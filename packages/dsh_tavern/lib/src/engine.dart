// ST continuation, display regex, injection ordering and world-info integration follow
// SillyTavern public/script.js, scripts/constants.js and scripts/world-info.js
// at 7e8663cd9c184a550b37238218bdd32c6efc68e9 (1.19.0, AGPL-3.0).
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:sqlite3/sqlite3.dart' show SqliteException;

import 'api.dart';
import 'authoring.dart';
import 'authoring_authority.dart';
import 'authoring_model_images.dart';
import 'authoring_preview.dart';
import 'authoring_render.dart';
import 'authoring_run.dart';
import 'authoring_script_preview.dart';
import 'authoring_seed.dart';
import 'authoring_simulation.dart';
import 'backup.dart';
import 'director.dart';
import 'director/direct_tool.dart' as director_core;
import 'dshgo_inspection.dart';
import 'gameplay.dart';
import 'gameplay_bindings.dart';
import 'gameplay_cast.dart';
import 'gameplay_export.dart';
import 'gameplay_packs.dart';
import 'import_report.dart';
import 'inspection.dart';
import 'io/authoring_text.dart';
import 'io/authoring_image.dart';
import 'io/card_codec.dart'
    show CardCodec, DecodedCardSeed, TavernCard, embeddedCardAssetPath, isSafeCardAssetPath, cardAssetDataUri;
import 'io/chat_jsonl.dart';
import 'io/deepseek_export.dart';
import 'io/gameplay_pack_codec.dart';
import 'io/import_intake.dart';
import 'io/preset_codec.dart';
import 'io/regex_intake.dart';
import 'io/script_library_codec.dart';
import 'io/tavern_backup.dart' as backup_io;
import 'js_string.dart';
import 'llm/model_client.dart';
import 'llm/tool_calls.dart';
import 'llm/tool_usage.dart';
import 'lorebook_library.dart';
import 'macros/macro_engine.dart';
import 'mvu/mvu.dart' as mvu_core;
import 'persona.dart';
import 'preset_library.dart';
import 'prompt/character_fields.dart';
import 'prompt/preset.dart';
import 'prompt/prompt_assembler.dart';
import 'prompt/post_processing.dart';
import 'prompt/prompt_types.dart';
import 'prompt/prompt_manager_snapshot.dart';
import 'regex/regex_engine.dart';
import 'regex/regex_worker.dart';
import 'regex_library.dart';
import 'script_library.dart';
import 'scripts.dart';
import 'spreset.dart';
import 'slash/slash_language.dart';
import 'slash/st_fuse.dart';
import 'slash/st_output_cleanup.dart';
import 'state.dart';
import 'state/state_engine.dart' as state_core;
import 'story/story_engine.dart' as story_core;
import 'store/character_library.dart';
import 'store/chat_store.dart';
import 'store/persona_store.dart';
import 'store/regex_library.dart';
import 'tool_policy.dart';
import 'tools.dart';
import 'worldinfo/world_info.dart';

part 'engine_state.dart';
part 'engine_spreset.dart';
part 'engine_spreset_response_metadata.dart';
part 'engine_profile.dart';
part 'engine_prompt_history.dart';
part 'engine_authoring.dart';
part 'engine_authoring_apply.dart';
part 'engine_authoring_run.dart';
part 'engine_authoring_images.dart';
part 'engine_authoring_seed.dart';
part 'engine_authoring_simulation_seed.dart';
part 'engine_authoring_simulation_client.dart';
part 'engine_authoring_simulation.dart';
part 'engine_authoring_capture.dart';
part 'engine_authoring_binding.dart';
part 'engine_authoring_facts.dart';
part 'engine_authoring_preview.dart';
part 'engine_authoring_render.dart';
part 'engine_prompt_preparation.dart';
part 'engine_authoring_context.dart';
part 'engine_authoring_scripts.dart';
part 'engine_authoring_script_host.dart';
part 'engine_tools.dart';
part 'engine_gameplay_packs.dart';
part 'engine_gameplay.dart';
part 'engine_gameplay_bindings.dart';
part 'engine_gameplay_cast.dart';
part 'engine_gameplay_export.dart';
part 'engine_gameplay_export_character.dart';
part 'gameplay_export_projection.dart';
part 'engine_gameplay_export_draft.dart';
part 'engine_gameplay_runtime.dart';
part 'engine_gameplay_resources.dart';
part 'engine_gameplay_events.dart';
part 'gameplay_composition.dart';
part 'engine_director.dart';
part 'engine_director_watch.dart';
part 'engine_story.dart';
part 'engine_card_events.dart';
part 'engine_secrets.dart';
part 'engine_group.dart';
part 'engine_scripts.dart';
part 'engine_mvu.dart';
part 'engine_mvu_resources.dart';
part 'engine_script_variables.dart';
part 'engine_scripts_messages.dart';
part 'engine_script_generation_types.dart';
part 'engine_script_generation.dart';
part 'engine_helper_generation.dart';
part 'engine_helper_request.dart';
part 'engine_helper_response.dart';
part 'engine_helper_output.dart';
part 'engine_helper_spreset.dart';
part 'engine_script_generation_commit.dart';
part 'engine_script_prompt.dart';
part 'engine_script_injections.dart';
part 'engine_script_regex.dart';
part 'engine_script_regex_write.dart';
part 'engine_slash_types.dart';
part 'engine_slash_execution.dart';
part 'engine_slash_effects.dart';
part 'engine_slash_chat_effects.dart';
part 'engine_slash_handlers.dart';
part 'engine_slash_messages.dart';
part 'engine_slash_native.dart';
part 'engine_slash_injections.dart';
part 'engine_slash_worldinfo.dart';
part 'engine_slash_returns.dart';
part 'engine_slash_generation.dart';
part 'engine_slash_output.dart';
part 'engine_slash_host.dart';
part 'engine_slash_generation_lock.dart';
part 'engine_script_resources.dart';
part 'engine_script_helper_settings.dart';
part 'engine_script_presets.dart';
part 'engine_script_library.dart';
part 'engine_script_avatars.dart';
part 'engine_script_book_directory.dart';
part 'engine_script_book_bindings.dart';
part 'engine_deepseek_import.dart';
part 'slash/st_name_matching.dart';
part 'slash/st_message_bias.dart';

/// App convenience factory. [directory] is the actual tavern data directory,
/// normally `<app support>/tavern`. No extra path component is appended.
Future<Tavern> openTavern(String directory) => TavernEngine.openDirectory(Directory(directory));

/// Validates and restores a backup into a closed tavern directory. Open a new
/// engine after success. Invalid archives/versions never replace the target.
/// Like ordinary opening, the root must have one owner across processes.
Future<TavernBackupInfo> restoreTavernDirectory(String archivePath, String directory) async {
  final root = Directory(directory);
  final identity = await _directoryIdentity(root);
  if (!_reserveTavernRoot(identity)) throw StateError('The tavern directory overlaps an open or restoring root.');
  try {
    return await backup_io.restoreTavernBackup(
      File(archivePath),
      root,
      validateStaging: TavernEngine._validateBackupStaging,
      validateDestination: (destination) async {
        if (AuthoringAuthority.inspectRootReadOnly(destination).hasPending) {
          throw const TavernAuthoringException(
            'pending_operation',
            'The destination has an unresolved file operation.',
          );
        }
      },
    );
  } finally {
    _ownedTavernRoots.remove(identity);
  }
}

// Same-isolate ownership also prevents a page from reopening a root while a
// restore is between its two directory renames. It is not an OS file lock.
final _ownedTavernRoots = <String>{};

bool _reserveTavernRoot(String identity) {
  // Canonical directory URIs end in '/', so these checks include a directory
  // boundary. Replacing an ancestor would move a live descendant database.
  if (_ownedTavernRoots.any((owned) => identity.startsWith(owned) || owned.startsWith(identity))) return false;
  return _ownedTavernRoots.add(identity);
}

Future<String> _directoryIdentity(Directory directory) => backup_io.tavernDirectoryIdentity(directory);

/// A recording of the actual assembly, never a second macro evaluation.
class TavernInspection {
  const TavernInspection({
    required this.prompt,
    required this.worldInfo,
    required this.generationType,
    required this.at,
    this.preparedUiHits = const [],
    this.missingBooks = const [],
    this.packSources = const {},
  });
  final PromptAssembly prompt;
  final WorldInfoResult worldInfo;
  final String generationType;
  final DateTime at;
  final List<WorldInfoHit> preparedUiHits;
  final List<Map<String, Object?>> missingBooks;
  final Map<WorldInfoEntryRef, WorldInfoPackSource> packSources;

  Map<String, Object?> toJson() => _copy({
    'prompt': prompt.toJson(),
    'generationType': generationType,
    'at': at.toIso8601String(),
    'worldInfo': _worldInfoTrace(
      worldInfo,
      preparedUiHits: preparedUiHits,
      missingBooks: missingBooks,
      packSources: packSources,
    ),
  });
}

/// Owns the character files, chat database, settings, and active generations.
/// Only one engine should open a given app-support directory at a time.
class TavernEngine implements Tavern, TavernSPresetLogApi, TavernSPresetPageLifecycle {
  TavernEngine._(
    this.directory,
    this._store,
    this._authoringAuthority,
    this._library,
    this._personas,
    this._document,
    this._config,
    this._modelClient,
    this._counter,
    this._clock,
    this._random,
    this._rollRandom,
    this._regexWorker,
    this._regexLibrary,
  ) {
    _globalVariables = _NativeGlobals(_map(_document['globalVariables']));
    _store.committedObserver = _scripts.storeCommitted;
    _regexLibrary.committedObserver = () {
      _managedRegexView = null;
      _scripts.resourcesChanged();
    };
    _library.cardCommitted = (id, data) {
      _characterCache = null;
      unawaited(_characterDetails.remove(id));
      _scripts.cardCommitted(id, data);
      _directors.characterChanged(id);
      _scriptCatalogChanged.add(null);
      _notifyLists();
    };
    _library.cardRemoved = (id) {
      _characterCache = null;
      unawaited(_characterDetails.remove(id));
      _scripts.cardRemoved(id);
      _directors.characterChanged(id);
      _scriptCatalogChanged.add(null);
      _notifyLists();
    };
    _storeSubscription = _store.chatCommits.listen((change) {
      if (_closed) return;
      final chatId = change.chatId;
      _paths.add(chatId);
      if (change.bodyOnly) return;
      _directors.changed(chatId);
      _scripts.nativeChanged(chatId);
      if (!_mainBusy(chatId)) _notifyLists(resourcesChanged: false);
    });
    _personaSubscription = _personas.changes.listen((_) => _directors.changedAll());
  }

  static Future<TavernEngine> open(
    Directory appSupport, {
    TavernModelConfig? config,
    TavernModelClient? modelClient,
    PromptTokenCounter counter = const EstimatedTokenCounter(),
    DateTime Function()? clock,
    double Function()? random,
    int Function(int max)? rollRandom,
  }) => openDirectory(
    Directory('${appSupport.path}/tavern'),
    config: config,
    modelClient: modelClient,
    counter: counter,
    clock: clock,
    random: random,
    rollRandom: rollRandom,
  );

  /// Opens an explicit tavern root. Unlike [open], this does not append
  /// `tavern`; the caller chooses the complete data-directory path.
  static Future<TavernEngine> openDirectory(
    Directory directory, {
    TavernModelConfig? config,
    TavernModelClient? modelClient,
    PromptTokenCounter counter = const EstimatedTokenCounter(),
    DateTime Function()? clock,
    double Function()? random,
    int Function(int max)? rollRandom,
  }) async {
    final identity = await _directoryIdentity(directory);
    if (!_reserveTavernRoot(identity)) {
      throw StateError('The tavern directory overlaps an open or restoring root.');
    }
    try {
      return await _openReservedDirectory(
        directory,
        identity,
        config: config,
        modelClient: modelClient,
        counter: counter,
        clock: clock,
        random: random,
        rollRandom: rollRandom,
      );
    } catch (_) {
      _ownedTavernRoots.remove(identity);
      rethrow;
    }
  }

  // The caller already owns this canonical root. Simulations retain that
  // reservation through close and directory removal, without reopening a gap.
  static Future<TavernEngine> _openReservedDirectory(
    Directory directory,
    String identity, {
    TavernModelConfig? config,
    TavernModelClient? modelClient,
    PromptTokenCounter counter = const EstimatedTokenCounter(),
    DateTime Function()? clock,
    double Function()? random,
    int Function(int max)? rollRandom,
    bool releaseRootOnClose = true,
    void Function()? onFailedOpenDrained,
  }) async {
    var acquired = false;
    var drained = false;
    try {
      await backup_io.recoverPendingTavernRestore(directory);
      await directory.create(recursive: true);
      final settingsFile = File('${directory.path}/settings.json');
      String? settingsText;
      try {
        settingsText = await settingsFile.readAsString();
      } on PathNotFoundException catch (error) {
        final code = error.osError?.errorCode;
        if (code != 2 && (!Platform.isWindows || code != 3)) {
          rethrow;
        }
        if (await FileSystemEntity.type(settingsFile.path) != FileSystemEntityType.notFound) {
          rethrow;
        }
      }
      final document = settingsText == null
          ? <String, Object?>{'version': 1, 'settings': <String, Object?>{}, 'globalVariables': <String, Object?>{}}
          : _decodeObject(settingsText, 'Tavern settings');
      if (document['version'] != 1) {
        throw const FormatException('Unsupported Tavern settings version.');
      }
      validateStoredScriptLibrary(document['scriptLibrary']);
      final now = clock ?? DateTime.now;
      final personas = await PersonaStore.open(directory);
      acquired = true;
      final regexWorker = RegexWorker();
      final regexLibrary = RegexLibrary(directory, regexWorker, clock: now);
      ChatStore? store;
      try {
        await regexLibrary.initialize();
        store = ChatStore.open('${directory.path}/tavern.sqlite3', clock: now);
        final authority = AuthoringAuthority(root: directory, store: store);
        store.interruptAuthoringRuns();
        final result = TavernEngine._(
          directory,
          store,
          authority,
          CharacterLibrary(directory, now: now, authority: authority),
          personas,
          document,
          config ?? TavernModelConfig(apiKey: () async => null),
          modelClient ?? TavernModelClient(),
          counter,
          now,
          random ?? Random.secure().nextDouble,
          rollRandom ?? Random.secure().nextInt,
          regexWorker,
          regexLibrary,
        );
        result._directoryOwnerKey = identity;
        result._releaseDirectoryOwnerOnClose = releaseRootOnClose;
        return result;
      } catch (_) {
        await regexWorker.close();
        await store?.close();
        await personas.close();
        drained = true;
        rethrow;
      }
    } catch (_) {
      if (!acquired || drained) {
        onFailedOpenDrained?.call();
      }
      rethrow;
    }
  }

  final Directory directory;
  late final String _directoryOwnerKey;
  bool _releaseDirectoryOwnerOnClose = true;
  final ChatStore _store;
  final AuthoringAuthority _authoringAuthority;
  final CharacterLibrary _library;
  final PersonaStore _personas;
  final Map<String, Object?> _document;
  TavernModelConfig _config;
  Object _authoringConfigVersion = Object();
  final TavernModelClient _modelClient;
  final PromptTokenCounter _counter;
  final DateTime Function() _clock;
  final double Function() _random;
  final int Function(int max) _rollRandom;
  final RegexWorker _regexWorker;
  final RegexLibrary _regexLibrary;
  // WI cannot queue behind obsolete 120ms display requests.
  final _keywordWorker = RegexWorker();
  late final _worldInfoEngine = WorldInfoEngine(worker: _keywordWorker);
  late final _chatCodec = ChatJsonlCodec(clock: _clock);
  final _presetCodec = const PresetCodec();
  late final _NativeGlobals _globalVariables;
  late final StreamSubscription<({String chatId, bool bodyOnly})> _storeSubscription;
  late final StreamSubscription<void> _personaSubscription;
  final _charactersChanged = StreamController<void>.broadcast();
  final _chatsChanged = StreamController<void>.broadcast();
  final _globalScriptsChanged = StreamController<void>.broadcast();
  final _scriptCatalogChanged = StreamController<void>.broadcast();
  final _paths = StreamController<String>.broadcast();
  final _turns = <String, _Turn>{};
  final _manualTools = <String, _ManualToolAction>{};
  late final _GroupCoordinator _groups = _GroupCoordinator(this);
  late final _ScriptCoordinator _scripts = _ScriptCoordinator(this);
  final _spresetGenerations = <_SPresetGeneration>{};
  final _spresetEntryGenerations = <String, _SPresetGeneration>{};
  final _spresetPromptManagers = <String, PromptManagerSnapshot>{};
  final _spresetPageEpochs = <String, int>{};

  @override
  void resetSPresetPage(String chatId) {
    _ensureOpen();
    if (chatId.isEmpty) throw ArgumentError.value(chatId, 'chatId', 'A page reset requires its chat identity.');
    _spresetPageEpochs[chatId] = (_spresetPageEpochs[chatId] ?? 0) + 1;
    _spresetPromptManagers.remove(chatId);
    _clearSPresetEntryDecisions(chatId);
  }

  // The App routes SPreset evaluation to a chat's canvas. END/STOP clears
  // that canvas's current decisions, not another chat or pending evaluations.
  // Helper's private js_generation_ended event does not use this method.
  void _clearSPresetEntryDecisions(String chatId) => _spresetEntryGenerations.remove(chatId);

  void _clearAllSPresetEntryDecisions() => _spresetEntryGenerations.clear();

  final _spresetMacroNest = SPresetMacroNestRuntime();
  final _spresetLogs = SPresetLogBuffer();
  Future<void>? _spresetLogLoad;
  Future<void> _spresetLogWrite = Future.value();
  @override
  TavernScriptBridge get scripts {
    _ensureOpen();
    return _scripts;
  }

  bool _mainBusy(String chatId) =>
      _turns.containsKey(chatId) || _groups.rounds.containsKey(chatId) || _manualTools.containsKey(chatId);
  final _mutations = <String, Future<void>>{};
  final _deletingCharacters = <String>{};
  final _deletingPersonas = <String>{};
  final _deletingPresets = <String>{};
  final _operations = <Future<void>>{};
  final _authoringRuns = <String, _AuthoringRunRecord>{};
  final _authoringPreviewCancellations = <ModelCancellation>{};
  final _inspections = <String, TavernInspection>{};
  // A null entry is a tombstone: never fall back to an older disk snapshot
  // after deleting the context of a more recent in-memory attempt.
  final _latestInspections = <String, TavernTurnInspection?>{};
  final _liveVariables = <String, ({String? leaf, Map<String, Object?> values})>{};
  final _books = <String, Map<String, Object?>>{};
  late final _directors = _DirectorCoordinator(this);
  final _bookSourceNames = <String, String>{};
  final _bookImportReports = <String, TavernImportReport>{};
  final _bookRevisions = <String, int>{};
  final _displayQueues = <(String, String?, bool), _DisplayQueue>{};
  final _displayChats = <String, _DisplayChatView>{};
  final _promptCacheWindows = <String, _CachedPromptWindow>{};
  final _executionPresets = <String, StoredPreset?>{};
  Object? _executionPresetVersion;
  List<Map<String, Object?>>? _managedRegexView;
  Future<List<StoredCharacterSummary>>? _characterCache;
  final _characterDetails = <String, Future<StoredCharacter?>>{};
  static const _detailCacheCapacity = 8;
  final _chatPreviews = <String, ({String raw, String plain})>{};
  var _chatPreviewUnits = 0;
  static const _chatPreviewEntries = 64;
  static const _chatPreviewCapacity = 4 * 1024 * 1024;
  Future<void> _libraryQueue = Future.value();

  /// DeepSeek imports, one after another (engine_deepseek_import.dart).
  Future<void> _deepSeekImports = Future.value();
  Future<void> _personaQueue = Future.value();
  Future<void> _presetQueue = Future.value();
  Map<String?, _PresetWorkingSlot> _presetWorkingSlots = {};
  var _presetWorkingRevision = 0;
  var _presetWorkingNotifiedRevision = 0;
  Future<void> _fileQueue = Future.value();
  Future<void> _bookQueue = Future.value();
  Future<void>? _closeFuture;
  var _closing = false;
  var _closed = false;
  var _globalPresetUpdate = false;
  var _temporaryId = 0;
  var _capturingBackup = false;
  var _backupInProgress = false;
  Completer<void>? _backupCaptureDone;

  void _ensureOpen() {
    if (_closing || _closed) throw StateError('The tavern is closed.');
  }

  void _ensureAdmission() {
    _ensureOpen();
    if (_capturingBackup) throw const TavernModelException(TavernFailure.busy, 'backup_capture_in_progress');
  }

  Future<T> _operation<T>(FutureOr<T> Function() action) {
    _ensureAdmission();
    return _trackOperation(Future<T>.sync(action));
  }

  Future<T> _trackOperation<T>(Future<T> result) {
    final completed = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _operations.add(completed);
    unawaited(
      completed.then<void>((_) {
        _operations.remove(completed);
      }),
    );
    return result;
  }

