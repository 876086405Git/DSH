// The composer's text controller with `@` references as atomic inline chips.
// The text stays exactly what is sent (the wire form the official client
// writes); only the drawing and the editing rules change.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'mention_chip.dart';
import 'mention_syntax.dart';

/// 输入框的文字控制器:`@` 引用是一个整体。
///
/// - 文字永远是要发出去的原文(`@lib/main.dart`、
///   `@[标题](dsh-session:…)`);每个引用画成一枚行内小签:第一个字符换成
///   签(WidgetSpan),其余字符画成零宽;
/// - 光标进不了签的内部:落进去就吸到边上(向左走一格吸到左边);
/// - 删除碰到签的任何一部分,整枚一起删;在签中间插字会落到签后面;
/// - 整段换进来的文字(恢复草稿、粘贴)里的引用自动成签,一个字一个字打出来
///   的 `@xxx` 仍是普通文字,要从面板里选。
///
/// [provisional] 是语音识别还没定下来的那一段,画成次级文字色。
class MentionTextController extends TextEditingController {
  MentionTextController({super.text}) {
    _tokens = parseDraftMentions(text);
  }

  List<MentionToken> _tokens = const [];

  /// Picked tokens waiting for the edit that inserts them.
  List<MentionToken>? _incoming;

  /// The references in [text], in order.
  List<MentionToken> get tokens => _tokens;

  TextRange _provisional = TextRange.empty;

  /// Dictated text that is not final yet; drawn muted.
  TextRange get provisional => _provisional;
  set provisional(TextRange range) {
    if (range == _provisional) return;
    _provisional = range;
    notifyListeners();
  }

  /// Replaces `[start, end)` with the reference [raw] (plus a space unless one
  /// follows) and puts the caret after it.
  void insertMention(String raw, {required int start, required int end}) {
    final current = value.text;
    final s = start.clamp(0, current.length);
    final e = end.clamp(s, current.length);
    final followedBySpace = e < current.length && _isSpace(current.codeUnitAt(e));
    final insert = followedBySpace ? raw : '$raw ';
    final token = MentionToken.fromRaw(raw, s);
    _incoming = token == null ? null : [token];
    value = TextEditingValue(
      text: current.replaceRange(s, e, insert),
      selection: TextSelection.collapsed(offset: s + insert.length + (followedBySpace ? 1 : 0)),
    );
    _incoming = null;
  }

  @override
  set value(TextEditingValue next) {
    final prev = super.value;
    if (next.text == prev.text) {
      super.value = next.copyWith(selection: _snap(prev.selection, next.selection));
      return;
    }

    // Set from code (`text = …`): take it as it is, chips and all.
    if (!next.selection.isValid) {
      _tokens = parseDraftMentions(next.text);
      _provisional = TextRange.empty;
      super.value = next;
      return;
    }

    var (start, end, inserted) = _diff(prev, next);
    var widened = false;
    for (final t in _tokens) {
      if (start == end) {
        // Typing inside a chip lands after it.
        if (t.start < start && start < t.end) {
          start = end = t.end;
          widened = true;
        }
      } else if (t.start < end && start < t.end && (t.start < start || t.end > end)) {
        // Deleting into a chip (backspace, a word) takes all of it. An edit
        // that keeps less of the chip than it removes is a replacement of
        // the whole text: it stands, and the broken chip becomes text.
        final inside = math.min(end, t.end) - math.max(start, t.start);
        if (inside > t.length - inside) continue;
        start = math.min(start, t.start);
        end = math.max(end, t.end);
        widened = true;
      }
    }
    final text = widened ? prev.text.replaceRange(start, end, inserted) : next.text;
    final delta = inserted.length - (end - start);
    final added =
        _incoming ??
        (inserted.length > 1 && !next.composing.isValid && inserted.contains('@')
            ? parseDraftMentions(text, start, start + inserted.length)
            : const <MentionToken>[]);
    _tokens = [
      for (final t in _tokens)
        if (t.end <= start) t else if (t.start >= end) t.shifted(delta),
      ...added,
    ]..sort((a, b) => a.start.compareTo(b.start));
    if (_provisional.isValid && (_provisional.end > text.length || _provisional.end > start)) {
      _provisional = TextRange.empty;
    }

    final selection = widened ? TextSelection.collapsed(offset: start + inserted.length) : next.selection;
    super.value = TextEditingValue(
      text: text,
      selection: _snap(prev.selection, selection),
      composing: widened ? TextRange.empty : next.composing,
    );
  }

