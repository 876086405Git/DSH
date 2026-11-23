// The settings index: every settings page and every row on them that a
// person may look for, in one table. A row takes its title from here (the
// `spot:` of SettingsTile and friends), so the page and the index can't drift
// apart; search, page links (`dshgo://open/<id>`) and the guide's paths all
// read the same entries. docs/design/settings-ia.md §4.5.
//
// Pure data: no page widgets here (they are in settings_pages.dart), so any
// row can import it.

import '../../../l10n/l10n.dart';

/// A piece of UI text, resolved in a given language.
typedef Label = String Function(L10n l10n);

/// How often people come for it; a search tie goes to the more frequent.
enum Freq {
  high(5),
  medium(2),
  low(0);

  const Freq(this.bonus);

  /// What it adds to a search score.
  final int bonus;
}

/// When a page or row is there. Search still lists it otherwise, with the
/// reason in place of its path, and opens the page it would be on.
enum SpotCondition {
  /// Only with this phone's engine in use.
  localHost,

  /// Only while 手机操控 is on.
  phoneControlOn,

  /// Not in 网页模式 (the native chat takes the question).
  nativeUi,

  /// Only when the host's engine has the setting.
  engineField,

  /// Only with a conversation open.
  openChat,

  /// Only with animations on.
  animationsOn,

  /// Only in builds that come with a Workshop.
  workshopBuilt;

  String label(L10n l10n) => switch (this) {
    localHost => l10n.searchNeedsLocal,
    phoneControlOn => l10n.searchNeedsPhoneControl,
    nativeUi => l10n.searchNeedsNativeUi,
    engineField => l10n.searchNeedsEngineField,
    openChat => l10n.searchNeedsChat,
    animationsOn => l10n.searchNeedsAnimations,
    workshopBuilt => l10n.searchNeedsWorkshop,
  };
}

/// The settings pages, each with one home: its [SettingsPageMeta.parent].
enum SettingsPageId {
  hub,
  models,
  permission,
  personalization,
  replyPrefs,
  agentPresets,
  phone,
  phoneAppRules,
  phoneAlwaysAllow,
  phoneAndroidShell,
  phoneDnd,
  phoneUnlocks,
  systemActions,
  linuxEnvironment,
  webSearch,
  media,
  plugins,
  appearance,
  pets,
  interface,
  notifications,
  voice,
  voiceReading,
  performance,
  background,
  systemAccess,
  privacy,
  sharedLinks,
  engine,
  remote,
  engineParams,
  subagent,
  agentLoop,
  shell,
  pluginInventory,
  allFeatures,
  diagnostics,
  about,
  account,
}

/// One engine setting a spot anchors: the field [key] in any of [namespaces]
/// (shell settings live in `bash-sandbox` or `pwsh-sandbox`).
class SpotField {
  const SpotField(this.namespaces, this.key);

  final List<String> namespaces;
  final String key;

  bool matches(String ns, List<String> path) => path.length == 1 && path.single == key && namespaces.contains(ns);
}

/// A settings page: where it lives, what it is called, how links name it.
class SettingsPageMeta {
  SettingsPageMeta(
    this.id, {
    required this.title,
    this.parent = SettingsPageId.hub,
    this.group,
    this.keywords,
    this.ohosKeywords,
    this.freq = Freq.low,
    this.links = const [],
    this.condition,
    this.row = true,
    this.androidOnly = false,
    this.ohosOnly = false,
    this.iosToo = false,
  });

  final SettingsPageId id;
  final Label title;

  /// Its one home; null only for the hub.
  final SettingsPageId? parent;

  /// The hub group its row sits in, when [parent] is the hub.
  final Label? group;

  /// Comma-separated synonyms and old names (search_{zh,en}.arb).
  final Label? keywords;

  /// In place of [keywords] where they name what HarmonyOS doesn't have.
  final Label? ohosKeywords;
  final Freq freq;

  /// `dshgo://open/<id>` names, old ones included.
  final List<String> links;
  final SpotCondition? condition;

  /// Whether [parent] draws a row for it. 全部功能 has none: the drawer opens
  /// it, and search still finds it.
  final bool row;

  /// Android's own (androidSystemFeaturesProvider), and so is all that is on
  /// or under it ([SettingsIndex.androidOnly]).
  final bool androidOnly;

  /// HarmonyOS's own, where Android has a page of its own for the same idea.
  final bool ohosOnly;
  final bool iosToo;

  /// The row on [parent] that opens this page.
  late final SettingSpot entry = SettingSpot(
    'page:${id.name}',
    page: parent ?? SettingsPageId.hub,
    title: title,
    group: group,
    keywords: keywords,
    ohosKeywords: ohosKeywords,
    freq: freq,
    opens: id,
    condition: condition,
    androidOnly: androidOnly,
    ohosOnly: ohosOnly,
    iosToo: iosToo,
  );
}

/// One row (or one section of a page) a person may look for.
class SettingSpot {
  const SettingSpot(
    this.id, {
    required this.page,
    required this.title,
    this.group,
    this.keywords,
    this.ohosKeywords,
    this.freq = Freq.low,
    this.link,
    this.condition,
    this.opens,
    this.field,
    this.altTitle,
    this.ohosTitle,
    this.androidOnly = false,
    this.ohosOnly = false,
    this.iosToo = false,
    this.iosLacks = false,
  });

  /// Stable, unique: `phone-confirm`, `page:phone`.
  final String id;

  /// The page it is on.
  final SettingsPageId page;
  final Label title;

  /// The hub group, when [page] is the hub.
  final Label? group;

  /// Comma-separated synonyms and old names (search_{zh,en}.arb).
  final Label? keywords;

