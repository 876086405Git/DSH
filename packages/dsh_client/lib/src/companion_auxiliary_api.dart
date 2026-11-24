/// One phone-owned auxiliary attempt: full-mode text, a completed Agent message,
/// or an explicitly selected optional screen-image route.
/// This uses the existing authenticated HTTP connection, never Session RPC,
/// Host tool execution, mux recovery, a provider fallback, or an automatic retry.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'carrier.dart';
import 'connection.dart';
import 'errors.dart';
import 'models.dart';
import 'session_api.dart';

const _path = '/dsh-go/v1/companion/auxiliary';
const _maxInputBytes = 65536;

/// Maximum UTF-8 bytes of the complete encoded Agent request body.
const companionAgentRequestMaxBytes = _maxInputBytes;
const _maxLineBytes = 192 * 1024;
const _maxStreamBytes = 8 * 1024 * 1024;
const _maxSafe = 9007199254740991;

/// The system, messages and tools of one Agent request, JSON-encoded once.
/// [json] feeds the token estimate; callCompanionAgent splices the same text
/// into the body it measures and sends, so later changes to the caller's maps
/// never reach the request.
final class CompanionAgentInput {
  factory CompanionAgentInput({
    required String system,
    required List<Map<String, Object?>> messages,
    required List<Map<String, Object?>> tools,
  }) => CompanionAgentInput._(_agentJson(system), _agentJson(tools), _text(system) && _agentTools(tools), messages);

  CompanionAgentInput._(this._system, this._tools, this._fixedValid, List<Map<String, Object?>> messages)
    : _valid = _fixedValid && _agentMessages(messages),
      json = '{"system":$_system,"messages":${_agentJson(messages)},"tools":$_tools}';

  final String _system, _tools;
  final bool _fixedValid, _valid;

  /// Exactly `jsonEncode({'system': system, 'messages': messages, 'tools': tools})`.
  final String json;
  late final Uint8List _fields = utf8.encode(json.substring(1, json.length - 1));

  /// The same system and tools with other messages; only the messages are encoded.
  CompanionAgentInput withMessages(List<Map<String, Object?>> messages) =>
      CompanionAgentInput._(_system, _tools, _fixedValid, messages);

  /// UTF-8 size of the body callCompanionAgent sends for this input.
  int requestBytes(CompanionAuxiliaryCapability host, {required String requestId, required int maxTokens}) {
    final (head, tail) = _ends(host, requestId, maxTokens);
    return head.length + _fields.length + tail.length;
  }

  Uint8List _body(CompanionAuxiliaryCapability host, String requestId, int maxTokens) {
    final (head, tail) = _ends(host, requestId, maxTokens);
    return (BytesBuilder(copy: false)
          ..add(head)
          ..add(_fields)
          ..add(tail))
        .takeBytes();
  }

  (Uint8List, Uint8List) _ends(CompanionAuxiliaryCapability host, String requestId, int maxTokens) {
    final head = jsonEncode({
      'v': 1,
      'instanceId': host.instanceId,
      'requestId': requestId,
      'sessionId': host.sessionId,
      'provider': host.provider,
      'model': host.model,
      'kind': 'agent',
    });
    return (utf8.encode('${head.substring(0, head.length - 1)},'), utf8.encode(',"maxTokens":$maxTokens}'));
  }
}

String _agentJson(Object? value) {
  try {
    return jsonEncode(value);
  } on JsonUnsupportedObjectError {
    throw const CompanionAuxiliaryFailure(code: 'invalid-request', terminal: 'preflight_error', notSent: true);
  }
}

/// The actual selection and bridge generation read for one full Session.
/// Unknown physical dispatch/raw usage does not make a callable route unsupported.
class CompanionAuxiliaryCapability {
  const CompanionAuxiliaryCapability._({
    required DshClient owner,
    required this.sessionId,
    required this.instanceId,
    required this.provider,
    required this.model,
    required this.supported,
    required this.physicalDispatch,
    required this.rawUsage,
    required this.maxPhysicalRequests,
    this.agentSupported = false,
  }) : _owner = owner;

  final DshClient _owner;
  final String sessionId;
  final String instanceId;
  final String provider;
  final String model;
  final bool supported;

  /// `fetch-invoked` is an observation of the Host calling fetch, not delivery
  /// to the provider or proof of billing. `unknown` offers no physical count.
  final String? physicalDispatch;
  final String? rawUsage;
  final int? maxPhysicalRequests;

  /// The Host can return complete tool calls for execution by the phone.
  /// Older Hosts retain their text-only capability and default to false.
  final bool agentSupported;
}

