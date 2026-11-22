// Controls the Theme Studio's groups share: a group that folds its advanced half away, captioned chip choices,
// sliders that can fall back to a default, and text fields that stay in step with the draft.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/l10n.dart';
import '../../common/capsule_chip.dart';
import '../../common/expand_reveal.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

String studioText(String zh, String en) => AppLocale.isEnglish ? en : zh;

/// One titled group: [basics] always show, [more] sits behind a fold at the bottom.
class StudioGroup extends StatelessWidget {
  const StudioGroup({
    super.key,
    required this.id,
    required this.title,
    required this.basics,
    this.more = const [],
    this.open = false,
    this.onToggle,
  });

  final String id;
  final String title;
  final List<Widget> basics;
  final List<Widget> more;
  final bool open;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 22, bottom: 10),
          child: Semantics(
            header: true,
            child: Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: basics,
        ),
        if (more.isNotEmpty) ...[
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: ValueKey('theme-studio-more-$id'),
              onPressed: onToggle,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                foregroundColor: theme.colorScheme.onSurfaceVariant,
              ),
              icon: Icon(open ? AppIcons.collapse : AppIcons.expand, size: 14),
              label: Text(open ? studioText('收起', 'Show less') : studioText('更多选项', 'More options')),
            ),
          ),
          ExpandReveal(
            open: open,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 14,
                children: more,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The small label over a control.
class StudioCaption extends StatelessWidget {
  const StudioCaption(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant));
  }
}

/// A captioned row of capsules, one of which is picked.
class StudioChoice<T> extends StatelessWidget {
  const StudioChoice({super.key, this.label, required this.items, required this.value, required this.onChanged});

  final String? label;
  final List<(T, String)> items;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (label case final label?) ...[StudioCaption(label), const SizedBox(height: 6)],
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (item, name) in items)
            CapsuleChoiceChip(label: name, selected: item == value, onSelected: () => onChanged(item)),
        ],
      ),
    ],
  );
}

/// A slider over one number of the draft. A null [value] means the field follows something else ([follows] says
/// what): the slider is drawn faint with its thumb at [effective], the value in use now, and the first drag is
/// what writes a number into the draft.
class StudioSlider extends StatelessWidget {
  const StudioSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.fallback,
    this.effective,
    this.step = 0.05,
    this.format,
    this.follows,
  });

  final String label;
  final double? value;
  final double min;
  final double max;

  /// What the reset key writes; null clears a field that can follow its default.
  final double? fallback;

  /// What an unset field comes to in the theme as it is now; null when that cannot be told.
  final double? effective;
  final double step;
  final String Function(double value)? format;

  /// What an unset field follows (「跟随材质」), also the key that unsets it.
  final String? follows;
  final ValueChanged<double?> onChanged;

  static String percent(double v) => '${(v * 100).round()}%';

  static String times(double v) => '${v.toStringAsFixed(2)}×';

  int get _decimals => step >= 1 ? 0 : (step >= 0.1 ? 1 : 2);

  // Snapped through text so a step of 0.1 never lands on 0.30000000000000004 in theme.json.
  double _snap(double raw) => double.parse(((raw / step).round() * step).clamp(min, max).toStringAsFixed(_decimals));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final value = this.value;
    String number(double v) => format?.call(v) ?? v.toStringAsFixed(_decimals);
    final following = follows ?? studioText('默认', 'Default');
    final shown = value != null
        ? number(value)
        : (effective == null
              ? following
              : studioText('$following · 当前 ${number(effective!)}', '$following · now ${number(effective!)}'));
    // Faint but solid: a see-through thumb would show the track through it.
    final resting = Color.alphaBlend(scheme.onSurfaceVariant.withValues(alpha: 0.32), scheme.surface);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 30,
          child: Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
              Text(shown, style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: scheme.onSurfaceVariant))),
              if (value != fallback)
                TextButton(
                  onPressed: () => onChanged(fallback),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(fallback == null && follows != null ? follows! : studioText('恢复默认', 'Reset')),
                ),
            ],
          ),
        ),
        Semantics(
          label: label,
          child: Slider(
            value: (value ?? effective ?? fallback ?? min).clamp(min, max).toDouble(),
            min: min,
            max: max,
            // The thumb's half stays inside the row: a fold clips what leaves it.
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            // Neutral and without tick marks, like every slider in settings; steps come from [_snap].
            activeColor: value == null ? resting : scheme.onSurfaceVariant,
            inactiveColor: scheme.onSurface.withValues(alpha: 0.1),
            onChanged: (raw) {
              final next = _snap(raw);
              if (next != value) onChanged(next);
            },
          ),
        ),
      ],
    );
  }
}

