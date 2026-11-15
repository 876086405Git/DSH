// The sheets behind the engine settings rows: a number with a mirrored
// stepper, a line of text, a choice list, a write-only secret, a list /
// key-value editor, items of an object list and a read-only value. Each has
// one primary button at most; the restore action is its outlined mirror image.

import 'dart:async';
import 'dart:convert';

import 'numeric_edit_math.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/engine_settings_state.dart';
import '../common/app_sheet.dart';
import '../common/sheet_navigator.dart';
import '../common/sheet_title_bar.dart';
import '../common/smooth_size.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'field_row.dart';
import 'schema_fields.dart';

/// Content of a field sheet: title bar, body, the action row; lifted above
/// the keyboard.
class FieldSheetFrame extends StatelessWidget {
  const FieldSheetFrame({super.key, required this.title, required this.children, this.actions});

  final String title;
  final List<Widget> children;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(title),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: kSheetGutter),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
              ),
            ),
            if (actions case final actions?)
              Padding(padding: const EdgeInsets.fromLTRB(kSheetGutter, 16, kSheetGutter, 12), child: actions),
          ],
        ),
      ),
    );
  }
}

/// [primary] alone across the row, or the outlined [secondary] on its left at
/// the same width and height.
class SheetActions extends StatelessWidget {
  const SheetActions({super.key, required this.primary, this.secondary});

  final Widget primary;
  final Widget? secondary;

  static const height = 48.0;

  @override
  Widget build(BuildContext context) {
    if (secondary == null) return SizedBox(height: height, child: primary);
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: secondary!),
          const SizedBox(width: 12),
          Expanded(child: primary),
        ],
      ),
    );
  }
}

ButtonStyle _fill(BuildContext context) =>
    FilledButton.styleFrom(minimumSize: const Size.fromHeight(SheetActions.height));

ButtonStyle _outline(BuildContext context, {Color? color}) => OutlinedButton.styleFrom(
  minimumSize: const Size.fromHeight(SheetActions.height),
  foregroundColor: color,
  side: color == null ? null : BorderSide(color: color.withValues(alpha: 0.4)),
);

/// A helper line under a field: the error in the danger colour when there is
/// one, else [helper]; height changes glide.
class SheetHelper extends StatelessWidget {
  const SheetHelper({super.key, this.helper, this.error});

  final String? helper;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final text = error ?? helper;
    return SmoothSize(
      duration: AppMotion.of(context, AppMotion.quick),
      curve: AppMotion.std,
      alignment: Alignment.topLeft,
      child: text == null || text.isEmpty
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(color: error != null ? colors.danger : colors.textTertiary),
              ),
            ),
    );
  }
}

/// Card-tier glass around a sheet's main control.
class SheetCard extends StatelessWidget {
  const SheetCard({super.key, required this.child, this.padding = const EdgeInsets.all(12)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => GlassSurface(
    tier: GlassTier.card,
    borderRadius: AppShape.radiusLg,
    child: Padding(padding: padding, child: child),
  );
}

/// Opens a field's sheet: sized to its content, lifted above the keyboard,
/// closed by the × in its title bar (an editor) unless [dismissal] says the
/// handle (a picker that closes on its own).
Future<T?> showFieldSheet<T>(
  BuildContext context,
  WidgetBuilder builder, {
  SheetDismissal dismissal = SheetDismissal.button,
}) => showAppSheet<T>(context, isScrollControlled: true, dismissal: dismissal, builder: builder);

/// The action row of a sheet that edits one value: 完成, with 恢复默认 on
/// its left while the value is the user's own ([onRestore]). Both wait while
/// a save is in flight.
class EditorSheetActions extends StatelessWidget {
  const EditorSheetActions({super.key, required this.busy, required this.onDone, this.onRestore});

  final bool busy;
  final VoidCallback onDone;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final restore = onRestore;
    return SheetActions(
      secondary: restore == null
          ? null
          : OutlinedButton(
              style: _outline(context),
              onPressed: busy ? null : restore,
              child: Text(l10n.engineFieldRestoreDefault),
            ),
      primary: FilledButton(style: _fill(context), onPressed: busy ? null : onDone, child: Text(l10n.commonDone)),
    );
  }
}

/// Shared acknowledgement handling for scalar editors. A rejected write keeps
/// the draft available; duplicate taps do not issue duplicate mutations.
mixin _AcknowledgedSheet<T extends StatefulWidget> on State<T> {
  bool _busy = false;
  String? _error;

  Future<void> _save(Future<bool> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    var saved = false;
    try {
      saved = await action();
    } catch (_) {
      // Transport/controller failures have the same retryable local UX.
    }
    if (!mounted) return;
    if (saved) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = context.l10n.commonSaveFailed;
      });
    }
  }
}

// ── Number ───────────────────────────────────────────────────────────────────

