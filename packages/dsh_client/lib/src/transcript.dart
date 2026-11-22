/// Folds [DshEvent]s from `DshClient.watch` into renderable chat items.
///
/// Feed every event to [ChatTranscript.apply] and render [ChatTranscript.items].
/// Durable events are merged by `seq` (so resync snapshots and older history
/// pages are idempotent); live assistant-stream frames become a streaming
/// draft that is replaced by the durable `assistant/message` when it lands.
library;

import 'dart:collection';

import 'goals_api.dart';
import 'json.dart';
import 'models.dart';
import 'todos_fold.dart';

sealed class ChatItem {
  const ChatItem();

  /// Stable key for list diffing.
  String get key;
}

/// What the person typed (plus images/files).
final class UserChatItem extends ChatItem {
  const UserChatItem({
    required this.seq,
    required this.time,
    required this.text,
    required this.images,
    required this.files,
    this.requestId,
    this.sourceKind = 'user',
  });

  final int seq;
  final DateTime time;
  final String text;
  final List<ImageAttachment> images;
  final List<FileAttachment> files;

  /// Matches the `requestId` returned by `DshClient.prompt` (optimistic echo).
  final String? requestId;
  final String sourceKind;

  @override
  String get key => 'u$seq';
}

/// Assistant text + reasoning of one step (tool calls follow as [ToolChatItem]s).
final class AssistantChatItem extends ChatItem {
  const AssistantChatItem({
    required this.id,
    required this.text,
    required this.reasoning,
    this.seq,
    this.time,
    this.streaming = false,
    this.interrupted = false,
    this.isFinalAnswer = false,
    this.usage,
    this.model,
    this.rowKey,
  });

  /// `a<seq>` for durable messages, `d<attemptId>` for live drafts.
  final String id;

  /// `m<turn>.<step>`, shared by a draft and the message it commits to, so the row keeps its widget state.
  final String? rowKey;
  final int? seq;
  final DateTime? time;
  final String text;
  final String reasoning;

  /// Still receiving deltas.
  final bool streaming;

  /// The turn was cancelled mid-stream; [text] is the delivered prefix.
  final bool interrupted;

  /// The committed message contains explicitly marked final-answer text.
  final bool isFinalAnswer;
  final TokenUsage? usage;
  final String? model;

  @override
  String get key => rowKey ?? id;
}

enum ToolStatus {
  /// Arguments are still streaming from the model.
  streaming,

  /// Dispatched, no result yet.
  running,

  /// An `approval/request` for this call is waiting for an answer.
  awaitingApproval,
  succeeded,
  failed,

  /// The approval was rejected/cancelled/unavailable.
  denied,

  /// The turn ended before a result arrived.
  cancelled,
}

final class ToolChatItem extends ChatItem {
  const ToolChatItem({
    required this.callId,
    required this.name,
    required this.arguments,
    required this.status,
    this.seq,
    this.resultParts = const [],
    this.failure,
    this.approvalOutcome,
    this.pendingApproval,
    this.meta,
  });

  final String callId;
  final String name;

  /// Raw JSON arguments (possibly partial while [status] is streaming).
  final String arguments;
  final ToolStatus status;
  final int? seq;
  final List<Part> resultParts;
  final ToolFailure? failure;
  final ApprovalOutcome? approvalOutcome;

  /// Answer this with `DshClient.respondApproval` to unblock the call.
  final ApprovalRequest? pendingApproval;
  final Object? meta;

  String get resultText => resultParts.whereType<TextPart>().map((p) => p.text).join();

  @override
  String get key => 't$callId';
}

/// Turn-level notices: errors, cancellation, retries, max-tokens.
final class NoticeChatItem extends ChatItem {
  const NoticeChatItem({required this.seq, required this.kind, required this.text, this.failure});

  final int seq;

  /// `error`, `aborted`, `blocked`, `max-tokens`, `retry`, `interrupted`.
  final String kind;
  final String text;
  final LlmFailure? failure;

  @override
  String get key => 'n$seq';
}

class ChatTranscript {
  ChatTranscript({this.showSyntheticUserMessages = false});

  /// Show injected context (`runtime-context`, `skill-catalog`, ...) too.
  final bool showSyntheticUserMessages;

  final SplayTreeMap<int, SessionLogEvent> _log = SplayTreeMap();
  final Map<String, _Draft> _drafts = {};
  final Map<String, ApprovalRequest> _approvals = {};
  final Map<String, UserQuestionRequest> _questions = {};
  Map<String, List<Message>> _inbox = const {'next-turn': [], 'next-step': []};
  List<ChatItem>? _durable;
  // The live projection also stays stable until its durable base or drafts change.
  List<ChatItem>? _items;
  _DurableFold? _durableFold;
  final List<SessionLogEvent> _durableTail = [];
  bool? _derivedRunning;
  List<TurnTrace>? _traces;
  List<TurnTrace> _previousTraces = const [];
  List<TurnTrace>? _completedTracePrefix;
  ({List<TodoItem>? todos})? _todos;
  ({GoalProjection? goal})? _goal;
  bool? _runningOverride;

  SessionProjections projections = SessionProjections.empty;
  SessionHeader? header;
  String? _title;
  int cursor = -1;

  /// Older history exists before [oldestSeq]; load it with `history()`.
  bool hasMoreHistory = false;
  DshConnectionState? connectionState;

  String? get title => _title ?? projections.title;
  int? get oldestSeq => _log.isEmpty ? null : _log.firstKey();
  int? get newestSeq => _log.isEmpty ? null : _log.lastKey();

