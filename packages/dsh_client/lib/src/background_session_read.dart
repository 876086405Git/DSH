/// Opt-in stock HTTP read-only list reads. Each worker owns its HTTP client,
/// including redirect hops and gzip decoding; it never closes shared RPC IO.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'binary_response.dart';
import 'engine_settings_api.dart';
import 'errors.dart';
import 'features_api.dart';
import 'json.dart';
import 'models.dart';
import 'plugins_api.dart';
import 'providers_api.dart';
import 'rpc.dart';
import 'rpc_envelope.dart';

/// Fixed read-only operations. The tag, not an arbitrary decoder closure,
/// crosses the isolate boundary; each branch constructs the existing DTOs.
enum BackgroundListKind {
  sessions('session/list'),
  models('session/modelCatalog'),
  providers('llm/listProviders'),
  configurableProviders('llm/listConfigurableProviders'),
  providerSettings('settings/describe'),
  bundles('pluginManager/listBundles'),
  plugins('pluginManager/listPlugins'),
  inventory('pluginInventory/list'),
  settings('settings/describe'),
  credentials('credentials/describe');

  const BackgroundListKind(this.endpoint);
  final String endpoint;
}

/// Immutable request snapshot; no HttpClient, tracer or closure crosses into
/// the worker. Not exported by the package's public entrypoint.
final class BackgroundListRequest {
  const BackgroundListRequest({
    required this.uri,
    required this.kind,
    required this.rpcId,
    required this.connectTimeout,
    required this.requestTimeout,
    this.hostHeader,
    this.cookieHeader,
    this.credentialRefs = const [],
  });

  final Uri uri;
  final BackgroundListKind kind;
  final List<String> credentialRefs;
  final String rpcId;
  final String? hostHeader;
  final String? cookieHeader;
  final Duration connectTimeout;
  final Duration requestTimeout;
}

/// A connection's non-reusable ownership scope. Retiring it settles callers
/// immediately; active slots remain reserved until matching worker exits.
final class BackgroundListReads {
  /// Reads go through the calling isolate's shared [BackgroundReadScheduler]
  /// unless a test hands in its own.
  BackgroundListReads({BackgroundReadScheduler? scheduler}) : _queue = scheduler ?? _scheduler;

  final BackgroundReadScheduler _queue;
  bool _closed = false;
  final Set<_ReadJob> _jobs = {};

  Future<Object?> read(BackgroundListRequest request) {
    if (_closed) return Future.error(const DshClosedException());
    return _queue.submit(this, request);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final job in _jobs.toList()) {
      _queue._retire(job, const DshClosedException());
    }
  }
}

// These are opt-in client resource policies, not engine protocol limits or
// process-wide/RSS bounds. Statics are shared only in this calling isolate.
const _maxActive = 2;
// Four concurrent App lists can fan out to three provider metadata reads
// before their completed worker's onExit releases the physical slot. Keep a
// bounded reserve for that measured startup chain instead of dropping metadata.
const _maxPending = 8;
// Waiting for the one parse slot, and parsing in it. Waiting for an active
// slot gets the request's own timeout, as the HTTP read does: on a slow cold
// start (proot, ~5 s a read) two slots take well over ten seconds to reach
// the last of a full queue.
const _stageTimeout = Duration(seconds: 10);
// A long-used host's list (hundreds of sessions with their context headers)
// passes 10 MiB; this only stops a runaway response.
const _maxBodyBytes = 64 * 1024 * 1024;
const _maxRows = 100000;
const _maxNodes = 500000;
const _maxDepth = 64;
final _scheduler = BackgroundReadScheduler();

/// One running worker, as the scheduler drives it.
abstract interface class BackgroundReadWorker {
  /// Grants the one parse slot: the worker may decode its body now.
  void parse();

  /// Stops the worker. It still reports [BackgroundReadEvents.exited], and
  /// keeps its slot until then.
  void kill();
}

