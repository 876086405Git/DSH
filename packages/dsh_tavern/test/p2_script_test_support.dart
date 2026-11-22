import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show t24Preset;

typedef ScriptJson = Map<String, Object?>;
typedef ScriptRequest = ({String method, Uri url, ScriptJson body});

ScriptJson scriptMap(Object? value) => value! as ScriptJson;

TypeMatcher<TavernScriptException> scriptError(TavernScriptErrorCode code) =>
    isA<TavernScriptException>().having((error) => error.code, 'code', code);

const scriptGlobal = TavernVariableTarget(scope: TavernVariableScope.global);
const scriptChat = TavernVariableTarget(scope: TavernVariableScope.chat);
const scriptMessage = TavernVariableTarget(scope: TavernVariableScope.message);
const scriptCharacter = TavernVariableTarget(scope: TavernVariableScope.character);
const scriptOwner = TavernVariableTarget(scope: TavernVariableScope.script);

// Real model encoder/decoder, card files and SQLite. Only HTTP responses,
// clock/random and the App host are supplied by the tests.
class ScriptFixture {
  ScriptFixture(this.root, this.allowModel, {this.cleanupMarker = 'P2_SCRIPT_CLEANUP'});

  static Future<ScriptFixture> open({bool allowModel = false, String cleanupMarker = 'P2_SCRIPT_CLEANUP'}) async {
    final directory = await Directory.systemTemp.createTemp('dsh-p2-script-');
    final h = ScriptFixture(directory, allowModel, cleanupMarker: cleanupMarker);
    addTearDown(h.dispose);
    h.config = TavernModelConfig(
      apiKey: () async {
        h.keyReads++;
        if (!allowModel) {
          throw StateError('Storage-only test requested an API key.');
        }
        return 'script-fixture-key';
      },
      baseUrl: 'https://p2-script.invalid/v1',
      model: 'p2-script-model',
      deepseek: false,
      thinking: false,
    );
    h.model = TavernModelClient(
      clientFactory: () {
        final peer = _ScriptPeer(h);
        h.peers.add(peer);
        return peer;
      },
    );
    await h.openEngine();
    await h.engine.setPreset(scriptPreset());
    await h.engine.setSettings({
      'userName': 'User',
      'macroEngine': 'modern',
      'globalRegexScripts': <Object?>[],
      'worldInfo': {
        'world_info_depth': 10,
        'world_info_budget': 80,
        'world_info_include_names': false,
        'world_info_recursive': false,
      },
    });
    return h;
  }

  final Directory root;
  final bool allowModel;
  final String cleanupMarker;
  late TavernModelConfig config;
  late TavernModelClient model;
  TavernEngine? _engine;
  final requests = <ScriptRequest>[];
  final pending = <ScriptResponsePlan>[];
  final plans = <ScriptResponsePlan>[];
  final peers = <_ScriptPeer>[];
  int keyReads = 0;
  DateTime now = DateTime.utc(2026, 11, 12, 5);
  void Function()? onRandom;

  TavernEngine get engine => _engine!;
  TavernScriptBridge get bridge => engine.scripts;

  Future<void> openEngine() async {
    _engine = await TavernEngine.openDirectory(
      root,
      config: config,
      modelClient: model,
      clock: () => now,
      random: () {
        onRandom?.call();
        return 0.25;
      },
    );
  }

  Future<void> close() async {
    final current = _engine;
    _engine = null;
    await current?.close();
  }

  Future<void> reopen({Future<void> Function()? whileClosed}) async {
    await close();
    await whileClosed?.call();
    await openEngine();
  }

