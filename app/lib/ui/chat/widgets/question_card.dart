// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../common/expand_reveal.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../render/markdown_body.dart';
import 'chat_card.dart';
import 'schedule_question_body.dart';
import 'stream_motion.dart';

typedef QuestionResponder = Future<void> Function(UserQuestionRequest request, List<QuestionAnswer> answers);

/// 提问卡(`ask_user_question`):[ChatCard] 的「提问」语气,与审批卡同一套
/// 解剖;选项是可选中的行(按下缩放),底部一个通栏的「提交」;能拒绝时
/// 与「不回答」左右成对,同审批卡。
class QuestionCard extends StatefulWidget {
  const QuestionCard({super.key, required this.request, required this.onAnswer, this.onReject});

  final UserQuestionRequest request;
  final QuestionResponder onAnswer;

  /// Explicitly settle the Host request; never just hide an unanswered card.
  final Future<void> Function(UserQuestionRequest request)? onReject;

  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  late final List<Set<int>> _picked = [for (final _ in widget.request.questions) <int>{}];
  late final List<TextEditingController> _custom = [for (final _ in widget.request.questions) TextEditingController()];
  late final List<bool> _customOpen = [for (final q in widget.request.questions) q.options.isEmpty];
  bool _sending = false;

  /// The in-flight action is the decline (its button shows the spinner).
  bool _declining = false;

  /// 选到一半滚出屏幕、切去别的对话再回来,选择和自填都还在:草稿记在
  /// 所在路由的 [PageStorage] 里。
  String get _draftId => 'question-${widget.request.eventId}';

  @override
  void initState() {
    super.initState();
    final draft = PageStorage.maybeOf(context)?.readState(context, identifier: _draftId);
    if (draft case (List<Set<int>> picked, List<String> texts, List<bool> open)) {
      for (var i = 0; i < _picked.length; i++) {
        _picked[i].addAll(picked[i]);
        _custom[i].text = texts[i];
        _customOpen[i] = open[i];
      }
    }
  }

  void _saveDraft() {
    PageStorage.maybeOf(context)?.writeState(context, (
      [
        for (final picked in _picked) {...picked},
      ],
      [for (final controller in _custom) controller.text],
      [..._customOpen],
    ), identifier: _draftId);
  }

  @override
  void dispose() {
    for (final c in _custom) {
      c.dispose();
    }
    super.dispose();
  }

  /// 每题都要有答案(选项或自填)才能提交。
  bool get _complete {
    for (var i = 0; i < widget.request.questions.length; i++) {
      if (_picked[i].isEmpty && _custom[i].text.trim().isEmpty) return false;
    }
    return true;
  }

  void _toggle(int q, int option, bool multi) {
    setState(() {
      final picked = _picked[q];
      if (multi) {
        picked.contains(option) ? picked.remove(option) : picked.add(option);
      } else {
        picked
          ..clear()
          ..add(option);
        // 单选题点了选项就收起自填,避免两份答案互相打架。
        if (widget.request.questions[q].options.isNotEmpty) {
          _custom[q].clear();
          _customOpen[q] = false;
        }
      }
    });
    _saveDraft();
  }

