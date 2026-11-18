import 'dart:async';
import 'dart:io';

import 'package:dsh_app/tavern/deferred_tavern.dart';
import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_test/flutter_test.dart';

class _Run implements TavernAuthoringRun {
  _Run(this.runId);

  @override
  final String runId;
  var cancelled = false;

  @override
  Stream<TavernAuthoringRunEvent> get events => const Stream.empty();

  @override
  Future<TavernAuthoringRunSnapshot> get result => Completer<TavernAuthoringRunSnapshot>().future;

  @override
  Future<void> cancel() async => cancelled = true;
}

/// A trial the engine started: what it shows so far, and whether it was stopped.
class _Simulation implements TavernAuthoringSimulationTask {
  var cancelled = false;

  @override
  String get requestId => 't1';

  @override
  TavernAuthoringSimulationResult get view => const TavernAuthoringSimulationResult(
    requestId: 't1',
    captureId: 'engine-capture',
    draftId: 'd1',
    draftRevision: 1,
    changeIds: [],
    status: TavernAuthoringSimulationStatus.running,
    origin: {},
    turns: [],
    requests: [],
    usage: {},
    cleanup: {},
    issues: [],
  );

  @override
  Future<TavernAuthoringSimulationResult> get result => Completer<TavernAuthoringSimulationResult>().future;

  @override
  Future<void> cancel() async => cancelled = true;
}

class _Authoring extends PreviewTavern {
  _Authoring() : super(tick: Duration.zero);

  TavernAuthoringSimulationRequest? tried;

  @override
  TavernAuthoringSimulationTask simulateAuthoringDraft(TavernAuthoringSimulationRequest request) {
    tried = request;
    return _Simulation();
  }

  _Run? started;

  @override
  TavernAuthoringRun startAuthoringRun(
    TavernAuthoringRunRequest request, {
    TavernAuthoringPromptHost? promptHost,
    TavernAuthoringPreviewHost? renderHost,
  }) => started = _Run(request.runId);
}

