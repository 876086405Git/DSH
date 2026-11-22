import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../pets/overlay_channel.dart';
import '../speech/speech_settings.dart' show companionEffectiveVoiceProvider;

import '../state/companion_agent_state.dart';
import 'companion_agent.dart';
import 'companion_agent_task_ui.dart';
import 'companion_float.dart';
import 'companion_host_tasks.dart';
import 'companion_initiative.dart';
import 'companion_initiative_owner.dart';
import 'companion_maps.dart';
import 'companion_moves.dart';
import 'companion_residency.dart';
import 'companion_screen_observer.dart';
import 'companion_state.dart' show companionNameProvider;
import 'companion_voice.dart';

/// DshApp watches this provider. Merely reading an ordinary Provider does not
/// retain the Ref.listen dependencies needed by a resident visit.
final companionAlwaysOnOwnerProvider = Provider<CompanionAlwaysOnOwner>((ref) {
  final agent = ref.watch(companionAgentProvider);
  final channel = ref.read(companionResidencyProvider.notifier);
  final owner = CompanionAlwaysOnOwner(ref, agent, channel);
  ref.listen(companionResidencyProvider, (_, value) => owner.synchronize(value));
  ref.listen(companionEffectiveVoiceProvider, (_, value) {
    if (value?.on != true) owner._hush();
  });
  ref.listen(petOverlayProvider, (_, value) {
    if (!value.showing) owner._hush();
  });
  ref.listen(companionNameProvider, (_, value) => owner._rename(value));
  ref.onDispose(owner.close);
  scheduleMicrotask(() {
    if (ref.mounted) owner.synchronize(ref.read(companionResidencyProvider));
  });
  return owner;
});

class CompanionAlwaysOnOwner {
  CompanionAlwaysOnOwner(this.ref, this.agent, this.channel) : overlay = ref.read(petOverlayChannelProvider) {
    _givenName = ref.read(companionNameProvider);
    _input = channel.listenInputs(_receive);
    agent.addListener(_changed);
    overlay.setCompanionActionHandler(_overlayAction);
    _speaker = ref.read(companionSpeakerProvider);
    _voiceEvents = _speaker.events.listen(_voiceEvent);
    _screen = CompanionScreenObserver(agent: agent);
  }
  final Ref ref;
  final CompanionAgent agent;
  final CompanionResidency channel;
  final PetOverlayChannel overlay;
  late final StreamSubscription<CompanionResidentInput> _input;
  late final StreamSubscription<CompanionVoiceEvent> _voiceEvents;
  late final CompanionSpeaker _speaker;
  late final CompanionScreenObserver _screen;
  CompanionScreenObserver get screen => _screen;
  StreamSubscription<int>? _packChanges;
  void Function()? _removeBeforePack;
  CompanionAgentResident? _resident;
  CompanionAlwaysOnStatus _status = const CompanionAlwaysOnStatus();
  Future<void> _opening = Future.value();
  Future<void> _notificationQueue = Future.value();
  final _received = <String>{};
  int _generation = 0;
  int _outputGeneration = 0;
  bool _closed = false;

  /// The name the person gave her, as the room shows it; else the pack's own.
  String? _givenName;
  String? _packName;
  String get _name => _givenName ?? _packName ?? 'Companion';
  String? _reply;
  String? _sentText;
  bool? _sentRunning;
  bool _fromFloat = false;
  final _spokenReplies = <String>{};
  final _voices = <String, ({String bubble, int chars})>{};
  int _voiceGeneration = 0;
  int _voiceSerial = 0;
  int _textAfterControl = 0;

  bool get active => !_closed && _status.enabled && _status.running && _resident?.active == true;

  void synchronize(CompanionAlwaysOnStatus next) {
    final changed = next.epoch != _status.epoch || next.enabled != _status.enabled || next.running != _status.running;
    _status = next;
    if (_closed) return;
    _resident?.setReducedPower(next.reducedPower);
    _screen.setReducedPower(next.reducedPower);
    if (!changed) return;
    final generation = ++_generation;
    _release();
    unawaited(overlay.companionMode(enabled: next.enabled && next.running, name: _name));
    if (!next.enabled || !next.running) return;
    _opening = _start(generation).catchError((Object error) async {
      if (!_closed && generation == _generation) {
        await channel.reportFailure('companion_unavailable');
      }
    });
  }

