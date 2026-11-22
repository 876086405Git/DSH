// The `@` reference grammar on the app side: which spans of a draft or a sent
// message are references, and what they show. The wire format itself (what
// the official clients write) lives in dsh_client's `references_api.dart`.

import 'package:dsh_client/dsh_client.dart';

import '../../../l10n/l10n.dart';

/// What a reference points at.
enum MentionKind { file, folder, session }

/// One reference span `[start, end)` of a text, and how it reads.
class MentionToken {
  const MentionToken({required this.start, required this.end, required this.kind, required this.label});

  /// The token for [raw] placed at [start]; null when [raw] is not a
  /// reference.
  static MentionToken? fromRaw(String raw, int start) {
    final session = sessionMentionPattern.matchAsPrefix(raw);
    if (session != null && session.end == raw.length) {
      return MentionToken(
        start: start,
        end: start + raw.length,
        kind: MentionKind.session,
        label: unescapeMentionLabel(session[1]!),
      );
    }
    if (raw.length < 2 || !raw.startsWith('@')) return null;
    final quoted = raw.startsWith('@"');
    var path = raw.substring(quoted ? 2 : 1);
    if (quoted && path.endsWith('"')) path = path.substring(0, path.length - 1);
    if (path.isEmpty) return null;
    final folder = path.endsWith('/');
    final segments = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
    final name = segments.isEmpty ? path : segments.last;
    return MentionToken(
      start: start,
      end: start + raw.length,
      kind: folder ? MentionKind.folder : MentionKind.file,
      label: folder ? '$name/' : name,
    );
  }

  final int start;
  final int end;
  final MentionKind kind;

  /// What the chip shows: the file name, `folder/`, or the conversation title.
  final String label;

  int get length => end - start;

  MentionToken shifted(int delta) =>
      delta == 0 ? this : MentionToken(start: start + delta, end: end + delta, kind: kind, label: label);

  @override
  bool operator ==(Object other) =>
      other is MentionToken && other.start == start && other.end == end && other.kind == kind && other.label == label;

  @override
  int get hashCode => Object.hash(start, end, kind, label);

  @override
  String toString() => 'MentionToken($kind "$label" $start..$end)';
}

/// Session labels this app has seen in canonical mentions or in the picker.
///
/// The Host stores a sent conversation reference as plain `@label`, so a
/// sent bubble recognises one by its label (the official client reads the
/// same facts from its session list). Plain memory: it only adds.
abstract final class MentionLabels {
  static final Set<String> _labels = {};

  static Iterable<String> get all => _labels;

  static void add(String label) {
    final trimmed = label.trim();
    if (trimmed.isNotEmpty) _labels.add(trimmed);
  }

  static void addAll(Iterable<String> labels) => labels.forEach(add);
}

// A token starts at the text start or after whitespace (an email address is
// not a reference). Quoted paths first; an open quoted folder (`@"a b/`)
// ends at its slash.
final RegExp _pathToken = RegExp(r'(?<!\S)(@"[^"\n]+"|@"[^"\n]*/(?=\s|$)|@[^\s"]+)');
// l10n:keep Mention grammar matches Chinese and ASCII punctuation.
final RegExp _trailingPunctuation = RegExp(r'[.,;:!?，。；：！？、）)]+$');

/// References in a sent message, for the bubble.
///
/// - canonical conversation mentions (`@[标题](dsh-session:…)`);
/// - `@label` for a conversation label in [labels] (longest wins);
/// - quoted paths, and bare `@path` tokens that look like a path (a slash, a
///   dot inside the name, or `~`) — a lone `@word` stays text;
/// - trailing punctuation is not part of a bare path.
List<MentionToken> parseMessageMentions(String text, {Iterable<String> labels = const []}) {
  if (!text.contains('@')) return const [];
  final tokens = <MentionToken>[];
  for (final m in sessionMentionPattern.allMatches(text)) {
    tokens.add(MentionToken(start: m.start, end: m.end, kind: MentionKind.session, label: unescapeMentionLabel(m[1]!)));
  }
  bool free(int start, int end) => !tokens.any((t) => t.start < end && start < t.end);

  final known = labels.where((l) => l.isNotEmpty).toList()..sort((a, b) => b.length.compareTo(a.length));
  if (known.isNotEmpty) {
    for (var at = text.indexOf('@'); at >= 0; at = text.indexOf('@', at + 1)) {
      if (at > 0 && !_isSpace(text.codeUnitAt(at - 1))) continue;
      for (final label in known) {
        if (!text.startsWith(label, at + 1)) continue;
        final end = at + 1 + label.length;
        // A label ends at a word boundary, not halfway through a word.
        if (end < text.length && !_isBoundary(text.codeUnitAt(end))) continue;
        if (free(at, end)) {
          tokens.add(MentionToken(start: at, end: end, kind: MentionKind.session, label: label));
        }
        break;
      }
    }
  }

  for (final m in _pathToken.allMatches(text)) {
    var raw = m[0]!;
    if (!raw.startsWith('@"')) {
      raw = raw.replaceFirst(_trailingPunctuation, '');
      if (!_looksLikePath(raw.substring(1))) continue;
    }
    if (raw.length < 2 || !free(m.start, m.start + raw.length)) continue;
    final token = MentionToken.fromRaw(raw, m.start);
    if (token != null) tokens.add(token);
  }
  tokens.sort((a, b) => a.start.compareTo(b.start));
  return tokens;
}

