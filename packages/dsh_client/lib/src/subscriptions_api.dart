/// Subscription sign-in through dsh-app's engine-side auth bridge
/// (`@dsh-app/auth`, service `appAuth`).
///
/// DSH 0.2.1 already carries both sign-in flows: the built-in `llm-pi-ai`
/// adapter registers one authorization flow per pi-ai provider that has a
/// login (`llm-pi-ai/openai-codex`, `llm-pi-ai/anthropic`) and stores the
/// grant in the local credential store. It does not expose "begin a sign-in"
/// to clients, so the bridge does that and turns the flow's interaction into
/// a small polled state machine:
///
/// ```
/// beginLogin → attemptId
/// pollLogin(attemptId) → starting → open | device | prompt → done | failed
///                                    (answerLogin for prompt)  cancelled
/// ```
///
/// Polling (not a stream) so it works the same over every carrier. Once an
/// attempt is `done`, its route can serve models in the catalog.
/// The legacy logins use `llm-pi-ai`; official ChatGPT has its own route.
/// [DshSubscriptions.signOut] revokes access on the host.
library;

import 'json.dart';
import 'session_api.dart';

/// A subscription the bridge can sign in to.
enum Subscription {
  chatgpt('openai-codex'),
  claude('anthropic'),
  chatgptOfficial('openai-siwc');

  const Subscription(this.wire);

  /// The provider id used by both appAuth and the model catalog.
  final String wire;

  static Subscription? fromWire(String? wire) {
    for (final s in values) {
      if (s.wire == wire) return s;
    }
    return null;
  }
}

/// Sign-in state of one subscription.
class SubscriptionStatus {
  const SubscriptionStatus({
    required this.subscription,
    required this.signedIn,
    this.account,
    this.planEnabled,
    this.reconnectAvailable = false,
    this.signOutPending = false,
  });

  factory SubscriptionStatus.fromJson(Subscription subscription, Map<String, Object?> json) => SubscriptionStatus(
    subscription: subscription,
    signedIn: json['signedIn'] == true,
    account: asString(json['account']),
    planEnabled: switch (json['planEnabled']) {
      final bool value => value,
      _ => null,
    },
    reconnectAvailable: json['reconnectAvailable'] == true,
    signOutPending: json['signOutPending'] == true,
  );

  final Subscription subscription;
  final bool signedIn;

  /// Who is signed in (an email or plan name), when the grant says.
  final String? account;

  /// Whether the official ChatGPT grant permits subscription inference.
  /// Omitted for older bridges and legacy subscriptions.
  final bool? planEnabled;

  /// The host has a saved registration for the signed-out official account.
  final bool reconnectAvailable;

  /// Sign-out cleanup failed; the host blocks login until cleanup is retried.
  final bool signOutPending;
}

/// A provider-reported usage window. Percent is used, not remaining.
class SubscriptionUsageWindow {
  const SubscriptionUsageWindow({required this.id, required this.usedPercent, this.resetAt, this.windowSeconds});
  final String id;
  final double usedPercent;
  final DateTime? resetAt;
  final int? windowSeconds;
}

enum SubscriptionUsageStatus { ok, unsupported, notSignedIn, unavailable }

class SubscriptionUsage {
  const SubscriptionUsage({required this.status, this.windows = const [], this.plan, this.reason});

  factory SubscriptionUsage.fromJson(Subscription provider, Object? value) {
    final json = asMap(value);
    if (json == null || json['provider'] != provider.wire) {
      throw const FormatException('appAuth/usage: invalid provider');
    }
    final status = switch (json['status']) {
      'ok' => SubscriptionUsageStatus.ok,
      'unsupported' => SubscriptionUsageStatus.unsupported,
      'not_signed_in' => SubscriptionUsageStatus.notSignedIn,
      'unavailable' => SubscriptionUsageStatus.unavailable,
      _ => throw const FormatException('appAuth/usage: invalid status'),
    };
    final windows = <SubscriptionUsageWindow>[];
    if (status == SubscriptionUsageStatus.ok) {
      final entries = json['windows'];
      if (entries is! List || entries.isEmpty) throw const FormatException('appAuth/usage: no windows');
      for (final entry in entries) {
        final map = asMap(entry);
        final id = asString(map?['id']);
        final percent = map?['usedPercent'];
        if (id == null || id.isEmpty || percent is! num || !percent.isFinite || percent < 0 || percent > 100) {
          throw const FormatException('appAuth/usage: invalid window');
        }
        final reset = asString(map?['resetAt']);
        final seconds = map?['windowSeconds'];
        windows.add(
          SubscriptionUsageWindow(
            id: id,
            usedPercent: percent.toDouble(),
            resetAt: reset == null ? null : DateTime.tryParse(reset),
            windowSeconds: seconds is int && seconds > 0 ? seconds : null,
          ),
        );
      }
    }
    return SubscriptionUsage(
      status: status,
      windows: windows,
      plan: asString(json['plan']),
      reason: asString(json['reason']),
    );
  }

