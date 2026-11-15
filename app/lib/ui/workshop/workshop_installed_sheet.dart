// One installed row, opened: what this phone knows about it, what is wrong
// with it in plain words, and 更新 / 卸载 (docs/design/workshop-app.md).
//
// Everything shown comes from the local record (the receipt) plus whatever
// the public catalogue added to the row; a row without a trusted receipt
// shows its local id and its problem, nothing guessed. The sheet does the
// asking (卸载 is confirmed here) and hands the choice back; the list is the
// one that calls the controllers.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/workshop_installed_state.dart';
import '../../workshop/workshop_models.dart';
import '../../workshop/workshop_repository.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../plugins/plugin_widgets.dart' show PluginAvatar;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'workshop_text.dart';
import 'workshop_widgets.dart';

/// What the person chose in the sheet. The list acts on it after the sheet
/// has closed.
sealed class WorkshopInstalledChoice {
  const WorkshopInstalledChoice();
}

/// 更新: open [entry]'s detail, where installing is done.
class WorkshopInstalledUpdate extends WorkshopInstalledChoice {
  const WorkshopInstalledUpdate(this.entry);

  final WorkshopEntry entry;
}

/// 卸载, already confirmed: [local] is the row's own object, to be passed on
/// as it is.
class WorkshopInstalledUninstall extends WorkshopInstalledChoice {
  const WorkshopInstalledUninstall(this.local);

  final WorkshopLocalEntry local;
}

/// Opens [row]'s sheet. Null when it was just closed.
Future<WorkshopInstalledChoice?> showWorkshopInstalledSheet(BuildContext context, WorkshopInstalledRow row) {
  return showAppSheet<WorkshopInstalledChoice>(
    context,
    // As tall as what it has to say (its notes can run to several lines);
    // past the screen it scrolls.
    isScrollControlled: true,
    builder: (_) => WorkshopInstalledSheet(opened: row),
  );
}

/// The row's name: the public title when the catalogue has the item, else the
/// id its receipt carries, else (no trusted receipt) the local id.
String workshopInstalledTitle(WorkshopInstalledRow row, String languageCode) {
  if (row.publicEntry case final entry?) return workshopTitleOf(entry.metadata, languageCode);
  return switch (row.local) {
    WorkshopInstalled(:final receipt) => receipt.id,
    WorkshopInstallationIssue(:final localId) => localId,
  };
}

/// What the last uninstall says about [row]: [WorkshopRemovalPhase.idle]
/// unless it was this row's.
///
/// A running or failed removal follows the row through a re-read (same slot,
/// same receipt). A finished one only marks the very object it removed: a row
/// that is still listed because the list could not refresh, not a later
/// install into the same slot.
WorkshopRemovalPhase workshopInstalledRemovalOf(WorkshopInstalledRow row, WorkshopRemovalState removal) {
  final target = removal.target;
  final local = row.local;
  if (target == null) return WorkshopRemovalPhase.idle;
  final mine = switch (removal.phase) {
    WorkshopRemovalPhase.idle => false,
    WorkshopRemovalPhase.succeeded => identical(local, target),
    WorkshopRemovalPhase.removing || WorkshopRemovalPhase.failed =>
      local.localId == target.localId &&
          (local is WorkshopInstalled && target is WorkshopInstalled
              ? local.receipt.same(target.receipt)
              : identical(local, target)),
  };
  return mine ? removal.phase : WorkshopRemovalPhase.idle;
}

/// What kind of local problem a diagnostic code is. Which codes mean "the
/// package itself is wrong" is the data layer's list
/// ([workshopPackageValidationCodes]); a code this page has no name for is
/// [other], never a guess from how it is spelled.
enum _LocalIssue { broken, unreadable, record, other }

_LocalIssue _localIssue(String code) => switch (code) {
  'workshop_install_record' || 'workshop_install_conflict' => _LocalIssue.record,
  'workshop_storage' || 'workshop_companion_storage' => _LocalIssue.unreadable,
  _ when workshopPackageValidationCodes.contains(code) => _LocalIssue.broken,
  _ => _LocalIssue.other,
};

