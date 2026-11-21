import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';

import '../../../tooling/companion/offline_http.dart';

const notesPath = '/dsh-go/v1/companion/tasks';
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
    client = DshClient(
      DshConnection(
        uri,
        httpClient: _http,
        hostHeader: uri.authority,
        cookie: DshCookie(name: 'dsh-auth-test', value: 'fixture-cookie', authority: uri.authority),
      ),
    );
    server.listen((request) async {
      final text = await utf8.decoder.bind(request).join();
      final value = text.isEmpty ? null : jsonDecode(text);
      final body = value is Map ? Map<String, Object?>.from(value) : null;
      calls.add((method: request.method, uri: request.uri, body: body));
      if (request.uri.path == '$notesPath/capabilities') {
        await json(request, notesCapability);
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
  late final DshClient client;
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
    'kind': 'host.notes_to_todo',
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