/// A title with a switch at its end.
class StudioSwitch extends StatelessWidget {
  const StudioSwitch({super.key, required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: InkWell(
      onTap: () => onChanged(!value),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
          Switch.adaptive(value: value, onChanged: onChanged, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
        ],
      ),
    ),
  );
}

String _same(String text) => text;

/// Keeps a field within [max] code points, the unit the pack's own check counts in; whole characters only, so
/// an emoji made of several is never cut in half.
class StudioRuneLimit extends TextInputFormatter {
  const StudioRuneLimit(this.max);

  final int max;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.runes.length <= max) return newValue;
    final kept = StringBuffer();
    var runes = 0;
    for (final character in newValue.text.characters) {
      runes += character.runes.length;
      if (runes > max) break;
      kept.write(character);
    }
    final text = kept.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: math.max(0, math.min(newValue.selection.end, text.length))),
    );
  }
}

/// A text field over one value of the draft. Typing writes through [read]; the text is only rewritten when the
/// value changes from outside (a swatch, a reset, a pasted JSON), never while the user is mid-word.
class StudioField<T> extends StatefulWidget {
  const StudioField({
    super.key,
    required this.value,
    required this.read,
    required this.show,
    required this.onChanged,
    this.same,
    this.label,
    this.hint,
    this.maxLength,
    this.invalidText,
    this.errorText,
    this.prefix,
    this.mono = false,
    this.dense = false,
  });

  static StudioField<String> text({
    Key? key,
    required String value,
    required ValueChanged<String> onChanged,
    String? label,
    String? hint,
    int? maxLength,
    String? errorText,
  }) => StudioField<String>(
    key: key,
    value: value,
    read: _same,
    show: _same,
    onChanged: onChanged,
    label: label,
    hint: hint,
    maxLength: maxLength,
    errorText: errorText,
  );

  final T value;

  /// What a text stands for; throws [FormatException] while it is not a value yet.
  final T Function(String text) read;
  final String Function(T value) show;
  final ValueChanged<T> onChanged;
  final bool Function(T a, T b)? same;
  final String? label;
  final String? hint;

  /// The most code points the field takes.
  final int? maxLength;

  /// Shown while the text cannot be read.
  final String? invalidText;

  /// A problem with the value itself (a required field left empty).
  final String? errorText;
  final Widget? prefix;
  final bool mono;
  final bool dense;

  @override
  State<StudioField<T>> createState() => _StudioFieldState<T>();
}

class _StudioFieldState<T> extends State<StudioField<T>> {
  late final _controller = TextEditingController(text: widget.show(widget.value));
  bool _invalid = false;

  bool _equal(T a, T b) => widget.same?.call(a, b) ?? a == b;

  bool _textStandsFor(T value) {
    try {
      return _equal(widget.read(_controller.text), value);
    } on FormatException {
      return false;
    }
  }

