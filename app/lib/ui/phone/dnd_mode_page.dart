import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../state/phone_state.dart';
import '../common/app_dialog.dart';
import '../common/brief_notice.dart';
import '../common/expand_reveal.dart';
import '../common/list_page_row.dart';
import '../common/risk_notice.dart';
import '../common/row_marks.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'phone_widgets.dart';
import 'background_preview.dart';
import 'restricted_settings_guide.dart' show RomFamily;

/// Shizuku's own download page (official site).
const shizukuDownloadUrl = 'https://shizuku.rikka.app/download/';

extension PhoneChannelLabel on PhonePrivilegedMode {
  /// What 不打扰模式 calls this channel.
  String label(L10n l10n) => switch (this) {
    PhonePrivilegedMode.off => l10n.phoneDisabled,
    PhonePrivilegedMode.shizuku => 'Shizuku',
    PhonePrivilegedMode.sui => l10n.phonePrivilegedSui,
    PhonePrivilegedMode.root => l10n.phonePrivilegedRoot,
    PhonePrivilegedMode.adb => l10n.phoneDndDirectAdb,
  };
}

/// One-line state of 不打扰模式 for the row on the main page.
String dndSummary(PhoneBackgroundStatus bg) {
  final l10n = appL10n;
  if (!bg.androidOk) return l10n.phoneDndRequiresAndroid;
  final channel = bg.effectiveMode.label(l10n);
  return switch (bg.effectiveMode) {
    PhonePrivilegedMode.off => l10n.phoneDndHiddenScreen,
    _ when bg.effectiveReady => l10n.phoneDndChannelReady(channel),
    _ => l10n.phoneDndChannelStatus(channel, bg.effectiveReason ?? l10n.phoneNotReadyYet),
  };
}

/// The page's rhythm: 24 before a section (its titled card, or a fold of its
/// own), 12 between the untitled cards of one section, 8 between the status
/// card and the notes under it.
const _sectionGap = SizedBox(height: 24);
const _cardGap = SizedBox(height: 12);
const _noteGap = SizedBox(height: 8);

/// Notes line up with the cards; the gaps above set the space between them.
const _noteMargin = EdgeInsets.symmetric(horizontal: 16);

/// [items] with [gap] between them.
List<Widget> _spaced(List<Widget> items, Widget gap) => [
  for (final (i, item) in items.indexed) ...[if (i > 0) gap, item],
];

/// Root and Sui: under 更多连接方式, folded until asked for.
bool _rare(PhonePrivilegedMode mode) => mode == PhonePrivilegedMode.root || mode == PhonePrivilegedMode.sui;

/// The Shizuku app (or a binder it serves), not Sui speaking its interface.
bool _shizukuInstalled(ShizukuStatus s) => s.provider == 'shizuku' || (s.appInstalled ?? s.installed);

/// 不打扰模式: Agent works on a virtual display through a privileged channel —
/// Shizuku, Sui, root or the app's own wireless-debugging connection — that
/// the person picks here. Advanced, off by default; the page says plainly what
/// each channel needs and why one isn't working.
///
/// A row unfolds its channel; only the button inside picks it. Nothing here
/// picks, authorizes, keeps or runs su on its own: not opening the page, not a
/// status refresh, not the suggestion.
class PhoneDndPage extends ConsumerStatefulWidget {
  const PhoneDndPage({super.key});

  @override
  ConsumerState<PhoneDndPage> createState() => _PhoneDndPageState();
}

class _PhoneDndPageState extends ConsumerState<PhoneDndPage> {
  /// The channel unfolded under its row: null until a row is tapped (till then
  /// the one in use unfolds while it isn't ready), off for none.
  PhonePrivilegedMode? _open;
  bool _busy = false;
  bool _previewOpen = false;
  String? _error;
  late final AppLifecycleListener _lifecycle;