/// One explicitly selected image route. It belongs to this client and bridge,
/// not a Session or the companion's ordinary chat model.
class CompanionScreenCapability {
  const CompanionScreenCapability._({
    required DshClient owner,
    required this.instanceId,
    required this.selection,
    required this.supported,
  }) : _owner = owner;

  final DshClient _owner;
  final String instanceId;
  final ModelSelection selection;
  final bool supported;
}

/// A single transient JPEG produced by the qualified native screen sampler.
/// It is never submitted through session/attachment or written to a transcript.
class CompanionScreenImage {
  CompanionScreenImage._(Uint8List bytes, this.width, this.height) : _bytes = Uint8List.fromList(bytes);

  final Uint8List _bytes;
  final int width;
  final int height;

  static CompanionScreenImage? fromNative(Object? raw) {
    if (raw is! Map) return null;
    final bytes = raw['bytes'];
    final width = raw['width'];
    final height = raw['height'];
    if (raw['mime_type'] != 'image/jpeg' ||
        bytes is! Uint8List ||
        bytes.length < 4 ||
        bytes.length > 512 * 512 * 4 ||
        bytes[0] != 0xff ||
        bytes[1] != 0xd8 ||
        width is! int ||
        height is! int ||
        width < 1 ||
        width > 512 ||
        height < 1 ||
        height > 512) {
      return null;
    }
    return CompanionScreenImage._(bytes, width, height);
  }

  Map<String, Object?> toJson() => {
    'mediaType': 'image/jpeg',
    'width': width,
    'height': height,
    'data': base64Encode(_bytes),
  };
}

class CompanionAuxiliaryResult {
  const CompanionAuxiliaryResult._({
    required this.text,
    required this.terminal,
    required this.complete,
    required this.dispatched,
    required this.hostDispatchAtMs,
    required this.httpStatus,
    required this.errorCode,
    required this.usage,
  });

  final String text;
  final String terminal;
  final bool complete;

  /// Only false proves preflight without dispatch. Null must keep the phone's
  /// reservation and conservative request count, even after a valid finish.
  final bool? dispatched;
  final int? hostDispatchAtMs;
  final int? httpStatus;
  final String? errorCode;

  /// The finish usage object, with the original Host dispatch timestamp added.
  /// Runtime-normalized observations keep their own names; they are not raw.
  final Map<String, Object?> usage;
}

/// A completed Host model message, separately from its physical receipt.
/// Failure, truncation or cancellation can retain a receipt without granting
/// an executable message. Thinking and replay metadata never enter [text].
class DshCompanionAgentResult extends CompanionAuxiliaryResult {
  DshCompanionAgentResult._(CompanionAuxiliaryResult receipt, {required Map<String, Object?>? message})
    : message = message,
      super._(
        text: message == null
            ? receipt.text
            : (message['content']! as List<Map<String, Object?>>)
                  .where((block) => block['type'] == 'text')
                  .map((block) => block['text'] as String)
                  .join(''),
        terminal: receipt.terminal,
        complete: receipt.complete,
        dispatched: receipt.dispatched,
        hostDispatchAtMs: receipt.hostDispatchAtMs,
        httpStatus: receipt.httpStatus,
        errorCode: receipt.errorCode,
        usage: receipt.usage,
      );

  /// Anthropic-shaped content and stopReason with the actual Host source.
  /// This becomes non-null only after the matching successful finish settles.
  final Map<String, Object?>? message;
}

/// An exchange failure, as distinct from a complete but invalid model answer.
/// A broken pipe, a missing finish, an old bridge generation and a repeated ID
/// cannot establish [notSent]. No exception message contains prompt text.
class CompanionAuxiliaryFailure implements Exception {
  const CompanionAuxiliaryFailure({required this.code, required this.terminal, required this.notSent, this.httpStatus});

  final String code;
  final String terminal;
  final bool notSent;
  final int? httpStatus;

  @override
  String toString() => 'CompanionAuxiliaryFailure($code, $terminal, notSent: $notSent)';
}

