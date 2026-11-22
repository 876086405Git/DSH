// A [Tavern] that is still opening (the engine opens its database and reads
// its settings asynchronously). Calls wait for it; streams start once it is
// open. The latest [configure] reaches it when it opens, so 酒馆设置 can be
// applied straight away.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';

class DeferredTavern implements Tavern, TavernSPresetPageLifecycle {
  DeferredTavern(Future<Tavern> opening) {
    _ready = opening.then((tavern) {
      _open = tavern;
      if (_config case final config?) tavern.configure(config);
      return tavern;
    });
  }

  late final Future<Tavern> _ready;
  Tavern? _open;
  TavernModelConfig? _config;

  Stream<T> _stream<T>(Stream<T> Function(Tavern t) call) => Stream.fromFuture(_ready).asyncExpand(call);

  @override
  Stream<List<TavernCharacter>> watchCharacters() => _stream((t) => t.watchCharacters());

  @override
  Future<TavernCharacter?> character(String id) async => (await _ready).character(id);

  @override
  Future<TavernCharacter> importCard(Uint8List bytes, {String? fileName}) async =>
      (await _ready).importCard(bytes, fileName: fileName);

  @override
  Future<Uint8List> exportCard(String characterId, {TavernCardFormat format = TavernCardFormat.png}) async =>
      (await _ready).exportCard(characterId, format: format);

  @override
  Future<void> deleteCharacter(String characterId) async => (await _ready).deleteCharacter(characterId);

  @override
  Future<Map<String, Object?>?> characterFields(String characterId) async =>
      (await _ready).characterFields(characterId);

  @override
  Future<TavernCharacter> updateCharacterFields(String characterId, Map<String, Object?> fields) async =>
      (await _ready).updateCharacterFields(characterId, fields);

  @override
  Stream<List<TavernPersona>> watchPersonas() => _stream((t) => t.watchPersonas());

  @override
  Future<TavernPersona?> persona(String personaId) async => (await _ready).persona(personaId);

  @override
  Future<TavernPersona> createPersona({
    required String name,
    String description = '',
    String? avatarPath,
    int descriptionPosition = PersonaDescriptionPosition.inPrompt,
  }) async => (await _ready).createPersona(
    name: name,
    description: description,
    avatarPath: avatarPath,
    descriptionPosition: descriptionPosition,
  );

  @override
  Future<TavernPersona> updatePersona(
    String personaId, {
    String? name,
    String? description,
    String? avatarPath,
    bool clearAvatar = false,
    int? descriptionPosition,
  }) async => (await _ready).updatePersona(
    personaId,
    name: name,
    description: description,
    avatarPath: avatarPath,
    clearAvatar: clearAvatar,
    descriptionPosition: descriptionPosition,
  );

  @override
  Future<void> deletePersona(String personaId) async => (await _ready).deletePersona(personaId);

  @override
  Future<PersonaSelection> personaSelection({String? chatId}) async => (await _ready).personaSelection(chatId: chatId);

  @override
  Future<void> setDefaultPersona(String? personaId) async => (await _ready).setDefaultPersona(personaId);

  @override
  Future<void> bindPersona(String chatId, String? personaId) async => (await _ready).bindPersona(chatId, personaId);

  @override
  Stream<List<TavernChatSummary>> watchChats({String? characterId}) =>
      _stream((t) => t.watchChats(characterId: characterId));

  @override
  Future<String> createChat(String characterId, {int greeting = 0}) async =>
      (await _ready).createChat(characterId, greeting: greeting);

  @override
  Future<TavernChatImportResult> importChats(
    String characterId,
    List<TavernChatFile> files, {
    Map<String, String> lorebookIds = const {},
  }) async => (await _ready).importChats(characterId, files, lorebookIds: lorebookIds);

  @override
  Future<List<TavernChatFile>> exportChat(String chatId, {String? fileName}) async =>
      (await _ready).exportChat(chatId, fileName: fileName);

  @override
  Future<List<TavernDeepSeekSession>> inspectDeepSeekExport(String zipPath) async =>
      (await _ready).inspectDeepSeekExport(zipPath);

  @override
  Future<List<TavernDeepSeekImported>> importDeepSeekSessions(String zipPath, List<String> sessionIds) async =>
      (await _ready).importDeepSeekSessions(zipPath, sessionIds);

  @override
  Future<void> deleteChat(String chatId) async => (await _ready).deleteChat(chatId);

  @override
  Future<List<TavernMessage>> path(String chatId, {int limit = 60, String? beforeNodeId}) async =>
      (await _ready).path(chatId, limit: limit, beforeNodeId: beforeNodeId);

  @override
  Future<List<TavernPathUsage>> pathUsage(String chatId) async => (await _ready).pathUsage(chatId);

  @override
  Future<TavernCastImportResult> importDshgoCastMember(
    TavernCastSource source,
    String localCastId, {
    required String operationId,
    String? domainId,
  }) async => (await _ready).importDshgoCastMember(source, localCastId, operationId: operationId, domainId: domainId);

  @override
  Future<TavernCastImportResult?> readDshgoCastImport(String domainId, String operationId) async =>
      (await _ready).readDshgoCastImport(domainId, operationId);

  @override
  Future<TavernGameplayExportPreview> previewGameplayExport(TavernGameplayExportRequest request) async =>
      (await _ready).previewGameplayExport(request);

  @override
  Future<Uint8List> exportCharacterWithPacks(
    TavernGameplayExportRequest request, {
    required String expectedPreviewId,
  }) async => (await _ready).exportCharacterWithPacks(request, expectedPreviewId: expectedPreviewId);

  @override
  Future<Uint8List> exportGameplayPackFromDraft(
    TavernGameplayExportRequest request, {
    required String expectedPreviewId,
  }) async => (await _ready).exportGameplayPackFromDraft(request, expectedPreviewId: expectedPreviewId);

  @override
  Future<TavernPackScopeSnapshot> readGameplayBindings(TavernPackScopeTarget scope) async =>
      (await _ready).readGameplayBindings(scope);

