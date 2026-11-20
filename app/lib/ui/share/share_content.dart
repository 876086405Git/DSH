// What a share card shows (晒成果), built from the conversation, and the text work
// done before it is drawn: the same redaction as a shared file or link
// (credentials, home folders, app storage), visual replies summarised,
// pictures gathered into galleries and long code lines folded.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart';

import '../../l10n/l10n.dart';
import '../../share_code/conversation_redact.dart' show redactText;
import '../../state/app_notes.dart';
import '../../state/chat_state.dart';
import '../../update/update_config.dart' show updateRepo;
import '../chat/dsh_ui/dsh_ui.dart';
import '../chat/run_info.dart' show formatSpan;

/// The project page every card's QR code and footer point at.
const dshGoProjectUrl = 'https://github.com/$updateRepo';

/// One piece of a share card's body.
@immutable
sealed class ShareBlock {
  const ShareBlock();
}

/// What the person asked: plain text in a bubble, the pictures they attached
/// above it (as the chat draws them). Either may be empty, not both.
final class ShareQuestion extends ShareBlock {
  const ShareQuestion(this.text, {this.images = const []});
  final String text;
  final List<ShareImage> images;
}

/// A reply: Markdown (code, maths, tables, pictures) drawn with the chat's
/// renderer; its `![…](…)` pictures become galleries ([shareSegments]).
final class ShareAnswer extends ShareBlock {
  const ShareAnswer(this.markdown, {this.turn});
  final String markdown;
  final int? turn;
}

/// A delivered file: an image preview, or a file tile with an excerpt.
final class ShareFile extends ShareBlock {
  const ShareFile({
    required this.name,
    required this.typeLabel,
    this.description,
    this.image,
    this.excerpt,
    this.excerptLanguage,
  });

  final String name;

  /// `图片 · PNG · 84.2 KB`.
  final String typeLabel;
  final String? description;
  final ImageProvider? image;

  /// The first lines of a text / Markdown file; [excerptLanguage] null means
  /// Markdown, otherwise it is shown as code in that language.
  final String? excerpt;
  final String? excerptLanguage;
}

/// A plugin from the market.
final class SharePlugin extends ShareBlock {
  const SharePlugin({
    required this.name,
    required this.title,
    this.author,
    this.description,
    this.icon,
    this.facts = const [],
  });

  /// Package name (also picks the avatar tint).
  final String name;
  final String title;
  final String? author;
  final String? description;

  /// `https://` or `data:` image, as in the market index.
  final String? icon;

  /// Up to three `(value, label)` pairs: version, stars, update date.
  final List<(String, String)> facts;
}

// ── Pictures ────────────────────────────────────────────────────────────────

/// Where a picture on a card comes from. The card fetches it the way the chat
/// does (`share_gallery.dart`) and waits for it before it is exported.
@immutable
sealed class ShareImage {
  const ShareImage();

  /// Width / height when known before the bytes arrive.
  double? get aspect => null;
}

/// A picture the person attached to a prompt (`session/attachment`).
final class ShareAttachmentImage extends ShareImage {
  const ShareAttachmentImage(this.attachment);

  /// The whole reference: a 0.2.2 engine checks all of it when asked for the bytes.
  final ImageAttachment attachment;

  String get attachmentId => attachment.attachmentId;

  @override
  double? get aspect {
    final w = attachment.width, h = attachment.height;
    return w != null && h != null && w > 0 && h > 0 ? w / h : null;
  }
}

/// A picture a reply points at (`![…](chart.png)`): a workspace file, a web
/// address or a `data:` URL.
final class ShareUrlImage extends ShareImage {
  const ShareUrlImage(this.url, {this.turn});
  final String url;
  final int? turn;
}

/// A picture already in hand (tests, a file's preview).
final class ShareProvidedImage extends ShareImage {
  const ShareProvidedImage(this.provider, {this.knownAspect});

  final ImageProvider provider;

  /// Width / height, when the caller knows it.
  final double? knownAspect;

  @override
  double? get aspect => knownAspect;
}

/// How the pictures of one message are laid out: one at its own aspect
/// ratio, two side by side, three as one tall and two stacked, four and more
/// as a 2 × 2 grid with 「+N」 on the fourth.
abstract final class ShareGalleryLayout {
  /// Between cells.
  static const gap = 4.0;

  /// Outer corners of a gallery (the code wells' radius); inner corners are
  /// [innerRadius].
  static const radius = 14.0;
  static const innerRadius = 4.0;

  /// A prompt's pictures: right-aligned above the bubble, at most this wide.
  static const questionWidth = 240.0;

