import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

const _url = 'https://fixture.invalid/image.png';
const _png = 'data:image/png;base64,AQ==';
const _otherPng = 'data:image/png;base64,Ag==';
const _marker = '__IMG_ARRAY_MARKER_';

void main() {
  final oracle =
      jsonDecode(File('test/fixtures/w11_helper_image_conversion_source.json').readAsStringSync()) as ScriptJson;
  final sourceCases = {
    for (final row in (oracle['results']! as List<Object?>).cast<ScriptJson>()) row['name']! as String: row,
  };
  for (final array in [false, true]) {
    test('normal ${array ? 'array READY' : 'single'} resolution follows its actual source macro/WI phase', () async {
      final h = await generationFixture();
      var macroCalls = 0;
      h.onRandom = () => macroCalls++;
      await h.engine.setPreset(scriptPreset(main: 'PROMPT{{random::a::b}}'));
      final context = await _normalContext(h, macros: true);
      int? atResolve;
      final host = _ImageHost((source, token) async {
        atResolve = macroCalls;
        return 'invalid resolver protocol result';
      });
      h.bridge.attachHost(host);
      final generation = await h.bridge.generate(
        context.id,
        TavernHelperGenerateRequest.fromJson({
          'user_input': 'Q{{random::a::b}}',
          'image': array ? [_url] : _url,
          'should_silence': true,
        }),
      );
      final failure = await generationFailure(generation);
      expect(failure.code, TavernScriptErrorCode.invalidArgument);
      expect(failure.fieldPath, 'image');
      expect(atResolve, array ? 4 : 3, reason: 'Input and character, then WI; only arrays wait for prompt macros.');
      expect(h.requests, isEmpty);
    });
  }

  test('normal missing marker is a warning success with zero resolver calls', () async {
    final h = await generationFixture();
    await h.engine.setPreset(_layout(history: false));
    final context = await _normalContext(h);
    final host = _ImageHost((source, token) async => throw StateError('The absent marker must not resolve.'));
    h.bridge.attachHost(host);
    final plan = h.reply('MODEL');
    final generation = await h.bridge.generate(
      context.id,
      TavernHelperGenerateRequest.fromJson({
        'user_input': 'Q',
        'image': [_url],
        'should_silence': true,
      }),
    );
    final wire = await generationRequest(generation, plan);
    final result = await generation.result;
    expect(result.text, 'MODEL');
    expect(host.sources, isEmpty);
    expect(result.hookIssues.where((issue) => issue.code == 'helperImageMarkerMissing'), hasLength(1));
    expect(generationMessages(wire), [
      {'role': 'system', 'content': 'SYSTEM'},
    ]);
  });

  test('normal marker must belong to a user string and only the last user match is converted', () async {
    for (final role in ['assistant', 'user']) {
      final h = await generationFixture();
      await h.engine.setPreset(_layout(history: role == 'user', markerRole: role));
      final context = await _normalContext(h);
      final host = _ImageHost((source, token) async => _png);
      h.bridge.attachHost(host);
      final plan = h.reply('MODEL');
      final generation = await h.bridge.generate(
        context.id,
        TavernHelperGenerateRequest.fromJson({
          'user_input': 'Q',
          'image': [_url],
          'should_silence': true,
        }),
      );
      final wire = await generationRequest(generation, plan);
      final result = await generation.result;
      final messages = generationMessages(wire);
      expect(messages.any((row) => row['content'] == 'OLD$_marker'), isTrue);
      if (role == 'assistant') {
        expect(host.sources, isEmpty);
        expect(result.hookIssues.where((issue) => issue.code == 'helperImageMarkerMissing'), hasLength(1));
      } else {
        expect(host.sources, [_url]);
        expect(messages.last['content'], [
          {'type': 'text', 'text': 'Q'},
          {
            'type': 'image_url',
            'image_url': {'url': _png, 'detail': 'low'},
          },
        ]);
      }
    }
  });

  test('normal array marker participates in WI before READY but not in final user text', () async {
    final h = await generationFixture();
    final context = await _normalContext(h);
    await h.engine.putLorebook('array-marker-scan', _book('MARKER ACTIVATED', key: _marker));
    await h.engine.bindLorebooks(['array-marker-scan']);
    final host = _ImageHost((source, token) async => _png);
    h.bridge.attachHost(host);
    final plan = h.reply('MODEL');
    final generation = await h.bridge.generate(
      context.id,
      TavernHelperGenerateRequest.fromJson({
        'user_input': 'Q',
        'image': [_url],
        'should_silence': true,
      }),
    );
    final wire = await generationRequest(generation, plan);
    await generation.result;
    expect(jsonEncode(wire.body), contains('MARKER ACTIVATED'));
    expect(jsonEncode(wire.body), isNot(contains(_marker)));
  });

  for (final array in [false, true]) {
    test('raw system admission ${array ? 'follows early arrays' : 'precedes single image resolution'}', () async {
      final h = await generationFixture();
      await h.engine.setPreset(ChatPreset({...scriptPreset().raw, 'openai_max_context': 100, 'openai_max_tokens': 10}));
      final host = _ImageHost((source, token) async => _png);
      h.bridge.attachHost(host);
      final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'raw-budget-image'));
      final generation = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'user_input': 'Q',
          'image': array ? [_url] : _url,
          'ordered_prompts': [
            {'role': 'system', 'content': List.filled(10000, 'overlarge ').join()},
            'user_input',
          ],
          'overrides': {
            'chat_history': {'prompts': [], 'with_depth_entries': false},
          },
        }),
      );
      final failure = await generationFailure(generation);
      expect(failure.modelFailure, TavernFailure.contextTooLong);
      expect(host.sources, array ? [_url] : isEmpty);
      expect(h.requests, isEmpty);
    });
  }

  for (final raw in [false, true]) {
    for (final stage in TavernHelperImageConversionStage.values) {
      test(
        '${raw ? 'raw' : 'normal'} single ${stage.name} failure follows source undefined with a visible issue',
        () async {
          final h = await generationFixture();
          final context = await _normalContext(h);
          final host = _ImageHost((source, token) async => throw _failure(stage));
          h.bridge.attachHost(host);
          final plan = h.reply('MODEL');
          final generation = await _generate(h, context.id, raw: raw, image: _url);
          final wire = await generationRequest(generation, plan);
          final result = await generation.result;
          expect(result.text, 'MODEL');
          expect(host.sources, [_url]);
          expect(generationMessages(wire).last['content'], 'Q');
          expect(jsonEncode(wire.body), isNot(contains('image_url')));
          final issue = result.hookIssues.singleWhere((issue) => issue.code == 'helperImageConversionFailed');
          expect(issue.details['conversionStage'], stage.name);
        },
      );
    }
  }

  for (final raw in [false, true]) {
    test('${raw ? 'raw' : 'normal'} array starts conversions together and preserves successful order', () async {
      final h = await generationFixture();
      final context = await _normalContext(h);
      final allEntered = Completer<void>();
      final sources = [for (var i = 0; i < 4; i++) 'https://fixture.invalid/$i.png'];
      final pending = {for (final source in sources) source: Completer<String>()};
      late _ImageHost host;
      host = _ImageHost((source, token) {
        if (host.sources.length == sources.length) allEntered.complete();
        return pending[source]!.future;
      });
      h.bridge.attachHost(host);
      final plan = h.reply('MODEL');
      final generation = await _generate(h, context.id, raw: raw, image: sources);
      await generationSignal(generation, allEntered.future);
      pending[sources[3]]!.completeError(_failure(TavernHelperImageConversionStage.base64));
      pending[sources[2]]!.complete(_otherPng);
      pending[sources[1]]!.completeError(_failure(TavernHelperImageConversionStage.download));
      pending[sources[0]]!.complete(_png);
      final wire = await generationRequest(generation, plan);
      final result = await generation.result;
      expect(result.text, 'MODEL');
      expect(host.sources, sources);
      expect(
        generationMessages(wire).last['content'],
        sourceCases['${raw ? 'raw' : 'normal'}-array-mixed']!['content'],
      );
      expect(result.hookIssues.where((issue) => issue.code == 'helperImageConversionFailed'), hasLength(2));
    });

    test('${raw ? 'raw' : 'normal'} all-failed nonempty array retains its source text-part shape', () async {
      final h = await generationFixture();
      final context = await _normalContext(h);
      h.bridge.attachHost(
        _ImageHost((source, token) async => throw _failure(TavernHelperImageConversionStage.download)),
      );
      final plan = h.reply('MODEL');
      final generation = await _generate(h, context.id, raw: raw, image: [_url], input: '');
      final wire = await generationRequest(generation, plan);
      final result = await generation.result;
      expect(result.text, 'MODEL');
      expect(generationMessages(wire).last, {
        'role': 'user',
        'content': sourceCases['${raw ? 'raw' : 'normal'}-array-all-failed']!['content'],
      });
      expect(result.hookIssues.where((issue) => issue.code == 'helperImageConversionFailed'), hasLength(1));
    });
  }

  test('an untyped host error remains an error instead of becoming a skipped image', () async {
    final h = await generationFixture();
    final context = await _normalContext(h);
    h.bridge.attachHost(_ImageHost((source, token) async => throw StateError('resolver protocol broke')));
    final generation = await _generate(h, context.id, raw: true, image: _url);
    final failure = await generationFailure(generation);
    // Preserve the existing bridge's StateError mapping; no new skip/fallback.
    expect(failure.code, TavernScriptErrorCode.notFound);
    expect(failure.issues.where((issue) => issue.code == 'helperImageConversionFailed'), isEmpty);
    expect(h.requests, isEmpty);
  });

  test('a consumed URL still requires a real image host and invalid DTOs still fail', () async {
    final h = await generationFixture();
    final context = await _normalContext(h);
    final generation = await _generate(h, context.id, raw: false, image: [_url]);
    final failure = await generationFailure(generation);
    expect(failure.code, TavernScriptErrorCode.unsupportedCapability);
    expect(h.requests, isEmpty);
    expect(
      () => TavernHelperGenerateRequest.fromJson({
        'image': {'url': _url},
      }),
      throwsA(scriptError(TavernScriptErrorCode.invalidArgument)),
    );
  });

  for (final boundary in ['cancel', 'host', 'page']) {
    test('$boundary change rejects a late typed image conversion failure instead of skipping it', () async {
      final h = await generationFixture();
      final context = await _normalContext(h);
      final entered = Completer<void>();
      final pending = Completer<String>();
      h.bridge.attachHost(
        _ImageHost((source, token) {
          entered.complete();
          return pending.future;
        }),
      );
      final generation = await _generate(h, context.id, raw: false, image: [_url]);
      await generationSignal(generation, entered.future);
      switch (boundary) {
        case 'cancel':
          expect(await (h.bridge as TavernHelperGenerationControl).stopHelperGenerationById(generation.id), isTrue);
        case 'host':
          h.bridge.attachHost(ScriptHost());
        case 'page':
          (h.engine as TavernSPresetPageLifecycle).resetSPresetPage(context.chatId!);
      }
      pending.completeError(_failure(TavernHelperImageConversionStage.base64));
      final failure = await generationFailure(generation);
      if (boundary == 'cancel') expect(failure.code, TavernScriptErrorCode.cancelled);
      if (boundary == 'page') expect(failure.message, contains('page document or host changed'));
      expect(failure.issues.where((issue) => issue.code == 'helperImageConversionFailed'), isEmpty);
      expect(h.requests, isEmpty);
    });
  }
}

