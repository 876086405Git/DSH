// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/clojure.dart';
import 'package:re_highlight/languages/cmake.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/dos.dart';
import 'package:re_highlight/languages/elixir.dart';
import 'package:re_highlight/languages/erlang.dart';
import 'package:re_highlight/languages/fsharp.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/gradle.dart';
import 'package:re_highlight/languages/graphql.dart';
import 'package:re_highlight/languages/groovy.dart';
import 'package:re_highlight/languages/haskell.dart';
import 'package:re_highlight/languages/http.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/julia.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/latex.dart';
import 'package:re_highlight/languages/less.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/matlab.dart';
import 'package:re_highlight/languages/nginx.dart';
import 'package:re_highlight/languages/nix.dart';
import 'package:re_highlight/languages/objectivec.dart';
import 'package:re_highlight/languages/ocaml.dart';
import 'package:re_highlight/languages/perl.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/powershell.dart';
import 'package:re_highlight/languages/properties.dart';
import 'package:re_highlight/languages/protobuf.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/r.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scala.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/verilog.dart';
import 'package:re_highlight/languages/vim.dart';
import 'package:re_highlight/languages/vue.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';

import '../../../l10n/l10n.dart';
import '../../common/edge_fade.dart';
import '../../common/fluid_bits.dart';
import '../../common/overscroll_forwarder.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'diff_view.dart' show DiffLineKind, parseUnifiedDiff;
import 'markdown_blocks.dart' show MarkdownReplyScope;
import 'mermaid_preview.dart';

/// 超过该长度不做语法高亮(纯等宽渲染),避免大输出卡顿。
const _kHighlightMaxChars = 20000;

final Highlight _hl = Highlight()
  ..registerLanguages({
    'bash': langBash,
    'c': langC,
    'clojure': langClojure,
    'cmake': langCmake,
    'cpp': langCpp,
    'csharp': langCsharp,
    'css': langCss,
    'dart': langDart,
    'diff': langDiff,
    'dockerfile': langDockerfile,
    'dos': langDos,
    'elixir': langElixir,
    'erlang': langErlang,
    'fsharp': langFsharp,
    'go': langGo,
    'gradle': langGradle,
    'graphql': langGraphql,
    'groovy': langGroovy,
    'haskell': langHaskell,
    'http': langHttp,
    'ini': langIni,
    'java': langJava,
    'javascript': langJavascript,
    'json': langJson,
    'julia': langJulia,
    'kotlin': langKotlin,
    'latex': langLatex,
    'less': langLess,
    'lua': langLua,
    'makefile': langMakefile,
    'markdown': langMarkdown,
    'matlab': langMatlab,
    'nginx': langNginx,
    'nix': langNix,
    'objectivec': langObjectivec,
    'ocaml': langOcaml,
    'perl': langPerl,
    'php': langPhp,
    'powershell': langPowershell,
    'properties': langProperties,
    'protobuf': langProtobuf,
    'python': langPython,
    'r': langR,
    'ruby': langRuby,
    'rust': langRust,
    'scala': langScala,
    'scss': langScss,
    'shell': langShell,
    'sql': langSql,
    'swift': langSwift,
    'typescript': langTypescript,
    'verilog': langVerilog,
    'vim': langVim,
    'vue': langVue,
    'xml': langXml,
    'yaml': langYaml,
  });

const _aliases = <String, String>{
  'js': 'javascript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'node': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'py': 'python',
  'sh': 'bash',
  'zsh': 'bash',
  'fish': 'bash',
  'console': 'shell',
  'yml': 'yaml',
  'toml': 'ini',
  'html': 'xml',
  'htm': 'xml',
  'svg': 'xml',
  'c++': 'cpp',
  'cc': 'cpp',
  'cxx': 'cpp',
  'h': 'c',
  'hpp': 'cpp',
  'rs': 'rust',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'md': 'markdown',
  'patch': 'diff',
  'rb': 'ruby',
  'docker': 'dockerfile',
  'make': 'makefile',
  'cs': 'csharp',
  'c#': 'csharp',
  'objc': 'objectivec',
  'objective-c': 'objectivec',
  'mm': 'objectivec',
  'pl': 'perl',
  'ps1': 'powershell',
  'pwsh': 'powershell',
  'ps': 'powershell',
  'bat': 'dos',
  'cmd': 'dos',
  'batch': 'dos',
  'tex': 'latex',
  'proto': 'protobuf',
  'gql': 'graphql',
  'hs': 'haskell',
  'ex': 'elixir',
  'exs': 'elixir',
  'erl': 'erlang',
  'fs': 'fsharp',
  'f#': 'fsharp',
  'ml': 'ocaml',
  'jl': 'julia',
  'sass': 'scss',
  'jsonc': 'json',
  'json5': 'json',
  'conf': 'ini',
  'cfg': 'ini',
  'env': 'properties',
  'sv': 'verilog',
  'vimscript': 'vim',
  'jsonl': 'json',
  'psql': 'sql',
  'mysql': 'sql',
  'postgresql': 'sql',
  'sqlite': 'sql',
};

