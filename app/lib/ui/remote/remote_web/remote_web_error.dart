import '../../../l10n/l10n.dart';

String remoteWebErrorText(L10n l10n, String code) => switch (code) {
  'RATE_LIMITED' || 'HTTP_429' => l10n.remoteWebBusy,
  'TUNNEL_UNAVAILABLE' => l10n.remoteWebUnavailable,
  'MEMBERSHIP_REQUIRED' || 'DEVICE_REVOKED' || 'DEVICE_NOT_FOUND' => l10n.remoteWebPairingRequired,
  'FEATURE_NOT_SUPPORTED' || 'DSH_WEB_NOT_READY' => l10n.remoteWebHostNotReady,
  'CONNECTION_NOT_FOUND' || 'TRANSPORT_CLOSED' || 'CLIENT_CLOSED' || 'HOST_OFFLINE' => l10n.remoteWebReconnect,
  'UNTRUSTED_WEB_URL' || 'UNSAFE_WEB_NAVIGATION' => l10n.remoteWebUnsafeUrl,
  'WEB_EXCHANGE_REJECTED' => l10n.remoteWebExchangeRejected,
  'GRANT_EXPIRED' || 'GRANT_CONSUMED' || 'WEB_SESSION_EXPIRED' => l10n.remoteWebSessionExpired,
  'WEB_PLATFORM_UNAVAILABLE' => l10n.remoteWebPlatformUnavailable,
  _ => l10n.remoteWebTryAgain,
};
