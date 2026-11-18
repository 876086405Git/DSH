// One item at a time: why in a line, one key to where it is turned on, a
// check when the person comes back with it on. First run walks everything
// the picked features need; 设置 › 系统权限 walks one item.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/access_state.dart';
import '../../state/android_features.dart';
import '../../state/phone_state.dart';
import '../onboarding/onboarding_scaffold.dart';
import '../phone/phone_disclosure_sheet.dart';
import '../phone/restricted_settings_guide.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'access_text.dart';
import 'access_widgets.dart';

/// ```
///   ▣                               2 / 5
///   打开无障碍
///   手机操控靠它看屏幕、点按
///                                         ← 还没开启 / 在那一页打开了吗？
///   ╭ 先允许受限制的设置 ────────────────╮   only while it stands in the way
///   │ ① 在无障碍里点一下「DSH 手机操控」…  │
///   │ ② 在应用信息里点右上角 ⋮ …          │
///   │ ③ 回到无障碍，打开「DSH 手机操控」    │
///   ╰──────────────────────────────────╯
///   (              去开启              )
///   (     看图示     )(      跳过      )
/// ```
///
/// Coming back to the app reads everything again: an item that is on now
/// shows its check and moves along. A maker's switch can't be read, so after
/// the trip the person says 「设好了」 (shown as 「已去设置」, never as on).
class AccessWalk extends ConsumerStatefulWidget {
  const AccessWalk({
    super.key,
    required this.items,
    required this.onDone,
    this.skipped = const {},
    this.onSkip,
    this.leading,
    this.vendor,
    this.revisit = false,
  });

  /// In walk order; ones already settled are passed over.
  final List<AccessItem> items;

  /// Skipped earlier (first run, before the app went away).
  final Set<AccessItem> skipped;
  final ValueChanged<AccessItem>? onSkip;

  /// Every item is settled or skipped.
  final VoidCallback onDone;

  /// Top-left key (back, when opened from settings).
  final Widget? leading;

  /// The phone's maker, for the names of its switches.
  final String? vendor;

  /// A maker's switch already visited is shown again (opened from its row)
  /// rather than passed over.
  final bool revisit;

  /// How long the check shows before the next item.
  static const doneHold = Duration(milliseconds: 700);

  @override
  ConsumerState<AccessWalk> createState() => _AccessWalkState();
}

class _AccessWalkState extends ConsumerState<AccessWalk> {
  late final AppLifecycleListener _lifecycle;
  late final Set<AccessItem> _skipped = {...widget.skipped};

  AccessItem? _current;

  /// Sent out to a dialog or settings page, not back yet.
  bool _away = false;

  /// Tried once, and how many times.
  final _tries = <AccessItem, int>{};

  /// Came on, or said to be set, during this walk.
  final _finishedItems = <AccessItem>{};

  /// The item that just came on, showing its check.
  AccessItem? _done;
  Timer? _doneTimer;
  bool _finished = false;

  /// 「受限制的设置」 was seen standing in the way during this walk.
  bool _wasRestricted = false;
  bool _appInfoVisited = false;

