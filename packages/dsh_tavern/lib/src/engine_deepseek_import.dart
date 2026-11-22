part of 'engine.dart';

// Taking a conversation over from DeepSeek's own app (io/deepseek_export.dart
// reads its export). There is no card behind such a conversation: who the
// model was lives in the conversation itself. So each one gets a character
// that only says "go on as before", its chat holds the whole tree, and the
// chat asks for enough context that the model reads a long stretch of it.

/// What a taken-in chat asks of the preset when the preset offers less: ST's
/// default 4K context and 300-token reply would forget all but the last few
/// lines and cut replies short.
const _deepSeekContext = 65536;
const _deepSeekReply = 2000;

/// The card's own main prompt (it replaces the preset's, which speaks of a
/// fictional chat with a character named after the card).
const _deepSeekPrompt =
    '这是一段已经进行了很久的对话，下面是它的记录。你就是记录里一直在回应用户的那一方：'
    '保持同样的身份、性格、语气和对用户的称呼，记得你们之间发生过的事，接着最后一条自然地聊下去。'
    '不要提到“记录”“导入”或换了地方。';

/// How much of one opening message is kept as the card's description.
const _deepSeekOpeningChars = 4000;

extension _DeepSeekImportOperations on TavernEngine {
  Future<List<TavernDeepSeekSession>> _inspectDeepSeekExport(String zipPath) => _operation(() async {
    final sessions = await _deepSeekList(zipPath);
    final imported = _store.deepSeekChats();
    return [
      for (final session in sessions)
        TavernDeepSeekSession(
          id: session.id,
          title: session.title,
          messageCount: session.messageCount,
          updatedAt: session.updatedAt,
          imported: switch (imported[session.id]) {
            final chat? => TavernDeepSeekImported(
              sessionId: session.id,
              characterId: chat.characterId,
              chatId: chat.chatId,
            ),
            null => null,
          },
        ),
    ];
  });

  Future<List<TavernDeepSeekImported>> _importDeepSeekSessions(String zipPath, List<String> sessionIds) =>
      _operation(() {
        final ids = List<String>.of(sessionIds);
        // One at a time: an import asked for while another runs finds what
        // that one took in, instead of taking the same conversation in twice.
        final result = _deepSeekImports.then((_) => _deepSeekImport(zipPath, ids));
        _deepSeekImports = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
        return result;
      });

  Future<List<TavernDeepSeekImported>> _deepSeekImport(String zipPath, List<String> ids) async {
    final sessions = await _deepSeekSessions(zipPath, ids);
    final result = <TavernDeepSeekImported>[];
    for (final session in sessions) {
      if (_store.deepSeekChats()[session.id] case final chat?) {
        result.add(TavernDeepSeekImported(sessionId: session.id, characterId: chat.characterId, chatId: chat.chatId));
        continue;
      }
      final character = await _importCard(utf8.encode(jsonEncode(_deepSeekCard(session))));
      final String chatId;
      try {
        chatId = await _libraryOperation(() async => _deepSeekChat(session, character));
      } on Object {
        await deleteCharacter(character.id);
        rethrow;
      }
      result.add(TavernDeepSeekImported(sessionId: session.id, characterId: character.id, chatId: chatId));
    }
    _notifyLists();
    return result;
  }

  String _deepSeekChat(DeepSeekSession session, TavernCharacter character) {
    final userName = _personaSettings(_effectiveSettings(), _personas.resolve())['userName'];
    final preset = _map(_effectiveSettings()['preset']);
    final path = session.currentPath;
    final next = {for (var i = 0; i + 1 < path.length; i++) path[i].id: path[i + 1].id};
    // Off the branch last on screen, a message leads on to its newest reply.
    final newest = <int, int>{for (final message in session.messages) ?message.parentId: message.id};
    return _store.transaction(() {
      final chatId = _store.createChat(
        characterId: character.id,
        title: session.title.isEmpty ? character.name : session.title,
        metadata: {
          'dshgo': {
            'deepseek': {'version': 1, 'sessionId': session.id},
          },
        },
        settings: {
          'presetOverrides': {
            'openai_max_context': max(presetNumber(preset['openai_max_context'], 4095).toInt(), _deepSeekContext),
            'openai_max_tokens': max(presetNumber(preset['openai_max_tokens'], 300).toInt(), _deepSeekReply),
          },
        },
      );
      final nodes = <int, String>{};
      for (final message in session.messages) {
        nodes[message.id] = _store
            .append(
              chatId,
              parentId: nodes[message.parentId],
              role: message.isUser ? TavernRole.user : TavernRole.character,
              speaker: message.isUser ? (userName is String ? userName : 'User') : character.name,
              speakerCharacterId: message.isUser ? null : character.id,
              text: message.text,
              reasoning: message.reasoning,
              at: message.at,
              hidden: message.hidden,
              makeCurrent: false,
            )
            .nodeId;
      }
      _store.restoreSelection(
        chatId,
        selectedRootId: path.isEmpty ? null : nodes[path.first.id],
        selectedChildren: {
          for (final message in session.messages)
            // The branch last on screen ends where the export says it did,
            // even when something was said after that line.
            nodes[message.id]!:
                nodes[next[message.id] ?? (message.id == session.currentId ? null : newest[message.id])],
        },
      );
      return chatId;
    });
  }
}

// Top-level, so what crosses to the other isolate is the path alone and never
// the engine.
Future<List<DeepSeekSessionSummary>> _deepSeekList(String zipPath) => _deepSeekRead(() => listDeepSeekExport(zipPath));

Future<List<DeepSeekSession>> _deepSeekSessions(String zipPath, List<String> ids) =>
    _deepSeekRead(() => readDeepSeekSessions(zipPath, ids));

/// Reads an export off the main isolate; a file that is not one is an import
/// error the app can say plainly.
Future<T> _deepSeekRead<T>(T Function() read) async {
  try {
    return await Isolate.run(read);
  } on DeepSeekExportException {
    throw const TavernImportError('这不是 DeepSeek 导出的对话文件。');
  }
}

Map<String, Object?> _deepSeekCard(DeepSeekSession session) {
  final name = session.title.isEmpty ? 'DeepSeek 对话' : session.title;
  final spoken = session.currentPath.where((message) => !message.hidden).toList();
  // Past what the model is sent, the oldest lines drop out first — and they
  // are where the person usually said who the model should be. Keep them.
  final opening = spoken.fold(0, (sum, message) => sum + message.text.length) <= _deepSeekContext
      ? ''
      : [
          '这段对话最开始的内容，一直作为设定保留：',
          for (final message in spoken.take(2))
            '${message.isUser ? '用户' : '你'}：'
                '${message.text.length > _deepSeekOpeningChars ? '${message.text.substring(0, _deepSeekOpeningChars)}…' : message.text}',
        ].join('\n\n');
  return {
    'spec': 'chara_card_v2',
    'spec_version': '2.0',
    'data': {
      'name': name.length > 40 ? name.substring(0, 40) : name,
      'description': opening,
      'personality': '',
      'scenario': '',
      'first_mes': '',
      'mes_example': '',
      'creator_notes': '从 DeepSeek 的对话接回。',
      'system_prompt': _deepSeekPrompt,
      'post_history_instructions': '',
      'alternate_greetings': <String>[],
      'tags': <String>['DeepSeek'],
      'creator': '',
      'character_version': '',
      'extensions': <String, Object?>{},
    },
  };
}
