// DeepSeek's「导出所有历史对话」ZIP (chat.deepseek.com): one
// `chat_sessions/<id>.json` per conversation, each a tree of messages
// (`id` / `parent_id`) whose `current_message_id` names the branch last on
// screen, and a `chat_session_index.json` of when each was last used. A
// message is a list of fragments: what was asked (REQUEST), the reasoning
// (THINK), the reply (RESPONSE), DeepSeek's own canned refusals
// (TEMPLATE_RESPONSE), attached files (FILE).
//
// The field names are those DeepSeek's own importer reads
// (deepseek-ai/deepseek-harness, packages/experimental/deepseek-chat-import,
// MIT). Everything here is synchronous and reads the archive from its path,
// one entry at a time: callers run it off the main isolate.

import 'dart:convert';

import 'package:archive/archive_io.dart';

final _sessionEntry = RegExp(r'^chat_sessions/([^/]+)\.json$');

/// The largest conversation file read. One above it is left out of the list.
const deepSeekSessionMaxBytes = 128 * 1024 * 1024;

/// The file at a path is not a DeepSeek export.
class DeepSeekExportException implements Exception {
  const DeepSeekExportException();

  @override
  String toString() => 'Not a DeepSeek chat export.';
}

/// One conversation, as a list of them shows it.
class DeepSeekSessionSummary {
  const DeepSeekSessionSummary({required this.id, required this.title, required this.messageCount, this.updatedAt});

  final String id;
  final String title;

  /// Messages that would be taken in, over every branch.
  final int messageCount;
  final DateTime? updatedAt;
}

/// One message taken from a conversation.
class DeepSeekMessage {
  const DeepSeekMessage({
    required this.id,
    required this.parentId,
    required this.isUser,
    required this.text,
    required this.reasoning,
    required this.at,
    required this.hidden,
    required this.status,
  });

  final int id;

  /// The nearest message above it that was also taken; null at a root.
  final int? parentId;
  final bool isUser;
  final String text;
  final String? reasoning;
  final DateTime? at;

  /// A reply DeepSeek did not finish, withdrew, or answered with a canned
  /// refusal: kept to be read, never sent to a model again.
  final bool hidden;
  final String status;
}

/// One conversation: every branch, parents before their children.
class DeepSeekSession {
  DeepSeekSession({required this.id, required this.title, required this.messages, required this.currentId});

  final String id;
  final String title;
  final List<DeepSeekMessage> messages;

  /// Where the branch last on screen ends; null in an empty conversation.
  final int? currentId;

  /// The branch last on screen, oldest first.
  late final List<DeepSeekMessage> currentPath = () {
    final byId = {for (final message in messages) message.id: message};
    final path = <DeepSeekMessage>[];
    for (var at = byId[currentId]; at != null; at = byId[at.parentId]) {
      path.add(at);
    }
    return path.reversed.toList();
  }();
}

/// Whether the file at [path] is a DeepSeek export. Reads only the archive's
/// directory.
bool isDeepSeekExport(String path) {
  try {
    return _open(path, (entries) => true);
  } on Object {
    return false;
  }
}

/// The conversations in the export at [path], the longest first.
List<DeepSeekSessionSummary> listDeepSeekExport(String path) => _open(path, (entries) {
  final updated = _updatedAt(entries['chat_session_index.json']);
  final result = <DeepSeekSessionSummary>[];
  for (final MapEntry(key: id, value: entry) in _sessions(entries).entries) {
    final session = _read(id, entry);
    if (session == null || session.messages.isEmpty) continue;
    result.add(
      DeepSeekSessionSummary(
        id: id,
        title: session.title,
        messageCount: session.messages.length,
        updatedAt: updated[id] ?? session.messages.last.at,
      ),
    );
  }
  return result..sort((a, b) => b.messageCount.compareTo(a.messageCount));
});

/// The conversations named by [ids], in that order. One that is missing or
/// unreadable is left out.
List<DeepSeekSession> readDeepSeekSessions(String path, List<String> ids) => _open(path, (entries) {
  final sessions = _sessions(entries);
  return [
    for (final id in ids)
      if (sessions[id] case final entry?)
        if (_read(id, entry) case final session? when session.messages.isNotEmpty) session,
  ];
});

T _open<T>(String path, T Function(Map<String, ArchiveFile> entries) read) {
  final input = InputFileStream(path);
  try {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } on Object {
      throw const DeepSeekExportException();
    }
    final entries = {
      for (final entry in archive)
        if (entry.isFile) entry.name: entry,
    };
    if (_sessions(entries).isEmpty) throw const DeepSeekExportException();
    return read(entries);
  } finally {
    input.closeSync();
  }
}

