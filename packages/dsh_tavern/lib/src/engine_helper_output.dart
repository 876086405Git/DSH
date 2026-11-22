part of 'engine.dart';

extension _HelperOutput on _HelperRequestRuntime {
  Stream<({ModelDelta delta, String? text})> output(Stream<({ModelDelta delta, String? text})> source) async* {
    if (!options.stream) {
      yield* source;
      return;
    }
    final power = _map(record.capture!.settings['power_user']);
    final interval = 1000 / presetJsNumber(power.containsKey('streaming_fps') ? power['streaming_fps'] : 30);
    progressInterval = interval.isFinite && interval > 0 ? interval.toDouble() : 1;
    lastProgressAt = owner.engine._clock().millisecondsSinceEpoch;
    var finalized = false;
    await for (final packet in source) {
      record.cancellation.check();
      if (packet.delta case ModelText(:final text)) {
        outputRaw = packet.text ?? '$outputRaw$text';
      } else if (packet.delta case ModelReasoning(:final text)) {
        outputReasoning += text;
      } else if (packet.delta is ModelFinished) {
        await _progress(finalChunk: true);
        finalized = true;
      }
      yield packet;
    }
    if (!finalized) {
      await _progress(finalChunk: true);
    }
  }

  Future<void>? frame(int attempt, bool streaming, Map<String, Object?> value) {
    response?.decodedFrame(attempt, streaming, value);
    return streaming && options.stream ? _tick() : null;
  }

  Future<void> _tick() async {
    record.cancellation.check();
    final now = owner.engine._clock().millisecondsSinceEpoch;
    if (now - lastProgressAt < progressInterval) return;
    await _progress(finalChunk: false);
    // Fixed ST Stopwatch reads the clock after the action has completed.
    lastProgressAt = owner.engine._clock().millisecondsSinceEpoch;
  }

  Future<void> _progress({required bool finalChunk}) async {
    final addition = outputRaw.substring(min(emittedTextLength, outputRaw.length));
    emittedTextLength = outputRaw.length;
    var incremental = await _cleanOutput(addition, incomplete: !finalChunk, phase: 'incremental');
    if (!finalChunk) {
      for (final marker in const ['*', '"', '```']) {
        if ((incremental.split(marker).length - 1).isOdd) {
          incremental = '${trimEndJsWhitespace(incremental)}${marker.length > 1 ? '\n' : ''}$marker';
        }
      }
    }
    record.cancellation.check();
    owner._generationNotify(record, 'STREAM_TOKEN_RECEIVED_FULLY', [outputRaw, record.id]);
    owner._generationNotify(record, 'STREAM_TOKEN_RECEIVED_INCREMENTALLY', [incremental, record.id]);
    owner._generationNotify(record, 'REASONING_TOKEN_RECEIVED_FULLY', [outputReasoning, record.id]);
    owner._generationNotify(record, 'REASONING_TOKEN_RECEIVED_INCREMENTALLY', [
      outputReasoning.substring(min(emittedReasoningLength, outputReasoning.length)),
      record.id,
    ]);
    emittedReasoningLength = outputReasoning.length;
    if (finalChunk) {
      final cleaned = await _cleanOutput(outputRaw, incomplete: false, phase: 'final');
      record.cancellation.check();
      // Upstream changes only the progress object's text. Its accumulated
      // result remains raw and wrapStreamingResult returns that raw value.
      endedText = cleaned;
    }
  }

  Future<String> _cleanOutput(String text, {required bool incomplete, required String phase}) async {
    if (text.isEmpty) return '';
    final settled = Completer<void>();
    final pending = outputPending = settled.future;
    try {
      return await owner._cleanHelperOutput(record, text, incomplete: incomplete, phase: phase);
    } finally {
      // Cancellation may wait on the actual effect unit. Always settle the
      // marker, including errors; its caller owns the original error channel.
      settled.complete();
      if (identical(outputPending, pending)) outputPending = null;
    }
  }
}

