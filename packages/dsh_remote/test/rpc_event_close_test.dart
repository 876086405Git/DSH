import 'dart:async';
import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';
import 'support/rpc_event_host.dart';

void main() {
  late EventHost f;
  setUp(() async {
    f = EventHost();
    await f.start();
  });
  tearDown(() async => f.close());
  for (final channelClose in [false, true]) {
    test('${channelClose ? 'channel' : 'rpc'} close inside legitimate event callback completes its stream', () async {
      final pending = f.rpc.call('held', {}).then<Object?>((v) => v, onError: (Object e) => e);
      await f.request.future;
      final closed = Completer<Object?>();
      f.rpc.events.listen((event) {
        final future = channelClose ? f.channel.close() : f.rpc.close();
        future.then((_) => closed.complete(null), onError: (Object e) => closed.complete(e));
      });
      f.sendBytes(RemoteMessage('event', {'event': 'stop', 'data': null}).encode());
      final closeError = await closed.future;
      final outcome = await pending;
      expect((await f.rpc.done).code, 'CLIENT_CLOSED');
      expect(outcome, isA<RemoteRpcException>().having((e) => e.code, 'code', 'CLIENT_CLOSED'));
      print({'closeError': closeError?.runtimeType.toString(), 'streamDone': f.streamDone.isCompleted});
      expect(closeError, isNull);
      expect(f.streamDone.isCompleted, isTrue);
      expect(f.events, ['stop']);
      expect(f.observations, hasLength(1));
      await f.rpc.close();
      expect(f.observations, hasLength(1));
    });
  }
  test('two receivers finish the current broadcast before one done each', () async {
    final order = <String>[];
    final closed = Completer<Object?>();
    final secondDone = Completer<void>();
    f.rpc.events.listen((event) {
      order.add('first:event');
      f.rpc.close().then((_) => closed.complete(null), onError: (Object e) => closed.complete(e));
      order.add('first:return');
    }, onDone: () => order.add('first:done'));
    f.rpc.events.listen(
      (event) => order.add('second:event'),
      onDone: () {
        order.add('second:done');
        secondDone.complete();
      },
    );
    f.sendBytes(RemoteMessage('event', {'event': 'stop', 'data': 0}).encode());
    expect(await closed.future, isNull);
    expect(secondDone.isCompleted, isTrue);
    expect(order, ['first:event', 'first:return', 'second:event', 'first:done', 'second:done']);
  });
  test('ordinary explicit close keeps synchronous stream completion', () async {
    final reclosed = Completer<Object?>();
    f.rpc.events.listen(
      (_) {},
      onDone: () {
        f.rpc.close().then((_) => reclosed.complete(null), onError: (Object e) => reclosed.complete(e));
      },
    );
    final closed = f.rpc.close();
    expect(f.streamDone.isCompleted, isTrue);
    expect(f.observations, [(rpcClosed: true, channelClosed: true, code: 'CLIENT_CLOSED')]);
    await closed;
    expect(await reclosed.future, isNull);
    await f.rpc.close();
    expect(f.observations, hasLength(1));
  });
  test('normal event ordering remains synchronous and channel usable', () async {
    final observed = Completer<void>();
    f.rpc.events.listen((event) {
      if (event.event == 'second') observed.complete();
    });
    f.sendBytes(RemoteMessage('event', {'event': 'first', 'data': 1}).encode());
    f.sendBytes(RemoteMessage('event', {'event': 'second', 'data': 2}).encode());
    await observed.future;
    expect(f.events, ['first', 'second']);
    expect(f.rpc.isClosed, isFalse);
    await f.rpc.close();
    expect(f.observations, hasLength(1));
  });
  test('listener can cancel itself and request close twice', () async {
    final closes = Completer<List<Object?>>();
    late StreamSubscription<RemoteEvent> subscription;
    subscription = f.rpc.events.listen((event) {
      unawaited(subscription.cancel());
      final one = f.rpc.close().then<Object?>((_) => null, onError: (Object e) => e);
      final two = f.rpc.close().then<Object?>((_) => null, onError: (Object e) => e);
      Future.wait([one, two]).then(closes.complete);
    });
    f.sendBytes(RemoteMessage('event', {'event': 'stop', 'data': null}).encode());
    expect(await closes.future, [null, null]);
    expect(f.streamDone.isCompleted, isTrue);
    expect(f.observations, hasLength(1));
  });
  test('listener error does not prevent deferred stream completion', () async {
    final closed = Completer<Object?>();
    final intentional = StateError('listener failure');
    final errors = <Object>[];
    runZonedGuarded(() {
      f.rpc.events.listen((event) {
        f.rpc.close().then((_) => closed.complete(null), onError: (Object e) => closed.complete(e));
        throw intentional;
      });
    }, (error, stack) => errors.add(error));
    f.sendBytes(RemoteMessage('event', {'event': 'stop', 'data': null}).encode());
    expect(await closed.future, isNull);
    expect(errors, [same(intentional)]);
    expect(f.streamDone.isCompleted, isTrue);
    expect(f.observations, hasLength(1));
  });
}