  void _rename(String? given) {
    if (given == _givenName) return;
    _givenName = given;
    if (!_closed && _status.enabled && _status.running) unawaited(overlay.companionMode(enabled: true, name: _name));
  }

  Future<void> _start(int generation) async {
    final store = await ref.read(companionFloatStoreProvider)();
    if (_closed || generation != _generation) return;
    _removeBeforePack = store.beforeChanges(() async {
      if (generation == _generation) {
        ++_generation;
        _retireLease();
      }
    });
    _packChanges = store.revisions.listen((_) {
      if (_closed || !_status.enabled || !_status.running) return;
      final next = ++_generation;
      _release();
      _opening = _start(next).catchError((Object _) => channel.reportFailure('companion_unavailable'));
    });
    final identity = await store.characterIdentity();
    if (_closed || generation != _generation) return;
    _packName = identity.character.name;
    unawaited(overlay.companionMode(enabled: true, name: _name));
    final ui = _ResidentUi(this);
    final lease = _resident = agent.retainAlwaysOn(
      root: Future.value(store.root),
      character: identity.character,
      moves: const CompanionMoves(),
      sourceKey: identity.key,
      ui: ui,
      mapHandoff: CompanionMapHandoff(ref.read(companionMapsProvider)),
    );
    lease.setReducedPower(_status.reducedPower);
    await lease.openMemory();
    if (_closed || generation != _generation || !lease.active) return;
    _screen.start();
    _changed();
  }

  Future<bool> submit(String text, {bool fromFloat = false}) async {
    final generation = _generation;
    await _opening;
    if (!active || generation != _generation || text.trim().isEmpty) return false;
    _fromFloat = fromFloat;
    _hush();
    final accepted = Completer<bool>();
    unawaited(
      _resident!
          .submit(
            text,
            onCommitted: (source) {
              if (!accepted.isCompleted) accepted.complete(true);
              _post(id: 'input:${source['id']}', text: text, user: true);
            },
          )
          .then((_) {
            if (!accepted.isCompleted) accepted.complete(false);
          })
          .catchError((Object _) {
            if (!accepted.isCompleted) accepted.complete(false);
          }),
    );
    return accepted.future;
  }

  Future<Object?> _overlayAction(MethodCall call) async {
    if (call.method == 'companionAskTarget') {
      return {
        'fresh': {'line': _name},
        'recent': [
          for (final row in _resident?.recentMessages ?? const <MemoryRow>[])
            {'id': row['id'], 'role': row['role'], 'text': row['text']},
        ],
        if (!active) 'problem': 'Open the companion room to finish setup.',
      };
    }
    if (call.method == 'companionAsk') {
      final args = call.arguments;
      final text = args is Map ? args['text'] : null;
      if (text is! String || !active) return {'sent': false, 'problem': 'Companion is not ready.'};
      // The real source commit, not the eventual model answer, accepts this
      // composer. A failed model retains its original retry/receipt path.
      final generation = _generation;
      final accepted = await submit(text, fromFloat: true);
      return {
        'sent': accepted,
        if (!accepted || generation != _generation) 'problem': 'Open the companion room to inspect this turn.',
      };
    }
    return null;
  }

  void _receive(CompanionResidentInput input) {
    if (_closed || !_status.enabled || input.epoch != _status.epoch || !_received.add(input.id)) return;
    while (_received.length > 64) {
      _received.remove(_received.first);
    }
    // No replay after an unknown delivery. The user may explicitly retry in
    // the original conversation, whose own turn/receipt rules stay in force.
    unawaited(
      submit(input.text)
          .then((accepted) {
            if (!accepted && !_closed) _failure();
          })
          .catchError((Object _) {
            if (!_closed) _failure();
          }),
    );
  }

  void _changed() {
    if (!active) return;
    final reply = agent.replyId;
    if (reply != _reply) {
      _reply = reply;
      _sentText = null;
      _sentRunning = null;
      _textAfterControl = 0;
    }
    final text = agent.text;
    final visible = _textAfterControl <= text.length ? text.substring(_textAfterControl).trim() : '';
    if (reply == null || visible.isEmpty || (visible == _sentText && _sentRunning == agent.running)) return;
    _sentText = visible;
    _sentRunning = agent.running;
    final speak = !agent.running && _fromFloat && _resident?.ownsCurrentRun == true && _spokenReplies.add(reply);
    while (_spokenReplies.length > 64) {
      _spokenReplies.remove(_spokenReplies.first);
    }
    unawaited(_presentLine(id: reply, text: visible, emotion: 'neutral', speak: speak));
    _post(id: reply, text: visible);
  }

