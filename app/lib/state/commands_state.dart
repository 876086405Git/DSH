import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import 'connection_state.dart';
import 'features_state.dart';
import 'hosts_state.dart';

/// Where a slash command runs.
enum SlashCommandKind {
  /// A DSH command (`commands/list`), run with `commands/execute`.
  host,

  /// Handled by the app itself (`/new`, `/model`).
  app,

  /// A skill (`skills/list`): `/name …` is sent as a normal message and
  /// the Host loads the skill, like the official "/" menu's skill group.
  skill,
}

/// One row of the slash palette.
class SlashCommand {
  const SlashCommand({
    required this.name,
    required this.label,
    required this.description,
    this.hint,
    this.kind = SlashCommandKind.host,
    this.acceptsAttachments = false,
  });

  /// Registered name without the slash (`compact`); what gets executed.
  final String name;

  /// Short Chinese title (`压缩`); also accepted as a typed alias (`/压缩`).
  final String label;
  final String description;

  /// Input placeholder when the command takes free-form input.
  final String? hint;
  final SlashCommandKind kind;
  final bool acceptsAttachments;

  /// Commands without an input descriptor run as soon as they are picked.
  bool get takesInput => hint != null;
}

/// App-level commands, always available.
List<SlashCommand> get appSlashCommands => [
  SlashCommand(
    name: 'new',
    label: appL10n.commonNewChat,
    description: appL10n.stateCommandNewDescription,
    kind: SlashCommandKind.app,
  ),
  SlashCommand(
    name: 'model',
    label: appL10n.stateModelLabel,
    description: appL10n.stateCommandModelDescription,
    kind: SlashCommandKind.app,
  ),
  SlashCommand(
    name: 'export',
    label: appL10n.stateCommandExportLabel,
    description: wordsForIos ? appL10n.iosCommandExportDescription : appL10n.stateCommandExportDescription,
    kind: SlashCommandKind.app,
  ),
  SlashCommand(
    name: 'features',
    label: appL10n.stateAllFeatures,
    description: appL10n.stateCommandFeaturesDescription,
    kind: SlashCommandKind.app,
  ),
];

/// Chinese faces for DSH's first-party commands, selected by `definitionId`
/// like the official web client does (`dsh-client-ui-commands` locales), so a
/// plugin's same-name override keeps its own copy.
Map<String, ({String name, String label, String description, String? hint})> get _firstParty => {
  '@deepseek-ai/dsh-command-compact': (
    name: 'compact',
    label: appL10n.stateCompactLabel,
    description: appL10n.stateCommandCompactDescription,
    hint: null,
  ),
  '@deepseek-ai/dsh-permission-presets': (
    name: 'permission',
    label: appL10n.statePermissionLabel,
    description: appL10n.stateCommandPermissionDescription,
    hint: appL10n.stateCommandPermissionHint,
  ),
  '@deepseek-ai/dsh-plan-mode': (
    name: 'plan',
    label: appL10n.statePlanLabel,
    description: appL10n.stateCommandPlanDescription,
    hint: appL10n.stateCommandPlanHint,
  ),
  '@deepseek-ai/dsh-command-goal': (
    name: 'goal',
    label: appL10n.stateGoalLabel,
    description: appL10n.stateCommandGoalDescription,
    hint: appL10n.stateCommandGoalHint,
  ),
  '@deepseek-ai/dsh-command-feedback': (
    name: 'feedback',
    label: appL10n.stateFeedbackLabel,
    description: appL10n.stateCommandFeedbackDescription,
    hint: appL10n.stateCommandFeedbackHint,
  ),
};

/// The Host's `/export` asks for a browser download the app can't receive;
/// the app's own `/export` ([appSlashCommands]) fetches the ZIP instead.
const _hiddenCommands = {'export'};

/// Palette order: app commands, then the first-party ones in this order,
/// then anything else in catalog order.
const _order = ['new', 'model', 'compact', 'permission', 'plan', 'goal', 'feedback', 'export', 'features'];

/// Parses one `CommandDescriptor` (`commands/list` item); null when unusable.
SlashCommand? slashCommandFromJson(Object? json) {
  if (json is! Map) return null;
  final name = json['name'];
  if (name is! String || name.isEmpty) return null;
  final description = json['description'];
  final input = json['input'];
  final definitionId = json['definitionId'];
  final hostHint = input is Map && input['hint'] is String ? input['hint'] as String : null;
  final attachments = input is Map && input['attachments'] == true;
  final face = definitionId is String
      ? _firstParty[definitionId]
      : _firstParty.values.where((f) => f.name == name).firstOrNull;
  if (face != null && face.name == name) {
    return SlashCommand(
      name: name,
      label: face.label,
      description: face.description,
      // Keep "takes input" exactly as the Host declares it.
      hint: input is Map ? (face.hint ?? hostHint) : null,
      acceptsAttachments: attachments,
    );
  }
  return SlashCommand(
    name: name,
    label: name,
    description: description is String ? description : '',
    hint: input is Map ? (hostHint ?? '') : null,
    acceptsAttachments: attachments,
  );
}

/// `commands/list` result → host commands (Web-only ones dropped).
List<SlashCommand> parseCommandList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (slashCommandFromJson(item) case final command? when !_hiddenCommands.contains(command.name)) command,
  ];
}

