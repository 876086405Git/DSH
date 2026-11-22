part of 'engine.dart';

class _ScriptGenerationRecord implements TavernScriptGeneration {
  _ScriptGenerationRecord(this.owner, this.id, this.context, this.request, this.config, this.at, {this.slashSpec}) {
    // Observe rejection immediately without replacing the caller's future.
    // A caller may first await result long after the hot operation has failed.
    unawaited(_result.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }
  final _ScriptCoordinator owner;
  @override
  final String id;
  final _ScriptContextState context;
  final TavernScriptGenerateRequest request;
  final TavernModelConfig config;
  final DateTime at;
  final _SlashGenerationSpec? slashSpec;
  final cancellation = ModelCancellation();
  final receipt = _ScriptGenerationReceipt();
  final _result = Completer<TavernScriptGenerationResult>();
  final observers = <MultiStreamController<TavernScriptGenerationEvent>>{};
  final text = StringBuffer();
  final reasoning = StringBuffer();
  final hookIssues = <TavernScriptIssue>[];
  _ScriptGenerationCapture? capture;
  _SPresetGeneration? spreset;
  TavernUsage? usage;
  String? finishReason;
  int seq = 0;
  TavernScriptGenerationStatus status = TavernScriptGenerationStatus.preparing;
  TavernScriptGenerationEvent? terminal;

  // Known prior effects are separate from this request's own receipt carriers.
  bool get committed =>
      receipt.committed || terminal?.error?.committed == true || hookIssues.any((issue) => issue.committed);

  @override
  Future<TavernScriptGenerationResult> get result => _result.future;

  TavernScriptGenerationEvent _event(
    TavernScriptGenerationEventKind kind, {
    String? delta,
    TavernScriptException? error,
    bool snapshot = false,
  }) => TavernScriptGenerationEvent(
    id: id,
    seq: seq,
    kind: kind,
    status: status,
    text: text.toString(),
    reasoning: request.includeReasoning ? reasoning.toString() : null,
    usage: usage,
    delta: delta,
    finishReason: finishReason,
    error: error,
    isSnapshot: snapshot,
    lastSeq: snapshot ? seq : null,
  );

  @override
  Stream<TavernScriptGenerationEvent> get events => Stream<TavernScriptGenerationEvent>.multi((observer) {
    // Snapshot and registration are one synchronous section. This snapshot is
    // private to this observer, never rebroadcast as a logical engine event.
    final ended = terminal;
    if (ended != null) {
      observer.add(_event(ended.kind, error: ended.error, snapshot: true));
      observer.close();
      return;
    }
    final snapshot = _event(TavernScriptGenerationEventKind.snapshot, snapshot: true);
    observers.add(observer);
    observer.onCancel = () {
      observers.remove(observer);
    };
    observer.add(snapshot);
  }, isBroadcast: true);

  void emit(TavernScriptGenerationEventKind kind, {String? delta}) {
    if (terminal != null) return;
    seq++;
    final event = _event(kind, delta: delta);
    for (final observer in observers.toList()) {
      observer.add(event);
    }
  }

  TavernScriptGenerationOrigin get origin =>
      capture?.origin ??
      TavernScriptGenerationOrigin(
        contextId: context.value.id,
        instanceId: context.value.instanceId,
        chatId: context.value.chatId,
        provider: config.deepseek ? 'deepseek' : 'openaiCompatible',
        model: config.model,
      );

  void finish({TavernScriptException? error}) {
    if (terminal != null) return;
    status = error == null
        ? TavernScriptGenerationStatus.completed
        : error.code == TavernScriptErrorCode.cancelled
        ? TavernScriptGenerationStatus.cancelled
        : TavernScriptGenerationStatus.failed;
    seq++;
    terminal = _event(
      error == null ? TavernScriptGenerationEventKind.finished : TavernScriptGenerationEventKind.failed,
      error: error,
    );
    if (identical(owner._generations[id], this)) owner._generations.remove(id);
    for (final observer in observers.toList()) {
      observer.add(terminal!);
      observer.close();
    }
    observers.clear();
    if (error == null) {
      _result.complete(
        TavernScriptGenerationResult(
          id: id,
          text: text.toString(),
          reasoning: request.includeReasoning ? reasoning.toString() : null,
          usage: usage,
          finishReason: finishReason,
          origin: origin,
          hookIssues: hookIssues,
        ),
      );
    } else {
      _result.completeError(error);
    }
    owner._generationNotify(this, 'GENERATION_ENDED', [
      {
        'status': status.name,
        'text': text.toString(),
        'finishReason': finishReason,
        'error': error?.code.name,
        'committed': committed,
        'hookIssues': [for (final issue in hookIssues) _scriptIssueJson(issue)],
      },
    ]);
  }
}

extension _ScriptGenerationOperations on _ScriptCoordinator {
  TavernScriptGeneration _startGeneration(String contextId, TavernScriptGenerateRequest source, {required bool raw}) {
    final context = _context(contextId);
    if (raw != (source is TavernScriptRawRequest)) {
      throw _scriptError(TavernScriptErrorCode.invalidArgument, 'generate', 'Request shape does not match the method.');
    }
    final request = _captureGenerationRequest(source);
    if (!raw && context.value.chatId == null) {
      throw _scriptError(TavernScriptErrorCode.noContext, 'generate', 'Normal generation requires a chat.');
    }
    for (final item in request.injects) {
      final filter = item.filter;
      if (filter != null &&
          (filter.contextId != context.value.id ||
              filter.instanceId != context.value.instanceId ||
              filter.callbackId.isEmpty)) {
        throw _scriptError(
          TavernScriptErrorCode.callbackUnavailable,
          'generate',
          'The filter is not owned by this live context.',
        );
      }
    }
    final config = engine._config;
    if (config.deepseek && request.samplingOverrides.containsKey('seed')) {
      throw TavernScriptException(
        code: TavernScriptErrorCode.unsupportedOption,
        operation: 'generate',
        message: 'This provider does not support the seed override.',
        fieldPath: 'samplingOverrides.seed',
      );
    }
    final id = request.generationId ?? 'background-${_newStateId()}';
    if (_generations.containsKey(id)) {
      throw _scriptError(TavernScriptErrorCode.duplicateId, 'generate', 'Generation id is active.');
    }
    final record = _ScriptGenerationRecord(
      this,
      id,
      context,
      request,
      TavernModelConfig(
        apiKey: config.apiKey,
        baseUrl: config.baseUrl,
        model: config.model,
        deepseek: config.deepseek,
        thinking: config.thinking,
        headers: config.headers,
        auxiliary: config.auxiliary,
      ),
      engine._clock(),
    );
    _generations[id] = record;
    // Start now, independently of observations. Storage ownership is acquired
    // before returning the handle, so backup cannot pass between admission and
    // the first asynchronous read.
    unawaited(_runGeneration(record));
    return record;
  }

