import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../phone/phone_channel.dart';
import '../../state/composer_insert.dart';
import '../../state/phone_skills_state.dart';
import '../common/brief_notice.dart';
import '../common/list_page_row.dart';
import '../features/feature_kit.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'phone_skills_page.dart';
import 'phone_widgets.dart';

/// The five sections in the order DSH reads them, with their titles.
List<(String, String Function(PhoneSkillSections))> skillSections(BuildContext context) {
  final l10n = context.l10n;
  return [
    (l10n.phoneSkillSectionEntry, (s) => s.entry),
    (l10n.phoneSkillSectionSteps, (s) => s.steps),
    (l10n.phoneSkillSectionPitfalls, (s) => s.pitfalls),
    (l10n.phoneSkillSectionSuccess, (s) => s.success),
    (l10n.phoneSkillSectionHandoff, (s) => s.handoff),
  ];
}

/// One skill (§6.3): what it is, how it has gone, its five sections as DSH
/// reads them; 改一改, 在对话里用, 恢复上一版, 删除.
class PhoneSkillDetailPage extends ConsumerWidget {
  const PhoneSkillDetailPage({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final detail = ref.watch(phoneSkillDetailProvider(name));
    final skill = detail.value;
    if (skill == null) {
      return AppPage.list(
        title: l10n.phoneSkillsTitle,
        children: [
          if (detail.error case final PhoneSkillException e)
            ListPageCard(
              children: [
                ListPageRow(
                  icon: AppIcons.error,
                  title: skillErrorText(context, e),
                  titleMaxLines: 3,
                  trailing: TextButton(
                    onPressed: () => ref.invalidate(phoneSkillDetailProvider(name)),
                    child: Text(l10n.commonRetry),
                  ),
                ),
              ],
            )
          else if (detail.hasError)
            PageFootnote(l10n.phoneSkillErrorUnavailable)
          else
            const QuietSpinner(padding: EdgeInsets.symmetric(vertical: 32)),
        ],
      );
    }
    final sections = skill.sections;
    return AppPage.list(
      title: skill.display,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PhoneSkillAppIcon(apps: skill.apps, size: 44, dimmed: skill.state == PhoneSkillState.suspended),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(skill.description, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 6),
                    Text(
                      skillStatusLine(context, skill),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: skill.state == PhoneSkillState.active ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _RecentDots(recent: skill.recent),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        ListPageCard(title: l10n.phoneSkillFieldWhen, children: [_SectionText(skill.whenToUse)]),
        if (sections != null)
          for (final (title, read) in skillSections(context)) ...[
            const SizedBox(height: 16),
            ListPageCard(title: title, children: [_SectionText(read(sections))]),
          ],
        const SizedBox(height: 24),
        ListPageCard(
          children: [
            ListPageRow(
              key: const ValueKey('phone-skill-edit'),
              icon: AppIcons.edit,
              title: l10n.phoneSkillEditDraft,
              onTap: sections == null
                  ? null
                  : () =>
                        Navigator.of(context)
                            .push(MaterialPageRoute<void>(builder: (_) => PhoneSkillEditPage.skill(skill: skill))),
            ),
            ListPageRow(
              key: const ValueKey('phone-skill-use'),
              icon: AppIcons.chat,
              title: l10n.phoneSkillUseInChat,
              onTap: () {
                unawaited(HapticFeedback.selectionClick());
                Navigator.of(context).popUntil((route) => route.isFirst);
                ref.read(composerInsertProvider.notifier).request(ComposerInsert.skill(skill.name, sessionId: null));
              },
            ),
            if (skill.history.isNotEmpty)
              ListPageRow(
                key: const ValueKey('phone-skill-restore'),
                icon: AppIcons.history,
                title: l10n.phoneSkillRestore,
                onTap: () => unawaited(_restore(context, ref, skill)),
              ),
            ListPageRow(
              key: const ValueKey('phone-skill-delete'),
              icon: AppIcons.delete,
              title: l10n.phoneSkillDelete,
              danger: true,
              onTap: () async {
                await confirmDeleteSkill(context, ref, skill.name, skill.display);
                if (context.mounted && !_exists(ref, skill.name)) Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ],
    );
  }

  static bool _exists(WidgetRef ref, String name) =>
      ref.read(phoneSkillsProvider).value?.skills.any((s) => s.name == name) ?? true;

  Future<void> _restore(BuildContext context, WidgetRef ref, PhoneSkill skill) async {
    try {
      await ref.read(phoneSkillsProvider.notifier).restore(skill.name);
      if (context.mounted) showBriefNotice(context, context.l10n.phoneSkillRestored);
    } on PhoneSkillException catch (e) {
      if (context.mounted) showBriefNotice(context, skillErrorText(context, e));
    }
  }
}

class _SectionText extends StatelessWidget {
  const _SectionText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    child: SelectableText(text.trim(), style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5)),
  );
}

/// The last few runs, oldest first: green 办成, red 不灵, grey 不算.
class _RecentDots extends StatelessWidget {
  const _RecentDots({required this.recent});

  final List<PhoneSkillOutcome> recent;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final dsh = DshColors.of(context);
    final theme = Theme.of(context);
    if (recent.isEmpty) {
      return Text(l10n.phoneSkillRecentNone, style: theme.textTheme.labelSmall?.copyWith(color: dsh.textTertiary));
    }
    final words = [
      for (final outcome in recent)
        switch (outcome) {
          PhoneSkillOutcome.ok => l10n.phoneSkillRecentOk,
          PhoneSkillOutcome.miss => l10n.phoneSkillRecentMiss,
          PhoneSkillOutcome.unscored => l10n.phoneSkillRecentVoid,
        },
    ];
    return Semantics(
      label: '${l10n.phoneSkillRecent}: ${words.join(l10n.phoneSkillRecentSeparator)}',
      excludeSemantics: true,
      child: Row(
        children: [
          Text(l10n.phoneSkillRecent, style: theme.textTheme.labelSmall?.copyWith(color: dsh.textTertiary)),
          const SizedBox(width: 8),
          for (final outcome in recent)
            Padding(
              padding: const EdgeInsets.only(right: 5),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: switch (outcome) {
                    PhoneSkillOutcome.ok => dsh.success,
                    PhoneSkillOutcome.miss => dsh.danger,
                    PhoneSkillOutcome.unscored => dsh.textDisabled,
                  },
                ),
                child: const SizedBox.square(dimension: 7),
              ),
            ),
        ],
      ),
    );
  }
}

