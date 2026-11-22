import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';
import 'spreset_engine_test.dart' show SPresetHost;

void main() {
  test('Helper raw separate history uses its own messages before any page snapshot', () async {
    final h = await generationFixture();
    await h.engine.setPreset(_preset('CURRENT', separate: true));
    final actor = await h.card('History actor');
    final context = await h.context(await h.emptyChat(actor));
    final plan = h.reply('done');
    final generation = await h.bridge.generateRaw(context.id, _raw('RAW'));
    final request = await generationRequest(generation, plan);
    await generation.result;
    expect(generationMessages(request), [
      {'role': 'user', 'content': 'RAW'},
    ]);
  });

  test('Helper raw and named use their current inputs across preset switches and private ends', () async {
    final h = await generationFixture();
    await h.engine.setPreset(_preset('OLD MAIN'));
    final actor = await h.card('History actor');
    final context = await h.context(await h.emptyChat(actor));
    final warm = await _normal(h, context.id, 'OLD INPUT');
    expect(_text(warm), contains('OLD INPUT'));
    await h.engine.importPreset(jsonEncode(_preset('NAMED MAIN').raw), fileName: 'History Named.json');
    await h.engine.setPreset(_preset('CURRENT MAIN', separate: true));
    for (final path in ['raw', 'named', 'raw']) {
      final plan = h.reply('done');
      final generation = path == 'named'
          ? await h.bridge.generate(
              context.id,
              TavernHelperGenerateRequest.fromJson({'preset_name': 'History Named', 'user_input': 'NEW INPUT'}),
            )
          : await h.bridge.generateRaw(context.id, _raw('RAW INPUT'));
      final request = await generationRequest(generation, plan);
      await generation.result;
      expect(_text(request), isNot(contains('OLD MAIN')), reason: path);
      expect(_text(request), isNot(contains('OLD INPUT')), reason: path);
      if (path == 'named') {
        expect(_text(request), contains('NAMED MAIN'));
        expect(_text(request), contains('NEW INPUT'));
        expect(_text(request), isNot(contains('RAW INPUT')));
      } else {
        expect(generationMessages(request), [
          {'role': 'user', 'content': 'RAW INPUT'},
        ]);
      }
    }
  });

  test('Raw system squash retains the real history membership without swallowing a literal', () async {
    final h = await generationFixture();
    await h.engine.setPreset(ChatPreset({..._preset('MAIN', separate: true).raw, 'squash_system_messages': true}));
    final actor = await h.card('Raw system actor');
    final context = await h.context(await h.emptyChat(actor));
    final plan = h.reply('done');
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernHelperRawRequest.fromJson({
        'ordered_prompts': [
          'chat_history',
          {'role': 'user', 'content': 'OUTSIDE'},
        ],
        'overrides': {
          'chat_history': {
            'with_depth_entries': false,
            'prompts': [
              {'role': 'system', 'content': 'S1'},
              {'role': 'system', 'content': 'S2'},
            ],
          },
        },
      }),
    );
    final request = await generationRequest(generation, plan);
    await generation.result;
    expect(generationMessages(request), [
      {'role': 'assistant', 'content': 'S[S1\nS2]'},
      {'role': 'user', 'content': 'OUTSIDE'},
    ]);
  });

  test('Helper raw owns its messages after a completed native normal request', () async {
    final h = await generationFixture();
    await h.engine.setPreset(_preset('NATIVE MAIN'));
    final actor = await h.card('Native history actor');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat);
    final plan = h.reply('MODEL RESPONSE');
    final native = ScriptEvents(h.engine.send(chat, 'NATIVE INPUT'));
    await native.done.future;
    expect(native.values.whereType<TavernTurnFailed>(), isEmpty);
    expect(plan.seen.isCompleted, isTrue);
    await h.engine.setPreset(_preset('CURRENT MAIN', separate: true));
    final rawPlan = h.reply('done');
    final raw = await h.bridge.generateRaw(context.id, _raw('RAW INPUT'));
    final request = await generationRequest(raw, rawPlan);
    await raw.result;
    expect(generationMessages(request), [
      {'role': 'user', 'content': 'RAW INPUT'},
    ]);
  });

  test('Native and Helper raw retain their own messages after quiet ordinary assembly', () async {
    final h = await generationFixture();
    final actor = await h.card('Quiet actor');
    final context = await h.context(await h.emptyChat(actor));
    await h.engine.setPreset(_preset('QUIET MAIN'));
    final plan = h.reply('quiet response');
    final quiet = await h.bridge.triggerSlash(context.id, '/gen QUIET CONTROL');
    await quiet.result;
    expect(plan.seen.isCompleted, isTrue);
    await h.engine.setPreset(_preset('CURRENT', separate: true));
    final nativePlan = h.reply('native raw response');
    final nativeRaw = await h.bridge.generateRaw(
      context.id,
      TavernScriptRawRequest(
        orderedPrompts: const [
          TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'NATIVE RAW'),
        ],
      ),
    );
    final nativeWire = await generationRequest(nativeRaw, nativePlan);
    await nativeRaw.result;
    expect(_text(nativeWire), 'NATIVE RAW');
    expect(generationMessages(await _rawRequest(h, context.id, 'HELPER RAW')), [
      {'role': 'user', 'content': 'HELPER RAW'},
    ]);
  });

  test('Conditional raw squash removes only the current input tag', () async {
    final h = await generationFixture();
    final actor = await h.card('Tag actor');
    final context = await h.context(await h.emptyChat(actor));
    await h.engine.setPreset(
      _withSquash(_preset('CURRENT', separate: true), {'conditional_enabled': true, 'conditional_tag': '[[GO]]'}),
    );
    expect(_text(await _rawRequest(h, context.id, 'NO TAG')), 'NO TAG');
    await h.engine.setPreset(_preset('OLD [[GO]] MAIN'));
    await _normal(h, context.id, 'OLD [[GO]] INPUT');
    await h.engine.setPreset(
      _withSquash(_preset('CURRENT', separate: true), {'conditional_enabled': true, 'conditional_tag': '[[GO]]'}),
    );
    expect(_text(await _rawRequest(h, context.id, 'NO TAG')), 'NO TAG');
    final replaced = _text(await _rawRequest(h, context.id, 'NEW [[GO]] INPUT'));
    expect(replaced, 'NEW  INPUT');
    expect(replaced, isNot(contains('[[GO]]')));
  });

  test('An initialized empty shared collection cannot replace current raw input', () async {
    final h = await generationFixture();
    final actor = await h.card('Empty actor');
    final context = await h.context(await h.emptyChat(actor));
    await h.engine.setPreset(
      ChatPreset({
        ..._preset('').raw,
        'prompt_order': [
          {'character_id': 100001, 'order': <Object?>[]},
        ],
      }),
    );
    final warm = await _normal(h, context.id, 'UNPLACED');
    expect(generationMessages(warm), isEmpty);
    await h.engine.setPreset(_preset('CURRENT', separate: true));
    expect(generationMessages(await _rawRequest(h, context.id, 'RAW')), [
      {'role': 'user', 'content': 'RAW'},
    ]);
  });

  test('Normal separate keeps the complete current MessageInjections exchange', () async {
    final h = await generationFixture();
    final actor = await h.card('Injection actor');
    final context = await h.context(await h.emptyChat(actor));
    final raw = _preset('MAIN', separate: true).raw;
    final modules = (raw['extensions']! as Map<String, Object?>)['SPreset']! as Map<String, Object?>;
    modules['MessageInjections'] = {
      'main': {
        'enabled': true,
        'reasoning': 'INJECTED REASONING',
        'signature': '',
        'toolCalls': [
          {'id': 'injected_call', 'name': 'look', 'arguments': '{}'},
        ],
        'toolResults': [
          {'toolCallId': 'injected_call', 'content': 'INJECTED RESULT'},
        ],
      },
    };
    await h.engine.setPreset(ChatPreset(raw));
    final wire = await _normal(h, context.id, 'INPUT');
    expect(generationMessages(wire), [
      {
        'role': 'assistant',
        'content': 'MAIN',
        'tool_calls': [
          {
            'id': 'injected_call',
            'type': 'function',
            'function': {'name': 'look', 'arguments': '{}'},
          },
        ],
      },
      {'role': 'tool', 'content': 'INJECTED RESULT', 'tool_call_id': 'injected_call'},
      {'role': 'assistant', 'content': 'U[INPUT]'},
    ]);
    expect(_text(await _rawRequest(h, context.id, 'RAW')), 'RAW');
  });

  for (final systemSquash in [false, true]) {
    test('Header classification follows actual collection topology: system squash $systemSquash', () async {
      final h = await generationFixture();
      final actor = await h.card('Header actor', description: 'DESCRIPTION');
      final context = await h.context(await h.emptyChat(actor));
      await h.engine.setPreset(
        ChatPreset({
          ..._preset('MAIN', separate: true).raw,
          'new_chat_prompt': 'HEADER',
          'squash_system_messages': systemSquash,
        }),
      );
      final messages = generationMessages(await _normal(h, context.id, 'INPUT'));
      if (systemSquash) {
        expect(messages, [
          {'role': 'system', 'content': 'MAIN\nDESCRIPTION'},
          {'role': 'system', 'content': 'HEADER'},
          {'role': 'assistant', 'content': 'U[INPUT]'},
        ]);
      } else {
        expect(messages, [
          {'role': 'system', 'content': 'MAIN'},
          {'role': 'system', 'content': 'DESCRIPTION'},
          {'role': 'assistant', 'content': 'S[HEADER]U[INPUT]'},
        ]);
      }
    });
  }

  for (final systemSquash in [false, true]) {
    test('Continuation stays in its own collection and preserves absent logical ID: $systemSquash', () async {
      final h = await generationFixture();
      final actor = await h.card('Continue actor');
      final chat = await h.emptyChat(actor);
      final context = await h.context(chat);
      await h.bridge.createChatMessages(context.id, [
        TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'HISTORY'),
        TavernScriptMessageDraft(role: TavernScriptRole.assistant, message: 'CONTINUED'),
      ]);
      await h.engine.setPreset(
        ChatPreset({
          ..._preset('MAIN', separate: true).raw,
          'continue_prefill': false,
          'continue_nudge_prompt': 'NUDGE',
          'continue_postfix': '',
          'squash_system_messages': systemSquash,
        }),
      );
      final plan = h.reply('MODEL APPEND');
      final continuation = ScriptEvents(h.engine.continueReply(chat, (await h.engine.path(chat)).last.nodeId));
      await continuation.done.future;
      expect(continuation.values.whereType<TavernTurnFailed>(), isEmpty);
      expect(generationMessages(await plan.seen.future), [
        {'role': 'system', 'content': 'MAIN'},
        {'role': 'assistant', 'content': 'U[HISTORY]'},
        {'role': 'assistant', 'content': 'CONTINUED'},
        {'role': 'system', 'content': 'NUDGE'},
      ]);
    });
  }

  test('Failed mandatory admission cannot leak its partial root into later Helper raw', () async {
    final h = await generationFixture();
    final actor = await h.card('Partial actor', description: 'L' * 2000);
    final context = await h.context(await h.emptyChat(actor));
    await h.engine.setPreset(_preset('OLD MAIN'));
    await _normal(h, context.id, 'OLD INPUT');
    await h.engine.setPreset(ChatPreset({..._preset('PARTIAL MAIN').raw, 'openai_max_context': 110}));
    final failed = await h.bridge.generate(
      context.id,
      TavernHelperGenerateRequest.fromJson({'user_input': 'NEW INPUT'}),
    );
    expect((await generationFailure(failed)).modelFailure, TavernFailure.contextTooLong);
    expect(h.requests, hasLength(1));
    await h.engine.setPreset(_preset('CURRENT', separate: true));
    expect(generationMessages(await _rawRequest(h, context.id, 'RAW')), [
      {'role': 'user', 'content': 'RAW'},
    ]);
  });

  test('Cancelled normal assembly cannot replace later Helper raw input', () async {
    final h = await generationFixture();
    final actor = await h.card('Cancelled actor');
    final context = await h.context(await h.emptyChat(actor));
    await h.engine.setPreset(_preset('CANCELLED MAIN'));
    final plan = h.stream();
    final generation = await h.bridge.generate(
      context.id,
      TavernHelperGenerateRequest.fromJson({'user_input': 'CANCELLED INPUT', 'should_stream': true}),
    );
    await generationSignal(generation, plan.listening.future);
    expect(await (h.bridge as TavernHelperGenerationControl).stopHelperGenerationById(generation.id), isTrue);
    plan.finish();
    expect((await generationFailure(generation)).code, TavernScriptErrorCode.cancelled);
    await h.engine.setPreset(_preset('CURRENT', separate: true));
    expect(_text(await _rawRequest(h, context.id, 'RAW')), 'RAW');
  });

  test('Helper raw uses its current input across chat, page reset and host replacement', () async {
    final h = await generationFixture();
    final actor = await h.card('Partition actor');
    final chatA = await h.emptyChat(actor), chatB = await h.emptyChat(actor);
    final a = await h.context(chatA), b = await h.context(chatB);
    final aScript = await h.context(chatA, instanceId: 'same-page-script');
    await h.engine.setPreset(_preset('MAIN'));
    await _normal(h, a.id, 'A');
    await _normal(h, b.id, 'B');
    await h.engine.setPreset(_preset('CURRENT', separate: true));
    expect(_text(await _rawRequest(h, aScript.id, 'RAW A')), 'RAW A');
    expect(_text(await _rawRequest(h, b.id, 'RAW B')), 'RAW B');
    (h.engine as TavernSPresetPageLifecycle).resetSPresetPage(chatA);
    expect(_text(await _rawRequest(h, a.id, 'RESET A')), 'RESET A');
    expect(_text(await _rawRequest(h, b.id, 'UNCHANGED B')), 'UNCHANGED B');
    await h.engine.setPreset(_preset('NEW MAIN'));
    await _normal(h, aScript.id, 'NEW A');
    await h.engine.setPreset(_preset('CURRENT', separate: true));
    expect(_text(await _rawRequest(h, a.id, 'RAW')), 'RAW');
    h.bridge.attachHost(ScriptHost());
    expect(_text(await _rawRequest(h, b.id, 'REPLACED HOST')), 'REPLACED HOST');
  });

  test('A page reset rejects a late Final result while a new document publishes its own collection', () async {
    final h = await generationFixture();
    final host = SPresetHost();
    h.bridge.attachHost(host);
    final actor = await h.card('Epoch actor');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat);
    final reached = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    host.handler = (request) async {
      if (request.stage == 'FinalRequestProcessing') {
        reached.complete();
        await release.future;
        return TavernSPresetEvaluationResult(
          requestId: request.requestId,
          value: (request.arguments.single! as Map)['request'],
        );
      }
      return host.defaultEvaluate(request);
    };
    await h.engine.setPreset(
      ChatPreset({
        ..._preset('OLD MAIN').raw,
        'extensions': {
          'SPreset': {
            'FinalRequestProcessing': {'enabled': true, 'script': 'synthetic barrier'},
          },
        },
      }),
    );
    final old = await h.bridge.generate(context.id, TavernHelperGenerateRequest.fromJson({'user_input': 'OLD INPUT'}));
    await generationSignal(old, reached.future);
    (h.engine as TavernSPresetPageLifecycle).resetSPresetPage(chat);
    await h.engine.setPreset(_preset('NEW MAIN'));
    await _normal(h, context.id, 'NEW INPUT');
    release.complete();
    final failure = await generationFailure(old);
    expect(failure.code, TavernScriptErrorCode.hostUnavailable);
    expect(failure.message, contains('document'));
    expect(h.requests, hasLength(1));
    await h.engine.setPreset(_preset('CURRENT', separate: true));
    expect(_text(await _rawRequest(h, context.id, 'RAW')), 'RAW');
  });

  test('Page reset clears only its active Entry map and rejects a late entry evaluation', () async {
    final h = await generationFixture();
    final host = SPresetHost();
    h.bridge.attachHost(host);
    final actor = await h.card('Entry page actor');
    final chatA = await h.emptyChat(actor), chatB = await h.emptyChat(actor);
    final a = await h.context(chatA), b = await h.context(chatB);
    final reached = Completer<void>(), release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    host.handler = (request) async {
      if (request.stage == 'EntryCondition') {
        if (request.chatId == chatA && !reached.isCompleted) {
          reached.complete();
          await release.future;
        }
        return TavernSPresetEvaluationResult(requestId: request.requestId, value: false);
      }
      return host.defaultEvaluate(request);
    };
    final raw = _preset('MAIN').raw;
    raw['stream_openai'] = true;
    raw['extensions'] = {'SPreset': <String, Object?>{}};
    (raw['prompts']! as List<Object?>).add({
      'identifier': 'visible-entry',
      'content': 'VISIBLE ENTRY',
      'role': 'system',
      'system_prompt': false,
      'spreset_condition_enabled': true,
      'spreset_condition_script': 'synthetic condition',
    });
    final order =
        (raw['prompt_order']! as List<Object?>).cast<Map<String, Object?>>().firstWhere(
              (row) => row['character_id'].toString() == '100001',
            )['order']!
            as List<Object?>;
    order.add({'identifier': 'visible-entry', 'enabled': true});
    await h.engine.setPreset(ChatPreset(raw));
    final oldA = ScriptEvents(h.engine.send(chatA, 'A pending condition'));
    await Future.any([reached.future, oldA.done.future.then((_) => throw StateError('A finished before condition'))]);
    final bPlan = h.stream();
    final nativeB = ScriptEvents(h.engine.send(chatB, 'B live'));
    await Future.any([
      bPlan.listening.future,
      nativeB.done.future.then((_) => throw StateError('B finished before HTTP')),
    ]);
    (h.engine as TavernSPresetPageLifecycle).resetSPresetPage(chatA);
    release.complete();
    await oldA.done.future;
    expect(oldA.values.whereType<TavernTurnFailed>(), hasLength(1));
    expect(h.requests, hasLength(1), reason: 'The obsolete Entry result cannot reach HTTP.');
    final aPlan = h.stream();
    final nativeA = ScriptEvents(h.engine.send(chatA, 'A fresh document'));
    await Future.any([
      aPlan.listening.future,
      nativeA.done.future.then((_) => throw StateError('A finished before HTTP')),
    ]);
    expect(_text(await _normal(h, a.id, 'BEFORE RESET A')), isNot(contains('VISIBLE ENTRY')));
    (h.engine as TavernSPresetPageLifecycle).resetSPresetPage(chatA);
    expect(_text(await _normal(h, a.id, 'NEW A')), contains('VISIBLE ENTRY'));
    expect(_text(await _normal(h, b.id, 'HELPER B')), isNot(contains('VISIBLE ENTRY')));
    expect(_text(await _normal(h, a.id, 'AFTER LATE A')), contains('VISIBLE ENTRY'));
    expect(_text(await _normal(h, b.id, 'AFTER PRIVATE A END')), isNot(contains('VISIBLE ENTRY')));
    aPlan.delta('A response');
    aPlan.finish();
    await nativeA.done.future;
    expect(nativeA.values.whereType<TavernTurnFailed>(), isEmpty);
    bPlan.delta('B response');
    bPlan.finish();
    await nativeB.done.future;
    expect(nativeB.values.whereType<TavernTurnFailed>(), isEmpty);
  });

  test('Detached authoring preview cannot replace Helper raw input', () async {
    final h = await generationFixture();
    final actor = await h.card('Preview actor');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat);
    await h.engine.setPreset(_preset('ACTIVE MAIN'));
    await _normal(h, context.id, 'ACTIVE INPUT');
    await h.engine.setPreset(_preset('PREVIEW MAIN'));
    final draft = await h.engine.createAuthoringDraft([
      TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: actor),
    ]);
    final preview = await h.engine
        .previewAuthoringPrompt(
          TavernAuthoringPromptRequest(
            requestId: 'isolated-manager-preview',
            draftId: draft.id,
            draftRevision: draft.draftRevision,
            changeIds: const [],
            context: TavernAuthoringChatContext(chatId: chat),
            text: 'PREVIEW INPUT',
            at: h.now,
            seed: 3,
          ),
        )
        .result;
    expect(preview.status, TavernAuthoringPreviewStatus.complete);
    expect(jsonEncode(preview.assembly!.body), contains('PREVIEW INPUT'));
    await h.engine.setPreset(_preset('CURRENT', separate: true));
    expect(_text(await _rawRequest(h, context.id, 'RAW')), 'RAW');
  });

  for (final separateDuringNormal in [false, true]) {
    test('Normal keeps current image parts and later raw owns its input: $separateDuringNormal', () async {
      final h = await generationFixture();
      final actor = await h.card('Array marker actor');
      final context = await h.context(await h.emptyChat(actor));
      await h.engine.setPreset(_preset('MAIN', separate: separateDuringNormal));
      final plan = h.reply('done');
      final normal = await h.bridge.generate(
        context.id,
        TavernHelperGenerateRequest.fromJson({
          'user_input': 'IMAGE INPUT',
          'image': ['data:image/png;base64,AA=='],
        }),
      );
      final original = await generationRequest(normal, plan);
      await normal.result;
      expect(jsonEncode(original.body), contains('image_url'));
      expect(jsonEncode(original.body), isNot(contains('__IMG_ARRAY_MARKER_')));
      await h.engine.setPreset(_preset('CURRENT', separate: true));
      final reread = await _rawRequest(h, context.id, 'RAW');
      expect(_text(reread), 'RAW');
      expect(jsonEncode(reread.body), isNot(contains('image_url')));
      expect(jsonEncode(reread.body), isNot(contains('helper-image-')));
    });
  }
}

