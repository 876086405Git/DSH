import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'api.dart' show TavernCharacter, TavernFailure, TavernRole, TavernUsage;
import 'regex/regex_engine.dart';
import 'regex_library.dart' show TavernDisplayResult, TavernRegexDiagnostic;
import 'state.dart';

typedef TavernJsonObject = Map<String, Object?>;

enum TavernVariableScope { global, character, chat, message, script }

enum TavernScriptOwnerKind { global, character, preset }

enum TavernScriptRole { user, assistant, system }

enum TavernHiddenFilter { all, hiddenOnly, visibleOnly }

enum TavernScriptRefresh { none, affected, all }

enum TavernVariableChangeKind { set, insertIfAbsent, remove }

enum TavernScriptDispatchKind { cache, lifecycle }

enum TavernScriptAckStatus { completed, failed, cancelled }

enum TavernScriptErrorCode {
  noContext,
  closedContext,
  notFound,
  ambiguousName,
  duplicateId,
  range,
  invalidArgument,
  invalidJson,
  reservedField,
  shapeMismatch,
  stateValidation,
  revisionConflict,
  busy,
  unsupportedCommand,
  unsupportedOption,
  unsupportedCapability,
  hostUnavailable,
  callbackUnavailable,
  cancelled,
  storage,
  model,
  hookFailure,
}

/// Persistent script identity. An iframe instance is deliberately not a key.
class TavernScriptOwner {
  const TavernScriptOwner({required this.kind, required this.scriptId, this.assetId});
  final TavernScriptOwnerKind kind;
  final String? assetId;
  final String scriptId;
  @override
  bool operator ==(Object other) =>
      other is TavernScriptOwner && kind == other.kind && assetId == other.assetId && scriptId == other.scriptId;
  @override
  int get hashCode => Object.hash(kind, assetId, scriptId);
}

class TavernScriptContextSpec {
  const TavernScriptContextSpec({required this.instanceId, this.chatId, this.characterId, this.nodeId, this.script});
  final String instanceId;
  final String? chatId;
  final String? characterId;
  final String? nodeId;
  final TavernScriptOwner? script;
}

class TavernScriptContext {
  const TavernScriptContext({
    required this.id,
    required this.engineEpoch,
    required this.instanceId,
    this.chatId,
    this.characterId,
    this.nodeId,
    this.script,
  });
  final String id;
  final String engineEpoch;
  final String instanceId;
  final String? chatId;
  final String? characterId;
  final String? nodeId;
  final TavernScriptOwner? script;
}

class TavernScriptMessageRef {
  const TavernScriptMessageRef({required this.chatId, required this.nodeId});
  final String chatId;
  final String nodeId;
  @override
  bool operator ==(Object other) => other is TavernScriptMessageRef && chatId == other.chatId && nodeId == other.nodeId;
  @override
  int get hashCode => Object.hash(chatId, nodeId);
}

class TavernMessageRange {
  const TavernMessageRange({this.first, this.last});
  final int? first;
  final int? last;
}

class TavernScriptWriteOptions {
  const TavernScriptWriteOptions({this.expectedPathRevision, this.refresh = TavernScriptRefresh.affected});
  final String? expectedPathRevision;
  final TavernScriptRefresh refresh;
}

class TavernScriptShapeIssue {
  const TavernScriptShapeIssue({required this.fieldPath, required this.actualKind, required this.message});
  final String fieldPath;
  final String actualKind;
  final String message;
}

class TavernScriptSwipe {
  TavernScriptSwipe({
    required this.ref,
    required this.swipeId,
    required this.text,
    this.hasData = false,
    Object? rawData,
    this.dataIssue,
    TavernJsonObject info = const {},
  }) : _rawData = _scriptCopy(rawData),
       _info = _scriptObject(info);
  final TavernScriptMessageRef ref;
  final int swipeId;
  final String text;
  final bool hasData;
  final Object? _rawData;
  final TavernScriptShapeIssue? dataIssue;
  final TavernJsonObject _info;
  Object? get rawData => _scriptCopy(_rawData);
  TavernJsonObject? get data => !hasData
      ? <String, Object?>{}
      : _rawData is TavernJsonObject
      ? _scriptObject(_rawData)
      : null;
  TavernJsonObject get info => _scriptObject(_info);
}

class TavernScriptMessage {
  TavernScriptMessage({
    required this.messageId,
    required this.ref,
    required this.name,
    required this.role,
    required this.message,
    required this.nativeRole,
    this.hidden = false,
    this.speakerCharacterId,
    this.hasData = false,
    Object? rawData,
    this.dataIssue,
    TavernJsonObject extra = const {},
    this.swipeId = 0,
    List<TavernScriptSwipe> swipes = const [],
  }) : _rawData = _scriptCopy(rawData),
       _extra = _scriptObject(extra),
       swipes = List.unmodifiable(swipes);
  final int messageId;
  final TavernScriptMessageRef ref;
  final String name;
  final TavernScriptRole role;
  final TavernRole nativeRole;
  final String message;
  final bool hidden;
  final String? speakerCharacterId;
  final bool hasData;
  final Object? _rawData;
  final TavernScriptShapeIssue? dataIssue;
  final TavernJsonObject _extra;
  final int swipeId;
  final List<TavernScriptSwipe> swipes;
  Object? get rawData => _scriptCopy(_rawData);
  TavernJsonObject? get data => !hasData
      ? <String, Object?>{}
      : _rawData is TavernJsonObject
      ? _scriptObject(_rawData)
      : null;
  TavernJsonObject get extra => _scriptObject(_extra);
}

class TavernScriptMessagePage {
  TavernScriptMessagePage({
    required this.pathRevision,
    required this.totalPathLength,
    required List<TavernScriptMessage> messages,
  }) : messages = List.unmodifiable(messages);
  final String pathRevision;
  final int totalPathLength;
  final List<TavernScriptMessage> messages;
}

class TavernScriptMessagePatch {
  TavernScriptMessagePatch({this.messageId, this.ref, required TavernJsonObject fields})
    : _fields = _scriptObject(fields);
  final int? messageId;
  final TavernScriptMessageRef? ref;
  final TavernJsonObject _fields;
  TavernJsonObject get fields => _scriptObject(_fields);
}

class TavernScriptMessageDraft {
  TavernScriptMessageDraft({
    required this.role,
    required this.message,
    this.name,
    this.speakerCharacterId,
    this.hidden = false,
    TavernJsonObject? data,
    TavernJsonObject extra = const {},
  }) : _data = data == null ? null : _scriptObject(data),
       _extra = _scriptObject(extra);
  final TavernScriptRole role;
  final String message;
  final String? name;
  final String? speakerCharacterId;
  final bool hidden;
  final TavernJsonObject? _data;
  final TavernJsonObject _extra;

  /// Null means omitted in the native DTO. A wire adapter rejects explicit null.
  TavernJsonObject? get data => _data == null ? null : _scriptObject(_data);
  TavernJsonObject get extra => _scriptObject(_extra);
}

class TavernScriptMutation {
  TavernScriptMutation({
    required this.oldRevision,
    required this.pathRevision,
    List<TavernScriptMessage> upsertMessages = const [],
    List<TavernScriptMessageRef> affectedRefs = const [],
    List<TavernScriptMessageRef> removedRefs = const [],
    Map<int, TavernScriptMessageRef?> indexChanges = const {},
    this.refresh = TavernScriptRefresh.affected,
    Map<String, TavernStateEditResult> stateEdits = const {},
  }) : upsertMessages = List.unmodifiable(upsertMessages),
       affectedRefs = List.unmodifiable(affectedRefs),
       removedRefs = List.unmodifiable(removedRefs),
       indexChanges = Map.unmodifiable(indexChanges),
       stateEdits = Map.unmodifiable(stateEdits);
  final String oldRevision;
  final String pathRevision;
  final List<TavernScriptMessage> upsertMessages;
  final List<TavernScriptMessageRef> affectedRefs;
  final List<TavernScriptMessageRef> removedRefs;
  final Map<int, TavernScriptMessageRef?> indexChanges;
  final TavernScriptRefresh refresh;
  final Map<String, TavernStateEditResult> stateEdits;
}

class TavernVariableTarget {
  const TavernVariableTarget({
    required this.scope,
    this.characterId,
    this.chatId,
    this.messageRef,
    this.messageId,
    this.scriptOwner,
  });
  final TavernVariableScope scope;
  final String? characterId;
  final String? chatId;
  final TavernScriptMessageRef? messageRef;
  final int? messageId;
  final TavernScriptOwner? scriptOwner;
}