  @override
  Future<TavernPackBindingReceipt> updateGameplayBindings(
    TavernPackScopeTarget scope, {
    required TavernGameplayRevision expected,
    required String operationId,
    required List<TavernPackBindingEdit> edits,
  }) async => (await _ready).updateGameplayBindings(scope, expected: expected, operationId: operationId, edits: edits);

  @override
  Future<TavernGameplayResolution> resolveGameplayConfig(
    TavernGameplayContext context, {
    List<TavernPackScopePreview> proposedScopes = const [],
    bool validateCurrentState = false,
  }) async => (await _ready).resolveGameplayConfig(
    context,
    proposedScopes: proposedScopes,
    validateCurrentState: validateCurrentState,
  );

  @override
  Future<TavernPackImportResult> importGameplayPack(Uint8List bytes) async => (await _ready).importGameplayPack(bytes);

  @override
  Future<List<TavernPackVersion>> listGameplayPacks({bool includeRemoved = false}) async =>
      (await _ready).listGameplayPacks(includeRemoved: includeRemoved);

  @override
  Future<TavernPackVersion?> readGameplayPack(TavernPackVersionRef ref) async => (await _ready).readGameplayPack(ref);

  @override
  Future<TavernPackResource?> readGameplayPackResource(TavernPackVersionRef ref, String localId) async =>
      (await _ready).readGameplayPackResource(ref, localId);

  @override
  Future<Uint8List> exportInstalledGameplayPack(TavernPackVersionRef ref) async =>
      (await _ready).exportInstalledGameplayPack(ref);

  @override
  Future<TavernPackRemovalReceipt> removeGameplayPackVersion(
    TavernPackVersionRef ref, {
    required TavernGameplayRevision expected,
    required String operationId,
  }) async => (await _ready).removeGameplayPackVersion(ref, expected: expected, operationId: operationId);

  @override
  Future<TavernAuthoringDraft> createAuthoringDraft(List<TavernAuthoringTarget> targets) async =>
      (await _ready).createAuthoringDraft(targets);

  @override
  Future<TavernAuthoringDraft?> readAuthoringDraft(String draftId) async => (await _ready).readAuthoringDraft(draftId);

  /// Returned at once with its id; the render itself runs once the engine is open.
  @override
  TavernAuthoringTask<TavernAuthoringRenderResult> renderAuthoringDraft(
    TavernAuthoringRenderRequest request, {
    required TavernAuthoringPreviewHost host,
  }) => _DeferredTask(request.requestId, _ready.then((t) => t.renderAuthoringDraft(request, host: host)));

  /// Returned at once with its id; the preview itself runs once the engine is open.
  @override
  TavernAuthoringTask<TavernAuthoringPromptPreview> previewAuthoringPrompt(
    TavernAuthoringPromptRequest request, {
    TavernAuthoringPromptHost? host,
  }) => _DeferredTask(request.requestId, _ready.then((t) => t.previewAuthoringPrompt(request, host: host)));

  /// Returned at once with its id; the trial itself runs once the engine is open.
  @override
  TavernAuthoringSimulationTask simulateAuthoringDraft(TavernAuthoringSimulationRequest request) =>
      _DeferredSimulation(request, _ready.then((t) => t.simulateAuthoringDraft(request)));

  /// Returned at once with its id; the run itself starts once the engine is open.
  @override
  TavernAuthoringRun startAuthoringRun(
    TavernAuthoringRunRequest request, {
    TavernAuthoringPromptHost? promptHost,
    TavernAuthoringPreviewHost? renderHost,
  }) => _DeferredAuthoringRun(
    request.runId,
    _ready.then((t) => t.startAuthoringRun(request, promptHost: promptHost, renderHost: renderHost)),
  );

  @override
  Future<TavernAuthoringRunSnapshot?> readAuthoringRun(String runId) async => (await _ready).readAuthoringRun(runId);

  @override
  Future<List<TavernAuthoringRunSummary>> listAuthoringRuns({
    String? draftId,
    int limit = 30,
    String? beforeRunId,
  }) async => (await _ready).listAuthoringRuns(draftId: draftId, limit: limit, beforeRunId: beforeRunId);

  @override
  Future<TavernAuthoringToolReceipt?> readAuthoringToolReceipt(String runId, String receiptId) async =>
      (await _ready).readAuthoringToolReceipt(runId, receiptId);

  @override
  Future<void> cancelAuthoringRun(String runId) async => (await _ready).cancelAuthoringRun(runId);

  @override
  Future<TavernAuthoringDraft> createAuthoringSeed(TavernAuthoringSeedInput input) async =>
      (await _ready).createAuthoringSeed(input);

  @override
  Future<TavernAuthoringSaveAsReceipt> saveAuthoringAsNew(
    String draftId, {
    required int draftRevision,
    required String physicalResourceId,
    required List<String> changeIds,
    required String operationId,
    required TavernAuthoringMediaSelection media,
    String? domainId,
  }) async => (await _ready).saveAuthoringAsNew(
    draftId,
    draftRevision: draftRevision,
    physicalResourceId: physicalResourceId,
    changeIds: changeIds,
    operationId: operationId,
    media: media,
    domainId: domainId,
  );

  @override
  Future<TavernAuthoringReceipt> applyAuthoringChanges(
    String draftId, {
    required int draftRevision,
    required String physicalResourceId,
    required List<String> changeIds,
    required TavernAuthorityRevision expectedAuthorityRevision,
    required String operationId,
  }) async => (await _ready).applyAuthoringChanges(
    draftId,
    draftRevision: draftRevision,
    physicalResourceId: physicalResourceId,
    changeIds: changeIds,
    expectedAuthorityRevision: expectedAuthorityRevision,
    operationId: operationId,
  );

  @override
  Future<TavernAuthoringOperation?> readAuthoringOperation(String operationId, {required String domainId}) async =>
      (await _ready).readAuthoringOperation(operationId, domainId: domainId);

  @override
  Future<List<TavernAuthoringRevisionSummary>> listAuthoringRevisions(String physicalResourceId) async =>
      (await _ready).listAuthoringRevisions(physicalResourceId);

  @override
  Future<TavernAuthoringReceipt> restoreAuthoringRevision(
    String physicalResourceId, {
    required TavernAuthorityRevision revision,
    required TavernAuthorityRevision expectedAuthorityRevision,
    required String operationId,
  }) async => (await _ready).restoreAuthoringRevision(
    physicalResourceId,
    revision: revision,
    expectedAuthorityRevision: expectedAuthorityRevision,
    operationId: operationId,
  );

