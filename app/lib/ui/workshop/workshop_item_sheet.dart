// One workshop item: what it is, who made it, and the one button that
// installs or updates it (docs/design/workshop-app.md).
//
// The sheet follows the item by identity, not by the entry it was opened
// with: a refresh may bring a new version while it is open. Installing goes
// through workshopInstallProvider, which re-checks freshness, version, hash
// and space itself; nothing here decides whether an install is allowed.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../state/attachments.dart' show formatBytes;
import '../../state/workshop_catalog_state.dart';
import '../../state/workshop_install_state.dart';
import '../../workshop/workshop_models.dart';
import '../../workshop/workshop_repository.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/list_page_row.dart';
import '../plugins/plugin_detail_sheet.dart' show PluginHero, PluginStats;
import '../plugins/plugin_widgets.dart' show PluginBadge, PluginBadgeTone;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'workshop_text.dart';
import 'workshop_widgets.dart';

/// Opens [item]'s detail. [onReport] shows 举报 in the title row.
Future<void> showWorkshopItemSheet(BuildContext context, WorkshopItemState item, {ValueChanged<WorkshopEntry>? onReport}) {
  return showAppSheet<void>(
    context,
    heightFactor: 0.82,
    builder: (_) => WorkshopItemSheet(identity: item.entry.metadata.identity, opened: item, onReport: onReport),
  );
}

class WorkshopItemSheet extends ConsumerStatefulWidget {
  const WorkshopItemSheet({super.key, required this.identity, required this.opened, this.onReport});

  final String identity;

  /// What the list showed when the sheet opened; kept on screen if the item
  /// leaves the catalogue while the sheet is up.
  final WorkshopItemState opened;
  final ValueChanged<WorkshopEntry>? onReport;

  @override
  ConsumerState<WorkshopItemSheet> createState() => _WorkshopItemSheetState();
}

class _WorkshopItemSheetState extends ConsumerState<WorkshopItemSheet> {
  /// The replacement request whose dialog is up, so one request asks once.
  WorkshopReplacementRequest? _asking;

