import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/src/authoring.dart';
import 'package:dsh_tavern/src/authoring_authority.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Database database;
  late ChatStore store;
  late AuthoringAuthority owner;

  void open() {
    database = sqlite3.open('${root.path}/tavern.sqlite3');
    store = ChatStore.fromDatabase(database);
    owner = AuthoringAuthority(root: root, store: store);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dsh-authoring-payload-');
    open();
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  AuthoringWriteTicket ticket(String id, AuthoringResourceSnapshot before, AuthoringResourceSnapshot after) =>
      AuthoringWriteTicket(
        request: AuthoringWriteRequest(
          domainId: owner.domainId,
          operationId: id,
          physicalResourceId: 'character:sample',
          parameters: {'method': 'writeCharacter', 'after': after.toJson()},
        ),
        before: before,
        after: after,
        artifacts: const ['characters/.staging-sample'],
      );

  void adopt(AuthoringWriteTicket value) {
    expect(owner.prepare(value), isNull);
    value.enteredEffect = true;
    value.knownAdopted = true;
    owner.adopted(value);
    owner.publish(value);
  }

  test('one retained body restores exact snapshots and same-parameter replay after reopen', () async {
    const before = AuthoringResourceSnapshot(present: false);
    const after = AuthoringResourceSnapshot(
      present: true,
      rawText: '\ufeff{ "name": "Sample", "note": "海🌊" }\r\n',
      identityText: '\ufeff{"version":1}',
    );
    final first = ticket('first', before, after);
    adopt(first);
    final revision = owner.listRevisions('character:sample').single;
    expect(owner.readOperation('first', domainId: first.request.domainId)!.request, first.request.parameters);
    expect(store.readAuthoringResource('character:sample')!.snapshot, after.toJson());
    expect(
      (database.select('SELECT char(1) || raw_text AS raw_text FROM authoring_payloads').single['raw_text']! as String)
          .substring(1),
      after.rawText,
    );
    final stored = database.select('SELECT request_json, after_json FROM authoring_operations').single;
    expect(jsonDecode(stored['request_json']! as String), {'method': 'writeCharacter'});
    expect((jsonDecode(stored['after_json']! as String) as Map<String, Object?>)['rawText'], isNull);

    await store.close();
    open();
    final operation = owner.readOperation('first', domainId: first.request.domainId)!;
    expect(operation.before, before.toJson());
    expect(operation.after, after.toJson());
    expect(operation.request, first.request.parameters);
    expect(owner.replay(first.request)!.committed, isTrue);
    expect(
      owner
          .revisionSnapshot(
            'character:sample',
            TavernAuthorityRevision(domainId: revision.domainId, revision: revision.revision),
          )!
          .rawText,
      after.rawText,
    );
    expect(database.select('SELECT COUNT(*) AS n FROM authoring_payloads').single['n'], 1);
    final conflicting = AuthoringWriteRequest(
      domainId: first.request.domainId,
      operationId: 'first',
      physicalResourceId: 'character:sample',
      parameters: {'method': 'writeCharacter', 'after': before.toJson()},
    );
    expect(() => owner.replay(conflicting), throwsA(isA<TavernAuthoringException>()));
    expect(database.select('PRAGMA foreign_key_check'), isEmpty);
  });

  test('legacy inline history reads unchanged when a later write adopts shared bodies', () {
    const before = AuthoringResourceSnapshot(present: false);
    const original = AuthoringResourceSnapshot(present: true, rawText: '\ufeff{"name":"Original"}', identityText: '{}');
    const changed = AuthoringResourceSnapshot(present: true, rawText: '{"name":"Changed"}', identityText: '{}');
    final request = {'method': 'writeCharacter', 'after': original.toJson()};
    database.execute(
      'INSERT INTO authoring_resources (physical_resource_id, revision, present, raw_text, identity_text) '
      'VALUES (?, 2, 1, ?, ?)',
      ['character:sample', original.rawText, original.identityText],
    );
    database.execute(
      'INSERT INTO authoring_operations (domain_id, operation_id, physical_resource_id, request_json, base_revision, '
      'before_json, after_json, artifacts_json, state, adopted_revision, created_at, updated_at) '
      "VALUES (?, 'legacy', 'character:sample', ?, 1, ?, ?, '[]', 'published', 2, 0, 0)",
      [owner.domainId, jsonEncode(request), jsonEncode(before.toJson()), jsonEncode(original.toJson())],
    );
    expect(owner.readOperation('legacy', domainId: owner.domainId)!.request, request);
    final next = ticket('next', original, changed);
    adopt(next);
    final previous = owner.readOperation('legacy', domainId: owner.domainId)!;
    expect(previous.after, original.toJson());
    expect(previous.request, request);
    expect(owner.readOperation('next', domainId: owner.domainId)!.before, original.toJson());
    expect(store.readAuthoringResource('character:sample')!.snapshot, changed.toJson());
    expect(database.select('SELECT raw_text_id FROM authoring_resources').single['raw_text_id'], isNotNull);
    expect(database.select('PRAGMA foreign_key_check'), isEmpty);
  });

  test('failed prepare rolls back new bodies and observed replacements collect only unreferenced text', () {
    const first = AuthoringResourceSnapshot(present: true, rawText: 'first', identityText: '{}');
    const second = AuthoringResourceSnapshot(present: true, rawText: 'second', identityText: '{}');
    const third = AuthoringResourceSnapshot(present: true, rawText: 'third', identityText: '{}');
    owner.observe('character:sample', first);
    owner.observe('character:sample', second);
    expect(database.select('SELECT raw_text FROM authoring_payloads').map((row) => row['raw_text']), ['second']);
    database.execute("""
      CREATE TRIGGER fail_prepare BEFORE INSERT ON authoring_operations
      BEGIN SELECT RAISE(ABORT, 'fixture'); END;
    """);
    expect(() => owner.prepare(ticket('failed', second, third)), throwsA(isA<SqliteException>()));
    expect(database.select('SELECT raw_text FROM authoring_payloads').map((row) => row['raw_text']), ['second']);
    expect(store.readAuthoringResourceHead('character:sample')!.pendingOperationId, isNull);
    database.execute('DROP TRIGGER fail_prepare');
    adopt(ticket('kept', second, third));
    owner.observe('character:sample', first);
    expect(
      database.select('SELECT raw_text FROM authoring_payloads').map((row) => row['raw_text']),
      unorderedEquals(['second', 'third', 'first']),
    );
    expect(owner.readOperation('kept', domainId: owner.domainId)!.before, second.toJson());
    expect(owner.readOperation('kept', domainId: owner.domainId)!.after, third.toJson());
    expect(database.select('PRAGMA foreign_key_check'), isEmpty);
  });
}
