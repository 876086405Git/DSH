// Ported from MagicalAstrogy/MagVarUpdate:
// src/function/update/structured_update.ts and extractCommands in
// src/function/update_variables.ts, commit
// d03b7dc8a6ebf9bd611c7e2dc91f3b35462deebc.
// Copyright (c) 2025 MagicalAstrogy & StageDog. MIT; see THIRD_PARTY_NOTICES.md.

part of 'mvu.dart';

typedef _MvuTag = ({String kind, bool closing, int start, int end});
typedef _MvuMarkup = ({String visible, List<_MvuTag> tags});
typedef _MvuBlock = ({int start, int end, int contentStart, int contentEnd, bool closed, bool discarded});

const _mvuIncompletePatchMarker = '<!-- mvu:discard-incomplete-json-patch -->';

_MvuMarkup _mvuScanMarkup(String input) {
  final visible = List<String>.generate(input.length, (index) => input[index]);
  final tags = <_MvuTag>[];
  final ignored = <String>[];
  String? mode;
  var pendingData = true;
  var quote = '';
  var escaped = false;
  var blockComment = false;
  int? scalarIndent;
  var lineStart = 0;
  var markupDepth = 0;
  final hasExplicitUpdate = RegExp(
    r'<(?:updatevariable|variableupdate|update)\b[^>]*>',
    caseSensitive: false,
  ).hasMatch(input);
  final tagPattern = RegExp(
    r'^<(\/?)\s*(updatevariable|variableupdate|update|json_?patch|think|thinking|reasoning|analysis|analyze)\b[^>]*>',
    caseSensitive: false,
  );
  final thinkingPattern = RegExp(
    r'^<(\/?)\s*(think|thinking|reasoning|analysis|analyze)\b[^>]*>',
    caseSensitive: false,
  );
  const thinkingNames = <String>{'think', 'thinking', 'reasoning', 'analysis', 'analyze'};
  void hide(int start, int end) {
    for (var index = start; index < end; index++) {
      if (input[index] != '\n' && input[index] != '\r') {
        visible[index] = ' ';
      }
    }
  }

  for (var index = 0; index < input.length; index++) {
    final character = input[index];
    if (index == lineStart && pendingData && ignored.isEmpty) {
      final first = input.substring(index).trimLeft();
      if (first.startsWith('[') || first.startsWith('{') || RegExp(r'^(?://|/\*|_\.)').hasMatch(first)) {
        mode = 'json';
      } else if (RegExp(r'^(?:-(?:\s|$)|#|[\w]+\s*:)').hasMatch(first)) {
        mode = 'yaml';
      }
    }
    if (index == lineStart && mode == 'yaml' && quote.isEmpty && ignored.isEmpty) {
      final nextLine = input.indexOf('\n', index);
      final lineEnd = nextLine < 0 ? input.length : nextLine;
      final line = input.substring(index, lineEnd).replaceFirst(RegExp(r'\r$'), '');
      final indent = RegExp(r'^\s*').firstMatch(line)!.group(0)!.length;
      if (scalarIndent != null) {
        if (line.trim().isEmpty || indent > scalarIndent) {
          index = lineEnd;
          lineStart = lineEnd + 1;
          continue;
        }
        scalarIndent = null;
      }
      if (RegExp(r'^\s*(?:-\s+)?[^#\r\n]*:\s*[|>](?:[+-]?[1-9]?|[1-9][+-]?)\s*(?:#.*)?$').hasMatch(line)) {
        scalarIndent = indent + (line.trimLeft().startsWith('- ') ? 2 : 0);
        pendingData = false;
        index = lineEnd;
        lineStart = lineEnd + 1;
        continue;
      }
    }
    if (character == '\n') {
      lineStart = index + 1;
    }
    if (ignored.isNotEmpty) {
      final tag = thinkingPattern.firstMatch(input.substring(index));
      if (tag != null) {
        final name = tag.group(2)!.toLowerCase();
        if (tag.group(1)!.isNotEmpty && name == ignored.last) {
          ignored.removeLast();
        } else if (tag.group(1)!.isEmpty) {
          ignored.add(name);
        }
        hide(index, index + tag.end);
        index += tag.end - 1;
        if (ignored.isEmpty) {
          pendingData = true;
        }
      } else {
        hide(index, index + 1);
      }
      continue;
    }
    if (quote.isNotEmpty) {
      if (escaped) {
        escaped = false;
      } else if (character == '\\' && (mode != 'yaml' || quote == '"')) {
        escaped = true;
      } else if (character == quote) {
        if (mode == 'yaml' && quote == "'" && index + 1 < input.length && input[index + 1] == "'") {
          index++;
        } else {
          quote = '';
        }
      }
      continue;
    }
    if (blockComment) {
      hide(index, index + 1);
      if (character == '*' && index + 1 < input.length && input[index + 1] == '/') {
        hide(index + 1, index + 2);
        index++;
        blockComment = false;
      }
      continue;
    }
    if (character == '<') {
      final tag = tagPattern.firstMatch(input.substring(index));
      if (tag != null) {
        final name = tag.group(2)!.toLowerCase();
        final closing = tag.group(1)!.isNotEmpty;
        if (thinkingNames.contains(name)) {
          if (!closing) {
            ignored.add(name);
          }
          hide(index, index + tag.end);
        } else {
          if (closing) {
            if (markupDepth > 0) {
              markupDepth--;
            }
          } else {
            markupDepth++;
          }
          tags.add((
            kind: name.startsWith('json') ? 'patch' : 'update',
            closing: closing,
            start: index,
            end: index + tag.end,
          ));
          mode = null;
          scalarIndent = null;
          pendingData = !closing;
        }
        index += tag.end - 1;
        continue;
      }
    }
    if (pendingData && character.trim().isNotEmpty) {
      if (input.startsWith('```', index)) {
        final end = input.indexOf('\n', index);
        if (end >= 0) {
          index = end;
          lineStart = end + 1;
          continue;
        }
      }
      if (character == '[' ||
          character == '{' ||
          input.startsWith('_.', index) ||
          input.startsWith('//', index) ||
          input.startsWith('/*', index)) {
        mode = 'json';
      } else if (RegExp(r'^-(?:\s|$)').hasMatch(input.substring(index)) ||
          RegExp(r'^[\w]+\s*:').hasMatch(input.substring(index))) {
        mode = 'yaml';
      }
      pendingData = false;
    }
    final previous = index == 0 ? '' : input[index - 1];
    final proseApostrophe =
        hasExplicitUpdate &&
        markupDepth == 0 &&
        character == "'" &&
        RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(previous);
    if (mode != null && (character == '"' || character == "'") && !proseApostrophe) {
      quote = character;
    } else if (mode == 'json' && input.startsWith('/*', index)) {
      hide(index, index + 2);
      blockComment = true;
      index++;
    } else if ((mode == 'json' && input.startsWith('//', index)) ||
        (mode == 'yaml' && character == '#' && (index == lineStart || previous.trim().isEmpty))) {
      final nextLine = input.indexOf('\n', index);
      hide(index, nextLine < 0 ? input.length : nextLine);
      index = (nextLine < 0 ? input.length : nextLine) - 1;
    } else if (mode == 'yaml' && character == ':' && index + 1 < input.length && input[index + 1].trim().isEmpty) {
      final rest = RegExp(r'''^[ \t]+([^\s"'[{|>#\r\n][^\r\n]*)''').firstMatch(input.substring(index + 1));
      if (rest != null) {
        index += rest.end;
      }
    }
  }
  return (visible: visible.join(), tags: tags);
}

