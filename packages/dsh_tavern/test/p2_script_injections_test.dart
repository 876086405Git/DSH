import 'dart:async';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

void main() {
  test('leases remove only their exact owner version while explicit uninject stays chat-scoped', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Lease');
    final chat = await _metadataChat(h, character, {
      'script_injects': {
        'same': {'value': 'PERSISTENT', 'position': 1, 'depth': 0, 'role': 0},
      },
    });
    final a = await h.context(chat, characterId: character, instanceId: 'owner-a');
    final b = await h.context(chat, characterId: character, instanceId: 'owner-b');
    final otherChat = await h.emptyChat(character);
    final other = await h.context(otherChat, characterId: character, instanceId: 'other-chat');
    final first = await h.bridge.injectPrompts(a.id, [TavernScriptInjection(id: 'same', content: 'VALUE')]);
    final second = await h.bridge.injectPrompts(b.id, [TavernScriptInjection(id: 'same', content: 'VALUE')]);
    expect(first.registrations.single.registrationVersion, isNot(second.registrations.single.registrationVersion));
    await h.bridge.injectPrompts(other.id, [TavernScriptInjection(id: 'same', content: 'OTHER')]);
    await h.bridge.releaseInjectionLease(first.leaseId);
    await h.bridge.releaseInjectionLease(first.leaseId);
    await h.bridge.closeContext(a.id);
    var views = await h.bridge.listInjections(b.id);
    expect(views, hasLength(2));
    expect(views.last.ownerContextId, b.id);
    expect(views.last.registrationVersion, second.registrations.single.registrationVersion);
    await expectLater(
      () => h.bridge.injectPrompts(b.id, [
        TavernScriptInjection(id: 'new', content: 'FIRST'),
        TavernScriptInjection(id: 'new', content: 'SECOND'),
      ]),
      throwsA(scriptError(TavernScriptErrorCode.duplicateId)),
    );
    expect((await h.bridge.listInjections(b.id)).map((view) => view.injection!.id), ['same', 'same']);
    await h.bridge.uninjectPrompts(b.id, ['same']);
    views = await h.bridge.listInjections(b.id);
    expect(views.single.source, TavernScriptInjectionSource.persistent);
    expect(views.single.injection!.content, 'PERSISTENT');
    expect((await h.bridge.listInjections(other.id)).single.injection!.content, 'OTHER');
    await h.bridge.releaseInjectionLease(second.leaseId);
    final empty = await h.bridge.injectPrompts(b.id, []);
    expect(empty.registrations, isEmpty);
    await h.bridge.releaseInjectionLease(empty.leaseId);
    await h.reopen();
    final fresh = await h.context(chat, characterId: character);
    expect((await h.bridge.listInjections(fresh.id)).single.injection!.content, 'PERSISTENT');
    final freshOther = await h.context(otherChat, characterId: character, instanceId: 'other-reopen');
    expect(await h.bridge.listInjections(freshOther.id), isEmpty);
    h.expectNoGeneration();
  });

  test('raw depth uses the complete original sequence and preserves raw ids and all three sources', () async {
    final h = await generationFixture();
    final character = await h.card('Depth');
    final chat = await _metadataChat(h, character, {
      'script_injects': {
        'shared': {'value': 'PERSISTENT', 'position': 1, 'depth': 1, 'role': 0},
      },
    });
    final context = await h.context(chat, characterId: character);
    await h.bridge.injectPrompts(context.id, [
      TavernScriptInjection(id: 'a_b', content: 'UNDERSCORE', depth: 1),
      TavernScriptInjection(id: 'a-b', content: 'DASH', depth: 1),
      TavernScriptInjection(id: 'shared', content: 'TRANSIENT', depth: 1),
    ]);
    final before = generationNodes(h, chat);
    expect(before, isEmpty, reason: 'Persistent root metadata remains available without a selected leaf.');
    final response = h.reply('done');
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernScriptRawRequest(
        orderedPrompts: const [
          TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'A'),
          TavernScriptPromptPart.literal(role: TavernScriptPromptRole.assistant, content: 'B'),
          TavernScriptPromptPart.literal(role: TavernScriptPromptRole.system, content: 'C'),
        ],
        injects: [
          TavernScriptInjection(id: 'shared', content: 'REQUEST', depth: 1),
          TavernScriptInjection(id: 'head', content: 'HEAD', depth: 10000),
          TavernScriptInjection(id: 'tail-s', content: 'TAIL-S', depth: 0),
          TavernScriptInjection(id: 'tail-u', content: 'TAIL-U', depth: 0, role: TavernScriptPromptRole.user),
          TavernScriptInjection(id: 'tail-a', content: 'TAIL-A', depth: 0, role: TavernScriptPromptRole.assistant),
        ],
      ),
    );
    final wire = await generationRequest(generation, response);
    await generation.result;
    expect(generationMessages(wire), [
      {'role': 'system', 'content': 'HEAD'},
      {'role': 'user', 'content': 'A'},
      {'role': 'assistant', 'content': 'B'},
      {'role': 'system', 'content': 'DASH\nUNDERSCORE\nPERSISTENT\nTRANSIENT\nREQUEST'},
      {'role': 'system', 'content': 'C'},
      {'role': 'assistant', 'content': 'TAIL-A'},
      {'role': 'user', 'content': 'TAIL-U'},
      {'role': 'system', 'content': 'TAIL-S'},
    ]);
    expect((await h.bridge.listInjections(context.id)).map((view) => view.injection!.id), [
      'shared',
      'a_b',
      'a-b',
      'shared',
    ]);
    expect(generationNodes(h, chat), before);
  });

  test('two prepared background calls race one once version without re-running its filter', () async {
    final h = await generationFixture();
    final character = await h.card('Once race');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    final bothEntered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final host = GenerationHost();
    host.onInvoke = (request, cancellation) async {
      expect(request.kind, 'filter');
      expect(request.args, isEmpty);
      expect(request.ref.contextId, context.id);
      expect(request.ref.instanceId, context.instanceId);
      if (host.invocations.length == 2) bothEntered.complete();
      await release.future;
      return TavernScriptCallbackResult(requestId: request.requestId, status: 'completed', value: true);
    };
    h.bridge.attachHost(host);
    final lease = await h.bridge.injectPrompts(context.id, [
      TavernScriptInjection(id: 'once', content: 'ONCE', depth: 0, filter: _filter(context, 'allow')),
    ], once: true);
    final response = h.reply('winner');
    final first = await h.bridge.generateRaw(context.id, _raw('first'));
    final second = await h.bridge.generateRaw(context.id, _raw('second'));
    final outcomes = Future.wait([_outcome(first), _outcome(second)]);
    await Future.any([generationSignal(first, bothEntered.future), generationSignal(second, bothEntered.future)]);
    expect(h.requests, isEmpty);
    expect(h.keyReads, 0);
    release.complete();
    final actual = await outcomes;
    expect(actual.whereType<TavernScriptGenerationResult>(), hasLength(1));
    final failure = actual.whereType<TavernScriptException>().single;
    expect(failure.code, TavernScriptErrorCode.revisionConflict);
    expect(failure.committed, isFalse);
    expect(host.invocations, hasLength(2));
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
    expect(generationMessages(await response.seen.future), [
      {'role': 'user', 'content': 'Q'},
      {'role': 'system', 'content': 'ONCE'},
    ]);
    final view = (await h.bridge.listInjections(context.id)).single;
    expect(view.once, isTrue);
    expect(view.claimed, isTrue);
    expect(view.registrationVersion, lease.registrations.single.registrationVersion);
    expect(await h.engine.path(chat), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('accepted scan-only empty once stays consumed after missing key without evaluating unused text', () async {
    final h = await generationFixture();
    final character = await h.card('Empty once');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    final host = GenerationHost();
    host.onInvoke = (request, cancellation) async =>
        TavernScriptCallbackResult(requestId: request.requestId, status: 'completed', value: true);
    h.bridge.attachHost(host);
    await h.bridge.injectPrompts(context.id, [
      TavernScriptInjection(
        id: 'empty',
        content: '{{incglobalvar::unused}}',
        position: TavernScriptInjectionPosition.scanOnly,
        scan: false,
        filter: _filter(context, 'once'),
      ),
    ], once: true);
    h.engine.configure(
      TavernModelConfig(
        apiKey: () async {
          h.keyReads++;
          return null;
        },
        baseUrl: h.config.baseUrl,
        model: h.config.model,
        deepseek: true,
      ),
    );
    final generation = await h.bridge.generateRaw(context.id, _raw('no-key'));
    final failure = await generationFailure(generation);
    expect(failure.code, TavernScriptErrorCode.model);
    expect(failure.modelFailure, TavernFailure.noKey);
    expect(failure.committed, isTrue, reason: 'The precise once version was already accepted.');
    expect((await h.bridge.listInjections(context.id)).single.claimed, isTrue);
    expect(h.engine.globalVariables.containsKey('unused'), isFalse);
    expect(h.requests, isEmpty);
    expect(h.keyReads, 1);
    h.engine.configure(h.config);
    final response = h.reply('later');
    final later = await h.bridge.generateRaw(context.id, _raw('later'));
    final wire = await generationRequest(later, response);
    await later.result;
    expect(generationMessages(wire), [
      {'role': 'user', 'content': 'Q'},
    ]);
    expect(host.invocations, hasLength(1));
    expect(h.keyReads, 2);
    final exported = (await h.engine.exportChat(chat)).first;
    final document = StChatDocument.decode(exported.fileName, exported.bytes);
    expect(scriptMap(document.header['chat_metadata']).containsKey('script_injects'), isFalse);
  });

  test('a same-content replacement invalidates a captured non-once version instead of replaying preparation', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Version');
    final chat = await h.emptyChat(character);
    final a = await h.context(chat, characterId: character, instanceId: 'old-owner');
    final b = await h.context(chat, characterId: character, instanceId: 'new-owner');
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final host = GenerationHost();
    host.onInvoke = (request, cancellation) async {
      entered.complete();
      await release.future;
      return TavernScriptCallbackResult(requestId: request.requestId, status: 'completed', value: true);
    };
    h.bridge.attachHost(host);
    final old = await h.bridge.injectPrompts(a.id, [
      TavernScriptInjection(id: 'same', content: 'UNCHANGED', filter: _filter(a, 'hold')),
    ]);
    final generation = await h.bridge.generateRaw(a.id, _raw('stale'));
    await generationSignal(generation, entered.future);
    final replacement = await h.bridge.injectPrompts(b.id, [TavernScriptInjection(id: 'same', content: 'UNCHANGED')]);
    expect(replacement.registrations.single.registrationVersion, isNot(old.registrations.single.registrationVersion));
    release.complete();
    final failure = await generationFailure(generation);
    expect(failure.code, TavernScriptErrorCode.revisionConflict);
    expect(failure.committed, isFalse);
    expect(host.invocations, hasLength(1));
    expect((await h.bridge.listInjections(b.id)).single.ownerContextId, b.id);
    expect((await h.bridge.listInjections(b.id)).single.claimed, isFalse);
    h.expectNoGeneration();
  });

  test(
    'raw missing main rejects a used placement but false filters and empty expansion obey their own boundaries',
    () async {
      final h = await generationFixture();
      final character = await h.card('Placement');
      final chat = await h.emptyChat(character);
      final context = await h.context(chat, characterId: character);
      final host = GenerationHost();
      host.onInvoke = (request, cancellation) async => TavernScriptCallbackResult(
        requestId: request.requestId,
        status: 'completed',
        value: request.ref.callbackId != 'false',
      );
      h.bridge.attachHost(host);
      await h.bridge.injectPrompts(context.id, [
        TavernScriptInjection(
          id: 'missing-main',
          content: 'NONEMPTY',
          position: TavernScriptInjectionPosition.beforeMain,
        ),
      ], once: true);
      final invalid = await h.bridge.generateRaw(context.id, _raw('invalid'));
      expect((await generationFailure(invalid)).code, TavernScriptErrorCode.unsupportedOption);
      expect((await h.bridge.listInjections(context.id)).single.claimed, isFalse);
      expect(h.keyReads, 0);
      await h.bridge.uninjectPrompts(context.id, ['missing-main']);
      await h.bridge.injectPrompts(context.id, [
        TavernScriptInjection(
          id: 'false-main',
          content: 'NONEMPTY',
          position: TavernScriptInjectionPosition.afterMain,
          filter: _filter(context, 'false'),
        ),
        TavernScriptInjection(
          id: 'empty-main',
          content: '{{getglobalvar::absent}}',
          position: TavernScriptInjectionPosition.beforeMain,
          filter: _filter(context, 'true'),
        ),
      ], once: true);
      final response = h.reply('done');
      final generation = await h.bridge.generateRaw(context.id, _raw('valid'));
      final wire = await generationRequest(generation, response);
      await generation.result;
      expect(generationMessages(wire), [
        {'role': 'user', 'content': 'Q'},
      ]);
      final views = await h.bridge.listInjections(context.id);
      expect(views.singleWhere((view) => view.injection!.id == 'false-main').claimed, isFalse);
      expect(views.singleWhere((view) => view.injection!.id == 'empty-main').claimed, isTrue);
      expect(host.invocations, hasLength(2));
    },
  );
  test('persistent malformed entries stay inspectable and serialized closures never silently become true', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Persistent diagnostics');
    final chat = await _metadataChat(h, character, {
      'script_injects': {
        'bad': ['retain', 'raw'],
        'closure': {'value': 'NEVER', 'position': 1, 'filter': '{: /echo forbidden :}'},
      },
    });
    final context = await h.context(chat, characterId: character);
    final views = await h.bridge.listInjections(context.id);
    expect(views, hasLength(2));
    expect(views.first.raw, ['retain', 'raw']);
    expect(views.first.injection, isNull);
    expect(views.first.issues.map((issue) => issue.code), contains('shapeMismatch'));
    expect(views.last.filterStatus, 'unsupportedPersistent');
    expect(views.last.injection!.filter, isNull);
    expect(views.last.issues.map((issue) => issue.code), contains('unsupportedCapability'));
    expect(
      views.every(
        (view) => view.registrationVersion == null && view.ownerContextId == null && !view.once && !view.claimed,
      ),
      isTrue,
    );
    final bad = await h.bridge.generateRaw(context.id, _raw('malformed'));
    expect((await generationFailure(bad)).code, TavernScriptErrorCode.shapeMismatch);
    final closureChat = await _metadataChat(h, character, {
      'script_injects': {
        'closure': {'value': 'NEVER', 'position': 1, 'filter': '{: /echo forbidden :}'},
      },
    });
    final closureContext = await h.context(closureChat, characterId: character, instanceId: 'closure');
    final closure = await h.bridge.generateRaw(closureContext.id, _raw('closure'));
    final error = await generationFailure(closure);
    expect(error.code, TavernScriptErrorCode.unsupportedCapability);
    expect(
      error.issues.any((issue) => scriptMap(issue.details['sourceRef'] ?? <String, Object?>{})['rawId'] == 'closure'),
      isTrue,
    );
    final brokenChat = await _metadataChat(h, character, {
      'script_injects': ['not-an-object'],
    });
    final broken = await h.context(brokenChat, characterId: character, instanceId: 'broken');
    await expectLater(
      () => h.bridge.listInjections(broken.id),
      throwsA(scriptError(TavernScriptErrorCode.shapeMismatch)),
    );
    h.expectNoGeneration();
  });

  test('filter host errors remain explicit and completed without bool is not a false predicate', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Filter errors');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    TavernScriptRawRequest request(String id) => TavernScriptRawRequest(
      generationId: id,
      orderedPrompts: const [TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'Q')],
      injects: [
        TavernScriptInjection(id: 'filtered', content: '{{incglobalvar::forbidden}}', filter: _filter(context, id)),
      ],
    );
    final absent = await h.bridge.generateRaw(context.id, request('no-host'));
    expect((await generationFailure(absent)).code, TavernScriptErrorCode.hostUnavailable);
    final host = GenerationHost();
    h.bridge.attachHost(host);
    final cases = <String, TavernScriptErrorCode>{
      'wrong-id': TavernScriptErrorCode.hookFailure,
      'no-bool': TavernScriptErrorCode.shapeMismatch,
      'failed': TavernScriptErrorCode.hookFailure,
      'cancelled': TavernScriptErrorCode.cancelled,
      'throw': TavernScriptErrorCode.hookFailure,
    };
    for (final entry in cases.entries) {
      host.onInvoke = (call, cancellation) async {
        if (entry.key == 'throw') throw StateError('fixture callback error');
        return TavernScriptCallbackResult(
          requestId: entry.key == 'wrong-id' ? 'unrelated-request' : call.requestId,
          status: entry.key == 'failed' || entry.key == 'cancelled' ? entry.key : 'completed',
          value: entry.key == 'no-bool' ? null : true,
        );
      };
      final generation = await h.bridge.generateRaw(context.id, request(entry.key));
      final error = await generationFailure(generation);
      expect(error.code, entry.value);
      expect(error.committed, isFalse);
      expect(error.issues.any((issue) => issue.stage == 'injectionFilter'), isTrue);
    }
    expect(host.invocations, hasLength(cases.length));
    expect(h.engine.globalVariables.containsKey('forbidden'), isFalse);
    await expectLater(
      () => h.bridge.injectPrompts(context.id, [
        TavernScriptInjection(
          id: 'alien',
          content: 'x',
          filter: TavernScriptCallbackRef(contextId: context.id, instanceId: 'another-instance', callbackId: 'x'),
        ),
      ]),
      throwsA(scriptError(TavernScriptErrorCode.callbackUnavailable)),
    );
    expect(await h.bridge.listInjections(context.id), isEmpty);
    h.expectNoGeneration();
  });

  test(
    'native filter writes settle inside preparation and the same once registry serves later background work',
    () async {
      final h = await generationFixture();
      final character = await h.card('Native filter');
      final chat = await h.emptyChat(character);
      final context = await h.context(chat, characterId: character, instanceId: 'filter-owner');
      await h.engine.setPreset(scriptPreset(main: 'FILTER{{getvar::prepared}}'));
      final host = GenerationHost();
      host.onInvoke = (request, cancellation) async {
        expect(request.kind, 'filter');
        expect(request.args, isEmpty);
        expect(request.ref.contextId, context.id);
        await h.bridge.replaceVariables(context.id, scriptChat, {'prepared': 7});
        return TavernScriptCallbackResult(requestId: request.requestId, status: 'completed', value: true);
      };
      h.bridge.attachHost(host);
      await h.bridge.injectPrompts(context.id, [
        TavernScriptInjection(
          id: 'native-once',
          content: 'ONCE{{getvar::prepared}}',
          depth: 0,
          filter: _filter(context, 'prepare'),
        ),
      ], once: true);
      final nativeResponse = h.reply('NATIVE');
      final native = ScriptEvents(h.engine.send(chat, 'Q'));
      await native.waitRequest(nativeResponse);
      await native.done.future;
      expect(native.values.whereType<TavernTurnFailed>(), isEmpty);
      expect(native.values.whereType<TavernTurnDone>().single.message.text, 'NATIVE');
      expect(
        h.requests.single.body,
        scriptWire([
          {'role': 'system', 'content': 'FILTER7'},
          {'role': 'user', 'content': 'Q'},
          {'role': 'system', 'content': 'ONCE7'},
        ]),
      );
      expect((await h.bridge.listInjections(context.id)).single.claimed, isTrue);
      expect((await h.engine.readVariables(chat))['prepared'], 7);
      final before = generationNodes(h, chat);
      final response = h.reply('BACKGROUND');
      final background = await h.bridge.generateRaw(context.id, _raw('after-native'));
      final wire = await generationRequest(background, response);
      await background.result;
      expect(generationMessages(wire), [
        {'role': 'user', 'content': 'Q'},
      ]);
      expect(host.invocations, hasLength(1));
      expect(generationNodes(h, chat), before);
      expect(h.requests, hasLength(2));
      expect(h.keyReads, 2);
      stdout.writeln('P2_B2_INJECTIONS_READY');
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test('background filter failures retain known effects without claiming preparation targets', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Known filter effects');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    final host = GenerationHost();
    h.bridge.attachHost(host);
    await h.bridge.injectPrompts(context.id, [
      TavernScriptInjection(id: 'a-effect', content: 'NEVER', filter: _filter(context, 'effect')),
      TavernScriptInjection(id: 'z-failure', content: 'NEVER', filter: _filter(context, 'later-failure')),
    ], once: true);
    for (final mode in ['reported', 'thrown', 'prior', 'clean']) {
      final id = 'known-effect-$mode';
      final known = mode != 'clean';
      final kept = mode == 'reported'
          ? 7
          : mode == 'thrown'
          ? 8
          : 9;
      final ended = Completer<TavernScriptDispatch>();
      host.onDispatch = (request, cancellation) async {
        if (request.name == 'GENERATION_ENDED' && request.generationId == id) {
          ended.complete(request);
        }
        return TavernScriptDispatchAck(eventId: request.eventId);
      };
      host.onInvoke = (request, cancellation) async {
        if (request.ref.callbackId == 'later-failure') {
          expect(mode, 'prior');
          return TavernScriptCallbackResult(requestId: request.requestId, status: 'failed');
        }
        expect(request.ref.callbackId, 'effect');
        if (known) {
          await h.bridge.replaceVariables(context.id, scriptChat, {'kept': kept});
        }
        if (mode == 'thrown') {
          throw TavernScriptException(
            code: TavernScriptErrorCode.hookFailure,
            operation: 'fixtureFilter',
            message: 'write completed before throw',
            committed: true,
          );
        }
        return TavernScriptCallbackResult(
          requestId: request.requestId,
          status: mode == 'prior' ? 'completed' : 'failed',
          value: mode == 'prior' ? false : null,
          issues: [
            if (known)
              TavernScriptIssue(
                code: 'known-filter-write',
                message: 'the preceding bridge write completed',
                committed: true,
              ),
          ],
        );
      };
      final generation = await h.bridge.generateRaw(context.id, _raw(id));
      final failure = await generationFailure(generation);
      expect(failure.code, TavernScriptErrorCode.hookFailure);
      expect(failure.committed, known);
      final preparation = failure.issues.singleWhere((issue) => issue.code == 'generationPreparation');
      expect(preparation.committed, known);
      expect(preparation.stage, 'filter');
      final receipt = preparation.details;
      expect(receipt['preparationAccepted'], isFalse);
      expect(receipt['persistedTargets'], isEmpty);
      expect(receipt['claimedInjectionVersions'], isEmpty);
      expect(
        failure.issues.where((issue) => issue.code == 'known-filter-write'),
        hasLength(mode == 'reported' || mode == 'prior' ? 1 : 0),
      );
      final terminal = (await generation.events.toList()).single;
      expect(terminal.kind, TavernScriptGenerationEventKind.failed);
      expect(terminal.status, TavernScriptGenerationStatus.failed);
      expect(terminal.error, same(failure));
      final notice = scriptMap((await ended.future).args.single);
      expect(notice['status'], 'failed');
      expect(notice['error'], 'hookFailure');
      expect(notice['committed'], known);
      expect((await h.bridge.getVariables(context.id, scriptChat)).value['kept'], kept);
      expect(await h.engine.path(chat), isEmpty);
      final registrations = await h.bridge.listInjections(context.id);
      expect(registrations, hasLength(2));
      expect(registrations.every((entry) => entry.once && !entry.claimed), isTrue);
      h.expectNoGeneration();
    }
    expect(host.invocations, hasLength(5));
    await h.reopen();
    final fresh = await h.context(chat, characterId: character);
    expect((await h.bridge.getVariables(fresh.id, scriptChat)).value['kept'], 9);
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('native filter failure preserves its completed bridge write and reports the known issue once', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Native failure');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    final host = GenerationHost();
    host.onInvoke = (request, cancellation) async {
      await h.bridge.replaceVariables(context.id, scriptChat, {'kept': 7});
      return TavernScriptCallbackResult(
        requestId: request.requestId,
        status: 'failed',
        issues: [TavernScriptIssue(code: 'native-filter-failure', message: 'known fixture issue', committed: true)],
      );
    };
    h.bridge.attachHost(host);
    await h.bridge.injectPrompts(context.id, [
      TavernScriptInjection(id: 'failure', content: 'NEVER', filter: _filter(context, 'write-then-fail')),
    ], once: true);
    final events = await h.engine.send(chat, 'Q').toList();
    expect(events.whereType<TavernTurnDone>(), isEmpty);
    final failure = events.whereType<TavernTurnFailed>().single;
    expect(failure.kind, TavernFailure.server);
    expect(failure.hookIssues.where((issue) => issue.code == 'native-filter-failure'), hasLength(1));
    expect(failure.hookIssues.any((issue) => issue.stage == 'injectionFilter'), isTrue);
    expect((await h.bridge.getVariables(context.id, scriptChat)).value['kept'], 7);
    expect(await h.engine.path(chat), isEmpty);
    expect((await h.bridge.listInjections(context.id)).single.claimed, isFalse);
    expect(host.invocations, hasLength(1));
    await h.reopen();
    final fresh = await h.context(chat, characterId: character);
    expect((await h.bridge.getVariables(fresh.id, scriptChat)).value['kept'], 7);
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
  }, timeout: const Timeout(Duration(seconds: 15)));

  for (final mainHasInjection in [false, true]) {
    for (final mode in ['regenerate', 'continue']) {
      final mainCase = mainHasInjection ? 'the same raw id in MAIN' : 'no MAIN injections';
      test('native $mode takes noncurrent BRANCH injections with $mainCase', () async {
        final h = await generationFixture();
        final character = await h.card('Target source');
        await h.engine.setPreset(scriptPreset(main: 'SOURCE_MAIN_PROMPT'));
        final sources = await _twoSourceChat(
          h,
          character,
          mainInjections: mainHasInjection ? {'shared': _sourceEntry('MAIN_ONLY')} : null,
          branchInjections: {'shared': _sourceEntry('BRANCH_ONLY')},
        );
        final chat = sources.chatId;
        final context = await h.context(chat, characterId: character);
        expect((await h.engine.path(chat)).last.nodeId, sources.mainLeaf);
        expect(h.engine.settings(chatId: chat)['scenarioOverride'], 'MAIN_SOURCE');
        final selected = await h.bridge.listInjections(context.id);
        if (mainHasInjection) {
          expect(selected.single.injection!.content, 'MAIN_ONLY');
        } else {
          expect(selected, isEmpty);
        }
        final response = h.reply('TARGET_REPLY');
        final events = ScriptEvents(
          mode == 'regenerate'
              ? h.engine.regenerate(chat, sources.branchLeaf)
              : h.engine.continueReply(chat, sources.branchLeaf),
        );
        final request = await events.waitRequest(response);
        await events.done.future;
        expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
        final done = events.values.whereType<TavernTurnDone>().single;
        final wire = generationMessages(request).map((message) => message['content']).join('\n');
        expect(wire, contains('BRANCH_ONLY'));
        expect(wire, isNot(contains('MAIN_ONLY')));
        expect(h.requests, hasLength(1));
        expect(h.keyReads, 1);
        final path = await h.engine.path(chat);
        expect(path.first.nodeId, sources.branchRoot);
        expect(path.last.nodeId, done.message.nodeId);
        expect(done.message.nodeId, mode == 'continue' ? sources.branchLeaf : isNot(sources.branchLeaf));
        expect(h.engine.settings(chatId: chat)['scenarioOverride'], 'BRANCH_SOURCE');
        expect((await h.bridge.listInjections(context.id)).single.injection!.content, 'BRANCH_ONLY');
        await h.reopen();
        final reopened = await h.context(chat, characterId: character);
        expect((await h.engine.path(chat)).last.nodeId, done.message.nodeId);
        expect(h.engine.settings(chatId: chat)['scenarioOverride'], 'BRANCH_SOURCE');
        expect((await h.bridge.listInjections(reopened.id)).single.injection!.content, 'BRANCH_ONLY');
        expect(h.requests, hasLength(1));
        expect(h.keyReads, 1);
      }, timeout: const Timeout(Duration(seconds: 15)));
    }
  }

  test('raw persistent source observes real ABA commits but ignores another header without an anchor', () async {
    final h = await generationFixture();
    final character = await h.card('Persistent source observation');
    final sources = await _twoSourceChat(
      h,
      character,
      mainInjections: {'shared': _sourceEntry('MAIN_A', position: -1)},
      branchInjections: {'shared': _sourceEntry('BRANCH_A', position: -1)},
    );
    final chat = sources.chatId;
    await h.engine.selectSibling(chat, sources.mainRoot, 1);
    expect((await h.engine.path(chat)).last.nodeId, sources.branchLeaf);
    final context = await h.context(chat, characterId: character);
    expect(_storedSourceValue(h, chat, 'main'), 'MAIN_A');
    expect(_storedSourceValue(h, chat, 'branch'), 'BRANCH_A');
    final entered = [Completer<void>(), Completer<void>()];
    final release = [Completer<void>(), Completer<void>()];
    final owned = <TavernScriptGeneration>[];
    addTearDown(() async {
      for (final generation in owned) {
        h.bridge.stopGenerationById(generation.id);
      }
      for (final gate in release) {
        if (!gate.isCompleted) gate.complete();
      }
      await Future.wait<void>([
        for (final generation in owned)
          generation.result.then<void>((_) {}, onError: (Object error, StackTrace stack) {}),
      ]);
      h.inspect((db) => db.execute('DROP TRIGGER IF EXISTS p2_persistent_source_phase'), writable: true);
    });
    final chatLiteral = chat.replaceAll("'", "''");
    // Only DDL is installed through inspect. The metadata changes below occur
    // inside the engine's real chat-variable SQL statements and outer COMMIT.
    // That path writes node state first and updateChat(variables) last; _touch
    // follows without replacing metadata, so the AFTER result reaches the
    // ordinary committedObserver. The trigger's inner UPDATE does not name
    // variables and therefore cannot recursively fire this OF-variables hook.
    h.inspect(
      (db) => db.execute('''
      CREATE TRIGGER p2_persistent_source_phase AFTER UPDATE OF variables ON chats
      WHEN NEW.id = '$chatLiteral'
        AND json_extract(NEW.variables, '\$.sourcePhase')
          IS NOT json_extract(OLD.variables, '\$.sourcePhase')
        AND json_extract(NEW.variables, '\$.sourcePhase') IN ('branch-b', 'branch-a', 'main-only')
      BEGIN
        UPDATE chats SET metadata =
          CASE json_extract(NEW.variables, '\$.sourcePhase')
            WHEN 'branch-b' THEN json_set(metadata,
              '\$.dshgo.chatJsonl.sources.branch.chat_metadata.script_injects.shared.value', 'BRANCH_B')
            WHEN 'branch-a' THEN json_set(metadata,
              '\$.dshgo.chatJsonl.sources.branch.chat_metadata.script_injects.shared.value', 'BRANCH_A')
            WHEN 'main-only' THEN json_set(metadata,
              '\$.dshgo.chatJsonl.sources.main.chat_metadata.script_injects.shared.value', 'MAIN_CHANGED')
            ELSE metadata
          END
        WHERE id = NEW.id;
      END
    '''),
      writable: true,
    );
    final host = GenerationHost();
    host.onInvoke = (request, cancellation) async {
      final index = host.invocations.length - 1;
      expect(index, lessThan(entered.length));
      expect(request.kind, 'filter');
      expect(request.ref.callbackId, 'hold-source');
      expect(request.ref.contextId, context.id);
      expect(request.args, isEmpty);
      entered[index].complete();
      await release[index].future;
      return TavernScriptCallbackResult(requestId: request.requestId, status: 'completed', value: true);
    };
    h.bridge.attachHost(host);
    final lease = await h.bridge.injectPrompts(context.id, [
      TavernScriptInjection(
        id: 'hold-once',
        content: 'ONCE_HELD',
        depth: 0,
        scan: false,
        position: TavernScriptInjectionPosition.scanOnly,
        filter: _filter(context, 'hold-source'),
      ),
    ], once: true);
    final first = await h.bridge.generateRaw(context.id, _raw('persistent-source-aba'));
    owned.add(first);
    final firstOutcome = _outcome(first);
    await generationSignal(first, entered[0].future);
    h.expectNoGeneration();
    await h.bridge.replaceVariables(context.id, scriptChat, {'sourcePhase': 'branch-b'});
    expect(_storedSourceValue(h, chat, 'branch'), 'BRANCH_B');
    expect(_storedSourceValue(h, chat, 'main'), 'MAIN_A');
    await h.bridge.replaceVariables(context.id, scriptChat, {'sourcePhase': 'branch-a'});
    expect(_storedSourceValue(h, chat, 'branch'), 'BRANCH_A');
    expect(_storedSourceValue(h, chat, 'main'), 'MAIN_A');
    final afterAba = generationNodes(h, chat);
    release[0].complete();
    final failed = await firstOutcome;
    expect(failed, isA<TavernScriptException>());
    final failure = failed as TavernScriptException;
    expect(failure.code, TavernScriptErrorCode.revisionConflict);
    expect(failure.committed, isFalse);
    final receipt = failure.issues.singleWhere((issue) => issue.code == 'generationPreparation').details;
    expect(receipt['preparationAccepted'], isFalse);
    expect(receipt['claimedInjectionVersions'], isEmpty);
    expect(receipt['persistedTargets'], isEmpty);
    expect(generationNodes(h, chat), afterAba);
    expect(host.invocations, hasLength(1));
    var once = (await h.bridge.listInjections(context.id)).singleWhere((view) => view.once);
    expect(once.claimed, isFalse);
    expect(once.registrationVersion, lease.registrations.single.registrationVersion);
    h.expectNoGeneration();

    final response = h.reply('AFTER_UNRELATED_SOURCE');
    final second = await h.bridge.generateRaw(context.id, _raw('persistent-source-unrelated'));
    owned.add(second);
    final secondOutcome = _outcome(second);
    await generationSignal(second, entered[1].future);
    h.expectNoGeneration();
    await h.bridge.replaceVariables(context.id, scriptChat, {'sourcePhase': 'main-only'});
    expect(_storedSourceValue(h, chat, 'main'), 'MAIN_CHANGED');
    expect(_storedSourceValue(h, chat, 'branch'), 'BRANCH_A');
    expect((await h.engine.path(chat)).last.nodeId, sources.branchLeaf);
    final afterUnrelated = generationNodes(h, chat);
    release[1].complete();
    final request = await generationRequest(second, response);
    final completed = await secondOutcome;
    expect(completed, isA<TavernScriptGenerationResult>());
    final result = completed as TavernScriptGenerationResult;
    expect(result.text, 'AFTER_UNRELATED_SOURCE');
    expect(result.origin.chatId, chat);
    expect(result.origin.nodeAnchor, isNull);
    expect(result.origin.emptyChatAnchor, isFalse);
    // Both text outlets are closed, but these filter-true sources still
    // participate in version acceptance and the same once claim.
    expect(generationMessages(request), [
      {'role': 'user', 'content': 'Q'},
    ]);
    expect(generationNodes(h, chat), afterUnrelated);
    expect(host.invocations, hasLength(2));
    once = (await h.bridge.listInjections(context.id)).singleWhere((view) => view.once);
    expect(once.claimed, isTrue);
    expect(once.registrationVersion, lease.registrations.single.registrationVersion);
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
  }, timeout: const Timeout(Duration(seconds: 15)));
}

TavernScriptCallbackRef _filter(TavernScriptContext context, String id) =>
    TavernScriptCallbackRef(contextId: context.id, instanceId: context.instanceId, callbackId: id);

TavernScriptRawRequest _raw(String id) => TavernScriptRawRequest(
  generationId: id,
  orderedPrompts: const [TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'Q')],
);