/// A local problem in a few words, for a row's status line.
String workshopInstalledIssueLine(L10n l10n, String code) => switch (_localIssue(code)) {
  _LocalIssue.broken => l10n.workshopInstalledIssueBroken,
  _LocalIssue.unreadable => l10n.workshopInstalledIssueUnreadable,
  _LocalIssue.record => l10n.workshopInstalledIssueRecord,
  _LocalIssue.other => l10n.workshopInstalledIssueOther,
};

/// As [workshopInstalledIssueLine], as a sentence.
String _issueText(L10n l10n, String code) => switch (_localIssue(code)) {
  _LocalIssue.broken => l10n.workshopInstalledNoteBroken,
  _LocalIssue.unreadable => l10n.workshopInstalledNoteUnreadable,
  _LocalIssue.record => l10n.workshopInstalledNoteRecord,
  _LocalIssue.other => l10n.workshopInstalledNoteOther,
};

/// Why the catalogue's side of [row] is not simply "fine", as a sentence;
/// null when there is nothing to say (or a louder note already says it).
String? _remoteText(L10n l10n, WorkshopInstalledRow row) => switch (row.remoteUnavailable) {
  null => null,
  'workshop_other_origin' => l10n.workshopInstalledNoteOtherOrigin,
  'workshop_not_found' => l10n.workshopInstalledNoteNotListed,
  'workshop_version_rewritten' => l10n.workshopInstalledNoteRewritten,
  'workshop_companion_disabled' => l10n.workshopErrorCompanionOff,
  'workshop_min_app' || 'workshop_app_version_unknown' || 'workshop_app_too_old' => l10n.workshopInstalledNoteMinApp,
  'workshop_version_withdrawn' when row.installedWithdrawn == true => null,
  _ => l10n.workshopInstalledNoteUnavailable,
};

/// The row's square: the item's own tint when its identity is trusted, a
/// plain mark when all that is known is that something is there.
class WorkshopInstalledAvatar extends StatelessWidget {
  const WorkshopInstalledAvatar(this.row, {super.key, this.size = 40});

  final WorkshopInstalledRow row;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (row.publicEntry case final entry?) return WorkshopEntryAvatar(entry, size: size);
    final local = row.local;
    if (local is WorkshopInstalled) {
      // The same tint WorkshopAvatar gives this identity.
      return PluginAvatar(name: local.receipt.identity, title: local.receipt.id, size: size);
    }
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: ShapeDecoration(color: scheme.surfaceContainerHighest, shape: Squircle.border(size * 0.25)),
        child: Center(child: Icon(AppIcons.question, size: size * 0.5, color: scheme.onSurfaceVariant)),
      ),
    );
  }
}

class WorkshopInstalledSheet extends ConsumerWidget {
  const WorkshopInstalledSheet({super.key, required this.opened});

  /// The row the list showed when the sheet opened. The sheet follows its
  /// slot (the local id): the catalogue's half may arrive while it is up.
  final WorkshopInstalledRow opened;