  final SubscriptionUsageStatus status;
  final List<SubscriptionUsageWindow> windows;
  final String? plan;
  final String? reason;
}

/// Where a sign-in attempt is.
enum LoginPhase {
  /// The bridge is starting the flow.
  starting,

  /// Open [LoginStep.url] in a browser; the engine catches the callback.
  open,

  /// Show [LoginStep.userCode]; the person enters it at [LoginStep.url].
  device,

  /// The flow asks for text (a pasted code or redirect URL):
  /// [LoginStep.message], answered with [DshSubscriptions.answerLogin].
  prompt,
  done,
  failed,
  cancelled;

  static LoginPhase fromWire(String? wire) {
    for (final p in values) {
      if (p.name == wire) return p;
    }
    return LoginPhase.failed;
  }

  bool get finished => this == done || this == failed || this == cancelled;
}

/// One poll of a sign-in attempt.
class LoginStep {
  const LoginStep({required this.phase, this.url, this.userCode, this.message, this.placeholder, this.error});

  factory LoginStep.fromJson(Map<String, Object?> json) => LoginStep(
    phase: LoginPhase.fromWire(asString(json['phase'])),
    url: asString(json['url']),
    userCode: asString(json['userCode']),
    message: asString(json['message']),
    placeholder: asString(json['placeholder']),
    error: asString(json['error']),
  );

  final LoginPhase phase;
  final String? url;
  final String? userCode;
  final String? message;
  final String? placeholder;
  final String? error;
}

extension DshSubscriptions on DshClient {
  /// Read the current host's subscription quota without exposing credentials.
  Future<SubscriptionUsage> subscriptionUsage(Subscription subscription) async =>
      SubscriptionUsage.fromJson(subscription, await rpc.call('appAuth/usage', {'provider': subscription.wire}));

  /// `appAuth/list`: every subscription the bridge knows, signed in or not.
  /// Throws `remote/unknown-method` (or similar) when the bridge is absent.
  Future<List<SubscriptionStatus>> subscriptions() async {
    final result = asMap(await rpc.call('appAuth/list')) ?? const {};
    return [
      for (final entry in asListOrEmpty(result['providers']))
        if (asMap(entry) case final map?)
          if (Subscription.fromWire(asString(map['id'])) case final s?) SubscriptionStatus.fromJson(s, map),
    ];
  }

  /// `appAuth/begin`: starts a sign-in; returns the attempt id to poll.
  /// [newAccount] opts out of reusing the official ChatGPT registration.
  Future<String> beginLogin(Subscription subscription, {bool newAccount = false}) async {
    final result = await rpc.call('appAuth/begin', {'provider': subscription.wire, if (newAccount) 'newAccount': true});
    final id = asString(asMap(result)?['attemptId']);
    if (id == null) throw const FormatException('appAuth/begin: no attemptId');
    return id;
  }

  /// `appAuth/poll`: the attempt's current step.
  Future<LoginStep> pollLogin(String attemptId) async =>
      LoginStep.fromJson(asMap(await rpc.call('appAuth/poll', {'attemptId': attemptId})) ?? const {});

  /// `appAuth/answer`: replies to a [LoginPhase.prompt].
  Future<void> answerLogin(String attemptId, String value) =>
      rpc.call('appAuth/answer', {'attemptId': attemptId, 'value': value});

  /// `appAuth/cancel`: abandons an attempt (no-op once finished).
  Future<void> cancelLogin(String attemptId) => rpc.call('appAuth/cancel', {'attemptId': attemptId});

  /// `appAuth/signOut`: removes the stored authorization on the host.
  Future<void> signOut(Subscription subscription) => rpc.call('appAuth/signOut', {'provider': subscription.wire});
}
