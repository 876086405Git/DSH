// 消息里的组件 (docs/design/roleplay-ui.md §5, roleplay-agent.md §6.2): the
// model writes <dsh-letter from="林" date="三月初七">见字如面……</dsh-letter>,
// <dsh-item name="铜钥匙" take>…</dsh-item> and the like. Outside an HTML block
// they are drawn natively, in the story's colours; the whole-page canvas
// draws them as Web Components. A dsh- tag of a kind not drawn here reads as
// its text, as SillyTavern shows an unknown tag.

/// The components drawn here.
enum TavernComponentKind { letter, item, clue, phone, roll, notice, game }

/// One component tag: its kind, its attributes (lower-case names; a bare
/// attribute such as `take` is there with an empty value) and its text.
final class TavernComponent {
  const TavernComponent(this.kind, this.attributes, this.body);

  final TavernComponentKind kind;
  final Map<String, String> attributes;

  /// The text between the tags, as plain text: <br> a line break, other tags
  /// gone, entities decoded, trimmed.
  final String body;

  /// The first of [names] that has a non-blank value, trimmed; null if none.
  String? attribute(List<String> names) {
    for (final name in names) {
      final value = attributes[name]?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  /// Whether the tag carries [name] at all (`<dsh-item take>`).
  bool has(String name) => attributes.containsKey(name);
}

final _tag = RegExp(
  '<dsh-([a-z][a-z0-9-]*)((?:[^>"\']|"[^"]*"|\'[^\']*\')*?)(?:/>|>([\\s\\S]*?)</dsh-\\1\\s*>)',
  caseSensitive: false,
);
final _attribute = RegExp('([a-zA-Z_][\\w:.-]*)(?:\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s"\'=<>`/]+)))?');
final _entity = RegExp(r'&(?:#(\d+)|#x([0-9a-fA-F]+)|(amp|lt|gt|quot|apos|nbsp));');
const _named = {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': '\u00a0'};

String _decode(String text) => text.replaceAllMapped(_entity, (m) {
  final code = m[1] != null ? int.tryParse(m[1]!) : (m[2] != null ? int.tryParse(m[2]!, radix: 16) : null);
  if (code != null) return code > 0 && code <= 0x10ffff ? String.fromCharCode(code) : m[0]!;
  return _named[m[3]] ?? m[0]!;
});

String _plain(String html) => _decode(
  html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p\s*>\s*<p[^>]*>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<[^<>]*>'), ''),
).trim();

Map<String, String> _attributes(String source) => {
  for (final m in _attribute.allMatches(source)) m[1]!.toLowerCase(): _decode(m[2] ?? m[3] ?? m[4] ?? ''),
};

TavernComponentKind? _kindOf(String name) {
  for (final kind in TavernComponentKind.values) {
    if (kind.name == name.toLowerCase()) return kind;
  }
  return null;
}

/// [text] split at its component tags, in order: [String]s (the text between,
/// as written) and [TavernComponent]s. A dsh- tag of another kind joins the
/// text as its words; a tag never closed stays as written.
List<Object> tavernSplitComponents(String text) {
  final pieces = <Object>[];
  final buffer = StringBuffer();
  var at = 0;
  for (final m in _tag.allMatches(text)) {
    buffer.write(text.substring(at, m.start));
    at = m.end;
    final kind = _kindOf(m[1]!);
    final body = _plain(m[3] ?? '');
    if (kind == null) {
      buffer.write(body);
      continue;
    }
    if (buffer.isNotEmpty) pieces.add(buffer.toString());
    buffer.clear();
    pieces.add(TavernComponent(kind, _attributes(m[2] ?? ''), body));
  }
  buffer.write(text.substring(at));
  if (buffer.isNotEmpty) pieces.add(buffer.toString());
  return pieces;
}

/// [text] with its dsh- tags taken out and their words kept, for where
/// components are not drawn (a reply still being written, 视觉小说). A tag
/// still being written at the end goes too.
String tavernComponentTagsOut(String text) {
  if (!text.contains('<')) return text;
  return text
      .replaceAll(RegExp(r'</?dsh-[a-z][^<>]*>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<(?:/?(?:d(?:s(?:h(?:-[^<>]*)?)?)?)?)?$', caseSensitive: false), '');
}
