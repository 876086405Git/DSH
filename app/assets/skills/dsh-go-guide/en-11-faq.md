# Troubleshooting

## Messages won't send, or no reply comes

Check the host status at the bottom of the chat list.

- **This phone**: open the engine page and check its status and **Logs**. Not installed, stopped and failed to start are different cases; follow the page. When a start fails, the failure card links to the logs and a diagnostics bundle.
- **Remote host**: the remote hosts page offers a fix for the cause, such as **Reconnect**, **Sign in again** or **Trust again**.
- If no model is set up, **Choose model** offers to enter an API key or add a provider.

Reset and uninstall both delete data on this phone; you rarely need them to fix a problem.

<!-- nav: commonSettings,phoneEngineDiagnostics -->
`Settings › Diagnostics` · [Open](dshgo://open/diagnostics)

To report a problem, export a diagnostics bundle here. It includes the version, device, bounded engine logs and captured errors, not all system logs or a complete crash history. The app attempts to remove keys and tokens; still inspect the bundle before sharing it.

To let the AI look into it, tap **Let the AI read diagnostics**. The app writes a bounded snapshot for the local engine, then ask the AI to "check the diagnostics". The bundled `dsh-go-support` skill walks the symptoms and drafts an issue you can paste.

### Crashes and automatic failure analysis

The app keeps bounded local records of error categories, a few app/framework source locations and voice stages, without exception bodies, recordings or chat content. On Android 11 and later it also attempts to read this app's historical process-exit reasons. Missing or empty system records do not prove there was no failure, and are not complete crash stacks.

In an ordinary local chat, ask the AI to check the recent crash. Supported versions expose a diagnostics tool that refreshes and reads individual sections, without a manual export, enabling Phone control or granting accessibility. In Safe mode or with an older runtime, the published snapshot remains the fallback; export only if more evidence is needed.

**Automatic failure analysis** is off by default. Enabling it explains that, after a failure and only while the app is foregrounded and connected to the working local engine, allowlisted versions, device/system facts, error categories, source locations, voice stages and exit reasons are sent to the model provider configured on that engine. Model charges may apply. Chat bodies, recordings, credentials, raw logs and system input-method evidence are excluded. After an app crash, analysis must wait until the app is reopened and connected.

Analysis uses a separate tool-free conversation, without switching your current chat, performing repairs or publishing to GitHub. Matching failures are grouped; failed or ambiguous attempts are not retried automatically. Check its status here and tap the report entry to read the analysis. Disabling it, switching to a remote host or backgrounding the app prevents new requests and attempts to stop ongoing analysis; sent data and generated conversations cannot be retracted.

If local analysis records cannot be read or saved, automatic analysis pauses and a recovery entry appears. Recovery is local only: it baselines already retained failures without resending old requests, then resumes handling future failures after a successful save. Failed recovery remains paused and is not retried in a loop.

### Input-method or keyboard problems

After reproducing the problem, use **Capture recent events** under **System input-method diagnostics**, read the native prompt and confirm it yourself. It only reuses an already selected and connected Shizuku, Sui, wireless-debugging or Root channel; it does not request permissions, open a background screen or operate an editor. With no channel available, **Phone-control permissions (optional)** lets you choose whether to configure one.

A one-time bounded read of existing fixed-tag system logs retains up to 64 known show/hide requests or input-connection-closed events emitted by this app process from the last two minutes. Typed text, candidates and raw log lines are not exported. Android 12 and some vendor systems may have no matching records; zero events and failures do not prove that the keyboard is healthy. There is no continuous monitoring. Backgrounding the app, leaving Diagnostics or clearing cancels the request. Switching focus in multi-window mode while Diagnostics remains visible does not revoke the one short read already approved.

Results stay in app memory. Only **Let the AI read diagnostics** or a manual bundle export includes them; automatic snapshots do not. Manual AI reports and automatic environment snapshots each atomically replace their own fixed file; neither overwrites the other. Clear the in-memory evidence whenever you want, or restart the app. Clearing cannot retract files already generated or shared.

## The engine stops in the background, or notifications don't arrive

<!-- nav: commonSettings,phoneEngineKeepAlive -->
`Settings › Background running` · [Open](dshgo://open/background)

Android: follow the guide to turn off battery optimization, keep the "engine running" notification, and lock the app in Recents. After system reclamation of the whole app, a local engine with saved launch options requests restoration. A manual stop is not revived, and launches with temporary environment overrides do not restore automatically. This restarts the engine, not interrupted commands or phone actions. Vendor restrictions still apply.

iOS: this page offers separate audio and location protection switches, both off by default. They are used only while a local task is running in the background, and released when the task ends, the engine stops or the switch is turned off. Audio protection plays silence, uses more battery and yields to recording, calls or other audio use. Location protection needs Always location access and uses extra power and location permissions, but does not store coordinates. If access is denied, this page links to system settings.

The iOS 26 system continued task remains the default path; the system can refuse, cancel or expire it. Enhanced protection is also best-effort, not unlimited background execution or survival after force quit. Keep long tasks in the foreground or use a remote host when reliable execution matters.

For notifications, also turn on the alerts you want in the app's **Notifications** and allow DSH Go notifications in system settings. Alerts from remote hosts need the app running and the connection online.

## The engine keeps failing to start

**Automatic Safe mode** on the local engine page is on by default: after two failed starts in a row, the engine starts without plugins. You can also tap **Start in Safe mode** on the same page. Your chats are safe in Safe mode; fix the configuration, then tap **Return to normal mode**. Web settings changed in Safe mode aren't kept.

Direct local engine launch is off by default; you turn it on under Developer options. Once it is on, on a phone where a direct start fails (Android 16 blocks it, for one), it switches to compatible launch on its own: that doesn't count as a failed start and doesn't lead to Safe mode. It keeps using compatible launch until an app update brings a new runtime, and **Diagnostics** shows **Direct launch failed**. To try again, stop the local engine, then turn on **Direct local engine launch** under **Developer options** on the Diagnostics page.

After an upgrade from an earlier version, the first direct start tidies your plugin files once; the engine shows **Tidying plugin files** meanwhile. If the phone is short of space or the tidy-up doesn't finish, that start uses compatible launch, **Fallback reason** on the **Diagnostics** page says why, and the next start carries on. No files are lost.

**tawcroot fast launch** is also under **Developer options**, on by default, and only one of it and direct launch can be on. With it on, tawcroot runs the local engine: it starts about three times faster, and package installs and apt get faster too. If it can't start, the app switches to compatible launch on its own; that doesn't count as a failed start either, and **Diagnostics** shows **tawcroot failed to start**. To try again, stop the local engine and turn it back on. The first start after you turn it off first turns the hard links it made into ordinary files, and the engine shows **Tidying plugin files**. If the phone is short on space, that start fails and says how much is missing; free up space or turn tawcroot back on. No files are lost.

## The app can chat, but headless reports MISSING_CREDENTIAL

`dsh --profile headless` starts a separate one-shot task. Its default profile disables the interactive credential store, authorization and DeepSeek account services, so it does not automatically use API keys or account sign-ins saved in the app. A working chat in the app does not mean this command has credentials configured.

The default DeepSeek official API route needs `DEEPSEEK_API_KEY`. Supply it in the process environment that launches the command, or set your own API key as `DEEPSEEK_API_KEY=...` in the launch directory's `.env` or `$DSH_HOME/.env`. These are read in order: process environment, launch directory's `.env`, then `$DSH_HOME/.env`. An exported empty variable also shadows the `.env` fallback; unset that empty variable before using a file instead. Keep real keys out of chats, issue reports and source control.

DeepSeek account sign-in and an official API key are different credentials. An account sign-in token cannot be used as `DEEPSEEK_API_KEY`. You can keep using the account in the app, or configure an API key separately for headless.

Adding the app's sign-in patch alone does not enable the services that headless disables by default. Custom profiles and remote hosts may use different configurations; follow the configuration of that host.

## Phone control doesn't work

The top of the phone control page says what's missing:

- The switch is off, or the engine hasn't started.
- You're connected to a remote host: switch to **This phone**.
- DSH isn't installed on this phone: install it first.
- Safe mode is on: return to normal mode.
- Accessibility is off: tap **Turn on**. For a sideloaded app, allow restricted settings first.

If a task stopped midway: turning the screen off, locking the phone, or DSH making no new move for 3 minutes ends it. See [Phone control](04-phone-control.md).

## The floating bar is in the way

Hold and drag the bar out of the way (left, middle or right, at any height), or drag it off the screen's edge to shrink it to a ball; tapping the dot at its left end (or **Shrink to a ball** in its card) does that too. **Collapse when idle** is on by default, so an idle capsule shrinks to a ball by itself; an idle ball fades and slides half out of sight over the edge. Lower **Idle opacity** to fade it more.

## The pet is gone

- Not in chats: if the pet page is set to **None**, choose a pet; if it's hidden for an hour, tap **Show now**.
- Not outside the app: check that **Show outside the app** is on and display over other apps is allowed. **When to show** defaults to **When active**, which hides the pet after 5 quiet minutes. If it was hidden for today, tap **Restore** on the pet page. It also hides while the app is in the foreground and during phone control tasks.

See [Pets](06-pets.md).

## A plugin is installed but doesn't show up

Check that the plugin is enabled, and restart the engine if asked. A plugin's native UI needs the dsh-go bridge on the host: this phone's engine has it built in, remote hosts usually don't. A display place may also be turned off in the plugin's details. Plugin panels without a native UI appear in the Plugins group of All features, opening in the app or as Web entries. See [Plugins](08-plugins.md).

## What the app sends

<!-- nav: commonSettings,hubPrivacy,usageStatsTitle -->
`Settings › Privacy and sharing › Send anonymous usage stats` · [Open](dshgo://open/usage-stats)

dsh-go’s own anonymous usage statistics are on by default; the switch is on the welcome screen the first time you open the app. If you updated from an earlier version, a one-time notice at the bottom of the home screen tells you, and can turn it off right there. While it's on, the app sends anonymous stats for the days before, at most once a day, and only this: app and Android version, CPU architecture, phone maker and model (such as `V2405A`, from 1.0.15), the maker's system and its version (such as OriginOS 5.0, from 1.0.15), app language, how the local engine was started, and that day's number of messages, voice inputs (speech typed into the message box, not voice calls), phone control tasks, generations, shares and installed plugins. From 1.0.17 also: messages sent in the tavern, visits to the companion room, voice calls that connected, and the day's total input and output tokens that model replies reported (only the numbers the provider gives in its replies; channels that give none are not counted, and nothing is estimated). Devices are told apart by a random ID that changes every 90 days.

On Android, daily totals also include foreground activity, the first day of collection, reported model usage, feature outcomes, and crashes or hangs confirmed by Android. Collection is on by default; showing the notice only informs you and does not change when it starts. These reports cannot measure who is online now.

These statistics never include accounts, API keys, chats, character cards, files, prompts, host addresses or which model you use, or device identifiers such as phone number or IMEI. Turning this switch off stops the feature and model collection and deletes that unsent data; on Android, one anonymous daily-activity count with no content is still reported. Reports already received by the server cannot be withdrawn.

## Local text recognition and Google ML Kit

<!-- nav: commonSettings,hubSettingsPhoneControl -->
`Settings › Phone control`

Phone control uses bundled Google ML Kit Chinese text recognition (`com.google.mlkit:text-recognition-chinese:16.0.1`), enabled by default; expand **More settings** on that page and turn it off separately with **Text recognition**. Recognition runs on this device; screenshots and recognized text are not sent to Google. Google’s SDK collects usage statistics such as device model, app version and processing time. The anonymous usage statistics switch above does not control this SDK.

Screenshots and recognized text may be sent to your configured model as part of phone control. While off, recognition requests do not trigger SDK loading or initialization. Turning local recognition off prevents new recognition; work already started may still finish. It does not uninstall the SDK, clear previously accumulated SDK statistics, or guarantee that old SDK statistics stop being sent. A device that has never initialized the SDK and a device previously used with recognition enabled have different histories.

Remote’s pairing scanner also uses ML Kit and initializes the shared SDK separately when the scanner opens. Camera scanning and reading a gallery image do not require phone control or text recognition to be enabled, and do not change that setting. To connect without using ML Kit for pairing, use the Remote account sign-in path instead.

See [Google ML Kit terms](https://developers.google.com/ml-kit/terms) and [Android SDK data disclosure](https://developers.google.com/ml-kit/android-data-disclosure). These SDK terms are distinct from the Apache 2.0 license attached to example code in the documentation.

## The guide doesn't match what I see

Check the app version under **Version** in Settings and compare it with the version in the [guide index](../README.md). The app is always right.
