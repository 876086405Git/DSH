// Providers behind the share-code sheets.

import 'dart:async';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/android_features.dart';
import '../state/connection_state.dart';
import '../state/plugins_state.dart';
import '../state/runtime_capabilities_state.dart';
import 'guest_fs.dart';
import 'profile_export.dart';
import 'share_codec.dart';
import 'share_import.dart';
import 'share_link.dart';
import 'share_models.dart';
import 'share_net.dart';

/// The code a link points at: inline, or fetched from its Gist (and checked
/// against the checksum the link carries).
Future<SharePayload> resolveShareLink(ShareLink link, ShareNet net) async =>
    decodeShareFile(await fetchShareLinkText(link, net));

/// What a link points at, as `.dshgo` file text (or a bare code): the code
/// inline, or the file in its Gist, checked against the checksum the link
/// carries.
Future<String> fetchShareLinkText(ShareLink link, ShareNet net) async {
  if (!link.isGist) return link.code!;
  final text = await net.fetchGist(link.gistId!);
  final code = await compute(_codeOf, text);
  if (code == null || !code.endsWith('.${link.gistSum}')) throw const ShareDecodeException('gist changed');
  return text;
}

String? _codeOf(String fileText) {
  try {
    final code = readShareEnvelope(fileText).code;
    return RegExp(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{8}$').hasMatch(code) ? code : null;
  } on ShareDecodeException {
    return null;
  }
}

/// Engines an import can go to: 本机 when its engine runs, and the active
/// remote host when connected. The active host comes first.
final importTargetsProvider = Provider.autoDispose<List<ImportTarget>>((ref) {
  final local = ref.watch(localConnectionProvider).value;
  final active = ref.watch(activeConnectionProvider).value;
  final safeMode = ref.watch(localSafeModeProvider);
  // The capability is the active engine's; HarmonyOS's own refuses whichever is active.
  final ohos = ref.watch(operatingSystemProvider) == 'ohos';
  final refused = ohos && ref.watch(marketInstallRefusedProvider);
  return [
    if (active != null && !active.isLocal) ImportTarget(active, isActive: true, installRefused: refused),
    if (local != null)
      ImportTarget(local, isActive: active?.isLocal ?? false, safeMode: safeMode, installRefused: ohos),
  ];
});

/// The checklist for 「分享配置」 on the active engine; null while disconnected.
final profileExportProvider = FutureProvider.autoDispose<ProfileExportSource?>((ref) async {
  final connection = ref.watch(activeConnectionProvider).value;
  if (connection == null) return null;
  final fs = connection.isLocal ? await ref.watch(guestFsProvider.future) : null;
  return loadProfileExport(connection.client, hostLabel: connection.label, isLocal: connection.isLocal, fs: fs);
});

/// How plugin steps reach [target]: the active host's install queue, or
/// its client directly. Tests override it.
final pluginRunnerFactoryProvider = Provider<ImportPluginRunner Function(ProviderContainer, ImportTarget)>(
  (ref) =>
      (container, target) => target.isActive
      ? QueuedPluginRunner(container.read(pluginInstallsProvider.notifier), target.client, isLocal: target.isLocal)
      : DirectPluginRunner(target.client, isLocal: target.isLocal),
);

/// GitHub token for Gist links, kept for this app session only.
class GistTokenController extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? token) => state = (token?.trim().isEmpty ?? true) ? null : token!.trim();
}

final gistTokenProvider = NotifierProvider<GistTokenController, String?>(GistTokenController.new);
