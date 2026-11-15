// 宠物设置 › 大小 › 自定义: the chosen pet standing at the dragged size, and
// the slider under it, as a share of 标准. Dragging only redraws the preview;
// letting go saves, and the pet on the chat page follows.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../pets/pet_prefs.dart';
import '../../pets/pet_signals.dart';
import '../../pets/pet_state.dart';
import '../settings/settings_widgets.dart';
import 'pet_sprite.dart';

class PetCustomSizePanel extends ConsumerStatefulWidget {
  const PetCustomSizePanel({super.key});

  /// Steps of 5 % of 标准 between [PetSize.customMin] and [PetSize.customMax].
  static double snap(double dp) {
    final step = PetSize.medium.bodyHeight / 20;
    return ((dp / step).round() * step).clamp(PetSize.customMin, PetSize.customMax).toDouble();
  }

  static String label(double dp) => '${(dp / PetSize.medium.bodyHeight * 100).round()}%';

  @override
  ConsumerState<PetCustomSizePanel> createState() => _PetCustomSizePanelState();
}

class _PetCustomSizePanelState extends ConsumerState<PetCustomSizePanel> {
  /// The height while a finger is on the slider.
  double? _draft;

  /// Room for the largest body plus what a pack draws above and below it.
  static const _previewHeight = 132.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final double height = _draft ?? ref.watch(petPrefsProvider.select((p) => p.customHeight));
    final pack = ref.watch(currentPetPackProvider);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 6, SettingsMetrics.inset, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pack != null)
            SizedBox(
              height: _previewHeight,
              child: LayoutBuilder(
                builder: (context, box) {
                  final s = petScale(pack, PetSize.custom, dpr, customHeight: height);
                  final perchTop = _previewHeight - 10;
                  final left = box.maxWidth / 2 - ((pack.contentBox.left + pack.contentBox.right) / 2) * s;
                  final top = perchTop - pack.baseline * s;
                  final perchWidth = math.min(box.maxWidth, math.max(48.0, pack.contentBox.width * s * 1.6));
                  return Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      Positioned(
                        left: (box.maxWidth - perchWidth) / 2,
                        top: perchTop,
                        width: perchWidth,
                        height: 6,
                        child: DecoratedBox(
                          decoration: ShapeDecoration(
                            color: scheme.onSurface.withValues(alpha: 0.10),
                            shape: const StadiumBorder(),
                          ),
                        ),
                      ),
                      Positioned(
                        left: (left * dpr).roundToDouble() / dpr,
                        top: (top * dpr).roundToDouble() / dpr,
                        child: ExcludeSemantics(
                          child: PetSprite(pack: pack, anim: pack.animFor(PetStateName.idle), scale: s),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ExcludeSemantics(
            child: Row(
              children: [
                Expanded(child: Text(l10n.botsPetCustomSize, style: settingsTitleStyle(context))),
                const SizedBox(width: 12),
                Text(
                  PetCustomSizePanel.label(height),
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Semantics(
            label: l10n.botsPetCustomSize,
            child: Slider(
              key: const ValueKey('pet-custom-size'),
              value: height.clamp(PetSize.customMin, PetSize.customMax).toDouble(),
              min: PetSize.customMin,
              max: PetSize.customMax,
              padding: EdgeInsets.zero,
              activeColor: scheme.onSurfaceVariant,
              inactiveColor: scheme.onSurface.withValues(alpha: 0.1),
              semanticFormatterCallback: (v) => PetCustomSizePanel.label(PetCustomSizePanel.snap(v)),
              onChanged: (raw) {
                final next = PetCustomSizePanel.snap(raw);
                if (next == PetCustomSizePanel.snap(height)) return;
                HapticFeedback.selectionClick();
                setState(() => _draft = next);
              },
              onChangeEnd: (raw) {
                final next = PetCustomSizePanel.snap(raw);
                unawaited(ref.read(petPrefsProvider.notifier).setCustomHeight(next).whenComplete(() {
                  if (mounted) setState(() => _draft = null);
                }));
              },
            ),
          ),
        ],
      ),
    );
  }
}
