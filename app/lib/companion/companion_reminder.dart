import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef CompanionReminderClock = ({int utcMs, String zoneId, int offsetSeconds});
typedef CompanionReminderCommand = ({String operation, String? text, String? when, String? target});
typedef CompanionReminderPart = ({int itemNo, String raw, CompanionReminderCommand? command});
typedef CompanionReminderResult = ({MemoryRow task, int acceptedRev, String executorId});

final companionRemindersProvider = Provider((_) => const CompanionReminders());

// These complete command forms are deliberately small. Unparsed clauses are
// retained for clarification; a word such as “提醒” alone grants no action.
List<CompanionReminderPart> parseCompanionReminders(String input) {
  // A separator inside quoted dialogue is not a new instruction to the phone.
  // An unfinished quote stays one clause; do not guess where it ends.
  const quotes = {'“': '”', '‘': '’', '「': '」', '『': '』', '"': '"', "'": "'"};
  final separator = RegExp(r'[；;\n]+|[，,]\s*再');
  final clauses = <String>[];
  var start = 0;
  String? closeQuote;
  for (var index = 0; index < input.length; index++) {
    final character = input[index];
    if (character == "'" &&
        index > 0 &&
        index + 1 < input.length &&
        RegExp(r'[A-Za-z]').hasMatch(input[index - 1]) &&
        RegExp(r'[A-Za-z]').hasMatch(input[index + 1])) {
      continue;
    }
    if (closeQuote != null) {
      if (character == r'\' && (closeQuote == '"' || closeQuote == "'")) {
        index++;
      } else if (character == closeQuote) {
        closeQuote = null;
      }
      continue;
    }
    closeQuote = quotes[character];
    if (closeQuote != null) {
      continue;
    }
    final match = separator.matchAsPrefix(input, index);
    if (match == null) {
      continue;
    }
    clauses.add(input.substring(start, index));
    start = match.end;
    index = match.end - 1;
  }
  clauses.add(input.substring(start));
  final parts = <CompanionReminderPart>[];
  for (var index = 0; index < clauses.length; index++) {
    final raw = clauses[index].trim();
    final text = raw
        .replaceFirst(RegExp(r'[。.!！]+$'), '')
        .replaceFirst(RegExp(r'^(?:请帮我|请|帮我)?(?:现实中|现实里|在我的手机上)?\s*'), '')
        .replaceFirst(RegExp(r'^(?:另外)?再加一条\s*'), '');
    CompanionReminderCommand? command;
    final before = RegExp(r'^(.+?)提醒我(.*)$').firstMatch(text);
    final after = RegExp(r'^提醒我(.*)$').firstMatch(text);
    final amend = RegExp(r'^(?:把(.+?)的提醒|提醒)改(?:到|成)?(.+)$').firstMatch(text);
    final shortAmend = RegExp(r'^改(?:到|成)?(.+)$').firstMatch(text);
    final cancel = RegExp(r'^取消(?:(.+?)的)?提醒$').firstMatch(text);
    final english = RegExp(r'^remind me at (.+?) to (.+)$', caseSensitive: false).firstMatch(text);
    if (cancel != null || text == '不用提醒了' || text == '取消那条提醒') {
      command = (operation: 'cancel', text: null, when: null, target: cancel?.group(1));
    } else if (amend != null && _reminderTime(amend.group(2)!) != null) {
      command = (operation: 'amend', text: null, when: amend.group(2), target: amend.group(1));
    } else if (shortAmend != null && _reminderTime(shortAmend.group(1)!) != null) {
      command = (operation: 'amend', text: null, when: shortAmend.group(1), target: null);
    } else if (english != null && _reminderTime(english.group(1)!) != null) {
      command = (operation: 'create', text: english.group(2)!.trim(), when: english.group(1), target: null);
    } else if (before != null && _reminderTime(before.group(1)!) != null) {
      command = (operation: 'create', text: before.group(2)!.trim(), when: before.group(1), target: null);
    } else if (after != null && after.group(1)!.trim().isNotEmpty) {
      // A bare explicit request is saved as waiting for its date/time. It is
      // never scheduled using a default hour or a time guessed from its text.
      command = (operation: 'create', text: after.group(1)!.trim(), when: '', target: null);
    } else if (amend != null ||
        english != null ||
        text.startsWith('那条提醒改') ||
        (before != null && RegExp(r'^(今天|明天|后天|明早|明晚|周|下周|下下周|下个月|\d{4}-)').hasMatch(before.group(1)!))) {
      command = (operation: 'clarify', text: null, when: null, target: null);
    }
    parts.add((itemNo: index, raw: raw, command: command));
  }
  return parts;
}

