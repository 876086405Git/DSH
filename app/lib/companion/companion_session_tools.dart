// The active phone offers only the bindings made for this person's message.
// Host and Flutter each own one side of the same DSH callId.
import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';

import 'companion_agent_loop.dart';
import 'companion_light.dart';
import 'companion_notice_channel.dart';

class CompanionSessionTools {
  CompanionSessionTools._(this._connection, this._session, this._request, this._bindings, this._current);

  static const _root = '/dsh-go/v1/companion/session-tools';
  // These operations run through the phone's own feature-specific adapters.
  // General device control stays with the enabled native MCP and its policy.
  static const _supported = {
    'remember',
    'forget',
    'revise',
    'related',
    'merge',
    'person',
    'diary',
    'relationship',
    'impression',
    'quiet',
    'cancel',
    'postpone',
    'ask_later',
    'recall',
    'task_status',
    'reminder',
    'map_open',
    'photos_recent',
    'photo_view',
    'recent_notices',
    'notify_user',
    'notes_to_todo',
    'find_draft',
    'compare_drafts',
    'receipts_to_sheet',
  };
  final DshConnection _connection;
  final String _session, _request;
  final Map<String, CompanionAgentToolBinding> _bindings;
  final bool Function() _current;
  final _abort = DshHttpAbort();
  final _calls = <String>{};
  final _seen = <String>{};
  String? _token;

  /// Returns null only when this carrier or an older bridge has no callback.
  /// The explicit null idle timeout lets the person answer a long approval.
  static Future<CompanionSessionTools?> open(
    DshClient client, {
    required String sessionId,
    required String requestId,
    required List<CompanionAgentToolBinding> tools,
    required bool Function() isCurrent,
    // Kept until the A04 caller is cleaned up in A07. Neither argument grants a tool.
    bool local = false,
    void Function()? stopPhone,
  }) async {
    final carrier = client.carrier;
    if (carrier is! DshHttpCarrier || tools.isEmpty) return null;
    final bindings = {
      for (final binding in tools)
        if (_supported.contains(binding.definition.name)) binding.definition.name: binding,
    };
    if (bindings.isEmpty) return null;
    final owner = CompanionSessionTools._(carrier.connection, sessionId, requestId, bindings, isCurrent);
    try {
      if (!isCurrent()) throw const DshClosedException('Companion turn was replaced');
      final response = await carrier.connection.postJsonStream(
        '$_root/open',
        {
          'sessionId': sessionId,
          'requestId': requestId,
          'tools': [for (final binding in bindings.values) binding.definition.toJson()],
        },
        abort: owner._abort,
        headerTimeout: const Duration(seconds: 8),
        idleTimeout: null,
      );
      if (response.statusCode == 404) {
        owner.close();
        return null;
      }
      if (response.statusCode == 409) {
        final bytes = await response.body.expand((chunk) => chunk).toList();
        final data = jsonDecode(utf8.decode(bytes));
        if (data case {'error': {'code': 'companion/device-request-in-use'}}) {
          owner.close();
          return null; // chat.send can reconcile the original requestId.
        }
        if (data case {'error': {'code': final String code}}) {
          if (const {
            'companion/device-connection-replaced',
            'companion/device-session-unavailable',
            'companion/device-unavailable', // Older bridge.
          }.contains(code)) {
            throw CompanionHostError(CompanionHostFailure.deviceConflict, code);
          }
        }
      }
      if (response.statusCode != 200 || response.contentType != 'application/x-ndjson') {
        throw DshProtocolException('Companion device stream returned HTTP ${response.statusCode}');
      }
      final ready = Completer<void>();
      unawaited(owner._listen(response, ready));
      await ready.future.timeout(const Duration(seconds: 8));
      if (!isCurrent()) throw const DshClosedException('Companion turn was replaced');
      return owner;
    } catch (_) {
      owner.close();
      rethrow;
    }
  }

