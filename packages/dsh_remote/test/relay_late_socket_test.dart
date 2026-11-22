// Default connector, real loopback upgrades and real WebSocket close frames.
// The original connect deadline is fired explicitly; no wall-clock delay.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

const _deadline = Duration(seconds: 10);
const _watchdog = Duration(seconds: 5);

class _Deadline implements Timer {
  _Deadline(this.callback);
  final void Function() callback;
  bool active = true;
  int ticks = 0;

  void fire() {
    expect(active, isTrue);
    active = false;
    ticks++;
    callback();
  }

  @override
  void cancel() => active = false;
  @override
  bool get isActive => active;
  @override
  int get tick => ticks;
}

// Observe close invocation without replacing its effects or inferring them
// from readyState, which dart:io updates asynchronously. Every operation is
// delegated to the WebSocket actually created by the default connector.
class _ObservedSocket extends Stream<dynamic> implements WebSocket {
  _ObservedSocket(this.socket);
  final WebSocket socket;
  int closeCalls = 0;
  Future<dynamic>? closing;

  @override
  Future<dynamic> close([int? code, String? reason]) {
    closeCalls++;
    return closing = socket.close(code, reason);
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => socket.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  void add(dynamic data) => socket.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) => socket.addError(error, stackTrace);
  @override
  Future<dynamic> addStream(Stream<dynamic> stream) => socket.addStream(stream);
  @override
  void addUtf8Text(List<int> bytes) => socket.addUtf8Text(bytes);
  @override
  Future<dynamic> get done => socket.done;
  @override
  int? get closeCode => socket.closeCode;
  @override
  String? get closeReason => socket.closeReason;
  @override
  String get extensions => socket.extensions;
  @override
  String? get protocol => socket.protocol;
  @override
  int get readyState => socket.readyState;
  @override
  Duration? get pingInterval => socket.pingInterval;
  @override
  set pingInterval(Duration? value) => socket.pingInterval = value;
}

class _ConnectObservation {
  final deadlines = <_Deadline>[];
  final known = Set<WebSocket>.identity();
  final consumed = Completer<_ObservedSocket>();
  bool expired = false;
  _ObservedSocket? lateSocket;

  Future<V> run<V>(Future<V> Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        if (duration != _deadline) return parent.createTimer(zone, duration, callback);
        final timer = _Deadline(callback);
        deadlines.add(timer);
        return timer;
      },
      registerUnaryCallback: <R, T>(self, parent, zone, R Function(T) callback) {
        return parent.registerUnaryCallback<R, T>(zone, (T value) {
          if (value is! WebSocket || value is _ObservedSocket || !known.add(value)) return callback(value);
          if (!expired) return callback(value);
          final observed = lateSocket = _ObservedSocket(value);
          try {
            return callback(observed as T);
          } finally {
            // The source Future's value handler has now run. Do not inspect
            // the socket before the product gets its chance to retire it.
            if (!consumed.isCompleted) consumed.complete(observed);
          }
        });
      },
    ),
  );

  void expireConnector({required bool attach}) {
    expired = true;
    // The data-ready deadline is installed after its connector deadline. This
    // regression still expires the connector and observes its late source value.
    deadlines[deadlines.length - (attach ? 2 : 1)].fire();
  }
}

String _frame(String type, Map<String, Object?> payload) => jsonEncode(ControlFrame(type, payload).toJson());

class _Server {
  _Server(this.http, {required this.attach, required this.holdControl});
  final HttpServer http;
  final bool attach;
  final bool holdControl;
  final held = Completer<HttpRequest>();
  final sockets = <WebSocket>[];

  Uri get url => Uri.parse('ws://127.0.0.1:${http.port}/control');

  static Future<_Server> start({required bool attach, required bool holdControl}) async {
    final fixture = _Server(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      attach: attach,
      holdControl: holdControl,
    );
    fixture.http.listen((request) {
      if (fixture.holdControl || request.uri.path == '/data') {
        fixture.held.complete(request);
      } else {
        unawaited(fixture.acceptControl(request));
      }
    });
    return fixture;
  }

