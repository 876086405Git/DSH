part of 'engine.dart';

extension _ManagedScriptLibrary on TavernEngine {
  List<Object?> _globalScriptTree(Map<String, Object?> document) =>
      document['scriptLibrary'] as List<Object?>? ?? const [];

  List<Map<String, Object?>> _globalScriptRawTree(Map<String, Object?> document, {List<Object?>? tree}) {
    final data = _readOptionalObject(document, 'scriptData');
    final buttons = _readOptionalObject(document, 'scriptButtons');
    Map<String, Object?> project(Map<String, Object?> node) {
      final raw = Map<String, Object?>.of(node);
      if (isScriptFolder(raw)) {
        final key = raw['scripts'] != null ? 'scripts' : 'children';
        raw[key] = [
          for (final child in scriptTreeChildren(raw)! as List<Object?>) project(child! as Map<String, Object?>),
        ];
      } else {
        final id = raw['id']! as String;
        raw.remove('data');
        if (data.containsKey(id)) raw['data'] = data[id];
        final button = _scriptMapView(raw['button']);
        if (raw.containsKey('button') || buttons.containsKey(id)) {
          raw['button'] = {...button, if (buttons.containsKey(id)) 'buttons': buttons[id]};
        }
      }
      return raw;
    }

    return [for (final node in tree ?? _globalScriptTree(document)) project(node! as Map<String, Object?>)];
  }

  List<TavernScriptLibraryEntry> _globalScriptViews(Map<String, Object?> document, {List<Object?>? tree}) =>
      List.unmodifiable([for (final raw in _globalScriptRawTree(document, tree: tree)) TavernScriptLibraryEntry(raw)]);

  Object _globalScriptExportRaw(Map<String, Object?> document, String? id) {
    if (id == null) return _globalScriptRawTree(document);
    final found = _globalScriptLocation(_globalScriptTree(document), id);
    return _globalScriptRawTree(document, tree: [found.siblings[found.index]]).single;
  }

  Future<List<TavernScriptLibraryEntry>> _importGlobalScripts(String text) {
    final imported = decodeScriptLibraryImport(text);
    return _settingsDocument((document) async {
      final tree = List<Object?>.of(_globalScriptTree(document));
      final data = _readOptionalObject(document, 'scriptData');
      final buttons = _readOptionalObject(document, 'scriptButtons');
      final used = <String>{
        ...data.keys,
        ...buttons.keys,
        for (final node in _globalScriptNodes(tree)) node['id']! as String,
      };
      void adopt(Map<String, Object?> node) {
        final supplied = node['id'] as String?;
        final id = supplied != null && supplied.isNotEmpty && !used.contains(supplied) ? supplied : _newStateId();
        used.add(id);
        node['id'] = id;
        if (isScriptFolder(node)) {
          for (final child in scriptTreeChildren(node)! as List<Object?>) {
            adopt(child! as Map<String, Object?>);
          }
        } else {
          if (node.containsKey('data')) data[id] = node.remove('data');
          final button = node['button'];
          if (button is Map<String, Object?> && button.containsKey('buttons')) {
            buttons[id] = button.remove('buttons');
          }
        }
      }

      for (final node in imported) {
        adopt(node);
      }
      tree.addAll(imported);
      document['scriptLibrary'] = tree;
      document['scriptData'] = data;
      document['scriptButtons'] = buttons;
      await _commitGlobalScriptLibrary(document);
      return _globalScriptViews(document, tree: imported);
    });
  }

  Future<TavernScriptLibraryEntry> _setGlobalScriptEnabled(String id, bool enabled) =>
      _settingsDocument((document) async {
        final found = _globalScriptLocation(_globalScriptTree(document), id);
        final node = found.siblings[found.index]! as Map<String, Object?>;
        if (node['enabled'] != enabled) {
          node['enabled'] = enabled;
          await _commitGlobalScriptLibrary(document);
        }
        return _globalScriptViewById(document, id);
      });

