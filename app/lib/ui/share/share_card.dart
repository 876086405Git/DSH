// The share card (晒成果) — a fixed-width poster of a reply, a stretch of a
// conversation, a file or a plugin, in the app's own type and the person's
// accent colour, with the dsh-go lockup and a QR code to the project page.

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/app_info.dart';
import '../chat/render/code_block.dart' show highlightCode;
import '../chat/render/markdown_body.dart';
import '../common/tool_glyph.dart' show ToolGlyphs;
import '../plugins/plugin_detail_sheet.dart' show PluginHero, PluginStats;
import '../plugins/plugin_widgets.dart' show PluginAvatar;
import '../shell/brand_mark.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'qr_code.dart';
import 'share_content.dart';
import 'share_gallery.dart';

/// The card's look. Every template draws the same content.
enum ShareTemplate {
  /// The app's light page: misty gradient in the accent's tint, ink text.
  light,

  /// The app's dark page.
  dark,

  /// Warm white paper, set for reading: longer leading, an accent rule over
  /// the title, the QR code printed straight on the page.
  paper,

  /// A frosted pane over the accent's misty gradient: the launcher icon's
  /// material.
  glass,

  /// A white card floating on the accent colour.
  card;

  String get label => switch (this) {
    ShareTemplate.light => appL10n.commonLight,
    ShareTemplate.dark => appL10n.commonDark,
    ShareTemplate.paper => appL10n.viewTemplatePaper,
    ShareTemplate.glass => appL10n.viewTemplateGlass,
    ShareTemplate.card => appL10n.viewTemplateCard,
  };

  /// The body sits on a panel over a coloured field, the brand line below
  /// the panel on the field.
  bool get onField => this == glass || this == card;

  Brightness get brightness => this == dark ? Brightness.dark : Brightness.light;
}

/// A share card, [width] logical pixels wide and as tall as its full content.
///
/// ```
/// ┌──────────────────────────────────────┐
/// │ 修复登录按钮重复提交                    │  title, up to three lines
/// │ (deepseek-v4-pro) (53 秒) (8 步)       │  meta capsules
/// │ ⌕ 联网搜索 3   ▷ 运行命令 1             │  what the agent did
/// │                        ▢▢ pictures    │
/// │                  ╭─────────────────╮  │
/// │                  │ 登录按钮连点…     │  │  the question
/// │                  ╰─────────────────╯  │
/// │ The answer, as Markdown, ▢ pictures…  │
/// │ ───────────────────────────────────── │
/// │ ◖● dsh-go                     ▣▣▣▣    │  brand + QR; the QR's corner
/// │    手机上的 DSH · 扫码获取       ▣▣▣▣    │  as far from both edges
/// └──────────────────────────────────────┘
/// ```
class ShareCard extends StatelessWidget {
  const ShareCard({
    super.key,
    required this.content,
    this.template = ShareTemplate.light,
    this.showQuestion = true,
    this.showMeta = true,
    this.accent,
  });

  final ShareContent content;
  final ShareTemplate template;
  final bool showQuestion;
  final bool showMeta;

  /// The colours to draw in; null: the app's current accent
  /// ([DshSurfaces.accent] of the ambient theme).
  final AppAccent? accent;

  /// Logical width; exported at 2–3× (1170 px wide at 3×).
  static const width = 390.0;

  /// Content inset of the page templates (light, dark, paper): left, right
  /// and bottom (the QR code's corner); the top has [topInset].
  static const inset = 24.0;
  static const topInset = 32.0;

  /// Field templates (glass, card): the panel's margin on the field, on all
  /// four sides and between the panel and the brand line.
  static const fieldInset = 18.0;

  /// Field templates: the content inset inside the panel.
  static const panelInset = 22.0;

  /// The panel's corner radius.
  static const panelRadius = 24.0;

  static const qrSize = 72.0;

  /// Light modules round the card's code.
  static const qrQuietZone = 3;

  /// The finest module, in logical pixels, a card's QR code is drawn at.
  ///
  /// A card exported at 2× and then halved shows the code at one pixel per
  /// logical pixel. In that and every other halving tried (box, bilinear,
  /// Lanczos, JPEG), on all five templates, zxing-cpp read version 6 at 72
  /// (1.53 a module) every time and missed version 7 (1.41).
  static const qrMinModule = 1.5;

