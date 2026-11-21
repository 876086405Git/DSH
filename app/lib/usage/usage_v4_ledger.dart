import 'dart:convert';
import 'dart:math';

import 'usage_ledger.dart';

String usageV4Day(DateTime at) => usageDay(at.toUtc().add(const Duration(hours: 8)));

int? _token(Object? v) => v is int && v >= 0 && v <= 9007199254740991 ? v : null;

enum UsageTokenSource { chatLog, tavern, companion }

enum UsageOperation {
  runtimeDirect('runtime_direct'),
  runtimeProot('runtime_proot'),
  runtimeOther('runtime_other'),
  sshInitial('ssh_initial'),
  sshReconnect('ssh_reconnect'),
  relayInitial('relay_initial'),
  relayReconnect('relay_reconnect'),
  chatTurnLocal('chat_turn_local'),
  chatTurnRemote('chat_turn_remote'),
  chatFirstTextLocal('chat_first_text_local'),
  chatFirstTextRemote('chat_first_text_remote'),
  phoneTask('phone_task'),
  updateDownload('update_download'),
  updateInstall('update_install'),
  callConnect('call_connect'),
  callSession('call_session'),
  pluginInstall('plugin_install');

  const UsageOperation(this.wire);
  final String wire;
}

enum UsageOutcome { ready, failed, cancelled, unknown }

class UsageV4Tokens {
  final counts = List<int>.filled(13, 0);
  final values = List<int>.filled(10, 0);

  Map<String, Object?> get json => {'counts': counts, 'values': values};

  void restore(Map<String, dynamic> json) {
    counts.setAll(0, (json['counts'] as List).cast<int>());
    values.setAll(0, (json['values'] as List).cast<int>());
  }

  void record(Map<String, Object?>? usage, {bool partial = false}) {
    if (counts[0] >= 100000) {
      counts[12] = 1;
      return;
    }
    int classification(String key) {
      if (usage == null || !usage.containsKey(key) || usage[key] == null) return 3;
      final v = _token(usage[key]);
      return v == null ? 4 : (v == 0 ? 1 : 0);
    }

    counts[0]++;
    var inputStatus = classification('inputTokens');
    var outputStatus = classification('outputTokens');
    final rawIn = _token(usage?['inputTokens']);
    final rawOut = _token(usage?['outputTokens']);
    final rawRead = usage?['cacheReadTokens'];
    final rawWrite = usage?['cacheWriteTokens'];
    final read = _token(rawRead);
    final write = _token(rawWrite);
    final allIn = rawIn == null ? null : rawIn + (read ?? 0) + (write ?? 0);
    if (allIn != null &&
        (allIn > 9007199254740991 || (rawRead != null && read == null) || (rawWrite != null && write == null))) {
      inputStatus = 4;
    } else if (allIn != null && allIn > 0) {
      inputStatus = 0;
    }
    if (partial) {
      if (inputStatus <= 1) inputStatus = 2;
      if (outputStatus <= 1) outputStatus = 2;
    }
    counts[1 + inputStatus]++;
    counts[6 + outputStatus]++;

    void add(int index, int n) {
      const cap = 1000000000000;
      final total = values[index] + n;
      if (total > cap) counts[12] = 1;
      values[index] = min(cap, total);
    }

    if (inputStatus == 2 && allIn != null) add(8, allIn);
    if (outputStatus == 2 && rawOut != null) add(9, rawOut);
    final input = inputStatus <= 1 ? allIn : null;
    final output = outputStatus <= 1 ? rawOut : null;
    if (input != null) {
      add(0, input);
      add(4, rawIn!);
      if (read != null) add(5, read);
      if (write != null) add(6, write);
      if (read != null && write != null) values[7]++;
    }
    if (output != null) add(1, output);
    if (input != null && output != null) {
      counts[11]++;
      add(2, input);
      add(3, output);
    }
  }
}

class UsageV4Day {
  UsageV4Day(this.iid, {this.foreground = false, this.first = false});

  final String iid;
  bool foreground;
  bool first;
  String? snapshot;
  final tokens = {for (final source in UsageTokenSource.values) source: UsageV4Tokens()};
  final operations = <UsageOperation, List<int>>{};

  void operation(UsageOperation operation, UsageOutcome outcome, Duration elapsed) {
    final bins = operations.putIfAbsent(operation, () => List<int>.filled(16, 0));
    if (bins[0] == 100000) {
      bins[15] = 1;
      return;
    }
    bins[0]++;
    bins[1 + outcome.index]++;
    if (outcome != UsageOutcome.ready) return;
    const edges = [250, 500, 1000, 2000, 5000, 10000, 30000, 60000, 180000];
    final index = edges.indexWhere((ms) => elapsed.inMicroseconds <= ms * 1000);
    bins[index < 0 ? 14 : index + 5]++;
  }