  AccessDriver get _driver => ref.read(accessDriverProvider);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_onResume()));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _advance();
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _doneTimer?.cancel();
    super.dispose();
  }

  AccessState? _stateOf(AccessItem item, AccessReadings r) =>
      accessStateOf(item, r, ref.read(accessVisitedProvider));

  /// The next item that needs the person, or done.
  void _advance() {
    final r = ref.read(accessReadingsProvider).value;
    if (r == null) return;
    bool open(AccessItem i) => switch (_stateOf(i, r)) {
      null || AccessState.on => false,
      AccessState.visited => widget.revisit,
      AccessState.off || AccessState.unknown => true,
    };
    final next = widget.items
        .where((i) => !_skipped.contains(i) && !_finishedItems.contains(i) && open(i))
        .firstOrNull;
    if (next == null) {
      if (_finished) return;
      _finished = true;
      widget.onDone();
      return;
    }
    if (next != _current) {
      setState(() {
        _current = next;
        _done = null;
      });
    }
  }

  Future<void> _onResume() async {
    final wasAway = _away;
    _away = false;
    final r = await ref.read(accessReadingsProvider.notifier).refresh();
    if (!mounted) return;
    final item = _current;
    if (wasAway && item != null && _stateOf(item, r) == AccessState.on) _celebrate(item);
    setState(() {});
  }

  /// [item] is on: its check, then the next.
  void _celebrate(AccessItem item) {
    if (_done == item) return;
    _finishedItems.add(item);
    setState(() => _done = item);
    _doneTimer?.cancel();
    _doneTimer = Timer(AppMotion.of(context, AccessWalk.doneHold) == Duration.zero ? Duration.zero : AccessWalk.doneHold, () {
      if (mounted) _advance();
    });
  }

  void _toast(String text) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _go(AccessItem item, {bool appInfo = false}) async {
    if (item == AccessItem.accessibility && !ref.read(phoneProvider).disclosureAccepted) {
      // Opened from settings without 手机操控 ever turned on: its disclosure first.
      if (!await showPhoneDisclosure(context) || !mounted) return;
      await ref.read(phoneProvider.notifier).acceptDisclosure();
    }
    final again = (_tries[item] ?? 0) > 0;
    setState(() {
      _away = true;
      _tries[item] = (_tries[item] ?? 0) + 1;
      if (appInfo) _appInfoVisited = true;
    });
    final opened = appInfo ? await _driver.openAppInfo() : await _driver.open(item, again: again);
    if (!mounted) return;
    if (!opened) {
      setState(() => _away = false);
      _toast(context.l10n.accessOpenFailed);
      return;
    }
    // A system dialog answers when the call returns.
    if (item.dialogOn(ref.read(operatingSystemProvider))) await _onResume();
  }

  Future<void> _confirmVendor(AccessItem item) async {
    await ref.read(accessVisitedProvider.notifier).mark(item);
    if (mounted) _celebrate(item);
  }

  void _skip(AccessItem item) {
    _doneTimer?.cancel();
    _skipped.add(item);
    widget.onSkip?.call(item);
    _advance();
  }

  void _push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final readings = ref.watch(accessReadingsProvider).value;
    ref.watch(accessVisitedProvider);
    // Readings that turn the item on (from the trip, or by any other way).
    ref.listen(accessReadingsProvider, (_, next) {
      final r = next.value;
      final item = _current;
      if (r == null || item == null || _away) return;
      if (_stateOf(item, r) == AccessState.on) _celebrate(item);
    });
    final item = _current;
    if (readings == null || item == null) {
      // The first readings came after the first frame: start now.
      if (readings != null && !_finished) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _current == null) _advance();
        });
      }
      return OnboardingScaffold(leading: widget.leading, children: const [SizedBox.shrink()]);
    }
    final state = _stateOf(item, readings);
    final done = _done == item || state == AccessState.on;
    final tries = _tries[item] ?? 0;
    // Once seen in the way, the last of its steps stays shown until the switch is on.
    if (item == AccessItem.accessibility &&
        (readings.restricted == RestrictedSettingsState.guarded ||
            readings.restricted == RestrictedSettingsState.acknowledged)) {
      _wasRestricted = true;
    }
    final counter = widget.items.length > 1
        ? l10n.accessStepCount(widget.items.indexOf(item) + 1, widget.items.length)
        : null;
    final restricted = item == AccessItem.accessibility && !done
        ? restrictedStep(
            state: readings.restricted,
            mayNeed: readings.mayNeedRestricted,
            tried: tries > 0,
            wasRestricted: _wasRestricted,
            appInfoVisited: _appInfoVisited,
          )
        : null;

    // The line under the reason: what came of the last trip.
    final String? status;
    Color? statusColor;
    if (done) {
      status = item.vendor ? l10n.accessStateVisited : l10n.accessIsOn;
      statusColor = theme.colorScheme.primary;
    } else if (item.vendor && tries > 0) {
      status = l10n.accessDidYouSet;
    } else if (tries > 0 && restricted == null && !_away) {
      status = l10n.accessNotOnYet;
      statusColor = colors.warning;
    } else {
      status = null;
    }
    final path = item.path(l10n, vendor: widget.vendor ?? readings.vendor, app: readings.appLabel);

    final (String primary, VoidCallback onPrimary) = switch (item) {
      _ when item.vendor && tries > 0 => (l10n.accessItsSet, () => unawaited(_confirmVendor(item))),
      _ when item.vendor => (l10n.accessOpenSettings, () => unawaited(_go(item))),
      AccessItem.accessibility when restricted == 2 => (l10n.accessOpenAppInfo, () => unawaited(_go(item, appInfo: true))),
      AccessItem.accessibility when restricted != null => (l10n.accessOpenA11y, () => unawaited(_go(item))),
      _ when tries > 0 => (l10n.commonRetry, () => unawaited(_go(item))),
      _ => (l10n.accessTurnOn, () => unawaited(_go(item))),
    };
    final skip = (l10n.accessSkip, () => _skip(item));
    final secondary = <(String, VoidCallback?)>[
      if (item.vendor && tries > 0)
        (l10n.accessOpenAgain, () => unawaited(_go(item)))
      else if (restricted != null)
        (l10n.accessRestrictedHelp, () => _push(const RestrictedSettingsGuidePage()))
      else if (item == AccessItem.overlay && tries > 0 && (readings.sdk ?? 33) >= 33 && !readings.overlayBlocked)
        (l10n.accessOverlayGreyed, () => _push(const RestrictedSettingsGuidePage(target: RestrictedTarget.overlay))),
      skip,
    ];

    final textScaler = MediaQuery.textScalerOf(context);
    return OnboardingScaffold(
      leading: widget.leading,
      children: [
        const Spacer(),
        KeyedSubtree(
          key: ValueKey('access-step-${item.name}'),
          child: AccessHeader(
            icon: item.icon,
            title: item.title(l10n, vendor: widget.vendor ?? readings.vendor),
            message: item.why(l10n, os: ref.read(operatingSystemProvider)),
            counter: counter,
            done: done,
          ),
        ),
        if (path != null) ...[
          const SizedBox(height: 4),
          Text(
            l10n.accessWhere(path),
            key: const ValueKey('access-path'),
            style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
          ),
        ],
        const SizedBox(height: 16),
        // The slot stays when there is nothing to say: no jump when there is.
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: textScaler.scale(14) * 1.5),
          child: AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.standard),
            // In line with the text above it, not centred.
            layoutBuilder: (current, previous) =>
                Stack(alignment: AlignmentDirectional.topStart, children: [...previous, ?current]),
            child: status == null
                ? const SizedBox.shrink()
                : Text(
                    status,
                    key: ValueKey(status),
                    style: theme.textTheme.bodyMedium?.copyWith(color: statusColor),
                  ),
          ),
        ),
        if (restricted != null) ...[
          const SizedBox(height: 12),
          _RestrictedSteps(step: restricted, manufacturer: readings.manufacturer),
        ],
        const Spacer(flex: 2),
        const SizedBox(height: 24),
        AccessActions(primary: primary, onPrimary: onPrimary, secondary: secondary, hidden: done),
      ],
    );
  }
}

