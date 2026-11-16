/// The tavern (酒馆): SillyTavern-compatible role play that runs on the phone.
/// Design: docs/design/roleplay.md.
library;

export 'src/api.dart';
export 'src/authoring.dart';
export 'src/authoring_model_images.dart';
export 'src/authoring_preview.dart';
export 'src/authoring_render.dart';
export 'src/authoring_run.dart';
export 'src/authoring_script_preview.dart';
export 'src/authoring_seed.dart';
export 'src/authoring_simulation.dart';
export 'src/backup.dart';
export 'src/director.dart';
export 'src/dshgo_inspection.dart';
export 'src/engine.dart';
export 'src/gameplay.dart';
export 'src/gameplay_bindings.dart';
export 'src/gameplay_cast.dart';
export 'src/gameplay_export.dart';
export 'src/gameplay_packs.dart';
export 'src/import_report.dart';
export 'src/inspection.dart';
export 'src/lorebook_library.dart';
export 'src/io/card_codec.dart' hide DecodedCardSeed, cardAssetDataUri;
export 'src/io/chat_jsonl.dart';
export 'src/io/deepseek_export.dart' show isDeepSeekExport;
export 'src/io/st_chat_document.dart';
export 'src/llm/model_client.dart';
export 'src/macros/macro_engine.dart'
    hide ScriptCoercion, ScriptMacroAdapter, ScriptMacroBindings, MacroHistorySnapshot;
export 'src/persona.dart';
export 'src/preset_library.dart';
export 'src/regex_library.dart';
export 'src/scripts.dart';
export 'src/state.dart';
export 'src/tools.dart';
export 'src/io/preset_codec.dart';
export 'src/prompt/character_fields.dart';
export 'src/prompt/deepseek_processing.dart';
export 'src/prompt/preset.dart';
export 'src/prompt/prompt_assembler.dart'
    hide
        genericChatRequestBody,
        convertExplicitPromptMessages,
        explicitPromptRequestBody,
        assembleScriptPrompt,
        assemblePromptWindow,
        plainHistoryTokenCost;
export 'src/prompt/prompt_types.dart';
export 'src/regex/regex_engine.dart';
export 'src/regex/regex_worker.dart';
export 'src/store/character_library.dart'
    hide
        AuthoringCardMedia,
        AuthoringCharacterCapture,
        CharacterAvatarMetadata,
        CharacterAvatarCapture,
        replayAuthoringSaveAs,
        authoringSaveAsReceipt;
export 'src/store/chat_store.dart'
    hide
        GameplayBindingStore,
        GameplaySimulationStore,
        StoredGameplaySimulationData,
        AuthoringStore,
        StoredAuthoringDraft,
        AuthoringAuthorityStore,
        inspectAuthoringDatabase,
        StoredAuthoringResource,
        AuthoringRunStore,
        AuthoringSeedStore,
        ToolStore,
        StoredToolOperation,
        StoredToolPhase,
        StoredToolFinishKind,
        StoredToolTurnOwner,
        StoredToolOwnership,
        StoredToolCommit,
        StoredToolPreparation,
        StoredToolSourceEligibility,
        StoredToolTerminal,
        StoredToolOwnershipException,
        StoredToolBudgetException,
        StoredToolBodyRewrite,
        StoredModelToolCall,
        StoredToolMemoryStage,
        StoredToolStateSettlement,
        StoredToolRollbackPlan,
        StoredToolCleanupFacts,
        StoredToolCleanup,
        StoredRememberMemory,
        StoredDisplayHistory,
        StoredHistoryLink;
export 'src/worldinfo/world_info.dart' hide remapWorldInfoBook, WorldInfoPackSource, exportGameplayWorldInfoEntry;
