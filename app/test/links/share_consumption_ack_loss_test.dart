// Actual Dart consumer with an explicit transport-fault receiver. This is not
// a claim that HMS/device packet loss has been measured.
import 'dart:io';

import 'package:dsh_app/links/share_intake.dart';
import 'package:dsh_app/state/compose_inbox.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native consumption followed by eight lost ACK replies does not reject the next valid share', () async {
    const channel = MethodChannel('test/share-ack-loss');
    final root = await Directory.systemTemp.createTemp('share-ack-loss-');
    final paths = <String, String>{};
    final settled = <String>[];
    final acks = <Object?>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') return true;
      if (call.method != 'consumed') throw MissingPluginException(call.method);
      acks.add(call.arguments);
      final id = (call.arguments as Map)['shareId'] as String;
      // Explicit boundary behavior: the native owner has consumed its entry
      // and attempted deletion, but Dart does not receive the successful reply.
      settled.add(id);
      await File(paths[id]!).delete();
      throw PlatformException(code: 'reply_transport_lost');
    });
    final intake = ShareIntake(channel: channel, ohos: true);
    final shares = <IncomingShare>[];
    final subscription = intake.shares.listen(shares.add);
    Future<void> deliver(int i) async {
      final id = 'aaaaaaaa-bbbb-4ccc-8ddd-${i.toString().padLeft(12, '0')}';
      final path = '${root.path}/$i.pdf';
      await File(path).writeAsString('%PDF-1.7\n$i');
      paths[id] = path;
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('share', {
            'shareId': id,
            'files': [
              {'path': path, 'name': '$i.pdf'},
            ],
          }),
        ),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
    }

    try {
      for (var i = 1; i <= 8; i++) {
        await deliver(i);
        expect(shares, hasLength(i));
        final request = await ComposeRequest.fromShare(shares.last);
        expect(request.attachments.map((a) => a.name), ['$i.pdf']);
        await shares.last.consumption!.finish();
        expect(settled, hasLength(i));
        expect(acks, hasLength(i), reason: 'no automatic retry');
        expect(File(paths[settled.last]!).existsSync(), isFalse);
      }
      await deliver(9);
      expect(
        shares,
        hasLength(9),
        reason: 'Consumed Dart entries must not impose a second permanent eight-batch quota after lost replies.',
      );
      expect(shares.last.files.single.name, '9.pdf');
      expect(acks, hasLength(8), reason: 'the ninth file has not been consumed yet');
    } finally {
      await subscription.cancel();
      intake.dispose();
      messenger.setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    }
  });
}