  void _post({required String id, required String text, bool user = false}) {
    final generation = _outputGeneration;
    final epoch = _status.epoch;
    _notificationQueue = _notificationQueue.catchError((Object _) {}).then((_) async {
      if (!active || generation != _outputGeneration || epoch != _status.epoch) return;
      await channel.update(epoch: epoch, name: _name, text: text, id: id, user: user);
    });
  }

  void _controlChanged() {
    _hush();
    unawaited(overlay.clearCompanion());
    ++_outputGeneration;
    _textAfterControl = agent.text.length;
    _sentText = null;
    final epoch = _status.epoch;
    _notificationQueue = _notificationQueue.catchError((Object _) {}).then((_) => channel.clear(epoch));
  }

  void _failure() => _post(
    id: 'failure:${_status.epoch}:${DateTime.now().microsecondsSinceEpoch}',
    text: 'This turn did not finish. Open the companion room to inspect its progress.',
  );

  void _retireLease() {
    final resident = _resident;
    _screen.stop();
    _hush();
    ++_outputGeneration;
    unawaited(overlay.clearCompanion());
    // Cold synchronization has no old Dart conversation to clear. In
    // particular, a reminder may already be visible from its native process.
    if (resident != null) {
      final epoch = _status.epoch;
      _notificationQueue = _notificationQueue.catchError((Object _) {}).then((_) => channel.clear(epoch));
      resident.close();
    }
    _resident = null;
    _reply = null;
    _sentText = null;
    _sentRunning = null;
  }

  void _release() {
    _retireLease();
    _packChanges?.cancel();
    _packChanges = null;
    _removeBeforePack?.call();
    _removeBeforePack = null;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    ++_generation;
    _release();
    agent.removeListener(_changed);
    overlay.setCompanionActionHandler(null);
    unawaited(_input.cancel());
    unawaited(_voiceEvents.cancel());
    _screen.dispose();
  }

  Future<bool> _presentLine({
    required String id,
    required String text,
    required String emotion,
    required bool speak,
  }) async {
    final generation = _voiceGeneration;
    final shown = await overlay.presentCompanion(id: id, text: text, emotion: emotion, speaking: false);
    if (!shown || !speak || !active || generation != _voiceGeneration) return shown;
    final settings = ref.read(companionEffectiveVoiceProvider);
    if (settings?.on != true) return shown;
    final ready = await _speaker.ready(settings!);
    if (!ready || !active || generation != _voiceGeneration || !ref.read(petOverlayProvider).showing) return shown;
    final voiceId = 'float:${_status.epoch}:${++_voiceSerial}';
    _voices[voiceId] = (bubble: id, chars: text.length);
    _speaker.speak(voiceId, text);
    return shown;
  }

  void _voiceEvent(CompanionVoiceEvent event) {
    final line = _voices[event.id];
    if (line == null) return;
    switch (event.type) {
      case CompanionVoiceEventType.start:
        unawaited(overlay.companionSpeech(id: line.bubble, chars: line.chars, speaking: true));
      case CompanionVoiceEventType.range:
        unawaited(
          overlay.companionSpeech(id: line.bubble, chars: (event.end ?? 0) - (event.start ?? 0), speaking: true),
        );
      case CompanionVoiceEventType.done || CompanionVoiceEventType.stopped || CompanionVoiceEventType.error:
        _voices.remove(event.id);
        unawaited(overlay.companionSpeech(id: line.bubble, chars: 0, speaking: false));
      case CompanionVoiceEventType.fallback:
        break;
    }
  }

  void _hush() {
    ++_voiceGeneration;
    if (_voices.isEmpty) return;
    final old = _voices.values.toList();
    _voices.clear();
    _speaker.stop();
    for (final line in old) {
      unawaited(overlay.companionSpeech(id: line.bubble, chars: 0, speaking: false));
    }
  }
}

