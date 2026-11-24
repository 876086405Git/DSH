/// 伙伴小屋's state on the Host, through the dsh-go bridge
/// (runtime/bridge/dsh-go-bridge/lib/companion/, contract in
/// docs/design/companion.md):
///
/// * `GET  /dsh-go/v1/companion`: identity, versions and her state now;
/// * `POST /dsh-go/v1/companion/events`: `visit` / `pet` / `snack` / `play` /
///   `rest`, with the store id and revision as read;
/// * `GET  /dsh-go/v1/companion/memories`, `POST .../memories` (add or replace
///   one, by a client-made id), `POST .../memories/delete`, `.../clear`.
///
/// Writes carry `storeId` + `expectedRevision`; a 409 means someone else wrote
/// first: read again, never replay with the new revision. Only HTTP carriers
/// reach the bridge (not the relay); a 404 without a code means an older
/// bridge. Refusals throw [DshRemoteException] `companion/<code>`.
library;

import 'carrier.dart';
import 'connection.dart';
import 'dsh_go_api.dart';
import 'errors.dart';
import 'json.dart';
import 'models.dart';
import 'mux.dart';
import 'session_api.dart';

const dshGoCompanionPath = '/dsh-go/v1/companion';

/// Her state as the Host projects it at [asOf].
class CompanionVitals {
  const CompanionVitals({
    required this.valence,
    required this.energy,
    required this.closeness,
    required this.activity,
    this.activityUntil,
    this.lastVisitAt,
    this.lastInteractionAt,
    this.thought,
  });

  factory CompanionVitals.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    double unit(String key, double fallback) => (asNum(map[key])?.toDouble() ?? fallback).clamp(0, 1);
    return CompanionVitals(
      valence: unit('valence', 0.25),
      energy: unit('energy', 0.75),
      closeness: unit('closeness', 0),
      activity: asString(map['activity']) ?? 'idle',
      activityUntil: _time(map['activityUntil']),
      lastVisitAt: _time(map['lastVisitAt']),
      lastInteractionAt: _time(map['lastInteractionAt']),
      thought: asString(map['thought']),
    );
  }

  /// 0–1: how pleased she is right now (rule variable, not a measurement).
  final double valence;

  /// 0–1: how lively.
  final double energy;

  /// 0–1: how well she knows the person; never decays with absence.
  final double closeness;

  /// `idle` / `snack` / `play` / `rest`; unknown names read as idle.
  final String activity;
  final DateTime? activityUntil;
  final DateTime? lastVisitAt;
  final DateTime? lastInteractionAt;
  final String? thought;
}

class CompanionSnapshot {
  const CompanionSnapshot({
    required this.storeId,
    required this.revision,
    required this.memoryRevision,
    required this.vitals,
    this.asOf,
    this.memories = false,
    this.automaticRecall = false,
  });

  static CompanionSnapshot? fromJson(Object? json) {
    final map = asMap(json);
    final storeId = asString(map?['storeId']);
    final revision = asInt(map?['revision']);
    if (map == null || storeId == null || revision == null) return null;
    final capabilities = asMapOrEmpty(map['capabilities']);
    return CompanionSnapshot(
      storeId: storeId,
      revision: revision,
      memoryRevision: asInt(map['memoryRevision']) ?? 0,
      vitals: CompanionVitals.fromJson(map['state']),
      asOf: _time(map['asOf']),
      memories: capabilities['memories'] == true,
      automaticRecall: capabilities['automaticRecall'] == true,
    );
  }

  final String storeId;
  final int revision;
  final int memoryRevision;
  final CompanionVitals vitals;

  /// The Host's clock when it projected [vitals].
  final DateTime? asOf;

  /// How long her current activity has left, on the Host's own clock (never
  /// the phone's: the two can disagree).
  Duration get activityLeft {
    final until = vitals.activityUntil;
    final now = asOf;
    if (vitals.activity == 'idle' || until == null || now == null) return Duration.zero;
    final left = until.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// The Host keeps confirmed memories.
  final bool memories;

  /// The Host puts them in front of her by itself (not yet: false).
  final bool automaticRecall;
}

/// Provenance supplied by the confirming UI, not proof of user approval.
class CompanionMemorySource {
  const CompanionMemorySource({this.kind = 'manual', this.sessionId, this.messageId});

  factory CompanionMemorySource.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return CompanionMemorySource(
      kind: asString(map['kind']) ?? 'manual',
      sessionId: asString(map['sessionId']),
      messageId: asString(map['messageId']),
    );
  }

