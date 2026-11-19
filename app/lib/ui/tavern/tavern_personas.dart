// 人设 (docs/design/roleplay-ui.md §1, §6): who you are in the tavern. A
// persona is a name and a description the model reads. One can be the
// default; a chat can pick its own. The composer's left key shows whose
// voice you are writing in and switches it.

import 'dart:async';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/discard_guard.dart';
import '../common/sheet_title_bar.dart';
import '../features/feature_kit.dart';
import '../providers/provider_widgets.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_home_page.dart' show plainPreviewLines;
import 'tavern_lorebooks_page.dart';
import 'tavern_widgets.dart';

/// Where picked persona pictures are kept: the app's own copy, so the persona
/// keeps its picture after the original moves. Outside the engine's folder.
Future<Directory> _avatarDir() async {
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}/tavern_avatars');
}

/// Picks a picture and copies it in. Null when nothing was picked.
Future<String?> _pickAvatar() async {
  final file = (await FilePicker.pickFiles(type: FileType.image)).firstOrNull;
  if (file == null) return null;
  final dir = await _avatarDir();
  await dir.create(recursive: true);
  final dot = file.name.lastIndexOf('.');
  final ext = dot < 0 ? 'png' : file.name.substring(dot + 1).toLowerCase();
  final out = File('${dir.path}/${DateTime.now().microsecondsSinceEpoch}.$ext');
  await out.writeAsBytes(await file.readAsBytes(), flush: true);
  return out.path;
}

/// Removes a picture this page copied in, once nothing points at it.
Future<void> _dropAvatar(String? path) async {
  if (path == null) return;
  try {
    final dir = await _avatarDir();
    if (File(path).parent.absolute.path == dir.absolute.path) await File(path).delete();
  } on Object {
    // Already gone, or not ours: nothing to tidy.
  }
}

/// A persona's round picture, or its first character.
class TavernPersonaAvatar extends StatelessWidget {
  const TavernPersonaAvatar({super.key, required this.name, this.path, this.size = 36});

  final String name;
  final String? path;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: TavernPortrait(name: name, path: path, radius: size / 2, initialSize: size * 0.42),
  );
}

// The list -------------------------------------------------------------------

class TavernPersonasPage extends ConsumerWidget {
  const TavernPersonasPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const TavernPersonasPage());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final personas = ref.watch(tavernPersonasProvider).value;
    final defaultId = ref.watch(tavernPersonaSelectionProvider(null)).value?.defaultPersonaId;
    void create() => unawaited(Navigator.of(context).push(TavernPersonaEditPage.route()));
    return AppPage.list(
      title: l10n.tavernPersonas,
      actions: [
        GlassIconButton(
          key: const ValueKey('tavern-persona-new'),
          icon: AppIcons.add,
          tooltip: l10n.tavernPersonaNew,
          onPressed: create,
        ),
      ],
      children: [
        if (personas == null)
          const QuietSpinner()
        else if (personas.isEmpty)
          EmptyView(
            icon: AppIcons.profile,
            title: l10n.tavernPersonasEmpty,
            message: l10n.tavernPersonasEmptyMessage,
            actionLabel: l10n.tavernPersonaNew,
            onAction: create,
          )
        else
          SettingsSection(
            footer: Text(l10n.tavernPersonasNote),
            children: [
              for (final p in personas)
                _PersonaRow(
                  key: ValueKey('tavern-persona-${p.id}'),
                  persona: p,
                  badge: p.id == defaultId ? l10n.commonDefault : null,
                  onTap: () => unawaited(Navigator.of(context).push(TavernPersonaEditPage.route(p))),
                  onLongPress: () => unawaited(
                    showTavernActions(context, [
                      if (p.id == defaultId)
                        (
                          AppIcons.profile,
                          l10n.tavernPersonaUnsetDefault,
                          () => unawaited(ref.read(tavernProvider).setDefaultPersona(null)),
                        )
                      else
                        (
                          AppIcons.profile,
                          l10n.tavernPersonaSetDefault,
                          () => unawaited(ref.read(tavernProvider).setDefaultPersona(p.id)),
                        ),
                      (AppIcons.delete, l10n.commonDelete, () => unawaited(deleteTavernPersona(context, ref, p))),
                    ]),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// Asks, then deletes [persona]; chats that used it go back to the default,
/// and what was already written stays. True when it was deleted.
Future<bool> deleteTavernPersona(BuildContext context, WidgetRef ref, TavernPersona persona) async {
  final l10n = context.l10n;
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l10n.tavernPersonaDeleteTitle(persona.name)),
      content: Text(l10n.tavernPersonaDeleteMessage),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(l10n.commonCancel)),
        TextButton(onPressed: () => Navigator.of(dialog).pop(true), child: Text(l10n.commonDelete)),
      ],
    ),
  );
  if (ok != true) return false;
  await ref.read(tavernProvider).deletePersona(persona.id);
  unawaited(_dropAvatar(persona.avatarPath));
  return true;
}

/// One persona in a list: its picture, name and first line, and what is
/// true of it at the end (默认, or a tick in the picker).
class _PersonaRow extends StatelessWidget {
  const _PersonaRow({
    super.key,
    required this.persona,
    required this.onTap,
    this.onLongPress,
    this.badge,
    this.trailing,
  });

  final TavernPersona persona;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final String? badge;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _AvatarRow(
      leading: TavernPersonaAvatar(name: persona.name, path: persona.avatarPath),
      title: persona.name,
      subtitle: plainPreviewLines(persona.description, 1),
      onTap: onTap,
      onLongPress: onLongPress,
      trailing: switch (badge) {
        final badge? => Text(badge, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
        null => trailing,
      },
    );
  }
}

/// A settings-height row led by a 36 round picture, so persona rows and the
/// 跟随默认 row line up.
class _AvatarRow extends StatelessWidget {
  const _AvatarRow({
    super.key,
    required this.leading,
    required this.title,
    required this.onTap,
    this.subtitle = '',
    this.onLongPress,
    this.trailing,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      splashFactory: rowSplash(context),
      highlightColor: theme.colorScheme.onSurface.withValues(alpha: 0.05),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: SettingsMetrics.rowHeightTwoLine),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: SettingsMetrics.inset, vertical: 10),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                      ),
                  ],
                ),
              ),
              if (trailing case final trailing?) ...[const SizedBox(width: 8), trailing],
            ],
          ),
        ),
      ),
    );
  }
}

