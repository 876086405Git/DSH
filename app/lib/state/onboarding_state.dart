import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// First-run flags that outlive a single launch.
///
/// - [welcomeSeen]: the user tapped "开始" once. If the process dies mid-unpack, the
///   next launch resumes at the setup screen instead of showing the welcome again.
/// - [keySkipped]: the user chose "稍后设置" on the API key step. We don't nag on
///   every launch after that (they may have configured the key inside DSH's own
///   Web UI); settings shows the key as missing instead.
/// - [localDeclined]: the app runs without the on-device runtime: first run
///   went to a remote host instead (「远程主机」) or straight to 酒馆
///   (「和角色聊天」), or it was uninstalled in settings. A launch without the runtime then goes straight home; any
///   install clears it.
/// - [setupStep]: first run picked 「本机」 and is setting up while the runtime
///   unpacks; the page to come back to after the app was killed. Cleared once
///   first run reaches home (or goes to a remote host instead).
class OnboardingPrefs {
  const OnboardingPrefs({
    this.loaded = false,
    this.welcomeSeen = false,
    this.keySkipped = false,
    this.localDeclined = false,
    this.setupStep,
  });

  final bool loaded;
  final bool welcomeSeen;
  final bool keySkipped;
  final bool localDeclined;
  final SetupStep? setupStep;

  OnboardingPrefs copyWith({
    bool? welcomeSeen,
    bool? keySkipped,
    bool? localDeclined,
    SetupStep? setupStep,
    bool clearSetupStep = false,
  }) => OnboardingPrefs(
    loaded: loaded,
    welcomeSeen: welcomeSeen ?? this.welcomeSeen,
    keySkipped: keySkipped ?? this.keySkipped,
    localDeclined: localDeclined ?? this.localDeclined,
    setupStep: clearSetupStep ? null : (setupStep ?? this.setupStep),
  );
}

/// The first-run pages that run while the runtime unpacks
/// (docs/design/onboarding-parallel-setup.md), in order.
enum SetupStep {
  /// 选择外观.
  appearance,

  /// 想让 DSH Go 帮你做哪些事, and the permissions that takes.
  access,

  /// 连接 DeepSeek.
  connect,

  /// Everything set; waiting for the unpack to finish.
  finishing;

  static SetupStep? parse(String? wire) => SetupStep.values.asNameMap()[wire];
}

class OnboardingPrefsController extends Notifier<OnboardingPrefs> {
  static const _welcomeKey = 'onboarding_welcome_seen';
  static const _skippedKey = 'onboarding_key_skipped';
  static const _declinedKey = 'onboarding_local_declined';
  static const _setupStepKey = 'onboarding_setup_step';

  @override
  OnboardingPrefs build() {
    _load();
    return const OnboardingPrefs();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      state = OnboardingPrefs(
        loaded: true,
        welcomeSeen: prefs.getBool(_welcomeKey) ?? false,
        keySkipped: prefs.getBool(_skippedKey) ?? false,
        localDeclined: prefs.getBool(_declinedKey) ?? false,
        setupStep: SetupStep.parse(prefs.getString(_setupStepKey)),
      );
    } catch (_) {
      // Preferences unavailable: behave like a fresh install rather than hang the gate.
      if (ref.mounted) state = const OnboardingPrefs(loaded: true);
    }
  }

  Future<void> markWelcomeSeen() async {
    state = state.copyWith(welcomeSeen: true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_welcomeKey, true);
    } catch (_) {}
  }

  Future<void> setKeySkipped(bool skipped) async {
    state = state.copyWith(keySkipped: skipped);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_skippedKey, skipped);
    } catch (_) {}
  }

  Future<void> setLocalDeclined(bool declined) async {
    if (state.loaded && state.localDeclined == declined) return;
    state = state.copyWith(localDeclined: declined);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_declinedKey, declined);
    } catch (_) {}
  }

  /// Where first run's set-up-while-unpacking stands; null when it is over.
  Future<void> setSetupStep(SetupStep? step) async {
    if (state.loaded && state.setupStep == step) return;
    state = step == null ? state.copyWith(clearSetupStep: true) : state.copyWith(setupStep: step);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (step == null) {
        await prefs.remove(_setupStepKey);
      } else {
        await prefs.setString(_setupStepKey, step.name);
      }
    } catch (_) {}
  }
}

final onboardingPrefsProvider = NotifierProvider<OnboardingPrefsController, OnboardingPrefs>(
  OnboardingPrefsController.new,
);
