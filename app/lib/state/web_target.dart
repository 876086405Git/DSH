import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:dsh_client/dsh_client.dart' show PluginBundle;

import '../l10n/l10n.dart';

/// A page of the official DSH Web client the app can land on.
///
/// DSH Web has no URLs for its pages (no router, no hash, no query): the
/// injected bridge (`assets/web/dsh_web_open.js`) gets there by restoring the
/// stored session selection and clicking the official controls. A target is
/// one destination; [sessionId] goes first when set.
class DshWebTarget {
  const DshWebTarget({
    this.sessionId,
    this.panel,
    this.settings,
    this.settingsSection,
    this.settingsPackage,
    this.settingsLabels = const [],
    this.pluginItem = const [],
    this.rightbar,
    this.sidebar = false,
    this.newSession = false,
  });

  /// Opens this session (one extra page load: the bridge stores the
  /// selection the client restores at boot, then reloads).
  final String? sessionId;

  /// A global panel of the sidebar.
  final DshWebPanel? panel;

  /// A section of the settings dialog.
  final DshWebSettings? settings;

  /// A third-party section and its owner, with registered names for hosts
  /// without a browser bridge. Bundle titles are not section names.
  final String? settingsSection;
  final String? settingsPackage;
  final List<String> settingsLabels;

  /// Names of a card on the Plugins page: its titles (zh and en), e.g. a
  /// built-in config page ("Agent 循环") or an experimental bundle ("语音输入"),
  /// and a bundle's package name (the page marks its card with it).
  final List<String> pluginItem;

  /// [pluginItem] as the page can match it: trimmed, none empty (an empty
  /// name would match any icon on the page), each once.
  List<String> get _pluginLabels => _labelsOf(pluginItem);

  static List<String> _labelsOf(List<String> values) => {
    for (final label in values)
      if (label.replaceAll(RegExp(r'\s+'), ' ').trim() case final clean when clean.isNotEmpty) clean,
  }.toList();

  /// A start-page entry of the right sidebar; needs [sessionId].
  final DshWebRightbar? rightbar;

  /// Opens the sessions / workspaces sidebar.
  final bool sidebar;

  /// Starts a new conversation (the sidebar's 新会话); ignores [sessionId].
  final bool newSession;

  /// The plain home page: nothing to open.
  bool get isHome =>
      sessionId == null &&
      panel == null &&
      settings == null &&
      settingsSection == null &&
      _pluginLabels.isEmpty &&
      rightbar == null &&
      !sidebar &&
      !newSession;

  /// What `window.__dshAppOpen` receives.
  Map<String, Object?> toJson() => {
    'session': ?sessionId,
    'panel': ?panel?.key,
    'settings': ?(settingsSection ?? settings?.key),
    'settingsPackage': ?settingsPackage,
    if (settingsSection != null && _labelsOf(settingsLabels).isNotEmpty) 'settingsLabels': _labelsOf(settingsLabels),
    if (_pluginLabels case final labels when labels.isNotEmpty) 'pluginItem': labels,
    'rightbar': ?rightbar?.key,
    if (sidebar) 'sidebar': true,
    if (newSession) 'newSession': true,
  };

  /// The call the WebView runs once the page and the bridge are loaded.
  String get openScript {
    final target = toJson();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS && newSession) target['confirmNewSession'] = true;
    return 'window.__dshAppOpen && window.__dshAppOpen(${jsonEncode(target)});';
  }

  /// A copy aimed at [sessionId] (keeps the destination).
  DshWebTarget inSession(String? sessionId) => _copy(sessionId: sessionId, pluginItem: pluginItem);

  /// A copy whose [pluginItem] also names the bundle behind each name that is
  /// one of its rows (an entry id, `speech-to-text-sensevoice`): its titles
  /// and its package name, which is what the Plugins page shows and marks a
  /// card with. An entry id alone matches no card there.
  DshWebTarget withPluginNames(Iterable<PluginBundle>? bundles) {
    if (bundles == null || pluginItem.isEmpty) return this;
    final names = [..._pluginLabels];
    for (final label in _pluginLabels) {
      for (final bundle in bundles) {
        if (bundle.name == label || !bundle.rows.any((row) => row.rowId == label)) continue;
        for (final name in [...?bundle.meta?.title?.all, bundle.name]) {
          if (!names.contains(name)) names.add(name);
        }
      }
    }
    return names.length == _pluginLabels.length ? this : _copy(sessionId: sessionId, pluginItem: names);
  }

  DshWebTarget _copy({required String? sessionId, required List<String> pluginItem}) => DshWebTarget(
    sessionId: sessionId,
    panel: panel,
    settings: settings,
    settingsSection: settingsSection,
    settingsPackage: settingsPackage,
    settingsLabels: settingsLabels,
    pluginItem: pluginItem,
    rightbar: rightbar,
    sidebar: sidebar,
    newSession: newSession,
  );

  @override
  bool operator ==(Object other) => other is DshWebTarget && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;

  @override
  String toString() => 'DshWebTarget(${jsonEncode(toJson())})';
}

/// Global panels of the DSH Web sidebar (`ctx.layout.selectPanel` keys),
/// and [cordis]: the Cordis plugin panel behind the sidebar's bottom badge
/// (`dsh-client-ui-cordis`; it only renders while the Host has a plugin).
enum DshWebPanel {
  plugins('plugins'),
  schedules('schedules'),
  cordis('cordis');

  const DshWebPanel(this.key);
  final String key;
}

/// Sections of the DSH Web settings dialog (`settings.section` ids).
enum DshWebSettings {
  general('general'),
  models('models'),
  plugins('plugins'),
  agentPresets('agent-presets'),
  account('account');

  const DshWebSettings(this.key);
  final String key;
}

/// Start-page entries of the DSH Web right sidebar (tab kinds).
enum DshWebRightbar {
  files('files'),
  terminal('terminal');

  const DshWebRightbar(this.key);
  final String key;
}

/// What the bridge reported back (`DshAppOpen` channel): [step] names the
/// part that didn't land when [ok] is false.
class DshWebOpenResult {
  const DshWebOpenResult({required this.ok, this.step});

  static DshWebOpenResult? parse(String message) {
    try {
      final json = jsonDecode(message);
      if (json is! Map) return null;
      final step = json['step'];
      return DshWebOpenResult(ok: json['ok'] == true, step: step is String ? step : null);
    } on FormatException {
      return null;
    }
  }

  final bool ok;
  final String? step;

  /// A short localized line for a miss, or null on success.
  String? get problem => ok
      ? null
      : switch (step) {
          'session' => appL10n.webTargetSessionMissing,
          'boot' => appL10n.webTargetNotLoaded,
          'settings' => appL10n.webTargetSettingsMissing,
          'pluginItem' => appL10n.webTargetPluginMissing,
          'rightbar' => appL10n.webTargetSidebarFailed,
          'cordis' => appL10n.webTargetCordisMissing,
          'newSession' => appL10n.webTargetNewChatFailed,
          _ => appL10n.webTargetPageFailed,
        };
}