typedef _ReminderTime = ({String? date, String? time, String? zone});

_ReminderTime? _reminderTime(String value) {
  final text = value.trim().replaceFirstMapped(
    RegExp(r'^(today|tomorrow)\b', caseSensitive: false),
    (match) => match.group(1)!.toLowerCase() == 'today' ? '今天' : '明天',
  );
  if (text.isEmpty) {
    return (date: null, time: null, zone: null);
  }
  final match = RegExp(
    r'^(今天|明天|后天|明早|明晚|\d{4}-\d{2}-\d{2})?\s*'
    r'(凌晨|早上|上午|中午|下午|晚上)?\s*'
    r'(\d{1,2}|[零一二两三四五六七八九十]{1,3})?'
    r'(?:(?:[:：](\d{2})(?::(\d{2}))?)|(?:点(?:(半)|([零一二两三四五六七八九十\d]{1,3})分?)?))?'
    r'(?:\s+(UTC|[A-Za-z_]+(?:/[A-Za-z0-9_+\-]+)+|[+\-]\d{2}:\d{2}))?$',
  ).firstMatch(text);
  if (match == null) {
    return null;
  }
  final date = match.group(1);
  var period = match.group(2);
  if (date == '明早') {
    period = '早上';
  }
  if (date == '明晚') {
    period = '晚上';
  }
  var hour = _clockNumber(match.group(3));
  final minuteText = match.group(4) ?? match.group(7);
  final minuteNumber = _clockNumber(minuteText);
  if (minuteText != null && minuteNumber == null) {
    return null;
  }
  final minute = match.group(6) != null ? 30 : minuteNumber ?? 0;
  final second = int.tryParse(match.group(5) ?? '0')!;
  if (hour == null) {
    return date == null ? null : (date: date, time: null, zone: match.group(8));
  }
  // Clock digits need an actual clock delimiter; “明天八” is incomplete.
  if (!RegExp(r'[:：点]').hasMatch(text)) {
    return null;
  }
  if (period == '下午' || period == '晚上') {
    if (hour < 1 || hour > 12 || (period == '晚上' && hour == 12)) {
      return null;
    }
    if (hour < 12) {
      hour += 12;
    }
  } else if (period == '中午') {
    if (hour == 1) {
      hour = 13;
    }
    if (hour < 11 || hour > 13) {
      return null;
    }
  } else if (period != null && hour > 11) {
    return null;
  }
  if (hour > 23 || minute > 59 || second > 59) {
    return null;
  }
  final time =
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}'
      '${second == 0 ? '' : ':${second.toString().padLeft(2, '0')}'}';
  return (date: date, time: time, zone: match.group(8));
}

int? _clockNumber(String? text) {
  if (text == null) {
    return null;
  }
  final digits = int.tryParse(text);
  if (digits != null) {
    return digits;
  }
  const numbers = {'零': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9};
  if (numbers.containsKey(text)) {
    return numbers[text];
  }
  final parts = text.split('十');
  if (parts.length != 2) {
    return null;
  }
  final tens = parts[0].isEmpty ? 1 : numbers[parts[0]];
  final units = parts[1].isEmpty ? 0 : numbers[parts[1]];
  return tens == null || units == null ? null : tens * 10 + units;
}

