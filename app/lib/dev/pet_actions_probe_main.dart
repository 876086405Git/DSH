// Debug-only entry: real native overlay -> Dart actions -> loopback HTTP/mux.
// No live engine, credentials, model downloads or paid requests. See
// docs/testing/pet-actions-probe.md. Test fixtures are deliberately reused only
// by this dev entry; neither production main nor the native plugin imports it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pet_probe_support.dart';
import '../l10n/l10n.dart';
import '../pets/overlay_channel.dart';
import '../pets/pet_mood.dart';
import '../pets/pet_overlay_bridge.dart';
import '../pets/pet_signals.dart';
import '../pets/pet_state.dart';
import '../state/connection_state.dart';
import '../state/hosts_state.dart';
import '../state/notify_state.dart';
import '../state/sessions_state.dart';
import '../state/voice_state.dart';
import '../ui/chat/voice/voice_bridge.dart';

const probeHost = HostRef.ssh('pet-probe');
const probeSession = 'probe-existing';
const probeTranscript = 'probe voice words';
final probePetProvider = NotifierProvider<ProbePetController, PetState>(ProbePetController.new);

class ProbePetController extends Notifier<PetState> {
  @override
  PetState build() =>
      const PetState(packId: 'whale-girl', foreground: false, target: PetTarget(probeHost, probeSession));

  void show(PetEvent event) {
    state = PetState(
      packId: 'whale-girl',
      foreground: false,
      active: true,
      state: PetStateName.notification,
      target: event.target,
      bubble: PetBubble(
        id: event.key,
        kind: event.bubbleKind!,
        target: event.target,
        until: DateTime.now().add(const Duration(minutes: 2)),
        title: event.title,
        ask: event.ask,
      ),
    );
  }

  void idle() => state = build();
}

class _ProbeHost extends ActiveHostController {
  @override
  HostRef build() => probeHost;
}

class _ProbeLocal extends LocalConnectionController {
  _ProbeLocal(this.connection);
  final HostConnection connection;
  @override
  Future<HostConnection?> build() async => connection;
}

class _ProbeSessions extends SessionsController {
  _ProbeSessions(this.client);
  final DshClient client;
  @override
  Future<List<SessionSummary>> build() async => [session(probeSession, title: 'Pet probe')];
  @override
  Future<String> create({bool autoApprove = true}) async => (await client.createSession(cwd: '/probe')).sessionId;
}

/// Observes the real MethodChannel handler; never supplies a fake success.
class _ObservedOverlay extends PetOverlayChannel {
  _ObservedOverlay(this.log);
  final void Function(String, Map<String, Object?>) log;
  @override
  void setActionHandler(Future<Object?> Function(MethodCall)? handler) {
    super.setActionHandler(
      handler == null
          ? null
          : (call) async {
              log('native-action', {'method': call.method});
              final result = await handler(call);
              log('native-result', {'method': call.method, 'result': result});
              return result;
            },
    );
  }
}

/// Only the foreground fallback recorder is scripted. Native overlay recording
/// remains native. The fallback still uses PetVoiceDialog/VoiceInputController
/// and speech/transcribe over HTTP, with a canonical one-second PCM WAV.
class _FallbackRecorder implements VoiceBridge {
  _FallbackRecorder(this.log);
  final void Function(String, Map<String, Object?>) log;
  final _events = StreamController<VoiceEvent>.broadcast();
  Timer? _limit;
  @override
  Stream<VoiceEvent> get events => _events.stream;
  @override
  Future<VoiceCapabilities> capabilities() async => const VoiceCapabilities(recognizer: false, recorder: true);
  @override
  Future<VoicePermission> requestPermission() async => VoicePermission.granted;
  @override
  Future<void> openSettings() async {}
  @override
  Future<void> startRecognizer({String? language}) async => throw UnsupportedError('No system recognizer fixture');
  // 「内置模型」不在这个探针的覆盖范围里：它只脚本化前台回退录音。
  @override
  Future<VoiceOfflineStatus> offlineStatus() async => const VoiceOfflineStatus(ready: false);
  @override
  Future<void> prepareOffline() async => throw UnsupportedError('No bundled model fixture');
  @override
  Future<void> startOffline({required int maxSeconds}) async =>
      throw UnsupportedError('No bundled model fixture');
  @override
  Future<String> stopOffline() async => throw UnsupportedError('No bundled model fixture');
  @override
  Future<void> startRecorder({required int maxSeconds}) async {
    log('fallback-recorder', {'fixture': 'one-second PCM16 WAV'});
    _limit?.cancel();
    _limit = Timer(const Duration(milliseconds: 500), () => _events.add(const VoiceLimit()));
  }

  @override
  Future<Uint8List?> stop() async {
    _limit?.cancel();
    return silentWav(1);
  }

  @override
  Future<void> cancel() async => _limit?.cancel();
  Future<void> close() async {
    _limit?.cancel();
    await _events.close();
  }
}

