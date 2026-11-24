import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/companion/companion_light.dart' show companionLightEndpoint, companionLightModel;
import 'package:dsh_client/dsh_client.dart';
import 'package:http/http.dart' as http;

import '../../../tooling/companion/offline_http.dart';

const notesPath = '/dsh-go/v1/companion/tasks';
const hostAgentPath = '/dsh-go/v1/companion/auxiliary';
const notesCapability = <String, Object?>{
  'v': 1,
  'hostStoreId': 'original-store',
  'durableAcceptance': true,
  'kinds': ['host.notes_to_todo'],
  'artifactRead': true,
  'afterExit': ['continue'],
  'pauseBehavior': 'waiting',
  'reason': null,
};

/// A controlled HTTP peer. This does not implement the Host runner or claim
/// that an RPC response proves a physical file or model execution.
class NotesPeer {
  NotesPeer._(this.server) {
    final uri = Uri.parse('http://127.0.0.1:${server.port}');
    connection = DshConnection(
      uri,
      httpClient: _http,
      hostHeader: uri.authority,
      cookie: DshCookie(name: 'dsh-auth-test', value: 'fixture-cookie', authority: uri.authority),
    );
    client = DshClient(connection);
    server.listen((request) async {
      final text = await utf8.decoder.bind(request).join();
      final value = text.isEmpty ? null : jsonDecode(text);
      final body = value is Map ? Map<String, Object?>.from(value) : null;
      if (request.uri.path == hostAgentPath && hostModel.model != null) {
        await hostModel.serve(request, body);
        return;
      }
      calls.add((method: request.method, uri: request.uri, body: body));
      if (request.uri.path == '$notesPath/capabilities') {
        await beforeCapability?.call();
        await json(request, capability);
      } else {
        await respond(request, body);
      }
    });
  }
  static Future<NotesPeer> open() async => NotesPeer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  final HttpServer server;
  // The widget binding's ambient client returns 400 without reaching the
  // server. Only this peer gets a real, numeric-loopback-only client.
  final HttpClient _http = CompanionOfflineHttpOverrides().createHttpClient(null);
  late final DshConnection connection;
  late final DshClient client;
  MemoryRow capability = notesCapability;

  /// The full room's model route (ADD67). Once its model is set, this peer
  /// answers the companion auxiliary route the way the bridge does.
  final hostModel = HostModelRoute();
  Future<void> Function()? beforeCapability;
  final calls = <({String method, Uri uri, MemoryRow? body})>[];
  late Future<void> Function(HttpRequest, MemoryRow?) respond = (request, _) => json(request, {
    'error': {'code': 'companion/task-not-found', 'message': 'No recorded task'},
  }, status: 404);
  static Future<void> json(HttpRequest request, Object? body, {int status = 200}) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> close() async {
    await client.close();
    _http.close(force: true);
    await server.close(force: true);
  }
}

/// The bridge's companion auxiliary route (ADD67) over a scripted model: a
/// Full-mode turn asks its Host, never the phone key. Each request is relayed
/// once to [model] in the phone's own Messages shape and answered with the
/// bridge's NDJSON frames, so a scripted phone model answers the same turns
/// through the Host path. The phone keeps executing every tool.
class HostModelRoute {
  static const instanceId = 'test-host';
  static const provider = 'deepseek';

  /// The scripted phone-format Messages model.
  http.Client Function()? model;

  /// False models an older bridge: its text route, but no agent turn.
  bool agent = true;

  /// Model requests seen, in the bridge's own body shape.
  final requests = <MemoryRow>[];

  MemoryRow get capability => {
    'v': 1,
    'instanceId': instanceId,
    'provider': provider,
    'model': companionLightModel,
    'supported': true,
    'capability': {
      'physicalDispatch': 'fetch-invoked',
      'rawUsage': 'deepseek-messages-cumulative',
      'maxPhysicalRequests': 1,
      'noTools': true,
    },
    if (agent) 'agent': {'v': 1, 'tools': 'return-only', 'streaming': true},
  };