Map<String, ArchiveFile> _sessions(Map<String, ArchiveFile> entries) => {
  for (final MapEntry(key: name, value: entry) in entries.entries)
    if (_sessionEntry.firstMatch(name) case final match?) match[1]!: entry,
};

Object? _json(ArchiveFile? entry) {
  if (entry == null || entry.size > deepSeekSessionMaxBytes) return null;
  try {
    return jsonDecode(utf8.decode(entry.content));
  } on FormatException {
    return null;
  } finally {
    entry.clear();
  }
}

Map<String, DateTime> _updatedAt(ArchiveFile? index) => {
  if (_json(index) case final List<Object?> rows)
    for (final row in rows.whereType<Map<String, Object?>>())
      if ((row['id'], _time(row['updated_at'])) case (final String id, final DateTime at)) id: at,
};

DateTime? _time(Object? value) => value is String ? DateTime.tryParse(value) : null;

DeepSeekSession? _read(String id, ArchiveFile entry) {
  final json = _json(entry);
  if (json is! Map<String, Object?> || json['messages'] is! List<Object?>) return null;
  final raw = <int, Map<String, Object?>>{
    for (final message in (json['messages']! as List<Object?>).whereType<Map<String, Object?>>())
      if (message['id'] case final int id) id: message,
  };
  final kept = <int, _Kept>{};
  for (final MapEntry(key: id, value: message) in raw.entries) {
    final isUser = message['role'] == 'USER';
    final text = <String>[];
    final reasoning = <String>[];
    var canned = false;
    for (final fragment in _list(message['fragments'])) {
      final content = fragment['content'];
      switch (fragment['type']) {
        case 'REQUEST' || 'RESPONSE' when content is String:
          text.add(content);
        case 'TEMPLATE_RESPONSE' when content is String:
          canned = true;
          text.add(content);
        case 'THINK' when content is String:
          reasoning.add(content);
        case 'FILE' when isUser:
          for (final file in _list(fragment['files'])) {
            if (file['file_name'] case final String name) text.add('〔$name〕');
          }
      }
    }
    final body = text.join('\n\n').trim();
    // A reply with nothing to read (it failed before a word) is not a message.
    if (body.isEmpty) continue;
    final status = message['status'] is String ? message['status']! as String : 'FINISHED';
    final thought = reasoning.join('\n\n').trim();
    kept[id] = (
      isUser: isUser,
      text: body,
      reasoning: thought.isEmpty ? null : thought,
      at: _time(message['inserted_at']),
      hidden: !isUser && (canned || status != 'FINISHED'),
      status: status,
    );
  }

  // The nearest kept message above [id]; a broken or looping chain is a root.
  int? keptAbove(int id) {
    var parent = raw[id]?['parent_id'];
    for (var steps = 0; parent is int && steps < raw.length; steps++) {
      if (kept.containsKey(parent)) return parent;
      parent = raw[parent]?['parent_id'];
    }
    return null;
  }

  final parents = {for (final id in kept.keys) id: keptAbove(id)};
  final depths = <int, int>{};
  for (final start in kept.keys) {
    final chain = <int>{};
    int? at = start;
    while (at != null && !depths.containsKey(at)) {
      // A chain that comes back to itself is cut there: its last link is a root.
      if (!chain.add(at)) {
        parents[chain.last] = null;
        at = null;
        break;
      }
      at = parents[at];
    }
    var depth = at == null ? 0 : depths[at]!;
    for (final link in chain.toList().reversed) {
      depths[link] = ++depth;
    }
  }

  final order = kept.keys.toList()
    ..sort((a, b) {
      final byDepth = depths[a]!.compareTo(depths[b]!);
      return byDepth != 0 ? byDepth : a.compareTo(b);
    });
  var current = json['current_message_id'];
  if (current is! int || !raw.containsKey(current)) {
    current = raw.keys.fold<int?>(null, (latest, id) => latest == null || id > latest ? id : latest);
  }
  if (current is int && !kept.containsKey(current)) current = keptAbove(current);
  final title = json['title'];
  return DeepSeekSession(
    id: id,
    title: title is String ? title.replaceAll(RegExp(r'\s+'), ' ').trim() : '',
    messages: [
      for (final id in order)
        DeepSeekMessage(
          id: id,
          parentId: parents[id],
          isUser: kept[id]!.isUser,
          text: kept[id]!.text,
          reasoning: kept[id]!.reasoning,
          at: kept[id]!.at,
          hidden: kept[id]!.hidden,
          status: kept[id]!.status,
        ),
    ],
    currentId: current is int ? current : (order.isEmpty ? null : order.last),
  );
}

List<Map<String, Object?>> _list(Object? value) =>
    value is List<Object?> ? value.whereType<Map<String, Object?>>().toList() : const [];

typedef _Kept = ({bool isUser, String text, String? reasoning, DateTime? at, bool hidden, String status});
