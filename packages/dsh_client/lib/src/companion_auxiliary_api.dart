/// One phone-owned auxiliary attempt through the current full-mode provider.
/// This uses the existing authenticated HTTP connection, never Session RPC,
/// tools, mux recovery, a provider fallback, or an automatic retry.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'carrier.dart';
import 'connection.dart';
import 'errors.dart';
import 'session_api.dart';

const _path = '/dsh-go/v1/companion/auxiliary';
const _maxInputBytes = 65536;
const _maxLineBytes = 192 * 1024;
const _maxStreamBytes = 8 * 1024 * 1024;
const _maxSafe = 9007199254740991;

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
    if (utf8.encode(jsonEncode(body)).length > _maxInputBytes) {
      throw const CompanionAuxiliaryFailure(code: 'request-limit', terminal: 'preflight_error', notSent: true);
    }
    if (abort.isAborted) {
      throw const CompanionAuxiliaryFailure(code: 'cancelled', terminal: 'cancelled', notSent: true);
    }
    // The durable phone write must complete before this exact HTTP handoff.
    // Callback exceptions propagate; they must prevent the POST.
    onDispatchUncertain();
    final receipt = _Receipt(host, requestId, onSent);
    DshHttpStreamResponse? response;
    var terminal = 'incomplete';
    try {
      response = await transport.connection.postJsonStream(
        _path,
        body,
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
              code.startsWith('companion/auxiliary-') &&
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
}

class _Receipt {
  _Receipt(this.host, this.requestId, this.onSent);

  final CompanionAuxiliaryCapability host;
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
      if (_accepted ||
          frame['instanceId'] != host.instanceId ||
          frame['provider'] != host.provider ||
          frame['model'] != host.model) {
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
          value['provider'] != host.provider ||
          value['model'] != host.model ||
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
      'provider': host.provider,
      'model': host.model,
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
