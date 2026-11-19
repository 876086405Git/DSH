import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

/// A front-end card as the community ships them: the greeting carries only
/// tags, and the card's display regexes (AI output, Markdown only) turn them
/// into whole pages — one in an ```html block, one in a block with no
/// language — and a variable update into a <div>/<style> panel.
Uint8List _frontendCard() => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': 'Guide',
        'description': '',
        'personality': '',
        'scenario': '',
        'first_mes':
            '<maintext>\r\n<content>\r\n{{user}}推门进来。\r\n</content>\r\n</maintext>\r\n\r\n<StatusPlaceHolderImpl/>',
        'mes_example': '',
        'creator_notes': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'alternate_greetings': [
          '<maintext>\r\n<content>\r\n早。\r\n</content>\r\n</maintext>\r\n\r\n'
              '<UpdateVariable>\r\n[{"op":"replace"}]\r\n</UpdateVariable>\r\n\r\n<StatusPlaceHolderImpl/>',
        ],
        'tags': <String>[],
        'creator': '',
        'character_version': '',
        'extensions': {
          'regex_scripts': [
            _rule(
              '正文',
              r'<maintext>[\s\S]*?</maintext>',
              "```html\n<!DOCTYPE html>\n<html><head><style>\n.a{}\n\n.b{}\n</style></head>\n<body><script>\nvar who='{{user}}';\n\n"
                  "s=s.replace(/x/g,'<b>\$1</b>');\n</script></body></html>\n```",
            ),
            _rule(
              '状态栏',
              '<StatusPlaceHolderImpl/>',
              '```\n<!DOCTYPE html>\n<html><body><div>状态</div></body></html>\n```',
            ),
            _rule('隐藏状态栏', '<StatusPlaceHolderImpl/>', '', markdownOnly: false, promptOnly: true),
            _rule(
              '变量',
              r'/<update(?:variable)?>\s*(.*)\s*<\/update(?:variable)?>/gsi',
              '<div><details><summary>变量</summary>\$1</details></div>\n<style>\n.x{}\n\n.y{}\n</style>',
            ),
          ],
        },
      },
    }),
  ),
);

Map<String, Object?> _rule(
  String name,
  String find,
  String replace, {
  bool markdownOnly = true,
  bool promptOnly = false,
}) => {
  'id': name,
  'scriptName': name,
  'findRegex': find,
  'replaceString': replace,
  'trimStrings': <String>[],
  'placement': [2],
  'disabled': false,
  'markdownOnly': markdownOnly,
  'promptOnly': promptOnly,
  'runOnEdit': true,
  'substituteRegex': 0,
  'minDepth': null,
  'maxDepth': 6,
};

void main() {
  test("a front-end card's greeting shows as its display regexes make it: pages in code blocks", () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final card = await h.engine.importCard(_frontendCard());
    Future<String> shown(int greeting) async {
      final chat = await h.engine.createChat(card.id, greeting: greeting);
      final first = (await h.engine.path(chat)).single;
      return (await h.engine.displayText(chat, nodeId: first.nodeId, text: first.text)).text;
    }

    final first = await shown(0);
    // Both tags replaced; the macro in the replacement filled in; a $1 with
    // no group to take is dropped, as SillyTavern drops it.
    expect(first, startsWith('```html\n<!DOCTYPE html>'));
    expect(first, contains("var who='User';"));
    expect(first, contains("s=s.replace(/x/g,'<b></b>');"));
    expect(first, contains('```\n\n```\n<!DOCTYPE html>\n<html><body><div>状态</div>'));
    expect(first, isNot(contains('<StatusPlaceHolderImpl/>')));
    expect(first, isNot(contains('\r')));

    // The other greeting: the variable update a <div>/<style> panel too.
    final second = await shown(1);
    expect(second, contains('<div><details><summary>变量</summary>[{"op":"replace"}]'));
    expect(second, contains('```\n<!DOCTYPE html>\n<html><body><div>状态</div>'));
  });
}