  /// Pending approvals for this session, keyed by eventId.
  Map<String, ApprovalRequest> get pendingApprovals => Map.unmodifiable(_approvals);
  Map<String, UserQuestionRequest> get pendingQuestions => Map.unmodifiable(_questions);

  /// Prompts accepted by the Host but not yet in the transcript: steering
  /// messages (picked up at the running turn's next step) first, then those
  /// queued for the next turn. DSH writes `user/message` only once a prompt
  /// leaves the inbox.
  List<QueuedPrompt> get inbox => [
    for (final m in _inbox['next-step'] ?? const <Message>[]) QueuedPrompt(m, steering: true),
    for (final m in _inbox['next-turn'] ?? const <Message>[]) QueuedPrompt(m, steering: false),
  ];

  /// Whether a turn is in progress (Host status when known, else derived).
  bool get running {
    if (_runningOverride != null) return _runningOverride!;
    if (_derivedRunning case final cached?) return cached;
    int? lastStart;
    int? lastEnd;
    for (final event in _log.values) {
      if (event is TurnStartedEvent) lastStart = event.seq;
      if (event is TurnEndedEvent) lastEnd = event.seq;
    }
    return _derivedRunning = lastStart != null && (lastEnd == null || lastEnd < lastStart);
  }

  Iterable<SessionLogEvent> get events => _log.values;

  /// Where each loaded turn's time went ([traceTurns] over the merged log).
  /// Finished turns keep their [TurnTrace] instance across later events.
  List<TurnTrace> get turns => _traces ??= _buildTraces();

  List<TurnTrace> _buildTraces() {
    final prefix = _completedTracePrefix;
    final traces = prefix == null || prefix.isEmpty
        ? traceTurns(_log.values, reuse: _previousTraces)
        : [...prefix, ...traceTurns(_traceEventsAfter(prefix.last.endSeq!), reuse: _previousTraces)];
    // Own this list: callers may mutate the growable result returned by turns.
    // An implicit interrupted turn has no endSeq and cannot bound a prefix.
    _completedTracePrefix = traces.takeWhile((trace) => trace.endSeq != null).toList(growable: false);
    return traces;
  }

  Iterable<SessionLogEvent> _traceEventsAfter(int boundary) sync* {
    var seq = _log.firstKeyAfter(boundary);
    while (seq != null) {
      yield _log[seq]!;
      seq = _log.firstKeyAfter(seq);
    }
  }

  /// The session's current todo list, as the Host's `todos` projection has
  /// it ([foldTodos]): the latest `todo/write`, cleared when the next turn
  /// starts, kept after its turn ends. Null when there is none.
  List<TodoItem>? get todos {
    final cached = _todos;
    if (cached != null) return cached.todos;
    final todos = foldTodos(projections, _log.values);
    _todos = (todos: todos);
    return todos;
  }

  /// The session's current goal, as the Host's `goal` projection has it
  /// ([foldGoalProjection]). Null when there is none (or it was cleared).
  GoalProjection? get goal {
    final cached = _goal;
    if (cached != null) return cached.goal;
    final goal = foldGoalProjection(projections, _log.values);
    _goal = (goal: goal);
    return goal;
  }

  void _logChanged({SessionLogEvent? appended}) {
    if (appended == null) {
      _completedTracePrefix = null;
      _durableFold = null;
      _durableTail.clear();
      _derivedRunning = null;
    } else {
      if (_durableFold != null) _durableTail.add(appended);
      if (_derivedRunning != null) {
        if (appended is TurnStartedEvent) _derivedRunning = true;
        if (appended is TurnEndedEvent) _derivedRunning = false;
      }
    }
    // An appended event the fold ignores (turn start, usage, model, title…)
    // keeps the built items, and the list: nothing shown changed.
    if (appended == null || _DurableFold.folds(appended, showSyntheticUserMessages)) {
      _durable = null;
      _items = null;
    }
    if (_traces case final traces?) _previousTraces = traces;
    _traces = null;
    // Only these appended events change the two projections. Snapshots,
    // history and replacements still invalidate both through appended == null.
    if (appended == null || appended is TodoWriteEvent || appended is TurnStartedEvent) _todos = null;
    if (appended == null ||
        appended.type == 'goal/change' ||
        (appended.type == 'user/message' && asMap(appended.data['source'])?['kind'] == 'goal')) {
      _goal = null;
    }
  }

  List<ChatItem> get items {
    final durable = _durable ??= _build();
    if (_drafts.isEmpty) return durable;
    if (_items case final cached?) return cached;
    // A draft shares its step's row key with the message it commits to; keys stay unique when a step
    // is already committed or has more than one live attempt (the latest keeps the key).
    final latest = {for (final draft in _drafts.values) draft.rowKey: draft};
    for (final item in durable.whereType<AssistantChatItem>()) {
      latest.remove(item.key);
    }
    return _items = [
      ...durable,
      for (final draft in _drafts.values) ...draft.items(useRowKey: identical(latest[draft.rowKey], draft)),
    ];
  }