  Future<void> _runGeneration(_ScriptGenerationRecord record) async {
    try {
      final prepared = await _prepareGenerationOwned(record);
      record.cancellation.check();
      _context(record.context.value.id);
      // The pure transport phase is not a backup storage barrier.
      final body = await record.spreset?.request(prepared.body) ?? prepared.body;
      await _consumeGeneration(record, body);
    } catch (error) {
      if (record.terminal == null) record.finish(error: _generationFailure(record, error));
      // All hot task failures have a structured result and an internal error
      // observer. No detached error is sent to the isolate's uncaught zone.
    } finally {
      final spreset = record.spreset;
      if (spreset != null) {
        unawaited(
          engine._trackOperation(spreset.close()).catchError((Object error) {
            spreset.diagnose('close', error);
          }),
        );
      }
    }
  }

  Future<_ScriptPreparedGeneration> _prepareGenerationOwned(_ScriptGenerationRecord record) {
    final completed = Completer<_ScriptPreparedGeneration>();
    final owned = engine._trackOperation(completed.future);
    // Register before dispatch can synchronously reenter backup()/close().
    unawaited(() async {
      try {
        record.emit(TavernScriptGenerationEventKind.started);
        _generationNotify(record, 'GENERATION_STARTED', [
          {'silent': record.request.silent},
        ]);
        record.cancellation.check();
        final capture = record.slashSpec == null
            ? await _captureGeneration(record)
            : await _captureSlashGeneration(record);
        record.capture = capture;
        final selected = capture.promptPreset;
        final spreset = record.spreset = _SPresetGeneration(
          engine,
          chatId: capture.context.value.chatId ?? '',
          generationId: record.id,
          cancellation: record.cancellation,
          settings: capture.settings,
          model: capture.config,
          presetId: capture.request.presetId ?? capture.chat?.presetId ?? engine._store.defaultPresetId,
          generationType: record.slashSpec == null ? 'normal' : 'quiet',
          onIssue: record.hookIssues.add,
          preset: selected == null
              ? const {}
              : {
                  ...selected.raw,
                  if (!selected.raw.containsKey('show_thoughts'))
                    'show_thoughts': !capture.config.deepseek || capture.config.thinking,
                },
        );
        await spreset.preparePreset(
          record.slashSpec == null ? 'normal' : 'quiet',
          () => [
            for (final node in capture.history)
              {
                'mes': node.message.text,
                'name': node.message.speaker,
                'is_user': node.message.role == TavernRole.user,
                'is_system': _systemMessage(node),
              },
          ],
        );
        record.receipt.phase = 'assemble';
        final prepared = record.slashSpec == null
            ? await prepareGeneration(
                capture,
                record.cancellation,
                spreset: spreset,
                onPhase: (phase) {
                  record.receipt.phase = phase;
                },
                onBudgetSource: (source) {
                  record.receipt.budgetSource = source;
                },
              )
            : await _prepareSlashGeneration(record, capture);
        record.hookIssues.addAll(prepared.hookIssues);
        record.receipt.budgetSource = prepared.budgetSource;
        record.cancellation.check();
        await _commitGeneration(record, prepared);
        completed.complete(prepared);
      } catch (error, stack) {
        completed.completeError(error, stack);
      }
    }());
    return owned;
  }

