import 'dart:async';

import 'package:flutter/material.dart';

import '../../companion/companion_memory_embeddings.dart';
import '../../l10n/l10n.dart';

Future<void> showCompanionMemoryModelDialog(BuildContext context, CompanionMemoryEmbeddings embeddings) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _MemoryModelDialog(embeddings: embeddings),
  );
}

class _MemoryModelDialog extends StatefulWidget {
  const _MemoryModelDialog({required this.embeddings});
  final CompanionMemoryEmbeddings embeddings;

  @override
  State<_MemoryModelDialog> createState() => _MemoryModelDialogState();
}

class _MemoryModelDialogState extends State<_MemoryModelDialog> {
  @override
  void initState() {
    super.initState();
    widget.embeddings.addListener(_changed);
    // Inspect/load an existing local model; this never initiates a download.
    unawaited(widget.embeddings.ensureReady().catchError((Object _) => false));
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _download() async {
    try {
      await widget.embeddings.download();
    } catch (_) {
      // The owner exposes a localized status, not native paths or exceptions.
    }
  }

  @override
  void dispose() {
    widget.embeddings.removeListener(_changed);
    // Closing this view leaves an explicitly requested download with its
    // process owner. Cancel stops work before the atomic install commit point.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final material = MaterialLocalizations.of(context);
    final embeddings = widget.embeddings;
    final state = embeddings.status;
    final message = switch (state) {
      CompanionMemoryModelStatus.unavailable => l10n.companionMemorySearchUnavailable,
      CompanionMemoryModelStatus.downloading => l10n.companionMemorySearchDownloading,
      CompanionMemoryModelStatus.ready => l10n.companionMemorySearchReady,
      CompanionMemoryModelStatus.failed => l10n.companionMemorySearchFailed,
      CompanionMemoryModelStatus.notDownloaded => null,
    };
    return AlertDialog(
      title: Text(l10n.companionMemorySearchTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.companionMemorySearchDescription),
          if (message != null) ...[const SizedBox(height: 16), Text(message)],
          if (state == CompanionMemoryModelStatus.downloading) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: embeddings.progress),
          ],
        ],
      ),
      actions: [
        if (state == CompanionMemoryModelStatus.downloading)
          TextButton(
            onPressed: embeddings.canCancelDownload ? embeddings.cancelDownload : null,
            child: Text(material.cancelButtonLabel),
          )
        else if (embeddings.supported && state != CompanionMemoryModelStatus.ready)
          FilledButton(onPressed: _download, child: Text(l10n.companionMemorySearchDownload)),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(material.closeButtonLabel)),
      ],
    );
  }
}