  /// Applies one event; returns `true` when [items] may have changed.
  bool apply(DshEvent event) {
    switch (event) {
      case SessionSnapshotEvent():
        if (!event.isResync) _log.clear();
        header = event.header;
        projections = event.projections;
        _inbox = projections.inbox;
        cursor = event.cursor;
        if (!event.isResync) hasMoreHistory = event.hasMore;
        _drafts.clear();
        _runningOverride = null;
        for (final e in event.events) {
          _log[e.seq] = e;
        }
        _recomputeTitle();
        final active = event.activeAttempt;
        if (active != null) {
          final draft = _Draft(active.attemptId, active.turn, active.step, active.startedAfterSeq);
          for (final timed in active.chunks) {
            draft.apply(timed.chunk);
          }
          draft.nextIndex = active.nextIndex;
          _drafts[active.attemptId] = draft;
        }
        _logChanged();
        return true;
      case SessionLogEvent():
        // The follow cursor may exceed (or trail) the loaded log after snapshots.
        final previousLast = _log.lastKey();
        final appended = previousLast == null || event.seq > previousLast;
        final fresh = event.seq > cursor;
        _log[event.seq] = event;
        if (fresh) cursor = event.seq;
        switch (event) {
          case InboxSplicedEvent() when fresh:
            _spliceInbox(event);
          case TitleChangedEvent():
            _recomputeTitle();
          case TurnStartedEvent():
            _runningOverride = true;
          case TurnEndedEvent():
            _runningOverride = false;
          case AssistantMessageEvent(:final turn, :final step) || AssistantAttemptEvent(:final turn, :final step):
            _drafts.removeWhere((_, d) => d.turn == turn && d.step == step && d.startedAfterSeq < event.seq);
            _items = null;
          default:
            break;
        }
        _logChanged(appended: appended ? event : null);
        return true;
      case AssistantStreamStarted():
        _drafts[event.attemptId] = _Draft(event.attemptId, event.turn, event.step, event.startedAfterSeq);
        _items = null;
        return true;
      case AssistantChunkEvent():
        final draft = _drafts[event.attemptId];
        if (draft == null || event.index < draft.nextIndex) return false;
        draft.apply(event.chunk);
        draft.nextIndex = event.index + 1;
        _items = null;
        return true;
      case AssistantStreamEnded():
        final draft = _drafts[event.attemptId];
        if (draft == null) return false;
        final seq = event.committedSeq;
        if (!event.committed || (seq != null && _log.containsKey(seq))) {
          _drafts.remove(event.attemptId);
        } else {
          draft.streaming = false;
        }
        _items = null;
        return true;
      case ApprovalRequestedEvent(:final request):
        _approvals[request.eventId] = request;
        _durable = null;
        _items = null;
        return true;
      case UserQuestionRequestedEvent(:final request):
        _questions[request.eventId] = request;
        return true;
      case HostRequestCancelledEvent(:final eventId):
        final removed = _approvals.remove(eventId) != null || _questions.remove(eventId) != null;
        if (removed) {
          _durable = null;
          _items = null;
        }
        return removed;
      case SessionStatusEvent(:final running):
        _runningOverride = running;
        return true;
      case ConnectionStateEvent(:final state):
        connectionState = state;
        return true;
      default:
        return false;
    }
  }

  void _spliceInbox(InboxSplicedEvent event) {
    final list = [...?_inbox[event.target]];
    final start = event.start.clamp(0, list.length);
    final end = (start + event.removedCount).clamp(start, list.length);
    list.replaceRange(start, end, event.inserted);
    _inbox = {..._inbox, event.target: list};
  }

  /// Merges an older page from `DshClient.history(beforeSeq: oldestSeq)`.
  void prependHistory(HistoryPage page) {
    for (final e in page.events) {
      _log[e.seq] = e;
    }
    hasMoreHistory = page.hasMore;
    _recomputeTitle();
    _logChanged();
  }

  /// Latest `session/title` in the merged log wins; else the projection.
  void _recomputeTitle() {
    _title = null;
    for (final e in _log.values) {
      if (e is TitleChangedEvent) _title = e.title;
    }
  }

  List<ChatItem> _build() {
    var fold = _durableFold;
    if (fold == null) {
      fold = _DurableFold(showSyntheticUserMessages);
      for (final event in _log.values) {
        fold.apply(event);
      }
      _durableFold = fold;
    } else {
      for (final event in _durableTail) {
        fold.apply(event);
      }
    }
    _durableTail.clear();
    return fold.build(_approvals.values);
  }

  static NoticeChatItem? _turnNotice(int seq, TurnEndReason reason) => switch (reason.kind) {
    'completed' => null,
    'aborted' => NoticeChatItem(seq: seq, kind: 'aborted', text: 'Stopped'),
    'error' => NoticeChatItem(
      seq: seq,
      kind: 'error',
      text: reason.error?.message ?? 'The turn failed',
      failure: reason.error,
    ),
    'max-tokens' => NoticeChatItem(seq: seq, kind: 'max-tokens', text: 'Output token limit reached'),
    'blocked' => NoticeChatItem(seq: seq, kind: 'blocked', text: 'Turn blocked'),
    'interrupted' => NoticeChatItem(seq: seq, kind: 'interrupted', text: 'Interrupted (Host restarted)'),
    _ => null,
  };
}

// Folded prefix of the log, extended by strictly appended events. Tools stay global:
// late results and approvals can still update a row from an ended turn.
class _DurableFold {
  _DurableFold(this.showSyntheticUserMessages);

  final bool showSyntheticUserMessages;
  final items = <Object>[];
  final tools = <String, _ToolBuilder>{};
  final approvalCalls = <String, String>{};
  final messageKeys = <String>{};
  final unresolved = <_ToolBuilder>{};

