# Chat

Ask the AI anything, send images and files, and steer or stop it while it works. Chats belong to the current host: switch hosts and the list shows that host's chats.

## Start a new chat

<!-- nav: chatChats,commonNewChat -->
`Chats › New chat`

Tap the menu button at the top left of the chat (or swipe in from the left edge) to open the chat list, then tap **New chat**. There's also a new-chat button at the top right of the chat.

Type your message and tap the send button. The chat is created when you send the first message, so opening a new chat never leaves an empty one behind.

With a hardware keyboard, Enter adds a line break and Ctrl+Enter or ⌘+Enter sends. See Hardware keyboard below for more controls.

## Choose a model

On a phone, tap into the composer, then tap the model under it. On a tablet or wider screen, tap the model capsule at the top right. Either way opens **Choose model**. Tap a model to switch right away; if it supports levels, pick one under **Thinking effort**. Typing `/model` in the composer opens it too. **Manage models** at the bottom goes straight to the models page in Settings; to add and manage models, see [Models and providers](02-models.md).

## Images, files and voice

Tap the plus button next to the composer and choose **Photos**, **Take photo** or **File**. You can attach up to 9 items per message. Under **This chat** in the same panel you can change this chat's **Permissions** and turn **Plan mode** on or off; while system actions are on, a **System actions** card is there too, and **Confirmation** in it opens their page.

- On DSH Remote, **File** appears when the host's Remote plugin supports uploads. The app adds no separate 20 MB limit; the normal 200 MB attachment limit still applies. The host decides whether it can accept the file based on its plugin version and current network path (Relay/TURN typically allow up to 20 MB). Files are uploaded in chunks to the current chat's working directory when you send. Existing files are never overwritten; the host assigns a new name on collision. If an upload fails, the question is not sent. Older hosts accept images only; update their Remote plugin and reconnect.
- If the current model can't view images, they're sent to the AI as files. Switch to a model that can view images to let the AI see them.

Tap an image to view it full screen. Pinch to zoom in or out, up to 8x; double-tap to zoom to 2.5x around the touch point, then double-tap again to fit. Swipe left or right through images in the same attachment group, reply or tool output; the page count is shown. Workspace and web images in a reply form separate groups. While zoomed in, dragging pans the picture instead of turning pages; return to fit before swiping. Save and the long-press menu apply to the current picture.

