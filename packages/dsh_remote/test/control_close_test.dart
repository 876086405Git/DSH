import 'package:dsh_remote/src/protocol/close_semantics.dart';
import 'package:test/test.dart';

void main() {
  test('shutdown and heartbeat are classified by code and reason together', () {
    for (final code in [4009, 4001, 1013]) {
      final close = classifyControlClose(code, ' server shutdown ');
      expect(close.serverShutdown, isTrue);
      expect(close.heartbeatTimeout, isFalse);
      expect(close.retryable, isTrue);
    }
    for (final pair in [(4009, 'heartbeat timeout'), (4001, 'CONNECTION_FAILED')]) {
      final close = classifyControlClose(pair.$1, pair.$2);
      expect(close.heartbeatTimeout, isTrue);
      expect(close.serverShutdown, isFalse);
      expect(close.retryable, isTrue);
    }
    for (final code in [4009, 4001]) {
      expect(classifyControlClose(code, '').retryable, isFalse);
    }
  });

  test('replacement, auth and unknown application codes do not retain tunnels', () {
    expect(classifyControlClose(4003, 'CONNECTION_REPLACED').replaced, isTrue);
    for (final code in [4001, 4002, 4003, 4004, 4008, 4011, 4012, 4999]) {
      expect(classifyControlClose(code, 'AUTH_INVALID').retryable, isFalse);
    }
    for (final code in [1000, 1001, 1006, 1011, 1012, 1013]) {
      expect(classifyControlClose(code, '').retryable, isTrue);
    }
  });
}