class TavernVariableSnapshot {
  TavernVariableSnapshot({
    required this.resolvedTarget,
    required this.version,
    required TavernJsonObject value,
    this.stateEdit,
  }) : _value = _scriptObject(value);
  final TavernVariableTarget resolvedTarget;
  final String version;
  final TavernJsonObject _value;
  final TavernStateEditResult? stateEdit;
  TavernJsonObject get value => _scriptObject(_value);
}

const Object _scriptAbsent = Object();

class TavernVariableChange {
  TavernVariableChange({required this.kind, required List<Object> pathTokens, Object? value = _scriptAbsent})
    : pathTokens = List.unmodifiable(pathTokens),
      hasValue = !identical(value, _scriptAbsent),
      _value = identical(value, _scriptAbsent) ? null : _scriptCopy(value);
  final TavernVariableChangeKind kind;
  final List<Object> pathTokens;
  final bool hasValue;
  final Object? _value;
  Object? get value => _scriptCopy(_value);
}

class TavernVariableChangeResult {
  TavernVariableChangeResult({
    required this.kind,
    required List<Object> pathTokens,
    required this.existed,
    required this.changed,
  }) : pathTokens = List.unmodifiable(pathTokens);
  final TavernVariableChangeKind kind;
  final List<Object> pathTokens;
  final bool existed;
  final bool changed;
}

class TavernVariableMutation {
  TavernVariableMutation({required this.snapshot, required List<TavernVariableChangeResult> results})
    : results = List.unmodifiable(results);
  final TavernVariableSnapshot snapshot;
  final List<TavernVariableChangeResult> results;
}

class TavernScriptCapabilities {
  TavernScriptCapabilities({
    required this.adapterVersion,
    required Set<String> methods,
    required Set<TavernVariableScope> scopes,
    Set<String> slashCommands = const {},
    Set<String> generationOptions = const {},
    Set<String> hostCapabilities = const {},
    required this.hostAttached,
    this.simulated = false,
  }) : methods = Set.unmodifiable(methods),
       scopes = Set.unmodifiable(scopes),
       slashCommands = Set.unmodifiable(slashCommands),
       generationOptions = Set.unmodifiable(generationOptions),
       hostCapabilities = Set.unmodifiable(hostCapabilities);
  final String adapterVersion;
  final Set<String> methods;
  final Set<TavernVariableScope> scopes;
  final Set<String> slashCommands;
  final Set<String> generationOptions;
  final Set<String> hostCapabilities;
  final bool hostAttached;
  final bool simulated;
}

class TavernScriptSnapshot {
  TavernScriptSnapshot({
    required this.context,
    required this.engineEpoch,
    required this.lastSeq,
    required this.pathRevision,
    required List<TavernScriptMessage> messages,
    List<TavernVariableSnapshot> variableSnapshots = const [],
    this.presetId,
    this.personaId,
    List<String> memberCharacterIds = const [],
    TavernJsonObject resourceRefs = const {},
    required this.capabilities,
  }) : messages = List.unmodifiable(messages),
       variableSnapshots = List.unmodifiable(variableSnapshots),
       memberCharacterIds = List.unmodifiable(memberCharacterIds),
       _resourceRefs = _scriptObject(resourceRefs);
  final TavernScriptContext context;
  final String engineEpoch;
  final int lastSeq;
  final String pathRevision;
  final List<TavernScriptMessage> messages;
  final List<TavernVariableSnapshot> variableSnapshots;
  final String? presetId;
  final String? personaId;
  final List<String> memberCharacterIds;
  final TavernJsonObject _resourceRefs;
  final TavernScriptCapabilities capabilities;
  TavernJsonObject get resourceRefs => _scriptObject(_resourceRefs);
}

class TavernScriptDelta {
  TavernScriptDelta({
    required this.baseRevision,
    required this.newRevision,
    List<TavernScriptMessage> upsertMessages = const [],
    List<TavernScriptMessageRef> removedRefs = const [],
    Map<int, TavernScriptMessageRef?> indexChanges = const {},
    List<TavernVariableSnapshot> variableSnapshots = const [],
    TavernJsonObject resourceRefs = const {},
  }) : upsertMessages = List.unmodifiable(upsertMessages),
       removedRefs = List.unmodifiable(removedRefs),
       indexChanges = Map.unmodifiable(indexChanges),
       variableSnapshots = List.unmodifiable(variableSnapshots),
       _resourceRefs = _scriptObject(resourceRefs);
  final String baseRevision;
  final String newRevision;
  final List<TavernScriptMessage> upsertMessages;
  final List<TavernScriptMessageRef> removedRefs;
  final Map<int, TavernScriptMessageRef?> indexChanges;
  final List<TavernVariableSnapshot> variableSnapshots;
  final TavernJsonObject _resourceRefs;
  TavernJsonObject get resourceRefs => _scriptObject(_resourceRefs);
}

class TavernScriptSourceSpan {
  const TavernScriptSourceSpan({
    this.sourceId,
    required this.start,
    required this.end,
    required this.line,
    required this.column,
  });
  final String? sourceId;
  final int start;
  final int end;
  final int line;
  final int column;
}

class TavernScriptIssue {
  TavernScriptIssue({
    required this.code,
    required this.message,
    required this.committed,
    TavernJsonObject details = const {},
    this.contextId,
    this.eventId,
    this.generationId,
    this.nodeRef,
    this.sourceSpan,
    this.stage,
    this.cancelled = false,
  }) : _details = _scriptObject(details);
  final String code;
  final String message;
  final bool committed;
  final TavernJsonObject _details;
  final String? contextId;
  final String? eventId;
  final String? generationId;
  final TavernScriptMessageRef? nodeRef;
  final TavernScriptSourceSpan? sourceSpan;
  final String? stage;
  final bool cancelled;
  TavernJsonObject get details => _scriptObject(_details);
}

class TavernScriptException implements Exception {
  TavernScriptException({
    required this.code,
    required this.operation,
    required this.message,
    this.contextId,
    this.nodeId,
    this.generationId,
    this.executionId,
    this.fieldPath,
    this.sourceSpan,
    this.committed = false,
    this.modelFailure,
    List<TavernScriptIssue> issues = const [],
    this.stateEdit,
  }) : issues = List.unmodifiable(issues);
  final TavernScriptErrorCode code;
  final String operation;
  final String message;
  final String? contextId;
  final String? nodeId;
  final String? generationId;
  final String? executionId;
  final String? fieldPath;
  final TavernScriptSourceSpan? sourceSpan;
  final bool committed;
  final TavernFailure? modelFailure;
  final List<TavernScriptIssue> issues;
  final TavernStateEditResult? stateEdit;
  @override
  String toString() => 'TavernScriptException(${code.name}, $operation): $message';
}

class TavernScriptDispatch {
  TavernScriptDispatch({
    required this.kind,
    required this.eventId,
    required this.contextId,
    required this.seq,
    this.chatId,
    this.namespace,
    this.name,
    this.generationId,
    this.nodeRef,
    this.messageId,
    this.swipeId,
    this.pathRevision,
    List<Object?> args = const [],
    this.delta,
  }) : _args = _scriptCopy(args)! as List<Object?>;
  final TavernScriptDispatchKind kind;
  final String eventId;
  final String contextId;
  final String? chatId;
  final String? namespace;
  final String? name;
  final int seq;
  final String? generationId;
  final TavernScriptMessageRef? nodeRef;
  final int? messageId;
  final int? swipeId;
  final String? pathRevision;
  final List<Object?> _args;
  final TavernScriptDelta? delta;
  List<Object?> get args => _scriptCopy(_args)! as List<Object?>;
}

/// Mutable MVU event feedback is captured as finite JSON before transport.
class TavernScriptMvuFeedback {
  TavernScriptMvuFeedback({
    required TavernJsonObject data,
    List<TavernJsonObject>? commands,
    TavernJsonObject? beforeData,
  }) : _data = _scriptObject(data),
       _commands = commands?.map(_scriptObject).toList(growable: false),
       _beforeData = beforeData == null ? null : _scriptObject(beforeData);
  final TavernJsonObject _data;
  final List<TavernJsonObject>? _commands;
  final TavernJsonObject? _beforeData;
  TavernJsonObject get data => _scriptObject(_data);
  List<TavernJsonObject>? get commands => _commands?.map(_scriptObject).toList();
  TavernJsonObject? get beforeData => _beforeData == null ? null : _scriptObject(_beforeData);
}

