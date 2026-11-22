// Behaviour contract: starowo/starowo.github.io, commit
// 53bd585da14248ba10baaede7fc7ed0cebe1eeeb, regex_bind/inject.js.
// This is an independent implementation of the public preset data protocol.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart' as crypto;

import 'prompt/preset.dart';
import 'prompt/prompt_types.dart';
import 'scripts.dart';
import 'js_string.dart';

part 'spreset/config.dart';
part 'spreset/messages.dart';
part 'spreset/squash.dart';
part 'spreset/output.dart';
part 'spreset/log.dart';

/// Optional App capability; the existing TavernScriptHost ABI is unchanged.
/// Evaluate in the active chat's persistent page realm, including that page's
/// localStorage, TavernHelper and SillyTavern facades. Never evaluate in a fresh
/// unrelated iframe. A session retains the compiled function and its closures.
/// The host Future must settle after cancellation/page teardown; an App may
/// immediately return an error with unknown effects while page JS still runs.
/// Engine close/backup wait for that host Future, not proof of JS termination.
/// Cancellation must never be reported as committed=false without evidence.
abstract interface class TavernSPresetScriptHost {
  Future<TavernSPresetEvaluationResult> evaluateSPreset(
    TavernSPresetEvaluationRequest request,
    TavernScriptCancellation cancellation,
  );
  Future<void> releaseSPresetSession(String sessionId);
}

/// Optional observation after every native request transformation, before send.
abstract interface class TavernSPresetRequestObserver {
  Future<void> observeSPresetRequest(TavernSPresetRequestSnapshot request, TavernScriptCancellation cancellation);
}

/// Optional local report capability. Kept outside Tavern so existing App
/// wrappers and preview implementations do not acquire new abstract members.
/// An App wrapper may explicitly expose and forward this capability when its
/// delegate implements it; it must not assume every Tavern is an engine.
abstract interface class TavernSPresetLogApi {
  /// The App supplies snapshots from the active page. Omitted snapshots are
  /// explicitly unavailable; the engine cannot observe a browser console.
  Future<Map<String, Object?>> exportSPresetLogs(
    String chatId, {
    Map<String, Object?>? tavernHelper,
    Map<String, Object?>? browserConsole,
  });

  /// Explicit action requiring spresetLogUploadEnabled in App settings.
  Future<Map<String, Object?>> uploadSPresetLogs(
    String chatId, {
    String? address,
    String? bearerToken,
    Map<String, Object?>? tavernHelper,
    Map<String, Object?>? browserConsole,
  });
}

class TavernSPresetRequestSnapshot {
  TavernSPresetRequestSnapshot({required this.chatId, required this.generationId, required Map<String, Object?> body})
    : _body = _spObjectCopy(body);
  final String chatId;
  final String generationId;
  final Map<String, Object?> _body;
  Map<String, Object?> get body => _spObjectCopy(_body);
}

/// functionExpression evaluates an expression to a function and awaits its
/// invocation. syncFunctionExpression uses direct eval and does not await the
/// returned function's result. toolRegistry synchronizes all active bindings
/// in one page operation, preserving UUID and transient evaluation caches.
/// toolDefinition evaluates one retained tool (legacy direct host operation);
/// the host retains action/formatMessage and returns only JSON fields.
/// toolAction and toolFormatMessage invoke those retained functions.
enum TavernSPresetEvaluationKind {
  validateFunctionExpression,
  functionExpression,
  syncFunctionExpression,
  toolRegistry,
  toolDefinition,
  toolAction,
  toolFormatMessage,
}

class TavernSPresetEvaluationRequest {
  TavernSPresetEvaluationRequest({
    required this.requestId,
    required this.chatId,
    required this.generationId,
    required this.sessionId,
    required this.stage,
    required this.source,
    this.identifier,
    this.cacheKey,
    this.kind = TavernSPresetEvaluationKind.functionExpression,
    this.reset = false,
    this.captureLogs = false,
    List<Object?> arguments = const [],
  }) : _arguments = _spCopy(arguments)! as List<Object?>;
  final String requestId, chatId, generationId, sessionId, stage, source;
  final String? identifier;

