# Engine and remote hosts

DSH can run right on this phone (this phone's engine), or on your computer or server with your phone connecting to it. Chats, workspaces and plugins belong to each host.

## Running in the background on iPhone

The local engine continues after leaving the app only while the system actually allows background execution. A playing, unsuspended picture-in-picture pet and an accepted continued-processing task are independent sources; ending one must not clear the other. An enabled switch, downloaded assets or a previously visible PiP does not prove current execution permission.

Pet PiP is off by default and is not a prerequisite for phone control or pet selection; native phone tasks request system continued execution directly. If you explicitly enable PiP on the phone-control page and choose to keep it after tasks, it can also support ordinary local chats. Start a real PiP from the foreground before switching apps. If PiP closes, pauses, the device locks or audio is interrupted, and no other system execution grant remains, the engine pauses at its next tool boundary. iOS can still suspend or terminate the app; permanent uptime is not promised.

PiP does not approve tools, disable safe mode or resume a phone task you manually paused. Return to the app for confirmations; restoring PiP does not approve a previous request. An engine on a remote host does not depend on the iPhone's PiP.

## Linux and Python on iPhone

<!-- nav: commonSettings,hubSettingsEngine -->
`Settings › Local engine` · [Open](dshgo://open/engine)

On iPhone, find the **Linux environment** section on that page.

Install the optional environment, then restart the local engine. It uses Alpine. Installing the environment does not also install Python, git or rg. Commands have a different available set when Linux is missing or paused; check its actual status first.

You can explicitly ask a local chat to install Python and pip:

```sh
apk add python3 py3-pip
python3 --version
python3 -m pip --version
```

Installing packages changes the Linux system and needs approval for that system write. Workspace-write permission does not replace it. Inspect the actual download, installation or execution error; do not reset, uninstall or change pairing settings to address a missing package. The Linux environment does not grant arbitrary access to other iOS apps.

## This phone or remote

The first time you open the app, choose how to use it:

- **This phone**: installs the runtime on your phone; everything runs on this phone. The option shows the storage and memory it needs.
- **Remote host**: uses DSH on your computer or server, with nothing installed on the phone. Recommended when the phone is short on memory or storage.
- **Chat with characters**: the tavern only, with nothing installed; the app opens straight into the tavern, now and on later launches. Bringing chats over from DeepSeek starts here too.

You can add DSH to this phone anytime: tap **Install runtime** on the engine page, or tap **This phone** when switching hosts. It starts once installed.

## This phone's engine

<!-- nav: commonSettings,hubSettingsEngine -->
`Settings › Local engine` · [Open](dshgo://open/engine)

- **Start**, **Stop**, **Restart**: stopping asks first; both stopping and restarting interrupt active chats.
- If the engine fails to start, the page shows the cause and ways to fix it, such as retrying, **Start in Safe mode** or viewing logs.
- **Start when DSH Go opens**: on by default. As long as DSH is installed on this phone, opening the app starts it, even while you use a remote host. Turn it off if you don't need that.
- **Automatic Safe mode**: on by default. After two failed starts in a row, starts without plugins.
- **Start in Safe mode**: enter Safe mode by hand. Once fixed, tap **Return to normal mode**. Entering and leaving both restart the engine.
- **Logs**: the engine's live output.
- **Background running** and **Diagnostics**: see [FAQ](11-faq.md).

## Updates and installed tools

Normal engine updates replace only app-managed engine components, without rebuilding your Linux system. Apt tools such as gh, npm global packages in their default location, Python/pip packages, settings and workspaces stay. Bundled DSH, Node, pnpm, the bridge and their dedicated directories remain app-managed; do not install your own software there. A Node version change may still require rebuilding third-party native extensions: preserving files does not guarantee extension compatibility.

Older runtimes are adopted after checking the architecture, Ubuntu version and Python. If compatibility cannot be confirmed, the update manifest is invalid, or a leftover process has not stopped, the update stops with an explanation. It never automatically wipes or rebuilds the environment. Retry an interrupted installation; do not delete recovery directories by hand.

Before changing the base system, make a full backup. Diagnostics bundles and exported chat logs are not environment backups. A complete backup must be taken with the engine stopped, include Linux files, permissions, symlinks, package databases and the home directory, be stored outside the runtime, and have a checked read/restore procedure. The app does not currently offer one-click full environment backup/restore. On a compatibility warning, keep the environment intact and contact the maintainer for help with offline export; do not reset or uninstall the app. Keeping the original environment is not an independent backup: clearing app data or uninstalling still loses it.

## Reset the runtime

<!-- nav: commonSettings,hubSettingsEngine,phoneEngineReset -->
`Settings › Local engine › Reset runtime`

Deletes data on this phone and reinstalls the runtime, to fix a runtime that won't start. In the dialog:

- **Keep interface settings and skills**: on by default.
- **Keep installed plugins and settings**: off by default.

With the defaults, chats, workspaces, plugins and settings are deleted, including custom model providers; the DeepSeek key saved in the app is filled back in. Anything else in the home folder (`/root`) goes too, including files in your workspaces, `AGENTS.md` and data that plugins store themselves, such as memories. The dialog spells out what will go; tap **Delete and reset** and the app reinstalls the runtime. A reset can't be undone, so export chats you need first with `/export` or **Export chat log** in All features.

## Uninstall the runtime

<!-- nav: commonSettings,hubSettingsEngine,localEnvUninstall -->
`Settings › Local engine › Uninstall runtime`

Frees up storage. Chats, workspaces, plugins, settings, interface settings and skills on this phone are all deleted, and nothing is reinstalled. To use this phone's engine again, tap **Install runtime** on the same page. If you only need a break, stop the engine and turn off **Start when DSH Go opens**.

## Switch hosts

Open the chat list and tap the current host's name at the bottom to open **Switch host**, then choose **This phone** or a remote host. With no remote hosts yet, tap **Connect a computer or server**; otherwise tap **Manage remote hosts**.

Tap the icon to the left of the host name for details: remote hosts show their name, connection status and current network path, with an on-demand latency measurement where supported. For this phone, it opens **Local engine**. The host name and dropdown arrow still switch hosts.

<!-- nav: remoteSwitchHost,remoteManageHosts -->
`Switch host › Manage remote hosts` · [Open](dshgo://open/remote)

It's in Settings too:

<!-- nav: commonSettings,commonRemoteHost -->
`Settings › Remote host`

On launch, the app reconnects to the host you used last. To start on this phone every time, turn off **Connect to the last host** on the remote hosts page; saved hosts stay, and you can connect to them by hand any time.

## Add an SSH host

The host needs SSH enabled and DSH installed (`npm i -g @deepseek-ai/dsh`).

1. On the remote hosts page, tap **Add SSH host**.
2. Enter the **Host** and **Username**. **Port** defaults to 22. The name is optional.
3. Sign in with a **Password** or a **Private key**. You can **Import from file**, and add a **Private key passphrase (optional)**. Passwords and keys stay on this phone.
4. **Instance management** defaults to **Managed**: **Start command** defaults to `dsh web`; if you installed DSH with nvm, enter its full path. For an instance you manage yourself, select **Attach only** and enter its **Remote DSH port** and **DSH launch token** from its launch URL. **Working directory (optional)** is where new chats start; use an absolute path in attach-only mode.
5. Tap **Test connection**. The first time, **Trust this host?** appears: check the fingerprint on the host, and tap **Trust and connect** if it matches.
6. Tap **Save**, then select the host in the list.

In managed mode, testing starts or reuses DSH on the host, and it keeps running afterwards. **Attach only** opens an SSH tunnel to the specified port on remote `127.0.0.1`. It never discovers instances, starts, stops or restarts DSH, or reads/writes managed state files. Start the instance yourself first and keep it running. If connection fails, check the port and token; the app never restarts it as a repair. The token stays in secure storage on this phone, like the SSH password and private key.

Managed mode refuses to replace a live instance whose start command differs or launch log is missing. A rejected token or refused reused port never authorizes a restart either. Check the settings or use **Attach only** first. If you really intend to replace the app-recorded instance, choose **Restart managed DSH** in the DSH section of Edit host and confirm. This may interrupt other clients and active chats; normal **Test connection** never performs it. Confirmed dead managed processes can still be started automatically.

**SSH compression** is on by default, negotiating compression after authentication. Unsupported servers continue uncompressed. Turn it off in the host form if needed; save and establish a new SSH connection to apply.

To change or delete a host, tap **Edit** next to it to open **Edit host**; **Delete this host** is at the bottom. Deleting removes only the settings, password, key and launch token saved on this phone; DSH and chats on the host stay.

## DSH Remote

No network setup, end-to-end encrypted. Good for computers on another network.

1. Install the remote plugin in the host's DSH and sign in.
2. On the remote hosts page, choose the same sign-in provider you used on that host, for example “Continue with GitHub”, and sign in with the same account. If the page lists no providers and shows only **Sign in in browser**, tap that button.
3. Select an online host. On first connection, check that the identity fingerprint matches the one the host's remote plugin shows, then tap **Trust and connect**.

When the server supports it, you can also choose **Pair a computer by scanning**: sign in to DeepSeek in the app, scan the code shown by the computer’s Remote plugin, check the computer fingerprint, then enter the verification code as prompted. Camera permission is only for capturing the QR code; reading an image from photos or pasting the pairing link still works without it. Opening the scanner initializes the shared ML Kit SDK on demand, without requiring or enabling phone control’s text recognition. See the [FAQ](11-faq.md#local-text-recognition-and-google-ml-kit) for SDK statistics disclosures.

Connections automatically try LAN / P2P, then TURN, and finally Relay without a direct-connection switch. Each path requires compatible server and Host support. Tap the route label on the connection card or beside a Host to see the actual route, connection time, available round-trip latency and fallback reason. WebRTC routes also show the selected ICE candidates' phone/Host IPv4 or IPv6 and UDP or TCP, never raw IP addresses. Unmeasured or unconfirmed values are not presented as known results.

<!-- nav: commonSettings,commonRemoteHost,remoteCompactHistory -->
`Settings › Remote host › Compact history`

**Compact history** is off by default. Supporting DSH Remote Hosts summarize historical tool arguments and output to reduce history transfer; message text, live replies, approvals and original Host records stay unchanged. Switch to another host (or this phone) and back, or restart the app, to apply. The current client and its automatic reconnects retain their original mode to avoid mixing cached history. After turning it off, select the host again and reopen the chat to load full history. Older Hosts continue sending full history; SSH is unaffected.

DSH Remote connects to one host at a time; switching disconnects the previous one. Over DSH Remote: you can send images only, DSH Web doesn't open in the app, plugins can only be turned on or off, and DS Bot and chat log export aren't available.
