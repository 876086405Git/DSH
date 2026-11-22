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
      final light = buildLightTheme(
        accent: AppAccent.fromThemePack(pack),
        themePack: pack,
      );
      final dark = buildDarkTheme(
        accent: AppAccent.fromThemePack(pack),
        themePack: pack,
      );
      expect(light.extension<DshThemeStyle>()?.pack, pack);
      expect(dark.extension<DshThemeStyle>()?.pack, pack);
    }

    final paperLight = buildLightTheme(
      accent: AppAccent.fromThemePack(ThemePack.paper),
      themePack: ThemePack.paper,
    );
    final paperSurfaces = paperLight.extension<DshSurfaces>()!;
    expect(paperSurfaces.glowPrimary, Colors.transparent);
    expect(paperSurfaces.chrome.blurs, isFalse);
    expect(paperSurfaces.userBubble, const Color(0xFFECE8E2));
    final paperStyle = paperLight.extension<DshThemeStyle>()!;
    expect(paperStyle.components.headerStyle, ThemeHeaderStyle.ghost);
    expect(paperStyle.components.sendButtonStyle, ThemeSendButtonStyle.ink);
    expect(paperStyle.emptyState.suggestionsDisplay, ThemeSuggestionsDisplay.collapsible);
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
      'palette': {
        'seed': '#8B3A2B',
        'tintHue': 68,
        'tintChroma': 0.25,
        'glowOpacity': 0.0,
      },
      'surfaces': {
        'preset': 'paper',
        'backdropImage': 'texture.png',
        'backdropOpacity': 0.24,
        'backdropRepeat': true,
      },
      'typography': {
        'readingFont': 'book.otf',
        'readingLineHeight': 1.68,
      },
      'shapes': {
        'cornerScale': 0.75,
        'borderWidth': 1.0,
      },
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
      () => ThemePackValidator.validateArchive(
        Uint8List.fromList(ZipEncoder().encode(badFontArchive)),
      ),
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
    final savedWithAsset = await library.saveCustom(
      withTexture,
      assets: {'paper-grain.png': textureBytes},
    );
    expect(savedWithAsset.id, 'user-warm-editorial');
    // Creating a new theme with allowOverwrite: false must reject collisions.
    await expectLater(
      () => library.saveCustom(withTexture, assets: {'paper-grain.png': textureBytes}, allowOverwrite: false),
      throwsA(isA<ThemeImportException>()),
    );
    // Re-saving without passing assets again preserves existing referenced files.
    final saved = await library.saveCustom(
      savedWithAsset.copyWith(name: '暖纸手稿 v2'),
      editingLocalId: savedWithAsset.id,
    );
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
    final renamedCoverZip = workshopThemePreviewZip(
      (await collisionExport.readAsBytes(), WorkshopPreviewInput.themePng(workshopPng(24, 24))),
    );
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
    final installed = await library.install(
      exportedFile,
      workshop: receipt,
      replaceExisting: true,
    );
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
