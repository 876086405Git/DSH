// The tavern's surface for the app (docs/design/roleplay.md §4): what the
// screens read and call. The engine behind it — card IO, the chat store, the
// prompt assembler, the model client — implements [Tavern]; the app holds one
// and never reaches past it.
//
// Pure Dart, no Flutter. Everything here is value types and one interface, so
// the app can be built against a fake before the engine lands.

import 'dart:typed_data';

import 'authoring.dart';
import 'authoring_preview.dart';
import 'authoring_render.dart';
import 'authoring_run.dart';
import 'authoring_script_preview.dart';
import 'authoring_seed.dart';
import 'authoring_simulation.dart';
import 'backup.dart';
import 'director.dart';
import 'gameplay.dart';
import 'gameplay_bindings.dart';
import 'gameplay_cast.dart';
import 'gameplay_export.dart';
import 'gameplay_packs.dart';
import 'import_report.dart';
import 'inspection.dart';
import 'lorebook_library.dart';
import 'persona.dart';
import 'preset_library.dart';
import 'regex_library.dart';
import 'script_library.dart';
import 'scripts.dart';
import 'state.dart';
import 'tools.dart';
import 'worldinfo/world_info.dart' show WorldInfoSource;

part 'group.dart';

enum PresetSelectionSource { chat, chatInline, globalDefault, globalInline, stDefault }

/// Selection for a newly admitted turn. Missing legacy ids fall through to
/// the next complete preset without rewriting the stored chat binding.
class TavernPresetSelection {
  const TavernPresetSelection({
    required this.source,
    required this.boundPresetId,
    required this.defaultPresetId,
    required this.effectivePresetId,
    this.missingPresetIds = const [],
  });
  final PresetSelectionSource source;
  final String? boundPresetId;
  final String? defaultPresetId;
  final String? effectivePresetId;
  final List<String> missingPresetIds;
}

/// One character in the library: the card's V3 `data` plus what the library
/// knows about it.
class TavernCharacter {
  const TavernCharacter({
    required this.id,
    required this.name,
    this.nickname,
    this.creator,
    this.tags = const [],
    this.avatarPath,
    this.theme,
    this.assets = const [],
    this.description = '',
    this.creatorNotes = '',
    this.greetings = const [],
    this.regexCount = 0,
    this.scriptCount = 0,
    this.hasLorebook = false,
    this.chatCount = 0,
    this.lastChatAt,
    this.importedAt,
    this.regexDiagnostics = const [],
  });

  final String id;
  final String name;
  final String? nickname;
  final String? creator;
  final List<String> tags;

  /// The card picture on this phone (the PNG it came in, or the `main` icon).
  final String? avatarPath;

  /// Detached extensions.dshgo.theme on complete details. Missing/null stays
  /// null; list summaries omit it. The app interprets this raw JSON value.
  final Object? theme;

  /// Declared V3 asset objects in original order on complete details. Summary
  /// lists leave this empty; call character(id) for appearance and local paths.
  /// Non-object declarations stay in characterFields, but not this view.
  final List<TavernCharacterAsset> assets;
  final String description;

  /// May carry HTML; the canvas renders it.
  final String creatorNotes;

  /// `first_mes` first, then `alternate_greetings`.
  final List<String> greetings;

  /// The card's own regex scripts and 酒馆助手 scripts (roleplay-compat.md §6.1).
  final int regexCount;
  final int scriptCount;
  final bool hasLorebook;

  final int chatCount;
  final DateTime? lastChatAt;
  final DateTime? importedAt;

  /// Checks returned by a new import. Unified persistent intake reports are
  /// separate; reading an older library entry need not populate this.
  final List<TavernRegexDiagnostic> regexDiagnostics;
}

/// One declared V3 asset. Missing or non-string fields are null in this view;
/// the original card JSON is retained unchanged by the library.
class TavernCharacterAsset {
  const TavernCharacterAsset({this.type, this.name, this.uri, this.ext, this.localPath});

  final String? type;
  final String? name;

  /// The original URI, including an unchanged remote URL or embedded reference.
  final String? uri;
  final String? ext;

  /// A resolved local file path when the library has materialized this asset.
  /// A missing reference or remote URL has no local path; URI reads never
  /// download remote resources or rewrite the stored declaration.
  final String? localPath;
}

/// A conversation in the list.
class TavernChatSummary {
  TavernChatSummary({
    required this.id,
    required this.characterId,
    required this.title,
    required this.updatedAt,
    this.lastText,
    this.messageCount = 0,
    this.kind = TavernChatKind.single,
    List<String> memberCharacterIds = const [],
  }) : memberCharacterIds = List<String>.unmodifiable(memberCharacterIds);

  final String id;
  final String characterId;
  final String title;
  final DateTime updatedAt;

  /// The last message on the current path, plain text, for a preview line.
  final String? lastText;
  final int messageCount;
  final TavernChatKind kind;
  final List<String> memberCharacterIds;
}

enum TavernRole { user, character, narrator, system }

/// One message on the current path. Alternatives are siblings in the tree
/// (roleplay.md §5.2): [siblingIndex] of [siblingCount].
class TavernMessage {
  const TavernMessage({
    required this.nodeId,
    required this.role,
    required this.speaker,
    required this.text,
    required this.at,
    this.parentId,
    this.reasoning,
    this.siblingIndex = 0,
    this.siblingCount = 1,
    this.hidden = false,
    this.usage,
    this.reportedUsage,
    this.speakerCharacterId,
  });

  final String nodeId;
  final String? parentId;
  final TavernRole role;

  /// Display name: the character's or the persona's.
  final String speaker;

  /// Stable library identity; null for users, narration and unknown imports.
  final String? speakerCharacterId;

  /// The stored text (after write-back regex). Use displayText for an ephemeral
  /// display-regex copy; Markdown rendering remains the caller's responsibility.
  final String text;
  final String? reasoning;
  final DateTime at;
  final int siblingIndex;
  final int siblingCount;

  /// Kept out of the prompt (ST `/hide`).
  final bool hidden;
  final TavernUsage? usage;

  /// Provider usage for this node's latest recorded generation, without
  /// rebuilding its full inspection. Null means that call reported none;
  /// it is not replaced with estimates or a continued message's older usage.
  /// A live path/snapshot uses the current call's report, if already received.
  final TavernUsage? reportedUsage;
}

