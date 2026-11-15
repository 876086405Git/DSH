// Native, bounded view-v2 inputs and content. Geometry is owned by the app.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/l10n.dart';
import '../../common/expand_reveal.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../render/code_block.dart';
import 'dsh_ui_blocks.dart';
import 'dsh_ui_model.dart';
import 'dsh_ui_plugin_choice.dart';
import 'dsh_ui_plugin_controls_state.dart';
import 'dsh_ui_plugin_row.dart';
import 'dsh_ui_plugin_tones.dart';
import 'dsh_ui_plugin_styles.dart';
import 'dsh_ui_widgets.dart';

class PluginControlsScope extends InheritedNotifier<PluginDraftController> {
  const PluginControlsScope({super.key, required PluginDraftController controller, required super.child})
    : super(notifier: controller);
  static PluginDraftController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PluginControlsScope>()?.notifier;
}

/// How much a plugin control button asks for attention.
enum DshUiButtonTone {
  /// A quiet outlined button on the node's surface.
  neutral,

  /// The one main action of a form: a tonal accent fill with an accent
  /// outline. Deliberately never a solid accent fill with inverse text,
  /// which is the app's own approval / permission button.
  primary,

  /// No visible edge, for a button that sits inside another field.
  quiet,
}

/// Every action uses equal padding on all four sides and at least 48 dp.
/// Its label may wrap; no fixed height competes with system text scaling.
/// Focus, hover and press thicken the outline instead of tinting the fill.
class DshUiControlButton extends StatelessWidget {
  const DshUiControlButton({
    super.key,
    required this.label,
    this.onPressed,
    this.selected,
    this.busy = false,
    this.semanticLabel,
    this.trailingIcon,
    this.leadingIcon,
    this.icon,
    this.mirrorIcon = false,
    this.tone = DshUiButtonTone.neutral,
    this.fill,
    this.padding = const EdgeInsets.all(12),
    this.small = false,
  });
  static const minimumHeight = 48.0;
  final String label;
  final VoidCallback? onPressed;
  final bool? selected;
  final bool busy;
  final String? semanticLabel;
  final IconData? trailingIcon;

  /// Drawn before the label text.
  final IconData? leadingIcon;

  /// Drawn instead of the label text (the label stays the semantics).
  final IconData? icon;

  /// Mirror [icon] horizontally (a glyph that must point the other way in
  /// right-to-left text but does not mirror by itself).
  final bool mirrorIcon;
  final DshUiButtonTone tone;

  /// An opaque fill for a button placed on another control's surface.
  final Color? fill;
  final EdgeInsets padding;

  /// A secondary label size for a button inside a strip (code header); the
  /// target stays 48 dp.
  final bool small;

  @override
  Widget build(BuildContext context) {
    final tones = DshUiPluginTones.of(context);
    final primary = tone == DshUiButtonTone.primary || selected == true;
    final background = primary ? tones.tint : fill ?? tones.surface;
    final foreground = primary
        ? tones.onTint
        : Color(0xFF000000 | dshUiReadableColor(tones.ink.toARGB32() & 0xFFFFFF, background.toARGB32() & 0xFFFFFF));
    final edge = primary ? tones.accentLine : tones.hairline;
    final textStyle = Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: small ? 13 : 15);
    return MergeSemantics(
      child: Semantics(
        label: semanticLabel,
        selected: selected,
        button: true,
        child: OutlinedButton(
          onPressed: busy ? null : onPressed,
          style:
              OutlinedButton.styleFrom(
                padding: padding,
                minimumSize: const Size(48, minimumHeight),
                foregroundColor: foreground,
                disabledForegroundColor: tones.inactive,
                backgroundColor: background,
                disabledBackgroundColor: background,
                overlayColor: Colors.transparent,
                splashFactory: NoSplash.splashFactory,
                textStyle: textStyle,
                shape: Squircle.border(AppShape.md),
                tapTargetSize: MaterialTapTargetSize.padded,
                visualDensity: VisualDensity.standard,
              ).copyWith(
                side: WidgetStateProperty.resolveWith((states) {
                  final active = states.any({WidgetState.focused, WidgetState.hovered, WidgetState.pressed}.contains);
                  if (tone == DshUiButtonTone.quiet && !primary) {
                    return BorderSide(color: active ? tones.line : background, width: active ? 2 : 1);
                  }
                  return BorderSide(color: active && !primary ? tones.line : edge, width: active ? 2 : 1);
                }),
              ),
          child: ExcludeSemantics(
            excluding: semanticLabel != null,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Opacity(
                  opacity: busy ? 0 : 1,
                  child: icon != null
                      ? Transform.flip(flipX: mirrorIcon, child: Icon(icon, size: 20))
                      : leadingIcon != null
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(leadingIcon, size: small ? 16 : 18),
                            const SizedBox(width: 6),
                            Flexible(child: Text(label, textAlign: TextAlign.center)),
                          ],
                        )
                      : trailingIcon == null
                      ? Text(label, textAlign: TextAlign.center)
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(child: Text(label, textAlign: TextAlign.center)),
                            const SizedBox(width: 8),
                            Icon(trailingIcon, size: 20),
                          ],
                        ),
                ),
                if (busy)
                  SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: foreground)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Equal columns and equal heights per row, including wrapped 2x labels.
/// Every row uses the same element structure, whatever the column count.
class DshUiControlChoices extends StatelessWidget {
  const DshUiControlChoices({
    super.key,
    required this.buttons,
    this.columns = 3,
    this.minimumCellWidth,
    this.gap = 8,
    this.runGap,
  });
  final List<Widget> buttons;
  final int columns;
  final double? minimumCellWidth;
  final double gap;
  final double? runGap;