  /// In place of [keywords] where they name what HarmonyOS doesn't have.
  final Label? ohosKeywords;
  final Freq freq;

  /// `dshgo://open/<link>` opens [page] at this row.
  final String? link;
  final SpotCondition? condition;

  /// The page this row opens: an entry row.
  final SettingsPageId? opens;

  /// The engine setting it shows, on pages drawn from the engine's schema.
  final SpotField? field;

  /// The title the row shows in its other state (安全模式: 以安全模式启动 /
  /// 恢复正常模式).
  final Label? altTitle;

  /// In place of [title] where the row has another name on HarmonyOS.
  final Label? ohosTitle;

  /// The title on this OS, for what lists the spot away from its row.
  Label titleOn({required bool harmony}) => harmony ? ohosTitle ?? title : title;

  /// Android's own, on a page that isn't ([SettingsIndex.androidOnly]).
  final bool androidOnly;

  /// HarmonyOS's own ([SettingsPageMeta.ohosOnly]).
  final bool ohosOnly;

  /// One of [androidOnly]'s that iOS has as well: only HarmonyOS goes without.
  final bool iosToo;

  /// What Android and HarmonyOS have and iOS doesn't (a picture shortcut, the
  /// refresh rate, the rescue profile).
  final bool iosLacks;

  bool get isEntry => opens != null;
}

/// The index itself.
abstract final class SettingsIndex {
  static final Map<SettingsPageId, SettingsPageMeta> pages = {for (final p in _pages) p.id: p};

  /// Rows that aren't page entries.
  static final List<SettingSpot> rows = List.unmodifiable(_rows);

  /// Every spot: the rows and each page's entry.
  static final List<SettingSpot> spots = [
    for (final p in _pages)
      if (p.parent != null) p.entry,
    ..._rows,
  ];

  static final Map<String, SettingSpot> _byId = {for (final s in spots) s.id: s};

  static SettingsPageMeta page(SettingsPageId id) => pages[id]!;

  static SettingSpot? spot(String id) => _byId[id];

  static SettingSpot entry(SettingsPageId id) => pages[id]!.entry;

  /// The spots on [page], entries to its child pages included.
  static Iterable<SettingSpot> on(SettingsPageId page) => spots.where((s) => s.page == page);

  /// The page a `dshgo://open/<id>` link names, by its page links.
  static SettingsPageMeta? pageForLink(String id) => _pages.where((p) => p.links.contains(id)).firstOrNull;

  /// The row a `dshgo://open/<id>` link names.
  static SettingSpot? spotForLink(String id) => _rows.where((s) => s.link == id).firstOrNull;

  /// The row showing the engine setting [path] of namespace [ns].
  static SettingSpot? forField(String ns, List<String> path) =>
      _rows.where((s) => s.field?.matches(ns, path) ?? false).firstOrNull;

  /// Every link id the index answers.
  static Set<String> get linkIds => {for (final p in _pages) ...p.links, for (final s in _rows) ?s.link};

  /// Whether [spot] is Android's own: it says so, or a page on its way does.
  /// Search leaves these out on HarmonyOS (androidSystemFeaturesProvider).
  static bool androidOnly(SettingSpot spot) => spot.androidOnly || chain(spot.page).any((p) => page(p).androidOnly);

  /// Whether the `dshgo://open/<id>` link [id] leads to something [androidOnly]
  /// (on [ios], also to what it lacks: [SettingSpot.iosLacks]).
  static bool androidOnlyLink(String id, {bool ios = false}) {
    final spot = pageForLink(id)?.entry ?? spotForLink(id);
    return spot != null && (androidOnly(spot) && !(ios && spot.iosToo) || ios && spot.iosLacks);
  }

  /// Whether the `dshgo://open/<id>` link [id] leads to what only HarmonyOS has.
  static bool ohosOnlyLink(String id) => pageForLink(id)?.ohosOnly ?? false;

  /// The link to follow on HarmonyOS for [id]: 系统操作 stands in for 手机操控
  /// and its 解除限制, whose hard rules it hasn't got, and the permission page
  /// for 确认方式, which follows it there. Anything else is itself.
  static String ohosLink(String id) => _ohosLinks[id] ?? id;

  static const _ohosLinks = {
    'phone': 'system-actions',
    'phone-unlocks': 'system-actions',
    'phone-confirm': 'permission',
  };

  /// Pages from the hub down to [id], both included.
  static List<SettingsPageId> chain(SettingsPageId id) {
    final out = <SettingsPageId>[];
    SettingsPageId? at = id;
    while (at != null) {
      out.insert(0, at);
      at = pages[at]!.parent;
    }
    return out;
  }

  /// The way there by name, as the guide writes it: 设置 › 手机操控 ›
  /// 确认方式. A page's own trail ends with its title.
  static List<String> trail(SettingSpot spot, L10n l10n) => [
    for (final p in chain(spot.isEntry ? spot.opens! : spot.page)) page(p).title(l10n),
    if (!spot.isEntry) spot.title(l10n),
  ];

  /// What a search result shows under its title: the pages it sits in, with
  /// the hub group after 设置 (设置 › AI › 权限). A page shows its own title
  /// last; a row shows the page it is on.
  static List<String> path(SettingSpot spot, L10n l10n) {
    final pages = chain(spot.isEntry ? spot.opens! : spot.page);
    final out = <String>[];
    for (final (i, p) in pages.indexed) {
      out.add(page(p).title(l10n));
      if (i == 0) {
        // The hub group of the next step down, or of the row itself.
        final group = pages.length > 1 ? page(pages[1]).group : spot.group;
        if (group != null) out.add(group(l10n));
      }
    }
    return out;
  }
}