/// One stored node in the complete message tree, including inactive branches.
/// Soft-deleted nodes are excluded; ST-hidden nodes remain in the tree.
/// Values are detached from storage; reading them never evaluates macros.
class TavernTreeNode {
  const TavernTreeNode({
    required this.nodeId,
    required this.role,
    required this.speaker,
    required this.preview,
    required this.at,
    required this.isCurrentPath,
    this.parentId,
    this.siblingIndex = 0,
    this.siblingCount = 1,
    this.hidden = false,
    this.branchName,
    this.speakerCharacterId,
  });

  final String nodeId;
  final String? parentId;
  final TavernRole role;
  final String speaker;

  /// The first 64 Unicode code points of the stored text, without stripping
  /// whitespace, Markdown or macros. This never splits a surrogate pair.
  final String preview;
  final DateTime at;

  /// Whether this node is an ancestor of, or is, the current selected leaf.
  /// Hidden messages may still belong to the current path.
  final bool isCurrentPath;
  final int siblingIndex;
  final int siblingCount;
  final bool hidden;

  /// An optional label for the branch starting at this node.
  final String? branchName;
  final String? speakerCharacterId;
}

/// Legacy normalized token counters. They do not establish whether each raw
/// provider field was present; exact multi-request evidence lives in tool usage.
class TavernUsage {
  const TavernUsage({this.promptTokens = 0, this.cacheHitTokens = 0, this.completionTokens = 0, this.model});

  final int promptTokens;
  final int cacheHitTokens;
  final int completionTokens;
  final String? model;
}

/// Saved provider-reported counters grouped by model and the call's UTC hour.
/// A null model is its own group; [replyCount] counts replies with a report,
/// including reports whose counters are zero.
class TavernPathUsage {
  const TavernPathUsage({
    required this.model,
    required this.utcWeekday,
    required this.utcHour,
    required this.promptTokens,
    required this.cacheHitTokens,
    required this.completionTokens,
    required this.replyCount,
  });

  final String? model;

  /// Monday = 1 through Sunday = 7. Older reports without a saved call time
  /// use the reply timestamp; a historical continuation can therefore be approximate.
  final int utcWeekday;

  /// 0 through 23. Each model has at most 168 weekday/hour groups.
  final int utcHour;
  final int promptTokens;
  final int cacheHitTokens;
  final int completionTokens;
  final int replyCount;
}

/// The small identity view of one stored logical tool turn.
class TavernToolTurnSummary {
  const TavernToolTurnSummary({required this.logicalTurnId, required this.replyNodeId});

  final String logicalTurnId;

  /// Null until the turn adopts a reply, or after that physical reply is
  /// deleted. This association does not assert that the turn added new text.
  final String? replyNodeId;
}

/// A turn as it streams. A turn always ends with exactly one [TavernTurnDone]
/// or [TavernTurnFailed].
sealed class TavernEvent {
  const TavernEvent();
}

/// First event when reconnecting to an active turn. This is the complete
/// in-memory body at subscription time, including uncheckpointed text.
class TavernTurnSnapshot extends TavernEvent {
  const TavernTurnSnapshot({
    required this.chatId,
    required this.generationType,
    required this.startedAt,
    this.message,
    this.logicalTurnId,
  });

  final String chatId;
  final String generationType;
  final DateTime startedAt;
  final String? logicalTurnId;

  /// Null while preparing the request, before a reply node exists. Later
  /// TavernTurnStarted supplies it. Impersonation has a temporary user node.
  final TavernMessage? message;
}

/// The node the reply is written into exists (a new one, or a new sibling).
class TavernTurnStarted extends TavernEvent {
  const TavernTurnStarted(this.message, {this.logicalTurnId});

  /// Empty for a new reply; continuation retains its existing body. Carries
  /// the node id and its place among siblings.
  final TavernMessage message;
  final String? logicalTurnId;
}

/// Refresh notification after actual tool audit adoption. It carries only
/// durable identities; observing it never executes or repeats an action.
class TavernToolActivity extends TavernEvent {
  const TavernToolActivity(this.logicalTurnId, {this.requestId, this.executionId, this.proposalId});
  final String logicalTurnId;
  final String? requestId;
  final String? executionId;
  final String? proposalId;
}

class TavernTextDelta extends TavernEvent {
  const TavernTextDelta(this.nodeId, this.text);
  final String nodeId;
  final String text;
}

class TavernReasoningDelta extends TavernEvent {
  const TavernReasoningDelta(this.nodeId, this.text);
  final String nodeId;
  final String text;
}

class TavernTurnDone extends TavernEvent {
  TavernTurnDone(this.message, {this.finishReason, this.logicalTurnId, List<TavernScriptIssue> hookIssues = const []})
    : hookIssues = List.unmodifiable(hookIssues);

  /// As stored: write-back regex applied, usage filled in.
  final TavernMessage message;

  /// The provider's finish_reason, including length or content_filter. Null
  /// means the transport did not report one; unknown future values are kept.
  final String? finishReason;
  final String? logicalTurnId;
  final List<TavernScriptIssue> hookIssues;
}

enum TavernFailure {
  noKey,
  badKey,
  busy,
  network,
  server,
  contextTooLong,
  cancelled,
  invalidCard,
  insufficientBalance,
  invalidParameters,
  toolFailure,
}

class TavernTurnFailed extends TavernEvent {
  TavernTurnFailed(
    this.kind, {
    this.detail,
    this.partial,
    this.logicalTurnId,
    this.toolFailureCode,
    List<TavernScriptIssue> hookIssues = const [],
  }) : hookIssues = List.unmodifiable(hookIssues);
  final TavernFailure kind;
  final String? logicalTurnId;

  /// Stable project terminal code for toolFailure; never a provider finish reason.
  final String? toolFailureCode;

  /// For 「详情」: a status code, the first part of an error body.
  final String? detail;

  /// Whatever arrived before it failed or was stopped; null when nothing was
  /// stored (the user's line goes back into the composer).
  final TavernMessage? partial;
  final List<TavernScriptIssue> hookIssues;
}

enum TavernCardFormat { png, json, charx }

/// A named ST JSONL document. The filename is a label, never a path to read.
/// Bytes are copied at construction and cannot be changed through this value.
final class TavernChatFile {
  TavernChatFile({required this.fileName, required Uint8List bytes})
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  final String fileName;
  final Uint8List bytes;
}

/// One atomic batch may contain several independent chats and their branches.
final class TavernChatImportResult {
  TavernChatImportResult({
    required List<String> chatIds,
    required Map<String, String> chatsByFile,
    required List<String> notices,
  }) : chatIds = List<String>.unmodifiable(chatIds),
       chatsByFile = Map<String, String>.unmodifiable(chatsByFile),
       notices = List<String>.unmodifiable(notices);

  final List<String> chatIds;
  final Map<String, String> chatsByFile;
  final List<String> notices;
}

