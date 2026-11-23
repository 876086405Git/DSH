// A fake native side for `dsh/phone` + `dsh/phone/events` (the contract
// PhonePlugin.kt implements), plus a runtime that records restarts. Widget
// tests run the real PhoneChannel against it, so parsing is exercised too.

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const phoneMethods = MethodChannel('dsh/phone');
const phoneEvents = EventChannel('dsh/phone/events');

/// A `status` map as the native module sends it.
Map<String, Object?> phoneStatus({
  bool enabled = true,
  bool bridgeListening = true,
  bool a11y = false,
  bool? serviceConnected,
  bool notifications = true,
  String mode = 'off',
  bool backgroundReady = false,
  String? backgroundReason,
  bool androidOk = true,
  bool shizukuInstalled = false,
  bool shizukuRunning = false,
  bool shizukuGranted = false,
  bool? wirelessDebugging = false,
  bool paired = false,
  bool adbConnected = false,
  bool taskActive = false,
  int? taskId,
  String? taskApp,
  bool taskPaused = false,
  bool taskStopped = false,
  bool taskWaived = false,
  Map<String, Object?>? device = const {'manufacturer': 'vivo', 'sdkInt': 35, 'sideloaded': true},
}) => {
  'enabled': enabled,
  'bridgeListening': bridgeListening,
  'a11y': {'enabled': a11y, 'serviceConnected': serviceConnected ?? a11y},
  'overlay': a11y,
  'notifications': notifications,
  'background': {
    'mode': mode,
    'ready': backgroundReady,
    'reason': backgroundReason,
    'androidOk': androidOk,
    'shizuku': {'installed': shizukuInstalled, 'running': shizukuRunning, 'granted': shizukuGranted},
    'adb': {'wirelessDebugging': wirelessDebugging, 'paired': paired, 'connected': adbConnected},
  },
  'task': {
    'id': ?taskId,
    'active': taskActive,
    'app': taskApp,
    'paused': taskPaused,
    'stopped': taskStopped,
    'waived': taskWaived,
  },
  'device': ?device,
};

/// [phoneStatus] from a native module with the versioned five-channel block
/// (`background.privileged` v1, `background.root`, the shared API's source),
/// the old fields projected as it projects them: Sui is Shizuku, root is off.
Map<String, Object?> privilegedStatus({
  String mode = 'off',
  bool ready = false,
  String? reason,
  String recommended = 'off',
  String grantPath = 'setup',
  bool? rootSelected,
  String? provider,
  bool shizukuApp = false,
  bool running = false,
  bool granted = false,
  Map<String, Object?> root = const {},
  bool? wirelessDebugging = false,
  bool paired = false,
  bool adbConnected = false,
  bool androidOk = true,
  bool enabled = true,
  Map<String, Object?>? keep,
}) {
  final base = phoneStatus(
    enabled: enabled,
    androidOk: androidOk,
    wirelessDebugging: wirelessDebugging,
    paired: paired,
    adbConnected: adbConnected,
  );
  final legacy = switch (mode) {
    'sui' => 'shizuku',
    'root' => 'off',
    _ => mode,
  };
  return {
    ...base,
    'background': {
      ...(base['background'] as Map).cast<String, Object?>(),
      'mode': legacy,
      'ready': ready && legacy != 'off',
      'reason': reason,
      'shizuku': {
        'installed': shizukuApp || provider != null,
        'appInstalled': shizukuApp,
        'running': running,
        'granted': granted,
        'provider': provider,
      },
      'root': {'checked': false, 'available': null, 'connected': false, 'starting': false, 'reasonCode': null, ...root},
      'privileged': {
        'v': 1,
        'mode': mode,
        'ready': ready,
        'reason': reason,
        'supportedModes': const ['off', 'shizuku', 'sui', 'root', 'adb'],
        'recommendedMode': recommended,
        'grantPath': grantPath,
        'rootSelected': rootSelected ?? mode == 'root',
        'keep': ?keep,
      },
    },
  };
}

Map<String, Object?> defaultPolicies() => {
  'denyPackages': ['com.eg.android.AlipayGphone', 'com.unionpay', 'cmb.pb', 'com.icbc'],
  'confirmEveryWritePackages': ['com.tencent.mm'],
};

