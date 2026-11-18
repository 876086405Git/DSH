// Runs against the original public picker before adding any new product API.
// The MethodChannel boundary stands in for a genuine native authorized result;
// this is not evidence that a Linux machine can grant PasteButton permission.
import 'package:dsh_app/forum/forum_share.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('OH public share picker receives text from authorized native paste', (tester) async {
    final container = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue('ohos')]);
    addTearDown(container.dispose);
    var nativeReads = 0;
    var ordinaryReads = 0;
    const channel = MethodChannel('dsh/paste');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') ordinaryReads++;
      return null; // Ordinary OH package has no unrestricted read permission.
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'readText') {
        nativeReads++;
        expect((call.arguments as Map)['requestId'], isA<String>());
        return {'status': 'text', 'text': 'dshgo://share/plugin?p=clipboard.12345678'};
      }
      return false;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(channel, null);
    });
    late BuildContext target;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          target = context;
          return const SizedBox();
        },
      ),
    );
    final picked = await container.read(forumShareCodePickerProvider)(target);
    expect(picked.link?.code, 'clipboard.12345678');
    expect(picked.reason, isNull);
    expect(nativeReads, 1);
    expect(ordinaryReads, 0);
  });

  testWidgets('OH picker: backed out of or already toasted says nothing, the rest say what happened', (tester) async {
    final container = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue('ohos')]);
    addTearDown(container.dispose);
    const channel = MethodChannel('dsh/paste');
    final messenger = tester.binding.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    late BuildContext target;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          target = context;
          return const SizedBox();
        },
      ),
    );
    Future<String?> reasonFor(Map<String, Object?> reply) async {
      messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'readText' ? reply : false);
      final picked = await container.read(forumShareCodePickerProvider)(target);
      expect(picked.link, isNull);
      return picked.reason;
    }

    expect(await reasonFor({'status': 'cancelled'}), isNull);
    expect(await reasonFor({'status': 'denied', 'shown': true}), isNull);
    expect(await reasonFor({'status': 'busy'}), '粘贴窗口尚未结束或仍在关闭，请完成或取消后重试。');
    expect(await reasonFor({'status': 'unavailable'}), '无法读取剪贴板，请重试或手动输入。');
    expect(await reasonFor({'status': 'text', 'text': 'not a code'}), isNot(isNull));
  });
}