/// One conversation in a DeepSeek export, as a list of them shows it.
final class TavernDeepSeekSession {
  const TavernDeepSeekSession({
    required this.id,
    required this.title,
    required this.messageCount,
    this.updatedAt,
    this.imported,
  });

  /// Its id in the export.
  final String id;

  /// As DeepSeek titled it; empty when it had none.
  final String title;
  final int messageCount;
  final DateTime? updatedAt;

  /// Where it lives when it was taken in before.
  final TavernDeepSeekImported? imported;
}

/// A DeepSeek conversation taken in: the character made for it and its chat.
final class TavernDeepSeekImported {
  const TavernDeepSeekImported({required this.sessionId, required this.characterId, required this.chatId});

  final String sessionId;
  final String characterId;
  final String chatId;
}

/// Where the model calls go. The key is read through [apiKey] each call, so
/// the app keeps it in secure storage and the engine never stores it.
class TavernModelConfig {
  const TavernModelConfig({
    required this.apiKey,
    this.baseUrl = 'https://api.deepseek.com',
    this.model = 'deepseek-flash',
    this.deepseek = true,
    this.thinking = false,
    this.headers = const {},
    this.auxiliary,
  });

  final Future<String?> Function() apiKey;
  final String baseUrl;
  final String model;

  /// DeepSeek's own API: ST's DeepSeek post-processing and `/beta` prefix
  /// continuation (roleplay-compat.md §3.4). False: a plain OpenAI-compatible
  /// endpoint.
  final bool deepseek;
  final bool thinking;

  /// Additional HTTP headers, never included in inspection data or logs.
  /// A non-empty [apiKey] overrides Authorization with Bearer authentication.
  /// Otherwise OpenAI-compatible channels keep any supplied Authorization.
  final Map<String, String> headers;

  /// Configuration for director, secret and other helper requests. Null keeps
  /// the current channel, using DeepSeek flash or the configured generic model
  /// with thinking disabled. An explicit configuration is used as supplied.
  final TavernModelConfig? auxiliary;
}

/// The tavern. One per app; [open] it on the app's support directory.
abstract interface class Tavern {
  /// Persisted script data and awaited App lifecycle bridge. Capabilities
  /// distinguish the implemented surface from later script/generation layers.
  TavernScriptBridge get scripts;

  // Authoring drafts ----------------------------------------------------------

  /// Captures existing sources in their actual writer queues. Characters and
  /// standalone books include a durable authority revision. Other targets
  /// support drafts and static checks, but not adoption.
  Future<TavernAuthoringDraft> createAuthoringDraft(List<TavernAuthoringTarget> targets);
  Future<TavernAuthoringDraft?> readAuthoringDraft(String draftId);

  /// Summary discovery does not validate every saved change; read or preview
  /// a draft to validate its complete persisted structure.
  Future<List<TavernAuthoringDraftSummary>> listAuthoringDrafts();

  /// Replaces the change list, keeping its saved base, and advances the draft
  /// revision. Input values are captured before the first asynchronous wait.
  Future<TavernAuthoringDraft> editAuthoringDraft(
    String draftId, {
    required int draftRevision,
    required List<TavernAuthoringChange> changes,
  });

  /// Explicitly captures a new base and adopts only the resubmitted changes.
  /// An empty list resets the draft for a subsequent editing step.
  Future<TavernAuthoringDraft> rebaseAuthoringDraft(
    String draftId, {
    required int draftRevision,
    required List<TavernAuthoringChange> changes,
  });
  Future<void> deleteAuthoringDraft(String draftId, {required int draftRevision});

  /// Selects explicit change IDs, checks dependency closure, and runs static
  /// intake checks. It does not execute macros or write an import report.
  Future<TavernAuthoringPreview> previewAuthoringDraft(
    String draftId, {
    required int draftRevision,
    required List<String> changeIds,
  });
  Future<TavernAuthoringRegexTest> testAuthoringRegex(
    String draftId, {
    required int draftRevision,
    required List<String> changeIds,
    required String physicalResourceId,
    required String scriptPath,
    required String text,
  });

  /// Adopts one physical resource after checking its saved base, the supplied
  /// durable revision and the fresh source inside its actual writer queue.
  /// The draft stays unchanged. Further changes to an adopted target require
  /// an explicit rebase; untouched targets can still use their saved bases.
  /// Reusing an operation ID with the same parameters returns its receipt,
  /// including after the draft was deleted, without repeating the write.
  Future<TavernAuthoringReceipt> applyAuthoringChanges(
    String draftId, {
    required int draftRevision,
    required String physicalResourceId,
    required List<String> changeIds,
    required TavernAuthorityRevision expectedAuthorityRevision,
    required String operationId,
  });

  Future<TavernAuthoringOperation?> readAuthoringOperation(String operationId, {required String domainId});

  /// Lists confirmed adoptions only. Prepared and unconfirmed operations are
  /// available through readAuthoringOperation and are not committed versions.
  Future<List<TavernAuthoringRevisionSummary>> listAuthoringRevisions(String physicalResourceId);

  /// Uses a historical JSON after-image as a new adoption with a new version.
  /// The target must still exist; a character must retain the same library
  /// identity and available media. This does not restore deleted media or
  /// overwrite library.json, original imports or attachments.
  Future<TavernAuthoringReceipt> restoreAuthoringRevision(
    String physicalResourceId, {
    required TavernAuthorityRevision revision,
    required TavernAuthorityRevision expectedAuthorityRevision,
    required String operationId,
  });

  /// Starts a separate authoring conversation whose tools only edit drafts.
  /// Reusing the same run identity never sends another model request.
  TavernAuthoringRun startAuthoringRun(
    TavernAuthoringRunRequest request, {
    TavernAuthoringPromptHost? promptHost,
    TavernAuthoringPreviewHost? renderHost,
  });
  Future<TavernAuthoringRunSnapshot?> readAuthoringRun(String runId);
  Future<List<TavernAuthoringRunSummary>> listAuthoringRuns({String? draftId, int limit = 30, String? beforeRunId});
  Future<TavernAuthoringToolReceipt?> readAuthoringToolReceipt(String runId, String receiptId);
  Future<void> cancelAuthoringRun(String runId);

  /// Saves an imported container as a draft, retaining its raw source and media.
  Future<TavernAuthoringDraft> createAuthoringSeed(TavernAuthoringSeedInput input);

  /// Creates one new resource without changing the source draft. Preserve the
  /// returned operation domain on retries, especially after a root restore.
  Future<TavernAuthoringSaveAsReceipt> saveAuthoringAsNew(
    String draftId, {
    required int draftRevision,
    required String physicalResourceId,
    required List<String> changeIds,
    required String operationId,
    required TavernAuthoringMediaSelection media,
    String? domainId,
  });

