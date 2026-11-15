// Words for the workshop pages: what a stable error code means to the person,
// a release's name in their language, and the few shared labels.
//
// The state layer (lib/state/workshop_*.dart) only hands out codes; every
// sentence a page shows comes from here, so one code reads the same on every
// page. A code this file doesn't know gets the generic line, never a guess
// from its name (docs/design/workshop-app.md).

import '../../l10n/l10n.dart';
import '../../workshop/workshop_models.dart';

/// What [code] means, in a sentence. Null in, null out.
String? workshopErrorText(L10n l10n, String? code) => code == null ? null : workshopErrorLine(l10n, code);

/// As [workshopErrorText], for a code that is there.
String workshopErrorLine(L10n l10n, String code) => switch (code) {
  'workshop_network' || 'workshop_download_unavailable' => l10n.workshopErrorNetwork,
  'workshop_timeout' => l10n.workshopErrorTimeout,
  'workshop_http' ||
  'workshop_redirect' ||
  'workshop_storage_unavailable' ||
  'workshop_state_invalid' ||
  'workshop_state_conflict' ||
  'workshop_capacity' ||
  'workshop_moc_policy_unavailable' => l10n.workshopErrorServer,
  'workshop_rate_limited' => l10n.workshopErrorRateLimited,
  'workshop_bad_response' ||
  'workshop_bad_catalog' ||
  'workshop_catalog_rollback' ||
  'workshop_cache_invalid' ||
  'workshop_download_range' => l10n.workshopErrorBadData,
  'workshop_catalog_changed' => l10n.workshopErrorCatalogChanged,
  'workshop_not_found' => l10n.workshopErrorNotFound,
  'workshop_version_withdrawn' || 'workshop_version_rewritten' => l10n.workshopErrorWithdrawn,
  'workshop_min_app' || 'workshop_app_version_unknown' || 'workshop_app_too_old' => l10n.workshopErrorMinApp,
  'workshop_unsupported_kind' => l10n.workshopErrorUnsupported,
  'workshop_companion_disabled' => l10n.workshopErrorCompanionOff,
  'workshop_upload_disabled' => l10n.workshopErrorUploadOff,
  'workshop_no_space' => l10n.workshopErrorNoSpace,
  'workshop_storage' || 'workshop_cache_storage' || 'workshop_export_exists' => l10n.workshopErrorStorage,
  'workshop_size_mismatch' || 'workshop_sha_mismatch' => l10n.workshopErrorIntegrity,
  'workshop_downgrade' => l10n.workshopErrorDowngrade,
  'workshop_runtime_missing' => l10n.workshopErrorRuntimeMissing,
  'workshop_readers_busy' => l10n.workshopErrorReadersBusy,
  'workshop_install_record' || 'workshop_install_conflict' => l10n.workshopErrorInstallRecord,
  'workshop_other_origin' => l10n.workshopErrorOtherOrigin,
  'workshop_account_auth_required' || 'workshop_account_auth_invalid' || 'workshop_profile_required' => l10n.workshopErrorSignIn,
  'workshop_consent_required' || 'workshop_confirmation_stale' => l10n.workshopErrorConsent,
  // The getters keep their old names until the sign-in wording is rewritten.
  'workshop_account_origin' => l10n.workshopErrorAccountMismatch,
  'workshop_account_unavailable' => l10n.workshopErrorAccountDown,
  'workshop_preferences' => l10n.workshopErrorPreferences,
  'workshop_busy' => l10n.workshopErrorBusy,
  'workshop_cancelled' => l10n.workshopErrorCancelled,
  'workshop_unconfigured' || 'workshop_untrusted_origin' => l10n.workshopNotOpenMessage,
  _ => l10n.workshopErrorGeneric,
};

/// As [workshopErrorLine] for an exception: a write whose result is unknown
/// says so, whatever its code, because retrying it could do the thing twice.
String workshopExceptionText(L10n l10n, WorkshopException error) =>
    error.resultUnknown ? l10n.workshopErrorUnknownResult : workshopErrorLine(l10n, error.code);

/// The release's title in [languageCode], else the other language's, else its id.
String workshopTitleOf(WorkshopMetadata metadata, String languageCode) {
  final own = metadata.title[languageCode]?.trim();
  if (own != null && own.isNotEmpty) return own;
  for (final other in metadata.title.values) {
    if (other.trim().isNotEmpty) return other.trim();
  }
  return metadata.id;
}

/// 「像素宠物」 / 「伙伴」; an unknown kind shows as written.
String workshopKindText(L10n l10n, String kind) => switch (kind) {
  'pet' => l10n.workshopKindPet,
  'companion' => l10n.workshopKindCompanion,
  _ => kind,
};

/// The address as the person would recognise it: the host, with its port
/// when it has one. An IPv6 host keeps its brackets, so the port cannot be
/// read as part of the address.
String workshopHostText(Uri origin) {
  final host = origin.host.contains(':') ? '[${origin.host}]' : origin.host;
  return origin.hasPort ? '$host:${origin.port}' : host;
}