extension _HelperOutputEffects on _ScriptCoordinator {
  Future<String> _cleanHelperOutput(
    _ScriptGenerationRecord record,
    String text, {
    required bool incomplete,
    required String phase,
  }) async {
    record.cancellation.check();
    final capture = record.capture!;
    final policy = _HelperCleanupPolicy(capture.settings);
    final scope = _ScriptEffectScope.publicMacro(this, record.context);
    unawaited(
      record.cancellation.whenCancelled.then((_) {
        if (!scope.ended) scope.token!.cancel();
      }),
    );
    record.receipt.phase = 'helperOutputCleanup';
    try {
      final unit = await _bridgeOperation(
        () => _captureScriptMacroUnit(
          scope,
          frozenGeneration: capture,
          collapseNewlinesOverride: policy.cleanup.collapseNewlines,
        ),
      );
      scope.checkAlive();
      record.cancellation.check();
      final environment = unit.environment;
      final cleaned = stCleanUpMessage(
        text,
        options: policy.cleanup,
        expand: (value) => environment.expand(value, const {}),
        stoppingStrings: () => policy.stoppingStrings(environment),
        outputRegex: (value) => environment.regex.apply(
          value,
          placement: RegexPlacement.aiOutput,
          phase: RegexPhase.writeBack,
          expand: environment.regexExpand,
        ),
        userName: () => environment.userName,
        characterName: () => unit.characterName,
        groupNames: () => capture.groupView?.names ?? const [],
        isGroup: capture.groupView != null,
        // Fixed Helper passes five positional arguments. ST 1.19's legacy
        // adapter assigns the three omitted trailing arguments to undefined.
        includeUserPromptBias: false,
        displayIncompleteSentences: incomplete,
        trimNames: false,
        trimWrongNames: false,
      );
      unit.checkDependencies();
      scope.checkAlive();
      record.cancellation.check();
      await _commitCapturedMacroUnit(
        unit,
        stage: TavernSlashEffectStage.outputCleanup,
        operation: 'helperOutputCleanup',
      );
      record.cancellation.check();
      return cleaned;
    } catch (error, stack) {
      scope.observe(error);
      Error.throwWithStackTrace(_scriptEffectException(scope, _scriptFailure(error)), stack);
    } finally {
      record.hookIssues.addAll(scope.issues);
      if (scope.committed) {
        record.hookIssues.add(
          TavernScriptIssue(
            code: 'helperOutputEffects',
            message: 'The Helper output cleanup committed actual variable effects.',
            committed: true,
            contextId: record.context.value.id,
            generationId: record.id,
            stage: 'outputCleanup',
            details: {'phase': phase},
          ),
        );
      }
      scope.finish();
    }
  }
}

class _HelperCleanupPolicy {
  _HelperCleanupPolicy(Map<String, Object?> settings) : power = _map(settings['power_user']);
  final Map<String, Object?> power;
  bool flag(String key, bool fallback) => presetTruthy(power.containsKey(key) ? power[key] : fallback);
  StOutputCleanupOptions get cleanup => StOutputCleanupOptions(
    collapseNewlines: flag('collapse_newlines', false),
    trimSentences: flag('trim_sentences', false),
    trimSpaces: flag('trim_spaces', true),
    allowUserName: flag('allow_name1_display', false),
    allowCharacterName: flag('allow_name2_display', false),
    fixMarkdown: flag('auto_fix_generated_markdown', true),
    disableGroupTrimming: flag('disable_group_trimming', false),
    userPromptBias: '',
  );
  List<String> stoppingStrings(_MacroEnvironment environment) {
    Object? decoded;
    try {
      decoded = jsonDecode(_string(power['custom_stopping_strings']));
    } on FormatException {
      decoded = null;
    }
    if (decoded is! List<Object?>) return const [];
    return [
      for (final value in decoded)
        if (value is String && value.isNotEmpty)
          flag('custom_stopping_strings_macro', true) ? environment.expand(value, const {}) : value,
    ];
  }
}
