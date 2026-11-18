// Native mirror of the official in-app folder browser
// (`dsh-client-ui-directory-picker-browse`): a sheet with where to start
// (the home folder, the engine's default folder, the phone's storage, recent
// places), then a full page that walks the host's folders one level at a
// time through `directoryPicker/list` — breadcrumb capsules on top, folders
// only, 「新建文件夹」 through `directoryPicker/createDirectory`. Remote hosts
// browse their own disks through the same calls.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/local_paths.dart';
import '../../state/connection_state.dart';
import '../../state/sessions_state.dart' show localWorkspaceDir;
import '../../state/settings_state.dart';
import '../../state/workspaces_state.dart';
import '../common/app_sheet.dart';
import '../common/breadcrumb_row.dart';
import '../common/fade_in.dart';
import '../common/list_page_row.dart';
import '../common/sheet_title_bar.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../features/feature_widgets.dart';
import '../providers/provider_widgets.dart' show FormBottomBar;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'text_prompt.dart';
import 'workspace_format.dart';

/// Picks a folder on the active host; null when dismissed. [confirmLabel]
/// is the verb on the browser's button (「添加」 → 「添加「dsh-app」」).
Future<String?> showDirectoryPicker(BuildContext context, {String? title, String? confirmLabel}) {
  final l10n = context.l10n;
  return showAppSheet<String>(
    context,
    isScrollControlled: true,
    builder: (_) => DirectoryLocationsSheet(
      title: title ?? l10n.remoteDirectoryPickerTitle,
      confirmLabel: confirmLabel ?? l10n.remoteDirectoryChoose,
    ),
  );
}

/// One place to start browsing from.
class DirectoryShortcut {
  const DirectoryShortcut(this.icon, this.title, this.path, {this.subtitle});

  final IconData icon;
  final String title;

  /// Null: the host's home folder (its path is known only after listing).
  final String? path;
  final String? subtitle;
}

/// Where to start: the home folder and the engine's default folder; on the
/// phone also its shared storage (when the engine can see it).
List<DirectoryShortcut> directoryShortcuts({required bool local, required bool phoneStorage, String? workingDir}) {
  if (local) {
    return [
      DirectoryShortcut(
        AppIcons.defaultFolder,
        appL10n.remoteDirectoryDefault,
        localWorkspaceDir,
        subtitle: displayPath(localWorkspaceDir, local: true),
      ),
      // HarmonyOS: the sandbox lets the engine at its default folder and no further.
      if (!LocalPaths.noGuest) DirectoryShortcut(AppIcons.home, appL10n.remoteDirectoryHome, localHome, subtitle: '~'),
      if (phoneStorage) ...[
        DirectoryShortcut(AppIcons.phoneStorage, appL10n.remoteDirectoryPhoneStorage, phoneStorageRoot),
        DirectoryShortcut(
          AppIcons.downloads,
          appL10n.remoteDirectoryDownloads,
          '$phoneStorageRoot/Download',
          subtitle: appL10n.remoteDirectoryDownloadsPath,
        ),
        DirectoryShortcut(
          AppIcons.document,
          appL10n.remoteDirectoryDocuments,
          '$phoneStorageRoot/Documents',
          subtitle: appL10n.remoteDirectoryDocumentsPath,
        ),
      ],
    ];
  }
  return [
    DirectoryShortcut(AppIcons.home, appL10n.remoteDirectoryHome, null, subtitle: '~'),
    if (workingDir != null && workingDir.isNotEmpty)
      DirectoryShortcut(AppIcons.defaultFolder, appL10n.remoteDirectoryDefault, workingDir, subtitle: workingDir),
  ];
}

/// The picker's first step (a sheet): places to start, recent places,
/// 「输入路径」.
class DirectoryLocationsSheet extends ConsumerWidget {
  const DirectoryLocationsSheet({super.key, required this.title, required this.confirmLabel});

  final String title;
  final String confirmLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final conn = ref.watch(activeConnectionProvider).value;
    final local = conn?.isLocal ?? true;
    final phoneStorage = ref.watch(settingsProvider.select((s) => s.phoneStorage));
    final recent = ref.watch(workspacePrefsProvider.select((p) => p.recent));
    final shortcuts = directoryShortcuts(local: local, phoneStorage: phoneStorage, workingDir: conn?.workingDirectory);
    final canBrowse = conn?.client.canBrowseDirectories ?? false;
    final known = {for (final s in shortcuts) ?s.path};
    final places = [
      for (final p in recent)
        if (!known.contains(p)) p,
    ];

    Future<void> browse(String? path) async {
      final navigator = Navigator.of(context);
      final picked = await navigator.push<String>(
        MaterialPageRoute(
          builder: (_) => DirectoryBrowserPage(start: path, confirmLabel: confirmLabel),
        ),
      );
      if (picked != null && navigator.mounted) navigator.pop(picked);
    }

