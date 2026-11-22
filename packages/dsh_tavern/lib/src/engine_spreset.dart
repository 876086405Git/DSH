part of 'engine.dart';

const _reservedNativeToolNames = {'roll', 'remember', 'update_state'};

class _SPresetGeneration {
  _SPresetGeneration(
    this.engine, {
    required this.chatId,
    required this.generationId,
    required this.cancellation,
    required this.settings,
    required this.model,
    required this.onIssue,
    this.generationType = 'normal',
    this.presetId,
    required Map<String, Object?> preset,
  }) : preset = {...preset, if (settings['spresetRuntimeMode'] == 'external') 'dsh_spreset_runtime': 'external'},
       host = engine._scripts._host,
       hostVersion = engine._scripts._hostVersion {
    engine._spresetGenerations.add(this);
    cancellation.whenCancelled.then((_) => token.cancel());
  }
  final TavernEngine engine;
  final String chatId, generationId, generationType;
  final String? presetId;
  final ModelCancellation cancellation;
  final Map<String, Object?> settings;
  final TavernModelConfig model;
  final void Function(TavernScriptIssue) onIssue;
  final Map<String, Object?> preset;
  final TavernScriptHost? host;
  final int hostVersion;
  final token = _ScriptCancellation();
  final sessions = <String>{};
  final pending = <Future<void>>{};
  final logs = SPresetScriptLogBuffer();
  final _logSecrets = <String>{};
  final _loggedResponses = <int>{};
  void observeResponseSecret(String secret) {
    // A response may already be collecting while its key Future is pending.
    // Turning the App setting off must not disable its credential redactor.
    // The key stays only in this generation's memory, never in a log record.
    if (secret.isNotEmpty) _logSecrets.add(secret);
  }

  final _transportLogs = <int, List<Map<String, Object?>>>{};
  void observeResponseStarted(int attempt, int status, Map<String, String> headers) {
    if (!logEnabled || !_loggedResponses.contains(_response)) return;
    final attempts = _transportLogs.putIfAbsent(_response, () => []);
    attempts.add({'attempt': attempt, 'status': status, 'headers': headers, 'capture': SPresetResponseLogCapture()});
  }

  void observeResponseBytes(int attempt, List<int> bytes) {
    if (!logEnabled) return;
    final record = _transportLogs[_response]?.where((item) => item['attempt'] == attempt).lastOrNull;
    if (record == null) return;
    (record['capture']! as SPresetResponseLogCapture).add(bytes);
  }

  List<Map<String, Object?>> _finishTransportLog(int number) {
    final records = _transportLogs.remove(number) ?? <Map<String, Object?>>[];
    for (final record in records) {
      final captured = (record.remove('capture')! as SPresetResponseLogCapture).finish(secrets: _logSecrets);
      record['body'] = redactSPresetResponseBody(captured.text, truncated: captured.truncated, secrets: _logSecrets);
      record['truncated'] = captured.truncated;
    }
    return records;
  }

  void _discardTransportLog(int number) {
    for (final record in _transportLogs.remove(number) ?? <Map<String, Object?>>[]) {
      (record['capture']! as SPresetResponseLogCapture).discard();
    }
  }

  late final config = SPresetConfig.fromPreset(preset);
  SPresetMacroNestRuntime get macroNestRuntime => engine._spresetMacroNest;
  late final provider = SPresetProvider(source: _modelChatCompletionSource(model), model: model.model);
  List<SPresetTool> tools = const [];
  int _sequence = 0, _response = 0;
  bool _closed = false;
  bool get logEnabled =>
      config.present &&
      _readMap(engine._document['settings'])['spresetLogUploadEnabled'] == true &&
      config.module('LogUpload')['enabled'] != false;

  void diagnose(String stage, Object error) {
    onIssue(
      TavernScriptIssue(
        code: error is SPresetException ? 'spresetScript' : 'spresetFailure',
        message: error is SPresetException ? error.detail : 'SPreset $stage failed (${error.runtimeType}).',
        committed: false,
        generationId: generationId,
        stage: stage,
      ),
    );
  }