  @override
  Future<List<TavernAuthoringDraftSummary>> listAuthoringDrafts() async => (await _ready).listAuthoringDrafts();

  @override
  Future<TavernAuthoringDraft> editAuthoringDraft(
    String draftId, {
    required int draftRevision,
    required List<TavernAuthoringChange> changes,
  }) async => (await _ready).editAuthoringDraft(draftId, draftRevision: draftRevision, changes: changes);

  @override
  Future<TavernAuthoringDraft> rebaseAuthoringDraft(
    String draftId, {
    required int draftRevision,
    required List<TavernAuthoringChange> changes,
  }) async => (await _ready).rebaseAuthoringDraft(draftId, draftRevision: draftRevision, changes: changes);

  @override
  Future<void> deleteAuthoringDraft(String draftId, {required int draftRevision}) async =>
      (await _ready).deleteAuthoringDraft(draftId, draftRevision: draftRevision);

  @override
  Future<TavernAuthoringPreview> previewAuthoringDraft(
    String draftId, {
    required int draftRevision,
    required List<String> changeIds,
  }) async => (await _ready).previewAuthoringDraft(draftId, draftRevision: draftRevision, changeIds: changeIds);

  @override
  Future<TavernAuthoringRegexTest> testAuthoringRegex(
    String draftId, {
    required int draftRevision,
    required List<String> changeIds,
    required String physicalResourceId,
    required String scriptPath,
    required String text,
  }) async => (await _ready).testAuthoringRegex(
    draftId,
    draftRevision: draftRevision,
    changeIds: changeIds,
    physicalResourceId: physicalResourceId,
    scriptPath: scriptPath,
    text: text,
  );

  @override
  Future<List<TavernToolTurnSummary>> recentToolTurns(String chatId, {int limit = 20}) async =>
      (await _ready).recentToolTurns(chatId, limit: limit);

  @override
  Stream<void> pathChanges(String chatId) => _stream((t) => t.pathChanges(chatId));

  @override
  Stream<TavernEvent> send(String chatId, String text) => _stream((t) => t.send(chatId, text));

  // Group chats (engine P2 125): the lists are copied as they are when called,
  // before waiting for the engine.

  @override
  Future<String> createGroupChat(
    List<String> characterIds, {
    String? hostCharacterId,
    String? title,
    TavernGroupActivation activation = TavernGroupActivation.natural,
    int maxSpeakersPerTurn = 3,
    bool allowSelfResponses = false,
    bool addGreetings = true,
  }) {
    final ids = List<String>.of(characterIds);
    return _ready.then(
      (t) => t.createGroupChat(
        ids,
        hostCharacterId: hostCharacterId,
        title: title,
        activation: activation,
        maxSpeakersPerTurn: maxSpeakersPerTurn,
        allowSelfResponses: allowSelfResponses,
        addGreetings: addGreetings,
      ),
    );
  }

  @override
  Future<TavernGroupChat?> groupChat(String chatId) async => (await _ready).groupChat(chatId);

  @override
  Stream<TavernGroupChat?> watchGroupChat(String chatId) => _stream((t) => t.watchGroupChat(chatId));

  @override
  Future<TavernGroupChat> addGroupMember(
    String chatId,
    String characterId, {
    double? talkativeness,
    bool muted = false,
    TavernGroupModelRole? modelRole,
  }) async => (await _ready).addGroupMember(
    chatId,
    characterId,
    talkativeness: talkativeness,
    muted: muted,
    modelRole: modelRole,
  );

  @override
  Future<TavernGroupChat> updateGroupMember(
    String chatId,
    String characterId, {
    double? talkativeness,
    bool? muted,
    TavernGroupModelRole? modelRole,
  }) async => (await _ready).updateGroupMember(
    chatId,
    characterId,
    talkativeness: talkativeness,
    muted: muted,
    modelRole: modelRole,
  );

  @override
  Future<TavernGroupChat> removeGroupMember(String chatId, String characterId) async =>
      (await _ready).removeGroupMember(chatId, characterId);

  @override
  Future<TavernGroupChat> reorderGroupMembers(String chatId, List<String> characterIds) {
    final ids = List<String>.of(characterIds);
    return _ready.then((t) => t.reorderGroupMembers(chatId, ids));
  }

  @override
  Future<TavernGroupChat> updateGroupChat(
    String chatId, {
    String? title,
    TavernGroupActivation? activation,
    int? maxSpeakersPerTurn,
    bool? allowSelfResponses,
  }) async => (await _ready).updateGroupChat(
    chatId,
    title: title,
    activation: activation,
    maxSpeakersPerTurn: maxSpeakersPerTurn,
    allowSelfResponses: allowSelfResponses,
  );

  @override
  Stream<TavernGroupEvent> sendGroup(String chatId, String text, {String? speakerCharacterId}) =>
      _stream((t) => t.sendGroup(chatId, text, speakerCharacterId: speakerCharacterId));

  @override
  Stream<TavernGroupEvent> resumeGroupTurn(String chatId) => _stream((t) => t.resumeGroupTurn(chatId));

  @override
  Stream<TavernEvent> regenerate(String chatId, String nodeId) => _stream((t) => t.regenerate(chatId, nodeId));

  @override
  Stream<TavernEvent> continueReply(String chatId, String nodeId) => _stream((t) => t.continueReply(chatId, nodeId));

  @override
  Stream<TavernEvent> impersonate(String chatId) => _stream((t) => t.impersonate(chatId));

  /// Nothing to stop before it is open: no turn can be running yet.
  @override
  void stop(String chatId) => _open?.stop(chatId);

  /// A chat's canvas document went: the open engine forgets its page state.
  @override
  void resetSPresetPage(String chatId) {
    if (_open case final TavernSPresetPageLifecycle page) page.resetSPresetPage(chatId);
  }

  @override
  Future<void> selectSibling(String chatId, String nodeId, int index) async =>
      (await _ready).selectSibling(chatId, nodeId, index);