  /// The column count that keeps each cell at least [minimum] wide.
  static int fit({
    required int count,
    required int columns,
    required double width,
    required double minimum,
    double gap = 8,
  }) {
    var n = math.max(1, math.min(count, columns));
    while (n > 1 && (width - gap * (n - 1)) / n < minimum) {
      n--;
    }
    return n;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final count = fit(
        count: buttons.length,
        columns: columns,
        width: box.maxWidth,
        minimum: minimumCellWidth ?? 100 * scale,
        gap: gap,
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var start = 0; start < buttons.length; start += count) ...[
            if (start != 0) SizedBox(height: runGap ?? gap),
            // A partial final row spans the full width, keeping both outer
            // margins equal.
            DshUiEqualRow(
              gap: gap,
              flex: List.filled(math.min(count, buttons.length - start), 1),
              stretch: List.filled(math.min(count, buttons.length - start), true),
              children: buttons.sublist(start, math.min(start + count, buttons.length)),
            ),
          ],
        ],
      );
    },
  );
}

class DshUiInputView extends StatefulWidget {
  const DshUiInputView({super.key, required this.node});
  final DshUiInput node;
  @override
  State<DshUiInputView> createState() => _DshUiInputViewState();
}

class _DshUiInputViewState extends State<DshUiInputView> {
  late final TextEditingController _text = TextEditingController();
  final _focus = FocusNode();
  final _menu = MenuController();

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final controller = PluginControlsScope.maybeOf(context);
    final value = controller == null ? node.value : controller.value(node);
    final enabled = controller?.enabled == true && !node.readOnly;
    void change(Object? next) => controller?.edit(node, next);
    final error = node.bind == null ? null : controller?.errors[node.bind];
    final label = node.required ? '${node.label} *' : node.label;
    final tones = DshUiPluginTones.of(context);
    final Widget input;
    switch (node.kind) {
      case 'textField':
      case 'number':
        final shown = value == null ? '' : '$value';
        if (_text.text != shown) {
          _text.value = TextEditingValue(
            text: shown,
            selection: TextSelection.collapsed(offset: shown.length),
          );
        }
        final editor = TextField(
          key: ValueKey('input:${node.path}'),
          controller: _text,
          focusNode: _focus,
          readOnly: !enabled,
          enableInteractiveSelection: true,
          maxLines: node.kind == 'textField' ? node.lines : 1,
          minLines: 1,
          maxLength: node.maxLength,
          inputFormatters: [TextInputFormatter.withFunction((old, next) => _limitText(next, node.maxLength))],
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          keyboardType: node.kind == 'number'
              ? const TextInputType.numberWithOptions(decimal: true, signed: true)
              : node.lines > 1
              ? TextInputType.multiline
              : TextInputType.text,
          textInputAction: node.lines > 1 ? TextInputAction.newline : TextInputAction.next,
          autocorrect: node.kind == 'textField',
          obscureText: false,
          style: theme.textTheme.bodyLarge?.copyWith(color: colors.onSurface),
          cursorColor: colors.primary,
          decoration: InputDecoration(
            filled: true,
            fillColor: colors.surface,
            hoverColor: Colors.transparent,
            focusColor: Colors.transparent,
            hintText: node.placeholder,
            hintStyle: TextStyle(color: colors.onSurfaceVariant),
            labelStyle: TextStyle(color: colors.onSurfaceVariant),
            floatingLabelStyle: TextStyle(color: colors.primary),
            counterStyle: TextStyle(color: colors.onSurfaceVariant),
            errorStyle: TextStyle(color: colors.error),
            counterText: '${shown.runes.length}/${node.maxLength}',
            errorText: error,
            errorMaxLines: 3,
            contentPadding: const EdgeInsets.all(12),
            constraints: const BoxConstraints(minHeight: 48),
            border: OutlineInputBorder(borderRadius: AppShape.radiusMd),
            enabledBorder: OutlineInputBorder(
              borderRadius: AppShape.radiusMd,
              borderSide: BorderSide(color: tones.line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: AppShape.radiusMd,
              borderSide: BorderSide(color: colors.primary, width: 2),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: AppShape.radiusMd,
              borderSide: BorderSide(color: colors.error),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: AppShape.radiusMd,
              borderSide: BorderSide(color: colors.error, width: 2),
            ),
          ),
          onChanged: enabled ? change : null,
        );
        input = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(child: _FieldLabel(label)),
            const SizedBox(height: 8),
            Semantics(label: label, child: editor),
          ],
        );
      case 'toggle':
        input = _PluginToggle(
          key: ValueKey('input:${node.path}'),
          label: label,
          value: value == true,
          focusNode: _focus,
          onChanged: enabled ? change : null,
        );
      case 'stepper':
        final current = _number(value, node.min).clamp(node.min, node.max);
        final previous = _step(current, -node.step, node);
        final next = _step(current, node.step, node);
        Widget step({required bool up, required DshUiButtonTone tone}) => DshUiControlButton(
          key: ValueKey('stepper-${up ? 'up' : 'down'}:${node.path}'),
          label: up ? '+' : '−',
          icon: up ? AppIcons.increment : AppIcons.decrement,
          tone: tone,
          semanticLabel: up ? context.l10n.plugInputIncrease(node.label) : context.l10n.plugInputDecrease(node.label),
          onPressed: up
              ? (enabled && next > current ? () => change(next) : null)
              : (enabled && previous < current ? () => change(previous) : null),
        );
        final number = Semantics(
          value: '$current',
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              formatDshUiNumber(current),
              textAlign: TextAlign.center,
              style: AppType.tabular(theme.textTheme.bodyLarge!.copyWith(color: tones.ink)),
            ),
          ),
        );
        input = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FieldLabel(label),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, box) {
                final scale = (MediaQuery.textScalerOf(context).scale(16) / 16).clamp(1.0, 2.0);
                if (box.maxWidth >= 120 + 64 * scale) {
                  // One input-shaped field: − value +, the buttons inside it.
                  return _FieldFrame(
                    key: ValueKey('stepper-field:${node.path}'),
                    child: Row(
                      children: [
                        SizedBox(width: 48, child: step(up: false, tone: DshUiButtonTone.quiet)),
                        Expanded(child: number),
                        SizedBox(width: 48, child: step(up: true, tone: DshUiButtonTone.quiet)),
                      ],
                    ),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _FieldFrame(child: number),
                    const SizedBox(height: 8),
                    DshUiControlChoices(
                      columns: 2,
                      minimumCellWidth: 48,
                      buttons: [
                        step(up: false, tone: DshUiButtonTone.neutral),
                        step(up: true, tone: DshUiButtonTone.neutral),
                      ],
                    ),
                  ],
                );
              },
            ),
          ],
        );
      case 'slider':
        final divisions = ((node.max - node.min) / node.step).round().clamp(1, 1000);
        final Widget slider;
        final String shown;
        if (node.range) {
          final values = value is List ? value : const [];
          final a = _number(values.isEmpty ? null : values[0], node.min).clamp(node.min, node.max);
          final b = _number(values.length < 2 ? null : values[1], node.max).clamp(a, node.max);
          shown = '${formatDshUiNumber(a)} – ${formatDshUiNumber(b)}';
          slider = RangeSlider(
            values: RangeValues(a, b),
            min: node.min,
            max: node.max,
            divisions: divisions,
            // The range track already insets by the (thumb-sized) overlay.
            padding: EdgeInsets.symmetric(vertical: _sliderPadding.vertical / 2),
            labels: RangeLabels(formatDshUiNumber(a), formatDshUiNumber(b)),
            semanticFormatterCallback: (v) => '${node.label}: ${formatDshUiNumber(v)}',
            onChanged: enabled ? (v) => change([v.start, v.end]) : null,
          );
        } else {
          final n = _number(value, node.min).clamp(node.min, node.max);
          shown = formatDshUiNumber(n);
          slider = Slider(
            value: n,
            min: node.min,
            max: node.max,
            divisions: divisions,
            padding: _sliderPadding,
            label: formatDshUiNumber(n),
            semanticFormatterCallback: (v) => '${node.label}: ${formatDshUiNumber(v)}',
            onChanged: enabled ? change : null,
          );
        }
        input = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(child: _FieldLabel(label)),
                const SizedBox(width: 12),
                ExcludeSemantics(
                  child: Text(
                    shown,
                    key: ValueKey('slider-value:${node.path}'),
                    style: AppType.tabular(
                      theme.textTheme.bodyMedium!.copyWith(fontWeight: FontWeight.w600, color: tones.ink),
                    ),
                  ),
                ),
              ],
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: SliderTheme(data: _sliderTheme(context, tones, divisions), child: slider),
            ),
          ],
        );
      case 'select':
        final selected = node.options.where((o) => o.value == value).firstOrNull;
        final colors = Theme.of(context).colorScheme;
        input = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FieldLabel(label),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, box) => MenuAnchor(
                controller: _menu,
                crossAxisUnconstrained: false,
                style: MenuStyle(
                  backgroundColor: WidgetStatePropertyAll(colors.surface),
                  surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
                  padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                ),
                menuChildren: [
                  SizedBox(
                    width: box.maxWidth,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Semantics(
                            header: true,
                            child: Text(
                              context.l10n.plugInputChoices,
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: colors.onSurface),
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 240),
                          child: SingleChildScrollView(
                            primary: false,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final option in node.options)
                                  MenuItemButton(
                                    style: ButtonStyle(
                                      minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
                                      padding: const WidgetStatePropertyAll(EdgeInsets.all(12)),
                                      foregroundColor: WidgetStatePropertyAll(colors.onSurface),
                                      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                                      side: WidgetStateProperty.resolveWith(
                                        (states) => BorderSide(
                                          color: states.contains(WidgetState.focused)
                                              ? colors.outline
                                              : Colors.transparent,
                                          width: 2,
                                        ),
                                      ),
                                    ),
                                    leadingIcon: option.value == value
                                        ? const Icon(AppIcons.done, size: 20)
                                        : const SizedBox.square(dimension: 20),
                                    onPressed: () {
                                      _menu.close();
                                      change(option.value);
                                    },
                                    child: Text(option.label),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                builder: (context, menu, child) => DshUiPickerField(
                  key: ValueKey('select:${node.path}'),
                  text: selected?.label ?? node.placeholder ?? context.l10n.plugInputChoose,
                  placeholder: selected == null,
                  icon: AppIcons.expand,
                  error: error != null,
                  semanticLabel: '$label: ${selected?.label ?? context.l10n.plugInputChoose}',
                  onPressed: enabled && node.options.isNotEmpty ? () => menu.isOpen ? menu.close() : menu.open() : null,
                ),
              ),
            ),
          ],
        );
      case 'segmented':
      case 'chips':
        final selected = node.multi && value is List ? value : [value];
        void pick(int index) {
          final option = node.options[index];
          if (!node.multi) {
            change(option.value);
            return;
          }
          final next = <String>[
            for (final o in node.options)
              if (selected.contains(o.value)) o.value,
          ];
          if (next.contains(option.value)) {
            next.remove(option.value);
          } else {
            next.add(option.value);
          }
          change(next);
        }

        final choices = [
          for (final option in node.options)
            DshUiChoice(
              key: ValueKey('choice:${node.path}:${option.value}'),
              label: option.label,
              selected: selected.contains(option.value),
            ),
        ];
        input = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FieldLabel(label),
            const SizedBox(height: 8),
            if (node.kind == 'segmented')
              DshUiSegmented(choices: choices, onSelect: enabled ? pick : null)
            else
              DshUiChips(choices: choices, multi: node.multi, onToggle: enabled ? pick : null),
          ],
        );
      case 'date':
      case 'time':
        final hasValue = value is String && value.isNotEmpty;
        input = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FieldLabel(label),
            const SizedBox(height: 8),
            DshUiPickerField(
              key: ValueKey('${node.kind}:${node.path}'),
              text: hasValue ? value : node.placeholder ?? context.l10n.plugInputChoose,
              placeholder: !hasValue,
              icon: node.kind == 'date' ? AppIcons.calendar : AppIcons.time,
              error: error != null,
              semanticLabel: '$label: ${hasValue ? value : context.l10n.plugInputChoose}',
              onPressed: !enabled
                  ? null
                  : () async {
                      if (node.kind == 'date') {
                        final first = node.minDate ?? DateTime(1900);
                        final last = node.maxDate ?? DateTime(2100, 12, 31);
                        var initial = dshUiInputDate(value) ?? DateTime.now();
                        if (initial.isBefore(first)) initial = first;
                        if (initial.isAfter(last)) initial = last;
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: initial,
                          firstDate: first,
                          lastDate: last,
                          helpText: context.l10n.plugInputDatePicker,
                          builder: (context, child) => _pickerTheme(context, child!),
                        );
                        if (picked != null && mounted && controller?.enabled == true) {
                          change(
                            '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}',
                          );
                        }
                      } else {
                        final time = dshUiInputTime(value);
                        final picked = await showTimePicker(
                          context: context,
                          initialTime: time == null
                              ? const TimeOfDay(hour: 12, minute: 0)
                              : TimeOfDay(hour: time.$1, minute: time.$2),
                          helpText: context.l10n.plugInputTimePicker,
                          builder: (context, child) => _pickerTheme(context, child!),
                        );
                        if (picked != null && mounted && controller?.enabled == true) {
                          change(
                            '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}',
                          );
                        }
                      }
                    },
            ),
          ],
        );
      case 'rating':
        final current = _number(value, 0).round();
        input = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FieldLabel(label),
            const SizedBox(height: 4),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: DshUiRatingStars(
                max: node.max.toInt(),
                value: current,
                keyPrefix: 'rating:${node.path}',
                semanticLabel: (i) => context.l10n.plugInputRating(node.label, i, node.max.toInt()),
                onChanged: enabled ? change : null,
              ),
            ),
          ],
        );
      default:
        input = const SizedBox.shrink();
    }
    return Semantics(
      container: true,
      label: node.kind == 'textField' || node.kind == 'number' ? null : node.label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          input,
          if (error != null && node.kind != 'textField' && node.kind != 'number') ...[
            const SizedBox(height: 4),
            _ControlError(error),
          ],
        ],
      ),
    );
  }
}