  final String kind;
  final String? sessionId;
  final String? messageId;
  Map<String, Object?> toJson() => {
    'kind': kind,
    if (sessionId != null) 'sessionId': sessionId,
    if (messageId != null) 'messageId': messageId,
  };
}

/// One thing she remembers, as the person confirmed it.
class CompanionMemory {
  const CompanionMemory({
    required this.id,
    required this.text,
    this.kind = 'fact',
    this.keywords = const [],
    this.pinned = false,
    this.source = const CompanionMemorySource(),
    this.expiresAt,
    this.createdAt,
    this.updatedAt,
  });

  static CompanionMemory? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map?['id']);
    final text = asString(map?['text']);
    if (map == null || id == null || text == null) return null;
    return CompanionMemory(
      id: id,
      text: text,
      kind: asString(map['kind']) ?? 'fact',
      keywords: asStringList(map['keywords']),
      pinned: map['pinned'] == true,
      source: CompanionMemorySource.fromJson(map['source']),
      expiresAt: _time(map['expiresAt']),
      createdAt: _time(map['createdAt']),
      updatedAt: _time(map['updatedAt']),
    );
  }

  final String id;
  final String text;

  /// `fact` / `preference` / `episode`.
  final String kind;
  final List<String> keywords;
  final bool pinned;
  final CompanionMemorySource source;
  final DateTime? expiresAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// What a write sends: the server owns the timestamps.
  Map<String, Object?> toWrite() => {
    'id': id,
    'kind': kind,
    'text': text,
    'keywords': keywords,
    'pinned': pinned,
    'source': source.toJson(),
    'expiresAt': expiresAt?.millisecondsSinceEpoch,
  };

  void validateWrite() {
    if (!_migrationMemory(toWrite(), stored: false)) {
      throw const DshRemoteException('companion/invalid-request', 'Invalid companion memory', {'status': 400});
    }
  }
}

class CompanionMemories {
  const CompanionMemories({
    required this.storeId,
    required this.revision,
    required this.memories,
    this.memoryRevision = 0,
  });

  final String storeId;
  final int revision;
  final int memoryRevision;
  final List<CompanionMemory> memories;
}

/// A complete v1 read that can be used to migrate, unlike the tolerant UI DTO.
class CompanionMigrationSnapshot extends CompanionMemories {
  const CompanionMigrationSnapshot._({
    required super.storeId,
    required super.revision,
    required super.memoryRevision,
    required super.memories,
  });

  factory CompanionMigrationSnapshot.fromJson(Object? value) {
    final map = asMap(value);
    final rows = map?['memories'];
    if (map == null ||
        map['v'] != 1 ||
        !_migrationUuid(map['storeId']) ||
        !_migrationInteger(map['revision']) ||
        !_migrationInteger(map['memoryRevision']) ||
        (map['memoryRevision']! as num) > (map['revision']! as num) ||
        rows is! List ||
        rows.length > 256 ||
        !rows.every(_migrationMemory)) {
      throw const DshProtocolException('Invalid companion migration snapshot');
    }
    final memories = <CompanionMemory>[];
    for (final row in rows) {
      final memory = CompanionMemory.fromJson(row)!;
      memories.add(
        CompanionMemory(
          id: memory.id,
          text: memory.text,
          kind: memory.kind,
          keywords: List.unmodifiable(memory.keywords),
          pinned: memory.pinned,
          source: memory.source,
          expiresAt: memory.expiresAt,
          createdAt: memory.createdAt,
          updatedAt: memory.updatedAt,
        ),
      );
    }
    if (memories.map((m) => m.id.toLowerCase()).toSet().length != memories.length) {
      throw const DshProtocolException('Duplicate companion migration memory');
    }
    return CompanionMigrationSnapshot._(
      storeId: (map['storeId']! as String).toLowerCase(),
      revision: (map['revision']! as num).toInt(),
      memoryRevision: (map['memoryRevision']! as num).toInt(),
      memories: List.unmodifiable(memories),
    );
  }

  /// Advance only from the acknowledgement for our own conditional deletion.
  CompanionMigrationSnapshot afterDeletion(String id, Object? value) {
    final map = asMap(value);
    final deleted = map?['deleted'];
    if (map == null ||
        map['v'] != 1 ||
        map['storeId'] is! String ||
        (map['storeId']! as String).toLowerCase() != storeId ||
        deleted is! bool ||
        map['revision'] != revision + (deleted ? 1 : 0) ||
        map['memoryRevision'] != memoryRevision + (deleted ? 1 : 0)) {
      throw const DshProtocolException('Unconfirmed companion migration deletion');
    }
    return CompanionMigrationSnapshot._(
      storeId: storeId,
      revision: revision + (deleted ? 1 : 0),
      memoryRevision: memoryRevision + (deleted ? 1 : 0),
      memories: List.unmodifiable(memories.where((m) => m.id.toLowerCase() != id.toLowerCase())),
    );
  }
}

