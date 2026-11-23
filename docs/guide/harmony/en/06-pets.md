# Pets

Pick a pet to keep you company in chats. When a turn finishes, fails, or waits for your approval or answer, it pops up a bubble.

## Choose a pet

<!-- nav: commonSettings,botsPets -->
`Settings › Pets` · [Open](dshgo://open/pets)

Tap **Pets** in the Appearance group of Settings, or touch and hold the pet in a chat and choose **Pet settings**. Choose a pet first; the other settings appear below it.

- Choose **Deepy**, **Whale girl**, **Pink fish** or **None**.
- **Size**: **Small**, **Standard** or **Large**. Standard by default. If a pet looks too small or too big, choose **Custom** and drag the slider to 50–300% of Standard; the preview above follows, and it saves when you let go.
- **Quiet mode**: animations only, no bubbles.

On HarmonyOS the pet stays in the app: it can't show outside the app, and there's no floating pet to ask or to answer in.

## In chats

- The pet sits above the composer; drag it left or right to move it.
- Tap a bubble to jump to its chat; swipe up to dismiss it.
- Touch and hold the pet for **Change pet**, **Hide for 1 hour** and **Pet settings**. While it's hidden, **Show now** appears on the pet page.

## Companion room

The companion room is a separate full page with an animated Live2D character. It isn't the status pet above: the pet watches the agent for you, and the room is a place to spend a little time.

Tap the **Switch mode** button at the top of the chat list, then **Companion room**; if you've set a startup mode, the app opens straight into it. When the app comes with her, she swims in by herself the first time; after you remove her from the menu at the top right of the room, you can bring her back or import another asset pack (zip). Her assets stay on this phone.

On HarmonyOS she can't live in a floating window.

On HarmonyOS, open the room from its home-screen card and use voice in the composer. The default digital assistant entry is available on Android.

What you can do:

- Touch her: stroke her head to pat it, and tap her face, body or tail for different reactions. Three quick pokes make her dizzy. None of this calls a model or spends tokens.
- Move the phone: tilt it to one side and she drifts that way with the water, tips over a little, then finds her balance. Shake it hard a few times and she gets dizzy and lets out a stream of bubbles. None of this happens when the phone has reduced motion turned on, and shaking does nothing on phones without a motion sensor.
- Talk to her: type or use voice in the bar at the bottom. Choose how in **How she talks** in the menu at the top right:
  - **Light**: chat only. The phone uses the DeepSeek API key you saved in Settings to talk to the model directly, with no engine and no host. The chat stays on this phone, and **Start over** deletes it. Not available when you signed in with a DeepSeek account and saved no key.
  - **Full**: uses DSH on the current host, in its own conversation that stays out of the chat list. **View chat history** in the menu opens it, and **Start over** begins a new conversation while the old record stays on the host. She can use the host's tools; anything that acts asks you first.
  - Until you choose, she uses Full while a host is connected and Light otherwise.
- Zoom: pinch to zoom and move.
- Her corner: there's a snack in the shell at the bottom left, a bubble floating on the right, and a seaweed cushion behind her. Tap the shell to give her a snack, the bubble to play, and the cushion to let her rest for a while. What she's doing shows under her name.
- Feed her, hold her: drag a snack out of the shell dish and let go at her mouth, and she eats it. Rest a finger on her to give her a hug. Tilt the phone and the reef shifts a little.
- Her voice: turn on **Let her speak** under **Her voice** in the menu and she reads her words aloud; she stops as soon as you type or use the microphone. On HarmonyOS she uses **The phone's own** voice, which works offline; DeepSeek, external speech services and voice cloning aren't there yet. Tap **Preview** to check it works.
- About her: under **About her** in the menu, change her name, what she calls you, and her persona: who she is, her personality, how she talks, all of it, with **Reset** to start over. The default persona includes a few boundaries you can delete; only the format of her expression marks is added by the app.
- Getting closer: visit and pat her often and she slowly gets more familiar with you; **You two** in the menu shows how far you've come. Once you're close she hums more and has fonder words for a pat.
- Your other chats: while the room is open, she tells you when another chat finishes, fails or waits for your approval; tap Take a look to go there.
- Her invitations: when you sit quietly with her for a while, she may now and then ask, above the input bar, whether you'd like to rest on the cushion together. Tap **Sure** and she leans back on it; tap **Not now** or just leave it, and she waits a while before asking again. She asks silently. Choose how often in **How often she speaks up** in the menu at the top right: **Now and then** by default (at most twice a day, at least 6 hours apart), **Often** or **Chatty** for more, **Quiet** for none. Mentions of your other chats count toward the same allowance.
- Home-screen card: add the Companion room card to your home screen to see what she's doing and the last thing she said; tap it to visit. The card updates only while the app is running.

She notices that you visit and pat her, and slowly gets more familiar with you; staying away for a few days doesn't upset her. Write down things you want her to remember in **What she remembers** in the menu. You can edit or delete them anytime. In Full mode they stay on the current host; in Light mode, on this phone. She doesn't bring these up by herself yet, and can't touch your files or phone.

If this host's engine is older, she runs on the default preset and may ask to use tools. When "Something needs your confirmation" appears, tap it and handle the request in the regular chat.

## Workshop

The Workshop holds pixel pets and companions other people made. Pick the ones you like and install them on this phone, or send in your own. There are two ways in: the **Workshop** row on the pet settings page, and **Workshop** in the menu at the top right of the companion room. If the row isn't there, this version isn't connected to a workshop yet.

The page has three tabs:

- **Browse**: look around, search, and filter by **Pixel pets** or **Companions**. Tap an item for its description, author, license and size, and tap **Get** to download and install it. A pet is added to the pets you can choose, and a companion becomes the character in the room; you're asked first when something already on this phone would be overwritten. Browsing and installing need no sign-in.
- **Installed**: what came from the Workshop onto this phone. A new version, or an item withdrawn by its author or a reviewer, is marked here; open an item to update or uninstall it. This tab works offline.
- **My uploads**: what you sent in and where each one stands in review. Sign in with your GitHub account first.

To submit: tap **Submit** under **My uploads**, pick a pet you imported, your current companion, or tap **Choose a file** to pick a pet or companion zip directly (no need to import it first; a file in the wrong format is turned away right there). Only a name is needed: the English name, ID, author, license and source link are optional, and when left empty they become the other name, an ID made from the name, your GitHub username, Author permission and your GitHub page. Then check the packed result, tick **I confirm I have the right to share this** and send it. A pet uses its first idle frame by default; you can turn it off. The app tries to capture just the character for a companion and renders a sample conversation for a theme. Review, replace, or remove a companion or theme cover before submitting; you can still submit if generation fails. Once it passes the format checks it is listed right away under **Browse**; if someone reports it, a reviewer looks and takes it down with a reason if needed. To take one back, open it and tap **Withdraw**.

If the phone's record of an unfinished submission can't be read, or keeps failing to clear, that step offers **Let go of this record**. It only deletes the record on this phone (if the phone's submission records can't be read as a whole, it clears the unfinished records of every account on this phone, and the confirmation says so) and doesn't ask the Workshop to cancel anything: if the Workshop already received the submission, it stays under **My uploads**; if not, you'll need to submit again.

Submitting, viewing your uploads and reporting need a GitHub account. Tap **Sign in with GitHub** and the app shows a code: open GitHub's verification page, enter the code and authorize, then come back to the app. This sign-in can only read your public GitHub profile (username and account number), not your repositories. It is kept on this phone; you can sign out in **My uploads**, and to withdraw the authorization completely, revoke it under Applications in your GitHub settings.

The first time you submit, view your uploads or report something, the app also asks you to confirm one thing: the Workshop tells who you are by your GitHub account, by sending your GitHub sign-in credential to the Workshop service, which asks GitHub whose it is. The page shows both addresses, the Workshop's and GitHub's, and the credential isn't sent to the Workshop until you tap **Agree and continue**. You can browse and install without agreeing.

If something is wrong with an item (infringement, unsuitable content), tap **Report** in its details and say why. A reviewer handles the report; an item isn't taken down automatically because it was reported.
