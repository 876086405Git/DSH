// Character cards arriving from the rest of the phone: a `.charx` opened with
// the app, or a lone card shared to it (a PNG with a `chara` / `ccv3` text
// chunk, a CHARX, a card JSON). They are imported into 酒馆 and open their
// page instead of landing in a new conversation (system_entry_host.dart asks
// [isTavernCardFile] first).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../links/app_links.dart';
import '../../tavern/tavern_file_kind.dart';
import '../../tavern/tavern_provider.dart';
import 'tavern_character_page.dart';

/// Whether [file] (named [name] by its sender) is a character card. Reads the
/// file; cards are a few MB at most.
Future<bool> isTavernCardFile(File file, String name) async {
  final lower = name.toLowerCase();
  if (lower.endsWith('.charx')) return true;
  if (!lower.endsWith('.png') && !lower.endsWith('.json')) return false;
  try {
    final bytes = await file.readAsBytes();
    if (lower.endsWith('.png')) return tavernPngIsCard(bytes);
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map) return false;
    final spec = json['spec'];
    return spec is String && spec.startsWith('chara_card_v') || json.containsKey('first_mes');
  } catch (_) {
    return false;
  }
}

/// Imports the card in [file] and opens its page; says when it couldn't.
Future<void> openTavernCardFile(BuildContext context, WidgetRef ref, File file, String name) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final navigator = Navigator.of(context);
  try {
    final character = await ref.read(tavernProvider).importCard(await file.readAsBytes(), fileName: name);
    messenger?.showSnackBar(SnackBar(content: Text(l10n.tavernImported(character.name))));
    unawaited(navigator.push(TavernCharacterPage.route(character.id)));
  } on TavernImportError catch (e) {
    messenger?.showSnackBar(
      SnackBar(content: Text(e.isLorebook ? l10n.tavernImportLorebook : l10n.tavernImportFailed)),
    );
  } catch (_) {
    messenger?.showSnackBar(SnackBar(content: Text(l10n.tavernImportFailed)));
  }
}

/// Draws nothing. Takes `.charx` files opened with the app (the link router's
/// file route). Put it once in the home shell's stack, next to the other hosts.
class TavernIntakeHost extends ConsumerStatefulWidget {
  const TavernIntakeHost({super.key});

  @override
  ConsumerState<TavernIntakeHost> createState() => _TavernIntakeHostState();
}

class _TavernIntakeHostState extends ConsumerState<TavernIntakeHost> {
  VoidCallback? _off;

  @override
  void initState() {
    super.initState();
    _off = ref.read(linkRouterProvider).registerFileHandler('charx', _file);
  }

  Future<bool> _file(Uri uri) async {
    final ui = ref.read(linkRouterProvider).context ?? (mounted ? context : null);
    if (ui == null || !ui.mounted) return false;
    final file = File(uri.toFilePath());
    await openTavernCardFile(ui, ref, file, file.uri.pathSegments.last);
    return true;
  }

  @override
  void dispose() {
    _off?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
