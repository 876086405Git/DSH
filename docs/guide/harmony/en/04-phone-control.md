# System actions

HarmonyOS has no phone control; it has system actions instead. From a chat, the AI can open apps and system pages, send notifications and write the clipboard, and it hands back the steps that are yours. It doesn't see the screen or tap inside other apps: the system doesn't allow that.

So HarmonyOS has no accessibility service, floating bar, app rules, lifted limits or non-disruptive mode. System actions only work in the local engine's chats, not while you're connected to a remote host.

## Turn it on

<!-- nav: commonSettings,systemActionsTitle -->
`Settings › System actions` · [Open](dshgo://open/system-actions)

Turn on the switch at the top of the page. The first time, it explains what it can do, when, who gets the results, what it never does and how to stop; tap **Agree**. You can also pick it when choosing permissions the first time you open the app.

Once on, the top of the page says where things stand; if it isn't working, see [FAQ](11-faq.md). Turn it off here anytime.

## What it can do

- Open an app or link: apps by package name, not by display name.
- Calendar, dialer, share, navigation: opens the system page; the last step is yours.
- Some system settings pages: mobile network, display, sound, NFC and this app's notifications.
- Send a notification: sending it doesn't mean you've seen it.
- Write the clipboard: write only, never read.
- Alarms and timers: where this version has system reminders, they're listed under What it can do. The system reminds you when it's time, and the engine doesn't run for it. The system can still say no, for example if the service isn't turned on or it's at its limit, and the AI is told.
- Hand back to you: you do steps like sign-in or codes, then press **Continue**.

## What it can't do

- See the screen or tap inside other apps: the system doesn't allow it.
- Read the clipboard, find apps by name, SMS: no reliable public API; the AI is told it's not supported.
- Alarms and timers, on a version or device without system reminders: What it can't do says so.

## Confirmation

**Confirmation** is always **Follows permissions**, with nothing else to pick: it follows the chat's permissions, so it usually asks each time, and not with full access. For permissions, see Permissions in [Settings](10-settings.md). The last step of a call, a share or a calendar event is always yours, in the system page.

## Only with DSH Go on screen

The system doesn't let background apps do these. After the AI opens another app, it can't go on until you're back in DSH Go.

## Your turn

When **Your turn** appears, do the step, come back to DSH Go and press **Continue**. That only says you confirmed; the AI can't see what happened in other apps. To end it, press **Stop**.

## Results and the log

Results go back to the chat and to the model you chose. They describe the system call: a page that opened doesn't mean the thing is done, and if the result is unknown the call may have gone out, it won't retry on its own, and it's worth checking yourself.

**Recent actions** at the bottom of the page records what ran and how it ended, not the content.
