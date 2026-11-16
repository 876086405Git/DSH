import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/io/deepseek_export.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String zip;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dsh-deepseek-');
    zip = '${directory.path}/deepseek_data-2026-11-16.zip';
    File(zip).writeAsBytesSync(
      _export({
        'short': _session('闲聊', current: 1, [
          _message(1, null, 'USER', [_text('REQUEST', '今天几号')]),
          _message(2, 1, 'ASSISTANT', [_text('RESPONSE', '十六号')]),
        ]),
        'long': _session('小满', current: 8, [
          _message(1, null, 'USER', [_text('REQUEST', '你以后叫小满')]),
          _message(2, 1, 'ASSISTANT', [_text('THINK', '想一想'), _text('RESPONSE', '好，我是小满')]),
          _message(3, 2, 'USER', [_text('REQUEST', '在吗')]),
          _message(4, 3, 'ASSISTANT', status: 'CONTENT_FILTER', [_text('TEMPLATE_RESPONSE', '换个话题吧')]),
          _message(5, 3, 'ASSISTANT', [_text('RESPONSE', '在的')]),
          _message(6, 5, 'USER', [_text('REQUEST', '晚安')]),
          _message(7, 6, 'ASSISTANT', status: 'FAILED', const []),
          _message(8, 7, 'USER', [_text('REQUEST', '还在吗')]),
        ]),
      }),
    );
  });
  tearDown(() => directory.delete(recursive: true));

  test('an export lists its conversations longest first and keeps every branch', () {
    expect(isDeepSeekExport(zip), isTrue);
    final list = listDeepSeekExport(zip);
    expect([for (final s in list) (s.id, s.title, s.messageCount)], [('long', '小满', 7), ('short', '闲聊', 2)]);
    expect(list.first.updatedAt, DateTime.utc(2026, 11, 15));

    final session = readDeepSeekSessions(zip, ['long']).single;
    // The reply that failed before a word is gone; what came after it hangs
    // from the line above. The withdrawn reply stays, out of the model's sight.
    expect([for (final m in session.currentPath) m.text], ['你以后叫小满', '好，我是小满', '在吗', '在的', '晚安', '还在吗']);
    expect(session.messages.singleWhere((m) => m.id == 2).reasoning, '想一想');
    expect(
      [
        for (final m in session.messages)
          if (m.hidden) m.text,
      ],
      ['换个话题吧'],
    );
    expect(session.messages.singleWhere((m) => m.id == 8).parentId, 6);
  });

  test('another zip is not an export', () {
    final other = '${directory.path}/other.zip';
    File(other).writeAsBytesSync(ZipEncoder().encode(Archive()..addFile(ArchiveFile.bytes('a.txt', utf8.encode('a')))));
    expect(isDeepSeekExport(other), isFalse);
    expect(() => listDeepSeekExport(other), throwsA(isA<DeepSeekExportException>()));
  });

  test('a conversation taken in continues where it stopped', () async {
    final model = _Model();
    final engine = await TavernEngine.openDirectory(
      Directory('${directory.path}/tavern'),
      config: TavernModelConfig(apiKey: () async => 'fixture', model: 'fixture'),
      modelClient: model,
    );
    addTearDown(engine.close);

    final listed = await engine.inspectDeepSeekExport(zip);
    expect(listed.first.imported, isNull);
    final taken = (await engine.importDeepSeekSessions(zip, ['long'])).single;
    expect((await engine.watchCharacters().first).single.name, '小满');
    expect([for (final m in await engine.path(taken.chatId)) m.text], ['你以后叫小满', '好，我是小满', '在吗', '在的', '晚安', '还在吗']);

    // Taking it in again makes nothing new, nor do two imports asked for at once.
    final again = (await engine.importDeepSeekSessions(zip, ['long'])).single;
    expect(again.chatId, taken.chatId);
    final both = await Future.wait([
      engine.importDeepSeekSessions(zip, ['short']),
      engine.importDeepSeekSessions(zip, ['short']),
    ]);
    expect(both.first.single.chatId, both.last.single.chatId);
    // 「闲聊」was left on its first line though a reply follows it: it opens there.
    expect([for (final m in await engine.path(both.first.single.chatId)) m.text], ['今天几号']);
    expect((await engine.inspectDeepSeekExport(zip)).first.imported?.chatId, taken.chatId);
    expect(await engine.watchCharacters().first, hasLength(2));

    await engine.send(taken.chatId, '我回来了').toList();
    final body = model.bodies.single;
    final sent = jsonEncode(body['messages']);
    expect(sent, allOf(contains('接着最后一条'), contains('好，我是小满'), contains('我回来了')));
    expect(sent, isNot(contains('换个话题吧')));
    expect(body['max_tokens'], 2000);
  });
}

class _Model extends TavernModelClient {
  final bodies = <Map<String, Object?>>[];

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    bodies.add(jsonDecode(jsonEncode(body)) as Map<String, Object?>);
    return Stream.fromIterable([const ModelText('回复'), const ModelFinished('stop')]);
  }
}

List<int> _export(Map<String, Map<String, Object?>> sessions) {
  final archive = Archive();
  void add(String name, Object? json) => archive.addFile(ArchiveFile.bytes(name, utf8.encode(jsonEncode(json))));
  add('manifest.json', {'export_format_version': 3});
  add('chat_session_index.json', [
    for (final id in sessions.keys)
      {'id': id, 'inserted_at': '2026-11-01T00:00:00Z', 'updated_at': '2026-11-15T00:00:00.000000000Z'},
  ]);
  for (final MapEntry(key: id, value: session) in sessions.entries) {
    add('chat_sessions/$id.json', {'id': id, ...session});
  }
  return ZipEncoder().encode(archive);
}

Map<String, Object?> _session(String title, List<Map<String, Object?>> messages, {int? current}) => {
  'title': title,
  'inserted_at': '2026-11-01T00:00:00Z',
  'current_message_id': current,
  'messages': messages,
};

Map<String, Object?> _message(
  int id,
  int? parent,
  String role,
  List<Map<String, Object?>> fragments, {
  String status = 'FINISHED',
}) => {
  'id': id,
  'parent_id': parent,
  'role': role,
  'status': status,
  'inserted_at': '2026-11-01T00:00:0$id.000Z',
  'fragments': fragments,
};

Map<String, Object?> _text(String type, String content) => {'type': type, 'content': content};
