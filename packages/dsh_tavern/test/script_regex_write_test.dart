import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

ScriptJson _rule(String name, String find, String replacement) => <String, Object?>{
  'id': 'same-st-id',
  'scriptName': name,
  'findRegex': find,
  'replaceString': replacement,
  'trimStrings': <String>[],
  'placement': [RegexPlacement.slashCommand],
  'disabled': false,
  'promptOnly': true,
  'foreign_rule': <String, Object?>{'keep': name},
};

List<ScriptJson> _rows(Object? value) => (value! as List<Object?>).cast<ScriptJson>();

void main() {
  test('regex writes keep physical identity, whole CAS, real origins and ready execution', () async {
    final h = await ScriptFixture.open();
    final firstRaw = _rule('first', '/A/g', 'B');
    final secondRaw = _rule('second', '/B/g', 'C');
    final sourceText = jsonEncode([firstRaw, secondRaw]);
    final imported = await h.engine.importRegexScripts(sourceText);
    final firstId = imported.scripts[0].id;
    final secondId = imported.scripts[1].id;
    expect(firstId, isNot(secondId));
    final characterId = await h.card(
      'Regex identity',
      extensions: <String, Object?>{
        'foreign_character': <String, Object?>{'keep': true},
        'regex_scripts': [_rule('card', '/P/g', 'K')],
      },
    );
    final chatId = await h.engine.createChat(characterId);
    final presetId = (await h.engine.listPresets()).single.id;
    await h.engine.updatePreset(presetId, <String, Object?>{
      'extensions': <String, Object?>{
        'foreign_preset': <String, Object?>{'keep': true},
        'regex_scripts': [_rule('preset', '/C/g', 'P')],
      },
    });
    await h.engine.setSettings(<String, Object?>{
      'globalRegexScripts': [_rule('inline', '/X/g', 'A')],
      'regex': [_rule('shadow', '/X/g', 'Z')],
      'foreign_settings': <String, Object?>{'keep': true},
    });
    final host = ScriptHost();
    final nativeAdoption = Completer<void>();
    ScriptJson? cachedRegex;
    host.onDispatch = (request, cancellation) async {
      final value = request.delta?.resourceRefs['regex'];
      if (value is ScriptJson) {
        cachedRegex = value;
        if (!nativeAdoption.isCompleted &&
            _rows(value['rules']).any((row) => row['engineId'] == firstId && row['effective'] == false)) {
          nativeAdoption.complete();
        }
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    final initialContext = await h.context(chatId);
    const libraryTarget = TavernScriptRegexWriteTarget.globalLibrary();
    final stale = await h.bridge.readTavernRegexesForWrite(initialContext.id, libraryTarget);
    final file = File('${h.root.path}/regex-library.json');
    await h.engine.setRegexEnabled(firstId, false);
    await nativeAdoption.future;
    final afterNative = await file.readAsString();
    await expectLater(
      h.bridge.replaceTavernRegexes(initialContext.id, libraryTarget, stale.items, expectedVersion: stale.version),
      throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
    );
    expect(await file.readAsString(), afterNative);
    await h.engine.setRegexEnabled(firstId, true);

    // Real future fields in the physical library must survive the new whole
    // writer. Reopen makes the same file its native runtime input.
    await h.reopen(
      whileClosed: () async {
        final document = scriptMap(jsonDecode(await file.readAsString()));
        document['foreign_root'] = <String, Object?>{
          'keep': [1, null],
        };
        for (final row in _rows(document['scripts'])) {
          row['foreign_record'] = <String, Object?>{'owner': row['id']};
        }
        await file.writeAsString(jsonEncode(document), flush: true);
      },
    );
    h.bridge.attachHost(host);
    final context = await h.context(chatId, instanceId: 'regex-reopened');
    final physicalBefore = scriptMap(jsonDecode(await file.readAsString()));
    final beforeById = {for (final row in _rows(physicalBefore['scripts'])) row['id']! as String: row};
    Future<String> format() async => (await h.bridge.formatAsTavernRegexedString(
      context.id,
      'X',
      source: RegexPlacement.slashCommand,
      destination: RegexPhase.prompt,
    )).text;
    expect(await format(), 'K');

    final before = await h.bridge.readTavernRegexesForWrite(context.id, libraryTarget);
    final reordered = await h.bridge.replaceTavernRegexes(context.id, libraryTarget, [
      before.items.singleWhere((item) => item.engineId == secondId),
      before.items.singleWhere((item) => item.engineId == firstId),
    ], expectedVersion: before.version);
    expect(reordered.items.map((item) => item.engineId), [secondId, firstId]);
    expect(await format(), 'B');
    var query = await h.bridge.getTavernRegexes(
      context.id,
      TavernScriptRegexQuery(sources: {TavernScriptRegexSource.global}),
    );
    expect(query.where((rule) => rule.sourceRef['kind'] == 'managedGlobal').map((rule) => rule.engineId), [
      secondId,
      firstId,
    ]);
    expect(query.where((rule) => rule.engineId != null).map((rule) => rule.stId), ['same-st-id', 'same-st-id']);

    final invalid = <String, Object?>{
      ...reordered.items.singleWhere((item) => item.engineId == firstId).raw,
      'findRegex': '/[/g',
    };
    final checked = await h.bridge.replaceTavernRegexes(context.id, libraryTarget, [
      reordered.items.singleWhere((item) => item.engineId == secondId),
      TavernScriptRegexWriteItem(engineId: firstId, raw: invalid),
    ], expectedVersion: reordered.version);
    expect(checked.diagnostics.any((issue) => issue.status == TavernRegexCompatibility.incompatible), isTrue);
    query = await h.bridge.getTavernRegexes(
      context.id,
      TavernScriptRegexQuery(sources: {TavernScriptRegexSource.global}),
    );
    final invalidView = query.singleWhere((rule) => rule.engineId == firstId);
    expect(invalidView.raw['disabled'], isFalse);
    expect(invalidView.enabled, isTrue);
    expect(invalidView.effective, isFalse);
    expect(await format(), 'A');
    final physicalAfter = scriptMap(jsonDecode(await file.readAsString()));
    expect(physicalAfter['foreign_root'], physicalBefore['foreign_root']);
    expect(_rows(physicalAfter['scripts']).map((row) => row['id']), [secondId, firstId]);
    for (final row in _rows(physicalAfter['scripts'])) {
      final old = beforeById[row['id']]!;
      expect(row['sourceText'], old['sourceText']);
      expect(row['sourceText'], sourceText);
      expect(row['importedAt'], old['importedAt']);
      expect(row['foreign_record'], old['foreign_record']);
    }

    // The chat null masks A, so execution sees the root's shadow B field.
    // That real root origin still cannot be written through the A target.
    await h.engine.setSettings(<String, Object?>{'globalRegexScripts': null}, chatId: chatId);
    query = await h.bridge.getTavernRegexes(
      context.id,
      TavernScriptRegexQuery(sources: {TavernScriptRegexSource.global}),
    );
    final shadow = query.singleWhere((rule) => rule.sourceRef['kind'] == 'inlineGlobal');
    expect(shadow.sourceRef['scope'], 'global');
    expect(shadow.sourceRef['field'], 'regex');
    expect(shadow.sourceRef.containsKey('writeTarget'), isFalse);
    expect(await format(), 'Z');
    const inlineTarget = TavernScriptRegexWriteTarget.globalInline();
    final inlineBefore = await h.bridge.readTavernRegexesForWrite(context.id, inlineTarget);
    expect(inlineBefore.source['field'], 'globalRegexScripts');
    expect(inlineBefore.items.single.raw['replaceString'], 'A');
    await h.engine.setSettings(<String, Object?>{
      'regex': [_rule('shadow', '/X/g', 'Y')],
    });
    await expectLater(
      h.bridge.replaceTavernRegexes(
        context.id,
        inlineTarget,
        inlineBefore.items,
        expectedVersion: inlineBefore.version,
      ),
      throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
    );
    final inlineCurrent = await h.bridge.readTavernRegexesForWrite(context.id, inlineTarget);
    await h.bridge.replaceTavernRegexes(context.id, inlineTarget, [
      TavernScriptRegexWriteItem(raw: _rule('inline', '/X/g', 'Q')),
    ], expectedVersion: inlineCurrent.version);
    final settings = scriptMap((await h.settingsDocument())['settings']);
    expect(_rows(settings['globalRegexScripts']).single['replaceString'], 'Q');
    expect(_rows(settings['regex']).single['replaceString'], 'Y');
    expect(settings['foreign_settings'], <String, Object?>{'keep': true});
    expect(await format(), 'Y');

    // Both preset targets delegate to the real carrier writer. A current
    // regex edit must not replace its saved source or claim sampling fields.
    final storedRef = TavernScriptPresetRef.stored(presetId);
    final storedTarget = TavernScriptRegexWriteTarget.preset(preset: storedRef);
    final storedBefore = await h.bridge.readTavernRegexesForWrite(context.id, storedTarget);
    await h.bridge.replaceTavernRegexes(context.id, storedTarget, [
      TavernScriptRegexWriteItem(raw: _rule('stored', '/C/g', 'S')),
    ], expectedVersion: storedBefore.version);
    const currentTarget = TavernScriptRegexWriteTarget.preset(preset: TavernScriptPresetRef.current());
    final currentBefore = await h.bridge.readTavernRegexesForWrite(context.id, currentTarget);
    final beforeWorkingView = await h.bridge.snapshot(context.id);
    final beforeWorkingRegex = scriptMap(beforeWorkingView.resourceRefs['regex']);
    expect(scriptMap((await h.bridge.snapshot(context.id)).resourceRefs['regex']), beforeWorkingRegex);
    await h.bridge.replaceTavernRegexes(context.id, currentTarget, [
      TavernScriptRegexWriteItem(raw: _rule('working', '/Y/g', 'P')),
    ], expectedVersion: currentBefore.version);
    final workingView = await h.bridge.snapshot(context.id);
    final workingRegex = scriptMap(workingView.resourceRefs['regex']);
    final workingRule = _rows(workingRegex['rules']).singleWhere((row) => row['source'] == 'preset');
    expect(scriptMap(workingRule['raw'])['replaceString'], 'P');
    expect(workingRegex['version'], isNot(beforeWorkingRegex['version']));
    expect(scriptMap(beforeWorkingView.resourceRefs['regex']), beforeWorkingRegex);
    final savedPreset = await h.bridge.readPreset(context.id, storedRef);
    final savedExtensions = scriptMap(savedPreset.raw['extensions']);
    expect(_rows(savedExtensions['regex_scripts']).single['replaceString'], 'S');
    expect(savedExtensions['foreign_preset'], <String, Object?>{'keep': true});
    final currentPreset = await h.bridge.readPreset(context.id, const TavernScriptPresetRef.current());
    expect(currentPreset.source['kind'], 'current');
    expect(currentPreset.source['working'], isTrue);
    expect(currentPreset.raw['temperature'], 0.4);

    final cardTarget = TavernScriptRegexWriteTarget.character(characterId: characterId);
    final cardBefore = await h.bridge.readTavernRegexesForWrite(context.id, cardTarget);
    await h.bridge.replaceTavernRegexes(context.id, cardTarget, [
      TavernScriptRegexWriteItem(raw: _rule('card', '/P/g', 'FINAL')),
    ], expectedVersion: cardBefore.version);
    expect(await format(), 'FINAL');
    final snapshot = await h.bridge.snapshot(context.id);
    final cardView = scriptMap(snapshot.resourceRefs['characterData']);
    final cardExtensions = scriptMap(scriptMap(cardView['data'])['extensions']);
    expect(cardExtensions['foreign_character'], <String, Object?>{'keep': true});
    final ready = scriptMap(snapshot.resourceRefs['regex']);
    expect(cachedRegex, equals(ready));
    final readyRules = _rows(ready['rules']);
    expect(readyRules.singleWhere((row) => row['engineId'] == firstId)['effective'], isFalse);
    final readyInline = readyRules.singleWhere((row) => scriptMap(row['sourceRef'])['kind'] == 'inlineGlobal');
    expect(scriptMap(readyInline['sourceRef']).containsKey('writeTarget'), isFalse);
    final readyPreset = readyRules.singleWhere((row) => scriptMap(row['sourceRef'])['kind'] == 'preset');
    expect(scriptMap(scriptMap(readyPreset['sourceRef'])['presetSource'])['kind'], 'current');
    expect(scriptMap(snapshot.resourceRefs['preset'])['version'], currentPreset.version);
    h.expectNoGeneration();
  });
}
