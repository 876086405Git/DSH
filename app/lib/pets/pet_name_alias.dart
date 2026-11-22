import 'dart:convert';

import 'package:archive/archive.dart';

import 'pet_unicode_data.g.dart';

// Unicode data is trusted, generated, and versioned with the market checker.
final List<dynamic> _tables =
    jsonDecode(utf8.decode(ZLibDecoder().decodeBytes(base64Decode(petUnicodeData)))) as List<dynamic>;
Map<String, dynamic> get _decomp => _tables[0] as Map<String, dynamic>;
Map<String, dynamic> get _classes => _tables[1] as Map<String, dynamic>;
Map<String, dynamic> get _compositions => _tables[2] as Map<String, dynamic>;
Map<String, dynamic> get _folds => _tables[3] as Map<String, dynamic>;
int _class(int cp) => _classes['$cp'] as int? ?? 0;

void _decompose(int cp, List<int> target) {
  final syllable = cp - 0xac00;
  if (syllable >= 0 && syllable < 11172) {
    target.add(0x1100 + syllable ~/ 588);
    target.add(0x1161 + (syllable % 588) ~/ 28);
    if (syllable % 28 != 0) target.add(0x11a7 + syllable % 28);
  } else {
    final parts = _decomp['$cp'] as List<dynamic>?;
    if (parts == null) {
      target.add(cp);
    } else {
      for (final part in parts) {
        _decompose(part as int, target);
      }
    }
  }
}

int? _compose(int a, int b) {
  final l = a - 0x1100, v = b - 0x1161;
  if (l >= 0 && l < 19 && v >= 0 && v < 21) return 0xac00 + (l * 21 + v) * 28;
  final s = a - 0xac00, t = b - 0x11a7;
  if (s >= 0 && s < 11172 && s % 28 == 0 && t > 0 && t < 28) return a + t;
  return _compositions['$a,$b'] as int?;
}

/// Exactly Python 3.12's unicodedata.normalize('NFC', name).casefold().
/// This is an alias key only: the original spelling remains the file name.
String petNameAlias(String name) {
  if (name.codeUnits.every((unit) => unit <= 0x7f)) return name.toLowerCase();
  final decomposed = <int>[];
  for (final cp in name.runes) {
    _decompose(cp, decomposed);
  }
  // Stable canonical ordering with at most 255 classes. Sorting a long ZIP
  // name must not become quadratic in its number of combining characters.
  final ordered = <int>[];
  final marks = <int, List<int>>{};
  void flush() {
    for (final cc in marks.keys.toList()..sort()) {
      ordered.addAll(marks[cc]!);
    }
    marks.clear();
  }

  for (final cp in decomposed) {
    final cc = _class(cp);
    if (cc == 0) {
      flush();
      ordered.add(cp);
    } else {
      (marks[cc] ??= []).add(cp);
    }
  }
  flush();
  final composed = <int>[];
  var starter = -1, previousClass = 0;
  for (final cp in ordered) {
    final cc = _class(cp);
    final replacement = starter >= 0 && (previousClass == 0 || previousClass < cc)
        ? _compose(composed[starter], cp)
        : null;
    if (replacement != null) {
      composed[starter] = replacement;
    } else {
      if (cc == 0) starter = composed.length;
      composed.add(cp);
      previousClass = cc;
    }
  }
  return String.fromCharCodes([
    for (final cp in composed) ...((_folds['$cp'] as List<dynamic>?)?.cast<int>() ?? [cp]),
  ]);
}
