import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  for (final cancel in [false, true]) {
    test('log-only observation preserves synchronous resume and tail adoption, cancel=$cancel', () async {
      final h = await T24Harness.open();
      addTearDown(h.dispose);
      await h.engine.setPreset(
        ChatPreset({
          ...t24Preset().raw,
          'extensions': {
            'SPreset': {
              'LogUpload': {'enabled': true},
            },
          },
        }),
      );
      await h.engine.setSettings({'spresetLogUploadEnabled': true});
      final call = h.model.prepare();
      final first = T24Events(h.engine.send(h.chatId, 'question'));
      await call.listening.future;
      call.add(const ModelText('before'));
      call.add(const ModelReasoning('thought'));
      await first.detach();
      call.add(const ModelText('-away'));
      call.add(const ModelReasoning('-away'));
      final resumed = T24Events(h.engine.resumeTurn(h.chatId));
      call.add(const ModelText('-tail'));
      call.add(const ModelReasoning('-tail'));
      if (cancel) {
        h.engine.stop(h.chatId);
      } else {
        await call.finish();
      }
      await resumed.done.future;
      final snapshot = resumed.values.first as TavernTurnSnapshot;
      expect(snapshot.message!.text, 'before-away');
      expect(snapshot.message!.reasoning, 'thought-away');
      final saved = (await h.engine.path(h.chatId)).last;
      expect(saved.text, 'before-away-tail');
      expect(saved.reasoning, 'thought-away-tail');
      final report = await h.engine.exportSPresetLogs(h.chatId);
      final records = report['records']! as List<Object?>;
      expect(records, hasLength(1));
      final response = (records.single! as Map<String, Object?>)['response']! as Map<String, Object?>;
      expect(response['text'], 'before-away-tail');
    });
  }

  for (final setting in [
    (name: 'App default off', appEnabled: false, moduleEnabled: true, external: false),
    (name: 'preset module off', appEnabled: true, moduleEnabled: false, external: false),
    (name: 'external runtime', appEnabled: true, moduleEnabled: true, external: true),
  ]) {
    test('native logging does not collect when ${setting.name}', () async {
      final h = await T24Harness.open();
      addTearDown(h.dispose);
      await h.engine.setPreset(
        ChatPreset({
          ...t24Preset().raw,
          'extensions': {
            'SPreset': {
              'LogUpload': {'enabled': setting.moduleEnabled},
            },
          },
        }),
      );
      await h.engine.setSettings({
        if (setting.appEnabled) 'spresetLogUploadEnabled': true,
        if (setting.external) 'spresetRuntimeMode': 'external',
      });
      final call = h.model.prepare();
      final events = T24Events(h.engine.send(h.chatId, 'question'));
      await call.listening.future;
      call.add(const ModelText('answer'));
      await call.finish();
      await events.done.future;
      expect((await h.engine.path(h.chatId)).last.text, 'answer');
      expect((await h.engine.exportSPresetLogs(h.chatId))['records'], isEmpty);
    });
  }

  test('App log snapshots are captured on entry, redacted and explicitly optional', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final helper = <String, Object?>{
      'available': true,
      'entries': [
        {'id': 'fixture-script', 'configuredEnabled': true, 'runtimePresent': false},
      ],
      'api_key': 'fixture-secret',
      'authToken': 'fixture-auth-secret',
      'json': '{"authToken":"fixture-json-secret"}',
    };
    final console = <String, Object?>{
      'events': [
        {
          'level': 'warn',
          'args': [
            'https://fixture.invalid/?token=fixture-secret',
            'inline Bearer fixture-bearer-secret',
            'Basic Zml4dHVyZTpzZWNyZXQ=',
          ],
        },
      ],
    };
    final pending = h.engine.exportSPresetLogs(h.chatId, tavernHelper: helper, browserConsole: console);
    (helper['entries']! as List).clear();
    (console['events']! as List).clear();
    final report = await pending;
    final savedHelper = report['tavernHelper']! as Map<String, Object?>;
    expect(savedHelper['entries'], hasLength(1));
    expect(savedHelper['api_key'], '[REDACTED]');
    final savedConsole = report['browserConsole']! as Map<String, Object?>;
    expect(savedConsole['events'], hasLength(1));
    expect(jsonEncode(report), isNot(contains('fixture-secret')));
    for (final secret in [
      'fixture-auth-secret',
      'fixture-json-secret',
      'fixture-bearer-secret',
      'Zml4dHVyZTpzZWNyZXQ=',
    ]) {
      expect(jsonEncode(report), isNot(contains(secret)));
    }
    savedHelper['available'] = false;
    expect(helper['available'], isTrue);
    final absent = await h.engine.exportSPresetLogs(h.chatId);
    expect((absent['tavernHelper']! as Map)['available'], isFalse);
    expect((absent['browserConsole']! as Map)['available'], isFalse);
  });

  test('HTTP log cap counts decoded UTF-16 units across split UTF-8 chunks', () {
    const limit = 1024 * 1024;
    final cjk = '猫' * limit;
    final bytes = utf8.encode('$cjk🌊');
    final capture = SPresetResponseLogCapture()
      ..add(bytes.sublist(0, 1))
      ..add(bytes.sublist(1, 7))
      ..add(bytes.sublist(7));
    final result = capture.finish();
    expect(result.text, cjk);
    expect(result.truncated, isTrue);

    final edge = SPresetResponseLogCapture()..add(utf8.encode('${'A' * (limit - 1)}🌊'));
    final edgeResult = edge.finish();
    expect(edgeResult.text.length, limit);
    expect(edgeResult.text.codeUnits.last, 0xd83c);
    expect(edgeResult.truncated, isTrue);

    final incomplete = SPresetResponseLogCapture()..add([0xf0, 0x9f]);
    expect(incomplete.finish().text, '\uFFFD');
  });
}
