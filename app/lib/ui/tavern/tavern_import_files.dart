// 导入 › 从文件 (docs/design/roleplay-roadmap.md §4): one door. Each picked
// file goes where it belongs — cards to the shelf, presets, lorebooks and
// regex to the library, 酒馆助手 scripts to 脚本库, an ST quick reply set to
// 快速回复, a chat to the character it names — and one non-card file opens its 体检.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_file_kind.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_quick_replies.dart';
import '../../tavern/tavern_settings.dart';
import '../../tavern/tavern_st_theme.dart';
import '../common/brief_notice.dart';
import 'tavern_chat_files.dart';
import 'tavern_lorebooks_page.dart';
import 'tavern_presets_page.dart';
import 'tavern_regex_page.dart';
import 'tavern_report_page.dart';
import 'tavern_scripts_page.dart' show tavernScriptCount;

/// Picks files and takes each in where it belongs, saying how each went. The
/// first card taken in is returned (its page opens); a single other file
/// opens its import report instead.
Future<TavernCharacter?> importTavernFiles(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final navigator = Navigator.of(context);
  final tavern = ref.read(tavernProvider);
  final picked = await ref.read(tavernChatPickerProvider)();
  if (picked.isEmpty) return null;
  TavernCharacter? card;
  ({TavernImportKind kind, String id, String name})? report;
  for (final file in picked) {
    String notice;
    try {
      switch (tavernFileKindOf(file.fileName, file.bytes)) {
        case TavernFileKind.card:
          final character = await tavern.importCard(file.bytes, fileName: file.fileName);
          card ??= character;
          notice = l10n.tavernImported(character.name);
        case TavernFileKind.preset:
          final result = await tavern.importPreset(tavernTextOf(file.bytes), fileName: file.fileName);
          report = (kind: TavernImportKind.preset, id: result.preset.id, name: result.preset.name);
          notice = result.issues.isEmpty
              ? l10n.tavernPresetImported(result.preset.name)
              : l10n.tavernPresetImportedWithIssues(result.preset.name, result.issues.length);
        case TavernFileKind.lorebook:
          final result = await tavern.importLorebook(tavernTextOf(file.bytes), fileName: file.fileName);
          report = (kind: TavernImportKind.lorebook, id: result.book.id, name: result.book.name);
          notice = l10n.tavernLorebookImported(result.book.name, result.book.entryCount);
        case TavernFileKind.regex:
          final result = await tavern.importRegexScripts(tavernTextOf(file.bytes));
          if (result.scripts case [final script]) {
            final name = script.name.isEmpty ? l10n.tavernRegexUnnamed : script.name;
            report = (kind: TavernImportKind.regex, id: script.id, name: name);
          }
          notice = l10n.tavernRegexImported(result.scripts.length);
        case TavernFileKind.quickReplies:
          final (:replies, :skipped) = tavernQuickRepliesOf(file.bytes);
          final kept = ref.read(tavernQuickRepliesProvider);
          final added = [
            for (final r in {...replies})
              if (!kept.contains(r)) r,
          ];
          if (added.isNotEmpty) await ref.read(tavernQuickRepliesProvider.notifier).set([...kept, ...added]);
          notice = skipped == 0
              ? l10n.tavernQuickRepliesAdded(added.length)
              : l10n.tavernQuickRepliesAddedSkipped(added.length, skipped);
        case TavernFileKind.chat:
          notice = await _importChat(ref, tavern, file, l10n);
        case TavernFileKind.stTheme:
          // Its quote and italics colours become the story's (配色 › ST).
          final map = jsonDecode(tavernTextOf(file.bytes).replaceFirst('﻿', '')) as Map<String, Object?>;
          final theme = tavernStThemeOf(map, fileName: file.fileName);
          if (theme == null) {
            notice = l10n.tavernStThemeNoColors(file.fileName);
          } else {
            await ref.read(tavernStThemeProvider.notifier).set(theme);
            await ref.read(tavernSettingsProvider.notifier).setPalette(TavernPalette.st);
            notice = l10n.tavernStThemeImported(theme.name);
          }
        case TavernFileKind.helperScripts:
          final added = await tavern.importGlobalScripts(tavernTextOf(file.bytes));
          notice = l10n.tavernScriptsImported(tavernScriptCount(added));
        case TavernFileKind.unknown:
          notice = l10n.tavernImportUnknown(file.fileName);
      }
    } on Object catch (e) {
      final reason = e is TavernImportError ? l10n.tavernImportFailed : e.toString().split('\n').first;
      notice = l10n.tavernImportFileFailed(file.fileName, reason);
    }
    messenger?.showBriefNotice(notice);
  }
  ref
    ..invalidate(tavernPresetSelectionProvider)
    ..invalidate(tavernLorebooksProvider)
    ..invalidate(tavernRegexProvider);
  if (picked.length == 1 && card == null && report != null && navigator.mounted) {
    unawaited(navigator.push(TavernImportReportPage.route(kind: report.kind, assetId: report.id, name: report.name)));
  }
  return card;
}

/// An ST chat goes to the character its first line names, when exactly one
/// on the shelf has that name; otherwise its own page is the place.
Future<String> _importChat(WidgetRef ref, Tavern tavern, TavernChatFile file, L10n l10n) async {
  final name = tavernChatCharacterName(file.bytes);
  if (name == null) return l10n.tavernImportChatNoName;
  final matches = (await tavern.watchCharacters().first).where((c) => c.name.trim() == name).toList();
  if (matches.length != 1) return l10n.tavernImportChatNoCharacter(name);
  final result = await tavern.importChats(matches.single.id, [file]);
  return l10n.tavernImportedChatsTo(result.chatIds.length, name);
}