extension CompanionAuxiliaryApi on DshClient {
  /// Discovery does not submit a model request. Null denotes a carrier without
  /// this HTTP route or an older Host's unclaimed 404, not a model fallback.
  Future<CompanionAuxiliaryCapability?> readCompanionAuxiliaryCapability(
    String sessionId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!_id(sessionId)) throw ArgumentError('invalid companion auxiliary session');
    final transport = carrier;
    if (transport is! DshHttpCarrier) return null;
    final response = await transport.connection.get(
      _path,
      query: {'sessionId': sessionId},
      timeout: timeout,
      followRedirects: false,
      maxResponseBytes: 4096,
    );
    Map<String, Object?>? map;
    if (response.contentType == 'application/json') {
      try {
        map = _map(jsonDecode(utf8.decode(response.body)));
      } on FormatException {
        throw const DshProtocolException('invalid auxiliary capability JSON');
      }
    }
    final discoveryCode = _map(map?['error'])?['code'];
    // The original companion bridge claims its namespace but returns this
    // exact code for an unknown subroute. An auxiliary-specific 404 is still
    // an error from an existing route, not an older Host without the route.
    if (response.statusCode == 404 && (discoveryCode == null || discoveryCode == 'companion/not-found')) return null;
    if (response.statusCode != 200) {
      if (discoveryCode is String) {
        throw CompanionAuxiliaryFailure(
          code: discoveryCode,
          terminal: 'preflight_error',
          notSent: true,
          httpStatus: response.statusCode,
        );
      }
      throw DshHttpException(response.statusCode, 'Auxiliary capability request failed');
    }
    if (map == null ||
        map['v'] != 1 ||
        map['supported'] is! bool ||
        !_id(map['instanceId']) ||
        !_id(map['provider']) ||
        !_id(map['model'])) {
      throw const DshProtocolException('invalid auxiliary capability');
    }
    final supported = map['supported'] as bool;
    final detail = _map(map['capability']);
    final agent = _map(map['agent']);
    if (map['agent'] != null &&
        (agent == null || agent['v'] != 1 || agent['tools'] != 'return-only' || agent['streaming'] != true)) {
      throw const DshProtocolException('invalid companion Agent capability');
    }
    if (supported &&
        (detail == null ||
            detail['noTools'] != true ||
            !const {'fetch-invoked', 'unknown'}.contains(detail['physicalDispatch']) ||
            !const {'deepseek-messages-cumulative', 'unavailable'}.contains(detail['rawUsage']) ||
            !detail.containsKey('maxPhysicalRequests') ||
            (detail['maxPhysicalRequests'] != null &&
                (detail['maxPhysicalRequests'] is! int || detail['maxPhysicalRequests'] != 1)))) {
      throw const DshProtocolException('invalid auxiliary observation capability');
    }
    return CompanionAuxiliaryCapability._(
      owner: this,
      sessionId: sessionId,
      instanceId: map['instanceId'] as String,
      provider: map['provider'] as String,
      model: map['model'] as String,
      supported: supported,
      physicalDispatch: supported ? detail!['physicalDispatch'] as String : null,
      rawUsage: supported ? detail!['rawUsage'] as String : null,
      maxPhysicalRequests: supported ? detail!['maxPhysicalRequests'] as int? : null,
      agentSupported: supported && agent != null,
    );
  }

  /// No model request or image is sent during this discovery. An unsupported
  /// adapter/model may keep the existing text observation before any handoff.
  Future<CompanionScreenCapability?> readCompanionScreenCapability(
    ModelSelection selection, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!_id(selection.provider) ||
        !_id(selection.model) ||
        (selection.reasoningEffort != null && !_id(selection.reasoningEffort))) {
      throw ArgumentError('invalid companion screen selection');
    }
    final transport = carrier;
    if (transport is! DshHttpCarrier) return null;
    final response = await transport.connection.get(
      _path,
      query: {
        'kind': 'screen',
        'provider': selection.provider,
        'model': selection.model,
        if (selection.reasoningEffort != null) 'reasoningEffort': selection.reasoningEffort!,
      },
      timeout: timeout,
      followRedirects: false,
      maxResponseBytes: 4096,
    );
    Map<String, Object?>? map;
    if (response.contentType == 'application/json') {
      try {
        map = _map(jsonDecode(utf8.decode(response.body)));
      } on FormatException {
        throw const DshProtocolException('invalid screen capability JSON');
      }
    }
    final code = _map(map?['error'])?['code'];
    if (response.statusCode == 404 && (code == null || code == 'companion/not-found')) return null;
    if (response.statusCode != 200) {
      throw DshHttpException(response.statusCode, 'Screen capability request failed');
    }
    if (map == null ||
        map['v'] != 1 ||
        map['kind'] != 'screen' ||
        map['supported'] is! bool ||
        !_id(map['instanceId']) ||
        map['provider'] != selection.provider ||
        map['model'] != selection.model ||
        map['reasoningEffort'] != selection.reasoningEffort) {
      throw const DshProtocolException('invalid screen capability');
    }
    final supported = map['supported'] as bool;
    final detail = _map(map['capability']);
    if (supported &&
        (detail == null ||
            detail['noTools'] != true ||
            detail['transientImage'] != 'jpeg-512-inline' ||
            detail['physicalDispatch'] != 'fetch-invoked' ||
            !const {'deepseek-messages-cumulative', 'unavailable'}.contains(detail['rawUsage']) ||
            detail['maxPhysicalRequests'] != 1)) {
      throw const DshProtocolException('invalid screen observation capability');
    }
    return CompanionScreenCapability._(
      owner: this,
      instanceId: map['instanceId'] as String,
      selection: selection,
      supported: supported,
    );
  }

  /// Reserve durably before calling. [onDispatchUncertain] runs synchronously
  /// before the POST can open a socket. [onSent] runs only after a validated
  /// physical observation, at most once. [onUsage] runs once after handoff,
  /// including on interruption; a complete finish is passed through unchanged
  /// apart from `host_dispatch_at_ms`. Partial streams retain known raw events.
  ///
  /// This call never refreshes [host], repeats a POST, or follows a redirect.
  /// A caller must not resend an uncertain attempt with a new capability.
  Future<CompanionAuxiliaryResult> callCompanionAuxiliary(
    CompanionAuxiliaryCapability host, {
    required String requestId,
    required String kind,
    required String system,
    required String input,
    required int maxTokens,
    required DshHttpAbort abort,
    required void Function() onDispatchUncertain,
    required void Function() onSent,
    required void Function(Map<String, Object?> usage) onUsage,
    Duration headerTimeout = const Duration(seconds: 10),
    Duration idleTimeout = const Duration(seconds: 100),
  }) async {
    final transport = carrier;
    if (!identical(host._owner, this) || transport is! DshHttpCarrier || !host.supported) {
      throw const CompanionAuxiliaryFailure(code: 'route-unavailable', terminal: 'preflight_error', notSent: true);
    }
    if (!_id(requestId) ||
        !const {'extract', 'consolidate', 'followup'}.contains(kind) ||
        !_text(system) ||
        !_text(input) ||
        maxTokens < 1 ||
        maxTokens > 3000 ||
        headerTimeout <= Duration.zero ||
        idleTimeout <= Duration.zero) {
      throw const CompanionAuxiliaryFailure(code: 'invalid-request', terminal: 'preflight_error', notSent: true);
    }
    final body = <String, Object?>{
      'v': 1,
      'instanceId': host.instanceId,
      'requestId': requestId,
      'sessionId': host.sessionId,
      'provider': host.provider,
      'model': host.model,
      'kind': kind,
      'system': system,
      'input': input,
      'maxTokens': maxTokens,
    };
    return _postAuxiliary(
      transport,
      body: utf8.encode(jsonEncode(body)),
      instanceId: host.instanceId,
      provider: host.provider,
      model: host.model,
      requestId: requestId,
      abort: abort,
      onDispatchUncertain: onDispatchUncertain,
      onSent: onSent,
      onUsage: onUsage,
      headerTimeout: headerTimeout,
      idleTimeout: idleTimeout,
      maxRequestBytes: _maxInputBytes,
      path: _path,
    );
  }

  /// One model round on the full companion Session's captured Host selection.
  /// Tools are returned to the phone, never executed by this endpoint. Text
  /// deltas are immediate; a message is released only after its finish receipt.
  Future<DshCompanionAgentResult> callCompanionAgent(
    CompanionAuxiliaryCapability host, {
    required String requestId,
    required CompanionAgentInput input,
    required int maxTokens,
    required DshHttpAbort abort,
    required void Function() onDispatchUncertain,
    required void Function() onSent,
    required void Function(Map<String, Object?> usage) onUsage,
    required void Function(String text) onText,
    Duration headerTimeout = const Duration(seconds: 10),
    Duration idleTimeout = const Duration(seconds: 100),
  }) async {
    final transport = carrier;
    if (!identical(host._owner, this) || transport is! DshHttpCarrier || !host.agentSupported) {
      throw const CompanionAuxiliaryFailure(code: 'route-unavailable', terminal: 'preflight_error', notSent: true);
    }
    if (!_id(requestId) ||
        !input._valid ||
        maxTokens < 1 ||
        maxTokens > 4000 ||
        headerTimeout <= Duration.zero ||
        idleTimeout <= Duration.zero) {
      throw const CompanionAuxiliaryFailure(code: 'invalid-request', terminal: 'preflight_error', notSent: true);
    }
    final body = input._body(host, requestId, maxTokens);
    final receipt = _AgentReceipt(host.instanceId, host.provider, host.model, requestId, onSent, abort, onText);
    final result = await _postAuxiliary(
      transport,
      body: body,
      instanceId: host.instanceId,
      provider: host.provider,
      model: host.model,
      requestId: requestId,
      abort: abort,
      onDispatchUncertain: onDispatchUncertain,
      onSent: onSent,
      onUsage: onUsage,
      headerTimeout: headerTimeout,
      idleTimeout: idleTimeout,
      maxRequestBytes: _maxInputBytes,
      path: _path,
      observation: receipt,
    );
    // onSent/onUsage can retire the owner while the final receipt settles.
    return DshCompanionAgentResult._(result, message: abort.isAborted ? null : receipt.message);
  }

  /// One image attempt on the captured route. Failure, cancellation or unknown
  /// dispatch never starts another text request; the same receipt still settles.
  Future<CompanionAuxiliaryResult> callCompanionScreen(
    CompanionScreenCapability host, {
    required String requestId,
    required String system,
    required String input,
    required CompanionScreenImage image,
    required int maxTokens,
    required DshHttpAbort abort,
    required void Function() onDispatchUncertain,
    required void Function() onSent,
    required void Function(Map<String, Object?> usage) onUsage,
    Duration headerTimeout = const Duration(seconds: 10),
    Duration idleTimeout = const Duration(seconds: 100),
  }) async {
    final transport = carrier;
    if (!identical(host._owner, this) || transport is! DshHttpCarrier || !host.supported) {
      throw const CompanionAuxiliaryFailure(code: 'route-unavailable', terminal: 'preflight_error', notSent: true);
    }
    if (!_id(requestId) ||
        !_text(system) ||
        !_text(input) ||
        utf8.encode(system).length + utf8.encode(input).length > _maxInputBytes ||
        maxTokens < 1 ||
        maxTokens > 3000 ||
        headerTimeout <= Duration.zero ||
        idleTimeout <= Duration.zero) {
      throw const CompanionAuxiliaryFailure(code: 'invalid-request', terminal: 'preflight_error', notSent: true);
    }
    final body = <String, Object?>{
      'v': 1,
      'instanceId': host.instanceId,
      'requestId': requestId,
      'kind': 'screen',
      'provider': host.selection.provider,
      'model': host.selection.model,
      if (host.selection.reasoningEffort != null) 'reasoningEffort': host.selection.reasoningEffort,
      'system': system,
      'input': input,
      'image': image.toJson(),
      'maxTokens': maxTokens,
    };
    return _postAuxiliary(
      transport,
      body: utf8.encode(jsonEncode(body)),
      instanceId: host.instanceId,
      provider: host.selection.provider,
      model: host.selection.model,
      requestId: requestId,
      abort: abort,
      onDispatchUncertain: onDispatchUncertain,
      onSent: onSent,
      onUsage: onUsage,
      headerTimeout: headerTimeout,
      idleTimeout: idleTimeout,
      maxRequestBytes: 2 * 1024 * 1024,
      path: '$_path/screen',
    );
  }
}

