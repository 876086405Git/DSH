import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../phone/android_shell_channel.dart';
import '../../state/phone_state.dart';
import '../common/app_dialog.dart';
import '../common/list_page_row.dart';
import '../common/risk_notice.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'phone_widgets.dart';

String androidShellErrorText(L10n l10n, String code) => switch (code) {
  'disabled' => l10n.androidShellErrorDisabled,
  'stopped' => l10n.androidShellErrorStopped,
  'notConnected' => l10n.androidShellErrorNotConnected,
  'shizukuMissing' => l10n.androidShellErrorShizukuMissing,
  'shizukuStopped' => l10n.androidShellErrorShizukuStopped,
  'permissionRequired' => l10n.androidShellErrorPermissionRequired,
  'adbNotPaired' => l10n.androidShellErrorAdbNotPaired,
  'connectFailed' => l10n.androidShellErrorConnectFailed,
  'identityChanged' => l10n.androidShellErrorIdentityChanged,
  'helperStartFailed' => l10n.androidShellErrorHelperStartFailed,
  'busy' => l10n.androidShellErrorBusy,
  'invalidArguments' => l10n.androidShellErrorInvalidArguments,
  'cancelled' => l10n.androidShellErrorCancelled,
  'timeout' => l10n.androidShellErrorTimeout,
  'confirmationDenied' => l10n.androidShellErrorConfirmationDenied,
  'cleanupFailed' => l10n.androidShellErrorCleanupFailed,
  'locked' => l10n.androidShellErrorLocked,
  'confirmationUnavailable' => l10n.androidShellErrorConfirmationUnavailable,
  'transportLost' => l10n.androidShellErrorTransportLost,
  'protocolMismatch' => l10n.androidShellErrorProtocolMismatch,
  'nativeUnavailable' => l10n.androidShellErrorNativeUnavailable,
  'invalidResponse' => l10n.androidShellErrorInvalidResponse,
  'stopFailed' => l10n.androidShellErrorStopFailed,
  _ => l10n.androidShellErrorUnknown,
};

/// Setup is separate from screen control; only its master switch gates enabling.
class AndroidShellPage extends ConsumerStatefulWidget {
  const AndroidShellPage({super.key});

  @override
  ConsumerState<AndroidShellPage> createState() => _AndroidShellPageState();
}

class _AndroidShellPageState extends ConsumerState<AndroidShellPage> {
  static const _channel = AndroidShellChannel();
  static const _margin = EdgeInsets.fromLTRB(16, 12, 16, 12);

