import 'dart:async';

import 'package:dsh_app/links/launcher_entries.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('dsh/shortcuts');

final _connection = HostConnection(
  client: DshClient(DshConnection(Uri.parse('http://127.0.0.1:9'))),
  label: '本机',
  isLocal: true,
);

SessionSummary _session(String id, String? title, int minutesAgo) => SessionSummary.fromJson({
  'sessionId': id,
  'updatedAt': DateTime(2026, 10, 24, 12).subtract(Duration(minutes: minutesAgo)).millisecondsSinceEpoch,
  'running': false,
  'blank': false,
  'agentAvailable': false,
  'projections': {
    'values': {'title': ?title},
  },
});

class _Sessions extends SessionsController {
  _Sessions(this.list);
  final List<SessionSummary> list;

  @override
  Future<List<SessionSummary>> build() async => list;
}

class _Host extends ActiveHostController {
  _Host(this.host);
  final HostRef host;

  @override
  HostRef build() => host;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LauncherEntry.parse', () {
    test('new, voice and a conversation on its host', () {
      expect(LauncherEntry.parse({'kind': 'new'}), isA<NewChatEntry>().having((e) => e.voice, 'voice', isFalse));
      expect(LauncherEntry.parse({'kind': 'voice'}), isA<NewChatEntry>().having((e) => e.voice, 'voice', isTrue));
      final chat = LauncherEntry.parse({'kind': 'chat', 'sessionId': 's1', 'host': const HostRef.ssh('box').encode()});
      expect(chat, isA<OpenChatEntry>());
      chat as OpenChatEntry;
      expect(chat.sessionId, 's1');
      expect(chat.host, const HostRef.ssh('box'));
      // No host recorded: the phone's own engine.
      expect((LauncherEntry.parse({'kind': 'chat', 'sessionId': 's2'}) as OpenChatEntry).host, HostRef.local);
    });

    test("a companion phone task's way back is her room or the app as it was, never a chat", () {
      final room = LauncherEntry.parse({'kind': 'chat', 'sessionId': 'companion:room:t1:r1', 'host': HostRef.local.encode()});
      expect(room, isA<OpenCompanionEntry>().having((e) => e.room, 'room', isTrue));
      final floating = LauncherEntry.parse({'kind': 'chat', 'sessionId': 'companion:floating:t1:r1'});
      expect(floating, isA<OpenCompanionEntry>().having((e) => e.room, 'room', isFalse));
    });

    test('a pet screenshot carries only its private cache path', () {
      final entry = LauncherEntry.parse({'kind': 'screenshot', 'path': '/cache/pet-screenshots/slot/screen.png'});
      expect(entry, isA<ScreenshotEntry>());
      expect((entry as ScreenshotEntry).path, '/cache/pet-screenshots/slot/screen.png');
    });

    test('the system assistant opens the room even when Android shares no page', () {
      final plain = LauncherEntry.parse({'kind': 'companion_assistant', 'page': null}) as CompanionAssistantEntry;
      expect(plain.page, isNull);
      expect(plain.returnToApp, isFalse);
      final entry = LauncherEntry.parse({
        'kind': 'companion_assistant',
        'page': 'Train arrives at 9:30',
        'returnToApp': true,
      }) as CompanionAssistantEntry;
      expect(entry.page, 'Train arrives at 9:30');
      expect(entry.returnToApp, isTrue);
    });

    test('a reminder notification retains its task and the revision that was opened', () {
      final entry = LauncherEntry.parse({'kind': 'companion_task', 'taskId': 'task-one', 'taskRev': 2});
      expect(entry, isA<OpenCompanionTaskEntry>());
      entry as OpenCompanionTaskEntry;
      expect(entry.taskId, 'task-one');
      expect(entry.taskRev, 2);
      for (final invalid in [
        {'taskId': '', 'taskRev': 1},
        {'taskId': 'bad\u0000id', 'taskRev': 1},
        {'taskId': 'task-one', 'taskRev': 0},
        {'taskId': 'task-one', 'taskRev': '2'},
        {'taskId': 'task-one'},
      ]) {
        expect(LauncherEntry.parse({'kind': 'companion_task', ...invalid}), isNull);
      }
    });

    test('malformed screenshot entries are dropped', () {
      for (final path in [null, 42, '', 'screen.png', 'content://screen', '/cache/bad\u0000.png']) {
        expect(LauncherEntry.parse({'kind': 'screenshot', 'path': path}), isNull);
      }
    });

