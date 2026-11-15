// Dart side of the `dsh/notify` method channel and the taps / actions event
// channels (native: android/.../notify/NotifyPlugin.kt). Every call tolerates
// the native side being absent (widget tests, desktop): it does nothing, and
// [NotifyChannel.status] says so without flagging anything as blocked.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../state/hosts_state.dart';
import 'live_activity.dart';

/// Whether the system lets DSH's chat notifications through.
class NotifySystemStatus {
  const NotifySystemStatus({this.native = true, this.enabled = true, this.done = true, this.attention = true});

  /// No native side (widget tests, desktop): nothing to post or listen to.
  const NotifySystemStatus.unavailable() : this(native: false);

  factory NotifySystemStatus.fromMap(Map<Object?, Object?> m) =>
      NotifySystemStatus(enabled: m['enabled'] != false, done: m['done'] != false, attention: m['attention'] != false);

  /// The native module answered.
  final bool native;

  /// The app-level switch (`areNotificationsEnabled`, Android 13+ permission).
  final bool enabled;

  /// 「一轮结束」 channel not blocked.
  final bool done;

  /// 「等你确认」 channel not blocked.
  final bool attention;

  bool get allOpen => enabled && done && attention;

  @override
  bool operator ==(Object other) =>
      other is NotifySystemStatus &&
      other.native == native &&
      other.enabled == enabled &&
      other.done == done &&
      other.attention == attention;

  @override
  int get hashCode => Object.hash(native, enabled, done, attention);
}

/// One system notification, as [NotifyChannel.show] posts it.
class NotifyPost {
  const NotifyPost({
    required this.group,
    required this.key,
    required this.attention,
    required this.title,
    required this.text,
    required this.publicText,
    required this.sessionId,
    required this.host,
    required this.kind,
    this.eventId,
    this.canApprove = false,
    this.fullText,
  });

  /// One per conversation: `<host>|<sessionId>` (see [notifyGroup]).
  final String group;

  /// `turn`, or the approval / question event id.
  final String key;
  final bool attention;
  final String title;
  final String text;

  /// What the lock screen shows instead (no title, no content).
  final String publicText;
  final String sessionId;
  final HostRef host;
  final String kind;
  final String? eventId;
  final bool canApprove;
  final String? fullText;

  Map<String, Object?> toMap() => {
    'group': group,
    'key': key,
    'attention': attention,
    'title': title,
    'text': text,
    'publicText': publicText,
    'sessionId': sessionId,
    'host': host.encode(),
    'kind': kind,
    'eventId': ?eventId,
    if (canApprove) 'canApprove': true,
    'fullText': ?fullText,
  };
}

/// A tapped notification: open [sessionId] on [host].
class NotifyTap {
  const NotifyTap({required this.host, required this.sessionId, this.kind, this.eventId});

  /// Null for anything that isn't a well-formed tap of ours.
  static NotifyTap? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final session = raw['sessionId'];
    if (session is! String || session.isEmpty || session.length > 200) return null;
    final host = raw['host'];
    final kind = raw['kind'];
    final event = raw['eventId'];
    return NotifyTap(
      host: HostRef.decode(host is String ? host : null),
      sessionId: session,
      kind: kind is String ? kind : null,
      eventId: event is String ? event : null,
    );
  }

  final HostRef host;
  final String sessionId;
  final String? kind;
  final String? eventId;

  @override
  bool operator ==(Object other) =>
      other is NotifyTap &&
      other.host == host &&
      other.sessionId == sessionId &&
      other.kind == kind &&
      other.eventId == eventId;

  @override
  int get hashCode => Object.hash(host, sessionId, kind, eventId);
}

/// How answering a [NotifyAction] went; the notification shows it.
enum NotifyActionResult { handled, gone, failed }

/// An approval button tapped on the notification [group] / [key].
class NotifyAction {
  const NotifyAction({
    required this.host,
    required this.group,
    required this.key,
    required this.eventId,
    required this.decision,
  });

  /// Null for anything that isn't a well-formed action of ours.
  static NotifyAction? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final group = raw['group'];
    final key = raw['key'];
    final eventId = raw['eventId'];
    final host = raw['host'];
    final decision = switch (raw['decision']) {
      'allowed-once' => ApprovalDecision.allowOnce,
      'rejected' => ApprovalDecision.reject,
      _ => null,
    };
    if (group is! String || key is! String || eventId is! String || eventId.isEmpty || host is! String) return null;
    if (decision == null) return null;
    return NotifyAction(host: HostRef.decode(host), group: group, key: key, eventId: eventId, decision: decision);
  }

  final HostRef host;
  final String group;
  final String key;
  final String eventId;
  final ApprovalDecision decision;
}

/// What the live activity is told: whether it is on, the pet whose pictures
/// it shows, and what the agent does ([LiveActivity]; null: nothing).
@immutable
class LivePush {
  const LivePush({required this.enabled, this.packId, this.activity});

  final bool enabled;
  final String? packId;
  final LiveActivity? activity;

  Map<String, Object?> toMap() => {'enabled': enabled, 'packId': ?packId, 'activity': ?activity?.toMap()};

  @override
  bool operator ==(Object other) =>
      other is LivePush && other.enabled == enabled && other.packId == packId && other.activity == activity;

  @override
  int get hashCode => Object.hash(enabled, packId, activity);
}

/// What the phone offers the live activity.
class LiveSystemStatus {
  const LiveSystemStatus({
    this.native = true,
    this.supported = false,
    this.allowed = false,
    this.settings = false,
    this.xiaomiFocus = false,
  });

  const LiveSystemStatus.unavailable() : this(native: false);