  /// The code the card draws for [link] and the plate its logo clears, or
  /// null when even the plain code would be finer than [qrMinModule] (a
  /// plugin's landing link carries the whole plugin): the card then goes
  /// without a QR code rather than print one that can't be scanned.
  static (QrCode, QrLogoPlate?)? qrFor(String link) {
    bool scans(QrCode code) => qrSize / (code.size + 2 * qrQuietZone) >= qrMinModule;
    final drawn = QrCodeView.codeFor(link, QrEcc.medium, logo: true, size: qrSize, quietZone: qrQuietZone);
    if (scans(drawn.$1)) return drawn;
    final plain = QrCodeView.codeFor(link, QrEcc.medium, size: qrSize, quietZone: qrQuietZone);
    return scans(plain.$1) ? plain : null;
  }

  /// The width the body is laid out in.
  static double contentWidth(ShareTemplate template) =>
      template.onField ? width - 2 * (fieldInset + panelInset) : width - 2 * inset;

  /// Line height of the body text.
  static double leadingFor(ShareTemplate template) => template == ShareTemplate.paper ? 1.8 : 1.65;

  static final _themes = <(ShareTemplate, AppAccent), ThemeData>{};

  /// The theme [template] is drawn in, in [accent]'s colours.
  static ThemeData themeFor(ShareTemplate template, {AppAccent accent = AppAccent.mist}) {
    final key = (template, accent);
    final hit = _themes.remove(key);
    if (hit != null) return _themes[key] = hit;
    if (_themes.length >= 12) _themes.remove(_themes.keys.first);
    return _themes[key] = _buildTheme(template, accent);
  }

  static ThemeData _buildTheme(ShareTemplate template, AppAccent accent) {
    switch (template) {
      case ShareTemplate.dark:
        return buildDarkTheme(accent: accent, glassBlur: false);
      case ShareTemplate.light || ShareTemplate.card:
        return buildLightTheme(accent: accent, glassBlur: false);
      case ShareTemplate.glass:
        final theme = buildLightTheme(accent: accent, glassBlur: false);
        return _withSurfaces(theme, (s) => s.copyWith(userBubble: Colors.white.withValues(alpha: 0.74)));
      case ShareTemplate.paper:
        // The accent stays; the neutrals (text, wells, rules) turn warm.
        final theme = buildLightTheme(accent: _paperAccent(accent), glassBlur: false);
        final body = theme.textTheme.bodyLarge!.copyWith(height: leadingFor(template));
        return _withSurfaces(
          theme.copyWith(textTheme: theme.textTheme.copyWith(bodyLarge: body)),
          (s) => s.copyWith(userBubble: _PaperLook.bubble),
        );
    }
  }

  static ThemeData _withSurfaces(ThemeData theme, DshSurfaces Function(DshSurfaces) change) =>
      theme.copyWith(extensions: [for (final e in theme.extensions.values) e is DshSurfaces ? change(e) : e]);

  /// [accent] with warm, paper-toned neutrals.
  static AppAccent _paperAccent(AppAccent a) => AppAccent(
    id: '${a.id}-paper',
    label: a.label,
    seed: a.seed,
    pressed: a.pressed,
    container: a.container,
    onContainer: a.onContainer,
    bubble: a.bubble,
    glow: a.glow,
    seedDark: a.seedDark,
    pressedDark: a.pressedDark,
    onSeedDark: a.onSeedDark,
    containerDark: a.containerDark,
    onContainerDark: a.onContainerDark,
    bubbleDark: a.bubbleDark,
    glowDark: a.glowDark,
    tintHue: _PaperLook.hue,
    tintChroma: 0.55,
    haze: a.haze,
    hazeDark: a.hazeDark,
  );

