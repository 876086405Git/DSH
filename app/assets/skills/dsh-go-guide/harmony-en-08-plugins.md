# Plugins

Add abilities to DSH from the plugin market, and turn installed plugins on or off, change their settings or uninstall them. Plugins with a native UI appear above the composer, in the message menu and in panels.

Plugins install on the current host. The top of the page says **Install to: This phone** or the host's name; check it before you go ahead. In Safe mode, over DSH Remote, when not connected, or when this engine can't install from the market, it says why instead; you can then turn bundled plugins on or off, or connect a computer to manage plugins.

## Plugins page

<!-- nav: commonSettings,hubPlugins -->
`Settings › Plugins` · [Open](dshgo://open/plugins)

Two tabs: **Installed** and **Plugin market**. Installed shows your plugins and **DSH official** components; some official components need **Get** to install first. Pull down or tap refresh at the top right.

## Install

<!-- nav: commonSettings,hubPlugins,pluginsMarketTitle -->
`Settings › Plugins › Plugin market`

1. Search or browse by category, and tap a plugin for its description, source and required DSH version.
2. Tap the install button at the bottom; it names the target host.
3. If a restart is needed, choose **Restart engine** or **Later** on this phone. Restarting interrupts replies in progress. For a remote host, restart DSH there as prompted.

If build scripts block the install, **Allow scripts and retry** appears. The scripts run on the target host; review the package list, then tap **Allow and retry**.

Web-only plugins are hidden by default; use the button in the market to show them.

## Turn on or off, settings, update and uninstall

- **Enable**: use the switch in the Installed list, or in the plugin's details. Some plugins need an engine restart.
- **Settings**: if a plugin has settings, open them from its details once it's enabled; see Edit plugin settings in the app below. Some plugins also add rows under Plugins on the Settings page.
- **Update**: in the plugin's market details, tap the update button. Updating uninstalls the old version first; if the new one fails to install, the plugin is left uninstalled and you can retry. The running engine keeps the old version until it restarts: on the local engine, a finished update shows **Engine restart needed**, where you can tap **Restart engine** right away or **Later**; on a remote host, you're told to restart DSH on that computer.
- **Uninstall**: in the details, tap **Uninstall** and confirm; you can tap **Undo** on the notice within 4 seconds, and leaving the app uninstalls it at once. The plugin is removed from the host; its data and settings are kept. Sometimes an engine restart is needed to remove it fully.
- **DSH official** components can be turned on or off but not uninstalled, and the switch applies to every chat on that host.

Over DSH Remote, plugins can only be turned on or off. To install or uninstall, tap **Get install command** or **Get uninstall command** and run it on that computer. Plugins can't be installed or uninstalled in Safe mode.

## Edit plugin settings in the app

Enable the plugin, then open **Settings** in its details. When the plugin supplies supported settings, the app shows switches, choices, text or number inputs directly, without switching to the web. Some changes take effect at once. If the page shows **Unsaved**, tap **Save** at the bottom and wait for **Applied**. For fields that need typing, tap **Done** in the sheet, then check whether the page still shows **Unsaved**. These changes apply to the plugin on the current host.

Some items can only be edited on the web. Their rows say **Edit this item on the web**; tap one to open the plugin's web settings. Other supported items on the same page remain editable in the app. If the plugin has no usable native settings page, follow its entry to the web interface.

Locked settings, read-only hosts and disconnected hosts can't be edited. If a save fails, check the reason shown on the page and try again. If DSH Web can't be opened over DSH Remote, make the change in DSH Web on that computer.

## Native UI

Plugins with a native UI can appear in these places:

- **Composer buttons**: capsules above the composer. Tapping one fills in the composer or runs an action; it never sends on its own.
- **Status line**: a live line above the capsules; several plugins take turns. Tap it to open the plugin's panel or run its action.
- **Message menu**: touch and hold an AI reply; plugin actions are below, grouped by plugin.
- **Panels**: on the **Plugins** tab of chat details, and in the Plugins group of All features.
- **Plus panel tools**: a plugin's tools in the composer's plus panel.
- **Chat actions**: actions on this chat in the side panel's **Info**, with the plugin's name on the right.
- **Turn notes**: a few words at the end of a reply's footnote.

Turn off any of these places in the plugin's details. To turn off the whole plugin, use **Enable**. Tap **Native UI** to see how it's running and any problems.

The first time a plugin reads your draft, clipboard or a reply, it asks first. It reads only after you tap **Allow**, and only when you tap it. Once allowed, it can't be revoked separately; turn off that place or the plugin instead.

The native UI needs the dsh-go bridge on the host: this phone's engine has it built in, remote hosts usually don't, and it never shows over DSH Remote.

## DSH Go market

The market offers Official, Adapted for DSH Go and All sections. When an official index lists a package, its checked, pinned version takes precedence over other listings of the same name. Details include risk flags, native features, minimum app version, screenshots and localized descriptions. Risk flags describe capabilities rather than a guarantee of safety. Medium- and high-risk installations ask for confirmation.

Before installation or an update, the app compares the declared digest with npm registry metadata. An unavailable or mismatching digest stops the operation before removing an old version. This does not verify the bytes eventually downloaded by the host; that requires host protocol support. Changing host or connection invalidates pending consent. Withdrawn installed versions show a warning.

Share a plugin page from its details. Opening a shared link leads to the matching details so you can choose the installation host.

The Official section now includes Images and video, with no npm package name to enter. Connect to and select the target Host, then open the card to install.

<!-- nav: commonSettings,mediaSettingsTitle -->
`Settings › Images and video`

When the plugin is missing, this page also offers installation on the current Host. Configure the provider and key on that page afterwards. Over DSH Remote, in Safe mode or when this engine can't install, the page explains why direct installation is unavailable.
