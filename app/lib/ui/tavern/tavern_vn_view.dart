// 视觉小说 layout (docs/design/roleplay-ui.md §4): the character's picture on
// the stage, one paragraph at a time in a glass box at the bottom; tap the box
// for the next one, typed out at 酒馆设置's speed (a tap while it types shows
// it whole). 自动 turns the pages on their own; 跳过 goes to the newest. A card
// with expression pictures shows the one each page's words call for.

import 'dart:async';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_components.dart' show tavernComponentTagsOut;
import '../../tavern/tavern_markers.dart';
import '../../tavern/tavern_sprites.dart';
import '../chat/render/markdown_body.dart';
import '../companion/companion_log.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_ink.dart';
import 'tavern_widgets.dart';

/// One page of the story: a paragraph of a message, or part of a long one.
class TavernPage {
  const TavernPage(this.message, this.text, {this.streaming = false, this.marker});
  final TavernMessage message;

  /// What the box shows, expression markers taken out.
  final String text;
  final bool streaming;

  /// The expression marker in force on this page ([表情:x]): the last one
  /// before it in its message, else the message's first.
  final String? marker;
}

/// The path cut into pages, the reply being written included; each message
/// as [shown] gives it (through the display regex), or as written.
List<TavernPage> tavernPages(
  List<TavernMessage> messages, {
  String? streamNode,
  String streamText = '',
  String Function(TavernMessage message)? shown,
}) => [
  for (final m in messages)
    ..._messagePages(
      m,
      m.nodeId == streamNode ? streamText : (shown?.call(m) ?? m.text),
      streaming: m.nodeId == streamNode,
    ),
];

/// [m]'s pages from [text]: each paragraph's, markers taken out, each page
/// carrying the marker in force. Kept with the message: the view is built
/// again with each piece of a reply, and only that one has changed.
List<TavernPage> _messagePages(TavernMessage m, String text, {required bool streaming}) {
  if (streaming) return _paginate(m, text, streaming: true);
  final kept = _pagesOf[m];
  if (kept != null && kept.$1 == text) return kept.$2;
  final pages = _paginate(m, text, streaming: false);
  _pagesOf[m] = (text, pages);
  return pages;
}

final _pagesOf = Expando<(String, List<TavernPage>)>('tavern pages');

List<TavernPage> _paginate(TavernMessage m, String text, {required bool streaming}) {
  final first = tavernMarkerIn(text);
  String? current;
  return [
    for (final paragraph in _paragraphs(text))
      if ((current = tavernMarkerIn(paragraph) ?? current, tavernComponentTagsOut(tavernStripMarkers(paragraph)).trim())
          case (_, final words) when words.isNotEmpty)
        for (final page in tavernParagraphPages(words))
          TavernPage(m, page, streaming: streaming, marker: current ?? first),
  ];
}

Iterable<String> _paragraphs(String text) =>
    text.split(RegExp(r'\n\s*\n')).map((p) => p.trim()).where((p) => p.isNotEmpty);

/// About what the box shows without scrolling on a phone: some six lines at
/// 酒馆设置's middle text size.
const tavernPageChars = 120;

/// What ends a sentence; a run of them ends it once (「……」, 「？！」).
const _sentenceEnds = '。！？!?…';
const _opens = '「『“（(';
const _closes = '」』”）)';

