import 'package:dsh_app/diagnostics/app_error_log.dart';
import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/diagnostics/diagnostics_markdown.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';

void main() {
  DiagnosticsSnapshot snapshot({
    List<String> engineLog = const [],
    List<String> failureLog = const [],
    List<AppErrorRecord> errors = const [],
    Map<String, Object?> connection = const {},
    Map<String, Object?> performance = const {},
    Map<String, Object?>? device,
  }) => DiagnosticsSnapshot(
    at: DateTime(2026, 10, 31, 18, 2, 3),
    status: RuntimeStatus(
      phase: RuntimePhase.running,
      abi: 'arm64-v8a',
      bundledVersion: 'r11-dsh0.2.1-rc.4-node24.22.1-ubuntu24.04.5',
      installedVersion: 'r11-dsh0.2.1-rc.4-node24.22.1-ubuntu24.04.5',
      dshVersion: '0.2.1-rc.4',
      nodeVersion: '24.22.1',
      baseUrl: 'http://127.0.0.1:4512',
      token: 'launch-token-secret-value',
      currentExecutionMode: 'proot',
      launchSelectedMode: 'proot',
    ),
    settings: const AppSettings(apiKey: 'sk-verysecretvalue123', themeMode: ThemeMode.dark, phoneStorage: true),
    native: NativeDiagnostics(
      app: {'versionName': '1.0.6', 'versionCode': 10311700, 'abi': 'arm64-v8a'},
      device:
          device ??
          {
            'manufacturer': 'vivo',
            'brand': 'vivo',
            'model': 'V2405A',
            'android': '16',
            'sdkInt': 36,
            'memoryMb': 12288,
            'freeStorageMb': 4096,
          },
      manifest: {'runtimeVersion': 'r11', 'dshVersion': '0.2.1-rc.4', 'nodeVersion': '24.22.1'},
    ),
    connection: connection,
    performance: performance,
    engineLog: engineLog,
    failureLog: failureLog,
    appErrors: errors,
  );

  group('the device line', () {
    String line(Map<String, Object?> device) =>
        diagnosticsMarkdown(snapshot(device: device)).split('\n').singleWhere((l) => l.startsWith('- 设备：'));

    test('on Android as ever', () {
      expect(line({'manufacturer': 'vivo', 'android': '16', 'sdkInt': 36}), contains('Android 16 (SDK 36)'));
    });

    test('on HarmonyOS its own version and API', () {
      expect(
        line({'manufacturer': 'HUAWEI', 'osVersion': 'HarmonyOS 6.0.0', 'apiVersion': 26}),
        contains('HarmonyOS 6.0.0 (API 26)'),
      );
      expect(line({'manufacturer': 'HUAWEI', 'apiVersion': 26}), contains('API 26'));
      expect(line({'manufacturer': 'HUAWEI'}), isNot(contains('API')));
    });
  });

  test('the report has the sections a support skill needs', () {
    final text = diagnosticsMarkdown(snapshot());
    expect(text, contains('# DSH Go 本机诊断'));
    expect(text, contains('## 环境'));
    expect(text, contains('vivo'));
    expect(text, contains('V2405A'));
    expect(text, contains('Android 16 (SDK 36)'));
    expect(text, contains('设备资源：内存 12288 MB · 剩余存储 4096 MB'));
    expect(text, contains('0.2.1-rc.4'));
    expect(text, contains('## 设置'));
    expect(text, contains('API Key：已设置'));
    expect(text, contains('## 连接'));
    expect(text, contains('## 性能'));
  });

  test('resource sizes preserve native MB, including small and missing values', () {
    final cases = <(Map<String, Object?>, String)>[
      ({'memoryMb': 11323, 'freeStorageMb': 64512}, '- 设备资源：内存 11323 MB · 剩余存储 64512 MB'),
      ({'memoryMb': 0, 'freeStorageMb': 1}, '- 设备资源：内存 0 MB · 剩余存储 1 MB'),
      ({'memoryMb': 2048}, '- 设备资源：内存 2048 MB'),
      ({}, '- 设备资源：'),
    ];
    for (final (device, expected) in cases) {
      final report = diagnosticsMarkdown(snapshot(device: device));
      expect(report.split('\n').singleWhere((line) => line.startsWith('- 设备资源：')), expected);
    }
  });

  test('secrets never survive, even inside log lines and errors', () {
    final text = diagnosticsMarkdown(
      snapshot(
        engineLog: ['start token=launch-token-secret-value', 'Authorization: Bearer abcdef0123456789'],
        errors: [
          AppErrorRecord(
            at: DateTime(2026, 10, 31, 17, 0),
            source: AppErrorSource.flutter,
            message: 'request failed with apiKey=sk-verysecretvalue123',
            stack: '',
          ),
        ],
      ),
    );
    expect(text, isNot(contains('launch-token-secret-value')));
    expect(text, isNot(contains('abcdef0123456789')));
    expect(text, isNot(contains('sk-verysecretvalue123')));
    expect(text, contains('•••'));
  });

  test('log tails are capped and the whole file is bounded', () {
    final many = [for (var i = 0; i < 3000; i++) 'line $i: ${'x' * 40}'];
    final text = diagnosticsMarkdown(snapshot(engineLog: many), maxBytes: 4096);
    expect(text.length, lessThanOrEqualTo(4096 + 80));
    expect(text, contains('已截断'));
    final capped = diagnosticsMarkdown(snapshot(engineLog: many));
    expect(capped, contains('取最后 80 行'));
    expect(capped, isNot(contains('line 0:')));
    expect(capped, contains('line 2999:'));
  });

  test('display facts are printed, for "the pet looks the wrong size" reports', () {
    final text = diagnosticsMarkdown(
      snapshot(
        device: {
          'model': 'M154FF',
          'display': {'widthPx': 1208, 'heightPx': 2624, 'density': 2.625, 'densityDpi': 420, 'fontScale': 1.0},
        },
      ),
    );
    expect(text, contains('显示：1208×2624 · 420dpi · 2.625× · 字号 1.0'));
  });

  test('connection and performance maps are printed as facts', () {
    final text = diagnosticsMarkdown(
      snapshot(
        connection: {'state': 'connected', 'route': 'relay'},
        performance: {
          'device': {'tier': 'high'},
          'thermal': {'lightweight': false},
        },
      ),
    );
    expect(text, contains('state：connected'));
    expect(text, contains('route：relay'));
    expect(text, contains('tier=high'));
  });
}