  Future<WebSocket> upgrade(HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    sockets.add(socket);
    return socket;
  }

  Future<void> acceptControl(HttpRequest request) async {
    final socket = await upgrade(request);
    socket.listen((raw) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      switch (frame['type']) {
        case 'hello':
          socket.add(
            _frame('hello.ack', {
              'protocol': 1,
              'serverVersion': 'test',
              'connectionSessionId': 'control-session',
              'heartbeatIntervalMs': 25000,
              'maxControlFrameBytes': 65536,
              'maxRelayFrameBytes': 262144,
              'capabilities': ['transport.relay', 'transport.relay.attach'],
            }),
          );
        case 'connect.request':
          socket.add(
            _frame('connect.accepted', {
              'connectionId': 'connection',
              if (attach) ...{
                'relayEndpoint': url.replace(path: '/data').toString(),
                'relayTicket': 'test-ticket',
                'relayNodeId': 'node',
                'relayEpoch': 1,
              },
            }),
          );
      }
    });
  }

  Future<void> close() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await http.close(force: true);
  }
}

Future<RelayTransport> _connect(_Server server, _ConnectObservation observation) => observation.run(
  () => RelayTransport.connect(url: server.url, deviceId: 'phone', accessToken: 'test-token', hostDeviceId: 'host'),
);

void main() {
  for (final attach in [false, true]) {
    test('late ${attach ? 'relay data' : 'control'} upgrade is closed after the connect deadline', () async {
      final server = await _Server.start(attach: attach, holdControl: !attach);
      final observation = _ConnectObservation();
      final opening = _connect(server, observation);
      final rejected = expectLater(
        opening,
        throwsA(isA<RemoteTransportException>().having((e) => e.code, 'code', 'CONNECTION_FAILED')),
      );
      try {
        final request = await server.held.future.timeout(_watchdog);
        expect(request.uri.path, attach ? '/data' : '/control');
        expect(observation.deadlines.where((t) => t.isActive), hasLength(attach ? 2 : 1));
        observation.expireConnector(attach: attach);
        await rejected;

        final peer = await server.upgrade(request);
        final peerClosed = Completer<void>();
        final received = <Object?>[];
        peer.listen(received.add, onDone: peerClosed.complete);
        final late = await observation.consumed.future.timeout(_watchdog);
        expect(late.closeCalls, 1, reason: 'the abandoned source Future must retire its late socket');
        await late.closing!.timeout(_watchdog);
        await peerClosed.future.timeout(_watchdog);
        expect(peer.closeCode, WebSocketStatus.normalClosure);
        expect(received, isEmpty, reason: 'no hello or relay ticket is sent on the abandoned socket');
      } finally {
        // Even the red baseline owns its observed leak here, after assertion.
        await observation.lateSocket?.socket.close();
        await server.close();
      }
    });

    test('on-time ${attach ? 'relay data' : 'control'} upgrade remains usable', () async {
      final server = await _Server.start(attach: attach, holdControl: false);
      final observation = _ConnectObservation();
      RelayTransport? transport;
      try {
        final opening = _connect(server, observation);
        if (attach) {
          final peer = await server.upgrade(await server.held.future.timeout(_watchdog));
          peer.listen((raw) {
            final frame = jsonDecode(raw as String) as Map<String, dynamic>;
            if (frame['type'] == 'relay.attach') {
              peer.add(_frame('relay.ready', {'connectionId': 'connection', 'epoch': 1}));
            }
          });
        }
        transport = await opening.timeout(_watchdog);
        expect(transport.info.connectionId, 'connection');
        expect(observation.known, hasLength(attach ? 2 : 1));
        expect(observation.deadlines.where((t) => t.isActive), isEmpty);
        expect(observation.lateSocket, isNull);
      } finally {
        await transport?.close();
        await server.close();
      }
    });
  }
}
