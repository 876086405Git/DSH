import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';

import '../../l10n/l10n.dart';
import '../common/tool_glyph.dart';
import 'dsh_ui/dsh_ui_model.dart' show DshUiParse, DshUiParsed;
import 'dsh_ui/dsh_ui_plugin.dart';
import '../../state/sessions_state.dart' show localWorkspaceDir;
import 'render/code_block.dart' show languageForPath;
import 'render/diff_view.dart';

/// 插件工具的原生卡片(结果 meta 里的 `dsh-go/view`,见
/// `docs/design/native-plugins-views.md` §8):null = 没有;
/// `DshUiInvalid` = 有但画不了。只在成功的调用上读;解析按 meta 对象缓存。
DshUiParse? toolCardParse(ToolChatItem item) {
  if (item.status != ToolStatus.succeeded) return null;
  final meta = item.meta;
  if (meta is! Map || !meta.containsKey(toolCardViewKey)) return null;
  return parsePluginView(meta[toolCardViewKey], budget: PluginViewBudget.toolCard);
}

/// 生成的图片 / 视频(结果 meta 里的 `dsh-go/media`,见
/// `docs/design/media-generation.md` §2.5):null = 没有。任何状态都读(视频
/// 先回一张「生成中」,失败也带原因);解析按 meta 对象缓存。
MediaMeta? toolMedia(ToolChatItem item) {
  final meta = item.meta;
  if (meta is! Map || !meta.containsKey(mediaMetaKey)) return null;
  final cached = _media[meta];
  if (cached != null) return cached.$1;
  final parsed = MediaMeta.fromToolMeta(meta);
  _media[meta] = (parsed,);
  return parsed;
}

final _media = Expando<(MediaMeta?,)>('media');

typedef QuestionReply = ({String id, String question, String answer});

final _questionReplies = Expando<List<QuestionReply>>('question replies');

/// A durable receipt, only from a successful question tool's saved answer.
/// Unknown/malformed results retain the ordinary raw tool detail.
List<QuestionReply> toolQuestionReplies(ToolChatItem item) {
  if (item.name != 'ask_user_question' || item.status != ToolStatus.succeeded) return const [];
  return _questionReplies[item] ??= _parseQuestionReplies(item);
}

List<QuestionReply> _parseQuestionReplies(ToolChatItem item) {
  final questions = ToolView._decode(item.arguments)?['questions'];
  final answers = ToolView._decode(item.resultText)?['answers'];
  if (questions is! List || answers is! List || answers.isEmpty) return const [];
  final labels = <String, String>{};
  for (final question in questions) {
    if (question is! Map) return const [];
    final id = question['id'];
    final text = question['question'];
    if (id is! String || id.isEmpty || text is! String || text.trim().isEmpty || labels.containsKey(id)) {
      return const [];
    }
    final header = question['header'];
    labels[id] = header is String && header.trim().isNotEmpty ? header : text;
  }
  final replies = <QuestionReply>[];
  final seen = <String>{};
  for (final answer in answers) {
    if (answer is! Map) return const [];
    final id = answer['id'];
    final selected = answer['selected'];
    final custom = answer['custom'];
    if (id is! String ||
        !labels.containsKey(id) ||
        !seen.add(id) ||
        selected is! List ||
        selected.any((value) => value is! String || value.trim().isEmpty) ||
        (custom != null && custom is! String)) {
      return const [];
    }
    final text = [...selected.cast<String>(), if (custom is String && custom.trim().isNotEmpty) custom].join('\n');
    if (text.isEmpty) return const [];
    replies.add((id: id, question: labels[id]!, answer: text));
  }
  return List.unmodifiable(replies);
}

/// 这次调用带了一张画得出来的原生卡片(插件卡片、媒体卡或提问回执)。
bool hasToolCard(ToolChatItem item) =>
    toolCardParse(item) is DshUiParsed || toolMedia(item) != null || toolQuestionReplies(item).isNotEmpty;

/// 带原生卡片的工具调用,卡片画在哪(`ToolCallRow.card`)。
enum ToolCardPlacement {
  /// 工具行里:卡片默认展开,参数和结果收在卡片下的「详情」里。
  inline,

  /// 一轮折叠后留在消息流里的卡片本身(没有工具行)。
  cardOnly,

  /// 折进过程里的那一行:卡片已经在外面了,这里只是普通的工具行。
  rowOnly,
}

/// 本机没有沙箱后端时,DSH 默认 `workspace-write` 预设下第一次 bash 会被拒,
/// 模型随后带 `danger-full-access` 重试并触发审批。这次失败不是用户的错,
/// 工具行要把它显示成中性的"需要授权",而不是红色错误。
const _sandboxUnavailableMarker = 'no sandbox backend is usable';

