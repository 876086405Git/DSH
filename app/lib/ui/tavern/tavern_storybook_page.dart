// 故事书: hand the story on. The whole of it as a book (EPUB for reading
// apps, or plain text), or its latest lines as one long image to save or
// share. The image is drawn here, the books in lib/tavern/tavern_storybook.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_storybook.dart';
import '../chat/render/markdown_body.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../settings/settings_widgets.dart';
import '../share/share_export.dart' show shareExporterProvider;
import '../share/share_gallery.dart' show shareImagesSettled;
import '../shell/page_frame.dart';
import '../theme/theme.dart';
import 'tavern_chat_files.dart' show tavernChatSinkProvider, tavernChatFileName;
import 'tavern_ink.dart';
import 'tavern_widgets.dart' show TavernPortrait;

/// The latest lines a long image can hold: more makes a picture no phone
/// draws in one piece.
const tavernStoryImageChoices = [10, 20, 30];

class TavernStorybookPage extends ConsumerStatefulWidget {
  const TavernStorybookPage({super.key, required this.chatId, required this.character, this.avatarPath});

  final String chatId;

  /// The character's name and picture.
  final String character;
  final String? avatarPath;

  static Route<void> route({required String chatId, required String character, String? avatarPath}) =>
      MaterialPageRoute<void>(
        builder: (_) => TavernStorybookPage(chatId: chatId, character: character, avatarPath: avatarPath),
      );

  @override
  ConsumerState<TavernStorybookPage> createState() => _TavernStorybookPageState();
}

