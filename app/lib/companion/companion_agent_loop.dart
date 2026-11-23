import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:http/http.dart' as http;

import 'companion_light.dart';

typedef CompanionAgentToolBinding = ({
  CompanionAgentTool definition,
  Future<CompanionAgentToolResult> Function(CompanionAgentToolCall) execute,
});

typedef CompanionAgentExchange = ({CompanionAgentMessage assistant, List<Map<String, Object?>> results});

typedef CompanionAgentResponse = ({CompanionAgentMessage message, String requestId});

/// Own memory control can retire old text without erasing a confirmed outcome.
/// These are the actual adapter's receipt fields, not a second execution log.
Map<String, Object?> _safeToolOutcome(String content) {
  Object? decoded;
  try {
    decoded = jsonDecode(content);
  } on FormatException {
    return const {'retiredAfterMemoryChange': true};
  }
  if (decoded is! Map) return const {'retiredAfterMemoryChange': true};
  Map<String, Object?> card(Map row) => {
    for (final key in const ['id', 'row_rev', 'kind', 'layer', 'collection', 'character_id'])
      if (row.containsKey(key)) key: row[key],
  };
  Map<String, Object?> task(Map row) => {
    for (final key in const [
      'task_id',
      'task_rev',
      'kind',
      'source_session_id',
      'state',
      'wait_reason',
      'cancel_requested',
      'operation',
      'executor_id',
      'local_date',
      'local_time',
      'zone_id',
      'epoch_ms',
      'offset_seconds',
    ])
      if (row.containsKey(key)) key: row[key],
  };
  return {
    'retiredAfterMemoryChange': true,
    for (final key in const [
      'applied',
      'accepted',
      'replayed',
      'code',
      'ok',
      'error',
      'changedCardIds',
      'currentCardRevisions',
      'targetId',
      'readOnly',
      'limited',
      'sourceSessionId',
      'receiptError',
      // A forget that asked to erase original chat as well: what is still
      // waiting for the person, so her reply does not claim it is gone.
      'pendingRawEraseId',
      'rawEraseState',
      'rawEraseMessage',
    ])
      if (decoded.containsKey(key)) key: decoded[key],
    if (decoded['task'] case final Map row) 'task': task(row),
    if (decoded['tasks'] case final List rows) 'tasks': [for (final row in rows.whereType<Map>()) task(row)],
    if (decoded['selection'] case final Map selection)
      'selection': {
        for (final key in const ['type', 'version', 'scope'])
          if (selection.containsKey(key)) key: selection[key],
        if (selection['items'] case final List rows) 'items': [for (final row in rows.whereType<Map>()) card(row)],
      },
    if (decoded['cards'] case final List rows) 'cards': [for (final row in rows.whereType<Map>()) card(row)],
  };
}

// Only the real adapter's applied receipt permits this narrow exception.
// Creating a new entry and changing followup/plan state do not revoke text.
// An update, destructive operation, or unknown own control remains retired.
bool _controlRetiresText(CompanionAgentToolCall call, CompanionAgentToolResult result) {
  Object? decoded;
  try {
    decoded = jsonDecode(result.content);
  } on FormatException {
    return true;
  }
  if (decoded is! Map || decoded['applied'] != true) return true;
  if (const ['remember', 'person', 'diary', 'impression'].contains(call.name)) {
    return call.input['card'] != null;
  }
  return !const ['ask_later', 'cancel', 'postpone'].contains(call.name);
}

// A later own control invalidates an earlier raw-erase proposal. Its durable
// card outcome stays, but the old result must not claim it is still pending.
Map<String, Object?> _withoutRawEraseFields(Map<String, Object?> result) {
  if (result['type'] != 'tool_result') return result;
  final content = result['content'];
  if (content is! String) return result;
  Object? decoded;
  try {
    decoded = jsonDecode(content);
  } on FormatException {
    return result;
  }
  if (decoded is! Map) return result;
  const fields = ['pendingRawEraseId', 'rawEraseState', 'rawEraseMessage'];
  if (!fields.any(decoded.containsKey)) return result;
  final remaining = Map<String, Object?>.from(decoded);
  for (final field in fields) {
    remaining.remove(field);
  }
  return {...result, 'content': jsonEncode(remaining)};
}