double _number(Object? value, double fallback) {
  final n = value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value)
      : null;
  return n != null && n.isFinite ? n : fallback;
}

TextEditingValue _limitText(TextEditingValue value, int max) {
  final runes = value.text.runes.take(max + 1).toList();
  if (runes.length <= max) return value;
  final text = String.fromCharCodes(runes.take(max));
  return TextEditingValue(
    text: text,
    selection: TextSelection(
      baseOffset: value.selection.baseOffset.clamp(0, text.length),
      extentOffset: value.selection.extentOffset.clamp(0, text.length),
    ),
  );
}

// Keep the exact representable value: display rounding must never rewrite
// a valid bound. A direction with no representable progress is disabled above.
double _step(double value, double change, DshUiInput node) => (value + change).clamp(node.min, node.max);

class _ControlPadding extends StatelessWidget {
  const _ControlPadding({required this.path, required this.child});
  final String path;
  final Widget child;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => Padding(
      key: ValueKey('plugin-control-padding:$path'),
      padding: dshUiPluginAdaptivePadding(context, requested: 12, availableWidth: box.maxWidth),
      child: child,
    ),
  );
}

/// The thumb sits flush with the field edges at both ends; the slider stays
/// a 48 dp target.
const _sliderPadding = EdgeInsets.symmetric(horizontal: 10, vertical: 14);

