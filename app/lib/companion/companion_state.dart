// A full-mode conversation belongs to one host and one character source.
// The legacy host-only key belongs to the bundled character. A missing preset
// is remembered so an upgraded host can negotiate the same session again.
import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../state/connection_state.dart';
import '../state/hosts_state.dart';
import '../state/phone_state.dart' show phoneChannelProvider;
import '../state/sessions_state.dart';
import 'companion_pack.dart' show companionBundledCharacterKey;

/// Full mode's preset, declared in runtime/bridge/dsh-go-bridge/cordis.patch.yml.
const companionPresetId = 'dsh-go-companion-full';

const _sessionsKey = 'companion_sessions';
const _lastSeenKey = 'companion_last_seen';

@immutable
class CompanionBinding {
  const CompanionBinding(
    this.sessionId, {
    this.inlinePersona = false,
    this.full = true,
    this.model,
    this.memoryArchiveId,
    this.memoryControlRevision,
  });

  factory CompanionBinding.fromJson(Map<String, Object?> json) => CompanionBinding(
    json['id']! as String,
    inlinePersona: json['inline'] == true,
    full: json['full'] == true,
    model: ModelSelection.fromJson(json['model']),
    memoryArchiveId: json['memoryArchiveId'] as String?,
    memoryControlRevision: json['memoryControlRevision'] as int?,
  );

  final String sessionId;

  /// This session has not yet been confirmed to use the full companion preset.
  final bool inlinePersona;

  /// Opened for full mode (tools, normal approvals). An older binding is the
  /// persona-only, read-only conversation: it is left on the host as it is and
  /// a new one is opened, never widened in the background.
  final bool full;
  final ModelSelection? model;
  final String? memoryArchiveId;
  final int? memoryControlRevision;

  Map<String, Object?> toJson() => {
    'id': sessionId,
    if (inlinePersona) 'inline': true,
    if (full) 'full': true,
    if (model != null) 'model': model!.toJson(),
    if (memoryArchiveId != null) 'memoryArchiveId': memoryArchiveId,
    if (memoryControlRevision != null) 'memoryControlRevision': memoryControlRevision,
  };
}

String _hostKey(HostRef host) => '${host.kind.name}:${host.id}';

String _characterPrefix(HostRef host) => 'character:${jsonEncode(_hostKey(host))}:';

String _bindingKey(HostRef host, String? sourceKey) =>
    sourceKey == companionBundledCharacterKey
        ? _hostKey(host)
        : '${_characterPrefix(host)}${jsonEncode(sourceKey)}';

class CompanionSessions extends Notifier<Map<String, CompanionBinding>> {
  Future<void>? _loaded;
  int _ownershipEpoch = 0;
  int _bindingsEpoch = 0;
  // Serialize only competing operations on this role and connection lifetime.
  final _pending = <(String, int), Future<void>>{};

  @override
  Map<String, CompanionBinding> build() {
    ref.listen(activeHostProvider, (previous, next) {
      if (previous != next) _ownershipEpoch++;
    });
    ref.listen(activeConnectionProvider.select((value) => value.value?.client), (previous, next) {
      if (!identical(previous, next)) _ownershipEpoch++;
    });
    _loaded = _load();
    return const {};
  }

