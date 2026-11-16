// 扫码配对电脑: the camera reads the code the computer's Remote plugin shows,
// the person confirms the computer, the phone shows an 8-digit code to type
// into the computer, and once the computer confirmed it the phone connects.
//
// The pairing code is shown only here: never logged, notified, copied or
// shared, and the phone never confirms for the computer.

import 'dart:async';

import 'package:dsh_remote/dsh_remote.dart' show formatPairingFingerprint;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../l10n/l10n.dart';
import '../../remote/relay/relay_backend.dart';
import '../../state/account_state.dart';
import '../../state/android_features.dart' show operatingSystemProvider;
import '../../state/hosts_state.dart';
import '../../state/remote_pairing_state.dart';
import '../account/account_widgets.dart' show AccountTile;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'host_key_dialog.dart' show activateHost;

/// The live camera that reports the text of a QR code. Tests swap in a
/// stand-in (there is no camera there).
typedef PairingScannerBuilder = Widget Function(BuildContext context, ValueChanged<String> onCode);

final pairingScannerProvider = Provider<PairingScannerBuilder>((ref) {
  // HarmonyOS has no mobile_scanner: the system scan page reads the code there.
  if (ref.watch(operatingSystemProvider) == 'ohos') {
    return (context, onCode) => _SystemScanner(onCode: onCode);
  }
  return (context, onCode) => _CameraScanner(onCode: onCode);
});

/// Whether the current Remote Server pairs by scanning (the entry shows only
/// then).
final relayPairingSupportProvider = FutureProvider.autoDispose<bool>((ref) async {
  final backend = ref.watch(relayBackendProvider);
  if (!backend.available || backend is! RelayPairingBackend) return false;
  return (backend as RelayPairingBackend).supportsPairing();
});

class RemotePairingPage extends ConsumerStatefulWidget {
  const RemotePairingPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const RemotePairingPage());

  @override
  ConsumerState<RemotePairingPage> createState() => _RemotePairingPageState();
}

class _RemotePairingPageState extends ConsumerState<RemotePairingPage> {
  late final AppLifecycleListener _lifecycle;
  bool _finishing = false;

  /// Paired, but switching to the computer failed: offer to try again.
  bool _switchFailed = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () => ref.read(remotePairingProvider.notifier).setPaused(true),
      onShow: () => ref.read(remotePairingProvider.notifier).setPaused(false),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// Paired: refresh the account (this phone is signed in now) and connect.
  Future<void> _finish(RelayHost host) async {
    if (_finishing) return;
    _finishing = true;
    setState(() => _switchFailed = false);
    final navigator = Navigator.of(context);
    var ok = false;
    try {
      ref.invalidate(relayAccountProvider);
      try {
        await ref.read(relayAccountProvider.future);
      } catch (_) {}
      if (!mounted) return;
      ok = await activateHost(context, ref, HostRef.relay(host.id, name: host.name));
    } catch (_) {
      ok = false;
    } finally {
      _finishing = false;
    }
    if (ok) {
      if (navigator.mounted) navigator.pop();
    } else if (mounted) {
      setState(() => _switchFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final flow = ref.watch(remotePairingProvider);
    final account = ref.watch(accountProvider);
    ref.listen(remotePairingProvider.select((s) => s.host), (_, host) {
      if (host != null) unawaited(_finish(host));
    });
    // A shown code stays even if the account state flickers.
    final gated = !account.signedIn && flow.step.index < PairingStep.claiming.index;
    final Widget body = gated
        ? const _DeepSeekGate()
        : switch (flow.step) {
            PairingStep.scanning => _ScanStep(onCode: ref.read(remotePairingProvider.notifier).scanned),
            PairingStep.resolving => _Busy(label: l10n.remotePairReading),
            PairingStep.confirming => _ConfirmStep(offer: flow.offer!),
            PairingStep.claiming => _Busy(label: l10n.remotePairClaiming),
            PairingStep.showingCode => _CodeStep(flow: flow),
            PairingStep.done when _switchFailed => _SwitchFailed(
              hostName: flow.host?.name ?? '',
              onRetry: () => unawaited(_finish(flow.host!)),
            ),
            PairingStep.done => _Busy(label: l10n.remotePairConnecting(flow.host?.name ?? '')),
            PairingStep.failed => _FailedStep(error: flow.error!),
          };
    return AppPage.list(
      title: l10n.remotePairTitle,
      subtitle: Text(l10n.remotePairSubtitle),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: AnimatedSwitcher(duration: const Duration(milliseconds: 220), child: body),
        ),
      ],
    );
  }
}