  factory LiveSystemStatus.fromMap(Map<Object?, Object?> m) => LiveSystemStatus(
    supported: m['supported'] == true,
    allowed: m['allowed'] == true,
    settings: m['settings'] == true,
    xiaomiFocus: m['xiaomiFocus'] == true,
  );

  final bool native;

  /// Android 16 promotion exists here (QPR1+), or HyperOS takes the focus template.
  final bool supported;

  /// And it is allowed for DSH Go: the live activity will be posted.
  final bool allowed;

  /// The system page with the per-app switch opens.
  final bool settings;

  /// HyperOS shows DSH Go's focus notifications.
  final bool xiaomiFocus;

  @override
  bool operator ==(Object other) =>
      other is LiveSystemStatus &&
      other.native == native &&
      other.supported == supported &&
      other.allowed == allowed &&
      other.settings == settings &&
      other.xiaomiFocus == xiaomiFocus;

  @override
  int get hashCode => Object.hash(native, supported, allowed, settings, xiaomiFocus);
}

/// Notification group of one conversation on one host.
String notifyGroup(HostRef host, String sessionId) => '${host.kind.name}:${host.id}|$sessionId';

class NotifyChannel {
  NotifyChannel({MethodChannel? methods, EventChannel? taps})
    : _methods = methods ?? const MethodChannel('dsh/notify'),
      _taps = taps ?? const EventChannel('dsh/notify/taps');

  final MethodChannel _methods;
  final EventChannel _taps;
  final EventChannel _actions = const EventChannel('dsh/notify/actions');

  Future<NotifySystemStatus> status() async {
    try {
      final raw = await _methods.invokeMethod<Object?>('status');
      return raw is Map ? NotifySystemStatus.fromMap(raw) : const NotifySystemStatus();
    } on MissingPluginException {
      return const NotifySystemStatus.unavailable();
    } on PlatformException {
      // Android's answer is only ever a stale one; a failure on HarmonyOS or iOS
      // means it doesn't know, which mustn't read as every switch on.
      return Platform.operatingSystem == 'ohos' || Platform.isIOS
          ? const NotifySystemStatus.unavailable()
          : const NotifySystemStatus();
    }
  }

  Future<void> show(NotifyPost post) => _call('show', post.toMap());

  /// An operational return path: report whether the native post was accepted.
  /// This cannot prove that an OEM actually displayed the notification.
  Future<bool> tryShow(NotifyPost post, {bool Function()? stillCurrent}) async {
    try {
      if (stillCurrent?.call() == false) return false;
      final system = await status().timeout(const Duration(seconds: 2));
      if (stillCurrent?.call() == false) return false;
      if (!system.native || !system.enabled || !(post.attention ? system.attention : system.done)) return false;
      await _methods.invokeMethod<void>('show', post.toMap()).timeout(const Duration(seconds: 3));
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  Future<void> cancel(String group, String key) => _call('cancel', {'group': group, 'key': key});

  Future<void> cancelGroup(String group) => _call('cancelGroup', {'group': group});

  Future<void> cancelAll() => _call('cancelAll');

  /// The system's permission dialog on HarmonyOS and iOS; true when notifications
  /// are on afterwards.
  /// It comes up once: after a refusal only [openSettings] can turn them on.
  Future<bool> requestPermission() async {
    try {
      return await _methods.invokeMethod<bool>('requestPermission') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens the system notification settings; [channel] (`done` / `attention`)
  /// goes straight to that channel when the app-level switch is on.
  Future<bool> openSettings({String? channel}) async {
    try {
      return await _methods.invokeMethod<bool>('openSettings', {'channel': ?channel}) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Tells the live activity what to show (see [LivePush]).
  Future<void> live(LivePush push) => _call('live', push.toMap());

  Future<LiveSystemStatus> liveStatus() async {
    try {
      final raw = await _methods.invokeMethod<Object?>('liveStatus');
      return raw is Map ? LiveSystemStatus.fromMap(raw) : const LiveSystemStatus();
    } on MissingPluginException {
      return const LiveSystemStatus.unavailable();
    } on PlatformException {
      return const LiveSystemStatus();
    }
  }

  /// Opens DSH Go's 「实时活动」 switch where the system has one, else its notification settings.
  Future<bool> openLiveSettings() async {
    try {
      return await _methods.invokeMethod<bool>('openLiveSettings') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Taps on our notifications, including the one that launched the app.
  /// Listen only once [status] reported the native side: activating the
  /// stream without one reports an error to Flutter.
  Stream<NotifyTap> get taps => _taps
      .receiveBroadcastStream()
      .map(NotifyTap.fromMap)
      .where((t) => t != null)
      .cast<NotifyTap>()
      .handleError((Object _) {}, test: (e) => e is MissingPluginException || e is PlatformException);

  /// Approval buttons tapped on our notifications. Same rule as [taps]: listen
  /// only once [status] reported the native side.
  Stream<NotifyAction> get actions => _actions
      .receiveBroadcastStream()
      .map(NotifyAction.fromMap)
      .where((a) => a != null)
      .cast<NotifyAction>()
      .handleError((Object _) {}, test: (e) => e is MissingPluginException || e is PlatformException);

  /// Shows how [action] went on its notification.
  Future<void> completeAction(NotifyAction action, NotifyActionResult result) =>
      _call('actionResult', {'group': action.group, 'key': action.key, 'result': result.name});

  Future<void> _call(String method, [Map<String, Object?>? args]) async {
    try {
      await _methods.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // No native side (tests, desktop): nothing to post.
    } on PlatformException {
      // A bad post is not worth failing the event loop over.
    }
  }
}
