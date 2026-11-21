import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';

/// A controlled MethodChannel boundary. Its SQL is explicitly simulated native
/// evidence; these Flutter tests do not run Android, PackageManager or an Intent.
/// The real App must still create/read the original SQLite task and pass only
/// its identity across the boundary.
class MapPlatformPeer {
  MapPlatformPeer(this.database, this.store);
  static const channel = MethodChannel('dsh/companion_maps');
  static const target = <String, Object?>{
    'packageName': 'test.maps',
    'componentName': 'test.maps.View',
    'uid': 12001,
    'label': '实际候选地图',
  };
  final Database database;
  final CompanionMemoryStore store;
  final calls = <MethodCall>[];
  MemoryRow targets = {
    'kind': 'known',
    'targets': [target],
    'defaultTarget': target,
  };
  Future<void> Function(MethodCall)? before;
  Future<void> Function(MemoryRow)? onHandoff;
  String executorId = 'installation-A';
  var _scopes = 0;
  var _attempts = 0;
  final _openScopes = <String, String>{};

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    await before?.call(call);
    final args = call.arguments as Map<Object?, Object?>?;
    switch (call.method) {
      case 'capabilities':
        return {'executorId': executorId};
      case 'targets':
        return targets;
      case 'openScope':
        final scope = 'scope-${++_scopes}';
        final sourceSessionId = args!['sourceSessionId']! as String;
        _openScopes[scope] = sourceSessionId;
        database.execute('INSERT INTO companion_map_scopes(scope_id,source_session_id,closed) VALUES(?,?,0)', [
          scope,
          sourceSessionId,
        ]);
        return {'scopeId': scope};
      case 'closeScope':
        _openScopes.remove(args!['scopeId']);
        return null;
      case 'handoff':
        if (args!.keys.toSet().difference({'taskId', 'taskRev', 'scopeId'}).isNotEmpty || args.length != 3) {
          throw StateError('The channel must not receive an address or executable Intent');
        }
        final task = store.mapTask(args['taskId']! as String)!;
        if (task['task_rev'] != args['taskRev'] || _openScopes[args['scopeId']] != task['source_session_id']) {
          throw StateError('The App did not pass the original task and scope');
        }
        await onHandoff?.call(task);
        return null;
      default:
        throw StateError('Unexpected map method ${call.method}');
    }
  }

  String claim(MemoryRow task) {
    final attempt = 'native-observation-${++_attempts}';
    _receipt(task, attempt, 'claimed');
    database.execute('UPDATE companion_task_revisions SET state=?,wait_reason=? WHERE task_id=? AND task_rev=?', [
      'unknown',
      'map_handoff_pending',
      task['task_id'],
      task['task_rev'],
    ]);
    return attempt;
  }

  void returned(MemoryRow task, String attempt, {bool chooser = false}) {
    _receipt(
      task,
      attempt,
      'returned',
      outcome: chooser ? 'unknown' : 'succeeded',
      result: chooser ? 'chooser_shown' : 'handoff_dispatched',
    );
    // Updating the original revision does not change companion_tasks.current_rev.
    database.execute('UPDATE companion_task_revisions SET state=?,wait_reason=? WHERE task_id=? AND task_rev=?', [
      chooser ? 'waiting' : 'done',
      chooser ? 'map_target_choice' : null,
      task['task_id'],
      task['task_rev'],
    ]);
  }

  void blocked(MemoryRow task, String attempt) {
    _receipt(task, attempt, 'blocked', outcome: 'not_performed', result: 'not_dispatched');
    database.execute('UPDATE companion_task_revisions SET state=?,wait_reason=? WHERE task_id=? AND task_rev=?', [
      'waiting',
      'map_scope_closed',
      task['task_id'],
      task['task_rev'],
    ]);
  }

  void _receipt(MemoryRow task, String attempt, String event, {String? outcome, String? result}) {
    database.execute(
      '''INSERT INTO companion_task_receipts(
      task_id,task_rev,step_key,attempt_id,event_kind,executor_id,occurred_at_ms,outcome,detail_json)
      VALUES(?,?,'map.handoff',?,?,?,?,?,?)''',
      [
        task['task_id'],
        task['task_rev'],
        attempt,
        event,
        task['executor_id'],
        1795219200000,
        outcome,
        jsonEncode({'result': ?result}),
      ],
    );
  }
}
