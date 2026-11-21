# Web mode

Use the full DSH Web interface inside the app, and switch back to the native interface anytime. Switching keeps the current host and chat, and the app remembers your choice next time.

## Switch interfaces

<!-- nav: commonSettings,hubSettingsInterface -->
`Settings › Interface` · [Open](dshgo://open/interface)

Under **Home**, choose **Native** or **Web** to switch right away. You can also tap the button next to New chat at the top of the chat list to go straight to Web.

Going to Web brings the current chat along, or starts a new one in Web if none is open. Coming back brings the chat you were viewing in Web. DSH Web on a DSH Remote host is the exception: it opens on its home page without the chat, and switching back doesn't bring back the chat you viewed there.

## App features in Web mode

Tap the app logo at the top left of the page (above the sidebar on wide screens, at the top right when the engine isn't running) to open the DSH menu:

- **Switch to native**: back to the current chat.
- **App settings**: the app's full settings.
- **Switch host**: change hosts; the current one is shown on the right.

## Phone layout

<!-- nav: commonSettings,hubSettingsInterface,hubInterfacePhoneLayout -->
`Settings › Interface › Phone layout`

On by default: adapts DSH Web to phone screens, folding the sidebar into a menu button in the header on narrow screens. Turn it off for DSH Web's original layout. The page reloads when you change it.

## Open Web once

<!-- nav: commonSettings,hubSettingsInterface,hubInterfaceOpenWeb -->
`Settings › Interface › Open the web app`

In the native interface, opens the current host's DSH Web without changing your interface; **Web** in All features does the same. In Web mode, it takes you back to the current host's Web page.

## Web display and sending

Further down **Interface** are DSH Web's own options, kept in the current host's engine and read only by DSH Web: under **Web display**, **Show coding view**, how work steps show and when they fold, and performance and usage; under **Web sending**, how messages send while the AI works and how links open. They appear once a host is connected.

## If it won't open

- **This phone**: if the engine isn't running, tap **Start engine**; if DSH isn't installed on this phone, tap **Install runtime**.
- **SSH hosts**: DSH Web appears once the host is connected.
- DSH Remote hosts: the host needs DS Harness Remote plugin 0.6.6 or later with DSH Web running; see [Open DSH Web on a Remote host](03-engine-hosts.md#open-dsh-web-on-a-remote-host).
