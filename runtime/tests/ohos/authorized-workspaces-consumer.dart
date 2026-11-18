import 'dart:convert';
import 'dart:io';

import '../../../app/lib/runtime/authorized_workspaces.dart';

void check(bool condition, String label) {
  if (!condition) throw StateError(label);
}

void rejects(void Function() work) {
  try {
    work();
  } on FormatException {
    return;
  }
  throw StateError('invalid protocol was accepted');
}

Future<void> main(List<String> arguments) async {
  final cases = jsonDecode(
    File(arguments.single).readAsStringSync(),
  ) as Map<String, dynamic>;
  final capability = AuthorizedWorkspaceCapabilities.fromChannel(
    cases['capabilities'],
  );
  check(
    capability.available &&
        capability.folderSelection &&
        !capability.engineAttached,
    'capability',
  );
  var count = 0;
  for (final item in cases['snapshots'] as List) {
    final state = AuthorizedWorkspacesSnapshot.fromChannel(item['wire']);
    check(!state.engineAttached, 'engine must remain unattached');
    for (final workspace in state.workspaces) {
      check(
        !workspace.engineAttached && workspace.nodeAccess == 'unverified',
        'unverified Node access',
      );
    }
    check(
      state.workspaces.isEmpty ||
          state.workspaces.single.authorization.name == item['authorization'],
      'actual ETS state',
    );
    count++;
  }
  final selected = (cases['snapshots'] as List).first['wire'] as Map;
  final wire = Map<String, Object?>.from(selected);
  rejects(
    () => AuthorizedWorkspacesSnapshot.fromChannel({...wire, 'protocol': 2}),
  );
  rejects(
    () => AuthorizedWorkspacesSnapshot.fromChannel({
      ...wire,
      'engineAttached': true,
    }),
  );
  rejects(
    () => AuthorizedWorkspacesSnapshot.fromChannel({
      ...wire,
      'osGrantChanged': true,
    }),
  );
  final record = Map<String, Object?>.from(
    (wire['workspaces'] as List).single as Map,
  );
  for (final mutation in [
    {'engineAttached': true},
    {'nodeAccess': 'read-write'},
    {'authorization': 'ready'},
    {'persistence': 'forever'},
    {'generation': -1},
    {'candidatePath': 123},
  ]) {
    rejects(() => AuthorizedWorkspace.fromChannel({...record, ...mutation}));
  }
  final calls = <Map<String, Object?>>[];
  final client = AuthorizedWorkspacesClient((method, args) async {
    calls.add({'method': method, 'arguments': args});
    return method == 'capabilities' ? cases['capabilities'] : wire;
  });
  await client.capabilities();
  await client.list();
  await client.select(userGesture: false);
  await client.persist('exact-id', userGesture: true);
  await client.activate('exact-id', userGesture: true);
  await client.deactivate('exact-id', userGesture: true);
  await client.revoke('exact-id', userGesture: true);
  await client.forget('exact-id', userGesture: true);
  await client.attach('exact-id', userGesture: true);
  await client.cancel();
  check(
    calls.map((value) => value['method']).join(',') == 'capabilities,list,select,persist,activate,deactivate,revoke,forget,attach,cancel',
    'method names',
  );
  check(
    (calls[2]['arguments'] as Map)['userGesture'] == false,
    'transport must not manufacture a gesture',
  );
  check((calls[3]['arguments'] as Map)['id'] == 'exact-id', 'opaque identity');
  check(
    !const AuthorizedWorkspaceCapabilities.unavailable().available,
    'missing platform',
  );
  check(
    const AuthorizedWorkspaceFailure('reauthorize', 'private').toString() ==
        'AuthorizedWorkspaceFailure(reauthorize)',
    'error does not log data',
  );
  print(
    jsonEncode({
      'status': 'PASS_SCOPED',
      'actualEtsSnapshots': count,
      'clientCalls': calls.length,
      'engineAttached': false,
      'scope': 'actual pure Dart decoder/client; Flutter transport not executed here',
    }),
  );
}
