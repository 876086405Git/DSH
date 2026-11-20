// 玩法包 (STAGE3-APP-INTEGRATION §1, §3): the installed packs, one row per
// pack with its versions behind it; import a .dshpack, and 全局启用 for the
// packs every chat uses. Installing never turns a pack on.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_packs.dart';
import '../../tavern/tavern_provider.dart';
import '../common/brief_notice.dart';
import '../common/empty_view.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'tavern_chat_files.dart' show tavernChatPickerProvider;
import 'tavern_pack_bindings_page.dart';
import 'tavern_pack_page.dart';

class TavernPacksPage extends ConsumerStatefulWidget {
  const TavernPacksPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const TavernPacksPage());

  @override
  ConsumerState<TavernPacksPage> createState() => _TavernPacksPageState();
}

class _TavernPacksPageState extends ConsumerState<TavernPacksPage> {
  bool _busy = false;
  bool _withdrawn = false;

  Future<void> _import() async {
    final l10n = context.l10n;
    final picked = await ref.read(tavernChatPickerProvider)();
    if (picked.isEmpty || !mounted) return;
    setState(() => _busy = true);
    TavernPackVersionRef? opened;
    final tavern = ref.read(tavernProvider);
    for (final file in picked) {
      try {
        final result = await tavern.importGameplayPack(file.bytes);
        final title = tavernPackTitle(result.version);
        if (mounted) {
          showBriefNotice(
            context,
            result.reused
                ? l10n.tavernPackAlreadyInstalled(title, result.ref.packVersion)
                : l10n.tavernPackInstalled(title, result.ref.packVersion),
          );
        }
        opened = result.ref;
      } on Object catch (e) {
        if (mounted) showBriefNotice(context, l10n.tavernImportFileFailed(file.fileName, tavernPackErrorText(l10n, e)));
      }
    }
    if (!mounted) return;
    ref.invalidate(tavernPacksProvider);
    setState(() => _busy = false);
    // One file: straight to what it installed.
    if (picked.length == 1 && opened != null) await _open(opened);
  }

  Future<void> _open(TavernPackVersionRef ref) => Navigator.of(context).push(TavernPackPage.route(ref));

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final packs = ref.watch(tavernPacksProvider(_withdrawn));
    // One row per installed pack: its newest version stands for it.
    final byPack = <String, List<TavernPackVersion>>{};
    for (final v in packs.value ?? const <TavernPackVersion>[]) {
      (byPack[v.ref.installedPackId] ??= []).add(v);
    }
    return AppPage.list(
      title: l10n.tavernPacks,
      actions: [
        GlassIconButton(
          key: const ValueKey('tavern-packs-import'),
          icon: AppIcons.download,
          tooltip: l10n.tavernPackImport,
          onPressed: _busy ? null : () => unawaited(_import()),
        ),
      ],
      children: [
        SettingsSection(
          footer: Text(l10n.tavernPacksSubtitle),
          children: [
            SettingsTile(
              key: const ValueKey('tavern-packs-global'),
              title: l10n.tavernPackScopeGlobal,
              onTap: () =>
                  Navigator.of(context)
                      .push(TavernPackBindingsPage.route((kind: TavernGameplayScope.global, targetId: null))),
            ),
          ],
        ),
        if (packs.isLoading && !packs.hasValue)
          const Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(child: QuietSpinner()),
          )
        else if (byPack.isEmpty)
          Padding(
            key: const ValueKey('tavern-packs-empty'),
            padding: const EdgeInsets.only(top: 32),
            child: EmptyView(
              icon: AppIcons.zip,
              title: l10n.tavernPacksEmpty,
              message: packs.hasError ? '${packs.error}' : l10n.tavernPacksEmptyNote,
              actionLabel: l10n.tavernPackImport,
              onAction: _busy ? null : () => unawaited(_import()),
              compact: true,
            ),
          )
        else
          SettingsSection(
            key: const ValueKey('tavern-packs'),
            children: [
              for (final versions in byPack.values)
                SettingsTile(
                  key: ValueKey('tavern-pack-${versions.last.ref.installedPackId}'),
                  title: tavernPackTitle(versions.last),
                  subtitle: versions.length == 1 ? null : l10n.tavernPackVersionCount(versions.length),
                  value: Text(
                    versions.last.removed
                        ? l10n.tavernPackWithdrawnShort(versions.last.ref.packVersion)
                        : versions.last.ref.packVersion,
                  ),
                  onTap: () => unawaited(_open(versions.last.ref)),
                ),
            ],
          ),
        SettingsSection(
          children: [
            SettingsSwitchTile(
              key: const ValueKey('tavern-packs-withdrawn'),
              tinted: false,
              title: l10n.tavernPackShowWithdrawn,
              value: _withdrawn,
              onChanged: (value) => setState(() => _withdrawn = value),
            ),
          ],
        ),
      ],
    );
  }
}
