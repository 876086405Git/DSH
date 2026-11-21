import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api.dart';

part 'model_metadata.dart';

/// The transport contract is OpenAI Chat Completions. DeepSeek's beta endpoint,
/// prefix, reasoning_content and usage fields follow its published API:
/// https://api-docs.deepseek.com/api/create-chat-completion/
/// https://api-docs.deepseek.com/guides/chat_prefix_completion/
/// Checked 2026-11-10. Prompt conversion belongs to the prompt assembler.
sealed class ModelDelta {
  const ModelDelta();
}

class ModelText extends ModelDelta {
  const ModelText(this.text);
  final String text;
}

class ModelReasoning extends ModelDelta {
  const ModelReasoning(this.text);
  final String text;
}

/// An unexecuted tool fragment. An absent/invalid streaming index is never
/// guessed. Protocol diagnostics travel beside the other response channels.
/// The accumulator, rather than the transport, owns call identity and JSON.
class ModelToolFragment extends ModelDelta {
  ModelToolFragment({
    this.index,
    this.id,
    this.type,
    this.name,
    this.arguments,
    List<Map<String, Object?>> issues = const [],
    this.structure,
  }) : _issues = jsonEncode(issues);

  final int? index;
  final String? id;
  final String? type;
  final String? name;
  final String? arguments;
  final ModelToolFragmentStructure? structure;
  final String _issues;

  /// Every read is detached, including nested diagnostic metadata.
  List<Map<String, Object?>> get issues => [
    for (final issue in jsonDecode(_issues) as List<Object?>) issue as Map<String, Object?>,
  ];
}

class ModelUsage extends ModelDelta {
  const ModelUsage(this.usage, {this.report});
  final TavernUsage usage;
  final ModelUsageReport? report;
}

class ModelFinished extends ModelDelta {
  const ModelFinished(this.reason, {this.assistantSnapshot, this.finalUsageReport});
  final String? reason;
  final ModelAssistantSnapshot? assistantSnapshot;
  final ModelUsageReport? finalUsageReport;
}

class TavernModelException implements Exception {
  const TavernModelException(this.kind, this.detail);
  final TavernFailure kind;
  final String detail;

  @override
  String toString() => 'TavernModelException(${kind.name}): $detail';
}

/// Only failures before an accepted response are eligible. A successful HTTP
/// response may already be billable even when its first token never arrives.
class _RetryableModelException implements Exception {
  const _RetryableModelException(this.cause);
  final TavernModelException cause;
}

/// One cancellation per generation, including time spent obtaining the key.
class ModelCancellation {
  final _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw const TavernModelException(TavernFailure.cancelled, 'cancelled');
  }

  Future<T> wait<T>(Future<T> operation) {
    check();
    return Future.any([
      operation,
      whenCancelled.then<T>((_) => throw const TavernModelException(TavernFailure.cancelled, 'cancelled')),
    ]);
  }
}

/// A single request's raw-usage observation scope over the original token.
/// All cancellation operations delegate; closing observations neither cancels
/// that token nor erases already recorded evidence. Legacy generate overrides
/// still accept this through their unchanged ModelCancellation parameter.
class ModelRequestContext extends ModelCancellation {
  ModelRequestContext({required ModelCancellation cancellation, required void Function(ModelUsageReport) onUsageReport})
    : _cancellation = cancellation,
      _onUsageReport = onUsageReport;

  final ModelCancellation _cancellation;
  final void Function(ModelUsageReport) _onUsageReport;
  var _observationsClosed = false;

  @override
  bool get isCancelled => _cancellation.isCancelled;
  @override
  Future<void> get whenCancelled => _cancellation.whenCancelled;
  @override
  void cancel() => _cancellation.cancel();
  @override
  void check() => _cancellation.check();
  @override
  Future<T> wait<T>(Future<T> operation) => _cancellation.wait(operation);

