/// High-level chat API over [DshRpc] + [DshMux].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'agents_api.dart';
import 'background_session_read.dart';
import 'carrier.dart';
import 'session_activation.dart';
import 'connection.dart';
import 'errors.dart';
import 'json.dart';
import 'models.dart';
import 'mux.dart';
import 'rpc.dart';
import 'rpc_envelope.dart';
import 'workspace_upload.dart';

/// `queue` waits for the next turn; `steer` injects into the running turn's
/// next step.
enum PromptMode {
  queue('queue'),
  steer('steer');

  const PromptMode(this.wire);
  final String wire;
}

/// Inline image for `session/prompt` (png, jpeg, webp, gif; 20 MiB per image,
/// 20 images and 200 MiB per message by default — see
/// `SessionProjections.imageLimits`).
class PromptImage {
  const PromptImage({required this.mediaType, required this.base64Data, this.name});

  factory PromptImage.fromBytes(List<int> bytes, {required String mediaType, String? name}) =>
      PromptImage(mediaType: mediaType, base64Data: base64Encode(bytes), name: name);

  final String mediaType;
  final String base64Data;
  final String? name;

  Map<String, Object?> toJson() => {
    'type': 'image',
    'mediaType': mediaType,
    'data': base64Data,
    if (name != null) 'name': name,
  };
}

/// History window minima used by `session/follow` and `session/page`.
class TurnWindow {
  const TurnWindow(this.minMessages, this.minTurns);
  final int minMessages;
  final int minTurns;

  Map<String, Object?> toJson() => {'minMessages': minMessages, 'minTurns': minTurns};
}

class WatchOptions {
  const WatchOptions({
    this.assistantStream = true,
    this.activate = false,
    this.activationAllowed,
    this.onActivationChecked,
    this.turnWindow = const TurnWindow(50, 2),
    this.maxMessages = 500,
    this.includeHostEvents = true,
    this.includeConnectionEvents = true,
    this.includeSyncEvents = false,
    this.hostRequestGrace = const Duration(seconds: 3),
  });

  /// Request activation on a confirmed compatible Host. Passive readers keep
  /// this false. Unknown releases and carriers without release evidence omit it.
  final bool activate;

  /// Rechecked after discovery and on every reconnect. A screen can revoke
  /// its interaction intent while a capability read is in flight.
  final bool Function()? activationAllowed;

  /// Reports the current generation's release check, including a cached
  /// result. Discovery follows the passive baseline and never delays it.
  /// Runs only for an allowed interaction that is still in the same epoch;
  /// callers must not replace the primary follow in response.
  final void Function(bool supported)? onActivationChecked;

  /// Receive live token deltas ([AssistantStreamEvent]s).
  final bool assistantStream;

  /// Initial window; the official web client uses 50 messages / 2 turns.
  final TurnWindow? turnWindow;

  /// Hard cap on the initial window. The Host cuts at the [turnWindow] turn
  /// start unless this many messages come first (then mid-turn, losing that
  /// turn's `turn/start`); its own default is 50, so without a larger cap a
  /// 50-message window cuts mid-turn. 500 as in the official web client
  /// (`HISTORY_PAGE_OPTIONS`).
  final int? maxMessages;

  /// Forward this session's approvals, questions, status and errors.
  final bool includeHostEvents;
  final bool includeConnectionEvents;

  /// Control surfaces need a fresh complete baseline after every follow
  /// discontinuity. Emit local [SessionSyncEvent]s and reopen on log gaps;
  /// the default read-only stream retains its snapshot-first contract.
  final bool includeSyncEvents;

  /// Reconcile requests not redelivered after a new Host ready generation.
  final Duration hostRequestGrace;
}

class FileReceipt {
  const FileReceipt(this.receiptId, this.attachment);
  final String receiptId;
  final FileAttachment attachment;
}

class DirectoryListing {
  const DirectoryListing(this.path, this.home, this.entries, this.truncated);
  final String path;
  final String home;
  final List<({String name, String path, bool hidden})> entries;
  final bool truncated;
}

class CommandResult {
  const CommandResult(this.commandId, this.success, this.text);
  final String? commandId;
  final bool success;
  final String? text;
}

/// `session/control` frames: per-session projection values for every
/// resident session (titles, running inbox, model, permissions, ...).
sealed class SessionControlUpdate {
  const SessionControlUpdate();
}

/// Complete per-generation baseline; replaces previous projection state.
final class SessionControlBaseline extends SessionControlUpdate {
  const SessionControlBaseline(this.projections);
  final Map<String, SessionProjections> projections;
}

final class SessionControlProjection extends SessionControlUpdate {
  const SessionControlProjection(this.sessionId, this.key, this.value, this.seq);
  final String sessionId;
  final String key;
  final Object? value;
  final int seq;
}

/// Entry point for the app.
///
/// ```dart
/// final client = await DshClient.connect(launchUrl: 'http://127.0.0.1:3080/?token=...');
/// final created = await client.createSession(cwd: '/data/ws');
/// final events = client.watch(created.sessionId).listen(print);
/// await client.prompt(created.sessionId, 'hello');
/// ```
///
/// The same API runs over any [DshCarrier]: [DshClient.new] and [connect]
/// use the local HTTP/WebSocket carrier, [DshClient.withCarrier] /
/// [connectCarrier] accept others (for example the encrypted tunnel from
/// `package:dsh_remote`).
class DshClient {
  /// Local `dsh web` over HTTP + WebSocket ([DshHttpCarrier]).
  DshClient(
    DshConnection connection, {
    MuxOptions muxOptions = const MuxOptions(),
    bool backgroundSessionLists = false,
    bool backgroundLists = false,
  }) : this.withCarrier(
         DshHttpCarrier(connection),
         muxOptions: muxOptions,
         backgroundSessionLists: backgroundSessionLists,
         backgroundLists: backgroundLists,
       );

  /// Any carrier. Nothing connects until the first call or [DshMux.ready].
  DshClient.withCarrier(
    this.carrier, {
    MuxOptions muxOptions = const MuxOptions(),
    this.backgroundSessionLists = false,
    this.backgroundLists = false,
  }) : rpc = DshRpc(carrier),
       mux = DshMux(carrier, options: muxOptions);