  @override
  Widget build(BuildContext context) {
    final accent = this.accent ?? Theme.of(context).extension<DshSurfaces>()?.accent ?? AppAccent.mist;
    final blocks = [
      for (final block in content.blocks)
        if (showQuestion || block is! ShareQuestion) block,
    ];
    final theme = themeFor(template, accent: accent);
    final look = _Look(template, accent);
    return MediaQuery(
      // The image looks the same whatever the phone's text size.
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling, disableAnimations: true),
      child: Theme(
        data: theme,
        child: TickerMode(
          enabled: false,
          child: Material(
            type: MaterialType.transparency,
            child: DefaultTextStyle(
              style: theme.textTheme.bodyMedium!.copyWith(color: theme.colorScheme.onSurface),
              child: ShareImageScope(
                sessionId: content.sessionId,
                decodeBound: ShareImageScope.decodeBoundFor(blocks),
                child: SizedBox(
                  width: width,
                  child: template.onField
                      ? _FieldLayout(card: this, blocks: blocks, look: look)
                      : _PageLayout(card: this, blocks: blocks, look: look),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The colours of one template in one accent.
class _Look {
  _Look(this.template, this.accent) : _o = Oklch.fromColor(accent.seed);

  final ShareTemplate template;
  final AppAccent accent;
  final Oklch _o;

  /// The accent's chroma, kept within what reads as calm.
  double get _c => _o.c.clamp(0.0, 0.14);

  /// The field of the card template: the accent, a step up and down.
  (Color, Color) get cardField =>
      (Oklch(0.63, _c * 1.3, _o.h - 4).toColor(), Oklch(0.47, _c * 1.25, _o.h + 3).toColor());

  /// The glass field: the launcher icon's gradient, pale at the top left,
  /// deep at the bottom right where the brand line sits.
  (Color, Color) get glassField =>
      (Oklch(0.86, _c * 0.42, _o.h - 8).toColor(), Oklch(0.52, _c * 0.95, _o.h + 2).toColor());

  /// A deeper pool of the accent behind the glass, for the frost to soften.
  Color get glassPool => Oklch(0.58, _c * 1.1, _o.h).toColor();

  /// The panel's shadow on a field.
  Color get fieldShadow => Oklch(0.24, _c * 0.9, _o.h).toColor();

  /// Light that shows through the glass, blurred.
  Color get glassOrb => accent.haze;
}

/// The paper template's own tones (warm white, never the accent).
abstract final class _PaperLook {
  static const hue = 80.0;
  static final top = const Oklch(0.984, 0.007, hue).toColor();
  static final bottom = const Oklch(0.968, 0.010, hue - 6).toColor();
  static final bubble = const Oklch(0.935, 0.014, hue).toColor();
  static final rule = const Oklch(0.86, 0.012, hue).toColor();
  static final ink = const Oklch(0.24, 0.012, hue - 20).toColor();
}

/// 浅色 / 深色 / 纸张: content straight on the page.
class _PageLayout extends StatelessWidget {
  const _PageLayout({required this.card, required this.blocks, required this.look});

  final ShareCard card;
  final List<ShareBlock> blocks;
  final _Look look;

  @override
  Widget build(BuildContext context) {
    final surfaces = DshSurfaces.of(context);
    final scheme = Theme.of(context).colorScheme;
    final paper = card.template == ShareTemplate.paper;
    return CustomPaint(
      painter: paper
          ? _PaperPainter(top: _PaperLook.top, bottom: _PaperLook.bottom)
          : _PagePainter(
              top: surfaces.backdropTop,
              bottom: surfaces.backdropBottom,
              glowPrimary: surfaces.glowPrimary,
              glowSecondary: surfaces.glowSecondary,
            ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(ShareCard.inset, ShareCard.topInset, ShareCard.inset, ShareCard.inset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Body(card: card, blocks: blocks, look: look),
            const SizedBox(height: 28),
            Divider(
              key: const ValueKey('share-footer-rule'),
              height: 0.5,
              thickness: 0.5,
              color: paper ? _PaperLook.rule : scheme.outlineVariant.withValues(alpha: 0.8),
            ),
            // With no code, the brand block alone sits as far below the rule as
            // above the card's edge.
            SizedBox(height: ShareCard.qrFor(card.content.link) == null ? ShareCard.inset : 20),
            _Footer(link: card.content.link, template: card.template, qrBackground: paper ? _PaperLook.bottom : null),
          ],
        ),
      ),
    );
  }
}

/// 玻璃 / 卡片: the body on a panel floating on the accent field, the brand
/// line under it on the field. The panel's margin, the gap below it and the
/// brand line's margin are all [ShareCard.fieldInset].
class _FieldLayout extends StatelessWidget {
  const _FieldLayout({required this.card, required this.blocks, required this.look});

  final ShareCard card;
  final List<ShareBlock> blocks;
  final _Look look;

  @override
  Widget build(BuildContext context) {
    final glass = card.template == ShareTemplate.glass;
    final scheme = Theme.of(context).colorScheme;
    final (top, bottom) = glass ? look.glassField : look.cardField;
    const radius = BorderRadius.all(Radius.circular(ShareCard.panelRadius));
    final shadow = [
      BoxShadow(
        color: look.fieldShadow.withValues(alpha: glass ? 0.20 : 0.26),
        blurRadius: glass ? 40 : 28,
        offset: Offset(0, glass ? 14 : 10),
      ),
    ];
    final body = Padding(
      padding: const EdgeInsets.all(ShareCard.panelInset),
      child: _Body(card: card, blocks: blocks, look: look),
    );
    final Widget panel = glass
        ? _GlassPanel(radius: radius, shadows: shadow, child: body)
        : DecoratedBox(
            decoration: ShapeDecoration(
              color: scheme.surface,
              shape: const RoundedSuperellipseBorder(borderRadius: radius),
              shadows: shadow,
            ),
            child: body,
          );
    return CustomPaint(
      painter: _FieldPainter(
        top: top,
        bottom: bottom,
        orb: glass ? look.glassOrb : null,
        pool: glass ? look.glassPool : null,
      ),
      child: Padding(
        padding: const EdgeInsets.all(ShareCard.fieldInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KeyedSubtree(key: const ValueKey('share-panel'), child: panel),
            const SizedBox(height: ShareCard.fieldInset),
            _Footer(link: card.content.link, template: card.template),
          ],
        ),
      ),
    );
  }
}

/// Frosted glass: what is behind it blurred and brightened, a white wash
/// that thins towards the bottom right, a rim of light on the top-left edge.
class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.radius, required this.shadows, required this.child});

  final BorderRadius radius;
  final List<BoxShadow> shadows;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: RoundedSuperellipseBorder(borderRadius: radius),
        shadows: shadows,
      ),
      child: ClipRSuperellipse(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: CustomPaint(painter: _GlassPainter(radius), foregroundPainter: _GlassRimPainter(radius), child: child),
        ),
      ),
    );
  }
}

