import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

void main() {
  test('Helper intermediate cleanup retains an actual storage failure across the owned model-frame callback', () async {
    final h = await generationFixture();
    await h.engine.setSettings({
      'globalRegexScripts': [_outputRegex('{{incglobalvar::cleanupWrites}}')],
    });
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'frame-storage-error'));
    final plan = h.stream();
    final generation = await h.bridge.generateRaw(context.id, _raw('frame-storage-error'));
    await generationSignal(generation, plan.listening.future);
    final original = await File('${h.root.path}/settings.json').readAsBytes();
    final blocker = Directory('${h.root.path}/settings.json.writing');
    await blocker.create();
    try {
      h.now = h.now.add(const Duration(milliseconds: 40));
      plan.delta('X');
      plan.finish();
      final failure = await generationFailure(generation);
      expect(failure.code, TavernScriptErrorCode.storage);
      expect(failure.modelFailure, isNull, reason: 'An output storage failure is not a network/parser failure.');
      expect(failure.committed, isFalse);
      expect(h.engine.globalVariables.containsKey('cleanupWrites'), isFalse);
      expect(await File('${h.root.path}/settings.json').readAsBytes(), original);
      expect(h.requests, hasLength(1), reason: 'Owned callback failures must not retry the accepted response.');
    } finally {
      await blocker.delete(recursive: true);
    }
  });

  for (final intermediate in [false, true]) {
    test('Helper real SSE matches source progress throttle and cleanup order (intermediate=$intermediate)', () async {
      final h = await generationFixture();
      await h.engine.setSettings({
        'power_user': {
          'streaming_fps': 30,
          'trim_spaces': true,
          'auto_fix_generated_markdown': false,
          'custom_stopping_strings': '["{{incglobalvar::cleanupReads}}STOP"]',
          'custom_stopping_strings_macro': true,
        },
      });
      final trace = <ScriptJson>[];
      final firstProgress = Completer<void>();
      final host = ScriptHost();
      host.onDispatch = (request, token) async {
        if (request.name != null && request.name != 'GENERATION_STARTED') {
          trace.add({'name': request.name, 'args': request.args, 'reads': h.engine.globalVariables['cleanupReads']});
        }
        if (request.name == 'REASONING_TOKEN_RECEIVED_INCREMENTALLY' && !firstProgress.isCompleted) {
          firstProgress.complete();
        }
        return TavernScriptDispatchAck(eventId: request.eventId);
      };
      h.bridge.attachHost(host);
      final context = await h.bridge.openContext(TavernScriptContextSpec(instanceId: 'clock-$intermediate'));
      final plan = h.stream();
      final generation = await h.bridge.generateRaw(context.id, _raw('clock-$intermediate'));
      await generationSignal(generation, plan.listening.future);
      final base = h.now;
      await _frame(h, plan, generation, base, intermediate ? 10 : 0, '  A', '  A');
      await _frame(
        h,
        plan,
        generation,
        base,
        intermediate ? 20 : 10,
        'B',
        '  AB',
        reasoning: intermediate ? 'r' : null,
      );
      expect(trace, isEmpty, reason: 'Stopwatch skips early frames; it does not sleep or clean each fragment.');
      await _frame(
        h,
        plan,
        generation,
        base,
        intermediate ? 40 : 20,
        intermediate ? 'C' : 'C  ',
        intermediate ? '  ABC' : '  ABC  ',
      );
      if (intermediate) {
        // Await an actual event, without advancing the injected clock.
        await generationSignal(generation, firstProgress.future);
        expect(trace.map((row) => row['reads']), everyElement(1));
        await _frame(h, plan, generation, base, 50, ' D  ', '  ABC D  ', reasoning: 's');
      }
      plan.finish();
      final result = await generation.result;
      await Future<void>.delayed(Duration.zero);
      final count = intermediate ? 3 : 2;
      expect(h.engine.globalVariables['cleanupReads'], count);
      final increments = trace.where((row) => row['name'] == 'STREAM_TOKEN_RECEIVED_INCREMENTALLY').toList();
      expect(increments.map((row) => (row['args']! as List<Object?>).first), intermediate ? ['ABC', 'D'] : ['ABC']);
      final names = trace.map((row) => row['name']).toList();
      const progress = [
        'STREAM_TOKEN_RECEIVED_FULLY',
        'STREAM_TOKEN_RECEIVED_INCREMENTALLY',
        'REASONING_TOKEN_RECEIVED_FULLY',
        'REASONING_TOKEN_RECEIVED_INCREMENTALLY',
      ];
      expect(names, [if (intermediate) ...progress, ...progress, 'GENERATION_BEFORE_END', 'GENERATION_ENDED']);
      expect(
        trace[trace.length - 3]['reads'],
        count - 1,
        reason: 'The final four progress notifications precede the full-output cleanup.',
      );
      expect(trace.last['reads'], count);
      expect(result.text, intermediate ? '  ABC D  ' : '  ABC  ');
      expect((trace.last['args']! as List<Object?>).first, intermediate ? 'ABC D' : 'ABC');
      if (intermediate) {
        expect(
          trace
              .where((row) => row['name'] == 'REASONING_TOKEN_RECEIVED_INCREMENTALLY')
              .map((row) => (row['args']! as List<Object?>).first),
          ['r', 's'],
        );
      }
    });
  }

  test(
    'Helper stream cleanup keeps raw result, cleans events, and executes fresh stopping macros for each nonempty call',
    () async {
      final h = await generationFixture();
      await h.engine.setSettings({
        'power_user': {
          'trim_spaces': true,
          'auto_fix_generated_markdown': false,
          'user_prompt_bias': '{{incglobalvar::unusedBias}}',
          'custom_stopping_strings': '["{{incglobalvar::cleanupReads}}STOP"]',
          'custom_stopping_strings_macro': true,
        },
      });
      final host = ScriptHost();
      final incremental = Completer<TavernScriptDispatch>();
      host.onDispatch = (request, token) async {
        if (request.name == 'STREAM_TOKEN_RECEIVED_INCREMENTALLY' && !incremental.isCompleted) {
          incremental.complete(request);
        }
        return TavernScriptDispatchAck(eventId: request.eventId);
      };
      h.bridge.attachHost(host);
      final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'cleanup-events'));
      final plan = h.stream();
      final generation = await h.bridge.generateRaw(context.id, _raw('cleanup-events'));
      await generationSignal(generation, plan.listening.future);
      h.now = h.now.add(const Duration(milliseconds: 40));
      plan.delta('  User: *hello  ');
      final delta = await generationSignal(generation, incremental.future);
      expect(delta.args, ['User: *hello*', generation.id]);
      plan.finish();
      final result = await generation.result;
      await Future<void>.delayed(Duration.zero);
      expect(result.toHelperValue(), '  User: *hello  ');
      expect(host.deliveries.singleWhere((event) => event.name == 'GENERATION_ENDED').args, [
        'User: *hello',
        generation.id,
      ]);
      expect(host.deliveries.singleWhere((event) => event.name == 'GENERATION_BEFORE_END').args.first, {
        'message': 'User: *hello',
      });
      expect(h.engine.globalVariables['cleanupReads'], 2);
      expect(
        h.engine.globalVariables.containsKey('unusedBias'),
        isFalse,
        reason: 'The fixed five-positional-argument compatibility branch does not enable user_prompt_bias.',
      );
      expect(scriptMap((await h.settingsDocument())['globalVariables'])['cleanupReads'], 2);
      expect(result.hookIssues.where((issue) => issue.code == 'helperOutputEffects'), hasLength(2));
    },
  );

  test('Helper stop during cleanup expansion prevents its unentered storage effect', () async {
    final h = await generationFixture();
    await h.engine.setSettings({
      'globalRegexScripts': [_outputRegex('{{random::A::B}}{{incglobalvar::cleanupWrites}}')],
    });
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'cleanup-stop-before'));
    final control = h.bridge as TavernHelperGenerationControl;
    var cancelledAtMacro = false;
    h.onRandom = () {
      cancelledAtMacro = true;
      unawaited(control.stopHelperGenerationById('cleanup-stop-before'));
    };
    final plan = h.stream();
    final generation = await h.bridge.generateRaw(context.id, _raw('cleanup-stop-before'));
    await generationSignal(generation, plan.listening.future);
    plan.delta('X');
    plan.finish();
    final failure = await generationFailure(generation);
    expect(cancelledAtMacro, isTrue);
    expect(failure.code, TavernScriptErrorCode.cancelled);
    expect(failure.committed, isFalse);
    expect(h.engine.globalVariables.containsKey('cleanupWrites'), isFalse);
    expect(scriptMap((await h.settingsDocument())['globalVariables']).containsKey('cleanupWrites'), isFalse);
  });

  test(
    'Helper cancellation and engine close drain an actual renamed output carrier before reporting its committed result',
    () async {
      final gate = _RenameGate();
      await IOOverrides.runWithIOOverrides(() async {
        final h = await generationFixture();
        await h.engine.setSettings({
          'globalRegexScripts': [_outputRegex('{{incglobalvar::cleanupWrites}}')],
        });
        final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'cleanup-stop-after'));
        final control = h.bridge as TavernHelperGenerationControl;
        final plan = h.stream();
        final generation = await h.bridge.generateRaw(context.id, _raw('cleanup-stop-after'));
        var resultDone = false;
        unawaited(
          generation.result.then<void>(
            (_) {
              resultDone = true;
            },
            onError: (Object _, StackTrace _) {
              resultDone = true;
            },
          ),
        );
        await generationSignal(generation, plan.listening.future);
        gate.armed = true;
        try {
          plan.delta('X');
          plan.finish();
          await generationSignal(generation, gate.entered.future);
          expect(
            scriptMap((await h.settingsDocument())['globalVariables'])['cleanupWrites'],
            1,
            reason: 'The real settings file has already been renamed; only its returned Future is held.',
          );
          expect(await control.stopHelperGenerationById('cleanup-stop-after'), isTrue);
          var closeDone = false;
          final closing = h.close().then((_) {
            closeDone = true;
          });
          await Future<void>.delayed(Duration.zero);
          expect(resultDone, isFalse, reason: 'Cancellation must wait for the already-entered output carrier.');
          expect(closeDone, isFalse);
          gate.release.complete();
          final failure = await generationFailure(generation);
          expect(failure.code, TavernScriptErrorCode.cancelled);
          expect(failure.committed, isTrue);
          expect(failure.issues.any((issue) => issue.code == 'helperOutputEffects' && issue.committed), isTrue);
          await closing;
          expect(scriptMap((await h.settingsDocument())['globalVariables'])['cleanupWrites'], 1);
        } finally {
          if (!gate.release.isCompleted) gate.release.complete();
        }
      }, gate);
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );
  test('Helper admits a reused ID while the cancelled old output carrier is still draining', () async {
    final gate = _RenameGate();
    await IOOverrides.runWithIOOverrides(() async {
      final h = await generationFixture();
      await h.engine.setSettings({
        'globalRegexScripts': [_outputRegex('{{incglobalvar::cleanupWrites}}')],
      });
      final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'preterminal-reuse'));
      final control = h.bridge as TavernHelperGenerationControl;
      final oldPlan = h.stream();
      final old = await h.bridge.generateRaw(context.id, _raw('reused-helper-id'));
      var oldSettled = false;
      unawaited(
        old.result.then<void>(
          (_) => oldSettled = true,
          onError: (Object _, StackTrace _) {
            oldSettled = true;
          },
        ),
      );
      await generationSignal(old, oldPlan.listening.future);
      gate.armed = true;
      try {
        oldPlan.delta('X');
        oldPlan.finish();
        await generationSignal(old, gate.entered.future);
        expect(await control.stopHelperGenerationById(old.id), isTrue);
        expect(oldSettled, isFalse);
        final nextPlan = h.stream();
        final next = await h.bridge.generateRaw(context.id, _raw(old.id));
        expect(identical(next, old), isFalse);
        expect(oldSettled, isFalse, reason: 'Admission occurs before the old terminal result, not after it.');
        expect(control.helperGenerationState.activeIds, [next.id]);
        gate.release.complete();
        final oldFailure = await generationFailure(old);
        expect(oldFailure.code, TavernScriptErrorCode.cancelled);
        expect(oldFailure.committed, isTrue);
        expect(control.helperGenerationState.activeIds, [
          next.id,
        ], reason: 'Old finish must not remove the new record.');
        await generationSignal(next, nextPlan.listening.future);
        nextPlan.delta('NEW');
        nextPlan.finish();
        expect((await next.result).text, 'NEW');
        expect(control.helperGenerationState.activeIds, isEmpty);
        expect(h.engine.globalVariables['cleanupWrites'], 1);
      } finally {
        if (!gate.release.isCompleted) gate.release.complete();
      }
    }, gate);
  }, timeout: const Timeout(Duration(seconds: 15)));
}

