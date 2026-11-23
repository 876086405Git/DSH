// What the companion's reply text carries besides words: `[表情:开心]` and
// `[动作:点头]` marks, written by the model as the persona asks
// (runtime/bridge/dsh-go-bridge/cordis.patch.yml). The page shows the words and
// hands the marks to the stage. Pure full-text parsing, with a reader that
// keeps the safe prefixes of one growing Agent reply.

import 'package:flutter/foundation.dart';

/// A faces the stage knows (`emotions` in app/assets/companion/stage.js).
const _emotions = {
  '平静': 'calm',
  'calm': 'calm',
  '开心': 'happy',
  '高兴': 'happy',
  'happy': 'happy',
  '害羞': 'shy',
  '脸红': 'shy',
  'shy': 'shy',
  '难过': 'sad',
  '伤心': 'sad',
  'sad': 'sad',
  '生气': 'angry',
  '黑脸': 'angry',
  'angry': 'angry',
  '惊讶': 'surprised',
  'surprised': 'surprised',
  '疑惑': 'confused',
  '困惑': 'confused',
  'confused': 'confused',
  '得意': 'smug',
  'smug': 'smug',
  '困': 'sleepy',
  '犯困': 'sleepy',
  'sleepy': 'sleepy',
  '担心': 'worried',
  'worried': 'worried',
};

const _actions = {
  '点头': 'nod',
  'nod': 'nod',
  '摇头': 'shake',
  'shake': 'shake',
  '歪头': 'tilt',
  'tilt': 'tilt',
  '抬头': 'lookUp',
  'lookUp': 'lookUp',
  '低头': 'duck',
  'duck': 'duck',
  '挥手': 'wave',
  'wave': 'wave',
  '跳一下': 'hop',
  '蹦': 'hop',
  'hop': 'hop',
  '摇尾巴': 'tail',
  'tail': 'tail',
};

enum CompanionMarkKind { emotion, action }

/// Whether [name] is already one of her own marks, which a model's own move of
/// the same name can't take over.
bool companionMarkKnown(CompanionMarkKind kind, String name) {
  final known = kind == CompanionMarkKind.emotion ? _emotions : _actions;
  return known.containsKey(name) || known.containsKey(name.toLowerCase());
}

@immutable
class CompanionMark {
  const CompanionMark(this.kind, this.name, {this.native = false});

  final CompanionMarkKind kind;

  /// The stage's name for it.
  final String name;

  /// One of the model's own expressions or motions, by its raw name.
  final bool native;

  @override
  bool operator ==(Object other) =>
      other is CompanionMark && other.kind == kind && other.name == name && other.native == native;

  @override
  int get hashCode => Object.hash(kind, name, native);

  @override
  String toString() => '${kind.name}:$name';
}

@immutable
class CompanionReply {
  const CompanionReply(this.words, this.marks, [this._rawOffsets = const []]);

  /// What to show: the text without marks.
  final String words;

  /// Marks in the order they appear; unknown names are dropped.
  final List<CompanionMark> marks;

  // Each displayed UTF-16 unit still belongs to its original whole-turn text.
  // Removed marks, held partial marks and trimmed whitespace have no entry.
  final Iterable<int> _rawOffsets;

  /// The non-blank word ranges contributed by one saved raw source range.
  /// Parse the whole turn first: a mark can cross a model-round boundary.
  List<({int start, int end})> wordRangesFrom(int rawStart, int rawEnd) {
    final ranges = <({int start, int end})>[];
    final offsets = _rawOffsets.iterator;
    int? start;
    for (var i = 0; i <= words.length; i++) {
      final belongs =
          offsets.moveNext() && offsets.current >= rawStart && offsets.current < rawEnd && words[i].trim().isNotEmpty;
      if (belongs) {
        start ??= i;
      } else if (start != null) {
        ranges.add((start: start, end: i));
        start = null;
      }
    }
    return ranges;
  }
}

final _mark = RegExp(r'[\[【]\s*(表情|动作|emotion|action)\s*[:：]\s*([^\]】\n]{1,40}?)\s*[\]】]', caseSensitive: false);

