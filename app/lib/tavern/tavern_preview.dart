// A stand-in [Tavern] for building the screens before the engine
// (packages/dsh_tavern, Pro's T8) lands: two sample characters, an in-memory
// tree, and canned replies that stream like a model. Nothing is stored and no
// model is called; the chat page says so ([TavernPreview] → 预览 banner).

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';

/// Marks the stand-in, so the screens can say replies are samples.
abstract interface class TavernPreview {}

class PreviewTavern implements Tavern, TavernPreview {
  PreviewTavern({DateTime Function()? clock, this.tick = const Duration(milliseconds: 28)})
    : _clock = clock ?? DateTime.now {
    final now = _clock();
    for (final c in _samples) {
      _characters[c.id] = _Char(c, now);
    }
  }

  final DateTime Function() _clock;

  /// Time between streamed pieces.
  final Duration tick;

  final _characters = <String, _Char>{};
  final _chats = <String, _Chat>{};
  final _listChanged = StreamController<void>.broadcast();
  final _running = <String, StreamController<TavernEvent>>{};
  var _seq = 0;

  String _id(String prefix) => '$prefix-${++_seq}';

  /// Card scripts (P2 B1) are not simulated here: the bridge says so.
  @override
  late final TavernScriptBridge scripts = _PreviewScripts();

  // Library -------------------------------------------------------------------

  /// The list as the engine gives it (T23): the long fields left out, which
  /// [character] fills in.
  List<TavernCharacter> _characterList() {
    final list = _characters.values.map((c) => _view(c, summary: true)).toList()
      ..sort((a, b) => (b.lastChatAt ?? b.importedAt!).compareTo(a.lastChatAt ?? a.importedAt!));
    return list;
  }

  TavernCharacter _view(_Char c, {bool summary = false}) {
    final chats = _chats.values.where((chat) => chat.characterId == c.id).toList();
    DateTime? last;
    for (final chat in chats) {
      if (last == null || chat.updatedAt.isAfter(last)) last = chat.updatedAt;
    }
    return TavernCharacter(
      id: c.id,
      name: c.name,
      creator: c.creator,
      tags: c.tags,
      description: summary ? '' : c.description,
      creatorNotes: summary ? '' : c.creatorNotes,
      greetings: summary ? const [] : c.greetings,
      hasLorebook: c.data['character_book'] is Map,
      theme: summary ? null : _copySetting(_dshgoOf(c.data)['theme']),
      chatCount: chats.length,
      lastChatAt: last,
      importedAt: c.importedAt,
    );
  }

  Stream<T> _watch<T>(T Function() read) async* {
    yield read();
    yield* _listChanged.stream.map((_) => read());
  }

  @override
  Stream<List<TavernCharacter>> watchCharacters() => _watch(_characterList);

  @override
  Future<TavernCharacter?> character(String id) async => switch (_characters[id]) {
    final c? => _view(c),
    null => null,
  };

  @override
  Future<TavernCharacter> importCard(Uint8List bytes, {String? fileName}) async =>
      throw const TavernImportError('preview');

  @override
  Future<Uint8List> exportCard(String characterId, {TavernCardFormat format = TavernCardFormat.png}) async =>
      throw UnsupportedError('preview');

  @override
  Future<void> deleteCharacter(String characterId) async {
    _characters.remove(characterId);
    _chats.removeWhere((_, chat) => chat.characterId == characterId);
    _listChanged.add(null);
  }

  static const _editableTexts = {
    'name',
    'nickname',
    'description',
    'personality',
    'scenario',
    'first_mes',
    'mes_example',
    'system_prompt',
    'post_history_instructions',
    'creator_notes',
    'creator',
    'character_version',
  };

  @override
  Future<Map<String, Object?>?> characterFields(String characterId) async => switch (_characters[characterId]) {
    final c? => _copy(c.data),
    null => null,
  };

  @override
  Future<TavernCharacter> updateCharacterFields(String characterId, Map<String, Object?> fields) async {
    final c = _characters[characterId];
    if (c == null) throw const TavernImportError('missing character');
    for (final MapEntry(:key, :value) in fields.entries) {
      final ok = _editableTexts.contains(key)
          ? value is String
          : (key == 'alternate_greetings' || key == 'tags') && value is List && value.every((v) => v is String);
      if (!ok) throw ArgumentError.value(value, key);
    }
    for (final MapEntry(:key, :value) in fields.entries) {
      c.data[key] = value is List ? [...value] : value;
    }
    _listChanged.add(null);
    return _view(c);
  }

  static Map<String, Object?> _copy(Map<String, Object?> data) => {
    for (final MapEntry(:key, :value) in data.entries)
      key: switch (value) {
        final List l => [...l],
        final Map<String, Object?> m => _copy(m),
        _ => value,
      },
  };

  /// Canned replies assemble no prompt: there is nothing to inspect.
  @override
  Future<TavernTurnInspection?> inspectTurn(String chatId, {String? nodeId}) async => null;

  // Stage one's tools: the preview keeps none, and says so rather than
  // making up a roll, a receipt or a saved setting.

  Future<T> _noTool<T>(String operation, {String? chatId}) => Future<T>.error(
    TavernToolException(
      code: TavernToolErrorCode.unsupportedCapability,
      operation: operation,
      message: 'The preview keeps no tool executions.',
      committed: false,
      chatId: chatId,
    ),
  );

  @override
  Future<TavernToolTurnSnapshot?> readToolTurn(String logicalTurnId) => _noTool('readToolTurn');

  @override
  Future<TavernToolReceipt?> readToolReceipt(String executionId) => _noTool('readToolReceipt');

  @override
  Future<List<TavernToolTurnSummary>> recentToolTurns(String chatId, {int limit = 20}) =>
      _noTool('recentToolTurns', chatId: chatId);

  // 做卡草稿 (stage 2A): the preview keeps none; there is nothing to list or
  // read, and nothing is made up for a draft that would be written.
  static Future<T> _noDraft<T>() => Future<T>.error(UnsupportedError('The preview keeps no authoring drafts.'));

  @override
  Future<List<TavernAuthoringDraftSummary>> listAuthoringDrafts() async => const [];

  @override
  Future<TavernAuthoringDraft?> readAuthoringDraft(String draftId) async => null;

  @override
  TavernAuthoringRun startAuthoringRun(
    TavernAuthoringRunRequest request, {
    TavernAuthoringPromptHost? promptHost,
    TavernAuthoringPreviewHost? renderHost,
  }) => throw UnsupportedError('The preview runs no authoring.');

  @override
  TavernAuthoringTask<TavernAuthoringPromptPreview> previewAuthoringPrompt(
    TavernAuthoringPromptRequest request, {
    TavernAuthoringPromptHost? host,
  }) => throw UnsupportedError('The preview runs no authoring.');

  @override
  TavernAuthoringSimulationTask simulateAuthoringDraft(TavernAuthoringSimulationRequest request) =>
      throw UnsupportedError('The preview runs no authoring.');

  @override
  TavernAuthoringTask<TavernAuthoringRenderResult> renderAuthoringDraft(
    TavernAuthoringRenderRequest request, {
    required TavernAuthoringPreviewHost host,
  }) => throw UnsupportedError('The preview runs no authoring.');

  @override
  Future<TavernAuthoringRunSnapshot?> readAuthoringRun(String runId) async => null;

  @override
  Future<List<TavernAuthoringRunSummary>> listAuthoringRuns({
    String? draftId,
    int limit = 30,
    String? beforeRunId,
  }) async => const [];

  @override
  Future<TavernAuthoringToolReceipt?> readAuthoringToolReceipt(String runId, String receiptId) async => null;

  @override
  Future<void> cancelAuthoringRun(String runId) => _noDraft();

  @override
  Future<TavernAuthoringDraft> createAuthoringSeed(TavernAuthoringSeedInput input) => _noDraft();

  @override
  Future<TavernAuthoringSaveAsReceipt> saveAuthoringAsNew(
    String draftId, {
    required int draftRevision,
    required String physicalResourceId,
    required List<String> changeIds,
    required String operationId,
    required TavernAuthoringMediaSelection media,
    String? domainId,
  }) => _noDraft();

  @override
  Future<TavernAuthoringReceipt> applyAuthoringChanges(
    String draftId, {
    required int draftRevision,
    required String physicalResourceId,
    required List<String> changeIds,
    required TavernAuthorityRevision expectedAuthorityRevision,
    required String operationId,
  }) => _noDraft();

  @override
  Future<TavernAuthoringOperation?> readAuthoringOperation(String operationId, {required String domainId}) async =>
      null;

  @override
  Future<List<TavernAuthoringRevisionSummary>> listAuthoringRevisions(String physicalResourceId) async => const [];

  @override
  Future<TavernAuthoringReceipt> restoreAuthoringRevision(
    String physicalResourceId, {
    required TavernAuthorityRevision revision,
    required TavernAuthorityRevision expectedAuthorityRevision,
    required String operationId,
  }) => _noDraft();

  @override
  Future<TavernAuthoringDraft> createAuthoringDraft(List<TavernAuthoringTarget> targets) => _noDraft();

  // The preview keeps no gameplay packs: none listed or read, none taken in.
  static Future<T> _noPack<T>() => Future<T>.error(UnsupportedError('The preview keeps no gameplay packs.'));

  @override
  Future<TavernCastImportResult> importDshgoCastMember(
    TavernCastSource source,
    String localCastId, {
    required String operationId,
    String? domainId,
  }) => _noPack();

  @override
  Future<TavernCastImportResult?> readDshgoCastImport(String domainId, String operationId) async => null;

  @override
  Future<TavernGameplayExportPreview> previewGameplayExport(TavernGameplayExportRequest request) => _noPack();

  @override
  Future<Uint8List> exportCharacterWithPacks(
    TavernGameplayExportRequest request, {
    required String expectedPreviewId,
  }) => _noPack();

  @override
  Future<Uint8List> exportGameplayPackFromDraft(
    TavernGameplayExportRequest request, {
    required String expectedPreviewId,
  }) => _noPack();

  @override
  Future<TavernPackScopeSnapshot> readGameplayBindings(TavernPackScopeTarget scope) => _noPack();

  @override
  Future<TavernPackBindingReceipt> updateGameplayBindings(
    TavernPackScopeTarget scope, {
    required TavernGameplayRevision expected,
    required String operationId,
    required List<TavernPackBindingEdit> edits,
  }) => _noPack();

  @override
  Future<TavernGameplayResolution> resolveGameplayConfig(
    TavernGameplayContext context, {
    List<TavernPackScopePreview> proposedScopes = const [],
    bool validateCurrentState = false,
  }) => _noPack();