  Future<void> _askUninstall(BuildContext context, WorkshopInstalledRow row, String title) async {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final lost = const {'workshop_not_found', 'workshop_version_withdrawn'}.contains(row.remoteUnavailable);
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.workshopInstalledRemoveTitle(title)),
        content: Text(
          lost
              ? '${l10n.workshopInstalledRemoveMessage}\n\n${l10n.workshopInstalledRemoveNoReinstall}'
              : l10n.workshopInstalledRemoveMessage,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: colors.danger, foregroundColor: colors.onDanger),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.hubPluginUninstall),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    // The object the person was looking at when they said yes, unchanged.
    Navigator.of(context).pop(WorkshopInstalledUninstall(row.local));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final state = ref.watch(workshopInstalledProvider);
    final listed = state.rows.where((r) => r.local.localId == opened.local.localId).firstOrNull;
    final row = listed ?? opened;
    final removal = workshopInstalledRemovalOf(row, state.removal);
    // The list is being read, or could not be: a row missing from it says
    // nothing about the phone, so what was opened stays, with its actions.
    final unread = listed == null && (state.loading || state.loadError != null);
    // Removed while the sheet was up, or removed with the list not yet re-read.
    final gone = (listed == null && !unread) || removal == WorkshopRemovalPhase.succeeded;
    final local = row.local;
    final title = workshopInstalledTitle(row, locale);
    final update = row.updateAvailable == true ? row.publicEntry : null;
    final busy = state.removal.phase == WorkshopRemovalPhase.removing;
    const notePadding = EdgeInsets.fromLTRB(kSheetGutter + 4, 0, kSheetGutter, 10);
    const buttonSize = Size.fromHeight(48);

    final notes = <Widget>[
      if (gone)
        WorkshopNote(l10n.workshopInstalledNoteGone, padding: notePadding)
      else ...[
        if (unread)
          WorkshopNote(l10n.workshopInstalledNoteUnread, tone: WorkshopNoteTone.warning, padding: notePadding),
        if (removal == WorkshopRemovalPhase.failed)
          WorkshopNote(
            l10n.workshopInstalledRemoveFailed(workshopErrorLine(l10n, state.removal.error ?? '')),
            tone: WorkshopNoteTone.danger,
            padding: notePadding,
            // Put away on the person's tap, never from a listener: the row
            // goes back to what the phone says about it.
            actionLabel: l10n.workshopInstalledDismissFailure,
            onAction: () => ref.read(workshopInstalledProvider.notifier).acknowledgeRemoval(),
          ),
        if (row.localIssue case final code?)
          WorkshopNote(_issueText(l10n, code), tone: WorkshopNoteTone.warning, padding: notePadding),
        if (!row.canUninstall) WorkshopNote(l10n.workshopInstalledNoteUntrusted, padding: notePadding),
        if (row.installedWithdrawn == true)
          WorkshopNote(l10n.workshopInstalledWithdrawn, tone: WorkshopNoteTone.warning, padding: notePadding),
        if (_remoteText(l10n, row) case final text?) WorkshopNote(text, padding: notePadding),
      ],
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(title),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 4, bottom: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...notes,
                SheetGroup(
                  margin: const EdgeInsets.symmetric(horizontal: kSheetGutter),
                  children: switch (local) {
                    WorkshopInstalled(:final receipt) => [
                      ListPageRow(
                        title: l10n.workshopInstalledFactKind,
                        value: workshopKindText(l10n, receipt.kind),
                      ),
                      ListPageRow(title: l10n.workshopInstalledFactId, value: receipt.id),
                      ListPageRow(title: l10n.commonVersion, value: receipt.version),
                      ListPageRow(title: l10n.workshopInstalledFactOrigin, value: receipt.origin.host),
                    ],
                    // No trusted receipt: the slot's name is all there is.
                    WorkshopInstallationIssue(:final localId) => [
                      ListPageRow(title: l10n.workshopInstalledFactLocalId, value: localId),
                    ],
                  },
                ),
              ],
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(kSheetGutter, 10, kSheetGutter, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (update != null && !gone)
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: buttonSize),
                    onPressed: () => Navigator.of(context).pop(WorkshopInstalledUpdate(update)),
                    child: Text(
                      l10n.workshopUpdateTo(update.metadata.version),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (row.canUninstall && !gone) ...[
                  if (update != null) const SizedBox(height: 8),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: buttonSize,
                      foregroundColor: colors.danger,
                      side: busy ? null : BorderSide(color: colors.danger.withValues(alpha: 0.5)),
                    ),
                    // One removal at a time; the row shows the one running.
                    onPressed: busy ? null : () => unawaited(_askUninstall(context, row, title)),
                    child: Text(l10n.hubPluginUninstall),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