/// A plugin's own settings form on 引擎设置: known only once the host says
/// which plugins it has, so not in the table (search adds them from the
/// engine's settings). [title] in each language, as search matches both.
SettingSpot pluginFormSpot(String ns, String Function(L10n l10n) title) => SettingSpot(
  '$pluginFormPrefix$ns',
  page: SettingsPageId.engineParams,
  title: title,
  condition: SpotCondition.engineField,
);

/// The id prefix of [pluginFormSpot]s.
const pluginFormPrefix = 'plugin:';

// ── Pages ────────────────────────────────────────────────────────────────────

// The hub's groups, by intent (docs/design/settings-ia.md §4.2).
String _ai(L10n l) => l.hubGroupAi;
String _abilities(L10n l) => l.hubGroupCapabilities;
String _look(L10n l) => l.hubSettingsAppearance;
String _general(L10n l) => l.hubGroupGeneral;
String _hosts(L10n l) => l.hubGroupHosts;
String _help(L10n l) => l.hubGroupHelp;

final _pages = <SettingsPageMeta>[
  SettingsPageMeta(SettingsPageId.hub, title: (l) => l.commonSettings, parent: null, links: const ['settings']),
  // AI
  SettingsPageMeta(
    SettingsPageId.models,
    title: (l) => l.hubSettingsProviders,
    group: _ai,
    keywords: (l) => l.searchKwModels,
    freq: Freq.medium,
    links: const ['models'],
  ),
  SettingsPageMeta(
    SettingsPageId.permission,
    title: (l) => l.featuresPermissions,
    group: _ai,
    keywords: (l) => l.searchKwPermission,
    freq: Freq.medium,
    links: const ['permission'],
  ),
  SettingsPageMeta(
    SettingsPageId.personalization,
    title: (l) => l.hubPersonalization,
    group: _ai,
    keywords: (l) => l.searchKwPersonalization,
    links: const ['personalization'],
  ),
  SettingsPageMeta(
    SettingsPageId.replyPrefs,
    title: (l) => l.hubSettingsPreferences,
    parent: SettingsPageId.personalization,
    keywords: (l) => l.searchKwReplyPrefs,
    condition: SpotCondition.localHost,
  ),
  SettingsPageMeta(
    SettingsPageId.agentPresets,
    title: (l) => l.featuresAgentPresets,
    parent: SettingsPageId.personalization,
    keywords: (l) => l.searchKwAgentPresets,
    links: const ['agent-presets'],
  ),
  // 能力
  SettingsPageMeta(
    SettingsPageId.phone,
    title: (l) => l.phoneControlTitle,
    group: _abilities,
    keywords: (l) => l.searchKwPhone,
    freq: Freq.medium,
    links: const ['phone'],
    androidOnly: true,
    iosToo: true,
  ),
  SettingsPageMeta(
    SettingsPageId.systemActions,
    title: (l) => l.systemActionsTitle,
    group: _abilities,
    keywords: (l) => l.searchKwSystemActions,
    freq: Freq.medium,
    links: const ['system-actions'],
    ohosOnly: true,
  ),
  SettingsPageMeta(
    SettingsPageId.linuxEnvironment,
    title: (l) => l.linuxTitle,
    group: _abilities,
    keywords: (l) => l.searchKwLinux,
    freq: Freq.low,
    links: const ['linux'],
    ohosOnly: true,
  ),
  SettingsPageMeta(
    SettingsPageId.phoneAppRules,
    title: (l) => l.phoneAppRulesTitle,
    parent: SettingsPageId.phone,
    keywords: (l) => l.searchKwAppRules,
  ),
  SettingsPageMeta(
    SettingsPageId.phoneAlwaysAllow,
    title: (l) => l.phoneAlwaysAllowTitle,
    parent: SettingsPageId.phone,
    keywords: (l) => l.phoneAlwaysAllowSwitchHint,
  ),
  SettingsPageMeta(
    SettingsPageId.phoneAndroidShell,
    title: (l) => l.androidShellTitle,
    parent: SettingsPageId.phone,
    keywords: (l) => l.androidShellEntryHint,
  ),
  SettingsPageMeta(
    SettingsPageId.phoneDnd,
    title: (l) => l.phoneDndTitle,
    parent: SettingsPageId.phone,
    keywords: (l) => l.searchKwDnd,
    condition: SpotCondition.phoneControlOn,
  ),
  SettingsPageMeta(
    SettingsPageId.phoneUnlocks,
    title: (l) => l.phoneUnlockTitle,
    parent: SettingsPageId.phone,
    keywords: (l) => l.searchKwPhoneUnlock,
    // The overlay's 「已解除限制」 tag opens it through this link.
    links: const ['phone-unlocks'],
  ),
  SettingsPageMeta(
    SettingsPageId.webSearch,
    title: (l) => l.engineSearchTitle,
    group: _abilities,
    keywords: (l) => l.searchKwWebSearch,
    freq: Freq.medium,
    links: const ['web-search'],
  ),
  SettingsPageMeta(
    SettingsPageId.media,
    title: (l) => l.mediaSettingsTitle,
    group: _abilities,
    keywords: (l) => l.searchKwMediaGeneration,
    freq: Freq.medium,
    links: const ['media'],
  ),
  SettingsPageMeta(
    SettingsPageId.plugins,
    title: (l) => l.hubPlugins,
    group: _abilities,
    keywords: (l) => l.searchKwPlugins,
    freq: Freq.medium,
    links: const ['plugins'],
  ),
  // 外观
  SettingsPageMeta(
    SettingsPageId.appearance,
    title: (l) => l.pluginsTheme,
    group: _look,
    keywords: (l) => l.searchKwTheme,
    freq: Freq.medium,
    links: const ['appearance'],
  ),
  SettingsPageMeta(
    SettingsPageId.pets,
    title: (l) => l.botsPets,
    group: _look,
    keywords: (l) => l.searchKwPets,
    ohosKeywords: (l) => l.harmonyKwPets,
    freq: Freq.medium,
    links: const ['pets'],
  ),
  // 通用
  SettingsPageMeta(
    SettingsPageId.interface,
    title: (l) => l.hubSettingsInterface,
    group: _general,
    keywords: (l) => l.searchKwInterface,
    links: const ['interface'],
  ),
  SettingsPageMeta(
    SettingsPageId.notifications,
    title: (l) => l.pluginsNotifications,
    group: _general,
    keywords: (l) => l.searchKwNotifications,
    freq: Freq.medium,
    links: const ['notifications'],
  ),
  SettingsPageMeta(
    SettingsPageId.voice,
    title: (l) => l.voiceSettingsTitle,
    group: _general,
    keywords: (l) => l.searchKwVoice,
    ohosKeywords: (l) => l.harmonyKwVoice,
    links: const ['voice'],
  ),
  SettingsPageMeta(
    SettingsPageId.voiceReading,
    title: (l) => l.speechVoiceTitle,
    parent: SettingsPageId.voice,
    keywords: (l) => l.searchKwVoiceReading,
    links: const ['voice-reading'],
  ),
  SettingsPageMeta(
    SettingsPageId.performance,
    title: (l) => l.performanceTitle,
    group: _general,
    keywords: (l) => l.searchKwPerformance,
    links: const ['performance'],
  ),
  SettingsPageMeta(
    SettingsPageId.background,
    title: (l) => l.phoneEngineKeepAlive,
    group: _general,
    keywords: (l) => l.searchKwBackground,
    ohosKeywords: (l) => l.harmonyKwBackground,
    freq: Freq.medium,
    links: const ['background'],
  ),
  SettingsPageMeta(
    SettingsPageId.systemAccess,
    title: (l) => l.accessPageTitle,
    group: _general,
    keywords: (l) => l.searchKwSystemAccess,
    ohosKeywords: (l) => l.harmonyKwSystemAccess,
    freq: Freq.medium,
    links: const ['system-permissions'],
  ),
  SettingsPageMeta(
    SettingsPageId.privacy,
    title: (l) => l.hubPrivacy,
    group: _general,
    keywords: (l) => l.searchKwPrivacy,
    links: const ['privacy'],
  ),
  SettingsPageMeta(
    SettingsPageId.sharedLinks,
    title: (l) => l.remoteHostedMyLinks,
    parent: SettingsPageId.privacy,
    keywords: (l) => l.searchKwSharedLinks,
    links: const ['shared-links'],
  ),
  // 主机
  SettingsPageMeta(
    SettingsPageId.engine,
    title: (l) => l.hubSettingsEngine,
    group: _hosts,
    keywords: (l) => l.searchKwEngine,
    freq: Freq.medium,
    links: const ['engine'],
  ),
  SettingsPageMeta(
    SettingsPageId.remote,
    title: (l) => l.commonRemoteHost,
    group: _hosts,
    keywords: (l) => l.searchKwRemote,
    freq: Freq.medium,
    links: const ['remote'],
  ),
  SettingsPageMeta(
    SettingsPageId.engineParams,
    title: (l) => l.engineSettingsTitle,
    group: _hosts,
    keywords: (l) => l.searchKwEngineParams,
    links: const ['engine-settings'],
  ),
  SettingsPageMeta(
    SettingsPageId.subagent,
    title: (l) => l.engineSubagentTitle,
    parent: SettingsPageId.engineParams,
    keywords: (l) => l.searchKwSubagent,
    links: const ['subagent-settings'],
  ),
  SettingsPageMeta(
    SettingsPageId.agentLoop,
    title: (l) => l.engineAgentLoopTitle,
    parent: SettingsPageId.engineParams,
    keywords: (l) => l.searchKwAgentLoop,
    links: const ['agent-loop'],
  ),
  SettingsPageMeta(
    SettingsPageId.shell,
    title: (l) => l.engineShellTitle,
    parent: SettingsPageId.engineParams,
    keywords: (l) => l.searchKwShell,
    links: const ['shell-settings'],
  ),
  SettingsPageMeta(
    SettingsPageId.pluginInventory,
    title: (l) => l.engineSettingsPluginInventory,
    parent: SettingsPageId.engineParams,
    keywords: (l) => l.searchKwPluginInventory,
    links: const ['plugin-inventory'],
  ),
  SettingsPageMeta(
    SettingsPageId.allFeatures,
    title: (l) => l.hubSettingsAllFeatures,
    keywords: (l) => l.searchKwAllFeatures,
    links: const ['all-features'],
    row: false,
  ),
  // 帮助与关于
  SettingsPageMeta(
    SettingsPageId.diagnostics,
    title: (l) => l.phoneEngineDiagnostics,
    group: _help,
    keywords: (l) => l.searchKwDiagnostics,
    links: const ['diagnostics'],
  ),
  SettingsPageMeta(
    SettingsPageId.about,
    title: (l) => l.hubAbout,
    group: _help,
    keywords: (l) => l.searchKwAbout,
    links: const ['about'],
  ),
  // The overview card.
  SettingsPageMeta(
    SettingsPageId.account,
    title: (l) => l.engineAccountTitle,
    keywords: (l) => l.searchKwAccount,
    freq: Freq.medium,
    links: const ['account'],
  ),
];