Future<CompanionAuxiliaryResult> _postAuxiliary(
  DshHttpCarrier transport, {
  required Uint8List body,
  required String instanceId,
  required String provider,
  required String model,
  required String requestId,
  required DshHttpAbort abort,
  required void Function() onDispatchUncertain,
  required void Function() onSent,
  required void Function(Map<String, Object?> usage) onUsage,
  required Duration headerTimeout,
  required Duration idleTimeout,
  required int maxRequestBytes,
  required String path,
  _Receipt? observation,
}) async {
  if (body.length > maxRequestBytes) {
    throw const CompanionAuxiliaryFailure(code: 'request-limit', terminal: 'preflight_error', notSent: true);
  }
  if (abort.isAborted) {
    throw const CompanionAuxiliaryFailure(code: 'cancelled', terminal: 'cancelled', notSent: true);
  }
  // The durable phone write must complete before this exact HTTP handoff.
  // Callback exceptions propagate; they must prevent the POST.
  onDispatchUncertain();
  final receipt = observation ?? _Receipt(instanceId, provider, model, requestId, onSent);
  DshHttpStreamResponse? response;
  var terminal = 'incomplete';
  try {
    response = await transport.connection.postJsonStream(
      path,
      DshEncodedJson(body),
      abort: abort,
      headerTimeout: headerTimeout,
      idleTimeout: idleTimeout,
    );
    if (response.statusCode != 200) {
      final bytes = await _boundedBytes(response.body, 16384);
      if (response.contentType == 'application/json') {
        final map = _map(jsonDecode(utf8.decode(bytes)));
        final error = _map(map?['error']);
        final code = error?['code'];
        // These refer to an earlier request/generation. Even a malformed
        // response claiming false may not release that earlier reservation.
        final uncertainId = const {
          'companion/auxiliary-instance-changed',
          'companion/auxiliary-request-used',
          'companion/auxiliary-request-conflict',
          'companion/auxiliary-request-unknown',
        }.contains(code);
        final notSent =
            response.statusCode >= 400 &&
            code is String &&
            (code.startsWith('companion/auxiliary-') ||
                (response.statusCode == 413 && code == 'companion/too-large')) &&
            map?['dispatched'] == false &&
            !uncertainId;
        throw CompanionAuxiliaryFailure(
          code: code is String ? code : 'http-error',
          terminal: notSent ? 'preflight_error' : 'http_error',
          notSent: notSent,
          httpStatus: response.statusCode,
        );
      }
      throw CompanionAuxiliaryFailure(
        code: 'http-error',
        terminal: 'http_error',
        notSent: false,
        httpStatus: response.statusCode,
      );
    }
    if (response.contentType != 'application/x-ndjson') _protocol();
    await for (final line in _lines(response.body)) {
      final frame = _map(jsonDecode(line));
      if (frame == null) _protocol();
      final result = receipt.add(frame);
      if (result != null) return result;
    }
    throw CompanionAuxiliaryFailure(
      code: abort.isAborted ? 'cancelled' : 'missing-finish',
      terminal: abort.isAborted ? 'cancelled' : 'incomplete',
      notSent: false,
    );
  } on CompanionAuxiliaryFailure catch (error) {
    terminal = error.terminal;
    rethrow;
  } on DshClosedException {
    terminal = 'cancelled';
    throw const CompanionAuxiliaryFailure(code: 'cancelled', terminal: 'cancelled', notSent: false);
  } on DshException {
    terminal = 'network_error';
    throw const CompanionAuxiliaryFailure(code: 'transport-error', terminal: 'network_error', notSent: false);
  } on FormatException {
    terminal = 'incomplete';
    throw const CompanionAuxiliaryFailure(code: 'invalid-response', terminal: 'incomplete', notSent: false);
  } finally {
    try {
      await response?.cancel();
    } finally {
      onUsage(receipt.usage(terminal));
    }
  }
}