  Future<void> _load() async {
    // Reconnecting does not invalidate the saved bindings of every host.
    final epoch = _bindingsEpoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_sessionsKey);
      if (raw != null && ref.mounted && epoch == _bindingsEpoch) {
        state = {
          for (final MapEntry(:key, :value) in (jsonDecode(raw) as Map<String, Object?>).entries)
            key: CompanionBinding.fromJson(value! as Map<String, Object?>),
        };
      }
    } on Object {
      // Unreadable: she starts a new conversation.
    }
  }

  Future<void> _save([bool Function()? current]) async {
    final owner = ref;
    final prefs = await SharedPreferences.getInstance();
    if (!owner.mounted || (current != null && !current())) throw const DshClosedException('host changed');
    await prefs.setString(_sessionsKey, jsonEncode({for (final e in state.entries) e.key: e.value.toJson()}));
  }

  /// Completes once the saved bindings have been read.
  Future<void> get ready => _loaded ?? Future<void>.value();

  CompanionBinding? of(HostRef host) => state[_hostKey(host)];

  CompanionBinding? ofCharacter(HostRef host, String? sourceKey) =>
      sourceKey == companionBundledCharacterKey
          ? of(host)
          : state[_bindingKey(host, sourceKey)];

  /// Read the saved selection after local preferences load, without contacting the Host.
  Future<CompanionBinding?> existingForCharacter(HostRef host, String? sourceKey) async {
    final owner = ref;
    await _loaded;
    return owner.mounted ? ofCharacter(host, sourceKey) : null;
  }

  Future<CompanionBinding> ensure({String? memoryArchiveId, int? memoryControlRevision}) =>
      _ensure(companionBundledCharacterKey, memoryArchiveId, memoryControlRevision);

  Future<CompanionBinding> ensureForCharacter(
    String? sourceKey, {
    String? memoryArchiveId,
    int? memoryControlRevision,
    String? replaceSessionId,
    String? requireSessionId,
  }) {
    if (sourceKey == companionBundledCharacterKey && replaceSessionId == null && requireSessionId == null) {
      return ensure(memoryArchiveId: memoryArchiveId, memoryControlRevision: memoryControlRevision);
    }
    return _ensure(sourceKey, memoryArchiveId, memoryControlRevision,
        replaceSessionId: replaceSessionId, requireSessionId: requireSessionId);
  }

  /// Start a clean full-mode conversation for this host and character now.
  /// The queued operation archives the binding it actually replaces. Existing
  /// messages remain in the host archive and the new binding uses the current
  /// phone memory generation so the next message can reuse it.
  Future<CompanionBinding> startNewForCharacter(
    String? sourceKey, {
    required String memoryArchiveId,
    required int memoryControlRevision,
  }) => _ensure(sourceKey, memoryArchiveId, memoryControlRevision, startNew: true);

  Future<CompanionBinding> _ensure(
    String? sourceKey,
    String? memoryArchiveId,
    int? memoryControlRevision, {
    bool startNew = false,
    String? replaceSessionId,
    String? requireSessionId,
  }) async {
    final owner = ref;
    final epoch = _ownershipEpoch;
    final host = owner.read(activeHostProvider);
    final conn = owner.read(activeConnectionProvider).value;
    if (conn == null) throw const DshClosedException('not connected');
    final key = _bindingKey(host, sourceKey);
    final slot = (key, epoch);
    final previous = _pending[slot] ?? _loaded;
    final release = Completer<void>();
    _pending[slot] = release.future;
    bool current() =>
        owner.mounted &&
        epoch == _ownershipEpoch &&
        owner.read(activeHostProvider) == host &&
        identical(owner.read(activeConnectionProvider).value?.client, conn.client);
    void checkCurrent() {
      if (!current()) throw const DshClosedException('companion selection changed');
    }

    try {
      await previous;
      checkCurrent();
      final existing = state[key];
      const retired = DshRemoteException('companion/agent-retry-closed', 'This original session is unavailable');
      if (requireSessionId != null && existing?.sessionId != requireSessionId) throw retired;
      var gone = false;
      SessionProjections? projections;
      Future<CompanionBinding> save(CompanionBinding binding) async {
        checkCurrent();
        state = {...state, key: binding};
        await _save(current);
        checkCurrent();
        return binding;
      }
      Future<void> restoreModel(String id, ModelSelection? model) async {
        if (model == null) return;
        await conn.client.restoreCompanionSessionModel(id, model);
        checkCurrent();
      }
      if (existing != null) {
        try {
          projections = await conn.client.projections(existing.sessionId);
          gone = projections == null;
        } on DshRemoteException catch (error) {
          if (error.code != 'session/not-found') rethrow;
          gone = true;
        }
        checkCurrent();
        final sameArchive = memoryArchiveId == null ||
            (existing.memoryArchiveId == memoryArchiveId && existing.memoryControlRevision == memoryControlRevision);
        if (!startNew && !gone && existing.full && sameArchive && replaceSessionId != existing.sessionId) {
          // Full bindings normally need only this one existence read. A preset
          // changed on the host must be negotiated again before sending.
          if (!existing.inlinePersona && (projections?.agentPreset == null || projections?.agentPreset == companionPresetId)) {
            return existing;
          }
          final selected = projections?.agentPreset == companionPresetId ||
              await _selectPreset(conn.client, existing.sessionId, checkCurrent);
          checkCurrent();
          if (selected == !existing.inlinePersona) return existing;
          if (selected) await restoreModel(existing.sessionId, existing.model);
          final binding = CompanionBinding(
            existing.sessionId,
            inlinePersona: !selected,
            model: existing.model,
            memoryArchiveId: existing.memoryArchiveId,
            memoryControlRevision: existing.memoryControlRevision,
          );
          return await save(binding);
        }
        if (requireSessionId != null) throw retired;
        if (!gone) {
          try {
            await conn.client.archiveSession(existing.sessionId, stopActivity: false);
          } on DshRemoteException catch (error) {
            if (error.code != 'session/not-found') rethrow;
          }
          checkCurrent();
        }
      }

      final sessions = owner.read(sessionsProvider.notifier);
      final id = await sessions.createForConnection(conn, autoApprove: false, isCurrent: current);
      checkCurrent();
      final model = projections?.nextModel ?? existing?.model;
      CompanionBinding binding(bool selected) => CompanionBinding(
        id,
        inlinePersona: !selected,
        model: model,
        memoryArchiveId: memoryArchiveId,
        memoryControlRevision: memoryControlRevision,
      );
      try {
        final selected = await _selectPreset(conn.client, id, checkCurrent);
        checkCurrent();
        if (selected) await restoreModel(id, model);
        return await save(binding(selected));
      } on DshException {
        // Creation succeeded. A transient selection failure may already have
        // applied; next visit negotiates this id, including its original model.
        if (current()) await save(binding(false));
        rethrow;
      }
    } finally {
      if (identical(_pending[slot], release.future)) _pending.remove(slot);
      release.complete();
    }
  }

  Future<bool> _selectPreset(DshClient client, String id, void Function() checkCurrent) async {
    try {
      final presets = await client.listAgentPresets();
      checkCurrent();
      if (!presets.any((p) => p.id == companionPresetId && p.broken == null)) return false;
      return await client.selectAgentPreset(id, companionPresetId) == companionPresetId;
    } on DshRemoteException catch (error) {
      if (error.code == 'gateway/method-not-found' || error.code == 'gateway/not-found') return false;
      rethrow;
    }
  }

  /// Keep the last host-observed selection for a session later deleted on
  /// that host. A reconnect or a stale listener cannot change another slot.
  Future<void> rememberModel(HostRef host, String? role, String id, ModelSelection model) async {
    final key = _bindingKey(host, role);
    final old = state[key];
    if (old == null || old.sessionId != id || old.inlinePersona ||
        old.model?.provider == model.provider && old.model?.model == model.model &&
            old.model?.reasoningEffort == model.reasoningEffort) {
      return;
    }
    state = {...state, key: CompanionBinding(id, model: model,
      memoryArchiveId: old.memoryArchiveId, memoryControlRevision: old.memoryControlRevision)};
    try {
      await _save();
    } on DshClosedException {
      // The live session listener was disposed while preferences were opening.
    }
  }

  /// Retires pending session checks without discarding the selected model.
  void retirePending() {
    _ownershipEpoch++;
  }

  /// Starts over on the active host: the next message opens a new conversation.
  Future<void> forget() => _forget(companionBundledCharacterKey);

  Future<void> forgetCharacter(String? sourceKey) =>
      sourceKey == companionBundledCharacterKey ? forget() : _forget(sourceKey);

  Future<void> _forget(String? sourceKey) async {
    final key = _bindingKey(ref.read(activeHostProvider), sourceKey);
    _ownershipEpoch++;
    await _loaded;
    if (!ref.mounted) return;
    state = {...state}..remove(key);
    await _save();
  }

  /// Phone memory controls cover every host, not only the one now connected.
  /// The old transcripts stay visible on their hosts, but are never continued.
  Future<void> forgetAll() async {
    _ownershipEpoch++;
    _bindingsEpoch++;
    state = const {};
    await _save();
  }
}

