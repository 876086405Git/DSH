// SPDX-FileCopyrightText: 2026 DSH Remote contributors
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
// dsh_client carrier over an authenticated ds-harness-remote connection: maps
// DshRpc / DshMux onto the Typert Remote tunnel RPCs (`harness.remote.call`,
// `harness.remote.stream.open|close`, `harness.remote.transfer.*`) and events
// (`harness.remote.frame`, `harness.remote.stream.closed`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';

import '../channel/rpc_client.dart';
import '../state.dart';
import '../transport/transport.dart';
import '../util/bytes.dart';

/// Fixed endpoint allow-list of the Host plugin (ds-harness-remote 0.5.17 to 0.6.0,
/// `HARNESS_REMOTE_ALLOWLIST` + terminal endpoints). Everything else is
/// refused by the Host; this client refuses it locally first.
const Set<String> harnessRemoteAllowlist = {
  r'$events',
  r'$events/result',
  'agentPresets/list',
  'agentPresets/read',
  'agentPresets/select',
  'commands/execute',
  'commands/list',
  'credentials/describe',
  'credentials/set',
  'credentials/unset',
  'directoryPicker/list',
  'fileReferences/list',
  'goals/clear',
  'goals/complete',
  'goals/create',
  'goals/edit',
  'goals/pause',
  'goals/resume',
  'job/list',
  'job/follow',
  'llm/discoverModels',
  'llm/listConfigurableProviders',
  'llm/listProviders',
  'messageFeedback/delete',
  'messageFeedback/list',
  'messageFeedback/put',
  'pluginInventory/list',
  'pluginManager/listBundles',
  'pluginManager/listPlugins',
  'pluginManager/setBundleEnabled',
  'pluginManager/setPluginEnabled',
  'permissionPresets/catalog',
  'schedule/list',
  'schedule/catalog',
  'schedule/history',
  'schedule/update',
  'schedule/delete',
  'session/attachment',
  'session/cancel',
  'session/canOpenWorkspacePath',
  'session/control',
  'session/create',
  'session/follow',
  'session/fork',
  'session/list',
  'session/modelCatalog',
  'session/page',
  'session/prompt',
  'remoteAccess/follow',
  'session/projections',
  'session/initializeDefaultModel',
  'session/workspacePathApplications',
  'session/rename',
  'session/search',
  'session/selectModel',
  'session/updateQueue',
  'sessionReferenceResolver/candidates',
  'settings/describe',
  'settings/mutate',
  'settings/replace',
  'settings/update',
  'skills/list',
  'subagents/interruptByParent',
  'subagents/list',
  'subagents/prompt',
  'userQuestions/answer',
  'userQuestions/attachWait',
  'claudeCodeMods/watchBand',
  'claudeCodeMods/pressBand',
  'workspaceFiles/list',
  'workspaceFiles/stat',
  'workspaceFiles/read',
  'workspaceFiles/readBytes',
  'workspaceFiles/readAll',
  'workspaceFiles/readRelated',
  'workspaceFiles/changes',
  'officeToPdf/render',
  'officeToPdf/generation',
  'workspace/archiveSession',
  'workspace/create',
  'workspace/delete',
  'workspace/follow',
  'workspace/insertBefore',
  'workspace/insertSessionBefore',
  'workspace/rename',
  'workspace/unarchiveSession',
  'workspace/initializeDefault',
  'workspace/pinSession',
  'workspace/unpinSession',
  // Terminal endpoints (Host-configurable, `TERMINAL_DISABLED` when off).
  'terminal/environment',
  'terminal/shells',
  'terminal/list',
  'terminal/create',
  'terminal/write',
  'terminal/resize',
  'terminal/rename',
  'terminal/close',
  'terminal/follow',
  'terminal/retain',
};

/// Endpoints whose binary results arrive as a base64 `data` string over the
/// tunnel (locally they are multipart, which the HTTP carrier rejects).
const Set<String> base64ResultEndpoints = {'workspaceFiles/readBytes', 'officeToPdf/render'};

/// Requests above this go through `harness.remote.transfer.*`.
const int directRemoteCallBytes = 2 * 1024 * 1024;

/// Decoded bytes per transfer chunk.
const int remoteTransferChunkBytes = 512 * 1024;

/// Largest transferred request or response.
const int maxRemoteTransferBytes = 288 * 1024 * 1024;

/// One live, authenticated connection to a Host, after
/// `harness.transport.describe`.
class RemoteHostSession {
  RemoteHostSession({
    required this.rpc,
    required this.capabilities,
    this.workspaceTypes,
    this.harnessVersion,
    this.transport = 'relay',
    this.networkDiagnostics,
    this.inspectNetwork,
  });

  final RemoteRpcClient rpc;