/// Fixed past times so goldens don't depend on today's date.
List<Map<String, Object?>> sampleLog() => [
  {
    'time': DateTime(2025, 10, 20, 14, 6).millisecondsSinceEpoch,
    'tool': 'tap',
    'app': '高德地图',
    'summary': '点「路线」',
    'decision': 'allowed',
  },
  {
    'time': DateTime(2025, 10, 20, 14, 5).millisecondsSinceEpoch,
    'tool': 'mcp__phone__type',
    'app': '微信',
    'summary': '给 张三 发送：“晚上见”',
    'decision': 'confirmed',
  },
  {
    'time': DateTime(2025, 10, 20, 14, 2).millisecondsSinceEpoch,
    'tool': 'open',
    'app': '支付宝',
    'summary': '打开「支付宝」',
    'decision': 'refused:deny-list',
  },
  {
    'time': DateTime(2025, 10, 20, 13, 58).millisecondsSinceEpoch,
    'tool': 'screen',
    'app': '京东',
    'summary': '',
    'decision': 'ok',
  },
];

const sampleScreenText =
    '屏幕 s7 · 京东 · 我的订单\n'
    '[1] 按钮 返回\n'
    '[2] 标签 全部 · 待付款 · 待收货\n'
    '[3] 列表 订单\n'
    '  [4] 文字 小米充电器 67W ¥89.00 已签收\n'
    '  [5] 文字 抽纸 3 层 24 包 ¥39.90 运输中';

class FakePhoneNative {
  FakePhoneNative({Map<String, Object?>? status, Map<String, Object?>? policies, List<Map<String, Object?>>? log})
    : status = status ?? phoneStatus(),
      policies = policies ?? defaultPolicies(),
      log = log ?? sampleLog();

  Map<String, Object?> status;
  Map<String, Object?> policies;
  List<Map<String, Object?>> log;
  Map<String, Object?> screen = {'ok': true, 'text': sampleScreenText};

  /// Optional barriers for settings writes and their subsequent real channel readback.
  Future<Map<String, Object?>?> Function()? onStatus;
  Future<Map<String, Object?>> Function(Map<String, Object?>)? onSetBackgroundParallelLimit;

  /// Reply of `setEnabled` / `setPolicies`.
  bool accept = true;

  Future<Map<String, Object?>?> Function()? onGetPolicies;
  Future<bool> Function(Map<String, Object?>)? onSetPolicies;

  /// Reply of `finishTask`; null: closed, and back in the app exactly when asked to reopen.
  Map<String, Object?>? finish;

  /// Runs when `finishTask` comes in (what the app coming up would do).
  void Function()? onFinish;

  /// Private engine-approval UI; production PhoneChannel still encodes/parses.
  Future<Map<String, Object?>> Function(Map<String, Object?>)? onPresentPrompt;

  /// Gate cleanup's asynchronous native response, without rerunning a probe.
  Future<bool> Function(String)? onAcknowledgeInterruption;
  Future<bool> Function()? onRetryInterruption;

  /// The 悬浮条 settings as the native side keeps them.
  Map<String, Object?> overlay = {'idleOpacity': 0.7, 'autoCollapse': false};

  /// Whether the phone has its own island (`systemIsland`): none by default.
  Map<String, Object?> systemIsland = {'vendor': false, 'shows': false};

  /// Replies for `{ok, reason}` methods, by method name (default ok).
  final results = <String, Map<String, Object?>>{};

  bool learn = true;
  final skills = <String, Map<String, Object?>>{};
  final drafts = <String, Map<String, Object?>>{};
  final legacy = <String, Map<String, Object?>>{};
  final archived = <String>{};

  final calls = <MethodCall>[];
  MockStreamHandlerEventSink? _sink;

  List<String> get methods => [for (final c in calls) c.method];

  Iterable<MethodCall> callsOf(String method) => calls.where((c) => c.method == method);

  TestDefaultBinaryMessenger get _messenger => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void install() {
    _messenger.setMockMethodCallHandler(phoneMethods, _handle);
    _messenger.setMockStreamHandler(
      phoneEvents,
      MockStreamHandler.inline(
        // Block bodies: an arrow would return the sink, which the mock then tries to encode.
        onListen: (_, sink) {
          _sink = sink;
        },
        onCancel: (_) {
          _sink = null;
        },
      ),
    );
    addTearDown(uninstall);
  }