  /// Whether [apply] can change what [build] gives for [event].
  static bool folds(SessionLogEvent event, bool showSyntheticUserMessages) => switch (event) {
    UserMessageEvent() => event.isHumanPrompt || showSyntheticUserMessages,
    AssistantMessageEvent() ||
    ToolCallEvent() ||
    ToolResultEvent() ||
    ApprovalAskedEvent(callId: _?) ||
    ApprovalDecidedEvent() ||
    TurnEndedEvent() ||
    LlmRetryEvent() => true,
    _ => false,
  };

  _ToolBuilder tool(String callId, String name, String arguments, int seq) {
    return tools.putIfAbsent(callId, () {
      final builder = _ToolBuilder(callId, name, arguments, seq);
      items.add(_ToolPlaceholder(builder));
      unresolved.add(builder);
      return builder;
    });
  }

  void apply(SessionLogEvent event) {
    switch (event) {
      case UserMessageEvent(:final message):
        if (!event.isHumanPrompt && !showSyntheticUserMessages) break;
        items.add(
          UserChatItem(
            seq: event.seq,
            time: event.time,
            text: message.text,
            images: message.parts.whereType<ImagePart>().map((p) => p.attachment).toList(),
            files: message.parts.whereType<FilePart>().map((p) => p.attachment).toList(),
            requestId: event.requestId,
            sourceKind: message.source.kind,
          ),
        );
      case AssistantMessageEvent(:final message):
        final text = message.text;
        final reasoning = message.reasoning;
        if (text.trim().isNotEmpty || reasoning.trim().isNotEmpty || event.interrupted) {
          final rowKey = 'm${event.turn}.${event.step}';
          items.add(
            AssistantChatItem(
              id: 'a${event.seq}',
              rowKey: messageKeys.add(rowKey) ? rowKey : null,
              seq: event.seq,
              time: event.time,
              text: text,
              reasoning: reasoning,
              interrupted: event.interrupted,
              isFinalAnswer: message.isFinalAnswer,
              usage: event.usage,
              model: message.source.model,
            ),
          );
        }
        for (final call in message.toolCalls) {
          tool(call.id, call.name, call.arguments, event.seq);
        }
      case ToolCallEvent():
        tool(event.callId, event.name, event.arguments, event.seq).dispatched = true;
      case ToolResultEvent():
        final builder = tool(event.callId, 'tool', '', event.seq);
        unresolved.remove(builder);
        builder
          ..result = event
          ..dispatched = true;
      case ApprovalAskedEvent(:final callId?):
        approvalCalls[event.approvalId] = callId;
        tools[callId]?.approvalAsked = true;
      case ApprovalDecidedEvent():
        final callId = approvalCalls[event.approvalId];
        if (callId != null) tools[callId]?.approvalOutcome = event.outcome;
      case TurnEndedEvent(:final reason):
        for (final builder in unresolved) {
          builder.turnEnded = true;
        }
        unresolved.clear();
        final notice = ChatTranscript._turnNotice(event.seq, reason);
        if (notice != null) items.add(notice);
      case LlmRetryEvent():
        items.add(
          NoticeChatItem(
            seq: event.seq,
            kind: 'retry',
            text:
                'Retrying model request (${event.retry}${event.maxRetries == null ? '' : '/${event.maxRetries}'})'
                '${event.failure == null ? '' : ': ${event.failure!.message}'}',
            failure: event.failure,
          ),
        );
      default:
        break;
    }
  }

  List<ChatItem> build(Iterable<ApprovalRequest> approvals) {
    final pendingByCall = {
      for (final request in approvals)
        if (request.callId != null) request.callId!: request,
    };
    return [
      for (final item in items)
        if (item is _ToolPlaceholder) item.builder.build(pendingByCall[item.builder.callId]) else item as ChatItem,
    ];
  }
}

class _ToolPlaceholder {
  const _ToolPlaceholder(this.builder);
  final _ToolBuilder builder;
}

class _ToolBuilder {
  _ToolBuilder(this.callId, this.name, this.arguments, this.seq);

  final String callId;
  final String name;
  final String arguments;
  final int seq;
  bool dispatched = false;
  bool approvalAsked = false;
  bool turnEnded = false;
  ApprovalOutcome? approvalOutcome;
  ToolResultEvent? result;

  /// The last item built, and the result it was built from: a call nothing
  /// happened to since keeps its item.
  ToolChatItem? _item;
  ToolResultEvent? _itemResult;

  ToolChatItem build(ApprovalRequest? pending) {
    final result = this.result;
    final ToolStatus status;
    if (result != null) {
      final denied = approvalOutcome != null && approvalOutcome != ApprovalOutcome.allowedOnce;
      status = denied ? ToolStatus.denied : (result.isError ? ToolStatus.failed : ToolStatus.succeeded);
    } else if (pending != null || (approvalAsked && approvalOutcome == null && !turnEnded)) {
      status = ToolStatus.awaitingApproval;
    } else if (turnEnded) {
      status = ToolStatus.cancelled;
    } else {
      status = ToolStatus.running;
    }
    final built = _item;
    if (built != null &&
        built.status == status &&
        identical(_itemResult, result) &&
        // Read from the event's data each time, not kept with it.
        identical(built.meta, result?.meta) &&
        identical(built.pendingApproval, pending) &&
        built.approvalOutcome == approvalOutcome) {
      return built;
    }
    _itemResult = result;
    return _item = ToolChatItem(
      callId: callId,
      name: name,
      arguments: arguments,
      status: status,
      seq: seq,
      resultParts: result?.message.parts ?? const [],
      failure: result?.failure,
      approvalOutcome: approvalOutcome,
      pendingApproval: pending,
      meta: result?.meta,
    );
  }
}