class _GlassPainter extends CustomPainter {
  const _GlassPainter(this.radius);

  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white.withValues(alpha: 0.66), Colors.white.withValues(alpha: 0.52)],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlassPainter old) => old.radius != radius;
}

class _GlassRimPainter extends CustomPainter {
  const _GlassRimPainter(this.radius);

  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shape = RoundedSuperellipseBorder(borderRadius: radius);
    canvas.drawPath(
      shape.getInnerPath(rect.deflate(0.5)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white.withValues(alpha: 0.95), Colors.white.withValues(alpha: 0.35)],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlassRimPainter old) => old.radius != radius;
}

/// Title, meta, what the agent did, and the blocks.
class _Body extends StatelessWidget {
  const _Body({required this.card, required this.blocks, required this.look});

  final ShareCard card;
  final List<ShareBlock> blocks;
  final _Look look;

  @override
  Widget build(BuildContext context) {
    final content = card.content;
    final width = ShareCard.contentWidth(card.template);
    final children = <Widget>[];
    void gap(double h) {
      if (children.isNotEmpty) children.add(SizedBox(height: h));
    }

    final header = _Header(
      title: content.title,
      pills: card.showMeta ? content.metaPills : const [],
      process: card.showMeta ? content.process : const [],
      rule: card.template == ShareTemplate.paper ? look.accent.seed : null,
    );
    if (header.isNotEmpty) children.add(header);
    ShareBlock? previous;
    for (final block in blocks) {
      // 28 under the header; an answer close under its own question; a new
      // exchange of a long image further apart than paragraphs.
      gap(switch ((previous, block)) {
        (null, _) => 28,
        (ShareQuestion(), ShareAnswer()) => 14,
        (ShareAnswer(), ShareQuestion()) => 36,
        _ => 24,
      });
      children.add(_block(block, width));
      previous = block;
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children);
  }

  Widget _block(ShareBlock block, double width) => switch (block) {
    final ShareQuestion q => _Question(q, width: width),
    ShareAnswer(:final markdown) => _Answer(markdown, width: width),
    final ShareFile file => _File(file),
    final SharePlugin plugin => _Plugin(plugin),
  };
}

/// The magazine head: a large title, quiet capsules for the model, time and
/// steps, and one light line of what the agent did.
class _Header extends StatelessWidget {
  const _Header({required this.title, required this.pills, required this.process, this.rule});

  final String? title;
  final List<String> pills;
  final List<ShareProcessItem> process;

  /// Paper: a short accent rule over the title.
  final Color? rule;

  bool get isNotEmpty => title != null || pills.isNotEmpty || process.isNotEmpty;