bool _migrationUuid(Object? value) =>
    value is String &&
    RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      caseSensitive: false,
    ).hasMatch(value);

bool _migrationInteger(Object? value) =>
    value is num && value.isFinite && value >= 0 && value <= 9007199254740991 && value == value.truncateToDouble();

bool _migrationTime(Object? value) => _migrationInteger(value) && (value! as num) <= 8640000000000000;

bool _migrationText(Object? value, int limit, {bool multiline = false}) {
  if (value is! String ||
      value.runes.length > limit ||
      RegExp(
        r'^[\u0009-\u000D\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]*$',
      ).hasMatch(value) ||
      RegExp(
        multiline ? r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]' : r'[\u0000-\u001f\u007f]',
      ).hasMatch(value)) {
    return false;
  }
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= value.length || value.codeUnitAt(i) < 0xdc00 || value.codeUnitAt(i) > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

bool _migrationMemory(Object? value, {bool stored = true}) {
  final map = asMap(value);
  final keys = {
    'id',
    'kind',
    'text',
    'keywords',
    'pinned',
    'source',
    'expiresAt',
    if (stored) ...['createdAt', 'updatedAt'],
  };
  if (map == null ||
      map.keys.toSet().difference(keys).isNotEmpty ||
      !keys.every(map.containsKey) ||
      !_migrationUuid(map['id']) ||
      !const ['fact', 'preference', 'episode'].contains(map['kind']) ||
      !_migrationText(map['text'], 512, multiline: true) ||
      map['pinned'] is! bool ||
      !(map['expiresAt'] == null || _migrationTime(map['expiresAt'])) ||
      (stored &&
          (!_migrationTime(map['createdAt']) ||
              !_migrationTime(map['updatedAt']) ||
              (map['createdAt']! as num) > (map['updatedAt']! as num)))) {
    return false;
  }
  final keywords = map['keywords'];
  final source = asMap(map['source']);
  return keywords is List &&
      keywords.length <= 8 &&
      keywords.every((k) => _migrationText(k, 24)) &&
      source != null &&
      const ['manual', 'user-confirmed'].contains(source['kind']) &&
      source.keys.every(const {'kind', 'sessionId', 'messageId'}.contains) &&
      ['sessionId', 'messageId'].every(
        (key) =>
            !source.containsKey(key) ||
            (source[key] is String && (source[key]! as String).length <= 128 && _migrationText(source[key], 128)),
      );
}

DateTime? _time(Object? value) {
  final ms = asInt(value);
  return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
}

/// The bridge's process identity and this session's setting revision. Clear
/// locally acknowledged settings whenever instanceId changes or on reconnect.
class CompanionPromptCapability {
  const CompanionPromptCapability({
    required this.instanceId,
    required this.sessionId,
    required this.profileRevision,
    this.profileAccepted,
    this.memoryMode = 'query',
    this.memoryEpoch,
    this.phoneMemory = false,
    int? phoneMemoryVersion,
    this.selectedPage = false,
    this.chatUsage = false,
    this.screenEvents = false,
  }) : phoneMemoryVersion = phoneMemoryVersion ?? (phoneMemory ? 2 : 0);
  final String instanceId;
  final String sessionId;
  final int profileRevision;
  final bool? profileAccepted;

  /// Older prompt-context hosts omit this field and use query sidecars.
  /// `automatic` means C902 is the sole memory provider for this target;
  /// it is not a claim that a recall binding is still ready.
  final String memoryMode;

  /// Host-owned memory generation, when advertised. Clients may suppress an
  /// unnecessary query but cannot grant or restore memory using this value.
  final int? memoryEpoch;

  /// The runtime can attach the phone's already selected block to this
  /// request without writing it into the Session or system projections.
  final bool phoneMemory;

  /// v3 preserves the phone's selected layers and source labels, and supports deviceContext.
  final int phoneMemoryVersion;

  /// This bridge accepts a shared page in the matching request-only sidecar.
  final bool selectedPage;

  /// Owner-only observations for marked ordinary chat calls. This is not
  /// complete billing coverage for background, compaction, or other agents.
  final bool chatUsage;

