// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show DshRemoteException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/l10n.dart';
import '../../../links/page_links.dart' show openReplyPageLink;
import '../../../state/artifacts.dart';
import '../../../state/table_tint_state.dart';
import '../../../state/workspace_state.dart';
import '../../common/edge_fade.dart';
import '../../common/streaming_cursor.dart';
import '../../theme/app_icons.dart';
import '../../plugins/native/native_taps.dart' show openConfirmedLink;
import '../../theme/theme.dart';
import '../artifact_preview.dart';
import '../dsh_ui/dsh_ui.dart';
import 'code_block.dart';
import 'markdown_blocks.dart';
import 'markdown_image.dart';
import 'markdown_math.dart';
import 'markdown_split.dart';
import 'math_syntax.dart';
import 'stream_repair.dart';
import 'table_syntax.dart';

/// 流式光标的占位符(私用区码位)。拼在正文末尾,由 [InlinePattern] 换成
/// 光标 —— 这样光标跟着最后一段文字走,而不是孤零零掉到正文下面。
const _cursorSentinel = '\uE000';

/// 收进 `<details>` 之外,模型常写的 HTML 都按 gpt_markdown 的默认表
/// 渲染(`<br>` 换行、`<sub>` / `<sup>`、`<kbd>`、`<u>`、`<mark>`…),
/// 不认识的标签原样显示;`<details>` 换成可折叠的一块。
final Map<String, HtmlTag?> _htmlTags = {
  'details': const HtmlTag.block(MarkdownDisclosure.build),
  'summary': const HtmlTag.block(),
};

/// The HTML gpt_markdown parses with [_htmlTags]: where its blocks end.
final _markdownHtml = GptMarkdownConfig(htmlTags: _htmlTags).markdownHtml;

/// Inline patterns a part of the app lays over every [MarkdownBody] below it
/// (the tavern colours its story's dialogue). Keep [patterns] one list per
/// look: its identity is part of the parse cache's key.
class MarkdownPatterns extends InheritedWidget {
  const MarkdownPatterns({super.key, required this.patterns, required super.child});

  final List<InlinePattern> patterns;

  static List<InlinePattern>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MarkdownPatterns>()?.patterns;

  @override
  bool updateShouldNotify(MarkdownPatterns old) => !identical(old.patterns, patterns);
}

/// 助手正文的 Markdown 渲染。
///
/// - 正文样式与用户气泡同源([AppType.chatBody]),流式与完成态不跳字号;
/// - 围栏代码交给 [CodeBlock](Mist 高亮 + 复制);
/// - 行内代码是画在文字下面的小井(gpt_markdown 1.4 的 chip),可换行、可选中;
/// - 公式:`$…$` / `\(…\)` 行内、`$$…$$` / `\[…\]` 成块([MarkdownMath]),
///   价格(`$5 和 $10`)不当公式([normalizeMath]);
/// - 图片:工作区文件、网页、`data:` 都能显示([MarkdownImage]);
/// - [streaming] 时修补正在生成的末尾([repairStreamingMarkdown]),并在
///   最后一段末尾放呼吸光标。
class MarkdownBody extends StatefulWidget {
  const MarkdownBody({
    super.key,
    required this.text,
    this.streaming = false,
    this.reveal = false,
    this.selectable = true,
    this.secondary = false,
    this.repairBareViews = false,
  });

  final String text;
  final bool streaming;

  /// The fluid tier's streamed reply: gpt_markdown paces the text itself, fades in
  /// the newest words, and only rebuilds the part that can still change, so an update
  /// costs the same however long the reply is. No cursor and no tail repair: it holds
  /// back half-written markup on its own. Keep it on after [streaming] ends, for the
  /// life of this body: the tree stays and nothing moves when the reply finishes.
  final bool reveal;
  final bool selectable;

  /// 次级排版(思考过程):小一号、次级文字色,标题也不抢眼。
  final bool secondary;

  /// 助手回复:模型把 `dsh-ui` 的 JSON 裸着写进正文时,也当成视图画
  /// (见 [fenceBareDshUiViews])。别的 Markdown(文档、说明页)不开。
  final bool repairBareViews;

