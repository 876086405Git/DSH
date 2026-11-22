import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/src/prompt/tool_reasoning.dart';
import 'package:test/test.dart';

Map<String, Object?> _object(Object? value) => value! as Map<String, Object?>;
List<Map<String, Object?>> _rows(Object? value) => (value! as List<Object?>).cast<Map<String, Object?>>();

void main() {
  final fixture = _object(jsonDecode(File('test/fixtures/tool_reasoning-st119.json').readAsStringSync()));

  for (final vector in _rows(fixture['modeSettings'])) {
    test('actual mode helper: ${vector['id']}', () {
      expect(
        effectiveToolReasoningMode(_object(vector['settings']), source: 'openrouter').value,
        vector['expectedMode'],
      );
    });
  }

  group('fixed ST history selector', () {
    for (final vector in _rows(fixture['history'])) {
      test(vector['id']! as String, () {
        final original = jsonEncode(vector['input']);
        final rows = _rows(vector['input']).map(ToolReasoningHistoryRow.fromJson).toList();
        final mode = effectiveToolReasoningMode({
          'tool_reasoning_mode': vector['mode'],
          'show_thoughts': vector['show'],
        }, source: vector['source']! as String);
        expect(
          mode.value,
          const {'openrouter', 'custom'}.contains(vector['source']) ? vector['effectiveMode'] : 'disabled',
        );
        final projections = <ToolReasoningProjection>[];
        for (var index = 0; index < rows.length; index++) {
          final projected = projectToolReasoning(
            rows,
            index,
            mode: mode,
            toolsSupported: vector['toolsSupported']! as bool,
          );
          if (projected != null) projections.add(projected);
        }
        expect([for (final item in projections) item.reasoning], vector['toolMessageReasoning']);
        // The real source visits history newest first. Its recorded arguments
        // include the full cloned invocation records before setToolCalls.
        expect(
          [for (final item in projections) item.invocations],
          [for (final item in _rows(vector['toolProjections']).reversed) item['invocations']],
        );
        expect(jsonEncode(vector['input']), original);
        expect([for (final row in rows) row.toJson()], vector['input']);
      });
    }
  });

  group('fixed ST source and group provenance', () {
    for (final vector in _rows(fixture['provenance'])) {
      test(vector['id']! as String, () {
        final original = jsonEncode(vector['input']);
        final input = _rows(vector['input']).single;
        final extra = _object(input['extra']);
        // This is the prepared row boundary, not a replacement for ST's
        // complete chat/name/media adapter. These fixtures have no media.
        final row = ToolReasoningHistoryRow.fromJson({
          'role': input['is_user'] == true ? 'user' : 'assistant',
          'content': (input['mes']! as String).replaceAll('\r', ''),
          'name': input['name'],
          'mediaDisplay': null,
          'mediaIndex': null,
          if (extra.containsKey('tool_invocations')) 'invocations': extra['tool_invocations'],
          if (extra.containsKey('reasoning_signature')) 'signature': extra['reasoning_signature'],
          if (extra.containsKey('reasoning')) 'reasoning': extra['reasoning'],
        });
        final before = row.toJson();
        final projected = projectToolReasoningProvenance(
          row,
          source: vector['source']! as String,
          model: vector['model']! as String,
          originSource: extra['api'],
          originModel: extra['model'],
          group: vector['group']! as bool,
          characterName: vector['characterName']! as String,
        );
        expect(projected.toJson(), _rows(vector['result']).single);
        expect(row.toJson(), before);
        expect(jsonEncode(vector['input']), original);
      });
    }
  });

  group('ordinary reasoning controls stay outside invocation selection', () {
    for (final vector in _rows(fixture['ordinaryReasoning'])) {
      test('${vector['mode']}/add=${vector['addToPrompts']}', () {
        // PromptReasoning produced this string in the real source oracle.
        // P1 does not implement or rerun that independent ordinary-body stage.
        final row = ToolReasoningHistoryRow.fromJson({
          'role': 'assistant',
          'content': vector['result'],
          'reasoning': 'ORDINARY',
          'opaque': {'keep': true},
        });
        final before = row.toJson();
        expect(
          projectToolReasoning(
            [row],
            0,
            mode: effectiveToolReasoningMode({
              'tool_reasoning_mode': vector['mode'],
              'show_thoughts': true,
            }, source: 'openrouter'),
          ),
          isNull,
        );
        expect(row.toJson(), before);
      });
    }
  });

  test('absent and empty invocation arrays keep distinct row identities', () {
    final absent = ToolReasoningHistoryRow.fromJson({'role': 'assistant', 'content': 'A'});
    final empty = ToolReasoningHistoryRow.fromJson({'role': 'assistant', 'content': 'A', 'invocations': <Object?>[]});
    expect(absent.invocations, isNull);
    expect(absent.toJson().containsKey('invocations'), isFalse);
    expect(empty.invocations, isEmpty);
    expect(projectToolReasoning([absent], 0, mode: ToolReasoningMode.activeChain), isNull);
    final projected = projectToolReasoning([empty], 0, mode: ToolReasoningMode.activeChain)!;
    expect(projected.invocations, isEmpty);
    expect(projected.reasoning, isNull);
  });

  test('detached inputs and reads preserve all opaque invocation metadata', () {
    final input = <String, Object?>{
      'role': 'assistant',
      'content': 'T',
      'invocations': <Object?>[
        <String, Object?>{
          'id': 'call',
          'reasoning': 'OWN',
          'signature': 'SIG',
          'opaque': <String, Object?>{
            'items': <Object?>['original'],
          },
        },
      ],
    };
    final row = ToolReasoningHistoryRow.fromJson(input);
    final captured = row.toJson();
    _rows(input['invocations']).single['reasoning'] = 'changed';
    expect(row.toJson(), captured);
    final projection = projectToolReasoning([row], 0, mode: ToolReasoningMode.disabled)!;
    final read = projection.invocations.single;
    expect(read.containsKey('reasoning'), isFalse);
    expect(read['signature'], 'SIG');
    (_object(read['opaque'])['items']! as List<Object?>).add('modified read');
    expect(_object(projection.invocations.single['opaque'])['items'], ['original']);
    final rowRead = row.toJson();
    _rows(rowRead['invocations']).single.clear();
    expect(row.toJson(), captured);
  });
}
