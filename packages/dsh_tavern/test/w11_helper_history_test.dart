import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';
import 'spreset_engine_test.dart' show SPresetHost;

void main() {
  test('Helper separate history reports an unset page collection before HTTP', () async {
    final h = await generationFixture();
    await h.engine.setPreset(_preset('CURRENT', separate: true));
    final actor = await h.card('History actor');
    final context = await h.context(await h.emptyChat(actor));
    h.reply('unexpected');
    final generation = await h.bridge.generateRaw(context.id, _raw('RAW'));
    final failure = await generationFailure(generation);
    expect(failure.message, contains('PromptManager'));
    expect(h.requests, isEmpty);
  });

  test('Helper raw and named use the prior normal collection across preset switches and private ends', () async {
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
      expect(_text(request), contains('OLD MAIN'), reason: path);
      expect(_text(request), contains('U[OLD INPUT]'), reason: path);
      expect(_text(request), isNot(contains('RAW INPUT')), reason: path);
      expect(_text(request), isNot(contains('NAMED MAIN')), reason: path);
      expect(_text(request), isNot(contains('NEW INPUT')), reason: path);
    }
  });

  test('Native normal publishes the real shared collection before its model response', () async {
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
    expect(_text(request), contains('NATIVE MAIN'));
    expect(_text(request), contains('U[NATIVE INPUT]'));
    expect(_text(request), isNot(contains('MODEL RESPONSE')));
    expect(_text(request), isNot(contains('RAW INPUT')));
  });

  test('Quiet ordinary assembly publishes controls while native raw retains its existing ABI', () async {
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
      {'role': 'system', 'content': 'QUIET MAIN'},
      {'role': 'system', 'content': 'QUIET CONTROL'},
    ]);
  });

  test('Conditional gate reads current input first and removes the old tag after squash', () async {
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
    expect(replaced, 'OLD  MAIN|U[OLD  INPUT]');
    expect(replaced, isNot(contains('[[GO]]')));
  });

  test('An initialized empty collection replaces raw input with a real empty message array', () async {
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
    expect(generationMessages(await _rawRequest(h, context.id, 'RAW')), isEmpty);
  });

  test('Normal separate reads the pre-injection manager instead of the mutated getChat body', () async {
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
      {'role': 'system', 'content': 'MAIN'},
      {'role': 'assistant', 'content': 'U[INPUT]'},
    ]);
    expect(jsonEncode(wire.body), isNot(contains('injected_call')));
    expect(_text(await _rawRequest(h, context.id, 'RAW')), 'MAIN|U[INPUT]');
  });

  for (final systemSquash in [false, true]) {
    test('Header classification follows actual collection topology: system squash $systemSquash', () async {
      final h = await generationFixture();
      final actor = await h.card('Header actor', description: 'DESCRIPTION');
      final context = await h.context(await h.emptyChat(actor));
      await h.engine.setPreset(
        ChatPreset({..._preset('MAIN').raw, 'new_chat_prompt': 'HEADER', 'squash_system_messages': systemSquash}),
      );
      await _normal(h, context.id, 'INPUT');
      await h.engine.setPreset(_preset('CURRENT', separate: true));
      final messages = generationMessages(await _rawRequest(h, context.id, 'RAW'));
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
          ..._preset('MAIN').raw,
          'continue_prefill': false,
          'continue_nudge_prompt': 'NUDGE',
          'continue_postfix': '',
          'squash_system_messages': systemSquash,
        }),
      );
      h.reply('MODEL APPEND');
      final continuation = ScriptEvents(h.engine.continueReply(chat, (await h.engine.path(chat)).last.nodeId));
      await continuation.done.future;
      expect(continuation.values.whereType<TavernTurnFailed>(), isEmpty);
      await h.engine.setPreset(_preset('CURRENT', separate: true));
      if (systemSquash) {
        final generation = await h.bridge.generateRaw(context.id, _raw('RAW'));
        final error = await generationFailure(generation);
        expect(error.code, TavernScriptErrorCode.hookFailure);
        expect(error.message, contains('logical identifier'));
        expect(h.requests, hasLength(1));
      } else {
        expect(generationMessages(await _rawRequest(h, context.id, 'RAW')), [
          {'role': 'system', 'content': 'MAIN'},
          {'role': 'assistant', 'content': 'U[HISTORY]'},
          {'role': 'assistant', 'content': 'CONTINUED'},
          {'role': 'system', 'content': 'NUDGE'},
        ]);
      }
    });
  }

  test('Failed mandatory admission replaces the previous cache with actual partial root', () async {
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
      {'role': 'system', 'content': 'PARTIAL MAIN'},
    ]);
  });

  test('Cancellation after assembly retains the published collection for later Helper raw', () async {
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
    expect(_text(await _rawRequest(h, context.id, 'RAW')), 'CANCELLED MAIN|U[CANCELLED INPUT]');
  });

  test('Per-chat snapshots share same-chat contexts and reset only the addressed page', () async {
    final h = await generationFixture();
    final actor = await h.card('Partition actor');
    final chatA = await h.emptyChat(actor), chatB = await h.emptyChat(actor);
    final a = await h.context(chatA), b = await h.context(chatB);
    final aScript = await h.context(chatA, instanceId: 'same-page-script');
    await h.engine.setPreset(_preset('MAIN'));
    await _normal(h, a.id, 'A');
    await _normal(h, b.id, 'B');
    await h.engine.setPreset(_preset('CURRENT', separate: true));
    expect(_text(await _rawRequest(h, aScript.id, 'RAW')), 'MAIN|U[A]');
    expect(_text(await _rawRequest(h, b.id, 'RAW')), 'MAIN|U[B]');
    (h.engine as TavernSPresetPageLifecycle).resetSPresetPage(chatA);
    final missing = await h.bridge.generateRaw(a.id, _raw('RAW'));
    expect((await generationFailure(missing)).message, contains('PromptManager'));
    expect(_text(await _rawRequest(h, b.id, 'RAW')), 'MAIN|U[B]');
    await h.engine.setPreset(_preset('NEW MAIN'));
    await _normal(h, aScript.id, 'NEW A');
    await h.engine.setPreset(_preset('CURRENT', separate: true));
    expect(_text(await _rawRequest(h, a.id, 'RAW')), 'NEW MAIN|U[NEW A]');
    h.bridge.attachHost(ScriptHost());
    final replaced = await h.bridge.generateRaw(b.id, _raw('RAW'));
    expect((await generationFailure(replaced)).message, contains('PromptManager'));
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
    expect(_text(await _rawRequest(h, context.id, 'RAW')), 'NEW MAIN|U[NEW INPUT]');
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

  test('Detached authoring preview does not replace the active page collection', () async {
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
    expect(_text(await _rawRequest(h, context.id, 'RAW')), 'ACTIVE MAIN|U[ACTIVE INPUT]');
  });

  for (final separateDuringNormal in [false, true]) {
    test(
      'Normal image-array getChat mutation does not replace the shared source marker: $separateDuringNormal',
      () async {
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
        expect(jsonEncode(original.body).contains('image_url'), !separateDuringNormal);
        if (separateDuringNormal) expect(_text(original), contains('__IMG_ARRAY_MARKER_'));
        await h.engine.setPreset(_preset('CURRENT', separate: true));
        final reread = await _rawRequest(h, context.id, 'RAW');
        expect(_text(reread), 'MAIN|U[IMAGE INPUT__IMG_ARRAY_MARKER_]');
        expect(jsonEncode(reread.body), isNot(contains('image_url')));
        expect(jsonEncode(reread.body), isNot(contains('helper-image-')));
      },
    );
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