class TavernScriptDispatchAck {
  TavernScriptDispatchAck({
    required this.eventId,
    this.status = TavernScriptAckStatus.completed,
    List<TavernScriptIssue> issues = const [],
    Map<String, String> revisions = const {},
    this.mvu,
  }) : issues = List.unmodifiable(issues),
       revisions = Map.unmodifiable(revisions);
  final String eventId;
  final TavernScriptAckStatus status;
  final List<TavernScriptIssue> issues;
  final Map<String, String> revisions;
  final TavernScriptMvuFeedback? mvu;
}

class TavernScriptEvent {
  TavernScriptEvent({
    required this.dispatch,
    required this.phase,
    required this.committed,
    List<TavernScriptIssue> issues = const [],
  }) : issues = List.unmodifiable(issues);
  final TavernScriptDispatch dispatch;
  final String phase;
  final bool committed;
  final List<TavernScriptIssue> issues;
  String get contextId => dispatch.contextId;
  String? get chatId => dispatch.chatId;
  String? get name => dispatch.name;
  int get seq => dispatch.seq;
}

abstract interface class TavernScriptCancellation {
  bool get isCancelled;
  Future<void> get whenCancelled;
}

class TavernScriptRefreshRequest {
  TavernScriptRefreshRequest({
    required this.requestId,
    required this.contextId,
    required this.mode,
    required this.pathRevision,
    required List<TavernScriptMessageRef> refs,
    required this.reason,
  }) : refs = List.unmodifiable(refs);
  final String requestId;
  final String contextId;
  final TavernScriptRefresh mode;
  final String pathRevision;
  final List<TavernScriptMessageRef> refs;
  final String reason;
}

/// JSON-only host messages. UI and callback execution are supplied by the App.
class TavernScriptUiRequest {
  TavernScriptUiRequest({
    required this.requestId,
    required this.contextId,
    required this.executionId,
    required this.kind,
    TavernJsonObject fields = const {},
  }) : _fields = _scriptObject(fields);
  final String requestId;
  final String contextId;
  final String executionId;
  final String kind;
  final TavernJsonObject _fields;
  TavernJsonObject get fields => _scriptObject(_fields);
}

class TavernScriptUiResult {
  const TavernScriptUiResult({required this.requestId, required this.status, this.text, this.buttonIndex, this.label});
  final String requestId;
  final String status;
  final String? text;
  final int? buttonIndex;
  final String? label;
}

class TavernScriptCallbackRef {
  const TavernScriptCallbackRef({required this.contextId, required this.instanceId, required this.callbackId});
  final String contextId;
  final String instanceId;
  final String callbackId;
}

class TavernScriptCallbackRequest {
  TavernScriptCallbackRequest({
    required this.requestId,
    required this.ref,
    required this.kind,
    List<Object?> args = const [],
  }) : _args = _scriptCopy(args)! as List<Object?>;
  final String requestId;
  final TavernScriptCallbackRef ref;
  final String kind;
  final List<Object?> _args;
  List<Object?> get args => _scriptCopy(_args)! as List<Object?>;
}

class TavernScriptCallbackResult {
  TavernScriptCallbackResult({
    required this.requestId,
    required this.status,
    this.value,
    List<TavernScriptIssue> issues = const [],
  }) : issues = List.unmodifiable(issues);
  final String requestId;
  final String status;
  final bool? value;
  final List<TavernScriptIssue> issues;
}

class TavernSlashReference {
  const TavernSlashReference({required this.contextId, required this.label, this.setName, this.sourceSpan});
  final String contextId;
  final String label;
  final String? setName;
  final TavernScriptSourceSpan? sourceSpan;
}

class TavernResolvedSlash {
  const TavernResolvedSlash({required this.assetId, required this.version, required this.source});
  final String assetId;
  final String version;
  final String source;
}

abstract interface class TavernScriptHost {
  Future<TavernScriptDispatchAck> dispatch(TavernScriptDispatch request, TavernScriptCancellation cancellation);
  Future<TavernScriptUiResult> interact(TavernScriptUiRequest request, TavernScriptCancellation cancellation);
  Future<TavernScriptCallbackResult> invoke(TavernScriptCallbackRequest request, TavernScriptCancellation cancellation);
  Future<TavernResolvedSlash?> resolveSlash(TavernSlashReference request, TavernScriptCancellation cancellation);
  Future<void> refresh(TavernScriptRefreshRequest request);
}

/// Optional real App generation-control lease. The original host contract is
/// unchanged; a host advertises this capability by implementing this interface.
abstract interface class TavernScriptGenerationLockHost {
  Future<TavernScriptGenerationLockAck> acquireGenerationLock(
    TavernScriptGenerationLockAcquireRequest request,
    TavernScriptCancellation cancellation,
  );
  Future<TavernScriptGenerationLockAck> releaseGenerationLock(
    TavernScriptGenerationLockReleaseRequest request,
    TavernScriptCancellation cancellation,
  );
}

enum TavernScriptGenerationLockStatus { acquired, released, cancelled, failed }

class TavernScriptGenerationLockAcquireRequest {
  const TavernScriptGenerationLockAcquireRequest({
    required this.requestId,
    required this.contextId,
    required this.executionId,
    required this.leaseId,
  });
  final String requestId, contextId, executionId, leaseId;
}

class TavernScriptGenerationLockReleaseRequest {
  const TavernScriptGenerationLockReleaseRequest({
    required this.requestId,
    required this.contextId,
    required this.executionId,
    required this.leaseId,
    required this.acquireRequestId,
  });
  final String requestId, contextId, executionId, leaseId, acquireRequestId;
}

class TavernScriptGenerationLockAck {
  TavernScriptGenerationLockAck({
    required this.requestId,
    required this.leaseId,
    required this.status,
    List<TavernScriptIssue> issues = const [],
  }) : issues = List.unmodifiable(issues);
  final String requestId, leaseId;
  final TavernScriptGenerationLockStatus status;
  final List<TavernScriptIssue> issues;
}

class TavernMvuInitialization {
  TavernMvuInitialization({
    required this.chatId,
    required this.enabled,
    List<TavernScriptMessageRef> initializedRefs = const [],
    List<TavernScriptIssue> issues = const [],
  }) : initializedRefs = List.unmodifiable(initializedRefs),
       issues = List.unmodifiable(issues);
  final String chatId;
  final bool enabled;
  final List<TavernScriptMessageRef> initializedRefs;
  final List<TavernScriptIssue> issues;
}

class TavernMvuParseResult {
  TavernMvuParseResult({required TavernJsonObject data, List<TavernScriptIssue> issues = const []})
    : _data = _scriptObject(data),
      issues = List.unmodifiable(issues);
  final TavernJsonObject _data;
  final List<TavernScriptIssue> issues;
  TavernJsonObject get data => _scriptObject(_data);
}

