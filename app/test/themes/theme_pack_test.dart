import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_app/state/appearance_state.dart';
import 'package:dsh_app/themes/theme_library.dart';
import 'package:dsh_app/themes/theme_pack_validator.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/workshop/workshop_preview.dart';
import 'package:dsh_app/workshop/workshop_receipt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../workshop/support.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('built-in theme packs round-trip through JSON and project distinct theme styles', () {
    expect(ThemePack.builtIns.map((p) => p.id), [
      'paper',
      'bamboo-celadon',
      'terminal-noir',
      'sakura-card',
      'amber-cafe',
    ]);
    for (final pack in ThemePack.builtIns) {
      final parsed = ThemePack.parse(pack.toJson());
      expect(parsed, pack);
      final light = buildLightTheme(accent: AppAccent.fromThemePack(pack), themePack: pack);
      final dark = buildDarkTheme(accent: AppAccent.fromThemePack(pack), themePack: pack);
      expect(light.extension<DshThemeStyle>()?.pack, pack);
      expect(dark.extension<DshThemeStyle>()?.pack, pack);
    }

    final paperLight = buildLightTheme(accent: AppAccent.fromThemePack(ThemePack.paper), themePack: ThemePack.paper);
    final paperSurfaces = paperLight.extension<DshSurfaces>()!;
    expect(paperSurfaces.glowPrimary, Colors.transparent);
    expect(paperSurfaces.chrome.blurs, isFalse);
    expect(paperSurfaces.userBubble, const Color(0xFFEAE3D4));
    final paperStyle = paperLight.extension<DshThemeStyle>()!;
    expect(paperStyle.components.headerStyle, ThemeHeaderStyle.ghost);
    expect(paperStyle.components.sendButtonStyle, ThemeSendButtonStyle.ink);
    expect(paperStyle.emptyState.heroStyle, ThemeHeroStyle.seal);
  });

  Map<String, Object?> seamManifest([Map<String, Object?> overrides = const {}]) => {
    'schema': 1,
    'id': 'seams',
    'name': 'Seams',
    ...overrides,
  };

  test('seam fields round-trip through JSON and reject out-of-range values', () {
    final manifest = seamManifest({
      'palette': {
        'seed': '#2B6A58',
        'light': {'link': '#1A5FB4', 'rule': '#802B6A58', 'patternInk': '#14322A'},
        'dark': {
          'sendButton': '#7FC7B0',
          'onSendButton': '#0E1315',
          'cardFill': '#CC1A2521',
          'danger': '#FF6B6B',
          'syntaxKeyword': '#E0A458',
          'syntaxString': '#9CCB8B',
          'syntaxNumber': '#F2B880',
          'syntaxComment': '#997F8A80',
          'syntaxFunction': '#8FB8DE',
          'syntaxType': '#7FC7B0',
        },
      },
      'surfaces': {
        'preset': 'paper',
        'pattern': 'grid',
        'patternOpacity': 0.1,
        'patternScale': 1.5,
        'glowLayout': 'top',
        'backdropImage': 'rain.gif',
        'backdropBlur': 40,
        'backdropAlign': 'bottom',
        'backdropAnimate': false,
      },
      'typography': {'readingLetterSpacing': 0.3, 'headingLetterSpacing': -0.5, 'headingWeight': 700, 'codeScale': 0.9},
      'shapes': {
        'cornerStyle': 'bevel',
        'bubbleCorners': 'tail',
        'bubbleRadius': 20,
        'cardRadius': 0,
        'codeRadius': 6,
        'composerRadius': 36,
        'bubblePadH': 18,
        'bubblePadV': 10,
      },
      'components': {
        'assistantStyle': 'quote',
        'sendButtonStyle': 'outlined',
        'sendButtonShape': 'square',
        'codeHeaderStyle': 'plain',
        'turnDivider': 'dashed',
        'headingStyle': 'marker',
        'bulletStyle': 'diamond',
        'headerTitleFont': 'heading',
        'userLabel': {'zh': '我', 'en': 'Me'},
        'assistantLabel': {'en': 'Reply'},
        'assistantAvatar': 'bot.webp',
        'userAvatar': 'me.png',
        'composerHint': {'zh': '写点什么'},
      },
      'emptyState': {
        'heroStyle': 'seal',
        'heroGlyph': '竹韵',
        'heroScale': 1.4,
        'greeting': {'zh': '见字如面'},
        'subtitle': {'zh': '慢慢写', 'en': 'Take your time'},
      },
    });
    final pack = ThemePack.parse(manifest);
    expect(pack.palette.light.link, 0xFF1A5FB4);
    expect(pack.palette.light.rule, 0x802B6A58);
    expect(pack.surfaces.pattern, ThemeBackdropPattern.grid);
    expect(pack.typography.headingWeight, 700);
    expect(pack.shapes.cardRadius, 0);
    expect(pack.components.turnDivider, ThemeTurnDivider.dashed);
    expect(pack.emptyState.heroGlyph, '竹韵');
    expect(pack.palette.dark.cardFill, 0xCC1A2521);
    expect(
      [
        for (final role in const ['Keyword', 'String', 'Number', 'Comment', 'Function', 'Type'])
          pack.palette.dark['syntax$role'],
      ],
      [0xFFE0A458, 0xFF9CCB8B, 0xFFF2B880, 0x997F8A80, 0xFF8FB8DE, 0xFF7FC7B0],
    );
    expect(pack.surfaces.backdropAnimate, isFalse);
    expect(pack.referencedImages, {'rain.gif', 'bot.webp', 'me.png'});
    expect(ThemePack.parse(jsonDecode(jsonEncode(pack.toJson())) as Map<String, Object?>), pack);
    expect(
      pack.shapes.copyWith(bubbleRadius: () => null, bubblePadH: 12),
      ThemeShapeSpec.parse({...manifest['shapes']! as Map, 'bubbleRadius': null, 'bubblePadH': 12}),
    );

    // One distinct value per token proves the key list, getters and constructor stay aligned.
    for (final (index, key) in ThemeColorOverrides.tokenKeys.indexed) {
      final one = const ThemeColorOverrides().withToken(key, 0xFF000000 + index);
      expect(one[key], 0xFF000000 + index);
      expect(one.toJson().keys, [key]);
      expect(one.withToken(key, null).isEmpty, isTrue);
    }

    for (final bad in <Map<String, Object?>>[
      {
        'surfaces': {'patternScale': 3.5},
      },
      {
        'surfaces': {'pattern': 'stripes'},
      },
      {
        'surfaces': {'backdropBlur': 41},
      },
      {
        'surfaces': {'backdropImage': 'photo.jpg'},
      },
      {
        'typography': {'headingWeight': 650},
      },
      {
        'shapes': {'bubbleRadius': 37},
      },
      {
        'components': {'bulletStyle': 'star'},
      },
      {
        'components': {
          'userLabel': {'zh': '字' * 17},
        },
      },
      {
        'components': {
          'userLabel': {'ja': 'わたし'},
        },
      },
      {
        'emptyState': {'heroScale': 0.5},
      },
      {
        'palette': {
          'light': {'link': 'blue'},
        },
      },
    ]) {
      expect(() => ThemePack.parse(seamManifest(bad)), throwsFormatException, reason: '$bad');
    }
  });

  test('glyph and seal heroes require a 1 to 4 character heroGlyph', () {
    ThemePack parse(Map<String, Object?> emptyState) => ThemePack.parse(seamManifest({'emptyState': emptyState}));
    expect(parse({'heroStyle': 'glyph', 'heroGlyph': '墨'}).emptyState.heroStyle, ThemeHeroStyle.glyph);
    expect(parse({'heroGlyph': '😀a文b'}).emptyState.heroGlyph, '😀a文b');
    expect(() => parse({'heroStyle': 'glyph'}), throwsFormatException);
    expect(() => parse({'heroStyle': 'seal'}), throwsFormatException);
    expect(() => parse({'heroStyle': 'seal', 'heroGlyph': '一二三四五'}), throwsFormatException);
    expect(() => parse({'heroStyle': 'seal', 'heroGlyph': ' '}), throwsFormatException);
  });

  test('extends inherits a built-in look, overrides it, and drops keys set to null', () {
    final pack = ThemePack.parse(
      seamManifest({
        'extends': 'paper',
        'palette': {
          'light': {'link': '#112233', 'userBubble': null},
        },
        'components': {'assistantStyle': 'quote', 'sendButtonStyle': null},
        'typography': null,
      }),
    );
    expect(pack.id, 'seams');
    expect(pack.name, 'Seams');
    expect(pack.description, isEmpty);
    expect(pack.palette.seed, ThemePack.paper.palette.seed);
    expect(pack.palette.dark, ThemePack.paper.palette.dark);
    expect(
      pack.palette.light,
      ThemePack.paper.palette.light.withToken('link', 0xFF112233).withToken('userBubble', null),
    );
    expect(
      pack.components,
      ThemePack.paper.components.copyWith(
        assistantStyle: ThemeAssistantStyle.quote,
        sendButtonStyle: ThemeSendButtonStyle.primary,
      ),
    );
    expect(pack.typography, const ThemeTypographySpec());
    expect(pack.emptyState, ThemePack.paper.emptyState);
    expect(pack.toJson().containsKey('extends'), isFalse);
    expect(ThemePack.parse(pack.toJson()), pack);
    expect(() => ThemePack.parse(seamManifest({'extends': 'not-a-built-in'})), throwsFormatException);
  });

  test('localized text prefers the matching language and falls back to the other', () {
    const both = ThemeLocalizedText(zh: '你好', en: 'Hello');
    expect(both.resolve('en'), 'Hello');
    expect(both.resolve('zh'), '你好');
    expect(both.resolve('ja'), '你好');
    expect(both.resolve(null), '你好');
    expect(const ThemeLocalizedText(zh: '你好').resolve('en'), '你好');
    expect(const ThemeLocalizedText(en: 'Hello').resolve('zh'), 'Hello');
  });

  test('validator accepts WebP and GIF images only when the header matches the extension', () {
    final manifest = seamManifest({
      'surfaces': {'backdropImage': 'rain.gif'},
      'components': {'assistantAvatar': 'bot.webp', 'userAvatar': 'me.png'},
    });
    // Header, logical screen, a graphic control extension, then the first frame's descriptor.
    Uint8List gifOf(int screen, int frame) => Uint8List.fromList([
      ...'GIF89a'.codeUnits, screen & 0xFF, screen >> 8, screen & 0xFF, screen >> 8, 0, 0, 0, //
      0x21, 0xF9, 4, 0, 0, 0, 0, 0,
      0x2C, 0, 0, 0, 0, frame & 0xFF, frame >> 8, frame & 0xFF, frame >> 8, 0, 2, 2, 0x4C, 0x01, 0, 0x3B,
    ]);
    final gif = gifOf(1, 1);
    Uint8List webpOf(int w, int h) => Uint8List.fromList([
      ...'RIFF'.codeUnits, 22, 0, 0, 0, ...'WEBP'.codeUnits, ...'VP8X'.codeUnits, 10, 0, 0, 0, 0, 0, 0, 0,
      (w - 1) & 0xFF, ((w - 1) >> 8) & 0xFF, 0, (h - 1) & 0xFF, ((h - 1) >> 8) & 0xFF, 0, //
    ]);
    final webp = webpOf(64, 64);
    final png = workshopPng(8, 8);
    final validated = ThemePackValidator.validateParts(manifest, {'rain.gif': gif, 'bot.webp': webp, 'me.png': png});
    expect(validated.assets.keys.toSet(), {'rain.gif', 'bot.webp', 'me.png'});

    for (final renamed in [
      {'rain.gif': webp, 'bot.webp': webp, 'me.png': png},
      {'rain.gif': gif, 'bot.webp': png, 'me.png': png},
      {'rain.gif': gif, 'bot.webp': webp, 'me.png': gif},
      // A canvas past the PNG limits, declared by a few bytes of header.
      {'rain.gif': gif, 'bot.webp': webpOf(5000, 16), 'me.png': png},
      {'rain.gif': gifOf(4096 + 1, 1), 'bot.webp': webp, 'me.png': png},
      // A first frame larger than the screen it declares: the decoder grows the canvas to fit.
      {'rain.gif': gifOf(1, 8192), 'bot.webp': webp, 'me.png': png},
      // No frame at all.
      {
        'rain.gif': Uint8List.fromList([...'GIF89a'.codeUnits, 1, 0, 1, 0, 0, 0, 0, 0x3B]),
        'bot.webp': webp,
        'me.png': png,
      },
    ]) {
      expect(() => ThemePackValidator.validateParts(manifest, renamed), throwsA(isA<ThemeValidationException>()));
    }
  });

  test('validator checks referenced PNGs and OTF/TTF fonts and rejects invalid archives', () {
    final pngBytes = workshopPng(8, 8);
    final fontBytes = Uint8List.fromList([
      0x4F, 0x54, 0x54, 0x4F, // 'OTTO'
      0, 1, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4,
    ]);
    final manifest = {
      'schema': 1,
      'id': 'ink-scroll',
      'name': '墨卷',
      'title': {'zh': '墨卷', 'en': 'Ink Scroll'},
      'description': 'Custom font and hero illustration theme.',
      'tags': ['墨卷', 'serif'],
      'author': 'Author',
      'license': 'CC0-1.0',
      'source': 'https://source.example/ink-scroll',
      'palette': {'seed': '#8B3A2B', 'tintHue': 68, 'tintChroma': 0.25, 'glowOpacity': 0.0},
      'surfaces': {'preset': 'paper', 'backdropImage': 'texture.png', 'backdropOpacity': 0.24, 'backdropRepeat': true},
      'typography': {'readingFont': 'book.otf', 'readingLineHeight': 1.68},
      'shapes': {'cornerScale': 0.75, 'borderWidth': 1.0},
      'components': {
        'headerStyle': 'ghost',
        'composerStyle': 'solidPaper',
        'sendButtonStyle': 'ink',
        'assistantStyle': 'card',
        'useReadingFontForReply': true,
        'codeBlockStyle': 'outlined',
      },
      'emptyState': {
        'layout': 'editorial',
        'heroStyle': 'customImage',
        'heroImage': 'hero.png',
        'suggestionsDisplay': 'collapsible',
      },
    };

    final archive = Archive()
      ..add(ArchiveFile.bytes('theme.json', utf8.encode(jsonEncode(manifest))))
      ..add(ArchiveFile.bytes('texture.png', pngBytes))
      ..add(ArchiveFile.bytes('hero.png', pngBytes))
      ..add(ArchiveFile.bytes('book.otf', fontBytes));
    final zipBytes = Uint8List.fromList(ZipEncoder().encode(archive));

    final validated = ThemePackValidator.validateArchive(zipBytes, market: true);
    expect(validated.pack.id, 'ink-scroll');
    expect(validated.pack.surfaces.backdropRepeat, isTrue);
    expect(validated.pack.components.codeBlockStyle, ThemeCodeBlockStyle.outlined);
    expect(validated.assets.keys.toSet(), {'texture.png', 'hero.png', 'book.otf'});

    final badFontArchive = Archive()
      ..add(ArchiveFile.bytes('theme.json', utf8.encode(jsonEncode(manifest))))
      ..add(ArchiveFile.bytes('texture.png', pngBytes))
      ..add(ArchiveFile.bytes('hero.png', pngBytes))
      ..add(ArchiveFile.bytes('book.otf', Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])));
    expect(
      () => ThemePackValidator.validateArchive(Uint8List.fromList(ZipEncoder().encode(badFontArchive))),
      throwsA(isA<ThemeValidationException>()),
    );
  });

  test('ThemeLibrary saves custom theme packs, exports clean Workshop ZIPs and manages receipts', () async {
    final temp = await Directory.systemTemp.createTemp('dsh-theme-lib-test-');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    final library = ThemeLibrary(() async => Directory('${temp.path}/themes'));
    final custom = ThemePack.paper.copyWith(
      id: 'warm-editorial',
      name: '暖纸手稿',
      author: 'StudioAuthor',
      license: 'MIT',
      source: 'https://source.example/warm-editorial',
    );
    final textureBytes = workshopPng(8, 8);
    final withTexture = custom.copyWith(
      surfaces: ThemeSurfaceSpec(
        preset: custom.surfaces.preset,
        hairlineWidth: custom.surfaces.hairlineWidth,
        backdropImage: 'paper-grain.png',
        backdropRepeat: true,
      ),
    );
    final savedWithAsset = await library.saveCustom(withTexture, assets: {'paper-grain.png': textureBytes});
    expect(savedWithAsset.id, 'user-warm-editorial');
    // Creating a new theme with allowOverwrite: false must reject collisions.
    await expectLater(
      () => library.saveCustom(withTexture, assets: {'paper-grain.png': textureBytes}, allowOverwrite: false),
      throwsA(isA<ThemeImportException>()),
    );
    // Re-saving without passing assets again preserves existing referenced files.
    final saved = await library.saveCustom(savedWithAsset.copyWith(name: '暖纸手稿 v2'), editingLocalId: savedWithAsset.id);
    expect(saved.id, 'user-warm-editorial');
    expect(saved.name, '暖纸手稿 v2');
    expect(saved.surfaces.backdropImage, 'paper-grain.png');
    expect((await library.list()).single.id, 'user-warm-editorial');

    // Public ID starting with 'user-' maps reversibly without colliding with the stripped ID.
    final prefixed = ThemePack.paper.copyWith(id: 'user-warm-editorial', name: 'Prefixed Public');
    final savedPrefixed = await library.saveCustom(prefixed, allowOverwrite: false);
    expect(savedPrefixed.id, 'user-user-warm-editorial');
    expect(savedPrefixed.publicId, 'user-warm-editorial');
    expect((await library.list()).map((t) => t.id).toSet(), {'user-warm-editorial', 'user-user-warm-editorial'});

    // Adding a Workshop cover renames colliding artwork named preview.png automatically.
    final withPreviewArtwork = custom.copyWith(
      id: 'cover-rename',
      surfaces: const ThemeSurfaceSpec(preset: ThemeSurfacePreset.paper, backdropImage: 'preview.png'),
    );
    final savedCollision = await library.saveCustom(
      withPreviewArtwork,
      assets: {'preview.png': textureBytes},
      allowOverwrite: false,
    );
    final collisionExport = File('${temp.path}/collision.zip');
    await library.exportZip(savedCollision.id, collisionExport, publicId: 'cover-rename');
    final renamedCoverZip = workshopThemePreviewZip((
      await collisionExport.readAsBytes(),
      WorkshopPreviewInput.themePng(workshopPng(24, 24)),
    ));
    final validatedCoverZip = ThemePackValidator.validateArchive(renamedCoverZip);
    expect(validatedCoverZip.pack.surfaces.backdropImage, 'theme-asset-preview.png');
    expect(ZipDecoder().decodeBytes(renamedCoverZip).files.any((f) => f.name == 'preview.png'), isTrue);

    final exportedFile = File('${temp.path}/exported.zip');
    await library.exportZip(
      saved.id,
      exportedFile,
      publicId: 'warm-editorial',
      author: 'StudioAuthor',
      license: 'MIT',
      source: 'https://source.example/warm-editorial',
    );
    expect(await exportedFile.exists(), isTrue);

    final receipt = WorkshopReceipt(
      kind: 'theme',
      id: 'warm-editorial',
      version: '1.0.0',
      sha256: 'a' * 64,
      origin: workshopTestOrigin,
    );
    final installed = await library.install(exportedFile, workshop: receipt, replaceExisting: true);
    expect(installed.id, 'user-warm-editorial');
    final receipts = await library.workshopReceipts();
    expect(receipts['user-warm-editorial']?.receipt?.same(receipt), isTrue);

    final cover = WorkshopPreviewInput.themePng(workshopPng(24, 24));
    final previewZipBytes = workshopThemePreviewZip((await exportedFile.readAsBytes(), cover));
    final decoded = ZipDecoder().decodeBytes(previewZipBytes);
    expect(decoded.files.any((f) => f.name == 'preview.png'), isTrue);
  });

  test('AppearanceController activates and persists theme packs and clears on preset selection', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(activeThemePackProvider), isNull);
    await container.read(appearanceProvider.notifier).selectThemePack('paper');
    expect(container.read(activeThemePackProvider), ThemePack.paper);
    expect(container.read(accentProvider).seed, const Color(0xFFA14732));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('appearance.theme_pack'), 'paper');

    await container.read(appearanceProvider.notifier).selectPreset('daiqing');
    expect(container.read(activeThemePackProvider), isNull);
    expect(container.read(accentProvider), AppAccent.daiqing);
    expect(prefs.getString('appearance.theme_pack'), isNull);
  });
}