    test('anything else is dropped', () {
      expect(LauncherEntry.parse(null), isNull);
      expect(LauncherEntry.parse({'kind': 'chat'}), isNull);
      expect(LauncherEntry.parse({'kind': 'chat', 'sessionId': ''}), isNull);
      expect(LauncherEntry.parse({'kind': 'delete-everything'}), isNull);
    });
  });

  group('setRecent', () {
    late List<Object?> sent;
    late bool accept;
    Completer<bool>? held;

    setUp(() {
      sent = [];
      accept = true;
      held = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
        call,
      ) async {
        if (call.method == 'setRecent') {
          sent.add(call.arguments);
          return held?.future ?? accept;
        }
        return true;
      });
    });
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null),
    );

    const a = RecentShortcut(sessionId: 'a', title: '周报', host: HostRef.local);
    const b = RecentShortcut(sessionId: 'b', title: '修复登录', host: HostRef.local);

    test('publishes once per change', () async {
      final bridge = LauncherBridge();
      addTearDown(bridge.dispose);
      expect(await bridge.setRecent([a, b]), isTrue);
      expect(await bridge.setRecent([a, b]), isTrue);
      expect(sent, hasLength(1));
      expect(sent.single, {
        'items': [
          {'id': 'a', 'title': '周报', 'host': HostRef.local.encode()},
          {'id': 'b', 'title': '修复登录', 'host': HostRef.local.encode()},
        ],
      });
      await bridge.setRecent([b, a]);
      await bridge.setRecent(const []);
      expect(sent, hasLength(3));
    });

    test('back to the published list while another is on its way: it still goes out', () async {
      final bridge = LauncherBridge();
      addTearDown(bridge.dispose);
      expect(await bridge.setRecent([a]), isTrue);
      final reply = held = Completer<bool>();
      final toB = bridge.setRecent([b]);
      await Future<void>.delayed(Duration.zero);
      held = null;
      final backToA = bridge.setRecent([a]);
      reply.complete(true);
      expect(await toB, isTrue);
      expect(await backToA, isTrue);
      expect(sent, hasLength(3));
      expect((sent.last! as Map)['items'], [
        {'id': 'a', 'title': '周报', 'host': HostRef.local.encode()},
      ]);
    });

    test('tries again after the launcher refused (rate limit)', () async {
      final bridge = LauncherBridge();
      addTearDown(bridge.dispose);
      accept = false;
      expect(await bridge.setRecent([a]), isFalse);
      accept = true;
      expect(await bridge.setRecent([a]), isTrue);
      expect(sent, hasLength(2));
    });
  });

  test('without a native side, setRecent is a quiet no', () async {
    final bridge = LauncherBridge();
    addTearDown(bridge.dispose);
    expect(await bridge.setRecent(const []), isFalse);
  });

  group('recentShortcutsProvider', () {
    ProviderContainer container({
      required bool connected,
      List<SessionSummary> sessions = const [],
      HostRef host = HostRef.local,
    }) {
      final c = ProviderContainer(
        overrides: [
          activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(connected ? _connection : null)),
          sessionsProvider.overrideWith(() => _Sessions(sessions)),
          activeHostProvider.overrideWith(() => _Host(host)),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('the three newest conversations, on the active host', () async {
      final c = container(
        connected: true,
        host: const HostRef.ssh('box'),
        sessions: [
          _session('n1', '最新的', 1),
          _session('n2', null, 5),
          _session('n3', '  第三 ', 9),
          _session('n4', '第四', 20),
        ],
      );
      expect(c.read(recentShortcutsProvider), isNull, reason: 'list still loading');
      await c.read(sessionsProvider.future);
      final recents = c.read(recentShortcutsProvider)!;
      expect(recents.map((r) => r.sessionId), ['n1', 'n2', 'n3']);
      expect(recents.map((r) => r.title), ['最新的', '未命名对话', '第三']);
      expect(recents.every((r) => r.host == const HostRef.ssh('box')), isTrue);
    });

    test('unknown while disconnected: the launcher keeps what it has', () async {
      final c = container(connected: false, sessions: [_session('n1', 'x', 1)]);
      expect(c.read(recentShortcutsProvider), isNull);
    });

    test('an empty list once connected clears them', () async {
      final c = container(connected: true);
      await c.read(sessionsProvider.future);
      expect(c.read(recentShortcutsProvider), isEmpty);
    });
  });
}
