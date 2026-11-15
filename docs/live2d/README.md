# 伙伴小屋 · Live2D 模型适配指南

> 面向模型作者和想导入自己模型的用户。读完这一篇，你应该能做出一个「导入后能站在舞台上、会转头眨眼、被摸头有反应」的素材包；适配表（adapter）要做什么、不能做什么，也写在这里。

伙伴小屋（Companion room）是一个固定的 Live2D 舞台：舞台代码和生成动作由 App 提供，模型以「素材包」的形式导入。适配分两层：

- **确定性的兼容由 App 做**：渲染、文件结构、贴图尺寸、蒙版、大小限制、安全校验。
- **需要判断的适配交给 AI 或作者本人**：哪个参数是转头，哪个表情是害羞，点哪里算摸头。AI 只会产出一份数据（adapter），执行和校验仍在 App 里。

## 1. 支持范围

| 项 | 结论 | 依据 |
|---|---|---|
| 运行库 | 官方 **Cubism Web Framework 5-r.5 + Core 6.0.1**，随素材包/App 下发，作者不能替换、也不能自带 | `docs/design/companion.md` §3、`app/assets/companion/stage.js` |
| 模型格式 | 只认 **.moc3**；Cubism 3 及以后编辑器导出的模型都走这条路 | `app/lib/companion/companion_pack.dart` |
| moc 版本 | moc3 格式枚举 **1–6**（官方 Core 6.0.1 的 latestMocVersion = 6）；更高的版本加载时提示「版本太新，最高只认到 N」 | `stage.js` 版本头检查、`tooling/companion/fixtures/live2d-core-sources-v1.json`、`docs/design/workshop-worker.md` |
| Cubism 2 | **不支持**。`.moc` + `model.json` 会被拒，提示用 Cubism Editor 打开后导出成 moc3 | `companion_zh.arb` `companionPackLegacyModel` |
| 换肤/换装 | 属于模型自身参数；AI 适配不会自动驱动服装、水印、显隐这类开关 | 适配契约与 `stage.js` 保护项 |
| 多模型 | 一个包可以放多个模型，舞台只用 `character.json` 的 `model` 指定的那个；缺省取第一个 `.model3.json` | `stage.js` `resolveModelFile` |

**不要试图改运行库。** 包里如果带 `runtime/`，它的 SHA-256 摘要必须和 App 里钉死的那份一致，否则整包拒收（「素材包里的运行库和这个版本的 App 对不上」）。作者只需要提供 `character/`。

## 2. 准备一个能导入的模型包

### 2.1 最小可用包

把模型的**一个文件夹**打成 zip。zip 根目录直接是模型内容（推荐），或者整个文件夹作为唯一的顶层目录（安装器会把它剥掉）：

```
my-model.zip
├─ my.model3.json
├─ my.moc3
├─ textures/ …
└─ 可选：*.exp3.json、*.motion3.json、*.physics3.json、*.pose3.json、*.wav、*.mp3
```

规则（都在 `companion_pack.dart` 的安装流程里）：

- **必须有** `.model3.json`；没有就报「包里没有找到 Live2D 模型（.model3.json）」。
- `character/` 只收这些扩展名：`.json .moc3 .png .jpg .jpeg .webp .wav .mp3 .txt .md`。`.cmo3`、`.psd`、`.clip` 等会被忽略，不会报错，也不会留在手机上。
- 路径必须是安全的相对路径：不能有 `..`、不能以 `/` 开头、不能有反斜杠或空字节；符号链接一律拒收。
- 文件名不能「归一化后重名」（大小写、Unicode 别名）。别放 `A.png` 和 `a.PNG` 这种。
- 大小上限：**解压后 400 MB、4000 个文件**（本地导入）。超出报「素材包太大了」。
- 图片只按扩展名收，但**请保证 PNG/JPEG/WebP 真的能解码**：舞台加载不了坏图会整体失败。

### 2.2 只有 character/ 的包

这是作者发布的标准形态，也是创意工坊里「伙伴」的格式。它不含运行库，安装时直接复用手机上已经装好的 runtime。因此：

- 用户手机上**必须先装过一个完整素材包**（或 App 自带包），否则报「这个包只有角色，手机上还没有运行库」。
- 完整包（带 `runtime/`）只有官方构建能发；作者的包请只放 `character/` 内容。