  /// Prepares the complete selected prompt in an isolated captured context.
  /// Unsupported dependencies return no assembly and never fall back to live execution.
  TavernAuthoringTask<TavernAuthoringPromptPreview> previewAuthoringPrompt(
    TavernAuthoringPromptRequest request, {
    TavernAuthoringPromptHost? host,
  });

  /// Renders selected saved content through an App-owned independent static
  /// renderer. No prompt preparation, live scripts or model request is run.
  /// Completion/cancellation waits for the session's actual work and close.
  TavernAuthoringTask<TavernAuthoringRenderResult> renderAuthoringDraft(
    TavernAuthoringRenderRequest request, {
    required TavernAuthoringPreviewHost host,
  });

  /// Runs one to four real normal sends in a private temporary sample chat.
  /// This uses captured files with their original IDs and saved diagnostics,
  /// then the real fresh-open loaders. Helpers/retries are additional actual
  /// requests. Repeating requestId is a new invocation and can spend again.
  /// Cancellation waits for real requests, key suppliers, close and cleanup.
  TavernAuthoringSimulationTask simulateAuthoringDraft(TavernAuthoringSimulationRequest request);

  // Gameplay pack catalog ----------------------------------------------------

  /// Saves immutable dshpack v1 bytes and original import diagnostics.
  /// This does not bind or execute the pack. castCard files are full CCv3 JSON.
  /// A post-COMMIT publication failure carries the adopted import result.
  Future<TavernPackImportResult> importGameplayPack(Uint8List bytes);

  /// Lists installed versions; tombstones are omitted unless requested.
  Future<List<TavernPackVersion>> listGameplayPacks({bool includeRemoved = false});

  /// Returns saved data, including tombstones, or null for a missing version.
  Future<TavernPackVersion?> readGameplayPack(TavernPackVersionRef ref);

  /// Returns exact resource bytes or null for a missing version/local identity.
  Future<TavernPackResource?> readGameplayPackResource(TavernPackVersionRef ref, String localId);

  /// Returns the originally saved ZIP, also for a removed version.
  Future<Uint8List> exportInstalledGameplayPack(TavernPackVersionRef ref);

  /// Marks availability removed without deleting payload. Preserve expected's
  /// domain and the complete operation parameters when retrying.
  Future<TavernPackRemovalReceipt> removeGameplayPackVersion(
    TavernPackVersionRef ref, {
    required TavernGameplayRevision expected,
    required String operationId,
  });

  /// Reads a complete persisted scope, including disabled and removed slots.
  Future<TavernPackScopeSnapshot> readGameplayBindings(TavernPackScopeTarget scope);

  /// Applies one operation atomically to one scope. Retry with the original
  /// domain token, operation id, and complete parameters to replay its receipt.
  Future<TavernPackBindingReceipt> updateGameplayBindings(
    TavernPackScopeTarget scope, {
    required TavernGameplayRevision expected,
    required String operationId,
    required List<TavernPackBindingEdit> edits,
  });

  /// Resolves current bindings with explicit candidate scopes substituted.
  /// This neither saves bindings nor initializes an absent state value.
  Future<TavernGameplayResolution> resolveGameplayConfig(
    TavernGameplayContext context, {
    List<TavernPackScopePreview> proposedScopes = const [],
    bool validateCurrentState = false,
  });

  /// Imports one explicit cast source through the existing prepared writer.
  /// Retain the complete source/domain/operation intent for a replay.
  Future<TavernCastImportResult> importDshgoCastMember(
    TavernCastSource source,
    String localCastId, {
    required String operationId,
    String? domainId,
  });

  /// Reads the original stored outcome without publishing or importing again.
  Future<TavernCastImportResult?> readDshgoCastImport(String domainId, String operationId);

  /// Captures a complete prospective export without saving any source or pack.
  Future<TavernGameplayExportPreview> previewGameplayExport(TavernGameplayExportRequest request);

  /// Recaptures and compares the full preview before encoding a new card.
  Future<Uint8List> exportCharacterWithPacks(TavernGameplayExportRequest request, {required String expectedPreviewId});

  /// Exports selected materialized draft candidates into a new pack's bytes.
  /// This does not install, bind, publish or overwrite an installed version.
  Future<Uint8List> exportGameplayPackFromDraft(
    TavernGameplayExportRequest request, {
    required String expectedPreviewId,
  });

  // Library ------------------------------------------------------------------

  /// The saved capability snapshot, or null for a missing/legacy asset.
  /// Reading compares the current inspection-input fingerprint with the saved
  /// fingerprint. Restoring a match can make stale false; checkedAt and findings
  /// still describe the saved snapshot. Explicit rechecking and
  /// updateRegexScript refresh it; reading does not run compatibility work.
  Future<TavernImportReport?> readImportReport(TavernImportKind kind, String assetId);

  /// Explicitly inspects the current asset, including legacy imports, and
  /// atomically replaces its report. No macros or embedded scripts execute.
  /// Regex rechecks also refresh compatibility diagnostics used by subsequent
  /// executions; the user's original data and disabled flag are not changed.
  Future<TavernImportReport> recheckImport(TavernImportKind kind, String assetId);

  /// Character summaries, newest chat first, then newest import. Emits the
  /// current list first. Reads the library index, not card bodies or assets.
  /// Name, nickname, creator, tags, avatar path, counts and dates are included;
  /// description, greetings, creatorNotes and regexDiagnostics are empty.
  /// Use [character] for full card details.
  Stream<List<TavernCharacter>> watchCharacters();

  /// Loads one character's full details, including greetings and creatorNotes.
  Future<TavernCharacter?> character(String id);

  /// The complete V3 `data` object, including read-only unknown fields. The
  /// returned map is detached: editing it does not change the stored card.
  /// Optional fields may be absent. Null means the character does not exist.
  Future<Map<String, Object?>?> characterFields(String characterId);

  /// Saves only the supplied fields, retaining the rest of the card and all
  /// original assets. Editable strings: `name`, `nickname`, `description`,
  /// `personality`, `scenario`, `first_mes`, `mes_example`, `system_prompt`,
  /// `post_history_instructions`, `creator_notes`, `creator`,
  /// `character_version`. `alternate_greetings` and `tags` are string lists.
  ///
  /// Empty strings/lists clear a field; null and other keys/types throw
  /// [ArgumentError]. A nonempty patch updates V3 `modification_date` in Unix
  /// seconds. An empty patch is a read. Missing characters throw
  /// [TavernImportError]. Existing messages keep their text and speaker names.
  Future<TavernCharacter> updateCharacterFields(String characterId, Map<String, Object?> fields);

