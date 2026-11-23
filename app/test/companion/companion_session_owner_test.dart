// Real CompanionSessions, real SessionsController creation and real DshClient
// RPC decoding. Only carrier replies and background list loading are staged.
import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RpcHost extends DshCarrier {
  _RpcHost(this.name);
  final String name;
  final calls = <(String, Map<String, Object?>)>[];
  final held = <String, Future<RpcResult> Function(Map<String, Object?>)>{};
  bool hasPreset = true;

  Iterable<Map<String, Object?>> argsOf(String endpoint) => calls.where((c) => c.$1 == endpoint).map((c) => c.$2);
  @override
  String get kind => 'companion-test';
  @override
  DshTracer? get tracer => null;
  @override
  Future<void> close() async {}
  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw StateError('no stream is needed by this test');
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    final wait = held.remove(endpoint);
    if (wait != null) return await wait(args);
    return RpcOk(switch (endpoint) {
      'session/create' => {'sessionId': '$name-created'},
      'session/projections' => {'sessionId': '$name-existing'},
      'workspace/archiveSession' => {
        'archivedSessionIds': [(args['request']! as Map)['sessionId']],
      },
      'commands/execute' => {
        'result': {'kind': 'success'},
      },
      'agentPresets/list' => {
        'presets': [
          if (hasPreset) {'id': companionPresetId},
        ],
      },
      'agentPresets/select' => companionPresetId,
      _ => throw StateError('unexpected RPC $endpoint'),
    });
  }
}

class _ActiveHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
  void change(HostRef host) => state = host;
}

class _Lists extends SessionsController {
  @override
  Future<List<SessionSummary>> build() async => const [];
  @override
  Future<void> refresh() async {}
}

class _Workspaces extends WorkspacesController {
  @override
  WorkspacesState build() => const WorkspacesState();
}

class _Selection extends WorkspacePrefsController {
  Future<String?>? pending;
  String? selected;
  @override
  WorkspacePrefs build() => const WorkspacePrefs(loaded: true);
  @override
  Future<String?> selection() async => await (pending ?? Future.value(selected));
}

class _Runtime extends LocalRuntimeController {
  @override
  LocalRuntimeState build() => const LocalRuntimeState(loaded: true);
}

class _Room {
  _Room() {
    add(HostRef.local, a);
    add(bHost, b);
    container = ProviderContainer(
      overrides: [
        activeHostProvider.overrideWith(() => host),
        activeConnectionProvider.overrideWith((ref) => AsyncData(connections[ref.watch(activeHostProvider)])),
        sessionsProvider.overrideWith(_Lists.new),
        workspacesProvider.overrideWith(_Workspaces.new),
        workspacePrefsProvider.overrideWith(() => selection),
        localRuntimeProvider.overrideWith(_Runtime.new),
      ],
    );
    container.read(activeConnectionProvider);
    addTearDown(() async {
      container.dispose();
      for (final client in clients) {
        await client.close();
      }
    });
  }
  static const bHost = HostRef.ssh('b');
  final a = _RpcHost('a');
  final b = _RpcHost('b');
  final host = _ActiveHost();
  final selection = _Selection();
  final connections = <HostRef, HostConnection>{};
  final clients = <DshClient>[];
  late final ProviderContainer container;
  CompanionSessions get sessions => container.read(companionSessionsProvider.notifier);

  void add(HostRef host, _RpcHost rpc) {
    final client = DshClient.withCarrier(rpc);
    clients.add(client);
    connections[host] = HostConnection(
      client: client,
      isLocal: host.isLocal,
      kind: host.kind,
      hostId: host.id,
      workingDirectory: '/${rpc.name}',
    );
  }

  Future<void> loaded() async {
    sessions;
    await _flush();
  }
}

Future<void> _flush() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<Object> _outcome(Future<CompanionBinding> future) =>
    future.then<Object>((value) => value, onError: (Object error) => error);

