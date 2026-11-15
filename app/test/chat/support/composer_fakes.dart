// Fakes for the composer's `@` references and voice input: an RPC carrier
// that answers like DSH 0.2.1-rc.2 did against a throwaway `dsh web`
// (`fileReferences/list`, `sessionReferenceResolver/candidates`,
// `session/list`, `speech/*`), and a scripted voice bridge.

import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:dsh_client/dsh_client.dart';

typedef RpcHandler = Object? Function(Map<String, Object?> args);

/// Answers unary calls from [handlers]; anything else is a 404, as the HTTP
/// carrier reports an endpoint the Host does not serve.
class FakeRpcCarrier extends DshCarrier {
  FakeRpcCarrier(this.handlers);

  final Map<String, RpcHandler> handlers;
  final calls = <(String, Map<String, Object?>)>[];

  List<Map<String, Object?>> argsOf(String endpoint) => [
    for (final (e, a) in calls)
      if (e == endpoint) a,
  ];

  @override
  String get kind => 'fake';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    final handler = handlers[endpoint];
    if (handler == null) {
      throw DshHttpException(404, 'endpoint $endpoint is not served by this Host');
    }
    return RpcOk(handler(args));
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => Future.error(const DshTransportException('no mux in tests'));

  @override
  Future<void> close() async {}
}

/// The workspace of the reference fixtures.
const fakeCwd = '/root/shop';

/// A host with a small workspace and a few conversations; `main` is the
/// open one, `child` its subagent.
FakeRpcCarrier referenceHost({DateTime? now}) {
  final t = now ?? DateTime(2026, 10, 24, 12);
  int ago(Duration d) => t.subtract(d).millisecondsSinceEpoch;
  const files = [
    {'path': 'README.md', 'kind': 'file'},
    {'path': 'lib', 'kind': 'directory'},
    {'path': 'lib/main.dart', 'kind': 'file'},
    {'path': 'lib/ui', 'kind': 'directory'},
    {'path': 'lib/ui/login page.dart', 'kind': 'file'},
    {'path': 'docs/guide.md', 'kind': 'file'},
  ];
  final sessions = <Map<String, Object?>>[
    {
      'sessionId': 'login',
      'label': '修复登录重复提交',
      'sameWorkspace': true,
      'cwd': fakeCwd,
      'createdAt': ago(const Duration(days: 2)),
      'mention': formatSessionMention('login', '修复登录重复提交'),
    },
    {
      'sessionId': 'child',
      'label': 'child',
      'displayTitle': '检查依赖',
      'sameWorkspace': true,
      'cwd': fakeCwd,
      'createdAt': ago(const Duration(minutes: 20)),
      'mention': formatSessionMention('child', '检查依赖'),
    },
    {
      'sessionId': 'notes',
      'label': '周报草稿',
      'sameWorkspace': false,
      'cwd': '/root/notes',
      'createdAt': ago(const Duration(days: 40)),
      'mention': formatSessionMention('notes', '周报草稿'),
    },
  ];
  Map<String, Object?> summary(String id, Duration age, {String? parent, String? origin, String cwd = fakeCwd}) => {
    'sessionId': id,
    'updatedAt': ago(age),
    'running': false,
    'blank': false,
    'agentAvailable': true,
    'cwd': cwd,
    'parentSessionId': ?parent,
    'origin': ?origin,
  };
  return FakeRpcCarrier({
    'fileReferences/list': (args) {
      final q = (args['query'] as String?) ?? '';
      final slash = q.lastIndexOf('/');
      if (q.isEmpty || slash >= 0) {
        final dir = slash < 0 ? '' : q.substring(0, slash);
        final rest = slash < 0 ? '' : q.substring(slash + 1);
        return [
          for (final f in files)
            if (_parent(f['path']!) == dir && f['path']!.split('/').last.startsWith(rest)) f,
        ];
      }
      return [
        for (final f in files)
          if (f['path']!.toLowerCase().contains(q.toLowerCase())) f,
      ];
    },
    'sessionReferenceResolver/candidates': (args) {
      final q = ((args['query'] as String?) ?? '').toLowerCase();
      return [
        for (final s in sessions)
          if (q.isEmpty ||
              (s['label'] as String).toLowerCase().contains(q) ||
              ((s['displayTitle'] as String?) ?? '').toLowerCase().contains(q) ||
              (s['sessionId'] as String).contains(q))
            s,
      ];
    },
    'session/list': (_) => {
      'items': [
        summary('main', const Duration(minutes: 1)),
        summary('login', const Duration(hours: 3)),
        summary('child', const Duration(minutes: 5), parent: 'main', origin: 'subagent'),
        summary('notes', const Duration(days: 40), cwd: '/root/notes'),
      ],
    },
  });
}

String _parent(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.substring(0, slash);
}

/// A voice bridge driven by the test.
class FakeVoiceBridge implements VoiceBridge {
  FakeVoiceBridge({
    this.caps = const VoiceCapabilities(recognizer: true, recorder: true),
    this.permission = VoicePermission.granted,
  });

  VoiceCapabilities caps;
  VoicePermission permission;

  /// What `stop` returns in recorder mode.
  Uint8List? recording;

  final calls = <String>[];
  final _events = StreamController<VoiceEvent>.broadcast();

  void emit(VoiceEvent event) => _events.add(event);

  @override
  Future<VoiceCapabilities> capabilities() async => caps;

  @override
  Future<VoicePermission> requestPermission() async {
    calls.add('permission');
    return permission;
  }

  @override
  Future<void> openSettings() async => calls.add('settings');

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  Future<void> startRecognizer({String? language}) async => calls.add('recognizer');

  @override
  Future<void> startRecorder({required int maxSeconds}) async => calls.add('recorder:$maxSeconds');

  /// 「内置模型」：默认不可用，测试按需打开。
  bool offlineReady = false;
  String offlineText = '';

  @override
  Future<VoiceOfflineStatus> offlineStatus() async =>
      VoiceOfflineStatus(ready: offlineReady);

  @override
  Future<void> prepareOffline() async => calls.add('prepareOffline');

  @override
  Future<void> startOffline({required int maxSeconds}) async => calls.add('offline:$maxSeconds');

  @override
  Future<String> stopOffline() async {
    calls.add('stopOffline');
    return offlineText;
  }

  @override
  Future<Uint8List?> stop() async {
    calls.add('stop');
    return recording;
  }

  @override
  Future<void> cancel() async => calls.add('cancel');
}

/// A canonical 16 kHz mono PCM16 WAV of [seconds] of silence.
Uint8List silentWav(double seconds) {
  final samples = (seconds * 16000).round();
  final data = samples * 2;
  final bytes = ByteData(44 + data);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + data, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, 16000, Endian.little);
  bytes.setUint32(28, 32000, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, data, Endian.little);
  return bytes.buffer.asUint8List();
}

/// `speech/catalog` with SenseVoice ready, as the voice-input bundle serves it.
Map<String, Object?> readySpeechCatalog({String phase = 'standby'}) => {
  'providers': [
    {
      'id': 'sensevoice-local',
      'name': 'SenseVoice',
      'location': 'host-local',
      'languages': ['auto', 'zh', 'en'],
      'preparation': {'phase': phase},
    },
  ],
  'selection': {'providerId': 'sensevoice-local', 'language': 'auto'},
  'maxAudioBytes': 4 * 1024 * 1024,
  'maxDurationSeconds': 120,
};