When the composer is empty and speech recognition is available, the send button becomes a microphone. Tap it and speak; your words fill the composer so you can check them before sending. When you're signed in to DeepSeek or have an API key, DeepSeek's recognizer is used by default (the recording is sent to DeepSeek; you're told the first time); otherwise the system's recognition. When the recognition service isn't available, **Change** on the notice opens the voice settings.

## Read aloud and voice calls

Under each reply there is a **Read aloud** key: tap it to hear the reply, tap again to stop. It's also in the reply's long-press menu, and in the tavern when you long-press a character's message. Code blocks, tables and link addresses are left out. DeepSeek's voice is used by default, paid by your signed-in DeepSeek account, or the API key in Settings when signed out; you can switch to the phone's own voice, which costs nothing and works offline:

<!-- nav: commonSettings,voiceSettingsTitle,speechVoiceTitle -->
`Settings › Voice › Reading voice`

**Voice call** in the plus panel opens a call: just speak, pause, and it is sent; the answer is read while it is written. Start talking while the AI speaks and it stops to listen (turn off **Interrupt by speaking** in Settings); tap the light in the middle to skip an answer. At the bottom are **Mute**, **Hang up** and **Speaker** / **Earpiece**. Approvals and questions appear on the call page. The key at the top right changes the **Call background**: **Deep sea**, **My picture**, or your **Companion** from the companion room, who speaks along with the voice. Calls end when the app goes to the background. Live captions during a call come from the HarmonyOS recognizer (Mandarin) on the phone, with no model to download; the end of what you say is judged by volume and pauses, so in a noisy place you may need to pause a little longer. The text sent to the AI still comes from the recognition chosen in Voice settings; a cloud choice uploads the recording.

## Create images and video

When the current host has the image and video plugin, the plus panel has a **Create** tile. Tap it to enter create mode: a capsule above the composer shows the settings, such as "Image · 3:4 · 2 images". Tap the capsule to change the type, model, aspect, number and quality, and for video the length and sound; then describe what you want and send; the settings show under your message. The × on the capsule leaves create mode and keeps what you typed. You can also just ask the AI, "draw a cat napping on the windowsill".

Add reference images from the plus panel as usual. For video, the first image is the **First** frame and the second the **Last** frame.

Created images appear in the chat with a line that says **AI-generated**, the model and the aspect, plus an estimated cost when the price is reliable. Tap an image to view it full screen and swipe through the batch. Under the images you can save to Photos, share or **Regenerate**; More has **Edit**, **Copy prompt** and **Details**. When a description doesn't pass content review, tap **Revise** on the card to get it back in the composer. If an image fails to load, **Reload image** reads the file again without generating again or incurring generation charges. Tapping a video opens the in-app player, where you can play, pause and seek; if it won't play, tap **Open in another app**. Images and videos can both be saved to the gallery; the system asks you to confirm each save. Remote videos download only when you open them, never just for scrolling previews.

If the host doesn't have the plugin yet, **Create** offers **Install on this host**. Services and API keys are set under Capabilities in [Settings](10-settings.md).

## Commands

Type `/` in the composer for the command list, or `@` to reference a file or another chat. Common commands:

- `/compact`: compact the chat above to free up context.
- `/export`: export this chat's full history as a ZIP to share, or to save where you choose in the system dialog.
- `/plan`: enter or leave Plan mode.
- `/goal`: set or view the goal for a long-running task.
- `/permission`: switch the permission preset.
- `/new`, `/model`, `/features`: new chat, choose model, all features.

## Steer or stop the AI while it works

Sending while the AI is replying is a **Steer**: it doesn't interrupt, and the AI sees your message at its next step. Touch and hold the send button to choose a **Send mode**:

- **Steer**: the AI sees it next step, without interrupting
- **Interrupt and send**: stops the current task and handles this first
- **Queue**: sends after this turn

Steered and queued messages appear at the bottom of the chat, where you can **Send now**, **Steer instead** or **Undo**. An undone message goes back to the composer for editing.

While the AI replies with an empty composer, the send button becomes a stop button. Tap it to stop the current turn. Queued messages then start the next turn.

## Answer questions and approvals

Question cards: pick an answer, or tap **Other answer** to write your own, then tap **Submit**. When exactly one question is waiting, with no pending approval, attachments, quote or create mode, you can also answer in the composer; **Send text as an answer** stays visible while you type. Attachments, a quote or create mode show **Send a new message**; choosing another send mode by holding Send still sends a message. Once the host records the answer, the chat keeps an **Answered** receipt with your answer, visible even when the turn’s process is folded.

Approval cards: check the command, files and reason, then tap **Allow once** or **Decline**.

**Allow for chat** approves ordinary tool approvals for the rest of this chat, including requests already waiting. **Auto-approving** appears above the composer; tap it to turn it off. Approvals are asked again after the app restarts. A chat with **Full access** or **Auto review** also shows a capsule above the composer; tap it to change the chat's permissions. To skip approvals in all new chats on this phone's engine, set the new-chat default to **Full access** under Permissions in [Settings](10-settings.md).

### Separate authorization for scheduled tasks

With the patched bundled engine, creating a task or changing its name, instructions or timing requires a separate confirmation. The question shows the complete instructions, rule, time zone and resolved trigger time. Review them, select "授权 / Authorize", then submit. Full access, Auto review and chat-wide auto-approval cannot replace this confirmation. While saving in the task editor, the confirmation appears there; tasks requested in a chat are confirmed in that chat.

Rejection, no answer, a two-minute authorization timeout or an unavailable confirmation interface does not save the change. A trigger time that has already passed must be proposed and confirmed again. A rejected edit leaves the existing task unchanged. Cancelling a save, leaving the editor or switching hosts attempts to reject that page's outstanding requests; it cannot undo an operation another client already confirmed first.

Authorization covers only the displayed task, not arbitrary future actions. It does not reduce the target chat's permissions or replace system isolation of credentials and tool execution. Existing tasks are not retrospectively authorized; inspect them and delete any you do not recognize. Remote hosts need the same engine fix: updating only the phone UI does not enforce authorization on an unpatched remote engine.

## Copy, quote and regenerate

The row under a reply copies, shares, branches and regenerates in one tap. Touch and hold an AI reply for **Copy**, **Select text**, **Quote**, **Share**, **Regenerate** and **Branch here**. Plugins with a native UI add their actions below.

Touch and hold the text of your sent message, then tap **Edit and resend** in the toolbar. **More** opens the full menu.

**Regenerate**, **Branch here** and **Edit and resend** continue in a new chat and leave the original as is. The notice that appears has **Back to original chat**; after it's gone, the original is still in the chat list.

- **Regenerate** works on the last reply of the chat and resends right away. It's unavailable while the AI replies, while messages are steered or queued, or when the question had files attached.
- **Edit and resend** needs attachments added again.

## All features

The round button at the bottom of the chat list opens **All features**, where everything from the web version lives: chat details, files the AI produced, files, the terminal, background tasks, skills, subagents, schedules and more. See [All features](14-all-features.md).

## Organize the chat list

Touch and hold a chat for **Pin**, **Rename**, **Move to folder**, **Share**, **Select**, **Archive** and **Delete permanently**.

- **Archive** stops a turn in progress. Tap **Undo** on the notice within 4 seconds to keep the chat as it was, turn included; leaving the app archives it at once.
- **Delete permanently** removes the chat record from this host and cannot be undone — unlike archive. The working folder, generated files, branched chats, shared attachments and published cloud shares stay; delete cloud shares separately.
- Deletion asks for confirmation first. A running chat must be stopped. Subagent chats are deleted along with the chat; a chat that still has scheduled tasks is refused by the host. It needs a host that supports it: on an older host the action says so and archive stays the only option — it never falls back to archive silently.
- After selecting several chats, **Delete** in the action bar removes them in one go; failures are listed one by one and only acknowledged chats leave the list. If the connection drops and the result is unconfirmed, the rest of the batch stops — refresh the list before deciding.
- To get an archived chat back, tap **Search chats**, find it and tap **Restore and open**.
- Filter the list with **All**, **Running**, **Pending** and **Unread**. The ⋯ at the end of a folder row sorts by **Recent activity** or **Date created**, and has **New folder** and **Manage folders**.

## Swipe-left shortcuts

<!-- nav: commonSettings,hubSettingsInterface,hubQuickPanel -->
`Settings › Interface › Swipe-left shortcuts`

Swipe right to left over the chat and **Shortcuts** slides in from the right; tap one to open that page. It starts with **Plugins**, **Local engine** and **Settings**. Swiping on code blocks, tables and other content that scrolls sideways still scrolls them. Back closes the panel first.

You can turn off **Open with a left swipe**, and under **What it lists** tick what to show and drag to reorder. There's no swipe while the chat list stays open at the side.

With a conversation open, the panel is about that conversation, in two parts, **Info** and **Plugins**: Info has the whole title, workspace, model and host, with the full page a tap away at the top right; Plugins has every plugin panel, switched along its top when there are several. The shortcuts you ticked sit along the bottom. On a phone the header has no model chip, with the status and workspace under the title, and while you type, the composer shows the model and thinking depth at its foot: tap them to change, or use Overview.

## Hardware keyboard

Focus the chat's composer before using these shortcuts:

- Enter: add a line break.
- Ctrl+Enter or ⌘+Enter: send. The numeric keypad's Enter works too. The host must be connected and the draft must contain text or attachments; it won't send while voice input is active.
- While the AI is replying, press Esc twice within half a second to stop the current turn. Holding Esc doesn't count as two presses; one press won't leave the composer.

Send and stop shortcuts don't run while an input method is composing text or choosing a candidate. Finish composing first.

With the `@` reference picker open, ↑ and ↓ select an item, and Enter or Tab inserts it. On a folder, Tab opens the folder instead. Esc closes the picker first; to stop the reply, press Esc twice again after closing it.
