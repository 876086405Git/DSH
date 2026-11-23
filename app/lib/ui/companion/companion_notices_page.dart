// 她会留意你的通知: the switch, the system grant, and which apps she reads
// (docs/design/companion-notices.md §1.1). The Android listener owns all of it;
// this page only mirrors CompanionNotices and sends changes back.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_notice_channel.dart';
import '../../l10n/l10n.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/overview_card.dart' show OverviewChevron;
import '../common/sheet_title_bar.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// Kinds of apps people most often want her to watch: messages, SMS,
/// calendar, mail, parcels. They lead the list but are never preselected.
const _recommended = [
  'com.tencent.mm',
  'com.tencent.mobileqq',
  'com.tencent.tim',
  'com.google.android.apps.messaging',
  'com.android.mms',
  'com.samsung.android.messaging',
  'com.google.android.calendar',
  'com.android.calendar',
  'com.google.android.gm',
  'com.tencent.androidqqmail',
  'com.netease.mail',
  'com.microsoft.office.outlook',
  'com.cainiao.wireless',
  'com.sf.activity',
];

class CompanionNoticesPage extends ConsumerStatefulWidget {
  const CompanionNoticesPage({super.key});

  @override
  ConsumerState<CompanionNoticesPage> createState() => _CompanionNoticesPageState();
}

class _CompanionNoticesPageState extends ConsumerState<CompanionNoticesPage> {
  late final CompanionNotices _notices = ref.read(companionNoticesProvider);
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<int>? _signals;
  CompanionNoticeStatus? _status;
  List<CompanionNoticeApp> _apps = const [];
  bool _loading = false, _again = false, _busy = false, _failed = false;

