import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';

import 'companion_notes_peer.dart';

class _Mux extends DshMux {
  _Mux(super.carrier);
  final connection = StreamController<DshConnectionState>.broadcast();
  @override
  Stream<DshConnectionState> get states => connection.stream;
}

class CompanionSessionPeer extends DshClient {
  CompanionSessionPeer(super.connection);
  late final _fakeMux = _Mux(carrier);
  final _watches = <StreamController<DshEvent>>[];
  final _bySession = <String, List<StreamController<DshEvent>>>{};
  final records = <String, List<Map<String, Object?>>>{};
  final prompts = <({String session, String text, String requestId})>[];
  bool dropNext = false;
  Completer<void>? releaseEcho;
  Completer<void>? releaseCommit;
  final scriptedWords = <String, String>{};
  Future<void>? holdBeforeResponse;
  final firstPrompt = Completer<void>();
  final firstTurnEnded = Completer<void>();
  final cancelledSessions = <String>[];
  final cancelled = Completer<void>();
  @override
  Future<void> cancel(String sessionId) async {
    cancelledSessions.add(sessionId);
    if (!cancelled.isCompleted) cancelled.complete();
  }
  int serial = 0;
  @override
  DshMux get mux => _fakeMux;

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) {
    final controller = StreamController<DshEvent>();
    _watches.add(controller);
    _bySession.putIfAbsent(sessionId, () => []).add(controller);
    controller.onListen = () => controller.add(
      parseFollowFrame(sessionId, {
        'type': 'snapshot',
        'cursor': (records[sessionId]?.length ?? 0) - 1,
        'records': records[sessionId] ?? [],
        'assistantStream': {'revision': 0},
      }),
    );
    return controller.stream;
  }

  @override
  Future<String> prompt(
    String sessionId,
    String text, {
    List<PromptImage> images = const [],
    List<String> fileReceiptIds = const [],
    String? requestId,
    PromptMode mode = PromptMode.queue,
    String? timeZone,
  }) async {
    final id = requestId!;

    prompts.add((session: sessionId, text: text, requestId: id));
    if (!firstPrompt.isCompleted) firstPrompt.complete();
    final gate = holdBeforeResponse;
    if (gate != null) await gate;
    if (dropNext) {
      dropNext = false;
      throw const DshTransportException('Prompt result unknown');
    }
    return completeOriginal(sessionId, text, id);
  }

  void journal(String sessionId, String type, Map<String, Object?> data) {
    final log = records.putIfAbsent(sessionId, () => []);
    final entry = <String, Object?>{
      'type': type,
      'seq': log.length,
      'time': 1795260000123 + log.length,
      'data': data,
    };
    log.add(entry);
    for (final watch in _bySession[sessionId] ?? <StreamController<DshEvent>>[]) {
      watch.add(parseFollowFrame(sessionId, {'type': 'event', 'event': entry}));
    }
  }

  // The Host journal may arrive even after the prompt transport returned an error.
  Future<String> completeOriginal(String sessionId, String text, String id) async {
    final log = records.putIfAbsent(sessionId, () => []);
    final hold = releaseEcho;
    if (hold != null) await hold.future;
    final turn = ++serial;
    void event(String type, Map<String, Object?> data) => journal(sessionId, type, data);
    event('turn/start', {'turn': turn});
    event('user/message', {
      'id': 'source-$turn',
      'role': 'user',
      'content': [{'type': 'text', 'text': text}],
      'source': {'kind': 'user', 'rpcId': id},
    });
    if (hold != null) await cancelled.future;
    final commit = releaseCommit;
    final words = scriptedWords[text] ?? (commit == null ? '会话回复' : '[动作:点头]找到文件了。');
    var revision = 0;
    void stream(Map<String, Object?> frame) {
      final data = {'type': 'assistant-stream', 'frame': {'attemptId': 'try-$turn', 'revision': ++revision, ...frame}};
      for (final watch in _bySession[sessionId] ?? <StreamController<DshEvent>>[]) {
        watch.add(parseFollowFrame(sessionId, data));
      }
    }
    if (commit != null) {
      event('step/start', {'turn': turn, 'step': 1});
      stream({'type': 'start', 'turn': turn, 'step': 1, 'startedAfterSeq': log.length - 1});
      stream({'type': 'chunk', 'index': 0, 'time': 1795260000123,
        'chunk': {'type': 'block-start', 'index': 0, 'blockType': 'text'}});
      stream({'type': 'chunk', 'index': 1, 'time': 1795260000124,
        'chunk': {'type': 'text-delta', 'index': 0, 'text': words}});
      await commit.future;
    }
    event('assistant/message', {
      'turn': turn,
      'step': 1,
      'message': {
        'role': 'assistant',
        'content': [{'type': 'reasoning', 'text': '不显示的内部推理'}, {'type': 'text', 'text': words}],
      },
    });
    if (commit != null) {
      stream({'type': 'end', 'index': 2, 'outcome': {'kind': 'committed', 'eventType': 'assistant/message', 'seq': log.length - 1}});
      event('step/end', {'turn': turn, 'step': 1});
      event('step/start', {'turn': turn, 'step': 2});
      event('assistant/message', {'turn': turn, 'step': 2, 'message': {
        'role': 'assistant', 'content': [{'type': 'text', 'text': '里面有三行。'}],
      }});
      event('step/end', {'turn': turn, 'step': 2});
    }
    event('turn/end', {'turn': turn, 'reason': {'kind': 'completed'}});
    if (!firstTurnEnded.isCompleted) firstTurnEnded.complete();
    return id;
  }

  void hostEvent(String sessionId, Map<String, Object?> frame) {
    for (final watch in _bySession[sessionId] ?? <StreamController<DshEvent>>[]) {
      watch.add(HostEvent.fromFrame(frame));
    }
  }

  Future<void> closeAll() async {
    for (final watch in _watches) {
      await watch.close();
    }
    await _fakeMux.connection.close();
    await close();
  }
}

