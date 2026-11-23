import 'dart:io';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/phone/phone_channel.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/composer_insert.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/features_state.dart' show skillsProvider;
import 'package:dsh_app/state/media_generation.dart' show mediaPluginProvider, MediaPluginState;
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/phone_skill_use.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_sync_draft_test.dart' as fixture;
import 'support/harness.dart';
import 'support/session_sync_host.dart';

class _Local extends LocalConnectionController {
  _Local(this.connection);
  final HostConnection connection;
  @override
  Future<HostConnection?> build() async => connection;
}
class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

const _method = MethodChannel('dsh/phone');
const _revision = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _invocation = 'cccccccccccccccccccccccccccccccc';
const _text = 'Only replay this reviewed route: $_invocation';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(_method, null));

  Future<void> settleIo(WidgetTester tester, bool Function() ready) async {
    final deadline = Stopwatch()..start();
    while (!ready()) {
      if (deadline.elapsed >= const Duration(seconds: 4)) fail('Route RPC/UI completion did not arrive');
      // Yield to actual socket events; success is the RPC/UI condition, never an iteration count.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
  }

  final releaseCatalogs = Expando<void Function()>();
  final catalogGeneration = Expando<Object>();

  Future<void> drainCatalogs(WidgetTester tester, SyncHarness h) async {
    expect(identical(h.client.mux.generation, catalogGeneration[h]), isTrue,
      reason: 'Catalog cleanup must not read a replacement connection generation');
    expect(h.container.exists(skillsProvider('S')), isTrue);
    var done = false;
    Object? error;
    StackTrace? stack;
    final completion = h.container.read(skillsProvider('S').future).then<void>((_) { done = true; }, onError: (Object value, StackTrace trace) {
      error = value;
      stack = trace;
      done = true;
    });
    await settleIo(tester, () => done);
    await completion;
    if (error != null) Error.throwWithStackTrace(error!, stack!);
  }

  Future<void> disposeHarness(WidgetTester tester, SyncHarness h) async {
    try {
      await tester.pumpWidget(const SizedBox());
      // Join the real skills RPC before force-closing FakeDsh. Its pin keeps
      // the same provider alive after the widget listener leaves.
      if (releaseCatalogs[h] != null) await drainCatalogs(tester, h);
    } finally {
      try {
        releaseCatalogs[h]?.call();
      } finally {
        releaseCatalogs[h] = null;
        catalogGeneration[h] = null;
        await tester.runAsync(h.close);
      }
    }
    await tester.pump();
  }

  Future<SyncHarness> open(WidgetTester tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final ui = ChatHarness(session: 'S');
    late HostConnection connection;
    SessionFollowEpoch? observedEpoch;
    final overrides = [
      petScopedStateProvider.overrideWith((ref, scope) => const PetState()),
      // These are plain-text phone-route tests, not media generation tests.
      mediaPluginProvider.overrideWithValue(MediaPluginState.absent),
      for (final override in ui.overrides)
        if (override.origin != activeConnectionProvider && override.origin != chatProvider &&
            override.origin != localConnectionProvider) override,
      activeHostProvider.overrideWith(_Host.new),
      localConnectionProvider.overrideWith(() => _Local(connection)),
    ];
    final h = await tester.runAsync(() => HttpOverrides.runWithHttpOverrides(
      () => SyncHarness.start(overrides: overrides, observe: (event) {
        if (event is SessionSnapshotEvent) observedEpoch = event.followEpoch;
      }), RealSyncHttp()));
    if (h == null) fail('Loopback startup failed; see the original runAsync exception');
    try {
      connection = HostConnection(client: h.client, isLocal: true);
      await h.container.read(localConnectionProvider.future);
      h.host.handlers['skills/list'] = (_) => {'ok': true, 'value': {'skills': <Object?>[]}};
      catalogGeneration[h] = h.client.mux.generation!;
      final skills = h.container.listen(skillsProvider('S'), (_, _) {});
      releaseCatalogs[h] = skills.close;
      await fixture.mount(tester, h);
      await pumpFrames(tester);
      final epoch = observedEpoch;
      if (epoch == null) fail('The real follow did not publish its epoch');
      // Chat interaction starts a generation-shared GET / capability probe. Its
      // independent HTTP deadline is cancelled only by that request's finally,
      // not by closing the mux. Join the same production future before teardown.
      expect(epoch.isCurrent, isTrue);
      expect(identical(h.client.mux.generation, epoch.generation), isTrue);
      expect(h.host.indexHtml, isEmpty);
      var activationDone = false;
      bool? supported;
      final follows = h.follows.length;
      final activation = h.client.activateSessionForInteraction('S', epoch: epoch,
        allowed: () => identical(h.client.mux.generation, epoch.generation),
        onActivationChecked: (value) { supported = value; });
      final completed = activation.then((_) { activationDone = true; });
      await settleIo(tester, () => activationDone);
      await completed;
      // No supported Host release was established. A failed HTTP read also
      // joins the release future; neither case opens an auxiliary follow.
      expect(supported, isFalse); // null means stale/early refusal, not a joined probe.
      expect(await activation, isFalse);
      expect(h.follows.length, follows);
      await drainCatalogs(tester, h);
      return h;
    } catch (error, stack) {
      try {
        await disposeHarness(tester, h);
      } catch (cleanupError, cleanupStack) {
        FlutterError.reportError(FlutterErrorDetails(exception: cleanupError, stack: cleanupStack,
          context: ErrorDescription('while cleaning up the route composer fixture')));
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  PreparedPhoneSkill selection(SyncHarness h, {String invocation = _invocation}) => PreparedPhoneSkill(
    origin: PhoneSkillUseOrigin.capture(h.container, 'S')!, channel: PhoneChannel(), text: _text,
    ready: PhoneSkillReplayReady.parse({'kind': 'ready', 'revision': _revision,
      'invocation': invocation, 'parameterNames': []})!);

  testWidgets('prepared route card never enters ordinary input or saved draft and queues through real Chat', (tester) async {
    messenger.setMockMethodCallHandler(_method, (_) async => {'kind': 'discarded'});
    final h = await open(tester);
    try {
      await tester.enterText(find.byType(TextField), 'my ordinary draft');
      await tester.pump();
      h.container.read(composerInsertProvider.notifier).request(ComposerInsert.phoneRoute(selection(h)));
      await tester.pump();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'my ordinary draft');
      expect(h.container.read(draftStoreProvider).drafts['S']?.text, 'my ordinary draft');
      expect(find.text(_text), findsOneWidget);
      await tester.ensureVisible(find.text(appL10n.phoneSkillReplayQueue));
      await tester.tap(find.text(appL10n.phoneSkillReplayQueue));
      await tester.pump();
      await settleIo(tester, () => h.boundary.length == 1 && find.text(_text).evaluate().isEmpty);
      expect(h.boundary.single['endpoint'], 'session/prompt');
      expect((h.boundary.single['request'] as Map)['mode'], 'queue');
      expect(jsonEncode(h.boundary.single['request']), contains(_text));
      expect(jsonEncode(h.boundary.single['request']), isNot(contains('my ordinary draft')));
      expect(h.cancelledBackendRuns, isEmpty);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'my ordinary draft');
      expect(h.container.read(draftStoreProvider).drafts['S']?.text, 'my ordinary draft');
    } finally { await disposeHarness(tester, h); }
  });

  testWidgets('changing selection after preparation cannot silently restore old session or send', (tester) async {
    final discarded = <Object?>[];
    messenger.setMockMethodCallHandler(_method, (call) async {
      if (call.method == 'discardSkillReplay') discarded.add(call.arguments);
      return {'kind': 'discarded'};
    });
    final h = await open(tester);
    try {
      final prepared = selection(h);
      h.container.read(currentSessionProvider.notifier).select(null);
      h.container.read(composerInsertProvider.notifier).request(ComposerInsert.phoneRoute(prepared));
      await tester.pump();
      expect(h.container.read(currentSessionProvider), isNull);
      expect(find.text(_text), findsNothing);
      expect(h.boundary, isEmpty);
      expect(discarded, [{'invocation': _invocation}]);
    } finally { await disposeHarness(tester, h); }
  });

  testWidgets('replacing an unconsumed typed insert discards just its original invocation', (tester) async {
    final discarded = <Object?>[];
    messenger.setMockMethodCallHandler(_method, (call) async {
      if (call.method == 'discardSkillReplay') discarded.add(call.arguments);
      return {'kind': 'discarded'};
    });
    final h = await open(tester);
    try {
      // A separate container owns no Chat listener, so request replacement is
      // tested before any consumer takes responsibility for the first insert.
      final pending = ProviderContainer();
      try {
        pending.read(composerInsertProvider.notifier).request(ComposerInsert.phoneRoute(selection(h)));
        pending.read(composerInsertProvider.notifier).request(const ComposerInsert.skill('plain', sessionId: 'S'));
        await tester.pump();
        expect(discarded, [{'invocation': _invocation}]);
        expect(pending.read(composerInsertProvider), const ComposerInsert.skill('plain', sessionId: 'S'));
        expect(h.boundary, isEmpty);
      } finally { pending.dispose(); }
    } finally { await disposeHarness(tester, h); }
  });
}