  /// Title size; three lines at most.
  static const titleSize = 24.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final scheme = theme.colorScheme;
    final children = <Widget>[];
    void gap(double h) {
      if (children.isNotEmpty) children.add(SizedBox(height: h));
    }

    if (rule case final color? when title != null) {
      children
        ..add(
          Align(
            alignment: Alignment.centerLeft,
            child: DecoratedBox(
              key: const ValueKey('share-rule'),
              decoration: ShapeDecoration(color: color, shape: const StadiumBorder()),
              child: const SizedBox(width: 24, height: 3),
            ),
          ),
        )
        ..add(const SizedBox(height: 4));
    }
    if (title case final t?) {
      gap(12);
      children.add(
        Text(
          t,
          key: const ValueKey('share-title'),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontSize: titleSize,
            height: 1.32,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
      );
    }
    if (pills.isNotEmpty) {
      gap(14);
      children.add(
        Wrap(
          key: const ValueKey('share-pills'),
          spacing: 6,
          runSpacing: 6,
          children: [for (final p in pills) _MetaPill(p)],
        ),
      );
    }
    if (process.isNotEmpty) {
      gap(12);
      final label = theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary, height: 1.35);
      children.add(
        Wrap(
          key: const ValueKey('share-process'),
          spacing: 14,
          runSpacing: 4,
          children: [
            for (final item in process)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(ToolGlyphs.iconFor(item.tool), size: 14, color: colors.textTertiary),
                  const SizedBox(width: 4),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: '${item.label} '),
                        TextSpan(
                          text: '${item.count}',
                          style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    style: AppType.tabular(label),
                  ),
                ],
              ),
          ],
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children);
  }
}

/// One meta capsule: 24 tall, 10 either side of its text.
class _MetaPill extends StatelessWidget {
  const _MetaPill(this.text);

  final String text;

  static const height = 24.0;
  static const padding = 10.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      key: ValueKey('share-pill-$text'),
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: padding),
      decoration: ShapeDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: dark ? 0.08 : 0.055),
        shape: const StadiumBorder(),
      ),
      child: Center(
        widthFactor: 1,
        child: Text(
          text,
          maxLines: 1,
          style: AppType.tabular(
            theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
              height: 1.2,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
        ),
      ),
    );
  }
}

/// The prompt, as the chat draws it: its pictures, then a right-aligned
/// bubble under them.
class _Question extends StatelessWidget {
  const _Question(this.question, {required this.width});

  final ShareQuestion question;
  final double width;

  @override
  Widget build(BuildContext context) {
    final surfaces = DshSurfaces.of(context);
    final text = question.text;
    final images = question.images;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (images.isNotEmpty) ShareGallery(images: images, width: width, question: true),
        if (images.isNotEmpty && text.isNotEmpty) const SizedBox(height: 8),
        if (text.isNotEmpty)
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width * 0.82),
            child: DecoratedBox(
              key: const ValueKey('share-bubble'),
              decoration: ShapeDecoration(color: surfaces.userBubble, shape: AppShape.bubble),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Text(
                  text,
                  // The bubble hugs its longest line, not the column.
                  textWidthBasis: TextWidthBasis.longestLine,
                  style: AppType.chatBody(context, color: surfaces.onUserBubble),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A reply: its text runs through the chat's Markdown renderer, its code
/// blocks as [ShareCodeWell]s (wrapped, no buttons: an image can't scroll
/// or copy), its pictures as galleries where they stood.
class _Answer extends StatelessWidget {
  const _Answer(this.markdown, {required this.width});

  final String markdown;
  final double width;

  @override
  Widget build(BuildContext context) {
    final segments = shareSegments(markdown);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, segment) in segments.indexed) ...[
          if (i > 0)
            SizedBox(
              height: segment.code || segment.isImages || segments[i - 1].code || segments[i - 1].isImages ? 12 : 8,
            ),
          if (segment.isImages)
            ShareGallery(images: [for (final url in segment.images) ShareUrlImage(url)], width: width)
          else if (segment.code)
            ShareCodeWell(code: segment.text, language: segment.language)
          else
            MarkdownBody(text: segment.text, selectable: false),
        ],
      ],
    );
  }
}

/// The chat's code well for a still image: the language on the header strip,
/// Mist highlighting, long lines wrapped instead of scrolled.
class ShareCodeWell extends StatelessWidget {
  const ShareCodeWell({super.key, required this.code, this.language});