  /// `harness.transport.describe` capabilities (`harness.remote.v3`,
  /// `harness.remote.transfer.v1`, `remote.history.compact.v1`,
  /// `harness.terminal.v1`, ...).
  final List<String> capabilities;
  final Object? workspaceTypes;

  /// Fresh authorized descriptor for this connection, never a cached listing.
  final String? harnessVersion;
  final String transport;

  /// Initial payload-free snapshot; [inspectNetwork] refreshes native stats
  /// on demand without sending a health probe or starting a polling timer.
  final RemoteNetworkDiagnostics? networkDiagnostics;
  final Future<RemoteNetworkDiagnostics> Function()? inspectNetwork;

  bool get supportsTransfer => capabilities.contains('harness.remote.transfer.v1');
  bool get supportsStreamTransfer => capabilities.contains('harness.remote.stream.transfer.v1');

  bool get isClosed => rpc.isClosed;

  Future<void> close() => rpc.close();
}

/// Opens a [RemoteHostSession]; throws [RemoteConnectException].
/// [previous] is the failure of the last attempt (e.g. `TOKEN_EXPIRED`
/// asks the opener to refresh the access token first).
typedef RemoteSessionOpener = Future<RemoteHostSession> Function(RemoteFailure? previous);

/// [DshCarrier] over ds-harness-remote. Unary calls become
/// `harness.remote.call`; each [DshMux] link is one secure connection whose
/// logical streams map to `harness.remote.stream.*`. A lost data plane or
/// refused recovery is reported as link loss, so [DshMux] reconnects (new
/// connection, new `$events` generation, streams reopened) with its backoff.
/// Lease-backed Control recovery keeps this link and its existing streams.
///
/// Differences from the local carrier that callers see:
/// * only [harnessRemoteAllowlist] endpoints (others: `METHOD_NOT_ALLOWED`;
///   receipt staging via `fileUploads/upload` remains unavailable);
/// * workspace files use the separate [WorkspaceUploadCarrier] protocol;
/// * no uplink items on streams ([supportsUplink] is false);
/// * requests above 2 MiB use chunked transfers (Host must declare
///   `harness.remote.transfer.v1`), single messages are capped at 4 MiB;
/// * Host / tunnel refusals (`METHOD_NOT_ALLOWED`, `RPC_TIMEOUT`,
///   `RATE_LIMITED`, ...) surface as `{ok: false}` [DshRemoteException]s.
class RemoteTunnelCarrier extends DshCarrier implements WorkspaceUploadCarrier {
  RemoteTunnelCarrier({
    required this.hostId,
    required RemoteSessionOpener open,
    this.callTimeout = const Duration(seconds: 65),
    this.streamControlTimeout = const Duration(seconds: 15),
    this.healthInterval = const Duration(seconds: 25),
    this.healthTimeout = const Duration(seconds: 10),
    DshTracer? tracer,
  }) : _open = open,
       _tracer = tracer;

  final String hostId;
  final RemoteSessionOpener _open;

  /// Unary deadline (the Host caps one call at 60 s).
  final Duration callTimeout;
  final Duration streamControlTimeout;

  /// `harness.transport.describe` health probe cadence and deadline. The
  /// periodic probe is skipped while the Host keeps sending: a busy channel is
  /// a live one, and a probe queued behind a large transfer on a slow link
  /// could time out and tear down a healthy connection.
  final Duration healthInterval;
  final Duration healthTimeout;
  final DshTracer? _tracer;

  RemoteHostSession? _session;
  Future<RemoteHostSession>? _opening;
  Timer? _health;
  Future<bool>? _probing;
  bool _closed = false;
  RemoteFailure? _lastFailure;
  final StreamController<RemoteFailure> _failures = StreamController.broadcast();
  final StreamController<RemoteHostSession> _sessions = StreamController.broadcast();

  @override
  String get kind => 'remote-relay';

  @override
  String? get hostVersion => _session?.isClosed == false ? _session?.harnessVersion : null;

  @override
  DshTracer? get tracer => _tracer;

  @override
  bool get supportsUplink => false;

  @override
  bool allowsEndpoint(String endpoint) => harnessRemoteAllowlist.contains(endpoint);

  @override
  bool get supportsWorkspaceUpload =>
      !_closed && _session?.isClosed == false && _session!.capabilities.contains('workspace.upload.v1');

  // Absolute protocol bound only. The Host authoritatively checks its current
  // path and supported limit; do not infer either from a claimed P2P session.
  @override
  int get maxWorkspaceUploadBytes => 1024 * 1024 * 1024;

  /// The live connection, if any.
  RemoteHostSession? get session => _session;

  /// Capabilities of the live (or last) Host connection.
  List<String> get capabilities => _lastCapabilities;

