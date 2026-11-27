# 更新日志 · Changelog

每个版本先中文、后英文。发版时把对应版本的正文（不含版本标题）作为 Release 正文，见 `docs/release.md`。

## 1.4.1 · 2026-11-27

### 中文

#### 改进

- **对话显示解码速度。** 每轮结束的脚注、用量弹层和对话详情新增 `tokens/秒`（输出 token ÷ 解码时长，与单步详情同一口径）；子代理数量按会话谱系统计。
- **远程主机后台连接。** 连上远程主机后由独立的前台服务维持连接：切到后台或息屏不再受 App 自设时限，也不会顺带启动本机引擎。后台运行页新增「远程连接保活」，可选静音音频和保护性后台定位（默认关闭，定位只用大致位置，不保存也不发送坐标）。
- **状态显示更清楚。** 远程主机时顶栏把「主机连接」和「会话同步」分开显示，中继连接直接显示实际线路。

#### 修复

- **DS Bot 走中继。** 中继上通过 `dsBot/call`、`dsBot/feed` 访问 DS Bot（需要远端 Host 插件包含 ds-harness-remote#605）；只对可以安全重放的读操作重试，操作不会被执行两次。
- **更新检查。** 多个官方源并行比较，选出版本最新的一个，旧的内测源不会再挡住 GitHub 正式版；打开 App 和从后台返回都会检查（成功检查后 24 小时内不重复）；检查失败时，已下载的安装包仍可校验并安装。
- **OpenAI 订阅渠道支持图片。** ChatGPT 订阅渠道按官方声明的模型能力接收图片，可以直接发图。
- **创意工坊投稿。** 可以投稿主题包，也可以直接选择 ZIP；投稿完成后回到「我的投稿」并看到这一条。
- **tawcroot 启动。** 显式的 `/dev/shm` 绑定优先，不再被进程内的共享内存模拟覆盖。
- **鸿蒙。** 修复真机图像打包、Inspector 与生命周期同步。

#### 验证情况

这版改动大多只经过自动测试和编译检查；1.4.1 的测试包在一台 vivo X200 Pro（Android 16）上装过并启动。远程主机后台保活、DS Bot 中继、OpenAI 订阅图片和更新检查需要相应的主机或账号，尚未逐项在真机上验证。

### English

#### Improvements

- **Decoding speed in chats.** The end-of-turn footnote, the usage sheet and the conversation details now show `tokens/sec` (output tokens ÷ decoding time, the same measure as the step details), and the subagent count comes from the conversation lineage.
- **Remote hosts in the background.** Once connected, a dedicated foreground service keeps the remote link alive: leaving the app or turning the screen off no longer runs into a self-imposed limit, and the local engine is not started. The background page gains remote connection protection — silent audio and protective background location, both off by default; location is coarse only and is never stored or sent.
- **Clearer status.** With a remote host, the header shows the host link and the conversation sync state separately, and relay connections show the actual route.

#### Fixes