### 2.3 可选的 character.json（强烈建议提供）

`character.json` 放在模型文件夹根目录。字段都可以省略；缺省时用标准参数名和默认分区，但那样触摸区、取景只能靠默认值，AI 也补不了（见 §4）。

| 字段 | 类型 | 含义 |
|---|---|---|
| `schema` | int | 固定 `1` |
| `model` | string | 相对 `character/` 的模型路径；缺省取第一个 `.model3.json` |
| `name`/`author`/`license`/`source` | string | 显示在角色菜单底部；发布到工坊时会被核对 |
| `framing` | `{zoom, y}` | 默认取景；zoom 建议 0.3–3，y 为纵向偏移 |
| `mark` | `[x, y]` | 漫符（心、汗滴等）出现的位置，模型坐标 |
| `tail` | string[] | 尾巴参数 ID，从根到尖 |
| `zones` | 数组 | 触摸分区，见下 |
| `emotions` | 对象 | 情绪 → `{expression, face, gaze}`，和内置情绪表合并 |
| `actions` | 对象 | 动作名 → `{ms, tracks}` 曲线，和内置动作表合并 |

`zones` 每项：`{"id":"head|face|body|tail|legs","from":数字,"to":数字,"xFrom":可选,"xTo":可选}`。

- 坐标在**模型矩阵之后、相机之前**：`from = (1 - top) / 2`，`to = (1 - bottom) / 2`，要求 `0 ≤ from < to ≤ 1`。
- `xFrom`/`xTo` 是可选的横向区间（比如尾巴只在右侧），必须成对且 `xFrom < xTo`；它不是屏幕百分比。
- 部件名**不会**自动变成坐标。没有 `zones` 时只有模型自带的 HitAreas 能救，再没有就用默认分区（头/脸/身体/腿）；AI 适配只能复制已有几何，不会凭空造。

`emotions` 示例（结构来自 `tooling/companion/whale-girl.character.json`，**不要复制那个模型的素材**）：

```json
{
  "happy": { "expression": "02 龇牙", "face": { "ParamEyeSmile": 0.7 } },
  "shy":   { "expression": "04 脸红", "face": { "ParamEyeSmile": 0.2 }, "gaze": [0.45, -0.35] }
}
```

`expression` 是模型自带 `.exp3.json` 的加载名，`face` 是叠加到标准参数上的增量（不是绝对姿态），`gaze` 是视线偏移。`actions` 示例：

```json
{ "wave": { "ms": 1900, "tracks": { "Param_arm_R1": [[0, 0], [0.18, 26], [1, 0]] } } }
```

`tracks` 的每条是 `[时间 0–1, 参数值]` 的折线，叠加在基础姿态上。动作名可以是内置的 12 个（`nod`、`nodSmall`、`shake`、`tilt`、`tiltLeft`、`lookUp`、`recoil`、`duck`、`sway`、`stretch`、`yawn`、`wave`），也可以自定义。

### 2.4 可选的 adapter.json

`adapter.json` 是适配表（App 的 AI 适配会写它）。作者也可以预置一份，省掉用户第一次适配。规则：

- `moc` 必须是 **moc3 文件的 SHA-256**（小写十六进制，对文件字节做哈希，不是路径）。App 用 `sha256(moc3)` 校验；对不上会把整份适配表删掉并重新适配。
- 字段按 §4 的 `app-local-adapter-v1`；不合法的项会被丢弃，但**导入本身不校验**它——舞台会尽量执行，所以手写时请自查。

## 3. 导入到 App

路径：**切换主机 → 伙伴小屋**。

1. 第一次进入（或移除素材后）是「把她接回家」页，点 **导入素材包**，选你的 zip。
2. App 依次检查：zip 能否打开、路径是否安全、文件类型、大小/数量、runtime 摘要（有 runtime 时）、是否有 `.model3.json`；全部通过才写入 App 私有目录（整包替换是事务式的，失败保留旧包）。
3. 舞台加载后做一次体检：能不能加载、moc 版本、参数表、表情/动作/部件名、标准参数覆盖、触摸区来源。体检报告只给 App 和适配用，不含模型文件和贴图。
4. 需要时出现适配入口（见 §4）；不需要就直接能用。
5. 想换一个包：菜单 **更多 → 移除素材**（会删除这台手机上的角色素材，聊天不受影响），回到「把她接回家」再导入。

