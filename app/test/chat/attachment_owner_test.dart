import 'dart:async';

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/composer_fakes.dart';
import 'support/harness.dart';

class _Connection extends Notifier<HostConnection?> {
  _Connection(this.initial);
  final HostConnection initial;
  @override
  HostConnection? build() => initial;
  void select(HostConnection? next) => state = next;
}

final _connectionProvider = NotifierProvider<_Connection, HostConnection?>(() => throw UnimplementedError());

class _PendingPicker extends FakePicker {
  final result = Completer<List<DraftAttachment>>();
  @override
  Future<PickedAttachments> pickFiles({int limit = maxAttachments, int heldBytes = 0}) {
    calls.add('files');
    return result.future.then((files) => PickedAttachments(files));
  }

  @override
  Future<List<DraftAttachment>> pickImages({required int limit}) {
    calls.add('images:$limit');
    return result.future;
  }

  @override
  Future<DraftAttachment?> takePhoto() {
    calls.add('camera');
    return result.future.then((files) => files.firstOrNull);
  }
}

// Uses the real DshMux handshake, with controlled frames and no socket.
class _HistoryCarrier extends FakeRpcCarrier {
  _HistoryCarrier() : super({});
  _HistoryLink? latest;
  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final link = _HistoryLink();
    latest = link;
    return link;
  }
}

class _HistoryLink implements DshMuxLink {
  late DshMuxFrameHandler frame;
  String? eventsId;
  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) => frame = onFrame;
  @override
  void open(String id, String endpoint, Map<String, Object?> payload) {
    if (endpoint != r'$events') return;
    eventsId = id;
  }

  void ready() => frame({
    'type': 'item',
    'streamId': eventsId!,
    'value': {
      'type': 'ready',
      'clientId': 'same-wire-id',
      'host': {'home': '/synthetic/home'},
    },
  });
  @override
  void cancel(String streamId) {}
  @override
  Future<void> close(int code, String reason) async {}
  @override
  void sendItem(String streamId, Object? value) {}
  @override
  void endUplink(String streamId) {}
}

class _Rig {
  _Rig({DshCarrier? carrier})
    : first = HostConnection(
        client: DshClient.withCarrier(
          carrier ?? FakeRpcCarrier({}),
          muxOptions: carrier is _HistoryCarrier ? const MuxOptions(retryCaps: [Duration.zero]) : const MuxOptions(),
        ),
        isLocal: true,
      );

  final picker = _PendingPicker();
  late final ChatHarness ui;
  final HostConnection first;
  final second = HostConnection(client: DshClient.withCarrier(FakeRpcCarrier({})), isLocal: true);
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    SharedPreferences.setMockInitialValues({});
    ui = ChatHarness(session: 'A', picker: picker);
    await tester.pumpWidget(
      testApp(
        const ChatScreen(),
        overrides: [
          for (final override in ui.overrides)
            if (override.origin != activeConnectionProvider) override,
          _connectionProvider.overrideWith(() => _Connection(first)),
          activeConnectionProvider.overrideWith((ref) => AsyncData(ref.watch(_connectionProvider))),
        ],
      ),
    );
    await pumpFrames(tester);
    container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!picker.result.isCompleted) picker.result.complete([]);
      await tester.pump();
      await first.client.close();
      await second.client.close();
    });
  }

  Future<void> menu(WidgetTester tester) async {
    await tester.tap(find.bySemanticsLabel('添加图片或文件'));
    await pumpFrames(tester);
  }

  Future<void> choose(WidgetTester tester, [String source = '文件']) async {
    await menu(tester);
    await tester.tap(find.text(source));
    await pumpFrames(tester);
    expect(picker.calls, isNotEmpty);
  }

  Future<void> session(WidgetTester tester, String? id) async {
    container.read(currentSessionProvider.notifier).select(id);
    await pumpFrames(tester);
  }

  Future<void> host(WidgetTester tester, HostConnection? connection) async {
    container.read(_connectionProvider.notifier).select(connection);
    await pumpFrames(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    picker.result.complete([
      DraftAttachment.sniff('private-selection.txt', Uint8List.fromList('synthetic contents'.codeUnits)),
    ]);
    await pumpFrames(tester);
  }

  void noAttachment() {
    expect(find.text('private-selection.txt'), findsNothing);
    expect(
      container.read(draftStoreProvider).drafts.values.expand((draft) => draft.attachments),
      isEmpty,
      reason: 'a retired selection is not reassigned or saved into another draft',
    );
  }
}