/// Whether a label can be written in a mark at all.
bool companionMarkLabelFits(String label) {
  final trimmed = label.trim();
  return trimmed.isNotEmpty && trimmed == label && label.length <= 40 && !label.contains(RegExp(r'[\]】\n]'));
}

/// [name] in a model's own labels: exactly, else ignoring case.
String? _own(Map<String, String> labels, String name) {
  final exact = labels[name];
  if (exact != null) return exact;
  final lower = name.toLowerCase();
  for (final MapEntry(:key, :value) in labels.entries) {
    if (key.toLowerCase() == lower) return value;
  }
  return null;
}

/// A mark still arriving at the end of the stream: held back so it never flashes.
final _partialMark = RegExp(
  r'[\[【](?:\s*(?:表|表情|动|动作|e|em|emo|emot|emoti|emotio|emotion|a|ac|act|acti|actio|action)?\s*(?:[:：][^\]】\n]{0,40})?)?$',
  caseSensitive: false,
);

/// Reads [text]. While [streaming], a trailing partial mark is held back.
/// [emotions] and [actions] map the labels of the model's own expressions and
/// motions to their raw names (companion_moves.dart); hers come first, since
/// they carry her pose as well as a face.
CompanionReply parseCompanionReply(
  String text, {
  bool streaming = false,
  Map<String, String> emotions = const {},
  Map<String, String> actions = const {},
}) => _parseReplyPart(text, streaming: streaming, emotions: emotions, actions: actions).reply;

/// Reads growing prefixes of one Agent run with a fixed move directory.
/// A replacement run or directory starts a new reader.
class CompanionReplyStream {
  CompanionReplyStream({this.emotions = const {}, this.actions = const {}});

  final Map<String, String> emotions;
  final Map<String, String> actions;
  final _offsets = <int>[];
  var _end = 0;
  var _committed = const CompanionReply('', []);

  CompanionReply read(String text, {required bool streaming}) {
    if (text.length == _end) return _committed;
    final part = _parseReplyPart(
      text.substring(_end),
      streaming: streaming,
      emotions: emotions,
      actions: actions,
      base: _end,
      hasWords: _committed.words.isNotEmpty,
      findCut: true,
    );
    final tail = part.reply;
    final words = tail.words.isEmpty ? _committed.words : _committed.words + tail.words;
    final marks = tail.marks.isEmpty
        ? _committed.marks
        : List<CompanionMark>.unmodifiable([..._committed.marks, ...tail.marks]);
    if (part.canCommit) {
      _end = text.length;
      _offsets.addAll(tail._rawOffsets);
      // A frame may still hold an older reply. Its take count never changes.
      return _committed = CompanionReply(words, marks, _offsets.take(_offsets.length));
    }
    return CompanionReply(words, marks, _offsets.take(_offsets.length).followedBy(tail._rawOffsets));
  }
}

