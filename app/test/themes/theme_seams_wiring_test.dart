// One smoke check per kind of theme-pack field that reaches the screen:
// tokens, shapes, typography, and each chat component that reads them.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/empty_actions.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/chat/model_sheet.dart';
import 'package:dsh_app/ui/chat/render/code_block.dart';
import 'package:dsh_app/ui/chat/render/markdown_blocks.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:dsh_app/ui/chat/widgets/whale_tail.dart';
import 'package:dsh_app/ui/common/status_dot.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../chat/support/harness.dart';
import '../chat/support/sample_chat.dart';
import '../support/test_fonts.dart';

const _red = 0xFFCC2200;
const _green = 0xFF117733;

/// A pack that sets one of everything this file checks.
const _pack = ThemePack(
  id: 'seams',
  name: 'Seams',
  palette: ThemePaletteSpec(
    light: ThemeColorOverrides(
      link: _red,
      heading: _green,
      rule: _red,
      userBubbleBorder: _red,
      assistantBorder: _green,
      composerFill: 0xFFFFF4E0,
      composerBorder: _red,
      sendButton: _green,
      onSendButton: 0xFFFFFFFF,
      inlineCodeBg: 0xFFFFEEDD,
      inlineCodeFg: _red,
      cardFill: 0x80FFFFFF,
      chromeFill: 0xFFEEEEFF,
      sheetFill: 0xFFEEFFEE,
      hairline: _red,
      textTertiary: _green,
      success: _red,
      syntaxKeyword: _red,
    ),
  ),
  typography: ThemeTypographySpec(
    readingLetterSpacing: 0.5,
    headingLetterSpacing: 2,
    headingWeight: 800,
    headingScale: 1.2,
    codeScale: 1.2,
  ),
  shapes: ThemeShapeSpec(
    cornerStyle: ThemeCornerStyle.bevel,
    bubbleCorners: ThemeBubbleCorners.tail,
    bubbleRadius: 18,
    cardRadius: 30,
    codeRadius: 8,
    composerRadius: 6,
    bubblePadH: 20,
    bubblePadV: 12,
  ),
  components: ThemeComponentSpec(
    userBubbleStyle: ThemeUserBubbleStyle.outlined,
    assistantStyle: ThemeAssistantStyle.quote,
    sendButtonStyle: ThemeSendButtonStyle.outlined,
    sendButtonShape: ThemeSendButtonShape.square,
    codeHeaderStyle: ThemeCodeHeaderStyle.plain,
    turnDivider: ThemeTurnDivider.dashed,
    headingStyle: ThemeHeadingStyle.marker,
    bulletStyle: ThemeBulletStyle.square,
    headerTitleFont: ThemeHeaderTitleFont.code,
    userLabel: ThemeLocalizedText(zh: '旅人', en: 'Traveller'),
    assistantLabel: ThemeLocalizedText(zh: '向导'),
    composerHint: ThemeLocalizedText(zh: '写点什么'),
  ),
  emptyState: ThemeEmptyStateSpec(
    layout: ThemeEmptyLayout.editorial,
    heroStyle: ThemeHeroStyle.seal,
    heroGlyph: '墨',
    heroScale: 1.5,
    greeting: ThemeLocalizedText(zh: '见字如面'),
    subtitle: ThemeLocalizedText(zh: '落笔吧'),
  ),
);

ThemeData _theme(ThemePack? pack, [Brightness brightness = Brightness.light]) {
  final accent = pack == null ? AppAccent.mist : AppAccent.fromThemePack(pack);
  final base = brightness == Brightness.dark
      ? buildDarkTheme(accent: accent, themePack: pack)
      : buildLightTheme(accent: accent, themePack: pack);
  return withTestFonts(base.copyWith(textTheme: base.textTheme.apply(fontFamilyFallback: const [cjkFamily])));
}

Future<void> _pump(WidgetTester tester, ThemePack? pack, Widget child, {List<Override> overrides = const []}) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(pack),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: child is ChatScreen ? child : Scaffold(body: Center(child: child)),
      ),
    ),
  );
  await pumpFrames(tester, 8);
}