/// No drop shadow under the thumb (it read as a dark ring), and no tick dots
/// once there are more steps than the eye can count.
SliderThemeData _sliderTheme(BuildContext context, DshUiPluginTones tones, int divisions) {
  final base = SliderTheme.of(context);
  return base.copyWith(
    trackHeight: 4,
    activeTrackColor: tones.accent,
    inactiveTrackColor: tones.line,
    thumbColor: tones.accent,
    overlayColor: Colors.transparent,
    overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10, elevation: 0, pressedElevation: 0),
    rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 10, elevation: 0, pressedElevation: 0),
    tickMarkShape: divisions > 10 ? SliderTickMarkShape.noTickMark : null,
    rangeTickMarkShape: divisions > 10 ? const RoundRangeSliderTickMarkShape(tickMarkRadius: 0) : null,
    activeTickMarkColor: tones.tint,
    inactiveTickMarkColor: tones.surface,
  );
}

/// Where a text field's typed text starts (12 dp padding + 4 dp input gap).
const _fieldInset = 16.0;

/// The input outline shared by text fields, pickers and the stepper.
class _FieldFrame extends StatelessWidget {
  const _FieldFrame({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final tones = DshUiPluginTones.of(context);
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: AppShape.radiusMd,
        border: Border.all(color: tones.line),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(color: tones.surface, borderRadius: AppShape.radiusMd),
        child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 48), child: child),
      ),
    );
  }
}

/// A select, date or time value drawn as an input: the value at the start in
/// the text-field style, a trailing icon, the same outline, height and focus
/// treatment as a text field. Semantically it is a labelled button.
class DshUiPickerField extends StatefulWidget {
  const DshUiPickerField({
    super.key,
    required this.text,
    required this.icon,
    required this.semanticLabel,
    this.placeholder = false,
    this.error = false,
    this.onPressed,
  });
  final String text;
  final IconData icon;
  final String semanticLabel;
  final bool placeholder;
  final bool error;
  final VoidCallback? onPressed;
  @override
  State<DshUiPickerField> createState() => _DshUiPickerFieldState();
}

