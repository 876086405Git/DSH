// 轻量模式 (docs/design/companion.md §7): she talks to DeepSeek straight from
// the phone, with no engine and no host. The same Messages API the engine's
// DeepSeek adapter uses (@deepseek-ai/dsh-llm-deepseek), with the API key
// saved in the app. The room writes new source lines to its shared SQLite
// owner; CompanionLightHistory below remains the reader for old visible logs.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dsh_client/companion.dart' show MemorySelection;
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

/// The API's alternating request view. Joining here does not change the raw
/// SQLite message IDs, versions, or stored text used by extraction.
List<CompanionLine> companionLightContext(Iterable<CompanionLine> lines, {int window = 24}) {
  final all = lines.toList();
  var start = max(0, all.length - window);
  while (start < all.length && all[start].fromHer) {
    start++;
  }
  final out = <CompanionLine>[];
  for (final line in all.skip(start)) {
    if (out.isNotEmpty && out.last.fromHer == line.fromHer) {
      final joined = '${out.last.text}\n${line.text}';
      out[out.length - 1] = line.fromHer ? CompanionLine.her(joined) : CompanionLine.user(joined);
    } else {
      out.add(line);
    }
  }
  return out;
}

enum CompanionLightFailure { noKey, badKey, busy, network, server }

enum CompanionHostFailure { disconnected, modelUnavailable, unavailable, busy, requestFailed, deviceConflict, retryClosed, selectionChanged }

// Host failures keep their route identity through the Agent's existing error
// channel. In particular they never ask for a phone-only DeepSeek key.
CompanionHostFailure companionHostFailure(String? code, {int? httpStatus}) => switch (code) {
  _ when httpStatus == 429 => CompanionHostFailure.busy,
  'RATE_LIMIT' || 'companion/auxiliary-busy' => CompanionHostFailure.busy,
  'companion/auxiliary-model-unavailable' || 'UNKNOWN_MODEL' || 'MISSING_MODEL' =>
    CompanionHostFailure.modelUnavailable,
  'transport-error' || 'cancelled' => CompanionHostFailure.disconnected,
  'route-unavailable' ||
  'companion/auxiliary-unavailable' ||
  'companion/auxiliary-session-unavailable' ||
  'companion/auxiliary-forbidden' ||
  'COMPANION_AUXILIARY_UNAVAILABLE' ||
  'CLIENT_UPGRADE_REQUIRED' => CompanionHostFailure.unavailable,
  _ => CompanionHostFailure.requestFailed,
};

class CompanionLightError implements Exception {
  const CompanionLightError(this.failure, [this.detail]);

  final CompanionLightFailure failure;
  final String? detail;

  @override
  String toString() => 'CompanionLightError(${failure.name}${detail == null ? '' : ': $detail'})';
}

/// Fits the existing Agent error channel without widening Light's enum or
/// losing the Host reason when the Agent retains a failed turn.
class CompanionHostError extends CompanionLightError {
  const CompanionHostError(this.hostFailure, [String? detail])
    : super(
        hostFailure == CompanionHostFailure.busy ? CompanionLightFailure.busy : CompanionLightFailure.server,
        detail,
      );

  final CompanionHostFailure hostFailure;
}

/// One sent request's usage receipt. The raw objects retain the provider's
/// fields; missing final components stay unknown, including after a start-only
/// disconnect. [complete] means message_stop arrived, not that the answer was
/// usable: max_tokens and refusal still have their own [terminal].
class CompanionUsage {
  const CompanionUsage({
    required this.provider,
    required this.model,
    required this.startUsage,
    required this.finalUsage,
    required this.startEvent,
    required this.finalEvent,
    required this.semantics,
    required this.inputUncached,
    required this.inputCacheRead,
    required this.inputCacheWrite,
    required this.outputTokens,
    required this.stopReason,
    required this.terminal,
    required this.complete,
    required this.httpStatus,
  });

