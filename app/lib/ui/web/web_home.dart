// 网页模式's home — the active host's official DSH Web, full screen, with the
// native handle in its back button's seat (web_handle.dart) and the app's
// system integration underneath:
//
//   notifications      the alert controller and its taps (ChatAlertHost)
//                      select the host and the conversation; the page
//                      follows the current conversation, so it opens there
//   launcher shortcut  新对话 → a new conversation in the page; a recent
//                      conversation → that one, on its host
//   share sheet        text and files → a new conversation's composer, as a
//                      paste; what the page can't take: the text to the
//                      clipboard and one short line. Share codes and hosted
//                      conversation links still open their native pages.
//   links              LinkHost / ForumLinkHost, as on the native home
//   the floating pet   its states and its 「宠物设置」, as on the native home
//
// The page reports the conversation on screen back to the app
// (dsh_web_state.js), so the native interface, a cold start and the launcher's
// recent conversations agree with it.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../links/app_links.dart';
import '../../links/launcher_entries.dart';
import '../../links/share_intake.dart';
import '../../pets/overlay_channel.dart' show petOverlayChannelProvider;
import '../../pets/pet_overlay_bridge.dart';
import '../../state/android_features.dart';
import '../../state/compose_inbox.dart';
import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import '../../state/settings_state.dart';
import '../../state/ui_mode_state.dart';
import '../common/discard_guard.dart';
import '../common/empty_view.dart';
import '../forum/forum_link_host.dart';
import '../notify/chat_alert_host.dart';
import '../pets/pet_settings_page.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'dsh_web_launcher.dart';
import 'local_web_screen.dart';
import 'web_handle.dart';
import 'web_target.dart';
import 'web_view_page.dart';

/// Most a share may bring into the page's composer in one paste (files are
/// handed over as base64 text).
const maxWebComposeBytes = 16 * 1024 * 1024;

/// 网页模式's home page.
class WebHome extends ConsumerStatefulWidget {
  const WebHome({super.key, this.initial});

  /// Where to land first (a switch from the native interface: its
  /// conversation). Null: the page restores its own last conversation.
  final DshWebTarget? initial;

  @override
  ConsumerState<WebHome> createState() => _WebHomeState();
}

class _WebHomeState extends ConsumerState<WebHome> {
  final _link = DshWebLink();

  /// The conversation the page last reported (or was sent to).
  String? _webSession;

  @override
  void initState() {
    super.initState();
    if (widget.initial case final target?) {
      _webSession = target.sessionId;
      unawaited(_link.open(target));
    }
    // Something chose a conversation (a notification, a recent shortcut, the
    // banner): the page goes there, once it has been rebuilt for the host.
    ref.listenManual(currentSessionProvider, (_, next) {
      if (next == null || next == _webSession) return;
      _webSession = next;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_link.open(DshWebTarget(sessionId: next)));
      });
    });
    ref.listenManual(webOpenProvider, (_, request) {
      if (request != null) _take(request);
    }, fireImmediately: true);
  }

  void _onSession(String? id) {
    if (id == _webSession) return;
    _webSession = id;
    ref.read(currentSessionProvider.notifier).select(id);
  }

  void _take(WebOpenRequest request) {
    ref.read(webOpenProvider.notifier).taken(request);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
      unawaited(_open(request));
    });
  }

  Future<void> _open(WebOpenRequest request) async {
    await _link.open(request.target);
    final compose = request.compose;
    if (compose == null) return;
    final problems = [...compose.problems];
    final files = <({String name, String? type, String base64})>[];
    var bytes = 0;
    for (final a in compose.attachments) {
      bytes += a.bytes.length;
      if (bytes > maxWebComposeBytes) {
        problems.add(appL10n.webAttachmentTooLarge);
        break;
      }
      files.add((name: a.name, type: a.mediaType, base64: base64Encode(a.bytes)));
    }
    final text = compose.text.trim();
    if (text.isEmpty && files.isEmpty) return _tell(problems);
    final result = await _link.compose(text, files: files);
    if (text.isNotEmpty && !result.text) {
      await Clipboard.setData(ClipboardData(text: text));
      problems.insert(0, appL10n.webTextCopied);
    }
    if (files.length > result.files) problems.add(appL10n.webAttachmentFailed);
    _tell(problems);
  }

  void _tell(List<String> problems) {
    if (problems.isEmpty || !mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(problems.first)));
  }

  /// 切回原生界面: the native home opens on the conversation the page shows.
  Future<void> _toNative() async {
    final id = _webSession;
    if (id != null && ref.read(currentSessionProvider) != id) {
      ref.read(currentSessionProvider.notifier).select(id);
    }
    await ref.read(uiModeProvider.notifier).set(UiMode.native);
  }

  Widget _handle(double size) => WebHandleButton(size: size, onNative: _toNative);

  @override
  Widget build(BuildContext context) {
    final access = ref.watch(dshWebAccessProvider);
    final phoneLayout = ref.watch(settingsProvider.select((s) => s.webPhoneLayout));
    final Widget page = switch (access) {
      LocalDshWeb() => LocalWebScreen(handle: _handle, link: _link, onSession: _onSession),
      SshDshWeb(:final url, :final hostName) => WebViewPage(
        // A new forward (reconnect) or layout switch: a new page.
        key: ValueKey((url, phoneLayout)),
        url: url,
        title: context.l10n.webTitle,
        subtitle: hostName,
        externalDisabledReason: context.l10n.webSshAppOnly,
        // Android suspends the page in the background and its socket drops.
        reloadAfterBackground: const Duration(seconds: 60),
        dshWeb: true,
        phoneLayout: phoneLayout,
        leading: _handle,
        root: true,
        link: _link,
        onSession: _onSession,
      ),
      NoDshWeb(:final reason) => _NoWeb(reason: reason, handle: _handle),
    };
    return ChatAlertHost(
      child: Stack(
        fit: StackFit.expand,
        children: [page, const LinkHost(), const WebEntryHost(), const ForumLinkHost(), const _PetHost()],
      ),
    );
  }
}

