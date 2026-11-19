import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dsh_tavern/src/macros/macro_engine.dart';
import 'package:dsh_tavern/src/regex/regex_engine.dart';
import 'package:dsh_tavern/src/regex/regex_worker.dart';
import 'package:test/test.dart';

void main() {
  late RegexWorker worker;
  setUpAll(() => worker = RegexWorker());
  tearDownAll(() => worker.close());
  final fixture = jsonDecode(File('test/fixtures/regex-oracle.json').readAsStringSync()) as Map<String, Object?>;
  final cases = (fixture['cases']! as List).cast<Map<String, Object?>>();
  for (final testCase in cases) {
    test('protected capture ST oracle: ${testCase['name']}', () async {
      final expected = testCase['expected']! as Map<String, Object?>;
      final events = <Map<String, Object?>>[];
      var counter = 0;
      String expand(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) {
        events.add({'text': text, 'characterOverride': characterOverride, 'postProcess': postProcess != null});
        return text.replaceAllMapped(RegExp(r'\{\{([a-z]+)\}\}', caseSensitive: false), (match) {
          final name = match[1]!.toLowerCase();
          final macros = (testCase['macros'] as Map?)?.cast<String, Object?>() ?? <String, Object?>{};
          final values = <String, Object?>{'user': 'User', 'char': 'Character', ...macros};
          if (characterOverride != null) {
            values['char'] = characterOverride;
          }
          if (name != 'inc' && !values.containsKey(name)) {
            return match[0]!;
          }
          final value = name == 'inc' ? (++counter).toString() : values[name];
          return (postProcess == null ? value : postProcess(value)).toString();
        });
      }

      // Preserve each fixture's original admitted set, then route those rules
      // through the protected display execution path. This reuses the frozen
      // ST output/event oracle without claiming prompt/write-back is isolated.
      final placement = (testCase['placement'] as num? ?? 1).toInt();
      final engine = RegexEngine(
        globalScripts: _oracleScripts(testCase, 'global', placement),
        presetScripts: _oracleScripts(testCase, 'preset', placement),
        characterScripts: _oracleScripts(testCase, 'character', placement),
        enabled: testCase['direct'] == true || testCase['enabled'] != false,
      );
      final result = await engine.applyDisplay(
        testCase['input']! as String,
        placement: placement,
        worker: worker,
        isEdit: testCase['isEdit'] == true,
        depth: testCase['direct'] == true || (testCase['phase'] ?? 'writeBack') == 'writeBack'
            ? null
            : testCase['depth'] as num?,
        characterOverride: testCase['characterOverride'] as String?,
        expand: expand,
      );
      if (expected.containsKey('error')) {
        expect(result.warnings.any((warning) => warning.reason == 'replacement-error'), isTrue);
        expect(result.text, testCase['input']);
      } else {
        expect(result.text, expected['output']);
      }
      expect(counter, expected['counter']);
      expect(events, expected['events']);
    });
  }

  test('display eligibility keeps source order, depth and edit filters', () async {
    final engine = RegexEngine(
      globalScripts: [
        _script(pattern: 'x', replacement: 'A'),
        _script(pattern: 'A', replacement: 'bad', patch: {'markdownOnly': false, 'promptOnly': true}),
      ],
      presetScripts: [
        _script(pattern: 'A', replacement: 'B', patch: {'minDepth': 1, 'maxDepth': 2}),
      ],
      characterScripts: [
        _script(pattern: 'B', replacement: 'C', patch: {'runOnEdit': true}),
      ],
    );
    expect((await engine.applyDisplay('x', placement: 1, worker: worker, depth: 1)).text, 'C');
    expect((await engine.applyDisplay('x', placement: 1, worker: worker, depth: 0)).text, 'A');
    expect((await engine.applyDisplay('B', placement: 1, worker: worker, isEdit: true)).text, 'C');
    expect((await engine.applyDisplay('x', placement: 2, worker: worker)).text, 'x');
    expect(engine.apply('x', placement: 1), 'x');
  });

  test('expanded patterns are checked anew while each replacement macro runs once', () async {
    final context = MacroContext(localVariables: {'n': 0, 'key': 'x'});
    var patterns = 0;
    final engine = RegexEngine(
      globalScripts: [
        _script(pattern: '/{{getvar::key}}/g', replacement: r'{{incvar::n}}-$0', patch: {'substituteRegex': 2}),
      ],
    );
    String expand(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) {
      if (postProcess != null) {
        patterns++;
      }
      return const MacroEngine().expand(text, context, postProcess: postProcess);
    }

    expect((await engine.applyDisplay('x y', placement: 1, worker: worker, expand: expand)).text, '1-x y');
    context.localVariables['key'] = 'y';
    expect((await engine.applyDisplay('x y', placement: 1, worker: worker, expand: expand)).text, 'x 2-y');
    context.localVariables['key'] = 'x';
    expect((await engine.applyDisplay('x y', placement: 1, worker: worker, expand: expand)).text, '3-x y');
    expect(patterns, 3);
    expect(context.localVariables['n'], 3);
  });

  test('shared replacement plans keep per-worker limits and per-call macro effects', () async {
    final small = RegexWorker(limits: const RegexLimits(maxCaptureBytes: 33));
    addTearDown(small.close);
    var patterns = 0;
    var values = 0;
    final engine = RegexEngine(
      globalScripts: [
        _script(
          pattern: '{{find}}',
          replacement: r'{{unused}}$1',
          patch: {
            'substituteRegex': 1,
            'trimStrings': ['{{trim}}'],
          },
        ),
        _script(pattern: '(x)', replacement: r'{{value}}-{{match}}-$1', patch: {'id': 'active'}),
      ],
    );
    String expand(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) {
      if (text == '{{find}}') {
        patterns++;
        return '(absent)';
      }
      if (text.contains('{{unused}}') || text.contains('{{trim}}')) {
        throw StateError('An unmatched rule must not expand trim or replacement macros.');
      }
      return text.replaceAll('{{value}}', 'v${++values}');
    }

    final rejected = await engine.applyDisplay('x', placement: 1, worker: small, expand: expand);
    expect(rejected.text, 'x');
    expect(rejected.replacements, 0);
    expect(rejected.warnings.single.reason, 'capture-limit');
    expect(rejected.warnings.single.ruleId, 'active');
    final first = await engine.applyDisplay('x', placement: 1, worker: worker, expand: expand);
    expect(first.text, 'v1-x-x');
    expect(first.replacements, 1);
    expect(first.warnings, isEmpty);
    final second = await engine.applyDisplay('x', placement: 1, worker: worker, expand: expand);
    expect(second.text, 'v2-x-x');
    expect(second.warnings, isEmpty);
    final rejectedAgain = await engine.applyDisplay('x', placement: 1, worker: small, expand: expand);
    expect(rejectedAgain.text, 'x');
    expect(rejectedAgain.warnings.single.reason, 'capture-limit');
    expect(patterns, 4);
    expect(values, 2);
  });

  test('named reference budgets reject before replacement effects and remain per worker', () async {
    final small = RegexWorker(limits: const RegexLimits(maxCaptureBytes: 18));
    addTearDown(small.close);
    final missing = List<String>.generate(128, (index) => '\$<missing$index>').join();
    final engine = RegexEngine(
      globalScripts: [
        _script(
          pattern: '(?<letter>x)',
          replacement:
              '$missing{{value}}'
              r'$<letter>$<letter>',
        ),
      ],
    );
    var values = 0;
    String expand(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) =>
        text.replaceAll('{{value}}', 'v${++values}');

    final rejected = await engine.applyDisplay('x', placement: 1, worker: small, expand: expand);
    expect(rejected.text, 'x');
    expect(rejected.replacements, 0);
    expect(rejected.warnings.single.reason, 'capture-limit');
    expect(values, 0);

    final admitted = await engine.applyDisplay('x', placement: 1, worker: worker, expand: expand);
    expect(admitted.text, 'v1xx');
    expect(admitted.replacements, 1);
    expect(admitted.warnings, isEmpty);
    expect(values, 1);

    final rejectedAgain = await engine.applyDisplay('x', placement: 1, worker: small, expand: expand);
    expect(rejectedAgain.text, 'x');
    expect(rejectedAgain.replacements, 0);
    expect(rejectedAgain.warnings.single.reason, 'capture-limit');
    expect(values, 1);
  });

  test('the 201st eligible display rule is skipped with its stable location', () async {
    var calls = 0;
    final engine = RegexEngine(
      globalScripts: [
        for (var index = 0; index < 201; index++)
          _script(pattern: '^', replacement: '+', patch: {'id': 'r$index', 'scriptName': 'rule'}),
      ],
    );
    String expand(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) {
      calls++;
      return text;
    }

    final result = await engine.applyDisplay('x', placement: 1, worker: worker, expand: expand);
    expect(result.text, '${List<String>.filled(200, '+').join()}x');
    expect(calls, 200);
    expect(result.replacements, 200);
    expect(result.warnings.single.toJson(), {
      'ruleId': 'r200',
      'ruleName': 'rule',
      'ruleIndex': 200,
      'reason': 'rule-limit',
      'message': '本次显示已达规则上限，后续规则跳过。',
    });
  });

  test('default raw UTF8 size accepts exactly 512KiB and preserves oversized originals', () async {
    final exact = '${List<String>.filled(174762, '你').join()}ab';
    expect(regexUtf8Length(exact), 512 * 1024);
    final engine = RegexEngine(
      globalScripts: [_script(pattern: 'z', replacement: 'Y')],
    );
    final admitted = await engine.applyDisplay(exact, placement: 1, worker: worker);
    expect(admitted.text, exact);
    expect(admitted.warnings, isEmpty);
    final oversized = await engine.applyDisplay('${exact}c', placement: 1, worker: worker);
    expect(oversized.text, '${exact}c');
    expect(oversized.warnings.single.reason, 'input-limit');
    expect(oversized.warnings.single.ruleIndex, -1);
  });

  test('default output byte bound accepts 2MiB and drops only an overflowing rule', () async {
    final exact = List<String>.filled(2 * 1024 * 1024, 'Y').join();
    final success = RegexEngine(
      globalScripts: [_script(pattern: 'x', replacement: exact)],
    );
    final good = await success.applyDisplay('x', placement: 1, worker: worker);
    expect(good.text.length, exact.length);
    expect(good.warnings, isEmpty);
    final failure = RegexEngine(
      globalScripts: [_script(pattern: 'x', replacement: '$exact!')],
    );
    final failed = await failure.applyDisplay('x', placement: 1, worker: worker);
    expect(failed.text, 'x');
    expect(failed.warnings.single.reason, 'output-limit');
    expect(failed.replacements, 1);
  });

  test('a large intermediate result can shrink in the next rule without raw-input rejection', () async {
    final middle = List<String>.filled(800 * 1024, 'X').join();
    final engine = RegexEngine(
      globalScripts: [
        _script(pattern: 'x', replacement: middle),
        _script(pattern: '^X+', replacement: 'Y'),
      ],
    );
    final result = await engine.applyDisplay('x', placement: 1, worker: worker);
    expect(result.text, 'Y');
    expect(result.warnings, isEmpty);
    expect(result.replacements, 2);
  });

  test('replacement limit is cumulative across rules and includes zero-width matches', () async {
    final exact = List<String>.filled(20000, 'x').join();
    final engine = RegexEngine(
      globalScripts: [
        _script(pattern: '/x/g', replacement: 'y'),
        _script(pattern: '/y/g', replacement: 'z'),
      ],
    );
    final result = await engine.applyDisplay(exact, placement: 1, worker: worker);
    expect(result.text, List<String>.filled(20000, 'y').join());
    expect(result.replacements, 20000);
    expect(result.warnings.single.reason, 'replacement-limit');
    expect(result.warnings.single.ruleIndex, 1);
    final overflow = RegexEngine(
      globalScripts: [_script(pattern: '/x/g', replacement: 'y')],
    );
    final failed = await overflow.applyDisplay('${exact}x', placement: 1, worker: worker);
    expect(failed.text, '${exact}x');
    expect(failed.replacements, 0);
    expect(failed.warnings.single.reason, 'replacement-limit');
    final empty = RegexEngine(
      globalScripts: [_script(pattern: '/(?:)/g', replacement: '-')],
    );
    final zeros = await empty.applyDisplay(exact.substring(1), placement: 1, worker: worker);
    expect(zeros.replacements, 20000);
    expect(zeros.text.length, 39999);
    expect(zeros.warnings, isEmpty);
  });

  test('UTF8 output counting joins surrogate halves across non-unicode match chunks', () async {
    final small = RegexWorker(limits: const RegexLimits(maxInputBytes: 4, maxOutputBytes: 4));
    addTearDown(small.close);
    final engine = RegexEngine(
      globalScripts: [_script(pattern: '/./g', replacement: r'$0')],
    );
    final result = await engine.applyDisplay('😀', placement: 1, worker: small);
    expect(result.text, '😀');
    expect(result.warnings, isEmpty);
    expect(result.replacements, 2);
  });

  test('output failure retains completed text and already executed display effects', () async {
    final small = RegexWorker(limits: const RegexLimits(maxOutputBytes: 8));
    addTearDown(small.close);
    var n = 0;
    final events = <String>[];
    String expand(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) {
      events.add(text);
      return switch (text) {
        '{{first}}' => 'A${++n}',
        '{{overflow}}' => (++n > 0 ? '123456789' : ''),
        '{{last}}' => 'B$n',
        _ => text,
      };
    }

    final engine = RegexEngine(
      globalScripts: [
        _script(pattern: 'x', replacement: '{{first}}'),
        _script(pattern: 'A1', replacement: '{{overflow}}', patch: {'id': 'large'}),
        _script(pattern: 'A1', replacement: '{{last}}'),
      ],
    );
    final result = await engine.applyDisplay('x', placement: 1, worker: small, expand: expand);
    expect(result.text, 'B2');
    expect(n, 2);
    expect(events, ['{{first}}', '{{overflow}}', '{{last}}']);
    expect(result.warnings.single.ruleId, 'large');
    expect(result.warnings.single.reason, 'output-limit');
  });

  test('repeated captures are bounded before building the replacement macro input', () async {
    final small = RegexWorker(limits: const RegexLimits(maxOutputBytes: 12));
    addTearDown(small.close);
    final events = <String>[];
    String expand(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) {
      events.add(text);
      return text == '{{trim}}' ? '' : text;
    }

    final engine = RegexEngine(
      globalScripts: [
        _script(
          pattern: 'abc',
          replacement: r'$0$0$0$0$0',
          patch: {
            'trimStrings': ['{{trim}}'],
            'id': 'expanded',
          },
        ),
        _script(pattern: 'abc', replacement: 'Z'),
      ],
    );
    final result = await engine.applyDisplay('abc', placement: 1, worker: small, expand: expand);
    expect(result.text, 'Z');
    expect(result.replacements, 2);
    expect(events, [...List<String>.filled(5, '{{trim}}'), 'Z']);
    expect(result.warnings.single.ruleId, 'expanded');
    expect(result.warnings.single.reason, 'output-limit');
  });

  test('an existing longer macro template can shrink inside the final output bound', () async {
    final small = RegexWorker(limits: const RegexLimits(maxOutputBytes: 2));
    addTearDown(small.close);
    final events = <String>[];
    String expand(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) {
      events.add(text);
      return text == '{{shrink}}' ? 'Y' : text;
    }

    final engine = RegexEngine(
      globalScripts: [_script(pattern: 'x', replacement: '{{shrink}}')],
    );
    final result = await engine.applyDisplay('x', placement: 1, worker: small, expand: expand);
    expect(result.text, 'Y');
    expect(result.warnings, isEmpty);
    expect(events, ['{{shrink}}']);
  });

  test('timeout drops only its rule and the next rule resumes without macro replay', () async {
    final protected = RegexWorker(spawner: _blockOnePattern());
    addTearDown(protected.close);
    final events = <String>[];
    var effects = 0;
    String expand(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) {
      events.add(text);
      if (text == '{{first}}') {
        effects++;
        return 'A';
      }
      if (text == '{{pattern}}') {
        effects++;
        return 'BLOCK';
      }
      return text == '{{last}}' ? 'B$effects' : text;
    }

    final engine = RegexEngine(
      globalScripts: [
        _script(pattern: 'x', replacement: '{{first}}'),
        _script(pattern: '{{pattern}}', replacement: '{{never}}', patch: {'substituteRegex': 1, 'id': 'slow'}),
        _script(pattern: 'A', replacement: '{{last}}'),
      ],
    );
    final result = await engine.applyDisplay('x', placement: 1, worker: protected, expand: expand);
    expect(result.text, 'B2');
    expect(events, ['{{first}}', '{{pattern}}', '{{last}}']);
    expect(effects, 2);
    expect(result.warnings.single.reason, 'timeout');
    expect(result.warnings.single.ruleId, 'slow');
    expect(result.warnings.single.ruleIndex, 1);
  });

  test('invalid dynamic pattern preserves its expansion effects and successful prior text', () async {
    var effects = 0;
    String expand(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) {
      if (text == '{{invalid}}') {
        effects++;
        return '(';
      }
      return text == '{{seen}}' ? effects.toString() : text;
    }

    final engine = RegexEngine(
      globalScripts: [
        _script(pattern: 'x', replacement: 'A'),
        _script(pattern: '{{invalid}}', replacement: '{{never}}', patch: {'substituteRegex': 1}),
        _script(pattern: 'A', replacement: '{{seen}}'),
      ],
    );
    final result = await engine.applyDisplay('x', placement: 1, worker: worker, expand: expand);
    expect(result.text, '1');
    expect(effects, 1);
    expect(result.warnings.single.reason, 'incompatible-pattern');
  });

  test('cancellation after pattern expansion prevents dispatch and all later macros', () async {
    var cancelled = false;
    var spawns = 0;
    final protected = RegexWorker(
      spawner: (entry, replies, errors, exits) {
        spawns++;
        return Isolate.spawn(entry, replies, onError: errors, onExit: exits);
      },
    );
    addTearDown(protected.close);
    final events = <String>[];
    String expand(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) {
      events.add(text);
      cancelled = true;
      return 'x';
    }

    final engine = RegexEngine(
      globalScripts: [
        _script(pattern: '{{pattern}}', replacement: '{{after}}', patch: {'substituteRegex': 1}),
      ],
    );
    final result = await engine.applyDisplay(
      'x',
      placement: 1,
      worker: protected,
      expand: expand,
      isCancelled: () => cancelled,
    );
    expect(result.cancelled, isTrue);
    expect(result.text, 'x');
    expect(events, ['{{pattern}}']);
    expect(spawns, 0);
  });

  test('cancellation observed after await stops later rules and retains completed text', () async {
    var cancelled = false;
    final protected = RegexWorker(spawner: _blockOnePattern(onBlocked: () => cancelled = true));
    addTearDown(protected.close);
    final events = <String>[];
    String expand(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) {
      events.add(text);
      return text;
    }

    final engine = RegexEngine(
      globalScripts: [
        _script(pattern: 'x', replacement: 'A'),
        _script(pattern: 'BLOCK', replacement: '{{never}}'),
        _script(pattern: 'A', replacement: '{{later}}'),
      ],
    );
    final result = await engine.applyDisplay(
      'x',
      placement: 1,
      worker: protected,
      expand: expand,
      isCancelled: () => cancelled,
    );
    expect(result.cancelled, isTrue);
    expect(result.text, 'A');
    expect(events, ['A']);
  });

  test('legacy sanitizer still receives raw numeric values in the protected display path', () async {
    final context = MacroContext(localVariables: {'x': 1.25});
    final engine = RegexEngine(
      globalScripts: [
        _script(pattern: r'^{{getvar::x}}$', replacement: 'Y', patch: {'substituteRegex': 2}),
      ],
    );
    String modern(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) =>
        const MacroEngine().expand(text, context, postProcess: postProcess);
    String legacy(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) =>
        const LegacyMacroEngine().expand(text, context, postProcess: postProcess);
    expect((await engine.applyDisplay('1x25', placement: 1, worker: worker, expand: legacy)).text, 'Y');
    expect((await engine.applyDisplay('1x25', placement: 1, worker: worker, expand: modern)).text, '1x25');
    expect((await engine.applyDisplay('1.25', placement: 1, worker: worker, expand: modern)).text, 'Y');
  });
}

