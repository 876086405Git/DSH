import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../phone/phone_channel.dart';
import '../../state/phone_skills_state.dart';
import '../common/brief_notice.dart';
import '../common/list_page_row.dart';
import '../common/segmented_pill.dart';
import '../shell/page_frame.dart';
import '../features/feature_kit.dart';
import '../features/feature_widgets.dart' show openSessionInChat;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'phone_skill_detail_page.dart';
import 'phone_widgets.dart';

/// 手机技能 (docs/design/phone-skills.md §6.2): 「从做过的事里学」, the skills
/// DSH learned (each can be turned off, opened, edited) and the drafts waiting
/// for the person.
class PhoneSkillsPage extends ConsumerStatefulWidget {
  const PhoneSkillsPage({super.key, this.drafts = false});

  /// Opens on 「待确认」 (from a notification or the row's count).
  final bool drafts;

  @override
  ConsumerState<PhoneSkillsPage> createState() => _PhoneSkillsPageState();
}

enum _Tab { mine, drafts }

class _PhoneSkillsPageState extends ConsumerState<PhoneSkillsPage> {
  late _Tab _tab = widget.drafts ? _Tab.drafts : _Tab.mine;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final listing = ref.watch(phoneSkillsProvider);
    final data = listing.value;
    return AppPage.list(
      title: l10n.phoneSkillsTitle,
      children: [
        if (data == null)
          listing.hasError
              ? ListPageCard(
                  children: [
                    ListPageRow(
                      icon: AppIcons.error,
                      title: l10n.phoneSkillErrorUnavailable,
                      titleMaxLines: 3,
                      trailing: TextButton(
                        onPressed: () => ref.invalidate(phoneSkillsProvider),
                        child: Text(l10n.commonRetry),
                      ),
                    ),
                  ],
                )
              : const QuietSpinner(padding: EdgeInsets.symmetric(vertical: 32))
        else ...[
          ListPageCard(
            children: [
              ListPageRow(
                key: const ValueKey('phone-skills-learn'),
                icon: AppIcons.skill,
                title: l10n.phoneSkillsLearn,
                subtitle: data.learn ? l10n.phoneSkillsLearnHint : l10n.phoneSkillsLearnOffHint,
                subtitleMaxLines: 2,
                onTap: () => _setLearn(!data.learn),
                trailing: Switch(value: data.learn, onChanged: _setLearn),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedPill<_Tab>(
              expand: true,
              selected: _tab,
              onChanged: (tab) => setState(() => _tab = tab),
              segments: [
                PillSegment(_Tab.mine, l10n.phoneSkillsTabMine),
                PillSegment(
                  _Tab.drafts,
                  data.drafts.isEmpty ? l10n.phoneSkillsTabDraftsNone : l10n.phoneSkillsTabDrafts(data.drafts.length),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_tab == _Tab.mine) ..._mine(data) else ..._drafts(data),
        ],
      ],
    );
  }

  List<Widget> _mine(PhoneSkillListing data) {
    final l10n = context.l10n;
    final skills = [...data.skills]..sort(_byState);
    return [
      if (skills.isEmpty)
        PageFootnote(l10n.phoneSkillsEmpty)
      else
        ListPageCard(children: [for (final skill in skills) _SkillRow(skill: skill)]),
      if (data.legacy.isNotEmpty) ...[
        const SizedBox(height: 24),
        ListPageCard(
          title: l10n.phoneSkillLegacyTitle,
          children: [
            for (final old in data.legacy)
              ListPageRow(
                key: ValueKey('phone-skill-legacy-${old.name}'),
                icon: AppIcons.history,
                title: old.name,
                trailing: IconButton(
                  tooltip: l10n.phoneSkillDelete,
                  icon: const Icon(AppIcons.delete, size: 20),
                  onPressed: () => unawaited(confirmDeleteSkill(context, ref, old.name, old.name)),
                ),
              ),
          ],
        ),
        PageFootnote(l10n.phoneSkillLegacyHint),
      ],
      PageFootnote(l10n.phoneSkillsFootnote),
    ];
  }

  List<Widget> _drafts(PhoneSkillListing data) {
    final hidden = ref.watch(hiddenSkillDraftsProvider);
    final drafts = [...data.drafts.where((d) => !hidden.contains(d.id))]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (drafts.isEmpty) return [PageFootnote(context.l10n.phoneSkillsDraftsEmpty)];
    return [
      for (final (i, draft) in drafts.indexed) ...[
        if (i > 0) const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: PhoneSkillDraftCard(key: ValueKey('phone-skill-draft-${draft.id}'), draft: draft),
        ),
      ],
    ];
  }

  static int _byState(PhoneSkill a, PhoneSkill b) {
    int rank(PhoneSkill s) => switch (s.state) {
      PhoneSkillState.active => 0,
      PhoneSkillState.trial => 1,
      PhoneSkillState.suspended => 2,
    };
    final byRank = rank(a).compareTo(rank(b));
    return byRank != 0 ? byRank : b.uses.compareTo(a.uses);
  }

  Future<void> _setLearn(bool on) async {
    unawaited(HapticFeedback.selectionClick());
    try {
      await ref.read(phoneSkillsProvider.notifier).setLearn(on);
    } on PhoneSkillException catch (e) {
      if (mounted) showBriefNotice(context, skillErrorText(context, e));
    }
  }
}

class _SkillRow extends ConsumerWidget {
  const _SkillRow({required this.skill});

  final PhoneSkill skill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final on = skill.state != PhoneSkillState.suspended;
    return ListPageRow(
      key: ValueKey('phone-skill-${skill.name}'),
      leading: PhoneSkillAppIcon(apps: skill.apps, dimmed: !on),
      title: skill.display,
      subtitle: skillStatusLine(context, skill),
      subtitleColor: skill.state == PhoneSkillState.active ? Theme.of(context).colorScheme.primary : null,
      onTap: () =>
          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PhoneSkillDetailPage(name: skill.name))),
      trailingSemanticLabel: l10n.phoneSkillUse,
      trailing: Switch(
        value: on,
        onChanged: (value) async {
          unawaited(HapticFeedback.selectionClick());
          try {
            await ref.read(phoneSkillsProvider.notifier).setEnabled(skill.name, value);
          } on PhoneSkillException catch (e) {
            if (context.mounted) showBriefNotice(context, skillErrorText(context, e));
          }
        },
      ),
    );
  }
}