// ── Rows ─────────────────────────────────────────────────────────────────────

/// Rows by name, for the pages that draw them.
abstract final class Spots {
  // 设置 (the hub).
  static final chatTextSize = SettingSpot(
    'chat-text-size',
    page: SettingsPageId.hub,
    group: _look,
    title: (l) => l.hubSettingsChatTextSize,
    keywords: (l) => l.searchKwTextSize,
    freq: Freq.medium,
    link: 'chat-text-size',
  );
  static final foldTurns = SettingSpot(
    'fold-turns',
    page: SettingsPageId.hub,
    group: _look,
    title: (l) => l.hubSettingsCollapseSteps,
    keywords: (l) => l.searchKwFoldTurns,
  );
  static final language = SettingSpot(
    'language',
    page: SettingsPageId.hub,
    group: _general,
    title: (l) => l.localeTitle,
    keywords: (l) => l.searchKwLanguage,
  );
  static final askAi = SettingSpot(
    'ask-ai',
    page: SettingsPageId.hub,
    group: _help,
    title: (l) => l.askAiHelpTitle,
    keywords: (l) => l.searchKwHelp,
    condition: SpotCondition.nativeUi,
  );
  static final community = SettingSpot(
    'community',
    page: SettingsPageId.hub,
    group: _help,
    title: (l) => l.hubSettingsCommunity,
    keywords: (l) => l.searchKwCommunity,
  );

