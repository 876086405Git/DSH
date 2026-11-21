# 求 star 的提示

> 2026-10-29 · 基于 main `e120b7ca`。范围：公测后邀请用户去 GitHub 给 dsh-go 点 star。入口有两个：对话框（最多问五次，2026-11-21 起；之前最多两次），以及「设置 › 关于」里的一行。替换 10-28 的底部弹层方案（3 天 + 10 次回复）。

**结论**：App 在前台累计用满 **30 分钟**后，等你在首页或对话里闲下来，弹出一个对话框：鲸娘捧着星星的贴纸、一句「本鱼已经在 DSH Go 里陪你半个小时啦~」、一段请求，和三个键「去 GitHub 点 Star」「已经点过啦」「下次再说」。点前两个永不再问；点「下次再说」（或返回、点外面）的，累计用满 **2、5、10、20 小时**时再各问一次，每次换一段话，第一句写实际时长（「陪你 5 个小时啦~」），最后一次明说是最后一次，之后不再问。整个提示由编译参数 `DSH_STAR_PROMPT` 控制，默认关闭；`tooling/build-apk.sh` 打正式包时自动打开（§5）。「设置 › 关于 › 给 dsh-go 点个 star」不受开关影响。

## 1. 出现时机

**计时**：只算 App 在前台（`resumed`）的时间，所有启动累加，记在本机。每分钟记一次，离开前台时再记一次；进程被杀最多丢一分钟。用的是单调时钟，改手机时间不影响。开关打开时从启动就开始计，网页模式和首次引导期间也算；问完五次或已结束后不再计。

| 第几次 | 何时到期 | 第一句 |
|---|---|---|
| 第一次 | 累计 30 分钟 | 陪你半个小时啦~（拖到满 1 小时才弹出的，写「一个小时」） |
| 第二次 | 累计 2 小时 | 陪你 N 个小时啦~（N 向下取整，下同） |
| 第三次 | 累计 5 小时 | |
| 第四次 | 累计 10 小时 | |
| 第五次（最后） | 累计 20 小时 | |

每一档还要比上次弹出时多用满 **1 小时**：上一次因为一直不空闲拖晚了，下一次不会紧跟着弹。以前的版本只问两次（30 分钟、再加 5 小时）；它留下的记录照新规则接着走，问过两次的人到 5 小时这一档（至少再隔 1 小时）会被问第三次。

**到期后**，下面全都满足、并且保持 3 秒，才弹出；任何一条不满足就等，条件变化时或一分钟后再看：

| 不弹的情形 | 怎么判断 |
|---|---|
| 首次引导没走完 | 提示挂在首页外壳上，引导期间根本不在 |
| 不在首页或对话 | App 不在前台；对话页上面压着页面、弹层或对话框（`chatOnScreenProvider`）；抽屉开着；启动画面还在播 |
| 屏幕上的对话在跑 | 思考、写、调工具、等审批（`petFocusProvider`） |
| 有事等你 | 有待审批或待回答的问题（`petPendingProvider`） |
| 手机操控 | 正在进行，或刚结束不到 2 分钟 |
| 语音输入、打字 | 正在听写；键盘弹着，或输入框里有没发出的字、附件 |
| 这次启动已经弹过别的提示 | 使用统计的升级提示、更新弹层、后台联网那一行（`launchNoticeShownProvider`）；等下次启动 |

后台对话在跑不拦：只看你正在看的这个对话。

## 2. 频率

| 你做了什么 | 之后 |
|---|---|
| 去 GitHub 点 Star | 用外部浏览器打开仓库，永不再问。不知道、也不去查你到底点没点 |
| 已经点过啦 | 永不再问 |
| 下次再说，或返回、点外面 | 到下一档再问（§1）；第五次之后不再问 |
| 设置 › 关于 › 给 dsh-go 点个 star | 打开 GitHub，视同「去 GitHub 点 Star」 |

对话框一出现就记下（次数和当时的累计时长），中途被杀进程按「下次再说」算。

## 3. 形式

