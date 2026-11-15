import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/engine_settings_state.dart';
import '../theme/app_icons.dart';
import '../web/dsh_web_launcher.dart';
import '../web/web_target.dart';
import 'field_sheets.dart';
import 'schema_fields.dart';

/// Tuple positions and boolean arrays use native controls; unconstrained `any`
/// uses a JSON value editor because its value may be scalar, null or nested.
Future<void> showSequenceFieldSheet(
  BuildContext context, {
  required String title,
  required SchemaNode node,
  required Object? current,
  required bool modified,
  required Future<bool> Function(Object?) onSubmit,
  required Future<bool> Function() onReset,
  required String namespace,
}) => showFieldSheet<void>(
  context,
  (_) => SequenceFieldSheet(
    title: title,
    node: node,
    current: current,
    modified: modified,
    onSubmit: onSubmit,
    onReset: onReset,
    namespace: namespace,
  ),
);

class SequenceFieldSheet extends ConsumerStatefulWidget {
  const SequenceFieldSheet({
    super.key,
    required this.title,
    required this.node,
    required this.current,
    required this.modified,
    required this.onSubmit,
    required this.onReset,
    required this.namespace,
  });
  final String title;
  final SchemaNode node;
  final Object? current;
  final bool modified;
  final Future<bool> Function(Object?) onSubmit;
  final Future<bool> Function() onReset;
  final String namespace;
  @override
  ConsumerState<SequenceFieldSheet> createState() => _SequenceFieldSheetState();
}

class _SequenceFieldSheetState extends ConsumerState<SequenceFieldSheet> {
  final _form = GlobalKey<FormState>();
  late final _json = TextEditingController(text: const JsonEncoder.withIndent('  ').convert(widget.current));
  late final List<Object?> _draft = _initial();
  bool _busy = false;
  String? _error;
  SchemaNode get _node => widget.node.effective;
  bool get _canChangeLength =>
      !_busy && !(_node.inner?.meta.disabled ?? false) && !(_node.inner?.effective.meta.disabled ?? false);

  List<Object?> _initial() {
    final items = widget.current is List ? List<Object?>.of(widget.current as List) : <Object?>[];
    if (_node.type == 'tuple') {
      while (items.length < _node.list.length) {
        final item = _node.list[items.length].effective;
        items.add(item.type == 'const' ? item.value : item.meta.defaultValue);
      }
    }
    return items;
  }

  @override
  void dispose() {
    _json.dispose();
    super.dispose();
  }

  Future<void> _save({bool reset = false}) async {
    if (_busy) return;
    Object? value;
    if (!reset) {
      if (!_form.currentState!.validate()) return;
      _form.currentState!.save();
      value = _node.type == 'any' ? jsonDecode(_json.text) : _draft;
      if (_node.type == 'tuple') {
        for (var index = 0; index < _node.list.length; index++) {
          if (_node.list[index].effective.meta.required && _draft[index] == null) {
            setState(() => _error = context.l10n.engineFieldRequired);
            return;
          }
        }
      }
      if (_node.type == 'array') {
        final min = _node.meta.min;
        final max = _node.meta.max;
        final length = _draft.length;
        // Schemastery skips array.min when the item has a non-null default.
        if ((min != null && length < min && _node.inner?.meta.defaultValue == null) || (max != null && length > max)) {
          setState(() => _error = context.l10n.engineFieldInvalidFormat);
          return;
        }
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    bool ok;
    try {
      ok = reset ? await widget.onReset() : await widget.onSubmit(value);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) _error = context.l10n.commonSaveFailed;
    });
    if (ok) Navigator.of(context).pop();
  }

  Widget _item(int index, SchemaNode source) {
    final node = source.effective;
    if (source.meta.hidden || node.meta.hidden) return const SizedBox.shrink();
    final enabled = !_busy && !source.meta.disabled && !node.meta.disabled;
    final title = labelFor('${index + 1}', source, const FieldCopy());
    final value = _draft[index];
    final kind = kindOf(source);
    if (kind == FieldKind.toggle) {
      return SwitchListTile.adaptive(
        title: Text(title),
        value: value == true,
        contentPadding: EdgeInsets.zero,
        onChanged: enabled ? (next) => setState(() => _draft[index] = next) : null,
      );
    }
    if (kind == FieldKind.choice) {
      final options = choicesFor(source, const FieldCopy());
      final selected = options.where((entry) => jsonEquals(entry.$1, value)).firstOrNull;
      return DropdownButtonFormField<Object?>(
        initialValue: selected?.$1,
        isExpanded: true,
        decoration: InputDecoration(labelText: title),
        items: [for (final entry in options) DropdownMenuItem(value: entry.$1, child: Text(entry.$2))],
        onChanged: enabled ? (next) => setState(() => _draft[index] = next) : null,
        validator: (_) => node.meta.required && _draft[index] == null ? context.l10n.engineFieldRequired : null,
      );
    }
    if (kind == FieldKind.text || kind == FieldKind.number) {
      return TextFormField(
        key: ValueKey('sequence-$index'),
        initialValue: value == null ? '' : '$value',
        enabled: enabled,
        minLines: node.meta.role == 'textarea' ? 3 : 1,
        maxLines: node.meta.role == 'textarea' ? 6 : 1,
        keyboardType: kind == FieldKind.number
            ? const TextInputType.numberWithOptions(decimal: true, signed: true)
            : node.meta.role == 'textarea'
            ? TextInputType.multiline
            : TextInputType.text,
        decoration: InputDecoration(labelText: title),
        validator: (text) {
          if (!enabled) return null;
          final input = text ?? '';
          if (kind == FieldKind.number) {
            if (input.trim().isEmpty && node.meta.required) return context.l10n.engineFieldRequired;
            return validateNumber(input, node.meta, FieldUnit.plain);
          }
          // Empty text is a real tuple value, not an unset operation.
          if (input.isEmpty && (node.meta.min ?? 0) > 0) return context.l10n.engineFieldInvalidFormat;
          return validateText(input, node.meta);
        },
        onSaved: enabled
            ? (text) => _draft[index] = kind == FieldKind.number ? num.tryParse((text ?? '').trim()) : text ?? ''
            : null,
      );
    }
    if (node.type == 'const') return ListTile(title: Text(title), subtitle: Text('${node.value}'));
    // Preserve unknown, nested and secret values. Never stringify a secret.
    return ListTile(
      title: Text(title),
      subtitle: Text(context.l10n.engineFieldEditOnWeb),
      onTap: () => openDshWeb(context, ref, target: DshWebTarget(pluginItem: [widget.namespace])),
    );
  }

