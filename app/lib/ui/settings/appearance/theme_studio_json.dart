// The Theme Studio's raw view: the draft as theme.json, editable as text and checked by the same parser that
// reads installed packs.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/l10n.dart';
import '../../common/app_sheet.dart';
import '../../common/field_paste.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'theme_studio_controller.dart';
import 'theme_studio_problems.dart';

class ThemeStudioJsonSheet extends StatefulWidget {
  const ThemeStudioJsonSheet({super.key, required this.controller});

  final ThemeStudioController controller;

  @override
  State<ThemeStudioJsonSheet> createState() => _ThemeStudioJsonSheetState();
}

class _ThemeStudioJsonSheetState extends State<ThemeStudioJsonSheet> with FieldPaste {
  late final _text = TextEditingController(
    text: const JsonEncoder.withIndent('  ').convert(widget.controller.pack.toJson()),
  );
  final _focus = FocusNode();
  ThemePack? _parsed;
  String? _error;

  /// Where the text stops being JSON, when that is what is wrong with it.
  int? _errorAt;
  String? _note;

  @override
  void initState() {
    super.initState();
    _check(_text.text);
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _check(String text) {
    final english = AppLocale.isEnglish;
    _note = null;
    _parsed = null;
    _errorAt = null;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      final at = error.offset?.clamp(0, text.length);
      _errorAt = at;
      if (at == null) {
        _error = english ? 'This is not valid JSON.' : '这不是合法的 JSON。';
      } else {
        final line = '\n'.allMatches(text.substring(0, at)).length + 1;
        _error = english ? 'Not valid JSON near line $line. Tap here to go there.' : 'JSON 在第 $line 行附近写错了，点这里跳过去。';
      }
      return;
    }
    if (decoded is! Map<String, Object?>) {
      _error = english ? 'The whole text has to sit inside one pair of { }.' : '最外层要是一对花括号 { }。';
      return;
    }
    try {
      _parsed = ThemePack.parse(decoded);
      _error = null;
    } on FormatException catch (error) {
      _error = studioProblemText(error.message);
    }
  }

  void _goToError() {
    final at = _errorAt;
    if (at == null) return;
    _text.selection = TextSelection.collapsed(offset: at);
    _focus.requestFocus();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _text.text));
    if (mounted) setState(() => _note = AppLocale.isEnglish ? 'Copied.' : '已复制。');
  }

  Future<void> _paste() async {
    final text = await readClipboard(say: (message) => setState(() => _note = message));
    if (text == null || text.trim().isEmpty || !mounted) return;
    setState(() {
      _text.text = text;
      _check(text);
    });
    // Typing keeps its caret; pasted text has none worth keeping.
    _goToError();
  }

  void _apply() {
    final parsed = _parsed;
    if (parsed == null) return;
    widget.controller.replaceWith(parsed);
    Navigator.of(context).maybePop(true);
  }

  @override
  Widget build(BuildContext context) {
    final english = AppLocale.isEnglish;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final c = widget.controller;
    final keepsId = c.editing && _parsed != null && _parsed!.id != c.pack.id;
    final status =
        _error ??
        _note ??
        (keepsId
            ? (english
                  ? 'This theme keeps its ID "${c.pack.id}"; the ID here is ignored.'
                  : '正在编辑已有主题，ID 仍然是「${c.pack.id}」，这里写的 ID 不会生效。')
            : (english ? 'Looks good.' : '格式没问题。'));
    return Column(
      children: [
        SheetHeader(
          english ? 'Edit as JSON' : '直接编辑 JSON',
          actions: [
            SheetIconButton(
              key: const ValueKey('theme-json-copy'),
              icon: AppIcons.copy,
              tooltip: english ? 'Copy' : '复制',
              onPressed: _copy,
            ),
            SheetIconButton(
              key: const ValueKey('theme-json-paste'),
              icon: AppIcons.paste,
              tooltip: english ? 'Paste' : '粘贴',
              onPressed: _paste,
            ),
          ],
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              key: const ValueKey('theme-json-field'),
              controller: _text,
              focusNode: _focus,
              onChanged: (text) => setState(() => _check(text)),
              expands: true,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              autocorrect: false,
              enableSuggestions: false,
              // Curly quotes and long dashes are not JSON.
              smartQuotesType: SmartQuotesType.disabled,
              smartDashesType: SmartDashesType.disabled,
              style: AppType.mono(size: 12.5),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _errorAt == null ? null : _goToError,
                  child: Text(
                    status,
                    key: const ValueKey('theme-json-status'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _error != null ? scheme.error : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                key: const ValueKey('theme-json-apply'),
                onPressed: _parsed == null ? null : _apply,
                child: Text(english ? 'Apply' : '应用'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
