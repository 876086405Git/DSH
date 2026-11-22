import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dsh_app/pets/overlay_channel.dart';
import 'package:dsh_app/pets/pet_library.dart';
import 'package:dsh_app/pets/pet_pack.dart';
import 'package:dsh_app/pets/pet_prefs.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/pets/pet_state.dart' show noPetId;
import 'package:dsh_app/state/compose_inbox.dart';
import 'package:dsh_app/state/ui_mode_state.dart';
import 'package:dsh_app/ui/pets/pet_menu.dart';
import 'package:dsh_app/ui/pets/pet_picker.dart';
import 'package:dsh_app/ui/pets/pet_settings_page.dart';
import 'package:dsh_app/workshop/workshop_receipt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pet_library_test.dart' show packJson, png;
import 'support.dart';

/// The overlay's channel, minus the native side: which pets it was told to read again.
class _Overlay extends PetOverlayChannel {
  final reloaded = <String>[];

  @override
  Future<void> reloadPack(String id) async => reloaded.add(id);
}

/// A library whose removals fail (a file held open, storage gone).
class _StuckLibrary extends PetLibrary {
  _StuckLibrary(super.root);

  @override
  Future<void> remove(String id, {WorkshopReceipt? expectedWorkshop}) async => throw const FileSystemException('busy');
}

/// A library whose removals wait until the test lets them go.
class _GatedRemoval extends PetLibrary {
  _GatedRemoval(super.root);

  final gate = Completer<void>();

  @override
  Future<void> remove(String id, {WorkshopReceipt? expectedWorkshop}) async {
    await gate.future;
    return super.remove(id, expectedWorkshop: expectedWorkshop);
  }
}

/// A library whose first listing is slow: read before an import, back after it.
class _SlowFirstList extends PetLibrary {
  _SlowFirstList(super.root);

  final firstBack = Completer<void>();
  var _calls = 0;

  @override
  Future<List<PetPack>> list() async {
    final first = ++_calls == 1;
    final found = await super.list();
    if (first) await firstBack.future;
    return found;
  }
}

/// Brought pets already there, as many as a test needs.
class _FixedPets extends UserPetsController {
  _FixedPets(this.packs);

  final List<PetPack> packs;

