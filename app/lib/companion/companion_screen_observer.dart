import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'companion_agent.dart';
import 'companion_screen_pace.dart';

/// The resident owner holds one instance beside its existing CompanionAgent.
/// Native state is the settings/pause authority. This object owns no Agent,
/// engine, user transcript, long-term memory, or phone-action tool bindings.
class CompanionScreenObserver {
  CompanionScreenObserver({required this.agent}) {
    _userCallback = _userSaid;
    agent.onScreenUserText = _userCallback;
    _costCallback = _recordCost;
    agent.onScreenCost = _costCallback;
  }
  final CompanionAgent agent;
  static const _channel = MethodChannel('dsh/phone');
  static const _events = EventChannel('dsh/companion_screen/state');
  final state = ValueNotifier<Map<String, Object?>>(const {'enabled': false});
  final _pace = CompanionScreenPace();
  late final void Function(String) _userCallback;
  late final void Function(String, int, double?) _costCallback;
  StreamSubscription<dynamic>? _subscription;
  Timer? _timer;
  bool _active = false;
  bool _disposed = false;
  bool _sampling = false;
  bool _validating = false;
  bool _reducedPower = false;
  int _generation = 0;
  String? _inFlightSample;

  void start() {
    if (_disposed || _active) return;
    _active = true;
    _subscription ??= _events.receiveBroadcastStream().listen(
      _acceptState,
      onError: (Object error) {
        _cancel();
      },
    );
    unawaited(
      _channel
          .invokeMethod<Object?>('companionScreenState', const {'op': 'resident', 'active': true})
          .then(_acceptState)
          .catchError((Object error) {
            _cancel();
          }),
    );
    _schedule();
  }