/// [language] as the highlighter knows it (`ts` → `typescript`); null when
/// it has no grammar for it.
String? normalizedLanguage(String? language) => _normalizeLanguage(language);

String? _normalizeLanguage(String? language) {
  if (language == null) return null;
  final lower = language.trim().toLowerCase();
  if (lower.isEmpty) return null;
  final resolved = _aliases[lower] ?? lower;
  return _hl.listLanguages().contains(resolved) ? resolved : null;
}

/// 按文件扩展名推断高亮语言;未知返回 null。
String? languageForPath(String path) {
  final name = path.split('/').last;
  if (name == 'Dockerfile') return 'dockerfile';
  if (name == 'Makefile') return 'makefile';
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  return _normalizeLanguage(name.substring(dot + 1));
}

/// 语法高亮为 TextSpan;语言未知时是纯文本 span。
///
/// 长代码按 [codeChunks] 分块高亮、按块缓存:流式追加时前面的块原样复用,
/// 只重算最后一块;单块超长才退化为纯文本。
TextSpan highlightCode(
  String code,
  String? language,
  Brightness brightness, {
  TextStyle? style,
  AppAccent accent = AppAccent.mist,
  ThemeSyntaxColors? syntax,
}) {
  final base = style ?? AppType.mono();
  final lang = _normalizeLanguage(language);
  if (lang == null) return TextSpan(text: code, style: base);
  final chunks = codeChunks(code);
  if (chunks.length == 1) return _highlightChunk(code, lang, brightness, base, accent, syntax);
  return TextSpan(
    style: base,
    children: [for (final chunk in chunks) _highlightChunk(chunk, lang, brightness, base, accent, syntax)],
  );
}

/// 最近高亮过的块(LRU)。
final _chunkSpans = <(String, String, Brightness, TextStyle, AppAccent, ThemeSyntaxColors?), TextSpan>{};

TextSpan _highlightChunk(
  String code,
  String language,
  Brightness brightness,
  TextStyle base,
  AppAccent accent,
  ThemeSyntaxColors? syntax,
) {
  if (code.length > _kHighlightMaxChars) return TextSpan(text: code, style: base);
  final key = (code, language, brightness, base, accent, syntax);
  final cached = _chunkSpans.remove(key);
  if (cached != null) return _chunkSpans[key] = cached;
  var span = TextSpan(text: code, style: base);
  try {
    final result = _hl.highlight(code: code, language: language);
    final renderer = TextSpanRenderer(base, dshHighlightTheme(brightness, accent, syntax));
    result.render(renderer);
    span = renderer.span ?? span;
  } catch (_) {}
  _chunkSpans[key] = span;
  if (_chunkSpans.length > 64) _chunkSpans.remove(_chunkSpans.keys.first);
  return span;
}