TavernHelperImageConversionFailure _failure(TavernHelperImageConversionStage stage) =>
    TavernHelperImageConversionFailure(stage: stage, message: 'Observed synthetic ${stage.name} failure.');

Future<TavernScriptGeneration> _generate(
  ScriptFixture h,
  String context, {
  required bool raw,
  required Object image,
  String input = 'Q',
}) {
  final json = <String, Object?>{'user_input': input, 'image': image, 'should_silence': true};
  if (!raw) return h.bridge.generate(context, TavernHelperGenerateRequest.fromJson(json));
  return h.bridge.generateRaw(
    context,
    TavernHelperRawRequest.fromJson({
      ...json,
      'ordered_prompts': ['user_input'],
      'overrides': {
        'chat_history': {'prompts': [], 'with_depth_entries': false},
      },
    }),
  );
}

Future<TavernScriptContext> _normalContext(ScriptFixture h, {bool macros = false}) async {
  final actor = await h.card('Image phase actor', description: macros ? 'CHAR{{random::a::b}}' : '');
  final context = await h.context(await h.emptyChat(actor), characterId: actor);
  if (macros) {
    await h.engine.putLorebook('image-phase', _book('WORLD{{random::a::b}}'));
    await h.engine.bindLorebooks(['image-phase']);
  }
  return context;
}