/// 改一改 (§6.3): a skill's name, what it does, when to use it and its five
/// sections, or a draft's five sections before it is accepted. Saving runs
/// the same checks as a draft; a refusal says what to fix.
class PhoneSkillEditPage extends ConsumerStatefulWidget {
  const PhoneSkillEditPage.skill({super.key, required PhoneSkill this.skill}) : draft = null;

  const PhoneSkillEditPage.draft({super.key, required PhoneSkillDraft this.draft}) : skill = null;

  final PhoneSkill? skill;
  final PhoneSkillDraft? draft;

  @override
  ConsumerState<PhoneSkillEditPage> createState() => _PhoneSkillEditPageState();
}

class _PhoneSkillEditPageState extends ConsumerState<PhoneSkillEditPage> {
  late final PhoneSkillSections _from = widget.skill?.sections ?? widget.draft!.sections;
  late final _display = TextEditingController(text: widget.skill?.display ?? widget.draft!.display);
  late final _description = TextEditingController(text: widget.skill?.description ?? widget.draft!.description);
  late final _when = TextEditingController(text: widget.skill?.whenToUse ?? widget.draft!.whenToUse);
  late final _entry = TextEditingController(text: _from.entry);
  late final _steps = TextEditingController(text: _from.steps);
  late final _pitfalls = TextEditingController(text: _from.pitfalls);
  late final _success = TextEditingController(text: _from.success);
  late final _handoff = TextEditingController(text: _from.handoff);
  bool _saving = false;

  List<TextEditingController> get _all => [
    _display,
    _description,
    _when,
    _entry,
    _steps,
    _pitfalls,
    _success,
    _handoff,
  ];

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  PhoneSkillSections get _sections => PhoneSkillSections(
    entry: _entry.text.trim(),
    steps: _steps.text.trim(),
    pitfalls: _pitfalls.text.trim(),
    success: _success.text.trim(),
    handoff: _handoff.text.trim(),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final skill = widget.skill;
    final draft = widget.draft;
    final controllers = [_entry, _steps, _pitfalls, _success, _handoff];
    return AppPage.list(
      title: skill?.display ?? draft!.display,
      actions: [
        TextButton(
          key: const ValueKey('phone-skill-save'),
          onPressed: _saving ? null : () => unawaited(_save()),
          child: Text(draft == null ? l10n.commonSave : l10n.phoneSkillAccept),
        ),
      ],
      children: [
        if (skill != null) ...[
          _Field(label: l10n.phoneSkillFieldName, controller: _display, maxLines: 1),
          _Field(label: l10n.phoneSkillFieldDescription, controller: _description),
          _Field(label: l10n.phoneSkillFieldWhen, controller: _when),
        ],
        for (final ((title, _), controller) in [
          for (final (i, s) in skillSections(context).indexed) (s, controllers[i]),
        ])
          _Field(label: title, controller: controller, minLines: 3),
        PageFootnote(l10n.phoneSkillEditHint),
      ],
    );
  }

  Future<void> _save() async {
    final notifier = ref.read(phoneSkillsProvider.notifier);
    final skill = widget.skill;
    setState(() => _saving = true);
    try {
      if (skill != null) {
        await notifier.save(
          skill.name,
          display: _display.text.trim(),
          description: _description.text.trim(),
          whenToUse: _when.text.trim(),
          sections: _sections,
        );
        if (mounted) showBriefNotice(context, context.l10n.phoneSkillSaved);
      } else {
        final saved = await notifier.accept(widget.draft!.id, edited: _sections);
        if (mounted) showBriefNotice(context, context.l10n.phoneSkillAccepted(saved.display));
      }
      if (mounted) Navigator.of(context).pop();
    } on PhoneSkillException catch (e) {
      if (mounted) showBriefNotice(context, skillErrorText(context, e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.controller, this.minLines = 1, this.maxLines});

  final String label;
  final TextEditingController controller;
  final int minLines;
  final int? maxLines;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    child: TextField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      textInputAction: maxLines == 1 ? TextInputAction.next : TextInputAction.newline,
      decoration: InputDecoration(labelText: label, alignLabelWithHint: true),
    ),
  );
}