  @override
  Future<void> selectNode(String chatId, String nodeId, {bool restoreDescendants = false}) async =>
      (await _ready).selectNode(chatId, nodeId, restoreDescendants: restoreDescendants);

  @override
  Future<void> edit(String chatId, String nodeId, String text) async => (await _ready).edit(chatId, nodeId, text);

  @override
  Future<String> deleteFrom(String chatId, String nodeId) async => (await _ready).deleteFrom(chatId, nodeId);

  @override
  Future<TavernCharacter> addCharacterBookEntry(String characterId, Map<String, Object?> entry) async =>
      (await _ready).addCharacterBookEntry(characterId, entry);

  @override
  Future<TavernCharacter> updateCharacterBookEntry(String characterId, int index, Map<String, Object?> fields) async =>
      (await _ready).updateCharacterBookEntry(characterId, index, fields);

  @override
  Future<TavernCharacter> deleteCharacterBookEntry(String characterId, int index) async =>
      (await _ready).deleteCharacterBookEntry(characterId, index);

  @override
  Future<Map<String, Object?>> previewCharacterBook(
    String characterId,
    String text, {
    String? chatId,
    int seed = 0,
  }) async => (await _ready).previewCharacterBook(characterId, text, chatId: chatId, seed: seed);

  @override
  Future<List<TavernTreeNode>> tree(String chatId) async => (await _ready).tree(chatId);

  @override
  Future<Map<String, Object?>> readVariables(String chatId) async => (await _ready).readVariables(chatId);

  @override
  Future<TavernStateSnapshot> readState(String chatId) async => (await _ready).readState(chatId);

  @override
  Future<TavernStateEditResult> setStateValue(
    String chatId,
    String path,
    Object? value, {
    String? expectedNodeId,
  }) async => (await _ready).setStateValue(chatId, path, value, expectedNodeId: expectedNodeId);

  @override
  Future<List<TavernAgentRun>> readAgentRuns(String chatId, {String? nodeId, int limit = 50}) async =>
      (await _ready).readAgentRuns(chatId, nodeId: nodeId, limit: limit);

  @override
  Future<TavernMessage> sendOnly(String chatId, String text) async => (await _ready).sendOnly(chatId, text);

  @override
  Future<TavernMessage> narrate(String chatId, String text, {String? speaker}) async =>
      (await _ready).narrate(chatId, text, speaker: speaker);

  @override
  Future<void> nameBranch(String chatId, String nodeId, String? name) async =>
      (await _ready).nameBranch(chatId, nodeId, name);

  @override
  Future<void> deleteMessage(String chatId, String nodeId) async => (await _ready).deleteMessage(chatId, nodeId);

  @override
  Future<bool> undoDeleteFrom(String chatId, String deletionId) async =>
      (await _ready).undoDeleteFrom(chatId, deletionId);

  @override
  Future<List<TavernMessage>> searchChat(String chatId, String query, {int limit = 50}) async =>
      (await _ready).searchChat(chatId, query, limit: limit);

  @override
  Stream<TavernEvent> resumeTurn(String chatId) => _stream((t) => t.resumeTurn(chatId));

  @override
  Future<TavernBackupInfo> backup(String destinationPath) async => (await _ready).backup(destinationPath);

  @override
  Future<void> setHidden(String chatId, String nodeId, bool hidden) async =>
      (await _ready).setHidden(chatId, nodeId, hidden);

  @override
  Future<TavernTurnInspection?> inspectTurn(String chatId, {String? nodeId}) async =>
      (await _ready).inspectTurn(chatId, nodeId: nodeId);

  // Stage one's tools: what the caller hands over is taken as it is at the
  // call, before the tavern opens (STAGE1-APP-INTEGRATION §10.1).

  @override
  Future<TavernToolTurnSnapshot?> readToolTurn(String logicalTurnId) async =>
      (await _ready).readToolTurn(logicalTurnId);

  @override
  Future<TavernToolReceipt?> readToolReceipt(String executionId) async => (await _ready).readToolReceipt(executionId);

  @override
  Future<TavernToolReceipt> rollDice(
    String chatId, {
    required String actionId,
    required String dice,
    String? label,
    int? target,
    String? expectedNodeId,
  }) async => (await _ready).rollDice(
    chatId,
    actionId: actionId,
    dice: dice,
    label: label,
    target: target,
    expectedNodeId: expectedNodeId,
  );

  @override
  Future<TavernMemoryDecisionReceipt> resolveMemoryProposal(
    String proposalId, {
    required String decisionId,
    required int expectedVersion,
    required TavernMemoryDecision decision,
    required TavernToolContextAnchor expectedContextAnchor,
  }) {
    // The anchor as it was when clicked, apart from the caller's object.
    final anchor = TavernToolContextAnchor.fromJson(expectedContextAnchor.toJson());
    return _ready.then(
      (t) => t.resolveMemoryProposal(
        proposalId,
        decisionId: decisionId,
        expectedVersion: expectedVersion,
        decision: decision,
        expectedContextAnchor: anchor,
      ),
    );
  }

  @override
  Future<TavernToolPolicySnapshot> readToolPolicy({String? chatId}) async =>
      (await _ready).readToolPolicy(chatId: chatId);

  @override
  Future<TavernToolPolicyWriteResult> setToolPolicy(Map<String, Object?> patch, {String? chatId}) {
    final Map<String, Object?> held;
    try {
      held = _held(patch, 'setToolPolicy')! as Map<String, Object?>;
    } on TavernScriptException catch (e) {
      return Future.error(
        TavernToolException(
          code: TavernToolErrorCode.invalidArgument,
          operation: 'setToolPolicy',
          message: e.message,
          committed: false,
          chatId: chatId,
          fieldPath: 'toolPolicy',
        ),
      );
    }
    return _ready.then((t) => t.setToolPolicy(held, chatId: chatId));
  }

  @override
  void configure(TavernModelConfig config) {
    _config = config;
    _open?.configure(config);
  }

  // Display regex, presets, regex scripts and lorebooks (T20, T21) -----------

  @override
  Future<TavernDisplayResult> displayText(
    String chatId, {
    String? nodeId,
    String? text,
    TavernRole? role,
    String? speaker,
    num? depth,
    bool reasoning = false,
  }) async => (await _ready).displayText(
    chatId,
    nodeId: nodeId,
    text: text,
    role: role,
    speaker: speaker,
    depth: depth,
    reasoning: reasoning,
  );

