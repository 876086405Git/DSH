// A card script's UI request shown by the app itself (tavern_interact.dart):
// /input, /buttons and /popup as the app's own dialogs, /echo as its notice,
// /setinput into the composer. Nothing of it is drawn in the card's page.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_interact.dart';
import '../chat/render/markdown_body.dart';
import '../common/app_dialog.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart' show DshColors;

/// Shows [kind]'s request with [fields] and answers it once.
///
/// input: the words written (submitted, '' too), or 取消 (cancelled), or put
/// aside (dismissed). buttons: the button tapped, by its place and label as
/// given (blank and repeated labels stay as they are). popup: its OK, or put
/// aside. echo: shown as the app's notice and answered with its words at once,
/// or when it goes if [TavernInteractFields.awaitDismissal] (dismissed when
/// the person put it away). setInput: [onSetInput] sets the composer and the
/// words are the answer; with nowhere to put them, cancelled.
///
/// [withdraw] completing (the script stopped, its page gone) closes what is
/// still open and answers cancelled: nobody's answer is made up.
Future<TavernInteractAnswer> showTavernInteract(
  BuildContext context,
  TavernInteractKind kind,
  Map<String, Object?> fields, {
  Future<void>? withdraw,
  ValueChanged<String>? onSetInput,
}) async {
  final f = TavernInteractFields.of(kind, fields);
  switch (kind) {
    case TavernInteractKind.setInput:
      if (onSetInput == null) return const TavernInteractAnswer(TavernInteractStatus.cancelled);
      onSetInput(f.text);
      return TavernInteractAnswer(TavernInteractStatus.submitted, text: f.text);
    case TavernInteractKind.echo:
      return _echo(context, f, withdraw);
    case TavernInteractKind.input || TavernInteractKind.buttons || TavernInteractKind.popup:
      return _dialog(context, kind, f, withdraw);
  }
}

/// The request's words: Markdown when asked for, else as they read.
Widget _words(TavernInteractFields f, {TextStyle? style}) =>
    f.markdown ? MarkdownBody(text: f.shown, selectable: true) : SelectableText(f.shown, style: style);

Future<TavernInteractAnswer> _dialog(
  BuildContext context,
  TavernInteractKind kind,
  TavernInteractFields f,
  Future<void>? withdraw,
) async {
  BuildContext? open;
  var withdrawn = false;
  void close() {
    final at = open;
    if (at == null || !at.mounted) return;
    final route = ModalRoute.of(at);
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(at);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  unawaited(
    withdraw?.then((_) {
      withdrawn = true;
      close();
    }),
  );
  final answer = await showAppDialog<TavernInteractAnswer>(
    context: context,
    builder: (dialog) {
      final first = open == null;
      open = dialog;
      // Taken back before it was even drawn: it goes once it is.
      if (first && withdrawn) WidgetsBinding.instance.addPostFrameCallback((_) => close());
      return switch (kind) {
        TavernInteractKind.input => _InputDialog(fields: f),
        TavernInteractKind.buttons => _ButtonsDialog(fields: f),
        _ => _PopupDialog(fields: f),
      };
    },
  );
  if (withdrawn) return const TavernInteractAnswer(TavernInteractStatus.cancelled);
  return answer ?? const TavernInteractAnswer(TavernInteractStatus.dismissed);
}

/// Wider for [TavernInteractFields.wide], taller for [TavernInteractFields.large].
EdgeInsets _inset(TavernInteractFields f) => f.wide
    ? const EdgeInsets.symmetric(horizontal: 12, vertical: 24)
    : const EdgeInsets.symmetric(horizontal: 32, vertical: 24);

Widget _body(BuildContext context, TavernInteractFields f, List<Widget> below) {
  final height = MediaQuery.sizeOf(context).height;
  return ConstrainedBox(
    constraints: BoxConstraints(minHeight: f.large ? height * 0.5 : 0, maxHeight: height * (f.large ? 0.75 : 0.6)),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [if (f.shown.isNotEmpty) _words(f), ...below],
      ),
    ),
  );
}

class _InputDialog extends StatefulWidget {
  const _InputDialog({required this.fields});

  final TavernInteractFields fields;

  @override
  State<_InputDialog> createState() => _InputDialogState();
}

class _InputDialogState extends State<_InputDialog> {
  late final _field = TextEditingController(text: widget.fields.defaultValue);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(TavernInteractAnswer(TavernInteractStatus.submitted, text: _field.text));

  @override
  Widget build(BuildContext context) {
    final f = widget.fields;
    final l10n = context.l10n;
    final rows = f.large ? f.rows.clamp(8, 20) : f.rows.clamp(1, 12);
    return AlertDialog(
      key: const ValueKey('tavern-interact-input'),
      insetPadding: _inset(f),
      title: f.title == null ? null : Text(f.title!),
      content: SizedBox(
        width: double.maxFinite,
        child: _body(context, f, [
          if (f.shown.isNotEmpty) const SizedBox(height: 12),
          TextField(
            key: const ValueKey('tavern-interact-field'),
            controller: _field,
            autofocus: true,
            minLines: rows,
            maxLines: rows == 1 ? 1 : rows + 4,
            textInputAction: rows == 1 ? TextInputAction.done : TextInputAction.newline,
            onSubmitted: rows == 1 ? (_) => _submit() : null,
          ),
        ]),
      ),
      actions: [
        TextButton(
          key: const ValueKey('tavern-interact-cancel'),
          onPressed: () => Navigator.of(context).pop(const TavernInteractAnswer(TavernInteractStatus.cancelled)),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const ValueKey('tavern-interact-ok'),
          onPressed: _submit,
          child: Text(f.okButton ?? l10n.commonConfirm),
        ),
      ],
    );
  }
}

