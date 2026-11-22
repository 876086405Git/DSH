part of 'engine.dart';

const _reservedNativeToolNames = {'roll', 'remember', 'update_state'};

// Public generation IDs may be reused while an older bridge Future is still
// draining. Keep page sessions and RPC identities separate from that ID and
// from business ID allocation. The shared counter covers multiple engines in
// this isolate; an independent random prefix also separates other isolates.
final _spresetSessionPrefix = (() {
  final random = Random.secure();
  return base64Url.encode(List<int>.generate(16, (_) => random.nextInt(256))).replaceAll('=', '');
})();
var _spresetSessionSequence = 0;

String _newSPresetSessionScope() => 'spreset:$_spresetSessionPrefix:${++_spresetSessionSequence}';

enum _SPresetPromptPath { native, helperPreset, helperRaw }

class _SPresetGeneration {
  _SPresetGeneration(
    this.engine, {
    required this.chatId,
    required this.generationId,
    required this.cancellation,
    required this.settings,
    required this.model,
    this.providerOverride,
    required this.onIssue,
    this.generationType = 'normal',
    this.presetId,
    required Map<String, Object?> preset,
    SPresetConfig? capturedConfig,
  }) : _capturedConfig = capturedConfig,
       preset = {...preset, if (settings['spresetRuntimeMode'] == 'external') 'dsh_spreset_runtime': 'external'},
       host = engine._scripts._host,
       hostVersion = engine._scripts._hostVersion,
       pageEpoch = engine._spresetPageEpochs[chatId] ?? 0 {
    engine._spresetGenerations.add(this);
    cancellation.whenCancelled.then((_) => token.cancel());
  }
  final TavernEngine engine;
  final String chatId, generationId, generationType;
  final String sessionScope = _newSPresetSessionScope();
  final String? presetId;
  final ModelCancellation cancellation;
  final Map<String, Object?> settings;
  final TavernModelConfig model;
  final SPresetProvider? providerOverride;
  final void Function(TavernScriptIssue) onIssue;
  final Map<String, Object?> preset;
  final TavernScriptHost? host;
  final int hostVersion;
  final int pageEpoch;
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
  _SPresetResponseMetadata? _responseMetadata;
  Future<void>? Function(int, bool, Map<String, Object?>)? get nativeResponseFrameObserver {
    final output = config.module('OutputPreprocessing');
    if (!config.present || !presetTruthy(output['enabled']) || !presetTruthy(output['consumeToolCalls'])) return null;
    return (attempt, streaming, frame) {
      final metadata = _responseMetadata;
      if (metadata == null) return null;
      if (!streaming) {
        metadata.add(attempt, false, frame);
        return null;
      }
      final supported = _readStreamingToolSupport();
      if (supported is Future<bool>) {
        return supported.then((value) {
          check();
          metadata.add(attempt, true, frame, toolsSupported: value);
        });
      }
      metadata.add(attempt, true, frame, toolsSupported: supported);
      return null;
    };
  }

  bool get _streamingToolsSupported =>
      presetTruthy(preset['function_calling']) &&
      const {
        '',
        'merge_tools',
        'semi_tools',
        'strict_tools',
      }.contains(_spString(preset['custom_prompt_post_processing'])) &&
      !(const {'openai', 'azure_openai'}.contains(provider.source) && model.model.startsWith('gpt-6-astra'));

  FutureOr<bool> _readStreamingToolSupport() {
    check();
    if (!_streamingToolsSupported) return false;
    final capabilityHost = host;
    if (capabilityHost is! TavernSPresetToolCapabilityHost) {
      return spresetToolModelSupportsTools(provider.source, const TavernSPresetToolModelLookup.notSupplied());
    }
    try {
      final result = (capabilityHost as TavernSPresetToolCapabilityHost).lookupSPresetToolModel(
        TavernSPresetToolCapabilityRequest(
          generationId: generationId,
          chatId: chatId,
          source: provider.source,
          model: model.model,
        ),
        token,
      );
      if (result is Future<TavernSPresetToolModelLookup>) return _waitStreamingToolSupport(result);
      check();
      return spresetToolModelSupportsTools(provider.source, result);
    } catch (error) {
      cancellation.check();
      diagnose('ToolCapability', error);
      rethrow;
    }
  }