  void check() {
    cancellation.check();
    if (_closed ||
        token.isCancelled ||
        engine._scripts._hostVersion != hostVersion ||
        !identical(host, engine._scripts._host)) {
      throw const SPresetException('host', 'The SPreset page host changed or closed during generation.');
    }
  }

  Future<TavernSPresetEvaluationResult> evaluate(
    String stage,
    String source,
    List<Object?> arguments, {
    String? identifier,
    String? sessionId,
    bool reset = false,
    TavernSPresetEvaluationKind kind = TavernSPresetEvaluationKind.functionExpression,
    void Function(TavernSPresetEvaluationResult)? onActualResult,
    void Function(Object, StackTrace)? onActualError,
  }) async {
    check();
    final evaluator = host;
    if (evaluator is! TavernSPresetScriptHost) {
      throw SPresetException(stage, 'This preset requires the App SPreset JavaScript host; the host is not attached.');
    }
    final session = '$generationId:${sessionId ?? '$stage:${++_sequence}'}';
    sessions.add(session);
    final request = TavernSPresetEvaluationRequest(
      requestId: '$generationId:eval:${++_sequence}',
      chatId: chatId,
      generationId: generationId,
      sessionId: session,
      stage: stage,
      source: source,
      identifier: identifier,
      kind: kind,
      reset: reset,
      captureLogs: logEnabled,
      arguments: arguments,
      cacheKey:
          kind == TavernSPresetEvaluationKind.toolDefinition ||
              kind == TavernSPresetEvaluationKind.toolAction ||
              kind == TavernSPresetEvaluationKind.toolFormatMessage
          ? '$chatId:${sessionId ?? identifier}:${crypto.sha256.convert(utf8.encode(source))}'
          : null,
    );
    final actual =
        Future<TavernSPresetEvaluationResult>.sync(
          () => (evaluator as TavernSPresetScriptHost).evaluateSPreset(request, token),
        ).then(
          (response) {
            if (response.requestId != request.requestId) {
              throw SPresetException(stage, 'Mismatched SPreset evaluation response.');
            }
            onActualResult?.call(response);
            return response;
          },
          onError: (Object error, StackTrace stack) {
            onActualError?.call(error, stack);
            Error.throwWithStackTrace(error, stack);
          },
        );
    final drained = actual.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    pending.add(drained);
    unawaited(drained.then((_) => pending.remove(drained)));
    final response = await cancellation.wait(engine._trackOperation(actual));
    check();
    for (final issue in response.issues) {
      onIssue(issue);
    }
    if (logEnabled) {
      logs.add(
        {
          'stage': stage,
          'identifier': identifier,
          'arguments': arguments,
          'result': response.value,
          'argumentsAfter': response.arguments,
          'console': response.scriptLogs,
        },
        secrets: _logSecrets,
        upstreamDropped: response.scriptLogsDropped,
        upstreamTruncatedValues: response.scriptLogValuesTruncated,
      );
    }
    return response;
  }

  Future<Map<String, Object?>> preparePreset(String type, List<Map<String, Object?>> Function() readChat) async {
    if (!config.present) return preset;
    final forced = config.forcedPostProcessing;
    if (forced != null) preset['custom_prompt_post_processing'] = forced;
    final entries = _spRows(preset['prompts']).where((entry) => presetTruthy(entry['spreset_condition_enabled']));
    final decisions = <String, bool>{};
    if (entries.isNotEmpty) {
      final chat = readChat();
      for (final entry in entries) {
        final identifier = _spString(entry['identifier']);
        try {
          final response = await evaluate('EntryCondition', _spString(entry['spreset_condition_script']), [
            {
              'model': provider.model,
              'provider': provider.toJson(),
              'source': provider.source,
              'type': type,
              'entry': entry,
              'chat': chat,
            },
          ], identifier: identifier);
          if (response.value is! bool) {
            throw const SPresetException('EntryCondition', 'Entry condition must return boolean.');
          }
          decisions[identifier] = response.value! as bool;
        } catch (error) {
          cancellation.check();
          diagnose('EntryCondition', error);
          decisions[identifier] = false;
        }
      }
      preset['prompt_order'] = [
        for (final group in _spRows(preset['prompt_order']))
          {
            ...group,
            'order': [
              for (final row in _spRows(group['order']))
                {...row, if (decisions.containsKey(row['identifier'])) 'enabled': decisions[row['identifier']]},
            ],
          },
      ];
    }
    final resolved = await resolveSPresetTools(
      config,
      preset,
      evaluate,
      diagnose,
      synchronizeEmpty: host is TavernSPresetScriptHost,
    );
    final offered = <SPresetTool>[];
    for (final tool in resolved) {
      sessions.add('$generationId:${tool.sessionId}');
      if (_reservedNativeToolNames.contains(tool.name)) {
        diagnose(
          'ToolBindings',
          SPresetException('ToolBindings', 'Tool name conflicts with a reserved native tool: ${tool.name}'),
        );
      } else {
        offered.add(tool);
      }
    }
    tools = offered;
    cancellation.check();
    return preset;
  }