({CompanionReply reply, bool canCommit}) _parseReplyPart(
  String text, {
  required bool streaming,
  required Map<String, String> emotions,
  required Map<String, String> actions,
  int base = 0,
  bool hasWords = false,
  bool findCut = false,
}) {
  final marks = <CompanionMark>[];
  final kept = StringBuffer();
  final rawOffsets = <int>[];
  var cursor = 0;
  for (final m in _mark.allMatches(text)) {
    kept.write(text.substring(cursor, m.start));
    rawOffsets.addAll([for (var i = cursor; i < m.start; i++) base + i]);
    cursor = m.end;
    final kind = m[1]!.toLowerCase();
    final name = m[2]!;
    if (kind == '表情' || kind == 'emotion') {
      final hers = _emotions[name] ?? _emotions[name.toLowerCase()];
      final own = hers == null ? _own(emotions, name) : null;
      if (hers != null) marks.add(CompanionMark(CompanionMarkKind.emotion, hers));
      if (own != null) marks.add(CompanionMark(CompanionMarkKind.emotion, own, native: true));
    } else {
      final hers = _actions[name] ?? _actions[name.toLowerCase()];
      final own = hers == null ? _own(actions, name) : null;
      if (hers != null) marks.add(CompanionMark(CompanionMarkKind.action, hers));
      if (own != null) marks.add(CompanionMark(CompanionMarkKind.action, own, native: true));
    }
  }
  kept.write(text.substring(cursor));
  rawOffsets.addAll([for (var i = cursor; i < text.length; i++) base + i]);
  var words = kept.toString();
  // Any open raw mark still able to cross the cut starts after the last
  // complete mark, in the literal tail of kept. Kept can also have a partial
  // mark assembled across removed marks. Check it before hiding or trimming.
  final canCommit = findCut && _safeReplyEnd(words);
  if (streaming) {
    final partial = _partialMark.firstMatch(words);
    if (partial != null) {
      words = words.substring(0, partial.start);
      rawOffsets.removeRange(partial.start, rawOffsets.length);
    }
  }
  final normalized = StringBuffer();
  final offsets = <int>[];
  cursor = 0;
  for (final spaces in RegExp(r'[ \t]{2,}').allMatches(words)) {
    normalized
      ..write(words.substring(cursor, spaces.start))
      ..write(' ');
    offsets
      ..addAll(rawOffsets.getRange(cursor, spaces.start))
      ..add(rawOffsets[spaces.start]);
    cursor = spaces.end;
  }
  normalized.write(words.substring(cursor));
  offsets.addAll(rawOffsets.getRange(cursor, rawOffsets.length));
  final untrimmed = normalized.toString();
  final start = hasWords ? 0 : untrimmed.length - untrimmed.trimLeft().length;
  final visible = hasWords ? untrimmed.trimRight() : untrimmed.trim();
  return (
    reply: CompanionReply(visible, marks, List<int>.unmodifiable(offsets.sublist(start, start + visible.length))),
    canCommit: canCommit,
  );
}

bool _safeReplyEnd(String kept) {
  if (kept.isEmpty) return true;
  if (kept[kept.length - 1].trim().isEmpty) return false;
  // Both kinds of closer terminate either kind of opener.
  for (var i = kept.length - 1; i >= 0; i--) {
    switch (kept.codeUnitAt(i)) {
      case 0x5b || 0x3010: // [ 【
        return false;
      case 0x5d || 0x3011: // ] 】
        return true;
    }
  }
  return true;
}

/// What goes in front of a message the person sends: the small facts the model
/// can't otherwise know, in the 〔〕 aside the persona explains. Null without any.
String? companionAside({DateTime? now, List<String> notes = const []}) {
  final parts = [
    if (now != null)
      '${now.month}月${now.day}日 ${_weekday[now.weekday - 1]} '
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
    for (final note in notes) note.replaceAll(RegExp(r'\s*\n\s*'), ' '),
  ];
  return parts.isEmpty ? null : '〔${parts.join('，')}〕';
}

const _weekday = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// The aside line [companionAside] writes: it always starts with the date.
final _asideLine = RegExp(r'^〔\d{1,2}月\d{1,2}日 周[一二三四五六日] \d{2}:\d{2}[^\n]*〕$');

/// What the person actually typed, out of a message the page sent: whatever
/// the page put in front of it (the persona, its changes, her name, moves) all
/// comes before the aside, and the aside comes last. A message with no aside
/// is already only theirs.
String companionSaidText(String sent) {
  final lines = sent.split('\n');
  final aside = lines.indexWhere(_asideLine.hasMatch);
  if (aside < 0) return sent;
  return lines.skip(aside + 1).join('\n').trim();
}

/// How to greet someone coming back, from the clock and how long they were
/// away. Never reproachful: absence is news to her, not a debt.
enum CompanionGreeting { firstTime, morning, noon, afternoon, evening, lateNight, longAbsence, justNow }

CompanionGreeting companionGreeting(DateTime now, DateTime? lastSeen) {
  if (lastSeen == null) return CompanionGreeting.firstTime;
  final away = now.difference(lastSeen);
  if (away < const Duration(minutes: 20)) return CompanionGreeting.justNow;
  if (away > const Duration(days: 3)) return CompanionGreeting.longAbsence;
  return switch (now.hour) {
    >= 0 && < 5 => CompanionGreeting.lateNight,
    < 11 => CompanionGreeting.morning,
    < 14 => CompanionGreeting.noon,
    < 18 => CompanionGreeting.afternoon,
    < 23 => CompanionGreeting.evening,
    _ => CompanionGreeting.lateNight,
  };
}
