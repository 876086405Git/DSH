import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final wirePath = Platform.environment['OHOS_INSTALL_RECORD_WIRE'];
  final records = wirePath == null
      ? <Object?>[
          {
            'name': 'contract',
            'status': {
              'value': {
                'phase': 'error',
                'installedVersion': null,
                'error': '运行时安装记录已损坏，请选择“重置运行环境”。',
              },
            },
            'install': {
              'code': 'ohos_install_record_invalid',
              'message': '运行时安装记录已损坏，请选择“重置运行环境”。',
            },
          },
        ]
      : jsonDecode(File(wirePath).readAsStringSync()) as List<Object?>;
  const channel = MethodChannel('test/ohos-install-record');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  for (final raw in records) {
    final record = raw! as Map<String, dynamic>;
    test('安装记录损坏 ${record['name']} 的原生状态和错误到达 Dart consumer', () async {
      final statusReply = record['status'] as Map<String, dynamic>;
      final installReply = record['install'] as Map<String, dynamic>;
      expect(statusReply.containsKey('code'), isFalse);
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getStatus') return statusReply['value'];
        if (call.method == 'install') {
          throw PlatformException(
            code: installReply['code'] as String,
            message: installReply['message'] as String,
          );
        }
        throw MissingPluginException(call.method);
      });
      final bridge = RuntimeBridge(methods: channel);
      final status = await bridge.status();
      expect(status.phase, RuntimePhase.error);
      expect(status.installedVersion, isNull);
      expect(status.error, contains('重置运行环境'));
      await expectLater(
        bridge.install(),
        throwsA(
          isA<PlatformException>()
              .having(
                (error) => error.code,
                '稳定错误码',
                'ohos_install_record_invalid',
              )
              .having((error) => error.message, '恢复路径', contains('重置运行环境')),
        ),
      );
    });
  }
}