/// 「常用 · 用了 12 次」, 「试用中 · …」, 「已停用」, then 「你让 DSH 写的」 when it is.
String skillStatusLine(BuildContext context, PhoneSkill skill) {
  final l10n = context.l10n;
  final state = switch (skill.state) {
    PhoneSkillState.active => l10n.phoneSkillStateActive(skill.uses),
    PhoneSkillState.trial => l10n.phoneSkillStateTrial,
    PhoneSkillState.suspended =>
      skill.suspensionReason == PhoneSkillSuspensionReason.misses
          ? l10n.phoneSkillStateSuspendedMisses
          : l10n.phoneSkillStateSuspended,
  };
  return skill.source == PhoneSkillSource.written ? '$state · ${l10n.phoneSkillSourceWritten}' : state;
}

/// What the person reads for a refused change.
String skillErrorText(BuildContext context, PhoneSkillException e) {
  final l10n = context.l10n;
  return switch (e.code) {
    'changed' => l10n.phoneSkillErrorChanged,
    'invalid' => l10n.phoneSkillErrorInvalid,
    'sensitive' => l10n.phoneSkillErrorSensitive,
    _ => l10n.phoneSkillErrorUnavailable,
  };
}

Future<void> confirmDeleteSkill(BuildContext context, WidgetRef ref, String name, String display) async {
  final l10n = context.l10n;
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.phoneSkillDeleteTitle(display)),
      content: Text(l10n.phoneSkillDeleteBody),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.commonCancel)),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: DshColors.of(context).danger),
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.commonDelete),
        ),
      ],
    ),
  );
  if (yes != true) return;
  try {
    await ref.read(phoneSkillsProvider.notifier).delete(name);
  } on PhoneSkillException catch (e) {
    if (context.mounted) showBriefNotice(context, skillErrorText(context, e));
  }
}

/// The app a skill works in, as a rounded square (its own icon when installed,
/// else the skill glyph); a second app peeks out behind the first.
class PhoneSkillAppIcon extends ConsumerWidget {
  const PhoneSkillAppIcon({super.key, required this.apps, this.size = 28, this.dimmed = false});

  final List<String> apps;
  final double size;
  final bool dimmed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = apps.isEmpty ? null : ref.watch(phoneAppInfoProvider(appInfoKey(apps))).value;
    final icons = [
      for (final pkg in apps)
        if (info?[pkg]?.icon case final Uint8List bytes) bytes,
    ];
    final scheme = Theme.of(context).colorScheme;
    Widget square(Uint8List? bytes) => ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.235),
      child: SizedBox.square(
        dimension: size,
        child: bytes == null
            ? ColoredBox(
                color: scheme.primary.withValues(alpha: 0.12),
                child: Icon(AppIcons.skill, size: size * 0.6, color: scheme.primary),
              )
            : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
      ),
    );
    final front = square(icons.firstOrNull);
    final child = icons.length < 2
        ? front
        : SizedBox(
            width: size + 6,
            height: size,
            child: Stack(
              children: [
                Positioned(left: 6, top: 0, child: Opacity(opacity: 0.5, child: square(icons[1]))),
                front,
              ],
            ),
          );
    return Opacity(opacity: dimmed ? 0.45 : 1, child: child);
  }
}

/// A draft waiting for the person (§6.2, §6.4): what DSH learned or wants to
/// change, and 收下 / 改一改 / 不要. Used on the skills page and in the chat
/// the task ran in ([showSource] off there).
class PhoneSkillDraftCard extends ConsumerStatefulWidget {
  const PhoneSkillDraftCard({super.key, required this.draft, this.showSource = true, this.compact = false});