/// App commands + [host] + [skills], in palette order; a host command never
/// shadows an app one with the same name, and a skill never shadows either.
List<SlashCommand> mergeSlashCommands(List<SlashCommand> host, {List<SlashCommand> skills = const []}) {
  final appNames = {for (final c in appSlashCommands) c.name};
  final hostNames = {for (final c in host) c.name};
  final all = [
    ...appSlashCommands,
    for (final c in host)
      if (!appNames.contains(c.name)) c,
    for (final c in skills)
      if (!appNames.contains(c.name) && !hostNames.contains(c.name)) c,
  ];
  int rank(SlashCommand c) {
    final i = _order.indexOf(c.name);
    return i < 0 ? _order.length : i;
  }

  final indexed = all.indexed.toList()
    ..sort((a, b) {
      final byRank = rank(a.$2).compareTo(rank(b.$2));
      return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
    });
  return [for (final (_, c) in indexed) c];
}

/// What the composer holds when it starts with `/`.
class SlashInput {
  const SlashInput(this.token, this.rest);

  /// The typed name after the slash (may be empty or partial).
  final String token;

  /// Everything after the name, separator included; null = still typing it.
  final String? rest;

  bool get hasArgs => rest != null;
}

/// Parses a composer value as a command line (slash as the first token,
/// then a name up to the first whitespace); null when it is not one.
SlashInput? parseSlashInput(String text) {
  text = text.trimLeft();
  if (!text.startsWith('/')) return null;
  final match = RegExp(r'\s').firstMatch(text);
  if (match == null) return SlashInput(text.substring(1), null);
  return SlashInput(text.substring(1, match.start), text.substring(match.start));
}

/// Palette filter: name prefix, then title prefix, then substring, then
/// ordered subsequence of the name; ties keep palette order.
List<SlashCommand> filterSlashCommands(List<SlashCommand> all, String token) {
  final query = token.trim().toLowerCase();
  if (query.isEmpty) return all;
  int? score(SlashCommand c) {
    final name = c.name.toLowerCase();
    final label = c.label.toLowerCase();
    if (name.startsWith(query)) return 0;
    if (label.startsWith(query)) return 1;
    if (name.contains(query) || label.contains(query)) return 2;
    if (_isSubsequence(query, name)) return 3;
    return null;
  }

  final scored = <(int, int, SlashCommand)>[
    for (final (i, c) in all.indexed)
      if (score(c) case final s?) (s, i, c),
  ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  return [for (final (_, _, c) in scored) c];
}

/// The command [token] names exactly (by name or Chinese title), if any.
SlashCommand? resolveSlashCommand(List<SlashCommand> all, String token) {
  final query = token.trim().toLowerCase();
  if (query.isEmpty) return null;
  for (final c in all) {
    if (c.name.toLowerCase() == query || c.label.toLowerCase() == query) {
      return c;
    }
  }
  return null;
}

bool _isSubsequence(String needle, String haystack) {
  var i = 0;
  for (var j = 0; j < haystack.length && i < needle.length; j++) {
    if (haystack.codeUnitAt(j) == needle.codeUnitAt(i)) i++;
  }
  return i == needle.length;
}

/// Last catalog per host: the new-chat palette never borrows another host's
/// plugin commands.
final Map<HostRef, List<SlashCommand>> _lastHostCommands = {};

/// `commands/list` for [sessionId] (null = new chat: the last known list).
///
/// Re-fetched when the Host reports `commands/change` (a plugin registered or
/// dropped a command) or `agent-preset/selected`. Failures are quiet: the
/// palette still offers the app commands.
final hostCommandsProvider = FutureProvider.autoDispose.family<List<SlashCommand>, String?>((ref, sessionId) async {
  final conn = ref.watch(activeConnectionProvider).value;
  final host = ref.watch(activeHostProvider);
  if (conn == null) return const [];
  if (sessionId == null) return _lastHostCommands[host] ?? const [];
  final sub = conn.client.hostEvents.listen((event) {
    if (event is HostReadyEvent ||
        (event is UnknownHostEvent && (event.event == 'commands/change' || event.event == 'agent-preset/selected'))) {
      ref.invalidateSelf();
    }
  });
  ref.onDispose(() => unawaited(sub.cancel()));
  try {
    final value = await conn.client.rpc.call('commands/list', {'agentId': sessionId});
    final commands = parseCommandList(value);
    // A retired request must not replace the catalog used by new chats.
    if (ref.mounted) _lastHostCommands[host] = commands;
    return commands;
  } catch (_) {
    return _lastHostCommands[host] ?? const [];
  }
});

/// The session's skills as palette rows (none for a new chat).
final skillCommandsProvider = Provider.autoDispose.family<List<SlashCommand>, String?>((ref, sessionId) {
  if (sessionId == null) return const [];
  final skills = ref.watch(skillsProvider(sessionId)).value ?? const [];
  return [
    for (final s in skills)
      SlashCommand(name: s.name, label: s.name, description: s.description, hint: '', kind: SlashCommandKind.skill),
  ];
});

/// Everything the palette offers for [sessionId].
final slashCommandsProvider = Provider.autoDispose.family<List<SlashCommand>, String?>((ref, sessionId) {
  final host = ref.watch(hostCommandsProvider(sessionId)).value ?? const [];
  return mergeSlashCommands(host, skills: ref.watch(skillCommandsProvider(sessionId)));
});