  Future<bool> _waitStreamingToolSupport(Future<TavernSPresetToolModelLookup> actual) async {
    final drained = actual.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    pending.add(drained);
    unawaited(drained.then((_) => pending.remove(drained)));
    try {
      final result = await cancellation.wait(engine._trackOperation(actual));
      check();
      return spresetToolModelSupportsTools(provider.source, result);
    } catch (error) {
      cancellation.check();
      diagnose('ToolCapability', error);
      rethrow;
    }
  }

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

  final SPresetConfig? _capturedConfig;
  late final config = _capturedConfig ?? SPresetConfig.fromPreset(preset);
  SPresetMacroNestRuntime get macroNestRuntime => engine._spresetMacroNest;
  late final provider =
      providerOverride ?? SPresetProvider(source: _modelChatCompletionSource(model), model: model.model);
  List<SPresetTool> tools = const [];
  Map<String, bool>? _entryDecisions;
  PromptManagerSnapshot? _promptManagerSnapshot;
  late final Object? _originalPromptOrder = _captureScriptJson(preset['prompt_order']);
  final _registryModes = <String>{};
  final _reportedNativeToolConflicts = <(String, String)>{};
  List<Map<String, Object?>> _nativeToolRows = const [];
  bool _nativeEntryPhase = false;
  // A host interface does not prove that its current page loaded the runtime.
  // Keep temporarily order/Entry-filtered bindings in the shared sync path,
  // but data-only or wholly disabled/invalid bindings need no page registry.
  late final bool _hasEnabledToolBindings = config.module('ToolBindings').values.any((value) {
    final binding = _spMap(value);
    return presetTruthy(binding['valid']) && presetTruthy(binding['enabled']);
  });
  bool get _nativeRegistryPhases => _nativeEntryPhase && _hasEnabledToolBindings && host is TavernSPresetScriptHost;
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

  bool get _currentPage =>
      !_closed &&
      !token.isCancelled &&
      engine._scripts._hostVersion == hostVersion &&
      (engine._spresetPageEpochs[chatId] ?? 0) == pageEpoch &&
      identical(host, engine._scripts._host);

  void check() {
    cancellation.check();
    if (!_currentPage) {
      throw const SPresetException('host', 'The SPreset page document or host changed during generation.');
    }
  }

  void capturePromptManager(PromptManagerSnapshot snapshot) {
    // Local assembly belongs to this generation. Page publication is only an
    // observer: an obsolete page cannot repopulate its cleared shared state.
    _promptManagerSnapshot = snapshot;
    if (chatId.isNotEmpty && !cancellation.isCancelled && _currentPage) {
      engine._spresetPromptManagers[chatId] = snapshot;
    }
  }