  @override
  Future<TavernPackImportResult> importGameplayPack(Uint8List bytes) => _noPack();

  @override
  Future<List<TavernPackVersion>> listGameplayPacks({bool includeRemoved = false}) async => const [];

  @override
  Future<TavernPackVersion?> readGameplayPack(TavernPackVersionRef ref) async => null;

  @override
  Future<TavernPackResource?> readGameplayPackResource(TavernPackVersionRef ref, String localId) async => null;

  @override
  Future<Uint8List> exportInstalledGameplayPack(TavernPackVersionRef ref) => _noPack();

  @override
  Future<TavernPackRemovalReceipt> removeGameplayPackVersion(
    TavernPackVersionRef ref, {
    required TavernGameplayRevision expected,
    required String operationId,
  }) => _noPack();

  @override
  Future<TavernAuthoringDraft> editAuthoringDraft(
    String draftId, {
    required int draftRevision,
    required List<TavernAuthoringChange> changes,
  }) => _noDraft();

  @override
  Future<TavernAuthoringDraft> rebaseAuthoringDraft(
    String draftId, {
    required int draftRevision,
    required List<TavernAuthoringChange> changes,
  }) => _noDraft();

  @override
  Future<void> deleteAuthoringDraft(String draftId, {required int draftRevision}) => _noDraft();

  @override
  Future<TavernAuthoringPreview> previewAuthoringDraft(
    String draftId, {
    required int draftRevision,
    required List<String> changeIds,
  }) => _noDraft();

  @override
  Future<TavernAuthoringRegexTest> testAuthoringRegex(
    String draftId, {
    required int draftRevision,
    required List<String> changeIds,
    required String physicalResourceId,
    required String scriptPath,
    required String text,
  }) => _noDraft();

  /// The engine sums in one query; the preview adds up its line, a page at
  /// a time through [path] (as a test's line overrides it), the same way.
  @override
  Future<List<TavernPathUsage>> pathUsage(String chatId) async {
    final buckets = <(String?, int, int), List<int>>{};
    String? before;
    while (true) {
      final page = await path(chatId, limit: 200, beforeNodeId: before);
      for (final m in page) {
        final usage = m.reportedUsage;
        if (m.role != TavernRole.character || usage == null) continue;
        final at = m.at.toUtc();
        final sum = buckets[(usage.model, at.weekday, at.hour)] ??= [0, 0, 0, 0];
        sum[0] += usage.promptTokens;
        sum[1] += usage.cacheHitTokens;
        sum[2] += usage.completionTokens;
        sum[3]++;
      }
      if (page.length < 200) break;
      before = page.first.nodeId;
    }
    return [
      for (final MapEntry(key: (model, weekday, hour), value: sum) in buckets.entries)
        TavernPathUsage(
          model: model,
          utcWeekday: weekday,
          utcHour: hour,
          promptTokens: sum[0],
          cacheHitTokens: sum[1],
          completionTokens: sum[2],
          replyCount: sum[3],
        ),
    ];
  }

  @override
  Future<TavernToolReceipt> rollDice(
    String chatId, {
    required String actionId,
    required String dice,
    String? label,
    int? target,
    String? expectedNodeId,
  }) => _noTool('rollDice', chatId: chatId);

  @override
  Future<TavernMemoryDecisionReceipt> resolveMemoryProposal(
    String proposalId, {
    required String decisionId,
    required int expectedVersion,
    required TavernMemoryDecision decision,
    required TavernToolContextAnchor expectedContextAnchor,
  }) => _noTool('resolveMemoryProposal');

  @override
  Future<TavernToolPolicySnapshot> readToolPolicy({String? chatId}) => _noTool('readToolPolicy', chatId: chatId);

  @override
  Future<TavernToolPolicyWriteResult> setToolPolicy(Map<String, Object?> patch, {String? chatId}) =>
      _noTool('setToolPolicy', chatId: chatId);

  // Personas ------------------------------------------------------------------

  final _personas = <String, TavernPersona>{};
  final _bindings = <String, String>{};
  String? _defaultPersona;

  List<TavernPersona> _personaList() => _personas.values.toList();

  @override
  Stream<List<TavernPersona>> watchPersonas() => _watch(_personaList);

  @override
  Future<TavernPersona?> persona(String personaId) async => _personas[personaId];

  @override
  Future<TavernPersona> createPersona({
    required String name,
    String description = '',
    String? avatarPath,
    int descriptionPosition = PersonaDescriptionPosition.inPrompt,
  }) async {
    final persona = TavernPersona(
      id: _id('persona'),
      name: name,
      description: description,
      avatarPath: avatarPath,
      descriptionPosition: descriptionPosition,
    );
    _personas[persona.id] = persona;
    _listChanged.add(null);
    return persona;
  }

  @override
  Future<TavernPersona> updatePersona(
    String personaId, {
    String? name,
    String? description,
    String? avatarPath,
    bool clearAvatar = false,
    int? descriptionPosition,
  }) async {
    final persona = _personas[personaId]!.copyWith(
      name: name,
      description: description,
      avatarPath: avatarPath,
      clearAvatar: clearAvatar,
      descriptionPosition: descriptionPosition,
    );
    _personas[personaId] = persona;
    _listChanged.add(null);
    return persona;
  }

  @override
  Future<void> deletePersona(String personaId) async {
    _personas.remove(personaId);
    _bindings.removeWhere((_, id) => id == personaId);
    if (_defaultPersona == personaId) _defaultPersona = null;
    _listChanged.add(null);
  }

  @override
  Future<PersonaSelection> personaSelection({String? chatId}) async {
    final bound = chatId == null ? null : _bindings[chatId];
    final fallback = _defaultPersona;
    final persona = _personas[bound] ?? _personas[fallback];
    return PersonaSelection(
      persona: persona,
      source: _personas[bound] != null
          ? PersonaSelectionSource.chat
          : persona != null
          ? PersonaSelectionSource.globalDefault
          : PersonaSelectionSource.none,
      boundPersonaId: _personas.containsKey(bound) ? bound : null,
      defaultPersonaId: fallback,
    );
  }

  @override
  Future<void> setDefaultPersona(String? personaId) async {
    _defaultPersona = personaId;
    _listChanged.add(null);
  }

  @override
  Future<void> bindPersona(String chatId, String? personaId) async {
    if (personaId == null) {
      _bindings.remove(chatId);
    } else {
      _bindings[chatId] = personaId;
    }
    _listChanged.add(null);
  }

  // Chats ---------------------------------------------------------------------

