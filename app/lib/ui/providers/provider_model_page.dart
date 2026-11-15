// 模型设置 (a form page): one model of a custom provider — its name, how much it
// holds (context length, max output), what it takes (text, or text and images)
// and whether it thinks, at which efforts. These are the `llm-pi-ai` model
// entry's own fields; an empty one falls back to the route's default. One
// pinned button: 「完成」 hands the model back to the edit form, 「保存」 (from the
// detail page) writes it.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/providers_state.dart';
import '../chat/model_sheet.dart' show effortLabel;
import '../common/discard_guard.dart';
import '../common/expand_reveal.dart';
import '../common/smooth_size.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/theme.dart';
import 'provider_widgets.dart';

/// Quick picks under 「上下文长度」: the sizes models are sold in.
const contextPresets = [32768, 65536, 131072, 200000, 262144, 1000000];

/// Quick picks under 「最大输出」.
const maxOutputPresets = [8192, 16384, 32768, 65536, 131072];

/// The levels a model offers when thinking is first switched on: the common
/// OpenAI-style trio (what the web Models page starts with too, beside off).
const initialThinkingLevels = {'low', 'medium', 'high'};

/// The levels this page lists, a multiple choice. `off` is not one of them:
/// a model that thinks here also offers 不思考 in the chat's picker (the
/// adapter lists only what the entry declares, so the page declares it).
/// `minimal` (one older OpenAI model's) is not listed; an entry that
/// declares it keeps it.
const offeredThinkingLevels = ['low', 'medium', 'high', 'xhigh', 'max'];

/// Pops with the edited [ProviderModelSpec]; null when left without saving.
class ProviderModelPage extends StatefulWidget {
  const ProviderModelPage({super.key, required this.model, this.defaults = const ModelDefaults(), this.onSave});

  final ProviderModelSpec model;

  /// What the route assumes for an empty field (the placeholders).
  final ModelDefaults defaults;

  /// Writes the result before the page closes (the detail page). Null: the
  /// caller (the edit form) takes it with the pop and saves it later.
  final Future<void> Function(ProviderModelSpec model)? onSave;

  @override
  State<ProviderModelPage> createState() => _ProviderModelPageState();
}

enum _F { context, maxOutput, effort }

class _ProviderModelPageState extends State<ProviderModelPage> {
  ProviderModelSpec get _model => widget.model;

  late final _name = TextEditingController(text: _model.name ?? '');

  /// The counts as they will be written: exact until the text is edited (the
  /// field shows 131072 as 「128K」), then whatever the text says.
  late int? _context = _model.contextWindow;
  late int? _maxOutput = _model.maxTokens;
  late final _contextText = TextEditingController(text: _format(_context));
  late final _maxOutputText = TextEditingController(text: _format(_maxOutput));

  late final bool _initialImages = _model.acceptsImages(routeDefault: widget.defaults.input);
  late bool _images = _initialImages;

  /// What the entry declared when the page opened, `off` included.
  late final Set<String> _initialLevels = _model.thinks ? _model.thinkingLevels.toSet() : const {};
  late bool _thinking = _model.thinks;

  /// The levels beyond `off` the model offers. Kept while thinking is off, so
  /// switching it back on restores them.
  late Set<String> _levels = {..._initialLevels}..remove('off');

  /// Whether the picker also offers 不思考: yes for a model set up here; one
  /// declared elsewhere without `off` (a model that always thinks) keeps that.
  late final bool _offersOff = !_model.thinks || _initialLevels.contains('off');

  /// The `reasoningEfforts` keys to write; empty while thinking is off.
  Set<String> get _declared => _thinking ? {if (_offersOff) 'off', ..._levels} : const {};

  Map<_F, String> _errors = const {};
  String? _formError;
  bool _saving = false;

  late final Listenable _edits = Listenable.merge([_name, _contextText, _maxOutputText]);

  static String _format(int? value) => value == null ? '' : formatTokens(value);

