// 设置 › 主题 › 桌面图标 › 图片快捷方式: the user's own picture as a home-screen shortcut
// that opens the app (lib/state/icon_shortcut_state.dart says why it's a shortcut and not the
// icon). Pick a picture, place it in the launcher's own icon shape, name it, add it.
//
// ╭──────────────────────────────────────────╮
// │ 图片快捷方式                          ×  │
// │              ╭────────╮                   │  the picture in the launcher's mask,
// │              │  ▒▒▒▒  │                   │  drag / pinch inside it
// │              ╰────────╯                   │
// │           拖动或双指缩放 · 换一张           │
// │  名称  [ DSH Go                       ]   │
// │  系统不允许…部分桌面会在它的角上加一个小标  │
// │  [            添加到桌面               ]  │
// ╰──────────────────────────────────────────╯

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../launch/launch_import.dart' show edgeColour;
import '../../../plugins/native/native_effects.dart';
import '../../../plugins/native/native_file_platform.dart';
import '../../../state/app_icon_state.dart';
import '../../../state/android_features.dart' show operatingSystemProvider;
import '../../../state/app_info.dart';
import '../../../state/icon_shortcut_state.dart';
import '../../common/app_sheet.dart';
import '../../common/brief_notice.dart';
import '../../common/sheet_title_bar.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../settings_widgets.dart';
import 'app_icon_picker.dart';

/// The row under the launcher icons.
class IconShortcutTile extends StatelessWidget {
  const IconShortcutTile({super.key});

  @override
  Widget build(BuildContext context) => SettingsTile(
    spot: Spots.iconShortcut,
    subtitle: context.l10n.iconShortcutRowSubtitle,
    onTap: () => unawaited(showIconShortcutSheet(context)),
  );
}

Future<void> showIconShortcutSheet(BuildContext context) => showAppSheet<void>(
  context,
  dismissal: SheetDismissal.button,
  isScrollControlled: true,
  builder: (_) => const IconShortcutSheet(),
);

/// Reads one picture with the system photo picker: its bytes, or null when cancelled.
typedef PicturePicker = Future<Uint8List?> Function();

final shortcutPicturePickerProvider = Provider<PicturePicker>((ref) => _pickPicture);

Future<Uint8List?> _pickPicture() async {
  const max = 8 * 1024 * 1024;
  final platform = MethodNativeFilePlatform();
  final owner = 'shortcut${DateTime.now().microsecondsSinceEpoch}'.padRight(32, '0').substring(0, 32);
  try {
    final files = await platform.pick(
      PickFileEffect(request: owner, action: 'shortcut', images: true, maxFiles: 1, maxBytes: max, maxTotalBytes: max),
    );
    if (files.isEmpty) return null;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in files.first.openRead()) {
      bytes.add(chunk);
      if (bytes.length > max) return null;
    }
    return bytes.takeBytes();
  } finally {
    unawaited(platform.cancel(owner));
  }
}

class IconShortcutSheet extends ConsumerStatefulWidget {
  const IconShortcutSheet({super.key});

  /// The crop well's side at most.
  static const well = 216.0;

  /// The shortcut bitmap: the 108 dp adaptive layer at xxxhdpi.
  static const output = 432;

  /// Pictures are decoded no larger than this on the long side (plenty for a zoomed crop).
  static const decodeSide = 1600;

  @override
  ConsumerState<IconShortcutSheet> createState() => _IconShortcutSheetState();
}

class _IconShortcutSheetState extends ConsumerState<IconShortcutSheet> {
  final _transform = TransformationController();
  final _name = TextEditingController(text: AppInfo.name);
  ui.Image? _picture;
  Color _fill = const Color(0xFFFFFFFF);
  double _side = IconShortcutSheet.well;
  bool _busy = false;
  bool _asked = false;
  StreamSubscription<void>? _pinned;

  @override
  void initState() {
    super.initState();
    _pinned = ref.read(iconShortcutChannelProvider).pinned.listen((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      final text = context.l10n.iconShortcutAdded;
      Navigator.of(context).pop();
      messenger?.showBriefNotice(text);
    });
  }

