// 资源库 › 正则 › 编辑规则 (docs/design/roleplay-ui.md §9, engine 123
// updateRegexScript): one rule's own fields, in SillyTavern's names, edited
// in place — the rule keeps its place in the list and its first source.
// Only what changed is written; what the rule carries that this page does not
// show is left as it is. A rule saved that cannot run here still saves, and
// says so: whether it is on and whether it can run are two things.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../common/brief_notice.dart';
import '../common/discard_guard.dart';
import '../providers/provider_widgets.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/theme.dart';
import 'tavern_regex_page.dart' show tavernRegexProvider;
import 'tavern_regex_test_page.dart';

class TavernRegexEditPage extends ConsumerStatefulWidget {
  const TavernRegexEditPage({super.key, required this.script});

  final TavernRegexScript script;

  static Route<void> route(TavernRegexScript script) =>
      MaterialPageRoute<void>(builder: (_) => TavernRegexEditPage(script: script));

  @override
  ConsumerState<TavernRegexEditPage> createState() => _TavernRegexEditPageState();
}

/// Which copy a rule changes, from ST's two flags: neither is the saved text
/// itself; markdownOnly only what is shown; promptOnly only what is sent.
enum _Phase { write, display, prompt, both }

class _TavernRegexEditPageState extends ConsumerState<TavernRegexEditPage> {
  late final Map<String, Object?> _raw = widget.script.raw;

  static String _text(Object? value) => value is String ? value : '';
  static int? _depth(Object? value) => value is num && value.isFinite && value >= 0 ? value.round() : null;

  late final _name = TextEditingController(text: _text(_raw['scriptName']));
  late final _find = TextEditingController(text: _text(_raw['findRegex']));
  late final _replace = TextEditingController(text: _text(_raw['replaceString']));
  late final _trim = TextEditingController(
    text: [
      if (_raw['trimStrings'] case final List<Object?> list)
        for (final s in list)
          if (s is String) s,
    ].join('\n'),
  );
  late final _minDepth = TextEditingController(text: '${_depth(_raw['minDepth']) ?? ''}');
  late final _maxDepth = TextEditingController(text: '${_depth(_raw['maxDepth']) ?? ''}');
  late final _edits = Listenable.merge([_name, _find, _replace, _trim, _minDepth, _maxDepth]);

  late Set<int> _placement = {
    if (_raw['placement'] case final List<Object?> list)
      for (final p in list)
        if (p is num) p.round(),
  };
  late _Phase _phase = switch ((_raw['markdownOnly'] == true, _raw['promptOnly'] == true)) {
    (false, false) => _Phase.write,
    (true, false) => _Phase.display,
    (false, true) => _Phase.prompt,
    (true, true) => _Phase.both,
  };
  late int _substitute = switch (_raw['substituteRegex']) {
    final num n when n == 1 || n == 2 => n.round(),
    true => 1,
    _ => 0,
  };
  late bool _runOnEdit = _raw['runOnEdit'] == true;
  late bool _enabled = widget.script.enabled;

