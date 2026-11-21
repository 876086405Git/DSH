// 轻量模式 (docs/design/companion.md §7): she talks to DeepSeek straight from
// the phone, with no engine and no host. The same Messages API the engine's
// DeepSeek adapter uses (@deepseek-ai/dsh-llm-deepseek), with the API key
// saved in the app; her conversation is a small file next to the pack.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'companion_context.dart';

const companionLightEndpoint = 'https://api.deepseek.com/anthropic/v1/messages';

/// The fast model of the official route (text and images); thinking off, so a
/// line comes back as quickly as she would say it.
const companionLightModel = 'deepseek-flash';

/// One verbatim transcript line. Request-only context is assembled separately.
class CompanionLine {
  const CompanionLine.user(this.text, {this.legacyText}) : fromHer = false;
  const CompanionLine.her(this.text) : fromHer = true, legacyText = null;

  static CompanionLine? fromJson(Object? json, {int version = 2}) {
    if (json is! Map) return null;
    final text = json['text'];
    if (text is! String || text.isEmpty) return null;
    final migrated = companionMigrateLegacyLine(text, version: version, user: json['role'] == 'user');
    return switch (json['role']) {
      'user' => CompanionLine.user(
        migrated.text,
        legacyText: migrated.legacyText ?? (json['legacyText'] is String ? json['legacyText'] as String : null),
      ),
      'assistant' => CompanionLine.her(text),
      _ => null,
    };
  }

  final bool fromHer;
  final String text;

  /// Lossless backup for a narrowly recognized v1 generated prefix.
  final String? legacyText;

  String get role => fromHer ? 'assistant' : 'user';

  Map<String, Object?> toJson() => {'role': role, 'text': text, if (legacyText != null) 'legacyText': legacyText};
}

enum CompanionLightFailure { noKey, badKey, busy, network, server }

class CompanionLightError implements Exception {
  const CompanionLightError(this.failure, [this.detail]);

  final CompanionLightFailure failure;
  final String? detail;

  @override
  String toString() => 'CompanionLightError(${failure.name}${detail == null ? '' : ': $detail'})';
}

/// Her reply to [lines], as text deltas. Cancelling the subscription drops the
/// request; [client] is the caller's to close.
///
/// [onUsage] hears the tokens the API reported for a reply that finished
/// (input with its cached part, and output), once; a reply that reported none,
/// or didn't finish, says nothing.
Stream<String> streamCompanionReply({
  required http.Client client,
  required String apiKey,
  required String system,
  required List<CompanionLine> lines,
  CompanionTurnContext? context,
  int maxTokens = 800,
  void Function(int input, int output)? onUsage,
  void Function(Map<String, Object?> usage, {required bool partial})? onUsageSettled,
}) async* {
  final observed = <String, Object?>{};
  var finished = false;
  try {
    final request = http.Request('POST', Uri.parse(companionLightEndpoint))
      ..headers.addAll({
        'content-type': 'application/json',
        'accept': 'text/event-stream',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      })
      ..body = jsonEncode({
        'model': companionLightModel,
        'stream': true,
        'max_tokens': maxTokens,
        'thinking': {'type': 'disabled'},
        'system': system,
        'messages': companionRequestMessages([
          for (final line in lines) (role: line.role, text: line.text),
        ], context: context),
      });
    final http.StreamedResponse response;
    try {
      response = await client.send(request).timeout(const Duration(seconds: 30));
    } on Object catch (error) {
      throw CompanionLightError(CompanionLightFailure.network, '$error');
    }
    if (response.statusCode != 200) {
      // The status already says what went wrong; the body is only a note, read
      // for a moment and a few hundred bytes at most.
      final failure = switch (response.statusCode) {
        401 || 403 => CompanionLightFailure.badKey,
        429 => CompanionLightFailure.busy,
        _ => CompanionLightFailure.server,
      };
      throw CompanionLightError(failure, '${response.statusCode} ${await _note(response.stream)}');
    }
    final events = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        // A reply that stops arriving is a failed one, not a slow one.
        .timeout(const Duration(seconds: 45));
    // message_start carries the input, message_delta the output so far; each
    // is a running total, not an increment, so the largest one seen stands.
    int? input;
    int? output;
    void usageFrom(Object? usage, {required bool terminalSource}) {
      if (usage is! Map) return;
      const names = {
        'input_tokens': 'inputTokens',
        'cache_read_input_tokens': 'cacheReadTokens',
        'cache_creation_input_tokens': 'cacheWriteTokens',
        'output_tokens': 'outputTokens',
      };
      for (final entry in names.entries) {
        if (usage.containsKey(entry.key) && (terminalSource || entry.key != 'output_tokens')) {
          observed[entry.value] = usage[entry.key] ?? -1;
        }
      }
      int? n(Object? v) => v is int && v >= 0 ? v : null;
      if (n(usage['input_tokens']) case final fresh?) {
        final all = fresh + (n(usage['cache_read_input_tokens']) ?? 0) + (n(usage['cache_creation_input_tokens']) ?? 0);
        input = max(input ?? 0, all);
      }
      if (n(usage['output_tokens']) case final out?) output = max(output ?? 0, out);
    }

    try {
      await for (final line in events) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty || data == '[DONE]') continue;
        final Object? event;
        try {
          event = jsonDecode(data);
        } on FormatException {
          continue;
        }
        if (event is! Map) continue;
        // An error event, or a bare {"error": …} (the API's own timeout answer has no type).
        if (event['type'] == 'error' || (event['type'] == null && event['error'] != null)) {
          final error = event['error'];
          final kind = error is Map ? error['type'] : null;
          throw CompanionLightError(
            kind == 'overloaded_error' || kind == 'rate_limit_error'
                ? CompanionLightFailure.busy
                : CompanionLightFailure.server,
            error is Map ? '${error['message']}' : '$error',
          );
        }
        switch (event['type']) {
          case 'content_block_delta':
            final delta = event['delta'];
            if (delta is Map && delta['type'] == 'text_delta' && delta['text'] is String) {
              yield delta['text'] as String;
            }
          case 'message_start':
            final message = event['message'];
            if (message is Map) usageFrom(message['usage'], terminalSource: false);
          case 'message_delta':
            usageFrom(event['usage'], terminalSource: true);
          case 'message_stop':
            finished = true;
            if (input != null || output != null) onUsage?.call(input ?? 0, output ?? 0);
            return;
        }
      }
    } on CompanionLightError {
      rethrow;
    } on Object catch (error) {
      throw CompanionLightError(CompanionLightFailure.network, '$error');
    }
    // The connection ended before message_stop: the reply is incomplete, not done.
    throw const CompanionLightError(CompanionLightFailure.network, 'ended before message_stop');
  } finally {
    onUsageSettled?.call(observed, partial: !finished);
  }
}

