// Turns the pack parser's messages ("shapes.cornerScale must be between 0.0 and 1.6") into the Theme Studio's
// own words: the field by the name its control carries, the rule in a short sentence.

import '../../../l10n/l10n.dart';
import 'theme_studio_colors.dart' show studioColorName;

/// A field's path in theme.json → the name on its control, Chinese then English.
const _fieldNames = <String, (String, String)>{
  'id': ('主题 ID', 'Theme ID'),
  'name': ('主题名称', 'Theme name'),
  'description': ('一句话简介', 'Summary'),
  'title': ('名称', 'Name'),
  'title.zh': ('中文名称', 'Chinese name'),
  'title.en': ('英文名称', 'English name'),
  'tags': ('标签', 'Tags'),
  'tag': ('标签', 'Tag'),
  'author': ('作者', 'Author'),
  'license': ('许可协议', 'License'),
  'source': ('来源链接', 'Source link'),
  'palette.seed': ('主色', 'Accent'),
  'palette.seedDark': ('深色模式的主色', 'Accent in dark mode'),
  'palette.tintHue': ('背景和文字偏向的色调', 'Tint of backgrounds and text'),
  'palette.tintChroma': ('色调的浓淡', 'Tint strength'),
  'palette.glowOpacity': ('光晕强度', 'Glow strength'),
  'surfaces.preset': ('材质', 'Material'),
  'surfaces.chromeBlur': ('顶栏模糊', 'Top bar blur'),
  'surfaces.sheetBlur': ('面板模糊', 'Sheet blur'),
  'surfaces.cardOpacity': ('卡片不透明度', 'Card opacity'),
  'surfaces.pillOpacity': ('胶囊不透明度', 'Pill opacity'),
  'surfaces.hairlineWidth': ('材质的描边粗细', 'Edge width'),
  'surfaces.rimOpacity': ('边缘高光', 'Edge highlight'),
  'surfaces.shadowOpacity': ('阴影', 'Shadow'),
  'surfaces.backdropImage': ('背景图', 'Backdrop'),
  'surfaces.backdropOpacity': ('背景图不透明度', 'Backdrop opacity'),
  'surfaces.backdropRepeat': ('小图平铺', 'Tile the image'),
  'surfaces.backdropAnimate': ('动图保持播放', 'Keep animated images playing'),
  'surfaces.backdropBlur': ('背景图模糊', 'Backdrop blur'),
  'surfaces.backdropAlign': ('背景图对齐', 'Backdrop alignment'),
  'surfaces.pattern': ('背景纹理', 'Backdrop pattern'),
  'surfaces.patternOpacity': ('纹理深浅', 'Pattern strength'),
  'surfaces.patternScale': ('纹理疏密', 'Pattern spacing'),
  'surfaces.glowLayout': ('光晕位置', 'Glow position'),
  'typography.uiFont': ('界面字体', 'Interface font'),
  'typography.readingFont': ('回复字体', 'Reply font'),
  'typography.headingFont': ('标题字体', 'Heading font'),
  'typography.codeFont': ('代码字体', 'Code font'),
  'typography.readingScale': ('回复字号', 'Reply size'),
  'typography.readingLineHeight': ('回复行距', 'Reply line spacing'),
  'typography.readingLetterSpacing': ('回复字距', 'Reply letter spacing'),
  'typography.headingScale': ('标题字号', 'Heading size'),
  'typography.headingLetterSpacing': ('标题字距', 'Heading letter spacing'),
  'typography.headingWeight': ('标题粗细', 'Heading weight'),
  'typography.codeScale': ('代码字号', 'Code size'),
  'shapes.cornerScale': ('整体圆角', 'Overall roundness'),
  'shapes.cornerStyle': ('角型', 'Corner style'),
  'shapes.bubbleCorners': ('气泡四角', 'Bubble corners'),
  'shapes.bubbleRadius': ('气泡圆角', 'Bubble radius'),
  'shapes.cardRadius': ('卡片圆角', 'Card radius'),
  'shapes.codeRadius': ('代码块圆角', 'Code block radius'),
  'shapes.composerRadius': ('输入框圆角', 'Composer radius'),
  'shapes.bubblePadH': ('气泡左右留白', 'Bubble side padding'),
  'shapes.bubblePadV': ('气泡上下留白', 'Bubble top and bottom padding'),
  'shapes.borderWidth': ('描边粗细', 'Border width'),
  'shapes.turnGap': ('两轮对话之间', 'Between turns'),
  'shapes.inTurnGap': ('同一轮里的消息之间', 'Within a turn'),
  'shapes.gutter': ('左右页边距', 'Side margin'),
  'components.headerStyle': ('顶栏', 'Top bar'),
  'components.composerStyle': ('输入框', 'Composer'),
  'components.sendButtonStyle': ('发送键', 'Send button'),
  'components.sendButtonShape': ('发送键形状', 'Send button shape'),
  'components.userBubbleStyle': ('我的消息', 'My messages'),
  'components.assistantStyle': ('助手回复', 'Replies'),
  'components.codeBlockStyle': ('代码块', 'Code blocks'),
  'components.codeHeaderStyle': ('代码块标题条', 'Code block header'),
  'components.turnDivider': ('两轮对话之间的分隔', 'Divider between turns'),
  'components.headingStyle': ('回复里的标题', 'Headings in replies'),
  'components.bulletStyle': ('列表符号', 'List bullets'),
  'components.headerTitleFont': ('顶栏标题用哪种字体', 'Top bar title font'),
  'components.suggestionCardStyle': ('建议卡样式', 'Suggestion card style'),
  'components.useReadingFontForReply': ('回复正文用回复字体', 'Use the reply font for replies'),
  'components.userLabel': ('我的小标签', 'My label'),
  'components.assistantLabel': ('助手小标签', 'Assistant label'),
  'components.composerHint': ('输入框提示语', 'Composer hint'),
  'components.assistantAvatar': ('助手头像', 'Assistant avatar'),
  'components.userAvatar': ('我的头像', 'My avatar'),
  'emptyState.layout': ('新对话页的版式', 'New chat layout'),
  'emptyState.heroStyle': ('主视觉', 'Hero'),
  'emptyState.heroImage': ('主视觉图', 'Hero image'),
  'emptyState.heroGlyph': ('主视觉上的字', 'Hero characters'),
  'emptyState.heroScale': ('主视觉大小', 'Hero size'),
  'emptyState.greeting': ('问候语', 'Greeting'),
  'emptyState.subtitle': ('副标题', 'Subtitle'),
  'emptyState.useReadingFontForGreeting': ('问候语用回复字体', 'Use the reply font for the greeting'),
  'emptyState.showConnectedSubtitle': ('连上后显示副标题', 'Show the subtitle once connected'),
  'emptyState.suggestionsDisplay': ('建议卡', 'Suggestions'),
};