  /// Builds a connection, logs in when a token is given (otherwise uses
  /// [cookie]) and waits for the first ready mux generation.
  ///
  /// [launchUrl] accepts the `dsh web: http://...?token=...` line.
  static Future<DshClient> connect({
    Uri? baseUri,
    String? token,
    String? launchUrl,
    DshCookie? cookie,
    String? hostHeader,
    MuxOptions muxOptions = const MuxOptions(),
    DshTracer? tracer,
    bool backgroundSessionLists = false,
    bool backgroundLists = false,
    bool startMux = true,
    Duration readyTimeout = const Duration(seconds: 20),
  }) async {
    var base = baseUri;
    var launchToken = token;
    if (launchUrl != null) {
      final parsed = DshLaunchUrl.tryParse(launchUrl);
      if (parsed == null) throw ArgumentError.value(launchUrl, 'launchUrl', 'no URL with a token');
      base ??= parsed.baseUri;
      launchToken ??= parsed.token;
    }
    if (base == null) throw ArgumentError('baseUri or launchUrl is required');
    final connection = DshConnection(base, hostHeader: hostHeader, cookie: cookie, tracer: tracer);
    final client = DshClient(
      connection,
      muxOptions: muxOptions,
      backgroundSessionLists: backgroundSessionLists,
      backgroundLists: backgroundLists,
    );
    try {
      if (launchToken != null) {
        await connection.login(launchToken);
      } else if (cookie == null) {
        throw ArgumentError('token, launchUrl or cookie is required');
      }
      if (startMux) await client.mux.ready(timeout: readyTimeout);
      return client;
    } on Object {
      await client.close();
      rethrow;
    }
  }

  /// [DshClient.withCarrier] plus waiting for the first ready generation
  /// (when [startMux]); closes the client again if that fails.
  static Future<DshClient> connectCarrier(
    DshCarrier carrier, {
    MuxOptions muxOptions = const MuxOptions(),
    bool startMux = true,
    Duration readyTimeout = const Duration(seconds: 30),
  }) async {
    final client = DshClient.withCarrier(carrier, muxOptions: muxOptions);
    try {
      if (startMux) await client.mux.ready(timeout: readyTimeout);
      return client;
    } on Object {
      await client.close();
      rethrow;
    }
  }

  /// Offload stock HTTP session/list IO, gzip, JSON and DTO work. Default is
  /// false for SDK compatibility. Custom carriers/connections and record mode
  /// keep their original path; changing tracer retires pending worker reads.
  /// Opt-in reads enforce 8 MiB/100k rows and bounded queues; they fail rather
  /// than truncate. This does not offload remote/mux or App filtering/sorting.
  final bool backgroundSessionLists;

  /// Extends the same opt-in policy to model/provider/plugin lists and the
  /// settings/credential metadata those lists use. All operations share the
  /// session worker budget. Remote/custom/record mode retains its old path.
  /// No write, stream or discovery request is redirected to a worker.
  final bool backgroundLists;

  /// Internal dispatch shared by extension APIs. A null future means use the
  /// original carrier; a future containing null is a valid absent DTO.
  Future<Object?>? tryBackgroundListRead(BackgroundListKind kind, {List<String> credentialRefs = const []}) {
    if (!backgroundLists && !(backgroundSessionLists && kind == BackgroundListKind.sessions)) return null;
    final transport = carrier;
    if (transport.runtimeType != DshHttpCarrier || transport is! DshHttpCarrier) return null;
    if (!transport.connection.canReadSessionsInBackground) return null;
    return transport.connection.readListInBackground(kind, credentialRefs: credentialRefs);
  }

  final DshCarrier carrier;
  final DshRpc rpc;
  final DshMux mux;

  /// The HTTP connection of the default carrier (cookie, health check).
  ///
  /// Throws [StateError] for other carriers; check [carrier] first.
  DshConnection get connection => switch (carrier) {
    DshHttpCarrier(:final connection) => connection,
    _ => throw StateError(
      'DshClient.connection is only available on the HTTP carrier '
      '(this client uses ${carrier.kind})',
    ),
  };

  /// Whether [endpoint] is reachable through this client's carrier (remote
  /// tunnels serve a fixed allow-list; `fileUploads/upload` is not on it).
  bool supportsEndpoint(String endpoint) => carrier.allowsEndpoint(endpoint);

  /// Receipt staging or the current connection's workspace upload protocol.
  bool get supportsFileUpload =>
      supportsEndpoint('fileUploads/upload') ||
      (carrier is WorkspaceUploadCarrier && (carrier as WorkspaceUploadCarrier).supportsWorkspaceUpload);

  /// The live connection carries the workspace upload protocol
  /// (ds-harness-remote `workspace.upload.v1`): [uploadWorkspaceFile] works.
  bool get supportsWorkspaceUpload =>
      carrier is WorkspaceUploadCarrier && (carrier as WorkspaceUploadCarrier).supportsWorkspaceUpload;

  /// Publishes a file into this session's workspace, without a receipt.
  /// The returned relative path must be included in the prompt instead.
  Future<WorkspaceUploadedFile> uploadWorkspaceFile(String sessionId, List<int> bytes, {required String name}) {
    final transport = carrier is WorkspaceUploadCarrier ? carrier as WorkspaceUploadCarrier : null;
    if (transport == null || !transport.supportsWorkspaceUpload) {
      throw const DshRemoteException('WORKSPACE_UPLOAD_UNSUPPORTED', 'This Host does not support workspace uploads.');
    }
    return transport.uploadWorkspaceFile(sessionId, bytes, name: name);
  }

  /// All `$events` items (session added/status/error, approvals, ...).
  Stream<HostEvent> get hostEvents => mux.hostEvents;

  // ---------------------------------------------------------------------------
  // Sessions

  /// `session/list`: every stored session, newest first, *including archived
  /// and subagent sessions*. Filter archived ones with [watchWorkspaces].
  Future<List<SessionSummary>> listSessions() async {
    final read = tryBackgroundListRead(BackgroundListKind.sessions);
    if (read != null) return (await read) as List<SessionSummary>;
    final value = asMapOrEmpty(await rpc.call('session/list', {'_request': <String, Object?>{}}));
    return asListOrEmpty(value['items']).map(SessionSummary.fromJson).toList(growable: false);
  }

  /// `session/create`. Pass [workspaceId] to attach the session to a
  /// workspace (its path becomes the cwd) or [cwd] for a bare directory; with
  /// neither, the Host uses the `dsh web` process cwd. [sessionId] adopts or
  /// resumes an existing stored session instead (`session/writer-held` when
  /// another process holds it).
  Future<SessionCreated> createSession({
    String? cwd,
    String? workspaceId,
    String? agentPreset,
    String? sessionId,
  }) async {
    final value = asMapOrEmpty(
      await rpc.call('session/create', {
        'request': {'workspaceId': ?workspaceId, 'cwd': ?cwd, 'sessionId': ?sessionId, 'agentPreset': ?agentPreset},
      }),
    );
    return SessionCreated(asString(value['sessionId']) ?? '', asString(value['agentPreset']));
  }