  ({int status, String contentType, Stream<List<int>> body}) answer(String method, MemoryRow? body) {
    List<int> encode(Object value) => utf8.encode(jsonEncode(value));
    if (method == 'GET') {
      return (status: 200, contentType: 'application/json', body: Stream.value(encode(capability)));
    }
    final kind = body?['kind'];
    if (body == null || (kind == 'agent' ? !agent : !const {'extract', 'consolidate', 'followup'}.contains(kind))) {
      return (
        status: 400,
        contentType: 'application/json',
        body: Stream.value(
          encode({
            'error': {'code': 'companion/auxiliary-invalid-request'},
            'dispatched': false,
          }),
        ),
      );
    }
    requests.add(body);
    final relay = _HostModelRelay(agent: kind == 'agent');
    late final StreamController<List<int>> out;
    out = StreamController<List<int>>(
      onListen: () => unawaited(
        relay
            .run(model!(), body, (frame) {
              if (!out.isClosed) out.add([...encode({...frame, 'requestId': body['requestId']}), 10]);
            })
            .whenComplete(() {
              if (!out.isClosed) unawaited(out.close());
            }),
      ),
      // The phone left: stop reading the model, as the bridge's abort does.
      onCancel: relay.cancel,
    );
    return (status: 200, contentType: 'application/x-ndjson', body: out.stream);
  }

  /// Serves [answer] on a loopback response, unbuffered: a buffered dart:io
  /// response would hold flushed frames until it closes.
  Future<void> serve(HttpRequest request, MemoryRow? body) async {
    final answer = this.answer(request.method, body);
    final response = request.response
      ..bufferOutput = false
      ..statusCode = answer.status
      ..headers.contentType = ContentType.parse('${answer.contentType}; charset=utf-8');
    try {
      await response.addStream(answer.body);
      await response.close();
    } on Object {
      // The phone already left this request.
    }
  }
}

/// A connection to [route] without a socket, for a fake connection whose test
/// moves time by pumping alone. Requests still go through [DshConnection]'s
/// own HTTP code, so the phone's abort reaches the route.
DshConnection hostModelConnection(HostModelRoute route) =>
    DshConnection(Uri.parse('http://127.0.0.1:9'), httpClient: _MemoryHttpClient(route));

