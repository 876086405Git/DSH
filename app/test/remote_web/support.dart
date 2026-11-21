// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart' show HostKind;
import 'package:dsh_remote/dsh_remote.dart'
    show
        DshCarrier,
        DshClient,
        RemoteConnectionPhase,
        RemoteConnectionState,
        RemoteHostSession,
        RemoteRpcClient,
        RemoteTunnelCarrier,
        SecureChannelClosed;
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../web/support/fake_webview.dart';

final testGrant = List.filled(43, 'g').join();
final testRoot = Uri.parse('https://test-host.hostc.4ba.io/');

Map<String, Object?> webReply() => {
  'url': testRoot.toString(),
  'browserGrant': testGrant,
  'expiresAt': DateTime.now().millisecondsSinceEpoch + 30000,
};

class WebRpc implements RemoteRpcClient {
  final calls = <String>[];
  FutureOr<Object?> Function(String)? handler;
  // Bind completion to the widget test zone, not the outer setUp zone.
  late final _done = Completer<SecureChannelClosed>();

  @override
  bool get isClosed => _done.isCompleted;
  @override
  Future<SecureChannelClosed> get done => _done.future;
  @override
  Future<Object?> call(String method, Object? params, {Duration? timeout}) async {
    calls.add(method);
    if (handler != null) return await handler!(method);
    return method == 'dsh.web.close' ? {'closed': true} : webReply();
  }

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete(const SecureChannelClosed('CLIENT_CLOSED', 'test'));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class WebCarrier implements RemoteTunnelCarrier {
  WebCarrier(this.current);
  RemoteHostSession? current;
  RemoteConnectionPhase phase = RemoteConnectionPhase.connected;
  final sessionEvents = StreamController<RemoteHostSession>.broadcast();
  final stateEvents = StreamController<RemoteConnectionState>.broadcast();

  @override
  String get hostId => 'host';
  @override
  RemoteHostSession? get session => current;
  @override
  RemoteConnectionState get state => RemoteConnectionState(phase, hostId: hostId);
  @override
  Stream<RemoteHostSession> get sessions => sessionEvents.stream;
  @override
  Stream<RemoteConnectionState> get states => stateEvents.stream;

  void replace(RemoteHostSession next) {
    current = next;
    sessionEvents.add(next);
  }

  void disconnect() {
    phase = RemoteConnectionPhase.reconnecting;
    stateEvents.add(state);
  }

  @override
  Future<void> close() async {
    await sessionEvents.close();
    await stateEvents.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class WebClient implements DshClient {
  WebClient(this.carrier);
  @override
  final DshCarrier carrier;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

HostConnection webConnection(WebCarrier carrier) =>
    HostConnection(client: WebClient(carrier), isLocal: false, kind: HostKind.relay, hostId: carrier.hostId);

class TestWebPlatform extends FakeWebViewPlatform {
  @override
  TestWebController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) {
    final controller = TestWebController(params);
    controllers.add(controller);
    return controller;
  }

  @override
  TestWebDelegate createPlatformNavigationDelegate(PlatformNavigationDelegateCreationParams params) =>
      TestWebDelegate(params);

  TestWebController get last => controllers.last as TestWebController;
}

class TestWebController extends FakeWebViewController {
  TestWebController(super.params);
  final requests = <LoadRequestParams>[];

  /// Exchange pages, loaded as HTML at a base URL on the tunnel's origin.
  final exchanges = <({String html, String? baseUrl})>[];
  TestWebDelegate get navigation => delegate! as TestWebDelegate;

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    exchanges.add((html: html, baseUrl: baseUrl));
    await super.loadHtmlString(html, baseUrl: baseUrl);
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    requests.add(
      LoadRequestParams(
        uri: params.uri,
        method: params.method,
        headers: params.headers,
        body: params.body == null ? null : Uint8List.fromList(params.body!),
      ),
    );
    await super.loadRequest(params);
  }
}

class TestWebDelegate extends FakeNavigationDelegate {
  TestWebDelegate(super.params);
  NavigationRequestCallback? navigate;
  HttpResponseErrorCallback? httpError;

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback callback) async => navigate = callback;
  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback callback) async => httpError = callback;
}