/// Edits a number: − and + mirrored around the typed value, a slider for a
/// short bounded range, the range and default under it. [onSubmit] gets the
/// stored value; [onReset] restores the inherited one.
Future<void> showNumberSheet(
  BuildContext context, {
  required String title,
  required SchemaMeta meta,
  required FieldUnit unit,
  required num? current,
  required num? inherited,
  required bool modified,
  required Future<bool> Function(num) onSubmit,
  required Future<bool> Function() onReset,
  String? suffix,
  FieldCountUnit? countUnit,
}) => showFieldSheet<void>(
  context,
  (_) => NumberFieldSheet(
    title: title,
    meta: meta,
    unit: unit,
    suffix: suffix,
    countUnit: countUnit,
    current: current,
    inherited: inherited,
    modified: modified,
    onSubmit: onSubmit,
    onReset: onReset,
  ),
);

class NumberFieldSheet extends StatefulWidget {
  const NumberFieldSheet({
    super.key,
    required this.title,
    required this.meta,
    required this.unit,
    required this.current,
    required this.inherited,
    required this.modified,
    required this.onSubmit,
    required this.onReset,
    this.suffix,
    this.countUnit,
  });

  final String title;
  final SchemaMeta meta;
  final FieldUnit unit;

  /// Counted unit of a plain number, shown beside it.
  final String? suffix;
  final FieldCountUnit? countUnit;
  final num? current;
  final num? inherited;
  final bool modified;
  final Future<bool> Function(num) onSubmit;
  final Future<bool> Function() onReset;

  /// The round − / + keys.
  static const keySize = 44.0;

  @override
  State<NumberFieldSheet> createState() => _NumberFieldSheetState();
}

String _typedText(num? stored, FieldUnit unit) {
  if (stored == null) return '';
  final typed = toEditValue(stored, unit);
  return typed.toString().replaceFirst(RegExp(r'\.0$'), '');
}

class _NumberFieldSheetState extends State<NumberFieldSheet> with _AcknowledgedSheet<NumberFieldSheet> {
  late final _controller = TextEditingController(text: _typedText(widget.current ?? widget.inherited, widget.unit));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  num? get _min => meaningfulMin(widget.meta);
  num? get _max => meaningfulMax(widget.meta);

  num? get _stored {
    final typed = num.tryParse(_controller.text.trim());
    return typed == null ? null : fromEditValue(typed, widget.unit);
  }

  void _setStored(num stored) {
    if (!stored.isFinite) return;
    var value = stored;
    if (_min case final min? when value < min) value = min;
    if (_max case final max? when value > max) value = max;
    final text = _typedText(value, widget.unit);
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() => _error = null);
  }

  void _step(int direction) {
    HapticFeedback.selectionClick();
    final step = widget.meta.step;
    final storedStep = step != null && step.isFinite && step != 0
        ? step.abs()
        : fromEditValue(editStep(widget.meta, widget.unit), widget.unit);
    final base = _stored ?? widget.inherited ?? _min ?? 0;
    final next = decimalStepValue(base, storedStep, direction);
    if (next != null) _setStored(next);
  }

  bool get _canDown {
    final stored = _stored;
    return stored == null || _min == null || stored > _min!;
  }

  bool get _canUp {
    final stored = _stored;
    return stored == null || _max == null || stored < _max!;
  }

  num get _sliderStep {
    final step = widget.meta.step;
    return step != null && step.isFinite && step != 0 ? step.abs() : (widget.unit == FieldUnit.ratio ? 0.01 : 1);
  }

  int? get _sliderDivisions => widget.unit == FieldUnit.bytes ? null : schemaSliderDivisions(_min, _max, _sliderStep);

  void _submit() {
    if (_busy) return;
    final text = _controller.text.trim();
    if (text.isEmpty) {
      if (widget.modified) {
        unawaited(_save(widget.onReset));
      } else {
        Navigator.of(context).pop();
      }
      return;
    }
    final error = validateNumber(text, widget.meta, widget.unit);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final stored = _stored!;
    if (stored == (widget.current ?? widget.inherited)) {
      Navigator.of(context).pop();
    } else {
      unawaited(_save(() => widget.onSubmit(stored)));
    }
  }

  String? get _unitLabel => editUnitLabel(widget.unit) ?? widget.suffix;

  String? get _helper {
    final unitLabel = _unitLabel;
    final range = rangeText(widget.meta, widget.unit);
    final inherited = widget.inherited;
    return [
      if (range != null)
        unitLabel == null || (_min != null && _min! > 0 && _min! < 1e-300) ? range : '$range $unitLabel',
      if (inherited != null)
        widget.unit == FieldUnit.bytes ||
                unitLabel == null ||
                (widget.unit == FieldUnit.plain && widget.countUnit != null)
            ? context.l10n.engineFieldDefaultValue(
                formatFieldNumber(
                  inherited,
                  widget.unit,
                  FieldCopy(suffix: widget.suffix, countUnit: widget.countUnit),
                ),
              )
            : context.l10n.engineFieldDefaultValueUnit(_typedText(inherited, widget.unit), unitLabel),
      if (_stored case final stored? when widget.unit == FieldUnit.bytes && stored >= 1024)
        context.l10n.engineFieldCurrentValue(formatBytes(stored)),
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final unitLabel = _unitLabel;
    final stored = _stored;
    final valueStyle = AppType.tabular(theme.textTheme.headlineMedium!.copyWith(fontWeight: FontWeight.w600));
    return FieldSheetFrame(
      title: widget.title,
      actions: EditorSheetActions(
        busy: _busy,
        onDone: _submit,
        onRestore: widget.modified ? () => unawaited(_save(widget.onReset)) : null,
      ),
      children: [
        SheetCard(
          child: Row(
            children: [
              StepKey(
                key: const ValueKey('step-down'),
                icon: AppIcons.decrement,
                tooltip: l10n.engineFieldDecrease,
                onPressed: !_busy && _canDown ? () => _step(-1) : null,
              ),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: IntrinsicWidth(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 32),
                          child: TextField(
                            key: const ValueKey('number-input'),
                            enabled: !_busy,
                            controller: _controller,
                            textAlign: TextAlign.center,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[-+0-9.eE]'))],
                            style: valueStyle,
                            onChanged: (_) => setState(() => _error = null),
                            onSubmitted: (_) => _submit(),
                            decoration: const InputDecoration(
                              isCollapsed: true,
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(vertical: 8),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (unitLabel != null) ...[
                      const SizedBox(width: 6),
                      Text(unitLabel, style: theme.textTheme.bodyLarge?.copyWith(color: colors.textTertiary)),
                    ],
                  ],
                ),
              ),
              StepKey(
                key: const ValueKey('step-up'),
                icon: AppIcons.increment,
                tooltip: l10n.engineFieldIncrease,
                onPressed: !_busy && _canUp ? () => _step(1) : null,
              ),
            ],
          ),
        ),
        if (_sliderDivisions case final divisions?)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Slider(
              value: (stored ?? widget.inherited ?? _min!).clamp(_min!, _max!).toDouble(),
              min: _min!.toDouble(),
              max: _max!.toDouble(),
              divisions: divisions,
              activeColor: scheme.onSurfaceVariant,
              inactiveColor: scheme.onSurface.withValues(alpha: 0.1),
              onChanged: _busy
                  ? null
                  : (v) {
                      final index = ((v - _min!) / _sliderStep).round();
                      final snapped = decimalStepValue(_min!, _sliderStep, index) ?? v;
                      if (snapped != stored) HapticFeedback.selectionClick();
                      _setStored(snapped);
                    },
            ),
          ),
        SheetHelper(helper: _helper, error: _error),
      ],
    );
  }
}

