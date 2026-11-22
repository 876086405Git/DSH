# 主题包 theme.json 字段参考

> 2026-11-23。给做主题的人看的字段表，schema 1。解析规则以 `app/lib/themes/theme_pack.dart` 为准，
> 创意工坊投稿用同一套字段和范围（`services/share-worker/src/workshop-pack.ts`）。

## 0. 先看这几条

- **只有 `schema`、`id`、`name` 必填。** 其余分区和字段都可以不写，不写就是 App 默认的样子。
- **写错会整包拒绝。** 不认识的字段、越界的数值、拼错的枚举值都不会被悄悄忽略。
- **颜色**写 `#RRGGBB` 或 `#AARRGGBB`（带透明度）。
- **长度单位**是 dp，**倍率**是相对默认值的倍数。
- **双语短文本**写成 `{"zh": "…", "en": "…"}`，两项至少写一项。英文界面优先用 `en`，其它语言优先用 `zh`，缺哪个就用另一个。
- 想在内置主题上改几处，用 `extends`（§8），不用把整份抄一遍。

## 1. 包的结构

一个 zip，`theme.json` 放在顶层或一层文件夹里，引用到的图片和字体和它平铺在同一层。

| 素材 | 格式 | 单个上限 | 说明 |
|---|---|---|---|
| 图片 | `.png` `.webp` `.gif` | 8 MB | 文件内容必须和扩展名一致；每边不超过 4096 像素，且宽 × 高不超过约 419 万像素（例如 1440×2900 可以，1440×3200 不行）；GIF 和动态 WebP 会循环播放 |
| 字体 | `.ttf` `.otf` | 16 MB | 最多 4 个（四个字体角色各一个） |

- 全部素材合计不超过 32 MB，`theme.json` 不超过 128 KB。
- 文件名只用字母、数字、`.`、`_`、`-`，以字母或数字开头，不超过 80 个字符，不带路径。
- 只放 `theme.json` 引用到的文件。投稿到创意工坊时，多出来的文件会被拒绝。

## 2. 顶层字段

| 键 | 类型 | 说明 |
|---|---|---|
| `schema` | `1` | 必填 |
| `id` | 字符串 | 必填。小写字母、数字、`-`，不超过 40 个字符，如 `ink-scroll` |
| `name` | 字符串，≤ 120 字 | 必填。主题名 |
| `title` | 双语短文本，每项 ≤ 120 字 | 按界面语言显示的名字，没有就用 `name` |
| `description` | 字符串，≤ 512 字 | 简介 |
| `tags` | 字符串数组，最多 8 个，每个 ≤ 32 字 | 不能重复 |
| `author` | 字符串，≤ 256 字 | 投稿必填 |
| `license` | 字符串，≤ 100 字 | 投稿必填，须是工坊支持的授权（如 `CC0-1.0`、`MIT`） |
| `source` | https 网址 | 投稿必填 |
| `extends` | 内置主题 id | 见 §8 |
| `palette` `surfaces` `typography` `shapes` `components` `emptyState` | 对象 | 见 §3–§7 |

## 3. palette：配色

| 键 | 类型 / 范围 | 默认 | 说明 |
|---|---|---|---|
| `seed` | 颜色 | `#4B67B4` | 主色。浅色模式的各级强调色从它推出来 |
| `seedDark` | 颜色 | 从 `seed` 推 | 深色模式的主色 |
| `tintHue` | 0–360 | 跟随 `seed` | 中性色（背景、文字、分隔线）偏向的色相 |
| `tintChroma` | 0–2 | 1.0 | 中性色的彩度倍率，0 是纯灰 |
| `glowOpacity` | 0–1 | 1.0 | 背景光晕的强度，0 是没有光晕 |
| `light` | 颜色令牌 | — | 浅色模式下逐个覆盖 |
| `dark` | 颜色令牌 | — | 深色模式下逐个覆盖 |

`light` 和 `dark` 里可以写下面这些令牌，没写的由 `seed` 和材质预设决定。