  @override
  void dispose() {
    _name.dispose();
    _contextText.dispose();
    _maxOutputText.dispose();
    super.dispose();
  }

  /// The entry as it will be written. Fields left as they were keep their
  /// stored spelling (an input list the route defaults, effort values other
  /// than the level names).
  ProviderModelSpec _result() {
    final name = _name.text.trim();
    var spec = ProviderModelSpec(
      id: _model.id,
      name: name.isEmpty ? null : name,
      contextWindow: _context,
      maxTokens: _maxOutput,
      input: _images == _initialImages ? _model.input : (_images ? const ['text', 'image'] : const ['text']),
      extra: _model.extra,
    );
    if (!setEquals(_declared, _initialLevels)) spec = spec.withReasoningEfforts(_declared);
    return spec;
  }

  bool get _dirty => jsonEncode(_result().toJson()) != jsonEncode(_model.toJson());

  void _clear(_F field) {
    if (_errors.containsKey(field) || _formError != null) {
      setState(() {
        _errors = {..._errors}..remove(field);
        _formError = null;
      });
    }
  }

  void _typedContext(String text) {
    setState(() => _context = parseTokenCount(text));
    _clear(_F.context);
  }

  void _typedMaxOutput(String text) {
    setState(() => _maxOutput = parseTokenCount(text));
    _clear(_F.maxOutput);
  }

  /// A quick pick fills the field; picking the one already chosen empties it
  /// (back to the default).
  void _pickContext(int value) {
    final again = _context != null && formatTokens(_context!) == formatTokens(value);
    setState(() => _context = again ? null : value);
    _contextText.text = _format(_context);
    _clear(_F.context);
  }

  void _pickMaxOutput(int value) {
    final again = _maxOutput != null && formatTokens(_maxOutput!) == formatTokens(value);
    setState(() => _maxOutput = again ? null : value);
    _maxOutputText.text = _format(_maxOutput);
    _clear(_F.maxOutput);
  }

  void _setThinking(bool on) {
    setState(() {
      _thinking = on;
      if (on && _levels.isEmpty) _levels = {...initialThinkingLevels};
    });
    _clear(_F.effort);
  }

  void _toggleLevel(String level) {
    setState(() => _levels = _levels.contains(level) ? ({..._levels}..remove(level)) : {..._levels, level});
    _clear(_F.effort);
  }