  @override
  Set<String>? get peerCapabilities => _lastCapabilities.isEmpty ? null : _lastCapabilities.toSet();
  List<String> _lastCapabilities = const [];

  RemoteFailure? get lastFailure => _lastFailure;

  /// Every failed attempt or dropped connection.
  Stream<RemoteFailure> get failures => _failures.stream;

  /// Every newly established connection.
  Stream<RemoteHostSession> get sessions => _sessions.stream;

  bool get isClosed => _closed;

  // ---------------------------------------------------------------------------
  // Connection state (derived from the attached mux + carrier failures)

  final StreamController<RemoteConnectionState> _states = StreamController.broadcast();
  RemoteConnectionState? _state;
  StreamSubscription<DshConnectionState>? _muxStates;
  StreamSubscription<RemoteFailure>? _failureStates;

  /// connecting / connected / reconnecting / failed / closed, with the
  /// failure behind each non-connected state. Requires [attachMux].
  Stream<RemoteConnectionState> get states => _states.stream;

  RemoteConnectionState? get state => _state;

  DshMux? _mux;

  /// Derives [states] from [mux] (the [DshClient.mux] using this carrier).
  void attachMux(DshMux mux) {
    _mux = mux;
    _muxStates?.cancel();
    _failureStates?.cancel();
    void update([Object? _]) => _deriveState(mux);
    _muxStates = mux.states.listen(update);
    _failureStates = failures.listen(update);
    update();
  }

