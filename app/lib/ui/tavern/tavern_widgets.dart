// Pieces the tavern's pages share: a character's picture, importing a card,
// deleting with a confirmation, and the long-press action sheet.

import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_backgrounds.dart';
import '../../tavern/tavern_card_sites.dart';
import '../../tavern/tavern_live2d.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_session_usage.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_deepseek_import.dart';
import 'tavern_import_files.dart';

/// The card picture, or — for a card without one — a quiet field in the
/// theme's container colour with the name's first character.
class TavernPortrait extends StatelessWidget {
  const TavernPortrait({super.key, required this.name, this.path, this.radius = AppShape.lg, this.initialSize = 40});

  final String name;
  final String? path;
  final double radius;
  final double initialSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final file = path;
    final Widget body = file != null
        ? LayoutBuilder(
            builder: (context, box) {
              // Decoded near the size it is drawn at: a card's picture is
              // often 1–2k pixels, and a whole shelf of them at full size
              // overflows the image cache. Twice the box's longer side, so a
              // picture up to 2:1 the other way still covers it unblurred.
              final sides = [box.maxWidth, box.maxHeight].where((d) => d.isFinite);
              final side = sides.isEmpty ? double.infinity : sides.reduce(max) * 2;
              final ImageProvider picture = side.isFinite
                  ? ResizeImage(
                      FileImage(File(file)),
                      width: (side * MediaQuery.devicePixelRatioOf(context)).ceil(),
                      height: (side * MediaQuery.devicePixelRatioOf(context)).ceil(),
                      policy: ResizeImagePolicy.fit,
                    )
                  : FileImage(File(file));
              return Image(
                image: picture,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _initial(context),
              );
            },
          )
        : _initial(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ColoredBox(color: scheme.surfaceContainerHighest, child: body),
    );
  }

  Widget _initial(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = name.characters.isEmpty ? '?' : name.characters.first;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primaryContainer, scheme.surfaceContainerHighest],
        ),
      ),
      child: Center(
        child: Text(
          initial,
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(fontSize: initialSize, color: scheme.onPrimaryContainer.withValues(alpha: 0.7)),
        ),
      ),
    );
  }
}

/// Asks, then deletes [character] and its chats. True when it was deleted.
Future<bool> deleteTavernCharacter(BuildContext context, WidgetRef ref, TavernCharacter character) async {
  final l10n = context.l10n;
  final ok = await _confirmDelete(
    context,
    title: l10n.tavernDeleteCharacterTitle(character.name),
    message: l10n.tavernDeleteCharacterMessage,
  );
  if (!ok) return false;
  await _deleteCharacters(ref, [character]);
  return true;
}

/// Asks once, then deletes [characters] and their chats. True when they
/// were deleted.
Future<bool> deleteTavernCharacters(BuildContext context, WidgetRef ref, List<TavernCharacter> characters) async {
  if (characters.isEmpty) return false;
  if (characters.length == 1) return deleteTavernCharacter(context, ref, characters.single);
  final l10n = context.l10n;
  final ok = await _confirmDelete(
    context,
    title: l10n.tavernDeleteCharactersTitle(characters.length),
    message: l10n.tavernDeleteCharacterMessage,
  );
  if (!ok) return false;
  await _deleteCharacters(ref, characters);
  return true;
}

/// Deletes [characters] from the tavern first, all of them, then lets their
/// files go: a slow file never holds a character back.
Future<void> _deleteCharacters(WidgetRef ref, List<TavernCharacter> characters) async {
  final tavern = ref.read(tavernProvider);
  final live2d = ref.read(tavernLive2dRootProvider);
  final chats = <TavernChatSummary>[];
  for (final character in characters) {
    // Its chats go with it, and so do their pictures.
    // Never held up by it: without the list, the pictures just stay.
    chats.addAll(
      await tavern
          .watchChats(characterId: character.id)
          .first
          .timeout(const Duration(seconds: 3))
          .catchError((_) => <TavernChatSummary>[]),
    );
    await tavern.deleteCharacter(character.id);
  }
  for (final chat in chats) {
    await forgetTavernBackground(chat.id);
  }
  for (final character in characters) {
    await forgetTavernLive2d(live2d, character.id);
  }
}

