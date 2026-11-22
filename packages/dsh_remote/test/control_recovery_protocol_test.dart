// Additional boundaries from the current ds-harness-remote Control parser.
// Existing protocol-v1 fixtures remain unchanged.
import 'dart:convert';

import 'package:dsh_remote/src/protocol/control.dart';
import 'package:dsh_remote/src/protocol/messages.dart';
import 'package:dsh_remote/src/util/bytes.dart';
import 'package:test/test.dart';

const Map<String, Map<String, Object?>> _payloads = {
  'hello': {
    'role': 'client',
    'deviceId': 'client-1',
    'accessToken': 'synthetic-token',
    'protocols': [1],
    'capabilities': ['transport.relay', webRtcResumeCapability, relayResumeCapability],
    'clientVersion': '',
    'harnessVersion': '',
    'recoveryTickets': ['synthetic-ticket'],
  },
  'hello.ack': {
    'protocol': 1,
    'serverVersion': '1.0.0',
    'connectionSessionId': 'session-1',
    'heartbeatIntervalMs': 25000,
    'maxControlFrameBytes': maxControlFrameBytes,
    'maxRelayFrameBytes': maxRelayFrameBytes,
  },
  'connect.request': {
    'hostDeviceId': 'host-1',
    'preferredTransports': ['relay'],
  },
  'connect.incoming': {
    'connectionId': 'connection-1',
    'clientDeviceId': 'client-1',
    'clientIdentityKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'authorization': 'account',
    'preferredTransports': ['relay'],
    'recoveryTicket': 'synthetic-ticket',
    'relayRecoveryTicket': 'synthetic-relay-ticket',
    'relayEndpoint': 'wss://relay.example/ws',
    'relayTicket': 'synthetic-attach-ticket',
    'relayNodeId': 'relay-1',
    'relayEpoch': 0,
  },
  'connect.accepted': {
    'connectionId': 'connection-1',
    'recoveryTicket': 'synthetic-ticket',
    'relayRecoveryTicket': 'synthetic-relay-ticket',
    'webrtcFallbackTimeoutMs': 2147483647,
    'parallelConnections': true,
  },
  'connect.rejected': {'connectionId': 'connection-1', 'code': '', 'message': ''},
  'secure.handshake': {'connectionId': 'connection-1', 'targetDeviceId': 'host-1', 'step': 1, 'data': 'AQ'},
  'relay': {'connectionId': 'connection-1', 'targetDeviceId': 'host-1', 'counter': 0, 'ciphertext': 'AQ'},
  'signal.offer': {'connectionId': 'connection-1', 'targetDeviceId': 'host-1', 'sdp': 'v=0'},
  'signal.answer': {'connectionId': 'connection-1', 'targetDeviceId': 'host-1', 'sdp': 'v=0'},
  'signal.ice': {
    'connectionId': 'connection-1',
    'targetDeviceId': 'host-1',
    'candidate': {'candidate': '', 'sdpMid': null, 'sdpMLineIndex': 0, 'usernameFragment': null},
  },
  'transport.selected': {
    'connectionId': 'connection-1',
    'targetDeviceId': 'host-1',
    'transport': 'turn',
    'turnNode': 'turn.example',
  },
  'connection.lease.request': {'connectionId': 'connection-1', 'requestId': 'request-1', 'ticket': 'synthetic-ticket'},
  'connection.lease.ack': {
    'connectionId': 'connection-1',
    'requestId': 'request-1',
    'ticket': 'synthetic-ticket',
    'leaseMs': controlLeaseMs,
  },
  'connection.lease.close': {'connectionId': 'connection-1'},
  'ping': {'nonce': 'nonce-1'},
  'pong': {'nonce': 'nonce-1'},
  'error': {'code': 'ERROR', 'message': 'Synthetic error', 'retryable': false, 'connectionId': 'connection-1'},
};

Map<String, Object?> _frame(String type, Map<String, Object?> payload, {Object? timestamp = 1}) => {
  'v': 1,
  'id': 'frame-1',
  'type': type,
  'timestamp': timestamp,
  'payload': payload,
};

ControlFrame _parse(String type, [Map<String, Object?> changes = const {}]) =>
    parseControlFrame(_frame(type, {..._payloads[type]!, ...changes}));

Matcher _protocolError([String code = 'INVALID_MESSAGE']) =>
    throwsA(isA<ProtocolError>().having((e) => e.code, 'code', code));