  Future<T> _libraryOperation<T>(Future<T> Function() action) {
    final result = _libraryQueue.then((_) => action());
    _libraryQueue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<TavernAuthoringDraft> createAuthoringDraft(List<TavernAuthoringTarget> targets) =>
      _createAuthoringDraft(targets);
  @override
  Future<TavernAuthoringDraft?> readAuthoringDraft(String draftId) => _readAuthoringDraft(draftId);
  @override
  Future<List<TavernAuthoringDraftSummary>> listAuthoringDrafts() => _listAuthoringDrafts();
  @override
  Future<TavernAuthoringDraft> editAuthoringDraft(
    String draftId, {
    required int draftRevision,
    required List<TavernAuthoringChange> changes,
  }) => _editAuthoringDraft(draftId, draftRevision, changes, rebase: false);
  @override
  Future<TavernAuthoringDraft> rebaseAuthoringDraft(
    String draftId, {
    required int draftRevision,
    required List<TavernAuthoringChange> changes,
  }) => _editAuthoringDraft(draftId, draftRevision, changes, rebase: true);
  @override
  Future<void> deleteAuthoringDraft(String draftId, {required int draftRevision}) =>
      _authoringOperation(() => _store.deleteAuthoringDraftData(draftId, draftRevision));
  @override
  Future<TavernAuthoringPreview> previewAuthoringDraft(
    String draftId, {
    required int draftRevision,
    required List<String> changeIds,
  }) => _previewAuthoringDraft(draftId, draftRevision, changeIds);
  @override
  Future<TavernAuthoringRegexTest> testAuthoringRegex(
    String draftId, {
    required int draftRevision,
    required List<String> changeIds,
    required String physicalResourceId,
    required String scriptPath,
    required String text,
  }) => _testAuthoringRegex(draftId, draftRevision, changeIds, physicalResourceId, scriptPath, text);

  @override
  Future<TavernAuthoringReceipt> applyAuthoringChanges(
    String draftId, {
    required int draftRevision,
    required String physicalResourceId,
    required List<String> changeIds,
    required TavernAuthorityRevision expectedAuthorityRevision,
    required String operationId,
  }) => _applyAuthoringChanges(
    draftId,
    draftRevision: draftRevision,
    physicalResourceId: physicalResourceId,
    changeIds: changeIds,
    expectedAuthorityRevision: expectedAuthorityRevision,
    operationId: operationId,
  );
  @override
  Future<TavernAuthoringOperation?> readAuthoringOperation(String operationId, {required String domainId}) =>
      _readAuthoringOperation(operationId, domainId: domainId);
  @override
  Future<List<TavernAuthoringRevisionSummary>> listAuthoringRevisions(String physicalResourceId) =>
      _listAuthoringRevisions(physicalResourceId);
  @override
  Future<TavernAuthoringReceipt> restoreAuthoringRevision(
    String physicalResourceId, {
    required TavernAuthorityRevision revision,
    required TavernAuthorityRevision expectedAuthorityRevision,
    required String operationId,
  }) => _restoreAuthoringRevision(
    physicalResourceId,
    revision: revision,
    expectedAuthorityRevision: expectedAuthorityRevision,
    operationId: operationId,
  );

  @override
  TavernAuthoringRun startAuthoringRun(
    TavernAuthoringRunRequest request, {
    TavernAuthoringPromptHost? promptHost,
    TavernAuthoringPreviewHost? renderHost,
  }) => _startAuthoringRun(request, promptHost: promptHost, renderHost: renderHost);
  @override
  Future<TavernAuthoringRunSnapshot?> readAuthoringRun(String runId) => _readAuthoringRun(runId);
  @override
  Future<List<TavernAuthoringRunSummary>> listAuthoringRuns({String? draftId, int limit = 30, String? beforeRunId}) =>
      _listAuthoringRuns(draftId: draftId, limit: limit, beforeRunId: beforeRunId);
  @override
  Future<TavernAuthoringToolReceipt?> readAuthoringToolReceipt(String runId, String receiptId) =>
      _readAuthoringToolReceipt(runId, receiptId);
  @override
  Future<void> cancelAuthoringRun(String runId) => _cancelAuthoringRun(runId);
  @override
  Future<TavernAuthoringDraft> createAuthoringSeed(TavernAuthoringSeedInput input) => _createAuthoringSeed(input);
  @override
  Future<TavernAuthoringSaveAsReceipt> saveAuthoringAsNew(
    String draftId, {
    required int draftRevision,
    required String physicalResourceId,
    required List<String> changeIds,
    required String operationId,
    required TavernAuthoringMediaSelection media,
    String? domainId,
  }) => _saveAuthoringAsNew(
    draftId,
    draftRevision: draftRevision,
    physicalResourceId: physicalResourceId,
    changeIds: changeIds,
    operationId: operationId,
    media: media,
    domainId: domainId,
  );

  @override
  TavernAuthoringTask<TavernAuthoringPromptPreview> previewAuthoringPrompt(
    TavernAuthoringPromptRequest request, {
    TavernAuthoringPromptHost? host,
  }) => _previewAuthoringPrompt(request, host: host);

  @override
  TavernAuthoringTask<TavernAuthoringRenderResult> renderAuthoringDraft(
    TavernAuthoringRenderRequest request, {
    required TavernAuthoringPreviewHost host,
  }) => _renderAuthoringDraft(request, host);

  @override
  TavernAuthoringSimulationTask simulateAuthoringDraft(TavernAuthoringSimulationRequest request) =>
      _simulateAuthoringDraft(request);

  @override
  Future<TavernPackImportResult> importGameplayPack(Uint8List bytes) => _importGameplayPack(bytes);

  @override
  Future<List<TavernPackVersion>> listGameplayPacks({bool includeRemoved = false}) =>
      _listGameplayPacks(includeRemoved: includeRemoved);

  @override
  Future<TavernPackVersion?> readGameplayPack(TavernPackVersionRef ref) => _readGameplayPack(ref);

  @override
  Future<TavernPackResource?> readGameplayPackResource(TavernPackVersionRef ref, String localId) =>
      _readGameplayPackResource(ref, localId);

  @override
  Future<Uint8List> exportInstalledGameplayPack(TavernPackVersionRef ref) => _exportInstalledGameplayPack(ref);

  @override
  Future<TavernPackRemovalReceipt> removeGameplayPackVersion(
    TavernPackVersionRef ref, {
    required TavernGameplayRevision expected,
    required String operationId,
  }) => _removeGameplayPackVersion(ref, expected: expected, operationId: operationId);

  @override
  Future<TavernPackScopeSnapshot> readGameplayBindings(TavernPackScopeTarget scope) => _readGameplayBindings(scope);

  @override
  Future<TavernPackBindingReceipt> updateGameplayBindings(
    TavernPackScopeTarget scope, {
    required TavernGameplayRevision expected,
    required String operationId,
    required List<TavernPackBindingEdit> edits,
  }) => _updateGameplayBindings(scope, expected: expected, operationId: operationId, edits: edits);

  @override
  Future<TavernGameplayResolution> resolveGameplayConfig(
    TavernGameplayContext context, {
    List<TavernPackScopePreview> proposedScopes = const [],
    bool validateCurrentState = false,
  }) => _resolveGameplayConfig(context, proposedScopes: proposedScopes, validateCurrentState: validateCurrentState);

  @override
  Future<TavernCastImportResult> importDshgoCastMember(
    TavernCastSource source,
    String localCastId, {
    required String operationId,
    String? domainId,
  }) => _importDshgoCastMember(source, localCastId, operationId: operationId, domainId: domainId);

  @override
  Future<TavernCastImportResult?> readDshgoCastImport(String domainId, String operationId) =>
      _readDshgoCastImport(domainId, operationId);

  @override
  Future<TavernGameplayExportPreview> previewGameplayExport(TavernGameplayExportRequest request) =>
      _previewGameplayExport(request);

  @override
  Future<Uint8List> exportCharacterWithPacks(
    TavernGameplayExportRequest request, {
    required String expectedPreviewId,
  }) => _exportCharacterWithPacks(request, expectedPreviewId);

  @override
  Future<Uint8List> exportGameplayPackFromDraft(
    TavernGameplayExportRequest request, {
    required String expectedPreviewId,
  }) => _exportGameplayPackFromDraft(request, expectedPreviewId);

  // Acquire this queue before chat barriers for bind/delete. Taking them in
  // the reverse order could leave a binder waiting behind a deletion that is
  // itself waiting for the binder's chat barrier.
  Future<T> _personaOperation<T>(Future<T> Function() action) {
    final result = _personaQueue.then((_) => action());
    _personaQueue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  // Preset operations take this queue before any chat mutation barrier.
  Future<T> _presetOperation<T>(FutureOr<T> Function() action) {
    final result = _presetQueue.then((_) => action());
    _presetQueue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<List<StoredCharacterSummary>> _characters() {
    final cached = _characterCache;
    if (cached != null) return cached;
    late final Future<List<StoredCharacterSummary>> result;
    result = Future<List<StoredCharacterSummary>>.sync(_library.list).then(
      (value) => value,
      onError: (Object error, StackTrace stack) {
        if (identical(_characterCache, result)) _characterCache = null;
        Error.throwWithStackTrace(error, stack);
      },
    );
    _characterCache = result;
    return result;
  }

  void _cacheCharacterDetail(String id, Future<StoredCharacter?> value) {
    _characterDetails.remove(id);
    _characterDetails[id] = value;
    if (_characterDetails.length > _detailCacheCapacity) _characterDetails.remove(_characterDetails.keys.first);
  }

  void _cacheCharacterRecord(String id, StoredCharacter stored) =>
      _cacheCharacterDetail(id, Future.value(_detailCopy(stored)));

  /// [record] as the detail cache keeps it: nothing reads the original
  /// container from there (exports and edits read their own), so no copy of it.
  static StoredCharacter _detailCopy(StoredCharacter record) {
    final card = record.card;
    return StoredCharacter(
      id: record.id,
      card: TavernCard(
        json: card.json,
        assets: card.assets,
        png: card.png,
        avatar: card.avatar,
        sourceFormat: card.sourceFormat,
      ),
      importedAt: record.importedAt,
      avatarPath: record.avatarPath,
      directoryPath: record.directoryPath,
    );
  }

  Future<StoredCharacter?> _record(String id) {
    if (!CharacterLibrary.isValidId(id)) return Future.value(null);
    final cached = _characterDetails.remove(id);
    if (cached != null) {
      _characterDetails[id] = cached;
      return cached;
    }
    late final Future<StoredCharacter?> result;
    result = Future<StoredCharacter?>.sync(() => _library.read(id)).then(
      (record) {
        if (record == null) {
          if (identical(_characterDetails[id], result)) _characterDetails.remove(id);
          return null;
        }
        return _detailCopy(record);
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_characterDetails[id], result)) _characterDetails.remove(id);
        Error.throwWithStackTrace(error, stack);
      },
    );
    _cacheCharacterDetail(id, result);
    return result;
  }

  String? _chatPreview(String chatId, String? raw) {
    final previous = _chatPreviews.remove(chatId);
    if (previous != null) _chatPreviewUnits -= previous.raw.length + previous.plain.length;
    if (raw == null) return null;
    // Compare what SQLite just returned, including edits made by another connection.
    final plain = previous != null && previous.raw == raw ? previous.plain : _plainText(raw);
    final units = raw.length + plain.length;
    if (units <= _chatPreviewCapacity) {
      while (_chatPreviews.length >= _chatPreviewEntries || _chatPreviewUnits + units > _chatPreviewCapacity) {
        final oldest = _chatPreviews.remove(_chatPreviews.keys.first)!;
        _chatPreviewUnits -= oldest.raw.length + oldest.plain.length;
      }
      _chatPreviews[chatId] = (raw: raw, plain: plain);
      _chatPreviewUnits += units;
    }
    return plain;
  }

  List<TavernChatSummary> _chatSummaries({String? characterId}) => [
    for (final chat in _store.listChats(characterId: characterId))
      TavernChatSummary(
        id: chat.id,
        characterId: chat.characterId,
        title: chat.title,
        updatedAt: chat.updatedAt,
        lastText: _chatPreview(chat.id, chat.lastText),
        messageCount: chat.messageCount,
        kind: chat.kind,
        memberCharacterIds: chat.memberCharacterIds,
      ),
  ];

  Future<List<TavernCharacter>> _characterSummaries() async {
    final records = await _characters();
    if (_closed) return const [];
    final stats = _store.characterChatStats();
    final result = [
      for (final record in records)
        record.toCharacter(chatCount: stats[record.id]?.count ?? 0, lastChatAt: stats[record.id]?.lastAt),
    ];
    result.sort((a, b) {
      final chatOrder = (b.lastChatAt?.millisecondsSinceEpoch ?? -1).compareTo(
        a.lastChatAt?.millisecondsSinceEpoch ?? -1,
      );
      if (chatOrder != 0) return chatOrder;
      final importOrder = b.importedAt!.compareTo(a.importedAt!);
      return importOrder != 0 ? importOrder : a.id.compareTo(b.id);
    });
    return result;
  }

  void _notifyLists({bool resourcesChanged = true}) {
    if (_closed || _closing) return;
    if (resourcesChanged) _scripts.resourcesChanged();
    _charactersChanged.add(null);
    _chatsChanged.add(null);
  }

  @override
  Stream<List<TavernCharacter>> watchCharacters() {
    _ensureOpen();
    return _watch(_charactersChanged.stream, _characterSummaries);
  }

  @override
  Stream<List<TavernChatSummary>> watchChats({String? characterId}) {
    _ensureOpen();
    return _watch(_chatsChanged.stream, () => _chatSummaries(characterId: characterId));
  }

  @override
  Future<TavernCharacter?> character(String id) => _operation(
    () => _libraryOperation(() async {
      final record = await _record(id);
      if (record == null) return null;
      final stats = _store.characterChatStats()[id];
      return record.toCharacter(chatCount: stats?.count ?? 0, lastChatAt: stats?.lastAt);
    }),
  );

  @override
  Future<Map<String, Object?>?> characterFields(String characterId) =>
      _operation(() => _libraryOperation(() => _library.readFields(characterId)));

  @override
  Future<TavernCharacter> updateCharacterFields(String characterId, Map<String, Object?> fields) => _operation(() {
    if (_deletingCharacters.contains(characterId)) throw StateError('Character deletion is running.');
    // Only strings and string lists are accepted by the library. Snapshot the
    // lists now, before this edit waits behind another library operation.
    final patch = <String, Object?>{
      for (final entry in fields.entries)
        entry.key: entry.value is List<Object?> ? List<Object?>.of(entry.value! as List<Object?>) : entry.value,
    };
    return _libraryOperation(() async {
      final stored = await _library.updateFields(characterId, patch);
      _characterCache = null;
      _cacheCharacterRecord(characterId, stored);
      _notifyLists();
      final stats = _store.characterChatStats()[characterId];
      return stored.toCharacter(chatCount: stats?.count ?? 0, lastChatAt: stats?.lastAt);
    });
  });

  @override
  Future<TavernCharacter> addCharacterBookEntry(String characterId, Map<String, Object?> entry) => _operation(() {
    final captured = _captureBookEntry(entry);
    return _editCharacterBook(characterId, () => _library.addBookEntry(characterId, captured));
  });

  @override
  Future<TavernCharacter> updateCharacterBookEntry(String characterId, int index, Map<String, Object?> fields) =>
      _operation(() {
        final captured = _captureBookEntry(fields);
        return _editCharacterBook(characterId, () => _library.updateBookEntry(characterId, index, captured));
      });

  @override
  Future<TavernCharacter> deleteCharacterBookEntry(String characterId, int index) =>
      _operation(() => _editCharacterBook(characterId, () => _library.deleteBookEntry(characterId, index)));

  Map<String, Object?> _captureBookEntry(Map<String, Object?> fields) {
    try {
      return jsonDecode(jsonEncode(fields)) as Map<String, Object?>;
    } on JsonUnsupportedObjectError {
      throw ArgumentError.value(fields, 'fields', 'Expected JSON entry fields');
    }
  }

  Future<TavernCharacter> _editCharacterBook(String characterId, Future<StoredCharacter> Function() save) {
    if (_deletingCharacters.contains(characterId)) {
      throw StateError('Character deletion is running.');
    }
    return _libraryOperation(() async {
      final stored = await save();
      _characterCache = null;
      _cacheCharacterRecord(characterId, stored);
      _notifyLists();
      final stats = _store.characterChatStats()[characterId];
      return stored.toCharacter(chatCount: stats?.count ?? 0, lastChatAt: stats?.lastAt);
    });
  }

  @override
  Future<Map<String, Object?>> previewCharacterBook(String characterId, String text, {String? chatId, int seed = 0}) =>
      _operation(() async {
        final chat = chatId == null ? null : _store.chat(chatId);
        if (chat != null && chat.characterId != characterId) {
          throw ArgumentError.value(chatId, 'chatId', 'The chat belongs to another character.');
        }
        final leaf = chat?.currentLeafId;
        final metadata = chat == null ? <String, Object?>{} : _chatCodec.metadataForNode(_store, chat.id);
        final state = chat == null
            ? <String, Object?>{}
            : leaf == null
            ? _emptyChatState(metadata)
            : _stateAt(chat.id, leaf);
        final provenance =
            state['chatJsonlSourceFile'] ??
            (chat == null ? null : _map(_map(chat.metadata['dshgo'])['chatJsonl'])['rootFile']);
        final sourceFile = provenance is String ? provenance : null;
        final selection = _personas.resolve(personaId: chat?.personaId);
        final settings = _personaSettings(_effectiveReadSettings(chat, metadata), selection);
        final cached = chat == null ? null : _liveVariables[chat.id];
        final local = cached != null && cached.leaf == leaf
            ? _runtimeCopy(cached.values)
            : state.containsKey('variables')
            ? _map(state['variables'])
            : leaf != null && sourceFile != null
            ? <String, Object?>{}
            : _copy(chat?.variables ?? const {});
        final global = _runtimeCopy(_globalVariables);
        final history = chat == null ? <StoredNode>[] : _historyTo(chat.id, leaf);
        final siblingIndex = chat == null || text.isEmpty ? 0 : _store.children(chat.id, leaf).length;
        final config = _config;
        final at = _clock();
        final random = Random(seed).nextDouble;
        final identity = chat == null
            ? 'preview:$characterId'
            : _macroChatIdentity(chat, state, metadata, sourceFile, node: history.lastOrNull);
        final gameplayCapture = _captureGameplayResources(
          this,
          characterId: characterId,
          chatId: chatId,
          kinds: const {'regex'},
          deferResourceErrors: true,
        );
        // All mutable runtime inputs above were captured before the file read.
        // This query never owns a turn and never publishes its computed state.
        final record = await _record(characterId);
        if (record == null) {
          throw const TavernImportError('角色不存在。');
        }
        final data = _effectiveCard(record.card.data, settings);
        final rawPreset = _map(settings['preset']);
        final preset = ChatPreset({
          ...(rawPreset.isEmpty ? ChatPreset.stDefault().raw : rawPreset),
          if (!rawPreset.containsKey('show_thoughts')) 'show_thoughts': !config.deepseek || config.thinking,
        });
        void checkGameplay() {
          if (!_gameplayResourcesCurrent(this, gameplayCapture)) {
            _gameplayCaptureConflict();
          }
        }

        checkGameplay();
        final environment = _MacroEnvironment(
          data,
          settings,
          local,
          global,
          history,
          config,
          at,
          random,
          identity,
          text,
          'normal',
          chatIdHash: _finiteNumber(metadata['chat_id_hash']),
          pickRerollSeed: metadata['pick_reroll_seed'],
          characterId: characterId,
          preset: preset,
          messageVariables: state['messageVariables'],
          messageVariablesExists: state.containsKey('messageVariables'),
          packRegex: _resolveGameplayResources(
            gameplayCapture,
            settings,
            actorId: characterId,
            kinds: const {'regex'},
          ).regex,
        );
        if (text.isNotEmpty) {
          final regexed = environment.regex.apply(
            text,
            placement: RegexPlacement.userInput,
            expand: environment.regexExpand,
          );
          final input = environment.expand(regexed, const {});
          history.add(
            StoredNode(
              message: TavernMessage(
                nodeId: 'preview-user',
                parentId: leaf,
                role: TavernRole.user,
                speaker: environment.userName,
                text: input,
                at: at,
                siblingIndex: siblingIndex,
                siblingCount: siblingIndex + 1,
              ),
              depth: history.length + 1,
              extra: const {},
              original: const {},
            ),
          );
        }
        final prepared = prepareCharacterFields(data, persona: environment.persona, expand: environment.baseExpand);
        if (history.isNotEmpty) {
          history[0] = _nodeWithText(history.first, environment.expand(history.first.message.text, const {}));
        }
        final promptHistory = _preparePromptHistory(history, environment, continuing: false);
        final eligible = promptHistory.where((node) => !node.message.hidden && !_systemMessage(node)).toList();
        final injections = _configuredInjections(
          settings,
          prepared,
          data,
          userMessageCount: history.where((node) => node.message.role == TavernRole.user).length,
        );
        final scanInjections = <String>[];
        for (final injection in injections) {
          if (!injection.scan) {
            continue;
          }
          final content = environment.expand(injection.injection.fragment.content, const {});
          if (content.isNotEmpty) {
            scanInjections.add(content);
          }
        }
        final embedded = data['character_book'];
        final world = await _worldInfoEngine.evaluate(
          WorldInfoInput(
            books: [
              if (embedded is Map<String, Object?>)
                WorldInfoBook.fromJson(id: '$characterId:card', source: WorldInfoSource.character, json: embedded),
            ],
            messages: [for (final node in eligible) WorldInfoMessage(node.message.text, speaker: node.message.speaker)],
            maxContext: environment.maxContext - environment.maxResponse,
            tokenCount: _counter.countText,
            random: random,
            expand: (value) => environment.expand(value, const {}),
            settings: WorldInfoSettings.fromJson(_map(settings['worldInfo'])),
            scanInjections: scanInjections,
            personaDescription: prepared.persona,
            characterDescription: prepared['description'],
            characterPersonality: prepared['personality'],
            characterDepthPrompt: prepared['charDepthPrompt'],
            scenario: prepared['scenario'],
            creatorNotes: prepared['creator_notes'],
            characterName: _characterFilename(settings, characterId),
            characterTags: _characterTags(settings, characterId),
            timedWorldInfo: _map(state['timedWorldInfo']),
            decoratorState: _map(state['decoratorState']),
            assistantMessageCount: eligible.where((node) => node.message.role == TavernRole.character).length,
            greetingIndex: state['greetingIndex'] is int ? state['greetingIndex'] as int : null,
            userIconName: settings['userIconName'] as String?,
            // Evaluate normal effects on copies, then discard them. No complete
            // prompt was assembled, so contextAtCapacity deliberately stays null.
            availablePromptSections: _availableWorldSections(preset, 'normal'),
            postProcessContent: (entry, content, depth) => environment.regex.apply(
              content,
              placement: RegexPlacement.worldInfo,
              phase: RegexPhase.prompt,
              depth: depth,
              expand: environment.regexExpand,
            ),
          ),
        );
        checkGameplay();
        return {
          'scope': 'character-book',
          'stage': 'world-info',
          'seed': seed,
          'chatId': chatId,
          'contextNodeId': leaf,
          ..._worldInfoTrace(world),
        };
      });

  @override
  Future<TavernCharacter> importCard(Uint8List bytes, {String? fileName}) =>
      _operation(() => _importCard(bytes, fileName: fileName));

  /// [importCard] for an operation already admitted: one that began before a
  /// backup closed admission still takes its cards in.
  Future<TavernCharacter> _importCard(Uint8List bytes, {String? fileName}) => _libraryOperation(() async {
    var diagnostics = <TavernRegexDiagnostic>[];
    final stored = await _library.importCard(
      bytes,
      fileName: fileName,
      inspect: (card) async {
        diagnostics = await _checkCardRegex(card.data);
        return assessImportAsync(
          kind: TavernImportKind.character,
          document: card.json,
          embeddedAssetPaths: card.assets.keys,
          regexDiagnostics: diagnostics,
          checkedAt: _clock().toUtc(),
        );
      },
    );
    _characterCache = null;
    _cacheCharacterRecord(stored.id, stored);
    _notifyLists();
    return stored.toCharacter(regexDiagnostics: diagnostics);
  });

  @override
  Future<Uint8List> exportCard(String characterId, {TavernCardFormat format = TavernCardFormat.png}) =>
      _operation(() => _library.exportCard(characterId, format: format));

  @override
  Future<void> deleteCharacter(String characterId) {
    _ensureAdmission();
    final hosted = _store.groupHostChats(characterId);
    if (hosted.isNotEmpty) {
      return Future.error(
        TavernGroupException(TavernGroupError.hostInUse, characterId: characterId, relatedChatIds: hosted),
      );
    }
    if (!_deletingCharacters.add(characterId)) {
      return Future.error(StateError('Character deletion is already running.'));
    }
    return _operation(
      () => _libraryOperation(() async {
        try {
          final hosted = _store.groupHostChats(characterId);
          if (hosted.isNotEmpty) {
            throw TavernGroupException(TavernGroupError.hostInUse, characterId: characterId, relatedChatIds: hosted);
          }
          final ids = _store.listChats(characterId: characterId).map((chat) => chat.id).toList();
          await Future.wait([for (final id in ids) _withMutation<void>(id, () {})]);
          await Future.wait([for (final id in ids) _directors.cancelChat(id)]);
          await _library.delete(characterId);
          _characterCache = null;
          unawaited(_characterDetails.remove(characterId));
          _store.transaction(() {
            _store.removeCharacterGroupMemberships(characterId);
            _store.deleteCharacterChats(characterId);
          });
          for (final id in ids) {
            _inspections.remove(id);
            _latestInspections.remove(id);
            _liveVariables.remove(id);
            _promptCacheWindows.remove(id);
          }
          _characterCache = null;
          _notifyLists();
        } finally {
          _deletingCharacters.remove(characterId);
          _notifyLists();
        }
      }),
    );
  }

  @override
  Stream<List<TavernPersona>> watchPersonas() {
    _ensureOpen();
    return _watch(_personas.changes, _personas.list);
  }

  @override
  Future<TavernPersona?> persona(String personaId) =>
      _operation(() => _personaOperation(() async => _personas.get(personaId)));

  @override
  Future<TavernPersona> createPersona({
    required String name,
    String description = '',
    String? avatarPath,
    int descriptionPosition = PersonaDescriptionPosition.inPrompt,
  }) => _operation(
    () => _personaOperation(
      () => _personas.create(
        name: name,
        description: description,
        avatarPath: avatarPath,
        descriptionPosition: descriptionPosition,
      ),
    ),
  );

  @override
  Future<TavernPersona> updatePersona(
    String personaId, {
    String? name,
    String? description,
    String? avatarPath,
    bool clearAvatar = false,
    int? descriptionPosition,
  }) => _operation(
    () => _personaOperation(
      () => _personas.update(
        personaId,
        name: name,
        description: description,
        avatarPath: avatarPath,
        clearAvatar: clearAvatar,
        descriptionPosition: descriptionPosition,
      ),
    ),
  );

  @override
  Future<PersonaSelection> personaSelection({String? chatId}) => _operation(
    () => _personaOperation(() async => chatId == null ? _personas.resolve() : _personas.forChat(_store, chatId)),
  );

  @override
  Future<void> setDefaultPersona(String? personaId) =>
      _operation(() => _personaOperation(() => _personas.setDefault(personaId)));

  @override
  Future<void> bindPersona(String chatId, String? personaId) => _operation(
    () => _personaOperation(() async {
      // Reject a missing profile before disturbing an otherwise valid turn.
      if (personaId != null && _personas.get(personaId) == null) throw StateError('Unknown persona: $personaId');
      if (_store.chat(chatId).personaId == personaId) return;
      await _withMutation(chatId, () => _personas.bindChat(_store, chatId, personaId));
    }),
  );

  @override
  Future<void> deletePersona(String personaId) => _operation(
    () => _personaOperation(() async {
      _deletingPersonas.add(personaId);
      try {
        final affected = <String>{};
        for (final chat in _store.listChatPersonaBindings()) {
          if (chat.personaId == personaId ||
              _personas.resolve(personaId: chat.personaId).persona?.id == personaId ||
              _turns[chat.id]?.personaSelection.persona?.id == personaId ||
              _groups.rounds[chat.id]?.persona.persona?.id == personaId) {
            affected.add(chat.id);
          }
        }
        // Hold every affected chat gate until both profile and bindings have
        // been updated. The active turn may still use this profile even when
        // its chat has inherited a different default since that turn began.
        await _withMutations(affected, () async {
          await _personas.delete(personaId, chats: _store);
        });
      } finally {
        _deletingPersonas.remove(personaId);
      }
    }),
  );

  @override
  Future<String> createChat(String characterId, {int greeting = 0}) => _operation(
    () => _libraryOperation(() async {
      if (_deletingCharacters.contains(characterId)) throw StateError('Character deletion is running.');
      final gameplayAdmission = _captureGameplayAdmission(this, characterId: characterId, settings: const {});
      final record = await _record(characterId);
      if (record == null) throw const TavernImportError('角色不存在。');
      if (_deletingCharacters.contains(characterId)) throw StateError('Character deletion is running.');
      if (_globalPresetUpdate || _deletingPresets.contains(_resolvePreset().selection.effectivePresetId)) {
        throw StateError('Preset selection is changing.');
      }
      final data = record.card.data;
      final greetings = <String>[_string(data['first_mes']), ..._strings(data['alternate_greetings'])];
      RangeError.checkValidIndex(greeting, greetings, 'greeting');
      final selection = _personas.resolve();
      if (_deletingPersonas.contains(selection.persona?.id)) throw StateError('Persona deletion is running.');
      final settings = _personaSettings(_effectiveReadSettings(), selection);
      final gameplay = gameplayAdmission.hasActivePacks
          ? await _prepareGameplayRuntime(this, gameplayAdmission, hostData: record.card.data, settings: settings)
          : null;
      if (gameplayAdmission.hasActivePacks) {
        // The pack source read adds an await after the original settings gate.
        if (_deletingCharacters.contains(characterId)) {
          throw StateError('Character deletion is running.');
        }
        if (_globalPresetUpdate || _deletingPresets.contains(_resolvePreset().selection.effectivePresetId)) {
          throw StateError('Preset selection is changing.');
        }
        if (_deletingPersonas.contains(selection.persona?.id)) {
          throw StateError('Persona deletion is running.');
        }
      }
      final gameplayResources = _resolveGameplayResources(
        _GameplayResourceCapture.fromAdmission(gameplayAdmission),
        settings,
        actorId: characterId,
        kinds: const {'regex'},
      );
      final variables = <String, Object?>{};
      final beforeGlobals = _globalVariables.revision;
      late final String id;
      try {
        id = _store.transaction(() {
          final id = _store.createChat(characterId: characterId, title: record.card.name);
          final context = _MacroEnvironment(
            data,
            settings,
            variables,
            _globalVariables,
            [],
            _config,
            _clock(),
            _random,
            id,
            '',
            'normal',
            characterId: characterId,
            packRegex: gameplayResources.regex,
          );
          final regexed = context.regex.apply(
            greetings[greeting],
            placement: RegexPlacement.aiOutput,
            expand: context.regexExpand,
          );
          final text = context.expand(regexed, const {}).replaceAll('\r', '');
          final state = <String, Object?>{
            'variables': _copy(variables),
            'timedWorldInfo': <String, Object?>{},
            'decoratorState': <String, Object?>{},
            'greetingIndex': greeting,
            'stChatId': id,
            'stChatIdHash': context.chatIdHash,
          };
          if (!_gameplayAdmissionCurrent(this, gameplayAdmission)) {
            _gameplayCaptureConflict();
          }
          _initializeDshState(
            gameplay?.state ?? _stateDefinition(data),
            state,
            settings['stateEnabled'] != false,
            gameplay: gameplay,
          );
          if (gameplay != null && state['dshgoPackDefinitionConfigId'] == gameplay.effectiveConfigId) {
            _ensureGameplayConfig(this, gameplay);
          }
          _store.append(
            id,
            parentId: null,
            role: TavernRole.character,
            speaker: record.card.promptName,
            speakerCharacterId: characterId,
            text: text,
            state: state,
          );
          _store.updateChat(
            id,
            variables: _copy(variables),
            settings: {if (_mvuDeclared(data)) 'mvuEnabled': true},
            metadata: _runtimeMetadata(_store.chat(id).metadata, state),
          );
          return id;
        });
      } catch (createError, createStackTrace) {
        // SQL is rolled back, but preparation follows ST/T8 global-variable
        // semantics: preserve and save effects that happened before the error.
        try {
          if (_globalVariables.changedSince(beforeGlobals)) {
            await _saveDocument();
          }
        } catch (saveError, saveStackTrace) {
          Error.throwWithStackTrace(
            _PreparationSaveFailure(createError, createStackTrace, saveError, saveStackTrace),
            saveStackTrace,
          );
        }
        Error.throwWithStackTrace(createError, createStackTrace);
      }
      _liveVariables[id] = (leaf: _store.chat(id).currentLeafId, values: _runtimeCopy(variables));
      if (_globalVariables.changedSince(beforeGlobals)) {
        await _saveDocument();
      }
      _notifyLists();
      return id;
    }),
  );

  @override
  Future<String> createGroupChat(
    List<String> characterIds, {
    String? hostCharacterId,
    String? title,
    TavernGroupActivation activation = TavernGroupActivation.natural,
    int maxSpeakersPerTurn = 3,
    bool allowSelfResponses = false,
    bool addGreetings = true,
  }) => _operation(() {
    final ids = List<String>.of(characterIds);
    return _libraryOperation(
      () => _groups.create(
        ids,
        hostCharacterId: hostCharacterId,
        title: title,
        activation: activation,
        maxSpeakersPerTurn: maxSpeakersPerTurn,
        allowSelfResponses: allowSelfResponses,
        addGreetings: addGreetings,
      ),
    );
  });
  @override
  Future<TavernGroupChat?> groupChat(String chatId) => _operation(() => _groups.read(chatId));
  @override
  Stream<TavernGroupChat?> watchGroupChat(String chatId) {
    _ensureOpen();
    return _watch(_chatsChanged.stream, () => _groups.read(chatId));
  }

  @override
  Future<TavernGroupChat> addGroupMember(
    String chatId,
    String characterId, {
    double? talkativeness,
    bool muted = false,
    TavernGroupModelRole? modelRole,
  }) => _operation(
    () => _libraryOperation(
      () => _withMutation(
        chatId,
        () => _groups.add(chatId, characterId, talkativeness: talkativeness, muted: muted, modelRole: modelRole),
      ),
    ),
  );
  @override
  Future<TavernGroupChat> updateGroupMember(
    String chatId,
    String characterId, {
    double? talkativeness,
    bool? muted,
    TavernGroupModelRole? modelRole,
  }) => _operation(
    () => _withMutation(
      chatId,
      () => _groups.updateMember(chatId, characterId, talkativeness: talkativeness, muted: muted, modelRole: modelRole),
    ),
  );
  @override
  Future<TavernGroupChat> removeGroupMember(String chatId, String characterId) =>
      _operation(() => _withMutation(chatId, () => _groups.remove(chatId, characterId)));
  @override
  Future<TavernGroupChat> reorderGroupMembers(String chatId, List<String> characterIds) => _operation(() {
    final captured = List<String>.of(characterIds);
    return _withMutation(chatId, () => _groups.reorder(chatId, captured));
  });
  @override
  Future<TavernGroupChat> updateGroupChat(
    String chatId, {
    String? title,
    TavernGroupActivation? activation,
    int? maxSpeakersPerTurn,
    bool? allowSelfResponses,
  }) => _operation(
    () => _withMutation(
      chatId,
      () => _groups.update(
        chatId,
        title: title,
        activation: activation,
        maxSpeakersPerTurn: maxSpeakersPerTurn,
        allowSelfResponses: allowSelfResponses,
      ),
    ),
  );
  @override
  Stream<TavernGroupEvent> sendGroup(String chatId, String text, {String? speakerCharacterId}) =>
      _groups.send(chatId, text, speakerCharacterId: speakerCharacterId);
  @override
  Stream<TavernGroupEvent> resumeGroupTurn(String chatId) => _groups.resume(chatId);

  @override
  Future<TavernChatImportResult> importChats(
    String characterId,
    List<TavernChatFile> files, {
    Map<String, String> lorebookIds = const {},
  }) => _operation(() {
    final capturedFiles = List<TavernChatFile>.of(files);
    final mapping = Map<String, String>.of(lorebookIds);
    final profile = _TurnProfile.start();
    // Reserve the original library queue before decode can yield, preserving
    // call order even when a later small batch prepares faster than this one.
    return _libraryOperation(() async {
      profile?.mark('queue');
      final documents = await ChatJsonlCodec.decodeFiles(capturedFiles);
      profile?.mark('decode');
      for (final entry in mapping.entries) {
        if (entry.key.isEmpty) throw ArgumentError.value(entry.key, 'lorebookIds', 'ST names must not be empty.');
        _requireBookId(entry.value);
      }
      if (_deletingCharacters.contains(characterId)) throw StateError('Character deletion is running.');
      if (await _record(characterId) == null) throw const TavernImportError('角色不存在。');
      if (_deletingCharacters.contains(characterId)) throw StateError('Character deletion is running.');
      profile?.mark('resources');
      final extraNotices = <String>[];
      for (final document in documents) {
        final metadata = _map(document.header['chat_metadata']);
        final name = metadata['world_info'];
        if (name is String && name.isNotEmpty && !mapping.containsKey(name)) {
          extraNotices.add('${document.fileName}:${document.headerLineNumber}: 世界书“$name”没有本地映射；保留名称，暂不执行该绑定。');
        }
      }
      final plan = await _chatCodec.prepareBatchAsync(documents);
      profile?.mark('prepare');
      ChatJsonlImportResult commit() {
        if (_deletingCharacters.contains(characterId)) throw StateError('Character deletion is running.');
        final commitStarted = profile?.now;
        final imported = _store.transaction(() {
          final result = _chatCodec.commitBatch(_store, characterId: characterId, plan: plan);
          if (mapping.isNotEmpty) {
            for (final chatId in result.chatIds) {
              _store.updateChat(chatId, settings: {'stLorebookIds': mapping});
            }
          }
          return result;
        });
        profile?.record('chat_import_commit', commitStarted!);
        return imported;
      }

      final imported = mapping.isEmpty
          ? commit()
          : await _bookOperation(() async {
              for (final id in mapping.values.toSet()) {
                if (await _readBookNow(id) == null) throw const TavernImportError('映射的世界书不存在。');
              }
              return commit();
            });
      profile?.mark('commit');
      _notifyLists();
      profile?.mark('publish');
      return TavernChatImportResult(
        chatIds: imported.chatIds,
        chatsByFile: imported.chatsByFile,
        notices: [...imported.notices, ...extraNotices],
      );
    }).whenComplete(() {
      profile?.finish('chat_import');
    });
  });

  @override
  Future<List<TavernDeepSeekSession>> inspectDeepSeekExport(String zipPath) => _inspectDeepSeekExport(zipPath);
  @override
  Future<List<TavernDeepSeekImported>> importDeepSeekSessions(String zipPath, List<String> sessionIds) =>
      _importDeepSeekSessions(zipPath, sessionIds);

  @override
  Future<List<TavernChatFile>> exportChat(String chatId, {String? fileName}) => _operation(() {
    final active = _turns[chatId];
    final usageOverrides = <String, TavernUsage?>{
      if (active != null && active.reply != null && active.toolRequests.length > 1)
        active.reply!.nodeId: active.inspection.reportedUsage,
    };
    return List<TavernChatFile>.unmodifiable([
      for (final document in _chatCodec.exportChat(_store, chatId, fileName: fileName, usageOverrides: usageOverrides))
        TavernChatFile(fileName: document.fileName, bytes: document.encode()),
    ]);
  });

  @override
  Future<void> deleteChat(String chatId) => _operation(
    () => _withMutation(chatId, () async {
      await _directors.cancelChat(chatId);
      _store.deleteChat(chatId);
      _scriptCatalogChanged.add(null);
      _inspections.remove(chatId);
      _latestInspections.remove(chatId);
      _liveVariables.remove(chatId);
      _promptCacheWindows.remove(chatId);
    }),
  );

  @override
  Future<List<TavernMessage>> path(String chatId, {int limit = 60, String? beforeNodeId}) => _operation(() {
    final messages = _store.path(chatId, limit: limit, beforeNodeId: beforeNodeId);
    final active = _turns[chatId];
    if (active == null || active.reply == null) return messages;
    return [
      for (final message in messages)
        if (message.nodeId == active.reply!.nodeId)
          _withReportedUsage(message, active.inspection.reportedUsage, replaceUsage: active.toolRequests.length > 1)
        else
          message,
    ];
  });

  @override
  Future<List<TavernPathUsage>> pathUsage(String chatId) =>
      _operation(() => _store.pathUsage(chatId, excludeNodeId: _turns[chatId]?.reply?.nodeId));

  @override
  Future<List<TavernToolTurnSummary>> recentToolTurns(String chatId, {int limit = 20}) =>
      _operation(() => _store.recentToolTurns(chatId, limit: limit));

  @override
  Future<List<TavernTreeNode>> tree(String chatId) => _operation(() {
    final chat = _store.chat(chatId);
    final nodes = _store.allNodes(chatId);
    final byId = {for (final node in nodes) node.message.nodeId: node};
    final currentPath = <String>{};
    var id = chat.currentLeafId;
    while (id != null) {
      final node = byId[id];
      if (node == null || !currentPath.add(id)) {
        throw StateError('The selected message path is disconnected or cyclic.');
      }
      id = node.message.parentId;
    }
    final result = <TavernTreeNode>[];
    for (final node in nodes) {
      final message = node.message;
      final own = node.extra['dshgo'];
      final name = own is Map<String, Object?> ? own['branchName'] : null;
      result.add(
        TavernTreeNode(
          nodeId: message.nodeId,
          parentId: message.parentId,
          role: message.role,
          speaker: message.speaker,
          preview: String.fromCharCodes(message.text.runes.take(64)),
          at: message.at,
          isCurrentPath: currentPath.contains(message.nodeId),
          siblingIndex: message.siblingIndex,
          siblingCount: message.siblingCount,
          hidden: message.hidden,
          branchName: name is String ? name : null,
          speakerCharacterId: message.speakerCharacterId,
        ),
      );
    }
    return result;
  });

  @override
  Future<Map<String, Object?>> readVariables(String chatId) => _operation(() {
    final leaf = _store.chat(chatId).currentLeafId;
    if (leaf == null) {
      return <String, Object?>{};
    }
    return _runtimeCopy(_map(_stateAt(chatId, leaf)['variables']));
  });

  @override
  Future<TavernStateSnapshot> readState(String chatId) => _operation(() => _readSavedState(this, chatId));

  @override
  Future<TavernToolTurnSnapshot?> readToolTurn(String logicalTurnId) => _readToolTurnApi(this, logicalTurnId);
  @override
  Future<TavernToolReceipt?> readToolReceipt(String executionId) => _readToolReceiptApi(this, executionId);
  @override
  Future<TavernToolReceipt> rollDice(
    String chatId, {
    required String actionId,
    required String dice,
    String? label,
    int? target,
    String? expectedNodeId,
  }) => _rollDiceApi(
    this,
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
  }) => _resolveMemoryProposalApi(
    this,
    proposalId,
    decisionId: decisionId,
    expectedVersion: expectedVersion,
    decision: decision,
    expectedContextAnchor: expectedContextAnchor,
  );
  @override
  Future<TavernToolPolicySnapshot> readToolPolicy({String? chatId}) => _readToolPolicyApi(this, chatId: chatId);
  @override
  Future<TavernToolPolicyWriteResult> setToolPolicy(Map<String, Object?> patch, {String? chatId}) =>
      _setToolPolicyApi(this, patch, chatId: chatId);

  @override
  Future<TavernStateEditResult> setStateValue(String chatId, String path, Object? value, {String? expectedNodeId}) =>
      _editSavedState(this, chatId, path, value, expectedNodeId: expectedNodeId);

  @override
  Future<List<TavernAgentRun>> readAgentRuns(String chatId, {String? nodeId, int limit = 50}) => _operation(
    () => [
      for (final run in _store.agentRuns(chatId, nodeId: nodeId, limit: limit))
        TavernAgentRun(
          id: run.id,
          chatId: run.chatId,
          nodeId: run.nodeId,
          kind: run.kind,
          at: run.at,
          usage: run.usage,
          result: run.result,
        ),
    ],
  );

