// The ways in from outside the app other than links and
// shares — the launcher icon's long-press shortcuts (新对话, 语音输入, the
// three latest conversations), the Quick Settings tile (新对话), and a
// screenshot taken explicitly from the floating pet. Native
// side: android/.../shortcuts/ (EntryActivity, ShortcutsPlugin — MethodChannel
// `dsh/shortcuts`) and tile/NewChatTileService.kt. Routed by
// lib/ui/shell/system_entry_host.dart. HarmonyOS has the two static shortcuts
// (ohos/.../ShortcutsPlugin.ets): no tile, and no public API for recent ones.

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../companion/companion_agent_phone_tools.dart' show companionPhoneWindow;
import '../l10n/l10n.dart';
import '../state/connection_state.dart';
import '../state/hosts_state.dart';
import '../state/sessions_state.dart';
import 'native_inbox.dart';

/// Where a launcher shortcut or the tile asked to go.
sealed class LauncherEntry {
  const LauncherEntry();

  /// One `entry` call's arguments; null for anything malformed.
  static LauncherEntry? parse(Object? raw) {
    if (raw is! Map) return null;
    final sessionId = raw['sessionId'];
    final host = raw['host'];
    final text = raw['text'] is String ? raw['text'] as String : '';
    final path = raw['path'];
    final taskId = raw['taskId'];
    final taskRev = raw['taskRev'];
    final companion = companionPhoneWindow(sessionId is String ? sessionId : null);
    return switch (raw['kind']) {
      'new' => NewChatEntry(text: text),
      'voice' => NewChatEntry(voice: true, text: text),
      'companion_assistant' => CompanionAssistantEntry(
        page: raw['page'] is String ? raw['page'] as String : null,
        returnToApp: raw['returnToApp'] == true,
      ),
      'screenshot' when path is String && path.startsWith('/') && !path.contains('\u0000') => ScreenshotEntry(path),
      // A companion phone task's way back comes on its own session id: she is
      // no conversation in the chat.
      'chat' when companion != null => OpenCompanionEntry(room: companion == 'room'),
      'chat' when sessionId is String && sessionId.isNotEmpty => OpenChatEntry(
        HostRef.decode(host is String ? host : null),
        sessionId,
      ),
      'companion_task'
          when taskId is String && taskId.isNotEmpty && !taskId.contains('\u0000') && taskRev is int && taskRev > 0 =>
        OpenCompanionTaskEntry(taskId, taskRev),
      _ => null,
    };
  }
}

/// A new conversation; [voice] starts dictation in its composer.
class NewChatEntry extends LauncherEntry {
  const NewChatEntry({this.voice = false, this.text = ''});

  final String text;

  final bool voice;
}

/// The Android digital assistant opened the room, optionally with a system Assist snapshot.
class CompanionAssistantEntry extends LauncherEntry {
  const CompanionAssistantEntry({this.page, this.returnToApp = false});

  final String? page;
  final bool returnToApp;
}

/// A pet screenshot in the app's private cache, authenticated by the native
/// entry bridge. It is attached to a new-chat draft, never sent automatically.
class ScreenshotEntry extends LauncherEntry {
  const ScreenshotEntry(this.path);

  final String path;
}

/// One of the recent conversations.
class OpenChatEntry extends LauncherEntry {
  const OpenChatEntry(this.host, this.sessionId);

  final HostRef host;
  final String sessionId;
}

/// Back from a companion phone task (it finished, 回到 DSH Go, a prompt
/// opened): her [room] when it was asked for there; from her floating self or
/// her notification, the app as the person left it.
class OpenCompanionEntry extends LauncherEntry {
  const OpenCompanionEntry({required this.room});

  final bool room;
}

/// A trusted reminder notification opens its stored task, without choosing a
/// host or claiming that the current revision is the one that fired.
class OpenCompanionTaskEntry extends LauncherEntry {
  const OpenCompanionTaskEntry(this.taskId, this.taskRev);

  final String taskId;
  final int taskRev;
}

/// A conversation as a launcher shortcut.
class RecentShortcut {
  const RecentShortcut({required this.sessionId, required this.title, required this.host});

  final String sessionId;
  final String title;
  final HostRef host;

  Map<String, Object?> toJson() => {'id': sessionId, 'title': title, 'host': host.encode()};

  @override
  bool operator ==(Object other) =>
      other is RecentShortcut &&
      other.sessionId == sessionId &&
      other.title == title &&
      other.host == host &&
      other.host.name == host.name;

  @override
  int get hashCode => Object.hash(sessionId, title, host);
}

/// The native bridge: entries in, recent conversations out.
class LauncherBridge extends NativeInbox<LauncherEntry> {
  LauncherBridge({MethodChannel? channel})
    : super(channel ?? const MethodChannel('dsh/shortcuts'), method: 'entry', parse: LauncherEntry.parse);

  Stream<LauncherEntry> get entries => stream;

  /// What the launcher has, as far as this run knows.
  List<RecentShortcut>? _published;

  /// Publishes not answered yet: one of them may still replace [_published].
  int _sending = 0;

  /// Publishes [recents] (newest first) unless the launcher already has
  /// them. True when the launcher has them now.
  Future<bool> setRecent(List<RecentShortcut> recents) async {
    if (_sending == 0 && _published != null && listEquals(_published, recents)) return true;
    _sending++;
    try {
      final ok = await channel.invokeMethod<bool>('setRecent', {
        'items': [for (final r in recents) r.toJson()],
      });
      // Refused while rate-limited: the next change tries again.
      if (ok ?? false) _published = List.unmodifiable(recents);
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } finally {
      _sending--;
    }
  }
}

final launcherBridgeProvider = Provider<LauncherBridge>((ref) {
  final bridge = LauncherBridge();
  ref.onDispose(bridge.dispose);
  return bridge;
});

/// At most this many conversations on the launcher.
const maxRecentShortcuts = 3;

/// The active host's latest conversations, for the launcher. Null while that
/// isn't known (not connected, the list loading): the launcher keeps what it
/// shows rather than being emptied by a stopped engine.
final recentShortcutsProvider = Provider<List<RecentShortcut>?>((ref) {
  final connected = ref.watch(activeConnectionProvider.select((c) => c.value != null));
  if (!connected) return null;
  final sessions = ref.watch(sessionsProvider);
  if (sessions.isLoading || !sessions.hasValue || sessions.hasError) {
    return null;
  }
  final host = ref.watch(activeHostProvider);
  return [
    for (final s in sessions.value!.take(maxRecentShortcuts))
      RecentShortcut(
        sessionId: s.sessionId,
        // The drawer's fallback (ui/shell/sessions_drawer.dart `sessionTitle`).
        title: switch (s.title?.trim()) {
          final t? when t.isNotEmpty => t,
          _ => appL10n.commonUntitledChat,
        },
        host: host,
      ),
  ];
});