  /// Called synchronously when the actual report is observed, before outward
  /// response deltas. The owner handles its persistence failure separately;
  /// an observer cannot replace a transport error or change retry behavior.
  void reportUsage(ModelUsageReport report) {
    if (_observationsClosed) return;
    try {
      _onUsageReport(report);
    } catch (_) {
      /* observation only */
    }
  }

  void closeObservations() {
    _observationsClosed = true;
  }
}

void _observeUsage(ModelCancellation cancellation, ModelUsageReport report) {
  if (cancellation is ModelRequestContext) cancellation.reportUsage(report);
}

/// An HTTP client is owned by each call so stopping one chat cannot abort a
/// different chat. Supply [clientFactory] for deterministic transport tests.
class TavernModelClient {
  TavernModelClient({
    http.Client Function()? clientFactory,
    this.idleTimeout = const Duration(minutes: 5),
    this.onUsageSettled,
  }) : _clientFactory = clientFactory ?? http.Client.new;

  /// Once per actual HTTP attempt, including retries. A clean terminal response
  /// determines whether the latest report can be treated as final.
  final void Function(ModelUsageReport? report, {required bool partial})? onUsageSettled;

  final http.Client Function() _clientFactory;
  final Duration idleTimeout;

  /// [body] is the final, inspected request from the assembler. This method
  /// supplies transport settings and removes DeepSeek-only wire fields for
  /// an OpenAI-compatible endpoint.
  /// `stream: false` presets are also supported: one text/reasoning delta.
  /// Connection errors while sending and HTTP 5xx get at most two retries,
  /// after 250 and 500 ms. Accepted responses and 4xx are not retried; waiting
  /// for headers or an accepted body to time out does not trigger a retry.
  /// A known 5xx stays retryable if reading its error body fails or times out.
  /// A lost response during send can still mean the server received the POST;
  /// bounded retry cannot promise that the first attempt was not charged.
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) async* {
    String? key;
    try {
      cancellation.check();
      final headers = Map<String, String>.of(config.headers);
      key = await cancellation.wait(config.apiKey());
      cancellation.check();
      key = key?.trim();
      if (config.deepseek && (key == null || key.isEmpty)) {
        throw const TavernModelException(TavernFailure.noKey, 'no_api_key');
      }
      final payload = <String, Object?>{...body, 'model': config.model};
      payload.putIfAbsent('stream', () => true);
      if (config.deepseek) {
        payload.putIfAbsent('thinking', () => {'type': config.thinking ? 'enabled' : 'disabled'});
      } else {
        _normalizeOpenAiBody(payload);
      }
      final encodedBody = jsonEncode(payload);
      final uri = endpoint(config);
      for (var attempt = 0; ; attempt++) {
        try {
          await for (final delta in _generateAttempt(
            config,
            uri,
            key,
            headers,
            encodedBody,
            payload['stream'] != false,
            cancellation,
            attempt: attempt,
            onRequestStarted: onRequestStarted,
          )) {
            yield delta;
          }
          return;
        } on _RetryableModelException catch (error) {
          cancellation.check();
          if (attempt >= 2) throw error.cause;
          await cancellation.wait(Future<void>.delayed(Duration(milliseconds: 250 * (1 << attempt))));
        }
      }
    } on TavernModelException {
      rethrow;
    } on http.RequestAbortedException {
      throw const TavernModelException(TavernFailure.cancelled, 'cancelled');
    } on TimeoutException {
      cancellation.check();
      throw const TavernModelException(TavernFailure.network, 'request_timeout');
    } on http.ClientException {
      cancellation.check();
      throw const TavernModelException(TavernFailure.network, 'http_transport_failed');
    } on FormatException {
      cancellation.check();
      throw const TavernModelException(TavernFailure.server, 'invalid_response_format');
    } catch (_) {
      cancellation.check();
      // Do not expose callback/transport exception text: it may contain a key
      // or the entire request. Known HTTP errors carry a bounded safe detail.
      throw const TavernModelException(TavernFailure.network, 'model_call_failed');
    }
  }

  Stream<ModelDelta> _generateAttempt(
    TavernModelConfig config,
    Uri uri,
    String? key,
    Map<String, String> headers,
    String encodedBody,
    bool streaming,
    ModelCancellation cancellation, {
    required int attempt,
    void Function(int attempt)? onRequestStarted,
  }) async* {
    http.Client? client;
    ModelUsageReport? usageReport;
    var sentRequest = false;
    var finished = false;
    try {
      cancellation.check();
      final request = http.AbortableRequest('POST', uri, abortTrigger: cancellation.whenCancelled)
        ..headers.addAll({
          'Content-Type': 'application/json',
          for (final entry in headers.entries)
            if (key == null || key.isEmpty || entry.key.toLowerCase() != 'authorization') entry.key: entry.value,
          if (key != null && key.isNotEmpty) 'Authorization': 'Bearer $key',
        })
        ..body = encodedBody;
      client = _clientFactory();
      cancellation.check();
      http.StreamedResponse response;
      try {
        late final Future<http.StreamedResponse> sent;
        try {
          sentRequest = true;
          sent = client.send(request);
        } finally {
          // The method was really invoked, even if it threw synchronously.
          // This is not proof of socket delivery or HTTP acceptance. A private
          // observer cannot add retries, replace the error, or insert an await.
          try {
            onRequestStarted?.call(attempt);
          } catch (_) {
            /* observation only */
          }
        }
        response = await cancellation.wait(sent.timeout(idleTimeout));
      } on http.RequestAbortedException {
        rethrow;
      } on http.ClientException {
        cancellation.check();
        throw const _RetryableModelException(TavernModelException(TavernFailure.network, 'http_transport_failed'));
      }
      cancellation.check();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        String error;
        try {
          error = await cancellation.wait(_errorBody(response.stream.timeout(idleTimeout)));
        } catch (_) {
          cancellation.check();
          // The HTTP status remains authoritative even if its error body was
          // interrupted. Do not substitute raw transport exception messages.
          error = 'error_response_body_unavailable';
        }
        final failure = _apiError(response.statusCode, error, key, headers.values);
        if (response.statusCode >= 500 && response.statusCode < 600) {
          throw _RetryableModelException(failure);
        }
        throw failure;
      }

      if (!streaming) {
        final text = await cancellation.wait(response.stream.bytesToString().timeout(idleTimeout));
        cancellation.check();
        final result = _object(jsonDecode(text));
        if (result.containsKey('usage')) {
          usageReport = _providerUsageReport(
            result['usage'],
            present: true,
            transport: 'nonstream',
            observationIndex: 0,
          );
          _observeUsage(cancellation, usageReport);
        }
        if (result['error'] != null) throw _apiError(200, text, key, headers.values);
        final choice = _firstChoice(result);
        final message = _object(choice['message']);
        // The complete nonstream body and actual message are already present.
        // Do not fabricate absence for a malformed completion envelope.
        if (usageReport == null && choice.isNotEmpty && message.isNotEmpty) {
          usageReport = _providerUsageReport(null, present: false, transport: 'nonstream', observationIndex: 0);
          _observeUsage(cancellation, usageReport);
        }
        final assistant = _AssistantCollector('nonstream_message')..add(message, streaming: false);
        if (_reasoningText(message) case final String reasoning when reasoning.isNotEmpty) {
          cancellation.check();
          yield ModelReasoning(reasoning);
        }
        if (message['content'] case final String content when content.isNotEmpty) {
          cancellation.check();
          yield ModelText(content);
        }
        for (final fragment in _toolFragments(message['tool_calls'], streaming: false)) {
          cancellation.check();
          yield fragment;
        }
        if (result['usage'] case final Map<String, dynamic> usage) {
          cancellation.check();
          yield ModelUsage(_usage(usage, result['model'] as String? ?? config.model), report: usageReport);
        }
        if (choice.isEmpty || message.isEmpty) {
          throw const TavernModelException(TavernFailure.server, 'invalid_completion_response');
        }
        final reason = choice['finish_reason'] as String?;
        _checkFinish(reason);
        cancellation.check();
        finished = true;
        yield ModelFinished(reason, assistantSnapshot: assistant.finish(), finalUsageReport: usageReport);
        return;
      }

      String? finishReason;
      var sawFinish = false;
      var sawDone = false;
      final assistant = _AssistantCollector('streaming_aggregate');
      var usageObservationIndex = 0;
      await for (final event in decodeServerSentEvents(response.stream.timeout(idleTimeout))) {
        cancellation.check();
        if (event == '[DONE]') {
          sawDone = true;
          if (usageReport == null) {
            usageReport = _providerUsageReport(
              null,
              present: false,
              transport: 'streaming',
              observationIndex: usageObservationIndex,
            );
            _observeUsage(cancellation, usageReport);
          }
          break;
        }
        final data = _object(jsonDecode(event));
        // Top-level presence is independent of choice/delta shape. Deliver it
        // before this payload can yield text or fail on another response field.
        if (data.containsKey('usage')) {
          usageReport = _providerUsageReport(
            data['usage'],
            present: true,
            transport: 'streaming',
            observationIndex: usageObservationIndex++,
          );
          _observeUsage(cancellation, usageReport);
        }
        if (data['error'] != null) throw _apiError(200, event, key, headers.values);
        final choice = _firstChoice(data);
        final delta = _object(choice['delta']);
        assistant.add(delta, streaming: true);
        if (_reasoningText(delta) case final String reasoning when reasoning.isNotEmpty) {
          cancellation.check();
          yield ModelReasoning(reasoning);
        }
        if (delta['content'] case final String content when content.isNotEmpty) {
          cancellation.check();
          yield ModelText(content);
        }
        for (final fragment in _toolFragments(delta['tool_calls'], streaming: true)) {
          cancellation.check();
          yield fragment;
        }
        if (choice['finish_reason'] case final String reason) {
          finishReason = reason;
          sawFinish = true;
        }
        // Some providers send usage with choices: [], others on the finish
        // chunk. It must be read independently of the first choice.
        if (data['usage'] case final Map<String, dynamic> usage) {
          cancellation.check();
          yield ModelUsage(_usage(usage, data['model'] as String? ?? config.model), report: usageReport);
        }
      }
      if (sawFinish && usageReport == null) {
        usageReport = _providerUsageReport(
          null,
          present: false,
          transport: 'streaming',
          observationIndex: usageObservationIndex,
        );
        _observeUsage(cancellation, usageReport);
      }
      cancellation.check();
      if (!sawDone && !sawFinish) {
        throw const TavernModelException(TavernFailure.network, 'stream_ended_before_finish');
      }
      _checkFinish(finishReason);
      cancellation.check();
      finished = true;
      yield ModelFinished(finishReason, assistantSnapshot: assistant.finish(), finalUsageReport: usageReport);
    } finally {
      client?.close();
      if (sentRequest) {
        try {
          onUsageSettled?.call(usageReport, partial: !finished);
        } catch (_) {
          // Analytics must not replace the transport result or block retry.
        }
      }
    }
  }

  /// Generic services supply their own API prefix (for example /v1). A full
  /// /chat/completions URL is accepted. DeepSeek roots and /v1 become /beta.
  static Uri endpoint(TavernModelConfig config) {
    final uri = Uri.parse(config.baseUrl).removeFragment();
    if (!uri.hasAuthority || (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw const TavernModelException(TavernFailure.network, 'invalid_base_url');
    }
    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (path.endsWith('/chat/completions')) {
      if (!config.deepseek) return uri.replace(path: path);
      path = path.substring(0, path.length - '/chat/completions'.length);
    }
    if (config.deepseek && !path.endsWith('/beta')) {
      if (path.endsWith('/v1')) path = path.substring(0, path.length - 3);
      path += '/beta';
    }
    return uri.replace(path: '$path/chat/completions');
  }
}

