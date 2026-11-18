// Native MVU protocol profile derived from MagVarUpdate d03b7dc8.
// Copyright (c) 2025 MagicalAstrogy & StageDog. MIT; see THIRD_PARTY_NOTICES.md.
// This internal library computes owned candidates. Storage and script transport
// are supplied by the engine; expansion and phase callbacks may have effects.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:json5/json5.dart';
import 'package:math_expressions/math_expressions.dart' as math_expr;
import 'package:yaml/yaml.dart';

import '../js_string.dart';

part 'values.dart';
part 'json_repair.dart';
part 'schema.dart';
part 'initialize.dart';
part 'markup.dart';
part 'update.dart';

typedef MvuJson = Map<String, Object?>;
typedef MvuExpand = FutureOr<String> Function(String source);
typedef MvuPhaseHook = Future<void> Function(MvuPhase phase);

class MvuIssue {
  const MvuIssue(this.code, this.message, {this.source, this.offset});
  final String code;
  final String message;
  final String? source;
  final int? offset;
}

class MvuResult {
  const MvuResult(this.data, [this.issues = const []]);
  final MvuJson data;
  final List<MvuIssue> issues;
}

class MvuBook {
  const MvuBook({required this.name, required this.entries});
  final String name;
  final List<MvuInitEntry> entries;
}

class MvuInitEntry {
  const MvuInitEntry({required this.comment, required this.content, this.id});
  final String comment;
  final String content;
  final String? id;
}

class MvuCommand {
  MvuCommand({required this.type, required this.fullMatch, required this.args, this.reason = '', this.offset = 0});
  String type;
  String fullMatch;
  List<Object?> args;
  String reason;
  final int offset;
}

enum MvuPhaseKind { initialized, started, parsed, ended }

class MvuPhase {
  MvuPhase({
    required this.kind,
    required this.data,
    this.commands = const [],
    this.beforeData,
    this.swipeId,
    this.originalMessage,
  });
  final MvuPhaseKind kind;
  MvuJson data;
  List<MvuCommand> commands;
  MvuJson? beforeData;
  final int? swipeId;
  final String? originalMessage;
}