/// A 44 round key with a 22 glyph: the stepper's − and +.
class StepKey extends StatelessWidget {
  const StepKey({super.key, required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: tooltip,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: scheme.onSurface.withValues(alpha: dark ? 0.1 : 0.06),
              shape: const CircleBorder(),
            ),
            child: SizedBox.square(
              dimension: NumberFieldSheet.keySize,
              child: Icon(icon, size: 22, color: enabled ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.3)),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Text ─────────────────────────────────────────────────────────────────────

/// Edits a line (or a block, for `role('textarea')`) of text. Empty restores
/// the default.
Future<void> showTextSheet(
  BuildContext context, {
  required String title,
  required SchemaMeta meta,
  required String? current,
  required String? inherited,
  required bool modified,
  required Future<bool> Function(String) onSubmit,
  required Future<bool> Function() onReset,
  String? hint,
  String? placeholder,
  String? patternMessage,
  TextInputType? keyboardType,
}) => showFieldSheet<void>(
  context,
  (_) => TextFieldSheet(
    title: title,
    meta: meta,
    current: current,
    inherited: inherited,
    modified: modified,
    onSubmit: onSubmit,
    onReset: onReset,
    hint: hint,
    placeholder: placeholder,
    patternMessage: patternMessage,
    keyboardType: keyboardType,
  ),
);

class TextFieldSheet extends StatefulWidget {
  const TextFieldSheet({
    super.key,
    required this.title,
    required this.meta,
    required this.current,
    required this.inherited,
    required this.modified,
    required this.onSubmit,
    required this.onReset,
    this.hint,
    this.placeholder,
    this.patternMessage,
    this.keyboardType,
  });

  final String title;
  final SchemaMeta meta;
  final String? current;
  final String? inherited;
  final bool modified;
  final Future<bool> Function(String) onSubmit;
  final Future<bool> Function() onReset;
  final String? hint;
  final String? placeholder;
  final String? patternMessage;
  final TextInputType? keyboardType;

  @override
  State<TextFieldSheet> createState() => _TextFieldSheetState();
}

/// A preview only: the schema/engine still decides which color strings it
/// accepts, so valid CSS names and plugin-specific syntax remain editable.
Color? schemaHexColor(String text) {
  final value = text.trim();
  if (RegExp(r'^#[0-9a-fA-F]{3}$').hasMatch(value)) {
    final hex = value.substring(1).split('').map((c) => '$c$c').join();
    return Color(0xff000000 | int.parse(hex, radix: 16));
  }
  if (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
    return Color(0xff000000 | int.parse(value.substring(1), radix: 16));
  }
  return null;
}

/// A color preview dot. The hairline keeps white on light and black on dark
/// visible; a value with no preview shows the empty ring.
class SchemaColorDot extends StatelessWidget {
  const SchemaColorDot(this.color, {super.key, this.size = previewSize});

  final Color? color;
  final double size;

  /// The preview in the field.
  static const previewSize = 20.0;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
  );
}

/// The preset colours under a color field: two rows of four. Each column is
/// an equal share of the field's width with its dot centred in it, so the
/// grid spans the field with equal outer insets; a whole cell is the target.
class SchemaColorSwatches extends StatelessWidget {
  const SchemaColorSwatches({super.key, required this.onPick});

