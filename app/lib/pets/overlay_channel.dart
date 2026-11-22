// The Dart side of the out-of-app pet (MethodChannel `dsh/pet_overlay`;
// native: android/.../pet/PetOverlayPlugin.kt). Dart pushes every new
// [PetState] (and says when a brought pet's files changed); the overlay's own
// switches, 「一直显示」, 「今天不再显示」 and the permission live natively and
// are read and set here. Rules:
// `docs/design/pets.md` §2.7, §6.
//
// Every call tolerates the native side being absent (widget tests, desktop):
// pushes go nowhere and [PetOverlayStatus.unavailable] says so.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pet_state.dart';

/// What the overlay may use to draw over other apps.
enum PetOverlayPermission {
  /// The phone-control accessibility service is on: its overlay needs nothing else.
  accessibility,

  /// 「显示在其他应用上层」 works.
  granted,

  /// The system reports the permission, but the window was refused: a
  /// vendor's own floating-window switch (vivo and others).
  blocked,

  /// Not allowed.
  denied;

  static PetOverlayPermission fromName(Object? name) => values.asNameMap()[name is String ? name : null] ?? denied;

  /// The window can be shown.
  bool get usable => this == accessibility || this == granted;
}

/// The overlay's switches and permission, as the native side holds them.
class PetOverlayStatus {
  const PetOverlayStatus({
    this.native = true,
    this.enabled = false,
    this.alwaysShow = false,
    this.permission = PetOverlayPermission.denied,
    this.snoozed = false,
    this.showing = false,
    this.sdk = 0,
    this.manufacturer = '',
    this.refused = false,
    this.ios = false,
    this.usable = false,
    this.keepingAlive = false,
    this.pipActive = false,
    this.phoneTaskActive = false,
    this.taskPaused = false,
    this.errorCode,
    this.companionRendering = false,
    this.companionFallback = false,
    this.companionProblem,
  });

  /// No native side: nothing to switch on.
  const PetOverlayStatus.unavailable() : this(native: false);

  factory PetOverlayStatus.fromMap(Map<Object?, Object?> m) => PetOverlayStatus(
    enabled: m['enabled'] == true,
    alwaysShow: m['alwaysShow'] == true,
    permission: PetOverlayPermission.fromName(m['permission']),
    snoozed: m['snoozed'] == true,
    showing: m['showing'] == true,
    sdk: (m['sdk'] as num?)?.toInt() ?? 0,
    manufacturer: m['manufacturer'] is String ? m['manufacturer']! as String : '',
    ios: m['platform'] == 'ios',
    usable: m['usable'] == true,
    keepingAlive: m['keepingAlive'] == true,
    pipActive: m['active'] == true,
    phoneTaskActive: m['phoneTaskActive'] == true,
    taskPaused: m['paused'] == true || m['needsStopConfirmation'] == true,
    errorCode: m['errorCode'] is String ? m['errorCode']! as String : null,
    companionRendering: m['companionRendering'] == true,
    companionFallback: m['companionFallback'] == true,
    companionProblem: m['companionProblem'] is String ? m['companionProblem'] as String : null,
  );

  final bool native;

  /// The person turned 「App 外显示」 on (it may still lack the permission).
  final bool enabled;

  /// 「一直显示」 instead of 「有事时显示」.
  final bool alwaysShow;
  final PetOverlayPermission permission;

  /// 「今天不再显示」 until midnight.
  final bool snoozed;

  /// The pet is on screen right now.
  final bool showing;

  /// Android API level (Android 13 = 33: sideloaded apps hit 「受限制的设置」).
  final int sdk;

  /// `Build.MANUFACTURER`, for the vendor-specific guide.
  final String manufacturer;

  /// Not native: set by [PetOverlayController] when a trip to system
  /// settings came back without the permission (the row says 「未授权」).
  final bool refused;
  final bool companionRendering;
  final bool companionFallback;
  final String? companionProblem;

  // iOS: the pet in picture-in-picture, which keeps phone control alive in the background
  // (tooling/ios/pet-overlay-tests/README.md). Android sends none of these.

  /// The native side is the iOS picture-in-picture one.
  final bool ios;

  /// Switched on, supported, a valid pet chosen, not stopped by an error: phone control may run.
  final bool usable;

  /// Picture-in-picture is actually showing and holding the app up right now.
  final bool keepingAlive;
  final bool pipActive;
  final bool phoneTaskActive;