  /// `workspace/archiveSession`; returns the full archived set. Archiving a
  /// running session stops its work when [stopActivity] is true.
  Future<List<String>> archiveSession(String sessionId, {bool? stopActivity}) async {
    final value = asMapOrEmpty(
      await rpc.call('workspace/archiveSession', {
        'request': {'sessionId': sessionId, 'stopActivity': ?stopActivity},
      }),
    );
    return asStringList(value['archivedSessionIds']);
  }

  Future<List<String>> unarchiveSession(String sessionId) async {
    final value = asMapOrEmpty(
      await rpc.call('workspace/unarchiveSession', {
        'request': {'sessionId': sessionId},
      }),
    );
    return asStringList(value['archivedSessionIds']);
  }

  /// `session/rename`; pins the title (automatic titling stops).
  Future<String> renameSession(String sessionId, String title) async {
    final value = asMapOrEmpty(
      await rpc.call('session/rename', {
        'request': {'sessionId': sessionId, 'title': title},
      }),
    );
    return asString(value['title']) ?? title;
  }

  /// `session/fork`; omit [atSeq] to fork at the latest completed turn.
  Future<String> forkSession(String sessionId, {int? atSeq}) async {
    final value = asMapOrEmpty(
      await rpc.call('session/fork', {
        'request': {'sessionId': sessionId, 'atSeq': ?atSeq},
      }),
    );
    return asString(value['sessionId']) ?? '';
  }

  /// `session/projections`: non-activating read; `null` for unknown sessions.
  Future<SessionProjections?> projections(String sessionId) async {
    final value = await rpc.call('session/projections', {
      'request': {'sessionId': sessionId},
    });
    return value == null ? null : SessionProjections.fromJson(value);
  }

  Future<List<({String sessionId, String snippet})>> searchSessions(String query) async =>
      (await searchSessionsPage(query)).items;

  /// `session/search`: the Host's ranked search over current user and
  /// assistant message text, one hit per session (best match first) with a
  /// plain-text, whitespace-normalized snippet of at most 240 code points.
  /// At most 20 hits; [hasMore] when the Host cut the list. Matching is FTS5
  /// `unicode61` tokens/phrases, so a CJK query only hits a whole run between
  /// punctuation. The index is opt-in on the Host: the stock `dsh web` profile
  /// mounts it with `openAt: never` and the call fails with `gateway/internal`
  /// ("session search is disabled ..."). An empty or >500-char query is
  /// `gateway/bad-request`.
  Future<({List<({String sessionId, String snippet})> items, bool hasMore})> searchSessionsPage(String query) async {
    final value = asMapOrEmpty(
      await rpc.call('session/search', {
        'request': {'query': query},
      }),
    );
    final items = asListOrEmpty(value['items'])
        .map((i) {
          final item = asMapOrEmpty(i);
          return (sessionId: asString(item['sessionId']) ?? '', snippet: asString(item['snippet']) ?? '');
        })
        .toList(growable: false);
    return (items: items, hasMore: value['hasMore'] == true);
  }

  // ---------------------------------------------------------------------------
  // Prompting

  /// `session/prompt`; resolves once the prompt entered the Agent inbox and
  /// returns its `requestId` (echoed as `user/message.source.rpcId`).
  /// Retrying with the same [requestId] is idempotent. Content must contain
  /// non-whitespace text or an attachment (`gateway/bad-request` otherwise).
  Future<String> prompt(
    String sessionId,
    String text, {
    List<PromptImage> images = const [],
    List<String> fileReceiptIds = const [],
    String? requestId,
    PromptMode mode = PromptMode.queue,
    String? timeZone,
  }) async {
    final id = requestId ?? uuidV4();
    // A routed subagent child takes messages through its parent.
    if (subagentRoute(sessionId) case final route?) {
      return promptSubagent(route, text, images: images, requestId: id, mode: mode, timeZone: timeZone);
    }
    await rpc.call('session/prompt', {
      'request': {
        'requestId': id,
        'sessionId': sessionId,
        'mode': mode.wire,
        'content': [
          if (text.isNotEmpty) {'type': 'text', 'text': text},
          for (final image in images) image.toJson(),
          for (final receipt in fileReceiptIds) {'type': 'file', 'receiptId': receipt},
        ],
        'clientTimeZone': ?timeZone,
      },
    });
    return id;
  }

  /// `session/cancel`: interrupts the running turn (`turn/end` with
  /// `aborted`/`user`); answers `{accepted: true}` even when idle.
  Future<void> cancel(String sessionId) async {
    if (subagentRoute(sessionId) case final route?) return interruptSubagent(route);
    await rpc.call('session/cancel', {
      'request': {'sessionId': sessionId},
    });
  }

  /// Largest file the inline fallback accepts. `fileUploads/upload` carries
  /// the bytes as base64 inside one RPC frame, so peak memory runs several
  /// times the file; the Host's streamed route has no comparable bound.
  static const _maxInlineUploadBytes = 30 * 1024 * 1024;

  /// The Host's raw-byte upload route (streamed to disk, not buffered).
  static const _fileUploadBinaryPath = '/api/session/uploadFileBinary';

  /// Set once this Host answers 404 for [_fileUploadBinaryPath]: its release
  /// predates the route, so later uploads skip a request whose whole body the
  /// Host would buffer only to answer 404.
  bool _streamedUploadMissing = false;

  /// Stages a file for a later prompt.
  ///
  /// Prefers the Host's raw-byte route (`POST /api/session/uploadFileBinary`),
  /// which streams the body to disk without a base64 copy. Hosts older than
  /// the route and carriers without HTTP fall back to `fileUploads/upload`,
  /// whose single base64 frame is bounded by [_maxInlineUploadBytes].
  Future<FileReceipt> uploadFile(String sessionId, List<int> bytes, {String? name}) async {
    final streamed = await _uploadFileBinary(sessionId, bytes, name: name);
    if (streamed != null) return streamed;
    if (bytes.length > _maxInlineUploadBytes) {
      throw const DshProtocolException(
        'Host has no streaming file upload route; a file this large cannot be staged inline',
      );
    }
    final value = asMapOrEmpty(
      await rpc.call('fileUploads/upload', {
        'agentId': sessionId,
        'request': {'data': base64Encode(bytes), 'name': ?name},
      }),
    );
    return FileReceipt(asString(value['receiptId']) ?? '', FileAttachment.fromJson(value['file']));
  }