  List<Map<String, Object?>> offerTools(List<Map<String, Object?>> native) {
    if (!canPerformTools) return native;
    final names = {for (final tool in native) _spMap(tool['function'])['name']};
    return [
      ...native,
      for (final tool in tools)
        if (names.add(tool.name)) tool.wire,
    ];
  }

  bool get canPerformTools =>
      presetTruthy(preset['function_calling']) &&
      const {
        '',
        'merge_tools',
        'semi_tools',
        'strict_tools',
      }.contains(_spString(preset['custom_prompt_post_processing'])) &&
      !const {'impersonate', 'quiet', 'continue'}.contains(generationType);
  double get recursionLimit =>
      presetJsNumber(preset.containsKey('tool_call_recurse_limit') ? preset['tool_call_recurse_limit'] : 5).toDouble();
  bool permitsDepth(int depth) => canPerformTools && depth < recursionLimit;
  int? get requestLimit {
    if (tools.isEmpty || !canPerformTools) return 4;
    final limit = recursionLimit;
    if (limit == double.infinity) return null;
    return limit.isFinite && limit > 0 ? max(4, limit.ceil() + 1) : 4;
  }

  List<String> offeredNames(Map<String, Object?> body) {
    if (!canPerformTools) return const [];
    final choice = body['tool_choice'];
    String? selected;
    if (choice != null && choice != 'auto' && choice != 'required') {
      if (choice is! Map<String, Object?> || choice['type'] != 'function') return const [];
      final name = _spMap(choice['function'])['name'];
      if (name is! String) return const [];
      selected = name;
    }
    final offered = {
      for (final tool in _spRows(body['tools']))
        if (tool['type'] == 'function') _spMap(tool['function'])['name'],
    };
    return [
      for (final tool in tools)
        if (offered.contains(tool.name) &&
            (selected == null || selected == tool.name) &&
            !_reservedNativeToolNames.contains(tool.name))
          tool.name,
    ];
  }

  Future<PromptAssembly> assembly(PromptAssembly original, PromptInput input, PromptTokenCounter counter) async {
    if (!config.present) return original;
    final squash = config.chatSquash;
    if (!presetTruthy(squash['enabled']) && !presetTruthy(squash['squashed_post_script_enable'])) return original;
    final segments = await spresetSquashSegments(
      original.beforePostProcessing,
      config,
      counter,
      expand: (text) => input.expansion?.call(text, const {}) ?? text,
      evaluate: evaluate,
      diagnose: diagnose,
    );
    cancellation.check();
    return reprocessPromptAssembly(original, segments, input, counter: counter);
  }

