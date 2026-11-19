// One door for everything a tavern takes in (docs/design/roleplay-roadmap.md
// §4): what a picked file is — a card, a preset, a lorebook, regex, a quick
// reply set, a chat or 酒馆助手 scripts — told by its name and contents, never
// by asking.

import 'dart:convert';
import 'dart:typed_data';

import 'tavern_st_theme.dart';

enum TavernFileKind { card, preset, lorebook, regex, quickReplies, chat, stTheme, helperScripts, unknown }

/// What [bytes] (a file named [name]) is.
TavernFileKind tavernFileKindOf(String name, Uint8List bytes) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.charx')) return TavernFileKind.card;
  if (lower.endsWith('.png')) return tavernPngIsCard(bytes) ? TavernFileKind.card : TavernFileKind.unknown;
  if (lower.endsWith('.jsonl')) return TavernFileKind.chat;
  final json = _json(bytes);
  return switch (json) {
    final Map<String, Object?> map => _kindOfMap(map),
    final List<Object?> list when list.isNotEmpty && list.every((e) => e is Map && e.containsKey('findRegex')) =>
      TavernFileKind.regex,
    final List<Object?> list when list.isNotEmpty && list.every(_isHelperScript) => TavernFileKind.helperScripts,
    _ => TavernFileKind.unknown,
  };
}

TavernFileKind _kindOfMap(Map<String, Object?> map) {
  final spec = map['spec'];
  final data = map['data'];
  if ((spec is String && spec.startsWith('chara_card')) ||
      map.containsKey('first_mes') ||
      (data is Map && data.containsKey('first_mes'))) {
    return TavernFileKind.card;
  }
  if (_isHelperScript(map)) return TavernFileKind.helperScripts;
  if (map['format'] == 'dsh-preset-enhance') return TavernFileKind.preset;
  if (tavernIsStTheme(map)) return TavernFileKind.stTheme;
  if (map.containsKey('qrList')) return TavernFileKind.quickReplies;
  if (map.containsKey('findRegex')) return TavernFileKind.regex;
  if (spec == 'lorebook_v3' || map['entries'] is Map || map['entries'] is List) return TavernFileKind.lorebook;
  if (map.containsKey('prompts') ||
      map.containsKey('prompt_order') ||
      map.containsKey('openai_max_context') ||
      map.containsKey('openai_max_tokens')) {
    return TavernFileKind.preset;
  }
  return TavernFileKind.unknown;
}

/// A 酒馆助手 script ({type: script, content}) or folder of them ({type:
/// folder, scripts}), as it exports one.
bool _isHelperScript(Object? node) => switch (node) {
  {'type': 'script', 'content': String _} => true,
  {'type': 'folder', 'scripts': List<Object?> _} => true,
  _ => false,
};

/// [bytes] as JSON (a leading BOM allowed), or null.
Object? _json(Uint8List bytes) {
  try {
    var text = utf8.decode(bytes);
    if (text.startsWith('﻿')) text = text.substring(1);
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

/// A PNG `tEXt` chunk keyed `chara` (V2) or `ccv3` (V3). Goes chunk by
/// chunk: a card is mostly its picture, not worth reading byte by byte.
bool tavernPngIsCard(List<int> bytes) {
  bool keyed(int at, String key) {
    if (at + key.length + 1 > bytes.length) return false;
    for (var k = 0; k < key.length; k++) {
      if (bytes[at + k] != key.codeUnitAt(k)) return false;
    }
    return bytes[at + key.length] == 0;
  }

  var i = 8; // the signature
  while (i + 8 <= bytes.length) {
    final length = bytes[i] << 24 | bytes[i + 1] << 16 | bytes[i + 2] << 8 | bytes[i + 3];
    final type = String.fromCharCodes(bytes.sublist(i + 4, i + 8));
    if (type == 'tEXt' && (keyed(i + 8, 'chara') || keyed(i + 8, 'ccv3'))) return true;
    if (type == 'IEND') return false;
    i += 12 + length;
  }
  return false;
}

/// The character an ST chat file belongs to: its first line's
/// `character_name`, or null.
String? tavernChatCharacterName(Uint8List bytes) {
  try {
    var text = utf8.decode(bytes);
    if (text.startsWith('﻿')) text = text.substring(1);
    final first = const LineSplitter().convert(text).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    final head = jsonDecode(first);
    final name = head is Map ? head['character_name'] : null;
    return name is String && name.trim().isNotEmpty ? name.trim() : null;
  } on FormatException {
    return null;
  }
}

/// What an ST quick reply set says, as the replies the tavern keeps: each
/// one's message. Slash commands drive ST itself and have nothing to say
/// here; they are left out, and counted.
({List<String> replies, int skipped}) tavernQuickRepliesOf(Uint8List bytes) {
  final json = _json(bytes);
  final list = json is Map ? json['qrList'] : null;
  final replies = <String>[];
  var skipped = 0;
  for (final qr in list is List ? list : const []) {
    if (qr is! Map) continue;
    final message = qr['message'];
    if (message is! String || message.trim().isEmpty) continue;
    if (message.trimLeft().startsWith('/')) {
      skipped++;
    } else {
      replies.add(message.trim());
    }
  }
  return (replies: replies, skipped: skipped);
}