Future<void> _frame(
  ScriptFixture h,
  ScriptResponsePlan plan,
  TavernScriptGeneration generation,
  DateTime base,
  int at,
  String chunk,
  String cumulative, {
  String? reasoning,
}) async {
  h.now = base.add(Duration(milliseconds: at));
  final adopted = generation.events.firstWhere((event) => event.text == cumulative);
  generationSse(plan, {
    'choices': [
      {
        'index': 0,
        'delta': {'content': chunk, 'reasoning_content': ?reasoning},
      },
    ],
  });
  await generationSignal(generation, adopted);
  // Drain this frame's remaining microtasks before moving the controlled
  // clock. This is a zero-duration event turn, not wall-clock timing evidence.
  await Future<void>.delayed(Duration.zero);
}

TavernHelperRawRequest _raw(String id) => TavernHelperRawRequest.fromJson({
  'generation_id': id,
  'should_stream': true,
  'ordered_prompts': [
    {'role': 'user', 'content': 'Q'},
  ],
});

ScriptJson _outputRegex(String replacement) => {
  'id': 'helper-output',
  'scriptName': 'helper-output',
  'findRegex': 'X',
  'replaceString': replacement,
  'placement': [RegexPlacement.aiOutput],
  'markdownOnly': false,
  'promptOnly': false,
  'disabled': false,
  'runOnEdit': false,
  'substituteRegex': 0,
  'trimStrings': <Object?>[],
};

/// Delays the returned Future only after the real file rename. Every byte is
/// written by dart:io; this is an I/O completion barrier, not a persistence fake.
final class _RenameGate extends IOOverrides {
  bool armed = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  File createFile(String path) {
    final real = super.createFile(path);
    return path.endsWith('/settings.json.writing') ? _SettingsTemporary(real, this) : real;
  }
}

class _SettingsTemporary implements File {
  _SettingsTemporary(this.real, this.gate);
  final File real;
  final _RenameGate gate;
  @override
  String get path => real.path;
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    await real.writeAsString(contents, mode: mode, encoding: encoding, flush: flush);
    return this;
  }

  @override
  Future<File> rename(String newPath) async {
    final result = await real.rename(newPath);
    if (gate.armed) {
      gate.armed = false;
      gate.entered.complete();
      await gate.release.future;
    }
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected temporary File operation: ${invocation.memberName}');
}