class _DraftBlock {
  _DraftBlock(this.type);
  String type;
  final StringBuffer text = StringBuffer();
  String? toolId;
  String? toolName;
  Part? finished;
}

class _Draft {
  _Draft(this.attemptId, this.turn, this.step, this.startedAfterSeq);

  final String attemptId;
  final int turn;
  final int step;
  final int startedAfterSeq;
  final SplayTreeMap<int, _DraftBlock> blocks = SplayTreeMap();
  int nextIndex = 0;
  bool streaming = true;

  void apply(StreamChunk chunk) {
    switch (chunk) {
      case BlockStartChunk(:final blockIndex, :final blockType):
        blocks[blockIndex] = _DraftBlock(blockType);
      case TextDeltaChunk(:final blockIndex, :final text):
        (blocks[blockIndex] ??= _DraftBlock('text')).text.write(text);
      case ReasoningDeltaChunk(:final blockIndex, :final text):
        (blocks[blockIndex] ??= _DraftBlock('reasoning')).text.write(text);
      case ToolCallDeltaChunk(:final blockIndex, :final id, :final name, :final argumentsDelta):
        final block = blocks[blockIndex] ??= _DraftBlock('tool-call');
        block
          ..toolId = id
          ..toolName = name ?? block.toolName
          ..text.write(argumentsDelta);
      case BlockEndChunk(:final blockIndex, :final block):
        (blocks[blockIndex] ??= _DraftBlock('unknown')).finished = block;
      case FinishChunk():
        streaming = false;
      default:
        break;
    }
  }

  String get rowKey => 'm$turn.$step';

  List<ChatItem> items({required bool useRowKey}) {
    final text = StringBuffer();
    final reasoning = StringBuffer();
    final tools = <ChatItem>[];
    for (final block in blocks.values) {
      final finished = block.finished;
      switch (finished) {
        case TextPart(text: final t):
          text.write(t);
          continue;
        case ReasoningPart(text: final t):
          reasoning.write(t);
          continue;
        case ToolCallPart():
          tools.add(
            ToolChatItem(
              callId: finished.id,
              name: finished.name,
              arguments: finished.arguments,
              status: ToolStatus.running,
            ),
          );
          continue;
        default:
          break;
      }
      switch (block.type) {
        case 'text':
          text.write(block.text);
        case 'reasoning':
          reasoning.write(block.text);
        case 'tool-call':
          tools.add(
            ToolChatItem(
              callId: block.toolId ?? '$attemptId#${tools.length}',
              name: block.toolName ?? '',
              arguments: block.text.toString(),
              status: ToolStatus.streaming,
            ),
          );
      }
    }
    return [
      if (text.isNotEmpty || reasoning.isNotEmpty)
        AssistantChatItem(
          id: 'd$attemptId',
          rowKey: useRowKey ? rowKey : null,
          text: text.toString(),
          reasoning: reasoning.toString(),
          streaming: streaming,
        ),
      ...tools,
    ];
  }
}

/// One prompt waiting in the agent inbox.
class QueuedPrompt {
  const QueuedPrompt(this.message, {required this.steering});

  final Message message;

  /// In `next-step` (joins the running turn) rather than `next-turn`.
  final bool steering;

  /// Inbox item id, for `session/updateQueue`.
  String get id => message.id;

  /// The client `requestId` it was sent with, when sent by a client.
  String? get requestId => message.source.requestId;
  String get text => message.text;
}

// =============================================================================
// Turn traces: where one turn's time went
// =============================================================================

/// What one [TraceSpan] of a turn was spent on.
enum TraceKind {
  /// One model request: from the step's start to its committed message
  /// (retries included).
  model,

  /// A dispatched tool call, from `tool/call` (or from the approval answer
  /// that let it run) to `tool/result`.
  tool,

  /// The turn waits for the person to answer an approval prompt.
  approval,

  /// The turn waits for the person to answer an `ask_user_question` call.
  question,
}

/// Token use summed over model requests (DSH reports uncached input apart
/// from cache reads and writes; billed input is all three).
class TraceUsage {
  const TraceUsage({
    this.uncachedInput = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.output = 0,
    this.reasoning = 0,
    this.requests = 0,
  });

  static const zero = TraceUsage();

  final int uncachedInput;
  final int cacheRead;
  final int cacheWrite;
  final int output;

  /// Part of [output] the model spent reasoning, when the provider reports it.
  final int reasoning;

  /// Requests that reported usage.
  final int requests;

  int get input => uncachedInput + cacheRead + cacheWrite;
  int get total => input + output;
  bool get isEmpty => requests == 0;

  /// Share of input served from the provider's prompt cache.
  double? get cacheHitRate => input == 0 ? null : cacheRead / input;

  TraceUsage add(TokenUsage? usage) {
    if (usage == null) return this;
    return TraceUsage(
      uncachedInput: uncachedInput + usage.inputTokens,
      cacheRead: cacheRead + (usage.cacheReadTokens ?? 0),
      cacheWrite: cacheWrite + (usage.cacheWriteTokens ?? 0),
      output: output + usage.outputTokens,
      reasoning: reasoning + (usage.reasoningTokens ?? 0),
      requests: requests + 1,
    );
  }

  TraceUsage operator +(TraceUsage other) => TraceUsage(
    uncachedInput: uncachedInput + other.uncachedInput,
    cacheRead: cacheRead + other.cacheRead,
    cacheWrite: cacheWrite + other.cacheWrite,
    output: output + other.output,
    reasoning: reasoning + other.reasoning,
    requests: requests + other.requests,
  );
}