List<_MvuBlock> _mvuMarkupBlocks(String input, _MvuMarkup scanned, String kind) {
  final openings = <_MvuTag>[];
  final blocks = <_MvuBlock>[];
  for (final tag in scanned.tags) {
    if (tag.kind != kind) {
      continue;
    }
    if (!tag.closing) {
      openings.add(tag);
    } else if (openings.isNotEmpty) {
      final opening = openings.removeLast();
      blocks.add((
        start: opening.start,
        end: tag.end,
        contentStart: opening.end,
        contentEnd: tag.start,
        closed: true,
        discarded: kind == 'patch' && input.startsWith(_mvuIncompletePatchMarker, tag.end),
      ));
    }
  }
  for (final opening in openings) {
    blocks.add((
      start: opening.start,
      end: input.length,
      contentStart: opening.end,
      contentEnd: input.length,
      closed: false,
      discarded: false,
    ));
  }
  blocks.sort((a, b) => a.start.compareTo(b.start));
  return blocks;
}

String _mvuCleanStructured(String input) => input
    .trim()
    .replaceFirst(RegExp(r'^```(?:json5?|ya?ml)?\s*', caseSensitive: false), '')
    .replaceFirst(RegExp(r'\s*```$'), '')
    .trim();

String _mvuBracketPath(Iterable<String> segments) => segments.map((segment) {
  final escaped = segment.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  return '["$escaped"]';
}).join();