String? _reminderDate(String? word, MemoryRow source) {
  if (word == null) {
    return null;
  }
  final days = switch (word) {
    '今天' => 0,
    '明天' || '明早' || '明晚' => 1,
    '后天' => 2,
    _ => null,
  };
  if (days != null) {
    final seconds = source['offset_seconds'] as int?;
    if (seconds == null) {
      return null;
    }
    final local = DateTime.fromMillisecondsSinceEpoch((source['said_at_utc']! as int) + seconds * 1000, isUtc: true);
    return DateTime.utc(local.year, local.month, local.day + days).toIso8601String().substring(0, 10);
  }
  final date = DateTime.tryParse('${word}T00:00:00Z');
  return date != null && date.toIso8601String().startsWith(word) ? word : null;
}

/// The phone stores the contract first. Only the private native executor may
/// register/cancel an alarm and write its receipt; a wake acknowledgement is
/// never a receipt for the action itself.
class CompanionReminders {
  const CompanionReminders({this.channel = const MethodChannel('dsh/companion_reminders')});
  final MethodChannel channel;

  Future<String> executorId() async =>
      (await channel.invokeMapMethod<String, Object?>('capabilities'))!['executorId']! as String;

  Future<CompanionReminderClock> clock() async {
    final value = (await channel.invokeMapMethod<String, Object?>('clock'))!;
    return (
      utcMs: value['utcMs']! as int,
      zoneId: value['zoneId']! as String,
      offsetSeconds: value['offsetSeconds']! as int,
    );
  }

  Future<Map<String, Object?>> resolve(String date, String time, String zone, {int? selectedOffsetSeconds}) async =>
      (await channel.invokeMapMethod<String, Object?>('resolve', {
        'localDate': date,
        'localTime': time,
        'zoneId': zone,
        'selectedOffsetSeconds': ?selectedOffsetSeconds,
      }))!;

  Future<CompanionReminderSpec> specification(
    MemoryRow source,
    CompanionReminderCommand command, {
    MemoryRow? previous,
    int? selectedOffsetSeconds,
  }) async {
    final parsed = _reminderTime(command.when ?? '')!;
    final wording = command.text ?? (previous?['reminder_text'] as String?);
    final text = wording == '' ? null : wording;
    final date = parsed.date == null ? (previous?['local_date'] as String?) : _reminderDate(parsed.date, source);
    final time = parsed.time ?? (previous?['local_time'] as String?);
    final zone = parsed.zone ?? (previous?['zone_id'] as String?) ?? (source['zone_id'] as String?);
    String? missing;
    if (text == null || text.isEmpty) {
      missing = 'text_missing';
    } else if (date == null) {
      missing = 'date_missing';
    } else if (time == null) {
      missing = 'time_missing';
    } else if (zone == null) {
      missing = 'zone_missing';
    }
    if (missing != null) {
      return CompanionReminderSpec(text: text, localDate: date, localTime: time, zoneId: zone, waitReason: missing);
    }
    // Relative words use the original phone's local date. A different named
    // zone needs an explicit date; no offset-to-region guess is made.
    if (parsed.date != null &&
        !parsed.date!.startsWith(RegExp(r'\d')) &&
        parsed.zone != null &&
        zone != source['zone_id']) {
      return CompanionReminderSpec(text: text, localTime: time, zoneId: zone, waitReason: 'date_missing');
    }
    final resolved = await resolve(date!, time!, zone!, selectedOffsetSeconds: selectedOffsetSeconds);
    final moments = resolved['moments']! as List;
    if (resolved['kind'] != 'unique') {
      return CompanionReminderSpec(
        text: text,
        localDate: date,
        localTime: time,
        zoneId: zone,
        waitReason: resolved['kind'] == 'gap' ? 'time_gap' : 'time_overlap',
      );
    }
    final moment = moments.single as Map;
    return CompanionReminderSpec(
      text: text,
      localDate: date,
      localTime: time,
      zoneId: zone,
      epochMs: moment['epochMs']! as int,
      offsetSeconds: moment['offsetSeconds']! as int,
    );
  }