  Future<String> card(
    String name, {
    String greeting = '',
    String description = '',
    ScriptJson extensions = const {},
  }) async {
    final raw = {
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': name,
        'description': description,
        'personality': '',
        'scenario': '',
        'first_mes': greeting,
        'mes_example': '',
        'creator_notes': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'alternate_greetings': <String>[],
        'tags': <String>[],
        'creator': '',
        'character_version': '',
        'extensions': extensions,
      },
    };
    return (await engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(raw))))).id;
  }

  Future<TavernScriptContext> context(
    String chatId, {
    String? characterId,
    String? nodeId,
    TavernScriptOwner? owner,
    String instanceId = 'fixture-instance',
  }) => bridge.openContext(
    TavernScriptContextSpec(
      instanceId: instanceId,
      chatId: chatId,
      characterId: characterId,
      nodeId: nodeId,
      script: owner,
    ),
  );

  Future<String> emptyChat(String characterId) async {
    // Native createChat stores its greeting even when that body is empty.
    // Exercise an actually empty selection through the public delete API.
    final chat = await engine.createChat(characterId);
    for (final greeting in (await engine.path(chat)).reversed) {
      await engine.deleteMessage(chat, greeting.nodeId);
    }
    expect(await engine.path(chat), isEmpty);
    return chat;
  }

  ScriptResponsePlan reply(String text, {int status = 200}) {
    final plan = ScriptResponsePlan.json({
      'choices': [
        {
          'index': 0,
          'message': {'role': 'assistant', 'content': text},
          'finish_reason': 'stop',
        },
      ],
    }, status: status);
    pending.add(plan);
    plans.add(plan);
    return plan;
  }

  ScriptResponsePlan stream() {
    final plan = ScriptResponsePlan.stream();
    pending.add(plan);
    plans.add(plan);
    return plan;
  }

  T inspect<T>(T Function(Database) action, {bool writable = false}) {
    final db = sqlite3.open('${root.path}/tavern.sqlite3', mode: writable ? OpenMode.readWrite : OpenMode.readOnly);
    try {
      return action(db);
    } finally {
      db.close();
    }
  }

  Future<ScriptJson> settingsDocument() async =>
      scriptMap(jsonDecode(await File('${root.path}/settings.json').readAsString()));

  void expectNoGeneration() {
    expect(requests, isEmpty);
    expect(keyReads, 0);
  }

  Future<void> dispose() async {
    try {
      await close();
    } finally {
      for (final plan in plans) {
        await plan.dispose();
      }
      // Logical generation completion does not imply async* HTTP drainage.
      // Release every owned response, then wait for the real client's finally.
      await Future.wait([for (final peer in peers) peer.closedSignal.future]);
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    }
    expect(await root.exists(), isFalse);
    expect(peers.every((peer) => peer.closed), isTrue);
    stdout.writeln(cleanupMarker);
  }
}

ChatPreset scriptPreset({bool streaming = false, String main = ''}) {
  final raw = t24Preset().raw;
  raw.addAll({
    'stream_openai': streaming,
    'openai_max_context': 8192,
    'openai_max_tokens': 73,
    'temperature': 0.4,
    'presence_penalty': 0.2,
    'frequency_penalty': 0.1,
    'top_p': 0.9,
    'seed': -1,
    'squash_system_messages': false,
    'new_group_chat_prompt': '',
    'group_nudge_prompt': '',
  });
  final prompts = (raw['prompts']! as List<Object?>).cast<ScriptJson>();
  prompts.firstWhere((prompt) => prompt['identifier'] == 'main')['content'] = main;
  return ChatPreset(raw);
}

ScriptJson scriptWire(List<ScriptJson> messages) => {
  'messages': messages,
  'model': 'p2-script-model',
  'temperature': 0.4,
  'max_tokens': 73,
  'stream': false,
  'presence_penalty': 0.2,
  'frequency_penalty': 0.1,
  'top_p': 0.9,
};

class ScriptResponsePlan {
  ScriptResponsePlan.json(this.body, {this.status = 200}) : source = null;
  ScriptResponsePlan.stream() : body = null, status = 200 {
    source = StreamController<List<int>>(sync: true, onListen: () => listening.complete());
  }
  final ScriptJson? body;
  final int status;
  StreamController<List<int>>? source;
  final seen = Completer<ScriptRequest>();
  final listening = Completer<void>();
  Future<void> Function()? beforeResponse;

  void delta(String text) {
    source!.add(
      utf8.encode(
        'data: ${jsonEncode({
          'choices': [
            {
              'index': 0,
              'delta': {'content': text},
              'finish_reason': null,
            },
          ],
        })}\n\n',
      ),
    );
  }

  void finish() {
    source!.add(
      utf8.encode(
        'data: ${jsonEncode({
          'choices': [
            {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'stop'},
          ],
        })}\n\ndata: [DONE]\n\n',
      ),
    );
    unawaited(source!.close());
  }

  Future<void> dispose() async {
    final controller = source;
    if (controller == null || controller.isClosed) {
      return;
    }
    if (listening.isCompleted) {
      await controller.close();
    } else {
      unawaited(controller.close());
    }
  }
}

class _ScriptPeer extends http.BaseClient {
  _ScriptPeer(this.h);
  final ScriptFixture h;
  final closedSignal = Completer<void>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = scriptMap(jsonDecode(utf8.decode(await request.finalize().toBytes())));
    final captured = (method: request.method, url: request.url, body: body);
    h.requests.add(captured);
    if (h.pending.isEmpty) {
      throw StateError('Unexpected additional script HTTP request.');
    }
    final plan = h.pending.removeAt(0);
    plan.seen.complete(captured);
    await plan.beforeResponse?.call();
    return http.StreamedResponse(
      plan.source?.stream ?? Stream.value(utf8.encode(jsonEncode(plan.body))),
      plan.status,
      headers: {'content-type': plan.source == null ? 'application/json' : 'text/event-stream'},
    );
  }

  @override
  void close() {
    closed = true;
    if (!closedSignal.isCompleted) {
      closedSignal.complete();
    }
  }
}