/// Asks, then deletes one chat. True when it was deleted.
Future<bool> deleteTavernChat(BuildContext context, WidgetRef ref, String chatId) async {
  final l10n = context.l10n;
  final ok = await _confirmDelete(context, title: l10n.tavernDeleteChatTitle, message: l10n.tavernDeleteChatMessage);
  if (!ok) return false;
  await ref.read(tavernProvider).deleteChat(chatId);
  await forgetTavernBackground(chatId);
  return true;
}

/// Asks before something is deleted (or replaced) for good. True to go ahead.
/// [action] names the button; 删除 unless given.
Future<bool> confirmTavernDelete(
  BuildContext context, {
  required String title,
  required String message,
  String? action,
}) => _confirmDelete(context, title: title, message: message, action: action);

Future<bool> _confirmDelete(
  BuildContext context, {
  required String title,
  required String message,
  String? action,
}) async {
  final l10n = context.l10n;
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.commonCancel)),
        TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(action ?? l10n.commonDelete)),
      ],
    ),
  );
  return ok == true;
}

/// A one-row sheet of actions on something the person long-pressed.
Future<void> showTavernActions(BuildContext context, List<(IconData, String, VoidCallback)> actions) =>
    showAppSheet<void>(
      context,
      builder: (sheet) => SafeArea(
        top: false,
        child: SheetGroup(
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          children: [
            for (final (icon, title, onTap) in actions)
              SettingsTile(
                icon: icon,
                tinted: false,
                danger: icon == AppIcons.delete,
                title: title,
                onTap: () {
                  Navigator.of(sheet).pop();
                  onTap();
                },
              ),
          ],
        ),
      ),
    );

/// Our own sample card (assets/tavern), written for DSH Go: two greetings,
/// example lines and a small lorebook to try the tavern with.
const tavernSampleCardAsset = 'assets/tavern/sample_innkeeper.json';

/// Imports the sample card; says how it went. Returns the character, or null.
Future<TavernCharacter?> importSampleTavernCard(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final data = await rootBundle.load(tavernSampleCardAsset);
    final character = await ref
        .read(tavernProvider)
        .importCard(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), fileName: 'sample_innkeeper.json');
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernImported(character.name))));
    return character;
  } on Object {
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernImportFailed)));
    return null;
  }
}

/// Downloads cards from links. Tests swap it.
final tavernHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

enum _ImportFrom { file, link, deepSeek, blank }

/// 导入: from a file, from a link to a card file, or a blank card of your
/// own. Returns the character so the caller can open it ([blank]: open it
/// for writing).
Future<({TavernCharacter character, bool blank})?> showTavernImport(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final from = await showAppSheet<_ImportFrom>(
    context,
    builder: (sheet) => SafeArea(
      top: false,
      // Four ways in: on a short screen they scroll rather than run off it.
      child: SingleChildScrollView(
        child: SheetGroup(
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          children: [
            SettingsTile(
              key: const ValueKey('tavern-import-file'),
              icon: AppIcons.files,
              tinted: false,
              title: l10n.tavernImportFromFile,
              subtitle: l10n.tavernImportFromFileSubtitle,
              chevron: false,
              onTap: () => Navigator.of(sheet).pop(_ImportFrom.file),
            ),
            SettingsTile(
              key: const ValueKey('tavern-import-link'),
              icon: AppIcons.link,
              tinted: false,
              title: l10n.tavernImportFromLink,
              subtitle: l10n.tavernImportFromLinkSubtitle,
              chevron: false,
              onTap: () => Navigator.of(sheet).pop(_ImportFrom.link),
            ),
            SettingsTile(
              key: const ValueKey('tavern-import-deepseek'),
              icon: AppIcons.history,
              tinted: false,
              title: l10n.tavernImportFromDeepSeek,
              subtitle: l10n.tavernImportFromDeepSeekSubtitle,
              chevron: false,
              onTap: () => Navigator.of(sheet).pop(_ImportFrom.deepSeek),
            ),
            SettingsTile(
              key: const ValueKey('tavern-import-blank'),
              icon: AppIcons.edit,
              tinted: false,
              title: l10n.tavernWriteOwn,
              subtitle: l10n.tavernWriteOwnSubtitle,
              chevron: false,
              onTap: () => Navigator.of(sheet).pop(_ImportFrom.blank),
            ),
          ],
        ),
      ),
    ),
  );
  if (from == null || !context.mounted) return null;
  // A conversation carried over opens as a chat, not as a card's page.
  if (from == _ImportFrom.deepSeek) {
    await takeInDeepSeekExport(context, ref);
    return null;
  }
  final character = await switch (from) {
    _ImportFrom.file => importTavernFiles(context, ref),
    _ImportFrom.link => importTavernCardFromLink(context, ref),
    _ImportFrom.deepSeek => null,
    _ImportFrom.blank => createBlankTavernCharacter(context, ref),
  };
  return character == null ? null : (character: character, blank: from == _ImportFrom.blank);
}