```
╭──────────────────────────────────╮
│            ( 鲸娘 )              │  贴纸 ≤192，背后一圈很淡的主题色光晕
│      本鱼已经在 DSH Go           │  titleLarge · 居中 · 两行等宽（不让「啦~」单独一行）
│      里陪你半个小时啦~            │
│   这是一个免费开源的项目，如果它……   │  bodyMedium · onSurfaceVariant · 居中
│      拜托你啦~ 这真的很重要！！      │  bodyMedium w600 · 主色
│ ┌──────────────────────────────┐ │
│ │      ☆ 去 GitHub 点 Star      │ │  填充主键，通栏
│ └──────────────────────────────┘ │
│            已经点过啦             │  文字键 · 主色
│             下次再说              │  文字键 · 三级文字色
╰──────────────────────────────────╯
```

- **卡片**：主题的对话框（`popupFill`、发丝描边、28 圆角），宽度 280～360，手机两侧各留 24；平板上也是这个宽度。内容放在滚动视图里，矮屏或大字号时滚动，不溢出。
- **贴纸**：`assets/star/star_whale.webp`，576×576（192dp 的 3 倍），WebP 带透明，约 128 KB，中英文共用。原图下摆被画布截平，最后 40px 渐隐到透明，落在卡片上不显得被裁。边长取对话框可用高度的 30%，限制在 112～192dp。
- **入场**：对话框本身淡入；鲸娘从 0.86 倍、低 14dp 处轻轻弹起，略过 1 倍再落定（560ms，`easeOutBack`）。系统「移除动画」时直接显示。
- **返回、点外面**：等于「下次再说」。没有 ×。

## 4. 文案

文案在 `app/lib/l10n/parts/star_{zh,en}.arb`，第一句按小时数走复数（0 = 半个小时）。失败提示复用 `shellBrowserUrlCopied`。

| 位置 | 中文 | English |
|---|---|---|
| 第一句 | 本鱼已经在 DSH Go 里陪你半个小时啦~ / 一个小时 / N 个小时 | I’ve kept you company in DSH Go for half an hour now~ / an hour / N hours |
| 正文 | 这是一个免费开源的项目，如果它让你的移动端体验更好了一点，拜托点个 Star 支持一下，这对本鱼是很大的鼓励！ | DSH Go is free and open source. If it’s made your phone a little nicer to use, please give it a Star — it means so much to this little whale! |
| 请求 | 拜托你啦~ 这真的很重要！！ | Pretty please~ It really matters!! |
| 第二次正文 | 看来你挺喜欢这里嘛！点个 Star 只要几秒钟，却能让更多人发现 DSH Go，本鱼也会更有干劲！ | Looks like you like it here! A Star takes a few seconds, helps more people find DSH Go, and keeps this little whale going! |
| 第二次请求 | 就差你这一颗星星啦~ | Just one star from you~ |
| 第三次正文 | DSH Go 不收费、没有广告，全靠大家的 Star 让更多人看到。如果它帮到了你，就送本鱼一颗星星吧！ | DSH Go is free, with no ads — Stars are how more people get to see it. If it’s helped you, would you give this little whale a star? |
| 第三次请求 | 本鱼眼巴巴地等着呢~ | Waiting here with hopeful eyes~ |
| 第四次正文 | 这么久了，本鱼一直都在。如果 DSH Go 已经成了你每天都会打开的 App，点个 Star 就是给作者最好的回礼。 | I’ve been here all along. If DSH Go is something you open every day now, a Star is the best thank-you its author could get. |
| 第四次请求 | 求求你啦，就点一下下~ | Pretty please, just one tap~ |
| 第五次正文 | 这是本鱼最后一次问你啦。不管点不点，本鱼都会一直陪着你。要是愿意的话，点个 Star 让本鱼开心一下吧！ | This is the last time I’ll ask. Star or not, I’ll keep you company all the same. But if you’d like, a Star would make this little whale very happy! |
| 第五次请求 | 最后一次，拜托啦！ | Last time, pretty please! |
| 主键 | 去 GitHub 点 Star | Star it on GitHub |
| 次键 | 已经点过啦 | Already starred |
| 第三键 | 下次再说 | Maybe later |
| 设置行 | 给 dsh-go 点个 star | Star dsh-go on GitHub |