  @override
  void initState() {
    super.initState();
    // An install that reached its replacement question while no sheet was up
    // is still waiting for the answer: ask it now, not after another 获取.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final now = ref.read(workshopInstallProvider);
      if (!_mine(now) || now.phase != WorkshopInstallPhase.awaitingReplacement) return;
      if (now.replacement case final request?) unawaited(_askReplace(request));
    });
  }

  bool _mine(WorkshopInstallState install) => install.entry?.metadata.identity == widget.identity;

  Future<void> _install(WorkshopEntry entry) async {
    final accepted = await ref.read(workshopInstallProvider.notifier).install(entry);
    if (!mounted || accepted) return;
    showBriefNotice(context, context.l10n.workshopInstallBusy);
  }

  Future<void> _askReplace(WorkshopReplacementRequest request) async {
    if (identical(_asking, request)) return;
    _asking = request;
    final l10n = context.l10n;
    final title = workshopTitleOf(request.entry.metadata, Localizations.localeOf(context).languageCode);
    final replace = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.workshopReplaceTitle),
        content: Text(l10n.workshopReplaceMessage(title)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(l10n.workshopReplaceConfirm)),
        ],
      ),
    );
    if (!mounted) return;
    // The page may have moved on while the dialog was up: only the request
    // still on offer can be answered.
    final controller = ref.read(workshopInstallProvider.notifier);
    if (!identical(ref.read(workshopInstallProvider).replacement, request)) return;
    if (replace != true) {
      controller.declineReplacement(request);
      return;
    }
    final accepted = await controller.confirmReplacement(request);
    if (mounted && !accepted) showBriefNotice(context, context.l10n.workshopInstallBusy);
  }

  void _onInstallChanged(WorkshopInstallState? before, WorkshopInstallState now) {
    if (!_mine(now)) return;
    if (now.replacement case final request? when now.phase == WorkshopInstallPhase.awaitingReplacement) {
      unawaited(_askReplace(request));
      return;
    }
    if (before?.phase == now.phase) return;
    final l10n = context.l10n;
    switch (now.phase) {
      case WorkshopInstallPhase.succeeded:
        showBriefNotice(
          context,
          now.refreshError != null
              ? l10n.workshopInstallDoneRefreshIssue
              : switch (now.entry?.metadata.kind) {
                  'pet' => l10n.workshopInstallDonePet,
                  'companion' => l10n.workshopInstallDoneCompanion,
                  _ => l10n.workshopInstallDone,
                },
        );
      case WorkshopInstallPhase.cancelled:
        showBriefNotice(context, l10n.workshopInstallCancelled);
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    ref.listen(workshopInstallProvider, _onInstallChanged);

    final item = ref.watch(workshopItemProvider(widget.identity)) ?? widget.opened;
    final gone = ref.watch(workshopItemProvider(widget.identity)) == null;
    final localKnown = ref.watch(workshopCatalogProvider.select((s) => s.localStateKnown));
    final meta = item.entry.metadata;
    final title = workshopTitleOf(meta, locale);
    final installed = item.installed;
    final source = Uri.tryParse(meta.source);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(
          workshopKindText(l10n, meta.kind),
          actions: [
            if (widget.onReport case final report? when !gone)
              IconButton(
                tooltip: l10n.workshopReport,
                icon: Icon(AppIcons.report, size: 20, color: colors.textTertiary),
                onPressed: () => report(item.entry),
              ),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            children: [
              PluginHero(
                avatar: WorkshopEntryAvatar(item.entry, size: 64),
                title: title,
                subtitle: l10n.workshopByAuthor(meta.author),
                badges: [
                  if (item.updateAvailable) PluginBadge(l10n.commonUpdate, tone: PluginBadgeTone.official),
                  if (installed != null && !item.updateAvailable) PluginBadge(l10n.commonInstalled),
                ],
              ),
              WorkshopPreviewPanel(item.entry),
              const SizedBox(height: 20),
              PluginStats([
                (meta.version, l10n.workshopStatVersion),
                (formatBytes(meta.size), l10n.workshopStatSize),
                (meta.license, l10n.workshopStatLicense),
              ]),
              const SizedBox(height: 20),
              if (gone)
                WorkshopNote(
                  l10n.workshopErrorNotFound,
                  tone: WorkshopNoteTone.warning,
                  padding: const EdgeInsets.only(bottom: 12),
                )
              else if (item.installedWithdrawn)
                WorkshopNote(
                  l10n.workshopInstalledWithdrawn,
                  tone: WorkshopNoteTone.warning,
                  padding: const EdgeInsets.only(bottom: 12),
                )
              else if (item.unavailable case final code?)
                WorkshopNote(
                  code == 'workshop_min_app' ? l10n.workshopMinApp(meta.minApp) : workshopErrorLine(l10n, code),
                  tone: WorkshopNoteTone.warning,
                  padding: const EdgeInsets.only(bottom: 12),
                ),
              if (!localKnown) WorkshopNote(l10n.workshopLocalUnknown, padding: const EdgeInsets.only(bottom: 12)),
              Text(l10n.workshopAbout, style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(
                meta.description.trim().isEmpty ? l10n.workshopNoDescription : meta.description.trim(),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: meta.description.trim().isEmpty ? colors.textTertiary : theme.colorScheme.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
              if (meta.tags.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(spacing: 6, runSpacing: 6, children: [for (final tag in meta.tags) PluginBadge(tag)]),
              ],
              if (source != null && source.hasScheme && source.host.isNotEmpty) ...[
                const SizedBox(height: 16),
                ListPageCard(
                  margin: EdgeInsets.zero,
                  children: [
                    ListPageRow(
                      title: l10n.workshopSource,
                      meta: source.host,
                      chevron: true,
                      onTap: () => unawaited(launchUrl(source, mode: LaunchMode.externalApplication)),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Consumer(
              builder: (context, ref, _) {
                final install = ref.watch(workshopInstallProvider);
                final mine = _mine(install);
                return AnimatedSwitcher(
                  duration: AppMotion.of(context, AppMotion.quick),
                  child: mine && install.busy
                      ? _Progress(key: const ValueKey('progress'), install: install)
                      : _Action(
                          key: const ValueKey('action'),
                          item: item,
                          gone: gone,
                          failure: mine && install.phase == WorkshopInstallPhase.failed ? install.error : null,
                          onInstall: () => unawaited(_install(item.entry)),
                        ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// The bottom of the sheet at rest: why the last try failed (if it did), and
/// 获取 / 更新到 x / 已安装.
class _Action extends StatelessWidget {
  const _Action({super.key, required this.item, required this.gone, required this.failure, required this.onInstall});

  final WorkshopItemState item;
  final bool gone;
  final String? failure;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final installed = item.installed;
    final blocked = gone || item.unavailable != null;
    const size = Size.fromHeight(48);
    final String label;
    final VoidCallback? onPressed;
    if (item.updateAvailable && !blocked) {
      label = l10n.workshopUpdateTo(item.entry.metadata.version);
      onPressed = onInstall;
    } else if (installed != null) {
      label = l10n.workshopInstalledVersion(installed.receipt.version);
      onPressed = null;
    } else {
      label = l10n.workshopGet;
      onPressed = blocked ? null : onInstall;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (failure case final code?)
          WorkshopNote(
            workshopErrorLine(l10n, code),
            tone: WorkshopNoteTone.danger,
            padding: const EdgeInsets.only(bottom: 10),
          ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: size),
          onPressed: onPressed,
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}

/// The bottom of the sheet while this item installs: the phase, a bar that
/// only shows a fraction when the bytes are known, and 取消.
class _Progress extends ConsumerWidget {
  const _Progress({super.key, required this.install});

  final WorkshopInstallState install;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final total = install.total;
    final downloading = install.phase == WorkshopInstallPhase.downloading;
    final fraction = downloading && total != null && total > 0 ? (install.received / total).clamp(0.0, 1.0) : null;
    final label = switch (install.phase) {
      WorkshopInstallPhase.downloading => l10n.workshopPhaseDownloading,
      WorkshopInstallPhase.verifying => l10n.workshopPhaseVerifying,
      WorkshopInstallPhase.cancelling => l10n.workshopPhaseCancelling,
      _ => l10n.workshopPhasePreparing,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: theme.textTheme.titleSmall)),
            if (downloading && total != null)
              Text(
                l10n.workshopProgressBytes(formatBytes(install.received), formatBytes(total)),
                style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary)),
              ),
            if (install.phase != WorkshopInstallPhase.cancelling)
              TextButton(
                onPressed: () => ref.read(workshopInstallProvider.notifier).cancel(),
                child: Text(l10n.commonCancel),
              ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: AppShape.radiusXs,
          child: LinearProgressIndicator(minHeight: 4, value: fraction),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
