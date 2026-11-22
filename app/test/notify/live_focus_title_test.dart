import 'package:dsh_app/pets/pet_mood.dart';
import 'package:dsh_app/pets/pet_overlay_bridge.dart';
import 'package:dsh_app/pets/pet_prefs.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/live_activity_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/state/ui_mode_state.dart';
import 'package:dsh_app/ui/chat/run_info.dart';
import 'package:dsh_app/ui/pets/pet_stage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show FakeChatController;

const _local = HostRef.local;
const _target = PetTarget(_local, 'a');
final _time = DateTime(2026, 11, 4);

class _Prefs extends NotifyPrefsController {
  @override
  NotifyPrefs build() => const NotifyPrefs();
}

class _Signals extends Notifier<PetSignals> {
  @override
  PetSignals build() => PetSignals(lastInteraction: _time);
  void set(PetSignals next) => state = next;
}

class _Pet extends Notifier<PetState> {
  @override
  PetState build() => const PetState(state: PetStateName.working, target: _target);
  void set(PetState next) => state = next;
}

final _signals = NotifierProvider<_Signals, PetSignals>(_Signals.new);
final _pet = NotifierProvider<_Pet, PetState>(_Pet.new);

PetFocus _focus(String? title, {HostRef host = _local, String id = 'a'}) {
  final s = ChatState(loading: false, running: true, title: title);
  return petFocusOf(host, id, s, runActivityOf(s));
}

PetSignals _snapshot({PetFocus? focus, List<PetRun> runs = const []}) =>
    PetSignals(focus: focus, runs: runs, lastInteraction: _time);

ProviderContainer _container() {
  final c = ProviderContainer(
    overrides: [
      notifyPrefsProvider.overrideWith(_Prefs.new),
      petSignalsProvider.overrideWith((ref) => ref.watch(_signals)),
      petStateProvider.overrideWith((ref) => ref.watch(_pet)),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

class _PetPrefs extends PetPrefsController {
  @override
  PetPrefs build() => const PetPrefs(packId: noPetId, loaded: true);
}

class _Mode extends UiModeController {
  @override
  UiModeState build() => const UiModeState(loaded: true);
}

class _Host extends ActiveHostController {
  @override
  HostRef build() => _local;
}

void main() {
  test('title-only chat state changes remain observable in focus equality', () {
    final before = _focus('Old');
    final after = _focus('New');
    expect(after, isNot(before));
    expect({_focus('New'), after}.length, 1);
    expect({before, after}.length, 2);
    expect(after.activity, before.activity);
  });

  test('current chat title outranks an untitled or stale running summary', () {
    final c = _container();
    for (final old in <String?>[null, 'Old summary']) {
      c
          .read(_signals.notifier)
          .set(
            _snapshot(
              focus: _focus('Fresh'),
              runs: [PetRun(_local, 'a', title: old)],
            ),
          );
      final live = c.read(liveActivityProvider)!;
      expect(live.title, 'Fresh');
      expect(live.kind, LiveKind.running);
      expect(live.target, _target);
    }
  });

  for (final (name, host, id) in [
    ('another host with the same id', const HostRef.ssh('lab'), 'a'),
    ('another conversation', _local, 'b'),
    ('a child while the activity targets its root', _local, 'child'),
  ]) {
    test('focus title does not cross $name', () {
      final c = _container();
      c
          .read(_signals.notifier)
          .set(
            _snapshot(
              focus: _focus('Unrelated title', host: host, id: id),
              runs: const [
                PetRun(_local, 'a', title: 'Root title'),
                PetRun(_local, 'child', root: 'a', subagent: true),
              ],
            ),
          );
      expect(c.read(liveActivityProvider)!.title, 'Root title');
    });
  }

  test('missing and blank focused titles preserve existing summary fallback', () {
    final c = _container();
    for (final title in <String?>[null, '', '  ']) {
      c
          .read(_signals.notifier)
          .set(
            _snapshot(
              focus: _focus(title),
              runs: const [PetRun(_local, 'a', title: 'Known')],
            ),
          );
      expect(c.read(liveActivityProvider)!.title, 'Known');
    }
  });

  test('completion without a remaining run remembers the focused title', () {
    final c = _container();
    c
        .read(_signals.notifier)
        .set(
          _snapshot(
            focus: _focus('Generated'),
            runs: const [PetRun(_local, 'a', title: 'Old')],
          ),
        );
    c.read(liveActivityProvider);
    c.read(_signals.notifier).set(_snapshot());
    c.read(_pet.notifier).set(const PetState(state: PetStateName.attention, target: _target, foreground: false));
    final live = c.read(liveActivityProvider)!;
    expect(live.kind, LiveKind.done);
    expect(live.title, 'Generated');
    expect(live.since, isNull);
  });

  test('focused titles use the existing notification masking policy', () {
    final c = _container();
    const title = 'Deploy sk-abcdefghijklmnopqrstuvwxyz0123';
    c.read(_signals.notifier).set(_snapshot(focus: _focus(title), runs: const [PetRun(_local, 'a')]));
    final live = c.read(liveActivityProvider)!;
    expect(live.title, alertTitle(title));
    expect(live.title, isNot(contains('qrstuvwxyz0123')));
  });

  test('focused title memory remains bounded by the existing 32 entries', () {
    final c = _container();
    c.read(_pet.notifier).set(const PetState(state: PetStateName.attention, target: _target, foreground: false));
    c.read(_signals.notifier).set(_snapshot(focus: _focus('First')));
    expect(c.read(liveActivityProvider)!.title, 'First');
    for (var i = 0; i < 40; i++) {
      c.read(_signals.notifier).set(_snapshot(focus: _focus('Title $i', id: 'other-$i')));
      c.read(liveActivityProvider);
    }
    c.read(_signals.notifier).set(_snapshot());
    expect(c.read(liveActivityProvider)!.title, untitledSession);
  });

  testWidgets('a title-only change reaches live activity with background frames disabled', (tester) async {
    final chats = <String, FakeChatController>{};
    final c = ProviderContainer(
      overrides: [
        notifyPrefsProvider.overrideWith(_Prefs.new),
        petPrefsProvider.overrideWith(_PetPrefs.new),
        uiModeProvider.overrideWith(_Mode.new),
        activeHostProvider.overrideWith(_Host.new),
        petOverlayBridgeProvider.overrideWith((ref) {}),
        petScopedStateProvider.overrideWith((ref, scope) => const PetState(state: PetStateName.idle)),
        petStateProvider.overrideWithValue(const PetState(state: PetStateName.working, target: _target)),
        petSignalsProvider.overrideWith(
          (ref) => _snapshot(
            focus: ref.watch(petFocusProvider),
            runs: const [PetRun(_local, 'a', title: 'Old')],
          ),
        ),
        petClockProvider.overrideWithValue(() => _time),
        chatProvider.overrideWith2(
          (id) => chats[id] = FakeChatController(id, const ChatState(loading: false, running: true, title: 'Old')),
        ),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: PetStage(sessionId: 'a', child: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();
    expect(c.read(liveActivityProvider)!.title, 'Old');
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    for (final lifecycle in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(lifecycle);
    }
    expect(tester.binding.framesEnabled, isFalse);
    chats['a']!.emit(const ChatState(loading: false, running: true, title: 'Background update'));
    await tester.pump(const Duration(milliseconds: 20));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(c.read(liveActivityProvider)!.title, 'Background update');
  });
}