class _ButtonsDialog extends StatelessWidget {
  const _ButtonsDialog({required this.fields});

  final TavernInteractFields fields;

  @override
  Widget build(BuildContext context) {
    final f = fields;
    final labels = f.buttonLabels;
    return AlertDialog(
      key: const ValueKey('tavern-interact-buttons'),
      insetPadding: _inset(f),
      title: f.title == null ? null : Text(f.title!),
      content: SizedBox(
        width: double.maxFinite,
        child: _body(context, f, [
          if (f.shown.isNotEmpty) const SizedBox(height: 12),
          for (final (i, label) in labels.indexed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.tonal(
                key: ValueKey('tavern-interact-button-$i'),
                // A blank label keeps its place: a button as tall as the others.
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                onPressed: () =>
                    Navigator.of(context)
                        .pop(TavernInteractAnswer(TavernInteractStatus.submitted, buttonIndex: i, label: label)),
                child: Text(label, textAlign: TextAlign.center),
              ),
            ),
        ]),
      ),
      actions: [
        TextButton(
          key: const ValueKey('tavern-interact-cancel'),
          onPressed: () => Navigator.of(context).pop(const TavernInteractAnswer(TavernInteractStatus.cancelled)),
          child: Text(context.l10n.commonCancel),
        ),
      ],
    );
  }
}

class _PopupDialog extends StatelessWidget {
  const _PopupDialog({required this.fields});

  final TavernInteractFields fields;

  @override
  Widget build(BuildContext context) {
    final f = fields;
    return AlertDialog(
      key: const ValueKey('tavern-interact-popup'),
      insetPadding: _inset(f),
      title: f.title == null ? null : Text(f.title!),
      content: SizedBox(
        width: double.maxFinite,
        child: Scrollbar(thumbVisibility: f.scroll && f.large, child: _body(context, f, const [])),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('tavern-interact-ok'),
          onPressed: () => Navigator.of(context).pop(const TavernInteractAnswer(TavernInteractStatus.submitted)),
          child: Text(f.okButton ?? context.l10n.commonConfirm),
        ),
      ],
    );
  }
}

/// [theme] for Markdown on the notice's ground (the inverse surface): it
/// draws in onSurface, which there is the ground's own tone; its code wells,
/// table headers and highlighting take the other brightness's, made for that text.
ThemeData _onNotice(ThemeData theme) {
  final scheme = theme.colorScheme;
  final dsh = theme.extension<DshColors>()!;
  final dark = theme.brightness == Brightness.dark;
  final other = dark ? DshColors.light : DshColors.dark;
  return theme.copyWith(
    // The notice's ground is the other brightness's: code blocks pick their
    // highlighting by it.
    brightness: dark ? Brightness.light : Brightness.dark,
    colorScheme: scheme.copyWith(
      onSurface: scheme.onInverseSurface,
      onSurfaceVariant: scheme.onInverseSurface,
      primary: scheme.inversePrimary,
    ),
    extensions: [
      for (final e in theme.extensions.values)
        if (e is! DshColors) e,
      dsh.copyWith(
        codeWellBg: other.codeWellBg,
        codeWellHeader: other.codeWellHeader,
        codeWellFg: other.codeWellFg,
        codeWellBorder: other.codeWellBorder,
      ),
    ],
  );
}

/// /echo: the app's notice, its title over its words, marked by how much it
/// matters; a tap puts it away.
Future<TavernInteractAnswer> _echo(BuildContext context, TavernInteractFields f, Future<void>? withdraw) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final text = f.shown;
  if (messenger == null) return const TavernInteractAnswer(TavernInteractStatus.cancelled);
  // Marked by its shape: on the notice's dark ground a coloured mark reads poorly.
  final icon = switch (f.severity) {
    'error' => AppIcons.error,
    'warning' => AppIcons.warning,
    'success' => AppIcons.success,
    _ => AppIcons.info,
  };
  final serious = f.severity == 'error' || f.severity == 'warning';
  final bar = messenger.showSnackBar(
    SnackBar(
      key: const ValueKey('tavern-interact-echo'),
      duration: Duration(milliseconds: (2500 + text.runes.length * 50).clamp(serious ? 5000 : 3000, 9000)),
      content: Builder(
        builder: (bar) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => ScaffoldMessenger.of(bar).hideCurrentSnackBar(reason: SnackBarClosedReason.dismiss),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: DefaultTextStyle.of(bar).style.color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (f.title != null) Text(f.title!, style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (text.isNotEmpty)
                      f.markdown
                          ? Theme(
                              data: _onNotice(Theme.of(bar)),
                              child: MarkdownBody(text: text, selectable: false),
                            )
                          : Text(text),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (!f.awaitDismissal) return TavernInteractAnswer(TavernInteractStatus.submitted, text: text);
  // Withdrawn while up: it stays shown, only nobody waits for it now.
  final reason = await Future.any<SnackBarClosedReason?>([
    bar.closed,
    if (withdraw != null) withdraw.then((_) => null),
  ]);
  if (reason == null) return const TavernInteractAnswer(TavernInteractStatus.cancelled);
  return TavernInteractAnswer(
    reason == SnackBarClosedReason.dismiss || reason == SnackBarClosedReason.swipe
        ? TavernInteractStatus.dismissed
        : TavernInteractStatus.submitted,
    text: text,
  );
}
