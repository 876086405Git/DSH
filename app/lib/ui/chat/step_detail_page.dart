// Layer 3 of the run information: one step of a turn in full, a tool call's
// arguments and output, or a model request's timing and token use (the
// official trajectory inspector's content, laid out for a phone).

import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/chat_state.dart';
import '../common/app_sheet.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'diff_page.dart';
import 'output_page.dart';
import 'render/ansi_text.dart';
import 'render/code_block.dart';
import 'render/diff_view.dart';
import 'run_info.dart';
import 'tool_view.dart';
import 'trajectory_sheet.dart' show SpanGlyph, measureSpans;
import 'turn_summary.dart';
import 'usage_sheet.dart' show formatTokens;
import 'widgets/live_clock.dart';
import '../common/brief_notice.dart';

/// 显示的输出上限;复制拿到的永远是全文。
const _maxShownChars = 60000;

/// 一步的全貌。模型请求按步号找,工具调用(和它的审批)按 callId 找。
class StepDetailPage extends ConsumerWidget {
  const StepDetailPage({
    super.key,
    required this.sessionId,
    required this.turn,
    required this.kind,
    this.step,
    this.callId,
  });

  final String sessionId;
  final int turn;
  final TraceKind kind;
  final int? step;
  final String? callId;

  static Route<void> route({required String sessionId, required int turn, required TraceSpan span}) =>
      MaterialPageRoute<void>(
        builder: (_) => StepDetailPage(
          sessionId: sessionId,
          turn: turn,
          kind: span.kind == TraceKind.approval ? TraceKind.tool : span.kind,
          step: span.step,
          callId: span.callId,
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final trace = ref.watch(chatProvider(sessionId).select((s) => s.turns.where((t) => t.turn == turn).lastOrNull));
    final items = ref.watch(chatProvider(sessionId).select((s) => s.items));
    final skew = ref.watch(chatProvider(sessionId).select((s) => s.clockSkew));
    if (trace == null) {
      return AppPage(title: l10n.activityStepTitle, slivers: const [_Missing()]);
    }
    if (kind == TraceKind.model) {
      final span = trace.spans.where((s) => s.kind == TraceKind.model && s.step == step).lastOrNull;
      if (span == null) {
        return AppPage(title: l10n.activityStepTitle, slivers: const [_Missing()]);
      }
      final reply = items.whereType<AssistantChatItem>().where((a) => a.seq == span.seq).firstOrNull;
      return _ModelStep(
        sessionId: sessionId,
        trace: trace,
        span: span,
        reply: reply,
        tools: toolsById(items),
        skew: skew,
      );
    }
    final spans = trace.spans.where((s) => s.callId == callId).toList();
    final work = spans.where((s) => s.kind != TraceKind.approval).lastOrNull;
    final wait = spans.where((s) => s.kind == TraceKind.approval).lastOrNull;
    final anchor = work ?? wait;
    if (anchor == null) {
      return AppPage(title: l10n.activityStepTitle, slivers: const [_Missing()]);
    }
    final item = items.whereType<ToolChatItem>().where((t) => t.callId == callId).lastOrNull;
    return _ToolStep(trace: trace, work: work, wait: wait, item: item, span: anchor, skew: skew);
  }
}

class _Missing extends StatelessWidget {
  const _Missing();

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Text(
        context.l10n.activityStepMissing,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: DshColors.of(context).textTertiary),
      ),
    ),
  );
}

// -----------------------------------------------------------------------------
// 工具调用

class _ToolStep extends StatelessWidget {
  const _ToolStep({required this.trace, required this.span, required this.skew, this.work, this.wait, this.item});