/// [paragraph] as pages of about [tavernPageChars] characters, each ending
/// where a sentence does: never inside a quote, an `*action*`, a tag or code,
/// so each page reads and colours as it would whole. A sentence longer than
/// a page is one page (the box scrolls); tables and code blocks stay whole.
List<String> tavernParagraphPages(String paragraph) {
  if (paragraph.length <= tavernPageChars || paragraph.contains('```') || paragraph.contains('|')) return [paragraph];
  final cuts = <int>[];
  var depth = 0;
  var stars = 0;
  var tag = false;
  var code = false;
  for (var i = 0; i < paragraph.length; i++) {
    final c = paragraph[i];
    if (code) {
      if (c == '`') code = false;
      continue;
    }
    if (tag) {
      if (c == '>') tag = false;
      continue;
    }
    switch (c) {
      case '`':
        code = true;
      case '<':
        tag = true;
      case '*':
        stars++;
      case _ when _opens.contains(c):
        depth++;
      case _ when _closes.contains(c):
        if (depth > 0) depth--;
    }
    if (depth > 0 || stars.isOdd) continue;
    final next = i + 1 < paragraph.length ? paragraph[i + 1] : '';
    if (_sentenceEnds.contains(next) || _closes.contains(next)) continue; // the end goes on
    final ends =
        _sentenceEnds.contains(c) ||
        (c == '.' && (next == ' ' || next == '')) ||
        // A quote that ends a sentence: 「好。」
        (_closes.contains(c) && i > 0 && _sentenceEnds.contains(paragraph[i - 1]));
    if (ends) cuts.add(i + 1);
  }
  final pages = <String>[];
  var start = 0;
  int? best;
  for (final cut in cuts) {
    while (cut - start > tavernPageChars) {
      final end = best ?? cut;
      pages.add(paragraph.substring(start, end).trim());
      start = end;
      best = null;
    }
    if (cut > start) best = cut;
  }
  final rest = paragraph.substring(start).trim();
  if (rest.isEmpty) return pages;
  // A last few words go with the page before, not on a page of their own: at
  // most a quarter page more, or onto a page that scrolls already.
  if (pages.isNotEmpty && rest.length < tavernPageChars ~/ 4) {
    pages.last = '${pages.last}${paragraph.substring(start).trimRight()}';
  } else {
    pages.add(rest);
  }
  return pages.where((p) => p.isNotEmpty).toList();
}

/// One of a group's cast, as the stage shows them: name, picture, sprites.
typedef TavernVnCast = ({String name, String? avatarPath, Map<String, String> sprites});

class TavernVisualNovelView extends StatefulWidget {
  const TavernVisualNovelView({
    super.key,
    required this.pages,
    required this.name,
    required this.avatarPath,
    required this.topInset,
    required this.onMenu,
    required this.footer,
    this.stage,
    this.sprites = const {},
    this.onPage,
    this.onReadingBack,
    this.revealRate,
    this.castFor,
  });

  final List<TavernPage> pages;

  /// A group (engine P2): who a member is, by their card's ID; the stage
  /// shows whoever spoke last, in their own picture and sprites.
  final TavernVnCast? Function(String characterId)? castFor;

  /// The character on stage.
  final String name;
  final String? avatarPath;
  final double topInset;
  final ValueChanged<TavernMessage> onMenu;

  /// Under the box on the last page: the reply's alternatives.
  final Widget? Function(TavernMessage message, bool lastPage) footer;

  /// The character's Live2D stage, in place of the card's picture.
  final Widget? stage;

  /// The card's expression pictures by name ([tavernSprites]): her page shows
  /// the one its words call for, yours keeps her last.
  final Map<String, String> sprites;

  /// A page came up: a new one, or one reached by stepping back and forth.
  final ValueChanged<TavernPage>? onPage;

  /// Paging back to an older page (true), or to the newest again (false).
  final ValueChanged<bool>? onReadingBack;

  /// How fast a page turned to is typed out, in characters a second; null
  /// shows each page whole.
  final double? revealRate;

  @override
  State<TavernVisualNovelView> createState() => _TavernVisualNovelViewState();
}

class _TavernVisualNovelViewState extends State<TavernVisualNovelView> with SingleTickerProviderStateMixin {
  /// A name and the one it replaces, both at the line's start.
  static Widget _startAligned(Widget? current, List<Widget> previous) =>
      Stack(alignment: AlignmentDirectional.centerStart, children: [...previous, ?current]);

  /// The sprite for page [at]: by her words on it, or on her page before
  /// yours; her neutral one before she has said anything.
  String? _spriteAt(int at) {
    final sprites = _castAt(at).sprites;
    if (sprites.isEmpty) return null;
    for (var i = at; i >= 0 && i < widget.pages.length; i--) {
      final page = widget.pages[i];
      if (page.message.role == TavernRole.character) {
        return tavernSpriteFor(sprites, page.text, marker: page.marker);
      }
    }
    return tavernSpriteFor(sprites, '');
  }

