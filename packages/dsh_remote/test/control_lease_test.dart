import 'package:dsh_remote/src/protocol/control.dart';
import 'package:dsh_remote/src/transport/control_lease.dart';
import 'package:test/test.dart';

void main() {
  test('only a matching lease ack confirms and rotates a recovery ticket', () {
    final requests = <Map<String, Object?>>[];
    final lease = ControlLease('connection', 'initial', (payload) {
      requests.add(payload);
      return true;
    }, () => fail('unexpected expiry'));
    addTearDown(lease.stop);
    lease.start();
    expect(requests.single, {'connectionId': 'connection', 'requestId': '1', 'ticket': 'initial'});
    expect(lease.recoveryTicket, isNull);
    final ack = {...requests.single, 'ticket': 'confirmed', 'leaseMs': controlLeaseMs};
    expect(lease.acknowledge({...ack, 'connectionId': 'other'}), isFalse);
    expect(lease.acknowledge({...ack, 'requestId': 'other'}), isFalse);
    expect(lease.canDetach, isFalse);
    expect(lease.acknowledge(ack), isTrue);
    expect(lease.recoveryTicket, 'confirmed');
    expect(lease.acknowledge(ack), isFalse, reason: 'one ack cannot renew twice');
    lease.tick(force: true);
    expect(requests.last['ticket'], 'confirmed');
    expect(requests.last['requestId'], '2');
  });

  test('renewals are single-flight and wait for authenticated recovery Control', () {
    final requests = <Map<String, Object?>>[];
    var authenticated = true;
    final lease = ControlLease('connection', 'initial', (payload) {
      if (!authenticated) return false;
      requests.add(payload);
      return true;
    }, () => fail('unexpected expiry'));
    addTearDown(lease.stop);
    lease.start();
    final first = requests.single;
    lease.tick(force: true);
    lease.tick();
    expect(requests, hasLength(1), reason: 'no concurrent lease requests');
    expect(lease.acknowledge({...first, 'ticket': 'confirmed', 'leaseMs': controlLeaseMs}), isTrue);
    authenticated = false;
    lease.controlLost();
    lease.tick(force: true);
    expect(requests, hasLength(1), reason: 'hello.ack must arrive first');
    expect(lease.recoveryTicket, 'confirmed');
    authenticated = true;
    lease.tick(force: true);
    expect(requests, hasLength(2));
    expect(requests.last['ticket'], 'confirmed');
    expect(lease.acknowledge({...first, 'ticket': 'stale', 'leaseMs': controlLeaseMs}), isFalse);
    lease.stop();
    lease.tick(force: true);
    expect(requests, hasLength(2));
    expect(lease.isValid, isFalse);
    expect(lease.recoveryTicket, isNull);
  });
}