// ── Pieces ──────────────────────────────────────────────────────────────────

String _fingerprintLines(String fingerprint) {
  final groups = formatPairingFingerprint(fingerprint).split(' ');
  return [for (var i = 0; i < groups.length; i += 4) groups.skip(i).take(4).join(' ')].join('\n');
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding = const EdgeInsets.fromLTRB(18, 18, 18, 18)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => GlassSurface(
    tier: GlassTier.card,
    borderRadius: AppShape.radiusLg,
    child: Padding(padding: padding, child: child),
  );
}

class _Busy extends StatelessWidget {
  const _Busy({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => _Card(
    child: Row(
      children: [
        const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.2)),
        const SizedBox(width: 14),
        Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyLarge)),
      ],
    ),
  );
}

/// Pairing uses the DeepSeek account signed in on this phone: ask for it
/// first. Only its account id goes along, never a password or token.
class _DeepSeekGate extends ConsumerWidget {
  const _DeepSeekGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.remotePairNeedsDeepSeek, style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                l10n.remotePairNeedsDeepSeekBody,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassSurface(
          tier: GlassTier.card,
          borderRadius: AppShape.radiusLg,
          child: Material(
            type: MaterialType.transparency,
            clipBehavior: Clip.antiAlias,
            shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusLg),
            child: const AccountTile(),
          ),
        ),
      ],
    );
  }
}

class _ScanStep extends ConsumerWidget {
  const _ScanStep({required this.onCode});

  final ValueChanged<String> onCode;

  Future<void> _paste(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!context.mounted) return;
    if (text.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l10n.remotePairPasteEmpty)));
      return;
    }
    onCode(text);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: ClipRSuperellipse(
            borderRadius: AppShape.radiusLg,
            child: ref.watch(pairingScannerProvider)(context, onCode),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          l10n.remotePairScanHint,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: TextButton.icon(
            onPressed: () => unawaited(_paste(context)),
            icon: const Icon(AppIcons.paste, size: 18),
            label: Text(l10n.remotePairPasteLink),
          ),
        ),
      ],
    );
  }
}

/// "Is this your computer?" — the Server, the computer's name and the full
/// fingerprint the computer's Remote plugin shows.
class _ConfirmStep extends ConsumerWidget {
  const _ConfirmStep({required this.offer});

  final RelayPairingOffer offer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final notifier = ref.read(remotePairingProvider.notifier);
    final deepseekUserId = ref.watch(accountProvider.select((a) => a.profile?.id));
    Widget fact(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary)),
          ),
          Expanded(
            child: Text(value, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(AppIcons.computer, size: 22, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(child: Text(l10n.remotePairConfirmTitle, style: theme.textTheme.titleMedium)),
                ],
              ),
              const SizedBox(height: 14),
              fact(l10n.remotePairComputer, offer.hostName.isEmpty ? l10n.remoteHostFallback : offer.hostName),
              fact(l10n.remotePairServer, offer.server),
              const SizedBox(height: 2),
              Text(l10n.remotePairFingerprint, style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary)),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                decoration: ShapeDecoration(
                  color: colors.codeWellBg,
                  shape: Squircle.border(AppShape.md, side: BorderSide(color: colors.codeWellBorder, width: 0.5)),
                ),
                child: Text(
                  // Four groups a line: the same rows the computer shows, read one by one.
                  _fingerprintLines(offer.fingerprint),
                  style: AppType.mono(size: 13, color: colors.codeWellFg, height: 1.6),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                l10n.remotePairFingerprintHint,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => unawaited(notifier.confirm(deepseekUserId: deepseekUserId)),
          child: Text(l10n.remotePairConfirm),
        ),
        const SizedBox(height: 4),
        TextButton(onPressed: notifier.restart, child: Text(l10n.remotePairNotThis)),
      ],
    );
  }
}

/// The code, digit by digit, until the computer submitted it.
class _CodeStep extends ConsumerStatefulWidget {
  const _CodeStep({required this.flow});

  final PairingFlowState flow;

  @override
  ConsumerState<_CodeStep> createState() => _CodeStepState();
}