  Future<void> _setGlobalScriptOrder(List<String> ids, String? folderId) {
    final order = List<String>.of(ids);
    return _settingsDocument((document) async {
      var siblings = _globalScriptTree(document);
      if (folderId != null) {
        final found = _globalScriptLocation(siblings, folderId);
        final folder = found.siblings[found.index]! as Map<String, Object?>;
        if (!isScriptFolder(folder)) throw ArgumentError.value(folderId, 'folderId', 'The target is not a folder.');
        siblings = scriptTreeChildren(folder)! as List<Object?>;
      }
      final byId = {for (final node in siblings) (node! as Map<String, Object?>)['id']! as String: node};
      if (order.length != byId.length || order.toSet().length != order.length || !order.every(byId.containsKey)) {
        throw ArgumentError.value(ids, 'ids', 'Provide each sibling id exactly once.');
      }
      if (order.isEmpty) return;
      final sorted = [for (final id in order) byId[id]];
      siblings.setAll(0, sorted);
      await _commitGlobalScriptLibrary(document);
    });
  }

  Future<void> _deleteGlobalScript(String id) => _settingsDocument((document) async {
    final found = _globalScriptLocation(_globalScriptTree(document), id);
    final removed = found.siblings.removeAt(found.index)! as Map<String, Object?>;
    final data = _readOptionalObject(document, 'scriptData');
    final buttons = _readOptionalObject(document, 'scriptButtons');
    for (final node in _globalScriptNodes([removed])) {
      if (isScriptFolder(node)) continue;
      data.remove(node['id']);
      buttons.remove(node['id']);
    }
    document['scriptData'] = data;
    document['scriptButtons'] = buttons;
    await _commitGlobalScriptLibrary(document);
  });

  Future<void> _commitGlobalScriptLibrary(Map<String, Object?> document) => _commitSettingsDocument(
    document,
    onCommitted: () {
      for (final key in const ['scriptLibrary', 'scriptData', 'scriptButtons']) {
        if (document.containsKey(key)) _document[key] = document[key];
      }
      _globalScriptsChanged.add(null);
      _scriptCatalogChanged.add(null);
    },
  );

  TavernScriptLibraryEntry _globalScriptViewById(Map<String, Object?> document, String id) =>
      TavernScriptLibraryEntry(_globalScriptExportRaw(document, id) as Map<String, Object?>);

  Future<TavernChatScripts> _readChatScripts(String chatId, {String? characterId}) async {
    if (characterId == '') throw ArgumentError.value(characterId, 'characterId', 'Expected a nonempty id.');
    final chat = _store.chat(chatId);
    final selectedCharacter = characterId ?? (_store.groupChat(chatId) == null ? chat.characterId : null);
    Map<String, Object?>? card;
    if (selectedCharacter != null) {
      card = await _library.readRuntimeAuthority(selectedCharacter, (data) => data);
      if (card == null) throw _scriptError(TavernScriptErrorCode.notFound, 'chatScripts', 'Character not found.');
    }
    return _presetOperation(() {
      final current = _currentPresetData(chatId);
      final scripts = <TavernRunnableScript>[];
      final issues = <TavernScriptIssue>[];
      final globalButtons = _readOptionalObject(_document, 'scriptButtons');
      _appendRunnableScripts(
        scripts,
        issues,
        _globalScriptTree(_document),
        'global',
        (id) => TavernScriptOwner(kind: TavernScriptOwnerKind.global, scriptId: id),
        globalButtons: globalButtons,
      );
      final slot = current.working.chat ?? current.working.global;
      final TavernScriptPresetCarrier? carrier;
      if (slot != null) {
        carrier = TavernScriptPresetCarrier.working(
          chatId: current.working.chat == null ? null : chatId,
          workingId: slot.workingId,
        );
      } else if (current.selection.source == PresetSelectionSource.chatInline ||
          current.selection.source == PresetSelectionSource.globalInline) {
        carrier = TavernScriptPresetCarrier.inline(
          chatId: current.selection.source == PresetSelectionSource.chatInline ? chatId : null,
        );
      } else {
        carrier = null;
      }
      if (carrier != null || current.selection.effectivePresetId != null) {
        _appendRunnableScripts(
          scripts,
          issues,
          scriptTreeFromExtensions(_scriptMapView(current.raw['extensions'])),
          'preset',
          (id) => TavernScriptOwner(
            kind: TavernScriptOwnerKind.preset,
            assetId: current.selection.effectivePresetId,
            scriptId: id,
            presetCarrier: carrier,
          ),
        );
      }
      final characterData = card;
      if (characterData != null) {
        _appendRunnableScripts(
          scripts,
          issues,
          scriptTreeFromExtensions(_scriptMapView(characterData['extensions'])),
          'character',
          (id) => TavernScriptOwner(kind: TavernScriptOwnerKind.character, assetId: selectedCharacter, scriptId: id),
        );
      }
      return TavernChatScripts(chatId: chatId, characterId: selectedCharacter, scripts: scripts, issues: issues);
    });
  }
}