  @override
  Widget build(BuildContext context) => FieldSheetFrame(
    title: widget.title,
    actions: EditorSheetActions(
      busy: _busy,
      onDone: () => unawaited(_save()),
      onRestore: widget.modified ? () => unawaited(_save(reset: true)) : null,
    ),
    children: [
      Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_node.type == 'any')
              TextFormField(
                key: const ValueKey('schema-json-input'),
                controller: _json,
                enabled: !_busy,
                minLines: 4,
                maxLines: 10,
                keyboardType: TextInputType.multiline,
                autocorrect: false,
                validator: (text) {
                  try {
                    final value = jsonDecode(text ?? '');
                    return value == null && _node.meta.required ? context.l10n.engineFieldRequired : null;
                  } on FormatException {
                    return context.l10n.engineFieldInvalidFormat;
                  }
                },
              )
            else ...[
              for (var index = 0; index < (_node.type == 'tuple' ? _node.list.length : _draft.length); index++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _node.type == 'array'
                      ? Row(
                          children: [
                            Expanded(child: _item(index, _node.inner!)),
                            RemoveItemKey(
                              onPressed: !_canChangeLength ? null : () => setState(() => _draft.removeAt(index)),
                              tooltip: context.l10n.commonDelete,
                            ),
                          ],
                        )
                      : _item(index, _node.list[index]),
                ),
              if (_node.type == 'array')
                OutlinedButton(
                  onPressed: !_canChangeLength ? null : () => setState(() => _draft.add(false)),
                  child: Text(context.l10n.commonAdd),
                ),
            ],
          ],
        ),
      ),
      SheetHelper(error: _error),
    ],
  );
}

/// Removes an array item: a 48 target ending at the row's end, its ⊖ inked
/// to that end — the trailing edge of 添加 under the rows — and its press
/// circle centred on the glyph.
class RemoveItemKey extends StatelessWidget {
  const RemoveItemKey({super.key, required this.tooltip, required this.onPressed});

  final String tooltip;
  final VoidCallback? onPressed;

  static const target = 48.0;
  static const glyph = 24.0;

  /// minus-circle inks a ring of r 104 about the centre of Phosphor's 256
  /// grid, scaled 1.1 by the icon font: 13.6–242.4. Its ink ends this far
  /// inside the glyph's box.
  static const inkInset = (256 - 242.4) / 256 * glyph;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      fixedSize: const Size.square(target),
      minimumSize: const Size.square(target),
      padding: EdgeInsets.zero,
      alignment: Alignment.centerRight,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: const _EndCircleBorder(radius: 20, centreFromEnd: glyph / 2 - inkInset),
    ),
    icon: Transform.translate(
      offset: const Offset(inkInset, 0),
      child: const Icon(AppIcons.remove, size: glyph),
    ),
  );
}

/// A circle of [radius] centred [centreFromEnd] in from the right of the
/// box it shapes: the press circle around a glyph set at a target's end.
class _EndCircleBorder extends OutlinedBorder {
  const _EndCircleBorder({required this.radius, required this.centreFromEnd});

  final double radius;
  final double centreFromEnd;

  Rect _circle(Rect rect) =>
      Rect.fromCircle(center: Offset(rect.right - centreFromEnd, rect.center.dy), radius: radius);

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => Path()..addOval(_circle(rect));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => Path()..addOval(_circle(rect));

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => _EndCircleBorder(radius: radius * t, centreFromEnd: centreFromEnd * t);

  @override
  OutlinedBorder copyWith({BorderSide? side}) => this;

  @override
  bool operator ==(Object other) =>
      other is _EndCircleBorder && other.radius == radius && other.centreFromEnd == centreFromEnd;

  @override
  int get hashCode => Object.hash(radius, centreFromEnd);
}