  @override
  Stream<List<TavernChatSummary>> watchChats({String? characterId}) => _watch(() {
    final list = [
      for (final chat in _chats.values)
        if (characterId == null ||
            chat.characterId == characterId ||
            (_groups[chat.id]?.members.any((m) => m.characterId == characterId) ?? false))
          _summary(chat),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  });

  TavernChatSummary _summary(_Chat chat) {
    final path = chat.path();
    final group = _groups[chat.id];
    return TavernChatSummary(
      id: chat.id,
      characterId: chat.characterId,
      title: group?.title ?? chat.title,
      updatedAt: chat.updatedAt,
      lastText: path.isEmpty ? null : path.last.text,
      messageCount: path.length,
      kind: group == null ? TavernChatKind.single : TavernChatKind.group,
      memberCharacterIds: [for (final m in group?.members ?? const <TavernGroupMember>[]) m.characterId],
    );
  }

  // Group chats (engine P2 125), in memory: the roster and its settings, and
  // a batch that has each planned member reply in turn on the shared path.
  // The plan is simpler than the engine's: 列表 and 自然 both take the
  // unmuted members in order (自然 puts one named in your line first), 随机
  // the next who has not spoken since your line, 手动 no one unless named.

  final _groups = <String, _Group>{};

  _Group _group(String chatId) =>
      _groups[chatId] ?? (throw TavernGroupException(TavernGroupError.notGroup, chatId: chatId));

  TavernGroupChat _changed(_Group group) {
    _listChanged.add(null);
    return group.view();
  }

  @override
  Future<String> createGroupChat(
    List<String> characterIds, {
    String? hostCharacterId,
    String? title,
    TavernGroupActivation activation = TavernGroupActivation.natural,
    int maxSpeakersPerTurn = 3,
    bool allowSelfResponses = false,
    bool addGreetings = true,
  }) async {
    final ids = List<String>.of(characterIds);
    if (ids.toSet().length != ids.length) throw TavernGroupException(TavernGroupError.invalidMembers);
    for (final id in [...ids, ?hostCharacterId]) {
      if (!_characters.containsKey(id)) throw TavernGroupException(TavernGroupError.characterNotFound, characterId: id);
    }
    final host =
        hostCharacterId ?? (ids.isEmpty ? throw TavernGroupException(TavernGroupError.invalidMembers) : ids.first);
    if (maxSpeakersPerTurn < 1) throw TavernGroupException(TavernGroupError.invalidLimit);
    final now = _clock();
    final name = title ?? [for (final id in ids) _characters[id]!.name].join('、');
    final chat = _Chat(_id('chat'), host, name, now);
    _chats[chat.id] = chat;
    _groups[chat.id] = _Group(
      chat.id,
      name,
      host,
      [
        for (final id in ids)
          TavernGroupMember(characterId: id, talkativeness: 0.5, muted: false, modelRole: TavernGroupModelRole.main),
      ],
      activation,
      maxSpeakersPerTurn,
      allowSelfResponses,
    );
    if (addGreetings) {
      String? parent;
      for (final id in ids) {
        final c = _characters[id]!;
        if (c.greetings.isEmpty) continue;
        final node = _Node(_id('n'), parent, TavernRole.character, c.name, c.greetings.first, now)..speakerId = id;
        chat.add(node);
        chat.chosen[parent] = node.id;
        parent = node.id;
      }
    }
    _listChanged.add(null);
    return chat.id;
  }

  @override
  Future<TavernGroupChat?> groupChat(String chatId) async => _groups[chatId]?.view();

  @override
  Stream<TavernGroupChat?> watchGroupChat(String chatId) => _watch(() => _groups[chatId]?.view());

  @override
  Future<TavernGroupChat> addGroupMember(
    String chatId,
    String characterId, {
    double? talkativeness,
    bool muted = false,
    TavernGroupModelRole? modelRole,
  }) async {
    final group = _group(chatId);
    if (!_characters.containsKey(characterId)) {
      throw TavernGroupException(TavernGroupError.characterNotFound, chatId: chatId, characterId: characterId);
    }
    if (group.members.any((m) => m.characterId == characterId)) {
      throw TavernGroupException(TavernGroupError.memberExists, chatId: chatId, characterId: characterId);
    }
    if (talkativeness != null && !(talkativeness >= 0 && talkativeness <= 1)) {
      throw TavernGroupException(TavernGroupError.invalidTalkativeness, chatId: chatId, characterId: characterId);
    }
    group.members = [
      ...group.members,
      TavernGroupMember(
        characterId: characterId,
        talkativeness: talkativeness ?? 0.5,
        muted: muted,
        modelRole: modelRole ?? TavernGroupModelRole.main,
      ),
    ];
    return _changed(group);
  }

  @override
  Future<TavernGroupChat> updateGroupMember(
    String chatId,
    String characterId, {
    double? talkativeness,
    bool? muted,
    TavernGroupModelRole? modelRole,
  }) async {
    final group = _group(chatId);
    final at = group.members.indexWhere((m) => m.characterId == characterId);
    if (at < 0) throw TavernGroupException(TavernGroupError.memberNotFound, chatId: chatId, characterId: characterId);
    if (talkativeness != null && !(talkativeness >= 0 && talkativeness <= 1)) {
      throw TavernGroupException(TavernGroupError.invalidTalkativeness, chatId: chatId, characterId: characterId);
    }
    final old = group.members[at];
    group.members = [
      for (final (i, m) in group.members.indexed)
        if (i == at)
          TavernGroupMember(
            characterId: old.characterId,
            talkativeness: talkativeness ?? old.talkativeness,
            muted: muted ?? old.muted,
            modelRole: modelRole ?? old.modelRole,
          )
        else
          m,
    ];
    return _changed(group);
  }

  @override
  Future<TavernGroupChat> removeGroupMember(String chatId, String characterId) async {
    final group = _group(chatId);
    if (!group.members.any((m) => m.characterId == characterId)) {
      throw TavernGroupException(TavernGroupError.memberNotFound, chatId: chatId, characterId: characterId);
    }
    group.members = [
      for (final m in group.members)
        if (m.characterId != characterId) m,
    ];
    return _changed(group);
  }

  @override
  Future<TavernGroupChat> reorderGroupMembers(String chatId, List<String> characterIds) async {
    final group = _group(chatId);
    final ids = List<String>.of(characterIds);
    final now = {for (final m in group.members) m.characterId: m};
    if (ids.length != now.length || !ids.every(now.containsKey) || ids.toSet().length != ids.length) {
      throw TavernGroupException(TavernGroupError.invalidOrder, chatId: chatId);
    }
    group.members = [for (final id in ids) now[id]!];
    return _changed(group);
  }

  @override
  Future<TavernGroupChat> updateGroupChat(
    String chatId, {
    String? title,
    TavernGroupActivation? activation,
    int? maxSpeakersPerTurn,
    bool? allowSelfResponses,
  }) async {
    final group = _group(chatId);
    if (maxSpeakersPerTurn != null && maxSpeakersPerTurn < 1) {
      throw TavernGroupException(TavernGroupError.invalidLimit, chatId: chatId);
    }
    group
      ..title = title ?? group.title
      ..activation = activation ?? group.activation
      ..maxSpeakers = maxSpeakersPerTurn ?? group.maxSpeakers
      ..allowSelf = allowSelfResponses ?? group.allowSelf;
    return _changed(group);
  }

  /// Who replies to [text] in [group], in order.
  List<String> _plan(_Group group, _Chat chat, String text) {
    final ready = [
      for (final m in group.members)
        if (!m.muted && _characters.containsKey(m.characterId)) m.characterId,
    ];
    switch (group.activation) {
      case TavernGroupActivation.manual:
        return const [];
      case TavernGroupActivation.randomPool:
        // The next who has not spoken since your line before this one (the
        // line just sent is passed over, so the members take turns).
        final spoken = <String>{};
        var replies = false;
        for (final m in chat.path().reversed) {
          if (m.role == TavernRole.user) {
            if (replies) break;
            continue;
          }
          replies = true;
          if (m.speakerCharacterId case final id?) spoken.add(id);
        }
        final next = ready.where((id) => !spoken.contains(id)).firstOrNull ?? ready.firstOrNull;
        return [?next];
      case TavernGroupActivation.natural:
        final named = ready.where((id) => text.contains(_characters[id]!.name)).toList();
        return [...named, ...ready.where((id) => !named.contains(id))].take(group.maxSpeakers).toList();
      case TavernGroupActivation.listOrder:
      case TavernGroupActivation.director:
        return ready.take(group.maxSpeakers).toList();
    }
  }

  @override
  Stream<TavernGroupEvent> sendGroup(String chatId, String text, {String? speakerCharacterId}) {
    final group = _groups[chatId];
    if (group == null) return Stream.error(TavernGroupException(TavernGroupError.notGroup, chatId: chatId));
    final out = StreamController<TavernGroupEvent>();
    // As the engine: listening admits the batch.
    out.onListen = () => unawaited(_runGroup(group, text, speakerCharacterId, out));
    return out.stream;
  }

  Future<void> _runGroup(_Group group, String text, String? explicit, StreamController<TavernGroupEvent> out) async {
    final chat = _chats[group.chatId]!;
    final live = group.live = StreamController<TavernGroupEvent>.broadcast();
    void emit(TavernGroupEvent event) {
      if (!out.isClosed) out.add(event);
      live.add(event);
    }

    final roundId = _id('round');
    final startedAt = _clock();
    var parent = chat.tail()?.id;
    String? userNode;
    if (text.trim().isNotEmpty) {
      final user = _Node(_id('n'), parent, TavernRole.user, 'You', text, startedAt);
      chat.add(user);
      chat.chosen[parent] = user.id;
      parent = userNode = user.id;
      chat.changes.add(null);
    }
    final plan = explicit != null ? [explicit] : _plan(group, chat, text);
    final done = <String>[];
    TavernGroupProgress progress(
      TavernGroupPhase phase, {
      required List<String> remaining,
      String? speaker,
      String? reply,
      String? generation,
    }) => group.progress = TavernGroupProgress(
      chatId: group.chatId,
      roundId: roundId,
      startedAt: startedAt,
      phase: phase,
      userNodeId: userNode,
      speakerCharacterId: speaker,
      replyNodeId: reply,
      generationId: generation,
      plannedCharacterIds: plan,
      remainingCharacterIds: remaining,
      completedNodeIds: List.of(done),
    );
    Future<void> finish(
      TavernGroupEndReason reason,
      TavernGroupProgress at, {
      String? attempted,
      TavernMessage? partial,
    }) async {
      emit(
        TavernGroupFinished(
          chatId: group.chatId,
          reason: reason,
          progress: at,
          attemptedCharacterId: attempted,
          partial: partial,
        ),
      );
      group
        ..live = null
        ..progress = null
        ..current = null;
      _listChanged.add(null);
      await live.close();
      if (!out.isClosed) await out.close();
    }

    emit(TavernGroupStarted(progress(TavernGroupPhase.preparing, remaining: plan)));
    if (plan.isEmpty) {
      await finish(TavernGroupEndReason.noSpeakers, progress(TavernGroupPhase.finished, remaining: const []));
      return;
    }
    emit(TavernGroupProgressChanged(progress(TavernGroupPhase.ready, remaining: plan)));
    for (var i = 0; i < plan.length; i++) {
      final actorId = plan[i];
      final actor = _characters[actorId];
      final rest = plan.sublist(i + 1);
      if (actor == null) {
        await finish(
          TavernGroupEndReason.failed,
          progress(TavernGroupPhase.finished, remaining: rest),
          attempted: actorId,
        );
        return;
      }
      final node = _Node(_id('n'), parent, TavernRole.character, actor.name, '', _clock())..speakerId = actorId;
      chat.add(node);
      chat.chosen[parent] = node.id;
      group.current = node;
      final speaking = progress(
        TavernGroupPhase.speaking,
        remaining: rest,
        speaker: actorId,
        reply: node.id,
        generation: _id('gen'),
      );
      emit(TavernGroupProgressChanged(speaking));
      TavernEvent? last;
      await for (final event in _stream(
        chat,
        node,
        i == 0 ? _cannedFor(text) : _canned[(_seq++) % _canned.length],
        fresh: true,
      )) {
        last = event;
        emit(TavernGroupMemberEvent(progress: speaking, characterId: actorId, event: event));
      }
      if (last is! TavernTurnDone) {
        await finish(
          TavernGroupEndReason.cancelled,
          progress(TavernGroupPhase.finished, remaining: rest),
          attempted: actorId,
          partial: chat.message(node),
        );
        return;
      }
      done.add(node.id);
      parent = node.id;
      emit(
        TavernGroupProgressChanged(
          progress(TavernGroupPhase.settling, remaining: rest, speaker: actorId, reply: node.id),
        ),
      );
    }
    await finish(TavernGroupEndReason.completed, progress(TavernGroupPhase.finished, remaining: const []));
  }

  /// The batch now (with the reply being written) and what follows, taken
  /// together so nothing falls between; nothing when no batch runs. Never
  /// starts one.
  @override
  Stream<TavernGroupEvent> resumeGroupTurn(String chatId) {
    final group = _groups[chatId];
    final live = group?.live;
    final now = group?.progress;
    if (group == null || live == null || now == null) return const Stream.empty();
    final current = group.current;
    final out = StreamController<TavernGroupEvent>()
      ..add(TavernGroupSnapshot(progress: now, message: current == null ? null : _chats[chatId]!.message(current)));
    final following = live.stream.listen(out.add, onDone: out.close);
    out.onCancel = following.cancel;
    return out.stream;
  }

  @override
  Future<String> createChat(String characterId, {int greeting = 0}) async {
    final c = _characters[characterId]!;
    final now = _clock();
    final chat = _Chat(_id('chat'), characterId, c.name, now);
    final greetings = c.greetings;
    for (var i = 0; i < greetings.length; i++) {
      chat.add(_Node(_id('n'), null, TavernRole.character, c.name, greetings[i], now));
    }
    chat.chosen[null] = chat.children(null)[greeting.clamp(0, greetings.length - 1)].id;
    _chats[chat.id] = chat;
    _listChanged.add(null);
    return chat.id;
  }

  /// The samples have no ST chat files to read or write.
  @override
  Future<TavernChatImportResult> importChats(
    String characterId,
    List<TavernChatFile> files, {
    Map<String, String> lorebookIds = const {},
  }) async => throw UnsupportedError('preview');

  @override
  Future<List<TavernChatFile>> exportChat(String chatId, {String? fileName}) async => throw UnsupportedError('preview');

  @override
  Future<List<TavernDeepSeekSession>> inspectDeepSeekExport(String zipPath) async => throw UnsupportedError('preview');

  @override
  Future<List<TavernDeepSeekImported>> importDeepSeekSessions(String zipPath, List<String> sessionIds) async =>
      throw UnsupportedError('preview');

  @override
  Future<void> deleteChat(String chatId) async {
    _chats.remove(chatId);
    _listChanged.add(null);
  }

  @override
  Future<List<TavernMessage>> path(String chatId, {int limit = 60, String? beforeNodeId}) async {
    final all = _chats[chatId]!.path();
    var end = all.length;
    if (beforeNodeId != null) end = all.indexWhere((m) => m.nodeId == beforeNodeId).clamp(0, all.length);
    return all.sublist(math.max(0, end - limit), end);
  }

  @override
  Stream<void> pathChanges(String chatId) => _chats[chatId]!.changes.stream;

  // Turns ---------------------------------------------------------------------

  @override
  Stream<TavernEvent> send(String chatId, String text) {
    final chat = _chats[chatId]!;
    final tail = chat.tail();
    var parent = tail?.id;
    if (text.trim().isNotEmpty) {
      final user = _Node(_id('n'), parent, TavernRole.user, 'You', text, _clock());
      chat.add(user);
      chat.chosen[parent] = user.id;
      parent = user.id;
    }
    return _reply(chat, parent, _cannedFor(text));
  }

  @override
  Stream<TavernEvent> regenerate(String chatId, String nodeId) {
    final chat = _chats[chatId]!;
    final node = chat.nodes[nodeId]!;
    return _reply(chat, node.parent, _canned[_seq % _canned.length]);
  }

  @override
  Stream<TavernEvent> continueReply(String chatId, String nodeId) {
    final chat = _chats[chatId]!;
    final node = chat.nodes[nodeId]!;
    return _stream(chat, node, '\n\n她停顿了一下，又接着说：「还有一件事……我晚点再告诉你。」', fresh: false);
  }

  @override
  Stream<TavernEvent> impersonate(String chatId) async* {
    yield const TavernTextDelta('', '我推开门，四下看了看。');
    yield TavernTurnDone(
      TavernMessage(nodeId: '', role: TavernRole.user, speaker: 'You', text: '我推开门，四下看了看。', at: _clock()),
    );
  }

  @override
  void stop(String chatId) => _running[chatId]?.close();

  Stream<TavernEvent> _reply(_Chat chat, String? parent, String text) {
    final c = _characters[chat.characterId]!;
    final node = _Node(_id('n'), parent, TavernRole.character, c.name, '', _clock());
    chat.add(node);
    chat.chosen[parent] = node.id;
    return _stream(chat, node, text, fresh: true);
  }

  /// [fresh]: a new reply (it may think first); else one continued, which
  /// starts, as the engine's do, from what it already says.
  Stream<TavernEvent> _stream(_Chat chat, _Node node, String text, {required bool fresh}) {
    final out = StreamController<TavernEvent>();
    _running[chat.id] = out;
    var stopped = false;
    out.onCancel = () => stopped = true;
    unawaited(() async {
      out.add(TavernTurnStarted(chat.message(node)));
      chat.touch(_clock());
      if (_thinking && fresh) {
        for (final piece in _pieces(_sampleReasoning)) {
          await Future<void>.delayed(tick);
          if (stopped || out.isClosed) break;
          node.reasoning = (node.reasoning ?? '') + piece;
          out.add(TavernReasoningDelta(node.id, piece));
        }
      }
      final pieces = _pieces(text);
      for (final piece in pieces) {
        await Future<void>.delayed(tick);
        if (stopped || out.isClosed) break;
        node.text += piece;
        out.add(TavernTextDelta(node.id, piece));
      }
      _running.remove(chat.id);
      chat.changes.add(null);
      _listChanged.add(null);
      if (out.isClosed) return;
      out.add(
        stopped
            ? TavernTurnFailed(TavernFailure.cancelled, partial: chat.message(node))
            : TavernTurnDone(chat.message(node)),
      );
      await out.close();
    }());
    return out.stream;
  }

  // Editing the tree ----------------------------------------------------------

  @override
  Future<void> selectSibling(String chatId, String nodeId, int index) async {
    final chat = _chats[chatId]!;
    final node = chat.nodes[nodeId]!;
    final siblings = chat.children(node.parent);
    // As the engine: the chosen sibling's ancestors are all chosen too, so
    // any node of the tree can be made current in one call.
    var at = siblings[index.clamp(0, siblings.length - 1)];
    for (;;) {
      chat.chosen[at.parent] = at.id;
      final parent = at.parent;
      if (parent == null) break;
      at = chat.nodes[parent]!;
    }
    chat.changes.add(null);
  }

  /// As the engine: [nodeId] and all its ancestors chosen; the path stops at
  /// it unless [restoreDescendants] keeps what was chosen below. Nothing is
  /// deleted.
  @override
  Future<void> selectNode(String chatId, String nodeId, {bool restoreDescendants = false}) async {
    final chat = _chats[chatId]!;
    var at = chat.nodes[nodeId] ?? (throw StateError('No message $nodeId in $chatId'));
    if (!restoreDescendants) chat.chosen.remove(nodeId);
    for (;;) {
      chat.chosen[at.parent] = at.id;
      final parent = at.parent;
      if (parent == null) break;
      at = chat.nodes[parent]!;
    }
    chat.changes.add(null);
  }

  @override
  Future<void> edit(String chatId, String nodeId, String text) async {
    final chat = _chats[chatId]!;
    chat.nodes[nodeId]!.text = text;
    chat.changes.add(null);
  }

  /// What each deletion took, by its undo token, as the engine keeps them
  /// for as long as it is open.
  final _deletions = <String, ({String chatId, _Taken taken})>{};
  var _deletionSerial = 0;

  @override
  Future<String> deleteFrom(String chatId, String nodeId) async {
    final chat = _chats[chatId]!;
    final token = 'deletion-${++_deletionSerial}';
    _deletions[token] = (chatId: chatId, taken: chat.take(nodeId));
    chat.changes.add(null);
    _listChanged.add(null);
    return token;
  }

  @override
  Future<bool> undoDeleteFrom(String chatId, String deletionId) async {
    final deletion = _deletions[deletionId];
    if (deletion == null || deletion.chatId != chatId) return false;
    _deletions.remove(deletionId);
    final chat = _chats[chatId]!;
    chat.restore(deletion.taken);
    chat.changes.add(null);
    _listChanged.add(null);
    return true;
  }

  @override
  Future<List<TavernMessage>> searchChat(String chatId, String query, {int limit = 50}) async {
    if (limit < 0) throw ArgumentError.value(limit, 'limit');
    final chat = _chats[chatId]!;
    if (query.trim().isEmpty || limit == 0) return const [];
    return [
      for (final node in chat.newestFirst())
        if (node.text.contains(query) || node.speaker.contains(query)) chat.message(node),
    ].take(limit).toList();
  }

  // T16, in memory: the card's own lorebook, the whole tree, branch names,
  // one message out, and lines added without a reply.

  /// [c]'s card lorebook entries, made when it has none; a copy of its own
  /// (the sample card's book is a constant), kept on the card.
  List<Object?> _bookEntries(_Char c) {
    final book = _copySetting(c.data['character_book'] ?? const {'entries': <Object?>[]})! as Map<String, Object?>;
    final entries = (book['entries'] as List<Object?>?) ?? <Object?>[];
    // As the engine: an entry without an id takes its index before an edit.
    for (final (i, entry) in entries.indexed) {
      if (entry is Map<String, Object?> && entry['id'] == null) entry['id'] = i;
    }
    book['entries'] = entries;
    c.data['character_book'] = book;
    return entries;
  }

  _Char _characterFor(String characterId) =>
      _characters[characterId] ?? (throw const TavernImportError('missing character'));

  @override
  Future<TavernCharacter> addCharacterBookEntry(String characterId, Map<String, Object?> entry) async {
    final c = _characterFor(characterId);
    final entries = _bookEntries(c);
    final used = {for (final e in entries.whereType<Map<String, Object?>>()) e['id']};
    var id = 0;
    while (used.contains(id)) {
      id++;
    }
    entries.add({..._copySetting(entry)! as Map<String, Object?>, 'id': id});
    _listChanged.add(null);
    return _view(c);
  }

  @override
  Future<TavernCharacter> updateCharacterBookEntry(String characterId, int index, Map<String, Object?> fields) async {
    final c = _characterFor(characterId);
    final entries = _bookEntries(c);
    if (fields.containsKey('id')) throw ArgumentError.value(fields['id'], 'id');
    final entry = entries[RangeError.checkValidIndex(index, entries)]! as Map<String, Object?>;
    _mergeSettings(entry, fields);
    _listChanged.add(null);
    return _view(c);
  }

  @override
  Future<TavernCharacter> deleteCharacterBookEntry(String characterId, int index) async {
    final c = _characterFor(characterId);
    final entries = _bookEntries(c);
    entries.removeAt(RangeError.checkValidIndex(index, entries));
    _listChanged.add(null);
    return _view(c);
  }

  @override
  Future<Map<String, Object?>> previewCharacterBook(
    String characterId,
    String text, {
    String? chatId,
    int seed = 0,
  }) async {
    // A stand-in for the engine's world-info stage: enabled entries, always-on
    // or keyed by a case-blind substring (and, if selective, one secondary
    // key too). No macros, regex, budget, recursion or timed effects.
    final c = _characterFor(characterId);
    final book = c.data['character_book'];
    final entries = book is Map && book['entries'] is List ? book['entries'] as List : const <Object?>[];
    final lower = text.toLowerCase();
    bool said(String key) => key.isNotEmpty && lower.contains(key.toLowerCase());
    List<String> strings(Object? v) => [
      if (v is List)
        for (final s in v)
          if (s is String) s,
    ];
    final activated = <Map<String, Object?>>[];
    for (final (i, e) in entries.indexed) {
      if (e is! Map<String, Object?> || e['enabled'] == false) continue;
      final secondary = strings(e['secondary_keys']);
      final primary = e['constant'] == true ? null : strings(e['keys']).where(said).firstOrNull;
      final matches = secondary.where(said).toList();
      final selective = e['selective'] == true && secondary.isNotEmpty;
      if (e['constant'] != true && (primary == null || (selective && matches.isEmpty))) continue;
      activated.add({
        'bookId': '$characterId:card',
        'uid': '${e['id'] ?? i}',
        'source': 'character',
        'reason': e['constant'] == true ? 'constant' : 'keywords',
        'content': e['content'] is String ? e['content'] : '',
        'originalContent': e['content'] is String ? e['content'] : '',
        'order': e['insertion_order'] is num ? e['insertion_order'] : 100,
        'position': e['position'] == 'after_char' ? 1 : 0,
        'primaryKey': primary,
        'secondaryMatches': primary == null ? const <String>[] : matches,
      });
    }
    activated.sort((a, b) => (b['order']! as num).compareTo(a['order']! as num));
    return {
      'scope': 'character-book',
      'stage': 'world-info',
      'seed': seed,
      'chatId': chatId,
      'contextNodeId': null,
      'overflowed': false,
      'scanRounds': 1,
      'activated': activated,
      'preparedEffects': const <Object?>[],
    };
  }

  @override
  Future<List<TavernTreeNode>> tree(String chatId) async {
    final chat = _chats[chatId]!;
    final current = {for (final m in chat.path()) m.nodeId};
    return [
      for (final node in chat.inOrder())
        () {
          final siblings = chat.children(node.parent);
          return TavernTreeNode(
            nodeId: node.id,
            parentId: node.parent,
            role: node.role,
            speaker: node.speaker,
            preview: String.fromCharCodes(node.text.runes.take(64)),
            at: node.at,
            isCurrentPath: current.contains(node.id),
            siblingIndex: siblings.indexOf(node),
            siblingCount: siblings.length,
            hidden: node.hidden,
            branchName: chat.branchNames[node.id],
            speakerCharacterId: node.speakerId,
          );
        }(),
    ];
  }

  @override
  Future<Map<String, Object?>> readVariables(String chatId) async => {};

  /// The preview keeps no state: the selected leaf's empty ST-variables view,
  /// as a card without a state schema reads.
  @override
  Future<TavernStateSnapshot> readState(String chatId) async => TavernStateSnapshot(
    chatId: chatId,
    nodeId: _chats[chatId]!.tail()?.id,
    legacy: true,
    initialized: false,
    valueExists: false,
    automaticEnabled: false,
    values: const <String, Object?>{},
  );

  /// Not kept here, so not pretended: an edit is refused.
  @override
  Future<TavernStateEditResult> setStateValue(String chatId, String path, Object? value, {String? expectedNodeId}) =>
      Future.error(UnsupportedError('The preview tavern keeps no state.'));

  @override
  Future<List<TavernAgentRun>> readAgentRuns(String chatId, {String? nodeId, int limit = 50}) async {
    if (limit < 0) throw ArgumentError.value(limit, 'limit');
    return const [];
  }

  /// [node] added at the end of [chat]'s current path.
  TavernMessage _append(_Chat chat, TavernRole role, String speaker, String text) {
    final parent = chat.tail()?.id;
    final node = _Node(_id('n'), parent, role, speaker, text, _clock());
    chat.add(node);
    chat.chosen[parent] = node.id;
    chat.touch(node.at);
    chat.changes.add(null);
    _listChanged.add(null);
    return chat.message(node);
  }

  @override
  Future<TavernMessage> sendOnly(String chatId, String text) async =>
      _append(_chats[chatId]!, TavernRole.user, 'You', text);

  @override
  Future<TavernMessage> narrate(String chatId, String text, {String? speaker}) async =>
      _append(_chats[chatId]!, TavernRole.narrator, speaker ?? 'System', text.trim());

  @override
  Future<void> nameBranch(String chatId, String nodeId, String? name) async {
    final chat = _chats[chatId]!;
    final label = name?.trim() ?? '';
    if (label.isEmpty) {
      chat.branchNames.remove(nodeId);
    } else {
      chat.branchNames[nodeId] = label;
    }
    chat.changes.add(null);
  }

  @override
  Future<void> deleteMessage(String chatId, String nodeId) async {
    final chat = _chats[chatId]!;
    chat.removeOne(nodeId);
    chat.changes.add(null);
    _listChanged.add(null);
  }

  /// The preview runs a turn only for the stream that asked for it: there is
  /// none to rejoin.
  @override
  Stream<TavernEvent> resumeTurn(String chatId) => const Stream.empty();

  @override
  Future<TavernBackupInfo> backup(String destinationPath) async =>
      throw UnsupportedError('The preview keeps nothing to back up.');

  @override
  Future<void> setHidden(String chatId, String nodeId, bool hidden) async {
    final chat = _chats[chatId]!;
    chat.nodes[nodeId]!.hidden = hidden;
    chat.changes.add(null);
  }

  @override
  void configure(TavernModelConfig config) => _thinking = config.thinking;

  /// 思考 is on: replies think a little first.
  var _thinking = false;

  /// Settings as the engine keeps them: the global ones, and each chat's over
  /// them. Objects merge; lists and values replace; null is a value too.
  final _globalSettings = <String, Object?>{};
  final _chatSettings = <String, Map<String, Object?>>{};

  @override
  Future<Map<String, Object?>> readSettings({String? chatId}) async {
    final settings = <String, Object?>{};
    _mergeSettings(settings, _globalSettings);
    if (_chatSettings[chatId] case final chat?) _mergeSettings(settings, chat);
    return settings;
  }

  @override
  Future<void> setSettings(Map<String, Object?> patch, {String? chatId}) async =>
      _mergeSettings(chatId == null ? _globalSettings : _chatSettings.putIfAbsent(chatId, () => {}), patch);

  /// No helper runs in the preview: directing is off, nothing pending, no
  /// runs or proposals.
  @override
  Future<TavernDirectorSnapshot> readDirector(String chatId) async {
    if (!_chats.containsKey(chatId)) throw StateError('No chat $chatId');
    return TavernDirectorSnapshot(
      chatId: chatId,
      automaticEnabled: false,
      pendingJobs: 0,
      running: false,
      stale: false,
    );
  }

  @override
  Stream<TavernDirectorSnapshot> watchDirector(String chatId) => Stream.fromFuture(readDirector(chatId));

  /// No model here to ask, so not pretended.
  @override
  Future<TavernDirectorRun> runDirector(String chatId) =>
      Future.error(UnsupportedError('The preview tavern has no director.'));

  @override
  Future<List<TavernDirectorEvent>> readDirectorEvents(String chatId, {int limit = 50, String? beforeEventId}) async {
    if (limit < 0) throw ArgumentError.value(limit, 'limit');
    return const [];
  }

  // Presets, kept in memory as the engine keeps them; no regex scripts or
  // lorebooks of its own (importing one says so), and its text shows as written.

  @override
  Future<TavernDisplayResult> displayText(
    String chatId, {
    String? nodeId,
    String? text,
    TavernRole? role,
    String? speaker,
    num? depth,
    bool reasoning = false,
  }) async => TavernDisplayResult(
    text: text ?? _chats[chatId]?.nodes[nodeId]?.text ?? (throw StateError('No message $nodeId in $chatId')),
  );

  final _presets = <String, TavernPreset>{};
  final _presetsChanged = StreamController<void>.broadcast();
  var _presetCount = 0;
  String? _defaultPreset;
  final _chatPresets = <String, String?>{};

  List<TavernPresetSummary> _presetList() =>
      [for (final p in _presets.values) p.summary]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Future<List<TavernPresetSummary>> listPresets() async => _presetList();

  @override
  Stream<List<TavernPresetSummary>> watchPresets() async* {
    yield _presetList();
    await for (final _ in _presetsChanged.stream) {
      yield _presetList();
    }
  }

  @override
  Future<TavernPreset?> preset(String presetId) async => _presets[presetId];

  @override
  Future<TavernPresetImportResult> importPreset(String text, {String? fileName}) async {
    final Object? json;
    try {
      json = jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text);
    } on FormatException {
      throw TavernPresetImportError([
        const TavernPresetIssue(
          path: r'$',
          code: 'json',
          message: 'not JSON',
          severity: TavernPresetIssueSeverity.error,
        ),
      ]);
    }
    if (json is! Map<String, Object?>) {
      throw TavernPresetImportError([
        const TavernPresetIssue(
          path: r'$',
          code: 'object',
          message: 'not an object',
          severity: TavernPresetIssueSeverity.error,
        ),
      ]);
    }
    final at = DateTime.now();
    final id = 'preset-${_presetCount++}';
    final name = fileName == null
        ? 'Preset $_presetCount'
        : fileName.replaceFirst(RegExp(r'\.json$', caseSensitive: false), '');
    final preset = TavernPreset(id: id, name: name, sourceText: text, raw: json, createdAt: at, updatedAt: at);
    _presets[id] = preset;
    _presetsChanged.add(null);
    return TavernPresetImportResult(preset, const []);
  }

