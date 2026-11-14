part of 'mvu.dart';

// Dart port of jsonrepair 3.15.0's regular parser and string utilities.
// Copyright (c) 2020-2026 Jos de Jong. ISC; see THIRD_PARTY_NOTICES.md.
// Source commit: 4a80ed87fb1155db064945bc2aa4f6b4f4e89c27.

String _repairMvuJson(String source) => _MvuJsonRepair(source).run();

const _jrControls = <String, String>{'\b': r'\b', '\f': r'\f', '\n': r'\n', '\r': r'\r', '\t': r'\t'};

const _jrEscapes = <String>{'"', r'\', '/', 'b', 'f', 'n', 'r', 't'};

String _jrChar(String text, int index) => index >= 0 && index < text.length ? text[index] : '';

String _jrSlice(String text, int start, [int? end]) {
  final first = start < 0 ? 0 : (start > text.length ? text.length : start);
  final requestedLast = end ?? text.length;
  final last = requestedLast < first ? first : (requestedLast > text.length ? text.length : requestedLast);
  return text.substring(first, last);
}

bool _jrWhitespace(String text, int index, {bool newline = true}) {
  final char = _jrChar(text, index);
  return char == ' ' || char == '\t' || char == '\r' || newline && char == '\n';
}

bool _jrSpecialWhitespace(String text, int index) {
  if (index < 0 || index >= text.length) {
    return false;
  }
  final code = text.codeUnitAt(index);
  return code == 0xa0 ||
      code == 0x180e ||
      code >= 0x2000 && code <= 0x200b ||
      code == 0x202f ||
      code == 0x205f ||
      code == 0x3000 ||
      code == 0xfeff;
}

bool _jrDigit(String char) => char.isNotEmpty && char.codeUnitAt(0) >= 0x30 && char.codeUnitAt(0) <= 0x39;
bool _jrHex(String char) => RegExp(r'^[0-9a-fA-F]$').hasMatch(char);
bool _jrDoubleQuote(String char) => char == '"';
bool _jrSingleQuote(String char) => char == "'";
bool _jrDoubleQuoteLike(String char) => char == '"' || char == '\u201c' || char == '\u201d';
bool _jrSingleQuoteLike(String char) =>
    char == "'" || char == '\u2018' || char == '\u2019' || char == '\u0060' || char == '\u00b4';
bool _jrQuote(String char) => _jrDoubleQuoteLike(char) || _jrSingleQuoteLike(char);
bool _jrDelimiter(String char) => char.isNotEmpty && ',:[]/{}()\n+'.contains(char);
bool _jrUnquotedDelimiter(String char) => char.isNotEmpty && ',[]/{}\n+'.contains(char);
bool _jrFunctionStart(String char) => RegExp(r'^[A-Za-z_$]$').hasMatch(char);
bool _jrFunctionChar(String char) => RegExp(r'^[A-Za-z0-9_$]$').hasMatch(char);
bool _jrStartValue(String char) => _jrQuote(char) || RegExp(r'^[\[\{\w-]$').hasMatch(char);

final _jrUrlStart = RegExp(r'^(http|https|ftp|mailto|file|data|irc):\/\/$');
final _jrUrlChar = RegExp(r"^[A-Za-z0-9-._~:/?#@!$&'()*+;=]$");

String _jrStripLast(String text, String char, {bool remaining = false}) {
  final index = text.lastIndexOf(char);
  if (index < 0) {
    return text;
  }
  final before = text.substring(0, index);
  final after = remaining ? '' : text.substring(index + 1);
  return '$before$after';
}

String _jrInsertBeforeWhitespace(String text, String insert) {
  var index = text.length;
  while (_jrWhitespace(text, index - 1)) {
    index--;
  }
  final before = text.substring(0, index);
  final after = text.substring(index);
  return '$before$insert$after';
}

({String char, int length})? _jrEntity(String fragment) {
  if (!fragment.startsWith('&')) {
    return null;
  }
  final semicolon = fragment.indexOf(';');
  if (semicolon < 0) {
    return null;
  }
  final entity = fragment.substring(0, semicolon + 1);
  const named = <String, String>{'&quot;': '"', '&amp;': '&', '&lt;': '<', '&gt;': '>', '&apos;': "'"};
  final known = named[entity];
  if (known != null) {
    return (char: known, length: entity.length);
  }
  if (_jrChar(fragment, 1) != '#') {
    return null;
  }
  final body = fragment.substring(2, semicolon);
  final hex = body.startsWith('x') || body.startsWith('X');
  var digits = trimJsWhitespace(hex ? body.substring(1) : body);
  var sign = 1;
  if (digits.startsWith('-') || digits.startsWith('+')) {
    if (digits.startsWith('-')) {
      sign = -1;
    }
    digits = digits.substring(1);
  }
  // Number.parseInt accepts a valid prefix, including a hexadecimal 0x prefix.
  if (hex && (digits.startsWith('0x') || digits.startsWith('0X'))) {
    digits = digits.substring(2);
  }
  final prefix = RegExp(hex ? r'^[0-9a-fA-F]+' : r'^[0-9]+').firstMatch(digits);
  if (prefix == null) {
    return null;
  }
  final code = int.tryParse(prefix.group(0)!, radix: hex ? 16 : 10);
  if (code == null || sign * code < 0 || sign * code > 0x10ffff) {
    return null;
  }
  return (char: String.fromCharCode(sign * code), length: entity.length);
}

bool _jrInsideBracket(String text, String close) {
  final open = switch (close) {
    ')' => '(',
    ']' => '[',
    '}' => '{',
    _ => null,
  };
  if (open == null) {
    return false;
  }
  var opens = 0;
  var closes = 0;
  for (var index = 0; index < text.length; index++) {
    if (text[index] == open) {
      opens++;
    }
    if (text[index] == close) {
      closes++;
    }
  }
  return opens > closes;
}

class _MvuJsonRepair {
  _MvuJsonRepair(this.text);

  final String text;
  int i = 0;
  String output = '';

  String char([int offset = 0]) => _jrChar(text, i + offset);

  String run() {
    const fence = '\u0060\u0060\u0060';
    parseMarkdown([fence, '[$fence', '{$fence']);
    if (!parseValue()) {
      throw FormatException('Unexpected end of json string', text, text.length);
    }
    parseMarkdown([fence, '$fence]', '$fence}']);
    final comma = parseCharacter(',');
    if (comma) {
      parseWhitespaceAndComments();
    }
    if (_jrStartValue(char()) && RegExp(r'[,\n][ \t\r]*$').hasMatch(output)) {
      if (!comma) {
        output = _jrInsertBeforeWhitespace(output, ',');
      }
      parseNewlineDelimited();
    } else if (comma) {
      output = _jrStripLast(output, ',');
    }
    while (char() == '}' || char() == ']') {
      i++;
      parseWhitespaceAndComments();
    }
    if (i < text.length) {
      unexpected();
    }
    return output;
  }

  bool parseValue() {
    parseWhitespaceAndComments();
    final processed =
        parseObject() ||
        parseArray() ||
        parseString() ||
        parseNumber() ||
        parseKeywords() ||
        parseUnquoted(false) ||
        parseRegex();
    parseWhitespaceAndComments();
    return processed;
  }

  bool parseWhitespaceAndComments({bool newline = true}) {
    final start = i;
    var changed = parseWhitespace(newline: newline);
    do {
      changed = parseComment();
      if (changed) {
        changed = parseWhitespace(newline: newline);
      }
    } while (changed);
    return i > start;
  }

  bool parseWhitespace({bool newline = true}) {
    var whitespace = '';
    while (true) {
      if (_jrWhitespace(text, i, newline: newline)) {
        whitespace += char();
        i++;
      } else if (_jrSpecialWhitespace(text, i)) {
        whitespace += ' ';
        i++;
      } else {
        break;
      }
    }
    if (whitespace.isEmpty) {
      return false;
    }
    output += whitespace;
    return true;
  }

  bool parseComment() {
    if (char() == '/' && char(1) == '*') {
      while (i < text.length && !(char() == '*' && char(1) == '/')) {
        i++;
      }
      i += 2;
      return true;
    }
    if (char() == '/' && char(1) == '/') {
      while (i < text.length && char() != '\n') {
        i++;
      }
      return true;
    }
    return false;
  }

  bool parseMarkdown(List<String> blocks) {
    parseWhitespace();
    for (final block in blocks) {
      final end = i + block.length;
      if (_jrSlice(text, i, end) == block) {
        i = end;
        if (_jrFunctionStart(char())) {
          while (i < text.length && _jrFunctionChar(char())) {
            i++;
          }
        }
        parseWhitespaceAndComments();
        return true;
      }
    }
    return false;
  }

  bool parseCharacter(String expected) {
    if (char() != expected) {
      return false;
    }
    output += char();
    i++;
    return true;
  }

  bool skipCharacter(String expected) {
    if (char() != expected) {
      return false;
    }
    i++;
    return true;
  }

  bool skipEllipsis() {
    parseWhitespaceAndComments();
    if (char() == '.' && char(1) == '.' && char(2) == '.') {
      i += 3;
      parseWhitespaceAndComments();
      skipCharacter(',');
      return true;
    }
    return false;
  }

  bool parseObject() {
    if (char() != '{') {
      return false;
    }
    output += '{';
    i++;
    parseWhitespaceAndComments();
    if (skipCharacter(',')) {
      parseWhitespaceAndComments();
    }
    var initial = true;
    while (i < text.length && char() != '}') {
      if (!initial) {
        if (!parseCharacter(',')) {
          output = _jrInsertBeforeWhitespace(output, ',');
        }
        parseWhitespaceAndComments();
      }
      skipEllipsis();
      if (!(parseString() || parseUnquoted(true))) {
        if (char() == '}' || char() == '{' || char() == ']' || char() == '[' || char().isEmpty) {
          if (!initial) {
            output = _jrStripLast(output, ',');
          }
        } else {
          throw FormatException('Object key expected', text, i);
        }
        break;
      }
      parseWhitespaceAndComments();
      final colon = parseCharacter(':');
      final truncated = i >= text.length;
      if (!colon) {
        if (_jrStartValue(char()) || truncated) {
          output = _jrInsertBeforeWhitespace(output, ':');
        } else {
          throw FormatException('Colon expected', text, i);
        }
      }
      if (!parseValue()) {
        if (colon || truncated) {
          output += 'null';
        } else {
          throw FormatException('Colon expected', text, i);
        }
      }
      initial = false;
    }
    if (char() == '}') {
      output += '}';
      i++;
    } else {
      output = _jrInsertBeforeWhitespace(output, '}');
    }
    return true;
  }

  bool parseArray() {
    if (char() != '[') {
      return false;
    }
    output += '[';
    i++;
    parseWhitespaceAndComments();
    if (skipCharacter(',')) {
      parseWhitespaceAndComments();
    }
    var initial = true;
    while (i < text.length && char() != ']') {
      if (!initial && !parseCharacter(',')) {
        output = _jrInsertBeforeWhitespace(output, ',');
      }
      skipEllipsis();
      if (!parseValue()) {
        if (!initial) {
          output = _jrStripLast(output, ',');
        }
        break;
      }
      initial = false;
    }
    if (char() == ']') {
      output += ']';
      i++;
    } else {
      output = _jrInsertBeforeWhitespace(output, ']');
    }
    return true;
  }

  void parseNewlineDelimited() {
    var initial = true;
    var processed = true;
    while (processed) {
      if (!initial) {
        if (!parseCharacter(',')) {
          output = _jrInsertBeforeWhitespace(output, ',');
        }
      } else {
        initial = false;
      }
      processed = parseValue();
    }
    output = _jrStripLast(output, ',');
    output = '[\n$output\n]';
  }

  bool parseString({bool stopAtDelimiter = false, int stopAtIndex = -1}) {
    final skipEscapes = char() == r'\';
    if (skipEscapes) {
      i++;
      if (!_jrQuote(char())) {
        unexpected();
      }
    }
    final openEntity = char() == '&' ? _jrEntity(_jrSlice(text, i, i + 12)) : null;
    final openedByEntity = openEntity?.char == '"' || openEntity?.char == "'";
    final opening = char();
    if (!_jrQuote(opening) && !openedByEntity) {
      return false;
    }
    final bool Function(String) isEndQuote;
    if (_jrDoubleQuote(opening)) {
      isEndQuote = _jrDoubleQuote;
    } else if (_jrSingleQuote(opening)) {
      isEndQuote = _jrSingleQuote;
    } else if (_jrSingleQuoteLike(opening)) {
      isEndQuote = _jrSingleQuoteLike;
    } else {
      isEndQuote = _jrDoubleQuoteLike;
    }
    final beforeInput = i;
    final beforeOutput = output.length;
    var str = '"';
    i += openedByEntity && openEntity != null ? openEntity.length : 1;
    while (true) {
      if (i >= text.length) {
        final previous = prevNonWhitespace(i - 1);
        if (!stopAtDelimiter && _jrDelimiter(_jrChar(text, previous))) {
          i = beforeInput;
          output = output.substring(0, beforeOutput);
          return parseString(stopAtDelimiter: true);
        }
        str = _jrInsertBeforeWhitespace(str, '"');
        output += str;
        return true;
      }
      if (i == stopAtIndex) {
        str = _jrInsertBeforeWhitespace(str, '"');
        output += str;
        return true;
      }
      final entity = openedByEntity && char() == '&' ? _jrEntity(_jrSlice(text, i, i + 12)) : null;
      final isEnd = entity != null && openEntity != null ? entity.char == openEntity.char : isEndQuote(char());
      if (isEnd) {
        final quoteInput = i;
        final quoteOutput = str.length;
        str += '"';
        i += entity?.length ?? 1;
        output += str;
        parseWhitespaceAndComments(newline: false);
        if (stopAtDelimiter ||
            i >= text.length ||
            _jrDelimiter(char()) && !_jrInsideBracket(str, char()) ||
            _jrQuote(char()) && !nextQuoteIsEnd(i) ||
            _jrDigit(char())) {
          parseConcatenatedString();
          return true;
        }
        if (char() == r'\') {
          unexpected();
        }
        final previousIndex = prevNonWhitespace(quoteInput - 1);
        final previous = _jrChar(text, previousIndex);
        if (previous == ',') {
          i = beforeInput;
          output = output.substring(0, beforeOutput);
          return parseString(stopAtIndex: previousIndex);
        }
        if (_jrDelimiter(previous)) {
          i = beforeInput;
          output = output.substring(0, beforeOutput);
          return parseString(stopAtDelimiter: true);
        }
        output = output.substring(0, beforeOutput);
        i = quoteInput + (entity?.length ?? 1);
        final before = str.substring(0, quoteOutput);
        final after = str.substring(quoteOutput);
        str = '$before\\$after';
      } else if (stopAtDelimiter && _jrUnquotedDelimiter(char())) {
        if (char(-1) == ':' && _jrUrlStart.hasMatch(_jrSlice(text, beforeInput + 1, i + 2))) {
          while (i < text.length && _jrUrlChar.hasMatch(char())) {
            str += char();
            i++;
          }
        }
        str = _jrInsertBeforeWhitespace(str, '"');
        output += str;
        parseConcatenatedString();
        return true;
      } else if (entity != null) {
        final decoded = entity.char;
        if (decoded == '"') {
          str += r'\"';
        } else {
          str += _jrControls[decoded] ?? decoded;
        }
        i += entity.length;
      } else if (char() == r'\') {
        final escaped = char(1);
        if (_jrEscapes.contains(escaped)) {
          str += _jrSlice(text, i, i + 2);
          i += 2;
        } else if (escaped == 'u') {
          var j = 2;
          while (j < 6 && _jrHex(char(j))) {
            j++;
          }
          if (j == 6) {
            str += _jrSlice(text, i, i + 6);
            i += 6;
          } else if (i + j >= text.length) {
            i = text.length;
          } else {
            final invalid = _jrSlice(text, i, i + 6);
            throw FormatException('Invalid unicode character "$invalid"', text, i);
          }
        } else if (escaped == '\n') {
          str += r'\n';
          i += 2;
        } else {
          str += escaped;
          i += 2;
        }
      } else {
        final current = char();
        if (current == '"' && char(-1) != r'\') {
          str += r'\"';
          i++;
        } else if (_jrControls.containsKey(current)) {
          str += _jrControls[current]!;
          i++;
        } else {
          if (current.isEmpty || current.codeUnitAt(0) < 0x20) {
            final invalid = jsonEncode(current);
            throw FormatException('Invalid character $invalid', text, i);
          }
          str += current;
          i++;
        }
      }
      if (skipEscapes) {
        skipCharacter(r'\');
      }
    }
  }

  bool parseConcatenatedString() {
    var processed = false;
    parseWhitespaceAndComments();
    while (char() == '+') {
      processed = true;
      i++;
      parseWhitespaceAndComments();
      output = _jrStripLast(output, '"', remaining: true);
      final start = output.length;
      if (parseString()) {
        final before = output.substring(0, start);
        final after = output.substring(start + 1);
        output = '$before$after';
      } else {
        output = _jrInsertBeforeWhitespace(output, '"');
      }
    }
    return processed;
  }

  bool parseNumber() {
    final start = i;
    var number = '';
    var invalid = false;
    if (char() == '-') {
      number += char();
      i++;
      if (!_jrDigit(char()) && atEndOfNumber()) {
        number += '0';
      }
    }
    if (char() == '0' && _jrDigit(char(1))) {
      invalid = true;
    }
    while (_jrDigit(char())) {
      number += char();
      i++;
    }
    if (char() == '.') {
      if (number.isEmpty || number == '-') {
        number += '0';
      }
      number += char();
      i++;
      if (!_jrDigit(char())) {
        number += '0';
      }
      while (_jrDigit(char())) {
        number += char();
        i++;
      }
    }
    if (i == start) {
      return false;
    }
    if (char() == 'e' || char() == 'E') {
      if (number == '-') {
        invalid = true;
      }
      number += char();
      i++;
      if (char() == '-' || char() == '+') {
        number += char();
        i++;
      }
      if (!_jrDigit(char())) {
        number += '0';
      }
      while (_jrDigit(char())) {
        number += char();
        i++;
      }
    }
    if (!atEndOfNumber()) {
      i = start;
      return false;
    }
    final original = text.substring(start, i);
    output += invalid ? '"$original"' : number;
    return true;
  }

  bool parseKeywords() =>
      parseKeyword('true', 'true') ||
      parseKeyword('false', 'false') ||
      parseKeyword('null', 'null') ||
      parseKeyword('True', 'true') ||
      parseKeyword('False', 'false') ||
      parseKeyword('None', 'null');

  bool parseKeyword(String name, String value) {
    if (_jrSlice(text, i, i + name.length) == name && !_jrFunctionChar(char(name.length))) {
      output += value;
      i += name.length;
      return true;
    }
    return false;
  }

  bool parseUnquoted(bool isKey) {
    final start = i;
    if (_jrFunctionStart(char())) {
      while (i < text.length && _jrFunctionChar(char())) {
        i++;
      }
      var j = i;
      while (_jrWhitespace(text, j)) {
        j++;
      }
      if (_jrChar(text, j) == '(') {
        i = j + 1;
        parseValue();
        if (char() == ')') {
          i++;
          if (char() == ';') {
            i++;
          }
        }
        return true;
      }
    }
    while (i < text.length && !_jrUnquotedDelimiter(char()) && !_jrQuote(char()) && (!isKey || char() != ':')) {
      i++;
    }
    if (char(-1) == ':' && _jrUrlStart.hasMatch(_jrSlice(text, start, i + 2))) {
      while (i < text.length && _jrUrlChar.hasMatch(char())) {
        i++;
      }
    }
    if (i <= start) {
      return false;
    }
    while (i > 0 && _jrWhitespace(text, i - 1)) {
      i--;
    }
    final symbol = text.substring(start, i);
    output += symbol == 'undefined' ? 'null' : jsonEncode(symbol);
    if (char() == '"') {
      i++;
    }
    return true;
  }

  bool parseRegex() {
    if (char() != '/') {
      return false;
    }
    final start = i;
    i++;
    while (i < text.length && (char() != '/' || char(-1) == r'\')) {
      i++;
    }
    i++;
    output += jsonEncode(_jrSlice(text, start, i));
    return true;
  }

  int prevNonWhitespace(int start) {
    var previous = start;
    while (previous > 0 && _jrWhitespace(text, previous)) {
      previous--;
    }
    return previous;
  }

  bool nextQuoteIsEnd(int index) {
    var next = index + 1;
    while (next < text.length && _jrWhitespace(text, next)) {
      next++;
    }
    return next >= text.length || _jrDelimiter(_jrChar(text, next));
  }

  bool atEndOfNumber() => i >= text.length || _jrDelimiter(char()) || _jrWhitespace(text, i);

  Never unexpected() {
    final unexpected = jsonEncode(char());
    throw FormatException('Unexpected character $unexpected', text, i);
  }
}
