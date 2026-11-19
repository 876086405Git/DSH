import 'dart:convert';

/// The documented helper tree, also used by the existing owner data bridge.
/// A present modern empty list intentionally suppresses the legacy field.
Object? scriptTreeFromExtensions(Map<String, Object?> extensions) {
  final helper = extensions['tavern_helper'];
  return helper is Map<String, Object?> && helper['scripts'] != null
      ? helper['scripts']
      : extensions['TavernHelper_scripts'];
}

Object? scriptTreeChildren(Map<String, Object?> node) => node['scripts'] ?? node['children'];

bool isScriptFolder(Map<String, Object?> node) =>
    node['type'] == 'folder' || (node['type'] != 'script' && scriptTreeChildren(node) is List<Object?>);

typedef ScriptTreeLeaf = ({Map<String, Object?> raw, bool enabled, String path});

/// Legacy card/preset trees keep the same permissive traversal as the original
/// App parser. A leaf without a usable identity is diagnosed by its caller.
Iterable<ScriptTreeLeaf> scriptTreeLeaves(List<Object?> tree, {String path = r'$', bool enabled = true}) sync* {
  for (var i = 0; i < tree.length; i++) {
    final node = tree[i];
    if (node is! Map<String, Object?>) continue;
    final at = '$path[$i]';
    if (isScriptFolder(node)) {
      final children = scriptTreeChildren(node);
      if (children is List<Object?>) {
        yield* scriptTreeLeaves(
          children,
          path: '$at.${node['scripts'] != null ? 'scripts' : 'children'}',
          enabled: enabled && node['enabled'] != false,
        );
      }
    } else {
      yield (raw: node, enabled: enabled && node['enabled'] == true, path: at);
    }
  }
}

/// Bare script/folder objects, or this engine's complete-library array.
/// Optional export fields (info/data/button/export_with) stay optional.
List<Map<String, Object?>> decodeScriptLibraryImport(String text) {
  final value = jsonDecode(text.startsWith('\ufeff') ? text.substring(1) : text);
  final List<Object?> tree;
  if (value is Map<String, Object?>) {
    tree = [value];
  } else if (value is List<Object?>) {
    tree = value;
  } else {
    throw const FormatException('A script import must be a script/folder object or a tree array.');
  }
  _validate(tree, stored: false);
  return [for (final node in tree) node! as Map<String, Object?>];
}

/// Called once at the settings-file boundary, not on internal reads/writes.
void validateStoredScriptLibrary(Object? value) {
  if (value == null) return;
  if (value is! List<Object?>) throw const FormatException('scriptLibrary must be a tree array.');
  _validate(value, stored: true);
}

void _validate(List<Object?> tree, {required bool stored}) {
  final ids = <String>{};
  Never invalid(String path, String message) => throw FormatException('$path: $message');
  void optional(Map<String, Object?> raw, String key, bool Function(Object?) valid, String path) {
    if (raw.containsKey(key) && !valid(raw[key])) invalid('$path.$key', 'Invalid field shape.');
  }

  void visit(List<Object?> nodes, String path) {
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      final at = '$path[$i]';
      if (node is! Map<String, Object?>) invalid(at, 'Expected a script or folder object.');
      if (node['type'] != 'script' && node['type'] != 'folder') invalid('$at.type', 'Expected script or folder.');
      optional(node, 'id', (value) => value is String, at);
      optional(node, 'name', (value) => value is String, at);
      optional(node, 'enabled', (value) => value is bool, at);
      final id = node['id'];
      if (stored && (id is! String || id.isEmpty || !ids.add(id))) {
        invalid('$at.id', 'Stored library identities must be nonempty and unique.');
      }
      if (node['type'] == 'folder') {
        final children = scriptTreeChildren(node);
        if (children is! List<Object?>) invalid('$at.scripts', 'Expected a script array.');
        visit(children, '$at.${node['scripts'] != null ? 'scripts' : 'children'}');
        continue;
      }
      if (node['content'] is! String) invalid('$at.content', 'Expected script text.');
      optional(node, 'info', (value) => value is String, at);
      optional(node, 'data', (value) => value is Map<String, Object?>, at);
      final button = node['button'];
      if (node.containsKey('button')) {
        if (button is! Map<String, Object?>) invalid('$at.button', 'Expected a button object.');
        optional(button, 'enabled', (value) => value is bool, '$at.button');
        if (button.containsKey('buttons')) {
          final rows = button['buttons'];
          if (rows is! List<Object?>) invalid('$at.button.buttons', 'Expected a button array.');
          for (var b = 0; b < rows.length; b++) {
            final row = rows[b];
            if (row is! Map<String, Object?> || row['name'] is! String) {
              invalid('$at.button.buttons[$b]', 'Expected a named button object.');
            }
            optional(row, 'visible', (value) => value is bool, '$at.button.buttons[$b]');
          }
        }
      }
    }
  }

  visit(tree, r'$.scriptLibrary');
}
