// 回归：「内置模型」档位。
//
// SenseVoice 跑在 App 进程里，与引擎、系统识别服务都无关。这条路径是本机/远程、
// 在线/离线都成立的唯一一条（见上游 #716、#1067），所以它必须：
//   1. 显式选「内置模型」时只用它，不碰引擎语音、不碰系统识别；
//   2. 自动模式下模型就绪时优先用它；
//   3. 转写结果直接进草稿。

import 'package:dsh_app/state/voice_settings.dart';
import 'package:dsh_app/ui/chat/voice/voice_controller.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/composer_fakes.dart';

/// 远程隧道：没有 HTTP 通道，`speech/*` 也不在白名单里。
class _RemoteHostCarrier extends FakeRpcCarrier {
  _RemoteHostCarrier(super.handlers);

  static const _allowlist = {'session/list'};

  @override
  bool allowsEndpoint(String endpoint) => _allowlist.contains(endpoint);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

VoiceInputController _voice({
  required DshClient client,
  required FakeVoiceBridge bridge,
  required TextEditingController input,
  required VoiceMode mode,
}) => VoiceInputController(
  input: input,
  bridge: bridge,
  client: () => client,
  mode: () async => mode,
  modelReady: () => false,
  observeLifecycle: false,
);

void main() {
  testWidgets('choosing the bundled model records offline and never touches the engine',
      (tester) async {
    final carrier = _RemoteHostCarrier({});
    final client = DshClient.withCarrier(carrier);
    final bridge = FakeVoiceBridge()..offlineReady = true;
    final input = TextEditingController(text: '你好');
    final voice = _voice(
      client: client,
      bridge: bridge,
      input: input,
      mode: VoiceMode.offline,
    );
    addTearDown(voice.dispose);
    addTearDown(input.dispose);

    await voice.start();
    await _settle(tester);

    // 走的是内置模型录音，不是引擎录音、也不是系统识别。
    expect(bridge.calls.where((c) => c.startsWith('offline')), isNotEmpty);
    expect(bridge.calls.where((c) => c.startsWith('recorder')), isEmpty);
    expect(bridge.calls, isNot(contains('recognizer')));
    // 也没有向主机要任何语音能力。
    expect(carrier.calls.where((c) => c.$1.startsWith('speech/')), isEmpty);
  });

  testWidgets('the bundled model puts its transcript into the draft', (tester) async {
    final carrier = _RemoteHostCarrier({});
    final client = DshClient.withCarrier(carrier);
    final bridge = FakeVoiceBridge()
      ..offlineReady = true
      ..offlineText = '帮我整理本周计划';
    final input = TextEditingController(text: '前缀 ');
    final voice = _voice(
      client: client,
      bridge: bridge,
      input: input,
      mode: VoiceMode.offline,
    );
    addTearDown(voice.dispose);
    addTearDown(input.dispose);

    await voice.start();
    await _settle(tester);
    await voice.stop();
    await _settle(tester);

    expect(input.text, contains('帮我整理本周计划'));
    expect(bridge.calls, contains('stopOffline'));
  });

  testWidgets('auto mode prefers the bundled model once it is ready', (tester) async {
    final carrier = _RemoteHostCarrier({});
    final client = DshClient.withCarrier(carrier);
    final bridge = FakeVoiceBridge()..offlineReady = true;
    final input = TextEditingController(text: '你好');
    final voice = _voice(
      client: client,
      bridge: bridge,
      input: input,
      mode: VoiceMode.auto,
    );
    addTearDown(voice.dispose);
    addTearDown(input.dispose);

    await voice.start();
    await _settle(tester);

    expect(bridge.calls.where((c) => c.startsWith('offline')), isNotEmpty);
    expect(bridge.calls, isNot(contains('recognizer')));
  });

  testWidgets('auto mode still uses the system recognizer when the bundled model is absent',
      (tester) async {
    final carrier = _RemoteHostCarrier({});
    final client = DshClient.withCarrier(carrier);
    final bridge = FakeVoiceBridge()..offlineReady = false;
    final input = TextEditingController(text: '你好');
    final voice = _voice(
      client: client,
      bridge: bridge,
      input: input,
      mode: VoiceMode.auto,
    );
    addTearDown(voice.dispose);
    addTearDown(input.dispose);

    await voice.start();
    await _settle(tester);

    expect(bridge.calls, contains('recognizer'));
    expect(bridge.calls.where((c) => c.startsWith('offline')), isEmpty);
  });
}