常见错误与处理：

| 提示 | 原因 | 处理 |
|---|---|---|
| 这个文件打不开，可能不是素材包或已经损坏 | zip 损坏 / 不是 zip | 重新打包，别用会加杂项文件的压缩工具 |
| 包里没有找到 Live2D 模型（.model3.json） | 模型文件夹没进 zip，或 zip 里多套了一层 | 让 zip 根目录就是模型内容 |
| 这是 Cubism 2 的旧模型 | `.moc` + `model.json` | Cubism Editor 导出 moc3 后再打包 |
| 这个模型是用更新版本的 Cubism 导出的（moc 版本 N） | moc 枚举 > 当前 Core 上限 6 | Editor 里导出成旧一点的版本 |
| 这个包只有角色，手机上还没有运行库 | 只有 character/，且本机没装过完整包 | 先装官方/完整素材包 |
| 素材包里的运行库和这个版本的 App 对不上 | 包里自带的 runtime 摘要不符 | 去掉 runtime，只发 character/ |
| 包里有不允许的文件或路径 | `..`/绝对路径/符号链接/非白名单扩展名放进了 character/ | 清理后重打 |
| 素材包太大了 | 超过 400 MB 或 4000 个文件 | 删无用资源、压缩贴图 |
| 写入失败，看看手机存储空间够不够 | 磁盘满/权限 | 清理空间 |

## 4. 适配表（app-local-adapter-v1）

### 4.1 它做什么

适配表把「舞台的标准语义」接到「你的模型参数」上：`ParamAngleX` 对应哪根转头轴，`happy` 用哪个表情和哪些脸部增量，触摸落在哪个纵向区间。舞台只把它当数据执行，不执行任何代码。

它可以由两种方式产生：

App 只在「需要判断」时提议适配，任一条件成立即可：缺 4 个核心参数之一（`ParamAngleX`、`ParamAngleY`、`ParamEyeLOpen`、`ParamMouthOpenY`）、触摸区还在用默认分区、没有情绪表且模型自带至少 2 个表情、有像尾巴的参数却没登记 `tail`。你把这些都在 `character.json` 里配好，就不需要适配。

1. **AI 适配**（普通用户路径）：App 把模型名、参数名单（id/显示名/范围/分组）、表情动作和部件名、用户写的一句「哪里不对」、当前适配表发给用户自己的模型（轻量模式，DeepSeek API，按次计费）；收回来先在 App 里校验，再写入 `character/adapter.json`。
2. **作者预置**：手写 `adapter.json` 放进包里（见 §2.4）。

第一次自动适配前，App 会先出一张卡片说明会发送什么，用户点 **适配** 才发；之后默认自动适配新模型，可在菜单里用 **导入新模型时自动适配** 关掉。发出去的只有模型名、参数 id/显示名/范围、表情动作和部件的名字、用户写的话和当前适配表。菜单里的 **适配这个模型** 可带一句「哪里不对」重试，**撤销适配** 删除当前表。

### 4.2 字段

```json
{
  "adapter": 1,
  "moc": "<moc3 的 sha256>",
  "params": {
    "ParamAngleX": { "id": "PARAM_ANGLE_X" },
    "ParamEyeLOpen": { "id": "EyeL", "scale": -1, "offset": 1 }
  },
  "emotions": {
    "happy": { "face": { "ParamEyeSmile": 1 }, "expression": "02 龇牙" }
  },
  "actions": { "wave": { "motion": "挥手" } },
  "zones": [{ "id": "head", "from": 0.02, "to": 0.19 }],
  "tail": ["Param_Angle_Rotation_2"],
  "notes": "一句话说明做了什么"
}
```