  // 模型.
  static final addProvider = SettingSpot(
    'add-provider',
    page: SettingsPageId.models,
    title: (l) => l.engineProviderAdd,
    keywords: (l) => l.searchKwAddProvider,
  );

  // 权限.
  static final permissionCurrent = SettingSpot(
    'permission-current',
    page: SettingsPageId.permission,
    title: (l) => l.featuresCurrentChat,
    keywords: (l) => l.searchKwPermissionCurrent,
    condition: SpotCondition.openChat,
  );
  static final permissionDefault = SettingSpot(
    'permission-default',
    page: SettingsPageId.permission,
    title: (l) => l.featuresNewChatDefault,
    keywords: (l) => l.searchKwPermissionDefault,
    freq: Freq.medium,
    link: 'permission-default',
  );
  static final phoneFiles = SettingSpot(
    'phone-files',
    page: SettingsPageId.permission,
    title: (l) => l.hubSettingsPhoneFiles,
    keywords: (l) => l.searchKwPhoneFiles,
    link: 'phone-files',
    condition: SpotCondition.localHost,
    androidOnly: true,
  );
  static final permissionPhoneConfirm = SettingSpot(
    'permission-phone-confirm',
    page: SettingsPageId.permission,
    title: (l) => l.hubPermissionPhoneConfirm,
    keywords: (l) => l.searchKwPhoneConfirmEntry,
    androidOnly: true,
  );

  // 个性化.
  static final visualReplies = SettingSpot(
    'visual-replies',
    page: SettingsPageId.personalization,
    title: (l) => l.hubSettingsVisualReplies,
    keywords: (l) => l.searchKwVisualReplies,
    condition: SpotCondition.localHost,
  );

  // 手机操控.
  static final phoneA11yRestore = SettingSpot(
    'phone-a11y-restore',
    page: SettingsPageId.phone,
    title: (l) => l.a11yRestoreTitle,
    keywords: (l) => l.searchKwA11yRestore,
    condition: SpotCondition.phoneControlOn,
  );
  static final phoneConfirm = SettingSpot(
    'phone-confirm',
    page: SettingsPageId.phone,
    title: (l) => l.phoneConfirmTitle,
    keywords: (l) => l.searchKwPhoneConfirm,
    freq: Freq.medium,
    link: 'phone-confirm',
  );
  static final phoneAutoCollapse = SettingSpot(
    'phone-auto-collapse',
    page: SettingsPageId.phone,
    title: (l) => l.phoneAutoCollapse,
    keywords: (l) => l.searchKwPhoneAutoCollapse,
    condition: SpotCondition.phoneControlOn,
  );
  static final phoneEdgeGlow = SettingSpot(
    'phone-edge-glow',
    page: SettingsPageId.phone,
    title: (l) => l.phoneEdgeGlow,
    keywords: (l) => l.searchKwPhoneEdgeGlow,
    condition: SpotCondition.phoneControlOn,
  );
  static final phoneSystemIsland = SettingSpot(
    'phone-system-island',
    page: SettingsPageId.phone,
    title: (l) => l.phoneSystemIsland,
    keywords: (l) => l.searchKwPhoneSystemIsland,
    condition: SpotCondition.phoneControlOn,
  );
  static final phoneReturn = SettingSpot(
    'phone-return',
    page: SettingsPageId.phone,
    title: (l) => l.phoneReturnAfterDone,
    keywords: (l) => l.searchKwPhoneReturn,
    condition: SpotCondition.phoneControlOn,
    iosToo: true,
  );
  static final phoneBackgroundGuide = SettingSpot(
    'phone-background-guide',
    page: SettingsPageId.phone,
    title: (l) => l.phoneBackgroundGuideTitle,
    keywords: (l) => l.searchKwPhoneBackgroundGuide,
    condition: SpotCondition.phoneControlOn,
  );

  // 插件 (its 插件市场 tab; the page opens on its first tab).
  static final pluginsMarket = SettingSpot(
    'plugins-market',
    page: SettingsPageId.plugins,
    title: (l) => l.pluginsMarketTitle,
    keywords: (l) => l.searchKwPluginsMarket,
  );

  // 联网搜索 (drawn from the engine's schema).
  static final webSearchKey = SettingSpot(
    'web-search-key',
    page: SettingsPageId.webSearch,
    title: (l) => l.searchApiKey,
    keywords: (l) => l.searchKwWebSearchKey,
    field: const SpotField(['web-search-deepseek', 'web-deepseek-api'], 'apiKey'),
    condition: SpotCondition.engineField,
  );

