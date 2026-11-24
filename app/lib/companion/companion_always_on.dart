import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../pets/overlay_channel.dart';
import '../speech/speech_settings.dart' show companionEffectiveVoiceProvider;

import '../state/companion_agent_state.dart';
import '../state/models_state.dart' show modelSelectionScopeProvider;
import '../state/phone_state.dart' show phoneChannelProvider;
import 'companion_agent.dart';
import 'companion_agent_task_ui.dart';
import 'companion_float.dart';
import 'companion_host_tasks.dart';
import 'companion_initiative.dart';
import 'companion_initiative_owner.dart';
import 'companion_maps.dart';
import 'companion_moves.dart';
import 'companion_reply.dart';
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
  ref.listen(petOverlayProvider, (previous, value) {
    // Her phone work hides her floating self; what she says meanwhile goes on.
    if (previous?.showing == true && !value.showing && !owner._onPhone) owner._hush();
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
  ProviderSubscription<Object>? _screenRoute;
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
  int _sentSteps = 0;
  CompanionPhoneLines _phoneLines = CompanionPhoneLines();
  StreamSubscription<void>? _phoneStops;
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
    // A model change re-routes what she sees; heard only while she can look.
    _screenRoute ??= ref.listen(modelSelectionScopeProvider, (_, _) => agent.modelRouteChanged());
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
            fromFloat: fromFloat,
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
      // The person opens her composer to say something: she stops to listen.
      _hush();
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
      _sentSteps = 0;
      _phoneLines = CompanionPhoneLines();
      _textAfterControl = 0;
    }
    final text = agent.text;
    final raw = _textAfterControl <= text.length ? text.substring(_textAfterControl) : '';
    final moves = _resident!.moves;
    final parsed = !agent.hasSessionReply ? null : parseCompanionReply(
      raw,
      streaming: agent.running,
      emotions: moves.emotionLabels,
      actions: moves.actionLabels,
    );
    final activity = agent.sessionActivity;
    final visible = parsed == null ? raw.trim() : activity ??
        (parsed.words.isEmpty && !agent.running && _sentText != null
            ? agent.error == null ? appL10n.stateAlertPublicDone : appL10n.stateAlertPublicFailed
            : parsed.words);
    final steps = agent.phoneSteps;
    _watchPhoneStops(_onPhone);
    if (reply == null ||
        visible.isEmpty ||
        (visible == _sentText && _sentRunning == agent.running && steps == _sentSteps)) {
      return;
    }
    _sentText = visible;
    _sentRunning = agent.running;
    _sentSteps = steps;
    final resident = _resident;
    // While her room is open, even behind another app, it reads her words aloud.
    final voiced = resident != null && !resident.roomOpen;
    var line = visible;
    String? phoneSay;
    if (steps > 0) {
      // On the phone: her latest line in the bubble, and heard as she goes.
      final read = _phoneLines.read(
        parsed?.words ?? companionWithoutMarks(visible, streaming: agent.running),
        steps: steps,
        running: agent.running,
      );
      line = read.line;
      if (voiced && read.say.isNotEmpty) phoneSay = read.say;
    }
    final speak = steps == 0 &&
        voiced &&
        (parsed?.words ?? raw.trim()).isNotEmpty &&
        !agent.running &&
        _fromFloat &&
        resident.ownsCurrentRun &&
        _spokenReplies.add(reply);
    while (_spokenReplies.length > 64) {
      _spokenReplies.remove(_spokenReplies.first);
    }
    final generation = _voiceGeneration;
    if (resident != null && line.isNotEmpty) {
      unawaited(
        resident.deliverReply(reply, raw, (noticeEpoch) async {
          final shown = await _presentLine(
            id: reply,
            text: line,
            emotion: parsed?.marks.where((m) => m.kind == CompanionMarkKind.emotion).lastOrNull?.name ?? 'neutral',
            speak: speak,
            noticeEpoch: noticeEpoch,
          );
          // Phone work mostly hides her floating self: her words are heard all the same.
          if (phoneSay != null && noticeEpoch == null) await _speak(reply, phoneSay, generation, keepUp: true);
          return shown;
        }),
      );
    }
    _postReply(reply, raw, visible);
  }

  bool get _onPhone => agent.running && agent.phoneSteps > 0;

  /// While she works on the phone, the person stopping it from the island or
  /// pill stops her voice too.
  void _watchPhoneStops(bool onPhone) {
    if (onPhone) {
      _phoneStops ??= companionPhoneUserStops(ref.read(phoneChannelProvider).statusChanges).listen((_) => _hush());
    } else if (_phoneStops != null) {
      unawaited(_phoneStops!.cancel());
      _phoneStops = null;
    }
  }

  /// The reply update still waiting in [_notificationQueue].
  _ReplyUpdate? _replyUpdate;

  /// A streaming reply reaches the notification a few times a second, its
  /// latest text each time: Android drops updates to a notification beyond
  /// about five a second (the last one too), and each update holds the
  /// platform thread for two file locks and several system calls.
  void _postReply(String id, String raw, String text) {
    final waiting = _replyUpdate;
    if (waiting != null &&
        waiting.id == id &&
        waiting.generation == _outputGeneration &&
        waiting.epoch == _status.epoch) {
      waiting.raw = raw;
      waiting.text = text;
      return;
    }
    final update = _replyUpdate = _ReplyUpdate(id, raw, text, _outputGeneration, _status.epoch);
    _notificationQueue = _notificationQueue.catchError((Object _) {}).then((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (identical(_replyUpdate, update)) _replyUpdate = null;
      if (!active || update.generation != _outputGeneration || update.epoch != _status.epoch) return;
      final resident = _resident;
      if (resident == null) return;
      await resident.deliverReply(
        update.id,
        update.raw,
        (noticeEpoch) => channel.update(
          epoch: update.epoch,
          name: _name,
          text: update.text,
          id: update.id,
          noticeEpoch: noticeEpoch,
        ),
      );
    });
  }

  void _post({required String id, required String text, bool user = false}) {
    _replyUpdate = null;
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
    _screenRoute?.close();
    _screenRoute = null;
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
    _watchPhoneStops(false);
    _screen.dispose();
    _screenRoute?.close();
  }

  Future<bool> _presentLine({
    required String id,
    required String text,
    required String emotion,
    required bool speak,
    int? noticeEpoch,
  }) async {
    final generation = _voiceGeneration;
    final shown = await overlay.presentCompanion(
      id: id,
      text: text,
      emotion: emotion,
      speaking: false,
      noticeEpoch: noticeEpoch,
    );
    // Notice-derived words stay on the already-authorized text surface. A
    // voice model warm-up cannot retain authority across a later lock.
    if (!shown || noticeEpoch != null || !speak || !ref.read(petOverlayProvider).showing) return shown;
    await _speak(id, text, generation);
    return shown;
  }

  /// Reads [words] aloud in her voice when it is on; her mouth moves along in
  /// [bubble] while that shows. [keepUp]: on the phone, a line that would wait
  /// behind two others replaces them, so she never falls behind what she does.
  Future<void> _speak(String bubble, String words, int generation, {bool keepUp = false}) async {
    final settings = ref.read(companionEffectiveVoiceProvider);
    if (settings?.on != true) return;
    final ready = await _speaker.ready(settings!);
    if (!ready || !active || generation != _voiceGeneration) return;
    if (keepUp && _voices.length > 1) _hush();
    final voiceId = 'float:${_status.epoch}:${++_voiceSerial}';
    _voices[voiceId] = (bubble: bubble, chars: words.length);
    _speaker.speak(voiceId, words);
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
    implements
        CompanionAgentRoomUi,
        CompanionFallbackUi,
        CompanionInitiativeRoom,
        CompanionAgentAmbientUi,
        CompanionAgentNotificationUi,
        CompanionAgentNoticeUi {
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
  Future<bool> deliverNotice({required String id, required String text, required int noticeEpoch}) => owner.channel
      .deliver(epoch: owner._status.epoch, name: owner._name, text: text, id: id, noticeEpoch: noticeEpoch);
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
    blocked: owner.agent.running && owner._resident?.preparingSignalId == null,
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
  void continuedOnPhone(String sourceId) {
    unawaited(presentLine(id: 'route:$sourceId', text: appL10n.companionContinuedOnPhone, emotion: 'neutral', speak: false));
  }
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
  bool canPresent(CompanionInitiativeTicket ticket) {
    final preparing = owner._resident?.preparingSignalId;
    return ticket.kind == CompanionPromptKind.signal &&
        owner.active &&
        owner._status.notificationAvailable &&
        (!owner.agent.running || (preparing != null && ticket.signalId == preparing));
  }

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

final class _ReplyUpdate {
  _ReplyUpdate(this.id, this.raw, this.text, this.generation, this.epoch);
  final String id;
  String raw;
  String text;
  final int generation;
  final int epoch;
}