  /// The phone task was paused from picture-in-picture and waits for 继续 or 停止 in the app.
  final bool taskPaused;

  /// Why it stopped (`overlay_...`), or null.
  final String? errorCode;

  PetOverlayStatus copyWith({bool? refused}) => PetOverlayStatus(
    native: native,
    enabled: enabled,
    alwaysShow: alwaysShow,
    permission: permission,
    snoozed: snoozed,
    showing: showing,
    sdk: sdk,
    manufacturer: manufacturer,
    refused: refused ?? this.refused,
    ios: ios,
    usable: usable,
    keepingAlive: keepingAlive,
    pipActive: pipActive,
    phoneTaskActive: phoneTaskActive,
    taskPaused: taskPaused,
    errorCode: errorCode,
    companionRendering: companionRendering,
    companionFallback: companionFallback,
    companionProblem: companionProblem,
  );

  /// On and able to show.
  bool get working => enabled && permission.usable;

  @override
  bool operator ==(Object other) =>
      other is PetOverlayStatus &&
      other.native == native &&
      other.enabled == enabled &&
      other.alwaysShow == alwaysShow &&
      other.permission == permission &&
      other.snoozed == snoozed &&
      other.showing == showing &&
      other.sdk == sdk &&
      other.manufacturer == manufacturer &&
      other.refused == refused &&
      other.ios == ios &&
      other.usable == usable &&
      other.keepingAlive == keepingAlive &&
      other.pipActive == pipActive &&
      other.phoneTaskActive == phoneTaskActive &&
      other.taskPaused == taskPaused &&
      other.errorCode == errorCode &&
      other.companionRendering == companionRendering &&
      other.companionFallback == companionFallback &&
      other.companionProblem == companionProblem;

  @override
  int get hashCode => Object.hash(
    native,
    enabled,
    alwaysShow,
    permission,
    snoozed,
    showing,
    sdk,
    manufacturer,
    refused,
    ios,
    usable,
    keepingAlive,
    pipActive,
    phoneTaskActive,
    taskPaused,
    errorCode,
    companionRendering,
    companionFallback,
    companionProblem,
  );

  @override
  String toString() =>
      'PetOverlayStatus(${native ? '' : 'no native, '}enabled: $enabled, always: $alwaysShow, ${permission.name}'
      '${snoozed ? ', snoozed' : ''}${showing ? ', showing' : ''}${refused ? ', refused' : ''})';
}

/// MethodChannel `dsh/pet_overlay`.
class PetOverlayChannel {
  PetOverlayChannel([this.channel = const MethodChannel('dsh/pet_overlay')]);

  final MethodChannel channel;
  final _statusEvents = StreamController<PetOverlayStatus>.broadcast();
  final _settings = StreamController<void>.broadcast();
  bool _listening = false;
  Future<Object?> Function(MethodCall)? _actions;
  Future<Object?> Function(MethodCall)? _companionActions;
  Future<String?> Function(String text)? voiceFallback;

  void setActionHandler(Future<Object?> Function(MethodCall)? handler) {
    _actions = handler;
    _listen();
  }

  void setCompanionActionHandler(Future<Object?> Function(MethodCall)? handler) {
    _companionActions = handler;
    _listen();
  }

  Future<void> companionMode({required bool enabled, required String name}) async {
    try {
      await channel.invokeMethod<void>('companionMode', {'enabled': enabled, 'name': name});
    } on MissingPluginException {
      /* No Android overlay. */
    } on PlatformException {
      /* Actual status still reports the failed overlay. */
    }
  }