T _decorationOf<T extends Decoration>(WidgetTester tester, Finder within) => tester
    .widgetList<DecoratedBox>(find.descendant(of: within, matching: find.byType(DecoratedBox)))
    .map((box) => box.decoration)
    .whereType<T>()
    .first;

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await WhaleSprites.load();
    chatClock = () => DateTime(2026, 10, 23, 15, 20);
  });

  test('tokens land on the surfaces, the semantic colours and the style', () {
    final theme = _theme(_pack);
    final surfaces = theme.extension<DshSurfaces>()!;
    final plain = _theme(const ThemePack(id: 'plain', name: 'Plain')).extension<DshSurfaces>()!;
    expect(surfaces.card.fill, const Color(0x80FFFFFF));
    // The no-blur fill is flattened onto the page, never left translucent.
    expect(surfaces.card.fallbackFill.a, 1);
    expect(surfaces.chrome.fill, const Color(0xFFEEEEFF));
    expect(surfaces.sheet.fill, const Color(0xFFEEFFEE));
    for (final tier in [surfaces.chrome, surfaces.sheet, surfaces.card, surfaces.pill]) {
      expect(tier.hairline, const Color(_red));
    }
    expect(surfaces.pill.fill, plain.pill.fill);
    final dsh = theme.extension<DshColors>()!;
    expect(dsh.textTertiary, const Color(_green));
    expect(dsh.success, const Color(_red));
    final style = theme.extension<DshThemeStyle>()!;
    expect(style.link, const Color(_red));
    expect(style.sendButton, const Color(_green));
    expect(style.lerp(const DshThemeStyle(), 0).inlineCodeFg, const Color(_red));
  });

  test('typography: tracking, heading weight and code scale', () {
    final theme = _theme(_pack);
    final style = theme.extension<DshThemeStyle>()!;
    expect(style.readingTextStyle(const TextStyle(fontSize: 16)).letterSpacing, 0.5);
    final heading = style.headingTextStyle(const TextStyle(fontSize: 20));
    expect((heading.fontWeight, heading.letterSpacing, heading.fontSize), (FontWeight.w800, 2, 24));
    expect(theme.textTheme.displaySmall!.fontWeight, FontWeight.w800);
    expect(theme.textTheme.titleMedium!.fontWeight, FontWeight.w600);
    expect(style.codeTextStyle(AppType.mono()).fontSize, closeTo(13 * 1.2, 0.001));
    expect(style.headerTitleTextStyle(const TextStyle(fontSize: 15)).fontFamily, AppType.monoFamily);
    // Unset fields leave the styles alone.
    const plain = DshThemeStyle(
      pack: ThemePack(id: 'plain', name: 'Plain'),
    );
    expect(
      plain.headingTextStyle(const TextStyle(fontSize: 20, fontWeight: FontWeight.w300)).fontWeight,
      FontWeight.w300,
    );
    expect(plain.codeTextStyle(AppType.mono()), AppType.mono());
  });

  test('shapes: one corner style, absolute radii, an uneven bubble', () {
    final style = _theme(_pack).extension<DshThemeStyle>()!;
    final card = style.cardShape() as BeveledRectangleBorder;
    // Half the radius, capped at 10: a chamfer, not a diamond.
    expect(card.borderRadius, const BorderRadius.all(Radius.circular(10)));
    final bubble = style.bubbleShape() as BeveledRectangleBorder;
    expect(
      bubble.borderRadius,
      const BorderRadius.all(Radius.circular(9)).copyWith(bottomRight: const Radius.circular(2)),
    );
    expect((style.codeRadius, style.composerRadius), (8, 6));

    DshThemeStyle of(ThemeShapeSpec shapes) => DshThemeStyle(
      pack: ThemePack(id: 'p', name: 'P', shapes: shapes),
    );
    final round = of(const ThemeShapeSpec(cornerStyle: ThemeCornerStyle.round, bubbleCorners: ThemeBubbleCorners.leaf));
    final leaf = round.bubbleShape(Colors.black, 1) as RoundedRectangleBorder;
    expect(
      leaf.borderRadius,
      const BorderRadius.only(
        topLeft: Radius.circular(20),
        bottomRight: Radius.circular(20),
        topRight: Radius.circular(6),
        bottomLeft: Radius.circular(6),
      ),
    );
    // The defaults are the shapes drawn before these fields existed.
    final plain = of(const ThemeShapeSpec());
    expect(plain.cardShape(), AppShape.card);
    expect(plain.bubbleShape(), AppShape.bubble);
  });

  testWidgets('user bubble: corners, padding, border token and label', (tester) async {
    await _pump(tester, _pack, const UserBubble(text: '你好'));
    expect(find.text('旅人'), findsOneWidget);
    final decoration = _decorationOf<ShapeDecoration>(tester, find.byType(UserBubble));
    final shape = decoration.shape as BeveledRectangleBorder;
    expect(shape.side.color, const Color(_red));
    final bubble = tester.getRect(
      find.descendant(of: find.byType(UserBubble), matching: find.byType(DecoratedBox)).first,
    );
    final text = tester.getRect(find.text('你好'));
    expect(text.left - bubble.left, 20);
    expect(text.top - bubble.top, 12);
    // The label sits 4 above the bubble, its right end on the bubble's.
    final label = tester.getRect(find.text('旅人'));
    expect(bubble.top - label.bottom, 4);
    expect(label.right, bubble.right);
  });

  testWidgets('without a pack the bubble has no label and its old shape', (tester) async {
    await _pump(tester, null, const UserBubble(text: '你好'));
    final decoration = _decorationOf<ShapeDecoration>(tester, find.byType(UserBubble));
    expect(decoration.shape, AppShape.bubble);
    expect(find.descendant(of: find.byType(UserBubble), matching: find.byType(Row)), findsNothing);
  });

  testWidgets('assistant quote: full-width tinted card, rule token, label', (tester) async {
    await _pump(tester, _pack, AssistantMessage(item: assistant(2, '好。')));
    expect(find.text('向导'), findsOneWidget);
    final theme = Theme.of(tester.element(find.byType(AssistantMessage)));
    final quote = _decorationOf<BoxDecoration>(tester, find.byType(AssistantMessage));
    expect(quote.color, theme.colorScheme.primary.withValues(alpha: 0.06));
    expect((quote.border! as Border).left.color, const Color(_red));
    final card = tester.getSize(find.descendant(of: find.byType(AssistantMessage), matching: find.byType(Stack)).first);
    expect(card.width, tester.getSize(find.byType(AssistantMessage)).width);
    // The optional outline takes the assistantBorder token.
    final outline = _decorationOf<ShapeDecoration>(tester, find.byType(AssistantMessage));
    expect((outline.shape as BeveledRectangleBorder).side.color, const Color(_green));
  });

  testWidgets('assistant card: a short reply is as wide as the column', (tester) async {
    await _pump(tester, ThemePack.sakuraCard, AssistantMessage(item: assistant(2, '好。')));
    final card = tester.getSize(
      find.descendant(of: find.byType(AssistantMessage), matching: find.byType(DecoratedBox)).first,
    );
    expect(card.width, tester.getSize(find.byType(AssistantMessage)).width);
  });

  testWidgets('composer: hint, fill and border, square outlined keys', (tester) async {
    final input = TextEditingController();
    addTearDown(input.dispose);
    await _pump(
      tester,
      _pack,
      Composer(
        controller: input,
        connected: true,
        running: false,
        onSend: () {},
        onStop: () {},
        leading: AttachButton(onPressed: () {}),
      ),
    );
    expect(find.text('写点什么'), findsOneWidget);
    final glass = tester.widget<GlassSurface>(
      find.descendant(of: find.byType(Composer), matching: find.byType(GlassSurface)).first,
    );
    expect(glass.style!.fill, const Color(0xFFFFF4E0));
    expect(glass.style!.hairline, const Color(_red));
    expect(glass.borderRadius, const BorderRadius.all(Radius.circular(6)));
    final plus = tester.widget<Container>(
      find.ancestor(of: find.byIcon(AppIcons.add), matching: find.byType(Container)).first,
    );
    expect((plus.decoration! as ShapeDecoration).shape, isA<RoundedRectangleBorder>());

    input.text = '在吗';
    await pumpFrames(tester, 8);
    final key = tester.widget<AnimatedContainer>(
      find.ancestor(of: find.byIcon(AppIcons.send), matching: find.byType(AnimatedContainer)).first,
    );
    final decoration = key.decoration! as ShapeDecoration;
    final theme = Theme.of(tester.element(find.byType(Composer)));
    expect(decoration.color, const Color(_green));
    expect((decoration.shape as RoundedRectangleBorder).side, BorderSide(color: theme.colorScheme.primary, width: 1.5));
    expect(tester.widget<Icon>(find.byIcon(AppIcons.send)).color, const Color(0xFFFFFFFF));
  });

  testWidgets('header: the model chip wears the same glass as the keys', (tester) async {
    Future<(GlassStyle?, GlassStyle?)> glass(ThemePack? pack) async {
      await _pump(
        tester,
        pack,
        ChatHeader(
          title: '对话',
          status: const HeaderStatus(StatusTone.ok, '本机'),
          trailing: ModelChip(selection: testCatalog.defaultSelection, onSelected: (_) {}, grouped: true),
          onOpenDrawer: () {},
        ),
        overrides: ChatHarness().overrides,
      );
      GlassStyle? of(Finder within) =>
          tester.widget<GlassSurface>(find.descendant(of: within, matching: find.byType(GlassSurface)).first).style;
      return (of(find.byKey(const ValueKey('chat-menu'))), of(find.byType(ModelChip)));
    }

    final (key, chip) = await glass(
      _pack.copyWith(components: _pack.components.copyWith(headerStyle: ThemeHeaderStyle.ghost)),
    );
    expect(chip!.fill, Colors.transparent);
    expect(chip.hairline, Colors.transparent);
    expect(chip, same(key));
    expect(await glass(null), (null, null));
  });

  testWidgets('code block: radius, corner style, plain header, scale', (tester) async {
    await _pump(tester, _pack, const CodeBlock(code: 'final a = 1;', language: 'dart'));
    final box = _decorationOf<ShapeDecoration>(tester, find.byType(CodeBlock));
    expect((box.shape as BeveledRectangleBorder).borderRadius, const BorderRadius.all(Radius.circular(4)));
    expect(find.descendant(of: find.byType(CodeBlock), matching: find.byType(ClipPath)), findsOneWidget);
    final header = tester.widget<ColoredBox>(
      find.descendant(of: find.byType(CodeBlock), matching: find.byType(ColoredBox)).first,
    );
    expect(header.color, Colors.transparent);
    final code = tester.widget<RichText>(find.textContaining('final a', findRichText: true).last);
    expect((code.text as TextSpan).children!.single.style!.fontSize, closeTo(13 * 1.2, 0.001));
  });

  testWidgets('code block: the pack colours the syntax roles it names', (tester) async {
    const code = 'final a = "x"; // note';
    Future<Map<String, TextStyle?>> styles(ThemePack? pack) async {
      await _pump(tester, pack, const CodeBlock(code: code, language: 'dart'));
      final text = tester.widget<RichText>(find.textContaining('final a', findRichText: true).last).text as TextSpan;
      final found = <String, TextStyle?>{};
      text.visitChildren((span) {
        if (span is TextSpan && span.text != null) found[span.text!] = span.style;
        return true;
      });
      return found;
    }

    // Same accent, so the neutral cells match and only the named role differs.
    final plain = await styles(_pack.copyWith(palette: const ThemePaletteSpec()));
    final themed = await styles(_pack);
    expect(themed['final']!.color, const Color(_red));
    expect(plain['final']!.color, dshHighlightTheme(Brightness.light)['keyword']!.color);
    expect(themed['"x"'], plain['"x"']);
    expect(themed['// note'], plain['// note']);
    expect(themed['// note']!.fontStyle, FontStyle.italic);
    // A pack that names none of them highlights with the default map itself.
    final unset = _theme(const ThemePack(id: 'plain', name: 'Plain')).extension<DshThemeStyle>()!.syntax;
    expect(unset, isNull);
    expect(dshHighlightTheme(Brightness.light, AppAccent.mist, unset), same(dshHighlightTheme(Brightness.light)));
  });

  testWidgets('reply Markdown: link, heading and bullet styles, only in a reply', (tester) async {
    const source = '## 标题\n\n- 一\n- 二\n\n看 [这里](https://example.com) 和 `code`。\n\n```dart\nvoid a() {}\n```';
    await _pump(tester, _pack, const MarkdownBody(text: source, selectable: false, replyTypography: true));
    final context = tester.element(find.byType(GptMarkdown).first);
    final markdownTheme = GptMarkdownTheme.of(context);
    expect(markdownTheme.linkColor, const Color(_red));
    expect(markdownTheme.inlineCode.color, const Color(_red));
    expect(markdownTheme.inlineCode.backgroundColor, const Color(0xFFFFEEDD));
    // The heading token, the pack's weight and tracking, the scale on h2's own size.
    expect(markdownTheme.h2!.color, const Color(_green));
    expect((markdownTheme.h2!.fontWeight, markdownTheme.h2!.letterSpacing), (FontWeight.w800, 2));
    expect(markdownTheme.h2!.fontSize, closeTo(18 * 1.2, 0.001));
    final marker = tester.widget<DecoratedBox>(
      find.ancestor(of: find.textContaining('标题', findRichText: true), matching: find.byType(DecoratedBox)).first,
    );
    expect(
      ((marker.decoration as BoxDecoration).border! as Border).left,
      const BorderSide(color: Color(_red), width: 3),
    );
    expect(find.byType(ListItem).first, paints..rect());
    // Inside a card or quote reply the block gives up its own outline.
    final block = _decorationOf<ShapeDecoration>(tester, find.byType(CodeBlock));
    expect((block.shape as OutlinedBorder).side, BorderSide.none);

    // The same pack, a document page: none of it.
    await _pump(tester, _pack, const MarkdownBody(text: source, selectable: false));
    final plain = GptMarkdownTheme.of(tester.element(find.byType(GptMarkdown).first));
    final scheme = Theme.of(tester.element(find.byType(MarkdownBody))).colorScheme;
    expect(plain.linkColor, scheme.primary);
    expect(plain.h2!.fontWeight, FontWeight.w600);
    expect(find.byType(ListItem).first, paints..circle());
    expect((_decorationOf<ShapeDecoration>(tester, find.byType(CodeBlock)).shape as OutlinedBorder).side.width, 0.5);
  });

  testWidgets('turn divider: drawn in the gap, no row changes height', (tester) async {
    ChatState conversation() => ChatState(
      items: [user(1, '第一问'), assistant(2, '第一答'), user(3, '第二问'), assistant(4, '第二答')],
      title: '对话',
      loading: false,
    );
    Future<List<Rect>> rows(ThemePack pack) async {
      final harness = ChatHarness(session: 's1', states: {'s1': conversation()});
      await _pump(tester, pack, const ChatScreen(), overrides: harness.overrides);
      return [
        for (final text in const ['第一问', '第一答', '第二问', '第二答'])
          tester.getRect(find.text(text, findRichText: true).first),
      ];
    }

    final without = await rows(
      _pack.copyWith(components: _pack.components.copyWith(turnDivider: ThemeTurnDivider.none)),
    );
    Finder divided() => find.byWidgetPredicate(
      (w) => w is Container && '${w.foregroundDecoration.runtimeType}' == '_TurnDividerDecoration',
    );
    expect(divided(), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    final withDivider = await rows(_pack);
    expect(withDivider, without);
    // Only the second turn's first message: nothing above the first one.
    expect(divided(), findsOneWidget);
    expect(find.descendant(of: divided(), matching: find.text('第二问', findRichText: true)), findsWidgets);
  });

  testWidgets('empty state: seal, copy and one left line', (tester) async {
    await _pump(
      tester,
      _pack,
      ChatEmptyState(connected: true, onSuggestion: (_) {}, workspace: '项目', onWorkspace: () {}, tips: const ['提示']),
    );
    expect(find.text('见字如面'), findsOneWidget);
    expect(find.text('落笔吧'), findsOneWidget);
    expect(find.text('墨'), findsOneWidget);
    expect(find.byType(WhaleTail), findsNothing);
    final theme = Theme.of(tester.element(find.byType(ChatEmptyState)));
    final seal = find.ancestor(of: find.text('墨'), matching: find.byType(DecoratedBox)).first;
    final sealDecoration = tester.widget<DecoratedBox>(seal).decoration as ShapeDecoration;
    expect(sealDecoration.color, theme.colorScheme.primary);
    expect(sealDecoration.shape, isA<BeveledRectangleBorder>());
    expect(tester.getSize(find.ancestor(of: find.text('墨'), matching: find.byType(SizedBox)).first).width, 56 * 1.5);
    expect(find.ancestor(of: find.text('墨'), matching: find.byType(Transform)), findsWidgets);

    // Greeting, subtitle, the chip's fill and the first card's badge share the line.
    final line = tester.getRect(find.text('见字如面')).left;
    expect(tester.getRect(find.text('落笔吧')).left, line);
    expect(tester.getRect(find.byType(QuietChip)).left, line);
    final card = tester.getRect(find.byType(SuggestionCard).first);
    expect(card.left + SuggestionCardMetrics.padH, line);
    expect(tester.getRect(find.byIcon(AppIcons.tip).last).left, line);
    // Not connected: the pack's subtitle gives way to the connection state.
    await _pump(tester, _pack, ChatEmptyState(connected: false, connecting: true, onSuggestion: (_) {}));
    expect(find.text('落笔吧'), findsNothing);
  });

  testWidgets('a mono pack keeps the suggestion details, wrapped if they must', (tester) async {
    await _pump(tester, ThemePack.terminalNoir, ChatEmptyState(connected: true, onSuggestion: (_) {}, tips: const []));
    for (final suggestion in defaultSuggestions) {
      expect(find.text(suggestion.detail!), findsOneWidget);
    }
    final theme = Theme.of(tester.element(find.byType(ChatEmptyState)));
    for (final icon in tester.widgetList<Icon>(
      find.descendant(of: find.byType(SuggestionCard), matching: find.byType(Icon)),
    )) {
      expect(icon.color, theme.colorScheme.primary);
    }
    expect(tester.takeException(), isNull);
  });
}