  @override
  Future<TavernDirectorSnapshot> readDirector(String chatId) => _operation(() => _directors.read(chatId));

  @override
  Stream<TavernDirectorSnapshot> watchDirector(String chatId) {
    _ensureOpen();
    return _directors.watch(chatId);
  }

  @override
  Future<TavernDirectorRun> runDirector(String chatId) => _operation(() => _directors.manual(chatId));

  @override
  Future<List<TavernDirectorEvent>> readDirectorEvents(String chatId, {int limit = 50, String? beforeEventId}) =>
      _operation(() => _directors.events(chatId, limit: limit, beforeEventId: beforeEventId));

  @override
  Stream<void> pathChanges(String chatId) {
    _ensureOpen();
    return _paths.stream.where((id) => id == chatId).map<void>((_) {});
  }

  List<TavernPresetSummary> _presetSummaries() => [
    for (final value in _store.listPresets())
      TavernPresetSummary(
        id: value.id,
        name: value.name,
        createdAt: value.createdAt,
        updatedAt: value.updatedAt,
        hasEnvelope: value.hasEnvelope,
      ),
  ];

  TavernPreset _presetView(StoredPreset value) => TavernPreset(
    id: value.id,
    name: value.name,
    sourceText: value.sourceText,
    raw: value.raw,
    envelope: value.envelope,
    createdAt: value.createdAt,
    updatedAt: value.updatedAt,
  );

  StoredPreset _requirePreset(String id) => _store.preset(id) ?? (throw StateError('Unknown preset: $id'));

  @override
  Future<List<TavernPresetSummary>> listPresets() => _operation(_presetSummaries);

  @override
  Stream<List<TavernPresetSummary>> watchPresets() {
    _ensureOpen();
    return _watch(_store.presetChanges, _presetSummaries);
  }

  @override
  Future<TavernPreset?> preset(String presetId) => _operation(() {
    final value = _store.preset(presetId);
    return value == null ? null : _presetView(value);
  });

  @override
  Future<TavernPresetImportResult> importPreset(String text, {String? fileName}) => _operation(() async {
    final decoded = _presetCodec.decode(text, fileName: fileName);
    final importedRaw = decoded.raw;
    final fixedName = spresetSanitizedPresetName(spresetFixedPresetName(importedRaw));
    final diagnostics = await inspectRegexScripts(_map(importedRaw['extensions'])['regex_scripts'], _regexWorker);
    return _presetOperation(() async {
      // Name resolution and publication share the preset mutation queue.
      // Regex inspection above may await while another import claims the name.
      final conflict =
          fixedName.isNotEmpty &&
          _store.listPresets().any((preset) => _slashNamesEqualIgnoreCaseAndAccents(preset.name, fixedName));
      final issues = [
        ...decoded.issues,
        if (conflict)
          TavernPresetIssue(
            path: r'$.extensions.SPreset.FixedPresetName',
            code: 'spreset-fixed-name-conflict',
            message:
                'A preset named "$fixedName" already exists. Imported under its source name; the fixed-name marker was kept.',
          ),
      ];
      if (fixedName.isNotEmpty && !conflict) clearSPresetFixedPresetName(importedRaw);
      final report = await assessImportAsync(
        kind: TavernImportKind.preset,
        document: importedRaw,
        envelope: decoded.envelope,
        regexDiagnostics: diagnostics,
        presetIssues: issues,
        checkedAt: _clock().toUtc(),
      );
      final value = _store.createPreset(
        name: fixedName.isEmpty || conflict ? decoded.name : fixedName,
        sourceText: text,
        raw: importedRaw,
        envelope: decoded.envelope,
        importReport: report,
      );
      return TavernPresetImportResult(_presetView(value), issues, regexDiagnostics: diagnostics);
    });
  });

  TavernPresetImportResult _savePresetEdit(StoredPreset original, Map<String, Object?> raw, {String? name}) {
    final envelope = original.envelope;
    if (name != null && envelope != null) envelope['metadata'] = {..._map(envelope['metadata']), 'name': name};
    final decoded = _presetCodec.validate(raw, envelope: envelope);
    final value = _store.updatePreset(
      original.id,
      name: name ?? original.name,
      raw: decoded.raw,
      envelope: decoded.envelope,
    );
    return TavernPresetImportResult(_presetView(value), decoded.issues);
  }

  @override
  Future<TavernPresetImportResult> updatePreset(String presetId, Map<String, Object?> patch, {String? name}) =>
      _operation(() {
        final captured = _copy(patch);
        return _presetOperation(() {
          final original = _requirePreset(presetId);
          final raw = _mergeReadMaps(original.raw, captured);
          _guardPresetCarrier(original.raw, raw);
          return _savePresetEdit(original, raw, name: name);
        });
      });

  @override
  Future<Map<String, Object?>> exportSPresetLogs(
    String chatId, {
    Map<String, Object?>? tavernHelper,
    Map<String, Object?>? browserConsole,
  }) {
    final helper = tavernHelper == null ? null : _copy(tavernHelper);
    final console = browserConsole == null ? null : _copy(browserConsole);
    return _operation(() async {
      final chat = _store.chat(chatId);
      final settings = _effectiveReadSettings(chat);
      final preset = _readMap(settings['preset']);
      final selected = _resolvePreset(chat);
      final name = selected.preset?.name ?? _spString(preset['preset_settings_openai'], 'current');
      await _loadSPresetLogs();
      return _spresetLogs.report(presetName: name, at: _clock(), tavernHelper: helper, browserConsole: console);
    });
  }

  @override
  Future<Map<String, Object?>> uploadSPresetLogs(
    String chatId, {
    String? address,
    String? bearerToken,
    Map<String, Object?>? tavernHelper,
    Map<String, Object?>? browserConsole,
  }) {
    final helper = tavernHelper == null ? null : _copy(tavernHelper);
    final console = browserConsole == null ? null : _copy(browserConsole);
    return _operation(() async {
      final chat = _store.chat(chatId);
      final settings = _effectiveReadSettings(chat);
      final preset = _readMap(settings['preset']);
      final selected = _resolvePreset(chat);
      final name = selected.preset?.name ?? _spString(preset['preset_settings_openai'], 'current');
      final config = SPresetConfig.fromPreset(preset);
      final target = address ?? _spString(config.module('LogUpload')['url']);
      await _loadSPresetLogs();
      final report = _spresetLogs.report(presetName: name, at: _clock(), tavernHelper: helper, browserConsole: console);
      final enabled = _readMap(_document['settings'])['spresetLogUploadEnabled'] == true;
      return uploadSPresetLogReport(Uri.parse(target), report, enabled: enabled, bearerToken: bearerToken);
    });
  }

  @override
  Future<String> exportPreset(String presetId) => _operation(() {
    final value = _requirePreset(presetId);
    return _presetCodec.encode(value.raw, envelope: value.envelope);
  });

  Map<String, Object?> _knownPrompt(Map<String, Object?> raw, String identifier) {
    final definitions = ChatPreset(raw).settings['prompts']! as List<Object?>;
    for (final value in definitions.whereType<Map<String, Object?>>()) {
      if (value['identifier'] == identifier) return _copy(value);
    }
    throw ArgumentError.value(identifier, 'identifier', 'Unknown prompt');
  }

  void _guardPresetCarrier(Map<String, Object?> previous, Map<String, Object?> next) {
    final before = _map(_map(previous['extensions'])['dshgo']);
    final after = _map(_map(next['extensions'])['dshgo']);
    const key = 'presetEnvelope';
    if (before.containsKey(key) != after.containsKey(key) || !_presetJsonEquals(before[key], after[key])) {
      throw ArgumentError(
        'extensions.dshgo.presetEnvelope is an export-owned carrier; edit the preset fields instead.',
      );
    }
  }

  bool _presetJsonEquals(Object? left, Object? right) {
    if (left is Map<String, Object?> && right is Map<String, Object?>) {
      return left.length == right.length &&
          left.entries.every(
            (entry) => right.containsKey(entry.key) && _presetJsonEquals(entry.value, right[entry.key]),
          );
    }
    if (left is List<Object?> && right is List<Object?>) {
      if (left.length != right.length) return false;
      for (var i = 0; i < left.length; i++) {
        if (!_presetJsonEquals(left[i], right[i])) return false;
      }
      return true;
    }
    return left == right;
  }

  Map<String, Object?> _editableOrder(Map<String, Object?> raw) {
    final groups = raw['prompt_order'] is List<Object?>
        ? List<Object?>.of(raw['prompt_order']! as List<Object?>)
        : <Object?>[];
    raw['prompt_order'] = groups;
    for (final group in groups.whereType<Map<String, Object?>>()) {
      if (presetString(group['character_id']) == '100001') return group;
    }
    final effective = ChatPreset(raw).settings['prompt_order']! as List<Object?>;
    final group = _copy(
      effective.whereType<Map<String, Object?>>().firstWhere(
        (entry) => presetString(entry['character_id']) == '100001',
      ),
    );
    group['character_id'] = 100001;
    groups.add(group);
    return group;
  }

  @override
  Future<TavernPresetImportResult> updatePresetPrompt(String presetId, String identifier, Map<String, Object?> patch) =>
      _operation(() {
        final captured = _copy(patch);
        if (captured.containsKey('identifier') && captured['identifier'] != identifier) {
          throw ArgumentError('A prompt identifier is stable; replace prompts and order together to rename it.');
        }
        return _presetOperation(() {
          final original = _requirePreset(presetId);
          final raw = original.raw;
          final inherited = _knownPrompt(raw, identifier);
          final definitions = raw['prompts'] is List<Object?>
              ? List<Object?>.of(raw['prompts']! as List<Object?>)
              : <Object?>[];
          final index = definitions.indexWhere(
            (value) => value is Map<String, Object?> && value['identifier'] == identifier,
          );
          final previous = index < 0 ? inherited : definitions[index]! as Map<String, Object?>;
          final updated = _merge(previous, captured);
          if (index < 0) {
            definitions.add(updated);
          } else {
            definitions[index] = updated;
          }
          raw['prompts'] = definitions;
          if (captured.containsKey('content') && const ['main', 'nsfw', 'jailbreak'].contains(identifier)) {
            raw.remove('${identifier}_prompt');
          }
          return _savePresetEdit(original, raw);
        });
      });

  @override
  Future<TavernPresetImportResult> setPresetOrder(String presetId, List<String> identifiers) => _operation(() {
    final captured = List<String>.of(identifiers);
    if (captured.toSet().length != captured.length) throw ArgumentError('Prompt order identifiers must be unique.');
    return _presetOperation(() {
      final original = _requirePreset(presetId);
      final raw = original.raw;
      for (final id in captured) {
        _knownPrompt(raw, id);
      }
      final group = _editableOrder(raw);
      final old = group['order'] is List<Object?> ? group['order']! as List<Object?> : const <Object?>[];
      group['order'] = [
        for (final id in captured)
          {
            ...?old.whereType<Map<String, Object?>>().where((entry) => entry['identifier'] == id).firstOrNull,
            'identifier': id,
            if (!old.whereType<Map<String, Object?>>().any((entry) => entry['identifier'] == id)) 'enabled': true,
          },
      ];
      return _savePresetEdit(original, raw);
    });
  });

  @override
  Future<TavernPresetImportResult> setPresetPromptEnabled(String presetId, String identifier, bool enabled) =>
      _operation(
        () => _presetOperation(() {
          final original = _requirePreset(presetId);
          final raw = original.raw;
          _knownPrompt(raw, identifier);
          final group = _editableOrder(raw);
          final order = group['order'] is List<Object?>
              ? List<Object?>.of(group['order']! as List<Object?>)
              : <Object?>[];
          final index = order.indexWhere((entry) => entry is Map<String, Object?> && entry['identifier'] == identifier);
          if (index < 0) {
            order.add({'identifier': identifier, 'enabled': enabled});
          } else {
            order[index] = {...order[index]! as Map<String, Object?>, 'enabled': enabled};
          }
          group['order'] = order;
          return _savePresetEdit(original, raw);
        }),
      );

  StoredPreset? _executionPreset(String id) {
    final version = _store.presetVersion;
    if (!identical(_executionPresetVersion, version)) {
      _executionPresets.clear();
      _executionPresetVersion = version;
    }
    return _executionPresets.putIfAbsent(id, () => _store.preset(id));
  }

  ({StoredPreset? preset, TavernPresetSelection selection}) _resolvePreset([StoredChat? chat]) {
    final bound = chat?.presetId;
    final defaultId = _store.defaultPresetId;
    final missing = <String>[];
    ({StoredPreset? preset, TavernPresetSelection selection}) result(
      PresetSelectionSource source, [
      StoredPreset? value,
    ]) => (
      preset: value,
      selection: TavernPresetSelection(
        source: source,
        boundPresetId: bound,
        defaultPresetId: defaultId,
        effectivePresetId: value?.id,
        missingPresetIds: List<String>.unmodifiable(missing),
      ),
    );
    if (bound != null) {
      final value = _executionPreset(bound);
      if (value != null) return result(PresetSelectionSource.chat, value);
      missing.add(bound);
    }
    if (chat != null && chat.settings.containsKey('preset')) return result(PresetSelectionSource.chatInline);
    if (defaultId != null) {
      final value = _executionPreset(defaultId);
      if (value != null) return result(PresetSelectionSource.globalDefault, value);
      missing.add(defaultId);
    }
    if (_readMap(_document['settings']).containsKey('preset')) return result(PresetSelectionSource.globalInline);
    return result(PresetSelectionSource.stDefault);
  }

  @override
  Future<TavernPresetSelection> presetSelection({String? chatId}) =>
      _operation(() => _resolvePreset(chatId == null ? null : _store.chat(chatId)).selection);

  @override
  Future<void> setDefaultPreset(String? presetId) => _operation(
    () => _presetOperation(() {
      late _PresetWorkingMutation working;
      _store.transaction(
        () {
          _store.setDefaultPreset(presetId);
          working = _preparePresetWorkingReset();
        },
        onCommitted: () {
          _adoptPresetWorking(working);
        },
      );
    }),
  );

  @override
  Future<void> bindPreset(String chatId, String? presetId) => _operation(
    () => _presetOperation(() async {
      if (presetId != null) _requirePreset(presetId);
      final chat = _store.chat(chatId);
      if (chat.presetId == presetId && !chat.settings.containsKey('preset')) {
        _adoptPresetWorking(_preparePresetWorkingReset(chatId: chatId));
        _notifyPresetWorking();
        return;
      }
      late _PresetWorkingMutation working;
      await _withMutation(
        chatId,
        () => _store.transaction(
          () {
            final settings = _store.chat(chatId).settings;
            settings.remove('preset');
            _store.updateChat(chatId, settings: settings);
            _store.bindPreset(chatId, presetId);
            working = _preparePresetWorkingReset(chatId: chatId);
          },
          onCommitted: () {
            _adoptPresetWorking(working);
          },
        ),
      );
    }),
  );

  @override
  Future<void> deletePreset(String presetId) => _operation(
    () => _presetOperation(() async {
      _deletingPresets.add(presetId);
      try {
        final affected = <String>{};
        for (final summary in _store.listChats()) {
          final chat = _store.chat(summary.id);
          if (chat.presetId == presetId ||
              _resolvePreset(chat).selection.effectivePresetId == presetId ||
              _turns[chat.id]?.presetId == presetId ||
              _groups.rounds[chat.id]?.presetId == presetId) {
            affected.add(chat.id);
          }
        }
        await _withMutations(affected, () {
          _store.deletePreset(presetId);
        });
      } finally {
        _deletingPresets.remove(presetId);
      }
    }),
  );

  @override
  void configure(TavernModelConfig config) {
    _ensureOpen();
    _config = config;
    _authoringConfigVersion = Object();
  }

  /// Settings are JSON data. Per-chat documents overlay global settings.
  /// Unknown fields survive updates and reopening. Model credentials are never
  /// read from this document; use [configure] and its key callback.
  Map<String, Object?> settings({String? chatId}) {
    _ensureOpen();
    return _effectiveSettings(chatId == null ? null : _store.chat(chatId));
  }

  @override
  Future<Map<String, Object?>> readSettings({String? chatId}) => _operation(() => settings(chatId: chatId));

  Map<String, Object?> variables(String chatId) {
    _ensureOpen();
    return _runtimeCopy(_liveVariables[chatId]?.values ?? _store.chat(chatId).variables);
  }

  Map<String, Object?> get globalVariables {
    _ensureOpen();
    return _runtimeCopy(_globalVariables);
  }

  @override
  Future<void> setSettings(Map<String, Object?> patch, {String? chatId}) => _operation(() {
    final captured = _copy(patch);
    return _presetOperation(() => _setSettingsCaptured(captured, chatId: chatId));
  });

  Future<void> setPreset(ChatPreset preset, {String? chatId}) => _operation(() {
    final captured = preset.raw;
    return _presetOperation(() => _setSettingsCaptured({'preset': captured}, chatId: chatId, replacePreset: true));
  });

  Map<String, Object?> _mergeSettingsPatch(
    Map<String, Object?> previous,
    Map<String, Object?> patch, {
    String? scopePresetId,
    bool replacePreset = false,
  }) {
    final result = _merge(previous, patch);
    if (!patch.containsKey('preset')) return result;
    final value = patch['preset'];
    if (value is Map<String, Object?> && !replacePreset) {
      // An inherited global/default record is never the chat scope's base.
      final selected = scopePresetId == null ? null : _store.preset(scopePresetId);
      final raw = _merge(selected?.raw ?? _map(previous['preset']), value);
      if (selected?.envelope != null) _guardPresetCarrier(selected!.raw, raw);
      result['preset'] = raw;
    } else {
      result['preset'] = value;
    }
    return result;
  }

  void _selectLegacyPreset(Object? value, {String? chatId, Map<String, Object?>? envelope, String? inheritedName}) {
    String? id;
    if (value is Map<String, Object?>) {
      final suppliedName = value['name'];
      final name =
          inheritedName ??
          (suppliedName is String && suppliedName.trim().isNotEmpty
              ? suppliedName
              : (chatId == null ? '默认预设' : '对话预设'));
      if (envelope != null) envelope['preset'] = {..._map(envelope['preset']), 'data': _copy(value)};
      id = _store.createPreset(name: name, sourceText: jsonEncode(value), raw: value, envelope: envelope).id;
    }
    if (chatId == null) {
      _store.setDefaultPreset(id);
    } else {
      _store.bindPreset(chatId, id);
    }
  }

  Future<void> _setSettingsCaptured(Map<String, Object?> patch, {String? chatId, bool replacePreset = false}) async {
    if (chatId != null && patch.containsKey('spresetLogUploadEnabled')) {
      throw ArgumentError('spresetLogUploadEnabled is an App global setting; chat-level writes are not allowed.');
    }
    try {
      if (chatId == null) {
        final hasPreset = patch.containsKey('preset');
        _globalPresetUpdate = hasPreset;
        try {
          final selectedId = _store.defaultPresetId;
          final inherited = !replacePreset && patch['preset'] is Map<String, Object?> && selectedId != null
              ? _store.preset(selectedId)
              : null;
          final settings = _mergeSettingsPatch(
            _map(_document['settings']),
            patch,
            scopePresetId: selectedId,
            replacePreset: replacePreset,
          );
          // This legacy mixed API has no transaction spanning a file and SQL.
          // Keep its established in-memory/file behavior, then commit selection.
          _document['settings'] = settings;
          _adoptPresetWorking(_preparePresetSettingsAdoption(patch));
          _notifyPresetWorking();
          await _saveDocument(writeGlobals: false);
          if (hasPreset) {
            late _PresetWorkingMutation working;
            _store.transaction(
              () {
                _selectLegacyPreset(settings['preset'], envelope: inherited?.envelope, inheritedName: inherited?.name);
                working = _preparePresetWorkingReset();
              },
              onCommitted: () {
                _adoptPresetWorking(working);
              },
            );
          }
        } finally {
          _globalPresetUpdate = false;
        }
      } else {
        late _PresetWorkingMutation working;
        await _withMutation(
          chatId,
          () => _store.transaction(
            () {
              final chat = _store.chat(chatId);
              final inherited = !replacePreset && patch['preset'] is Map<String, Object?> && chat.presetId != null
                  ? _store.preset(chat.presetId!)
                  : null;
              final settings = _mergeSettingsPatch(
                chat.settings,
                patch,
                scopePresetId: chat.presetId,
                replacePreset: replacePreset,
              );
              _store.updateChat(chatId, settings: settings);
              if (patch.containsKey('preset')) {
                _selectLegacyPreset(
                  settings['preset'],
                  chatId: chatId,
                  envelope: inherited?.envelope,
                  inheritedName: inherited?.name,
                );
                working = _preparePresetWorkingReset(chatId: chatId);
              } else {
                working = _preparePresetSettingsAdoption(patch, chatId: chatId);
              }
            },
            onCommitted: () {
              _adoptPresetWorking(working);
            },
          ),
        );
      }
    } catch (error, stack) {
      // Global legacy settings can already be effective in memory even when
      // their file or subsequent preset SQL fails. Honor that actual switch,
      // while preserving the caller's original storage failure.
      try {
        await _directors.settingsChanged(chatId);
      } catch (_) {
        // A second cleanup failure must not replace the original exception.
      }
      Error.throwWithStackTrace(error, stack);
    }
    await _directors.settingsChanged(chatId);
  }

  Future<void> setGlobalVariables(Map<String, Object?> variables) => _operation(() {
    final captured = _copy(variables);
    final through = _globalVariables.revision;
    return _settingsDocument((document) async {
      final next = _copy(document)..['globalVariables'] = captured;
      await _commitSettingsDocument(next, globals: (runtime: captured, through: through));
    });
  });

  /// Reads the most recent real request. This has no variable/random effects.
  TavernInspection? inspect(String chatId) {
    _ensureOpen();
    return _inspections[chatId];
  }

  @override
  Future<TavernTurnInspection?> inspectTurn(String chatId, {String? nodeId}) => _operation(() {
    StoredChat chat;
    try {
      chat = _store.chat(chatId);
    } on StateError {
      return null;
    }
    if (nodeId != null) {
      final active = _turns[chatId]?.inspection;
      if (active != null && active.nodeId == nodeId && _inspectionAnchorExists(active)) return active;
      return _nodeInspection(chatId, nodeId);
    }
    if (_latestInspections.containsKey(chatId)) {
      final value = _latestInspections[chatId];
      if (value != null && !_inspectionAnchorExists(value)) _latestInspections[chatId] = null;
      return _latestInspections[chatId];
    }
    final value = _storedLatestInspection(chat);
    return value != null && _inspectionAnchorExists(value) ? value : null;
  });

  @override
  Future<TavernDisplayResult> displayText(
    String chatId, {
    String? nodeId,
    String? text,
    TavernRole? role,
    String? speaker,
    num? depth,
    bool reasoning = false,
  }) => _operation(() {
    final profile = _TurnProfile.start();
    try {
      final view = _displayView(chatId);
      if (nodeId == null && text == null) throw ArgumentError('Supply a stored node or original text.');
      if (depth != null && (!depth.isFinite || depth < 0)) throw ArgumentError.value(depth, 'depth');
      final node = nodeId == null ? null : view.node(_store, nodeId);
      final raw = text ?? (reasoning ? node!.message.reasoning ?? '' : node!.message.text);
      final displayRole = role ?? node?.message.role ?? TavernRole.character;
      final displaySpeaker =
          speaker ?? node?.message.speaker ?? (displayRole == TavernRole.system ? 'SillyTavern System' : null);
      final key = (chatId, nodeId, reasoning);
      final queue = _displayQueues.putIfAbsent(key, _DisplayQueue.new);
      final job = _DisplayJob(
        ++queue.version,
        chatId,
        nodeId,
        raw,
        displayRole,
        depth,
        reasoning,
        displaySpeaker,
        (role == TavernRole.system || (node != null && (node.message.hidden || _systemMessage(node)))) &&
            displaySpeaker == 'SillyTavern System',
        profile,
      );
      profile?.mark('read_view');
      // Advance before replacing pending work, so an already active job also
      // becomes stale at its next rule/await boundary.
      final previous = queue.pending;
      if (previous != null) {
        previous.profile?.mark('queued');
        previous.profile?.finish('display');
        previous.result.complete(TavernDisplayResult(text: previous.text, superseded: true));
      }
      queue.pending = job;
      if (!queue.running) unawaited(_drainDisplay(key, queue));
      return job.result.future;
    } catch (_) {
      profile?.finish('display');
      rethrow;
    }
  });

  _DisplayChatView _displayView(String chatId) {
    final version = _store.displayVersion(chatId);
    final previous = _displayChats.remove(chatId);
    final view = previous != null && identical(previous.version, version)
        ? previous
        : _DisplayChatView(version, _store.chat(chatId));
    _displayChats[chatId] = view;
    if (_displayChats.length > 8) _displayChats.remove(_displayChats.keys.first);
    return view;
  }

  _DisplayContext _displayContext(_DisplayChatView view, String? leaf) => view.contexts.putIfAbsent(leaf, () {
    final chat = view.chat;
    final node = leaf == null ? null : view.node(_store, leaf);
    final override = node == null ? null : _map(node.extra['dshgo'])['tavernState'];
    final state = node == null
        ? _store.groupInitialState(chat.id)
        : override is Map<String, Object?>
        ? _copy(override)
        : _store.nodeState(chat.id, leaf!);
    if (node != null && !state.containsKey('stChatIdHash')) _withStateHash(chat, state);
    final metadata = leaf == null
        ? {..._copy(chat.metadata), 'variables': _copy(chat.variables)}
        : _chatCodec.metadataForState(chat, state);
    return _DisplayContext(
      state,
      metadata,
      _store.displayHistory(chat.id, leaf),
      _macroChatIdentity(chat, state, metadata, state['chatJsonlSourceFile'] as String?, node: node),
    );
  });

  Future<void> _drainDisplay((String, String?, bool) key, _DisplayQueue queue) async {
    queue.running = true;
    try {
      while (queue.pending != null) {
        final job = queue.pending!;
        queue.pending = null;
        job.profile?.mark('queued');
        bool current() => !_closing && !_closed && queue.version == job.version;
        try {
          final result = current()
              ? await _display(job, current)
              : TavernDisplayResult(text: job.text, superseded: true);
          job.result.complete(
            TavernDisplayResult(
              text: result.text,
              warnings: result.warnings,
              replacements: result.replacements,
              superseded: result.superseded || !current(),
            ),
          );
        } catch (error, stack) {
          if (current()) {
            job.result.completeError(error, stack);
          } else {
            job.result.complete(TavernDisplayResult(text: job.text, superseded: true));
          }
        } finally {
          job.profile?.finish('display');
        }
      }
    } finally {
      queue.running = false;
      if (identical(_displayQueues[key], queue)) _displayQueues.remove(key);
    }
  }

  Future<TavernDisplayResult> _display(_DisplayJob job, bool Function() current) async {
    // Fixed ST messageFormatting first reclassifies hidden/comment messages
    // as displayable; only is_system with its actual system speaker bypasses.
    if (job.isSystem) return TavernDisplayResult(text: job.text);
    final view = _displayView(job.chatId);
    final chat = view.chat;
    final displayNode = job.nodeId == null ? null : view.node(_store, job.nodeId!);
    final position = displayNode == null
        ? (onCurrentPath: true, depth: null)
        : view.positions.putIfAbsent(
            job.nodeId!,
            () => _store.displayPosition(chat.id, displayNode, chat.currentLeafId),
          );
    final onCurrentPath = position.onCurrentPath;
    final leaf = onCurrentPath ? chat.currentLeafId : job.nodeId;
    final context = _displayContext(view, leaf);
    final state = context.state;
    final messageState = job.nodeId == null ? state : _displayContext(view, job.nodeId).state;
    final metadata = context.metadata;
    final live = _liveVariables[job.chatId];
    final active = _turns[job.chatId];
    final activeVariables = onCurrentPath && active?.environment != null ? active!.variables : null;
    final local = _runtimeCopy(
      activeVariables ??
          (onCurrentPath && live != null && live.leaf == leaf
              ? live.values
              : leaf == null
              ? chat.variables
              : _map(state['variables'])),
    );
    final global = _runtimeCopy(_globalVariables);
    final settings = _personaSettings(
      _effectiveReadSettings(chat, metadata),
      _personas.resolve(personaId: chat.personaId),
    );
    final config = _config;
    final now = _clock();
    job.profile?.mark('context');
    final group = _store.groupChat(chat.id);
    final actorId = group != null && displayNode?.message.role == TavernRole.character
        ? displayNode!.message.speakerCharacterId
        : active?.actorId ?? chat.characterId;
    final gameplayCapture = _captureGameplayResources(
      this,
      characterId: actorId,
      chatId: job.chatId,
      kinds: const {'regex'},
      deferResourceErrors: true,
    );
    final record = actorId == null ? null : await _record(actorId);
    final groupNames = group == null ? null : await _groups.captureNames(group);
    job.profile?.mark('resources');
    if (!current()) return TavernDisplayResult(text: job.text, superseded: true);
    if (record == null && group == null) throw const TavernImportError('角色不存在。');
    if (!_gameplayResourcesCurrent(this, gameplayCapture)) {
      return TavernDisplayResult(text: job.text, superseded: true);
    }
    final data = record?.card.data ?? <String, Object?>{'name': displayNode?.message.speaker ?? ''};
    final contextTarget = job.nodeId ?? active?.reply?.nodeId;
    final random = Random(_displaySeed('${job.chatId}\u0000${job.nodeId ?? ''}\u0000${job.reasoning}'));
    final environment = _MacroEnvironment(
      _effectiveCard(data, settings),
      settings,
      local,
      global,
      const [],
      config,
      now,
      random.nextDouble,
      context.chatIdentity,
      '',
      active?.generationType ?? 'normal',
      chatIdHash: _finiteNumber(metadata['chat_id_hash']),
      pickRerollSeed: metadata['pick_reroll_seed'],
      characterId: actorId ?? '',
      groupNames: groupNames?.names,
      groupNotMuted: groupNames?.enabledNames,
      messageVariables: messageState['messageVariables'],
      messageVariablesExists: messageState.containsKey('messageVariables'),
      macroHistorySnapshot: context.historySnapshot(
        overlayNodeId: job.reasoning ? null : contextTarget,
        text: job.text,
      ),
      packRegex: _resolveGameplayResources(gameplayCapture, settings, actorId: actorId, kinds: const {'regex'}).regex,
    );
    final placement = job.reasoning
        ? RegexPlacement.reasoning
        : switch (job.role) {
            TavernRole.user => RegexPlacement.userInput,
            TavernRole.narrator => RegexPlacement.slashCommand,
            _ => RegexPlacement.aiOutput,
          };
    var resourceConflict = false;
    ({Object error, StackTrace stackTrace})? resourceFailure;
    (int, int)? resourceStamp;
    bool cancelled() {
      if (!current()) {
        return true;
      }
      if (resourceConflict || resourceFailure != null) {
        return true;
      }
      // Rule-level display catches must not swallow an actual store error.
      // Keep the original worker Future owned until it has really drained.
      final checkStarted = job.profile?.now;
      try {
        // Read the stamp before the facts: a concurrent commit may cause an
        // extra miss, but cannot label an older result with a newer stamp.
        final stamp = _store.readGameplayBindingStamp();
        if (stamp != null && stamp == resourceStamp) return false;
        final factsStarted = job.profile?.now;
        try {
          resourceConflict = !_gameplayResourcesCurrent(this, gameplayCapture);
          if (!resourceConflict && stamp != null) resourceStamp = stamp;
        } finally {
          job.profile?.record('display_current_facts', factsStarted!);
        }
      } catch (error, stackTrace) {
        resourceFailure = (error: error, stackTrace: stackTrace);
      } finally {
        job.profile?.record('display_current_check', checkStarted!);
      }
      return resourceConflict || resourceFailure != null;
    }

    final regex = environment.regex;
    job.profile?.mark('regex_setup');
    try {
      final rendered = await regex.applyDisplay(
        job.text,
        placement: placement,
        worker: _regexWorker,
        depth: job.depth ?? position.depth,
        characterOverride: job.characterOverride ?? (job.role == TavernRole.user ? environment.userName : null),
        expand: environment.regexExpand,
        isCancelled: cancelled,
      );
      cancelled();
      final failure = resourceFailure;
      if (failure != null) {
        Error.throwWithStackTrace(failure.error, failure.stackTrace);
      }
      return TavernDisplayResult(
        text: rendered.text,
        warnings: [
          ...rendered.warnings,
          if (group != null && record == null)
            const RegexDisplayWarning(
              ruleId: '',
              ruleName: '',
              ruleIndex: -1,
              reason: 'group_speaker_unavailable',
              message: 'The historical speaker card is unavailable; card regex was omitted.',
            ),
        ],
        replacements: rendered.replacements,
        superseded: rendered.cancelled || resourceConflict || !current(),
      );
    } finally {
      job.profile?.mark('regex');
    }
  }

