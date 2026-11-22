part of 'engine.dart';

TavernHelperGenerationOptions? _helperOptions(TavernScriptGenerateRequest request) =>
    request is TavernHelperGenerationRequest ? (request as TavernHelperGenerationRequest).helperOptions : null;

bool _helperFiltersHistory(TavernScriptGenerateRequest request) {
  if (_helperOptions(request) == null) return false;
  final history = request.overrides.fields['chatHistory'];
  return history is List<Object?> && history.isEmpty;
}

class _HelperGenerationController {
  _HelperGenerationController(this.owner);
  final _ScriptCoordinator owner;
  final observers = <MultiStreamController<TavernHelperGenerationControlState>>{};
  bool closed = false;

  Iterable<_ScriptGenerationRecord> get active => owner._generations.values.where(
    (record) => _helperOptions(record.request) != null && record.terminal == null && !record.cancellation.isCancelled,
  );

  TavernHelperGenerationControlState get state => TavernHelperGenerationControlState(
    activeIds: [for (final record in active) record.id],
    nonSilentIds: [
      for (final record in active)
        if (!record.request.silent) record.id,
    ],
  );

  Stream<TavernHelperGenerationControlState> watch() => Stream<TavernHelperGenerationControlState>.multi((observer) {
    observer.add(state);
    if (closed) {
      observer.close();
      return;
    }
    observers.add(observer);
    observer.onCancel = () => observers.remove(observer);
  }, isBroadcast: true);

  void changed() {
    if (closed || observers.isEmpty) return;
    final next = state;
    for (final observer in observers.toList()) {
      observer.add(next);
    }
  }

  bool stop(String id) {
    final record = owner._generations[id];
    if (record == null ||
        _helperOptions(record.request) == null ||
        record.terminal != null ||
        record.cancellation.isCancelled) {
      return false;
    }
    record.cancellation.cancel();
    owner._generationNotify(record, 'GENERATION_STOPPED', [record.id]);
    changed();
    return true;
  }

  int stopMatching({required bool includeSilent}) {
    final selected = [
      for (final record in active)
        if (includeSilent || !record.request.silent) record.id,
    ];
    for (final id in selected) {
      stop(id);
    }
    return selected.length;
  }

  void close() {
    if (closed) return;
    closed = true;
    for (final observer in observers.toList()) {
      observer.add(state);
      observer.close();
    }
    observers.clear();
  }
}

extension _HelperPromptPreparation on _ScriptPromptRun {
  void _prepareHelperNamedPreset() {
    final helper = capture.helper;
    if (helper?.namedPreset == null) return;
    helper!.namedOrder = [
      for (final part in (capture.request as TavernScriptRawRequest).orderedPrompts)
        if (part is TavernScriptPromptLiteral)
          ...(() {
            final content = environment.expand(part.content, const {});
            return trimJsWhitespace(content).isEmpty
                ? <TavernScriptPromptPart>[]
                : [TavernScriptPromptPart.literal(role: part.role, content: content)];
          })()
        else
          part,
    ];
    for (final (index, injection) in helper.options.nativeInjections.indexed) {
      if (index < helper.namedInjectionStart) continue;
      helper.namedInjectionContent[index] = environment.expand(
        environment.expand(injection.content, const {}),
        const {},
      );
    }
  }

  List<PromptHistoryMessage> _prepareHelperHistory() {
    final replacement = overrides['chatHistory'];
    if (replacement is List<Object?>) {
      return [
        for (final (index, row) in replacement.cast<Map<String, Object?>>().indexed)
          PromptHistoryMessage(
            id: 'scriptHistory$index',
            role: row['role']! as String,
            content: row['content']! as String,
          ),
      ];
    }
    final full = promptHistory.where((node) => !node.message.hidden && !_systemMessage(node)).toList();
    final prepared = _preparePromptHistory(full, environment, continuing: false);
    final maximum = _helperOptions(capture.request)!.maxChatHistory;
    final take = maximum == null
        ? prepared.length
        : maximum < 0
        ? max(0, prepared.length + maximum)
        : min(prepared.length, maximum);
    return [for (final node in prepared.skip(prepared.length - take)) _promptHistory(node)];
  }