// The editor -----------------------------------------------------------------

class TavernPersonaEditPage extends ConsumerStatefulWidget {
  const TavernPersonaEditPage({super.key, this.persona});

  /// Null for a new persona.
  final TavernPersona? persona;

  static Route<void> route([TavernPersona? persona]) =>
      MaterialPageRoute<void>(builder: (_) => TavernPersonaEditPage(persona: persona));

  @override
  ConsumerState<TavernPersonaEditPage> createState() => _TavernPersonaEditPageState();
}

class _TavernPersonaEditPageState extends ConsumerState<TavernPersonaEditPage> {
  late final _name = TextEditingController(text: widget.persona?.name ?? '');
  late final _description = TextEditingController(text: widget.persona?.description ?? '');
  late String? _avatar = widget.persona?.avatarPath;

  /// Whether it is (to be) the default; null until the selection is read.
  bool? _default;
  bool? _wasDefault;
  bool _saving = false;
  String? _nameError;
  String? _error;

  /// Pictures picked on this page and not kept: removed when it closes.
  final _picked = <String>{};

  late final _edits = Listenable.merge([_name, _description]);

  @override
  void initState() {
    super.initState();
    _name.addListener(() {
      if (_nameError != null && _name.text.trim().isNotEmpty) setState(() => _nameError = null);
    });
    unawaited(_readDefault());
  }