// Script only the Host decisions. The room still sends its real Session prompt,
// advertises its per-turn bindings and submits each result on the real HTTP carrier.
class PageTaskSessionPeer extends CompanionSessionPeer {
  PageTaskSessionPeer(this.tasks, this.plan, {this.replies = const {}}) : super(tasks.connection);
  final NotesPeer tasks;
  final List<(String, Object)> Function(String) plan;
  final Map<String, String> replies;
  final _ports = <String, _TaskPort>{};
  final _active = <String, _TaskPort>{};
  final offered = <List<String>>[];
  final results = <MemoryRow>[];
  final errors = <Object>[];
  final contexts = <String, String>{};
  bool _installed = false;
  int _callId = 0;

  void install() {
    if (_installed) return;
    _installed = true;
    final ordinary = tasks.respond;
    tasks.respond = (request, body) async {
      final path = request.uri.path;
      if (path == '$dshGoCompanionPath/prompt-context') {
        final id = request.method == 'POST' ? body!['sessionId'] as String : request.uri.queryParameters['sessionId']!;
        if (request.method == 'POST') contexts[body!['requestId'] as String] = id;
        await NotesPeer.json(request, {
          'v': 1, 'supported': true, 'instanceId': 'page-task-host', 'sessionId': id,
          'profileRevision': 0, 'profileAccepted': true, 'phoneMemory': true, 'phoneMemoryVersion': 3, 'memoryMode': 'phone',
        });
      } else if (path == '$dshGoCompanionPath/session-tools/open') {
        final id = body!['requestId'] as String, session = body['sessionId'] as String;
        final tools = (body['tools'] as List).cast<Map>().map((tool) => tool['name'] as String).toList();
        if (_ports.containsKey(id) || contexts[id] != session) {
          await NotesPeer.json(request, {'error': {'code': 'test/window-mismatch'}}, status: 409);
          return;
        }
        final response = request.response
          ..headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8')
          ..bufferOutput = false;
        final port = _TaskPort(id, session, response, tools);
        _ports[id] = port;
        offered.add(tools);
        response.write('${jsonEncode({'type': 'ready', 'token': port.token})}\n');
        await response.flush();
        // Closing the room retires its callback even when the real task HTTP reply is still held.
        unawaited(response.done.then<void>((_) => _retire(port), onError: (Object _) => _retire(port)));
      } else if (path == '$dshGoCompanionPath/session-tools/result') {
        final port = _ports[body!['requestId']];
        final pending = port?.pending;
        if (port == null || port.closed || pending == null || pending.isCompleted ||
            port.session != body['sessionId'] || port.token != body['token'] || port.call != body['callId']) {
          await NotesPeer.json(request, {'error': {'code': 'test/mismatched-task-result'}}, status: 409);
          return;
        }
        // Keep the exact envelope; a late or different call cannot wake this turn.
        results.add(Map<String, Object?>.from(body));
        await NotesPeer.json(request, {});
        if (!pending.isCompleted) pending.complete(body);
      } else {
        await ordinary(request, body);
      }
    };
  }