  // 主题.
  static final darkMode = SettingSpot(
    'dark-mode',
    page: SettingsPageId.appearance,
    title: (l) => l.hubThemeLightDark,
    keywords: (l) => l.searchKwDarkMode,
    freq: Freq.medium,
    link: 'dark-mode',
  );
  static final accent = SettingSpot(
    'accent',
    page: SettingsPageId.appearance,
    title: (l) => l.pluginsColors,
    keywords: (l) => l.searchKwAccent,
    ohosKeywords: (l) => l.harmonyKwAccent,
  );
  static final tileStyle = SettingSpot(
    'tile-style',
    page: SettingsPageId.appearance,
    title: (l) => l.pluginsFeatureIcons,
    keywords: (l) => l.searchKwTileStyle,
  );
  static final appIcon = SettingSpot(
    'app-icon',
    page: SettingsPageId.appearance,
    title: (l) => l.pluginsAppIcon,
    keywords: (l) => l.searchKwAppIcon,
  );
  static final iconShortcut = SettingSpot(
    'icon-shortcut',
    page: SettingsPageId.appearance,
    title: (l) => l.iconShortcutRow,
    keywords: (l) => l.searchKwIconShortcut,
    iosLacks: true,
  );
  static final launchScreen = SettingSpot(
    'launch-screen',
    page: SettingsPageId.appearance,
    title: (l) => l.launchScreenTitle,
    keywords: (l) => l.searchKwLaunchScreen,
  );
  static final wallpaper = SettingSpot(
    'wallpaper',
    page: SettingsPageId.appearance,
    title: (l) => l.wallpaperTitle,
    keywords: (l) => l.searchKwWallpaper,
  );

  // 宠物.
  static final petSize = SettingSpot(
    'pet-size',
    page: SettingsPageId.pets,
    title: (l) => l.botsPetSize,
    keywords: (l) => l.searchKwPetSize,
  );
  static final petQuiet = SettingSpot(
    'pet-quiet',
    page: SettingsPageId.pets,
    title: (l) => l.botsPetQuiet,
    keywords: (l) => l.searchKwPetQuiet,
  );
  static final petOutsideApp = SettingSpot(
    'pet-outside-app',
    page: SettingsPageId.pets,
    title: (l) => l.botsPetOutsideApp,
    keywords: (l) => l.searchKwPetOutside,
    androidOnly: true,
    iosToo: true,
  );
  static final petDisplayWhen = SettingSpot(
    'pet-display-when',
    page: SettingsPageId.pets,
    title: (l) => l.botsPetDisplayWhen,
    keywords: (l) => l.searchKwPetDisplayWhen,
    androidOnly: true,
    iosToo: true,
  );
  static final petOverlayShows = SettingSpot(
    'pet-overlay-shows',
    page: SettingsPageId.pets,
    title: (l) => l.botsPetOverlayShows,
    keywords: (l) => l.searchKwPetOverlayShows,
    androidOnly: true,
  );
  static final petOverlayFraming = SettingSpot(
    'pet-overlay-framing',
    page: SettingsPageId.pets,
    title: (l) => l.botsPetOverlayFraming,
    keywords: (l) => l.searchKwPetOverlayFraming,
    androidOnly: true,
  );
  static final petMake = SettingSpot(
    'pet-make',
    page: SettingsPageId.pets,
    title: (l) => l.botsPetMake,
    keywords: (l) => l.searchKwPets,
  );
  static final workshop = SettingSpot(
    'workshop',
    page: SettingsPageId.pets,
    title: (l) => l.workshopTitle,
    keywords: (l) => l.searchKwWorkshop,
    condition: SpotCondition.workshopBuilt,
  );

  // 界面.
  static final uiMode = SettingSpot(
    'ui-mode',
    page: SettingsPageId.interface,
    title: (l) => l.hubInterfaceHome,
    keywords: (l) => l.searchKwUiMode,
  );
  static final hardwareEnterSends = SettingSpot(
    'hardware-enter-sends',
    page: SettingsPageId.interface,
    title: (l) => l.hubHardwareEnterSends,
    keywords: (l) => l.hubHardwareEnterSendsHint,
  );
  static final chatSuggestions = SettingSpot(
    'chat-suggestions',
    page: SettingsPageId.interface,
    title: (l) => l.hubChatSuggestions,
    keywords: (l) => l.searchKwChatSuggestions,
  );
  static final quickPanel = SettingSpot(
    'quick-panel',
    page: SettingsPageId.interface,
    title: (l) => l.hubQuickPanel,
    keywords: (l) => l.searchKwQuickPanel,
  );
  static final tableTint = SettingSpot(
    'table-tint',
    page: SettingsPageId.interface,
    title: (l) => l.hubTableTint,
    keywords: (l) => l.searchKwTableTint,
  );
  static final webApp = SettingSpot(
    'web-app',
    page: SettingsPageId.interface,
    title: (l) => l.commonWeb,
    keywords: (l) => l.searchKwGeneral,
    // 通用设置 (gone: its web app fields live here now).
    link: 'general',
  );
  static final openWeb = SettingSpot(
    'open-web',
    page: SettingsPageId.interface,
    title: (l) => l.hubInterfaceOpenWeb,
    keywords: (l) => l.searchKwOpenWeb,
  );
  static final webPhoneLayout = SettingSpot(
    'web-phone-layout',
    page: SettingsPageId.interface,
    title: (l) => l.hubInterfacePhoneLayout,
    keywords: (l) => l.searchKwWebPhoneLayout,
  );
  static final webCodingView = SettingSpot(
    'web-coding-view',
    page: SettingsPageId.interface,
    title: (l) => l.engineGeneralShowCodingView,
    keywords: (l) => l.searchKwWebCodingView,
    field: const SpotField(['ui-settings'], 'enabled'),
    condition: SpotCondition.engineField,
  );
  static final webCollapse = SettingSpot(
    'web-collapse',
    page: SettingsPageId.interface,
    title: (l) => l.engineGeneralCollapseTiming,
    keywords: (l) => l.searchKwWebCollapse,
    field: const SpotField(['ui-chat'], 'collapseTiming'),
    condition: SpotCondition.engineField,
  );
  static final webBusySend = SettingSpot(
    'web-busy-send',
    page: SettingsPageId.interface,
    title: (l) => l.engineGeneralBusySend,
    keywords: (l) => l.searchKwWebBusySend,
    field: const SpotField(['ui-conversation'], 'busyEnter'),
    condition: SpotCondition.engineField,
  );