  /// 表格单列最宽多少;更长的单元格在列内换行,而不是把整表拉得很长。
  static const _maxColumnWidth = 260.0;

  /// A reply this long, or one that streams, is drawn in blocks of about this
  /// many characters, one GptMarkdown each behind its own repaint boundary
  /// ([MarkdownBlockSplit]): new text re-renders and repaints only the last
  /// block, however long the reply. A shorter static text is one GptMarkdown.
  @visibleForTesting
  static int blockLength = 2000;

  static final _themes = <String, Expando<GptMarkdownThemeData>>{};
  static final _secondaryThemes = <String, Expando<GptMarkdownThemeData>>{};

  /// 每个 ThemeData 只建一次(工厂内部会构造整套 ThemeData,不便宜)。
  ///
  /// 缓存按语言 + 表格底色的组合分开:同一页里"跟随主题"和"无底色"是两份
  /// 主题,换设置后不必把旧的丢掉再重建。
  static GptMarkdownThemeData _themeFor(ThemeData theme, bool secondary, L10n l10n, TableTint tint) {
    final cache = (secondary ? _secondaryThemes : _themes).putIfAbsent(
      '${l10n.localeName}|${tint.name}',
      () => Expando<GptMarkdownThemeData>('markdownTheme'),
    );
    return cache[theme] ??= _buildTheme(theme, l10n, secondary: secondary, tint: tint);
  }

