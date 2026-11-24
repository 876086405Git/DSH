# Terminal

The conversation's terminal: run commands in the same workspace the agent uses. Commands run on the host — the on-device engine on this phone, or a remote host on your computer or server.

The terminal belongs to the open conversation, so open one first.

<!-- nav: catalogAllFeatures,catalogTerminal -->
`All features › Terminal`

The page shows **Terminal** over the current directory, a row of tabs, the terminal below, and a key row above the keyboard.

## Tabs

- Opening the page restores the terminals kept on the host one by one; if there is none, it starts a new one.
- Each tab is a separate terminal on the host. It stays on the host; closing the phone page doesn't stop it.
- Leaving the page only disconnects the view: commands keep running on the host, and coming back reattaches.
- Closing a tab ends its process. A tab whose process has exited stays ended and does not restart on its own.

## Keys

The key row above the keyboard sends the terminal's common control keys, such as interrupt, exit, completion and arrow keys. For a modifier combination, tap the modifier first, then the key.

Tap the terminal to reopen the on-screen keyboard, or choose **More**, then **Show keyboard**. Long-press and drag on terminal text to select a range, then tap **Copy**. To paste clipboard text into the current terminal without selecting any text, choose **More**, then **Paste**.

## Notes

- Commands run as the host's user and can read and write files there; the app doesn't ask you to confirm each command.
- If a remote host disconnects, its terminal keeps running; reconnect and open the page to attach again.
- Stopping or resetting the on-device engine also ends the processes in its terminals.

Related: [Engine and remote hosts](03-engine-hosts.md).
