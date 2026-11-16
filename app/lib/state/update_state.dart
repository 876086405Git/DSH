import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show MissingPluginException, appFlavor;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../update/checker.dart';
import '../update/downloader.dart';
import '../update/installer.dart';
import '../update/privileged_installer.dart';
import '../update/release.dart';
import '../update/update_config.dart';
import '../update/update_http.dart';
import '../update/version.dart';
import '../usage/usage_net.dart' show UsageDeviceChannel;
import 'android_features.dart' show operatingSystemProvider;
import 'app_info.dart';
import 'artifacts.dart';

/// In-app updates: daily check of our release copy and GitHub Releases (with
/// mirror fallback), a delta patch or the whole APK with resume, SHA-256
/// check, PackageInstaller install. Conventions in `docs/release.md`.

// ── Seams (tests override these) ─────────────────────────────────────────────

final updateHttpProvider = Provider<UpdateHttp>((ref) => IoUpdateHttp());
final updateInstallerProvider = Provider<UpdateInstaller>((ref) => const ChannelUpdateInstaller());
final privilegedInstallerProvider = Provider<PrivilegedInstaller>((ref) => const ChannelPrivilegedInstaller());
final updateSourcesProvider = Provider<UpdateSources>((ref) => defaultUpdateSources());
final updateClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Flutter's `appFlavor` (`--flavor arm64`); the native ABI is the fallback.
final updateFlavorNameProvider = Provider<String?>((ref) => appFlavor);

/// Where APKs are downloaded (app cache, so the system may reclaim it).
final updateDirectoryProvider = Provider<Future<Directory> Function()>(
  (ref) =>
      () async => Directory('${(await getTemporaryDirectory()).path}/updates'),
);

// ── Throttle ─────────────────────────────────────────────────────────────────

/// Automatic checks: once a day after one that got an answer, and not more
/// often than every few hours while they keep failing. A clock that went
/// backwards counts as due.
bool isAutoCheckDue({
  required DateTime now,
  DateTime? lastChecked,
  DateTime? lastAttempt,
  Duration interval = const Duration(hours: 24),
  Duration retryAfterFailure = const Duration(hours: 4),
}) {
  bool elapsed(DateTime? since, Duration span) => since == null || now.isBefore(since) || now.difference(since) >= span;
  return elapsed(lastChecked, interval) && elapsed(lastAttempt, retryAfterFailure);
}

// ── State ────────────────────────────────────────────────────────────────────

enum UpdateCheckPhase { idle, checking, upToDate, available, unavailable }

enum UpdateTaskPhase { idle, downloading, verifying, ready, needsPermission, installing, failed }

/// Why the download or install stopped. Text in `ui/update/update_sheet.dart`.
enum UpdateProblem {
  network,
  unavailable,
  checksum,
  noChecksum,
  storage,
  noSpace,
  permissionUnavailable,
  installCancelled,
  installUnconfirmed,
  signature,
  notDsh,
  downgrade,
  incompatible,
  invalid,
  blocked,
  installFailed,
}

class AppUpdateState {
  const AppUpdateState({
    required this.current,
    this.loaded = false,
    this.installable = true,
    this.noticeOnly = false,
    this.autoCheck = true,
    this.flavor,
    this.check = UpdateCheckPhase.idle,
    this.checkFailure,
    this.latest,
    this.skippedVersion,
    this.lastCheckedAt,
    this.task = UpdateTaskPhase.idle,
    this.received = 0,
    this.total,
    this.source,
    this.problem,
    this.apkHere = false,
    this.installedSha256,
    this.patchFailedVersion,
    this.installRoute = UpdateInstallRoute.system,
    this.privilegedStatus = const PrivilegedInstallStatus(),
    this.selfUpdate = const SelfUpdatePending(),
    this.privilegedErrorCode,
    this.loadingInstallStatus = false,
  });

  /// Preferences were read; nothing automatic runs before that.
  final bool loaded;

  /// Whether this build has the APK download and installation path.
  final bool installable;

  /// HarmonyOS checks the feed and offers a release page, never an APK.
  final bool noticeOnly;
  bool get checkable => installable || noticeOnly;

  /// The notice can open only a real web page, without embedded credentials.
  /// A newer feed version alone does not establish an OH installable artifact.
  Uri? get noticePage {
    if (!noticeOnly) return null;
    final page = latest?.pageUrl;
    if (page == null || (page.scheme != 'https' && page.scheme != 'http') ||
        page.host.isEmpty || page.userInfo.isNotEmpty) {
      return null;
    }
    return page;
  }
  final bool autoCheck;

  /// Installed version (native versionName + versionCode).
  final AppVersion current;
  final ApkFlavor? flavor;

  final UpdateCheckPhase check;
  final CheckFailure? checkFailure;

  /// The newest release, only when it is newer than [current].
  final ReleaseInfo? latest;
  final String? skippedVersion;
  final DateTime? lastCheckedAt;

  final UpdateTaskPhase task;
  final int received;
  final int? total;

  /// Mirror the download is coming through.
  final String? source;
  final UpdateProblem? problem;

  /// The verified download is still here in this session: 「导出安装包」 can copy
  /// it out for signing by hand. Cleared with the file, and when the offer it
  /// was downloaded for is replaced.
  final bool apkHere;

  /// SHA-256 of the installed APK, once hashed (only for offers with patches).
  final String? installedSha256;

  /// The release whose patch failed: its whole APK is downloaded instead.
  final String? patchFailedVersion;

  final UpdateInstallRoute installRoute;
  final PrivilegedInstallStatus privilegedStatus;
  final SelfUpdatePending selfUpdate;
  final String? privilegedErrorCode;
  final bool loadingInstallStatus;

  bool get hasSelfUpdateResult => selfUpdate.state != SelfUpdatePendingState.none;
  bool get hasUpdate => latest != null;
  bool get isSkipped => latest != null && skippedVersion == latest!.version.toString();
  ReleaseAsset? get asset => noticeOnly ? null : latest?.apkFor(flavor);