/// Up to [limit] bytes of an error body, within [wait]; never more, never longer.
Future<String> _note(Stream<List<int>> body, {int limit = 512, Duration wait = const Duration(seconds: 2)}) async {
  final bytes = <int>[];
  final done = Completer<void>();
  late final StreamSubscription<List<int>> sub;
  sub = body.listen(
    (chunk) {
      bytes.addAll(chunk.take(limit - bytes.length));
      if (bytes.length >= limit && !done.isCompleted) done.complete();
    },
    onError: (Object _) {
      if (!done.isCompleted) done.complete();
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    cancelOnError: true,
  );
  await done.future.timeout(wait, onTimeout: () {});
  unawaited(sub.cancel().catchError((Object _) {}));
  return utf8.decode(bytes, allowMalformed: true);
}

/// The light conversation, kept on this phone.
///
/// One page holds the current one. Reads, saves and clears of the same file
/// run one after another in the order they were asked for, across instances:
/// a page that has just closed finishes its last save before the next page
/// reads, and a clear cannot delete a save asked for after it.
class CompanionLightHistory {
  CompanionLightHistory(this.file);

  /// Next to the pack (`<root>/light-chat.json`): removing the pack keeps it.
  factory CompanionLightHistory.at(Directory root) => CompanionLightHistory(File('${root.path}/light-chat.json'));

  final File file;
  final List<CompanionLine> _lines = [];
  Future<void>? _loading;

  /// Bumped by [clear]: a read that started before it must not bring the old lines back.
  int _epoch = 0;

  /// The tail of each file's queue of reads and writes.
  static final _queues = <String, Future<void>>{};

  Future<void> _queued(Future<void> Function() op) {
    final key = file.absolute.path;
    final next = (_queues[key] ?? Future<void>.value()).then((_) => op()).catchError((Object _) {});
    _queues[key] = next;
    return next;
  }

  /// Lines kept on disk; older ones fall off.
  static const keep = 80;

  /// Lines sent with each message (about a dozen turns).
  static const window = 24;

  List<CompanionLine> get lines => List.unmodifiable(_lines);

  /// Reads the file once; every caller waits for that same read, so the old
  /// conversation always comes before anything added after it.
  Future<void> load() {
    final epoch = _epoch;
    return _loading ??= _queued(() async {
      try {
        final json = jsonDecode(await file.readAsString());
        if (epoch == _epoch && json is Map && json['lines'] is List) {
          final version = json['v'] == 1 ? 1 : 2;
          _lines.insertAll(0, [
            for (final line in json['lines'] as List) ?CompanionLine.fromJson(line, version: version),
          ]);
          if (_lines.length > keep) _lines.removeRange(0, _lines.length - keep);
        }
      } on Object {
        // Missing or unreadable: she starts afresh rather than not talking.
      }
    });
  }

  /// The caller must pass only the human's text; use streamCompanionReply's
  /// context argument for events. Integrate the page change with this schema.
  void add(CompanionLine line) {
    _lines.add(line);
    if (_lines.length > keep) _lines.removeRange(0, _lines.length - keep);
  }

  /// Takes back the last line when it's the person's and went unanswered.
  CompanionLine? dropUnanswered() => _lines.isNotEmpty && !_lines.last.fromHer ? _lines.removeLast() : null;

  /// What the model gets: the last [window] lines, starting with the person,
  /// with lines from the same side joined (the API wants them alternating).
  List<CompanionLine> context() {
    var start = max(0, _lines.length - window);
    while (start < _lines.length && _lines[start].fromHer) {
      start++;
    }
    final out = <CompanionLine>[];
    for (final line in _lines.skip(start)) {
      if (out.isNotEmpty && out.last.fromHer == line.fromHer) {
        final joined = '${out.last.text}\n${line.text}';
        out[out.length - 1] = line.fromHer ? CompanionLine.her(joined) : CompanionLine.user(joined);
      } else {
        out.add(line);
      }
    }
    return out;
  }

  /// Writes the conversation as it is now (taken at the call, not when the
  /// write's turn comes).
  Future<void> save() {
    final json = jsonEncode({
      'v': 2,
      'lines': [for (final line in _lines) line.toJson()],
    });
    return _queued(() async {
      try {
        await file.parent.create(recursive: true);
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(json);
        await temp.rename(file.path);
      } on Object {
        // A lost write costs her a little memory, never the conversation in progress.
      }
    });
  }

  Future<void> clear() {
    _epoch++;
    _lines.clear();
    return _queued(() async {
      try {
        if (await file.exists()) await file.delete();
      } on Object {
        // Nothing to forget, or it can't be: the next save overwrites it.
      }
    });
  }
}
