// A one-field dialog (rename, new folder, new group, type a path) that owns
// its controller, so the field survives the dialog's exit animation.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../common/app_dialog.dart';
import '../theme/theme.dart';

/// Asks for one line of text; resolves to it trimmed, or null when
/// cancelled. [validate] returns why the text can't be used (shown under
/// the field), or null.
Future<String?> showTextPrompt(
  BuildContext context, {
  required String title,
  String initial = '',
  String? hint,
  String? caption,
  String? confirm,
  int? maxLength,
  bool mono = false,
  TextInputType? keyboardType,
  String? Function(String text)? validate,
  void Function(ModalRoute<Object?> route, Route<dynamic>? nextRoute)? onRouteChanged,
}) {
  final l10n = context.l10n;
  return showAppDialog<String>(
    context: context,
    onRouteChanged: onRouteChanged,
    builder: (_) => _TextPrompt(
      title: title,
      initial: initial,
      hint: hint,
      caption: caption,
      confirm: confirm ?? l10n.commonSave,
      maxLength: maxLength,
      mono: mono,
      keyboardType: keyboardType,
      validate: validate,
    ),
  );
}

class _TextPrompt extends StatefulWidget {
  const _TextPrompt({
    required this.title,
    required this.initial,
    required this.confirm,
    required this.mono,
    this.hint,
    this.caption,
    this.maxLength,
    this.keyboardType,
    this.validate,
  });

  final String title;
  final String initial;
  final String? hint;
  final String? caption;
  final String confirm;
  final int? maxLength;
  final bool mono;
  final TextInputType? keyboardType;
  final String? Function(String text)? validate;

  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _problem;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    final problem = widget.validate?.call(text);
    if (problem != null) return setState(() => _problem = problem);
    Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final field = TextField(
      controller: _controller,
      autofocus: true,
      autocorrect: !widget.mono,
      enableSuggestions: !widget.mono,
      maxLength: widget.maxLength,
      keyboardType: widget.keyboardType,
      style: widget.mono ? AppType.mono(size: 14) : null,
      decoration: InputDecoration(hintText: widget.hint, counterText: '', errorText: _problem),
      onChanged: (_) {
        if (_problem != null) setState(() => _problem = null);
      },
      onSubmitted: (_) => _submit(),
    );
    return AlertDialog(
      title: Text(widget.title),
      content: widget.caption == null
          ? field
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.caption!,
                  style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
                ),
                const SizedBox(height: 8),
                field,
              ],
            ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
        FilledButton(onPressed: _submit, child: Text(widget.confirm)),
      ],
    );
  }
}
