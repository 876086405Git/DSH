# Sharing and replay

Share a chat as a link, an image, a file or text. Chat files and links you receive replay in the app, and you can pick up the conversation from there.

## Share

In the row under an AI reply, tap:

<!-- nav: commonShare -->
`Share`

Touching and holding a chat in the chat list, or choosing **Share** in a delivered file's menu, opens the same panel. From the chat list, it starts at **Entire chat**.

1. Choose what to share: **This reply**, **Selected** messages or the **Entire chat**. For selected messages, tap **Edit** to add or remove; touch, hold and drag to pick a run at once.
2. Choose what to include: **Thinking**, **Tool calls** and **Images** (all on by default). This one setting applies to every option below; the preview card updates, and the line under it shows the message count and that secrets are hidden.
3. Choose how to share: **Link**, **Image**, **File** or **Text**.

### Link

End-to-end encrypted; the server can't see your content. Choose **7 days**, **30 days** (default) or **Forever** and tap **Create link**. Then **Copy link**, show the **QR code**, **Share** it, or **Stop sharing**: after you confirm, you have 4 seconds to tap **Undo**. If you don't, deletion starts after that window; the link stops working once deletion succeeds.

### Image

Pick a template and whether to show the **Question** and **Model and steps**, then **Save image** or **Share**.

### File

Choose a **Chat file** (`.dshgo`, to replay and continue in DSH Go), a **Web page** (opens in any browser, even offline) or Markdown (plain text, readable anywhere). **Preview** it if you like, then **Save** (choose where in the system dialog) or **Share**.

### Text

With **This reply**, sends the reply as written; with selected messages or the entire chat, sends a Markdown transcript.

Links and files can be up to 4 MB; select less if it's over.

Sharing always masks keys, tokens and passwords in URLs, and replaces your user name in home folders with `~`, the same way for every option. Anyone with the link, image, file or text can see what's in it. Stopping sharing doesn't remove copies people already saved. Pictures a reply refers to are drawn only in an image; files, web pages and links show their alt text.

## Manage shared links

<!-- nav: commonSettings,hubPrivacy,remoteHostedMyLinks -->
`Settings › Privacy and sharing › My shared links` · [Open](dshgo://open/shared-links)

Lists links made on this phone, with their expiry. A link can be deleted only from the phone that made it: after uninstalling the app, clearing its data or switching phones, it can't be deleted, and a **Forever** link stays up. After you delete one and confirm, it disappears right away and you have 4 seconds to tap **Undo**; if you don't, deletion starts after that window and the link stops working once deletion succeeds. If deleting fails, the link comes back with the reason. Expired links leave the list after 30 days.

If you change the range or options after creating a link, the link on the panel clears, but the one already created still works. Delete it here if needed.

## Replay and continue

Open a `.dshgo` file or DSH Go share link with DSH Go to replay it:

- It plays automatically. Pause, drag the progress bar, and switch between 1×, 2× and 4×. When it ends, tap **Replay**.
- Tap **Full chat** to see the whole conversation at once.
- Tap **Continue chat** to start a new chat with this replay attached as a Markdown transcript (one summary line per tool call, without thinking or tool output) and a line ready in the composer. Check it, then send. Files and tool state from the original chat aren't restored.

**Continue chat** isn't shown in the preview of your own share. If the current DSH Remote host does not support file uploads, the transcript is dropped. Otherwise it is uploaded to the current workspace when you send, subject to the normal attachment limit and the host's actual limits.