/// 「先允许受限制的设置」: three short steps, the one to do now in full
/// colour, those done with a check, the rest quiet.
class _RestrictedSteps extends StatelessWidget {
  const _RestrictedSteps({required this.step, this.manufacturer});

  /// 1-based.
  final int step;
  final String? manufacturer;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    // Xiaomi keeps the option under 「高级设置」, not behind ⋮.
    final advanced = RomFamily.of(manufacturer) == RomFamily.xiaomi;
    final steps = [
      l10n.accessRestrictedTap,
      advanced ? l10n.accessRestrictedAdvanced : l10n.accessRestrictedMenu,
      l10n.accessRestrictedBack,
    ];
    return GlassSurface(
      key: const ValueKey('access-restricted'),
      tier: GlassTier.card,
      borderRadius: AppShape.radiusLg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(header: true, child: Text(l10n.accessRestrictedTitle, style: theme.textTheme.titleSmall)),
            const SizedBox(height: 4),
            for (final (i, text) in steps.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _StepMark(
                      key: ValueKey('access-step-mark-${i + 1}'),
                      index: i + 1,
                      state: i + 1 < step ? _Mark.done : (i + 1 == step ? _Mark.now : _Mark.later),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        text,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: i + 1 == step ? scheme.onSurface : colors.textTertiary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _Mark { done, now, later }

class _StepMark extends StatelessWidget {
  const _StepMark({super.key, required this.index, required this.state});

  final int index;
  final _Mark state;

  static const size = 22.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = state == _Mark.now;
    final fill = now ? scheme.primaryContainer : scheme.onSurface.withValues(alpha: 0.06);
    final ink = now ? scheme.onPrimaryContainer : DshColors.of(context).textTertiary;
    // Optically on the first line of its text.
    return Padding(
      padding: EdgeInsets.only(top: (MediaQuery.textScalerOf(context).scale(14) * 1.5 - size).clamp(0, 8) / 2),
      child: DecoratedBox(
        decoration: ShapeDecoration(color: fill, shape: const CircleBorder()),
        child: SizedBox.square(
          dimension: size,
          child: Center(
            child: state == _Mark.done
                ? Icon(AppIcons.done, size: 14, color: ink)
                : Text('$index', style: AppType.tabular(theme.textTheme.labelMedium!.copyWith(color: ink))),
          ),
        ),
      ),
    );
  }
}
