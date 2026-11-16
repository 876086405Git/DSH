// The conversation's terminal (the official web client's right-sidebar
// terminal, dsh-client-ui-sidebar-terminal) as a full-screen phone page:
// capsule tabs over one dark terminal card, the key row above the keyboard.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show RuntimeSupport, TerminalShell;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/android_features.dart';
import '../../state/runtime_capabilities_state.dart';
import '../../state/terminal_state.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/empty_view.dart';
import '../common/feature_tile.dart';
import '../common/list_page_row.dart';
import '../common/pressable.dart';
import '../common/sheet_navigator.dart';
import '../common/sheet_title_bar.dart';
import '../common/side_insets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../workspace/text_prompt.dart';
import 'terminal_keys.dart';
import 'terminal_screen.dart';

/// The conversation's terminal (a full-screen detail page): the bar with
/// 「终端」 over the current directory, a row of capsule tabs, then one dark
/// terminal card whose bottom slot is the key row above the keyboard.
///
/// Leaving the page only disconnects: the terminal keeps running in the engine
/// and reattaches on return. Only closing a tab ends its process.
class TerminalPage extends ConsumerStatefulWidget {
  const TerminalPage({super.key, required this.sessionId});

  final String sessionId;

  static Route<void> route(String sessionId) =>
      MaterialPageRoute<void>(builder: (_) => TerminalPage(sessionId: sessionId));