  /// Null while a save is in flight.
  final ValueChanged<String>? onPick;

  static const presets = ['#000000', '#ffffff', '#ef4444', '#f59e0b', '#22c55e', '#06b6d4', '#3b82f6', '#a855f7'];
  static const columns = 4;
  static const dot = 28.0;
  static const cellHeight = 48.0;

  @override
  Widget build(BuildContext context) {
    final pick = onPick;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var start = 0; start < presets.length; start += columns)
          Row(
            children: [
              for (final hex in presets.skip(start).take(columns))
                Expanded(
                  child: Tooltip(
                    message: hex,
                    child: Semantics(
                      button: true,
                      enabled: pick != null,
                      child: InkResponse(
                        key: ValueKey('schema-color-swatch-$hex'),
                        onTap: pick == null ? null : () => pick(hex),
                        radius: cellHeight / 2,
                        child: SizedBox(
                          height: cellHeight,
                          child: Center(child: SchemaColorDot(schemaHexColor(hex), size: dot)),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _TextFieldSheetState extends State<TextFieldSheet> with _AcknowledgedSheet<TextFieldSheet> {
  late final _controller = TextEditingController(text: widget.modified ? widget.current ?? '' : '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_busy) return;
    final text = widget.meta.role == 'textarea' || widget.meta.role == 'regexp'
        ? _controller.text
        : _controller.text.trim();
    if (text.isEmpty) {
      if (widget.modified) {
        unawaited(_save(widget.onReset));
      } else {
        Navigator.of(context).pop();
      }
      return;
    }
    final error = validateText(text, widget.meta, patternMessage: widget.patternMessage);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    if (text == (widget.current ?? widget.inherited)) {
      Navigator.of(context).pop();
    } else {
      unawaited(_save(() => widget.onSubmit(text)));
    }
  }

  Future<void> _pickDate() async {
    final initial = (DateTime.tryParse(_controller.text) ?? DateTime.tryParse(widget.inherited ?? '') ?? DateTime.now())
        .toLocal();
    final selected = await showDatePicker(
      context: context,
      initialDate: initial.year >= 1 && initial.year <= 9999 ? initial : DateTime.now(),
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
    );
    if (selected == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
    if (time == null || !mounted) return;
    final next = DateTime(selected.year, selected.month, selected.day, time.hour, time.minute);
    setState(() {
      _controller.text = next.toUtc().toIso8601String();
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final multiline = widget.meta.role == 'textarea';
    final colorRole = widget.meta.role == 'color';
    final dateRole = widget.meta.role == 'datetime';
    // The page's own choice (a URL setting) first, then the schema role.
    final keyboard = multiline
        ? TextInputType.multiline
        : widget.keyboardType ??
              (widget.meta.role == 'link'
                  ? TextInputType.url
                  : dateRole
                  ? TextInputType.datetime
                  : TextInputType.text);
    final inherited = widget.inherited;
    return FieldSheetFrame(
      title: widget.title,
      actions: EditorSheetActions(
        busy: _busy,
        onDone: _submit,
        onRestore: widget.modified ? () => unawaited(_save(widget.onReset)) : null,
      ),
      children: [
        TextField(
          key: const ValueKey('text-input'),
          enabled: !_busy,
          controller: _controller,
          autofocus: true,
          autocorrect: false,
          // A single-line URL needs suggestions enabled to retain Android's
          // URI variation; disabling them selects a password variation.
          enableSuggestions: keyboard == TextInputType.url,
          minLines: multiline ? 4 : 1,
          maxLines: multiline ? 8 : 1,
          keyboardType: keyboard,
          textInputAction: multiline ? TextInputAction.newline : TextInputAction.done,
          onChanged: (_) {
            if (_error != null || colorRole) setState(() => _error = null);
          },
          onSubmitted: multiline ? null : (_) => _submit(),
          decoration: InputDecoration(
            hintText: widget.placeholder ?? (inherited == null || inherited.isEmpty ? null : inherited),
            suffixIcon: dateRole
                ? IconButton(
                    onPressed: _busy ? null : () => unawaited(_pickDate()),
                    tooltip: widget.title,
                    icon: const Icon(AppIcons.calendar),
                  )
                : colorRole
                ? Center(
                    widthFactor: 1,
                    child: SchemaColorDot(
                      schemaHexColor(_controller.text.isEmpty ? inherited ?? '' : _controller.text),
                      key: const ValueKey('schema-color-preview'),
                    ),
                  )
                : null,
          ),
        ),
        if (colorRole) ...[
          const SizedBox(height: 4),
          SchemaColorSwatches(
            onPick: _busy
                ? null
                : (hex) => setState(() {
                    _controller.text = hex;
                    _error = null;
                  }),
          ),
        ],
        SheetHelper(error: _error),
      ],
    );
  }
}

// ── Choice ───────────────────────────────────────────────────────────────────

/// Picks one of [options]; selecting closes the sheet.
Future<void> showChoiceSheet(
  BuildContext context, {
  required String title,
  required List<(Object?, String)> options,
  required Object? selected,
  required ValueChanged<Object?> onSelect,
}) => showFieldSheet<void>(
  context,
  (sheet) => FieldSheetFrame(
    title: title,
    children: [
      SheetCard(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            children: [
              for (final (value, label) in options)
                ChoiceOptionRow(
                  label: label,
                  selected: jsonEquals(value, selected),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    if (!jsonEquals(value, selected)) onSelect(value);
                  },
                ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
    ],
  ),
  dismissal: SheetDismissal.drag,
);

class ChoiceOptionRow extends StatelessWidget {
  const ChoiceOptionRow({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: EngineFieldRow(
        title: label,
        onTap: onTap,
        chevron: false,
        trailing: selected
            ? Icon(AppIcons.selected, size: 22, color: scheme.primary)
            : const SizedBox.square(dimension: 22),
      ),
    );
  }
}

// ── Secret ───────────────────────────────────────────────────────────────────

/// Writes a secret (never shown again). [onSave] / [onClear] throw a
/// worded failure; the sheet stays open to show it.
Future<void> showSecretSheet(
  BuildContext context, {
  required String title,
  required bool configured,
  required bool writable,
  required Future<void> Function(String value) onSave,
  required Future<void> Function() onClear,
}) => showFieldSheet<void>(
  context,
  (_) => SecretFieldSheet(title: title, configured: configured, writable: writable, onSave: onSave, onClear: onClear),
);

class SecretFieldSheet extends StatefulWidget {
  const SecretFieldSheet({
    super.key,
    required this.title,
    required this.configured,
    required this.writable,
    required this.onSave,
    required this.onClear,
  });

  final String title;
  final bool configured;
  final bool writable;
  final Future<void> Function(String value) onSave;
  final Future<void> Function() onClear;

  @override
  State<SecretFieldSheet> createState() => _SecretFieldSheetState();
}

class _SecretFieldSheetState extends State<SecretFieldSheet> {
  final _controller = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _value => _controller.text.replaceAll(RegExp(r'\s'), '');

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = (data?.text ?? '').replaceAll(RegExp(r'\s'), '');
    if (text.isEmpty || !mounted) return;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() => _error = null);
  }

  Future<void> _run(Future<void> Function() action) async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = describeSettingsError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final scheme = theme.colorScheme;
    final canSave = widget.writable && !_busy && _value.isNotEmpty;
    final save = FilledButton(
      style: _fill(context),
      onPressed: canSave ? () => unawaited(_run(() => widget.onSave(_value))) : null,
      child: _busy
          ? SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onPrimary))
          : Text(l10n.commonDone),
    );
    return FieldSheetFrame(
      title: widget.title,
      actions: SheetActions(
        secondary: widget.configured && widget.writable
            ? OutlinedButton(
                style: _outline(context, color: colors.danger),
                onPressed: _busy ? null : () => unawaited(_run(widget.onClear)),
                child: Text(l10n.engineFieldRemove),
              )
            : null,
        primary: save,
      ),
      children: [
        TextField(
          key: const ValueKey('secret-input'),
          controller: _controller,
          autofocus: widget.writable,
          enabled: widget.writable && !_busy,
          obscureText: _obscure,
          obscuringCharacter: '•',
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          keyboardType: TextInputType.visiblePassword,
          onChanged: (_) => setState(() => _error = null),
          decoration: InputDecoration(
            hintText: widget.configured ? '••••••••' : 'sk-…',
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: l10n.commonPaste,
                  icon: const Icon(AppIcons.paste, size: 20),
                  onPressed: widget.writable && !_busy ? () => unawaited(_paste()) : null,
                ),
                IconButton(
                  tooltip: _obscure ? l10n.engineFieldShow : l10n.commonHide,
                  icon: Icon(_obscure ? AppIcons.showSecret : AppIcons.hideSecret, size: 20),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ],
            ),
          ),
        ),
        SheetHelper(helper: widget.writable ? null : l10n.engineFieldFromEnvironment, error: _error),
      ],
    );
  }
}

// ── Lists ────────────────────────────────────────────────────────────────────

/// Edits a list of strings / numbers / constants in place: every add and
/// remove is written at once. [read] gives the current items.
Future<void> showListSheet(
  BuildContext context, {
  required String title,
  required SchemaNode item,
  required List<Object?> Function(WidgetRef ref) read,
  required Future<bool> Function(List<Object?> items) onChange,
  String? itemLabel,
  String? patternMessage,
  String? placeholder,
  Map<Object?, String> choices = const {},
}) => showFieldSheet<void>(
  context,
  (_) => ListFieldSheet(
    title: title,
    item: item,
    read: read,
    onChange: onChange,
    itemLabel: itemLabel,
    patternMessage: patternMessage,
    placeholder: placeholder,
    choices: choices,
  ),
);

class ListFieldSheet extends ConsumerStatefulWidget {
  const ListFieldSheet({
    super.key,
    required this.title,
    required this.item,
    required this.read,
    required this.onChange,
    this.itemLabel,
    this.patternMessage,
    this.placeholder,
    this.choices = const {},
  });

  final String title;
  final SchemaNode item;
  final List<Object?> Function(WidgetRef ref) read;
  final Future<bool> Function(List<Object?> items) onChange;
  final String? itemLabel;
  final String? patternMessage;
  final String? placeholder;
  final Map<Object?, String> choices;

  @override
  ConsumerState<ListFieldSheet> createState() => _ListFieldSheetState();
}

class _ListFieldSheetState extends ConsumerState<ListFieldSheet> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  SchemaNode get _item => widget.item.effective;

  String _label(Object? value) => valueLabel(value, FieldCopy(choices: widget.choices), node: _item);

  Future<void> _add(List<Object?> items) async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Object? value = text;
    if (_item.type == 'number') {
      final error = validateNumber(text, _item.meta, FieldUnit.plain);
      if (error != null) return setState(() => _error = error);
      value = num.parse(text);
    } else {
      final error = validateText(text, _item.meta, patternMessage: widget.patternMessage);
      if (error != null) return setState(() => _error = error);
    }
    if (items.any((e) => jsonEquals(e, value))) return setState(() => _error = context.l10n.engineFieldAlreadyAdded);
    _controller.clear();
    setState(() => _error = null);
    await widget.onChange([...items, value]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final items = widget.read(ref);
    final enumValues = _item.enumValues;
    final missing = [
      for (final v in enumValues ?? const <Object?>[])
        if (!items.any((e) => jsonEquals(e, v))) v,
    ];
    return FieldSheetFrame(
      title: widget.title,
      children: [
        if (items.isNotEmpty)
          SheetCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                children: [
                  for (final (i, item) in items.indexed)
                    EngineFieldRow(
                      key: ValueKey('item-$i'),
                      title: _label(item),
                      chevron: false,
                      trailing: RemoveKey(
                        tooltip: l10n.engineFieldRemoveItem(_label(item)),
                        onPressed: () => unawaited(widget.onChange([...items]..removeAt(i))),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (enumValues != null) ...[
          if (missing.isNotEmpty) ...[
            const SizedBox(height: 12),
            SheetCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  children: [
                    for (final v in missing)
                      EngineFieldRow(
                        icon: AppIcons.add,
                        title: _label(v),
                        chevron: false,
                        onTap: () => unawaited(widget.onChange([...items, v])),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ] else ...[
          SizedBox(height: items.isEmpty ? 0 : 12),
          TextField(
            key: const ValueKey('list-input'),
            controller: _controller,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: _item.type == 'number' ? TextInputType.number : TextInputType.url,
            textInputAction: TextInputAction.done,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => unawaited(_add(items)),
            decoration: InputDecoration(
              hintText: widget.placeholder ?? l10n.engineFieldAddItem(widget.itemLabel ?? l10n.engineFieldItem),
              suffixIcon: IconButton(
                tooltip: l10n.commonAdd,
                icon: Icon(AppIcons.addEntry, color: colors.textTertiary),
                onPressed: () => unawaited(_add(items)),
              ),
            ),
          ),
          SheetHelper(error: _error),
        ],
        const SizedBox(height: 16),
      ],
    );
  }
}

/// The × at the end of an item row; its glyph ends where a chevron would.
class RemoveKey extends StatelessWidget {
  const RemoveKey({super.key, required this.tooltip, required this.onPressed});

  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 32,
    child: IconButton(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      color: DshColors.of(context).textTertiary,
      icon: const Icon(AppIcons.close, size: 20),
      onPressed: onPressed,
    ),
  );
}

/// Edits a key → value map in place (strings, numbers or booleans).
Future<void> showDictSheet(
  BuildContext context, {
  required String title,
  required SchemaNode value,
  required Map<String, Object?> Function(WidgetRef ref) read,
  required Future<bool> Function(Map<String, Object?> entries) onChange,
}) => showFieldSheet<void>(context, (_) => DictFieldSheet(title: title, value: value, read: read, onChange: onChange));

class DictFieldSheet extends ConsumerStatefulWidget {
  const DictFieldSheet({
    super.key,
    required this.title,
    required this.value,
    required this.read,
    required this.onChange,
  });

  final String title;
  final SchemaNode value;
  final Map<String, Object?> Function(WidgetRef ref) read;
  final Future<bool> Function(Map<String, Object?> entries) onChange;

  @override
  ConsumerState<DictFieldSheet> createState() => _DictFieldSheetState();
}

class _DictFieldSheetState extends ConsumerState<DictFieldSheet> {
  final _key = TextEditingController();
  final _value = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    _value.dispose();
    super.dispose();
  }

  SchemaNode get _node => widget.value.effective;

  Future<void> _add(Map<String, Object?> entries) async {
    final key = _key.text.trim();
    final raw = _value.text.trim();
    if (key.isEmpty) return setState(() => _error = context.l10n.engineFieldEnterName);
    Object? value = raw;
    switch (_node.type) {
      case 'number':
        final error =
            validateNumber(raw, _node.meta, FieldUnit.plain) ??
            (raw.isEmpty ? context.l10n.engineFieldEnterNumber : null);
        if (error != null) return setState(() => _error = error);
        value = num.parse(raw);
      case 'boolean':
        // l10n:keep accepted boolean input aliases
        value = raw == 'true' || raw == '1' || raw == '是' || raw == '开';
      default:
        final error = validateText(raw, _node.meta);
        if (error != null) return setState(() => _error = error);
    }
    _key.clear();
    _value.clear();
    setState(() => _error = null);
    await widget.onChange({...entries, key: value});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final entries = widget.read(ref);
    return FieldSheetFrame(
      title: widget.title,
      children: [
        if (entries.isNotEmpty)
          SheetCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                children: [
                  for (final MapEntry(:key, :value) in entries.entries)
                    EngineFieldRow(
                      title: key,
                      value: '$value',
                      chevron: false,
                      trailing: RemoveKey(
                        tooltip: l10n.engineFieldRemoveItem(key),
                        onPressed: () => unawaited(widget.onChange({...entries}..remove(key))),
                      ),
                    ),
                ],
              ),
            ),
          ),
        SizedBox(height: entries.isEmpty ? 0 : 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('dict-key'),
                controller: _key,
                autocorrect: false,
                decoration: InputDecoration(hintText: l10n.commonName),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const ValueKey('dict-value'),
                controller: _value,
                autocorrect: false,
                onSubmitted: (_) => unawaited(_add(entries)),
                decoration: InputDecoration(hintText: l10n.engineFieldValue),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: l10n.commonAdd,
              icon: Icon(AppIcons.addEntry, color: DshColors.of(context).textTertiary),
              onPressed: () => unawaited(_add(entries)),
            ),
          ],
        ),
        SheetHelper(error: _error),
        const SizedBox(height: 16),
      ],
    );
  }
}

// ── Object lists ─────────────────────────────────────────────────────────────

String _itemTitle(Map<String, Object?> item, int index) {
  for (final key in const ['name', 'title', 'id', 'model', 'provider', 'url', 'path']) {
    if (item[key] case final String v when v.isNotEmpty) return v;
  }
  for (final v in item.values) {
    if (v is String && v.isNotEmpty) return v;
  }
  return appL10n.engineFieldItemIndex(index + 1);
}

/// The schema defaults of an object, for a new item.
Map<String, Object?> defaultsOf(SchemaNode node) => {
  for (final MapEntry(:key, :value) in (node.fields ?? const <String, SchemaNode>{}).entries)
    if (value.effective.meta.hasDefault && value.effective.meta.defaultValue != null)
      key: value.effective.meta.defaultValue,
};

/// Edits a list of objects: the items, each opening a small form.
Future<void> showObjectListSheet(
  BuildContext context, {
  required String title,
  required SchemaNode item,
  required List<Object?> Function(WidgetRef ref) read,
  required Future<bool> Function(List<Object?> items) onChange,
}) => showFieldSheet<void>(
  context,
  (_) => SheetNavigator(
    root: (_) => _ObjectListPage(title: title, item: item, read: read, onChange: onChange),
  ),
);

class _ObjectListPage extends ConsumerWidget {
  const _ObjectListPage({required this.title, required this.item, required this.read, required this.onChange});

  final String title;
  final SchemaNode item;
  final List<Object?> Function(WidgetRef ref) read;
  final Future<bool> Function(List<Object?> items) onChange;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final items = read(ref);
    void open(int? index) => SheetNavigator.of(context).push(
      (_) => _ObjectItemPage(
        title: index == null ? l10n.engineFieldNew : _itemTitle(asJsonMap(items[index]), index),
        item: item,
        initial: index == null ? defaultsOf(item.effective) : asJsonMap(items[index]),
        onSave: (value) async {
          final next = [...items];
          if (index == null) {
            next.add(value);
          } else {
            next[index] = value;
          }
          return onChange(next);
        },
        onDelete: index == null ? null : () => onChange([...items]..removeAt(index)),
      ),
    );
    return FieldSheetFrame(
      title: title,
      children: [
        SheetCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                for (final (i, raw) in items.indexed)
                  EngineFieldRow(title: _itemTitle(asJsonMap(raw), i), onTap: () => open(i)),
                EngineFieldRow(icon: AppIcons.add, title: l10n.commonAdd, chevron: false, onTap: () => open(null)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

Map<String, Object?> asJsonMap(Object? value) =>
    value is Map ? {for (final MapEntry(:key, :value) in value.entries) '$key': value} : <String, Object?>{};

class _ObjectItemPage extends StatefulWidget {
  const _ObjectItemPage({
    required this.title,
    required this.item,
    required this.initial,
    required this.onSave,
    this.onDelete,
  });

  final String title;
  final SchemaNode item;
  final Map<String, Object?> initial;
  final Future<bool> Function(Map<String, Object?> value) onSave;
  final Future<bool> Function()? onDelete;

  @override
  State<_ObjectItemPage> createState() => _ObjectItemPageState();
}

class _ObjectItemPageState extends State<_ObjectItemPage> {
  late Map<String, Object?> _draft = {...widget.initial};
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _errors = {};
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(String key) =>
      _controllers.putIfAbsent(key, () => TextEditingController(text: _draft[key] == null ? '' : '${_draft[key]}'));

  Future<void> _save() async {
    final errors = <String, String>{};
    final fields = widget.item.effective.fields ?? const {};
    for (final MapEntry(:key, :value) in fields.entries) {
      final node = value.effective;
      final kind = kindOf(value);
      if (kind == FieldKind.text || kind == FieldKind.number) {
        final text = _controllerFor(key).text.trim();
        if (text.isEmpty) {
          if (node.meta.required && !node.meta.hasDefault) errors[key] = context.l10n.engineFieldRequired;
          _draft = {..._draft}..remove(key);
          continue;
        }
        final error = kind == FieldKind.number
            ? validateNumber(text, node.meta, FieldUnit.plain)
            : validateText(text, node.meta);
        if (error != null) {
          errors[key] = error;
        } else {
          _draft = {..._draft, key: kind == FieldKind.number ? num.parse(text) : text};
        }
      }
    }
    setState(() {
      _errors
        ..clear()
        ..addAll(errors);
    });
    if (errors.isNotEmpty) return;
    setState(() => _busy = true);
    final ok = await widget.onSave(_draft);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) SheetNavigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final fields = widget.item.effective.fields ?? const {};
    final colors = DshColors.of(context);
    return FieldSheetFrame(
      title: widget.title,
      actions: SheetActions(
        secondary: widget.onDelete == null
            ? null
            : OutlinedButton(
                style: _outline(context, color: colors.danger),
                onPressed: _busy
                    ? null
                    : () async {
                        final navigator = SheetNavigator.of(context);
                        if (await widget.onDelete!()) navigator.pop();
                      },
                child: Text(l10n.commonDelete),
              ),
        primary: FilledButton(
          style: _fill(context),
          onPressed: _busy ? null : () => unawaited(_save()),
          child: Text(l10n.commonDone),
        ),
      ),
      children: [
        for (final MapEntry(:key, :value) in fields.entries)
          if (kindOf(value) case final kind when kind != FieldKind.hidden)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: _draftField(key, value, kind)),
      ],
    );
  }

  Widget _draftField(String key, SchemaNode node, FieldKind kind) {
    final theme = Theme.of(context);
    final label = labelFor(key, node, const FieldCopy());
    final labelText = Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
      child: Text(label, style: theme.textTheme.labelLarge),
    );
    switch (kind) {
      case FieldKind.toggle:
        return SheetCard(
          padding: EdgeInsets.zero,
          child: EngineFieldRow(
            title: label,
            trailing: Switch.adaptive(
              value: _draft[key] == true || (_draft[key] == null && node.effective.meta.defaultValue == true),
              onChanged: (v) => setState(() => _draft = {..._draft, key: v}),
            ),
          ),
        );
      case FieldKind.choice:
        final options = choicesFor(node, const FieldCopy());
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            labelText,
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (value, text) in options)
                  ChoiceChip(
                    label: Text(text),
                    selected: jsonEquals(_draft[key] ?? node.effective.meta.defaultValue, value),
                    showCheckmark: false,
                    shape: const StadiumBorder(),
                    onSelected: (_) => setState(() => _draft = {..._draft, key: value}),
                  ),
              ],
            ),
          ],
        );
      case FieldKind.text:
      case FieldKind.number:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            labelText,
            TextField(
              controller: _controllerFor(key),
              autocorrect: false,
              keyboardType: kind == FieldKind.number
                  ? const TextInputType.numberWithOptions(decimal: true)
                  : TextInputType.text,
              decoration: InputDecoration(
                hintText: node.effective.meta.defaultValue == null ? null : '${node.effective.meta.defaultValue}',
                errorText: _errors[key],
              ),
            ),
          ],
        );
      default:
        return SheetCard(
          padding: EdgeInsets.zero,
          child: EngineFieldRow(title: label, value: compactJson(_draft[key]), enabled: false),
        );
    }
  }
}

// ── Read-only ────────────────────────────────────────────────────────────────

/// `{"mode":"normal"}` in one short line.
String compactJson(Object? value) {
  if (value == null) return appL10n.commonNotSet;
  if (value is String) return value;
  if (value is List) return appL10n.commonItemCount(value.length);
  if (value is Map) return appL10n.commonItemCount(value.length);
  return jsonEncode(value);
}

/// Shows a value the form cannot edit, pretty-printed and selectable.
Future<void> showValueSheet(BuildContext context, {required String title, required Object? value}) =>
    showFieldSheet<void>(
      context,
      (sheet) => FieldSheetFrame(
        title: title,
        children: [
          SheetCard(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              const JsonEncoder.withIndent('  ').convert(value),
              style: AppType.monoLabel(color: Theme.of(sheet).colorScheme.onSurface).copyWith(height: 1.6),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
      dismissal: SheetDismissal.drag,
    );