  StoredNode? _inspectionNode(String chatId, String nodeId) {
    try {
      return _store.node(chatId, nodeId);
    } on StateError {
      return null;
    }
  }

  TavernTurnInspection? _nodeInspection(String chatId, String nodeId) {
    final node = _inspectionNode(chatId, nodeId);
    final json = node == null ? null : _map(node.extra['dshgo'])['inspection'];
    if (json is! Map<String, Object?>) return null;
    final value = TavernTurnInspection.fromJson(json);
    return value.chatId == chatId && value.nodeId == nodeId ? value : null;
  }

  TavernTurnInspection? _storedLatestInspection(StoredChat chat) {
    final latest = _map(_map(chat.metadata['dshgo'])['latestInspection']);
    final nodeId = latest['nodeId'];
    if (nodeId is String) return _nodeInspection(chat.id, nodeId);
    final json = latest['snapshot'];
    if (json is! Map<String, Object?>) return null;
    final value = TavernTurnInspection.fromJson(json);
    return value.chatId == chat.id && value.nodeId == null ? value : null;
  }

  bool _inspectionAnchorExists(TavernTurnInspection value) {
    final anchor = value.nodeId ?? value.contextNodeId;
    return anchor == null || _inspectionNode(value.chatId, anchor) != null;
  }

  void _setInspection(_Turn turn, TavernTurnInspection value) {
    final captured = _gameplayInspection(value, turn.gameplay);
    turn.inspection = captured;
    _latestInspections[turn.chat.id] = captured;
  }

  Map<String, Object?> _inspectionExtra(Map<String, Object?> extra, TavernTurnInspection value) => {
    ...extra,
    'dshgo': {..._map(extra['dshgo']), 'inspection': value.toJson()},
  };

  Map<String, Object?> _latestInspectionMetadata(Map<String, Object?> metadata, TavernTurnInspection? value) {
    final own = _map(metadata['dshgo']);
    if (value == null) {
      own.remove('latestInspection');
    } else {
      own['latestInspection'] = value.nodeId == null ? {'snapshot': value.toJson()} : {'nodeId': value.nodeId};
    }
    return {...metadata, 'dshgo': own};
  }

  void _writeLatestInspection(String chatId, TavernTurnInspection? value) {
    _store.updateChat(chatId, metadata: _latestInspectionMetadata(_store.chat(chatId).metadata, value));
  }

  // The caller owns the transaction, so node evidence and the latest pointer
  // become visible together. Always merge with the current stored JSON.
  void _writeInspection(TavernTurnInspection value) {
    final nodeId = value.nodeId;
    if (nodeId != null) {
      final node = _store.node(value.chatId, nodeId);
      _store.updateMessage(value.chatId, nodeId, extra: _inspectionExtra(node.extra, value));
    }
    _writeLatestInspection(value.chatId, value);
  }

  void _captureAssembly(_Turn turn, PromptAssembly assembly) {
    final started = turn.profile?.now;
    try {
      _setInspection(turn, turn.inspection.copyWith(prompt: assembly, status: TavernInspectionStatus.ready));
    } on FormatException {
      // An internal recording error is not a malformed character card.
      throw StateError('Invalid assembled inspection data.');
    } finally {
      turn.profile?.record('inspection_capture', started!);
    }
  }

  @override
  Future<TavernImportReport?> readImportReport(TavernImportKind kind, String assetId) => _operation(() async {
    switch (kind) {
      case TavernImportKind.character:
        return _libraryOperation(() => _library.readImportReport(assetId));
      case TavernImportKind.preset:
        return _presetOperation(() {
          final record = _store.preset(assetId);
          if (record == null) return null;
          return _currentImportReport(kind, record.importReport, record.raw, envelope: record.envelope);
        });
      case TavernImportKind.lorebook:
        return _bookOperation(() async {
          final raw = await _readBookNow(assetId);
          if (raw == null) return null;
          return _currentImportReport(kind, _bookImportReports[assetId], raw);
        });
      case TavernImportKind.regex:
        return _regexLibrary.readImportReport(assetId);
    }
  });

  @override
  Future<TavernImportReport> recheckImport(TavernImportKind kind, String assetId) => _operation(() async {
    switch (kind) {
      case TavernImportKind.character:
        return _libraryOperation(() => _library.recheckImport(assetId, _inspectCardReport));
      case TavernImportKind.preset:
        return _presetOperation(() async {
          final record = _requirePreset(assetId);
          final raw = record.raw;
          final envelope = record.envelope;
          List<TavernPresetIssue> issues;
          try {
            issues = _presetCodec.validate(raw, envelope: envelope).issues;
          } on TavernPresetImportError catch (error) {
            // Legacy permissive settings can contain values rejected by the
            // modern importer. Inspection must not normalize their live data.
            issues = error.issues;
          }
          final diagnostics = await inspectRegexScripts(_map(raw['extensions'])['regex_scripts'], _regexWorker);
          final report = await assessImportAsync(
            kind: kind,
            document: raw,
            envelope: envelope,
            regexDiagnostics: diagnostics,
            presetIssues: issues,
            checkedAt: _clock().toUtc(),
          );
          _store.savePresetImportReport(assetId, report);
          return report;
        });
      case TavernImportKind.lorebook:
        return _bookOperation(() async {
          _authoringAuthority.checkWritable('lorebook:$assetId');
          final raw = await _readBookNow(assetId);
          if (raw == null) throw const TavernImportError('世界书不存在。');
          final book = WorldInfoBook.fromJson(id: assetId, source: WorldInfoSource.global, json: raw);
          final diagnostics = await _checkWorldBookRegex(book);
          final report = await assessImportAsync(
            kind: kind,
            document: raw,
            regexDiagnostics: diagnostics,
            checkedAt: _clock().toUtc(),
          );
          await _writeBookNow(assetId, raw, importReport: report);
          return report;
        });
      case TavernImportKind.regex:
        return _regexLibrary.recheckImport(assetId);
    }
  });

  Future<TavernImportReport> _inspectCardReport(TavernCard card) async {
    final diagnostics = await _checkCardRegex(card.data);
    return assessImportAsync(
      kind: TavernImportKind.character,
      document: card.json,
      embeddedAssetPaths: card.assets.keys,
      regexDiagnostics: diagnostics,
      checkedAt: _clock().toUtc(),
    );
  }

  TavernImportReport? _currentImportReport(
    TavernImportKind kind,
    TavernImportReport? report,
    Map<String, Object?> raw, {
    Map<String, Object?>? envelope,
  }) {
    if (report == null) return null;
    if (report.kind != kind) throw const FormatException('Import report does not match its asset kind.');
    return report.withStale(report.fingerprint != importFingerprint(kind, raw, envelope: envelope));
  }

  @override
  Future<List<TavernScriptLibraryEntry>> listGlobalScripts() => _operation(() => _globalScriptViews(_document));
  @override
  Stream<List<TavernScriptLibraryEntry>> watchGlobalScripts() {
    _ensureOpen();
    return _watch(_globalScriptsChanged.stream, () => _globalScriptViews(_document));
  }

  @override
  Future<List<TavernScriptLibraryEntry>> importGlobalScripts(String text) =>
      _operation(() => _importGlobalScripts(text));
  @override
  Future<TavernScriptLibraryEntry> setGlobalScriptEnabled(String id, bool enabled) =>
      _operation(() => _setGlobalScriptEnabled(id, enabled));
  @override
  Future<void> setGlobalScriptOrder(List<String> ids, {String? folderId}) =>
      _operation(() => _setGlobalScriptOrder(ids, folderId));
  @override
  Future<void> deleteGlobalScript(String id) => _operation(() => _deleteGlobalScript(id));
  @override
  Future<String> exportGlobalScripts({String? id}) =>
      _operation(() => const JsonEncoder.withIndent('  ').convert(_globalScriptExportRaw(_document, id)));
  @override
  Future<TavernChatScripts> chatScripts(String chatId, {String? characterId}) =>
      _operation(() => _readChatScripts(chatId, characterId: characterId));
  @override
  Stream<TavernChatScripts> watchChatScripts(String chatId, {String? characterId}) {
    _ensureOpen();
    return _watch(_scriptCatalogChanged.stream, () => _readChatScripts(chatId, characterId: characterId));
  }

  @override
  Future<List<TavernRegexScript>> listRegexScripts() => _operation(() => _regexLibrary.scripts);
  @override
  Future<TavernRegexImportResult> importRegexScripts(String text) =>
      _operation(() => _regexLibrary.importScripts(text));
  @override
  Future<TavernRegexScript> updateRegexScript(String regexId, Map<String, Object?> patch) =>
      _operation(() => _regexLibrary.updateScript(regexId, patch));
  @override
  Future<TavernRegexScript> setRegexEnabled(String regexId, bool enabled) =>
      _operation(() => _regexLibrary.setEnabled(regexId, enabled));
  @override
  Future<void> deleteRegex(String regexId) => _operation(() => _regexLibrary.delete(regexId));
  @override
  Future<String> exportRegex({String? regexId}) => _operation(() => _regexLibrary.exportScripts(id: regexId));

  Future<List<TavernRegexDiagnostic>> _checkCardRegex(Map<String, Object?> data) async {
    final result = [
      ...await inspectRegexScripts(
        _map(data['extensions'])['regex_scripts'],
        _regexWorker,
        path: r'$.data.extensions.regex_scripts',
      ),
    ];
    final embedded = data['character_book'];
    if (embedded is Map<String, Object?>) {
      try {
        final book = WorldInfoBook.fromJson(id: 'card', source: WorldInfoSource.character, json: embedded);
        result.addAll(await _checkWorldBookRegex(book, path: r'$.data.character_book'));
      } on FormatException {
        result.add(
          const TavernRegexDiagnostic(
            path: r'$.data.character_book',
            status: TavernRegexCompatibility.skipped,
            code: 'invalid-world-book',
            message: '内嵌世界书结构无法解析，原始数据保留；无法完成关键词试编译。',
          ),
        );
      }
    }
    return List.unmodifiable(result);
  }