| 令牌 | 用在哪 |
|---|---|
| `backdropTop` `backdropBottom` | 页面背景渐变的上端、下端 |
| `glowPrimary` `glowSecondary` | 背景的两团光晕 |
| `patternInk` | 程序化纹理的墨色，默认是 `onSurface` |
| `surface` `onSurface` `onSurfaceVariant` | 页面底色、正文色、次要文字色 |
| `textTertiary` | 三级文字（时间、标签这类小字） |
| `outline` `outlineVariant` | 描边、分隔线 |
| `primary` `onPrimary` | 主色和主色上的文字 |
| `primaryContainer` `onPrimaryContainer` | 主色的浅色容器和它上面的文字 |
| `cardFill` `chromeFill` `sheetFill` | 卡片层、顶栏和输入框这一层、底部面板的填充色，可带透明度 |
| `hairline` | 上面三层和小胶囊的描边色 |
| `userBubble` `onUserBubble` | 用户气泡的底色、文字色 |
| `userBubbleBorder` | 用户气泡的描边（`outlined` 样式），默认是 `outlineVariant` |
| `assistantBubble` `onAssistantBubble` | 助手卡片的底色、文字色 |
| `assistantBorder` | 助手 `card` / `quote` 样式的描边；`card` 默认是 `outlineVariant`，`quote` 不设就不画外框 |
| `rule` | 强调引线：助手 `leftRule` / `quote` 的竖线、用户 `minimal` 气泡的竖线、标题 `marker` 的小竖条，默认是 `primary` |
| `link` | 回复里的链接，默认是 `primary` |
| `heading` | 回复里的标题，默认是正文色 |
| `inlineCodeBg` `inlineCodeFg` | 行内代码的底色、文字色 |
| `codeWellBg` `codeWellHeader` `codeWellFg` `codeWellBorder` | 代码块的底色、标题条、文字色、描边 |
| `syntaxKeyword` | 代码高亮：关键字和内置字面量（`if` `return` `async` `true` `null`）。这六项没写的保持默认配色 |
| `syntaxString` | 代码高亮：字符串、正则、模板串 |
| `syntaxNumber` | 代码高亮：数字 |
| `syntaxComment` | 代码高亮：注释（仍是斜体） |
| `syntaxFunction` | 代码高亮：函数名、方法名 |
| `syntaxType` | 代码高亮：类型名、类名、内置类型 |
| `composerFill` `composerBorder` | 输入框的底色、描边 |
| `sendButton` `onSendButton` | 发送键可用时的底色、图标色 |
| `success` `warning` `danger` `info` | 状态色 |

## 4. surfaces：材质与背景

| 键 | 类型 / 范围 | 默认 | 说明 |
|---|---|---|---|
| `preset` | `glass` `paper` `flat` `outlined` | `glass` | 整体材质：毛玻璃、实心纸面、实心平面、线框 |
| `chromeBlur` | 0–40 | 预设值 | 顶栏和输入框这一层的模糊强度 |
| `sheetBlur` | 0–40 | 预设值 | 底部面板的模糊强度 |
| `cardOpacity` | 0–1 | 预设值 | 卡片填充的不透明度 |
| `pillOpacity` | 0–1 | 预设值 | 小胶囊填充的不透明度 |
| `hairlineWidth` | 0–3 | 预设值 | 各层描边的粗细 |
| `rimOpacity` | 0–1 | 预设值 | 玻璃高光边的强度倍率 |
| `shadowOpacity` | 0–1 | 预设值 | 阴影的强度倍率，0 是没有阴影 |
| `backdropImage` | 包内图片文件名 | 无 | 背景图 |
| `backdropOpacity` | 0–1 | 0.18 | 背景图的不透明度 |
| `backdropRepeat` | 布尔 | `false` | `true` 时平铺：按图片像素 = dp 平铺，从左上角起（各种屏幕上一块瓦片一样大）；否则铺满 |
| `backdropAlign` | `center` `top` `bottom` | `center` | 铺满时裁掉哪一头 |
| `backdropBlur` | 0–40 | 0 | 背景图的模糊强度 |
| `backdropAnimate` | 布尔 | `true` | `false` 时动图只显示第一帧 |
| `pattern` | `none` `dots` `grid` `lines` `diagonal` `grain` | `none` | 程序化纹理，画在渐变和光晕之上、内容之下，不需要图片 |
| `patternOpacity` | 0–1 | 0.06 | 纹理的不透明度 |
| `patternScale` | 0.5–3 | 1.0 | 纹理间距倍率（基准：点和格 24，横线 28，斜线 16） |
| `glowLayout` | `corners` `top` `bottom` `center` | `corners` | 两团光晕的位置，`corners` 是右上加左下 |

## 5. typography：字体

字体角色的取值：`system`（系统字体）、`serif`（衬线）、`mono` / `JetBrainsMono` / `monospace`（等宽），
或者包内的字体文件名。