  /// Appends an entry to the card's V3 character_book, creating the book when
  /// absent. The library assigns an unused id; supplying an id is rejected.
  /// Unknown stored fields and original assets remain intact. Input JSON is
  /// captured before waiting. Existing missing/null ids are fixed to their
  /// fallback index; normalizing a null id can invalidate that entry's timers.
  Future<TavernCharacter> addCharacterBookEntry(String characterId, Map<String, Object?> entry);

  /// Patches the entry at its original entries-array [index], not its sorted
  /// display position or id. Extensions merge recursively; an id patch is
  /// rejected. Invalid indices throw [RangeError]. An empty patch is a read;
  /// real edits normalize missing/null ids as [addCharacterBookEntry] does.
  Future<TavernCharacter> updateCharacterBookEntry(String characterId, int index, Map<String, Object?> fields);

  /// Removes only this entry from the original entries array. Missing/null ids are
  /// fixed to their pre-edit fallback indices so later entries keep identity.
  /// Native ST entries objects remain readable but are not edited by this API.
  Future<TavernCharacter> deleteCharacterBookEntry(String characterId, int index);

  /// Tests this card's embedded book against [text], optionally following the
  /// current path of this character's [chatId]. Returns a detached WI trace
  /// with scope, stage, seed and context identifiers; no model is called.
  ///
  /// Macros, regex, probability and normal timer/decorator rules evaluate on
  /// copied state with an independent seeded RNG. Nothing is stored, including
  /// variables and inspections. Other bound books and full-prompt trimming are
  /// outside this preview, so it is not a promise about the next real request.
  Future<Map<String, Object?>> previewCharacterBook(String characterId, String text, {String? chatId, int seed = 0});

  /// A PNG / JSON / CHARX card (sniffed from the bytes, not the name), or an
  /// ST lorebook JSON (then it throws [TavernImportError] with
  /// [TavernImportError.isLorebook]; use importLorebook for those files).
  Future<TavernCharacter> importCard(Uint8List bytes, {String? fileName});

  Future<Uint8List> exportCard(String characterId, {TavernCardFormat format = TavernCardFormat.png});

  /// Its chats go with it.
  Future<void> deleteCharacter(String characterId);

  // User personas ------------------------------------------------------------

  /// Saved personas, with the current committed list emitted first. Default
  /// and chat-binding changes also notify selectors through this stream.
  Stream<List<TavernPersona>> watchPersonas();

  Future<TavernPersona?> persona(String personaId);

  /// The optional avatar is a caller-owned file reference. Persona text is
  /// saved as entered; macros run only in the normal generation pipeline.
  /// Only position 0 currently injects the personaDescription prompt marker.
  Future<TavernPersona> createPersona({
    required String name,
    String description = '',
    String? avatarPath,
    int descriptionPosition = PersonaDescriptionPosition.inPrompt,
  });

  /// Null means unchanged; empty text is a real change. Use [clearAvatar] to
  /// remove an avatar reference. Active turns retain their captured persona.
  Future<TavernPersona> updatePersona(
    String personaId, {
    String? name,
    String? description,
    String? avatarPath,
    bool clearAvatar = false,
    int? descriptionPosition,
  });

  /// Cancels affected turns before removing the profile, default and matching
  /// chat bindings. Partial output and old messages remain; avatar files stay.
  Future<void> deletePersona(String personaId);

  /// Without [chatId], selects the global default. With it: chat binding,
  /// then global default, then no profile. This read never runs macros.
  Future<PersonaSelection> personaSelection({String? chatId});

  /// Null clears the default. Changes take effect on the next turn.
  Future<void> setDefaultPersona(String? personaId);

  /// Null restores inheritance from the global default. Cancels and waits for
  /// this chat's current turn before changing its binding.
  Future<void> bindPersona(String chatId, String? personaId);

  // Chats --------------------------------------------------------------------

  /// Newest first; all characters when [characterId] is null.
  Stream<List<TavernChatSummary>> watchChats({String? characterId});

  /// A new chat whose first message is greeting [greeting] (0 = `first_mes`).
  Future<String> createChat(String characterId, {int greeting = 0});

  /// A shared tree with a stable host definition and sequential actor calls.
  /// Mutable inputs are captured at invocation. See [sendGroup] for admission.
  /// Null title uses the host name. A blank resolved title is invalidTitle;
  /// valid titles retain their original leading and trailing characters.
  Future<String> createGroupChat(
    List<String> characterIds, {
    String? hostCharacterId,
    String? title,
    TavernGroupActivation activation = TavernGroupActivation.natural,
    int maxSpeakersPerTurn = 3,
    bool allowSelfResponses = false,
    bool addGreetings = true,
  });
  Future<TavernGroupChat?> groupChat(String chatId);
  Stream<TavernGroupChat?> watchGroupChat(String chatId);
  Future<TavernGroupChat> addGroupMember(
    String chatId,
    String characterId, {
    double? talkativeness,
    bool muted = false,
    TavernGroupModelRole? modelRole,
  });
  Future<TavernGroupChat> updateGroupMember(
    String chatId,
    String characterId, {
    double? talkativeness,
    bool? muted,
    TavernGroupModelRole? modelRole,
  });
  Future<TavernGroupChat> removeGroupMember(String chatId, String characterId);
  Future<TavernGroupChat> reorderGroupMembers(String chatId, List<String> characterIds);

  /// Null title keeps the old title; an explicit blank title is invalidTitle.
  Future<TavernGroupChat> updateGroupChat(
    String chatId, {
    String? title,
    TavernGroupActivation? activation,
    int? maxSpeakersPerTurn,
    bool? allowSelfResponses,
  });

  /// Listening admits one batch. Subscription cancellation only detaches.
  /// An explicit member overrides selection (including mute) for one reply.
  /// A committed user line survives failure; progress.userNodeId identifies it.
  Stream<TavernGroupEvent> sendGroup(String chatId, String text, {String? speakerCharacterId});

  /// Atomic snapshot plus future batch events; never starts a model request.
  Stream<TavernGroupEvent> resumeGroupTurn(String chatId);

  /// Imports a same-character batch without adding greetings or evaluating
  /// macros. Related main_chat files become branches; unrelated files remain
  /// separate chats. A malformed document rejects the whole batch.
  ///
  /// [lorebookIds] maps ST world_info names to existing local lorebook IDs.
  /// Unmapped names remain in the exported header and produce a notice.
  Future<TavernChatImportResult> importChats(
    String characterId,
    List<TavernChatFile> files, {
    Map<String, String> lorebookIds = const {},
  });