  final String code;
  final String? language;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final label = language?.trim();
    final style = AppType.mono(color: colors.codeWellFg);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: colors.codeWellBg,
        shape: RoundedSuperellipseBorder(
          borderRadius: AppShape.radiusMd,
          side: BorderSide(color: colors.codeWellBorder, width: 0.5),
        ),
      ),
      child: Squircle.clip(
        radius: AppShape.md,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ColoredBox(
              color: colors.codeWellHeader,
              child: SizedBox(
                height: 36,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      label == null || label.isEmpty ? 'text' : label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.monoLabel(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Text.rich(highlightCode(code.trimRight(), language, theme.brightness, style: style)),
            ),
          ],
        ),
      ),
    );
  }
}

/// A delivered file: the picture itself, or a tile and the first lines.
class _File extends StatelessWidget {
  const _File(this.file);

  final ShareFile file;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final image = file.image;
    final excerpt = file.excerpt;
    final tile = Row(
      children: [
        DecoratedBox(
          decoration: ShapeDecoration(color: colors.identity[0], shape: Squircle.border(10)),
          child: SizedBox.square(
            dimension: 40,
            child: Icon(image != null ? AppIcons.image : AppIcons.document, size: 20, color: colors.onIdentity[0]),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                file.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(height: 1.35),
              ),
              const SizedBox(height: 2),
              Text(
                file.description ?? file.typeLabel,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary)),
              ),
            ],
          ),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (image != null) ...[
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 460),
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: ShapeDecoration(
                shape: Squircle.border(
                  AppShape.md,
                  side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6), width: 0.5),
                ),
              ),
              child: Squircle.clip(
                radius: AppShape.md,
                child: Image(
                  image: ResizeImage(image, width: (ShareCard.width * 3).round(), policy: ResizeImagePolicy.fit),
                  fit: BoxFit.cover,
                  width: double.infinity,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
        tile,
        if (excerpt != null) ...[
          const SizedBox(height: 12),
          if (file.excerptLanguage case final language?)
            ShareCodeWell(code: excerpt, language: language)
          else
            MarkdownBody(text: excerpt, selectable: false),
        ],
      ],
    );
  }
}

/// A plugin: icon, name, author, numbers, what it does, how to get it.
class _Plugin extends StatelessWidget {
  const _Plugin(this.plugin);

  final SharePlugin plugin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final description = plugin.description;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PluginHero(
          avatar: PluginAvatar(name: plugin.name, title: plugin.title, icon: plugin.icon, size: 64),
          title: plugin.title,
          subtitle: plugin.author ?? plugin.name,
          monoSubtitle: plugin.author == null,
        ),
        if (plugin.facts.isNotEmpty) ...[const SizedBox(height: 20), PluginStats(plugin.facts.take(3).toList())],
        if (description != null) ...[
          const SizedBox(height: 16),
          Text(
            description,
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.7),
          ),
        ],
        const SizedBox(height: 16),
        DecoratedBox(
          decoration: ShapeDecoration(
            color: colors.codeWellBg,
            shape: RoundedSuperellipseBorder(
              borderRadius: AppShape.radiusSm,
              side: BorderSide(color: colors.codeWellBorder, width: 0.5),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Text(
              plugin.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppType.monoLabel(color: colors.codeWellFg),
            ),
          ),
        ),
      ],
    );
  }
}

/// The brand line: the 「DSH Go」 lockup with one short line under its word,
/// the QR code at the right edge, the two centred on each other. A link too
/// long to scan at the card's size ([ShareCard.qrFor]) leaves the lockup alone.
class _Footer extends StatelessWidget {
  const _Footer({required this.link, required this.template, this.qrBackground});

  final String link;
  final ShareTemplate template;

  /// Paper prints the code straight on the page: its ground is the paper.
  final Color? qrBackground;

  /// The wordmark's size.
  static const word = 17.0;