/// Background is not a visible/resumed room. It cannot manufacture a picker,
/// a real frame acknowledgement, or a fresh foreground task capability.
class _ResidentUi
    implements CompanionAgentRoomUi, CompanionInitiativeRoom, CompanionAgentAmbientUi, CompanionAgentNotificationUi {
  _ResidentUi(this.owner);
  final CompanionAlwaysOnOwner owner;
  @override
  bool get presentationAvailable => owner.active && owner.ref.read(petOverlayProvider).showing;
  @override
  Future<bool> presentLine({required String id, required String text, required String emotion, required bool speak}) =>
      owner._presentLine(id: id, text: text, emotion: emotion, speak: speak);
  @override
  void stopSpeech() => owner._hush();
  @override
  Future<bool> deliverFollowup({required String id, required String text}) =>
      owner.channel.deliver(epoch: owner._status.epoch, name: owner._name, text: text, id: id);
  @override
  bool get mounted => !owner._closed && owner._status.enabled && owner._status.running;
  @override
  bool get stageReady => false;
  @override
  String get forgottenNotice => 'I have removed that memory.';
  @override
  CompanionInitiativeRoom get initiativeRoom => this;
  @override
  CompanionInitiativeView get initiativeView => CompanionInitiativeView(
    visible: false,
    resumed: false,
    blocked: owner.agent.running,
    accessible: false,
    enabled: owner.active && owner.ref.read(companionInitiativeEnabledProvider) == true,
    notificationAvailable: owner.active && owner._status.notificationAvailable,
    contextKey: 'resident:${owner._status.epoch}',
  );
  @override
  bool get hasInvitation => false;
  @override
  CompanionAgentTaskUi tasks({required bool Function() isCurrent}) => _ResidentTaskUi(isCurrent);
  @override
  void committed(String raw) {}
  @override
  void failed(Object error, {String? retry}) => owner._failure();
  @override
  void controlChanged({required bool own}) => owner._controlChanged();
  @override
  void connectionChanged() {}
  @override
  void detached() {}
  @override
  void widgetClearPending() {}
  @override
  void vitalsChanged(CompanionSnapshot snapshot) {}
  @override
  Future<void> greet(DateTime? lastVisit, bool Function() isCurrent) async {}
  @override
  bool presentFollowup(CompanionInitiativeDisplay display, String line) => false;
  @override
  void hideFollowup(String ticketId) {}
  @override
  bool canPresent(CompanionInitiativeTicket ticket) =>
      ticket.kind == CompanionPromptKind.signal &&
      owner.active &&
      owner._status.notificationAvailable &&
      !owner.agent.running;
  @override
  void show(CompanionInitiativeDisplay display) {}
  @override
  void hide(String ticketId) {}
  @override
  void retime(String ticketId, int? expiresAtMono) {}
  @override
  void rest(CompanionInitiativeEffect intent) {}
}

class _ResidentTaskUi implements CompanionAgentTaskUi {
  _ResidentTaskUi(this.current);
  final bool Function() current;
  @override
  bool get isCurrent => current();
  @override
  bool get mapIsCurrent => false;
  @override
  CompanionAgentSelectionRoute? get onSelectionRoute => null;
  Never _openRoom() => throw const DshClosedException('Open the companion room to make this selection.');
  @override
  Future<String?> chooseDeadline(
    List<String> choices, {
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) async => _openRoom();
  @override
  Future<String?> chooseDirectory({
    required String kind,
    String? directoryHint,
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) async => _openRoom();
  @override
  Future<MemoryRow?> chooseSavedDirectory(
    List<MemoryRow> directories, {
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) async => _openRoom();
  @override
  Future<MemoryRow?> chooseDrafts({
    required CompanionMemoryStore store,
    required String hostKey,
    required DshClient? client,
    required CompanionTasksCapability? capability,
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
    String? originalStoreId,
  }) async => _openRoom();
  @override
  Future<({List<MemoryRow> inputs, MemoryRow outputDirectory})?> chooseReceipts({
    required CompanionMemoryStore store,
    required String hostKey,
    required DshClient? client,
    required CompanionTasksCapability? capability,
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
    String? originalStoreId,
    List<MemoryRow>? keptInputs,
    MemoryRow? keptOutput,
  }) async => _openRoom();
  @override
  Future<CompanionMapSpec?> chooseMap(
    CompanionMaps maps,
    String address, {
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) async => _openRoom();
  @override
  void accepted(MemoryRow task) {}
  @override
  void startForeground(List<CompanionNotesForegroundCapture> captures, {required bool Function() isCurrent}) {}
}