  PhoneController get _phone => ref.read(phoneProvider.notifier);
  bool get _ready => ref.read(phoneProvider).status.ready;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_phone.refreshStatus()));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<bool> _run(Future<PhoneResult> Function() action, {String? done}) async {
    if (!_ready || _busy) return false;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await action();
    if (!mounted) return false;
    setState(() {
      _busy = false;
      _error = result.ok ? null : (result.reason ?? context.l10n.phoneActionFailedLater);
    });
    if (result.ok && done != null) showBriefNotice(context, done);
    return result.ok;
  }

  /// The explicit choice. Root still requires its risk notice and the manager prompt.
  Future<void> _use(PhonePrivilegedMode mode) async {
    if (!_ready) return;
    if (mode == PhonePrivilegedMode.root && !await confirmRisk(context, RiskNotices.rootChannel)) return;
    if (!mounted) return;
    // Folded back once it works: the row says 使用中.
    if (await _run(() => _phone.setPrivilegedMode(mode), done: context.l10n.phoneDndEnabled) && mounted) {
      setState(() => _open = null);
    }
  }

  /// Not held back by a choice still pending: turning off is how a root
  /// prompt left unanswered is cancelled.
  Future<void> _close() async {
    if (!_ready) return;
    final l10n = context.l10n;
    final result = await _phone.setPrivilegedMode(PhonePrivilegedMode.off);
    if (!mounted) return;
    if (result.ok) {
      showBriefNotice(context, l10n.phoneDndDisabled);
    } else {
      setState(() => _error = result.reason ?? l10n.phoneActionFailedLater);
    }
  }

  /// Shizuku's or Sui's own permission dialog.
  Future<void> _authorize(PhonePrivilegedMode mode) async {
    if (!_ready || _busy) return;
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await _phone.requestPrivilegedPermission(mode);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      setState(
        () => _error = mode == PhonePrivilegedMode.sui
            ? l10n.phoneDndSuiPermissionFailed
            : l10n.phoneDndShizukuPermissionFailed,
      );
    }
  }

  Future<void> _openShizukuSite() async {
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(shizukuDownloadUrl), mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!ok && mounted) {
      _toast(context.l10n.phoneDndBrowserFailed(shizukuDownloadUrl));
    }
  }

  Future<void> _manualPair() async {
    final l10n = context.l10n;
    final entered = await showAppDialog<(String, int?)>(context: context, builder: (_) => const _PairDialog());
    if (entered == null) return;
    await _run(() => _phone.adbPair(entered.$1, port: entered.$2), done: l10n.phoneDndPairedConnect);
  }

  Future<void> _manualConnect() async {
    final l10n = context.l10n;
    final port = await showAppDialog<int>(context: context, builder: (_) => const _ConnectDialog());
    if (port == null || !mounted) return;
    await _run(() => _phone.adbConnect(port: port), done: l10n.phoneDndConnected);
  }

  bool _hasSlotMetadata(PhoneStatus status) =>
      status.background.parallelism != null ||
      status.task.backgroundSlot != null ||
      status.tasks.any((task) => task.backgroundSlot != null);

  Iterable<PhoneTaskStatus> _previewTasks(PhoneStatus status) {
    final modern = _hasSlotMetadata(status);
    return (modern ? status.tasks : [status.task]).where(
      (task) => task.active && task.id != null && task.id! > 0 && (!modern || task.backgroundSlot == true),
    );
  }

  Future<void> _showPreview(int taskId) async {
    final status = ref.read(phoneProvider).status;
    if (_previewOpen ||
        !status.ready ||
        !status.background.previewEnabled ||
        !_previewTasks(status).any((task) => task.id == taskId)) {
      return;
    }
    _previewOpen = true;
    try {
      await showAppDialog<void>(
        context: context,
        builder: (_) => Consumer(
          builder: (_, ref, _) => PhoneBackgroundPreviewDialog(
            channel: ref.read(phoneChannelProvider),
            taskId: taskId,
            enabled: ref.watch(phoneProvider.select((s) => s.status.ready)),
          ),
        ),
      );
    } finally {
      _previewOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = ref.watch(phoneProvider.select((s) => s.status));
    final bg = status.background;
    final hasSlotMetadata = _hasSlotMetadata(status);
    final previewTasks = _previewTasks(status);
    final using = bg.effectiveMode;
    final waiting = using == PhonePrivilegedMode.root && bg.root.starting;
    final open = _open ?? (bg.effectiveReady ? PhonePrivilegedMode.off : using);
    final others = [
      for (final mode in bg.supportedModes)
        if (mode != PhonePrivilegedMode.off && mode != using) mode,
    ];
    final common = others.where((mode) => !_rare(mode)).toList();
    final more = others.where(_rare).toList();
    // The channels not in use, in one card; Root and Sui fold in as its last rows.
    final choices = common.isEmpty && more.isEmpty
        ? null
        : ListPageCard(
            title: using == PhonePrivilegedMode.off ? l10n.phoneDndChannels : null,
            children: [
              for (final mode in common) ..._channel(mode, bg, open),
              if (more.isNotEmpty) ...[
                if (common.isNotEmpty) const Divider(indent: 16, endIndent: 16),
                PhoneOptionsFold(
                  key: const ValueKey('phone-dnd-more-channels'),
                  title: l10n.phoneDndMoreChannels,
                  card: false,
                  children: [for (final mode in more) ..._channel(mode, bg, open)],
                ),
              ],
            ],
          );

    // What is in use and what is wrong: first, and never folded away.
    final head = <Widget>[
      if (!bg.androidOk) PhoneNote(tone: NoteTone.warn, text: l10n.phoneDndUnsupported, margin: _noteMargin),
      if (using != PhonePrivilegedMode.off) ...[
        ListPageCard(
          children: [
            ListPageRow(
              icon: AppIcons.dndMode,
              iconColor: Theme.of(context).colorScheme.primary,
              title: l10n.phoneDndUsing(using.label(l10n)),
              titleMaxLines: 2,
              subtitle: bg.effectiveReady ? l10n.phoneReady : (waiting ? bg.effectiveReason : null),
              trailing: TextButton(onPressed: _ready ? _close : null, child: Text(l10n.commonClose)),
            ),
            if (bg.previewVersion == 1) ...[
              ListPageRow(
                leading: const SizedBox(),
                title: l10n.phonePreviewTitle,
                subtitle: l10n.phonePreviewDescription,
                subtitleMaxLines: 4,
                trailing: Switch(
                  value: bg.previewEnabled,
                  onChanged: !_ready || _busy
                      ? null
                      : (enabled) =>
                            unawaited(_run(() async => PhoneResult(await _phone.setBackgroundPreview(enabled)))),
                ),
              ),
              if (bg.previewEnabled)
                for (final candidate in previewTasks)
                  ListPageRow(
                    key: ValueKey('phone-preview-task-${candidate.id}'),
                    leading: const SizedBox(),
                    title: !hasSlotMetadata ? l10n.phonePreviewOpen : l10n.phonePreviewTask(candidate.id!.toString()),
                    subtitle: candidate.app,
                    onTap: _ready ? () => unawaited(_showPreview(candidate.id!)) : null,
                  ),
            ],
          ],
        ),
        // The channel's own reason, whole: a failure never quietly becomes another channel.
        if (!bg.effectiveReady && !waiting)
          PhoneNote(tone: NoteTone.warn, text: bg.effectiveReason ?? l10n.phoneNotReadyYet, margin: _noteMargin),
      ],
      if (_error case final error? when error != bg.effectiveReason)
        PhoneNote(tone: NoteTone.warn, text: error, margin: _noteMargin),
      if (bg.keep.enabled && _keepStatus(bg.keep).$1 != null)
        PhoneNote(
          tone: bg.keep.phase == PhoneKeepPhase.failed ? NoteTone.warn : NoteTone.info,
          text: _keepStatus(bg.keep).$1!,
          margin: _noteMargin,
        ),
    ];

    // 连接方式: the channel in use with the others folded under 更换连接方式, or the choices themselves.
    final connection = <Widget>[
      if (using != PhonePrivilegedMode.off) ...[
        ListPageCard(title: l10n.phoneDndChannels, children: _channel(using, bg, open)),
        _cardGap,
        PhoneOptionsFold(
          key: const ValueKey('phone-dnd-channels'),
          title: l10n.phoneDndChangeChannel,
          children: [
            if (choices != null) ...[_cardGap, choices],
          ],
        ),
      ] else
        ?choices,
    ];

    // 更多设置: each group a card of its own, 24 apart where a title leads it.
    final options = <ListPageCard>[
      if (using != PhonePrivilegedMode.off && bg.privileged != null) ListPageCard(children: [_keepRow(using, bg.keep)]),
      if (bg.parallelism case final capacity? when status.ready)
        ListPageCard(
          title: l10n.phoneBackgroundParallelTitle,
          children: [
            ListPageRow(
              title: l10n.phoneBackgroundParallelStatus(
                capacity.configuredLimit,
                capacity.effectiveLimit,
                capacity.heldSlots,
              ),
              titleMaxLines: 4,
              subtitle: switch (capacity.reason) {
                'off' => l10n.phoneBackgroundParallelOff,
                'unsupported' => l10n.phoneBackgroundParallelUnsupported,
                'connectionRequired' => l10n.phoneBackgroundParallelConnection,
                'busy' => l10n.phoneBackgroundParallelBusy,
                'transportSerial' => l10n.phoneBackgroundParallelSerial,
                _ => l10n.phoneBackgroundParallelDescription,
              },
              subtitleMaxLines: 5,
            ),
            for (final limit in const [1, 2, 3])
              Semantics(
                selected: capacity.configuredLimit == limit,
                inMutuallyExclusiveGroup: true,
                child: ListPageRow(
                  key: ValueKey('phone-background-limit-$limit'),
                  leading: Icon(capacity.configuredLimit == limit ? AppIcons.radioOn : AppIcons.radioOff),
                  title: l10n.phoneBackgroundParallelChoice(limit),
                  onTap: !_ready || _busy || capacity.configuredLimit == limit
                      ? null
                      : () => unawaited(_run(() => _phone.setBackgroundParallelLimit(limit))),
                ),
              ),
          ],
        ),
      if (bg.viewport case final viewport? when bg.androidOk)
        ListPageCard(
          title: l10n.phoneViewportTitle,
          children: [
            ListPageRow(leading: const SizedBox(), title: l10n.phoneViewportDescription, titleMaxLines: 10),
            for (final preset in PhoneBackgroundViewport.values)
              Semantics(
                selected: viewport == preset,
                inMutuallyExclusiveGroup: true,
                child: ListPageRow(
                  key: ValueKey('phone-viewport-${preset.name}'),
                  leading: Icon(viewport == preset ? AppIcons.radioOn : AppIcons.radioOff),
                  title: preset == PhoneBackgroundViewport.portrait
                      ? l10n.phoneViewportPortrait
                      : l10n.phoneViewportLandscape,
                  onTap: !_ready || _busy || viewport == preset
                      ? null
                      : () => unawaited(_run(() => _phone.setBackgroundViewport(preset))),
                ),
              ),
          ],
        ),
      ListPageCard(
        title: l10n.phoneDndRequirements,
        children: [
          BulletLines([
            l10n.phoneDndKeepUnlocked,
            if (!bg.keep.enabled) l10n.phoneDndReactivate,
            if (using == PhonePrivilegedMode.off ||
                using == PhonePrivilegedMode.shizuku ||
                using == PhonePrivilegedMode.adb)
              l10n.phoneDndKeepDebugging,
          ]),
        ],
      ),
    ];

    return AppPage.list(
      title: l10n.phoneDndTitle,
      subtitle: Text(l10n.phoneDndSubtitle),
      children: [
        ..._spaced(head, _noteGap),
        if (head.isNotEmpty && connection.isNotEmpty) _sectionGap,
        ...connection,
        if (head.isNotEmpty || connection.isNotEmpty) _sectionGap,
        PhoneOptionsFold(
          key: const ValueKey('phone-dnd-options'),
          title: l10n.phoneControlAdvanced,
          children: [
            for (final (i, group) in options.indexed) ...[
              if (i == 0 || group.title == null) _cardGap else _sectionGap,
              group,
            ],
          ],
        ),
      ],
    );
  }

  /// 保持 for the channel in use, off until the person turns it on: this
  /// switch is the only thing that writes it. Consent stays here; reconnect
  /// progress and failures stay visible outside the fold.
  Widget _keepRow(PhonePrivilegedMode mode, PhonePrivilegedKeepStatus keep) {
    final l10n = context.l10n;
    void toggle(bool on) => unawaited(_run(() => _phone.setBackgroundKeep(mode, on)));
    return MergeSemantics(
      child: ListPageRow(
        leading: const SizedBox(),
        title: l10n.phoneKeepTitle(mode.name),
        titleMaxLines: 2,
        subtitle: switch (mode) {
          PhonePrivilegedMode.root => l10n.phoneKeepRootDescription,
          PhonePrivilegedMode.adb => l10n.phoneKeepAdbDescription,
          _ => l10n.phoneKeepSharedDescription,
        },
        // What keeping means is the consent: never cut short.
        subtitleMaxLines: 8,
        onTap: !_ready || _busy ? null : () => toggle(!keep.enabled),
        trailing: Switch(value: keep.enabled, onChanged: !_ready || _busy ? null : toggle),
      ),
    );
  }

  /// Native's own fixed reason codes; anything else is plain waiting.
  (String?, Color?) _keepStatus(PhonePrivilegedKeepStatus keep) {
    final l10n = context.l10n;
    final accent = Theme.of(context).colorScheme.primary;
    return switch (keep.phase) {
      PhoneKeepPhase.restoring => (l10n.phoneKeepRestoring, accent),
      PhoneKeepPhase.waiting => (
        switch (keep.reasonCode) {
          'serviceUnavailable' || 'providerChanged' => l10n.phoneKeepWaitingService,
          'permissionRequired' => l10n.phoneKeepWaitingPermission,
          'networkUnavailable' => l10n.phoneKeepWaitingNetwork,
          'notPaired' => l10n.phoneKeepNotPaired,
          _ => l10n.phoneKeepWaiting,
        },
        accent,
      ),
      PhoneKeepPhase.failed => (l10n.phoneKeepFailed, DshColors.of(context).warning),
      _ => (null, null),
    };
  }

  List<Widget> _channel(PhonePrivilegedMode mode, PhoneBackgroundStatus bg, PhonePrivilegedMode open) => [
    _row(mode, bg, open: open == mode),
    ExpandReveal(
      open: open == mode,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _panel(mode, bg)),
    ),
  ];

  Widget _row(PhonePrivilegedMode mode, PhoneBackgroundStatus bg, {required bool open}) {
    final l10n = context.l10n;
    final (state, color) = _state(mode, bg);
    return Semantics(
      expanded: open,
      child: ListPageRow(
        title: mode.label(l10n),
        subtitle: !open
            ? null
            : switch (mode) {
                PhonePrivilegedMode.off => null,
                PhonePrivilegedMode.shizuku => l10n.phoneDndShizukuFor,
                PhonePrivilegedMode.sui => l10n.phoneDndSuiFor,
                PhonePrivilegedMode.root => l10n.phoneDndRootFor,
                PhonePrivilegedMode.adb => l10n.phoneDndAdbFor,
              },
        subtitleMaxLines: 2,
        meta: open ? state : null,
        metaColor: color,
        trailing: RowExpandArrow(open: open),
        onTap: () => setState(() {
          _open = open ? PhonePrivilegedMode.off : mode;
        }),
      ),
    );
  }

  /// A channel's state word: the accent for the one in use, green for one that
  /// would work now, quiet otherwise. Root not tried yet is 尚未检查, never a
  /// failure: su only runs once it is picked.
  (String, Color) _state(PhonePrivilegedMode mode, PhoneBackgroundStatus bg) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final quiet = colors.textTertiary;
    final waiting = (l10n.phoneDndStateWaiting, accent);
    if (mode == bg.effectiveMode) {
      if (bg.effectiveReady) return (l10n.phoneDndStateInUse, accent);
      if (mode == PhonePrivilegedMode.root && bg.root.starting) return waiting;
      return (l10n.phoneDndStateNotReady, colors.warning);
    }
    final shared = bg.shizuku;
    return switch (mode) {
      PhonePrivilegedMode.off => (l10n.phoneDisabled, quiet),
      PhonePrivilegedMode.shizuku when shared.provider == 'sui' => (l10n.phoneDndStateViaSui, quiet),
      PhonePrivilegedMode.shizuku when !_shizukuInstalled(shared) => (l10n.phoneDndStateNotInstalled, quiet),
      PhonePrivilegedMode.sui when shared.provider != 'sui' => (l10n.phoneDndStateNotFound, quiet),
      PhonePrivilegedMode.shizuku ||
      PhonePrivilegedMode.sui when !shared.running => (l10n.phoneDndStateNotRunning, quiet),
      PhonePrivilegedMode.shizuku ||
      PhonePrivilegedMode.sui when !shared.granted => (l10n.phoneDndStateNeedsGrant, quiet),
      PhonePrivilegedMode.shizuku || PhonePrivilegedMode.sui => (l10n.phoneDndStateUsable, colors.success),
      PhonePrivilegedMode.root => switch (bg.root) {
        PhoneRootStatus(connected: true) => (l10n.phoneDndConnected, colors.success),
        PhoneRootStatus(starting: true) => waiting,
        PhoneRootStatus(checked: false) => (l10n.phonePrivilegedRootUnchecked, quiet),
        _ => (l10n.phoneDndStateDisconnected, quiet),
      },
      PhonePrivilegedMode.adb => switch (bg.adb) {
        AdbStatus(connected: true) => (l10n.phoneDndConnected, colors.success),
        AdbStatus(paired: true) => (l10n.phoneDndPaired, quiet),
        _ => (l10n.phoneDndStateNotPaired, quiet),
      },
    };
  }

  List<Widget> _panel(PhonePrivilegedMode mode, PhoneBackgroundStatus bg) => switch (mode) {
    PhonePrivilegedMode.off => const [],
    PhonePrivilegedMode.shizuku => _shizuku(bg),
    PhonePrivilegedMode.sui => _sui(bg),
    PhonePrivilegedMode.root => _root(bg),
    PhonePrivilegedMode.adb => _adb(bg),
  };

  /// 用 X 开启, or 改用 X while another channel is in use (worded per channel:
  /// 自连 ADB takes no space after 用).
  Widget _useButton(PhonePrivilegedMode mode, PhoneBackgroundStatus bg) {
    final l10n = context.l10n;
    return FilledButton(
      onPressed: _ready && bg.androidOk && !_busy ? () => _use(mode) : null,
      child: Text(
        bg.effectiveMode == mode
            ? l10n.phoneGateRetest
            : bg.effectiveMode == PhonePrivilegedMode.off
            ? l10n.phoneDndEnableWith(mode.name)
            : l10n.phoneDndSwitchTo(mode.name),
      ),
    );
  }

  Widget _grantButton(PhonePrivilegedMode mode) => FilledButton(
    onPressed: !_ready || _busy ? null : () => _authorize(mode),
    child: Text(context.l10n.phoneDndGrantShizuku),
  );

  List<Widget> _shizuku(PhoneBackgroundStatus bg) {
    final l10n = context.l10n;
    final s = bg.shizuku;
    // Sui answers the Shizuku interface first; two names can't switch binders.
    if (s.provider == 'sui') return [_Next(text: l10n.phoneDndShizukuViaSui)];
    final installed = _shizukuInstalled(s);
    final sdk = ref.watch(phoneProvider.select((p) => p.status.device.sdkInt));
    return [
      if (!installed)
        _Next(
          text: l10n.phoneDndInstallShizuku,
          button: OutlinedButton.icon(
            onPressed: _openShizukuSite,
            icon: const Icon(AppIcons.openExternal, size: 18),
            label: Text(l10n.phoneDndOpenShizukuSite),
          ),
        )
      else if (!s.running)
        _Next(text: l10n.phoneDndStartShizuku)
      else if (!s.granted)
        _Next(text: l10n.phoneDndGrantShizukuHint, button: _grantButton(PhonePrivilegedMode.shizuku))
      else
        _Next(
          text: l10n.phoneDndShizukuAllSet,
          button: bg.effectiveMode == PhonePrivilegedMode.shizuku && bg.effectiveReady
              ? null
              : _useButton(PhonePrivilegedMode.shizuku, bg),
        ),
      if ((sdk ?? 0) >= 37) _Fine(l10n.phoneDndShizukuCompatibility),
    ];
  }

  List<Widget> _sui(PhoneBackgroundStatus bg) {
    final l10n = context.l10n;
    final s = bg.shizuku;
    if (s.provider != 'sui') return [_Next(text: l10n.phoneDndSuiMissing)];
    return [
      if (!s.running)
        _Next(text: l10n.phoneDndSuiStopped)
      else if (!s.granted)
        _Next(text: l10n.phonePrivilegedSuiDescription, button: _grantButton(PhonePrivilegedMode.sui))
      else
        _Next(
          text: l10n.phoneDndSuiAllSet,
          button: bg.effectiveMode == PhonePrivilegedMode.sui && bg.effectiveReady
              ? null
              : _useButton(PhonePrivilegedMode.sui, bg),
        ),
    ];
  }

  List<Widget> _root(PhoneBackgroundStatus bg) {
    final l10n = context.l10n;
    final r = bg.root;
    final using = bg.effectiveMode == PhonePrivilegedMode.root;
    return [
      _Next(
        // A lost connection says why above the picker; here it is only asked for again.
        text: r.starting
            ? l10n.phoneDndRootWaiting
            : !using
            ? l10n.phonePrivilegedRootDescription
            : r.connected
            ? (bg.keep.enabled ? l10n.phoneDndRootConnectedKept : l10n.phoneDndRootConnected)
            : null,
        button: r.starting || (using && r.connected && bg.effectiveReady)
            ? null
            : using
            ? FilledButton(
                onPressed: _ready && bg.androidOk && !_busy ? () => _use(PhonePrivilegedMode.root) : null,
                child: Text(r.connected ? l10n.phoneGateRetest : l10n.phoneDndRootRetry),
              )
            : _useButton(PhonePrivilegedMode.root, bg),
      ),
    ];
  }

  List<Widget> _adb(PhoneBackgroundStatus bg) {
    final l10n = context.l10n;
    final a = bg.adb;
    final usable = _ready && bg.androidOk;
    final maker = ref.watch(phoneProvider.select((s) => s.status.device.manufacturer));
    final xiaomi = RomFamily.of(maker) == RomFamily.xiaomi;
    return [
      if (!a.paired) ...[
        _Next(
          text: l10n.phoneDndPairNext,
          button: OutlinedButton(
            onPressed: usable && !_busy
                ? () => _run(_phone.adbStartPairing, done: l10n.phoneDndPairingNotificationSent)
                : null,
            child: Text(l10n.phoneDndStartPairing),
          ),
        ),
        PhoneOptionsFold(
          key: const ValueKey('phone-adb-pairing-help'),
          title: l10n.phoneDndPairingHelp,
          children: [
            NumberedSteps([
              l10n.phoneDndDeveloperOptionsStep,
              l10n.phoneDndWirelessDebuggingStep,
              l10n.phoneDndStartPairingStep,
              l10n.phoneDndGetPairingCodeStep,
              l10n.phoneDndEnterPairingCodeStep,
            ]),
            _Next(
              text: l10n.phoneDndManualEntryHint,
              button: OutlinedButton(
                onPressed: usable && !_busy ? _manualPair : null,
                child: Text(l10n.phoneDndManualEntry),
              ),
            ),
            if (xiaomi) _Fine(l10n.phoneDndXiaomiUsbHint),
          ],
        ),
      ] else if (!a.connected) ...[
        _Next(
          text: l10n.phoneDndPairedConnect,
          button: OutlinedButton(
            onPressed: usable && !_busy ? () => _run(_phone.adbConnect, done: l10n.phoneDndConnected) : null,
            child: Text(l10n.phoneDndConnect),
          ),
        ),
        PhoneOptionsFold(
          key: const ValueKey('phone-adb-connect-help'),
          title: l10n.phoneDndConnectHelp,
          children: [
            _Next(
              button: TextButton(
                onPressed: usable && !_busy ? _manualConnect : null,
                child: Text(l10n.phoneDndManualConnect),
              ),
            ),
            _Next(
              button: TextButton(
                onPressed: usable && !_busy ? _manualPair : null,
                child: Text(l10n.phoneDndManualEntry),
              ),
            ),
            if (xiaomi) _Fine(l10n.phoneDndXiaomiUsbHint),
          ],
        ),
      ] else if (bg.effectiveMode != PhonePrivilegedMode.adb || !bg.effectiveReady)
        _Next(button: _useButton(PhonePrivilegedMode.adb, bg)),
    ];
  }
}

