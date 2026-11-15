// Native mirror of the official session-log download
// (`dsh-session-log-export`: the session header's "下载 Session 日志" and
// `/export`): the conversation tree as a ZIP, shared or saved to Downloads.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/session_export.dart';
import '../common/list_page_row.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'feature_widgets.dart';
import '../common/brief_notice.dart';

enum _Action { share, save }

class SessionExportPage extends ConsumerStatefulWidget {
  const SessionExportPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<SessionExportPage> createState() => _SessionExportPageState();
}

class _SessionExportPageState extends ConsumerState<SessionExportPage> {
  _Action? _busy;

  Future<void> _run(_Action action) async {
    final l10n = context.l10n;
    if (_busy != null) return;
    setState(() => _busy = action);
    final exporter = ref.read(sessionLogExporterProvider);
    try {
      switch (action) {
        case _Action.share:
          await exporter.share(widget.sessionId);
        case _Action.save:
          final where = await exporter.saveToDownloads(widget.sessionId);
          if (mounted) showBriefNotice(context, l10n.featuresExportSavedTo(where));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(sessionExportErrorText(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Widget? _spinner(_Action action) => _busy == action
      ? const SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round),
        )
      : null;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connected = ref.watch(activeConnectionProvider).value != null;
    final supported = ref.watch(sessionLogExporterProvider).supported;
    final idle = _busy == null;
    return AppPage.list(
      title: l10n.featuresExportTitle,
      subtitle: Text(l10n.featuresExportSubtitle),
      children: [
        if (!connected)
          const FeatureOffline()
        else if (!supported)
          FeatureMessage(
            icon: AppIcons.offline,
            title: l10n.featuresExportUnavailable,
            body: l10n.featuresExportRemoteHint,
          )
        else ...[
          ListPageCard(
            children: [
              ListPageRow(
                icon: AppIcons.share,
                title: l10n.commonShare,
                subtitle: l10n.featuresExportShareHint,
                trailing: _spinner(_Action.share),
                chevron: _busy != _Action.share,
                onTap: idle ? () => _run(_Action.share) : null,
              ),
              ListPageRow(
                icon: AppIcons.download,
                title: wordsForIos ? l10n.iosSaveToFiles : l10n.featuresExportSaveDownloads,
                subtitle: wordsForIos ? l10n.iosFilesFolderHint : l10n.featuresExportDownloadsHint,
                trailing: _spinner(_Action.save),
                chevron: _busy != _Action.save,
                onTap: idle ? () => _run(_Action.save) : null,
              ),
            ],
          ),
          FeatureNote(l10n.featuresExportContents),
        ],
      ],
    );
  }
}
