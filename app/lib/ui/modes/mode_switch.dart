// Switching 模式 (lib/state/app_mode_state.dart): the 模式 sheet, its key in
// the drawer, and opening the startup mode on launch.
//
// 工作 is the home. 伙伴 and 酒馆 are full pages pushed over it, one at a
// time: switching pops back to the home first, so back from a mode always
// lands in 工作.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/app_mode_state.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../companion/companion_page.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../tavern/tavern_home_page.dart';
import '../fx/waves/distortion_wave.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// The page of a mode other than 工作.
Widget appModePage(AppMode mode) => switch (mode) {
  AppMode.companion => const CompanionPage(sections: true),
  AppMode.tavern => const TavernHomePage(),
  AppMode.work => throw ArgumentError.value(mode, 'mode', '工作 is the home, not a page'),
};

const _modeRoutePrefix = 'mode:';

/// Shows [mode]: back to the home, then that mode's page carried in over it on a
/// soft wave of the theme's colour (Libraries.dev Distortion waves).
void openAppMode(BuildContext context, AppMode mode) {
  final navigator = Navigator.of(context);
  final closing = navigator.canPop();
  navigator.popUntil((route) => route.isFirst);
  if (mode == AppMode.work) return;
  // The wave pictures the page under it as it starts: let the sheet and any page leave first.
  final settle = closing ? AppMotion.of(context, AppMotion.emphasized) : Duration.zero;
  unawaited(
    Future<void>.delayed(settle, () {
      if (!navigator.mounted) return;
      unawaited(
        navigator.push(
          DistortionWaveRoute<void>(
            settings: RouteSettings(name: '$_modeRoutePrefix${mode.name}'),
            // Quieter colour fringes than the author's 0.78: the words behind the front stay legible.
            style: DistortionWaveStyle.vertical.copyWith(aberration: 0.35),
            builder: (_) => appModePage(mode),
          ),
        ),
      );
    }),
  );
}

String appModeLabel(L10n l10n, AppMode mode) => switch (mode) {
  AppMode.work => l10n.modeWork,
  AppMode.companion => l10n.companionTitle,
  AppMode.tavern => l10n.tavernTitle,
};

IconData appModeIcon(AppMode mode) => switch (mode) {
  AppMode.work => AppIcons.chat,
  AppMode.companion => AppIcons.pet,
  AppMode.tavern => AppIcons.tavern,
};

/// 模式: the three modes, [current] marked, and which one a launch opens in.
Future<void> showModeSheet(BuildContext context, {required AppMode current}) => showAppSheet<void>(
  context,
  isScrollControlled: true,
  builder: (_) => ModeSheet(current: current, onOpen: (mode) => openAppMode(context, mode)),
);

class ModeSheet extends ConsumerWidget {
  const ModeSheet({super.key, required this.current, required this.onOpen});

  final AppMode current;
  final ValueChanged<AppMode> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final startup = ref.watch(appModeProvider.select((s) => s.startup));
    String subtitle(AppMode mode) => switch (mode) {
      AppMode.work => l10n.modeWorkSubtitle,
      AppMode.companion => l10n.companionEntrySubtitle,
      AppMode.tavern => l10n.modeTavernSubtitle,
    };
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar(l10n.modeSheetTitle),
          SheetGroup(
            margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
            children: [
              for (final mode in AppMode.values)
                Semantics(
                  key: ValueKey('mode-row-${mode.name}'),
                  selected: mode == current,
                  inMutuallyExclusiveGroup: true,
                  child: SettingsTile(
                    icon: appModeIcon(mode),
                    tinted: false,
                    title: appModeLabel(l10n, mode),
                    subtitle: subtitle(mode),
                    onTap: () => mode == current ? Navigator.of(context).pop() : onOpen(mode),
                    trailing: mode == current
                        ? Icon(AppIcons.selected, size: 20, color: scheme.primary)
                        : const SizedBox(width: 20),
                  ),
                ),
            ],
          ),
          SheetGroup(
            margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
            children: [
              SettingsSegmentTile<AppMode>(
                key: const ValueKey('mode-startup'),
                title: l10n.modeStartup,
                tinted: false,
                segments: [for (final mode in AppMode.values) PillSegment(mode, appModeShortLabel(l10n, mode))],
                selected: startup,
                onChanged: (mode) => unawaited(ref.read(appModeProvider.notifier).setStartup(mode)),
              ),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// One word per mode, for the startup switch.
String appModeShortLabel(L10n l10n, AppMode mode) => switch (mode) {
  AppMode.work => l10n.modeWork,
  AppMode.companion => l10n.modeCompanionShort,
  AppMode.tavern => l10n.tavernTitle,
};

/// The drawer's key to 模式, beside 网页模式.
class ModeKey extends StatelessWidget {
  const ModeKey({super.key, this.current = AppMode.work, this.size = 36, this.tier = GlassTier.pill});

  final AppMode current;
  final double size;
  final GlassTier tier;

  @override
  Widget build(BuildContext context) => GlassIconButton(
    key: const ValueKey('mode-key'),
    icon: AppIcons.modes,
    tooltip: context.l10n.modeKeyTooltip,
    size: size,
    tier: tier,
    onPressed: () => unawaited(showModeSheet(context, current: current)),
  );
}

/// Opens the startup mode once per launch, before the home shows: until then
/// it draws the backdrop, so a launch into 酒馆 doesn't flash 工作 first.
class ModeLaunch extends ConsumerStatefulWidget {
  const ModeLaunch({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ModeLaunch> createState() => _ModeLaunchState();
}

/// Set once the startup mode has been opened this launch.
final modeLaunchedProvider = NotifierProvider<_Launched, bool>(_Launched.new);

class _Launched extends Notifier<bool> {
  @override
  bool build() => false;

  void mark() => state = true;
}

class _ModeLaunchState extends ConsumerState<ModeLaunch> {
  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(appModeProvider);
    final launched = ref.watch(modeLaunchedProvider);
    if (launched) return widget.child;
    if (!mode.loaded) return const AppBackdrop(child: SizedBox.expand());
    if (mode.startup == AppMode.work) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(modeLaunchedProvider.notifier).mark());
      return widget.child;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ref.read(modeLaunchedProvider)) return;
      unawaited(
        Navigator.of(context).push(
          _InstantRoute<void>(
            settings: RouteSettings(name: '$_modeRoutePrefix${mode.startup.name}'),
            builder: (_) => appModePage(mode.startup),
          ),
        ),
      );
      ref.read(modeLaunchedProvider.notifier).mark();
    });
    return const AppBackdrop(child: SizedBox.expand());
  }
}

/// Appears at once (the launch), leaves like any page.
class _InstantRoute<T> extends MaterialPageRoute<T> {
  _InstantRoute({required super.builder, super.settings});

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => AppMotion.page;
}