  final TurnTrace trace;
  final TraceSpan span;
  final TraceSpan? work;
  final TraceSpan? wait;
  final ToolChatItem? item;
  final Duration skew;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final view = viewOfSpan(span, item);
    final tool = view.item;
    final title = span.kind == TraceKind.question ? l10n.activityStepQuestion : view.verb;
    final status = switch (tool.status) {
      _ when view.phoneResult != null => (
        view.phoneResult!.word,
        view.phoneResult!.isFault ? dsh.danger : dsh.textTertiary,
      ),
      ToolStatus.succeeded => (l10n.activityStepSuccess, dsh.success),
      ToolStatus.failed when view.sandboxBlocked => (l10n.activityStepNeedsPermission, dsh.textTertiary),
      ToolStatus.failed => (l10n.commonFailed, dsh.danger),
      ToolStatus.denied => (l10n.commonDeclined, dsh.warning),
      ToolStatus.cancelled => (l10n.commonCancelled, dsh.textTertiary),
      ToolStatus.awaitingApproval => (l10n.commonWaitingApproval, dsh.warning),
      ToolStatus.streaming || ToolStatus.running => (l10n.commonInProgress, theme.colorScheme.primary),
    };
    final outcome = wait?.outcome;
    final facts = <(String, Widget)>[
      (l10n.activityTools, _mono(context, tool.name)),
      (l10n.commonStatus, Text(status.$1, style: _value(context, status.$2))),
      if (span.dispatched ?? span.start case final at) (l10n.activityStepDispatched, _plain(context, clockTime(at))),
      if (wait case final w?)
        (
          w.open ? l10n.commonWaitingApproval : l10n.activityWaitingApproval,
          _Elapsed(span: w, skew: skew, suffix: outcome == null ? '' : ' · ${approvalLabel(outcome)}', warn: true),
        ),
      if (work case final w?)
        (
          span.kind == TraceKind.question ? l10n.commonWaitingAnswer : l10n.activityStepExecution,
          _Elapsed(span: w, skew: skew, warn: span.kind == TraceKind.question),
        ),
      (l10n.activityStepLocation, _plain(context, l10n.activityStepPosition(trace.turn, span.step))),
    ];

    final sections = <Widget>[FactsCard(facts: facts), ..._toolBody(context, view)];

    return AppPage(
      title: title,
      subtitle: view.summary.isEmpty
          ? null
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SpanGlyph(span: span, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    view.summary,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: view.summaryIsCode
                        ? AppType.mono(size: 13, color: theme.colorScheme.onSurfaceVariant, height: 1.45)
                        : null,
                  ),
                ),
              ],
            ),
      slivers: [
        SliverList.list(
          children: [
            for (final (i, section) in sections.indexed) ...[if (i > 0) const SizedBox(height: 12), section],
          ],
        ),
      ],
    );
  }

  List<Widget> _toolBody(BuildContext context, ToolView view) {
    final l10n = context.l10n;
    final tool = view.item;
    final out = <Widget>[];
    final args = tool.arguments.trim();
    if (args.isNotEmpty && args != '{}') {
      final pretty = prettyJson(tool.arguments);
      out.add(
        CodeSection(
          title: l10n.activityStepArguments,
          copyText: pretty,
          action: _viewAll(context, l10n.activityStepArguments, pretty),
          child: _wellText(context, pretty),
        ),
      );
    }
    if (tool.status == ToolStatus.succeeded) {
      if (view.diff case final lines? when lines.isNotEmpty) {
        final change = fileChangesOf([tool]).firstOrNull;
        out.add(
          CodeSection(
            title: l10n.activityStepChanges,
            copyText: change?.patch ?? lines.map((l) => l.text).join('\n'),
            action: change == null
                ? null
                : (l10n.activityStepFullScreen, () => Navigator.of(context).push(ChangeDiffPage.route([change]))),
            child: DiffView(lines: lines, embedded: true),
          ),
        );
      } else if (view.readWindow case final window?) {
        out.add(
          CodeSection(
            title: l10n.activityStepReadContent,
            copyText: window.code,
            child: CodeBlock(
              code: window.code,
              language: window.language,
              showLineNumbers: true,
              firstLineNumber: window.firstLine,
              embedded: true,
            ),
          ),
        );
      } else if (view.writtenContent case final content? when content.isNotEmpty) {
        out.add(
          CodeSection(
            title: l10n.activityStepWrittenContent,
            copyText: content,
            child: CodeBlock(
              code: content,
              language: view.path == null ? null : languageForPath(view.path!),
              showLineNumbers: true,
              embedded: true,
            ),
          ),
        );
      }
    }
    final result = tool.resultText.trimRight();
    if (result.isNotEmpty) {
      // A phone tool's reported outcome that isn't a fault (HarmonyOS) isn't an error.
      final fault = view.phoneResult?.isFault ?? true;
      final title = tool.status == ToolStatus.failed && fault
          ? l10n.activityStepError
          : view.isTerminal
          ? l10n.activityOutput
          : l10n.activityStepResult;
      final color = tool.status == ToolStatus.failed && !view.sandboxBlocked && fault
          ? DshColors.of(context).danger
          : null;
      out.add(
        CodeSection(
          title: title,
          copyText: result,
          action: _viewAll(context, title, result, ansi: true, color: color),
          child: _wellText(context, result, ansi: true, color: color),
        ),
      );
    } else if (tool.failure case final failure?) {
      out.add(
        CodeSection(
          title: l10n.activityStepError,
          copyText: failure.reason ?? failure.code,
          child: _wellText(
            context,
            '${failure.name} · ${failure.code}'
            '${failure.reason == null ? '' : '\n${failure.reason}'}',
            color: DshColors.of(context).danger,
          ),
        ),
      );
    } else if (!view.isActive) {
      out.add(
        CodeSection(
          title: l10n.activityStepResult,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Text(
              tool.status == ToolStatus.denied ? l10n.activityStepDeclined : l10n.activityStepNoOutput,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
            ),
          ),
        ),
      );
    }
    return out;
  }
}

