import 'dart:async';

import 'package:http/http.dart' as http;

import 'companion_light.dart';

typedef CompanionAgentToolBinding = ({
  CompanionAgentTool definition,
  Future<CompanionAgentToolResult> Function(CompanionAgentToolCall) execute,
});

typedef CompanionAgentExchange = ({CompanionAgentMessage assistant, List<Map<String, Object?>> results});

typedef CompanionAgentResponse = ({CompanionAgentMessage message, String requestId});

/// One physical request. Its caller reserves and settles the real receipt;
/// cancellation always drains the first StreamIterator cancellation future.
class CompanionAgentModelRequest {
  CompanionAgentModelRequest(this.id);

  final String id;
  final settled = Completer<void>();
  http.Client? client;
  StreamIterator<String>? stream;
  Future<void>? cancellation;
  bool sent = false;
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

  Future<void> drain() {
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
      if (controlRevision() != before) {
        // The matching assistant IDs stay intact. Earlier result bodies in
        // this batch no longer carry stale recall after a control commit.
        for (final previous in results) {
          previous['content'] = 'This earlier result was retired after memory changed. Use the current memory context.';
        }
      }
      results.add({
        'type': 'tool_result',
        'tool_use_id': call.id,
        'content': result.content,
        if (result.isError) 'is_error': true,
      });
    }
    exchanges.add((assistant: response.message, results: results));
  }
  return null;
}