/// 把长代码切成能各自高亮的块,拼起来和原文一字不差。
///
/// 不超过 200 行是一块。更长的从上一刀起满 200 行后,切在「空行
/// 之后顶格的一行」前面(多半是下一个声明),块注释和多行字符串里不切;
/// 满 400 行还没找到就硬切。
@visibleForTesting
List<String> codeChunks(String code) {
  var startOfLine = 0;
  for (var line = 0; line < 200; line++) {
    final end = code.indexOf('\n', startOfLine);
    if (end < 0 || end + 1 == code.length) return [code];
    startOfLine = end + 1;
  }
  final lines = <String>[];
  for (var at = 0; at < code.length;) {
    final end = code.indexOf('\n', at);
    final next = end < 0 ? code.length : end + 1;
    lines.add(code.substring(at, next));
    at = next;
  }
  final topLevel = RegExp(r'^[A-Za-z0-9_]');
  final chunks = <String>[];
  var start = 0;
  var comments = 0;
  String? quote;
  for (var line = 0; line < lines.length; line++) {
    final text = lines[line];
    final count = line - start;
    if (count >= 400 ||
        (count >= 200 && comments == 0 && quote == null && lines[line - 1].trim().isEmpty && topLevel.hasMatch(text))) {
      chunks.add(lines.sublist(start, line).join());
      start = line;
    }
    // 粗扫一遍这一行,记下块注释和字符串有没有跨到下一行。
    for (var i = 0; i < text.length;) {
      final open = quote;
      if (comments > 0) {
        if (text.startsWith('/*', i)) {
          comments++;
          i += 2;
        } else if (text.startsWith('*/', i)) {
          comments--;
          i += 2;
        } else {
          i++;
        }
      } else if (open != null) {
        if (text[i] == r'\') {
          i += 2;
        } else if (text.startsWith(open, i)) {
          quote = null;
          i += open.length;
        } else {
          i++;
        }
      } else if (text.startsWith('//', i) || text[i] == '#') {
        break;
      } else if (text.startsWith('/*', i)) {
        comments++;
        i += 2;
      } else if ('"\'`'.contains(text[i])) {
        final mark = text[i];
        quote = text.startsWith(mark * 3, i) ? mark * 3 : mark;
        i += quote.length;
      } else {
        i++;
      }
    }
    // 单引号、双引号的字符串不跨行(撇号、Rust 的生命周期也别把后面全吞了)。
    if (quote == '"' || quote == "'") quote = null;
  }
  chunks.add(lines.sublist(start).join());
  return chunks;
}

/// 代码井:语言标签 + 复制键的标题条 + 横向滚动的高亮代码,可选行号。
///
/// 所有等宽前景(语法色、行号)只铺在 [DshColors.codeWellBg] 上 —— 那是
/// 唯一对它们做过对比度核查的底色。
class CodeBlock extends StatefulWidget {
  const CodeBlock({
    super.key,
    required this.code,
    this.language,
    this.showLineNumbers = false,
    this.firstLineNumber = 1,
    this.maxHeight,
    this.embedded = false,
    this.replyActions = false,
    this.dense = false,
  });

  final String code;
  final String? language;
  final bool showLineNumbers;
  final int firstLineNumber;
  final double? maxHeight;

  /// 嵌在工具行详情里:不画外框与标题条,只出代码(外层已有井底)。
  final bool embedded;

  /// 回复正文里的代码:标题条多一个「自动换行」开关;Mermaid 图表多一个
  /// 「预览」。
  final bool replyActions;

  /// 工具详情里的代码:12 号字,上边贴着小标题,左右与小标题对齐。
  final bool dense;

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  /// [_cachedCode] highlighted.
  TextSpan? _span;

  /// What is drawn: [_span], plus the code that came after it, plain.
  TextSpan? _shown;
  String? _cachedCode;
  String? _cachedLanguage;
  Brightness? _cachedBrightness;
  AppAccent? _cachedAccent;
  ThemeSyntaxColors? _cachedSyntax;
  bool? _cachedDense;
  String? _cachedFontFamily;
  double? _cachedFontSize;

  /// 复制成功后图标原地闪成对勾再回退 —— 比 SnackBar 轻。
  late _CopyButton _copyButton = _CopyButton(copied: false, onTap: _copy);

  /// 长行折回显示,而不是横向滚动。
  bool _wrap = false;
  _HeaderButton? _wrapButton;

  _HeaderButton _wrapControl(L10n l10n) {
    final hint = _wrap ? l10n.chatUnwrapLines : l10n.chatWrapLines;
    final button = _wrapButton;
    if (button != null && button.selected == _wrap && button.tooltip == hint) return button;
    return _wrapButton = _HeaderButton(
      icon: AppIcons.wrapLines,
      tooltip: hint,
      selected: _wrap,
      onTap: () => setState(() => _wrap = !_wrap),
    );
  }