  final PhoneSkillDraft draft;
  final bool showSource;

  /// In the chat: the description and diff are shorter.
  final bool compact;

  @override
  ConsumerState<PhoneSkillDraftCard> createState() => _PhoneSkillDraftCardState();
}

class _PhoneSkillDraftCardState extends ConsumerState<PhoneSkillDraftCard> {
  bool _busy = false;

  PhoneSkillDraft get _draft => widget.draft;
  bool get _update => _draft.kind == PhoneSkillDraftKind.update;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dsh = DshColors.of(context);
    final changed = _draft.diff.where((line) => line.operation != PhoneSkillDiffOperation.unchanged).toList();
    final shown = changed.take(widget.compact ? 4 : 10).toList();
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: Color.alphaBlend(scheme.primary.withValues(alpha: 0.06), scheme.surfaceContainerLow),
        shape: Squircle.border(
          AppShape.lg,
          side: BorderSide(color: scheme.primary.withValues(alpha: 0.18), width: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(AppIcons.skill, size: 15, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _update
                        ? l10n.phoneSkillUpdateTitle(_targetDisplay(ref) ?? _draft.display)
                        : l10n.phoneSkillLearnedTitle,
                    style: theme.textTheme.labelMedium?.copyWith(color: scheme.primary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PhoneSkillAppIcon(apps: _draft.apps, size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_draft.display, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        _draft.description,
                        maxLines: widget.compact ? 2 : 4,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_update && shown.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final line in shown)
                Text(
                  '${line.operation == PhoneSkillDiffOperation.added ? '+' : '−'} ${line.text}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: line.operation == PhoneSkillDiffOperation.added ? dsh.success : dsh.danger,
                  ),
                ),
              if (changed.length > shown.length)
                Text('…', style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary)),
            ],
            const SizedBox(height: 6),
            // Wraps on a narrow screen or large text instead of pushing a button off the card.
            Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonal(
                  key: const ValueKey('phone-skill-draft-accept'),
                  onPressed: _busy ? null : () => unawaited(_accept()),
                  child: Text(_update ? l10n.phoneSkillAcceptUpdate : l10n.phoneSkillAccept),
                ),
                TextButton(
                  key: const ValueKey('phone-skill-draft-edit'),
                  onPressed: _busy ? null : _edit,
                  child: Text(l10n.phoneSkillEditDraft),
                ),
                if (widget.showSource)
                  TextButton(
                    key: const ValueKey('phone-skill-draft-source'),
                    style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
                    onPressed: () => openSessionInChat(context, ref, _draft.from.sessionId),
                    child: Text(l10n.phoneSkillOpenSource),
                  ),
                TextButton(
                  key: const ValueKey('phone-skill-draft-discard'),
                  style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
                  onPressed: _busy ? null : () => unawaited(_discard()),
                  child: Text(l10n.phoneSkillDiscard),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String? _targetDisplay(WidgetRef ref) {
    final target = _draft.target;
    if (target == null) return null;
    return ref.watch(phoneSkillsProvider).value?.skills.where((s) => s.name == target).firstOrNull?.display;
  }

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      final skill = await ref.read(phoneSkillsProvider.notifier).accept(_draft.id);
      if (mounted) showBriefNotice(context, context.l10n.phoneSkillAccepted(skill.display));
    } on PhoneSkillException catch (e) {
      if (mounted) showBriefNotice(context, skillErrorText(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _edit() =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PhoneSkillEditPage.draft(draft: _draft)));

  /// Gone at once; 「撤销」 keeps it for five seconds before the native side forgets it.
  Future<void> _discard() async {
    final notifier = ref.read(phoneSkillsProvider.notifier);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    setState(() => _busy = true);
    var undone = false;
    final hidden = HiddenSkillDrafts.of(ref)..hide(_draft.id);
    final bar = messenger?.showSnackBar(
      SnackBar(
        // A screen reader needs the time to reach 「撤销」; closing it discards.
        persist: MediaQuery.of(context).accessibleNavigation,
        showCloseIcon: MediaQuery.of(context).accessibleNavigation,
        content: Text(l10n.phoneSkillDiscarded),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: l10n.phoneSkillUndo,
          onPressed: () {
            undone = true;
            hidden.show(_draft.id);
          },
        ),
      ),
    );
    await (bar?.closed ?? Future<void>.delayed(const Duration(seconds: 5)));
    if (undone) return;
    try {
      await notifier.discard(_draft.id);
    } on PhoneSkillException {
      hidden.show(_draft.id);
    }
  }
}

/// Drafts the person just discarded, hidden while 「撤销」 is still offered.
class HiddenSkillDrafts extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void hide(String id) => state = {...state, id};

  void show(String id) => state = {...state}..remove(id);

  static HiddenSkillDrafts of(WidgetRef ref) => ref.read(hiddenSkillDraftsProvider.notifier);
}

final hiddenSkillDraftsProvider = NotifierProvider<HiddenSkillDrafts, Set<String>>(HiddenSkillDrafts.new);
