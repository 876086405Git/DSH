// The ways into 「分享」 (share_panel.dart): a reply (the key under it, the
// long-press menu, a reply in a replay), a whole conversation (the drawer), a
// delivered file; and the plugin card the plugin share sheet offers as 「图片」.

import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../share_code/conversation_redact.dart' show redactText;
import '../../share_code/plugin_share.dart' show marketPluginShareWebLink;
import '../../state/artifact_files.dart';
import '../../state/artifacts.dart';
import '../../state/chat_state.dart';
import '../../state/plugins_state.dart' show MarketEntry;
import '../../state/sessions_state.dart';
import '../chat/render/code_block.dart' show languageForPath;
import '../replay/replay_scope.dart';
import '../session/workspace_files.dart' show formatBytes;
import 'share_content.dart';
import 'share_panel.dart';

/// 「分享」 on a reply: the panel at 「这条回复」. A reply in a replayed
/// conversation shares from the replay, not from the chat that happens to be
/// open.
Future<void> shareReply(BuildContext context, AssistantChatItem reply) async {
  if (ReplayScope.maybeOf(context) case final replay?) {
    final end = replay.frames.end;
    final state = ChatState(
      items: end.items,
      turns: end.turns,
      commands: end.commands,
      title: replay.share.title,
      loading: false,
    );
    final done = end.items.whereType<AssistantChatItem>().where((r) => r.id == reply.id).firstOrNull ?? reply;
    final source = ReplaySource(
      share: replay.share,
      state: state,
      assets: replay.assets,
      container: ProviderScope.containerOf(context, listen: false),
    );
    return showSharePanel(context, ConversationSubject(replay: source, reply: done));
  }
  final sessionId = ProviderScope.containerOf(context, listen: false).read(currentSessionProvider);
  if (sessionId == null) return;
  return showSharePanel(context, ConversationSubject(sessionId: sessionId, reply: reply));
}

/// 「分享」 on a conversation (the drawer): the panel at 「整段对话」. Works for
/// a conversation that is not open yet: the panel waits for it.
Future<void> shareConversation(BuildContext context, String sessionId) =>
    showSharePanel(context, ConversationSubject(sessionId: sessionId), scope: ShareScope.whole);

/// The title of [sessionId] from the session list, when it is loaded (no
/// live subscription; never starts loading it).
String? _sessionTitle(ProviderContainer container, String sessionId) => container.exists(sessionsProvider)
    ? container.read(sessionsProvider).value?.where((s) => s.sessionId == sessionId).firstOrNull?.projections.title
    : null;

/// 「分享」 on a delivered file: the panel with the file's card (the picture
/// for images, the first lines for Markdown and text, otherwise the file
/// tile) and the file itself. The panel opens at once with the tile; the
/// picture / lines arrive when fetched.
Future<void> shareArtifact(BuildContext context, {required String sessionId, required Artifact artifact}) {
  final container = ProviderScope.containerOf(context, listen: false);
  final title = shareTitleText(_sessionTitle(container, sessionId));
  final typeLabel = [artifact.typeLabel, if (artifact.bytes case final b?) formatBytes(b)].join(' · ');
  ShareContent content({ImageProvider? image, String? excerpt, String? language}) => ShareContent(
    title: title,
    blocks: [
      ShareFile(
        name: artifact.name,
        typeLabel: typeLabel,
        description: artifact.description == null ? null : redactText(artifact.description!),
        image: image,
        excerpt: excerpt,
        excerptLanguage: language,
      ),
    ],
  );
  return showSharePanel(
    context,
    ArtifactSubject(
      sessionId: sessionId,
      artifact: artifact,
      card: content(),
      refine: _artifactExtras(container.read(artifactFilesProvider), sessionId, artifact, content),
    ),
  );
}

Future<ShareContent?> _artifactExtras(
  ArtifactFiles files,
  String sessionId,
  Artifact artifact,
  ShareContent Function({ImageProvider? image, String? excerpt, String? language}) content,
) async {
  if (!files.canFetch) return null;
  try {
    switch (artifact.kind) {
      case ArtifactKind.image:
        final image = await files
            .thumbnail(sessionId, artifact.path, turn: artifact.snapshotImage ? artifact.turn : null)
            .timeout(const Duration(seconds: 20));
        return image == null ? null : content(image: image);
      case ArtifactKind.markdown || ArtifactKind.text:
        if ((artifact.bytes ?? 0) > 2 * 1024 * 1024) return null;
        final file = await files.materialize(sessionId, artifact).timeout(const Duration(seconds: 20));
        final head = await file.openRead(0, 16 * 1024).transform(const Utf8Decoder(allowMalformed: true)).join();
        final lines = head.split('\n');
        final excerpt = lines.take(40).join('\n').trimRight();
        if (excerpt.isEmpty) return null;
        if (artifact.kind == ArtifactKind.markdown) {
          return content(excerpt: shareMarkdown(excerpt));
        }
        return content(excerpt: redactText(excerpt), language: languageForPath(artifact.path) ?? 'text');
      default:
        return null;
    }
  } catch (_) {
    return null;
  }
}

/// A market plugin as a card: what the plugin share sheet's 「图片」 draws.
ShareContent pluginCardContent(BuildContext context, MarketEntry entry, {String? webLink}) {
  final plugin = entry.plugin;
  final stars = plugin.sortKeys['stars'];
  final published = plugin.latest.published.toLocal();
  return ShareContent(
    title: null,
    // The share-code landing link when it can travel. It carries the whole
    // plugin, usually too long to scan at the card's size: the card then goes
    // without a QR code (ShareCard.qrFor); the text shared with it carries the
    // install command and the plugin page.
    link: webLink ?? marketPluginShareWebLink(plugin) ?? dshGoProjectUrl,
    blocks: [
      SharePlugin(
        name: plugin.name,
        title: entry.title(Localizations.localeOf(context).languageCode),
        author: plugin.author,
        description: entry.summary(Localizations.localeOf(context).languageCode),
        icon: plugin.icon,
        facts: [
          if (stars != null) ('${stars.round()}', context.l10n.viewShareStars),
          (plugin.latest.version, context.l10n.commonVersion),
          ('${published.year}.${published.month}.${published.day}', context.l10n.commonUpdate),
        ],
      ),
    ],
  );
}

/// What goes with a plugin card: name, one line, the install command and
/// where to read more.
String pluginShareText(MarketEntry entry, {String? webLink}) {
  final plugin = entry.plugin;
  final page =
      webLink ??
      plugin.homepage ??
      plugin.repositoryUrl ??
      (plugin.latest.source is MarketNpmSource ? 'https://www.npmjs.com/package/${plugin.name}' : null);
  final description = entry.summary(AppLocale.current.languageCode)?.trim();
  return [
    appL10n.viewSharePluginTitle(entry.title(AppLocale.current.languageCode)),
    if (description != null && description.isNotEmpty) description,
    appL10n.viewShareInstallCommand(
      entry.listing == null ? plugin.name : plugin.latest.installTarget(plugin.name).spec,
    ),
    ?page,
    appL10n.viewSharePhoneInstall(dshGoProjectUrl),
  ].join('\n');
}
