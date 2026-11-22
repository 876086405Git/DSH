// Replay pacing (lib/ui/replay/replay_timeline.dart) and the frames built
// from it. The fixture test/replay/fixtures/timeline.json holds a conversation
// file and its schedule; site/share/test/viewer_test.mjs checks the web viewer
// against the same file.
//
//   flutter test test/replay/replay_timeline_test.dart
//   UPDATE_FIXTURES=1 flutter test test/replay/replay_timeline_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/share_code/conversation_export.dart';
import 'package:dsh_app/share_code/conversation_share.dart';
import 'package:dsh_app/ui/replay/replay_frame.dart';
import 'package:dsh_app/ui/replay/replay_timeline.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_app/share_code/conversation_html.dart';

import 'support/conversation_fixture.dart';
import 'support/rich_conversation.dart';

ConversationShare _share() =>
    ConversationExport(fixtureSource()).build(now: DateTime.utc(2026, 10, 25, 3), app: 'dsh-go 1.0.0');

void main() {
  test('streamed prefixes keep rune boundaries when seeking in either direction', () {
    final body = String.fromCharCodes([0xdc01, 0x41, 0x1f642, 0xd801, 0x301, 0x1f64a]);
    const thinking = '中文👩‍💻';
    final frames = ReplayFrames(
      ConversationShare(
        title: 'seek',
        start: DateTime.utc(2026),
        entries: [ReplyEntry(t: 0, text: body, thinking: thinking)],
      ),
    );
    final beat = frames.timeline.beats.single;
    for (final reason in [false, true, false]) {
      final text = reason ? thinking : body;
      final start = reason ? beat.start : beat.thinkEnd;
      final end = reason ? beat.thinkEnd : beat.end;
      final runes = text.runes.toList();
      for (var n = runes.length - 1; n >= 0; n--) {
        final time = start + (end - start) * ((n + 0.5) / runes.length);
        final item = frames.at(time).items.whereType<AssistantChatItem>().single;
        expect(reason ? item.reasoning : item.text, String.fromCharCodes(runes.take(n)));
      }
    }
  });

  test('long waits shrink, short ones stay, streams keep a reading pace', () {
    final share = _share();
    final plan = ReplayTimeline.of(share.entries);
    final beats = plan.beats;
    final types = [for (final e in share.entries) e.type];
    // turn, user, reply, tool, todos, reply, command, turn, user, tool, tool, goal, reply, notice
    expect(types.first, 'turn');
    // Starts never go backwards.
    for (var i = 1; i < beats.length; i++) {
      expect(beats[i].start, greaterThanOrEqualTo(beats[i - 1].start));
    }
    // The first reply streamed 3 s with thinking: thinking at least 0.6 s.
    final reply = beats[2];
    expect(reply.thinkEnd - reply.start, greaterThanOrEqualTo(ReplayPace.minThinking));
    // The 20 s bash run plays in at most 2.5 s.
    final bash = beats[3];
    expect(bash.end - bash.start, lessThanOrEqualTo(ReplayPace.maxTool));
    expect(bash.end - bash.start, greaterThan(ReplayPace.minTool));
    // An hour-long pause before the second prompt plays in under a second.
    final secondPrompt = types.indexOf('user', 2);
    final before = beats.sublist(0, secondPrompt).map((b) => b.end).reduce((a, b) => a > b ? a : b);
    expect(beats[secondPrompt].start - before, lessThanOrEqualTo(ReplayPace.maxGapBeforePrompt));
    // Two calls that ran side by side appear one after the other.
    final a = beats[secondPrompt + 1];
    final b = beats[secondPrompt + 2];
    expect(b.start - a.start, ReplayPace.minStagger);
    // The 41 s stream of the last reply is capped.
    final last = share.entries.lastIndexWhere((e) => e is ReplyEntry);
    expect(beats[last].end - beats[last].thinkEnd, lessThanOrEqualTo(ReplayPace.maxStream));
    // Turns close after their last part; the whole replay is short.
    expect(plan.turnEnds.keys, [0, 7]);
    expect(plan.turnEnds[0], greaterThan(beats[6].end));
    expect(plan.duration, lessThan(25000));
    expect(plan.duration, greaterThan(5000));
  });

  test('frames: replies stream, tools run, turns close and the todo list follows', () {
    final frames = ReplayFrames(_share());
    final plan = frames.timeline;
    final reply = plan.beats[2];

    final thinking = frames.at(reply.start + 10);
    final draft = thinking.items.whereType<AssistantChatItem>().single;
    expect(draft.streaming, isTrue);
    expect(draft.text, isEmpty);
    expect(thinking.running, isTrue);

    final streaming = frames.at((reply.thinkEnd + reply.end) / 2);
    final half = streaming.items.whereType<AssistantChatItem>().single;
    expect(half.text.length, greaterThan(0));
    expect(half.text.length, lessThan('我先跑一下测试。'.length));

    final bash = plan.beats[3];
    final running = frames.at(bash.start + 1).items.whereType<ToolChatItem>().single;
    expect(running.status, ToolStatus.running);
    expect(running.resultParts, isEmpty);
    final done = frames.at(bash.end).items.whereType<ToolChatItem>().single;
    expect(done.status, ToolStatus.failed);
    expect(frames.at(bash.start + 2).items.whereType<ToolChatItem>().single, same(running));
    expect(done, isNot(same(running)));
    expect(done.arguments, running.arguments);

    // The todo list appears with its write and goes when the next turn starts.
    expect(frames.at(plan.beats[4].start).todos, hasLength(2));
    expect(frames.at(plan.beats[7].start).todos, isNull);
    expect(frames.at(plan.beats[11].start).goal?.text, '登录不再重复提交');

    final end = frames.end;
    expect(end.running, isFalse);
    expect(end.turns.every((t) => t.end != null && t.endSeq != null), isTrue);
    expect(frames.at(reply.start + 10).turns.first, same(thinking.turns.first));
    expect(streaming.turns.first, same(thinking.turns.first));
    expect(end.turns.first, isNot(same(thinking.turns.first)));
    expect(end.turns.first.steps, 2);
    expect(end.turns.first.usage.total, 2400);
    expect(end.commands.single.name, 'compact');
    // Finished parts keep their identity from frame to frame.
    expect(identical(frames.end.items.first, end.items.first), isTrue);
    // A turn's end comes before the next prompt.
    final second = end.items.whereType<UserChatItem>().last;
    expect(end.turns.first.endSeq, lessThan(second.seq));
    expect(end.turns.last.startSeq, lessThan(second.seq));
  });

  test('the fixture the web viewer is checked against', () async {
    final share = _share();
    final png = Uint8List.fromList(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGPwTt/yHxkzkC4AAAPnJlH/osXzAAAAAElFTkSuQmCC',
      ),
    );
    final asset = ConversationAsset.of(png, mediaType: 'image/png', width: 4, height: 4);
    final withImage = ConversationShare(
      title: share.title,
      start: share.start,
      model: share.model,
      app: share.app,
      created: share.created,
      entries: [
        for (final e in share.entries)
          if (e is UserEntry && e.text.startsWith('帮我'))
            UserEntry(
              t: e.t,
              text: e.text,
              files: e.files,
              images: [ImageRef(id: asset.id, width: 4, height: 4)],
            )
          else
            e,
      ],
    );
    final fixture = {
      'note': 'Generated by test/replay/replay_timeline_test.dart (UPDATE_FIXTURES=1).',
      'file': encodeConversationFile(withImage, [asset]),
      'timeline': ReplayTimeline.of(withImage.entries).toJson(),
    };
    final text = '${const JsonEncoder.withIndent('  ').convert(fixture)}\n';
    final file = File('test/replay/fixtures/timeline.json');
    if (Platform.environment['UPDATE_FIXTURES'] == '1') {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(text);
    }
    final saved = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    // The file's own bytes change with the export time only; the schedule
    // must match exactly.
    expect(saved['timeline'], fixture['timeline']);
    final read = decodeConversationFile(saved['file']! as String);
    expect(read.assets.keys, [asset.id]);
    expect(ReplayTimeline.of(read.share.entries).toJson(), saved['timeline']);
  });

  test('the sample conversation as a file and a page (WRITE_PREVIEW=<dir>)', () {
    final text = richFileText();
    final html = conversationHtml(text, title: '修复登录重复提交');
    expect(decodeConversationFile(text).assets, hasLength(1));
    expect(html, contains('<title>修复登录重复提交 · DSH Go</title>'));
    final dir = Platform.environment['WRITE_PREVIEW'];
    if (dir != null && dir.isNotEmpty) {
      Directory(dir).createSync(recursive: true);
      File('$dir/修复登录重复提交.dshgo').writeAsStringSync(text);
      File('$dir/修复登录重复提交.html').writeAsStringSync(html);
    }
  });
}