  late final AppLifecycleListener _lifecycle;
  AndroidShellStatus _status = const AndroidShellStatus();
  bool _loading = true;
  bool _busy = false;
  bool _stopping = false;
  String? _errorCode;
  int _read = 0;
  int _operation = 0;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () {
        unawaited(ref.read(phoneProvider.notifier).refreshStatus());
        unawaited(_refresh());
      },
    );
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final read = ++_read;
    final status = await _channel.status();
    if (!mounted || read != _read) return;
    setState(() {
      _status = status;
      _loading = false;
    });
  }

  Future<void> _run(Future<AndroidShellResult> Function() action) async {
    if (_busy || _stopping || !_status.supported) return;
    final operation = ++_operation;
    setState(() {
      _busy = true;
      _errorCode = null;
    });
    try {
      final result = await action();
      if (!mounted || operation != _operation) return;
      setState(() => _errorCode = result.ok ? null : result.errorCode ?? 'invalidResponse');
      await _refresh();
    } finally {
      if (mounted && operation == _operation) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(bool enabled) => _run(() async {
    if (enabled) {
      final l10n = context.l10n;
      final accepted = await confirmRisk(
        context,
        RiskNotice(
          id: 'phone.android-shell.enable',
          level: RiskLevel.high,
          title: l10n.androidShellRiskTitle,
          body: l10n.androidShellRiskBody,
          action: l10n.androidShellRiskAction,
        ),
      );
      if (!accepted || !mounted) return const AndroidShellResult(true);
      final phone = ref.read(phoneProvider);
      if (!phone.loaded || !phone.status.ready || !phone.status.enabled) {
        return const AndroidShellResult(false, errorCode: 'disabled');
      }
    }
    return _channel.configure(enabled: enabled, backend: _status.backend);
  });

  Future<void> _authorize() =>
      _run(() async => AndroidShellResult(await _channel.requestPermission(), errorCode: 'permissionRequired'));

  Future<void> _adbInput({required bool pairing}) async {
    if (_busy || _stopping) return;
    final input = await showAppDialog<_AdbInput>(
      context: context,
      builder: (_) => _AdbInputDialog(pairing: pairing),
    );
    if (input == null || !mounted) return;
    await _run(() => pairing ? _channel.pair(input.code!, port: input.port) : _channel.connect(port: input.port));
  }

  /// Stop remains available while a pairing/connection request is pending.
  Future<void> _stop() async {
    if (_stopping) return;
    final operation = ++_operation;
    setState(() {
      _stopping = true;
      _errorCode = null;
    });
    try {
      final stopped = await _channel.stop();
      if (!mounted || operation != _operation) return;
      setState(() => _errorCode = stopped ? null : 'stopFailed');
      await _refresh();
    } finally {
      if (mounted && operation == _operation) {
        setState(() {
          _stopping = false;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final phone = ref.watch(phoneProvider);
    final canSetup = !_loading && _status.supported && !_busy && !_stopping;
    final canEnable = canSetup && phone.loaded && phone.status.ready && phone.status.enabled;
    final reasonCode = _status.reasonCode;
    final timeout = _status.limits['maxTimeoutMs'];
    final output = _status.limits['maxOutputBytes'];
    final shizuku = _status.backend == AndroidShellBackend.shizuku;
    final authorize = ListPageRow(
      key: const ValueKey('android-shell-authorize'),
      title: l10n.androidShellAuthorize,
      titleMaxLines: 2,
      subtitle: !_status.shizuku.installed
          ? l10n.androidShellErrorShizukuMissing
          : !_status.shizuku.running
          ? l10n.androidShellErrorShizukuStopped
          : null,
      subtitleMaxLines: 3,
      onTap: canSetup ? () => unawaited(_authorize()) : null,
    );
    final pairing = [
      ListPageRow(
        key: const ValueKey('android-shell-start-pairing'),
        title: l10n.androidShellStartPairing,
        titleMaxLines: 2,
        onTap: canSetup ? () => unawaited(_run(_channel.startPairing)) : null,
      ),
      ListPageRow(
        key: const ValueKey('android-shell-pair'),
        title: l10n.androidShellPair,
        onTap: canSetup ? () => unawaited(_adbInput(pairing: true)) : null,
      ),
    ];
    return AppPage.list(
      title: l10n.androidShellTitle,
      children: [
        PhoneNote(tone: NoteTone.warn, text: l10n.androidShellConfirmationNote),
        if (!phone.status.enabled) PhoneNote(text: l10n.androidShellMasterOff),
        ListPageCard(
          margin: _margin,
          children: [
            ListPageRow(
              icon: AppIcons.terminal,
              title: l10n.androidShellEnable,
              titleMaxLines: 2,
              trailing: Switch(
                key: const ValueKey('android-shell-enable'),
                value: _status.enabled,
                onChanged: canEnable || (canSetup && _status.enabled) ? (value) => unawaited(_toggle(value)) : null,
              ),
            ),
            ListPageRow(
              title: l10n.androidShellStatus,
              subtitle: _loading
                  ? l10n.phoneNotReadyYet
                  : !_status.supported
                  ? androidShellErrorText(l10n, reasonCode ?? 'invalidResponse')
                  : reasonCode != null
                  ? androidShellErrorText(l10n, reasonCode)
                  : !_status.enabled
                  ? l10n.androidShellErrorDisabled
                  : _status.ready
                  ? l10n.androidShellReady
                  : l10n.androidShellErrorNotConnected,
              subtitleMaxLines: 6,
            ),
            ListPageRow(title: l10n.androidShellRefresh, onTap: _loading ? null : () => unawaited(_refresh())),
          ],
        ),
        if (_errorCode case final code?)
          PhoneNote(
            key: const ValueKey('android-shell-operation-error'),
            tone: NoteTone.warn,
            text: androidShellErrorText(l10n, code),
          ),
        ListPageCard(
          margin: _margin,
          title: l10n.androidShellBackend,
          children: [
            for (final backend in AndroidShellBackend.values)
              Semantics(
                selected: _status.backend == backend,
                inMutuallyExclusiveGroup: true,
                child: ListPageRow(
                  key: ValueKey('android-shell-backend-${backend.name}'),
                  leading: Icon(_status.backend == backend ? AppIcons.radioOn : AppIcons.radioOff),
                  title: backend == AndroidShellBackend.shizuku ? 'Shizuku' : l10n.androidShellAdb,
                  onTap: !canSetup || _status.backend == backend
                      ? null
                      : () => unawaited(_run(() => _channel.configure(enabled: _status.enabled, backend: backend))),
                ),
              ),
          ],
        ),
        if (shizuku && !_status.shizuku.granted)
          ListPageCard(margin: _margin, children: [authorize])
        else if (!shizuku && !_status.adb.paired)
          ListPageCard(margin: _margin, children: pairing),
        if (!_status.ready && (shizuku ? _status.shizuku.granted : _status.adb.paired))
          ListPageCard(
            margin: _margin,
            children: [
              ListPageRow(
                key: ValueKey(shizuku ? 'android-shell-connect-shizuku' : 'android-shell-connect'),
                title: shizuku ? l10n.androidShellConnectChannel : l10n.androidShellConnect,
                titleMaxLines: 2,
                subtitle: !_status.enabled ? l10n.androidShellErrorDisabled : null,
                onTap: canSetup && _status.enabled
                    ? () => unawaited(shizuku ? _run(_channel.connect) : _adbInput(pairing: false))
                    : null,
              ),
            ],
          ),
        ListPageCard(
          margin: _margin,
          children: [
            ListPageRow(
              key: const ValueKey('android-shell-stop'),
              icon: AppIcons.stop,
              title: l10n.androidShellStop,
              titleMaxLines: 2,
              danger: true,
              onTap: _loading || _stopping ? null : () => unawaited(_stop()),
            ),
          ],
        ),
        PhoneOptionsFold(
          key: const ValueKey('android-shell-details'),
          title: l10n.androidShellDetails,
          children: [
            PhoneNote(text: l10n.androidShellSubtitle),
            PhoneNote(text: l10n.androidShellEnableHint),
            PhoneNote(text: shizuku ? l10n.androidShellShizukuHint : l10n.androidShellAdbHint),
            ListPageCard(
              margin: _margin,
              children: [
                ListPageRow(
                  key: const ValueKey('android-shell-uid'),
                  title: l10n.androidShellUid,
                  value: _status.uid?.toString() ?? l10n.androidShellUidUnknown,
                ),
                if (timeout != null && output != null)
                  ListPageRow(title: l10n.androidShellLimits(timeout ~/ 1000, output), titleMaxLines: 3),
                if (reasonCode != null)
                  ListPageRow(
                    key: const ValueKey('android-shell-reason'),
                    title: l10n.androidShellErrorCode(reasonCode),
                    titleMaxLines: 3,
                  ),
                if (_errorCode case final code?) ListPageRow(title: l10n.androidShellErrorCode(code), titleMaxLines: 3),
                if (shizuku) ...[
                  _fact(l10n.androidShellInstalled, _status.shizuku.installed),
                  _fact(l10n.androidShellRunning, _status.shizuku.running),
                  _fact(l10n.androidShellGranted, _status.shizuku.granted),
                  if (_status.shizuku.granted) authorize,
                ] else ...[
                  _fact(l10n.androidShellPaired, _status.adb.paired),
                  _fact(l10n.androidShellConnected, _status.adb.connected),
                  if (_status.adb.paired) ...pairing,
                ],
              ],
            ),
            PhoneNote(text: shizuku ? l10n.androidShellAuthorizeHint : l10n.androidShellPairingGuide),
            PhoneNote(text: l10n.androidShellStopHint),
          ],
        ),
      ],
    );
  }

  Widget _fact(String title, bool ready) => ListPageRow(
    title: title,
    titleMaxLines: 2,
    value: ready ? context.l10n.phoneReady : context.l10n.phoneNotReadyYet,
  );
}

class _AdbInput {
  const _AdbInput({this.code, this.port});

  final String? code;
  final int? port;
}

/// Pairing and connection use separate short-lived forms and port controllers.
class _AdbInputDialog extends StatefulWidget {
  const _AdbInputDialog({required this.pairing});

  final bool pairing;

  @override
  State<_AdbInputDialog> createState() => _AdbInputDialogState();
}

class _AdbInputDialogState extends State<_AdbInputDialog> {
  final _code = TextEditingController();
  final _port = TextEditingController();

  @override
  void dispose() {
    _code.clear();
    _code.dispose();
    _port.dispose();
    super.dispose();
  }

  _AdbInput? _readInput() {
    final portText = _port.text.trim();
    final port = int.tryParse(portText);
    if (portText.isNotEmpty && (port == null || port < 1 || port > 65535)) return null;
    if (widget.pairing && !RegExp(r'^[0-9]{6}$').hasMatch(_code.text)) return null;
    return _AdbInput(code: widget.pairing ? _code.text : null, port: port);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(widget.pairing ? l10n.androidShellPair : l10n.androidShellConnect),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.pairing ? l10n.androidShellPairPortHint : l10n.androidShellConnectPortHint),
            if (widget.pairing)
              TextField(
                key: const ValueKey('android-shell-pair-code'),
                controller: _code,
                autofocus: true,
                keyboardType: TextInputType.number,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(labelText: l10n.androidShellPairCode),
                onChanged: (_) => setState(() {}),
              ),
            TextField(
              key: ValueKey(widget.pairing ? 'android-shell-pair-port' : 'android-shell-connect-port'),
              controller: _port,
              autofocus: !widget.pairing,
              keyboardType: TextInputType.number,
              maxLength: 5,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: widget.pairing ? l10n.androidShellPairPort : l10n.androidShellConnectPort,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
        FilledButton(
          key: const ValueKey('android-shell-adb-submit'),
          onPressed: _readInput() == null
              ? null
              : () {
                  // Input may change after this button was built but before the next frame.
                  final input = _readInput();
                  if (input == null) return;
                  _code.clear();
                  Navigator.pop(context, input);
                },
          child: Text(widget.pairing ? l10n.androidShellPairSubmit : l10n.androidShellConnect),
        ),
      ],
    );
  }
}