  @override
  Future<List<TavernPresetSummary>> listPresets() async => (await _ready).listPresets();

  @override
  Stream<List<TavernPresetSummary>> watchPresets() => _stream((t) => t.watchPresets());

  @override
  Future<TavernPreset?> preset(String presetId) async => (await _ready).preset(presetId);

  @override
  Future<TavernPresetImportResult> importPreset(String text, {String? fileName}) async =>
      (await _ready).importPreset(text, fileName: fileName);

  @override
  Future<TavernPresetImportResult> updatePreset(String presetId, Map<String, Object?> patch, {String? name}) async =>
      (await _ready).updatePreset(presetId, patch, name: name);

  @override
  Future<TavernPresetImportResult> updatePresetPrompt(
    String presetId,
    String identifier,
    Map<String, Object?> patch,
  ) async => (await _ready).updatePresetPrompt(presetId, identifier, patch);

  @override
  Future<TavernPresetImportResult> setPresetOrder(String presetId, List<String> identifiers) async =>
      (await _ready).setPresetOrder(presetId, identifiers);

  @override
  Future<TavernPresetImportResult> setPresetPromptEnabled(String presetId, String identifier, bool enabled) async =>
      (await _ready).setPresetPromptEnabled(presetId, identifier, enabled);

  @override
  Future<String> exportPreset(String presetId) async => (await _ready).exportPreset(presetId);

  @override
  Future<TavernPresetSelection> presetSelection({String? chatId}) async =>
      (await _ready).presetSelection(chatId: chatId);

  @override
  Future<void> setDefaultPreset(String? presetId) async => (await _ready).setDefaultPreset(presetId);

  @override
  Future<void> bindPreset(String chatId, String? presetId) async => (await _ready).bindPreset(chatId, presetId);

  @override
  Future<void> deletePreset(String presetId) async => (await _ready).deletePreset(presetId);

  @override
  Future<List<TavernScriptLibraryEntry>> listGlobalScripts() async => (await _ready).listGlobalScripts();

  @override
  Stream<List<TavernScriptLibraryEntry>> watchGlobalScripts() => _stream((t) => t.watchGlobalScripts());

  @override
  Future<List<TavernScriptLibraryEntry>> importGlobalScripts(String text) async =>
      (await _ready).importGlobalScripts(text);

  @override
  Future<TavernScriptLibraryEntry> setGlobalScriptEnabled(String id, bool enabled) async =>
      (await _ready).setGlobalScriptEnabled(id, enabled);

  @override
  Future<void> setGlobalScriptOrder(List<String> ids, {String? folderId}) async {
    final order = List.of(ids);
    return (await _ready).setGlobalScriptOrder(order, folderId: folderId);
  }

  @override
  Future<void> deleteGlobalScript(String id) async => (await _ready).deleteGlobalScript(id);

  @override
  Future<String> exportGlobalScripts({String? id}) async => (await _ready).exportGlobalScripts(id: id);

  @override
  Future<TavernChatScripts> chatScripts(String chatId, {String? characterId}) async =>
      (await _ready).chatScripts(chatId, characterId: characterId);

  @override
  Stream<TavernChatScripts> watchChatScripts(String chatId, {String? characterId}) =>
      _stream((t) => t.watchChatScripts(chatId, characterId: characterId));

  @override
  Future<List<TavernRegexScript>> listRegexScripts() async => (await _ready).listRegexScripts();

  @override
  Future<TavernRegexImportResult> importRegexScripts(String text) async => (await _ready).importRegexScripts(text);

  /// The edit as it is when called: copied before waiting for the engine, so
  /// a caller changing its map afterwards does not change what is saved.
  @override
  Future<TavernRegexScript> updateRegexScript(String regexId, Map<String, Object?> patch) =>
      Future<TavernRegexScript>.sync(() {
        final captured = jsonDecode(jsonEncode(patch)) as Map<String, Object?>;
        return _ready.then((tavern) => tavern.updateRegexScript(regexId, captured));
      });

  @override
  Future<TavernRegexScript> setRegexEnabled(String regexId, bool enabled) async =>
      (await _ready).setRegexEnabled(regexId, enabled);

  @override
  Future<void> deleteRegex(String regexId) async => (await _ready).deleteRegex(regexId);

  @override
  Future<String> exportRegex({String? regexId}) async => (await _ready).exportRegex(regexId: regexId);

  @override
  Future<List<TavernLorebookSummary>> listLorebooks() async => (await _ready).listLorebooks();

  @override
  Future<TavernLorebookImportResult> importLorebook(String text, {String? fileName}) async =>
      (await _ready).importLorebook(text, fileName: fileName);

  @override
  Future<Map<String, Object?>?> lorebook(String id) async => (await _ready).lorebook(id);

  @override
  Future<void> putLorebook(String id, Map<String, Object?> json) async => (await _ready).putLorebook(id, json);

  @override
  Future<String> exportLorebook(String id) async => (await _ready).exportLorebook(id);

  @override
  Future<void> deleteLorebook(String id) async => (await _ready).deleteLorebook(id);

  @override
  Future<void> bindLorebooks(
    List<String> ids, {
    WorldInfoSource source = WorldInfoSource.global,
    String? chatId,
    String? characterId,
    String? personaId,
  }) async =>
      (await _ready).bindLorebooks(ids, source: source, chatId: chatId, characterId: characterId, personaId: personaId);

  // Import reports (T22) -------------------------------------------------------

  @override
  Future<TavernImportReport?> readImportReport(TavernImportKind kind, String assetId) async =>
      (await _ready).readImportReport(kind, assetId);

  @override
  Future<TavernImportReport> recheckImport(TavernImportKind kind, String assetId) async =>
      (await _ready).recheckImport(kind, assetId);

  @override
  Future<Map<String, Object?>> readSettings({String? chatId}) async => (await _ready).readSettings(chatId: chatId);

  @override
  Future<void> setSettings(Map<String, Object?> patch, {String? chatId}) async =>
      (await _ready).setSettings(patch, chatId: chatId);