  void uninstall() {
    _messenger.setMockMethodCallHandler(phoneMethods, null);
    // A provider can outlive the fake by a frame at teardown and cancel its event stream
    // then: leave a quiet handler rather than none (removePhoneNative removes it outright).
    _messenger.setMockStreamHandler(
      phoneEvents,
      MockStreamHandler.inline(onListen: (_, _) {}, onCancel: (_) {}),
    );
  }

  bool get listening => _sink != null;

  /// Pushes a status event, as the native side does on every change.
  void push(Map<String, Object?> next) {
    status = next;
    _sink?.success(next);
  }

  /// A domain event shares the native sink without replacing the latest status snapshot.
  void pushSkill(Map<String, Object?> event) => _sink?.success(event);

  Map<String, Object?> get _background => (status['background'] as Map).cast<String, Object?>();

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    final args = call.arguments is Map ? (call.arguments as Map).cast<String, Object?>() : const <String, Object?>{};
    if (call.method.startsWith('skills.')) return _skill(call.method, args);
    switch (call.method) {
      case 'status':
        return onStatus?.call() ?? status;
      case 'setEnabled':
        if (accept) status = {...status, 'enabled': args['enabled']};
        return accept;
      case 'openAccessibilitySettings' || 'openAppDetails' || 'stopTask' || 'resumeTask' || 'retryTaskCleanup':
        return true;
      case 'acknowledgeTaskInterruption':
        return onAcknowledgeInterruption?.call(args['batchToken'] as String) ?? false;
      case 'retryTaskInterruptionStorage':
        return onRetryInterruption?.call() ?? false;
      case 'testScreen':
        return screen;
      case 'setBackgroundViewport':
        final viewportResult = results[call.method] ?? {'ok': true};
        if (viewportResult['ok'] == true) {
          status = {...status, 'background': {..._background, 'viewport': {'v': 1, 'preset': args['preset']}}};
        }
        return viewportResult;
      case 'setBackgroundParallelLimit':
        if (onSetBackgroundParallelLimit != null) return onSetBackgroundParallelLimit!(args);
        final capacityResult = results[call.method] ?? {'ok': true};
        if (capacityResult['ok'] == true) {
          final old = (_background['parallelism'] as Map).cast<String, Object?>();
          final limit = args['limit'] as int;
          final current = old['effectiveLimit'] as int;
          status = {...status, 'background': {..._background, 'parallelism': {
            ...old, 'configuredLimit': limit, 'effectiveLimit': current > limit ? limit : current,
          }}};
        }
        return capacityResult;
      case 'setBackgroundMode':
        final r = results[call.method] ?? {'ok': true};
        if (r['ok'] == true) {
          final mode = args['mode'];
          status = {
            ...status,
            'background': {
              ..._background,
              'mode': mode,
              if (_background['privileged'] case final Map privileged)
                'privileged': {...privileged, 'mode': mode, 'ready': mode != 'off', 'reason': null},
            },
          };
        }
        return r;
      case 'requestShizukuPermission':
        return true;
      case 'adbStartPairing' || 'adbPair' || 'adbConnect' || 'prepareRoot':
        return results[call.method] ?? {'ok': true};
      case 'grantSecureSettings':
        final result = results[call.method] ?? {'ok': true};
        if (result['ok'] == true) {
          status = {
            ...status,
            'a11yKeeper': {...?(status['a11yKeeper'] as Map?), 'granted': true, 'path': 'granted'},
          };
        }
        return result;
      case 'getPolicies':
        return onGetPolicies != null ? onGetPolicies!() : policies;
      case 'setPolicies':
        if (onSetPolicies != null) return onSetPolicies!(args);
        // As natively: what isn't sent stays, inside `unlocks` too.
        if (accept) {
          final unlocks = args['unlocks'];
          policies = {
            ...policies,
            ...args,
            if (unlocks is Map) 'unlocks': {...?(policies['unlocks'] as Map?)?.cast<String, Object?>(), ...unlocks},
          };
        }
        return accept;
      case 'actionLog':
        return log;
      case 'overlayPrefs':
        return overlay;
      case 'setOverlayPrefs':
        overlay = {...overlay, ...args};
        return overlay;
      case 'systemIsland':
        return systemIsland;
      case 'setPhoneThought':
        return true;
      case 'finishTask':
        onFinish?.call();
        final reopen = args['reopen'] == true;
        return finish ?? {'closed': true, 'busy': false, 'opened': reopen, 'launched': reopen};
      case 'presentPrompt':
        return onPresentPrompt?.call(args) ?? {'decision': 'unavailable', 'presented': 'none'};
      case 'cancelPrompt':
        return true;
    }
    throw MissingPluginException(call.method);
  }

  Map<String, Object?> _skill(String method, Map<String, Object?> args) {
    // Tests supply exact native mutation replies (including validated body, archive, and diff)
    // without reproducing the native file format and state machine in the test double.
    final result = results[method];
    if (result?.containsKey('error') == true) return result!;
    final name = args['name'] as String?;
    final id = args['draftId'] as String?;
    switch (method) {
      case 'skills.list':
        return result ?? {'learn': learn, 'skills': skills.values.toList(), 'drafts': drafts.values.toList(),
          'legacy': legacy.values.toList(), 'archived': archived.toList()};
      case 'skills.get':
        return result ?? skills[name] ?? {'error': 'changed', 'detail': 'Unknown skill.'};
      case 'skills.setLearn':
        learn = (result?['learn'] ?? args['on']) as bool;
        return {'learn': learn};
      case 'skills.discard':
        drafts.remove(id);
        return {};
      case 'skills.delete':
        if (skills.remove(name) != null) archived.add(name!);
        legacy.remove(name);
        return {};
      case 'skills.accept' || 'skills.save' || 'skills.setEnabled' || 'skills.restore':
        if (result == null) return {'error': 'changed', 'detail': 'No skill result configured.'};
        final savedName = result['name'] as String;
        skills[savedName] = result;
        if (method == 'skills.accept') drafts.remove(id);
        if (method == 'skills.restore') archived.remove(savedName);
        return result;
      default:
        throw MissingPluginException(method);
    }
  }

}

