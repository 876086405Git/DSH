// 回归：提示词增强必须同时支持两种宿主。
//
// 本机引擎由 dsh-go 桥提供 `/dsh-go/v1/prompt-enhance`；远程主机跑的是桌面版
// `dsh-prompt-enhance` 插件，挂在 `/dsh-prompt-enhance`。以前客户端只认前者，
// 于是「本机能用、远程主机一律报不支持」——两个宿主结构相同，只是路径不同。

import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

/// 记录收到的请求，并按 [routes] 回应；未列出的路径回 404 + 纯文本（和宿主一样）。
class _Host {
  _Host(this.routes);

  final Map<String, (int, Object?)> routes;
  final requests = <(String, String)>[];
  late HttpServer server;
  late DshClient client;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      requests.add((request.method, path));
      // 读掉 body，否则客户端可能等不到响应。
      await utf8.decoder.bind(request).join();
      final route = routes['${request.method} $path'];
      if (route == null) {
        request.response
          ..statusCode = 404
          ..headers.contentType = ContentType.text
          ..write('Not Found\n');
        await request.response.close();
        return;
      }
      final (status, payload) = route;
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(payload));
      await request.response.close();
    });
    client = DshClient.withCarrier(
      DshHttpCarrier(DshConnection(Uri.parse('http://127.0.0.1:${server.port}'))),
    );
  }

  Future<void> stop() async {
    await client.close();
    await server.close(force: true);
  }
}

Map<String, Object?> _statusOk() => {
  'ok': true,
  'plugin': 'dsh-prompt-enhance',
  'version': '1.0.0',
  'model': {'provider': 'deepseek', 'model': 'deepseek-chat'},
  'limits': {'maxInputChars': 20000, 'maxOutputTokens': 800, 'timeoutMs': 120000},
};

Map<String, Object?> _enhanceOk() => {
  'ok': true,
  'text': '优化后的提示词',
  'contextUsed': false,
  'trimmed': false,
  'limit': 800,
  'model': {'provider': 'deepseek', 'model': 'deepseek-chat'},
  'elapsedMs': 120,
};

/// 远程隧道：只有受限 RPC，没有 HTTP 通道（`DshCarrier` 但不实现 `DshHttpCarrier`）。
class _TunnelCarrier extends DshCarrier {
  _TunnelCarrier({this.routes = const {}});

  /// 宿主侧 `plugin.route.call` 能转发的插件路由 → 响应体。
  final Map<String, Map<String, Object?>> routes;

  final calls = <(String, Map<String, Object?>)>[];

  @override
  String get kind => 'remote-relay';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    if (endpoint == 'plugin.route.call') {
      final route = args['route'];
      final body = routes[route];
      if (body == null) {
        // 和真实宿主一样：方法在，但这条插件路由不在白名单。
        return RpcError(DshRemoteException('INVALID_MESSAGE', 'A valid plugin route is required.'));
      }
      return RpcOk({'status': 200, 'json': body});
    }
    return RpcError(DshRemoteException('gateway/method-not-allowed', endpoint));
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) =>
      throw const DshCarrierRefusedException('TEST', 'no mux in this test');

  @override
  Future<void> close() async {}
}

void main() {
  test('远程隧道：经 plugin.route.call 转发到宿主的插件路由', () async {
    // 远程隧道没有 HTTP 通道，但宿主可以转发单个白名单插件路由。
    // 以前这里 `carrier as DshHttpCarrier` 直接抛
    // "type 'RemoteTunnelCarrier' is not a subtype of type 'DshHttpCarrier'"。
    final carrier = _TunnelCarrier(
      routes: {
        'dsh-prompt-enhance/enhance': _enhanceOk(),
      },
    );
    final client = DshClient.withCarrier(carrier);
    addTearDown(client.close);

    expect(await client.promptEnhanceAvailable(), isTrue);
    final result = await client.promptEnhance(text: '把登录页改好看点');
    expect(result.text, '优化后的提示词');

    // 走的是 plugin.route.call，且带上了正确的 route 与请求体。
    // （可用性探测也会发一次，所以取最后一次。）
    final call = carrier.calls.lastWhere((c) => c.$1 == 'plugin.route.call');
    final args = call.$2;
    expect(args['route'], 'dsh-prompt-enhance/enhance');
    final body = args['body'] as Map<String, Object?>;
    expect(body['text'], '把登录页改好看点');
  });

  test('远程隧道：宿主不转发这条路由时如实报不支持，而不是抛类型错误', () async {
    // 宿主认识 RPC 但不放行这条插件路由（旧版 ds-harness-remote 的情况）。
    final carrier = _TunnelCarrier();
    final client = DshClient.withCarrier(carrier);
    addTearDown(client.close);

    expect(await client.promptEnhanceAvailable(), isFalse);
    await expectLater(
      client.promptEnhance(text: '随便写点什么'),
      throwsA(
        isA<PromptEnhanceFailure>().having((e) => e.code, 'code', 'ROUTE_NOT_FOUND'),
      ),
    );
  });

  test('远程主机：回退到桌面插件的 /dsh-prompt-enhance 路径', () async {
    final host = _Host({
      'GET $desktopPromptEnhanceStatusPath': (200, _statusOk()),
      'POST $desktopPromptEnhanceEnhancePath': (200, _enhanceOk()),
    });
    await host.start();
    addTearDown(host.stop);

    expect(await host.client.promptEnhanceAvailable(), isTrue);
    final result = await host.client.promptEnhance(text: '把登录页改好看点');
    expect(result.text, '优化后的提示词');

    final posts = host.requests.where((r) => r.$1 == 'POST').map((r) => r.$2);
    expect(posts, contains(desktopPromptEnhanceEnhancePath));
  });

  test('本机引擎：优先用桥的 /dsh-go/v1/prompt-enhance 路径', () async {
    final host = _Host({
      'GET $dshGoPromptEnhancePath/status': (200, _statusOk()),
      'POST $dshGoPromptEnhancePath': (200, _enhanceOk()),
    });
    await host.start();
    addTearDown(host.stop);

    expect(await host.client.promptEnhanceAvailable(), isTrue);
    final result = await host.client.promptEnhance(text: '把登录页改好看点');
    expect(result.text, '优化后的提示词');

    final posts = host.requests.where((r) => r.$1 == 'POST').map((r) => r.$2);
    expect(posts, contains(dshGoPromptEnhancePath));
  });

  test('两套路径都没有时才报不支持', () async {
    final host = _Host({});
    await host.start();
    addTearDown(host.stop);

    expect(await host.client.promptEnhanceAvailable(), isFalse);
    await expectLater(
      host.client.promptEnhance(text: '随便写点什么'),
      throwsA(
        isA<PromptEnhanceFailure>().having((e) => e.code, 'code', 'ROUTE_NOT_FOUND'),
      ),
    );
  });

  test('宿主的业务错误照常上抛，不被回退吞掉', () async {
    final host = _Host({
      'POST $desktopPromptEnhanceEnhancePath': (
        503,
        {
          'ok': false,
          'error': {'code': 'NO_MODEL', 'message': '宿主没有可用的默认模型路由'},
        },
      ),
    });
    await host.start();
    addTearDown(host.stop);

    await expectLater(
      host.client.promptEnhance(text: '随便写点什么'),
      throwsA(isA<PromptEnhanceFailure>().having((e) => e.code, 'code', 'NO_MODEL')),
    );
  });
}