  /// Who stands on the stage at page [at]: the speaker of the nearest
  /// character page at or before it, in a group; else the chat's character.
  TavernVnCast _castAt(int at) {
    final own = (name: widget.name, avatarPath: widget.avatarPath, sprites: widget.sprites);
    final castFor = widget.castFor;
    if (castFor == null) return own;
    for (var i = at; i >= 0 && i < widget.pages.length; i--) {
      final message = widget.pages[i].message;
      if (message.role != TavernRole.character) continue;
      final id = message.speakerCharacterId;
      return (id == null ? null : castFor(id)) ?? own;
    }
    return own;
  }

  /// [cast]'s picture; keyed by who it is, so a new speaker cross-fades in.
  Widget _face(TavernVnCast cast) => KeyedSubtree(
    key: ValueKey(('tavern-vn-cast', cast.name)),
    child: AspectRatio(
      key: const ValueKey('tavern-vn-face'),
      aspectRatio: 2 / 3,
      child: TavernPortrait(name: cast.name, path: cast.avatarPath, radius: AppShape.xl, initialSize: 96),
    ),
  );

  /// The page shown; null follows the newest.
  int? _page;

  /// The backlog is open over the stage.
  bool _log = false;

  /// 自动: each page, once whole, waits as long as it takes to read and turns.
  bool _auto = false;
  Timer? _autoTimer;

  /// The page being typed out; null when the page shows whole.
  _Typing? _typing;
  late final Ticker _ticker = createTicker(_tick);

  final _scroll = ScrollController();

  /// The typed part of the page, to keep its newest line in sight.
  final _typedKey = GlobalKey();

  int get _last => widget.pages.length - 1;