class _DshUiPickerFieldState extends State<DshUiPickerField> {
  bool _focused = false;
  bool _hovered = false;
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = DshUiPluginTones.of(context);
    final active = widget.onPressed != null && (_focused || _hovered || _pressed);
    final edge = widget.error
        ? theme.colorScheme.error
        : active
        ? tones.accent
        : tones.line;
    final shape = RoundedRectangleBorder(
      borderRadius: AppShape.radiusMd,
      side: BorderSide(color: edge, width: active ? 2 : 1),
    );
    return Semantics(
      button: true,
      enabled: widget.onPressed != null,
      label: widget.semanticLabel,
      child: Material(
        color: tones.surface,
        shape: shape,
        child: InkWell(
          customBorder: shape,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          onFocusChange: (v) => setState(() => _focused = v),
          onHover: (v) => setState(() => _hovered = v),
          onHighlightChanged: (v) => setState(() => _pressed = v),
          onTap: widget.onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              key: const ValueKey('plugin-field-padding'),
              // A text field's value sits at its 12 dp content padding plus
              // Flutter's 4 dp outline gap; the picker value and icon match.
              padding: const EdgeInsets.symmetric(horizontal: _fieldInset, vertical: 12),
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.text,
                        style: theme.textTheme.bodyLarge?.copyWith(color: widget.placeholder ? tones.muted : tones.ink),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Icon(widget.icon, size: 20, color: widget.onPressed == null ? tones.inactive : tones.muted),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A toggle row: the label starts at the same edge as every other field
/// label, the switch track ends at the same edge as every input. The whole
/// row is one labelled toggle; focus thickens and darkens the track outline
/// instead of washing the row, so the verified switch colours never change.
class _PluginToggle extends StatefulWidget {
  const _PluginToggle({super.key, required this.label, required this.value, required this.focusNode, this.onChanged});
  final String label;
  final bool value;
  final FocusNode focusNode;
  final ValueChanged<bool>? onChanged;

  @override
  State<_PluginToggle> createState() => _PluginToggleState();
}

class _PluginToggleState extends State<_PluginToggle> {
  bool _hovered = false;
  bool _pressed = false;
  bool get _active => widget.focusNode.hasFocus || _hovered || _pressed;
  void _changed() => setState(() {});

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_changed);
  }

  @override
  void didUpdateWidget(_PluginToggle old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_changed);
      widget.focusNode.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tones = DshUiPluginTones.of(context);
    final active = _active && widget.onChanged != null;
    final switchTheme = SwitchThemeData(
      materialTapTargetSize: MaterialTapTargetSize.padded,
      padding: EdgeInsets.zero,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? colors.primary : colors.surface,
      ),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? colors.onPrimary : colors.onSurface,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => active
            ? tones.ink
            : states.contains(WidgetState.selected)
            ? colors.primary
            : colors.onSurface,
      ),
      trackOutlineWidth: WidgetStateProperty.resolveWith(
        (states) =>
            active || states.any({WidgetState.focused, WidgetState.hovered, WidgetState.pressed}.contains) ? 3 : 2,
      ),
      thumbIcon: WidgetStateProperty.resolveWith(
        (states) => Icon(
          AppIcons.selected,
          size: 14,
          color: states.contains(WidgetState.selected) ? colors.primary : Colors.transparent,
        ),
      ),
    );
    final label = Text(widget.label, style: theme.textTheme.bodyLarge?.copyWith(color: colors.onSurface));
    final toggle = Switch.adaptive(
      key: const ValueKey('plugin-toggle-switch'),
      value: widget.value,
      onChanged: widget.onChanged,
      focusNode: widget.focusNode,
    );
    return Theme(
      data: theme.copyWith(
        switchTheme: switchTheme,
        splashFactory: NoSplash.splashFactory,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
      ),
      child: MergeSemantics(
        child: InkWell(
          canRequestFocus: false,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          onHover: (v) => setState(() => _hovered = v),
          onHighlightChanged: (v) => setState(() => _pressed = v),
          onTap: widget.onChanged == null ? null : () => widget.onChanged!(!widget.value),
          child: LayoutBuilder(
            builder: (context, box) {
              if (box.maxWidth < dshUiPluginContentMinWidth(context)) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [label, toggle],
                );
              }
              return ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    Expanded(child: label),
                    const SizedBox(width: 12),
                    toggle,
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ControlError extends StatelessWidget {
  const _ControlError(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
    ),
  );
}

/// A field's name above its control: one size and weight for every input.
class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500));
}

class DshUiControlContainerView extends StatefulWidget {
  const DshUiControlContainerView({super.key, required this.node, required this.depth});
  final DshUiControlContainer node;
  final int depth;
  @override
  State<DshUiControlContainerView> createState() => _DshUiControlContainerViewState();
}

class _DshUiControlContainerViewState extends State<DshUiControlContainerView> {
  int _page = 0;
  final _open = <int>{};
  @override
  void initState() {
    super.initState();
    if (widget.node.expanded) _open.add(0);
  }