  Future<void> _listen(DshHttpStreamResponse response, Completer<void> ready) async {
    try {
      final lines = response.body.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        final frame = jsonDecode(line) as Map<String, Object?>;
        if (!ready.isCompleted) {
          if (frame['type'] != 'ready' || frame['token'] is! String) {
            throw const DshProtocolException('Missing companion device ready');
          }
          _token = frame['token']! as String;
          ready.complete();
          continue;
        }
        if (!_current()) break;
        final id = frame['callId']! as String;
        if (frame['type'] == 'cancel') {
          _calls.remove(id);
        } else if (frame['type'] == 'call') {
          final name = frame['name']! as String;
          if (!_seen.add(id)) throw const DshProtocolException('Duplicate companion device call');
          _calls.add(id);
          unawaited(_execute(id, name, frame['input']! as Map<String, Object?>));
        }
      }
    } catch (error, stack) {
      if (!ready.isCompleted) ready.completeError(error, stack);
    } finally {
      if (!ready.isCompleted) ready.completeError(const DshClosedException('Companion device stream closed'));
      close();
    }
  }

  Future<void> _execute(String id, String name, Map<String, Object?> input) async {
    final binding = _bindings[name];
    CompanionAgentToolResult result;
    try {
      if (binding == null || !_current() || _abort.isAborted) {
        throw const DshClosedException('This phone capability is unavailable');
      }
      result = await binding.execute(CompanionAgentToolCall(id: id, name: name, input: input));
    } catch (error) {
      result = CompanionAgentToolResult(content: error.toString(), isError: true);
    }
    if (!_calls.remove(id) || _abort.isAborted || !_current()) return;
    try {
      final reply = await _connection.postJson('$_root/result', {
        'sessionId': _session,
        'requestId': _request,
        'token': _token,
        'callId': id,
        'content': _sessionContent(name, result),
        'isError': result.isError,
      }, timeout: const Duration(seconds: 8));
      if (reply.statusCode != 200) close();
    } on Object {
      // Closing rejects this Host promise as unknown. Replaying a phone action
      // after a lost response could set two reminders.
      close();
    }
  }

  // Both recall and related can return ordinary and notification cards in one
  // result. The latter stay on the phone rather than entering the Host tool log.
  static String _sessionContent(String name, CompanionAgentToolResult result) {
    if (!result.externalNoticeContent) return result.content;
    final data = jsonDecode(result.content) as Map<String, Object?>;
    final rows = name == 'recall' ? (data['selection'] as Map)['items'] as List : data['cards'] as List;
    rows.removeWhere((row) => row is Map && row['source'] is Map && row['source']['kind'] == 'notice');
    return jsonEncode(data);
  }

  void close() {
    if (_abort.isAborted) return;
    _calls.clear();
    _abort.abort();
  }
}

/// The notice listener and the existing memory store own permissions and data.
/// Reading summaries has no effect on the listener's pending delivery queue.
CompanionAgentToolBinding companionRecentNoticesTool({
  required CompanionNotices notices,
  required List<MemoryRow> Function() readSummaries,
  required bool Function() isCurrent,
  DateTime Function() now = DateTime.now,
}) => (
  definition: const CompanionAgentTool(
    name: 'recent_notices',
    description:
        'Count the eligible notification summaries from the apps the user allowed. '
        'Notification content is shown by the existing private phone flow.',
    inputSchema: {'type': 'object', 'properties': <String, Object?>{}, 'additionalProperties': false},
  ),
  execute: (_) async {
    final status = await notices.status();
    if (!isCurrent() || !status.readable) {
      return const CompanionAgentToolResult(isError: true, content: '当前无法读取伙伴通知摘要。');
    }
    final at = now().millisecondsSinceEpoch;
    var visible = 0;
    for (final row in readSummaries()) {
      final source = row['source']! as Map;
      if (status.level(source['package']! as String) != CompanionNoticeLevel.remember ||
          !isMemoryContextEligible(row, nowMs: at)) {
        continue;
      }
      visible++;
    }
    return CompanionAgentToolResult(
      content: jsonEncode({'retainedSummaryCount': visible, 'message': '这是当前可用的通知摘要数量。通知正文和草稿由手机现有通知流程展示。'}),
    );
  },
);

CompanionAgentToolBinding companionNotifyTool({required Future<bool> Function(String id, String text) deliver}) => (
  definition: const CompanionAgentTool(
    name: 'notify_user',
    description: 'Show a local companion notification to this phone owner.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
      },
      'required': ['text'],
      'additionalProperties': false,
    },
  ),
  execute: (call) async {
    final text = call.input['text'];
    if (text is! String || text.trim().isEmpty) {
      return const CompanionAgentToolResult(isError: true, content: '通知需要显示的文字。');
    }
    final delivered = await deliver('companion:${call.id}', text);
    return CompanionAgentToolResult(isError: !delivered, content: delivered ? '这台手机已接收本地通知。' : '这次未能显示本地通知。');
  },
);
