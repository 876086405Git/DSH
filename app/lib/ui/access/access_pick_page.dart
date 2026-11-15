// First run, 「想让 DSH Go 帮你做哪些事」: what DSH Go should do, by feature
// (docs: lib/state/access_state.dart). Nothing is picked to begin with; 跳过
// leaves everything as it is.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/access_state.dart';
import '../../state/android_features.dart';
import '../../state/phone_state.dart';
import '../common/risk_notice.dart';
import '../onboarding/onboarding_scaffold.dart';
import '../phone/phone_disclosure_sheet.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'access_widgets.dart';
import 'phone_mode_sheet.dart';

/// ```
///   ▣  想让 DSH Go 帮你做哪些事
///      选好后逐项开启
///   ╭──────────────────────────────────╮
///   │ ▢ 读写手机里的文件            ☐  │
///   │   需要文件访问权限                │
///   │ ▢ 桌宠与悬浮窗               ☐  │
///   │ ▢ 手机操控                   ☐  │
///   │ ▢ 后台持续运行               ☐  │
///   │ ▢ 语音输入                   ☐  │
///   │   需要麦克风权限                  │
///   │   离线识别，需下载约 241 MB 语音模型 │
///   ╰──────────────────────────────────╯
///   (             开启所选             )
///                 跳过
/// ```
///
/// Picking 手机操控 shows its disclosure and then asks how it confirms
/// (关键步骤先问我 / 全程自动), and 读写手机里的文件 what AI may then do, right
/// there, the way their switches in settings do; declining either leaves the
/// box empty. HarmonyOS lists fewer ([accessFeaturesFor]), and its voice input
/// has nothing to download.
class AccessPickPage extends ConsumerStatefulWidget {
  const AccessPickPage({super.key, required this.onPicked, required this.onSkip});

  /// The features, and 手机操控's 确认方式 when it is among them.
  final void Function(Set<AccessFeature> features, PhoneConfirmMode? phoneMode) onPicked;
  final VoidCallback onSkip;

  @override
  ConsumerState<AccessPickPage> createState() => _AccessPickPageState();
}

class _AccessPickPageState extends ConsumerState<AccessPickPage> {
  final _picked = <AccessFeature>{};
  bool _asking = false;

  /// 手机操控's 确认方式, chosen right after its disclosure.
  PhoneConfirmMode? _phoneMode;

  Future<void> _toggle(AccessFeature feature) async {
    if (_asking) return;
    if (_picked.contains(feature)) {
      if (feature == AccessFeature.phone) _phoneMode = null;
      return setState(() => _picked.remove(feature));
    }
    _asking = true;
    try {
      final bool ok;
      if (feature == AccessFeature.phone) {
        ok = await _phoneDisclosure() && await _chooseMode();
      } else if (feature == AccessFeature.files) {
        ok = await confirmRisk(context, RiskNotices.phoneFilesFirstRun);
      } else {
        ok = true;
      }
      if (ok && mounted) setState(() => _picked.add(feature));
    } finally {
      _asking = false;
    }
  }

  Future<bool> _phoneDisclosure() async {
    if (ref.read(phoneProvider).disclosureAccepted) return true;
    if (!await showPhoneDisclosure(context)) return false;
    await ref.read(phoneProvider.notifier).acceptDisclosure();
    return true;
  }

  /// 关键步骤先问我 / 全程自动, every time 手机操控 is picked: closed without
  /// one, the box stays empty.
  Future<bool> _chooseMode() async {
    if (!mounted) return false;
    final mode = await showPhoneModeSheet(context);
    if (mode == null) return false;
    _phoneMode = mode;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final metered = ref.watch(accessReadingsProvider.select((r) => r.value?.metered == true));
    final os = ref.watch(operatingSystemProvider);
    return OnboardingScaffold(
      children: [
        const Spacer(),
        OnboardingHeader(icon: AppIcons.systemAccess, title: l10n.accessPickTitle, message: l10n.accessPickMessage),
        const SizedBox(height: 28),
        SettingsSection(
          key: const ValueKey('access-pick-card'),
          margin: EdgeInsets.zero,
          children: [
            for (final feature in accessFeaturesFor(os))
              AccessFeatureRow(
                feature: feature,
                selected: _picked.contains(feature),
                onTap: () => unawaited(_toggle(feature)),
                lines: feature == AccessFeature.voice && accessVoiceDownloads(os)
                    ? [
                        (text: l10n.accessFeatureVoiceNeeds, color: null),
                        (text: l10n.accessVoiceModel(voiceModelApproxMb), color: null),
                        if (metered) (text: l10n.accessVoiceMetered, color: colors.warning),
                      ]
                    : const [],
              ),
          ],
        ),
        const Spacer(flex: 2),
        const SizedBox(height: 24),
        AccessActions(
          primary: l10n.accessPickConfirm,
          onPrimary: _picked.isEmpty
              ? null
              : () => widget.onPicked({..._picked}, _picked.contains(AccessFeature.phone) ? _phoneMode : null),
          secondary: [(l10n.accessSkip, widget.onSkip)],
        ),
      ],
    );
  }
}
