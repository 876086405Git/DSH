// DS Bot state: availability per host, the team and the feed, notices as
// unread counts and notifications, the chat and group chat controllers, and
// the small pure helpers the pages lean on.

import 'dart:convert';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/ui/bots/bot_chat_kit.dart';
import 'package:dsh_app/ui/bots/bot_format.dart';
import 'package:dsh_app/ui/bots/bot_mention.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show fakeConnection;
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ProviderContainer> start(FakeDsBotTransport transport, {NotifyChannel? notify}) async {
    final container = dsBotContainer(transport, notify: notify);
    addTearDown(container.dispose);
    container.listen(dsBotProvider, (_, _) {});
    container.listen(dsBotInboxProvider, (_, _) {});
    await settle(12);
    return container;
  }

  group('availability', () {
    test('a host without the plugin (404) asks to install it', () async {
      final transport = FakeDsBotTransport();
      transport.handlers['hello'] = (_) => throw const DshHttpException(404, 'missing');
      final container = await start(transport);
      expect(container.read(dsBotProvider).availability, DsBotAvailability.missing);
      expect(transport.feedOpens, 0);
    });

    test('a DS Bot without hello, or with no version in common, needs an update', () async {
      final old = FakeDsBotTransport()..handlers.remove('hello');
      expect((await start(old)).read(dsBotProvider).availability, DsBotAvailability.outdated);

      final later = FakeDsBotTransport();
      later.handlers['hello'] = (_) => {...later.helloAnswer(), 'api': null, 'apiMin': 2, 'apiMax': 2};
      expect((await start(later)).read(dsBotProvider).availability, DsBotAvailability.outdated);
    });

    test('a relay that refuses dsBot/* reads as the relay, not as a missing plugin', () async {
      final transport = FakeDsBotTransport();
      transport.handlers['hello'] = (_) =>
          throw const DshRemoteException('METHOD_NOT_ALLOWED', 'not on the allow-list');
      expect((await start(transport)).read(dsBotProvider).availability, DsBotAvailability.relay);
    });

    test('the relay cannot reach plugin routes', () async {
      final container = ProviderContainer(
        overrides: [
          activeConnectionProvider.overrideWithValue(AsyncData(fakeConnection)),
          dsBotApiFactoryProvider.overrideWithValue((_) => null),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(dsBotProvider).availability, DsBotAvailability.relay);
    });

    test('no connection is offline', () {
      final container = ProviderContainer(
        overrides: [activeConnectionProvider.overrideWithValue(const AsyncData(null))],
      );
      addTearDown(container.dispose);
      expect(container.read(dsBotProvider).availability, DsBotAvailability.offline);
    });
  });

  group('team and feed', () {
    test('ready: the team is read, the feed opened, and a save reads it again', () async {
      final transport = FakeDsBotTransport();
      final container = await start(transport);
      final status = container.read(dsBotProvider);
      expect(status.availability, DsBotAvailability.ready);
      expect(status.team!.bots.map((b) => b.name), ['Chief', 'Writer', 'Coder']);
      expect(status.live.bots['m1']!.tool, 'bash');
      expect(status.feedConnected, isTrue);
      expect(transport.feedOpens, 1);
      expect(transport.endpoints.take(2), ['hello', 'state']);

      final before = transport.endpoints.where((e) => e == 'state').length;
      transport.emit('revision', {'revision': 8});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await settle();
      expect(transport.endpoints.where((e) => e == 'state').length, greaterThan(before));
      // The read asks only for what changed since the revision it has.
      expect(transport.calls.lastWhere((c) => c.$1 == 'state').$2['since'], 7);
    });

    test('every Session the team uses is DS Bot\'s, for the drawer and the generic alerts', () async {
      final container = await start(FakeDsBotTransport());
      final owned = container.read(dsBotOwnedSessionsProvider);
      expect(owned, containsAll(['m1', 'm1c', 'b2', 'b3', 'r1', 'g1', 'g2', 'g3']));
      final filter = container.read(dsBotSessionFilterProvider);
      expect(filter(HostRef.local, 'g2'), isTrue);
      expect(filter(HostRef.local, 'someone-else'), isFalse);
      expect(filter(const HostRef.ssh('lab'), 'g2'), isFalse);
    });
  });

  group('notices', () {
    Map<String, Object?> notice(int seq, {String kind = 'message', String? roomId, String text = '初稿写好了'}) => {
      'seq': seq,
      'kind': kind,
      'botId': 'b2',
      'name': 'Writer',
      'roomId': ?roomId,
      'title': roomId == null ? null : '发布会',
      'text': text,
      'time': DateTime.now().millisecondsSinceEpoch,
    };

    test('in the background a notice becomes a notification and an unread count', () async {
      final transport = FakeDsBotTransport();
      final notify = RecordingNotifyChannel();
      final container = await start(transport, notify: notify);
      container.read(appForegroundProvider.notifier).set(false);

      transport.emit('notice', notice(1, roomId: 'r1'));
      transport.emit('notice', notice(2, kind: 'question', text: '要发布吗？'));
      await settle();

      final inbox = container.read(dsBotInboxProvider);
      expect(inbox.unreadOf('r1'), 1);
      expect(inbox.unreadOf('b2'), 1);
      expect(inbox.latest['r1']!.text, '初稿写好了');
      expect(notify.shown.map((p) => (p.title, p.text, p.attention, p.kind, p.sessionId)), [
        ('发布会', 'Writer：初稿写好了', false, dsBotTapRoom, 'r1'),
        ('Writer', 'Writer 问你：要发布吗？', true, dsBotTapBot, 'b2'),
      ]);
      expect(notify.shown.first.group, dsBotNotifyGroup(HostRef.local, 'r1'));
    });

    test('in the app only the unread count moves; the conversation on screen stays read', () async {
      final transport = FakeDsBotTransport();
      final notify = RecordingNotifyChannel();
      final container = await start(transport, notify: notify);
      container.read(dsBotViewingProvider.notifier).set('b2');
      transport.emit('notice', notice(1));
      transport.emit('notice', notice(2, roomId: 'r1'));
      await settle();
      final inbox = container.read(dsBotInboxProvider);
      expect(inbox.unreadOf('b2'), 0);
      expect(inbox.unreadOf('r1'), 1);
      expect(notify.shown, isEmpty);

      container.read(dsBotViewingProvider.notifier).set('r1');
      await settle();
      expect(container.read(dsBotInboxProvider).unreadOf('r1'), 0);
      expect(notify.cancelledGroups, contains(dsBotNotifyGroup(HostRef.local, 'r1')));
    });

    test('the notification switches decide, by kind', () async {
      final transport = FakeDsBotTransport();
      final notify = RecordingNotifyChannel();
      final container = await start(transport, notify: notify);
      container.read(appForegroundProvider.notifier).set(false);
      await container.read(notifyPrefsProvider.notifier).setDone(false);
      transport.emit('notice', notice(1));
      transport.emit('notice', notice(2, kind: 'approval', text: 'bash'));
      await settle();
      expect(notify.shown.map((p) => p.text), ['Writer 等你批准：bash']);
    });

    test('after a reconnect, notices since the last one read are caught up', () async {
      SharedPreferences.setMockInitialValues({'dsbot_cursor_${HostRef.local.encode()}': '{"boot":"boot-1","seq":3}'});
      final transport = FakeDsBotTransport()..helloOnFeed = false;
      transport.handlers['notices'] = (payload) {
        expect(payload, {'boot': 'boot-1', 'since': 3});
        return {
          'boot': 'boot-1',
          'seq': 5,
          'reset': false,
          'notices': [notice(4), notice(5, roomId: 'r1')],
        };
      };
      final notify = RecordingNotifyChannel();
      final container = await start(transport, notify: notify);
      container.read(appForegroundProvider.notifier).set(false);
      transport.emit('hello', {'revision': 7, 'api': 1, 'boot': 'boot-1', 'seq': 5});
      await settle(12);
      expect(notify.shown.map((p) => p.sessionId), ['b2', 'r1']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dsbot_cursor_${HostRef.local.encode()}'), '{"boot":"boot-1","seq":5}');
    });
  });

  test('notice cursors stay separate when switching hosts', () async {
    const lab = HostRef.ssh('lab');
    final localKey = 'dsbot_cursor_${HostRef.local.encode()}';
    final labKey = 'dsbot_cursor_${lab.encode()}';
    SharedPreferences.setMockInitialValues({
      localKey: '{"boot":"boot-A","seq":3}',
      labKey: '{"boot":"boot-B","seq":10}',
    });
    final local = FakeDsBotTransport()..helloOnFeed = false;
    final remote = FakeDsBotTransport()..helloOnFeed = false;
    local.handlers['hello'] = (_) => {...local.helloAnswer(), 'boot': 'boot-A', 'seq': 3};
    remote.handlers['hello'] = (_) => {...remote.helloAnswer(), 'boot': 'boot-B', 'seq': 12};
    remote.handlers['notices'] = (_) => {'boot': 'boot-B', 'seq': 12, 'reset': false, 'notices': <Object?>[]};
    final container = ProviderContainer(
      overrides: [
        activeHostProvider.overrideWith(_CursorHost.new),
        activeConnectionProvider.overrideWith((ref) {
          final host = ref.watch(activeHostProvider);
          return AsyncData(
            HostConnection(
              client: fakeConnection.client,
              label: host.id,
              isLocal: host.isLocal,
              kind: host.kind,
              hostId: host.id,
            ),
          );
        }),
        dsBotApiFactoryProvider.overrideWithValue((connection) => DsBotApi(connection.isLocal ? local : remote)),
      ],
    );
    addTearDown(container.dispose);
    container.listen(dsBotProvider, (_, _) {});
    await settle(12);
    local.emit('hello', {'revision': 7, 'api': 1, 'boot': 'boot-A', 'seq': 3});
    await settle(12);
    container.read(activeHostProvider.notifier).select(lab);
    await settle(12);
    remote.emit('hello', {'revision': 7, 'api': 1, 'boot': 'boot-B', 'seq': 12});
    await settle(12);
    expect(remote.calls.where((call) => call.$1 == 'notices').single.$2, {'boot': 'boot-B', 'since': 10});
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString(localKey)!), {'boot': 'boot-A', 'seq': 3});
    expect(jsonDecode(prefs.getString(labKey)!), {'boot': 'boot-B', 'seq': 12});
  });

  test('Bot notifications mask credentials in text and room title', () {
    const key = 'sk-abcdefghijklmnopqrstuvwxyz0123456789';
    final notice = DsBotNotice.fromJson({
      'seq': 1,
      'kind': 'message',
      'botId': 'b2',
      'name': 'Writer',
      'roomId': 'r1',
      'title': '群 $key',
      'text': '结果 $key',
      'time': 1,
    });
    final post = dsBotPost(HostRef.local, notice);
    expect(post.title, isNot(contains(key)));
    expect(post.text, isNot(contains(key)));
    expect(post.title, contains('•'));
    expect(post.text, contains('•'));
  });

  group('chats', () {
    test('a Bot chat shows its page, a sent message until it comes back, and the reply as it is written', () async {
      final transport = FakeDsBotTransport()..chatItems = [];
      final container = await start(transport);
      final sub = container.listen(botChatProvider('b2'), (_, _) {});
      addTearDown(sub.close);
      await settle();
      final chat = container.read(botChatProvider('b2').notifier);
      expect(container.read(botChatProvider('b2')).sessionId, 'b2-c');

      expect(await chat.send('  写个开场白 '), isTrue);
      expect(transport.calls.last.$1, 'send');
      expect(transport.calls.last.$2, {'sessionId': 'b2', 'text': '写个开场白'});
      expect(container.read(botChatProvider('b2')).pending.single.text, '写个开场白');

      final time = DateTime.now().millisecondsSinceEpoch;
      transport.emit('message', {
        'botId': 'b2',
        'sessionId': 'b2-c',
        'item': {'kind': 'user', 'text': '写个开场白', 'time': time},
      });
      transport.emit('stream', {'botId': 'b2', 'sessionId': 'b2-c', 'attemptId': 'a1', 'phase': 'start'});
      transport.emit('stream', {'botId': 'b2', 'sessionId': 'b2-c', 'attemptId': 'a1', 'text': '各位'});
      transport.emit('stream', {'botId': 'b2', 'sessionId': 'b2-c', 'attemptId': 'a1', 'text': '好'});
      // Another Bot's reply does not leak in.
      transport.emit('stream', {'botId': 'm1', 'sessionId': 'm1c', 'attemptId': 'a9', 'phase': 'start'});
      await settle();
      var state = container.read(botChatProvider('b2'));
      expect(state.pending, isEmpty);
      expect(state.items.single.text, '写个开场白');
      expect(state.streaming, '各位好');

      transport.emit('message', {
        'botId': 'b2',
        'sessionId': 'b2-c',
        'item': {'kind': 'bot', 'text': '各位好', 'time': time + 1},
      });
      // The same entry twice (feed and page) shows once.
      transport.emit('message', {
        'botId': 'b2',
        'sessionId': 'b2-c',
        'item': {'kind': 'bot', 'text': '各位好', 'time': time + 1},
      });
      await settle();
      state = container.read(botChatProvider('b2'));
      expect(state.items.map((i) => i.text), ['写个开场白', '各位好']);
      expect(state.streaming, isNull);
    });

    test('a failed send goes back to the draft side and says why', () async {
      final transport = FakeDsBotTransport();
      transport.handlers['send'] = (_) => throw const DshRemoteException('bot/read-only', 'held');
      final container = await start(transport);
      final sub = container.listen(botChatProvider('b2'), (_, _) {});
      addTearDown(sub.close);
      await settle();
      expect(await container.read(botChatProvider('b2').notifier).send('hi'), isFalse);
      final state = container.read(botChatProvider('b2'));
      expect(state.pending, isEmpty);
      expect(state.error, '另一个 DSH 正在使用这个团队');
    });

    test('a group chat reads its newest page again on its room event; live replies keep their place', () async {
      final transport = FakeDsBotTransport()
        ..roomItems = [
          {'id': '1', 'kind': 'user', 'text': '报数', 'time': 1},
          {'id': 'c:0', 'kind': 'bot', 'botId': 'm1', 'name': 'Chief', 'text': '1', 'time': 2, 'live': true},
        ]
        ..roomRunning = true
        ..roomSpeaking = 'b2';
      final container = await start(transport);
      final sub = container.listen(roomChatProvider('r1'), (_, _) {});
      addTearDown(sub.close);
      await settle();
      var state = container.read(roomChatProvider('r1'));
      expect(state.items.map((i) => i.id), ['1', 'c:0']);
      expect((state.running, state.speaking), (true, 'b2'));

      transport
        ..roomItems = [
          {'id': '1', 'kind': 'user', 'text': '报数', 'time': 1},
          {'id': 'c:0', 'kind': 'bot', 'botId': 'm1', 'name': 'Chief', 'text': '1', 'time': 2},
          {'id': 'c:1', 'kind': 'bot', 'botId': 'b2', 'name': 'Writer', 'text': '2', 'time': 3},
        ]
        ..roomRunning = false
        ..roomSpeaking = null;
      transport.emit('room', {'roomId': 'other'});
      await settle();
      expect(container.read(roomChatProvider('r1')).items.length, 2);
      transport.emit('room', {'roomId': 'r1'});
      await settle();
      state = container.read(roomChatProvider('r1'));
      expect(state.items.map((i) => (i.id, i.live)), [('1', false), ('c:0', false), ('c:1', false)]);
      expect(state.running, isFalse);
    });
  });

  group('helpers', () {
    DsBotItem item(String id, [String text = '']) => DsBotItem(kind: DsBotItemKind.bot, id: id, text: text, botId: 'b');

    test('mergeNewestPage keeps earlier pages and replaces from the page\'s first item', () {
      final shown = [item('a'), item('b'), item('c', 'live')];
      final merged = mergeNewestPage(shown, [item('b'), item('c', 'final'), item('d')]);
      expect(merged.joined, isTrue);
      expect(merged.items.map((i) => '${i.id}${i.text}'), ['a', 'b', 'cfinal', 'd']);
      expect(mergeNewestPage(shown, [item('x')]).items.map((i) => i.id), ['x']);
    });

    test('settlePending drops each echoed message once', () {
      final at = DateTime(2026);
      final pending = [DsBotPending('hi', at), DsBotPending('hi', at), DsBotPending('other', at)];
      final left = settlePending(pending, [const DsBotItem(kind: DsBotItemKind.user, text: 'hi ')]);
      expect(left.map((p) => p.text), ['hi', 'other']);
    });

    test('transcriptRows marks one speaker\'s runs and puts a time between distant messages', () {
      final t0 = DateTime(2026, 10, 24, 9);
      final rows = transcriptRows([
        DsBotItem(kind: DsBotItemKind.bot, botId: 'a', text: '1', time: t0),
        DsBotItem(kind: DsBotItemKind.bot, botId: 'a', text: '2', time: t0.add(const Duration(minutes: 1))),
        DsBotItem(kind: DsBotItemKind.bot, botId: 'b', text: '3', time: t0.add(const Duration(minutes: 2))),
        DsBotItem(kind: DsBotItemKind.bot, botId: 'b', text: '4', time: t0.add(const Duration(hours: 1))),
      ], streaming: '…');
      expect(rows.map((r) => r.runtimeType.toString()), [
        'BotTimeRow',
        'BotItemRow',
        'BotItemRow',
        'BotItemRow',
        'BotTimeRow',
        'BotItemRow',
        'BotStreamingRow',
      ]);
      final items = rows.whereType<BotItemRow>().map((r) => r.continued).toList();
      expect(items, [false, true, false, false]);
    });

    test('activeBotMention finds the @ word at the caret, not an address', () {
      TextEditingValue at(String text, [int? caret]) => TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: caret ?? text.length),
      );
      expect(activeBotMention(at('@')), (start: 0, query: ''));
      expect(activeBotMention(at('你好 @Wri')), (start: 3, query: 'Wri'));
      expect(activeBotMention(at('mail a@b')), isNull);
      expect(activeBotMention(at('@Writer 你好')), isNull);
      expect(activeBotMention(at('@Writer 你好', 4)), (start: 0, query: 'Wri'));
      final limit = List.filled(20, '😀').join();
      expect(activeBotMention(at(' @$limit')), (start: 1, query: limit));
      expect(activeBotMention(at(' @${limit}x')), isNull);
    });

    test('the mention picker writes @Name and lists the admin first', () {
      final input = TextEditingController(text: '请 @w');
      final mentions = BotMentionController(
        input: input,
        members: const [
          DsBot(id: 'b2', name: 'Writer'),
          DsBot(id: 'm1', name: 'Chief'),
        ],
        admin: 'm1',
      );
      addTearDown(mentions.dispose);
      input.selection = const TextSelection.collapsed(offset: 4);
      expect(mentions.isOpen, isTrue);
      expect(mentions.options.map((o) => o.label), ['Writer']);
      input
        ..text = '请 @'
        ..selection = const TextSelection.collapsed(offset: 3);
      expect(mentions.options.map((o) => o.label), ['Chief', 'Writer', mentionEveryone]);
      mentions.pick(mentions.options[1]);
      expect(input.text, '请 @Writer ');
      expect(input.selection.baseOffset, input.text.length);
      expect(mentions.isOpen, isFalse);
    });

    test('words for work, times, previews and posts', () {
      expect(workPhrase(const DsBotWork(tool: 'bash')), '正在运行命令');
      expect(workPhrase(null, activity: 'thinking'), '正在思考');
      expect(workPhrase(null), isNull);
      expect(workPhrase(const DsBotWork(switching: true)), '正在整理笔记');
      final now = DateTime(2026, 10, 24, 15);
      expect(shortTime(now.subtract(const Duration(seconds: 20)), now: now), '刚刚');
      expect(shortTime(DateTime(2026, 10, 24, 9, 5), now: now), '09:05');
      expect(shortTime(DateTime(2026, 10, 23, 9, 5), now: now), '昨天');
      expect(shortTime(DateTime(2026, 3, 2), now: now), '3月2日');
      expect(compactCount(980), '980');
      expect(compactCount(12345), '1.2 万');
      final team = DsBotTeam(
        revision: 1,
        bots: const [DsBot(id: 'b2', name: 'Writer')],
        rooms: const [
          DsBotRoom(id: 'r1', name: 'R', members: ['b2'], preview: 'Writer：好'),
          DsBotRoom(id: 'r2', name: 'R2', members: ['b2'], preview: '大家好'),
        ],
      );
      expect(roomPreview(team.rooms[0], team), 'Writer：好');
      expect(roomPreview(team.rooms[1], team), '你：大家好');
      final post = dsBotPost(
        HostRef.local,
        const DsBotNotice(seq: 1, kind: 'done', botId: 'b2', name: 'Writer', roomId: 'r1', title: '发布会'),
      );
      expect((post.title, post.text, post.publicText), ('发布会', 'Writer 完成了工作', 'Bot 有新消息'));
    });
  });
}

class _CursorHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
  @override
  void select(HostRef host) => state = host;
}