class _Receipt {
  _Receipt(this.instanceId, this.provider, this.model, this.requestId, this.onSent);

  final String instanceId;
  final String provider;
  final String model;
  final String requestId;
  final void Function() onSent;
  final _textOutput = StringBuffer();
  final _normalizedUsage = <Map<String, Object?>>[];
  Map<String, Object?>? _startUsage, _finalUsage, _finishUsage;
  var _accepted = false;
  var _outputBytes = 0;
  var _normalizedBytes = 0;
  int? _dispatchAtMs;

  CompanionAuxiliaryResult? add(Map<String, Object?> frame) {
    if (frame['requestId'] != requestId || frame['type'] is! String) _protocol();
    final type = frame['type'];
    if (type == 'accepted') {
      if (_accepted || frame['instanceId'] != instanceId || frame['provider'] != provider || frame['model'] != model) {
        _protocol();
      }
      _accepted = true;
      return null;
    }
    if (!_accepted) _protocol();
    if (type == 'dispatch') {
      if (_dispatchAtMs != null || frame['boundary'] != 'fetch-invoked' || !_count(frame['atMs'])) _protocol();
      _dispatchAtMs = frame['atMs'] as int;
      onSent();
    } else if (type == 'text') {
      final text = frame['text'];
      if (text is! String) _protocol();
      _outputBytes += utf8.encode(text).length;
      if (_outputBytes > _maxInputBytes) _protocol();
      _textOutput.write(text);
    } else if (type == 'usage') {
      final raw = _map(frame['raw']);
      if (frame['semantics'] != 'cumulative' ||
          raw == null ||
          !const {'message_start', 'message_delta'}.contains(frame['event'])) {
        _protocol();
      }
      if (frame['event'] == 'message_start') {
        _startUsage = raw;
      } else {
        _finalUsage = raw;
      }
    } else if (type == 'runtime-usage') {
      final value = _map(frame['usage']);
      if (frame['semantics'] != 'runtime-normalized' || value == null) _protocol();
      _normalizedBytes += utf8.encode(jsonEncode(value)).length;
      if (_normalizedBytes > _maxInputBytes) _protocol();
      _normalizedUsage.add(value);
    } else if (type == 'finish') {
      final dispatched = frame['dispatched'];
      final atMs = frame['dispatchAtMs'];
      final complete = frame['complete'];
      final terminal = frame['terminal'];
      final status = frame['httpStatus'];
      final value = _map(frame['usage']);
      final error = _map(frame['error']);
      if (!frame.containsKey('dispatched') ||
          (dispatched != null && dispatched is! bool) ||
          !frame.containsKey('dispatchAtMs') ||
          (atMs != null && !_count(atMs)) ||
          (dispatched == true) != (atMs != null) ||
          (_dispatchAtMs != null && (dispatched != true || atMs != _dispatchAtMs)) ||
          complete is! bool ||
          terminal is! String ||
          terminal.isEmpty ||
          !frame.containsKey('httpStatus') ||
          (status != null && !_status(status)) ||
          value == null ||
          value['provider'] != provider ||
          value['model'] != model ||
          value['terminal'] != terminal ||
          value['complete'] != complete ||
          value['http_status'] != status ||
          (frame.containsKey('error') && (error == null || error['code'] is! String))) {
        _protocol();
      }
      // Keep the complete receipt even if the owner cancels in onSent.
      _finishUsage = Map<String, Object?>.unmodifiable({...value, 'host_dispatch_at_ms': atMs});
      // A final observation may establish dispatch even if no earlier dispatch
      // callback ran; no entry into a stream is itself treated as a send.
      if (dispatched == true && _dispatchAtMs == null) {
        _dispatchAtMs = atMs as int;
        onSent();
      }
      return CompanionAuxiliaryResult._(
        text: _textOutput.toString(),
        terminal: terminal,
        complete: complete,
        dispatched: dispatched as bool?,
        hostDispatchAtMs: atMs as int?,
        httpStatus: status as int?,
        errorCode: error?['code'] as String?,
        usage: _finishUsage!,
      );
    }
    // Future non-terminal observations are ignored without altering the
    // billing proof; request identity, framing and byte limits still apply.
    return null;
  }