/// One timed span of a turn. Times are the Host's durable event timestamps;
/// [end] is null while the span is still going on (nothing is invented for
/// work in progress).
class TraceSpan {
  const TraceSpan({
    required this.kind,
    required this.step,
    required this.seq,
    required this.start,
    this.end,
    this.cutShort = false,
    this.usage,
    this.provider,
    this.model,
    this.firstToken,
    this.lastToken,
    this.retries = 0,
    this.retryFailures = const [],
    this.hasText = false,
    this.hasReasoning = false,
    this.toolCalls = 0,
    this.interrupted = false,
    this.callId,
    this.toolName,
    this.arguments,
    this.dispatched,
    this.failed = false,
    this.outcome,
  });

  final TraceKind kind;

  /// DSH step number (one model request plus the tool calls it made).
  final int step;

  /// The event that names the span: `assistant/message` (model; -1 while the
  /// request is in flight), `tool/call` (tool, question), `approval/asked`.
  final int seq;
  final DateTime start;
  final DateTime? end;

  /// Ended by the turn ending (cancelled, failed), not by its own event.
  final bool cutShort;

  // --- model requests ---
  final TokenUsage? usage;
  final String? provider;
  final String? model;

  /// First streamed token (earlier failed attempts included), when recorded.
  final DateTime? firstToken;

  /// Last streamed token, when recorded.
  final DateTime? lastToken;
  final int retries;
  final List<String> retryFailures;
  final bool hasText;
  final bool hasReasoning;

  /// Tool calls the message asked for.
  final int toolCalls;

  /// The message was cut off by a cancel.
  final bool interrupted;

  // --- tool calls, questions, approvals ---
  final String? callId;
  final String? toolName;

  /// Raw JSON arguments of the call.
  final String? arguments;

  /// When the call was dispatched; [start] is later when it waited for an
  /// approval first.
  final DateTime? dispatched;

  /// The result was an error.
  final bool failed;

  /// Approvals: the answer. Tools: the answer that let them run (or not).
  final ApprovalOutcome? outcome;

  bool get open => end == null;

  /// Waiting for the person rather than for the agent.
  bool get waiting => kind == TraceKind.approval || kind == TraceKind.question;
  Duration? get duration => end?.difference(start);

  /// Time to first token: step start to the first streamed token.
  Duration? get ttft {
    final first = firstToken;
    if (kind != TraceKind.model || first == null) return null;
    final value = first.difference(start);
    return value.isNegative ? null : value;
  }

  /// First token to the committed message (the official trajectory view's
  /// "decoding": TTFT plus decoding is the request's whole time).
  Duration? get decoding {
    final first = firstToken;
    final last = end ?? lastToken;
    if (kind != TraceKind.model || first == null || last == null) return null;
    final value = last.difference(first);
    return value.isNegative ? null : value;
  }

  /// Output tokens per second while decoding; null when not measurable.
  double? get tokensPerSecond {
    final output = usage?.outputTokens;
    final decoding = this.decoding;
    if (output == null || output <= 0 || decoding == null || decoding.inMilliseconds < 200) {
      return null;
    }
    return output / (decoding.inMilliseconds / 1000);
  }
}

/// One turn (`turn/start` … `turn/end`) folded into timed [spans].
class TurnTrace {
  TurnTrace({
    required this.turn,
    required this.startSeq,
    required this.start,
    required this.spans,
    this.endSeq,
    this.end,
    this.endReason,
  });

  final int turn;
  final int startSeq;
  final DateTime start;

  /// `turn/end`; null while the turn runs.
  final int? endSeq;
  final DateTime? end;
  final TurnEndReason? endReason;

  /// In start order (ties by seq).
  final List<TraceSpan> spans;

  bool get running => end == null;
  Duration? get duration => end?.difference(start);

  /// Model requests made (DSH steps that reached the model).
  late final int steps = spans.where((s) => s.kind == TraceKind.model && s.seq >= 0).length;

  late final TraceUsage usage = spans.fold(TraceUsage.zero, (sum, s) => sum.add(s.usage));

  /// Time to first token of the turn's first model request, when recorded.
  late final Duration? ttft = spans.where((s) => s.kind == TraceKind.model).firstOrNull?.ttft;

  /// The span still going on (the latest one), while the turn runs.
  TraceSpan? get current => running ? spans.lastWhereOrNull((s) => s.open) : null;

  /// Summed durations of closed spans by kind (spans may overlap when tools
  /// run concurrently, so the parts can exceed the turn's duration).
  late final Duration modelTime = _sum((s) => s.kind == TraceKind.model);
  late final Duration toolTime = _sum((s) => s.kind == TraceKind.tool);
  late final Duration waitTime = _sum((s) => s.waiting);

  Duration _sum(bool Function(TraceSpan) test) =>
      spans.where((s) => test(s) && !s.open).fold(Duration.zero, (sum, s) => sum + s.duration!);

  /// The model of the turn's last request (`provider`, `model`).
  ({String? provider, String? model}) get lastModel {
    for (final span in spans.reversed) {
      if (span.kind == TraceKind.model && span.model != null) {
        return (provider: span.provider, model: span.model);
      }
    }
    return (provider: null, model: null);
  }
}

extension<T> on Iterable<T> {
  T? lastWhereOrNull(bool Function(T) test) {
    T? found;
    for (final value in this) {
      if (test(value)) found = value;
    }
    return found;
  }
}