/// Acts as a build without the native module: every call fails with
/// MissingPluginException. (Leaving the channel unhandled would hang inside
/// testWidgets' fake async zone instead.)
void removePhoneNative() {
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(phoneMethods, (call) async => throw MissingPluginException(call.method));
  addTearDown(() => m.setMockMethodCallHandler(phoneMethods, null));
}

class PhoneTestRuntime extends LocalRuntimeController {
  PhoneTestRuntime(this.initial);

  final LocalRuntimeState initial;
  final starts = <String>[];
  int stops = 0;

  @override
  LocalRuntimeState build() => initial;

  @override
  Future<void> install() async {}

  @override
  Future<void> start() async {
    starts.add('start');
    state = state.copyWith(status: _with(RuntimePhase.running));
  }

  @override
  Future<void> startIn(EngineMode mode) async => starts.add(mode.name);

  @override
  Future<void> stop() async {
    stops++;
    state = state.copyWith(status: _with(RuntimePhase.installed));
  }

  RuntimeStatus _with(RuntimePhase phase) {
    final s = state.status;
    return RuntimeStatus(
      phase: phase,
      dshVersion: s.dshVersion,
      baseUrl: s.baseUrl,
      token: s.token,
      mode: s.mode,
      safeState: s.safeState,
    );
  }
}

const runningRuntime = RuntimeStatus(
  phase: RuntimePhase.running,
  dshVersion: '0.2.1-rc.2',
  baseUrl: 'http://127.0.0.1:3080',
  token: 't',
);

const safeRuntime = RuntimeStatus(
  phase: RuntimePhase.running,
  dshVersion: '0.2.1-rc.2',
  baseUrl: 'http://127.0.0.1:3080',
  token: 't',
  mode: EngineMode.safe,
  safeState: SafeModeState.on,
  safeReason: 'manual',
);

class FixedActiveHost extends ActiveHostController {
  FixedActiveHost(this.host);

  final HostRef host;

  @override
  HostRef build() => host;
}

class FixedHosts extends HostsController {
  @override
  HostsState build() => const HostsState(
    loaded: true,
    ssh: [
      SshHostConfig(
        id: 'lab',
        name: '实验室服务器',
        host: 'lab.example.com',
        port: 22,
        user: 'root',
        auth: SshAuthMethod.privateKey,
      ),
    ],
  );
}