  Future<void> _readDefault() async {
    final selection = await ref.read(tavernProvider).personaSelection();
    if (!mounted) return;
    final current = selection.defaultPersonaId;
    setState(() {
      _wasDefault = widget.persona != null && current == widget.persona!.id;
      // The first persona becomes the default unless you say otherwise.
      _default = _wasDefault! || (widget.persona == null && current == null);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    for (final path in _picked) {
      unawaited(_dropAvatar(path));
    }
    super.dispose();
  }

  bool _dirty() {
    if (_saving) return false;
    final p = widget.persona;
    if (p == null) return _name.text.trim().isNotEmpty || _description.text.isNotEmpty || _avatar != null;
    return _name.text != p.name ||
        _description.text != p.description ||
        _avatar != p.avatarPath ||
        (_default != null && _default != _wasDefault);
  }

  Future<void> _changeAvatar() async {
    final l10n = context.l10n;
    final remove =
        _avatar != null &&
        await showAppSheet<bool>(
              context,
              builder: (sheet) => SafeArea(
                top: false,
                child: SheetGroup(
                  margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                  children: [
                    SettingsTile(
                      icon: AppIcons.image,
                      tinted: false,
                      title: l10n.tavernPersonaPickAvatar,
                      onTap: () => Navigator.of(sheet).pop(false),
                    ),
                    SettingsTile(
                      icon: AppIcons.delete,
                      tinted: false,
                      danger: true,
                      title: l10n.tavernPersonaRemoveAvatar,
                      onTap: () => Navigator.of(sheet).pop(true),
                    ),
                  ],
                ),
              ),
            ) ==
            true;
    if (!mounted) return;
    if (remove) return setState(() => _avatar = null);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await _pickAvatar();
      if (path == null || !mounted) return;
      _picked.add(path);
      setState(() => _avatar = path);
    } on Object {
      messenger.showSnackBar(SnackBar(content: Text(l10n.tavernPersonaAvatarFailed)));
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final l10n = context.l10n;
    if (_name.text.trim().isEmpty) return setState(() => _nameError = l10n.tavernNameNeeded);
    final navigator = Navigator.of(context);
    final tavern = ref.read(tavernProvider);
    final old = widget.persona;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final TavernPersona saved;
      if (old == null) {
        saved = await tavern.createPersona(name: _name.text, description: _description.text, avatarPath: _avatar);
      } else {
        saved = await tavern.updatePersona(
          old.id,
          name: _name.text == old.name ? null : _name.text,
          description: _description.text == old.description ? null : _description.text,
          avatarPath: _avatar != old.avatarPath ? _avatar : null,
          clearAvatar: _avatar == null && old.avatarPath != null,
        );
      }
      if (_default case final makeDefault? when makeDefault != _wasDefault) {
        await tavern.setDefaultPersona(makeDefault ? saved.id : null);
      }
    } on Object {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = l10n.commonSaveFailedRetry;
        });
      }
      return;
    }
    // Kept now: not tidied away when the page closes. The one it replaced is.
    _picked.remove(_avatar);
    if (old?.avatarPath case final previous? when previous != _avatar) unawaited(_dropAvatar(previous));
    if (mounted) navigator.pop();
  }

  Future<void> _delete() async {
    final persona = widget.persona;
    if (persona == null) return;
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    if (await deleteTavernPersona(context, ref, persona)) {
      if (mounted) navigator.pop();
    } else if (mounted) {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final enabled = !_saving;
    final editing = widget.persona != null;
    final body = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
        child: Center(
          child: Semantics(
            button: true,
            label: l10n.tavernPersonaPickAvatar,
            child: GestureDetector(
              key: const ValueKey('tavern-persona-avatar'),
              onTap: enabled ? () => unawaited(_changeAvatar()) : null,
              child: ListenableBuilder(
                listenable: _name,
                builder: (context, _) => Stack(
                  clipBehavior: Clip.none,
                  children: [
                    TavernPersonaAvatar(name: _name.text, path: _avatar, size: 88),
                    // Says the picture can be changed.
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          shape: BoxShape.circle,
                          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                        ),
                        child: Icon(AppIcons.image, size: 16, color: Theme.of(context).colorScheme.onSurface),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      SettingsSection(
        children: [
          FormFieldGroup(
            children: [
              FormFieldBlock(
                key: const ValueKey('tavern-persona-name'),
                label: l10n.tavernFieldName,
                error: _nameError,
                child: TextField(
                  controller: _name,
                  enabled: enabled,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    hintText: l10n.tavernPersonaNameHint,
                    error: _nameError == null ? null : const SizedBox.shrink(),
                  ),
                ),
              ),
              FormFieldBlock(
                key: const ValueKey('tavern-persona-description'),
                label: l10n.tavernFieldDescription,
                helper: l10n.tavernPersonaDescriptionHelp,
                child: TextField(
                  controller: _description,
                  enabled: enabled,
                  minLines: 4,
                  maxLines: 14,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(hintText: l10n.tavernPersonaDescriptionHint),
                ),
              ),
            ],
          ),
        ],
      ),
      SettingsSection(
        children: [
          SettingsSwitchTile(
            key: const ValueKey('tavern-persona-default'),
            icon: AppIcons.profile,
            title: l10n.tavernPersonaSetDefault,
            subtitle: l10n.tavernPersonaDefaultSubtitle,
            value: _default ?? false,
            onChanged: enabled && _default != null ? (on) => setState(() => _default = on) : null,
          ),
          // Saved as it changes, as the picker says; only once the persona exists.
          if (widget.persona case final persona?)
            TavernLorebookBindingTile(
              key: const ValueKey('tavern-persona-lorebooks'),
              scope: (source: WorldInfoSource.persona, id: persona.id),
              title: l10n.tavernLorebooksBound,
              subtitle: l10n.tavernLorebooksBoundPersona,
              sheetTitle: l10n.tavernLorebookForPersona(persona.name),
              note: l10n.tavernLorebookPersonaNote,
              enabled: enabled,
            ),
        ],
      ),
      if (editing)
        SettingsSection(
          children: [
            SettingsTile(
              key: const ValueKey('tavern-persona-delete'),
              icon: AppIcons.delete,
              danger: true,
              tinted: false,
              title: l10n.tavernPersonaDelete,
              chevron: false,
              onTap: enabled ? () => unawaited(_delete()) : null,
            ),
          ],
        ),
      if (_error case final error?)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Text(
            error,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).danger),
          ),
        ),
      const SizedBox(height: FormBottomBar.height),
    ];
    return DiscardGuard(
      listenable: _edits,
      isDirty: _dirty,
      child: Stack(
        children: [
          AppPage.list(
            title: editing ? l10n.tavernPersonaEdit : l10n.tavernPersonaNew,
            children: [Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body)],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: FormBottomBar(
              child: FilledButton(
                key: const ValueKey('tavern-persona-save'),
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

// In a chat --------------------------------------------------------------------

/// The composer's left key: who you are in this chat. Tapping it switches.
/// Off while a reply is being written (switching would stop it).
class TavernPersonaKey extends ConsumerWidget {
  const TavernPersonaKey({super.key, required this.chatId, this.enabled = true});

  final String chatId;
  final bool enabled;

  static const size = 36.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final persona = ref.watch(tavernPersonaSelectionProvider(chatId)).value?.persona;
    final label = persona == null ? l10n.tavernPersonaNone : l10n.tavernPersonaAs(persona.name);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Tooltip(
        message: label,
        child: InkResponse(
          key: const ValueKey('tavern-persona-key'),
          onTap: enabled ? () => unawaited(showTavernPersonaPicker(context, chatId)) : null,
          radius: 22,
          child: AnimatedOpacity(
            opacity: enabled ? 1 : 0.38,
            duration: AppMotion.of(context, AppMotion.quick),
            child: persona == null
                ? Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(color: scheme.onSurface.withValues(alpha: 0.06), shape: BoxShape.circle),
                    child: Icon(AppIcons.profile, size: 20, color: scheme.onSurface),
                  )
                : TavernPersonaAvatar(name: persona.name, path: persona.avatarPath, size: size),
          ),
        ),
      ),
    );
  }
}

/// Picks who you are in [chatId]: the default, or one persona for this chat.
/// Takes effect from the next message.
Future<void> showTavernPersonaPicker(BuildContext context, String chatId) => showAppSheet<void>(
  context,
  builder: (sheet) => Consumer(
    builder: (inner, ref, _) {
      final l10n = inner.l10n;
      final personas = ref.watch(tavernPersonasProvider).value ?? const <TavernPersona>[];
      final selection = ref.watch(tavernPersonaSelectionProvider(chatId)).value;
      final bound = selection?.boundPersonaId;
      final fallback = personas.where((p) => p.id == selection?.defaultPersonaId).firstOrNull;
      void bind(String? id) {
        Navigator.of(sheet).pop();
        if (id != bound) unawaited(ref.read(tavernProvider).bindPersona(chatId, id));
      }

      Widget? tick(bool on) =>
          on ? Icon(AppIcons.selected, size: 18, color: Theme.of(inner).colorScheme.primary) : null;
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.tavernPersonaForChat),
            Flexible(
              child: SingleChildScrollView(
                child: SheetGroup(
                  margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                  children: [
                    _AvatarRow(
                      key: const ValueKey('tavern-persona-follow'),
                      leading: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: Theme.of(inner).colorScheme.onSurface.withValues(alpha: 0.06),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(AppIcons.restart, size: 18, color: Theme.of(inner).colorScheme.onSurface),
                      ),
                      title: l10n.tavernPersonaFollowDefault,
                      subtitle: fallback?.name ?? l10n.tavernPersonaNone,
                      trailing: tick(bound == null),
                      onTap: () => bind(null),
                    ),
                    for (final p in personas)
                      _PersonaRow(
                        key: ValueKey('tavern-persona-pick-${p.id}'),
                        persona: p,
                        trailing: tick(bound == p.id),
                        onTap: () => bind(p.id),
                      ),
                  ],
                ),
              ),
            ),
            SheetGroup(
              margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
              children: [
                SettingsTile(
                  key: const ValueKey('tavern-persona-manage'),
                  icon: AppIcons.edit,
                  tinted: false,
                  title: l10n.tavernPersonasManage,
                  onTap: () {
                    Navigator.of(sheet).pop();
                    unawaited(Navigator.of(context).push(TavernPersonasPage.route()));
                  },
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
        ),
      );
    },
  ),
);