  static GptMarkdownThemeData _buildTheme(
    ThemeData theme,
    L10n l10n, {
    bool secondary = false,
    TableTint tint = TableTint.follow,
  }) {
    final colors = theme.colorScheme;
    final dsh = theme.extension<DshColors>()!;
    // 表格底色三档只在两个填充上不同;隔行比表头再淡一档,能看出条带又不
    // 抢文字。
    final tableFills = tableTintFills(
      tint,
      headerColor: dsh.codeWellHeader,
      stripeColor: colors.onSurface.withValues(alpha: theme.brightness == Brightness.dark ? 0.06 : 0.05),
    );
    final shrink = secondary ? 0.9 : 1.0;
    TextStyle heading(double size, {double height = 1.45}) => TextStyle(
      fontSize: size * shrink,
      fontWeight: FontWeight.w600,
      height: height,
      color: secondary ? colors.onSurfaceVariant : colors.onSurface,
      leadingDistribution: TextLeadingDistribution.even,
    );
    return GptMarkdownThemeData(
      brightness: theme.brightness,
      h1: heading(20, height: 1.4),
      h2: heading(18, height: 1.4),
      h3: heading(16.5),
      h4: heading(16),
      h5: heading(15),
      h6: heading(15),
      hrLineThickness: 0.5,
      hrLineColor: colors.outlineVariant,
      hrLinePadding: const EdgeInsets.symmetric(vertical: 12),
      linkColor: colors.primary,
      linkHoverColor: colors.primary,
      autoAddDividerLineAfterH1: false,
      inlineCode: InlineCodeStyle(
        fontFamily: AppType.monoFamily,
        fontFamilyFallback: AppType.monoFallback,
        fontSizeFactor: 0.875,
        color: dsh.codeWellFg,
        backgroundColor: dsh.codeWellBg,
        borderColor: dsh.codeWellBorder,
        borderWidth: 0.5,
        borderRadius: const Radius.circular(AppShape.xs),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      ),
      styleSheet: GptMarkdownStyleSheet(
        blockQuote: BlockQuoteStyle(
          barWidth: 3,
          barColor: colors.outlineVariant,
          barRadius: const Radius.circular(2),
          textStyle: TextStyle(color: colors.onSurfaceVariant),
        ),
        list: ListStyle(
          bulletColor: colors.onSurfaceVariant,
          bulletSize: 5,
          markerTextStyle: TextStyle(color: colors.onSurfaceVariant),
        ),
        // GitHub 提示块:状态色的浅底 + 左侧色条,标题用中文。
        alert: AlertStyle(
          borderRadius: const Radius.circular(AppShape.sm),
          padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 14, 10),
          // 和段落同一个块间距,不再额外加外边距。
          margin: EdgeInsets.zero,
          titleStyle: const TextStyle(fontWeight: FontWeight.w600),
          titleGap: 4,
          note: AlertStyle(title: l10n.chatAlertNote, color: dsh.info, icon: AppIcons.info),
          tip: AlertStyle(title: l10n.chatAlertTip, color: dsh.success, icon: AppIcons.tip),
          important: AlertStyle(title: l10n.chatAlertImportant, color: dsh.ansi[5], icon: AppIcons.important),
          warning: AlertStyle(title: l10n.chatAlertWarning, color: dsh.warning, icon: AppIcons.warning),
          caution: AlertStyle(title: l10n.chatAlertCaution, color: dsh.danger, icon: AppIcons.caution),
        ),
        // `<mark>`:荧光笔一样的暖黄底。
        highlight: HighlightStyle(backgroundColor: dsh.warningContainer, color: dsh.onWarningContainer),
        link: LinkStyle(
          color: colors.primary,
          hoverColor: colors.primary,
          decoration: TextDecoration.underline,
          decorationThickness: 0.6,
        ),
        hr: HrStyle(thickness: 0.5, color: colors.outlineVariant),
        // 表格:细线网格、方角、表头加粗;列宽随内容,但单列
        // 不超过 [_maxColumnWidth](长文字在列内换行),整表放不下时横向滚动。
        // 方角:表头与隔行的底色是矩形填充,没有跟着圆角裁剪(gpt_markdown
        // 1.4.0),圆角会让四角露出方形色块;上游修好后可换回 AppShape.md。
        table: TableStyle(
          // 比代码井的描边重一点:深色下行线也要看得见。
          borderColor: colors.onSurface.withValues(alpha: theme.brightness == Brightness.dark ? 0.18 : 0.14),
          borderWidth: 0.5,
          borderRadius: Radius.zero,
          // 三档底色的差别只在这两个填充(设置 → 界面 → 表格底色)。
          headerBackground: tableFills.header,
          rowStripeColor: tableFills.stripe,
          cellPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          columnWidth: const MinColumnWidth(IntrinsicColumnWidth(), FixedColumnWidth(_maxColumnWidth)),
          overflow: TableOverflow.scroll,
        ),
      ),
    );
  }

  static final _cursorPattern = InlinePattern(
    pattern: RegExp(_cursorSentinel),
    builder: (context, match, style) => _cursorSpan(style),
  );

  static InlineSpan _cursorSpan(TextStyle style) {
    final fontSize = style.fontSize ?? 16;
    final lineHeight = fontSize * (style.height ?? 1.6);
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.only(left: 2),
        // 光标自己一层:呼吸动画只重绘这 2.5px,不重绘整段正文。
        child: RepaintBoundary(child: StreamingCursor(height: lineHeight * 0.66)),
      ),
    );
  }

  static final _streamingPatterns = [_cursorPattern];

  /// The cursor with a [MarkdownPatterns] list, one list per list.
  static final _streamingWith = Expando<List<InlinePattern>>('streamingWith');

  // Builders stay static. gpt_markdown 1.4.0's config.isSame ignores
  // onLinkTap identity; its cached spans may retain this context-only callback.
  static void _onLinkTap(BuildContext context, String url, String title) {
    if (!context.mounted) return;
    // `dshgo://open/<page>`: the guide's links to the app's own pages.
    if (openReplyPageLink(context, url)) return;
    final uri = linkToOpen(url);
    if (uri != null) {
      launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    final scope = MarkdownImageScope.maybeOf(context);
    // `[官网](example.com)`: a site written without https, unless the
    // workspace really has a file by that name.
    final site = bareDomainLink(url);
    // Detached share/replay text must not borrow an unrelated active session.
    if (scope == null) {
      if (site != null) unawaited(openConfirmedLink(context, site));
      return;
    }
    final path = workspaceLinkPath(url, baseDir: scope.baseDir);
    if (path == null) return;
    if (site != null) {
      unawaited(_openFileOrSite(context, scope.sessionId, path, site));
      return;
    }
    _preview(context, scope.sessionId, path);
  }

  static void _preview(BuildContext context, String sessionId, String path) {
    Navigator.of(context).push(
      ArtifactPreviewPage.route(
        sessionId: sessionId,
        artifact: Artifact(
          path: path,
          origin: ArtifactOrigin.linked,
          turn: MarkdownImageScope.maybeOf(context)?.turn ?? 0,
          snapshotImage:
              MarkdownImageScope.maybeOf(context)?.turn != null && artifactKindOf(path) == ArtifactKind.image,
        ),
      ),
    );
  }

  /// The workspace file at [path] when there is one (a folder by that name
  /// too: its preview says so); otherwise [site], after the browser prompt.
  static Future<void> _openFileOrSite(BuildContext context, String sessionId, String path, Uri site) async {
    WorkspaceSource? source;
    try {
      source = ProviderScope.containerOf(context, listen: false).read(workspaceSourceProvider(sessionId));
    } catch (_) {
      // No provider scope above this text: nothing to look the file up in.
    }
    var file = false;
    if (source != null) {
      try {
        await source.stat(path);
        file = true;
      } on DshRemoteException catch (e) {
        file = e.code == 'workspace-file/not-regular-file';
      } catch (_) {
        // Offline or the Host failed: the site is what the link most likely meant.
      }
    }
    if (!context.mounted) return;
    if (file) {
      _preview(context, sessionId, path);
    } else {
      await openConfirmedLink(context, site);
    }
  }

  /// File endings a bare `name.ext` link reads as a file by, even where the
  /// ending is also a country's domain (`.md`, `.py`, `.rs`, `.sh`, `.pl`…).
  static const _fileEndings = {
    'md',
    'py',
    'rs',
    'sh',
    'pl',
    'pm',
    'so',
    'cc',
    'ps',
    'ml',
    'mk',
    'sv',
    'tf',
    'bz',
    'gz',
    'xz',
    'js',
    'ts',
    'go',
    'rb',
    'cs',
    'kt',
    'hs',
    'el',
    'ex',
    'fs',
    'jl',
    'db',
    'hh',
    'cp',
    'vb',
    'nb',
    'zip',
    'mov',
    'pro',
  };

  /// Endings of three letters or more that read as a website.
  static const _siteEndings = {
    'com',
    'net',
    'org',
    'edu',
    'gov',
    'mil',
    'int',
    'info',
    'biz',
    'dev',
    'app',
    'xyz',
    'top',
    'site',
    'online',
    'tech',
    'cloud',
    'page',
    'blog',
    'shop',
    'store',
    'art',
    'wiki',
    'news',
    'live',
    'life',
    'world',
    'today',
    'space',
    'website',
    'link',
    'club',
    'name',
    'mobi',
    'asia',
    'email',
    'studio',
    'design',
    'media',
    'network',
    'games',
    'chat',
    'fun',
    'icu',
    'vip',
    'ltd',
    'group',
    'global',
    'run',
    'codes',
    'tools',
    'software',
    'one',
    'plus',
    'social',
    'ink',
  };

  static final _hostLabel = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');

  /// `example.com`, `www.example.com/docs`, `github.io` — a link target that
  /// names a website without `https://` — as the https URL; null for
  /// anything else, a file name like `notes.md` or `main.py` included.
  @visibleForTesting
  static Uri? bareDomainLink(String url) {
    var target = url.trim();
    if (target.startsWith('<') && target.endsWith('>')) {
      target = target.substring(1, target.length - 1).trim();
    }
    if (target.isEmpty || target.contains(RegExp(r'\s'))) return null;
    final uri = Uri.tryParse(target);
    if (uri == null || uri.hasScheme || uri.hasAuthority) return null;
    // The host as written: Uri drops a leading `./`, which makes it a path.
    final end = target.indexOf(RegExp('[/?#]'));
    final host = (end < 0 ? target : target.substring(0, end)).toLowerCase();
    final labels = host.split('.');
    if (labels.length < 2 || !labels.every(_hostLabel.hasMatch)) return null;
    final ending = labels.last;
    if (!RegExp(r'^[a-z]{2,}$').hasMatch(ending) || _fileEndings.contains(ending)) return null;
    final site = ending.length == 2 || _siteEndings.contains(ending) || labels.first == 'www';
    return site ? Uri.tryParse('https://$target') : null;
  }

  /// External links open only on the web or as an email: the text is
  /// model-written (and can echo a web page), so `tel:`, `sms:`, `intent:`
  /// or another app's deep link (payments included) must not launch apps.
  @visibleForTesting
  static Uri? linkToOpen(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;
    return switch (uri.scheme.toLowerCase()) {
      'http' || 'https' when uri.host.isNotEmpty => uri,
      'mailto' => uri,
      _ => null,
    };
  }

  /// File links are read by the existing session preview, never launched as
  /// platform URLs. Unknown schemes and remote file authorities stay blocked.
  @visibleForTesting
  static String? workspaceLinkPath(String url, {String? baseDir}) => resolveWorkspaceLink(url, baseDir: baseDir);

  static Widget _codeBuilder(BuildContext context, String name, String code, bool closed) {
    // A closed block won't change. Handing back the same widget lets Flutter skip it,
    // or every block of the reply would rebuild on every update.
    final reveal = closed ? context.getInheritedWidgetOfExactType<_RevealStreaming>() : null;
    if (reveal != null) return reveal.blocks['$name\n$code'] ??= _buildCode(context, name, code, closed);
    return _buildCode(context, name, code, closed);
  }

  static Widget _buildCode(BuildContext context, String name, String code, bool closed) {
    final info = name.trim();
    final language = info.isEmpty ? null : info.split(RegExp(r'\s+')).first;
    // A visual reply (dsh-ui): drawn as native cards. The cursor sentinel inside an open fence means it is still
    // streaming; open without it means the reply was cut short.
    if (language == 'dsh-ui') {
      return DshUiBlock(
        source: code.replaceAll(_cursorSentinel, ''),
        streaming: !closed && (code.contains(_cursorSentinel) || _RevealStreaming.of(context)),
        closed: closed,
      );
    }
    // A display formula still streaming in ([normalizeMath]): its source,
    // muted, until the closing `$$` arrives and it can be drawn whole.
    if (language == pendingMathLanguage) {
      final style = AppType.chatBody(context);
      return MathSource(
        source: code.replaceAll(_cursorSentinel, ''),
        style: style,
        trailing: code.contains(_cursorSentinel) ? _cursorSpan(style) : null,
      );
    }
    return CodeBlock(
      code: code.replaceAll(_cursorSentinel, ''),
      // 围栏信息串可能带属性(```json title="…"),只取第一个 token。
      language: language,
      replyActions: true,
    );
  }

  /// 标题是读屏里能逐个跳转的 header 节点。
  static Widget _headingBuilder(BuildContext context, int level, Widget content, HeadingStyle style) {
    final theme = GptMarkdownTheme.of(context);
    final heading = [theme.h1, theme.h2, theme.h3, theme.h4, theme.h5, theme.h6][level - 1];
    final size = (heading ?? const TextStyle()).merge(style.textStyle).fontSize ?? MarkdownImageFont.of(context);
    return MarkdownImageFont(
      size: size,
      child: Semantics(header: true, container: true, child: content),
    );
  }

  /// 任务清单 `- [ ]` / `- [x]`:只读的方框图标。包里默认用 Material 的
  /// [Checkbox],它要求祖先里有 Material,聊天列表里没有,会报错并溢出。
  static Widget _checkboxBuilder(BuildContext context, bool checked, Widget content, CheckboxStyle style) {
    final colors = Theme.of(context).colorScheme;
    // TaskBox: a bullet item that opens with this box draws no bullet.
    return TaskBox(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        textBaseline: TextBaseline.alphabetic,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        children: [
          Text.rich(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(end: TaskBox.gap),
                child: Icon(
                  checked ? AppIcons.checkboxOn : AppIcons.checkboxOff,
                  size: TaskBox.size,
                  color: checked ? colors.primary : colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
          Flexible(child: content),
        ],
      ),
    );
  }

  /// What gpt_markdown is given for [text]: maths delimiters normalised,
  /// tables separated from the paragraph above and their headers bold and,
  /// while [streaming], the unfinished tail repaired and the cursor sentinel
  /// placed. With [repairBareViews] a bare `dsh-ui` JSON block gets its fence
  /// back first (see [fenceBareDshUiViews]).
  @visibleForTesting
  static String prepareSource(String text, {bool streaming = false, bool repairBareViews = false}) =>
      _prepareSource(text, streaming: streaming, repairBareViews: repairBareViews);

  /// Characters a second when the model is slower than this; the reveal goes faster
  /// by itself when it would fall behind. Near a comfortable reading pace, so the text
  /// flows evenly instead of catching up in bursts.
  static const _revealPace = 120.0;

  /// How long the newest words take to fade in.
  static const _revealFade = 0.24;

  /// [text] for the reveal. Only ever appended to while streaming, as the reveal needs
  /// (a rewrite far from the end would retype the message): a table's header is bolded
  /// as its delimiter row arrives, right at the end and for good, so its columns don't
  /// change when the reply finishes. Formulas are left to the library's own hold.
  static String _prepareRevealed(String text, {required bool repairBareViews}) {
    final repaired = repairBareViews ? fenceBareDshUiViews(text) : text;
    return boldTableHeaders(blankLineBeforeTables(normalizeMath(repaired)));
  }

  static String _prepareSource(
    String text, {
    bool streaming = false,
    bool repairBareViews = false,
    StreamingMarkdownRepair? repair,
  }) {
    final repaired = repairBareViews ? fenceBareDshUiViews(text) : text;
    final source = boldTableHeaders(blankLineBeforeTables(normalizeMath(repaired, streaming: streaming)));
    if (!streaming) return source;
    return _withCursor(repair?.repair(source) ?? repairStreamingMarkdown(source));
  }

  /// [text] with the cursor sentinel where the reader's eye is: at the end
  /// of the last line, except that a closing fence or a display formula's
  /// `\]` must stay alone on its line, and a table row takes it inside its
  /// last cell rather than as a new cell after the pipe.
  static String _withCursor(String text) {
    final last = text.substring(text.lastIndexOf('\n') + 1).trim();
    if (_fenceLine.hasMatch(last) || last.endsWith(r'\]')) {
      return '$text\n$_cursorSentinel';
    }
    if (last.length > 1 && last.startsWith('|') && last.endsWith('|')) {
      final pipe = text.lastIndexOf('|');
      return '${text.substring(0, pipe).trimRight()} $_cursorSentinel '
          '${text.substring(pipe)}';
    }
    return '$text$_cursorSentinel';
  }

  static final _fenceLine = RegExp(r'^(?:>\s*)*(?:`{3,}|~{3,})\s*$');

  static InlineSpan _inlineCodeBuilder(BuildContext context, String code, TextStyle style, InlineCodeStyle codeStyle) =>
      CodeTextSpan(
        text: code.replaceAll(_cursorSentinel, ''),
        codeStyle: codeStyle,
        style: style.copyWith(fontFeatures: AppType.monoFeatures),
      );

  @override
  State<MarkdownBody> createState() => _MarkdownBodyState();
}

class _MarkdownBodyState extends State<MarkdownBody> {
  StreamingMarkdownRepair? _repair;

  // Preparation depends only on text and streaming, not theme, text scale or
  // selection. Keep one result for this mounted body; unrelated stream rows
  // can rebuild its parent without rescanning the unchanged Markdown.
  late String _source = _prepare();

  String _prepare() {
    if (widget.reveal) {
      return MarkdownBody._prepareRevealed(widget.text, repairBareViews: widget.repairBareViews);
    }
    _repair = widget.streaming ? (_repair ?? StreamingMarkdownRepair()) : null;
    return MarkdownBody._prepareSource(
      widget.text,
      streaming: widget.streaming,
      repairBareViews: widget.repairBareViews,
      repair: _repair,
    );
  }

  /// 这棵树里有没有 ProviderScope。只在依赖变化时向上找一次 —— 正文随流式
  /// 每 32ms 重建一次，不必每次都走一遍 InheritedWidget 的查找。
  ///
  /// ProviderScope 挂在应用根上，装好之后不会中途消失，所以缓存到下一次
  /// didChangeDependencies 为止是安全的。
  bool _scoped = true;

  /// Finished code blocks of a revealed reply: see [_RevealStreaming.blocks].
  final _blocks = <String, Widget>{};

  /// Drawn in blocks ([MarkdownBody.blockLength]). Decided once and kept: a
  /// streamed reply keeps its tree when it finishes.
  late bool _blocked = _wantsBlocks();

  final _split = MarkdownBlockSplit(html: _markdownHtml, minLength: MarkdownBody.blockLength);

  /// Each block's widget, handed back while its text, its place at the end
  /// and [_builtStyle] stay the same: Flutter then skips the block entirely.
  final _built = <({String text, bool live, Widget widget})>[];
  TextStyle? _builtStyle;

  /// How many blocks the last build had (none before the first): what is
  /// already on screen has been seen, and only blocks past it are revealed
  /// from empty.
  int _shown = 0;

  bool _wantsBlocks() => widget.streaming || widget.reveal || widget.text.length >= MarkdownBody.blockLength;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scoped = _hasProviderScope(context);
  }

  @override
  void didUpdateWidget(MarkdownBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.streaming != widget.streaming ||
        oldWidget.reveal != widget.reveal ||
        oldWidget.repairBareViews != widget.repairBareViews) {
      _source = _prepare();
    }
    _blocked = _blocked || _wantsBlocks();
    if (oldWidget.reveal != widget.reveal) _built.clear();
  }

  /// [data] as one GptMarkdown; [live] when it is still being written.
  GptMarkdown _markdown(String data, TextStyle body, {required bool live, List<InlinePattern>? patterns}) {
    // The element itself, not [State.context]: a link tapped after this body
    // is gone asks it whether it is still mounted.
    final context = this.context;
    return GptMarkdown(
      data,
      style: body,
      followLinkColor: false,
      htmlTags: _htmlTags,
      // The tail is repaired here (and open formulas shown as source), so
      // the package must not complete open `\(` / `\[` on its own.
      isStreaming: widget.reveal && live,
      animation: widget.reveal ? GptMarkdownAnimation.fade : GptMarkdownAnimation.none,
      blockAnimation: widget.reveal ? GptMarkdownBlockAnimation.fadeIn : GptMarkdownBlockAnimation.none,
      charactersPerSecond: MarkdownBody._revealPace,
      revealFadeSeconds: MarkdownBody._revealFade,
      inlinePatterns: patterns,
      onLinkTap: (url, title) => MarkdownBody._onLinkTap(context, url, title),
      codeBuilder: MarkdownBody._codeBuilder,
      inlineCodeBuilder: MarkdownBody._inlineCodeBuilder,
      checkboxBuilder: MarkdownBody._checkboxBuilder,
      headingBuilder: MarkdownBody._headingBuilder,
      inlineLatexBuilder: MarkdownMath.inline,
      blockLatexBuilder: MarkdownMath.block,
      imageBuilder: markdownImageBuilder,
      orderedListBuilder: MarkdownLists.ordered,
      unOrderedListBuilder: MarkdownLists.unordered,
    );
  }

  /// The blocks of [_source], built or handed back from [_built].
  ///
  /// Only the last block is live: it alone gets the cursor, the reveal's
  /// streaming hold, and new text. A block that appears as a revealed reply
  /// streams starts empty ([_RevealBlock]), so its words fade in.
  _MarkdownBlocks _blocksFor(TextStyle body) {
    if (_builtStyle != body) {
      _built.clear();
      _builtStyle = body;
    }
    final blocks = _split.update(_source);
    final children = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      final text = blocks[i];
      final live = widget.streaming && i == blocks.length - 1;
      var built = i < _built.length ? _built[i] : null;
      if (built == null || built.live != live || !(identical(built.text, text) || built.text == text)) {
        final Widget block = widget.reveal
            ? _RevealBlock(
                text: text,
                fromEmpty: _shown > 0 && i >= _shown,
                build: (text) => _markdown(text, body, live: live),
              )
            : _markdown(text, body, live: live, patterns: live ? MarkdownBody._streamingPatterns : null);
        built = (text: text, live: live, widget: RepaintBoundary(child: block));
        if (i < _built.length) {
          _built[i] = built;
        } else {
          _built.add(built);
        }
      }
      children.add(built.widget);
    }
    if (_built.length > blocks.length) _built.removeRange(blocks.length, _built.length);
    _shown = blocks.length;
    return _MarkdownBlocks(style: body, children: children);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final body = widget.secondary
        ? AppType.chatBody(context, scale: 0.9, color: theme.colorScheme.onSurfaceVariant)
        : AppType.chatBody(context, color: theme.colorScheme.onSurface);
    final source = _source;
    final extra = MarkdownPatterns.maybeOf(context);

    // 表格底色是用户设置，只有主题跟着它变；正文 widget 本身保持同一个实例，
    // 切设置时不让 gpt_markdown 重新解析一遍。
    // A part of the app's own patterns (the tavern's) are matched over the
    // whole text, so such a text stays one GptMarkdown.
    final Widget text = _blocked && extra == null
        ? _blocksFor(body)
        : _markdown(
            source,
            body,
            live: widget.streaming,
            patterns: switch ((widget.streaming && !widget.reveal, extra)) {
              (true, null) => MarkdownBody._streamingPatterns,
              (false, null) => null,
              (true, final extra?) => MarkdownBody._streamingWith[extra] ??= [
                ...MarkdownBody._streamingPatterns,
                ...extra,
              ],
              (false, final extra?) => extra,
            },
          );

    Widget withTint(TableTint tint) =>
        GptMarkdownTheme(gptThemeData: MarkdownBody._themeFor(theme, widget.secondary, l10n, tint), child: text);

    // Golden 和几何测试不套 ProviderScope:那时按默认那一档画。
    Widget markdown = _scoped
        ? Consumer(builder: (context, ref, _) => withTint(ref.watch(tableTintProvider)))
        : withTint(TableTint.follow);
    // 表格、成块公式横向放不下时,两端淡出提示还能横滑。
    markdown = ScrollConfiguration(behavior: const EdgeFadeScrollBehavior(), child: markdown);
    if (widget.reveal) markdown = _RevealStreaming(streaming: widget.streaming, blocks: _blocks, child: markdown);
    if (widget.selectable) markdown = SelectionArea(child: markdown);
    return MarkdownImageFont(
      size: body.fontSize!,
      child: MarkdownGalleryScope(child: markdown),
    );
  }
}