  @override
  Future<TavernDirectorSnapshot> readDirector(String chatId) async => (await _ready).readDirector(chatId);

  @override
  Stream<TavernDirectorSnapshot> watchDirector(String chatId) => _stream((t) => t.watchDirector(chatId));

  @override
  Future<TavernDirectorRun> runDirector(String chatId) async => (await _ready).runDirector(chatId);

  @override
  Future<List<TavernDirectorEvent>> readDirectorEvents(String chatId, {int limit = 50, String? beforeEventId}) async =>
      (await _ready).readDirectorEvents(chatId, limit: limit, beforeEventId: beforeEventId);

  /// One bridge for as long as this tavern lives (P2 B1): calls go straight
  /// to the engine's once it is open, and wait for it before.
  @override
  late final TavernScriptBridge scripts = _DeferredScripts(this);

  /// Nothing to close when it never opened.
  @override
  Future<void> close() async {
    final Tavern tavern;
    try {
      tavern = await _ready;
    } on Object {
      return;
    }
    await tavern.close();
  }
}

/// [DeferredTavern.scripts]. Once the engine is open each call goes straight
/// to its bridge, so the bridge copies what it is given at the call, as its
/// contract asks; before that, lists and the one raw JSON object are copied
/// here and the call waits for the engine. The latest host reaches the
/// engine when it opens. Until then nothing is claimed: no methods, no
/// scopes.
class _DeferredScripts implements TavernScriptBridge, TavernHelperGenerationControl {
  _DeferredScripts(this._tavern) {
    unawaited(
      _tavern._ready.then((t) {
        if (_pending) t.scripts.attachHost(_host);
        _pending = false;
      }, onError: (Object _) {}),
    );
  }

  final DeferredTavern _tavern;
  TavernScriptHost? _host;

  /// A host was set while the engine was still opening: it gets it on open.
  bool _pending = false;

  Future<T> _call<T>(Future<T> Function(TavernScriptBridge b) call) {
    final open = _tavern._open;
    return open != null ? call(open.scripts) : _tavern._ready.then((t) => call(t.scripts));
  }

  @override
  TavernScriptCapabilities get capabilities =>
      _tavern._open?.scripts.capabilities ??
      TavernScriptCapabilities(adapterVersion: '', methods: const {}, scopes: const {}, hostAttached: _host != null);

  @override
  void attachHost(TavernScriptHost? host) {
    _host = host;
    final open = _tavern._open;
    _pending = open == null;
    open?.scripts.attachHost(host);
  }

  @override
  Future<TavernScriptContext> openContext(TavernScriptContextSpec spec) => _call((b) => b.openContext(spec));

  @override
  Future<TavernScriptSnapshot> snapshot(String contextId) => _call((b) => b.snapshot(contextId));

  @override
  Future<void> closeContext(String contextId) => _call((b) => b.closeContext(contextId));

  @override
  Future<void> activateChat(String contextId) => _call((b) => b.activateChat(contextId));

  @override
  Stream<TavernScriptEvent> watchEvents({String? chatId}) =>
      _tavern._stream((t) => t.scripts.watchEvents(chatId: chatId));

  @override
  Future<TavernScriptMessagePage> getChatMessages(
    String contextId,
    TavernMessageRange range, {
    TavernScriptRole? role,
    TavernHiddenFilter hidden = TavernHiddenFilter.all,
    bool includeSwipes = false,
  }) => _call((b) => b.getChatMessages(contextId, range, role: role, hidden: hidden, includeSwipes: includeSwipes));

  @override
  Future<TavernScriptMutation> setChatMessages(
    String contextId,
    List<TavernScriptMessagePatch> patches, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) {
    final held = List.of(patches);
    return _call((b) => b.setChatMessages(contextId, held, options: options));
  }