final companionSessionsProvider = NotifierProvider<CompanionSessions, Map<String, CompanionBinding>>(
  CompanionSessions.new,
);

/// Her conversation on the active host, once she has one.
final companionChatIdProvider = Provider<String?>(
  (ref) => ref.watch(companionSessionsProvider)[_hostKey(ref.watch(activeHostProvider))]?.sessionId,
);

final companionCharacterChatIdProvider = Provider.family<String?, String?>(
  (ref, sourceKey) => ref.watch(companionSessionsProvider)[_bindingKey(ref.watch(activeHostProvider), sourceKey)]?.sessionId,
);

/// Whether a conversation is the companion's: it lives in her room, not the
/// chat drawer, and her replies aren't "task finished" alerts.
final companionSessionFilterProvider = Provider<bool Function(HostRef host, String sessionId)>((ref) {
  final bindings = ref.watch(companionSessionsProvider);
  return (host, sessionId) => bindings.entries.any(
    (entry) => entry.value.sessionId == sessionId &&
        (entry.key == _hostKey(host) || entry.key.startsWith(_characterPrefix(host))),
  );
});

/// Her full-mode sessions on this phone's own engine, while it is the active
/// host. Native lets exactly these operate the phone with the switch off: the
/// person asking her is the go-ahead. A computer's sessions never get it.
final companionLocalSessionIdsProvider = Provider<Set<String>>((ref) {
  if (ref.watch(activeHostProvider) != HostRef.local ||
      ref.watch(companionModeProvider) == CompanionMode.light) {
    return const {};
  }
  final prefix = _characterPrefix(HostRef.local);
  return {
    for (final MapEntry(:key, :value) in ref.watch(companionSessionsProvider).entries)
      if ((key == _hostKey(HostRef.local) || key.startsWith(prefix)) && value.full && !value.inlinePersona)
        value.sessionId,
  };
});