| 键 | 类型 / 范围 | 默认 | 说明 |
|---|---|---|---|
| `uiFont` | 字体角色 | `system` | 界面文字 |
| `readingFont` | 字体角色 | `system` | 阅读字体，要配合 `useReadingFontForReply` / `useReadingFontForGreeting` 才用到 |
| `headingFont` | 字体角色 | `system` | 大标题 |
| `codeFont` | 字体角色 | `JetBrainsMono` | 代码 |
| `readingScale` | 0.85–1.25 | 1.0 | 阅读字号倍率 |
| `readingLineHeight` | 1.2–2.0 | 1.55 | 阅读行高 |
| `readingLetterSpacing` | -0.5–2.0 | 0 | 阅读字距 |
| `headingScale` | 0.85–1.35 | 1.0 | 标题字号倍率 |
| `headingLetterSpacing` | -1.0–4.0 | 0 | 标题字距 |
| `headingWeight` | 300–900 的整百 | 不改 | 标题字重 |
| `codeScale` | 0.85–1.2 | 1.0 | 代码字号倍率 |

## 6. shapes：形状与间距

| 键 | 类型 / 范围 | 默认 | 说明 |
|---|---|---|---|
| `cornerScale` | 0–1.6 | 1.0 | 全局圆角倍率，0 是直角 |
| `cornerStyle` | `squircle` `round` `bevel` | `squircle` | 角型：超椭圆、正圆角、切角。用于气泡、卡片、建议卡、代码块、空状态徽章 |
| `bubbleCorners` | `uniform` `tail` `leaf` | `uniform` | 用户气泡四角：一样大；右下收成小角；左上和右下大、另两角小 |
| `bubbleRadius` | 0–36 | 按 `cornerScale` | 气泡圆角 |
| `cardRadius` | 0–36 | 按 `cornerScale` | 助手卡片、建议卡、通用卡片的圆角 |
| `codeRadius` | 0–36 | 按 `cornerScale` | 代码块圆角 |
| `composerRadius` | 0–36 | 按 `cornerScale` | 输入框收起时的圆角 |
| `bubblePadH` | 10–24 | 16 | 用户气泡的左右内边距 |
| `bubblePadV` | 6–16 | 8 | 用户气泡的上下内边距 |
| `borderWidth` | 0–2.5 | 0.5 | 气泡和卡片的描边粗细 |
| `turnGap` | 12–40 | 24 | 两轮对话之间的间距 |
| `inTurnGap` | 4–20 | 8 | 同一轮里各块之间的间距 |
| `gutter` | 10–28 | 16 | 页面左右留白 |

## 7. components 与 emptyState

### 7.1 components：聊天页的各个部件

| 键 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `headerStyle` | `glass` `ghost` `outlined` `minimal` | `glass` | 顶栏：玻璃胶囊、无底、线框、极简 |
| `headerTitleFont` | `ui` `heading` `code` | `ui` | 顶栏标题用哪个字体角色 |
| `composerStyle` | `floatingGlass` `solidPaper` `outlined` | `floatingGlass` | 输入框：悬浮玻璃、实心、线框 |
| `composerHint` | 双语短文本，每项 ≤ 30 字 | 无 | 输入框的占位提示 |
| `sendButtonStyle` | `primary` `ink` `tonal` `outlined` | `primary` | 发送键：主色、深墨反白、柔和容器色、透明底加主色描边 |
| `sendButtonShape` | `circle` `squircle` `square` | `circle` | 发送键形状，`square` 是小圆角方块 |
| `userBubbleStyle` | `soft` `outlined` `accent` `minimal` | `soft` | 用户气泡：柔和底色、描边、主色实心、无底加竖线 |
| `userLabel` | 双语短文本，每项 ≤ 16 字 | 无 | 用户气泡上方的小标签 |
| `userAvatar` | 包内图片文件名 | 无 | 用户气泡上方的小头像，在标签右边 |
| `assistantStyle` | `plain` `card` `leftRule` `quote` | `plain` | 助手回复：无框、卡片、左侧引线、引线加极淡的主色底 |
| `assistantLabel` | 双语短文本，每项 ≤ 16 字 | 无 | 助手回复上方的小标签 |
| `assistantAvatar` | 包内图片文件名 | 无 | 助手回复上方的小头像，在标签左边，没有标签也单独显示 |
| `useReadingFontForReply` | 布尔 | `false` | 回复正文用阅读字体 |
| `headingStyle` | `plain` `accent` `underline` `marker` | `plain` | 回复里的标题：不变、用 `heading` 色（没设就用主色）、一二级标题加下划线、左侧加 `rule` 色小竖条 |
| `bulletStyle` | `dot` `dash` `diamond` `arrow` `square` | `dot` | 无序列表的项目符号 |
| `turnDivider` | `none` `hairline` `dashed` `dots` | `none` | 两轮对话之间的分隔线，画在已有间距里，不占高度 |
| `suggestionCardStyle` | `glass` `paper` `outlined` `minimal` | `glass` | 空状态里建议卡的样子 |
| `codeBlockStyle` | `well` `outlined` `card` | `well` | 代码块：凹槽、线框、卡片 |
| `codeHeaderStyle` | `bar` `plain` | `bar` | 代码块标题条：填色，或只留语言名和复制键 |

