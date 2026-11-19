// ST message/swipe/branch semantics: public/script.js ensureSwipes,
// syncMesToSwipe, syncSwipeToMes, saveChat; public/scripts/bookmarks.js
// createBranch/createNewBookmark, SillyTavern 1.19.0 (AGPL-3.0), commit
// 7e8663cd9c184a550b37238218bdd32c6efc68e9. Message variables[] are mapped
// from this project's roleplay-compat.md §7; no JS-Slash-Runner source is used.
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import '../api.dart';
import '../store/chat_store.dart';
import 'st_chat_document.dart';

final class ChatJsonlImportResult {
  ChatJsonlImportResult({
    required List<String> chatIds,
    required Map<String, String> chatsByFile,
    required List<String> notices,
  }) : chatIds = List.unmodifiable(chatIds),
       chatsByFile = Map.unmodifiable(chatsByFile),
       notices = List.unmodifiable(notices);
  final List<String> chatIds;
  final Map<String, String> chatsByFile;
  final List<String> notices;
}

/// An owned, validated batch which has not yet written anything to SQLite.
final class ChatJsonlImportPlan {
  const ChatJsonlImportPlan._(this._groups, this._notices);
  final List<({_ImportTree tree, List<StoredChatImportNode> nodes})> _groups;
  final List<String> _notices;
}

// Keep isolate closures here: their only captured state is sendable data,
// never a codec clock callback, engine, store, file queue or open connection.
Future<List<StChatDocument>> _decodeChatFilesInWorker(List<TavernChatFile> files) =>
    Isolate.run(() => [for (final file in files) StChatDocument.decode(file.fileName, file.bytes)]);

Future<ChatJsonlImportPlan> _prepareChatImportInWorker(List<StChatDocument> documents, DateTime fallbackDate) =>
    Isolate.run(() => _prepareChatImport(documents, fallbackDate));

ChatJsonlImportPlan _prepareChatImport(Iterable<StChatDocument> documents, DateTime fallbackDate) {
  final notices = <String>[];
  final files = <String, _SourceFile>{};
  for (final document in documents) {
    final file = _SourceFile(document, fallbackDate, notices);
    if (files.containsKey(file.key)) {
      throw StChatFormatException(document.fileName, document.headerLineNumber, 'Duplicate normalized filename.');
    }
    files[file.key] = file;
  }
  final ordered = _orderFiles(files, notices);
  final groups = <String, _ImportTree>{};
  for (final file in ordered) {
    final parent = files[file.parentKey];
    final root = parent?.rootKey ?? file.key;
    file.rootKey = root;
    final tree = groups.putIfAbsent(root, () => _ImportTree(file));
    tree.add(file, parent, notices);
  }
  for (final tree in groups.values) {
    tree.finish(notices);
  }
  return ChatJsonlImportPlan._([
    for (final tree in groups.values)
      (
        tree: tree,
        nodes: [
          for (final node in tree.nodes)
            StoredChatImportNode(
              key: node.id,
              parentKey: node.parent,
              role: node.variant.role,
              speaker: node.variant.name,
              speakerCharacterId: node.variant.speakerCharacterId,
              text: node.variant.text,
              reasoning: node.variant.reasoning,
              at: node.variant.at,
              hidden: node.variant.hidden,
              usage: node.variant.usage,
              state: node.state,
              extra: _withState(node.extra, node.state),
              original: node.variant.original,
            ),
        ],
      ),
  ], notices);
}

/// A physical metadata carrier, not a node-selection or generation identity.
enum ChatJsonlMetadataCarrier { root, sources, files }

final class ChatJsonlMetadataSource {
  const ChatJsonlMetadataSource._(this.carrier, this.sourceFile, this.fileIndex);

  final ChatJsonlMetadataCarrier carrier;
  final String? sourceFile;
  final int? fileIndex;

  /// Includes the actual files-array slot; no delimiter can alias a raw key.
  String get identity => jsonEncode([carrier.name, sourceFile, fileIndex]);
}

/// Imports only the supplied same-character batch. Filenames are labels, not
/// paths to read. Every document is validated before the single DB transaction.
final class ChatJsonlCodec {
  ChatJsonlCodec({DateTime Function()? clock, String Function()? createIntegrity})
    : _clock = clock ?? DateTime.now,
      _createIntegrity = createIntegrity ?? _uuid;
  final DateTime Function() _clock;
  final String Function() _createIntegrity;

  static Future<List<StChatDocument>> decodeFiles(List<TavernChatFile> files) => _decodeChatFilesInWorker(files);

  Future<ChatJsonlImportPlan> prepareBatchAsync(Iterable<StChatDocument> documents) =>
      _prepareChatImportInWorker(List<StChatDocument>.of(documents), _clock().toUtc());

  ChatJsonlImportResult importBatch(
    ChatStore store, {
    required String characterId,
    required Iterable<StChatDocument> documents,
  }) => commitBatch(store, characterId: characterId, plan: _prepareChatImport(documents, _clock().toUtc()));

  ChatJsonlImportResult commitBatch(
    ChatStore store, {
    required String characterId,
    required ChatJsonlImportPlan plan,
  }) => store.transaction(() {
    final chatIds = <String>[];
    final chatsByFile = <String, String>{};
    for (final group in plan._groups) {
      final tree = group.tree;
      final metadata = _quarantineMetadata(tree.root.metadata);
      final chatId = store.createChat(
        characterId: characterId,
        title: _stem(tree.root.document.fileName),
        metadata: metadata,
      );
      chatIds.add(chatId);
      final ids = store.appendImportedNodes(chatId, group.nodes);
      store.restoreSelection(
        chatId,
        selectedRootId: ids[tree.selectedRoot],
        selectedChildren: {for (final node in tree.nodes) ids[node.id]!: ids[tree.choices[node.id]]},
      );
      final own = _map(_map(metadata['dshgo'])[_namespace]);
      own.addAll({
        'version': 1,
        'rootFile': tree.root.key,
        'sources': tree.sources,
        'files': [
          for (final file in tree.files)
            {
              'key': file.key,
              'fileName': file.document.fileName,
              'header': _sourceHeader(file.document.header, keepSourceFileName: true),
              'path': [for (final node in file.path) ids[node.id]],
              // Shared variants do not own a source row's unused array tail.
              'unusedTails': {
                for (var index = 0; index < file.path.length; index++)
                  ids[file.path[index].id]!: _unusedMessageTails(file.document.messages[index]),
              },
            },
        ],
      });
      metadata['dshgo'] = {..._map(metadata['dshgo']), _namespace: own};
      final leaf = tree.currentLeaf;
      final variables = leaf == null ? _map(tree.root.metadata['variables']) : _map(leaf.state['variables']);
      store.updateChat(chatId, metadata: metadata, variables: variables);
      for (final file in tree.files) {
        chatsByFile[file.document.fileName] = chatId;
      }
    }
    return ChatJsonlImportResult(chatIds: chatIds, chatsByFile: chatsByFile, notices: plan._notices);
  });

  /// Null [nodeId] means the current leaf. Source metadata is copied; a file's
  /// final variables or world-info state are never presented as the state of
  /// an earlier node. A known null hash removes an old source-header cache.
  Map<String, Object?> metadataForNode(ChatStore store, String chatId, {String? nodeId}) {
    final chat = store.chat(chatId);
    final id = nodeId ?? chat.currentLeafId;
    return metadataForCapturedNode(store, chat, id == null ? null : store.node(chatId, id));
  }

  /// Projects a fully read [chat] and a fully read [node] from that same chat.
  /// The caller has already resolved the store boundary; null means an empty
  /// captured path. Does not mutate either snapshot or reread its full row.
  Map<String, Object?> metadataForCapturedNode(ChatStore store, StoredChat chat, StoredNode? node) {
    if (node == null) {
      return {..._clone(chat.metadata), 'variables': _clone(chat.variables)};
    }
    final state = _effectiveState(store, chat.id, node);
    return metadataForState(chat, state);
  }

