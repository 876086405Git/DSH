import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:mirrors' as mirrors;

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';
import 'spreset_engine_test.dart' show SPresetHost;

// Reflection only reads the existing log/capture ledgers after real public
// generation, cancellation and physical close. It does not select a private
// execution path or modify product state.
Object? _field(mirrors.InstanceMirror value, String name, mirrors.LibraryMirror library) =>
    value.getField(mirrors.MirrorSystem.getSymbol(name, library)).reflectee;

void main() {
  for (final helper in [false, true]) {
    test(
      'validate cancellation settles the registered ${helper ? 'Helper' : 'native'} log after real host drain',
      () async {
        final h = await generationFixture(allowModel: false);
        final entered = Completer<void>();
        final release = Completer<void>();
        final settled = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final host = SPresetHost();
        host.handler = (request) async {
          if (request.stage == 'OutputPreprocessing/validate') {
            entered.complete();
            try {
              await release.future;
              return await host.defaultEvaluate(request);
            } finally {
              settled.complete();
            }
          }
          return host.defaultEvaluate(request);
        };
        h.bridge.attachHost(host);
        await h.engine.setPreset(
          ChatPreset({
            ...scriptPreset().raw,
            'stream_openai': false,
            'function_calling': false,
            'extensions': {
              'SPreset': {
                'LogUpload': {'enabled': true},
                'OutputPreprocessing': {
                  'enabled': true,
                  'consumeToolCalls': true,
                  'script': 'synthetic-validation-barrier',
                },
              },
            },
          }),
        );
        await h.engine.setSettings({'spresetLogUploadEnabled': true});
        final actor = await h.card('Validation barrier actor');
        final chatId = await h.emptyChat(actor);
        final context = await h.context(chatId, characterId: actor);
        TavernScriptGeneration? generation;
        ScriptEvents<TavernEvent>? native;
        late Future<void> logicalDone;
        String? logicalTerminal;
        if (helper) {
          generation = await h.bridge.generateRaw(
            context.id,
            TavernHelperRawRequest.fromJson({
              'generation_id': 'validate-cancel-helper',
              'should_stream': false,
              'ordered_prompts': [
                {'role': 'user', 'content': 'Q'},
              ],
            }),
          );
          logicalDone = generation.result.then<void>(
            (_) {
              logicalTerminal = 'unexpected-success';
            },
            onError: (Object error, StackTrace _) {
              logicalTerminal = error is TavernScriptException ? error.code.name : error.runtimeType.toString();
            },
          );
        } else {
          native = ScriptEvents(h.engine.send(chatId, 'Q'));
          logicalDone = native.done.future.then((_) {
            logicalTerminal = native!.values.last.runtimeType.toString();
          });
        }
        await Future.any([
          entered.future,
          logicalDone.then((_) => throw StateError('Generation ended before reaching the validation barrier.')),
        ]);
        final engineMirror = mirrors.reflect(h.engine);
        final library = engineMirror.type.owner! as mirrors.LibraryMirror;
        final active = (_field(engineMirror, '_spresetGenerations', library)! as Set).single;
        final sp = mirrors.reflect(active);
        final beforeRegistered = (_field(sp, '_loggedResponses', library)! as Set).toList();
        final beforeCaptures = (_field(sp, '_transportLogs', library)! as Map).length;
        expect(beforeRegistered, [1]);
        expect(host.requests, hasLength(1));
        // Settlement samples the completed global setting; cancellation itself
        // may trigger settlement before the blocked host physically returns.
        await h.engine.setSettings({'spresetLogUploadEnabled': false});
        if (helper) {
          expect(h.bridge.stopGenerationById(generation!.id), isTrue);
        } else {
          h.engine.stop(chatId);
        }
        expect(settled.isCompleted, isFalse);
        expect(host.released, isEmpty, reason: 'Logical cancellation must not masquerade as actual host completion.');
        release.complete();
        await settled.future;
        await logicalDone;
        await h.engine.close();

        final records = (_field(engineMirror, '_spresetLogs', library)! as SPresetLogBuffer).records;
        final registered = (_field(sp, '_loggedResponses', library)! as Set).toList();
        final captures = (_field(sp, '_transportLogs', library)! as Map).length;
        final pending = (_field(sp, 'pending', library)! as Set).length;
        final file = File('${h.root.path}/spreset-generation-logs.json');
        final exists = await file.exists();
        print(
          'VALIDATE_CANCEL_OBSERVATION ${jsonEncode({'path': helper ? 'Helper' : 'native', 'logicalTerminal': logicalTerminal, 'hostSettled': settled.isCompleted, 'hostReleasedSessions': host.released.length, 'pendingActualFuturesAfterClose': pending, 'registeredBefore': beforeRegistered, 'registeredAfterClose': registered, 'transportCapturesBefore': beforeCaptures, 'transportCapturesAfterClose': captures, 'recordStatusesAfterClose': records.map((record) => record['status']).toList(), 'physicalLogFileExists': exists, 'httpRequests': h.requests.length, 'keyReads': h.keyReads})}',
        );
        expect(settled.isCompleted, isTrue);
        expect(host.released, isNotEmpty);
        expect(pending, 0);
        expect(captures, 0);
        expect(h.requests, isEmpty);
        expect(h.keyReads, 0);
        expect(registered, isEmpty, reason: 'A cancelled validation must settle its already registered response log.');
        expect(records, hasLength(1));
        expect(records.single['status'], 'logging_disabled');
        expect(records.single['response'], containsPair('omitted', true));
        expect(exists, isTrue, reason: 'Physical close must finish persisting the registered response log.');
      },
    );
  }
}