  Future<void> _submit() async {
    if (!_complete || _sending) return;
    setState(() => _sending = true);
    final questions = widget.request.questions;
    final answers = [
      for (var i = 0; i < questions.length; i++)
        QuestionAnswer(
          questions[i].id,
          selected: [
            for (var j = 0; j < questions[i].options.length; j++)
              if (_picked[i].contains(j)) questions[i].options[j].label,
          ],
          custom: _custom[i].text.trim().isEmpty ? null : _custom[i].text.trim(),
        ),
    ];
    try {
      await widget.onAnswer(widget.request, answers);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _reject() async {
    final reject = widget.onReject;
    if (_sending || reject == null) return;
    setState(() => _sending = _declining = true);
    try {
      await reject(widget.request);
    } finally {
      if (mounted) setState(() => _sending = _declining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final questions = widget.request.questions;

    const button = Size(0, 44);
    Widget spinner(Color color) => SizedBox.square(
      key: const ValueKey('sending'),
      dimension: 16,
      child: CircularProgressIndicator(strokeWidth: 2, color: color),
    );
    final complete = _complete;
    final submit = FilledButton(
      onPressed: complete && !_sending ? _submit : null,
      style: FilledButton.styleFrom(minimumSize: button, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      child: AnimatedSwitcher(
        duration: AppMotion.of(context, AppMotion.quick),
        child: _sending && !_declining
            ? spinner(theme.colorScheme.onPrimary)
            : Text(l10n.chatSubmit, key: const ValueKey('submit')),
      ),
    );
    return ChatCard(
      icon: AppIcons.question,
      title: questions.length > 1 ? l10n.chatQuestionsTitle(questions.length) : l10n.chatOneQuestion,
      tone: ChatCardTone.ask,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(ChatCard.inset, 4, ChatCard.inset, ChatCard.inset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < questions.length; i++) ...[
                if (i > 0) const SizedBox(height: 24),
                _QuestionBlock(
                  question: questions[i],
                  scheduleAuthorization:
                      widget.request.raw['purpose'] == 'schedule-authorization' &&
                      questions[i].id.startsWith('dsh-go-schedule-authorization-'),
                  index: questions.length > 1 ? i + 1 : null,
                  picked: _picked[i],
                  controller: _custom[i],
                  customOpen: _customOpen[i],
                  enabled: !_sending,
                  onToggle: (option) => _toggle(i, option, questions[i].multiSelect),
                  onToggleCustom: () {
                    setState(() => _customOpen[i] = !_customOpen[i]);
                    _saveDraft();
                  },
                  onTextChanged: () {
                    if (complete != _complete) setState(() {});
                    _saveDraft();
                  },
                ),
              ],
              const SizedBox(height: 16),
              // With a decline: the approval card's pair, mirrored halves.
              if (widget.onReject == null)
                submit
              else
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _sending ? null : _reject,
                        style: OutlinedButton.styleFrom(
                          minimumSize: button,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          side: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.5)),
                        ),
                        child: AnimatedSwitcher(
                          duration: AppMotion.of(context, AppMotion.quick),
                          child: _declining
                              ? spinner(theme.colorScheme.onSurfaceVariant)
                              : Text(l10n.chatDeclineQuestion, key: const ValueKey('decline')),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: submit),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _QuestionBlock extends StatelessWidget {
  const _QuestionBlock({
    required this.question,
    required this.scheduleAuthorization,
    required this.index,
    required this.picked,
    required this.controller,
    required this.customOpen,
    required this.enabled,
    required this.onToggle,
    required this.onToggleCustom,
    required this.onTextChanged,
  });

  final UserQuestion question;
  final bool scheduleAuthorization;
  final int? index;
  final Set<int> picked;
  final TextEditingController controller;
  final bool customOpen;
  final bool enabled;
  final ValueChanged<int> onToggle;
  final VoidCallback onToggleCustom;
  final VoidCallback onTextChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final header = question.header?.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (index != null || (header != null && header.isNotEmpty) || question.multiSelect)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              [
                if (index != null) '$index',
                if (header != null && header.isNotEmpty) header,
                if (question.multiSelect) l10n.chatMultipleChoices,
              ].join(' · '),
              style: AppType.eyebrow(color: dsh.textTertiary),
            ),
          ),
        if (scheduleAuthorization)
          ScheduleQuestionBody(text: question.question)
        else
          Text(question.question, style: theme.textTheme.bodyLarge?.copyWith(color: colors.onSurface, height: 1.5)),
        if (question.detail case final detail? when detail.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: colors.onSurfaceVariant),
              child: MarkdownBody(text: detail.trim(), selectable: false),
            ),
          ),
        const SizedBox(height: 4),
        for (var i = 0; i < question.options.length; i++)
          _OptionRow(
            option: question.options[i],
            selected: picked.contains(i),
            multi: question.multiSelect,
            enabled: enabled,
            onTap: () => onToggle(i),
          ),
        if (question.options.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: enabled ? onToggleCustom : null,
                icon: AnimatedRotation(
                  // ＋ 转 45° 成 ×:同一个图形,不换图标。
                  turns: customOpen ? 0.125 : 0,
                  duration: AppMotion.of(context, AppMotion.standard),
                  curve: AppMotion.std,
                  child: const Icon(AppIcons.add, size: 18),
                ),
                label: Text(l10n.chatCustomAnswer),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 36),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ),
        ExpandReveal(
          open: customOpen,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: 4,
              onChanged: (_) => onTextChanged(),
              decoration: InputDecoration(
                isDense: true,
                hintText: l10n.chatCustomAnswerHint,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 可选中的选项行:选中 = 主色浅底 + 主色细线 + 实心勾;按下轻轻缩放。
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.selected,
    required this.multi,
    required this.enabled,
    required this.onTap,
  });

  final QuestionOption option;
  final bool selected;
  final bool multi;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final fg = selected ? colors.onPrimaryContainer : colors.onSurface;
    final icon = selected
        ? (multi ? AppIcons.checkboxOn : AppIcons.radioOn)
        : (multi ? AppIcons.checkboxOff : AppIcons.radioOff);
    final duration = AppMotion.of(context, AppMotion.quick);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: StreamPress(
        enabled: enabled,
        child: AnimatedContainer(
          duration: duration,
          curve: AppMotion.std,
          decoration: ShapeDecoration(
            color: selected ? colors.primaryContainer : colors.onSurface.withValues(alpha: 0.03),
            shape: Squircle.border(
              12,
              side: BorderSide(
                color: selected ? colors.primary.withValues(alpha: 0.5) : colors.outlineVariant.withValues(alpha: 0.8),
              ),
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            shape: Squircle.border(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: enabled ? onTap : null,
              // 读屏:选中态和单选组读在这一行自己的节点上。
              child: Semantics(
                checked: selected,
                inMutuallyExclusiveGroup: multi ? null : true,
                enabled: enabled,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AnimatedSwitcher(
                        duration: duration,
                        child: Icon(
                          icon,
                          key: ValueKey(selected),
                          size: 20,
                          color: selected ? colors.primary : colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              option.label,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: fg,
                                height: 1.43,
                                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                              ),
                            ),
                            if (option.description case final d? when d.trim().isNotEmpty)
                              Text(
                                d.trim(),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: selected ? colors.onPrimaryContainer : colors.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
