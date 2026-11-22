import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'spreset_protocol_test.dart' as fixture;

void main() {
  final source =
      jsonDecode(File('test/fixtures/w11_spreset_conditional_source.json').readAsStringSync()) as Map<String, Object?>;
  for (final row in (source['results']! as List<Object?>).cast<Map<String, Object?>>()) {
    test('fixed conditional tag stage still applies to follow tool results: ${row['name']}', () async {
      final message = (row['input']! as List<Object?>).single! as Map<String, Object?>;
      final input = fixture.segment(
        'tool-result',
        'tool',
        message['content'],
        collection: 'chatHistory',
        extra: Map.of(message)
          ..remove('role')
          ..remove('content'),
      );
      final evaluator = fixture.Evaluator();
      final result = await spresetSquashSegments(
        [input],
        fixture.config({'ChatSquash': row['settings']}),
        fixture.counter,
        expand: (text) => text,
        evaluate: evaluator.call,
        diagnose: evaluator.diagnose,
      );
      expect(result, hasLength(1));
      // The fixed source evidence ends at the conditional/squash boundary.
      // r2's separate owner-authorized tool-ID preservation still applies.
      expect(result.single.message, (row['afterConditional']! as List<Object?>).single);
      expect(result.single.message['tool_call_id'], 'call<yes>');
      expect(result.single.message['signature'], '<yes>signature');
      expect(result.single.collectionId, input.collectionId);
      expect(result.single.sources, input.sources);
      expect(input.message, message, reason: 'Preparing the prompt does not mutate the captured source segment.');
      expect(evaluator.calls, isEmpty);
      expect(evaluator.issues, isEmpty);
    });
  }
}