  /// Tallest a lone picture is drawn (a reply's / a prompt's).
  static const answerMaxHeight = 400.0;
  static const questionMaxHeight = 240.0;

  /// Width / height of the three- and four-up frames.
  static double frameAspect({required bool question}) => question ? 1 : 4 / 3;

  /// Shape assumed for a lone picture whose size is not known yet.
  static double fallbackAspect({required bool question}) => question ? 1 : 4 / 3;

  /// Cells drawn for [count] pictures.
  static int cells(int count) => count > 4 ? 4 : count;

  /// The size of a lone picture of [aspect] in a [width] column.
  static Size single(double width, double aspect, {required bool question}) {
    final maxHeight = question ? questionMaxHeight : answerMaxHeight;
    var w = width;
    var h = w / aspect;
    if (h > maxHeight) {
      h = maxHeight;
      w = h * aspect;
    }
    return Size(w, h);
  }

  /// Height of a gallery of [count] pictures [width] wide (a lone one at
  /// [aspect], or the fallback).
  static double height(int count, double width, {required bool question, double? aspect}) {
    if (count <= 0) return 0;
    if (count == 1) {
      return single(width, aspect ?? fallbackAspect(question: question), question: question).height;
    }
    if (count == 2) return (width - gap) / 2;
    return width / frameAspect(question: question);
  }
}

// ── The card's content ──────────────────────────────────────────────────────

/// One kind of work in the turns behind a card: 「联网搜索 3」.
@immutable
class ShareProcessItem {
  const ShareProcessItem(this.label, this.count, {required this.tool});

  final String label;
  final int count;

  /// A tool of this kind (its icon).
  final String tool;

  @override
  bool operator ==(Object other) =>
      other is ShareProcessItem && other.label == label && other.count == count && other.tool == tool;

  @override
  int get hashCode => Object.hash(label, count, tool);

  @override
  String toString() => '$label $count';
}

/// Everything a share card needs.
@immutable
class ShareContent {
  const ShareContent({
    this.title,
    required this.blocks,
    this.model,
    this.stats,
    this.process = const [],
    this.link = dshGoProjectUrl,
    this.sessionId,
  });

  /// The conversation's title (or the plugin's name).
  final String? title;
  final List<ShareBlock> blocks;

  /// `deepseek-v4-pro`.
  final String? model;

  /// `53 秒 · 8 步`: one capsule per part.
  final String? stats;

  /// What the agent did on the way (most frequent first), under the meta.
  final List<ShareProcessItem> process;

  /// Where the QR code goes.
  final String link;

  /// The conversation the pictures come from; null: the one open in the chat.
  final String? sessionId;

  bool get hasQuestion => blocks.any((b) => b is ShareQuestion);
  bool get hasMeta => model != null || stats != null || process.isNotEmpty;
  bool get isConversation => blocks.any((b) => b is ShareAnswer || b is ShareQuestion);

  /// The meta capsules: model, time, steps.
  List<String> get metaPills => [
    ?model,
    if (stats case final s?)
      for (final part in s.split(' · '))
        if (part.trim().isNotEmpty) part.trim(),
  ];

  ShareContent copyWith({List<ShareBlock>? blocks, String? sessionId}) => ShareContent(
    title: title,
    blocks: blocks ?? this.blocks,
    model: model,
    stats: stats,
    process: process,
    link: link,
    sessionId: sessionId ?? this.sessionId,
  );
}

// ── Text preparation ─────────────────────────────────────────────────────────

/// A prompt as it goes on a card: redacted, blank runs folded.
String shareQuestionText(String text) => redactText(text).replaceAll(RegExp(r'\n\s*\n+'), '\n').trim();

/// A conversation title as it goes on a card.
String? shareTitleText(String? title) {
  final t = title?.trim();
  if (t == null || t.isEmpty) return null;
  return redactText(t);
}

/// `![alt](url)`, optionally wrapped in a link: `[![alt](url)](href)`. An
/// address may hold one level of balanced parentheses.
final _image = RegExp(
  r'\[!\[([^\]\n]*)\]\(((?:[^()\n]|\([^()\n]*\))*)\)\]\([^)\n]*\)|!\[([^\]\n]*)\]\(((?:[^()\n]|\([^()\n]*\))*)\)',
);
final _fence = RegExp(r'^\s{0,3}(`{3,}|~{3,})(.*)$');

/// The address of an `_image` match, without a `"title"`.
String _imageUrl(Match m) {
  final raw = (m.group(2) ?? m.group(4) ?? '').trim();
  final titled = RegExp(r'''^(\S+)\s+["'(].*$''').firstMatch(raw);
  return titled?.group(1) ?? raw;
}

