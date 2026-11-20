// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../speech/speech_ui.dart';
import '../secret_mask.dart';
import 'message_menu.dart';

/// A message's text, selectable where it is: a long-press selects the word
/// under the finger, the handles drag the range. The toolbar over the
/// selection: 复制 · 引用 ([onQuote]) · 分享 · 朗读 · 更多 ([onMore], the
/// message's own menu) · 全选, then the system's text actions.
///
/// It copies and shares what is drawn (a masked credential stays
/// masked; the eye shows it, the menu's 「复制」 takes the original); 朗读
/// leaves credentials out ([speakableSelection]).
class MessageSelection extends StatefulWidget {
  const MessageSelection({super.key, required this.text, required this.child, this.onQuote, this.onMore});

  /// The whole message: 朗读 finds its credentials here, where a selected
  /// piece of one would no longer look like one.
  final String text;

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
              // Its own id: another passage starts over, the same one stops.
              readAloudReply(this.context, 'selection:$selected', speakableSelection(selected, widget.text));
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

/// [selected] without any part of a credential in [message]: a whole one, one
/// cut at either end of the selection, or a selection inside one (nothing is
/// left). Neither a voice service nor the speaker gets it, as with a whole
/// reply. Text only, without positions: a cut counts from [_least] characters,
/// so an ordinary word that merely shares a letter with a key stays.
@visibleForTesting
String speakableSelection(String selected, String message) {
  final cut = List.filled(selected.length, false);
  for (final secret in findSecrets(message)) {
    final value = message.substring(secret.start, secret.end);
    final words = selected.trim();
    if (words.length >= _least && value.contains(words)) return '';
    for (var at = selected.indexOf(value); at >= 0; at = selected.indexOf(value, at + 1)) {
      cut.fillRange(at, at + value.length, true);
    }
    for (var n = math.min(value.length, selected.length); n >= _least; n--) {
      if (selected.startsWith(value.substring(value.length - n))) {
        cut.fillRange(0, n, true);
        break;
      }
    }
    for (var n = math.min(value.length, selected.length); n >= _least; n--) {
      if (selected.endsWith(value.substring(0, n))) {
        cut.fillRange(selected.length - n, selected.length, true);
        break;
      }
    }
  }
  return String.fromCharCodes([
    for (var i = 0; i < selected.length; i++)
      if (!cut[i]) selected.codeUnitAt(i),
  ]);
}

const _least = 4;