  void _deriveState(DshMux mux) {
    final phase = switch (mux.state) {
      DshConnectionState.idle => null,
      DshConnectionState.connecting => RemoteConnectionPhase.connecting,
      DshConnectionState.connected => RemoteConnectionPhase.connected,
      DshConnectionState.reconnecting => RemoteConnectionPhase.reconnecting,
      DshConnectionState.unauthorized => RemoteConnectionPhase.failed,
      DshConnectionState.closed => RemoteConnectionPhase.closed,
    };
    if (phase == null) return;
    RemoteFailure? failure;
    if (phase != RemoteConnectionPhase.connected && phase != RemoteConnectionPhase.closed) {
      failure = _lastFailure ?? _failureFromError(mux.lastError);
    }
    final previous = _state;
    if (previous != null && previous.phase == phase && previous.failure?.code == failure?.code) {
      return;
    }
    final next = RemoteConnectionState(
      phase,
      hostId: hostId,
      failure: failure,
      transport: phase == RemoteConnectionPhase.connected ? (_session?.transport ?? 'relay') : null,
      at: DateTime.now(),
    );
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  static RemoteFailure? _failureFromError(Object? error) => switch (error) {
    null => null,
    DshCarrierRefusedException(:final code, :final message) => RemoteFailure(code, message, retryable: false),
    DshTransportException(:final cause) when cause is RemoteFailure => cause,
    DshException(:final message) => RemoteFailure('CONNECTION_FAILED', message, retryable: true),
    _ => RemoteFailure('CONNECTION_FAILED', '$error', retryable: true),
  };

  // ---------------------------------------------------------------------------
  // Session management

  Future<RemoteHostSession> _ensureSession() {
    if (_closed) return Future.error(const DshClosedException('remote carrier closed'));
    final current = _session;
    if (current != null && !current.isClosed) return Future.value(current);
    return _opening ??= _openSession().whenComplete(() => _opening = null);
  }

  Future<RemoteHostSession> _openSession() async {
    // A terminal failure (identity mismatch, replaced by another client,
    // signed out, ...) sticks until [reconnect]: never fight over the
    // connection or retry into a refused identity.
    final sticky = _lastFailure;
    if (sticky != null && !sticky.retryable) throw _toDshException(sticky);
    final RemoteHostSession session;
    try {
      session = await _open(_lastFailure);
    } on RemoteConnectException catch (error) {
      _recordFailure(error.failure);
      throw _toDshException(error.failure);
    }
    if (_closed) {
      unawaited(session.close());
      throw const DshClosedException('remote carrier closed');
    }
    _session = session;
    _lastFailure = null;
    _lastCapabilities = session.capabilities;
    unawaited(
      session.rpc.done.then((reason) {
        if (_session == session) {
          _session = null;
          _health?.cancel();
          if (reason.code != 'CLIENT_CLOSED') {
            _recordFailure(RemoteFailure(reason.code, reason.message, retryable: reason.retryable));
          }
        }
      }),
    );
    _startHealth(session);
    if (!_sessions.isClosed) _sessions.add(session);
    return session;
  }

  void _recordFailure(RemoteFailure failure) {
    _lastFailure = failure;
    if (!_failures.isClosed) _failures.add(failure);
  }

  void _startHealth(RemoteHostSession session) {
    _health?.cancel();
    _health = Timer.periodic(healthInterval, (_) {
      if (_session == session && !session.isClosed && session.rpc.sinceInbound >= healthInterval) unawaited(probe());
    });
  }

  /// Checks an established tunnel now; simultaneous checks share one RPC.
  Future<bool> probe({Duration? timeout}) {
    final session = _session;
    if (session == null) return Future.value(true);
    session.rpc.channel.checkControlHealth();
    return _probing ??= _check(session, timeout ?? healthTimeout).whenComplete(() => _probing = null);
  }

  Future<bool> _check(RemoteHostSession session, Duration timeout) async {
    try {
      await session.rpc.call('harness.transport.describe', const <String, Object?>{}, timeout: timeout);
    } on RemoteRpcException catch (error) {
      if (!error.isLocal || _session != session) return true; // a Host answer is a healthy channel
      _recordFailure(RemoteFailure('CONNECTION_FAILED', 'Health check failed: ${error.message}', retryable: true));
      await session.close();
      return false;
    }
    return true;
  }

  /// Clears a terminal failure and reconnects now (after the user fixed
  /// the cause: signed in again, re-trusted the Host, or wants this device
  /// to take the connection back).
  void reconnect() {
    _lastFailure = null;
    final mux = _mux;
    if (mux != null) {
      mux.reconnect();
    } else {
      final session = _session;
      if (session != null) unawaited(_closeSession(session));
    }
  }

  Future<void> _closeSession(RemoteHostSession session) async {
    if (_session == session) {
      _session = null;
      _health?.cancel();
    }
    await session.close();
  }

  static DshException _toDshException(RemoteFailure failure) => failure.retryable
      ? DshTransportException('${failure.code}: ${failure.message}', failure)
      : DshCarrierRefusedException(failure.code, failure.message);

  // ---------------------------------------------------------------------------
  // Unary calls

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (!allowsEndpoint(endpoint)) {
      return RpcError(
        DshRemoteException('METHOD_NOT_ALLOWED', 'The endpoint $endpoint is not available over ds-harness-remote.', {
          'endpoint': endpoint,
        }),
      );
    }
    final session = await _ensureSession();
    final request = <String, Object?>{
      'endpoint': endpoint,
      'payload': {'args': args},
    };
    _tracer?.call(DshTraceEntry('out', 'rpc', {'endpoint': endpoint, 'args': args}));
    final encoded = utf8.encode(jsonEncode(request));
    Object? response;
    try {
      if (encoded.length > directRemoteCallBytes) {
        response = await _callTransferred(session, endpoint, encoded, timeout);
      } else {
        try {
          response = await session.rpc.call('harness.remote.call', request, timeout: timeout ?? callTimeout);
        } on RemoteRpcException catch (error) {
          // The Host checks response size after executing the request. A
          // transfer retry would execute it again, not retrieve its result.
          if (error.isLocal ||
              error.code != 'RESPONSE_TOO_LARGE' ||
              endpoint == 'commands/execute' ||
              endpoint == 'settings/mutate' ||
              endpoint == 'settings/update' ||
              endpoint == 'settings/replace') {
            rethrow;
          }
          response = await _callTransferred(session, endpoint, encoded, timeout);
        }
      }
    } on RemoteRpcException catch (error) {
      final result = _foldRpcFailure(endpoint, error);
      _tracer?.call(DshTraceEntry('in', 'rpc', {'endpoint': endpoint, 'error': error.code}));
      return result;
    }
    final result = _parseResult(endpoint, response);
    _tracer?.call(DshTraceEntry('in', 'rpc', {'endpoint': endpoint, 'body': response}));
    return result;
  }

  /// Host refusals become `{ok: false}`; local deadline/loss become
  /// [DshTransportException] (the call's outcome is unknown: do not blindly
  /// retry mutations).
  RpcResult _foldRpcFailure(String endpoint, RemoteRpcException error) {
    if (error.isLocal && error.code != 'FRAME_TOO_LARGE' && error.code != 'RATE_LIMITED') {
      throw DshTransportException(
        error.code == 'RPC_TIMEOUT'
            ? '$endpoint timed out over the remote tunnel'
            : 'remote connection lost during $endpoint: ${error.message}',
        error,
      );
    }
    return RpcError(
      DshRemoteException(error.code, error.message, {
        ...asMapOrEmpty(error.details),
        'remote': true,
        if (error.retryable) 'retryable': true,
      }),
    );
  }

  RpcResult _parseResult(String endpoint, Object? response) {
    final map = asMap(response);
    if (map == null) throw DshProtocolException('$endpoint: invalid remote Gateway result');
    if (map['ok'] == true) return RpcOk(map['value']);
    final error = asMap(map['error']);
    if (map['ok'] == false && error != null && error['code'] is String && error['message'] is String) {
      return RpcError(DshRemoteException.fromJson(error));
    }
    throw DshProtocolException('$endpoint: invalid remote Gateway failure');
  }