  /// While code streams in, it is highlighted again at most this often (the
  /// last chunk of up to 8000 characters, every delta, was the cost); what
  /// came since shows plain until then.
  static const _highlightEvery = Duration(milliseconds: 250);
  Timer? _cooldown;

  @override
  void dispose() {
    _cooldown?.cancel();
    super.dispose();
  }

  void _cooled() {
    _cooldown = null;
    // Still behind the code: highlight the rest.
    if (mounted && !identical(_shown, _span)) setState(() {});
  }

  bool get _mermaid => widget.language?.trim().toLowerCase() == 'mermaid';

  String get _trimmedCode {
    var code = widget.code;
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    return code;
  }

  void _setCopied(bool copied) => setState(() => _copyButton = _CopyButton(copied: copied, onTap: _copy));

  void _copy() {
    Clipboard.setData(ClipboardData(text: _trimmedCode));
    HapticFeedback.lightImpact();
    _setCopied(true);
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) _setCopied(false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final brightness = Theme.of(context).brightness;
    final accent = DshSurfaces.of(context).accent;
    final code = _trimmedCode;
    final themeStyle = DshThemeStyle.of(context);
    final syntax = themeStyle.syntax;
    final baseStyle = widget.dense ? AppType.monoSmall(color: dsh.codeWellFg) : AppType.mono(color: dsh.codeWellFg);
    final style = themeStyle.pack == null ? baseStyle : themeStyle.codeTextStyle(baseStyle);

    final diff = !widget.showLineNumbers && normalizedLanguage(widget.language) == 'diff';
    final previous = _cachedCode;
    final sameLook =
        _span != null &&
        _cachedLanguage == widget.language &&
        _cachedBrightness == brightness &&
        _cachedAccent == accent &&
        _cachedSyntax == syntax &&
        _cachedDense == widget.dense &&
        _cachedFontFamily == style.fontFamily &&
        _cachedFontSize == style.fontSize;
    if (diff) {
      // Diff rows paint their own colours; discard any previous highlighted text.
      _span = _shown = null;
      _cachedCode = null;
      _cooldown?.cancel();
      _cooldown = null;
    } else if (!sameLook || previous != code) {
      final grows = sameLook && previous != null && code.length > previous.length && code.startsWith(previous);
      if (grows && _cooldown != null) {
        _shown = TextSpan(
          style: style,
          children: [
            _span!,
            TextSpan(text: code.substring(previous.length)),
          ],
        );
      } else {
        final old = grows ? _span : null;
        _span = _shown = highlightCode(code, widget.language, brightness, style: style, accent: accent, syntax: syntax);
        // Code that grew replaced its cached prefix: the old span itself (one chunk) or its
        // last chunk (several). Drop that from the global cache unless the new span reuses it.
        for (final stale in [?old, ?old?.children?.lastOrNull]) {
          if (identical(stale, _span) || (_span!.children?.any((c) => identical(c, stale)) ?? false)) continue;
          _chunkSpans.removeWhere((_, span) => identical(span, stale));
        }
        _cachedCode = code;
        _cachedLanguage = widget.language;
        _cachedBrightness = brightness;
        _cachedAccent = accent;
        _cachedSyntax = syntax;
        _cachedDense = widget.dense;
        _cachedFontFamily = style.fontFamily;
        _cachedFontSize = style.fontSize;
        _cooldown?.cancel();
        _cooldown = grows ? Timer(_highlightEvery, _cooled) : null;
      }
    } else if (!identical(_shown, _span)) {
      // Back to exactly what was highlighted (a resync): drop the plain tail
      // the cooldown was showing after it.
      _shown = _span;
    }

    Widget body;
    if (diff) {
      body = _DiffLines(code: code, style: style, wrap: _wrap);
    } else {
      body = Padding(
        padding: EdgeInsets.fromLTRB(
          widget.dense || widget.showLineNumbers ? 12 : 16,
          widget.dense ? 4 : 12,
          widget.dense ? 12 : 16,
          12,
        ),
        child: Text.rich(_shown!),
      );
      if (!_wrap) {
        body = HorizontalEdgeFade(
          child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: body),
        );
      }
    }
    // 长按选字,选区包在横滑外面:手势场里横滑先到,拖动归滚动(放在里面的
    // SelectableText 会吃掉 Android 上的横向拖动)。外面已有选区(选择文字
    // 页)时并进那一个。
    if (SelectionContainer.maybeOf(context) == null) {
      body = SelectionArea(child: body);
    }
    if (widget.showLineNumbers) {
      final lineCount = '\n'.allMatches(code).length + 1;
      final gutter = List.generate(lineCount, (i) => '${widget.firstLineNumber + i}').join('\n');
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: widget.dense ? const EdgeInsets.fromLTRB(12, 4, 0, 12) : const EdgeInsets.fromLTRB(16, 12, 0, 12),
            child: SelectionContainer.disabled(
              child: Text(
                gutter,
                textAlign: TextAlign.right,
                style: AppType.tabular(style.copyWith(color: dsh.lineNumberFg)),
              ),
            ),
          ),
          Expanded(child: body),
        ],
      );
    }
    if (widget.maxHeight != null) {
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight!),
        // 纵向滚到头后让路给外层消息列表。
        child: OverscrollForwarder(child: SingleChildScrollView(child: body)),
      );
    }

    if (widget.embedded) return body;

    final label = widget.language?.trim();
    final codeRadius = themeStyle.pack == null ? AppShape.md : themeStyle.codeRadius;
    final codeBorderRadius = themeStyle.pack == null
        ? AppShape.radiusMd
        : BorderRadius.all(Radius.circular(codeRadius));
    final codeStyle = themeStyle.components.codeBlockStyle;
    // In a reply that is itself a card, the block drops its own outline:
    // one frame, not two. A frame-only block then needs the well's fill.
    final framed =
        themeStyle.pack != null &&
        MarkdownReplyScope.of(context) &&
        (themeStyle.components.assistantStyle == ThemeAssistantStyle.card ||
            themeStyle.components.assistantStyle == ThemeAssistantStyle.quote);
    final boxFill = switch (codeStyle) {
      ThemeCodeBlockStyle.well => dsh.codeWellBg,
      ThemeCodeBlockStyle.outlined when framed => dsh.codeWellBg,
      ThemeCodeBlockStyle.outlined => colors.surface.withValues(alpha: 0.72),
      ThemeCodeBlockStyle.card => DshSurfaces.of(context).card.fallbackFill,
    };
    final headerFill = switch (codeStyle) {
      _ when themeStyle.components.codeHeaderStyle == ThemeCodeHeaderStyle.plain => Colors.transparent,
      ThemeCodeBlockStyle.well => dsh.codeWellHeader,
      ThemeCodeBlockStyle.outlined => dsh.codeWellHeader.withValues(alpha: 0.45),
      ThemeCodeBlockStyle.card => dsh.codeWellHeader.withValues(alpha: 0.7),
    };
    final boxBorderColor = codeStyle == ThemeCodeBlockStyle.outlined ? colors.outlineVariant : dsh.codeWellBorder;
    final boxBorderWidth = themeStyle.pack == null
        ? 0.5
        : (codeStyle == ThemeCodeBlockStyle.outlined
            ? themeStyle.borderWidth.clamp(1.0, 2.0)
            : themeStyle.borderWidth.clamp(0.5, 2.0));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: boxFill,
          shape: themeStyle.shapeFor(
            codeBorderRadius,
            framed ? BorderSide.none : BorderSide(color: boxBorderColor, width: boxBorderWidth),
          ),
        ),
        child: themeStyle.clipFor(
          codeRadius,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 标题条:左边语言名、右边「复制」,两端各留 16(复制键自带 8
              // 的点按边,所以条的右内边距是 8)。
              ColoredBox(
                color: headerFill,
                child: SizedBox(
                  height: math.max(36, _headerButtonHeight(context) + 8),
                  child: Row(
                    children: [
                      const SizedBox(width: 16),
                      if (_mermaid) ...[
                        Icon(AppIcons.diagram, size: 14, color: colors.onSurfaceVariant),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          _mermaid
                              ? l10n.chatMermaidChart
                              : label == null || label.isEmpty
                              ? 'text'
                              : label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _mermaid
                              ? theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant, fontSize: 12)
                              : AppType.monoLabel(color: colors.onSurfaceVariant),
                        ),
                      ),
                      if (widget.replyActions && _mermaid)
                        _HeaderButton(
                          icon: AppIcons.preview,
                          label: l10n.chatPreview,
                          onTap: () => Navigator.of(context).push(MermaidPreviewPage.route(source: code)),
                        )
                      else if (widget.replyActions)
                        _wrapControl(l10n),
                      _copyButton,
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              ),
              body,
            ],
          ),
        ),
      ),
    );
  }
}