/// Persisted data, awaited native lifecycle and independent B2 background
/// generation. App callback execution and STscript remain separate capabilities.
abstract interface class TavernScriptBridge {
  TavernScriptCapabilities get capabilities;
  void attachHost(TavernScriptHost? host);
  Future<TavernScriptContext> openContext(TavernScriptContextSpec spec);
  Future<TavernScriptSnapshot> snapshot(String contextId);
  Future<void> closeContext(String contextId);
  Future<void> activateChat(String contextId);
  Stream<TavernScriptEvent> watchEvents({String? chatId});
  Future<TavernScriptMessagePage> getChatMessages(
    String contextId,
    TavernMessageRange range, {
    TavernScriptRole? role,
    TavernHiddenFilter hidden = TavernHiddenFilter.all,
    bool includeSwipes = false,
  });
  Future<TavernScriptMutation> setChatMessages(
    String contextId,
    List<TavernScriptMessagePatch> patches, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  });
  Future<TavernScriptMutation> createChatMessages(
    String contextId,
    List<TavernScriptMessageDraft> messages, {
    int? insertBefore,
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  });
  Future<TavernScriptMutation> deleteChatMessages(
    String contextId,
    List<int> messageIds, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  });
  Future<TavernScriptMutation> rotateChatMessages(
    String contextId,
    int begin,
    int middle,
    int end, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  });
  Future<TavernScriptMutation> selectSwipe(
    String contextId,
    TavernScriptMessageRef message,
    int swipeId, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  });
  Future<TavernVariableSnapshot> getVariables(String contextId, TavernVariableTarget target);
  Future<TavernVariableSnapshot> replaceVariables(
    String contextId,
    TavernVariableTarget target,
    TavernJsonObject value, {
    String? expectedVersion,
  });
  Future<TavernVariableSnapshot> updateVariablesWith(
    String contextId,
    TavernVariableTarget target,
    FutureOr<TavernJsonObject> Function(TavernJsonObject value) updater,
  );
  Future<TavernVariableMutation> mutateVariables(
    String contextId,
    TavernVariableTarget target,
    List<TavernVariableChange> changes, {
    String? expectedVersion,
  });
  Future<TavernScriptGeneration> generate(String contextId, TavernScriptGenerateRequest request);
  Future<TavernScriptGeneration> generateRaw(String contextId, TavernScriptRawRequest request);
  bool stopGenerationById(String generationId);
  Future<List<TavernScriptRegex>> getTavernRegexes(String contextId, TavernScriptRegexQuery query);
  Future<TavernDisplayResult> formatAsTavernRegexedString(
    String contextId,
    String text, {
    required int source,
    required RegexPhase destination,
    num? depth,
    String? characterId,
  });
  Future<TavernScriptInjectionLease> injectPrompts(
    String contextId,
    List<TavernScriptInjection> prompts, {
    bool once = false,
  });
  Future<void> uninjectPrompts(String contextId, List<String> ids);
  Future<void> releaseInjectionLease(String leaseId);
  Future<List<TavernScriptInjectionView>> listInjections(String contextId);
  Future<TavernSlashExecution> triggerSlash(
    String contextId,
    String source, {
    String? executionId,
    String pipe = '',
    Map<String, String> arguments = const {},
  });
  bool stopScript(String executionId);
  Future<String> substituteMacros(String contextId, String text);
  Future<TavernMvuInitialization> setMvuEnabled(String contextId, bool enabled);
  Future<TavernMvuParseResult> parseMvuMessage(String contextId, String message, TavernJsonObject previousData);
  Future<TavernCharacter> replaceCharacterData(
    String contextId,
    String characterId,
    TavernJsonObject data, {
    String? expectedVersion,
  });
  Future<TavernScriptCharacterAvatarSnapshot> readCharacterAvatar(String contextId, String characterId);
  Future<TavernScriptCharacterAvatarSnapshot> replaceCharacterAvatar(
    String contextId,
    String characterId,
    Uint8List bytes, {
    required String expectedVersion,
  });
  Future<List<TavernScriptBookBinding>> getContextBooks(String contextId);
  Future<TavernScriptBookSnapshot> readBook(String contextId, TavernScriptBookRef ref);
  Future<TavernScriptBookSnapshot> replaceBook(
    String contextId,
    TavernScriptBookRef ref,
    TavernJsonObject book, {
    String? expectedVersion,
  });
  Future<TavernScriptWorldInfoSettingsSnapshot> updateWorldInfoSettings(
    String contextId,
    TavernJsonObject patch, {
    String? expectedVersion,
  });
  Future<TavernScriptButtonsSnapshot> replaceScriptButtons(
    String contextId,
    List<TavernScriptButton> buttons, {
    String? expectedVersion,
  });
  Future<TavernScriptBookDirectorySnapshot> getBookDirectory(String contextId);
  Future<TavernScriptBookRef> resolveBook(String contextId, String nameOrHandle);
  Future<TavernScriptBookSnapshot> createBook(String contextId, String name, TavernJsonObject raw);
  Future<void> deleteBook(String contextId, TavernScriptBookRef ref, {required String expectedVersion});
  Future<TavernScriptBookBindingsSnapshot> readBookBindings(String contextId, TavernScriptBookBindingsTarget target);
  Future<TavernScriptBookBindingsSnapshot> updateBookBindings(
    String contextId,
    TavernScriptBookBindingsEdit edit, {
    required String expectedVersion,
  });
  Future<TavernScriptPresetSnapshot> readPreset(String contextId, TavernScriptPresetRef ref);
  Future<TavernScriptPresetSnapshot> replacePreset(
    String contextId,
    TavernScriptPresetRef ref,
    TavernJsonObject raw, {
    required String expectedVersion,
  });
  Future<TavernScriptRegexWriteSnapshot> readTavernRegexesForWrite(
    String contextId,
    TavernScriptRegexWriteTarget target,
  );
  Future<TavernScriptRegexWriteSnapshot> replaceTavernRegexes(
    String contextId,
    TavernScriptRegexWriteTarget target,
    List<TavernScriptRegexWriteItem> items, {
    required String expectedVersion,
  });
}

enum TavernSlashExecutionEventKind { snapshot, started, command, waiting, finished, failed }

enum TavernSlashStatus { parsing, running, waiting, completed, aborted, failed, cancelled }

enum TavernSlashCompletion { completed, aborted }

enum TavernSlashWaitKind {
  storage,
  generation,
  nativeTurn,
  ui,
  resolveSlash,
  generationLockAcquire,
  generationLockRelease,
}

enum TavernSlashEffectKind { storage, injection, backgroundGeneration, nativeTurn, ui, generationLock }

enum TavernSlashEffectStage { defaults, named, unnamed, provided, handler, preparation, model, outputCleanup, release }

enum TavernSlashEffectState {
  requested,
  started,
  accepted,
  adopted,
  completed,
  failed,
  cancelled,
  skipped,
  acquireRequested,
  acquired,
  releaseRequested,
  released,
  unconfirmed,
}

/// A hot execution. Observing or cancelling a subscription never starts or stops
/// the script. Each subscription receives its own current immutable snapshot.
abstract interface class TavernSlashExecution {
  String get id;
  Stream<TavernSlashExecutionEvent> get events;
  Future<TavernSlashResult> get result;
}

class TavernSlashEffects {
  TavernSlashEffects({required this.committed, List<TavernSlashEffect> entries = const []})
    : entries = List.unmodifiable(entries);
  final bool committed;
  final List<TavernSlashEffect> entries;
  TavernJsonObject toJson() => {
    'committed': committed,
    'entries': [for (final entry in entries) entry.toJson()],
  };
}

class TavernSlashEffect {
  TavernSlashEffect({
    required this.index,
    required this.kind,
    required this.stage,
    required this.state,
    required this.operation,
    required TavernJsonObject target,
    required this.committed,
    this.commandIndex,
    this.command,
    this.sourceSpan,
    this.version,
    TavernJsonObject details = const {},
  }) : _target = _scriptObject(target),
       _details = _scriptObject(details);
  final int index;
  final TavernSlashEffectKind kind;
  final TavernSlashEffectStage stage;
  final TavernSlashEffectState state;
  final String operation;
  final TavernJsonObject _target, _details;
  final bool committed;
  final int? commandIndex;
  final String? command, version;
  final TavernScriptSourceSpan? sourceSpan;
  TavernJsonObject get target => _scriptObject(_target);
  TavernJsonObject get details => _scriptObject(_details);
  TavernJsonObject toJson() => {
    'index': index,
    'kind': kind.name,
    'stage': stage.name,
    'state': state.name,
    'operation': operation,
    'target': target,
    'committed': committed,
    if (commandIndex != null) 'commandIndex': commandIndex,
    if (command != null) 'command': command,
    if (sourceSpan case final span?)
      'sourceSpan': {
        'sourceId': ?span.sourceId,
        'start': span.start,
        'end': span.end,
        'line': span.line,
        'column': span.column,
      },
    if (version != null) 'version': version,
    'details': details,
  };
}

class TavernSlashExecutionEvent {
  TavernSlashExecutionEvent({
    required this.id,
    required this.context,
    required this.seq,
    required this.kind,
    required this.status,
    required this.effects,
    this.pipe,
    this.commandIndex,
    this.command,
    this.sourceSpan,
    this.waitKind,
    this.completion,
    this.error,
    this.partialGeneration,
    this.lastSeq,
    List<TavernScriptIssue> issues = const [],
    this.simulated = false,
  }) : issues = List.unmodifiable(issues);
  final String id;
  final TavernScriptContext context;
  final int seq;
  final TavernSlashExecutionEventKind kind;
  final TavernSlashStatus status;
  final TavernSlashEffects effects;
  final String? pipe;
  final int? commandIndex;
  final String? command;
  final TavernScriptSourceSpan? sourceSpan;
  final TavernSlashWaitKind? waitKind;
  final TavernSlashCompletion? completion;
  final TavernScriptException? error;
  final TavernScriptGenerationResult? partialGeneration;
  final int? lastSeq;
  final List<TavernScriptIssue> issues;
  final bool simulated;
  bool get isSnapshot => kind == TavernSlashExecutionEventKind.snapshot;
}

