# Engine and remote hosts

DSH can run right on this phone (this phone's engine), or on your computer or server with your phone connecting to it. Chats, workspaces and plugins belong to each host.

## This phone or remote

The first time you open the app, choose how to use it:

- **This phone**: installs the runtime on your phone; everything runs on this phone. The option shows the storage and memory it needs.
- **Remote host**: uses DSH on your computer or server, with nothing installed on the phone. Recommended when the phone is short on memory or storage.
- **Chat with characters**: the tavern only, with nothing installed; the app opens straight into the tavern, now and on later launches. Bringing chats over from DeepSeek starts here too.

You can add DSH to this phone anytime: tap **Install runtime** on the engine page, or tap **This phone** when switching hosts. Stay on that page while it installs; it starts once installed.

## This phone's engine

<!-- nav: commonSettings,hubSettingsEngine -->
`Settings › Local engine` · [Open](dshgo://open/engine)

- **Start**, **Stop**, **Restart**: stopping asks first; both stopping and restarting interrupt active chats.
- If the engine fails to start, the page shows the cause and ways to fix it, such as retrying, **Enter Safe mode**, **Restore configuration** or viewing logs.
- **Start when DSH Go opens**: on by default. As long as DSH is installed on this phone, opening the app starts it, even while you use a remote host. Turn it off if you don't need that.
- **Start in Safe mode**: enter Safe mode by hand. It starts with the default configuration that comes with the app, without the plugins you installed. Your chats stay and your own configuration isn't changed, though a global patch or `.env` can still affect the start. Once fixed, tap **Return to normal mode**. If the engine has already started since the app opened, entering and leaving both reopen the app; the dialog says so.
- Safe mode never starts by itself. After several unclean exits in a row the engine won't start on its own, and the failure card offers **Restore configuration**, **Enter Safe mode** and **Retry**.
- **Logs**: the engine's live output.
- **Background running** and **Diagnostics**: see [FAQ](11-faq.md).

## Linux environment

<!-- nav: commonSettings,linuxTitle -->
`Settings › Linux environment`

Runs command-line tools such as gh and Python on this phone. This row exists only on HarmonyOS, in the Capabilities group of the settings home; it can be turned on only while the local engine runs.

- Turn on **Turn on Linux**. The first time downloads a 3.5 MB base system and installs it, which takes a minute or two; the switch shows the step it is on: downloading the base system, preparing disks, starting, installing tools. After that it starts in seconds.
- The switch is remembered: left on, Linux comes back on by itself each time the local engine starts.
- While Linux is on, the app uses roughly 100 MB more memory. Turning it off gives that back; turning it on again then needs the app reopened.
- When the page asks you to reopen the app (after you turned the switch off, including while it was getting ready), tap **Reopen app** or quit and open it yourself; then Linux can be turned on again.
- When the page says the existing Linux data can't be used any more (usually after an app update), tap **Reinstall Linux**. It deletes everything inside Linux: installed software and Python packages, files that exist only inside Linux, and accounts signed in there (such as gh); files in your chat workspaces aren't touched. It works while the switch is off or turning on failed; if Linux already started in this run of the app, turn the switch off and reopen the app first. Afterwards the switch stays off, and turning it on downloads and installs Linux again.

While it's on, `gh`, `python3`, `python`, `pip` and `pip3` run by the AI in chats on this phone's engine go to this Linux, and so do Python processes that plugins start; run anything else with `linux <command>`, for example `linux sh -c '…'`. `bash`, `git`, `rg` and `node` still run in the app's own command environment. While it's off, those commands report that the Linux environment is off; nothing is installed for you.

Commands in Linux see the chat's workspace at the same paths; when the chat's permission is **Read only**, the workspace is read-only in Linux too. Linux runs one command at a time, and `pip` is slow to start: it can take tens of seconds. Chats on remote hosts don't use this Linux.

**Network proxy** applies only to commands inside Linux. Choose a **Mode**:

- **Same as app** (default): uses the local engine's proxy when it has one, otherwise connects directly.
- **No proxy**: connects directly.
- **Manual**: enter an **HTTP proxy**, an **HTTPS proxy** (**Same as HTTP** when left empty) and **Bypass for** (NO_PROXY, comma-separated, such as `example.com,10.0.0.0/8`). Proxy addresses start with `http://` or `https://`, such as `http://127.0.0.1:7890`; `127.0.0.1` means this phone, not your computer, and a proxy app on the phone needs `http://`. Clearing both proxies goes back to **No proxy**.

Gitee, Huawei Cloud and other mirrors in China always connect directly. The proxy is saved only on this phone, and a change applies to the commands that follow.

Resetting or uninstalling the runtime doesn't delete what is installed in Linux; **Reinstall Linux** or uninstalling the app does. If it won't turn on, see [FAQ](11-faq.md).

## Reset the runtime

<!-- nav: commonSettings,hubSettingsEngine,phoneEngineReset -->
`Settings › Local engine › Reset runtime`

Deletes data on this phone and reinstalls the runtime, to fix a runtime that won't start. In the dialog:

- **Keep interface settings and skills**: on by default.
- **Keep installed plugins and settings**: off by default.

With the defaults, chats, workspaces, plugins and settings are deleted, including custom model providers. Anything else in the home folder goes too, including files in your workspaces, `AGENTS.md` and data that plugins store themselves, such as memories. Your host list, app settings and saved keys aren't affected. The dialog spells out what will go; tap **Delete and reset** and the app reopens and finishes the reset as it opens. If it still needs reopening, the engine page says so: tap **Reopen**. The local engine won't start until then. A reset can't be undone, so export chats you need first with `/export` or **Export chat log** in All features.

## Uninstall the runtime

<!-- nav: commonSettings,hubSettingsEngine,localEnvUninstall -->
`Settings › Local engine › Uninstall runtime`

Deletes the unpacked runtime and local data. Chats, workspaces, plugins, settings, interface settings and skills on this phone are all deleted, the app reopens, and nothing is reinstalled. The copy of the runtime inside the app package stays; only uninstalling the app frees it. To use this phone's engine again, tap **Install runtime** on the same page. If you only need a break, stop the engine and turn off **Start when DSH Go opens**.

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

In managed mode, testing starts or reuses DSH on the host, and it keeps running afterwards. **Attach only** opens an SSH tunnel to the specified port on remote `127.0.0.1`. It never discovers instances, starts, stops or restarts DSH, or reads/writes managed state files. Start the instance yourself first and keep it running. If connection fails, check the port and token; the app never restarts it as a repair. The token stays on this phone, like the password and private key.

Managed mode refuses to replace a live instance whose start command differs or launch log is missing. A rejected token or refused reused port never authorizes a restart either. Check the settings or use **Attach only** first. If you really intend to replace the app-recorded instance, choose **Restart managed DSH** in the DSH section of Edit host and confirm. This may interrupt other clients and active chats; normal **Test connection** never performs it. Confirmed dead managed processes can still be started automatically.

**SSH compression** is on by default, negotiating compression after authentication. Unsupported servers continue uncompressed. Turn it off in the host form if needed; save and establish a new SSH connection to apply.

To change or delete a host, tap **Edit** next to it to open **Edit host**; **Delete this host** is at the bottom. Deleting removes only the settings, password, key and launch token saved on this phone; DSH and chats on the host stay.

## DSH Remote

No network setup, end-to-end encrypted. Good for computers on another network.

1. Install the remote plugin in the host's DSH and sign in.
2. On the remote hosts page, choose the same sign-in provider you used on that host, for example “Continue with GitHub”, and sign in with the same account. If the page lists no providers and shows only **Sign in in browser**, tap that button.
3. Select an online host. On first connection, check that the identity fingerprint matches the one the host's remote plugin shows, then tap **Trust and connect**.

When the server supports it, the remote hosts page shows **Pair a computer by scanning**: sign in to DeepSeek in the app, tap **Scan** to open the system scanner, scan the code shown by the computer’s Remote plugin, check the computer fingerprint, then enter the verification code as prompted. The scanner is the system’s own page and uses the camera itself, so DSH Go asks for no camera permission; if the code is in a screenshot, pick it from photos inside that page. You can also copy the pairing link and tap **Paste pairing link**. If the system scanner can't open, the app tells you to paste the link instead.

This version goes through the relay, end-to-end encrypted the whole way, not over LAN, P2P or TURN. Tap the route label on the connection card or beside a Host to see the actual route, connection time and available round-trip latency. Unmeasured values are not shown as zero.

<!-- nav: commonSettings,commonRemoteHost,remoteCompactHistory -->
`Settings › Remote host › Compact history`

**Compact history** is off by default. Supporting DSH Remote Hosts summarize historical tool arguments and output to reduce history transfer; message text, live replies, approvals and original Host records stay unchanged. Switch to another host (or this phone) and back, or restart the app, to apply. The current client and its automatic reconnects retain their original mode to avoid mixing cached history. After turning it off, select the host again and reopen the chat to load full history. Older Hosts continue sending full history; SSH is unaffected.

DSH Remote connects to one host at a time; switching disconnects the previous one. Over DSH Remote: you can send images only, DSH Web doesn't open in the app, plugins can only be turned on or off, and DS Bot and chat log export aren't available.