  // 性能.
  static final refreshRate = SettingSpot(
    'refresh-rate',
    page: SettingsPageId.performance,
    title: (l) => l.performanceRefresh,
    keywords: (l) => l.searchKwRefreshRate,
    iosLacks: true,
  );
  static final blur = SettingSpot(
    'blur',
    page: SettingsPageId.performance,
    title: (l) => l.performanceBlur,
    keywords: (l) => l.searchKwBlur,
  );
  static final animations = SettingSpot(
    'animations',
    page: SettingsPageId.performance,
    title: (l) => l.performanceAnimations,
    keywords: (l) => l.searchKwAnimations,
  );
  static final fluidMotion = SettingSpot(
    'fluid-motion',
    page: SettingsPageId.performance,
    title: (l) => l.performanceFluid,
    keywords: (l) => l.searchKwFluidMotion,
    condition: SpotCondition.animationsOn,
  );

  // 通知.
  static final notifyEnabled = SettingSpot(
    'notify-enabled',
    page: SettingsPageId.notifications,
    title: (l) => l.pluginsAllowNotifications,
    keywords: (l) => l.searchKwNotifyEnabled,
  );
  static final notifyDone = SettingSpot(
    'notify-done',
    page: SettingsPageId.notifications,
    title: (l) => l.pluginsTurnComplete,
    keywords: (l) => l.searchKwNotifyDone,
  );
  static final notifyFailed = SettingSpot(
    'notify-failed',
    page: SettingsPageId.notifications,
    title: (l) => l.pluginsErrorOrStopped,
    keywords: (l) => l.searchKwNotifyFailed,
  );
  static final notifyApproval = SettingSpot(
    'notify-approval',
    page: SettingsPageId.notifications,
    title: (l) => l.commonWaitingApproval,
    keywords: (l) => l.searchKwNotifyApproval,
  );
  static final notifyQuestion = SettingSpot(
    'notify-question',
    page: SettingsPageId.notifications,
    title: (l) => l.pluginsQuestions,
    keywords: (l) => l.searchKwNotifyQuestion,
  );
  static final notifyLive = SettingSpot(
    'notify-live',
    page: SettingsPageId.notifications,
    title: (l) => l.liveSettingsSwitch,
    ohosTitle: (l) => l.harmonyLiveSwitch,
    keywords: (l) => l.searchKwNotifyLive,
    ohosKeywords: (l) => l.harmonyKwNotifyLive,
  );
  static final notifySystem = SettingSpot(
    'notify-system',
    page: SettingsPageId.notifications,
    title: (l) => l.pluginsSoundBannerLockScreen,
    keywords: (l) => l.searchKwNotifySystem,
  );

  // 隐私与分享.
  static final shareConfig = SettingSpot(
    'share-config',
    page: SettingsPageId.privacy,
    title: (l) => l.hubSettingsShareConfig,
    keywords: (l) => l.searchKwShareConfig,
  );
  static final usageStats = SettingSpot(
    'usage-stats',
    page: SettingsPageId.privacy,
    title: (l) => l.usageStatsTitle,
    keywords: (l) => l.searchKwUsageStats,
    link: 'usage-stats',
  );
  static final chatLogUpload = SettingSpot(
    'chat-log-upload',
    page: SettingsPageId.privacy,
    title: (l) => l.engineChatLogUpload,
    keywords: (l) => l.searchKwChatLogUpload,
    field: const SpotField(['session-log-deepseek'], 'enabled'),
    condition: SpotCondition.engineField,
  );

  // 本机引擎.
  static final autoStart = SettingSpot(
    'auto-start',
    page: SettingsPageId.engine,
    title: (l) => l.phoneEngineAutoStart,
    keywords: (l) => l.searchKwAutoStart,
  );
  static final autoSafe = SettingSpot(
    'auto-safe',
    page: SettingsPageId.engine,
    title: (l) => l.phoneSafeAutoSettings,
    keywords: (l) => l.searchKwAutoSafe,
    androidOnly: true,
  );
  static final safeMode = SettingSpot(
    'safe-mode',
    page: SettingsPageId.engine,
    title: (l) => l.phoneSafeStartSettings,
    altTitle: (l) => l.phoneSafeLeave,
    keywords: (l) => l.searchKwSafeMode,
    iosLacks: true,
  );
  static final workspaceRecovery = SettingSpot(
    'workspace-recovery',
    page: SettingsPageId.engine,
    title: (l) => l.workspaceRecoveryEnable,
    altTitle: (l) => l.workspaceRecoveryDisable,
    keywords: (l) => l.searchKwWorkspaceRecovery,
  );
  static final engineReset = SettingSpot(
    'engine-reset',
    page: SettingsPageId.engine,
    title: (l) => l.phoneEngineReset,
    keywords: (l) => l.searchKwEngineReset,
  );
  static final engineUninstall = SettingSpot(
    'engine-uninstall',
    page: SettingsPageId.engine,
    title: (l) => l.localEnvUninstall,
    keywords: (l) => l.searchKwEngineUninstall,
    ohosKeywords: (l) => l.harmonyKwEngineUninstall,
  );