class _LocalConnection extends LocalConnectionController {
  _LocalConnection(this.connection);
  final HostConnection connection;
  @override
  Future<HostConnection?> build() async => connection;
}

void main() {
  for (final stage in ['menu', 'success', 'failure', 'same-host']) {
    testWidgets('real Host selection cannot revive a new-draft attachment at $stage', (tester) async {
      usePhoneView(tester);
      mockClipboard(tester);
      SharedPreferences.setMockInitialValues({});
      final picker = _PendingPicker();
      final ui = ChatHarness(picker: picker);
      final connection = HostConnection(client: DshClient.withCarrier(FakeRpcCarrier({})), isLocal: true);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        if (!picker.result.isCompleted) picker.result.complete([]);
        await tester.pump();
        await connection.client.close();
      });
      await tester.pumpWidget(
        testApp(
          const ChatScreen(),
          overrides: [
            for (final override in ui.overrides)
              if (override.origin != activeConnectionProvider && override.origin != localConnectionProvider) override,
            localConnectionProvider.overrideWith(() => _LocalConnection(connection)),
          ],
        ),
      );
      await pumpFrames(tester);
      final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
      expect(container.read(currentSessionProvider), isNull);
      expect(container.read(activeHostProvider), HostRef.local);
      expect(identical(container.read(activeConnectionProvider).value!.client, connection.client), isTrue);
      await tester.tap(find.bySemanticsLabel('添加图片或文件'));
      await pumpFrames(tester);
      if (stage != 'menu') {
        await tester.tap(find.text('文件'));
        await pumpFrames(tester);
        expect(picker.calls, ['files']);
      }
      final host = container.read(activeHostProvider.notifier);
      if (stage != 'same-host') host.select(const HostRef.relay('synthetic-unused-host'));
      host.select(HostRef.local);
      expect(container.read(currentSessionProvider), isNull);
      if (stage == 'menu') {
        await tester.tap(find.text('文件'));
        await pumpFrames(tester);
        expect(picker.calls, isEmpty);
      } else if (stage == 'failure') {
        picker.result.completeError(PlatformException(code: 'permission_denied'));
        await pumpFrames(tester);
        expect(find.byType(SnackBar), findsNothing);
      } else {
        picker.result.complete([
          DraftAttachment.sniff('host-selection.txt', Uint8List.fromList([1, 2, 3])),
        ]);
        await pumpFrames(tester);
        expect(find.text('host-selection.txt'), stage == 'same-host' ? findsOneWidget : findsNothing);
      }
      if (stage != 'same-host') {
        expect(container.read(draftStoreProvider).drafts.values.expand((draft) => draft.attachments), isEmpty);
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final destination in <String?>['B', null]) {
    testWidgets('a file chosen for A does not land in session $destination', (tester) async {
      final rig = _Rig();
      await rig.pump(tester);
      await rig.choose(tester);
      await rig.session(tester, destination);
      await rig.finish(tester);
      rig.noAttachment();
    });
  }

  testWidgets('switching A to B and back cannot revive the old selection', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await rig.choose(tester);
    await rig.session(tester, 'B');
    await rig.session(tester, 'A');
    await rig.finish(tester);
    rig.noAttachment();
  });

  testWidgets('a replacement host with the same session ID cannot receive the file', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await rig.choose(tester);
    await rig.host(tester, rig.second);
    await rig.finish(tester);
    rig.noAttachment();
  });

  testWidgets('a disconnect and reconnect cannot revive the pending selection', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await rig.choose(tester);
    await rig.host(tester, null);
    await rig.host(tester, rig.first);
    await rig.finish(tester);
    rig.noAttachment();
  });

  testWidgets('a new mux generation on the same client retires the selection', (tester) async {
    final carrier = _HistoryCarrier();
    final rig = _Rig(carrier: carrier);
    await rig.pump(tester);
    final started = rig.first.client.mux.ready();
    await tester.pump();
    final link = carrier.latest!;
    expect(link.eventsId, isNotNull);
    link.ready();
    await tester.pump();
    await started;
    await rig.choose(tester);
    rig.first.client.mux.reconnect();
    await tester.pump(const Duration(milliseconds: 1));
    final next = carrier.latest!;
    expect(identical(next, link), isFalse);
    expect(next.eventsId, isNotNull);
    next.ready();
    expect(rig.first.client.mux.generation!.number, 2);
    await rig.finish(tester);
    rig.noAttachment();
  });

  testWidgets('a send that did not go out comes back after a new mux generation on the same client', (tester) async {
    // #1416: the upload settled after the reconnect, so the prompt was never sent.
    final carrier = _HistoryCarrier();
    final rig = _Rig(carrier: carrier);
    await rig.pump(tester);
    final started = rig.first.client.mux.ready();
    await tester.pump();
    carrier.latest!.ready();
    await tester.pump();
    await started;
    final result = Completer<bool>();
    rig.ui.controllers['A']!.sendResult = result.future;
    await tester.enterText(find.byType(TextField), '没发出去的那句');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await tester.pump();
    String composer() => tester.widget<TextField>(find.byType(TextField)).controller!.text;
    expect(composer(), isEmpty);
    rig.first.client.mux.reconnect();
    await tester.pump(const Duration(milliseconds: 1));
    carrier.latest!.ready();
    expect(rig.first.client.mux.generation!.number, 2);
    result.complete(false);
    await pumpFrames(tester);
    expect(composer(), '没发出去的那句');
  });

  testWidgets('null to ready to null cannot hide a mux generation change', (tester) async {
    final carrier = _HistoryCarrier();
    final rig = _Rig(carrier: carrier);
    await rig.pump(tester);
    expect(rig.first.client.mux.generation, isNull);
    await rig.choose(tester);
    final started = rig.first.client.mux.ready();
    await tester.pump();
    final link = carrier.latest!;
    expect(link.eventsId, isNotNull);
    link.ready();
    await tester.pump();
    await started;
    final closed = rig.first.client.close();
    await tester.pump();
    await closed;
    expect(rig.first.client.mux.generation, isNull);
    expect(rig.first.client.mux.lastReadyGenerationNumber, 1);
    await rig.finish(tester);
    rig.noAttachment();
  });

  testWidgets('a retired menu does not launch the system picker', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await rig.menu(tester);
    await rig.session(tester, 'B');
    await tester.tap(find.text('文件'));
    await pumpFrames(tester);
    expect(rig.picker.calls, isEmpty);
  });

  for (final permission in [false, true]) {
    testWidgets('a retired ${permission ? 'permission' : 'read'} error stays out of the new session', (tester) async {
      final rig = _Rig();
      await rig.pump(tester);
      await rig.choose(tester);
      await rig.session(tester, 'B');
      rig.picker.result.completeError(
        permission ? PlatformException(code: 'permission_denied') : StateError('synthetic late read'),
      );
      await pumpFrames(tester);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final source in ['文件', '相册', '拍照']) {
    testWidgets('the current $source selection still reaches the current draft', (tester) async {
      final rig = _Rig();
      await rig.pump(tester);
      await rig.choose(tester, source);
      await rig.finish(tester);
      expect(find.text('private-selection.txt'), findsOneWidget);
      expect(_containerDraft(rig).single.name, 'private-selection.txt');
    });
  }

  testWidgets('typing in the same draft while picking does not retire it', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await rig.choose(tester);
    await tester.enterText(find.byType(TextField), 'still the same draft');
    await rig.finish(tester);
    expect(find.text('private-selection.txt'), findsOneWidget);
    expect(rig.container.read(draftStoreProvider).drafts['A']!.text, 'still the same draft');
  });

  testWidgets('a failure still shows feedback for the current selection', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await rig.choose(tester);
    rig.picker.result.completeError(PlatformException(code: 'permission_denied'));
    await pumpFrames(tester);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

List<DraftAttachment> _containerDraft(_Rig rig) => rig.container.read(draftStoreProvider).drafts['A']!.attachments;