  /// This bridge accepts her own lines about the screen as 'screen' events.
  final bool screenEvents;

  static CompanionPromptCapability? fromJson(Object? value) {
    final map = asMap(value);
    if (map == null) return null;
    final instance = asString(map['instanceId']), session = asString(map['sessionId']);
    final revision = asInt(map['profileRevision']);
    final memoryMode = map.containsKey('memoryMode') ? asString(map['memoryMode']) : 'query';
    final memoryEpoch = asInt(map['memoryEpoch']);
    if (map['v'] != 1 ||
        map['supported'] != true ||
        instance == null ||
        instance.isEmpty ||
        session == null ||
        session.isEmpty ||
        revision == null ||
        revision < 0 ||
        revision > 9007199254740991 ||
        (memoryMode != 'query' && memoryMode != 'automatic' && memoryMode != 'phone') ||
        (map.containsKey('phoneMemory') && map['phoneMemory'] is! bool) ||
        (map.containsKey('phoneMemoryVersion') &&
            (map['phoneMemory'] != true || map['phoneMemoryVersion'] is! int || (map['phoneMemoryVersion'] as int) < 2)) ||
        (map.containsKey('chatUsage') && map['chatUsage'] is! bool) ||
        (memoryMode == 'phone' && map['phoneMemory'] != true) ||
        (map.containsKey('memoryEpoch') &&
            (memoryEpoch == null || memoryEpoch < 0 || memoryEpoch > 9007199254740991)) ||
        (map.containsKey('profileAccepted') && map['profileAccepted'] is! bool)) {
      return null;
    }
    return CompanionPromptCapability(
      instanceId: instance,
      sessionId: session,
      profileRevision: revision,
      profileAccepted: map['profileAccepted'] as bool?,
      memoryMode: memoryMode!,
      memoryEpoch: memoryEpoch,
      phoneMemory: map['phoneMemory'] == true,
      phoneMemoryVersion: map['phoneMemoryVersion'] as int?,
      selectedPage: map['selectedPage'] == true,
      chatUsage: map['chatUsage'] == true,
      screenEvents: map['screenEvents'] == true,
    );
  }
}

/// Ownership captured when a synchronized session/follow subscription accepts
/// events, before any asynchronous UI delivery. Never construct a new scope to
/// label a late event from an old subscription. [sessionScope] is the App's
/// actual target/watch identity, replaced on mode/target changes (also A→B→A).
final class CompanionPromptScope {
  const CompanionPromptScope({
    required this.client,
    required this.generation,
    required this.followEpoch,
    required this.sessionScope,
    required this.instanceId,
    required this.sessionId,
  });

  final DshClient client;
  final MuxGeneration generation;
  final SessionFollowEpoch followEpoch;
  final Object sessionScope;
  final String instanceId;
  final String sessionId;

  bool get isCurrent =>
      followEpoch.isCurrent &&
      identical(followEpoch.generation, generation) &&
      identical(client.mux.generation, generation);

  bool _sameAs(CompanionPromptScope other) =>
      identical(client, other.client) &&
      identical(generation, other.generation) &&
      identical(followEpoch, other.followEpoch) &&
      identical(sessionScope, other.sessionScope) &&
      instanceId == other.instanceId &&
      sessionId == other.sessionId;
}

/// Matches one prepared event snapshot to the Host's durable human commit.
/// This does not subscribe, send, or consume anything. Supply events from the
/// synchronized session/follow log (or its validated snapshot), not inbox or
/// optimistic UI messages. POST ACK and prompt/chat.send success only mean
/// preparation/acceptance and cannot call this path as a commit.
final class CompanionPromptCommit {
  CompanionPromptCommit({required this.scope, required this.requestId, required Iterable<String> eventIds})
    : eventIds = List.unmodifiable(eventIds) {
    if (!_promptIdentity(scope.instanceId) ||
        !_promptIdentity(scope.sessionId) ||
        !_promptIdentity(requestId) ||
        this.eventIds.length > 8 ||
        this.eventIds.any((id) => !_promptIdentity(id)) ||
        this.eventIds.toSet().length != this.eventIds.length) {
      throw const FormatException('Invalid companion commit identity');
    }
  }

  final CompanionPromptScope scope;
  final String requestId;
  final List<String> eventIds;

