# Settings

Tap the gear at the bottom of the chat list to open Settings; touch and hold it to search right away. The round button beside it opens All features, which ends with shortcuts to settings. In Web mode, tap the app logo and choose **App settings**.

<!-- nav: commonSettings -->
`Settings` · [Open](dshgo://open/settings)

Settings come in six groups, by what you want to do: AI, Capabilities, Appearance, General, Hosts, and Help and about. Each row that opens a page shows where it stands on the right.

## Search

Tap **Search settings** at the top and type a name or a common word, in English or Chinese: "dark", "keep alive", "don't ask", "api key". Renamed settings answer to their old names too. A result opens its page with the row marked. With no results, you can hand the question to the AI in a new chat.

## Top card

Shows your DeepSeek account or API key and balance; tap it to open your account. The line at the bottom shows this phone's engine; tap it to open the local engine page. If DSH isn't installed on this phone, you're not signed in and you're using a remote host, the card shows that host and opens the remote hosts page.

## AI

- **Models**: see [Models and providers](02-models.md).
- **Permissions**: how new chats run commands and change files; see Permissions below.
- **Personalization**:
  - **Personal preferences**: instructions for the AI; new chats follow them. Clear and save to remove them.
  - **Visual replies**: on by default; the AI on this phone's engine can answer with charts, comparisons and tappable options. Takes effect after the engine restarts; tap **Restart now** when asked.
  - **Agent presets**: how new chats work by default; you can also create, copy and edit presets. A preset decides which tools a chat can use. Coding presets such as **Standard mode** and **PTC mode** bring `bash`, `run_code` and other command tools; a custom persona preset can have no tools at all, so pick the right preset when you start a chat.
  - The first two show only with this phone's engine.

## Capabilities

- **System actions**: see [System actions](04-phone-control.md).
- **Web search**: the current host's web search: fill in an API key, or switch to the **New search API**.
- **Plugins**: see [Plugins](08-plugins.md). Some plugins add their own rows below.
- **Images and video**: the current host's generation services, API keys and default models, from the image and video plugin. Pick a provider to add a service, then enter its API key once; image and video services for the same provider and target origin can share that key, with consumers listed in service details. Enter the API root rather than a complete generation endpoint; editing previews the request URL, and changing origin or reusing a key across origins needs confirmation. Saved does not mean authenticated: **Check saved configuration** inspects saved settings only, without checking the key, balance or model permissions over the network. Without the plugin you can **Install on this host**. How to use it: see [Chat](01-chat.md).
- **Linux environment**: HarmonyOS only. Runs command-line tools such as gh and Python on this phone. For the switch, the proxy and how commands use it, see [Engine and remote hosts](03-engine-hosts.md#linux-environment).

## Appearance

**Theme**, **Chat text size** and **Collapse steps when done**: see [Appearance](09-appearance.md). **Pets**: see [Pets](06-pets.md).

## General

- **Interface**: the **Mode** group at the top sets **Open on launch** (Work, Companion or Tavern). Below it, choose whether the app opens to **Native** or **Web**, and DSH Web's options; see [Web mode](05-web.md).
- **Language**: **System**, **简体中文** or **English**.
- **Notifications**: turn on **Allow notifications**, then choose **Turn complete**, **Error or stopped**, **Needs approval** and **Questions for you**. Alerts need the app running, and none go out once the system suspends it; alerts from remote hosts also need the connection online. **Progress notification** shows a chat's status in the notification bar; it's a plain notification and stops updating once the system suspends the app. Sound, banners and the lock screen are set in system settings; banners are off by default.
- **Voice**: how voice input recognizes speech: **Automatic**, **DeepSeek**, **System** or **Another cloud service**. **Automatic** uses DeepSeek when you're signed in or have an API key, otherwise the system's recognition; with DeepSeek or another cloud service, the recording is sent to that service. HarmonyOS's own engine has no voice model; **Voice model** is offered only while connected to a remote host. This page also has **Reading voice** (for reading replies aloud and voice calls), **Live captions** (the HarmonyOS recognizer, showing whether it's available, with no model to download), and for voice calls **Call background**, **Interrupt by speaking**, **Pause before she answers**, **Spoken answers**, **Speakerphone by default** and **Thinking sound**.
- **Performance**: **Auto**, **Full** or **Light**, plus glass blur, interface motion, fluid motion **Refresh rate** (Auto / Max / System) and **Frame cache**.
- **Background running**: what happens to chats on this phone once the app leaves the screen; see [FAQ](11-faq.md).
- **System permissions**: what each feature needs from HarmonyOS. [Open](dshgo://open/system-permissions)
- **Privacy and sharing**:
  - **My shared links**: see [Sharing and replay](07-sharing.md).
  - **Share configuration**: select the current host's settings, plugins, skills and personal preferences to share, and share them as a link, QR code or file.
  - **Send anonymous usage stats**: usage statistics aren't sent on HarmonyOS for now, so this switch is off and locked.
  - **Upload chat logs to DeepSeek**: shown when the current host has it.

## Hosts

- **Local engine** and **Remote host**: see [Engine and remote hosts](03-engine-hosts.md).
- **Engine parameters**: the current host's engine parameters. **Runtime** has **Subagent**, **Agent loop** and **Command execution**; **Plugins** has **Plugin inventory** and plugins' own settings. [Open](dshgo://open/engine-settings)

## Help and about

- **Help**: takes "what can this app do" to a new chat, where the AI answers from this guide. Not shown in Web mode.
- **Community**: chat groups and the forum.
- **Diagnostics**: inspect the environment, export a bundle, or **Let the AI read diagnostics**, and enable **Automatic failure analysis** (off by default); when the keyboard covers the input, **This app's keyboard geometry** exports where the keyboard sat in the last two minutes, without anything typed. See [FAQ](11-faq.md).
- **About DSH Go**:
  - **Version**: the app version, such as 0.9.2 (10251234), with the build number in parentheses. When there's a new version, this row on the Settings page says **Update available**.
  - **Check for updates**: checks online for the latest release. HarmonyOS can't update inside the app. A new version opens the update window with **What’s new**, and the release page says how to get it; it may not have a HarmonyOS package yet. To pass on this version, tap **Skip this version**.
  - **Check automatically**: on by default; checks on launch or return to the app, at most once in 24 hours after a successful check. Tapping Later only closes the window. A new version opens the update window, unless you're on another page or typing, in which case **Check for updates** shows it. Skipped versions aren't offered again, and nothing downloads or installs.
  - **Star DSH Go on GitHub**: opens the project page, where you can star it or share it with friends.
  - **Open-source licenses**.

## Permissions

<!-- nav: commonSettings,featuresPermissions -->
`Settings › Permissions` · [Open](dshgo://open/permission)

- **Current chat**: shown with a chat open; changes that chat only.
- **Default for new chats**: **Read only**, **Workspace write** or **Full access**. Choosing **Full access** asks **Turn on Full access?** first. On this phone's engine it is what used to be "Auto-run commands": in chats and automations you create in the native interface on this phone's engine, the AI no longer asks before running commands or changing files. Remote hosts, Web mode, Safe mode and existing chats aren't affected. Switching back doesn't change chats created while it was on; change those in the chat's permissions.
- System actions follow these permissions too: no asking with full access, otherwise it asks each time. See [System actions](04-phone-control.md).