### 7.2 emptyState：新对话首页

| 键 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `layout` | `centered` `editorial` `compact` | `centered` | 版式：居中、靠左的杂志式、紧凑 |
| `heroStyle` | `whale` `badge` `customImage` `hidden` `glyph` `seal` | `whale` | 主视觉：鲸尾、徽章、自带图片、不显示、文字、印章 |
| `heroImage` | 包内图片文件名 | 无 | `customImage` 时必填 |
| `heroGlyph` | 1–4 个字符 | 无 | `glyph` / `seal` 时必填。`glyph` 用标题字体和主色直接画字；`seal` 是主色实心方块里的反白字，略微倾斜 |
| `heroScale` | 0.6–2.0 | 1.0 | 主视觉大小倍率 |
| `greeting` | 双语短文本，每项 ≤ 40 字 | 无 | 替换按时间变化的问候语 |
| `subtitle` | 双语短文本，每项 ≤ 60 字 | 无 | 已连接时替换副标题；没连接时仍显示连接状态 |
| `useReadingFontForGreeting` | 布尔 | `false` | 问候语用阅读字体 |
| `showConnectedSubtitle` | 布尔 | `true` | `false` 时已连接就不显示副标题 |
| `suggestionsDisplay` | `expanded` `collapsible` `grid` | `expanded` | 建议卡：展开的列表、可折叠、双列网格 |

## 8. extends：在内置主题上改

`"extends"` 写一个内置主题的 id：`paper`（纸墨书卷）、`bamboo-celadon`（竹韵青瓷）、`terminal-noir`（极夜终端）、
`sakura-card`（落樱手账）、`amber-cafe`（琥珀咖啡馆）。

- 继承的是 §3–§7 这六个分区；`id`、`name`、简介、作者这些还是用你自己的。
- 你写的字段盖在内置主题上面，对象逐层合并，没写的保持内置主题的值。
- 把某个键写成 `null`，表示去掉内置主题的设置、回到 App 默认。整个分区也可以写 `null`。
- 保存和投稿时会展开成完整的 `theme.json`，里面不再有 `extends`，所以装到别的手机上不依赖那台手机有没有这个内置主题。
- 只能继承内置主题，写别的 id 会被拒绝。

```json
{
  "schema": 1,
  "id": "paper-night-rain",
  "name": "夜雨书卷",
  "extends": "paper",
  "palette": {
    "light": { "link": "#1A5FB4", "userBubble": null }
  },
  "surfaces": { "backdropImage": "rain.gif", "backdropOpacity": 0.12 },
  "components": {
    "assistantStyle": "quote",
    "sendButtonStyle": null,
    "assistantLabel": { "zh": "回信", "en": "Reply" }
  },
  "emptyState": { "heroStyle": "seal", "heroGlyph": "雨" }
}
```

这份主题沿用纸墨书卷的配色、字体和版式，只改了链接色，去掉了用户气泡的自定义底色，换了动态背景，
助手回复改成引线样式并加上标签，发送键回到默认的主色，首页主视觉换成一枚「雨」字印章。

## 9. 最小示例

最小的包只有一个文件：

```json
{
  "schema": 1,
  "id": "plain-teal",
  "name": "青色",
  "palette": { "seed": "#2B6A58" }
}
```

稍微完整一点、不带素材的例子：

```json
{
  "schema": 1,
  "id": "grid-notebook",
  "name": "方格本",
  "title": { "zh": "方格本", "en": "Grid Notebook" },
  "description": "方格纸底纹、切角卡片和虚线分隔。",
  "tags": ["纸", "极简"],
  "palette": {
    "seed": "#3A5BA0",
    "glowOpacity": 0,
    "light": { "backdropTop": "#F6F7F9", "backdropBottom": "#F1F3F6", "rule": "#3A5BA0" }
  },
  "surfaces": { "preset": "flat", "pattern": "grid", "patternOpacity": 0.08 },
  "typography": { "headingWeight": 700, "headingLetterSpacing": 0.5 },
  "shapes": { "cornerStyle": "bevel", "cardRadius": 10, "bubbleCorners": "tail" },
  "components": {
    "assistantStyle": "card",
    "headingStyle": "marker",
    "bulletStyle": "dash",
    "turnDivider": "dashed",
    "composerHint": { "zh": "写点什么", "en": "Write something" }
  },
  "emptyState": {
    "layout": "editorial",
    "heroStyle": "glyph",
    "heroGlyph": "格",
    "greeting": { "zh": "翻开新的一页", "en": "A fresh page" }
  }
}
```