  /// A view for the existing token UI. The caller records the original Host
  /// map first, including runtime-normalized fields absent from this view.
  factory CompanionUsage.fromReceipt(Map<String, Object?> receipt) {
    int? count(String key) => receipt[key] is int && (receipt[key]! as int) >= 0 ? receipt[key] as int : null;
    Map<String, Object?>? map(String key) =>
        receipt[key] is Map<String, Object?> ? receipt[key] as Map<String, Object?> : null;
    return CompanionUsage(
      provider: receipt['provider']! as String,
      model: receipt['model']! as String,
      startUsage: map('start_usage'),
      finalUsage: map('final_usage'),
      startEvent: receipt['start_event'] as String?,
      finalEvent: receipt['final_event'] as String?,
      semantics: receipt['usage_semantics'] as String? ?? 'unknown',
      inputUncached: count('input_uncached'),
      inputCacheRead: count('input_cache_read'),
      inputCacheWrite: count('input_cache_write'),
      outputTokens: count('output_tokens'),
      stopReason: receipt['stop_reason'] as String?,
      terminal: receipt['terminal'] as String? ?? 'incomplete',
      complete: receipt['complete'] == true,
      httpStatus: count('http_status'),
    );
  }

  final String provider;
  final String model;
  final Map<String, Object?>? startUsage;
  final Map<String, Object?>? finalUsage;
  final String? startEvent;
  final String? finalEvent;
  final String semantics;
  final int? inputUncached;
  final int? inputCacheRead;
  final int? inputCacheWrite;
  final int? outputTokens;
  final String? stopReason;

  /// complete, max_tokens, refusal, incomplete, http_error, provider_error,
  /// network_error, or cancelled.
  final String terminal;
  final bool complete;
  final int? httpStatus;

  /// An additive telemetry count of reported input components, not a complete
  /// billable input total. Unknown components remain null in the receipt.
  int? get reportedInputTokens {
    final parts = [inputUncached, inputCacheRead, inputCacheWrite].whereType<int>();
    return parts.isEmpty ? null : parts.fold<int>(0, (sum, part) => sum + part);
  }

  /// The usage-v4 ledger's token report: the start frame's input components,
  /// overlaid by the final frame's (output only ever from the final one); a
  /// field sent as null is -1.
  Map<String, Object?> get telemetry {
    const names = {
      'input_tokens': 'inputTokens',
      'cache_read_input_tokens': 'cacheReadTokens',
      'cache_creation_input_tokens': 'cacheWriteTokens',
      'output_tokens': 'outputTokens',
    };
    return {
      for (final MapEntry(:key, :value) in names.entries)
        if (finalUsage?.containsKey(key) ?? false)
          value: finalUsage![key] ?? -1
        else if (key != 'output_tokens' && (startUsage?.containsKey(key) ?? false))
          value: startUsage![key] ?? -1,
    };
  }

  /// Usage metadata only: no request body, credential, or generated text.
  Map<String, Object?> toJson() => {
    'provider': provider,
    'model': model,
    'start_usage': startUsage,
    'final_usage': finalUsage,
    'start_event': startEvent,
    'final_event': finalEvent,
    'usage_semantics': semantics,
    'input_uncached': inputUncached,
    'input_cache_read': inputCacheRead,
    'input_cache_write': inputCacheWrite,
    'output_tokens': outputTokens,
    'stop_reason': stopReason,
    'terminal': terminal,
    'complete': complete,
    'http_status': httpStatus,
  };
}

/// A client tool in the official Messages schema, without a custom tool type.
class CompanionAgentTool {
  const CompanionAgentTool({required this.name, required this.description, required this.inputSchema});

  final String name;
  final String description;
  final Map<String, Object?> inputSchema;

  Map<String, Object?> toJson() => {'name': name, 'description': description, 'input_schema': inputSchema};
}

class CompanionAgentToolCall {
  const CompanionAgentToolCall({required this.id, required this.name, required this.input});

  final String id;
  final String name;
  final Map<String, Object?> input;
}

class CompanionAgentToolResult {
  const CompanionAgentToolResult({
    required this.content,
    this.isError = false,
    this.notice,
    this.externalWebContent = false,
    this.externalNoticeContent = false,
  });

  /// Includes a truthful failure explanation: DeepSeek ignores is_error.
  final String content;
  final bool isError;

  /// The adapter actually returned public-web text or a report containing it.
  /// This is application provenance, never a field trusted from model input.
  final bool externalWebContent;

