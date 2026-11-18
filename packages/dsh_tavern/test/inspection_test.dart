import 'dart:convert';

import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/inspection.dart';
import 'package:dsh_tavern/src/prompt/prompt_types.dart';
import 'package:test/test.dart';

void main() {
  test('inspection freezes nested messages, source details and WI evidence', () {
    final keys = <Object?>['海'];
    final details = <String, Object?>{'keys': keys, 'reason': 'keywords'};
    final content = <String, Object?>{'role': 'system', 'content': '鲸🐋\r\n海'};
    final body = <String, Object?>{
      'model': 'fixture',
      'messages': <Object?>[content],
    };
    final hits = <Object?>[
      <String, Object?>{'uid': '7', 'content': '鲸', 'secondaryMatches': keys},
    ];
    final snapshot = TavernTurnInspection(
      chatId: 'chat',
      generationType: 'normal',
      startedAt: _at,
      prompt: _prompt(body, content, details),
      worldInfo: {'activated': hits},
    );
    content['content'] = 'changed';
    keys.add('changed');
    hits.clear();
    body['model'] = 'changed';
    expect(snapshot.prompt!.body['model'], 'fixture');
    expect(snapshot.prompt!.beforePostProcessing.single.message['content'], '鲸🐋\r\n海');
    expect(snapshot.prompt!.beforePostProcessing.single.sources.single.details['keys'], ['海']);
    expect((snapshot.worldInfo['activated']! as List<Object?>).length, 1);
    expect(() => snapshot.prompt!.body['model'] = 'bad', throwsUnsupportedError);
    expect(() => snapshot.prompt!.beforePostProcessing.clear(), throwsUnsupportedError);
    expect(() => (snapshot.worldInfo['activated']! as List<Object?>).clear(), throwsUnsupportedError);
  });

  test('roundtrip preserves tool payload, all origins, exclusions and actual usage', () {
    final body = <String, Object?>{
      'model': 'fixture',
      'stream': true,
      'messages': [
        <String, Object?>{
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            <String, Object?>{
              'id': 'call1',
              'type': 'function',
              'function': {'name': 'remember', 'arguments': '{"x":1}'},
            },
          ],
        },
      ],
      'future_field': {'enabled': true},
    };
    final sourceKinds = ['preset', 'card', 'worldInfo', 'authorNote', 'memory', 'history'];
    final sources = [
      for (final kind in sourceKinds) PromptSource(kind, '$kind:id', details: {'reason': 'fixture'}),
    ];
    final prompt = PromptAssembly(
      body: body,
      beforePostProcessing: [
        PromptSegment(id: 'before', message: {'role': 'system', 'content': '文'}, sources: sources, tokens: 3),
      ],
      afterPostProcessing: [
        PromptSegment(id: 'after', message: {'role': 'user', 'content': '文'}, sources: sources, tokens: 3),
      ],
      excluded: [PromptExclusion('old', 'history_budget', sources)],
      budget: 100,
      remainingBudget: 94,
      counterName: 'test estimate',
      exactTokenCounts: false,
      historyWindow: PromptHistoryWindow(
        firstNodeId: 'history:id',
        admittedExamples: [(kind: 'card', id: 'card:mes_example', block: 0)],
        excludedOptionalSources: [(kind: 'worldInfo', id: 'book:3')],
        excludedInjections: ['["depth-10",[["extension","fixture"]]]'],
      ),
    );
    final snapshot = TavernTurnInspection(
      chatId: 'chat',
      nodeId: 'node',
      generationType: 'continue',
      startedAt: _at,
      status: TavernInspectionStatus.completed,
      finishedAt: _at.add(const Duration(seconds: 1)),
      prompt: prompt,
      reportedUsage: const TavernUsage(promptTokens: 24, cacheHitTokens: 17, completionTokens: 5, model: 'fixture'),
    );
    final encoded = jsonEncode(snapshot.toJson());
    final restored = TavernTurnInspection.fromJson(jsonDecode(encoded) as Map<String, Object?>);
    expect(jsonEncode(restored.toJson()), encoded);
    expect(restored.prompt!.afterPostProcessing.single.sources.map((source) => source.kind), sourceKinds);
    expect(restored.prompt!.excluded.single.reason, 'history_budget');
    expect(restored.reportedUsage!.cacheHitTokens, 17);
    expect(restored.tokenCountsEstimated, isTrue);
    expect(restored.tokenCountLabel, '估算');
    expect(restored.startedAt.isUtc, isTrue);
  });

  test('missing usage differs from a provider-reported zero', () {
    final snapshot = TavernTurnInspection(chatId: 'chat', generationType: 'continue', startedAt: _at);
    expect(snapshot.reportedUsage, isNull);
    expect(snapshot.tokenCountLabel, '未组装');
    final reported = snapshot.copyWith(reportedUsage: const TavernUsage());
    final restored = TavernTurnInspection.fromJson(jsonDecode(jsonEncode(reported.toJson())) as Map<String, Object?>);
    expect(restored.reportedUsage, isNotNull);
    expect(restored.reportedUsage!.promptTokens, 0);
    expect(snapshot.reportedUsage, isNull);
  });

  test('failed ephemeral copy drops its node without mutating the saved snapshot', () {
    final saved = TavernTurnInspection(
      chatId: 'chat',
      nodeId: 'existing',
      contextNodeId: 'context',
      generationType: 'continue',
      startedAt: _at,
    );
    final failed = saved.copyWith(
      clearNodeId: true,
      status: TavernInspectionStatus.failed,
      failure: TavernFailure.network,
      detail: 'network',
      finishedAt: _at,
    );
    expect(saved.nodeId, 'existing');
    expect(saved.status, TavernInspectionStatus.preparing);
    expect(failed.nodeId, isNull);
    final restored = TavernTurnInspection.fromJson(jsonDecode(jsonEncode(failed.toJson())) as Map<String, Object?>);
    expect(restored.failure, TavernFailure.network);
    expect(restored.contextNodeId, 'context');
    expect(restored.copyWith(clearContextNodeId: true).contextNodeId, isNull);
  });

  test('unknown schema and corrupt structured values fail explicitly', () {
    final snapshot = TavernTurnInspection(chatId: 'chat', generationType: 'normal', startedAt: _at);
    expect(() => TavernTurnInspection.fromJson({...snapshot.toJson(), 'version': 2}), throwsFormatException);
    expect(() => TavernTurnInspection.fromJson({...snapshot.toJson(), 'status': 'invented'}), throwsFormatException);
    expect(() => TavernTurnInspection.fromJson({...snapshot.toJson(), 'worldInfo': []}), throwsFormatException);
    expect(
      () => TavernTurnInspection(
        chatId: 'chat',
        generationType: 'normal',
        startedAt: _at,
        worldInfo: {'notJson': double.infinity},
      ),
      throwsFormatException,
    );
  });
}

final _at = DateTime.parse('2026-11-10T03:00:00+08:00');

PromptAssembly _prompt(Map<String, Object?> body, Map<String, Object?> message, Map<String, Object?> details) =>
    PromptAssembly(
      body: body,
      beforePostProcessing: [
        PromptSegment(
          id: 'before',
          message: message,
          sources: [PromptSource('worldInfo', 'book:7', details: details)],
          tokens: 5,
        ),
      ],
      afterPostProcessing: const [],
      excluded: const [],
      budget: 100,
      remainingBudget: 95,
      counterName: 'test estimate',
      exactTokenCounts: false,
    );