  /// Exports the current path first, then the other stored branches. Each
  /// document has a fresh integrity UUID. Reading during a turn does not stop
  /// generation; only the state already committed to storage is included.
  Future<List<TavernChatFile>> exportChat(String chatId, {String? fileName});

  /// The conversations in DeepSeek's「导出所有历史对话」ZIP at [zipPath], the
  /// longest first. Throws [TavernImportError] when the file is not one.
  Future<List<TavernDeepSeekSession>> inspectDeepSeekExport(String zipPath);

  /// Takes the named conversations in: each becomes a character of its own
  /// with one chat holding every branch, the one last on screen selected, so
  /// the next message continues it. No greeting is added and no model is
  /// called. One taken in before is returned as it is, not copied again.
  Future<List<TavernDeepSeekImported>> importDeepSeekSessions(String zipPath, List<String> sessionIds);

  Future<void> deleteChat(String chatId);

  /// The current path, oldest first: the last [limit] messages, or the
  /// [limit] before [beforeNodeId] when paging back.
  Future<List<TavernMessage>> path(String chatId, {int limit = 60, String? beforeNodeId});

  /// Totals saved reported usage for character replies from the selected leaf
  /// to the root, grouped by model and the report's UTC weekday/hour.
  /// Includes ST-hidden replies; excludes active replies, streaming checkpoints,
  /// replies without reports and other branches. Reads no message bodies.
  /// These are the latest saved node reports, not lifetime billing totals or
  /// an overlay of uncommitted live requests. An unknown chat is an error.
  Future<List<TavernPathUsage>> pathUsage(String chatId);

  /// Every visible stored node in insertion order, including inactive
  /// descendants and ST-hidden messages. Soft-deleted nodes are excluded.
  /// Previews use the saved body/checkpoint, not uncheckpointed live buffers;
  /// this read does not cancel an active turn.
  Future<List<TavernTreeNode>> tree(String chatId);

  /// A detached copy of the current leaf's saved local variables. An empty
  /// selected path has an empty snapshot. Does not expose uncommitted live
  /// macro effects, mutate state, or cancel a turn; global variables are separate.
  Future<Map<String, Object?>> readVariables(String chatId);

  /// The selected leaf's saved DSH state and raw schema, or saved ST local
  /// variables for cards without a schema. Reading has no state side effects.
  Future<TavernStateSnapshot> readState(String chatId);

  /// Sets a JSON Pointer on the selected leaf through user permissions and
  /// the same validator/rules as model updates. An empty pointer means root.
  /// An empty selected chat path is rejected. [expectedNodeId], when supplied,
  /// protects an editor against a changed selection after cancelling a turn.
  Future<TavernStateEditResult> setStateValue(String chatId, String path, Object? value, {String? expectedNodeId});

  /// Most recent persistent state/agent execution records, newest first.
  /// An explicit node filter excludes records whose node was permanently deleted.
  Future<List<TavernAgentRun>> readAgentRuns(String chatId, {String? nodeId, int limit = 50});

  /// Latest admitted tool turns in insertion order, newest first. Reads only
  /// identities and reply ownership, without loading inspection or tool bodies.
  /// An unknown chat or negative [limit] is an error; zero returns an empty list.
  Future<List<TavernToolTurnSummary>> recentToolTurns(String chatId, {int limit = 20});

  /// Reads persisted facts without resuming a model request or tool execution.
  Future<TavernToolTurnSnapshot?> readToolTurn(String logicalTurnId);
  Future<TavernToolReceipt?> readToolReceipt(String executionId);

  /// Reuse actionId with the same complete parameters when retrying. A new
  /// action on a busy chat fails without implicitly stopping its active turn.
  Future<TavernToolReceipt> rollDice(
    String chatId, {
    required String actionId,
    required String dice,
    String? label,
    int? target,
    String? expectedNodeId,
  });

  /// A decision id identifies one immutable accept/reject attempt. Replays
  /// return its original record beside current source and target observations.
  Future<TavernMemoryDecisionReceipt> resolveMemoryProposal(
    String proposalId, {
    required String decisionId,
    required int expectedVersion,
    required TavernMemoryDecision decision,
    required TavernToolContextAnchor expectedContextAnchor,
  });
  Future<TavernToolPolicySnapshot> readToolPolicy({String? chatId});

  /// Edits only the tool-policy leaves. Adoption affects later admissions and
  /// does not cancel the current turn; chat null leaf values restore inheritance.
  Future<TavernToolPolicyWriteResult> setToolPolicy(Map<String, Object?> patch, {String? chatId});

  /// Fires whenever the current path changes (a turn, a swipe, an edit) so the
  /// screen re-reads [path].
  Stream<void> pathChanges(String chatId);

  /// The recorded request for a node, or the chat's latest admitted attempt
  /// when [nodeId] is omitted. Reading never repeats macros, WI or assembly.
  /// Missing/deleted records return null. Branch selection does not change
  /// which attempt is latest. Ephemeral/empty failed attempts have no node.
  /// Estimates and this call's provider-reported usage are separate fields.
  Future<TavernTurnInspection?> inspectTurn(String chatId, {String? nodeId});

  /// Recomputes from original text or a stored node. No display result, macro
  /// variable or random state is persisted. A node plus text supplies the latest
  /// complete stream. With no node this is the chat's single live-text channel
  /// for each reasoning flag. Ignore results marked superseded by a newer call.
  /// Hidden messages still run display regex, but do not count toward automatic
  /// depth. Only system messages named "SillyTavern System" bypass; this is the
  /// default speaker for raw system text. Raw text has no inferred depth. Supply
  /// a speaker for custom raw narration so trim macros receive its display name.
  Future<TavernDisplayResult> displayText(
    String chatId, {
    String? nodeId,
    String? text,
    TavernRole? role,
    String? speaker,
    num? depth,
    bool reasoning = false,
  });

  // Turns --------------------------------------------------------------------

  /// Appends [text] as the user's message and streams the character's reply.
  /// Empty [text]: the character speaks next without a new user line.
  /// Listening admits the turn. Cancelling a turn-stream subscription only
  /// detaches that observer; generation continues until completion or [stop].
  Stream<TavernEvent> send(String chatId, String text);