  Map<String, Object?> usage(String terminal) {
    final finished = _finishUsage;
    if (finished != null) return finished;
    int? finalCount(String key) => _count(_finalUsage?[key]) ? _finalUsage![key] as int : null;
    return {
      'provider': provider,
      'model': model,
      'start_usage': _startUsage,
      'final_usage': _finalUsage,
      'start_event': _startUsage == null ? null : 'message_start',
      'final_event': _finalUsage == null ? null : 'message_delta',
      'usage_semantics': _startUsage != null || _finalUsage != null ? 'cumulative' : 'unknown',
      'input_uncached': finalCount('input_tokens'),
      'input_cache_read': finalCount('cache_read_input_tokens'),
      'input_cache_write': finalCount('cache_creation_input_tokens'),
      'output_tokens': finalCount('output_tokens'),
      'stop_reason': null,
      'terminal': terminal,
      'complete': false,
      'http_status': null,
      'host_dispatch_at_ms': _dispatchAtMs,
      'proxy_finish_observed': false,
      if (_normalizedUsage.isNotEmpty) ...{
        'runtime_normalized_usage': _normalizedUsage,
        'runtime_normalized_usage_semantics': 'runtime-normalized-events',
      },
    };
  }
}

class _AgentReceipt extends _Receipt {
  _AgentReceipt(super.instanceId, super.provider, super.model, super.requestId, super.onSent, this.abort, this.onText);