  Future<Map<String, Object?>> _helperRawBody() async {
    final request = capture.request as TavernScriptRawRequest;
    final options = _helperOptions(request)!;
    final ordered = capture.helper?.namedOrder ?? request.orderedPrompts;
    final positions = <TavernScriptPromptPlaceholder, int>{};
    for (final (index, part) in ordered.indexed) {
      if (part is TavernScriptPromptPlaceholderPart) positions[part.kind] = index;
    }
    final collections = <int, List<_ScriptRawPiece>>{};
    var remaining = environment.maxContext - environment.maxResponse - 3;
    final sourceMessageCosts = <String, int>{};
    int cost(_ScriptRawPiece piece) =>
        sourceMessageCosts[piece.id] ??
        (piece.message['content'] == '' && !piece.message.containsKey('tool_calls')
            ? 0
            : _helperImageCounter.countMessage(piece.message));
    Never overflow() => throw const TavernModelException(
      TavernFailure.contextTooLong,
      'The Helper raw collection exceeds the current preset budget.',
    );
    void add(int at, List<_ScriptRawPiece> pieces) {
      final tokens = pieces.fold<int>(0, (sum, item) => sum + cost(item));
      if (tokens > remaining) overflow();
      collections[at] = pieces;
      remaining -= tokens;
    }

    List<_ScriptRawPiece> source(TavernScriptPromptPlaceholder kind) =>
        _rawSources.putIfAbsent(kind, () => _rawSource(kind));
    for (final (index, part) in ordered.indexed) {
      if (part is TavernScriptPromptLiteral) {
        if (part.content.isNotEmpty) {
          add(index, [
            _piece({'role': part.role.name, 'content': part.content}, PromptSource('scriptLiteral', 'literal$index')),
          ]);
        }
      } else if (part is TavernScriptPromptPlaceholderPart &&
          part.kind != TavernScriptPromptPlaceholder.chatHistory &&
          part.kind != TavernScriptPromptPlaceholder.userInput &&
          part.kind != TavernScriptPromptPlaceholder.dialogueExamples &&
          !(part.kind == TavernScriptPromptPlaceholder.personaDescription && settings['personaInPrompt'] == false)) {
        add(positions[part.kind]!, source(part.kind));
      }
    }
    int first(TavernScriptPromptPlaceholder kind) =>
        ordered.indexWhere((part) => part is TavernScriptPromptPlaceholderPart && part.kind == kind);
    final exampleIndex = first(TavernScriptPromptPlaceholder.dialogueExamples);
    if (exampleIndex >= 0) add(exampleIndex, source(TavernScriptPromptPlaceholder.dialogueExamples));
    final historyIndex = first(TavernScriptPromptPlaceholder.chatHistory);
    final userIndex = first(TavernScriptPromptPlaceholder.userInput);
    final replacement = overrides['chatHistory'];
    final historyFiltered = replacement is List<Object?> && replacement.isEmpty;
    final attachImage = userIndex >= 0 || historyIndex >= 0 && !historyFiltered;
    final coerceHistoryArray =
        userIndex < 0 &&
        historyIndex >= 0 &&
        !historyFiltered &&
        capture.helper!.imageArray &&
        options.images.isNotEmpty;
    final plainUser = _piece({
      'role': 'user',
      'content': preparedInput,
    }, const PromptSource('helperReserve', 'userInput'));
    // The outer fixed Helper path still reserves the plain user text before
    // the inner collection admits its own Message instance.
    final userCost = cost(plainUser);
    remaining -= userCost;
    if (userIndex >= 0) await capture.helper!.prepareRawUserImage();
    _ScriptRawPiece user() {
      final piece = _piece({
        'role': 'user',
        'content': attachImage
            ? _helperImageText(
                preparedInput,
                capture.helper?.images,
                required: !coerceHistoryArray,
                forceArray: capture.helper!.imageArray && options.images.isNotEmpty,
              )
            : preparedInput,
      }, const PromptSource('scriptPlaceholder', 'userInput'));
      if (userIndex >= 0 && capture.helper!.imageArray && options.images.isNotEmpty) {
        // Fixed Message.createAsync(parts) keeps its initial tokens=0. The
        // text reserve above is separate, including when every image failed.
        sourceMessageCosts[piece.id] = 0;
      }
      return piece;
    }

    if (historyIndex < 0 || historyFiltered) {
      add(userIndex < 0 ? ordered.length : userIndex, [user()]);
    } else {
      final newChat = _piece({
        'role': 'system',
        'content': environment.expand(_string(capture.contextRegexPresetSettings['new_chat_prompt']), const {}),
      }, const PromptSource('helperControl', 'newMainChat'));
      final newChatCost = cost(newChat);
      remaining -= newChatCost;
      final collection = <_ScriptRawPiece>[newChat];
      final sendIfEmpty = _string(capture.contextRegexPresetSettings['send_if_empty']);
      if (_history().firstOrNull?.role == 'assistant' && sendIfEmpty.isNotEmpty) {
        final empty = _piece({
          'role': 'user',
          'content': sendIfEmpty,
        }, const PromptSource('helperControl', 'emptyUser'));
        if (cost(empty) <= remaining) collection.add(empty);
      }
      await capture.helper!.prepareRawHistoryImages(capture, hasInput: userIndex >= 0);
      final history = List<_ScriptRawPiece>.of(source(TavernScriptPromptPlaceholder.chatHistory));
      final userMessage = user();
      if (userIndex < 0) history.add(userMessage);
      final additions = <PromptInjection>[
        ...shared.prompts,
        if (world == null)
          ...configured.map((item) => item.injection)
        else
          ..._finishInjections(configured, world!)
              .where((injection) => depthRequested || injection.fragment.source.kind != 'worldInfo')
              .map(_preparedPromptInjection),
        for (final (index, injection) in options.nativeInjections.indexed)
          PromptInjection(
            fragment: PromptFragment(
              environment.expand(capture.helper?.namedInjectionContent[index] ?? injection.content, const {}),
              PromptSource('helperInjection', injection.id),
              expandMacros: false,
            ),
            role: injection.role.name,
            depth: injection.depth,
          ),
      ];
      final expanded = _helperDepth(history, additions);
      // Fixed upstream checks each message against the same remaining budget;
      // MessageCollection.add itself does not charge. The complete collection
      // is charged below, so individually affordable rows can still overflow.
      for (var piece in expanded) {
        if (coerceHistoryArray && piece.id == userMessage.id) {
          // Fixed Helper sends these parts through substituteParams in its
          // history loop: String(parts) precedes either macro engine and cost.
          final message = _helperImageMessage(piece.message);
          capture.helper!.record.hookIssues.add(
            TavernScriptIssue(
              code: 'helperHistoryImageArrayCoerced',
              message: 'substituteParams: content will be coerced to string',
              committed: false,
              contextId: capture.context.value.id,
              generationId: capture.generationId,
              stage: 'image',
            ),
          );
          piece = _ScriptRawPiece(
            piece.id,
            {...message, 'content': environment.expand(ScriptCoercion.string(message['content']), const {})},
            piece.source,
            worldIdentity: piece.worldIdentity,
            optional: piece.optional,
          );
        }
        if (piece.source.kind == 'history' && capture.helper!.historyImageInlining) {
          final images = await capture.helper!.resolveHistoryImages(piece.source.id);
          if (images != null) {
            // ST addImage converts text to parts before download/base64. Its
            // caught failure preserves the original Message.tokens value.
            if (images.isEmpty) sourceMessageCosts[piece.id] = cost(piece);
            piece = _ScriptRawPiece(
              piece.id,
              {
                ...piece.message,
                'content': _helperImageText(piece.message['content']! as String, images, forceArray: true),
              },
              piece.source,
              worldIdentity: piece.worldIdentity,
              optional: piece.optional,
            );
          }
        }
        if (cost(piece) > remaining) break;
        collection.add(piece);
      }
      remaining += newChatCost;
      add(historyIndex, collection);
      if (userIndex >= 0) add(userIndex, [userMessage]);
    }
    remaining += userCost;
    final indices = collections.keys.toList()..sort();
    var pieces = [for (final index in indices) ...collections[index]!];
    pieces = pieces
        .where((piece) => piece.message['content'] != '' || piece.message.containsKey('tool_calls'))
        .toList();
    if (presetTruthy(capture.contextRegexPresetSettings['squash_system_messages'])) {
      final squashed = <_ScriptRawPiece>[];
      bool eligible(_ScriptRawPiece piece) =>
          piece.message['role'] == 'system' && !piece.message.containsKey('name') && piece.source.id != 'newMainChat';
      for (final piece in pieces) {
        final previous = squashed.lastOrNull;
        if (previous != null && eligible(previous) && eligible(piece)) {
          squashed[squashed.length - 1] = _ScriptRawPiece(
            previous.id,
            _captureScriptObject({
              ...previous.message,
              'content': '${previous.message['content']}\n${piece.message['content']}',
            }),
            previous.source,
            worldIdentity: previous.worldIdentity,
            optional: previous.optional,
          );
        } else {
          squashed.add(piece);
        }
      }
      pieces = squashed;
    }
    var segments = _materializeHelperImageSegments([for (final piece in pieces) piece.segment(_helperImageCounter)]);
    final mode = _spString(promptPreset?.settings['custom_prompt_post_processing']);
    List<Object?>? rawMessages;
    if (spreset?.config.present == true) {
      segments = await spresetSquashSegments(
        segments,
        spreset!.config,
        owner.engine._counter,
        expand: (text) => environment.expand(text, const {}),
        evaluate: spreset!.evaluate,
        diagnose: spreset!.diagnose,
        historyIds: {for (final piece in collections[historyIndex] ?? const <_ScriptRawPiece>[]) piece.id},
        onUnconvertedMessages: spreset!.allowsRawMessageArray(mode) ? (messages) => rawMessages = messages : null,
      );
      spreset!.check();
    }
    segments = postProcessPrompt(
      segments,
      mode,
      userName: environment.userName,
      characterName: _string(card['name']),
      groupNames: capture.groupView?.names ?? const [],
      counter: owner.engine._counter,
    );
    final converted = convertExplicitPromptMessages(
      segments,
      deepseek: capture.config.deepseek,
      userName: environment.userName,
      characterName: _string(card['name']),
      groupNames: capture.groupView?.names ?? const [],
      counter: owner.engine._counter,
    );
    final body = explicitPromptRequestBody(
      messages: converted,
      settings: promptPreset!.settings,
      deepseek: capture.config.deepseek,
      model: capture.config.model,
    );
    if (rawMessages != null) body['messages'] = rawMessages;
    final tools = spreset?.offerTools(const []) ?? const [];
    if (tools.isNotEmpty) body.addAll({'tools': tools, 'tool_choice': 'auto'});
    return body;
  }

  List<_ScriptRawPiece> _helperDepth(List<_ScriptRawPiece> history, List<PromptInjection> additions) {
    final newest = history.reversed.toList();
    final depths = additions.map((injection) => injection.depth).toSet().toList()..sort();
    var inserted = 0;
    for (final depth in depths) {
      final group = additions.where((injection) => injection.depth == depth).toList();
      final messages = <_ScriptRawPiece>[];
      for (final role in const ['system', 'user', 'assistant']) {
        final text = group
            .where((injection) => injection.role == role)
            .map((injection) {
              final fragment = injection.fragment;
              return trimJsWhitespace(
                fragment.expandMacros ? environment.expand(fragment.content, const {}) : fragment.content,
              );
            })
            .where((text) => text.isNotEmpty)
            .join('\n');
        if (text.isNotEmpty) {
          messages.add(_piece({'role': role, 'content': text}, PromptSource('helperDepth', '$depth:$role')));
        }
      }
      newest.insertAll(min(newest.length, depth + inserted), messages);
      inserted += messages.length;
    }
    return newest.reversed.toList();
  }
}