class _TavernStorybookPageState extends ConsumerState<TavernStorybookPage> {
  late final _title = TextEditingController();
  final _card = GlobalKey();
  List<TavernMessage>? _messages;
  Uint8List? _cover;
  int _excerpt = tavernStoryImageChoices[1];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final tavern = ref.read(tavernProvider);
    // The whole path, however long.
    final messages = await tavern.path(widget.chatId, limit: 1 << 30);
    Uint8List? cover;
    try {
      if (widget.avatarPath case final path?) cover = await File(path).readAsBytes();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _messages = messages;
      _cover = cover;
    });
  }

  String get _you =>
      ref.read(tavernPersonaSelectionProvider(widget.chatId)).value?.persona?.name ?? context.l10n.tavernYou;

  String get _bookTitle {
    final typed = _title.text.trim();
    return typed.isEmpty ? context.l10n.tavernStorybookDefaultTitle(widget.character) : typed;
  }

  TavernStory _story() => TavernStory.of(
    _messages ?? const [],
    title: _bookTitle,
    byline: context.l10n.tavernStorybookByline(widget.character, _you),
    you: _you,
    cover: _cover,
  );

  /// Runs one export; says when it didn't work.
  Future<void> _run(Future<void> Function() job, {String? done}) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    final failed = context.l10n.tavernStorybookFailed;
    setState(() => _busy = true);
    try {
      await job();
      if (done != null) messenger.showSnackBar(SnackBar(content: Text(done)));
    } on Object {
      messenger.showSnackBar(SnackBar(content: Text(failed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _epub() {
    final l10n = context.l10n;
    final story = _story();
    final words = TavernBookWords(
      language: Localizations.localeOf(context).languageCode == 'zh' ? 'zh-CN' : 'en',
      contents: l10n.tavernStorybookContents,
      chapter: l10n.tavernStorybookChapter,
      madeWith: l10n.tavernStorybookMadeWith,
    );
    unawaited(
      _run(() async {
        final bytes = buildTavernEpub(story, words, id: tavernBookId(), modified: DateTime.now());
        await ref.read(tavernChatSinkProvider)([
          TavernChatFile(fileName: _fileName(story.title, 'epub'), bytes: bytes),
        ]);
      }),
    );
  }

  void _text() {
    final story = _story();
    final text = buildTavernStoryText(story, madeWith: context.l10n.tavernStorybookMadeWith);
    unawaited(
      _run(
        () => ref.read(tavernChatSinkProvider)([
          TavernChatFile(fileName: _fileName(story.title, 'txt'), bytes: utf8.encode(text)),
        ]),
      ),
    );
  }

  void _image({required bool save}) {
    final saved = context.l10n.tavernStorybookSaved;
    unawaited(
      _run(() async {
        final png = await _capture();
        final exporter = ref.read(shareExporterProvider);
        final file = await exporter.write(png);
        if (save) {
          await exporter.save(file);
        } else {
          await exporter.share(file);
        }
      }, done: save ? saved : null),
    );
  }

  /// The card as PNG, as sharp as a picture this tall can be.
  Future<Uint8List> _capture() async {
    final card = _card.currentContext;
    if (card == null) throw StateError('the card is not built');
    // Scrolled into view first: a card wholly out of view is never painted.
    await Scrollable.ensureVisible(card);
    if (!card.mounted) throw StateError('the page is gone');
    await shareImagesSettled(card);
    final boundary = _card.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) throw StateError('the card is not on screen');
    if (SchedulerBinding.instance.hasScheduledFrame) await SchedulerBinding.instance.endOfFrame;
    final image = await boundary.toImage(pixelRatio: tavernStoryPixelRatio(boundary.size.height));
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('PNG encoding failed');
      return data.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final messages = _messages;
    if (messages == null) {
      return AppPage.list(
        title: l10n.tavernStorybook,
        children: const [
          Padding(
            padding: EdgeInsets.all(48),
            child: Center(child: QuietSpinner()),
          ),
        ],
      );
    }
    // Rebuilt as the title is typed, so the card's heading follows it.
    return ListenableBuilder(
      listenable: _title,
      builder: (context, _) {
        final story = _story();
        final empty = story.lines.isEmpty;
        final shown = story.lines.length <= _excerpt ? story.lines : story.lines.sublist(story.lines.length - _excerpt);
        // One column, built whole: the card must exist (to be captured) however
        // far down it is.
        return AppPage(
          title: l10n.tavernStorybook,
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsSection(
                    title: l10n.tavernStorybookTitle,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        child: TextField(
                          key: const ValueKey('tavern-book-title'),
                          controller: _title,
                          textInputAction: TextInputAction.done,
                          decoration: InputDecoration(
                            hintText: l10n.tavernStorybookDefaultTitle(widget.character),
                            // The text starts where the rows' titles below do.
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(vertical: 14),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SettingsSection(
                    title: l10n.tavernStorybookWhole,
                    footer: Text(l10n.tavernStorybookWholeNote(story.lines.length)),
                    children: [
                      SettingsTile(
                        key: const ValueKey('tavern-book-epub'),
                        title: l10n.tavernStorybookEpub,
                        onTap: empty || _busy ? null : _epub,
                      ),
                      SettingsTile(
                        key: const ValueKey('tavern-book-text'),
                        title: l10n.tavernStorybookText,
                        onTap: empty || _busy ? null : _text,
                      ),
                    ],
                  ),
                  SettingsSection(
                    title: l10n.tavernStorybookImage,
                    footer: story.lines.length > _excerpt
                        ? Text(l10n.tavernStorybookEarlier(story.lines.length - _excerpt))
                        : null,
                    children: [
                      SettingsSegmentTile<int>(
                        key: const ValueKey('tavern-book-excerpt'),
                        title: l10n.tavernStorybookLatest,
                        tinted: false,
                        segments: [
                          for (final n in tavernStoryImageChoices) PillSegment(n, l10n.tavernStorybookLines(n)),
                        ],
                        selected: _excerpt,
                        onChanged: (n) => setState(() => _excerpt = n),
                      ),
                      SettingsTile(
                        key: const ValueKey('tavern-book-save'),
                        title: l10n.tavernStorybookSave,
                        chevron: false,
                        onTap: empty || _busy ? null : () => _image(save: true),
                      ),
                      SettingsTile(
                        key: const ValueKey('tavern-book-share'),
                        title: l10n.tavernStorybookShare,
                        chevron: false,
                        onTap: empty || _busy ? null : () => _image(save: false),
                      ),
                    ],
                  ),
                  // What the image will be, as it will be.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppShape.lg),
                      child: FittedBox(
                        fit: BoxFit.fitWidth,
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: TavernStoryCard.width,
                          child: RepaintBoundary(
                            key: _card,
                            child: TavernStoryCard(
                              story: story,
                              lines: shown,
                              earlier: story.lines.length - shown.length,
                              avatarPath: widget.avatarPath,
                              character: widget.character,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

String _fileName(String title, String ext) => tavernChatFileName(title, extension: ext);

/// The long image: the cover's heading, the lines, and where it was written.
class TavernStoryCard extends StatelessWidget {
  const TavernStoryCard({
    super.key,
    required this.story,
    required this.lines,
    required this.earlier,
    required this.character,
    this.avatarPath,
  });

  /// Drawn this wide, whatever the screen.
  static const width = 360.0;

  final TavernStory story;
  final List<TavernStoryLine> lines;

  /// Lines before these, left out.
  final int earlier;
  final String character;
  final String? avatarPath;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dsh = DshColors.of(context);
    final surfaces = DshSurfaces.of(context);
    return DecoratedBox(
      // Opaque: a saved picture has no page behind it.
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [surfaces.backdropTop, surfaces.backdropBottom],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                SizedBox.square(
                  dimension: 48,
                  child: ClipOval(
                    child: TavernPortrait(name: character, path: avatarPath, radius: 0, initialSize: 18),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        story.title,
                        key: const ValueKey('tavern-book-card-title'),
                        style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [story.byline, ?story.dates].join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.6)),
            const SizedBox(height: 18),
            if (earlier > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  l10n.tavernStorybookEarlierShort(earlier),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                ),
              ),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      line.speaker,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: line.you ? dsh.textTertiary : tavernNameColor(context, line.speaker, lead: character),
                      ),
                    ),
                    const SizedBox(height: 4),
                    MarkdownBody(text: tavernStoryParagraphs(line.text).join('\n\n'), selectable: false),
                  ],
                ),
              ),
            Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text(
              l10n.tavernStorybookMadeWith,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(color: dsh.textTertiary, letterSpacing: 0.4),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pixels per point for a card [height] points tall: up to 3×, less for a long
/// one so the picture stays within what a phone draws in one piece (12,000 px).
double tavernStoryPixelRatio(double height) => math.min(3, math.max(1, 12000 / height));