class TavernSlashResult {
  TavernSlashResult({
    required this.id,
    required this.context,
    required this.pipe,
    required this.completion,
    required this.effects,
    List<TavernScriptIssue> issues = const [],
    this.simulated = false,
  }) : issues = List.unmodifiable(issues);
  final String id;
  final TavernScriptContext context;
  final String pipe;
  final TavernSlashCompletion completion;
  final TavernSlashEffects effects;
  final List<TavernScriptIssue> issues;
  final bool simulated;
}

sealed class TavernScriptBookRef {
  const TavernScriptBookRef();
  factory TavernScriptBookRef.standalone({required String bookId}) = TavernScriptStandaloneBookRef;
  factory TavernScriptBookRef.embedded({required String characterId}) = TavernScriptEmbeddedBookRef;
  TavernJsonObject toJson();
  factory TavernScriptBookRef.fromJson(TavernJsonObject json) {
    final value = _scriptDtoObject(json, const {'kind', 'bookId', 'characterId'});
    if (value['kind'] == 'standalone') {
      _scriptDtoKeys(value, const {'kind', 'bookId'});
      return TavernScriptBookRef.standalone(bookId: _scriptRequiredString(value, 'bookId'));
    }
    if (value['kind'] == 'embedded') {
      _scriptDtoKeys(value, const {'kind', 'characterId'});
      return TavernScriptBookRef.embedded(characterId: _scriptRequiredString(value, 'characterId'));
    }
    throw _scriptDtoError('kind', 'Expected standalone or embedded.');
  }
}

final class TavernScriptStandaloneBookRef extends TavernScriptBookRef {
  TavernScriptStandaloneBookRef({required this.bookId}) {
    if (bookId.isEmpty) throw _scriptDtoError('bookId', 'Identity must be nonempty.');
  }
  final String bookId;
  @override
  TavernJsonObject toJson() => {'kind': 'standalone', 'bookId': bookId};
  @override
  bool operator ==(Object other) => other is TavernScriptStandaloneBookRef && bookId == other.bookId;
  @override
  int get hashCode => Object.hash('standalone', bookId);
}

final class TavernScriptEmbeddedBookRef extends TavernScriptBookRef {
  TavernScriptEmbeddedBookRef({required this.characterId}) {
    if (characterId.isEmpty) throw _scriptDtoError('characterId', 'Identity must be nonempty.');
  }
  final String characterId;
  @override
  TavernJsonObject toJson() => {'kind': 'embedded', 'characterId': characterId};
  @override
  bool operator ==(Object other) => other is TavernScriptEmbeddedBookRef && characterId == other.characterId;
  @override
  int get hashCode => Object.hash('embedded', characterId);
}

enum TavernScriptBookSource { global, persona, chat, character, groupMember }

class TavernScriptBookBinding {
  const TavernScriptBookBinding({
    required this.ref,
    required this.source,
    this.chatId,
    this.personaId,
    this.characterId,
  });
  final TavernScriptBookRef ref;
  final TavernScriptBookSource source;
  final String? chatId, personaId, characterId;
}

class TavernScriptBookSnapshot {
  TavernScriptBookSnapshot({required this.ref, required this.version, required TavernJsonObject book})
    : _book = _scriptObject(book);
  final TavernScriptBookRef ref;
  final String version;
  final TavernJsonObject _book;
  TavernJsonObject get book => _scriptObject(_book);
}

/// Global Helper settings projection. Book handles are read-only here.
/// overflow_alert is a compatibility preference with no native scan effect.
class TavernScriptWorldInfoSettingsSnapshot {
  TavernScriptWorldInfoSettingsSnapshot({required this.version, required TavernJsonObject value})
    : _value = _scriptObject(value);
  final String version;
  final TavernJsonObject _value;
  TavernJsonObject get value => _scriptObject(_value);
  TavernJsonObject toJson() => {'version': version, 'value': value};
}

class TavernScriptButton {
  const TavernScriptButton({required this.name, required this.visible});
  final String name;
  final bool visible;
  TavernJsonObject toJson() => {'name': name, 'visible': visible};
}

/// The persistent owner comes from the opened context, not a caller selector.
class TavernScriptButtonsSnapshot {
  TavernScriptButtonsSnapshot({required this.owner, required this.version, required List<TavernScriptButton> buttons})
    : buttons = List.unmodifiable(buttons);
  final TavernScriptOwner owner;
  final String version;
  final List<TavernScriptButton> buttons;
  TavernJsonObject toJson() => {
    'owner': {'kind': owner.kind.name, 'scriptId': owner.scriptId, 'assetId': ?owner.assetId},
    'version': version,
    'buttons': [for (final button in buttons) button.toJson()],
  };
}

/// Raw identity metadata; displayName is a label, never an implicit identity.
class TavernScriptBookDirectoryEntry {
  const TavernScriptBookDirectoryEntry({required this.ref, this.name, this.stWorldName, required this.readable});
  final TavernScriptBookRef ref;
  final String? name, stWorldName;
  final bool readable;
  String get handle => switch (ref) {
    TavernScriptStandaloneBookRef(:final bookId) => 'standalone:$bookId',
    TavernScriptEmbeddedBookRef(:final characterId) => 'embedded:$characterId',
  };
  String get displayName => name != null && name!.isNotEmpty
      ? name!
      : switch (ref) {
          TavernScriptStandaloneBookRef(:final bookId) => bookId,
          TavernScriptEmbeddedBookRef(:final characterId) => characterId,
        };
  TavernJsonObject toJson() => {
    'ref': ref.toJson(),
    'handle': handle,
    'name': ?name,
    'displayName': displayName,
    'stWorldName': ?stWorldName,
    'readable': readable,
  };
}

class TavernScriptBookDirectorySnapshot {
  TavernScriptBookDirectorySnapshot({
    required this.version,
    required List<TavernScriptBookDirectoryEntry> books,
    List<TavernScriptIssue> issues = const [],
  }) : books = List.unmodifiable(books),
       issues = List.unmodifiable(issues);
  final String version;
  final List<TavernScriptBookDirectoryEntry> books;
  final List<TavernScriptIssue> issues;
}

enum TavernScriptBookBindingScope { global, character, chat, persona }

class TavernScriptBookBindingsTarget {
  const TavernScriptBookBindingsTarget({required this.scope, this.targetId});
  final TavernScriptBookBindingScope scope;
  final String? targetId;
}

class TavernScriptBookBindingsEdit {
  TavernScriptBookBindingsEdit({
    required this.scope,
    this.targetId,
    required this.primary,
    List<TavernScriptBookRef> additional = const [],
  }) : additional = List.unmodifiable(additional);
  final TavernScriptBookBindingScope scope;
  final String? targetId;
  final TavernScriptBookRef? primary;
  final List<TavernScriptBookRef> additional;
}

class TavernScriptBookBindingsSnapshot {
  TavernScriptBookBindingsSnapshot({
    required this.scope,
    this.targetId,
    required this.version,
    required this.primary,
    List<TavernScriptBookRef> additional = const [],
    List<TavernScriptBookRef> inherited = const [],
  }) : additional = List.unmodifiable(additional),
       inherited = List.unmodifiable(inherited);
  final TavernScriptBookBindingScope scope;
  final String? targetId;
  final String version;
  final TavernScriptBookRef? primary;
  final List<TavernScriptBookRef> additional, inherited;
}

/// A detached binary read. The version covers the authoritative carrier and
/// the selected avatar bytes; cache metadata versions are not write tokens.
class TavernScriptCharacterAvatarSnapshot {
  TavernScriptCharacterAvatarSnapshot({required this.characterId, required this.version, required Uint8List? bytes})
    : _bytes = bytes == null ? null : Uint8List.fromList(bytes);

  final String characterId;
  final String version;
  final Uint8List? _bytes;
  Uint8List? get bytes => _bytes == null ? null : Uint8List.fromList(_bytes);

  TavernJsonObject toJson() => {'characterId': characterId, 'version': version, 'bytes': bytes};
}