List<String> _mvuPointer(String path) {
  if (path.isEmpty) {
    return const [];
  }
  final withoutRoot = path.startsWith('/') ? path.substring(1) : path;
  return withoutRoot.split('/').map((segment) => segment.replaceAll('~1', '/').replaceAll('~0', '~')).toList();
}

List<MvuCommand> _mvuExtractCommands(String input, List<MvuIssue> issues, {required bool blocksOnly}) {
  final scanned = _mvuScanMarkup(input);
  final patches = _mvuMarkupBlocks(input, scanned, 'patch');
  final updates = _mvuMarkupBlocks(input, scanned, 'update');
  final commands = <MvuCommand>[];
  for (final block in <_MvuBlock>[...patches, ...updates]) {
    if (!block.closed) {
      issues.add(
        MvuIssue(
          'unclosed_update',
          'An update block is incomplete and is not completed implicitly.',
          source: input.substring(block.start, block.end),
          offset: block.start,
        ),
      );
    }
  }
  for (final block in patches) {
    if (!block.closed || block.discarded) {
      continue;
    }
    final source = input.substring(block.contentStart, block.contentEnd);
    Object? patch;
    try {
      patch = _mvuParseDocument(_mvuCleanStructured(scanned.visible.substring(block.contentStart, block.contentEnd)));
    } on FormatException catch (error) {
      issues.add(MvuIssue('invalid_patch', error.message, source: source, offset: block.start));
      continue;
    }
    if (patch is! List<Object?> ||
        patch.any((operation) => operation is! MvuJson || operation['op'] is! String || operation['path'] is! String)) {
      issues.add(
        MvuIssue(
          'invalid_patch',
          'A patch must be an array of objects with string op and path fields.',
          source: source,
          offset: block.start,
        ),
      );
      continue;
    }
    for (final value in patch) {
      final operation = value as MvuJson;
      final type = operation['op'] as String;
      final segments = _mvuPointer(operation['path'] as String);
      final path = _mvuBracketPath(segments);
      final fullMatch = _mvuJsonText(operation);
      if (!const {'replace', 'delta', 'add', 'insert', 'remove'}.contains(type)) {
        issues.add(
          MvuIssue(
            'unsupported_patch_operation',
            'Unsupported MVU patch operation: $type.',
            source: fullMatch,
            offset: block.start,
          ),
        );
        continue;
      }
      if (type != 'remove' && !operation.containsKey('value')) {
        issues.add(
          MvuIssue(
            'invalid_command',
            'The patch operation requires a value field.',
            source: fullMatch,
            offset: block.start,
          ),
        );
        continue;
      }
      switch (type) {
        case 'replace':
        case 'delta':
          commands.add(
            MvuCommand(
              type: type == 'replace' ? 'set' : 'add',
              fullMatch: fullMatch,
              args: [path, _mvuJsonText(operation['value'])],
              reason: 'json_patch',
              offset: block.start,
            ),
          );
        case 'add':
        case 'insert':
          if (segments.isEmpty) {
            issues.add(
              MvuIssue(
                'invalid_command',
                'A patch insertion requires a property or array position.',
                source: fullMatch,
                offset: block.start,
              ),
            );
            continue;
          }
          final key = segments.last;
          commands.add(
            MvuCommand(
              type: 'insert',
              fullMatch: fullMatch,
              args: [
                _mvuBracketPath(segments.take(segments.length - 1)),
                RegExp(r'^\d+$').hasMatch(key) ? key : _mvuJsonText(key),
                _mvuJsonText(operation['value']),
              ],
              reason: 'json_patch',
              offset: block.start,
            ),
          );
        case 'remove':
          commands.add(
            MvuCommand(type: 'delete', fullMatch: fullMatch, args: [path], reason: 'json_patch', offset: block.start),
          );
      }
    }
  }

  final legacy = List<String>.generate(input.length, (index) => scanned.visible[index]);
  for (final block in patches) {
    legacy.fillRange(block.start, block.end, ' ');
  }
  if (blocksOnly) {
    for (var index = 0; index < legacy.length; index++) {
      if (!updates.any((block) => block.closed && index >= block.contentStart && index < block.contentEnd)) {
        legacy[index] = ' ';
      }
    }
  }
  final legacyText = legacy.join();
  final callPattern = RegExp(r'_\.(set|insert|assign|remove|unset|delete|add)\(');
  var position = 0;
  while (position < input.length) {
    final match = callPattern.firstMatch(legacyText.substring(position));
    if (match == null) {
      break;
    }
    final start = position + match.start;
    final open = position + match.end;
    final close = _mvuClosingParen(input, open);
    if (close < 0) {
      issues.add(
        MvuIssue(
          'invalid_command',
          'The command has no closing parenthesis.',
          source: input.substring(start),
          offset: start,
        ),
      );
      position = open;
      continue;
    }
    var end = close + 1;
    if (end >= input.length || input[end] != ';') {
      issues.add(
        MvuIssue(
          'invalid_command',
          'The closing parenthesis must be followed by a semicolon.',
          source: input.substring(start, end),
          offset: start,
        ),
      );
      position = end;
      continue;
    }
    end++;
    if (blocksOnly && !updates.any((block) => block.closed && start >= block.contentStart && end <= block.contentEnd)) {
      issues.add(
        MvuIssue(
          'invalid_command',
          'The complete command must be inside a closed update block.',
          source: input.substring(start, end),
          offset: start,
        ),
      );
      position = end;
      continue;
    }
    var reason = '';
    final comment = RegExp(r'^\s*//(.*)').firstMatch(input.substring(end));
    if (comment != null) {
      reason = comment.group(1)!.trim();
      end += comment.end;
    }
    final type = match.group(1)!;
    final fullMatch = input.substring(start, end);
    try {
      final args = _mvuSplitArguments(input.substring(open, close));
      if (!_mvuCommandArity(type, args.length)) {
        throw const FormatException('The command has an invalid number of arguments.');
      }
      commands.add(MvuCommand(type: type, fullMatch: fullMatch, args: args, reason: reason, offset: start));
    } on FormatException catch (error) {
      issues.add(MvuIssue('invalid_command', error.message, source: fullMatch, offset: start));
    }
    position = end;
  }
  final ordered = [for (var index = 0; index < commands.length; index++) (index: index, command: commands[index])];
  ordered.sort((a, b) {
    final offset = a.command.offset.compareTo(b.command.offset);
    return offset != 0 ? offset : a.index.compareTo(b.index);
  });
  return [for (final value in ordered) value.command];
}