  Future<List<TavernRegexDiagnostic>> _checkWorldBookRegex(WorldInfoBook book, {String path = r'$'}) async {
    final result = <TavernRegexDiagnostic>[];
    for (final input in worldInfoRegexInputs(book)) {
      final checked = input.isDynamic
          ? const RegexCompileResult(
              status: RegexCompileStatus.skipped,
              code: 'runtime-check',
              message: '关键词依赖运行时宏，导入不展开；实际使用时再受控检查。',
            )
          : await _keywordWorker.compile(input.pattern, dialect: input.dialect, caseSensitive: input.caseSensitive);
      result.add(
        regexCompileDiagnostic(
          checked,
          path: '$path.${input.path}',
          identifier: input.uid,
          line: input.line,
          decorator: input.decorator,
          keyIndex: input.keyIndex,
          conditional: input.conditional,
          fallback: input.isFallback,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  Future<T> _bookOperation<T>(FutureOr<T> Function() action) {
    final result = _bookQueue.then((_) => action());
    _bookQueue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<List<TavernLorebookSummary>> listLorebooks() => _operation(
    () => _bookOperation(() async {
      final folder = Directory('${directory.path}/lorebooks');
      if (!await folder.exists()) return <TavernLorebookSummary>[];
      final result = <TavernLorebookSummary>[];
      await for (final entry in folder.list(followLinks: false)) {
        if (entry is! File || !entry.path.endsWith('.json')) continue;
        final name = entry.uri.pathSegments.last;
        final id = name.substring(0, name.length - 5);
        final raw = await _readBookNow(id);
        if (raw == null) continue;
        final book = WorldInfoBook.fromJson(id: id, source: WorldInfoSource.global, json: raw);
        result.add(
          TavernLorebookSummary(
            id: id,
            name: book.name,
            entryCount: book.entries.length,
            stWorldName: _bookSourceNames[id],
          ),
        );
      }
      result.sort((a, b) {
        final name = a.name.compareTo(b.name);
        return name != 0 ? name : a.id.compareTo(b.id);
      });
      return List<TavernLorebookSummary>.unmodifiable(result);
    }),
  );

  @override
  Future<TavernLorebookImportResult> importLorebook(String text, {String? fileName}) => _operation(() async {
    final WorldInfoBook parsed;
    final suppliedName = fileName
        ?.replaceAll('\\', '/')
        .split('/')
        .last
        .replaceFirst(RegExp(r'\.json$', caseSensitive: false), '');
    final sourceName = suppliedName == null || suppliedName.isEmpty ? null : suppliedName;
    try {
      final raw = _decodeObject(text.startsWith('\uFEFF') ? text.substring(1) : text, 'Lorebook');
      if (!raw.containsKey('name') && sourceName != null) {
        raw['name'] = sourceName;
      }
      parsed = WorldInfoBook.fromJson(id: 'import', source: WorldInfoSource.global, json: raw);
    } on FormatException {
      throw const TavernImportError('世界书JSON格式无效。');
    } on JsonUnsupportedObjectError {
      throw const TavernImportError('世界书只能包含合法JSON数值。');
    }
    final diagnostics = await _checkWorldBookRegex(parsed);
    final report = await assessImportAsync(
      kind: TavernImportKind.lorebook,
      document: parsed.raw,
      regexDiagnostics: diagnostics,
      checkedAt: _clock().toUtc(),
    );
    return _bookOperation(() async {
      final random = Random.secure();
      String id;
      do {
        id = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      } while (await FileSystemEntity.type('${directory.path}/lorebooks/$id.json', followLinks: false) !=
          FileSystemEntityType.notFound);
      await _writeBookNow(id, parsed.raw, stWorldName: sourceName, importReport: report);
      final book = WorldInfoBook.fromJson(id: id, source: WorldInfoSource.global, json: parsed.raw);
      return TavernLorebookImportResult(
        TavernLorebook(
          id: id,
          name: book.name,
          entryCount: book.entries.length,
          stWorldName: sourceName,
          raw: book.raw,
        ),
        diagnostics,
      );
    });
  });

  @override
  Future<void> putLorebook(String id, Map<String, Object?> json) => _operation(() {
    _requireBookId(id);
    final book = WorldInfoBook.fromJson(id: id, source: WorldInfoSource.global, json: json);
    return _bookOperation(() async {
      _authoringAuthority.checkWritable('lorebook:$id');
      await _readBookNow(id);
      await _writeBookNow(id, book.raw);
    });
  });

  Future<TavernAuthoringReceipt> _writeBookNow(
    String id,
    Map<String, Object?>? raw, {
    String? stWorldName,
    TavernImportReport? importReport,
    Map<String, Object?>? preservedEnvelope,
    void Function()? check,
    void Function()? onStarted,
    void Function()? onRenamed,
    String? exactText,
    AuthoringWriteRequest? request,
    AuthoringExpectation? expected,
    bool requireMissing = false,
  }) {
    final result = _fileQueue.then((_) async {
      final owner = _authoringAuthority;
      if (request != null) {
        final replayed = owner.replay(request);
        if (replayed != null) return replayed;
      }
      owner.checkWritable('lorebook:$id');
      final Map<String, Object?> document;
      final Map<String, Object?> actualRaw;
      final String? sourceName;
      final TavernImportReport? report;
      if (exactText != null) {
        try {
          document = _decodeObject(decodeAuthoringText(utf8.encode(exactText)).text, 'Lorebook');
          actualRaw = _authoringBook(document);
          WorldInfoBook.fromJson(id: id, source: WorldInfoSource.global, json: actualRaw);
          final enveloped = !document.containsKey('entries') && document['format'] == 'dshgo-lorebook';
          sourceName = enveloped ? document['stWorldName'] as String? : null;
          report = enveloped && document['importReport'] != null
              ? TavernImportReport.fromJson(document['importReport']! as Map<String, Object?>)
              : null;
        } on FormatException {
          throw TavernAuthoringException(
            'invalid_change',
            'The candidate lorebook envelope is invalid.',
            physicalResourceId: 'lorebook:$id',
          );
        } on TavernImportError {
          throw TavernAuthoringException(
            'invalid_change',
            'The candidate lorebook envelope is invalid.',
            physicalResourceId: 'lorebook:$id',
          );
        } on TypeError {
          throw TavernAuthoringException(
            'invalid_change',
            'The candidate lorebook envelope is invalid.',
            physicalResourceId: 'lorebook:$id',
          );
        } on ArgumentError {
          throw TavernAuthoringException(
            'invalid_change',
            'The candidate lorebook envelope is invalid.',
            physicalResourceId: 'lorebook:$id',
          );
        }
      } else {
        actualRaw = raw!;
        sourceName = stWorldName ?? _bookSourceNames[id];
        report = importReport ?? _bookImportReports[id];
        // Final envelope selection happens at the real file queue position.
        document = sourceName == null && report == null && preservedEnvelope == null
            ? actualRaw
            : {
                ...?preservedEnvelope,
                'format': 'dshgo-lorebook',
                'version': 1,
                'stWorldName': ?sourceName,
                if (report != null) 'importReport': report.toJson(),
                'book': actualRaw,
              };
      }
      final text = exactText ?? jsonEncode(document);
      final file = File('${directory.path}/lorebooks/$id.json');
      final before = await _readBookResource(file);
      if (requireMissing && before.present) {
        _authoringAuthorityConflict('lorebook:$id');
      }
      final after = AuthoringResourceSnapshot(present: true, rawText: text);
      final ticket = AuthoringWriteTicket(
        request: request ?? owner.newRequest('lorebook:$id', {'method': 'writeLorebook', 'after': after.toJson()}),
        before: before,
        after: after,
      );
      try {
        if (expected != null && before.sameAs(after)) {
          return owner.notAdopted(ticket, noChange: true, expected: expected, check: check);
        }
        final replayed = owner.prepare(ticket, expected: expected, check: check);
        if (replayed != null) return replayed;
        onStarted?.call();
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.writing');
        await temporary.writeAsString(text, flush: true);
        if (request == null) check?.call();
        ticket.enteredEffect = true;
        await temporary.rename(file.path);
        ticket.knownAdopted = true;
        try {
          _adoptBookCache(id, actualRaw, sourceName, report);
        } finally {
          onRenamed?.call();
        }
        // fail() preserves the return and completes this marker on callback errors.
        owner.adopted(ticket);
        return owner.publish(ticket);
      } catch (error, stack) {
        owner.fail(ticket, error, stack);
      }
    });
    _fileQueue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<TavernAuthoringReceipt> _writeAuthoringBook(
    String id,
    String rawText, {
    required AuthoringWriteRequest request,
    required AuthoringExpectation expected,
    void Function()? check,
  }) => _bookOperation(
    () => _writeBookNow(id, null, exactText: rawText, request: request, expected: expected, check: check),
  );

  Future<AuthoringResourceSnapshot> _readBookResource(File file) async {
    try {
      final text = await readAuthoringText(file);
      return AuthoringResourceSnapshot(present: true, rawText: text.rawText);
    } on PathNotFoundException catch (error) {
      final code = error.osError?.errorCode;
      if (code != 2 && (!Platform.isWindows || code != 3)) rethrow;
      return const AuthoringResourceSnapshot(present: false);
    }
  }

  void _adoptBookCache(String id, Map<String, Object?> raw, String? sourceName, TavernImportReport? report) {
    _bookRevisions.update(id, (revision) => revision + 1, ifAbsent: () => 1);
    _books[id] = _copy(raw);
    if (sourceName == null) {
      _bookSourceNames.remove(id);
    } else {
      _bookSourceNames[id] = sourceName;
    }
    if (report == null) {
      _bookImportReports.remove(id);
    } else {
      _bookImportReports[id] = report;
    }
    _scripts.scriptResourceBookCommitted(id, raw);
  }

  void _forgetBook(String id) {
    _bookRevisions.update(id, (revision) => revision + 1, ifAbsent: () => 1);
    _books.remove(id);
    _bookSourceNames.remove(id);
    _bookImportReports.remove(id);
    _scripts.scriptResourceBookCommitted(id, null);
  }

  @override
  Future<Map<String, Object?>?> lorebook(String id) => _operation(() async {
    _requireBookId(id);
    final value = await _readBook(id);
    return value == null ? null : _copy(value);
  });

  @override
  Future<String> exportLorebook(String id) => _operation(() async {
    final raw = await _readBook(id);
    if (raw == null) throw const TavernImportError('世界书不存在。');
    return jsonEncode(raw);
  });

  @override
  Future<void> deleteLorebook(String id) => _operation(() {
    _requireBookId(id);
    return _bookOperation(() => _deleteBookNow(id));
  });

  Future<void> _deleteBookNow(String id, {void Function()? check, void Function()? onDeleted}) async {
    check?.call();
    _authoringAuthority.checkWritable('lorebook:$id');
    final file = File('${directory.path}/lorebooks/$id.json');
    var remove = false;
    if (await file.exists()) {
      remove = true;
    } else {
      // exists can hide lookup errors. Preserve its link-following and
      // known non-file behavior, but do not acknowledge uncertain absence.
      final type = await FileSystemEntity.type(file.path, followLinks: true);
      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.pipe ||
          type == FileSystemEntityType.unixDomainSock) {
        remove = true;
      } else if (type == FileSystemEntityType.notFound) {
        // Linux delete can fold a lookup error into ENOENT. A read-only
        // open preserves that error without reading or creating the book.
        RandomAccessFile? probe;
        try {
          probe = await file.open(mode: FileMode.read);
        } on PathNotFoundException catch (error) {
          final code = error.osError?.errorCode;
          if (code != 2 && (!Platform.isWindows || code != 3)) {
            rethrow;
          }
        }
        if (probe != null) {
          // Neither close nor delete errors authorize the cache cleanup.
          await probe.close();
          remove = true;
        }
      }
    }
    final before = remove
        ? AuthoringResourceSnapshot(present: true, rawText: (await readAuthoringText(file)).rawText)
        : const AuthoringResourceSnapshot(present: false);
    final owner = _authoringAuthority;
    final ticket = AuthoringWriteTicket(
      request: owner.newRequest('lorebook:$id', {'method': 'deleteLorebook'}),
      before: before,
      after: const AuthoringResourceSnapshot(present: false),
    );
    try {
      if (!remove) {
        owner.notAdopted(ticket, noChange: true, check: check);
        _forgetBook(id);
        return;
      }
      if (owner.prepare(ticket, check: check) != null) {
        return;
      }
      ticket.enteredEffect = true;
      await file.delete();
      ticket.knownAdopted = true;
      try {
        _forgetBook(id);
      } finally {
        onDeleted?.call();
      }
      owner.adopted(ticket);
      owner.publish(ticket);
    } catch (error, stack) {
      owner.fail(ticket, error, stack);
    }
  }

  /// A global binding applies to all chats; a chat binding overrides that
  /// source's global list. Character-specific bindings may be set globally via
  /// settings.characterLorebooks[characterId]. Card-embedded books always join.
  @override
  Future<void> bindLorebooks(
    List<String> ids, {
    WorldInfoSource source = WorldInfoSource.global,
    String? chatId,
    String? characterId,
    String? personaId,
  }) {
    for (final id in ids) {
      _requireBookId(id);
    }
    final captured = List<String>.of(ids);
    if ([chatId, characterId, personaId].where((value) => value != null).length > 1 ||
        (characterId != null && source != WorldInfoSource.character) ||
        (personaId != null && source != WorldInfoSource.persona)) {
      throw ArgumentError('Select one matching chat, character or persona scope.');
    }
    if (characterId != null) {
      return _operation(
        () => _libraryOperation(
          () => _presetOperation(() async {
            if (_deletingCharacters.contains(characterId) || await _record(characterId) == null) {
              throw const TavernImportError('角色不存在或正在删除。');
            }
            await _setSettingsCaptured({
              'characterLorebooks': {characterId: captured},
            });
          }),
        ),
      );
    }
    if (personaId != null) {
      return _operation(
        () => _personaOperation(
          () => _presetOperation(() async {
            if (_deletingPersonas.contains(personaId) || _personas.get(personaId) == null) {
              throw const TavernImportError('人设不存在或正在删除。');
            }
            await _setSettingsCaptured({
              'personaLorebooks': {personaId: captured},
            });
          }),
        ),
      );
    }
    return setSettings({
      'lorebooks': {source.name: captured},
    }, chatId: chatId);
  }

  /// ST character filters use the avatar filename and independent tag-map ids,
  /// not a card's display name, library id, or descriptive tags. Importers/UI
  /// can supply that identity explicitly; absent tag-map data remains null.
  Future<void> setCharacterIdentity(String characterId, {required String avatarFilename, List<String>? tagIds}) =>
      setSettings({
        'characterIdentities': {
          characterId: {'avatarFilename': avatarFilename, 'tagIds': tagIds == null ? null : List<String>.of(tagIds)},
        },
      });

  Map<String, Object?> _effectiveSettings([StoredChat? chat, Map<String, Object?>? metadata]) =>
      _copy(_effectiveReadSettings(chat, metadata));

  // Internal read projection. Only merged containers are new; source payloads
  // stay owned by their revision, while the public settings() result is copied.
  Map<String, Object?> _effectiveReadSettings([StoredChat? chat, Map<String, Object?>? metadata]) {
    final global = _readMap(_document['settings']);
    var result = Map<String, Object?>.of(global);
    if (chat != null) {
      final source = metadata ?? _chatCodec.metadataForNode(_store, chat.id);
      result = _mergeReadMaps(
        result,
        _chatMetadataSettings(source, _map(chat.settings['stLorebookIds']), _map(result['authorNote'])),
      );
      result = _mergeReadMaps(result, chat.settings);
    }
    // A selected preset is one complete preset, not a field-by-field mixture
    // with whichever global preset happened to be selected previously.
    final selection = _resolvePreset(chat);
    if (selection.preset != null) {
      result['preset'] = selection.preset!.raw;
    } else if (chat != null && chat.settings.containsKey('preset')) {
      result['preset'] = _readMap(chat.settings['preset']);
    }
    if (_presetWorkingSlots.isNotEmpty ||
        _readMap(global['presetOverrides']).isNotEmpty ||
        _readMap(chat?.settings['presetOverrides']).isNotEmpty) {
      result = _applyPresetWorkingSettings(
        result,
        global: global,
        chat: chat,
        selectedSource: selection.selection.source,
        selectedPresetId: selection.selection.effectivePresetId,
        working: _presetWorkingSlots.isEmpty ? null : _currentPresetData(chat?.id, capturedChat: chat).working,
      );
    }
    // Project only after every global/source/chat merge. A read->set roundtrip
    // cannot duplicate the collection or replace it with a supplied snapshot.
    result.remove('managedRegexScripts');
    // Imported/legacy chat settings must not grant or revoke the App opt-in.
    if (global.containsKey('spresetLogUploadEnabled')) {
      result['spresetLogUploadEnabled'] = global['spresetLogUploadEnabled'];
    } else {
      result.remove('spresetLogUploadEnabled');
    }
    final managed = _managedRegexView ??= _regexLibrary.executionScripts;
    if (managed.isNotEmpty) result['managedRegexScripts'] = managed;
    return result;
  }

  Future<Map<String, Object?>?> _readBook(String id) => _bookOperation(() => _readBookNow(id));

  Future<({Map<String, Object?> raw, String? stWorldName})?> _readBookSnapshot(String id) => _bookOperation(() async {
    // Bound standalone books share the directory's admission rules. Keep raw
    // reads separate so an unreadable entries field can still be repaired.
    if (_scripts.scriptResources.directory.standalone[id]?.readable == false) return null;
    final raw = await _readBookNow(id);
    if (raw == null || _scripts._bookDirectoryEntriesFailure(raw) != null) return null;
    return (raw: raw, stWorldName: _bookSourceNames[id]);
  });

  Future<Map<String, Object?>?> _readBookNow(String id) async {
    _requireBookId(id);
    final cached = _books[id];
    if (cached != null) return cached;
    final revision = _bookRevisions[id] ?? 0;
    final file = File('${directory.path}/lorebooks/$id.json');
    if (!await file.exists()) return null;
    final document = _decodeObject(await file.readAsString(), 'Lorebook');
    Map<String, Object?> value = document;
    String? sourceName;
    TavernImportReport? report;
    if (!document.containsKey('entries') && document['format'] == 'dshgo-lorebook') {
      if (document['version'] != 1 ||
          document['book'] is! Map<String, Object?> ||
          (document['stWorldName'] != null && document['stWorldName'] is! String)) {
        throw const FormatException('Unsupported or invalid stored lorebook.');
      }
      value = document['book']! as Map<String, Object?>;
      sourceName = document['stWorldName'] as String?;
      if (document['importReport'] != null) {
        report = TavernImportReport.fromJson(document['importReport']! as Map<String, Object?>);
      }
    }
    if ((_bookRevisions[id] ?? 0) == revision) {
      _books[id] = value;
      if (report == null) {
        _bookImportReports.remove(id);
      } else {
        _bookImportReports[id] = report;
      }
      if (sourceName == null) {
        _bookSourceNames.remove(id);
      } else {
        _bookSourceNames[id] = sourceName;
      }
    }
    return value;
  }

  Future<void> _saveDocument({bool writeGlobals = true, void Function()? onGlobalsAdopted}) {
    final through = _globalVariables.revision;
    return _settingsDocument((document) async {
      if (!writeGlobals) {
        await _commitSettingsDocument(document);
        return;
      }
      // Claim only still-uncommitted native intent at this real queue position.
      // An earlier flush may already have saved the same prefix.
      if (!_globalVariables.hasThrough(through)) {
        onGlobalsAdopted?.call();
        return;
      }
      final runtime = _globalVariables.project(through);
      final persisted = _copy(runtime);
      if (_jsonString({'value': document['globalVariables']}) == _jsonString({'value': persisted})) {
        _adoptGlobals(runtime, through);
        onGlobalsAdopted?.call();
        return;
      }
      document['globalVariables'] = persisted;
      await _commitSettingsDocument(
        document,
        globals: (runtime: runtime, through: through),
        onCommitted: onGlobalsAdopted,
      );
    });
  }

  void _adoptGlobals(Map<String, Object?> runtime, int through) {
    _document['globalVariables'] = _copy(runtime);
    _globalVariables.commit(runtime, through);
  }

  // Every writer of settings.json encodes while owning the same file queue.
  // A native settings-only save must not carry globals captured before an
  // earlier bridge variable write has committed.
  Future<T> _settingsDocument<T>(Future<T> Function(Map<String, Object?> document) action) {
    final result = _fileQueue.then((_) => action(_copy(_document)));
    _fileQueue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _commitSettingsDocument(
    Map<String, Object?> document, {
    ({Map<String, Object?> runtime, int through})? globals,
    void Function()? check,
    void Function()? onCommitted,
  }) async {
    final file = File('${directory.path}/settings.json');
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.writing');
    await temporary.writeAsString(jsonEncode(document), flush: true);
    check?.call();
    await temporary.rename(file.path);
    if (globals != null) {
      _adoptGlobals(globals.runtime, globals.through);
    }
    onCommitted?.call();
    _scripts.documentCommitted(document);
    if (globals != null) {
      _scripts.resourcesChanged();
    }
  }

  Future<T> _withMutation<T>(String chatId, FutureOr<T> Function() action) => _withMutations([chatId], action);

  Future<T> _withMutations<T>(Iterable<String> chatIds, FutureOr<T> Function() action) {
    final ids = chatIds.toSet();
    final previous = [for (final id in ids) _mutations[id] ?? Future<void>.value()];
    final released = Completer<void>();
    // Register every gate before awaiting any turn, including when one persona
    // deletion affects several chats. Later overlapping mutations wait behind
    // this same gate; none can enter while another affected chat is draining.
    for (final id in ids) {
      _mutations[id] = released.future;
      _scripts.cancelChat(id);
      _groups.cancel(id);
      _turns[id]?.cancellation.cancel();
      _manualTools[id]?.cancellation.cancel();
    }
    return () async {
      try {
        await Future.wait(previous);
        final manual = [for (final id in ids) ?_manualTools[id]];
        for (final action in manual) {
          action.cancellation.cancel();
        }
        await Future.wait([for (final action in manual) action.done.future]);
        final groups = [for (final id in ids) ?_groups.rounds[id]];
        for (final group in groups) {
          group.cancel();
        }
        await Future.wait([for (final group in groups) group.done.future]);
        final running = ids.map((id) => _turns[id]).whereType<_Turn>().toList();
        for (final turn in running) {
          turn.cancellation.cancel();
        }
        await Future.wait([for (final turn in running) turn.done.future]);
        return await action();
      } finally {
        for (final id in ids) {
          if (identical(_mutations[id], released.future)) {
            // remove returns this same gate Future; complete it below. Waiting
            // for it here would deadlock the mutation's own finally block.
            unawaited(_mutations.remove(id));
          }
        }
        released.complete();
        _notifyLists();
      }
    }();
  }

  @override
  Future<void> selectSibling(String chatId, String nodeId, int index) => _operation(() async {
    String? previous;
    late String selected;
    await _withMutation(chatId, () {
      _store.transaction(() {
        final parent = _store.node(chatId, nodeId).message.parentId;
        previous = parent == null ? _store.chat(chatId).selectedRootId : _store.node(chatId, parent).selectedChildId;
        _store.selectSibling(chatId, nodeId, index);
        selected = _store.children(chatId, parent)[index].message.nodeId;
        _restoreVariables(chatId);
      });
      _liveVariables.remove(chatId);
    });
    await _scripts.nativeMutation(
      chatId,
      'MESSAGE_SWIPED',
      nodeId: selected,
      args: [
        {
          'oldRef': previous == null ? null : {'chatId': chatId, 'nodeId': previous},
          'newRef': {'chatId': chatId, 'nodeId': selected},
          'swipeId': index,
        },
      ],
    );
  });

  @override
  Future<void> selectNode(String chatId, String nodeId, {bool restoreDescendants = false}) => _operation(
    () => _withMutation(chatId, () {
      _store.transaction(() {
        _store.selectNode(chatId, nodeId, restoreDescendants: restoreDescendants);
        _restoreVariables(chatId);
      });
      _liveVariables.remove(chatId);
    }),
  );

  @override
  Future<void> nameBranch(String chatId, String nodeId, String? name) => _operation(
    () => _withMutation(chatId, () {
      _store.transaction(() {
        final extra = _copy(_store.node(chatId, nodeId).extra);
        final own = _map(extra['dshgo']);
        final label = name?.trim();
        if (label == null || label.isEmpty) {
          if (!own.containsKey('branchName')) {
            return;
          }
          own.remove('branchName');
        } else {
          if (own['branchName'] == label) {
            return;
          }
          own['branchName'] = label;
        }
        extra['dshgo'] = own;
        _store.updateMessage(chatId, nodeId, extra: extra);
      });
    }),
  );

  @override
  Future<void> edit(String chatId, String nodeId, String text) => _operation(
    () => _withMutation(chatId, () async {
      final chat = _store.chat(chatId);
      final target = _store.node(chatId, nodeId);
      final messageState = _stateFromNode(chatId, target, chat: chat);
      final group = _store.groupChat(chatId);
      final actorId = group != null && target.message.role == TavernRole.character
          ? target.message.speakerCharacterId
          : chat.characterId;
      final gameplayCapture = _captureGameplayResources(
        this,
        characterId: actorId,
        chatId: chatId,
        kinds: const {'regex'},
        deferResourceErrors: true,
      );
      final record = actorId == null ? null : await _record(actorId);
      if (record == null && group == null) throw const TavernImportError('角色不存在。');
      final groupNames = group == null ? null : await _groups.captureNames(group);
      final data = record?.card.data ?? <String, Object?>{'name': target.message.speaker};
      final current = _historyTo(chatId, chat.currentLeafId).any((node) => node.message.nodeId == nodeId);
      var terminal = current ? _store.node(chatId, chat.currentLeafId!) : target;
      while (!current && terminal.selectedChildId != null) {
        terminal = _store.node(chatId, terminal.selectedChildId!);
      }
      final leaf = terminal.message.nodeId;
      final state = _stateAt(chatId, leaf);
      final cached = _liveVariables[chatId];
      final local = current && cached != null && cached.leaf == leaf
          ? _runtimeCopy(cached.values)
          : _map(state['variables']);
      final metadata = _chatCodec.metadataForNode(_store, chatId, nodeId: leaf);
      final settings = _personaSettings(
        _effectiveReadSettings(chat, metadata),
        _personas.resolve(personaId: chat.personaId),
      );
      void checkGameplay() {
        if (!_gameplayResourcesCurrent(this, gameplayCapture)) {
          _gameplayCaptureConflict();
        }
      }

      checkGameplay();
      final environment = _MacroEnvironment(
        _effectiveCard(data, settings),
        settings,
        local,
        _globalVariables,
        _historyTo(chatId, leaf),
        _config,
        _clock(),
        _random,
        _macroChatIdentity(chat, state, metadata, state['chatJsonlSourceFile'] as String?, node: terminal),
        '',
        'normal',
        chatIdHash: _finiteNumber(metadata['chat_id_hash']),
        pickRerollSeed: metadata['pick_reroll_seed'],
        characterId: actorId ?? '',
        groupNames: groupNames?.names,
        groupNotMuted: groupNames?.enabledNames,
        messageVariables: messageState['messageVariables'],
        messageVariablesExists: messageState.containsKey('messageVariables'),
        packRegex: _resolveGameplayResources(gameplayCapture, settings, actorId: actorId, kinds: const {'regex'}).regex,
      );
      final globals = _globalVariables.checkpoint();
      try {
        final placement = switch (target.message.role) {
          TavernRole.user => RegexPlacement.userInput,
          TavernRole.narrator => RegexPlacement.slashCommand,
          _ => RegexPlacement.aiOutput,
        };
        final regexed = environment.regex.apply(
          text,
          placement: placement,
          isEdit: true,
          characterOverride: target.message.role == TavernRole.narrator ? null : target.message.speaker,
          expand: environment.regexExpand,
        );
        final expanded = environment.expand(regexed, const {});
        final nextState = <String, Object?>{
          ...state,
          'variables': _copy(local),
          'stChatId': environment.chatId,
          'stChatIdHash': environment.chatIdHash,
        };
        _store.transaction(() {
          checkGameplay();
          _store.edit(chatId, nodeId, expanded);
          _writeNodeState(chatId, leaf, nextState);
          if (current) {
            _store.updateChat(
              chatId,
              variables: _copy(local),
              metadata: _runtimeMetadata(_store.chat(chatId).metadata, nextState),
            );
          }
        });
      } catch (_) {
        _globalVariables.rollback(globals);
        rethrow;
      }
      if (current) _liveVariables[chatId] = (leaf: leaf, values: _runtimeCopy(local));
      if (_globalVariables.changedSince(globals.revision)) {
        await _saveDocument();
      }
    }).then((_) => _scripts.nativeMutation(chatId, 'MESSAGE_EDITED', nodeId: nodeId)),
  );

  void _writeNodeState(String chatId, String nodeId, Map<String, Object?> state) {
    final node = _store.node(chatId, nodeId);
    _store.updateMessage(
      chatId,
      nodeId,
      extra: {
        ...node.extra,
        'dshgo': {..._map(node.extra['dshgo']), 'tavernState': _copy(state)},
      },
    );
  }

  bool _impersonationStateChanged(String chatId, String nodeId, Map<String, Object?> state) {
    final previous = _stateAt(chatId, nodeId);
    final comparable = _copy(state);
    final beforeTimers = previous['timedWorldInfo'];
    final afterTimers = comparable['timedWorldInfo'];
    if (beforeTimers is Map<String, Object?> && afterTimers is Map<String, Object?>) {
      // Evaluation materializes these two containers even without any effect.
      // Ignore only newly added empty maps when deciding whether the old leaf
      // needs a write. Existing nulls, arrays, entries and unknown fields keep
      // their exact meaning; actual writes still use the complete new state.
      for (final key in const ['sticky', 'cooldown']) {
        final value = afterTimers[key];
        if (!beforeTimers.containsKey(key) && value is Map<String, Object?> && value.isEmpty) {
          afterTimers.remove(key);
        }
      }
    }
    return _jsonString(previous) != _jsonString(comparable);
  }

  @override
  Future<void> deleteMessage(String chatId, String nodeId) => _operation(
    () =>
        _withMutation(chatId, () {
          final stored = _storedLatestInspection(_store.chat(chatId));
          final latest = _latestInspections.containsKey(chatId) ? _latestInspections[chatId] : stored;
          var clearLatest = false;
          _store.transaction(() {
            final chat = _store.chat(chatId);
            _store.deleteMessage(
              chatId,
              nodeId,
              capturePortableState: (child, physicalState) {
                final override = _map(child.extra['dshgo'])['tavernState'];
                final state = _copy(override is Map<String, Object?> ? override : physicalState);
                // Resolve the child's own old source before any edge or current
                // metadata changes. This callback never reads a hidden node via a
                // visibility-filtered API, and never writes or evaluates macros.
                return _withStateHash(chat, state);
              },
            );
            _restoreVariables(chatId);
            clearLatest = latest != null && !_inspectionAnchorExists(latest);
            if (clearLatest || (stored != null && !_inspectionAnchorExists(stored))) {
              _writeLatestInspection(chatId, null);
            }
          });
          if (clearLatest) {
            _latestInspections[chatId] = null;
          }
          _liveVariables.remove(chatId);
        }).then(
          (_) => _scripts.nativeMutation(
            chatId,
            'MESSAGE_DELETED',
            nodeId: nodeId,
            args: [
              {
                'ref': {'chatId': chatId, 'nodeId': nodeId},
              },
            ],
          ),
        ),
  );

  @override
  Future<String> deleteFrom(String chatId, String nodeId) => _operation(
    () => _withMutation(chatId, () {
      final stored = _storedLatestInspection(_store.chat(chatId));
      final latest = _latestInspections.containsKey(chatId) ? _latestInspections[chatId] : stored;
      var clearLatest = false;
      final deletionId = _store.transaction(() {
        final token = _store.softDeleteFrom(chatId, nodeId);
        _restoreVariables(chatId);
        clearLatest = latest != null && !_inspectionAnchorExists(latest);
        if (clearLatest || (stored != null && !_inspectionAnchorExists(stored))) {
          _writeLatestInspection(chatId, null);
        }
        return token;
      });
      if (clearLatest) _latestInspections[chatId] = null;
      _liveVariables.remove(chatId);
      return deletionId;
    }),
  );

  @override
  Future<bool> undoDeleteFrom(String chatId, String deletionId) => _operation(
    () => _withMutation(chatId, () {
      final restored = _store.transaction(() {
        if (!_store.undoDeleteFrom(chatId, deletionId)) return false;
        _restoreVariables(chatId);
        return true;
      });
      if (restored) _liveVariables.remove(chatId);
      return restored;
    }),
  );

  @override
  Future<List<TavernMessage>> searchChat(String chatId, String query, {int limit = 50}) => _operation(() {
    final activeId = _turns[chatId]?.reply?.nodeId;
    if (activeId == null || limit <= 0) return _store.searchChat(chatId, query, limit: limit);
    // Before the first body checkpoint, a continuation still has its old
    // committed text/report and no shadow marker. Do not expose that active
    // reply as finalized. One extra result keeps the requested visible limit.
    return _store
        .searchChat(chatId, query, limit: limit + 1)
        .where((message) => message.nodeId != activeId)
        .take(limit)
        .toList();
  });

  @override
  Future<void> setHidden(String chatId, String nodeId, bool hidden) => _operation(
    () => _withMutation(chatId, () {
      _store.transaction(() {
        final node = _store.node(chatId, nodeId);
        _store.updateMessage(chatId, nodeId, original: {...node.original, 'is_system': hidden});
        _store.setHidden(chatId, nodeId, hidden);
      });
    }).then((_) => _scripts.nativeMutation(chatId, 'MESSAGE_UPDATED', nodeId: nodeId)),
  );

  void _restoreVariables(String chatId) {
    final leaf = _store.chat(chatId).currentLeafId;
    final state = _stateAt(chatId, leaf);
    final variables = _map(state['variables']);
    _store.updateChat(chatId, variables: variables, metadata: _runtimeMetadata(_store.chat(chatId).metadata, state));
  }

  Map<String, Object?> _stateAt(String chatId, String? nodeId) {
    if (nodeId == null) return _store.groupInitialState(chatId);
    return _stateFromNode(chatId, _store.node(chatId, nodeId));
  }

  // Only full store.node snapshots belong here, never display/prompt views.
  Map<String, Object?> _stateFromNode(String chatId, StoredNode node, {StoredChat? chat}) {
    final own = node.extra['dshgo'];
    final override = own is Map<String, Object?> ? own['tavernState'] : null;
    final state = override is Map<String, Object?> ? _copy(override) : _store.nodeState(chatId, node.message.nodeId);
    // Older snapshots predate the explicit cache marker. Resolve their own
    // source header before a selection can replace the chat's current cache.
    if (!state.containsKey('stChatIdHash')) {
      _withStateHash(chat ?? _store.chat(chatId), state);
    }
    return state;
  }

  Map<String, Object?> _withStateHash(StoredChat chat, Map<String, Object?> state) {
    state.putIfAbsent('stChatIdHash', () => _finiteNumber(_chatCodec.metadataForState(chat, state)['chat_id_hash']));
    return state;
  }

  List<StoredNode> _historyTo(String chatId, String? leaf) => _store.historyTo(chatId, leaf);

  @override
  Stream<TavernEvent> send(String chatId, String text) => _streamTurn(chatId, _TurnKind.send, input: text);

  @override
  Future<TavernMessage> sendOnly(String chatId, String text) =>
      _operation(() => _appendManualMessage(chatId, text, narrator: false));

  @override
  Future<TavernMessage> narrate(String chatId, String text, {String? speaker}) =>
      _operation(() => _appendManualMessage(chatId, text, narrator: true, speaker: speaker));

  Future<TavernMessage> _appendManualMessage(
    String chatId,
    String text, {
    required bool narrator,
    String? speaker,
  }) async {
    final message = await _withMutation(
      chatId,
      () => _appendMessage(chatId, text, narrator: narrator, speaker: speaker),
    );
    await _scripts.nativeMutation(chatId, 'MESSAGE_SENT', nodeId: message.nodeId);
    return message;
  }

  Future<TavernMessage> _appendMessage(
    String chatId,
    String text, {
    required bool narrator,
    String? speaker,
    _GroupView? groupView,
    StoredCharacter? actor,
    Map<String, Object?>? settingsOverride,
    TavernModelConfig? configOverride,
    ModelCancellation? cancellation,
    _GameplayAdmission? gameplayAdmission,
    _GameplayRuntime? gameplayOverride,
  }) async {
    final chat = _store.chat(chatId);
    final admission =
        gameplayAdmission ??
        _captureGameplayAdmission(
          this,
          characterId: actor?.id ?? chat.characterId,
          chatId: chatId,
          settings: settingsOverride ?? const {},
        );
    final group = groupView?.group ?? _store.groupChat(chatId);
    final host = groupView?.host ?? (group == null ? null : await _groups._card(group.hostCharacterId));
    final names = groupView == null && group != null ? await _groups.captureNames(group) : null;
    final record = actor ?? host ?? await _record(chat.characterId);
    if (record == null) {
      throw const TavernImportError('角色不存在。');
    }
    final leaf = chat.currentLeafId;
    final metadata = _chatCodec.metadataForNode(_store, chatId);
    final state = leaf == null && group == null ? _emptyChatState(metadata) : _stateAt(chatId, leaf);
    final source = state['chatJsonlSourceFile'] ?? _map(_map(chat.metadata['dshgo'])['chatJsonl'])['rootFile'];
    final sourceFile = source is String ? source : null;
    if (sourceFile != null) {
      state['chatJsonlSourceFile'] = sourceFile;
    }
    final cached = _liveVariables[chatId];
    final local = cached != null && cached.leaf == leaf
        ? _runtimeCopy(cached.values)
        : state.containsKey('variables')
        ? _map(state['variables'])
        : leaf != null && sourceFile != null
        ? <String, Object?>{}
        : _copy(chat.variables);
    final settings =
        settingsOverride ??
        _personaSettings(_effectiveReadSettings(chat, metadata), _personas.resolve(personaId: chat.personaId));
    final config = configOverride ?? _config;
    final previousGameplay = _gameplayHistoricalConfig(this, state).config;
    final gameplay =
        gameplayOverride ??
        (admission.hasActivePacks || state.containsKey('dshgoPackDefinitionConfigId')
            ? await _prepareGameplayRuntime(
                this,
                admission,
                hostData: host?.card.data ?? record.card.data,
                force: state.containsKey('dshgoPackDefinitionConfigId'),
                settings: settings,
                capturedCards: groupView == null
                    ? null
                    : {
                        groupView.host.id: groupView.host.card.data,
                        for (final member in groupView.group.members)
                          member.characterId: groupView.cards[member.characterId]?.card.data,
                      },
              )
            : null);
    final gameplayIssues = _gameplayValueIssues(
      gameplay,
      state,
      initializing: leaf == null,
      previousConfig: previousGameplay,
    );
    cancellation?.check();
    final history = _historyTo(chatId, leaf);
    final presetRaw = _map(settings['preset']);
    final preset = ChatPreset({
      ...(presetRaw.isEmpty ? ChatPreset.stDefault().raw : presetRaw),
      if (!presetRaw.containsKey('show_thoughts')) 'show_thoughts': !config.deepseek || config.thinking,
    });
    final environment = _MacroEnvironment(
      _effectiveCard(record.card.data, settings),
      settings,
      local,
      _globalVariables,
      history,
      config,
      _clock(),
      _random,
      _macroChatIdentity(chat, state, metadata, sourceFile, node: history.lastOrNull),
      text,
      'normal',
      chatIdHash: _finiteNumber(metadata['chat_id_hash']),
      pickRerollSeed: metadata['pick_reroll_seed'],
      characterId: record.id,
      preset: preset,
      groupNames: groupView?.names ?? names?.names,
      groupNotMuted: groupView?.enabledNames ?? names?.enabledNames,
      messageVariables: state['messageVariables'],
      messageVariablesExists: state.containsKey('messageVariables'),
      // Narrator preparation never runs the user-input regex pipeline.
      packRegex: narrator
          ? const []
          : _resolveGameplayResources(
              _GameplayResourceCapture.fromAdmission(admission),
              settings,
              actorId: record.id,
              kinds: const {'regex'},
            ).regex,
    );
    final beforeGlobals = _globalVariables.revision;
    late final String expanded;
    try {
      // Adapted from SillyTavern (AGPL-3.0), commit
      // 7e8663cd9c184a550b37238218bdd32c6efc68e9:
      // public/script.js::sendMessageAsUser and
      // public/scripts/slash-commands.js::sendNarratorMessage.
      // sendMessageAsUser applies USER_INPUT before substitution.
      // sendNarratorMessage instead substitutes text.trim(), without regex 3.
      expanded = narrator
          ? environment.expand(trimJsWhitespace(text), const {})
          : _preparePromptUser(environment, text);
    } catch (prepareError, prepareStackTrace) {
      // Local state is detached, but preparation uses ST/T11's real globals.
      // Preserve both failures when those effects cannot be saved either.
      try {
        if (_globalVariables.changedSince(beforeGlobals)) {
          await _saveDocument();
        }
      } catch (saveError, saveStackTrace) {
        Error.throwWithStackTrace(
          _PreparationSaveFailure(
            prepareError,
            prepareStackTrace,
            saveError,
            saveStackTrace,
            operation: narrator ? 'narrate' : 'sendOnly',
          ),
          saveStackTrace,
        );
      }
      Error.throwWithStackTrace(prepareError, prepareStackTrace);
    }
    // Save preparation effects before SQL: a failed write must not append a
    // manual message. Later SQL failure rolls back local state and the tree,
    // while already saved global preparation effects remain committed.
    if (_globalVariables.changedSince(beforeGlobals)) {
      await _saveDocument();
    }
    final nextState = _prepareAppendedMessageState(
      state,
      environment,
      stateCardData: host?.card.data ?? record.card.data,
      stateEnabled: settings['stateEnabled'] != false && (gameplay == null || leaf == null && gameplayIssues.isEmpty),
      gameplay: gameplay,
    );
    final initializedGameplay =
        gameplay != null &&
        !_map(state['messageVariables']).containsKey('dshgo') &&
        _map(nextState['messageVariables']).containsKey('dshgo');
    final narratorName = metadata['narrator_name'];
    final name = narrator
        ? speaker ?? (narratorName is String && narratorName.isNotEmpty ? narratorName : 'System')
        : environment.userName;
    cancellation?.check();
    final message = _store.transaction(() {
      if (!_gameplayAdmissionCurrent(this, admission)) {
        _gameplayCaptureConflict();
      }
      if (initializedGameplay) {
        _ensureGameplayConfig(this, gameplay);
      }
      final message = _store.append(
        chatId,
        parentId: leaf,
        role: narrator ? TavernRole.narrator : TavernRole.user,
        speaker: name,
        text: expanded,
        extra: {
          if (narrator) 'type': 'narrator',
          if (gameplayIssues.isNotEmpty) 'dshgo': {'stateIssues': gameplayIssues},
        },
        state: nextState,
      );
      _store.updateChat(
        chatId,
        variables: _copy(local),
        metadata: _runtimeMetadata(_store.chat(chatId).metadata, nextState),
      );
      return message;
    });
    _liveVariables[chatId] = (leaf: message.nodeId, values: _runtimeCopy(local));
    return message;
  }

  @override
  Stream<TavernEvent> regenerate(String chatId, String nodeId) =>
      _streamTurn(chatId, _TurnKind.regenerate, nodeId: nodeId);
  @override
  Stream<TavernEvent> continueReply(String chatId, String nodeId) =>
      _streamTurn(chatId, _TurnKind.continueReply, nodeId: nodeId);
  @override
  Stream<TavernEvent> impersonate(String chatId) => _streamTurn(chatId, _TurnKind.impersonate);
  @override
  Stream<TavernEvent> resumeTurn(String chatId) {
    late StreamController<TavernEvent> controller;
    _Turn? observed;
    controller = StreamController<TavernEvent>(
      onListen: () {
        try {
          _ensureOpen();
          _store.chat(chatId);
          if (_groups.rounds.containsKey(chatId)) {
            controller.add(TavernTurnFailed(TavernFailure.invalidParameters, detail: 'group_requires_resumeGroupTurn'));
            unawaited(controller.close());
            return;
          }
          final turn = _turns[chatId];
          if (turn == null || turn.finished) {
            unawaited(controller.close());
            return;
          }
          // Registration and the complete snapshot are one synchronous
          // operation: no delta can slip between them or appear twice.
          observed = turn;
          turn.observers.add(controller);
          controller.add(
            TavernTurnSnapshot(
              chatId: chatId,
              generationType: turn.generationType,
              startedAt: turn.at,
              logicalTurnId: turn.toolAdmitted ? turn.toolLogicalId : null,
              message: turn.reply == null ? null : _buffered(turn),
            ),
          );
        } catch (error) {
          controller.add(TavernTurnFailed(TavernFailure.server, detail: _safeDetail(error)));
          unawaited(controller.close());
        }
      },
      onCancel: () {
        observed?.observers.remove(controller);
      },
    );
    return controller.stream;
  }

  @override
  void stop(String chatId) {
    _scripts.cancelChat(chatId);
    _groups.cancel(chatId);
    _turns[chatId]?.cancellation.cancel();
    _manualTools[chatId]?.cancellation.cancel();
  }

  Stream<TavernEvent> _streamTurn(
    String chatId,
    _TurnKind kind, {
    String input = '',
    String? nodeId,
    void Function(_Turn)? onAdmitted,
  }) {
    late StreamController<TavernEvent> controller;
    _Turn? turn;
    controller = StreamController<TavernEvent>(
      onListen: () {
        try {
          _ensureOpen();
          final profile = _TurnProfile.start();
          if (_capturingBackup) {
            controller.add(TavernTurnFailed(TavernFailure.busy, detail: 'backup_capture_in_progress'));
            unawaited(controller.close());
            return;
          }
          final chat = _store.chat(chatId);
          if (_mainBusy(chatId) || _mutations.containsKey(chatId)) {
            controller.add(TavernTurnFailed(TavernFailure.busy, detail: 'chat_busy'));
            unawaited(controller.close());
            return;
          }
          final group = _store.groupChat(chatId);
          if (group != null && (kind == _TurnKind.send || kind == _TurnKind.impersonate)) {
            controller.add(
              TavernTurnFailed(
                TavernFailure.invalidParameters,
                detail: kind == _TurnKind.send ? 'group_requires_sendGroup' : 'group_impersonate_unsupported',
              ),
            );
            unawaited(controller.close());
            return;
          }
          var actorId = chat.characterId;
          var actorConfig = _config;
          if (group != null) {
            final targetId = nodeId == null ? null : _store.node(chatId, nodeId).message.speakerCharacterId;
            final member = group.members.where((item) => item.characterId == targetId).firstOrNull;
            if (member == null) {
              controller.add(TavernTurnFailed(TavernFailure.invalidParameters, detail: 'group_actor_not_in_roster'));
              unawaited(controller.close());
              return;
            }
            actorId = member.characterId;
            actorConfig = _groupModelConfig(_config, member.modelRole);
          }
          final selection = _personas.resolve(personaId: chat.personaId);
          final presetSelection = _resolvePreset(chat).selection;
          if (_mainBusy(chatId) ||
              _mutations.containsKey(chatId) ||
              _globalPresetUpdate ||
              _deletingPresets.contains(presetSelection.effectivePresetId) ||
              _deletingCharacters.contains(chat.characterId) ||
              _deletingCharacters.contains(actorId) ||
              group?.members.any((member) => _deletingCharacters.contains(member.characterId)) == true ||
              _deletingPersonas.contains(selection.persona?.id)) {
            controller.add(TavernTurnFailed(TavernFailure.busy, detail: 'chat_busy'));
            unawaited(controller.close());
            return;
          }
          final contextStarted = profile?.now;
          final sourceNodeId = nodeId ?? chat.currentLeafId;
          final sourceNode = sourceNodeId == null ? null : _store.node(chatId, sourceNodeId);
          final metadata = _chatCodec.metadataForCapturedNode(_store, chat, sourceNode);
          final sourceState = sourceNode == null
              ? _store.groupInitialState(chatId)
              : _stateFromNode(chatId, sourceNode, chat: chat);
          final sourceFile =
              sourceState['chatJsonlSourceFile'] ?? _map(_map(chat.metadata['dshgo'])['chatJsonl'])['rootFile'];
          profile?.record('admission_context', contextStarted!);
          final running = _Turn(
            chat,
            kind,
            input,
            nodeId,
            controller,
            actorConfig,
            _personaSettings(_effectiveReadSettings(chat, metadata), selection),
            _clock(),
            selection,
            metadata,
            sourceFile is String ? sourceFile : null,
            presetSelection.effectivePresetId,
            actorId: actorId,
            profile: profile,
          );
          running.gameplayAdmission = _captureGameplayAdmission(
            this,
            characterId: actorId,
            chatId: chatId,
            settings: running.settings,
          );
          turn = running;
          running.directorCaptured = _directors.latestSuccess(chatId);
          if (_secretsEnabled(running.settings) && kind != _TurnKind.impersonate) {
            running.secretCaptured = _store.agentRunsByKind(chatId, const {
              'director.secret_proposal',
            }, limit: 1).firstOrNull;
          }
          _turns[chatId] = running;
          _setInspection(running, running.inspection);
          onAdmitted?.call(running);
          running.profile?.mark('admission');
          unawaited(_run(running));
        } catch (error) {
          controller.add(TavernTurnFailed(TavernFailure.server, detail: _safeDetail(error)));
          unawaited(controller.close());
        }
      },
      onCancel: () {
        // Leaving a page releases its observer, not the generation. A later
        // resumeTurn reads the current buffers without retaining old deltas.
        turn?.observers.remove(controller);
      },
    );
    return controller.stream;
  }

  Future<void> _run(_Turn turn) async {
    final chatId = turn.chat.id;
    final counter = turn.profile?.counter(_counter) ?? _counter;
    var beforeGlobals = _globalVariables.revision;
    try {
      turn.secretCardRevision ??= _directors._cardRevisions[turn.chat.characterId] ?? 0;
      final toolAdmissionAt = turn.profile?.now;
      try {
        _beginOrdinaryToolTurn(this, turn);
      } finally {
        turn.profile?.record('prepare_tool_admission', toolAdmissionAt!);
      }
      final beforeHooksAt = turn.profile?.now;
      try {
        await _scripts.beforeTurn(turn);
      } finally {
        turn.profile?.recordElapsed('prepare_before_hooks', beforeHooksAt!);
      }
      await Future<void>.delayed(Duration.zero);
      turn.cancellation.check();
      // Preparation handlers may write locals or message variables. Capture
      // their committed state after their direct writes have drained. An
      // explicit regenerate/continue target still owns its source branch,
      // even while a different branch is selected in the chat.
      if (turn.toolOwner != null) {
        beforeGlobals = _sealOrdinaryToolPreparation(this, turn);
        final policyAt = turn.profile?.now;
        try {
          await _completeOrdinaryToolPolicy(this, turn);
        } finally {
          turn.profile?.recordElapsed('prepare_policy', policyAt!);
        }
      } else {
        turn.chat = _store.chat(chatId);
        turn.metadata = _chatCodec.metadataForNode(_store, chatId, nodeId: turn.nodeId);
        final savedSource =
            _stateAt(chatId, turn.nodeId ?? turn.chat.currentLeafId)['chatJsonlSourceFile'] ??
            _map(_map(turn.chat.metadata['dshgo'])['chatJsonl'])['rootFile'];
        turn.sourceFile = savedSource is String ? savedSource : null;
        beforeGlobals = _globalVariables.revision;
        turn.originalVariables = _runtimeCopy(_liveVariables[chatId]?.values ?? turn.chat.variables);
        turn.nativePreparationStarted = true;
      }
      // Cancellation releases the turn, not its actual local file work.
      // Keep the original read owned until every character file has drained.
      final resourcesAt = turn.profile?.now;
      if (turn.groupView == null) {
        final group = _store.groupChat(chatId);
        if (group != null) {
          turn.groupView = await turn.cancellation.wait(
            _trackOperation(_groups.capture(group, checkCancelled: turn.cancellation.check)),
          );
        }
      }
      final record = turn.groupView == null
          ? await turn.cancellation.wait(_trackOperation(_record(turn.actorId)))
          : turn.groupView!.cards[turn.actorId];
      turn.profile?.recordElapsed('prepare_resources', resourcesAt!);
      if (record == null) throw const TavernImportError('角色不存在。');
      final prepareContextAt = turn.profile?.now;
      turn.cancellation.check();
      _requireOrdinaryOwnership(this, turn, StoredToolPhase.native);
      final data = _effectiveCard(record.card.data, turn.settings);
      final hostRaw = turn.groupView?.host.card.data ?? record.card.data;
      final hostData = identical(hostRaw, record.card.data) ? data : _effectiveCard(hostRaw, turn.settings);
      turn.directorCard = hostData;
      StoredNode? target = turn.originalTarget;
      if (turn.nodeId != null) {
        target ??= _store.node(chatId, turn.nodeId!);
        if (target.message.role != TavernRole.character) throw ArgumentError('The target must be a character message.');
      }
      turn.originalTarget = target;
      var parent = turn.chat.currentLeafId;
      if (turn.kind == _TurnKind.regenerate) parent = target!.message.parentId;
      if (turn.kind == _TurnKind.continueReply) parent = target!.message.nodeId;
      _setInspection(turn, turn.inspection.copyWith(contextNodeId: parent, clearContextNodeId: parent == null));
      // A successful impersonation may update the terminal state of an empty
      // chat without adding a node. Only a turn starting at that empty current
      // end may resume it; an empty regenerate prefix has no such snapshot.
      var state = turn.groupView != null && parent == null
          ? _stateAt(chatId, null)
          : parent == null && turn.chat.currentLeafId == null && turn.kind != _TurnKind.regenerate
          ? _emptyChatState(turn.metadata)
          : _stateAt(chatId, parent);
      if (turn.sourceFile != null) state['chatJsonlSourceFile'] = turn.sourceFile;
      final cached = _liveVariables[chatId];
      final local = turn.kind != _TurnKind.regenerate && cached != null && cached.leaf == parent
          ? _runtimeCopy(cached.values)
          : state.containsKey('variables')
          ? _map(state['variables'])
          : turn.kind == _TurnKind.regenerate || (parent != null && turn.sourceFile != null)
          ? <String, Object?>{}
          : _copy(turn.chat.variables);
      turn.variables = local;
      turn.state = state;
      turn.gameplayInitializing = parent == null && turn.chat.currentLeafId == null;
      turn.gameplayPreviousConfig = _gameplayHistoricalConfig(this, state).config;
      final gameplayAdmission = turn.gameplayAdmission!;
      if (turn.gameplay == null &&
          (gameplayAdmission.hasActivePacks || state.containsKey('dshgoPackDefinitionConfigId'))) {
        turn.gameplay = await turn.cancellation.wait(
          _trackOperation(
            _prepareGameplayRuntime(
              this,
              gameplayAdmission,
              hostData: hostData,
              force: state.containsKey('dshgoPackDefinitionConfigId'),
              settings: turn.settings,
              capturedCards: turn.groupView == null
                  ? null
                  : {
                      turn.groupView!.host.id: turn.groupView!.host.card.data,
                      for (final member in turn.groupView!.group.members)
                        member.characterId: turn.groupView!.cards[member.characterId]?.card.data,
                    },
            ),
          ),
        );
        turn.cancellation.check();
        _requireOrdinaryOwnership(this, turn, StoredToolPhase.native);
      }
      turn.gameplayResources = _resolveGameplayResources(
        _GameplayResourceCapture.fromAdmission(gameplayAdmission),
        turn.settings,
        actorId: turn.actorId,
      );
      final gameplayIssues = _gameplayValueIssues(
        turn.gameplay,
        state,
        initializing: turn.gameplayInitializing,
        previousConfig: turn.gameplayPreviousConfig,
      );
      turn.gameplayValueEligible = gameplayIssues.isEmpty;
      turn.statePreparationIssues.addAll(gameplayIssues);
      _setInspection(turn, turn.inspection);
      _bindSecretTurn(this, turn, hostData, parent, target, (next, restored) {
        state = next;
        turn.state = next;
        target = restored;
        turn.originalTarget = restored;
      });
      final hadGameplayValue = _map(turn.state['messageVariables']).containsKey('dshgo');
      _prepareStateTurn(turn, hostData);
      turn.gameplayInitialized =
          turn.gameplay != null && !hadGameplayValue && _map(turn.state['messageVariables']).containsKey('dshgo');
      final spreset = turn.spreset ??= _createNativeSPreset(turn);
      final preset = ChatPreset(
        await spreset.preparePreset(
          turn.generationType,
          () => [
            for (final node in _store.scriptHistoryTo(chatId, parent))
              {
                'mes': node.message.text,
                'name': node.message.speaker,
                'is_user': node.message.role == TavernRole.user,
                'is_system': _systemMessage(node),
              },
          ],
        ),
      );
      turn.effectiveShowThoughts = presetTruthy(preset.settings['show_thoughts']);
      final worldSettings = WorldInfoSettings.fromJson(_map(turn.settings['worldInfo']));
      turn.profile?.record('prepare_context', prepareContextAt!);
      turn.profile?.mark('prepare');
      await Future<void>.delayed(Duration.zero);
      turn.cancellation.check();
      _requireOrdinaryOwnership(this, turn, StoredToolPhase.native);
      final historyAt = turn.profile?.now;
      final _PromptHistoryWindow? historyWindow;
      final List<StoredNode> history;
      try {
        historyWindow = _plainPromptHistory(
          this,
          turn,
          data,
          preset,
          parent,
          counter: counter,
          worldSettings: worldSettings,
        );
        history = historyWindow?.nodes ?? await _completePromptHistory(this, turn, parent);
      } finally {
        turn.profile?.recordElapsed('history_read', historyAt!);
      }
      var pathNodes = historyWindow?.path.length ?? history.length;
      final bodyNodes = historyWindow?.bodyNodes ?? history.length;
      var eligibleMessageCount = historyWindow == null
          ? history.where((node) => !node.message.hidden && !_systemMessage(node)).length
          : historyWindow.path.where((node) => !node.hidden && !node.isSystem).length;
      var userMessageCount = historyWindow == null
          ? history.where((node) => node.message.role == TavernRole.user).length
          : historyWindow.path.where((node) => node.role == TavernRole.user).length;
      final assistantMessageCount = historyWindow == null
          ? history
                .where(
                  (node) => node.message.role == TavernRole.character && !node.message.hidden && !_systemMessage(node),
                )
                .length
          : historyWindow.path
                .where((node) => node.role == TavernRole.character && !node.hidden && !node.isSystem)
                .length;
      turn.directorPrepared = _directors.prepare(turn, hostData, parent);
      _prepareCardEventTurn(this, turn, hostData);
      // An inactive target can rewrite remembered edges outside the old active
      // path. Preserve only edges activation can change, including a null
      // selection with still-stored, unselected children below it.
      if (historyWindow != null) {
        final links = historyWindow.path;
        for (var index = 0; index < links.length; index++) {
          final node = links[index];
          if (index == links.length - 1 || node.selectedChildId != links[index + 1].nodeId) {
            turn.previousSelections.add((node.nodeId, node.selectedChildId));
          }
        }
      } else {
        for (var index = 0; index < history.length; index++) {
          final node = history[index];
          if (index == history.length - 1 || node.selectedChildId != history[index + 1].message.nodeId) {
            turn.previousSelections.add((node.message.nodeId, node.selectedChildId));
          }
        }
      }
      turn.profile?.mark('history');
      await Future<void>.delayed(Duration.zero);
      turn.cancellation.check();
      _requireOrdinaryOwnership(this, turn, StoredToolPhase.native);
      final environment = _MacroEnvironment(
        data,
        turn.settings,
        local,
        _globalVariables,
        history,
        turn.config,
        turn.at,
        _random,
        _macroChatIdentity(
          turn.chat,
          _stateAt(chatId, turn.nodeId ?? parent),
          turn.metadata,
          turn.sourceFile,
          node: target ?? historyWindow?.identityNode ?? history.lastOrNull,
        ),
        turn.input,
        turn.generationType,
        chatIdHash: _finiteNumber(turn.metadata['chat_id_hash']),
        pickRerollSeed: turn.metadata['pick_reroll_seed'],
        characterId: turn.actorId,
        groupNames: turn.groupView?.names,
        groupNotMuted: turn.groupView?.enabledNames,
        preset: preset,
        messageVariables: turn.state['messageVariables'],
        messageVariablesExists: turn.state.containsKey('messageVariables'),
        packRegex: turn.gameplayResources.regex,
      );
      turn.environment = environment;
      if (turn.kind == _TurnKind.send && turn.input.isNotEmpty) {
        final text = _preparePromptUser(environment, turn.input);
        final appended = _appendOrdinaryToolUser(
          this,
          turn,
          parentId: parent,
          speaker: environment.userName,
          text: text,
        );
        parent = appended.message.nodeId;
        history.add(appended.node);
        userMessageCount++;
        pathNodes++;
        eligibleMessageCount++;
      }
      final prepared = prepareCharacterFields(data, persona: environment.persona, expand: environment.baseExpand);
      // ST expands chat[0].mes after eager card fields, before WI and before
      // filtering hidden/system messages. Keep the same per-turn history for
      // later macros; commit text changes with the ready reply below.
      final first = historyWindow?.first ?? history.firstOrNull;
      final expandedFirst = _expandPromptFirst(history, first, environment);
      if (expandedFirst != null && turn.kind != _TurnKind.impersonate) {
        turn.originalFirstMessage = first;
        turn.expandedFirstMessage = expandedFirst;
        turn.firstMessageSource = _store.sourceToken(chatId, first!.message.nodeId);
      }
      final promptHistory = await _preparePromptHistoryAsync(
        history,
        environment,
        continuing: turn.kind == _TurnKind.continueReply,
        check: () {
          turn.cancellation.check();
          _requireOrdinaryOwnership(this, turn, StoredToolPhase.native);
        },
      );
      var eligibleHistory = promptHistory.where((node) => !node.message.hidden && !_systemMessage(node)).toList();
      final activeWorldName = turn.metadata['world_info'];
      final activeBookId = activeWorldName is String
          ? _map(turn.chat.settings['stLorebookIds'])[activeWorldName]
          : null;
      turn.profile?.mark('fields');
      await Future<void>.delayed(Duration.zero);
      turn.cancellation.check();
      _requireOrdinaryOwnership(this, turn, StoredToolPhase.native);
      // Own the complete walk, and stop before admitting its next book read.
      final books = await turn.cancellation.wait(
        _trackOperation(
          _loadBooks(
            turn.actorId,
            data,
            turn.settings,
            group: turn.groupView,
            gameplayResources: turn.gameplayResources,
            personaId: turn.personaSelection.persona?.id,
            stWorldNames: {if (activeWorldName is String && activeBookId is String) activeBookId: activeWorldName},
            checkCancelled: turn.cancellation.check,
          ),
        ),
      );
      turn.cancellation.check();
      _requireOrdinaryOwnership(this, turn, StoredToolPhase.native);
      final directorBooks = _directorBooks(this, turn, books.loaded, requestedLeafId: parent);
      turn.profile?.mark('books');
      await Future<void>.delayed(Duration.zero);
      turn.cancellation.check();
      _requireOrdinaryOwnership(this, turn, StoredToolPhase.native);
      var completeMacroHistory = false;
      int? scanDepth;
      if (historyWindow != null) {
        final worldHistoryAt = turn.profile?.now;
        try {
          if (directorBooks.any((book) => !(_plainBookViews[book] ?? _plainPromptData(book.raw)))) {
            final complete = await _completePromptHistory(this, turn, parent);
            historyWindow.bodyNodes += complete.length;
            // The macro context owns this live list. Earlier admitted fields
            // only used pure names; do not replay them or the independent
            // promptHistory list when a loaded book needs complete history.
            history
              ..clear()
              ..addAll(complete);
            eligibleHistory = complete.where((node) => !node.message.hidden && !_systemMessage(node)).toList();
            completeMacroHistory = true;
          } else {
            scanDepth = _worldHistoryDepth(directorBooks, worldSettings);
            eligibleHistory = _worldHistoryWindow(
              this,
              chatId,
              parent,
              promptHistory,
              historyWindow,
              depth: scanDepth,
              includeNames: worldSettings.includeNames,
            );
          }
        } finally {
          turn.profile?.record('world_history_read', worldHistoryAt!);
        }
      }
      turn.profile?.history(
        windowed: historyWindow != null && !completeMacroHistory,
        pathNodes: pathNodes,
        bodyNodes: historyWindow?.bodyNodes ?? bodyNodes,
        scanDepth: scanDepth,
      );
      if (books.missing.isNotEmpty) {
        _setInspection(turn, turn.inspection.copyWith(worldInfo: {'missing': books.missing}));
      }
      final initialInjections = _configuredInjections(
        turn.settings,
        prepared,
        data,
        userMessageCount: userMessageCount,
      );
      final scriptInjections = turn.scriptInjectionUses == null
          ? null
          : _scripts.injectionRegistry.prepareInjections(turn.scriptInjectionUses!, environment);
      final scanInjections = <String>[];
      for (final item in initialInjections) {
        if (item.scan) {
          final content = environment.expand(item.injection.fragment.content, const {});
          if (content.isNotEmpty) scanInjections.add(content);
        }
      }
      scanInjections.addAll(scriptInjections?.scanTexts ?? const []);
      var world = await _evaluatePreparedWorld(
        worldEngine: _worldInfoEngine,
        turn: turn,
        environment: environment,
        prepared: prepared,
        books: directorBooks,
        eligibleHistory: eligibleHistory,
        messageCount: eligibleMessageCount,
        assistantMessageCount: assistantMessageCount,
        preset: preset,
        worldSettings: worldSettings,
        counter: counter,
        scanInjections: scanInjections,
      );
      final preparedUiHits = world.activated.where((hit) => hit.disabledUiPrompt != null).toList();
      _setInspection(
        turn,
        turn.inspection.copyWith(
          worldInfo: _worldInfoTrace(
            world,
            preparedUiHits: preparedUiHits,
            missingBooks: books.missing,
            packSources: turn.gameplayResources.packSources,
          ),
        ),
      );
      environment.outlets.addAll({
        for (final entry in world.outlets.entries) entry.key: entry.value.map((hit) => hit.content).join('\n'),
      });
      turn.profile?.mark('world_info');
      await Future<void>.delayed(Duration.zero);
      turn.cancellation.check();
      _requireOrdinaryOwnership(this, turn, StoredToolPhase.native);
      final injections = [
        ..._finishInjections(initialInjections, world, deepseek: turn.config.deepseek),
        ...?scriptInjections?.prompts,
        ..._stateTurnInjections(turn),
        ..._cardEventTurnInjections(turn),
        ..._secretTurnInjections(this, turn, hostData),
        ..._directorInjections(turn),
      ];
      final windowConfiguration = _PromptWindowConfiguration(turn, data, hostData, books.loaded);
      final cacheWindow = _reusePromptWindow(turn, parent, windowConfiguration);
      var assembly = _assemblePreparedPrompt(
        turn: turn,
        data: data,
        environment: environment,
        preset: preset,
        world: world,
        promptHistory: promptHistory,
        prepared: prepared,
        injections: injections,
        counter: counter,
        prefix: historyWindow?.prefix ?? const [],
        cacheWindow: cacheWindow,
        onInput: (input) => turn.spresetPromptInput = input,
        onPromptManager: spreset.capturePromptManager,
      );
      assembly = await spreset.assembly(assembly, turn.spresetPromptInput!, counter);
      assembly = await spreset.selectNativeWireTools(assembly, turn.spresetPromptInput!);
      if (assembly.historyWindow case final window?) {
        turn.pendingPromptWindow = _PendingPromptWindow(window, parent, windowConfiguration);
      } else {
        _promptCacheWindows.remove(chatId);
      }
      turn.profile?.mark('assembly');
      await Future<void>.delayed(Duration.zero);
      turn.cancellation.check();
      _requireOrdinaryOwnership(this, turn, StoredToolPhase.native);
      final excludedWorldEntries = <(String, String)>{
        for (final exclusion in assembly.excluded)
          if (exclusion.reason == 'v3-ignore-on-max-context')
            for (final source in exclusion.sources)
              if (source.kind == 'worldInfo' && source.details['bookId'] is String && source.details['uid'] is String)
                (source.details['bookId']! as String, source.details['uid']! as String),
      };
      world = world.withoutEntries(excludedWorldEntries);
      state['timedWorldInfo'] = _copy(world.timedWorldInfo);
      state['decoratorState'] = _copy(world.decoratorState);
      _adoptGameplayWorldInfo(turn, world);
      _setInspection(
        turn,
        turn.inspection.copyWith(
          worldInfo: _worldInfoTrace(
            world,
            preparedUiHits: preparedUiHits,
            missingBooks: books.missing,
            packSources: turn.gameplayResources.packSources,
          ),
        ),
      );
      _inspections[chatId] = TavernInspection(
        prompt: assembly,
        worldInfo: world,
        generationType: turn.generationType,
        at: turn.at,
        preparedUiHits: preparedUiHits,
        missingBooks: books.missing,
        packSources: turn.gameplayResources.packSources,
      );
      _captureAssembly(turn, assembly);
      _captureStateAssembly(turn, assembly);
      _captureCardEventAssembly(turn, assembly);
      _captureSecretAssembly(turn, assembly);
      _captureDirectorAssembly(this, turn, assembly, world);
      if (turn.groupRound case final round?) {
        _setInspection(
          turn,
          turn.inspection.copyWith(
            director: {
              ...turn.inspection.director,
              'groupSelection': {'roundId': round.id, 'plannedCharacterIds': round.planned, 'issues': round.issues},
            },
          ),
        );
      }
      if (turn.stateDefinition != null || _hasSecretTrace(turn)) {
        _setInspection(turn, turn.inspection.copyWith(state: _statePreparationTrace(turn)));
      }
      turn.profile?.mark('inspection');
      turn.cancellation.check();
      turn.postfix = presetString(preset.executionSettings['continue_postfix']);
      if (turn.kind == _TurnKind.impersonate) {
        turn.begin(
          TavernMessage(
            nodeId: 'temporary-${++_temporaryId}',
            parentId: parent,
            role: TavernRole.user,
            speaker: environment.userName,
            text: '',
            at: turn.at,
          ),
        );
      } else {
        _bindOrdinaryToolReply(this, turn, parentId: parent, speaker: record.card.promptName, target: target);
      }
      await _scripts._captureMvuTurnBase(turn);
      final requestBody = _copy(assembly.body);
      turn.cancellation.check();
      try {
        if (turn.scriptInjectionUses case final uses?) {
          _scripts.injectionRegistry.claim(uses, generationId: turn.generationId);
        }
      } on TavernScriptException catch (error) {
        turn.hookIssues.addAll(error.issues);
        rethrow;
      }
      turn.emit(TavernTurnStarted(_buffered(turn), logicalTurnId: turn.toolAdmitted ? turn.toolLogicalId : null));
      _scripts.publishSent(
        turn.sent ?? turn.groupRound?.sent,
        generationId: turn.generationId,
        cancellation: turn.cancellation,
      );
      turn.profile?.mark('reply');
      // Let the event queue run before registering the first model request.
      await Future<void>.delayed(Duration.zero);
      turn.cancellation.check();
      if (turn.toolOwner == null) {
        await _consume(turn, await spreset.request(requestBody));
      } else {
        await _consumeOrdinaryTools(this, turn, requestBody);
      }
      turn.cancellation.check();
      turn.profile?.mark('model');
      _finishRegex(turn);
      if (_globalVariables.changedSince(beforeGlobals)) {
        await _saveDocument();
      }
      turn.cancellation.check();
      turn.profile?.mark('writeback');
      final stateSettlement = _settleStateTurn(this, turn, successful: true);
      turn.stateAttempt = stateSettlement;
      final storySettlement = turn.groupRound == null
          ? _settleStoryTurn(this, turn, stateSettlement?.state ?? turn.currentState)
          : null;
      turn.storyAttempt = storySettlement;
      _commitTurn(
        turn,
        turn.inspection.copyWith(status: TavernInspectionStatus.completed, finishedAt: _clock()),
        stateSettlement: stateSettlement,
        storySettlement: storySettlement,
      );
      turn.modelCommitted = true;
      if (!turn.modelDrained.isCompleted) {
        turn.modelDrained.complete();
      }
      _groups.actorCommitted(turn);
      turn.profile?.mark('settlement');
      // Storage is already adopted; cancellation here remains post-commit.
      await Future<void>.delayed(Duration.zero);
      await _scripts.afterMessage(turn);
      turn.emit(
        TavernTurnDone(
          turn.lastCommitted!,
          finishReason: turn.finishReason,
          logicalTurnId: turn.toolAdmitted ? turn.toolLogicalId : null,
          hookIssues: turn.hookIssues,
        ),
      );
      turn.terminal = true;
      if (turn.groupRound == null && !turn.cancellation.isCancelled) {
        _directors.afterTurn(turn);
      }
      turn.profile?.mark('after_hooks');
    } catch (error) {
      turn.profile?.mark('failed');
      if (turn.modelCommitted) {
        // A hook or late anchor problem cannot re-enter model settlement or
        // roll back a body that has already been committed.
        turn.hookIssues.add(
          TavernScriptIssue(
            code: 'hookFailure',
            message: 'Post-commit processing failed (${error.runtimeType}).',
            committed: true,
            generationId: turn.generationId,
          ),
        );
        turn.emit(
          TavernTurnDone(
            turn.lastCommitted!,
            finishReason: turn.finishReason,
            logicalTurnId: turn.toolAdmitted ? turn.toolLogicalId : null,
            hookIssues: turn.hookIssues,
          ),
        );
        turn.terminal = true;
      } else if (turn.toolOwner != null) {
        await _failOrdinaryToolTurn(this, turn, error, beforeGlobals);
      } else {
        var failure = error is TavernModelException
            ? error.kind
            : error is PromptBudgetExceeded
            ? TavernFailure.contextTooLong
            : error is TavernImportError || error is FormatException
            ? TavernFailure.invalidCard
            : TavernFailure.server;
        var detail = error is TavernModelException ? error.detail : _safeDetail(error);
        TavernMessage? partial;
        var inspection = turn.inspection.copyWith(
          status: TavernInspectionStatus.failed,
          finishedAt: _clock(),
          failure: failure,
          detail: detail,
        );
        try {
          _finishRegex(turn);
        } catch (writeError) {
          failure = TavernFailure.server;
          detail = 'writeback_failed (${writeError.runtimeType})';
          inspection = inspection.copyWith(failure: failure, detail: detail);
        }
        // Resolve the asynchronous file result before publishing one SQL
        // terminal snapshot. A file failure must not prevent an empty rollback.
        try {
          if (_globalVariables.changedSince(beforeGlobals)) {
            await _saveDocument();
          }
        } catch (fileError) {
          failure = TavernFailure.server;
          detail = 'turn_storage_failure (${fileError.runtimeType})';
          inspection = inspection.copyWith(failure: failure, detail: detail);
        }
        try {
          final stateSettlement = turn.nativePreparationStarted ? _failedStateSettlement(this, turn, inspection) : null;
          final storySettlement = turn.nativePreparationStarted ? _failedStorySettlement(turn, inspection) : null;
          if (stateSettlement != null) inspection = inspection.copyWith(state: stateSettlement.trace);
          if (turn.hasOutput) {
            _commitTurn(turn, inspection, stateSettlement: stateSettlement, storySettlement: storySettlement);
            partial = _latest(turn);
          } else {
            inspection = inspection.copyWith(clearNodeId: true);
            _rollbackEmpty(turn, inspection, stateSettlement: stateSettlement, storySettlement: storySettlement);
            if (turn.kind == _TurnKind.continueReply) partial = turn.originalTarget?.message;
          }
          // Terminal storage has added the state/story/event failure traces.
          // Keep that published snapshot instead of replacing it below with
          // the pre-storage inspection captured by this catch block.
          inspection = turn.inspection;
        } catch (storageError) {
          // Do not return partial=null after a failed rollback: that would invite
          // the UI to reinsert a user line that might still be in the database.
          failure = TavernFailure.server;
          detail = 'turn_storage_failure (${storageError.runtimeType})';
          partial = turn.lastCommitted;
          if (partial == null && turn.newUserId != null) {
            try {
              partial = _store.message(chatId, turn.newUserId!);
            } catch (_) {
              /* Original failure is retained. */
            }
          }
          inspection = inspection.copyWith(
            status: TavernInspectionStatus.failed,
            finishedAt: _clock(),
            failure: failure,
            detail: detail,
          );
        }
        _setInspection(turn, inspection);
        turn.emit(TavernTurnFailed(failure, detail: detail, partial: partial, hookIssues: turn.hookIssues));
        turn.terminal = true;
      }
      turn.profile?.mark('failure_settlement');
    } finally {
      turn.flushTimer?.cancel();
      final spreset = turn.spreset;
      if (spreset != null) {
        unawaited(
          _trackOperation(spreset.close()).catchError((Object error) {
            spreset.diagnose('close', error);
          }),
        );
      }
      // The capture remains in _operations until its real library read ends.
      // Its I/O must not delay the cancelled turn's terminal stream or done.
      unawaited(turn.toolPolicyCapture?.drainStarted());
      if (!turn.modelDrained.isCompleted) {
        turn.modelDrained.complete();
      }
      turn.finished = true;
      if (identical(_turns[chatId], turn)) _turns.remove(chatId);
      if (!turn.done.isCompleted) turn.done.complete();
      // A paused consumer can delay stream.close forever. It must not hold the
      // database, a mutation, or engine.close hostage.
      for (final observer in turn.observers) {
        unawaited(observer.close());
      }
      turn.observers.clear();
      _scripts.publishSent(
        turn.sent ?? turn.groupRound?.sent,
        generationId: turn.generationId,
        cancellation: turn.cancellation,
      );
      _scripts.ended(turn);
      _notifyLists(resourcesChanged: false);
      turn.profile?.mark('cleanup');
      turn.profile?.finish(turn.kind.name);
    }
  }

  Future<({List<WorldInfoBook> loaded, List<Map<String, Object?>> missing})> _loadBooks(
    String characterId,
    Map<String, Object?> data,
    Map<String, Object?> settings, {
    String? personaId,
    Map<String, String> stWorldNames = const {},
    void Function()? checkCancelled,
    _GroupView? group,
    _GameplayResources gameplayResources = const _GameplayResources(),
  }) async {
    final result = <WorldInfoBook>[];
    final missing = <Map<String, Object?>>[];
    final bindings = _map(settings['lorebooks']);
    final characterCards = group == null
        ? <String, Map<String, Object?>>{characterId: data}
        : {
            for (final member in group.group.members)
              member.characterId: group.cards[member.characterId]?.card.data ?? <String, Object?>{},
          };
    final primaries = await _scripts._captureCharacterPrimaryBooks(settings, characterCards);
    for (final entry in primaries.entries) {
      if (entry.value.issue(entry.key) case final issue?) missing.add(_characterBookMissing(issue));
    }
    for (final source in WorldInfoSource.values) {
      final ids = <String>[
        ..._strings(bindings[source.name]),
        if (source == WorldInfoSource.character)
          for (final entry in primaries.entries) ..._characterLinkedBookIds(settings, entry.key, primary: entry.value),
        if (source == WorldInfoSource.persona && personaId != null)
          ..._strings(_map(settings['personaLorebooks'])[personaId]),
      ];
      for (final id in ids) {
        checkCancelled?.call();
        final saved = await _readBookSnapshot(id);
        checkCancelled?.call();
        if (saved == null) {
          missing.add({'bookId': id, 'source': source.name, 'reason': 'missing'});
          continue;
        }
        result.add(
          _compiledBook(id: id, source: source, json: saved.raw, stWorldName: stWorldNames[id] ?? saved.stWorldName),
        );
      }
    }
    checkCancelled?.call();
    final embeddedBooks = <WorldInfoBook>[];
    for (final card in characterCards.entries) {
      final embedded = card.value['character_book'];
      if (embedded is Map<String, Object?>) {
        embeddedBooks.add(_compiledBook(id: '${card.key}:card', source: WorldInfoSource.character, json: embedded));
      }
    }
    return (loaded: _mergeGameplayBooks(result, embeddedBooks, gameplayResources), missing: missing);
  }

  Future<void> _consume(_Turn turn, Map<String, Object?> body, {_OrdinaryToolRequest? request}) async {
    final completed = Completer<void>();
    void fail(Object error, StackTrace stack) {
      if (!completed.isCompleted) completed.completeError(error, stack);
    }

    unawaited(
      turn.cancellation.whenCancelled.then<void>((_) {
        fail(const TavernModelException(TavernFailure.cancelled, 'cancelled'), StackTrace.current);
      }),
    );
    StreamSubscription<({ModelDelta delta, String? text})>? subscription;
    final requestCancellation = _gameplayRequestCancellation(this, turn.gameplayAdmission, turn.cancellation);
    final requestContext = request == null && turn.spreset == null
        ? null
        : ModelRequestContext(
            preparedBody: turn.spreset != null,
            onResponseStarted: turn.spreset?.observeResponseStarted,
            onResponseFrame: turn.spreset?.nativeResponseFrameObserver,
            onResponseBytes: turn.spreset?.observeResponseBytes,
            onResponseSecret: turn.spreset?.observeResponseSecret,
            cancellation: requestCancellation,
            onUsageReport: (report) {
              if (completed.isCompleted) return;
              try {
                if (request != null) _recordOrdinaryUsage(this, turn, request, report);
              } catch (error, stack) {
                fail(error, stack);
              }
            },
          );
    var streamingWrites = false;
    try {
      turn.cancellation.check();
      if (turn.kind != _TurnKind.impersonate) {
        _store.beginStreamingWrites();
        streamingWrites = true;
        turn.flushTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
          if (completed.isCompleted) return;
          try {
            _checkpointBody(turn);
          } catch (error, stack) {
            fail(error, stack);
          }
        });
      }
      _requireOrdinaryOwnership(this, turn, StoredToolPhase.owned);
      if (request != null &&
          !_stateJsonEqual(
            request.authorization.toJson(),
            toolWireAuthorization(
              config: turn.config,
              body: body,
              policy: turn.toolPolicy!,
              showThoughts: turn.effectiveShowThoughts,
            ).toJson(),
          )) {
        throw const _ToolLoopFailure('protocol_invalid', 'The actual request authorization changed.');
      }
      final secretInspection = _prepareSecretRequest(this, turn);
      requestCancellation.check();
      if (secretInspection != null) {
        turn.secretRequestAttempted = true;
        _setInspection(turn, secretInspection);
      }
      final modelStream = _modelClient.generate(
        config: turn.config,
        body: body,
        cancellation: requestContext ?? requestCancellation,
        onRequestStarted: request == null
            ? null
            : (attempt) {
                if (completed.isCompleted) return;
                try {
                  _store.observeToolRequest(
                    request.snapshot.requestId,
                    sendAttempt: attempt,
                    onCommitted: (snapshot) {
                      request.snapshot = snapshot;
                    },
                  );
                } catch (error) {
                  request.diagnostics = {
                    ...request.diagnostics,
                    'sendObservationFailure': {'type': '${error.runtimeType}'},
                  };
                }
              },
      );
      final responseStream =
          turn.spreset?.response(modelStream, body) ?? modelStream.map((delta) => (delta: delta, text: null));
      final responsePrefix = turn.text!.toString();
      final responsePostfix =
          turn.kind == _TurnKind.continueReply && !turn.receivedText && !responsePrefix.endsWith(' ')
          ? turn.postfix
          : '';
      var previousProcessed = '';
      subscription = responseStream.listen(
        (packet) {
          if (completed.isCompleted || turn.cancellation.isCancelled) return;
          try {
            final delta = packet.delta;
            switch (delta) {
              case ModelToolFragment():
                turn.stateTools.add(delta);
                turn.stateWatch ??= Stopwatch()..start();
                return;
              case ModelText(:final text):
                if (packet.text case final processed?) {
                  final appended = processed.startsWith(previousProcessed)
                      ? processed.substring(previousProcessed.length)
                      : null;
                  final firstProcessed = previousProcessed.isEmpty;
                  previousProcessed = processed;
                  if (appended == '') return;
                  final postfix = responsePostfix;
                  turn.text = StringBuffer(responsePrefix + postfix + processed);
                  turn.receivedText = processed.isNotEmpty;
                  turn.dirty = true;
                  if (appended != null) {
                    turn.emit(TavernTextDelta(turn.reply!.nodeId, (firstProcessed ? postfix : '') + appended));
                  } else {
                    turn.emit(
                      TavernTurnSnapshot(
                        chatId: turn.chat.id,
                        generationType: turn.generationType,
                        startedAt: turn.at,
                        message: _buffered(turn),
                        logicalTurnId: turn.toolAdmitted ? turn.toolLogicalId : null,
                      ),
                    );
                  }
                  break;
                }
                if (text.isEmpty) return;
                var addition = text;
                if (turn.kind == _TurnKind.continueReply && !turn.receivedText) {
                  if (!turn.text!.toString().endsWith(' ')) addition = '${turn.postfix}$text';
                }
                turn.receivedText = true;
                turn.text!.write(addition);
                turn.dirty = true;
                turn.emit(TavernTextDelta(turn.reply!.nodeId, addition));
              case ModelReasoning(:final text):
                if (text.isEmpty || !turn.effectiveShowThoughts) return;
                turn.reasoning!.write(text);
                turn.dirty = true;
                turn.emit(TavernReasoningDelta(turn.reply!.nodeId, text));
              case ModelUsage(:final usage, :final report):
                if (request != null) {
                  _recordOrdinaryUsage(
                    this,
                    turn,
                    request,
                    report ?? ModelUsageReport.legacyNormalized(observationIndex: request.legacyObservationIndex++),
                    normalizedUsage: usage,
                  );
                }
                if (turn.toolRequests.length < 2) {
                  turn.usage = usage;
                  _setInspection(turn, turn.inspection.copyWith(reportedUsage: usage));
                }
              case ModelFinished(:final reason, :final assistantSnapshot, :final finalUsageReport):
                if (request != null) {
                  request.assistant = assistantSnapshot;
                  request.finishReason = reason;
                  request.responseComplete = true;
                  if (finalUsageReport != null) _recordOrdinaryUsage(this, turn, request, finalUsageReport);
                }
                turn.finishReason = reason;
                completed.complete();
                return;
            }
            turn.hasOutput = true;
          } catch (error, stack) {
            fail(error, stack);
          }
        },
        onError: (Object error, StackTrace stack) => fail(error, stack),
        onDone: () {
          if (!completed.isCompleted) completed.complete();
        },
        cancelOnError: true,
      );
      _adoptPromptWindow(turn);
      await completed.future;
    } finally {
      requestContext?.closeObservations();
      turn.flushTimer?.cancel();
      // The transport owns its HTTP client. Cancelling an async* subscription
      // can itself wait for I/O, so no tree mutation depends on this Future.
      subscription?.cancel().ignore();
      if (streamingWrites) _store.endStreamingWrites();
    }
  }

  void _finishRegex(_Turn turn) {
    final environment = turn.environment;
    if (turn.writeBackAttempted || !turn.hasOutput || turn.reply == null || environment == null) return;
    final started = turn.profile?.now;
    // A finish, stop, failed transport and late onDone may converge here. Mark
    // before evaluating user scripts, including scripts that later throw.
    turn.writeBackAttempted = true;
    final local = _runtimeCopy(environment.local);
    final global = _globalVariables.checkpoint();
    final history = List<StoredNode>.of(environment.history);
    final hash = environment.chatIdHash;
    final raw = _buffered(turn);
    try {
      final index = environment.history.indexWhere((node) => node.message.nodeId == raw.nodeId);
      final node = StoredNode(
        message: raw,
        depth: index < 0 ? history.length : index,
        extra: const {},
        original: const {},
      );
      if (index < 0) {
        environment.history.add(node);
      } else {
        environment.history[index] = node;
      }
      final text = environment.regex.apply(
        raw.text,
        placement: turn.kind == _TurnKind.impersonate ? RegexPlacement.userInput : RegexPlacement.aiOutput,
        expand: environment.regexExpand,
      );
      final reasoning = environment.regex.apply(
        raw.reasoning ?? '',
        placement: RegexPlacement.reasoning,
        expand: environment.regexExpand,
      );
      turn.text = StringBuffer(text);
      turn.reasoning = StringBuffer(reasoning);
      turn.dirty = true;
    } catch (_) {
      environment.local
        ..clear()
        ..addAll(local);
      _globalVariables.rollback(global);
      environment.history
        ..clear()
        ..addAll(history);
      environment.chatIdHash = hash;
      // Buffers are still the complete raw response. The preparation-stage
      // effects present in the saved snapshots above are intentionally kept.
      rethrow;
    } finally {
      turn.profile?.record('writeback_regex', started!);
    }
  }

  void _checkpointBody(_Turn turn) {
    if (!turn.dirty || turn.reply == null || turn.kind == _TurnKind.impersonate) return;
    final started = turn.profile?.now;
    try {
      final message = _buffered(turn, includeUsage: false);
      _store.writeOwnedStreamingBody(
        turn.toolOwner!,
        text: message.text,
        reasoning: message.reasoning,
        onCommitted: (committed) {
          turn.lastCommitted = committed.value;
          turn.dirty = false;
          turn.toolPhase = committed.ownership.phase;
        },
      );
    } finally {
      turn.profile?.record('stream_checkpoint', started!);
    }
  }

  // Ordinary completion/cancellation writes the inspection and indexes the
  // final body once, in the same FULL transaction as usage and runtime state.
  // A failed transaction can be retried by the terminal failure path.
  void _commitTurn(
    _Turn turn,
    TavernTurnInspection inspection, {
    _StateSettlement? stateSettlement,
    _StorySettlement? storySettlement,
  }) {
    final message = _buffered(turn);
    final state = storySettlement?.state ?? stateSettlement?.state ?? turn.currentState;
    final ownAudit = stateSettlement?.ownAudit;
    if (stateSettlement != null) inspection = inspection.copyWith(state: stateSettlement.trace);
    final events = stateSettlement?.events;
    if (events != null) {
      inspection = inspection.copyWith(director: {...inspection.director, 'eventRules': events.trace});
    }
    if (storySettlement != null) {
      inspection = inspection.copyWith(director: {...inspection.director, 'story': storySettlement.trace});
    }
    inspection = _gameplayInspection(inspection, turn.gameplay);
    if (turn.kind != _TurnKind.impersonate) {
      _commitOrdinaryToolFinal(this, turn, inspection, state, ownAudit, stateSettlement, storySettlement);
      return;
    } else {
      _store.transaction(() {
        if (inspection.status == TavernInspectionStatus.completed) {
          _ensureAdoptedGameplay(this, turn, state, stateSettlement, storySettlement);
        }
        final leaf = turn.chat.currentLeafId;
        if (leaf != null && _impersonationStateChanged(turn.chat.id, leaf, state)) {
          _writeNodeState(turn.chat.id, leaf, state);
        }
        _store.updateChat(
          turn.chat.id,
          variables: _copy(turn.variables),
          metadata: _latestInspectionMetadata(_runtimeMetadata(_store.chat(turn.chat.id).metadata, state), inspection),
        );
        _writeStateRuns(_store, turn, stateSettlement, null);
        _writeStoryRun(_store, turn, storySettlement, null);
      });
      _liveVariables[turn.chat.id] = (leaf: turn.chat.currentLeafId, values: _runtimeCopy(turn.variables));
      turn.lastCommitted = message;
    }
    if (stateSettlement != null || storySettlement != null) {
      turn.state = _copy(state);
    }
    if (stateSettlement != null) turn.stateRunsWritten = true;
    if (storySettlement != null) turn.storyRunWritten = true;
    _setInspection(turn, inspection);
    turn.dirty = false;
  }

  TavernMessage _buffered(_Turn turn, {bool includeUsage = true}) {
    final reply = turn.reply!;
    if (turn.modelCommitted && includeUsage && turn.kind != _TurnKind.impersonate) {
      // A logical turn can still await RECEIVED after model SQL has drained.
      // Resume must show a handler's committed edit, not the old model buffer.
      return _store.message(turn.chat.id, reply.nodeId);
    }
    final reasoning = turn.reasoning!.toString();
    return TavernMessage(
      nodeId: reply.nodeId,
      parentId: reply.parentId,
      role: reply.role,
      speaker: reply.speaker,
      speakerCharacterId: reply.speakerCharacterId,
      text: turn.text!.toString(),
      reasoning: reasoning.isEmpty && reply.reasoning == null ? null : reasoning,
      at: reply.at,
      siblingIndex: reply.siblingIndex,
      siblingCount: reply.siblingCount,
      hidden: reply.hidden,
      usage: includeUsage ? turn.usage : null,
      reportedUsage: includeUsage ? turn.inspection.reportedUsage : null,
    );
  }

  /// The batch tail follows script writes. It owns only this new story
  /// settlement, never the prior actor's body/usage or stale inspection buffer.
  void _commitGroupStory(_Turn turn, _StorySettlement settlement) {
    final nodeId = turn.reply!.nodeId;
    final chat = _store.chat(turn.chat.id);
    if (chat.currentLeafId != nodeId || turn.groupRound!.cancellation.isCancelled) {
      throw const TavernModelException(TavernFailure.cancelled, 'group_anchor_changed');
    }
    final currentInspection = _nodeInspection(chat.id, nodeId);
    final inspection = currentInspection?.copyWith(
      director: {...currentInspection.director, 'story': settlement.trace},
    );
    _store.transaction(() {
      _ensureAdoptedGameplay(this, turn, settlement.state, null, settlement);
      final extra = _store.rawNodeExtra(chat.id, nodeId);
      final own = _map(extra['dshgo']);
      extra['dshgo'] = {
        ...own,
        ...?settlement.ownAudit,
        'tavernState': _copy(settlement.state),
        'inspection': ?inspection?.toJson(),
      };
      turn.lastCommitted = _store.updateMessage(chat.id, nodeId, extra: extra);
      _store.updateChat(
        chat.id,
        variables: _map(settlement.state['variables']),
        metadata: _runtimeMetadata(_store.chat(chat.id).metadata, settlement.state),
      );
      _writeStoryRun(_store, turn, settlement, nodeId);
    });
    turn.storyRunWritten = true;
    turn.state = _copy(settlement.state);
    turn.variables = _runtimeCopy(_map(turn.state['variables']));
    _liveVariables[chat.id] = (leaf: nodeId, values: _runtimeCopy(turn.variables));
    if (inspection != null) {
      _setInspection(turn, inspection);
    }
  }

  TavernMessage _latest(_Turn turn) =>
      turn.kind == _TurnKind.impersonate ? _buffered(turn) : _store.message(turn.chat.id, turn.reply!.nodeId);

  void _rollbackEmpty(
    _Turn turn,
    TavernTurnInspection failed, {
    _StateSettlement? stateSettlement,
    _StorySettlement? storySettlement,
  }) {
    if (turn.toolOwner != null) {
      if (stateSettlement != null) failed = failed.copyWith(state: stateSettlement.trace);
      final events = stateSettlement?.events;
      if (events != null) failed = failed.copyWith(director: {...failed.director, 'eventRules': events.trace});
      if (storySettlement != null) {
        failed = failed.copyWith(director: {...failed.director, 'story': storySettlement.trace});
      }
      _rollbackOrdinaryToolTurn(this, turn, failed, stateSettlement, storySettlement);
      return;
    }
    if (!turn.nativePreparationStarted) {
      // No native message, selection, local state or runtime was prepared.
      // Preserve successful handler writes and merge only this failure record
      // into the current stored metadata.
      _store.transaction(() => _writeLatestInspection(turn.chat.id, failed));
      _setInspection(turn, failed);
      return;
    }
    if (stateSettlement != null) failed = failed.copyWith(state: stateSettlement.trace);
    final events = stateSettlement?.events;
    if (events != null) {
      failed = failed.copyWith(director: {...failed.director, 'eventRules': events.trace});
    }
    if (storySettlement != null) {
      failed = failed.copyWith(director: {...failed.director, 'story': storySettlement.trace});
    }
    if (turn.kind == _TurnKind.impersonate) {
      _store.transaction(() {
        _writeInspection(failed);
        _writeStateRuns(_store, turn, stateSettlement, null);
        _writeStoryRun(_store, turn, storySettlement, null);
      });
      if (stateSettlement != null) turn.stateRunsWritten = true;
      if (storySettlement != null) turn.storyRunWritten = true;
      _setInspection(turn, failed);
      return;
    }
    _store.transaction(() {
      final original = turn.originalTarget;
      if (turn.kind == _TurnKind.continueReply && turn.reply != null && original != null) {
        final message = original.message;
        _store.updateMessage(
          turn.chat.id,
          message.nodeId,
          text: message.text,
          reasoning: message.reasoning,
          clearReasoning: message.reasoning == null,
          speakerCharacterId: message.speakerCharacterId,
          clearSpeakerCharacterId: message.speakerCharacterId == null,
          usage: message.usage,
          clearUsage: message.usage == null,
          extra: original.extra,
        );
      } else if (turn.reply != null) {
        _store.deleteFrom(turn.chat.id, turn.reply!.nodeId);
      }
      if (turn.newUserId != null) _store.deleteFrom(turn.chat.id, turn.newUserId!);
      final first = turn.originalFirstMessage;
      if (turn.firstMessageCommitted && first != null && first.message.nodeId != turn.newUserId) {
        _store.updateMessage(turn.chat.id, first.message.nodeId, text: first.message.text);
      }
      // Restore deepest choices first, then the old active leaf. Selecting a
      // child only rewrites its ancestors, never its remembered descendants.
      for (final selection in turn.previousSelections.reversed) {
        _store.selectNode(turn.chat.id, selection.$2 ?? selection.$1, restoreDescendants: selection.$2 != null);
      }
      if (turn.chat.currentLeafId != null) {
        _store.selectNode(turn.chat.id, turn.chat.currentLeafId!, restoreDescendants: false);
      } else {
        // Deleting a temporary root can select a surviving sibling. An old
        // empty path is an explicit selection too, even with roots retained.
        _store.clearSelection(turn.chat.id);
      }
      _store.updateChat(turn.chat.id, variables: turn.chat.variables);
      _writeLatestInspection(turn.chat.id, failed);
      _writeStateRuns(
        _store,
        turn,
        stateSettlement,
        turn.kind == _TurnKind.continueReply ? original?.message.nodeId : null,
      );
      _writeStoryRun(
        _store,
        turn,
        storySettlement,
        turn.kind == _TurnKind.continueReply ? original?.message.nodeId : null,
      );
    });
    if (stateSettlement != null) turn.stateRunsWritten = true;
    if (storySettlement != null) turn.storyRunWritten = true;
    _setInspection(turn, failed);
    _liveVariables[turn.chat.id] = (leaf: turn.chat.currentLeafId, values: _runtimeCopy(turn.originalVariables));
  }

  Stream<T> _watch<T>(Stream<void> changes, FutureOr<T> Function() snapshot) {
    late StreamController<T> controller;
    StreamSubscription<void>? subscription;
    var ended = false;
    var dirty = false;
    var pumping = false;
    Future<void> refresh() async {
      dirty = true;
      if (pumping) return;
      pumping = true;
      try {
        while (dirty && !ended && !_closing && !_closed) {
          // A watcher can rebuild derived character indexes. Reads that
          // already started belong to the backup's admitted operations;
          // later reads wait outside that set, avoiding a backup/self wait.
          final captureDone = _backupCaptureDone;
          if (captureDone != null) {
            await captureDone.future;
            continue;
          }
          dirty = false;
          try {
            final value = await _trackOperation(Future<T>.sync(snapshot));
            // A change during the first asynchronous file load must not be
            // lost, nor should it publish a knowingly stale initial snapshot.
            if (!ended && !_closing && !_closed && !dirty) controller.add(value);
          } catch (error, stack) {
            if (!ended && !_closing && !_closed) controller.addError(error, stack);
          }
        }
      } finally {
        pumping = false;
      }
    }

    controller = StreamController<T>(
      onListen: () {
        if (_closing || _closed) {
          ended = true;
          unawaited(controller.close());
          return;
        }
        subscription = changes.listen(
          (_) => unawaited(refresh()),
          onDone: () {
            ended = true;
            unawaited(controller.close());
          },
        );
        unawaited(refresh());
      },
      onCancel: () {
        ended = true;
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Future<TavernBackupInfo> backup(String destinationPath) {
    _ensureOpen();
    if (_backupInProgress ||
        _turns.isNotEmpty ||
        _groups.rounds.isNotEmpty ||
        _manualTools.isNotEmpty ||
        _directors.hasJobs) {
      return Future.error(const TavernModelException(TavernFailure.busy, 'backup_busy'));
    }
    // Close admission before draining. Capture the prior operations BEFORE
    // tracking this backup, otherwise it would wait on its own completion.
    _capturingBackup = true;
    _backupInProgress = true;
    _backupCaptureDone = Completer<void>();
    final admitted = List<Future<void>>.of(_operations);
    return _trackOperation(_createBackup(destinationPath, admitted));
  }

  Future<TavernBackupInfo> _createBackup(String destinationPath, List<Future<void>> admitted) async {
    backup_io.TavernBackupSnapshot? snapshot;
    try {
      try {
        await Future.wait(admitted);
        _authoringAuthority.reconcileLiveTickets();
        if (_authoringAuthority.pendingState().hasPending) {
          throw const TavernAuthoringException('pending_operation', 'The tavern has an unresolved file operation.');
        }
        snapshot = await backup_io.captureTavernBackup(
          directory,
          backupDatabase: _store.backupToFile,
          createdAt: _clock(),
        );
      } finally {
        _capturingBackup = false;
        final captureDone = _backupCaptureDone;
        _backupCaptureDone = null;
        captureDone?.complete();
      }
      return await snapshot.writeZip(File(destinationPath));
    } finally {
      try {
        await snapshot?.dispose();
      } finally {
        _backupInProgress = false;
      }
    }
  }

  static Future<void> _validateBackupStaging(Directory staging, int sourceSchemaVersion) async {
    await ChatStore.validateBackup(File('${staging.path}/tavern.sqlite3'), sourceSchemaVersion: sourceSchemaVersion);
    if (AuthoringAuthority.inspectRootReadOnly(staging).hasPending) {
      throw const TavernAuthoringException(
        'pending_operation',
        'The incoming backup has an unresolved file operation.',
      );
    }
    final probe = await TavernEngine.openDirectory(staging);
    try {
      // Use the existing versioned loaders; never reimport opaque card bytes,
      // recompile regex scripts, or replace recorded intake reports.
      final characters = await probe._library.list();
      for (final character in characters) {
        await probe._library.readImportReport(character.id);
      }
      probe._personas.list();
      for (final preset in probe._presetSummaries()) {
        probe._store.preset(preset.id);
      }
      await probe.listLorebooks();
      // Opening initialized legacy snapshots too. Rotate only after complete
      // staged validation, so old-domain drafts cannot adopt into this restore.
      probe._store.rotateAuthoringDomain();
    } finally {
      await probe.close();
    }
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    _cancelAuthoringRuns();
    for (final cancellation in _authoringPreviewCancellations) {
      cancellation.cancel();
    }
    _scripts.close();
    for (final group in _groups.rounds.values) {
      group.cancel();
    }
    for (final turn in _turns.values) {
      turn.cancellation.cancel();
    }
    for (final action in _manualTools.values) {
      action.cancellation.cancel();
    }
    await _directors.close();
    // Unblock guarded work before waiting for operations that may own it.
    await Future.wait([_regexWorker.close(), _keywordWorker.close()]);
    while (_turns.isNotEmpty ||
        _groups.rounds.isNotEmpty ||
        _manualTools.isNotEmpty ||
        _operations.isNotEmpty ||
        _scripts._generationDrains.isNotEmpty) {
      await Future.wait<void>([
        ..._operations,
        for (final turn in _turns.values) turn.done.future,
        for (final group in _groups.rounds.values) group.done.future,
        for (final action in _manualTools.values) action.done.future,
        ..._scripts._generationDrains,
      ]);
    }
    await _fileQueue;
    await _libraryQueue;
    await _personaQueue;
    await _presetQueue;
    await _bookQueue;
    await _personaSubscription.cancel();
    await _storeSubscription.cancel();
    _authoringRuns.clear();
    _liveVariables.clear();
    _latestInspections.clear();
    _inspections.clear();
    _chatPreviews.clear();
    _chatPreviewUnits = 0;
    _closed = true;
    unawaited(_charactersChanged.close());
    unawaited(_chatsChanged.close());
    unawaited(_globalScriptsChanged.close());
    unawaited(_scriptCatalogChanged.close());
    unawaited(_paths.close());
    await _personas.close();
    await _store.close();
    if (_releaseDirectoryOwnerOnClose) {
      _ownedTavernRoots.remove(_directoryOwnerKey);
    }
  }
}

class _DisplayQueue {
  int version = 0;
  bool running = false;
  _DisplayJob? pending;
}

class _DisplayChatView {
  _DisplayChatView(this.version, this.chat);
  final Object version;
  final StoredChat chat;
  final nodes = <String, StoredNode>{};
  final positions = <String, ({bool onCurrentPath, int? depth})>{};
  final contexts = <String?, _DisplayContext>{};
  StoredNode node(ChatStore store, String id) => nodes.putIfAbsent(id, () => store.displayNode(chat.id, id));
}

class _DisplayContext {
  _DisplayContext(this.state, this.metadata, this.history, this.chatIdentity);
  final Map<String, Object?> state;
  final Map<String, Object?> metadata;
  final StoredDisplayHistory history;
  final String chatIdentity;

  MacroHistorySnapshot historySnapshot({String? overlayNodeId, required String text}) {
    MacroMessage message(StoredNode node) => MacroMessage(
      text: node.message.nodeId == overlayNodeId ? text : node.message.text,
      isUser: node.message.role == TavernRole.user,
      isSystem: node.message.hidden || _systemMessage(node),
      swipeId: node.message.siblingIndex,
      swipeCount: node.message.siblingCount,
      sentAt: node.message.at,
    );
    ({int index, MacroMessage message})? entry(StoredNode? node) =>
        node == null ? null : (index: node.depth - 1, message: message(node));
    return MacroHistorySnapshot(
      length: history.length,
      last: entry(history.last),
      user: entry(history.user),
      character: entry(history.character),
      previousUser: history.previousUser == null ? null : message(history.previousUser!),
    );
  }
}

class _DisplayJob {
  _DisplayJob(
    this.version,
    this.chatId,
    this.nodeId,
    this.text,
    this.role,
    this.depth,
    this.reasoning,
    this.characterOverride,
    this.isSystem,
    this.profile,
  );
  final int version;
  final String chatId;
  final String? nodeId;
  final String text;
  final TavernRole role;
  final num? depth;
  final bool reasoning;
  final String? characterOverride;
  final bool isSystem;
  final _TurnProfile? profile;
  final result = Completer<TavernDisplayResult>();
}

int _displaySeed(String identity) {
  var hash = 2166136261;
  for (final unit in identity.codeUnits) {
    hash = ((hash ^ unit) * 16777619) & 0x7fffffff;
  }
  return hash;
}

class _PreparationSaveFailure implements Exception {
  const _PreparationSaveFailure(
    this.createError,
    this.createStackTrace,
    this.saveError,
    this.saveStackTrace, {
    this.operation = 'createChat',
  });
  final String operation;
  // Keep the original createChat error/stack fields for callers inspecting
  // both failures; manual-message preparation uses the same carrier.
  final Object createError;
  final StackTrace createStackTrace;
  final Object saveError;
  final StackTrace saveStackTrace;
  @override
  String toString() =>
      '$operation failed: $createError\n'
      'Saving global variables also failed: $saveError';
}

class _GlobalWrite {
  const _GlobalWrite(this.revision, this.key, this.present, this.value);
  final int revision;
  final String key;
  final bool present;
  final Object? value;
}

/// Native macros share a live Map, while persistence records their already
/// computed root set/remove intent. File commits adopt only their own prefix;
/// writes made while an earlier file operation awaited I/O remain visible.
class _NativeGlobals extends MapBase<String, Object?> {
  _NativeGlobals(Map<String, Object?> value) : _base = _runtimeCopy(value), _values = _runtimeCopy(value);

  Map<String, Object?> _base;
  final Map<String, Object?> _values;
  final List<_GlobalWrite> _pending = [];
  int revision = 0;
  // Internal runtime identity is deliberately independent of public JSON CAS
  // and journal serials: adoption can change Inf/null or settle pending intent.
  int observation = 0;

  @override
  Object? operator [](Object? key) => _values[key];

  @override
  void operator []=(String key, Object? value) {
    // Same-value assignments are still intent: an earlier queued replace may
    // change this key before this native operation reaches its own save.
    _pending.add(_GlobalWrite(++revision, key, true, _runtimeValue(value)));
    observation++;
    _values[key] = _runtimeValue(value);
  }

  @override
  Object? remove(Object? key) {
    if (key is! String) {
      return null;
    }
    // An absent key must likewise retain its explicit delete intent.
    _pending.add(_GlobalWrite(++revision, key, false, null));
    observation++;
    return _values.remove(key);
  }

  @override
  void clear() {
    for (final key in _values.keys.toList()) {
      remove(key);
    }
  }

  @override
  bool containsKey(Object? key) => _values.containsKey(key);

  @override
  Iterable<String> get keys => _values.keys;

  bool changedSince(int before) => _pending.any((write) => write.revision > before);
  bool hasThrough(int through) => _pending.any((write) => write.revision <= through);

  Map<String, Object?> project(int through) {
    final result = _runtimeCopy(_base);
    for (final write in _pending) {
      if (write.revision <= through) {
        _apply(result, write);
      }
    }
    return result;
  }

  void commit(Map<String, Object?> runtime, int through) {
    observation++;
    _base = _runtimeCopy(runtime);
    _pending.removeWhere((write) => write.revision <= through);
    _values
      ..clear()
      ..addAll(_runtimeCopy(_base));
    for (final write in _pending) {
      _apply(_values, write);
    }
  }

  ({int revision, Map<String, Object?> values}) checkpoint() => (revision: revision, values: _runtimeCopy(_values));

  // Only the caller's synchronous edit/output-regex segment uses this. It
  // cannot span an await or undo a successful file commit; serials never reset.
  void rollback(({int revision, Map<String, Object?> values}) checkpoint) {
    if (_pending.any((write) => write.revision > checkpoint.revision) ||
        _scriptRuntimeFingerprint(_values) != _scriptRuntimeFingerprint(checkpoint.values)) {
      observation++;
    }
    _pending.removeWhere((write) => write.revision > checkpoint.revision);
    _values
      ..clear()
      ..addAll(_runtimeCopy(checkpoint.values));
  }

  static void _apply(Map<String, Object?> values, _GlobalWrite write) {
    if (write.present) {
      values[write.key] = _runtimeValue(write.value);
    } else {
      values.remove(write.key);
    }
  }
}

enum _TurnKind { send, regenerate, continueReply, impersonate }

class _Turn {
  _Turn(
    this.chat,
    this.kind,
    this.input,
    this.nodeId,
    StreamController<TavernEvent>? controller,
    this.config,
    this.settings,
    this.at,
    this.personaSelection,
    this.metadata,
    this.sourceFile,
    this.presetId, {
    String? actorId,
    this.groupView,
    this.groupRound,
    this.gameplayAdmission,
    this.gameplay,
    _TurnProfile? profile,
    String? previewId,
    ModelCancellation? previewCancellation,
  }) : actorId = actorId ?? chat.characterId,
       profile = previewId == null ? profile ?? _TurnProfile.start() : null,
       cancellation = previewCancellation ?? ModelCancellation(),
       generationId = previewId ?? 'generation-${_newStateId()}' {
    if (controller != null) observers.add(controller);
    if (previewId != null) {
      stateInvocationId = '$previewId:state';
    }
    inspection = TavernTurnInspection(
      chatId: chat.id,
      contextNodeId: chat.currentLeafId,
      generationType: generationType,
      startedAt: at,
    );
  }
  late TavernTurnInspection inspection;
  final _TurnProfile? profile;
  _PendingPromptWindow? pendingPromptWindow;
  StoredChat chat;
  final _TurnKind kind;
  final String input;
  final String? nodeId;
  final observers = <StreamController<TavernEvent>>{};
  final TavernModelConfig config;
  final Map<String, Object?> settings;
  final DateTime at;
  final PersonaSelection personaSelection;
  Map<String, Object?> metadata;
  String? sourceFile;
  final String? presetId;
  final String actorId;
  _GroupView? groupView;
  final _GroupRound? groupRound;
  _GameplayAdmission? gameplayAdmission;
  _GameplayRuntime? gameplay;
  _GameplayRuntime? gameplayPreviousConfig;
  _GameplayResources gameplayResources = const _GameplayResources();
  bool gameplayValueEligible = true;
  bool gameplayInitializing = false;
  bool gameplayInitialized = false;
  void Function(TavernEvent)? onEvent;
  final ModelCancellation cancellation;
  final String generationId;
  String get toolLogicalId => generationId;
  StoredToolTurnOwner? toolOwner;
  StoredToolPhase? toolPhase;
  bool toolAdmitted = false;
  bool terminalStorageAdopted = false;
  bool replyCommitAdopted = false;
  bool normalFinalAdopted = false;
  String? toolFailureCode;
  bool modelTerminal = false;
  TavernToolPolicySnapshot? toolPolicyScope;
  ToolCapturedPolicy? toolPolicy;
  _ToolPolicyCapture? toolPolicyCapture;
  var toolRequests = <_OrdinaryToolRequest>[];
  _OrdinaryToolRequest? toolRequest;
  TavernToolSourceToken? newUserSource;
  TavernToolSourceToken? firstMessageSource;
  TavernToolSourceToken? committedFirstMessageSource;
  StoredToolCleanupFacts? toolCleanupFacts;
  final modelDrained = Completer<void>();
  bool modelCommitted = false;
  bool scriptWritesAllowed = false;
  bool nativePreparationStarted = false;
  _ScriptInjectionUseSet? scriptInjectionUses;
  final hookIssues = <TavernScriptIssue>[];
  final done = Completer<void>();
  bool finished = false;
  bool terminal = false;
  TavernEvent? terminalEvent;
  bool hasOutput = false;
  bool receivedText = false;
  bool dirty = false;
  String? newUserId;
  _ScriptSent? sent;
  StoredNode? originalTarget;
  StoredNode? originalFirstMessage;
  String? expandedFirstMessage;
  bool firstMessageCommitted = false;
  TavernMessage? reply;
  TavernMessage? lastCommitted;
  StringBuffer? text;
  StringBuffer? reasoning;
  TavernUsage? usage;
  String? finishReason;
  Timer? flushTimer;
  String postfix = '';
  Map<String, Object?> variables = {};
  Map<String, Object?> state = {};
  Map<String, Object?> originalVariables = {};
  final previousSelections = <(String, String?)>[];
  _MacroEnvironment? environment;
  bool effectiveShowThoughts = true;
  bool get effectiveThinking => config.deepseek ? effectiveShowThoughts : config.thinking;
  _SPresetGeneration? spreset;
  PromptInput? spresetPromptInput;
  _MvuResources? mvuResources;
  _MvuTurnBase? mvuBase;
  bool writeBackAttempted = false;
  state_core.StateDefinition? stateDefinition;
  bool stateAutomatic = false;
  bool stateToolAllowed = false;
  String? stateInvocationId;
  Stopwatch? stateWatch;
  var stateTools = ModelToolAccumulator();
  final stagedStateCalls = <_StagedStateCall>[];
  final stagedStateBatches = <_StagedStateBatch>[];
  final statePreparationIssues = <Map<String, Object?>>[];
  final stateOfferedPrompts = <String, String>{};
  final stateSentPrompts = <String>{};
  _StateSettlement? stateAttempt;
  state_core.StateSession? stateSession;
  state_core.StateSecretPrepared? secretPrepared;
  StoredAgentRun? secretCaptured;
  Map<String, Object?>? secretAttempt;
  int? secretCardRevision;
  bool stateSettlementStarted = false;
  final secretIssues = <Map<String, Object?>>[];
  _SecretProtection? secretProtection;
  final secretOffered = <String, Map<String, Object?>>{};
  final secretIncluded = <String>{};
  bool secretRequestAttempted = false;
  bool stateRunsWritten = false;
  StoredAgentRun? directorCaptured;
  _DirectorPrepared? directorPrepared;
  Map<String, Object?>? directorCard;
  state_core.CardEventDefinition? cardEventDefinition;
  final cardEventAuthorizedHandlers = <String>{};
  final cardEventAuthorizedHandlerRefs = <state_core.CardEventHandlerRef>{};
  final cardEventOfferedPackPrompts = <String, _GameplayEventPromptRef>{};
  final cardEventSentPackPrompts = <_GameplayEventPromptRef>{};
  final cardEventProposals = <state_core.CardEventProposal>[];
  final cardEventPreparationIssues = <Map<String, Object?>>[];
  final cardEventOfferedPrompts = <String, String>{};
  final cardEventSentPrompts = <String>{};
  Map<String, Object?>? cardEventSource;
  String? cardEventInvocationId;
  bool cardEventTerminalEnabled = false;
  String? storyInvocationId;
  _StorySettlement? storyAttempt;
  bool storyRunWritten = false;
  Map<String, Object?> get currentState => {
    ..._copy(state),
    'variables': _copy(variables),
    if (environment != null) 'stChatId': environment!.chatId,
    if (environment != null) 'stChatIdHash': environment!.chatIdHash,
  };
  String get generationType => switch (kind) {
    _TurnKind.send => 'normal',
    _TurnKind.regenerate => 'regenerate',
    _TurnKind.continueReply => 'continue',
    _TurnKind.impersonate => 'impersonate',
  };
  void begin(TavernMessage message) {
    reply = message;
    lastCommitted = message;
    text = StringBuffer(message.text);
    reasoning = StringBuffer(message.reasoning ?? '');
    usage = message.usage;
  }

  void emit(TavernEvent event) {
    if (terminal) return;
    if (event is TavernTurnDone || event is TavernTurnFailed) {
      terminalEvent = event;
    }
    onEvent?.call(event);
    for (final observer in observers) {
      if (!observer.isClosed) observer.add(event);
    }
  }
}

TavernMessage _withReportedUsage(TavernMessage message, TavernUsage? usage, {bool replaceUsage = false}) =>
    TavernMessage(
      nodeId: message.nodeId,
      parentId: message.parentId,
      role: message.role,
      speaker: message.speaker,
      speakerCharacterId: message.speakerCharacterId,
      text: message.text,
      reasoning: message.reasoning,
      at: message.at,
      siblingIndex: message.siblingIndex,
      siblingCount: message.siblingCount,
      hidden: message.hidden,
      usage: replaceUsage ? usage : message.usage,
      reportedUsage: usage,
    );

class _MacroEnvironment {
  _MacroEnvironment(
    this.card,
    this.settings,
    this.local,
    this.global,
    this.history,
    this.config,
    this.now,
    this.random,
    this.chatId,
    this.input,
    this.generationType, {
    this.chatIdHash,
    this.pickRerollSeed,
    this.characterId = '',
    this.groupNames,
    this.groupNotMuted,
    ChatPreset? preset,
    Map<String, Object?>? regexPresetSettings,
    this.macroHistory,
    this.macroHistorySnapshot,
    this.messageVariables,
    this.messageVariablesExists = false,
    this.onCharacterDependency,
    this.prepareCharacterFieldsOnDemand = false,
    this.collapseNewlinesOverride,
    this.packRegex = const [],
    this.gameplayCapture,
  }) {
    final raw = _readMap(settings['preset']);
    _presetSettings = (preset ?? _readPreset(raw)).executionSettings;
    _regexPresetSettings = regexPresetSettings ?? _presetSettings;
  }
  final Map<String, Object?> card;
  final Map<String, Object?> settings;
  final Map<String, Object?> local;
  final Map<String, Object?> global;
  final List<StoredNode> history;
  final List<MacroMessage>? macroHistory;
  final MacroHistorySnapshot? macroHistorySnapshot;
  final Object? messageVariables;
  final bool messageVariablesExists;
  final void Function(String)? onCharacterDependency;
  final bool prepareCharacterFieldsOnDemand;
  final bool? collapseNewlinesOverride;
  final List<TavernScriptRegex> packRegex;
  final _GameplayResourceCapture? gameplayCapture;
  late final List<TavernScriptRegex> _capturedPackRegex = gameplayCapture == null
      ? packRegex
      : _resolveGameplayResources(
          gameplayCapture!,
          settings,
          actorId: characterId.isEmpty ? null : characterId,
          kinds: const {'regex'},
        ).regex;
  final TavernModelConfig config;
  final DateTime now;
  final double Function() random;
  final String chatId;
  num? chatIdHash;
  final Object? pickRerollSeed;
  final String characterId;
  final List<String>? groupNames;
  final List<String>? groupNotMuted;
  final String input;
  final String generationType;
  final outlets = <String, String>{};
  late final Map<String, Object?> _presetSettings;
  late final Map<String, Object?> _regexPresetSettings;
  late final _spresetRegexConfig = SPresetConfig.fromPreset({
    ..._regexPresetSettings,
    if (settings['spresetRuntimeMode'] == 'external') 'dsh_spreset_runtime': 'external',
  });
  late final RegexEngine regex = RegexEngine(
    globalScripts: [
      ...RegexEngine.readScripts(
        spresetGlobalRegexes(settings['globalRegexScripts'] ?? settings['regex'], _spresetRegexConfig),
      ),
      ...RegexEngine.readScripts(spresetGlobalRegexes(settings['managedRegexScripts'], _spresetRegexConfig)),
      for (final rule in _capturedPackRegex)
        if (rule.source == TavernScriptRegexSource.global) rule.execution,
    ],
    scopeOrder: spresetRegexOrder(_spresetRegexConfig, settings),
    presetScripts: settings['presetRegexEnabled'] == false
        ? const []
        : _readRegexScripts(_spresetRegexConfig.presetRegexes(_regexPresetSettings)),
    characterScripts:
        settings['characterRegexEnabled'] == false || _strings(settings['disabledCharacterRegex']).contains(characterId)
        ? const []
        : [
            ..._readRegexScripts(_readMap(card['extensions'])['regex_scripts']),
            for (final rule in _capturedPackRegex)
              if (rule.source == TavernScriptRegexSource.character) rule.execution,
          ],
    chatScripts: [
      for (final rule in _capturedPackRegex)
        if (rule.source == TavernScriptRegexSource.chat) rule.execution,
    ],
    enabled: settings['regexEnabled'] != false,
  );

  bool get legacy =>
      settings['macroEngine'] == 'legacy' ||
      (settings['macroEngine'] == null && settings['experimental_macro_engine'] == false);
  String get userName => settings['userName'] is String ? settings['userName'] as String : 'User';
  String get persona => _string(settings['persona']);
  int get maxContext => presetNumber(_presetSettings['openai_max_context'], 4095).toInt();
  int get maxResponse => presetNumber(_presetSettings['openai_max_tokens'], 300).toInt();

  String expand(String text, Map<String, String> overrides) => _expand(text, overrides, true);
  String baseExpand(String text, Map<String, String> overrides) => _expand(text, overrides, false);
  String regexExpand(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) =>
      _expand(text, const {}, true, characterOverride: characterOverride, postProcess: postProcess);

  late final MacroContext _context = MacroContext(
    localVariables: local,
    globalVariables: global,
    card: card,
    group: groupNames?.join(', '),
    groupNotMuted: groupNotMuted?.join(', '),
    userName: userName,
    persona: persona,
    history: macroHistory ?? _MacroHistory(history),
    historySnapshot: macroHistorySnapshot,
    messageVariables: messageVariables,
    messageVariablesExists: messageVariablesExists,
    model: config.model,
    input: input,
    maxContext: maxContext,
    maxResponse: maxResponse,
    lastGenerationType: generationType,
    now: now,
    timeZoneOffset: now.timeZoneOffset,
    locale: _string(settings['locale']).isEmpty ? 'en' : _string(settings['locale']),
    random: random,
    chatId: chatId,
    chatIdHash: chatIdHash,
    onChatIdHash: (value) {
      if (chatIdHash == null || (legacy && chatIdHash == 0)) chatIdHash = value;
    },
    pickRerollSeed: pickRerollSeed,
    outlets: outlets,
    extensions: _strings(settings['extensions']).toSet(),
    preferCharacterPrompt: _presetSettings['prefer_character_prompt'] != false,
    preferCharacterJailbreak: _presetSettings['prefer_character_jailbreak'] != false,
    collapseNewlines: collapseNewlinesOverride ?? settings['collapseNewlines'] == true,
    systemPromptOverride: settings['systemPromptOverride'] as String?,
    scenarioOverride: settings['scenarioOverride'] as String?,
    mesExamplesOverride: settings['mesExamplesOverride'] as String?,
    onCharacterDependency: onCharacterDependency,
  );

  String _expand(
    String text,
    Map<String, String> overrides,
    bool replaceCard, {
    String? characterOverride,
    Object? Function(Object?)? postProcess,
  }) {
    return legacy
        ? const LegacyMacroEngine().expand(
            text,
            _context,
            overrides: overrides,
            postProcess: postProcess,
            replaceCharacterCard: replaceCard,
            characterOverride: characterOverride,
            prepareCharacterFieldsOnDemand: prepareCharacterFieldsOnDemand,
          )
        : const MacroEngine().expand(
            text,
            _context,
            overrides: overrides,
            postProcess: postProcess,
            replaceCharacterCard: replaceCard,
            characterOverride: characterOverride,
          );
  }
}

/// A turn keeps its stored-node list live as input, greeting and write-back
/// preparation append or replace nodes. Project each unchanged node once, not
/// the entire path on every macro call. Rollback is visible by node identity.
class _MacroHistory extends ListBase<MacroMessage> {
  _MacroHistory(this._nodes);
  final List<StoredNode> _nodes;
  final _cache = <({StoredNode node, MacroMessage message})?>[];

  @override
  int get length => _nodes.length;
  @override
  set length(int value) => throw UnsupportedError('Macro history is read-only.');

  @override
  MacroMessage operator [](int index) {
    RangeError.checkValidIndex(index, _nodes);
    if (_cache.length != _nodes.length) _cache.length = _nodes.length;
    final node = _nodes[index];
    final cached = _cache[index];
    if (cached != null && identical(cached.node, node)) return cached.message;
    final message = MacroMessage(
      text: node.message.text,
      isUser: node.message.role == TavernRole.user,
      isSystem: node.message.hidden || _systemMessage(node),
      swipeId: node.message.siblingIndex,
      swipeCount: node.message.siblingCount,
      sentAt: node.message.at,
    );
    _cache[index] = (node: node, message: message);
    return message;
  }

  @override
  void operator []=(int index, MacroMessage value) => throw UnsupportedError('Macro history is read-only.');
}

class _ConfiguredInjection {
  const _ConfiguredInjection(this.injection, {this.scan = false, this.authorNote = false});
  final PromptInjection injection;
  final bool scan;
  final bool authorNote;
}

List<_ConfiguredInjection> _configuredInjections(
  Map<String, Object?> settings,
  PreparedCharacterFields prepared,
  Map<String, Object?> card, {
  required int userMessageCount,
}) {
  final result = <_ConfiguredInjection>[];
  final note = _map(settings['authorNote']);
  final interval = note['interval'];
  final noteDue =
      interval == null ||
      interval == 1 ||
      (interval is num && interval > 0 && userMessageCount > 0 && userMessageCount % interval == 0);
  if (note.isNotEmpty && note['enabled'] != false && noteDue) {
    result.add(
      _ConfiguredInjection(
        _injection(note, '2_floating_prompt', kind: 'authorNote'),
        scan: note['scan'] == true,
        authorNote: true,
      ),
    );
  }
  final depth = _readMap(_readMap(card['extensions'])['depth_prompt']);
  if (prepared['charDepthPrompt'].isNotEmpty) {
    result.add(
      _ConfiguredInjection(
        PromptInjection(
          fragment: PromptFragment(prepared['charDepthPrompt'], const PromptSource('card', 'DEPTH_PROMPT')),
          depth: _injectionDepth(depth['depth']),
          role: _role(depth['role']),
        ),
        scan: settings['scanDepthPrompt'] == true,
      ),
    );
  }
  final injections = settings['injections'];
  if (injections is List<Object?>) {
    for (var index = 0; index < injections.length; index++) {
      final value = injections[index];
      if (value is! Map<String, Object?> || value['enabled'] == false) continue;
      final id = _string(value['id']);
      result.add(
        _ConfiguredInjection(_injection(value, id.isEmpty ? 'custom-$index' : id), scan: value['scan'] == true),
      );
    }
  }
  return result;
}

PromptInjection _injection(Map<String, Object?> value, String id, {String kind = 'extension'}) => PromptInjection(
  fragment: PromptFragment(_string(value['content']), PromptSource(kind, id)),
  role: _role(value['role']),
  depth: _injectionDepth(value['depth']),
  order: _integer(value['order'], 100),
  placement: switch (value['placement']) {
    'beforeMain' => PromptPlacement.beforeMain,
    'afterMain' => PromptPlacement.afterMain,
    _ => PromptPlacement.inChat,
  },
);

List<PromptInjection> _finishInjections(
  List<_ConfiguredInjection> initial,
  WorldInfoResult world, {
  bool deepseek = false,
}) {
  final result = <PromptInjection>[];
  for (final item in initial) {
    final injection = item.injection;
    if (!item.authorNote) {
      result.add(injection);
      continue;
    }
    final before = world.authorNoteBefore.map((hit) => hit.content).join('\n');
    final after = world.authorNoteAfter.map((hit) => hit.content).join('\n');
    // ST removes one leading/trailing newline, not arbitrary whitespace.
    final content = '$before\n${injection.fragment.content}\n$after'.replaceAll(RegExp(r'(^\n)|(\n$)'), '');
    result.add(
      PromptInjection(
        fragment: PromptFragment(
          content,
          PromptSource(
            'authorNote',
            injection.fragment.source.id,
            details: {
              'worldInfo': [
                for (final hit in [...world.authorNoteBefore, ...world.authorNoteAfter]) _worldSource(hit).toJson(),
              ],
            },
          ),
        ),
        placement: injection.placement,
        role: injection.role,
        depth: injection.depth,
        order: injection.order,
        fragments: [...world.authorNoteBefore, ...world.authorNoteAfter].any(_decoratedWorldHit)
            ? [
                ...world.authorNoteBefore.map(_worldFragment),
                injection.fragment,
                ...world.authorNoteAfter.map(_worldFragment),
              ]
            : const [],
      ),
    );
  }
  for (final depth in world.depths) {
    // Only explicit V3 prefill entries move to the tail. Native entries in
    // the same depth/role group keep ST's original depth-injection ordering.
    final entries = deepseek ? depth.entries.where((hit) => !_worldPrefill(hit)).toList() : depth.entries;
    if (entries.isEmpty) continue;
    result.add(
      PromptInjection(
        fragment: PromptFragment(
          entries.map((hit) => hit.content).join('\n'),
          PromptSource(
            'worldInfo',
            'customDepthWI_${depth.depth}_${depth.role}',
            details: {'entries': entries.map((hit) => _worldSource(hit).toJson()).toList()},
          ),
        ),
        depth: depth.depth,
        role: _role(depth.role),
        v3Depth: entries.any((hit) => hit.depthOverride != null),
        fragments: entries.any(_decoratedWorldHit) ? entries.map(_worldFragment).toList() : const [],
      ),
    );
  }
  return result;
}

bool _worldPrefill(WorldInfoHit hit) => hit.assistantPrefill;

bool _decoratedWorldHit(WorldInfoHit hit) => hit.roleOverride != null || hit.ignoreOnMaxContext;

PromptFragment _worldFragment(WorldInfoHit hit) => PromptFragment(
  hit.content,
  _worldSource(hit),
  role: hit.roleOverride == null ? null : _role(hit.roleOverride),
  trimOnOverflow: hit.ignoreOnMaxContext,
);
Map<String, Object?> _worldInfoTrace(
  WorldInfoResult world, {
  List<WorldInfoHit> preparedUiHits = const [],
  List<Map<String, Object?>> missingBooks = const [],
  Map<WorldInfoEntryRef, WorldInfoPackSource> packSources = const {},
}) => _copy({
  if (missingBooks.isNotEmpty) 'missing': missingBooks,
  if (world.packIssues.isNotEmpty) 'gameplayIssues': world.packIssues,
  if (world.regexDiagnostics.isNotEmpty)
    'regexDiagnostics': [for (final value in world.regexDiagnostics) value.toJson()],
  if (world.externalActivations.isNotEmpty)
    'externalActivations': [for (final value in world.externalActivations) value.toJson()],
  if (world.externalActivationsOmitted != 0) 'externalActivationsOmitted': world.externalActivationsOmitted,
  'budget': world.budget,
  'overflowed': world.overflowed,
  'scanRounds': world.scanRounds,
  'activated': [
    for (final hit in world.activated)
      {
        'bookId': hit.bookId,
        'uid': hit.uid,
        if (packSources[hit.entry.identity] case final source?)
          'sourceRef': {
            ...source.source.toJson(),
            'packVersion': source.packVersion,
            'resourceLocalId': source.resourceLocalId,
            'entryLocalId': source.entryLocalId,
          },
        'source': hit.source.name,
        'reason': hit.reason,
        'content': hit.content,
        'originalContent': hit.originalContent,
        'order': hit.order,
        'position': hit.position,
        'depth': hit.depth,
        'role': hit.role,
        'section': hit.section,
        'outlet': hit.entry.outlet,
        'phase': hit.phase.name,
        'round': hit.round,
        'primaryKey': hit.primaryKey,
        'secondaryMatches': hit.secondaryMatches,
        'probabilityRoll': hit.probabilityRoll,
        'ignoreOnMaxContext': hit.ignoreOnMaxContext,
        'disabledUiPrompt': hit.disabledUiPrompt,
        'unappliedDecorators': [
          if (hit.position == 7 && hit.section == null) ...[
            if (hit.roleOverride != null) 'role',
            if (hit.ignoreOnMaxContext) 'ignore_on_max_context',
          ],
        ],
      },
  ],
  'preparedEffects': [
    for (final hit in preparedUiHits)
      {
        'kind': 'disable_ui_prompt',
        'prompt': hit.disabledUiPrompt,
        'stage': 'before-assembly',
        'source': _worldSource(hit).toJson(),
        'contentRetained': world.activated.any((retained) => retained.entry.identity == hit.entry.identity),
      },
  ],
});

PromptSource _worldSource(WorldInfoHit hit) => PromptSource(
  'worldInfo',
  '${hit.bookId}:${hit.uid}',
  label: hit.entry.comment,
  details: {
    'bookId': hit.bookId,
    'uid': hit.uid,
    'source': hit.source.name,
    'order': hit.order,
    'reason': hit.reason,
    'originalContent': hit.originalContent,
  },
);

bool _systemMessage(StoredNode node) => node.message.role == TavernRole.system || node.original['is_system'] == true;

// ST script.js prepares body regex oldest-first, then reasoning newest-first.
// The latter visits the latest eligible message even when add_to_prompts=false;
// a continuation's existing reasoning prefix remains available in that case.
List<StoredNode> _preparePromptHistory(
  List<StoredNode> history,
  _MacroEnvironment environment, {
  required bool continuing,
  int depthOffset = 0,
  List<Map<String, Object?>>? regexTrace,
}) {
  final result = <StoredNode>[];
  for (final _ in _preparePromptHistorySteps(
    history,
    environment,
    result,
    continuing: continuing,
    depthOffset: depthOffset,
    regexTrace: regexTrace,
  )) {}
  return result;
}

Future<List<StoredNode>> _preparePromptHistoryAsync(
  List<StoredNode> history,
  _MacroEnvironment environment, {
  required bool continuing,
  required void Function() check,
}) async {
  final result = <StoredNode>[];
  var processed = 0;
  for (final _ in _preparePromptHistorySteps(history, environment, result, continuing: continuing)) {
    if (++processed % 32 == 0) {
      await Future<void>.delayed(Duration.zero);
      check();
    }
  }
  return result;
}

Iterable<int> _preparePromptHistorySteps(
  List<StoredNode> history,
  _MacroEnvironment environment,
  List<StoredNode> result, {
  required bool continuing,
  int depthOffset = 0,
  List<Map<String, Object?>>? regexTrace,
}) sync* {
  final visible = history.where((node) => !node.message.hidden && !_systemMessage(node)).toList();
  final transformed = <StoredNode>[];
  for (var index = 0; index < visible.length; index++) {
    final node = visible[index];
    final depth = visible.length - index - (continuing ? 2 : 1) + depthOffset;
    final text = _preparePromptRegex(
      environment,
      node.message.text,
      placement: node.message.role == TavernRole.user ? RegexPlacement.userInput : RegexPlacement.aiOutput,
      phase: RegexPhase.prompt,
      depth: depth,
      source: 'history:${node.message.nodeId}',
      trace: regexTrace,
    );
    transformed.add(_nodeWithText(node, text));
    yield 1;
  }
  final options = _map(environment.settings['reasoning']);
  final add = options['add_to_prompts'] == true;
  final maximum = _finiteNumber(options['max_additions']) ?? 1;
  var additions = 0;
  for (var index = transformed.length - 1; index >= 0; index--) {
    final node = transformed[index];
    if (environment.groupNames != null) {
      final provenance = _map(_map(node.extra['dshgo'])['group']);
      if (node.message.speakerCharacterId != environment.characterId ||
          provenance['model'] != environment.config.model ||
          provenance['deepseek'] != environment.config.deepseek) {
        continue;
      }
    }
    final depth = transformed.length - index - (continuing ? 2 : 1) + depthOffset;
    final reasoning = _preparePromptRegex(
      environment,
      node.message.reasoning ?? '',
      placement: RegexPlacement.reasoning,
      phase: RegexPhase.prompt,
      depth: depth,
      source: 'reasoning:${node.message.nodeId}',
      trace: regexTrace,
    );
    final prefixMessage = continuing && index == transformed.length - 1;
    if ((prefixMessage || (add && additions < maximum)) && reasoning.isNotEmpty && reasoning != '\u200B') {
      additions++;
      final prefix = environment.expand(_string(options['prefix'] ?? '<think>'), const {});
      final separator = environment.expand(_string(options['separator'] ?? '\n'), const {});
      final suffix = environment.expand(_string(options['suffix'] ?? '</think>'), const {});
      final text = prefixMessage && node.message.text.isEmpty
          ? '$prefix$reasoning'
          : '$prefix$reasoning$suffix$separator${node.message.text}';
      transformed[index] = _nodeWithText(node, text);
    }
    yield 1;
    if (!add || additions >= maximum) break;
  }
  final byId = {for (final node in transformed) node.message.nodeId: node};
  result.addAll([for (final node in history) byId[node.message.nodeId] ?? node]);
}

Set<String> _availableWorldSections(ChatPreset preset, String generationType) {
  final settings = preset.executionSettings;
  final definitions = (settings['prompts']! as List<Object?>).whereType<Map<String, Object?>>();
  final groups = (settings['prompt_order']! as List<Object?>).whereType<Map<String, Object?>>();
  final order = groups.firstWhere((group) => '${group['character_id']}' == '100001')['order']! as List<Object?>;
  final enabled = <String>{};
  for (final entry in order.whereType<Map<String, Object?>>()) {
    if (entry['enabled'] != true) continue;
    final definition = definitions.where((item) => item['identifier'] == entry['identifier']).firstOrNull;
    if (definition == null) continue;
    final triggers = definition['injection_trigger'];
    if (triggers is List<Object?> && triggers.isNotEmpty && !triggers.contains(generationType)) continue;
    if (entry['identifier'] == 'charPersonality') enabled.add('personality');
    if (entry['identifier'] == 'scenario') enabled.add('scenario');
  }
  return enabled;
}

num? _finiteNumber(Object? value) => value is num && value.isFinite ? value : null;

Map<String, Object?> _emptyChatState(Map<String, Object?> metadata) {
  final pack = _gameplayWorldInfoCarrier(metadata);
  return {
    'variables': _map(metadata['variables']),
    for (final key in const ['timedWorldInfo', 'decoratorState', 'greetingIndex'])
      if (metadata.containsKey(key)) key: _runtimeValue(metadata[key]),
    if (pack.exists) 'dshgoPackRuntime': pack.raw,
    'stChatIdHash': _finiteNumber(metadata['chat_id_hash']),
  };
}

Map<String, Object?> _runtimeMetadata(Map<String, Object?> metadata, Map<String, Object?> state) {
  // The source is decoded store JSON. Keep the detached compatible tree
  // without encoding and parsing the complete source catalog again.
  final result = _jsonCompatible(metadata) as Map<String, Object?>;
  for (final key in const ['timedWorldInfo', 'decoratorState', 'greetingIndex']) {
    if (state.containsKey(key)) {
      result[key] = _runtimeValue(state[key]);
    } else {
      result.remove(key);
    }
  }
  final pack = _gameplayWorldInfoCarrier(state);
  if (pack.exists) {
    result['dshgoPackRuntime'] = pack.raw;
  } else {
    result.remove('dshgoPackRuntime');
  }
  if (state.containsKey('stChatIdHash')) {
    final hash = _finiteNumber(state['stChatIdHash']);
    if (hash == null) {
      result.remove('chat_id_hash');
    } else {
      result['chat_id_hash'] = hash;
    }
  }
  return result;
}

String _macroChatIdentity(
  StoredChat chat,
  Map<String, Object?> state,
  Map<String, Object?> metadata,
  String? sourceFile, {
  StoredNode? node,
}) {
  if (state['stChatId'] case final String value) return value;
  final own = _map(_map(chat.metadata['dshgo'])['chatJsonl']);
  final files = own['files'] is List<Object?>
      ? (own['files']! as List<Object?>).whereType<Map<String, Object?>>()
      : const Iterable<Map<String, Object?>>.empty();
  final nodeOwn = _map(_map(node?.extra['dshgo'])['chatJsonl']);
  final originalName = nodeOwn['sourceFileName'];
  Map<String, Object?>? file = files.where((item) => item['key'] == sourceFile).firstOrNull;
  file ??= files.where((item) => originalName is String && item['fileName'] == originalName).firstOrNull;
  if (file == null && node != null) {
    file = files
        .where(
          (item) => item['path'] is List<Object?> && (item['path']! as List<Object?>).contains(node.message.nodeId),
        )
        .firstOrNull;
  }
  if (file != null) {
    final header = _map(file['header']);
    final originalMetadata = _map(header['chat_metadata']);
    if (originalMetadata['main_chat'] case final String identity) return identity;
    final label = _map(_map(originalMetadata['dshgo'])['chatJsonl'])['sourceFileName'] ?? file['fileName'];
    if (label is String) return _chatLabel(label);
  }
  if (metadata['main_chat'] case final String identity) return identity;
  final oldMetadata = _map(_map(nodeOwn['sourceHeader'])['chat_metadata']);
  if (oldMetadata['main_chat'] case final String identity) return identity;
  if (originalName is String) return _chatLabel(originalName);
  return sourceFile == null ? chat.id : _chatLabel(sourceFile);
}

String _chatLabel(String fileName) {
  final label = fileName.replaceAll('\\', '/').split('/').last;
  return label.toLowerCase().endsWith('.jsonl') ? label.substring(0, label.length - 6) : label;
}

StoredNode _nodeWithText(StoredNode node, String text) {
  final value = node.message;
  return StoredNode(
    message: TavernMessage(
      nodeId: value.nodeId,
      parentId: value.parentId,
      role: value.role,
      speaker: value.speaker,
      speakerCharacterId: value.speakerCharacterId,
      text: text,
      reasoning: value.reasoning,
      at: value.at,
      siblingIndex: value.siblingIndex,
      siblingCount: value.siblingCount,
      hidden: value.hidden,
      usage: value.usage,
      reportedUsage: value.reportedUsage,
    ),
    depth: node.depth,
    selectedChildId: node.selectedChildId,
    extra: node.extra,
    original: node.original,
  );
}

PromptHistoryMessage _promptHistory(StoredNode node) => PromptHistoryMessage(
  id: node.message.nodeId,
  role: switch (node.message.role) {
    TavernRole.user => 'user',
    TavernRole.character => 'assistant',
    TavernRole.narrator => 'narrator',
    TavernRole.system => 'system',
  },
  content: node.message.text,
  name: node.message.speaker,
  hidden: node.message.hidden,
  isSystem: _systemMessage(node),
  forceAvatar: _jsTruthy(node.original['force_avatar']),
  toolCalls: node.original['tool_calls'] is List<Object?>
      ? (node.original['tool_calls'] as List<Object?>).whereType<Map<String, Object?>>().map(_copy).toList()
      : null,
  toolCallId: node.original['tool_call_id'] as String?,
);

Map<String, Object?> _decodeObject(String text, String description) {
  final value = jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text);
  if (value is! Map<String, Object?>) throw FormatException('$description must be a JSON object.');
  return value;
}

// Variable arithmetic follows JS Number, including non-finite values. JS
// JSON.stringify writes those as null; keep that boundary in both SQLite and
// settings rather than letting a legal macro poison every subsequent turn.
Object? _jsonCompatible(Object? value) {
  if (value is num && !value.isFinite) return null;
  if (value is List<Object?>) return value.map(_jsonCompatible).toList();
  if (value is Map<String, Object?>) {
    return {for (final entry in value.entries) entry.key: _jsonCompatible(entry.value)};
  }
  return value;
}

String _jsonString(Map<String, Object?> value) => jsonEncode(_jsonCompatible(value));
Map<String, Object?> _copy(Map<String, Object?> value) => jsonDecode(_jsonString(value)) as Map<String, Object?>;
Object? _runtimeValue(Object? value) {
  if (value is List<Object?>) return value.map(_runtimeValue).toList();
  if (value is Map<String, Object?>) return _runtimeCopy(value);
  return value;
}

Map<String, Object?> _runtimeCopy(Map<String, Object?> value) => {
  for (final entry in value.entries) entry.key: _runtimeValue(entry.value),
};
bool _jsTruthy(Object? value) =>
    value != null && value != false && value != '' && !(value is num && (value == 0 || value.isNaN));
Map<String, Object?> _personaSettings(Map<String, Object?> settings, PersonaSelection selection) {
  final persona = selection.persona;
  if (persona == null) return settings;
  return {...settings, 'userName': persona.name, 'persona': persona.description, 'personaInPrompt': persona.inPrompt};
}

// ST public/script.js getCharacterCardFields and scripts/authors-note.js
// loadSettings/setFloatingPrompt, fixed 1.19.0 commit cited at the file top.
// These values are projected from the selected source, not copied into every
// branch's mutable chat settings. Explicit local settings are merged last.
Map<String, Object?> _chatMetadataSettings(
  Map<String, Object?> metadata,
  Map<String, Object?> lorebookIds,
  Map<String, Object?> defaultNote,
) {
  final result = <String, Object?>{};
  for (final entry in const {
    'scenario': 'scenarioOverride',
    'system_prompt': 'systemPromptOverride',
    'mes_example': 'mesExamplesOverride',
  }.entries) {
    final value = metadata[entry.key];
    if (value is String) result[entry.value] = value;
  }
  const noteKeys = ['note_prompt', 'note_interval', 'note_depth', 'note_position', 'note_role'];
  if (noteKeys.any(metadata.containsKey)) {
    final position = metadata['note_position'];
    final placement = position == null
        ? defaultNote['placement'] ?? 'inChat'
        : switch (position) {
            2 => 'beforeMain',
            0 => 'afterMain',
            _ => 'inChat',
          };
    result['authorNote'] = {
      'content': metadata['note_prompt'] ?? defaultNote['content'] ?? '',
      'interval': metadata['note_interval'] ?? defaultNote['interval'] ?? 1,
      'depth': metadata['note_depth'] ?? defaultNote['depth'] ?? 4,
      'placement': placement,
      'role': metadata['note_role'] == null ? defaultNote['role'] ?? 'system' : _role(metadata['note_role']),
      'enabled': position == null || position == 0 || position == 1 || position == 2,
    };
  }
  if (metadata.containsKey('world_info')) {
    final name = metadata['world_info'];
    final mapped = name is String ? lorebookIds[name] : null;
    result['lorebooks'] = {
      'chat': [if (mapped is String) mapped],
    };
  }
  return result;
}

Map<String, Object?> _effectiveCard(Map<String, Object?> raw, Map<String, Object?> settings) {
  final card = Map<String, Object?>.of(raw);
  for (final key in const {
    'scenarioOverride': 'scenario',
    'systemPromptOverride': 'system_prompt',
    'mesExamplesOverride': 'mes_example',
  }.entries) {
    final value = settings[key.key];
    if (value is String && value.isNotEmpty) card[key.value] = value;
  }
  return card;
}

Map<String, Object?> _map(Object? value) => value is Map<String, Object?> ? _copy(value) : <String, Object?>{};
// Borrow only engine-owned JSON on read paths. Mutations continue to use _map.
Map<String, Object?> _readMap(Object? value) => value is Map<String, Object?> ? value : const {};

final _regexViews = Expando<List<RegexScript>>('tavern regex projections');
List<RegexScript> _readRegexScripts(Object? value) {
  if (value is! List<Object?>) return const [];
  return _regexViews[value] ??= RegexEngine.readScripts(value);
}

final _plainBookViews = Expando<bool>('plain book projections');
final _bookViews = Expando<Map<(String, WorldInfoSource, String?), WorldInfoBook>>('tavern world book projections');
WorldInfoBook _compiledBook({
  required String id,
  required WorldInfoSource source,
  required Map<String, Object?> json,
  String? stWorldName,
}) {
  final views = _bookViews[json] ??= {};
  return views.putIfAbsent((id, source, stWorldName), () {
    final book = WorldInfoBook.cached(id: id, source: source, json: json, stWorldName: stWorldName);
    _plainBookViews[book] = _plainPromptData(json);
    return book;
  });
}

final _presetViews = Expando<ChatPreset>('preset projections');
ChatPreset _readPreset(Map<String, Object?> raw) =>
    raw.isEmpty ? ChatPreset.stDefault() : (_presetViews[raw] ??= ChatPreset(raw));

Map<String, Object?> _mergeReadMaps(Map<String, Object?> base, Map<String, Object?> patch) {
  final result = Map<String, Object?>.of(base);
  for (final entry in patch.entries) {
    final previous = result[entry.key];
    result[entry.key] = previous is Map<String, Object?> && entry.value is Map<String, Object?>
        ? _mergeReadMaps(previous, entry.value! as Map<String, Object?>)
        : entry.value;
  }
  return result;
}

Map<String, Object?> _merge(Map<String, Object?> base, Map<String, Object?> patch) {
  final result = _copy(base);
  for (final entry in _copy(patch).entries) {
    final previous = result[entry.key];
    result[entry.key] = previous is Map<String, Object?> && entry.value is Map<String, Object?>
        ? _merge(previous, entry.value! as Map<String, Object?>)
        : entry.value;
  }
  return result;
}

String _string(Object? value) => value is String ? value : '';
List<String> _strings(Object? value) => value is List<Object?> ? value.whereType<String>().toList() : <String>[];
int _integer(Object? value, int fallback) => value is num && value.isFinite ? value.toInt() : fallback;
// An invalid in-chat depth remains non-injectable. In particular 4.5 must not
// silently become depth 4. The -1 sentinel is rejected by PromptAssembler but
// retains the extension's independent scan flag for world-info scanning.
int _injectionDepth(Object? value) {
  if (value == null) return 4;
  if (value is! num || !value.isFinite || value != value.truncateToDouble() || value < 0 || value > 10000) return -1;
  return value.toInt();
}

Map<String, Object?> _characterIdentity(Map<String, Object?> settings, String characterId) =>
    _merge(_map(_map(settings['characterIdentities'])[characterId]), _map(settings['characterIdentity']));
String _characterFilename(Map<String, Object?> settings, String characterId) {
  final filename = _string(_characterIdentity(settings, characterId)['avatarFilename']);
  final extension = filename.lastIndexOf('.');
  return extension > 0 ? filename.substring(0, extension) : filename;
}

List<String>? _characterTags(Map<String, Object?> settings, String characterId) {
  final value = _characterIdentity(settings, characterId)['tagIds'];
  return value is List<Object?> ? _strings(value) : null;
}

String _role(Object? value) => switch (value) {
  1 || 'user' => 'user',
  2 || 'assistant' => 'assistant',
  _ => 'system',
};
void _requireBookId(String id) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(id)) {
    throw ArgumentError.value(id, 'id', 'Use a filename-safe lorebook id.');
  }
}

String _safeDetail(Object error) => error is TavernImportError
    ? error.message
    : error is PromptBudgetExceeded
    ? error.toString()
    : 'turn_failed (${error.runtimeType})';
String _plainText(String text) => text
    .replaceAll(RegExp(r'<(?:script|style)\b[^>]*>[\s\S]*?</(?:script|style)>', caseSensitive: false), '')
    .replaceAll(RegExp(r'</?[A-Za-z][^>]*>'), '')
    .replaceAllMapped(RegExp(r'!?\[([^\]]*)\]\([^)]*\)'), (match) => match[1]!)
    .replaceAll(RegExp(r'(^|\n)\s{0,3}(?:#{1,6}\s+|>\s*|[-*+]\s+)'), ' ')
    .replaceAll(RegExp(r'[`*_~]'), '')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