  /// Projects a previously captured node state without looking the node up
  /// again. Single-node deletion uses this before reparenting even children
  /// hidden by a pending subtree deletion. Does not mutate [chat] or [state].
  Map<String, Object?> metadataForState(StoredChat chat, Map<String, Object?> state) {
    final source = state[_sourceKey];
    final header = _sourceFor(chat.metadata, source);
    final metadata = header == null ? _clone(chat.metadata) : _map(header['chat_metadata']);
    metadata.remove('variables');
    if (state['variables'] is Map<String, Object?>) {
      metadata['variables'] = _map(state['variables']);
    }
    _projectRuntimeState(metadata, state);
    return metadata;
  }

  /// The actual source used by [metadataForState], captured with the selected
  /// state. A stale/unmapped label falls back to root just as that reader does.
  String? metadataSourceForState(StoredChat chat, Map<String, Object?> state) =>
      metadataSourceTargetForState(chat, state).sourceFile;

  /// Resolves once with the same null/current and effective-state rules as
  /// [metadataForNode]. An empty path or an unmapped label resolves to root.
  ChatJsonlMetadataSource metadataSourceForNode(ChatStore store, String chatId, {String? nodeId}) {
    final chat = store.chat(chatId);
    final id = nodeId ?? chat.currentLeafId;
    return id == null
        ? _metadataSource(chat.metadata, null)
        : metadataSourceTargetForState(chat, _effectiveState(store, chatId, store.node(chatId, id)));
  }

  ChatJsonlMetadataSource metadataSourceTargetForState(StoredChat chat, Map<String, Object?> state) =>
      _metadataSource(chat.metadata, state[_sourceKey]);

  /// Reads only this captured carrier, without consulting a leaf or applying
  /// state projections. A missing/rekeyed files slot or missing source returns
  /// null; it never silently switches to a fallback carrier. Malformed/null
  /// chat_metadata keeps the ordinary reader's empty-map projection.
  Map<String, Object?>? readMetadataSource(Map<String, Object?> root, ChatJsonlMetadataSource source) {
    if (source.carrier == ChatJsonlMetadataCarrier.root) return _clone(root);
    final header = _metadataSourceHeader(root, source);
    return header == null ? null : _map(header['chat_metadata']);
  }

  /// Pure single-source edit for the bridge's short SQL carrier. The caller
  /// checks current selection/source identity inside its real transaction.
  /// Only a proven same-key/context catalogue mirror follows the delta;
  /// unrelated headers, quarantine data and unknown keys are untouched.
  Map<String, Object?> updateMetadataSource(
    Map<String, Object?> root, {
    required String? sourceFile,
    ChatJsonlMetadataSource? target,
    required Map<String, Object?> Function(Map<String, Object?>) update,
  }) {
    final result = _clone(root);
    final source = target ?? _metadataSource(result, sourceFile);
    if (source.sourceFile != sourceFile) {
      throw const FormatException('The selected metadata source is absent.');
    }
    if (source.carrier == ChatJsonlMetadataCarrier.root) return _clone(update(result));
    final header = _metadataSourceHeader(result, source);
    if (header == null) throw const FormatException('The selected metadata source is absent.');
    final metadata = header['chat_metadata'];
    if (metadata != null && metadata is! Map<String, Object?>) {
      throw const FormatException('The selected source metadata is not an object.');
    }
    final before = _map(metadata);
    final after = _clone(update(_clone(before)));
    header['chat_metadata'] = after;
    if (source.carrier == ChatJsonlMetadataCarrier.sources) {
      // The normal importer also keeps the file's terminal header. Only its
      // same-key, same-context mirror follows this edit; a historical context
      // with the same label remains independent. Apply the context delta once,
      // preserving the catalogue's variables, navigation and unknown fields.
      final own = _view(_view(result['dshgo'])[_namespace]);
      final files = own['files'];
      final beforeContext = _contextMetadata(before);
      final afterContext = _contextMetadata(after);
      if (files is List<Object?>) {
        for (final file in files.whereType<Map<String, Object?>>()) {
          final mirror = file['header'];
          if (file['key'] != sourceFile || mirror is! Map<String, Object?>) continue;
          final raw = mirror['chat_metadata'];
          if (raw != null && raw is! Map<String, Object?>) continue;
          final current = _map(raw);
          if (_canonical(_contextMetadata(current)) != _canonical(beforeContext)) continue;
          mirror['chat_metadata'] = _metadataContextDelta(current, beforeContext, afterContext);
        }
      }
    }
    return result;
  }

  /// Single-page ST object at the actual commit watermark. It shares the
  /// existing export projection/family logic without serializing a whole
  /// JSONL document, inventing a header integrity, or changing stored values.
  Map<String, Object?> projectMessage(ChatStore store, String chatId, String nodeId) {
    final tree = _ExportTree(store, chatId, null, _createIntegrity);
    final node = tree.byId[nodeId];
    if (node == null) throw StateError('The committed message is absent.');
    return _clone(tree._exportMessage(node, const {}));
  }

  List<StChatDocument> exportChat(
    ChatStore store,
    String chatId, {
    String? fileName,
    Map<String, TavernUsage?> usageOverrides = const {},
  }) => _ExportTree(store, chatId, fileName, _createIntegrity, usageOverrides: usageOverrides).documents();
}

const _namespace = 'chatJsonl';
const _sourceKey = 'chatJsonlSourceFile';

final class _ExportJob {
  _ExportJob(
    this.path,
    this.header,
    this.proposedName,
    this.sourceFileName, {
    this.keepEmptyVariables = false,
    this.unusedTails = const {},
  });
  final List<StoredNode> path;
  final Map<String, Object?> header;
  final String proposedName;
  final String sourceFileName;
  final bool keepEmptyVariables;
  final Map<String, Object?> unusedTails;
  late String fileName;
}

final class _ExportTree {
  _ExportTree(
    this.store,
    this.chatId,
    this.requestedName,
    this.createIntegrity, {
    Map<String, TavernUsage?> usageOverrides = const {},
  }) : usageOverrides = Map.unmodifiable(usageOverrides) {
    chat = store.chat(chatId);
    nodes = store.allNodes(chatId);
    for (final node in nodes) {
      byId[node.message.nodeId] = node;
      children.putIfAbsent(node.message.parentId, () => []).add(node);
    }
    sourceFiles = _sourceFiles(chat.metadata);
  }
  final ChatStore store;
  final String chatId;
  final String? requestedName;
  final String Function() createIntegrity;
  final Map<String, TavernUsage?> usageOverrides;
  late final StoredChat chat;
  late final List<StoredNode> nodes;
  late final List<Map<String, Object?>> sourceFiles;
  final byId = <String, StoredNode>{};
  final children = <String?, List<StoredNode>>{};
  final states = <String, Map<String, Object?>>{};
  final aliases = <String, String>{};
  final branchLinks = <String, List<String>>{};

  Map<String, Object?> _state(StoredNode node) =>
      states.putIfAbsent(node.message.nodeId, () => _effectiveState(store, chatId, node));

  Map<String, Object?> _headerFor(StoredNode? node) {
    if (node != null) {
      final header = _sourceFor(chat.metadata, _state(node)[_sourceKey]);
      if (header != null) {
        return _sourceHeader(header);
      }
    }
    final own = _map(_map(chat.metadata['dshgo'])[_namespace]);
    for (final file in sourceFiles) {
      if (file['key'] == own['rootFile']) {
        return {..._sourceHeader(_map(file['header'])), 'chat_metadata': _clone(chat.metadata)};
      }
    }
    return {'user_name': 'unused', 'character_name': 'unused', 'chat_metadata': _clone(chat.metadata)};
  }

  List<StoredNode> _pathTo(String? leaf) {
    final reversed = <StoredNode>[];
    final visited = <String>{};
    var id = leaf;
    while (id != null) {
      if (!visited.add(id)) {
        throw StateError('The stored message tree contains a cycle.');
      }
      final node = byId[id];
      if (node == null) {
        throw StateError('The stored message path references an absent node.');
      }
      reversed.add(node);
      id = node.message.parentId;
    }
    return reversed.reversed.toList();
  }

  List<StoredNode> _retainedPath(Object? value) {
    final result = <StoredNode>[];
    if (value is! List<Object?>) {
      return result;
    }
    String? parent;
    for (final id in value) {
      final node = id is String ? byId[id] : null;
      if (node == null || node.message.parentId != parent) {
        break;
      }
      result.add(node);
      parent = node.message.nodeId;
    }
    return result;
  }