// -----------------------------------------------------------------------------
// 模型请求

class _ModelStep extends StatelessWidget {
  const _ModelStep({
    required this.sessionId,
    required this.trace,
    required this.span,
    required this.tools,
    required this.skew,
    this.reply,
  });

  final String sessionId;
  final TurnTrace trace;
  final TraceSpan span;
  final AssistantChatItem? reply;
  final Map<String, ToolChatItem> tools;
  final Duration skew;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final label = spanLabel(span);
    final usage = span.usage;
    final speed = span.tokensPerSecond;
    final timing = <(String, Widget)>[
      (l10n.activityStepStart, _plain(context, clockTime(span.start))),
      (l10n.activityDuration, _Elapsed(span: span, skew: skew)),
      if (span.ttft case final t?) (l10n.activityFirstToken, _measure(context, formatSpan(t))),
      if (!span.open)
        if (span.decoding case final d?) (l10n.activityStepGeneration, _measure(context, formatSpan(d))),
      if (speed != null)
        (
          l10n.activityStepSpeed,
          _measure(context, l10n.activityStepTokenSpeed(speed.toStringAsFixed(speed < 10 ? 1 : 0))),
        ),
      if (span.retries > 0)
        (
          l10n.commonRetry,
          Text(
            [l10n.activityStepRetryCount(span.retries), ...span.retryFailures.take(2)].join(' · '),
            style: _value(context, dsh.warning),
          ),
        ),
      if (span.model case final model?) (l10n.activityModel, _mono(context, model)),
      (l10n.activityStepLocation, _plain(context, l10n.activityStepPosition(trace.turn, span.step))),
    ];

    final sections = <Widget>[FactsCard(title: l10n.activityStepTiming, facts: timing)];
    if (usage != null) {
      final input = usage.inputTokens + (usage.cacheReadTokens ?? 0) + (usage.cacheWriteTokens ?? 0);
      final reasoning = usage.reasoningTokens;
      sections.add(
        FactsCard(
          title: l10n.activityUsage,
          facts: [
            (l10n.activityInput, _measure(context, formatTokens(input))),
            (l10n.activityStepCacheHit, _measure(context, formatTokens(usage.cacheReadTokens ?? 0))),
            (l10n.activityStepCacheMiss, _measure(context, formatTokens(usage.inputTokens))),
            if ((usage.cacheWriteTokens ?? 0) > 0)
              (l10n.activityStepCacheWrite, _measure(context, formatTokens(usage.cacheWriteTokens!))),
            (l10n.activityOutput, _measure(context, formatTokens(usage.outputTokens))),
            if (reasoning != null && reasoning > 0) ...[
              (l10n.activityStepReasoning, _measure(context, formatTokens(reasoning))),
              (
                l10n.activityStepAnswer,
                _measure(context, formatTokens((usage.outputTokens - reasoning).clamp(0, 1 << 31))),
              ),
            ],
          ],
        ),
      );
    }
    final reasoningText = reply?.reasoning.trim() ?? '';
    if (reasoningText.isNotEmpty) {
      sections.add(
        CodeSection(
          title: l10n.activityStepThinking,
          copyText: reasoningText,
          prose: true,
          child: _prose(context, reasoningText, muted: true),
        ),
      );
    }
    final text = reply?.text.trim() ?? '';
    if (text.isNotEmpty) {
      sections.add(
        CodeSection(
          title: span.toolCalls > 0 ? l10n.activityStepExplanation : l10n.commonReply,
          copyText: text,
          prose: true,
          child: _prose(context, text),
        ),
      );
    }
    final calls = [
      for (final s in trace.spans)
        if (s.step == span.step && s.kind != TraceKind.model && s.kind != TraceKind.approval) s,
    ];
    if (calls.isNotEmpty) {
      sections.add(
        SheetGroup(
          title: l10n.activityStepToolCalls,
          margin: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
          children: [
            for (final call in calls)
              _CallRow(
                span: call,
                tool: tools[call.callId],
                onTap: () =>
                    Navigator.of(context)
                        .push(StepDetailPage.route(sessionId: sessionId, turn: trace.turn, span: call)),
              ),
          ],
        ),
      );
    }

