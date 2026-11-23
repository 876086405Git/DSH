// Tool-group summaries, per-turn change detection and their place in the
// chat rows, over captured DSH frames (packages/dsh_client/test/fixtures)
// and a synthetic file-editing session in the same wire shape
// (test/chat/fixtures/follow_file_changes.jsonl).

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_rows.dart';
import 'package:dsh_app/ui/chat/render/diff_view.dart';
import 'package:dsh_app/ui/chat/turn_summary.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sample_chat.dart';

const _clientFixtures = '../packages/dsh_client/test/fixtures';

ChatTranscript _load(String path) {
  final transcript = ChatTranscript();
  for (final line in File(path).readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    transcript.apply(parseFollowFrame('s', jsonDecode(line)));
  }
  return transcript;
}

List<ToolChatItem> _tools(ChatTranscript t) => t.items.whereType<ToolChatItem>().toList();

void main() {
  test('file changes reuse semantic inputs and ignore live drafts', () {
    final a = tool('cache-a', 'edit', {'file_path': 'a', 'old_string': 'a', 'new_string': 'b'});
    final b = tool('cache-b', 'edit', {'file_path': 'a', 'old_string': 'b', 'new_string': 'c'});
    ToolChatItem rebuild(ToolChatItem t) => ToolChatItem(
      callId: t.callId,
      name: t.name,
      arguments: t.arguments,
      status: t.status,
      resultParts: t.resultParts,
      meta: t.meta,
    );
    final first = fileChangesOf([a]);
    final all = fileChangesOf([a, b]);
    expect(all.single.lastCallId, 'cache-b');
    expect(fileChangesOf([rebuild(a), rebuild(b)]), same(all));
    expect(fileChangesOf([a, b, tool('draft', 'edit', {}, status: ToolStatus.streaming)]), same(all));
    expect(fileChangesOf([rebuild(a)]), same(first));
    expect(fileChangesOf([a, b]), same(all));
  });

  test('a conversation forgets only its own calls', () {
    ToolChatItem edit(String id) => tool(id, 'edit', {'file_path': 'f', 'old_string': id, 'new_string': '$id!'});
    final mine = [edit('forget-a'), edit('forget-b')];
    final other = [edit('keep-a')];
    fileChangesOf(mine);
    fileChangesOf(other);
    final before = debugToolSummaryCaches;
    forgetToolSummaries({for (final t in mine) t.callId});
    final after = debugToolSummaryCaches;
    expect(after.views, before.views - 2);
    expect(after.turns, before.turns - 1);
    // The other conversation's turn is still cached.
    expect(fileChangesOf(other), same(fileChangesOf(other)));
    forgetToolSummaries(const {});
    expect(debugToolSummaryCaches, after);
  });

  test('whole-session changes keep only the latest result, outside the turn cache', () {
    ToolChatItem edit(String id) => tool(id, 'edit', {'file_path': 'f', 'old_string': id, 'new_string': '$id!'});
    final a = edit('session-a');
    final b = edit('session-b');
    final before = debugToolSummaryCaches.turns;
    final first = sessionChangesOf([a]);
    expect(sessionChangesOf([a]), same(first));
    final both = sessionChangesOf([a, b]);
    expect(both.single.lastCallId, 'session-b');
    expect(sessionChangesOf([a]), isNot(same(first)));
    expect(debugToolSummaryCaches.turns, before);
    final latest = sessionChangesOf([a, b]);
    expect(sessionChangesOf([a, b]), same(latest));
    forgetToolSummaries({b.callId});
    expect(sessionChangesOf([a, b]), isNot(same(latest)));
    forgetToolSummaries({a.callId, b.callId});
  });

  group('captured DSH turns', () {
    test('approval turn: one command, no file changes', () {
      final t = _load('$_clientFixtures/follow_approval_with_resync.jsonl');
      final tools = _tools(t);
      expect(tools, hasLength(1));
      final summary = summarizeTools(tools);
      expect(summary.commands, 1);
      expect(summary.failed, 0);
      expect(summary.label, '执行 1 条命令');
      expect(fileChangesOf(tools), isEmpty);
      expect(turnChanges(t.items), isEmpty);
    });

    test('a turn without tools has nothing to summarise', () {
      final t = _load('$_clientFixtures/follow_reply_ok.jsonl');
      expect(_tools(t), isEmpty);
      expect(turnChanges(t.items), isEmpty);
      expect(summarizeTools(const []).label, '使用了 0 个工具');
    });
  });

  group('file-editing session', () {
    late ChatTranscript t;
    setUp(() => t = _load('test/chat/fixtures/follow_file_changes.jsonl'));

    test('summary of the six-call group', () {
      final turnOne = _tools(t).take(6).toList();
      final summary = summarizeTools(turnOne);
      expect(summary.total, 6);
      expect(summary.commands, 1);
      expect(summary.editedFiles, 2, reason: 'two edits of one file + README');
      expect(summary.readFiles, 1);
      expect(summary.searches, 1);
      expect(summary.label, '执行 1 条命令 · 改了 2 个文件 · 读了 1 个文件 · 搜索 1 次');
    });

    test('changes per turn: create, merged edits, update; failures skipped', () {
      final turns = turnChanges(t.items);
      expect(turns, hasLength(2));

      final first = turns[0].files;
      expect(first.map((f) => f.shownPath), ['README.md', 'app/lib/auth/login_controller.dart']);
      final readme = first[0];
      expect(readme.created, isTrue);
      expect((readme.added, readme.removed), (7, 0));
      expect(readme.lines.every((l) => l.kind == DiffLineKind.add), isTrue);

      final login = first[1];
      expect(login.created, isFalse);
      expect(login.edits, 2);
      expect((login.added, login.removed), (8, 3));
      expect(login.fileName, 'login_controller.dart');
      expect(login.directory, 'app/lib/auth');
      expect(login.path, '/root/workspace/app/lib/auth/login_controller.dart');
      expect(
        login.lines.where((l) => l.kind == DiffLineKind.hunk).length,
        2,
        reason: 'one header per edit when a file changes twice',
      );
      expect((turns[0].added, turns[0].removed), (15, 3));

      final second = turns[1].files;
      expect(second, hasLength(1), reason: 'the failed CHANGELOG edit is not a change');
      expect(second.single.shownPath, 'README.md');
      expect(second.single.created, isFalse);
      expect((second.single.added, second.single.removed), (4, 0));
    });

    test('the running turn gets no card yet', () {
      final items = t.items;
      final lastUser = items.lastIndexWhere((i) => i is UserChatItem);
      final cut = items.sublist(0, lastUser + 2); // user + first tool of turn 2
      expect(turnChanges(cut, running: true), hasLength(1));
      expect(turnChanges(cut), hasLength(2));
    });

    test('command/run + command/done fold into one notice', () {
      final log = CommandLog();
      t.events.forEach(log.apply);
      final notice = log.view.single;
      expect(notice.name, 'compact');
      expect(notice.seq, 21);
      expect(notice.done, isTrue);
      expect(notice.success, isTrue);
      expect(notice.text, 'Compacted 9 earlier messages.');
      expect(notice.line, '/compact');
      expect(identical(log.view, log.view), isTrue, reason: 'memoised');

      log['local-0'] = const CommandNotice(id: 'local-0', name: 'plan');
      expect(log.view.map((c) => c.id), ['cmd-1', 'local-0']);
    });

    test('rows: group, change card after the turn, command in seq order', () {
      final log = CommandLog();
      t.events.forEach(log.apply);
      final rows = deriveRows(items: t.items, commands: log.view);
      String kind(ChatRow r) => switch (r) {
        UserRow() => 'user',
        AssistantRow() => 'assistant',
        ToolGroupRow(:final tools) => 'group${tools.length}',
        ToolCallRow() => 'tool',
        ChangeCardRow(:final files) => 'changes${files.length}',
        CommandNoticeRow(:final notice) => '/${notice.name}',
        _ => r.runtimeType.toString(),
      };
      expect(rows.map(kind).toList(), [
        'user',
        'assistant',
        'group6',
        'assistant',
        'changes2',
        '/compact',
        'user',
        'tool',
        'tool',
        'assistant',
        'changes1',
      ]);
      final last = rows.whereType<AssistantRow>().toList();
      expect(last[1].showActions, isTrue);
      expect(rows.whereType<ChangeCardRow>().first.key, 'chgc-write');
    });

    test('a group that is still running keeps its card for later', () {
      final items = t.items.sublist(0, 9); // turn 1 up to the tool calls
      final rows = deriveRows(items: items, running: true);
      expect(rows.whereType<ChangeCardRow>(), isEmpty);
    });
  });

  group('edge cases', () {
    test('整文件新增保留 CRLF、末尾空行和重复读取的行文本', () {
      final write = tool(
        'whole-write-eol',
        'write',
        {'file_path': 'f', 'content': 'a\r\n\nb\n\n'},
        meta: {'operation': 'create'},
      );
      final file = fileChangesOf([write]).single;
      expect((file.added, file.removed), (4, 0));
      expect(file.lines.map((line) => line.text), ['+a\r', '+', '+b', '+']);
      expect(file.lines.first.text, same(file.lines.first.text));
      const patch = '--- /dev/null\n+++ b/f\n@@ -0,0 +1,4 @@\n+a\r\n+\n+b\n+\n';
      expect(file.patch, patch);
      expect(file.patch, patch);
    });

    test('failed, denied and streaming edits are not changes', () {
      final tools = [
        tool('a', 'edit', {
          'file_path': '/root/workspace/a.txt',
          'old_string': 'x',
          'new_string': 'y',
        }, status: ToolStatus.failed),
        tool('b', 'write', {'file_path': '/root/workspace/b.txt', 'content': 'b'}, status: ToolStatus.denied),
        tool('c', 'write', {'file_path': '/root/workspace/c.txt'}, status: ToolStatus.streaming),
      ];
      expect(fileChangesOf(tools), isEmpty);
      final summary = summarizeTools(tools);
      expect(summary.editedFiles, 1, reason: 'only the one still streaming');
      expect(summary.failed, 1);
      expect(summary.label, '改了 1 个文件');
    });

    test('str_replace_editor: view reads, create and insert change', () {
      final tools = [
        tool('v', 'str_replace_editor', {'command': 'view', 'path': '/root/workspace/x.py'}),
        tool('n', 'str_replace_editor', {
          'command': 'create',
          'path': '/root/workspace/new.py',
          'file_text': 'print(1)\nprint(2)\n',
        }),
        tool('i', 'str_replace_editor', {
          'command': 'insert',
          'path': '/root/workspace/x.py',
          'insert_line': 3,
          'new_str': 'import os',
        }),
      ];
      final summary = summarizeTools(tools);
      expect(summary.readFiles, 1);
      expect(summary.editedFiles, 2);
      final changes = fileChangesOf(tools);
      expect(changes.map((c) => (c.shownPath, c.created, c.added)), [('new.py', true, 2), ('x.py', false, 1)]);
    });

    test('sandbox refusal is not counted as a separate command', () {
      final tools = [
        tool('s', 'bash', {'command': 'ls'}, status: ToolStatus.failed, result: sandboxRefusal),
        tool('r', 'bash', {'command': 'ls'}),
        tool('g', 'glob', {'pattern': '*.dart'}),
        tool('w', 'web_search', {'query': 'flutter'}),
        tool('t', 'todo_write', {'todos': []}),
        tool('k', 'skill', {'name': 'x'}),
      ];
      final summary = summarizeTools(tools);
      expect(summary.commands, 1);
      expect(summary.failed, 0);
      expect(summary.label, '执行 1 条命令 · 搜索 1 次 · 联网 1 次 · 更新了待办 · 其他工具 1 次');
    });
  });
}