  /// Appends a visible user message without requesting a reply. Applies input
  /// write-back regex and then macros, preserving leading/trailing whitespace
  /// and an empty result. The speaker is the selected persona's user name.
  ///
  /// Cancels and awaits this chat's active turn first. Runs only the input
  /// stage, without separate card-field/WI/prompt preparation or a model
  /// request, and keeps the previous turn inspection. Legacy macro evaluation
  /// retains its existing eager card-field reads. Local variables commit with
  /// the message.
  /// Changed global variables save before that atomic commit; preparation
  /// failure still saves global effects that already occurred. A failed
  /// global save does not append this message.
  Future<TavernMessage> sendOnly(String chatId, String text);

  /// Appends a visible narrator message using JavaScript trim and then macros,
  /// without slash-command regex. Explicit [speaker], including an empty
  /// string, wins; otherwise uses a nonempty metadata narrator_name or System.
  /// Uses [sendOnly]'s cancellation, state and persistence rules.
  ///
  /// This is the direct narrator handler's text stage, not a slash parser:
  /// bias, insertion-position, compact and avatar arguments are not evaluated.
  Future<TavernMessage> narrate(String chatId, String text, {String? speaker});

  /// A new reply as a sibling of [nodeId] (a character message), which becomes
  /// current.
  Stream<TavernEvent> regenerate(String chatId, String nodeId);

  /// More text at the end of [nodeId] (ST 「继续」).
  Stream<TavernEvent> continueReply(String chatId, String nodeId);

  /// Writes the user's next line for them (ST impersonate); not stored.
  Stream<TavernEvent> impersonate(String chatId);

  /// Observes the turn active when this stream is listened to. The first
  /// event is a [TavernTurnSnapshot], followed by only subsequent deltas and
  /// its single terminal event. Snapshot and observer registration have no
  /// asynchronous gap. Multiple observers are independent; cancellation
  /// never stops the turn. There is no event-history buffer.
  ///
  /// If no turn is active, closes without events; read [path]/[inspectTurn]
  /// for persisted results. Reconnection is within this engine's lifetime,
  /// not a resumable HTTP request after process termination.
  Stream<TavernEvent> resumeTurn(String chatId);

  /// Stops whatever turn [chatId] is running. Its stream ends with
  /// [TavernTurnFailed] `cancelled`, keeping what arrived.
  void stop(String chatId);

  // Editing the tree -----------------------------------------------------------

  /// Makes sibling [index] of [nodeId] current (and its subtree's remembered
  /// path below it).
  Future<void> selectSibling(String chatId, String nodeId, int index);

  /// Selects any visible node in this chat, cancelling and awaiting its active
  /// turn first. By default the path stops exactly at [nodeId]: its first
  /// selected child edge is persistently cleared, without deleting descendants.
  /// With [restoreDescendants], follows the path currently remembered beneath
  /// the node; this does not reconstruct an edge cleared by an earlier stop.
  /// Selection and restoration of the chosen leaf's variables are atomic.
  /// ST-hidden messages remain selectable; soft-deleted messages do not.
  Future<void> selectNode(String chatId, String nodeId, {bool restoreDescendants = false});

  /// Labels a visible branch root in extra.dshgo.branchName. Trims the name;
  /// null/empty clears it. Cancels and awaits this chat's active turn before
  /// merging the latest extra. Does not rewrite text or selected edges.
  Future<void> nameBranch(String chatId, String nodeId, String? name);

  /// Permanently removes only this visible node and reparents all its children,
  /// including pending soft-deleted children. Their identities and snapshots
  /// survive. Unlike deleteFrom this does not delete a subtree or return an
  /// undo token. Cancels and awaits the chat's active turn first.
  Future<void> deleteMessage(String chatId, String nodeId);

  Future<void> edit(String chatId, String nodeId, String text);

  /// Hides [nodeId] and its whole subtree, returning an undo token. Data is
  /// physically removed the next time the store is opened. Existing callers
  /// may ignore the token; implementations must forward the returned String.
  Future<String> deleteFrom(String chatId, String nodeId);

  /// Restores this deletion during the same open-store lifetime. Restores
  /// the old selection only if no later tree operation has changed it;
  /// otherwise restores the branch without replacing the current path.
  /// False means unknown/consumed token or an ancestor is still soft-deleted.
  Future<bool> undoDeleteFrom(String chatId, String deletionId);

  /// Literal substring search across this chat's visible branches, newest
  /// first. Matches body/speaker, including Chinese; %, _ and backslash are
  /// literal. Pending streaming bodies and soft-deleted nodes are excluded.
  Future<List<TavernMessage>> searchChat(String chatId, String query, {int limit = 50});

  Future<void> setHidden(String chatId, String nodeId, bool hidden);

  // Presets ------------------------------------------------------------------

  Future<List<TavernPresetSummary>> listPresets();
  Stream<List<TavernPresetSummary>> watchPresets();
  Future<TavernPreset?> preset(String presetId);

  /// Saves without selecting. Original text and unknown fields are retained;
  /// validation issues identify the precise prompt and JSON path.
  Future<TavernPresetImportResult> importPreset(String text, {String? fileName});

  /// Merges objects and replaces arrays/scalars in the current ST document.
  /// Sampling keys use their native ST names. The original source is unchanged.
  /// Name is a library label; package metadata is synchronized when present.
  /// For plain ST exports the caller chooses the corresponding file name.
  /// extensions.dshgo.presetEnvelope is an export-owned carrier; edits that
  /// change it are rejected, so an opaque wrapper cannot be silently lost.
  Future<TavernPresetImportResult> updatePreset(String presetId, Map<String, Object?> patch, {String? name});
  Future<TavernPresetImportResult> updatePresetPrompt(String presetId, String identifier, Map<String, Object?> patch);

  /// Reorders the first 100001 group's complete list. Existing entry fields
  /// survive; new entries start enabled. Omitted identifiers leave this group.
  Future<TavernPresetImportResult> setPresetOrder(String presetId, List<String> identifiers);
  Future<TavernPresetImportResult> setPresetPromptEnabled(String presetId, String identifier, bool enabled);

  /// Native ST JSON, with preserved project data under extensions.dshgo.
  Future<String> exportPreset(String presetId);

  Future<TavernPresetSelection> presetSelection({String? chatId});
  Future<void> setDefaultPreset(String? presetId);

  /// Clears the legacy inline chat preset. Null restores default inheritance;
  /// this differs from setSettings({'preset': null}), which selects ST defaults.
  Future<void> bindPreset(String chatId, String? presetId);

  /// Deletes the library record and clears its bindings/default atomically.
  /// Independently stored legacy inline settings remain a fallback; deletion
  /// of a generated legacy record does not erase that separate configuration.
  Future<void> deletePreset(String presetId);

  // Managed helper scripts -------------------------------------------------

