part of '../plugins_state.dart';

// ── Failures ─────────────────────────────────────────────────────────────────

enum PluginFailureKind {
  network,
  timeout,
  pnpmMissing,
  notFound,
  noMatchingVersion,
  tooNew,
  incompatible,
  diskFull,
  permission,
  integrity,

  /// The registry's version isn't the one the official market checked.
  mismatch,
  buildBlocked,
  alreadyInstalled,
  notBundle,
  inUse,
  readOnly,
  cancelled,
  unsupported,
  connection,
  resultUnknown,
  unknown,
}

/// A failed plugin operation in plain Chinese.
class PluginFailure {
  const PluginFailure(this.kind, this.title, this.message, {this.detail, this.pendingBuilds = const []});

  final PluginFailureKind kind;
  final String title;
  final String message;

  /// pnpm / Host diagnostic for the expandable detail.
  final String? detail;

  /// Packages whose build scripts pnpm blocked (offer an explicit approval).
  final List<String> pendingBuilds;

  bool get canApproveBuilds => kind == PluginFailureKind.buildBlocked && pendingBuilds.isNotEmpty;

  bool get retryable => switch (kind) {
    PluginFailureKind.network ||
    PluginFailureKind.timeout ||
    PluginFailureKind.integrity ||
    PluginFailureKind.connection ||
    PluginFailureKind.unknown ||
    PluginFailureKind.noMatchingVersion => true,
    _ => false,
  };
}

String _registryName(String? registry) {
  if (registry == null) return appL10n.stateRegistryDefault;
  final host = Uri.tryParse(registry)?.host ?? registry;
  return switch (host) {
    'registry.npmjs.org' => appL10n.stateRegistryNpm,
    'registry.npmmirror.com' => appL10n.stateRegistryMirror,
    _ => host,
  };
}

String _requirementText(List<PluginIncompatibility> incompatible) {
  if (incompatible.isEmpty) return appL10n.statePluginIncompatible;
  final first = incompatible.first;
  final wanted = first.requirements['engines.dsh'] ?? first.requirements.values.firstOrNull;
  if (wanted == null) return appL10n.statePluginRuntimeIncompatible(first.runtimeVersion);
  return appL10n.statePluginRequiredVersion(wanted, first.runtimeVersion);
}

PluginFailure _installRefusedFailure() =>
    PluginFailure(PluginFailureKind.unsupported, appL10n.marketInstallRefused, appL10n.harmonyPluginRefusedHint);

