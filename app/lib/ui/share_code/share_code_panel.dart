// The second half of every 「分享…」 sheet — the code made, then its ways out in
// one row of round keys, as on the share panel: 复制链接 · 二维码 · (图片) · 分享,
// and for a profile 存为文件. A plugin's link always fits, so it has no file key;
// a profile too large for a link goes out as a `.dshgo` file, or as a Gist link
// when a GitHub token is given.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/artifacts.dart' show saveWindowDismissed;
import '../../share_code/share_code_state.dart';
import '../../share_code/share_codec.dart';
import '../../share_code/share_link.dart';
import '../../share_code/share_models.dart';
import '../../share_code/share_net.dart';
import '../../usage/usage_stats.dart';
import '../common/app_sheet.dart';
import '../common/discard_guard.dart';
import '../common/expand_reveal.dart';
import '../common/sheet_navigator.dart';
import '../share/qr_code.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'share_code_widgets.dart';
import 'share_out.dart';

/// The link (or file) for [payload], and the ways out.
class ShareCodePanel extends ConsumerStatefulWidget {
  const ShareCodePanel({super.key, required this.payload, required this.title, this.onImage, this.webLink});

  final SharePayload payload;

  /// What the link is called in the share text and under the QR code.
  final String title;

  /// 「图片」: a picture card of it (a plugin the market knows).
  final VoidCallback? onImage;

  /// A link of its own (a plugin's page in the official market) copied,
  /// shown and shared instead of the share code's.
  final String? webLink;

  @override
  ConsumerState<ShareCodePanel> createState() => _ShareCodePanelState();
}

enum _Done { copied, saved }

class _ShareCodePanelState extends ConsumerState<ShareCodePanel> {
  late String _code;
  ShareLink? _link;
  bool _fits = true;
  _Done? _done;
  bool _sharing = false;
  bool _saving = false;
  String? _error;
  Timer? _doneReset;

  @override
  void initState() {
    super.initState();
    _encode();
  }

  @override
  void didUpdateWidget(ShareCodePanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.payload, widget.payload)) _encode();
  }

  void _encode() {
    _code = encodeShareCode(widget.payload);
    final inline = ShareLink.inline(widget.payload.kind, _code);
    _fits = widget.webLink != null || inline.webLink.length <= maxInlineLinkChars;
    _link = _fits ? inline : null;
  }

  @override
  void dispose() {
    _doneReset?.cancel();
    super.dispose();
  }

  void _flash(_Done done) {
    HapticFeedback.lightImpact();
    setState(() {
      _done = done;
      _error = null;
    });
    _doneReset?.cancel();
    _doneReset = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _done = null);
    });
  }

  /// The link that goes out: [ShareCodePanel.webLink], else the code's.
  String? get _web => widget.webLink ?? _link?.webLink;

  String get _shareText {
    final what = widget.payload is PluginShare ? appL10n.pluginsPluginShareTitle : appL10n.pluginsProfileTitle;
    return '「${widget.title}」· $what\n${_web!}';
  }

  String get _fileName => ref
      .read(shareOutProvider)
      .fileName(
        profile: widget.payload is ProfileShare,
        name: switch (widget.payload) {
          PluginShare(:final plugin) => plugin.name,
          _ => null,
        },
      );

  Future<void> _copy() async {
    final link = _web;
    if (link == null) return;
    await ref.read(shareOutProvider).copy(link);
    if (mounted) _flash(_Done.copied);
  }

  void _qr() {
    final link = _web;
    if (link == null) return;
    final sheet = SheetNavigator.maybeOf(context);
    final page = ShareQrPage(link: link, title: widget.title);
    if (sheet != null) {
      sheet.push((_) => page);
    } else {
      unawaited(
        showAppSheet<void>(context, dismissal: SheetDismissal.drag, isScrollControlled: true, builder: (_) => page),
      );
    }
  }

  /// It went out (usage statistics).
  void _shared() {
    if (mounted) ref.read(usageStatsProvider.notifier).count(UsageCount.share);
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() {
      _sharing = true;
      _error = null;
    });
    final out = ref.read(shareOutProvider);
    String? error;
    try {
      if (_web != null) {
        await out.shareText(_shareText);
      } else {
        final file = await out.write(_fileName, encodeShareFile(widget.payload, code: _code));
        await out.shareFile(file);
      }
      _shared();
    } catch (_) {
      error = appL10n.pluginsShareSheetOpenFailed;
    }
    if (mounted) {
      setState(() {
        _sharing = false;
        _error = error;
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final out = ref.read(shareOutProvider);
    String? error;
    try {
      await out.save(_fileName, encodeShareFile(widget.payload, code: _code));
      _shared();
    } on PlatformException catch (e) {
      if (saveWindowDismissed(e)) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      error = e.code == 'permission' ? appL10n.pluginsSavePermissionDenied : appL10n.commonSaveFailedRetry;
    } catch (_) {
      error = appL10n.commonSaveFailedRetry;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = error;
    });
    if (error == null) _flash(_Done.saved);
  }

  void _gistMade(String id) {
    setState(() => _link = ShareLink.gist(id, _code.split('.').last));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final hasLink = _web != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_fits) ...[
          _GistLink(
            fileName: _fileName,
            fileText: () => encodeShareFile(widget.payload, code: _code),
            made: hasLink,
            onMade: _gistMade,
          ),
          const SizedBox(height: 20),
        ],
        ShareActionRow(
          actions: [
            ShareAction(
              key: const ValueKey('share-code-copy'),
              icon: AppIcons.link,
              label: _done == _Done.copied ? l10n.commonCopied : l10n.commonCopyLink,
              done: _done == _Done.copied,
              onTap: hasLink ? _copy : null,
            ),
            ShareAction(
              key: const ValueKey('share-code-qr'),
              icon: AppIcons.qrCode,
              label: l10n.pluginsQrCode,
              onTap: hasLink ? _qr : null,
            ),
            if (widget.onImage case final onImage?)
              ShareAction(
                key: const ValueKey('share-code-image'),
                icon: AppIcons.shareImage,
                label: l10n.viewShareAsImage,
                onTap: onImage,
              ),
            ShareAction(
              key: const ValueKey('share-code-share'),
              icon: AppIcons.share,
              label: l10n.commonShare,
              busy: _sharing,
              onTap: _share,
            ),
            if (widget.payload is! PluginShare)
              ShareAction(
                key: const ValueKey('share-code-save'),
                icon: AppIcons.download,
                label: _done == _Done.saved ? l10n.commonSaved : l10n.pluginsSaveAsFile,
                done: _done == _Done.saved,
                busy: _saving,
                onTap: _save,
              ),
          ],
        ),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              error,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.danger),
            ),
          ),
      ],
    );
  }
}

