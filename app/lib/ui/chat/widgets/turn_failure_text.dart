import '../../../l10n/l10n.dart';

/// Codes DSH (0.2.1-rc.4+) answers before sending anything when the model
/// itself can't be served: the official model listing says it needs a newer
/// DSH (`CLIENT_UPGRADE_REQUIRED`), or this DSH doesn't know it
/// (`MODEL_UNSUPPORTED`), or the chosen reasoning effort is unsupported.
/// Sending unchanged can't help; choose a supported effort/model or upgrade.
const modelRefusalCodes = {'CLIENT_UPGRADE_REQUIRED', 'MODEL_UNSUPPORTED', 'UNSUPPORTED_REASONING_EFFORT'};

/// The engine reports 401 and 403 alike as AUTH; only the message tells them apart.
/// A 403 is a key that may well be fine but isn't allowed this.
final _forbidden = RegExp(r'\b403\b|permission[_ ](denied|error)', caseSensitive: false);

/// 一轮出错时说明行上的短句,按错误码给;后端原文放在点开的详情里。
String turnFailureText(String? code, {String? message}) => switch (code) {
  'AUTH' when message != null && _forbidden.hasMatch(message) => appL10n.chatErrForbidden,
  'AUTH' || 'INVALID_CREDENTIAL' => appL10n.chatErrApiKey,
  'QUOTA' => appL10n.chatErrBalance,
  'ACCOUNT_QUOTA' => appL10n.chatErrAccountQuota,
  'RATE_LIMIT' => appL10n.chatErrRateLimit,
  'CONTEXT_WINDOW_EXCEEDED' => appL10n.chatErrContextLength,
  'SERVER' => appL10n.chatErrModelUnavailable,
  final value? when RegExp(r'^HTTP_5\d\d$').hasMatch(value) => appL10n.chatErrModelUnavailable,
  'TIMEOUT' => appL10n.chatErrModelTimeout,
  'TRANSPORT' => appL10n.chatErrModelConnection,
  'EMPTY_RESPONSE' => appL10n.chatErrModelEmpty,
  // The engine is on the phone (updated with the app) or on the remote host.
  'CLIENT_UPGRADE_REQUIRED' => appL10n.chatErrEngineOutdated,
  'MODEL_UNSUPPORTED' => appL10n.chatErrModelUnsupported,
  'UNSUPPORTED_REASONING_EFFORT' => appL10n.chatErrReasoningEffortUnsupported,
  _ => appL10n.chatErrTurn,
};
