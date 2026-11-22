@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:mirrors' as mirrors;

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'spreset_engine_test.dart' show SPresetHost, preset, toolExtension;
import 'support/stage1_engine_harness.dart';
import 'support/t24_engine_harness.dart' show T24Events;

// These core tests use the real engine/host lifecycle. Mirrors only select the
// private Helper prompt-path entry before the separate Helper DTO patch lands;
// they do not claim end-to-end coverage of the new public Helper API.
class _EntryHost extends SPresetHost {
  int conditionCalls = 0;
  final conditionEntered = Completer<void>();
  Future<bool> Function()? condition;

  @override
  Future<TavernSPresetEvaluationResult> evaluateSPreset(
    TavernSPresetEvaluationRequest request,
    TavernScriptCancellation cancellation,
  ) async {
    if (request.stage != 'EntryCondition') return super.evaluateSPreset(request, cancellation);
    evaluations.add(request);
    conditionCalls++;
    if (!conditionEntered.isCompleted) conditionEntered.complete();
    final value = await (condition?.call() ?? Future.value(false));
    return TavernSPresetEvaluationResult(requestId: request.requestId, value: value, arguments: request.arguments);
  }
}

ChatPreset _conditionalPreset() {
  final raw = preset(toolExtension(), calling: true).raw;
  final entry = (raw['prompts']! as List<Object?>).cast<Map<String, Object?>>().singleWhere(
    (value) => value['identifier'] == 'fixture-slot',
  );
  entry.addAll({
    'content': 'conditionally-visible',
    'spreset_condition_enabled': true,
    'spreset_condition_script': 'synthetic-false-condition',
  });
  return ChatPreset(raw);
}

bool _enabled(Map<String, Object?> value) {
  final group = (value['prompt_order']! as List<Object?>).cast<Map<String, Object?>>().singleWhere(
    (entry) => entry['character_id'] == 100001,
  );
  return (group['order']! as List<Object?>).cast<Map<String, Object?>>().singleWhere(
        (entry) => entry['identifier'] == 'fixture-slot',
      )['enabled'] ==
      true;
}

class _CorePath {
  _CorePath(Stage1Harness h, this.path, {String? chatId}) {
    final library = mirrors.reflect(h.engine).type.owner! as mirrors.LibraryMirror;
    final generationType =
        library.declarations[mirrors.MirrorSystem.getSymbol('_SPresetGeneration', library)]! as mirrors.ClassMirror;
    final pathType =
        library.declarations[mirrors.MirrorSystem.getSymbol('_SPresetPromptPath', library)]! as mirrors.ClassMirror;
    selectedPath = pathType.getField(Symbol(path)).reflectee;
    instance = generationType.newInstance(
      const Symbol(''),
      [h.engine],
      {
        #chatId: chatId ?? h.chatId,
        #generationId: 'same-public-entry-id',
        #cancellation: cancellation,
        #settings: <String, Object?>{},
        #model: h.config,
        #onIssue: (TavernScriptIssue issue) => issues.add(issue),
        #preset: _conditionalPreset().raw,
      },
    );
    addTearDown(close);
  }

  final String path;
  final cancellation = ModelCancellation();
  final issues = <TavernScriptIssue>[];
  late final mirrors.InstanceMirror instance;
  late final Object? selectedPath;