/// 一次工具调用的展示视图:动词、摘要、命令、diff、read 窗口……
///
/// 全部从 [ToolChatItem] 现算,但 diff(LCS)不便宜,所以惰性 + 由工具行的
/// State 按输入身份复用([matches])。
class ToolView {
  ToolView._(this.item) : args = _decode(item.arguments);

  factory ToolView.of(ToolChatItem item, [ToolView? previous]) =>
      previous != null && previous.matches(item) ? previous : ToolView._(item);

  final ToolChatItem item;
  final _locale = AppLocale.current;

  /// 解析后的参数;流式中(JSON 不完整)为 null。
  final Map<String, Object?>? args;

  String get name => item.name;

  /// 输入没变就复用(结果片段、meta 来自事件对象,身份稳定)。
  bool matches(ToolChatItem other) => _locale == AppLocale.current && sameInput(item, other);

  static bool sameInput(ToolChatItem item, ToolChatItem other) =>
      other.callId == item.callId &&
      other.name == item.name &&
      other.status == item.status &&
      other.arguments == item.arguments &&
      identical(other.resultParts, item.resultParts) &&
      identical(other.meta, item.meta) &&
      other.failure == item.failure &&
      other.pendingApproval?.eventId == item.pendingApproval?.eventId;

  static Map<String, Object?>? _decode(String raw) {
    // An object's JSON ends in `}`. Arguments still streaming mostly don't:
    // skip the parse that would throw on every delta.
    if (!raw.trimRight().endsWith('}')) return null;
    try {
      final value = jsonDecode(raw);
      return value is Map<String, Object?> ? value : null;
    } on FormatException {
      return null;
    }
  }

  /// 读一个字符串参数;JSON 还没流完时从半截原文里尽量抠出来。
  String? arg(String key) {
    final value = args?[key];
    if (value is String) return value;
    if (args != null) return null;
    final match = RegExp('"${RegExp.escape(key)}"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)').firstMatch(item.arguments);
    if (match == null) return null;
    return _unescape(match.group(1)!);
  }

  static String _unescape(String s) => s.replaceAllMapped(RegExp(r'\\(u[0-9a-fA-F]{4}|.)'), (m) {
    final e = m.group(1)!;
    return switch (e[0]) {
      'n' => '\n',
      't' => '\t',
      'r' => '',
      'u' when e.length == 5 => String.fromCharCode(int.parse(e.substring(1), radix: 16)),
      _ => e,
    };
  });

  bool get isTerminal => const {'bash', 'pwsh', 'job_output'}.contains(name);

  bool get isActive => switch (item.status) {
    ToolStatus.streaming || ToolStatus.running || ToolStatus.awaitingApproval => true,
    _ => false,
  };

  /// 第一次 bash 撞上"没有可用沙箱"的拒绝(见 [_sandboxUnavailableMarker])。
  late final bool sandboxBlocked =
      item.status == ToolStatus.failed &&
      ((item.resultText.contains(_sandboxUnavailableMarker)) ||
          (item.failure?.reason?.contains(_sandboxUnavailableMarker) ?? false));

  /// 工具行的动词("运行"、"读取"……)。
  String get verb {
    if (name == 'str_replace_editor') {
      return switch (arg('command')) {
        'view' => appL10n.activityToolRead,
        'create' => appL10n.activityToolWrite,
        _ => appL10n.commonEdit,
      };
    }
    if (name.isEmpty) return appL10n.activityToolCall;
    return ToolGlyphs.labelFor(name);
  }

  /// read / write / edit / str_replace_editor:详情里只列路径,不摊开参数。
  bool get isFileTool => const {'read', 'write', 'edit', 'str_replace_editor', 'read_image'}.contains(name);

  /// 文件类工具的路径。
  String? get path => arg('file_path') ?? arg('path');

  /// bash / pwsh 的完整命令。
  String? get command => isTerminal ? arg('command') : null;

  /// 摘要是不是命令 / 路径 / 模式(用等宽)。
  bool get summaryIsCode => switch (name) {
    'bash' ||
    'pwsh' ||
    'read' ||
    'write' ||
    'edit' ||
    'str_replace_editor' ||
    'read_image' ||
    'grep' ||
    'glob' ||
    'job_output' ||
    'job_kill' => true,
    _ => false,
  };

  /// 一行摘要(行内显示时由 Text 自己省略)。
  String get summary => _summary();