/// What one worker reports, in order: [bodyReady] once its body is read,
/// then [result] or [failure], and [exited] last — only that frees its
/// slot. [crashed] is an uncaught error on the way; [spawnFailed] means no
/// worker ever ran.
final class BackgroundReadEvents {
  BackgroundReadEvents._(this._scheduler, this._job);

  final BackgroundReadScheduler _scheduler;
  final _ReadJob _job;

  void bodyReady() => _scheduler._bodyReady(_job);
  void result(Object? value) => _scheduler._result(_job, value);
  void failure(Object error, StackTrace stack) => _scheduler._failure(_job, error, stack);
  void crashed(Object? error) => _scheduler._crashed(_job, error);
  void spawnFailed(Object error, StackTrace stack) => _scheduler._spawnFailed(_job, error, stack);
  void exited() => _scheduler._exited(_job);
}

/// Starts the worker for [request], which reports through [events].
typedef BackgroundWorkerSpawn =
    BackgroundReadWorker Function(BackgroundListRequest request, BackgroundReadEvents events);

final class _ReadJob {
  _ReadJob(this.owner, this.request);
  final BackgroundListReads owner;
  final BackgroundListRequest request;
  final Completer<Object?> result = Completer();
  BackgroundReadWorker? worker;
  Timer? timer;
  bool retired = false;
  bool exited = false;

  void fail(Object error, [StackTrace? stack]) {
    if (!result.isCompleted) result.completeError(error, stack ?? StackTrace.current);
  }
}

/// Admission and stage timeouts of the list reads: at most [_maxActive]
/// workers and [_maxPending] waiting (beyond that a read fails at once), one
/// body parsed at a time. Every reader in an isolate shares one; a test may
/// drive its own over a fake [spawn].
final class BackgroundReadScheduler {
  BackgroundReadScheduler({BackgroundWorkerSpawn spawn = _IsolateWorker.new}) : _spawn = spawn;

  final BackgroundWorkerSpawn _spawn;
  final Queue<_ReadJob> _pending = Queue();
  final Set<_ReadJob> _active = {};
  final Queue<_ReadJob> _ready = Queue();
  _ReadJob? _parsing;

  Future<Object?> submit(BackgroundListReads owner, BackgroundListRequest request) {
    final job = _ReadJob(owner, request);
    if (_active.length >= _maxActive && _pending.length >= _maxPending) {
      job.fail(DshTransportException('${job.request.kind.endpoint}: background read queue is full; retry later'));
      return job.result.future;
    }
    owner._jobs.add(job);
    _pending.add(job);
    job.timer = Timer(request.requestTimeout, () => _retire(job, _timeout(job, 'queue')));
    _drain();
    return job.result.future;
  }

  DshTransportException _timeout(_ReadJob job, String stage) =>
      DshTransportException('${job.request.kind.endpoint}: background $stage timed out');

  void _drain() {
    while (_active.length < _maxActive && _pending.isNotEmpty) {
      _start(_pending.removeFirst());
    }
  }

  void _start(_ReadJob job) {
    _active.add(job);
    job.timer?.cancel();
    job.timer = Timer(job.request.requestTimeout, () => _retire(job, _timeout(job, 'HTTP read')));
    job.worker = _spawn(job.request, BackgroundReadEvents._(this, job));
  }

  void _bodyReady(_ReadJob job) {
    if (job.exited || job.retired) return;
    job.timer?.cancel();
    job.timer = Timer(_stageTimeout, () => _retire(job, _timeout(job, 'parse queue')));
    _ready.add(job);
    _advanceParse();
  }

  void _result(_ReadJob job, Object? value) {
    if (job.exited) return;
    job.timer?.cancel();
    if (!job.retired && !job.owner._closed && !job.result.isCompleted) {
      job.result.complete(value);
    }
    // Isolate.exit sends the result, followed by exit notification on the
    // same port. The result alone never releases active/parse ownership.
  }

