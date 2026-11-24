// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:async';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart' show CotTranslationLimits;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/cot_translation_state.dart';
import '../../../state/sessions_state.dart';
import '../../common/expand_reveal.dart';
import '../../common/pressable.dart';
import '../../common/smooth_size.dart';
import '../../common/think_glyph.dart';
import '../../engine_settings/engine_settings_page.dart' show openSettingsPage;
import '../../fx/orbs/thinking_orb.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../render/markdown_body.dart';
import 'stream_pacer.dart';
import 'stream_row.dart';

/// 思考过程:**和工具行同一套解剖的一行**。
///
/// ```
/// ⚛ 思考中                                  ⌄   ← 轨道在转,下面是实时窗口
/// │ 正在写的一段话,自然折行,一行接一行往上走     ← 最多三行,只跟最新的字
/// ⚛ 思考 · 用户想把工具调用折叠起来…          ⌄   ← 结束后收起:预览全文首行
/// │ 全文(次级排版)
/// ```
///
/// 流式思考时下面是一段**最多三行的连续文字**:跟着最新写出来的字走,写满
/// 一行就轻轻往上滑一行,高度固定,列表不会因为思考长了几行而跳。点这一行
/// 展开全文,再点收回三行;一轮结束后手动展开的全文也自动收回去。
///
/// 实时窗口和全文**共用同一个槽**:同一时刻只有一块内容,切换时不会一段
/// 淡出、一段淡入地叠在一起。
///
/// 图形块是品牌蓝(思考是 DeepSeek 的品牌时刻),其余都是过程行的次级色。
///
/// 收起时的行内预览照官方 Web:完成后取全文第一行,都去掉 `**`。展开是
/// 次级排版的 Markdown。
///
/// 引擎开着「思考过程机器翻译」插件时,展开的全文上方多一颗「翻译」:
/// 译文就地替换原文,随时「查看原文」切回去(官方 cot-translation 的行为)。
/// DeepSeek 品牌蓝(与鲸尾同色)。
const _brandBlue = Color(0xFF4D6BFE);

class ThinkingPill extends StatefulWidget {
  const ThinkingPill({
    super.key,
    required this.reasoning,
    this.active = false,
    this.streaming = false,
    this.growIn = false,
    this.meta,
  });

  final String reasoning;

  /// Shown after the label, as a role-play shows how long it has thought.
  final Widget? meta;

  /// 模型此刻还在思考(流式中且正文还没开始)。
  final bool active;

  /// 这条回复还在流式输出:一轮(streaming 结束)时把展开的全文收回去。
  final bool streaming;

  /// 接在等待的三个点后面出现:三行实时窗口从 0 长出来,而不是一帧多出来 ——
  /// 这一行的高度三个点已经占好了,窗口没法提前占。
  final bool growIn;

  @override
  State<ThinkingPill> createState() => _ThinkingPillState();
}

/// 收起时的一行预览(官方 ReasoningRow 的规则):全文第一行,去掉 `**`。
String thinkingPreview(String text) => _firstLine(text).replaceAll('**', '').trim();

String _firstLine(String text) {
  final trimmed = text.trimLeft();
  final newline = trimmed.indexOf('\n');
  return newline == -1 ? trimmed : trimmed.substring(0, newline);
}

class _ThinkingPillState extends State<ThinkingPill> {
  bool _expanded = false;

  /// Reasoning can grow while all four inputs to the header stay the same.
  (bool, bool, String, Widget?)? _headerInputs;
  late Widget _header;

  /// 收起动画期间还要画的那块内容:收起时它已经不该在树上了,但高度收回
  /// 去的过程里得先留着,不能啪地消失留下一块空白。
  Widget? _body;

  /// 译文与"看译文还是原文":收起再展开也还在。
  final _translation = _TranslationHolder();

  /// 第一帧窗口先关着,下一帧打开,[ExpandReveal] 才有得展开。
  late bool _windowHeld = widget.growIn;