/// 标题条上带字的按钮高:28,字号放大时跟着长,字不被裁。
double _headerButtonHeight(BuildContext context) => math.max(28, MediaQuery.textScalerOf(context).scale(12) * 1.35 + 8);

/// 代码井标题条上的小按钮(「自动换行」开关、「预览」):28 高、与「复制」
/// 同一套留白;只有图标时是 28 的方形点按区。
class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.icon, required this.onTap, this.label, this.tooltip, this.selected = false});

  final IconData icon;
  final String? label;
  final String? tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;
    final text = label;
    Widget button = InkWell(
      onTap: onTap,
      customBorder: const StadiumBorder(),
      child: SizedBox(
        height: text == null ? 28 : _headerButtonHeight(context),
        width: text == null ? 28 : null,
        child: text == null
            ? Icon(icon, size: 16, color: color)
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 14, color: color),
                    const SizedBox(width: 4),
                    Text(text, style: theme.textTheme.labelSmall?.copyWith(color: color, fontSize: 12)),
                  ],
                ),
              ),
      ),
    );
    final hint = tooltip ?? label;
    button = Semantics(
      button: true,
      toggled: label == null ? selected : null,
      label: hint,
      excludeSemantics: true,
      onTap: onTap,
      child: hint == null ? button : Tooltip(message: hint, child: button),
    );
    return button;
  }
}