  Future<Object?> _callTransferred(
    RemoteHostSession session,
    String endpoint,
    Uint8List encoded,
    Duration? timeout,
  ) async {
    if (!session.supportsTransfer) {
      throw RemoteRpcException(
        'FRAME_TOO_LARGE',
        '$endpoint needs a chunked transfer, which this Host does not support.',
        isLocal: true,
      );
    }
    if (encoded.length > maxRemoteTransferBytes) {
      throw const RemoteRpcException(
        'FRAME_TOO_LARGE',
        'The request exceeds the 288 MiB transfer limit.',
        isLocal: true,
      );
    }
    final rpc = session.rpc;
    final perCall = timeout ?? callTimeout;
    final transferId = uuidV7();
    final totalChunks = (encoded.length + remoteTransferChunkBytes - 1) ~/ remoteTransferChunkBytes;
    try {
      await rpc.call('harness.remote.transfer.open', {
        'transferId': transferId,
        'totalBytes': encoded.length,
        'totalChunks': totalChunks,
      }, timeout: perCall);
      for (var index = 0; index < totalChunks; index++) {
        final start = index * remoteTransferChunkBytes;
        final end = start + remoteTransferChunkBytes < encoded.length
            ? start + remoteTransferChunkBytes
            : encoded.length;
        await rpc.call('harness.remote.transfer.chunk', {
          'transferId': transferId,
          'index': index,
          'data': base64Encode(Uint8List.sublistView(encoded, start, end)),
        }, timeout: perCall);
      }
      final committed = asMapOrEmpty(
        await rpc.call('harness.remote.transfer.commit', {'transferId': transferId}, timeout: perCall),
      );
      if (committed['kind'] == 'inline') return committed['response'];
      final totalBytes = asInt(committed['totalBytes']);
      final responseChunks = asInt(committed['totalChunks']);
      if (committed['kind'] != 'chunked' ||
          committed['transferId'] != transferId ||
          totalBytes == null ||
          totalBytes <= 0 ||
          totalBytes > maxRemoteTransferBytes ||
          responseChunks != (totalBytes + remoteTransferChunkBytes - 1) ~/ remoteTransferChunkBytes) {
        throw DshProtocolException('$endpoint: invalid remote transfer descriptor');
      }
      final out = BytesBuilder(copy: false);
      for (var index = 0; index < responseChunks!; index++) {
        final chunk = asMapOrEmpty(
          await rpc.call('harness.remote.transfer.read', {'transferId': transferId, 'index': index}, timeout: perCall),
        );
        final data = asString(chunk['data']);
        if (chunk['transferId'] != transferId || chunk['index'] != index || data == null) {
          throw DshProtocolException('$endpoint: out-of-order remote transfer chunk');
        }
        final Uint8List bytes;
        try {
          bytes = base64Decode(data);
        } on FormatException {
          throw DshProtocolException('$endpoint: malformed remote transfer chunk');
        }
        final remaining = totalBytes - index * remoteTransferChunkBytes;
        final expected = remaining < remoteTransferChunkBytes ? remaining : remoteTransferChunkBytes;
        if (bytes.length != expected || base64Encode(bytes) != data) {
          throw DshProtocolException('$endpoint: non-canonical remote transfer chunk');
        }
        out.add(bytes);
      }
      final text = utf8.decode(out.takeBytes());
      final decoded = tryDecodeJson(text);
      if (decoded == null) throw DshProtocolException('$endpoint: remote transfer is not JSON');
      return decoded;
    } finally {
      // An open timeout can follow allocation on the Host. Closing a missing
      // UUID is harmless; keep cleanup on this request's original connection.
      unawaited(
        rpc
            .call('harness.remote.transfer.close', {'transferId': transferId}, timeout: const Duration(seconds: 5))
            .then((_) {}, onError: (Object _) {}),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Workspace files (independent top-level RPCs, not Gateway endpoints).
  // Wire contract: plugin 0.6.2, ds-harness-remote commit 479b943.

  @override
  Future<WorkspaceUploadedFile> uploadWorkspaceFile(String sessionId, List<int> bytes, {required String name}) async {
    final session = _session;
    if (!supportsWorkspaceUpload || session == null) {
      throw const DshRemoteException(
        'WORKSPACE_UPLOAD_UNSUPPORTED',
        'The live Host connection does not support workspace uploads.',
      );
    }
    if (sessionId.isEmpty || sessionId.length > 512) {
      throw const DshRemoteException('INVALID_MESSAGE', 'Invalid workspace upload session.');
    }
    if (!_safeWorkspaceUploadName(name)) {
      throw const DshRemoteException('UPLOAD_INVALID_NAME', 'Invalid workspace upload file name.');
    }
    final totalBytes = bytes.length;
    if (totalBytes > maxWorkspaceUploadBytes) {
      throw const DshRemoteException(
        'WORKSPACE_UPLOAD_TOO_LARGE',
        'Workspace uploads exceed the 1 GiB protocol limit.',
      );
    }
    final uploadId = uuidV7();
    final scope = <String, Object?>{'sessionId': sessionId, 'uploadId': uploadId};
    var committed = false;
    try {
      final opened = asMap(
        await _workspaceUploadCall(session, 'workspace.upload.open', {
          ...scope,
          'name': name,
          'totalBytes': totalBytes,
        }),
      );
      final chunkBytes = opened?['chunkBytes'];
      if (opened?['uploadId'] != uploadId || chunkBytes is! int || chunkBytes < 1 || chunkBytes > 64 * 1024) {
        throw const DshRemoteException('INVALID_MESSAGE', 'Invalid workspace upload open acknowledgement.');
      }
      for (var offset = 0; offset < totalBytes;) {
        final end = offset + chunkBytes < totalBytes ? offset + chunkBytes : totalBytes;
        final chunk = bytes.sublist(offset, end);
        if (chunk.any((byte) => byte < 0 || byte > 255)) {
          throw const DshRemoteException('INVALID_MESSAGE', 'Invalid workspace upload bytes.');
        }
        final ack = asMap(
          await _workspaceUploadCall(session, 'workspace.upload.chunk', {
            ...scope,
            'offset': offset,
            'data': base64Encode(chunk),
          }),
        );
        if (ack?['uploadId'] != uploadId || ack?['receivedBytes'] != end || ack?['receivedBytes'] is! int) {
          throw const DshRemoteException('INVALID_MESSAGE', 'Invalid workspace upload chunk acknowledgement.');
        }
        offset = end;
      }
      final result = asMap(await _workspaceUploadCall(session, 'workspace.upload.commit', scope));
      final finalName = result?['name'];
      if (finalName is! String ||
          // The Host may append the longest collision suffix, ' (9999)'.
          !_safeWorkspaceUploadName(finalName, maxBytes: 227) ||
          result?['path'] != './$finalName' ||
          result?['bytes'] != totalBytes ||
          result?['bytes'] is! int) {
        throw const DshRemoteException('INVALID_MESSAGE', 'Invalid workspace upload commit result.');
      }
      committed = true;
      return WorkspaceUploadedFile(name: finalName, path: './$finalName', bytes: totalBytes);
    } finally {
      if (!committed) {
        // Even an open timeout can leave an allocation. Never reconnect or
        // replay a mutation; abort only this UUID on its original connection.
        unawaited(
          session.rpc
              .call('workspace.upload.abort', scope, timeout: const Duration(seconds: 5))
              .then((_) {}, onError: (Object _) {}),
        );
      }
    }
  }

  Future<Object?> _workspaceUploadCall(RemoteHostSession session, String method, Map<String, Object?> params) async {
    void checkConnection() {
      if (_closed || _session != session || session.isClosed) {
        throw const RemoteRpcException('TRANSPORT_CLOSED', 'The workspace upload connection ended.', isLocal: true);
      }
    }

    try {
      checkConnection();
      final result = await session.rpc.call(method, params, timeout: callTimeout);
      checkConnection();
      return result;
    } on RemoteRpcException catch (error) {
      throw (_foldRpcFailure(method, error) as RpcError).error;
    }
  }

  static bool _safeWorkspaceUploadName(String name, {int maxBytes = 220}) =>
      name.isNotEmpty &&
      utf8.encode(name).length <= maxBytes &&
      name != '.' &&
      name != '..' &&
      !RegExp(r'[\x00-\x1f\x7f/\\<>:"|?*]').hasMatch(name) &&
      !name.endsWith('.') &&
      !name.endsWith(' ') &&
      !name.startsWith('.dsh-upload-') &&
      !RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)', caseSensitive: false).hasMatch(name);

  // ---------------------------------------------------------------------------
  // Links

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final session = await _ensureSession();
    return _TunnelLink(this, session);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _health?.cancel();
    final session = _session;
    _session = null;
    await session?.close();
    // Let the mux's final `closed` state through before detaching.
    await Future<void>.delayed(Duration.zero);
    await _muxStates?.cancel();
    await _failureStates?.cancel();
    if (_state?.phase != RemoteConnectionPhase.closed && !_states.isClosed) {
      _state = RemoteConnectionState(RemoteConnectionPhase.closed, hostId: hostId, at: DateTime.now());
      _states.add(_state!);
    }
    await _failures.close();
    await _sessions.close();
    await _states.close();
  }
}

/// Remote-specific views of a [DshClient] built by `RemoteAccount.connectHost`.
extension RemoteDshClient on DshClient {
  /// The tunnel carrier, or `null` for a local client.
  RemoteTunnelCarrier? get remoteCarrier => switch (carrier) {
    final RemoteTunnelCarrier remote => remote,
    _ => null,
  };