  @override
  Future<List<PetPack>> build() async => packs;
}

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('pet-import'));
  tearDown(() => temp.deleteSync(recursive: true));

  File zip(Map<String, List<int>> files) {
    final archive = Archive();
    files.forEach((name, data) => archive.add(ArchiveFile.bytes(name, data)));
    final file = File('${temp.path}/in-${DateTime.now().microsecondsSinceEpoch}.zip');
    file.writeAsBytesSync(ZipEncoder().encode(archive));
    return file;
  }

  /// Lets the real file work (unzip, write, read back) finish.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<Directory> pets() async => Directory('${temp.path}/pets');

  Future<ProviderContainer> open(
    WidgetTester tester,
    File? Function() picked, {
    PetLibrary? library,
    PetOverlayChannel? overlay,
    bool web = false,
  }) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const PetSettingsPage(),
        overrides: [
          petClockProvider.overrideWithValue(TestClock().call),
          petLibraryProvider.overrideWithValue(library ?? PetLibrary(pets)),
          petOverlayChannelProvider.overrideWithValue(overlay ?? _Overlay()),
          petPackPickerProvider.overrideWithValue(() async => picked()),
          petPackProvider.overrideWith(
            (ref, id) async => isUserPet(id) ? ref.watch(petLibraryProvider).load(id) : diskPack(id),
          ),
          petPrefsProvider.overrideWith(() => FixedPetPrefs(const PetPrefs(loaded: true))),
          if (web) uiModeProvider.overrideWith(_WebMode.new),
        ],
      ),
    );
    await settle(tester, () => false);
    return ProviderScope.containerOf(tester.element(find.byType(PetSettingsPage)));
  }

  testWidgets('让 AI 做一只宠物: the skill word waits in a new composer', (tester) async {
    final container = await open(tester, () => null);
    expect(find.text('让 AI 做一只宠物'), findsOneWidget);
    await tester.tap(find.text('让 AI 做一只宠物'));
    await tester.pump();
    final pending = container.read(composeInboxProvider);
    expect(pending, isNotEmpty);
    expect(pending.first.text, '/pet-theme ');
  });

  testWidgets('让 AI 做一只宠物 in web mode: the page opens a new chat with it', (tester) async {
    final container = await open(tester, () => null, web: true);
    await tester.tap(find.text('让 AI 做一只宠物'));
    await tester.pump();
    final request = container.read(webOpenProvider)!;
    expect(request.target.newSession, isTrue);
    expect(request.compose!.text, '/pet-theme ');
    expect(container.read(composeInboxProvider), isEmpty);
  });

  testWidgets('导入: your pet joins the picker, chosen, and says who made it', (tester) async {
    final file = zip({'cat/pack.json': utf8.encode(jsonEncode(packJson())), 'cat/idle.png': png(32, 16)});
    final overlay = _Overlay();
    final container = await open(tester, () => file, overlay: overlay);
    expect(find.text('导入'), findsOneWidget);
    expect(find.textContaining('导入你自己的像素宠物'), findsOneWidget);

    await tester.tap(find.text('导入'));
    await settle(tester, () => find.text('「小猫」来了').evaluate().isNotEmpty);
    expect(find.text('「小猫」来了'), findsOneWidget);
    expect(find.text('小猫'), findsOneWidget);
    expect(container.read(petPrefsProvider).packId, 'user-cat');
    expect(find.textContaining('阿周 · CC0'), findsOneWidget);
    // Success is visible before the asynchronous picked-copy cleanup ends.
    // Keep the deletion oracle; the original bounded helper waits for the file.
    await settle(tester, () => !file.existsSync());
    expect(file.existsSync(), isFalse);
    // The overlay reads it from disk, not from what it had under that id.
    expect(overlay.reloaded, ['user-cat']);

    // Long press: gone, and the default is back.
    await tester.longPress(find.text('小猫'));
    await tester.pumpAndSettle();
    expect(find.text('删除「小猫」？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await settle(tester, () => find.text('小猫').evaluate().isEmpty);
    expect(find.text('小猫'), findsNothing);
    expect(container.read(petPrefsProvider).packId, defaultPetId);
    expect(Directory('${temp.path}/pets/user-cat').existsSync(), isFalse);
    expect(overlay.reloaded, ['user-cat', 'user-cat']);
  });

  testWidgets('a pet that cannot be deleted stays, chosen again, and says so', (tester) async {
    final file = zip({'pack.json': utf8.encode(jsonEncode(packJson())), 'idle.png': png(32, 16)});
    final container = await open(tester, () => file, library: _StuckLibrary(pets));
    await tester.tap(find.text('导入'));
    await settle(tester, () => find.text('「小猫」来了').evaluate().isNotEmpty);
    expect(container.read(petPrefsProvider).packId, 'user-cat');
    ScaffoldMessenger.of(tester.element(find.byType(PetSettingsPage))).removeCurrentSnackBar();
    await tester.pumpAndSettle();

    await tester.longPress(find.text('小猫'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await settle(tester, () => find.textContaining('没能删除').evaluate().isNotEmpty);
    expect(find.text('没能删除「小猫」，再试一次'), findsOneWidget);
    expect(find.text('小猫'), findsOneWidget);
    expect(container.read(petPrefsProvider).packId, 'user-cat');
    expect(Directory('${temp.path}/pets/user-cat').existsSync(), isTrue);
  });

  testWidgets('a pack that is turned away says why, and nothing changes', (tester) async {
    final file = zip({'pack.json': utf8.encode(jsonEncode(packJson()))});
    final container = await open(tester, () => file);
    await tester.tap(find.text('导入'));
    await settle(tester, () => find.textContaining('少了序列帧图').evaluate().isNotEmpty);
    expect(find.text('zip 里少了序列帧图 idle.png'), findsOneWidget);
    expect(container.read(petPrefsProvider).packId, defaultPetId);
  });

  testWidgets('换宠物 with many brought pets: the sheet scrolls, 不显示 is still there', (tester) async {
    usePhoneView(tester);
    final brought = [for (var i = 0; i < 16; i++) PetPack.parse(packJson(id: 'user-pet$i', name: '宠物$i'))];
    final byId = {for (final p in brought) p.id: p};
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showPetMenu(context, pack: girl),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
        overrides: [
          petClockProvider.overrideWithValue(TestClock().call),
          userPetsProvider.overrideWith(() => _FixedPets(brought)),
          petPackProvider.overrideWith((ref, id) async => byId[id] ?? diskPack(id)),
          petPrefsProvider.overrideWith(() => FixedPetPrefs(const PetPrefs(loaded: true))),
        ],
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('换宠物'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'no overflow');
    final grid = find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.text('不显示'), 200, scrollable: grid.first);
    await tester.tap(find.text('不显示'));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.text('打开')));
    expect(container.read(petPrefsProvider).packId, noPetId);
  });

  test('the first listing, back after an import listed again, does not undo it', () async {
    final library = _SlowFirstList(pets);
    final container = ProviderContainer(
      overrides: [
        petLibraryProvider.overrideWithValue(library),
        petOverlayChannelProvider.overrideWithValue(_Overlay()),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(userPetsProvider, (_, _) {});
    addTearDown(sub.close);
    await pumpEventQueue();

    final file = zip({'pack.json': utf8.encode(jsonEncode(packJson())), 'idle.png': png(32, 16)});
    await container.read(userPetsProvider.notifier).import(file);
    expect(container.read(userPetsProvider).value!.map((p) => p.id), ['user-cat']);

    // The first listing (read before the import: nothing) comes back now.
    library.firstBack.complete();
    await container.read(userPetsProvider.future);
    await pumpEventQueue();
    expect(container.read(userPetsProvider).value!.map((p) => p.id), ['user-cat']);
  });

  group('removing a chosen pet: what is chosen after, and still hidden', () {
    final until = DateTime(2026, 11, 8, 18);

    Future<ProviderContainer> chosenCat(PetLibrary library, {DateTime? hiddenUntil}) async {
      await library.install(zip({'pack.json': utf8.encode(jsonEncode(packJson())), 'idle.png': png(32, 16)}));
      final container = ProviderContainer(
        overrides: [
          petLibraryProvider.overrideWithValue(library),
          petOverlayChannelProvider.overrideWithValue(_Overlay()),
          petPrefsProvider.overrideWith(
            () => FixedPetPrefs(PetPrefs(packId: 'user-cat', hiddenUntil: hiddenUntil, loaded: true)),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('deleted while hidden: the default comes back, hidden as it was', () async {
      final container = await chosenCat(PetLibrary(pets), hiddenUntil: until);
      await container.read(userPetsProvider.notifier).remove('user-cat');
      expect(container.read(petPrefsProvider).packId, defaultPetId);
      expect(container.read(petPrefsProvider).hiddenUntil, until);
    });

    test('cannot be deleted while hidden: chosen again, hidden as it was', () async {
      final container = await chosenCat(_StuckLibrary(pets), hiddenUntil: until);
      await expectLater(
        container.read(userPetsProvider.notifier).remove('user-cat'),
        throwsA(isA<FileSystemException>()),
      );
      expect(container.read(petPrefsProvider).packId, 'user-cat');
      expect(container.read(petPrefsProvider).hiddenUntil, until);
    });

    test('picked again while it was being deleted: the default after all', () async {
      final library = _GatedRemoval(pets);
      final container = await chosenCat(library);
      final removing = container.read(userPetsProvider.notifier).remove('user-cat');
      await pumpEventQueue();
      expect(container.read(petPrefsProvider).packId, defaultPetId);
      await container.read(petPrefsProvider.notifier).setPack('user-cat');
      library.gate.complete();
      await removing;
      expect(container.read(petPrefsProvider).packId, defaultPetId);
      expect(Directory('${temp.path}/pets/user-cat').existsSync(), isFalse);
    });
  });

  testWidgets('cancelling the pick does nothing', (tester) async {
    final container = await open(tester, () => null);
    await tester.tap(find.text('导入'));
    await settle(tester, () => false);
    expect(find.byType(SnackBar), findsNothing);
    expect(container.read(petPrefsProvider).packId, defaultPetId);
  });
}

class _WebMode extends UiModeController {
  @override
  UiModeState build() => const UiModeState(mode: UiMode.web, loaded: true);
}