  void _failure(_ReadJob job, Object error, StackTrace stack) {
    if (job.exited) return;
    job.timer?.cancel();
    job.fail(error, stack);
  }

  void _crashed(_ReadJob job, Object? error) {
    if (job.exited) return;
    // Uncaught VM/user worker error; still wait for onExit to free slots.
    _retire(job, DshTransportException('${job.request.kind.endpoint}: worker failed', error.toString()));
  }

  void _spawnFailed(_ReadJob job, Object error, StackTrace stack) {
    job.fail(
      DshTransportException('${job.request.kind.endpoint}: cannot start background worker', error.toString()),
      stack,
    );
    // A real spawn failure proves no worker user code owns this slot.
    _finish(job);
  }

  void _exited(_ReadJob job) {
    if (job.exited) return;
    if (!job.result.isCompleted) {
      job.fail(DshTransportException('${job.request.kind.endpoint}: worker exited without a result'));
    }
    _finish(job);
  }

  void _advanceParse() {
    if (_parsing != null) return;
    while (_ready.isNotEmpty) {
      final job = _ready.removeFirst();
      if (job.retired || job.exited) continue;
      _parsing = job;
      job.timer?.cancel();
      job.timer = Timer(_stageTimeout, () => _retire(job, _timeout(job, 'parse')));
      job.worker!.parse();
      return;
    }
  }

  void _retire(_ReadJob job, Object error) {
    if (job.retired || job.exited) return;
    job.retired = true;
    job.timer?.cancel();
    job.fail(error);
    if (_pending.remove(job)) {
      job.owner._jobs.remove(job);
      _drain();
      return;
    }
    _ready.remove(job);
    job.worker?.kill();
    // kill is a request, not exit evidence. Keep both physical slots until
    // _finish receives this job's exit, including the late-handle case.
  }

  void _finish(_ReadJob job) {
    if (job.exited) return;
    job.exited = true;
    job.timer?.cancel();
    job.worker = null;
    job.owner._jobs.remove(job);
    _active.remove(job);
    _ready.remove(job);
    if (identical(_parsing, job)) _parsing = null;
    _advanceParse();
    _drain();
  }
}

/// The real worker: an isolate that owns the read's whole HTTP chain and
/// decode, reporting over one port.
final class _IsolateWorker implements BackgroundReadWorker {
  _IsolateWorker(BackgroundListRequest request, this._events) {
    _port.listen(_message);
    // onExit/onError are installed before user code starts. A late spawn
    // handle belongs only to this job and is killed if already retired.
    Future.sync(
      () => Isolate.spawn<_WorkerInput>(
        _sessionReadWorker,
        _WorkerInput(_port.sendPort, request),
        onError: _port.sendPort,
        onExit: _port.sendPort,
        errorsAreFatal: true,
        debugName: 'dsh-${request.kind.name}-list',
      ),
    ).then(
      (isolate) {
        _isolate = isolate;
        if (_killed && !_exited) isolate.kill(priority: Isolate.immediate);
      },
      onError: (Object error, StackTrace stack) {
        _close();
        _events.spawnFailed(error, stack);
      },
    );
  }

  final BackgroundReadEvents _events;
  final _port = ReceivePort();
  Isolate? _isolate;
  SendPort? _control;
  bool _killed = false;
  bool _exited = false;

  void _close() {
    _exited = true;
    _port.close();
    _control = null;
    _isolate = null;
  }

  void _message(Object? message) {
    if (_exited) return;
    switch (message) {
      case null:
        _close();
        _events.exited();
      case _WorkerControl(:final port):
        _control = port;
      case _BodyReady():
        _events.bodyReady();
      case _WorkerResult(:final value):
        _events.result(value);
      case _WorkerFailure(:final error, :final stack):
        _events.failure(error, StackTrace.fromString(stack));
      case [final error, _]:
        _events.crashed(error);
    }
  }

