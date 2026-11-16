// Tool-group summaries and per-turn file changes.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../l10n/l10n.dart';
import 'render/diff_view.dart';
import 'tool_view.dart';

/// 工具在摘要里归到哪一类。
enum ToolKind { command, edit, read, search, web, agent, todo, other }

ToolKind toolKindOf(ToolChatItem tool) {
  switch (tool.name) {
    case 'bash' || 'pwsh':
      return ToolKind.command;
    case 'write' || 'edit':
      return ToolKind.edit;
    case 'str_replace_editor':
      return _cachedView(tool).arg('command') == 'view' ? ToolKind.read : ToolKind.edit;
    case 'read' || 'read_image':
      return ToolKind.read;
    case 'grep' || 'glob':
      return ToolKind.search;
    case 'web_fetch' || 'web_search':
      return ToolKind.web;
    case 'subagent' || 'subagent_fork' || 'send_message' || 'interrupt_agent' || 'workflow' || 'ralph':
      return ToolKind.agent;
    case 'todo_write':
      return ToolKind.todo;
    default:
      return ToolKind.other;
  }
}

/// 一组连续工具调用的计数(文件按路径去重)。
class ToolSummary {
  const ToolSummary({
    this.commands = 0,
    this.editedFiles = 0,
    this.readFiles = 0,
    this.searches = 0,
    this.web = 0,
    this.agents = 0,
    this.todos = 0,
    this.other = 0,
    this.failed = 0,
    this.total = 0,
  });

  final int commands;
  final int editedFiles;
  final int readFiles;
  final int searches;
  final int web;
  final int agents;
  final int todos;
  final int other;

  /// 真失败的调用(不含 Android 上"没有沙箱"的第一次拒绝)。
  final int failed;
  final int total;

  /// "执行 3 条命令 · 改了 2 个文件 · 读了 4 个文件"(失败数不在这里)。
  List<String> get segments => [
    if (commands > 0) appL10n.activitySummaryCommands(commands),
    if (editedFiles > 0) appL10n.activitySummaryEditedFiles(editedFiles),
    if (readFiles > 0) appL10n.activitySummaryReadFiles(readFiles),
    if (searches > 0) appL10n.activitySummarySearches(searches),
    if (web > 0) appL10n.activitySummaryWeb(web),
    if (agents > 0) appL10n.activitySummarySubagents(agents),
    if (todos > 0) appL10n.activitySummaryTodo,
    if (other > 0) appL10n.activitySummaryOther(other),
  ];

  String get label {
    final parts = segments;
    return parts.isEmpty ? appL10n.activitySummaryTotal(total) : parts.join(' · ');
  }
}

/// 把一组工具调用数成 [ToolSummary]。
///
/// - 文件类按路径去重(同一文件读三次算"读了 1 个文件");路径还没流完的按调用算;
///   失败 / 被拒 / 被取消的文件调用不算"改了""读了";
/// - 被沙箱拦下、随后带授权重试的那次 bash 不计(它和重试是同一条命令);
/// - 流式中 / 运行中的调用照常计入:摘要描述的是"这一组在做什么"。
ToolSummary summarizeTools(Iterable<ToolChatItem> tools) {
  var commands = 0, searches = 0, web = 0, agents = 0, todos = 0, other = 0;
  var failed = 0, total = 0;
  final edited = <String>{};
  final read = <String>{};
  for (final tool in tools) {
    total++;
    final view = _cachedView(tool);
    if (view.sandboxBlocked) continue;
    if (tool.status == ToolStatus.failed && (view.phoneResult?.isFault ?? true)) failed++;
    final fileKey = _normalisePath(view.path) ?? '#${tool.callId}';
    // "改了 / 读了" claim it happened: a failed, refused or abandoned file
    // call shows up in the failure count (or nowhere), not as a file.
    final happened = switch (tool.status) {
      ToolStatus.failed || ToolStatus.denied || ToolStatus.cancelled => false,
      _ => true,
    };
    switch (toolKindOf(tool)) {
      case ToolKind.command:
        commands++;
      case ToolKind.edit:
        if (happened) edited.add(fileKey);
      case ToolKind.read:
        if (happened) read.add(fileKey);
      case ToolKind.search:
        searches++;
      case ToolKind.web:
        web++;
      case ToolKind.agent:
        agents++;
      case ToolKind.todo:
        todos++;
      case ToolKind.other:
        other++;
    }
  }
  return ToolSummary(
    commands: commands,
    editedFiles: edited.length,
    readFiles: read.length,
    searches: searches,
    web: web,
    agents: agents,
    todos: todos,
    other: other,
    failed: failed,
    total: total,
  );
}