  Future<bool> presentCompanion({
    required String id,
    required String text,
    String emotion = 'neutral',
    bool speaking = false,
  }) async {
    try {
      return await channel.invokeMethod<bool>('companionLine', {
            'id': id,
            'text': text,
            'emotion': emotion,
            'speaking': speaking,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> companionSpeech({required String id, required int chars, required bool speaking}) async {
    try {
      await channel.invokeMethod<void>('companionSpeech', {'id': id, 'chars': chars, 'speaking': speaking});
    } on MissingPluginException {
      /* No displayed body. */
    } on PlatformException {
      /* A late voice event owns no replacement window. */
    }
  }

  Future<void> clearCompanion() async {
    try {
      await channel.invokeMethod<void>('clearCompanion');
    } on MissingPluginException {
      /* No displayed companion body. */
    } on PlatformException {
      /* The next actual window evaluation rechecks it. */
    }
  }

  /// Sends [state] to the overlay; nothing happens without the native side.
  Future<void> push(PetState state) async {
    try {
      await channel.invokeMethod<void>('push', state.toMap());
    } on MissingPluginException {
      // Tests, desktop: no overlay.
    } on PlatformException {
      // A bad push is not worth failing the pet over.
    }
  }

  /// A brought pet's files changed (imported again, removed): the overlay
  /// reads [id] from disk again if it is the one out, instead of keeping the
  /// old picture (it keys what it loaded by id and size only).
  Future<void> reloadPack(String id) async {
    try {
      await channel.invokeMethod<void>('reloadPack', {'id': id});
    } on MissingPluginException {
      // Tests, desktop, an older native side: nothing to reload.
    } on PlatformException {
      // Not worth failing an import over.
    }
  }

  Future<PetOverlayStatus> status() => _call('status');

  /// Acknowledgement is required: pack replacement must not proceed while a
  /// native WebView might still read it. Unlike optional pixel pushes, this
  /// call propagates an unavailable/failed native endpoint to its owner.
  Future<PetOverlayStatus> configureCompanion({Uri? page, String? notice}) async {
    final raw = await channel.invokeMethod<Object?>('configureCompanion', {'url': page?.toString(), 'notice': notice});
    if (raw is! Map) throw PlatformException(code: 'companion_native_unavailable');
    return PetOverlayStatus.fromMap(raw);
  }

  /// Like [status], but checks the permission for real (adds and removes an
  /// invisible window): what to call when coming back from system settings.
  Future<PetOverlayStatus> permissionStatus() => _call('permissionStatus');

  Future<PetOverlayStatus> setEnabled(bool enabled) => _call('setEnabled', {'enabled': enabled});

  Future<PetOverlayStatus> setAlwaysShow(bool on) => _call('setAlwaysShow', {'on': on});

  /// Ends 「今天不再显示」.
  Future<PetOverlayStatus> unsnooze() => _call('unsnooze');

  /// Opens 「显示在其他应用上层」 for this app (else its app info page).
  Future<bool> requestPermission() => _bool('requestPermission');

  /// Opens the app's system info page (restricted settings, vendor switches).
  Future<bool> openAppDetails() => _bool('openAppDetails');

  /// iOS: a switch or step whose native confirmation may be refused (app in the background,
  /// another dialog up). Then the status is read again rather than taken as no native side.
  Future<PetOverlayStatus> iosStep(String method, [Map<String, Object?>? args]) async {
    try {
      final raw = await channel.invokeMethod<Object?>(method, args);
      if (raw is Map) return PetOverlayStatus.fromMap(raw);
    } on MissingPluginException {
      return const PetOverlayStatus.unavailable();
    } on PlatformException {
      // Not done; what is true now follows.
    }
    return status();
  }

  /// iOS: starts picture-in-picture now. Only from the person's own tap in the app.
  Future<bool> startPictureInPicture() => _bool('startPictureInPicture');

  /// The native status whenever it changes (switched from the pet's menu,
  /// a permission found out, the pet shown or gone).
  Stream<PetOverlayStatus> get statusChanges {
    _listen();
    return _statusEvents.stream;
  }

  /// 「宠物设置」 tapped in the floating pet's menu: the app is coming to the
  /// front; open the pet settings page.
  Stream<void> get settingsRequests {
    _listen();
    return _settings.stream;
  }

  void _listen() {
    if (_listening) return;
    _listening = true;
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'companionAskTarget':
          final target = await _companionActions?.call(call);
          if (target is! Map) return target;
          // Reuse the actual existing local speech capability check only.
          // No ordinary Host ask/submit is called for companion text.
          final legacy = await _actions?.call(const MethodCall('askTarget', {'fresh': false}));
          return {...target, 'voice': legacy is Map ? legacy['voice'] : 'off'};
        case 'companionAsk':
          return _companionActions?.call(call);
        case 'status':
          final args = call.arguments;
          if (args is Map) _statusEvents.add(PetOverlayStatus.fromMap(args));
        case 'voiceFallback':
          final args = call.arguments;
          if (args is! Map || args['text'] is! String || voiceFallback == null) return null;
          return {'text': await voiceFallback!(args['text'] as String)};
        case 'openSettings':
          _settings.add(null);
        default:
          return _actions?.call(call);
      }
      return null;
    });
  }

  Future<PetOverlayStatus> _call(String method, [Map<String, Object?>? args]) async {
    try {
      final raw = await channel.invokeMethod<Object?>(method, args);
      return raw is Map ? PetOverlayStatus.fromMap(raw) : const PetOverlayStatus.unavailable();
    } on MissingPluginException {
      return const PetOverlayStatus.unavailable();
    } on PlatformException {
      return const PetOverlayStatus.unavailable();
    }
  }

  Future<bool> _bool(String method) async {
    try {
      return await channel.invokeMethod<bool>(method) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

final petOverlayChannelProvider = Provider<PetOverlayChannel>((ref) => PetOverlayChannel());

/// 「宠物设置」 from the floating pet's menu. Whoever owns navigation listens
/// and opens `PetSettingsPage`.
final petOverlaySettingsRequestsProvider = StreamProvider<void>(
  (ref) => ref.watch(petOverlayChannelProvider).settingsRequests,
);

/// The overlay's status and its switches, for the settings group and the
/// restricted-settings guide.
final petOverlayProvider = NotifierProvider<PetOverlayController, PetOverlayStatus>(PetOverlayController.new);

class PetOverlayController extends Notifier<PetOverlayStatus> {
  StreamSubscription<PetOverlayStatus>? _changes;

  /// Sent to system settings for the permission; the next [refresh] tells
  /// whether it came back granted.
  bool _asked = false;

  PetOverlayChannel get _channel => ref.read(petOverlayChannelProvider);

  @override
  PetOverlayStatus build() {
    _changes = _channel.statusChanges.listen(_set);
    ref.onDispose(() => _changes?.cancel());
    unawaited(_channel.status().then(_set));
    // Until the native side answers: off, which is also the default there.
    return const PetOverlayStatus();
  }

  void _set(PetOverlayStatus s, {bool? refused}) {
    if (!ref.mounted) return;
    state = s.copyWith(refused: s.permission.usable ? false : (refused ?? state.refused));
  }

  /// The real check, e.g. on returning from system settings. A request
  /// that comes back without the permission turns the switch back off
  /// (docs/design/pets.md §6.4).
  Future<PetOverlayStatus> refresh() async {
    final s = await _channel.permissionStatus();
    if (_asked) {
      _asked = false;
      if (s.native && s.enabled && !s.permission.usable) {
        _set(await _channel.setEnabled(false), refused: true);
        return state;
      }
    }
    _set(s);
    return state;
  }

  /// 「App 外显示」 on: with the accessibility overlay or a working
  /// permission it just turns on; otherwise to system settings first.
  Future<void> turnOn() async {
    final s = await _channel.setEnabled(true);
    _set(s);
    if (!s.native || s.permission.usable) return;
    final checked = await _channel.permissionStatus();
    _set(checked);
    if (checked.permission.usable) return;
    // Refused although the system says granted: a vendor switch (vivo) lives on the app's own page.
    _asked = checked.permission == PetOverlayPermission.blocked
        ? await _channel.openAppDetails()
        : await _channel.requestPermission();
    if (!_asked) _set(await _channel.setEnabled(false), refused: true);
  }

  Future<void> turnOff() async {
    _asked = false;
    _set(await _channel.setEnabled(false));
  }

  Future<void> setAlwaysShow(bool on) async => _set(await _channel.setAlwaysShow(on));

  Future<void> unsnooze() async => _set(await _channel.unsnooze());

  /// To 「显示在其他应用上层」 again (the restricted-settings guide): the
  /// switch turns on with it, so coming back granted is all it takes.
  Future<bool> openPermission() async {
    _set(await _channel.setEnabled(true));
    _asked = await _channel.requestPermission();
    return _asked;
  }

  Future<bool> openAppDetails() => _channel.openAppDetails();

  /// iOS: on or off (the native side explains and asks before on), and 一直显示.
  Future<void> iosSetEnabled(bool on) async => _set(await _channel.iosStep('setEnabled', {'enabled': on}));

  Future<void> iosSetAlwaysShow(bool on) async => _set(await _channel.iosStep('setAlwaysShow', {'on': on}));

  /// iOS: back after a stop (system closed it, the phone locked, audio taken over).
  Future<void> iosResume() async => _set(await _channel.iosStep('unsnooze'));

  /// iOS: the native 继续 / 停止 question for a phone task paused from picture-in-picture.
  Future<void> iosReviewPausedTask() async => _set(await _channel.iosStep('reviewPausedTask'));

  Future<void> iosStart() async {
    await _channel.startPictureInPicture();
    _set(await _channel.status());
  }
}