  PromptManagerSnapshot? readPromptManager() {
    check();
    return chatId.isEmpty ? null : engine._spresetPromptManagers[chatId];
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
    final session = '$sessionScope:${sessionId ?? '$stage:${++_sequence}'}';
    sessions.add(session);
    final request = TavernSPresetEvaluationRequest(
      requestId: '$sessionScope:eval:${++_sequence}',
      chatId: chatId,
      generationId: generationId,
      sessionScope: sessionScope,
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
    final captureRegistryReceivers =
        kind == TavernSPresetEvaluationKind.toolRegistry && _spMap(arguments.firstOrNull)['registryMode'] != 'refresh';
    final actual =
        Future<TavernSPresetEvaluationResult>.sync(
          () => (evaluator as TavernSPresetScriptHost).evaluateSPreset(request, token),
        ).then(
          (response) {
            if (response.requestId != request.requestId) {
              throw SPresetException(stage, 'Mismatched SPreset evaluation response.');
            }
            if (captureRegistryReceivers) {
              // A late result is not adopted after cancellation/host changes, but
              // close drains this actual Future and still owns its returned receivers.
              for (final tool in _spRows(_spMap(response.value)['tools'])) {
                sessions.add('$sessionScope:${_spString(tool['sessionId'])}');
              }
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

  Future<void> beginNativeEntries(String type, List<Map<String, Object?>> Function() readChat) async {
    check();
    _nativeEntryPhase = true;
    final forced = config.forcedPostProcessing;
    if (forced != null) preset['custom_prompt_post_processing'] = forced;
    await _evaluateEntryConditions(type, readChat);
    if (config.present) tools = await _resolveRegistry(_currentEntryPreset());
  }

  Future<void> _evaluateEntryConditions(String type, List<Map<String, Object?>> Function() readChat) async {
    if (!config.present) return;
    check();
    engine._clearSPresetEntryDecisions(chatId);
    _entryDecisions = null;
    final selectedProvider = provider;
    final entries = _spRows(preset['prompts']).where((entry) => presetTruthy(entry['spreset_condition_enabled']));
    final evaluated = <String, bool>{};
    for (final entry in entries) {
      check();
      final identifier = _spString(entry['identifier']);
      try {
        final response = await evaluate('EntryCondition', _spString(entry['spreset_condition_script']), [
          {
            'model': selectedProvider.model,
            'provider': selectedProvider.toJson(),
            'source': selectedProvider.source,
            'type': type,
            'entry': entry,
            // The fixed source captures context/provider once but clones its
            // live chat immediately before each awaited condition invocation.
            'chat': readChat(),
          },
        ], identifier: identifier);
        if (response.value is! bool) {
          throw const SPresetException('EntryCondition', 'Entry condition must return boolean.');
        }
        evaluated[identifier] = response.value! as bool;
      } catch (error) {
        cancellation.check();
        diagnose('EntryCondition', error);
        evaluated[identifier] = false;
      }
    }
    check();
    _entryDecisions = Map.unmodifiable(evaluated);
    // An unrelated STOP clears the current map without cancelling this live
    // evaluator. It may publish on completion, as the source listener does.
    if (chatId.isNotEmpty) engine._spresetEntryGenerations[chatId] = this;
  }

  // An unscoped legacy native request owns only its freshly evaluated map;
  // Helper never evaluates one. Neither path borrows or publishes a chat map.
  Map<String, Object?> _currentEntryPreset() => _presetWithSPresetEntryDecisions({
    ...preset,
    'prompt_order': _originalPromptOrder,
  }, chatId.isEmpty ? _entryDecisions : engine._currentSPresetEntryDecisions(chatId));

  Future<List<SPresetTool>> _resolveRegistry(Map<String, Object?> effective, {String mode = 'sync'}) async {
    cancellation.check();
    if (!_hasEnabledToolBindings) return const [];
    check();
    if (mode != 'sync' && !_registryModes.contains(mode)) {
      final error = SPresetException('ToolBindings', 'The App host has not advertised tool registry mode $mode.');
      diagnose('ToolBindings', error);
      throw error;
    }
    final resolved = await resolveSPresetTools(
      config,
      effective,
      evaluate,
      diagnose,
      synchronizeEmpty: host is TavernSPresetScriptHost,
      registryMode: mode,
      onRegistryModes: _registryModes.addAll,
    );
    check();
    final offered = <SPresetTool>[];
    for (final tool in resolved) {
      if (_reservedNativeToolNames.contains(tool.name)) {
        if (_reportedNativeToolConflicts.add((tool.identifier, tool.name))) {
          diagnose(
            'ToolBindings',
            SPresetException('ToolBindings', 'Tool name conflicts with a reserved native tool: ${tool.name}'),
          );
        }
      } else {
        offered.add(tool);
      }
    }
    return offered;
  }

  Future<Map<String, Object?>> preparePreset(
    String type,
    List<Map<String, Object?>> Function() readChat, {
    _SPresetPromptPath path = _SPresetPromptPath.native,
  }) async {
    check();
    if (path == _SPresetPromptPath.native && !_nativeEntryPhase) {
      // Legacy explicit/private API preparation has no public START phase.
      // Only the actual public native lifecycle calls beginNativeEntries.
      await _evaluateEntryConditions(type, readChat);
    }
    if (!config.present) return preset;
    final forced = config.forcedPostProcessing;
    if (forced != null) preset['custom_prompt_post_processing'] = forced;
    // START handlers or a nested Helper STOP may have cleared/replaced the
    // shared map. Never republish the earlier private evaluation here.
    final effective = _currentEntryPreset();
    final applyToPrompt = switch (path) {
      _SPresetPromptPath.native || _SPresetPromptPath.helperPreset => true,
      _SPresetPromptPath.helperRaw => false,
    };
    if (applyToPrompt) preset['prompt_order'] = effective['prompt_order'];
    tools = _nativeEntryPhase
        ? _nativeRegistryPhases && canPerformTools
              ? await _resolveRegistry(effective, mode: 'read')
              : const []
        : await _resolveRegistry(effective);
    check();
    return preset;
  }

  Future<PromptAssembly> selectNativeWireTools(PromptAssembly original, PromptInput input) async {
    cancellation.check();
    if (!_nativeRegistryPhases || !config.present || !canPerformTools) return original;
    check();
    // Source wire selection follows GENERATE_AFTER_DATA. It reads the current
    // shared registry, not this generation's earlier budget-time tool list.
    tools = await _resolveRegistry(_currentEntryPreset(), mode: 'read');
    final offered = offerTools(_nativeToolRows);
    final body = _captureScriptObject(original.body);
    if (offered.isEmpty) {
      body.remove('tools');
      body.remove('tool_choice');
    } else {
      body['tools'] = offered;
      if (input.toolChoice != null || tools.isNotEmpty) body['tool_choice'] = input.toolChoice ?? 'auto';
    }
    return PromptAssembly(
      body: body,
      beforePostProcessing: original.beforePostProcessing,
      afterPostProcessing: original.afterPostProcessing,
      excluded: original.excluded,
      budget: original.budget,
      remainingBudget: original.remainingBudget,
      counterName: original.counterName,
      exactTokenCounts: original.exactTokenCounts,
      historyWindow: original.historyWindow,
    );
  }

  List<Map<String, Object?>> offerTools(List<Map<String, Object?>> native) {
    if (_nativeEntryPhase) _nativeToolRows = [for (final row in native) _captureScriptObject(row)];
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

  // The fixed ST postProcessPrompt switch returns its input for every other
  // value, including unknown/none modes. DeepSeek still has its own conversion.
  bool allowsRawMessageArray(String mode) =>
      !model.deepseek &&
      !const {
        'merge',
        'claude',
        'merge_tools',
        'semi',
        'semi_tools',
        'strict',
        'strict_tools',
        'single',
      }.contains(mode);

  Future<PromptAssembly> assembly(PromptAssembly original, PromptInput input, PromptTokenCounter counter) async {
    cancellation.check();
    if (!config.present) return original;
    final squash = config.chatSquash;
    if (!presetTruthy(squash['enabled']) && !presetTruthy(squash['squashed_post_script_enable'])) return original;
    List<Object?>? rawMessages;
    final segments = await spresetSquashSegments(
      original.beforePostProcessing,
      config,
      counter,
      expand: (text) => input.expansion?.call(text, const {}) ?? text,
      evaluate: evaluate,
      diagnose: diagnose,
      readPromptManager: () => _promptManagerSnapshot,
      onUnconvertedMessages: allowsRawMessageArray(_spString(input.preset.settings['custom_prompt_post_processing']))
          ? (messages) => rawMessages = messages
          : null,
    );
    cancellation.check();
    if (rawMessages != null) {
      // Admission/token provenance predates GENERATE_AFTER_DATA, as in ST.
      // body carries the later script result to FinalRequestProcessing.
      return PromptAssembly(
        body: {...original.body, 'messages': rawMessages},
        beforePostProcessing: original.beforePostProcessing,
        afterPostProcessing: original.afterPostProcessing,
        excluded: original.excluded,
        budget: original.budget,
        remainingBudget: original.remainingBudget,
        counterName: original.counterName,
        exactTokenCounts: original.exactTokenCounts,
        historyWindow: original.historyWindow,
      );
    }
    return reprocessPromptAssembly(original, segments, input, counter: counter);
  }

  Future<Map<String, Object?>> request(
    Map<String, Object?> body, {
    bool prepared = false,
    String? requestSource,
    void Function(Map<String, Object?>)? validateFinalBody,
  }) async {
    cancellation.check();
    final base = prepared ? _captureScriptObject(body) : prepareModelRequestBody(model, body);
    if (!config.present && host is! TavernSPresetRequestObserver) return base;
    if (config.present) {
      spresetApplyStops(config, base);
    }
    if (_nativeRegistryPhases && config.present && (canPerformTools || _registryModes.contains('refresh'))) {
      // SETTINGS_READY refresh occurs after tools were selected for this
      // body. It changes future registration only; neither the body nor its
      // generation-owned action sessions are rebound from this response.
      await _resolveRegistry(_currentEntryPreset(), mode: 'refresh');
      check();
    }
    Map<String, Object?> finalBody;
    try {
      finalBody = await spresetFinalRequest(config, base, provider, evaluate, requestSource: requestSource);
    } catch (error) {
      diagnose('FinalRequestProcessing', error);
      rethrow;
    }
    cancellation.check();
    validateFinalBody?.call(finalBody);
    final observer = host;
    if (observer is TavernSPresetRequestObserver && _currentPage) {
      await cancellation.wait(
        engine._trackOperation(
          (observer as TavernSPresetRequestObserver).observeSPresetRequest(
            TavernSPresetRequestSnapshot(chatId: chatId, generationId: generationId, body: finalBody),
            token,
          ),
        ),
      );
      cancellation.check();
    }
    if (logEnabled) {
      try {
        await engine._loadSPresetLogs();
        final now = engine._clock().toUtc().toIso8601String();
        engine._spresetLogs.add({
          'id': '$sessionScope:request:${_response + 1}',
          'generationId': generationId,
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
          .where((value) => value['id'] == '$sessionScope:request:$number')
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
    var raw = '';
    var finished = false;
    Map<String, Object?>? originalMessage;
    try {
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
      final frames = consume
          ? _SPresetResponseMetadata(source: provider.source, streamingToolsSupported: _streamingToolsSupported)
          : null;
      _responseMetadata = frames;
      final toolAccumulator = ModelToolAccumulator();
      final fragments = <ModelToolFragment>[];
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
          if (consume && (fragments.isNotEmpty || frames?.observed == true)) {
            if (session.failed) {
              toolFailure = true;
            } else {
              try {
                if (frames?.observed == true && !streaming) {
                  final response = frames!.nonStreamingResponse!;
                  final changed = await consumeResponseTools(response, outputSettings);
                  if (changed != null) {
                    final originalChoice = _spresetPrimaryChoice(response);
                    final choice = _spresetPrimaryChoice(changed);
                    final original = _spMap(originalChoice['message']);
                    final message = _spMap(choice['message']);
                    nonstreamRaw = _spresetResponseText(message['content']);
                    consumed = original.containsKey('tool_calls') || original.containsKey('function_call');
                  }
                } else {
                  List<Object?> calls;
                  if (frames?.observed == true) {
                    calls = frames!.toolCalls;
                  } else if (streaming && !await _readStreamingToolSupport()) {
                    // A legacy custom client has no parsed-frame callback. Its
                    // EOF lookup is a compatibility boundary, not ST's per-frame
                    // sampling. Unconsumed fragments retain native permissions.
                    calls = const [];
                  } else {
                    // Clients without parsed-frame observations retain the
                    // existing fragment contract, with no fabricated signature.
                    final batch = toolAccumulator.finish();
                    if (!batch.finalIdentityComplete ||
                        !batch.originalArgumentsStringComplete ||
                        batch.metadataConflict) {
                      throw const SPresetException(
                        'OutputPreprocessing',
                        'Incomplete tool arguments cannot be consumed.',
                      );
                    }
                    calls = [
                      for (final call in batch.calls)
                        {
                          'id': call.id,
                          'type': 'function',
                          'function': {'name': call.name, 'arguments': call.arguments},
                        },
                    ];
                  }
                  if (calls.isNotEmpty) {
                    final text = await spresetFormatToolCalls(
                      calls,
                      outputSettings,
                      provider,
                      evaluate,
                      stream: streaming,
                      channel: streaming ? 'main' : 'choice:0',
                    );
                    final cumulative = spresetAppendToolText(raw, text);
                    if (streaming) {
                      await session.updateCumulative(cumulative);
                      toolFailure = session.failed;
                    } else {
                      nonstreamRaw = cumulative;
                    }
                    // The formatter sees only supported frame metadata. If
                    // any primary fragment was excluded, retain the complete
                    // native batch and its original authorization/replay path.
                    consumed = !toolFailure && frames?.hasBlockedPrimaryToolFragments != true;
                  }
                }
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
      _responseMetadata = null;
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
  Map<String, Object?> _nativeSPresetPreset(_Turn turn) {
    final raw = _readMap(turn.settings['preset']);
    return {
      ...(raw.isEmpty ? ChatPreset.stDefault().raw : raw),
      if (!raw.containsKey('show_thoughts')) 'show_thoughts': !turn.config.deepseek || turn.config.thinking,
      if (turn.settings['spresetRuntimeMode'] == 'external') 'dsh_spreset_runtime': 'external',
    };
  }

  _SPresetGeneration _createNativeSPreset(_Turn turn, {Map<String, Object?>? preset, SPresetConfig? capturedConfig}) =>
      _SPresetGeneration(
        this,
        chatId: turn.chat.id,
        generationId: turn.generationId,
        cancellation: turn.cancellation,
        settings: turn.settings,
        model: turn.config,
        generationType: turn.generationType,
        presetId: turn.presetId,
        onIssue: turn.hookIssues.add,
        preset: preset ?? _nativeSPresetPreset(turn),
        capturedConfig: capturedConfig,
      );

  Future<void> _beginNativeSPreset(_Turn turn) async {
    final preset = _nativeSPresetPreset(turn);
    final config = SPresetConfig.fromPreset(preset);
    // Ordinary presets keep their existing late host/page capture. Moving
    // that capture would turn a non-SP START host warning into an abort.
    if (!config.present) return;
    final spreset = turn.spreset = _createNativeSPreset(turn, preset: preset, capturedConfig: config);
    await spreset.beginNativeEntries(
      turn.generationType,
      () => [
        for (final node in _store.scriptHistoryTo(turn.chat.id, _store.chatCurrentLeafId(turn.chat.id)))
          {
            'mes': node.message.text,
            'name': node.message.speaker,
            'is_user': node.message.role == TavernRole.user,
            'is_system': _systemMessage(node),
          },
      ],
    );
  }

  Map<String, bool>? _currentSPresetEntryDecisions(String chatId) {
    if (chatId.isEmpty) return null;
    final generation = _spresetEntryGenerations[chatId];
    if (generation == null) return null;
    if (generation._closed ||
        generation.cancellation.isCancelled ||
        generation.token.isCancelled ||
        generation.hostVersion != _scripts._hostVersion ||
        generation.pageEpoch != (_spresetPageEpochs[chatId] ?? 0) ||
        !identical(generation.host, _scripts._host)) {
      _clearSPresetEntryDecisions(chatId);
      return null;
    }
    return generation._entryDecisions;
  }

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

Map<String, Object?> _presetWithSPresetEntryDecisions(Map<String, Object?> preset, Map<String, bool>? decisions) {
  if (decisions == null || decisions.isEmpty) return preset;
  return {
    ...preset,
    'prompt_order': [
      for (final group in _spRows(preset['prompt_order']))
        {
          ...group,
          'order': [
            for (final row in _spRows(group['order']))
              {...row, if (decisions.containsKey(row['identifier'])) 'enabled': decisions[row['identifier']]},
          ],
        },
    ],
  };
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