  List<StChatDocument> documents() {
    final current = _pathTo(chat.currentLeafId);
    var mainSource = -1;
    for (var index = 0; index < sourceFiles.length; index++) {
      final raw = sourceFiles[index]['path'];
      final retained = _retainedPath(raw);
      if (raw is List<Object?> && raw.length == retained.length && _samePath(retained, current)) {
        mainSource = index;
        break;
      }
    }
    final source = mainSource < 0 ? <String, Object?>{} : sourceFiles[mainSource];
    final mainHeader = source.isEmpty ? _headerFor(current.isEmpty ? null : current.last) : _map(source['header']);
    final mainName =
        requestedName ??
        (source['fileName'] as String?) ??
        (sourceFiles.isEmpty ? chat.title : _text(sourceFiles.first['fileName']));
    final jobs = <_ExportJob>[
      _ExportJob(
        current,
        mainHeader,
        mainName,
        _originalLabel(mainHeader, _text(source['fileName']).isEmpty ? mainName : _text(source['fileName'])),
        unusedTails: _map(source['unusedTails']),
      ),
    ];
    for (var index = 0; index < sourceFiles.length; index++) {
      if (index == mainSource) {
        continue;
      }
      final source = sourceFiles[index];
      final header = _map(source['header']);
      final name = _text(source['fileName']);
      jobs.add(
        _ExportJob(
          _retainedPath(source['path']),
          header,
          name,
          _originalLabel(header, name),
          keepEmptyVariables: source['path'] is List<Object?> && (source['path'] as List<Object?>).isEmpty,
          unusedTails: _map(source['unusedTails']),
        ),
      );
    }
    final covered = <String>{};
    void cover(List<StoredNode> path) {
      for (final node in path) {
        for (final sibling in children[node.message.parentId] ?? const <StoredNode>[]) {
          covered.add(sibling.message.nodeId);
        }
      }
    }

    for (final job in jobs) {
      cover(job.path);
    }
    for (final node in nodes) {
      if (covered.contains(node.message.nodeId)) {
        continue;
      }
      var end = node;
      final visited = <String>{};
      while ((children[end.message.nodeId] ?? const <StoredNode>[]).isNotEmpty) {
        if (!visited.add(end.message.nodeId)) {
          throw StateError('The remembered path contains a cycle.');
        }
        final selected = end.selectedChildId;
        final child = selected == null ? children[end.message.nodeId]!.first : byId[selected];
        if (child == null || child.message.parentId != end.message.nodeId) {
          throw StateError('The remembered selection is not a child of its node.');
        }
        end = child;
      }
      final path = _pathTo(end.message.nodeId);
      final name = '${_stem(mainName)}-branch-${jobs.length}';
      jobs.add(_ExportJob(path, _headerFor(end), name, name));
      cover(path);
    }
    final usedNames = <String>{};
    for (final job in jobs) {
      job.fileName = _portableFileName(job.proposedName, usedNames);
      for (final old in [job.proposedName, job.sourceFileName]) {
        final stem = _stem(old);
        if (stem.isNotEmpty && stem != '.' && stem != '..' && !stem.contains('\u0000')) {
          aliases.putIfAbsent(_fileKey(old), () => _stem(job.fileName));
        }
      }
    }
    for (final job in jobs.skip(1)) {
      var common = 0;
      while (common < current.length &&
          common < job.path.length &&
          current[common].message.nodeId == job.path[common].message.nodeId) {
        common++;
      }
      final anchor = common < current.length
          ? current[common]
          : current.isEmpty
          ? null
          : current.last;
      if (anchor != null) {
        branchLinks.putIfAbsent(anchor.message.nodeId, () => []).add(_stem(job.fileName));
      }
    }
    final integrities = <String>{};
    return [
      for (var index = 0; index < jobs.length; index++)
        StChatDocument(
          fileName: jobs[index].fileName,
          header: _exportHeader(jobs[index], jobs.first.fileName, index == 0, integrities),
          messages: [for (final node in jobs[index].path) _exportMessage(node, jobs[index].unusedTails)],
        ),
    ];
  }

  Map<String, Object?> _exportHeader(_ExportJob job, String mainName, bool isMain, Set<String> integrities) {
    final result = _sourceHeader(job.header);
    var metadata = _map(result['chat_metadata']);
    if (isMain &&
        (job.path.isEmpty || _canonical(_contextMetadata(metadata)) == _canonical(_contextMetadata(chat.metadata)))) {
      metadata = _map(_sourceHeader({'chat_metadata': chat.metadata})['chat_metadata']);
    }
    if (job.path.isNotEmpty) {
      final state = _state(job.path.last);
      final variables = state['variables'];
      metadata.remove('variables');
      if (variables is Map<String, Object?>) {
        metadata['variables'] = _clone(variables);
      } else if (isMain && chat.variables.isNotEmpty) {
        metadata['variables'] = _clone(chat.variables);
      }
      _projectRuntimeState(metadata, state);
    } else if (isMain) {
      final hadVariables = metadata['variables'] is Map<String, Object?>;
      metadata.remove('variables');
      if (hadVariables || chat.variables.isNotEmpty) {
        metadata['variables'] = _clone(chat.variables);
      }
    } else if (!job.keepEmptyVariables) {
      metadata.remove('variables');
    }
    final dshgo = _map(metadata['dshgo']);
    if (isMain) {
      final latest = _map(chat.metadata['dshgo']);
      if (latest.containsKey('latestInspection')) {
        dshgo['latestInspection'] = latest['latestInspection'];
      }
    }
    dshgo[_namespace] = {
      ..._map(dshgo[_namespace]),
      'version': 1,
      'path': [for (final node in job.path) node.message.nodeId],
      'sourceFileName': job.sourceFileName,
      'runtimeContext': _canonical(_contextMetadata(metadata)),
    };
    metadata['dshgo'] = dshgo;
    final integrity = createIntegrity();
    if (integrity.isEmpty || integrity == metadata['integrity'] || !integrities.add(integrity)) {
      throw StateError('The integrity generator must return a fresh, nonempty value for every file.');
    }
    metadata['integrity'] = integrity;
    if (isMain) {
      metadata.remove('main_chat');
    } else {
      metadata['main_chat'] = _stem(mainName);
    }
    result['chat_metadata'] = metadata;
    return result;
  }

  Map<String, Object?> _messageFields(StoredNode node) {
    final result = _clone(node.original)..removeWhere((key, _) => _messageContainers.contains(key));
    final message = node.message;
    result.addAll({
      'name': message.speaker,
      'is_user': message.role == TavernRole.user,
      'is_system': message.hidden || message.role == TavernRole.system,
    });
    return result;
  }

  Map<String, Object?> _dates(StoredNode node) => {
    'send_date': node.original.containsKey('send_date')
        ? node.original['send_date']
        : node.message.at.toUtc().toIso8601String(),
    for (final key in ['gen_started', 'gen_finished'])
      if (node.original.containsKey(key)) key: node.original[key],
  };

  int _originalIndex(StoredNode node) {
    final value = node.original['swipe_id'];
    return value is num && value.isFinite && value >= 0 && value == value.roundToDouble() ? value.toInt() : 0;
  }

  String _rawSwipe(StoredNode node) {
    final swipes = node.original['swipes'];
    final index = _originalIndex(node);
    if (node.message.text == _text(node.original['mes']) &&
        swipes is List<Object?> &&
        index < swipes.length &&
        swipes[index] is String) {
      return swipes[index] as String;
    }
    return node.message.text;
  }

  Object? _link(Object? value) {
    if (value is! String) {
      return value;
    }
    final stem = _stem(value);
    if (stem.isEmpty || stem == '.' || stem == '..' || stem.contains('\u0000')) {
      return value;
    }
    return aliases[_fileKey(value)] ?? value;
  }