/// What to do next inside an unfolded channel: a line, a button, or both.
class _Next extends StatelessWidget {
  const _Next({this.text, this.button});

  final String? text;
  final Widget? button;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          if (text case final text?)
            Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.5),
            ),
          ?button,
        ],
      ),
    );
  }
}

/// Small print at the end of an unfolded channel.
class _Fine extends StatelessWidget {
  const _Fine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary, height: 1.5),
    ),
  );
}

/// The in-app pairing fallback: six-digit code, optional port.
class _PairDialog extends StatefulWidget {
  const _PairDialog();

  @override
  State<_PairDialog> createState() => _PairDialogState();
}

/// ROMs with broken mDNS can connect to the device's current adbd port directly.
class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog();

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  final _port = TextEditingController();

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final port = int.tryParse(_port.text.trim());
    final valid = port != null && port >= 1 && port <= 65535;
    return AlertDialog(
      title: Text(l10n.phoneDndManualConnect),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.phoneDndConnectPortHint),
          TextField(
            key: const ValueKey('adb-connect-port'),
            controller: _port,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 5,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: l10n.phoneDndConnectPortLabel),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
        FilledButton(onPressed: valid ? () => Navigator.pop(context, port) : null, child: Text(l10n.phoneDndConnect)),
      ],
    );
  }
}

class _PairDialogState extends State<_PairDialog> {
  final _code = TextEditingController();
  final _port = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    _port.dispose();
    super.dispose();
  }

  bool get _valid => RegExp(r'^\d{6}$').hasMatch(_code.text.trim());

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.phoneDndEnterCodeTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _code,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: l10n.phoneDndCodeLabel),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            controller: _port,
            keyboardType: TextInputType.number,
            maxLength: 5,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: l10n.phoneDndPortLabel, helperText: l10n.phoneDndPortHint),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
        FilledButton(
          onPressed: _valid ? () => Navigator.pop(context, (_code.text.trim(), int.tryParse(_port.text.trim()))) : null,
          child: Text(l10n.phoneDndPair),
        ),
      ],
    );
  }
}
