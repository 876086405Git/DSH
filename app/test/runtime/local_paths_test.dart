import 'package:dsh_app/runtime/local_paths.dart';
import 'package:dsh_app/state/sessions_state.dart' show localWorkspaceDir;
import 'package:dsh_app/ui/workspace/workspace_format.dart' show displayPath, localHome;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('test/local-paths');
const _root = '/data/storage/el2/base/haps/entry/files/runtime/rootfs';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void answer(Object? Function(MethodCall call) reply) =>
      messenger.setMockMethodCallHandler(_channel, (call) async => reply(call));

  tearDown(() {
    LocalPaths.debugRoot = null;
    messenger.setMockMethodCallHandler(_channel, null);
  });

  test("Android's guest paths don't ask anyone", () async {
    var asked = false;
    answer((_) {
      asked = true;
      return _root;
    });
    await LocalPaths.load(ohos: false, channel: _channel);
    expect(asked, isFalse);
    expect(LocalPaths.noGuest, isFalse);
    expect(LocalPaths.root, isNull);
    expect(localHome, '/root');
    expect(localWorkspaceDir, '/root/workspace');
  });

  test('HarmonyOS keeps the layout under the root the native side reports', () async {
    answer((call) => call.method == 'guestRoot' ? _root : null);
    await LocalPaths.load(ohos: true, channel: _channel);
    expect(LocalPaths.noGuest, isTrue);
    expect(localHome, '$_root/root');
    expect(localWorkspaceDir, '$_root/root/workspace');
    expect(displayPath(localWorkspaceDir, local: true), '~/workspace');
  });

  test('a root that is missing, relative or refused leaves the paths alone', () async {
    for (final reply in <Object? Function(MethodCall)>[
      (_) => null,
      (_) => 'relative/rootfs',
      (_) => throw PlatformException(code: 'ohos_unsupported'),
    ]) {
      answer(reply);
      await LocalPaths.load(ohos: true, channel: _channel);
      expect(LocalPaths.noGuest, isFalse);
      expect(localWorkspaceDir, '/root/workspace');
    }
  });

  test('no native side at all leaves the paths alone', () async {
    await LocalPaths.load(ohos: true, channel: _channel);
    expect(LocalPaths.noGuest, isFalse);
  });
}