  TavernScriptException _generationFailure(_ScriptGenerationRecord record, Object error) {
    final cancelled =
        record.cancellation.isCancelled ||
        error is TavernModelException && error.kind == TavernFailure.cancelled ||
        error is TavernScriptException && error.code == TavernScriptErrorCode.cancelled;
    final original = _scriptReportedFailure(error);
    final model = error is TavernModelException
        ? error.kind
        : error is PromptBudgetExceeded
        ? TavernFailure.contextTooLong
        : null;
    final code = cancelled
        ? TavernScriptErrorCode.cancelled
        : original?.code ?? (model != null ? TavernScriptErrorCode.model : _scriptFailure(error).code);
    if (record.capture?.global.hasIntents == true) record.receipt.requiredTargets.add('global');
    if (record.capture?.local.hasIntents == true) record.receipt.requiredTargets.add('chat');
    for (final target in record.receipt.requiredTargets) {
      if (!record.receipt.startedTargets.contains(target) &&
          !record.receipt.skippedTargets.any((entry) => entry['targetKind'] == target)) {
        record.receipt.skippedTargets.add({'targetKind': target, 'reason': cancelled ? 'cancelled' : 'earlierFailure'});
      }
    }
    if (original?.operation == 'injectionFilter') record.receipt.phase = 'filter';
    if (model == TavernFailure.noKey) record.receipt.phase = 'key';
    final known = <TavernScriptIssue>[];
    for (final issue in [...?original?.issues, ...record.hookIssues]) {
      if (!known.contains(issue)) known.add(issue);
    }
    final committed = record.receipt.committed || original?.committed == true || known.any((issue) => issue.committed);
    final issues = [
      ...known,
      TavernScriptIssue(
        code: 'generationPreparation',
        message: 'Background generation ended before successful completion.',
        committed: committed,
        contextId: record.context.value.id,
        generationId: record.id,
        stage: record.receipt.phase,
        cancelled: cancelled,
        details: record.receipt.details(code.name),
      ),
    ];
    return TavernScriptException(
      code: code,
      operation: 'generate',
      message: cancelled
          ? 'Generation cancelled.'
          : original?.message ??
                (error is TavernModelException ? error.detail : 'Background generation failed (${error.runtimeType}).'),
      contextId: record.context.value.id,
      generationId: record.id,
      fieldPath: original?.fieldPath,
      sourceSpan: original?.sourceSpan,
      committed: committed,
      modelFailure: model ?? original?.modelFailure,
      issues: issues,
    );
  }