class PetActionsProbe {
  PetActionsProbe._(this.server);
  final FakeDsh server;
  late final DshClient client;
  late final ProviderContainer container;
  late final _FallbackRecorder _recorder;
  final lines = ValueNotifier<List<Map<String, Object?>>>([]);
  final source = FakeAlertSource()..sessions = [session(probeSession, title: 'Pet probe')];
  final silentLocalSource = FakeAlertSource();
  final notifications = FakeNotifyChannel();
  StreamSubscription<HostEvent>? _hostEvents;
  StreamSubscription<PetEvent>? _petEvents;
  HttpServer? _control;
  int _serial = 0;
  int _created = 0;
  Map<String, Object?>? lastRequest;

  void log(String kind, [Map<String, Object?> data = const {}]) {
    final line = <String, Object?>{...data, if (data.containsKey('kind')) 'requestKind': data['kind'], 'kind': kind};
    debugPrint('[pet-actions-probe] ${jsonEncode(line)}');
    lines.value = [...lines.value, line];
  }

  static Future<PetActionsProbe> start({int? controlPort}) async {
    if (!kDebugMode) throw StateError('Pet actions probe requires a debug build');
    // This debug-only acceptance entry must not replace the user's persisted Dart settings.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    final p = PetActionsProbe._(await FakeDsh.start());
    p._configureServer();
    final connection = DshConnection(p.server.baseUri);
    await connection.login(FakeDsh.token);
    p.client = await DshClient.connectCarrier(DshHttpCarrier(connection));
    p._recorder = _FallbackRecorder(p.log);
    final remote = HostConnection(
      client: p.client,
      label: 'Pet probe',
      isLocal: false,
      kind: HostKind.ssh,
      hostId: 'pet-probe',
    );
    final local = HostConnection(client: p.client, label: 'Voice fixture', isLocal: true);
    p.container = ProviderContainer(
      overrides: [
        activeHostProvider.overrideWith(_ProbeHost.new),
        activeConnectionProvider.overrideWithValue(AsyncData(remote)),
        localConnectionProvider.overrideWith(() => _ProbeLocal(local)),
        sessionsProvider.overrideWith(() => _ProbeSessions(p.client)),
        petStateProvider.overrideWith((ref) => ref.watch(probePetProvider)),
        petOnScreenProvider.overrideWithValue(true),
        notifyChannelProvider.overrideWithValue(p.notifications),
        alertSourceFactoryProvider.overrideWithValue((c) => c.isLocal ? p.silentLocalSource : p.source),
        alertTimingProvider.overrideWithValue((announce: Duration.zero, reconcile: const Duration(milliseconds: 30))),
        petOverlayChannelProvider.overrideWithValue(_ObservedOverlay(p.log)),
        voiceBridgeProvider.overrideWithValue(p._recorder),
      ],
    );
    p._hostEvents = p.client.hostEvents.listen(p.source.emit);
    p._petEvents = p.container.read(petEventBusProvider).events.listen((event) {
      if (event.host != probeHost || event.ask == null) return;
      p.container.read(probePetProvider.notifier).show(event);
      p.lastRequest = {
        'host': event.host.encode(),
        'sessionId': event.sessionId,
        ...event.ask!.toMap(event.bubbleKind!),
      };
      p.log('bubble-ready', p.lastRequest!);
    });
    await p.container.read(localConnectionProvider.future);
    await p.container.read(sessionsProvider.future);
    p.container.listen(chatAlertsProvider, (_, _) {});
    p.container.read(appForegroundProvider.notifier).set(false);
    if (controlPort != null) {
      p._control = await HttpServer.bind(InternetAddress.loopbackIPv4, controlPort);
      p._control!.listen(p._controlRequest);
    }
    p.log('ready', {'http': p.server.baseUri.toString(), 'controlPort': p._control?.port});
    return p;
  }

  void _configureServer() {
    void handle(String endpoint, Map<String, Object?> Function(Map<String, Object?>) body) {
      server.handlers[endpoint] = (args) {
        if (endpoint != 'speech/catalog') {
          log('rpc', {'endpoint': endpoint, if (endpoint != 'speech/transcribe') 'args': args});
        }
        return body(args);
      };
    }

    handle(
      'session/list',
      (_) => {
        'ok': true,
        'value': {'items': <Object?>[]},
      },
    );
    handle(
      'session/create',
      (_) => {
        'ok': true,
        'value': {'sessionId': 'probe-new-${++_created}'},
      },
    );
    handle('session/prompt', (_) => {'ok': true});
    handle(
      'session/page',
      (_) => {
        'ok': true,
        'value': {'records': <Object?>[], 'hasMore': false},
      },
    );
    handle(r'$events/result', (args) {
      scheduleMicrotask(() {
        for (final socket in server.sockets) {
          if (socket.eventsStreamId != null) socket.event({'type': 'cancel', 'eventId': args['eventId']});
        }
        container.read(probePetProvider.notifier).idle();
      });
      return {'ok': true};
    });
    handle('speech/catalog', (_) => {'ok': true, 'value': readySpeechCatalog()});
    handle('speech/transcribe', (args) {
      final request = (args['request']! as Map);
      final bytes = base64Decode(request['audioBase64']! as String);
      final valid =
          bytes.length >= 9644 &&
          ascii.decode(bytes.take(4).toList()) == 'RIFF' &&
          request['providerId'] == 'sensevoice-local';
      log('speech', {
        'bytes': bytes.length,
        'providerId': request['providerId'],
        'valid': valid,
        'text': probeTranscript,
      });
      return valid
          ? {
              'ok': true,
              'value': {'text': probeTranscript, 'audioSeconds': 1},
            }
          : {
              'ok': false,
              'error': {'code': 'probe/invalid-audio', 'message': 'Expected PCM WAV and local provider'},
            };
    });
    server.onOpen = (socket, id, endpoint, payload) {
      log('stream', {'endpoint': endpoint});
      if (endpoint != 'session/follow') return;
      final request = (payload['args'] as Map?)?['request'] as Map?;
      socket.item(id, {
        'type': 'snapshot',
        'header': {'id': request?['sessionId'] ?? probeSession},
        'cursor': -1,
        'records': <Object?>[],
        'hasMore': false,
        'projections': {'asOfSeq': -1, 'values': <String, Object?>{}},
        'running': false,
      });
    };
  }

