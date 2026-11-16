// The App's TavernScriptHost (P2 B1): what the engine delivers to a script
// context goes to the page holding that context.
//
// - cache: the change (variables, messages, revisions) is put into the page
//   for its own copy, at once; it never waits on any script's handler, as the
//   engine's notes require (a handler awaiting a write needs that write's
//   cache to get through).
// - lifecycle: the page runs its handlers (eventOn), waits for them and for
//   the writes they started, and says how it went; the engine is answered
//   then — or when it cancels, or as failed when the page goes before
//   answering. A page not ready yet has no handlers: nothing ran, said so.
// - invoke: a prompt's filter is a function the page keeps; the page runs it
//   and says true or false (or how it failed), its writes back first.
// - interact: a script's /input, /buttons, /popup, /echo or /setinput is shown
//   by the app itself for the chat whose page holds the context (never in the
//   card's page); taken back when the engine cancels it or the page closes.
// - slash lookups are refused as unsupported (the app keeps no script
//   library), never answered with an empty success.
// - refresh: the chat page redraws from its own watch of the path.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';

import 'tavern_interact.dart';
import 'tavern_script_wire.dart';

/// Puts one delivery (JSON) into a page; false when there was no page ready
/// to take it.
typedef TavernScriptPage = Future<bool> Function(Map<String, Object?> delivery);

/// Shows a script's UI request for its chat and says how the person left
/// it; [withdraw] completes when the request is taken back.
typedef TavernScriptInteractor = Future<TavernInteractAnswer> Function(
  TavernInteractKind kind,
  Map<String, Object?> fields, {
  required Future<void> withdraw,
});

class TavernScriptPages implements TavernScriptHost {
  final _pages = <String, TavernScriptPage>{};
  TavernScriptBridge? _attached;

  /// Lifecycle events a page is running, by event: which context, and the
  /// answer the engine waits for.
  final _waiting = <String, ({String contextId, Completer<TavernScriptDispatchAck> answer})>{};

  /// Who shows UI requests for a context: its chat's screen.
  final _interactors = <String, TavernScriptInteractor>{};

  /// UI requests on screen, by request: whose, and how to take one back.
  final _asking = <String, ({String contextId, Completer<void> withdraw})>{};

  /// Filters a page is running, by request.
  final _invoking =
      <
        String,
        ({String contextId, TavernScriptCallbackRequest request, Completer<TavernScriptCallbackResult> answer})
      >{};

  /// Becomes [bridge]'s host, once.
  void attach(TavernScriptBridge bridge) {
    if (identical(_attached, bridge)) return;
    _attached = bridge;
    bridge.attachHost(this);
  }

  void add(String contextId, TavernScriptPage page, {TavernScriptInteractor? interact}) {
    _pages[contextId] = page;
    if (interact != null) {
      _interactors[contextId] = interact;
    } else {
      _interactors.remove(contextId);
    }
  }

  /// The page closed: what it was running did not finish, and what its
  /// scripts asked the person is taken back.
  void remove(String contextId) {
    _pages.remove(contextId);
    _interactors.remove(contextId);
    drop(contextId);
    for (final asking in [..._asking.values]) {
      if (asking.contextId == contextId && !asking.withdraw.isCompleted) asking.withdraw.complete();
    }
  }

  /// The page for [contextId] went (closed, or its renderer was lost):
  /// what it was running did not finish.
  void drop(String contextId) {
    for (final MapEntry(:key, :value) in [..._waiting.entries]) {
      if (value.contextId != contextId) continue;
      _waiting.remove(key);
      if (!value.answer.isCompleted) {
        value.answer.complete(_failed(key, contextId, 'pageGone', 'The page went before its handlers finished.'));
      }
    }
    for (final MapEntry(:key, :value) in [..._invoking.entries]) {
      if (value.contextId != contextId) continue;
      _invoking.remove(key);
      if (!value.answer.isCompleted) {
        value.answer.completeError(_unavailable(value.request, 'The page went before its filter answered.'));
      }
    }
  }

