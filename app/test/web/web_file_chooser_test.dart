import 'dart:async';

import 'package:dsh_app/ui/web/web_file_chooser.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

const _channel = MethodChannel('test/web-files');
const _url = 'http://127.0.0.1:3080/?token=test-only';
const _file = 'content://com.android.providers.media.documents/document/image:12';

FileSelectorParams _params({FileSelectorMode mode = FileSelectorMode.open, List<String> accept = const []}) =>
    FileSelectorParams(isCaptureEnabled: false, acceptTypes: accept, mode: mode);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late WebFileChooser chooser;
  late List<MethodCall> calls;
  late String? url;

  Future<List<String>> choose([FileSelectorParams? params]) =>
      chooser.choose(params ?? _params(), webViewId: 7, currentUrl: () async => url);

  setUp(() {
    calls = [];
    url = _url;
    chooser = WebFileChooser(channel: _channel);
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return call.method == 'pick' ? [_file] : null;
    });
  });
  tearDown(() {
    chooser.dispose();
    messenger.setMockMethodCallHandler(_channel, null);
  });

  test('selected content URI and MIME/multiple request reach the existing callback', () async {
    expect(await choose(_params(accept: ['image/*', 'application/pdf'], mode: FileSelectorMode.openMultiple)), [_file]);
    expect(calls.single.arguments, {
      'owner': '7:0',
      'webViewId': 7,
      'url': _url,
      'acceptTypes': ['image/*', 'application/pdf'],
      'multiple': true,
    });
  });

  test('multiple files are returned only for an input that requests them', () async {
    messenger.setMockMethodCallHandler(_channel, (_) async => [_file, 'content://docs/document/2']);
    expect(await choose(), isEmpty);
    expect(await choose(_params(mode: FileSelectorMode.openMultiple)), hasLength(2));
  });

  for (final response in [
    null,
    <String>[],
    ['file:///data/user/0/app/private'],
    ['content:///missing-authority'],
  ]) {
    test('cancellation or unsupported URI produces an empty callback: $response', () async {
      messenger.setMockMethodCallHandler(_channel, (_) async => response);
      expect(await choose(), isEmpty);
    });
  }

  test('missing picker/platform error completes the callback and permits a retry', () async {
    messenger.setMockMethodCallHandler(_channel, (_) async => throw PlatformException(code: 'unavailable'));
    expect(await choose(), isEmpty);
    messenger.setMockMethodCallHandler(_channel, (_) async => [_file]);
    expect(await choose(), [_file]);
  });

  group('HarmonyOS', () {
    const docs = 'file://docs/storage/Users/currentUser/Download/a.pdf';
    const media = 'file://media/Photo/12/IMG_1/a.jpg';

    late WebFileChooser ohos;
    setUp(() => ohos = WebFileChooser(channel: _channel, ohos: true));
    tearDown(() => ohos.dispose());

    Future<List<String>> pick(List<String> response) {
      messenger.setMockMethodCallHandler(_channel, (call) async => response);
      return ohos.choose(_params(mode: FileSelectorMode.openMultiple), webViewId: 7, currentUrl: () async => url);
    }

    test("the system picker's URIs reach the page", () async {
      expect(await pick(const [docs, media]), const [docs, media]);
    });

    for (final bad in [
      'file:///data/storage/el2/base/haps/entry/files/secret',
      'file://com.example.app/data/storage/el2/base/files/secret',
      '/data/storage/el2/base/files/secret',
      _file,
    ]) {
      test('$bad is refused, along with the rest of the pick', () async {
        expect(await pick([docs, bad]), isEmpty);
      });
    }
  });

  test('save mode and non-web documents never invoke a file picker', () async {
    expect(await choose(_params(mode: FileSelectorMode.save)), isEmpty);
    url = 'file:///data/user/0/app/page.html';
    expect(await choose(), isEmpty);
    expect(calls, isEmpty);
  });

  test('a second callback cannot steal the outstanding picker result', () async {
    final selected = Completer<List<String>>();
    messenger.setMockMethodCallHandler(_channel, (call) {
      calls.add(call);
      return selected.future;
    });
    final first = choose();
    await pumpEventQueue();
    expect(await choose(), isEmpty);
    expect(calls, hasLength(1));
    selected.complete([_file]);
    expect(await first, [_file]);
  });

  for (final dispose in [false, true]) {
    test('navigation/disposal retires a late Android result (dispose=$dispose)', () async {
      final selected = Completer<List<String>>();
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return call.method == 'pick' ? selected.future : null;
      });
      final pending = choose();
      await pumpEventQueue();
      if (dispose) {
        chooser.dispose();
      } else {
        chooser.invalidate();
      }
      await pumpEventQueue();
      expect(calls.last.method, 'cancel');
      expect(calls.last.arguments, {'owner': '7:0'});
      selected.complete([_file]);
      expect(await pending, isEmpty);
    });
  }

  test('URL changed while selecting does not receive the selected file', () async {
    messenger.setMockMethodCallHandler(_channel, (_) async {
      url = 'https://other.example/';
      return [_file];
    });
    expect(await choose(), isEmpty);
  });

  test('same-URL reload during the final URL lookup still retires the callback', () async {
    var reads = 0;
    final finalUrl = Completer<String>();
    final pending = chooser.choose(
      _params(),
      webViewId: 7,
      currentUrl: () async => ++reads == 1 ? _url : finalUrl.future,
    );
    await pumpEventQueue();
    chooser.invalidate();
    finalUrl.complete(_url);
    expect(await pending, isEmpty);
  });
}
