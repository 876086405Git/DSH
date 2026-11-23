// Device-local scheduling metadata. The native key is already a digest. Neither
// notice segments nor the model's output are accepted by these operations.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

class CompanionNoticeRate {
  CompanionNoticeRate(this._db) {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS notice_identity (id INTEGER PRIMARY KEY CHECK(id=1), secret BLOB NOT NULL);
      CREATE TABLE IF NOT EXISTS notice_day (day TEXT PRIMARY KEY, requests INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS notice_cooldown (key TEXT PRIMARY KEY, until_ms INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS notice_backoff (
        id INTEGER PRIMARY KEY CHECK(id=1), failures INTEGER NOT NULL, until_ms INTEGER NOT NULL
      );
    ''');
    if (_db.select('SELECT 1 FROM notice_identity').isEmpty) {
      final random = Random.secure();
      _db.execute('INSERT OR IGNORE INTO notice_identity VALUES (1,?)', [
        Uint8List.fromList(List.generate(32, (_) => random.nextInt(256))),
      ]);
    }
    _hmac = Hmac(sha256, _db.select('SELECT secret FROM notice_identity').single['secret'] as Uint8List);
  }

  factory CompanionNoticeRate.open(String rootPath) =>
      CompanionNoticeRate(sqlite3.open('$rootPath/notice-rate.sqlite'));

  final Database _db;
  late final Hmac _hmac;
  String fingerprint(String kind, String value) => _hmac.convert(utf8.encode(jsonEncode([kind, value]))).toString();
  static const dailyLimit = 300;
  static const cooldown = Duration(minutes: 2);
  static const _backoffMinutes = [2, 5, 15, 30];

  String _day(DateTime now) => now.toIso8601String().substring(0, 10);

  int availableAt(DateTime now) {
    final quota = _db.select('SELECT requests FROM notice_day WHERE day=?', [_day(now)]);
    final nextDay = quota.isNotEmpty && (quota.single['requests'] as int) >= dailyLimit
        ? DateTime(now.year, now.month, now.day + 1).millisecondsSinceEpoch
        : 0;
    final failure = _db.select('SELECT until_ms FROM notice_backoff WHERE id=1');
    final until = failure.isEmpty ? 0 : failure.single['until_ms'] as int;
    return nextDay > until ? nextDay : until;
  }

  Map<String, int> cooldowns(DateTime now) => {
    for (final row in _db.select('SELECT key,until_ms FROM notice_cooldown WHERE until_ms>?', [
      now.millisecondsSinceEpoch,
    ]))
      row['key'] as String: row['until_ms'] as int,
  };

  /// Atomic even if a retiring visit and a newly attached visit briefly share a folder.
  bool reserve(DateTime now, Iterable<String> keys) {
    final at = now.millisecondsSinceEpoch;
    _db.execute('BEGIN IMMEDIATE');
    try {
      if (availableAt(now) > at) {
        _db.execute('ROLLBACK');
        return false;
      }
      _db.execute('DELETE FROM notice_cooldown WHERE until_ms<=?', [at]);
      for (final key in keys) {
        if (_db.select('SELECT 1 FROM notice_cooldown WHERE key=?', [key]).isNotEmpty) {
          _db.execute('ROLLBACK');
          return false;
        }
        _db.execute('INSERT INTO notice_cooldown VALUES (?,?)', [key, at + cooldown.inMilliseconds]);
      }
      final day = _day(now);
      // Keep recent days across clock/timezone adjustments, without retaining an unbounded ledger.
      _db.execute('DELETE FROM notice_day WHERE day < ?', [_day(now.subtract(const Duration(days: 7)))]);
      _db.execute('INSERT INTO notice_day VALUES (?,1) ON CONFLICT(day) DO UPDATE SET requests=requests+1', [day]);
      _db.execute('COMMIT');
      return true;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  int failed(DateTime now) {
    final rows = _db.select('SELECT failures FROM notice_backoff WHERE id=1');
    final step = rows.isEmpty ? 0 : (rows.single['failures'] as int).clamp(0, _backoffMinutes.length - 1);
    final until = now.add(Duration(minutes: _backoffMinutes[step])).millisecondsSinceEpoch;
    _db.execute('INSERT OR REPLACE INTO notice_backoff VALUES (1,?,?)', [step + 1, until]);
    return until;
  }

  void succeeded() => _db.execute('DELETE FROM notice_backoff');
  void close() => _db.close();
}