ChatPreset _preset(String main, {bool separate = false}) => ChatPreset({
  ...scriptPreset(main: main).raw,
  'new_chat_prompt': '',
  'send_if_empty': '',
  'top_k': 0,
  'custom_prompt_post_processing': 'none',
  if (separate)
    'extensions': {
      'SPreset': {
        'ChatSquash': {
          'enabled': true,
          'separate_chat_history': true,
          'role': 'assistant',
          'user_prefix': 'U[',
          'user_suffix': ']',
          'char_prefix': 'A[',
          'char_suffix': ']',
          'prefix_system': 'S[',
          'suffix_system': ']',
        },
      },
    },
});

TavernHelperRawRequest _raw(String text) => TavernHelperRawRequest.fromJson({
  'ordered_prompts': [
    {'role': 'user', 'content': text},
  ],
});

Future<ScriptRequest> _normal(ScriptFixture h, String contextId, String text) async {
  final plan = h.reply('done');
  final generation = await h.bridge.generate(contextId, TavernHelperGenerateRequest.fromJson({'user_input': text}));
  final request = await generationRequest(generation, plan);
  await generation.result;
  return request;
}

String _text(ScriptRequest request) => generationMessages(request).map((message) => message['content']).join('|');

ChatPreset _withSquash(ChatPreset preset, Map<String, Object?> additions) {
  final raw = preset.raw;
  final modules = (raw['extensions']! as Map<String, Object?>)['SPreset']! as Map<String, Object?>;
  (modules['ChatSquash']! as Map<String, Object?>).addAll(additions);
  return ChatPreset(raw);
}

Future<ScriptRequest> _rawRequest(ScriptFixture h, String contextId, String text) async {
  final plan = h.reply('done');
  final generation = await h.bridge.generateRaw(contextId, _raw(text));
  final request = await generationRequest(generation, plan);
  await generation.result;
  return request;
}