  /// Ordered global tree, including disabled scripts/folders. Raw values are
  /// detached and include current owner data/buttons, not stale import copies.
  Future<List<TavernScriptLibraryEntry>> listGlobalScripts();
  Stream<List<TavernScriptLibraryEntry>> watchGlobalScripts();

  /// Saves a bare helper script/folder object or a complete tree array.
  /// Preserves enabled flags and unknown fields; never executes JavaScript.
  /// Missing/conflicting ids become new stable ids; existing owners survive.
  Future<List<TavernScriptLibraryEntry>> importGlobalScripts(String text);
  Future<TavernScriptLibraryEntry> setGlobalScriptEnabled(String id, bool enabled);

  /// Exact permutation of one folder's children, or of roots when null.
  Future<void> setGlobalScriptOrder(List<String> ids, {String? folderId});

  /// Removes this item/subtree and its leaf scripts' global data/button rows.
  Future<void> deleteGlobalScript(String id);

  /// Complete current JSON: one object with id, otherwise a tree array.
  Future<String> exportGlobalScripts({String? id});

  /// Global + actual current preset (including RAM/legacy inline) + card.
  /// A group without characterId does not implicitly choose a group member.
  /// Returned owners must be passed intact to scripts.openContext.
  Future<TavernChatScripts> chatScripts(String chatId, {String? characterId});

  /// Initial value and catalog changes. Ordinary message commits do not
  /// reload scripts; runtime data/buttons still use the context cache bridge.
  Stream<TavernChatScripts> watchChatScripts(String chatId, {String? characterId});

  // Managed global regex scripts --------------------------------------------

  /// This imported collection follows legacy inline global rules in settings,
  /// and precedes preset and character scripts.
  Future<List<TavernRegexScript>> listRegexScripts();
  Future<TavernRegexImportResult> importRegexScripts(String text);

  /// Edits the current ST raw object in place, retaining its internal id, order,
  /// original sourceText and importedAt. The payload's raw id remains editable.
  /// Captures a JSON deep copy of patch at call time, then merges into the latest
  /// committed raw in the library queue. Objects merge recursively; arrays,
  /// scalars and null replace, while omitted fields remain.
  /// Refreshes compatibility diagnostics and the import report without expanding
  /// macros. Incompatible raw remains saved but is disabled in execution views.
  /// Await publication before starting work that must use the edited rules;
  /// existing messages and already captured execution views are unchanged.
  Future<TavernRegexScript> updateRegexScript(String regexId, Map<String, Object?> patch);
  Future<TavernRegexScript> setRegexEnabled(String regexId, bool enabled);
  Future<void> deleteRegex(String regexId);

  /// One native ST object when id is given; otherwise the ordered array.
  Future<String> exportRegex({String? regexId});

  // Independent world books -------------------------------------------------

  Future<List<TavernLorebookSummary>> listLorebooks();

  /// Keeps a supplied filename (without .json) as native timer identity,
  /// separately from the raw display title. An active imported chat mapping
  /// can supply its own exact ST name. Raw read/export omit local metadata.
  Future<TavernLorebookImportResult> importLorebook(String text, {String? fileName});
  Future<Map<String, Object?>?> lorebook(String id);
  Future<void> putLorebook(String id, Map<String, Object?> json);
  Future<String> exportLorebook(String id);

  /// Retains source bindings. Future turns diagnose and skip the missing id;
  /// an already captured book remains usable.
  Future<void> deleteLorebook(String id);

  /// Empty ids clears this binding. Character/persona identity scopes use their
  /// matching source. chatId can also override a legacy global source. Missing
  /// ids remain and are diagnosed when a turn loads them.
  Future<void> bindLorebooks(
    List<String> ids, {
    WorldInfoSource source = WorldInfoSource.global,
    String? chatId,
    String? characterId,
    String? personaId,
  });

  // Settings -----------------------------------------------------------------

  /// Where model calls go from now on.
  void configure(TavernModelConfig config);

  /// A detached effective settings snapshot: global, imported source, then
  /// explicit chat settings. Reading does not evaluate macros or world info.
  /// managedRegexScripts is a read-only library projection; settings cannot
  /// override it or add a second copy of the imported collection.
  Future<Map<String, Object?>> readSettings({String? chatId});

  /// Recursively merges objects; arrays/scalars replace their previous values.
  /// Null is a stored value, not a deletion. Chat changes cancel and await its
  /// active turn. Global changes apply to turns admitted after this call.
  /// presetOverrides overlays only temperature/top_p/presence_penalty/
  /// frequency_penalty/openai_max_tokens/openai_max_context after selection.
  /// Legacy global patches containing preset write settings.json before the
  /// SQLite selection; a second-step failure leaves the file change committed.
  Future<void> setSettings(Map<String, Object?> patch, {String? chatId});

  /// Latest successful director output and the latest attempt are separate.
  /// Notes are marked spoilers; stale branch results remain readable but are
  /// not injected into a main turn. The optional story view reads the selected
  /// branch's saved progress independently of the helper. Optional eventRules
  /// exposes that branch's fixed-card event ledger and literal prompt queue.
  /// Reading never calls a model, executes handlers or advances chapters.
  Future<TavernDirectorSnapshot> readDirector(String chatId);

  /// Initial snapshot, then independent background completion/failure updates.
  /// Cancelling this subscription does not stop a helper or a main turn.
  Stream<TavernDirectorSnapshot> watchDirector(String chatId);

  /// One explicit helper invocation, even when automatic directing is off.
  /// Returns busy during a main generation or tree mutation, without cancelling
  /// or waiting for it. The source is saved context, never streaming buffers.
  Future<TavernDirectorRun> runDirector(String chatId);

  /// Pending proposals, newest first by publication order. Pass the last id
  /// as beforeEventId for the next page. A proposal remains globally pending;
  /// branch-local fixed-card execution is recorded separately in eventRules.
  /// A malformed/unsupported row retains its id with available=false and null
  /// payload, so it neither invents a proposal nor hides valid neighboring rows.
  Future<List<TavernDirectorEvent>> readDirectorEvents(String chatId, {int limit = 50, String? beforeEventId});

  /// Creates a complete ZIP at [destinationPath], outside this data root.
  /// Active turns or another backup return busy. New operations are rejected
  /// only while the stable database/files snapshot is being captured; normal
  /// work may resume while that independent snapshot is compressed.
  /// Restore uses restoreTavernDirectory after closing the target engine.
  Future<TavernBackupInfo> backup(String destinationPath);

  Future<void> close();
}

class TavernImportError implements Exception {
  const TavernImportError(this.message, {this.isLorebook = false});
  final String message;
  final bool isLorebook;

  @override
  String toString() => 'TavernImportError: $message';
}