Future<Object> _outcome(TavernScriptGeneration generation) async {
  try {
    return await generation.result;
  } on TavernScriptException catch (error) {
    return error;
  }
}

Future<String> _metadataChat(ScriptFixture h, String character, ScriptJson metadata) async {
  final imported = await h.engine.importChats(character, [
    TavernChatFile(
      fileName: 'injections.jsonl',
      bytes: StChatDocument(
        fileName: 'injections.jsonl',
        header: {'user_name': 'User', 'character_name': 'Fixture', 'chat_metadata': metadata},
        messages: [],
      ).encode(),
    ),
  ]);
  return imported.chatIds.single;
}

ScriptJson _sourceEntry(String value, {int position = 0}) => {
  'value': value,
  'position': position,
  'depth': 0,
  'role': 0,
  'scan': false,
  'filter': '',
};

Future<({String chatId, String mainRoot, String mainLeaf, String branchRoot, String branchLeaf})> _twoSourceChat(
  ScriptFixture h,
  String character, {
  ScriptJson? mainInjections,
  required ScriptJson branchInjections,
}) async {
  TavernChatFile file(String name, ScriptJson metadata) => TavernChatFile(
    fileName: name,
    bytes: StChatDocument(
      fileName: name,
      header: {'user_name': 'User', 'character_name': 'Fixture', 'chat_metadata': metadata},
      messages: [
        {
          'name': 'User',
          'is_user': true,
          'is_system': false,
          'mes': 'SOURCE_QUESTION',
          'send_date': '2026-11-12T05:00:00Z',
        },
        {
          'name': 'Fixture',
          'is_user': false,
          'is_system': false,
          'mes': 'SOURCE_REPLY',
          'send_date': '2026-11-12T05:00:01Z',
        },
      ],
    ).encode(),
  );
  final imported = await h.engine.importChats(character, [
    file('main.jsonl', {'scenario': 'MAIN_SOURCE', 'script_injects': ?mainInjections}),
    file('branch.jsonl', {'main_chat': 'main', 'scenario': 'BRANCH_SOURCE', 'script_injects': branchInjections}),
  ]);
  final chat = imported.chatIds.single;
  final main = await h.engine.path(chat);
  expect(main, hasLength(2));
  expect(main.first.siblingCount, 2);
  await h.engine.selectSibling(chat, main.first.nodeId, 1);
  final branch = await h.engine.path(chat);
  expect(branch, hasLength(2));
  expect(branch.first.nodeId, isNot(main.first.nodeId));
  expect(branch.last.nodeId, isNot(main.last.nodeId));
  expect(h.engine.settings(chatId: chat)['scenarioOverride'], 'BRANCH_SOURCE');
  await h.engine.selectSibling(chat, main.first.nodeId, 0);
  expect((await h.engine.path(chat)).last.nodeId, main.last.nodeId);
  return (
    chatId: chat,
    mainRoot: main.first.nodeId,
    mainLeaf: main.last.nodeId,
    branchRoot: branch.first.nodeId,
    branchLeaf: branch.last.nodeId,
  );
}

Object? _storedSourceValue(ScriptFixture h, String chat, String source) => h.inspect(
  (db) => db.select('SELECT json_extract(metadata, ?) AS value FROM chats WHERE id = ?', [
    '\$.dshgo.chatJsonl.sources.$source.chat_metadata.script_injects.shared.value',
    chat,
  ]).single['value'],
);
