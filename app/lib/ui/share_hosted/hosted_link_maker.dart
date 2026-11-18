// Plugs the share host (app/lib/share_hosted/) into the share panel's 「链接」
// (ui/replay/conversation_out.dart):
//
//   conversationLinkMakerProvider.overrideWith(hostedConversationLinkMaker)
//
// Every link made this way is kept in 「我的分享链接」.

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../share_hosted/hosted_link.dart';
import '../../share_hosted/hosted_links_state.dart';
import '../replay/conversation_out.dart';

class HostedConversationLinkMaker implements ConversationLinkMaker {
  const HostedConversationLinkMaker(this._links);

  final HostedLinksController _links;

  static HostedTtl ttlOf(LinkExpiry expiry) => switch (expiry) {
    LinkExpiry.week => HostedTtl.week,
    LinkExpiry.month => HostedTtl.month,
    LinkExpiry.forever => HostedTtl.forever,
  };

  /// Throws [HostedShareException]; its `message` is ready to show.
  @override
  Future<ConversationLink> upload(Uint8List fileBytes, LinkExpiry expiry, {required String title}) async {
    final link = await _links.publish(fileBytes, title: title, ttl: ttlOf(expiry));
    return ConversationLink(
      url: Uri.parse(link.url),
      expiresAt: link.expiresAt,
      id: link.id,
      locallySaved: _links.isPersisted(link.id),
    );
  }

  /// Hidden from 「我的分享链接」 at once, deleted on the host after the
  /// undo window (as a delete there).
  @override
  Future<void> revoke(ConversationLink link) async {
    if (link.id == null) {
      if (_links.isHarmonyOS) throw const HostedStorageException();
      return;
    }
    final saved = await _links.remove(link.id!);
    if (_links.isHarmonyOS && !saved) throw const HostedStorageException();
  }

  @override
  Future<void> restore(ConversationLink link) async {
    final result = link.id == null ? HostedUndoResult.unavailable : await _links.undo(link.id!);
    if (_links.isHarmonyOS && result == HostedUndoResult.sessionOnly) throw const ConversationLinkRestoreUnsaved();
    if (_links.isHarmonyOS && result == HostedUndoResult.unavailable) throw const HostedStorageException();
  }

  @override
  Duration get undoWindow => HostedLinksController.undoWindow;
}

/// For `conversationLinkMakerProvider.overrideWith(...)`, or as its body.
ConversationLinkMaker? hostedConversationLinkMaker(Ref ref) =>
    HostedConversationLinkMaker(ref.watch(hostedLinksProvider.notifier));