  MemoryRow? target(CompanionMemoryStore store, String sourceSession, CompanionReminderCommand command) {
    final candidates = store
        .tasks(sourceSessionId: sourceSession)
        .where(
          (task) =>
              task['kind'] == 'phone.reminder' &&
              task['cancel_requested'] == 0 &&
              (command.target == null || task['reminder_text'] == command.target),
        )
        .toList();
    return candidates.length == 1 ? candidates.single : null;
  }

  Future<CompanionReminderResult> submit({
    required CompanionMemoryStore store,
    required MemoryRow source,
    required CompanionReminderPart part,
    required String roomMode,
    required bool Function() isCurrent,
    String? hostKey,
    String? hostSessionId,
    MemoryRow? previous,
    int? selectedOffsetSeconds,
  }) async {
    final command = part.command!;
    final id = source['id']! as String;
    final sourceRev = source['source_rev']! as int;
    final accepted = store.taskForCommand(id, part.itemNo);
    if (accepted == null && !isCurrent()) {
      throw const DshClosedException('Reminder command is no longer current');
    }
    final executor = await executorId();
    if (accepted == null && !isCurrent()) {
      throw const DshClosedException('Reminder command is no longer current');
    }
    if (accepted == null && previous != null && previous['executor_id'] != executor) {
      throw PlatformException(code: 'reminder_executor_changed');
    }
    MemoryRow task;
    if (accepted != null) {
      // A receipt may have been lost, or a later instruction may have revised
      // the contract. This old command must not be interpreted a second time.
      task = accepted;
    } else if (command.operation == 'cancel') {
      task = store.cancelReminder(
        taskId: previous!['task_id']! as String,
        expectedTaskRev: previous['task_rev']! as int,
        messageId: id,
        expectedSourceRev: sourceRev,
        itemNo: part.itemNo,
      );
    } else {
      final spec = await specification(
        source,
        command,
        previous: previous,
        selectedOffsetSeconds: selectedOffsetSeconds,
      );
      if (!isCurrent()) {
        throw const DshClosedException('Reminder command is no longer current');
      }
      if (command.operation == 'amend') {
        task = store.amendReminder(
          taskId: previous!['task_id']! as String,
          expectedTaskRev: previous['task_rev']! as int,
          messageId: id,
          expectedSourceRev: sourceRev,
          itemNo: part.itemNo,
          reminder: spec,
        );
      } else {
        task = store.createReminderFromMessage(
          messageId: id,
          expectedSourceRev: sourceRev,
          itemNo: part.itemNo,
          roomMode: roomMode,
          hostKey: hostKey,
          hostSessionId: hostSessionId,
          executorId: executor,
          reminder: spec,
        );
      }
    }
    final acceptedRev = task['task_rev']! as int;
    if (task['executor_id'] == executor &&
        task['state'] != 'done' &&
        task['state'] != 'cancelled' &&
        (task['epoch_ms'] != null || task['operation'] == 'amend' || task['cancel_requested'] == 1)) {
      await wake(task['task_id']! as String);
    }
    return (task: store.task(task['task_id']! as String)!, acceptedRev: acceptedRev, executorId: executor);
  }

  Future<void> wake(String taskId) async {
    try {
      await channel.invokeMethod<Object?>('wake', {'taskId': taskId}).timeout(const Duration(seconds: 3));
    } on TimeoutException {
      // The executor may still be working. The original task is queried later.
    } on PlatformException {
      // Nothing in a channel error proves whether a physical action happened.
    } on MissingPluginException {
      // An unavailable executor leaves the accepted task visible, never done.
    }
  }

  Future<void> openSettings(String kind) => channel.invokeMethod<void>('openSettings', {'kind': kind});

  Future<void> recover() async {
    try {
      // A queued recovery job is only a future opportunity, not an alarm receipt.
      await channel.invokeMethod<Object?>('recover');
    } on PlatformException {
      // Existing task records remain queryable when the executor is unavailable.
    } on MissingPluginException {
      // Other platforms still use ordinary companion chat.
    }
  }
}