  @override
  Future<TavernPresetImportResult> updatePreset(String presetId, Map<String, Object?> patch, {String? name}) async {
    final old = _presets[presetId]!;
    // As the engine: objects merge, arrays and scalars are replaced.
    final raw = _copySetting(old.raw)! as Map<String, Object?>;
    _mergeSettings(raw, patch);
    final preset = TavernPreset(
      id: old.id,
      name: name ?? old.name,
      sourceText: old.sourceText,
      raw: raw,
      envelope: old.envelope,
      createdAt: old.createdAt,
      updatedAt: DateTime.now(),
    );
    _presets[presetId] = preset;
    _presetsChanged.add(null);
    return TavernPresetImportResult(preset, const []);
  }

  @override
  Future<TavernPresetImportResult> updatePresetPrompt(String presetId, String identifier, Map<String, Object?> patch) =>
      _editPreset(presetId, (raw) {
        final prompts = [
          for (final p in (raw['prompts'] as List?) ?? const []) Map<String, Object?>.of(p as Map<String, Object?>),
        ];
        final i = prompts.indexWhere((p) => p['identifier'] == identifier);
        if (i >= 0) prompts[i] = {...prompts[i], ...patch};
        raw['prompts'] = prompts;
      });

  @override
  Future<TavernPresetImportResult> setPresetOrder(String presetId, List<String> identifiers) =>
      _editPreset(presetId, (raw) {
        final order = _orderOf(raw);
        order['order'] = [
          for (final id in identifiers)
            {
              'identifier': id,
              'enabled':
                  [
                    for (final e in (order['order'] as List?) ?? const [])
                      if ((e as Map)['identifier'] == id) e['enabled'],
                  ].firstOrNull ??
                  true,
            },
        ];
      });