  @override
  void didUpdateWidget(TavernVisualNovelView old) {
    super.didUpdateWidget(old);
    // Reading the newest page when more arrive: keep up with them.
    if (_page != null && _page! >= old.pages.length - 1) _page = null;
    if (_page != null && _page! > _last) _page = null;
    // The page being typed out moved off screen or changed: no more typing.
    if (_typing case final typing?) {
      final at = _page ?? _last;
      if (widget.revealRate == null ||
          typing.at != at ||
          at > _last ||
          widget.pages[at].message.nodeId != typing.node ||
          widget.pages[at].text != typing.text) {
        _stopTyping();
      }
    }
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _ticker.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// To page [page] (null: the newest), typed out when [type].
  void _go(int? page, {bool type = false}) {
    _cancelAuto();
    setState(() {
      _page = page;
      _stopTyping();
      if (type) _type(page ?? _last);
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _next() {
    final at = _page ?? _last;
    if (at < _last) _go(at + 1 == _last ? null : at + 1, type: true);
  }

  void _previous() {
    final at = _page ?? _last;
    if (at > 0) _go(at - 1);
  }

  /// 跳过: to the newest page, whole.
  void _skip() => _go(null);

  /// A tap on the box: the page whole while it types, else the next one.
  void _tap() {
    if (_typing == null) return _next();
    _cancelAuto();
    setState(_stopTyping);
  }

  void _openLog() {
    _cancelAuto();
    setState(() => _log = true);
  }

  /// Starts typing out page [at], unless pages show whole: at 立即, with
  /// motion reduced, for a reply still being written (it types itself) and
  /// for your own lines.
  void _type(int at) {
    final rate = widget.revealRate;
    if (rate == null || at < 0 || at > _last || AppMotion.reduced(context)) return;
    final page = widget.pages[at];
    if (page.streaming || page.message.role == TavernRole.user) return;
    final typing = _Typing(page.message.nodeId, at, page.text);
    if (typing.cuts.length < 2) return;
    _typing = typing;
    _ticker.start();
  }

  void _stopTyping() {
    _ticker.stop();
    _typing = null;
  }

  void _tick(Duration elapsed) {
    final typing = _typing;
    final rate = widget.revealRate;
    if (typing == null || rate == null) return _ticker.stop();
    final shown = (elapsed.inMicroseconds * rate / Duration.microsecondsPerSecond).floor() + 1;
    if (shown >= typing.cuts.length) return setState(_stopTyping);
    if (shown == typing.shown.value) return;
    // Only the typed text builds again, not the stage around it.
    typing.shown.value = shown;
    // A page taller than the box: keep the newest typed line in sight.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final typed = _typedKey.currentContext?.findRenderObject();
      if (!mounted || typed is! RenderBox || !_scroll.hasClients) return;
      final position = _scroll.position;
      final bottom = (typed.size.height - position.viewportDimension).clamp(0.0, position.maxScrollExtent);
      if (bottom > position.pixels) _scroll.jumpTo(bottom);
    });
  }

  void _cancelAuto() {
    _autoTimer?.cancel();
    _autoTimer = null;
  }

  void _setAuto(bool on) {
    _cancelAuto();
    setState(() => _auto = on);
  }

  /// With 自动 on, page [at], whole and not the last, waits as long as it
  /// takes to read, then turns.
  void _schedule(TavernPage? page, int at) {
    if (!_auto || _autoTimer != null || _typing != null || _log) return;
    if (page == null || page.streaming || at >= _last) return;
    final wait = 1200 + 50 * page.text.characters.length;
    _autoTimer = Timer(Duration(milliseconds: wait.clamp(1200, 8000)), () {
      _autoTimer = null;
      if (mounted) _next();
    });
  }

  /// The page last told to [TavernVisualNovelView.onPage]: its message, where
  /// it is, and whether it was still being written.
  (String, int, bool)? _told;

  /// What [TavernVisualNovelView.onReadingBack] was last told.
  bool? _toldBack;

  void _tellBack(bool back) {
    final onBack = widget.onReadingBack;
    if (onBack == null || back == _toldBack) return;
    _toldBack = back;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) onBack(back);
    });
  }

  void _tell(TavernPage? page, int at) {
    final onPage = widget.onPage;
    if (page == null || onPage == null) return;
    final key = (page.message.nodeId, at, page.streaming);
    if (key == _told) return;
    _told = key;
    // After this frame: the page is on screen before the stage reacts to it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) onPage(page);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dsh = DshColors.of(context);
    final pages = widget.pages;
    final at = (_page ?? _last).clamp(0, pages.isEmpty ? 0 : _last);
    final page = pages.isEmpty ? null : pages[at];
    final user = page?.message.role == TavernRole.user;
    final speaker = page == null ? widget.name : (user ? context.l10n.tavernYou : tavernSpeaker(context, page.message));
    final typing = _typing?.at == at ? _typing : null;
    _tell(page, at);
    _tellBack(pages.isNotEmpty && at < _last);
    _schedule(page, at);
    final stage = widget.stage;
    final sprite = stage == null ? _spriteAt(at) : null;
    final cast = _castAt(at);
    final footer = page == null ? null : widget.footer(page.message, at == _last);
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [scheme.primaryContainer.withValues(alpha: 0.35), Colors.transparent],
              ),
            ),
          ),
        ),
        // Her Live2D model, across the stage: she listens while you speak.
        if (stage != null)
          Positioned(
            key: const ValueKey('tavern-vn-stage'),
            left: 0,
            right: 0,
            top: widget.topInset,
            bottom: 170,
            child: stage,
          )
        // Else her expression picture, standing on the box, or the card's
        // picture; dimmed a little while you speak.
        else
          Positioned(
            left: sprite != null ? 16 : 40,
            right: sprite != null ? 16 : 40,
            top: widget.topInset + 8,
            bottom: sprite != null ? 170 : 190,
            child: Center(
              child: AnimatedOpacity(
                opacity: user ? 0.55 : 1,
                duration: AppMotion.of(context, AppMotion.standard),
                child: AnimatedSwitcher(
                  duration: AppMotion.of(context, AppMotion.standard),
                  child: sprite != null
                      // Sprites are cut out: as large as the stage allows, whole, no frame.
                      ? SizedBox.expand(
                          key: ValueKey(sprite),
                          child: Image.file(
                            File(sprite),
                            fit: BoxFit.contain,
                            alignment: Alignment.bottomCenter,
                            errorBuilder: (_, _, _) => Center(child: _face(cast)),
                          ),
                        )
                      : _face(cast),
                ),
              ),
            ),
          ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 8,
          child: GestureDetector(
            key: const ValueKey('tavern-vn-box'),
            behavior: HitTestBehavior.opaque,
            onTap: _tap,
            onLongPress: page == null ? null : () => widget.onMenu(page.message),
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v > 200) _previous();
              if (v < -200) _next();
            },
            // Up over the box: the backlog, as in a visual novel.
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) < -300) _openLog();
            },
            child: GlassSurface(
              tier: GlassTier.sheet,
              borderRadius: AppShape.radiusXl,
              // The keys' rows (the name's, the alternatives') bring their own
              // air: the box's own is even all round.
              padding: EdgeInsets.fromLTRB(16, 8, 16, footer == null ? 16 : 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // Who speaks changes with the page, in the same cross-fade.
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: AppMotion.of(context, AppMotion.quick),
                          layoutBuilder: _startAligned,
                          child: Text(
                            speaker,
                            key: ValueKey(speaker),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: user ? dsh.textTertiary : tavernNameColor(context, speaker, lead: widget.name),
                              fontWeight: FontWeight.w600,
                              fontFamily: user ? null : tavernNameFont(context),
                            ),
                          ),
                        ),
                      ),
                      // The last key's glyph on the box's edge, as the name is on the other.
                      Transform.translate(
                        offset: const Offset((_BoxKey.height - _BoxKey.glyph) / 2, 0),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (pages.length > 1) ...[
                              Text(
                                '${at + 1}/${pages.length}',
                                style: AppType.tabular(theme.textTheme.labelSmall!.copyWith(color: dsh.textTertiary)),
                              ),
                              const SizedBox(width: 8),
                            ],
                            _BoxKey(
                              key: const ValueKey('tavern-vn-auto'),
                              label: context.l10n.tavernVnAuto,
                              on: _auto,
                              onTap: () => _setAuto(!_auto),
                            ),
                            if (at < _last)
                              _BoxKey(
                                key: const ValueKey('tavern-vn-skip'),
                                label: context.l10n.tavernVnSkip,
                                onTap: _skip,
                              ),
                            SizedBox.square(
                              dimension: _BoxKey.height,
                              child: IconButton(
                                key: const ValueKey('tavern-vn-log'),
                                tooltip: context.l10n.tavernLog,
                                padding: EdgeInsets.zero,
                                iconSize: _BoxKey.glyph,
                                color: dsh.textTertiary,
                                onPressed: _openLog,
                                icon: Icon(AppIcons.history),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 72, maxHeight: 220),
                    child: SingleChildScrollView(
                      controller: _scroll,
                      reverse: page?.streaming ?? false,
                      child: AnimatedSwitcher(
                        duration: AppMotion.of(context, AppMotion.quick),
                        child: SizedBox(
                          key: ValueKey(at),
                          width: double.infinity,
                          child: switch ((page, typing)) {
                            (null, _) => const SizedBox.shrink(),
                            (final page?, null) => MarkdownBody(
                              text: page.text,
                              streaming: page.streaming,
                              selectable: false,
                            ),
                            // Typing: the page whole but unseen under it, so the
                            // box takes its size at once and no line moves.
                            (final page?, final typing?) => Stack(
                              children: [
                                Visibility.maintain(
                                  visible: false,
                                  child: MarkdownBody(text: page.text, selectable: false),
                                ),
                                Positioned(
                                  top: 0,
                                  left: 0,
                                  right: 0,
                                  child: ValueListenableBuilder(
                                    valueListenable: typing.shown,
                                    builder: (context, _, _) => MarkdownBody(
                                      key: _typedKey,
                                      text: typing.typed,
                                      streaming: true,
                                      selectable: false,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          },
                        ),
                      ),
                    ),
                  ),
                  ?footer,
                ],
              ),
            ),
          ),
        ),
        // The backlog in the story's own look: the app's light or dark, the
        // card's accent on her name (TavernReading above sets it); it starts
        // under the floating header.
        Positioned.fill(
          top: widget.topInset,
          child: CompanionLogTransition(
            child: _log
                ? KeyedSubtree(
                    key: const ValueKey('tavern-vn-backlog'),
                    child: CompanionLog(
                      scrim: [
                        theme.colorScheme.surface.withValues(alpha: DshSurfaces.of(context).blurEnabled ? 0.86 : 0.96),
                        theme.colorScheme.surfaceContainer.withValues(
                          alpha: DshSurfaces.of(context).blurEnabled ? 0.92 : 0.98,
                        ),
                      ],
                      herTone: theme.colorScheme.primary,
                      youTone: dsh.textTertiary,
                      entries: [
                        for (final page in pages)
                          if (page.message.role == TavernRole.user)
                            CompanionLogEntry.you(_plain(page.text))
                          else
                            _logLine(context, page.message, _plain(page.text), lead: widget.name),
                      ],
                      name: widget.name,
                      onClose: () => setState(() => _log = false),
                    ),
                  )
                : null,
          ),
        ),
      ],
    );
  }
}