  Map<String, Object?> _extra(StoredNode node) {
    final result = _clone(node.extra);
    if (node.message.reasoning == null) {
      result.remove('reasoning');
    } else {
      result['reasoning'] = node.message.reasoning;
    }
    if (result['branches'] is List<Object?>) {
      result['branches'] = (result['branches'] as List<Object?>).map(_link).toList();
    }
    if (result.containsKey('bookmark_link')) {
      result['bookmark_link'] = _link(result['bookmark_link']);
    }
    final added = branchLinks[node.message.nodeId];
    if (added != null && (result['branches'] == null || result['branches'] is List<Object?>)) {
      final links = List<Object?>.of(result['branches'] as List<Object?>? ?? const []);
      for (final value in added) {
        if (!links.contains(value)) links.add(value);
      }
      result['branches'] = links;
    }
    final dshgo = _map(result['dshgo']);
    final own = _map(dshgo[_namespace]);
    if (own.isNotEmpty && own['version'] != 1) {
      throw StateError('Unsupported stored dshgo.chatJsonl version.');
    }
    own.remove('speakerCharacterId');
    final state = _state(node);
    own.addAll({
      'version': 1,
      'nodeId': node.message.nodeId,
      'selectedChildId': node.selectedChildId,
      'message': _messageFields(node),
      'text': node.message.text,
      'role': node.message.role.name,
      'speakerCharacterId': ?node.message.speakerCharacterId,
      'hidden': node.message.hidden,
      'usage': _usageJson(
        usageOverrides.containsKey(node.message.nodeId) ? usageOverrides[node.message.nodeId] : node.message.usage,
      ),
      'at': node.message.at.toUtc().toIso8601String(),
      'hasMessageVariables': state.containsKey('messageVariables'),
      'sourceHeader': _runtimeSourceHeader(_headerFor(node)),
    });
    if (own.containsKey('opaqueInspection') && !dshgo.containsKey('inspection')) {
      dshgo['inspection'] = own['opaqueInspection'];
    }
    dshgo.addAll({_namespace: own, 'tavernState': _clone(state)});
    result['dshgo'] = dshgo;
    return result;
  }

  Map<String, Object?> _swipeInfo(StoredNode node) {
    final infos = node.original['swipe_info'];
    final index = _originalIndex(node);
    final result = infos is List<Object?> && index < infos.length ? _map(infos[index]) : <String, Object?>{};
    for (final key in _swipeFields) {
      result.remove(key);
    }
    result.addAll({..._dates(node), 'extra': _extra(node)});
    return result;
  }

  Map<String, Object?> _exportMessage(StoredNode node, Map<String, Object?> unusedTails) {
    final family = children[node.message.parentId]!;
    final result = {
      ..._messageFields(node),
      'mes': node.message.text,
      ..._dates(node),
      'extra': _extra(node),
      'swipe_id': family.indexOf(node),
      'swipes': [for (final sibling in family) _rawSwipe(sibling)],
      'swipe_info': <Object?>[for (final sibling in family) _swipeInfo(sibling)],
    };
    // An explicit empty source tail overrides another file's original. Older
    // catalogues and generated paths without a source row keep the fallback.
    final savedTails = unusedTails[node.message.nodeId];
    final tails = savedTails is Map<String, Object?> ? savedTails : _unusedMessageTails(node.original);
    final infoTail = tails['swipe_info'];
    if (infoTail is List<Object?>) {
      (result['swipe_info'] as List<Object?>).addAll(infoTail);
    }
    final variableTail = tails['variables'];
    if (family.any((sibling) => _state(sibling).containsKey('messageVariables')) ||
        node.original['variables'] is List<Object?> ||
        variableTail is List<Object?> && variableTail.isNotEmpty) {
      result['variables'] = <Object?>[
        for (final sibling in family) _state(sibling)['messageVariables'],
        if (variableTail is List<Object?>) ...variableTail,
      ];
    }
    return result;
  }
}

Map<String, Object?> _unusedMessageTails(Map<String, Object?> message) {
  final swipes = message['swipes'];
  final count = swipes is List<Object?> ? swipes.length : 1;
  return _clone({
    for (final key in ['swipe_info', 'variables'])
      key: message[key] is List<Object?> ? (message[key] as List<Object?>).skip(count).toList() : <Object?>[],
  });
}

bool _samePath(List<StoredNode> first, List<StoredNode> second) =>
    first.length == second.length &&
    List.generate(
      first.length,
      (index) => first[index].message.nodeId == second[index].message.nodeId,
    ).every((equal) => equal);

String _originalLabel(Map<String, Object?> header, String fallback) {
  final own = _map(_map(_map(header['chat_metadata'])['dshgo'])[_namespace]);
  return own['sourceFileName'] is String ? own['sourceFileName'] as String : fallback;
}

String _portableFileName(String value, Set<String> used) {
  var stem = _stem(value).replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim().replaceFirst(RegExp(r'[. ]+$'), '');
  if (stem.isEmpty || stem == '.' || stem == '..') {
    stem = 'chat';
  }
  if (RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)', caseSensitive: false).hasMatch(stem)) {
    stem = '_$stem';
  }
  stem = String.fromCharCodes(stem.runes.take(100));
  String withSuffix(String suffix) {
    // Keep the complete name within 255 UTF-8 bytes, including
    // its extension and collision suffix. Never split a Unicode code point.
    var remaining = 255 - utf8.encode('$suffix.jsonl').length;
    final prefix = StringBuffer();
    for (final rune in stem.runes) {
      final character = String.fromCharCode(rune);
      final size = utf8.encode(character).length;
      if (size > remaining) {
        break;
      }
      prefix.write(character);
      remaining -= size;
    }
    return '$prefix$suffix.jsonl';
  }

  var name = withSuffix('');
  var suffix = 2;
  while (!used.add(name.toLowerCase())) {
    name = withSuffix('-${suffix++}');
  }
  return name;
}

final class _SourceFile {
  _SourceFile(this.document, DateTime fallbackDate, List<String> notices)
    : key = _fileKey(document.fileName, lineNumber: document.headerLineNumber),
      metadata = _checkedMetadata(document) {
    final parent = metadata['main_chat'];
    if (parent != null && parent is! String) {
      _error(document, document.headerLineNumber, 'main_chat must be text.');
    }
    try {
      parentKey = parent is String && parent.isNotEmpty ? _fileKey(parent) : null;
    } on StChatFormatException {
      _error(document, document.headerLineNumber, 'main_chat must identify a nonempty filename label.');
    }
    context = _canonical(_contextMetadata(metadata));
    runtimeHeader = _runtimeSourceHeader(document.header);
    unchangedRuntimeContext = _sameRuntimeContext(
      _view(_view(metadata['dshgo'])[_namespace])['runtimeContext'],
      metadata,
    );
    for (var index = 0; index < document.messages.length; index++) {
      lines.add(_SourceLine(this, index, fallbackDate, notices));
    }
  }
  final StChatDocument document;
  final String key;
  final Map<String, Object?> metadata;
  String? parentKey;
  late String rootKey;
  late String context;
  late final Map<String, Object?> runtimeHeader;
  late final bool unchangedRuntimeContext;
  final lines = <_SourceLine>[];
  final path = <_ImportNode>[];
}

List<_SourceFile> _orderFiles(Map<String, _SourceFile> files, List<String> notices) {
  final result = <_SourceFile>[];
  final done = <String>{};
  for (final start in files.values) {
    if (done.contains(start.key)) {
      continue;
    }
    final chain = <_SourceFile>[];
    final visiting = <String>{};
    _SourceFile? current = start;
    while (current != null && !done.contains(current.key)) {
      if (!visiting.add(current.key)) {
        _error(current.document, current.document.headerLineNumber, 'main_chat contains a cycle.');
      }
      chain.add(current);
      final parentKey = current.parentKey;
      if (parentKey != null && !files.containsKey(parentKey)) {
        notices.add(
          '${current.document.fileName}:${current.document.headerLineNumber}: '
          'Parent chat is absent from this batch; imported independently.',
        );
      }
      current = files[parentKey];
    }
    for (final file in chain.reversed) {
      done.add(file.key);
      result.add(file);
    }
  }
  return result;
}