Map<String, Object?> _retiredToolResult(Map<String, Object?> result) => {
  ...result,
  'content': jsonEncode(_safeToolOutcome(result['content']! as String)),
};

CompanionAgentMessage _retiredToolArguments(CompanionAgentMessage message) => CompanionAgentMessage(
  content: [
    for (final block in message.content)
      if (block['type'] == 'tool_use')
        {
          ...block,
          // Explicitly absent historical arguments, never invented replacements.
          // Matching original call IDs and actual result facts stay intact.
          'input': const {'_retired_after_memory_change': true},
        },
  ],
  stopReason: message.stopReason,
);

void _retireCompanionAgentExchanges(List<CompanionAgentExchange> exchanges) {
  for (var i = 0; i < exchanges.length; i++) {
    final exchange = exchanges[i];
    exchanges[i] = (
      assistant: _retiredToolArguments(exchange.assistant),
      results: [for (final result in exchange.results) _retiredToolResult(result)],
    );
  }
}

/// One physical request. Its caller reserves and settles the real receipt;
/// cancellation always drains the first StreamIterator cancellation future.
class CompanionAgentModelRequest {
  CompanionAgentModelRequest(this.id);

  final String id;
  final settled = Completer<void>();
  http.Client? client;
  StreamIterator<String>? stream;
  Future<void>? cancellation;
  DshHttpAbort? _hostAbort;
  Future<void>? _hostDrain;
  bool sent = false;
  bool uncertain = false;
  bool notSentProven = false;
  bool finalized = false;
  String text = '';

  Future<CompanionAgentMessage?> read({
    required http.Client client,
    required String apiKey,
    required String system,
    required List<Map<String, Object?>> messages,
    required List<CompanionAgentTool> tools,
    required bool Function() isCurrent,
    required void Function(String) onText,
    required void Function() onSent,
    required void Function(CompanionUsage) onUsage,
    void Function(Map<String, Object?>, {required bool partial})? onUsageSettled,
    int maxTokens = 800,
  }) async {
    this.client = client;
    CompanionAgentMessage? message;
    final iterator = stream = StreamIterator(
      streamCompanionAgentReply(
        client: client,
        apiKey: apiKey,
        system: system,
        messages: messages,
        tools: tools,
        maxTokens: maxTokens,
        onMessage: (value) => message = value,
        onSent: onSent,
        onUsage: onUsage,
        onUsageSettled: onUsageSettled,
      ),
    );
    while (await iterator.moveNext()) {
      if (!isCurrent()) return null;
      onText(iterator.current);
    }
    return message;
  }

  Future<CompanionAgentMessage?> readHost({
    required DshClient client,
    required CompanionAuxiliaryCapability capability,
    required String system,
    required List<Map<String, Object?>> messages,
    required List<CompanionAgentTool> tools,
    required bool Function() isCurrent,
    required void Function(String) onText,
    required void Function() onDispatchUncertain,
    required void Function() onSent,
    required void Function(Map<String, Object?>) onUsage,
    void Function(Map<String, Object?>, {required bool partial})? onUsageSettled,
    int maxTokens = 800,
  }) async {
    if (!isCurrent()) return null;
    final abort = _hostAbort = DshHttpAbort();
    final future = client.callCompanionAgent(
      capability,
      requestId: id,
      system: system,
      messages: messages,
      tools: [for (final tool in tools) tool.toJson()],
      maxTokens: maxTokens,
      abort: abort,
      onDispatchUncertain: onDispatchUncertain,
      onSent: onSent,
      onText: (delta) {
        if (!isCurrent()) {
          abort.abort();
          return;
        }
        onText(delta);
      },
      onUsage: (usage) {
        // Late receipts still belong to this captured physical request.
        onUsage(usage);
        final view = CompanionUsage.fromReceipt(usage);
        onUsageSettled?.call(view.telemetry, partial: !view.complete);
      },
    );
    _hostDrain = future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    try {
      final result = await future;
      notSentProven = result.dispatched == false;
      if (!isCurrent() || abort.isAborted) return null;
      final message = result.message;
      if (message == null) {
        throw CompanionHostError(
          companionHostFailure(result.errorCode, httpStatus: result.httpStatus),
          result.errorCode ?? result.terminal,
        );
      }
      return CompanionAgentMessage(
        content: (message['content']! as List).cast<Map<String, Object?>>(),
        stopReason: message['stopReason']! as String,
        source: message['source']! as Map<String, Object?>,
      );
    } on CompanionAuxiliaryFailure catch (error) {
      notSentProven = error.notSent;
      throw CompanionHostError(companionHostFailure(error.code, httpStatus: error.httpStatus), error.code);
    } finally {
      abort.abort();
    }
  }