/// A character of your own: a blank V2 card (only its name, 新角色), taken
/// in as any card is, for you to write. Null when it couldn't be.
Future<TavernCharacter?> createBlankTavernCharacter(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final card = {
    'spec': 'chara_card_v2',
    'spec_version': '2.0',
    'data': {
      'name': l10n.tavernNewCharacterName,
      'description': '',
      'personality': '',
      'scenario': '',
      'first_mes': '',
      'mes_example': '',
      'creator_notes': '',
      'system_prompt': '',
      'post_history_instructions': '',
      'alternate_greetings': <String>[],
      'tags': <String>[],
      'creator': '',
      'character_version': '',
      'extensions': <String, Object?>{},
    },
  };
  try {
    return await ref
        .read(tavernProvider)
        .importCard(Uint8List.fromList(utf8.encode(jsonEncode(card))), fileName: 'new_character.json');
  } on Object {
    messenger?.showSnackBar(SnackBar(content: Text(l10n.tavernImportFailed)));
    return null;
  }
}

/// Asks for a link to a card file (PNG, JSON or CHARX), downloads it and
/// imports it; says how it went. A link already on the clipboard is filled in.
Future<TavernCharacter?> importTavernCardFromLink(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final client = ref.read(tavernHttpClientProvider);
  final tavern = ref.read(tavernProvider);
  // Only a convenience: never wait long on the clipboard.
  final clip = await Clipboard.getData(Clipboard.kTextPlain)
      .timeout(const Duration(milliseconds: 500), onTimeout: () => null)
      .catchError((Object _) => null);
  final copied = clip?.text?.trim() ?? '';
  if (!context.mounted) return null;
  final link = await showAppDialog<String>(
    context: context,
    builder: (_) => _LinkDialog(initial: copied.startsWith(RegExp('https?://')) ? copied : ''),
  );
  if (link == null || link.trim().isEmpty) return null;
  // A site's address typed without its scheme, like chub.ai/characters/…, is https.
  final typed = link.trim();
  final uri = Uri.tryParse(
    RegExp(r'^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(/\S*)?$').hasMatch(typed) ? 'https://$typed' : typed,
  );
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernLinkInvalid)));
    return null;
  }
  final Uint8List bytes;
  final String name;
  // A character page on a site the App knows goes through its download.
  if (tavernCardSiteOf(uri) case final page?) {
    try {
      (:bytes, fileName: name) = await downloadTavernSiteCard(client, page).timeout(const Duration(seconds: 60));
    } on TavernCardSiteError catch (e) {
      final status = e.status;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            status == 404
                ? l10n.tavernLinkSiteMissing
                : status != null
                ? l10n.tavernLinkStatus(status)
                : l10n.tavernImportFailed,
          ),
        ),
      );
      return null;
    } on Object {
      messenger.showSnackBar(SnackBar(content: Text(l10n.tavernLinkFailed)));
      return null;
    }
  } else {
    final http.Response response;
    try {
      response = await client.get(uri).timeout(const Duration(seconds: 60));
    } on Object {
      messenger.showSnackBar(SnackBar(content: Text(l10n.tavernLinkFailed)));
      return null;
    }
    if (response.statusCode != 200) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.tavernLinkStatus(response.statusCode))));
      return null;
    }
    // A page rather than the card file itself.
    if ((response.headers['content-type'] ?? '').contains('text/html')) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.tavernLinkIsPage)));
      return null;
    }
    bytes = response.bodyBytes;
    name = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? 'card';
  }
  try {
    final character = await tavern.importCard(bytes, fileName: name);
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernImported(character.name))));
    return character;
  } on TavernImportError catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.isLorebook ? l10n.tavernImportLorebook : l10n.tavernImportFailed)));
  } on Object {
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernImportFailed)));
  }
  return null;
}