  @override
  void parse() => _control!.send(true);

  @override
  void kill() {
    _killed = true;
    _isolate?.kill(priority: Isolate.immediate);
  }
}

final class _WorkerInput {
  const _WorkerInput(this.reply, this.request);
  final SendPort reply;
  final BackgroundListRequest request;
}

final class _WorkerControl {
  const _WorkerControl(this.port);
  final SendPort port;
}

final class _BodyReady {
  const _BodyReady();
}

final class _WorkerResult {
  const _WorkerResult(this.value);
  final Object? value;
}

final class _WorkerFailure {
  const _WorkerFailure(this.error, this.stack);
  final Object error;
  final String stack;
}

Future<void> _sessionReadWorker(_WorkerInput input) async {
  final command = ReceivePort();
  input.reply.send(_WorkerControl(command.sendPort));
  final request = input.request;
  final endpoint = request.kind.endpoint;
  final http = HttpClient()
    ..connectionTimeout = request.connectTimeout
    ..autoUncompress = true;
  Object outcome;
  try {
    final req = await http.postUrl(request.uri);
    if (request.hostHeader case final host?) {
      final parsed = Uri.tryParse('http://$host');
      if (parsed == null || parsed.host.isEmpty) {
        throw ArgumentError.value(host, 'hostHeader', 'expected host or host:port');
      }
      req.headers.host = parsed.host;
      req.headers.port = parsed.hasPort ? parsed.port : 80;
    }
    if (request.cookieHeader case final cookie?) req.headers.set(HttpHeaders.cookieHeader, cookie);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    final body = utf8.encode(
      jsonEncode({
        'type': 'client-request',
        'rpcId': request.rpcId,
        'method': endpoint,
        'payload': {
          'args': switch (request.kind) {
            BackgroundListKind.sessions => {'_request': <String, Object?>{}},
            BackgroundListKind.credentials => {'refs': request.credentialRefs},
            _ => <String, Object?>{},
          },
        },
      }),
    );
    req.contentLength = body.length;
    req.add(body);
    final response = await req.close();
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (bytes.length + chunk.length > _maxBodyBytes) {
        throw DshProtocolException('$endpoint: response exceeds $_maxBodyBytes bytes');
      }
      bytes.add(chunk);
    }
    // No text/JSON/DTO work until this caller isolate grants the one parse
    // slot. Network/gzip work remains isolated even while another job parses.
    input.reply.send(const _BodyReady());
    await command.first;
    final data = bytes.takeBytes();
    if (response.statusCode != 200) {
      throw DshHttpException(
        response.statusCode,
        httpRpcStatusMessage(response.statusCode, endpoint),
        body: utf8.decode(data, allowMalformed: true),
      );
    }
    final type = response.headers.contentType;
    final Map<String, Object?>? decoded;
    if (type?.mimeType.toLowerCase() == 'multipart/form-data') {
      final boundary = type!.parameters.entries
          .where((e) => e.key.toLowerCase() == 'boundary')
          .map((e) => e.value)
          .firstOrNull;
      if (boundary == null || boundary.isEmpty) {
        throw DshProtocolException('$endpoint: multipart result without a boundary');
      }
      decoded = decodeBinaryResponse(data, boundary);
    } else {
      decoded = asMap(tryDecodeJson(utf8.decode(data, allowMalformed: true)));
    }
    _checkStructure(decoded, endpoint);
    final result = readRpcEnvelope(decoded, request.rpcId, endpoint);
    final value = switch (result) {
      RpcOk(:final value) => value,
      RpcError(:final error) => throw error,
    };
    outcome = _WorkerResult(_readListValue(request.kind, value));
  } catch (error, stack) {
    // Socket/TLS errors may carry native objects. Preserve their typed
    // transport failure without sending a native resource to the caller.
    final safe = switch (error) {
      SocketException() => DshTransportException('POST ${request.uri.path} failed: ${error.message}', error.toString()),
      HttpException() => DshTransportException('POST ${request.uri.path} failed: ${error.message}', error.toString()),
      HandshakeException() => DshTransportException('TLS handshake failed: ${error.message}', error.toString()),
      DshException() => error,
      ArgumentError() => error,
      _ => DshProtocolException('$endpoint: background decode failed: $error'),
    };
    outcome = _WorkerFailure(safe, stack.toString());
  } finally {
    command.close();
    http.close(force: true);
  }
  Isolate.exit(input.reply, outcome);
}