/// The blocks of a reply stacked as gpt_markdown stacks its own segments: the
/// same gap between them, sized to their content, left-aligned.
class _MarkdownBlocks extends StatelessWidget {
  const _MarkdownBlocks({required this.style, required this.children});

  /// The text style the blocks are drawn in; the gap is scaled from it.
  final TextStyle style;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    textDirection: TextDirection.ltr,
    spacing: blockGap(context, GptMarkdownConfig(style: style)),
    children: children,
  );
}

/// One block of a revealed reply. A GptMarkdown shows the text it mounts with
/// at once (it has been seen), so a block that comes into being as the reply
/// streams first mounts empty, for a frame, and its words then fade in.
class _RevealBlock extends StatefulWidget {
  const _RevealBlock({required this.text, required this.fromEmpty, required this.build});

  final String text;

  /// Read when the block mounts: whether it starts empty.
  final bool fromEmpty;
  final Widget Function(String text) build;

  @override
  State<_RevealBlock> createState() => _RevealBlockState();
}

class _RevealBlockState extends State<_RevealBlock> {
  late bool _empty = widget.fromEmpty;

  @override
  void initState() {
    super.initState();
    if (_empty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _empty = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.build(_empty ? '' : widget.text);
}

/// 当前子树里有没有 ProviderScope;没有就按默认表格底色画。
bool _hasProviderScope(BuildContext context) {
  try {
    ProviderScope.containerOf(context, listen: false);
    return true;
  } on StateError {
    return false;
  }
}

/// Whether the reveal's reply is still streaming, for the builders below it: with no
/// cursor in the source, an open fence can't tell "still arriving" from "cut short".
class _RevealStreaming extends InheritedWidget {
  const _RevealStreaming({required this.streaming, required this.blocks, required super.child});

  final bool streaming;

  /// Finished code blocks by name and content.
  final Map<String, Widget> blocks;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_RevealStreaming>()?.streaming ?? false;

  @override
  bool updateShouldNotify(_RevealStreaming oldWidget) => streaming != oldWidget.streaming;
}
