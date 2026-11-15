/// Client for the DeepSeek Harness `dsh web` API (verified on 0.2.0-rc.2 and 0.2.1-rc.2).
///
/// Layers, lowest first:
/// * [DshCarrier] — pluggable transport: [DshHttpCarrier] over
///   [DshConnection] (launch-token login, session cookie, HTTP, WebSocket)
///   by default; `package:dsh_remote` adds the encrypted remote tunnel.
/// * [DshRpc] — unary Typert Remote calls (`POST /api/<namespace>/<method>`
///   on HTTP).
/// * [DshMux] — logical streams + `$events` generations (`/api/remote.mux`
///   on HTTP).
/// * [DshClient] — sessions, prompts, history, live `watch()`, approvals,
///   models, provider key, custom providers (`llm-pi-ai` routes).
/// * [ChatTranscript] — optional reducer from events to chat items.
library;

export 'src/agents_api.dart';
export 'src/carrier.dart';
export 'src/client_inventory_api.dart';
export 'src/companion_api.dart';
export 'src/companion_recall_api.dart';
export 'src/companion_signals.dart';
export 'src/companion_signals_api.dart';
export 'src/connection.dart';
export 'src/cordis_api.dart';
export 'src/cot_translation_api.dart';
export 'src/deliverables.dart';
export 'src/dsh_go_api.dart';
export 'src/dsbot_api.dart';
export 'src/engine_settings_api.dart';
export 'src/editors_api.dart';
export 'src/errors.dart';
export 'src/features_api.dart';
export 'src/files_api.dart';
export 'src/media_meta.dart';
export 'src/goals_api.dart';
export 'src/messages_api.dart';
export 'src/models.dart';
export 'src/mux.dart';
export 'src/plugin_config_api.dart';
export 'src/plugins_api.dart';
export 'src/providers_api.dart';
export 'src/references_api.dart';
export 'src/rpc.dart';
export 'src/runtime_capabilities.dart';
export 'src/schedule_list_api.dart';
export 'src/session_api.dart';
export 'src/session_deletion_api.dart';
export 'src/session_activation.dart';
export 'src/session_export.dart';
export 'src/speech_api.dart';
export 'src/subscriptions_api.dart';
export 'src/terminal_api.dart';
export 'src/transcript.dart';
export 'src/workspace_api.dart';
export 'src/workspace_upload.dart';
export 'src/workspaces_api.dart';

export 'src/lifecycle_api.dart';