  late final Map<String, Object?> _start = _fields();
  bool _saving = false;
  bool _leaving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _find, _replace, _trim, _minDepth, _maxDepth]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The rule as the page now has it, in ST's field names.
  Map<String, Object?> _fields() => {
    'scriptName': _name.text.trim(),
    'findRegex': _find.text,
    'replaceString': _replace.text,
    'trimStrings': [
      for (final line in _trim.text.split('\n'))
        if (line.isNotEmpty) line,
    ],
    'placement': _placement.toList()..sort(),
    'markdownOnly': _phase == _Phase.display || _phase == _Phase.both,
    'promptOnly': _phase == _Phase.prompt || _phase == _Phase.both,
    'minDepth': int.tryParse(_minDepth.text.trim()),
    'maxDepth': int.tryParse(_maxDepth.text.trim()),
    'substituteRegex': _substitute,
    'runOnEdit': _runOnEdit,
    'disabled': !_enabled,
  };

  /// What changed since the page opened; only that is written.
  Map<String, Object?> _changes() {
    final now = _fields();
    return {
      for (final MapEntry(:key, :value) in now.entries)
        if ('$value' != '${_start[key]}') key: value,
    };
  }

  bool _dirty() => !_leaving && _changes().isNotEmpty;

  Future<void> _save() async {
    if (_saving) return;
    final changes = _changes();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    if (changes.isEmpty) {
      _leaving = true;
      navigator.pop();
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await ref.read(tavernProvider).updateRegexScript(widget.script.id, changes);
      if (!mounted) return;
      ref.invalidate(tavernRegexProvider);
      if (!saved.compatible) messenger?.showBriefNotice(l10n.tavernRegexSavedIncompatible);
      _leaving = true;
      navigator.pop();
    } on TavernImportError {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = l10n.tavernRegexGone;
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '${l10n.commonSaveFailed}：$e';
        });
      }
    }
  }

  /// 试一下 with the rule as filled in, not as saved.
  void _try() => unawaited(
    Navigator.of(context).push(
      TavernRegexTestPage.route(
        TavernRegexScript(
          id: widget.script.id,
          sourceText: widget.script.sourceText,
          raw: {...widget.script.raw, ..._fields()},
          importedAt: widget.script.importedAt,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final enabled = !_saving;
    final code = theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace', height: 1.5);
    TextField field(
      TextEditingController controller, {
      String? key,
      int? maxLines = 1,
      int? minLines,
      TextStyle? style,
      bool digits = false,
      String? hint,
    }) => TextField(
      key: key == null ? null : ValueKey(key),
      controller: controller,
      enabled: enabled,
      maxLines: maxLines,
      minLines: minLines,
      style: style,
      keyboardType: digits ? TextInputType.number : (maxLines == 1 ? null : TextInputType.multiline),
      inputFormatters: digits ? [FilteringTextInputFormatter.digitsOnly] : null,
      decoration: InputDecoration(hintText: hint),
    );
    // What the last check said: a rule that cannot run here, or one that can
    // only be judged when it runs (it uses macros).
    final issues = [
      for (final d in widget.script.diagnostics)
        if (d.status == TavernRegexCompatibility.incompatible) (d.message, dsh.danger),
      if (widget.script.diagnostics.any((d) => d.status == TavernRegexCompatibility.deferred))
        (l10n.tavernRegexDeferred, dsh.textTertiary),
    ];
    final places = [
      (RegexPlacement.userInput, l10n.tavernRegexPlaceUser),
      (RegexPlacement.aiOutput, l10n.tavernRegexPlaceAi),
      (RegexPlacement.slashCommand, l10n.tavernRegexPlaceSlash),
      (RegexPlacement.worldInfo, l10n.tavernRegexPlaceWorld),
      (RegexPlacement.reasoning, l10n.tavernRegexPlaceReasoning),
    ];
    final body = <Widget>[
      for (final (message, color) in issues)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Text(message, style: theme.textTheme.bodySmall?.copyWith(color: color, height: 1.5)),
        ),
      SettingsSection(
        children: [
          FormFieldGroup(
            children: [
              FormFieldBlock(
                label: l10n.tavernRegexFieldName,
                child: field(_name, key: 'tavern-regex-edit-name'),
              ),
              FormFieldBlock(
                label: l10n.tavernRegexTestFind,
                helper: l10n.tavernRegexFieldFindHelp,
                child: field(_find, key: 'tavern-regex-edit-find', maxLines: 4, minLines: 1, style: code),
              ),
              FormFieldBlock(
                label: l10n.tavernRegexTestReplace,
                helper: l10n.tavernRegexFieldReplaceHelp,
                child: field(_replace, key: 'tavern-regex-edit-replace', maxLines: 8, minLines: 2, style: code),
              ),
              FormFieldBlock(
                label: l10n.tavernRegexFieldTrim,
                helper: l10n.tavernRegexFieldTrimHelp,
                child: field(_trim, key: 'tavern-regex-edit-trim', maxLines: 6, minLines: 1, style: code),
              ),
            ],
          ),
        ],
      ),
      // A row like the rest, under the fields it tries.
      SettingsSection(
        children: [
          SettingsTile(
            key: const ValueKey('tavern-regex-edit-try'),
            title: l10n.tavernRegexTryDraft,
            onTap: enabled ? _try : null,
          ),
        ],
      ),
      SettingsSection(
        title: l10n.tavernRegexPlacement,
        footer: Text(l10n.tavernRegexPhaseNote),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (place, label) in places)
                    FilterChip(
                      key: ValueKey('tavern-regex-place-$place'),
                      label: Text(label),
                      selected: _placement.contains(place),
                      onSelected: enabled
                          ? (on) => setState(
                              () => _placement = on ? {..._placement, place} : ({..._placement}..remove(place)),
                            )
                          : null,
                    ),
                ],
              ),
            ),
          ),
          SettingsSegmentTile<_Phase>(
            key: const ValueKey('tavern-regex-edit-phase'),
            title: l10n.tavernRegexPhase,
            segments: [
              PillSegment(_Phase.write, l10n.tavernRegexPhaseWrite),
              PillSegment(_Phase.display, l10n.tavernRegexPhaseDisplay),
              PillSegment(_Phase.prompt, l10n.tavernRegexPhasePrompt),
              PillSegment(_Phase.both, l10n.tavernRegexPhaseBoth),
            ],
            selected: _phase,
            onChanged: enabled ? (p) => setState(() => _phase = p) : (_) {},
          ),
        ],
      ),
      SettingsSection(
        footer: Text(l10n.tavernRegexDepthHelp),
        children: [
          FormFieldGroup(
            children: [
              FormFieldBlock(
                label: l10n.tavernRegexMinDepth,
                child: field(_minDepth, key: 'tavern-regex-edit-min', digits: true, hint: l10n.tavernRegexDepthAny),
              ),
              FormFieldBlock(
                label: l10n.tavernRegexMaxDepth,
                child: field(_maxDepth, key: 'tavern-regex-edit-max', digits: true, hint: l10n.tavernRegexDepthAny),
              ),
            ],
          ),
        ],
      ),
      SettingsSection(
        children: [
          SettingsSegmentTile<int>(
            key: const ValueKey('tavern-regex-edit-substitute'),
            title: l10n.tavernRegexSubstitute,
            segments: [
              PillSegment(0, l10n.tavernRegexSubstituteNone),
              PillSegment(1, l10n.tavernRegexSubstituteRaw),
              PillSegment(2, l10n.tavernRegexSubstituteEscaped),
            ],
            selected: _substitute,
            onChanged: enabled ? (s) => setState(() => _substitute = s) : (_) {},
          ),
          SettingsSwitchTile(
            key: const ValueKey('tavern-regex-edit-run-on-edit'),
            title: l10n.tavernRegexRunOnEdit,
            value: _runOnEdit,
            onChanged: enabled ? (on) => setState(() => _runOnEdit = on) : null,
          ),
          SettingsSwitchTile(
            key: const ValueKey('tavern-regex-edit-enabled'),
            title: l10n.tavernRegexFieldEnabled,
            value: _enabled,
            onChanged: enabled ? (on) => setState(() => _enabled = on) : null,
          ),
        ],
      ),
      if (_error case final error?)
        Padding(
          key: const ValueKey('tavern-regex-edit-error'),
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Text(error, style: theme.textTheme.bodySmall?.copyWith(color: dsh.danger)),
        ),
      const SizedBox(height: FormBottomBar.height),
    ];
    return DiscardGuard(
      listenable: _edits,
      isDirty: _dirty,
      child: Stack(
        children: [
          AppPage.list(
            title: l10n.tavernRegexEdit,
            children: [Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body)],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: FormBottomBar(
              child: FilledButton(
                key: const ValueKey('tavern-regex-edit-save'),
                onPressed: enabled ? _save : null,
                child: Text(l10n.commonSave),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