Iterable<Map<String, Object?>> _globalScriptNodes(List<Object?> tree) sync* {
  for (final value in tree) {
    final node = value! as Map<String, Object?>;
    yield node;
    if (isScriptFolder(node)) yield* _globalScriptNodes(scriptTreeChildren(node)! as List<Object?>);
  }
}

({List<Object?> siblings, int index}) _globalScriptLocation(List<Object?> tree, String id) {
  ({List<Object?> siblings, int index})? find(List<Object?> nodes) {
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i]! as Map<String, Object?>;
      if (node['id'] == id) return (siblings: nodes, index: i);
      if (isScriptFolder(node)) {
        final child = find(scriptTreeChildren(node)! as List<Object?>);
        if (child != null) return child;
      }
    }
    return null;
  }

  final found = find(tree);
  if (found == null) throw StateError('Global script or folder not found: $id');
  return found;
}

void _appendRunnableScripts(
  List<TavernRunnableScript> output,
  List<TavernScriptIssue> issues,
  Object? tree,
  String source,
  TavernScriptOwner Function(String id) owner, {
  Map<String, Object?>? globalButtons,
}) {
  void issue(String code, String path, String message) => issues.add(
    TavernScriptIssue(code: code, message: message, committed: false, details: {'source': source, 'path': path}),
  );
  if (tree == null) return;
  if (tree is! List<Object?>) {
    issue('shapeMismatch', r'$', 'Scripts must be an array.');
    return;
  }
  final leaves = scriptTreeLeaves(tree).toList();
  final counts = <String, int>{};
  for (final leaf in leaves) {
    final id = leaf.raw['id'];
    if (id is String) counts[id] = (counts[id] ?? 0) + 1;
  }
  for (final leaf in leaves) {
    final raw = leaf.raw;
    if (!leaf.enabled) continue;
    final content = raw['content'];
    if (content is! String || content.trim().isEmpty) continue;
    final id = raw['id'];
    if (id is! String || id.isEmpty) {
      issue('missingScriptId', '${leaf.path}.id', 'An enabled script needs a stable owner id.');
      continue;
    }
    if (counts[id] != 1) {
      issue('ambiguousName', '${leaf.path}.id', 'The script id is repeated in its owner.');
      continue;
    }
    final button = _scriptMapView(raw['button']);
    final rows = globalButtons == null ? button['buttons'] : globalButtons[id];
    output.add(
      TavernRunnableScript(
        owner: owner(id),
        name: raw['name'] is String ? raw['name']! as String : '',
        content: content,
        info: raw['info'] is String ? raw['info']! as String : '',
        buttonsEnabled: button['enabled'] != false,
        buttons: [
          if (rows is List<Object?>)
            for (final row in rows)
              if (row is Map<String, Object?> && row['name'] is String)
                TavernScriptButton(name: row['name']! as String, visible: row['visible'] != false),
        ],
      ),
    );
  }
}