  /// The edit from [a] to [b] as `[start, end)` of [a] replaced by a string,
  /// anchored at the caret so repeated characters resolve to where the person
  /// is typing.
  static (int, int, String) _diff(TextEditingValue a, TextEditingValue b) {
    final x = a.text;
    final y = b.text;
    final shorter = math.min(x.length, y.length);
    var p = 0;
    while (p < shorter && x.codeUnitAt(p) == y.codeUnitAt(p)) {
      p++;
    }
    if (a.selection.isValid && b.selection.isValid) {
      p = math.min(p, math.min(a.selection.start, b.selection.start));
      p = math.max(0, p);
    }
    var s = 0;
    final maxS = shorter - p;
    while (s < maxS && x.codeUnitAt(x.length - 1 - s) == y.codeUnitAt(y.length - 1 - s)) {
      s++;
    }
    return (p, x.length - s, y.substring(p, y.length - s));
  }

  /// Keeps carets and selection ends out of chips.
  TextSelection _snap(TextSelection prev, TextSelection selection) {
    if (!selection.isValid || _tokens.isEmpty) return selection;
    int snap(int offset, {required bool forward}) {
      for (final t in _tokens) {
        if (t.start < offset && offset < t.end) {
          return forward ? t.end : t.start;
        }
      }
      return offset;
    }

    if (selection.isCollapsed) {
      final offset = selection.baseOffset;
      final stepLeft = prev.isValid && prev.isCollapsed && prev.baseOffset == offset + 1;
      final snapped = snap(offset, forward: !stepLeft);
      return snapped == offset ? selection : TextSelection.collapsed(offset: snapped, affinity: selection.affinity);
    }
    final start = snap(selection.start, forward: false);
    final end = snap(selection.end, forward: true);
    if (start == selection.start && end == selection.end) return selection;
    return selection.baseOffset <= selection.extentOffset
        ? selection.copyWith(baseOffset: start, extentOffset: end)
        : selection.copyWith(baseOffset: end, extentOffset: start);
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final text = this.text;
    final composing = withComposing && value.isComposingRangeValid ? value.composing : TextRange.empty;
    final muted = _provisional.isValid && _provisional.end <= text.length ? _provisional : TextRange.empty;
    if (_tokens.isEmpty && !composing.isValid && !muted.isValid) {
      return TextSpan(style: style, text: text);
    }

    final mutedStyle = MentionChip.provisionalStyle(context, style);
    final children = <InlineSpan>[];

    // Plain text, split where the composing underline or the muted range
    // starts and ends.
    void plain(int from, int to) {
      if (from >= to) return;
      final cuts = <int>{from, to};
      for (final range in [composing, muted]) {
        if (!range.isValid) continue;
        if (range.start > from && range.start < to) cuts.add(range.start);
        if (range.end > from && range.end < to) cuts.add(range.end);
      }
      final points = cuts.toList()..sort();
      for (var i = 0; i + 1 < points.length; i++) {
        final a = points[i];
        final b = points[i + 1];
        final inComposing = composing.isValid && a >= composing.start && b <= composing.end;
        final inMuted = muted.isValid && a >= muted.start && b <= muted.end;
        TextStyle? s = inMuted ? mutedStyle : null;
        if (inComposing) {
          s = (s ?? const TextStyle()).merge(const TextStyle(decoration: TextDecoration.underline));
        }
        children.add(TextSpan(text: text.substring(a, b), style: s));
      }
    }

    var at = 0;
    for (final t in _tokens) {
      if (t.start < at || t.end > text.length) continue;
      plain(at, t.start);
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: MentionChip(kind: t.kind, label: t.label, style: style),
        ),
      );
      if (t.length > 1) {
        children.add(TextSpan(text: text.substring(t.start + 1, t.end), style: MentionChip.hiddenStyle));
      }
      at = t.end;
    }
    plain(at, text.length);
    return TextSpan(style: style, children: children);
  }
}

bool _isSpace(int unit) => unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x3000;