  // 远程主机.
  static final addSshHost = SettingSpot(
    'add-ssh-host',
    page: SettingsPageId.remote,
    title: (l) => l.remoteAddSshHost,
    keywords: (l) => l.searchKwAddSshHost,
  );
  static final remoteAutoConnect = SettingSpot(
    'remote-auto-connect',
    page: SettingsPageId.remote,
    title: (l) => l.remoteAutoConnectOnStartup,
    keywords: (l) => l.searchKwRemoteAutoConnect,
  );

  static final remoteSessionBackup = SettingSpot(
    'remote-session-backup',
    page: SettingsPageId.remote,
    title: (l) => l.backupTitle,
    keywords: (l) => l.backupSearchKeywords,
  );

  static final remoteCompactHistory = SettingSpot(
    'remote-compact-history',
    page: SettingsPageId.remote,
    title: (l) => l.remoteCompactHistory,
    keywords: (l) => l.searchKwRemoteCompactHistory,
  );

  // 引擎参数 and its pages (drawn from the engine's schema).
  static final subagentDepth = SettingSpot(
    'subagent-depth',
    page: SettingsPageId.subagent,
    title: (l) => l.engineSubagentMaxDepth,
    keywords: (l) => l.searchKwSubagentDepth,
    field: const SpotField(['subagent'], 'maxDepth'),
    condition: SpotCondition.engineField,
  );
  static final parallelCalls = SettingSpot(
    'parallel-calls',
    page: SettingsPageId.agentLoop,
    title: (l) => l.engineAgentMaxParallelCalls,
    keywords: (l) => l.searchKwParallelCalls,
    field: const SpotField(['agent-loop'], 'maxParallelToolCalls'),
    condition: SpotCondition.engineField,
  );
  static final commandTimeout = SettingSpot(
    'command-timeout',
    page: SettingsPageId.shell,
    title: (l) => l.engineFieldCommandTimeout,
    keywords: (l) => l.searchKwCommandTimeout,
    field: const SpotField(['bash-sandbox', 'pwsh-sandbox'], 'timeoutMs'),
    condition: SpotCondition.engineField,
  );

  // 关于 dsh-go.
  static final version = SettingSpot(
    'version',
    page: SettingsPageId.about,
    title: (l) => l.commonVersion,
    keywords: (l) => l.searchKwVersion,
  );
  static final updateCheck = SettingSpot(
    'update-check',
    page: SettingsPageId.about,
    title: (l) => l.updateCheck,
    keywords: (l) => l.searchKwUpdate,
  );
  static final updateAuto = SettingSpot(
    'update-auto',
    page: SettingsPageId.about,
    title: (l) => l.updateAutoCheck,
    keywords: (l) => l.searchKwUpdateAuto,
  );
  static final star = SettingSpot(
    'star',
    page: SettingsPageId.about,
    title: (l) => l.starSettingsTitle,
    keywords: (l) => l.searchKwStar,
  );
  static final licenses = SettingSpot(
    'licenses',
    page: SettingsPageId.about,
    title: (l) => l.hubSettingsLicenses,
    keywords: (l) => l.searchKwLicenses,
  );
}

final _rows = <SettingSpot>[
  Spots.chatTextSize,
  Spots.foldTurns,
  Spots.language,
  Spots.askAi,
  Spots.community,
  Spots.addProvider,
  Spots.permissionCurrent,
  Spots.permissionDefault,
  Spots.phoneFiles,
  Spots.permissionPhoneConfirm,
  Spots.visualReplies,
  Spots.phoneA11yRestore,
  Spots.phoneConfirm,
  Spots.phoneAutoCollapse,
  Spots.phoneEdgeGlow,
  Spots.phoneSystemIsland,
  Spots.phoneReturn,
  Spots.phoneBackgroundGuide,
  Spots.pluginsMarket,
  Spots.webSearchKey,
  Spots.darkMode,
  Spots.accent,
  Spots.tileStyle,
  Spots.appIcon,
  Spots.iconShortcut,
  Spots.launchScreen,
  Spots.wallpaper,
  Spots.petSize,
  Spots.petQuiet,
  Spots.petOutsideApp,
  Spots.petDisplayWhen,
  Spots.petOverlayShows,
  Spots.petOverlayFraming,
  Spots.petMake,
  Spots.workshop,
  Spots.uiMode,
  Spots.hardwareEnterSends,
  Spots.chatSuggestions,
  Spots.quickPanel,
  Spots.tableTint,
  Spots.webApp,
  Spots.openWeb,
  Spots.webPhoneLayout,
  Spots.webCodingView,
  Spots.webCollapse,
  Spots.webBusySend,
  Spots.refreshRate,
  Spots.blur,
  Spots.animations,
  Spots.fluidMotion,
  Spots.notifyEnabled,
  Spots.notifyDone,
  Spots.notifyFailed,
  Spots.notifyApproval,
  Spots.notifyQuestion,
  Spots.notifyLive,
  Spots.notifySystem,
  Spots.shareConfig,
  Spots.usageStats,
  Spots.chatLogUpload,
  Spots.autoStart,
  Spots.autoSafe,
  Spots.safeMode,
  Spots.workspaceRecovery,
  Spots.engineReset,
  Spots.engineUninstall,
  Spots.addSshHost,
  Spots.remoteAutoConnect,
  Spots.remoteCompactHistory,
  Spots.remoteSessionBackup,
  Spots.subagentDepth,
  Spots.parallelCalls,
  Spots.commandTimeout,
  Spots.version,
  Spots.updateCheck,
  Spots.updateAuto,
  Spots.star,
  Spots.licenses,
];
