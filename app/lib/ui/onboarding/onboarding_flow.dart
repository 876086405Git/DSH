import 'package:flutter/material.dart';

import 'access_step.dart';
import 'appearance_step.dart';
import 'connect_page.dart';
import 'onboarding_scaffold.dart';
import 'runtime_setup_page.dart';
import 'welcome_page.dart';

/// First-run pages. [apiKey] is the "connect DeepSeek" step: account sign-in
/// first, API key as the alternative.
///
/// On this phone, first run sets up while the runtime unpacks
/// (docs/design/onboarding-parallel-setup.md): [runtime] asks where DSH runs,
/// [appearance], [access] (what DSH Go should do, and the permissions for it)
/// and [apiKey] follow while it unpacks, and [finishing] waits for whatever
/// is left of it. Upgrades, resets and a phone that only needs a key go
/// [runtime] (the unpack itself) → [apiKey].
enum OnboardingStep { welcome, runtime, appearance, access, apiKey, finishing }

/// Moves between the first-run pages. The step itself is owned by the root
/// gate, which also decides where a returning user resumes.
///
/// The welcome and finishing pages stand alone; the steps between show a thin
/// step bar at the top ([OnboardingProgress]) and, beside an unpack, its
/// capsule at the bottom.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({
    super.key,
    required this.step,
    required this.onWelcomeDone,
    required this.onRuntimeDone,
    required this.onKeyDone,
    this.chooseRuntime = false,
    this.onRemote,
    this.onLocal,
    this.onAppearanceDone,
    this.onAccessDone,
    this.onFinished,
    this.beside = false,
  });

  final OnboardingStep step;
  final VoidCallback onWelcomeDone;
  final VoidCallback onRuntimeDone;
  final VoidCallback onKeyDone;

  /// The runtime step asks first: this phone or a remote host
  /// ([RuntimeSetupPage.choose]); false installs (resume, upgrade, reset).
  final bool chooseRuntime;

  /// Picked 「远程主机」 (or gave up on a failed install for one).
  final VoidCallback? onRemote;

  /// Picked 「本机」: the caller starts the unpack and moves on to
  /// [OnboardingStep.appearance]. Null: the runtime page installs itself.
  final VoidCallback? onLocal;

  final VoidCallback? onAppearanceDone;

  /// Past 想让 DSH Go 帮你做哪些事 (picked and walked, or skipped).
  final VoidCallback? onAccessDone;

  /// The unpack [OnboardingStep.finishing] waited for is done.
  final VoidCallback? onFinished;

  /// The steps run beside an unpack (first run on this phone).
  final bool beside;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  late DateTime _since = DateTime.now();

  @override
  void didUpdateWidget(OnboardingFlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.step != widget.step) _since = DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.step;
    final Widget page = switch (step) {
      OnboardingStep.welcome => WelcomePage(onStart: widget.onWelcomeDone),
      OnboardingStep.runtime => RuntimeSetupPage(
        onDone: widget.onRuntimeDone,
        choose: widget.chooseRuntime,
        onRemote: widget.onRemote,
        onLocal: widget.onLocal,
      ),
      OnboardingStep.appearance => AppearanceStepPage(onDone: widget.onAppearanceDone ?? () {}),
      OnboardingStep.access => AccessStepPage(onDone: widget.onAccessDone ?? () {}),
      OnboardingStep.apiKey => ConnectPage(onDone: widget.onKeyDone),
      OnboardingStep.finishing => RuntimeSetupPage(
        onDone: widget.onFinished ?? widget.onRuntimeDone,
        waiting: true,
        onRemote: widget.onRemote,
      ),
    };
    // The step bar counts the questions: where DSH runs, then (on this
    // phone, first run) the look and what DSH Go should do, then the
    // connection.
    final steps = widget.chooseRuntime || widget.beside
        ? const [
            OnboardingStep.runtime,
            OnboardingStep.appearance,
            OnboardingStep.access,
            OnboardingStep.apiKey,
          ]
        : const [OnboardingStep.runtime, OnboardingStep.apiKey];
    final index = steps.indexOf(step);
    return OnboardingSwitcher(
      child: KeyedSubtree(
        key: ValueKey(step),
        child: index < 0
            ? page
            : OnboardingProgress(
                step: index + 1,
                steps: steps.length,
                since: _since,
                runtime: widget.beside && step != OnboardingStep.runtime,
                onRemote: widget.onRemote,
                child: page,
              ),
      ),
    );
  }
}