  String seed(String kind) {
    if (kind != 'approval' && kind != 'question') throw ArgumentError.value(kind);
    final id = 'probe-$kind-${++_serial}';
    final callId = 'call-$_serial';
    source.approvalCalls[callId] = ToolCallPart(id: callId, name: 'bash', arguments: '{"command":"printf pet-probe"}');
    final frame = <String, Object?>{
      'type': 'waterfall',
      'eventId': id,
      'agentId': probeSession,
      'event': kind == 'approval' ? 'approval/request' : 'user-questions/request',
      'request': kind == 'approval'
          ? {'toolName': 'bash', 'callId': callId}
          : {
              'questions': [
                {
                  'id': 'color',
                  'question': 'Pick a color',
                  'options': [
                    {'label': 'Blue'},
                    {'label': 'Red'},
                  ],
                },
              ],
            },
    };
    for (final socket in server.sockets) {
      if (socket.eventsStreamId != null) socket.event(frame);
    }
    log('seed', {'eventId': id, 'requestKind': kind});
    return id;
  }

  Map<String, Object?> get snapshot => {
    'fixture': 'dsh-pet-actions-probe-v1',
    'ready': client.mux.generation != null,
    'lastRequest': lastRequest,
    'events': lines.value,
    'promptCount': server.rpcCalls.where((c) => c['method'] == 'session/prompt').length,
    'answerCount': server.rpcCalls.where((c) => c['method'] == r'$events/result').length,
    'speechCount': server.rpcCalls.where((c) => c['method'] == 'speech/transcribe').length,
  };

  Future<void> _controlRequest(HttpRequest request) async {
    request.response.headers.contentType = ContentType.json;
    try {
      if (request.method == 'GET' && request.uri.path == '/state') {
        request.response.write(jsonEncode(snapshot));
      } else if (request.method == 'POST' && {'/approval', '/question'}.contains(request.uri.path)) {
        request.response.write(jsonEncode({'eventId': seed(request.uri.path.substring(1))}));
      } else {
        request.response.statusCode = 404;
      }
    } on Object catch (error) {
      request.response.statusCode = 500;
      request.response.write(jsonEncode({'error': error.toString()}));
    } finally {
      await request.response.close();
    }
  }

  Future<void> close() async {
    await _control?.close(force: true);
    container.dispose();
    await _hostEvents?.cancel();
    await _petEvents?.cancel();
    await _recorder.close();
    await notifications.actionController.close();
    await notifications.tapController.close();
    await client.close();
    await server.close();
    lines.dispose();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLocale.use(AppLocale.zhCN);
  final probe = await PetActionsProbe.start(
    controlPort: const int.fromEnvironment('PET_PROBE_PORT', defaultValue: 38080),
  );
  runApp(
    UncontrolledProviderScope(
      container: probe.container,
      child: MaterialApp(
        locale: AppLocale.zhCN,
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: AppLocale.supported,
        home: Scaffold(
          appBar: AppBar(title: const Text('Pet actions probe — local fixture')),
          body: SafeArea(
            child: Column(
              children: [
                const PetOverlayBridge(),
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('原生浮窗动作 → 真实 Dart / HTTP / mux。语音固定回填 probe voice words；不会调用模型或自动发送。'),
                ),
                Wrap(
                  children: [
                    TextButton(onPressed: () => probe.seed('approval'), child: const Text('Seed approval')),
                    TextButton(onPressed: () => probe.seed('question'), child: const Text('Seed question')),
                  ],
                ),
                Expanded(
                  child: ValueListenableBuilder<List<Map<String, Object?>>>(
                    valueListenable: probe.lines,
                    builder: (_, lines, _) => ListView(
                      children: [
                        for (final line in lines)
                          SelectableText(
                            jsonEncode(line),
                            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
