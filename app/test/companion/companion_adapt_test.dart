import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/companion/companion_adapt.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A model as the stage reports it: a few parameters named like a real one.
Map<String, Object?> probeJson({
  String zonesFrom = 'default',
  String emotionsFrom = 'default',
  List<String> missing = const ['ParamEyeLOpen', 'ParamEyeROpen'],
  bool adapter = false,
  List<String> tail = const [],
}) => {
  'moc': 'model/m.moc3',
  'mocVersion': 5,
  'parameterCount': 6,
  'params': [
    {'id': 'PARAM_ANGLE_X', 'name': '角度 X', 'group': '脸', 'min': -30, 'max': 30, 'def': 0},
    {'id': 'EyeOpenL', 'name': '左眼 开闭', 'group': '眼睛', 'min': 0, 'max': 1, 'def': 1},
    {'id': 'EyeOpenR', 'name': '右眼 开闭', 'group': '眼睛', 'min': 0, 'max': 1, 'def': 1},
    {'id': 'TailSwing', 'name': '尾巴 摆动', 'group': '尾巴', 'min': -1, 'max': 1, 'def': 0},
    {'id': 'Watermark', 'name': '水印', 'group': '开关', 'min': 0, 'max': 1, 'def': 1},
    {'id': 'ParamMouthForm', 'name': '口型', 'min': -1, 'max': 1, 'def': 0},
  ],
  'parts': [
    {'id': 'PartHead', 'name': '头'},
  ],
  'expressions': ['开心', '脸红', '水印消除'],
  'motions': ['挥手', 'Idle'],
  'linked': {
    'ParamAngleX': ['PARAM_ANGLE_X'],
  },
  'ruleAliasVersion': 1,
  'ruleAliases': {
    'ParamAngleX': {
      'ids': ['PARAM_ANGLE_X'],
      'scale': 1,
      'offset': 0,
    },
  },
  'missing': missing,
  'zonesFrom': zonesFrom,
  'emotionsFrom': emotionsFrom,
  'tail': tail,
  'adapter': adapter,
  'name': '小鱼',
};

CompanionProbe probe([Map<String, Object?>? json]) => CompanionProbe.fromJson(json ?? probeJson())!;