  Future<Map<String, Object?>> prepare() =>
      instance
              .invoke(
                #preparePreset,
                [
                  'normal',
                  () {
                    if (path != 'native') throw StateError('Helper must not read chat for new condition evaluation.');
                    return <Map<String, Object?>>[];
                  },
                ],
                {#path: selectedPath},
              )
              .reflectee
          as Future<Map<String, Object?>>;

  List<Object?> get tools => (instance.getField(#tools).reflectee! as List).cast<Object?>();
  Future<void> close() => instance.invoke(#close, const []).reflectee as Future<void>;
}

void _globalStop(Stage1Harness h, {String? chatId}) {
  final library = mirrors.reflect(h.engine).type.owner! as mirrors.LibraryMirror;
  mirrors.reflect(h.engine).invoke(mirrors.MirrorSystem.getSymbol('_clearSPresetEntryDecisions', library), [
    chatId ?? h.chatId,
  ]);
}

Future<Stage1Active> _startChat(Stage1Harness h, String chatId) async {
  final call = h.model.prepare();
  final events = T24Events(h.engine.send(chatId, 'other chat question'));
  await Stage1Harness.listening(call, events);
  return Stage1Active(call, events);
}

void _releaseModels(Stage1Harness h) {
  // Also settle the real engine on the pre-fix red assertion path. The test
  // owns these synthetic sources; no production timeout/drain is changed.
  addTearDown(() async {
    for (final call in h.model.allCalls) {
      if (call.cancellation == null) {
        unawaited(call.close());
      } else {
        await call.close();
      }
    }
    stdout.writeln('SPRESET_ENTRY_PAGE_CLEANUP');
  });
}

void main() {
  test('Helper defaults without an active map and never freshly evaluates entry conditions', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    final host = _EntryHost();
    h.engine.scripts.attachHost(host);
    for (final path in ['helperPreset', 'helperRaw']) {
      final helper = _CorePath(h, path);
      expect(_enabled(await helper.prepare()), isTrue);
      expect(helper.tools, hasLength(1));
    }
    expect(host.conditionCalls, 0);
  });

  test('active native decisions affect Helper preset prompts and both tool paths, but not raw prompts', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    final host = _EntryHost();
    h.engine.scripts.attachHost(host);
    await h.engine.setPreset(_conditionalPreset());
    final native = await h.start();
    expect(host.conditionCalls, 1);
    final normal = _CorePath(h, 'helperPreset');
    expect(_enabled(await normal.prepare()), isFalse);
    expect(normal.tools, isEmpty);
    await normal.close();
    final raw = _CorePath(h, 'helperRaw');
    expect(_enabled(await raw.prepare()), isTrue);
    expect(raw.tools, isEmpty);
    await raw.close();
    expect(host.conditionCalls, 1);
    // Helper completion/close does not clear the active native decision map.
    final stillActive = _CorePath(h, 'helperPreset');
    expect(_enabled(await stillActive.prepare()), isFalse);
    await stage1Finish(native.call, content: 'done');
    await native.events.done.future;
    final afterEnd = _CorePath(h, 'helperPreset');
    expect(_enabled(await afterEnd.prepare()), isTrue);
    expect(afterEnd.tools, hasLength(1));
    expect(host.conditionCalls, 1);
  });

  test('global STOP clears the current map without cancelling an active native generation', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    final host = _EntryHost();
    h.engine.scripts.attachHost(host);
    await h.engine.setPreset(_conditionalPreset());
    final native = await h.start();
    _globalStop(h);
    final helper = _CorePath(h, 'helperPreset');
    expect(_enabled(await helper.prepare()), isTrue);
    expect(helper.tools, hasLength(1));
    await stage1Finish(native.call, content: 'still alive');
    await native.events.done.future;
    expect(native.events.values.whereType<TavernTurnDone>().single.message.text, 'still alive');
    expect(host.conditionCalls, 1);
  });

  test('a still-live condition evaluation can publish after an unrelated global STOP', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    final gate = Completer<bool>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(false);
    });
    final host = _EntryHost()..condition = () => gate.future;
    h.engine.scripts.attachHost(host);
    final native = _CorePath(h, 'native');
    final pending = native.prepare();
    await host.conditionEntered.future;
    final before = _CorePath(h, 'helperPreset');
    expect(_enabled(await before.prepare()), isTrue);
    _globalStop(h);
    gate.complete(false);
    expect(_enabled(await pending), isFalse);
    final after = _CorePath(h, 'helperPreset');
    expect(_enabled(await after.prepare()), isFalse);
    expect(host.conditionCalls, 1);
  });

  test('cancelled native evaluation cannot republish after its actual global END', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    final gate = Completer<bool>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(false);
    });
    final host = _EntryHost()..condition = () => gate.future;
    h.engine.scripts.attachHost(host);
    await h.engine.setPreset(_conditionalPreset());
    final events = T24Events(h.engine.send(h.chatId, 'cancel during entry'));
    await Future.any([
      host.conditionEntered.future,
      events.done.future.then((_) => throw TestFailure('Generation ended before entry evaluation.')),
    ]);
    h.engine.stop(h.chatId);
    await events.done.future;
    expect(events.values.whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
    gate.complete(false);
    final helper = _CorePath(h, 'helperPreset');
    expect(_enabled(await helper.prepare()), isTrue);
    expect(helper.tools, hasLength(1));
    expect(h.model.generated, 0);
    expect(host.conditionCalls, 1);
  });

  test('page host replacement discards the old active map without evaluating Helper conditions', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    final oldHost = _EntryHost();
    h.engine.scripts.attachHost(oldHost);
    final native = _CorePath(h, 'native');
    expect(_enabled(await native.prepare()), isFalse);
    final nextHost = _EntryHost();
    h.engine.scripts.attachHost(nextHost);
    final helper = _CorePath(h, 'helperPreset');
    expect(_enabled(await helper.prepare()), isTrue);
    expect(helper.tools, hasLength(1));
    expect(oldHost.conditionCalls, 1);
    expect(nextHost.conditionCalls, 0);
  });

  test('active decisions stay with their chat canvas across other-chat generation and end', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    _releaseModels(h);
    final chatB = await h.engine.createChat(h.characterId);
    final host = _EntryHost();
    h.engine.scripts.attachHost(host);
    await h.engine.setPreset(_conditionalPreset());
    final nativeA = await h.start();
    final helperA = _CorePath(h, 'helperPreset');
    expect(_enabled(await helperA.prepare()), isFalse);
    final isolatedB = _CorePath(h, 'helperPreset', chatId: chatB);
    expect(_enabled(await isolatedB.prepare()), isTrue);
    expect(isolatedB.tools, hasLength(1));
    expect(host.conditionCalls, 1);

    final nativeB = await _startChat(h, chatB);
    final activeA = _CorePath(h, 'helperPreset');
    final activeB = _CorePath(h, 'helperPreset', chatId: chatB);
    expect(_enabled(await activeA.prepare()), isFalse);
    expect(_enabled(await activeB.prepare()), isFalse);
    expect(host.conditionCalls, 2);

    await stage1Finish(nativeB.call, content: 'B finished');
    await nativeB.events.done.future;
    final afterB = _CorePath(h, 'helperPreset', chatId: chatB);
    expect(_enabled(await afterB.prepare()), isTrue);
    expect(afterB.tools, hasLength(1));
    final preservedA = _CorePath(h, 'helperPreset');
    expect(_enabled(await preservedA.prepare()), isFalse);
    expect(preservedA.tools, isEmpty);
    expect(nativeA.events.done.isCompleted, isFalse);
    await stage1Finish(nativeA.call, content: 'A finished');
    await nativeA.events.done.future;
    final afterA = _CorePath(h, 'helperPreset');
    expect(_enabled(await afterA.prepare()), isTrue);
  });

  test('other-chat actual cancellation and scoped STOP leave native A decisions active', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    _releaseModels(h);
    final chatB = await h.engine.createChat(h.characterId);
    final host = _EntryHost();
    h.engine.scripts.attachHost(host);
    await h.engine.setPreset(_conditionalPreset());
    final nativeA = await h.start();
    final nativeB = await _startChat(h, chatB);
    h.engine.stop(chatB);
    await nativeB.events.done.future;
    expect(nativeB.events.values.whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
    _globalStop(h, chatId: chatB);
    final helperA = _CorePath(h, 'helperPreset');
    final helperB = _CorePath(h, 'helperPreset', chatId: chatB);
    expect(_enabled(await helperA.prepare()), isFalse);
    expect(_enabled(await helperB.prepare()), isTrue);
    final rawA = _CorePath(h, 'helperRaw');
    expect(_enabled(await rawA.prepare()), isTrue);
    expect(rawA.tools, isEmpty);
    expect(host.conditionCalls, 2);
    await stage1Finish(nativeA.call, content: 'A survives B stop');
    await nativeA.events.done.future;
  });

  test('script contexts on the same chat share canvas decisions and a context close does not clear them', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    _releaseModels(h);
    final host = _EntryHost();
    h.engine.scripts.attachHost(host);
    final first = await h.engine.scripts.openContext(
      TavernScriptContextSpec(instanceId: 'canvas:first', chatId: h.chatId),
    );
    final second = await h.engine.scripts.openContext(
      TavernScriptContextSpec(instanceId: 'canvas:second', chatId: h.chatId),
    );
    await h.engine.setPreset(_conditionalPreset());
    final native = await h.start();
    for (final context in [first, second]) {
      final helper = _CorePath(h, 'helperPreset', chatId: context.chatId);
      expect(_enabled(await helper.prepare()), isFalse);
      expect(helper.tools, isEmpty);
    }
    await h.engine.scripts.closeContext(first.id);
    final afterSiblingClose = _CorePath(h, 'helperPreset', chatId: second.chatId);
    expect(_enabled(await afterSiblingClose.prepare()), isFalse);
    expect(host.conditionCalls, 1);
    await stage1Finish(native.call, content: 'done');
    await native.events.done.future;
    await h.engine.scripts.closeContext(second.id);
  });

  test('host replacement clears every chat canvas without fresh Helper evaluation', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    final chatB = await h.engine.createChat(h.characterId);
    final oldHost = _EntryHost();
    h.engine.scripts.attachHost(oldHost);
    for (final chatId in [h.chatId, chatB]) {
      final native = _CorePath(h, 'native', chatId: chatId);
      expect(_enabled(await native.prepare()), isFalse);
    }
    final nextHost = _EntryHost();
    h.engine.scripts.attachHost(nextHost);
    for (final chatId in [h.chatId, chatB]) {
      final helper = _CorePath(h, 'helperPreset', chatId: chatId);
      expect(_enabled(await helper.prepare()), isTrue);
      expect(helper.tools, hasLength(1));
    }
    expect(oldHost.conditionCalls, 2);
    expect(nextHost.conditionCalls, 0);
  });

  test('an unscoped generation neither borrows nor replaces a chat canvas decision map', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    final host = _EntryHost();
    h.engine.scripts.attachHost(host);
    final nativeA = _CorePath(h, 'native');
    expect(_enabled(await nativeA.prepare()), isFalse);
    final unscopedHelper = _CorePath(h, 'helperPreset', chatId: '');
    expect(_enabled(await unscopedHelper.prepare()), isTrue);
    expect(unscopedHelper.tools, hasLength(1));
    final unscopedNative = _CorePath(h, 'native', chatId: '');
    expect(_enabled(await unscopedNative.prepare()), isFalse);
    _globalStop(h, chatId: '');
    final sameChat = _CorePath(h, 'helperPreset');
    expect(_enabled(await sameChat.prepare()), isFalse);
    final unscopedAfter = _CorePath(h, 'helperPreset', chatId: '');
    expect(_enabled(await unscopedAfter.prepare()), isTrue);
    expect(host.conditionCalls, 2);
  });
}