List<RegexScript> _oracleScripts(Map<String, Object?> fixture, String source, int placement) {
  final original = fixture[source] as List<Object?>? ?? const [];
  final direct = fixture['direct'] == true;
  final phase = fixture['phase'] as String? ?? 'writeBack';
  return [
    for (final item in original)
      (() {
        final raw = item! as Map<String, Object?>;
        final view = RegexScript.fromJson(raw);
        final eligible =
            direct ||
            switch (phase) {
              'writeBack' => !view.markdownOnly && !view.promptOnly,
              'prompt' => view.promptOnly,
              _ => view.markdownOnly,
            };
        return RegexScript.fromJson({
          ...raw,
          'placement': direct ? [placement] : view.placement,
          'markdownOnly': eligible,
          'promptOnly': false,
          'runOnEdit': direct || view.runOnEdit,
          'minDepth': direct || phase == 'writeBack' ? null : view.minDepth,
          'maxDepth': direct || phase == 'writeBack' ? null : view.maxDepth,
        });
      })(),
  ];
}

RegexScript _script({String pattern = '/x/g', String replacement = 'Y', Map<String, Object?> patch = const {}}) =>
    RegexScript.fromJson({
      'id': 'rule',
      'scriptName': 'test',
      'findRegex': pattern,
      'replaceString': replacement,
      'placement': [1],
      'trimStrings': <String>[],
      'markdownOnly': true,
      ...patch,
    });

RegexWorkerSpawner _blockOnePattern({void Function()? onBlocked}) => (entry, replies, errors, exits) async {
  final responses = ReceivePort();
  final incoming = ReceivePort();
  final observedExit = ReceivePort();
  SendPort? actual;
  incoming.listen((Object? value) {
    final command = value! as Map<String, Object?>;
    if (command['pattern'] == 'BLOCK') {
      onBlocked?.call();
    } else {
      actual!.send(value);
    }
  });
  responses.listen((Object? value) {
    if (value is SendPort) {
      actual = value;
      replies.send(incoming.sendPort);
    } else {
      replies.send(value);
    }
  });
  void release() {
    responses.close();
    incoming.close();
    observedExit.close();
  }

  observedExit.listen((value) {
    release();
    exits.send(value);
  });
  try {
    return await Isolate.spawn(
      entry,
      responses.sendPort,
      onError: errors,
      onExit: observedExit.sendPort,
      errorsAreFatal: true,
    );
  } catch (_) {
    release();
    rethrow;
  }
};