  /// Legacy single-tool identity hint. Ordinary engine ToolBindings uses the
  /// toolRegistry operation and its raw UUID keys; callbacks use sessionId to
  /// retain exactly the registered object, including same-UUID code changes.
  final String? cacheKey;
  final TavernSPresetEvaluationKind kind;
  final bool reset;
  final bool captureLogs;
  final List<Object?> _arguments;
  List<Object?> get arguments => _spCopy(_arguments)! as List<Object?>;
  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'chatId': chatId,
    'generationId': generationId,
    'sessionId': sessionId,
    'stage': stage,
    'source': source,
    'identifier': identifier,
    'cacheKey': cacheKey,
    'kind': kind.name,
    'reset': reset,
    'captureLogs': captureLogs,
    'arguments': arguments,
  };
}

class TavernSPresetEvaluationResult {
  TavernSPresetEvaluationResult({
    required this.requestId,
    Object? value,
    this.isUndefined = false,
    this.committed,
    this.scriptLogsDropped = 0,
    this.scriptLogValuesTruncated = 0,
    List<Object?> arguments = const [],
    List<TavernScriptIssue> issues = const [],
    List<Map<String, Object?>> scriptLogs = const [],
  }) : _value = _spCopy(value),
       _scriptLogs = scriptLogs.map(_spObjectCopy).toList(),
       _arguments = _spCopy(arguments)! as List<Object?>,
       issues = List.unmodifiable(issues);
  final String requestId;
  factory TavernSPresetEvaluationResult.fromJson(Map<String, Object?> value) => TavernSPresetEvaluationResult(
    requestId: value['requestId']! as String,
    value: value['value'],
    isUndefined: value['isUndefined'] == true,
    committed: value['committed'] as bool?,
    arguments: value['arguments'] as List<Object?>? ?? const [],
    scriptLogs: _spRows(value['scriptLogs']),
    scriptLogsDropped: (value['scriptLogsDropped'] as num?)?.toInt() ?? 0,
    scriptLogValuesTruncated: (value['scriptLogValuesTruncated'] as num?)?.toInt() ?? 0,
  );
  final Object? _value;
  final List<Map<String, Object?>> _scriptLogs;
  Object? get value => _spCopy(_value);
  List<Map<String, Object?>> get scriptLogs => _scriptLogs.map(_spObjectCopy).toList();
  final bool isUndefined;
  final int scriptLogsDropped;
  final int scriptLogValuesTruncated;

  /// Actual side-effect fact for tool actions: true = known committed effects,
  /// false = known no committed effects, null = unknown. Returning normally
  /// from arbitrary JavaScript alone does not establish either boolean.
  final bool? committed;
  final List<Object?> _arguments;
  final List<TavernScriptIssue> issues;
  List<Object?> get arguments => _spCopy(_arguments)! as List<Object?>;
}

typedef SPresetEvaluate =
    Future<TavernSPresetEvaluationResult> Function(
      String stage,
      String source,
      List<Object?> arguments, {
      String? identifier,
      String? sessionId,
      bool reset,
      TavernSPresetEvaluationKind kind,
    });

typedef SPresetDiagnostic = void Function(String stage, Object error);

class SPresetException implements Exception {
  const SPresetException(this.stage, this.detail);
  final String stage, detail;
  @override
  String toString() => 'SPresetException($stage): $detail';
}

Object? _spCopy(Object? value) => value == null ? null : jsonDecode(jsonEncode(value));
Map<String, Object?> _spObjectCopy(Map<String, Object?> value) => _spCopy(value)! as Map<String, Object?>;
Map<String, Object?> _spMap(Object? value) => value is Map<String, Object?> ? value : const {};
List<Map<String, Object?>> _spRows(Object? value) =>
    value is List<Object?> ? value.whereType<Map<String, Object?>>().toList() : const [];
String _spString(Object? value, [String fallback = '']) => value == null ? fallback : presetString(value);
