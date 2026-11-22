import 'dart:async';
import 'dart:io';

import 'package:dsh_app/tavern/tavern_canvas_calls.dart';
import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_script_host.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("a page's calls run in its chat's own context, opened once, and closed with it", () async {
    final dir = await Directory.systemTemp.createTemp('canvas-calls');
    final tavern = await openTavern(dir.path);
    addTearDown(() async {
      await tavern.close();
      await dir.delete(recursive: true);
    });
    final card = await File('assets/tavern/sample_innkeeper.json').readAsBytes();
    final character = await tavern.importCard(card, fileName: 'sample_innkeeper.json');
    final chat = await tavern.createChat(character.id);
    final calls = TavernCanvasCalls(tavern.scripts, chatId: chat, characterId: () => character.id);

    // No context named: this chat's own is used.
    final saved = await calls.handle({
      'id': 1,
      'method': 'replaceVariables',
      'params': {
        'target': {'scope': 'chat'},
        'value': {'met': true},
      },
    });
    expect(saved['ok'], isTrue, reason: '${saved['error']}');
    final target = (saved['result']! as Map)['target']! as Map;
    expect(target['chatId'], chat);
    final read = await calls.handle({
      'id': 2,
      'method': 'getVariables',
      'params': {
        'target': {'scope': 'chat'},
      },
    });
    expect((read['result']! as Map)['value'], {'met': true});
    final messages = await calls.handle({'id': 3, 'method': 'getChatMessages', 'params': <String, Object?>{}});
    expect(((messages['result']! as Map)['messages']! as List).first, containsPair('role', 'assistant'));
    // Asking what is there needs no context.
    expect((await calls.handle({'id': 4, 'method': 'capabilities'}))['ok'], isTrue);

    // Closed with the page; a later call opens a new one and still works.
    await calls.close();
    final again = await calls.handle({
      'id': 5,
      'method': 'getVariables',
      'params': {
        'target': {'scope': 'chat'},
      },
    });
    expect((again['result']! as Map)['value'], {'met': true});
    await calls.close();
  });

  test('no context to be had (the preview): told so; asked again, it tries again', () async {
    final preview = PreviewTavern(tick: Duration.zero);
    final chat = await preview.createChat('sample-innkeeper');
    final calls = TavernCanvasCalls(preview.scripts, chatId: chat, characterId: () => 'sample-innkeeper');
    for (final id in [1, 2]) {
      final reply = await calls.handle({
        'id': id,
        'method': 'getVariables',
        'params': {
          'target': {'scope': 'chat'},
        },
      });
      expect(reply['id'], id);
      expect((reply['error']! as Map)['code'], 'unsupportedCapability');
    }
    await calls.close();
  });

  test("the character's picture: the app's to give, as a data: URL; none for a group", () async {
    final preview = PreviewTavern(tick: Duration.zero);
    final chat = await preview.createChat('sample-innkeeper');
    final asked = <String>[];
    String? character = 'sample-innkeeper';
    final calls = TavernCanvasCalls(
      preview.scripts,
      chatId: chat,
      characterId: () => character,
      avatar: (id) async {
        asked.add(id);
        return 'data:image/png;base64,AAAA';
      },
    );
    final reply = await calls.handle({'id': 7, 'method': 'characterAvatar', 'params': <String, Object?>{}});
    expect(reply, {'id': 7, 'ok': true, 'result': 'data:image/png;base64,AAAA'});
    expect(asked, ['sample-innkeeper']);

    character = null;
    expect(await calls.handle({'id': 8, 'method': 'characterAvatar'}), {'id': 8, 'ok': true, 'result': null});
    expect(asked, ['sample-innkeeper']);

    // No reader, or one that fails: no picture, not an error.
    final bare = TavernCanvasCalls(preview.scripts, chatId: chat, characterId: () => 'sample-innkeeper');
    expect((await bare.handle({'id': 9, 'method': 'characterAvatar'}))['result'], isNull);
    final failing = TavernCanvasCalls(
      preview.scripts,
      chatId: chat,
      characterId: () => 'sample-innkeeper',
      avatar: (_) async => throw const FileSystemException('gone'),
    );
    expect(await failing.handle({'id': 10, 'method': 'characterAvatar'}), {'id': 10, 'ok': true, 'result': null});
  });

  test('a picture file as a data: URL, its type known by its first bytes', () async {
    final dir = await Directory.systemTemp.createTemp('dsh-avatar');
    addTearDown(() => dir.delete(recursive: true));
    Future<String?> of(String name, List<int> bytes) async {
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes);
      return tavernImageDataUrl(file.path);
    }

    expect(await of('a.png', [0x89, 0x50, 0x4E, 0x47, 1]), 'data:image/png;base64,iVBORwE=');
    expect(await of('a.jpg', [0xFF, 0xD8, 0xFF, 0xE0]), startsWith('data:image/jpeg;base64,'));
    expect(await of('a.gif', 'GIF89a'.codeUnits), startsWith('data:image/gif;base64,'));
    expect(await of('a.webp', [...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits]), startsWith('data:image/webp;'));
    expect(await of('a.txt', 'not a picture'.codeUnits), isNull);
    expect(await tavernImageDataUrl('${dir.path}/missing.png'), isNull);
    expect(await tavernImageDataUrl(null), isNull);
  });

  test("the personas' pictures go to the page once each, and again only as they change", () async {
    final reads = <String?>[];
    final avatars = TavernCanvasPersonaAvatars(
      read: (path) async {
        reads.add(path);
        if (path == '/broken.png') throw const FileSystemException('gone');
        return path == null ? null : 'data:image/png;base64,$path';
      },
    );
    TavernPersona persona(String id, [String? avatar]) => TavernPersona(id: id, name: id, avatarPath: avatar);

    expect(await avatars.changes([persona('p1', '/a.png'), persona('p2')]), [('p1', 'data:image/png;base64,/a.png')]);
    expect(reads, ['/a.png']);
    expect(await avatars.changes([persona('p1', '/a.png'), persona('p2')]), isEmpty);
    expect(reads, ['/a.png']);

    // A new picture, one taken away, one that cannot be read (none, not an error).
    expect(await avatars.changes([persona('p1'), persona('p2', '/b.png'), persona('p3', '/broken.png')]), [
      ('p1', null),
      ('p2', 'data:image/png;base64,/b.png'),
      ('p3', null),
    ]);

    // A fresh page has none of them.
    avatars.reset();
    expect(await avatars.changes([persona('p2', '/b.png')]), [('p2', 'data:image/png;base64,/b.png')]);
  });

  test('a picture changed again while the last one was read: only the newer goes', () async {
    final slow = Completer<String?>();
    final avatars = TavernCanvasPersonaAvatars(read: (path) => path == '/old.png' ? slow.future : Future.value(path));
    final first = avatars.changes([TavernPersona(id: 'p1', name: 'a', avatarPath: '/old.png')]);
    expect(await avatars.changes([TavernPersona(id: 'p1', name: 'a', avatarPath: '/new.png')]), [('p1', '/new.png')]);
    slow.complete('/old.png');
    expect(await first, isEmpty);
  });

  test('a page closed while its context is still opening leaves nothing with the host', () async {
    final bridge = _SlowOpen();
    final pages = _Pages();
    final calls = TavernCanvasCalls(bridge, chatId: 'chat', characterId: () => 'c', pages: pages);
    final reply = calls.handle({
      'id': 1,
      'method': 'getVariables',
      'params': {
        'target': {'scope': 'chat'},
      },
    });
    final closing = calls.close();
    bridge.opening.complete(const TavernScriptContext(id: 'ctx', engineEpoch: 'e', instanceId: 'canvas'));
    await closing;
    await reply;
    expect(pages.added, isEmpty);
    expect(bridge.closed, ['ctx']);
  });

  test('a page that is up registers with the host with no call of its own, once; its SPreset reaches it', () async {
    final bridge = _SlowOpen();
    final pages = _Pages();
    final calls = TavernCanvasCalls(bridge, chatId: 'chat', characterId: () => 'c', pages: pages);
    final sent = <Map<String, Object?>>[];
    calls.deliver = (d) async {
      sent.add(d);
      return true;
    };
    calls.pageReady();
    calls.pageReady();
    bridge.opening.complete(const TavernScriptContext(id: 'ctx', engineEpoch: 'e', instanceId: 'canvas'));
    await pumpEventQueue();
    expect(pages.added, ['ctx']);
    final answer = pages.evaluateSPreset(
      TavernSPresetEvaluationRequest(
        requestId: 'r',
        chatId: 'chat',
        generationId: 'g',
        sessionId: 'g:s',
        stage: 'FinalRequestProcessing',
        source: '(x) => x',
      ),
      _Never(),
    );
    await pumpEventQueue();
    expect(sent.single['kind'], 'spreset');
    calls.spreset({'requestId': 'r', 'value': true});
    expect((await answer).value, true);
  });
}

class _Never implements TavernScriptCancellation {
  @override
  bool get isCancelled => false;

  @override
  Future<void> get whenCancelled => Completer<void>().future;
}

/// A bridge whose context opens only when told; closes are noted.
class _SlowOpen implements TavernScriptBridge {
  final opening = Completer<TavernScriptContext>();
  final closed = <String>[];

  @override
  Future<TavernScriptContext> openContext(TavernScriptContextSpec spec) => opening.future;

  @override
  Future<void> closeContext(String contextId) async => closed.add(contextId);

  @override
  void attachHost(TavernScriptHost? host) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Pages extends TavernScriptPages {
  final added = <String>[];

  @override
  void add(String contextId, TavernScriptPage page, {TavernScriptInteractor? interact, String? chatId}) {
    added.add(contextId);
    super.add(contextId, page, interact: interact, chatId: chatId);
  }
}