  final DshHttpAbort abort;
  final void Function(String) onText;
  Map<String, Object?>? message, _pendingMessage;
  var _messageSeen = false;
  var _invalidMessage = false;

  @override
  CompanionAuxiliaryResult? add(Map<String, Object?> frame) {
    // Validate the same accepted/request/route identity and settle usage first.
    final result = super.add(frame);
    if (frame['type'] == 'text') {
      if (!abort.isAborted) onText(frame['text'] as String);
    } else if (frame['type'] == 'message') {
      if (_messageSeen) _invalidMessage = true;
      _messageSeen = true;
      _pendingMessage = _agentMessage(frame['message'], provider, model);
      if (_pendingMessage == null) _invalidMessage = true;
      // Keep reading the actual final usage even when the message is invalid.
    }
    if (result != null && result.complete && const {'complete', 'tool-calls'}.contains(result.terminal)) {
      final candidate = _pendingMessage;
      if (_invalidMessage ||
          candidate == null ||
          result.errorCode != null ||
          result.dispatched == false ||
          (result.httpStatus != null && (result.httpStatus! < 200 || result.httpStatus! >= 300))) {
        _protocol();
      }
      final content = candidate['content']! as List<Map<String, Object?>>;
      final hasCalls = content.any((block) => block['type'] == 'tool_use');
      if ((result.terminal == 'tool-calls') != hasCalls ||
          candidate['stopReason'] != (hasCalls ? 'tool_use' : 'end_turn')) {
        _protocol();
      }
      message = candidate;
    }
    return result;
  }
}