  /// Side and bottom inset of the card; the top bar's buttons sit on the same
  /// 12 line.
  static const gutter = 12.0;
  static const barHeight = 56.0;
  static const tabsHeight = 48.0;

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage> {
  final _focus = FocusNode(debugLabel: 'terminal');
  final _modifiers = TerminalModifiers();
  late final AppLifecycleListener _lifecycle;

  NotifierProvider<TerminalWorkspace, TerminalWorkspaceState> get _provider =>
      terminalWorkspaceProvider(widget.sessionId);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => ref.read(_provider.notifier).reconnectAll());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _focus.dispose();
    _modifiers.dispose();
    super.dispose();
  }

  // ── Actions ──

  Future<void> _showActions(TerminalTab tab) {
    final workspace = ref.read(_provider.notifier);
    return showAppSheet<void>(
      context,
      isScrollControlled: true,
      builder: (sheet) => SheetNavigator(
        root: (_) => _TabActions(
          title: tab.title.isEmpty ? appL10n.botsTerminal : tab.title,
          onRename: () {
            Navigator.of(sheet).pop();
            unawaited(_rename(tab));
          },
          loadShells: workspace.shells,
          onNew: (shell) {
            Navigator.of(sheet).pop();
            unawaited(workspace.newTerminal(shellPath: shell?.path));
          },
          onClose: () {
            Navigator.of(sheet).pop();
            unawaited(_close(tab));
          },
        ),
      ),
    );
  }

  Future<void> _rename(TerminalTab tab) async {
    final next = await showTextPrompt(
      context,
      title: appL10n.botsTerminalRename,
      initial: tab.title,
      hint: appL10n.botsTerminalName,
      maxLength: 120,
    );
    if (next == null || next.isEmpty || next == tab.title || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await ref.read(_provider.notifier).rename(tab.id, next);
    if (!ok) messenger?.showSnackBar(SnackBar(content: Text(appL10n.botsTerminalRenameFailed)));
  }

  Future<void> _close(TerminalTab tab) async {
    if (tab.phase == TerminalPhase.live && (tab.info?.running ?? false)) {
      final ok = await showAppDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(appL10n.botsTerminalCloseNamed(tab.title.isEmpty ? appL10n.botsTerminal : tab.title)),
          content: Text(appL10n.botsTerminalCloseBody),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(appL10n.commonCancel)),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: DshColors.of(dialog).danger,
                foregroundColor: DshColors.of(dialog).onDanger,
              ),
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(appL10n.commonClose),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    ref.read(_provider.notifier).closeTab(tab.id);
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = ref.watch(_provider);
    final workspace = ref.read(_provider.notifier);
    final selected = state.selected;
    final padding = MediaQuery.paddingOf(context);
    final cwd = selected?.info?.cwd ?? state.environment?.cwd ?? '';
    // HarmonyOS's own engine has no PTY and says so; asked before the first attach fails.
    final ohos = ref.watch(operatingSystemProvider) == 'ohos';
    final capabilities = ohos ? ref.watch(runtimeCapabilitiesProvider) : null;
    final noPty = capabilities?.value?.shell.pty == RuntimeSupport.unsupported;

    final Widget body;
    if (state.offline) {
      body = Center(
        child: EmptyView(icon: AppIcons.offline, title: TerminalCopy.offline),
      );
    } else if (!state.supported || noPty) {
      body = Center(
        child: EmptyView(
          art: FeatureTile(FeatureKind.terminal, size: FeatureTile.empty),
          title: l10n.botsTerminalUnsupported,
          message: noPty
              ? l10n.harmonyTerminalNoPty
              : (ohos ? l10n.harmonyTerminalSupportedHosts : l10n.botsTerminalSupportedHosts),
        ),
      );
    } else if (capabilities?.isLoading ?? false) {
      body = TerminalCardPlaceholder(label: l10n.botsTerminalOpening);
    } else if (state.error case final error?) {
      body = Center(
        child: EmptyView(
          icon: AppIcons.offline,
          title: error,
          actionLabel: l10n.commonRetry,
          onAction: workspace.reload,
        ),
      );
    } else if (state.loading) {
      body = TerminalCardPlaceholder(label: l10n.botsTerminalOpening);
    } else if (selected == null) {
      body = Center(
        child: EmptyView(
          art: const FeatureTile(FeatureKind.terminal, size: FeatureTile.empty),
          title: l10n.botsTerminalNone,
          actionLabel: l10n.botsTerminalNew,
          onAction: () => unawaited(workspace.newTerminal()),
        ),
      );
    } else {
      body = TerminalCardFrame(
        child: TerminalScreen(sessionId: widget.sessionId, tab: selected, focusNode: _focus, modifiers: _modifiers),
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(theme.brightness),
      child: AppBackdrop(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          // A phone on its side: clear of the cutout on both sides.
          body: SideSafeArea(
            child: Padding(
              padding: EdgeInsets.only(top: padding.top),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TopBar(
                    subtitle: _directoryName(cwd),
                    onMore: selected == null ? null : () => unawaited(_showActions(selected)),
                  ),
                  if (state.tabs.isNotEmpty)
                    _TabsRow(
                      tabs: state.tabs,
                      selectedId: selected?.id,
                      onSelect: workspace.select,
                      onActions: (tab) => unawaited(_showActions(tab)),
                      onNew: () => unawaited(workspace.newTerminal()),
                    ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        TerminalPage.gutter,
                        state.tabs.isEmpty ? TerminalPage.gutter : 0,
                        TerminalPage.gutter,
                        TerminalPage.gutter + padding.bottom,
                      ),
                      child: body,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Last path segment of the shell's starting directory.
  static String _directoryName(String path) {
    final trimmed = path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
    if (trimmed.isEmpty) return '';
    if (trimmed == '/') return '/';
    return trimmed.split('/').last;
  }
}

/// Back · 「终端」 over the directory · more. The two round keys mirror each
/// other so the title stays centred.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.subtitle, required this.onMore});

  final String subtitle;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return SizedBox(
      height: TerminalPage.barHeight,
      child: BackdropGroup(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: TerminalPage.gutter),
          child: Row(
            children: [
              GlassIconButton(
                key: const ValueKey('terminal-back'),
                icon: AppIcons.back,
                tooltip: l10n.commonBack,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l10n.botsTerminal, maxLines: 1, style: theme.textTheme.titleMedium),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.monoLabel(color: DshColors.of(context).textTertiary),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Same width either way keeps the title centred.
              if (onMore == null)
                const SizedBox(width: 44)
              else
                GlassIconButton(
                  key: const ValueKey('terminal-more'),
                  icon: AppIcons.more,
                  tooltip: l10n.commonMore,
                  onPressed: onMore,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The terminals as capsules (ink when selected, like the filter capsules),
/// then a round 「+」 of the same height. Long press a capsule for its
/// actions.
class _TabsRow extends StatelessWidget {
  const _TabsRow({
    required this.tabs,
    required this.selectedId,
    required this.onSelect,
    required this.onActions,
    required this.onNew,
  });

  final List<TerminalTab> tabs;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final ValueChanged<TerminalTab> onActions;
  final VoidCallback onNew;

  static const capsuleHeight = 32.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final idle = dark ? Colors.white.withValues(alpha: 0.07) : scheme.onSurface.withValues(alpha: 0.05);
    final label = theme.textTheme.labelLarge?.copyWith(fontSize: 13);
    return SizedBox(
      height: TerminalPage.tabsHeight,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: TerminalPage.gutter),
        children: [
          for (final (i, tab) in tabs.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            Center(
              child: Semantics(
                key: ValueKey('terminal-tab-${tab.id}'),
                selected: tab.id == selectedId,
                inMutuallyExclusiveGroup: true,
                child: Pressable(
                  onTap: () => onSelect(tab.id),
                  onLongPress: () => onActions(tab),
                  semanticLabel: tab.title.isEmpty ? l10n.botsTerminal : tab.title,
                  child: AnimatedContainer(
                    duration: AppMotion.of(context, AppMotion.quick),
                    height: capsuleHeight,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    alignment: Alignment.center,
                    decoration: ShapeDecoration(
                      color: tab.id == selectedId ? scheme.onSurface : idle,
                      shape: const StadiumBorder(),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 140),
                      child: Text(
                        tab.title.isEmpty ? l10n.botsTerminal : tab.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: label?.copyWith(color: tab.id == selectedId ? scheme.surface : scheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(width: 8),
          Center(
            child: Pressable(
              key: const ValueKey('terminal-new'),
              onTap: onNew,
              semanticLabel: l10n.botsTerminalNew,
              child: Container(
                width: capsuleHeight,
                height: capsuleHeight,
                decoration: ShapeDecoration(color: idle, shape: const CircleBorder()),
                child: Icon(AppIcons.add, size: 20, color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 重命名 · 新建终端(选 Shell) · 关闭终端.
class _TabActions extends StatelessWidget {
  const _TabActions({
    required this.title,
    required this.onRename,
    required this.loadShells,
    required this.onNew,
    required this.onClose,
  });

  final String title;
  final VoidCallback onRename;
  final Future<List<TerminalShell>> Function() loadShells;
  final ValueChanged<TerminalShell?> onNew;
  final VoidCallback onClose;

  static const _margin = EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(title),
            SheetGroup(
              margin: _margin,
              children: [
                ListPageRow(icon: AppIcons.rename, title: l10n.commonRename, chevron: false, onTap: onRename),
                ListPageRow(
                  icon: AppIcons.add,
                  title: l10n.botsTerminalNew,
                  onTap: () =>
                      SheetNavigator.of(context).push((_) => _ShellPicker(loadShells: loadShells, onPick: onNew)),
                ),
              ],
            ),
            SheetGroup(
              margin: _margin,
              children: [
                ListPageRow(
                  icon: AppIcons.close,
                  title: l10n.botsTerminalClose,
                  danger: true,
                  chevron: false,
                  onTap: onClose,
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// Installed shells; the first is the environment's default.
class _ShellPicker extends StatefulWidget {
  const _ShellPicker({required this.loadShells, required this.onPick});

  final Future<List<TerminalShell>> Function() loadShells;
  final ValueChanged<TerminalShell?> onPick;

  @override
  State<_ShellPicker> createState() => _ShellPickerState();
}

class _ShellPickerState extends State<_ShellPicker> {
  late Future<List<TerminalShell>> _shells = widget.loadShells();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.botsTerminalChooseShell),
            FutureBuilder<List<TerminalShell>>(
              future: _shells,
              builder: (context, snapshot) {
                final shells = snapshot.data;
                final List<Widget> rows;
                if (snapshot.hasError) {
                  rows = [
                    ListPageRow(
                      icon: AppIcons.refresh,
                      title: l10n.botsTerminalShellFailed,
                      meta: l10n.commonRetry,
                      onTap: () => setState(() => _shells = widget.loadShells()),
                    ),
                  ];
                } else if (shells == null) {
                  rows = [
                    ListPageRow(
                      leading: const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 1.6)),
                      title: l10n.botsTerminalReading,
                      titleStyle: TextStyle(color: colors.textTertiary),
                    ),
                  ];
                } else if (shells.isEmpty) {
                  rows = [
                    ListPageRow(
                      icon: AppIcons.terminal,
                      title: l10n.botsTerminalDefaultShell,
                      onTap: () => widget.onPick(null),
                    ),
                  ];
                } else {
                  rows = [
                    for (final shell in shells)
                      ListPageRow(
                        icon: AppIcons.terminal,
                        title: shell.name,
                        subtitle: shell.path,
                        chevron: false,
                        onTap: () => widget.onPick(shell),
                      ),
                  ];
                }
                return SheetGroup(margin: _TabActions._margin, children: rows);
              },
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}