| 字段 | 接受什么 | 边界 |
|---|---|---|
| `adapter` | 只能是 `1` | 其他值整份丢弃 |
| `params` | 18 个标准参数名之一 → `{id, scale?, offset?}`；`id` 可以是字符串或同驱 ID 列表 | id 必须是体检报告里存在、且不在保护名单里的参数；`scale` 有限非零、\|scale\|≤1000；`offset` 有限、\|offset\|≤1000；非法值整项丢弃；列表会去重 |
| `emotions` | `calm/happy/shy/sad/angry/surprised/confused/smug/sleepy/worried` → `{face?, expression?, ...}` | `face` 只能用 18 个标准参数并按语义域夹值；`ParamEyeLOpen/ROpen` **不接受**（会被眨眼覆盖）；`expression` 必须是 App 已验证过效果的资源，当前默认没有证据 → 写不进去 |
| `actions` | 12 个动作名 → `{motion}` | `motion` 同样需要已验证效果，当前默认写不进去 |
| `zones` | `{id, from, to, xFrom?, xTo?}` | 只能复制体检报告里已有的几何；`zones: []` 会整项拒收（不能用空数组假装关掉默认区） |
| `tail` | 参数 ID 数组 | 必须是模型里存在的参数，且已在尾巴名单里、或名字像尾巴（`tail`/尾巴/尻尾） |
| `notes` | 一句中文 | 最多 60 个 Unicode 字符 |

语义公式：`set(v) = clamp(v*scale + offset, 原生min, 原生max)`；`add(d) = clamp(当前原生值 + d*scale, …)`，**增量不加 offset**。默认 `scale=1, offset=0`。眼睛最大值 2 表示还能睁更大，正常睁眼仍是 1，不要机械按范围换算。`id` 用列表时，只在多个目标的语义、方向、单位一致且适用同一仿射式时使用；把一个闭眼和一个睁眼参数共用一式会被拒。

### 4.3 AI 适配**不会**做的事（手写时也请避开）

- AI 适配不写 `moc` 指纹（App 自己算）；手写的 `adapter.json` 仍须按 §2.4 写入 `moc`。
- 不写 `framing`、`pose`、`toggles`、代码、URL 或任何未知顶层字段——未知字段会记进 `dropped` 并丢弃。
- 不写任意 native 参数名或虚拟 eyelids；`face` 只认 18 个标准参数；`gaze`/`eyelid` 不属于 AI 契约（它们只出现在 `character.json` 的 `emotions` 里，由舞台执行）。
- 不从名字猜效果：加载成功、名字叫「开心」都不算证据；没有 `verifiedEffects` 就不开新的表情/动作资源。
- 不控制服装、水印、署名、透明度、声音、事件；名称含「水印/署名/换装/透明/隐藏/开关」等字样的参数会被排除。
- 不凭空造触摸区、不按人形比例猜头尾腿、不用头发/衣服参数假装尾巴。
- 不保证「最多三轮」：页面不会自动反复重试；用户可在菜单 **适配这个模型** 里写一句「哪里不对」再试一次，或 **撤销适配**。
- 没有截图/像素级验收：App 只做结构校验，视觉正确性要靠真机看。

**为空是正常结果**：没有可用改动时会输出空表（只有 notes），App 会提示「模型没找到能用的对应」，不会花额外轮次假造。

## 5. 模型自带的动作和表情（不用适配表）

模型里的 `.exp3.json` 和 `.motion3.json` 会在 App 的 **动作和表情** 页列出来：

- 用户可以对每一条**开/关**、**改个叫法**、点 **试一下** 在角色身上预览。
- 开着的会以标记的形式教给 AI：`[表情:名字]`、`[动作:名字]`（表情、动作各最多 24 条，按列表顺序），她回复时会自己用。
- 默认开启的判定：名字读起来像词（至少两个字母/汉字），表情名不含「水印/隐藏/开关」这类字样，动作名不以 `idle` 开头。

**作者建议**：给 `.exp3.json`/`.motion3.json` 起有意义的文件名和 Name（`wave`、`脸红`、`挥手`），别用 `01`、`X X`；不要把换装/显隐做成表情；idle 循环不要放进表情动作列表。

## 6. 作者自检

**App 内（所有作者）**

1. 导入后先看默认姿态和取景是否正常（`framing`）。
2. 打开 **动作和表情**，逐条 **试一下**。
3. 菜单 **适配这个模型**：可填一句「哪里不对」，看 AI 适配结果；不满意 **撤销适配** 再试。
4. 摸头、点脸、点身体、点尾巴，确认 `zones` 反应符合预期。