## 5. 公测开关

- 常量 `starPromptEnabled = bool.fromEnvironment('DSH_STAR_PROMPT')`，默认 `false`。关闭时不计时、不读写偏好、不弹，更新弹层里的「点 Star」键也不出现。内测期间不留状态，公测版从零开始计时。
- **正式包由 `tooling/build-apk.sh` 自动打开**（2026-11-21 起，经 `tooling/star-prompt-on.json`，额外参数里的 `DSH_STAR_PROMPT` 优先）。`--beta`、`--side`、debug/profile 包不开，`--no-star` 手动关。以前要手动加 `-- --dart-define=DSH_STAR_PROMPT=true`，最近的正式包漏了（1.3.0 确认没加，1.1.0、1.2.0 的打包记录里也没有）：这些版本既不弹对话框，更新弹层也没有「点 Star」，只剩设置里那一行。开关关着的版本不计时，所以这些用户升级到打开的版本后从零算，再用满 30 分钟就会被问到。
- 设置里的那一行不受开关影响。
- 不用远程配置，理由同前：公测包的更新检查读 GitHub API，放不了自定义字段；这个开关只在公测发版时拨一次。

## 6. 合规

- **只是邀请**：任何功能都不需要点 star；三个选择都不影响任何东西。
- **不追踪**：不联网，不查 GitHub。本机只记累计前台时长、问过几次、上次问时的累计时长、是否结束。都不离开手机，也不进使用统计（统计的计数键是固定的，加键要改服务端，这里不加）。
- **读写失败照常运行**：偏好读不出来时，这次运行从零计时、不写回，免得覆盖以前存下的「已经点过啦」；写不进去时，只在这次运行里生效。

## 7. 实现

| 文件 | 内容 |
|---|---|
| `app/lib/state/star_prompt.dart` | 开关、规则、本地记录（`star_prompt`，JSON v2；读到旧 v1 只保留「已结束」）、前台计时、空闲判断、手机操控观察器、打开链接的接缝 |
| `app/lib/ui/star/star_prompt_dialog.dart` | 对话框、贴纸和入场、两行等宽的标题、打开 GitHub |
| `app/lib/ui/star/star_prompt_host.dart` | 挂在首页外壳上；记录或场景一变就判断，安静 3 秒后弹出 |
| `app/lib/app.dart` | 开关打开时从启动起持有记录（开始计时） |
| `app/lib/state/notify_state.dart` | `launchNoticeShownProvider`：使用统计提示、更新弹层、后台联网那一行出现时置位 |
| `app/lib/ui/settings/about_page.dart` | 「关于」里的「给 dsh-go 点个 star」 |

## 8. 测试

`app/test/star/star_prompt_test.dart`：29 分钟不弹、30 分钟弹；只在 `resumed` 时计时、跨启动累加；「下次再说」后 2、5、10、20 小时各差 1 分钟不弹、到点弹，第一句写实际小时数、正文和请求按档换，拖晚的下一档至少隔 1 小时；返回、点外面等于「下次再说」，第五次后不再问、不再计时；五档文案中英文各不相同，最后一档写明「最后一次」；「去 GitHub 点 Star」打开 `https://github.com/ccch1mneyyy/dsh-go`、「已经点过啦」都永不再问；打不开浏览器时复制网址；首次引导、对话在跑、有审批、页面盖着、不在前台、手机操控、听写、键盘、草稿、抽屉、本次启动已有提示时都不弹，条件解除后会弹；开关关闭时不读写；偏好读写失败；设置行；360×780 / 360×640 × 1、1.3 倍字号和平板的几何（不溢出、贴纸方正居中、主键通栏、标题两行等宽）；英文；入场动画开关；浅色、深色 golden。
