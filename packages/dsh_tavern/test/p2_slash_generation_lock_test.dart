import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_slash_test_support.dart';

void main() {
  test('lock capability is optional and real acquisition precedes any key or HTTP work', () async {
    final h = await slashFixture();
    final actor = await h.card('Lock capability');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final unattached = h.bridge.capabilities;
    expect(unattached.adapterVersion, 'p2-b3');
    expect(unattached.methods, {
      'openContext',
      'snapshot',
      'closeContext',
      'activateChat',
      'watchEvents',
      'getChatMessages',
      'setChatMessages',
      'createChatMessages',
      'deleteChatMessages',
      'rotateChatMessages',
      'selectSwipe',
      'getVariables',
      'replaceVariables',
      'updateVariablesWith',
      'mutateVariables',
      'generate',
      'generateRaw',
      'stopGenerationById',
      'getTavernRegexes',
      'formatAsTavernRegexedString',
      'injectPrompts',
      'uninjectPrompts',
      'releaseInjectionLease',
      'listInjections',
      'triggerSlash',
      'stopScript',
      'substituteMacros',
      'replaceCharacterData',
      'getContextBooks',
      'readBook',
      'replaceBook',
      'setMvuEnabled',
      'parseMvuMessage',
      'updateWorldInfoSettings',
      'replaceScriptButtons',
      'getBookDirectory',
      'resolveBook',
      'createBook',
      'deleteBook',
      'readBookBindings',
      'updateBookBindings',
      'readPreset',
      'replacePreset',
      'readTavernRegexesForWrite',
      'replaceTavernRegexes',
      'readCharacterAvatar',
      'replaceCharacterAvatar',
    });
    expect(unattached.slashCommands, {
      'setvar',
      'getvar',
      'addvar',
      'incvar',
      'setglobalvar',
      'getglobalvar',
      'flushvar',
      'if',
      'while',
      'times',
      'run',
      'pass',
      'return',
      'break',
      'abort',
      'gen',
      'genraw',
      'trigger',
      'send',
      'sendas',
      'sys',
      'nar',
      'comment',
      'inject',
      'listinjects',
      'flushinject',
      'flushinjects',
      'echo',
      'input',
      'buttons',
      'popup',
      'setinput',
      'hide',
      'unhide',
      'messages',
      'cut',
      'del',
      'getchatbook',
      'findentry',
      'createentry',
      'setentryfield',
    });
    expect(unattached.scopes, {
      TavernVariableScope.global,
      TavernVariableScope.chat,
      TavernVariableScope.character,
      TavernVariableScope.message,
      TavernVariableScope.script,
    });
    expect(unattached.generationOptions, {
      'generationId',
      'presetId',
      'speakerCharacterId',
      'userInput',
      'stream',
      'includeReasoning',
      'silent',
      'maxChatHistory',
      'overrides',
      'injects',
      'samplingOverrides',
      'orderedPrompts',
    });
    expect(unattached.hostAttached, isFalse);
    expect(unattached.hostCapabilities, isEmpty);
    expect(unattached.simulated, isFalse);
    final noHost = await slashFailure(await h.bridge.triggerSlash(context.id, '/genraw lock=true Q'));
    expect(noHost.code, TavernScriptErrorCode.hostUnavailable);
    h.expectNoGeneration();
    final plain = SlashHost();
    h.bridge.attachHost(plain);
    expect(h.bridge.capabilities.hostCapabilities, isEmpty);
    final plainSnapshot = (await h.bridge.snapshot(context.id)).capabilities;
    expect(plainSnapshot.hostAttached, isTrue);
    expect(plainSnapshot.hostCapabilities, isEmpty);
    final unsupported = await slashFailure(await h.bridge.triggerSlash(context.id, '/genraw lock=true Q'));
    expect(unsupported.code, TavernScriptErrorCode.unsupportedCapability);
    h.expectNoGeneration();
    final capable = SlashLockHost();
    h.bridge.attachHost(capable);
    expect(h.bridge.capabilities.hostCapabilities, {'generationLock'});
    final capableSnapshot = (await h.bridge.snapshot(context.id)).capabilities;
    expect(capableSnapshot.hostAttached, isTrue);
    expect(capableSnapshot.hostCapabilities, {'generationLock'});
    expect(capableSnapshot.methods, unattached.methods);
    expect(capableSnapshot.slashCommands, unattached.slashCommands);
    final empty = await slashRun(h, context.id, '/genraw lock=true');
    expect(empty.pipe, '');
    expect(capable.acquisitions, isEmpty);
    expect(capable.releases, isEmpty);
    expect(capable.interactions, isEmpty);
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
    h.bridge.attachHost(plain);
    expect(h.bridge.capabilities.hostAttached, isTrue);
    expect(h.bridge.capabilities.hostCapabilities, isEmpty);
    expect((await h.bridge.snapshot(context.id)).capabilities.hostCapabilities, isEmpty);
    expect(capableSnapshot.hostCapabilities, {'generationLock'});
    expect(plainSnapshot.hostCapabilities, isEmpty);
    expect(unattached.hostAttached, isFalse);
    h.bridge.attachHost(null);
    expect(h.bridge.capabilities.hostCapabilities, isEmpty);
    expect((await h.bridge.snapshot(context.id)).capabilities.hostAttached, isFalse);
  });

  test(
    'normal lock waits for matching release after child ENDED while its lifetime and request remain distinct',
    () async {
      final h = await slashFixture(allowModel: true);
      final actor = await h.card('Lock order');
      final chat = await h.emptyChat(actor);
      final context = await h.context(chat, characterId: actor);
      final host = SlashLockHost();
      final acquireSeen = Completer<TavernScriptGenerationLockAcquireRequest>();
      final releaseSeen = Completer<TavernScriptGenerationLockReleaseRequest>();
      final acquireReply = Completer<TavernScriptGenerationLockAck>();
      final releaseReply = Completer<TavernScriptGenerationLockAck>();
      final ended = Completer<TavernScriptDispatch>();
      var cleaning = false;
      host.onAcquire = (request, token) {
        if (cleaning) return Future.value(_acquireAck(request, TavernScriptGenerationLockStatus.cancelled));
        acquireSeen.complete(request);
        return acquireReply.future;
      };
      host.onRelease = (request, token) {
        if (cleaning) return Future.value(_releaseAck(request, TavernScriptGenerationLockStatus.cancelled));
        releaseSeen.complete(request);
        return releaseReply.future;
      };
      host.onDispatch = (request, token) async {
        if (request.name == 'GENERATION_ENDED' && !ended.isCompleted) ended.complete(request);
        return TavernScriptDispatchAck(eventId: request.eventId);
      };
      h.bridge.attachHost(host);
      addTearDown(() {
        cleaning = true;
        if (host.acquisitions.isNotEmpty && !acquireReply.isCompleted) {
          acquireReply.complete(_acquireAck(host.acquisitions.single, TavernScriptGenerationLockStatus.cancelled));
        }
        if (host.releases.isNotEmpty && !releaseReply.isCompleted) {
          releaseReply.complete(_releaseAck(host.releases.single, TavernScriptGenerationLockStatus.cancelled));
        }
      });
      await h.bridge.replaceVariables(context.id, scriptGlobal, {'PREFILL': '{{random::p::q}}'});
      var draws = 0;
      h.onRandom = () {
        draws++;
      };
      final response = h.reply('LOCKED ANSWER');
      final script = await h.bridge.triggerSlash(context.id, '/genraw lock=true prefill=PREFILL Q');
      final settled = Completer<void>();
      unawaited(
        script.result.then<void>(
          (_) {
            settled.complete();
          },
          onError: (Object error, StackTrace stack) {
            settled.complete();
          },
        ),
      );
      final acquire = await slashSignal(script, acquireSeen.future);
      h.expectNoGeneration();
      expect(draws, 0);
      expect(host.lifetimes.single.isCancelled, isFalse);
      expect(host.releases, isEmpty);
      acquireReply.complete(_acquireAck(acquire, TavernScriptGenerationLockStatus.acquired));
      final wire = await slashSignal(script, response.seen.future);
      expect(generationMessages(wire), [
        {'role': 'user', 'content': 'Q'},
        {'role': 'assistant', 'content': 'p'},
      ]);
      expect(draws, 1);
      final release = await slashSignal(script, releaseSeen.future);
      final childEnded = await slashSignal(script, ended.future);
      expect(childEnded.generationId, isNotNull);
      expect(h.bridge.stopGenerationById(childEnded.generationId!), isFalse);
      expect(release.leaseId, acquire.leaseId);
      expect(release.acquireRequestId, acquire.requestId);
      expect(release.requestId, isNot(acquire.requestId));
      expect(host.lifetimes.single.isCancelled, isTrue);
      expect(host.releaseTokens.single.isCancelled, isFalse);
      expect(settled.isCompleted, isFalse);
      expect(host.interactions, isEmpty);
      expect(await h.engine.path(chat), isEmpty);
      releaseReply.complete(_releaseAck(release, TavernScriptGenerationLockStatus.released));
      final result = await script.result;
      expect(result.pipe, 'LOCKED ANSWER');
      expect(
        result.effects.entries
            .where((effect) => effect.kind == TavernSlashEffectKind.generationLock)
            .map((effect) => effect.state),
        [
          TavernSlashEffectState.acquireRequested,
          TavernSlashEffectState.acquired,
          TavernSlashEffectState.releaseRequested,
          TavernSlashEffectState.released,
        ],
      );
      expect(host.deliveries.where((event) => event.namespace == 'slash' && event.name == 'GENERATION_LOCK'), isEmpty);
      expect(host.acquisitions, hasLength(1));
      expect(host.releases, hasLength(1));
      expect(h.requests, hasLength(1));
      expect(h.keyReads, 1);
      stdout.writeln('P2_B3_LOCK_READY');
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test('release failure preserves decoded child and adopted parameter effects without repeating generation', () async {
    final h = await slashFixture(allowModel: true);
    final actor = await h.card('Release failure');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final host = SlashLockHost();
    host.onAcquire = (request, token) async => _acquireAck(request, TavernScriptGenerationLockStatus.acquired);
    host.onRelease = (request, token) async => _releaseAck(request, TavernScriptGenerationLockStatus.failed);
    h.bridge.attachHost(host);
    final response = h.reply('DECODED BODY');
    final script = await h.bridge.triggerSlash(
      context.id,
      '/genraw lock=true prefill="{{setglobalvar::parameter::yes}}" Q',
    );
    await slashSignal(script, response.seen.future);
    final failure = await slashFailure(script);
    expect(failure.code, TavernScriptErrorCode.hookFailure);
    expect(failure.committed, isTrue);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'parameter': 'yes'});
    final terminal = await script.events.single;
    expect(terminal.status, TavernSlashStatus.failed);
    expect(terminal.partialGeneration!.text, 'DECODED BODY');
    expect(terminal.effects.committed, isTrue);
    expect(host.lifetimes.single.isCancelled, isTrue);
    expect(host.acquisitions, hasLength(1));
    expect(host.releases, hasLength(1));
    expect(h.bridge.stopScript(script.id), isFalse);
    expect(await h.engine.path(chat), isEmpty);
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('pre-ACK cancellation and same-ID reuse retain ownership of each lease and ignore late old acquire', () async {
    final h = await slashFixture();
    final actor = await h.card('Lease reuse');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final host = SlashLockHost();
    final seen = [
      Completer<TavernScriptGenerationLockAcquireRequest>(),
      Completer<TavernScriptGenerationLockAcquireRequest>(),
    ];
    final replies = [Completer<TavernScriptGenerationLockAck>(), Completer<TavernScriptGenerationLockAck>()];
    var cleaning = false;
    host.onAcquire = (request, token) {
      if (cleaning) return Future.value(_acquireAck(request, TavernScriptGenerationLockStatus.cancelled));
      final index = host.acquisitions.length - 1;
      if (index >= seen.length) throw TestFailure('Unexpected additional acquisition.');
      seen[index].complete(request);
      return replies[index].future;
    };
    host.onRelease = (request, token) async => _releaseAck(request, TavernScriptGenerationLockStatus.released);
    h.bridge.attachHost(host);
    final watch = ScriptEvents(h.bridge.watchEvents(chatId: chat));
    addTearDown(() {
      cleaning = true;
      for (var i = 0; i < replies.length && i < host.acquisitions.length; i++) {
        if (!replies[i].isCompleted) {
          replies[i].complete(_acquireAck(host.acquisitions[i], TavernScriptGenerationLockStatus.cancelled));
        }
      }
    });
    final old = await h.bridge.triggerSlash(context.id, '/genraw lock=true Q', executionId: 'reused-lock');
    final oldAcquire = await slashSignal(old, seen[0].future);
    expect(h.bridge.stopScript('reused-lock'), isTrue);
    expect((await slashFailure(old)).code, TavernScriptErrorCode.cancelled);
    final terminal = await old.events.single;
    final frozen = jsonEncode(terminal.effects.toJson());
    expect(terminal.status, TavernSlashStatus.cancelled);
    expect(host.lifetimes[0].isCancelled, isTrue);
    final current = await h.bridge.triggerSlash(context.id, '/genraw lock=true Q', executionId: 'reused-lock');
    final newAcquire = await slashSignal(current, seen[1].future);
    expect(newAcquire.leaseId, isNot(oldAcquire.leaseId));
    expect(newAcquire.requestId, isNot(oldAcquire.requestId));
    final watermark = watch.values.isEmpty ? 0 : watch.values.last.dispatch.seq;
    replies[0].complete(
      _acquireAck(
        oldAcquire,
        TavernScriptGenerationLockStatus.acquired,
        issues: [_lateAckIssue('fixtureLateAcquire', oldAcquire.requestId)],
      ),
    );
    await slashSignal(
      current,
      watch.until(
        (event) => _leaseWatch(
          event,
          oldAcquire.leaseId,
          'acquire',
          after: watermark,
          issueCode: 'fixtureLateAcquire',
          requestId: oldAcquire.requestId,
        ),
      ),
    );
    expect(host.lifetimes[1].isCancelled, isFalse);
    expect(jsonEncode((await old.events.single).effects.toJson()), frozen);
    expect((await old.events.single).lastSeq, terminal.lastSeq);
    expect(h.bridge.stopScript('reused-lock'), isTrue);
    expect((await slashFailure(current)).code, TavernScriptErrorCode.cancelled);
    replies[1].complete(_acquireAck(newAcquire, TavernScriptGenerationLockStatus.cancelled));
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('host replacement inside acquire revokes before old shared host fields can cause an obsolete release', () async {
    final h = await slashFixture();
    final actor = await h.card('Synchronous replacement');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final bridge = h.bridge;
    final replacement = SlashLockHost();
    final old = SlashLockHost()
      ..onAcquire = (request, token) async {
        bridge.attachHost(replacement);
        return _acquireAck(request, TavernScriptGenerationLockStatus.acquired);
      }
      ..onRelease = (request, token) async => _releaseAck(request, TavernScriptGenerationLockStatus.released);
    bridge.attachHost(old);
    final script = await bridge.triggerSlash(context.id, '/genraw lock=true Q');
    final failure = await slashFailure(script);
    expect(failure.code, TavernScriptErrorCode.hostUnavailable);
    expect(old.acquisitions, hasLength(1));
    expect(old.lifetimes.single.isCancelled, isTrue);
    expect(old.releases, isEmpty);
    expect(replacement.acquisitions, isEmpty);
    expect(replacement.releases, isEmpty);
    final terminal = await script.events.single;
    expect(terminal.status, TavernSlashStatus.failed);
    expect(
      terminal.effects.entries.where(
        (effect) =>
            effect.kind == TavernSlashEffectKind.generationLock && effect.state == TavernSlashEffectState.acquired,
      ),
      isEmpty,
    );
    expect(await h.engine.path(chat), isEmpty);
    h.expectNoGeneration();
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('stop during normal release does not wait for its host promise or send a second release', () async {
    final h = await slashFixture(allowModel: true);
    final actor = await h.card('Release stop');
    final chat = await h.emptyChat(actor);
    final context = await h.context(chat, characterId: actor);
    final host = SlashLockHost();
    final releaseSeen = Completer<TavernScriptGenerationLockReleaseRequest>();
    final reply = Completer<TavernScriptGenerationLockAck>();
    var cleaning = false;
    host.onAcquire = (request, token) async => _acquireAck(request, TavernScriptGenerationLockStatus.acquired);
    host.onRelease = (request, token) {
      if (cleaning) return Future.value(_releaseAck(request, TavernScriptGenerationLockStatus.cancelled));
      releaseSeen.complete(request);
      return reply.future;
    };
    h.bridge.attachHost(host);
    final watch = ScriptEvents(h.bridge.watchEvents(chatId: chat));
    addTearDown(() {
      cleaning = true;
      if (!reply.isCompleted && host.releases.isNotEmpty) {
        reply.complete(_releaseAck(host.releases.single, TavernScriptGenerationLockStatus.cancelled));
      }
    });
    final response = h.reply('FINISHED CHILD');
    final script = await h.bridge.triggerSlash(context.id, '/genraw lock=true Q');
    await slashSignal(script, response.seen.future);
    final release = await slashSignal(script, releaseSeen.future);
    expect(reply.isCompleted, isFalse);
    expect(h.bridge.stopScript(script.id), isTrue);
    final failure = await slashFailure(script);
    expect(failure.code, TavernScriptErrorCode.cancelled);
    expect(reply.isCompleted, isFalse);
    final terminal = await script.events.single;
    expect(terminal.status, TavernSlashStatus.cancelled);
    expect(terminal.partialGeneration!.text, 'FINISHED CHILD');
    final frozen = jsonEncode(terminal.effects.toJson());
    final watermark = watch.values.isEmpty ? 0 : watch.values.last.dispatch.seq;
    reply.complete(
      _releaseAck(
        release,
        TavernScriptGenerationLockStatus.released,
        issues: [_lateAckIssue('fixtureLateRelease', release.requestId)],
      ),
    );
    await watch.until(
      (event) => _leaseWatch(
        event,
        release.leaseId,
        'release',
        after: watermark,
        issueCode: 'fixtureLateRelease',
        requestId: release.requestId,
      ),
    );
    expect(host.releases, hasLength(1));
    expect(jsonEncode((await script.events.single).effects.toJson()), frozen);
    expect((await script.events.single).lastSeq, terminal.lastSeq);
    expect(host.deliveries.where((event) => event.namespace == 'slash' && event.name == 'GENERATION_LOCK'), isEmpty);
    expect(await h.engine.path(chat), isEmpty);
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
  }, timeout: const Timeout(Duration(seconds: 15)));
  test(
    'distinct lock acknowledgements preserve repeated diagnostic observations through success and failure',
    () async {
      final sharedIssue = TavernScriptIssue(
        code: 'fixtureSharedLockIssue',
        message: 'The host deliberately reuses this immutable issue object.',
        committed: false,
        details: {'fixture': 'shared-issue'},
      );
      for (final releaseFails in [false, true]) {
        final h = await slashFixture(allowModel: true);
        final actor = await h.card('Repeated acknowledgement issue $releaseFails');
        final chat = await h.emptyChat(actor);
        final context = await h.context(chat, characterId: actor);
        final host = SlashLockHost();
        host.onAcquire = (request, token) async =>
            _acquireAck(request, TavernScriptGenerationLockStatus.acquired, issues: [sharedIssue]);
        host.onRelease = (request, token) async => _releaseAck(
          request,
          releaseFails ? TavernScriptGenerationLockStatus.failed : TavernScriptGenerationLockStatus.released,
          issues: [sharedIssue],
        );
        h.bridge.attachHost(host);
        final response = h.reply('DIAGNOSTIC BODY');
        final script = await h.bridge.triggerSlash(context.id, '/genraw lock=true Q');
        await slashSignal(script, response.seen.future);
        final List<TavernScriptIssue> issues;
        if (releaseFails) {
          final failure = await slashFailure(script);
          expect(failure.code, TavernScriptErrorCode.hookFailure);
          issues = failure.issues;
        } else {
          issues = (await script.result).issues;
        }
        expect(
          issues.where((issue) => issue.code == 'fixtureSharedLockIssue'),
          hasLength(2),
          reason: 'Acquire and release are two actual observations even when their issue object is identical.',
        );
        final terminal = await script.events.single;
        expect(
          terminal.issues.where((issue) => issue.code == 'fixtureSharedLockIssue'),
          hasLength(2),
          reason: 'Terminal projection must retain both observations without adding propagation copies.',
        );
        expect(host.acquisitions, hasLength(1));
        expect(host.releases, hasLength(1));
        expect(await h.engine.path(chat), isEmpty);
        expect(h.requests, hasLength(1));
        expect(h.keyReads, 1);
      }
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );
}

TavernScriptGenerationLockAck _acquireAck(
  TavernScriptGenerationLockAcquireRequest request,
  TavernScriptGenerationLockStatus status, {
  List<TavernScriptIssue> issues = const [],
}) => TavernScriptGenerationLockAck(
  requestId: request.requestId,
  leaseId: request.leaseId,
  status: status,
  issues: issues,
);

TavernScriptGenerationLockAck _releaseAck(
  TavernScriptGenerationLockReleaseRequest request,
  TavernScriptGenerationLockStatus status, {
  List<TavernScriptIssue> issues = const [],
}) => TavernScriptGenerationLockAck(
  requestId: request.requestId,
  leaseId: request.leaseId,
  status: status,
  issues: issues,
);

TavernScriptIssue _lateAckIssue(String code, String requestId) => TavernScriptIssue(
  code: code,
  message: 'Unique marker supplied only by this late lock acknowledgement.',
  committed: false,
  details: {'requestId': requestId},
);

bool _leaseWatch(
  TavernScriptEvent event,
  String leaseId,
  String operation, {
  required int after,
  required String issueCode,
  required String requestId,
}) {
  final dispatch = event.dispatch;
  return dispatch.seq > after &&
      dispatch.namespace == 'slash' &&
      dispatch.name == 'GENERATION_LOCK' &&
      event.issues.any((issue) => issue.code == issueCode && issue.details['requestId'] == requestId) &&
      dispatch.args.any(
        (value) => value is Map<String, Object?> && value['leaseId'] == leaseId && value['operation'] == operation,
      );
}