  @override
  void didUpdateWidget(StudioField<T> old) {
    super.didUpdateWidget(old);
    if (!_equal(old.value, widget.value) && !_textStandsFor(widget.value)) {
      _controller.text = widget.show(widget.value);
      _invalid = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _typed(String text) {
    final T next;
    try {
      next = widget.read(text);
    } on FormatException {
      setState(() => _invalid = true);
      return;
    }
    // The counter follows the text even when the value it stands for is unchanged.
    if (_invalid || widget.maxLength != null) setState(() => _invalid = false);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    onChanged: _typed,
    inputFormatters: widget.maxLength == null ? null : [StudioRuneLimit(widget.maxLength!)],
    autocorrect: !widget.mono,
    enableSuggestions: !widget.mono,
    style: widget.mono ? AppType.mono(size: 13) : null,
    decoration: InputDecoration(
      labelText: widget.label,
      hintText: widget.hint,
      // Clearly fainter than a typed value: a hint may be the default colour's own code.
      hintStyle: (widget.mono ? AppType.mono(size: 13) : const TextStyle()).copyWith(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.32),
      ),
      isDense: widget.dense,
      prefixIcon: widget.prefix,
      counterText: widget.maxLength == null ? null : '${_controller.text.runes.length}/${widget.maxLength}',
      errorText: _invalid ? widget.invalidText : widget.errorText,
    ),
  );
}

/// A colour typed as #RRGGBB or #AARRGGBB; an empty field is "no colour".
class StudioHexField extends StatelessWidget {
  const StudioHexField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.hint,
    this.dense = false,
    this.onPick,
  });

  final int? value;
  final ValueChanged<int?> onChanged;
  final String? label;
  final String? hint;
  final bool dense;

  /// Puts a dot of the colour before the text, which opens a picker; an empty ring while there is no colour.
  final VoidCallback? onPick;

  static int? _read(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final parsed = parseThemeHexColor(trimmed.startsWith('#') ? trimmed : '#$trimmed');
    if (parsed == null) throw const FormatException('hex');
    return parsed;
  }

  static String _show(int? value) => value == null ? '' : formatThemeHexColor(value);

  @override
  Widget build(BuildContext context) => StudioField<int?>(
    value: value,
    read: _read,
    show: _show,
    onChanged: onChanged,
    label: label,
    hint: hint,
    dense: dense,
    mono: true,
    invalidText: studioText('写成 #RRGGBB', 'Use #RRGGBB'),
    prefix: onPick == null
        ? null
        : Semantics(
            button: true,
            label: studioText('选颜色', 'Pick a color'),
            child: InkResponse(
              radius: 20,
              onTap: onPick,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: value == null ? null : Color(value!),
                    shape: BoxShape.circle,
                    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  child: const SizedBox.square(dimension: 16),
                ),
              ),
            ),
          ),
  );
}

/// A short text the pack supplies itself, in Chinese and English side by side.
class StudioLocalizedText extends StatelessWidget {
  const StudioLocalizedText({
    super.key,
    required this.label,
    required this.value,
    required this.maxLength,
    required this.onChanged,
  });

  final String label;
  final ThemeLocalizedText? value;
  final int maxLength;
  final ValueChanged<ThemeLocalizedText?> onChanged;

  void _write({String? zh, String? en}) {
    String? kept(String? text) => text == null || text.trim().isEmpty ? null : text;
    final next = ThemeLocalizedText(zh: kept(zh), en: kept(en));
    onChanged(next.zh == null && next.en == null ? null : next);
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // The caption carries the name: half-width field labels have no room for it.
      StudioCaption(label),
      const SizedBox(height: 8),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: StudioField.text(
              value: value?.zh ?? '',
              onChanged: (text) => _write(zh: text, en: value?.en),
              label: studioText('中文', 'Chinese'),
              maxLength: maxLength,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: StudioField.text(
              value: value?.en ?? '',
              onChanged: (text) => _write(zh: value?.zh, en: text),
              label: studioText('英文', 'English'),
              maxLength: maxLength,
            ),
          ),
        ],
      ),
    ],
  );
}

/// The picker for one bundled file: pick, clear, and a note when the draft names a file that is not there.
class StudioAssetRow extends StatelessWidget {
  const StudioAssetRow({
    super.key,
    required this.title,
    required this.pickLabel,
    required this.fileName,
    required this.missing,
    required this.onPick,
    required this.onClear,
    this.icon = AppIcons.image,
  });

  /// What the file is, once picked (「背景图」).
  final String title;

  /// The button while nothing is picked (「选择背景图」).
  final String pickLabel;
  final String? fileName;
  final bool missing;
  final VoidCallback onPick;
  final VoidCallback onClear;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              icon: Icon(icon, size: 16),
              label: Text(fileName == null ? pickLabel : '$title · $fileName'),
              onPressed: onPick,
            ),
            if (fileName != null) TextButton(onPressed: onClear, child: Text(studioText('清除', 'Clear'))),
          ],
        ),
        if (missing) StudioMissingNote(fileName!),
      ],
    );
  }
}

class StudioMissingNote extends StatelessWidget {
  const StudioMissingNote(this.fileName, {super.key});

  final String fileName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        studioText('还缺文件 $fileName，重新选一个才能保存。', 'The file $fileName is missing. Pick one again before saving.'),
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
      ),
    );
  }
}