// -----------------------------------------------------------------------------
// 改动卡

/// 一处改动:增删 / 上下文行,和它在文件里的起始行号(知道时)。
///
/// DSH 的 diff meta 不带行号,所以行号要靠同一轮里更早的 `read` 窗口或整
/// 文件写入对位:旧文本在已知内容里**唯一**出现才算数,对不上就不编号。
class DiffHunk {
  const DiffHunk({required this.lines, required this.edit, this.oldStart, this.newStart});

  /// 只有 add / del / context。
  final List<DiffLine> lines;

  /// 第几次修改(从 1 起),同一次修改的多处共享。
  final int edit;

  /// 旧文件里的起始行;null = 不知道(或纯新增)。
  final int? oldStart;

  /// 新文件里的起始行;null = 不知道。
  final int? newStart;

  bool get numbered => newStart != null;

  int get oldCount => lines.where((l) => l.kind != DiffLineKind.add).length;
  int get newCount => lines.where((l) => l.kind != DiffLineKind.del).length;
}

/// 一轮里被改过的一个文件:多次修改合并成一份 diff。
class FileChange {
  const FileChange({
    required this.path,
    required this.created,
    required this.added,
    required this.removed,
    required this.lines,
    required this.edits,
    this.hunks = const [],
    this.lastCallId,
  });

  /// 工具参数里的原始路径(复制路径用它)。
  final String path;

  /// 本轮第一次碰它时是新建(write create / str_replace_editor create)。
  final bool created;
  final int added;
  final int removed;

  /// 合并后的行级 diff;多次修改之间插一行 hunk 标题。
  final List<DiffLine> lines;

  /// 成功修改的次数。
  final int edits;

  /// 同一份改动按处拆开(带行号时可以画行号栏、拼补丁)。
  final List<DiffHunk> hunks;

  /// 最后一次改它的工具调用(按它找出是哪一轮改的)。
  final String? lastCallId;

  /// 统一 diff 格式的补丁(复制用)。不知道行号的那几处按第 1 行写,
  /// `patch` 会按上下文找位置。
  String get patch {
    final shown = shownPath;
    final out = StringBuffer()
      ..writeln(created ? '--- /dev/null' : '--- a/$shown')
      ..writeln('+++ b/$shown');
    for (final hunk in hunks) {
      final oldCount = hunk.oldCount;
      final newCount = hunk.newCount;
      final oldStart = oldCount == 0 ? 0 : (hunk.oldStart ?? 1);
      final newStart = newCount == 0 ? 0 : (hunk.newStart ?? 1);
      out.writeln('@@ -$oldStart,$oldCount +$newStart,$newCount @@');
      for (final line in hunk.lines) {
        out.writeln(line.text.isEmpty ? ' ' : line.text);
      }
    }
    return out.toString();
  }

  /// 工作区内去掉 `/root/workspace/` 前缀。
  String get shownPath => displayPath(path);

  String get fileName {
    final shown = shownPath;
    final slash = shown.lastIndexOf('/');
    return slash < 0 ? shown : shown.substring(slash + 1);
  }