  @override
  void initState() {
    super.initState();
    if (!_windowHeld) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _windowHeld = false);
    });
  }

  @override
  void didUpdateWidget(ThinkingPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 一轮结束:过程收进摘要,亲手展开的全文也不留在外面。
    if (oldWidget.streaming && !widget.streaming) _expanded = false;
  }

  @override
  void dispose() {
    _translation.dispose();
    super.dispose();
  }

  Widget _buildHeader(BuildContext context, String preview) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    // 深色底上品牌蓝提一档亮度,图形才不发闷。
    final brand = dark ? Color.lerp(_brandBlue, Colors.white, 0.3)! : _brandBlue;
    final active = widget.active;
    final detail = StreamRow.detail(context);

    final header = Row(
      children: [
        SizedBox.square(
          dimension: StreamRow.lead,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: brand.withValues(alpha: dark ? 0.18 : 0.10),
              shape: Squircle.border(StreamRow.lead * 0.32),
            ),
            child: Center(
              // 思考中是一颗慢慢变形的点阵小光球(Libraries.dev 思考光球),想完换回静止的图形
              // (和标签一样直接换,不叠着淡入淡出)。
              child: active
                  ? ThinkingOrb(state: OrbState.breathing, size: OrbSize.px20, displaySize: 18, ink: OrbInk.tint(brand))
                  : ThinkGlyph(size: 15, color: brand),
            ),
          ),
        ),
        const SizedBox(width: StreamRow.gap),
        // 标签直接换字,不做淡入淡出:两个词叠在同一个位置上闪一下更乱。
        ThinkingLabel(active ? l10n.chatThinkingActive : l10n.chatThinking, active: active),
        ?widget.meta,
        if (preview.isNotEmpty) ...[
          const StreamDot(),
          Expanded(
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) => LinearGradient(
                colors: const [Colors.black, Colors.transparent],
                stops: [((rect.width - 40) / rect.width).clamp(0.0, 1.0), 1],
              ).createShader(rect),
              child: Text(preview, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: detail),
            ),
          ),
        ] else
          const Spacer(),
        const SizedBox(width: 4),
        StreamChevron(open: _expanded),
      ],
    );

    return Semantics(
      button: true,
      expanded: _expanded,
      child: StreamRowFrame(onTap: () => setState(() => _expanded = !_expanded), child: header),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    final open = active || _expanded;
    final preview = open ? '' : thinkingPreview(widget.reasoning);
    final heading = (active, _expanded, preview, widget.meta);
    if (heading != _headerInputs) {
      _headerInputs = heading;
      _header = Builder(builder: (context) => _buildHeader(context, preview));
    }

    Widget reasoningBody() {
      if (!_expanded) return ThinkingTicker(text: widget.reasoning);
      // 展开后,点正文本身和点头部一样收起。只在展开态挂这层手势:实时窗口
      // 还要能长按选字/随列表滚动,不该多一个点击目标。
      void collapse() => setState(() => _expanded = false);
      return _hasProviderScope(context)
          ? _TranslatableReasoning(
              text: widget.reasoning.trim(),
              active: active,
              holder: _translation,
              onBodyTap: collapse,
            )
          : _CollapsibleReasoningBody(
              onCollapse: collapse,
              child: MarkdownBody(text: widget.reasoning.trim(), streaming: active, secondary: true, selectable: false),
            );
    }

    // 实时窗口和展开的全文共用同一个槽:同一时刻只画一块内容。两块各自
    // 做动画会一段淡出、一段淡入,两段文字叠在一起闪。
    if (open) {
      _body = SmoothSize(
        // 流式思考的块高按行瞬长。高度再做一次动画会和文字上滑、列表追底叠在
        // 一起 —— 文字越快，看起来越像在上下抖。展开全文、收起时才要动画。
        duration: active && !_expanded ? Duration.zero : AppMotion.of(context, AppMotion.quick),
        alignment: AlignmentDirectional.topCenter,
        child: StreamThread(
          child: Padding(padding: const EdgeInsets.only(top: 4, bottom: 8), child: reasoningBody()),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _header,
        // 一个槽:思考中是实时窗口,点开换成全文,一轮结束收起。
        ExpandReveal(open: open && !_windowHeld, child: _body ?? const SizedBox.shrink()),
      ],
    );
  }
}

