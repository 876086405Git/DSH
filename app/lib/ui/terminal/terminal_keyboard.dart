// The soft-keyboard bridge of the terminal page.
//
// xterm's own text input maps Enter only from TextInputAction.done (Android
// sends newline or an Enter key, fixed upstream after 4.0.0) and offers no hook
// for sticky modifiers, so the emulator runs with `hardwareKeyboardOnly` and
// this client owns the IME connection. It keeps two spaces before the caret, as
// xterm's delete detection does, so the IME always has something to delete: a
// shorter value is a Backspace, extra text is typing, and the value is put back
// after every change.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Opens the soft keyboard while [focusNode] has focus and [enabled], and
/// turns IME edits into terminal input.
class TerminalKeyboard extends StatefulWidget {
  const TerminalKeyboard({
    super.key,
    required this.focusNode,
    required this.enabled,
    required this.onText,
    required this.onBackspace,
    required this.onEnter,
    required this.onComposing,
    required this.child,
  });

  final FocusNode focusNode;
  final bool enabled;

  /// Committed text (Enter inside it already turned into [onEnter]).
  final ValueChanged<String> onText;
  final VoidCallback onBackspace;
  final VoidCallback onEnter;

  /// Text the IME is still composing (pinyin before a candidate is picked);
  /// null when nothing is pending.
  final ValueChanged<String?> onComposing;
  final Widget child;

  @override
  State<TerminalKeyboard> createState() => TerminalKeyboardState();
}

class TerminalKeyboardState extends State<TerminalKeyboard> with TextInputClient {
  static const _sentinel = TextEditingValue(text: '  ', selection: TextSelection.collapsed(offset: 2));

  TextInputConnection? _connection;
  TextEditingValue _value = _sentinel;

  /// The IME holds unfinished text: hardware-style key events must wait.
  bool get composing => _value.composing.isValid && !_value.composing.isCollapsed;

  bool get hasConnection => _connection?.attached ?? false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_sync);
  }

  @override
  void didUpdateWidget(TerminalKeyboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_sync);
      widget.focusNode.addListener(_sync);
    }
    if (oldWidget.enabled != widget.enabled) _sync();
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_sync);
    _close();
    super.dispose();
  }

  /// Brings the keyboard back (a tap on the screen after it was dismissed).
  /// On a fresh connection: some IMEs ignore show() once Back has hidden them
  /// (iFlytek on HyperOS, #1277), and a new attach is what brings them back,
  /// as leaving the page does. Attaching in the same frame keeps an open
  /// keyboard up.
  void show() {
    if (!widget.enabled) return;
    flushComposing();
    _close();
    if (!widget.focusNode.hasFocus) {
      widget.focusNode.requestFocus();
      return;
    }
    _open();
  }

  /// Sends what the IME is still composing as typed text and ends the
  /// composition, so a key from the key row lands after it (`git ch` + Tab).
  void flushComposing() {
    if (!composing) return;
    final text = _value.composing.textInside(_value.text);
    widget.onComposing(null);
    if (text.isNotEmpty) _emit(text);
    _reset();
  }

  void _sync() {
    if (widget.enabled && widget.focusNode.hasFocus) {
      _open();
    } else {
      _close();
    }
  }

  void _open() {
    final existing = _connection;
    if (existing != null && existing.attached) {
      existing.show();
      return;
    }
    final connection = TextInput.attach(
      this,
      const TextInputConfiguration(
        inputAction: TextInputAction.newline,
        keyboardAppearance: Brightness.dark,
        autocorrect: false,
        // Disabling suggestions sets Android's visible-password input type.
        enableSuggestions: true,
        enableIMEPersonalizedLearning: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
      ),
    );
    _connection = connection;
    _value = _sentinel;
    connection
      ..show()
      ..setEditingState(_sentinel);
  }

  void _close() {
    final connection = _connection;
    _connection = null;
    if (connection != null && connection.attached) connection.close();
    if (composing) widget.onComposing(null);
    _value = _sentinel;
  }

  void _reset() {
    _value = _sentinel;
    _connection?.setEditingState(_sentinel);
  }

  // ── TextInputClient ──

  @override
  TextEditingValue? get currentTextEditingValue => _value;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    _value = value;
    if (composing) {
      widget.onComposing(value.composing.textInside(value.text));
      return;
    }
    widget.onComposing(null);
    final text = value.text;
    if (text == _sentinel.text) return;
    final base = _sentinel.text;
    var common = 0;
    while (common < text.length && common < base.length && text.codeUnitAt(common) == base.codeUnitAt(common)) {
      common++;
    }
    for (var i = common; i < base.length; i++) {
      widget.onBackspace();
    }
    final inserted = text.substring(common);
    if (inserted.isNotEmpty) _emit(inserted);
    _reset();
  }

  /// Splits committed text at line breaks: each one is an Enter.
  void _emit(String text) {
    final lines = text.replaceAll('\r\n', '\n').split(RegExp('[\r\n]'));
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].isNotEmpty) widget.onText(lines[i]);
      if (i < lines.length - 1) widget.onEnter();
    }
  }

  @override
  void performAction(TextInputAction action) => widget.onEnter();

  @override
  void connectionClosed() {
    _connection = null;
    if (composing) widget.onComposing(null);
    _value = _sentinel;
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}

  @override
  void didChangeInputControl(TextInputControl? oldControl, TextInputControl? newControl) {}

  @override
  void performSelector(String selectorName) {}

  @override
  void insertContent(KeyboardInsertedContent content) {}

  @override
  Widget build(BuildContext context) => widget.child;
}
