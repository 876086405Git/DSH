// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';

import 'accent.dart';
import 'palette.dart';

/// re_highlight 的 scope → TextStyle 映射("Mist" 主题,深浅两套)。
///
/// 键名对应 highlight.js scope(无 `hljs-` 前缀)。
///
/// 方向:**安静的彩色**。每个角色一个色相、彩度 0.09–0.13(Xcode / GitHub
/// 主题约 0.2),明度统一到对代码井 ≥ 4.5,所以没有哪一类 token 特别跳:
///
/// | 角色 | 色相 | 浅色 | 深色 |
/// |---|---|---|---|
/// | keyword | 紫 300° | #6A499B | #C4ACF2 |
/// | string | 绿 150° | #336F43 | #97D2A2 |
/// | number / literal | 琥珀 62° | #90561A | #F2BB8A |
/// | comment(斜体) | 灰蓝 | #636975 | #868C97 |
/// | function / title | 蓝 258° | #2C5CA3 | #95BDF8 |
/// | type / class / built_in | 青 205° | #006E77 | #85CFD8 |
/// | attr / property | 玫 15° | #97464F | #ECA4A9 |
/// | meta / 装饰器 | 土 80° | #726042 | #BFAF95 |
///
/// 变量、参数、标点不上色(或只用次级文字色)—— 满屏彩色是噪音。
///
/// 角色色相是语义,不随配色变;正文、注释、标点这几格中性色跟 [accent]
/// 的中性色走(同明度,对代码井的对比度不变)。
///
/// A theme pack's [syntax] colours replace the role colours they name; each
/// scope keeps its own italics, weight and underline.
Map<String, TextStyle> dshHighlightTheme(
  Brightness brightness, [
  AppAccent accent = AppAccent.mist,
  ThemeSyntaxColors? syntax,
]) {
  final dark = brightness == Brightness.dark;
  final n = NeutralTones.forAccent(accent);
  final neutral = _neutralTheme(dark, n);
  if (syntax == null) return neutral;
  return _themed.putIfAbsent((dark, n, syntax), () {
    if (_themed.length > 16) _themed.clear();
    final themed = {...neutral};
    void paint(Color? color, List<String> scopes) {
      if (color == null) return;
      for (final scope in scopes) {
        // Some of these the default map leaves plain (`title.function`,
        // `title.class`): a pack that names the role colours them too.
        themed[scope] = themed[scope]?.copyWith(color: color) ?? TextStyle(color: color);
      }
    }

    paint(syntax.keyword, const ['keyword', 'literal', 'doctag', 'template-tag', 'selector-tag', 'name']);
    paint(syntax.string, const ['string', 'regexp', 'char.escape']);
    paint(syntax.number, const ['number', 'symbol', 'bullet']);
    paint(syntax.comment, const ['comment', 'quote']);
    paint(syntax.function, const ['title', 'title.function', 'title.function.invoke', 'function', 'section', 'link']);
    paint(syntax.type, const [
      'title.class',
      'title.class.inherited',
      'type',
      'built_in',
      'selector-class',
      'selector-id',
    ]);
    return themed;
  });
}

final _themed = <(bool, NeutralTones, ThemeSyntaxColors), Map<String, TextStyle>>{};

/// A theme pack's colours for the syntax roles, for one brightness; a null
/// role keeps its default. Compared by value: the highlight caches key on it.
@immutable
class ThemeSyntaxColors {
  const ThemeSyntaxColors({this.keyword, this.string, this.number, this.comment, this.function, this.type});

  final Color? keyword;
  final Color? string;
  final Color? number;
  final Color? comment;
  final Color? function;
  final Color? type;

  @override
  bool operator ==(Object other) =>
      other is ThemeSyntaxColors &&
      other.keyword == keyword &&
      other.string == string &&
      other.number == number &&
      other.comment == comment &&
      other.function == function &&
      other.type == type;

  @override
  int get hashCode => Object.hash(keyword, string, number, comment, function, type);
}

Map<String, TextStyle> _neutralTheme(bool dark, NeutralTones n) {
  final base = dark ? _dark : _light;
  if (identical(n, NeutralTones.defaults)) return base;
  return _tinted.putIfAbsent((dark, n), () {
    if (_tinted.length > 16) _tinted.clear();
    final root = dark ? n.paper : n.ink;
    final comment = dark ? n.commentDark : n.comment;
    final punct = dark ? n.paperMuted : n.inkMuted;
    return {
      ...base,
      'root': TextStyle(color: root),
      'comment': TextStyle(color: comment, fontStyle: FontStyle.italic),
      'quote': TextStyle(color: comment, fontStyle: FontStyle.italic),
      'operator': TextStyle(color: punct),
      'punctuation': TextStyle(color: punct),
    };
  });
}

final _tinted = <(bool, NeutralTones), Map<String, TextStyle>>{};