  @override
  Future<TavernScriptMutation> createChatMessages(
    String contextId,
    List<TavernScriptMessageDraft> messages, {
    int? insertBefore,
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) {
    final held = List.of(messages);
    return _call((b) => b.createChatMessages(contextId, held, insertBefore: insertBefore, options: options));
  }

  @override
  Future<TavernScriptMutation> deleteChatMessages(
    String contextId,
    List<int> messageIds, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) {
    final held = List.of(messageIds);
    return _call((b) => b.deleteChatMessages(contextId, held, options: options));
  }

  @override
  Future<TavernScriptMutation> rotateChatMessages(
    String contextId,
    int begin,
    int middle,
    int end, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) => _call((b) => b.rotateChatMessages(contextId, begin, middle, end, options: options));

  @override
  Future<TavernScriptMutation> selectSwipe(
    String contextId,
    TavernScriptMessageRef message,
    int swipeId, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) => _call((b) => b.selectSwipe(contextId, message, swipeId, options: options));

  @override
  Future<TavernVariableSnapshot> getVariables(String contextId, TavernVariableTarget target) =>
      _call((b) => b.getVariables(contextId, target));

  @override
  Future<TavernVariableSnapshot> replaceVariables(
    String contextId,
    TavernVariableTarget target,
    TavernJsonObject value, {
    String? expectedVersion,
  }) {
    if (_tavern._open case final open?) {
      return open.scripts.replaceVariables(contextId, target, value, expectedVersion: expectedVersion);
    }
    final TavernJsonObject held;
    try {
      held = _held(value, 'replaceVariables') as TavernJsonObject;
    } on TavernScriptException catch (e) {
      return Future.error(e);
    }
    return _call((b) => b.replaceVariables(contextId, target, held, expectedVersion: expectedVersion));
  }

  @override
  Future<TavernVariableSnapshot> updateVariablesWith(
    String contextId,
    TavernVariableTarget target,
    FutureOr<TavernJsonObject> Function(TavernJsonObject value) updater,
  ) => _call((b) => b.updateVariablesWith(contextId, target, updater));

  @override
  Future<TavernVariableMutation> mutateVariables(
    String contextId,
    TavernVariableTarget target,
    List<TavernVariableChange> changes, {
    String? expectedVersion,
  }) {
    final held = List.of(changes);
    return _call((b) => b.mutateVariables(contextId, target, held, expectedVersion: expectedVersion));
  }

  // B2: background generation, regex and injections.

  @override
  Future<TavernScriptGeneration> generate(String contextId, TavernScriptGenerateRequest request) =>
      _call((b) => b.generate(contextId, request));

  @override
  Future<TavernScriptGeneration> generateRaw(String contextId, TavernScriptRawRequest request) =>
      _call((b) => b.generateRaw(contextId, request));

  /// Nothing can be generating before the engine is open.
  @override
  bool stopGenerationById(String generationId) => _tavern._open?.scripts.stopGenerationById(generationId) ?? false;

  // 酒馆助手's generations, shared by every page of the engine; none before
  // it opens.
  TavernHelperGenerationControl? get _control => switch (_tavern._open?.scripts) {
    final TavernHelperGenerationControl c => c,
    _ => null,
  };

  @override
  TavernHelperGenerationControlState get helperGenerationState =>
      _control?.helperGenerationState ??
      TavernHelperGenerationControlState(activeIds: const [], nonSilentIds: const []);

  @override
  Stream<TavernHelperGenerationControlState> watchHelperGenerations() => Stream.fromFuture(_tavern._ready).asyncExpand(
    (t) => switch (t.scripts) {
      final TavernHelperGenerationControl c => c.watchHelperGenerations(),
      _ => const Stream.empty(),
    },
  );

  @override
  Future<bool> stopHelperGenerationById(String generationId) async =>
      await _control?.stopHelperGenerationById(generationId) ?? false;

  @override
  Future<bool> stopAllHelperGenerations() async => await _control?.stopAllHelperGenerations() ?? true;

  @override
  Future<int> stopNonSilentHelperGenerations() async => await _control?.stopNonSilentHelperGenerations() ?? 0;

  @override
  Future<List<TavernScriptRegex>> getTavernRegexes(String contextId, TavernScriptRegexQuery query) =>
      _call((b) => b.getTavernRegexes(contextId, query));

  @override
  Future<TavernDisplayResult> formatAsTavernRegexedString(
    String contextId,
    String text, {
    required int source,
    required RegexPhase destination,
    num? depth,
    String? characterId,
  }) => _call(
    (b) => b.formatAsTavernRegexedString(
      contextId,
      text,
      source: source,
      destination: destination,
      depth: depth,
      characterId: characterId,
    ),
  );

  @override
  Future<TavernScriptInjectionLease> injectPrompts(
    String contextId,
    List<TavernScriptInjection> prompts, {
    bool once = false,
  }) {
    final held = List.of(prompts);
    return _call((b) => b.injectPrompts(contextId, held, once: once));
  }

  @override
  Future<void> uninjectPrompts(String contextId, List<String> ids) {
    final held = List.of(ids);
    return _call((b) => b.uninjectPrompts(contextId, held));
  }

  @override
  Future<void> releaseInjectionLease(String leaseId) => _call((b) => b.releaseInjectionLease(leaseId));

  @override
  Future<List<TavernScriptInjectionView>> listInjections(String contextId) => _call((b) => b.listInjections(contextId));

  // B3: Slash, macros, a character's raw data and the books in play. What
  // the caller hands over is taken as it is now, not once the engine opens.

  @override
  Future<TavernSlashExecution> triggerSlash(
    String contextId,
    String source, {
    String? executionId,
    String pipe = '',
    Map<String, String> arguments = const {},
  }) {
    if (_tavern._open case final open?) {
      return open.scripts.triggerSlash(contextId, source, executionId: executionId, pipe: pipe, arguments: arguments);
    }
    final held = Map<String, String>.of(arguments);
    return _call((b) => b.triggerSlash(contextId, source, executionId: executionId, pipe: pipe, arguments: held));
  }

  /// Nothing can be running before the engine is open.
  @override
  bool stopScript(String executionId) => _tavern._open?.scripts.stopScript(executionId) ?? false;

  @override
  Future<String> substituteMacros(String contextId, String text) => _call((b) => b.substituteMacros(contextId, text));

  @override
  Future<TavernCharacter> replaceCharacterData(
    String contextId,
    String characterId,
    TavernJsonObject data, {
    String? expectedVersion,
  }) {
    if (_tavern._open case final open?) {
      return open.scripts.replaceCharacterData(contextId, characterId, data, expectedVersion: expectedVersion);
    }
    final TavernJsonObject held;
    try {
      held = _held(data, 'replaceCharacterData') as TavernJsonObject;
    } on TavernScriptException catch (e) {
      return Future.error(e);
    }
    return _call((b) => b.replaceCharacterData(contextId, characterId, held, expectedVersion: expectedVersion));
  }

  @override
  Future<TavernMvuInitialization> setMvuEnabled(String contextId, bool enabled) =>
      _call((b) => b.setMvuEnabled(contextId, enabled));

  @override
  Future<TavernMvuParseResult> parseMvuMessage(String contextId, String message, TavernJsonObject previousData) =>
      _call((b) => b.parseMvuMessage(contextId, message, previousData));

  @override
  Future<TavernScriptCharacterAvatarSnapshot> readCharacterAvatar(String contextId, String characterId) =>
      _call((b) => b.readCharacterAvatar(contextId, characterId));

  @override
  Future<TavernScriptCharacterAvatarSnapshot> replaceCharacterAvatar(
    String contextId,
    String characterId,
    Uint8List bytes, {
    required String expectedVersion,
  }) => _call((b) => b.replaceCharacterAvatar(contextId, characterId, bytes, expectedVersion: expectedVersion));

  @override
  Future<TavernScriptWorldInfoSettingsSnapshot> updateWorldInfoSettings(
    String contextId,
    TavernJsonObject patch, {
    String? expectedVersion,
  }) => _call((b) => b.updateWorldInfoSettings(contextId, patch, expectedVersion: expectedVersion));

  @override
  Future<TavernScriptButtonsSnapshot> replaceScriptButtons(
    String contextId,
    List<TavernScriptButton> buttons, {
    String? expectedVersion,
  }) => _call((b) => b.replaceScriptButtons(contextId, buttons, expectedVersion: expectedVersion));

  @override
  Future<TavernScriptBookDirectorySnapshot> getBookDirectory(String contextId) =>
      _call((b) => b.getBookDirectory(contextId));

  @override
  Future<TavernScriptBookRef> resolveBook(String contextId, String nameOrHandle) =>
      _call((b) => b.resolveBook(contextId, nameOrHandle));

  @override
  Future<TavernScriptBookSnapshot> createBook(String contextId, String name, TavernJsonObject raw) =>
      _call((b) => b.createBook(contextId, name, raw));

  @override
  Future<void> deleteBook(String contextId, TavernScriptBookRef ref, {required String expectedVersion}) =>
      _call((b) => b.deleteBook(contextId, ref, expectedVersion: expectedVersion));

  @override
  Future<TavernScriptBookBindingsSnapshot> readBookBindings(String contextId, TavernScriptBookBindingsTarget target) =>
      _call((b) => b.readBookBindings(contextId, target));

  @override
  Future<TavernScriptBookBindingsSnapshot> updateBookBindings(
    String contextId,
    TavernScriptBookBindingsEdit edit, {
    required String expectedVersion,
  }) => _call((b) => b.updateBookBindings(contextId, edit, expectedVersion: expectedVersion));

  @override
  Future<TavernScriptPresetSnapshot> readPreset(String contextId, TavernScriptPresetRef ref) =>
      _call((b) => b.readPreset(contextId, ref));

  @override
  Future<TavernScriptPresetSnapshot> replacePreset(
    String contextId,
    TavernScriptPresetRef ref,
    TavernJsonObject raw, {
    required String expectedVersion,
  }) => _call((b) => b.replacePreset(contextId, ref, raw, expectedVersion: expectedVersion));

  @override
  Future<TavernScriptRegexWriteSnapshot> readTavernRegexesForWrite(
    String contextId,
    TavernScriptRegexWriteTarget target,
  ) => _call((b) => b.readTavernRegexesForWrite(contextId, target));

  @override
  Future<TavernScriptRegexWriteSnapshot> replaceTavernRegexes(
    String contextId,
    TavernScriptRegexWriteTarget target,
    List<TavernScriptRegexWriteItem> items, {
    required String expectedVersion,
  }) => _call((b) => b.replaceTavernRegexes(contextId, target, items, expectedVersion: expectedVersion));

  @override
  Future<List<TavernScriptBookBinding>> getContextBooks(String contextId) => _call((b) => b.getContextBooks(contextId));

  @override
  Future<TavernScriptBookSnapshot> readBook(String contextId, TavernScriptBookRef ref) =>
      _call((b) => b.readBook(contextId, ref));

  @override
  Future<TavernScriptBookSnapshot> replaceBook(
    String contextId,
    TavernScriptBookRef ref,
    TavernJsonObject book, {
    String? expectedVersion,
  }) {
    if (_tavern._open case final open?) {
      return open.scripts.replaceBook(contextId, ref, book, expectedVersion: expectedVersion);
    }
    final TavernJsonObject held;
    try {
      held = _held(book, 'replaceBook') as TavernJsonObject;
    } on TavernScriptException catch (e) {
      return Future.error(e);
    }
    return _call((b) => b.replaceBook(contextId, ref, held, expectedVersion: expectedVersion));
  }
}

/// [value] as it is now: maps and lists copied all the way down, the rest
/// kept for the engine to judge. A cycle is not JSON.
Object? _held(Object? value, String operation, [Set<Object>? seen]) {
  if (value is! Map && value is! List) return value;
  final active = seen ?? Set<Object>.identity();
  if (!active.add(value!)) {
    throw TavernScriptException(
      code: TavernScriptErrorCode.invalidJson,
      operation: operation,
      message: 'The value contains a cycle.',
    );
  }
  try {
    return switch (value) {
      Map<String, Object?>() => <String, Object?>{
        for (final MapEntry(:key, value: v) in value.entries) key: _held(v, operation, active),
      },
      Map() => {for (final MapEntry(:key, value: v) in value.entries) key: _held(v, operation, active)},
      List() => [for (final v in value) _held(v, operation, active)],
      _ => value,
    };
  } finally {
    active.remove(value);
  }
}

/// An authoring run asked for before the engine opened: its id now, the rest
/// from the engine's own run once there is one.
class _DeferredAuthoringRun implements TavernAuthoringRun {
  _DeferredAuthoringRun(this.runId, this._run);