bool _agentSource(Object? value) {
  final source = _map(value);
  return source != null && source['kind'] == 'model' && _id(source['provider']) && _id(source['model']);
}

bool _agentBlocks(Object? value, String role) {
  if (value is! List) return false;
  final ids = <String>{};
  for (final raw in value) {
    final block = _map(raw);
    if (block == null) return false;
    switch (block['type']) {
      case 'text':
        if (block['text'] is! String) return false;
      case 'thinking':
        if (role != 'assistant' || block['thinking'] is! String) return false;
      case 'tool_use':
        if (role != 'assistant' ||
            !_id(block['id']) ||
            !_id(block['name']) ||
            _map(block['input']) == null ||
            !ids.add(block['id'] as String)) {
          return false;
        }
      case 'tool_result':
        final content = block['content'];
        if (role != 'user' ||
            !_id(block['tool_use_id']) ||
            (block.containsKey('is_error') && block['is_error'] is! bool) ||
            !(content is String ||
                content is List &&
                    content.every((part) => _map(part)?['type'] == 'text' && _map(part)?['text'] is String))) {
          return false;
        }
      default:
        return false;
    }
  }
  return true;
}

bool _agentMessages(List<Map<String, Object?>> messages) =>
    messages.isNotEmpty &&
    messages.every((message) {
      final role = message['role'];
      if (role is! String || !const {'user', 'assistant'}.contains(role)) return false;
      final content = message['content'];
      if (content is! String && !_agentBlocks(content, role)) return false;
      return !message.containsKey('source') || role == 'assistant' && _agentSource(message['source']);
    });

bool _agentTools(List<Map<String, Object?>> tools) {
  final names = <String>{};
  return tools.every(
    (tool) =>
        _id(tool['name']) &&
        names.add(tool['name'] as String) &&
        _map(tool['input_schema']) != null &&
        (!tool.containsKey('description') || tool['description'] is String),
  );
}

Map<String, Object?>? _agentMessage(Object? value, String provider, String model) {
  final message = _map(value);
  if (message == null ||
      !_agentSource(message['source']) ||
      !const {'end_turn', 'tool_use'}.contains(message['stopReason']) ||
      !_agentBlocks(message['content'], 'assistant') ||
      utf8.encode(jsonEncode(message)).length > _maxInputBytes) {
    return null;
  }
  final source = _map(message['source'])!;
  if (source['provider'] != provider || source['model'] != model) return null;
  return Map<String, Object?>.unmodifiable({
    'content': List<Map<String, Object?>>.unmodifiable([
      for (final block in message['content'] as List) Map<String, Object?>.unmodifiable(_map(block)!),
    ]),
    'stopReason': message['stopReason'],
    'source': Map<String, Object?>.unmodifiable(source),
  });
}

Future<Uint8List> _boundedBytes(Stream<Uint8List> body, int limit) async {
  final result = BytesBuilder(copy: false);
  await for (final chunk in body) {
    if (result.length + chunk.length > limit) _protocol();
    result.add(chunk);
  }
  return result.takeBytes();
}

Stream<String> _lines(Stream<Uint8List> body) async* {
  final pending = BytesBuilder(copy: false);
  var total = 0;
  await for (final chunk in body) {
    total += chunk.length;
    if (total > _maxStreamBytes) _protocol();
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] != 10) continue;
      if (pending.length + i - start > _maxLineBytes) _protocol();
      pending.add(chunk.sublist(start, i));
      final line = utf8.decode(pending.takeBytes());
      if (line.trim().isNotEmpty) yield line;
      start = i + 1;
    }
    if (pending.length + chunk.length - start > _maxLineBytes) _protocol();
    pending.add(chunk.sublist(start));
  }
  // A cut-off final JSON object is not a terminal NDJSON receipt.
  if (pending.isNotEmpty) _protocol();
}

Map<String, Object?>? _map(Object? value) => value is Map<String, Object?> ? value : null;
bool _count(Object? value) => value is int && value >= 0 && value <= _maxSafe;
bool _status(Object? value) => value is int && value >= 100 && value <= 599;
bool _id(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.runes.length <= 128 &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value) &&
    _unicode(value);
bool _text(String value) =>
    value.trim().isNotEmpty && !RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(value) && _unicode(value);

bool _unicode(String value) {
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= value.length) return false;
      final low = value.codeUnitAt(i);
      if (low < 0xdc00 || low > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

Never _protocol() =>
    throw const CompanionAuxiliaryFailure(code: 'invalid-response', terminal: 'incomplete', notSent: false);
