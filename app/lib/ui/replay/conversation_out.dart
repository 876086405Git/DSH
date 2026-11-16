// Where a shared conversation goes — a `.dshgo` file, a self-contained `.html`
// or Markdown (the Android share sheet, or Download/DSH-Go), plain text, or a
// hosted link (the share host's client, app/lib/share_hosted/). Seams: tests
// record instead.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/l10n.dart';
import '../../share_code/conversation_html.dart';
import '../../share_code/conversation_share.dart' show prefixKeepingPairs;
import '../../share_code/share_codec.dart' show shareFileExtension, shareFileMime;
import '../../share_hosted/hosted_client.dart' show HostedShareException;
import '../share_hosted/hosted_link_maker.dart' show hostedConversationLinkMaker;
import '../../state/artifacts.dart' show FilesChannel, filesChannelProvider;

/// 「我的分享链接」 for the share panel's link page.
export '../share_hosted/manage_links_button.dart' show ManageLinksButton;

/// The file forms of a shared conversation.
enum ConversationFormat {
  /// `.dshgo`: opens in dsh-go (replay, 「接着聊」) and on the landing page.
  file,

  /// `.html`: opens in any browser, offline.
  page,

  /// `.md`: who said what, one line per tool call (what 「接着聊」 attaches).
  markdown;

  String get extension => switch (this) {
    file => shareFileExtension,
    page => 'html',
    markdown => 'md',
  };

  String get mime => switch (this) {
    file => shareFileMime,
    page => conversationHtmlMime,
    markdown => 'text/markdown',
  };

  /// Carries the `.dshgo` file (and so its size limit).
  bool get carriesFile => this != markdown;
}

class ConversationOut {
  ConversationOut({
    required this.files,
    Future<Directory> Function()? cacheRoot,
    Future<void> Function(ShareParams params)? share,
  }) : _cacheRoot = cacheRoot ?? getTemporaryDirectory,
       _share = share ?? _systemShare;

  final FilesChannel files;
  final Future<Directory> Function() _cacheRoot;
  final Future<void> Function(ShareParams params) _share;

  static Future<void> _systemShare(ShareParams params) async {
    await SharePlus.instance.share(params);
  }

  /// 「修复登录重复提交.dshgo」.
  static String fileName(String title, ConversationFormat format) => '${fileStem(title)}.${format.extension}';

  /// Writes [content] into the cache's `conversation/` (keeping the last few).
  Future<File> write(String name, String content) async {
    final dir = Directory('${(await _cacheRoot()).path}/conversation');
    await dir.create(recursive: true);
    final old = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    for (final file in old.skip(4)) {
      try {
        file.deleteSync();
      } catch (_) {}
    }
    final file = File('${dir.path}/$name');
    await file.writeAsString(content, flush: true);
    return file;
  }

  /// The Android share sheet with the file.
  Future<void> shareFile(File file, ConversationFormat format) => _share(
    ShareParams(
      files: [XFile(file.path, mimeType: format.mime, name: file.uri.pathSegments.last)],
    ),
  );

  /// The Android share sheet with a link.
  Future<void> shareText(String text) => _share(ShareParams(text: text));

  /// Into `Download/DSH-Go`; returns where it landed.
  Future<String> save(String name, String content, ConversationFormat format) async {
    final dir = await Directory('${(await _cacheRoot()).path}/conversation').create(recursive: true);
    // A dismissed sheet can reopen before the native worker reads its source.
    final operation = await dir.createTemp('save-');
    try {
      final file = File('${operation.path}/$name');
      await file.writeAsString(content, flush: true);
      return await files.saveToDownloads(file.path, name: name, mime: format.mime);
    } finally {
      try {
        await operation.delete(recursive: true);
      } catch (_) {
        // Cleanup must preserve the native result or the original save error.
      }
    }
  }
}

final conversationOutProvider = Provider<ConversationOut>(
  (ref) => ConversationOut(files: ref.watch(filesChannelProvider)),
);

/// A file name from a title: no path characters, at most 40 characters.
String fileStem(String title) {
  final cleaned = title.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleaned.isEmpty) return appL10n.fileChatFallback;
  return cleaned.length <= 40 ? cleaned : prefixKeepingPairs(cleaned, 40).trim();
}

// ── Hosted links ─────────────────────────────────────────────────────────────

/// How long a hosted link lives (the share host's `ttl`).
enum LinkExpiry {
  week,
  month,
  forever;

  String get label => switch (this) {
    LinkExpiry.week => appL10n.viewLinkWeek,
    LinkExpiry.month => appL10n.viewLinkMonth,
    LinkExpiry.forever => appL10n.viewLinkForever,
  };
}

/// A hosted link: `https://<host>/c/<id>#k=<key>`.
class ConversationLink {
  const ConversationLink({required this.url, this.expiresAt, this.id, this.locallySaved = true});

  /// False when upload succeeded but the local secure list could not be saved.
  final bool locallySaved;

  final Uri url;

  /// Null: kept until deleted.
  final DateTime? expiresAt;

  /// The share host's id, for [ConversationLinkMaker.revoke].
  final String? id;

  /// `go.dshtui.com/c/a1B2c3D4e5`: the link without its scheme and key.
  String get display => '${url.host}${url.path}';
}

/// Puts a conversation file on the share host, encrypted on the phone (the
/// key only in the link, after `#`). A seam over the share host's client
/// (`app/lib/share_hosted/`, adapted in ui/share_hosted/hosted_link_maker.dart,
/// which also keeps every link in 「我的分享链接」); null leaves 「链接」 out of
/// the share sheet.
/// The live delete was cancelled, but its persistent restart marker remains.
class ConversationLinkRestoreUnsaved implements Exception {
  const ConversationLinkRestoreUnsaved();
}

abstract class ConversationLinkMaker {
  /// [fileBytes] is the `.dshgo` file's UTF-8 text; [title] names it in
  /// 「我的分享链接」. Throws [HostedShareException] (its `message` is for the
  /// person).
  Future<ConversationLink> upload(Uint8List fileBytes, LinkExpiry expiry, {required String title});

  /// 「停止分享」: the link stops working once [undoWindow] passes without
  /// [restore].
  Future<void> revoke(ConversationLink link);

  /// Takes a [revoke] back, within [undoWindow].
  Future<void> restore(ConversationLink link);

  /// How long a revoke can be taken back.
  Duration get undoWindow;
}

final conversationLinkMakerProvider = Provider<ConversationLinkMaker?>(hostedConversationLinkMaker);

/// The bytes a link maker uploads.
Uint8List conversationFileBytes(String fileText) => Uint8List.fromList(utf8.encode(fileText));
