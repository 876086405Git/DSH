import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/themes/theme_library.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/chat/render/code_block.dart';
import 'package:dsh_app/ui/chat/widgets/whale_tail.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/settings/appearance/theme_studio_colors.dart';
import 'package:dsh_app/ui/settings/appearance/theme_studio_controller.dart';
import 'package:dsh_app/ui/settings/appearance/theme_studio_controls.dart';
import 'package:dsh_app/ui/settings/appearance/theme_studio_json.dart';
import 'package:dsh_app/ui/settings/appearance/theme_studio_preview.dart';
import 'package:dsh_app/ui/settings/appearance/theme_studio_problems.dart';
import 'package:dsh_app/ui/settings/appearance/theme_studio_sheet.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show tinyPng;

Widget _app(Widget body) => MaterialApp(
  theme: buildLightTheme(),
  home: Scaffold(body: body),
);

/// The studio as the app opens it: a sheet over a page, here a phone 390 wide.
Future<void> _openStudio(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [themeLoadedFontsProvider.overrideWith((ref, id) async => const <String, String>{})],
      child: MaterialApp(
        theme: buildLightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showAppSheet<ThemePack>(
                context,
                isScrollControlled: true,
                builder: (_) => const ThemeStudioSheet(initial: ThemePack.paper),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(WhaleSprites.load);

  testWidgets('closing asks first once the draft has changed, and not before', (tester) async {
    await _openStudio(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ThemeStudioSheet), findsNothing);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('青瓷'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃修改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.byType(ThemeStudioSheet), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃'));
    await tester.pumpAndSettle();
    expect(find.byType(ThemeStudioSheet), findsNothing);
  });

  testWidgets('the preview draws both pages with the chat\'s own widgets, and nothing overflows', (tester) async {
    await _openStudio(tester);
    expect(find.byType(CodeBlock), findsOneWidget);
    expect(find.byType(ChatEmptyState), findsNothing);

    await tester.tap(find.text('新对话页').first);
    await tester.pumpAndSettle();
    expect(find.byType(ChatEmptyState), findsOneWidget);
    expect(find.byType(CodeBlock), findsNothing);

    // The jump row brings a group up from below the fold.
    final shapes = find.text('形状与间距').last;
    expect(tester.getTopLeft(shapes).dy, greaterThan(844));
    final jump = find.byKey(const ValueKey('theme-studio-jump-shapes'));
    await tester.ensureVisible(jump);
    await tester.pumpAndSettle();
    await tester.tap(jump);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(shapes).dy, lessThan(600));
    final back = find.byKey(const ValueKey('theme-studio-jump-info'));
    await tester.ensureVisible(back);
    await tester.pumpAndSettle();
    await tester.tap(back);
    await tester.pumpAndSettle();

    // The draft reaches the preview's theme a beat after the control.
    await tester.tap(find.text('深色'));
    await tester.tap(find.text('青瓷'));
    await tester.pump(const Duration(milliseconds: 200));
    final preview = Theme.of(tester.element(find.byType(ChatEmptyState)));
    expect(preview.brightness, Brightness.dark);
    expect(preview.extension<DshThemeStyle>()!.pack!.palette.seed, 0xFF2B6A58);

    // A swatch of the quick fields opens the same picker as the colour list.
    await tester.tap(
      find.descendant(of: find.byKey(const ValueKey('theme-studio-seed-hex')), matching: find.byType(InkResponse)),
    );
    await tester.pumpAndSettle();
    expect(find.text('选颜色'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a value the material decides shows what it comes to until it is dragged', (tester) async {
    double? written = -1;
    await tester.pumpWidget(
      _app(
        StudioSlider(
          label: '顶栏模糊',
          value: null,
          min: 0,
          max: 40,
          step: 1,
          effective: 20,
          follows: '跟随材质',
          onChanged: (v) => written = v,
        ),
      ),
    );
    expect(find.text('跟随材质 · 当前 20'), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 20);
    expect(written, -1);
    final track = tester.getRect(find.byType(Slider));
    await tester.tapAt(Offset(track.left + track.width * 0.75, track.center.dy));
    expect(written, closeTo(30, 1));
  });

  testWidgets('a picture picked in this session is where the preview\'s widgets look for it', (tester) async {
    final c = ThemeStudioController(initial: ThemePack.paper);
    c.useImage(ThemeImageSlot.assistantAvatar, tinyPng);
    expect(c.error, isNull);
    expect(c.isDirty, isTrue);
    final staged = c.previewPack;
    expect(File('${staged.folderPath}/avatar-assistant.png').readAsBytesSync(), tinyPng);
    // The draft still saves from the template's own folder (a built-in has none).
    expect(c.pack.folderPath, isNull);

    await tester.pumpWidget(
      ProviderScope(
        child: _app(
          ThemeStudioPreview(
            theme: buildLightTheme(accent: AppAccent.fromThemePack(staged), themePack: staged),
            page: StudioPreviewPage.chat,
          ),
        ),
      ),
    );
    // The avatar decodes at the size it is drawn, so its file sits inside a ResizeImage.
    final avatar = (tester.widget<Image>(find.byType(Image)).image as ResizeImage).imageProvider as FileImage;
    expect(avatar.file.parent.path, Directory(staged.folderPath!).path);

    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
    expect(Directory(staged.folderPath!).existsSync(), isFalse);
  });

  test('two different fonts picked under one file name stay two files', () async {
    Uint8List font(int mark) => Uint8List.fromList([0x4F, 0x54, 0x54, 0x4F, 0, 0, 0, 0, 0, 0, 0, mark]);
    final c = ThemeStudioController(initial: ThemePack.paper);
    addTearDown(c.dispose);
    await c.useFont(ThemeFontRole.ui, 'Regular.otf', font(1));
    await c.useFont(ThemeFontRole.code, 'Regular.otf', font(2));
    // The same file again shares the name it already has.
    await c.useFont(ThemeFontRole.heading, 'Regular.otf', font(1));
    final t = c.pack.typography;
    expect((t.uiFont, t.codeFont, t.headingFont), ('Regular.otf', 'Regular-2.otf', 'Regular.otf'));
    expect(c.assets['Regular.otf']!.last, 1);
    expect(c.assets['Regular-2.otf']!.last, 2);

    // A pack takes names that differ only in case for one name: a third font can't be regular.otf,
    // and the first one picked again under that spelling is still Regular.otf.
    await c.useFont(ThemeFontRole.code, 'regular.otf', font(3));
    await c.useFont(ThemeFontRole.ui, 'REGULAR.otf', font(1));
    expect((c.pack.typography.codeFont, c.pack.typography.uiFont), ('regular-3.otf', 'Regular.otf'));
    expect(c.assets.keys.toSet(), {'Regular.otf', 'Regular-2.otf', 'regular-3.otf'});
  });

  test('parser messages are said in the studio\'s words', () {
    expect(studioProblemText('shapes.cornerScale must be between 0.0 and 1.6'), '「整体圆角」要在 0 到 1.6 之间。');
    expect(studioProblemText('palette.light.link must be #RRGGBB or #AARRGGBB'), '「浅色 · 链接」的颜色要写成 #RRGGBB。');
    expect(studioProblemText('components.codeBlockStyle is invalid'), '「代码块」填得不对。');
    expect(studioProblemText('surfaces.sparkle is not supported'), '「surfaces.sparkle」这一项不认识。');
    expect(studioProblemText('surfaces.backdropImage must be a local .png, .webp or .gif filename'), '「背景图」要选一个包里的文件。');
    expect(studioProblemText('emptyState.heroImage is required when heroStyle is customImage'), '「主视觉图」还没填。');
    expect(studioProblemText('components.userLabel.zh must be non-empty up to 16 chars'), '「我的小标签（中文）」要填 1 到 16 个字。');
    expect(studioProblemText('theme.json name must be non-empty up to 120 chars'), '「主题名称」要填 1 到 120 个字。');
    // A sentence it has no words for is left alone.
    expect(studioProblemText('theme.json schema must be 1'), 'theme.json schema must be 1');
  });

  testWidgets('a capped field counts code points, as the pack does', (tester) async {
    var typed = '';
    await tester.pumpWidget(_app(StudioField.text(value: '', maxLength: 4, onChanged: (text) => typed = text)));
    // Each flag is two code points, four UTF-16 units and one character on screen.
    await tester.enterText(find.byType(TextField), '🇨🇳🇨🇳🇨🇳');
    await tester.pump();
    expect(typed, '🇨🇳🇨🇳');
    expect(find.text('4/4'), findsOneWidget);
  });

  testWidgets('an advanced edit is saved, and fields no control was touched for survive', (tester) async {
    final temp = (await tester.runAsync(() => Directory.systemTemp.createTemp('dsh-theme-studio-test-')))!;
    addTearDown(() => temp.deleteSync(recursive: true));
    final library = ThemeLibrary(() async => Directory('${temp.path}/themes'));
    const paper = ThemePack.paper;
    final seeded = (await tester.runAsync(
      () => library.saveCustom(
        paper.copyWith(
          id: 'studio-seams',
          name: '接缝',
          palette: paper.palette.copyWith(light: paper.palette.light.withToken('link', 0xFF112233)),
          typography: paper.typography.copyWith(headingWeight: () => 700),
          components: paper.components.copyWith(
            turnDivider: ThemeTurnDivider.dots,
            userLabel: () => const ThemeLocalizedText(zh: '我'),
          ),
        ),
      ),
    ))!;

    ThemePack? saved;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          themeLibraryProvider.overrideWithValue(library),
          themeLoadedFontsProvider.overrideWith((ref, id) async => const <String, String>{}),
        ],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => saved = await Navigator.of(context).push<ThemePack>(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: ThemeStudioSheet(initial: seeded, editing: true, existingIds: const {'studio-seams'}),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final more = find.byKey(const ValueKey('theme-studio-more-shapes'));
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('切角'));
    await tester.tap(find.text('切角'));
    await tester.pump();

    final save = find.byKey(const ValueKey('theme-studio-save'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    // The save is real file I/O: let it run, then let the test zone see each step finish.
    for (var i = 0; i < 100 && saved == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(saved?.id, 'user-studio-seams');
    final json = jsonDecode(File('${temp.path}/themes/user-studio-seams/theme.json').readAsStringSync()) as Map;
    expect(json['name'], '接缝');
    expect(json['shapes'], containsPair('cornerStyle', 'bevel'));
    expect(json['shapes'], containsPair('cornerScale', paper.shapes.cornerScale));
    expect(json['typography'], containsPair('headingWeight', 700));
    expect(json['components'], containsPair('turnDivider', 'dots'));
    expect(json['components'], containsPair('userLabel', {'zh': '我'}));
    expect((json['palette'] as Map)['light'], containsPair('link', '#112233'));
  });

  testWidgets('the JSON editor applies a valid pack and holds back an invalid one', (tester) async {
    final c = ThemeStudioController(initial: ThemePack.paper);
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(ThemeStudioJsonSheet(controller: c)));
    final field = find.byKey(const ValueKey('theme-json-field'));
    FilledButton apply() => tester.widget(find.byKey(const ValueKey('theme-json-apply')));

    final valid = {
      'schema': 1,
      'id': 'from-json',
      'name': 'JSON 主题',
      'extends': 'terminal-noir',
      'shapes': {'cornerStyle': 'bevel'},
    };
    await tester.enterText(field, jsonEncode(valid));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('theme-json-apply')));
    await tester.pump();
    expect(c.pack.id, 'from-json');
    expect(c.pack.shapes.cornerStyle, ThemeCornerStyle.bevel);
    expect(c.pack.shapes.cornerScale, ThemePack.terminalNoir.shapes.cornerScale);
    expect(c.pack.surfaces.preset, ThemeSurfacePreset.outlined);

    await tester.enterText(
      field,
      jsonEncode({
        ...valid,
        'name': '不该生效',
        'shapes': {'cornerScale': 9},
      }),
    );
    await tester.pump();
    expect(find.text('「整体圆角」要在 0 到 1.6 之间。'), findsOneWidget);
    expect(apply().onPressed, isNull);
    expect(c.pack.name, 'JSON 主题');

    // Broken JSON: the status says which line, and a tap on it puts the caret there.
    await tester.enterText(field, '{\n  "schema": 1,\n  "id": oops\n}');
    await tester.pump();
    expect(find.text('JSON 在第 3 行附近写错了，点这里跳过去。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('theme-json-status')));
    await tester.pump();
    final caret = tester.widget<EditableText>(find.byType(EditableText)).controller.selection;
    expect(caret.isCollapsed, isTrue);
    expect(caret.baseOffset, '{\n  "schema": 1,\n  "id": '.length);

    // A theme being edited keeps its ID whatever the JSON says.
    final editing = ThemeStudioController(initial: ThemePack.paper.copyWith(id: 'mine'), editing: true);
    addTearDown(editing.dispose);
    editing.replaceWith(ThemePack.parse(valid));
    expect(editing.pack.id, 'mine');
    expect(editing.pack.name, 'JSON 主题');
  });

  testWidgets('the colour list sets and clears one colour, and names every colour the model has', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 4200);
    addTearDown(tester.view.reset);
    final c = ThemeStudioController(initial: ThemePack.paper);
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(ThemeStudioColorsSheet(controller: c)));
    expect(find.text('其它'), findsNothing);

    final link = find.byKey(const ValueKey('theme-color-light-link'));
    await tester.enterText(link, '#112233');
    await tester.pump();
    expect(c.pack.palette.light.link, 0xFF112233);
    expect(c.pack.palette.dark.link, isNull);

    await tester.tap(find.byKey(const ValueKey('theme-color-clear-light-link')));
    await tester.pump();
    expect(c.pack.palette.light.link, isNull);
    expect(
      tester.widget<EditableText>(find.descendant(of: link, matching: find.byType(EditableText))).controller.text,
      '',
    );
  });
}
