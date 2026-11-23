import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import '../../themes/theme_library.dart';
import '../../wallpaper/wallpaper_frames.dart';
import '../../workshop/workshop_models.dart';
import '../theme/theme.dart';

/// Renders a still of a fictional chat. Pass the installed library for a local
/// source, or the staging library for a picked ZIP. Never mounts a chat page
/// or reads the current theme, wallpaper, locale, or conversation.
Future<Uint8List> workshopGenerateThemeCover({required ThemeLibrary library, required String localId}) async {
  if (!isUserThemeId(localId) || !isValidThemeId(publicThemeIdFor(localId))) {
    throw const ThemeImportException(ThemeImportProblem.badPack, 'id');
  }
  final pack = await library.load(localId);
  final loadedFonts = await _coverFonts(pack);
  final theme = buildLightTheme(accent: AppAccent.fromThemePack(pack), themePack: pack, loadedFonts: loadedFonts);
  final style = theme.extension<DshThemeStyle>()!;
  final surfaces = theme.extension<DshSurfaces>()!;
  final images = <String, ui.Image>{};
  final surfaceSpec = pack.surfaces;
  final backdrop = surfaceSpec.backdropOpacity > 0 ? surfaceSpec.backdropImage : null;
  try {
    // Read only displayed assets of the already validated pack; shared slots
    // use the same decoded first frame.
    for (final name in {backdrop, pack.components.userAvatar, pack.components.assistantAvatar}.nonNulls) {
      final file = style.assetFile(name)!;
      const maxSide = 2048;
      final extent = name != backdrop ? 48 : (surfaceSpec.backdropRepeat ? maxSide : workshopPreviewSide);
      final codec = await openFrames(
        FrameSource(path: file.path, coverWidth: extent, coverHeight: extent, maxSide: maxSide),
      );
      try {
        images[name] = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    }
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(workshopPreviewSide / _side);
    ui.Picture? picture;
    try {
      _paintBackdrop(canvas, surfaces, surfaceSpec, images[backdrop]);
      _paintChat(canvas, theme, style, surfaces, images);
      picture = recorder.endRecording();
      final image = await picture.toImage(workshopPreviewSide, workshopPreviewSide);
      try {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        if (png == null) workshopInvalid('workshop_preview_png');
        return Uint8List.sublistView(png);
      } finally {
        image.dispose();
      }
    } finally {
      (picture ?? recorder.endRecording()).dispose();
    }
  } finally {
    for (final image in images.values) {
      image.dispose();
    }
  }
}

Future<Map<String, String>> _coverFonts(ThemePack pack) {
  if (pack.referencedFonts.isEmpty) return Future.value(const {});
  // A staged ZIP can have the same ID and font filenames as an installed pack.
  // Keep it out of the active theme's font cache, including after a replacement.
  final scope = sha256.convert(utf8.encode('${pack.folderPath}#${pack.assetRevision}'));
  return ThemeFonts.instance.loadFor(pack.copyWith(id: 'workshop-cover-$scope'));
}

const _side = 400.0;
const _page = Rect.fromLTWH(0, 0, _side, _side);

void _paintBackdrop(Canvas canvas, DshSurfaces surfaces, ThemeSurfaceSpec spec, ui.Image? image) {
  canvas.drawRect(
    _page,
    Paint()
      ..shader = ui.Gradient.linear(_page.topLeft, _page.bottomLeft, [surfaces.backdropTop, surfaces.backdropBottom]),
  );
  final (primary, secondary) = switch (spec.glowLayout) {
    ThemeGlowLayout.corners => (_page.topRight, _page.bottomLeft),
    ThemeGlowLayout.top => (_page.topRight, _page.topLeft),
    ThemeGlowLayout.bottom => (_page.bottomRight, _page.bottomLeft),
    ThemeGlowLayout.center => (const Offset(200, 88), _page.bottomCenter),
  };
  for (final (center, color) in [(primary, surfaces.glowPrimary), (secondary, surfaces.glowSecondary)]) {
    canvas.drawRect(_page, Paint()..shader = ui.Gradient.radial(center, 250, [color, color.withValues(alpha: 0)]));
  }
  if (image == null) return;
  final blur = spec.backdropBlur;
  if (blur > 0) {
    canvas.saveLayer(_page, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur));
  }
  paintImage(
    canvas: canvas,
    rect: _page,
    image: image,
    alignment: spec.backdropRepeat
        ? Alignment.topLeft
        : switch (spec.backdropAlign) {
            ThemeBackdropAlign.top => Alignment.topCenter,
            ThemeBackdropAlign.center => Alignment.center,
            ThemeBackdropAlign.bottom => Alignment.bottomCenter,
          },
    fit: spec.backdropRepeat ? BoxFit.none : BoxFit.cover,
    repeat: spec.backdropRepeat ? ImageRepeat.repeat : ImageRepeat.noRepeat,
    opacity: spec.backdropOpacity,
    filterQuality: FilterQuality.medium,
  );
  if (blur > 0) canvas.restore();
}