/// ```diff 代码块:增删整行着色(与改动卡同一套 diff 色),hunk 头浅底;
/// 不换行时横向滚动,行底色铺满最宽的一行。
class _DiffLines extends StatelessWidget {
  const _DiffLines({required this.code, required this.style, required this.wrap});

  final String code;
  final TextStyle style;
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final dsh = DshColors.of(context);
    final colors = Theme.of(context).colorScheme;
    final lines = parseUnifiedDiff(code);
    Widget row(String text, DiffLineKind kind) {
      final (bg, fg) = switch (kind) {
        DiffLineKind.add => (dsh.diffAddBg, dsh.diffAddFg),
        DiffLineKind.del => (dsh.diffDelBg, dsh.diffDelFg),
        DiffLineKind.hunk => (dsh.codeWellHeader, dsh.diffHunkFg),
        DiffLineKind.meta => (null, colors.onSurfaceVariant),
        DiffLineKind.context => (null, dsh.codeWellFg),
      };
      return Container(
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          text.isEmpty ? ' ' : text,
          style: style.copyWith(color: fg),
          softWrap: wrap,
        ),
      );
    }

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        for (final line in lines) row(line.text, line.kind),
        const SizedBox(height: 12),
      ],
    );
    if (wrap) return column;
    return LayoutBuilder(
      builder: (context, constraints) => HorizontalEdgeFade(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: IntrinsicWidth(child: column),
          ),
        ),
      ),
    );
  }
}

/// 代码井标题条上的「⧉ 复制」→「✓ 已复制」,图标与文字一起交叉淡变。
class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.copied, required this.onTap});

  final bool copied;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final color = copied ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      label: copied ? l10n.commonCopied : l10n.commonCopy,
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: copied ? l10n.commonCopied : l10n.commonCopy,
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          child: SizedBox(
            height: _headerButtonHeight(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: AnimatedSwitcher(
                duration: AppMotion.of(context, AppMotion.quick),
                child: Row(
                  key: ValueKey(copied),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (copied && AppMotion.fluid(context))
                      DrawnCheck(size: 14, color: color)
                    else
                      Icon(copied ? AppIcons.done : AppIcons.copy, size: 14, color: color),
                    const SizedBox(width: 4),
                    Text(
                      copied ? l10n.commonCopied : l10n.commonCopy,
                      style: theme.textTheme.labelSmall?.copyWith(color: color, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
