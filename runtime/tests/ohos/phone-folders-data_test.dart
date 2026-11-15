import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../app/lib/runtime/authorized_workspaces.dart';
import '../../../app/lib/runtime/authorized_workspaces_channel.dart';

const folderId = '4caef624-b8cc-4b49-b135-271c455fbac2';
Map<String, Object?> record({
  String id = folderId,
  String authorization = 'selected',
  String nativeGrant = 'ready',
  int generation = 2,
  int nativeGeneration = 2,
}) => {
  'id': id,
  'uri': 'file://docs/storage/Users/currentUser/Projects/chosen',
  'name': 'chosen',
  'candidatePath': '/untrusted/path/must/not/be/the/workspace',
  'generation': generation,
  'authorization': authorization,
  'persistence': 'persisted',
  'nativeGrant': nativeGrant,
  'nativeGeneration': nativeGeneration,
  'nativeKey': 'boot:$folderId',
  'nodeAccess': 'unverified',
  'engineAttached': false,
};

// Dynamic access lets this same test run against the pre-change real decoder;
// absence of the new data-layer accessor is a behavioral red, not a fake stub.
String? logicalRoot(Map<String, Object?> raw) {
  return workspaceRoot(AuthorizedWorkspace.fromChannel(raw));
}

String? workspaceRoot(AuthorizedWorkspace workspace) {
  final dynamic value = workspace;
  return value.logicalRoot as String?;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'ready selected or activated grant exposes the existing logical Node root',
    () {
      expect(logicalRoot(record()), '/workspaces/$folderId');
      expect(
        logicalRoot(record(authorization: 'activated')),
        '/workspaces/$folderId',
      );
      expect(
        logicalRoot({...record(), 'candidatePath': null}),
        '/workspaces/$folderId',
      );
    },
  );
  test(
    'selection alone and retired native generations expose no usable root',
    () {
      for (final grant in [
        'unattached',
        'draining',
        'drained',
        'quarantined',
      ]) {
        expect(logicalRoot(record(nativeGrant: grant)), isNull);
      }
      expect(logicalRoot(record(generation: 3)), isNull);
      expect(logicalRoot(record(generation: 0, nativeGeneration: 0)), isNull);
    },
  );
  test('restart and background invalidation cannot regain authority from saved URI', () {
    for (final state in [
      'needsRestore',
      'needsActivation',
      'needsReauthorization',
      'needsRevalidation',
    ]) {
      expect(logicalRoot(record(authorization: state)), isNull);
    }
    expect(logicalRoot(record(id: '../outside')), isNull);
    expect(logicalRoot(record(id: '/absolute')), isNull);
  });
  test(
    'logical coordinates do not claim engine admission or physical path access',
    () {
      final value = AuthorizedWorkspace.fromChannel(record());
      expect(value.engineAttached, isFalse);
      expect(value.nodeAccess, 'unverified');
      expect(logicalRoot(record()), isNot(value.candidatePath));
      expect(
        () => AuthorizedWorkspace.fromChannel({
          ...record(),
          'engineAttached': true,
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'actual ETS wire traverses MethodChannel without granting a candidate path',
    () async {
      final input = Platform.environment['OHOS_PHONE_FOLDERS_WIRE'];
      expect(input, isNotNull, reason: 'requires the actual native gate wire');
      final rows = (jsonDecode(File(input!).readAsStringSync()) as List)
          .cast<Map<String, dynamic>>();
      const channel = MethodChannel('dsh/authorized-workspaces');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      Future<AuthorizedWorkspace> read(Map<String, dynamic> row) async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'list');
          return row['value'];
        });
        return (await MethodAuthorizedWorkspaces().list()).workspaces.single;
      }

      final selection = await read(
        rows.firstWhere((row) => row['method'] == 'select'),
      );
      expect(workspaceRoot(selection), isNull);
      final attached = await read(
        rows.firstWhere((row) => row['method'] == 'attach'),
      );
      expect(attached.candidatePath, isNull);
      expect(workspaceRoot(attached), '/workspaces/${attached.id}');
      final restored = await read(
        rows.firstWhere((row) => row['method'] == 'list'),
      );
      expect(restored.authorization, WorkspaceAuthorization.needsRestore);
      expect(workspaceRoot(restored), isNull);
      final activated = await read(
        rows.lastWhere((row) => row['method'] == 'attach'),
      );
      expect(activated.id, attached.id);
      expect(workspaceRoot(activated), workspaceRoot(attached));
      final revoked = await read(
        rows.lastWhere((row) => row['method'] == 'revoke'),
      );
      expect(workspaceRoot(revoked), isNull);
      expect(revoked.persistence, WorkspacePersistence.absent);
      expect(activated.engineAttached, isFalse);
      expect(activated.nodeAccess, 'unverified');
    },
  );
}