void _checkStructure(Object? root, String endpoint) {
  var nodes = 0;
  void visit(Object? value, int depth) {
    if (++nodes > _maxNodes || depth > _maxDepth) {
      throw DshProtocolException('$endpoint: decoded structure budget exceeded');
    }
    if (value is Uint8List) return;
    if (value is Map) {
      for (final child in value.values) {
        visit(child, depth + 1);
      }
    } else if (value is List) {
      for (final child in value) {
        visit(child, depth + 1);
      }
    }
  }

  visit(root, 0);
}

Object? _readListValue(BackgroundListKind kind, Object? value) {
  // Preserve the original forgiving DTO readers. The resource policy rejects
  // oversized collections, but never drops valid rows to manufacture success.
  void rows(int length) {
    if (length > _maxRows) throw DshProtocolException('${kind.endpoint}: row budget exceeded');
  }

  final map = asMapOrEmpty(value);
  switch (kind) {
    case BackgroundListKind.sessions:
      final items = asListOrEmpty(map['items']);
      rows(items.length);
      return items.map(SessionSummary.fromJson).toList(growable: false);
    case BackgroundListKind.models:
      final groups = asListOrEmpty(map['groups']);
      rows(groups.length);
      var count = 0;
      for (final group in groups) {
        count += asListOrEmpty(asMapOrEmpty(group)['models']).length;
        rows(count);
      }
      return ModelCatalog.fromJson(value);
    case BackgroundListKind.providers:
      final items = asListOrEmpty(value);
      rows(items.length);
      return items
          .map((p) {
            final row = asMapOrEmpty(p);
            return (id: asString(row['id']) ?? '', name: asString(row['name']) ?? '');
          })
          .toList(growable: false);
    case BackgroundListKind.configurableProviders:
      final items = asListOrEmpty(value);
      rows(items.length);
      return [for (final item in items) ?ConfigurableProvider.fromJson(item)];
    case BackgroundListKind.providerSettings:
      final namespaces = asListOrEmpty(map['namespaces']);
      rows(namespaces.length);
      for (final item in namespaces) {
        final namespace = asMap(item);
        if (namespace == null || namespace['ns'] != piAiSettingsNs) continue;
        final section = SettingsSection.fromView(piAiSettingsNs, namespace, writable: map['writable'] != false);
        rows(asMapOrEmpty(section.value['providers']).length);
        return ProviderSettings.fromSection(section);
      }
      return null;
    case BackgroundListKind.bundles:
      final items = asListOrEmpty(value);
      rows(items.length);
      return items.map(PluginBundle.fromJson).toList(growable: false);
    case BackgroundListKind.plugins:
      final items = asListOrEmpty(value);
      rows(items.length);
      return items.map(PluginEntry.fromJson).toList(growable: false);
    case BackgroundListKind.inventory:
      rows(asListOrEmpty(map['entries']).length + asListOrEmpty(map['agentPresets']).length);
      return PluginInventory.fromJson(value);
    case BackgroundListKind.settings:
      rows(asListOrEmpty(map['namespaces']).length);
      return SettingsDescription.fromJson(value);
    case BackgroundListKind.credentials:
      rows(map.length);
      return map.map((key, item) => MapEntry(key, CredentialStatus.fromJson(item)));
  }
}