String sse(String text, {Map<String, Object?>? usage}) =>
    'event: content_block_delta\ndata: ${jsonEncode({
      'type': 'content_block_delta',
      'index': 0,
      'delta': {'type': 'text_delta', 'text': text},
    })}\n\nevent: message_delta\ndata: ${jsonEncode({
      'type': 'message_delta',
      'delta': {'stop_reason': 'end_turn'},
      'usage': ?usage,
    })}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the stage report, read', () {
    final p = probe();
    expect(p.moc, 'model/m.moc3');
    expect(p.params.map((x) => x.id), contains('EyeOpenL'));
    expect(p.param('EyeOpenL')!.name, '左眼 开闭');
    expect(p.parts.single, ('PartHead', '头'));
    expect(p.linked['ParamAngleX'], ['PARAM_ANGLE_X']);
    expect(p.ruleAliases!['ParamAngleX']!.toJson(), {
      'ids': ['PARAM_ANGLE_X'],
      'scale': 1,
      'offset': 0,
    });
    expect(CompanionProbe.fromJson('nope'), isNull);
  });

  test('what judgement is still needed', () {
    expect(companionAdaptWanted(probe()), ['motion', 'zones', 'emotions', 'tail']);
    // An authored character.json with everything: nothing to ask.
    expect(
      companionAdaptWanted(
        probe(
          probeJson(zonesFrom: 'character', emotionsFrom: 'character', missing: const [], tail: const ['TailSwing']),
        ),
      ),
      isEmpty,
    );
    // Only a smile missing doesn't make her stiff.
    expect(
      companionAdaptWanted(
        probe(probeJson(zonesFrom: 'hitAreas', emotionsFrom: 'character', missing: const ['ParamEyeSmile'])),
      ),
      ['tail'],
    );
    expect(companionAdaptWanted(probe(probeJson(adapter: true))), isEmpty);
  });

  test('the request: what was linked, what is missing, every parameter by group, the note', () {
    final text = companionAdaptRequest(probe(), note: '摸头没反应', current: {'zones': []});
    final input = jsonDecode(text) as Map;
    final data = input['probe'] as Map;
    expect(data['linked'], {
      'ParamAngleX': ['PARAM_ANGLE_X'],
    });
    expect(data['ruleAliasVersion'], 1);
    expect(data['ruleAliases'], probeJson()['ruleAliases']);
    expect(data['missing'], ['ParamEyeLOpen', 'ParamEyeROpen']);
    expect(data['coverageUnknown'], contains('ParamAngleY'));
    expect((data['params'] as List).where((p) => p['group'] == '眼睛').map((p) => p['id']), ['EyeOpenL', 'EyeOpenR']);
    expect(data['loadedExpressions'], ['开心', '脸红', '水印消除']);
    expect(input['verifiedEffects'], {'expressions': {}, 'motions': {}});
    expect(input['userFeedback'], '摸头没反应');
    expect(input['current'], {'adapter': 1});
    expect(input['currentDropped'], ['zones']);
    expect(companionAdaptSystem, contains('只输出一个 JSON 对象'));
  });

  test('the JSON out of whatever the model wrapped it in', () {
    expect(companionAdaptJson('好的：\n```json\n{"notes":"x"}\n```'), {'notes': 'x'});
    expect(companionAdaptJson('没有'), isNull);
    expect(companionAdaptJson('{broken'), isNull);
  });

  test('only what the model backs is kept', () {
    final (:adapter, :dropped) = companionAdapterCheck(
      {
        'params': {
          'ParamEyeLOpen': {'id': 'EyeOpenL'},
          'ParamEyeROpen': {'id': 'EyeOpenR', 'scale': -1, 'offset': 1},
          'ParamMouthOpenY': {'id': 'NoSuchParam'},
          'NotHers': {'id': 'EyeOpenL'},
        },
        'emotions': {
          'happy': {
            'expression': '开心',
            'face': {'ParamMouthForm': 3, 'EyeOpenL': 5, 'Nope': 1},
          },
          'shy': {'expression': '不存在'},
          'ecstatic': {'expression': '开心'},
        },
        'actions': {
          'wave': {'motion': '挥手'},
          'nod': {'motion': '没有这个'},
          'dance': {'motion': '挥手'},
        },
        'zones': [
          {'id': 'head', 'from': 0, 'to': 0.2},
          {'id': 'face', 'from': 0.3, 'to': 0.2},
          {'id': 'wings', 'from': 0, 'to': 1},
          // Preserve upstream malformed-geometry regressions under the stricter contract.
          {'id': 'legs', 'from': 1.2, 'to': 1.6},
          {'id': 'body', 'from': 0.3, 'to': 0.6, 'xFrom': 0.5, 'xTo': -0.5},
        ],
        'framing': {'zoom': 9, 'y': 0.1},
        'tail': ['TailSwing', 'Nope'],
        'pose': {'Watermark': 7, 'Nope': 1},
        'notes': '  尾巴用摆动参数代替了  ',
        'script': 'alert(1)',
      },
      probe({
        ...probeJson(zonesFrom: 'hitAreas'),
        'zones': [
          {'id': 'head', 'from': 0, 'to': 0.2},
        ],
      }),
      evidence: const CompanionAdaptEvidence(
        expressions: {'开心': 'Observed smile; only facial parameters, no switches'},
        motions: {'挥手': 'Observed waving with no sound, events or visibility effects'},
      ),
    );
    expect(adapter['params'], {
      'ParamEyeLOpen': {'id': 'EyeOpenL'},
      'ParamEyeROpen': {'id': 'EyeOpenR', 'scale': -1.0, 'offset': 1.0},
    });
    expect(adapter['emotions'], {
      'happy': {
        'expression': '开心',
        'face': {'ParamMouthForm': 1.0},
      },
    });
    expect(adapter['actions'], {
      'wave': {'motion': '挥手'},
    });
    expect(adapter['zones'], [
      {'id': 'head', 'from': 0.0, 'to': 0.2},
    ]);
    expect(adapter.containsKey('framing'), isFalse);
    expect(adapter['tail'], ['TailSwing']);
    expect(adapter.containsKey('pose'), isFalse);
    expect(adapter['notes'], '尾巴用摆动参数代替了');
    expect(adapter.containsKey('script'), isFalse);
    expect(
      dropped,
      containsAll([
        'params.ParamMouthOpenY',
        'params.NotHers',
        'emotions.happy.face.Nope',
        'emotions.shy.expression',
        'emotions.ecstatic',
        'actions.nod',
        'actions.dance',
        'zones',
        'script',
        'pose',
      ]),
    );
    expect(companionAdapterEmpty(adapter), isFalse);
    expect(companionAdapterEmpty(companionAdapterCheck({'notes': 'x'}, probe()).adapter), isTrue);
    // Framing has no camera evidence and cannot make an empty result useful.
    expect(
      companionAdapterEmpty(
        companionAdapterCheck({
          'framing': {'zoom': 0.7},
        }, probe()).adapter,
      ),
      isTrue,
    );
  });

  group('asking her AI', () {
    const current = {
      'adapter': 1,
      'params': {
        'ParamMouthForm': {'id': 'SmileShape', 'scale': -2.0, 'offset': 0.3},
      },
    };
    const face = {
      'emotions': {
        'happy': {
          'face': {'ParamMouthForm': 0.5},
        },
      },
    };
    Map<String, Object?> replacementReport({Map<String, Object?> rules = const {}, bool legacy = false}) => {
      'adapter': true,
      'parameterCount': 1,
      'params': [
        {'id': 'SmileShape', 'min': -1, 'max': 1, 'def': 0},
      ],
      'linked': {
        'ParamMouthForm': ['SmileShape'],
      },
      if (!legacy) 'ruleAliasVersion': 1,
      if (!legacy) 'ruleAliases': rules,
    };

    test('one request, the answer checked', () async {
      final asked = <Map<String, Object?>>[];
      final receipts = <CompanionUsage>[];
      var sent = 0;
      const rawUsage = {'input_tokens': 100, 'cache_read_input_tokens': 10, 'output_tokens': 25};
      final client = MockClient.streaming((request, body) async {
        expect(sent, 1, reason: 'the wrapper forwards onSent before the actual send');
        asked.add(jsonDecode(await body.bytesToString()) as Map<String, Object?>);
        final answer = jsonEncode({
          'params': {
            'ParamEyeLOpen': {'id': 'EyeOpenL'},
          },
          'zones': [
            {'id': 'head', 'from': 0, 'to': 0.2},
          ],
          'notes': '对上了眼睛',
        });
        return http.StreamedResponse(Stream.value(utf8.encode(sse('好的。$answer', usage: rawUsage))), 200);
      });
      final adapter = await companionAdaptAsk(
        client: client,
        apiKey: 'sk-test',
        probe: probe(),
        note: '眼睛不眨',
        onSent: () => sent++,
        onUsage: receipts.add,
      );
      expect(asked.single['system'], companionAdaptSystem);
      expect((asked.single['messages']! as List).single.toString(), contains('眼睛不眨'));
      expect(adapter['params'], {
        'ParamEyeLOpen': {'id': 'EyeOpenL'},
      });
      expect(adapter['notes'], '对上了眼睛');
      expect(receipts.single.finalUsage, rawUsage);
      expect(receipts.single.outputTokens, 25);
      expect(receipts.single.complete, isTrue);
      expect(receipts.single.terminal, 'complete');
    });

    test('an answer with nothing usable in it', () async {
      final receipts = <CompanionUsage>[];
      final prose = MockClient.streaming(
        (_, _) async => http.StreamedResponse(Stream.value(utf8.encode(sse('我不确定', usage: {'output_tokens': 4}))), 200),
      );
      await expectLater(
        companionAdaptAsk(client: prose, apiKey: 'k', probe: probe(), onUsage: receipts.add),
        throwsA(isA<CompanionAdaptError>().having((e) => e.reason, 'reason', 'unreadable')),
      );
      expect(receipts.single.outputTokens, 4, reason: 'an unusable adapter still has billable reported usage');
      expect(receipts.single.complete, isTrue);
      final made = MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.value(
            utf8.encode(
              sse(
                jsonEncode({
                  'params': {
                    'ParamAngleX': {'id': 'Made'},
                  },
                }),
              ),
            ),
          ),
          200,
        ),
      );
      await expectLater(
        companionAdaptAsk(client: made, apiKey: 'k', probe: probe()),
        throwsA(isA<CompanionAdaptError>().having((e) => e.reason, 'reason', 'empty')),
      );
    });

    test('old linked-only face is rejected even when current is supplied', () async {
      for (final legacy in [false, true]) {
        final asked = <Map>[];
        final client = MockClient.streaming((_, body) async {
          final request = jsonDecode(await body.bytesToString()) as Map;
          asked.add(jsonDecode((request['messages'] as List).single['content'] as String) as Map);
          return http.StreamedResponse(Stream.value(utf8.encode(sse(jsonEncode(face)))), 200);
        });
        addTearDown(client.close);
        final before = jsonEncode(current);
        await expectLater(
          companionAdaptAsk(
            client: client,
            apiKey: 'k',
            probe: probe(replacementReport(legacy: legacy)),
            current: current,
          ),
          throwsA(isA<CompanionAdaptError>().having((e) => e.reason, 'reason', 'empty')),
        );
        expect(asked.single['current'], current);
        expect((asked.single['probe'] as Map)['ruleAliases'], legacy ? null : {});
        expect(jsonEncode(current), before, reason: 'the supplied old adapter is not modified');
      }
    });

    test('explicit retained params keep negative affine coefficients and support face on legacy stage', () async {
      final client = MockClient.streaming(
        (_, _) async => http.StreamedResponse(Stream.value(utf8.encode(sse(jsonEncode({...current, ...face})))), 200),
      );
      addTearDown(client.close);
      final checked = await companionAdaptAsk(
        client: client,
        apiKey: 'k',
        probe: probe(replacementReport(legacy: true)),
        current: current,
      );
      expect(checked, {...current, ...face});
    });

    test('omitted override restores original rules and the request preserves their coefficients', () async {
      const rules = {
        'ParamMouthForm': {
          'ids': ['SmileShape'],
          'scale': -0.000037123456789,
          'offset': 0.000000987654321,
        },
      };
      final asked = <Map>[];
      final client = MockClient.streaming((_, body) async {
        final request = jsonDecode(await body.bytesToString()) as Map;
        asked.add(jsonDecode((request['messages'] as List).single['content'] as String) as Map);
        return http.StreamedResponse(Stream.value(utf8.encode(sse(jsonEncode(face)))), 200);
      });
      addTearDown(client.close);
      final checked = await companionAdaptAsk(
        client: client,
        apiKey: 'k',
        probe: probe({
          ...replacementReport(rules: rules),
          'params': [
            {'id': 'SmileShape', 'min': -0.00004, 'max': 0.00004, 'def': 0.000001},
          ],
        }),
        current: current,
      );
      expect(checked, {'adapter': 1, ...face});
      expect(checked.containsKey('params'), isFalse, reason: 'current is not merged into a full replacement');
      expect((asked.single['probe'] as Map)['ruleAliases'], rules);
      expect(asked.single['current'], current);
    });

    test('a refused key is the light route\'s error', () async {
      final refused = MockClient((_) async => http.Response('{"error":"bad key"}', 401));
      final receipts = <CompanionUsage>[];
      var sent = 0;
      await expectLater(
        companionAdaptAsk(client: refused, apiKey: 'k', probe: probe(), onSent: () => sent++, onUsage: receipts.add),
        throwsA(isA<CompanionLightError>().having((e) => e.failure, 'failure', CompanionLightFailure.badKey)),
      );
      expect(sent, 1);
      expect(receipts.single.terminal, 'http_error');
      expect(receipts.single.httpStatus, 401);
      expect(receipts.single.outputTokens, isNull);
    });
  });

  group('kept beside the character', () {
    late Directory pack;

    setUp(() {
      pack = Directory.systemTemp.createTempSync('companion-adapt');
      File('${pack.path}/character/model/m.moc3')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
    });
    tearDown(() => pack.deleteSync(recursive: true));

    test('written with the moc3 fingerprint, read back, removed', () async {
      await companionAdapterWrite(pack, probe(), {
        'adapter': 1,
        'tail': ['TailSwing'],
      });
      final back = await companionAdapterRead(pack);
      expect(back!['tail'], ['TailSwing']);
      expect(back['moc'], sha256.convert([1, 2, 3]).toString());
      expect(File('${pack.path}/character/adapter.json.part').existsSync(), isFalse);
      await companionAdapterRemove(pack);
      expect(await companionAdapterRead(pack), isNull);
    });

    test('no fingerprint for a path that climbs out', () async {
      expect(await companionMocFingerprint(pack, probe({...probeJson(), 'moc': '../x.moc3'})), isNull);
    });
  });

  test('fitting on its own: on unless turned off, once per model', () async {
    expect(await companionAdaptAuto(), isTrue);
    await companionAdaptSetAuto(false);
    expect(await companionAdaptAuto(), isFalse);
    expect(await companionAdaptTried('abc'), isFalse);
    await companionAdaptMarkTried('abc');
    expect(await companionAdaptTried('abc'), isTrue);
  });
}