  Future<Map<String, Object?>> request(Map<String, Object?> body) async {
    cancellation.check();
    final base = prepareModelRequestBody(model, body);
    if (!config.present && host is! TavernSPresetRequestObserver) return base;
    if (config.present) {
      spresetApplyStops(config, base);
    }
    Map<String, Object?> finalBody;
    try {
      finalBody = await spresetFinalRequest(config, base, provider, evaluate);
    } catch (error) {
      diagnose('FinalRequestProcessing', error);
      rethrow;
    }
    cancellation.check();
    final observer = host;
    if (observer is TavernSPresetRequestObserver) {
      await cancellation.wait(
        engine._trackOperation(
          (observer as TavernSPresetRequestObserver).observeSPresetRequest(
            TavernSPresetRequestSnapshot(chatId: chatId, generationId: generationId, body: finalBody),
            token,
          ),
        ),
      );
      check();
    }
    if (logEnabled) {
      try {
        await engine._loadSPresetLogs();
        final now = engine._clock().toUtc().toIso8601String();
        engine._spresetLogs.add({
          'id': '$generationId:request:${_response + 1}',
          'startedAt': now,
          'endedAt': null,
          'status': 'pending',
          'presetName': _presetName,
          'request': finalBody,
          'apiConfig': {'provider': provider.toJson(), 'baseUrl': model.baseUrl, 'headers': model.headers},
          ..._scriptLogFields,
        }, secrets: _logSecrets);
        _loggedResponses.add(_response + 1);
      } catch (error) {
        diagnose('LogUpload', error);
      }
    }
    return finalBody;
  }

  String get _presetName => presetId == null
      ? _spString(preset['preset_settings_openai'], 'current')
      : engine._store.listPresets().where((item) => item.id == presetId).firstOrNull?.name ?? presetId!;

  Map<String, Object?> get _scriptLogFields => {
    'scriptLogs': logs.records,
    'scriptLogsDropped': logs.dropped,
    'scriptLogValuesTruncated': logs.truncatedValues,
    'scriptConsoleLogsDropped': logs.consoleDropped,
  };

  Stream<({ModelDelta delta, String? text})> response(Stream<ModelDelta> source, Map<String, Object?> body) {
    if (!config.present || !presetTruthy(config.module('OutputPreprocessing')['enabled'])) {
      final number = ++_response;
      // A disabled hook must not turn synchronous producer callbacks into
      // queued async events: resume snapshots and cancellation observe them.
      return _loggedResponses.contains(number)
          ? _observeResponse(source, number)
          : source.map((delta) => (delta: delta, text: null));
    }
    return _processedResponse(source, body);
  }

