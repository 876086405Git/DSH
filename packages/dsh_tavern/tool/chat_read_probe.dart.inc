// Appended to the SHA-pinned W7 heavy benchmark. Setup, writes and assertions
// stay outside _probeRead; only the end-to-end public read is timed.
void _registerChatReadProbes(Uint8List Function() card) {
  test('ADD03/watchChats cold, repeated and one changed tail', () async {
    expect(_entries, 1000);
    expect(_libraryCards, 50);
    final root = await Directory.systemTemp.createTemp('dsh-add03-list-');
    var engine = await _open(root);
    try {
      final preset = await engine.importPreset(_presetJson(), fileName: 'p.json');
      await engine.setDefaultPreset(preset.preset.id);
      await engine.importLorebook(_worldJson(_entries), fileName: 'w.json');
      final character = await engine.importCard(card(), fileName: 'heavy.png');
      final imported = await engine.importChats(character.id, [
        for (var index = 0; index < _libraryCards; index++)
          TavernChatFile(
            fileName: 'list-$index.jsonl',
            bytes: _readProbeJsonl(character.name, 2, tail: _greetingHtml(20, index)),
          ),
      ]);
      expect(imported.chatIds.toSet().length, 50);
      for (var sample = 1; sample <= 3; sample++) {
        await engine.close();
        engine = await _open(root);
        final cold = await _probeRead('ADD03/list/$sample/engine-cold', () => engine.watchChats().first);
        expect(cold, hasLength(50));
        final repeated = await _probeRead('ADD03/list/$sample/repeat', () => engine.watchChats().first);
        final before = {for (final chat in cold) chat.id: chat.lastText};
        expect({for (final chat in repeated) chat.id: chat.lastText}, before);
        final chatId = cold.first.id;
        final leaf = (await engine.path(chatId, limit: 1)).single;
        final marker = 'ADD03TAIL$sample';
        await engine.edit(chatId, leaf.nodeId, '${leaf.text}\n$marker');
        final changed = await _probeRead('ADD03/list/$sample/one-tail', () => engine.watchChats().first);
        final after = {for (final chat in changed) chat.id: chat.lastText};
        expect(changed, hasLength(50));
        expect(after.keys.toSet(), before.keys.toSet());
        expect(after.keys.where((id) => before[id] != after[id]).toList(), [chatId]);
        expect(after[chatId], contains(marker));
      }
      // ignore: avoid_print
      print('ADD03 verified: 50 real chats, repeated list and exactly one changed tail.');
    } finally {
      await engine.close();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('ADD03/path 60 with opaque payload, writes and sibling selection', () async {
    expect(_entries, 1000);
    final root = await Directory.systemTemp.createTemp('dsh-add03-path-');
    var engine = await _open(root);
    ChatStore? writer;
    try {
      final preset = await engine.importPreset(_presetJson(), fileName: 'p.json');
      await engine.setDefaultPreset(preset.preset.id);
      await engine.importLorebook(_worldJson(_entries), fileName: 'w.json');
      final character = await engine.importCard(card(), fileName: 'heavy.png');
      final opaque = _statusHtml(32, 19);
      // ignore: avoid_print
      print('ADD03 payload per extra/original field: ${opaque.length} UTF-16 code units, ${utf8.encode(opaque).length} UTF-8 bytes; last 60 nodes.');
      final imported = await engine.importChats(character.id, [
        TavernChatFile(fileName: 'plain.jsonl', bytes: _readProbeJsonl(character.name, 1000)),
        TavernChatFile(fileName: 'opaque.jsonl', bytes: _readProbeJsonl(character.name, 1000, opaque: opaque)),
      ]);
      final ids = {'plain': imported.chatsByFile['plain.jsonl']!, 'opaque': imported.chatsByFile['opaque.jsonl']!};
      expect(ids.values.toSet(), hasLength(2));
      final plain = await engine.path(ids['plain']!, limit: 60);
      final padded = await engine.path(ids['opaque']!, limit: 60);
      expect(plain, hasLength(60));
      expect(_probeRows(plain, identities: false), _probeRows(padded, identities: false));
      // Open before any checkpoint: open's recovery must not terminate the experiment.
      final store = ChatStore.open('${root.path}/tavern.sqlite3');
      writer = store;
      final retained = store.node(ids['opaque']!, padded.last.nodeId);
      expect(retained.extra['add03_extra'], opaque);
      expect(retained.original['add03_original'], opaque);
      for (final id in ids.values) {
        expect(store.path(id, limit: 1001), hasLength(1000));
      }
      for (var sample = 1; sample <= 3; sample++) {
        final order = sample.isOdd ? ['plain', 'opaque'] : ['opaque', 'plain'];
        for (final mode in order) {
          await engine.close();
          engine = await _open(root);
          final chatId = ids[mode]!;
          final otherId = ids[mode == 'plain' ? 'opaque' : 'plain']!;
          final label = 'ADD03/path/$sample/$mode';
          final first = await _probeRead('$label/engine-cold', () => engine.path(chatId, limit: 60));
          final repeated = await _probeRead('$label/repeat', () => engine.path(chatId, limit: 60));
          expect(first, hasLength(60));
          expect(_probeRows(repeated), _probeRows(first));
          final otherBefore = _probeRows(await engine.path(otherId, limit: 60));
          final leaf = first.last;
          await engine.edit(chatId, leaf.nodeId, '${leaf.text}\nADD03_EDIT_$sample');
          // edit runs the real regex/macro pipeline; compare to its persisted result.
          final editedText = store.message(chatId, leaf.nodeId).text;
          final edited = await _probeRead('$label/edited', () => engine.path(chatId, limit: 60));
          expect(edited.last.text, editedText);
          expect(edited.last.text, contains('ADD03_EDIT_$sample'));
          expect(_probeRows(edited.take(59)), _probeRows(first.take(59)));
          final checkpoint = '$editedText\nADD03_CHECKPOINT_$sample';
          final revision = store.treeRevision(chatId);
          store.beginStreamingWrites();
          try {
            store.writeStreamingBody(chatId, leaf.nodeId, text: checkpoint, reasoning: 'ADD03_REASON_$sample');
          } finally {
            store.endStreamingWrites();
          }
          expect(store.treeRevision(chatId), revision);
          final body = await _probeRead('$label/other-connection-checkpoint', () => engine.path(chatId, limit: 60));
          expect(body.last.text, checkpoint);
          expect(body.last.reasoning, 'ADD03_REASON_$sample');
          // Finish the checkpoint before the next engine reopen.
          store.updateMessage(chatId, leaf.nodeId, text: checkpoint, reasoning: 'ADD03_REASON_$sample');
          final branchSource = store.node(chatId, leaf.nodeId);
          final sibling = store.append(
            chatId,
            parentId: leaf.parentId,
            role: leaf.role,
            speaker: leaf.speaker,
            text: '$checkpoint\nADD03_BRANCH_$sample',
            makeCurrent: false,
            extra: branchSource.extra,
            original: branchSource.original,
          );
          await engine.selectNode(chatId, sibling.nodeId);
          final branched = await _probeRead('$label/sibling', () => engine.path(chatId, limit: 60));
          expect(branched, hasLength(60));
          expect(branched.last.nodeId, sibling.nodeId);
          expect(branched.last.text, contains('ADD03_BRANCH_$sample'));
          expect(branched.last.siblingCount, greaterThan(1));
          expect(branched.take(59).map((message) => message.nodeId), first.take(59).map((message) => message.nodeId));
          expect(_probeRows(await engine.path(otherId, limit: 60)), otherBefore);
          await engine.selectNode(chatId, leaf.nodeId);
        }
      }
      // ignore: avoid_print
      print('ADD03 verified: 1000-node paths, repeat/edit/checkpoint/sibling; checkpoint uses another connection, no native model turn.');
    } finally {
      await writer?.close();
      await engine.close();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}

Uint8List _readProbeJsonl(String name, int count, {String? tail, String? opaque}) {
  final bytes = _jsonl(name, count);
  if (tail == null && opaque == null) return bytes;
  final lines = const LineSplitter().convert(utf8.decode(bytes));
  for (var index = 1; index < lines.length; index++) {
    if (index != lines.length - 1 && (opaque == null || index < lines.length - 60)) continue;
    final row = jsonDecode(lines[index]) as Map<String, Object?>;
    if (tail != null && index == lines.length - 1) row['mes'] = tail;
    if (opaque != null && index >= lines.length - 60) {
      (row['extra']! as Map<String, Object?>)['add03_extra'] = opaque;
      row['add03_original'] = opaque;
    }
    lines[index] = jsonEncode(row);
  }
  return Uint8List.fromList(utf8.encode(lines.join('\n')));
}

Future<T> _probeRead<T>(String name, Future<T> Function() read) async {
  late T value;
  Object? failure;
  StackTrace? trace;
  // Let the original measure finish/cancel its Timer even if the read fails.
  await _measure<void>(name, () async {
    try {
      value = await read();
    } catch (error, stack) {
      failure = error;
      trace = stack;
    }
  });
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  return value;
}

List<List<Object?>> _probeRows(Iterable<TavernMessage> messages, {bool identities = true}) => [
  for (final message in messages)
    [
      if (identities) ...[message.nodeId, message.parentId],
      message.role.name, message.speaker, message.text, message.reasoning, message.at,
      message.hidden, message.siblingIndex, message.siblingCount, message.speakerCharacterId,
      message.usage != null, message.usage?.model, message.usage?.promptTokens,
      message.usage?.cacheHitTokens, message.usage?.completionTokens,
      message.reportedUsage != null, message.reportedUsage?.model, message.reportedUsage?.promptTokens,
      message.reportedUsage?.cacheHitTokens, message.reportedUsage?.completionTokens,
    ],
];
