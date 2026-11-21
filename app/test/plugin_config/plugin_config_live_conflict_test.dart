// CR-33caa7c B1: a live field refused with 409 conflict (the entry changed
// since it was read). Over the real BridgePluginConfigApi, DshClient and the
// HTTP fake bridge. Started from the review's counterexample, where both edits
// went out against r1 four times and never landed.

import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_state.dart';
import 'package:dsh_app/state/plugins_state.dart' show installedPluginsProvider;
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../engine_settings/support.dart';
import 'fake_bridge.dart';

const _ns = 'speech-to-text-sensevoice';
const _language = FieldRef(_ns, ['language']);
const _threads = FieldRef(_ns, ['threads']);

void main() {
  late FakeBridgeHost host;
  late ProviderContainer c;
  late PluginConfigController controller;

  setUp(() async {
    host = await FakeBridgeHost.start();
    addTearDown(host.close);
    host.entries[_ns] = sensevoiceEntry();
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeBridgeHost.token, startMux: false);
    addTearDown(client.close);
    c = ProviderContainer(overrides: engineOverrides(client));
    addTearDown(c.dispose);
    final sub = c.listen(pluginConfigProvider, (_, _) {});
    addTearDown(sub.close);
    await c.read(pluginConfigProvider.future);
    // The plugin list is in and confirmed (the fake's voice-input bundle):
    // the entry is a plugin's, so its form is read (PLUGIN-CONFIG-ALLOW).
    await c.read(installedPluginsProvider.future);
    for (var i = 0; i < 500 && !(c.read(pluginConfigProvider).value?.isPlugin(_ns) ?? false); i++) {
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(c.read(pluginConfigProvider).value!.isPlugin(_ns), isTrue);
    controller = c.read(pluginConfigProvider.notifier);
    await controller.load(_ns);
  });

  List<Object?> revisions() => [for (final w in host.writes()) (w as Map)['revision']];
  PluginConfigState state() => c.read(pluginConfigProvider).value!;
  Object? shown(FieldRef field) => state().settingsFor(_ns).valueOf(field);

  test('another field changed elsewhere: the write re-reads and goes again with the new revision', () async {
    host.entries[_ns]!
      ..user = {'threads': 4}
      ..revision += 1;

    expect(await controller.set(_language, 'zh'), isTrue);
    expect(revisions(), ['r1', 'r2'], reason: 'the conflict re-read moves the revision on before the retry');
    expect(host.entries[_ns]!.user, {'threads': 4, 'language': 'zh'});
    expect(shown(_language), 'zh');
    expect(shown(_threads), 4);
    expect(state().errors, isEmpty);
    expect(state()[_ns]!.revision, 'r3');
  });

  test('the same field changed elsewhere: not overwritten, the Host’s value shows, with the reason', () async {
    host.entries[_ns]!
      ..user = {'language': 'ja'}
      ..revision += 1;

    expect(await controller.set(_language, 'zh'), isFalse);
    expect(revisions(), ['r1'], reason: 'no automatic second try over someone else’s value');
    expect(host.entries[_ns]!.user, {'language': 'ja'});
    expect(shown(_language), 'ja');
    expect(state().errors[_language.key], isNotNull);
    expect(state().saving, isEmpty);
    expect(state()[_ns]!.revision, 'r2', reason: 'what the re-read confirmed');
  });

  test('the next edit is not stuck on the old revision', () async {
    // After a conflict that was not retried …
    host.entries[_ns]!
      ..user = {'language': 'ja'}
      ..revision += 1;
    expect(await controller.set(_language, 'zh'), isFalse);
    // … the person picks again, against what the Host has now.
    expect(await controller.set(_language, 'en'), isTrue);
    expect(revisions(), ['r1', 'r2']);
    expect(host.entries[_ns]!.user, {'language': 'en'});

    // And after one that was: the review's sequence, two edits in a row.
    host.entries[_ns]!
      ..user = {'language': 'en', 'threads': 4}
      ..revision += 1;
    expect(await controller.set(_language, 'zh'), isTrue);
    expect(await controller.set(_language, 'ja'), isTrue);
    expect(revisions(), ['r1', 'r2', 'r3', 'r4', 'r5']);
    expect(host.entries[_ns]!.user, {'language': 'ja', 'threads': 4});
    expect(state().errors, isEmpty);
  });

  test('a re-read while a live write is in flight takes the Host’s form; the edit stays on top', () async {
    host.next = BridgeOutcome.lostAfterWrite; // written at once, answered late
    final writing = controller.set(_language, 'zh');
    for (var i = 0; i < 200 && host.writes().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await controller.refresh();
    expect(state()[_ns]!.revision, 'r2', reason: 'the confirmed base is what the Host said, not the revision sent');
    expect(shown(_language), 'zh');
    expect(await writing, isTrue);
    expect(state()[_ns]!.revision, 'r2');
    expect(shown(_language), 'zh');
  });

  // CR-e0b8ece B1: an edit already queued when the one before it met a
  // same-field conflict. Started from the review's counterexample, where the
  // second edit went out on the revision the first one's re-read confirmed and
  // overwrote 'ja' with 'en'.
  group('an edit waiting behind another goes out only on what the person saw', () {
    test('the same field changed elsewhere: the edit queued behind the refused one is not sent either', () async {
      host.entries[_ns]!
        ..user = {'language': 'ja'}
        ..revision += 1;
      // Both edits are made before either answer: the second one on top of
      // the first's 'zh', neither having seen 'ja'.
      final first = controller.set(_language, 'zh');
      expect(shown(_language), 'zh');
      final second = controller.set(_language, 'en');
      final outcomes = await Future.wait([first, second]);

      expect(outcomes, [false, false]);
      expect(revisions(), ['r1'], reason: 'nothing goes out on r2, which only the refusal confirmed');
      expect(host.entries[_ns]!.user, {'language': 'ja'});
      expect(shown(_language), 'ja');
      expect(state().errors[_language.key], isNotNull);
      expect(state().saving, isEmpty);
      expect(state().pending, isEmpty);

      // The person picks again, now on 'ja': that one goes out.
      expect(await controller.set(_language, 'en'), isTrue);
      expect(revisions(), ['r1', 'r2']);
      expect(host.entries[_ns]!.user, {'language': 'en'});
      expect(state().errors, isEmpty);
    });

    test('another field changed elsewhere: both queued edits land, the other field kept', () async {
      host.entries[_ns]!
        ..user = {'threads': 4}
        ..revision += 1;
      final outcomes = await Future.wait([controller.set(_language, 'zh'), controller.set(_language, 'en')]);
      expect(outcomes, [true, true]);
      expect(revisions(), ['r1', 'r2', 'r3']);
      expect(host.entries[_ns]!.user, {'threads': 4, 'language': 'en'});
      expect(shown(_language), 'en');
      expect(state().errors, isEmpty);
    });

    test('a queued edit of another live field still goes out after the refusal', () async {
      // Threads made live for this case: two live fields in one entry.
      final entry = sensevoiceEntry();
      (((entry.schema['refs']! as Map)['3']! as Map)['meta']! as Map)['volatile'] = true;
      host.entries[_ns] = entry;
      await controller.refresh();
      expect(state()[_ns]!.isLive(_threads.path), isTrue);
      expect(state()[_ns]!.revision, 'r1');
      entry
        ..user = {'language': 'ja'}
        ..revision += 1;

      final outcomes = await Future.wait([controller.set(_language, 'zh'), controller.set(_threads, 4)]);
      expect(outcomes, [false, true]);
      expect(revisions(), ['r1', 'r2']);
      expect(host.entries[_ns]!.user, {'language': 'ja', 'threads': 4});
    });
  });
}
