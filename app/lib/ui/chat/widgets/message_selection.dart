// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../speech/speech_ui.dart';
import 'message_menu.dart';

/// A message's text, selectable where it is: a long-press selects the word
/// under the finger, the handles drag the range. The toolbar over the
/// selection: 复制 · 引用 ([onQuote]) · 分享 · 朗读 · 更多 ([onMore], the
/// message's own menu) · 全选, then the system's text actions.
///
/// It copies, shares and reads what is drawn: a masked credential stays
/// masked (the eye shows it, the menu's 「复制」 takes the original).
class MessageSelection extends StatefulWidget {
  const MessageSelection({super.key, required this.child, this.onQuote, this.onMore});

  final Widget child;
  final ValueChanged<String>? onQuote;
  final VoidCallback? onMore;

  @override
  State<MessageSelection> createState() => _MessageSelectionState();
}

class _MessageSelectionState extends State<MessageSelection> {
  /// What is selected right now (plain text).
  String _selected = '';

  Widget _toolbar(BuildContext context, SelectableRegionState region) {
    final system = region.contextMenuButtonItems;
    ContextMenuButtonItem? item(ContextMenuButtonType type) => system.where((i) => i.type == type).firstOrNull;
    const ours = {ContextMenuButtonType.copy, ContextMenuButtonType.share, ContextMenuButtonType.selectAll};
    final selected = _selected;
    final some = selected.trim().isNotEmpty;
    final onQuote = widget.onQuote;
    final onMore = widget.onMore;
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: region.contextMenuAnchors,
      buttonItems: [
        ?item(ContextMenuButtonType.copy),
        if (some && onQuote != null)
          ContextMenuButtonItem(
            label: MessageAction.quote.label,
            onPressed: () {
              region.clearSelection();
              onQuote(selected);
            },
          ),
        ?item(ContextMenuButtonType.share),
        if (some)
          ContextMenuButtonItem(
            label: MessageAction.readAloud.label,
            onPressed: () {
              region.hideToolbar();
              readAloudReply(this.context, 'selection', selected);
            },
          ),
        // Before 全选: a narrow toolbar folds its last items away, and 「更多」
        // is the way to the message's menu.
        if (onMore != null)
          ContextMenuButtonItem(
            label: context.l10n.commonMore,
            onPressed: () {
              region.clearSelection();
              onMore();
            },
          ),
        ?item(ContextMenuButtonType.selectAll),
        ...system.where((i) => !ours.contains(i.type)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => SelectionArea(
    onSelectionChanged: (content) => _selected = content?.plainText ?? '',
    contextMenuBuilder: _toolbar,
    child: widget.child,
  );
}