  /// 所在目录(工作区根下的文件为空串)。
  String get directory {
    final shown = shownPath;
    final slash = shown.lastIndexOf('/');
    return slash <= 0 ? '' : shown.substring(0, slash);
  }
}

/// 一轮(两条用户消息之间)的改动。
class TurnChanges {
  const TurnChanges({required this.afterKey, required this.files});

  /// 这一轮最后一条 transcript 项的 key:改动卡接在它后面。
  final String afterKey;
  final List<FileChange> files;

  int get added => files.fold(0, (sum, f) => sum + f.added);
  int get removed => files.fold(0, (sum, f) => sum + f.removed);
}

/// 一组工具调用改了哪些文件,按第一次修改的顺序。
///
/// 只算**成功**的 write / edit / str_replace_editor(create、str_replace、insert);
/// diff 优先用结果 meta 里 DSH 算好的 hunk(`meta.diffs`),其次用参数里的
/// old/new 文本,新建文件按全文计为新增。bash 里的 `sed -i`、重定向等写文件
/// 的方式看不出来,不在此列。
List<FileChange> fileChangesOf(Iterable<ToolChatItem> tools) {
  final list = tools.where((tool) => tool.status == ToolStatus.succeeded).toList();
  if (list.isEmpty) return const [];
  // The chat list re-derives its rows every streaming frame and the
  // transcript rebuilds its items on every event; finished calls keep the
  // same inputs, so compare those, not the item objects.
  final key =
      '${AppLocale.current.languageCode}|'
      '${list.first.callId}|${list.last.callId}|${list.length}';
  final hit = _changeCache[key];
  if (hit != null && _sameTools(hit.tools, list)) return hit.changes;
  final changes = _computeChanges(list);
  _changeCache.remove(key);
  _changeCache[key] = (tools: List.of(list), changes: changes);
  if (_changeCache.length > _maxCachedTurns) {
    _changeCache.remove(_changeCache.keys.first);
  }
  return changes;
}

final _changeCache = <String, ({List<ToolChatItem> tools, List<FileChange> changes})>{};
const _maxCachedTurns = 200;

bool _sameTools(List<ToolChatItem> a, List<ToolChatItem> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!ToolView.sameInput(a[i], b[i])) return false;
  }
  return true;
}

List<FileChange> _computeChanges(List<ToolChatItem> tools) {
  final byPath = <String, _FileAccumulator>{};
  // What the turn has seen of each file (read windows, whole writes), kept
  // in step with its own edits, to give hunks real line numbers.
  final known = <String, _KnownLines>{};
  for (final tool in tools) {
    if (tool.status != ToolStatus.succeeded) continue;
    final kind = toolKindOf(tool);
    if (kind == ToolKind.command) {
      // A shell command may have rewritten anything.
      known.clear();
      continue;
    }
    final view = _cachedView(tool);
    final path = _normalisePath(view.path);
    if (path == null) continue;
    if (kind == ToolKind.read) {
      if (view.readWindow case final window?) {
        known[path] = _KnownLines(window.firstLine, window.code.split('\n'));
      }
      continue;
    }
    if (kind != ToolKind.edit) continue;
    final change = _changeOf(view, known[path]);
    final after = view.writtenContent;
    if (after != null) {
      known[path] = _KnownLines(1, _contentLines(after));
    } else if (change != null && !change.tracked) {
      known.remove(path);
    }
    if (change == null) continue;
    byPath
        .putIfAbsent(path, () => _FileAccumulator(view.path!, created: change.created))
        .add(change.hunks, tool.callId);
  }
  return [for (final acc in byPath.values) acc.build()];
}

List<String> _contentLines(String text) {
  final body = text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
  return body.split('\n');
}

/// 已知的一段连续文件内容(从 [start] 行起)。
class _KnownLines {
  _KnownLines(this.start, this.lines);
  final int start;
  final List<String> lines;