  @override
  Future<TavernPresetImportResult> setPresetPromptEnabled(String presetId, String identifier, bool enabled) =>
      _editPreset(presetId, (raw) {
        final order = _orderOf(raw);
        final list = [
          for (final e in (order['order'] as List?) ?? const []) Map<String, Object?>.of(e as Map<String, Object?>),
        ];
        final i = list.indexWhere((e) => e['identifier'] == identifier);
        i < 0 ? list.add({'identifier': identifier, 'enabled': enabled}) : list[i]['enabled'] = enabled;
        order['order'] = list;
      });

  /// The 100001 group of [raw]'s prompt_order, made when missing (from the
  /// first group), as the engine edits it.
  static Map<String, Object?> _orderOf(Map<String, Object?> raw) {
    final groups = [
      for (final g in (raw['prompt_order'] as List?) ?? const []) Map<String, Object?>.of(g as Map<String, Object?>),
    ];
    var i = groups.indexWhere((g) => '${g['character_id']}' == '100001');
    if (i < 0) {
      groups.add({'character_id': 100001, 'order': groups.isEmpty ? <Object?>[] : groups.first['order']});
      i = groups.length - 1;
    }
    raw['prompt_order'] = groups;
    return groups[i];
  }

  Future<TavernPresetImportResult> _editPreset(String presetId, void Function(Map<String, Object?> raw) edit) async {
    final old = _presets[presetId]!;
    final raw = old.raw;
    edit(raw);
    final preset = TavernPreset(
      id: old.id,
      name: old.name,
      sourceText: old.sourceText,
      raw: raw,
      envelope: old.envelope,
      createdAt: old.createdAt,
      updatedAt: DateTime.now(),
    );
    _presets[presetId] = preset;
    _presetsChanged.add(null);
    return TavernPresetImportResult(preset, const []);
  }