void main() {
  for (final entry in _payloads.entries) {
    test('${entry.key} parses and encodes only its known payload fields', () {
      final input = {
        ...entry.value,
        'futureField': {'value': true},
      };
      final parsed = parseControlFrame(_frame(entry.key, input));
      expect(parsed.payload, entry.value);
      expect(input, contains('futureField'));
      expect(decodeControlFrame(encodeControlFrame(ControlFrame(entry.key, input))).payload, entry.value);
    });
  }

  test('lease frames enforce bounded required strings and exact duration', () {
    for (final type in ['connection.lease.request', 'connection.lease.ack', 'connection.lease.close']) {
      final fields = {
        'connectionId': 128,
        if (type != 'connection.lease.close') 'requestId': 128,
        if (type != 'connection.lease.close') 'ticket': 4096,
      };
      for (final entry in fields.entries) {
        expect(_parse(type, {entry.key: 'x' * entry.value}).payload[entry.key], 'x' * entry.value);
        for (final invalid in [null, 1, '', 'x' * (entry.value + 1)]) {
          expect(() => _parse(type, {entry.key: invalid}), _protocolError(), reason: '$type ${entry.key}');
        }
        final missing = {..._payloads[type]!}..remove(entry.key);
        expect(() => parseControlFrame(_frame(type, missing)), _protocolError());
      }
    }
    for (final invalid in [null, '300000', 0, controlLeaseMs - 1, controlLeaseMs + 1]) {
      expect(() => _parse('connection.lease.ack', {'leaseMs': invalid}), _protocolError());
    }
    final missing = {..._payloads['connection.lease.ack']!}..remove('leaseMs');
    expect(() => parseControlFrame(_frame('connection.lease.ack', missing)), _protocolError());
    expect(_parse('connection.lease.close', {'ticket': 42}).payload, _payloads['connection.lease.close']);
  });

  test('hello recovery tickets are optional, bounded, and not deduplicated', () {
    final hello = {..._payloads['hello']!}..remove('recoveryTickets');
    expect(parseControlFrame(_frame('hello', hello)).payload, hello);
    expect(_parse('hello', {'recoveryTickets': <String>[]}).payload['recoveryTickets'], isEmpty);
    final maximum = List.filled(64, 't' * 4096);
    expect(_parse('hello', {'recoveryTickets': maximum}).payload['recoveryTickets'], maximum);
    for (final invalid in [
      null,
      'ticket',
      [null],
      [1],
      [''],
      ['t' * 4097],
      List.filled(65, 'ticket'),
    ]) {
      expect(() => _parse('hello', {'recoveryTickets': invalid}), _protocolError());
    }
  });

  test('connect recovery tickets are optional and individually bounded', () {
    for (final type in ['connect.incoming', 'connect.accepted']) {
      final payload = {..._payloads[type]!}
        ..remove('recoveryTicket')
        ..remove('relayRecoveryTicket');
      expect(parseControlFrame(_frame(type, payload)).payload, payload);
      for (final key in ['recoveryTicket', 'relayRecoveryTicket']) {
        expect(_parse(type, {key: 't' * 4096}).payload[key], 't' * 4096);
        for (final invalid in [null, 1, '', 't' * 4097]) {
          expect(() => _parse(type, {key: invalid}), _protocolError(), reason: '$type $key');
        }
      }
    }
  });

  test('hello.ack keeps optional WebRTC fields and its safe timeout bound', () {
    expect(_parse('hello.ack').payload, _payloads['hello.ack']);
    for (final enabled in [true, false]) {
      final changes = {'webrtcEnabled': enabled, 'webrtcFallbackTimeoutMs': maxSafeInteger};
      expect(_parse('hello.ack', changes).payload, containsPair('webrtcEnabled', enabled));
      expect(_parse('hello.ack', changes).payload['webrtcFallbackTimeoutMs'], maxSafeInteger);
    }
    for (final invalid in [null, 0, 'true']) {
      expect(() => _parse('hello.ack', {'webrtcEnabled': invalid}), _protocolError());
    }
    for (final invalid in [null, '1', 0, -1, 1.5, maxSafeInteger + 1]) {
      expect(() => _parse('hello.ack', {'webrtcFallbackTimeoutMs': invalid}), _protocolError());
    }
  });

  test('connect.accepted timeout is a positive int32 and parallelConnections is optional boolean', () {
    final payload = {..._payloads['connect.accepted']!}
      ..remove('webrtcFallbackTimeoutMs')
      ..remove('parallelConnections');
    expect(parseControlFrame(_frame('connect.accepted', payload)).payload, payload);
    expect(
      _parse('connect.accepted', {
        'webrtcFallbackTimeoutMs': 1,
        'parallelConnections': false,
      }).payload['parallelConnections'],
      false,
    );
    for (final invalid in [null, '1', 0, -1, 1.5, 2147483648]) {
      expect(() => _parse('connect.accepted', {'webrtcFallbackTimeoutMs': invalid}), _protocolError());
    }
    for (final invalid in [null, 1, 'true']) {
      expect(() => _parse('connect.accepted', {'parallelConnections': invalid}), _protocolError());
    }
  });

  test('capability negotiation never infers recovery support', () {
    const offered = ['transport.relay', webRtcResumeCapability, relayResumeCapability];
    expect(acceptNegotiatedCapabilities(offered, null), ['transport.relay']);
    expect(acceptNegotiatedCapabilities(offered, []), isEmpty);
    expect(acceptNegotiatedCapabilities(offered, [relayResumeCapability]), [relayResumeCapability]);
    expect(() => acceptNegotiatedCapabilities([webRtcResumeCapability], null), _protocolError());
    expect(() => acceptNegotiatedCapabilities(['transport.relay'], [webRtcResumeCapability]), _protocolError());
    expect(
      () => acceptNegotiatedCapabilities(offered, [relayResumeCapability, relayResumeCapability]),
      _protocolError(),
    );
  });

  test('ICE candidates normalize native indices, strip additions, and do not mutate input', () {
    for (final index in [
      null,
      -1,
      1.167066568144e-312,
      1.5,
      '0',
      true,
      <String, Object?>{},
      double.nan,
      double.infinity,
    ]) {
      final candidate = {
        'candidate': '',
        'sdpMid': null,
        'sdpMLineIndex': index,
        'usernameFragment': null,
        'futureField': true,
      };
      final parsed = _parse('signal.ice', {'candidate': candidate});
      expect(parsed.payload['candidate'], {
        'candidate': '',
        'sdpMid': null,
        'sdpMLineIndex': null,
        'usernameFragment': null,
      });
      expect(candidate, contains('futureField'));
      expect(candidate['sdpMLineIndex'], same(index));
    }
    for (final index in [0, 1.0, maxSafeInteger]) {
      final parsed = _parse('signal.ice', {
        'candidate': {'sdpMLineIndex': index},
      });
      final candidate = parsed.payload['candidate']! as Map<String, Object?>;
      expect(candidate['sdpMLineIndex'], index);
    }
    expect(_parse('signal.ice', {'candidate': <String, Object?>{}}).payload['candidate'], isEmpty);
    expect(
      () => _parse('signal.ice', {
        'candidate': {'sdpMLineIndex': maxSafeInteger + 1},
      }),
      _protocolError(),
    );
  });

  test('ICE candidate fields retain their declared nullable types', () {
    for (final invalid in [null, '', [], 1]) {
      expect(() => _parse('signal.ice', {'candidate': invalid}), _protocolError());
    }
    for (final key in ['candidate', 'sdpMid', 'usernameFragment']) {
      for (final invalid in [1, false, <String, Object?>{}]) {
        expect(
          () => _parse('signal.ice', {
            'candidate': {key: invalid},
          }),
          _protocolError(),
          reason: key,
        );
      }
    }
    expect(
      () => _parse('signal.ice', {
        'candidate': {'candidate': null},
      }),
      _protocolError(),
    );
    final candidate = {'candidate': 'candidate:1', 'sdpMid': '0', 'usernameFragment': 'u'};
    expect(_parse('signal.ice', {'candidate': candidate}).payload['candidate'], candidate);
  });

  test('transport.selected bounds optional turnNode to 1..253 characters', () {
    final payload = {..._payloads['transport.selected']!}..remove('turnNode');
    expect(parseControlFrame(_frame('transport.selected', payload)).payload, payload);
    expect(_parse('transport.selected', {'turnNode': 'n' * 253}).payload['turnNode'], 'n' * 253);
    for (final invalid in [null, 1, '', 'n' * 254]) {
      expect(() => _parse('transport.selected', {'turnNode': invalid}), _protocolError());
    }
  });

  test('Control, Relay data and Remote timestamps must be positive safe integers', () {
    for (final timestamp in [1, 1.0, maxSafeInteger]) {
      final frame = _frame('ping', _payloads['ping']!, timestamp: timestamp);
      expect(parseControlFrame(frame).timestamp, timestamp);
      expect(decodeRelayDataFrame(jsonEncode(frame)).timestamp, timestamp);
      expect(RemoteMessage.decode(utf8.encode(jsonEncode({...frame, 'type': 'rpc.response'}))).timestamp, timestamp);
    }
    for (final timestamp in [null, 0, -1, 1.5, '1', maxSafeInteger + 1]) {
      final frame = _frame('ping', _payloads['ping']!, timestamp: timestamp);
      expect(() => parseControlFrame(frame), _protocolError());
      expect(() => decodeRelayDataFrame(jsonEncode(frame)), _protocolError());
      expect(() => RemoteMessage.decode(utf8.encode(jsonEncode({...frame, 'type': 'rpc.response'}))), _protocolError());
    }
  });

  test('Relay data applies known payload schemas without closing its type namespace', () {
    for (final type in ['relay', 'secure.handshake']) {
      final payload = {..._payloads[type]!, 'futureField': true};
      expect(decodeRelayDataFrame(encodeRelayDataFrame(ControlFrame(type, payload))).payload, _payloads[type]);
      expect(() => encodeRelayDataFrame(ControlFrame(type, {'connectionId': 'connection-1'})), _protocolError());
    }
    final relay = _frame('relay', {..._payloads['relay']!, 'counter': -1});
    expect(() => decodeRelayDataFrame(jsonEncode(relay)), _protocolError());
    relay['payload'] = {..._payloads['relay']!, 'ciphertext': 'AR'};
    expect(() => decodeRelayDataFrame(jsonEncode(relay)), _protocolError());
    expect(decodeRelayDataFrame(encodeRelayDataFrame(ControlFrame('relay.ready', {'epoch': 1}))).payload, {'epoch': 1});
  });

  test('Relay assignment URL requires a host for special schemes, not for opaque schemes', () {
    for (final type in ['connect.incoming', 'connect.accepted']) {
      for (final endpoint in ['wss://relay.example/ws', 'https:relay.example/ws', 'custom:relay']) {
        expect(_parse(type, {'relayEndpoint': endpoint}).payload['relayEndpoint'], endpoint);
      }
      for (final endpoint in ['ws://', 'http:', 'https://?query', 'ftp://#fragment', '/relative']) {
        expect(() => _parse(type, {'relayEndpoint': endpoint}), _protocolError());
      }
    }
  });

  test('relayEpoch is a nonnegative safe integer and integer-valued JSON numbers remain valid', () {
    for (final type in ['connect.incoming', 'connect.accepted']) {
      expect(_parse(type, {'relayEpoch': maxSafeInteger}).payload['relayEpoch'], maxSafeInteger);
      for (final invalid in [null, -1, 1.5, maxSafeInteger + 1]) {
        expect(() => _parse(type, {'relayEpoch': invalid}), _protocolError());
      }
    }
    expect(
      _parse('hello', {
        'protocols': [1.0],
      }).payload['protocols'],
      [1],
    );
    expect(_parse('hello.ack', {'heartbeatIntervalMs': 1.0}).payload['heartbeatIntervalMs'], 1);
    expect(_parse('relay', {'counter': 1.0}).payload['counter'], 1);
    expect(_parse('secure.handshake', {'step': 2.0}).payload['step'], isA<int>());
    expect(_parse('connection.lease.ack', {'leaseMs': 300000.0}).payload['leaseMs'], isA<int>());
  });

  test('rpc.error retryable is optional boolean, not nullable', () {
    const payload = {'requestId': 'request-1', 'code': 'ERROR', 'message': 'Synthetic error'};
    expect(RpcErrorPayload.parse(payload).retryable, isNull);
    expect(RpcErrorPayload.parse({...payload, 'retryable': false}).retryable, false);
    expect(() => RpcErrorPayload.parse({...payload, 'retryable': null}), _protocolError());
  });

  test('existing error classifications and raw-frame byte limits remain stable', () {
    final frame = _frame('ping', _payloads['ping']!);
    expect(() => parseControlFrame({...frame, 'v': 2}), _protocolError('UNSUPPORTED_VERSION'));
    expect(() => _parse('hello.ack', {'protocol': 2}), _protocolError('UNSUPPORTED_VERSION'));
    expect(() => parseControlFrame({...frame, 'futureField': true}), _protocolError());
    expect(() => decodeControlFrame('{'), _protocolError());
    expect(
      () => encodeControlFrame(ControlFrame('ping', {'nonce': 'n' * maxControlFrameBytes})),
      _protocolError('FRAME_TOO_LARGE'),
    );
    final added = _frame('ping', {..._payloads['ping']!, 'futureField': 'x' * maxControlFrameBytes});
    expect(() => decodeControlFrame(jsonEncode(added)), _protocolError('FRAME_TOO_LARGE'));
    expect(
      decodeControlFrame(encodeControlFrame(ControlFrame('ping', added['payload']! as Map<String, Object?>))).payload,
      _payloads['ping'],
    );
  });
}