  /// The QR tile's corner radius (inside the code's three-module margin).
  static const qrRadius = 10.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final onField = template.onField;
    final paper = template == ShareTemplate.paper;
    final ink = onField ? Colors.white : scheme.onSurface;
    final muted = onField ? Colors.white.withValues(alpha: 0.80) : colors.textTertiary;
    final code = ShareCard.qrFor(link);
    final brand = Column(
      key: const ValueKey('share-brand'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        BrandLockup(fontSize: word, label: AppInfo.name, color: ink, glyphColor: onField ? Colors.white : null),
        const SizedBox(height: 3),
        Padding(
          // Under the word, not the glyph.
          padding: EdgeInsets.only(left: BrandLockup.wordInset(word)),
          child: Text(
            code == null ? l10n.viewShareBrandLineNoQr : l10n.viewShareBrandLine,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: muted, height: 1.35, letterSpacing: 0.2),
          ),
        ),
      ],
    );
    // A link too long to scan at this size: the brand block alone, where the
    // body's text starts.
    if (code == null) {
      return Row(
        key: const ValueKey('share-footer'),
        children: [Expanded(child: brand)],
      );
    }
    final qr = QrCodeView(
      data: link,
      size: ShareCard.qrSize,
      color: paper ? _PaperLook.ink : const Color(0xFF111318),
      background:
          qrBackground ??
          (template == ShareTemplate.dark
              ? NeutralTones.forAccent(DshSurfaces.of(context).accent).mistLow
              : Colors.white),
      quietZone: ShareCard.qrQuietZone,
      // The app's tile in the centre when the link is short enough.
      logo: code.$2 != null,
      semanticLabel: l10n.viewShareProjectQr,
    );
    return Row(
      key: const ValueKey('share-footer'),
      children: [
        Expanded(child: brand),
        const SizedBox(width: 16),
        KeyedSubtree(
          key: const ValueKey('share-qr'),
          child: paper
              ? qr
              : DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: ShapeDecoration(
                    shape: Squircle.border(
                      qrRadius,
                      side: template == ShareTemplate.light
                          ? BorderSide(color: scheme.outlineVariant, width: 0.5)
                          : BorderSide.none,
                    ),
                  ),
                  child: Squircle.clip(radius: qrRadius, child: qr),
                ),
        ),
      ],
    );
  }
}

class _PagePainter extends CustomPainter {
  const _PagePainter({required this.top, required this.bottom, required this.glowPrimary, required this.glowSecondary});

  final Color top;
  final Color bottom;
  final Color glowPrimary;
  final Color glowSecondary;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, bottom],
        ).createShader(rect),
    );
    // The page's two glows, sized by the width so a tall card keeps them in
    // its corners instead of washing over the text.
    _glow(canvas, Offset(size.width * 0.92, 0), size.width * 0.9, glowPrimary);
    _glow(canvas, Offset(0, size.height), size.width * 0.8, glowSecondary);
  }

  @override
  bool shouldRepaint(_PagePainter old) =>
      old.top != top || old.bottom != bottom || old.glowPrimary != glowPrimary || old.glowSecondary != glowSecondary;
}

void _glow(Canvas canvas, Offset center, double radius, Color color) {
  final bounds = Rect.fromCircle(center: center, radius: radius);
  canvas.drawRect(
    bounds,
    Paint()..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)]).createShader(bounds),
  );
}

/// Warm paper: a flat sheet, a touch lighter at the top.
class _PaperPainter extends CustomPainter {
  const _PaperPainter({required this.top, required this.bottom});

  final Color top;
  final Color bottom;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, bottom],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_PaperPainter old) => old.top != top || old.bottom != bottom;
}

/// The coloured field of 玻璃 / 卡片: a diagonal gradient, light from the top
/// right; glass adds soft orbs for its frost to blur.
class _FieldPainter extends CustomPainter {
  const _FieldPainter({required this.top, required this.bottom, this.orb, this.pool});

  final Color top;
  final Color bottom;
  final Color? orb;
  final Color? pool;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // Corner to corner: the brand line at the bottom always sits on the deep end.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [top, bottom],
        ).createShader(rect),
    );
    _glow(canvas, Offset(size.width * 0.9, 0), size.width * 0.85, Colors.white.withValues(alpha: 0.22));
    if (orb case final color?) {
      _glow(canvas, Offset(size.width * 0.05, size.width * 0.5), size.width * 0.7, color.withValues(alpha: 0.85));
      if (pool case final deep?) {
        _glow(canvas, Offset(size.width * 0.98, size.width * 0.95), size.width * 0.62, deep.withValues(alpha: 0.55));
      }
      _glow(
        canvas,
        Offset(size.width * 0.3, size.height - size.width * 0.2),
        size.width * 0.55,
        color.withValues(alpha: 0.4),
      );
    }
  }

  @override
  bool shouldRepaint(_FieldPainter old) => old.top != top || old.bottom != bottom || old.orb != orb || old.pool != pool;
}