/// Stored identity and the context's unsaved current ST preset are distinct.
enum TavernScriptPresetRefKind { stored, current }

class TavernScriptPresetRef {
  const TavernScriptPresetRef.stored(String this.presetId) : kind = TavernScriptPresetRefKind.stored;
  const TavernScriptPresetRef.current() : kind = TavernScriptPresetRefKind.current, presetId = null;
  final TavernScriptPresetRefKind kind;
  final String? presetId;
  TavernJsonObject toJson() => {'kind': kind.name, 'presetId': ?presetId};
}

/// Complete ST raw input. Helper's public preset shape is an App projection.
class TavernScriptPresetSnapshot {
  TavernScriptPresetSnapshot({
    required this.ref,
    required this.version,
    required TavernJsonObject source,
    required TavernJsonObject raw,
  }) : _source = _scriptObject(source),
       _raw = _scriptObject(raw);
  final TavernScriptPresetRef ref;
  final String version;
  final TavernJsonObject _source, _raw;
  TavernJsonObject get source => _scriptObject(_source);
  TavernJsonObject get raw => _scriptObject(_raw);
  TavernJsonObject toJson() => {'ref': ref.toJson(), 'version': version, 'source': source, 'raw': raw};
}

enum TavernScriptPromptRole { system, user, assistant }

enum TavernScriptPromptPlaceholder {
  worldInfoBefore,
  personaDescription,
  charDescription,
  charPersonality,
  scenario,
  worldInfoAfter,
  dialogueExamples,
  chatHistory,
  userInput,
}

sealed class TavernScriptPromptPart {
  const TavernScriptPromptPart();
  const factory TavernScriptPromptPart.literal({required TavernScriptPromptRole role, required String content}) =
      TavernScriptPromptLiteral;
  const factory TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder kind) =
      TavernScriptPromptPlaceholderPart;
  factory TavernScriptPromptPart.fromJson(TavernJsonObject json) {
    final value = _scriptDtoObject(json, const {'kind', 'role', 'content', 'placeholder'});
    if (value['kind'] == 'literal') {
      _scriptDtoKeys(value, const {'kind', 'role', 'content'});
      return TavernScriptPromptPart.literal(
        role: _scriptEnum(TavernScriptPromptRole.values, value['role'], 'role'),
        content: _scriptRequiredString(value, 'content'),
      );
    }
    if (value['kind'] == 'placeholder') {
      _scriptDtoKeys(value, const {'kind', 'placeholder'});
      return TavernScriptPromptPart.placeholder(
        _scriptEnum(TavernScriptPromptPlaceholder.values, value['placeholder'], 'placeholder'),
      );
    }
    throw _scriptDtoError('kind', 'Expected literal or placeholder.');
  }
}

final class TavernScriptPromptLiteral extends TavernScriptPromptPart {
  const TavernScriptPromptLiteral({required this.role, required this.content});
  final TavernScriptPromptRole role;
  final String content;
}

final class TavernScriptPromptPlaceholderPart extends TavernScriptPromptPart {
  const TavernScriptPromptPlaceholderPart(this.kind);
  final TavernScriptPromptPlaceholder kind;
}

class TavernScriptPromptOverrides {
  TavernScriptPromptOverrides({TavernJsonObject fields = const {}})
    : _fields = _scriptDtoObject(fields, const {
        'worldInfoBefore',
        'personaDescription',
        'charDescription',
        'charPersonality',
        'scenario',
        'worldInfoAfter',
        'dialogueExamples',
        'chatHistory',
        'authorNote',
        'withDepthEntries',
      }) {
    for (final entry in _fields.entries) {
      if (entry.key == 'withDepthEntries') {
        if (entry.value is! bool) throw _scriptDtoError('overrides.${entry.key}', 'Expected a boolean.');
      } else if (entry.key == 'chatHistory') {
        if (entry.value is! List<Object?>) throw _scriptDtoError('overrides.chatHistory', 'Expected a list.');
        for (final (index, item) in (entry.value! as List<Object?>).indexed) {
          if (item is! Map<String, Object?>) {
            throw _scriptDtoError('overrides.chatHistory[$index]', 'Expected an object.');
          }
          _scriptDtoKeys(item, const {'role', 'content'}, prefix: 'overrides.chatHistory[$index].');
          _scriptEnum(TavernScriptPromptRole.values, item['role'], 'overrides.chatHistory[$index].role');
          if (item['content'] is! String) {
            throw _scriptDtoError('overrides.chatHistory[$index].content', 'Expected a string.');
          }
        }
      } else if (entry.value is! String) {
        throw _scriptDtoError('overrides.${entry.key}', 'Expected a string.');
      }
    }
  }
  final TavernJsonObject _fields;
  TavernJsonObject get fields => _scriptObject(_fields);
}

class TavernScriptGenerateRequest {
  TavernScriptGenerateRequest({
    this.generationId,
    this.presetId,
    this.speakerCharacterId,
    this.userInput = '',
    this.stream = false,
    this.includeReasoning = false,
    this.silent = false,
    this.maxChatHistory,
    TavernScriptPromptOverrides? overrides,
    List<TavernScriptInjection> injects = const [],
    TavernJsonObject samplingOverrides = const {},
  }) : overrides = overrides ?? TavernScriptPromptOverrides(),
       injects = List.unmodifiable(injects),
       _samplingOverrides = _scriptObject(samplingOverrides) {
    for (final entry in {
      'generationId': generationId,
      'presetId': presetId,
      'speakerCharacterId': speakerCharacterId,
    }.entries) {
      if (entry.value == '') throw _scriptDtoError(entry.key, 'Identity must be nonempty.');
    }
    if (maxChatHistory != null && maxChatHistory! < 0) {
      throw _scriptDtoError('maxChatHistory', 'Expected a nonnegative integer.', code: TavernScriptErrorCode.range);
    }
    final ids = <String>{};
    for (final item in this.injects) {
      if (!ids.add(item.id)) {
        throw _scriptDtoError('injects', 'Duplicate injection id.', code: TavernScriptErrorCode.duplicateId);
      }
    }
    _scriptDtoKeys(_samplingOverrides, const {
      'temperature',
      'top_p',
      'presence_penalty',
      'frequency_penalty',
      'max_tokens',
      'seed',
    }, prefix: 'samplingOverrides.');
    for (final entry in _samplingOverrides.entries) {
      final value = entry.value;
      final valid = entry.key == 'max_tokens'
          ? value is int && value > 0
          : entry.key == 'seed'
          ? value is int && value >= 0
          : value is num && value.isFinite;
      if (!valid) throw _scriptDtoError('samplingOverrides.${entry.key}', 'Invalid sampling value.');
    }
  }
  final String? generationId, presetId, speakerCharacterId;
  final String userInput;
  final bool stream, includeReasoning, silent;
  final int? maxChatHistory;
  final TavernScriptPromptOverrides overrides;
  final List<TavernScriptInjection> injects;
  final TavernJsonObject _samplingOverrides;
  TavernJsonObject get samplingOverrides => _scriptObject(_samplingOverrides);

  factory TavernScriptGenerateRequest.fromJson(TavernJsonObject json) {
    final value = _scriptDtoObject(json, _scriptRequestKeys);
    return TavernScriptGenerateRequest(
      generationId: _scriptOptionalString(value, 'generationId'),
      presetId: _scriptOptionalString(value, 'presetId'),
      speakerCharacterId: _scriptOptionalString(value, 'speakerCharacterId'),
      userInput: _scriptDefaultString(value, 'userInput', ''),
      stream: _scriptDefaultBool(value, 'stream'),
      includeReasoning: _scriptDefaultBool(value, 'includeReasoning'),
      silent: _scriptDefaultBool(value, 'silent'),
      maxChatHistory: _scriptOptionalInt(value, 'maxChatHistory'),
      overrides: _scriptRequestOverrides(value),
      injects: _scriptRequestInjections(value),
      samplingOverrides: _scriptDefaultObject(value, 'samplingOverrides'),
    );
  }
}

