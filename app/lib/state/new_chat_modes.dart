// The agent preset and permission picked on the new-chat screen before a
// session exists. Like the pending model (models_state.dart), they belong to
// one host/connection lifetime and are applied to the session right after it
// is created, before its first prompt.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart' show ModelSelection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hosts_state.dart' show HostRef;
import 'models_state.dart' show modelSelectionScopeProvider;

/// Presets a new chat never offers: the companion room's own preset is set up
/// by the room, and the diagnostics one is internal and carries no tools.
const hiddenNewChatPresets = {'dsh-go-companion-full', 'dsh-go-diagnostics'};

/// What the new-chat screen asked for. Null fields keep the Host's default.
class NewChatModes {
  const NewChatModes({this.preset, this.permission});

  /// Agent preset id (`agentPresets/select`).
  final String? preset;

  /// Permission preset value (`/permission`).
  final String? permission;

  bool get isEmpty => preset == null && permission == null;

  NewChatModes withPreset(String? value) => NewChatModes(preset: value, permission: permission);
  NewChatModes withPermission(String? value) => NewChatModes(preset: preset, permission: value);

  @override
  bool operator ==(Object other) => other is NewChatModes && other.preset == preset && other.permission == permission;

  @override
  int get hashCode => Object.hash(preset, permission);
}

class PendingNewChatModes extends Notifier<NewChatModes> {
  @override
  NewChatModes build() {
    // A choice made for one host must not reach a host selected later, nor a
    // new connection generation of the same host.
    ref.watch(modelSelectionScopeProvider);
    return const NewChatModes();
  }

  /// Picks [preset]; null (or the Host default) keeps the default.
  void selectPreset(String? preset) => state = state.withPreset(preset);

  /// Picks [permission]; null (or the effective default) keeps the default.
  void selectPermission(String? permission) => state = state.withPermission(permission);

  void clear() => state = const NewChatModes();
}

final pendingNewChatModesProvider = NotifierProvider<PendingNewChatModes, NewChatModes>(PendingNewChatModes.new);

/// What a session made on the new-chat screen still owes before its first
/// prompt: the picks the Host has not confirmed yet. Null fields are settled.
class OwedSetup {
  const OwedSetup({this.preset, this.permission, this.model});

  final String? preset;
  final String? permission;
  final ModelSelection? model;

  bool get isEmpty => preset == null && permission == null && model == null;

  Map<String, Object?> toJson() => {
    if (preset != null) 'preset': preset,
    if (permission != null) 'permission': permission,
    if (model case final model?) 'model': model.toJson(),
  };

  static OwedSetup fromJson(Object? json) {
    if (json is! Map) return const OwedSetup();
    final preset = json['preset'];
    final permission = json['permission'];
    return OwedSetup(
      preset: preset is String ? preset : null,
      permission: permission is String ? permission : null,
      model: ModelSelection.fromJson(json['model']),
    );
  }
}

bool _sameModel(ModelSelection? a, ModelSelection b) =>
    a != null && a.provider == b.provider && a.model == b.model && a.reasoningEffort == b.reasoningEffort;

/// Owed setups by host and session. They outlive the chat screen and a
/// restart (the session and its draft do too), and each pick leaves only when
/// the Host confirms it: a kept draft is never sent under a preset, permission
/// or model the person did not choose.
class OwedSetups extends Notifier<Map<String, OwedSetup>> {
  static const preferenceKey = 'new_chat_owed_setup_v1';

  /// Failures are rare; keep only the latest few.
  static const limit = 20;

  late Future<void> _restored;

  /// Written before the saved setups were in: this run's value wins.
  final _touched = <String>{};

  static String key(HostRef host, String sessionId) => jsonEncode([host.kind.name, host.id, sessionId]);

  @override
  Map<String, OwedSetup> build() {
    _restored = _restore();
    return const {};
  }

  Future<void> _restore() async {
    final restored = <String, OwedSetup>{};
    try {
      final raw = (await SharedPreferences.getInstance()).getString(preferenceKey);
      if (raw != null) {
        for (final MapEntry(:key, :value) in (jsonDecode(raw) as Map).entries) {
          final setup = OwedSetup.fromJson(value);
          if (!setup.isEmpty) restored[key as String] = setup;
        }
      }
    } catch (_) {
      // No preferences backend (tests) or an unreadable value: nothing owed.
    }
    if (!ref.mounted) return;
    restored.removeWhere((key, _) => _touched.contains(key));
    state = Map.unmodifiable({...restored, ...state});
  }

  OwedSetup? of(HostRef host, String sessionId) => state[key(host, sessionId)];

  /// Records what [sessionId] owes; an empty [setup] settles it.
  void put(HostRef host, String sessionId, OwedSetup setup) {
    final k = key(host, sessionId);
    _touched.add(k);
    final next = {...state}..remove(k);
    if (!setup.isEmpty) next[k] = setup;
    final keep = next.entries.skip(next.length > limit ? next.length - limit : 0);
    state = Map.unmodifiable(Map.fromEntries(keep));
    unawaited(_write());
  }

  /// The Host confirmed these picks: each leaves if it is still what is owed.
  void settled(HostRef host, String sessionId, {String? preset, String? permission, ModelSelection? model}) {
    final owed = of(host, sessionId);
    if (owed == null) return;
    put(
      host,
      sessionId,
      OwedSetup(
        preset: preset != null && owed.preset == preset ? null : owed.preset,
        permission: permission != null && owed.permission == permission ? null : owed.permission,
        model: model != null && _sameModel(owed.model, model) ? null : owed.model,
      ),
    );
  }

  /// The person picked another model for [sessionId]: the owed one is moot.
  void dropModel(HostRef host, String sessionId) {
    final owed = of(host, sessionId);
    if (owed?.model == null) return;
    put(host, sessionId, OwedSetup(preset: owed!.preset, permission: owed.permission));
  }

  Future<void> _write() async {
    // Writing before the saved setups are in would drop them.
    await _restored;
    if (!ref.mounted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (state.isEmpty) {
        await prefs.remove(preferenceKey);
      } else {
        await prefs.setString(preferenceKey, jsonEncode({for (final e in state.entries) e.key: e.value.toJson()}));
      }
    } catch (_) {}
  }
}

final owedSetupsProvider = NotifierProvider<OwedSetups, Map<String, OwedSetup>>(OwedSetups.new);