/// A page being typed out.
class _Typing {
  _Typing(this.node, this.at, this.text) : cuts = _cuts(text);

  final String node;
  final int at;
  final String text;

  /// Where [text] is cut as it is typed: see [_cuts].
  final List<int> cuts;

  /// How many of [cuts] show.
  final shown = ValueNotifier(1);

  String get typed => text.substring(0, cuts[shown.value - 1]);
}

/// What comes at once, whole: an HTML tag, an image, a link.
final _whole = RegExp(r'</?[A-Za-z][^<>]*>|!?\[[^\]\n]*\]\([^)\n]*\)');

@visibleForTesting
List<int> tavernTypingCuts(String text) => _cuts(text);

/// Where [text] can be cut as it is typed out: after each character, never
/// inside a tag, an image or a link.
List<int> _cuts(String text) {
  final whole = [for (final m in _whole.allMatches(text)) (m.start, m.end)];
  final cuts = <int>[];
  var offset = 0;
  var w = 0;
  for (final c in text.characters) {
    offset += c.length;
    while (w < whole.length && whole[w].$2 < offset) {
      w++;
    }
    if (w < whole.length && whole[w].$1 < offset && offset < whole[w].$2) continue;
    cuts.add(offset);
  }
  return cuts;
}

/// One of the box's keys (自动, 跳过), as a visual novel labels them: a word,
/// in the accent while it is on.
class _BoxKey extends StatelessWidget {
  const _BoxKey({super.key, required this.label, required this.onTap, this.on = false});

  /// The row's keys: this tall, the log's glyph this size in a square of it.
  static const height = 32.0;
  static const glyph = 18.0;

  final String label;
  final VoidCallback onTap;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      toggled: on,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // The same air each side as the log key's glyph has in its square.
        child: Container(
          constraints: const BoxConstraints(minHeight: height),
          padding: const EdgeInsets.symmetric(horizontal: (height - glyph) / 2),
          child: Center(
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: on ? theme.colorScheme.primary : DshColors.of(context).textTertiary,
                fontWeight: on ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A page as the backlog shows it: plain text, Markdown emphasis dropped.
String _plain(String text) => text.replaceAll(RegExp(r'(\*\*|\*|__)'), '');

/// A line not yours in the backlog, under whoever says it: in a group each
/// member (the name over the story is the group's), the narrator as 旁白;
/// named and coloured as in the chat.
CompanionLogEntry _logLine(BuildContext context, TavernMessage message, String text, {required String lead}) {
  final who = tavernSpeaker(context, message);
  if (who.isEmpty || who == lead) return CompanionLogEntry.her(text);
  return CompanionLogEntry.her(
    text,
    who: who,
    tone: tavernNameColor(context, who, lead: lead),
  );
}