/// The control's name for [path], or null when no control edits it.
String? _fieldName(String path, bool english) {
  String? pick((String, String)? names) => names == null ? null : (english ? names.$2 : names.$1);
  if (pick(_fieldNames[path]) case final name?) return name;
  for (final (mode, zh, en) in const [('light', '浅色', 'Light'), ('dark', '深色', 'Dark')]) {
    final prefix = 'palette.$mode.';
    if (!path.startsWith(prefix)) continue;
    final color = studioColorName(path.substring(prefix.length), english: english);
    return color == null ? null : '${english ? en : zh} · $color';
  }
  // One half of a text the pack supplies in two languages.
  for (final (suffix, zh, en) in const [('.zh', '中文', 'Chinese'), ('.en', '英文', 'English')]) {
    if (!path.endsWith(suffix)) continue;
    final base = pick(_fieldNames[path.substring(0, path.length - suffix.length)]);
    return base == null ? null : (english ? '$base ($en)' : '$base（$zh）');
  }
  return null;
}

String _plain(String number) => number.replaceFirst(RegExp(r'\.0$'), '');

/// [message] from the pack parser, said the way the studio's controls are labelled. A message in a form this
/// does not know comes back as it was.
String studioProblemText(String message) {
  final english = AppLocale.isEnglish;
  final unknown = RegExp(r'^Unknown theme\.json field: (.+)$').firstMatch(message);
  if (unknown != null) {
    return english ? 'There is no field called "${unknown[1]}".' : '不认识「${unknown[1]}」这一项。';
  }
  final text = message.startsWith('theme.json ') ? message.substring('theme.json '.length) : message;
  final space = text.indexOf(' ');
  if (space <= 0) return message;
  final path = text.substring(0, space);
  final rule = text.substring(space + 1);
  final known = _fieldName(path, english);
  if (english) return known == null ? message : '$known $rule';
  final name = '「${known ?? path}」';
  final range = RegExp(r'between (\S+) and (\S+)$').firstMatch(rule);
  if (rule.startsWith('must be between ') && range != null) {
    return '$name要在 ${_plain(range[1]!)} 到 ${_plain(range[2]!)} 之间。';
  }
  if (rule.startsWith('must be a multiple of 100') && range != null) {
    return '$name要填 ${range[1]} 到 ${range[2]} 之间的整百数。';
  }
  if (rule.startsWith('is not supported') || rule.startsWith('is not a supported')) return '$name这一项不认识。';
  if (rule == 'is invalid') return '$name填得不对。';
  if (rule.startsWith('must be #RRGGBB')) return '$name的颜色要写成 #RRGGBB。';
  if (rule.contains('or a local ')) return '$name要选一种自带的字体，或者包里的字体文件。';
  if (rule.startsWith('must be a local ')) return '$name要选一个包里的文件。';
  if (rule.startsWith('is required when ')) return '$name还没填。';
  if (rule == 'must be a boolean') return '$name只能是 true 或 false。';
  if (rule == 'must be an object' || rule == 'must be a string') return '$name的写法不对。';
  if (rule == 'needs zh or en') return '$name的中文和英文至少要填一个。';
  final length = RegExp(r'^must be (?:non-empty up to|1 to) (\d+) char').firstMatch(rule);
  if (length != null) return '$name要填 1 到 ${length[1]} 个字。';
  return switch (path) {
    'id' => '主题 ID 只能用小写字母、数字和连字符，最多 40 个字符。',
    'tags' when rule.contains('unique') => '标签不能重复。',
    'tags' => '标签最多 8 个。',
    'source' => '来源链接要以 https:// 开头。',
    _ => message,
  };
}
