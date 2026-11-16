# Tavern

The Tavern is the app's role-play area: import SillyTavern character cards and chat with a character or follow a story. Cards, chats and tavern settings live only on this phone, and it calls the model directly with the DeepSeek API key from Settings — no on-device runtime and no remote host needed.

## Getting in

<!-- nav: chatChats,modeKeyTooltip,tavernTitle -->
`Chats › Switch mode › Tavern`

Tap the **Switch mode** key at the top of the chat list and pick **Tavern** under **Mode**; Back returns to Work. Set **Open on launch** to Tavern and the app opens straight into it. Picking **Chat with characters** the first time you open the app skips installing, goes straight to the tavern and sets this for you.

## Importing

<!-- nav: tavernTitle,tavernImport -->
`Tavern › Import`

**From a file** works out what each file is: character cards (PNG, JSON, CHARX), lorebooks, presets, regex, quick replies and SillyTavern chat records. **From a link** takes a character page on a card site or a direct card-file link. With several files picked, each result is reported; a non-card file opens its import report listing what was noticed while importing.

**Import chats** takes SillyTavern .jsonl files, one or several at a time. Importing an ST theme lives under **Display** in **Tavern settings**.

### Bringing a chat over from DeepSeek

<!-- nav: tavernTitle,tavernImport,tavernImportFromDeepSeek -->
`Tavern › Import › Bring over from DeepSeek`

A long chat that DeepSeek's own app won't continue can be carried over and continued here. Export all chats in DeepSeek's settings to get a ZIP, then either share that file to dsh-Go from a file manager, or tap **Bring over from DeepSeek** under **Import** in the tavern and pick it.

The list is sorted by length with the longest chat already ticked; the button at the bottom opens it, ready for your next line. Each chat becomes a character on the shelf, with the branches left by regenerating and editing kept; replies that were withdrawn or never finished stay, but are no longer sent to the model. A chat brought over before isn't copied again: tapping it opens it.

Continuing uses the model and key you set up in the tavern, billed by the API. A chat brought over asks for a larger context (at least 64K) and a longer reply limit. The model can't see what falls outside the context, so a very long chat keeps its first two messages (skipping withdrawn or unfinished replies) in the character's description, up to 4,000 characters of each.

## Shelf, chats and the character page

The **Shelf** opens with the chats you played most recently — tap **Continue** to pick one up — then the character grid, which can be searched, filtered by tag and sorted once the shelf is full enough.

**Chats** lists every chat, newest first, with **New group chat** at the top (it needs at least two characters on the shelf). Long-press a chat to delete it.

A character card opens its page with three tabs: **Chats** (swipe through the **Greeting**s and tap **Start**, or **Continue where you left off**), **Card** (the card's picture and definition), and **Setup** (its lorebooks, Live2D model and import report). **Edit character** changes only the fields it can edit; what it can't stays as it is when you save, and existing chats don't change.

## Library

<!-- nav: tavernTitle,tavernSectionLibrary,tavernLorebooks -->
`Tavern › Library › Lorebooks`

The **Library** holds **Lorebooks**, **Presets**, **Regex**, the **Default persona** and **Quick replies**. Lorebooks, presets and regex can be imported from files, edited, and tested (which lorebook entries match, what a regex replaces). A lorebook set as global applies to every chat; a card's own lorebooks travel with the card. The **Default persona** is who you play in a chat; long-press to make one the default or delete it.

## Starting a chat

The story (stage and messages) fills the top of the chat page and the composer sits at the bottom. Long-press the send key to **Send as narration** or **Send without a reply**; **Write it for me** next to the composer has the model draft your line, and **Continue writing** lets the last reply go on. **Quick replies** and **Roll dice** sit above the composer: pick the dice and the result goes into the box, to send once you've checked it.

## Replies, branches and message actions

Swipe any character reply left or right for the **Previous reply** and **Next reply**; swiping past the last one equals **Regenerate**. Long-press a message to **Copy**, **Edit**, **Branch from here**, **Regenerate**, **Continue writing**, **Bookmark** it, **Hide from the model**, **Delete just this one** or **Delete this and everything after**, or **See what was sent**. Swiping to another alternative shows a note that you switched to another branch, with an undo.

The **Branches** page draws the story's forks: an indented row is another way out of the end of the row above. Tap a row to switch to it or name it; a branch the story isn't on can be deleted.

## Stage

<!-- nav: tavernTitle,tavernStage -->
`Tavern › Stage`

The **Stage** key at the top right of the chat page opens a side panel with **This chat**, **State**, **Director** and **This turn**:

- **This chat**: the model, **Thinking**, persona, preset, lorebooks, layout and background picture in use; plus **Bookmarks**, **Branches**, **Search this chat**, **Export chat** and **Export as a storybook** (E-book (EPUB), Plain text (TXT) or Long image).
- **State**: what the card defines, as of the current message. This turn's changes are marked (like +5); tap one to see it whole or change it, and the change is kept on that message, so switching replies or branches takes it back. An older card without state lists its variables here.
- **Director**: with **Director runs on its own** on, it reads the story in the background every few turns, keeps **The director's notes** (hidden by default to avoid spoilers) and offers a few suggested replies; you can also **Ask the director now**. **Background log** shows every state change and director run, newest first, up to 100.
- **This turn**: exactly what this turn sent, with the full inspection.

## Group chats

**New group chat** asks **Who's in it**: members are ordered by the order you pick them, and the first one hosts — the story's shared state, director and secrets live on that card; the host need not be among the speakers. The chat shows who is speaking, and **Let them go on** keeps the scene moving; the roster and order are edited in **Group settings**.

## Layout and tavern settings

Each chat can pick its own layout under **This chat** on the **Stage**; the default lives in **Tavern settings**, grouped by purpose:

<!-- nav: tavernTitle,tavernSectionMe,tavernSettings -->
`Tavern › Me › Tavern settings`

- **Model & connection**: the main model, **Flash** or **V4 Pro**, **Thinking** on or off, and the **DeepSeek API key** (the same key as the chat screen; the page points you to fill it in when missing).
- **Generation**: the default preset's **Reply limit** and **Temperature**; a chat that brought its own preset keeps it.
- **Display**: **Layout** (**Bubbles**, **Novel**, **Visual novel**), **Text size**, **Colours**, whether to **Use the card's own look**, **Import an ST theme**, and the switches for HTML panels and the whole-story canvas.
- **Safety**: **No card scripts in those pages** and **Keep those pages offline**, both off by default.
- **Data**: **Back up the whole tavern**, **Restore from a backup**, **Usage** and **Storage**.
- **You**: the **Default persona** and **Quick replies**.

**Open on launch** also sits under **Me** on the tavern's home, deciding whether the app opens straight into the tavern.

## Backup and data

Cards, chats, lorebooks, presets, personas, settings and Live2D models live only on this phone. Under **Data** in **Tavern settings** you can **Back up the whole tavern** (one zip) and **Restore from a backup**; **Storage** breaks the space down by cards, chats, presets and so on. Back up before changing phones, resetting or uninstalling. **Usage** shows the tokens each chat used, cache hits included.

## Things to know

- The tavern talks to DeepSeek directly, not through the on-device engine or a remote host; the key comes from Settings and is shared with the chat screen.
- The tavern doesn't review card or model content; HTML and scripts a card carries run inside its messages. Turn on **No card scripts in those pages** and **Keep those pages offline** under **Safety** to stop them.
- Deleting a character deletes its chats too, after a confirmation; it can't be undone.
- Longer stories cost more: a longer context remembers more and uses more tokens each turn.
