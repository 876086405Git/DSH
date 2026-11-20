// 资源库 › 正则 (docs/design/roleplay-roadmap.md P0, engine T21): global regex
// scripts, exported from SillyTavern one by one or as a list, imported as
// they are; each on or off, edited in place, exported or deleted. A script the engine cannot
// run here (a JavaScript feature Dart's regex lacks) says so and is skipped.
// The regex a card or a preset brings goes with it, not here.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../common/brief_notice.dart';
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'tavern_chat_files.dart';
import 'tavern_presets_page.dart' show tavernTextOf;
import 'tavern_regex_edit_page.dart';
import 'tavern_regex_test_page.dart';
import 'tavern_report_page.dart';
import 'tavern_widgets.dart';

/// The global regex scripts.
final tavernRegexProvider = FutureProvider.autoDispose<List<TavernRegexScript>>(
  (ref) => ref.watch(tavernProvider).listRegexScripts(),
);

class TavernRegexPage extends ConsumerWidget {
  const TavernRegexPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const TavernRegexPage());

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final tavern = ref.read(tavernProvider);
    for (final file in await ref.read(tavernChatPickerProvider)()) {
      try {
        final result = await tavern.importRegexScripts(tavernTextOf(file.bytes));
        messenger?.showBriefNotice(l10n.tavernRegexImported(result.scripts.length));
      } on Object catch (e) {
        messenger?.showBriefNotice(
          l10n.tavernPresetImportFailed(e is FormatException ? l10n.tavernPresetNotText : '$e'),
        );
      }
    }
    ref.invalidate(tavernRegexProvider);
  }

  Future<void> _export(WidgetRef ref, TavernRegexScript script, String name) async {
    final text = await ref.read(tavernProvider).exportRegex(regexId: script.id);
    final bytes = Uint8List.fromList(utf8.encode(text));
    await ref.read(tavernChatSinkProvider)([TavernChatFile(fileName: '$name.json', bytes: bytes)]);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, TavernRegexScript script, String name) async {
    final l10n = context.l10n;
    final ok = await confirmTavernDelete(
      context,
      title: l10n.tavernRegexDeleteTitle(name),
      message: l10n.tavernDeleteChatMessage,
    );
    if (!ok) return;
    await ref.read(tavernProvider).deleteRegex(script.id);
    ref.invalidate(tavernRegexProvider);
  }

  Future<void> _toggle(WidgetRef ref, TavernRegexScript script) async {
    await ref.read(tavernProvider).setRegexEnabled(script.id, !script.enabled);
    ref.invalidate(tavernRegexProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scripts = ref.watch(tavernRegexProvider).value;
    return AppPage.list(
      title: l10n.tavernRegex,
      actions: [
        GlassIconButton(
          key: const ValueKey('tavern-regex-import'),
          icon: AppIcons.add,
          tooltip: l10n.tavernRegexImport,
          onPressed: () => unawaited(_import(context, ref)),
        ),
      ],
      children: [
        if (scripts == null)
          const QuietSpinner()
        else if (scripts.isEmpty)
          EmptyView(
            key: const ValueKey('tavern-regex-empty'),
            icon: AppIcons.code,
            title: l10n.tavernRegexEmpty,
            message: l10n.tavernRegexEmptyMessage,
            compact: true,
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
          )
        else
          SettingsSection(
            children: [
              for (final script in scripts)
                () {
                  final name = script.name.isEmpty ? l10n.tavernRegexUnnamed : script.name;
                  final find = '${script.raw['findRegex'] ?? ''}';
                  return SettingsTile(
                    key: ValueKey('tavern-regex-${script.id}'),
                    title: name,
                    subtitle: script.compatible ? find : l10n.tavernRegexIncompatible,
                    value: Text(script.enabled ? l10n.tavernRegexOn : l10n.tavernRegexOff),
                    onTap: () => unawaited(
                      showTavernActions(context, [
                        (
                          script.enabled ? AppIcons.remove : AppIcons.selected,
                          script.enabled ? l10n.tavernRegexDisable : l10n.tavernRegexEnable,
                          () => unawaited(_toggle(ref, script)),
                        ),
                        (
                          AppIcons.edit,
                          l10n.tavernRegexEdit,
                          () => unawaited(Navigator.of(context).push(TavernRegexEditPage.route(script))),
                        ),
                        (
                          AppIcons.play,
                          l10n.tavernRegexTest,
                          () => unawaited(Navigator.of(context).push(TavernRegexTestPage.route(script))),
                        ),
                        (
                          AppIcons.info,
                          l10n.tavernReport,
                          () => unawaited(
                            Navigator.of(context).push(
                              TavernImportReportPage.route(
                                kind: TavernImportKind.regex,
                                assetId: script.id,
                                name: name,
                              ),
                            ),
                          ),
                        ),
                        (AppIcons.share, l10n.tavernRegexExport, () => unawaited(_export(ref, script, name))),
                        (AppIcons.delete, l10n.tavernRegexDelete, () => unawaited(_delete(context, ref, script, name))),
                      ]),
                    ),
                  );
                }(),
            ],
          ),
      ],
    );
  }
}