  /// The memory owner returned actual externally sourced notification material.
  /// Never inferred from user wording or from any model-supplied argument.
  final bool externalNoticeContent;

  /// A committed deletion's short natural acknowledgement, even if the next
  /// model request fails. This is spoken text, not a tool log.
  final String? notice;
}

class CompanionAgentMessage {
  CompanionAgentMessage({required List<Map<String, Object?>> content, required this.stopReason, Map<String, Object?>? source})
    : content = List.unmodifiable(content.map(Map<String, Object?>.unmodifiable)),
      source = source == null ? null : Map<String, Object?>.unmodifiable(source);

  final List<Map<String, Object?>> content;
  final String? stopReason;

  /// Request-local Host provenance/replay, never persisted as phone memory.
  /// Rebuilding a retired message deliberately does not inherit this field.
  final Map<String, Object?>? source;

  String get text => [for (final block in content) if (block['type'] == 'text') block['text']! as String].join();

  Map<String, Object?> toRequest() => {
    'role': 'assistant',
    'content': content,
    if (source != null) 'source': source,
  };

  List<CompanionAgentToolCall> get calls => [
    for (final block in content)
      if (block['type'] == 'tool_use')
        CompanionAgentToolCall(
          id: block['id'] as String,
          name: block['name'] as String,
          input: block['input'] as Map<String, Object?>,
        ),
  ];
}

/// Her reply to [lines], as text deltas. Cancelling the subscription drops the
/// request; [client] is the caller's to close.
///
/// [onSent] runs immediately before client.send, after local validation.
/// [onUsage] runs once in finally for that sent request, even after an error or
/// cancellation. The caller retains a reservation for unknown final usage.
/// [onUsageSettled] hears the same receipt as [CompanionUsage.telemetry] right
/// after, partial unless message_stop arrived.
Stream<String> streamCompanionReply({
  required http.Client client,
  required String apiKey,
  required String system,
  required List<CompanionLine> lines,
  CompanionTurnContext? context,
  MemorySelection? memory,
  int maxTokens = 800,
  void Function()? onSent,
  void Function(CompanionUsage usage)? onUsage,
  void Function(Map<String, Object?> usage, {required bool partial})? onUsageSettled,
}) async* {
  if (apiKey.trim().isEmpty) throw const CompanionLightError(CompanionLightFailure.noKey);
  yield* _streamCompanionMessage(
    client: client,
    apiKey: apiKey,
    system: system,
    messages: companionRequestMessages(
      [for (final line in lines) (role: line.role, text: line.text)],
      context: context,
      memory: memory,
    ),
    maxTokens: maxTokens,
    onSent: onSent,
    onUsage: onUsage,
    onUsageSettled: onUsageSettled,
  );
}

/// The same wire and receipt as the text-only entry point. Tool arguments are
/// accumulated by content index and are exposed only after message_stop.
/// The caller executes calls after this stream (and its receipt finally) ends.
Stream<String> streamCompanionAgentReply({
  required http.Client client,
  required String apiKey,
  required String system,
  required List<Map<String, Object?>> messages,
  required List<CompanionAgentTool> tools,
  required void Function(CompanionAgentMessage) onMessage,
  int maxTokens = 800,
  void Function()? onSent,
  void Function(CompanionUsage usage)? onUsage,
  void Function(Map<String, Object?> usage, {required bool partial})? onUsageSettled,
}) async* {
  if (apiKey.trim().isEmpty) throw const CompanionLightError(CompanionLightFailure.noKey);
  yield* _streamCompanionMessage(
    client: client,
    apiKey: apiKey,
    system: system,
    messages: messages,
    tools: tools,
    collector: _CompanionAgentMessageBuilder(),
    onMessage: onMessage,
    maxTokens: maxTokens,
    onSent: onSent,
    onUsage: onUsage,
    onUsageSettled: onUsageSettled,
  );
}

/// The exact Messages body used for dispatch and preflight accounting. This
/// does not send, choose a route, or create another conversational protocol.
Map<String, Object?> companionAgentRequestBody({
  required String system,
  required List<Map<String, Object?>> messages,
  List<CompanionAgentTool> tools = const [],
  int maxTokens = 800,
}) => {
  'model': companionLightModel,
  'stream': true,
  'max_tokens': maxTokens,
  'thinking': {'type': 'disabled'},
  'system': system,
  'messages': messages,
  if (tools.isNotEmpty) 'tools': [for (final tool in tools) tool.toJson()],
};

