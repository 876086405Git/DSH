// One installed pack version (STAGE3-APP-INTEGRATION §3, §6): what it is,
// the characters it can make, its resources and what the import noticed;
// hand the original file on, or withdraw this version (kept, not deleted).

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_packs.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_tool_turns.dart' show tavernNewId;
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/empty_view.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'tavern_chat_files.dart' show tavernChatFileName;
import 'tavern_pack_bindings_page.dart';
import 'tavern_pack_widgets.dart';
import 'tavern_widgets.dart' show kTavernSheetMargin, tavernCardSinkProvider;

class TavernPackPage extends ConsumerStatefulWidget {
  const TavernPackPage({super.key, required this.packRef});

  final TavernPackVersionRef packRef;

  static Route<void> route(TavernPackVersionRef packRef) =>
      MaterialPageRoute<void>(builder: (_) => TavernPackPage(packRef: packRef));

  @override
  ConsumerState<TavernPackPage> createState() => _TavernPackPageState();
}

class _TavernPackPageState extends ConsumerState<TavernPackPage> {
  late String _version = widget.packRef.packVersion;
  bool _busy = false;

  /// A withdrawal not answered yet goes again with its own id.
  String? _removal;

  String get _packId => widget.packRef.installedPackId;

  Future<void> _export(TavernPackVersion version) async {
    final l10n = context.l10n;
    final sink = ref.read(tavernCardSinkProvider);
    try {
      final bytes = await ref.read(tavernProvider).exportInstalledGameplayPack(version.ref);
      final name = tavernChatFileName('${tavernPackTitle(version)} ${version.ref.packVersion}', extension: 'dshpack');
      await sink(name, bytes, 'application/zip');
    } on Object catch (e) {
      if (mounted) showBriefNotice(context, tavernPackErrorText(l10n, e));
    }
  }