bool _closes(String line, String fence) {
  final close = _fence.firstMatch(line);
  return close != null &&
      close.group(1)![0] == fence[0] &&
      close.group(1)!.length >= fence.length &&
      close.group(2)!.trim().isEmpty;
}

/// A reply as it goes on a card: visual replies as their one-line summary,
/// redacted like a shared file (`•` for masked characters, which Markdown
/// leaves alone).
///
/// With [images] the reply's pictures stay (their addresses are fetched, not
/// shown, so they are kept as written); without, each becomes its alt text,
/// for Markdown drawn where no picture can load.
String shareMarkdown(String markdown, {bool images = false}) {
  final plain = dshUiPlainText(markdown);
  // Pictures are set aside while the text is masked: a long `data:` payload
  // must not be taken for a key.
  final kept = <String>[];
  final guarded = images
      ? plain.replaceAllMapped(_image, (m) {
          kept.add('![](${_imageUrl(m)})');
          return '${kept.length - 1}';
        })
      : plain;
  final masked = redactText(guarded);
  final out = <String>[];
  String? fence;
  for (final line in masked.split('\n')) {
    if (fence != null) {
      if (_closes(line, fence)) fence = null;
      out.add(line);
      continue;
    }
    if (_fence.firstMatch(line) case final open?) {
      fence = open.group(1);
      out.add(line);
      continue;
    }
    out.add(
      images
          ? line
          : line.replaceAllMapped(_image, (m) {
              final alt = (m.group(1) ?? m.group(3) ?? '').trim();
              return alt.isEmpty ? '' : appL10n.viewShareAltMarker(alt);
            }),
    );
  }
  final text = out.join('\n').trim();
  if (!images) return text;
  return text.replaceAllMapped(RegExp('(\\d+)'), (m) => kept[int.parse(m.group(1)!)]);
}

/// A run of a reply: Markdown text, one fenced code block (drawn by the card
/// itself: wrapped, no buttons), or the pictures of one passage.
@immutable
class ShareSegment {
  const ShareSegment.text(this.text) : code = false, language = null, images = const [];
  const ShareSegment.code(this.text, this.language) : images = const [], code = true;
  const ShareSegment.images(this.images) : text = '', code = false, language = null;

  final String text;
  final bool code;

  /// The fence's info string's first word.
  final String? language;

  /// Picture addresses, in order (a gallery).
  final List<String> images;

  bool get isImages => images.isNotEmpty;
}

/// A list marker or blank left behind when a line's pictures are taken out.
final _bareMarker = RegExp(r'^\s*(?:(?:[-*+]|\d+[.)])\s*)?$');

/// [lines] without their pictures, and the pictures' addresses.
(List<String>, List<String>) _splitImages(List<String> lines) {
  final urls = <String>[];
  final text = <String>[];
  for (final line in lines) {
    if (!line.contains('![')) {
      text.add(line);
      continue;
    }
    final rest = line.replaceAllMapped(_image, (m) {
      final url = _imageUrl(m);
      if (url.isNotEmpty) urls.add(url);
      return '';
    });
    if (!_bareMarker.hasMatch(rest)) text.add(rest.trimRight());
  }
  return (text, urls);
}

/// [markdown] cut into text runs, top-level fenced code blocks and galleries:
/// a passage's pictures follow its text, and pictures with no text between
/// them share one gallery.
List<ShareSegment> shareSegments(String markdown) {
  final out = <ShareSegment>[];
  final text = <String>[];
  void flush() {
    final joined = text.join('\n\n').trim();
    if (joined.isNotEmpty) out.add(ShareSegment.text(joined));
    text.clear();
  }

  for (final chunk in _chunks(markdown)) {
    if (!chunk.code) {
      final (lines, urls) = _splitImages(chunk.lines);
      if (lines.isNotEmpty) text.add(lines.join('\n'));
      if (urls.isEmpty) continue;
      flush();
      if (out.lastOrNull case final last? when last.isImages) {
        out[out.length - 1] = ShareSegment.images([...last.images, ...urls]);
      } else {
        out.add(ShareSegment.images(urls));
      }
      continue;
    }
    flush();
    final open = _fence.firstMatch(chunk.lines.first)!;
    final info = open.group(2)!.trim();
    final closed = chunk.lines.length > 1 && _closes(chunk.lines.last, open.group(1)!);
    final body = chunk.lines.sublist(1, closed ? chunk.lines.length - 1 : chunk.lines.length);
    out.add(ShareSegment.code(body.join('\n'), info.isEmpty ? null : info.split(RegExp(r'\s+')).first));
  }
  flush();
  return out;
}