  Stream<({ModelDelta delta, String? text})> _observeResponse(Stream<ModelDelta> source, int number) {
    final raw = StringBuffer();
    var finished = false;
    Map<String, Object?>? originalMessage;
    Future<void>? finishing;
    Future<void> finish() =>
        finishing ??= engine._trackOperation(_writeResponseLog(number, raw.toString(), finished, originalMessage));
    StreamSubscription<ModelDelta>? subscription;
    late final StreamController<({ModelDelta delta, String? text})> controller;
    controller = StreamController(
      sync: true,
      onListen: () {
        subscription = source.listen(
          (delta) {
            if (delta is ModelText) raw.write(delta.text);
            if (delta is ModelFinished) {
              finished = true;
              originalMessage = delta.assistantSnapshot?.wireMessage;
            }
            controller.add((delta: delta, text: null));
          },
          onError: (Object error, StackTrace stack) => controller.addError(error, stack),
          onDone: () => unawaited(finish().then((_) => controller.close())),
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        await subscription?.cancel();
        await finish();
      },
    );
    return controller.stream;
  }

  Future<void> _writeResponseLog(int number, String raw, bool finished, Map<String, Object?>? originalMessage) async {
    if (!_loggedResponses.remove(number)) return;
    try {
      final enabled = logEnabled;
      if (!enabled) _discardTransportLog(number);
      final now = engine._clock().toUtc().toIso8601String();
      final record = engine._spresetLogs.records
          .where((value) => value['id'] == '$generationId:request:$number')
          .firstOrNull;
      if (record != null) {
        engine._spresetLogs.add({
          ...record,
          'endedAt': now,
          'status': !enabled ? 'logging_disabled' : (finished ? 'completed' : 'response_error'),
          'response': enabled
              ? {'text': raw, 'message': ?originalMessage, 'transport': _finishTransportLog(number)}
              : {'omitted': true, 'reason': 'App global logging is disabled at response settlement'},
          ..._scriptLogFields,
        }, secrets: _logSecrets);
      }
      await engine._saveSPresetLogs();
    } catch (error) {
      diagnose('LogUpload', error);
    } finally {
      // Another generation can evict this record before its response settles.
      // Its transport capture still needs releasing when no record remains.
      _discardTransportLog(number);
    }
  }

  Stream<({ModelDelta delta, String? text})> _processedResponse(
    Stream<ModelDelta> source,
    Map<String, Object?> body,
  ) async* {
    final number = ++_response;
    final outputSettings = config.module('OutputPreprocessing');
    final streaming = body['stream'] != false;
    SPresetOutputSession? session;
    if (config.present && presetTruthy(outputSettings['enabled'])) {
      try {
        // Upstream validates the function before intercepting tools. A syntax
        // error or absent host must never silently consume a real tool call.
        await evaluate(
          'OutputPreprocessing/validate',
          _spString(outputSettings['script']),
          const [],
          kind: TavernSPresetEvaluationKind.validateFunctionExpression,
        );
        session = SPresetOutputSession(
          script: _spString(outputSettings['script']),
          evaluate: evaluate,
          diagnose: diagnose,
          stream: streaming,
          sessionId: 'output:$number',
        );
      } catch (error) {
        cancellation.check();
        diagnose('OutputPreprocessing', error);
      }
    }
    final consume = session != null && presetTruthy(outputSettings['consumeToolCalls']);
    final toolAccumulator = ModelToolAccumulator();
    final fragments = <ModelToolFragment>[];
    var raw = '';
    var finished = false;
    Map<String, Object?>? originalMessage;
    try {
      await for (final delta in source) {
        cancellation.check();
        if (delta is ModelText && session != null) {
          raw += delta.text;
          if (streaming) {
            final text = await session.updateCumulative(raw);
            cancellation.check();
            yield (delta: delta, text: text);
          }
        } else if (delta is ModelToolFragment && consume) {
          toolAccumulator.add(delta);
          fragments.add(delta);
        } else if (delta is ModelFinished) {
          finished = true;
          var consumed = false;
          final beforeToolText = session?.output ?? raw;
          var toolFailure = false;
          var nonstreamRaw = raw;
          if (consume && fragments.isNotEmpty) {
            if (session.failed) {
              toolFailure = true;
            } else {
              try {
                final batch = toolAccumulator.finish();
                if (!batch.finalIdentityComplete || !batch.originalArgumentsStringComplete || batch.metadataConflict) {
                  throw const SPresetException('OutputPreprocessing', 'Incomplete tool arguments cannot be consumed.');
                }
                final calls = [
                  for (final call in batch.calls)
                    {
                      'id': call.id,
                      'type': 'function',
                      'function': {'name': call.name, 'arguments': call.arguments},
                    },
                ];
                final text = await spresetFormatToolCalls(calls, outputSettings, provider, evaluate, stream: streaming);
                final cumulative = spresetAppendToolText(raw, text);
                if (streaming) {
                  await session.updateCumulative(cumulative);
                  toolFailure = session.failed;
                } else {
                  nonstreamRaw = cumulative;
                }
                consumed = !toolFailure;
              } catch (error) {
                cancellation.check();
                toolFailure = true;
                diagnose('ToolCallFormatter', error);
              }
            }
          }
          String? finalText;
          if (session != null) {
            // Nonstream MESSAGE_RECEIVED calls the processor once, with the
            // entire response and final=true, after fetch-level consumption.
            finalText = streaming
                ? await session.finish()
                : await session.updateCumulative(nonstreamRaw, finalChunk: true);
            cancellation.check();
            if (streaming && consume && fragments.isNotEmpty && (toolFailure || session.failed)) {
              // The stream wrapper restores the last previously emitted text
              // and original tools; it does not expose failed appended args.
              consumed = false;
              finalText = beforeToolText;
            }
            yield (delta: const ModelText(''), text: finalText);
          }
          if (!consumed) {
            for (final fragment in fragments) {
              yield (delta: fragment, text: null);
            }
          }
          final originalSnapshot = delta.assistantSnapshot;
          originalMessage = originalSnapshot?.wireMessage;
          final message = originalSnapshot?.wireMessage;
          if (message != null && finalText != null) {
            message['content'] = finalText;
            if (consumed) {
              message.remove('tool_calls');
              message.remove('function_call');
            }
          }
          yield (
            delta: ModelFinished(
              consumed ? 'stop' : delta.reason,
              assistantSnapshot: message == null || finalText == null
                  ? originalSnapshot
                  : ModelAssistantSnapshot.fromCustomMessage(
                      message,
                      callIndexes: consumed ? const [] : originalSnapshot?.calls.map((call) => call.index).toList(),
                    ),
              finalUsageReport: delta.finalUsageReport,
            ),
            text: null,
          );
        } else {
          if (delta is ModelText) raw += delta.text;
          yield (delta: delta, text: null);
        }
      }
      if (!finished && session != null) {
        final text = streaming ? await session.finish() : await session.updateCumulative(raw, finalChunk: true);
        cancellation.check();
        yield (delta: const ModelText(''), text: text);
        for (final fragment in fragments) {
          yield (delta: fragment, text: null);
        }
      }
    } finally {
      if (_loggedResponses.contains(number)) await _writeResponseLog(number, raw, finished, originalMessage);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    token.cancel('closed');
    try {
      await Future.wait(pending.toList());
      final evaluator = host;
      if (evaluator is TavernSPresetScriptHost) {
        Object? firstError;
        StackTrace? firstStack;
        for (final session in sessions) {
          try {
            await (evaluator as TavernSPresetScriptHost).releaseSPresetSession(session);
          } catch (error, stack) {
            firstError ??= error;
            firstStack ??= stack;
          }
        }
        if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
      }
    } finally {
      engine._spresetGenerations.remove(this);
    }
  }
}

extension _SPresetEngineOperations on TavernEngine {
  Future<void> _loadSPresetLogs() => _spresetLogLoad ??= () async {
    final file = File('${directory.path}/spreset-generation-logs.json');
    if (!await file.exists()) return;
    final value = jsonDecode(await file.readAsString());
    _spresetLogs.restore(_spRows(value));
  }();
  Future<void> _saveSPresetLogs() {
    final next = _spresetLogWrite.then((_) async {
      final file = File('${directory.path}/spreset-generation-logs.json');
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(_spresetLogs.records), flush: true);
      await temporary.rename(file.path);
    });
    _spresetLogWrite = next.catchError((Object _) {});
    return _trackOperation(next);
  }
}

Map<String, Object?> _spMap(Object? value) => value is Map<String, Object?> ? value : const {};
List<Map<String, Object?>> _spRows(Object? value) =>
    value is List<Object?> ? value.whereType<Map<String, Object?>>().toList() : const [];
String _spString(Object? value, [String fallback = '']) => value == null ? fallback : presetString(value);

Future<bool> _processSPresetToolCall(
  TavernEngine engine,
  _Turn turn,
  _OrdinaryToolRequest request,
  ModelToolCall call,
  _SPresetGeneration generation,
) async {
  final tool = generation.tools.firstWhere((tool) => tool.name == call.name);
  if (!call.valid || call.parameters == null) {
    final receipt = _prepareOrdinaryReceipt(
      engine,
      turn,
      request,
      call,
      status: 'rejected',
      error: {'code': 'invalid_arguments'},
    );
    _sealOrdinaryReceipt(engine, turn, request, call, receipt);
    return false;
  }
  final receipt = engine._store.prepareSPresetToolReceipt(
    turn.toolOwner!,
    call: _storedModelCall(request, call),
    onCommitted: (receipt) {
      request.receipts[call.index] = receipt;
    },
  );
  Object? result;
  var resultUndefined = false;
  bool? committed;
  var actionEntered = false;
  String? error;
  String? displayMessage;
  TavernSPresetEvaluationResult? observed;
  var adopted = false;
  Map<String, Object?> payload(Object? actual, {bool late = false}) => {
    'result': actual,
    'displayName': presetTruthy(tool.definition['displayName']) ? tool.definition['displayName'] : tool.name,
    'formatMessage': displayMessage,
    'stealth': presetTruthy(tool.definition['stealth']),
    'actionInvoked': actionEntered,
    if (late) 'observedLate': true,
    if (late) 'logicalError': error,
  };
  void observe(TavernSPresetEvaluationResult response) {
    observed = response;
    if (!adopted) return;
    final actualCommitted = response.committed ?? (response.issues.any((issue) => issue.committed) ? true : null);
    if (actualCommitted == null) return;
    try {
      engine._store.finishSPresetToolReceipt(
        receipt.executionId,
        value: payload(response.value, late: true),
        committed: actualCommitted,
        late: true,
        onCommitted: (next) {
          request.receipts[call.index] = next;
        },
      );
    } catch (failure) {
      generation.onIssue(
        TavernScriptIssue(
          code: 'spresetLateReceipt',
          message: 'The action completed after cancellation, but its receipt could not be updated.',
          committed: actualCommitted,
          generationId: generation.generationId,
          stage: 'ToolBindings/action',
          details: {'executionId': receipt.executionId, 'failureType': '${failure.runtimeType}'},
        ),
      );
    }
  }

  try {
    if (tool.definition['hasFormatMessage'] == true) {
      try {
        final display = await generation.evaluate(
          'ToolBindings/formatMessage',
          tool.code,
          [call.parameters],
          identifier: tool.identifier,
          sessionId: tool.sessionId,
          kind: TavernSPresetEvaluationKind.toolFormatMessage,
        );
        displayMessage = display.value is String ? display.value as String : null;
      } catch (failure) {
        generation.diagnose('ToolBindings/formatMessage', failure);
      }
    }
    turn.cancellation.check();
    _requireOrdinaryOwnership(engine, turn, StoredToolPhase.owned);
    generation.check();
    actionEntered = true;
    final response = await generation.evaluate(
      'ToolBindings/action',
      tool.code,
      [call.parameters],
      identifier: tool.identifier,
      sessionId: tool.sessionId,
      kind: TavernSPresetEvaluationKind.toolAction,
      onActualResult: observe,
      onActualError: (failure, stack) {
        if (failure is TavernScriptException && failure.committed) {
          observe(TavernSPresetEvaluationResult(requestId: 'observed-error', committed: true, issues: failure.issues));
        }
      },
    );
    result = response.value;
    resultUndefined = response.isUndefined;
    committed = response.committed ?? (response.issues.any((issue) => issue.committed) ? true : null);
  } catch (failure) {
    if (!actionEntered) committed = false;
    error = failure is SPresetException ? failure.detail : 'Tool action failed (${failure.runtimeType}).';
    generation.diagnose('ToolBindings/action', failure);
  }
  final actual = observed;
  if (actual != null) {
    result = actual.value;
    resultUndefined = actual.isUndefined;
    committed = actual.committed ?? (actual.issues.any((issue) => issue.committed) ? true : committed);
  }
  engine._store.finishSPresetToolReceipt(
    receipt.executionId,
    value: payload(result),
    committed: committed,
    error: error,
    // Terminal cleanup can settle an in-flight intent before this continuation.
    // Only an unresolved result may then adopt the observed completion facts.
    late: engine._store.readToolReceipt(receipt.executionId)?.status == 'unresolved',
    onCommitted: (next) {
      request.receipts[call.index] = next;
    },
  );
  adopted = true;
  final wire = error == null
      ? resultUndefined || result == ''
            ? '[No content]'
            : result is String
            ? result
            : jsonEncode(result)
      : 'Error: $error';
  engine._store.sealToolReceiptWireResult(
    receipt.executionId,
    wireResultJson: jsonEncode({'spresetResult': wire}),
    onCommitted: (next) {
      request.receipts[call.index] = next;
    },
  );
  _toolActivity(turn, requestId: request.snapshot.requestId, executionId: receipt.executionId);
  turn.cancellation.check();
  _requireOrdinaryOwnership(engine, turn, StoredToolPhase.owned);
  return presetTruthy(tool.definition['stealth']);
}
