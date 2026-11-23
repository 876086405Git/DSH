import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../settings/settings_widgets.dart';

Future<void> showCompanionAssistantSettings(BuildContext context) =>
    showAppSheet<void>(context, builder: (_) => const _AssistantSettings());

class _AssistantSettings extends StatefulWidget {
  const _AssistantSettings();

  @override
  State<_AssistantSettings> createState() => _AssistantSettingsState();
}

class _AssistantSettingsState extends State<_AssistantSettings> {
  static const _app = MethodChannel('dsh/app');
  late final AppLifecycleListener _lifecycle;
  late Future<Map<String, bool>?> _status;

  Future<Map<String, bool>?> _read() => _app.invokeMapMethod<String, bool>('companionAssistantStatus');

  @override
  void initState() {
    super.initState();
    _status = _read();
    _lifecycle = AppLifecycleListener(onResume: _refresh);
  }

  void _refresh() => setState(() => _status = _read());

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _openAndroidSettings() async {
    final opened = await _app.invokeMethod<bool>('openCompanionAssistantSettings');
    if (mounted && opened != true) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.companionAssistantSettingsMissing)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetTitleBar(l10n.companionSystemAssistant),
            FutureBuilder<Map<String, bool>?>(
              future: _status,
              builder: (context, snapshot) {
                final status = snapshot.data;
                return SheetGroup(
                  margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                  children: [
                    SettingsTile(
                      title: l10n.companionAssistantChoose,
                      subtitle: status?['selected'] == true
                          ? l10n.companionAssistantSelected
                          : l10n.companionAssistantChooseHint,
                      onTap: _openAndroidSettings,
                    ),
                    if (status != null)
                      SettingsSwitchTile(
                        title: l10n.companionAssistantSharePage,
                        subtitle: l10n.companionAssistantSharePageHint,
                        value: status['sharePage'] == true,
                        onChanged: (value) async {
                          await _app.invokeMethod<void>('configureCompanionAssistantPage', value);
                          if (mounted) _refresh();
                        },
                      ),
                    if (status != null)
                      SettingsTile(
                        title: l10n.companionAssistantCalendarAccess,
                        subtitle: status['calendarAllowed'] == true
                            ? l10n.companionAssistantCalendarAllowed
                            : l10n.companionAssistantCalendarHint,
                        onTap: () => _app.invokeMethod<void>(
                          status['calendarAllowed'] == true ? 'openCompanionPermissions' : 'requestCompanionCalendar',
                        ),
                      ),
                    if (status?['calendarAllowed'] == false)
                      SettingsTile(
                        title: l10n.companionAssistantAppPermissions,
                        onTap: () => _app.invokeMethod<void>('openCompanionPermissions'),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