Stream<String> _streamCompanionMessage({
  required http.Client client,
  required String apiKey,
  required String system,
  required List<Map<String, Object?>> messages,
  List<CompanionAgentTool> tools = const [],
  _CompanionAgentMessageBuilder? collector,
  void Function(CompanionAgentMessage)? onMessage,
  int maxTokens = 800,
  void Function()? onSent,
  void Function(CompanionUsage usage)? onUsage,
  void Function(Map<String, Object?> usage, {required bool partial})? onUsageSettled,
}) async* {
  final request = http.Request('POST', Uri.parse(companionLightEndpoint))
    ..headers.addAll({
      'content-type': 'application/json',
      'accept': 'text/event-stream',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    })
    ..body = jsonEncode(
      companionAgentRequestBody(system: system, messages: messages, tools: tools, maxTokens: maxTokens),
    );
  Map<String, Object?>? startUsage;
  Map<String, Object?>? finalUsage;
  String? stopReason;
  int? httpStatus;
  var terminal = 'cancelled';
  var complete = false;
  // A failed local receipt reservation must prevent the request from leaving.
  onSent?.call();
  try {
    final response = await client.send(request).timeout(const Duration(seconds: 30));
    httpStatus = response.statusCode;
    if (response.statusCode != 200) {
      terminal = 'http_error';
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
        terminal = 'provider_error';
        final error = event['error'];
        final kind = error is Map ? error['type'] : null;
        throw CompanionLightError(
          kind == 'overloaded_error' || kind == 'rate_limit_error'
              ? CompanionLightFailure.busy
              : CompanionLightFailure.server,
          error is Map ? '${error['message']}' : '$error',
        );
      }
      if (event['type'] != 'message_stop') collector?.add(event);
      switch (event['type']) {
        case 'content_block_start':
          final block = event['content_block'];
          if (collector != null &&
              block is Map &&
              block['type'] == 'text' &&
              block['text'] is String &&
              (block['text'] as String).isNotEmpty) {
            yield block['text'] as String;
          }
        case 'content_block_delta':
          final delta = event['delta'];
          if (delta is Map && delta['type'] == 'text_delta' && delta['text'] is String) {
            yield delta['text'] as String;
          }
        case 'message_start':
          final message = event['message'];
          if (message is Map && message['usage'] is Map) {
            startUsage ??= Map<String, Object?>.unmodifiable(message['usage'] as Map);
          }
        case 'message_delta':
          if (event['usage'] is Map) {
            finalUsage = Map<String, Object?>.unmodifiable(event['usage'] as Map);
          }
          final messageDelta = event['delta'];
          if (messageDelta is Map && messageDelta['stop_reason'] is String) {
            stopReason = messageDelta['stop_reason'] as String;
          }
        case 'message_stop':
          complete = true;
          terminal = switch (stopReason) {
            'max_tokens' => 'max_tokens',
            'refusal' => 'refusal',
            _ => 'complete',
          };
          if (collector != null && stopReason != 'max_tokens' && stopReason != 'refusal') {
            try {
              onMessage!(collector.finish(stopReason));
            } on FormatException catch (error) {
              terminal = 'provider_error';
              throw CompanionLightError(CompanionLightFailure.server, error.message);
            }
          }
          return;
      }
    }
    // The connection ended before message_stop: the reply is incomplete, not done.
    terminal = 'incomplete';
    throw const CompanionLightError(CompanionLightFailure.network, 'ended before message_stop');
  } on CompanionLightError {
    rethrow;
  } on Object catch (error) {
    terminal = 'network_error';
    throw CompanionLightError(CompanionLightFailure.network, '$error');
  } finally {
    int? tokens(String key) {
      final value = finalUsage?[key];
      return value is int && value >= 0 ? value : null;
    }

    // DeepSeek's final message_delta.usage is cumulative. Do not add the
    // initial values, take maxima, or fill absent final fields from the start.
    final usage = CompanionUsage(
      provider: 'deepseek',
      model: companionLightModel,
      startUsage: startUsage,
      finalUsage: finalUsage,
      startEvent: startUsage == null ? null : 'message_start',
      finalEvent: finalUsage == null ? null : 'message_delta',
      semantics: 'cumulative',
      inputUncached: tokens('input_tokens'),
      inputCacheRead: tokens('cache_read_input_tokens'),
      inputCacheWrite: tokens('cache_creation_input_tokens'),
      outputTokens: tokens('output_tokens'),
      stopReason: stopReason,
      terminal: terminal,
      complete: complete,
      httpStatus: httpStatus,
    );
    onUsage?.call(usage);
    onUsageSettled?.call(usage.telemetry, partial: !complete);
  }
}

