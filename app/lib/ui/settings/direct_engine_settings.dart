import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../common/brief_notice.dart';
import 'settings_widgets.dart';

/// Direct launch (off by default) and tawcroot launch (on by default), at most one on; a
/// change applies only after a deliberate engine stop/start.
class DirectEngineSettings extends ConsumerStatefulWidget {
  const DirectEngineSettings({super.key});

  @override
  ConsumerState<DirectEngineSettings> createState() => _DirectEngineSettingsState();
}

class _DirectEngineSettingsState extends ConsumerState<DirectEngineSettings> {
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final runtime = ref.watch(localRuntimeProvider);
    final status = runtime.status;
    final l10n = context.l10n;
    final stopped = !status.phase.isBusy && status.phase != RuntimePhase.running;
    final enabled =
        runtime.loaded && stopped && !_saving && (status.directEngineAvailable || status.directEngineEnabled);
    // Safe mode launches compatibly by design: not a sign the runtime needs it.
    // After Direct failed to launch, native reports the switch off until the
    // user turns it on again (a new try).
    final fallback = status.directEngineFallbackReason;
    final directFailed = fallback == 'directFailed';
    // A tawcroot start's fallback is the tawcroot switch's to explain.
    final runtimeNeedsCompatible =
        !status.tawcEngineEnabled &&
        fallback != null &&
        fallback != 'safeRecovery' &&
        !directFailed &&
        !fallback.startsWith('tawcroot');
    final tawcFailed = fallback == 'tawcrootFailed';
    final tawcEnabled =
        runtime.loaded && stopped && !_saving && (status.tawcEngineAvailable || status.tawcEngineEnabled);
    final tawcHint = !status.tawcEngineAvailable
        ? l10n.phoneTawcUnavailable
        : tawcFailed && !status.tawcEngineEnabled
        ? l10n.phoneTawcFailedHint
        : status.tawcEngineEnabled && fallback != null && fallback != 'safeRecovery'
        ? l10n.phoneDirectCompatibleHint
        : !stopped
        ? l10n.phoneDirectStopFirst
        : status.inSafeMode
        ? l10n.phoneDirectSafeHint
        : l10n.phoneTawcHint;
    final hint = !status.directEngineAvailable
        ? l10n.phoneDirectNeedsRuntime
        : directFailed && !status.directEngineEnabled
        ? l10n.phoneDirectFailedHint
        : runtimeNeedsCompatible
        ? l10n.phoneDirectCompatibleHint
        : !stopped
        ? l10n.phoneDirectStopFirst
        : status.inSafeMode
        ? l10n.phoneDirectSafeHint
        : l10n.phoneDirectHint;

    return SettingsSection(
      title: l10n.phoneDeveloperOptions,
      children: [
        // Only after a direct launch failed: a fallback already runs compatibly
        // and the switch's hint says so.
        if (status.directEngineEnabled && status.launchSelectedMode == 'direct' && status.launchFailureReason != null)
          SettingsTile(
            title: l10n.phoneReturnCompatible,
            subtitle: stopped ? null : l10n.phoneDirectStopFirst,
            onTap: enabled ? () => _change(false) : null,
          ),
        SettingsSwitchTile(
          title: l10n.phoneDirectEngine,
          subtitle: hint,
          value: status.directEngineEnabled,
          onChanged: enabled ? _change : null,
        ),
        SettingsSwitchTile(
          title: l10n.phoneTawcEngine,
          subtitle: tawcHint,
          value: status.tawcEngineEnabled,
          onChanged: tawcEnabled ? _changeTawc : null,
        ),
      ],
    );
  }

  Future<void> _changeTawc(bool value) async {
    setState(() => _saving = true);
    try {
      await ref.read(runtimeBridgeProvider).setTawcEngine(value);
    } catch (_) {
      if (mounted) showBriefNotice(context, context.l10n.phoneDirectChangeFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _change(bool value) async {
    setState(() => _saving = true);
    try {
      await ref.read(runtimeBridgeProvider).setDirectEngine(value);
    } catch (_) {
      if (mounted) showBriefNotice(context, context.l10n.phoneDirectChangeFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