  /// [needle] 在已知内容里(从 [from] 起)唯一出现的下标;否则 null。
  int? find(List<String> needle, {int from = 0}) {
    if (needle.isEmpty || needle.length > lines.length) return null;
    int? found;
    for (var i = from; i + needle.length <= lines.length; i++) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (lines[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (!match) continue;
      if (found != null) return null;
      found = i;
    }
    return found;
  }
}

/// 按用户消息切轮,返回每一轮的改动(没有改动的轮不返回)。
///
/// [running] 时最后一轮还没结束,不出卡片。
List<TurnChanges> turnChanges(List<ChatItem> items, {bool running = false}) {
  final out = <TurnChanges>[];
  var tools = <ToolChatItem>[];
  String? lastKey;

  void close() {
    final key = lastKey;
    if (key != null && tools.isNotEmpty) {
      final files = fileChangesOf(tools);
      if (files.isNotEmpty) out.add(TurnChanges(afterKey: key, files: files));
    }
    tools = <ToolChatItem>[];
    lastKey = null;
  }

  for (final item in items) {
    if (item is UserChatItem) close();
    if (item is ToolChatItem) tools.add(item);
    lastKey = item.key;
  }
  if (!running) close();
  return out;
}

/// 一次修改的各处改动。[tracked] = 每一处都在已知内容里对上了位置
/// (已知内容已同步更新;否则调用方该把它作废)。
({bool created, List<DiffHunk> hunks, bool tracked})? _changeOf(ToolView view, _KnownLines? known) {
  final name = view.name;
  final command = name == 'str_replace_editor' ? view.arg('command') : null;
  final meta = view.item.meta;
  final created = (name == 'write' && meta is Map && meta['operation'] == 'create') || command == 'create';
  if (!created) {
    if (view.changeBlocks case final blocks? when blocks.isNotEmpty) {
      final hunks = <DiffHunk>[];
      var tracked = known != null;
      // Within one edit later hunks sit below earlier ones: the window is
      // updated hunk by hunk, so a match is in "after" coordinates.
      var delta = 0;
      for (final (i, block) in blocks.indexed) {
        final lines = view.blockDiffs![i];
        final oldLines = block.oldText == null ? const <String>[] : block.oldText!.split('\n');
        final at = tracked ? known!.find(oldLines) : null;
        if (at == null) {
          tracked = false;
          hunks.add(DiffHunk(lines: lines, edit: 0));
          continue;
        }
        final newLines = block.newText.split('\n');
        known!.lines.replaceRange(at, at + oldLines.length, newLines);
        final newStart = known.start + at;
        hunks.add(DiffHunk(lines: lines, edit: 0, oldStart: newStart - delta, newStart: newStart));
        delta += newLines.length - oldLines.length;
      }
      // A whole-file write states the result: place each hunk's new text in
      // it (in file order), and the old side follows from the hunks above.
      final after = view.writtenContent;
      if (!tracked && after != null) {
        final known = _KnownLines(1, _contentLines(after));
        var from = 0;
        var shift = 0;
        final placed = <DiffHunk>[];
        for (final (i, block) in blocks.indexed) {
          final newLines = block.newText.split('\n');
          final oldLength = block.oldText == null ? 0 : block.oldText!.split('\n').length;
          final at = known.find(newLines, from: from);
          if (at == null) break;
          placed.add(DiffHunk(lines: hunks[i].lines, edit: 0, oldStart: at + 1 - shift, newStart: at + 1));
          from = at + newLines.length;
          shift += newLines.length - oldLength;
        }
        if (placed.length == blocks.length) {
          return (created: false, hunks: placed, tracked: false);
        }
      }
      return (created: false, hunks: hunks, tracked: tracked);
    }
    if (command == 'insert') {
      final text = view.arg('new_str');
      if (text != null) {
        final after = view.args?['insert_line'];
        final line = after is int ? after : null;
        final added = _contentLines(text);
        var tracked = false;
        if (known != null && line != null) {
          final index = line - known.start + 1;
          if (index >= 0 && index <= known.lines.length) {
            known.lines.insertAll(index, added);
            tracked = true;
          }
        }
        return (
          created: false,
          hunks: [DiffHunk(lines: _allAdded(text), edit: 0, newStart: line == null ? null : line + 1)],
          tracked: tracked,
        );
      }
    }
  }
  final content = view.writtenContent;
  if (content != null) {
    final lines = _allAdded(content);
    return (created: created, hunks: [DiffHunk(lines: lines, edit: 0, newStart: created ? 1 : null)], tracked: true);
  }
  return null;
}

List<DiffLine> _allAdded(String text) {
  if (text.isEmpty) return const [];
  final body = text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
  return [for (final line in body.split('\n')) DiffLine(DiffLineKind.add, '+$line')];
}

class _FileAccumulator {
  _FileAccumulator(this.path, {required this.created});

