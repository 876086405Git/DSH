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

The app keeps bounded local records of error categories and voice stages, and the next time it opens it reads the crash and freeze events the system recorded for this app, keeping the latest 8. Exception bodies, recordings and chat content aren't kept, and these aren't complete crash stacks. No record doesn't prove there was no failure.

**Automatic failure analysis** is off by default, and turning it on explains what is sent and to whom: after a failure, only while the app is in the foreground and connected to the working local engine, redacted versions, device and system facts, error categories, voice stages and exit events go to the model provider configured on that engine. Model charges may apply. Chat bodies, recordings, credentials and raw logs aren't sent. After an app crash, analysis waits until the app is reopened and connected. It runs in a separate conversation, without switching your current chat or performing repairs; tap **View latest analysis conversation** to read it. Turning it off, switching to a remote host or going to the background stops new requests; data already sent can't be retracted.

### The keyboard covers the input

After reproducing it, tap **Export recent keyboard geometry** under **This app's keyboard geometry**. It takes only the last 120 seconds of keyboard show/hide, height and avoid-area records for this app's main window (at most 64), with no typed text, and doesn't read system input-method logs. No records don't prove the keyboard is fine. Share the result with the AI or attach it to your report along with a diagnostics bundle.

## The engine stops in the background, or notifications don't arrive

<!-- nav: commonSettings,phoneEngineKeepAlive -->
`Settings › Background running` · [Open](dshgo://open/background)

The system suspends the app soon after it leaves the screen: a running chat may go on for a short while, as long as the system allows, then pauses with the app and tries to pick up when you come back. Some versions can ask for a long-running task, so the chat goes on in the background with a notice in the notification bar; if the system says no or takes it back, it pauses the same way. This page says which your version is.

To keep it going, keep the app on screen, or run it on a connected remote host. HarmonyOS has no battery-optimization or lock-in-Recents steps to try.

Alerts need the app running, and none go out while it's suspended; also turn on the alerts you want in the app's **Notifications** and allow DSH Go notifications in system settings. Scheduled tasks on this phone only fire while the app is running too, and won't run on time while it's suspended.

## The engine keeps failing to start

After several unclean exits in a row the engine won't start by itself and waits for you. The cause isn't known: the system may have reclaimed the app, or the app was closed, or the engine hit an error. On the failure card:

- **Restore configuration**: goes back to the plugins and settings of the last good run. A run counts as good after two minutes without stopping; with no such record, or nothing changed since, the button isn't there. It only restores configuration: it doesn't go back to an older engine, and it leaves chats and scheduled tasks alone.
- **Enter Safe mode**: starts with the default configuration that comes with the app, without the plugins you installed. Your chats stay. Once fixed, tap **Return to normal mode**. Web settings changed in Safe mode aren't kept.
- **Retry**: starts again with the configuration as it is.

If the engine has already started since the app opened, restoring and entering or leaving Safe mode reopen the app; the dialog says so. The failure card also links to the logs and a diagnostics bundle. Reset and uninstall both delete data on this phone; you rarely need them to fix a problem.

## The app can chat, but headless reports MISSING_CREDENTIAL

`dsh --profile headless` starts a separate one-shot task. Its default profile disables the interactive credential store, authorization and DeepSeek account services, so it does not automatically use API keys or account sign-ins saved in the app. A working chat in the app does not mean this command has credentials configured.

The default DeepSeek official API route needs `DEEPSEEK_API_KEY`. Supply it in the process environment that launches the command, or set your own API key as `DEEPSEEK_API_KEY=...` in the launch directory's `.env` or `$DSH_HOME/.env`. These are read in order: process environment, launch directory's `.env`, then `$DSH_HOME/.env`. An exported empty variable also shadows the `.env` fallback; unset that empty variable before using a file instead. Keep real keys out of chats, issue reports and source control.

DeepSeek account sign-in and an official API key are different credentials. An account sign-in token cannot be used as `DEEPSEEK_API_KEY`. You can keep using the account in the app, or configure an API key separately for headless.

Adding the app's sign-in patch alone does not enable the services that headless disables by default. Custom profiles and remote hosts may use different configurations; follow the configuration of that host.

## System actions don't work

The top of the system actions page says where things stand:

- **On, waiting for the local engine**: start the local engine.
- **On, works once you're back in DSH Go**: the system doesn't let background apps do these, so come back to DSH Go.
- **On, can't connect right now, retrying**: give it a moment.
- **Not available in this version**: this version doesn't support system actions.
- **You're connected to a remote host**: switch to **This phone**.

If the AI says it isn't supported: seeing the screen, tapping inside other apps, reading the clipboard, finding apps by name and SMS can't be done. Alarms and timers need a version with system reminders. See [System actions](04-phone-control.md).

## The AI says gh, python3 or pip isn't available

<!-- nav: commonSettings,linuxTitle -->
`Settings › Linux environment`

On this phone's HarmonyOS engine these commands need the Linux environment; see [Engine and remote hosts](03-engine-hosts.md#linux-environment). Check the status on that page:

- **Off**: turn on **Turn on Linux**. The first time, wait until it's ready, then ask the AI to try again; while it's getting ready those commands still fail rather than wait for it.
- The page says the local engine isn't running: start the local engine first.
- The page asks you to reopen the app: tap **Reopen app**, or quit and open it again, then turn it on.
- It says the existing Linux data can't be used any more (usually after an app update): tap **Reinstall Linux** on the same page, then turn on **Turn on Linux**. What was installed inside Linux is deleted; see [Engine and remote hosts](03-engine-hosts.md#linux-environment).
- **Failed**, or it couldn't turn on with a code: include that code and a diagnostics bundle when you report the problem.
- The AI says Linux is busy: Linux runs one command at a time, and a plugin's long-running Python service holds it the whole time, so other commands report busy after a short wait. Turn that plugin off or try later.
- Downloads are slow or can't connect: set a proxy under **Network proxy** on the same page.

On a remote host these commands run on that host, whatever this switch says.

## The pet is gone

- Not in chats: if the pet page is set to **None**, choose a pet; if it's hidden for an hour, tap **Show now**.
- Not outside the app: HarmonyOS can't show the pet outside the app; it stays in the app.

See [Pets](06-pets.md).

## A plugin is installed but doesn't show up

Check that the plugin is enabled, and restart the engine if asked. A plugin's native UI needs the dsh-go bridge on the host: this phone's engine has it built in, remote hosts usually don't. A display place may also be turned off in the plugin's details. Plugin panels without a native UI appear in the Plugins group of All features, opening in the app or as Web entries. See [Plugins](08-plugins.md).

## What the app sends

<!-- nav: commonSettings,hubPrivacy,usageStatsTitle -->
`Settings › Privacy and sharing › Send anonymous usage stats` · [Open](dshgo://open/usage-stats)

Usage statistics aren't sent on HarmonyOS for now. The switch is off and locked, and neither the welcome screen nor an upgrade notice offers it.

## The guide doesn't match what I see

Check the app version under **Version** in Settings and compare it with the version in the [guide index](../README.md). The app is always right.