/// For a profile too large to inline: 「生成链接」 through a secret Gist with
/// the person's GitHub token (kept for this app session only).
class _GistLink extends ConsumerStatefulWidget {
  const _GistLink({required this.fileName, required this.fileText, required this.made, required this.onMade});

  final String fileName;
  final String Function() fileText;
  final bool made;
  final ValueChanged<String> onMade;

  @override
  ConsumerState<_GistLink> createState() => _GistLinkState();
}

class _GistLinkState extends ConsumerState<_GistLink> {
  /// The token kept from an earlier Gist this app session: not lost on close.
  late final String _kept = ref.read(gistTokenProvider) ?? '';
  late final TextEditingController _token = TextEditingController(text: _kept);
  bool _open = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  /// A token typed into the open field and not yet used: closing the sheet
  /// (drag, scrim, back) asks first. Empty, folded or used, it closes as is.
  bool _unsaved() {
    if (!_open || widget.made) return false;
    final token = _token.text.trim();
    return token.isNotEmpty && token != _kept;
  }

  Future<void> _make() async {
    final token = _token.text.trim();
    if (token.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await ref
          .read(shareNetProvider)
          .createGist(token: token, fileName: widget.fileName, content: widget.fileText());
      ref.read(gistTokenProvider.notifier).set(token);
      if (!mounted) return;
      setState(() => _busy = false);
      widget.onMade(id);
    } on GistException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = appL10n.pluginsGistCreateFailed;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final scheme = theme.colorScheme;
    final duration = AppMotion.of(context, AppMotion.standard);
    return DiscardGuard(
      listenable: _token,
      isDirty: _unsaved,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                widget.made ? AppIcons.success : AppIcons.document,
                size: 18,
                color: widget.made ? colors.success : colors.textTertiary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.made ? l10n.pluginsGistLinkReady : l10n.pluginsTooLargeShareFile,
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              if (!widget.made)
                TextButton(
                  key: const ValueKey('share-code-gist'),
                  // Text flush with the gutter, like the field below it.
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 44),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => setState(() => _open = !_open),
                  child: Text(_open ? l10n.commonCollapse : l10n.pluginsGenerateLink),
                ),
            ],
          ),
          ExpandReveal(
            open: _open && !widget.made,
            duration: duration,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const ValueKey('share-code-gist-token'),
                    controller: _token,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: l10n.pluginsGitHubToken,
                      hintText: l10n.pluginsGistPermissionNeeded,
                      errorText: _error,
                    ),
                    onSubmitted: (_) => _make(),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    key: const ValueKey('share-code-gist-make'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                    onPressed: _busy ? null : _make,
                    child: _busy
                        ? SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              strokeCap: StrokeCap.round,
                              color: scheme.onSurfaceVariant,
                            ),
                          )
                        : Text(l10n.pluginsGenerateGistLink),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The QR code of a share link, large, on a white card (scans in both themes).
class ShareQrPage extends StatelessWidget {
  const ShareQrPage({super.key, required this.link, required this.title});

  final String link;
  final String title;

  /// Side of the code; the card adds [padding] around it.
  static const size = 248.0;
  static const padding = 16.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final ecc = link.length > 600 ? QrEcc.low : QrEcc.medium;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(l10n.pluginsQrCode),
          const SizedBox(height: 8),
          Center(
            child: DecoratedBox(
              key: const ValueKey('share-qr-card'),
              decoration: ShapeDecoration(
                color: Colors.white,
                shape: Squircle.border(
                  AppShape.lg,
                  side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6), width: 0.5),
                ),
                shadows: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: theme.brightness == Brightness.dark ? 0.24 : 0.05),
                    blurRadius: 24,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(padding),
                child: QrCodeView(
                  data: link,
                  size: size,
                  ecc: ecc,
                  quietZone: 2,
                  semanticLabel: l10n.pluginsShareQrCode,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kSheetGutter),
            child: Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 28),
        ],
      ),
    );
  }
}