  @override
  Future<String> exportPreset(String presetId) async => _presets[presetId]!.sourceText;

  @override
  Future<TavernPresetSelection> presetSelection({String? chatId}) async {
    final bound = chatId == null ? null : _chatPresets[chatId];
    final effective = bound ?? _defaultPreset;
    return TavernPresetSelection(
      source: bound != null
          ? PresetSelectionSource.chat
          : _defaultPreset != null
          ? PresetSelectionSource.globalDefault
          : PresetSelectionSource.stDefault,
      boundPresetId: bound,
      defaultPresetId: _defaultPreset,
      effectivePresetId: effective,
    );
  }

  @override
  Future<void> setDefaultPreset(String? presetId) async {
    _defaultPreset = presetId;
    _presetsChanged.add(null);
  }

  @override
  Future<void> bindPreset(String chatId, String? presetId) async {
    _chatPresets[chatId] = presetId;
    _presetsChanged.add(null);
  }

  @override
  Future<void> deletePreset(String presetId) async {
    _presets.remove(presetId);
    if (_defaultPreset == presetId) _defaultPreset = null;
    _chatPresets.removeWhere((_, id) => id == presetId);
    _presetsChanged.add(null);
  }

  /// Global helper scripts, kept in memory as their tree; never run here.
  final _scriptTree = <Map<String, Object?>>[];
  final _scriptsChanged = StreamController<void>.broadcast();
  var _scriptCount = 0;

  List<TavernScriptLibraryEntry> _scriptEntries() => [for (final e in _scriptTree) TavernScriptLibraryEntry(e)];

  /// The item [id] in [nodes] or under them, with the list it is in.
  (List<Map<String, Object?>>, Map<String, Object?>)? _scriptItem(String id, List<Map<String, Object?>> nodes) {
    for (final node in nodes) {
      if (node['id'] == id) return (nodes, node);
      if (node['type'] != 'folder') continue;
      if (_scriptItem(id, _scriptChildren(node)) case final found?) return found;
    }
    return null;
  }

  static List<Map<String, Object?>> _scriptChildren(Map<String, Object?> folder) =>
      (folder['scripts'] ??= <Map<String, Object?>>[]) as List<Map<String, Object?>>;

  @override
  Future<List<TavernScriptLibraryEntry>> listGlobalScripts() async => _scriptEntries();

  @override
  Stream<List<TavernScriptLibraryEntry>> watchGlobalScripts() async* {
    yield _scriptEntries();
    await for (final _ in _scriptsChanged.stream) {
      yield _scriptEntries();
    }
  }

  /// One script, one folder or a whole tree; each item gets an id of its own.
  @override
  Future<List<TavernScriptLibraryEntry>> importGlobalScripts(String text) async {
    final json = jsonDecode(text);
    Map<String, Object?> own(Object? node) {
      final item = Map<String, Object?>.of(node! as Map<String, Object?>);
      if (item['id'] is! String || _scriptItem(item['id']! as String, _scriptTree) != null) {
        item['id'] = 'script-${_scriptCount++}';
      }
      if (item['type'] == 'folder') item['scripts'] = [for (final child in item['scripts']! as List) own(child)];
      return item;
    }

    final added = [
      for (final node in json is List ? json : [json]) own(node),
    ];
    _scriptTree.addAll(added);
    _scriptsChanged.add(null);
    return [for (final e in added) TavernScriptLibraryEntry(e)];
  }

  @override
  Future<TavernScriptLibraryEntry> setGlobalScriptEnabled(String id, bool enabled) async {
    final (_, item) = _scriptItem(id, _scriptTree)!;
    item['enabled'] = enabled;
    _scriptsChanged.add(null);
    return TavernScriptLibraryEntry(item);
  }

  @override
  Future<void> setGlobalScriptOrder(List<String> ids, {String? folderId}) async {
    final list = folderId == null ? _scriptTree : _scriptChildren(_scriptItem(folderId, _scriptTree)!.$2);
    final byId = {for (final e in list) e['id']: e};
    list
      ..clear()
      ..addAll([for (final id in ids) byId[id]!]);
    _scriptsChanged.add(null);
  }

  @override
  Future<void> deleteGlobalScript(String id) async {
    final (list, item) = _scriptItem(id, _scriptTree)!;
    list.remove(item);
    _scriptsChanged.add(null);
  }

  @override
  Future<String> exportGlobalScripts({String? id}) async =>
      jsonEncode(id == null ? _scriptTree : _scriptItem(id, _scriptTree)!.$2);

  /// The global scripts that are on; the preview keeps no preset or card ones.
  @override
  Future<TavernChatScripts> chatScripts(String chatId, {String? characterId}) async {
    final out = <TavernRunnableScript>[];
    void visit(List<Map<String, Object?>> nodes) {
      for (final node in nodes) {
        if (node['type'] == 'folder') {
          if (node['enabled'] != false) visit(_scriptChildren(node));
        } else if (node['enabled'] == true && '${node['content'] ?? ''}'.trim().isNotEmpty) {
          out.add(
            TavernRunnableScript(
              owner: TavernScriptOwner(kind: TavernScriptOwnerKind.global, scriptId: node['id']! as String),
              name: '${node['name'] ?? ''}',
              content: node['content']! as String,
            ),
          );
        }
      }
    }

    visit(_scriptTree);
    return TavernChatScripts(chatId: chatId, characterId: characterId, scripts: out);
  }

  @override
  Stream<TavernChatScripts> watchChatScripts(String chatId, {String? characterId}) async* {
    yield await chatScripts(chatId, characterId: characterId);
    await for (final _ in _scriptsChanged.stream) {
      yield await chatScripts(chatId, characterId: characterId);
    }
  }

  /// The preview files no import reports.
  @override
  Future<TavernImportReport?> readImportReport(TavernImportKind kind, String assetId) async => null;

  @override
  Future<TavernImportReport> recheckImport(TavernImportKind kind, String assetId) =>
      throw UnsupportedError('The preview keeps no import reports');

  final _regex = <String, TavernRegexScript>{};
  var _regexCount = 0;

  @override
  Future<List<TavernRegexScript>> listRegexScripts() async => _regex.values.toList();

  /// Global regex scripts, kept in memory: one ST script or a list of them.
  @override
  Future<TavernRegexImportResult> importRegexScripts(String text) async {
    final json = jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text);
    final rules = json is List ? json : [json];
    final scripts = [
      for (final rule in rules.whereType<Map<String, Object?>>())
        TavernRegexScript(id: 'regex-${_regexCount++}', sourceText: text, raw: rule, importedAt: DateTime.now()),
    ];
    if (scripts.isEmpty) throw const FormatException('No regex scripts');
    for (final script in scripts) {
      _regex[script.id] = script;
    }
    return TavernRegexImportResult(scripts);
  }

  @override
  Future<TavernRegexScript> setRegexEnabled(String regexId, bool enabled) async {
    final old = _regex[regexId]!;
    return _regex[regexId] = TavernRegexScript(
      id: old.id,
      sourceText: old.sourceText,
      raw: {...old.raw, 'disabled': !enabled},
      importedAt: old.importedAt,
      diagnostics: old.diagnostics,
    );
  }

  /// An edit in place, as the engine makes it: the patch copied when called,
  /// merged into the rule (maps by key, the rest replaced, null kept), its
  /// id, place and first source kept. The preview checks nothing: the rule
  /// keeps the findings it had (none), not a fresh 「compatible」.
  @override
  Future<TavernRegexScript> updateRegexScript(String regexId, Map<String, Object?> patch) {
    final captured = jsonDecode(jsonEncode(patch)) as Map<String, Object?>;
    return Future.sync(() {
      final old = _regex[regexId];
      if (old == null) throw TavernImportError('No regex script $regexId');
      Map<String, Object?> merge(Map<String, Object?> base, Map<String, Object?> edit) => {
        ...base,
        for (final MapEntry(:key, :value) in edit.entries)
          key: switch ((base[key], value)) {
            (final Map<String, Object?> was, final Map<String, Object?> now) => merge(was, now),
            _ => value,
          },
      };
      return _regex[regexId] = TavernRegexScript(
        id: old.id,
        sourceText: old.sourceText,
        raw: merge(old.raw, captured),
        importedAt: old.importedAt,
        diagnostics: old.diagnostics,
      );
    });
  }

  @override
  Future<void> deleteRegex(String regexId) async => _regex.remove(regexId);

  @override
  Future<String> exportRegex({String? regexId}) async => jsonEncode([
    for (final s in _regex.values)
      if (regexId == null || s.id == regexId) s.raw,
  ]);

  // Standalone lorebooks, kept in memory; their bindings go into the
  // settings as the engine keeps them (lorebooks.<source>).

  final _books = <String, TavernLorebook>{};
  var _bookCount = 0;

  @override
  Future<List<TavernLorebookSummary>> listLorebooks() async => _books.values.toList();

  @override
  Future<TavernLorebookImportResult> importLorebook(String text, {String? fileName}) async {
    final json = jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text);
    if (json is! Map<String, Object?> || json['entries'] == null) throw const FormatException('Not a lorebook');
    final entries = json['entries'];
    final name = fileName?.replaceFirst(RegExp(r'\.json$', caseSensitive: false), '') ?? 'Lorebook ${_bookCount + 1}';
    final book = TavernLorebook(
      id: 'book-${_bookCount++}',
      name: name,
      entryCount: entries is Map ? entries.length : (entries is List ? entries.length : 0),
      stWorldName: name,
      raw: json,
    );
    _books[book.id] = book;
    return TavernLorebookImportResult(book, const []);
  }

  @override
  Future<Map<String, Object?>?> lorebook(String id) async => _books[id]?.raw;

  @override
  Future<void> putLorebook(String id, Map<String, Object?> json) async {
    final old = _books[id];
    final entries = json['entries'];
    _books[id] = TavernLorebook(
      id: id,
      name: old?.name ?? id,
      entryCount: entries is Map ? entries.length : (entries is List ? entries.length : 0),
      stWorldName: old?.stWorldName,
      raw: json,
    );
  }

  @override
  Future<String> exportLorebook(String id) async => jsonEncode(_books[id]!.raw);

  @override
  Future<void> deleteLorebook(String id) async => _books.remove(id);

  @override
  Future<void> bindLorebooks(
    List<String> ids, {
    WorldInfoSource source = WorldInfoSource.global,
    String? chatId,
    String? characterId,
    String? personaId,
  }) => switch ((characterId, personaId)) {
    (final String id, _) => setSettings({
      'characterLorebooks': {id: ids},
    }),
    (_, final String id) => setSettings({
      'personaLorebooks': {id: ids},
    }),
    _ => setSettings({
      'lorebooks': {source.name: ids},
    }, chatId: chatId),
  };

  @override
  Future<void> close() async {
    await _listChanged.close();
    await _presetsChanged.close();
  }
}

