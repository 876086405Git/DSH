// Picks the pet (Deepy 小鲸鱼, 鲸娘, the ones you brought, 不显示) with live
// previews, for 宠物设置 and the pet's long-press menu. Same grid as the other
// pickers on the 主题 page (PickerGrid: 16 in, 12 apart, label 8 under), three
// to a row. 宠物设置 adds 导入 (a pack zip, pet_library.dart); a brought pet
// is removed with a long press.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../l10n/l10n.dart';
import '../../pets/pet_library.dart';
import '../../pets/pet_pack.dart';
import '../../pets/pet_prefs.dart';
import '../../pets/pet_signals.dart';
import '../../pets/pet_state.dart';
import '../bots/bot_sheets.dart' show confirmDelete;
import '../common/pressable.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'pet_sprite.dart';

/// Names for the picker before a pack has loaded (and for 不显示).
Map<String, String> get petNames => {
  'deepy-whale': appL10n.botsPetDeepy,
  'whale-girl': appL10n.botsPetWhaleGirl,
  'pink-fish': appL10n.botsPetPinkFish,
  noPetId: appL10n.botsPetNone,
};

/// Picks a pack zip: a file the importer can read. Null when cancelled.
final petPackPickerProvider = Provider<Future<File?> Function()>(
  (ref) => () async {
    final picked = await FilePicker.pickFile();
    if (picked == null) return null;
    // Picks may be content URIs: bring it somewhere the unzipper can seek.
    final temp = File(
      '${(await getTemporaryDirectory()).path}/pet-import-${DateTime.now().microsecondsSinceEpoch}.zip',
    );
    final sink = temp.openWrite();
    try {
      await sink.addStream(picked.readAsByteStream());
    } finally {
      await sink.close();
    }
    return temp;
  },
);

/// What went wrong with a pack, in words.
String petImportProblemText(L10n l10n, PetImportException error) => switch (error.problem) {
  PetImportProblem.notAZip => l10n.botsPetImportNotZip,
  PetImportProblem.noPack => l10n.botsPetImportNoPack,
  PetImportProblem.badPack => l10n.botsPetImportBadPack(error.detail ?? ''),
  PetImportProblem.missingSheet => l10n.botsPetImportMissingSheet(error.detail ?? ''),
  PetImportProblem.badSheet => l10n.botsPetImportBadSheet(error.detail ?? ''),
  PetImportProblem.tooLarge => l10n.botsPetImportTooLarge,
  PetImportProblem.storage => l10n.botsPetImportStorage,
};

/// Three previews in a row, the chosen one ringed in the accent:
///
/// ```
/// ╭────────╮  ╭────────╮  ╭────────╮
/// │  🐋    │  │  👧    │  │        │   the pet standing on a little capsule
/// │ ▔▔▔▔▔▔ │  │ ▔▔▔▔▔▔ │  │ ▔▔▔▔▔▔ │
/// ╰────────╯  ╰────────╯  ╰────────╯
///  Deepy 小鲸鱼   鲸娘       不显示
/// ```
class PetPicker extends ConsumerStatefulWidget {
  const PetPicker({super.key, this.padding = const EdgeInsets.all(16), this.onPicked, this.importable = false});

  final EdgeInsetsGeometry padding;

  /// After a choice (the menu's sheet closes).
  final ValueChanged<String>? onPicked;

  /// Offers 导入 after the pets (宠物设置; the menu's quick swap doesn't).
  final bool importable;

  static const gap = 12.0;
  static const ring = 2.0;

  /// The capsule the preview pet stands on: its top at this share of the side.
  static const perchAt = 0.74;

  /// The preview pet's body height, as a share of the side.
  static const bodyShare = 0.34;

  /// Previews in a row.
  static const perRow = 3;

  @override
  ConsumerState<PetPicker> createState() => _PetPickerState();
}

class _PetPickerState extends ConsumerState<PetPicker> {
  bool _importing = false;

  void _pick(String id) {
    unawaited(ref.read(petPrefsProvider.notifier).setPack(id));
    widget.onPicked?.call(id);
  }

