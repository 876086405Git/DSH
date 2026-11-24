import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

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

  // The Host journal may arrive even after the prompt transport returned an error.
  Future<String> completeOriginal(String sessionId, String text, String id) async {
    final log = records.putIfAbsent(sessionId, () => []);
    final hold = releaseEcho;
    if (hold != null) await hold.future;
    final turn = ++serial;
    void event(String type, Map<String, Object?> data) {
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