/// SSE framing is independent of HTTP chunk boundaries and UTF-8 characters.
/// Malformed UTF-8 is replaced before fields and comments are interpreted.
/// UTF-8 decoding removes at most one leading BOM for the entire stream.
/// Comments/keepalives are ignored; multiple data fields join with a newline.
/// Only a terminating blank line dispatches an event; EOF discards pending data.
Stream<String> decodeServerSentEvents(Stream<List<int>> bytes) async* {
  final data = <String>[];
  await for (final line in bytes.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        yield data.join('\n');
        data.clear();
      }
      continue;
    }
    if (line.startsWith(':')) continue;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    if (field != 'data') continue;
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    data.add(value);
  }
}

Map<String, Object?> _object(Object? value) {
  if (value is Map<String, dynamic>) return value;
  return const {};
}

// The transport boundary also covers custom callers of TavernModelClient.
// Copy message/tool maps without mutating the caller's inspected body.
void _normalizeOpenAiBody(Map<String, Object?> body) {
  body.remove('thinking');
  if (body['messages'] case final List<Object?> messages) {
    body['messages'] = [
      for (final message in messages)
        if (message is Map<String, Object?>)
          Map<String, Object?>.of(message)
            ..remove('prefix')
            ..remove('reasoning_content')
            ..remove('reasoning')
        else
          message,
    ];
  }
  if (body['tools'] case final List<Object?> tools) {
    body['tools'] = [
      for (final tool in tools)
        if (tool is Map<String, Object?> && tool['function'] is Map<String, Object?>)
          {...tool, 'function': Map<String, Object?>.of(tool['function']! as Map<String, Object?>)..remove('strict')}
        else
          tool,
    ];
  }
}

