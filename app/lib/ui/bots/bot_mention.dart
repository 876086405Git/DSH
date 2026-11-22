// SPDX-FileCopyrightText: 2026 Fei2411 and the DS Bot contributors
// SPDX-License-Identifier: Apache-2.0
// See THIRD_PARTY_NOTICES.md.
// Modified: the mention rules of `ds-bot/src/shared/mentions.js` (the everyone word, no
// mention right after an address character) applied to a Flutter `@` picker.
// The `@` picker of a group chat: the group's members (and 「所有人」) above
// the composer while the caret is in an `@` word; a pick writes `@Name ` the
// way DS Bot reads a mention. Self-contained: it only listens to a
// TextEditingController, so any composer can host it.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../common/smooth_size.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'bot_avatar.dart';
import 'bots_page.dart' show BotTag;

/// The `@` word the caret is in: where its `@` is and what follows it.
/// An `@` right after a letter, digit, `_` or `.` is an address, not a
/// mention, as DS Bot decides.
({int start, String query})? activeBotMention(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid || !selection.isCollapsed) return null;
  final text = value.text;
  final caret = selection.baseOffset.clamp(0, text.length);
  var at = caret - 1;
  while (at >= 0) {
    final unit = text[at];
    if (unit == '@') break;
    if (caret - at > 40 || RegExp(r'\s').hasMatch(unit)) return null;
    at -= 1;
  }
  if (at < 0) return null;
  if (at > 0 && RegExp(r'[A-Za-z0-9_.]').hasMatch(text[at - 1])) return null;
  final query = text.substring(at + 1, caret);
  return (start: at, query: query);
}

/// One row of the picker: a member, or everyone.
class BotMentionOption {
  const BotMentionOption({required this.label, required this.insert, this.bot, this.admin = false});

  final String label;

  /// What goes into the draft, `@` included.
  final String insert;
  final DsBot? bot;
  final bool admin;
}

/// The word DS Bot reads as "every member".
// l10n:keep engine mention token
const mentionEveryone = '所有人';

/// Follows [input]; [members] are the group's Bots, the admin first.
class BotMentionController extends ChangeNotifier {
  BotMentionController({required this.input, this.members = const [], this.admin}) {
    input.addListener(_onInput);
  }

  final TextEditingController input;

  /// The group's Bots; [admin] is listed first and tagged.
  List<DsBot> members;
  String? admin;
  ({int start, String query})? _query;
  int? _dismissedAt;
  int _highlight = 0;

  /// New members or a new admin (the group changed). Called while the page
  /// builds, which redraws the picker anyway, so nobody is notified.
  void setMembers(List<DsBot> members, String? admin) {
    this.members = members;
    this.admin = admin;
  }

  ({int start, String query})? get query => _query;
  int get highlighted => _highlight;

  bool get isOpen => _query != null && _dismissedAt != _query!.start && options.isNotEmpty;

  List<BotMentionOption> get options {
    final q = _query?.query.toLowerCase() ?? '';
    bool matches(String name) => q.isEmpty || name.toLowerCase().contains(q);
    final ordered = [...members.where((bot) => bot.id == admin), ...members.where((bot) => bot.id != admin)];
    return [
      for (final bot in ordered)
        if (matches(bot.name))
          BotMentionOption(label: bot.name, insert: '@${bot.name}', bot: bot, admin: bot.id == admin),
      if (matches(mentionEveryone) || matches(appL10n.botsEveryone) || 'all'.contains(q) || 'everyone'.contains(q))
        BotMentionOption(label: appL10n.botsEveryone, insert: '@$mentionEveryone'),
    ];
  }

  void _onInput() {
    final next = activeBotMention(input.value);
    if (next == _query) return;
    final moved = next == null || _query == null || next.start != _query!.start;
    _query = next;
    if (moved) {
      _dismissedAt = null;
      _highlight = 0;
    } else {
      _highlight = 0;
    }
    notifyListeners();
  }

