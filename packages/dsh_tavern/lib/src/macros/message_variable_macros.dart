// Message-variable macro compatibility from the published Tavern Helper
// contract. No Helper implementation or type-repository source is used.
part of 'macro_engine.dart';

/// Null is an unresolved macro, distinct from a resolved JSON null's text.
String? _messageVariableMacro(MacroContext context, String path, {bool format = false}) {
  if (!context.messageVariablesExists) {
    return null;
  }
  final root = context.messageVariables;
  if (root is! Map<String, Object?>) {
    return null;
  }
  final segments = _messageVariablePath(path);
  if (segments == null) {
    return null;
  }

  Object? value = root;
  for (final segment in segments) {
    if (value is Map<String, Object?>) {
      if (!value.containsKey(segment)) {
        return null;
      }
      value = value[segment];
    } else if (value is List<Object?>) {
      final index = _arrayIndex(segment);
      if (index == null || index >= value.length) {
        return null;
      }
      value = value[index];
    } else {
      return null;
    }
  }
  if (!format) {
    return value is String ? value : _jsJson(value);
  }
  final editor = YamlEditor('');
  editor.update(const [], _messageVariableFormatValue(value));
  return trimEndJsWhitespace(editor.toString());
}

/// This profile accepts dot segments and numeric brackets, not JSON Pointer,
/// quoted brackets, empty segments or a second message argument.
List<String>? _messageVariablePath(String source) {
  final path = trimJsWhitespace(source);
  if (path.isEmpty || path.startsWith('/') || path.contains('::')) {
    return null;
  }
  final segments = <String>[];
  var cursor = 0;

  bool readProperty() {
    final start = cursor;
    while (cursor < path.length && path[cursor] != '.' && path[cursor] != '[' && path[cursor] != ']') {
      cursor++;
    }
    if (cursor == start) {
      return false;
    }
    segments.add(path.substring(start, cursor));
    return true;
  }

  if (!readProperty()) {
    return null;
  }
  while (cursor < path.length) {
    if (path[cursor] == '.') {
      cursor++;
      if (!readProperty()) {
        return null;
      }
    } else if (path[cursor] == '[') {
      final start = ++cursor;
      while (cursor < path.length && path.codeUnitAt(cursor) >= 0x30 && path.codeUnitAt(cursor) <= 0x39) {
        cursor++;
      }
      if (cursor == start || cursor == path.length || path[cursor] != ']') {
        return null;
      }
      segments.add(path.substring(start, cursor));
      cursor++;
    } else {
      return null;
    }
  }
  return segments;
}

/// Only the YAML macro omits metadata keys. Preserve list positions and never
/// mutate the selected value; the compact JSON getter returns all fields.
Object? _messageVariableFormatValue(Object? value) {
  if (value is Map<String, Object?>) {
    return <String, Object?>{
      for (final entry in value.entries)
        if (!entry.key.startsWith(r'$')) entry.key: _messageVariableFormatValue(entry.value),
    };
  }
  if (value is List<Object?>) {
    return [for (final item in value) _messageVariableFormatValue(item)];
  }
  return value;
}