class ScriptEvents<T> {
  ScriptEvents(Stream<T> source) {
    subscription = source.listen(
      (event) {
        values.add(event);
        changes.add(event);
      },
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) {
          done.completeError(error, stack);
        }
      },
      onDone: () {
        if (!done.isCompleted) {
          done.complete();
        }
        unawaited(changes.close());
      },
    );
    addTearDown(detach);
  }
  final values = <T>[];
  final changes = StreamController<T>.broadcast(sync: true);
  final done = Completer<void>();
  late final StreamSubscription<T> subscription;

  Future<T> until(bool Function(T) accept) {
    for (final event in values) {
      if (accept(event)) {
        return Future.value(event);
      }
    }
    return Future.any([
      changes.stream.firstWhere(accept),
      done.future.then<T>((_) => throw TestFailure('Stream ended before the expected event.')),
    ]);
  }

  Future<ScriptRequest> waitRequest(ScriptResponsePlan plan) => Future.any([
    plan.seen.future,
    done.future.then<ScriptRequest>((_) => throw TestFailure('Stream ended before the expected request.')),
  ]);

  Future<void> detach() async {
    await subscription.cancel();
    if (!changes.isClosed) {
      await changes.close();
    }
  }
}

class ScriptHost implements TavernScriptHost {
  final deliveries = <TavernScriptDispatch>[];
  final refreshes = <TavernScriptRefreshRequest>[];
  Future<TavernScriptDispatchAck> Function(TavernScriptDispatch, TavernScriptCancellation)? onDispatch;
  Future<void> Function(TavernScriptRefreshRequest)? onRefresh;

  @override
  Future<TavernScriptDispatchAck> dispatch(TavernScriptDispatch request, TavernScriptCancellation cancellation) async {
    deliveries.add(request);
    return await onDispatch?.call(request, cancellation) ?? TavernScriptDispatchAck(eventId: request.eventId);
  }

  @override
  Future<void> refresh(TavernScriptRefreshRequest request) async {
    refreshes.add(request);
    await onRefresh?.call(request);
  }

  @override
  Future<TavernScriptUiResult> interact(TavernScriptUiRequest request, TavernScriptCancellation cancellation) =>
      Future.error(StateError('B1 test must not request an App UI operation.'));

  @override
  Future<TavernScriptCallbackResult> invoke(
    TavernScriptCallbackRequest request,
    TavernScriptCancellation cancellation,
  ) => Future.error(StateError('B1 test must not request a JS filter callback.'));

  @override
  Future<TavernResolvedSlash?> resolveSlash(TavernSlashReference request, TavernScriptCancellation cancellation) =>
      Future.error(StateError('B1 test must not resolve a Slash program.'));
}

ScriptJson scriptStateExtension({int initial = 0}) => {
  'dshgo': {
    'v': 1,
    'state': {
      'schema': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['count'],
        'properties': {
          'count': {'type': 'integer', 'minimum': 0, 'maximum': 100, 'default': 0, 'x-dsh-step': 5},
        },
      },
      'init': {'count': initial},
      'rules': [
        {
          'id': 'once-on-positive',
          'when': {
            '>': [
              {'var': 'count'},
              0,
            ],
          },
          'once': true,
          'do': [
            {'type': 'notice', 'text': 'script-rule-once'},
          ],
        },
      ],
    },
  },
};

// Shape from the public "getScriptTrees" documentation, not helper source.
ScriptJson scriptContainer(String initial) => {
  'variables': {'card-variable': initial},
  'unknown_container': {'keep': true},
  'scripts': [
    {
      'type': 'folder',
      'id': 'folder',
      'name': 'Folder',
      'enabled': true,
      'icon': 'book',
      'color': '#123456',
      'foreign_folder': [1, null],
      'scripts': [
        {
          'type': 'script',
          'id': 'same-script',
          'name': 'Saved script',
          'enabled': true,
          'content': '/* opaque; never executed by this test */',
          'info': 'kept',
          'button': {
            'enabled': true,
            'buttons': [
              {'name': 'Go', 'visible': true},
            ],
          },
          'export_with': {'data': true, 'button': false},
          'data': {'start': initial},
          'foreign_script': {
            'keep': [1, false],
          },
        },
      ],
    },
  ],
};