  /// Fields of a form breathe a little more than content in a section.
  Widget content(Iterable<DshUiNode> nodes, {double gap = 12}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final (i, node) in nodes.indexed) ...[
        if (i != 0) SizedBox(height: gap),
        DshUiNodeView(key: ValueKey(node.path), node: node, depth: widget.depth + 1),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final controller = PluginControlsScope.maybeOf(context);
    if (node.sections.isEmpty) return const DshUiEmptyBlock();
    _page = _page.clamp(0, node.sections.length - 1);
    switch (node.kind) {
      case 'form':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (node.label != null) ...[
              Semantics(header: true, child: Text(node.label!, style: Theme.of(context).textTheme.titleMedium)),
              const SizedBox(height: 16),
            ],
            content(node.children, gap: 16),
            if (controller?.formErrors[node.path] case final error?) ...[
              const SizedBox(height: 8),
              _ControlError(error),
            ],
            if (controller?.enabled == true) ...[
              const SizedBox(height: 20),
              DshUiControlButton(
                key: ValueKey('submit:${node.path}'),
                label: node.submitLabel ?? context.l10n.plugInputSubmit,
                tone: DshUiButtonTone.primary,
                busy: controller!.busy(node.path),
                onPressed: () => controller.submit(node),
              ),
            ],
          ],
        );
      case 'grid':
        final children = node.children.toList();
        final tones = DshUiPluginTones.of(context);
        return DshUiControlChoices(
          columns: node.columns,
          minimumCellWidth: dshUiPluginContentMinWidth(context),
          buttons: [
            for (final child in children)
              DecoratedBox(
                key: ValueKey('plugin-grid-cell:${child.path}'),
                decoration: ShapeDecoration(
                  color: tones.surface,
                  shape: Squircle.border(AppShape.md, side: BorderSide(color: tones.hairline)),
                ),
                // Cells share the row height; their content starts at the top.
                child: DshUiCellFill(
                  child: _ControlPadding(
                    path: child.path,
                    child: DshUiNodeView(node: child, depth: widget.depth + 1),
                  ),
                ),
              ),
          ],
        );
      case 'collapsible':
      case 'accordion':
        final tones = DshUiPluginTones.of(context);
        final sections = node.kind == 'collapsible'
            ? [(node.label ?? context.l10n.commonDetails, node.children)]
            : [for (final section in node.sections) (section.label, section.children)];
        // One outlined group: a header row per section (title, caret), the
        // open section's content directly under its header.
        return DecoratedBox(
          key: ValueKey('plugin-fold:${node.path}'),
          position: DecorationPosition.foreground,
          decoration: ShapeDecoration(
            shape: Squircle.border(AppShape.md, side: BorderSide(color: tones.hairline)),
          ),
          child: LayoutBuilder(
            builder: (context, box) {
              final inset = dshUiPluginAdaptivePadding(context, requested: 12, availableWidth: box.maxWidth).left;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (i, (label, children)) in sections.indexed) ...[
                    if (i != 0) Divider(height: 1, thickness: 1, color: tones.hairline),
                    _FoldHeader(
                      key: ValueKey('plugin-fold-header:${node.path}:$i'),
                      label: label,
                      open: _open.contains(i),
                      inset: inset,
                      onTap: () => setState(() {
                        if (!_open.remove(i)) _open.add(i);
                      }),
                    ),
                    ExpandReveal(
                      open: _open.contains(i),
                      child: Padding(
                        key: ValueKey('plugin-fold-body:${node.path}:$i'),
                        // The header's own 12 dp bottom space is above.
                        padding: EdgeInsets.fromLTRB(inset, 0, inset, inset),
                        child: content(children),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        );
      case 'tabs':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            DshUiTabBar(
              labels: [for (final section in node.sections) section.label],
              selected: _page,
              onSelect: (i) => setState(() => _page = i),
            ),
            const SizedBox(height: 12),
            content(node.sections[_page].children),
          ],
        );
      case 'carousel':
        final count = node.sections.length;
        final section = node.sections[_page];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              liveRegion: true,
              label: '${section.label} · ${_page + 1}/$count',
              excludeSemantics: true,
              child: Text(
                section.label,
                key: ValueKey('plugin-carousel-title:${node.path}'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 8),
            content(section.children),
            const SizedBox(height: 4),
            _CarouselPager(
              path: node.path,
              count: count,
              page: _page,
              onPrevious: _page == 0 ? null : () => setState(() => _page--),
              onNext: _page + 1 == count ? null : () => setState(() => _page++),
            ),
          ],
        );
      case 'timeline':
        final tones = DshUiPluginTones.of(context);
        final theme = Theme.of(context);
        final title = theme.textTheme.titleMedium!;
        final line = MediaQuery.textScalerOf(context).scale(title.fontSize!) * title.height!;
        // A numbered dot on the first line of each step's title.
        final dot = math.max(24.0, line);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, section) in node.sections.indexed)
              Padding(
                padding: EdgeInsets.only(bottom: i + 1 < node.sections.length ? 16 : 0),
                child: LayoutBuilder(
                  builder: (context, box) {
                    final body = Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: (dot - line) / 2),
                          child: Text(section.label, style: title),
                        ),
                        if (section.children.isNotEmpty) ...[const SizedBox(height: 4), content(section.children)],
                      ],
                    );
                    final marker = ExcludeSemantics(
                      child: SizedBox(
                        key: ValueKey('plugin-timeline-marker:${node.path}:$i'),
                        width: dot,
                        height: dot,
                        child: DecoratedBox(
                          decoration: ShapeDecoration(color: tones.well, shape: const CircleBorder()),
                          child: Center(
                            child: Text(
                              '${i + 1}',
                              style: AppType.tabular(
                                theme.textTheme.labelMedium!.copyWith(color: tones.wellInk, height: 1),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                    if (box.maxWidth < dot + 12 + dshUiPluginContentMinWidth(context)) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [marker, const SizedBox(height: 8), body],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        marker,
                        const SizedBox(width: 12),
                        Expanded(child: body),
                      ],
                    );
                  },
                ),
              ),
          ],
        );
      default:
        return content(node.children);
    }
  }
}