final class _SourceLine {
  _SourceLine(this.file, this.index, DateTime fallbackDate, List<String> notices) {
    final raw = file.document.messages[index];
    final physicalLine = file.document.messageLines[index];
    for (final key in ['name', 'mes']) {
      if (raw[key] != null && raw[key] is! String) {
        _error(file.document, physicalLine, '$key must be text.');
      }
    }
    for (final key in ['is_user', 'is_system']) {
      if (raw[key] != null && raw[key] is! bool) {
        _error(file.document, physicalLine, '$key must be boolean.');
      }
    }
    final swipeValue = raw['swipes'];
    if (swipeValue != null &&
        (swipeValue is! List<Object?> || swipeValue.isEmpty || swipeValue.any((v) => v is! String))) {
      _error(file.document, physicalLine, 'swipes must be a nonempty array of strings.');
    }
    final swipes = swipeValue == null ? <String>[_text(raw['mes'])] : (swipeValue as List<Object?>).cast<String>();
    selected = raw['swipe_id'] == null ? 0 : _index(raw['swipe_id'], file.document, physicalLine, 'swipe_id');
    if (selected < 0 || selected >= swipes.length) {
      _error(file.document, physicalLine, 'swipe_id is out of range.');
    }
    for (final key in ['swipe_info', 'variables']) {
      if (raw[key] != null && raw[key] is! List<Object?>) {
        _error(file.document, physicalLine, '$key must be an array.');
      }
    }
    final infos = raw['swipe_info'] as List<Object?>? ?? const [];
    for (final info in infos) {
      if (info != null && info is! Map<String, Object?>) {
        _error(file.document, physicalLine, 'swipe_info entries must be objects.');
      }
    }
    for (var swipe = 0; swipe < swipes.length; swipe++) {
      variants.add(
        _Variant(this, swipe, swipes[swipe], swipe < infos.length ? infos[swipe] : null, fallbackDate, notices),
      );
    }
  }
  final _SourceFile file;
  final int index;
  late final int selected;
  final variants = <_Variant>[];
}

final class _Variant {
  _Variant(_SourceLine line, int swipe, this.rawSwipe, Object? infoValue, DateTime fallbackDate, List<String> notices) {
    final file = line.file;
    final raw = file.document.messages[line.index];
    final number = file.document.messageLines[line.index];
    final isSelected = swipe == line.selected;
    info = _map(infoValue);
    extra = _checkedMap(isSelected ? raw['extra'] : info['extra'], file.document, number, 'extra');
    final dshgo = _checkedMap(extra['dshgo'], file.document, number, 'extra.dshgo');
    final own = _checkedEnvelope(dshgo[_namespace], file.document, number);
    final ownHeader = own['version'] == 1 ? own['sourceHeader'] : null;
    final rawHeader = ownHeader is Map<String, Object?> && (!isSelected || file.unchangedRuntimeContext)
        ? ownHeader
        : file.runtimeHeader;
    final sourceMetadata = _checkedMap(rawHeader['chat_metadata'], file.document, number, 'source chat_metadata');
    _validateMetadataFields(sourceMetadata, file.document, number);
    final sourceDshgo = _checkedMap(sourceMetadata['dshgo'], file.document, number, 'source chat_metadata.dshgo');
    _checkedEnvelope(sourceDshgo[_namespace], file.document, number);
    sourceHeader = _runtimeSourceHeader(rawHeader);
    final portable = own['version'] == 1 ? _map(own['message']) : <String, Object?>{};
    for (final key in ['name']) {
      if (portable[key] != null && portable[key] is! String) {
        _error(file.document, number, 'Portable $key must be text.');
      }
    }
    for (final key in ['is_user', 'is_system']) {
      if (portable[key] != null && portable[key] is! bool) {
        _error(file.document, number, 'Portable $key must be boolean.');
      }
    }
    original = _clone(raw);
    if (!isSelected && own['message'] is Map<String, Object?>) {
      original.removeWhere((key, _) => !_messageContainers.contains(key));
      for (final entry in portable.entries) {
        if (!_messageContainers.contains(entry.key)) {
          original[entry.key] = entry.value;
        }
      }
    }
    text = isSelected
        ? _text(raw['mes'])
        : own['version'] == 1 && own['text'] is String
        ? own['text'] as String
        : rawSwipe;
    original['mes'] = text;
    original['swipe_id'] = swipe;
    for (final field in ['send_date', 'gen_started', 'gen_finished']) {
      if (!isSelected) {
        if (info.containsKey(field)) {
          original[field] = info[field];
        } else if (infoValue == null &&
            raw.containsKey(field) &&
            (field == 'send_date' || raw['is_user'] != true && !_truthy(_map(raw['extra'])['isSmallSys']))) {
          original[field] = raw[field];
        } else {
          original.remove(field);
        }
      }
    }
    name = _text(original['name']);
    final user = original['is_user'] == true;
    final roleName = own['version'] == 1 ? own['role'] : null;
    // A portable character/system role takes precedence over the ST type hint.
    role = user
        ? TavernRole.user
        : roleName == 'narrator' || (extra['type'] == 'narrator' && roleName != 'character' && roleName != 'system')
        ? TavernRole.narrator
        : roleName == 'system'
        ? TavernRole.system
        : TavernRole.character;
    hidden = original['is_system'] == true;
    speakerCharacterId = role == TavernRole.character ? own['speakerCharacterId'] as String? : null;
    if (role == TavernRole.system && own['hidden'] is bool) {
      hidden = own['hidden'] as bool;
    }
    // is_system is ST's exclusion flag. Its mapped owner is hidden, so the
    // original JSON must not keep a sticky flag that defeats a later unhide.
    original.remove('is_system');
    final reason = extra['reasoning'];
    if (reason != null && reason is! String) {
      _error(file.document, number, 'extra.reasoning must be text.');
    }
    reasoning = reason as String?;
    final parsedDate = _date(original['send_date']);
    final portableDate = own['version'] == 1 ? _date(own['at']) : null;
    at = parsedDate ?? portableDate ?? fallbackDate;
    if (parsedDate == null && original.containsKey('send_date')) {
      notices.add(
        '${file.document.fileName}:$number: Unrecognized send_date; retained verbatim, internal time uses '
        '${portableDate == null ? 'import time' : 'the portable timestamp'}.',
      );
    }
    state = _checkedMap(dshgo['tavernState'], file.document, number, 'extra.dshgo.tavernState');
    if (state['variables'] != null && state['variables'] is! Map<String, Object?>) {
      _error(file.document, number, 'State variables must be an object.');
    }
    if (state.containsKey('stChatId') && state['stChatId'] is! String) {
      _error(file.document, number, 'State stChatId must be text.');
    }
    final cachedHash = state['stChatIdHash'];
    if (cachedHash != null && (cachedHash is! num || !cachedHash.isFinite)) {
      _error(file.document, number, 'State stChatIdHash must be a finite number or null.');
    }
    state.putIfAbsent('stChatId', () {
      final parent = sourceMetadata['main_chat'] ?? file.metadata['main_chat'];
      return parent is String ? parent : _stem(_originalLabel(file.document.header, file.document.fileName));
    });
    // The adopted historical header can differ from the file's final header.
    // A present null marker deliberately does not fall back to either header.
    state.putIfAbsent('stChatIdHash', () => sourceMetadata['chat_id_hash']);
    final effectiveContext = _contextMetadata(sourceMetadata);
    _projectHash(effectiveContext, state);
    context = _canonical(effectiveContext);
    final variables = raw['variables'] as List<Object?>?;
    if (variables != null &&
        swipe < variables.length &&
        !(own['version'] == 1 && own['hasMessageVariables'] == false && variables[swipe] == null)) {
      state['messageVariables'] = variables[swipe];
    }
    if (isSelected && line.index + 1 == file.document.messages.length) {
      if (!state.containsKey('variables') && file.metadata['variables'] is Map<String, Object?>) {
        state['variables'] = _map(file.metadata['variables']);
      }
      for (final key in _terminalStateKeys) {
        if (!state.containsKey(key) && file.metadata.containsKey(key)) {
          state[key] = file.metadata[key];
        }
      }
    }
    state[_sourceKey] = file.key;
    usage = own['version'] == 1 ? _usage(own['usage'], file.document, number) : null;
    token = own['version'] == 1 && own['nodeId'] is String ? own['nodeId'] as String : null;
    hasChoice =
        own['version'] == 1 &&
        own.containsKey('selectedChildId') &&
        (own['selectedChildId'] == null || own['selectedChildId'] is String);
    childToken = hasChoice ? own['selectedChildId'] as String? : null;
    original['extra'] = _clone(extra);
    extra = _quarantineExtra(extra);
    fingerprint = _canonical({
      'message': _messageIdentity(original),
      'extra': _extraIdentity(extra),
      'swipeInfo': {
        for (final entry in info.entries)
          if (!_swipeFields.contains(entry.key)) entry.key: entry.value,
      },
      'role': role.name,
      'speakerCharacterId': speakerCharacterId,
      'hidden': hidden,
      'rawSwipe': rawSwipe,
      'usage': _usageJson(usage),
    });
  }
  final String rawSwipe;
  late Map<String, Object?> original;
  late Map<String, Object?> info;
  late Map<String, Object?> extra;
  late Map<String, Object?> state;
  late String text;
  late String name;
  late String? speakerCharacterId;
  late TavernRole role;
  late bool hidden;
  late String? reasoning;
  late DateTime at;
  late TavernUsage? usage;
  late String? token;
  late String? childToken;
  late bool hasChoice;
  late String fingerprint;
  late String context;
  late Map<String, Object?> sourceHeader;
}