  /// [from] belongs to the original event callback; [current] is the current
  /// selected target. A typed user/message alone carries no session identity,
  /// so both ownership proofs are required. The caller already established
  /// that this is an actual durable event, not a locally fabricated DTO.
  List<String> committedEventIds(
    DshEvent event, {
    required CompanionPromptScope from,
    required CompanionPromptScope current,
  }) {
    if (!scope._sameAs(from) ||
        !scope._sameAs(current) ||
        !scope.isCurrent ||
        event is! UserMessageEvent ||
        event.seq < 0 ||
        event.message.role != MessageRole.user ||
        event.message.source.kind != 'user' ||
        event.message.source.raw.containsKey('principal') ||
        event.requestId != requestId) {
      return const [];
    }
    // Queue edits legitimately change text while preserving rpcId and the
    // physical-event snapshot. Text comparison would discard that receipt.
    return eventIds;
  }
}

bool _promptIdentity(String value) =>
    value.isNotEmpty && value.runes.length <= 128 && !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

extension CompanionApi on DshClient {
  DshConnection get _bridge => (carrier as DshHttpCarrier).connection;

  /// Null only for a carrier/old bridge without this route. Authentication,
  /// invalid sessions, malformed success and network failures are not fallback.
  Future<CompanionPromptCapability?> companionPromptCapability(String sessionId) async {
    if (!canReachDshGo) return null;
    const path = '$dshGoCompanionPath/prompt-context';
    final response = await _bridge.get(path, query: {'sessionId': sessionId}, timeout: const Duration(seconds: 8));
    if (response.statusCode == 404 && (_codeOf(response) == null || _codeOf(response) == 'companion/not-found')) {
      return null;
    }
    return _promptCapability(path, response, sessionId);
  }

  /// Restore a replaced companion session without changing the Host default.
  /// An old bridge or relay can already have the desired default. If it does
  /// not, keep the requested model for a later retry on an upgraded host.
  Future<void> restoreCompanionSessionModel(String sessionId, ModelSelection model) async {
    bool same(ModelSelection? selected) => selected?.provider == model.provider &&
        selected?.model == model.model && selected?.reasoningEffort == model.reasoningEffort;
    if (canReachDshGo) {
      const path = '$dshGoCompanionPath/restore-model';
      final response = await _bridge.postJson(path, {'sessionId': sessionId, 'model': model.toJson()});
      if (response.statusCode == 200) {
        final body = asMap(tryDecodeJson(response.text));
        if (body?['sessionId'] == sessionId && same(ModelSelection.fromJson(body?['model']))) return;
        throw const DshProtocolException('Unconfirmed companion model restoration');
      }
      if (response.statusCode != 404 || (_codeOf(response) != null && _codeOf(response) != 'companion/not-found')) {
        throw companionHttpError(path, response);
      }
    }
    final projection = await projections(sessionId);
    if (projection == null) throw const DshRemoteException('session/not-found', 'Missing companion session');
    if (same(projection.nextModel ?? (await listModels()).defaultSelection)) return;
    throw const DshRemoteException('companion/model-restore-unavailable', 'Select the previous model on this host');
  }

  /// Send the pure App plan's update, then prompt with the SAME requestId.
  /// Retry an uncertain HTTP outcome with identical bytes/id; never a new id.
  /// The acknowledgement prepares context; it is not a human user/message
  /// commit and must not consume the App's local event snapshot.
  Future<CompanionPromptCapability> prepareCompanionPromptContext(Map<String, Object?> update) async {
    if (!canReachDshGo) throw const DshProtocolException('Companion context needs an HTTP bridge');
    const path = '$dshGoCompanionPath/prompt-context';
    final response = await _bridge.postJson(path, update, timeout: const Duration(seconds: 8));
    final value = _promptCapability(path, response, update['sessionId'] as String);
    if (value.instanceId != update['instanceId']) {
      throw const DshProtocolException('Companion context acknowledgement is from another instance');
    }
    return value;
  }

  CompanionPromptCapability _promptCapability(String path, DshHttpResponse response, String sessionId) {
    if (response.statusCode != 200) throw companionHttpError(path, response);
    final value = CompanionPromptCapability.fromJson(tryDecodeJson(response.text));
    if (response.contentType != 'application/json' || value == null || value.sessionId != sessionId) {
      throw DshProtocolException('$path: not a companion prompt capability');
    }
    return value;
  }

  /// `GET /dsh-go/v1/companion`. Null when this Host can't keep her state:
  /// the relay, or a bridge without these routes.
  Future<CompanionSnapshot?> companionSnapshot({Duration timeout = const Duration(seconds: 8)}) async {
    if (!canReachDshGo) return null;
    final response = await _bridge.get(dshGoCompanionPath, timeout: timeout);
    if (response.statusCode == 404 && _codeOf(response) == null) return null;
    return _snapshot(dshGoCompanionPath, response);
  }