  /// The page's answer for a lifecycle event: {status, issues}.
  void acknowledge(String eventId, Map<Object?, Object?> answer) {
    final waiting = _waiting.remove(eventId);
    if (waiting == null || waiting.answer.isCompleted) return;
    // A candidate a listener left in another shape (a command that is not
    // an object…) is not taken: the event failed, said why.
    final raw = answer['mvu'];
    final Object? mvu;
    if (raw == null) {
      mvu = null;
    } else if (raw case {'data': final Map<String, Object?> data}
        when (raw['commands'] == null ||
                raw['commands'] is List<Object?> &&
                    (raw['commands']! as List<Object?>).every((c) => c is Map<String, Object?>)) &&
            (raw['beforeData'] == null || raw['beforeData'] is Map<String, Object?>)) {
      mvu = TavernScriptMvuFeedback(
        data: data,
        commands: (raw['commands'] as List<Object?>?)?.cast<Map<String, Object?>>(),
        beforeData: raw['beforeData'] as Map<String, Object?>?,
      );
    } else {
      mvu = false;
    }
    final status = mvu == false
        ? TavernScriptAckStatus.failed
        : switch (answer['status']) {
            'failed' => TavernScriptAckStatus.failed,
            'cancelled' => TavernScriptAckStatus.cancelled,
            _ => TavernScriptAckStatus.completed,
          };
    TavernScriptIssue issue(String code, String message) => TavernScriptIssue(
      code: code,
      message: message,
      committed: false,
      contextId: waiting.contextId,
      eventId: eventId,
      stage: 'handler',
    );
    waiting.answer.complete(
      TavernScriptDispatchAck(
        eventId: eventId,
        status: status,
        issues: [
          for (final x in (answer['issues'] as List?) ?? const [])
            if (x is Map) issue('${x['code'] ?? 'hookFailure'}', '${x['message'] ?? ''}'),
          if (mvu == false) issue('invalidArgument', 'MVU listeners left the candidate in a shape it cannot take.'),
        ],
        mvu: mvu is TavernScriptMvuFeedback ? mvu : null,
      ),
    );
  }

  @override
  Future<TavernScriptDispatchAck> dispatch(TavernScriptDispatch request, TavernScriptCancellation cancellation) async {
    final page = _pages[request.contextId];
    final done = TavernScriptDispatchAck(eventId: request.eventId);
    if (page == null || cancellation.isCancelled) return done;
    if (request.kind == TavernScriptDispatchKind.cache) {
      try {
        await page(tavernScriptDeliveryJson(request));
      } on Object {
        // The page went (its renderer, the screen): it reloads a snapshot
        // when it comes back. The engine's write is not undone by that.
      }
      return done;
    }
    final answer = Completer<TavernScriptDispatchAck>();
    _waiting[request.eventId] = (contextId: request.contextId, answer: answer);
    final bool delivered;
    try {
      delivered = await page(tavernScriptDeliveryJson(request));
    } on Object {
      _waiting.remove(request.eventId);
      return _failed(request.eventId, request.contextId, 'pageGone', 'The page could not take the event.');
    }
    if (!delivered) {
      _waiting.remove(request.eventId);
      return done;
    }
    final cancelled = cancellation.whenCancelled.then(
      (_) => TavernScriptDispatchAck(eventId: request.eventId, status: TavernScriptAckStatus.cancelled),
    );
    try {
      return await Future.any([answer.future, cancelled]);
    } finally {
      _waiting.remove(request.eventId);
    }
  }

  /// A script's UI request, shown by its chat's screen: how the person left
  /// it is the answer (what they wrote, the button they chose; nothing made
  /// up). Cancelled by the engine, or its page closed, it is taken back and
  /// answered cancelled.
  @override
  Future<TavernScriptUiResult> interact(TavernScriptUiRequest request, TavernScriptCancellation cancellation) async {
    final kind = tavernInteractKind(request.kind);
    if (kind == null) throw _unsupported('interact ${request.kind}');
    final show = _interactors[request.contextId];
    if (show == null) {
      throw TavernScriptException(
        code: TavernScriptErrorCode.hostUnavailable,
        operation: 'interact',
        message: 'No chat on screen holds that context now.',
        contextId: request.contextId,
      );
    }
    if (cancellation.isCancelled) {
      return TavernScriptUiResult(requestId: request.requestId, status: TavernInteractStatus.cancelled.name);
    }
    final withdraw = Completer<void>();
    _asking[request.requestId] = (contextId: request.contextId, withdraw: withdraw);
    unawaited(
      cancellation.whenCancelled.then((_) {
        if (!withdraw.isCompleted) withdraw.complete();
      }),
    );
    try {
      final answer = await show(kind, request.fields, withdraw: withdraw.future);
      return TavernScriptUiResult(
        requestId: request.requestId,
        status: answer.status.name,
        text: answer.text,
        buttonIndex: answer.buttonIndex,
        label: answer.label,
      );
    } finally {
      _asking.remove(request.requestId);
    }
  }