/// Maps a failed (or cancelled) [result] to user copy. [published] is the
/// version's index publish time, used to explain pnpm's 24-hour cooldown.
PluginFailure describeOperationFailure(
  PluginOperationResult result, {
  required bool isLocal,
  DateTime? published,
  DateTime? now,
}) {
  final run = result.packageResult;
  final detail = [?result.error?.diagnostic, if (run != null && run.output.trim().isNotEmpty) run.output].join('\n\n');
  final d = detail.isEmpty ? null : detail;
  // The engine refused before doing anything: its diagnostic isn't a message.
  if (d != null && d.contains('OHOS_PLUGIN_INSTALL_UNAVAILABLE')) return _installRefusedFailure();
  if (result.application == PluginApplication.cancelled) {
    // The host stopped an operation that had already started, so it may have
    // written something. Only a job cancelled before it ran (the queue's
    // describeCancelled) can promise that nothing changed.
    return PluginFailure(
      PluginFailureKind.cancelled,
      appL10n.statePluginInstallCancelled,
      appL10n.statePluginOperationIncomplete,
    );
  }
  final incompatible = [...?result.error?.incompatible, ...?run?.incompatible];
  if (result.error?.code == 'incompatible-version' || incompatible.isNotEmpty) {
    return PluginFailure(
      PluginFailureKind.incompatible,
      appL10n.statePluginIncompatibleTitle,
      _requirementText(incompatible),
      detail: d,
    );
  }
  switch (run?.kind) {
    case 'network':
      final spec = result.failedAt == 'spec-host';
      final asked = result.registries.map(_registryName).toSet().join(appL10n.stateListSeparator);
      return PluginFailure(
        PluginFailureKind.network,
        appL10n.statePluginNetworkFailed,
        spec
            ? appL10n.statePluginSourceUnreachable
            : (asked.isEmpty
                  ? appL10n.statePluginRegistryUnreachable
                  : appL10n.statePluginNamedRegistryUnreachable(asked)),
        detail: d,
      );
    case 'timeout':
      return PluginFailure(
        PluginFailureKind.timeout,
        appL10n.statePluginDownloadTimeout,
        appL10n.statePluginRegistryUnavailable,
        detail: d,
      );
    case 'pnpm-missing':
      return PluginFailure(
        PluginFailureKind.pnpmMissing,
        appL10n.statePluginPnpmMissing,
        isLocal ? appL10n.statePluginPhonePnpmMissing : appL10n.statePluginHostPnpmMissing,
        detail: [?d, if (!isLocal) 'npm install -g pnpm'].join('\n\n'),
      );
    case 'not-found':
      return PluginFailure(
        PluginFailureKind.notFound,
        appL10n.statePluginNotFound,
        appL10n.statePluginPackageMissing,
        detail: d,
      );
    case 'no-matching-version':
      final reference = now ?? DateTime.now();
      if (published != null && reference.difference(published) < const Duration(hours: 24)) {
        return PluginFailure(
          PluginFailureKind.tooNew,
          appL10n.statePluginTooNew,
          appL10n.statePluginWaitForRelease,
          detail: d,
        );
      }
      return PluginFailure(
        PluginFailureKind.noMatchingVersion,
        appL10n.statePluginVersionMissing,
        appL10n.statePluginRegistryVersionMissing,
        detail: d,
      );
    case 'disk-full':
      return PluginFailure(
        PluginFailureKind.diskFull,
        appL10n.commonStorageFull,
        appL10n.stateDeviceStorageFull,
        detail: d,
      );
    case 'permission':
      return PluginFailure(
        PluginFailureKind.permission,
        appL10n.statePluginNoWritePermission,
        appL10n.statePluginConfigReadOnly,
        detail: d,
      );
    case 'integrity':
      return PluginFailure(
        PluginFailureKind.integrity,
        appL10n.statePluginIntegrityFailed,
        appL10n.statePluginDownloadIncomplete,
        detail: d,
      );
    case 'build-blocked':
      final builds = result.pendingBuilds;
      return PluginFailure(
        PluginFailureKind.buildBlocked,
        appL10n.statePluginBuildScripts,
        builds.isEmpty
            ? appL10n.statePluginBuildApproval
            : appL10n.statePluginBuildsPending(builds.join(appL10n.stateListSeparator)),
        detail: d,
        pendingBuilds: builds,
      );
  }
  switch (result.error?.code) {
    case 'already-installed':
      return PluginFailure(
        PluginFailureKind.alreadyInstalled,
        appL10n.statePluginAlreadyInstalled,
        appL10n.statePluginUninstallFirst,
      );
    case 'not-bundle':
    case 'ambiguous-install':
      return PluginFailure(
        PluginFailureKind.notBundle,
        appL10n.statePluginInvalid,
        appL10n.statePluginNoEntry,
        detail: d,
      );
    case 'bundle-in-use':
      return PluginFailure(
        PluginFailureKind.inUse,
        appL10n.statePluginInUse,
        appL10n.statePluginHasDependents,
        detail: d,
      );
    case 'not-removable':
    case 'management-required':
    case 'unaddressable':
    case 'stop-profile':
      return PluginFailure(
        PluginFailureKind.readOnly,
        appL10n.statePluginManagedElsewhere,
        appL10n.statePluginEngineManaged,
        detail: d,
      );
    case 'stale-approval':
      return PluginFailure(
        PluginFailureKind.buildBlocked,
        appL10n.statePluginAuthorizationExpired,
        appL10n.statePluginBuildChanged,
        detail: d,
      );
    case 'invalid-spec':
      return PluginFailure(
        PluginFailureKind.notFound,
        appL10n.statePluginInvalidAddress,
        appL10n.statePluginCatalogInvalidAddress,
        detail: d,
      );
  }
  if (result.pendingBuilds.isNotEmpty) {
    return PluginFailure(
      PluginFailureKind.buildBlocked,
      appL10n.statePluginBuildScripts,
      appL10n.statePluginBuildsPending(result.pendingBuilds.join(appL10n.stateListSeparator)),
      detail: d,
      pendingBuilds: result.pendingBuilds,
    );
  }
  return PluginFailure(
    PluginFailureKind.unknown,
    appL10n.statePluginOperationIncomplete,
    appL10n.commonFailedTryAgain,
    detail: d,
  );
}

/// Maps an exception from a plugin call to user copy.
PluginFailure describePluginError(Object error) {
  switch (error) {
    case DshRemoteException(code: 'METHOD_NOT_ALLOWED'):
      return PluginFailure(
        PluginFailureKind.unsupported,
        appL10n.statePluginRemoteForbidden,
        appL10n.statePluginRelayToggleOnly,
      );
    case DshRemoteException(:final code, :final message) when code.startsWith('gateway/'):
      return PluginFailure(
        PluginFailureKind.unsupported,
        appL10n.statePluginManagementUnsupported,
        appL10n.statePluginEngineUnsupported,
        detail: '$code: $message',
      );
    case DshRemoteException(:final code, :final message):
      return PluginFailure(
        PluginFailureKind.unknown,
        appL10n.statePluginOperationIncomplete,
        appL10n.commonFailedTryAgain,
        detail: '$code: $message',
      );
    case DshHttpException(statusCode: 404):
      return PluginFailure(
        PluginFailureKind.unsupported,
        appL10n.statePluginManagementUnsupported,
        appL10n.statePluginEngineUnsupported,
      );
    case _InstallResultUnknown():
      return PluginFailure(
        PluginFailureKind.resultUnknown,
        appL10n.statePluginResultMissing,
        appL10n.statePluginResultPending,
      );
    case _ when engineUnreachable(error):
      return PluginFailure(
        PluginFailureKind.connection,
        appL10n.statePluginDisconnected,
        appL10n.commonEngineUnreachable,
        detail: '$error',
      );
    default:
      return PluginFailure(
        PluginFailureKind.unknown,
        appL10n.statePluginOperationIncomplete,
        appL10n.commonFailedTryAgain,
        detail: '$error',
      );
  }
}

class _InstallResultUnknown implements Exception {
  const _InstallResultUnknown();
}
