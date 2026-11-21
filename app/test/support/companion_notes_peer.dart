import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  late final DshClient client;
  MemoryRow capability = notesCapability;
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