  /// A prompt's filter, run by the page that keeps it: called with the
  /// request's arguments; its true or false (anything else is not an answer),
  /// once the writes it started are back. Its page gone or not there, the
  /// function is not to be had; the engine cancelling, cancelled.
  @override
  Future<TavernScriptCallbackResult> invoke(
    TavernScriptCallbackRequest request,
    TavernScriptCancellation cancellation,
  ) async {
    final contextId = request.ref.contextId;
    final page = _pages[contextId];
    if (page == null) throw _unavailable(request, 'No page holds that context now.');
    if (cancellation.isCancelled) return TavernScriptCallbackResult(requestId: request.requestId, status: 'cancelled');
    final answer = Completer<TavernScriptCallbackResult>();
    _invoking[request.requestId] = (contextId: contextId, request: request, answer: answer);
    final bool delivered;
    try {
      delivered = await page({
        'kind': 'invoke',
        'requestId': request.requestId,
        'contextId': contextId,
        'instanceId': request.ref.instanceId,
        'callbackId': request.ref.callbackId,
        'callbackKind': request.kind,
        'args': request.args,
      });
    } on Object {
      _invoking.remove(request.requestId);
      throw _unavailable(request, 'The page could not take the call.');
    }
    if (!delivered) {
      _invoking.remove(request.requestId);
      throw _unavailable(request, 'The page is not ready.');
    }
    final cancelled = cancellation.whenCancelled.then(
      (_) => TavernScriptCallbackResult(requestId: request.requestId, status: 'cancelled'),
    );
    try {
      return await Future.any([answer.future, cancelled]);
    } finally {
      _invoking.remove(request.requestId);
    }
  }

  /// The page's answer to a filter: {status: completed, value} or {status:
  /// failed, message}, with the issues of writes it started that failed
  /// unwatched.
  void invoked(String requestId, Map<Object?, Object?> answer) {
    final waiting = _invoking.remove(requestId);
    if (waiting == null || waiting.answer.isCompleted) return;
    final ok = answer['status'] == 'completed';
    TavernScriptIssue issue(Object? code, Object? message) => TavernScriptIssue(
      code: '${code ?? 'hookFailure'}',
      message: '${message ?? ''}',
      committed: false,
      contextId: waiting.contextId,
      stage: 'filter',
    );
    waiting.answer.complete(
      TavernScriptCallbackResult(
        requestId: requestId,
        status: ok ? 'completed' : 'failed',
        value: ok
            ? switch (answer['value']) {
                final bool b => b,
                _ => null,
              }
            : null,
        issues: [
          if (!ok) issue('hookFailure', answer['message']),
          for (final x in (answer['issues'] as List?) ?? const [])
            if (x is Map) issue(x['code'], x['message']),
        ],
      ),
    );
  }

  @override
  Future<TavernResolvedSlash?> resolveSlash(TavernSlashReference request, TavernScriptCancellation cancellation) =>
      Future.error(_unsupported('resolveSlash'));

  @override
  Future<void> refresh(TavernScriptRefreshRequest request) async {}
}

TavernScriptDispatchAck _failed(String eventId, String contextId, String code, String message) =>
    TavernScriptDispatchAck(
      eventId: eventId,
      status: TavernScriptAckStatus.failed,
      issues: [
        TavernScriptIssue(
          code: code,
          message: message,
          committed: false,
          contextId: contextId,
          eventId: eventId,
          stage: 'handler',
        ),
      ],
    );

TavernScriptException _unavailable(TavernScriptCallbackRequest request, String message) => TavernScriptException(
  code: TavernScriptErrorCode.callbackUnavailable,
  operation: 'invoke',
  message: message,
  contextId: request.ref.contextId,
);

TavernScriptException _unsupported(String operation) => TavernScriptException(
  code: TavernScriptErrorCode.unsupportedCapability,
  operation: operation,
  message: 'The app does not answer $operation for card scripts yet.',
);

/// A delivery as the page reads it; a revision is the string it was given,
/// and a floor whose message went is kept as null.
Map<String, Object?> tavernScriptDeliveryJson(TavernScriptDispatch d) {
  final delta = d.delta;
  return {
    'kind': d.kind.name,
    'eventId': d.eventId,
    'contextId': d.contextId,
    'seq': d.seq,
    'namespace': d.namespace,
    'name': d.name,
    'args': d.args,
    'generationId': d.generationId,
    'nodeRef': d.nodeRef == null ? null : tavernScriptRefJson(d.nodeRef!),
    'messageId': d.messageId,
    'swipeId': d.swipeId,
    'pathRevision': d.pathRevision,
    'delta': delta == null
        ? null
        : {
            'baseRevision': delta.baseRevision,
            'newRevision': delta.newRevision,
            'upsertMessages': [for (final m in delta.upsertMessages) tavernScriptMessageJson(m)],
            'removedRefs': [for (final r in delta.removedRefs) tavernScriptRefJson(r)],
            'indexChanges': {
              for (final MapEntry(:key, :value) in delta.indexChanges.entries)
                '$key': value == null ? null : tavernScriptRefJson(value),
            },
            'variables': [for (final v in delta.variableSnapshots) tavernScriptVariablesJson(v)],
            'resourceRefs': delta.resourceRefs,
          },
  };
}