class _CodeStepState extends ConsumerState<_CodeStep> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final session = widget.flow.session!;
    final left = session.codeExpiresAt.difference(DateTime.now());
    final expired = left.isNegative && !widget.flow.approved;
    final seconds = left.isNegative ? 0 : left.inSeconds;
    final countdown = '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final digits = session.code.split('');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 18),
          child: Column(
            children: [
              Text(l10n.remotePairCodeTitle, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              Semantics(
                label: l10n.remotePairCodeSemantics(digits.join(' ')),
                excludeSemantics: true,
                child: Row(
                  children: [
                    for (final (i, d) in digits.indexed) ...[
                      if (i == 4) const SizedBox(width: 10) else if (i > 0) const SizedBox(width: 5),
                      Expanded(child: _Digit(d)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.remotePairCodeHint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.remotePairOneAttempt,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.warning, height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!expired) ...[
              const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
            ],
            Flexible(
              child: Text(
                widget.flow.approved
                    ? l10n.remotePairApproved
                    : expired
                    ? l10n.remotePairCodeExpired
                    : l10n.remotePairWaiting(countdown),
                style: theme.textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (!widget.flow.approved)
          TextButton(
            onPressed: () => unawaited(ref.read(remotePairingProvider.notifier).cancel()),
            child: Text(l10n.commonCancel),
          ),
      ],
    );
  }
}

class _Digit extends StatelessWidget {
  const _Digit(this.digit);

  final String digit;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    return AspectRatio(
      aspectRatio: 0.78,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: colors.codeWellBg,
          shape: Squircle.border(AppShape.md, side: BorderSide(color: colors.codeWellBorder, width: 0.5)),
        ),
        child: Center(
          child: FittedBox(
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Text(
                digit,
                style: AppType.mono(size: 28, weight: FontWeight.w600, color: colors.codeWellFg),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paired (this phone is signed in, the key pinned), but switching to the
/// computer did not happen: try again, or leave and pick it from the list.
class _SwitchFailed extends StatelessWidget {
  const _SwitchFailed({required this.hostName, required this.onRetry});

  final String hostName;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.remotePairSwitchFailedTitle(hostName), style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                l10n.remotePairSwitchFailedBody,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: onRetry, child: Text(l10n.commonRetry)),
        const SizedBox(height: 4),
        TextButton(onPressed: () => Navigator.of(context).maybePop(), child: Text(l10n.remotePairDone)),
      ],
    );
  }
}

class _FailedStep extends ConsumerWidget {
  const _FailedStep({required this.error});

  final RelayPairingError error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final notifier = ref.read(remotePairingProvider.notifier);
    final otherServer = error.kind == RelayPairingErrorKind.otherServer && error.server != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(AppIcons.warning, size: 20, color: colors.danger),
                  const SizedBox(width: 10),
                  Expanded(child: Text(l10n.remotePairFailedTitle, style: theme.textTheme.titleMedium)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                otherServer ? l10n.remotePairOtherServerBody(error.server!) : error.message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (otherServer) ...[
          FilledButton(
            onPressed: () => unawaited(notifier.switchServerAndRetry()),
            child: Text(l10n.remotePairSwitchServer),
          ),
          const SizedBox(height: 4),
          TextButton(onPressed: notifier.restart, child: Text(l10n.remotePairScanAgain)),
        ] else
          FilledButton(onPressed: notifier.restart, child: Text(l10n.remotePairScanAgain)),
      ],
    );
  }
}

// ── The camera ──────────────────────────────────────────────────────────────

class _CameraScanner extends StatefulWidget {
  const _CameraScanner({required this.onCode});

  final ValueChanged<String> onCode;

  @override
  State<_CameraScanner> createState() => _CameraScannerState();
}

class _CameraScannerState extends State<_CameraScanner> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _reported = false;
  late final Future<void> _initialization;

  @override
  void initState() {
    super.initState();
    // Android disables ML Kit's eager provider for OCR privacy. Both the camera
    // and photo decoder need the shared SDK before mobile_scanner uses it.
    _initialization = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? const MethodChannel('dsh/app').invokeMethod<void>('initializePairingScanner')
        : Future<void>.value();
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _report(BarcodeCapture capture) {
    if (!mounted || _reported) return;
    for (final code in capture.barcodes) {
      final text = code.rawValue;
      if (text == null || text.isEmpty) continue;
      _reported = true;
      unawaited(_controller.stop());
      widget.onCode(text);
      return;
    }
  }

  /// A screenshot of the code instead of the camera (no camera permission).
  Future<void> _fromImage() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: ImageSource.gallery, requestFullMetadata: false);
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.remotePairImageNoCode)));
      return;
    }
    if (picked == null || !mounted) return;
    BarcodeCapture? capture;
    try {
      await _initialization;
      if (!mounted) return;
      capture = await _controller.analyzeImage(picked.path, formats: const [BarcodeFormat.qrCode]);
    } catch (_) {
      if (mounted) messenger?.showSnackBar(SnackBar(content: Text(l10n.remotePairScannerFailed)));
      return;
    }
    if (!mounted) return;
    if (capture == null || capture.barcodes.every((b) => (b.rawValue ?? '').isEmpty)) {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.remotePairImageNoCode)));
      return;
    }
    _report(capture);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Stack(
      fit: StackFit.expand,
      children: [
        FutureBuilder<void>(
          future: _initialization,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _CameraUnavailable(message: l10n.remotePairScannerFailed);
            }
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            return MobileScanner(
              controller: _controller,
              onDetect: _report,
              errorBuilder: (context, error) => _CameraUnavailable(
                message: error.errorCode == MobileScannerErrorCode.permissionDenied
                    ? l10n.remotePairCameraDenied
                    : l10n.remotePairCameraFailed,
              ),
            );
          },
        ),
        const IgnorePointer(child: CustomPaint(painter: _FramePainter())),
        Positioned(
          right: 10,
          bottom: 10,
          child: Material(
            color: Colors.black.withValues(alpha: 0.45),
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => unawaited(_fromImage()),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(AppIcons.gallery, size: 16, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(l10n.remotePairFromImage, style: const TextStyle(color: Colors.white, fontSize: 13)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// HarmonyOS: a button that opens the system scan page (Scan Kit, through
/// `dsh/app.scanQrCode`). That page owns the camera and has its own album entry,
/// so there is no camera permission and no 从相册识别 here. Closing it does nothing.
class _SystemScanner extends StatefulWidget {
  const _SystemScanner({required this.onCode});

  final ValueChanged<String> onCode;

  @override
  State<_SystemScanner> createState() => _SystemScannerState();
}

class _SystemScannerState extends State<_SystemScanner> {
  static const _app = MethodChannel('dsh/app');
  bool _scanning = false;
  bool _failed = false;

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _failed = false;
    });
    String? text;
    var failed = false;
    try {
      text = await _app.invokeMethod<String>('scanQrCode');
    } on PlatformException catch (e) {
      // 'busy': a scan page is already open and will answer for itself.
      failed = e.code != 'busy';
    } on MissingPluginException {
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _failed = failed;
    });
    if (text != null && text.isNotEmpty) widget.onCode(text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return ColoredBox(
      color: colors.codeWellBg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.icon(
                onPressed: _scanning ? null : () => unawaited(_scan()),
                style: FilledButton.styleFrom(minimumSize: const Size(168, 56), textStyle: theme.textTheme.titleMedium),
                icon: const Icon(AppIcons.qrCode, size: 24),
                label: Text(l10n.remotePairSystemScan),
              ),
              const SizedBox(height: 16),
              Text(
                _failed ? l10n.remotePairScannerFailed : l10n.remotePairSystemScanHint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _failed ? colors.danger : theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    return ColoredBox(
      color: colors.codeWellBg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.qrCode, size: 36, color: colors.textTertiary),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Four corner brackets around the middle of the preview.
class _FramePainter extends CustomPainter {
  const _FramePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide * 0.64;
    final rect = Rect.fromCenter(center: size.center(Offset.zero), width: side, height: side);
    final arm = side * 0.16;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (final (corner, dx, dy) in [
      (rect.topLeft, 1.0, 1.0),
      (rect.topRight, -1.0, 1.0),
      (rect.bottomLeft, 1.0, -1.0),
      (rect.bottomRight, -1.0, -1.0),
    ]) {
      canvas
        ..drawLine(corner, corner.translate(arm * dx, 0), paint)
        ..drawLine(corner, corner.translate(0, arm * dy), paint);
    }
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) => false;
}