  /// Writes `@Name ` over the `@` word.
  void pick(BotMentionOption option) {
    final q = _query;
    if (q == null) return;
    HapticFeedback.selectionClick();
    final text = input.text;
    final end = input.selection.baseOffset.clamp(q.start, text.length);
    final inserted = '${option.insert} ';
    final next = text.replaceRange(q.start, end, inserted);
    input.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: q.start + inserted.length),
    );
  }

  /// The 「@」 key: starts a mention at the caret (after a space when the
  /// caret follows a word), which opens the picker.
  void start() {
    HapticFeedback.selectionClick();
    final value = input.value;
    final text = value.text;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final before = text.substring(0, start);
    final insert = before.isEmpty || RegExp(r'\s$').hasMatch(before) ? '@' : ' @';
    input.value = TextEditingValue(
      text: text.replaceRange(start, end, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
  }

  void dismiss() {
    final q = _query;
    if (q == null) return;
    _dismissedAt = q.start;
    notifyListeners();
  }

  /// Hardware keys while it is open: ↑ ↓ move, Enter / Tab pick, Esc closes.
  KeyEventResult handleKey(FocusNode node, KeyEvent event) {
    if (!isOpen || event is KeyUpEvent) return KeyEventResult.ignored;
    final all = options;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      dismiss();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _highlight = (_highlight + 1) % all.length;
      notifyListeners();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _highlight = _highlight <= 0 ? all.length - 1 : _highlight - 1;
      notifyListeners();
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.tab) {
      pick(all[_highlight.clamp(0, all.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    input.removeListener(_onInput);
    super.dispose();
  }
}

/// The glass popover over the composer, like the chat's own `@` panel.
///
/// ```
/// ╭──────────────────────────────────╮
/// │  成员                            │
/// │  ◉  Chief            管理员      │
/// │  ◉  Writer                       │
/// │  ◎  所有人                       │
/// ╰──────────────────────────────────╯
/// ```
class BotMentionPicker extends StatelessWidget {
  const BotMentionPicker({super.key, required this.controller});

  final BotMentionController controller;

  static const radius = 20.0;
  static const rowHeight = 48.0;
  static const face = 28.0;

  /// Inset of the rows from the popover's edges, both sides.
  static const inset = 12.0;
  static const maxHeight = 248.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final options = controller.options;
    return Semantics(
      container: true,
      label: l10n.botsChooseMember,
      child: GlassSurface(
        tier: GlassTier.sheet,
        borderRadius: const BorderRadius.all(Radius.circular(radius)),
        child: Material(
          color: DshSurfaces.of(context).backdropTop.withValues(alpha: 0.94),
          clipBehavior: Clip.antiAlias,
          shape: const RoundedSuperellipseBorder(borderRadius: BorderRadius.all(Radius.circular(radius))),
          child: SmoothSize(
            duration: AppMotion.of(context, AppMotion.quick),
            curve: AppMotion.std,
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: maxHeight),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(inset + 6, 4, inset + 6, 4),
                    child: Text(
                      l10n.botsMembers,
                      style: theme.textTheme.labelMedium?.copyWith(color: dsh.textTertiary),
                    ),
                  ),
                  for (final (i, option) in options.indexed)
                    _MentionRow(
                      key: ValueKey('mention-${option.label}'),
                      option: option,
                      highlighted: i == controller.highlighted && (controller.query?.query.isNotEmpty ?? false),
                      onTap: () => controller.pick(option),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MentionRow extends StatelessWidget {
  const _MentionRow({super.key, required this.option, required this.highlighted, required this.onTap});

  final BotMentionOption option;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    const inset = BotMentionPicker.inset;
    final bot = option.bot;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: inset - 6),
      child: Material(
        color: highlighted ? theme.colorScheme.onSurface.withValues(alpha: 0.06) : Colors.transparent,
        shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusMd),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: BotMentionPicker.rowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: BotMentionPicker.face,
                    child: bot == null
                        ? DecoratedBox(
                            decoration: ShapeDecoration(
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.07),
                              shape: const CircleBorder(),
                            ),
                            child: Icon(AppIcons.team, size: 16, color: dsh.textTertiary),
                          )
                        : BotAvatar(bot: bot, size: BotMentionPicker.face),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      option.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(fontSize: 15),
                    ),
                  ),
                  if (option.admin) BotTag(l10n.botsAdmin),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The composer's left key in a group: the same 40 circle as the chat's ＋,
/// so it mirrors the send key; it starts an `@` and opens the member list.
class MentionKey extends StatelessWidget {
  const MentionKey({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  static const size = 36.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: l10n.botsMentionMember,
      child: Tooltip(
        message: l10n.botsMentionMember,
        child: InkResponse(
          onTap: onPressed,
          radius: 22,
          child: Container(
            key: const ValueKey('mention-key'),
            width: size,
            height: size,
            decoration: BoxDecoration(color: scheme.onSurface.withValues(alpha: 0.06), shape: BoxShape.circle),
            child: Icon(
              AppIcons.mention,
              size: 20,
              color: enabled ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.38),
            ),
          ),
        ),
      ),
    );
  }
}