  /// What a download fetches in place of [asset]: the patch from the installed
  /// APK, unless one already failed for this release.
  ReleasePatch? get patch {
    final latest = this.latest;
    if (latest == null || asset == null || latest.version.toString() == patchFailedVersion) return null;
    return latest.patchFor(flavor, installedSha256);
  }

  /// Bytes a download fetches.
  int? get downloadSize => patch?.size ?? asset?.size;

  /// 0..1 while downloading with a known size.
  double? get progress => total == null || total == 0 ? null : (received / total!).clamp(0.0, 1.0);

  bool get busy =>
      task == UpdateTaskPhase.downloading || task == UpdateTaskPhase.verifying ||
      task == UpdateTaskPhase.installing || selfUpdate.unresolved;

  AppUpdateState copyWith({
    bool? loaded,
    bool? installable,
    bool? noticeOnly,
    bool? autoCheck,
    AppVersion? current,
    ApkFlavor? flavor,
    UpdateCheckPhase? check,
    CheckFailure? Function()? checkFailure,
    ReleaseInfo? Function()? latest,
    String? Function()? skippedVersion,
    DateTime? lastCheckedAt,
    UpdateTaskPhase? task,
    int? received,
    int? Function()? total,
    String? Function()? source,
    UpdateProblem? Function()? problem,
    bool? apkHere,
    String? installedSha256,
    String? Function()? patchFailedVersion,
    UpdateInstallRoute? installRoute,
    PrivilegedInstallStatus? privilegedStatus,
    SelfUpdatePending? selfUpdate,
    String? Function()? privilegedErrorCode,
    bool? loadingInstallStatus,
  }) => AppUpdateState(
    loaded: loaded ?? this.loaded,
    installable: installable ?? this.installable,
    noticeOnly: noticeOnly ?? this.noticeOnly,
    autoCheck: autoCheck ?? this.autoCheck,
    current: current ?? this.current,
    flavor: flavor ?? this.flavor,
    check: check ?? this.check,
    checkFailure: checkFailure == null ? this.checkFailure : checkFailure(),
    latest: latest == null ? this.latest : latest(),
    skippedVersion: skippedVersion == null ? this.skippedVersion : skippedVersion(),
    lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
    task: task ?? this.task,
    received: received ?? this.received,
    total: total == null ? this.total : total(),
    source: source == null ? this.source : source(),
    problem: problem == null ? this.problem : problem(),
    apkHere: apkHere ?? this.apkHere,
    installedSha256: installedSha256 ?? this.installedSha256,
    patchFailedVersion: patchFailedVersion == null ? this.patchFailedVersion : patchFailedVersion(),
    installRoute: installRoute ?? this.installRoute,
    privilegedStatus: privilegedStatus ?? this.privilegedStatus,
    selfUpdate: selfUpdate ?? this.selfUpdate,
    privilegedErrorCode: privilegedErrorCode == null ? this.privilegedErrorCode : privilegedErrorCode(),
    loadingInstallStatus: loadingInstallStatus ?? this.loadingInstallStatus,
  );
}

// ── Controller ───────────────────────────────────────────────────────────────

/// The offer in [state] is [version]'s APK named [asset], and (when [sha256]
/// is given) names that digest for it.
bool _offers(AppUpdateState state, AppVersion version, String asset, {String? sha256}) {
  final latest = state.latest;
  final offered = state.asset;
  return latest != null &&
      offered != null &&
      latest.version.toString() == version.toString() &&
      offered.name == asset &&
      (sha256 == null || offered.sha256 == sha256);
}

/// How a check's answer relates to the offer on screen.
enum _Answer {
  /// The same release and APK. A digest only one side knows is not a
  /// different one: the answer fills it in, or keeps the one known.
  same,

  /// Another release or another APK.
  changed,

  /// The same version and file name under another digest: one of the two
  /// sources is wrong, and nothing verified for the old digest is installed.
  conflict,
}

/// A verified download and the offer it was downloaded for. Only this file,
/// and only while that offer is the one on screen, goes to the installer.
class _ReadyApk {
  const _ReadyApk({required this.file, required this.version, required this.asset, required this.sha256});

  final File file;
  final AppVersion version;

  /// Asset name ([ReleaseAsset.name]).
  final String asset;

  /// The digest bound to it at download (the offer's, or `SHA256SUMS`',
  /// pinned to the offer then), and what the file hashed to.
  final String sha256;

  /// [state] offers this release and this asset under this digest: what is
  /// on screen, what was verified and what is installed are one (version,
  /// file, digest). An offer without a digest vouches for none.
  bool isFor(AppUpdateState state) => _offers(state, version, asset, sha256: sha256);

  /// [state] offers this release and this asset, whatever digest it names.
  bool isFile(AppUpdateState state) => _offers(state, version, asset);

  /// The APK's own manifest names this release. Fields the system didn't
  /// report don't count against it.
  bool isVersion(ApkInspection inspection) {
    final name = inspection.versionName;
    if (name != null && AppVersion.tryParse(name)?.name != version.name) return false;
    final code = inspection.versionCode;
    return version.build == null || code == null || version.build == code;
  }
}

class AppUpdateController extends Notifier<AppUpdateState> {
  static const _autoKey = 'update_auto_check';
  static const _skippedKey = 'update_skipped_version';
  static const _checkedKey = 'update_last_checked';
  static const _attemptKey = 'update_last_attempt';
  static const _endpointKey = 'update_endpoint';
  static const _mirrorKey = 'update_mirror';
  static const _latestKey = 'update_latest';
  static const _installedKey = 'update_installed_sha256';
  static const _patchFailedKey = 'update_patch_failed';

  /// Free space wanted on top of twice the APK (download + install staging).
  static const _spareBytes = 64 * 1024 * 1024;

  SharedPreferences? _prefs;
  late Future<void> _loading;
  Future<UpdateCheckPhase>? _checking;
  CancelToken? _cancel;
  _ReadyApk? _apk;
  Future<String?>? _installedHash;
  bool _privilegedDispatching = false;
  int _reconcileRead = 0;

  /// Bumped per download and install attempt: a late answer from an abandoned
  /// one, or a check that started before it, can't change what it works on.
  int _run = 0;

