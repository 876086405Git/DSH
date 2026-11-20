// 群聊设置 (engine P2 125, roleplay-agent.md §4.1): the group's name; how it
// takes turns and how many speak at most each turn; and its members — each
// muted or not, more or less talkative, on the main model or the helper, in
// order, taken out, or one more added. Every change is saved at once; the
// page follows the group as the engine has it.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../workspace/text_prompt.dart';
import 'tavern_group_new_page.dart';
import 'tavern_stepper.dart';
import 'tavern_widgets.dart' show kTavernSheetMargin;

/// A group as the engine has it now; null once it is not one.
final tavernGroupProvider = StreamProvider.autoDispose.family<TavernGroupChat?, String>(
  (ref, chatId) => ref.watch(tavernProvider).watchGroupChat(chatId),
);

class TavernGroupPage extends ConsumerWidget {
  const TavernGroupPage({super.key, required this.chatId});

  final String chatId;

  static Route<void> route(String chatId) => MaterialPageRoute<void>(builder: (_) => TavernGroupPage(chatId: chatId));

  /// Saves one change; a refusal says why.
  Future<void> _save(BuildContext context, WidgetRef ref, Future<Object?> Function(Tavern t) change) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    try {
      await change(ref.read(tavernProvider));
    } on TavernGroupException catch (e) {
      messenger?.showBriefNotice(
        l10n.tavernGroupSaveFailed(switch (e.code) {
          TavernGroupError.notGroup => l10n.tavernGroupErrorNotGroup,
          TavernGroupError.characterNotFound => l10n.tavernGroupErrorCharacterNotFound,
          TavernGroupError.memberExists => l10n.tavernGroupErrorMemberExists,
          TavernGroupError.memberNotFound => l10n.tavernGroupErrorMemberNotFound,
          TavernGroupError.invalidMembers => l10n.tavernGroupErrorInvalidMembers,
          TavernGroupError.invalidTalkativeness => l10n.tavernGroupErrorInvalidTalkativeness,
          TavernGroupError.invalidLimit => l10n.tavernGroupErrorInvalidLimit,
          TavernGroupError.invalidOrder => l10n.tavernGroupErrorInvalidOrder,
          TavernGroupError.hostInUse => l10n.tavernGroupErrorHostInUse,
          TavernGroupError.invalidTitle => l10n.tavernGroupErrorInvalidTitle,
        }),
      );
    } on Object catch (e) {
      messenger?.showBriefNotice(l10n.tavernGroupSaveFailed('$e'));
    }
  }

  Future<void> _rename(BuildContext context, WidgetRef ref, TavernGroupChat group) async {
    final l10n = context.l10n;
    final title = await showTextPrompt(context, title: l10n.tavernGroupTitle, initial: group.title, maxLength: 60);
    if (title == null || title.trim().isEmpty || !context.mounted) return;
    await _save(context, ref, (t) => t.updateGroupChat(chatId, title: title.trim()));
  }

  Future<void> _add(BuildContext context, WidgetRef ref, TavernGroupChat group) async {
    final l10n = context.l10n;
    final inside = {for (final m in group.members) m.characterId};
    final others = [
      for (final c in ref.read(tavernCharactersProvider).value ?? const <TavernCharacter>[])
        if (!inside.contains(c.id)) c,
    ];
    final picked = await showAppSheet<String>(
      context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: SheetGroup(
            title: l10n.tavernGroupAdd,
            margin: kTavernSheetMargin,
            children: [
              if (others.isEmpty)
                SettingsTile(tinted: false, title: l10n.tavernGroupNoOthers, chevron: false)
              else
                for (final c in others)
                  SettingsTile(
                    key: ValueKey('tavern-group-add-${c.id}'),
                    tinted: false,
                    title: c.name,
                    chevron: false,
                    onTap: () => Navigator.of(sheet).pop(c.id),
                  ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !context.mounted) return;
    await _save(context, ref, (t) => t.addGroupMember(chatId, picked));
  }

  /// One member's own settings, each saved as it changes.
  Future<void> _member(BuildContext context, WidgetRef ref, String characterId, String name) async {
    final l10n = context.l10n;
    await showAppSheet<void>(
      context,
      isScrollControlled: true,
      builder: (sheet) => Consumer(
        builder: (context, ref, _) {
          final group = ref.watch(tavernGroupProvider(chatId)).value;
          final members = group?.members ?? const <TavernGroupMember>[];
          final at = members.indexWhere((m) => m.characterId == characterId);
          if (group == null || at < 0) return const SizedBox.shrink();
          final member = members[at];
          return SafeArea(
            top: false,
            child: SingleChildScrollView(
              child: SheetGroup(
                title: name,
                margin: kTavernSheetMargin,
                children: [
                  SettingsSwitchTile(
                    key: const ValueKey('tavern-group-member-muted'),
                    title: l10n.tavernGroupMuted,
                    subtitle: l10n.tavernGroupMutedNote,
                    value: member.muted,
                    onChanged: (on) =>
                        unawaited(_save(context, ref, (t) => t.updateGroupMember(chatId, characterId, muted: on))),
                  ),
                  SettingsTile(
                    key: const ValueKey('tavern-group-member-talk'),
                    title: l10n.tavernGroupTalkativeness,
                    subtitle: l10n.tavernGroupTalkativenessNote,
                    value: TavernStepper(
                      keyName: 'tavern-group-member-talk',
                      value: (member.talkativeness * 100).round(),
                      max: 100,
                      step: 10,
                      suffix: '%',
                      onChanged: (v) => unawaited(
                        _save(context, ref, (t) => t.updateGroupMember(chatId, characterId, talkativeness: v / 100)),
                      ),
                    ),
                    chevron: false,
                  ),
                  SettingsSwitchTile(
                    key: const ValueKey('tavern-group-member-helper'),
                    title: l10n.tavernGroupHelperModel,
                    subtitle: l10n.tavernGroupHelperModelNote,
                    value: member.modelRole == TavernGroupModelRole.helper,
                    onChanged: (on) => unawaited(
                      _save(
                        context,
                        ref,
                        (t) => t.updateGroupMember(
                          chatId,
                          characterId,
                          modelRole: on ? TavernGroupModelRole.helper : TavernGroupModelRole.main,
                        ),
                      ),
                    ),
                  ),
                  if (at > 0)
                    SettingsTile(
                      key: const ValueKey('tavern-group-member-up'),
                      tinted: false,
                      title: l10n.tavernGroupMoveUp,
                      chevron: false,
                      onTap: () => unawaited(_move(context, ref, members, at, at - 1)),
                    ),
                  if (at < members.length - 1)
                    SettingsTile(
                      key: const ValueKey('tavern-group-member-down'),
                      tinted: false,
                      title: l10n.tavernGroupMoveDown,
                      chevron: false,
                      onTap: () => unawaited(_move(context, ref, members, at, at + 1)),
                    ),
                  SettingsTile(
                    key: const ValueKey('tavern-group-member-remove'),
                    danger: true,
                    tinted: false,
                    title: l10n.tavernGroupRemove,
                    chevron: false,
                    onTap: () {
                      Navigator.of(sheet).pop();
                      unawaited(_save(context, ref, (t) => t.removeGroupMember(chatId, characterId)));
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _move(BuildContext context, WidgetRef ref, List<TavernGroupMember> members, int from, int to) {
    final ids = [for (final m in members) m.characterId];
    final id = ids.removeAt(from);
    ids.insert(to, id);
    return _save(context, ref, (t) => t.reorderGroupMembers(chatId, ids));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final group = ref.watch(tavernGroupProvider(chatId)).value;
    final names = {
      for (final c in ref.watch(tavernCharactersProvider).value ?? const <TavernCharacter>[]) c.id: c.name,
    };
    return AppPage.list(
      title: l10n.tavernGroupSettings,
      children: [
        if (group == null)
          const QuietSpinner()
        else ...[
          SettingsSection(
            children: [
              SettingsTile(
                key: const ValueKey('tavern-group-rename'),
                title: l10n.tavernGroupTitle,
                value: Text(group.title),
                onTap: () => unawaited(_rename(context, ref, group)),
              ),
            ],
          ),
          SettingsSection(
            footer: Text(tavernGroupActivationNote(context, group.activation)),
            children: [
              SettingsSegmentTile<TavernGroupActivation>(
                key: const ValueKey('tavern-group-activation'),
                title: l10n.tavernGroupActivation,
                segments: [
                  for (final a in [
                    TavernGroupActivation.natural,
                    TavernGroupActivation.listOrder,
                    TavernGroupActivation.randomPool,
                    TavernGroupActivation.manual,
                    // The director's way shows once the group takes it.
                    if (group.activation == TavernGroupActivation.director) TavernGroupActivation.director,
                  ])
                    PillSegment(a, tavernGroupActivationName(context, a)),
                ],
                selected: group.activation,
                onChanged: (a) => unawaited(_save(context, ref, (t) => t.updateGroupChat(chatId, activation: a))),
              ),
              SettingsTile(
                key: const ValueKey('tavern-group-max'),
                title: l10n.tavernGroupMaxSpeakers,
                value: TavernStepper(
                  keyName: 'tavern-group-max',
                  value: group.maxSpeakersPerTurn,
                  min: 1,
                  max: 6,
                  onChanged: (n) =>
                      unawaited(_save(context, ref, (t) => t.updateGroupChat(chatId, maxSpeakersPerTurn: n))),
                ),
                chevron: false,
              ),
              SettingsSwitchTile(
                key: const ValueKey('tavern-group-self'),
                title: l10n.tavernGroupSelfResponses,
                subtitle: l10n.tavernGroupSelfResponsesNote,
                value: group.allowSelfResponses,
                onChanged: (on) =>
                    unawaited(_save(context, ref, (t) => t.updateGroupChat(chatId, allowSelfResponses: on))),
              ),
            ],
          ),
          SettingsSection(
            title: l10n.tavernGroupMembers,
            footer: Text(l10n.tavernGroupHostNote(names[group.hostCharacterId] ?? '')),
            children: [
              for (final m in group.members)
                SettingsTile(
                  key: ValueKey('tavern-group-member-${m.characterId}'),
                  tinted: false,
                  title: names[m.characterId] ?? m.characterId,
                  // Nothing to say: a one-line row, its title centred.
                  subtitle: switch ([
                    if (m.characterId == group.hostCharacterId) l10n.tavernGroupHost,
                    if (m.muted) l10n.tavernGroupMuted,
                    if (m.modelRole == TavernGroupModelRole.helper) l10n.tavernGroupHelperModel,
                    if (!m.available) l10n.tavernGroupUnavailable,
                  ]) {
                    [] => null,
                    final notes => notes.join(' · '),
                  },
                  value: Text('${(m.talkativeness * 100).round()}%'),
                  onTap: () => unawaited(_member(context, ref, m.characterId, names[m.characterId] ?? m.characterId)),
                ),
              SettingsTile(
                key: const ValueKey('tavern-group-add'),
                title: l10n.tavernGroupAdd,
                // Ends where the members' chevrons do.
                trailing: Icon(AppIcons.add, size: 20, color: DshColors.of(context).textTertiary),
                onTap: () => unawaited(_add(context, ref, group)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