  Future<void> _withdraw(TavernPackVersion version) async {
    final l10n = context.l10n;
    final ok = await tavernPackConfirm(
      context,
      title: l10n.tavernPackWithdrawTitle(version.ref.packVersion),
      message: l10n.tavernPackWithdrawNote,
      action: l10n.tavernPackWithdraw,
    );
    if (!ok || !mounted) return;
    // The list behind this page refreshes even if this page is left meanwhile.
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() => _busy = true);
    try {
      await ref
          .read(tavernProvider)
          .removeGameplayPackVersion(
            version.ref,
            expected: version.availability,
            operationId: _removal ??= tavernNewId(),
          );
      _removal = null;
    } on TavernGameplayException catch (e) {
      // Refused: a new try is a new intent, against what is there now.
      _removal = null;
      if (mounted) showBriefNotice(context, tavernPackErrorText(l10n, e));
    } on Object catch (e) {
      if (mounted) showBriefNotice(context, tavernPackErrorText(l10n, e));
    }
    container.invalidate(tavernPacksProvider);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickVersion(List<TavernPackVersion> versions) => showAppSheet<void>(
    context,
    builder: (sheet) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: SheetGroup(
          margin: kTavernSheetMargin,
          children: [
            for (final v in versions.reversed)
              SettingsTile(
                key: ValueKey('tavern-pack-version-${v.ref.packVersion}'),
                tinted: false,
                title: v.ref.packVersion,
                value: v.removed ? Text(context.l10n.tavernPackWithdrawnLabel) : null,
                trailing: v.ref.packVersion == _version ? const Icon(AppIcons.selected, size: 20) : null,
                chevron: false,
                onTap: () {
                  Navigator.of(sheet).pop();
                  // Another version is another withdrawal, with its own id.
                  if (v.ref.packVersion != _version) _removal = null;
                  setState(() => _version = v.ref.packVersion);
                },
              ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final packs = ref.watch(tavernPacksProvider(true));
    final versions = [
      for (final v in packs.value ?? const <TavernPackVersion>[])
        if (v.ref.installedPackId == _packId) v,
    ];
    final version = versions.where((v) => v.ref.packVersion == _version).firstOrNull;
    if (version == null) {
      return AppPage.list(
        title: l10n.tavernPacks,
        children: [
          if (packs.isLoading)
            const Center(child: QuietSpinner())
          else
            EmptyView(icon: AppIcons.zip, title: l10n.tavernPackVersionNotFound),
        ],
      );
    }
    final cast = tavernPackCast(version);
    final resources = tavernPackResources(version);
    final dshgo = version.inspection['dshgo'];
    final declarationIssues = [
      if (dshgo is Map<String, Object?>) ...[
        for (final issue in dshgo['issues'] as List<Object?>? ?? const []) issue! as Map<String, Object?>,
        for (final block in dshgo['blocks'] as List<Object?>? ?? const [])
          if (block case {'status': final status} when status != 'executable' && status != 'absent')
            block as Map<String, Object?>,
      ],
    ];
    return AppPage.list(
      title: tavernPackTitle(version),
      // The pack's id, unless the title already is it.
      subtitle: tavernPackTitle(version) == version.externalPackId ? null : Text(version.externalPackId),
      children: [
        SettingsSection(
          footer: version.removed ? null : Text(l10n.tavernPackAddNote),
          children: [
            SettingsTile(
              key: const ValueKey('tavern-pack-version'),
              title: l10n.tavernPackVersion,
              value: Text(version.removed ? l10n.tavernPackWithdrawnShort(_version) : _version),
              onTap: versions.length > 1 ? () => unawaited(_pickVersion(versions)) : null,
              chevron: versions.length > 1,
            ),
            if (!version.removed)
              SettingsTile(
                key: const ValueKey('tavern-pack-enable-global'),
                title: l10n.tavernPackAddGlobal,
                onTap: () => Navigator.of(context).push(
                  TavernPackBindingsPage.route((kind: TavernGameplayScope.global, targetId: null), adding: version.ref),
                ),
              ),
          ],
        ),
        if (cast.isNotEmpty)
          SettingsSection(
            key: const ValueKey('tavern-pack-cast'),
            title: l10n.tavernPackCast,
            footer: Text(l10n.tavernPackCastNote),
            children: [
              for (final member in cast)
                SettingsTile(
                  key: ValueKey('tavern-pack-cast-${member.resource ? 'r' : 'm'}-${member.localId}'),
                  title: member.name,
                  subtitle: member.resource ? l10n.tavernPackCastFromCard : null,
                  value: Text(l10n.tavernPackCastImportAction),
                  onTap: _busy ? null : () => unawaited(importTavernPackCast(context, ref, version.ref, member)),
                ),
            ],
          ),
        if (resources.isNotEmpty)
          SettingsSection(
            key: const ValueKey('tavern-pack-resources'),
            title: l10n.tavernPackResources,
            children: [
              for (final r in resources)
                switch (tavernPackResourceIssues(version, r['localId']! as String)) {
                  final issues => SettingsTile(
                    key: ValueKey('tavern-pack-resource-${r['localId']}'),
                    tinted: false,
                    title: r['localId']! as String,
                    subtitle: '${r['kind']} · ${r['path']}',
                    value: issues.isEmpty ? null : Text(l10n.tavernPackIssueCount(issues.length)),
                    onTap: issues.isEmpty
                        ? null
                        : () =>
                              unawaited(showTavernPackIssues(context, title: r['localId']! as String, issues: issues)),
                    chevron: issues.isNotEmpty,
                  ),
                },
            ],
          ),
        SettingsSection(
          children: [
            SettingsTile(
              key: const ValueKey('tavern-pack-declaration'),
              icon: AppIcons.diagnostics,
              tinted: false,
              title: l10n.tavernPackDeclaration,
              value: Text(
                declarationIssues.isEmpty
                    ? l10n.tavernPackNothingNoted
                    : l10n.tavernPackIssueCount(declarationIssues.length),
              ),
              onTap: declarationIssues.isEmpty
                  ? null
                  : () => unawaited(
                      showTavernPackIssues(
                        context,
                        title: l10n.tavernPackDeclaration,
                        note: l10n.tavernPackDeclarationNote,
                        issues: declarationIssues,
                      ),
                    ),
              chevron: declarationIssues.isNotEmpty,
            ),
            SettingsTile(
              key: const ValueKey('tavern-pack-export'),
              icon: AppIcons.share,
              tinted: false,
              title: l10n.tavernPackExportOriginal,
              chevron: false,
              onTap: () => unawaited(_export(version)),
            ),
            if (!version.removed)
              SettingsTile(
                key: const ValueKey('tavern-pack-withdraw'),
                icon: AppIcons.archive,
                danger: true,
                tinted: false,
                title: l10n.tavernPackWithdraw,
                chevron: false,
                onTap: _busy ? null : () => unawaited(_withdraw(version)),
              ),
          ],
        ),
      ],
    );
  }
}