void _paintChat(
  Canvas canvas,
  ThemeData theme,
  DshThemeStyle style,
  DshSurfaces surfaces,
  Map<String, ui.Image> images,
) {
  final colors = theme.colorScheme;
  final components = style.components;
  final header = style.headerGlass(colors) ?? surfaces.chrome;
  const headerBox = Rect.fromLTWH(24, 24, 352, 54);
  _shape(canvas, headerBox, style.cardShape(header.hairline, header.hairlineWidth), header.fill);
  canvas.drawCircle(const Offset(48, 51), 6, Paint()..color = colors.primary);
  _text(canvas, 'Theme preview', style.headerTitleTextStyle(theme.textTheme.titleMedium!), const Offset(64, 39), 288);

  const userBox = Rect.fromLTWH(93, 106, 248, 54);
  final userStyle = components.userBubbleStyle;
  final (userFill, userInk) = switch (userStyle) {
    ThemeUserBubbleStyle.accent => (colors.primaryContainer, colors.onPrimaryContainer),
    ThemeUserBubbleStyle.minimal => (Colors.transparent, colors.onSurface),
    _ => (surfaces.userBubble, surfaces.onUserBubble),
  };
  if (userStyle == ThemeUserBubbleStyle.minimal) {
    canvas.drawRect(const Rect.fromLTWH(339, 112, 2, 42), Paint()..color = style.rule ?? colors.primary);
  } else {
    final outline = userStyle == ThemeUserBubbleStyle.outlined ? style.userBubbleBorder ?? colors.outlineVariant : null;
    _shape(canvas, userBox, style.bubbleShape(outline, style.borderWidth.clamp(0.8, 2.0)), userFill);
  }
  _avatar(canvas, images[components.userAvatar], const Offset(363, 133), colors.primaryContainer);
  _text(
    canvas,
    'What should we make?',
    theme.textTheme.bodyLarge!.copyWith(color: userInk),
    const Offset(110, 121),
    215,
  );

  const replyBox = Rect.fromLTWH(58, 185, 318, 112);
  final assistantStyle = components.assistantStyle;
  final assistantInk = assistantStyle == ThemeAssistantStyle.card ? style.onAssistantBubble : null;
  if (assistantStyle == ThemeAssistantStyle.card || assistantStyle == ThemeAssistantStyle.quote) {
    final fill = assistantStyle == ThemeAssistantStyle.card
        ? style.assistantBubble ?? surfaces.card.fill
        : surfaces.pill.fill;
    _shape(canvas, replyBox, style.cardShape(style.assistantBorder ?? colors.outlineVariant), fill);
  }
  if (assistantStyle == ThemeAssistantStyle.leftRule || assistantStyle == ThemeAssistantStyle.quote) {
    canvas.drawRect(const Rect.fromLTWH(58, 191, 3, 98), Paint()..color = style.rule ?? colors.primary);
  }
  _avatar(canvas, images[components.assistantAvatar], const Offset(36, 205), colors.primary);
  _text(
    canvas,
    'A little inspiration',
    style.headingTextStyle(theme.textTheme.titleLarge!).copyWith(color: style.heading ?? assistantInk),
    const Offset(73, 194),
    285,
  );
  _text(
    canvas,
    'Start with a color you love.',
    style.readingTextStyle(theme.textTheme.bodyLarge!).copyWith(color: assistantInk),
    const Offset(73, 236),
    285,
  );

  const composer = Rect.fromLTWH(24, 322, 352, 54);
  final (fill, border) = switch (components.composerStyle) {
    ThemeComposerStyle.floatingGlass => (surfaces.chrome.fill, surfaces.chrome.hairline),
    ThemeComposerStyle.solidPaper => (colors.surfaceContainerLowest, colors.outlineVariant),
    ThemeComposerStyle.outlined => (colors.surface, colors.outline),
  };
  _shape(
    canvas,
    composer,
    style.shapeFor(
      BorderRadius.circular(style.composerRadius),
      BorderSide(color: style.composerBorder ?? border, width: style.borderWidth),
    ),
    style.composerFill ?? fill,
  );
  _text(canvas, 'Try it now', theme.textTheme.bodyLarge!, const Offset(42, 336), 262);
  final (sendFill, sendInk) = switch (components.sendButtonStyle) {
    ThemeSendButtonStyle.tonal => (colors.primaryContainer, colors.onPrimaryContainer),
    ThemeSendButtonStyle.outlined => (Colors.transparent, colors.primary),
    _ => (colors.primary, colors.onPrimary),
  };
  final sendBorder = components.sendButtonStyle == ThemeSendButtonStyle.outlined
      ? BorderSide(color: colors.primary, width: 1.5)
      : BorderSide.none;
  _shape(
    canvas,
    const Rect.fromLTWH(329, 331, 36, 36),
    (style.keyShape ?? const CircleBorder()).copyWith(side: sendBorder),
    style.sendButton ?? sendFill,
  );
  final arrow = Path()
    ..moveTo(340, 349)
    ..lineTo(347, 342)
    ..lineTo(354, 349)
    ..moveTo(347, 343)
    ..lineTo(347, 357);
  canvas.drawPath(
    arrow,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = style.onSendButton ?? sendInk,
  );
}

void _shape(Canvas canvas, Rect rect, ShapeBorder shape, Color fill) {
  canvas.drawPath(shape.getOuterPath(rect), Paint()..color = fill);
  shape.paint(canvas, rect);
}

void _avatar(Canvas canvas, ui.Image? image, Offset center, Color fallback) {
  if (image == null) {
    canvas.drawCircle(center, 12, Paint()..color = fallback);
    return;
  }
  final rect = Rect.fromCircle(center: center, radius: 13);
  canvas.save();
  canvas.clipPath(Path()..addOval(rect));
  paintImage(canvas: canvas, rect: rect, image: image, fit: BoxFit.cover, filterQuality: FilterQuality.medium);
  canvas.restore();
}

void _text(Canvas canvas, String text, TextStyle style, Offset origin, double width) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '...',
  );
  try {
    painter.layout(maxWidth: width);
    painter.paint(canvas, origin);
  } finally {
    painter.dispose();
  }
}