const _messageContainers = {
  'swipes',
  'swipe_id',
  'swipe_info',
  'variables',
  'extra',
  'mes',
  'send_date',
  'gen_started',
  'gen_finished',
};
const _swipeFields = {'send_date', 'gen_started', 'gen_finished', 'extra'};

final class _ImportNode {
  _ImportNode(this.id, this.parent, this.variant, String source)
    : state = {..._clone(variant.state), _sourceKey: source},
      extra = _clone(variant.extra);
  final String id;
  final String? parent;
  final _Variant variant;
  final Map<String, Object?> state;
  final Map<String, Object?> extra;
}

final class _ImportTree {
  _ImportTree(this.root);
  final _SourceFile root;
  final files = <_SourceFile>[];
  final nodes = <_ImportNode>[];
  final byId = <String, _ImportNode>{};
  final siblings = <String?, List<_ImportNode>>{};
  final choices = <String, String?>{};
  final assigned = <String>{};
  final sources = <String, Map<String, Object?>>{};
  final sourceContexts = <String, String>{};
  final tokens = <String, List<_ImportNode>>{};
  final hints = <(_ImportNode, String?, String)>[];
  String? selectedRoot;

  String _source(_Variant variant, _SourceFile file) => sourceContexts.putIfAbsent(variant.context, () {
    var key = file.key;
    var suffix = sources.length;
    while (sources.containsKey(key)) {
      key = '@source-${suffix++}';
    }
    sources[key] = _sourceHeader(variant.sourceHeader);
    return key;
  });

  void add(_SourceFile file, _SourceFile? parentFile, List<String> notices) {
    files.add(file);
    if (parentFile != null && parentFile.context != file.context) {
      notices.add(
        '${file.document.fileName}:${file.document.headerLineNumber}: '
        'Different source metadata is retained as a separate tree context.',
      );
    }
    String? parent;
    for (var index = 0; index < file.lines.length; index++) {
      final line = file.lines[index];
      final candidates = siblings.putIfAbsent(parent, () => []);
      final used = <String>{};
      final family = <_ImportNode>[];
      for (final variant in line.variants) {
        _ImportNode? node;
        for (final candidate in candidates) {
          if (!used.contains(candidate.id) && _compatible(candidate, variant)) {
            node = candidate;
            break;
          }
        }
        if (node == null) {
          node = _ImportNode('n${nodes.length}', parent, variant, _source(variant, file));
          nodes.add(node);
          byId[node.id] = node;
          choices[node.id] = null;
          candidates.add(node);
        } else {
          for (final entry in variant.state.entries) {
            if (entry.key != _sourceKey) {
              node.state.putIfAbsent(entry.key, () => entry.value);
            }
          }
          _mergeNavigation(node.extra, variant.extra);
        }
        used.add(node.id);
        family.add(node);
        final token = variant.token;
        if (token != null) {
          final matches = tokens.putIfAbsent(token, () => []);
          if (!matches.contains(node)) {
            matches.add(node);
          }
        }
        if (variant.hasChoice) {
          hints.add((node, variant.childToken, file.document.fileName));
        }
      }
      final selected = family[line.selected];
      file.path.add(selected);
      parent = selected.id;
    }
    for (var index = 0; index < file.path.length; index++) {
      final node = file.path[index];
      if (assigned.add(node.id)) {
        choices[node.id] = index + 1 < file.path.length ? file.path[index + 1].id : null;
      }
    }
  }

  void finish(List<String> notices) {
    final restored = <String>{};
    for (final (node, childToken, source) in hints) {
      if (restored.contains(node.id)) {
        continue;
      }
      if (childToken == null) {
        choices[node.id] = null;
        restored.add(node.id);
        continue;
      }
      final matches = (tokens[childToken] ?? const <_ImportNode>[])
          .where((candidate) => candidate.parent == node.id)
          .toList();
      if (matches.length == 1) {
        choices[node.id] = matches.single.id;
        restored.add(node.id);
      } else {
        notices.add('$source: Saved child selection is absent or ambiguous; the imported file path is used.');
      }
    }
    for (final file in files) {
      final own = _map(_map(file.metadata['dshgo'])[_namespace]);
      final oldPath = own['path'];
      if (oldPath is! List<Object?>) {
        continue;
      }
      final selectedTokens = [for (final line in file.lines) line.variants[line.selected].token];
      if (_canonical(oldPath) == _canonical(selectedTokens)) {
        continue;
      }
      // ST may select another swipe or truncate an exported branch. Its actual
      // path then wins over this file's old portable selection hints.
      for (var index = 0; index < file.path.length; index++) {
        choices[file.path[index].id] = index + 1 < file.path.length ? file.path[index + 1].id : null;
      }
    }
    // Actual primary JSONL swipes/path win over stale extension selections
    // when an exported file was subsequently edited by ST.
    selectedRoot = root.path.isEmpty ? null : root.path.first.id;
    for (var index = 0; index < root.path.length; index++) {
      choices[root.path[index].id] = index + 1 < root.path.length ? root.path[index + 1].id : null;
    }
  }

  _ImportNode? get currentLeaf {
    var id = selectedRoot;
    while (id != null && choices[id] != null) {
      id = choices[id];
    }
    return byId[id];
  }
}

bool _compatible(_ImportNode node, _Variant variant) {
  if (node.variant.fingerprint != variant.fingerprint) {
    return false;
  }
  final beforeState = _clone(node.state)..remove(_sourceKey);
  final afterState = _clone(variant.state)..remove(_sourceKey);
  final beforeContext = _contextMetadata(_map(node.variant.sourceHeader['chat_metadata']));
  final afterContext = _contextMetadata(_map(variant.sourceHeader['chat_metadata']));
  _projectHash(beforeContext, beforeState);
  _projectHash(afterContext, afterState);
  final beforeHash = beforeContext['chat_id_hash'];
  final afterHash = afterContext['chat_id_hash'];
  if (beforeHash is num && afterHash is num && beforeHash == afterHash) {
    // Integral doubles and integers denote the same ST numeric cache. Only
    // nonzero caches make both macro engines independent of the raw identity.
    beforeContext.remove('chat_id_hash');
    afterContext.remove('chat_id_hash');
    beforeState.remove('stChatIdHash');
    afterState.remove('stChatIdHash');
    if (beforeHash != 0) {
      beforeState.remove('stChatId');
      afterState.remove('stChatId');
    }
  }
  if (_canonical(beforeContext) != _canonical(afterContext)) {
    return false;
  }
  if (_canonical(beforeState) != _canonical(afterState)) {
    return false;
  }
  final before = node.extra['bookmark_link'];
  final after = variant.extra['bookmark_link'];
  return before == null || after == null || _canonical(before) == _canonical(after);
}