  /// The resident owner forwards actual system low-battery/power-save state.
  /// This only changes the sampling cadence; it does not cancel a receipt or
  /// change the user's chosen frequency and never delays Agent.say.
  void setReducedPower(bool value) {
    if (_disposed || _reducedPower == value) return;
    _reducedPower = value;
    if (_active) _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: _reducedPower ? 4 : 2), (_) {
      unawaited(_tick());
    });
  }

  void stop() {
    _active = false;
    _timer?.cancel();
    _timer = null;
    _cancel();
    unawaited(
      _channel
          .invokeMethod<Object?>('companionScreenState', const {'op': 'resident', 'active': false})
          .then(_acceptState)
          .catchError((Object error) {}),
    );
  }

  void dispose() {
    if (_disposed) return;
    stop();
    _disposed = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
    if (agent.onScreenUserText == _userCallback) agent.onScreenUserText = null;
    if (agent.onScreenCost == _costCallback) agent.onScreenCost = null;
    state.dispose();
  }

  Future<void> refresh() async {
    if (_disposed) return;
    try {
      _acceptState(await _channel.invokeMethod<Object?>('companionScreenState'));
    } on Object {
      if (!_disposed) _cancel();
    }
  }

  /// Used by the owner's settings UI; the native side persists the same state
  /// read by the notification action and both capture backends.
  Future<void> configure({
    bool? enabled,
    String? frequency,
    List<String>? excludedPackages,
    int? seriousPerHour,
  }) async {
    if (_disposed) return;
    if (enabled == false) _cancel();
    _acceptState(
      await _channel.invokeMethod<Object?>('companionScreenState', {
        'op': 'configure',
        'enabled': ?enabled,
        'frequency': ?frequency,
        'excluded_packages': ?excludedPackages,
        'serious_per_hour': ?seriousPerHour,
      }),
    );
  }

  Future<void> requestProjection() async {
    if (!_disposed) {
      _acceptState(await _channel.invokeMethod<Object?>('companionScreenState', const {'op': 'request_projection'}));
    }
  }

  Future<void> requestUsageAccess() async {
    if (!_disposed) {
      _acceptState(await _channel.invokeMethod<Object?>('companionScreenState', const {'op': 'request_usage_access'}));
    }
  }

  void _acceptState(Object? raw) {
    if (_disposed || raw is! Map) return;
    final next = Map<String, Object?>.from(raw);
    if (next['generation'] is num &&
        state.value['generation'] is num &&
        (next['generation']! as num) < (state.value['generation']! as num)) {
      return;
    }
    if (next['generation'] != state.value['generation'] ||
        next['enabled'] != true ||
        (next['muted_until_ms'] as num? ?? 0) > DateTime.now().millisecondsSinceEpoch) {
      _cancel();
    }
    _pace.frequency = next['frequency'] as String? ?? 'normal';
    state.value = Map<String, Object?>.unmodifiable(next);
  }

  void _cancel() {
    _generation++;
    _inFlightSample = null;
    agent.cancelScreenObservation();
  }

  void _recordCost(String id, int at, double? estimated) {
    if (_disposed) return;
    unawaited(
      _channel
          .invokeMethod<Object?>('companionScreenState', {
            'op': 'cost',
            'request_id': id,
            'at_ms': at,
            'estimated_cny': estimated,
          })
          .then(_acceptState)
          .catchError((Object error) {}),
    );
  }

  void _userSaid(String words) {
    _cancel();
    _pace.userSpoke(agent.lastUserInteractionAtMs);
    final command = words.trim().replaceAll(RegExp(r'[。！!？?]+$'), '');
    final op = command == '别看了'
        ? 'pause'
        : command == '先别吵'
        ? 'mute'
        : null;
    if (op != null) {
      // Stop locally before waiting for the native persistence/notification.
      state.value = Map<String, Object?>.unmodifiable({
        ...state.value,
        if (op == 'pause') 'enabled': false,
        if (op == 'mute') 'muted_until_ms': DateTime.now().millisecondsSinceEpoch + 3600000,
      });
      unawaited(
        _channel
            .invokeMethod<Object?>('companionScreenState', {'op': op})
            .then(_acceptState)
            .catchError((Object error) {}),
      );
    }
  }

  bool get _enabled =>
      _active &&
      !_disposed &&
      state.value['enabled'] == true &&
      state.value['resident_active'] == true &&
      (state.value['muted_until_ms'] as num? ?? 0) <= DateTime.now().millisecondsSinceEpoch;

  Future<bool> _valid(String sample, int generation, {bool requireIdle = false}) async {
    if (!_enabled || generation != _generation) return false;
    final value = await _channel.invokeMapMethod<String, Object?>('companionScreenSample', {
      'validate': sample,
      if (requireIdle) 'require_idle': true,
    });
    return _enabled && generation == _generation && value?['status'] == 'valid';
  }

  Future<void> _checkInFlight() async {
    final sample = _inFlightSample;
    if (sample == null || _validating) return;
    _validating = true;
    final generation = _generation;
    try {
      if (!await _valid(sample, generation) && generation == _generation) _cancel();
    } on Object {
      if (generation == _generation) _cancel();
    } finally {
      _validating = false;
    }
  }

  Future<bool> _permit(String tier, String sample) async {
    final raw = await _channel.invokeMapMethod<String, Object?>('companionScreenState', {
      'op': 'permit',
      'tier': tier,
      'sample_id': sample,
    });
    return raw?['allowed'] == true;
  }

  Future<void> _tick() async {
    _pace.userSpoke(agent.lastUserInteractionAtMs);
    if (!_enabled) return;
    if (_sampling) {
      await _checkInFlight();
      return;
    }
    if (agent.running) return;
    _sampling = true;
    final generation = _generation;
    try {
      final sample = await _channel.invokeMapMethod<String, Object?>('companionScreenSample');
      if (!_enabled || generation != _generation || sample?['status'] != 'observed') return;
      final token = sample!['sample_id'];
      final now = DateTime.now().millisecondsSinceEpoch;
      if (token is! String ||
          sample['text'] is! String ||
          sample['package_name'] is! String ||
          sample['observed_at_ms'] is! int ||
          !const {'tree', 'ocr'}.contains(sample['capture_method']) ||
          !_pace.cheapDue(now)) {
        return;
      }
      _inFlightSample = token;
      final context = <String, Object?>{
        'type': 'screen_observation',
        'observed_at_ms': sample['observed_at_ms'],
        'package_name': sample['package_name'],
        'window_title': sample['window_title'],
        'capture_method': sample['capture_method'],
        'text': sample['text'],
      };
      if (!await _permit('cheap', token) || !_enabled || generation != _generation) return;
      _pace.cheapStarted(now);
      final reading = CompanionScreenReading.parse(await agent.classifyScreen(context: context));
      if (reading == null || !await _valid(token, generation)) return;
      _pace.observed(reading);
      // This is only a local same-day activity label; no screenshot or source text.
      await _channel.invokeMethod<Object?>('companionScreenState', {'op': 'note', 'scene': reading.scene});
      if (!_enabled || generation != _generation) return;
      final spokeAt = DateTime.now().millisecondsSinceEpoch;
      var shown = false;
      if (_pace.seriousDue(spokeAt, reading, userBusy: sample['busy'] != false) &&
          await _permit('serious', token) &&
          _enabled &&
          generation == _generation) {
        _pace.seriousStarted(spokeAt);
        shown = await agent.observeScreen(
          context: {
            ...context,
            'scene': reading.scene,
            'mood': reading.mood,
            'salience': reading.salience,
            'emotion': reading.emotion,
          },
          isCurrentObservation: () => _valid(token, generation, requireIdle: reading.salience < .95),
        );
        if (shown) _pace.shown(spokeAt, reading, quip: false);
      }
      if (!shown &&
          _enabled &&
          generation == _generation &&
          _pace.quipIsNew(reading.quip) &&
          await _valid(token, generation)) {
        shown = await agent.presentScreenQuip(
          text: reading.quip,
          emotion: reading.emotion,
          observedAtMs: sample['observed_at_ms']! as int,
        );
        if (shown) _pace.shown(DateTime.now().millisecondsSinceEpoch, reading, quip: true);
      }
    } on Object {
      // Physical receipts stay with the Agent. A failed/absent result is not a
      // displayed line and therefore never increments unanswered backoff.
    } finally {
      if (generation == _generation) _inFlightSample = null;
      _sampling = false;
    }
  }
}
