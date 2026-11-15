// The ways in from the rest of the phone, sent where they
// belong —
//
//   share sheet        a lone `.dshgo` file or a share link → the share-code
//                      importer (as if opened); a hosted conversation link →
//                      its replay; a lone character card → 酒馆; anything
//                      else → 新对话 with the text and attachments in the
//                      composer, not sent
//   launcher shortcut  新对话 / 语音输入 → 新对话 (listening) · a recent
//                      conversation → that conversation, on its host
//   Quick Settings     新对话
//   pet screenshot     新对话 with the image attached, focused and unsent
//   a file opened with the app that no feature claims → 新对话 with it attached
//
// and keeps the launcher's recent conversations current. Bridges:
// lib/links/share_intake.dart, lib/links/launcher_entries.dart; the composer
// side: lib/state/compose_inbox.dart.
//
// Arrivals wait for this widget (the home shell): during the splash or
// onboarding they are held, natively and in the bridges.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../links/app_links.dart';
import '../../links/launcher_entries.dart';
import '../../links/share_intake.dart';
import '../../state/android_features.dart';
import '../../state/attachments.dart';
import '../../state/compose_inbox.dart';
import '../../state/draft_store.dart';
import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import '../common/discard_guard.dart';
import '../tavern/tavern_intake.dart';

/// Draws nothing. Put it once in the home shell's stack, next to [LinkHost].
class SystemEntryHost extends ConsumerStatefulWidget {
  const SystemEntryHost({super.key, this.onReveal});

  /// Brings the chat out from under the sessions drawer (false: at once).
  final ValueChanged<bool>? onReveal;

  @override
  ConsumerState<SystemEntryHost> createState() => _SystemEntryHostState();
}

class _SystemEntryHostState extends ConsumerState<SystemEntryHost> {
  StreamSubscription<IncomingShare>? _shares;
  StreamSubscription<LauncherEntry>? _entries;
  VoidCallback? _offFiles;

  @override
  void initState() {
    super.initState();
    _shares = ref.read(shareIntakeProvider).shares.listen((share) => unawaited(_onShare(share)));
    _entries = ref.read(launcherBridgeProvider).entries.listen((entry) => unawaited(_onEntry(entry)));
    _offFiles = ref.read(linkRouterProvider).registerFileFallback(_onFile);
    ref.listenManual(recentShortcutsProvider, (_, recents) {
      if (recents != null) {
        unawaited(ref.read(launcherBridgeProvider).setRecent(recents));
      }
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    unawaited(_shares?.cancel());
    unawaited(_entries?.cancel());
    _offFiles?.call();
    super.dispose();
  }

  Future<void> _onShare(IncomingShare share) async {
    // A share code goes to its importer, the same way as when it's opened.
    if (share.shareCodeFile case final file?) {
      ref.read(appLinksProvider).add(Uri.file(file.path));
      return;
    }
    if (share.hostedLink case final link?) {
      ref.read(appLinksProvider).add(link);
      return;
    }
    if (share.shareLink case final link?) {
      ref.read(appLinksProvider).add(link.appLink);
      return;
    }
    // A lone character card goes to 酒馆.
    if (share.files case [final file]
        when share.skipped.isEmpty && await isTavernCardFile(File(file.path), file.name)) {
      final ui = ref.read(linkRouterProvider).context ?? (mounted ? context : null);
      if (ui != null && ui.mounted) await openTavernCardFile(ui, ref, File(file.path), file.name);
      return;
    }
    // Read after the answer: shares arriving behind an unanswered 「放弃修改？」
    // wait in the cache, not in memory.
    await _showChat();
    if (!mounted) return ComposeRequest.discardShare(share);
    final request = await ComposeRequest.fromShare(share, heldBytes: _heldDraftBytes);
    if (mounted) ref.read(composeInboxProvider.notifier).push(request);
  }

  /// Bytes the draft this arrival lands in already holds; share loading checks
  /// the message's whole budget before buffering anything.
  int get _heldDraftBytes {
    // iOS shares always merge into the new-chat draft, even when another
    // conversation is selected. Its attachments own the pre-read budget.
    final key = ref.read(operatingSystemProvider) == 'ios' ? 'new' : ref.read(currentSessionProvider) ?? 'new';
    final draft = ref.read(draftStoreProvider).drafts[key];
    return totalAttachmentBytes(draft?.attachments ?? const []);
  }

  Future<void> _onEntry(LauncherEntry entry) async {
    switch (entry) {
      case NewChatEntry(:final voice, :final text):
        // The microphone opens only for an app on screen; the shortcut's
        // intent can arrive a beat before Flutter hears it is resumed.
        if (voice) await _untilResumed();
        if (mounted) await _compose(ComposeRequest(text: text, voice: voice));
      case ScreenshotEntry(:final path):
        final draft = ref.read(draftStoreProvider).drafts['new'];
        // Reuse share intake's validation and cache cleanup; unlike an opened
        // file, this copy belongs only to this pending attachment.
        final request = await ComposeRequest.fromShare(
          IncomingShare(
            files: [SharedFile(path: path, name: path.split('/').last)],
          ),
          heldBytes: totalAttachmentBytes(draft?.attachments ?? const []),
        );
        await _untilResumed();
        if (mounted) await _compose(request);
      case OpenChatEntry(:final host, :final sessionId):
        if (!await _showChat() || !mounted) return;
        final hosts = ref.read(hostsProvider);
        if (host.kind == HostKind.ssh && hosts.loaded && hosts.sshById(host.id) == null) {
          // Its host was removed since the shortcut was made.
          ref.read(composeInboxProvider.notifier).push(ComposeRequest(problems: [appL10n.shellChatGone]));
          return;
        }
        // Always select the host: it also stops a pending restore of the last
        // one from switching away on a cold start (as notification taps do).
        ref.read(activeHostProvider.notifier).select(host);
        ref.read(currentSessionProvider.notifier).select(sessionId);
    }
  }

  static Future<void> _untilResumed() async {
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) return;
    final resumed = Completer<void>();
    final listener = AppLifecycleListener(
      onResume: () {
        if (!resumed.isCompleted) resumed.complete();
      },
    );
    try {
      await resumed.future.timeout(const Duration(seconds: 3), onTimeout: () {});
    } finally {
      listener.dispose();
    }
  }

  /// A file opened with the app that no feature registered for.
  Future<bool> _onFile(Uri uri) async {
    if (uri.scheme != 'file') return false;
    final request = await ComposeRequest.fromFile(uri.toFilePath(), heldBytes: _heldDraftBytes);
    if (!mounted) return false;
    await _compose(request);
    return true;
  }

  /// Queues [request] for the new-chat composer. If the person keeps a page
  /// with unsaved edits open, it still lands there, ready for when they're
  /// back.
  Future<void> _compose(ComposeRequest request) async {
    final revealed = await _showChat();
    if (!mounted) return;
    // Siri dictation needs the visible composer. Keeping an edit page open
    // cancels this voice request; text and files may still wait in its draft.
    if (!revealed && request.voice && ref.read(operatingSystemProvider) == 'ios') return;
    ref.read(composeInboxProvider.notifier).push(request);
  }

  /// Back to the chat: pages and sheets above it closed (unsaved edits only
  /// with the person's say-so), the drawer pushed away. False when they chose
  /// to stay.
  Future<bool> _showChat() async {
    if (!mounted || !await DiscardGuard.confirmLeave(context) || !mounted) {
      return false;
    }
    widget.onReveal?.call(false);
    Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
    return true;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