  /// The streamed route's receipt, or null when this carrier or Host lacks it.
  Future<FileReceipt?> _uploadFileBinary(String sessionId, List<int> bytes, {String? name}) async {
    if (_streamedUploadMissing) return null;
    final carrier = this.carrier;
    if (carrier is! DshHttpCarrier) return null;
    final response = await carrier.connection.postBytes(
      _fileUploadBinaryPath,
      bytes,
      query: {'sessionId': sessionId, 'name': ?name},
      followRedirects: false,
      maxResponseBytes: 64 * 1024,
      // Uploading competes with the turn's own traffic, and a remote tunnel
      // can be slow; do not cut a large file off at the 2 min request default.
      timeout: const Duration(minutes: 10),
    );
    // A Host from before the route answers 404: use the inline fallback.
    if (response.statusCode == 404) {
      _streamedUploadMissing = true;
      return null;
    }
    if (response.statusCode != 200) {
      throw DshHttpException(
        response.statusCode,
        httpRpcStatusMessage(response.statusCode, 'session/uploadFileBinary'),
        body: response.text,
      );
    }
    final decoded = asMap(tryDecodeJson(response.text));
    if (decoded == null) throw const DshProtocolException('session/uploadFileBinary: invalid response');
    if (decoded['ok'] != true) throw DshRemoteException.fromJson(decoded['error']);
    final value = asMapOrEmpty(decoded['value']);
    final receiptId = asString(value['receiptId']);
    if (receiptId == null || receiptId.isEmpty) {
      throw const DshProtocolException('session/uploadFileBinary: no receipt');
    }
    return FileReceipt(receiptId, FileAttachment.fromJson(value['file']));
  }

  bool? _attachmentReferenceSupported;
  MuxGeneration? _attachmentReferenceGeneration;

  /// Read a durable image using its real log reference. Legacy Hosts reject the
  /// new request before dispatch; only that explicit validation failure falls back.
  Future<({ImageAttachment attachment, Uint8List bytes})> attachment(
    String sessionId,
    ImageAttachment reference,
  ) async {
    final generation = mux.generation;
    if (generation == null || !identical(generation, _attachmentReferenceGeneration)) {
      _attachmentReferenceSupported = null;
      _attachmentReferenceGeneration = generation;
    }
    final knownSupport = _attachmentReferenceSupported;
    void remember(bool supported) {
      // HTTP-only/disconnected reads have no Host-generation identity. A late
      // response from a retired connection must not seed the next generation.
      if (generation != null &&
          identical(mux.generation, generation) &&
          identical(_attachmentReferenceGeneration, generation)) {
        _attachmentReferenceSupported = supported;
      }
    }

    Future<Object?> read(bool fullReference) => rpc.call('session/attachment', {
      'request': {
        'sessionId': sessionId,
        if (fullReference) 'attachment': reference.toJson() else 'attachmentId': reference.attachmentId,
      },
    });
    Object? response;
    if (knownSupport == false) {
      response = await read(false);
    } else {
      try {
        response = await read(true);
        remember(true);
      } on DshRemoteException catch (error) {
        if (knownSupport == true ||
            !const {'gateway/arguments-invalid', 'gateway/input-invalid'}.contains(error.code)) {
          rethrow;
        }
        response = await read(false);
        remember(false);
      }
    }
    final value = asMapOrEmpty(response);
    final attachment = ImageAttachment.fromJson(value['attachment']);
    final data = asString(value['data']) ?? '';
    return (
      attachment: attachment,
      bytes: data.length > 256 * 1024 ? await _decodeLargeAttachment(data) : base64Decode(data),
    );
  }

  /// Edits/removes/steers a still-queued prompt (`session/updateQueue`).
  Future<void> updateQueue(
    String sessionId,
    String itemId, {
    String? editText,
    bool remove = false,
    bool steer = false,
  }) async {
    final Map<String, Object?> action = remove
        ? {'kind': 'remove'}
        : steer
        ? {'kind': 'steer'}
        : {
            'kind': 'edit',
            'content': [
              {'type': 'text', 'text': editText ?? ''},
            ],
          };
    await rpc.call('session/updateQueue', {
      'request': {'sessionId': sessionId, 'itemId': itemId, 'action': action},
    });
  }

  // ---------------------------------------------------------------------------
  // History and live events

