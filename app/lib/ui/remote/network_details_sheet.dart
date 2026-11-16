import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/link_status.dart';
import '../../state/android_features.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../common/app_sheet.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

Future<void> showRemoteNetworkDetails(BuildContext context, HostRef host) => showAppSheet<void>(
  context,
  dismissal: SheetDismissal.button,
  isScrollControlled: true,
  builder: (_) => RemoteNetworkDetailsSheet(host: host),
);

/// Only route names, timings and IP/protocol enums reach this surface.
/// Candidate addresses, credentials and raw errors never belong in this sheet.
class RemoteNetworkDetailsSheet extends ConsumerStatefulWidget {
  const RemoteNetworkDetailsSheet({super.key, required this.host});

  final HostRef host;

  @override
  ConsumerState<RemoteNetworkDetailsSheet> createState() => _RemoteNetworkDetailsSheetState();
}

class _RemoteNetworkDetailsSheetState extends ConsumerState<RemoteNetworkDetailsSheet> {
  bool _measuring = false;
  bool _failed = false;

  Future<void> _measure() async {
    final link = ref.read(hostLinkProvider(widget.host));
    if (link is! NetworkInspectableHostLink) {
      setState(() => _failed = true);
      return;
    }
    setState(() {
      _measuring = true;
      _failed = false;
    });
    try {
      final result = await (link as NetworkInspectableHostLink).inspectNetwork();
      if (!mounted || !identical(ref.read(hostLinkProvider(widget.host)), link)) return;
      if (ref.read(hostLinkStatusProvider(widget.host)).value?.isConnected != true) return;
      setState(() => _failed = result == null || result.roundTripTime == null);
    } catch (_) {
      if (mounted && identical(ref.read(hostLinkProvider(widget.host)), link)) {
        setState(() => _failed = true);
      }
    } finally {
      if (mounted) setState(() => _measuring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final status = ref.watch(hostLinkStatusProvider(widget.host)).value ?? HostLinkStatus.idle;
    final name = ref.watch(hostNameProvider(widget.host)) ?? l10n.commonRemoteHost;
    final relay = widget.host.kind == HostKind.relay;
    // No WebRTC there (hostsProvider's peer connector): the relay isn't a fallback.
    final ohos = ref.watch(operatingSystemProvider) == 'ohos';
    final connected = status.isConnected;
    final network = connected && relay ? status.network : null;
    final path = connected && relay ? network?.path ?? status.path : null;
    final observedAt = network?.observedAt?.toLocal();
    final material = MaterialLocalizations.of(context);
    final observedLabel = observedAt == null
        ? null
        : '${material.formatCompactDate(observedAt)} ${material.formatTimeOfDay(TimeOfDay.fromDateTime(observedAt), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
    String timing(Duration? value) =>
        value == null ? l10n.remoteNetworkUnmeasured : l10n.remoteNetworkMilliseconds(value.inMilliseconds);
    String ipVersion(NetworkIpVersion? value) => switch (value) {
      NetworkIpVersion.ipv4 => 'IPv4',
      NetworkIpVersion.ipv6 => 'IPv6',
      null => l10n.remoteNetworkUnknownPath,
    };
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(l10n.remoteNetworkDetails),
            Padding(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 12),
              child: Text(
                relay
                    ? '${ohos ? l10n.harmonyNetworkRelayOnly : l10n.remoteNetworkAutomatic}\n${l10n.remoteNetworkSnapshotHint}'
                    : l10n.hostDetailsSshNetworkHint,
                style: TextStyle(color: colors.textTertiary),
              ),
            ),
            SheetGroup(
              children: [
                _NetworkValue(label: l10n.remoteHost, value: name),
                _NetworkValue(label: l10n.hostDetailsConnectionType, value: relay ? 'DSH Remote' : 'SSH'),
                _NetworkValue(label: l10n.commonStatus, value: status.summary),
                _NetworkValue(
                  label: l10n.remoteNetworkCurrentPath,
                  value: connected && widget.host.kind == HostKind.ssh
                      ? 'SSH'
                      : path?.label ?? l10n.remoteNetworkUnknownPath,
                ),
                _NetworkValue(label: l10n.remoteNetworkConnectDuration, value: timing(network?.connectDuration)),
                _NetworkValue(label: l10n.remoteNetworkRoundTripTime, value: timing(network?.roundTripTime)),
                if (relay && connected && path != null && path != RelayPath.relay) ...[
                  _NetworkValue(label: l10n.remoteNetworkLocalIpVersion, value: ipVersion(network?.localIpVersion)),
                  _NetworkValue(label: l10n.remoteNetworkRemoteIpVersion, value: ipVersion(network?.remoteIpVersion)),
                  _NetworkValue(
                    label: l10n.remoteNetworkIceProtocol,
                    value: network?.iceProtocol?.name.toUpperCase() ?? l10n.remoteNetworkUnknownPath,
                  ),
                ],
                if (observedLabel != null) _NetworkValue(label: l10n.remoteNetworkObservedAt, value: observedLabel),
                if (network?.fallbackReason != null)
                  _NetworkValue(
                    label: l10n.remoteNetworkFallback,
                    value: _fallbackLabel(l10n, network!.fallbackReason!, ohos: ohos),
                  ),
              ],
            ),
            if (relay)
              Padding(
                padding: const EdgeInsets.fromLTRB(kSheetGutter, 8, kSheetGutter, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!connected || _failed) ...[
                      Text(
                        connected ? l10n.remoteNetworkMeasureFailed : l10n.remoteNetworkDisconnected,
                        style: TextStyle(color: colors.textTertiary),
                      ),
                      const SizedBox(height: 10),
                    ],
                    FilledButton.icon(
                      onPressed: connected && !_measuring ? _measure : null,
                      icon: _measuring
                          ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(AppIcons.refresh, size: 18),
                      label: Text(_measuring ? l10n.remoteNetworkMeasuring : l10n.remoteNetworkMeasure),
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

class _NetworkValue extends StatelessWidget {
  const _NetworkValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(label, style: TextStyle(color: DshColors.of(context).textTertiary)),
        ),
        const SizedBox(width: 16),
        Expanded(child: Text(value, textAlign: TextAlign.end)),
      ],
    ),
  );
}

String _fallbackLabel(L10n l10n, String code, {required bool ohos}) => switch (code) {
  'webrtcUnavailable' when ohos => l10n.harmonyNetworkFallbackRelayOnly,
  'webrtcUnavailable' => l10n.remoteNetworkFallbackWebrtcUnavailable,
  'directFailed' => l10n.remoteNetworkFallbackDirectFailed,
  'directTimeout' => l10n.remoteNetworkFallbackDirectTimeout,
  'directRecentlyFailed' => l10n.remoteNetworkFallbackDirectRecentlyFailed,
  'turnUnavailable' => l10n.remoteNetworkFallbackTurnUnavailable,
  'turnFailed' => l10n.remoteNetworkFallbackTurnFailed,
  'turnTimeout' => l10n.remoteNetworkFallbackTurnTimeout,
  'pathUnverified' => l10n.remoteNetworkFallbackPathUnverified,
  _ => l10n.remoteNetworkFallbackUnknown,
};