  Future<void> drain() {
    _hostAbort?.abort();
    final host = _hostDrain;
    if (host != null) return cancellation ??= host;
    final iterator = stream;
    if (iterator == null) return Future<void>.value();
    return cancellation ??= iterator.cancel();
  }
}

/// Chat and maintenance use the same completed-message/tool-result sequence.
/// The caller owns its context, physical receipts and presentation; a memory
/// worker never needs to take over the foreground Agent's current run.
Future<CompanionAgentMessage?> runCompanionAgentLoop({
  required List<CompanionAgentToolBinding> tools,
  required List<CompanionAgentExchange> exchanges,
  required bool Function() isCurrent,
  required int Function() controlRevision,
  required Future<CompanionAgentResponse?> Function() request,
  bool retainToolOutcomes = false,
  void Function()? onToolDispatch,
  void Function(String requestId, String callId, String words)? onNotice,
}) async {
  while (isCurrent()) {
    final response = await request();
    if (!isCurrent() || response == null) return null;
    final calls = response.message.calls;
    if (response.message.stopReason != 'tool_use' || calls.isEmpty) {
      return response.message;
    }

    final results = <Map<String, Object?>>[];
    var retireArguments = false;
    for (final call in calls) {
      if (!isCurrent()) return null;
      // Unknown and read-only calls also retire a no-tool retry opportunity.
      // Mark dispatch before an executor can synchronously commit anything.
      onToolDispatch?.call();
      final before = controlRevision();
      CompanionAgentToolBinding? binding;
      for (final candidate in tools) {
        if (candidate.definition.name == call.name) {
          binding = candidate;
          break;
        }
      }
      CompanionAgentToolResult result;
      if (binding == null) {
        result = const CompanionAgentToolResult(
          content: '{"ok":false,"error":"unavailable_tool","message":"This tool is not available in this turn."}',
          isError: true,
        );
      } else {
        try {
          result = await binding.execute(call);
        } on Object {
          result = const CompanionAgentToolResult(
            content: '{"ok":false,"error":"tool_failed","message":"The operation did not return a confirmed result."}',
            isError: true,
          );
        }
      }
      if (result.notice case final notice?) {
        onNotice?.call(response.requestId, call.id, notice);
      }
      if (!isCurrent()) return null;
      final controlChanged = controlRevision() != before;
      if (retainToolOutcomes && controlChanged) {
        // Clear only prior outcomes, including when a new remember keeps text.
        // The current returned result is added below, with any fresh pending.
        for (var i = 0; i < exchanges.length; i++) {
          final exchange = exchanges[i];
          exchanges[i] = (
            assistant: exchange.assistant,
            results: [for (final previous in exchange.results) _withoutRawEraseFields(previous)],
          );
        }
        for (var i = 0; i < results.length; i++) {
          results[i] = _withoutRawEraseFields(results[i]);
        }
      }
      final retireText = controlChanged && (!retainToolOutcomes || _controlRetiresText(call, result));
      if (retireText) {
        if (retainToolOutcomes) {
          _retireCompanionAgentExchanges(exchanges);
          retireArguments = true;
          for (var i = 0; i < results.length; i++) {
            results[i] = _retiredToolResult(results[i]);
          }
        } else {
          if (_controlRetiresText(call, result)) retireArguments = true;
          // Maintenance keeps its existing result-retirement contract.
          for (final previous in results) {
            previous['content'] =
                'This earlier result was retired after memory changed. Use the current memory context.';
          }
        }
      }
      final returned = <String, Object?>{
        'type': 'tool_result',
        'tool_use_id': call.id,
        'content': result.content,
        if (result.isError) 'is_error': true,
      };
      results.add(retainToolOutcomes && retireText ? _retiredToolResult(returned) : returned);
    }
    exchanges.add((
      assistant: retireArguments ? _retiredToolArguments(response.message) : response.message,
      results: results,
    ));
  }
  return null;
}