/// A fold's header row: the section title at the content edge, a caret at
/// the far edge that turns when the section opens. One labelled button with
/// its expanded state; focus, hover and press draw an inset outline.
class _FoldHeader extends StatelessWidget {
  const _FoldHeader({super.key, required this.label, required this.open, required this.inset, required this.onTap});
  final String label;
  final bool open;
  final double inset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tones = DshUiPluginTones.of(context);
    return Semantics(
      button: true,
      expanded: open,
      label: label,
      child: DshUiPressable(
        onTap: onTap,
        builder: (context, active) => DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: ShapeDecoration(
            shape: Squircle.border(
              AppShape.md,
              side: active ? BorderSide(color: tones.line, width: 2) : BorderSide.none,
            ),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              key: const ValueKey('plugin-fold-header-padding'),
              padding: EdgeInsets.symmetric(horizontal: inset, vertical: 12),
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(label, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: tones.ink)),
                    ),
                    const SizedBox(width: 12),
                    AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: AppMotion.of(context, AppMotion.collapse),
                      curve: AppMotion.collapseCurve,
                      child: Icon(AppIcons.expand, size: 20, color: tones.muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A light pager under a carousel: quiet ‹ › targets around page dots (or
/// "2 / 7" when the dots do not fit). The arrows carry the screen-reader
/// labels; the title above announces the page.
class _CarouselPager extends StatelessWidget {
  const _CarouselPager({
    required this.path,
    required this.count,
    required this.page,
    required this.onPrevious,
    required this.onNext,
  });
  final String path;
  final int count;
  final int page;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  static const dot = 6.0;
  static const activeDot = 18.0;
  static const dotGap = 6.0;

  @override
  Widget build(BuildContext context) {
    final tones = DshUiPluginTones.of(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final previous = DshUiControlButton(
      key: ValueKey('carousel-previous:$path'),
      label: context.l10n.plugInputPrevious,
      semanticLabel: context.l10n.plugInputPrevious,
      icon: AppIcons.pagePrevious,
      mirrorIcon: rtl,
      tone: DshUiButtonTone.quiet,
      onPressed: onPrevious,
    );
    final next = DshUiControlButton(
      key: ValueKey('carousel-next:$path'),
      label: context.l10n.plugInputNext,
      semanticLabel: context.l10n.plugInputNext,
      icon: AppIcons.pageNext,
      tone: DshUiButtonTone.quiet,
      onPressed: onNext,
    );
    final dotsWidth = (count - 1) * (dot + dotGap) + activeDot;
    return LayoutBuilder(
      builder: (context, box) {
        final Widget position = box.maxWidth >= 2 * 48 + 2 * 8 + dotsWidth
            ? Row(
                key: ValueKey('carousel-dots:$path'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < count; i++) ...[
                    if (i != 0) const SizedBox(width: dotGap),
                    AnimatedContainer(
                      duration: AppMotion.of(context, AppMotion.quick),
                      width: i == page ? activeDot : dot,
                      height: dot,
                      decoration: ShapeDecoration(
                        color: i == page ? tones.accent : tones.line,
                        shape: const StadiumBorder(),
                      ),
                    ),
                  ],
                ],
              )
            : Text(
                '${page + 1} / $count',
                key: ValueKey('carousel-count:$path'),
                style: AppType.tabular(Theme.of(context).textTheme.labelLarge!.copyWith(color: tones.muted)),
              );
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            previous,
            const SizedBox(width: 8),
            Flexible(child: ExcludeSemantics(child: position)),
            const SizedBox(width: 8),
            next,
          ],
        );
      },
    );
  }
}

class DshUiControlDisplayView extends StatelessWidget {
  const DshUiControlDisplayView({super.key, required this.node});
  final DshUiControlDisplay node;
  @override
  Widget build(BuildContext context) {
    switch (node.kind) {
      case 'codeBlock':
        return _PluginCodeBlock(path: node.path, code: node.text ?? '', language: node.language);
      case 'avatar':
        return Align(
          alignment: AlignmentDirectional.topStart,
          child: SizedBox.square(
            dimension: 48,
            child: ClipRRect(
              borderRadius: AppShape.radiusMd,
              child: _PluginAvatar(image: node.image!),
            ),
          ),
        );
      case 'badge':
      case 'tag':
        // A quiet tonal label, never an outlined box that reads as a button.
        // 4 dp above and below the 12 sp line looks as wide as the 8 dp sides.
        final tones = DshUiPluginTones.of(context);
        return Align(
          alignment: AlignmentDirectional.topStart,
          child: DecoratedBox(
            key: ValueKey('plugin-badge:${node.path}'),
            decoration: ShapeDecoration(color: tones.well, shape: Squircle.border(AppShape.sm)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                node.text ?? '',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(color: tones.wellInk),
              ),
            ),
          ),
        );
      case 'divider':
        return Divider(height: 16, thickness: 1, color: DshUiPluginTones.of(context).hairline);
      case 'spacer':
        return SizedBox(
          height: switch (node.size) {
            'S' => 8,
            'L' => 24,
            _ => 16,
          },
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

/// The ordinary image fallback includes text; an avatar uses an icon so its
/// bounded 48 dp square also fits when a resource is missing or undecodable.
class _PluginAvatar extends StatelessWidget {
  const _PluginAvatar({required this.image});
  final DshUiImage image;
  @override
  Widget build(BuildContext context) {
    final ImageProvider? base = switch (image.source) {
      DshUiDataImage(:final bytes) => MemoryImage(bytes),
      final DshUiAssetImage asset =>
        (DshUiPluginScope.maybeOf(context)?.imageResolver ?? PluginImages.maybeOf(context)?.resolver)?.call(asset.src),
      null => null,
    };
    final colors = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: colors.surface,
      child: Center(child: Icon(AppIcons.image, size: 24, color: colors.onSurface)),
    );
    return Semantics(
      image: true,
      label: image.alt,
      child: base == null
          ? placeholder
          : Image(
              image: ResizeImage(
                base,
                width: (48 * MediaQuery.devicePixelRatioOf(context)).round().clamp(1, 512),
                policy: ResizeImagePolicy.fit,
              ),
              fit: BoxFit.cover,
              frameBuilder: (context, child, frame, sync) => frame == null && !sync ? placeholder : child,
              errorBuilder: (context, error, stack) => placeholder,
            ),
    );
  }
}

/// Reuses the chat highlighter and its cache. The plugin's copy affordance has
/// the same 48 dp minimum and all-side padding as its other controls.
class _PluginCodeBlock extends StatefulWidget {
  const _PluginCodeBlock({required this.path, required this.code, this.language});
  final String path;
  final String code;
  final String? language;
  @override
  State<_PluginCodeBlock> createState() => _PluginCodeBlockState();
}

class _PluginCodeBlockState extends State<_PluginCodeBlock> {
  bool _copied = false;
  @override
  void didUpdateWidget(_PluginCodeBlock old) {
    super.didUpdateWidget(old);
    if (old.code != widget.code) _copied = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = DshUiPluginTones.of(context);
    final copied = _copied;
    // Header strip: language at the content edge, copy at the far edge,
    // both centred on one 48 dp line (as in the chat code block).
    final header = ColoredBox(
      key: ValueKey('plugin-code-header:${widget.path}'),
      color: tones.well,
      child: LayoutBuilder(
        builder: (context, box) {
          final inset = dshUiPluginAdaptivePadding(context, requested: 12, availableWidth: box.maxWidth).left;
          final label = copied ? context.l10n.commonCopied : context.l10n.commonCopy;
          // Narrow: the copy target keeps its glyph and drops the word.
          final compact = box.maxWidth < dshUiPluginContentMinWidth(context) + 48;
          return ConstrainedBox(
            constraints: const BoxConstraints(minHeight: DshUiControlButton.minimumHeight),
            child: Row(
              children: [
                SizedBox(width: inset),
                Expanded(
                  child: Text(
                    widget.language ?? '',
                    key: ValueKey('plugin-code-language:${widget.path}'),
                    style: AppType.monoLabel(color: tones.wellMuted),
                  ),
                ),
                const SizedBox(width: 8),
                DshUiControlButton(
                  key: ValueKey('plugin-code-copy:${widget.path}'),
                  label: label,
                  semanticLabel: label,
                  icon: compact ? (copied ? AppIcons.done : AppIcons.copy) : null,
                  leadingIcon: compact ? null : (copied ? AppIcons.done : AppIcons.copy),
                  tone: DshUiButtonTone.quiet,
                  small: true,
                  fill: tones.well,
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: widget.code));
                    if (mounted) setState(() => _copied = true);
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: ShapeDecoration(
        shape: Squircle.border(AppShape.md, side: BorderSide(color: tones.hairline)),
      ),
      child: Squircle.clip(
        radius: AppShape.md,
        child: DecoratedBox(
          decoration: BoxDecoration(color: tones.surface),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              _ControlPadding(
                path: widget.path,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: SingleChildScrollView(
                    primary: false,
                    child: SingleChildScrollView(
                      primary: false,
                      scrollDirection: Axis.horizontal,
                      child: SelectableText.rich(
                        _readableCodeSpan(
                          highlightCode(
                            widget.code,
                            widget.language,
                            theme.brightness,
                            style: AppType.mono().copyWith(color: tones.ink),
                          ),
                          tones.surface,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Retain the existing highlighter's tokens and cache, while its source palette
// is corrected against the exact opaque surface painted by this code block.
TextSpan _readableCodeSpan(TextSpan span, Color background) {
  final color = span.style?.color;
  final actualBackground = span.style?.backgroundColor ?? background;
  return TextSpan(
    text: span.text,
    style: color == null
        ? span.style
        : span.style!.copyWith(
            color: Color(
              0xFF000000 | dshUiReadableColor(color.toARGB32() & 0xFFFFFF, actualBackground.toARGB32() & 0xFFFFFF),
            ),
          ),
    children: span.children
        ?.map((child) => child is TextSpan ? _readableCodeSpan(child, actualBackground) : child)
        .toList(),
  );
}

Widget _pickerTheme(BuildContext context, Widget child) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  return Theme(
    data: theme.copyWith(
      dialogTheme: theme.dialogTheme.copyWith(backgroundColor: colors.surface, surfaceTintColor: Colors.transparent),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colors.onSurface,
          padding: const EdgeInsets.all(12),
          minimumSize: const Size(48, 48),
          overlayColor: Colors.transparent,
        ),
      ),
      inputDecorationTheme: theme.inputDecorationTheme.copyWith(
        fillColor: colors.surface,
        labelStyle: TextStyle(color: colors.onSurfaceVariant),
        hintStyle: TextStyle(color: colors.onSurfaceVariant),
        floatingLabelStyle: TextStyle(color: colors.primary),
      ),
      datePickerTheme: theme.datePickerTheme.copyWith(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        headerBackgroundColor: colors.surface,
        headerForegroundColor: colors.onSurface,
      ),
      timePickerTheme: theme.timePickerTheme.copyWith(
        backgroundColor: colors.surface,
        dialBackgroundColor: colors.surface,
        dialHandColor: colors.primary,
        dialTextColor: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.selected) ? colors.onPrimary : colors.onSurface,
        ),
        hourMinuteColor: colors.surface,
        hourMinuteTextColor: colors.onSurface,
        dayPeriodColor: colors.surface,
        dayPeriodTextColor: colors.onSurface,
        dayPeriodBorderSide: BorderSide(color: colors.outline),
        helpTextStyle: theme.textTheme.labelSmall?.copyWith(color: colors.onSurface),
      ),
    ),
    child: child,
  );
}