  Future<void> _submit() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final l10n = context.l10n;
    final errors = <_F, String>{
      _F.context: ?tokenCountError(_contextText.text),
      _F.maxOutput: ?tokenCountError(_maxOutputText.text),
      if (_thinking && _levels.isEmpty) _F.effort: l10n.engineModelNeedLevel,
    };
    setState(() {
      _errors = errors;
      _formError = null;
    });
    if (errors.isNotEmpty) return;
    final result = _result();
    final save = widget.onSave;
    if (save == null || !_dirty) {
      Navigator.of(context).pop(result);
      return;
    }
    setState(() => _saving = true);
    try {
      await save(result);
      if (mounted) Navigator.of(context).pop(result);
    } catch (error) {
      if (mounted) setState(() => _formError = context.l10n.engineProviderSaveFailed(describeProviderError(error)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final scheme = theme.colorScheme;
    final defaults = widget.defaults;

    final page = AppPage.list(
      title: _model.label,
      subtitle: _model.label == _model.id ? null : Text(_model.id),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSection(
              title: l10n.engineProviderBasicInfo,
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      label: l10n.commonName,
                      child: TextField(
                        controller: _name,
                        autocorrect: false,
                        textInputAction: TextInputAction.done,
                        inputFormatters: [LengthLimitingTextInputFormatter(64)],
                        decoration: InputDecoration(hintText: _model.id),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: l10n.engineModelTokenLimits,
              children: [
                FormFieldGroup(
                  children: [
                    _CapacityField(
                      label: l10n.engineModelContextLength,
                      controller: _contextText,
                      fallback: defaults.contextWindow,
                      presets: contextPresets,
                      value: _context,
                      error: _errors[_F.context],
                      onChanged: _typedContext,
                      onPick: _pickContext,
                    ),
                    _CapacityField(
                      label: l10n.engineModelMaxOutput,
                      controller: _maxOutputText,
                      fallback: defaults.maxTokens,
                      presets: maxOutputPresets,
                      value: _maxOutput,
                      error: _errors[_F.maxOutput],
                      onChanged: _typedMaxOutput,
                      onPick: _pickMaxOutput,
                    ),
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: l10n.engineModelCapabilities,
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      label: l10n.engineModelInputType,
                      child: SegmentedPill<bool>(
                        segments: [
                          PillSegment(false, l10n.engineModelInputText),
                          PillSegment(true, l10n.engineModelInputTextImage),
                        ],
                        selected: _images,
                        onChanged: _saving ? null : (v) => setState(() => _images = v),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          MergeSemantics(
                            child: FormFieldLabel(
                              l10n.engineModelThinking,
                              trailing: FieldSwitch(value: _thinking, onChanged: _saving ? null : _setThinking),
                            ),
                          ),
                          ExpandReveal(
                            open: _thinking,
                            child: _LevelList(
                              selected: _levels,
                              error: _errors[_F.effort],
                              onToggle: _saving ? null : _toggleLevel,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            SmoothSize(
              duration: AppMotion.of(context, AppMotion.standard),
              curve: AppMotion.std,
              alignment: Alignment.topCenter,
              child: _formError == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                      child: Text(_formError!, style: theme.textTheme.bodySmall?.copyWith(color: colors.danger)),
                    ),
            ),
            const SizedBox(height: FormBottomBar.height),
          ],
        ),
      ],
    );

    return DiscardGuard(
      listenable: _edits,
      isDirty: () => !_saving && _dirty,
      child: Stack(
        children: [
          page,
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: FormBottomBar(
              child: FilledButton(
                onPressed: _saving ? null : _submit,
                child: _saving
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onPrimary),
                          ),
                          const SizedBox(width: 10),
                          Text(l10n.engineProviderSaving),
                        ],
                      )
                    : Text(widget.onSave == null ? l10n.commonDone : l10n.commonSave),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A token count: the field (empty shows the route's default), its error, and
/// a row of quick picks; the pick matching the value reads as chosen.
class _CapacityField extends StatelessWidget {
  const _CapacityField({
    required this.label,
    required this.controller,
    required this.fallback,
    required this.presets,
    required this.value,
    required this.error,
    required this.onChanged,
    required this.onPick,
  });

  final String label;
  final TextEditingController controller;
  final int fallback;
  final List<int> presets;
  final int? value;
  final String? error;
  final ValueChanged<String> onChanged;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final shown = value == null ? null : formatTokens(value!);
    return FormFieldBlock(
      label: label,
      error: error,
      below: CapsuleGrid(
        columns: presets.length,
        children: [
          for (final preset in presets)
            ChoiceCapsule(
              label: formatTokens(preset),
              selected: shown == formatTokens(preset),
              onTap: () => onPick(preset),
            ),
        ],
      ),
      child: TextField(
        controller: controller,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.done,
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9kKmM., _]')),
          LengthLimitingTextInputFormatter(12),
        ],
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: context.l10n.engineModelDefaultSize(formatTokens(fallback)),
          error: error == null ? null : const SizedBox.shrink(),
        ),
      ),
    );
  }
}

/// 「可选档位」 under the thinking switch: the levels the chat's picker will
/// offer for this model, ticked (a multiple choice, unlike the quick picks
/// above it). Names as in the picker.
class _LevelList extends StatelessWidget {
  const _LevelList({required this.selected, required this.error, required this.onToggle});

  final Set<String> selected;
  final String? error;
  final ValueChanged<String>? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        FormFieldLabel(context.l10n.engineModelLevels),
        const SizedBox(height: FormFieldLabel.gap),
        for (final level in offeredThinkingLevels)
          LevelRow(
            label: effortLabel(level),
            checked: selected.contains(level),
            onTap: onToggle == null ? null : () => onToggle!(level),
          ),
        SmoothSize(
          duration: AppMotion.of(context, AppMotion.standard),
          alignment: Alignment.topLeft,
          child: error == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(FormFieldLabel.indent, 6, FormFieldLabel.indent, 0),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      error!,
                      style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).danger),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// One level of [_LevelList]: a tick on the labels' edge, then the name; the
/// whole row toggles it.
class LevelRow extends StatelessWidget {
  const LevelRow({super.key, required this.label, required this.checked, required this.onTap});

  final String label;
  final bool checked;
  final VoidCallback? onTap;

  static const height = 44.0;

  @override
  Widget build(BuildContext context) => Semantics(
    checked: checked,
    enabled: onTap != null,
    label: label,
    excludeSemantics: true,
    onTap: onTap,
    child: InkWell(
      onTap: onTap,
      borderRadius: AppShape.radiusMd,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: height),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: FormFieldLabel.indent, vertical: 8),
          child: Row(
            children: [
              SelectionTick(checked: checked),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: settingsTitleStyle(context)?.copyWith(color: Theme.of(context).colorScheme.onSurface),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A switch in a label row: its track (4 inside the switch's box) ends flush
/// with the field's edge, like a settings row's.
class FieldSwitch extends StatelessWidget {
  const FieldSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  /// Space between the switch's box and its track, on each side.
  static const trackInset = SettingsMetrics.inset - SettingsMetrics.trailingPad;

  @override
  Widget build(BuildContext context) => Transform.translate(
    offset: const Offset(trackInset, 0),
    child: SwitchTheme(
      data: SwitchTheme.of(context).copyWith(materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
      child: Switch.adaptive(value: value, onChanged: onChanged),
    ),
  );
}

/// Equal-width [ChoiceCapsule]s, [columns] to a row, 8 apart both ways. The
/// grid spans its parent, so its edges line up with the field above it; a
/// short last row keeps the columns.
class CapsuleGrid extends StatelessWidget {
  const CapsuleGrid({super.key, required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  static const gap = 8.0;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var start = 0; start < children.length; start += columns) ...[
        if (start > 0) const SizedBox(height: gap),
        Row(
          children: [
            for (var i = start; i < start + columns; i++) ...[
              if (i > start) const SizedBox(width: gap),
              Expanded(child: i < children.length ? children[i] : const SizedBox.shrink()),
            ],
          ],
        ),
      ],
    ],
  );
}

/// One choice of a [CapsuleGrid]: the quiet filter capsule
/// (the colours of `CapsuleChoiceChip`: a faint fill, ink when chosen), filling
/// its cell, the label centred and never wrapped.
class ChoiceCapsule extends StatelessWidget {
  const ChoiceCapsule({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final style = theme.textTheme.labelLarge!.copyWith(
      fontSize: 13,
      height: 1.2,
      color: selected ? scheme.surface : scheme.onSurfaceVariant,
    );
    final height = math.max(32.0, MediaQuery.textScalerOf(context).scale(style.fontSize!) * style.height! + 14);
    const shape = StadiumBorder();
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: AnimatedContainer(
        duration: AppMotion.of(context, AppMotion.quick),
        curve: AppMotion.std,
        height: height,
        decoration: ShapeDecoration(
          shape: shape,
          color: selected
              ? scheme.onSurface
              : (dark ? Colors.white.withValues(alpha: 0.07) : scheme.onSurface.withValues(alpha: 0.05)),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: shape,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: AnimatedDefaultTextStyle(
                    duration: AppMotion.of(context, AppMotion.quick),
                    style: style,
                    child: Text(label, maxLines: 1),
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
