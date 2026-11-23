// Only the Android listener owns consent and the in-memory notification inbox.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum CompanionNoticeLevel { off, glance, remember }

class CompanionNoticeStatus {
  const CompanionNoticeStatus({
    required this.enabled,
    required this.granted,
    required this.unlocked,
    required this.levels,
    required this.received,
    required this.judged,
    required this.said,
    required this.epoch,
    required this.consentEpoch,
  });

  final bool enabled, granted, unlocked;
  final Map<String, CompanionNoticeLevel> levels;
  final int received, judged, said, epoch, consentEpoch;
  bool get readable => enabled && granted && unlocked;
  CompanionNoticeLevel level(String pkg) => levels[pkg] ?? CompanionNoticeLevel.off;

  factory CompanionNoticeStatus.fromMap(Map value) => CompanionNoticeStatus(
    enabled: value['enabled'] as bool,
    granted: value['granted'] as bool,
    unlocked: value['unlocked'] as bool,
    levels: {
      for (final entry in (value['levels'] as Map).entries)
        entry.key as String: CompanionNoticeLevel.values.byName(entry.value as String),
    },
    received: value['received'] as int,
    judged: value['judged'] as int,
    said: value['said'] as int,
    epoch: value['epoch'] as int,
    consentEpoch: value['consentEpoch'] as int,
  );
}

typedef CompanionNoticeApp = ({String pkg, String name, int count, Uint8List? icon});
typedef CompanionNoticePending = ({String pkg, String key, int atMs});
typedef CompanionNoticeSegment = ({String text, int atMs, String? personId});
typedef CompanionNoticeItem = ({String key, List<CompanionNoticeSegment> segments});

class CompanionNoticeBatch {
  const CompanionNoticeBatch({
    required this.pkg,
    required this.appName,
    required this.level,
    required this.epoch,
    required this.consentEpoch,
    required this.items,
  });

  final String pkg, appName;
  final CompanionNoticeLevel level;
  final int epoch, consentEpoch;
  final List<CompanionNoticeItem> items;
}

abstract interface class CompanionNotices {
  Stream<int> get signals;
  Future<CompanionNoticeStatus> status();
  Future<CompanionNoticeStatus> setEnabled(bool enabled);
  Future<CompanionNoticeStatus> setLevel(String pkg, CompanionNoticeLevel level);
  Future<List<CompanionNoticeApp>> recentApps();
  Future<List<CompanionNoticePending>> pending();
  Future<CompanionNoticeBatch?> takeBatch(String pkg, List<String> keys, int epoch);
  Future<bool> record(int epoch, {int judged = 0, int said = 0});
}

class CompanionNoticeChannel implements CompanionNotices {
  CompanionNoticeChannel([this._channel = const MethodChannel('dsh/companion')]) {
    _signals = StreamController<int>.broadcast(
      onListen: () => _channel.setMethodCallHandler((call) async {
        if (call.method != 'noticeSignal') throw MissingPluginException();
        _signals.add((call.arguments as Map)['epoch'] as int);
      }),
      onCancel: () => _channel.setMethodCallHandler(null),
    );
  }

  static final instance = CompanionNoticeChannel();
  final MethodChannel _channel;
  late final StreamController<int> _signals;

  @override
  Stream<int> get signals => _signals.stream;

  Future<CompanionNoticeStatus> _status(String method, [Object? arguments]) async =>
      CompanionNoticeStatus.fromMap((await _channel.invokeMapMethod<Object?, Object?>(method, arguments))!);

  @override
  Future<CompanionNoticeStatus> status() => _status('notices.status');

  @override
  Future<CompanionNoticeStatus> setEnabled(bool enabled) => _status('notices.setEnabled', {'enabled': enabled});

  @override
  Future<CompanionNoticeStatus> setLevel(String pkg, CompanionNoticeLevel level) =>
      _status('notices.setLevel', {'pkg': pkg, 'level': level.name});

  @override
  Future<List<CompanionNoticeApp>> recentApps() async {
    final rows = await _channel.invokeListMethod<Object?>('notices.recentApps');
    return [
      for (final row in rows!.cast<Map>())
        (
          pkg: row['pkg'] as String,
          name: row['name'] as String,
          count: row['count'] as int,
          icon: row['icon'] as Uint8List?,
        ),
    ];
  }

  @override
  Future<List<CompanionNoticePending>> pending() async {
    final rows = await _channel.invokeListMethod<Object?>('notices.pending');
    return [
      for (final row in rows!.cast<Map>())
        (pkg: row['pkg'] as String, key: row['key'] as String, atMs: row['atMs'] as int),
    ];
  }

  @override
  Future<CompanionNoticeBatch?> takeBatch(String pkg, List<String> keys, int epoch) async {
    final batch = await _channel.invokeMapMethod<Object?, Object?>('notices.takeBatch', {
      'pkg': pkg,
      'keys': keys,
      'epoch': epoch,
    });
    if (batch == null) return null;
    final seen = <String>{};
    final items = <CompanionNoticeItem>[];
    for (final row in (batch['items'] as List).cast<Map>()) {
      final key = row['key'] as String;
      final segments = [
        for (final part in (row['segments'] as List).cast<Map>())
          (text: part['text'] as String, atMs: part['atMs'] as int, personId: part['personId'] as String?),
      ];
      if (!keys.contains(key) || !seen.add(key) || segments.isEmpty || segments.length > 10) {
        throw const FormatException('Invalid notice batch item');
      }
      items.add((key: key, segments: segments));
    }
    if (batch['pkg'] != pkg || batch['epoch'] != epoch || items.isEmpty || items.length > 8) {
      throw const FormatException('Invalid notice batch identity');
    }
    return CompanionNoticeBatch(
      pkg: pkg,
      epoch: epoch,
      consentEpoch: batch['consentEpoch'] as int,
      appName: batch['appName'] as String,
      level: CompanionNoticeLevel.values.byName(batch['level'] as String),
      items: items,
    );
  }

  @override
  Future<bool> record(int epoch, {int judged = 0, int said = 0}) async =>
      (await _channel.invokeMethod<bool>('notices.record', {'epoch': epoch, 'judged': judged, 'said': said}))!;
}

final companionNoticesProvider = Provider<CompanionNotices>((ref) => CompanionNoticeChannel.instance);