  Map<String, Object?> get extra => {
    for (final source in UsageTokenSource.values.skip(1)) source.name: tokens[source]!.json,
    for (final entry in operations.entries) entry.key.wire: entry.value,
  };

  String seal(String day, UsageDevice device) => snapshot ??= jsonEncode({
    'v': 4,
    'iid': iid,
    'day': day,
    'app': device.app,
    'platform': 'android',
    'maker': device.maker.isEmpty ? '' : usageMaker(device.maker),
    'model': device.model.isEmpty ? '' : usageMaker(device.model),
    'rom': device.rom.isEmpty ? '' : usageMaker(device.rom),
    'base': [foreground ? 1 : 0, first ? 1 : 0],
    'chat_log': tokens[UsageTokenSource.chatLog]!.json,
    'extra': extra,
  });

  Map<String, Object?> get json => {
    'iid': iid,
    'foreground': foreground,
    'first': first,
    ...tokens[UsageTokenSource.chatLog]!.json,
    'extra': extra,
    'snapshot': snapshot,
  };
}

class UsageV4Ledger {
  final days = <String, UsageV4Day>{};
  String? _iid;
  DateTime? _since;
  bool _hadForeground = false;
  String? _latestDay;

  UsageV4Day? _record(DateTime now) {
    final day = usageV4Day(now);
    if (_latestDay case final latest? when day.compareTo(latest) < 0) return null;
    _latestDay = day;
    return days.putIfAbsent(day, () {
      if (_since == null || now.difference(_since!) >= usageIidLifetime) {
        _iid = newUsageIid();
        _since = now;
      }
      return UsageV4Day(_iid!);
    });
  }

  void foreground(DateTime now) {
    final day = _record(now);
    if (day == null || day.snapshot != null) return;
    day.foreground = true;
    if (!_hadForeground) {
      day.first = true;
      _hadForeground = true;
    }
  }

  void token(DateTime now, UsageTokenSource source, Map<String, Object?>? usage, {bool partial = false}) {
    final day = _record(now);
    if (day != null && day.snapshot == null) day.tokens[source]!.record(usage, partial: partial);
  }

  void operation(DateTime now, UsageOperation operation, UsageOutcome outcome, Duration elapsed) {
    final day = _record(now);
    if (day != null && day.snapshot == null) day.operation(operation, outcome, elapsed);
  }

  List<String> due(DateTime now) {
    final today = usageV4Day(now);
    if (_latestDay == null || today.compareTo(_latestDay!) > 0) _latestDay = today;
    final oldest = usageV4Day(now.subtract(const Duration(days: usageBackfillDays)));
    days.removeWhere((day, _) => day.compareTo(oldest) < 0);
    return days.keys.where((day) => day.compareTo(today) < 0).toList()..sort();
  }

  String encode() => jsonEncode({
    'iid': _iid,
    'since': _since?.millisecondsSinceEpoch,
    'hadForeground': _hadForeground,
    'latestDay': _latestDay,
    'days': days.map((key, value) => MapEntry(key, value.json)),
  });

  static UsageV4Ledger decode(String? raw) {
    final ledger = UsageV4Ledger();
    if (raw == null) return ledger;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      ledger._iid = data['iid'] as String?;
      if (data['since'] case final int since) ledger._since = DateTime.fromMillisecondsSinceEpoch(since);
      ledger._hadForeground = data['hadForeground'] as bool;
      ledger._latestDay = data['latestDay'] as String?;
      final days = data['days'] as Map<String, dynamic>;
      for (final entry in days.entries) {
        final item = entry.value as Map<String, dynamic>;
        final day = UsageV4Day(
          item['iid'] as String,
          foreground: item['foreground'] as bool,
          first: item['first'] as bool,
        );
        day.tokens[UsageTokenSource.chatLog]!.restore(item);
        if (item['extra'] case final Map<String, dynamic> extra) {
          for (final source in UsageTokenSource.values.skip(1)) {
            day.tokens[source]!.restore(extra[source.name] as Map<String, dynamic>);
          }
          for (final kind in UsageOperation.values) {
            if (extra[kind.wire] case final List values) day.operations[kind] = values.cast<int>();
          }
        }
        day.snapshot = item['snapshot'] as String?;
        ledger.days[entry.key] = day;
      }
      return ledger;
    } on Exception {
      return UsageV4Ledger();
    } on Error {
      return UsageV4Ledger();
    }
  }
}