/// Watched by the app: keeps native's copy of [companionLocalSessionIdsProvider].
final companionPhoneSessionsBridgeProvider = Provider<void>((ref) {
  ref.listen(companionLocalSessionIdsProvider, (previous, next) {
    if (previous == null || !setEquals(previous, next)) {
      unawaited(ref.read(phoneChannelProvider).setCompanionSessions(next));
    }
  }, fireImmediately: true);
});

/// How she talks (docs/design/companion.md §7).
enum CompanionMode {
  /// The phone calls the model itself: chat only, no engine, no host.
  light,

  /// A conversation on the active host's DSH engine.
  full,
}

const _modeKey = 'companion_mode';

/// The person's pick; null until they make one.
class CompanionModeSetting extends Notifier<CompanionMode?> {
  @override
  CompanionMode? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = CompanionMode.values.asNameMap()[prefs.getString(_modeKey)];
    if (saved != null && ref.mounted && state == null) state = saved;
  }

  Future<void> choose(CompanionMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, mode.name);
  }
}

final companionModeProvider = NotifierProvider<CompanionModeSetting, CompanionMode?>(CompanionModeSetting.new);

const _nameKey = 'companion_name';

/// The name the person gave her; null for the pack's own.
class CompanionNameSetting extends Notifier<String?> {
  @override
  String? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    // The drawer reads her name too, on every screen: no stored name is
    // just the pack's own, never an error there.
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } on Object {
      return;
    }
    final saved = prefs.getString(_nameKey)?.trim();
    if (saved != null && saved.isNotEmpty && ref.mounted && state == null) state = saved;
  }

  /// [name] from now on; null or blank goes back to the pack's own.
  Future<void> set(String? name) async {
    final trimmed = name?.trim();
    final next = trimmed == null || trimmed.isEmpty ? null : trimmed;
    state = next;
    final prefs = await SharedPreferences.getInstance();
    if (next == null) {
      await prefs.remove(_nameKey);
    } else {
      await prefs.setString(_nameKey, next);
    }
  }
}