  @override
  Future<String> prompt(String sessionId, String text, {List<PromptImage> images = const [],
    List<String> fileReceiptIds = const [], String? requestId, PromptMode mode = PromptMode.queue, String? timeZone}) async {
    final port = _ports[requestId]!;
    if (port.closed || port.session != sessionId || _active.containsKey(sessionId)) throw StateError('Unowned task prompt');
    _active[sessionId] = port;
    port.turn = ++serial;
    prompts.add((session: sessionId, text: text, requestId: port.id));
    if (!firstPrompt.isCompleted) firstPrompt.complete();
    journal(sessionId, 'turn/start', {'turn': port.turn});
    journal(sessionId, 'user/message', {'id': 'user-${port.turn}', 'role': 'user',
      'content': [{'type': 'text', 'text': text}], 'source': {'kind': 'user', 'rpcId': port.id}});
    unawaited(_play(port, text));
    return port.id;
  }

  Future<void> _play(_TaskPort port, String text) async {
    try {
      List<MemoryRow> previous = [];
      for (final (name, spec) in plan(text)) {
        if (port.closed) return;
        if (!port.tools.contains(name)) throw StateError('Room did not offer $name');
        final arguments = spec is MemoryRow Function(List<MemoryRow>) ? spec(previous) : spec as MemoryRow;
        final id = port.call = 'page-task-${++_callId}';
        final waiting = port.pending = Completer<MemoryRow?>();
        port.response.write('${jsonEncode({'type': 'call', 'callId': id, 'name': name, 'input': arguments})}\n');
        await port.response.flush();
        final row = await waiting.future;
        if (port.closed || row == null) return;
        previous = [Map<String, Object?>.from(jsonDecode(row['content']! as String) as Map)];
      }
      if (port.closed) return;
      journal(port.session, 'assistant/message', {'turn': port.turn, 'step': 1, 'message': {'role': 'assistant',
        'content': [{'type': 'text', 'text': replies[text] ?? '嗯。'}]}});
      _retire(port, completed: true);
    } catch (error) {
      if (!port.closed) {
        errors.add(error);
        _retire(port);
      }
    }
  }

  void _retire(_TaskPort port, {bool completed = false}) {
    if (port.closed) return;
    port.closed = true;
    final waiting = port.pending;
    if (waiting != null && !waiting.isCompleted) waiting.complete(null);
    if (identical(_active[port.session], port)) {
      _active.remove(port.session);
      journal(port.session, 'turn/end', {'turn': port.turn, 'reason': {'kind': completed ? 'completed' : 'interrupted'}});
    }
    unawaited(_closeResponse(port.response));
  }

  static Future<void> _closeResponse(HttpResponse response) async {
    try {
      await response.close();
    } on HttpException {
      // The client closed this callback on leaving its room.
    } on SocketException {
      // The client can also cancel the TCP stream directly.
    }
  }

  @override
  Future<void> cancel(String sessionId) async {
    final active = _active[sessionId];
    if (active != null) _retire(active);
    await super.cancel(sessionId);
  }

  @override
  Future<void> closeAll() async {
    for (final port in _ports.values) {
      _retire(port);
    }
    await super.closeAll();
  }
}

class _TaskPort {
  _TaskPort(this.id, this.session, this.response, this.tools);
  final String id, session;
  String get token => 'test-$id';
  final HttpResponse response;
  final List<String> tools;
  int turn = 0;
  bool closed = false;
  String? call;
  Completer<MemoryRow?>? pending;
}
