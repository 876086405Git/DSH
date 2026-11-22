import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/tavern/tavern_canvas_calls.dart';
import 'package:dsh_app/tavern/tavern_interact.dart';
import 'package:dsh_app/tavern/tavern_script_host.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory dir;
  late Tavern tavern;
  late String chat;
  late String character;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('script-host');
    tavern = await openTavern(dir.path);
    final card = await File('assets/tavern/sample_innkeeper.json').readAsBytes();
    character = (await tavern.importCard(card, fileName: 'sample_innkeeper.json')).id;
    chat = await tavern.createChat(character);
  });
  tearDown(() async {
    await tavern.close();
    await dir.delete(recursive: true);
  });

  Future<Map<String, Object?>> write(TavernCanvasCalls calls, String scope, Map<String, Object?> value) =>
      calls.handle({
        'id': scope,
        'method': 'replaceVariables',
        'params': {
          'target': {'scope': scope},
          'value': value,
        },
      });

  Map<String, Object?>? variablesIn(List<Map<String, Object?>> deliveries, String scope) {
    for (final d in deliveries.reversed) {
      for (final v in ((d['delta'] as Map?)?['variables'] as List?) ?? const []) {
        if (((v as Map)['target']! as Map)['scope'] == scope) return v['value']! as Map<String, Object?>;
      }
    }
    return null;
  }

  test("the engine's changes reach the page holding the context, in order, as JSON", () async {
    final pages = TavernScriptPages();
    final seen = <Map<String, Object?>>[];
    final page = TavernCanvasCalls(tavern.scripts, chatId: chat, characterId: () => character, pages: pages)
      ..deliver = (d) async {
        seen.add(jsonDecode(jsonEncode(d)) as Map<String, Object?>);
        return true;
      };
    final other = TavernCanvasCalls(
      tavern.scripts,
      chatId: chat,
      characterId: () => character,
      instanceId: 'other',
      pages: pages,
    );
    expect(tavern.scripts.capabilities.hostAttached, isFalse);

    // Its own write comes back to it as the engine kept it.
    expect((await write(page, 'chat', {'hp': 7}))['ok'], isTrue);
    expect(tavern.scripts.capabilities.hostAttached, isTrue);
    expect(seen, isNotEmpty);
    expect(seen.every((d) => d['kind'] == 'cache'), isTrue);
    expect(variablesIn(seen, 'chat'), {'hp': 7});

    // Another page's write to what this one sees reaches it too.
    final before = seen.length;
    expect((await write(other, 'global', {'coins': 3}))['ok'], isTrue);
    expect(seen.length, greaterThan(before));
    expect(variablesIn(seen, 'global'), {'coins': 3});
    final seqs = [for (final d in seen) d['seq']! as int];
    expect(seqs, orderedEquals([...seqs]..sort()));

    // Closed: nothing more for it.
    await page.close();
    final after = seen.length;
    expect((await write(other, 'global', {'coins': 4}))['ok'], isTrue);
    expect(seen.length, after);
    await other.close();
  });

  test('an MVU event is answered with its candidate as the listeners left it', () async {
    final pages = TavernScriptPages();
    pages.add('ctx', (d) async => true);
    final answer = pages.dispatch(
      TavernScriptDispatch(
        kind: TavernScriptDispatchKind.lifecycle,
        eventId: 'm1',
        contextId: 'ctx',
        seq: 1,
        namespace: 'tavern',
        name: 'mag_command_parsed',
        args: [
          <String, Object?>{'stat_data': <String, Object?>{}},
          <Object?>[],
          'raw',
        ],
      ),
      _Never(),
    );
    await Future<void>.delayed(Duration.zero);
    pages.acknowledge('m1', {
      'status': 'completed',
      'mvu': {
        'data': {
          'stat_data': {'好感度': 5},
        },
        'commands': [
          {
            'type': 'set',
            'full_match': "_.set('好感度', 0, 5);",
            'args': ['好感度', '0', '5'],
            'reason': '',
          },
        ],
      },
    });
    final ack = await answer;
    expect(ack.mvu!.data, {
      'stat_data': {'好感度': 5},
    });
    expect(ack.mvu!.commands!.single['type'], 'set');
    expect(ack.mvu!.beforeData, isNull);
    // An answer without one leaves the candidate as it was.
    final plain = pages.dispatch(
      TavernScriptDispatch(kind: TavernScriptDispatchKind.lifecycle, eventId: 'm2', contextId: 'ctx', seq: 2),
      _Never(),
    );
    await Future<void>.delayed(Duration.zero);
    pages.acknowledge('m2', {'status': 'completed'});
    expect((await plain).mvu, isNull);
    // A listener left a command that is not one: not taken, the event failed.
    final bad = pages.dispatch(
      TavernScriptDispatch(kind: TavernScriptDispatchKind.lifecycle, eventId: 'm3', contextId: 'ctx', seq: 3),
      _Never(),
    );
    await Future<void>.delayed(Duration.zero);
    pages.acknowledge('m3', {
      'status': 'completed',
      'mvu': {
        'data': <String, Object?>{},
        'commands': [null],
      },
    });
    final refused = await bad;
    expect(
      (refused.status, refused.mvu, refused.issues.single.code),
      (TavernScriptAckStatus.failed, null, 'invalidArgument'),
    );
  });

  test("a lifecycle event waits for the page's handlers, and says how they went", () async {
    final pages = TavernScriptPages();
    final put = <Map<String, Object?>>[];
    var ready = true;
    pages.add('ctx', (d) async {
      put.add(d);
      return ready;
    });
    TavernScriptDispatch event(String id) => TavernScriptDispatch(
      kind: TavernScriptDispatchKind.lifecycle,
      eventId: id,
      contextId: 'ctx',
      seq: 1,
      namespace: 'tavern',
      name: 'MESSAGE_RECEIVED',
      args: [3, 'normal'],
    );

    // Held until the page answers; its failure comes back as an issue.
    var answered = false;
    final first = pages.dispatch(event('e1'), _Never())..then((_) => answered = true);
    await Future<void>.delayed(Duration.zero);
    expect(answered, isFalse);
    expect(put.single, containsPair('name', 'MESSAGE_RECEIVED'));
    expect(put.single['args'], [3, 'normal']);
    pages.acknowledge('e1', {
      'status': 'failed',
      'issues': [
        {'code': 'hookFailure', 'message': 'boom'},
      ],
    });
    final ack = await first;
    expect((ack.eventId, ack.status), ('e1', TavernScriptAckStatus.failed));
    expect(
      (ack.issues.single.code, ack.issues.single.message, ack.issues.single.eventId),
      ('hookFailure', 'boom', 'e1'),
    );

    // The engine cancels: answered as cancelled; a late answer changes nothing.
    final cancel = _Cancel();
    final second = pages.dispatch(event('e2'), cancel);
    await Future<void>.delayed(Duration.zero);
    cancel.cancel();
    expect((await second).status, TavernScriptAckStatus.cancelled);
    pages.acknowledge('e2', {'status': 'completed'});

    // The page goes before answering: failed, said why.
    final third = pages.dispatch(event('e3'), _Never());
    await Future<void>.delayed(Duration.zero);
    pages.drop('ctx');
    final lost = await third;
    expect((lost.status, lost.issues.single.code), (TavernScriptAckStatus.failed, 'pageGone'));

    // Not ready yet: no handlers ran, and that is the answer.
    ready = false;
    expect((await pages.dispatch(event('e4'), _Never())).status, TavernScriptAckStatus.completed);
  });

  test("a prompt's filter is run by the page that keeps it: its true or false, cancelled, or not to be had", () async {
    final pages = TavernScriptPages();
    final delivered = <Map<String, Object?>>[];
    var ready = true;
    pages.add('ctx', (d) async {
      delivered.add(d);
      return ready;
    });
    TavernScriptCallbackRequest ask(String id, {String context = 'ctx'}) => TavernScriptCallbackRequest(
      requestId: id,
      ref: TavernScriptCallbackRef(contextId: context, instanceId: 'canvas', callbackId: 'k-1'),
      kind: 'filter',
    );

    // Asked of the page by its name; answered with what the page said.
    final first = pages.invoke(ask('r1'), _Never());
    await pumpEventQueue();
    expect(delivered.single['kind'], 'invoke');
    expect(delivered.single['requestId'], 'r1');
    expect(delivered.single['callbackId'], 'k-1');
    expect(delivered.single['args'], isEmpty);
    pages.invoked('r1', {'requestId': 'r1', 'status': 'completed', 'value': false, 'issues': <Object?>[]});
    final r1 = await first;
    expect((r1.requestId, r1.status, r1.value), ('r1', 'completed', false));
    expect(r1.issues, isEmpty);

    // Not true or false: no answer to take. A write that failed unwatched: said.
    final second = pages.invoke(ask('r2'), _Never());
    await pumpEventQueue();
    pages.invoked('r2', {
      'status': 'completed',
      'value': 'yes',
      'issues': [
        {'code': 'storage', 'message': 'A write nobody waited for failed: disk'},
      ],
    });
    final r2 = await second;
    expect((r2.status, r2.value), ('completed', null));
    expect(r2.issues.single.code, 'storage');

    // It threw: failed, with why.
    final third = pages.invoke(ask('r3'), _Never());
    await pumpEventQueue();
    pages.invoked('r3', {'status': 'failed', 'message': 'nope'});
    final r3 = await third;
    expect(r3.status, 'failed');
    expect((r3.issues.single.code, r3.issues.single.message), ('hookFailure', 'nope'));

    // The engine cancelling: cancelled, a late answer changes nothing.
    final cancel = _Cancel();
    final fourth = pages.invoke(ask('r4'), cancel);
    await pumpEventQueue();
    cancel.cancel();
    expect((await fourth).status, 'cancelled');
    pages.invoked('r4', {'status': 'completed', 'value': true});

    // No page for it, a page not ready, a page gone while it ran: not to be had.
    final unavailable = throwsA(
      isA<TavernScriptException>().having((e) => e.code, 'code', TavernScriptErrorCode.callbackUnavailable),
    );
    await expectLater(pages.invoke(ask('r5', context: 'nobody'), _Never()), unavailable);
    ready = false;
    await expectLater(pages.invoke(ask('r6'), _Never()), unavailable);
    ready = true;
    final gone = pages.invoke(ask('r7'), _Never());
    await pumpEventQueue();
    pages.drop('ctx');
    await expectLater(gone, unavailable);
  });

  test("an injection's filter goes as this page's context and instance; listed so, and taken out", () async {
    final pages = TavernScriptPages();
    final calls = TavernCanvasCalls(tavern.scripts, chatId: chat, characterId: () => character, pages: pages);
    final reply = await calls.handle({
      'id': 'i',
      'method': 'injectPrompts',
      'params': {
        'prompts': [
          {
            'id': 'a',
            'content': 'X',
            'position': 'inChat',
            'depth': 2,
            'filter': {'callbackId': 'k-1'},
          },
          {'id': 'b', 'content': 'Y', 'position': 'scanOnly'},
        ],
        'once': false,
      },
    });
    expect(reply['ok'], isTrue, reason: '${reply['error']}');
    final lease = reply['result']! as Map;
    expect([for (final r in lease['registrations']! as List) (r as Map)['id']], ['a', 'b']);
    expect(lease['ownerInstanceId'], 'canvas');

    List<Map<Object?, Object?>> listed(Map<String, Object?> reply) => [
      for (final v in reply['result']! as List)
        if (((v as Map)['injection'] as Map?)?['id'] case 'a' || 'b') v,
    ];
    final views = listed(await calls.handle({'id': 'l', 'method': 'listInjections', 'params': <String, Object?>{}}));
    expect(views, hasLength(2));
    final a = views.firstWhere((v) => (v['injection']! as Map)['id'] == 'a');
    expect((a['injection']! as Map)['filter'], {
      'contextId': lease['ownerContextId'],
      'instanceId': 'canvas',
      'callbackId': 'k-1',
    });
    expect((a['injection']! as Map)['position'], 'inChat');
    final b = views.firstWhere((v) => (v['injection']! as Map)['id'] == 'b');
    expect((b['injection']! as Map)['filter'], isNull);

    final out = await calls.handle({
      'id': 'u',
      'method': 'uninjectPrompts',
      'params': {
        'ids': ['a', 'b'],
      },
    });
    expect(out['ok'], isTrue, reason: '${out['error']}');
    expect(
      listed(await calls.handle({'id': 'l2', 'method': 'listInjections', 'params': <String, Object?>{}})),
      isEmpty,
    );
    await calls.close();
  });

  test(
    "a script's /input, /buttons and /setinput are asked by the chat's screen, answered with what was done",
    () async {
      final pages = TavernScriptPages()..attach(tavern.scripts);
      final context = await tavern.scripts.openContext(
        TavernScriptContextSpec(instanceId: 'canvas', chatId: chat, characterId: character),
      );
      final asked = <(TavernInteractKind, Map<String, Object?>)>[];
      final answers = [
        const TavernInteractAnswer(TavernInteractStatus.submitted, text: '阿青'),
        const TavernInteractAnswer(TavernInteractStatus.submitted, buttonIndex: 1, label: '西'),
        const TavernInteractAnswer(TavernInteractStatus.submitted, text: '再来一杯'),
      ];
      pages.add(
        context.id,
        (_) async => false,
        interact: (kind, fields, {required withdraw}) async {
          asked.add((kind, fields));
          return answers.removeAt(0);
        },
      );

      final input = await tavern.scripts.triggerSlash(context.id, '/input 你叫什么');
      expect((await input.result).pipe, '阿青');
      final buttons = await tavern.scripts.triggerSlash(
        context.id,
        '/buttons labels={{arg::labels}} 往哪走',
        arguments: const {'labels': '["东","西"]'},
      );
      expect((await buttons.result).pipe, '西');
      final set = await tavern.scripts.triggerSlash(context.id, '/setinput 再来一杯');
      expect((await set.result).pipe, '再来一杯');

      expect(asked.map((a) => a.$1), [
        TavernInteractKind.input,
        TavernInteractKind.buttons,
        TavernInteractKind.setInput,
      ]);
      expect(asked[0].$2['text'], '你叫什么');
      expect(asked[1].$2['buttonLabels'], ['东', '西']);
    },
  );

  test('a request on screen is taken back when the script is stopped, or its page closes', () async {
    final pages = TavernScriptPages()..attach(tavern.scripts);
    final context = await tavern.scripts.openContext(
      TavernScriptContextSpec(instanceId: 'canvas', chatId: chat, characterId: character),
    );
    final showing = <Completer<void>>[];
    pages.add(
      context.id,
      (_) async => false,
      interact: (kind, fields, {required withdraw}) async {
        final shown = Completer<void>()..complete();
        showing.add(shown);
        await withdraw;
        return const TavernInteractAnswer(TavernInteractStatus.cancelled);
      },
    );

    final run = await tavern.scripts.triggerSlash(context.id, '/input 等一下', executionId: 'waiting');
    while (showing.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(tavern.scripts.stopScript('waiting'), isTrue);
    await expectLater(
      run.result,
      throwsA(isA<TavernScriptException>().having((e) => e.code, 'code', TavernScriptErrorCode.cancelled)),
    );

    // The page closing takes back what its scripts asked.
    final asked = pages.interact(
      TavernScriptUiRequest(requestId: 'r2', contextId: context.id, executionId: 'e2', kind: 'popup'),
      _Never(),
    );
    while (showing.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    pages.remove(context.id);
    final answer = await asked;
    expect((answer.requestId, answer.status), ('r2', 'cancelled'));
  });

  test('a canvas hands its chat screen to the host with its context', () async {
    final pages = _Recording();
    final calls = TavernCanvasCalls(
      tavern.scripts,
      chatId: chat,
      characterId: () => character,
      pages: pages,
      interact: (kind, fields, {required withdraw}) async => const TavernInteractAnswer(TavernInteractStatus.dismissed),
    );
    final out = await calls.handle({
      'id': 1,
      'method': 'getVariables',
      'params': {
        'target': {'scope': 'chat'},
      },
    });
    expect(out['ok'], isTrue, reason: '${out['error']}');
    expect(pages.interactors, hasLength(1));
    final answer = await pages.interact(
      TavernScriptUiRequest(requestId: 'r', contextId: pages.interactors.keys.single, executionId: 'e', kind: 'echo'),
      _Never(),
    );
    expect(answer.status, 'dismissed');
    await calls.close();
  });

  test('what the app does not do for scripts yet is refused, not faked', () async {
    final pages = TavernScriptPages();
    final cancel = _Never();
    // No chat on screen for it; a kind the app does not know.
    await expectLater(
      pages.interact(TavernScriptUiRequest(requestId: 'r', contextId: 'c', executionId: 'e', kind: 'input'), cancel),
      throwsA(isA<TavernScriptException>().having((e) => e.code, 'code', TavernScriptErrorCode.hostUnavailable)),
    );
    pages.add(
      'c',
      (_) async => false,
      interact: (kind, fields, {required withdraw}) async => const TavernInteractAnswer(TavernInteractStatus.submitted),
    );
    await expectLater(
      pages.interact(TavernScriptUiRequest(requestId: 'r', contextId: 'c', executionId: 'e', kind: 'speak'), cancel),
      throwsA(isA<TavernScriptException>().having((e) => e.code, 'code', TavernScriptErrorCode.unsupportedCapability)),
    );
    // Already cancelled: not shown, answered cancelled.
    final gone = _Cancel()..cancel();
    final answer = await pages.interact(
      TavernScriptUiRequest(requestId: 'r3', contextId: 'c', executionId: 'e', kind: 'input'),
      gone,
    );
    expect(answer.status, 'cancelled');
    await expectLater(
      pages.resolveSlash(const TavernSlashReference(contextId: 'c', label: 'x'), cancel),
      throwsA(isA<TavernScriptException>().having((e) => e.code, 'code', TavernScriptErrorCode.unsupportedCapability)),
    );
    // A delivery for a context no page holds is acknowledged, nothing run.
    final ack = await pages.dispatch(
      TavernScriptDispatch(kind: TavernScriptDispatchKind.lifecycle, eventId: 'ev', contextId: 'nobody', seq: 1),
      cancel,
    );
    expect((ack.eventId, ack.status), ('ev', TavernScriptAckStatus.completed));
    expect(ack.issues, isEmpty);
  });

  test("a preset's SPreset function is evaluated by its chat's page; a cancel is passed on, and its answer still settles it", () async {
    final pages = TavernScriptPages();
    TavernSPresetEvaluationRequest request(String id) => TavernSPresetEvaluationRequest(
      requestId: id,
      chatId: 'c1',
      generationId: 'g',
      sessionId: 'g:s',
      stage: 'OutputPreprocessing',
      source: '(x) => x',
      arguments: const [1],
    );
    // No page for that chat: said so.
    await expectLater(
      pages.evaluateSPreset(request('r0'), _Never()),
      throwsA(isA<TavernScriptException>().having((e) => e.code, 'code', TavernScriptErrorCode.hostUnavailable)),
    );
    final sent = <Map<String, Object?>>[];
    pages.add('ctx', (d) async {
      sent.add(d);
      return true;
    }, chatId: 'c1');
    final cancel = _Cancel();
    final answer = pages.evaluateSPreset(request('r1'), cancel);
    await pumpEventQueue();
    expect(sent.single['kind'], 'spreset');
    expect((sent.single['request']! as Map)['source'], '(x) => x');
    cancel.cancel();
    await pumpEventQueue();
    expect(sent.last, {'kind': 'spresetCancel', 'requestId': 'r1'});
    pages.spresetAnswered({
      'requestId': 'r1',
      'value': 2,
      'arguments': const [1],
      'type': 'spreset',
    });
    expect((await answer).value, 2);
    // What threw there fails here; a page that goes leaves it unknown, failed.
    final threw = pages.evaluateSPreset(request('r2'), _Never());
    await pumpEventQueue();
    pages.spresetAnswered({'requestId': 'r2', 'error': 'boom'});
    await expectLater(threw, throwsA(isA<TavernScriptException>().having((e) => e.message, 'message', 'boom')));
    final lost = pages.evaluateSPreset(request('r3'), _Never());
    await pumpEventQueue();
    pages.drop('ctx');
    await expectLater(lost, throwsA(isA<TavernScriptException>()));
    await pages.releaseSPresetSession('g:s');
    expect(sent.last, {'kind': 'spresetRelease', 'sessionId': 'g:s'});
  });

  test(
    "酒馆助手's URL image: fetched as a data URI; a failed download is the failure the engine skips; no named proxies",
    () async {
      final pages = TavernScriptPages(
        client: () => MockClient((request) async {
          if (request.url.path == '/cat.png') {
            return http.Response.bytes([1, 2, 3], 200, headers: {'content-type': 'image/png'});
          }
          if (request.url.path == '/page') return http.Response('<html>', 200, headers: {'content-type': 'text/html'});
          return http.Response('gone', 404);
        }),
      );
      expect(await pages.resolveHelperImage('https://x.test/cat.png', _Never()), 'data:image/png;base64,AQID');
      await expectLater(
        pages.resolveHelperImage('https://x.test/missing.png', _Never()),
        throwsA(
          isA<TavernHelperImageConversionFailure>().having(
            (e) => e.stage,
            'stage',
            TavernHelperImageConversionStage.download,
          ),
        ),
      );
      await expectLater(
        pages.resolveHelperImage('https://x.test/page', _Never()),
        throwsA(isA<TavernHelperImageConversionFailure>()),
      );
      expect(await pages.resolveHelperProxy('主代理', _Never()), isNull);
      // Offline chosen: nothing is fetched, and it is not a skipped image.
      final offline = TavernScriptPages(client: () => throw StateError('fetched'), offline: () => true);
      await expectLater(
        offline.resolveHelperImage('https://x.test/cat.png', _Never()),
        throwsA(
          isA<TavernScriptException>().having((e) => e.code, 'code', TavernScriptErrorCode.unsupportedCapability),
        ),
      );
    },
  );
}

class _Recording extends TavernScriptPages {
  final interactors = <String, TavernScriptInteractor>{};

  @override
  void add(String contextId, TavernScriptPage page, {TavernScriptInteractor? interact, String? chatId}) {
    if (interact != null) interactors[contextId] = interact;
    super.add(contextId, page, interact: interact, chatId: chatId);
  }
}

class _Cancel implements TavernScriptCancellation {
  final _done = Completer<void>();
  void cancel() => _done.complete();

  @override
  bool get isCancelled => _done.isCompleted;

  @override
  Future<void> get whenCancelled => _done.future;
}

class _Never implements TavernScriptCancellation {
  @override
  bool get isCancelled => false;

  @override
  Future<void> get whenCancelled => Future<void>.delayed(const Duration(days: 1));
}