/// The floating pet outside the app, as on the native home: it hears every
/// pet state, and its menu's 「宠物设置」 opens the settings page here.
class _PetHost extends ConsumerStatefulWidget {
  const _PetHost();

  @override
  ConsumerState<_PetHost> createState() => _PetHostState();
}

class _PetHostState extends ConsumerState<_PetHost> {
  StreamSubscription<void>? _settings;

  @override
  void initState() {
    super.initState();
    _settings = ref.read(petOverlayChannelProvider).settingsRequests.listen((_) {
      if (mounted) unawaited(PetSettingsPage.open(context));
    });
  }

  @override
  void dispose() {
    unawaited(_settings?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<void>(petOverlayBridgeProvider, (_, _) {});
    return const SizedBox.shrink();
  }
}

/// The active host has no web page the app can reach (a DSH Remote host):
/// say so, with the handle's ways out at hand.
class _NoWeb extends StatelessWidget {
  const _NoWeb({required this.reason, required this.handle});

  final String reason;
  final Widget Function(double size) handle;

  @override
  Widget build(BuildContext context) {
    return AppPage(
      title: context.l10n.commonWeb,
      showLargeTitle: false,
      actions: [handle(44)],
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 80),
            child: Center(
              child: EmptyView(icon: AppIcons.webApp, title: context.l10n.webHostUnavailable, message: reason),
            ),
          ),
        ),
      ],
    );
  }
}

/// The ways in from the rest of the phone while the web page is the home
/// (网页模式's counterpart of SystemEntryHost). Draws nothing.
class WebEntryHost extends ConsumerStatefulWidget {
  const WebEntryHost({super.key});

  @override
  ConsumerState<WebEntryHost> createState() => _WebEntryHostState();
}

class _WebEntryHostState extends ConsumerState<WebEntryHost> {
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
      if (recents != null) unawaited(ref.read(launcherBridgeProvider).setRecent(recents));
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
    // Share codes and links open their native pages, as on the native home.
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
    // Read after the answer, as on the native home.
    if (!mounted || !await DiscardGuard.confirmLeave(context) || !mounted) {
      return ComposeRequest.discardShare(share);
    }
    final request = await ComposeRequest.fromShare(share, maxBytes: maxWebComposeBytes);
    if (mounted) _open(request);
  }

  Future<void> _onEntry(LauncherEntry entry) async {
    switch (entry) {
      case NewChatEntry(:final text):
        // Dictation is the native composer's; Siri's supplied text still
        // belongs in the web composer, without sending it.
        if (mounted) {
          final request = ref.read(operatingSystemProvider) == 'ios' && text.isNotEmpty
              ? ComposeRequest(text: text)
              : null;
          await _compose(request);
        }
      case ScreenshotEntry(:final path):
        await _onShare(
          IncomingShare(
            files: [SharedFile(path: path, name: path.split('/').last)],
          ),
        );
      case OpenChatEntry(:final host, :final sessionId):
        if (!mounted || !await DiscardGuard.confirmLeave(context) || !mounted) return;
        final hosts = ref.read(hostsProvider);
        if (host.kind == HostKind.ssh && hosts.loaded && hosts.sshById(host.id) == null) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l10n.webChatGone)));
          return;
        }
        Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
        // The page follows the current conversation (WebHome).
        ref.read(activeHostProvider.notifier).select(host);
        ref.read(currentSessionProvider.notifier).select(sessionId);
    }
  }

  Future<bool> _onFile(Uri uri) async {
    if (uri.scheme != 'file') return false;
    final request = await ComposeRequest.fromFile(uri.toFilePath(), maxBytes: maxWebComposeBytes);
    if (!mounted) return false;
    await _compose(request);
    return true;
  }

  /// A new conversation in the page, with [request]'s text and files in its
  /// composer.
  Future<void> _compose(ComposeRequest? request) async {
    if (!mounted || !await DiscardGuard.confirmLeave(context) || !mounted) return;
    _open(request);
  }

  void _open(ComposeRequest? request) =>
      ref.read(webOpenProvider.notifier).request(const DshWebTarget(newSession: true), compose: request);

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