/// References in text that arrives in the composer as a whole (a restored or
/// pasted prompt): canonical conversation mentions, quoted paths and path-like
/// bare tokens.
List<MentionToken> parseDraftMentions(String text, [int from = 0, int? to]) {
  final end = to ?? text.length;
  return [
    for (final t in parseMessageMentions(text))
      if (t.start >= from && t.end <= end) t,
  ];
}

bool _looksLikePath(String path) {
  if (path.isEmpty) return false;
  if (path.contains('/') || path.startsWith('~')) return true;
  // `README.md`, `main.dart`: a dot inside, followed by a letter or digit.
  return RegExp(r'^[^.]+\.[A-Za-z0-9]').hasMatch(path) || RegExp(r'^\.[A-Za-z0-9]').hasMatch(path);
}

bool _isSpace(int unit) => unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D || unit == 0x3000;

bool _isBoundary(int unit) =>
    // l10n:keep Mention grammar recognizes Chinese and ASCII boundaries.
    _isSpace(unit) || '，。；：！？、,.;:!?)）'.codeUnits.contains(unit);

/// The `@` token being typed at the caret (`activeAtToken` in the official
/// grammar): from its `@` to the caret. Null when the caret is not in one,
/// or when the `@` starts a reference already in [tokens].
class MentionQuery {
  const MentionQuery({required this.start, required this.end, required this.query, required this.quoted});

  /// Where the `@` is.
  final int start;

  /// The caret.
  final int end;

  /// Text after `@` (or `@"`).
  final String query;
  final bool quoted;

  /// A path is being typed: only files apply.
  bool get pathOnly => quoted || query.contains('/');

  @override
  bool operator ==(Object other) =>
      other is MentionQuery &&
      other.start == start &&
      other.end == end &&
      other.query == query &&
      other.quoted == quoted;

  @override
  int get hashCode => Object.hash(start, end, query, quoted);
}

final RegExp _quotedQuery = RegExp(r'(?:^|\s)(@"([^"]*))$');
final RegExp _plainQuery = RegExp(r'(?:^|\s)(@([^\s]*))$');

MentionQuery? activeMentionQuery(String text, int caret, {List<MentionToken> tokens = const []}) {
  if (caret < 1 || caret > text.length) return null;
  // Only the current line matters.
  final lineStart = text.lastIndexOf('\n', caret - 1) + 1;
  final before = text.substring(lineStart, caret);
  if (!before.contains('@')) return null;
  final match = _quotedQuery.firstMatch(before) ?? _plainQuery.firstMatch(before);
  if (match == null) return null;
  final quoted = match[1]!.startsWith('@"');
  final start = lineStart + match.start + match[0]!.indexOf('@');
  if (tokens.any((t) => t.start <= start && start < t.end)) return null;
  return MentionQuery(start: start, end: caret, query: match[2]!, quoted: quoted);
}

/// Fuzzy score of [text] for [query] (higher is better); null when the
/// query's characters do not all appear in order.
///
/// Prefix > word start > substring > in-order characters; shorter texts win
/// ties.
double? fuzzyScore(String text, String query) {
  if (query.isEmpty) return 0;
  final t = text.toLowerCase();
  final q = query.toLowerCase();
  final at = t.indexOf(q);
  if (at == 0) return 1000 - t.length.toDouble();
  if (at > 0) {
    final previous = t.codeUnitAt(at - 1);
    final wordStart = _isSpace(previous) || '/_-.'.codeUnits.contains(previous);
    return (wordStart ? 800 : 600) - at - t.length / 100;
  }
  var ti = 0;
  var gaps = 0;
  for (final unit in q.codeUnits) {
    final next = t.indexOf(String.fromCharCode(unit), ti);
    if (next < 0) return null;
    gaps += next - ti;
    ti = next + 1;
  }
  return 300 - gaps - t.length / 100;
}

/// Age as the official reference menu words it: 刚刚 / 5分钟 / 3小时 / 2天 /
/// 4个月 / 1年.
String mentionAge(DateTime time, DateTime now) {
  final d = now.difference(time);
  if (d.inMinutes < 1) return appL10n.chatJustNow;
  if (d.inHours < 1) return appL10n.chatMentionAgeMinutes(d.inMinutes);
  if (d.inDays < 1) return appL10n.chatMentionAgeHours(d.inHours);
  if (d.inDays < 30) return appL10n.chatMentionAgeDays(d.inDays);
  if (d.inDays < 365) return appL10n.chatMentionAgeMonths(d.inDays ~/ 30);
  return appL10n.chatMentionAgeYears(d.inDays ~/ 365);
}
