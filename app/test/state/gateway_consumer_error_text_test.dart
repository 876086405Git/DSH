import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_app/state/subscriptions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const serviceReason = '所需的引擎服务未就绪，请查看引擎日志或导出诊断包';
  const operationReason = '引擎当前无法执行此操作，请查看引擎日志';
  const privateMessage = 'answered 403; could not reach; fetch failed; aborted; private-sentinel';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLocale.use(AppLocale.zhCN);
  });
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  for (final (code, reason) in const [
    ('gateway/service-unavailable', serviceReason),
    ('gateway/context-unavailable', serviceReason),
    ('gateway/lookup-unavailable', serviceReason),
    ('gateway/definition-unavailable', operationReason),
    ('gateway/invocation-unavailable', operationReason),
    ('gateway/method-unavailable', operationReason),
    ('gateway/cancelled', '已取消'),
    ('gateway/peer-disposed', '没能连上引擎'),
  ]) {
    test('$code keeps its meaning ahead of endpoint message guesses', () {
      final error = DshRemoteException(code, privateMessage, {'token': 'synthetic-private-token'});
      for (final text in [describeProviderError(error), describeLoginError(error)]) {
        expect(text, reason);
        expect(text, isNot(contains('private-sentinel')));
        expect(text, isNot(contains('synthetic-private-token')));
      }
    });
  }

  for (final code in const ['gateway/method-not-found', 'gateway/not-found']) {
    test('$code preserves each consumer legacy unsupported wording', () {
      final error = DshRemoteException(code, privateMessage);
      expect(describeProviderError(error), appL10n.stateProviderUnsupported);
      expect(describeLoginError(error), appL10n.stateSubscriptionUnsupported);
    });
  }

  for (final code in const [
    'gateway/arguments-invalid',
    'gateway/input-invalid',
    'gateway/lookup-not-found',
    'gateway/context-not-found',
    'gateway/interactions-forbidden',
    'gateway/protocol',
    'gateway/future-code',
    'gateway/internal',
  ]) {
    test('$code without a recognized business reason stays neutral', () {
      final error = DshRemoteException(code, 'synthetic-private-message');
      expect(describeProviderError(error), appL10n.commonFailedTryAgain);
      expect(describeLoginError(error), appL10n.stateSubscriptionSignInFailed);
    });
  }

  test('provider conflict and credential precedence do not change login semantics', () {
    const conflict = DshRemoteException('settings/conflict', 'synthetic-private-message');
    const credential = DshRemoteException('credential/rejected', 'synthetic-private-message');
    expect(describeProviderError(conflict), appL10n.stateProviderConflict);
    expect(describeProviderError(credential), appL10n.stateCredentialFromEnvironment);
    expect(describeLoginError(conflict), appL10n.stateSubscriptionSignInFailed);
    expect(describeLoginError(credential), appL10n.stateSubscriptionSignInFailed);
  });

  test('internal gateway errors retain endpoint-specific guidance', () {
    expect(
      describeProviderError(const DshRemoteException('gateway/internal', 'endpoint answered 403')),
      appL10n.stateProviderKeyRejected,
    );
    expect(
      describeProviderError(const DshRemoteException('gateway/internal', 'could not reach endpoint')),
      appL10n.stateProviderUnreachable,
    );
    expect(
      describeLoginError(const DshRemoteException('gateway/internal', 'fetch failed')),
      appL10n.stateSubscriptionUnreachable,
    );
    expect(describeProviderError(const DshRemoteException('gateway/internal', 'aborted')), appL10n.commonCancelled);
  });

  test('unrelated remote errors are not reclassified by the shared helper', () {
    const missing = DshRemoteException('session/not-found', 'synthetic-private-message');
    expect(describeProviderError(missing), appL10n.commonFailedTryAgain);
    expect(describeLoginError(missing), appL10n.stateSubscriptionSignInFailed);
    expect(describeProviderError(const ProviderFailure('already worded')), 'already worded');
  });

  test('HTTP authentication and transport failures keep their existing consumer copy', () {
    const refused = DshHttpException(403, 'synthetic-private-message');
    expect(describeProviderError(refused), appL10n.stateEngineHttpRejected(403));
    expect(describeLoginError(refused), appL10n.stateEngineHttpRejected(403));
    expect(describeProviderError(const DshTransportException('private')), appL10n.commonEngineUnreachable);
    expect(describeLoginError(const DshTransportException('private')), appL10n.stateSubscriptionTimeout);
    expect(describeLoginError(TimeoutException('private')), appL10n.stateSubscriptionTimeout);
    expect(describeLoginError(const DshClosedException('private')), appL10n.stateSubscriptionDisconnected);
  });

  test('LoginSession exposes the unavailable bridge reason without starting a poll', () async {
    final backend = _FailingBeginBackend(const DshRemoteException('gateway/service-unavailable', privateMessage));
    final session = LoginSession(backend, Subscription.chatgpt);
    addTearDown(session.dispose);
    await session.start();
    expect(session.step.phase, LoginPhase.failed);
    expect(session.step.error, serviceReason);
    expect(backend.begins, 1);
    expect(backend.polls, 0);
    expect(backend.cancels, 0);
  });

  test('both consumers follow the current English locale', () {
    AppLocale.use(AppLocale.en);
    const service = DshRemoteException('gateway/service-unavailable', privateMessage);
    const operation = DshRemoteException('gateway/invocation-unavailable', privateMessage);
    for (final describe in [describeProviderError, describeLoginError]) {
      expect(
        describe(service),
        'The required engine service is not ready. Check the engine logs or export diagnostics.',
      );
      expect(describe(operation), 'The engine cannot run this operation right now. Check the engine logs.');
    }
  });
}

class _FailingBeginBackend implements SubscriptionBackend {
  _FailingBeginBackend(this.error);

  final Object error;
  int begins = 0;
  int polls = 0;
  int cancels = 0;

  @override
  Future<String> begin(Subscription subscription, {bool newAccount = false}) async {
    begins++;
    throw error;
  }

  @override
  Future<LoginStep> poll(String attemptId) async {
    polls++;
    throw StateError('A refused begin cannot be polled');
  }

  @override
  Future<void> cancel(String attemptId) async {
    cancels++;
  }

  @override
  Future<List<SubscriptionStatus>> list() async => throw StateError('Unexpected list');

  @override
  Future<void> answer(String attemptId, String value) async => throw StateError('Unexpected answer');

  @override
  Future<void> signOut(Subscription subscription) async => throw StateError('Unexpected signOut');
}