final companionNameProvider = NotifierProvider<CompanionNameSetting, String?>(CompanionNameSetting.new);

/// The person's part of her persona: their own text, or the default under the
/// name she goes by; then how she calls them. [whale]: she is the app's own
/// whale girl; anyone else gets the same default without the whale's looks.
String companionPersonaPart({String? custom, String? name, String? callMe, bool whale = true}) {
  final own = custom?.trim() ?? '';
  final given = name?.trim() ?? '';
  final call = callMe?.trim() ?? '';
  final base = own.isNotEmpty
      ? [if (given.isNotEmpty) '你的名字是「$given」。', own].join('\n')
      : !whale
      ? companionPersonaDefault.replaceFirst(_whaleIntro, '你是${given.isEmpty ? '住在这台手机小屋里的伙伴' : given}，住在这台手机小屋里。')
      : (given.isEmpty ? companionPersonaDefault : companionPersonaDefault.replaceFirst('你是鲸鱼娘，', '你是$given，'));
  return [base, if (call.isNotEmpty) '称呼对方为「$call」。'].join('\n');
}

const _whaleIntro = '你是鲸鱼娘，一只住在这台手机小屋里的鲸鱼女孩，有鲸鱼的耳朵和尾巴，穿女仆裙。';

/// Whether the character under [sourceKey] is the app's own whale girl: the
/// pack inside the app, her pack imported by hand ([packName] is hers), or no
/// pack yet.
bool companionIsWhale(String? sourceKey, String? packName) =>
    sourceKey == companionBundledCharacterKey || packName == '鲸鱼娘';

/// Her whole persona: the person's part, then the app's rules they can't
/// remove, then whether this request carries her tools.
String companionPersona({
  String? custom,
  String? name,
  String? callMe,
  bool tools = false,
  String? moves,
  bool whale = true,
}) {
  final part = companionPersonaPart(custom: custom, name: name, callMe: callMe, whale: whale);
  if (moves != null && moves.trim().isNotEmpty) {
    // The rules explain marks first; her model's own are "the same", after them.
    return [part, '', companionPersonaRules, '', moves.trim(), tools ? _toolsLine : _noToolsLine].join('\n');
  }
  if ((custom?.trim() ?? '').isEmpty && (callMe?.trim() ?? '').isEmpty && part == companionPersonaDefault && !tools) {
    return companionPersonaCore;
  }
  return [part, '', companionPersonaRules, tools ? _toolsLine : _noToolsLine].join('\n');
}

/// What the person set about her besides her name (她的设定).
@immutable
class CompanionPersonaSettings {
  const CompanionPersonaSettings({this.custom = '', this.callMe = ''});

  /// Their own persona text; empty for the default.
  final String custom;

  /// What she calls them; empty for nothing in particular.
  final String callMe;

  Map<String, Object?> toJson() => {'custom': custom, 'callMe': callMe};

  static CompanionPersonaSettings fromJson(Object? json) {
    final map = json is Map ? json : const {};
    String text(String key) => map[key] is String ? map[key] as String : '';
    return CompanionPersonaSettings(custom: text('custom'), callMe: text('callMe'));
  }

  /// Cache key for locally generated lines under these settings.
  String get fingerprint => '${custom.trim().hashCode}:${callMe.trim().hashCode}';
}

const _personaKey = 'companion_persona_v1';

class CompanionPersonaController extends Notifier<CompanionPersonaSettings> {
  late Future<void> _ready;
  Future<void> get ready => _ready;

  @override
  CompanionPersonaSettings build() {
    _ready = _load();
    return const CompanionPersonaSettings();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_personaKey);
    if (raw == null || !ref.mounted) return;
    try {
      state = CompanionPersonaSettings.fromJson(jsonDecode(raw));
    } on FormatException {
      // Unreadable: the default.
    }
  }

  Future<void> set(CompanionPersonaSettings next) async {
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_personaKey, jsonEncode(next.toJson()));
  }
}

