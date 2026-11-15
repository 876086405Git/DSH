// 「导出诊断包」: the diagnostics bundle shared or saved
// to Downloads, from the diagnostics page and the engine's failure card.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../diagnostics/diagnostics_export.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../common/brief_notice.dart';

enum _Action { share, save }

/// The step an export is on, as a row subtitle.
String diagnosticsStepText(DiagnosticsStep step) => switch (step) {
  DiagnosticsStep.collecting => appL10n.phoneDiagnosticsCollecting,
  DiagnosticsStep.packing => appL10n.phoneDiagnosticsPacking,
  DiagnosticsStep.sharing => appL10n.phoneDiagnosticsSharing,
  DiagnosticsStep.saving => wordsForIos ? appL10n.iosSavingToFiles : appL10n.phoneDiagnosticsSaving,
};

/// The two ways out for a diagnostics bundle — 「分享诊断包」 and
/// 「存到「下载」」 — as one card of list rows. While one runs, its subtitle
/// says the step and a small ring replaces the chevron; the other waits.
/// [extra] rows join the card below them.
class DiagnosticsExportCard extends ConsumerStatefulWidget {
  const DiagnosticsExportCard({
    super.key,
    this.title,
    this.margin = const EdgeInsets.fromLTRB(16, 0, 16, 0),
    this.extra = const [],
    this.onSaved,
    this.onShared,
  });

  final String? title;
  final EdgeInsetsGeometry margin;
  final List<Widget> extra;

  /// Replaces the 「已存到 …」 toast (the sheet closes first, then toasts).
  final void Function(String where)? onSaved;

  /// Called after the bundle went somewhere through the share sheet.
  final VoidCallback? onShared;

  @override
  ConsumerState<DiagnosticsExportCard> createState() => _DiagnosticsExportCardState();
}

class _DiagnosticsExportCardState extends ConsumerState<DiagnosticsExportCard> {
  _Action? _busy;
  DiagnosticsStep? _step;

  void _toast(String text) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  void _onStep(DiagnosticsStep step) {
    if (mounted) setState(() => _step = step);
  }

  Future<void> _run(_Action action) async {
    if (_busy != null) return;
    setState(() {
      _busy = action;
      _step = DiagnosticsStep.collecting;
    });
    final exporter = ref.read(diagnosticsExporterProvider);
    try {
      switch (action) {
        case _Action.share:
          final sent = await exporter.share(onStep: _onStep);
          if (sent) widget.onShared?.call();
        case _Action.save:
          final where = await exporter.saveToDownloads(onStep: _onStep);
          if (widget.onSaved case final onSaved?) {
            onSaved(where);
          } else if (mounted) {
            showBriefNotice(context, diagnosticsSavedText(where));
          }
      }
    } catch (error) {
      debugPrint('Diagnostics export failed: $error');
      if (mounted) _toast(diagnosticsErrorText(error));
    } finally {
      if (mounted) {
        setState(() {
          _busy = null;
          _step = null;
        });
      }
    }
  }

  Widget? _ring(_Action action) => _busy == action
      ? SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            strokeCap: StrokeCap.round,
            color: DshColors.of(context).textTertiary,
          ),
        )
      : null;

  String _subtitle(_Action action, String idle) =>
      _busy == action && _step != null ? diagnosticsStepText(_step!) : idle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final idle = _busy == null;
    return ListPageCard(
      title: widget.title,
      margin: widget.margin,
      children: [
        ListPageRow(
          icon: AppIcons.share,
          title: l10n.phoneDiagnosticsShare,
          subtitle: _subtitle(_Action.share, l10n.phoneDiagnosticsShareHint),
          trailing: _ring(_Action.share),
          chevron: _busy != _Action.share,
          onTap: idle ? () => unawaited(_run(_Action.share)) : null,
        ),
        ListPageRow(
          icon: AppIcons.download,
          title: wordsForIos ? l10n.iosSaveToFiles : l10n.phoneDiagnosticsSave,
          subtitle: _subtitle(_Action.save, wordsForIos ? l10n.iosFilesFolderHint : l10n.phoneDiagnosticsSaveHint),
          trailing: _ring(_Action.save),
          chevron: _busy != _Action.save,
          onTap: idle ? () => unawaited(_run(_Action.save)) : null,
        ),
        ...widget.extra,
      ],
    );
  }
}

/// What a bundle holds, under the card.
String get diagnosticsBundleNote => appL10n.phoneDiagnosticsNote;

/// 「导出诊断包」 as a sheet (the failure card's way in): the card, then a
/// faint line on what is inside. A save closes the sheet before its toast,
/// so the toast isn't left under the sheet.
Future<void> showDiagnosticsExportSheet(BuildContext context) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  // The export can outlive the sheet (swiped away mid-export): close it only
  // while it is still the top route, and keep the saved notice either way.
  void close(BuildContext sheet) {
    if (sheet.mounted && (ModalRoute.of(sheet)?.isCurrent ?? false)) Navigator.of(sheet).pop();
  }

  return showAppSheet<void>(
    context,
    builder: (sheet) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(context.l10n.phoneDiagnosticsExport),
          DiagnosticsExportCard(
            margin: const EdgeInsets.symmetric(horizontal: kSheetGutter),
            onSaved: (where) {
              close(sheet);
              if (messenger?.mounted ?? false) messenger!.showBriefNotice(diagnosticsSavedText(where));
            },
            onShared: () => close(sheet),
          ),
          const DiagnosticsBundleNote(inset: kSheetGutter + 8),
          const SizedBox(height: 16),
        ],
      ),
    ),
  );
}

/// [diagnosticsBundleNote], faint, on the card's content column ([inset]
/// from the edge: the card's margin plus 8).
class DiagnosticsBundleNote extends StatelessWidget {
  const DiagnosticsBundleNote({super.key, this.inset = 24});

  final double inset;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(inset, 10, inset, 0),
    child: Text(
      diagnosticsBundleNote,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
    ),
  );
}
