// The phone task ends with its turn (lib/state/phone_turn_end.dart): which
// turn end is the phone's, what goes to the native side, and how the turn's
// alert follows (lib/state/notify_state.dart).

import 'package:dsh_app/phone/phone_channel.dart';
import 'package:dsh_app/state/chat_reveal.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/state/phone_turn_end.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notify/support.dart' as notify;
import 'support.dart';

const _active = PhoneTaskStatus(id: 1, active: true);
const _stopped = PhoneTaskStatus(id: 1, stopped: true);
const _idle = PhoneTaskStatus(id: 1);

ChatAlert _end(
  String session, {
  HostRef host = HostRef.local,
  AlertKind kind = AlertKind.done,
  String? turnEndKind = 'completed',
}) => ChatAlert(
  host: host,
  sessionId: session,
  kind: kind,
  key: turnKey,
  title: 't',
  text: 'x',
  turnEndKind: turnEndKind,
);

/// Local sessions as the engine lists them; [running] ones are mid-turn.
class _Client extends DshClient {
  _Client(this.running) : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final Set<String> running;

  @override
  Future<List<SessionSummary>> listSessions() async => [
    for (final id in ['s1', 's2', 's3']) notify.session(id, running: running.contains(id)),
  ];
}

class _Local extends LocalConnectionController {
  _Local(this.client);
  final DshClient client;

  @override
  Future<HostConnection?> build() async => HostConnection(client: client, label: '本机', isLocal: true);
}

