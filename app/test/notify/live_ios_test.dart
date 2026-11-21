import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/appearance_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/live_activity_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/ui/theme/accent.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _target = PetTarget(HostRef.local, 'root');

LiveActivity _activity(LiveKind kind, {PetTarget target = _target}) => LiveActivity(
  kind: kind,
  title: 'Private conversation',
  text: '正在思考',
  chip: '思考中',
  publicText: 'DSH 正在干活',
  mood: PetStateName.thinking,
  target: target,
);

class _Push extends Notifier<LivePush> {
  @override
  LivePush build() => LivePush(enabled: true, activity: _activity(LiveKind.running));
  void set(LivePush value) => state = value;
}

final _pushProvider = NotifierProvider<_Push, LivePush>(_Push.new);

class _Channel extends NotifyChannel {
  final sent = <Map<String, Object?>>[];
  var plain = 0;

  @override
  Future<void> live(LivePush push) async => plain++;

  @override
  Future<void> liveWith(LivePush push, Map<String, Object?> extras) async => sent.add({...push.toMap(), ...extras});
}

final _accent = AppAccent.preset(null);

ProviderContainer _container(_Channel channel, {PetState pet = const PetState()}) => ProviderContainer(
  overrides: [
    operatingSystemProvider.overrideWithValue('ios'),
    notifyChannelProvider.overrideWithValue(channel),
    livePushProvider.overrideWith((ref) => ref.watch(_pushProvider)),
    accentProvider.overrideWithValue(_accent),
    petStateProvider.overrideWithValue(pet),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('iOS sends the push with the theme, the card\'s words and nothing to draw without a pet', () async {
    final channel = _Channel();
    final container = _container(channel);
    addTearDown(container.dispose);
    container.listen<void>(liveActivityBridgeProvider, (_, _) {});
    await pumpEventQueue();

    expect(channel.plain, 0);
    expect(channel.sent, hasLength(1));
    final sent = channel.sent.single;
    expect((sent['activity'] as Map)['kind'], 'running');
    expect(sent['tint'], _accent.seed.toARGB32());
    expect(sent['tintDark'], _accent.seedDark.toARGB32());
    expect(sent['canStop'], isFalse);
    expect(sent['labels'], {'stop': appL10n.liveStop, 'stale': appL10n.liveStale});
    expect(sent.containsKey('art'), isFalse);
    // Sent as null, so native drops the last pet's picture instead of keeping it.
    expect(sent.containsKey('artKey'), isTrue);
    expect(sent['artKey'], isNull);
  });

  test('pushes go out once each and in order', () async {
    final channel = _Channel();
    final container = _container(channel);
    addTearDown(container.dispose);
    container.listen<void>(liveActivityBridgeProvider, (_, _) {});
    await pumpEventQueue();
    final push = container.read(_pushProvider.notifier);
    for (final next in [
      LivePush(enabled: true, activity: _activity(LiveKind.waiting)),
      LivePush(enabled: true, activity: _activity(LiveKind.waiting)),
      const LivePush(enabled: false),
    ]) {
      push.set(next);
      await pumpEventQueue();
    }

    expect([for (final s in channel.sent) (s['activity'] as Map?)?['kind']], ['running', 'waiting', null]);
    expect(channel.sent.last['enabled'], isFalse);
  });

  test('停止 only where the floating pet could stop, on the card about its conversation', () {
    bool canStop(PetState pet, {PetTarget target = _target}) {
      final container = _container(_Channel(), pet: pet);
      addTearDown(container.dispose);
      container
          .read(_pushProvider.notifier)
          .set(LivePush(enabled: true, activity: _activity(LiveKind.running, target: target)));
      return container.read(iosLiveProvider).canStop;
    }

    expect(canStop(const PetState(target: _target, canStop: true)), isTrue);
    expect(canStop(const PetState(target: _target)), isFalse);
    expect(
      canStop(const PetState(target: _target, canStop: true), target: const PetTarget(HostRef.local, 'other')),
      isFalse,
    );
    expect(canStop(const PetState(canStop: true)), isFalse);
  });
}
