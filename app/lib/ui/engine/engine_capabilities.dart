import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart';

import '../../l10n/l10n.dart';
import '../settings/settings_widgets.dart';

/// What this engine can't do like a computer's would, as rows of the runtime
/// group. None when it doesn't say; a fact it doesn't know has no row.
List<Widget> engineCapabilityRows(L10n l10n, RuntimeCapabilities? caps) {
  if (caps == null) return const [];
  final shell = switch (caps.shell.kind) {
    RuntimeShellKind.virtual => l10n.engineCapShellBuiltin(caps.shell.commands?.length ?? 0),
    RuntimeShellKind.system => l10n.engineCapShellSystem,
    RuntimeShellKind.none => l10n.engineCapNone,
    RuntimeShellKind.unknown => null,
  };
  final nodeScripts = switch (caps.nodeScripts) {
    RuntimeNodeScripts.worker || RuntimeNodeScripts.workerRebased || RuntimeNodeScripts.process => l10n.engineCapYes,
    RuntimeNodeScripts.none => l10n.engineCapNone,
    RuntimeNodeScripts.unknown => null,
  };
  final market = switch (caps.plugins.marketInstall) {
    RuntimeSupport.supported => l10n.engineCapYes,
    RuntimeSupport.unsupported => l10n.engineCapNone,
    RuntimeSupport.unknown => null,
  };
  final background = switch (caps.background.policy) {
    RuntimeBackgroundPolicy.mayFreeze => l10n.engineCapMayFreeze,
    RuntimeBackgroundPolicy.unrestricted => l10n.engineCapKeepsRunning,
    RuntimeBackgroundPolicy.unknown => null,
  };
  return [
    if (shell != null) InfoRow(label: l10n.engineCapShell, value: shell),
    if (nodeScripts != null) InfoRow(label: l10n.engineCapNodeScripts, value: nodeScripts),
    if (market != null) InfoRow(label: l10n.engineCapMarket, value: market),
    if (background != null) InfoRow(label: l10n.engineCapBackground, value: background),
  ];
}