  /// 插件工具的原生卡片,见 [toolCardParse]。
  /// Read through the parse cache each time: it starts over when the
  /// person's palette changes (a card that asked for `accent: "app"`).
  DshUiParse? get pluginView => toolCardParse(item);

  /// 生成的媒体,见 [toolMedia]。
  late final MediaMeta? media = toolMedia(item);

  late final List<QuestionReply> questionReplies = toolQuestionReplies(item);

  /// 原生卡片的标题:折叠行的摘要用它(卡片画不了或没写标题时为 null)。
  String? get pluginTitle => switch (pluginView) {
    DshUiParsed(:final view) => view.title,
    _ => null,
  };

  String _summary() {
    String oneLine(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');
    switch (name) {
      case 'bash' || 'pwsh':
        return oneLine(arg('command') ?? arg('description') ?? '');
      // present: `files: [{path, description?}]` (the declared deliverables).
      case 'present' when args?['files'] is List:
        return [
          for (final file in args!['files'] as List)
            if (file is Map && file['path'] is String) (file['path'] as String).split('/').last,
        ].join(appL10n.activityToolListSeparator);
      case 'read' || 'write' || 'edit' || 'read_image' || 'str_replace_editor' || 'present':
        final p = path;
        return p == null ? '' : displayPath(p);
      case 'grep':
        final pattern = arg('pattern') ?? '';
        final where = arg('path');
        return where == null || where.isEmpty ? pattern : '$pattern · ${displayPath(where)}';
      case 'glob':
        return arg('pattern') ?? '';
      case 'web_fetch':
        return (arg('url') ?? '').replaceFirst(RegExp(r'^https?://'), '');
      case 'web_search':
        return arg('query') ?? '';
      case 'todo_write':
        final todos = args?['todos'];
        return todos is List ? appL10n.commonItemCount(todos.length) : '';
      case 'job_output' || 'job_kill':
        return arg('job_id') ?? arg('id') ?? '';
      case 'ask_user_question':
        final questions = args?['questions'];
        if (questions is List && questions.isNotEmpty) {
          final first = questions.first;
          if (first is Map && first['question'] is String) {
            return oneLine(first['question'] as String);
          }
        }
        return '';
      case 'subagent' || 'send_message' || 'workflow' || 'ralph':
        return oneLine(arg('description') ?? arg('prompt') ?? '');
      case 'skill':
        return arg('name') ?? arg('skill') ?? '';
    }
    for (final key in const [
      'command',
      'file_path',
      'path',
      'pattern',
      'query',
      'url',
      'description',
      'prompt',
      'name',
    ]) {
      final value = arg(key);
      if (value != null && value.trim().isNotEmpty) return oneLine(value);
    }
    final map = args;
    if (map != null) {
      for (final value in map.values) {
        if (value is String && value.trim().isNotEmpty) return oneLine(value);
      }
    }
    return '';
  }

  /// 参数的可读形式(展开区"参数"一栏)。
  late final String prettyArguments = _pretty();

  String _pretty() {
    final map = args;
    if (map == null) return item.arguments;
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  /// Durable image blocks are authoritative; never guess images from result text.
  late final List<ImageAttachment> images = item.status == ToolStatus.succeeded
      ? item.resultParts.whereType<ImagePart>().map((part) => part.attachment).toList(growable: false)
      : const [];

  /// Legacy path-only image reads use the Host file API, not the phone filesystem.
  String? get imagePath {
    if (item.status != ToolStatus.succeeded || images.isNotEmpty || name != 'read_image') return null;
    final meta = item.meta;
    return meta is Map && meta['path'] is String ? meta['path'] as String : path;
  }

  bool get hasImages => images.isNotEmpty || imagePath != null;

  /// 结果文本(原样,含 ANSI)。
  String get resultText => item.resultText;

  /// 失败原因(结果文本优先,其次 failure.reason)。
  String? get failureText {
    if (item.status != ToolStatus.failed) return null;
    final text = item.resultText.trim();
    if (text.isNotEmpty) return text;
    return item.failure?.reason ?? item.failure?.code;
  }

  // ---------------------------------------------------------------------------
  // 结构化结果:edit / write 的 diff、read 的行号窗口

  /// edit / write / str_replace_editor 的行级 diff;没有可用信息时为 null。
  late final List<DiffLine>? diff = _diff();

  /// 这次修改的各处 old → new 文本块(按文件顺序):优先结果 meta 里 DSH
  /// 算好的 hunk(带 3 行上下文),其次参数里的 old/new。null = 不是这类修改。
  late final List<({String? oldText, String newText})>? changeBlocks = _changeBlocks();

  List<({String? oldText, String newText})>? _changeBlocks() {
    final fromMeta = _diffsFromMeta(item.meta);
    if (fromMeta != null) return fromMeta;
    if (name == 'edit') {
      final from = arg('old_string');
      final to = arg('new_string');
      if (from != null && to != null) return [(oldText: from, newText: to)];
    }
    if (name == 'str_replace_editor' && arg('command') == 'str_replace') {
      final from = arg('old_str');
      final to = arg('new_str');
      if (from != null && to != null) return [(oldText: from, newText: to)];
    }
    return null;
  }

  /// [changeBlocks] 每一块的行级 diff,只算一次(详情和本轮改动共用)。
  /// 纯插入时 DSH 写的 `oldText` 是 null。
  late final List<List<DiffLine>>? blockDiffs = changeBlocks == null
      ? null
      : [for (final block in changeBlocks!) computeLineDiff(block.oldText ?? '', block.newText)];

  List<DiffLine>? _diff() {
    final blocks = blockDiffs;
    if (blocks != null && blocks.isNotEmpty) return _merge(blocks);
    if (looksLikeUnifiedDiff(item.resultText)) {
      return parseUnifiedDiff(item.resultText);
    }
    return null;
  }

  static List<DiffLine> _merge(List<List<DiffLine>> blocks) {
    if (blocks.length == 1) return blocks.single;
    return [
      for (var i = 0; i < blocks.length; i++) ...[
        DiffLine(DiffLineKind.hunk, appL10n.activityDiffBlockMarker(i + 1, blocks.length)),
        ...blocks[i],
      ],
    ];
  }

  static List<({String? oldText, String newText})>? _diffsFromMeta(Object? meta) {
    if (meta is! Map) return null;
    final diffs = meta['diffs'];
    if (diffs is! List || diffs.isEmpty) return null;
    final out = <({String? oldText, String newText})>[];
    for (final d in diffs) {
      if (d is! Map) continue;
      final newText = d['newText'];
      if (newText is! String) continue;
      final oldText = d['oldText'];
      out.add((oldText: oldText is String ? oldText : null, newText: newText));
    }
    return out.isEmpty ? null : out;
  }

  /// 新写入文件的内容(write 新建,或 str_replace_editor create)。
  String? get writtenContent {
    if (name == 'write') return arg('content');
    if (name == 'str_replace_editor' && arg('command') == 'create') {
      return arg('file_text');
    }
    return null;
  }

  late final ({int added, int removed})? diffCounts = _counts();

  ({int added, int removed})? _counts() {
    if (item.status != ToolStatus.succeeded) return null;
    final lines = diff;
    if (lines != null) return diffStats(lines);
    final content = writtenContent;
    if (content != null && content.isNotEmpty) {
      return (added: '\n'.allMatches(content.trimRight()).length + 1, removed: 0);
    }
    return null;
  }

  /// read 的行号窗口:优先 meta,退回解析结果文本里的 `N: text` 行。
  late final ({String code, int firstLine, String? language})? readWindow = _read();

  ({String code, int firstLine, String? language})? _read() {
    if (name != 'read' || item.status != ToolStatus.succeeded) return null;
    final meta = item.meta;
    final p = path;
    String? language = p == null ? null : languageForPath(p);
    if (meta is Map && meta['lines'] is List) {
      final lines = <String>[];
      int? first;
      for (final line in meta['lines'] as List) {
        if (line is! Map) continue;
        final number = line['number'];
        final text = line['text'];
        if (number is! int || text is! String) continue;
        first ??= number;
        lines.add(text);
      }
      if (meta['lang'] is String) language ??= meta['lang'] as String;
      if (first != null) {
        return (code: lines.join('\n'), firstLine: first, language: language);
      }
    }
    final numbered = RegExp(r'^(\d+): ?(.*)$');
    final lines = <String>[];
    int? first;
    for (final raw in item.resultText.split('\n')) {
      final m = numbered.firstMatch(raw);
      if (m == null) {
        if (first != null) break;
        continue;
      }
      first ??= int.parse(m.group(1)!);
      lines.add(m.group(2)!);
    }
    if (first == null) return null;
    return (code: lines.join('\n'), firstLine: first, language: language);
  }
}

/// 工作区内的路径去掉工作区前缀,其余原样。
String displayPath(String path) {
  final prefix = '$localWorkspaceDir/';
  if (path.startsWith(prefix)) return path.substring(prefix.length);
  if (path == localWorkspaceDir) return '.';
  return path;
}
