// Text for the workspace pages: folder paths as people read them on a phone,
// and short errors for the workspace and directory-picker codes.

import 'package:dsh_client/dsh_client.dart';

import '../../l10n/l10n.dart';
import '../../runtime/local_paths.dart';

/// Where the phone's shared storage appears inside the engine
/// (`PhoneStorage.GUEST_PATH`).
const phoneStorageRoot = '/sdcard';

/// Home of the engine's user on the phone.
String get localHome => LocalPaths.home;

/// [path] for display: the phone's storage as 「手机存储」, the home folder as
/// `~` (the engine's `/root` on the phone, [home] elsewhere when known).
String displayPath(String path, {required bool local, String? home}) {
  if (local) {
    if (path == phoneStorageRoot) return appL10n.remoteDirectoryPhoneStorage;
    if (path.startsWith('$phoneStorageRoot/')) {
      return appL10n.remoteDirectoryPhonePath(path.substring(phoneStorageRoot.length + 1));
    }
  }
  final base = local ? localHome : home;
  if (base != null && base.length > 1) {
    if (path == base) return '~';
    if (path.startsWith('$base/')) return '~/${path.substring(base.length + 1)}';
  }
  return path;
}

/// The folder that contains [path] (POSIX), or null at the root.
String? parentFolder(String path) {
  final trimmed = path.length > 1 && path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  final cut = trimmed.lastIndexOf('/');
  if (cut < 0 || trimmed == '/') return null;
  return cut == 0 ? '/' : trimmed.substring(0, cut);
}

/// Last segment of [path] (the path itself at the root).
String folderName(String path) {
  final parts = path.split('/').where((p) => p.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

/// A valid single folder name, else why not (shown under the field).
String? folderNameProblem(String name) {
  final n = name.trim();
  if (n.isEmpty) return appL10n.remoteWorkspaceNameRequired;
  if (n == '.' || n == '..' || n.contains('/')) return appL10n.remoteDirectoryInvalidName;
  return null;
}

/// One short line for a failed workspace or folder action.
String workspaceErrorText(Object error, {String? fallback}) {
  if (error is DshRemoteException) {
    return switch (error.code) {
      WorkspaceErrors.nameConflict => appL10n.remoteWorkspaceErrNameConflict,
      WorkspaceErrors.invalidPath => appL10n.remoteWorkspaceErrInvalidPath,
      WorkspaceErrors.notFound => appL10n.remoteWorkspaceErrNotFound,
      WorkspaceErrors.unreadable => appL10n.remoteDirectoryErrUnreadable,
      WorkspaceErrors.exists => appL10n.remoteDirectoryErrExists,
      WorkspaceErrors.createFailed => appL10n.remoteDirectoryErrCreate,
      WorkspaceErrors.pickerUnavailable => appL10n.remoteDirectoryErrUnavailable,
      'METHOD_NOT_ALLOWED' || 'gateway/method-not-found' => appL10n.remoteWorkspaceErrUnsupported,
      _ => fallback ?? appL10n.commonFailedTryAgain,
    };
  }
  if (error is DshTransportException ||
      error is DshCarrierLostException ||
      error is DshClosedException ||
      error is DshHttpException) {
    return appL10n.commonEngineUnreachable;
  }
  return fallback ?? appL10n.commonFailedTryAgain;
}