void _mergeNavigation(Map<String, Object?> target, Map<String, Object?> incoming) {
  final before = target['branches'];
  final after = incoming['branches'];
  if (before is List<Object?> && after is List<Object?>) {
    final merged = List<Object?>.of(before);
    for (final value in after) {
      if (!merged.any((existing) => _canonical(existing) == _canonical(value))) {
        merged.add(value);
      }
    }
    target['branches'] = merged;
  } else if (before == null && after != null) {
    target['branches'] = after;
  }
  if (target['bookmark_link'] == null && incoming['bookmark_link'] != null) {
    target['bookmark_link'] = incoming['bookmark_link'];
  }
}

Map<String, Object?> _checkedMetadata(StChatDocument document) {
  final line = document.headerLineNumber;
  final metadata = _checkedMap(document.header['chat_metadata'], document, line, 'chat_metadata');
  _validateMetadataFields(metadata, document, line);
  final dshgo = _checkedMap(metadata['dshgo'], document, line, 'chat_metadata.dshgo');
  _checkedEnvelope(dshgo[_namespace], document, line);
  return metadata;
}

void _validateMetadataFields(Map<String, Object?> metadata, StChatDocument document, int line) {
  for (final key in ['scenario', 'system_prompt', 'mes_example', 'world_info', 'note_prompt']) {
    if (metadata[key] != null && metadata[key] is! String) {
      _error(document, line, 'chat_metadata.$key must be text.');
    }
  }
  for (final key in ['chat_id_hash', 'note_interval', 'note_depth', 'note_position', 'note_role']) {
    final value = metadata[key];
    if (value != null && (value is! num || !value.isFinite)) {
      _error(document, line, 'chat_metadata.$key must be a finite number.');
    }
  }
  _checkedMap(metadata['variables'], document, line, 'chat_metadata.variables');
}

Map<String, Object?> _checkedEnvelope(Object? value, StChatDocument document, int line) {
  final result = _checkedMap(value, document, line, 'dshgo.chatJsonl');
  if (result.isNotEmpty && result['version'] != 1) {
    _error(document, line, 'Unsupported dshgo.chatJsonl version; no part of this batch was imported.');
  }
  for (final key in [
    'nodeId',
    'selectedChildId',
    'speakerCharacterId',
    'text',
    'at',
    'sourceFileName',
    'runtimeContext',
  ]) {
    if (result[key] != null && result[key] is! String) {
      _error(document, line, 'chatJsonl.$key must be text.');
    }
  }
  for (final key in ['message', 'sourceHeader', 'usage']) {
    if (result[key] != null && result[key] is! Map<String, Object?>) {
      _error(document, line, 'chatJsonl.$key must be an object.');
    }
  }
  for (final key in ['hidden', 'hasMessageVariables']) {
    if (result[key] != null && result[key] is! bool) {
      _error(document, line, 'chatJsonl.$key must be boolean.');
    }
  }
  if (result['role'] != null && !TavernRole.values.any((role) => role.name == result['role'])) {
    _error(document, line, 'Unknown chatJsonl.role.');
  }
  if (result['path'] != null &&
      (result['path'] is! List<Object?> || (result['path'] as List<Object?>).any((id) => id is! String))) {
    _error(document, line, 'chatJsonl.path must be an array of node labels.');
  }
  return result;
}

Map<String, Object?> _checkedMap(Object? value, StChatDocument document, int line, String field) {
  if (value == null) {
    return {};
  }
  if (value is Map<String, Object?>) {
    return _clone(value);
  }
  _error(document, line, '$field must be an object.');
}

Never _error(StChatDocument document, int line, String message) =>
    throw StChatFormatException(document.fileName, line, message);

int _index(Object? value, StChatDocument document, int line, String field) {
  if (value is num && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  _error(document, line, '$field must be an integer.');
}

String _text(Object? value) => value is String ? value : '';
bool _truthy(Object? value) => value != null && value != false && value != 0 && value != '';
Map<String, Object?> _clone(Map<String, Object?> value) => jsonDecode(jsonEncode(value)) as Map<String, Object?>;
Map<String, Object?> _map(Object? value) => value is Map<String, Object?> ? _clone(value) : {};
Map<String, Object?> _view(Object? value) => value is Map<String, Object?> ? value : const {};
String _canonical(Object? value) => jsonEncode(_ordered(value));
Object? _ordered(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _ordered(value[key])};
  }
  if (value is List<Object?>) {
    return value.map(_ordered).toList();
  }
  return value;
}

String _stem(String fileName) {
  final leaf = fileName.replaceAll('\\', '/').split('/').last;
  return leaf.replaceFirst(RegExp(r'\.jsonl$', caseSensitive: false), '');
}

String _fileKey(String fileName, {int lineNumber = 1}) {
  final stem = _stem(fileName);
  if (stem.isEmpty || stem == '.' || stem == '..' || stem.contains('\u0000')) {
    throw StChatFormatException(fileName, lineNumber, 'Expected a nonempty filename.');
  }
  // Case-insensitive labels avoid ambiguous batches from Windows exports.
  return stem.toLowerCase();
}

Map<String, Object?> _messageIdentity(Map<String, Object?> message) => {
  for (final entry in message.entries)
    if (!const {'swipes', 'swipe_id', 'swipe_info', 'variables', 'extra'}.contains(entry.key)) entry.key: entry.value,
};

Map<String, Object?> _extraIdentity(Map<String, Object?> extra) {
  final result = _clone(extra)..remove('bookmark_link');
  if (result['branches'] == null || result['branches'] is List<Object?>) {
    result.remove('branches');
  }
  final dshgo = _map(result['dshgo']);
  dshgo.remove('tavernState');
  final own = _map(dshgo[_namespace]);
  for (final key in [
    'version',
    'nodeId',
    'selectedChildId',
    'message',
    'text',
    'role',
    'hidden',
    'usage',
    'sourceHeader',
    'at',
    'hasMessageVariables',
  ]) {
    own.remove(key);
  }
  if (own.isEmpty) {
    dshgo.remove(_namespace);
  } else {
    dshgo[_namespace] = own;
  }
  if (dshgo.isEmpty) {
    result.remove('dshgo');
  } else {
    result['dshgo'] = dshgo;
  }
  return result;
}

Map<String, Object?> _contextMetadata(Map<String, Object?> metadata) {
  final result = _map(_sourceHeader({'chat_metadata': metadata})['chat_metadata'])
    ..remove('integrity')
    ..remove('main_chat')
    ..remove('variables');
  for (final key in _terminalStateKeys) {
    result.remove(key);
  }
  final dshgo = _map(result['dshgo'])..remove('latestInspection');
  final own = _map(dshgo[_namespace])
    ..remove('sourceFileName')
    ..remove('version');
  if (own.isEmpty) {
    dshgo.remove(_namespace);
  } else {
    dshgo[_namespace] = own;
  }
  if (dshgo.isEmpty) {
    result.remove('dshgo');
  } else {
    result['dshgo'] = dshgo;
  }
  return result;
}

// Older v1 signatures included file-terminal world-info state. Compare both
// sides through today's projection without ignoring actual configuration.
bool _sameRuntimeContext(Object? signature, Map<String, Object?> metadata) {
  if (signature is! String) return false;
  try {
    final decoded = jsonDecode(signature);
    return decoded is Map<String, Object?> &&
        _canonical(_contextMetadata(decoded)) == _canonical(_contextMetadata(metadata));
  } on FormatException {
    return false;
  }
}

const _terminalStateKeys = ['timedWorldInfo', 'decoratorState', 'greetingIndex'];

void _projectHash(Map<String, Object?> metadata, Map<String, Object?> state) {
  if (!state.containsKey('stChatIdHash')) return;
  final value = state['stChatIdHash'];
  if (value == null) {
    metadata.remove('chat_id_hash');
  } else {
    metadata['chat_id_hash'] = value;
  }
}

void _projectRuntimeState(Map<String, Object?> metadata, Map<String, Object?> state) {
  for (final key in _terminalStateKeys) {
    metadata.remove(key);
    if (state.containsKey(key)) {
      metadata[key] = state[key];
    }
  }
  _projectHash(metadata, state);
}