/// Hands a card file to the system share sheet (save to Files, send to a
/// chat, open in another tavern): written into the app cache first, as the
/// diagnostics bundle is. Tests swap it.
final tavernCardSinkProvider = Provider<Future<void> Function(String name, Uint8List bytes, String mime)>(
  (ref) => (name, bytes, mime) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/tavern_export');
    await dir.create(recursive: true);
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: mime, name: name)],
        fileNameOverrides: [name],
      ),
    );
  },
);

/// Hands several card files to the share sheet at once, as
/// [tavernCardSinkProvider] does one. Tests swap it.
final tavernCardsSinkProvider = Provider<Future<void> Function(List<(String name, Uint8List bytes)> files)>(
  (ref) => (files) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/tavern_export');
    await dir.create(recursive: true);
    final shared = <XFile>[];
    for (final (name, bytes) in files) {
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes, flush: true);
      shared.add(XFile(file.path, mimeType: 'image/png', name: name));
    }
    await SharePlus.instance.share(
      ShareParams(files: shared, fileNameOverrides: [for (final (name, _) in files) name]),
    );
  },
);

/// Exports [characters] as PNG cards and shares them together; two of one
/// name get a number.
Future<void> shareTavernCards(BuildContext context, WidgetRef ref, List<TavernCharacter> characters) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final sink = ref.read(tavernCardsSinkProvider);
  try {
    final tavern = ref.read(tavernProvider);
    final used = <String>{};
    final files = <(String, Uint8List)>[];
    for (final character in characters) {
      var name = tavernCardFileName(character.name, TavernCardFormat.png);
      for (var n = 2; !used.add(name); n++) {
        name = tavernCardFileName('${character.name} $n', TavernCardFormat.png);
      }
      files.add((name, await tavern.exportCard(character.id)));
    }
    await sink(files);
  } on Object {
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernExportFailed)));
  }
}

/// A file name from a character's name: no path or reserved characters.
String tavernCardFileName(String name, TavernCardFormat format) {
  final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
  return '${safe.isEmpty ? 'character' : safe}.${format.name}';
}

/// Exports [character] as a card in [format] and shares it.
Future<void> shareTavernCard(
  BuildContext context,
  WidgetRef ref,
  TavernCharacter character,
  TavernCardFormat format,
) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final sink = ref.read(tavernCardSinkProvider);
  try {
    final bytes = await ref.read(tavernProvider).exportCard(character.id, format: format);
    final mime = switch (format) {
      TavernCardFormat.png => 'image/png',
      TavernCardFormat.json => 'application/json',
      TavernCardFormat.charx => 'application/zip',
    };
    await sink(tavernCardFileName(character.name, format), bytes, mime);
  } on Object {
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernExportFailed)));
  }
}

/// Asks for a card file's link; owns its field, so it is let go with the route.
class _LinkDialog extends StatefulWidget {
  const _LinkDialog({required this.initial});

  final String initial;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.tavernImportFromLink),
      content: TextField(
        key: const ValueKey('tavern-link-field'),
        controller: _field,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(hintText: 'chub.ai/characters/…'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        TextButton(
          key: const ValueKey('tavern-link-go'),
          onPressed: () => Navigator.of(context).pop(_field.text),
          child: Text(l10n.tavernImport),
        ),
      ],
    );
  }
}

/// A figure at a glance: a small label over a number (舞台 › 本回合, 用量).
class TavernFigure extends StatelessWidget {
  const TavernFigure({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: GlassSurface(
        tier: GlassTier.card,
        borderRadius: AppShape.radiusMd,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Column(
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: DshColors.of(context).textTertiary),
            ),
            const SizedBox(height: 4),
            Text(value, style: AppType.tabular(theme.textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w600))),
          ],
        ),
      ),
    );
  }
}

/// [usd], a reply's or a chat's estimated cost, as it reads: about
/// US$0.0065; under US$0.0001 when four places would show nothing.
String tavernCostLabel(L10n l10n, double usd) =>
    usd < 0.0001 ? l10n.tavernUsageCostUnder('US\$0.0001') : l10n.tavernUsageCost('US\$${tavernUsd(usd)}');