  bool get isRemote => carrier is RemoteTunnelCarrier;

  /// Connection states of a remote client (`null` for a local one).
  Stream<RemoteConnectionState>? get remoteStates => remoteCarrier?.states;
}

/// One secure connection seen as a mux link.
class _TunnelLink implements DshMuxLink {
  _TunnelLink(this._carrier, this._session);

  final RemoteTunnelCarrier _carrier;
  final RemoteHostSession _session;
  final Set<String> _streams = {};
  final Map<String, Future<void>> _pendingFrames = {};
  StreamSubscription<RemoteEvent>? _events;
  DshMuxFrameHandler? _onFrame;
  DshMuxLossHandler? _onLost;
  bool _closed = false;

  RemoteRpcClient get _rpc => _session.rpc;

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) {
    _onFrame = onFrame;
    _onLost = onLost;
    _events = _rpc.events.listen(_queueEvent);
    unawaited(
      _rpc.done.then((reason) {
        _lose(
          DshCarrierLostException('remote connection closed (${reason.code}): ${reason.message}'),
          reason.code == 'CLIENT_CLOSED' ? null : DshTransportException('${reason.code}: ${reason.message}', reason),
        );
      }),
    );
  }

  void _lose(DshCarrierLostException failure, Object? cause) {
    if (_closed) return;
    _closed = true;
    unawaited(_events?.cancel());
    _onLost?.call(failure, cause);
  }