/// 思考行的标签。思考中一道亮度慢慢扫过文字:只在标签的灰和正文的深之间走,
/// 不换颜色、不位移。
///
/// 节奏照 OpenAI 公开的 Codex 说明(和它的桌面端一致):开始思考 [lead] 后第一次,
/// 每次扫 [sweep],每 [period] 一次。其余时间控制器是停的,标签不重绘,也不挂
/// [ShaderMask]。屏幕上同一时刻只扫一条:后开始思考的那条接过去。系统关了动画
/// 就是静止的字。
///
/// 一起动的还有转圈的图形和滚动的实时窗口。三样同时抢眼就廉价了:窗口是信息,
/// 不能动它;这道扫光是这一行的主角;图形退一步,转得很慢(见 [ThinkGlyph])。
class ThinkingLabel extends StatefulWidget {
  const ThinkingLabel(this.text, {super.key, this.active = false});

  final String text;
  final bool active;

  static const lead = Duration(milliseconds: 600);
  static const sweep = Duration(seconds: 1);
  static const period = Duration(seconds: 4);

  @override
  State<ThinkingLabel> createState() => _ThinkingLabelState();
}

class _ThinkingLabelState extends State<ThinkingLabel> with SingleTickerProviderStateMixin {
  /// 现在归谁扫。
  static _ThinkingLabelState? _owner;

  AnimationController? _sweep;
  Timer? _timer;

  void _sync() {
    final run = widget.active && !AppMotion.reduced(context);
    if (run == (_timer != null)) return;
    if (run) {
      _sweep ??= AnimationController(vsync: this, duration: ThinkingLabel.sweep);
      _timer = Timer(ThinkingLabel.lead, () {
        _timer = Timer.periodic(ThinkingLabel.period, (_) => _play());
        // 在计时器里接手,不在 build 里:停别人的控制器会标脏别人的子树。
        _owner?._sweep?.reset();
        _owner = this;
        _play();
      });
    } else {
      _timer?.cancel();
      _timer = null;
      _sweep?.reset();
      _release();
    }
  }

  void _play() {
    // 接手的那条结束了,轮到还在思考的这条。
    _owner ??= this;
    if (identical(_owner, this)) _sweep!.forward(from: 0);
  }

  void _release() {
    if (identical(_owner, this)) _owner = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ThinkingLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _sync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sweep?.dispose();
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = StreamRow.label(context);
    final label = Text(widget.text, style: style);
    final sweep = _sweep;
    if (sweep == null || _timer == null) return label;
    final muted = style?.color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    final bright = Theme.of(context).colorScheme.onSurface;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: sweep,
        child: label,
        builder: (context, child) {
          if (!sweep.isAnimating) return child!;
          return ShaderMask(
            blendMode: BlendMode.srcIn,
            // 亮带和标签一样宽,从标签左外走到右外:两头都是静止时的颜色,起止不跳。
            shaderCallback: (rect) =>
                LinearGradient(colors: [muted, bright, muted])
                    .createShader(Rect.fromLTWH((2 * sweep.value - 1) * rect.width, 0, rect.width, rect.height)),
            child: child,
          );
        },
      ),
    );
  }
}

/// 展开的全文:整块正文都是收起的落点,等价于再点一次头部。
///
/// 包法有讲究:正文自带文本选择([MarkdownBody] 的 `selectable`),而选择区
/// 自己装了一个 tap 手势,并且比外层包装更先摸到指针 —— 直接把手势包在选择
/// 区外面,单击会被选择区吃掉。所以这里让正文**不带**选择区,由本层把
/// [SelectionArea] 套在收起手势的外面:收起的单击更靠里,先赢;正文里的
/// 链接、代码复制按钮在更里层,仍然各自优先;长按选词、横向滑动交给选择区
/// 和滚动自己判定。
class _CollapsibleReasoningBody extends StatelessWidget {
  const _CollapsibleReasoningBody({required this.onCollapse, required this.child});

  final VoidCallback onCollapse;
  final Widget child;