class TavernScriptRawRequest extends TavernScriptGenerateRequest {
  TavernScriptRawRequest({
    required List<TavernScriptPromptPart> orderedPrompts,
    super.generationId,
    super.presetId,
    super.speakerCharacterId,
    super.userInput,
    super.stream,
    super.includeReasoning,
    super.silent,
    super.maxChatHistory,
    super.overrides,
    super.injects,
    super.samplingOverrides,
  }) : orderedPrompts = List.unmodifiable(orderedPrompts);
  final List<TavernScriptPromptPart> orderedPrompts;
  factory TavernScriptRawRequest.fromJson(TavernJsonObject json) {
    final value = _scriptDtoObject(json, {..._scriptRequestKeys, 'orderedPrompts'});
    final ordered = value['orderedPrompts'];
    if (ordered is! List<Object?>) throw _scriptDtoError('orderedPrompts', 'Expected a list.');
    return TavernScriptRawRequest(
      orderedPrompts: [
        for (final item in ordered)
          if (item is Map<String, Object?>)
            TavernScriptPromptPart.fromJson(item)
          else
            throw _scriptDtoError('orderedPrompts', 'Expected prompt objects.'),
      ],
      generationId: _scriptOptionalString(value, 'generationId'),
      presetId: _scriptOptionalString(value, 'presetId'),
      speakerCharacterId: _scriptOptionalString(value, 'speakerCharacterId'),
      userInput: _scriptDefaultString(value, 'userInput', ''),
      stream: _scriptDefaultBool(value, 'stream'),
      includeReasoning: _scriptDefaultBool(value, 'includeReasoning'),
      silent: _scriptDefaultBool(value, 'silent'),
      maxChatHistory: _scriptOptionalInt(value, 'maxChatHistory'),
      overrides: _scriptRequestOverrides(value),
      injects: _scriptRequestInjections(value),
      samplingOverrides: _scriptDefaultObject(value, 'samplingOverrides'),
    );
  }
}

enum TavernScriptGenerationEventKind { snapshot, started, textDelta, reasoningDelta, finished, failed }

enum TavernScriptGenerationStatus { preparing, accepted, running, completed, failed, cancelled }

abstract interface class TavernScriptGeneration {
  String get id;
  Stream<TavernScriptGenerationEvent> get events;
  Future<TavernScriptGenerationResult> get result;
}

class TavernScriptGenerationOrigin {
  const TavernScriptGenerationOrigin({
    required this.contextId,
    required this.instanceId,
    required this.provider,
    required this.model,
    this.chatId,
    this.nodeAnchor,
    this.emptyChatAnchor = false,
  });
  final String contextId, instanceId, provider, model;
  final String? chatId;
  final TavernScriptMessageRef? nodeAnchor;
  final bool emptyChatAnchor;
}

class TavernScriptGenerationEvent {
  const TavernScriptGenerationEvent({
    required this.id,
    required this.seq,
    required this.kind,
    required this.status,
    this.text = '',
    this.reasoning,
    this.usage,
    this.delta,
    this.finishReason,
    this.error,
    this.isSnapshot = false,
    this.lastSeq,
  });
  final String id;
  final int seq;
  final TavernScriptGenerationEventKind kind;
  final TavernScriptGenerationStatus status;
  final String text;
  final String? reasoning, delta, finishReason;
  final TavernUsage? usage;
  final TavernScriptException? error;
  final bool isSnapshot;
  final int? lastSeq;
}

class TavernScriptGenerationResult {
  TavernScriptGenerationResult({
    required this.id,
    required this.text,
    required this.origin,
    this.reasoning,
    this.usage,
    this.finishReason,
    List<TavernScriptIssue> hookIssues = const [],
  }) : hookIssues = List.unmodifiable(hookIssues);
  final String id, text;
  final String? reasoning, finishReason;
  final TavernUsage? usage;
  final TavernScriptGenerationOrigin origin;
  final List<TavernScriptIssue> hookIssues;
}

enum TavernScriptInjectionPosition { inChat, scanOnly, beforeMain, afterMain }

enum TavernScriptInjectionSource { persistent, transient }

class TavernScriptInjection {
  TavernScriptInjection({
    required this.id,
    required this.content,
    this.role = TavernScriptPromptRole.system,
    this.position = TavernScriptInjectionPosition.inChat,
    this.depth = 4,
    this.scan,
    this.filter,
  }) {
    if (id.isEmpty) throw _scriptDtoError('id', 'Injection id must be nonempty.');
    if (depth < 0 || depth > 10000) {
      throw _scriptDtoError('depth', 'Depth must be between 0 and 10000.', code: TavernScriptErrorCode.range);
    }
  }
  final String id, content;
  final TavernScriptPromptRole role;
  final TavernScriptInjectionPosition position;
  final int depth;
  final bool? scan;
  final TavernScriptCallbackRef? filter;
  factory TavernScriptInjection.fromJson(TavernJsonObject json) {
    final value = _scriptDtoObject(json, const {'id', 'content', 'role', 'position', 'depth', 'scan', 'filter'});
    TavernScriptCallbackRef? filter;
    if (value['filter'] != null) {
      final raw = value['filter'];
      if (raw is! Map<String, Object?>) throw _scriptDtoError('filter', 'Expected a callback reference.');
      _scriptDtoKeys(raw, const {'contextId', 'instanceId', 'callbackId'}, prefix: 'filter.');
      filter = TavernScriptCallbackRef(
        contextId: _scriptRequiredString(raw, 'contextId'),
        instanceId: _scriptRequiredString(raw, 'instanceId'),
        callbackId: _scriptRequiredString(raw, 'callbackId'),
      );
    }
    final scan = value['scan'];
    if (scan != null && scan is! bool) throw _scriptDtoError('scan', 'Expected a boolean or null.');
    return TavernScriptInjection(
      id: _scriptRequiredString(value, 'id'),
      content: _scriptRequiredString(value, 'content'),
      role: value.containsKey('role')
          ? _scriptEnum(TavernScriptPromptRole.values, value['role'], 'role')
          : TavernScriptPromptRole.system,
      position: value.containsKey('position')
          ? _scriptEnum(TavernScriptInjectionPosition.values, value['position'], 'position')
          : TavernScriptInjectionPosition.inChat,
      depth: value.containsKey('depth') ? _scriptRequiredInt(value, 'depth') : 4,
      scan: scan as bool?,
      filter: filter,
    );
  }
}

class TavernScriptInjectionRegistration {
  const TavernScriptInjectionRegistration({required this.id, required this.registrationVersion});
  final String id, registrationVersion;
}

class TavernScriptInjectionLease {
  TavernScriptInjectionLease({
    required this.leaseId,
    required this.chatId,
    required this.ownerContextId,
    required this.ownerInstanceId,
    required List<TavernScriptInjectionRegistration> registrations,
  }) : registrations = List.unmodifiable(registrations);
  final String leaseId, chatId, ownerContextId, ownerInstanceId;
  final List<TavernScriptInjectionRegistration> registrations;
}

class TavernScriptInjectionView {
  TavernScriptInjectionView({
    required this.source,
    required TavernJsonObject sourceRef,
    required Object? raw,
    this.injection,
    this.filterStatus = 'none',
    List<TavernScriptIssue> issues = const [],
    this.ownerContextId,
    this.ownerInstanceId,
    this.registrationVersion,
    this.once = false,
    this.claimed = false,
    this.leaseId,
  }) : _sourceRef = _scriptObject(sourceRef),
       _raw = _scriptCopy(raw),
       issues = List.unmodifiable(issues);
  final TavernScriptInjectionSource source;
  final TavernJsonObject _sourceRef;
  final Object? _raw;
  TavernJsonObject get sourceRef => _scriptObject(_sourceRef);
  Object? get raw => _scriptCopy(_raw);
  final TavernScriptInjection? injection;
  final String filterStatus;
  final List<TavernScriptIssue> issues;
  final String? ownerContextId, ownerInstanceId, registrationVersion, leaseId;
  final bool once, claimed;
}

enum TavernScriptRegexSource { global, preset, character, chat }

class TavernScriptRegexQuery {
  TavernScriptRegexQuery({
    Set<TavernScriptRegexSource> sources = const {
      TavernScriptRegexSource.global,
      TavernScriptRegexSource.preset,
      TavernScriptRegexSource.character,
      TavernScriptRegexSource.chat,
    },
    this.effectiveOnly = false,
    this.characterId,
    this.presetId,
  }) : sources = Set.unmodifiable(sources) {
    if (characterId == '' || presetId == '') throw _scriptDtoError('query', 'Identity must be nonempty.');
  }
  final Set<TavernScriptRegexSource> sources;
  final bool effectiveOnly;
  final String? characterId, presetId;
  factory TavernScriptRegexQuery.fromJson(TavernJsonObject json) {
    final value = _scriptDtoObject(json, const {'sources', 'effectiveOnly', 'characterId', 'presetId'});
    final raw = value['sources'];
    if (value.containsKey('sources') && raw is! List<Object?>) throw _scriptDtoError('sources', 'Expected a list.');
    return TavernScriptRegexQuery(
      sources: raw == null
          ? TavernScriptRegexSource.values.toSet()
          : {for (final item in raw as List<Object?>) _scriptEnum(TavernScriptRegexSource.values, item, 'sources')},
      effectiveOnly: _scriptDefaultBool(value, 'effectiveOnly'),
      characterId: _scriptOptionalString(value, 'characterId'),
      presetId: _scriptOptionalString(value, 'presetId'),
    );
  }
}