Map<String, Object?> _sourceHeader(Map<String, Object?> header, {bool keepSourceFileName = false}) {
  final result = _clone(header);
  final metadata = _map(result['chat_metadata']);
  final dshgo = _map(metadata['dshgo']);
  final own = _map(dshgo[_namespace]);
  if (own.containsKey('opaqueLatestInspection') && !dshgo.containsKey('latestInspection')) {
    dshgo['latestInspection'] = own['opaqueLatestInspection'];
  }
  for (final key in [
    'version',
    'files',
    'sources',
    'rootFile',
    'path',
    'selectedRootId',
    'opaqueLatestInspection',
    'runtimeContext',
  ]) {
    own.remove(key);
  }
  if (!keepSourceFileName) {
    own.remove('sourceFileName');
  }
  if (own.isEmpty) {
    dshgo.remove(_namespace);
  } else {
    dshgo[_namespace] = {'version': 1, ...own};
  }
  if (dshgo.isEmpty && !metadata.containsKey('dshgo')) {
    metadata.remove('dshgo');
  } else {
    metadata['dshgo'] = dshgo;
  }
  if (result.containsKey('chat_metadata') || metadata.isNotEmpty) {
    result['chat_metadata'] = metadata;
  }
  return result;
}

// Per-node provenance carries configuration only. End-of-file variables,
// navigation, integrity and the latest-inspection pointer remain in the source
// file catalogue, never in an inactive swipe's effective state.
Map<String, Object?> _runtimeSourceHeader(Map<String, Object?> header) {
  final result = _sourceHeader(header);
  final metadata = _map(result['chat_metadata'])
    ..remove('variables')
    ..remove('integrity')
    ..remove('main_chat');
  for (final key in _terminalStateKeys) {
    metadata.remove(key);
  }
  final dshgo = _map(metadata['dshgo'])..remove('latestInspection');
  if (dshgo.isEmpty) {
    metadata.remove('dshgo');
  } else {
    metadata['dshgo'] = dshgo;
  }
  if (result.containsKey('chat_metadata') || metadata.isNotEmpty) {
    result['chat_metadata'] = metadata;
  }
  return result;
}

List<Map<String, Object?>> _sourceFiles(Map<String, Object?> metadata) {
  final own = _view(_view(metadata['dshgo'])[_namespace]);
  final files = own['files'];
  return files is List<Object?> ? files.whereType<Map<String, Object?>>().map(_clone).toList() : [];
}

Map<String, Object?>? _sourceFor(Map<String, Object?> metadata, Object? key) {
  final source = _metadataSource(metadata, key);
  final header = _metadataSourceHeader(metadata, source);
  return header == null ? null : _clone(header);
}

ChatJsonlMetadataSource _metadataSource(Map<String, Object?> metadata, Object? key) {
  if (key is! String) return const ChatJsonlMetadataSource._(ChatJsonlMetadataCarrier.root, null, null);
  final own = _view(_view(metadata['dshgo'])[_namespace]);
  final source = _view(own['sources'])[key];
  if (source is Map<String, Object?>) {
    return ChatJsonlMetadataSource._(ChatJsonlMetadataCarrier.sources, key, null);
  }
  final files = own['files'];
  if (files is List<Object?>) {
    for (var index = 0; index < files.length; index++) {
      final entry = files[index];
      if (entry is Map<String, Object?> && entry['key'] == key && entry['header'] is Map<String, Object?>) {
        return ChatJsonlMetadataSource._(ChatJsonlMetadataCarrier.files, key, index);
      }
    }
  }
  return const ChatJsonlMetadataSource._(ChatJsonlMetadataCarrier.root, null, null);
}

Map<String, Object?>? _metadataSourceHeader(Map<String, Object?> metadata, ChatJsonlMetadataSource source) {
  final own = _view(_view(metadata['dshgo'])[_namespace]);
  if (source.carrier == ChatJsonlMetadataCarrier.sources) {
    final header = _view(own['sources'])[source.sourceFile];
    return header is Map<String, Object?> ? header : null;
  }
  if (source.carrier == ChatJsonlMetadataCarrier.files) {
    final files = own['files'];
    final index = source.fileIndex;
    if (files is! List<Object?> || index == null || index < 0 || index >= files.length) return null;
    final entry = files[index];
    if (entry is! Map<String, Object?> || entry['key'] != source.sourceFile) return null;
    final header = entry['header'];
    return header is Map<String, Object?> ? header : null;
  }
  return null;
}

Map<String, Object?> _metadataContextDelta(
  Map<String, Object?> current,
  Map<String, Object?> before,
  Map<String, Object?> after,
) {
  final result = _clone(current);
  for (final key in {...before.keys, ...after.keys}) {
    if (!after.containsKey(key)) {
      final oldValue = before[key];
      final actual = result[key];
      if (oldValue is Map<String, Object?> && actual is Map<String, Object?>) {
        final remaining = _metadataContextDelta(actual, oldValue, const {});
        if (remaining.isEmpty) {
          result.remove(key);
        } else {
          result[key] = remaining;
        }
      } else {
        result.remove(key);
      }
    } else if (!before.containsKey(key) || _canonical(before[key]) != _canonical(after[key])) {
      final oldValue = before[key];
      final newValue = after[key];
      final actual = result[key];
      result[key] = newValue is Map<String, Object?> && actual is Map<String, Object?>
          ? _metadataContextDelta(actual, oldValue is Map<String, Object?> ? oldValue : const {}, newValue)
          : _clone({'value': newValue})['value'];
    }
  }
  return result;
}

Map<String, Object?> _effectiveState(ChatStore store, String chatId, StoredNode node) {
  final override = _view(node.extra['dshgo'])['tavernState'];
  return override is Map<String, Object?> ? _clone(override) : store.nodeState(chatId, node.message.nodeId);
}

Map<String, Object?> _withState(Map<String, Object?> extra, Map<String, Object?> state) => {
  ..._clone(extra),
  'dshgo': {..._map(extra['dshgo']), 'tavernState': _clone(state)},
};

Map<String, Object?> _quarantineExtra(Map<String, Object?> extra) =>
    _quarantine(extra, 'inspection', 'opaqueInspection');
Map<String, Object?> _quarantineMetadata(Map<String, Object?> metadata) =>
    _quarantine(metadata, 'latestInspection', 'opaqueLatestInspection');
Map<String, Object?> _quarantine(Map<String, Object?> value, String key, String archive) {
  final result = _clone(value);
  final dshgo = _map(result['dshgo']);
  if (dshgo.containsKey(key)) {
    final own = _map(dshgo[_namespace]);
    own.addAll({'version': 1, archive: dshgo.remove(key)});
    dshgo[_namespace] = own;
    result['dshgo'] = dshgo;
  }
  return result;
}

DateTime? _date(Object? value) {
  if (value is num && value.isFinite && value == value.roundToDouble()) {
    try {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
    } on ArgumentError {
      return null;
    }
  }
  if (value is! String) {
    return null;
  }
  var text = value;
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) {
    text += 'T00:00:00Z';
  }
  if (!RegExp(r'(?:[zZ]|[+-]\d{2}:?\d{2})$').hasMatch(text)) {
    text += 'Z';
  }
  return DateTime.tryParse(text)?.toUtc();
}

TavernUsage? _usage(Object? value, StChatDocument document, int line) {
  if (value == null) {
    return null;
  }
  final data = _checkedMap(value, document, line, 'chatJsonl.usage');
  final model = data['model'];
  if (model != null && model is! String) {
    _error(document, line, 'Usage model must be text.');
  }
  return TavernUsage(
    promptTokens: _index(data['promptTokens'] ?? 0, document, line, 'promptTokens'),
    cacheHitTokens: _index(data['cacheHitTokens'] ?? 0, document, line, 'cacheHitTokens'),
    completionTokens: _index(data['completionTokens'] ?? 0, document, line, 'completionTokens'),
    model: model as String?,
  );
}

Map<String, Object?>? _usageJson(TavernUsage? usage) => usage == null
    ? null
    : {
        'promptTokens': usage.promptTokens,
        'cacheHitTokens': usage.cacheHitTokens,
        'completionTokens': usage.completionTokens,
        'model': usage.model,
      };

String _uuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}