- **DS Bot over the relay.** DS Bot is reached through `dsBot/call` and `dsBot/feed` on relay hosts (the remote host plugin must include ds-harness-remote#605); only reads that are safe to replay are retried, so an action is never executed twice.
- **Update checks.** Official sources are compared in parallel and the newest release wins, so a stale beta feed can no longer hide the GitHub release; checks run at launch and on returning to the app (at most once per 24 hours after a successful check); when a check fails, an already downloaded package can still be verified and installed.
- **Images with an OpenAI subscription.** Models on the ChatGPT subscription channel now take images according to their declared capabilities.
- **Workshop submissions.** Theme packs can be submitted, or a ZIP picked directly; a finished submission lands back in My uploads with the new entry.
- **tawcroot launch.** Explicit `/dev/shm` binds take precedence instead of being shadowed by per-process shared-memory emulation.
- **HarmonyOS.** Fixed on-device image packaging, the Inspector and lifecycle sync.

#### Testing

Most of this version has only been checked by automated tests and builds; the 1.4.1 test build was installed and started on a vivo X200 Pro (Android 16). Remote background protection, DS Bot over the relay, images on the OpenAI subscription and update checks need the matching host or account and have not each been verified on a real device.

## 1.4.0 · 2026-11-25

### 中文

#### 新功能

- **伙伴小屋有了完整模式。** 伙伴可以在自己的 DSH 会话里工作，小屋里能直接看进度、打电话或打开她的主会话。也可以养多个伙伴，或在 Android 上把伙伴设为系统默认助理。
- **Android 手机操控有了悬浮岛和手机技能。** 操作进度能显示在屏幕顶部或支持的系统灵动岛里。完成任务后，可以把做法保存成手机技能，下次直接调用。
- **OpenAI 官方渠道。** 支持的 Android 本机引擎可以用 ChatGPT 账号授权订阅，选用该账号可用的模型。
- **酒馆和外观。** 补充了 SillyTavern 1.19 预设与 SPreset 支持。创意工坊的主题包可以改更多界面细节，壁纸也支持动图。
- **iOS 实时活动。** 可以在锁屏和灵动岛查看进度。

#### 修复与改进

- 修复远程主机网页版偶尔打不开、部分连接断开后无法恢复的问题。
- 修复终端键盘无法重新唤起、复制粘贴异常，以及部分 vivo 手机上手机操控无法读回结果的问题。
- 减轻长对话和流式回复时的卡顿，修复通话字幕偶尔截断表情的问题。

### English

#### New features

- **Full mode in the companion room.** Your companion can work in her own DSH session. See progress, call her or open her main session from the room. You can keep multiple companions or set your companion as Android’s default assistant.
- **Floating island and phone skills on Android.** See phone control progress at the top of the screen or in the system island on supported phones. After a task, you can save the steps as a phone skill and use it again later.
- **Official OpenAI channel.** On supported local Android engines, sign in with a ChatGPT account to authorize your subscription and use the models available to it.
- **Tavern and appearance.** Expanded SillyTavern 1.19 preset and SPreset support. Workshop themes can customize more of the interface, and wallpapers can be animated.
- **iOS Live Activities.** See progress on the Lock Screen and Dynamic Island.

#### Fixes and improvements

- Fixed cases where a remote host’s web app failed to open or a dropped connection failed to recover.
- Fixed reopening the terminal keyboard, copying and pasting, and reading phone control results back on some vivo phones.
- Reduced stutter in long chats and streaming replies. Fixed call captions occasionally cutting off emoji.

## 1.3.0 · 2026-11-21

### 中文

- **顶栏一键语音通话。** 首页右上角、新对话按钮旁边多了通话按钮，新对话里也能直接打。
- **长按就能选字。** 长按回复或自己发的消息直接选中按到的词，拖两端改范围；选区上有复制、引用、分享、朗读、全选，「更多」里是原来的消息菜单。自己发的消息也能引用了。朗读选中的文字时，里面的密码、密钥不会念出来。
- **远程主机：对话备份和网页版。** 远程主机页可以把主机上的对话加密备份到手机，再恢复到原来的或另一台主机（每次恢复新建对话，不覆盖；附件和工作区源码不迁移）。主机支持时，还能在 App 里直接打开主机的 DSH 网页版，不用把登录凭据交给浏览器；服务繁忙时会提示「人太多了，请稍后重试」。
- **后台保护（需要自己打开）。** 设置里新增后台运行保护，默认关闭。打开后本机长任务切到后台更不容易被系统杀掉，被系统收回时如实显示，不会假装还在运行。iOS 可以选静音音频或后台定位来保活，都要自己授权，不保存也不上传位置。
- **酒馆。**
  - 支持酒馆助手脚本库：全局、预设、角色卡里的脚本都能运行。预设的脚本能拿到 SillyTavern 的事件和当前预设，像小猫之神这类预设的菜单现在能出来；脚本面板在画布里显示，开关会写回预设。
  - 大卡明显不卡了：重卡导入、卡库列表、长历史显示快了数倍，卡库占用减少约三分之二。前端卡只渲染屏幕上看得见的消息，写回复时少了很多多余重建。新增「省电渲染」开关（酒馆设置 › 显示，默认关）：关掉卡片网页里的毛玻璃，循环动画只播一遍。
  - 上下文满了一次裁掉一截，而不是每条都裁，模型的缓存能持续命中，更快也更省钱（默认开）。
  - 前端卡的开场白不再显示成一堆代码；深色模式下卡片颜色和网页文字看得清；酒馆界面统一了间距、样式和文案，加了克制的动效。
- **伙伴小屋更清晰。** 小屋按屏幕本身的像素密度渲染（之前最多按 2 倍），卡顿时临时降低的清晰度流畅后会自己升回来。
- **新桌宠「小粉鱼」。** 第三只内置宠物，带 18 种状态动画和 3 段待机小动作；切换动作时淡入淡出。
- **分享长图。** 分享成图片时保留完整正文，生成一张长图，不再截掉后半段。
- **本机引擎默认用 tawcroot 启动**（Android 10 及以上）：启动更快；起不来会自动退回原来的兼容启动（PRoot），不弹故障卡。之前手动关过的保持原样。卓易通上 PRoot 启动失败时，故障卡上会出现「用 tawcroot 启动」。
- **修复。** 升级到 1.1.0 后本机新建对话失败；本机用久了会话列表超过 8 MB 就整个加载失败；配了多台 DNS 时第一台拒绝就联网失败；插件配置里 API Key 填不进去；Android 10 用 Shizuku 授权后手机操控报「身份改变」；HyperOS / Android 16 一直 60 Hz（刷新率设置现在也作用到画面本身）；APK 已下好但空间只够一份时误报空间不足；同一路径的图片被覆盖后，旧消息里显示成新图；模型列表接口返回 404 时现在会提示可以手动添加模型；模型选择里过长的名字显示不全；伙伴自动想起记忆时误把子代理配置当成对话内容；桌宠、悬浮窗菜单、伙伴小组件和网页岛的几处显示问题。
- **验证情况。** 这一版的新功能大部分只经过自动测试和编译检查，tawcroot 默认启动、后台保护、远程备份和网页版都没有在各种真机上完整走过。iOS 安装包等 CI 编完会补到这个版本下；鸿蒙 HAP 这一版仍不提供。遇到问题请导出诊断并开 issue。

### English

- **One-tap voice call in the top bar.** A call button sits next to New chat in the top right, and works from a new chat too.
- **Long-press to select text.** Long-press a reply or your own message to select the word under your finger, then drag the handles. The selection bar has Copy, Quote, Share, Read aloud and Select all; More opens the usual message menu. Your own messages can be quoted too. Reading a selection aloud skips any passwords or keys in it.
- **Remote hosts: chat backup and the web app.** The remote host page can back up the host's chats to the phone, encrypted, and restore them to the same or another host (each restore makes a new chat and overwrites nothing; attachments and workspace source are not moved). When the host supports it, you can open its DSH web app inside the app without handing your credentials to a browser; when the service is busy it says so and asks you to try later.
- **Background protection (opt-in).** Settings has a new background protection option, off by default. When on, long local tasks are less likely to be killed in the background, and when the system takes the time back the app says so instead of pretending the engine is still running. On iOS you can choose silent audio or background location to keep it alive; both need your permission, and location is never stored or sent.
- **Tavern.**
  - Tavern Helper script library: scripts from global settings, presets and character cards all run. Preset scripts get SillyTavern's event source and the current preset, so menus from presets such as Meowssiah now show up; the script panel shows in the canvas and its switches are written back to the preset.
  - Large cards no longer stutter: importing heavy cards, the card library list and long histories are several times faster, and the card library takes about a third of the space. Frontend cards only render the messages on screen, and writing a reply triggers far fewer rebuilds. A new Power-saving rendering switch (Tavern settings › Display, off by default) turns off frosted glass in card pages and plays looping animations once.
  - When the context fills up, it is trimmed in one larger step instead of one message at a time, so the model's cache keeps hitting: faster and cheaper (on by default).
  - Frontend cards' opening messages no longer show as raw code; card colors and web text are readable in dark mode; the Tavern screens have consistent spacing, styles and wording, with restrained motion.
- **Sharper companion room.** The room renders at the screen's own pixel density (it was capped at 2x before), and resolution lowered during stutters comes back once things are smooth.
- **New pet: Pink Fish.** A third built-in pet with 18 state animations and 3 idle moments; switching animations now fades.
- **Long share images.** Sharing as an image keeps the whole message and makes one long image instead of cutting off the end.
- **The local engine starts with tawcroot by default** (Android 10 and later): faster to start; if it can't start, the app falls back to the compatible launcher (PRoot) on its own without an error card. If you turned tawcroot off before, that is kept. On Zhuoyitong, when PRoot fails to start the error card offers Start with tawcroot.
- **Fixes.** New local chats failing after upgrading to 1.1.0; the local chat list failing to load once it grew past 8 MB; no network when the first of several configured DNS servers refused; API keys that couldn't be entered in plugin settings; phone control reporting "identity changed" on Android 10 after Shizuku authorization; HyperOS / Android 16 stuck at 60 Hz (the refresh rate setting now applies to the drawing surface too); a false out-of-space error when the APK was already downloaded; older messages showing the new image after a file at the same path was overwritten; a 404 from the model list now says models can be added by hand; long model names cut off in the model picker; the companion's automatic memory recall mistaking subagent settings for conversation; several display issues in pets, the floating menu, the companion widget and web islands.
- **Testing.** Most new features in this version have only been checked by automated tests and builds; tawcroot by default, background protection, remote backup and the web app have not been fully tried on a range of real devices. The iOS package will be added to this release once CI finishes; there is still no HarmonyOS HAP in this version. If you run into a problem, please export diagnostics and open an issue.

## 1.2.0 · 2026-11-18

### 中文

- **iOS 版（测试）。** 这一版起提供未签名的 iOS 安装包 `dsh-go-1.2.0-ios-unsigned.ipa`，需要用爱思助手、AltStore 等工具自己签名后安装。用免费 Apple ID 签名时 Bundle ID 会被改掉，部分能力（如 Siri、分享扩展、后台）可能用不了。iOS 版只在少数真机上试过，问题请开 issue。
- **鸿蒙版合入主线。** 鸿蒙版的代码已经和安卓、iOS 共用一套，这一版暂时不提供 HAP 安装包，签名就绪后再补到这个版本下。
- **酒馆。** 酒馆助手的接口补齐，支持原生 MVU 变量；能把 DeepSeek 网页里聊不下去的对话导入酒馆接着聊；导入大卡和长聊天时明显不卡了。
- **让 AI 做一只宠物。** 宠物页新增「让 AI 做一只宠物」：带上自己的素材（GIF、逐帧图、Aseprite 导出或单张图），AI 会把它转成宠物包；转换时保留中文动画名，网页模式也能用。
- **按你问过的话搜索会话。** 会话搜索能搜到你自己问过的话和回复摘要，句子中间的中文词也能搜到。
- **手机操控确认改成三档**：允许一次、本轮允许、取消；设置里可以列一份「始终允许」的 App。停止只作用于当前这一轮，下一轮自动恢复。免确认模式下截图和点击不再弹卡。
- **长回复更流畅。** 长回复分块显示，流式输出时只重排最后一块。
- 其他改进：选 English 时 App 写给引擎的 AGENTS.md 也用英文；伙伴包的大小上限放宽，投稿失败会说清原因；桌面小组件的默认文字跟随 App 语言；跳过的版本换了更新源后也算跳过。
- **修复。** 安卓引擎在某些情况下重启被锁死；DeepSeek 的拒绝回复和无名错误被当成网络错误；生成图片时网关返回空链接导致图片丢失；首次 DNS 失败占用当天的生成额度；回合结束但没有答复时没有任何提示；Windows 主机的盘符路径和链接打不开、长文件名存不到手机；换启动画面或壁纸时旧文件被提前删掉；快速切换主机后最近会话停在上一个；未发出的草稿丢失；读屏无法点击详情页签和主题选项。
- **验证情况。** iOS 版和鸿蒙版都只在 CI 里编译并跑过模拟器测试，真机只做过零星试用；安卓版的新改动大部分只经过自动测试。遇到问题请导出诊断并开 issue。

### English

- **iOS (testing).** Starting with this version there is an unsigned iOS package, `dsh-go-1.2.0-ios-unsigned.ipa`, which you sign yourself with a tool such as AltStore before installing. Signing with a free Apple ID changes the bundle ID, and some features (such as Siri, the share extension and background work) may not be available. The iOS version has only been tried on a few real devices; please open an issue if something goes wrong.
- **HarmonyOS joins the main line.** The HarmonyOS code now shares one code base with Android and iOS. This version doesn't ship a HAP yet; it will be added to this release once signing is ready.
- **Tavern.** The Tavern Helper interfaces are complete, with native MVU variables; conversations that ran out of room on the DeepSeek website can be imported into Tavern and continued; importing large cards and long chats no longer stutters.
- **Have the AI make a pet.** The pets page has a new Have the AI make a pet entry: bring your own art (GIFs, frame sequences, Aseprite exports or a single image) and the AI turns it into a pet pack; Chinese animation names are kept, and it works in web mode too.
- **Search chats by what you asked.** Chat search finds your own questions and reply summaries, including Chinese words in the middle of a sentence.
- **Phone control confirmation has three choices**: allow once, allow for this turn, or cancel, and Settings can keep a list of always-allowed apps. Stop only applies to the current turn; the next turn starts fresh. Screenshots and taps no longer show a card when confirmation is off.
- **Smoother long replies.** Long replies are rendered in blocks, and while streaming only the last block is laid out again.
- Other improvements: with English selected, the AGENTS.md the app writes for the engine is in English too; companion pack size limits are looser and failed submissions say why; the home screen widget's default text follows the app language; a skipped version stays skipped after switching update source.
- **Fixes.** The Android engine getting stuck on restart in some cases; DeepSeek refusals and unnamed errors being reported as network errors; images lost when the gateway returned an empty link; a first DNS failure using up the day's generation budget; no notice when a turn ended without an answer; drive-letter paths and links from Windows hosts not opening, and long file names not saving to the phone; the old file being deleted too early when changing the launch screen or wallpaper; recent chats sticking to the previous host after switching quickly; unsent drafts being lost; screen readers not being able to tap detail tabs and theme options.
- **Testing.** The iOS and HarmonyOS versions have only been compiled and run on simulators in CI, with only occasional tries on real devices; most of the new Android changes have only been checked by automated tests. If you run into a problem, please export diagnostics and open an issue.

## 1.1.0 · 2026-11-15

### 中文

- **语音：朗读、语音输入和语音通话。** 回复可以用 DeepSeek 的声音朗读，输入框可以说话输入，也可以直接和她语音通话。通话里能随时打断她，她会自己判断你说完了再接话，有实时字幕；「停顿多久算说完」可以选，默认多等一会儿。通话中可以换声音和识别方式。用账号登录时语音接口不认账号，会改用 API Key。
- **酒馆：玩法包和做卡工具。** 新增玩法包；做卡时可以让 AI 改卡、挑着应用改动、看历史版本、看最终提示词，还能先试玩。长对话不再越聊越卡（显示、用量统计、读对话都快了很多）。支持工具回合和自定义模型渠道，数值可以手填；回复长到顶栏下面时顶栏会加遮罩。
- **手机操控：悬浮条和不打扰模式。** 操控时屏幕边缘换成柔和的色带；悬浮条可以拖动、贴边，小球闲置时半藏在边上。不打扰模式选好通道、连上就能用，不再被一整套准入检查拦住；主屏读不到当前应用时改成确认一次，不再直接拒绝。
- **使用统计 v3。** 新增酒馆、伙伴小屋、语音通话和 token 用量。
- **桌宠更活泼。** 反应有多种动画，彩蛋在各种状态下都能触发，新增「搬东西」动作。
- 其他新功能：创意工坊的投稿改用 GitHub 账号登录，默认连接 go.dshtui.com；自定义启动画面在填满模式下可以缩放和调整位置；新增九个界面特效。
- **修复。** 进语音通话闪退；发给模型的内部提示不再出现在对话里；远程连接点「重连」立刻重连；伙伴小屋在旧版系统 WebView 上打不开、记忆保存的回包丢了列表不刷新；悬浮宠物在系统重新允许动画后不动；从系统设置打开实时活动回来后不补发；自动检查更新时中途关掉仍弹更新页；深色模式下分段选择器的滑块看不见；子代理都停了标题栏的忙碌点还在转；DeepSeek 图片附件丢失被当成网络错误。引擎运行时的 proot 升到 5.1.107.102（主要是硬链接模拟的修复）。
- **验证情况。** 语音、悬浮条、不打扰模式和 proot 升级只在自动测试和编译检查里验证过，没有在真机上完整走过。遇到问题请导出诊断并开 issue。

### English

- **Voice: read aloud, voice input and voice calls.** Replies can be read aloud in DeepSeek's voice, you can dictate in the input box, or call her directly. During a call you can interrupt her at any time; she works out when you've finished before answering, with live captions. How long a pause counts as finished is adjustable and defaults to waiting a little longer. You can change the voice and the recognition method mid-call. When signed in with an account the speech service won't accept, it falls back to your API key.
- **Tavern: play packs and card authoring.** Play packs are new. While making a card you can have the AI revise it, pick which changes to apply, browse past versions, see the final prompt and try it out first. Long chats no longer slow down as they grow (display, usage and loading are all much faster). Tool turns and custom model providers are supported, numbers can be typed in, and the top bar gets a scrim when a long reply scrolls under it.
- **Phone control: overlay bar and Do Not Disturb.** The screen edge shows a soft band while the app is in control; the overlay bar can be dragged and docked to an edge, and the ball tucks half away when idle. Do Not Disturb works as soon as a channel is chosen and connected, without the old admission checks; when the home screen can't tell which app is in front, it asks you once instead of refusing.
- **Usage stats v3.** Adds Tavern, the companion room, voice calls and token usage.
- **Livelier pets.** Reactions have several animations, easter eggs trigger in every state, and there's a new carrying action.
- Other new features: Creative Workshop submissions now sign in with GitHub, and the workshop connects to go.dshtui.com by default; a custom launch screen in fill mode can be zoomed and repositioned; nine new interface effects.
- **Fixes.** A crash on entering a voice call; internal notes meant for the model no longer show up in the chat; Reconnect for remote connections reconnects right away; the companion room failing to open on older system WebViews, and its memory list not refreshing when a save reply was lost; the floating pet staying still after the system re-enables animations; the live activity not being re-posted after returning from system settings; the update page still appearing when an automatic check was turned off midway; the segmented control's thumb vanishing in dark mode; the busy dot in the title bar spinning after all sub-agents had stopped; a lost DeepSeek image attachment being reported as a network error. The engine runtime's proot is now 5.1.107.102 (mostly fixes to hard-link emulation).
- **Testing.** Voice, the overlay bar, Do Not Disturb and the proot update have only been checked by automated tests and builds, not fully on a real phone. If you run into a problem, please export diagnostics and open an issue.

## 1.0.16 · 2026-11-13

### 中文

- **酒馆：新的角色扮演模式。** 抽屉顶栏的「模式」键可以在工作、伙伴、酒馆之间切换，设置 › 界面 › 启动时进入可以选默认进哪个。兼容 SillyTavern 的角色卡、预设、世界书、正则和聊天记录：导入卡（文件、分享、卡站链接）或自己写一张；对话有气泡、小说、视觉小说三种排版，支持备选、接着写、帮我写、分支和书签；资源库里管理预设、世界书、正则、人设和快速回复。消息里的 HTML 在隔离的网页里显示，相关安全开关默认关。
- **创意工坊。** 宠物设置和伙伴小屋的菜单里多了「创意工坊」：浏览、安装大家做的像素宠物和伙伴，不用登录；也可以投稿自己做的，先审后发，有问题的作品可以举报。投稿、查看自己的投稿和举报要用论坛账号，第一次会先说明会把什么发给工坊服务，同意后才发。
- **悬浮伙伴。** 宠物的「App 外显示」可以选「小屋里的她」，让伙伴小屋的角色待在悬浮窗里。悬浮窗里点一下是互动，连点两下才打开对话（像素宠物也改成这样）；伙伴小屋会跟着手机倾斜和摇晃动。悬浮伙伴比像素宠物更耗电。
- **tawcroot 加速启动（实验，默认关）。** 在 诊断 › 开发者选项 里打开后，本机引擎改用 tawcroot 启动：在测试手机上启动从约 5 秒降到约 1.5 秒，装包和 apt 也更快。起不来时自动改用原来的方式，不算启动失败；和「直接启动」二选一。关掉后的第一次启动会先把它留下的文件整理一遍。
- **超长工具输出只显示头尾。** 几万行的命令输出不再把对话卡住：中间折叠，点「查看全部」在单独的页面里看全文，可以跳到开头或末尾、复制全部。
- **酒馆后续：群聊和整页画布。** 可以建群聊，按发言人轮流，视觉小说按说话人换舞台。整页画布（酒馆设置里试用，默认关）能在隔离的网页里跑卡自带的 HTML 和脚本，兼容酒馆助手常用的接口；卡脚本要你输入或选按钮时用 App 自己的对话框。舞台面板可以播放卡里的音乐。每条回复显示按 DeepSeek 官方价估算的费用（高峰、低谷分开，节假日会算高一点），可以设单回合费用提醒，默认关。
- **手机操控：后台屏和 Shell 连接能自己恢复。** 第一次连接失败后不再一直不可用，App 升级后不再复用旧服务；后台资源残留时也能完成释放，不再永久卡住（#1096、#1104）。手机操控页精简了：只显示当前缺的权限或连接步骤，Root、Sui 这类不常用的项需要时再展开，自检改成单独一页。
- 其他新功能：可以删除已归档的会话；已安装插件可以筛选；自定义渠道支持自定义请求头（也用于模型发现）；SSH 主机支持认证后压缩和连接已有实例；更新窗口可以导出已下载的安装包，给需要自己重签的手机兜底；Shizuku 和本机 ADB 可以直接完成自更新；新对话首页的建议可以关掉。
- **大量稳定性修复。** 这一版合入了一百多处运行时、桥接、媒体和更新流程的修复，主要是：直接启动模式下会话、附件、媒体和文件的落盘；磁盘满时的提示和恢复；请求中途断开、进程被杀后的恢复；日志和诊断包里的凭据打码；更新下载被重定向到另一个域名后超时不生效；带「保留」的重置不再丢掉硬链接过的文件内容。聊天、终端、插件、设置和无障碍另有约六十处修复。后来又合进一批：定时任务里「每月倒数第 N 个某天」「每周第 N 个工作日」和普通星期、序数星期混写时算错日期；Web 斜杠菜单里技能消失、改了默认预设后第一条消息仍用旧预设、Web 搜索 key 保存失败却当成功；进程中途被杀留下的空锁、空标记和自更新残留；开着 tawcroot 时升级引擎误报不兼容。
- **验证情况。** 较早的一版测试包在一台手机（vivo X200 Pro，Android 16）上跑过一遍主要功能；之后合进来的后台屏连接重写、资源释放、酒馆群聊和整页画布，以及上面最后那批修复，没有在真机上验证过。大部分修复只经过自动测试和编译检查；直接启动在部分手机上（包括这台）仍会被系统拦下，届时自动改用兼容启动。遇到问题请导出诊断并开 issue。

### English

- **Tavern: a new role-play mode.** The Mode button in the drawer's top bar switches between Work, Companion and Tavern, and Settings › Interface › Open on start picks the default. It is compatible with SillyTavern character cards, presets, lorebooks, regex scripts and chat logs: import a card (file, share or card-site link) or write your own. Chats can be laid out as bubbles, a novel or a visual novel, with alternatives, continue, write-for-me, branches and bookmarks. The library manages presets, lorebooks, regex, personas and quick replies. HTML inside messages is shown in an isolated web view, and the related safety switches are off by default.
- **Creative Workshop.** Pet settings and the companion room's menu now have Creative Workshop: browse and install pixel pets and companions others made, with no sign-in needed, or submit your own. Submissions are reviewed before they appear, and you can report a problem item. Submitting, viewing your submissions and reporting use your forum account; the first time, the app explains what it will send to the workshop service and only sends it after you agree.
- **Floating companion.** A pet's Show outside the app can now be set to the companion from the room, so she stays in the floating window. In the floating window a single tap interacts and a double tap opens the chat (pixel pets work the same way now). The companion room also reacts to tilting and shaking the phone. The floating companion uses more battery than a pixel pet.
- **tawcroot fast launch (experimental, off by default).** Turn it on under Diagnostics › Developer options and the local engine starts with tawcroot: on the test phone, startup went from about 5 seconds to about 1.5, and package installs and apt are faster too. If it can't start, the app falls back to the usual method, which doesn't count as a start failure. Only one of it and direct launch can be on. The first start after turning it off tidies up the files it left behind.
- **Very long tool output shows only its start and end.** Command output tens of thousands of lines long no longer bogs the chat down: the middle is folded, and View all opens the full text on its own page, where you can jump to the start or end and copy everything.
- **More Tavern: group chats and the full-page canvas.** You can start a group chat with speakers taking turns, and the visual novel layout changes the stage with the speaker. The full-page canvas (a trial switch in Tavern settings, off by default) runs a card's own HTML and scripts in an isolated web view and supports the Tavern Helper interfaces cards commonly use; when a card script asks you for input or a button, the app's own dialogs handle it. The stage panel can play a card's music. Each reply shows an estimated cost at DeepSeek's official prices (peak and off-peak priced separately; public holidays come out a little high), and you can set a per-turn cost alert, off by default.
- **Phone control: the background screen and Shell connection recover on their own.** A first failed connection no longer leaves them unavailable, and an app update no longer reuses the old service. Leftover background resources can now be released instead of staying stuck (#1096, #1104). The phone control page is simpler: it shows only the permission or connection step that is missing, rarely used items such as Root and Sui expand when needed, and the self-check has its own page.
- Other new features: archived chats can be deleted; installed plugins can be filtered; custom providers support custom request headers, also used for model discovery; SSH hosts support compression after authentication and connecting to an existing instance; the update sheet can export the downloaded package as a fallback for phones that need to re-sign it themselves; Shizuku and local ADB can complete self-updates directly; the suggestions on the new-chat start page can be turned off.
- **Many stability fixes.** This version brings in over a hundred fixes to the runtime, bridge, media and update flow, mainly: how sessions, attachments, media and files are written in direct launch mode; messages and recovery when storage is full; recovery after a request is cut off or the process is killed; masking credentials in logs and diagnostics; the timeout not applying after an update download is redirected to another domain; and a reset that keeps your files no longer losing the contents of hard-linked files. Chat, terminal, plugins, settings and accessibility get about sixty more fixes. A later batch adds: scheduled tasks computing wrong dates for rules like the last-but-N weekday of a month, the Nth workday of a week, or plain and numbered weekdays mixed; skills vanishing from the web slash menu, the first message after changing the default preset still using the old one, and a failed web search key save being treated as success; empty locks, empty markers and self-update leftovers when the process is killed midway; and a false incompatibility report when upgrading the engine with tawcroot on.
- **How this version was checked.** An earlier test build went through the main features on one phone (vivo X200 Pro, Android 16). What was merged after it, the rewritten background screen connection, resource release, Tavern group chats and the full-page canvas, and the last batch of fixes above, hasn't been tried on a real phone. Most fixes have only been through automated tests and compile checks. Direct launch is still blocked by the system on some phones (including that one), and the app then falls back to compatible launch. If you hit a problem, please export diagnostics and open an issue.

## 1.0.15 · 2026-11-10

### 中文

- **从这一版起，更新引擎不再清空 Linux 环境。** 这次运行时又有改动，所以还是下整包；但更新时只替换 App 管理的引擎部分（DSH、Node、pnpm、桥接和它们的目录），用 `apt` 装的工具、默认位置的 npm 全局包、Python / pip 包、配置和工作区都会保留。从 1.0.14 升上来就生效。Node 版本变了时，第三方原生扩展仍可能要重新编译。
- **如果更新停下来了，先别重置。** App 确认不了现有环境和新引擎兼容、更新清单损坏，或者旧进程没停干净时，会停止更新并说明原因，原环境原样保留。按提示重试；还不行就导出诊断并开 issue，不要重置环境或卸载 App。
- **匿名使用统计多报两项：手机型号和厂商系统版本。** 型号是系统给的代号（如 `V2405A`），系统版本如 OriginOS 5.0、HyperOS 2.0，用来看问题集中在哪些机型和系统上。不含序列号、Android ID 这类能认出某一台手机的信息，仍可在「隐私与分享」里关掉。
- **这一版没有在真机上验证过。** 上面这套保留环境的更新流程和扫码配对只经过自动测试和编译检查。遇到问题请开 issue 反馈。
- 扫码配对电脑：修好相机打不开、从相册识码报 `MlKitContext has not been initialized` 的问题（#802）。扫码前会按需准备 ML Kit，不需要打开手机操控的「本机文字识别」，也不会改它的开关；SDK 出错和图里没有二维码会分开提示。
- 引擎和运行环境：上一次启动迟到的日志不再混进这次的故障快照和诊断；停止和自动安全模式同时发生时，状态不会被旧的「正在停止」盖回去；停止后迟到的刷新不会把已撤掉的前台通知发回来；持久终端的就绪判断不再受系统时间跳变影响。
- 通知和视频：审批点过、结果还没回来时重发的通知保留你的决定，显示「正在处理」，不再给按钮；上一次申请迟到的失焦回调不会再暂停刚恢复的视频。
- 其他修复：永久删除对话时一并删掉迁移留下的临时正文；最近会话的桌面快捷方式迁移失败时保留旧入口，下次再试（#22）；Agent Team 冷恢复时，子 agent 已领取的初始输入不再被判失败（实验功能）。

### English

- **From this version on, updating the engine no longer wipes the Linux environment.** The runtime changed again, so this is still a full download, but an update now replaces only the engine parts the app manages (DSH, Node, pnpm, the bridge and their folders). Tools installed with `apt`, npm global packages in the default location, Python and pip packages, configuration and workspaces are kept. This already applies when updating from 1.0.14. When the Node version changes, third-party native extensions may still need rebuilding.
- **If the update stops, don't reset.** When the app can't confirm the existing environment works with the new engine, the update manifest is damaged, or old processes haven't stopped, it stops the update, says why and leaves the environment as it was. Retry as it suggests; if it still fails, export diagnostics and open an issue rather than resetting the environment or uninstalling the app.
- **Anonymous usage stats now include two more items: the phone model and the maker's system version.** The model is the code the system reports (such as `V2405A`), and the system version is something like OriginOS 5.0 or HyperOS 2.0; they show which phones and systems problems cluster on. Nothing that identifies a single phone, such as a serial number or Android ID, is included, and you can still turn the stats off in Privacy and sharing.
- **This version hasn't been verified on a real phone.** The update flow that keeps the environment and pairing by scanning have only been through automated tests and compile checks. If you hit a problem, please open an issue.
- Pair a computer by scanning: fixed the camera not opening and gallery scans failing with `MlKitContext has not been initialized` (#802). ML Kit is prepared on demand before scanning; you don't need to turn on the phone control's on-device text recognition, and its switch isn't changed. An SDK failure and an image with no QR code are now reported differently.
- Engine and runtime: late log lines from the previous start no longer end up in this start's failure snapshot and diagnostics. When stopping and automatic safe mode happen together, an old Stopping state no longer overwrites the current one. A late refresh after stopping no longer brings back a foreground notification that was already removed. The persistent terminal's readiness checks are no longer thrown off by the system clock jumping.
- Notifications and video: a notification re-sent after you answered an approval but before the result came back keeps your decision and shows Processing, with no buttons. A late focus-loss callback from an earlier request no longer pauses a video you just resumed.
- Other fixes: deleting a chat for good also removes the temporary text left by migration. If moving the recent-chat home screen shortcuts fails, the old entry stays and it tries again later (#22). In Agent Team cold recovery, initial input a sub-agent had already taken is no longer marked failed (experimental feature).

## 1.0.14 · 2026-11-09

### 中文

- **更新前请注意：这一版的运行时有更新，所以还是下整包。** 内置引擎仍是 DSH 0.2.2-rc.1，变的是我们给它打的补丁和桥接层。升级后 Linux 环境里只保留 `/root`，用 `apt` 装的软件和放在 `/usr/local`、`/opt` 等目录的文件需要重新装。对话和设置不受影响。
- **这一版没有在真机上验证过。** 后台屏实时预览、多个后台任务、按截图坐标操作、本机文字识别、扫码配对和伙伴小屋的新功能都只经过自动测试和编译检查。遇到问题请开 issue 反馈。
- **新权限和新组件：** App 新声明了相机权限，只在扫码配对电脑时用；不给权限也可以从相册识图或粘贴配对链接。手机操控内置了 Google ML Kit 中文文字识别，默认开启：识别在手机上完成，截图和文字不会发给 Google，但 Google 的 SDK 会收集机型、应用版本、耗时等使用统计。不想要可以在手机操控页或「隐私与分享」里关掉「本机文字识别（ML Kit）」，关掉后不会加载它。
- 手机操控 · 多任务：每个对话的手机任务各自批准、暂停、停止。后台任务最多可以同时跑 3 个，在「不打扰模式」页的「后台任务上限」里设置，默认 1 个。悬浮条和通知上的停止、暂停、插话只作用于显示时的那个任务。
- 手机操控 · 看和点：「不打扰模式」页可以打开「实时查看后台屏」（默认关），App 内和悬浮小窗都能看，只读，最多每秒 5 帧，画面不存盘。找不到控件时可以按截图坐标点击、长按和滑动：截图 30 秒内有效，窗口一切换就作废；同一任务里第一次这样操作某个应用要你许可，发送、支付、删除仍然每次确认。输入文字后会回读核对，对不上时如实报告。
- 手机操控 · 技能和自检：任务成功后可以「存成技能」，起草时去掉联系人、号码、消息正文等个人信息，先预览、可修改，再装成 DSH 技能。手机操控页加了本机自检。
- 伙伴小屋 · 鲸鱼娘：她现在随 App 一起装好，第一次进小屋时自动安置，不用再自己导入素材包。模型作者是 B 站「Mao绒绒家园」，经作者授权随 DSH Go 分发。
- 伙伴小屋：菜单里的「主动邀请」换成「她多主动」，分安静、偶尔（默认）、常常、话多四档；别的对话跑完或出错时她提不提，在「她会提起什么」里分项开关。批准卡、提问卡和聊天记录在小屋里就能处理和翻看。日期、名字这些上下文不再写进你发出的消息里。完整模式可以打开自动想起记忆。
- 伙伴小屋 · 导入模型：模型文件夹直接打成 zip 也能导入。模型自带的表情和动作能用了，可以在菜单「动作和表情」里试、起名、标成 AI 可以用。蒙版多的精细模型也能画对，旧手机上更流畅；导不了的旧模型会说清原因。缺适配的模型可以让你配好的 AI 帮她适配：只发参数名单，不发模型文件，可以撤销，也可以关掉自动适配。
- 宠物：宠物选择里可以导入自己的像素宠物包，也能导入 Codex 宠物，转换后和原来不一样的地方会说明；长按自己导入的宠物可以删掉。
- 远程：Remote 电脑上也能开终端，电脑上关了终端时会提示去哪里打开；会话「文件」页可以直接「传文件到电脑」。「扫码配对电脑」要等 Remote 服务器支持后入口才会出现，线上服务器目前还没开。
- 诊断：诊断页可以在你逐次确认后采集系统输入法日志，帮助排查键盘自己收起的问题（#366）。只保留白名单里的事件，不记录输入内容和候选词。
- 网页版：关掉「手机布局」看官方网页版时，标题行左边的返回按钮换成 App 标记（点它仍是返回），DSH Web 侧栏打开时自动让开；系统返回会先收起官方侧栏。
- 其他修复：文件名清理后只剩空白时改用 `file`，上传不再被拒；宠物语音草稿和剪贴板预览截短时不拆开表情；锁屏时审批和分组摘要通知只显示公共标题；系统语音初始化失败后，下一次会重新创建；无障碍服务销毁后，迟到的连接不再重建悬浮层；远程主机换连接后，打开着的文件预览继续刷新（#465）；重新解包运行环境时补上 Android 附加组的组名（#159）。

### English

- **Before you update: this version changes the runtime, so it's a full download again.** The built-in engine is still DSH 0.2.2-rc.1; what changed are the patches we apply to it and the bridge layer. Only `/root` stays in the Linux environment, so software installed with `apt` and files in `/usr/local`, `/opt` and similar places need installing again. Chats and settings are kept.
- **This version hasn't been verified on a real phone.** Live background preview, multiple background tasks, actions by screenshot coordinates, on-device text recognition, pairing by scanning and the new companion room features have only been through automated tests and compile checks. If you hit a problem, please open an issue.
- **New permission and new component:** the app now declares the camera permission, used only to scan when pairing a computer; without it you can still read the code from a gallery image or paste the pairing link. Phone control now bundles Google ML Kit Chinese text recognition, on by default. Recognition runs on the phone and screenshots and text are not sent to Google, but Google's SDK collects usage statistics such as device model, app version and timing. If you don't want it, turn off On-device text recognition (ML Kit) on the phone control page or in Privacy and sharing; once off, it isn't loaded.
- Phone control, multiple tasks: each chat's phone task is approved, paused and stopped on its own. Up to 3 background tasks can run at once; set it under Background task limit on the Non-disruptive mode page (default 1). Stop, pause and interject on the floating bar and the notification act only on the task they were showing.
- Phone control, seeing and tapping: on the Non-disruptive mode page you can turn on Live background preview (off by default) to watch the background screen in the app or in a small floating window. It's view-only, at most 5 frames a second, and frames aren't saved. When no control can be found, the agent can tap, long-press and swipe by screenshot coordinates: a screenshot is valid for 30 seconds and is dropped as soon as the window changes. The first such action on an app within a task asks you; sending, paying and deleting still ask every time. Typed text is read back, and a mismatch is reported as it is.
- Phone control, skills and self-check: after a task succeeds you can Save as a skill. The draft leaves out contacts, numbers, message text and other personal details, and you can preview and edit it before it's installed as a DSH skill. The phone control page has a local self-check.
- Companion room, the whale girl: she now comes with the app and settles in the first time you open the room, so there's no pack to import. The model is by Mao绒绒家园 on Bilibili and is distributed with DSH Go with the author's permission.
- Companion room: the menu's invitation switch is now How often she speaks up, with four levels: Quiet, Now and then (default), Often and Chatty. Whether she mentions another chat finishing or failing is set item by item under What she brings up. Approval cards, question cards and the chat history can be handled and read right in the room. Context such as the date and your name is no longer written into the messages you send. Full mode can turn on automatic memory recall.
- Companion room, importing models: a zipped model folder can be imported as is. A model's own expressions and motions now work; try them, name them and mark them as usable by the AI under Moves and faces in the menu. Detailed models with many masks draw correctly, older phones run smoother, and an old model that can't be imported says why. A model that needs fitting can be adapted by the AI you configured: only the parameter list is sent, never the model files, and you can undo it or turn automatic fitting off.
- Pets: the pet picker can import your own pixel pet pack, and Codex pets too, with a note on anything that came out different from the original. Long-press a pet you imported to delete it.
- Remote: you can open a terminal on a Remote computer (if terminals are turned off on the computer, the app says where to turn them on), and a session's Files page can Send files to the computer directly. Pair a computer by scanning only appears once the Remote server supports it; the public server hasn't turned it on yet.
- Diagnostics: after you confirm each time, the diagnostics page can collect system keyboard logs to help track down the keyboard closing on its own (#366). Only allowlisted events are kept; typed text and suggestions are never recorded.
- Web: with the phone layout off on the official web page, the back button at the left of the title row is now the app mark (tapping it still goes back), and it moves out of the way when the DSH Web sidebar opens. System back closes the official sidebar first.
- Other fixes: a file name left blank after cleaning falls back to `file`, so uploads are no longer refused. Pet voice drafts and clipboard previews no longer split emoji when shortened. On the lock screen, approval and grouped summary notifications show only a public title. System text-to-speech is created again after it failed to start. A late connection to an accessibility service that was already destroyed no longer rebuilds the overlay. Open file previews keep refreshing after the remote host switches connections (#465). Unpacking the runtime environment again restores the group names for Android's supplementary groups (#159).

## 1.0.13 · 2026-11-08

### 中文

- **更新前请注意：这一版的运行时有更新，所以还是下整包。** 内置引擎仍是 DSH 0.2.2-rc.1，变的是我们给它打的补丁。升级后 Linux 环境里只保留 `/root`，用 `apt` 装的软件和放在 `/usr/local`、`/opt` 等目录的文件需要重新装。对话和设置不受影响。
- **这一版没有在真机上验证过。** App 内的视频播放和存视频到相册只经过自动测试和编译检查，没在手机上放过。遇到问题请开 issue 反馈。
- 新对话首页：建议换成横排小卡片，下面一行小技巧会自动轮换，点一下换下一条。首页就能选这次对话的模型、Agent 预设和权限，第一条消息发出前生效；设置失败时消息不会发出，留在输入框里。
- 视频：点视频在 App 内播放，可以播放、暂停和拖动进度，放不了时仍能用其他应用打开；视频也能保存到相册。没有封面的本机视频会取首帧当封面，远程视频只在你主动打开时才下载。
- 图片：加载失败时可以点「重新加载」，只重新读取文件，不会重新生成，也不会再收生成费用。
- 图像与视频设置：API 地址填根地址，编辑时可以预览请求地址；换站点或跨站点复用 Key 要先确认。「检查已保存配置」只检查配置本身，不联网验证 Key、余额或模型权限。
- 计划模式：重新打开对话后恢复之前选的计划模式，后面的命令失败也不会把它清掉。
- 手机操控：停止或换任务后，旧任务不会再启动应用、按键、点击或滚动；后台屏画面过期时会拒绝操作并要求刷新；横向列表的手势方向不再反；太短的滑动直接拒绝；所选模式和实际的 Shizuku / Sui 不一致时不再报就绪，并说明原因。
- 远程：迟到的退出登录不会再删掉新登录的凭据，旧的登录动作不会切到你后来选的服务器；自建服务器邮箱登录时连按完成键不再重复提交；较大的设置写入不再执行两次。
- 引擎：启动失败时先显示正在停止，并优先显示这次的原因；引擎服务没就绪不再被说成版本不支持；运行环境安装失败页可以直接导出诊断包；工作区索引损坏时可以改用独立的救援索引；插件安装输出里的中文和 emoji 不再乱码（#658）；空闲时排队的通知不再挡住永久删除对话（#687）；坏掉的 Agent 预设会显示实际的加载失败原因（#75）。
- 运行环境：重置前确认相关进程都已退出；升级中途被打断时保留要带走的用户文件。安全模式移走危险文件只完成一部分时会如实报告，可以重试剩下的。
- 文件和分享：很长的文件名按字节截短，不会切开表情，也保留扩展名。
- 插件开发：插件省略能力参数时按 v1 的默认处理，不再当成空列表（#656）。

### English

- **Before you update: this version changes the runtime, so it's a full download again.** The built-in engine is still DSH 0.2.2-rc.1; what changed are the patches we apply to it. Only `/root` stays in the Linux environment, so software installed with `apt` and files in `/usr/local`, `/opt` and similar places need installing again. Chats and settings are kept.
- **This version hasn't been verified on a real phone.** In-app video playback and saving videos to the gallery have only been through automated tests and compile checks, never played on a phone. If you hit a problem, please open an issue.
- New chat page: suggestions are now small cards side by side, with a tip line below that changes on its own; tap it for the next tip. You can pick this chat's model, Agent preset and permissions right on the page; they apply before the first message is sent, and if applying them fails the message stays in the composer instead of going out.
- Video: tap a video to play it in the app, with play, pause and seeking; if it won't play you can still open it in another app. Videos can be saved to the gallery too. A local video with no poster uses its first frame; a remote video is downloaded only when you open it.
- Images: when an image fails to load you can tap Reload. It only reads the file again; it doesn't regenerate or charge for generation again.
- Image and video settings: enter the API root as the address, and preview the request address while editing. Switching sites or reusing a key across sites asks first. Check saved configuration checks only the configuration; it doesn't go online to verify the key, balance or model access.
- Plan mode: reopening a chat restores the plan mode you chose, and a later command failing no longer clears it.
- Phone control: once a task stops or is replaced, the old one no longer launches apps, presses keys, taps or scrolls. Actions on a stale background screen are refused with a request to refresh. Gestures on horizontal lists no longer go the wrong way, swipes too short to register are refused, and when the selected mode doesn't match the actual Shizuku or Sui provider it no longer reports ready and says why.
- Remote: a late sign-out no longer deletes the credentials of a newer sign-in, and an old sign-in action no longer switches to a server you picked later. Pressing Done repeatedly while signing in by email on a self-hosted server no longer submits twice, and large settings writes no longer run twice.
- Engine: a failed start shows that it's stopping first and puts this attempt's reason ahead of older failures. An engine service that isn't ready is no longer reported as an unsupported version. The runtime install failure page can export a diagnostics bundle directly. A damaged workspace index can be swapped for a separate rescue index. Chinese and emoji in plugin install output are no longer garbled (#658). Notifications queued while idle no longer block deleting a chat for good (#687). A broken Agent preset shows the actual reason it failed to load (#75).
- Runtime environment: a reset first makes sure the related processes have exited, and an upgrade interrupted halfway keeps the user files it was carrying over. When safe mode moves dangerous files away and only part of it succeeds, it says so and you can retry the rest.
- Files and sharing: very long file names are shortened by bytes without splitting emoji, and keep their extension.
- Plugin development: a plugin that leaves out the capabilities parameter gets the v1 default instead of an empty list (#656).

## 1.0.12 · 2026-11-07

### 中文

- **更新前请注意：这一版的运行时有更新，所以还是下整包。** 内置引擎仍是 DSH 0.2.2-rc.1，变的是我们给它打的补丁。升级后 Linux 环境里只保留 `/root`，用 `apt` 装的软件和放在 `/usr/local`、`/opt` 等目录的文件需要重新装。对话和设置不受影响。
- **这一版没有在真机上验证过。** 目前在 x86_64 模拟器上用测试模型走过从 1.0.11 升级：运行时完成替换，对话和定时任务都在，`/root` 保留、`/usr/local` 清掉，升级后发消息正常。伙伴小屋只经过自动测试，没在模拟器上打开过。 遇到问题请开 issue 反馈。
- 伙伴小屋（新）：从「切换主机」面板进入的 Live2D 伙伴页面，可以摸摸她、和她聊天。轻量模式由手机直接调模型，不用启动引擎；完整模式在当前主机上开一个普通会话，能用主机的工具，审批照常。她会记得你写下的事；可以用手机自带的朗读或你自己配置的语音服务说话，也能用你自己的录音克隆音色，录音只发给你选的那个服务。Live2D 运行库和角色模型不随 App 提供，需要自己导入素材包。
- 悬浮宠物：长按打开半轮盘，新增「截图」，截下当前屏幕带进新对话的草稿，不会自动发送。需要 Android 11 及以上。
- 图片：点图片全屏查看，双指缩放、双击放大；同一组图片可以左右滑动切换。
- 英文界面：审批理由、插件市场分类和插件详情不再显示中文；英文的思考内容不再出现多余的翻译按钮。
- 对话：同一轮里的多段正式回答都会保留，不再被误折叠；上下文用量的估算说明更清楚。
- 远程：没选工作区时，新对话落到最近用过的工作区，新对话页会显示它；主机上一个工作区都没有时会写明「主机默认目录」。新增 `设置 › 远程主机 › 精简历史`，支持的 DSH Remote 主机可以只传历史工具输出的摘要。SSH 认证途中断线会继续重连，不再当成密钥错误，启动失败时显示详情。连接详情里能看到实际走的路径和 IPv4 / IPv6。
- 引擎：一个被改名或损坏的会话目录不再让整个引擎起不来，其余对话照常显示；安全模式在数据坏掉时用独立的数据目录启动，原来的对话保持原样。用 OpenAI 兼容协议接 Gemini 不再被 400 拒绝。插件安装、更新和热更新时的并发问题已修复；大量文本截断不再切坏字符，编辑文件时保留原来的 BOM 和行尾。
- 手机操控：OPPO、realme 等机型上确认卡的按钮点不动、只能等倒计时结束的问题已修复（#608、#632）。确认卡不再按触摸事件的字段猜是不是真手指，改成只拒绝 App 自己发出的点击，助手仍然不能替你点「允许」。这一项没在这些机型的真机上验证过。另外，无障碍服务被系统打断时不再直接停止本次操作；后台屏刚打开时的黑帧不再被报成安全窗口；无障碍授权自动恢复失败时会说明原因；通知上的两个停止按钮改叫「停止手机操控」和「停止引擎」。
- 设置：重置运行环境的确认框写明，`/root` 里没保留的内容（包括工作区文件、`AGENTS.md` 和插件自己存的数据）也会一起删除。
- 网页版：原版布局下侧栏按钮不再被 App 的浮钮挡住；顶栏按钮不再独占一排。

### English

- **Before you update: this version changes the runtime, so it's a full download again.** The built-in engine is still DSH 0.2.2-rc.1; what changed are the patches we apply to it. Only `/root` stays in the Linux environment, so software installed with `apt` and files in `/usr/local`, `/opt` and similar places need installing again. Chats and settings are kept.
- **This version hasn't been verified on a real phone.** So far it has run on an x86_64 emulator with a test model, updating from 1.0.11: the runtime was replaced, chats and scheduled tasks were kept, `/root` stayed and `/usr/local` was cleared, and messages worked after the update. The companion room has only been through automated tests and wasn't opened on the emulator. If you hit a problem, please open an issue.
- Companion room (new): a Live2D companion page, opened from the host switcher. You can pat her and talk to her. Light mode calls the model straight from the phone with no engine to start; full mode opens an ordinary conversation on the current host, with its tools and its usual approvals. She remembers what you write down for her, can speak with the phone's own text-to-speech or a speech service you configure, and can clone a voice from your own recording, which is sent only to the service you choose. The Live2D runtime and character models don't ship with the app; you import a pack yourself.
- Floating pet: a long press opens a half wheel with a new Screenshot item that takes the current screen into a new chat's draft, without sending it. Requires Android 11 or later.
- Images: tap an image to view it full screen, pinch or double-tap to zoom, and swipe between images of the same group.
- English interface: approval reasons, plugin market categories and plugin details no longer show Chinese, and English reasoning no longer shows a needless Translate button.
- Chat: every final answer in a turn is kept instead of being folded away by mistake, and the context usage estimate is explained more clearly.
- Remote: with no workspace selected, a new chat starts in the workspace you used last and the new chat page shows it; a host with no workspace at all says "Host default folder". New `Settings › Remote host › Compact history` lets supporting DSH Remote hosts send only summaries of past tool output. An SSH connection dropped during authentication keeps reconnecting instead of being reported as a key error, and a failed start shows its details. Connection details show the path actually used and IPv4 or IPv6.
- Engine: one renamed or damaged session folder no longer stops the whole engine from starting, and the other chats still show; safe mode starts on a separate data folder when the data is damaged, leaving the original chats untouched. Gemini through the OpenAI-compatible protocol is no longer rejected with a 400. Concurrency problems when installing, updating and hot-reloading plugins are fixed; many text truncations no longer cut characters apart, and editing a file keeps its BOM and line endings.
- Phone control: on OPPO, realme and similar phones the confirmation card's buttons no longer ignore taps until the countdown runs out (#608, #632). The card no longer guesses from touch event fields whether a finger is real; it only refuses taps the app itself sends, so the assistant still can't tap Allow for you. This hasn't been verified on those phones. Also, an accessibility service interrupted by the system no longer stops the current action; the black first frame of a just-opened background screen is no longer reported as a secure window; when restoring accessibility access automatically fails, the reason is shown; the notification's two stop buttons are now "Stop phone control" and "Stop engine".
- Settings: the reset runtime dialog says that anything in `/root` you don't keep, including workspace files, `AGENTS.md` and data plugins store themselves, is deleted too.
- Web UI: in the original layout the sidebar button is no longer covered by the app's floating button, and the header buttons no longer take a row of their own.

## 1.0.11 · 2026-11-05

### 中文

- **更新前请注意：这一版换了运行时，内置引擎升到 DSH 0.2.2-rc.1。** 升级后 Linux 环境里只保留 `/root`，用 `apt` 装的软件和放在 `/usr/local`、`/opt` 等目录的文件会被清掉，需要重新装。对话和设置不受影响。也因为换了运行时，这次还是下整包。新引擎写入后，定时任务不保证还能被旧版引擎读回，不建议退回旧版。
- **这一版的引擎升级还没在真机上验证过。** 目前在 x86_64 模拟器上用测试模型走过从 1.0.10 升级、发消息、定时任务、窄屏网页版和手机工具，没用过真实模型账号。遇到问题请开 issue 反馈。
- 网页版：手机宽度下改用官方的抽屉和设置页，顶部的菜单按钮打开官方抽屉。平板和横屏沿用原来的布局。
- 定时任务：**这里改了 1.0.10 的规则。** 官方页面新增的手动新建现在能用：你自己在页面或 App 里新建、修改任务不再二次确认，和官方一致。助手用工具新建、修改任务仍然要单独确认，拒绝或两分钟内没确认都不保存。确认卡防不住能读到凭据文件的程序，不能代替系统隔离。
- 定时任务：助手现在创建的任务用新的规则格式，列表里显示「自定义」，和官方一致。这类任务在 App 里能改名字和指令，时间不在这里改，请在对话里让助手改。
- 对话：手机顶栏把位置留给标题，第二行只放状态和工作区；输入框点进去展开成两行，换模型的按钮就在里面。左滑面板在开着对话时显示这段对话的信息和插件。
- 动效：新增「灵动动效」，有按压回弹、卡片展开成页面，文字匀速吐出并淡入。默认开启，省电模式和系统关闭动画时不生效，可在 `设置 › 性能` 里关掉。
- 插件：新增五个可放置的位置：`+` 面板的工具、侧栏的操作、回合脚注、插件页面板和弹窗面板。
- 手机操控：后台截图处理好了带行填充的画面，操作结束后浮层和触摸都会恢复，已结束的调用不再占着队列。
- 更新：取消下载后不再改写已有分片；响应头或错误内容很慢时不再一直占着连接；升级后的清理不再删掉刚校验好的新安装包。
- 分享和文件：损坏的分享链接会被拒绝；截断文字时不再切开表情；保存文件时先占住文件名，互不覆盖。
- 远程：请求超时后不再启动迟到的请求，也不再留下迟到的连接；重连不会取消已经选定的系统听写。
- 语音：录音读取失败时结束这次录音，不再留下半截文件；迟到的取消回执不再影响新一轮。
- 引擎：大量后台路径减少了重复计算和内存分配，比如长输出截断、文件搜索和会话列表。
- 限制：官方远程插件 0.6.2 还不支持新版的修改和立即运行，通过它连 0.2.2 主机时不能修改、删除或立即运行定时任务，可以查看。如果你在配置里完整复制过旧版的预设，新引擎可能启动不了这个预设，做法见 `docs/maintenance/dsh022-saved-preset-migration.md`。

### English

- **Before you update: this version changes the runtime, and the built-in engine is now DSH 0.2.2-rc.1.** Only `/root` stays in the Linux environment. Software installed with `apt` and files in `/usr/local`, `/opt` and similar places are removed and need installing again. Chats and settings aren't affected. Because the runtime changes, this is a full download. Once the new engine has written them, scheduled tasks may not read back on an older engine, so going back isn't recommended.
- **The engine upgrade hasn't been verified on a real phone yet.** So far it has run on an x86_64 emulator with a test model: updating from 1.0.10, messages, scheduled tasks, the narrow web UI and phone tools. No real model account was used. If you hit a problem, please open an issue.
- Web UI: at phone width it now uses the official drawer and settings sheet, and the menu button at the top opens the official drawer. Tablets and landscape keep the previous layout.
- Scheduled tasks: **this changes the rule from 1.0.10.** The official page's new manual create now works: when you create or edit a task yourself on the page or in the app, there's no second confirmation, as upstream has it. When the assistant creates or edits one through its tools, it still needs separate confirmation, and rejecting or not confirming within two minutes saves nothing. The card can't stop a program that can read the credentials file, so it doesn't replace system isolation.
- Scheduled tasks: tasks the assistant creates now use a new rule format and read "Custom" in the list, as on the official page. You can change their name and instruction in the app. To change the time, ask the assistant in a chat.
- Chat: the phone header gives its room to the title, with only status and workspace on the second line. The composer opens into two rows when you tap it, with the model button inside. With a chat open, the swipe panel shows that chat's info and plugins.
- Motion: a new "Fluid motion" setting adds press rebound, cards that expand into pages, and text that streams at an even pace and fades in. It's on by default, has no effect in battery saver or when the system turns animations off, and can be turned off in `Settings › Performance`.
- Plugins: five more places to put things: tools on the `+` panel, actions in the side panel, turn notes, panels on a plugin's own page, and panels that open as a sheet.
- Phone control: background screenshots handle frames with row padding, the overlay and touch come back after an action, and finished calls no longer hold up the queue.
- Updates: cancelling a download no longer rewrites existing chunks, a slow response header or error body no longer holds a connection, and cleanup after an update no longer deletes a freshly verified package.
- Sharing and files: damaged share links are refused, truncating text no longer cuts an emoji in half, and saving a file claims its name first so saves don't overwrite each other.
- Remote: a request that timed out no longer starts late or leaves a late connection, and reconnecting no longer cancels a system dictation you already chose.
- Voice: a failed recording read ends that recording instead of leaving a partial file, and a late cancel no longer affects the next round.
- Engine: many background paths do less repeated work and allocate less, such as long output truncation, file search and the session list.
- Limits: the official remote plugin 0.6.2 doesn't support the new edit and run yet, so through it on a 0.2.2 host you can view scheduled tasks but not edit, delete or run them. If you copied a whole old preset into your config, the new engine may fail to start it; see `docs/maintenance/dsh022-saved-preset-migration.md`.

## 1.0.10 · 2026-11-04

### 中文

- **更新前请注意：这一版换了运行时。** 升级后 Linux 环境里只保留 `/root`，用 `apt` 装的软件和放在 `/usr/local`、`/opt` 等目录的文件会被清掉，需要重新装。对话和设置不受影响。也因为换了运行时，这次还是下整包。
- 定时任务：新建任务、修改任务的名称、指令或时间，都要单独确认。确认卡会展示完整指令、规则、时区和实际触发时间；完全权限、自动审查和「本对话都允许」都不能代替这次确认。拒绝、两分钟内没确认或没有可用的确认界面时，这次改动不会保存。限制：更新前已经存在的任务不会补做授权，请检查并删除不认识的任务；远程主机要装同样的引擎修复才有这道检查；授权不能代替凭据和工具执行的系统隔离。这项还没在真机上验证过，遇到问题请开 issue 反馈。
- 动效：弹窗和返回手势跟手，松手后顺着手指的速度由弹簧收住；拉过头有阻尼，回弹途中再抓住会从当前位置接着拖。
- 动效：按压改用弹簧；滚动列表时不再闪一下按下的效果，快速点按也看得见。
- 动效：等待的三个点换成思考或正文时不再硬切；思考文字上有一道缓慢的亮度扫光，图标转得更慢；工具之后直接出正文时，回复不再跳一下；输入框多一行时平滑长高。
- 动画开关现在也管页面切换、底部弹窗和壁纸、启动画面的预览。系统的「移除动画」同样生效，App 开着时改也立刻生效。弹窗移动时不做模糊，只在停稳后模糊，中低端手机上更省。这些手感还没在真机上验证过，遇到问题请开 issue 反馈。
- 安装包小了约 13 MB：arm64 包不再带另外两种架构用不上的库。
- 远程：聊天输入框可以把文件上传到当前会话的工作目录，不再只能传图片。单个文件最大 200 MiB；走 Relay/TURN、未知路径或旧版主机时通常仍限 20 MiB，以主机的回复为准。这项还没在真实远程主机上验证过，遇到问题请开 issue 反馈。
- 远程：抽屉底部的主机图标直接打开连接详情，点主机名或下拉仍是切换主机；本机图标打开引擎页。
- 模型：`设置 › 模型` 顶部新增**新对话默认**，可以沿用上次的选择，也可以固定一个模型和思考深度。固定默认需要新版引擎支持。
- 对话：回复里由引擎提供的图片（比如表情包插件的图）现在能显示，不再一律显示“无法显示”。展开的待办清单超长时，滑到底不再被拉回，能看到最后几项。
- 对话：手动 `/compact` 不再在 120 秒时被中断，等待上限改为 30 分钟；模型、远程主机或代理自己的限制仍然有效。
- 不打扰模式：能力自检改用测试窗口实际收到的触摸来判断，并等新建的后台屏准备好，部分 Android 17 设备不再一直显示未就绪；后台屏被任务占用时提示任务结束后重试，失败提示会带上出错的步骤。这些还没在 Android 17 真机上验证过。
- 手机操控：拿不到有效画面时，不再把空白界面当成“界面没变”或“已经到底”，也不再把手势发出去就当成操作成功；读屏连接超时后也会关闭。
- 引擎：PRoot 启动早期的权限错误和符号链接循环会归为启动失败；启动前清理已确认无主的 PRoot 临时目录，清理失败不影响启动。
- 远程连接：每次新建连接都会重新尝试获取 TURN 凭据。
- 语音：下载模型时写入失败（比如磁盘满）会正常报错，不再卡住。
- 关于：展示原作者和 B 站、X、GitHub 主页的链接。

### English

- **Before you update: this version changes the runtime.** Only `/root` stays in the Linux environment. Software installed with `apt` and files in `/usr/local`, `/opt` and similar places are removed and need installing again. Chats and settings aren't affected. Because the runtime changed, this update is still a full download.
- Scheduled tasks: creating a task, or changing its name, instructions or time, now needs its own confirmation. The card shows the full instructions, rule, time zone and actual trigger time, and full access, auto review and **Allow for chat** can't stand in for it. If you reject it, don't confirm within two minutes, or no confirmation screen is available, the change isn't saved. Limits: tasks that existed before this update aren't reviewed retroactively, so please check them and delete any you don't recognize; a remote host needs the same engine fix to have this check; and the confirmation doesn't replace system isolation of credentials and tool execution. This hasn't been tried on a real device yet, so please open an issue if it misbehaves.
- Motion: sheets and the back gesture follow your finger, and on release a spring carries on at the finger's speed. Pulling too far meets resistance, and catching a sheet on its way back carries on from where it is.
- Motion: presses settle on a spring. Scrolling a list no longer flashes a press, and quick taps still show one.
- Motion: the waiting dots no longer cut to thinking or text. The thinking label has a slow brightness sweep and its icon turns more slowly. A reply no longer jumps when text comes straight after a tool, and the composer grows smoothly by a line.
- The animation switch now also covers page transitions, bottom sheets, and the wallpaper and launch previews. The system's remove-animations setting does too, including when changed with the app open. Sheets blur only at rest, not while moving, which is cheaper on mid-range and low-end phones. None of this has been felt on a real device yet, so please open an issue if it misbehaves.
- The APK is about 13 MB smaller: the arm64 package no longer carries libraries for the other two architectures.
- Remote: the composer can upload files to the current chat's working directory, not only images. Each file can be up to 200 MiB; over Relay or TURN, on an unknown path or with an older host the limit is usually still 20 MiB, and the host's reply decides. This hasn't been tried on a real remote host yet, so please open an issue if it misbehaves.
- Remote: the host icon at the bottom of the drawer opens the connection details directly, and the host name or dropdown still switches hosts. The local icon opens the engine page.
- Models: `Settings › Models` has **New chat defaults** at the top. Keep your last choice, or fix a model and thinking effort. A fixed default needs an engine that supports it.
- Chat: images the engine serves itself in replies, such as those from an emoji plugin, now load instead of showing "can't display". A long expanded to-do list no longer pulls back when you scroll to the end, so the last items can be seen.
- Chat: a manual `/compact` is no longer cut off at 120 seconds. It can now wait up to 30 minutes, though limits set by the model, a remote host or a proxy still apply.
- Do Not Disturb: the capability check now goes by the touches a test window really receives and waits for a new background screen to be ready, so some Android 17 devices no longer stay on Not ready. While a task holds the background screen, it says to retry when the task ends, and failures name the step that failed. None of this has been tried on an Android 17 device.
- Phone control: without a usable view of the screen, a blank capture no longer reads as "nothing changed" or "reached the end", and a sent gesture no longer counts as a success by itself. A screen-reading connection that times out is now closed too.
- Engine: permission and symlink-loop errors early in PRoot startup are classified as launch failures. Before a launch, PRoot temp directories confirmed abandoned are cleaned up, and a failed cleanup doesn't block the launch.
- Remote: each new connection tries again for TURN credentials.
- Voice: a failed write during a model download, such as a full disk, now reports an error instead of hanging.
- About: shows the original author, with links to their Bilibili, X and GitHub profiles.

## 1.0.9 · 2026-11-02

### 中文

- Android 17：不打扰模式能点了。系统删掉了后台屏下发输入要用的隐藏接口，root、Sui、Shizuku、自连 ADB 四条通道都只能读屏、点不了，现在改用还在的接口。我们手上没有 Android 17 真机，遇到问题请开 issue 反馈。
- Android 17：自连 ADB 用的 TLS 库（Conscrypt）升到 2.8.0，在 16 KB 内存页的设备上也能加载。
- 不打扰模式：新增「保持 X 通道」开关，默认关。打开后，通道断开、App 被杀或手机重启，都会自己连回去。root 打开后 DSH Go 会自己再向 root 管理器申请，给不给仍由管理器决定；没打开就绝不会自动执行 `su`。这个开关还没在真机上验证过，遇到问题请开 issue 反馈。
- 不打扰模式：读后台屏时按包名取目标 App 的窗口，不再只看第一个窗口；每次点按、滑动、按键只发一次，系统没确认时不再说「系统拒绝」，也不再让你去开 USB 调试；对后台屏按 HOME 这类系统键会直接失败，不再把物理屏送回桌面；root 的一键授权复用已连接的 root，不再多跑一次 `su`。
- 自连 ADB：在通知里输入配对码现在真的能配对了（以前每次都失败，结果还被丢掉，看起来没有任何反应），通知会显示配对结果。
- 手机操控悬浮条：胶囊 3 秒不碰就按「闲置时不透明度」变淡，碰一下恢复；卡片和等你处理的时候不变淡。开了「闲置时自动收起」的，还是先收成小球再变淡。
- 新增左滑快捷入口：在聊天区左滑，从右侧打开插件、引擎、设置等常用入口。可以在 设置 → 界面 里关掉，或者选显示哪些、调顺序。
- 会话：永久删除不再误报「此主机不支持」，引擎还没准备好时提示暂不可用；刚新建、还没写到磁盘的会话也能删了；删除一次只发一个请求。会话搜索跟随当前连接，不再用旧连接的结果回答。
- 对话：准备失败或中断时，还没被接收的输入按原顺序放回队列，不会丢。图片被拒时，不再一律让你换 V4.1 Flash，而是说明当前模型没声明支持图片，可以换模型或把自定义模型的输入类型改成「文本和图片」。
- 附件：单个文件上限从 30 MB 提到 200 MB，单条消息总量 400 MB；文件走引擎的流式上传。旧版主机上仍是 30 MB。
- 网络：引擎把 IPv4 和 IPv6 分开解析，网络拒绝 IPv6 查询时不再连带 IPv4 一起失败。PRoot 里的 git、curl、pip 这次没有覆盖到。
- 引擎：卡死时，停止和重置会等旧进程真正退出；启动早期堆内存耗尽会计入自动安全模式，不再每次打开都加载同一个插件。
- 更新：优先从 dl.dshtui.com 下载，并支持增量更新（这一版换了运行时，还是下整包，下一版起才会变小）；点了安装后没等到系统结果时，不再说「已取消安装」，安装包会留着。
- 插件市场：优先从 dl.dshtui.com 读目录，手机上留一份，读不到时用这份。
- 分享：导出和分享对话时，`Authorization` 请求头里的凭据会被隐藏。
- 文件：XLSX 预览的预算把铺开的空单元格也算进去；刷新之后不再被更早的修改时间覆盖。
- 终端：改名失败的结果晚到时，不再影响已离开的页面或重建后的终端。
- 插件：重载之后才完成的面板视图不再用旧注册回答；App 在后台时新建的流也会按时关闭；被关闭的连接中止的文件回调不再算成插件的错。
- 手机操控工具：`run_code` 能看到 intent、collect、tap_xy 的参数了；tap_xy 缺屏幕号时报错说对参数名。
- 诊断：快照里的内存和剩余存储单位对了，不再把 GiB 显示成 MB。
- 插件开发：插件技能和检查清单按 view v2 写，不再说只有 16 个组件。
- 性能：解压运行时并行解码；引擎日志成批处理；长对话只折叠新增的部分；重复打开会话列表跳过没变的记录；启动缓存在 Direct 模式下也生效；本机连接不等 mux 就能先加载会话列表。

### English

- Android 17: Do Not Disturb can tap again. The system removed the hidden interface the background screen used to send input, so root, Sui, Shizuku and self-paired ADB could all read the screen but not touch it; it now uses the one that remains. We don't have an Android 17 device, so please open an issue if it misbehaves.
- Android 17: the TLS library self-paired ADB uses (Conscrypt) is now 2.8.0, which loads on 16 KB-page devices.
- Do Not Disturb: a new "Keep this channel" switch, off by default. With it on, the channel reconnects by itself after a drop, the app being killed or a reboot. For root, DSH Go asks your root manager again by itself and the manager still decides; with it off, `su` never runs on its own. This switch hasn't been tried on a real device yet, so please open an issue if it misbehaves.
- Do Not Disturb: reading the background screen picks the target app's window by package instead of only looking at the first; each tap, swipe and key is sent once, and when the system doesn't confirm one it no longer says "rejected" or sends you to USB debugging settings; HOME and similar system keys on the background screen fail outright instead of sending the physical screen home; the one-tap root grant reuses the connected root instead of running `su` again.
- Self-paired ADB: typing the pairing code into the notification now really pairs (it used to fail every time and drop the result, so nothing seemed to happen), and the notification shows the outcome.
- Phone control overlay: the capsule fades to Idle opacity after 3 seconds untouched and comes back at a touch; the card and anything waiting for you stay solid. With Collapse when idle on, it still shrinks to a ball first and the ball fades.
- New left-swipe shortcuts: swipe left over the chat to open plugins, engine, settings and other common places from the right. Turn it off or choose and order the items in Settings → Interface.
- Sessions: permanent delete no longer says "this host doesn't support it" while the engine is starting; a new session that was never written to disk can be deleted; one delete sends one request. Session search follows the current connection instead of answering from the old one.
- Chat: input not yet accepted goes back to the queue in order when preparing fails or a turn is interrupted, so it isn't lost. Image refusals no longer send everyone to V4.1 Flash: they say the model doesn't declare image input, and that you can switch models or set a custom model's Input to Text + image.
- Attachments: up to 200 MB per file (was 30 MB) and 400 MB per message, uploaded through the engine's streaming route. Older hosts stay at 30 MB.
- Network: the engine resolves IPv4 and IPv6 separately, so a network that refuses IPv6 lookups no longer takes IPv4 down too. git, curl and pip inside PRoot aren't covered yet.
- Engine: when it hangs, stop and reset wait for the old process to really exit; running out of heap early in startup now counts toward safe mode, so the same plugin isn't loaded on every launch.
- Updates: downloads come from dl.dshtui.com first, with delta updates (this version changes the runtime, so it's still a full download; they get smaller from the next one); an install with no result from the system no longer says "cancelled", and the package is kept.
- Plugin market: the catalog comes from dl.dshtui.com first, with a copy kept on the phone for when it can't be read.
- Sharing: credentials in `Authorization` headers are hidden in exports and shares.
- Files: the XLSX preview's budget counts the empty cells it lays out; an older modified time can't overwrite a newer one after a refresh.
- Terminal: a late rename failure can't touch a page you left or a rebuilt terminal.
- Plugins: a panel view that finishes after a reload no longer answers from the old registration; a stream made while the app is in the background still closes on time; a file callback stopped by a closed connection isn't counted against the plugin.
- Phone control tools: `run_code` now sees the parameters of intent, collect and tap_xy; tap_xy's missing-screen error names the right parameter.
- Diagnostics: memory and free storage in the snapshot have the right units, no longer showing GiB as MB.
- Plugin development: the plugin skill and checklist describe view v2, not only 16 components.
- Performance: the runtime unpacks with parallel decoding; engine logs are batched; long chats fold only what's new; re-opening the session list skips unchanged records; the boot cache also works in Direct mode; the local connection can load the session list before the mux is up.

## 1.0.8 · 2026-11-01

### 中文

- 不打扰模式：「Shizuku 可用」改为看接口本身，不再要求装 Shizuku App——只装了 Sui（Magisk / KernelSU 模块）的设备也能直接用，状态里写明接口来自 Sui 还是 Shizuku；两者都没有、和有 Sui 但还没授权，提示分开说。
- 不打扰模式：新增 root 通道，给已 root（Magisk / KernelSU / APatch）但没有 Shizuku 的设备。只有你在页面上选了 root 才会第一次执行 `su`，授权走 root 管理器自己的弹窗；「自动恢复无障碍」的一键授予也能走 root。
- 不打扰模式：通道选择改成一个面板——关闭 / Shizuku / Sui / root / 自连 ADB，各自写明适合谁、现在什么状态，并标出推荐的那个（只推荐，不替你选）；失败时显示真实原因，不会悄悄换到别的通道。Sui 和 root 两条通道还没在真机上验证过，遇到问题请开 issue 反馈。
- 自连 ADB：修了「连接 → 启用」的检查死循环，端口可以手动填；切换通道时只断开要离开的那条，已经连好的 ADB 不再被一并断掉；一次操作被超时或停止打断后，不再复用旧连接，避免下一步收到上一步迟到的结果。
- 会话：可以永久删除对话（长按单删、多选批量删）；可以浏览并恢复已归档的对话；可以直接在某个文件夹里新建对话。
- 悬浮宠物：App 外的宠物和 App 内一样大；思考、子代理等动画完整显示，不再被裁掉；App 在后台时一轮结束，宠物气泡和通知照常出现；App 在后台时暂停宠物动画计时。
- 实时活动：运行状态显示在状态栏、锁屏和厂商灵动岛（如小米焦点通知），配宠物头像。
- 输入框上方：自动允许、插件胶囊不再各占一行；目标、待办、插件和状态条可以叠成一行卡片，点开有展开动画，叠着时左右滑动换到最前面。可以在 ui.json 里隐藏内置的插件胶囊。
- 手机操控悬浮条：重做成圆球、胶囊、圆角卡片三级，最常用的操作信息放在最前，暂停 / 停止重新排布，次要信息收进下一层。
- 插件设置：插件声明的字段都能显示，有中文标题优先用中文；十个常用插件补了中文字段说明；改一个字段只刷新那一行，不再卡；跳到网页版设置不再和它抢着改、也不会卡住。
- 图像与视频：设置页按服务商整理，同一服务商的几项服务共用一把 key，预设自动填好地址和模型。
- 对话：外接键盘可选 Enter 发送；在光标处输入 `/` 也能补全命令，不丢草稿；表格底色三档可选（带预览），表格紧贴段落也能正常显示；模型卡长名字完整显示，token 统一用 K / M；订阅渠道的上下文长度可以自己设。
- 外观：原生界面跟随主机设定的深浅色。
- 网页版：App 内的网页版可以上传文件。
- 渠道：思考级别留空不再让渠道失效。
- 性能：流式输出时复用已有的行和索引、复用已完成段落的扫描结果；侧边栏按需构造会话条目；顶栏状态文字不再重复测量。
- 源码：1.0.5–1.0.7 的源码已补进公开仓库，保留逐个提交的历史，对应的 tag 也改指到了正确的提交。

### English

- Do Not Disturb: Shizuku is now judged by its interface, not by the Shizuku app — devices with only Sui (a Magisk / KernelSU module) work as is, and the status says whether the interface comes from Sui or Shizuku. "Neither installed" and "Sui present but not authorized" are told apart.
- Do Not Disturb: a new root channel for rooted devices (Magisk / KernelSU / APatch) without Shizuku. `su` runs for the first time only after you pick root on the page, and the prompt is your root manager's own. The one-tap grant for auto-restoring accessibility can use root too.
- Do Not Disturb: picking a channel is one panel — off / Shizuku / Sui / root / self-paired ADB, each with who it's for and its current state, the recommended one marked (marked, never picked for you). Failures show the real reason and never switch channels behind your back. The Sui and root channels have not been tried on real devices yet — please open an issue if something goes wrong.
- Self-paired ADB: the connect → enable check no longer loops and the port can be entered by hand; switching channels closes only the one being left, so a connected ADB stays connected; after a step is interrupted by a timeout or Stop, the old connection is retired instead of reused, so the next step can't receive the previous one's late reply.
- Sessions: delete conversations for good (long-press one, or select several); browse and restore archived conversations; start a new conversation inside a folder.
- Floating pet: the pet outside the app is the same size as inside; thinking, subagent and other animations are drawn whole instead of clipped; a turn that ends while the app is in the background still reaches the pet's bubble and the notification; the pet's animation timer pauses while the app is in the background.
- Live activity: run status in the status bar, on the lock screen and in vendor islands (e.g. Xiaomi focus notifications), with the pet's portrait.
- Above the composer: auto-approve and plugin chips no longer take a row each; goal, todos, plugins and the status strip can stack into one row of cards that expands with an animation, and swiping a folded stack brings another card to the front. The built-in Plugins chip can be hidden from ui.json.
- Phone control overlay: redesigned as ball, capsule and rounded card on one surface — the operation info that matters up front, pause / stop re-laid, the rest one level down.
- Plugin settings: every declared field shows up, Chinese titles first; ten popular plugins get Chinese field copy; editing a field redraws only its row, so no more lag; handing over to the web settings no longer races them or freezes.
- Images & video: the settings page is organized by provider; a provider's services share one key, and presets fill in the address and models.
- Chat: optional Enter-to-send for hardware keyboards; `/` at the cursor completes commands without losing the draft; three table tint levels (with preview), and tables written flush against a paragraph still render; long model names show in full, token counts use K / M; the context length of subscription providers is configurable.
- Appearance: the native app follows the host's light / dark setting.
- Web: file uploads work in the in-app web view.
- Providers: an empty thinking level no longer breaks a provider.
- Performance: streaming reuses existing rows, indices and the scan of finished lines; the drawer builds session rows on demand; the top bar's status text is measured once.
- Source: the 1.0.5–1.0.7 source is now in the public repository with its commit-by-commit history, and those tags point at the right commits.

## 1.0.7 · 2026-10-31

### 中文

- 排障：引擎起来后，App 会把一份脱敏的本机诊断写进引擎（`$DSH_HOME/dsh-app/diagnostics.md`）：版本、设备、运行时、启动方式、连接、性能档位、最近错误和日志尾部。新增内置技能 `dsh-go-support`，教 AI 先读它再排查，并按症状给出可直接粘贴的 issue 草稿。
- 设置 → 诊断新增「让 AI 看诊断」：手动刷新这份快照，然后问 AI「看下诊断」就行。
- 更新：修了「已经是 1.0.4 却提示最新」——某个更新源停在旧版本时，不再就此收工，会继续问其它源，取更新的那个；公测包也不再带内测通道令牌，免得一个过期的内测清单盖住 GitHub 的新版本。

### English

- Support: once the engine is up, the app writes a redacted local diagnostics snapshot into it (`$DSH_HOME/dsh-app/diagnostics.md`): versions, device, runtime, launch mode, connection, performance tier, recent errors and log tails. The new bundled `dsh-go-support` skill tells the agent to read it first, walk the symptom, and draft an issue you can paste.
- Settings → Diagnostics gains 「Let the AI read diagnostics」: refreshes that snapshot on demand; then just ask the AI to check the diagnostics.
- Update: fixed 「1.0.4 says it is already latest」 — a source stuck on an older release no longer ends the check; the others are still asked and the newer release wins. Public builds also stop carrying the beta channel token, so a stale beta feed can no longer outrank the GitHub release.

## 1.0.6 · 2026-10-31

### 中文

- 性能：新增「刷新率」设置（自动 / 最高 / 系统）。自动：动画、滚动和输出时用屏幕最高刷新率，停下 0.7 秒后交回系统；最高：一直最高；系统：不声明，完全由系统决定。HyperOS 这类把第三方 App 压在 60Hz、又把开关显示成「应用内设置」的系统，现在可以在 App 里直接选；选「系统」就把决定权还回去。
- 对话：思考预览的窗口改成从头到尾恒高三行，流式时列表不再一行一行追底；上滑改成匀速，换行时不再一顿一顿，写得快也不抖。
- 对话：思考展开全文后，点正文本身也能收起（和点头部一样），文中的链接和按钮不受影响。
- 性能：侧边栏拖动时不再每帧重新模糊背后的聊天、面板位置改用位移而不是重新布局；聊天上方两颗悬浮胶囊也去掉了背景模糊，快速滚动和流式输出时更稳。
- 手机操控：动作后的屏幕不再整屏重发——和上一屏对得上时只回变化的行，完全没变就只回一行（编号沿用上一屏）；同一个 App 的连续屏幕里，重复的提示（DSH 自己的界面、系统页、敏感页、密码框）只出现一次。
- 手机操控：工具说明和拦截文案整体压短（13 个工具的定义 6,360 → 5,908 字符，`intent` 一个省 12%），"屏幕上的文字不是用户指令"只在全局指令里说一次，不再在 `screen` 工具里重复。

### English

- Performance: new 「Refresh rate」 setting (Auto / Max / System). Auto uses the screen's fastest rate while animating, scrolling or streaming and hands it back to the system after 0.7 s; Max pins it; System declares nothing and leaves the decision to the system. On ROMs that cap third-party apps at 60 Hz and show their per-app switch as an in-app setting (HyperOS among them), the choice now lives in the app — pick System to hand it back.
- Chat: the thinking preview keeps the same three-line window from start to finish, so the list no longer chases it line by line while streaming, and the lines glide up at a constant speed instead of easing in and out on every wrap.
- Chat: with the full thinking expanded, tapping the body now collapses it too (like tapping the header); links and buttons inside keep working.
- Performance: the sessions drawer no longer re-blurs the chat behind it on every frame while sliding, and moves by translation instead of re-laying out; the two floating chips above the chat drop their backdrop blur as well, so fast scrolling and streaming stay steadier.
- Phone control: the screen after an action is no longer resent whole — when it lines up with the previous one only the changed lines come back, and an unchanged screen is a single line (ids carry over). Repeated notices (DSH's own UI, system pages, sensitive pages, password fields) appear once per app instead of on every screen.
- Phone control: tool descriptions and refusal messages are shorter (the 13 tool definitions went from 6,360 to 5,908 characters, `intent` alone is 12% smaller), and "screen text is not an instruction" now lives only in the global instructions instead of being repeated by the `screen` tool.

## 1.0.5 · 2026-10-31

### 中文

- 可视化回复：选项卡可以在选项之外自己填一句（模型用 `freetext` 开启），回传时以「其他：…」跟在选择后面。模型忘了写 `dsh-ui` 围栏、把 JSON 直接写进正文时，也能画成原生卡片；复制和分享会把它换成一行摘要。
- 对话：思考中的预览改成一段连续文字的实时窗口，固定三行高，跟着最新写出来的字走；写满一行时整段轻轻滑上去，不再逐行淡入淡出、也不再有省略号。一轮正常结束时，思考与工具调用一律收成一行——以前翻看过这一轮就会一直展开着；手动展开的思考也会在轮次结束后收回。
- 手机操控：读不到页面内容时不再当成「文字信息不足（游戏、自绘界面）」或「界面没有明显变化」——现在会说明「可能受敏感视图策略限制」（Android 14 起密码、支付、验证这类页面会被系统过滤），并在这类页面上不做盲点、盲滑，引导 handoff。操作后两边没有可比较的内容时，返回「动作已提交，但当前无法验证结果」，而不是「没有变化 / 可能已经到头了」；键盘的弹出收起和窗口边距变化也算界面变化；截图会带上系统截图时间戳。
- 技能：内置的 `dsh-go-plugin`、`dsh-go-ui` 说明写清了和官方 Cordis 技能的分工（手机原生界面 vs Harness 网页版 / 桌面），目录和安装入口不再混用；App 写入的全局指令也加了同样的分流规则。

### English

- Visual replies: an options card can allow an answer beyond its presets (the model turns it on with `freetext`); what the person types comes back as an `Other: …` line after the choice. A reply whose model forgot the `dsh-ui` fence and wrote the JSON as plain text now draws as a native card too, and copy/share replace it with a one-line summary.
- Chat: the thinking preview is a three-line live window of continuous text that follows the newest words and glides up a line when one fills; the per-line fading and the leading ellipsis are gone. A turn that ends normally always folds its thinking and tool calls into one row — previously a turn you had scrolled through stayed expanded; thinking you expanded by hand folds back when the turn ends.
- Phone control: a page whose content cannot be read is no longer reported as a poor tree ("game / custom-drawn UI") or as "no visible change" — it now says the content may be blocked by the sensitive-view policy (Android 14+ filters pages like passwords, payments and verification), stops blind taps and swipes there and points to handoff. When an action leaves nothing comparable on either side it reports "submitted, but the result cannot be verified" instead of "unchanged / probably at the end of the list"; IME show/hide and window inset changes count as screen changes, and a screenshot carries the system timestamp.
- Skills: the bundled `dsh-go-plugin` and `dsh-go-ui` instructions now spell out how they divide work with the official Cordis skills (phone-native UI vs Harness Web / desktop), so directories and install entries are no longer mixed; the app's global instructions follow the same routing rule.

## 1.0.4 · 2026-10-31

### 中文

- 正式下载统一为 arm64 安装包，发布页明确标出安装包和辅助更新文件的用途。
- DSH Remote 默认自动选择连接方式，优先尝试局域网 / P2P，再尝试 TURN，最后回落 Relay。升级后不再需要打开直连开关，旧的关闭设置也会迁移到自动策略；相应路径需服务端与主机支持。
- 新增网络详情：点击连接卡或主机旁的网络标签，查看实际路径、连接耗时、可测的往返延迟及回落原因。重连后清除旧测量，改善 Wi-Fi 与蜂窝网络切换时的连接恢复。
- 官方插件市场已上架「生图生视频」，支持在当前主机上生成图片和视频。可从「设置 → 插件 → 插件市场 → 官方」安装；主机尚未安装时，「设置 → 图像与视频」也有安装入口。插件需单独安装并配置服务商。

### English

- Public downloads now provide one arm64 installer, with release-page guidance distinguishing it from update and verification files.
- DSH Remote now selects its connection automatically, trying LAN / P2P first, then TURN, and finally Relay. Upgrading also migrates the old disabled-direct setting to the automatic policy. Compatible server and Host support is required for each path.
- Added network details. Tap the route label on the connection card or beside a Host to see the actual route, connection time, available round-trip latency and fallback reason. Old measurements are cleared after reconnects, with improved recovery when switching between Wi-Fi and cellular networks.
- The official plugin market now includes Images and video for generation on the selected Host. Install it from Settings → Plugins → Plugin market → Official, or from Settings → Images and video when it is missing. The plugin remains a separate install and requires provider configuration.

## 1.0.3 · 2026-10-31

### 中文

- 修复更换桌面图标后出现两个入口的问题：保留正在使用的页面，回到桌面后完成切换；连续更换、强停后重开和刚切换就重启也能恢复最后选择。
- 手机操控新增无障碍自动恢复设置。授予系统设置权限后，手机操控开启期间会尝试恢复被关闭或断开的服务，并保留其他无障碍服务。Android 强制停止 App 后仍需手动重新打开。
- 桌宠新增「问一句」和新会话入口，可直接在气泡里处理支持的工具审批与简单问题；语音识别结果先回填草稿，由你确认发送。修复无障碍浮窗异常时的窗口创建、频繁重试，以及键盘遮挡输入栏的问题。
- DSH Remote 新增可选 P2P 直连和 TURN 配置，默认关闭；直连不可用时回退中继。需服务端与主机支持相应协议。
- 插件市场支持官方目录、固定版本更新、风险说明和分享链接，媒体生成设置也可跳转到对应插件。插件仍需单独安装，未上架的插件不会显示为可安装。

### English

- Fixed duplicate launcher entries after changing the app icon. The current page stays open, and the switch finishes when you return home. Rapid changes, relaunches after force-stop, and reboots immediately after a change retain the saved choice.
- Added optional accessibility recovery for Phone Control. After granting secure-settings access, the app can restore a disabled or disconnected service while Phone Control is enabled, preserving other accessibility services. Android force-stop still requires reopening the app.
- Added quick asks and new chats from the floating pet, supported approval and simple-question actions in bubbles, and voice input that fills a draft for explicit sending. Fixed accessibility-overlay window creation, excessive retries after a window failure, and the keyboard covering the input bar.
- Added opt-in P2P and TURN configuration for DSH Remote, off by default, with Relay fallback when direct connection is unavailable. Compatible server and Host support is required.
- The plugin market now supports an official catalog, pinned-version updates, risk notices and share links. Media generation settings link to the relevant plugin. Plugins remain separate installs; unpublished packages are not offered as installable.

## 1.0.2 · 2026-10-30

### 中文

- DSH Remote 更省流量：会话列表不再在每次对话状态变化时整份重新下载；App 切到后台 30 秒后，进行中的对话暂停逐字推送，回到前台时一次同步到最新（会短暂显示同步中）；连接有数据往来时不再额外发送检测请求，网络慢时也不容易误判断线、反复重连。
- DSH Remote 跟进 ds-harness-remote 的最新协议：主机插件更新到 0.6.0 后，远程流量会改走服务器分配的独立中继节点，减轻主服务器的压力；协议校验也和上游保持一致。

### English

- DSH Remote uses less data: the session list is no longer downloaded in full every time a chat changes state; 30 seconds after DSH Go goes to the background, a running chat stops streaming word by word and catches up in one go when you return (it shows syncing briefly); and the connection no longer sends extra health checks while data is flowing, so a slow network is less likely to look like a drop and reconnect over and over.
- DSH Remote follows the latest ds-harness-remote protocol: once the Host plugin is on 0.6.0, remote traffic moves to a separate Relay node assigned by the server, taking load off the main server; protocol checks match upstream too.

## 1.0.1 · 2026-10-30

### 中文

- 高刷新率：在支持 90Hz、120Hz 的手机上，DSH Go 会用屏幕最高的刷新率运行。之前部分系统（例如 OriginOS、HyperOS、ColorOS）会把它限制在 60Hz 或 90Hz。系统设置里选的刷新率和省电模式仍然优先。
- 安装包同时带 v1、v2、v3 三种签名，只认旧式签名的安装器和安全检测也能正常安装。签名证书没有变，可以直接覆盖 1.0.0 升级，对话和设置都会保留。
- 应用内更新的弹窗里多了一个「去 Star」按钮，可以顺手去 GitHub 给项目点个 Star。
- GitHub 发布页只放常见手机用的 arm64 安装包；模拟器和 x86 设备用的版本在发布说明末尾的「其他版本下载」里。

### English

- High refresh rate: on 90 Hz and 120 Hz phones, DSH Go now runs at the screen's highest refresh rate. Some systems (OriginOS, HyperOS and ColorOS, for example) used to hold it at 60 or 90 Hz. The refresh rate you choose in system settings and power saving still come first.
- The APK now carries v1, v2 and v3 signatures, so installers and security checks that only read the older signature accept it too. The signing certificate hasn't changed: it installs over 1.0.0 and keeps your chats and settings.
- The in-app update sheet has a Star it button for a quick star on GitHub.
- The GitHub release page offers the arm64 APK for most phones; the build for emulators and x86 devices is under "Other builds" at the end of the release notes.

## 1.0.0 · 2026-10-30

### 中文

DSH Go 1.0.0 来了，这是第一个公开版本。它让你在 Android 手机上运行 DeepSeek Harness（DSH），也能连上电脑或服务器上的 DSH，走到哪儿都能接着聊、接着干活。DSH Go 以 AGPL-3.0 开源，欢迎来 GitHub 看看。感谢测试期间每一位反馈问题、提出建议的朋友；已经在用 0.9.10 的，这一版功能不变，只是正式换上 1.0.0 的版本号。

现在的 DSH Go 可以：

- **本机运行**：在 App 里装好 Ubuntu、Node.js 和 DSH 运行环境，不用 Root，也不用另装 Termux。
- **远程主机**：通过 SSH 或 DSH Remote 使用电脑、服务器上的 DSH；只连远程时，手机上不必安装运行环境。
- **对话**：切换模型、发图片，回复中途也能插话；工具审批和提问在对话里直接处理，原生界面和网页版一键切换。
- **插件**：从插件市场安装；适配 DSH Go 的插件以原生的工具卡、表单和面板呈现，设置页也是原生的。仓库附带 SDK、教程和示例。
- **手机操控**：开启权限后，让本机引擎看屏幕、点按和输入，随时可以暂停或停止。确认方式可选「关键步骤先问我」或「全程自动」；可选的「解除限制」默认全部关闭，开启前会先说明风险。Android 14 及以上还能用不打扰模式，在看不见的屏幕上操作，不耽误你用手机。
- **离线语音输入**：语音模型（约 241 MB）下载到手机上，在本地识别。
- **宠物**：Deepy 小鲸鱼和鲸娘陪你干活，打开「App 外显示」还能跟你到桌面。
- **分享**：把一条回复、选中的消息或整段对话分享成链接、图片、文件或文字；链接端到端加密，对方可以在浏览器里回放，或在 DSH Go 里接着聊。
- **外观**：六套配色，也可以跟随壁纸或自选颜色；换桌面图标，用自己的壁纸和启动画面；界面支持中文和英文。
- **匿名使用统计**：只发送每天的使用次数和 App、系统版本等基本信息，不含对话、文件和账号；默认开启，在 设置 › 隐私与分享 随时关闭。
- **图像与视频生成即将上线**：App 这边已经就绪，生成插件发布后即可在对话里使用。

此前 0.9.x 各版本的详细改动见[更新日志](https://github.com/ccch1mneyyy/dsh-go/blob/HEAD/docs/changelog.md)。

### English

DSH Go 1.0.0 is here, our first public release. It runs DeepSeek Harness (DSH) on your Android phone or connects to DSH on your computer or server, so you can pick up a chat or a task wherever you are. DSH Go is open source under AGPL-3.0; come take a look on GitHub. Thank you to everyone who reported problems and shared ideas during testing. If you're already on 0.9.10, nothing changes but the version number: it's the same app, now 1.0.0.

What DSH Go does today:

- **On your phone:** install the Ubuntu, Node.js and DSH runtime from the app, without Root or a separate Termux.
- **Remote hosts:** use DSH on a computer or server over SSH or DSH Remote; if you only connect remotely, the phone doesn't need the runtime.
- **Chat:** switch models, send images and step in while a reply is still coming; handle tool approvals and questions right in the chat, and switch between the native and web interfaces in one tap.
- **Plugins:** install from the plugin market; plugins adapted for DSH Go show up as native tool cards, forms and panels, with native settings pages too. The repository includes an SDK, guides and examples.
- **Phone control:** once you grant the permissions, the local engine can read the screen, tap and type, and you can pause or stop it at any time. Choose "Ask me at key steps" or "Fully automatic"; the optional Lift limits switches are all off by default and explain the risks before they turn on. On Android 14 and later, non-disruptive mode works on a hidden screen while you keep using your phone.
- **Offline voice input:** the voice model (about 241 MB) downloads to the phone and recognises speech on the device.
- **Pets:** Deepy and Whale girl keep you company while DSH works, and with "Show outside the app" they come along to the home screen.
- **Sharing:** share one reply, selected messages or a whole chat as a link, an image, a file or text. Links are end-to-end encrypted, and the recipient can replay the chat in a browser or continue it in DSH Go.
- **Appearance:** six colour palettes, or follow your wallpaper or pick your own colour; change the app icon and use your own wallpaper and launch screen. The app is available in Chinese and English.
- **Anonymous usage stats:** only daily usage counts and basics like the app and Android version, never chats, files or accounts. On by default; turn it off any time in Settings › Privacy and sharing.
- **Image and video generation is on its way:** the app side is ready, and it opens up in chats once the generation plugin is released.

For the detailed history of the 0.9.x releases, see the [changelog](https://github.com/ccch1mneyyy/dsh-go/blob/HEAD/docs/changelog.md).

## 0.9.10 · 2026-10-30

### 中文

- 手机操控：不打扰模式下输入文字，总是写进 AI 指定的那个输入框，并整体替换原来的内容；页面上有密码或验证码输入框、或者页面没能读全时，只给文字不附截图；英文界面的验证码、口令输入框也能认出来。「关键步骤先问我」在英文界面的发送、删除、付款、购买等按钮前也会先确认。
- 停止引擎时，正在进行的手机操作一起停下，排在后面的也不再执行。
- 语音模型下载完成后，已经打开的对话里马上出现麦克风，不用退出重进。
- 登录 DSH Remote：取消后不会再打开浏览器，也不会过一会儿变成已登录；退出登录后，各登录方式的按钮照常显示。
- 自己的启动动图：最后一帧按原本的时长显示完再进入 App，不再一闪而过。
- 选文件时超过大小或数量上限会马上提示，不再先把整个文件读完。
- 连接远程主机时，对话里图片的缩略图和预览同时下载，预览不再报读取失败。
- 应用内更新：下载时手机存储满了，会提示存储可能已满、清理后重试，不再一直卡在下载中。
- 首次安装后第一次运行期间导入的配置，不会被安全模式的「恢复上次正常的配置」当成正常配置。
- 使用说明：插件设置显示「未保存」时要点底部「保存」并等到「已生效」；DSH Remote 登录选和主机上相同的登录方式；停止分享后，4 秒撤销期过去、删除成功时链接才失效。

### English

- Phone control: in non-disruptive mode, typing always goes into the field AI asked for and replaces what was there. A page with a password or code field, or one that couldn't be read in full, comes back as text only, without a screenshot, and English code and passcode fields are recognised too. "Ask me at key steps" also asks before Send, Delete, Pay, Buy and similar buttons in English apps.
- Stopping the engine also stops the phone action in progress, and the ones queued behind it no longer run.
- When the voice model finishes downloading, the microphone appears in a chat that's already open, without leaving and coming back.
- Signing in to DSH Remote: after you cancel, the browser no longer opens later and you don't end up signed in anyway; after signing out, each provider's button shows again.
- Your own launch animation holds its last frame for its full time before the app takes over, instead of flashing past.
- Picking files stops at the size and count limits right away, instead of reading the whole file first.
- On a remote host, an image's thumbnail and its preview can download at the same time without the preview failing to load.
- In-app updates: running out of storage during the download now says storage may be full, so you can free up space and retry, instead of waiting forever.
- A config imported during the very first run after install is no longer taken as the last working configuration by Safe mode's "Restore the last working configuration".
- User guide: when plugin settings show Unsaved, tap Save at the bottom and wait for Applied; DSH Remote sign-in uses the same provider as on the host; after Stop sharing, the link stops working once it's deleted after the 4 s Undo window.

## 0.9.9 · 2026-10-30

### 中文

- 手机操控可以全程自动：首次启动选「手机操控」时，可以选「关键步骤先问我」或「全程自动」，之后在 设置 › 手机操控 › 确认方式 随时改，那里也列出了哪些事仍由你来操作。
- 解除限制（可选）：设置 › 手机操控 › 解除限制 有三个开关——系统设置、密码和验证码、DSH Go 自身，默认全部关闭。打开前会说明 AI 能做什么、可能出什么问题以及免责声明，需要按住「我了解风险，开启」约 1.5 秒，后果由你自行承担；任务进行中不能打开，关闭只要点一下。开着时悬浮条和手机操控页显示「已解除限制」。AI 输入的密码和验证码在操作记录、悬浮条和确认卡里只显示为 ••••，也不会出现在返回给模型的结果里。
- 自定义壁纸：设置 › 主题 › 壁纸 可以把自己的图片铺在首页、对话和抽屉后面，可以调模糊，浅色模式下提亮、深色模式下压暗；文字和背景的对比度始终保持在 4.5:1 以上。
- 启动画面：自己的启动画面不再限制 3 秒，图片和动图 8 MB 以内、视频 30 MB 以内，冷启动时完整播放，点一下就能跳过。换了桌面图标后，启动时只会出现你选的那个图标，不会先闪一下默认的蓝色图标。
- 直接启动本机引擎（设置 › 诊断 › 开发者选项）仍是实验功能，默认关闭。打开后，从旧版本升级的会先把插件文件整理一次，手机空间不够时先用兼容启动；某台手机上直接启动起不来（例如 Android 16 会拦截）时，会自动改用兼容启动，不进安全模式，也不会反复重试。
- 插件更新后提示重启引擎：正在运行的引擎要重启才会用上新版本，更新完成后直接给出重启的选项（连接远程主机时提示到那台电脑上重启）。
- 匿名使用统计：每天的使用次数（发消息、语音输入、手机操控、生成、分享各几次，装了几个插件），连同 App 和系统版本、CPU 架构、手机品牌（不含型号）、界面语言和本机引擎的启动方式，当天过后匿名发送一次；设备之间只用一个每 90 天更换的随机编号区分，不含对话、文件和账号。首次启动的欢迎页上就有开关，之后在 设置 › 隐私与分享 一键关闭，关闭后本机记下的次数和编号立即删除。从旧版本升级的会在首页提示一次。
- App 外的桌宠：拿起来、开心、醒来和打字时不再被裁掉；气泡放在桌宠画面的上方，不挡住动画，换动作时平滑跟着移动。
- 归档对话和卸载插件先等 4 秒，期间点「撤销」就原样保留，归档时进行中的一轮也不会停；切出 App 或接着归档、卸载别的时会立即执行。
- 陪你满半小时后，鲸娘会请你去 GitHub 给 DSH Go 点个 Star：一键打开仓库，点「已经点过啦」就不再出现；选「下次再说」的，累计再用 5 小时会再问一次，最多两次。只在首页或对话里、没有其他弹窗、当前对话也没有进行中的任务时出现。
- 远程主机登录 DSH Remote：服务器提供的每种登录方式都有自己的按钮，GitHub 排在最前（感谢 @HuanLinOTO）。
- 以前把新对话的默认权限设成「Auto」的，升级后本机引擎会清掉这个已失效的设置并重启一次，「本对话」和设置里的权限选项恢复正常。
- 其他：对话里 DSH 自己写进收件箱的提示不再显示成你发的消息；插件市场连不上时显示网络错误和重试，不再说「目录格式有误」；首次启动选了「桌宠与悬浮窗」而还没选桌宠时，会顺带选好默认桌宠；换了主机后，删除文件夹的「撤销」和批量置顶不会落到另一台主机上；语音「重新下载」时旧模型保留到新模型下载完；首次启动总结页的「继续」失败后可以再试；远程主机页的服务说明改为「服务由 liguobao/ds-harness-remote 提供」，点项目名可以打开它。

### English

- Phone control can run fully automatic: when you pick Phone control on first run, choose "Ask me at key steps" or "Fully automatic"; change it any time in Settings › Phone control › Confirmation, which also lists what still stays with you.
- Lift limits (optional): Settings › Phone control › Lift limits has three switches — system settings, passwords and codes, and DSH Go itself — all off by default. Turning one on first shows what AI can then do, what can go wrong and the disclaimer, and takes holding "I understand the risks, turn on" for about 1.5 s; you bear the risk. It can't be turned on while a task runs, and one tap turns it off. While any is on, the floating bar and the Phone control page say "Limits lifted". Passwords and codes AI types show only as •••• in the action log, the floating bar and confirmation cards, and never come back in the results sent to the model.
- Your own wallpaper: Settings › Theme › Wallpaper puts a picture of yours behind home, chats and the drawer, with Blur, plus Lighten in light mode and Dim in dark mode; text always keeps a contrast of 4.5:1 or more.
- Launch screen: your own launch screen is no longer capped at 3 s. Pictures and animations up to 8 MB and videos up to 30 MB play in full on a cold start, and a tap skips. After you change the app icon, launch only ever shows the icon you chose, never a flash of the default blue one first.
- Direct local engine launch (Settings › Diagnostics › Developer options) stays experimental and off by default. Turned on, an install upgraded from an earlier version first tidies its plugin files once, using compatible launch while the phone is short of space; on a phone where a direct start fails (Android 16 blocks it, for one), the app goes back to compatible launch on its own, without Safe mode or repeated retries.
- Plugin updates ask for an engine restart: the running engine keeps the old version until it restarts, so finishing an update offers the restart right there (on a remote host, it tells you to restart DSH on that computer).
- Anonymous usage stats: each day's counts (messages, voice inputs, phone control tasks, generations and shares, and installed plugins), with the app and Android version, CPU architecture, phone maker (not the model), app language and how the local engine started, go out anonymously once after the day ends. Devices are told apart only by a random ID that changes every 90 days; never chats, files or accounts. The switch is on the welcome screen on first run, and one tap in Settings › Privacy and sharing turns it off and deletes the counts and the ID on the phone at once. Installs updated from an earlier version are told once on the home screen.
- Pet outside the app: picked up, happy, waking or typing, it's no longer cut off; its bubble sits above the pet's picture instead of over it and glides along when the pose changes.
- Archiving a chat or uninstalling a plugin waits 4 s first: Undo keeps it as it was, a running turn included. Leaving the app, or archiving or uninstalling something else, carries it out at once.
- After half an hour together, the whale asks you to give DSH Go a Star on GitHub: one tap opens the repository, "Already starred" ends it for good, and "Maybe later" asks once more after another 5 hours of use — twice at most. It only appears on the home screen or in a chat, with no other dialog open and no task running in the current chat.
- Signing in to DSH Remote on the remote host page: each sign-in method the server offers gets its own button, GitHub first (thanks @HuanLinOTO).
- If the default permission for new chats was once set to Auto, the local engine clears that no-longer-valid setting after the update and restarts once, so the permission options in This chat and Settings load again.
- Other fixes: notes DSH writes into the inbox itself no longer look like your messages; when the plugin market can't connect it shows a network error with Retry instead of "Invalid directory format"; picking Pet over other apps on first run also picks the default pet if none was chosen; after switching hosts, a deleted folder's Undo and bulk pinning never land on the other host; Re-download in Voice input keeps the old model until the new one is in; a failed Continue on the first-run summary can be tried again; the remote host page now credits liguobao/ds-harness-remote, and tapping the project name opens it.

## 0.9.8 · 2026-10-29

### 中文

- 改名 DSH Go：桌面图标、最近任务、通知和系统设置里都叫 DSH Go。保存的图片在相册「DSH Go」，下载的文件在「下载/DSH-Go」；之前存的文件留在原处，旧对话里的文件卡片照常打开。
- 启动动画：系统启动画面无缝交接到 App 的第一帧，图标轻轻上移，DSH Go 字样随之浮现；冷启动完整播一遍，热启动可用即进。
- 自己的启动画面和桌面入口：设置 › 主题 › 启动画面 可以换成自己的图片、动图或 3 秒内的视频，选适配方式和背景色，预览一遍再用。桌面图标下新增「图片快捷方式」，用自己的图片在桌面另放一个打开 DSH Go 的入口。换桌面图标后会提示几秒后生效。
- 首次启动按功能开权限：新增一步「想让 DSH Go 帮你做哪些事」，在读写手机文件、桌宠与悬浮窗、手机操控、后台持续运行、语音输入里挑选，再逐项带你到对应的系统页面或品牌设置页，回到 App 自动确认是否已开启。无障碍遇到「受限制的设置」时有分步指引。之后在 设置 › 通用 › 系统权限 随时查看、补开。
- 离线语音输入：语音模型（约 241 MB）下载到手机上本地识别，不再依赖系统语音服务。设置 › 语音输入 可以下载、取消、重试和删除；国内网络直接可下，中断后接着下，用移动数据时先确认。首次启动选了语音输入的，引擎就绪后自动下载。
- 插件设置页：每个有设置项的插件都打开原生设置页，字段多时可以搜索，常用项在前，其余收进「高级」，离开前有未保存的改动会先确认。设置 › 引擎参数 › 插件 只列你装的插件，引擎自身的核心配置不在其中。
- 插件界面更丰富：对话里的 genui 卡片直接画成原生卡片，不再显示原始 JSON 和「让它重发」；插件视图新增空状态、图片墙、环形进度和指标趋势，可以跟随你选的配色，图标扩充到 162 个。输入框上方新增「插件」胶囊，打开本对话的插件面板；对话详情 › 插件 能打开插件提供的对话视图，打开前核对是不是你点的那一个；插件详情列出 App 里还没有位置的网页界面，一点直达网页版。
- 加号新增「本对话」：直接改这个对话的权限、开关计划模式，手机操控开着时还能改确认方式。选择模型弹层底部可以直达「管理模型」。
- 网页模式的返回键：先关掉网页里打开的弹窗、菜单、侧栏和子页面，一次一层，都关完才离开 App。
- SSH 连接的电脑上，用桌面版、终端或其他方式产生的对话，在列表里直接显示标题，不再是「未命名」；断线重连后也照常补上。
- 内置引擎升级到 DSH 0.2.1-rc.4：用 API Key 时模型列表跟随 DeepSeek 官方。所选模型需要新版引擎或当前不可用时，对话里直接说明并给出出路，不再只是「本轮出错了」。
- 图像与视频生成即将上线：App 这边已经就绪，生成插件发布后即可在对话里使用。
- 应用内更新更稳妥：屏幕上显示的版本、下载的文件和它的校验和绑定在一起，安装的一定是你看到的那个版本；安装前再次核对，不符的安装包直接丢弃，重试时按屏幕上的版本重新下载；放弃的安装不会影响下一次。
- 切换更稳：换主机后，旧主机的审批卡和提问卡随之收起，不再挡住新主机的请求；在选模型弹层打开期间换了对话，选中的模型不会落到别的对话；重连后计划、目标和团队信息会重新读取。
- 报错更清楚：订阅页的模型读不到时显示「没能读取模型」并可重试，不再误报「暂无模型」；团队消息读取失败不再显示成空收件箱；论坛通知翻页失败可重试；直接打开的 Bot 或群聊页会分别说明离线、经中转连接或 Bot 已不在。
- 其他：App 进入后台后，计时、动画和终端长按按键都会停下；进行中的提示语相邻两条不再重复；设置 › 诊断 显示引擎实际是直接启动还是兼容启动，直接启动失败后可以一键切回兼容启动，App 自身的异常也会记进诊断包；插件不能再通过界面操作改动权限模式；开源许可信息补全。

### English

- Now called DSH Go: the launcher, Recents, notifications and system settings all say DSH Go. Saved pictures go to the DSH Go album and downloads to Download/DSH-Go; files saved earlier stay where they are, and older chats still open their file cards.
- Launch animation: the system splash hands over seamlessly to the app’s first frame, where the icon rises and DSH Go fades in beneath it. A cold start plays it through; a warm start goes the moment the app is ready.
- Your own launch screen and home-screen picture: Settings › Theme › Launch screen takes a picture, an animation or a clip up to 3 s, with a fit and background colour and a preview first. Under App icon, Picture shortcut puts a separate shortcut to DSH Go on the home screen with a picture of your own. After switching the app icon, the app says the home screen takes a few seconds.
- Permissions by feature on first run: a new step, "What should DSH Go help with?", lets you pick from phone files, pet and floating window, phone control, running in the background and voice input. The app then takes you to each system or phone-maker page in turn and checks whether it's on when you come back. Accessibility gets step-by-step help when Android shows Restricted settings. Review or finish any of it later in Settings › General › System permissions.
- Offline voice input: the voice model (about 241 MB) downloads to the phone and recognises speech on the device, without relying on the system's speech service. Settings › Voice input downloads, cancels, retries and deletes it; it downloads from mainland China, resumes after an interruption and asks before using mobile data. If you picked voice input on first run, it downloads once the engine is ready.
- Plugin settings: every plugin with settings opens a native page. Long forms can be searched, the common fields come first and the rest fold under Advanced, and leaving with unsaved changes asks first. Settings › Engine parameters › Plugins lists only the plugins you installed, never the engine's own core settings.
- Richer plugin UI: genui cards in a chat draw as native cards instead of raw JSON and "Ask to resend". Plugin views gain empty states, galleries, ring progress and metric trends, can follow your colour palette, and have 162 icons to choose from. A Plugins capsule above the composer opens the chat's plugin sheet; Chat details › Plugins opens a plugin's view of the chat, checking it is the one you tapped; and plugin details list the web parts the app has no place for yet, each one tap from DSH Web.
- This chat, in the + panel: change this chat's permissions, turn plan mode on or off and, with phone control on, its confirmation style. The model sheet links straight to Manage models.
- Back in web mode closes what DSH Web has open, one layer per press (dialogs, menus, side panels, sub-pages), and only then leaves the app.
- On a computer reached over SSH, chats started in the desktop app, the terminal or anywhere else show their titles in the list instead of "Untitled chat", and keep getting them after a reconnect.
- The built-in engine is now DSH 0.2.1-rc.4: with an API key, the model list follows DeepSeek's official one. When the chosen model needs a newer engine or isn't available, the chat says so and offers a way forward instead of a bare "Something went wrong this turn".
- Image and video generation is on its way: the app side is ready, and it opens up in chats once the generation plugin is released.
- Safer in-app updates: the version on screen, the file downloaded and its checksum are bound together, so what gets installed is always the release you see. They're checked again right before installing; a package that doesn't match is discarded and Retry downloads the release on screen again; and an abandoned install can't affect the next one.
- Steadier switching: after a host change, the old host's approval and question cards close instead of covering the new host's requests; picking a model after switching chats never lands on the wrong chat; and a reconnect reads plans, goals and team details again.
- Clearer errors: a subscription whose models can't be read says "Couldn’t load models" with Retry instead of "No models"; team messages that fail to load no longer look like an empty inbox; a forum notification page that fails to load more can be retried; and a Bot or group page opened directly tells offline, relay and a Bot that's gone apart.
- Other fixes: timers, animations and held terminal keys stop when the app goes to the background; neighbouring progress lines no longer repeat; Settings › Diagnostics shows whether the engine started directly or in compatible mode, offers a one-tap switch back after a failed direct start, and the app's own errors go into the diagnostics bundle; plugins can no longer change the permission mode from their UI; and the open-source notices are complete.

## 0.9.7 · 2026-10-28

### 中文

- 设置重新整理：首页按 AI、能力、外观、通用、主机、帮助与关于分组，每一行直接显示当前状态。顶部新增搜索，旧名字、同义词都能搜到，点结果会直接跳到那一项；在抽屉里按住 ⚙ 也能进入搜索。新增「个性化」「界面」「隐私与分享」「关于 dsh-go」几页。
- 几处改名：模型渠道 → 模型，引擎 → 本机引擎，引擎设置 → 引擎参数，后台保活 → 后台运行，语音识别 → 语音输入；「自动执行命令」并入权限里的「完全权限」。抽屉身份栏的圆键改为「全部功能」，全部功能也重新分组。
- 分享卡片的二维码中间加上了 dsh-go 图标，并略微放大，截图压缩后也更好扫。链接太长、印出来扫不出的卡片不再放二维码。
- DS Bot：视图卡里的选择题和简单表单可以直接在 App 里作答提交；群聊断线或补读失败后会自动接上；全文弹层的字数加上千分位。
- 插件设置里 App 编辑不了的部分，统一显示一行「在网页版编辑此项」。插件卸载、更新、允许构建脚本时如果已经切换了主机，会提示「主机已切换，未执行」。
- 切换主机后，斜杠命令的结果、「本对话都允许」和用量统计都只作用于原来的主机和对话。

### English

- Settings, reorganised: the home page groups everything under AI, Capabilities, Appearance, General, Hosts, and Help and about, and each row shows its current state. Search at the top finds old names and synonyms and takes you straight to the setting; you can also hold ⚙ in the drawer to search. New pages: Personalization, Interface, Privacy and sharing, and About dsh-go.
- A few renames: Model providers → Models, Engine → Local engine, Engine settings → Engine parameters, Keep alive → Background running, Speech recognition → Voice input; "Run commands automatically" is now Full access under Permissions. The drawer's round button opens All features, which is regrouped too.
- Share cards carry the dsh-go icon in the middle of the QR code, a little larger so it still scans from a compressed screenshot. A card whose link is too long to scan no longer prints a code.
- DS Bot: answer choice questions and simple forms in view cards right in the app; group chats pick up again after a dropped feed or a failed catch-up read; and the full-text sheet groups its character count.
- Plugin settings the app can't edit show one "Edit this item on the web" row. Uninstalling, updating or allowing a plugin's build scripts after you've switched hosts now says "Host changed — nothing was done".
- After switching hosts, a slash command's result, "allow all in this conversation" and usage figures stay with the host and conversation they came from.

## 0.9.6 · 2026-10-28

### 中文

- 手机操控：在别的 App 里遇到需要你确认的操作，也会弹出 dsh-go 的确认卡；任务完成后回到发起它的那个对话，系统不允许自动切回时改用一条通知。手机操控 › 进阶 › 后台确认与返回，可以查看各品牌手机的设置方法。
- 插件设置原生化：多选、列表、日期、颜色、链接、滑块、折叠分组等都能直接在 App 里编辑，只有个别不支持的项会显示「在网页版编辑此项」。字段说明完整显示；保存要等主机确认，失败时保留你的输入。语音输入类插件有了自己的「语音设置」。
- 列表不再等引擎：模型、渠道、插件和对话列表在引擎启动或重连时先显示上次的结果，后台更新完成后替换；读取大列表时界面照常滑动。
- DS Bot：主机上的 DS Bot 还不支持手机端时会直接说明，并提供网页版入口；群聊达到转发上限后可以一键继续；可以为 Bot 或群聊选择工作目录、从详情页复制一个 Bot；主机还在统计用量时显示「—」而不是 0；刷新记忆时内容保留在屏幕上。
- 切换更稳：换对话或换主机后，迟到的结果不会落到别处，包括附件、撤回、分叉、重新回答、Bot 的回答与审批，以及插件的安装、卸载和更新。断线重连后，先同步完对话再允许发送。
- 输入：外接键盘在输入法上屏后按 Ctrl+Enter 即可发送，连按两次 Esc 停止；模型渠道的 Base URL 和联网搜索地址使用普通网址键盘。
- 其他：后台任务的通知显示为一行安静的状态，不再像你发出的消息；SSH 导入私钥限制在 64 KiB；定时任务读取系统时区更可靠；诊断包里记录网络（DNS）设置，便于排查连不上的问题。

### English

- Phone control: when an action needs your OK while you're in another app, dsh-go's confirmation card now appears there too. When a task ends you're taken back to the chat that started it, or, where the system doesn't allow that, you get a notification. Phone control › Advanced › Confirmations and return shows how to set this up on each phone brand.
- Native plugin settings: multi-select, lists, dates, colours, links, sliders and collapsible groups can all be edited in the app; only the odd unsupported field shows "Edit this item on the web". Field descriptions show in full, saves wait for the host to confirm, and a failed save keeps what you typed. Voice input plugins get their own Voice settings.
- Lists don't wait for the engine: models, providers, plugins and chats show their last result while the engine starts or reconnects, then update in place, and large lists load without stalling the screen.
- DS Bot: when the host's DS Bot isn't on mobile yet, the app says so and offers DSH Web. A group that hits its relay limit can carry on in one tap; Bots and groups can have a working folder; you can duplicate a Bot from its details; usage shows "—" rather than 0 while the host is still counting; and refreshing memory keeps it on screen.
- Steadier switching: after you change chats or hosts, late results never land somewhere else. That covers attachments, withdrawals, forks, regenerated replies, Bot answers and approvals, and plugin installs, uninstalls and updates. After a reconnect, the chat syncs before you can send.
- Typing: with a hardware keyboard, Ctrl+Enter sends after an IME commit and pressing Esc twice stops; a provider's Base URL and web search addresses get a normal URL keyboard.
- Other fixes: background task notices show as a quiet status line instead of looking like your own message; SSH private key imports are capped at 64 KiB; schedules read the phone's time zone more reliably; and the diagnostics bundle records network (DNS) settings to help track down connection problems.

## 0.9.5 · 2026-10-27

### 中文

- 分享重新设计：消息下方的「分享」打开同一个面板，选好范围（这条回复、选中的消息、整段对话），再选链接、图片、文件或文字。是否包含思考过程、工具调用和图片只设一次，对每种方式都生效。「我的分享链接」随时可以管理和停止分享。点赞和点踩已移除。
- 首次启动更快上手：选择在本机运行后，运行环境在后台准备，同时就能挑外观、连接 DeepSeek；进度一直显示在底部，完成后自动进入。
- 设置 › 界面新增「性能」：自动、完整、轻量。配置较低或手机发热时自动减少模糊与动效，降温后恢复。
- 语音输入更可靠：系统语音识别出错时自动改用引擎转写；可以在设置 › 对话 › 语音识别里选择方式，出错时提示具体原因。
- 对话页：内容不满一屏时从顶部开始，往上翻不再有大片空白；一轮结束时过程收起不再跳动。
- 宠物悬浮窗不会再出现两只；停止和发送只作用于当前连接，重连后也能正常停止。
- 弹出面板只保留一种关闭方式：能下拉的只有顶部把手，编辑类保留 ×；有未保存的输入时，下拉会先确认。
- 插件：原生界面支持更丰富的文字样式与配色，以及输入框、滑块、开关、下拉、日期、评分、表单、页签、折叠等控件；插件可以请你选择文件或图片；插件详情显示加载状态与原因；本地插件可以一键重载；会话页签里能直接打开插件的网页面板。
- 其他：大字号下恢复选项完整显示；本机运行环境无法启动时直接说明原因；空工作区会提示旧对话在「全部对话」里。

### English

- Sharing, redesigned: Share under a message opens one panel. Pick what to share (this reply, selected messages or the whole chat), then a link, an image, a file or text. Whether to include thinking, tool calls and images is set once and applies to every option. My shared links lets you manage or stop sharing at any time. Like and dislike are gone.
- A faster first run: after you choose to run on this phone, the runtime gets ready in the background while you pick a look and connect DeepSeek. Progress stays at the bottom, and the app opens by itself when it's done.
- Settings › Interface › Performance: Auto, Full or Light. On lower-end or hot phones, blur and motion ease off automatically and come back when it cools down.
- More dependable voice input: when the system recognizer fails, the app switches to engine transcription. Choose the method in Settings › Chat › Voice recognition; errors now say what went wrong.
- Chats: a short chat starts at the top, with no empty space when you scroll up, and a finished turn folds away without a jump.
- The pet overlay no longer shows up twice, and Stop and Send act on the current connection, so stopping still works after a reconnect.
- Sheets close one way: draggable sheets have just the handle, editing sheets keep ×, and dragging away unsaved input asks first.
- Plugins: native views get richer text styles and colours plus text fields, sliders, switches, dropdowns, dates, ratings, forms, tabs and collapsible sections; plugins can ask you to pick a file or photo; plugin details show load status and why; local plugins reload in one tap; and a session's tab can open a plugin's web panel.
- Other fixes: recovery options show in full at large text sizes; a local runtime that can't start says why; and an empty workspace points to All chats for earlier chats.

## 0.9.4 · 2026-10-27

### 中文

- 网页模式更跟手：弹出键盘不再卡顿，侧栏开合更快。
- 打开 App 更快，引擎和界面同时启动。
- 远程主机连接更可靠：兼容新版 DSH Remote 服务端，用加密私钥连接 SSH 时界面不再卡住，版本不匹配时直接提示更新；远程主机页可以关闭「连接上次使用的主机」。
- 工具读取的图片和手机截图，展开卡片就能看到缩略图。
- 在手机共享存储里新建文件不再失败；手机操控不会因为别的对话结束而提前收起或跳回 App。
- 对话里：提问卡可以选「不回答」，斜杠命令只显示一行，被插件接走的消息不再一直显示发送中，回到底部的按钮不再闪烁，横屏打字时总留着一段对话。
- 插件与模型：插件开关在列表重排后不再错位，部分插件的设置页不再空白，自定义渠道里的同名模型不再被误认成已选中。
- 其他修复：代码里的 <=、-> 不再连成一个符号；看图时顶栏不再出现灰块；新对话的默认权限不再存成只对当前对话有效的「自动」；消息里的文件链接和图片打开的是正确的文件；引擎启动卡住时会停下并说明原因。

### English

- Web mode feels snappier: the keyboard no longer stutters, and the sidebar opens and closes faster.
- The app opens faster: the engine starts alongside the interface.
- More reliable remote hosts: works with newer DSH Remote servers, SSH with an encrypted private key no longer freezes the app, and a version mismatch tells you what to update. You can turn off Connect to the last host on the remote hosts page.
- Images read by tools and phone screenshots show as thumbnails when you expand the card.
- Creating files in the phone's shared storage no longer fails, and phone control no longer wraps up or jumps back to the app when a different chat finishes.
- In chats: question cards can be skipped, a slash command shows as one row, a message a plugin picked up no longer stays "sending", the jump-to-bottom button no longer flickers, and typing on a phone on its side always leaves a strip of chat.
- Plugins and models: plugin switches stay with their plugin when the list reorders, some plugin settings pages are no longer blank, and a model with the same name in a custom provider no longer looks selected.
- Other fixes: <= and -> in code no longer merge into one symbol; the image viewer's top bar no longer shows a grey block; the new-chat default permission can no longer be saved as the current-chat-only Auto; file links and images in messages open the right file; and an engine stuck while starting stops and tells you why.

## 0.9.3 · 2026-10-26

### 中文

- 插件可以直接朗读回复，你一开口就停下，还能显示字幕。
- 内置使用说明：直接问 App 里的 AI 怎么用，回答里一点就跳到对应页面。
- 静止时更省电：历史命令不再一直转圈，宠物隐藏时不再走帧。
- 手机操控暂停后不再自动恢复，等你点「继续」。
- 消息里的文件链接可以点开；写成 example.com 的网址在浏览器打开。
- 其他修复：分叉后的提示不再挡住输入框，切换语言后插件文字立即更新。

### English

- Plugins can read replies aloud, stop the moment you start talking, and show captions.
- A built-in guide: ask the AI in the app how anything works, then tap straight to the right page.
- Less battery drain at rest: the command history no longer spins forever, and a hidden pet no longer draws frames.
- Paused phone control no longer resumes on its own; it waits for you to tap Continue.
- File links in messages now open, and addresses written like example.com open in your browser.
- Other fixes: the notice after branching a chat no longer covers the composer, and plugin text follows a language change right away.

## 0.9.2 · 2026-10-26

### 中文

- 插件可以直接用原生界面呈现：工具结果卡片、输入框上方的快捷按钮和状态条、消息长按菜单里的插件操作，以及对话详情和全部功能里的插件面板。
- 手机操控的悬浮条默认常驻，闲置时自动变淡，也可以手动收起；自动收成小球改为可选。
- 「已复制」「已保存」这类提示更短，看一眼就走。
- 在 App 里直接检查并安装内测更新。
- 其他打磨：宠物站在输入框上方最上面那一条；让 AI 装好的插件，回复一结束就能用。

### English

- Plugins can now show up natively: tool result cards, quick buttons and a status line above the composer, actions in a message's long-press menu, and plugin panels in chat details and All features.
- The phone-control floating bar now stays put by default, fades when idle and can be tucked away by hand; folding into a small ball is now optional.
- Confirmations like "Copied" and "Saved" are shorter and get out of the way.
- Check for and install beta updates right in the app.
- More polish: your pet stands on the topmost bar above the composer, and a plugin the agent installs is ready as soon as the reply ends.

## 0.9.1 · 2026-10-25

### 中文

- 「模型渠道」里自己添加的模型，可以逐个设置上下文长度、最大输出、输入类型和思考档位。
- 手机操控时，悬浮条闲置一会儿就缩成小球，不挡屏幕；任务完成后自动回到对话，悬浮条一并收起。
- 首次使用可以只连远程主机，手机上不必安装运行环境；本机运行环境随时可以在设置里安装或卸载。
- 其他细节修复与打磨。

### English

- Models you add under Model providers can each have their own context length, max output, input types and thinking levels.
- During phone control, the floating bar shrinks to a small ball when idle, out of your way. When a task is done, you're back in the chat and the bar tucks away.
- On first launch you can connect to a remote host alone, with nothing to install on the phone. Install or remove the on-device runtime any time in Settings.
- Smaller fixes and polish.

## 0.9.0 · 2026-10-25

### 中文

**宠物**

- Deepy 小鲸鱼和鲸娘住进 App，趴在输入框和思考条上，干活、等你确认、完成时各有动作和气泡。
- 打开「App 外显示」，宠物跟着你到桌面；有事冒个气泡，点一下直达那段对话。

**网页模式**

- 原生界面和网页版一键切换，下次打开停在你上次用的那个。
- 网页版里也有 App 的按键，通知、分享、切换主机都落在同一段对话上。

**横屏与平板**

- 横屏手机和平板重新排版：内容居中限宽，弹窗和分享预览按屏宽排布，横屏弹出键盘也不挤。
- 网页版横屏用官方桌面布局，避开刘海和手势条。

**English**

- 全部界面支持英文，在设置里切换，默认跟随系统。

**主题与图标**

- 全新 App 图标，界面图标整套重绘。
- 六套主题色：雾蓝、黛青、暮紫、松石、琥珀、石墨，也可以跟随壁纸或自选颜色。
- 四款桌面图标：雾蓝、夜幕、霜白、墨。
- 功能磁贴三种风格：扁平双色、极简几何、玻璃渐变。

**对话**

- 回复中途也能插话：消息先排队，点「立即发送」就打断当前回复。
- 停下时，排队的消息马上发出；没送达的标为「未发送」，可以再发或撤回。
- 过程自动折叠，插过话的回合也分段收好；长对话的过程不再缺失。

**分享**

- 分享卡片带上消息里的图片，五种模板：浅色、深色、卡片、纸张、玻璃；多轮对话可以拼成一张长图。
- 整段对话可以分享成文件或链接，对方在浏览器里回放，或在 dsh-go 里接着聊。链接端到端加密，在「我的分享链接」里管理。

**更稳**

- 系统省电拦住后台时，App 会提醒，并直达对应的放行设置，vivo、小米、华为、荣耀、OPPO 都有。
- 重置引擎默认保留界面配置和技能，已装插件和设置也可以一并保留。
- 插件的网页界面可以直接嵌在 App 里打开。
- 本机网页版只接受 App 自己的访问。

### English

**Pets**

- Deepy and Whale girl now live in the app. They perch on the composer and the thinking bar, and react when DSH is working, needs you, or is done.
- Turn on "Show outside the app" and your pet comes along to the home screen. It pops a bubble when something needs you; one tap takes you to that chat.

**Web mode**

- Switch between the native and web interfaces in one tap. The app reopens in whichever you used last.
- The web interface has the app's keys too, and notifications, sharing and host switching all land on the same chat.

**Landscape and tablets**

- New layouts for landscape phones and tablets: content stays centered, dialogs and share previews use the width, and the keyboard no longer crowds a landscape screen.
- The web interface uses the official desktop layout in landscape and keeps clear of the notch and gesture bar.

**English**

- The whole app is now available in English. Switch in Settings; by default it follows your system.

**Themes and icons**

- A new app icon, and every icon in the app redrawn.
- Six accent colors: Mist, Teal, Dusk, Aqua, Amber and Slate. Or match your wallpaper, or pick your own.
- Four home screen icons: Mist blue, Nightfall, Frost white and Ink.
- Three feature tile styles: Duotone, Geometric and Glass.

**Chats**

- Chime in while DSH is replying. Your message waits its turn, or tap "Send now" to interrupt.
- Stopping sends queued messages right away. Anything that didn't get through is marked "Not sent", ready to send again or withdraw.
- Process steps fold away on their own, including turns you chimed into, and long chats keep every step.

**Sharing**

- Share cards now include the message's images and come in five templates: Light, Dark, Card, Paper and Glass. Several rounds can be stitched into one long image.
- Share a whole chat as a file or a link. Others replay it in the browser or pick it up in dsh-go. Links are end-to-end encrypted; manage them in "My shared links".

**More reliable**

- When the system's battery saver holds DSH back in the background, the app tells you and opens the right setting, on vivo, Xiaomi, Huawei, Honor and OPPO.
- Resetting the engine keeps your interface settings and skills, and can keep installed plugins and settings too.
- Plugin web interfaces open right inside the app.
- The local web interface only answers to the app itself.