  @override
  final String runId;
  final Future<TavernAuthoringRun> _run;

  @override
  Stream<TavernAuthoringRunEvent> get events => Stream.fromFuture(_run).asyncExpand((run) => run.events);

  @override
  Future<TavernAuthoringRunSnapshot> get result => _run.then((run) => run.result);

  @override
  Future<void> cancel() async => (await _run).cancel();
}

/// An authoring task asked for before the engine opened: its id now, its
/// result and cancellation from the engine's own task once there is one.
class _DeferredTask<T> implements TavernAuthoringTask<T> {
  _DeferredTask(this.requestId, this._task);

  @override
  final String requestId;
  final Future<TavernAuthoringTask<T>> _task;

  @override
  Future<T> get result => _task.then((task) => task.result);

  @override
  Future<void> cancel() async => (await _task).cancel();
}

/// A trial asked for before the engine opened: until its task is there, the
/// view says that nothing has run yet.
class _DeferredSimulation implements TavernAuthoringSimulationTask {
  _DeferredSimulation(this._request, this._task) {
    unawaited(_task.then((task) => _started = task, onError: (Object _) => null));
  }

  final TavernAuthoringSimulationRequest _request;
  final Future<TavernAuthoringSimulationTask> _task;
  TavernAuthoringSimulationTask? _started;

  @override
  String get requestId => _request.requestId;

  @override
  Future<TavernAuthoringSimulationResult> get result => _task.then((task) => task.result);

  @override
  Future<void> cancel() async => (await _task).cancel();

  @override
  TavernAuthoringSimulationResult get view =>
      _started?.view ??
      TavernAuthoringSimulationResult(
        requestId: _request.requestId,
        captureId: '',
        draftId: _request.draftId,
        draftRevision: _request.draftRevision,
        changeIds: _request.changeIds,
        status: TavernAuthoringSimulationStatus.running,
        origin: const {},
        turns: const [],
        requests: const [],
        usage: const {},
        cleanup: const {},
        issues: const [],
      );
}