  @override
  void dispose() {
    unawaited(_pinned?.cancel());
    _transform.dispose();
    _name.dispose();
    _picture?.dispose();
    super.dispose();
  }

  /// The picture's size in the well: covering it.
  Size get _childSize {
    final p = _picture!;
    final scale = math.max(_side / p.width, _side / p.height);
    return Size(p.width * scale, p.height * scale);
  }

  Future<void> _pick() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await ref.read(shortcutPicturePickerProvider)();
      if (bytes == null || !mounted) return;
      final (image, fill) = await _decode(bytes);
      if (!mounted) {
        image?.dispose();
        return;
      }
      if (image == null) {
        showBriefNotice(context, context.l10n.launchUnreadable);
        return;
      }
      setState(() {
        _picture?.dispose();
        _picture = image;
        _fill = fill;
        _asked = false;
        final child = _childSize;
        _transform.value = Matrix4.translationValues(-(child.width - _side) / 2, -(child.height - _side) / 2, 0);
      });
    } on PlatformException {
      if (mounted) showBriefNotice(context, context.l10n.launchUnavailable);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static Future<(ui.Image?, Color)> _decode(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodecWithSize(
        await ui.ImmutableBuffer.fromUint8List(bytes),
        getTargetSize: (w, h) {
          final scale = math.min(1.0, IconShortcutSheet.decodeSide / math.max(w, h));
          return ui.TargetImageSize(width: math.max(1, (w * scale).round()), height: math.max(1, (h * scale).round()));
        },
      );
      final image = (await codec.getNextFrame()).image;
      codec.dispose();
      var fill = const Color(0xFFFFFFFF);
      final small = await _shrink(image, 64);
      final data = await small.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (data != null) {
        final (edge, _) = edgeColour(data.buffer.asUint8List(), small.width, small.height);
        if (edge != null) fill = Color(edge);
      }
      small.dispose();
      return (image, fill);
    } catch (_) {
      return (null, const Color(0xFFFFFFFF));
    }
  }

  static Future<ui.Image> _shrink(ui.Image image, int side) {
    final scale = math.min(1.0, side / math.max(image.width, image.height));
    final w = math.max(1, (image.width * scale).round());
    final h = math.max(1, (image.height * scale).round());
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    return recorder.endRecording().toImage(w, h);
  }

  /// What the well shows, in the picture's pixels.
  Rect get _crop {
    final inv = Matrix4.inverted(_transform.value);
    final topLeft = MatrixUtils.transformPoint(inv, Offset.zero);
    final bottomRight = MatrixUtils.transformPoint(inv, Offset(_side, _side));
    final k = _picture!.width / _childSize.width;
    return Rect.fromPoints(topLeft * k, bottomRight * k);
  }

  Future<void> _add() async {
    final picture = _picture;
    if (picture == null || _busy) return;
    final l10n = context.l10n;
    setState(() => _busy = true);
    try {
      final png = await shortcutBitmap(picture, _crop, _fill);
      if (!mounted) return;
      final answer = await ref.read(iconShortcutChannelProvider).pin(_name.text, png);
      if (!mounted) return;
      switch (answer) {
        case PinRequest.asked:
          setState(() => _asked = true);
        case PinRequest.unsupported:
          showBriefNotice(context, l10n.iconShortcutUnsupported);
        case PinRequest.failed:
          showBriefNotice(context, l10n.iconShortcutFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final mask = ref.watch(appIconProvider).value?.mask;
    final note = theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.55);
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar(l10n.iconShortcutRow),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 8, kSheetGutter, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      _side = math.min(IconShortcutSheet.well, constraints.maxWidth);
                      return Center(child: _well(context, mask));
                    },
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 40,
                    child: _picture == null
                        ? null
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(l10n.iconShortcutHint, style: note),
                              const SizedBox(width: 4),
                              TextButton(
                                key: const ValueKey('shortcut-change'),
                                onPressed: _busy ? null : () => unawaited(_pick()),
                                child: Text(l10n.iconShortcutChange),
                              ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('shortcut-name'),
                    controller: _name,
                    maxLength: 24,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(labelText: l10n.iconShortcutName, counterText: ''),
                  ),
                  const SizedBox(height: 12),
                  Text(l10n.iconShortcutNote, style: note),
                  if (_asked) ...[
                    const SizedBox(height: 16),
                    Text(
                      l10n.iconShortcutConfirm,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface),
                    ),
                    // HarmonyOS asks before the request returns: nothing to allow afterwards.
                    if (ref.watch(operatingSystemProvider) != 'ohos') ...[
                      const SizedBox(height: 4),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(child: Text(l10n.iconShortcutNoDialog, style: note)),
                          TextButton(
                            key: const ValueKey('shortcut-settings'),
                            onPressed: () => unawaited(ref.read(iconShortcutChannelProvider).openAppSettings()),
                            child: Text(l10n.iconShortcutSettings),
                          ),
                        ],
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(kSheetGutter, 20, kSheetGutter, 12),
            child: FilledButton(
              key: const ValueKey('shortcut-add'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: _picture == null || _busy ? null : () => unawaited(_add()),
              child: Text(l10n.iconShortcutAdd),
            ),
          ),
        ],
      ),
    );
  }

  Widget _well(BuildContext context, List<double>? mask) {
    final scheme = Theme.of(context).colorScheme;
    final picture = _picture;
    final shape = launcherMaskPath(mask, _side);
    return SizedBox.square(
      key: const ValueKey('shortcut-well'),
      dimension: _side,
      child: CustomPaint(
        foregroundPainter: _Outline(shape, scheme.outlineVariant),
        child: ClipPath(
          clipper: _PathClipper(shape),
          child: picture == null
              ? ColoredBox(
                  color: scheme.surfaceContainerHigh,
                  child: Center(
                    child: _busy
                        ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                        : TextButton.icon(
                            key: const ValueKey('shortcut-pick'),
                            onPressed: () => unawaited(_pick()),
                            icon: Icon(AppIcons.addImage, size: 20),
                            label: Text(context.l10n.iconShortcutPick),
                          ),
                  ),
                )
              : ColoredBox(
                  color: _fill,
                  child: InteractiveViewer(
                    transformationController: _transform,
                    constrained: false,
                    minScale: 1,
                    maxScale: 6,
                    boundaryMargin: EdgeInsets.zero,
                    child: SizedBox.fromSize(
                      size: _childSize,
                      child: RawImage(image: picture, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class _PathClipper extends CustomClipper<Path> {
  const _PathClipper(this.path);

  final Path path;

  @override
  Path getClip(Size size) => path;

  @override
  bool shouldReclip(_PathClipper old) => old.path != path;
}

class _Outline extends CustomPainter {
  const _Outline(this.path, this.color);

  final Path path;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color,
  );

  @override
  bool shouldRepaint(_Outline old) => old.path != path || old.color != color;
}

/// The shortcut's bitmap: the 108 dp adaptive layer, [IconShortcutSheet.output] square, with
/// [crop] (picture pixels) in its middle 72 — what the launcher shows — and the picture carrying
/// on around it (the launcher's mask and parallax reach a little further), on [fill] where the
/// picture ends.
Future<Uint8List> shortcutBitmap(ui.Image picture, Rect crop, Color fill) async {
  const out = IconShortcutSheet.output;
  final side = out.toDouble();
  // 72 of 108: the visible middle grows by a quarter of the crop on each side.
  final src = crop.inflate(crop.width / 4);
  final bounds = Rect.fromLTWH(0, 0, picture.width.toDouble(), picture.height.toDouble());
  final clipped = src.intersect(bounds);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..drawRect(Rect.fromLTWH(0, 0, side, side), Paint()..color = fill);
  if (!clipped.isEmpty) {
    Offset map(Offset p) => Offset((p.dx - src.left) / src.width * side, (p.dy - src.top) / src.height * side);
    canvas.drawImageRect(
      picture,
      clipped,
      Rect.fromPoints(map(clipped.topLeft), map(clipped.bottomRight)),
      Paint()..filterQuality = FilterQuality.high,
    );
  }
  final recording = recorder.endRecording();
  try {
    final image = await recording.toImage(out, out);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    recording.dispose();
  }
}
