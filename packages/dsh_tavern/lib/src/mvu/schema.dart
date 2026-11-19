// Ported from MagicalAstrogy/MagVarUpdate:
// src/function/schema.ts and applyTemplate in src/function/update_variables.ts
// Commit d03b7dc8a6ebf9bd611c7e2dc91f3b35462deebc.
// Copyright (c) 2025 MagicalAstrogy & StageDog. MIT; see THIRD_PARTY_NOTICES.md.

part of 'mvu.dart';

const _mvuExtensibleMarker = r'$__META_EXTENSIBLE__$';

MvuJson _mvuGenerateSchema(Object? value, {Object? previous, bool parentRecursiveExtensible = false}) =>
    _mvuSchemaNode(_copyMvu(value), previous, parentRecursiveExtensible);

MvuJson _mvuSchemaNode(Object? value, Object? previous, bool parentRecursiveExtensible) {
  final old = previous is MvuJson ? previous : null;
  if (value is List<Object?>) {
    final oldArray = old?['type'] == 'array' ? old : null;
    Object? extensible = oldArray?['extensible'] == true;
    final recursive = oldArray?['recursiveExtensible'] == true || parentRecursiveExtensible;
    Object? template = oldArray?['template'];
    var hasTemplate = oldArray?.containsKey('template') ?? false;
    final metaIndex = value.indexWhere(
      (item) => item is MvuJson && item[r'$arrayMeta'] == true && item.containsKey(r'$meta'),
    );
    if (metaIndex != -1) {
      final item = value[metaIndex] as MvuJson;
      final rawMeta = item[r'$meta'];
      if (rawMeta == null) {
        throw const FormatException('Array metadata must not be null.');
      }
      if (rawMeta is MvuJson) {
        if (rawMeta.containsKey('extensible')) {
          extensible = rawMeta['extensible'];
        }
        if (rawMeta.containsKey('template')) {
          template = rawMeta['template'];
          hasTemplate = true;
        }
      }
      value.removeAt(metaIndex);
    }
    final markerIndex = value.indexOf(_mvuExtensibleMarker);
    if (markerIndex != -1) {
      extensible = true;
      value.removeAt(markerIndex);
    }
    return <String, Object?>{
      'type': 'array',
      'extensible': _mvuTruthy(extensible) ? extensible : parentRecursiveExtensible,
      'recursiveExtensible': recursive,
      'elementType': value.isEmpty
          ? <String, Object?>{'type': 'any'}
          : _mvuSchemaNode(value.first, oldArray?['elementType'], recursive),
      if (hasTemplate) 'template': _copyMvu(template),
    };
  }
  if (value is MvuJson) {
    final oldObject = old?['type'] == 'object' ? old : null;
    final oldProperties = oldObject?['properties'];
    final rawMeta = value[r'$meta'];
    final meta = rawMeta is MvuJson ? rawMeta : null;
    final extensible =
        oldObject?['extensible'] == true ||
        meta?['extensible'] == true ||
        meta?['recursiveExtensible'] == true ||
        parentRecursiveExtensible;
    final recursive =
        oldObject?['recursiveExtensible'] == true || parentRecursiveExtensible || meta?['recursiveExtensible'] == true;
    final properties = <String, Object?>{};
    final result = <String, Object?>{
      'type': 'object',
      'properties': properties,
      'extensible': extensible,
      'recursiveExtensible': recursive,
    };
    if (meta != null && meta.containsKey('template')) {
      result['template'] = _copyMvu(meta['template']);
    } else if (_mvuTruthy(oldObject?['template'])) {
      result['template'] = _copyMvu(oldObject?['template']);
    }
    if (_mvuTruthy(rawMeta)) {
      value.remove(r'$meta');
    }
    final requiredKeys = meta?['required'];
    for (final key in _mvuKeys(value)) {
      final oldChild = oldProperties is MvuJson ? oldProperties[key] : null;
      final child = _mvuSchemaNode(value[key], oldChild, extensible && recursive);
      var required = !extensible;
      if (requiredKeys is List<Object?> && requiredKeys.contains(key)) {
        required = true;
      }
      if (oldChild is MvuJson) {
        if (oldChild['required'] == false) {
          required = false;
        } else if (oldChild['required'] == true) {
          required = true;
        }
      }
      properties[key] = <String, Object?>{...child, 'required': required};
    }
    return result;
  }
  return <String, Object?>{
    'type': switch (value) {
      String() => 'string',
      num() => 'number',
      bool() => 'boolean',
      _ => 'any',
    },
  };
}

MvuJson? _mvuSchemaAt(Object? schema, List<String> segments) {
  MvuJson? current = schema is MvuJson ? schema : null;
  for (final segment in segments) {
    if (current == null) {
      return null;
    }
    final Object? next;
    if (current['type'] == 'object') {
      final properties = current['properties'];
      next = properties is MvuJson ? properties[segment] : null;
    } else if (current['type'] == 'array' && RegExp(r'^\d+$').hasMatch(segment)) {
      next = current['elementType'];
    } else {
      return null;
    }
    current = next is MvuJson ? next : null;
  }
  return current;
}

void _mvuReconcileSchema(MvuJson ownedData) {
  final previous = ownedData['schema'];
  final schema = _mvuGenerateSchema(ownedData['stat_data'], previous: previous);
  if (schema['type'] != 'object') {
    return;
  }
  final state = ownedData['stat_data'];
  final rawMeta = state is MvuJson ? state[r'$meta'] : null;
  final meta = rawMeta is MvuJson ? rawMeta : null;
  for (final key in const ['strictTemplate', 'strictSet', 'concatTemplateArray']) {
    if (previous is MvuJson && previous.containsKey(key)) {
      schema[key] = _copyMvu(previous[key]);
    }
    if (meta != null && meta.containsKey(key)) {
      schema[key] = _copyMvu(meta[key]);
    }
  }
  ownedData['schema'] = schema;
}

void _mvuCleanMetadata(Object? ownedValue) {
  if (ownedValue is List<Object?>) {
    for (var index = ownedValue.length - 1; index >= 0; index--) {
      final value = ownedValue[index];
      if (value == _mvuExtensibleMarker ||
          value is MvuJson && value[r'$arrayMeta'] == true && value.containsKey(r'$meta')) {
        ownedValue.removeAt(index);
      } else {
        _mvuCleanMetadata(value);
      }
    }
  } else if (ownedValue is MvuJson) {
    ownedValue.remove(r'$meta');
    for (final value in ownedValue.values) {
      _mvuCleanMetadata(value);
    }
  }
}

Object? _mvuApplyTemplate(Object? value, Object? template, {bool strictArrayCast = false, bool concatArrays = true}) {
  if (!_mvuTruthy(template)) {
    return value;
  }
  if (value is MvuJson && template is! List<Object?>) {
    final base = template is MvuJson
        ? _copyMvuMap(template)
        : <String, Object?>{
            if (template is String)
              for (var index = 0; index < template.length; index++)
                '$index': String.fromCharCode(template.codeUnitAt(index)),
          };
    return _mvuMerge(base, value);
  }
  if (value is List<Object?> && template is List<Object?>) {
    if (concatArrays) {
      return <Object?>[for (final item in value) _copyMvu(item), for (final item in template) _copyMvu(item)];
    }
    return _mvuMerge(_copyMvu(template), value);
  }
  if (value is! MvuJson && value is! List<Object?> && template is List<Object?> && !strictArrayCast) {
    if (concatArrays) {
      return <Object?>[_copyMvu(value), for (final item in template) _copyMvu(item)];
    }
    return _mvuMerge(_copyMvu(template), <Object?>[value]);
  }
  return value;
}