void _savedA() => SharedPreferences.setMockInitialValues({
  'companion_sessions': jsonEncode({
    'local:local': {'id': 'a-existing', 'full': true},
  }),
});

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a legacy untagged session is replaced before phone memory enters its context', () async {
    _savedA();
    final room = _Room();
    await room.loaded();
    final binding = await room.sessions.ensure(memoryArchiveId: 'phone-archive', memoryControlRevision: 0);
    expect(binding.sessionId, 'a-created');
    expect(binding.memoryArchiveId, 'phone-archive');
    expect(binding.memoryControlRevision, 0);
    expect(room.a.argsOf('session/create'), hasLength(1));
    expect(room.a.argsOf('session/projections'), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('companion_sessions')!) as Map;
    expect((saved['local:local'] as Map)['memoryArchiveId'], 'phone-archive');
  });

  test('only the matching archive and control revision can reuse a full session', () async {
    SharedPreferences.setMockInitialValues({
      'companion_sessions': jsonEncode({
        'local:local': {
          'id': 'a-existing',
          'full': true,
          'memoryArchiveId': 'phone-archive',
          'memoryControlRevision': 2,
        },
      }),
    });
    final room = _Room();
    await room.loaded();
    expect(
      (await room.sessions.ensure(memoryArchiveId: 'phone-archive', memoryControlRevision: 2)).sessionId,
      'a-existing',
    );
    expect(room.a.argsOf('session/create'), isEmpty);
    expect(
      (await room.sessions.ensure(memoryArchiveId: 'phone-archive', memoryControlRevision: 3)).sessionId,
      'a-created',
    );
    expect(room.a.argsOf('session/create'), hasLength(1));

    expect(room.a.argsOf('workspace/archiveSession').single['request'], {
      'sessionId': 'a-existing',
      'stopActivity': false,
    });
    expect(room.a.calls.map((call) => call.$1), [
      'session/projections',
      'workspace/archiveSession',
      'session/create',
      'agentPresets/list',
      'agentPresets/select',
    ]);

    room.a.held['workspace/archiveSession'] = (_) async =>
        RpcError(DshRemoteException('archive/denied', 'archive refused'));
    expect(
      await _outcome(room.sessions.ensure(memoryArchiveId: 'phone-archive', memoryControlRevision: 4)),
      isA<DshRemoteException>().having((error) => error.code, 'code', 'archive/denied'),
    );
    expect(room.a.argsOf('session/create'), hasLength(1));
    expect(room.sessions.of(HostRef.local)?.sessionId, 'a-created');
    expect(room.sessions.of(HostRef.local)?.memoryControlRevision, 3);

    room.a.held['workspace/archiveSession'] = (_) async =>
        RpcError(DshRemoteException('session/not-found', 'gone'));
    final replacement = await room.sessions.ensure(memoryArchiveId: 'phone-archive', memoryControlRevision: 4);
    expect(replacement.sessionId, 'a-created');
    expect(replacement.memoryArchiveId, 'phone-archive');
    expect(replacement.memoryControlRevision, 4);
    expect(room.a.argsOf('session/create'), hasLength(2));

    final archive = Completer<RpcResult>();
    room.a.held['workspace/archiveSession'] = (_) => archive.future;
    final pending = _outcome(room.sessions.ensure(memoryArchiveId: 'phone-archive', memoryControlRevision: 5));
    await _flush();
    expect(room.a.argsOf('workspace/archiveSession'), hasLength(4));
    expect(room.a.argsOf('session/create'), hasLength(2));
    room.sessions.retirePending();
    archive.complete(const RpcOk({'archivedSessionIds': ['a-created']}));
    expect(await pending, isA<DshClosedException>());
    expect(room.a.argsOf('session/create'), hasLength(2));
    expect(room.sessions.of(HostRef.local), same(replacement));
  });

  test('forgetAll during startup prevents a delayed preference read from restoring old bindings', () async {
    _savedA();
    final room = _Room();
    await room.sessions.forgetAll();
    await _flush();
    expect(room.sessions.of(HostRef.local), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('companion_sessions')!), isEmpty);
  });

  test('a startup intent does not move to B while preferences load', () async {
    SharedPreferences.setMockInitialValues({
      'companion_sessions': jsonEncode({
        'local:local': {'id': 'a-existing', 'full': true},
        '${_Room.bHost.kind.name}:${_Room.bHost.id}': {'id': 'b-existing', 'full': true},
      }),
    });
    final room = _Room();
    final pending = _outcome(room.sessions.ensure());
    room.host.change(_Room.bHost);
    final result = await pending;
    expect(room.b.argsOf('session/create'), isEmpty);
    expect(result, isA<DshClosedException>());
    expect(room.sessions.of(HostRef.local)?.sessionId, 'a-existing');
    expect(room.sessions.of(_Room.bHost)?.sessionId, 'b-existing');
    expect((await room.sessions.ensure()).sessionId, 'b-existing');
    expect(room.b.calls.map((call) => call.$1), ['session/projections']);
    room.host.change(HostRef.local);
    await _flush();
    expect((await room.sessions.ensure()).sessionId, 'a-existing');
    expect(room.a.calls.map((call) => call.$1), ['session/projections']);
  });

  test('a missing-session reply from A cannot create on B or bind its id to A', () async {
    _savedA();
    final room = _Room();
    await room.loaded();
    final projection = Completer<RpcResult>();
    room.a.held['session/projections'] = (_) => projection.future;
    final pending = _outcome(room.sessions.ensure());
    await _flush();
    expect(room.a.argsOf('session/projections'), hasLength(1));
    room.host.change(_Room.bHost);
    projection.complete(RpcError(DshRemoteException('session/not-found', 'gone')));
    final result = await pending;
    expect(
      {
        'createsOnB': room.b.argsOf('session/create').toList(),
        'configuredOnA': room.a.argsOf('commands/execute').map((args) => args['agentId']).toList(),
        'bindingForA': room.sessions.of(HostRef.local)?.sessionId,
      },
      {'createsOnB': isEmpty, 'configuredOnA': isEmpty, 'bindingForA': 'a-existing'},
    );
    expect(result, isA<DshClosedException>());
  });

  test('a created session finishing after a host switch is not configured or bound', () async {
    final room = _Room();
    await room.loaded();
    final creation = Completer<RpcResult>();
    room.a.held['session/create'] = (_) => creation.future;
    final pending = _outcome(room.sessions.ensure());
    await _flush();
    expect(room.a.argsOf('session/create'), hasLength(1));
    room.host.change(_Room.bHost);
    creation.complete(const RpcOk({'sessionId': 'a-late'}));
    final result = await pending;
    expect(room.a.argsOf('commands/execute'), isEmpty);
    expect(room.sessions.of(HostRef.local), isNull);
    expect(result, isA<DshClosedException>());
  });

  test('a late preset list cannot select or publish a retired binding', () async {
    final room = _Room();
    await room.loaded();
    final presets = Completer<RpcResult>();
    room.a.held['agentPresets/list'] = (_) => presets.future;
    final pending = _outcome(room.sessions.ensure());
    await _flush();
    expect(room.a.argsOf('agentPresets/list'), hasLength(1));
    room.host.change(_Room.bHost);
    presets.complete(
      const RpcOk({
        'presets': [
          {'id': companionPresetId},
        ],
      }),
    );
    final result = await pending;
    expect(room.a.argsOf('agentPresets/select'), isEmpty);
    expect(room.sessions.of(HostRef.local), isNull);
    expect(result, isA<DshClosedException>());
  });

  test('A to B to A invalidates the original session check', () async {
    _savedA();
    final room = _Room();
    await room.loaded();
    final projection = Completer<RpcResult>();
    room.a.held['session/projections'] = (_) => projection.future;
    final pending = _outcome(room.sessions.ensure());
    await _flush();
    room.host.change(_Room.bHost);
    await _flush();
    room.host.change(HostRef.local);
    projection.complete(RpcError(DshRemoteException('session/not-found', 'gone')));
    expect(await pending, isA<DshClosedException>());
    expect(room.a.argsOf('session/create'), isEmpty);
  });

  test('a replacement client for the same host invalidates old checks', () async {
    _savedA();
    final room = _Room();
    await room.loaded();
    final projection = Completer<RpcResult>();
    room.a.held['session/projections'] = (_) => projection.future;
    final pending = _outcome(room.sessions.ensure());
    await _flush();
    final replacement = _RpcHost('a-new');
    room.add(HostRef.local, replacement);
    room.container.invalidate(activeConnectionProvider);
    await _flush();
    projection.complete(RpcError(DshRemoteException('session/not-found', 'gone')));
    expect(await pending, isA<DshClosedException>());
    expect(replacement.argsOf('session/create'), isEmpty);
  });

  test('a retired intent waiting for workspace selection creates nothing', () async {
    final room = _Room();
    await room.loaded();
    final selection = Completer<String?>();
    room.selection.pending = selection.future;
    final pending = _outcome(room.sessions.ensure());
    await _flush();
    room.host.change(_Room.bHost);
    selection.complete(null);
    expect(await pending, isA<DshClosedException>());
    expect(room.a.argsOf('session/create'), isEmpty);
    expect(room.b.argsOf('session/create'), isEmpty);
  });

  test('workspace-not-found cannot retry a retired create in a fallback directory', () async {
    final room = _Room();
    await room.loaded();
    room.selection.selected = 'workspace-a';
    final creation = Completer<RpcResult>();
    room.a.held['session/create'] = (_) => creation.future;
    final pending = _outcome(room.sessions.ensure());
    await _flush();
    expect((room.a.argsOf('session/create').single['request']! as Map)['workspaceId'], 'workspace-a');
    room.host.change(_Room.bHost);
    creation.complete(RpcError(DshRemoteException(WorkspaceErrors.notFound, 'gone')));
    expect(await pending, isA<DshClosedException>());
    expect(room.a.argsOf('session/create'), hasLength(1));
  });

  test('an existing session is reused without a create or configuration call', () async {
    SharedPreferences.setMockInitialValues({
      'companion_sessions': jsonEncode({
        'local:local': {
          'id': 'a-existing',
          'full': true,
          'memoryArchiveId': 'phone-archive',
          'memoryControlRevision': 2,
        },
      }),
    });
    final room = _Room();
    await room.loaded();
    final binding = await room.sessions.ensure();
    expect(binding.sessionId, 'a-existing');
    expect(room.a.calls.map((c) => c.$1), ['session/projections']);

    final projection = Completer<RpcResult>();
    room.a.held['session/projections'] = (_) => projection.future;
    final pending = _outcome(room.sessions.ensure());
    await _flush();
    expect(room.a.argsOf('session/projections'), hasLength(2));
    room.sessions.retirePending();
    expect(room.sessions.of(HostRef.local), same(binding));
    projection.complete(const RpcOk({'sessionId': 'a-existing'}));
    expect(await pending, isA<DshClosedException>());

    final reused = await room.sessions.ensure();
    expect(reused, same(binding));
    expect(reused.memoryArchiveId, 'phone-archive');
    expect(reused.memoryControlRevision, 2);
    expect(room.a.calls.map((call) => call.$1), [
      'session/projections',
      'session/projections',
      'session/projections',
    ]);
    expect(room.a.argsOf('session/create'), isEmpty);
    expect(room.a.argsOf('workspace/archiveSession'), isEmpty);
    expect(room.a.argsOf('agentPresets/list'), isEmpty);
    expect(room.a.argsOf('agentPresets/select'), isEmpty);
  });

  test('starting over retires an unfinished creation instead of restoring its binding', () async {
    final room = _Room();
    await room.loaded();
    final creation = Completer<RpcResult>();
    room.a.held['session/create'] = (_) => creation.future;
    final pending = _outcome(room.sessions.ensure());
    await _flush();
    await room.sessions.forget();
    creation.complete(const RpcOk({'sessionId': 'a-before-restart'}));
    expect(await pending, isA<DshClosedException>());
    expect(room.sessions.of(HostRef.local), isNull);
    expect(room.a.argsOf('commands/execute'), isEmpty);
  });

  test('a new session gets the full preset, keeps the host permissions, then persists', () async {
    final room = _Room();
    await room.loaded();
    final binding = await room.sessions.ensure();
    expect(binding.sessionId, 'a-created');
    expect(binding.inlinePersona, false);
    expect(binding.full, true);
    expect(room.a.calls.map((c) => c.$1), ['session/create', 'agentPresets/list', 'agentPresets/select']);
    expect(room.a.argsOf('commands/execute'), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('companion_sessions')!) as Map;
    expect((saved['local:local'] as Map)['id'], 'a-created');
  });

  test('an older host without the persona preset keeps the inline fallback', () async {
    final room = _Room();
    await room.loaded();
    room.a.hasPreset = false;
    final binding = await room.sessions.ensure();
    expect(binding.inlinePersona, true);
    expect(room.a.argsOf('agentPresets/select'), isEmpty);
    expect(room.a.argsOf('commands/execute'), isEmpty);
  });

  test('a persona-only conversation from before is left alone and a full one opened', () async {
    SharedPreferences.setMockInitialValues({
      'companion_sessions': jsonEncode({
        'local:local': {'id': 'old-read-only'},
      }),
    });
    final room = _Room();
    await room.loaded();
    final binding = await room.sessions.ensure();
    expect(binding.sessionId, 'a-created');
    expect(binding.full, true);
    expect(room.a.argsOf('commands/execute'), isEmpty);
  });
}