  /// `POST /dsh-go/v1/companion/events`.
  Future<CompanionSnapshot> companionEvent(
    CompanionSnapshot read,
    String type, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    const path = '$dshGoCompanionPath/events';
    final response = await _bridge.postJson(path, {
      'storeId': read.storeId,
      'expectedRevision': read.revision,
      'type': type,
    }, timeout: timeout);
    return _snapshot(path, response);
  }

  Future<CompanionMemories> companionMemories({Duration timeout = const Duration(seconds: 8)}) async {
    const path = '$dshGoCompanionPath/memories';
    final response = await _bridge.get(path, timeout: timeout);
    return _memories(path, response);
  }

  Future<CompanionMigrationSnapshot> companionMemoriesForMigration({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    const path = '$dshGoCompanionPath/memories';
    final response = await _bridge.get(path, timeout: timeout);
    if (response.statusCode != 200) throw companionHttpError(path, response);
    return CompanionMigrationSnapshot.fromJson(tryDecodeJson(response.text));
  }

  Future<CompanionMigrationSnapshot> deleteMigratedCompanionMemory(CompanionMigrationSnapshot read, String id) async {
    const path = '$dshGoCompanionPath/memories/delete';
    final response = await _bridge.postJson(path, {
      'storeId': read.storeId,
      'expectedRevision': read.revision,
      'id': id,
    }, timeout: const Duration(seconds: 8));
    if (response.statusCode != 200) throw companionHttpError(path, response);
    return read.afterDeletion(id, tryDecodeJson(response.text));
  }

  /// Adds [memory], or replaces the one with its id. Returns the new revision.
  Future<int> saveCompanionMemory(String storeId, int revision, CompanionMemory memory) async {
    const path = '$dshGoCompanionPath/memories';
    final response = await _bridge.postJson(path, {
      'storeId': storeId,
      'expectedRevision': revision,
      'memory': memory.toWrite(),
    }, timeout: const Duration(seconds: 8));
    return _revision(path, response);
  }

  Future<int> deleteCompanionMemory(String storeId, int revision, String id) async {
    const path = '$dshGoCompanionPath/memories/delete';
    final response = await _bridge.postJson(path, {
      'storeId': storeId,
      'expectedRevision': revision,
      'id': id,
    }, timeout: const Duration(seconds: 8));
    return _revision(path, response);
  }

  CompanionSnapshot _snapshot(String path, DshHttpResponse response) {
    if (response.statusCode != 200) throw companionHttpError(path, response);
    final snapshot = CompanionSnapshot.fromJson(tryDecodeJson(response.text));
    if (snapshot == null) throw DshProtocolException('$path: not a companion snapshot');
    return snapshot;
  }

  CompanionMemories _memories(String path, DshHttpResponse response) {
    if (response.statusCode != 200) throw companionHttpError(path, response);
    final map = asMap(tryDecodeJson(response.text));
    final storeId = asString(map?['storeId']);
    final revision = asInt(map?['revision']);
    if (map == null || storeId == null || revision == null) throw DshProtocolException('$path: not a memory list');
    return CompanionMemories(
      storeId: storeId,
      revision: revision,
      memoryRevision: asInt(map['memoryRevision']) ?? 0,
      memories: [for (final m in asListOrEmpty(map['memories'])) ?CompanionMemory.fromJson(m)],
    );
  }

  int _revision(String path, DshHttpResponse response) {
    if (response.statusCode != 200) throw companionHttpError(path, response);
    final revision = asInt(asMap(tryDecodeJson(response.text))?['revision']);
    if (revision == null) throw DshProtocolException('$path: no revision');
    return revision;
  }
}

String? _codeOf(DshHttpResponse response) => asString(asMap(asMap(tryDecodeJson(response.text))?['error'])?['code']);

/// A refusal as its `companion/<code>` (`companion/http-<status>` without one).
DshRemoteException companionHttpError(String path, DshHttpResponse response) {
  final error = asMap(asMap(tryDecodeJson(response.text))?['error']);
  final code = asString(error?['code']);
  return DshRemoteException(
    code ?? 'companion/http-${response.statusCode}',
    asString(error?['message']) ?? '$path: HTTP ${response.statusCode}',
    {'route': path, 'status': response.statusCode},
  );
}
