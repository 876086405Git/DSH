import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/share_hosted/hosted_client.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/share_hosted/hosted_link.dart';
import 'package:dsh_app/share_hosted/hosted_links_state.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:dsh_app/ui/share_hosted/hosted_link_maker.dart';
import 'package:dsh_app/ui/replay/conversation_out.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../share_hosted/hosted_client_test.dart' show FakeHost;
import '../share_hosted/hosted_links_state_test.dart' show link;

// The injected FlutterSecureStorage boundary still goes through the real
// SecureHostedLinkStore and AppSecureStorage Android/injection path.
class FaultStorage implements FlutterSecureStorage {
  FaultStorage(List<HostedLink> links) : raw = jsonEncode([for (final l in links) l.toJson()]);
  String? raw;
  Object? readError;
  Object? writeError;
  Completer<void>? writeGate;
  int writes = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) {
      return readError == null ? Future<String?>.value(raw) : Future<String?>.error(readError!);
    }
    if (invocation.memberName == #write) {
      writes++;
      return _write(invocation.namedArguments[#value] as String?);
    }
    return super.noSuchMethod(invocation);
  }

  Future<void> _write(String? value) async {
    if (writeGate case final gate?) await gate.future;
    if (writeError case final error?) throw error;
    raw = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final failure = PlatformException(code: 'storage_locked');
  (ProviderContainer, HostedLinksController, FakeHost) rig(FaultStorage storage) {
    final host = FakeHost();
    final container = ProviderContainer(
      overrides: [
        operatingSystemProvider.overrideWithValue('ohos'),
        hostedLinkStoreProvider.overrideWithValue(SecureHostedLinkStore(storage)),
        hostedShareClientProvider.overrideWithValue(
          HostedShareClient(client: host.client, origin: 'https://go.example'),
        ),
      ],
    );
    addTearDown(container.dispose);
    return (container, container.read(hostedLinksProvider.notifier), host);
  }

  test('a transient secure read failure preserves the list and next add reloads it', () async {
    final storage = FaultStorage([link('M000000099')])..readError = failure;
    final (container, links, _) = rig(storage);
    await links.ready;
    expect(container.read(hostedLinksProvider).loaded, isFalse);
    storage.readError = null;
    await links.add(link('M000000002'));
    expect(container.read(hostedLinksProvider).visible.map((l) => l.id), ['M000000002', 'M000000099']);
    expect((jsonDecode(storage.raw!) as List), hasLength(2));
  });
  testWidgets('a failed delete save keeps the row and schedules no remote delete', (tester) async {
    final storage = FaultStorage([link('M000000099')]);
    final (container, links, host) = rig(storage);
    await links.ready;
    storage.writeError = failure;
    await links.remove('M000000099');
    expect(container.read(hostedLinksProvider).visible.single.id, 'M000000099');
    await tester.pump(HostedLinksController.undoWindow + const Duration(seconds: 1));
    expect(host.requests, isEmpty);
  });
  test('read failure stops upload before creating a remote orphan', () async {
    final storage = FaultStorage([link('M000000099')])..readError = failure;
    final (_, links, host) = rig(storage);
    await links.ready;
    await expectLater(links.publish(Uint8List.fromList(utf8.encode('fixture')), title: 'new'), throwsA(anything));
    expect(host.requests, isEmpty);
    expect(storage.writes, 0);
  });

  testWidgets('undo cancels this run even when persisting its marker fails; retry clears it', (tester) async {
    final storage = FaultStorage([link('M000000099')]);
    final (container, links, host) = rig(storage);
    await links.ready;
    expect(await links.remove('M000000099'), isTrue);
    storage.writeError = failure;
    expect(await links.undo('M000000099'), HostedUndoResult.sessionOnly);
    expect(container.read(hostedLinksProvider).visible, hasLength(1));
    expect((jsonDecode(storage.raw!) as List).single['deleting'], true);
    await tester.pump(HostedLinksController.undoWindow + const Duration(seconds: 1));
    expect(host.requests, isEmpty);
    storage.writeError = null;
    expect(await links.retry(), isTrue);
    expect((jsonDecode(storage.raw!) as List).single['deleting'], isNot(true));
  });
  testWidgets('undo cancels the timer immediately while another local write is pending', (tester) async {
    final storage = FaultStorage([link('M000000099')]);
    final (container, links, host) = rig(storage);
    await links.ready;
    await links.remove('M000000099');
    final gate = Completer<void>();
    storage.writeGate = gate;
    final adding = links.add(link('M000000002'));
    await tester.pump();
    final undoing = links.undo('M000000099');
    await tester.pump(HostedLinksController.undoWindow + const Duration(seconds: 1));
    expect(host.requests, isEmpty);
    storage.writeGate = null;
    gate.complete();
    await adding;
    expect(await undoing, HostedUndoResult.restored);
    expect(container.read(hostedLinksProvider).visible, hasLength(2));
  });
  test('uploaded link remains usable with a saved-status warning and can be saved by retry', () async {
    final storage = FaultStorage([link('M000000099')]);
    final (container, links, host) = rig(storage);
    await links.ready;
    storage.writeError = failure;
    final created = await HostedConversationLinkMaker(links)
        .upload(Uint8List.fromList([1, 2]), LinkExpiry.month, title: 'new');
    expect(created.locallySaved, isFalse);
    expect(host.blobs, contains(created.id));
    expect(container.read(hostedLinksProvider).links, hasLength(2));
    storage.writeError = null;
    expect(await links.retry(), isTrue);
    expect((jsonDecode(storage.raw!) as List), hasLength(2));
  });
  test('a failed initial read can recover on the next publish', () async {
    final storage = FaultStorage([link('M000000099')])..readError = failure;
    final (_, links, host) = rig(storage);
    await links.ready;
    storage.readError = null;
    await links.publish(Uint8List.fromList([1]), title: 'retry');
    expect(host.blobs, hasLength(1));
    expect((jsonDecode(storage.raw!) as List), hasLength(2));
  });
  for (final sameId in [false, true]) {
    test(
      'hung DELETE permits add and its late result preserves ${sameId ? "a replacement with the same id" : "the new row"}',
      () async {
        final gate = Completer<http.Response>();
        final started = Completer<void>();
        final storage = FaultStorage([link('M000000099', deleting: true)]);
        final client = HostedShareClient(
          client: MockClient((request) {
            expect(request.method, 'DELETE');
            started.complete();
            return gate.future;
          }),
          origin: 'https://go.example',
        );
        final container = ProviderContainer(
          overrides: [
            operatingSystemProvider.overrideWithValue('ohos'),
            hostedLinkStoreProvider.overrideWithValue(SecureHostedLinkStore(storage)),
            hostedShareClientProvider.overrideWithValue(client),
          ],
        );
        addTearDown(container.dispose);
        final links = container.read(hostedLinksProvider.notifier);
        await links.ready;
        await started.future.timeout(const Duration(seconds: 5));
        final replacement = link(sameId ? 'M000000099' : 'M000000002');
        expect(await links.add(replacement).timeout(const Duration(seconds: 5)), isTrue);
        expect(gate.isCompleted, isFalse, reason: 'local add completed before HTTP DELETE');
        expect(await links.undo('M000000099'), HostedUndoResult.unavailable);
        gate.complete(http.Response('', 204));
        await Future<void>.delayed(Duration.zero);
        await links.retry();
        expect(container.read(hostedLinksProvider).links.single, same(replacement));
        expect((jsonDecode(storage.raw!) as List).single['id'], replacement.id);
      },
    );
  }
  test('a pending local save does not postpone the next normal upload', () async {
    final storage = FaultStorage([]);
    final (_, links, host) = rig(storage);
    await links.ready;
    final gate = Completer<void>();
    storage.writeGate = gate;
    final first = links.publish(Uint8List.fromList([1]), title: 'first');
    await Future<void>.delayed(Duration.zero);
    expect(storage.writes, 1);
    final second = links.publish(Uint8List.fromList([2]), title: 'second');
    await Future<void>.delayed(Duration.zero);
    expect(host.requests, hasLength(2), reason: 'HTTP upload must not wait for an unrelated local save');
    storage.writeGate = null;
    gate.complete();
    await Future.wait([first, second]);
    expect(jsonDecode(storage.raw!), hasLength(2));
  });
  test('two uploads start concurrently and local completion keeps both links', () async {
    final gates = [Completer<http.Response>(), Completer<http.Response>()];
    final started = Completer<void>();
    var count = 0;
    final storage = FaultStorage([]);
    final client = HostedShareClient(
      client: MockClient((request) {
        final index = count++;
        if (count == 2) started.complete();
        return gates[index].future;
      }),
      origin: 'https://go.example',
    );
    final container = ProviderContainer(
      overrides: [
        operatingSystemProvider.overrideWithValue('ohos'),
        hostedLinkStoreProvider.overrideWithValue(SecureHostedLinkStore(storage)),
        hostedShareClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(container.dispose);
    final links = container.read(hostedLinksProvider.notifier);
    await links.ready;
    final a = links.publish(Uint8List.fromList([1]), title: 'a');
    final b = links.publish(Uint8List.fromList([2]), title: 'b');
    await started.future.timeout(const Duration(seconds: 5));
    for (var i = 0; i < 2; i++) {
      gates[i].complete(
        http.Response(
          jsonEncode({
            'id': 'M00000000${i + 1}',
            'deleteToken': 'token-0123456789012345',
            'expiresAt': '2026-11-24T00:00:00Z',
          }),
          201,
        ),
      );
    }
    await Future.wait([a, b]);
    expect(container.read(hostedLinksProvider).links, hasLength(2));
    expect(jsonDecode(storage.raw!), hasLength(2));
  });
}