class TavernScriptRegex {
  TavernScriptRegex({
    required this.source,
    required TavernJsonObject sourceRef,
    required TavernJsonObject raw,
    this.engineId,
    required this.stId,
    required this.execution,
    required this.enabled,
    required this.effective,
    List<TavernRegexDiagnostic> diagnostics = const [],
  }) : _sourceRef = _scriptObject(sourceRef),
       _raw = _scriptObject(raw),
       diagnostics = List.unmodifiable(diagnostics);
  final TavernScriptRegexSource source;
  final TavernJsonObject _sourceRef, _raw;
  TavernJsonObject get sourceRef => _scriptObject(_sourceRef);
  TavernJsonObject get raw => _scriptObject(_raw);
  final String? engineId;
  final String stId;
  final RegexScript execution;
  final bool enabled, effective;
  final List<TavernRegexDiagnostic> diagnostics;
}

/// One physical writable source, never the merged execution list.
enum TavernScriptRegexWriteKind { globalInline, globalLibrary, character, preset }

class TavernScriptRegexWriteTarget {
  const TavernScriptRegexWriteTarget.globalInline()
    : kind = TavernScriptRegexWriteKind.globalInline,
      characterId = null,
      preset = null;
  const TavernScriptRegexWriteTarget.globalLibrary()
    : kind = TavernScriptRegexWriteKind.globalLibrary,
      characterId = null,
      preset = null;
  const TavernScriptRegexWriteTarget.character({required String this.characterId})
    : kind = TavernScriptRegexWriteKind.character,
      preset = null;
  const TavernScriptRegexWriteTarget.preset({required TavernScriptPresetRef this.preset})
    : kind = TavernScriptRegexWriteKind.preset,
      characterId = null;
  final TavernScriptRegexWriteKind kind;
  final String? characterId;
  final TavernScriptPresetRef? preset;
  TavernJsonObject toJson() => {'kind': kind.name, 'characterId': ?characterId, 'preset': ?preset?.toJson()};
}

/// engineId is a managed-library identity; raw ST id is not a storage key.
class TavernScriptRegexWriteItem {
  TavernScriptRegexWriteItem({this.engineId, required TavernJsonObject raw}) : _raw = _scriptObject(raw);
  final String? engineId;
  final TavernJsonObject _raw;
  TavernJsonObject get raw => _scriptObject(_raw);
  TavernJsonObject toJson() => {'engineId': ?engineId, 'raw': raw};
}

class TavernScriptRegexWriteSnapshot {
  TavernScriptRegexWriteSnapshot({
    required this.target,
    required this.version,
    required TavernJsonObject source,
    required List<TavernScriptRegexWriteItem> items,
    List<TavernRegexDiagnostic> diagnostics = const [],
  }) : _source = _scriptObject(source),
       items = List.unmodifiable(items),
       diagnostics = List.unmodifiable(diagnostics);
  final TavernScriptRegexWriteTarget target;
  final String version;
  final TavernJsonObject _source;
  TavernJsonObject get source => _scriptObject(_source);
  final List<TavernScriptRegexWriteItem> items;
  final List<TavernRegexDiagnostic> diagnostics;
  TavernJsonObject toJson() => {
    'target': target.toJson(),
    'version': version,
    'source': source,
    'items': [for (final item in items) item.toJson()],
    'diagnostics': [for (final issue in diagnostics) issue.toJson()],
  };
}

const _scriptRequestKeys = <String>{
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
};

TavernScriptException _scriptDtoError(
  String path,
  String message, {
  TavernScriptErrorCode code = TavernScriptErrorCode.invalidArgument,
}) => TavernScriptException(code: code, operation: 'capture', message: message, fieldPath: path);
void _scriptDtoKeys(TavernJsonObject value, Set<String> allowed, {String prefix = ''}) {
  for (final key in value.keys) {
    if (!allowed.contains(key)) {
      throw _scriptDtoError('$prefix$key', 'Unsupported option.', code: TavernScriptErrorCode.unsupportedOption);
    }
  }
}

TavernJsonObject _scriptDtoObject(TavernJsonObject value, Set<String> allowed) {
  final captured = _scriptObject(value);
  _scriptDtoKeys(captured, allowed);
  return captured;
}

T _scriptEnum<T extends Enum>(List<T> values, Object? value, String path) {
  for (final item in values) {
    if (item.name == value) return item;
  }
  throw _scriptDtoError(path, 'Unknown value.');
}

String _scriptRequiredString(TavernJsonObject value, String key) {
  final raw = value[key];
  if (raw is! String) throw _scriptDtoError(key, 'Expected a string.');
  return raw;
}

String _scriptDefaultString(TavernJsonObject value, String key, String fallback) =>
    value.containsKey(key) ? _scriptRequiredString(value, key) : fallback;
String? _scriptOptionalString(TavernJsonObject value, String key) =>
    value[key] == null ? null : _scriptRequiredString(value, key);
int _scriptRequiredInt(TavernJsonObject value, String key) {
  final raw = value[key];
  if (raw is! int) throw _scriptDtoError(key, 'Expected an integer.');
  return raw;
}

int? _scriptOptionalInt(TavernJsonObject value, String key) =>
    value[key] == null ? null : _scriptRequiredInt(value, key);
bool _scriptDefaultBool(TavernJsonObject value, String key) {
  if (!value.containsKey(key)) return false;
  final raw = value[key];
  if (raw is! bool) throw _scriptDtoError(key, 'Expected a boolean.');
  return raw;
}

TavernJsonObject _scriptDefaultObject(TavernJsonObject value, String key) {
  if (!value.containsKey(key)) return {};
  final raw = value[key];
  if (raw is! Map<String, Object?>) throw _scriptDtoError(key, 'Expected an object.');
  return raw;
}

TavernScriptPromptOverrides _scriptRequestOverrides(TavernJsonObject value) =>
    TavernScriptPromptOverrides(fields: _scriptDefaultObject(value, 'overrides'));
List<TavernScriptInjection> _scriptRequestInjections(TavernJsonObject value) {
  if (!value.containsKey('injects')) return [];
  final raw = value['injects'];
  if (raw is! List<Object?>) throw _scriptDtoError('injects', 'Expected a list.');
  return [
    for (final item in raw)
      if (item is Map<String, Object?>)
        TavernScriptInjection.fromJson(item)
      else
        throw _scriptDtoError('injects', 'Expected injection objects.'),
  ];
}

Object? _scriptCopy(Object? value, [Set<Object>? seen]) {
  if (value == null || value is String || value is bool) {
    return value;
  }
  if (value is num && value.isFinite) {
    return value;
  }
  final active = seen ?? HashSet<Object>.identity();
  if (value is Map<Object?, Object?> || value is List<Object?>) {
    if (!active.add(value)) {
      throw TavernScriptException(
        code: TavernScriptErrorCode.invalidJson,
        operation: 'capture',
        message: 'Script JSON must not contain a cycle.',
      );
    }
    try {
      if (value is Map<Object?, Object?>) {
        final result = <String, Object?>{};
        for (final entry in value.entries) {
          if (entry.key is! String) {
            throw TavernScriptException(
              code: TavernScriptErrorCode.invalidJson,
              operation: 'capture',
              message: 'Script JSON object keys must be strings.',
            );
          }
          result[entry.key as String] = _scriptCopy(entry.value, active);
        }
        return result;
      }
      return [for (final item in value as List<Object?>) _scriptCopy(item, active)];
    } finally {
      active.remove(value);
    }
  }
  throw TavernScriptException(
    code: TavernScriptErrorCode.invalidJson,
    operation: 'capture',
    message: 'Expected finite standard JSON.',
  );
}

TavernJsonObject _scriptObject(Object? value) => _scriptCopy(value)! as TavernJsonObject;