const _light = <String, TextStyle>{
  'root': TextStyle(color: Color(0xFF1E232E)),
  'keyword': TextStyle(color: Color(0xFF6A499B)),
  'doctag': TextStyle(color: Color(0xFF6A499B)),
  'template-tag': TextStyle(color: Color(0xFF6A499B)),
  'selector-tag': TextStyle(color: Color(0xFF6A499B)),
  'name': TextStyle(color: Color(0xFF6A499B)),
  'string': TextStyle(color: Color(0xFF336F43)),
  'regexp': TextStyle(color: Color(0xFF336F43)),
  'meta-string': TextStyle(color: Color(0xFF336F43)),
  'char.escape_': TextStyle(color: Color(0xFF336F43)),
  'number': TextStyle(color: Color(0xFF90561A)),
  'literal': TextStyle(color: Color(0xFF90561A)),
  'symbol': TextStyle(color: Color(0xFF90561A)),
  'bullet': TextStyle(color: Color(0xFF90561A)),
  'comment': TextStyle(color: Color(0xFF636975), fontStyle: FontStyle.italic),
  'quote': TextStyle(color: Color(0xFF636975), fontStyle: FontStyle.italic),
  'title': TextStyle(color: Color(0xFF2C5CA3)),
  'title.function_': TextStyle(color: Color(0xFF2C5CA3)),
  'function': TextStyle(color: Color(0xFF2C5CA3)),
  'section': TextStyle(color: Color(0xFF2C5CA3), fontWeight: FontWeight.w600),
  'link': TextStyle(color: Color(0xFF2C5CA3), decoration: TextDecoration.underline),
  'title.class_': TextStyle(color: Color(0xFF006E77)),
  'class-title': TextStyle(color: Color(0xFF006E77)),
  'type': TextStyle(color: Color(0xFF006E77)),
  'built_in': TextStyle(color: Color(0xFF006E77)),
  'selector-class': TextStyle(color: Color(0xFF006E77)),
  'selector-id': TextStyle(color: Color(0xFF006E77)),
  'attr': TextStyle(color: Color(0xFF97464F)),
  'attribute': TextStyle(color: Color(0xFF97464F)),
  'property': TextStyle(color: Color(0xFF97464F)),
  'selector-attr': TextStyle(color: Color(0xFF97464F)),
  'selector-pseudo': TextStyle(color: Color(0xFF97464F)),
  'meta': TextStyle(color: Color(0xFF726042)),
  'meta keyword': TextStyle(color: Color(0xFF726042)),
  'operator': TextStyle(color: Color(0xFF4F5562)),
  'punctuation': TextStyle(color: Color(0xFF4F5562)),
  'addition': TextStyle(color: Color(0xFF1F613C), backgroundColor: Color(0xFFDCF4E3)),
  'deletion': TextStyle(color: Color(0xFF923A37), backgroundColor: Color(0xFFFFE4E2)),
  'emphasis': TextStyle(fontStyle: FontStyle.italic),
  'strong': TextStyle(fontWeight: FontWeight.bold),
};

const _dark = <String, TextStyle>{
  'root': TextStyle(color: Color(0xFFE6E9F0)),
  'keyword': TextStyle(color: Color(0xFFC4ACF2)),
  'doctag': TextStyle(color: Color(0xFFC4ACF2)),
  'template-tag': TextStyle(color: Color(0xFFC4ACF2)),
  'selector-tag': TextStyle(color: Color(0xFFC4ACF2)),
  'name': TextStyle(color: Color(0xFFC4ACF2)),
  'string': TextStyle(color: Color(0xFF97D2A2)),
  'regexp': TextStyle(color: Color(0xFF97D2A2)),
  'meta-string': TextStyle(color: Color(0xFF97D2A2)),
  'char.escape_': TextStyle(color: Color(0xFF97D2A2)),
  'number': TextStyle(color: Color(0xFFF2BB8A)),
  'literal': TextStyle(color: Color(0xFFF2BB8A)),
  'symbol': TextStyle(color: Color(0xFFF2BB8A)),
  'bullet': TextStyle(color: Color(0xFFF2BB8A)),
  'comment': TextStyle(color: Color(0xFF868C97), fontStyle: FontStyle.italic),
  'quote': TextStyle(color: Color(0xFF868C97), fontStyle: FontStyle.italic),
  'title': TextStyle(color: Color(0xFF95BDF8)),
  'title.function_': TextStyle(color: Color(0xFF95BDF8)),
  'function': TextStyle(color: Color(0xFF95BDF8)),
  'section': TextStyle(color: Color(0xFF95BDF8), fontWeight: FontWeight.w600),
  'link': TextStyle(color: Color(0xFF95BDF8), decoration: TextDecoration.underline),
  'title.class_': TextStyle(color: Color(0xFF85CFD8)),
  'class-title': TextStyle(color: Color(0xFF85CFD8)),
  'type': TextStyle(color: Color(0xFF85CFD8)),
  'built_in': TextStyle(color: Color(0xFF85CFD8)),
  'selector-class': TextStyle(color: Color(0xFF85CFD8)),
  'selector-id': TextStyle(color: Color(0xFF85CFD8)),
  'attr': TextStyle(color: Color(0xFFECA4A9)),
  'attribute': TextStyle(color: Color(0xFFECA4A9)),
  'property': TextStyle(color: Color(0xFFECA4A9)),
  'selector-attr': TextStyle(color: Color(0xFFECA4A9)),
  'selector-pseudo': TextStyle(color: Color(0xFFECA4A9)),
  'meta': TextStyle(color: Color(0xFFBFAF95)),
  'meta keyword': TextStyle(color: Color(0xFFBFAF95)),
  'operator': TextStyle(color: Color(0xFFB6BBC5)),
  'punctuation': TextStyle(color: Color(0xFFB6BBC5)),
  'addition': TextStyle(color: Color(0xFF98D5AC), backgroundColor: Color(0xFF1C3424)),
  'deletion': TextStyle(color: Color(0xFFF2A7A1), backgroundColor: Color(0xFF422423)),
  'emphasis': TextStyle(fontStyle: FontStyle.italic),
  'strong': TextStyle(fontWeight: FontWeight.bold),
};
