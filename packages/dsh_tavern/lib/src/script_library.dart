import 'dart:convert';

import 'scripts.dart';

/// One managed global script or folder, including fields unknown to this
/// engine. Data and button rows are projected from their current bridge stores.
final class TavernScriptLibraryEntry {
  TavernScriptLibraryEntry(Map<String, Object?> raw) : _raw = _copy(raw);

  final Map<String, Object?> _raw;
  String get id => _raw['id']! as String;
  String get name => _raw['name'] as String? ?? '';
  bool get isFolder => _raw['type'] == 'folder';
  bool get enabled => isFolder ? _raw['enabled'] != false : _raw['enabled'] == true;
  Map<String, Object?> get raw => _copy(_raw);
  List<TavernScriptLibraryEntry> get children => List.unmodifiable([
    if (isFolder)
      for (final child in (_raw['scripts'] ?? _raw['children'])! as List<Object?>)
        TavernScriptLibraryEntry(child! as Map<String, Object?>),
  ]);
}

/// A script selected for the App to run. Reading this value never executes it.
final class TavernRunnableScript {
  TavernRunnableScript({
    required this.owner,
    required this.name,
    required this.content,
    this.info = '',
    this.buttonsEnabled = true,
    Iterable<TavernScriptButton> buttons = const [],
  }) : buttons = List.unmodifiable(buttons);

  final TavernScriptOwner owner;
  final String name;
  final String content;
  final String info;
  final bool buttonsEnabled;
  final List<TavernScriptButton> buttons;
}

/// Global, current-preset, then character scripts, in each tree's order.
/// A group without an explicit character has no character scripts.
final class TavernChatScripts {
  TavernChatScripts({
    required this.chatId,
    required this.characterId,
    required Iterable<TavernRunnableScript> scripts,
    Iterable<TavernScriptIssue> issues = const [],
  }) : scripts = List.unmodifiable(scripts),
       issues = List.unmodifiable(issues);

  final String chatId;
  final String? characterId;
  final List<TavernRunnableScript> scripts;
  final List<TavernScriptIssue> issues;
}

Map<String, Object?> _copy(Map<String, Object?> value) => jsonDecode(jsonEncode(value)) as Map<String, Object?>;