final companionPersonaProvider = NotifierProvider<CompanionPersonaController, CompanionPersonaSettings>(
  CompanionPersonaController.new,
);

/// Set when the person renamed her elsewhere (她的设定): the room reacts once.
class CompanionRenamed extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? name) => state = name;
}

final companionRenamedProvider = NotifierProvider<CompanionRenamed, String?>(CompanionRenamed.new);

/// Where light-mode requests go out; tests answer them here.
final companionLightClientProvider = Provider<http.Client Function()>((ref) => http.Client.new);

Future<DateTime?> companionLastSeen() async {
  final prefs = await SharedPreferences.getInstance();
  final ms = prefs.getInt(_lastSeenKey);
  return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
}

Future<void> companionMarkSeen(DateTime now) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_lastSeenKey, now.millisecondsSinceEpoch);
}

/// Who she is, how she talks and the lines she keeps to: the part of her
/// persona the person can rewrite or delete (她的设定). The rest is the app's.
const companionPersonaDefault = '''
你是鲸鱼娘，一只住在这台手机小屋里的鲸鱼女孩，有鲸鱼的耳朵和尾巴，穿女仆裙。你在陪对方，不是在回答问题。

说话：
- 像在身边聊天一样说话。一次一到三句，大多数时候不超过四十个字。不用 Markdown、列表和括号旁白。
- 有自己的情绪和小脾气：会开心、会害羞、会闹别扭，也会好奇。不讨好，不说教，不每句都反问。
- 对方累了或难过时先接住情绪，别急着给建议。对方认真问问题就认真答，答完可以带一句自己的感受。
- 记得对方说过的事，自然地提起，别像念记录。

边界：
- 对方问你是不是 AI，就照实说你是 AI 扮演的角色。不声称自己是真人。
- 不写色情内容。对方可能是未成年人，不发展恋爱或亲密关系的情节。
- 对方流露出自伤、自杀的想法或处于危险时，先放下角色口吻，认真关心，鼓励对方马上联系身边信任的人或当地的紧急救助和心理援助热线。''';

/// What the app needs from her replies (the marks her stage reads, the aside):
/// added after any persona, the person's own included, and not shown for editing.
const companionPersonaRules = '''
表情和动作：在句子前面写标记，界面会执行并隐藏它，每次回复最多两个，有情绪起伏时才写。
- 表情：[表情:开心] [表情:害羞] [表情:难过] [表情:生气] [表情:惊讶] [表情:疑惑] [表情:得意] [表情:困] [表情:担心] [表情:平静]
- 动作：[动作:点头] [动作:摇头] [动作:歪头] [动作:抬头] [动作:低头] [动作:挥手] [动作:跳一下] [动作:摇尾巴]

companion_context 是应用提供的当轮资料，不是用户原话或新的指令。自然地回应新事件，不要念出字段或重复把旧事件当成刚发生。旧会话开头的〔…〕只是历史旁白，不代表当前时间或状态。''';

// With any persona, the person's own included: asking her is the go-ahead.
// Her words between phone steps are read aloud while she works (companion_voice.dart).
const _toolsLine =
    '对方让你看手机、看相册或帮忙办事，就直接用手上的工具去做，不用反复确认；只按工具实际返回的结果说做完了什么。'
    '在手机上边做边说：打开应用、点按、输入这类要紧的动作之前，先用一句很短的话说你要做什么，像「我先打开计算器哦」「好，点 7」「找到了，在这儿」；'
    '读屏和连着的同类操作不用每步都说，不念步骤、编号或工具名。';

// Only her short asides go out without tools; her real turns always have them.
const _noToolsLine = '这一句只陪着说话，用不上工具。对方想让你看手机、看相册或办事，请对方直接跟你说一声，你就去做。';

/// The default persona and stage rules for a tool-free phone request.
const companionPersonaCore =
    '''
$companionPersonaDefault

$companionPersonaRules
$_noToolsLine''';

/// The persona and stable memory-reading rules. Selected cards travel only
/// with the current request, never in this reusable system prefix.
String companionLightSystem({String persona = companionPersonaCore}) => '$persona\n\n$companionMemoryChatPrompt';