**仓库工具（需要 checkout 仓库 + Dart/Node，面向维护者）**

| 命令 | 用途 | 对第三方作者可用吗 |
|---|---|---|
| `dart tooling/companion/check-adapt-contract.dart` | 用真实纯 Dart 契约跑自测 | 只能验证格式理解，**不检查你的模型** |
| `dart tooling/companion/adapt-dry-run.dart probe.json [candidate.json]` | 生成真实适配请求 / 校验候选表 | 需要 `probe.json`（舞台体检报告）；App 目前没有给作者的导出入口，仓库 fixture 也不面向第三方 → **实际不可用**（UNVERIFIED） |
| `node --test tooling/companion/replay-model-corpus.test.mjs` | 用固定 SHA 的 stage 回放历史 24 个模型的规则绑定 | **开发者评测**，不评测新模型，不产出适配表 |
| `node tooling/companion/sync-adapt-skill.mjs --check` | 校验 `companion-adapt` 技能提示词与 App 内契约逐字一致 | 维护者工具 |

## 7. 发布与分享

- **创意工坊（技术路径已实现，尚未上线）**：伙伴小屋菜单 **创意工坊** → **我的投稿** → **投稿**，在 **选一个要投稿的** 里选小屋当前的伙伴。填名称、作者、许可、来源，可选一张封面 PNG（≤2 MiB、每边 ≤512、面积 ≤262144），勾选 **我确认自己有权分享这份内容**，提交后等审核；审核通过才公开，可 **撤回投稿**。投稿需要登录论坛账号；本机没装伙伴时这一项选不到。
- **工坊里的伙伴包只有 `character/`**：不含 runtime；安装方必须已有本机 runtime（缺了报错，不自动下载）。服务端限制：≤1000 个文件、单文件 ≤16 MiB、展开 ≤128 MiB、压缩包 ≤50 MiB；moc3 必须是 `MOC3` 头且枚举 1–6；`character.json` 的 `name`/`model` 必需，`author`/`license`/`source` 元数据要一致；所有 model3 引用的文件必须真的在角色目录里。
- **工坊导出会重建数据**：只带模型引用到的文件、已知字段；未知配置、UserData、动作事件文本、声音和 Sound 引用不导出；明确命名的 `LICENSE`/`COPYING`/`NOTICE` 文本会保留。适配表保留 params/emotions/actions/zones/tail/pose/framing。
- **直接分享 zip** 也可以：对方在 App 里手动导入。但模型的版权、授权和 Live2D 条款由分享者负责。
- **现状提醒**：工坊已部署在 `go.dshtui.com`，App 默认就接它，但还没在真机上走过一遍投稿。看不到「创意工坊」说明这个版本早于默认接入，或构建时把 `DSH_WORKSHOP_ORIGIN` 设成了空串。
- **Live2D 条款**：允许用户加载任意模型的应用属于 Live2D 的 Expandable Application，官方写明完全免费的应用原则上不批；随包鲸娘是单独取得作者授权分发的。第三方模型公开分发/上架前，需要先与 Live2D 确认条款（仓库设计文档里仍是待确认项）。

## 8. 明确不支持 / 会被拒

- Cubism 2（`.moc`/`model.json`）、自定义/替换运行库、任何脚本或 HTML（`character/` 只收数据文件）。
- 像素级自动验收、截图多轮返工、「最多三轮自动调度」：未实现。
- 完整模式（主机 agent）的适配页面编排：契约和 skill 已在，页面接线未完成；当前 AI 适配走轻量模式（App 直接调 DeepSeek）。
- 在线模型校验/上传服务：没有。
- 工坊正式上线与真机验证：未完成。

## 9. UNVERIFIED

- 工坊上线时间、审核流程细节与真机表现：仅按代码与设计文档整理，未实测。
- Live2D Expandable Application 条款的最终结论：仓库标注为待确认。
- moc 枚举 1–6 与 Cubism Editor 产品版本号的对应关系：仓库只记录枚举上限 6，未建立版本对照表。
- `adapt-dry-run.dart` 对第三方作者是否会被提供 probe 导出：目前没有入口，按「不可用」写。
- 手写 `adapter.json` 的完整体验（工坊导出会重建字段，服务端还有额外严格校验）：未做端到端实测。
