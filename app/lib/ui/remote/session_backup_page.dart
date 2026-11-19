import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:dsh_remote/dsh_remote.dart'
    show
        RemoteHostSession,
        RemoteTunnelCarrier,
        RemoteSessionTransfer,
        SessionTransferCancelledException,
        SessionImportOutcomeUnknownException,
        RemoteRpcException,
        SessionImportResult,
        Workspace,
        SessionSummary;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/relay/dsh_remote_backend.dart';
import '../../remote/session_backup/backup_store.dart';
import '../../state/hosts_state.dart';
import '../../state/connection_state.dart' show hostNameProvider;
import '../../state/read_list_identity.dart';
import '../../state/sessions_state.dart';
import '../../state/session_backup_state.dart';
import '../../state/workspaces_state.dart';
import '../common/app_dialog.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';

class SessionBackupPage extends ConsumerStatefulWidget {
  const SessionBackupPage({super.key});

  @override
  ConsumerState<SessionBackupPage> createState() => _SessionBackupPageState();
}

class _SessionBackupPageState extends ConsumerState<SessionBackupPage> {
  String? _workspaceId;
  String _sessionId = '*';
  bool _busy = false;
  bool _cancelled = false;
  bool _committing = false;
  String? _message;
  String? _hostKey;

  Future<BackupPeer> _peer() async {
    final selected = ref.read(activeHostProvider);
    final backend = ref.read(relayBackendProvider);
    final host = ref.read(relayAccountProvider).value?.hostById(selected.id);
    if (backend is! DshRemoteRelayBackend || selected.kind != HostKind.relay || host?.fingerprint == null) {
      throw StateError('BACKUP_HOST_UNAVAILABLE');
    }
    final user = await backend.account.currentUser();
    if (user == null) throw StateError('BACKUP_HOST_UNAVAILABLE');
    return BackupPeer(
      server: user.serverUrl.toString(),
      hostId: host!.id,
      hostName: host.name,
      fingerprint: host.fingerprint!,
      deviceId: user.deviceId,
    );
  }