/// Folds durable session events into one [TurnTrace] per turn, oldest first.
///
/// - A model span runs from `step/start` (else from the previous boundary:
///   turn start, last tool result, last message) to its `assistant/message`;
///   TTFT comes from the timed stream stored with the message, as in the
///   official trajectory view (step start to first token, earlier failed
///   attempts included).
/// - A tool span runs from `tool/call` to `tool/result`; when the call waited
///   for an approval, the wait is its own [TraceKind.approval] span and the
///   tool span starts at the answer.
/// - `ask_user_question` calls are [TraceKind.question] spans.
/// - Turns whose `turn/start` is not loaded are skipped (no honest start).
/// - While a turn runs, unfinished work is an open span; when nothing is
///   dispatched the model is being asked, so an open model span from the
///   last boundary stands for it.
///
/// [reuse]: earlier traces; finished turns with the same start and end are
/// returned as the same instance (durable events never change).
List<TurnTrace> traceTurns(Iterable<SessionLogEvent> events, {List<TurnTrace> reuse = const []}) {
  final finished = {
    for (final trace in reuse)
      if (!trace.running) trace.startSeq: trace,
  };
  final out = <TurnTrace>[];
  _TurnTracer? current;
  int? skipThrough;
  for (final event in events) {
    if (skipThrough != null) {
      if (event.seq <= skipThrough) continue;
      skipThrough = null;
    }
    if (event is TurnStartedEvent) {
      if (current != null) out.add(current.finish(null, current.lastSeen));
      final known = finished[event.seq];
      if (known != null && known.endSeq != null) {
        out.add(known);
        skipThrough = known.endSeq;
        current = null;
        continue;
      }
      current = _TurnTracer(event.turn, event.seq, event.time);
      continue;
    }
    final tracer = current;
    if (tracer == null) continue;
    if (event is TurnEndedEvent) {
      out.add(tracer.finish(event, event.time));
      current = null;
      continue;
    }
    tracer.apply(event);
  }
  if (current != null) out.add(current.running());
  return out;
}

class _OpenTool {
  _OpenTool(this.event) : start = event.time;
  final ToolCallEvent event;
  DateTime start;
  ApprovalOutcome? outcome;
  bool waiting = false;
}

class _OpenApproval {
  _OpenApproval(this.event);
  final ApprovalAskedEvent event;
}

class _TurnTracer {
  _TurnTracer(this.turn, this.startSeq, this.start) : boundary = start, lastSeen = start;

  final int turn;
  final int startSeq;
  final DateTime start;

  /// Latest moment the agent was between two pieces of work.
  DateTime boundary;

  /// Time of the latest event of the turn.
  DateTime lastSeen;
  int lastStep = 0;
  final List<TraceSpan> spans = [];
  final Map<int, DateTime> stepStarts = {};
  final Map<int, DateTime> attemptFirstToken = {};
  final Map<int, List<String>> retries = {};
  final Map<String, _OpenTool> tools = {};
  final Map<String, _OpenApproval> approvals = {};

  void apply(SessionLogEvent event) {
    if (event.time.isAfter(lastSeen)) lastSeen = event.time;
    switch (event) {
      case StepStartedEvent(:final step):
        stepStarts[step] = event.time;
        if (step > lastStep) lastStep = step;
      case AssistantAttemptEvent(:final step):
        final first = _streamBounds(event.data['stream']).first;
        if (first != null) {
          final known = attemptFirstToken[step];
          if (known == null || first.isBefore(known)) attemptFirstToken[step] = first;
        }
      case LlmRetryEvent(:final step, :final failure):
        (retries[step] ??= []).add(failure?.message ?? '');
      case AssistantMessageEvent(:final step, :final message):
        if (step > lastStep) lastStep = step;
        final bounds = _streamBounds(event.data['stream']);
        var first = bounds.first;
        final attempt = attemptFirstToken.remove(step);
        if (attempt != null && (first == null || attempt.isBefore(first))) first = attempt;
        final failures = retries.remove(step) ?? const [];
        spans.add(
          TraceSpan(
            kind: TraceKind.model,
            step: step,
            seq: event.seq,
            start: stepStarts.remove(step) ?? boundary,
            end: event.time,
            usage: event.usage,
            provider: message.source.provider,
            model: message.source.model,
            firstToken: first,
            lastToken: bounds.last,
            retries: failures.length,
            retryFailures: List.unmodifiable(failures.where((f) => f.isNotEmpty)),
            hasText: message.parts.any((p) => p is TextPart && p.text.trim().isNotEmpty),
            hasReasoning: message.parts.any((p) => p is ReasoningPart && p.text.trim().isNotEmpty),
            toolCalls: message.parts.whereType<ToolCallPart>().length,
            interrupted: event.interrupted,
          ),
        );
        boundary = event.time;
      case ToolCallEvent(:final callId):
        tools[callId] = _OpenTool(event);
      case ApprovalAskedEvent(:final callId):
        approvals[event.approvalId] = _OpenApproval(event);
        if (callId != null) tools[callId]?.waiting = true;
      case ApprovalDecidedEvent(:final approvalId, :final outcome):
        final asked = approvals.remove(approvalId);
        if (asked == null) break;
        spans.add(_approvalSpan(asked, event.time, outcome: outcome));
        final tool = tools[asked.event.callId];
        if (tool != null) {
          tool
            ..start = event.time
            ..outcome = outcome
            ..waiting = false;
        }
      case ToolResultEvent(:final callId):
        final tool = tools.remove(callId);
        if (tool == null) break;
        for (final entry in approvals.entries.toList()) {
          if (entry.value.event.callId == callId) {
            spans.add(_approvalSpan(entry.value, event.time, cutShort: true));
            approvals.remove(entry.key);
          }
        }
        spans.add(_toolSpan(tool, end: event.time, failed: event.isError));
        boundary = event.time;
      case StepEndedEvent() || UserMessageEvent():
        if (event.time.isAfter(boundary)) boundary = event.time;
      default:
        break;
    }
  }

