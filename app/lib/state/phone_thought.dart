// What DSH thinks while it drives the phone: the card of the phone-control
// island shows its newest words from the chat next to the steps it takes, so
// the person can follow why it does what it does (docs/design/phone-overlay.md
// §6). Read off the transcript of each conversation driving the phone and sent
// to native (`setPhoneThought`) at most every [PhoneThoughtsController.gap].

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_state.dart';
import 'connection_state.dart';
import 'phone_state.dart';

/// The words worth showing from [items]: in the turn since the person last
/// spoke, the newest assistant reply's last paragraph — or, while it has said
/// nothing yet, the last paragraph of its reasoning. Plain text (no Markdown
/// marks), on one line; null when there is nothing.
String? phoneThoughtOf(List<ChatItem> items) {
  for (var i = items.length - 1; i >= 0; i--) {
    final item = items[i];
    if (item is UserChatItem) return null;
    if (item is AssistantChatItem) {
      final words = _lastParagraph(item.text) ?? _lastParagraph(item.reasoning);
      if (words != null) return words;
    }
  }
  return null;
}

final _blankLine = RegExp(r'\n\s*\n');
final _linePrefix = RegExp(r'^\s*(?:#{1,6}\s+|>\s?|[-*+]\s+|\d+[.)]\s+)', multiLine: true);
final _marks = RegExp(r'(\*\*|__|`+|~~)');
final _link = RegExp(r'\[([^\]]*)\]\([^)]*\)');
final _space = RegExp(r'\s+');

String? _lastParagraph(String text) {
  final paragraphs = text.trim().split(_blankLine).where((p) => p.trim().isNotEmpty);
  if (paragraphs.isEmpty) return null;
  var words = paragraphs.last;
  // A code block says nothing to someone watching the phone.
  if (words.trimLeft().startsWith('```')) return null;
  words = words.replaceAll(_linePrefix, '').replaceAllMapped(_link, (m) => m[1] ?? '').replaceAll(_marks, '');
  words = words.replaceAll(_space, ' ').trim();
  if (words.isEmpty) return null;
  return words.length > maxPhoneThought ? words.substring(words.length - maxPhoneThought) : words;
}

/// Native keeps this much from the end (PhoneThoughts.MAX_CHARS).
const maxPhoneThought = 600;

/// Follows every conversation that drives the phone now (a native task with
/// its conversation, on this phone's own engine) and keeps native told what it
/// last said; forgets a conversation once its task is gone. Kept alive under
/// the home shell (PhoneStopWatcher).
class PhoneThoughtsController extends Notifier<void> {
  static const gap = Duration(milliseconds: 400);

  final _subs = <String, ProviderSubscription<String?>>{};
  final _latest = <String, String?>{};
  final _sent = <String, String?>{};
  final _timers = <String, Timer>{};

  @override
  void build() {
    ref.listen(phoneProvider.select((s) => _sessionsKey(s.status)), (_, key) => _sync(key), fireImmediately: true);
    // Another host in front: its chats aren't this phone's; follow again once ours is.
    ref.listen(activeConnectionProvider.select((c) => c.value?.isLocal == true), (_, local) {
      if (!local) _sync('');
      _sync(_sessionsKey(ref.read(phoneProvider).status));
    });
    ref.onDispose(() {
      for (final sub in _subs.values) {
        sub.close();
      }
      for (final timer in _timers.values) {
        timer.cancel();
      }
      _subs.clear();
      _timers.clear();
    });
  }

  /// The conversations driving the phone, as one comparable value.
  static String _sessionsKey(PhoneStatus status) {
    final ids = <String>{
      for (final task in status.tasks)
        if (task.active && task.sessionId != null) task.sessionId!,
    }.toList()..sort();
    return ids.join('\n');
  }

  PhoneChannel get _channel => ref.read(phoneChannelProvider);

  void _sync(String key) {
    final local = ref.read(activeConnectionProvider).value?.isLocal == true;
    final want = key.isEmpty || !local ? <String>{} : key.split('\n').toSet();
    for (final gone in _subs.keys.where((s) => !want.contains(s)).toList()) {
      _subs.remove(gone)?.close();
      _timers.remove(gone)?.cancel();
      _latest.remove(gone);
      if (_sent.remove(gone) != null) unawaited(_channel.setPhoneThought(gone, null));
    }
    for (final session in want) {
      if (_subs.containsKey(session)) continue;
      // Subscribed first, then the thought already there offered: a listener fired at once would
      // reach _flush before the subscription is kept, and drop it.
      final sub = ref.listen(
        chatProvider(session).select((chat) => phoneThoughtOf(chat.items)),
        (_, thought) => _offer(session, thought),
      );
      _subs[session] = sub;
      _offer(session, sub.read());
    }
  }

  /// The first change goes at once, the rest at most every [gap] (the newest then).
  void _offer(String session, String? thought) {
    _latest[session] = thought;
    if (_timers[session]?.isActive == true) return;
    _flush(session);
  }

  void _flush(String session) {
    if (!_subs.containsKey(session)) return;
    final thought = _latest[session];
    if (thought != _sent[session]) {
      _sent[session] = thought;
      unawaited(_channel.setPhoneThought(session, thought));
    }
    _timers[session] = Timer(gap, () {
      if (_latest[session] != _sent[session]) _flush(session);
    });
  }
}

final phoneThoughtsProvider = NotifierProvider<PhoneThoughtsController, void>(PhoneThoughtsController.new);