  @override
  Widget build(BuildContext context) => SelectionArea(
    child: Semantics(
      button: true,
      hint: context.l10n.commonCollapse,
      onTap: onCollapse,
      child: GestureDetector(
        // 正文不满一行时右侧留白也算正文:点那儿也该收起。
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: onCollapse,
        child: child,
      ),
    ),
  );
}

/// 流式思考的实时窗口:一段**连续的文字**,窗口恒高三行,写出来的字从底部
/// 进来,写满一行整段匀速往上滑一行。不拆行、不做逐行动效 —— 相邻两帧不会
/// 各画一份文字叠在一起,读的时候也不用横着找。
///
/// 块高从头到尾不变:流式期间列表不会一行一行地追底,写得再快也不会抖。
/// 不足三行时文字贴在窗口顶上,后面空着,写满就自然开始往上走。
class ThinkingTicker extends StatelessWidget {
  const ThinkingTicker({super.key, required this.text});

  final String text;

  /// 窗口行数(TUI 的 PREVIEW_ROWS)。
  static const rows = 3;

  @override
  Widget build(BuildContext context) {
    if (AppMotion.fluid(context)) return _FluidTicker(text: text);
    final style = StreamRow.detail(context);
    final scaler = MediaQuery.textScalerOf(context);
    final lineHeight = scaler.scale(style?.fontSize ?? 13) * (style?.height ?? 1.3);
    final shown = thinkingTickerText(text);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // 量一遍:窗口高度取「内容高度」和「三行」的较小值。
        final painter = TextPainter(
          text: TextSpan(text: shown, style: style),
          textDirection: Directionality.of(context),
          textScaler: scaler,
        )..layout(maxWidth: width);
        final textHeight = painter.height;
        // 每次发布都量一遍:排版对象持有原生资源,不能等 GC。
        painter.dispose();
        final window = lineHeight * ThinkingTicker.rows;
        // 恒高三行:流式期间块高不变,列表就不会一行一行地追底,快写时也不抖。
        final height = window;
        // 多出来的部分往上推,露出来的永远是最后三行。写满一行时目标只
        // 挪一行,由 AnimatedContainer 平滑推上去 —— 不换内容、不叠字。
        final shift = (textHeight - window).clamp(0.0, double.infinity);
        return SizedBox(
          width: width,
          height: height,
          child: ClipRect(
            child: AnimatedContainer(
              duration: AppMotion.of(context, AppMotion.quick),
              // 匀速上移:每次换行都重新给目标，缓动会在每一行开头重新缓起、结尾
              // 重新缓停，连起来就是一顿一顿的。
              curve: Curves.linear,
              transform: Matrix4.translationValues(0, -shift, 0),
              child: OverflowBox(
                alignment: AlignmentDirectional.topStart,
                minHeight: 0,
                maxHeight: double.infinity,
                child: SizedBox(
                  width: width,
                  child: Text(shown, style: style),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 实时窗口里显示的文字:去掉加粗标记、压掉空行、掐掉首尾空白。
///
/// 只留最后一段:更早的字在窗口外,不必参与排版(思考再长也不会拖慢每帧)。
String thinkingTickerText(String text) {
  var tail = text.trimRight();
  if (tail.length > _tickerChars) tail = tail.substring(tail.length - _tickerChars);
  return tail.replaceAll('**', '').replaceAll(_blankRun, '\n').trimLeft();
}

/// 尾部最多排这么多字。
const _tickerChars = 2000;

/// The fluid window's text. [thinkingTickerText] drops a character off the front for
/// every new one, and past [_tickerChars] that rewraps everything on every update. Here
/// the cut stands still for [_fluidCutStep] characters, and lands on a line break when
/// there is one, so the last lines keep their wrapping.
@visibleForTesting
String fluidTickerText(String text) {
  var tail = text.trimRight();
  if (tail.length > _tickerChars) {
    var cut = ((tail.length - _tickerChars) ~/ _fluidCutStep + 1) * _fluidCutStep;
    cut = math.min(cut, tail.length);
    final breakAt = tail.indexOf('\n', cut);
    if (breakAt >= 0 && breakAt - cut < _fluidCutStep) cut = breakAt + 1;
    tail = tail.substring(cut);
  }
  return tail.replaceAll('**', '').replaceAll(_blankRun, '\n').trimLeft();
}

const _fluidCutStep = 600;

/// [ThinkingTicker] on the fluid tier: the same three-line window, in continuous
/// motion. What made the plain one stutter: text arrives in lumps, each new line starts
/// its own 160ms move and then stops dead, and a long thought rewraps on every update.
///
/// Here the text is paced ([StreamPacer]), and the window holds the text by its bottom
/// edge: a new line only adds to how far the text still has to rise, and that distance
/// is worked off at a speed matched to how fast lines are coming. Between updates only
/// a transform changes; the text isn't laid out again. Lines leave through a soft edge.
class _FluidTicker extends StatefulWidget {
  const _FluidTicker({required this.text});

  final String text;

  @override
  State<_FluidTicker> createState() => _FluidTickerState();
}

class _FluidTickerState extends State<_FluidTicker> with SingleTickerProviderStateMixin {
  /// Text to show at most this often; the motion in between runs every frame.
  static const _publishEvery = 1 / 30;
  static const _minSettle = 0.09;
  static const _maxSettle = 0.45;

  late final Ticker _ticker = createTicker(_tick);
  // Not lazily: made at the first growth, it would take that growth as already shown.
  late final StreamPacer _pacer;

  /// How far the text still has to rise. Only ever a transform.
  final _behind = ValueNotifier(0.0);
  final _painter = TextPainter();
  late String _shown = fluidTickerText(widget.text);

  Duration _last = Duration.zero;
  double _sincePublish = 0;
  double _height = -1;
  double _width = -1;
  double _lineHeight = -1;
  double _sinceLine = 1;

  /// How long the last lines took to come: what the rise is paced by.
  double _settle = 0.2;

  @override
  void initState() {
    super.initState();
    _pacer = StreamPacer(shown: widget.text.length);
    PaintingBinding.instance.systemFonts.addListener(_painter.markNeedsLayout);
  }

  @override
  void didUpdateWidget(_FluidTicker old) {
    super.didUpdateWidget(old);
    if (!widget.text.startsWith(old.text)) {
      _pacer.reset(widget.text.length);
      _shown = fluidTickerText(widget.text);
      // Different text, not more of it: nothing to rise.
      _height = -1;
    }
    if (!_ticker.isActive) {
      _last = Duration.zero;
      unawaited(_ticker.start());
    }
  }

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(_painter.markNeedsLayout);
    _painter.dispose();
    _ticker.dispose();
    _behind.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final seconds = (elapsed - _last).inMicroseconds / Duration.microsecondsPerSecond;
    _last = elapsed;
    _sinceLine += seconds;
    final wasCaughtUp = _pacer.caughtUp(widget.text.length);
    _pacer.advance(seconds, widget.text.length);
    _sincePublish += seconds;
    final behind = _behind.value;
    if (behind > 0.1) {
      _behind.value = behind * math.exp(-seconds / _settle);
    } else if (behind != 0) {
      _behind.value = 0;
    }
    // The last of it goes out at once: the ticker is about to stop.
    if (_sincePublish >= _publishEvery || _pacer.caughtUp(widget.text.length)) {
      _sincePublish = 0;
      if (!wasCaughtUp) {
        final next = fluidTickerText(widget.text.substring(0, _pacer.shown));
        if (next != _shown) setState(() => _shown = next);
      }
    }
    if (_pacer.caughtUp(widget.text.length) && _behind.value == 0) _ticker.stop();
  }

  /// Text height at [width], with what growing by a line means for the motion.
  double _measure(TextStyle? style, TextScaler scaler, double width, double lineHeight, double window, String text) {
    // Kept across builds: an arrival rebuilds before the shown text changes, and then
    // the painter hands back its last layout.
    _painter
      ..text = TextSpan(text: text, style: style)
      ..textDirection = Directionality.of(context)
      ..textScaler = scaler
      ..layout(maxWidth: width);
    final height = _painter.height;
    // Only what goes past the window has to rise: below that the text grows into the
    // space it has, and any distance saved up would jump when the window fills.
    final past = math.max(_height, window);
    // A wider line or larger type grows the text too, but that isn't a new line.
    if (_width == width && _lineHeight == lineHeight && _height >= 0 && height > past) {
      final added = height - past;
      if (added < lineHeight * 3) {
        _settle = (0.5 * _settle + 0.5 * _sinceLine * 0.5).clamp(_minSettle, _maxSettle);
        _sinceLine = 0;
      }
      // Set during build for the transform below it: nothing has painted yet. A big lump
      // rises too, from no further down than the window is tall.
      _behind.value = math.min(_behind.value + added, window);
    }
    _height = height;
    _width = width;
    _lineHeight = lineHeight;
    return height;
  }

  @override
  Widget build(BuildContext context) {
    final style = StreamRow.detail(context);
    final scaler = MediaQuery.textScalerOf(context);
    final lineHeight = scaler.scale(style?.fontSize ?? 13) * (style?.height ?? 1.3);
    final window = lineHeight * ThinkingTicker.rows;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = _measure(style, scaler, width, lineHeight, window, _shown);
        final overflows = height > window;
        final text = OverflowBox(
          // Short of a full window it starts at the top; past that, by the bottom edge.
          alignment: overflows ? AlignmentDirectional.bottomStart : AlignmentDirectional.topStart,
          minHeight: 0,
          maxHeight: double.infinity,
          child: SizedBox(
            width: width,
            child: Text(_shown, style: style),
          ),
        );
        return SizedBox(
          width: width,
          height: window,
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) {
              final soft = overflows ? (lineHeight * 0.7 / rect.height).clamp(0.0, 0.5) : 0.0;
              return LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: const [Color(0x00000000), Color(0xFF000000)],
                stops: [0, soft == 0 ? 0.001 : soft],
              ).createShader(rect);
            },
            child: ClipRect(
              child: ValueListenableBuilder<double>(
                valueListenable: _behind,
                child: text,
                // Under a full window the text is just growing downward: nothing to rise.
                builder: (context, behind, child) =>
                    Transform.translate(offset: Offset(0, overflows ? behind : 0), child: child),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 连着几个空行压成一个。
final _blankRun = RegExp(r'\n[ \t]*(\n[ \t]*)+');

/// Golden and geometry tests pump the pill without a ProviderScope; there is
/// no engine to ask then, so the plain text shows.
bool _hasProviderScope(BuildContext context) {
  try {
    ProviderScope.containerOf(context, listen: false);
    return true;
  } on StateError {
    return false;
  }
}

/// 一段思考的翻译状态,挂在 [_ThinkingPillState] 上(展开区收起时子树会被
/// 拿掉,译文不能跟着丢)。
class _TranslationHolder {
  ReasoningTranslation? controller;

  /// [controller] 开始翻译时的界面语言;界面语言一变,旧译文就不再沿用。
  String? language;

  /// 正在看译文(false = 用户切回了原文)。
  bool showTranslation = false;

  void reset() {
    controller?.dispose();
    controller = null;
    showTranslation = false;
  }

  void dispose() => controller?.dispose();
}

/// 展开后的全文 + 翻译工具条。插件没开、当前模型的思考本来就是中文、或者
/// 没连上引擎时,只有全文。
class _TranslatableReasoning extends ConsumerStatefulWidget {
  const _TranslatableReasoning({
    required this.text,
    required this.active,
    required this.holder,
    required this.onBodyTap,
  });

  final String text;
  final bool active;
  final _TranslationHolder holder;

  /// 点正文收起(等价于点头部);工具栏上的按钮不受这层手势影响。
  final VoidCallback onBodyTap;

  @override
  ConsumerState<_TranslatableReasoning> createState() => _TranslatableReasoningState();
}

class _TranslatableReasoningState extends ConsumerState<_TranslatableReasoning> {
  ReasoningTranslation? _listening;

  @override
  void initState() {
    super.initState();
    _listen(widget.holder.controller);
  }

  @override
  void didUpdateWidget(_TranslatableReasoning old) {
    super.didUpdateWidget(old);
    _listen(widget.holder.controller);
    if (old.text != widget.text || old.active != widget.active) {
      widget.holder.controller?.update(widget.text, running: widget.active);
    }
  }

  @override
  void dispose() {
    _listening?.removeListener(_changed);
    super.dispose();
  }

  void _listen(ReasoningTranslation? controller) {
    if (identical(controller, _listening)) return;
    _listening?.removeListener(_changed);
    _listening = controller?..addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _start(CotTranslationLimits limits, ReasoningTranslator translator) {
    final holder = widget.holder;
    final sessionId = ref.read(currentSessionProvider);
    holder.language = reasoningUiLanguage;
    final controller = holder.controller ??= ReasoningTranslation(
      maxTextChars: limits.maxTextChars,
      translate: (text) => translator(text, limits: limits, sessionId: sessionId),
    );
    _listen(controller);
    setState(() => holder.showTranslation = true);
    controller.update(widget.text, running: widget.active);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final holder = widget.holder;
    if (holder.controller != null && holder.language != reasoningUiLanguage) holder.reset();
    final controller = holder.controller;
    final limits = ref.watch(cotTranslationProvider).value;
    final translator = ref.watch(reasoningTranslatorProvider);
    final offered =
        limits != null &&
        translator != null &&
        reasoningNeedsTranslation(widget.text, limits.targetFor(reasoningUiLanguage));
    final failed = controller?.failed ?? false;
    final showing = holder.showTranslation && controller != null && !failed;
    final body = _CollapsibleReasoningBody(
      onCollapse: widget.onBodyTap,
      child: MarkdownBody(
        text: showing ? controller.text.trim() : widget.text,
        streaming: widget.active,
        secondary: true,
        // 选择区由 _CollapsibleReasoningBody 套在收起手势的外面,单击才收得起来。
        selectable: false,
      ),
    );
    if (controller == null && !offered) return body;

    final tools = <Widget>[
      if (controller == null)
        _TranslateChip(icon: AppIcons.translate, label: l10n.chatTranslate, onTap: () => _start(limits!, translator!))
      else if (failed) ...[
        Text(
          l10n.chatTranslationUnavailable,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: DshColors.of(context).textTertiary),
        ),
        const SizedBox(width: 8),
        _TranslateChip(icon: AppIcons.retry, label: l10n.commonRetry, onTap: controller.retry),
      ] else
        _TranslateChip(
          icon: AppIcons.translate,
          label: showing ? l10n.chatViewOriginal : l10n.chatViewTranslation,
          onTap: () => setState(() => holder.showTranslation = !holder.showTranslation),
        ),
      if (controller != null && controller.pending && !failed) ...[
        const SizedBox(width: 10),
        Semantics(
          label: l10n.chatTranslating,
          child: SizedBox.square(
            dimension: 12,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: DshColors.of(context).textTertiary),
          ),
        ),
      ],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: tools),
        ),
        body,
      ],
    );
  }
}

/// 工具条上的小胶囊:左右等距 10,图标 14、字 12.5。
class _TranslateChip extends StatelessWidget {
  const _TranslateChip({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Held down: 翻译设置 (target language, translation service).
  void _settings(BuildContext context) => unawaited(openSettingsPage(context, 'cot-translation'));

  static const height = 26.0;
  static const padding = 10.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final fg = theme.colorScheme.onSurfaceVariant;
    return Pressable(
      onTap: onTap,
      onLongPress: () => _settings(context),
      semanticLabel: label,
      child: Container(
        constraints: const BoxConstraints(minHeight: height),
        padding: const EdgeInsets.symmetric(horizontal: padding),
        decoration: ShapeDecoration(
          color: dark ? Colors.white.withValues(alpha: 0.08) : theme.colorScheme.onSurface.withValues(alpha: 0.06),
          shape: const StadiumBorder(),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 4),
            Text(label, style: theme.textTheme.labelMedium?.copyWith(fontSize: 12.5, height: 1.2, color: fg)),
          ],
        ),
      ),
    );
  }
}
