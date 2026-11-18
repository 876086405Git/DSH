// Share codes (lib/share_code) inside forum posts. A post carries the
// landing-page link (`<shareLandingUrl>#p=…`), which works in a browser too
// (the forum's theme component draws it as an install card); in the app it
// becomes a card whose 「安装」 hands the link to the share-code feature through
// the app-link router (`dshgo://share/…`), the same path a link tapped in
// WeChat takes.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../clipboard/paste_reader.dart';
import '../links/app_links.dart' show linkRouterProvider;
import '../state/android_features.dart';
import '../l10n/l10n.dart';
import '../share_code/share_codec.dart';
import '../share_code/share_link.dart';
import '../share_code/share_models.dart';

/// What an install card shows for a share link.
class ForumShareSummary {
  const ForumShareSummary({required this.kind, required this.title, this.detail});

  final ShareKind kind;
  final String title;

  /// `3 个插件 · 2 个技能`, the author, … (null when nothing to add).
  final String? detail;

  /// 「插件」 / 「配置」.
  String get kindLabel => kind == ShareKind.plugin ? appL10n.statePluginLabel : appL10n.stateConfigLabel;
}

/// Reads what it can from [link] without the network: inline codes decode
/// locally; a Gist link only says it is a configuration.
ForumShareSummary summarizeShareLink(ShareLink link, {String? label}) {
  if (link.isGist) return ForumShareSummary(kind: ShareKind.profile, title: label ?? appL10n.stateConfigShare);
  try {
    final payload = decodeShareCode(link.code!);
    switch (payload) {
      case PluginShare(:final plugin):
        return ForumShareSummary(
          kind: ShareKind.plugin,
          title: plugin.displayTitle,
          detail: [?plugin.author, ?plugin.summary].where((s) => s.trim().isNotEmpty).join(' · ').ifEmpty(),
        );
      case ProfileShare():
        final parts = [
          if (payload.plugins.isNotEmpty) appL10n.stateSharePluginCount(payload.plugins.length),
          if (payload.skills.isNotEmpty) appL10n.stateShareSkillCount(payload.skills.length),
          if (payload.settings.isNotEmpty) appL10n.stateShareSettingCount(payload.settings.length),
        ];
        return ForumShareSummary(
          kind: ShareKind.profile,
          title: (payload.name?.trim().isNotEmpty ?? false)
              ? payload.name!.trim()
              : (label ?? appL10n.stateConfigShare),
          detail: parts.isEmpty ? null : parts.join(' · '),
        );
    }
  } catch (_) {
    return ForumShareSummary(kind: link.kind ?? ShareKind.plugin, title: label ?? appL10n.stateShareCode);
  }
}

extension on String {
  String? ifEmpty() => trim().isEmpty ? null : this;
}

/// The Markdown a post gets for [link]: a titled link on its own line (a
/// custom title keeps Discourse from turning it into a onebox).
String shareLinkMarkdown(ShareLink link) {
  final summary = summarizeShareLink(link);
  final title = '${summary.kindLabel}：${summary.title}'.replaceAll(RegExp(r'[\[\]]'), '');
  return '[$title](${link.webLink})';
}

/// 「安装」 on a card: hands the link to whoever imports share codes.
final forumShareInstallerProvider = Provider<Future<bool> Function(ShareLink link)>((ref) {
  return (link) => ref.read(linkRouterProvider).open(link.appLink);
});

/// What 「附上分享码」 attaches: the share link, or null (with a reason to
/// show) when there is none.
typedef ForumShareCodePick = ({ShareLink? link, String? reason});

/// 「附上分享码」 in the composer. Default: the share link on the clipboard
/// (copied from the share sheet's 「复制链接」). Override to pick the link
/// another way.
final forumShareCodePickerProvider = Provider<Future<ForumShareCodePick> Function(BuildContext context)>((ref) {
  return (context) async {
    if (ref.read(operatingSystemProvider) == 'ohos') {
      final result = await ref.read(pasteReaderProvider).begin().finish();
      if (!context.mounted) return (link: null, reason: null);
      final text = result.text;
      if (text == null) return (link: null, reason: pasteFailureText(result));
      final link = ShareLink.find(text);
      return (link: link, reason: link == null ? appL10n.stateCopyShareCodeFirst : null);
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    final link = text.isEmpty ? null : ShareLink.find(text);
    return (link: link, reason: link == null ? appL10n.stateCopyShareCodeFirst : null);
  };
});