/// [patch] into [into], copied: a reader never holds what is stored.
void _mergeSettings(Map<String, Object?> into, Map<String, Object?> patch) {
  for (final MapEntry(:key, :value) in patch.entries) {
    if (into[key] case final Map<String, Object?> old when value is Map<String, Object?>) {
      _mergeSettings(old, value);
    } else {
      into[key] = _copySetting(value);
    }
  }
}

/// A card's extensions.dshgo, or nothing.
Map<Object?, Object?> _dshgoOf(Map<String, Object?> data) => switch (data['extensions']) {
  {'dshgo': final Map<Object?, Object?> dshgo} => dshgo,
  _ => const {},
};

Object? _copySetting(Object? value) => switch (value) {
  final Map<String, Object?> map => {for (final MapEntry(:key, :value) in map.entries) key: _copySetting(value)},
  final List<Object?> list => [for (final item in list) _copySetting(item)],
  _ => value,
};

class _Card {
  const _Card({
    required this.id,
    required this.name,
    required this.description,
    required this.greetings,
    this.creator,
    this.tags = const [],
    this.creatorNotes = '',
    this.book,
  });

  final String id;
  final String name;
  final String? creator;
  final List<String> tags;
  final String description;
  final String creatorNotes;
  final List<String> greetings;

  /// A V3 character_book, as a card carries it.
  final Map<String, Object?>? book;
}

class _Char {
  _Char(_Card card, this.importedAt)
    : id = card.id,
      data = {
        'name': card.name,
        'nickname': '',
        'description': card.description,
        'personality': '',
        'scenario': '',
        'first_mes': card.greetings.first,
        'alternate_greetings': card.greetings.skip(1).toList(),
        'mes_example': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'creator_notes': card.creatorNotes,
        'creator': card.creator ?? '',
        'character_version': '',
        'tags': [...card.tags],
        'extensions': <String, Object?>{
          'depth_prompt': {'prompt': '', 'depth': 4},
        },
        'character_book': ?card.book,
      };

  final String id;

  /// The card's V3 `data`, as [Tavern.characterFields] gives it.
  final Map<String, Object?> data;
  final DateTime importedAt;

  String get name => data['name']! as String;
  String? get creator => switch (data['creator']) {
    final String c when c.isNotEmpty => c,
    _ => null,
  };
  List<String> get tags => (data['tags']! as List).cast<String>();
  String get description => data['description']! as String;
  String get creatorNotes => data['creator_notes']! as String;
  List<String> get greetings => [
    data['first_mes']! as String,
    ...(data['alternate_greetings']! as List).cast<String>(),
  ];
}

/// A group chat's roster and settings, and its batch while one runs.
class _Group {
  _Group(this.chatId, this.title, this.host, this.members, this.activation, this.maxSpeakers, this.allowSelf);
  final String chatId;
  String title;
  final String host;
  List<TavernGroupMember> members;
  TavernGroupActivation activation;
  int maxSpeakers;
  bool allowSelf;

  /// The running batch: its events for a page coming back, where it is, and
  /// the reply being written.
  StreamController<TavernGroupEvent>? live;
  TavernGroupProgress? progress;
  _Node? current;

  TavernGroupChat view() => TavernGroupChat(
    chatId: chatId,
    title: title,
    hostCharacterId: host,
    members: members,
    activation: activation,
    maxSpeakersPerTurn: maxSpeakers,
    allowSelfResponses: allowSelf,
  );
}

class _Node {
  _Node(this.id, this.parent, this.role, this.speaker, this.text, this.at);
  final String id;
  final String? parent;
  final TavernRole role;
  final String speaker;
  String text;
  String? reasoning;
  final DateTime at;
  bool hidden = false;

  /// The library card that said it (group chats); null for you and narration.
  String? speakerId;
}

/// A deletion's nodes, each with its place in the order, and the chosen path
/// before and after it.
typedef _Taken = ({List<(int, _Node)> nodes, Map<String?, String> before, Map<String?, String> after});

class _Chat {
  _Chat(this.id, this.characterId, this.title, this.updatedAt);
  final String id;
  final String characterId;
  final String title;
  DateTime updatedAt;
  final nodes = <String, _Node>{};
  final _order = <String>[];

  /// The child each node continues with (null key: the root).
  final chosen = <String?, String>{};
  final changes = StreamController<void>.broadcast();

  void add(_Node node) {
    nodes[node.id] = node;
    _order.add(node.id);
  }

  void touch(DateTime at) => updatedAt = at;

  List<_Node> children(String? parent) => [
    for (final id in _order)
      if (nodes[id]!.parent == parent) nodes[id]!,
  ];

  /// The nodes from the root down the chosen children.
  List<_Node> _walk() {
    final out = <_Node>[];
    var next = chosen[null];
    while (next != null && nodes.containsKey(next)) {
      out.add(nodes[next]!);
      next = chosen[next];
    }
    return out;
  }

  _Node? tail() => _walk().lastOrNull;

  List<TavernMessage> path() => [for (final node in _walk()) message(node)];

  TavernMessage message(_Node node) {
    final siblings = children(node.parent);
    return TavernMessage(
      nodeId: node.id,
      parentId: node.parent,
      role: node.role,
      speaker: node.speaker,
      text: node.text,
      reasoning: node.reasoning,
      at: node.at,
      siblingIndex: siblings.indexOf(node),
      siblingCount: siblings.length,
      hidden: node.hidden,
      speakerCharacterId: node.speakerId,
    );
  }

  /// Every node, the newest first.
  Iterable<_Node> newestFirst() => [for (final id in _order.reversed) nodes[id]!];

  /// Every node, in the order it was added.
  Iterable<_Node> inOrder() => [for (final id in _order) nodes[id]!];

  /// Names given to branches, by the node each starts at.
  final branchNames = <String, String>{};

  /// [id] alone out: its children move up to its parent, the path through it
  /// goes on through the child it continued with.
  void removeOne(String id) {
    final node = nodes[id];
    if (node == null) return;
    final next = chosen[id];
    for (final child in children(id)) {
      nodes[child.id] = _Node(child.id, node.parent, child.role, child.speaker, child.text, child.at)
        ..reasoning = child.reasoning
        ..hidden = child.hidden
        ..speakerId = child.speakerId;
    }
    nodes.remove(id);
    _order.remove(id);
    chosen.remove(id);
    branchNames.remove(id);
    if (chosen[node.parent] == id) {
      if (next != null) {
        chosen[node.parent] = next;
      } else {
        final rest = children(node.parent);
        if (rest.isEmpty) {
          chosen.remove(node.parent);
        } else {
          chosen[node.parent] = rest.last.id;
        }
      }
    }
  }

  /// [id] and everything under it taken out, with what [restore] needs.
  _Taken take(String id) {
    final before = Map.of(chosen);
    bool under(String? node) {
      for (var at = node; at != null; at = nodes[at]?.parent) {
        if (at == id) return true;
      }
      return false;
    }

    final taken = [
      for (final (i, node) in _order.indexed)
        if (under(node)) (i, nodes[node]!),
    ];
    remove(id);
    return (nodes: taken, before: before, after: Map.of(chosen));
  }

  /// Puts back what [take] took, each where it was; the path it was on too,
  /// unless the chat has gone another way since.
  void restore(_Taken taken) {
    final unchanged = chosen.length == taken.after.length && chosen.entries.every((e) => taken.after[e.key] == e.value);
    for (final (i, node) in taken.nodes) {
      nodes[node.id] = node;
      _order.insert(math.min(i, _order.length), node.id);
    }
    if (unchanged) {
      chosen
        ..clear()
        ..addAll(taken.before);
    }
  }

  void remove(String id) {
    final node = nodes[id];
    if (node == null) return;
    for (final child in children(id)) {
      remove(child.id);
    }
    nodes.remove(id);
    _order.remove(id);
    chosen.remove(id);
    if (chosen[node.parent] == id) {
      final rest = children(node.parent);
      if (rest.isEmpty) {
        chosen.remove(node.parent);
      } else {
        chosen[node.parent] = rest.last.id;
      }
    }
  }
}

Iterable<String> _pieces(String text) => RegExp(r'.{1,3}', dotAll: true).allMatches(text).map((m) => m[0]!);

const _sampleReasoning = '她在等一个答案，但不想说得太多。先回应眼前的问题，再留一点悬念。';

String _cannedFor(String text) => text.contains('?') || text.contains('？') ? _canned[1] : _canned[0];