    return AppPage(
      title: label.title,
      subtitle: Text(
        span.open
            ? l10n.activityStepProcessing
            : (label.detail.isEmpty
                  ? l10n.activityStepModelRequest
                  : l10n.activityStepModelRequestDetail(label.detail)),
        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      slivers: [
        SliverList.list(
          children: [
            for (final (i, section) in sections.indexed) ...[if (i > 0) const SizedBox(height: 12), section],
          ],
        ),
      ],
    );
  }

  Widget _prose(BuildContext context, String text, {bool muted = false}) {
    final theme = Theme.of(context);
    final shown = text.length > _maxShownChars ? '${text.substring(0, _maxShownChars)}\n…' : text;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: SelectableText(
        shown,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: muted ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.onSurface,
          height: 1.6,
        ),
      ),
    );
  }
}

class _CallRow extends StatelessWidget {
  const _CallRow({required this.span, required this.onTap, this.tool});

  final TraceSpan span;
  final ToolChatItem? tool;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final label = spanLabel(span, tool);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            SpanGlyph(span: span, size: 24),
            const SizedBox(width: 8),
            Text(label.title, style: theme.textTheme.bodyMedium),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label.detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: label.detailIsCode
                    ? AppType.mono(size: 12, color: dsh.textTertiary, height: 1.3)
                    : theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
              ),
            ),
            if (span.duration case final d?) ...[
              const SizedBox(width: 8),
              Text(
                formatSpan(d),
                style: AppType.tabular(
                  theme.textTheme.labelSmall!.copyWith(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
            Icon(AppIcons.disclosure, size: 18, color: dsh.textTertiary),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 共用件

/// `15:20:31`(本地时间)。
String clockTime(DateTime t) {
  final local = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

/// 审批答复的人话。
String approvalLabel(ApprovalOutcome outcome) => switch (outcome) {
  ApprovalOutcome.allowedOnce => appL10n.activityApprovalAllowed,
  ApprovalOutcome.rejected => appL10n.commonDeclined,
  ApprovalOutcome.cancelled => appL10n.commonCancelled,
  ApprovalOutcome.unavailable => appL10n.activityApprovalUnanswered,
  ApprovalOutcome.unknown => appL10n.activityApprovalAnswered,
};

/// JSON 原文缩进排好;不是 JSON 时原样。
String prettyJson(String raw) {
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
  } on FormatException {
    return raw;
  }
}

TextStyle? _value(BuildContext context, [Color? color]) => AppType.tabular(
  Theme.of(context).textTheme.bodyMedium!.copyWith(color: color ?? Theme.of(context).colorScheme.onSurface),
);

Widget _plain(BuildContext context, String text) => Text(text, style: _value(context));

/// 度量值(时长、token 数、速度):数字等宽,单位小一号、次级色。
Widget _measure(BuildContext context, String text) => Text.rich(
  TextSpan(children: measureSpans(text, _value(context)!, unitColor: Theme.of(context).colorScheme.onSurfaceVariant)),
);

Widget _mono(BuildContext context, String text) => SelectableText(
  text,
  style: AppType.mono(
    size: 13,
    color: Theme.of(context).colorScheme.onSurface,
    // 与左边标签(bodyMedium 14 / 1.55)同一个行高,首行文字对齐。
    height: 14 * 1.55 / 13,
  ),
);

/// 被 [_wellText] 截断的一段,在段头给一个进全文页的入口;没截断就没有。
(String, VoidCallback)? _viewAll(BuildContext context, String title, String text, {bool ansi = false, Color? color}) {
  if (text.length <= _maxShownChars) return null;
  return (
    context.l10n.chatOutputViewAll,
    () => Navigator.of(context).push(OutputPage.route(title: title, text: text, ansi: ansi, color: color)),
  );
}

Widget _wellText(BuildContext context, String text, {bool ansi = false, Color? color}) {
  final dsh = DshColors.of(context);
  final shown = text.length > _maxShownChars
      ? context.l10n.activityStepTruncated(text.substring(0, _maxShownChars), _maxShownChars ~/ 1000)
      : text;
  final style = AppType.mono(size: 12.5, color: color ?? dsh.codeWellFg, height: 1.55);
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
    child: SizedBox(
      width: double.infinity,
      child: ansi ? AnsiText(text: shown, style: style) : SelectableText(shown, style: style),
    ),
  );
}

/// 进行中的段落走秒,结束的写死。
class _Elapsed extends StatelessWidget {
  const _Elapsed({required this.span, required this.skew, this.suffix = '', this.warn = false});

  final TraceSpan span;
  final Duration skew;
  final String suffix;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final color = warn ? DshColors.of(context).warning : null;
    final duration = span.duration;
    if (duration != null) {
      return Text.rich(
        TextSpan(
          children: [
            ...measureSpans(formatSpan(duration), _value(context, color)!),
            if (suffix.isNotEmpty) TextSpan(text: suffix),
          ],
        ),
        style: _value(context, color),
      );
    }
    return LiveElapsed(
      since: span.start,
      skew: skew,
      builder: (context, elapsed) =>
          Text(l10n.activityStepLiveElapsed(formatClock(elapsed!), suffix), style: _value(context, color)),
    );
  }
}

/// 一组"名称 — 值"的事实,一块玻璃卡。
class FactsCard extends StatelessWidget {
  const FactsCard({super.key, required this.facts, this.title});

  final List<(String, Widget)> facts;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return SheetGroup(
      title: title,
      margin: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
      children: [
        for (final (label, value) in facts)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // A leading space marks a part of the row above: indented,
                // quieter.
                if (label.startsWith(' ')) const SizedBox(width: 16),
                SizedBox(
                  width: label.startsWith(' ') ? 64 : 80,
                  child: Text(
                    label.trimLeft(),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: label.startsWith(' ') ? dsh.textTertiary : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(child: value),
              ],
            ),
          ),
      ],
    );
  }
}