bool _mvuCommandArity(String type, int count) => switch (type) {
  'set' || 'assign' || 'insert' => count >= 2,
  'remove' || 'unset' || 'delete' => count >= 1,
  'add' => count == 2,
  _ => false,
};

int _mvuClosingParen(String input, int start) {
  var depth = 1;
  var quote = '';
  var escaped = false;
  for (var index = start; index < input.length; index++) {
    final character = input[index];
    if (quote.isNotEmpty) {
      if (escaped) {
        escaped = false;
      } else if (character == '\\') {
        escaped = true;
      } else if (character == quote) {
        quote = '';
      }
      continue;
    }
    if (character == '"' || character == "'" || character == '`') {
      quote = character;
    } else if (character == '(') {
      depth++;
    } else if (character == ')') {
      depth--;
      if (depth == 0) {
        return index;
      }
    }
  }
  return -1;
}

List<Object?> _mvuSplitArguments(String input) {
  final result = <Object?>[];
  var start = 0;
  var quote = '';
  var escaped = false;
  final closings = <String>[];
  for (var index = 0; index < input.length; index++) {
    final character = input[index];
    if (quote.isNotEmpty) {
      if (escaped) {
        escaped = false;
      } else if (character == '\\') {
        escaped = true;
      } else if (character == quote) {
        quote = '';
      }
      continue;
    }
    if (character == '"' || character == "'" || character == '`') {
      quote = character;
    } else if (character == '(' || character == '[' || character == '{') {
      closings.add(switch (character) {
        '(' => ')',
        '[' => ']',
        _ => '}',
      });
    } else if (character == ')' || character == ']' || character == '}') {
      if (closings.isEmpty || closings.removeLast() != character) {
        throw const FormatException('Mismatched argument delimiters.');
      }
    } else if (character == ',' && closings.isEmpty) {
      final argument = input.substring(start, index).trim();
      if (argument.isEmpty) {
        throw const FormatException('An argument is empty.');
      }
      result.add(argument);
      start = index + 1;
    }
  }
  if (quote.isNotEmpty || closings.isNotEmpty) {
    throw const FormatException('An argument is incomplete.');
  }
  final tail = input.substring(start).trim();
  if (tail.isNotEmpty) {
    result.add(tail);
  }
  return result;
}