class _MemoryHttpClient implements HttpClient {
  _MemoryHttpClient(this.route);
  final HostModelRoute route;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async => _MemoryRequest(route, method, url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemoryRequest implements HttpClientRequest {
  _MemoryRequest(this.route, this.method, this.uri);
  final HostModelRoute route;
  @override
  final String method;
  @override
  final Uri uri;
  @override
  final HttpHeaders headers = _MemoryHeaders();
  @override
  bool followRedirects = true;
  @override
  int contentLength = -1;
  final _bytes = BytesBuilder();
  final _done = Completer<HttpClientResponse>();

  @override
  void add(List<int> data) => _bytes.add(data);

  @override
  Future<HttpClientResponse> close() async {
    final text = utf8.decode(_bytes.takeBytes());
    final value = text.isEmpty ? null : jsonDecode(text);
    final answer = route.answer(method, value is Map ? MemoryRow.from(value) : null);
    final response = _MemoryResponse(answer.status, ContentType.parse(answer.contentType), answer.body);
    if (!_done.isCompleted) _done.complete(response);
    return response;
  }

  @override
  Future<HttpClientResponse> get done => _done.future;

  /// The reader's own cancel retires the relay; nothing else is open here.
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemoryResponse extends Stream<List<int>> implements HttpClientResponse {
  _MemoryResponse(this.statusCode, ContentType type, this._body) {
    headers.contentType = type;
  }

  @override
  final int statusCode;
  @override
  final HttpHeaders headers = _MemoryHeaders();
  final Stream<List<int>> _body;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _body.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemoryHeaders implements HttpHeaders {
  final _values = <String, List<String>>{};
  @override
  ContentType? contentType;
  @override
  String? host;
  @override
  int? port;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) => _values[name.toLowerCase()] = ['$value'];

  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One Host model request, relayed to a scripted phone-format Messages model.
/// It asks once, as the bridge does, and reports what actually came back: the
/// text as it streams, then the completed message and its finish receipt.
class _HostModelRelay {
  _HostModelRelay({required this.agent});

  final bool agent;
  final _blocks = <int, MemoryRow>{};
  final _arguments = <int, StringBuffer>{};
  MemoryRow? _startUsage;
  MemoryRow? _finalUsage;
  String? _stopReason;
  int? _httpStatus;
  String _terminal = 'incomplete';
  bool _complete = false;
  String? _error;
  bool _cancelled = false;
  StreamSubscription<String>? _subscription;
  Completer<void>? _reading;

  Future<void> run(http.Client model, MemoryRow body, void Function(MemoryRow) emit) async {
    emit({
      'type': 'accepted',
      'instanceId': HostModelRoute.instanceId,
      'provider': HostModelRoute.provider,
      'model': companionLightModel,
    });
    final dispatchAt = DateTime.now().millisecondsSinceEpoch;
    emit({'type': 'dispatch', 'boundary': 'fetch-invoked', 'atMs': dispatchAt});
    await _ask(model, body, emit);
    if (!_cancelled) emit(_finish(dispatchAt));
  }

  Future<void> cancel() async {
    _cancelled = true;
    final subscription = _subscription;
    _subscription = null;
    if (_reading case final reading? when !reading.isCompleted) reading.complete();
    await subscription?.cancel();
  }

  Future<void> _ask(http.Client model, MemoryRow body, void Function(MemoryRow) emit) async {
    // The phone's own Messages body: the Host adds no history, source or tool.
    final messages = [
      for (final message in (body['messages'] as List? ?? [
        {'role': 'user', 'content': body['input']},
      ]).cast<Map>())
        {
          for (final MapEntry(:key, :value) in message.entries)
            if (key != 'source') key as String: value,
        },
    ];
    final tools = body['tools'] as List? ?? const [];
    final request = http.Request('POST', Uri.parse(companionLightEndpoint))
      ..headers.addAll({'content-type': 'application/json', 'accept': 'text/event-stream'})
      ..body = jsonEncode({
        'model': companionLightModel,
        'stream': true,
        'max_tokens': body['maxTokens'],
        'thinking': {'type': 'disabled'},
        'system': body['system'],
        'messages': messages,
        if (tools.isNotEmpty) 'tools': tools,
      });
    final http.StreamedResponse response;
    try {
      response = await model.send(request);
    } on Object {
      _terminal = 'network_error';
      _error = 'provider-network-error';
      return;
    }
    _httpStatus = response.statusCode;
    if (_cancelled) {
      await response.stream.listen((_) {}).cancel();
      return;
    }
    if (response.statusCode != 200) {
      _terminal = 'http_error';
      _error = 'provider-http-error';
      unawaited(response.stream.drain<void>().catchError((Object _) {}));
      return;
    }
    final reading = _reading = Completer<void>();
    void stop() {
      if (!reading.isCompleted) reading.complete();
      unawaited(_subscription?.cancel());
      _subscription = null;
    }

    void invalid() {
      _terminal = 'provider_error';
      _error = 'provider-invalid-stream';
      stop();
    }

    _subscription = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (!line.startsWith('data:')) return;
            final data = line.substring(5).trim();
            if (data.isEmpty || data == '[DONE]') return;
            try {
              final event = jsonDecode(data);
              if (event is! Map) throw const FormatException('Expected a model event');
              if (event['type'] == 'error' || (event['type'] == null && event['error'] != null)) {
                _terminal = 'provider_error';
                _error = 'provider-error';
                stop();
              } else if (event['type'] is! String) {
                throw const FormatException('Expected an event type');
              } else if (_add(event, emit)) {
                stop();
              }
            } on FormatException {
              invalid();
            } on TypeError {
              invalid();
            }
          },
          onError: (Object _) {
            _terminal = 'network_error';
            _error = 'provider-network-error';
            stop();
          },
          onDone: stop,
          cancelOnError: true,
        );
    await reading.future;
  }

  /// True once the reply is complete.
  bool _add(Map event, void Function(MemoryRow) emit) {
    final index = event['index'];
    switch (event['type']) {
      case 'message_start':
        final message = event['message'];
        if (message is Map && message['usage'] is Map) _startUsage ??= MemoryRow.from(message['usage'] as Map);
      case 'content_block_start':
        final block = event['content_block'] as Map;
        if (block['type'] == 'tool_use') {
          _blocks[index as int] = {
            'type': 'tool_use',
            'id': block['id'],
            'name': block['name'],
            'input': MemoryRow.from(block['input'] as Map),
          };
          _arguments[index] = StringBuffer();
        } else {
          final text = block['text'] as String? ?? '';
          _blocks[index as int] = {'type': 'text', 'text': text};
          if (text.isNotEmpty) emit({'type': 'text', 'text': text});
        }
      case 'content_block_delta':
        final delta = event['delta'] as Map;
        if (delta['type'] == 'text_delta') {
          final block = _blocks.putIfAbsent(index as int, () => {'type': 'text', 'text': ''});
          block['text'] = '${block['text']}${delta['text']}';
          emit({'type': 'text', 'text': delta['text']});
        } else if (delta['type'] == 'input_json_delta') {
          final partial = delta['partial_json'];
          if (partial is! String || !_arguments.containsKey(index)) {
            throw const FormatException('Expected JSON for an open tool block');
          }
          _arguments[index]!.write(partial);
        }
      case 'content_block_stop':
        final arguments = _arguments.remove(index)?.toString();
        if (arguments != null && arguments.isNotEmpty) {
          _blocks[index as int]!['input'] = MemoryRow.from(jsonDecode(arguments) as Map);
        }
      case 'message_delta':
        if (event['usage'] is Map) _finalUsage = MemoryRow.from(event['usage'] as Map);
        final delta = event['delta'];
        if (delta is Map && delta['stop_reason'] is String) _stopReason = delta['stop_reason'] as String;
      case 'message_stop':
        if (_arguments.isNotEmpty) throw const FormatException('Unclosed tool block');
        _complete = true;
        final content = [for (final key in _blocks.keys.toList()..sort()) _blocks[key]!];
        final calls = content.any((block) => block['type'] == 'tool_use');
        _terminal = switch (_stopReason) {
          'max_tokens' => 'max_tokens',
          'refusal' => 'refusal',
          _ when agent && calls => 'tool-calls',
          _ => 'complete',
        };
        if (agent && (_terminal == 'complete' || _terminal == 'tool-calls')) {
          emit({
            'type': 'message',
            'message': {
              'content': content,
              'stopReason': calls ? 'tool_use' : 'end_turn',
              'source': {'kind': 'model', 'provider': HostModelRoute.provider, 'model': companionLightModel},
            },
          });
        }
        return true;
    }
    return false;
  }

  MemoryRow _finish(int dispatchAtMs) {
    int? count(String key) => switch (_finalUsage?[key]) {
      final int value when value >= 0 => value,
      _ => null,
    };
    return {
      'type': 'finish',
      'dispatched': true,
      'dispatchAtMs': dispatchAtMs,
      'terminal': _terminal,
      'complete': _complete,
      'stopReason': _stopReason,
      'httpStatus': _httpStatus,
      if (_error != null) 'error': {'code': _error},
      'usage': {
        'provider': HostModelRoute.provider,
        'model': companionLightModel,
        'start_usage': _startUsage,
        'final_usage': _finalUsage,
        'start_event': _startUsage == null ? null : 'message_start',
        'final_event': _finalUsage == null ? null : 'message_delta',
        'usage_semantics': _startUsage != null || _finalUsage != null ? 'cumulative' : 'unknown',
        'input_uncached': count('input_tokens'),
        'input_cache_read': count('cache_read_input_tokens'),
        'input_cache_write': count('cache_creation_input_tokens'),
        'output_tokens': count('output_tokens'),
        'stop_reason': _stopReason,
        'terminal': _terminal,
        'complete': _complete,
        'http_status': _httpStatus,
      },
    };
  }
}

/// Hold only the acknowledgement after the actual HTTP reader has retired.
/// Tests can read a newer observation while the old decoder still unwinds.
class DelayedNotesForegroundRetirement extends DshConnection {
  DelayedNotesForegroundRetirement(this.physical, {this.holdBodyCancellation = false}) : super(physical.baseUri);
  final DshConnection physical;
  final bool holdBodyCancellation;
  final retired = Completer<void>();
  final release = Completer<void>();

  @override
  Future<DshHttpResponse> get(
    String path, {
    Map<String, String>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool followRedirects = true,
    int? maxResponseBytes,
  }) => physical.get(
    path,
    query: query,
    headers: headers,
    timeout: timeout,
    followRedirects: followRedirects,
    maxResponseBytes: maxResponseBytes,
  );

  @override
  Future<DshHttpStreamResponse> postJsonStream(
    String path,
    Object? body, {
    required DshHttpAbort abort,
    Duration? headerTimeout,
    Duration? idleTimeout = const Duration(seconds: 20),
  }) async {
    final response = await physical.postJsonStream(
      path,
      body,
      abort: abort,
      headerTimeout: headerTimeout,
      idleTimeout: idleTimeout,
    );
    Future<void> retire() async {
      await response.cancel();
      if (!retired.isCompleted) retired.complete();
      await release.future;
    }

    Stream<Uint8List> observedBody() async* {
      try {
        yield* response.body;
      } finally {
        // Also expose the await-for subscription retirement boundary. Bytes
        // and actual socket cancellation still come from the real response.
        await retire();
      }
    }

    return DshHttpStreamResponse(
      response.statusCode,
      response.contentType,
      holdBodyCancellation ? observedBody() : response.body,
      retire,
    );
  }
}

MemoryRow notesAgreement({bool queue = false, String afterExit = 'continue'}) => {
  'args': {
    'folderRef': 'bound-source',
    'localDate': '2026-11-21',
    'timeZone': 'Asia/Shanghai',
    'dateBy': 'modified',
    'outputDirRef': 'bound-source',
    'outputName': '今日待办.md',
    'writeMode': 'createNew',
  },
  'deadlineAtMs': null,
  'afterExit': afterExit,
  'allowQueue': queue,
};

MemoryRow notesSnapshot(
  MemoryRow create, {
  int seq = 1,
  int rev = 1,
  String state = 'running',
  bool original = true,
  MemoryRow? agreement,
  List<MemoryRow>? revisions,
  List<MemoryRow> artifacts = const [],
  List<MemoryRow> steps = const [],
  MemoryRow? approval,
}) {
  final saved = {
    for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: create[key],
  };
  return {
    'v': 1,
    'hostStoreId': 'original-store',
    'taskId': create['taskId'],
    'hostExecutionId': 'actual-execution',
    'kind': create['kind'] ?? 'host.notes_to_todo',
    'taskRev': rev,
    'runnerReceiptSeq': seq,
    'originalCreatePresent': original,
    'origin': original ? create['origin'] : null,
    'hostSessionId': original ? create['hostSessionId'] : null,
    'state': state,
    'waitReason': state == 'waiting' ? (original ? 'foreground_control_unavailable' : 'original_create_missing') : null,
    'cancelRequested': state == 'cancelled',
    'createdAtMs': 1795219200000,
    'updatedAtMs': 1795219200000 + seq,
    'agreement': agreement ?? saved,
    'revisions':
        revisions ??
        [
          {'taskRev': 1, 'operation': 'create', 'acceptedAtMs': 1795219200000, 'agreement': saved},
        ],
    'steps': steps,
    'artifacts': artifacts,
    'approval': approval,
    'budget': {'limitMs': 300000, 'spentMs': 120, 'heldMs': 0},
  };
}

MemoryRow notesArtifact() => {
  'artifactId': 'file-original',
  'taskRev': 1,
  'stepKey': 'writePage',
  'relativePath': '今日待办.md',
  'mediaType': 'text/markdown',
  'size': 24,
  'sha256': List.filled(64, 'a').join(),
  'verifiedAtMs': 1795219200000,
  'sourceCount': 2,
};

final findCapability = <String, Object?>{
  ...notesCapability,
  'kinds': ['host.notes_to_todo', 'host.find_draft'],
  'sourceRead': true,
};
const findSpokenExample =
    '等家里电脑开了，帮我在‘演讲稿’这个文件夹的这一层找昨天改的稿子。'
    '七点以前把能打开的入口留在小屋，我先去布场。不用翻别处。';

MemoryRow findAgreement({
  bool queue = false,
  String afterExit = 'continue',
  String day = '2026-11-20',
  List<String> extensions = const ['md', 'txt'],
}) => {
  'args': {
    'folderRef': 'bound-source',
    'scope': 'currentLevel',
    'localDate': day,
    'timeZone': 'Asia/Shanghai',
    'dateBy': 'modified',
    'extensions': extensions,
  },
  'deadlineAtMs': null,
  'afterExit': afterExit,
  'allowQueue': queue,
};

MemoryRow findMatch({String id = 'draft-original', String name = '开场 A.md', bool openable = true}) => {
  'sourceRef': id,
  'relativePath': name,
  'size': 120,
  'modifiedAtMs': 1795147200000,
  'modifiedOffsetSeconds': 28800,
  'version': 'version-$id',
  'openable': openable,
  'reason': openable ? null : 'read_not_allowed',
};

/// Fixed HTTP observations for the App boundary. They do not run the Host FS.
MemoryRow findReportStep({
  int revision = 1,
  MemoryRow? agreement,
  List<MemoryRow> matches = const [],
  bool complete = true,
  List<MemoryRow> gaps = const [],
}) {
  final args = (agreement ?? findAgreement())['args']! as Map<String, Object?>;
  final day = DateTime.parse('${args['localDate']}T00:00:00Z');
  final start = day.millisecondsSinceEpoch - 28800000;
  return {
    'taskRev': revision,
    'stepKey': 'readInputs',
    'attemptId': 'find-read-$revision',
    'state': complete ? 'done' : 'partial',
    'startedAtMs': 1795219200000,
    'finishedAtMs': 1795219200010,
    'reason': complete ? null : 'coverage_partial',
    'result': {
      'completion': {
        'scope': {...args, 'displayPath': '/本人选的稿件', 'startAtMs': start, 'endAtMs': start + 86400000},
        'coverage': {
          'entriesChecked': 4,
          'supportedFilesChecked': matches.length,
          'matchingCandidates': matches.length,
          'enumerationComplete': true,
          'entryLimitReached': false,
          'candidateLimitReached': false,
          'gaps': gaps,
        },
        'matches': matches,
      },
    },
  };
}