/// 带标题、复制键的一块代码井(参数、输出、diff)。[prose] 时铺成普通卡片。
class CodeSection extends StatelessWidget {
  const CodeSection({
    super.key,
    required this.title,
    required this.child,
    this.copyText,
    this.action,
    this.prose = false,
  });

  final String title;
  final Widget child;
  final String? copyText;
  final (String, VoidCallback)? action;
  final bool prose;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final dsh = DshColors.of(context);
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: AppType.eyebrow(color: dsh.textTertiary).copyWith(fontSize: 11)),
          ),
          if (action case (final label, final onTap)) TextButton(onPressed: onTap, child: Text(label)),
          if (copyText case final text?)
            IconButton(
              tooltip: l10n.activityStepCopySection(title),
              iconSize: 18,
              style: IconButton.styleFrom(minimumSize: const Size(40, 40), foregroundColor: dsh.textTertiary),
              onPressed: () async {
                final messenger = ScaffoldMessenger.maybeOf(context);
                HapticFeedback.lightImpact();
                await Clipboard.setData(ClipboardData(text: text));
                messenger?.showBriefNotice(l10n.activityStepCopiedSection(title));
              },
              icon: const Icon(AppIcons.copy),
            ),
        ],
      ),
    );
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [header, child],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
      child: prose
          ? GlassSurface(tier: GlassTier.card, borderRadius: AppShape.radiusLg, child: body)
          : DecoratedBox(
              // 与上面的事实卡同一圆角(20):整页的块是一家。
              decoration: ShapeDecoration(
                color: dsh.codeWellBg,
                shape: RoundedSuperellipseBorder(
                  borderRadius: AppShape.radiusLg,
                  side: BorderSide(color: dsh.codeWellBorder, width: 0.5),
                ),
              ),
              child: Squircle.clip(radius: AppShape.lg, child: body),
            ),
    );
  }
}