void main() {
  test('an authoring run asked for before it opens has its id at once and starts once it opens', () async {
    final opening = Completer<Tavern>();
    final deferred = DeferredTavern(opening.future);
    final run = deferred.startAuthoringRun(
      const TavernAuthoringRunRequest(runId: 'r1', draftId: 'd1', draftRevision: 1, instruction: '写一张卡'),
    );
    expect(run.runId, 'r1');

    final engine = _Authoring();
    opening.complete(engine);
    await run.cancel();
    expect(engine.started?.runId, 'r1');
    expect(engine.started!.cancelled, isTrue);
  });

  test('a trial asked for before it opens shows nothing run yet, then the engine\'s own', () async {
    final opening = Completer<Tavern>();
    final deferred = DeferredTavern(opening.future);
    final trial = deferred.simulateAuthoringDraft(
      TavernAuthoringSimulationRequest(
        requestId: 't1',
        draftId: 'd1',
        draftRevision: 1,
        changeIds: const [],
        context: const TavernAuthoringSampleContext(characterResourceId: 'character:lin'),
        userInputs: const ['你好'],
        at: DateTime.utc(2026, 11, 14),
        seed: 1,
      ),
    );
    expect(trial.requestId, 't1');
    expect(trial.view.status, TavernAuthoringSimulationStatus.running);
    expect(trial.view.turns, isEmpty);

    final engine = _Authoring();
    opening.complete(engine);
    await trial.cancel();
    expect(engine.tried!.userInputs, ['你好']);
    expect(trial.view.captureId, 'engine-capture');
  });

  test('calls and streams wait for the tavern to open; configure reaches it then', () async {
    final opening = Completer<Tavern>();
    final deferred = DeferredTavern(opening.future)
      ..configure(TavernModelConfig(apiKey: () async => 'k', thinking: true));

    final characters = deferred.watchCharacters().first;
    final chat = deferred.createChat('sample-innkeeper');
    deferred.stop('nothing yet'); // no turn can run before it opens

    final preview = PreviewTavern(tick: const Duration(milliseconds: 1));
    opening.complete(preview);

    expect((await characters).map((c) => c.name), containsAll(['林晚', '星图']));
    final events = await deferred.send(await chat, '你好').toList();
    // The thinking set before it opened applies: the reply thinks first.
    expect(events.whereType<TavernReasoningDelta>(), isNotEmpty);
    expect(events.last, isA<TavernTurnDone>());
  });

  test('card scripts: one bridge; before it opens it claims nothing; the host set early reaches it', () async {
    final opening = Completer<Tavern>();
    final deferred = DeferredTavern(opening.future);
    final bridge = deferred.scripts;
    expect(identical(bridge, deferred.scripts), isTrue);
    expect(bridge.capabilities.methods, isEmpty);
    expect(bridge.capabilities.simulated, isFalse);
    bridge.attachHost(_Host());
    expect(bridge.capabilities.hostAttached, isTrue);
    final refused = bridge.getVariables('c', const TavernVariableTarget(scope: TavernVariableScope.global));

    final preview = PreviewTavern(tick: Duration.zero);
    opening.complete(preview);
    await expectLater(
      refused,
      throwsA(isA<TavernScriptException>().having((e) => e.code, 'code', TavernScriptErrorCode.unsupportedCapability)),
    );
    // Open: what the preview says, with the host handed over.
    expect(bridge.capabilities.simulated, isTrue);
    expect(bridge.capabilities.hostAttached, isTrue);
    expect(preview.scripts.capabilities.hostAttached, isTrue);
    bridge.attachHost(null);
    expect(preview.scripts.capabilities.hostAttached, isFalse);
  });

  test('card scripts reach the real engine: a global variable written, read back, and kept', () async {
    final dir = await Directory.systemTemp.createTemp('deferred-scripts');
    addTearDown(() => dir.delete(recursive: true));
    const global = TavernVariableTarget(scope: TavernVariableScope.global);
    final opening = Completer<Tavern>();
    final deferred = DeferredTavern(opening.future);
    final context = deferred.scripts.openContext(const TavernScriptContextSpec(instanceId: 'frame'));
    opening.complete(await openTavern(dir.path));

    final id = (await context).id;
    final value = <String, Object?>{
      'hp': 7,
      'bag': ['key'],
    };
    final saved = await deferred.scripts.replaceVariables(id, global, value);
    // The engine took it as it was at the call.
    (value['bag']! as List).add('map');
    expect(saved.value, {
      'hp': 7,
      'bag': ['key'],
    });
    expect(deferred.scripts.capabilities.simulated, isFalse);
    expect(deferred.scripts.capabilities.methods, contains('replaceVariables'));
    await deferred.close();

    // Opened again: still there.
    final again = DeferredTavern(openTavern(dir.path));
    addTearDown(again.close);
    final reopened = await again.scripts.openContext(const TavernScriptContextSpec(instanceId: 'frame'));
    expect((await again.scripts.getVariables(reopened.id, global)).value, {
      'hp': 7,
      'bag': ['key'],
    });
  });

  test('B2 reaches the real engine too: a prompt injected for a chat is listed, then taken out', () async {
    final dir = await Directory.systemTemp.createTemp('deferred-b2');
    addTearDown(() => dir.delete(recursive: true));
    final opening = Completer<Tavern>();
    final deferred = DeferredTavern(opening.future);
    addTearDown(deferred.close);
    // Nothing can be generating before it opens.
    expect(deferred.scripts.stopGenerationById('nothing'), isFalse);
    opening.complete(await openTavern(dir.path));
    final card = await File('assets/tavern/sample_innkeeper.json').readAsBytes();
    final character = await deferred.importCard(card, fileName: 'sample_innkeeper.json');
    final chat = await deferred.createChat(character.id);
    final context = await deferred.scripts.openContext(TavernScriptContextSpec(instanceId: 'frame', chatId: chat));

    await deferred.scripts.injectPrompts(context.id, [TavernScriptInjection(id: 'weather', content: '外面在下雨。')]);
    final listed = await deferred.scripts.listInjections(context.id);
    expect(listed.map((v) => v.injection?.content), contains('外面在下雨。'));
    await deferred.scripts.uninjectPrompts(context.id, ['weather']);
    expect(
      (await deferred.scripts.listInjections(context.id)).map((v) => v.injection?.content),
      isNot(contains('外面在下雨。')),
    );
    expect(deferred.scripts.stopGenerationById('nothing'), isFalse);
  });

  test('the preview says it does not simulate B2 either', () async {
    final preview = PreviewTavern(tick: Duration.zero);
    await expectLater(
      preview.scripts.listInjections('c'),
      throwsA(isA<TavernScriptException>().having((e) => e.code, 'code', TavernScriptErrorCode.unsupportedCapability)),
    );
    expect(preview.scripts.stopGenerationById('g'), isFalse);
  });

  test('B3 reaches the real engine: a Slash script, macros, and the card book read and replaced', () async {
    final dir = await Directory.systemTemp.createTemp('deferred-b3');
    addTearDown(() => dir.delete(recursive: true));
    final opening = Completer<Tavern>();
    final deferred = DeferredTavern(opening.future);
    addTearDown(deferred.close);
    // Nothing can be running before it opens.
    expect(deferred.scripts.stopScript('nothing'), isFalse);
    opening.complete(await openTavern(dir.path));
    final card = await File('assets/tavern/sample_innkeeper.json').readAsBytes();
    final character = await deferred.importCard(card, fileName: 'sample_innkeeper.json');
    final chat = await deferred.createChat(character.id);
    final context = await deferred.scripts.openContext(
      TavernScriptContextSpec(instanceId: 'frame', chatId: chat, characterId: character.id),
    );

    final run = await deferred.scripts.triggerSlash(context.id, '/pass {{char}} | /pass 到了', executionId: 'hello');
    expect((await run.result).pipe, '到了');
    expect(deferred.scripts.stopScript('hello'), isFalse);
    expect(await deferred.scripts.substituteMacros(context.id, '{{char}}在柜台后'), '林晚在柜台后');

    final embedded = TavernScriptBookRef.embedded(characterId: character.id);
    final books = await deferred.scripts.getContextBooks(context.id);
    expect(books.map((b) => b.ref).whereType<TavernScriptEmbeddedBookRef>(), isNotEmpty);
    final read = await deferred.scripts.readBook(context.id, embedded);
    expect(read.book['name'], '雨镇');
    final replaced = await deferred.scripts.replaceBook(context.id, embedded, {
      ...read.book,
      'name': '雨镇（改）',
    }, expectedVersion: read.version);
    expect(replaced.book['name'], '雨镇（改）');
    expect(replaced.version, isNot(read.version));
    expect((await deferred.scripts.readBook(context.id, embedded)).book['name'], '雨镇（改）');
    // The old version no longer matches.
    await expectLater(
      deferred.scripts.replaceBook(context.id, embedded, read.book, expectedVersion: read.version),
      throwsA(isA<TavernScriptException>().having((e) => e.code, 'code', TavernScriptErrorCode.revisionConflict)),
    );
  });

  test(
    'B3 before it opens: a card or a book is refused at the call if it is not JSON; the preview runs no Slash',
    () async {
      final opening = Completer<Tavern>();
      final deferred = DeferredTavern(opening.future);
      final loop = <String, Object?>{};
      loop['self'] = loop;
      final embedded = TavernScriptBookRef.embedded(characterId: 'x');
      await expectLater(
        deferred.scripts.replaceCharacterData('c', 'x', loop),
        throwsA(isA<TavernScriptException>().having((e) => e.code, 'code', TavernScriptErrorCode.invalidJson)),
      );
      await expectLater(
        deferred.scripts.replaceBook('c', embedded, loop),
        throwsA(isA<TavernScriptException>().having((e) => e.code, 'code', TavernScriptErrorCode.invalidJson)),
      );

      final preview = PreviewTavern(tick: Duration.zero);
      final unsupported = throwsA(
        isA<TavernScriptException>().having((e) => e.code, 'code', TavernScriptErrorCode.unsupportedCapability),
      );
      await expectLater(preview.scripts.triggerSlash('c', '/pass x'), unsupported);
      await expectLater(preview.scripts.substituteMacros('c', '{{char}}'), unsupported);
      await expectLater(preview.scripts.replaceCharacterData('c', 'x', const {}), unsupported);
      await expectLater(preview.scripts.getContextBooks('c'), unsupported);
      await expectLater(preview.scripts.readBook('c', embedded), unsupported);
      await expectLater(preview.scripts.replaceBook('c', embedded, const {}), unsupported);
      expect(preview.scripts.stopScript('s'), isFalse);
      opening.complete(preview);
    },
  );

  test('card scripts before it opens: a value is copied at the call; a cycle is refused there', () async {
    final opening = Completer<Tavern>();
    final deferred = DeferredTavern(opening.future);
    const global = TavernVariableTarget(scope: TavernVariableScope.global);
    final loop = <String, Object?>{};
    loop['self'] = loop;
    await expectLater(
      deferred.scripts.replaceVariables('c', global, loop),
      throwsA(isA<TavernScriptException>().having((e) => e.code, 'code', TavernScriptErrorCode.invalidJson)),
    );
    // A plain value waits, copied: the preview then refuses it as unsimulated.
    final value = <String, Object?>{'hp': 7};
    final waiting = deferred.scripts.replaceVariables('c', global, value);
    value['hp'] = 0;
    opening.complete(PreviewTavern(tick: Duration.zero));
    await expectLater(waiting, throwsA(isA<TavernScriptException>()));
  });

  test('the libraries and the display pass reach the engine once it opens (T20, T21)', () async {
    final preview = PreviewTavern(tick: Duration.zero);
    final chat = await preview.createChat('sample-innkeeper');
    final deferred = DeferredTavern(Future.value(preview));

    expect(await deferred.listPresets(), isEmpty);
    expect(await deferred.watchPresets().first, isEmpty);
    expect((await deferred.presetSelection(chatId: chat)).source, PresetSelectionSource.stDefault);
    expect(await deferred.listRegexScripts(), isEmpty);
    expect(await deferred.listLorebooks(), isEmpty);
    expect((await deferred.displayText(chat, text: '*她笑了*')).text, '*她笑了*');
    // Presets and lorebooks go through to the preview's own.
    final imported = await deferred.importPreset('{"temperature": 1}', fileName: 'a.json');
    expect((await deferred.listPresets()).single.id, imported.preset.id);
    final book = await deferred.importLorebook('{"entries": {"0": {"content": "x"}}}', fileName: 'w.json');
    expect((await deferred.listLorebooks()).single.id, book.book.id);
  });

  test('the script library waits for the tavern to open; its watches start then', () async {
    final opening = Completer<Tavern>();
    final deferred = DeferredTavern(opening.future);
    final library = deferred.watchGlobalScripts().firstWhere((l) => l.isNotEmpty);
    final running = deferred.watchChatScripts('c1', characterId: 'x').firstWhere((c) => c.scripts.isNotEmpty);
    final imported = deferred.importGlobalScripts(
      '{"type":"script","id":"s1","name":"状态栏","enabled":true,"content":"x"}',
    );

    opening.complete(PreviewTavern(tick: Duration.zero));
    expect((await imported).single.id, 's1');
    expect((await library).single.name, '状态栏');
    final chosen = await running;
    expect((chosen.characterId, chosen.scripts.single.owner.scriptId), ('x', 's1'));
    await deferred.setGlobalScriptEnabled('s1', false);
    expect((await deferred.chatScripts('c1')).scripts, isEmpty);
    expect(await deferred.exportGlobalScripts(id: 's1'), contains('"enabled":false'));
    await deferred.deleteGlobalScript('s1');
    expect(await deferred.listGlobalScripts(), isEmpty);
  });
}

/// A host that never answers: only its presence is looked at.
class _Host implements TavernScriptHost {
  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