  TraceSpan _approvalSpan(_OpenApproval asked, DateTime? end, {ApprovalOutcome? outcome, bool cutShort = false}) =>
      TraceSpan(
        kind: TraceKind.approval,
        step: tools[asked.event.callId]?.event.step ?? lastStep,
        seq: asked.event.seq,
        start: asked.event.time,
        end: end,
        cutShort: cutShort,
        callId: asked.event.callId,
        toolName: asked.event.toolName,
        arguments: tools[asked.event.callId]?.event.arguments,
        outcome: outcome,
      );

  TraceSpan _toolSpan(_OpenTool tool, {DateTime? end, bool failed = false, bool cutShort = false}) {
    final call = tool.event;
    return TraceSpan(
      kind: call.name == 'ask_user_question' ? TraceKind.question : TraceKind.tool,
      step: call.step,
      seq: call.seq,
      start: tool.start,
      end: end,
      cutShort: cutShort,
      callId: call.callId,
      toolName: call.name,
      arguments: call.arguments,
      dispatched: call.time,
      failed: failed,
      outcome: tool.outcome,
    );
  }

  /// Closes everything still open at [time] (the turn ended, or a new turn
  /// started without a `turn/end`: the Host went away).
  TurnTrace finish(TurnEndedEvent? event, DateTime time) {
    final all = [
      ...spans,
      for (final asked in approvals.values) _approvalSpan(asked, time, cutShort: true),
      for (final tool in tools.values)
        if (!tool.waiting) _toolSpan(tool, end: time, cutShort: true),
      if (stepStarts.isNotEmpty)
        for (final MapEntry(key: step, value: start) in stepStarts.entries)
          TraceSpan(kind: TraceKind.model, step: step, seq: -1, start: start, end: time, cutShort: true),
    ];
    return TurnTrace(
      turn: turn,
      startSeq: startSeq,
      start: start,
      endSeq: event?.seq,
      end: time,
      endReason: event?.reason ?? const TurnEndReason('interrupted'),
      spans: _ordered(all),
    );
  }

  /// The turn still runs: open spans for what is in flight.
  TurnTrace running() {
    final open = <TraceSpan>[
      for (final asked in approvals.values) _approvalSpan(asked, null),
      for (final tool in tools.values)
        if (!tool.waiting) _toolSpan(tool),
    ];
    if (stepStarts.isNotEmpty) {
      for (final MapEntry(key: step, value: start) in stepStarts.entries) {
        open.add(_inFlight(step, start));
      }
    } else if (open.isEmpty) {
      // Nothing dispatched and no step marker: the model is being asked.
      open.add(_inFlight(lastStep + 1, boundary));
    }
    return TurnTrace(turn: turn, startSeq: startSeq, start: start, spans: _ordered([...spans, ...open]));
  }

  /// A model request still in flight (retries so far included).
  TraceSpan _inFlight(int step, DateTime start) {
    final failures = retries[step] ?? const <String>[];
    return TraceSpan(
      kind: TraceKind.model,
      step: step,
      seq: -1,
      start: start,
      firstToken: attemptFirstToken[step],
      retries: failures.length,
      retryFailures: List.unmodifiable(failures.where((f) => f.isNotEmpty)),
    );
  }

  static List<TraceSpan> _ordered(List<TraceSpan> spans) {
    final sorted = [...spans]
      ..sort((a, b) {
        final byStart = a.start.compareTo(b.start);
        if (byStart != 0) return byStart;
        // An open model request (seq -1) follows what closed at the same time.
        final aSeq = a.seq < 0 ? 1 << 62 : a.seq;
        final bSeq = b.seq < 0 ? 1 << 62 : b.seq;
        return aSeq.compareTo(bSeq);
      });
    return List.unmodifiable(sorted);
  }
}

/// First and last token times of a stored assistant stream (the compact
/// `AssistantStreamRecord[]` of `assistant/message` / `assistant/attempt`),
/// without expanding every chunk.
({DateTime? first, DateTime? last}) _streamBounds(Object? records) {
  int? first;
  int? last;
  void see(int time) {
    if (first == null || time < first!) first = time;
    if (last == null || time > last!) last = time;
  }

  for (final record in asListOrEmpty(records)) {
    final map = asMapOrEmpty(record);
    switch (asString(map['type'])) {
      case 'chunk':
        final type = asString(asMapOrEmpty(map['chunk'])['type']);
        if (type == 'text-delta' || type == 'reasoning-delta' || type == 'tool-call-delta') {
          final time = asInt(map['time']);
          if (time != null) see(time);
        }
      case 'text-chunks' || 'reasoning-chunks' || 'tool-call-chunks':
        final time0 = asInt(map['time0']);
        if (time0 == null) break;
        see(time0);
        var time = time0;
        for (final dt in asListOrEmpty(map['dt'])) {
          time += asInt(dt) ?? 0;
        }
        see(time);
    }
  }
  DateTime? at(int? ms) => ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  return (first: at(first), last: at(last));
}