  void _generationNotify(_ScriptGenerationRecord record, String name, List<Object?> args) {
    final slashSpec = record.slashSpec;
    final request = _dispatch(
      record.context,
      kind: TavernScriptDispatchKind.lifecycle,
      namespace: 'iframe',
      name: name,
      generationId: record.id,
      args: args,
    );
    // A stopped generation still publishes its new terminal notification.
    // Its delivery is independently cancelled by owner/host shutdown instead
    // of inheriting the already cancelled token that ended the model work.
    unawaited(
      _deliver(
        record.context,
        request,
        committed: record.committed,
        cancellation: name == 'GENERATION_ENDED' ? null : record.cancellation,
        onObservedIssues: slashSpec == null
            ? null
            : (request, issues, committed) {
                if (record.terminal == null) slashSpec.observeHostOutcome(request, issues, committed);
              },
      ).then<void>((issues) {
        if (record.terminal == null) {
          // This aggregate also contains engine-generated delivery issues. It
          // propagates known occurrences; it is not another host observation.
          slashSpec?.owner.observeIssues(issues);
          record.hookIssues.addAll(issues);
        }
      }),
    );
  }

  Future<void> _consumeGeneration(_ScriptGenerationRecord record, Map<String, Object?> body) {
    final drained = Completer<void>();
    final owned = drained.future;
    _generationDrains.add(owned);
    unawaited(
      owned.then<void>((_) {
        _generationDrains.remove(owned);
      }),
    );
    StreamSubscription<({ModelDelta delta, String? text})>? subscription;
    var cancelling = false;
    void release() {
      if (!drained.isCompleted) drained.complete();
    }

    Future<void> cancelSubscription() async {
      if (cancelling) return;
      cancelling = true;
      try {
        await subscription?.cancel();
      } catch (_) {
        // This cancellation future is still owned through its actual terminal;
        // late cleanup cannot replace the already fixed logical result.
      } finally {
        release();
      }
    }

    void fail(Object error) {
      if (record.terminal == null) record.finish(error: _generationFailure(record, error));
      unawaited(cancelSubscription());
    }

    final gameplayCapture = record.capture?.gameplayCapture;
    final requestCancellation = _gameplayResourceRequestCancellation(engine, gameplayCapture, record.cancellation);
    final config = record.config;
    final transportConfig = TavernModelConfig(
      apiKey: () async {
        record.receipt.phase = 'key';
        final key = await config.apiKey();
        requestCancellation.check();
        if (record.terminal == null && !record.cancellation.isCancelled) record.receipt.phase = 'model';
        return key;
      },
      baseUrl: config.baseUrl,
      model: config.model,
      deepseek: config.deepseek,
      thinking: config.thinking,
      headers: config.headers,
      auxiliary: config.auxiliary,
    );
    try {
      record.cancellation.check();
      _checkScriptGameplayResources(engine, gameplayCapture, 'generate');
      record.status = TavernScriptGenerationStatus.running;
      record.receipt.phase = 'key';
      final slashSpec = record.slashSpec;
      final requestContext = ModelRequestContext(
        cancellation: requestCancellation,
        preparedBody: record.spreset != null,
        onUsageReport: (_) {},
        onResponseStarted: record.spreset?.observeResponseStarted,
        onResponseBytes: record.spreset?.observeResponseBytes,
        onResponseSecret: record.spreset?.observeResponseSecret,
      );
      final modelStream = engine._modelClient.generate(
        config: transportConfig,
        body: _captureScriptObject(body),
        cancellation: requestContext,
        onRequestStarted: slashSpec == null ? null : (attempt) => slashSpec.onModelStarted(record, attempt),
      );
      final responseStream =
          record.spreset?.response(modelStream, body) ?? modelStream.map((delta) => (delta: delta, text: null));
      subscription = responseStream.listen(
        (packet) {
          final delta = packet.delta;
          if (record.terminal != null || record.cancellation.isCancelled) return;
          try {
            _checkScriptGameplayResources(engine, gameplayCapture, 'generate');
          } catch (error) {
            fail(error);
            return;
          }
          record.receipt.phase = 'model';
          switch (delta) {
            case ModelText(:final text):
              if (packet.text case final processed?) {
                final previous = record.text.toString();
                if (processed == previous) return;
                final addition = processed.startsWith(previous) ? processed.substring(previous.length) : null;
                record.text.clear();
                record.text.write(processed);
                record.emit(
                  addition == null
                      ? TavernScriptGenerationEventKind.snapshot
                      : TavernScriptGenerationEventKind.textDelta,
                  delta: addition,
                );
                if (record.request.stream) {
                  if (addition != null) _generationNotify(record, 'STREAM_TOKEN_RECEIVED_INCREMENTALLY', [addition]);
                  _generationNotify(record, 'STREAM_TOKEN_RECEIVED_FULLY', [processed]);
                }
                return;
              }
              if (text.isEmpty) return;
              record.text.write(text);
              record.emit(TavernScriptGenerationEventKind.textDelta, delta: text);
              if (record.request.stream) {
                _generationNotify(record, 'STREAM_TOKEN_RECEIVED_INCREMENTALLY', [text]);
                _generationNotify(record, 'STREAM_TOKEN_RECEIVED_FULLY', [record.text.toString()]);
              }
            case ModelReasoning(:final text):
              if (text.isEmpty ||
                  !presetTruthy(
                    record.spreset?.preset['show_thoughts'] ?? (!record.config.deepseek || record.config.thinking),
                  )) {
                return;
              }
              record.reasoning.write(text);
              if (record.request.includeReasoning) {
                record.emit(TavernScriptGenerationEventKind.reasoningDelta, delta: text);
              }
            case ModelUsage(:final usage):
              record.usage = usage;
            case ModelToolFragment():
              fail(
                TavernScriptException(
                  code: TavernScriptErrorCode.unsupportedCapability,
                  operation: 'generate',
                  message: 'Background tool responses are not supported.',
                  generationId: record.id,
                  issues: [
                    TavernScriptIssue(
                      code: 'unsupportedCapability',
                      message: 'A tool response was received.',
                      committed: record.receipt.committed,
                      stage: 'model',
                      generationId: record.id,
                    ),
                  ],
                ),
              );
            case ModelFinished(:final reason):
              record.finishReason = reason;
              if (reason == 'tool_calls') {
                fail(
                  TavernScriptException(
                    code: TavernScriptErrorCode.unsupportedCapability,
                    operation: 'generate',
                    message: 'Background tool responses are not supported.',
                    generationId: record.id,
                    issues: [
                      TavernScriptIssue(
                        code: 'unsupportedCapability',
                        message: 'A tool finish was received.',
                        committed: record.receipt.committed,
                        stage: 'model',
                        generationId: record.id,
                      ),
                    ],
                  ),
                );
              } else {
                record.finish();
              }
          }
        },
        onError: (Object error, StackTrace _) {
          fail(error);
        },
        onDone: () {
          if (record.terminal == null) {
            if (record.cancellation.isCancelled) {
              record.finish(
                error: _generationFailure(record, const TavernModelException(TavernFailure.cancelled, 'cancelled')),
              );
            } else {
              try {
                _checkScriptGameplayResources(engine, gameplayCapture, 'generate');
                record.finish();
              } catch (error) {
                record.finish(error: _generationFailure(record, error));
              }
            }
          }
          release();
        },
      );
      unawaited(
        record.cancellation.whenCancelled.then<void>((_) {
          if (record.terminal == null) {
            fail(const TavernModelException(TavernFailure.cancelled, 'cancelled'));
          } else {
            unawaited(cancelSubscription());
          }
        }),
      );
    } catch (error) {
      fail(error);
    }
    return owned;
  }
}

TavernScriptGenerateRequest _captureGenerationRequest(TavernScriptGenerateRequest source) {
  final injections = [
    for (final item in source.injects)
      TavernScriptInjection(
        id: item.id,
        content: item.content,
        role: item.role,
        position: item.position,
        depth: item.depth,
        scan: item.scan,
        filter: item.filter == null
            ? null
            : TavernScriptCallbackRef(
                contextId: item.filter!.contextId,
                instanceId: item.filter!.instanceId,
                callbackId: item.filter!.callbackId,
              ),
      ),
  ];
  if (source is TavernScriptRawRequest) {
    return TavernScriptRawRequest(
      orderedPrompts: source.orderedPrompts,
      generationId: source.generationId,
      presetId: source.presetId,
      speakerCharacterId: source.speakerCharacterId,
      userInput: source.userInput,
      stream: source.stream,
      includeReasoning: source.includeReasoning,
      silent: source.silent,
      maxChatHistory: source.maxChatHistory,
      overrides: TavernScriptPromptOverrides(fields: source.overrides.fields),
      injects: injections,
      samplingOverrides: source.samplingOverrides,
    );
  }
  return TavernScriptGenerateRequest(
    generationId: source.generationId,
    presetId: source.presetId,
    speakerCharacterId: source.speakerCharacterId,
    userInput: source.userInput,
    stream: source.stream,
    includeReasoning: source.includeReasoning,
    silent: source.silent,
    maxChatHistory: source.maxChatHistory,
    overrides: TavernScriptPromptOverrides(fields: source.overrides.fields),
    injects: injections,
    samplingOverrides: source.samplingOverrides,
  );
}