String? _reasoningText(Map<String, Object?> message) {
  final content = message['reasoning_content'];
  if (content is String && content.isNotEmpty) return content;
  final alias = message['reasoning'];
  return alias is String ? alias : null;
}

Map<String, Object?> _firstChoice(Map<String, Object?> response) {
  final choices = response['choices'];
  if (choices is! List<Object?> || choices.isEmpty) return const {};
  for (final value in choices) {
    final choice = _object(value);
    if (choice['index'] == null || choice['index'] == 0) return choice;
  }
  return const {};
}

Iterable<ModelToolFragment> _toolFragments(Object? value, {required bool streaming}) sync* {
  if (value == null) {
    return;
  }
  if (value is! List<Object?>) {
    yield ModelToolFragment(
      issues: [
        {'code': 'invalid_tool_calls', 'field': 'tool_calls', 'message': 'Expected an array of tool calls.'},
      ],
      structure: const ModelToolFragmentStructure(unsupportedEnvelope: true, invalidMetadataType: true),
    );
    return;
  }
  for (var ordinal = 0; ordinal < value.length; ordinal++) {
    final item = value[ordinal];
    if (item is! Map<String, Object?>) {
      yield ModelToolFragment(
        index: streaming ? null : ordinal,
        issues: [
          {
            'code': 'invalid_tool_call',
            'field': 'tool_calls',
            'ordinal': ordinal,
            if (!streaming) 'index': ordinal,
            'message': 'Expected a tool call object.',
          },
        ],
        structure: const ModelToolFragmentStructure(unsupportedEnvelope: true, invalidMetadataType: true),
      );
      continue;
    }
    final issues = <Map<String, Object?>>[];
    var invalidMetadata = false;
    var invalidArguments = false;
    var unsupported = item.keys.any(
      (key) => !const ['id', 'type', 'function'].contains(key) && !(streaming && key == 'index'),
    );
    int? index;
    if (!streaming) {
      index = ordinal;
    } else if (item['index'] case final int position when position >= 0) {
      index = position;
    } else {
      issues.add({
        'code': 'invalid_index',
        'field': 'index',
        'ordinal': ordinal,
        'message': 'A streaming tool fragment requires a non-negative integer index.',
      });
    }
    String? field(Map<String, Object?> object, String key, String path) {
      if (!object.containsKey(key)) {
        return null;
      }
      final raw = object[key];
      if (raw is String) {
        return raw;
      }
      if (path == 'function.arguments') {
        invalidArguments = true;
      } else {
        invalidMetadata = true;
      }
      issues.add({'code': 'invalid_field_type', 'field': path, 'index': ?index, 'message': 'Expected a string.'});
      return null;
    }

    final id = field(item, 'id', 'id');
    final type = field(item, 'type', 'type');
    String? name;
    String? arguments;
    if (item.containsKey('function')) {
      final function = item['function'];
      if (function is Map<String, Object?>) {
        unsupported = unsupported || function.keys.any((key) => !const ['name', 'arguments'].contains(key));
        name = field(function, 'name', 'function.name');
        arguments = field(function, 'arguments', 'function.arguments');
      } else {
        invalidMetadata = true;
        invalidArguments = true;
        issues.add({
          'code': 'invalid_field_type',
          'field': 'function',
          'index': ?index,
          'message': 'Expected a function object.',
        });
      }
    }
    yield ModelToolFragment(
      index: index,
      id: id,
      type: type,
      name: name,
      arguments: arguments,
      issues: issues,
      structure: ModelToolFragmentStructure(
        unsupportedEnvelope: unsupported,
        invalidMetadataType: invalidMetadata,
        invalidArgumentsType: invalidArguments,
      ),
    );
  }
}

