// 她的设定: her name, what she calls the person, and who she is: the persona
// text itself, the default one to start from. The app's own rules (the mark
// format her stage reads, the safety lines) are added after it and not shown
// here (companion_state.dart). Everything saves as it is typed.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_state.dart';
import '../../l10n/l10n.dart';
import '../providers/provider_widgets.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';

class CompanionPersonaPage extends ConsumerStatefulWidget {
  const CompanionPersonaPage({super.key, this.packName, this.whale = true});

  /// Her name in the pack, for the name field's hint and the default persona.
  final String? packName;

  /// She is the app's own whale girl, whose default persona is hers.
  final bool whale;

  @override
  ConsumerState<CompanionPersonaPage> createState() => _CompanionPersonaPageState();
}

class _CompanionPersonaPageState extends ConsumerState<CompanionPersonaPage> {
  final _name = TextEditingController();
  final _callMe = TextEditingController();
  final _persona = TextEditingController();
  Timer? _saveTimer;

  // Held from the start: what is still unsaved is saved as the page closes,
  // when providers can no longer be read.
  late final CompanionNameSetting _names = ref.read(companionNameProvider.notifier);
  late final CompanionPersonaController _personas = ref.read(companionPersonaProvider.notifier);
  late final CompanionRenamed _renamed = ref.read(companionRenamedProvider.notifier);
  late final String? _nameBefore = ref.read(companionNameProvider);

  @override
  void initState() {
    super.initState();
    final persona = ref.read(companionPersonaProvider);
    _name.text = _nameBefore ?? '';
    _callMe.text = persona.callMe;
    _persona.text = persona.custom.trim().isNotEmpty ? persona.custom : _defaultFor(_nameBefore);
    // Bind now, not on first use (dispose can't).
    (_names, _personas, _renamed);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    final (name, settings) = _values();
    final renamed = name != _nameBefore && name != null;
    // Providers can't change while the tree is being torn down: right after.
    scheduleMicrotask(() {
      _write(name, settings);
      // Back in the room, she answers to it.
      if (renamed) _renamed.set(name);
    });
    _name.dispose();
    _callMe.dispose();
    _persona.dispose();
    super.dispose();
  }

  String? _given(String text) => text.trim().isEmpty ? null : text.trim();

  /// The default persona under the name she would go by with [name].
  String _defaultFor(String? name) => companionPersonaPart(name: name ?? widget.packName, whale: widget.whale);

  void _edited() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _save);
  }

  /// What the fields say now: her name, and the persona settings.
  (String?, CompanionPersonaSettings) _values() {
    final name = _given(_name.text);
    // Still the default (under whichever name): nothing of their own to keep.
    final text = _persona.text.trim();
    final own = text == _defaultFor(name).trim() || text == companionPersonaDefault.trim() ? '' : text;
    return (name, CompanionPersonaSettings(custom: own, callMe: _callMe.text.trim()));
  }

  void _write(String? name, CompanionPersonaSettings settings) {
    unawaited(_names.set(name));
    unawaited(_personas.set(settings));
  }

  void _save() {
    _saveTimer?.cancel();
    final (name, settings) = _values();
    _write(name, settings);
  }

  void _reset() {
    setState(() => _persona.text = _defaultFor(_given(_name.text)));
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AppPage.list(
      title: l10n.companionMenuPersona,
      children: [
        SettingsSection(
          children: [
            FormFieldGroup(
              children: [
                FormFieldBlock(
                  label: l10n.companionPersonaName,
                  helper: l10n.companionPersonaNameHelper,
                  child: TextField(
                    controller: _name,
                    onChanged: (_) => _edited(),
                    decoration: InputDecoration(hintText: widget.packName, counterText: ''),
                  ),
                ),
                FormFieldBlock(
                  label: l10n.companionPersonaCallMe,
                  helper: l10n.companionPersonaCallMeHelper,
                  child: TextField(
                    controller: _callMe,
                    onChanged: (_) => _edited(),
                    decoration: InputDecoration(hintText: l10n.companionPersonaCallMeHint, counterText: ''),
                  ),
                ),
              ],
            ),
          ],
        ),
        SettingsSection(
          title: l10n.companionPersonaText,
          footer: Text(l10n.companionPersonaFooter),
          children: [
            FormFieldGroup(
              children: [
                FormFieldBlock(
                  label: l10n.companionPersonaTextLabel,
                  helper: l10n.companionPersonaTextHelper,
                  trailing: FormSmallButton(label: l10n.companionPersonaReset, onPressed: _reset),
                  child: TextField(
                    controller: _persona,
                    minLines: 10,
                    maxLines: 24,
                    keyboardType: TextInputType.multiline,
                    onChanged: (_) => _edited(),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
