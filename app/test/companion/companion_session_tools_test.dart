import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/companion/companion_agent_loop.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:dsh_app/companion/companion_notice_channel.dart';
import 'package:dsh_app/companion/companion_session_tools.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _Notices implements CompanionNotices {
  bool enabled = true;
  @override
  Future<CompanionNoticeStatus> status() async => CompanionNoticeStatus(
    enabled: enabled, granted: true, unlocked: true, levels: const {'allowed': CompanionNoticeLevel.remember},
    received: 3, judged: 3, said: 0, epoch: 1, consentEpoch: 1,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ConflictBody extends DshConnection {
  _ConflictBody() : super(Uri.parse('http://127.0.0.1'));
  final body = StreamController<Uint8List>();
  late DshHttpAbort request;

  @override
  Future<DshHttpStreamResponse> postJsonStream(
    String path, Object? payload, {
    required DshHttpAbort abort, Duration? headerTimeout, Duration? idleTimeout = const Duration(seconds: 20),
  }) async {
    request = abort;
    return DshHttpStreamResponse(HttpStatus.conflict, 'application/json', body.stream, () async {});
  }
}

void main() {
  test('a paired HTTP stream dispatches only its offered call and reports its real result', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final replies = StreamController<Map<String, Object?>>();
    final resultFrames = StreamIterator(replies.stream);
    late HttpResponse stream;
    // The client sees `ready` before the handler's flush returns; write only after it.
    final flushed = Completer<void>();
    final served = server.listen((req) async {
      final data = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
      if (req.uri.path.endsWith('/open')) {
        expect(data['requestId'], 'turn');
        expect((data['tools'] as List).map((tool) => tool['name']), ['reminder', 'recall']);
        stream = req.response;
        stream.bufferOutput = false;
        stream.headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
        stream.writeln(jsonEncode({'type': 'ready', 'token': 'owner'}));
        await stream.flush();
        flushed.complete();
      } else {
        replies.add(Map<String, Object?>.from(data));
        req.response.write('{}');
        await req.response.close();
      }
    });
    final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
    addTearDown(() async { await client.close(); await served.cancel(); await server.close(force: true); });
    final calls = <String>[];
    final bindings = <CompanionAgentToolBinding>[
      (
        definition: const CompanionAgentTool(name: 'reminder', description: 'test', inputSchema: {'type': 'object'}),
        execute: (call) async {
          calls.add(call.id);
          expect(call.input, {'text': '午饭'});
          return const CompanionAgentToolResult(content: '已登记');
        },
      ),
    ];
    bindings.add((
      definition: const CompanionAgentTool(name: 'phone_screen', description: 'device', inputSchema: {'type': 'object'}),
      execute: (_) => throw StateError('Generic device control is never an app callback'),
    ));
    bindings.add((
      definition: const CompanionAgentTool(name: 'recall', description: 'memory', inputSchema: {'type': 'object'}),
      execute: (_) async => CompanionAgentToolResult(externalNoticeContent: true, content: jsonEncode({
        'selection': {'items': [
          {'id': 'fact', 'text': '偏好'},
          {'id': 'private', 'text': '通知正文', 'source': {'kind': 'notice'}},
        ]},
      })),
    ));
    final phone = await CompanionSessionTools.open(
      client, sessionId: 'cabin', requestId: 'turn', tools: bindings, isCurrent: () => true,
    );
    expect(phone, isNotNull);
    await flushed.future;
    stream.writeln(jsonEncode({'type': 'call', 'callId': 'one', 'name': 'reminder', 'input': {'text': '午饭'}}));
    await stream.flush();
    expect(await resultFrames.moveNext(), isTrue);
    expect(resultFrames.current, {
      'sessionId': 'cabin', 'requestId': 'turn', 'token': 'owner', 'callId': 'one', 'content': '已登记', 'isError': false,
    });
    expect(calls, ['one']);
    stream.writeln(jsonEncode({'type': 'call', 'callId': 'two', 'name': 'recall', 'input': {}}));
    await stream.flush();
    expect(await resultFrames.moveNext(), isTrue);
    expect(jsonDecode(resultFrames.current['content']! as String), {
      'selection': {'items': [{'id': 'fact', 'text': '偏好'}]},
    });
    await resultFrames.cancel();
    await replies.close();
    phone!.close();
    await stream.close();
  });

  test('a device conflict keeps its host reason, while a repeated request can reconcile the original turn', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
    var attempts = 0;
    const reason = 'companion/device-session-unavailable';
    server.listen((req) async {
      await req.drain<void>();
      final code = attempts++ == 0 ? reason : 'companion/device-request-in-use';
      req.response
        ..statusCode = HttpStatus.conflict
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': {'code': code, 'message': 'fixture text'}}));
      await req.response.close();
    });
    addTearDown(() async {
      await client.close();
      await server.close(force: true);
    });
    Future<CompanionSessionTools?> open() => CompanionSessionTools.open(
      client, sessionId: 'cabin', requestId: 'turn', isCurrent: () => true,
      tools: [companionNotifyTool(deliver: (_, _) => throw StateError('the phone received no call'))],
    );
    await expectLater(open(), throwsA(isA<CompanionHostError>()
        .having((e) => e.hostFailure, 'failure', CompanionHostFailure.deviceConflict)
        .having((e) => e.detail, 'reason', reason)));
    expect(await open(), isNull);
    expect(attempts, 2);
  });

  testWidgets('a partial conflict reply releases the phone handshake on its original deadline', (tester) async {
    final connection = _ConflictBody();
    final client = DshClient(connection);
    Object? failure;
    final pending = CompanionSessionTools.open(
      client, sessionId: 'cabin', requestId: 'turn', isCurrent: () => true,
      tools: [companionNotifyTool(deliver: (_, _) => throw StateError('no call was offered'))],
    ).then<void>((_) {}, onError: (Object error) { failure = error; });
    addTearDown(() async {
      await connection.body.close();
      await client.close();
    });
    await tester.pump();
    expect(connection.body.hasListener, isTrue);
    await tester.pump(const Duration(seconds: 7));
    connection.body.add(Uint8List.fromList(utf8.encode('{"error":')));
    await tester.pump();
    expect(connection.request.isAborted, isFalse);
    expect(failure, isNull);
    await tester.pump(const Duration(seconds: 1));
    expect(failure, isA<TimeoutException>());
    expect(connection.request.isAborted, isTrue);
    await pending;
  });

  test('recent notifications report eligible count without exposing private summaries or consuming the queue', () async {
    final notices = _Notices();
    MemoryRow row(String pkg, String text, int expires, [String mode = 'normal']) => {
      'text': text, 'scope': 'real', 'eligible': true, 'status': 'current', 'expires_at_ms': expires,
      'topic_mode': mode, 'topic_id': pkg, 'source': {'kind': 'notice', 'package': pkg, 'user_confirmed': false},
    };
    var reads = 0;
    final binding = companionRecentNoticesTool(notices: notices, isCurrent: () => true,
      now: () => DateTime.fromMillisecondsSinceEpoch(1000),
      readSummaries: () {
        reads++;
        return [row('allowed', '到货', 2000), row('other', '其他应用', 2000), row('allowed', '过期', 500),
          row('allowed', '禁提', 2000, 'never')];
      },
    );
    final call = CompanionAgentToolCall(id: 'read', name: binding.definition.name, input: const {});
    final answer = await binding.execute(call);
    expect((jsonDecode(answer.content) as Map)['retainedSummaryCount'], 1);
    expect(answer.content, isNot(contains('到货')));
    notices.enabled = false;
    expect((await binding.execute(call)).isError, isTrue);
    expect(reads, 1);
  });

  test('a local notification reports the actual resident delivery acknowledgement', () async {
    final sent = <String>[];
    final binding = companionNotifyTool(deliver: (id, text) async { sent.add('$id/$text'); return false; });
    final call = CompanionAgentToolCall(id: 'abc', name: binding.definition.name, input: const {'text': '午饭好了'});
    expect((await binding.execute(call)).isError, isTrue);
    expect(sent, ['companion:abc/午饭好了']);
  });
}