TavernUsage _usage(Map<String, Object?> data, String model) {
  int number(Object? value) => value is num ? value.toInt() : 0;
  return TavernUsage(
    promptTokens: number(data['prompt_tokens']),
    cacheHitTokens: number(data['prompt_cache_hit_tokens'] ?? _object(data['prompt_tokens_details'])['cached_tokens']),
    completionTokens: number(data['completion_tokens']),
    model: model,
  );
}

void _checkFinish(String? reason) {
  if (reason == 'insufficient_system_resource' || reason == 'aborted') {
    throw TavernModelException(TavernFailure.server, 'finish_reason:$reason');
  }
}

Future<String> _errorBody(Stream<List<int>> bytes) async {
  final buffer = StringBuffer();
  await for (final chunk in bytes.transform(const Utf8Decoder(allowMalformed: true))) {
    buffer.write(chunk);
    if (buffer.length >= 4096) break;
  }
  final text = buffer.toString();
  return text.length > 4096 ? text.substring(0, 4096) : text;
}

bool _isContextLengthError(String body) {
  bool matches(String value) {
    final lowered = value.toLowerCase();
    return lowered.contains('context_length_exceeded') ||
        lowered.contains('maximum context length') ||
        lowered.contains('context window') ||
        lowered.contains('context too long');
  }

  // Keep existing raw/plain-text matches and also recognize JSON escapes in
  // the two established error strings. Unrelated values are never re-encoded.
  if (matches(body)) return true;
  try {
    final error = _object(_object(jsonDecode(body))['error']);
    final code = error['code'];
    final message = error['message'];
    return (code is String && matches(code)) || (message is String && matches(message));
  } on FormatException {
    return false;
  }
}

TavernModelException _apiError(int status, String body, String? key, Iterable<String> headerValues) {
  final kind = switch (status) {
    401 || 403 => TavernFailure.badKey,
    402 => TavernFailure.insufficientBalance,
    429 => TavernFailure.busy,
    >= 500 && < 600 => TavernFailure.server,
    _ when _isContextLengthError(body) => TavernFailure.contextTooLong,
    400 || 422 => TavernFailure.invalidParameters,
    _ => TavernFailure.server,
  };
  var detail = body;
  void redact(String value) {
    if (value.isEmpty) return;
    final encoded = jsonEncode(value);
    detail = detail.replaceAll(value, '[redacted]').replaceAll(encoded.substring(1, encoded.length - 1), '[redacted]');
  }

  if (key != null) redact(key);
  for (final value in headerValues) {
    redact(value);
    final separator = value.indexOf(' ');
    if (separator >= 0) redact(value.substring(separator + 1));
  }
  detail = detail.replaceAll(RegExp(r'Bearer\s+[^\s"<>]+', caseSensitive: false), 'Bearer [redacted]');
  if (detail.length > 512) detail = detail.substring(0, 512);
  return TavernModelException(kind, 'HTTP $status: $detail');
}
