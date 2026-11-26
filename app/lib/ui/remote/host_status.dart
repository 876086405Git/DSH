import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_state.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../common/status_dot.dart';
import '../engine/engine_status.dart';
import '../theme/app_icons.dart';

/// Dot + words for a host's state. Colour is never the only signal.
class HostStatusView {
  const HostStatusView(this.tone, this.label);

  final StatusTone tone;
  final String label;

  static HostStatusView ofLink(HostLinkStatus status) => switch (status.phase) {
    HostLinkPhase.idle => HostStatusView(StatusTone.idle, appL10n.commonNotConnected),
    HostLinkPhase.connecting => HostStatusView(
      StatusTone.busy,
      status.step == null ? appL10n.remoteConnecting : '${status.step!.label}…',
    ),
    HostLinkPhase.connected => HostStatusView(StatusTone.ok, appL10n.remoteConnected),
    HostLinkPhase.reconnecting => HostStatusView(StatusTone.warn, appL10n.remoteReconnecting),
    HostLinkPhase.failed => HostStatusView(StatusTone.error, appL10n.commonConnectionFailed),
  };

  static HostStatusView ofRelayHost(RelayHost host) => host.online
      ? HostStatusView(StatusTone.ok, appL10n.remoteOnline)
      : HostStatusView(StatusTone.idle, appL10n.remoteOffline);
}

/// Live status of [host]: the engine for 本机, the link for remote hosts.
HostStatusView watchHostStatus(WidgetRef ref, HostRef host, {bool showRelayPath = false}) {
  if (host.isLocal) {
    final view = EngineStatusView.of(ref.watch(localRuntimeProvider));
    return HostStatusView(view.tone, view.label);
  }
  final snapshot = ref.watch(hostLinkStatusProvider(host));
  final status = (snapshot.isLoading || snapshot.hasError ? null : snapshot.value) ?? HostLinkStatus.idle;
  if (showRelayPath && host.kind == HostKind.relay && status.isConnected) {
    final path = status.network?.path ?? status.path;
    if (path != null) return HostStatusView(StatusTone.ok, path.label);
  }
  return HostStatusView.ofLink(status);
}

IconData hostKindIcon(HostKind kind) => switch (kind) {
  HostKind.local => AppIcons.thisPhone,
  HostKind.ssh => AppIcons.sshHost,
  HostKind.relay => AppIcons.computer,
};

/// Identity tint per kind (one of the 8 fixed pairs), so rows read as a set.
int hostKindTint(HostKind kind) => switch (kind) {
  HostKind.local => 0,
  HostKind.ssh => 6,
  HostKind.relay => 1,
};