  bool _stopped(RemoteHostSession session) {
    if (_cancelled || !mounted || session.isClosed) return true;
    final carrier = ref.read(readListLiveConnectionProvider)?.client.carrier;
    return carrier is! RemoteTunnelCarrier || !identical(carrier.session, session);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _cancelled = false;
      _message = null;
    });
    try {
      await action();
    } on SessionTransferCancelledException {
      if (mounted) _message = context.l10n.backupCancelled;
    } on SessionImportOutcomeUnknownException {
      if (mounted) _message = context.l10n.backupUnknown;
    } catch (error) {
      final code = switch (error) {
        RemoteRpcException() => error.code,
        FileSystemException() => 'BACKUP_STORAGE_ERROR',
        StateError() => error.message.toString(),
        _ => 'BACKUP_UNREADABLE',
      };
      if (mounted) _message = context.l10n.backupFailed(code);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _committing = false;
        });
      }
    }
  }

  Future<bool> _confirm(String text) async =>
      await showAppDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l10n.commonCancel)),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(context.l10n.commonConfirm)),
          ],
        ),
      ) ??
      false;

  Future<void> _backup(RemoteHostSession session, Workspace workspace, List<SessionSummary> summaries) =>
      _run(() async {
        final peer = await _peer();
        if (!mounted || _stopped(session)) throw const SessionTransferCancelledException();
        final store = await ref.read(sessionBackupStoreProvider.future);
        final transfer = RemoteSessionTransfer(session);
        final export = await transfer.openExport(
          workspaceId: _sessionId == '*' ? workspace.workspaceId : null,
          sessionId: _sessionId == '*' ? null : _sessionId,
        );
        var count = 0;
        try {
          for (final entry in export.sessions) {
            final data = await transfer.readSession(export, entry, isCancelled: () => _stopped(session));
            final title = summaries.where((e) => e.sessionId == entry.sessionId).firstOrNull?.title;
            await store.add(
              SessionBackup(
                id: newBackupId(),
                source: peer,
                workspaceId: workspace.workspaceId,
                sessionId: entry.sessionId,
                title: title ?? entry.sessionId,
                throughSeq: entry.throughSeq,
                createdAt: DateTime.now(),
                totalBytes: data.totalBytes,
                sha256: data.sha256,
              ),
              data,
            );
            count++;
            if (mounted) setState(() => _message = context.l10n.backupSaved(count));
          }
          if (mounted) _message = context.l10n.backupSaved(count);
        } finally {
          // Closing a read-only export cannot invalidate already verified backups.
          try {
            await transfer.closeExport(export);
          } on RemoteRpcException {
            if (mounted) _message = context.l10n.backupSavedCloseFailed(count);
          }
        }
      });

  Future<void> _restore(
    RemoteHostSession session,
    Workspace workspace,
    SessionBackup backup,
    SessionBackupStore store,
  ) => _run(() async {
    final target = await _peer();
    if (!mounted || _stopped(session)) throw const SessionTransferCancelledException();
    if (store.restores.any(
      (e) => e.backupId == backup.id && e.pending && e.target.hostIdentity == target.hostIdentity,
    )) {
      _message = context.l10n.backupUnknown;
      return;
    }
    if (!await _confirm(context.l10n.backupRestoreConfirm(backup.title, workspace.title))) return;
    if (!mounted || _stopped(session)) throw const SessionTransferCancelledException();
    final data = await store.read(backup);
    final pending = BackupRestore(
      backupId: backup.id,
      target: target,
      workspaceId: workspace.workspaceId,
      batchId: newBackupId(),
      requestId: newBackupId(),
    );
    var recorded = false;
    SessionImportResult result;
    try {
      result = await RemoteSessionTransfer(session).restore(
        data,
        workspaceId: workspace.workspaceId,
        batchId: pending.batchId,
        sourceSessionId: backup.sessionId,
        requestId: pending.requestId,
        beforeCommit: () async {
          await store.saveRestore(pending);
          recorded = true;
          if (mounted) setState(() => _committing = true);
        },
        isCancelled: () => _stopped(session),
      );
    } on SessionImportOutcomeUnknownException {
      rethrow;
    } catch (_) {
      if (recorded) await store.forgetRestore(pending);
      rethrow;
    }
    await _recordResult(pending, result, store);
    if (mounted && !_stopped(session)) unawaited(ref.read(sessionsProvider.notifier).refresh());
  });

  Future<void> _check(RemoteHostSession session, BackupRestore pending, SessionBackupStore store) => _run(() async {
    final target = await _peer();
    if (!mounted || _stopped(session)) throw const SessionTransferCancelledException();
    if (target.identity != pending.target.identity) {
      _message = context.l10n.backupOriginalDevice;
      return;
    }
    final result = await RemoteSessionTransfer(session).status(batchId: pending.batchId, requestId: pending.requestId);
    if (result == null) {
      if (mounted) _message = context.l10n.backupUnknown;
      return;
    }
    await _recordResult(pending, result, store);
  });

  Future<void> _recordResult(BackupRestore pending, SessionImportResult result, SessionBackupStore store) async {
    if (mounted) {
      setState(
        () => _message = result.workspaceAttached
            ? context.l10n.backupRestored(result.sessionId)
            : context.l10n.backupRestoredDetached(result.sessionId),
      );
    }
    try {
      await store.saveRestore(pending.completed(result));
    } catch (_) {
      // A local storage failure must not erase a known successful Host result.
      if (mounted) setState(() => _message = '$_message\n${context.l10n.backupRecordFailed}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final selected = ref.watch(activeHostProvider);
    final session = ref.watch(sessionBackupSessionProvider).value;
    final storeAsync = ref.watch(sessionBackupStoreProvider);
    final store = storeAsync.value;
    final registry = ref.watch(workspacesProvider);
    final summaries = ref.watch(sessionsProvider).value ?? const <SessionSummary>[];
    if (_hostKey != selected.encode()) {
      _hostKey = selected.encode();
      _workspaceId = null;
      _sessionId = '*';
    }
    final workspaces = registry.ready ? registry.workspaces : const <Workspace>[];
    final workspace = workspaces.where((w) => w.workspaceId == _workspaceId).firstOrNull ?? workspaces.firstOrNull;
    final sessions = summaries
        .where(
          (s) =>
              !s.isSubagent &&
              s.parentSessionId == null &&
              !s.blank &&
              (workspace?.sessionIds.contains(s.sessionId) ?? false),
        )
        .toList();
    final sessionId = sessions.any((s) => s.sessionId == _sessionId) ? _sessionId : '*';
    final transfer = session == null ? null : RemoteSessionTransfer(session);
    final pending = store?.restores.where((e) => e.pending).toList() ?? const <BackupRestore>[];
    return PopScope(
      canPop: !_busy,
      child: AppPage.list(
        title: l10n.backupTitle,
        subtitle: Text(l10n.backupHint),
        children: [
          if (storeAsync.isLoading) const LinearProgressIndicator(),
          if (storeAsync.hasError)
            ListTile(
              title: Text(l10n.backupStorageFailed),
              trailing: TextButton(
                onPressed: () => ref.invalidate(sessionBackupStoreProvider),
                child: Text(l10n.commonRetry),
              ),
            ),
          SettingsSection(
            title: ref.watch(hostNameProvider(selected)) ?? l10n.commonRemoteHost,
            children: [
              if (session == null) ListTile(title: Text(l10n.backupConnectHost)),
              if (workspace == null && session != null) ListTile(title: Text(l10n.backupNoWorkspace)),
              if (workspace != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: workspace.workspaceId,
                    items: [
                      for (final w in workspaces)
                        DropdownMenuItem(
                          value: w.workspaceId,
                          child: Text(w.title, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(() {
                            _workspaceId = value;
                            _sessionId = '*';
                          }),
                  ),
                ),
              if (transfer?.canExport == true && workspace != null) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: sessionId,
                    items: [
                      DropdownMenuItem(value: '*', child: Text(l10n.backupWorkspace)),
                      for (final s in sessions)
                        DropdownMenuItem(
                          value: s.sessionId,
                          child: Text(s.title ?? s.sessionId, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: _busy ? null : (value) => setState(() => _sessionId = value ?? '*'),
                  ),
                ),
                SettingsTile(
                  icon: AppIcons.save,
                  title: l10n.backupToPhone,
                  onTap: _busy || store == null
                      ? null
                      : () {
                          _sessionId = sessionId;
                          unawaited(_backup(session!, workspace, summaries));
                        },
                ),
              ],
              if (session != null && transfer?.canExport != true) ListTile(title: Text(l10n.backupExportUnsupported)),
            ],
          ),
          if (_busy || _message != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_busy) const LinearProgressIndicator(),
                  if (_message != null) SelectableText(_message!),
                  if (_busy)
                    TextButton(
                      onPressed: _committing ? null : () => setState(() => _cancelled = true),
                      child: Text(l10n.commonCancel),
                    ),
                ],
              ),
            ),
          if (pending.isNotEmpty)
            SettingsSection(
              title: l10n.backupPending,
              children: [
                for (final p in pending)
                  ListTile(
                    title: Text(p.target.hostName),
                    subtitle: Text(l10n.backupUnknown),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: _busy || session == null ? null : () => unawaited(_check(session, p, store!)),
                          child: Text(l10n.backupCheck),
                        ),
                        IconButton(
                          tooltip: l10n.backupAcknowledge,
                          icon: const Icon(AppIcons.done),
                          onPressed: _busy
                              ? null
                              : () => unawaited(
                                  _run(() async {
                                    if (await _confirm(l10n.backupAcknowledgeConfirm)) await store!.forgetRestore(p);
                                  }),
                                ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          SettingsSection(
            title: l10n.backupOnPhone,
            children: [
              if (store != null && store.backups.isEmpty) ListTile(title: Text(l10n.backupEmpty)),
              if (store != null)
                for (final b in store.backups)
                  ListTile(
                    title: Text(b.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: SelectableText(
                      [
                        '${b.source.hostName} · ${MaterialLocalizations.of(context).formatShortDate(b.createdAt.toLocal())}',
                        for (final r in store.restores.where((r) => r.backupId == b.id && !r.pending).take(1))
                          r.workspaceAttached == true
                              ? l10n.backupRestored(r.sessionId!)
                              : l10n.backupRestoredDetached(r.sessionId!),
                      ].join('\n'),
                    ),
                    trailing: PopupMenuButton<String>(
                      enabled: !_busy,
                      onSelected: (value) {
                        if (value == 'restore' && session != null && workspace != null) {
                          unawaited(_restore(session, workspace, b, store));
                        }
                        if (value == 'delete') {
                          unawaited(
                            _run(() async {
                              if (await _confirm(l10n.backupDeleteConfirm)) await store.delete(b);
                            }),
                          );
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'restore',
                          enabled: transfer?.canImport == true && workspace != null,
                          child: Text(l10n.backupRestore),
                        ),
                        const PopupMenuDivider(),
                        PopupMenuItem(value: 'delete', child: Text(l10n.commonDelete)),
                      ],
                    ),
                    onTap: _busy || transfer?.canImport != true || workspace == null
                        ? null
                        : () => unawaited(_restore(session!, workspace, b, store)),
                  ),
            ],
          ),
          if (store != null && store.backups.isNotEmpty && session != null && transfer?.canImport != true)
            Padding(padding: const EdgeInsets.all(16), child: Text(l10n.backupImportUnsupported)),
        ],
      ),
    );
  }
}
