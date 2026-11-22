// 引用追问. DSH has no quote in a prompt (the official composer sends text,
// attachments and `@` references only), so a quote travels as a Markdown
// blockquote in front of the message — what the model reads as "about this
// passage". The bubble shows it as a quote again ([splitQuote]).

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Longest passage sent, in characters; a longer one is cut with 「…」.
const maxQuoteLength = 1200;

/// [raw] tidied for quoting: line ends unified, trailing spaces and runs of
/// blank lines dropped, outer whitespace trimmed, at most [maxQuoteLength].
String normalizeQuote(String raw) {
  var text = raw
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  if (text.runes.length > maxQuoteLength) {
    text = '${String.fromCharCodes(text.runes.take(maxQuoteLength)).trimRight()}…';
  }
  return text;
}

/// [text] as sent with [quote] in front: every line of the quote behind
/// `> ` (blank ones as a bare `>`, so the block holds together), then a blank
/// line, then the message.
String withQuote(String quote, String text) {
  final passage = normalizeQuote(quote);
  if (passage.isEmpty) return text;
  final block = [for (final line in passage.split('\n')) line.isEmpty ? '>' : '> $line'].join('\n');
  final body = text.trim();
  return body.isEmpty ? block : '$block\n\n$body';
}

final _quoteLine = RegExp(r'^ {0,3}> ?');

/// A message split into the blockquote it opens with and the rest; [quote]
/// is null when it does not open with one.
({String? quote, String body}) splitQuote(String text) {
  if (!_quoteLine.hasMatch(text)) return (quote: null, body: text);
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  var i = 0;
  final quoted = <String>[];
  while (i < lines.length && _quoteLine.hasMatch(lines[i])) {
    quoted.add(lines[i].replaceFirst(_quoteLine, ''));
    i++;
  }
  final quote = quoted.join('\n').trim();
  if (quote.isEmpty) return (quote: null, body: text);
  // The block ends at a blank line or the first unquoted one.
  while (i < lines.length && lines[i].trim().isEmpty) {
    i++;
  }
  return (quote: quote, body: lines.skip(i).join('\n').trimRight());
}

/// [quote] on one line for the chip and the bubble: Markdown marks (emphasis,
/// code ticks, heading and list marks, nested `>`) dropped, whitespace
/// folded.
String quoteLine(String quote) => quote
    .replaceAll(RegExp(r'^\s{0,3}(#{1,6}|>+|[-*+]|\d+[.)])\s+', multiLine: true), '')
    .replaceAll(RegExp(r'\*\*|__|`+|~~'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// The passage waiting above each conversation's composer, by draft key (the
/// session id; `new` for the new-chat screen). Kept for the app run, like
/// draft attachments.
class ComposerQuotes extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};

  /// Quotes [passage] in conversation [key]; a blank one changes nothing.
  void set(String key, String passage) {
    final quote = normalizeQuote(passage);
    if (quote.isEmpty) return;
    state = Map.unmodifiable({...state, key: quote});
  }

  void clear(String key) {
    if (!state.containsKey(key)) return;
    state = Map.unmodifiable({...state}..remove(key));
  }

  /// Moves a new-chat quote with its draft in one notification. Keep any
  /// quote already placed in the destination.
  void move(String from, String to) {
    if (from == to) return;
    final quote = state[from];
    if (quote == null) return;
    state = Map.unmodifiable(
      {...state}
        ..remove(from)
        ..putIfAbsent(to, () => quote),
    );
  }
}

final composerQuoteProvider = NotifierProvider<ComposerQuotes, Map<String, String>>(ComposerQuotes.new);
