import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../companion/companion_float.dart' show companionFloatStoreProvider;
import '../pets/overlay_channel.dart' show petOverlayChannelProvider;
import '../pets/pet_library.dart';
import '../pets/pet_prefs.dart';
import '../pets/pet_sheets.dart';
import '../pets/pet_signals.dart' show petPackProvider, userPetsProvider;
import '../themes/theme_library.dart';
import '../workshop/workshop_client.dart';
import '../workshop/workshop_http.dart';
import '../workshop/workshop_models.dart';
import '../workshop/workshop_repository.dart';
import 'app_info.dart';
import 'appearance_state.dart';

/// Our own deployment unless the build names another; an empty value builds
/// without a Workshop. Never an implicit third-party host.
final workshopOriginProvider = Provider<Uri?>((ref) {
  const configured = String.fromEnvironment('DSH_WORKSHOP_ORIGIN', defaultValue: 'https://go.dshtui.com');
  if (configured.isEmpty) return null;
  final parsed = Uri.tryParse(configured);
  if (parsed == null) workshopInvalid('workshop_untrusted_origin');
  return workshopOrigin(parsed);
});

/// Tests replace the existing storage/network seams, without loading a page.
final workshopDirectoryProvider = Provider<Future<Directory> Function()>(
  (ref) => () async => Directory('${(await getApplicationSupportDirectory()).path}/workshop'),
);
final workshopHttpFactoryProvider = Provider<WorkshopHttp Function(Uri)>(
  (ref) => IoWorkshopHttp.new,
);
final workshopAppVersionProvider = Provider<String>((ref) => AppInfo.version);

final workshopClientProvider = FutureProvider<WorkshopClient>((ref) async {
  final configured = ref.watch(workshopOriginProvider);
  final directory = ref.watch(workshopDirectoryProvider);
  final createHttp = ref.watch(workshopHttpFactoryProvider);
  var disposed = false;
  WorkshopClient? owned;
  ref.onDispose(() {
    disposed = true;
    owned?.close();
  });
  if (configured == null) workshopInvalid('workshop_unconfigured');
  final origin = workshopOrigin(configured);
  final root = await directory();
  if (disposed || !ref.mounted) workshopInvalid('workshop_cancelled');
  final client = WorkshopClient(
    origin: origin,
    cacheFile: File('${root.path}/catalog.json'),
    http: createHttp(origin),
  );
  owned = client;
  return client;
}, retry: (_, _) => null);

/// Local receipts and receipt-fenced removal work without a configured Worker.
/// Stores are borrowed; this provider never closes a companion reader/store.
final workshopPackagesProvider = FutureProvider<WorkshopPackages>((ref) async {
  final pets = ref.watch(petLibraryProvider);
  final themes = ref.watch(themeLibraryProvider);
  final loadCompanion = ref.watch(companionFloatStoreProvider);
  final companion = await loadCompanion();
  if (!ref.mounted) workshopInvalid('workshop_cancelled');
  return LocalWorkshopPackages(pets: pets, companion: companion, themes: themes);
}, retry: (_, _) => null);

final workshopRepositoryProvider = FutureProvider<WorkshopRepository>((ref) async {
  final clientFuture = ref.watch(workshopClientProvider.future);
  final packagesFuture = ref.watch(workshopPackagesProvider.future);
  final directory = ref.watch(workshopDirectoryProvider);
  final version = ref.watch(workshopAppVersionProvider);
  // Capture every watched dependency before the first suspension. The client
  // provider owns the connection; this repository only borrows it.
  final dependencies = await Future.wait<Object>([clientFuture, packagesFuture, directory()]);
  final client = dependencies[0] as WorkshopClient;
  final packages = dependencies[1] as WorkshopPackages;
  final root = dependencies[2] as Directory;
  if (!ref.mounted) workshopInvalid('workshop_cancelled');
  return WorkshopRepository(
    client: client,
    packages: packages,
    downloadDirectory: Directory('${root.path}/downloads'),
    appVersion: version,
  );
}, retry: (_, _) => null);

/// Called only by explicit actions. Healthy dependencies remain shared/open.
void retryWorkshopDependencies(Ref ref, {bool includeLocal = false}) {
  final clientFailed = ref.exists(workshopClientProvider) && ref.read(workshopClientProvider).hasError;
  final packagesFailed = includeLocal && ref.exists(workshopPackagesProvider) &&
      ref.read(workshopPackagesProvider).hasError;
  final repositoryFailed = includeLocal && ref.exists(workshopRepositoryProvider) &&
      ref.read(workshopRepositoryProvider).hasError;
  if (clientFailed) ref.invalidate(workshopClientProvider);
  if (packagesFailed) ref.invalidate(workshopPackagesProvider);
  if (repositoryFailed) ref.invalidate(workshopRepositoryProvider);
}

typedef WorkshopPackageChanged = Future<void> Function(
  WorkshopInstalled item, {
  required bool removed,
});

Future<void> _waitPetPreferences(Ref ref) async {
  if (!ref.mounted) workshopInvalid('workshop_cancelled');
  if (ref.read(petPrefsProvider).loaded) return;
  final done = Completer<void>();
  void Function()? stopListening;
  final removeDispose = ref.onDispose(() {
    if (!done.isCompleted) done.completeError(const WorkshopException('workshop_cancelled'));
  });
  try {
    final subscription = ref.listen<bool>(
      petPrefsProvider.select((prefs) => prefs.loaded),
      (_, loaded) {
        if (loaded && !done.isCompleted) done.complete();
      },
      onError: (error, stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
      fireImmediately: true,
    );
    stopListening = subscription.close;
    await done.future;
  } finally {
    stopListening?.call();
    removeDispose();
  }
}

/// A successful filesystem mutation also refreshes the existing pet consumers.
/// Controllers report failure here separately: the package has already changed.
/// This hook does not watch the Worker, so an already-committed old-origin
/// operation can still refresh the local resource it changed.
final workshopPackageChangedProvider = Provider<WorkshopPackageChanged>((ref) {
  return (item, {required removed}) async {
    if (item.receipt.kind == 'theme') {
      ThemeFonts.instance.forget(item.localId);
      if (!ref.mounted) return;
      ref.invalidate(themePackByIdProvider(item.localId));
      ref.invalidate(themeLoadedFontsProvider(item.localId));
      ref.invalidate(userThemesProvider);
      if (removed && ref.read(appearanceProvider).themePackId == item.localId) {
        await ref.read(appearanceProvider.notifier).selectThemePack(null);
      }
      return;
    }
    if (item.receipt.kind != 'pet') return;
    PetSheets.instance.forget(item.localId);
    if (!ref.mounted) return;
    ref.invalidate(petPackProvider(item.localId));
    ref.invalidate(userPetsProvider);
    try {
      if (removed) {
        await _waitPetPreferences(ref);
        if (!ref.mounted) return;
        if (ref.read(petPrefsProvider).packId == item.localId) {
          await ref.read(petPrefsProvider.notifier).replacePack(defaultPetId);
        }
      }
      if (ref.mounted) await ref.read(petOverlayChannelProvider).reloadPack(item.localId);
    } on Object {
      throw const WorkshopException('workshop_local_refresh');
    }
  };
});