  @override
  void initState() {
    super.initState();
    // Back from the system grant page: read what was actually allowed.
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_load()));
    _signals = _notices.signals.listen((_) => unawaited(_load()));
    unawaited(_load());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(_signals?.cancel());
    super.dispose();
  }

  /// One read at a time; a signal arriving meanwhile reads once more after it.
  Future<void> _load() async {
    if (_loading) {
      _again = true;
      return;
    }
    _loading = true;
    try {
      do {
        _again = false;
        final status = await _notices.status();
        final apps = await _notices.recentApps();
        if (!mounted) return;
        setState(() {
          _status = status;
          _apps = apps;
          _failed = false;
        });
      } while (_again && mounted);
    } on Object {
      // The last mirrored state stays; the next resume or signal reads again.
      if (mounted && _status == null) setState(() => _failed = true);
    } finally {
      _loading = false;
    }
  }

  Future<void> _change(Future<CompanionNoticeStatus> Function() change) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final status = await change();
      if (mounted) setState(() => _status = status);
    } on Object {
      if (mounted) showBriefNotice(context, context.l10n.companionNoticesFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load();
  }

  static List<(CompanionNoticeLevel, String, String)> _levels(L10n l10n) => [
    (CompanionNoticeLevel.off, l10n.companionNoticeLevelOff, l10n.companionNoticeLevelOffHint),
    (CompanionNoticeLevel.glance, l10n.companionNoticeLevelGlance, l10n.companionNoticeLevelGlanceHint),
    (CompanionNoticeLevel.remember, l10n.companionNoticeLevelRemember, l10n.companionNoticeLevelRememberHint),
  ];

  void _chooseLevel(String pkg, String name) {
    unawaited(
      showAppSheet<void>(
        context,
        builder: (sheet) {
          final l10n = sheet.l10n;
          final chosen = _status?.level(pkg) ?? CompanionNoticeLevel.off;
          return SafeArea(
            top: false,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SheetTitleBar(name),
                  SheetGroup(
                    margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                    children: [
                      for (final (level, title, hint) in _levels(l10n))
                        SettingsTile(
                          key: ValueKey('notice-level-${level.name}'),
                          tinted: false,
                          title: title,
                          subtitle: hint,
                          chevron: false,
                          trailing: level == chosen ? const Icon(AppIcons.selected, size: 20) : null,
                          onTap: () {
                            Navigator.of(sheet).pop();
                            if (level != chosen) unawaited(_change(() => _notices.setLevel(pkg, level)));
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Recent apps, recommended kinds first, then the busiest; apps she still
  /// reads but that have been quiet for seven days stay at the end, so they
  /// can be turned off.
  List<CompanionNoticeApp> _ordered(CompanionNoticeStatus status) {
    int rank(String pkg) {
      final i = _recommended.indexOf(pkg);
      return i < 0 ? _recommended.length : i;
    }

    final recent = [..._apps]
      ..sort((a, b) {
        final byKind = rank(a.pkg).compareTo(rank(b.pkg));
        return byKind != 0 ? byKind : b.count.compareTo(a.count);
      });
    final listed = {for (final app in recent) app.pkg};
    return [
      ...recent,
      for (final MapEntry(key: pkg, value: level) in status.levels.entries)
        if (level != CompanionNoticeLevel.off && !listed.contains(pkg)) (pkg: pkg, name: pkg, count: 0, icon: null),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = _status;
    if (status == null) {
      return AppPage.list(
        title: l10n.companionNotices,
        children: [
          if (_failed)
            SettingsSection(
              children: [
                SettingsTile(icon: AppIcons.error, title: l10n.companionNoticesFailed, onTap: () => unawaited(_load())),
              ],
            ),
        ],
      );
    }
    final needsGrant = status.enabled && !status.granted;
    final apps = _ordered(status);
    final levels = {for (final (level, title, _) in _levels(l10n)) level: title};
    return AppPage.list(
      title: l10n.companionNotices,
      children: [
        SettingsSection(
          footer: status.enabled && status.granted && (status.received > 0 || status.said > 0)
              ? Text(l10n.companionNoticesToday(status.received, status.said))
              : null,
          children: [
            SettingsSwitchTile(
              key: const ValueKey('notices-switch'),
              tinted: false,
              title: l10n.companionNotices,
              subtitle: needsGrant ? l10n.companionNoticesNeedsAccess : l10n.companionNoticesHint,
              value: status.enabled,
              onChanged: _busy ? null : (on) => unawaited(_change(() => _notices.setEnabled(on))),
            ),
            if (needsGrant)
              SettingsTile(
                key: const ValueKey('notices-allow'),
                tinted: false,
                title: l10n.companionNoticesAllow,
                // Asking to turn on again opens the system page while the grant is missing.
                onTap: _busy ? null : () => unawaited(_change(() => _notices.setEnabled(true))),
              ),
          ],
        ),
        SettingsSection(
          title: l10n.companionNoticesApps,
          footer: Text(l10n.companionNoticesFooter),
          children: [
            if (apps.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 16, SettingsMetrics.inset, 16),
                child: Text(
                  l10n.companionNoticesAppsEmpty,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
                ),
              ),
            for (final app in apps)
              _AppRow(
                key: ValueKey('notice-app-${app.pkg}'),
                app: app,
                subtitle: app.count > 0 ? l10n.companionNoticesAppCount(app.count) : l10n.companionNoticesQuiet,
                level: levels[status.level(app.pkg)]!,
                onTap: _busy ? null : () => _chooseLevel(app.pkg, app.name),
              ),
          ],
        ),
      ],
    );
  }
}

/// A settings row led by the app's own icon (or its first letter) in a small
/// rounded square, in place of a line glyph.
class _AppRow extends StatelessWidget {
  const _AppRow({super.key, required this.app, required this.subtitle, required this.level, required this.onTap});

  final CompanionNoticeApp app;
  final String subtitle, level;
  final VoidCallback? onTap;

  static const _radius = BorderRadius.all(Radius.circular(8));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final initial = app.name.trim().isEmpty ? '?' : String.fromCharCode(app.name.trim().runes.first).toUpperCase();
    final icon = switch (app.icon) {
      final bytes? => ClipRRect(
        borderRadius: _radius,
        child: Image.memory(
          bytes,
          width: SettingsMetrics.icon,
          height: SettingsMetrics.icon,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _Initial(initial),
        ),
      ),
      null => _Initial(initial),
    };
    return InkWell(
      onTap: onTap,
      splashFactory: rowSplash(context),
      highlightColor: scheme.onSurface.withValues(alpha: 0.05),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: SettingsMetrics.rowHeightTwoLine),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 6, SettingsMetrics.trailingPad, 6),
          child: Row(
            children: [
              icon,
              const SizedBox(width: SettingsMetrics.iconGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      app.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: settingsTitleStyle(context)?.copyWith(color: scheme.onSurface),
                    ),
                    const SizedBox(height: 1),
                    Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(level, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(width: 4),
              const OverviewChevron(),
            ],
          ),
        ),
      ),
    );
  }
}

class _Initial extends StatelessWidget {
  const _Initial(this.letter);

  final String letter;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: _AppRow._radius),
      child: SizedBox.square(
        dimension: SettingsMetrics.icon,
        child: Center(
          child: Text(letter, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      ),
    );
  }
}