    Future<void> typePath() async {
      final path = await askFolderPath(context);
      if (path == null || !context.mounted) return;
      // Without the browser the typed folder is the answer; the host checks it.
      if (canBrowse) {
        await browse(path);
      } else {
        Navigator.of(context).pop(path);
      }
    }

    const margin = EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(title),
              if (conn == null)
                const FeatureOffline()
              else ...[
                if (canBrowse)
                  SheetGroup(
                    title: l10n.remoteDirectoryLocations,
                    margin: margin,
                    children: [
                      for (final s in shortcuts)
                        ListPageRow(icon: s.icon, title: s.title, subtitle: s.subtitle, onTap: () => browse(s.path)),
                    ],
                  ),
                if (canBrowse && places.isNotEmpty)
                  SheetGroup(
                    title: l10n.remoteDirectoryRecent,
                    margin: margin,
                    children: [
                      for (final p in places)
                        ListPageRow(
                          icon: AppIcons.history,
                          title: folderName(p),
                          subtitle: displayPath(p, local: local),
                          onTap: () => browse(p),
                        ),
                    ],
                  ),
                SheetGroup(
                  margin: margin,
                  children: [
                    ListPageRow(
                      icon: AppIcons.enterPath,
                      title: l10n.remoteDirectoryEnterPath,
                      chevron: false,
                      onTap: typePath,
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}

/// A Windows host's absolute path (C:/Users/me, C:\Users\me) and its drive root.
final _drivePath = RegExp(r'^[A-Za-z]:[\\/]');
final _driveRoot = RegExp(r'^[A-Za-z]:[\\/]$');

/// Asks for an absolute folder path, as the host writes it.
Future<String?> askFolderPath(BuildContext context) async {
  final l10n = context.l10n;
  final path = await showTextPrompt(
    context,
    title: l10n.remoteDirectoryEnterPath,
    hint: localWorkspaceDir,
    confirm: l10n.remoteDirectoryGo,
    mono: true,
    keyboardType: TextInputType.url,
    validate: (v) => v.startsWith('/') || _drivePath.hasMatch(v) ? null : l10n.remoteDirectoryAbsolutePath,
  );
  if (path == null || _driveRoot.hasMatch(path)) return path;
  return path.length > 1 && path.endsWith('/') ? path.substring(0, path.length - 1) : path;
}

/// Asks for a new folder's name.
Future<String?> askFolderName(BuildContext context, {required String parentName}) => showTextPrompt(
  context,
  title: context.l10n.remoteDirectoryNewFolder,
  caption: context.l10n.remoteDirectoryParentCaption(parentName),
  hint: context.l10n.remoteDirectoryFolderName,
  confirm: context.l10n.commonCreate,
  maxLength: 120,
  validate: folderNameProblem,
);

/// A breadcrumb for display.
typedef Crumb = ({String label, String path});

/// Breadcrumbs as people read them: inside the phone's storage from
/// 「手机存储」, inside the home folder from 「主目录」, else from the root.
List<Crumb> displayCrumbs(DirectoryLevel level, {required bool local}) {
  final crumbs = level.crumbs;
  final storage = local ? crumbs.indexWhere((c) => c.path == phoneStorageRoot) : -1;
  final home = crumbs.indexWhere((c) => c.path == level.home);
  final (start, label) = storage >= 0
      ? (storage, appL10n.remoteDirectoryPhoneStorage)
      : (home >= 0 ? (home, appL10n.remoteDirectoryHome) : (0, appL10n.remoteDirectoryRoot));
  return [
    for (final (i, c) in crumbs.indexed)
      if (i == start) (label: label, path: c.path) else if (i > start) (label: c.name, path: c.path),
  ];
}

/// The browser's title for [level]: its last crumb as displayed.
String levelTitle(DirectoryLevel level, {required bool local}) {
  final crumbs = displayCrumbs(level, local: local);
  return crumbs.isEmpty ? level.path : crumbs.last.label;
}

/// The full-page browser: one level of the host's folders at a time.
/// Pops with the chosen folder's path.
class DirectoryBrowserPage extends ConsumerStatefulWidget {
  const DirectoryBrowserPage({super.key, this.start, this.confirmLabel});

  /// Folder to open first; null opens the host's home folder.
  final String? start;
  final String? confirmLabel;

  @override
  ConsumerState<DirectoryBrowserPage> createState() => _DirectoryBrowserPageState();
}

class _DirectoryBrowserPageState extends ConsumerState<DirectoryBrowserPage> {
  DirectoryLevel? _level;
  Object? _error;
  bool _busy = false;
  bool _showHidden = false;

  /// Folders walked through, for 「返回」 one level at a time.
  final List<String> _history = [];

  DshClient? get _client => ref.read(activeConnectionProvider).value?.client;

  @override
  void initState() {
    super.initState();
    unawaited(_open(widget.start, record: false));
  }

  void _toast(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  /// Lists [path]; keeps the current level on screen until it arrives.
  Future<void> _open(String? path, {bool record = true}) async {
    final client = _client;
    if (client == null) return setState(() => _error = const DshTransportException('not connected'));
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final level = await client.browseDirectory(path);
      if (!mounted) return;
      setState(() {
        if (record && _level != null && _level!.path != level.path) _history.add(_level!.path);
        _level = level;
        _error = null;
        _showHidden = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (_level == null) {
        setState(() => _error = e);
      } else {
        _toast(workspaceErrorText(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _back() async {
    if (_history.isEmpty) return;
    final previous = _history.removeLast();
    await _open(previous, record: false);
  }

  Future<void> _newFolder() async {
    final level = _level;
    final client = _client;
    if (level == null || client == null) return;
    final local = ref.read(activeConnectionProvider).value?.isLocal ?? true;
    final name = await askFolderName(context, parentName: levelTitle(level, local: local));
    if (name == null || !mounted) return;
    try {
      final created = await client.createDirectory(level.path, name);
      if (!mounted) return;
      await _open(created);
    } catch (e) {
      if (mounted) _toast(workspaceErrorText(e, fallback: context.l10n.remoteDirectoryErrCreate));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final conn = ref.watch(activeConnectionProvider).value;
    final local = conn?.isLocal ?? true;
    final level = _level;
    final title = level == null ? l10n.remoteDirectoryPickerTitle : levelTitle(level, local: local);
    final confirmLabel = widget.confirmLabel ?? l10n.remoteDirectoryChoose;
    final canCreate = conn?.client.canCreateDirectories ?? false;

    final Widget body;
    if (level == null && _error != null) {
      final unavailable =
          _error is DshRemoteException && (_error as DshRemoteException).code == WorkspaceErrors.pickerUnavailable;
      body = FeatureMessage(
        icon: AppIcons.noFolder,
        title: workspaceErrorText(_error!),
        action: unavailable ? null : (l10n.commonRetry, () => _open(widget.start, record: false)),
      );
    } else if (level == null) {
      body = const QuietSpinner();
    } else {
      body = _LevelList(
        level: level,
        local: local,
        showHidden: _showHidden,
        onOpen: (path) => unawaited(_open(path)),
        onToggleHidden: () => setState(() => _showHidden = !_showHidden),
      );
    }

    final page = AppPage(
      // A new level starts at the top, its rows rising in again.
      key: ValueKey(level?.path),
      title: title,
      actions: [
        if (canCreate && level != null)
          GlassIconButton(icon: AppIcons.newFolder, tooltip: l10n.remoteDirectoryNewFolder, onPressed: _newFolder),
      ],
      slivers: [
        SliverList.list(
          children: [
            if (level != null)
              BreadcrumbRow(
                crumbs: displayCrumbs(level, local: local),
                onTap: (path) {
                  if (path != level.path) unawaited(_open(path));
                },
              ),
            body,
            const SizedBox(height: FormBottomBar.height),
          ],
        ),
      ],
    );

    return PopScope(
      canPop: _history.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: Stack(
        children: [
          page,
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: FormBottomBar(
              child: FilledButton(
                onPressed: level == null || _busy ? null : () => Navigator.of(context).pop(level.path),
                child: Text(
                  level == null ? confirmLabel : l10n.remoteDirectoryConfirmFolder(confirmLabel, title),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LevelList extends StatelessWidget {
  const _LevelList({
    required this.level,
    required this.local,
    required this.showHidden,
    required this.onOpen,
    required this.onToggleHidden,
  });

  final DirectoryLevel level;
  final bool local;
  final bool showHidden;
  final ValueChanged<String> onOpen;
  final VoidCallback onToggleHidden;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final hidden = level.entries.where((e) => e.hidden).length;
    final shown = [
      for (final e in level.entries)
        if (showHidden || !e.hidden) e,
    ];
    final colors = DshColors.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (shown.isEmpty)
          FeatureMessage(icon: AppIcons.folderOpen, title: l10n.remoteDirectoryNoSubfolders)
        else
          ListPageCard(
            children: [
              for (final (i, e) in shown.indexed)
                FadeSlideIn(
                  index: i,
                  child: ListPageRow(
                    icon: AppIcons.folder,
                    iconColor: e.hidden ? colors.textTertiary : null,
                    title: e.name,
                    onTap: () => onOpen(e.path),
                  ),
                ),
            ],
          ),
        if (hidden > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: TextButton(
                onPressed: onToggleHidden,
                style: TextButton.styleFrom(
                  foregroundColor: colors.textTertiary,
                  textStyle: theme.textTheme.bodySmall,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: Text(showHidden ? l10n.remoteDirectoryHideHidden : l10n.remoteDirectoryShowHidden(hidden)),
              ),
            ),
          ),
        if (level.truncated) FeatureNote(l10n.remoteDirectoryTruncated),
      ],
    );
  }
}