const _canned = [
  '*她把手里的杯子放下，抬眼看你。*\n\n「你来得正好。外面的雨一直没停，镇上的人都躲在屋里。」\n\n她往壁炉那边挪了挪，给你让出一个位置。「坐吧，我去给你倒点热的。」',
  '「这个问题啊……」她想了想，手指在桌面上轻轻敲着。\n\n「我只能告诉你我知道的那部分。剩下的，你得自己去地下室看看。」',
  '*门外传来一阵脚步声，又很快远去。*\n\n她没有回头，只是低声说：「别出声，等他们走远。」',
];

const _samples = [
  _Card(
    id: 'sample-innkeeper',
    name: '林晚',
    creator: 'DSH Go',
    tags: ['示例', '悬疑'],
    description: '雨夜小镇上一家旅店的老板娘，知道很多事，但只说一半。',
    creatorNotes: '这是一张示例卡，用来预览酒馆的界面。',
    book: {
      'name': '雨镇',
      'entries': [
        {
          'keys': ['地下室', '酒窖'],
          'comment': '地下室',
          'content': '旅店地下室名义上是酒窖，钥匙只有林晚有。',
          'insertion_order': 100,
          'enabled': true,
          'constant': false,
        },
        {
          'keys': ['雨'],
          'comment': '连雨',
          'content': '雨已经下了三天，桥被冲断了。',
          'insertion_order': 90,
          'enabled': true,
          'constant': true,
        },
      ],
    },
    greetings: [
      '*旅店的门被风推开，带进一阵冷雨。柜台后面的女人抬起头。*\n\n「这么晚了还在赶路？进来吧，炉子还热着。」',
      '*你醒来时，发现自己躺在旅店二楼的床上。窗外还在下雨。*\n\n「你可算醒了。」门口的女人端着一碗汤，「昨晚你倒在门口，吓我一跳。」',
    ],
  ),
  _Card(
    id: 'sample-navigator',
    name: '星图',
    creator: 'DSH Go',
    tags: ['示例', '科幻'],
    description: '远航飞船上的导航 AI，说话简短，偶尔会讲冷笑话。',
    greetings: ['「舰桥欢迎你，舰长。航线已经算好，还有三十七个小时抵达。要听个笑话打发时间吗？」'],
  ),
];

/// The preview's [Tavern.scripts]: it simulates none of the bridge, and says
/// so (simulated, no methods, no scopes); every call is refused as such,
/// and no events come.
class _PreviewScripts implements TavernScriptBridge {
  TavernScriptHost? _host;

  Future<T> _no<T>(String operation) => Future.error(
    TavernScriptException(
      code: TavernScriptErrorCode.unsupportedCapability,
      operation: operation,
      message: 'The preview does not simulate card scripts.',
    ),
  );

  @override
  TavernScriptCapabilities get capabilities => TavernScriptCapabilities(
    adapterVersion: 'preview',
    methods: const {},
    scopes: const {},
    hostAttached: _host != null,
    simulated: true,
  );

  @override
  void attachHost(TavernScriptHost? host) => _host = host;

  @override
  Future<TavernScriptContext> openContext(TavernScriptContextSpec spec) => _no('openContext');

  @override
  Future<TavernScriptSnapshot> snapshot(String contextId) => _no('snapshot');

  @override
  Future<void> closeContext(String contextId) => _no('closeContext');

  @override
  Future<void> activateChat(String contextId) => _no('activateChat');

  @override
  Stream<TavernScriptEvent> watchEvents({String? chatId}) => const Stream.empty();

  @override
  Future<TavernScriptMessagePage> getChatMessages(
    String contextId,
    TavernMessageRange range, {
    TavernScriptRole? role,
    TavernHiddenFilter hidden = TavernHiddenFilter.all,
    bool includeSwipes = false,
  }) => _no('getChatMessages');

  @override
  Future<TavernScriptMutation> setChatMessages(
    String contextId,
    List<TavernScriptMessagePatch> patches, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) => _no('setChatMessages');

  @override
  Future<TavernScriptMutation> createChatMessages(
    String contextId,
    List<TavernScriptMessageDraft> messages, {
    int? insertBefore,
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) => _no('createChatMessages');

  @override
  Future<TavernScriptMutation> deleteChatMessages(
    String contextId,
    List<int> messageIds, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) => _no('deleteChatMessages');

  @override
  Future<TavernScriptMutation> rotateChatMessages(
    String contextId,
    int begin,
    int middle,
    int end, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) => _no('rotateChatMessages');

  @override
  Future<TavernScriptMutation> selectSwipe(
    String contextId,
    TavernScriptMessageRef message,
    int swipeId, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) => _no('selectSwipe');

  @override
  Future<TavernVariableSnapshot> getVariables(String contextId, TavernVariableTarget target) => _no('getVariables');

  @override
  Future<TavernVariableSnapshot> replaceVariables(
    String contextId,
    TavernVariableTarget target,
    TavernJsonObject value, {
    String? expectedVersion,
  }) => _no('replaceVariables');

  @override
  Future<TavernVariableSnapshot> updateVariablesWith(
    String contextId,
    TavernVariableTarget target,
    FutureOr<TavernJsonObject> Function(TavernJsonObject value) updater,
  ) => _no('updateVariablesWith');

  @override
  Future<TavernVariableMutation> mutateVariables(
    String contextId,
    TavernVariableTarget target,
    List<TavernVariableChange> changes, {
    String? expectedVersion,
  }) => _no('mutateVariables');

  @override
  Future<TavernScriptGeneration> generate(String contextId, TavernScriptGenerateRequest request) => _no('generate');

  @override
  Future<TavernScriptGeneration> generateRaw(String contextId, TavernScriptRawRequest request) => _no('generateRaw');

  @override
  bool stopGenerationById(String generationId) => false;

  @override
  Future<List<TavernScriptRegex>> getTavernRegexes(String contextId, TavernScriptRegexQuery query) =>
      _no('getTavernRegexes');

  @override
  Future<TavernDisplayResult> formatAsTavernRegexedString(
    String contextId,
    String text, {
    required int source,
    required RegexPhase destination,
    num? depth,
    String? characterId,
  }) => _no('formatAsTavernRegexedString');

  @override
  Future<TavernScriptInjectionLease> injectPrompts(
    String contextId,
    List<TavernScriptInjection> prompts, {
    bool once = false,
  }) => _no('injectPrompts');

  @override
  Future<void> uninjectPrompts(String contextId, List<String> ids) => _no('uninjectPrompts');

  @override
  Future<void> releaseInjectionLease(String leaseId) => _no('releaseInjectionLease');

  @override
  Future<List<TavernScriptInjectionView>> listInjections(String contextId) => _no('listInjections');

  @override
  Future<TavernSlashExecution> triggerSlash(
    String contextId,
    String source, {
    String? executionId,
    String pipe = '',
    Map<String, String> arguments = const {},
  }) => _no('triggerSlash');

  @override
  bool stopScript(String executionId) => false;

  @override
  Future<String> substituteMacros(String contextId, String text) => _no('substituteMacros');

  @override
  Future<TavernCharacter> replaceCharacterData(
    String contextId,
    String characterId,
    TavernJsonObject data, {
    String? expectedVersion,
  }) => _no('replaceCharacterData');

  @override
  Future<TavernMvuInitialization> setMvuEnabled(String contextId, bool enabled) => _no('setMvuEnabled');

  @override
  Future<TavernMvuParseResult> parseMvuMessage(String contextId, String message, TavernJsonObject previousData) =>
      _no('parseMvuMessage');

  @override
  Future<TavernScriptCharacterAvatarSnapshot> readCharacterAvatar(String contextId, String characterId) =>
      _no('readCharacterAvatar');

  @override
  Future<TavernScriptCharacterAvatarSnapshot> replaceCharacterAvatar(
    String contextId,
    String characterId,
    Uint8List bytes, {
    required String expectedVersion,
  }) => _no('replaceCharacterAvatar');

  @override
  Future<TavernScriptWorldInfoSettingsSnapshot> updateWorldInfoSettings(
    String contextId,
    TavernJsonObject patch, {
    String? expectedVersion,
  }) => _no('updateWorldInfoSettings');

  @override
  Future<TavernScriptButtonsSnapshot> replaceScriptButtons(
    String contextId,
    List<TavernScriptButton> buttons, {
    String? expectedVersion,
  }) => _no('replaceScriptButtons');

  @override
  Future<TavernScriptBookDirectorySnapshot> getBookDirectory(String contextId) => _no('getBookDirectory');

  @override
  Future<TavernScriptBookRef> resolveBook(String contextId, String nameOrHandle) => _no('resolveBook');

  @override
  Future<TavernScriptBookSnapshot> createBook(String contextId, String name, TavernJsonObject raw) => _no('createBook');

  @override
  Future<void> deleteBook(String contextId, TavernScriptBookRef ref, {required String expectedVersion}) =>
      _no('deleteBook');

  @override
  Future<TavernScriptBookBindingsSnapshot> readBookBindings(String contextId, TavernScriptBookBindingsTarget target) =>
      _no('readBookBindings');

  @override
  Future<TavernScriptBookBindingsSnapshot> updateBookBindings(
    String contextId,
    TavernScriptBookBindingsEdit edit, {
    required String expectedVersion,
  }) => _no('updateBookBindings');

  @override
  Future<TavernScriptPresetSnapshot> readPreset(String contextId, TavernScriptPresetRef ref) => _no('readPreset');

  @override
  Future<TavernScriptPresetSnapshot> replacePreset(
    String contextId,
    TavernScriptPresetRef ref,
    TavernJsonObject raw, {
    required String expectedVersion,
  }) => _no('replacePreset');

  @override
  Future<TavernScriptRegexWriteSnapshot> readTavernRegexesForWrite(
    String contextId,
    TavernScriptRegexWriteTarget target,
  ) => _no('readTavernRegexesForWrite');

  @override
  Future<TavernScriptRegexWriteSnapshot> replaceTavernRegexes(
    String contextId,
    TavernScriptRegexWriteTarget target,
    List<TavernScriptRegexWriteItem> items, {
    required String expectedVersion,
  }) => _no('replaceTavernRegexes');

  @override
  Future<List<TavernScriptBookBinding>> getContextBooks(String contextId) => _no('getContextBooks');

  @override
  Future<TavernScriptBookSnapshot> readBook(String contextId, TavernScriptBookRef ref) => _no('readBook');

  @override
  Future<TavernScriptBookSnapshot> replaceBook(
    String contextId,
    TavernScriptBookRef ref,
    TavernJsonObject book, {
    String? expectedVersion,
  }) => _no('replaceBook');
}