  /// What a check on the beta channel calls itself: the installed version,
  /// build and ABI once the native side said them.
  String _userAgent = updaterUserAgent(version: AppInfo.version.split('+').first);

  bool get _noticeOnly => ref.read(operatingSystemProvider) == 'ohos';

  UpdateInstaller get _installer => ref.read(updateInstallerProvider);
  PrivilegedInstaller get _privileged => ref.read(privilegedInstallerProvider);
  UpdateHttp get _http => ref.read(updateHttpProvider);
  DateTime _now() => ref.read(updateClockProvider)();

  @override
  AppUpdateState build() {
    ref.onDispose(() => _cancel?.cancel());
    _loading = _load();
    if (_noticeOnly) {
      return AppUpdateState(
        current: AppVersion.tryParse(AppInfo.version) ?? const AppVersion(0, 0, 0),
        installable: false,
        noticeOnly: true,
      );
    }
    return AppUpdateState(current: AppVersion.tryParse(AppInfo.version) ?? const AppVersion(0, 0, 0));
  }

  /// Completes once preferences, the installed version and startup cleanup are ready.
  Future<void> get ready => _loading;

  Future<void> _load() async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return; // No preferences (widget tests): stay unloaded, nothing automatic.
    }
    if (_noticeOnly) {
      await _loadNotice(prefs);
      return;
    }
    InstalledApp? app;
    var installable = true;
    try {
      app = await _installer.installedApp();
    } on MissingPluginException {
      // No APK installer on this build (HarmonyOS, desktop): no updates here.
      installable = false;
    } catch (_) {
      // Native side failed: fall back to the compiled-in version.
    }
    if (!ref.mounted) return;
    _prefs = prefs;
    if (app?.versionName case final name?) {
      _userAgent = updaterUserAgent(version: name, build: app?.versionCode, abi: app?.androidAbi);
    }
    final current = AppVersion.tryParse(app?.versionName)?.withBuild(app?.versionCode) ?? state.current;
    final flavor = ApkFlavor.fromName(ref.read(updateFlavorNameProvider)) ?? ApkFlavor.fromAbi(app?.abi);
    ReleaseInfo? cached;
    try {
      final raw = prefs.getString(_latestKey);
      if (raw != null) cached = parseUpdateManifest(jsonDecode(raw));
    } catch (_) {}
    final latest = cached != null && cached.version.isNewerThan(current) ? cached : null;
    if (latest == null) {
      // Updated (or nothing pending): drop the offer and any leftover APK.
      unawaited(prefs.remove(_latestKey));
      // A new download must not race this walk and have its verified APK deleted.
      await _cleanDownloads();
      if (!ref.mounted) return;
    }
    int? ms(String key) => prefs.getInt(key);
    state = state.copyWith(
      loaded: true,
      installable: installable,
      autoCheck: prefs.getBool(_autoKey) ?? true,
      current: current,
      flavor: flavor,
      skippedVersion: () => prefs.getString(_skippedKey),
      lastCheckedAt: ms(_checkedKey) == null ? null : DateTime.fromMillisecondsSinceEpoch(ms(_checkedKey)!),
      latest: () => latest,
      check: latest != null ? UpdateCheckPhase.available : UpdateCheckPhase.idle,
      patchFailedVersion: () => prefs.getString(_patchFailedKey),
    );
    // No APK installer on this build: there is no self-update journal to read.
    if (installable) await reconcileSelfUpdate();
    if (ref.mounted) unawaited(_hashIfPatched());
  }

  void selectInstallRoute(UpdateInstallRoute route) {
    if (_noticeOnly) return;
    if (state.busy || state.loadingInstallStatus) return;
    state = state.copyWith(installRoute: route, privilegedErrorCode: () => null);
    if (route != UpdateInstallRoute.system) unawaited(refreshInstallStatus());
  }

  Future<void> refreshInstallStatus() async {
    if (_noticeOnly || state.loadingInstallStatus) return;
    state = state.copyWith(loadingInstallStatus: true);
    try {
      final status = await _privileged.status();
      if (ref.mounted) state = state.copyWith(privilegedStatus: status, privilegedErrorCode: () => status.errorCode);
    } catch (_) {
      if (ref.mounted) state = state.copyWith(privilegedErrorCode: () => 'nativeUnavailable');
    } finally {
      if (ref.mounted) state = state.copyWith(loadingInstallStatus: false);
    }
  }

  Future<void> requestUpdateShizukuPermission() async {
    if (_noticeOnly) return;
    if (state.busy || state.loadingInstallStatus) return;
    state = state.copyWith(loadingInstallStatus: true, privilegedErrorCode: () => null);
    var granted = false;
    try {
      granted = await _privileged.requestShizukuPermission();
    } catch (_) {} finally {
      if (ref.mounted) state = state.copyWith(loadingInstallStatus: false);
    }
    if (!ref.mounted) return;
    await refreshInstallStatus();
    if (ref.mounted && !granted) state = state.copyWith(privilegedErrorCode: () => 'permissionRequired');
  }

  /// Only native confirmation can clear an inactive unknown journal. This is
  /// not cancellation of a system install and never starts another attempt.
  Future<void> acknowledgeUnknownSelfUpdate() async {
    if (_privilegedDispatching || state.loadingInstallStatus ||
        state.selfUpdate.state != SelfUpdatePendingState.unknown || !state.selfUpdate.canAcknowledge) {
      return;
    }
    final run = _run;
    state = state.copyWith(loadingInstallStatus: true);
    try {
      final pending = await _privileged.acknowledgeUnknown();
      if (!ref.mounted || run != _run) return;
      if (pending.state == SelfUpdatePendingState.none) {
        _run++;
        _reconcileRead++;
        state = state.copyWith(
          selfUpdate: pending, task: _apk?.isFor(state) == true ? UpdateTaskPhase.ready : UpdateTaskPhase.idle,
          problem: () => null, privilegedErrorCode: () => null,
        );
      }
    } catch (_) {
      // Denial or missing native confirmation leaves the unresolved state.
    } finally {
      if (ref.mounted) state = state.copyWith(loadingInstallStatus: false);
    }
  }

  /// Read only. Missing/ambiguous evidence never unlocks replay of a dispatched
  /// attempt, and a successful RPC alone is not installation success.
  Future<void> reconcileSelfUpdate() async {
    final read = ++_reconcileRead;
    final run = _run;
    SelfUpdatePending pending;
    try {
      pending = await _privileged.reconcile();
    } catch (_) {
      return;
    }
    if (!ref.mounted || read != _reconcileRead || run != _run || pending.state == SelfUpdatePendingState.none) return;
    // A resume during native confirmation may still see the previous journal.
    // Wait for this RPC's result before accepting terminal evidence.
    if (_privilegedDispatching && !pending.unresolved) return;
    if (pending.verified) {
      try {
        final app = await _installer.installedApp();
        if (!ref.mounted || read != _reconcileRead || run != _run) return;
        final code = app.versionCode;
        final target = pending.versionCode;
        final verified = code != null && target != null &&
            (pending.state == SelfUpdatePendingState.installed ? code == target : code > target);
        if (verified) {
          _run++;
          _apk = null;
          final current = AppVersion.tryParse(app.versionName)?.withBuild(code) ?? state.current.withBuild(code);
          final latest = state.latest;
          final keepOffer = latest != null && latest.version.isNewerThan(current);
          state = state.copyWith(
            current: current, selfUpdate: pending, task: UpdateTaskPhase.idle,
            latest: () => keepOffer ? latest : null,
            check: keepOffer ? UpdateCheckPhase.available : UpdateCheckPhase.upToDate,
            problem: () => null, privilegedErrorCode: () => null, apkHere: false,
          );
          if (!keepOffer) unawaited(_prefs?.remove(_latestKey));
          return;
        }
      } catch (_) {}
      pending = SelfUpdatePending(
        state: SelfUpdatePendingState.unknown, backend: pending.backend,
        versionCode: pending.versionCode, errorCode: 'outcomeUnknown',
      );
    }
    if (!ref.mounted || read != _reconcileRead || run != _run) return;
    state = state.copyWith(
      selfUpdate: pending,
      installRoute: pending.backend,
      task: pending.unresolved ? UpdateTaskPhase.installing : UpdateTaskPhase.failed,
      problem: () => pending.unresolved ? null : UpdateProblem.installFailed,
      privilegedErrorCode: () => pending.errorCode,
    );
  }

  Future<void> _loadNotice(SharedPreferences prefs) async {
    var current = state.current;
    try {
      // Device facts only: this does not start the usage statistics controller.
      final device = await const UsageDeviceChannel().read();
      final version = AppVersion.tryParse(device.app);
      if (version != null) {
        // The existing channel uses zero when the native versionCode is absent.
        // Keep the compiled build on that fallback instead of inventing build 0.
        current = device.build > 0
            ? version.withBuild(device.build)
            : version.name == current.name ? current : version;
      }
    } catch (_) {
      // A device-facts failure does not disable checking the configured feed.
    }
    if (!ref.mounted) return;
    _prefs = prefs;
    ReleaseInfo? cached;
    try {
      final raw = prefs.getString(_latestKey);
      if (raw != null) cached = parseUpdateManifest(jsonDecode(raw));
    } catch (_) {}
    final latest = cached != null && cached.version.isNewerThan(current) ? cached : null;
    if (latest == null) unawaited(prefs.remove(_latestKey));
    final checked = prefs.getInt(_checkedKey);
    state = state.copyWith(
      loaded: true,
      installable: false,
      noticeOnly: true,
      current: current,
      autoCheck: prefs.getBool(_autoKey) ?? true,
      skippedVersion: () => prefs.getString(_skippedKey),
      lastCheckedAt: checked == null ? null : DateTime.fromMillisecondsSinceEpoch(checked),
      latest: () => latest,
      check: latest != null ? UpdateCheckPhase.available : UpdateCheckPhase.idle,
    );
  }

  Future<void> _cleanDownloads() async {
    try {
      final dir = await ref.read(updateDirectoryProvider)();
      await ApkDownloader(http: _http, directory: dir).clean();
    } catch (_) {}
  }

  /// Hashes the installed APK when the offer has patches for this device, so
  /// the sheet can tell which applies (and say its size).
  Future<void> _hashIfPatched() async {
    if (_noticeOnly) return;
    if (state.latest?.patches[state.flavor]?.isNotEmpty ?? false) await _installedSha256();
  }

  /// SHA-256 of the installed APK, which patches name as their base.
  Future<String?> _installedSha256() => _installedHash ??= _hashInstalled();

  /// Hashed off the UI isolate once per installed build (versionCode +
  /// install time), then remembered. Null when the native side doesn't say
  /// where the APK is, or it can't be read.
  Future<String?> _hashInstalled() async {
    String? digest;
    try {
      final app = await _installer.installedApp();
      final build = '${app.versionCode}:${app.lastUpdateTime}:';
      final known = _prefs?.getString(_installedKey);
      if (known != null && known.startsWith(build)) {
        digest = known.substring(build.length);
      } else if (app.apkPath case final path?) {
        digest = await sha256OfFile(File(path));
        unawaited(_prefs?.setString(_installedKey, '$build$digest'));
      }
    } catch (_) {}
    if (digest != null && ref.mounted) state = state.copyWith(installedSha256: digest);
    return digest;
  }

  // ── Checking ───────────────────────────────────────────────────────────────

  /// The launch check: runs only when enabled and due ([isAutoCheckDue]).
  /// True when the caller should offer the update (newer and not skipped).
  Future<bool> autoCheckIfDue() async {
    await ready;
    final prefs = _prefs;
    if (!ref.mounted || prefs == null || !state.checkable || !state.autoCheck || state.busy) return false;
    DateTime? at(String key) {
      final ms = prefs.getInt(key);
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    }

    if (!isAutoCheckDue(now: _now(), lastChecked: at(_checkedKey), lastAttempt: at(_attemptKey))) return false;
    await check();
    // Switched off while the check was in flight: keep the result, skip the offer.
    return ref.mounted && state.autoCheck && state.hasUpdate && !state.isSkipped &&
        (state.noticeOnly ? state.noticePage != null : state.asset != null);
  }

  /// Asks the sources for the latest release. Concurrent calls share one check;
  /// a running download keeps its release.
  Future<UpdateCheckPhase> check() async {
    await ready;
    if (!ref.mounted || !state.checkable) return UpdateCheckPhase.idle;
    if (state.busy) return state.check;
    return _checking ??= _check().whenComplete(() => _checking = null);
  }

  Future<UpdateCheckPhase> _check() async {
    state = state.copyWith(check: UpdateCheckPhase.checking, checkFailure: () => null);
    final run = _run;
    final prefs = _prefs;
    final now = _now();
    final checker = UpdateChecker(http: _http, sources: ref.read(updateSourcesProvider), userAgent: _userAgent);
    final result = await checker.check(preferred: prefs?.getString(_endpointKey), installed: state.current);
    if (!ref.mounted) return UpdateCheckPhase.idle;
    unawaited(prefs?.setInt(_attemptKey, now.millisecondsSinceEpoch));
    switch (result) {
      case CheckFound(:final release, :final endpoint):
        unawaited(prefs?.setString(_endpointKey, endpoint.id));
        if (endpoint.mirrorId case final mirror?) unawaited(prefs?.setString(_mirrorKey, mirror));
        var offer = release.version.isNewerThan(state.current) ? release : null;
        final answer = _compare(state.latest, offer);
        final changed = answer == _Answer.changed;
        if (changed && (run != _run || state.busy)) {
          // A download or install started while this check ran: it keeps the
          // release it is for, on screen and in the cache. Not counted as
          // checked, so a later check brings the answer back.
          state = state.copyWith(check: state.hasUpdate ? UpdateCheckPhase.available : UpdateCheckPhase.upToDate);
          return state.check;
        }
        // An answer without this APK's digest doesn't forget the one known.
        if (answer == _Answer.same) offer = _keepDigest(offer);
        unawaited(prefs?.setInt(_checkedKey, now.millisecondsSinceEpoch));
        if (offer case final offer?) {
          unawaited(prefs?.setString(_latestKey, jsonEncode(offer.toManifestJson())));
        } else {
          unawaited(prefs?.remove(_latestKey));
        }
        if (changed) _apk = null;
        state = state.copyWith(
          check: offer != null ? UpdateCheckPhase.available : UpdateCheckPhase.upToDate,
          latest: () => offer,
          lastCheckedAt: now,
          task: changed ? UpdateTaskPhase.idle : null,
          problem: changed ? () => null : null,
          apkHere: changed ? false : null,
        );
        if (answer == _Answer.conflict) await _conflicted();
        // Before the offer shows: its size is the patch's when one applies.
        await _hashIfPatched();
      case CheckFailed(:final failure):
        // A cached offer stays on screen; the check just couldn't refresh it.
        state = state.copyWith(
          check: state.hasUpdate ? UpdateCheckPhase.available : UpdateCheckPhase.unavailable,
          checkFailure: () => failure,
        );
    }
    return state.check;
  }

  /// [b] (a check's answer) against [a] (the offer on screen), for this
  /// device's APK. The digest on screen includes one a download pinned there.
  _Answer _compare(ReleaseInfo? a, ReleaseInfo? b) {
    if (a == null || b == null) return a == null && b == null ? _Answer.same : _Answer.changed;
    if (a.version.toString() != b.version.toString()) return _Answer.changed;
    final x = a.apkFor(state.flavor);
    final y = b.apkFor(state.flavor);
    if (x == null || y == null) return x == null && y == null ? _Answer.same : _Answer.changed;
    if (x.name != y.name) return _Answer.changed;
    if (x.sha256 != null && y.sha256 != null && x.sha256 != y.sha256) return _Answer.conflict;
    return _Answer.same;
  }

  /// [offer] (the same APK as on screen) with the digest on screen when it
  /// names none itself.
  ReleaseInfo? _keepDigest(ReleaseInfo? offer) {
    final flavor = state.flavor;
    final known = state.asset?.sha256;
    if (offer == null || flavor == null || known == null || offer.apkFor(flavor)?.sha256 != null) return offer;
    return offer.withApkSha256(flavor, known);
  }

  /// The offer on screen now names another digest for the same version and
  /// file. Nothing downloaded or verified under the old one goes to the
  /// installer: a running download or install finds out at its next step,
  /// fails and throws its file away; an APK nobody is installing is thrown
  /// away here. 「重试」 then downloads against the digest on screen.
  Future<void> _conflicted() async {
    if (state.busy) {
      // The running attempt owns the file: it fails it itself. A download
      // stops now rather than at its last byte.
      _cancel?.cancel();
      return;
    }
    final apk = _apk;
    if (apk == null) return; // Nothing kept: a leftover file is re-hashed against the new digest.
    // An install attempt the grace period gave up on can't come back to it.
    final run = ++_run;
    _apk = null;
    // Busy while the file goes, so 「重试」 can't download to the same path
    // meanwhile and meet the delete.
    state = state.copyWith(task: UpdateTaskPhase.verifying, problem: () => null, apkHere: false);
    await _deleteQuietly(apk.file);
    if (ref.mounted && run == _run) {
      state = state.copyWith(task: UpdateTaskPhase.failed, problem: () => UpdateProblem.checksum);
    }
  }

  /// Pins [sha256], which a download took from `SHA256SUMS`, to the offer on
  /// screen and in the cache: from here on what is shown, verified and
  /// installed is one (version, file, digest). False when the offer meanwhile
  /// names another digest for this file, or is no longer this file.
  bool _pin(AppVersion version, String asset, String sha256) {
    final latest = state.latest;
    final flavor = state.flavor;
    if (latest == null || flavor == null || !_offers(state, version, asset)) return false;
    final named = state.asset!.sha256;
    if (named != null) return named == sha256;
    final pinned = latest.withApkSha256(flavor, sha256);
    state = state.copyWith(latest: () => pinned);
    unawaited(_prefs?.setString(_latestKey, jsonEncode(pinned.toManifestJson())));
    return true;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Already gone (the system reclaimed the cache).
    }
  }

  Future<void> setAutoCheck(bool value) async {
    state = state.copyWith(autoCheck: value);
    await _prefs?.setBool(_autoKey, value);
  }

  /// 「跳过这个版本」: no automatic prompt until a newer one appears.
  Future<void> skipLatest() async {
    final version = state.latest?.version.toString();
    if (version == null) return;
    state = state.copyWith(skippedVersion: () => version);
    await _prefs?.setString(_skippedKey, version);
  }

  // ── Download ───────────────────────────────────────────────────────────────

  Future<void> startDownload() async {
    if (_noticeOnly) return;
    await ready;
    final release = state.latest;
    final asset = state.asset;
    if (!ref.mounted || release == null || asset == null || state.busy) return;
    final run = ++_run;
    bool owns() => ref.mounted && run == _run;
    final cancel = _cancel = CancelToken();
    _apk = null;
    state = state.copyWith(
      task: UpdateTaskPhase.downloading,
      apkHere: false,
      received: 0,
      total: () => state.downloadSize,
      source: () => null,
      problem: () => null,
      selfUpdate: const SelfUpdatePending(),
      privilegedErrorCode: () => null,
    );

    void fail(UpdateProblem problem) {
      if (owns()) state = state.copyWith(task: UpdateTaskPhase.failed, problem: () => problem);
    }

    await _hashIfPatched();
    if (!owns()) return;
    InstalledApp? app;
    try {
      app = await _installer.installedApp();
    } catch (_) {
      // Unknown free space and no APK to patch: let the download find out.
    }
    if (!owns()) return;
    // Room for the APK and its install staging copy. A patch needs no more:
    // it builds the APK from the installed one and goes before the install.
    if (app?.freeBytes case final free? when asset.size != null && free < asset.size! * 2 + _spareBytes) {
      return fail(UpdateProblem.noSpace);
    }

    final sources = ref.read(updateSourcesProvider);
    final mirror = _prefs?.getString(_mirrorKey);
    var sha256 = asset.sha256;
    if (sha256 == null) {
      final sums = release.checksumsUrl ?? githubReleaseAsset(release.tag, checksumsName);
      sha256 = await fetchSha256FromSums(_http, sources.downloadUrls([sums], preferredMirror: mirror), asset.name);
      if (!owns()) return;
      // A check answering meanwhile may have named another digest for this
      // file: neither is downloaded against the other.
      if (sha256 != null && !_pin(release.version, asset.name, sha256)) return fail(UpdateProblem.checksum);
      if (cancel.isCancelled) {
        state = state.copyWith(task: UpdateTaskPhase.idle);
        return;
      }
      if (sha256 == null) return fail(UpdateProblem.noChecksum);
    }

    final Directory dir;
    try {
      dir = await ref.read(updateDirectoryProvider)();
    } catch (_) {
      return fail(UpdateProblem.storage);
    }
    if (!owns()) return;
    final downloader = ApkDownloader(http: _http, directory: dir);
    final patch = state.patch;
    final base = app?.apkPath;
    await downloader.clean(keep: [asset.name, ?patch?.name]);
    if (!owns()) return;
    void onProgress(DownloadProgress p) {
      if (owns()) {
        state = state.copyWith(
          task: UpdateTaskPhase.downloading,
          received: p.received,
          total: () => p.total,
          source: () => p.source,
        );
      }
    }

    void onVerifying() {
      if (owns()) state = state.copyWith(task: UpdateTaskPhase.verifying);
    }

    // A file of this release: where the manifest puts it, then the GitHub
    // release asset through every mirror.
    List<DownloadUrl> urls(Uri own, String name) =>
        sources.downloadUrls([own, githubReleaseAsset(release.tag, name)], preferredMirror: mirror);

    // An APK already here (built or downloaded before) is checked and kept.
    var outcome = patch != null && base != null && !await File('${dir.path}/${asset.name}').exists()
        ? await downloader.downloadPatched(
            patch: patch,
            base: File(base),
            fileName: asset.name,
            sha256: sha256,
            // Next to the APK, wherever that is.
            urls: urls(asset.url.resolve(patch.name), patch.name),
            expectedSize: asset.size,
            cancel: cancel,
            onProgress: onProgress,
            onVerifying: onVerifying,
          )
        : null;
    if (!owns()) return;
    if (outcome is DownloadFailed) {
      // Silently the whole APK instead, and never this release's patch again.
      outcome = null;
      final version = release.version.toString();
      unawaited(_prefs?.setString(_patchFailedKey, version));
      state = state.copyWith(
        task: UpdateTaskPhase.downloading,
        received: 0,
        total: () => asset.size,
        source: () => null,
        patchFailedVersion: () => version,
      );
    }
    outcome ??= await downloader.download(
      fileName: asset.name,
      sha256: sha256,
      urls: urls(asset.url, asset.name),
      expectedSize: asset.size,
      cancel: cancel,
      onProgress: onProgress,
      onVerifying: onVerifying,
    );
    if (!owns()) return;
    if (!_offers(state, release.version, asset.name, sha256: sha256)) {
      // A check named another digest for this file while it downloaded (and
      // stopped it): what came is kept for neither digest.
      await _deleteQuietly(File('${dir.path}/${asset.name}'));
      await _deleteQuietly(File('${dir.path}/${asset.name}.part'));
      return fail(UpdateProblem.checksum);
    }
    switch (outcome) {
      case DownloadDone(:final file, :final from):
        _apk = _ReadyApk(file: file, version: release.version, asset: asset.name, sha256: sha256);
        if (from?.mirrorId case final id?) unawaited(_prefs?.setString(_mirrorKey, id));
        state = state.copyWith(task: UpdateTaskPhase.ready, apkHere: true);
      case DownloadCancelled():
        state = state.copyWith(task: UpdateTaskPhase.idle, received: 0);
      case DownloadFailed(:final failure):
        fail(switch (failure) {
          DownloadFailure.network => UpdateProblem.network,
          DownloadFailure.unavailable => UpdateProblem.unavailable,
          DownloadFailure.checksum => UpdateProblem.checksum,
          DownloadFailure.storage => UpdateProblem.storage,
        });
    }
  }

  void cancelDownload() => _cancel?.cancel();

  /// 「重试」: install again when the APK is already here, else resume the download.
  Future<void> retry({int? port}) async {
    if (_noticeOnly) return;
    if (state.busy) return;
    final apk = _apk;
    if (apk != null && await apk.file.exists()) {
      await install(route: state.installRoute, port: port);
    } else {
      await startDownload();
    }
  }

  // ── Install ────────────────────────────────────────────────────────────────

  /// 「用系统安装器安装」: the downloaded package, already checked by [install],
  /// in the system's own installer. Some OEM builds stop the in-app install
  /// before asking and it reads as cancelled. False when it couldn't open.
  Future<bool> installWithSystem() async {
    if (_noticeOnly) return false;
    final apk = _apk;
    final run = _run;
    if (!ref.mounted || apk == null || state.busy || !apk.isFor(state) || !await apk.file.exists()) return false;
    // The file check can outlive this owner, package or install attempt.
    if (!ref.mounted || run != _run || state.busy || !identical(_apk, apk) || !apk.isFor(state)) return false;
    return _installer.openWithSystemInstaller(apk.file.path);
  }

  /// 「导出安装包」: copies the verified download into `Download/DSH-Go`, so it can
  /// be signed and installed by hand — the way out for a phone whose system
  /// refuses a first install (a vendor block) and whose owner signs it with
  /// MT Manager or the like.
  ///
  /// Returns where it landed (`Download/DSH-Go/dsh-go-1.2.0-arm64.apk`), null
  /// when there is nothing to copy or the copy failed. A package signed by hand
  /// is one no later update can cover: the signature check stays, so that phone
  /// goes on signing and installing every version itself.
  Future<String?> exportApk() async {
    if (_noticeOnly) return null;
    final apk = _apk;
    if (!ref.mounted || apk == null || state.busy || !apk.isFile(state)) return null;
    final files = ref.read(filesChannelProvider);
    try {
      if (!await apk.file.exists()) return null;
      return await files.saveToDownloads(
        apk.file.path,
        name: apk.asset,
        mime: 'application/vnd.android.package-archive',
      );
    } catch (_) {
      // FilesChannel: `missing` (gone from the cache) or a refused save.
      return null;
    }
  }

  Future<void> install({UpdateInstallRoute route = UpdateInstallRoute.system, int? port}) async {
    if (_noticeOnly) return;
    final apk = _apk;
    if (!ref.mounted || apk == null || state.busy) return;
    if (!apk.isFile(state)) {
      // Downloaded for an offer that's no longer on screen: never installed in
      // its place. (The same file under another digest fails below.)
      _apk = null;
      state = state.copyWith(task: UpdateTaskPhase.idle, problem: () => null, apkHere: false);
      return;
    }
    // Taken before the first await, so a second tap or a resume finds it busy.
    // Once [onAppResumed] gives up on this attempt, nothing below writes state,
    // clears [_apk] or deletes the file: an answer, a late exception or a
    // check that was still running all belong to the attempt that replaced it.
    final run = ++_run;
    state = state.copyWith(
      task: UpdateTaskPhase.installing, problem: () => null, installRoute: route,
      selfUpdate: const SelfUpdatePending(), privilegedErrorCode: () => null,
    );
    bool owns() => ref.mounted && run == _run;
    // A file that failed its checks is deleted before the failure shows (the
    // task stays busy meanwhile): 「重试」 then downloads afresh and can't meet
    // a delete of the same path still on its way.
    Future<void> fail(UpdateProblem problem, {bool discard = false}) async {
      if (!owns()) return;
      if (discard) {
        try {
          await apk.file.delete();
        } on FileSystemException {
          // Already gone (the system reclaimed the cache).
        }
        // Given up on meanwhile: the bytes are gone either way, and a later
        // install finds that out when it hashes them.
        if (!owns()) return;
        if (identical(_apk, apk)) _apk = null;
      }
      state = state.copyWith(task: UpdateTaskPhase.failed, problem: () => problem, apkHere: discard ? false : null);
    }

    // The offer on screen still names this APK's version, file and the digest
    // bound to it at download. A check can name another digest for the same
    // file at any await below (it doesn't end this attempt): then the attempt
    // fails and the file goes, never installed under either digest.
    bool bound() => apk.isFor(state);
    Future<void> conflict() => fail(UpdateProblem.checksum, discard: true);

    try {
      if (!bound()) return await conflict();
      final allowed = route != UpdateInstallRoute.system || await _installer.canRequestInstalls();
      if (!owns()) return;
      if (!bound()) return await conflict();
      if (!allowed) {
        state = state.copyWith(task: UpdateTaskPhase.needsPermission, problem: () => null);
        return;
      }
      // The bytes still hash to the digest bound at download.
      final digest = await _digest(apk.file);
      if (!owns()) return;
      if (digest != apk.sha256 || !bound()) return await conflict();
      final inspection = await _installer.inspect(apk.file.path);
      if (!owns()) return;
      if (!inspection.valid) return await fail(UpdateProblem.invalid, discard: true);
      if (!inspection.samePackage) return await fail(UpdateProblem.notDsh, discard: true);
      if (inspection.signatureMatches == false ||
          route != UpdateInstallRoute.system && inspection.signatureMatches != true) {
        return await fail(UpdateProblem.signature);
      }
      if (!apk.isVersion(inspection)) return await fail(UpdateProblem.checksum, discard: true);
      // Last look before the handoff: the digest the bytes were checked
      // against is still the one the offer on screen names.
      if (!bound()) return await conflict();
      if (route != UpdateInstallRoute.system) {
        final versionCode = inspection.versionCode;
        if (versionCode == null || versionCode <= 0 || (state.current.build != null && versionCode <= state.current.build!)) {
          return await fail(UpdateProblem.downgrade);
        }
        _privilegedDispatching = true;
        final PrivilegedInstallResult result;
        try {
          result = await _privileged.install(
            path: apk.file.path, sha256: apk.sha256, versionCode: versionCode, backend: route, port: port,
          );
        } catch (_) {
          if (owns()) {
            state = state.copyWith(selfUpdate: SelfUpdatePending(
              state: SelfUpdatePendingState.unknown, backend: route, versionCode: versionCode, errorCode: 'outcomeUnknown',
            ));
          }
          _privilegedDispatching = false;
          if (owns()) await reconcileSelfUpdate();
          return;
        } finally {
          _privilegedDispatching = false;
        }
        if (!owns()) return;
        state = state.copyWith(privilegedErrorCode: () => result.errorCode);
        if (result.outcomeUnknown || result.status == PrivilegedInstallOutcome.unknown ||
            result.status == PrivilegedInstallOutcome.success) {
          state = state.copyWith(selfUpdate: SelfUpdatePending(
            state: SelfUpdatePendingState.unknown, backend: route, versionCode: versionCode, errorCode: result.errorCode,
          ));
          await reconcileSelfUpdate();
          return;
        }
        state = state.copyWith(selfUpdate: const SelfUpdatePending());
        if (!bound()) return await conflict();
        if (result.status == PrivilegedInstallOutcome.aborted) {
          state = state.copyWith(task: UpdateTaskPhase.ready, problem: () => UpdateProblem.installCancelled);
          return;
        }
        final preflightProblem = switch (result.errorCode) {
          'signatureMismatch' => UpdateProblem.signature,
          'packageMismatch' => UpdateProblem.notDsh,
          'hashMismatch' || 'sizeMismatch' || 'versionMismatch' => UpdateProblem.checksum,
          'notNewer' => UpdateProblem.downgrade,
          'unsupportedAbi' => UpdateProblem.incompatible,
          'invalidApk' => UpdateProblem.invalid,
          _ => null,
        };
        if (preflightProblem != null) {
          return await fail(preflightProblem, discard: preflightProblem == UpdateProblem.checksum ||
              preflightProblem == UpdateProblem.invalid || preflightProblem == UpdateProblem.notDsh);
        }
        return await fail(switch (result.status) {
          PrivilegedInstallOutcome.blocked => UpdateProblem.blocked,
          PrivilegedInstallOutcome.incompatible => UpdateProblem.incompatible,
          PrivilegedInstallOutcome.invalid => UpdateProblem.invalid,
          PrivilegedInstallOutcome.storage => UpdateProblem.noSpace,
          _ => UpdateProblem.installFailed,
        });
      }
      final result = await _installer.install(apk.file.path);
      if (!owns() || state.task != UpdateTaskPhase.installing) return;
      // Handed over under the offer then on screen. Another digest named since
      // can't take it back from the system; unfinished, it is thrown away.
      if (result.status != InstallStatus.success && !bound()) return await conflict();
      switch (result.status) {
        case InstallStatus.success:
          state = state.copyWith(task: UpdateTaskPhase.idle);
        case InstallStatus.aborted:
          state = state.copyWith(task: UpdateTaskPhase.ready, problem: () => UpdateProblem.installCancelled);
        case InstallStatus.signature:
          await fail(UpdateProblem.signature);
        case InstallStatus.downgrade:
          await fail(UpdateProblem.downgrade);
        case InstallStatus.incompatible:
          await fail(UpdateProblem.incompatible);
        case InstallStatus.storage:
          await fail(UpdateProblem.noSpace);
        case InstallStatus.invalid:
          await fail(UpdateProblem.invalid, discard: true);
        case InstallStatus.blocked:
          await fail(UpdateProblem.blocked);
        case InstallStatus.conflict || InstallStatus.failure:
          await fail(UpdateProblem.installFailed);
      }
    } catch (_) {
      // PlatformException, MissingPluginException.
      await fail(UpdateProblem.installFailed);
    }
  }

  /// SHA-256 of [file]; null when it can't be read.
  static Future<String?> _digest(File file) async {
    try {
      return await sha256OfFile(file);
    } catch (_) {
      return null;
    }
  }

  /// Opens the system "install unknown apps" page; [onAppResumed] continues.
  Future<void> requestInstallPermission() async {
    if (_noticeOnly) return;
    var opened = false;
    try {
      opened = await _installer.openInstallPermission();
    } catch (_) {}
    if (!opened && ref.mounted) state = state.copyWith(problem: () => UpdateProblem.permissionUnavailable);
  }

  /// The app is in front again: back from the permission page (install if it
  /// was granted), or from the system install dialog. Some ROM installers close
  /// without reporting; after [confirmGrace] the person can try again.
  Future<void> onAppResumed({Duration confirmGrace = const Duration(seconds: 3)}) async {
    if (_noticeOnly) return;
    await ready;
    if (!ref.mounted) return;
    if (state.selfUpdate.unresolved || state.installRoute != UpdateInstallRoute.system) {
      if (state.selfUpdate.unresolved || state.task == UpdateTaskPhase.installing) {
        await reconcileSelfUpdate();
      } else {
        await refreshInstallStatus();
      }
      return;
    }
    switch (state.task) {
      case UpdateTaskPhase.needsPermission:
        try {
          if (await _installer.canRequestInstalls()) await install();
        } catch (_) {}
      case UpdateTaskPhase.installing:
        final run = _run;
        await Future<void>.delayed(confirmGrace);
        if (ref.mounted && run == _run && state.task == UpdateTaskPhase.installing) {
          _run++;
          // No result is not evidence of user cancellation: even inspect may
          // still be pending. Keep the package and the existing retry/fallback.
          state = state.copyWith(task: UpdateTaskPhase.ready, problem: () => UpdateProblem.installUnconfirmed);
          // The offer named another digest for it meanwhile: not ready again.
          if (_apk case final apk? when !apk.isFor(state)) await _conflicted();
        }
      default:
    }
  }
}

final appUpdateProvider = NotifierProvider<AppUpdateController, AppUpdateState>(AppUpdateController.new);