void main() {
  group('PhoneTurnLink', () {
    test('a task with one running conversation links only that conversation', () {
      final link = PhoneTurnLink();
      expect(link.onStatus(_active), isTrue);
      link.began(['s2']);
      expect(link.candidates, {'s2'});
      expect(link.onTurnEnd('s1'), isFalse);
      expect(link.armed, isTrue);
      expect(link.onTurnEnd('s2'), isTrue);
      expect(link.armed, isFalse);
      // Settled: the same turn end again (a reconnect) does nothing.
      expect(link.onTurnEnd('s2'), isFalse);
    });

    test('multiple running conversations leave ownership ambiguous', () {
      final link = PhoneTurnLink()..onStatus(_active);
      link.began(['s1', 's2']);
      expect(link.candidates, {'s1', 's2'});
      expect(link.onTurnEnd('s3'), isFalse);
      expect(link.onTurnEnd('s1'), isFalse);
    });

    test('conversations unknown: no turn end is claimed', () {
      final link = PhoneTurnLink()..onStatus(_active);
      expect(link.candidates, isNull);
      expect(link.onTurnEnd('s9'), isFalse);
    });

    test('status pushes while the same task runs change nothing', () {
      final link = PhoneTurnLink()..onStatus(_active);
      link.began(['s1']);
      expect(link.onStatus(const PhoneTaskStatus(id: 1, active: true, paused: true)), isFalse);
      expect(link.candidates, {'s1'});
    });

    test('a stop keeps it: the cancelled turn ending still closes the overlay', () {
      final link = PhoneTurnLink()..onStatus(_active);
      link.began(['s1']);
      link.onStatus(_stopped);
      expect(link.armed, isTrue);
      expect(link.onTurnEnd('s1'), isTrue);
    });

    test('over without a stop (idle, engine gone): a later turn end leaves things alone', () {
      final link = PhoneTurnLink()..onStatus(_active);
      link.began(['s1']);
      link.onStatus(_idle);
      expect(link.armed, isFalse);
      expect(link.onTurnEnd('s1'), isFalse);
    });

    test('a new task id starts over even without an inactive push in between', () {
      final link = PhoneTurnLink()..onStatus(_active);
      link.began(['s1']);
      expect(link.onStatus(const PhoneTaskStatus(id: 2, active: true)), isTrue);
      expect(link.candidates, isNull);
      // A repeated push does not rearm an already claimed native task.
      link.began(['s1']);
      link.onTurnEnd('s1');
      expect(link.onStatus(const PhoneTaskStatus(id: 2, active: true)), isFalse);
    });

    test('busy preserves the same owner and ignores refusals from older tasks', () {
      final link = PhoneTurnLink()..onStatus(_active);
      link.began(['s1']);
      expect(link.onTurnEnd('s1'), isTrue);
      link.refused('s1', 1);
      expect(link.armed, isTrue);
      expect(link.candidates, {'s1'});
      expect(link.onTurnEnd('s2'), isFalse);
      expect(link.onTurnEnd('s1'), isTrue);
      link.onStatus(const PhoneTaskStatus(id: 2, active: true));
      link.began(['s2']);
      link.onTurnEnd('s2');
      link.refused('s1', 1);
      expect(link.armed, isFalse);
    });
  });

  group('channel', () {
    test('task id and finishTask replies parse', () {
      expect(PhoneTaskStatus.fromMap({'id': 7, 'active': true}).id, 7);
      expect(PhoneTaskStatus.fromMap({'active': true}).id, isNull);
      final f = PhoneFinish.fromMap({'closed': true, 'busy': false, 'opened': false, 'launched': true});
      expect((f.closed, f.busy, f.opened, f.launched), (true, false, false, true));
      expect(PhoneFinish.fromMap(const {}).closed, isFalse);
    });

    test('without the native side finishTask closes nothing', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      removePhoneNative();
      final r = await PhoneChannel().finishTask(taskId: 1, sessionId: 's1', reopen: true);
      expect(r.closed, isFalse);
      expect(r.opened, isFalse);
    });
  });

  group('controller', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    late FakePhoneNative native;
    late ProviderContainer container;

    Future<void> settle() => notify.settle();

    Future<PhoneTurnEndController> make({Set<String> running = const {'s1'}, String? viewed}) async {
      SharedPreferences.setMockInitialValues({});
      native = FakePhoneNative(status: phoneStatus(taskActive: false))..install();
      container = ProviderContainer(overrides: [localConnectionProvider.overrideWith(() => _Local(_Client(running)))]);
      addTearDown(container.dispose);
      await container.read(localConnectionProvider.future);
      if (viewed != null) container.read(currentSessionProvider.notifier).select(viewed);
      container.read(appForegroundProvider.notifier).set(false);
      container.listen(phoneTurnEndProvider, (_, _) {});
      await settle();
      expect(native.listening, isTrue);
      native.push(phoneStatus(taskActive: true, taskId: 1));
      await settle();
      return container.read(phoneTurnEndProvider.notifier);
    }

    Map<String, Object?> finishArgs() => (native.callsOf('finishTask').single.arguments as Map).cast<String, Object?>();

    Map<String, Object?> exactStatus({bool ended = false, int selected = 2}) => {
      ...phoneStatus(), 'taskProtocol': 1, 'parallelLimit': 1, 'selectedTaskId': selected,
      'tasks': [
        {'id': 1, 'sessionId': 's1', 'runId': 'epoch:1', 'active': !ended, 'generation': ended ? 3 : 1,
          if (ended) ...{'endedRunId': 'epoch:1', 'endedGeneration': 3, 'completion': 'completed'}},
        {'id': 2, 'sessionId': 's2', 'runId': 'other:4', 'active': true, 'generation': 1},
      ],
    };

    test('exact receipt finishes only its session while another task remains selected and running', () async {
      final phone = await make(running: {'s1', 's2'}, viewed: 's2');
      native.push(exactStatus());
      await settle();
      expect(phone.onTurnEnd(_end('s1')), isNull); // host idle inference is not the native receipt
      expect(native.callsOf('finishTask'), isEmpty);
      native.push(exactStatus(ended: true));
      await settle();
      expect(finishArgs(), {
        'taskId': 1, 'sessionId': 's1', 'host': HostRef.local.encode(), 'reopen': true,
        'runId': 'epoch:1', 'generation': 3,
      });
      expect(container.read(chatRevealProvider)?.sessionId, 's1');
      native.push(exactStatus(ended: true));
      await settle();
      expect(native.callsOf('finishTask'), hasLength(1));
    });

    test('a selected modern task does not disable a separately linked legacy task', () async {
      final phone = await make(running: {'s1'});
      native.push({
        ...phoneStatus(taskId: 1, taskActive: true),
        'taskProtocol': 1, 'parallelLimit': 1, 'selectedTaskId': 2,
        'tasks': [
          {'id': 1, 'active': true, 'identity': 'legacy'},
          {'id': 2, 'sessionId': 's2', 'runId': 'other:4', 'active': true},
        ],
      });
      await settle();
      expect(phone.link.candidates, {'s1'});
      await phone.onTurnEnd(_end('s1'));
      expect(finishArgs()['taskId'], 1);
      expect(finishArgs().containsKey('runId'), isFalse);
    });

    test('a receipt seen without a prior active push is still consumed once', () async {
      await make(running: {'s1', 's2'});
      native.push(exactStatus(ended: true));
      await settle();
      expect(finishArgs()['runId'], 'epoch:1');
      native.push(exactStatus(ended: true));
      await settle();
      expect(native.callsOf('finishTask'), hasLength(1));
    });

    test('exact receipt preserves the return preference without relying on viewed chat', () async {
      await make(running: {'s1', 's2'}, viewed: 's2');
      await container.read(phoneReturnPrefProvider.notifier).set(false);
      native.push(exactStatus(ended: true));
      await settle();
      expect(finishArgs()['sessionId'], 's1');
      expect(finishArgs()['reopen'], isFalse);
      expect(container.read(chatRevealProvider), isNull);
    });

    test('a companion task goes back to her room, or leaves the person where it was asked from', () async {
      await make(running: {'s1'});
      Map<String, Object?> companionEnd(int id, String session) => {
        ...phoneStatus(), 'taskProtocol': 1, 'parallelLimit': 1, 'selectedTaskId': id,
        'tasks': [
          {'id': id, 'sessionId': session, 'runId': 'r$id', 'active': false, 'generation': 3,
            'endedRunId': 'r$id', 'endedGeneration': 3, 'completion': 'completed'},
        ],
      };
      native.push(companionEnd(1, 'companion:room:t1:r1'));
      await settle();
      expect(finishArgs()['sessionId'], 'companion:room:t1:r1');
      expect(finishArgs()['reopen'], isTrue);
      // She is no conversation: nothing in the chat moves.
      expect(container.read(chatRevealProvider), isNull);

      native.calls.clear();
      native.push(companionEnd(2, 'companion:floating:t2:r2'));
      await settle();
      expect(finishArgs()['reopen'], isFalse);
    });

    test('the phone turn ending closes the overlay and brings the app back to that conversation', () async {
      final phone = await make(running: {'s2'}, viewed: 's2');
      expect(phone.link.candidates, {'s2'});
      final result = await phone.onTurnEnd(_end('s2'));
      expect(result?.opened, isTrue);
      expect(finishArgs(), {'taskId': 1, 'sessionId': 's2', 'host': HostRef.local.encode(), 'reopen': true});
      // The chat shows its newest line.
      expect(container.read(chatRevealProvider)?.sessionId, 's2');
    });

    test('failed and stopped turns end it the same way', () async {
      final phone = await make();
      native.push(phoneStatus(taskStopped: true, taskId: 1));
      await settle();
      final result = await phone.onTurnEnd(_end('s1', kind: AlertKind.stopped, turnEndKind: 'aborted'));
      expect(result?.closed, isTrue);
      expect(finishArgs()['reopen'], isTrue);
    });

    test('other conversations, remote hosts and requests are left alone', () async {
      final phone = await make(running: {'s1'});
      expect(phone.onTurnEnd(_end('s2')), isNull);
      expect(phone.onTurnEnd(_end('s1', host: const HostRef.ssh('lab'))), isNull);
      final request = ChatAlert(
        host: HostRef.local,
        sessionId: 's1',
        kind: AlertKind.approval,
        key: 'e1',
        title: 't',
        text: 'x',
      );
      expect(phone.onTurnEnd(request), isNull);
      expect(native.callsOf('finishTask'), isEmpty);
    });

    test('switch off, or the app already in front: the overlay closes, nothing is brought forward', () async {
      final phone = await make();
      await container.read(phoneReturnPrefProvider.notifier).set(false);
      await phone.onTurnEnd(_end('s1'));
      expect(finishArgs()['reopen'], isFalse);

      native.calls.clear();
      await container.read(phoneReturnPrefProvider.notifier).set(true);
      native.push(phoneStatus(taskActive: true, taskId: 2));
      await settle();
      container.read(appForegroundProvider.notifier).set(true);
      native.finish = {'closed': true, 'opened': true, 'launched': false};
      await phone.onTurnEnd(_end('s1'));
      expect(finishArgs()['reopen'], isFalse);
      // Not asked back: the chat isn't moved.
      expect(container.read(chatRevealProvider), isNull);
    });

    test('a call still running never changes ownership to another conversation', () async {
      final phone = await make(running: {'s1'});
      native.finish = {'closed': false, 'busy': true};
      final r = await phone.onTurnEnd(_end('s1'));
      expect(r?.busy, isTrue);
      expect(phone.link.candidates, {'s1'});
      expect(phone.onTurnEnd(_end('s2')), isNull);
      native.finish = {'closed': true, 'opened': true, 'launched': true};
      expect(await phone.onTurnEnd(_end('s1')), isNotNull);
    });

    test('the switch is on by default and kept', () async {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(phoneReturnPrefProvider), isTrue);
      await c.read(phoneReturnPrefProvider.notifier).set(false);
      expect((await SharedPreferences.getInstance()).getBool(PhoneReturnPrefController.key), isFalse);

      final again = ProviderContainer();
      addTearDown(again.dispose);
      again.read(phoneReturnPrefProvider);
      await notify.settle();
      expect(again.read(phoneReturnPrefProvider), isFalse);
    });
  });

  group('the turn alert after it', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    late FakePhoneNative native;
    late notify.FakeNotifyChannel channel;
    late notify.FakeAlertSource local;
    late ProviderContainer container;

    Future<void> make({bool doneNotifications = true}) async {
      SharedPreferences.setMockInitialValues({'notify_done': doneNotifications});
      native = FakePhoneNative(status: phoneStatus(taskActive: true, taskId: 1))..install();
      channel = notify.FakeNotifyChannel();
      local = notify.FakeAlertSource()..sessions = [notify.session('s1', title: '点外卖', running: true)];
      final conn = HostConnection(client: _Client({'s1'}), label: '本机', isLocal: true);
      container = ProviderContainer(
        overrides: [
          notifyChannelProvider.overrideWithValue(channel),
          alertSourceFactoryProvider.overrideWithValue((_) => local),
          alertTimingProvider.overrideWithValue((announce: Duration.zero, reconcile: const Duration(milliseconds: 30))),
          localConnectionProvider.overrideWith(() => _Local(conn.client)),
          activeConnectionProvider.overrideWithValue(AsyncData(conn)),
        ],
      );
      addTearDown(container.dispose);
      container.listen(phoneTurnEndProvider, (_, _) {});
      container.listen(chatAlertsProvider, (_, _) {});
      await notify.settle();
      container.read(appForegroundProvider.notifier).set(false);
      await notify.settle();
    }

    Future<void> endTurn() async {
      local.outcomes['s1'] = notify.outcome(9, 'completed', reply: '已下单', title: '点外卖');
      local.emit(const SessionStatusEvent('s1', false));
      await notify.settle();
    }

    test('blocked from coming back: the notification goes out, even with turn notifications off', () async {
      await make(doneNotifications: false);
      native.finish = {'closed': true, 'opened': false, 'launched': true};
      await endTurn();
      expect(native.callsOf('finishTask'), hasLength(1));
      expect(channel.shown.single.sessionId, 's1');
    });

    test('back in the app on it: no notification', () async {
      await make();
      native.onFinish = () {
        // What the app coming up does: foreground, on that conversation.
        container.read(appForegroundProvider.notifier).set(true);
        container.read(currentSessionProvider.notifier).select('s1');
      };
      await endTurn();
      expect(native.callsOf('finishTask'), hasLength(1));
      expect(channel.shown, isEmpty);
      expect(container.read(chatAlertsProvider), isNull);
    });

    test('no phone task: alerts as before, nothing sent to the phone side', () async {
      await make();
      native.push(phoneStatus(taskActive: false, taskId: 1));
      await notify.settle();
      await endTurn();
      expect(native.callsOf('finishTask'), isEmpty);
      // Turn notifications on, app in the background: the usual notification.
      expect(channel.shown.single.sessionId, 's1');
    });
  });
}