  /// `session/page`: events strictly before [beforeSeq] (when given), or the
  /// tail page ending exactly at [throughSeq]. [throughSeq] is the newest seq
  /// you hold (the follow cursor); pass the oldest seq you hold as
  /// [beforeSeq] to load older history.
  Future<HistoryPage> history(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int? maxMessages,
    TurnWindow? turnWindow,
  }) async {
    final value = asMapOrEmpty(
      await rpc.call('session/page', {
        'request': {
          'address': sessionAddressOf(sessionId),
          'throughSeq': throughSeq,
          'beforeSeq': ?beforeSeq,
          'maxMessages': ?maxMessages,
          if (turnWindow != null) 'turnWindow': turnWindow.toJson(),
        },
      }),
    );
    return HistoryPage(
      asListOrEmpty(
        value['records'],
      ).map((r) => SessionLogEvent.fromJson(asMapOrEmpty(r)['event'])).toList(growable: false),
      value['hasMore'] == true,
    );
  }

  /// Live view of one session (snapshot first, then contiguous durable events,
  /// assistant-stream deltas and this session's host requests).
  /// With [WatchOptions.includeSyncEvents], local readiness events may precede
  /// the snapshot; control consumers must wait until that snapshot is applied.
  ///
  /// The stream survives socket loss: it reports [ConnectionStateEvent]s,
  /// reopens `session/follow` on the next generation and emits a resync
  /// [SessionSnapshotEvent]. Transient failures (transport, protocol, 5xx)
  /// back off, six in a row without a snapshot end it; a 401/403 waits for the
  /// next login. It ends with an error for terminal Host failures (e.g.
  /// `session/not-found`).
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) =>
      _SessionWatch(this, sessionId, options).stream;

  // ---------------------------------------------------------------------------
  // Approvals and questions

  /// Answers an `approval/request` (via `$events/result`).
  Future<void> respondApproval(ApprovalRequest request, ApprovalDecision decision) => respondHostEvent(
    request.eventId,
    decision == ApprovalDecision.pass ? {'kind': 'next'} : {'kind': 'result', 'value': decision.wire},
  );

  /// Answers a `user-questions/request` while its tool call is still open.
  Future<void> answerQuestion(UserQuestionRequest request, List<QuestionAnswer> answers) =>
      respondHostEvent(request.eventId, {
        'kind': 'result',
        'value': {'answers': answers.map((a) => a.toJson()).toList()},
      });

  /// Rejects a question request; use code `ASK_TIMED_OUT` with name
  /// `UserQuestionError` when a claimed timed wait expires locally.
  Future<void> rejectQuestion(
    UserQuestionRequest request, {
    String name = 'UserQuestionError',
    String message = 'declined',
    String? code,
  }) => respondHostEvent(request.eventId, {
    'kind': 'rejected',
    'error': {'name': name, 'message': message, 'code': ?code},
  });

  /// Claims a timed question wait (`userQuestions/attachWait`); items are
  /// `{remainingMs: n}`. Cancel the stream to release the claim.
  MuxStream claimQuestionWait(String sessionId, String callId) =>
      mux.open('userQuestions/attachWait', {'agentId': sessionId, 'callId': callId});

  /// Answers a `continued` question (from the `userQuestions` projection)
  /// after its tool call already returned; steers a reply into the agent.
  Future<bool> answerContinuedQuestion(String sessionId, String callId, List<QuestionAnswer> answers) async {
    final value = await rpc.call('userQuestions/answer', {
      'agentId': sessionId,
      'callId': callId,
      'answer': {'answers': answers.map((a) => a.toJson()).toList()},
    });
    return value == true;
  }

  /// Low-level `$events/result`: `{kind: 'result', value}`, `{kind: 'next'}`
  /// or `{kind: 'rejected', error: {name, message, code?, details?}}`.
  ///
  /// Uses the *current* generation's `clientId` (pending requests are
  /// redelivered to new generations with the same `eventId`). The Host
  /// answers ok even when the request was already settled.
  Future<void> respondHostEvent(String eventId, Map<String, Object?> outcome) async {
    for (var attempt = 0; ; attempt++) {
      final generation = await mux.ready();
      try {
        await rpc.call(r'$events/result', {'clientId': generation.clientId, 'eventId': eventId, 'outcome': outcome});
        mux.resolvePendingRequest(eventId);
        return;
      } on DshRemoteException catch (error) {
        final stale = error.message.contains('identifies no active event stream');
        if (!stale || attempt >= 2) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Models, permissions and provider keys

  /// `session/modelCatalog`: providers, models, reasoning efforts, default.
  Future<ModelCatalog> listModels() async {
    final read = tryBackgroundListRead(BackgroundListKind.models);
    if (read != null) return (await read) as ModelCatalog;
    return ModelCatalog.fromJson(await rpc.call('session/modelCatalog'));
  }

  /// Switch this session's model, retaining the selection-only API.
  Future<ModelSelection> setModel(
    String sessionId, {
    required String provider,
    required String model,
    String? reasoningEffort,
  }) async =>
      (await setModelResult(sessionId, provider: provider, model: model, reasoningEffort: reasoningEffort)).selected;

  /// `session/selectModel`; unavailable routes fail the request. A failure to
  /// save the next-session default does not undo an accepted session selection.
  /// Older hosts omit [ModelSelectionResult.defaultSave].
  Future<ModelSelectionResult> setModelResult(
    String sessionId, {
    required String provider,
    required String model,
    String? reasoningEffort,
  }) async {
    final value = asMapOrEmpty(
      await rpc.call('session/selectModel', {
        'request': {'sessionId': sessionId, 'provider': provider, 'model': model, 'reasoningEffort': ?reasoningEffort},
      }),
    );
    return ModelSelectionResult(
      selected:
          ModelSelection.fromJson(value['selected']) ??
          ModelSelection(provider: provider, model: model, reasoningEffort: reasoningEffort),
      defaultSave: ModelDefaultSave.fromJson(value['defaultSave']),
    );
  }

  /// `llm/listProviders`: registered provider routes.
  Future<List<({String id, String name})>> listProviders() async {
    final read = tryBackgroundListRead(BackgroundListKind.providers);
    if (read != null) return (await read) as List<({String id, String name})>;
    final value = asListOrEmpty(await rpc.call('llm/listProviders'));
    return value
        .map((p) {
          final map = asMapOrEmpty(p);
          return (id: asString(map['id']) ?? '', name: asString(map['name']) ?? '');
        })
        .toList(growable: false);
  }

  /// `credentials/describe` — configured/source/writable, never values.
  Future<Map<String, CredentialStatus>> describeCredentials(List<String> refs) async {
    final read = tryBackgroundListRead(BackgroundListKind.credentials, credentialRefs: refs);
    if (read != null) return (await read) as Map<String, CredentialStatus>;
    final value = asMapOrEmpty(await rpc.call('credentials/describe', {'refs': refs}));
    return value.map((key, v) => MapEntry(key, CredentialStatus.fromJson(v)));
  }

  /// Stores the DeepSeek API key in `$DSH_HOME/.credentials.yaml`
  /// (`credentials/set`). Takes effect on the next model request; no
  /// restart. Fails with `credential/rejected` when the launch environment
  /// already supplies [ref] (start `dsh web` without `DEEPSEEK_API_KEY`).
  Future<void> setProviderKey(String apiKey, {String ref = 'DEEPSEEK_API_KEY'}) async {
    _checkRef(ref);
    if (apiKey.trim().isEmpty) throw ArgumentError.value('<empty>', 'apiKey', 'must not be empty');
    await rpc.call('credentials/set', {'ref': ref, 'value': apiKey});
  }

  Future<void> clearProviderKey({String ref = 'DEEPSEEK_API_KEY'}) async {
    _checkRef(ref);
    await rpc.call('credentials/unset', {'ref': ref});
  }

  /// `permissionPresets/catalog`: selectable presets and the default.
  Future<
    ({
      List<({String value, String name, String? description})> options,
      List<({String value, String name, String? description})> defaultOptions,
      String defaultPreset,
    })
  >
  permissionPresets() async {
    final value = asMapOrEmpty(await rpc.call('permissionPresets/catalog'));
    List<({String value, String name, String? description})> parseOptions(Object? raw) => asListOrEmpty(raw)
        .map((o) {
          final map = asMapOrEmpty(o);
          return (
            value: asString(map['value']) ?? '',
            name: asString(map['name']) ?? '',
            description: asString(map['description']),
          );
        })
        .toList(growable: false);
    final options = parseOptions(value['options']);
    return (
      options: options,
      // Older catalogs omit defaultOptions. Auto is a session-only preset.
      defaultOptions: value['defaultOptions'] is List
          ? parseOptions(value['defaultOptions'])
          : options.where((option) => option.value != 'auto').toList(growable: false),
      defaultPreset: asString(value['defaultPreset']) ?? '',
    );
  }

  /// Switches a session's permission preset through the `/permission` command.
  Future<CommandResult> setPermissionPreset(String sessionId, String preset) =>
      executeCommand(sessionId, '/permission $preset');

  /// `commands/execute` (slash commands as typed in the composer).
  /// Compaction waits for model generation; its request owns the cancellation
  /// signal, so the ordinary HTTP deadline would cancel a healthy compaction.
  Future<CommandResult> executeCommand(String sessionId, String line) async {
    final compact = RegExp(r'^/compact(?:\s|$)').hasMatch(line.trim());
    final value = asMap(
      await rpc.call('commands/execute', {
        'agentId': sessionId,
        'line': line,
        'submittedAttachments': <Object?>[],
      }, compact ? const Duration(minutes: 30) : null),
    );
    final result = asMapOrEmpty(value?['result']);
    return CommandResult(asString(value?['commandId']), result['kind'] == 'success', asString(result['text']));
  }

  // ---------------------------------------------------------------------------
  // Workspaces

  Future<({Workspace workspace, bool created})> createWorkspace(String path) async {
    final value = asMapOrEmpty(
      await rpc.call('workspace/create', {
        'request': {'path': path},
      }),
    );
    return (workspace: Workspace.fromJson(value['workspace']), created: value['created'] == true);
  }

  /// `directoryPicker/list`: one directory level (omit [path] for home).
  Future<DirectoryListing> listDirectory([String? path]) async {
    final value = asMapOrEmpty(await rpc.call('directoryPicker/list', {'path': ?path}));
    return DirectoryListing(
      asString(value['path']) ?? '',
      asString(value['home']) ?? '',
      asListOrEmpty(value['entries'])
          .map((e) {
            final map = asMapOrEmpty(e);
            return (
              name: asString(map['name']) ?? '',
              path: asString(map['path']) ?? '',
              hidden: map['hidden'] == true,
            );
          })
          .toList(growable: false),
      value['truncated'] == true,
    );
  }

  /// `workspace/follow`, reopened after reconnects (each generation starts
  /// with a [WorkspaceBaseline] that replaces earlier state).
  Stream<WorkspaceUpdate> watchWorkspaces() => _resilient('workspace/follow', const {}, WorkspaceUpdate.fromJson);

  /// `session/control`, reopened after reconnects (baseline first).
  Stream<SessionControlUpdate> watchSessionControl() =>
      _resilient('session/control', const {}, (value) => value).expand((value) {
        final map = asMapOrEmpty(value);
        if (map['type'] == 'baseline') {
          final projections = asMapOrEmpty(asMap(map['value'])?['projections']);
          return [SessionControlBaseline(projections.map((id, v) => MapEntry(id, SessionProjections.fromJson(v))))];
        }
        final sessionId = asString(map['sessionId']) ?? '';
        final seq = asInt(map['seq']) ?? -1;
        // 0.2.2 batches all keys changed by one committed event. Preserve the
        // existing per-key public stream and the shared commit sequence.
        if (map['changes'] is List) {
          return asListOrEmpty(map['changes']).map((change) {
            final entry = asMapOrEmpty(change);
            return SessionControlProjection(sessionId, asString(entry['key']) ?? '', entry['val'], seq);
          });
        }
        return [SessionControlProjection(sessionId, asString(map['key']) ?? '', map['value'], seq)];
      });

  Future<void> close() async {
    await mux.close();
    await carrier.close();
  }

  // ---------------------------------------------------------------------------

  static final RegExp _refPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  static void _checkRef(String ref) {
    if (!_refPattern.hasMatch(ref)) {
      throw ArgumentError.value(ref, 'ref', 'credential refs are POSIX environment variable names');
    }
  }

  Stream<T> _resilient<T>(String endpoint, Map<String, Object?> args, T Function(Object?) parse) {
    late final StreamController<T> controller;
    var stopped = false;
    MuxStream? current;
    Future<void> run() async {
      while (!stopped) {
        try {
          await mux.ready();
        } on Object catch (error) {
          if (!stopped) controller.addError(error);
          break;
        }
        if (stopped) break;
        try {
          final stream = mux.open(endpoint, args);
          current = stream;
          await for (final item in stream.items) {
            if (stopped) break;
            controller.add(parse(item));
          }
          if (stopped) break;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        } on DshCarrierLostException {
          continue;
        } on DshClosedException {
          break;
        } on Object catch (error) {
          if (!stopped) controller.addError(error);
          break;
        }
      }
      if (!controller.isClosed) await controller.close();
    }

    controller = StreamController<T>(
      onListen: () => unawaited(run()),
      onCancel: () async {
        stopped = true;
        await current?.cancel();
      },
    );
    return controller.stream;
  }
}

class _Resync implements Exception {
  const _Resync(this.reason);
  final String reason;
}

/// Implements [DshClient.watch].
///
/// Guarantees:
/// 1. Every follow generation starts with a [SessionSnapshotEvent]. On a
///    resync its `events` cover everything after the last durable event this
///    stream delivered (gaps are filled from `session/page`), so merging by
///    `seq` never leaves holes.
/// 2. Durable [SessionLogEvent]s after a snapshot are strictly contiguous
///    (`seq == previous + 1`); duplicates are dropped, holes are repaired
///    from history before delivery.
/// 3. Assistant-stream frames are checked for revision continuity; a skipped
///    revision forces a resync (new snapshot with `activeAttempt`).
/// 4. Host requests for this session ([ApprovalRequestedEvent],
///    [UserQuestionRequestedEvent]) are forwarded, including ones already
///    pending when the stream was opened; after a reconnect they may repeat
///    with the same `eventId` (dedupe by it).
class _SessionWatch {
  _SessionWatch(this.client, this.sessionId, this.options) {
    _controller = StreamController<DshEvent>(onListen: _start, onCancel: _stop);
  }

  final DshClient client;
  final String sessionId;
  final WatchOptions options;
  late final StreamController<DshEvent> _controller;
  final Set<String> _forwarded = {};
  StreamSubscription<HostEvent>? _hostSub;
  StreamSubscription<DshConnectionState>? _stateSub;
  MuxStream? _current;
  bool _stopped = false;
  int _lastSeq = -1;
  int? _assistantRevision;
  int _failures = 0;
  int _resyncs = 0;
  final Random _random = Random();
  Completer<bool>? _wake;
  Timer? _reconcileTimer;
  SessionFollowEpoch? _epoch;
  MuxGeneration? _epochGeneration;

  Stream<DshEvent> get stream => _controller.stream;

  void _emit(DshEvent event) {
    if (event is SessionSyncEvent && !options.includeSyncEvents) return;
    if (!_stopped && !_controller.isClosed) _controller.add(event);
  }

  void _start() {
    if (options.includeHostEvents) {
      for (final pending in client.mux.pendingRequests) {
        _forwardHost(pending);
      }
      _hostSub = client.mux.hostEvents.listen(_forwardHost);
    }
    if (options.includeConnectionEvents) {
      _stateSub = client.mux.states.listen((state) {
        if (state != DshConnectionState.connected) _epoch?.retire();
        _emit(ConnectionStateEvent(state, error: client.mux.lastError));
      });
    }
    unawaited(_loop());
  }

  Future<void> _stop() async {
    _stopped = true;
    _epoch?.retire();
    if (_wake case final wake? when !wake.isCompleted) wake.complete(false);
    _reconcileTimer?.cancel();
    await _hostSub?.cancel();
    await _stateSub?.cancel();
    await _current?.cancel();
  }

  void _forwardHost(HostEvent event) {
    switch (event) {
      case HostReadyEvent():
        // Requests settled elsewhere while disconnected are not redelivered:
        // once redeliveries had time to arrive, retract the leftovers.
        final stale = Set<String>.of(_forwarded);
        _reconcileTimer?.cancel();
        _reconcileTimer = Timer(options.hostRequestGrace, () {
          final pending = <String>{};
          for (final request in client.mux.pendingRequests) {
            switch (request) {
              case ApprovalRequestedEvent(:final request):
                pending.add(request.eventId);
              case UserQuestionRequestedEvent(:final request):
                pending.add(request.eventId);
              case UnknownHostEvent(:final eventId?):
                pending.add(eventId);
              default:
                break;
            }
          }
          for (final id in stale) {
            if (!pending.contains(id) && _forwarded.remove(id)) _emit(HostRequestCancelledEvent(id));
          }
        });
      case ApprovalRequestedEvent(:final request) when request.sessionId == sessionId:
        _forwarded.add(request.eventId);
        _emit(event);
      case UserQuestionRequestedEvent(:final request) when request.sessionId == sessionId:
        _forwarded.add(request.eventId);
        _emit(event);
      case UnknownHostEvent(:final eventId?, :final agentId) when agentId == sessionId:
        _forwarded.add(eventId);
        _emit(event);
      case HostRequestCancelledEvent(:final eventId) when _forwarded.remove(eventId):
        _emit(event);
      case SessionStatusEvent(sessionId: final id) when id == sessionId:
        _emit(event);
      case SessionErrorEvent(sessionId: final id) when id == sessionId:
        _emit(event);
      case SessionRemovedEvent(sessionId: final id) when id == sessionId:
        _emit(event);
      default:
        break;
    }
  }

  Map<String, Object?> _followRequest() => {
    'address': client.sessionAddressOf(sessionId),
    if (options.assistantStream) 'assistantStream': true,
    if (options.maxMessages != null) 'maxMessages': options.maxMessages,
    if (options.turnWindow != null) 'turnWindow': options.turnWindow!.toJson(),
  };

  /// Sleeps [delay]; false when the watch stopped meanwhile.
  Future<bool> _sleep(Duration delay) async {
    final wake = _wake = Completer<bool>();
    final timer = Timer(delay, () {
      if (!wake.isCompleted) wake.complete(true);
    });
    final awake = await wake.future;
    timer.cancel();
    return awake && !_stopped;
  }

  /// Same jitter as the mux's own reconnects.
  Future<bool> _backoff(int attempt) {
    final caps = client.mux.options.retryCaps;
    return _sleep(caps[min(attempt, caps.length - 1)] * (0.5 + _random.nextDouble() * 0.5));
  }

  /// Waits for the next ready generation (a new login); false once the client
  /// closes or the watch stops.
  Future<bool> _nextGeneration() async {
    // History may reject after a successor's non-replay ready event was sent.
    final current = client.mux.generation;
    if (current != null && !identical(current, _epochGeneration)) return !_stopped;
    final wake = _wake = Completer<bool>();
    void done(bool ready) {
      if (!wake.isCompleted) wake.complete(ready);
    }

    final sub = client.mux.generations.listen((_) => done(true), onDone: () => done(false));
    final ready = await wake.future;
    await sub.cancel();
    return ready && !_stopped;
  }

  /// Whether to reopen after [error]: refused credentials wait for a new
  /// login, transient failures back off, anything else ends the watch.
  Future<bool> _recover(Object error) async {
    if (_stopped) return false;
    if (error is DshCarrierRefusedException ||
        error is DshHttpException && (error.statusCode == 401 || error.statusCode == 403)) {
      return _nextGeneration();
    }
    final transient =
        error is DshTransportException ||
        error is DshProtocolException ||
        error is DshHttpException && (error.statusCode >= 500 || error.statusCode == 408 || error.statusCode == 429) ||
        error is DshRemoteException && (error.code == 'gateway/internal' || error.details['retryable'] == true);
    if (!transient || ++_failures >= 6) return false;
    return _backoff(_failures - 1);
  }

  Future<void> _loop() async {
    while (!_stopped) {
      _epoch?.retire();
      var epoch = _epoch = SessionFollowEpoch();
      _emit(SessionSyncEvent(epoch));
      try {
        _epochGeneration = await client.mux.ready();
        // Waiting for ready may have included connection-state changes.
        // The actual follow attempt gets ownership only after that wait.
        epoch.retire();
        epoch = _epoch = SessionFollowEpoch(generation: _epochGeneration);
        _emit(SessionSyncEvent(epoch));
      } on Object catch (error) {
        epoch.retire();
        if (await _recover(error)) continue;
        if (!_stopped) _controller.addError(error);
        break;
      }
      if (_stopped) break;
      MuxStream? stream;
      try {
        stream = client.mux.open('session/follow', {'request': _followRequest()});
        _current = stream;
        var opened = false;
        await for (final item in stream.items) {
          if (_stopped) break;
          if (!opened) {
            final first = parseFollowFrame(sessionId, item, isResync: _lastSeq >= 0);
            if (first is! SessionSnapshotEvent) throw const _Resync('follow opened without snapshot');
            await _onSnapshot(first);
            opened = true;
            if (options.activate) {
              unawaited(
                client.activateSessionForInteraction(
                  sessionId,
                  epoch: epoch,
                  allowed: () => !_stopped && (options.activationAllowed?.call() ?? true),
                  onActivationChecked: options.onActivationChecked,
                ),
              );
            }
          } else {
            await _onFrame(item);
            _resyncs = 0;
          }
        }
        if (_stopped) break;
        // The Host ended the follow without an error: reopen shortly.
        epoch.retire();
        _emit(SessionSyncEvent(epoch));
        if (!await _sleep(const Duration(milliseconds: 500))) break;
      } on DshCarrierLostException {
        epoch.retire();
        continue;
      } on DshClosedException {
        epoch.retire();
        break;
      } on _Resync catch (error) {
        if (!epoch.isCurrent || !identical(epoch.generation, client.mux.generation)) continue;
        epoch.retire();
        _emit(SessionSyncEvent(epoch));
        await stream?.cancel();
        if (_stopped) break;
        if (!identical(epoch.generation, client.mux.generation)) continue;
        // Back-to-back resyncs back off; six without a clean frame end the watch.
        if (++_resyncs >= 6) {
          _controller.addError(DshProtocolException(error.reason));
          break;
        }
        if (_resyncs > 1 && !await _backoff(_resyncs - 2)) break;
      } on Object catch (error) {
        // Preserve a closed client's terminal failure without recovery.
        if (client.mux.state == DshConnectionState.closed) {
          epoch.retire();
          if (!_stopped) _controller.addError(error);
          break;
        }
        if (!epoch.isCurrent || !identical(epoch.generation, client.mux.generation)) continue;
        epoch.retire();
        _emit(SessionSyncEvent(epoch));
        await stream?.cancel();
        if (_stopped) break;
        if (!identical(epoch.generation, client.mux.generation)) continue;
        // A subagent child opened without its parent route: route it, retry.
        if (await client.adoptSubagentRoute(sessionId, error)) continue;
        if (!identical(epoch.generation, client.mux.generation)) continue;
        if (await _recover(error)) continue;
        if (!identical(epoch.generation, client.mux.generation)) continue;
        if (!_stopped) _controller.addError(error);
        break;
      }
    }
    _epoch?.retire();
    _reconcileTimer?.cancel();
    await _hostSub?.cancel();
    await _stateSub?.cancel();
    if (!_controller.isClosed) await _controller.close();
  }

  Future<void> _onSnapshot(SessionSnapshotEvent snapshot) async {
    final epoch = _epoch!;
    _assistantRevision = snapshot.assistantRevision;
    var events = snapshot.events;
    if (_lastSeq >= 0 && snapshot.cursor > _lastSeq) {
      final firstSeq = events.isEmpty ? snapshot.cursor + 1 : events.first.seq;
      if (firstSeq > _lastSeq + 1) {
        final filled = await _fill(from: _lastSeq + 1, before: firstSeq, through: snapshot.cursor);
        _checkHistoryOwner(epoch);
        if (options.includeSyncEvents) {
          var expected = _lastSeq + 1;
          for (final event in filled) {
            if (event.seq != expected++) throw const _Resync('incomplete snapshot history repair');
          }
          if (expected != firstSeq) throw const _Resync('incomplete snapshot history repair');
        }
        events = [...filled, ...events];
      }
    }
    if (_stopped || !epoch.isCurrent || !identical(_epochGeneration, client.mux.generation)) {
      throw const DshCarrierLostException('follow snapshot belongs to a retired generation');
    }
    _lastSeq = snapshot.cursor;
    _failures = 0;
    _emit(snapshot.withEvents(events, followEpoch: epoch));
  }

  Future<void> _onFrame(Object? item) async {
    final event = parseFollowFrame(sessionId, item);
    switch (event) {
      case SessionLogEvent():
        if (event.seq <= _lastSeq) return;
        if (event.seq > _lastSeq + 1) {
          // Revalidate the complete inbox/running baseline, not only the
          // missing log records. The next snapshot repairs durable history.
          if (options.includeSyncEvents) throw _Resync('resync after gap before seq ${event.seq}');
          final epoch = _epoch!;
          final filled = await _fill(from: _lastSeq + 1, before: event.seq, through: event.seq - 1);
          _checkHistoryOwner(epoch);
          if (filled.isEmpty || filled.first.seq != _lastSeq + 1 || filled.last.seq != event.seq - 1) {
            throw _Resync('unrepairable gap before seq ${event.seq}');
          }
          filled.forEach(_emit);
        }
        _lastSeq = event.seq;
        _emit(event);
      case AssistantStreamEvent():
        final expected = (_assistantRevision ?? 0) + 1;
        if (event.revision != expected) {
          throw _Resync('assistant stream skipped revision $expected');
        }
        _assistantRevision = event.revision;
        _emit(event);
      case SessionSnapshotEvent():
        throw const _Resync('unexpected second snapshot');
      default:
        _emit(event);
    }
  }

  void _checkHistoryOwner(SessionFollowEpoch epoch) {
    if (_stopped || client.mux.state == DshConnectionState.closed) throw const DshClosedException();
    if (!epoch.isCurrent || !identical(epoch.generation, client.mux.generation)) {
      throw const DshCarrierLostException('history repair belongs to a retired follow');
    }
  }

  Future<List<SessionLogEvent>> _fill({required int from, required int before, required int through}) async {
    final epoch = _epoch!;
    final out = <SessionLogEvent>[];
    var beforeSeq = before;
    while (beforeSeq > from) {
      _checkHistoryOwner(epoch);
      final HistoryPage page;
      try {
        page = await client.history(sessionId, throughSeq: through, beforeSeq: beforeSeq, maxMessages: 500);
      } catch (_) {
        // Closing the client keeps the original terminal error contract;
        // only a live successor must be protected from stale recovery.
        if (!_stopped && client.mux.state == DshConnectionState.closed) rethrow;
        _checkHistoryOwner(epoch);
        rethrow;
      }
      _checkHistoryOwner(epoch);
      final usable = page.events.where((e) => e.seq >= from && e.seq < beforeSeq).toList();
      if (usable.isEmpty) break;
      // Reverse each page now, then the whole result, without shifting the accumulated prefix.
      out.addAll(usable.reversed);
      beforeSeq = usable.first.seq;
      if (!page.hasMore) break;
    }
    return out.reversed.toList();
  }
}

Future<Uint8List> _decodeLargeAttachment(String data) => Isolate.run(() => base64Decode(data));
