// 「Live2D 形象」 on a character's page: import a model for her (a model's
// folder zipped, as in the companion room), replace it, or take it away. The
// visual novel layout draws her with it (tavern_vn_view.dart).

import 'dart:async';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_pack.dart';
import '../../l10n/l10n.dart';
import '../../tavern/tavern_live2d.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import 'tavern_widgets.dart' show showTavernActions;

class TavernLive2dTile extends ConsumerStatefulWidget {
  const TavernLive2dTile({super.key, required this.character});

  final TavernCharacter character;

  @override
  ConsumerState<TavernLive2dTile> createState() => _TavernLive2dTileState();
}

class _TavernLive2dTileState extends ConsumerState<TavernLive2dTile> {
  bool _busy = false;

  String get _id => widget.character.id;

  Future<void> _import() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final zip = await ref.read(tavernLive2dPickerProvider)();
    if (zip == null || !mounted) return;
    setState(() => _busy = true);
    String? said;
    try {
      final store = await tavernLive2dStore(
        ref.read(tavernLive2dRootProvider),
        _id,
        expectedRuntime: ref.read(tavernLive2dRuntimeProvider),
      );
      await installTavernLive2d(
        store,
        zip.path,
        companionPack: ref.read(tavernCompanionPackProvider),
        bundled: ref.read(tavernBundledPackProvider),
      );
      said = l10n.tavernLive2dImported;
    } on CompanionPackException catch (error) {
      said = switch (error.problem) {
        CompanionPackProblem.noRuntime => l10n.tavernLive2dNoRuntime,
        CompanionPackProblem.runtimeMismatch => l10n.companionPackRuntimeMismatch,
        CompanionPackProblem.noModel => l10n.companionPackNoModel,
        CompanionPackProblem.legacyModel => l10n.companionPackLegacyModel,
        CompanionPackProblem.forbiddenFile || CompanionPackProblem.unsafePath => l10n.companionPackUnsafe,
        CompanionPackProblem.tooLarge => l10n.companionPackTooLarge,
        CompanionPackProblem.storage => l10n.companionPackStorage,
        CompanionPackProblem.notAPack => l10n.companionPackBroken,
      };
    } on Object {
      said = l10n.companionPackStorage;
    } finally {
      unawaited(zip.delete().then<void>((_) {}, onError: (Object _) {}));
      ref.invalidate(tavernLive2dProvider(_id));
      if (mounted) setState(() => _busy = false);
    }
    // In place of an earlier one: what it said is out of date.
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(said)));
  }

  Future<void> _remove(CompanionPackStore store) async {
    setState(() => _busy = true);
    try {
      await removeTavernLive2d(store);
    } on FileSystemException {
      // Whatever stayed goes with the next import or the character.
    } finally {
      ref.invalidate(tavernLive2dProvider(_id));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final store = ref.watch(tavernLive2dProvider(_id)).value;
    return SettingsTile(
      key: const ValueKey('tavern-live2d'),
      title: l10n.tavernLive2d,
      subtitle: l10n.tavernLive2dSubtitle,
      value: _busy
          ? const SizedBox.square(dimension: 18, child: QuietSpinner())
          : Text(store == null ? l10n.tavernLive2dNone : l10n.tavernLive2dSet),
      onTap: _busy
          ? null
          : store == null
          ? () => unawaited(_import())
          : () => unawaited(
              showTavernActions(context, [
                (AppIcons.refresh, l10n.tavernLive2dReplace, () => unawaited(_import())),
                (AppIcons.delete, l10n.tavernLive2dRemove, () => unawaited(_remove(store))),
              ]),
            ),
    );
  }
}
