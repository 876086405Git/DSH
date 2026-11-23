// The page behind each [SettingsPageId], and what a settings link
// (`dshgo://open/<id>`) opens: a page by one of its link ids, or the page a
// row is on.

import 'package:flutter/material.dart';

import '../../account/account_page.dart';
import '../../engine/engine_screen.dart';
import '../../engine_settings/engine_settings_hub.dart';
import '../../engine_settings/runtime_settings_pages.dart';
import '../../engine_settings/subagent_settings_page.dart';
import '../../engine_settings/web_search_page.dart';
import '../../features/agent_presets_page.dart';
import '../../features/all_features_page.dart';
import '../../features/permission_page.dart';
import '../../pets/pet_settings_page.dart';
import '../../phone/always_allow_page.dart';
import '../../phone/android_shell_page.dart';
import '../../phone/app_rules_page.dart';
import '../../phone/dnd_mode_page.dart';
import '../../phone/phone_control_screen.dart';
import '../../phone/phone_skills_page.dart';
import '../../phone/phone_unlock_page.dart';
import '../../phone/system_actions_page.dart';
import '../../plugins/plugin_inventory_page.dart';
import '../../plugins/plugins_screen.dart';
import '../../providers/providers_page.dart';
import '../../remote/remote_screen.dart';
import '../../share_hosted/hosted_links_page.dart';
import '../about_page.dart';
import '../appearance/appearance_page.dart';
import '../background_guide_page.dart';
import '../diagnostics_page.dart';
import '../interface_page.dart';
import '../media_settings_page.dart';
import '../notification_settings.dart';
import '../performance_page.dart';
import '../personalization_page.dart';
import '../privacy_page.dart';
import '../linux_environment_page.dart';
import '../reply_prefs_page.dart';
import '../settings_screen.dart';
import '../system_access_page.dart';
import '../../companion/companion_voice_page.dart';
import '../voice_settings_page.dart';
import 'spot_anchor.dart';
import 'spots.dart';

export 'spots.dart';

/// The page for [id]; [sessionId] is the conversation open in the chat (权限
/// shows its preset).
Widget settingsPage(SettingsPageId id, {String? sessionId}) => switch (id) {
  SettingsPageId.hub => const SettingsScreen(),
  SettingsPageId.appearance => const AppearancePage(),
  SettingsPageId.pets => const PetSettingsPage(),
  SettingsPageId.performance => const PerformancePage(),
  SettingsPageId.voice => const VoiceSettingsPage(),
  SettingsPageId.voiceReading => const CompanionVoicePage(shared: true),
  SettingsPageId.notifications => const NotificationSettingsPage(),
  SettingsPageId.replyPrefs => const ReplyPrefsPage(),
  SettingsPageId.sharedLinks => const HostedLinksPage(),
  SettingsPageId.phone => const PhoneControlScreen(),
  SettingsPageId.phoneAppRules => const PhoneAppRulesPage(),
  SettingsPageId.phoneAlwaysAllow => const PhoneAlwaysAllowPage(),
  SettingsPageId.phoneAndroidShell => const AndroidShellPage(),
  SettingsPageId.phoneDnd => const PhoneDndPage(),
  SettingsPageId.phoneSkills => const PhoneSkillsPage(),
  SettingsPageId.phoneUnlocks => const PhoneUnlockPage(),
  SettingsPageId.systemActions => const SystemActionsPage(),
  SettingsPageId.linuxEnvironment => const LinuxEnvironmentPage(),
  SettingsPageId.engine => const EngineScreen(),
  SettingsPageId.background => const BackgroundGuidePage(),
  SettingsPageId.systemAccess => const SystemAccessPage(),
  SettingsPageId.diagnostics => const DiagnosticsPage(),
  SettingsPageId.models => const ProvidersPage(),
  SettingsPageId.engineParams => const EngineSettingsHubPage(),
  SettingsPageId.subagent => const SubagentSettingsPage(),
  SettingsPageId.agentLoop => const AgentLoopSettingsPage(),
  SettingsPageId.shell => const ShellSettingsPage(),
  SettingsPageId.webSearch => const WebSearchSettingsPage(),
  SettingsPageId.media => const MediaSettingsPage(),
  SettingsPageId.pluginInventory => const PluginInventoryPage(),
  SettingsPageId.plugins => const PluginsScreen(),
  SettingsPageId.allFeatures => const AllFeaturesPage(),
  SettingsPageId.account => const AccountPage(),
  SettingsPageId.remote => const RemoteScreen(),
  SettingsPageId.permission => PermissionPage(sessionId: sessionId),
  SettingsPageId.agentPresets => const AgentPresetsPage(),
  SettingsPageId.personalization => const PersonalizationPage(),
  SettingsPageId.interface => const InterfacePage(),
  SettingsPageId.privacy => const PrivacyPage(),
  SettingsPageId.about => const AboutPage(),
};

/// What a settings link id opens: a page (by any of its link ids), or the
/// page a row is on. Null for ids the index doesn't know.
Widget? settingsPageForLink(String id, {String? sessionId}) {
  if (SettingsIndex.pageForLink(id) case final page?) return settingsPage(page.id, sessionId: sessionId);
  if (SettingsIndex.spotForLink(id) case final spot?) return spotPage(spot, sessionId: sessionId);
  return null;
}

/// Where [spot] leads: the page it opens, or the page it is on with the row
/// brought into view and lit.
Widget spotPage(SettingSpot spot, {String? sessionId}) => spot.isEntry
    ? settingsPage(spot.opens!, sessionId: sessionId)
    : SpotFocus(
        target: spot.id,
        child: settingsPage(spot.page, sessionId: sessionId),
      );

/// Pushes [spotPage] straight over the current page, without the pages in
/// between: back returns here.
Future<void> openSpot(BuildContext context, SettingSpot spot, {String? sessionId}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => spotPage(spot, sessionId: sessionId)));
