import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

const _sample = {
  'v': 1,
  'bootId': 'boot-a',
  'platform': 'openharmony',
  'arch': 'arm64',
  'nodeVersion': '24.22.1',
  'simulated': false,
  'shell': {
    'kind': 'virtual',
    'commands': ['bash', 'sh', 'rg'],
    'pty': 'unsupported',
  },
  'processSpawn': 'unsupported',
  'nodeScripts': 'none',
  'python': 'unsupported',
  'wasm': 'unsupported',
  'plugins': {'bundled': 'supported', 'marketInstall': 'unsupported'},
  'nativeModules': [
    {'name': 'node:sqlite', 'version': null, 'state': 'loaded'},
  ],
  'storage': {'sessionLock': 'main-thread'},
  'background': {'policy': 'may-freeze', 'computePermission': 'unknown', 'resume': 'none'},
  'publication': {'atomic': 'disabled-after-crash', 'systemVersion': 'fixture-system-build'},
  'future': {'ignored': true},
};

void main() {
  test('Worker路径重定位是独立协议值，不把Dart枚举拼写当作合法wire值', () {
    final cases = {
      'worker': RuntimeNodeScripts.worker,
      'worker-rebased': RuntimeNodeScripts.workerRebased,
      'process': RuntimeNodeScripts.process,
      'none': RuntimeNodeScripts.none,
      'workerRebased': RuntimeNodeScripts.unknown,
      'future': RuntimeNodeScripts.unknown,
    };
    for (final entry in cases.entries) {
      expect(RuntimeCapabilities.fromJson({'v': 1, 'nodeScripts': entry.key})!.nodeScripts, entry.value);
    }
  });

  test('完整v1、发布熔断和未来可选字段', () {
    final value = RuntimeCapabilities.fromJson(_sample)!;
    expect(
      (value.bootId, value.platform, value.arch, value.nodeVersion, value.simulated),
      ('boot-a', 'openharmony', 'arm64', '24.22.1', false),
    );
    expect(value.shell.kind, RuntimeShellKind.virtual);
    expect(value.shell.commands, ['bash', 'sh', 'rg']);
    expect(value.shell.pty, RuntimeSupport.unsupported);
    expect(value.nodeScripts, RuntimeNodeScripts.none);
    expect([value.processSpawn, value.python, value.wasm], everyElement(RuntimeSupport.unsupported));
    expect(value.plugins.bundled, RuntimeSupport.supported);
    expect(value.plugins.marketInstall, RuntimeSupport.unsupported);
    expect(value.nativeModules!.single.state, RuntimeNativeModuleState.loaded);
    expect(value.nativeModules!.single.version, isNull);
    expect(value.storage.sessionLock, RuntimeSessionLock.mainThread);
    expect(value.background.policy, RuntimeBackgroundPolicy.mayFreeze);
    expect(value.background.computePermission, RuntimeComputePermission.unknown);
    expect(value.background.resume, RuntimeResume.none);
    expect(value.publication.atomic, RuntimePublicationAtomic.disabledAfterCrash);
    expect(value.publication.systemVersion, 'fixture-system-build');
    expect(() => value.shell.commands!.add('python'), throwsUnsupportedError);
    expect(() => value.nativeModules!.clear(), throwsUnsupportedError);
  });

  test('缺失字段是unknown，空清单与未知清单不同，布尔与字符串不强制互转', () {
    final empty = RuntimeCapabilities.fromJson({'v': 1})!;
    expect(empty.shell.kind, RuntimeShellKind.unknown);
    expect(empty.shell.commands, isNull);
    expect(empty.nativeModules, isNull);
    expect(empty.simulated, isNull);
    expect([empty.processSpawn, empty.python, empty.wasm], everyElement(RuntimeSupport.unknown));
    expect(empty.storage.sessionLock, RuntimeSessionLock.unknown);
    expect(empty.background.policy, RuntimeBackgroundPolicy.unknown);
    expect(empty.publication.atomic, RuntimePublicationAtomic.unknown);
    final lists = RuntimeCapabilities.fromJson({
      'v': 1,
      'shell': {'commands': []},
      'nativeModules': [],
    })!;
    expect(lists.shell.commands, isEmpty);
    expect(lists.nativeModules, isEmpty);
    for (final raw in [true, false, 1, 'true', 'enabled', <Object?>[], <String, Object?>{}]) {
      final value = RuntimeCapabilities.fromJson({'v': 1, 'python': raw, 'simulated': 'false', 'shell': raw})!;
      expect(value.python, RuntimeSupport.unknown);
      expect(value.simulated, isNull);
      expect(value.shell.kind, RuntimeShellKind.unknown);
    }
    expect(
      RuntimeCapabilities.fromJson({
        'v': 1,
        'shell': {
          'commands': ['bash', 9],
        },
      })!.shell.commands,
      isNull,
    );
  });

  test('协议版本严格、未知枚举不推测，新boot不沿用旧快照', () {
    for (final raw in [
      null,
      [],
      {},
      {'v': '1'},
      {'v': 1.0},
      {'v': true},
      {..._sample, 'v': 2},
    ]) {
      expect(RuntimeCapabilities.fromJson(raw), isNull);
    }
    final unknown = RuntimeCapabilities.fromJson({
      'v': 1,
      'bootId': 'boot-b',
      'nodeScripts': 'future',
      'storage': {'sessionLock': 'mainThread'},
      'publication': {'atomic': 'disabledAfterCrash'},
      'background': {'policy': 'forever', 'resume': true},
    })!;
    expect(unknown.nodeScripts, RuntimeNodeScripts.unknown);
    expect(unknown.storage.sessionLock, RuntimeSessionLock.unknown);
    expect(unknown.publication.atomic, RuntimePublicationAtomic.unknown);
    expect(unknown.background.policy, RuntimeBackgroundPolicy.unknown);
    expect(unknown.background.resume, RuntimeResume.unknown);
    expect(unknown.bootId, isNot(RuntimeCapabilities.fromJson(_sample)!.bootId));
  });

  test('原生模块仅按状态解析：重复名字保守unknown、坏行不变成已知空数组', () {
    final modules = RuntimeCapabilities.fromJson({
      'v': 1,
      'nativeModules': [
        {'name': 'loader', 'version': '1', 'state': 'loaded'},
        {'name': 'loader', 'version': '2', 'state': 'packaged'},
        {'name': 'future', 'version': 7, 'state': 'enabled'},
      ],
    })!.nativeModules!;
    expect(modules.length, 2);
    expect(modules.map((row) => row.state), everyElement(RuntimeNativeModuleState.unknown));
    expect(modules.first.version, isNull);
    expect(
      RuntimeCapabilities.fromJson({
        'v': 1,
        'nativeModules': [
          {'state': 'loaded'},
        ],
      })!.nativeModules,
      isNull,
    );
    expect(RuntimeCapabilities.fromJson({'v': 1, 'nativeModules': 'loaded'})!.nativeModules, isNull);
  });

  group('真实HTTP兼容', () {
    late HttpServer server;
    late DshClient client;
    late int status;
    late String type;
    late Object? body;
    final paths = <String>[];
    final cookies = <String?>[];
    final origins = <String?>[];

    setUp(() async {
      status = 200;
      type = 'application/json';
      body = _sample;
      paths.clear();
      cookies.clear();
      origins.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/mount/' && request.uri.queryParameters['token'] == 'fixture-token') {
          request.response
            ..statusCode = 303
            ..headers.set('location', './')
            ..headers.add('set-cookie', 'dsh-auth-fixture=v1.test; Path=/; HttpOnly');
        } else {
          paths.add(request.uri.path);
          cookies.add(request.headers.value(HttpHeaders.cookieHeader));
          origins.add(request.headers.value('origin'));
          request.response.statusCode = status;
          request.response.headers.set(HttpHeaders.contentTypeHeader, type);
          if (status == 302) request.response.headers.set('location', '/elsewhere');
          request.response.write(body is String ? body : jsonEncode(body));
        }
        await request.response.close();
      });
      client = await DshClient.connect(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}/mount'),
        token: 'fixture-token',
        startMux: false,
      );
    });

    tearDown(() async {
      await client.close();
      await server.close(force: true);
    });

    test('复用Cookie与挂载路径，每次重新取，保留旧的不可变快照', () async {
      expect(client.canReadRuntimeCapabilities, isTrue);
      final first = await client.readRuntimeCapabilities();
      body = {
        ..._sample,
        'bootId': 'boot-b',
        'publication': {'atomic': 'unsupported'},
      };
      final next = await client.readRuntimeCapabilities();
      expect(first!.bootId, 'boot-a');
      expect(next!.bootId, 'boot-b');
      expect(first.publication.atomic, RuntimePublicationAtomic.disabledAfterCrash);
      expect(next.publication.atomic, RuntimePublicationAtomic.unsupported);
      expect(paths, ['/mount$runtimeCapabilitiesPath', '/mount$runtimeCapabilitiesPath']);
      expect(cookies, everyElement('dsh-auth-fixture=v1.test'));
      expect(origins, everyElement(isNull));
    });

    test('能力读取沿用注入的HttpClient及其代理策略', () async {
      var proxyChecks = 0;
      final transport = HttpClient()
        ..findProxy = (uri) {
          proxyChecks++;
          return 'DIRECT';
        };
      final custom = DshClient(
        DshConnection(
          Uri.parse('http://127.0.0.1:${server.port}/mount'),
          httpClient: transport,
          cookie: const DshCookie(name: 'dsh-auth-fixture', value: 'v1.test', authority: 'fixture'),
        ),
      );
      try {
        expect((await custom.readRuntimeCapabilities())!.bootId, 'boot-a');
        expect(proxyChecks, greaterThan(0));
      } finally {
        await custom.close();
        transport.close(force: true);
      }
    });

    test('404/405/501与未知主版本是协议未知，401/403/5xx仍抛原状态', () async {
      for (final code in [404, 405, 501]) {
        status = code;
        expect(await client.readRuntimeCapabilities(), isNull);
      }
      status = 200;
      body = {
        'v': 2,
        'shell': {'kind': 'system'},
      };
      expect(await client.readRuntimeCapabilities(), isNull);
      for (final code in [401, 403, 500, 503]) {
        status = code;
        await expectLater(
          client.readRuntimeCapabilities(),
          throwsA(isA<DshHttpException>().having((error) => error.statusCode, 'status', code)),
        );
      }
      status = 200;
      body = _sample;
      expect((await client.readRuntimeCapabilities())!.bootId, 'boot-a');
    });

    test('非JSON、坏信封、超大正文与重定向是失败，不能永久缓存为不支持', () async {
      for (final invalid in [
        '<html>',
        'not JSON',
        [],
        {},
        {'v': '1'},
      ]) {
        body = invalid;
        await expectLater(client.readRuntimeCapabilities(), throwsA(isA<DshProtocolException>()));
      }
      body = _sample;
      type = 'text/html';
      await expectLater(client.readRuntimeCapabilities(), throwsA(isA<DshProtocolException>()));
      type = 'application/json';
      body = {'v': 1, 'large': 'x' * (128 * 1024)};
      await expectLater(client.readRuntimeCapabilities(), throwsA(isA<DshProtocolException>()));
      status = 302;
      body = _sample;
      await expectLater(client.readRuntimeCapabilities(), throwsA(isA<DshHttpException>()));
      expect(paths, isNot(contains('/elsewhere')));
      status = 200;
      body = _sample;
      expect((await client.readRuntimeCapabilities())!.shell.kind, RuntimeShellKind.virtual);
    });
  });
}