  final String path;
  final bool created;
  final List<List<DiffHunk>> blocks = [];

  String? lastCallId;

  void add(List<DiffHunk> hunks, String callId) {
    blocks.add(hunks);
    lastCallId = callId;
  }

  FileChange build() {
    final edits = blocks.length;
    final hunks = [
      for (final (i, block) in blocks.indexed)
        for (final hunk in block)
          DiffHunk(lines: hunk.lines, edit: i + 1, oldStart: hunk.oldStart, newStart: hunk.newStart),
    ];
    List<DiffLine> flat(List<DiffHunk> block) {
      if (block.length == 1) return block.single.lines;
      return [
        for (var i = 0; i < block.length; i++) ...[
          DiffLine(DiffLineKind.hunk, appL10n.activityDiffBlockMarker(i + 1, block.length)),
          ...block[i].lines,
        ],
      ];
    }

    final lines = edits == 1
        ? flat(blocks.single)
        : [
            for (var i = 0; i < edits; i++) ...[
              DiffLine(DiffLineKind.hunk, appL10n.activityDiffEditMarker(i + 1, edits)),
              ...flat(blocks[i]),
            ],
          ];
    final stats = diffStats(lines);
    return FileChange(
      path: path,
      created: created,
      added: stats.added,
      removed: stats.removed,
      lines: lines,
      edits: edits,
      hunks: hunks,
      lastCallId: lastCallId,
    );
  }
}

String? _normalisePath(String? path) {
  if (path == null) return null;
  var p = path.trim();
  if (p.isEmpty) return null;
  while (p.startsWith('./')) {
    p = p.substring(2);
  }
  return displayPath(p);
}

// ToolView 的 diff 是 LCS,不便宜。transcript 每来一个持久事件就会重建所有
// ToolChatItem,但结果片段 / meta / 参数都还是同一批对象,所以按 callId 缓存
// 视图,用 [ToolView.matches] 校验,diff 每次调用只算一遍。
final _views = <String, ToolView>{};
const _maxCachedViews = 600;

/// Drops what the caches here hold for [callIds]: one conversation's calls,
/// when its chat closes. They are global and keep the calls' results (and
/// diffs) alive until 600 calls / 200 turns of other chats push them out.
void forgetToolSummaries(Set<String> callIds) {
  if (callIds.isEmpty) return;
  _views.removeWhere((callId, _) => callIds.contains(callId));
  _changeCache.removeWhere((_, entry) => entry.tools.any((tool) => callIds.contains(tool.callId)));
}

/// How many calls and turns the caches here hold.
@visibleForTesting
({int views, int turns}) get debugToolSummaryCaches => (views: _views.length, turns: _changeCache.length);

ToolView _cachedView(ToolChatItem tool) {
  final previous = _views.remove(tool.callId);
  final view = ToolView.of(tool, previous);
  _views[tool.callId] = view;
  if (_views.length > _maxCachedViews) _views.remove(_views.keys.first);
  return view;
}