  void _emit(Map<String, Object?> frame) {
    if (_closed) return;
    _carrier.tracer?.call(DshTraceEntry('in', 'mux', frame));
    _onFrame?.call(frame);
  }

  void _queueEvent(RemoteEvent event) {
    final streamId = asString(asMap(event.data)?['streamId']);
    if (_closed || streamId == null || !_streams.contains(streamId)) return;
    // Preserve frame/close ordering within one stream without blocking other
    // streams while a large history item is downloaded.
    final pending = (_pendingFrames[streamId] ?? Future<void>.value()).then((_) => _onEvent(event)).catchError((
      Object error,
    ) {
      if (_closed || !_streams.remove(streamId)) return;
      _closeRemote(streamId);
      _emit({
        'type': 'error',
        'streamId': streamId,
        'error': {
          'code': error is RemoteRpcException ? error.code : 'INVALID_MESSAGE',
          'message': 'Remote stream transfer failed: $error',
          'details': const <String, Object?>{},
        },
      });
    });
    _pendingFrames[streamId] = pending;
    unawaited(
      pending.then((_) {
        if (identical(_pendingFrames[streamId], pending)) _pendingFrames.remove(streamId);
      }),
    );
  }

  Future<Map<String, Object?>> _readFrame(String streamId, Map<String, Object?> data) async {
    final descriptor = asMap(data['transfer']);
    final id = asString(descriptor?['transferId']);
    if (!_session.supportsStreamTransfer ||
        data.containsKey('value') ||
        descriptor == null ||
        id == null ||
        !RegExp(r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$').hasMatch(id)) {
      throw const DshProtocolException('Unnegotiated or ambiguous remote stream transfer');
    }
    try {
      final bytes = asInt(descriptor['totalBytes']);
      final chunks = asInt(descriptor['totalChunks']);
      if (descriptor['kind'] != 'chunked' ||
          bytes == null ||
          bytes <= 0 ||
          bytes > maxRemoteTransferBytes ||
          chunks != (bytes + remoteTransferChunkBytes - 1) ~/ remoteTransferChunkBytes) {
        throw const DshProtocolException('Invalid remote stream transfer descriptor');
      }
      final watch = Stopwatch()..start();
      final out = BytesBuilder(copy: false);
      for (var index = 0; index < chunks!; index++) {
        if (_closed || !_streams.contains(streamId)) throw const DshClosedException('Stream cancelled');
        final remainingTime = _carrier.callTimeout - watch.elapsed;
        if (remainingTime <= Duration.zero) throw const DshProtocolException('Remote stream transfer timed out');
        final chunk = asMapOrEmpty(
          await _rpc.call('harness.remote.transfer.read', {'transferId': id, 'index': index}, timeout: remainingTime),
        );
        final text = asString(chunk['data']);
        if (chunk['transferId'] != id || chunk['index'] != index || text == null) {
          throw const DshProtocolException('Out-of-order remote stream transfer');
        }
        final decoded = base64Decode(text);
        final remaining = bytes - index * remoteTransferChunkBytes;
        final expected = remaining < remoteTransferChunkBytes ? remaining : remoteTransferChunkBytes;
        if (decoded.length != expected || base64Encode(decoded) != text) {
          throw const DshProtocolException('Invalid remote stream transfer chunk');
        }
        out.add(decoded);
      }
      final frame = asMap(jsonDecode(utf8.decode(out.takeBytes())));
      if (frame == null ||
          frame['streamId'] != streamId ||
          frame['hasValue'] != true ||
          frame.containsKey('transfer')) {
        throw const DshProtocolException('Invalid transferred remote stream frame');
      }
      return frame;
    } finally {
      // Releases Host backpressure even on malformed data or cancellation.
      try {
        await _rpc.call('harness.remote.transfer.close', {'transferId': id}, timeout: const Duration(seconds: 5));
      } on Object {
        /* The connection may already have gone away. */
      }
    }
  }

  Future<void> _onEvent(RemoteEvent event) async {
    if (_closed) return;
    final data = asMap(event.data);
    final streamId = asString(data?['streamId']);
    if (streamId == null || !_streams.contains(streamId)) return;
    switch (event.event) {
      case 'harness.remote.frame':
        if (data!['hasValue'] != true) return;
        final frame = data.containsKey('transfer') ? await _readFrame(streamId, data) : data;
        if (_closed || !_streams.contains(streamId)) return;
        _emit({'type': 'item', 'streamId': streamId, 'value': frame['value']});
      case 'harness.remote.stream.closed':
        _streams.remove(streamId);
        switch (data!['reason']) {
          case 'failed':
            final failure = asMapOrEmpty(data['failure']);
            _emit({
              'type': 'error',
              'streamId': streamId,
              'error': {
                'code': asString(failure['code']) ?? 'internal',
                'message': asString(failure['message']) ?? 'The remote Harness stream failed.',
                'details': asMapOrEmpty(failure['details']),
              },
            });
          case 'peer-disconnected':
            // The Host tore down this connection's streams: treat as loss.
            _lose(const DshCarrierLostException('remote Host disconnected the stream'), null);
            unawaited(_carrier._closeSession(_session));
          default: // completed, cancelled
            _emit({'type': 'end', 'streamId': streamId});
        }
    }
  }

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (_closed) return;
    if (!_carrier.allowsEndpoint(endpoint)) {
      scheduleMicrotask(
        () => _emit({
          'type': 'error',
          'streamId': streamId,
          'error': {
            'code': 'METHOD_NOT_ALLOWED',
            'message': 'The stream $endpoint is not available over ds-harness-remote.',
            'details': {'endpoint': endpoint},
          },
        }),
      );
      return;
    }
    _streams.add(streamId);
    _rpc
        .call('harness.remote.stream.open', {
          'streamId': streamId,
          'endpoint': endpoint,
          'payload': payload,
          if (_session.supportsStreamTransfer) 'transferFrames': true,
        }, timeout: _carrier.streamControlTimeout)
        .then(
          (_) {},
          onError: (Object error) {
            if (!_streams.remove(streamId)) return;
            if (error is RemoteRpcException && error.isTransportClosed) {
              return; // link loss reports it
            }
            // The Host registers the stream before answering: release the slot.
            _closeRemote(streamId);
            final code = error is RemoteRpcException ? error.code : 'internal';
            final message = error is RemoteRpcException ? error.message : '$error';
            _emit({
              'type': 'error',
              'streamId': streamId,
              'error': {
                'code': code,
                'message': message,
                'details': error is RemoteRpcException ? asMapOrEmpty(error.details) : const {},
              },
            });
          },
        );
  }

  void _closeRemote(String streamId) {
    if (_rpc.isClosed) return;
    _rpc
        .call('harness.remote.stream.close', {'streamId': streamId}, timeout: _carrier.streamControlTimeout)
        .then((_) {}, onError: (Object _) {});
  }

  @override
  void cancel(String streamId) {
    if (!_streams.remove(streamId)) return;
    _closeRemote(streamId);
  }

  @override
  void sendItem(String streamId, Object? value) => throw UnsupportedError('ds-harness-remote streams have no uplink');

  @override
  void endUplink(String streamId) => throw UnsupportedError('ds-harness-remote streams have no uplink');

  @override
  Future<void> close(int code, String reason) async {
    if (_closed) return;
    _closed = true;
    // A link the mux abandons (ready timeout, $events closed, reconnect(),
    // client close) takes its connection with it; the next link is fresh.
    // Detach the session before the first await so an immediate reconnect
    // cannot pick up this closing one.
    final closing = _carrier._closeSession(_session);
    await _events?.cancel();
    await closing;
  }
}