ScriptJson _book(String content, {String? key}) => {
  'name': 'Image phase',
  'entries': {
    '0': {
      'uid': 0,
      'key': [?key],
      'content': content,
      'constant': key == null,
      'disable': false,
      'position': 0,
      'order': 100,
      'useProbability': false,
    },
  },
};

ChatPreset _layout({required bool history, String? markerRole}) {
  final raw = scriptPreset(main: 'SYSTEM').raw;
  final prompts = (raw['prompts']! as List<Object?>).cast<ScriptJson>();
  final order = (scriptMap((raw['prompt_order']! as List<Object?>).single)['order']! as List<Object?>)
      .cast<ScriptJson>();
  for (final row in order) {
    if (row['identifier'] == 'chatHistory') row['enabled'] = history;
  }
  if (markerRole != null) {
    prompts.add({
      'identifier': 'oldImageMarker',
      'role': markerRole,
      'content': 'OLD$_marker',
      'system_prompt': false,
      'marker': false,
    });
    order.insert(0, {'identifier': 'oldImageMarker', 'enabled': true});
  }
  return ChatPreset(raw);
}

class _ImageHost extends ScriptHost implements TavernHelperImageHost {
  _ImageHost(this.resolve);
  final Future<String> Function(String, TavernScriptCancellation) resolve;
  final sources = <String>[];

  @override
  Future<String> resolveHelperImage(String source, TavernScriptCancellation cancellation) {
    sources.add(source);
    return resolve(source, cancellation);
  }
}