class _CompanionAgentMessageBuilder {
  final _blocks = <int, Map<String, Object?>>{};
  final _arguments = <int, StringBuffer>{};
  final _openTools = <int>{};
  FormatException? _error;

  void add(Map event) {
    if (_error != null) return;
    try {
      _add(event);
    } on FormatException catch (error) {
      // Still read message_delta usage and the actual stop reason. A truncated
      // tool must not replace a provider max_tokens/refusal receipt with a
      // locally inferred terminal, nor become executable along the way.
      _error = error;
    }
  }

  void _add(Map event) {
    final type = event['type'];
    if (type != 'content_block_start' && type != 'content_block_delta' && type != 'content_block_stop') return;
    final index = event['index'];
    if (index is! int || index < 0) throw const FormatException('Missing content block index');
    switch (type) {
      case 'content_block_start':
        final block = event['content_block'];
        if (block is! Map || _blocks.containsKey(index)) throw const FormatException('Invalid content block start');
        switch (block['type']) {
          case 'text':
            _blocks[index] = {'type': 'text', 'text': block['text'] as String? ?? ''};
          case 'tool_use':
            if (block['id'] is! String ||
                (block['id'] as String).isEmpty ||
                block['name'] is! String ||
                (block['name'] as String).isEmpty ||
                block['input'] is! Map) {
              throw const FormatException('Invalid tool call');
            }
            _blocks[index] = {
              'type': 'tool_use',
              'id': block['id'],
              'name': block['name'],
              'input': Map<String, Object?>.from(block['input'] as Map),
            };
            _arguments[index] = StringBuffer();
            _openTools.add(index);
          default:
            throw const FormatException('Unsupported content block');
        }
      case 'content_block_delta':
        final delta = event['delta'];
        if (delta is! Map) return;
        if (delta['type'] == 'text_delta' && delta['text'] is String) {
          // Preserve the existing text-delta contract; tool blocks below still
          // require their actual start and stop before an argument is usable.
          final block = _blocks.putIfAbsent(index, () => {'type': 'text', 'text': ''});
          if (block['type'] != 'text') throw const FormatException('Text in a tool block');
          block['text'] = '${block['text']}${delta['text']}';
        } else if (delta['type'] == 'input_json_delta') {
          if (!_openTools.contains(index) || delta['partial_json'] is! String) {
            throw const FormatException('Arguments outside a tool block');
          }
          _arguments[index]!.write(delta['partial_json']);
        }
      case 'content_block_stop':
        if (_openTools.remove(index)) {
          final json = _arguments.remove(index)!.toString();
          final Object? input = json.isEmpty ? _blocks[index]!['input'] : jsonDecode(json);
          if (input is! Map) throw const FormatException('Tool arguments must be an object');
          _blocks[index]!['input'] = Map<String, Object?>.unmodifiable(input);
        }
    }
  }

  CompanionAgentMessage finish(String? stopReason) {
    if (_error case final error?) throw error;
    if (_openTools.isNotEmpty) throw const FormatException('Tool block did not finish');
    final indices = _blocks.keys.toList()..sort();
    final ids = <String>{};
    for (final block in _blocks.values) {
      if (block['type'] == 'tool_use' && !ids.add(block['id'] as String)) {
        throw const FormatException('Duplicate tool call ID');
      }
    }
    return CompanionAgentMessage(content: [for (final index in indices) _blocks[index]!], stopReason: stopReason);
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
    return companionLightContext(_lines, window: window);
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