/// One top-level Markdown chunk: a fenced code block or a run of lines
/// between blank lines.
class _Chunk {
  _Chunk(this.lines, {this.code = false});
  final List<String> lines;
  final bool code;
}

List<_Chunk> _chunks(String markdown) {
  final chunks = <_Chunk>[];
  var current = <String>[];
  void flush() {
    if (current.isNotEmpty) chunks.add(_Chunk(current));
    current = <String>[];
  }

  final lines = markdown.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final open = _fence.firstMatch(line);
    if (open != null) {
      flush();
      final marker = open.group(1)!;
      final code = <String>[line];
      i++;
      while (i < lines.length) {
        code.add(lines[i]);
        if (_closes(lines[i], marker)) break;
        i++;
      }
      chunks.add(_Chunk(code, code: true));
      continue;
    }
    if (line.trim().isEmpty) {
      flush();
    } else {
      current.add(line);
    }
  }
  flush();
  return chunks;
}

// ── From the conversation ────────────────────────────────────────────────────

/// `53 秒 · 8 步` for the turn [trace].
String? shareStats(TurnTrace? trace) {
  if (trace == null) return null;
  final parts = [
    if (trace.duration case final d?) formatSpan(d),
    if (trace.steps > 0) appL10n.viewShareSteps(trace.steps),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// The time and steps of several finished turns, added up; null unless every
/// reply has its turn ([traces] holds null for one that has none).
String? shareStatsOf(Iterable<TurnTrace?> traces) {
  final list = traces.toSet().toList();
  if (list.isEmpty || list.contains(null)) return null;
  if (list.length == 1) return shareStats(list.single);
  final turns = list.cast<TurnTrace>();
  var time = Duration.zero;
  var timed = true;
  var steps = 0;
  for (final t in turns) {
    final d = t.duration;
    if (d == null) {
      timed = false;
    } else {
      time += d;
    }
    steps += t.steps;
  }
  final parts = [if (timed) formatSpan(time), if (steps > 0) appL10n.viewShareSteps(steps)];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// The noun for what a tool call did, as the process line counts it; null
/// for bookkeeping (todos, goals, questions) that is not work to show.
String? shareProcessLabel(String tool) => switch (tool) {
  'web_search' => appL10n.viewShareWebSearch,
  'web_fetch' => appL10n.viewShareOpenPage,
  'bash' || 'pwsh' => appL10n.viewShareRunCommand,
  'read' || 'read_image' || 'grep' || 'glob' => appL10n.viewShareReadFile,
  'write' || 'edit' || 'str_replace_editor' => appL10n.viewShareEditFile,
  'subagent' => appL10n.viewShareSubagent,
  'skill' => appL10n.viewShareSkill,
  'present' => appL10n.viewSharePresentFiles,
  'workflow' || 'ralph' => appL10n.viewShareWorkflow,
  _ when tool.startsWith('mcp__') => appL10n.viewSharePlugin,
  _ => null,
};

/// What the agent did in [traces]: tool calls counted by kind, most frequent
/// first (ties in order of first use), at most [limit] kinds.
List<ShareProcessItem> shareProcess(Iterable<TurnTrace?> traces, {int limit = 3}) {
  final counts = <String, int>{};
  final tools = <String, String>{};
  for (final trace in traces.toSet()) {
    if (trace == null) continue;
    for (final span in trace.spans) {
      if (span.kind != TraceKind.tool) continue;
      final tool = span.toolName;
      if (tool == null) continue;
      final label = shareProcessLabel(tool);
      if (label == null) continue;
      counts[label] = (counts[label] ?? 0) + 1;
      tools.putIfAbsent(label, () => tool);
    }
  }
  final order = counts.keys.toList();
  final ranked = [...order]
    ..sort((a, b) {
      final byCount = counts[b]!.compareTo(counts[a]!);
      return byCount != 0 ? byCount : order.indexOf(a).compareTo(order.indexOf(b));
    });
  return [for (final label in ranked.take(limit)) ShareProcessItem(label, counts[label]!, tool: tools[label]!)];
}

/// The finished turn that [seq] belongs to.
TurnTrace? turnOf(List<TurnTrace> turns, int? seq) {
  if (seq == null) return null;
  for (final trace in turns.reversed) {
    if (trace.startSeq <= seq && (trace.endSeq == null || seq <= trace.endSeq!)) return trace;
  }
  return null;
}

/// A prompt worth putting on a card: text or pictures, not the tap that
/// answered a visual reply.
bool _isPrompt(ChatItem item) =>
    item is UserChatItem &&
    (item.text.trim().isNotEmpty || item.images.isNotEmpty) &&
    dshUiReplyChip(item.text) == null;

/// The prompt a reply answers: the nearest person-typed message above it
/// (answers to visual replies are skipped, they are a tap, not a question).
UserChatItem? questionFor(List<ChatItem> items, ChatItem reply) {
  final index = items.indexWhere((i) => i.key == reply.key);
  for (var i = (index < 0 ? items.length : index) - 1; i >= 0; i--) {
    final item = items[i];
    if (_isPrompt(item)) return item as UserChatItem;
  }
  return null;
}

/// A prompt on a card: its text and (with [images]) the pictures attached
/// to it.
ShareQuestion shareQuestionOf(UserChatItem item, {bool images = true}) => ShareQuestion(
  shareQuestionText(withoutAppNotes(item.text)),
  images: [
    if (images)
      for (final image in item.images)
        if (image.attachmentId.isNotEmpty) ShareAttachmentImage(image),
  ],
);

int? _imageTurn(ChatState state, AssistantChatItem reply) {
  final key = reply.rowKey;
  final match = key == null ? null : RegExp(r'^m([0-9]+)[.]').firstMatch(key);
  return match == null ? turnOf(state.turns, reply.seq)?.turn : int.tryParse(match.group(1)!);
}

/// A reply's card: the conversation title, the question above it, the reply
/// and its turn's model, time and work. [sessionId] is where its pictures
/// are fetched from (null: the conversation open in the chat).
///
/// [images] false leaves the pictures out (a prompt's, and a reply's as
/// their alt text); [tools] false leaves out what the agent did.
ShareContent shareContentForReply(
  ChatState state,
  AssistantChatItem message, {
  String? sessionId,
  bool images = true,
  bool tools = true,
}) {
  // The list may hold a newer copy of the same message.
  final reply = state.items.whereType<AssistantChatItem>().where((i) => i.key == message.key).firstOrNull ?? message;
  final question = questionFor(state.items, reply);
  final trace = turnOf(state.turns, reply.seq);
  return ShareContent(
    title: shareTitleText(state.title),
    blocks: [
      if (question != null) shareQuestionOf(question, images: images),
      ShareAnswer(shareMarkdown(reply.text, images: images), turn: _imageTurn(state, reply)),
    ],
    model: reply.model ?? trace?.lastModel.model ?? state.model?.model,
    stats: shareStats(trace),
    process: tools ? shareProcess([trace]) : const [],
    sessionId: sessionId,
  );
}

/// The messages of a conversation a card can show: prompts (text or
/// pictures) and replies with text, in order.
List<ChatItem> shareableItems(List<ChatItem> items) => [
  for (final item in items)
    if (_isPrompt(item))
      item
    else if (item is AssistantChatItem && !item.streaming && item.text.trim().isNotEmpty)
      item,
];

/// A card of several picked messages ([keys] are `ChatItem.key`s). Time and
/// steps are added up over the replies' turns, shown only when every reply
/// has one; the model only when they all used the same. [images] and
/// [tools] as for [shareContentForReply].
ShareContent shareContentForItems(
  ChatState state,
  Set<String> keys, {
  String? sessionId,
  bool images = true,
  bool tools = true,
}) {
  final picked = [
    for (final item in shareableItems(state.items))
      if (keys.contains(item.key)) item,
  ];
  final replies = picked.whereType<AssistantChatItem>().toList();
  final traces = [for (final r in replies) turnOf(state.turns, r.seq)];
  final models = {for (final r in replies) r.model}..remove(null);
  return ShareContent(
    title: shareTitleText(state.title),
    blocks: [
      for (final item in picked)
        switch (item) {
          final UserChatItem prompt => shareQuestionOf(prompt, images: images),
          final AssistantChatItem reply => ShareAnswer(
            shareMarkdown(reply.text, images: images),
            turn: _imageTurn(state, reply),
          ),
          _ => throw StateError('not shareable'),
        },
    ],
    model: models.length == 1 ? models.single : (models.isEmpty ? state.model?.model : null),
    stats: shareStatsOf(traces),
    process: tools ? shareProcess(traces) : const [],
    sessionId: sessionId,
  );
}

/// The reply and the question above it: what a card that starts from one
/// reply shows, and the picks it starts 「选中消息」 with.
Set<String> initialSelection(List<ChatItem> items, AssistantChatItem reply) => {
  ?questionFor(items, reply)?.key,
  reply.key,
};