  Future<void> _import() async {
    if (_importing) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    File? zip;
    setState(() => _importing = true);
    try {
      zip = await ref.read(petPackPickerProvider)();
      if (zip == null || !mounted) return;
      final (:pack, :replaced) = await ref.read(userPetsProvider.notifier).import(zip);
      if (!mounted) return;
      _pick(pack.id);
      messenger?.showSnackBar(
        SnackBar(content: Text(replaced ? l10n.botsPetImportReplaced(pack.name) : l10n.botsPetImportDone(pack.name))),
      );
      // Brought over from a Codex pet: what doesn't carry over exactly, said once.
      final warnings = codexImportWarnings(pack);
      if (warnings.isNotEmpty && mounted) await _showCodexWarnings(pack, warnings);
    } on PetImportException catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text(petImportProblemText(l10n, error))));
    } on Object {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.botsPetImportStorage)));
    } finally {
      if (zip != null) unawaited(zip.delete().then((_) {}, onError: (_) {}));
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _showCodexWarnings(PetPack pack, List<String> warnings) => showDialog<void>(
    context: context,
    builder: (dialog) {
      final l10n = dialog.l10n;
      final theme = Theme.of(dialog);
      return AlertDialog(
        title: Text(l10n.botsPetCodexTitle(pack.name)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.botsPetCodexBody, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 12),
              for (final code in warnings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('· ${codexWarningText(l10n, code)}', style: theme.textTheme.bodyMedium),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(l10n.botsPetCodexOk))],
      );
    },
  );

  Future<void> _remove(PetPack pack) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await confirmDelete(context, title: l10n.botsPetRemoveTitle(pack.name), body: l10n.botsPetRemoveBody);
    if (!ok || !mounted) return;
    try {
      // On failure the pet stays, chosen again if it was (UserPetsController.remove).
      await ref.read(userPetsProvider.notifier).remove(pack.id);
    } on Object {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.botsPetRemoveFailed(pack.name))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(petPrefsProvider.select((p) => p.packId));
    final brought = ref.watch(userPetsProvider).value ?? const <PetPack>[];
    final tiles = <Widget>[
      for (final id in builtInPets) _Option(id: id, selected: id == selected, onTap: () => _pick(id)),
      for (final pack in brought)
        _Option(
          id: pack.id,
          selected: pack.id == selected,
          onTap: () => _pick(pack.id),
          onLongPress: () => unawaited(_remove(pack)),
        ),
      _Option(id: noPetId, selected: selected == noPetId, onTap: () => _pick(noPetId)),
      if (widget.importable) _ImportOption(busy: _importing, onTap: () => unawaited(_import())),
    ];
    const perRow = PetPicker.perRow;
    return Padding(
      padding: widget.padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var start = 0; start < tiles.length; start += perRow) ...[
            if (start > 0) const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = start; i < start + perRow; i++) ...[
                  if (i > start) const SizedBox(width: PetPicker.gap),
                  Expanded(child: i < tiles.length ? tiles[i] : const SizedBox.shrink()),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 导入: a pack zip of your own.
class _ImportOption extends StatelessWidget {
  const _ImportOption({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final label = context.l10n.botsPetImport;
    return Pressable(
      onTap: busy ? null : onTap,
      semanticLabel: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: RoundedSuperellipseBorder(
                  borderRadius: AppShape.radiusMd,
                  side: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: dark ? 0.5 : 0.7),
                    strokeAlign: BorderSide.strokeAlignInside,
                  ),
                ),
              ),
              child: Center(
                child: busy
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(AppIcons.add, size: 22, color: scheme.onSurfaceVariant),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium!.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _Option extends ConsumerWidget {
  const _Option({required this.id, required this.selected, required this.onTap, this.onLongPress});

  final String id;
  final bool selected;
  final VoidCallback onTap;

  /// A brought pet: removes it.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final duration = AppMotion.of(context, AppMotion.quick);
    final pack = id == noPetId ? null : ref.watch(petPackProvider(id)).value;
    final name = AppLocale.isEnglish ? petNames[id] ?? pack?.name ?? id : pack?.name ?? petNames[id] ?? id;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Pressable(
        onTap: onTap,
        onLongPress: onLongPress,
        semanticLabel: name,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: AnimatedContainer(
                key: ValueKey('pet-option-$id'),
                duration: duration,
                curve: AppMotion.std,
                decoration: ShapeDecoration(
                  color: dark ? Colors.white.withValues(alpha: 0.05) : scheme.onSurface.withValues(alpha: 0.04),
                  shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusMd),
                ),
                foregroundDecoration: ShapeDecoration(
                  shape: RoundedSuperellipseBorder(
                    borderRadius: AppShape.radiusMd,
                    side: BorderSide(
                      color: selected ? scheme.primary : scheme.outlineVariant.withValues(alpha: dark ? 0.5 : 0.7),
                      width: selected ? PetPicker.ring : 1,
                      strokeAlign: BorderSide.strokeAlignInside,
                    ),
                  ),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) => PetPreview(pack: pack, side: constraints.maxWidth),
                ),
              ),
            ),
            const SizedBox(height: 8),
            AnimatedDefaultTextStyle(
              duration: duration,
              style: theme.textTheme.labelMedium!.copyWith(
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
              child: Text(name, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}

/// A pet idling on a little capsule, in a [side]-square; just the capsule
/// for none.
class PetPreview extends StatelessWidget {
  const PetPreview({super.key, required this.pack, required this.side});

  final PetPack? pack;
  final double side;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final pack = this.pack;
    final perchTop = side * PetPicker.perchAt;
    final perchWidth = side * 0.62;
    final perch = Positioned(
      left: (side - perchWidth) / 2,
      top: perchTop,
      width: perchWidth,
      height: math.max(6, side * 0.07),
      child: DecoratedBox(
        decoration: ShapeDecoration(color: scheme.onSurface.withValues(alpha: 0.10), shape: const StadiumBorder()),
      ),
    );
    if (pack == null) return Stack(children: [perch]);
    // As big as on the chat page at 标准 (whole device pixels per art pixel),
    // a step smaller if the body would not fit over the capsule.
    var k = petDevicePixels(pack, PetSize.medium, dpr);
    final room = perchTop - 4;
    while (k > 1 && (pack.baseline - pack.contentBox.top) * k / dpr > room) {
      k--;
    }
    final s = pack.pixelArt ? k / dpr : side * PetPicker.bodyShare / pack.contentBox.height;
    final left = side / 2 - ((pack.contentBox.left + pack.contentBox.right) / 2) * s;
    final top = perchTop - pack.baseline * s;
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        perch,
        Positioned(
          left: (left * dpr).roundToDouble() / dpr,
          top: (top * dpr).roundToDouble() / dpr,
          child: PetSprite(pack: pack, anim: pack.animFor(PetStateName.idle), scale: s),
        ),
      ],
    );
  }
}

/// What a pet converted from a Codex pet left behind (C901 writes the codes
/// into its pack.json); empty for any other pet, or when it can't be read.
/// Read once, right after an import: a pack.json is small (256 KiB at most).
List<String> codexImportWarnings(PetPack pack) {
  final dir = pack.dir;
  if (dir == null) return const [];
  try {
    final json = jsonDecode(File('$dir/pack.json').readAsStringSync());
    final warnings = json is Map && json['codexImport'] is Map ? (json['codexImport'] as Map)['warnings'] : null;
    return [
      if (warnings is List)
        for (final code in warnings)
          if (code is String && code.isNotEmpty) code,
    ];
  } on Object {
    return const [];
  }
}

/// One conversion code in words; an unknown one as it is.
String codexWarningText(L10n l10n, String code) => switch (code) {
  'dsh-state-loops-replace-codex-settle-to-idle' => l10n.botsPetCodexLoops,
  'roam-left-mirrors-right-track' => l10n.botsPetCodexRoamLeft,
  'drag-direction-uses-right-track' => l10n.botsPetCodexDrag,
  'sleep-uses-first-idle-frame' => l10n.botsPetCodexSleep,
  'look-directions-not-bound' => l10n.botsPetCodexLook,
  'webp-transcoded-to-png' => l10n.botsPetCodexWebp,
  'custom-tracks-not-bound' => l10n.botsPetCodexCustomTracks,
  'fps-rounded-to-milliseconds' => l10n.botsPetCodexFps,
  'one-shot-return-controlled-by-dsh' => l10n.botsPetCodexOneShot,
  'missing-author' => l10n.botsPetCodexMissingAuthor,
  'missing-license' => l10n.botsPetCodexMissingLicense,
  'missing-source' => l10n.botsPetCodexMissingSource,
  _ => code,
};
