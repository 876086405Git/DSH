# 做一只 dsh-go 宠物包（作者指南）

dsh-go 的状态宠物是「一个 zip + 一份 `pack.json` + 几张平铺 PNG」。做完后先在本机 App 里导入自测，满意了再到创意工坊投稿。

**最短路径**

1. 画动作：每段动画一张平铺 PNG，格子等大；相同帧只存一格，用 `frames[].i` 重复引用。
2. 写 `pack.json`（schema 1）：至少一个 `idle` 动画和 `states.idle`。
3. 打包：`pack.json` 和它引用的 PNG 放在 zip 顶层，**或**同一个文件夹里。
4. 导入：App 里 **设置 → 宠物 → 选择器最后一格「导入」**，选 zip。
5. 调状态和时长，长按导入的宠物可删除重来；投稿入口在 **创意工坊 → 我的投稿 → 投稿**。

> 注意：清单文件叫 **`pack.json`**。`pet.json` 是 Codex 宠物兼容格式（§7），原生宠物包不要用它。
>
> App 内宠物和「App 外显示」的悬浮窗读同一份包，但悬浮窗的解析更严格（整数、几何按 Android Float32 算法）。本文按更严格的这一套写，照做两边都能跑。

---

## 1. 包格式、目录与大小限制

```
my-cat.zip
├─ pack.json          清单（必需，只能有一个）
├─ idle.png           动画图集（文件名由 pack.json 的 sheet 指定）
└─ working.png
```

也可以套一层文件夹：`my-cat.zip → my-cat/pack.json + my-cat/idle.png + …`。只能顶层或**一层**文件夹；更深（如 `a/b/pack.json`）不识别。

**zip 规则**

- 只认普通文件和目录；不加密、只用 store/deflate；不允许符号链接。
- 路径不许绝对路径、反斜杠、NUL、`:`、`.`、`..`。
- 文件名按 **Unicode 15 NFC + casefold** 比较，归一后重名直接拒（例如 `idle.png` 和 `Idle.PNG` 只能留一个）。
- 不按归档路径解压；只保留 `pack.json` 和它引用的 PNG，其它文件悄悄丢掉（不报错，但别依赖）。
- 有 `pack.json` 时以它为准；**坏掉的 pack.json 不会回退**去读同时存在的 Codex `pet.json`。

**硬限制**（`app/tool/pet-pack.rules.json`，rule set revision 3；App 生成常量在 `app/lib/pets/pet_pack_rules.g.dart`）

| 项 | 限制 |
|---|---|
| zip 文件 | ≤ 64 MiB；声明的展开总量也 ≤ 64 MiB；条目（含目录）≤ 256 |
| `pack.json` | ≤ 256 KiB；UTF-8，无 BOM；JSON 深度 ≤ 64（导入门另有 60 层限制）；拒重复键、非有限数、孤立代理字符 |
| 图集数量 | ≤ 64 张 |
| 单张图 | 压缩后 ≤ 8 MiB；每边 ≤ 4096 px；解码缓冲 `w×h×4` ≤ 16 MiB |
| 全部图集合计 | ≤ 48 MiB |
| 图集文件名 | 平铺、无目录；`.png` 结尾；≤ 120 个 UTF-16 码元；不以 `.` 开头；不含 `/`、反斜杠、NUL |
| 数值 | 帧 `i` ≥ 0、`ms` ≥ 1，整数；`frameW`/`frameH`/`cols` 1–4096；`canvas` 1–2³⁰；`scale` 1–4096，都是整数（导入门要求） |

## 2. 最小可用包（可直接照抄）

目录：

```
my-cat/
├─ pack.json
├─ idle.png      48×20：两个 24×20 的格子横排
└─ working.png   48×20：同上
```

`pack.json`：

```json
{
  "schema": 1,
  "id": "my-cat",
  "name": "我的猫",
  "author": "你的名字",
  "license": "CC-BY-4.0",
  "source": "https://example.com/my-cat",
  "pixelArt": true,
  "scale": 1,
  "canvas": { "w": 32, "h": 32 },
  "anchor": { "x": 16, "baseline": 28 },
  "contentBox": { "x": 4, "y": 8, "w": 24, "h": 20 },
  "animations": {
    "idle": {
      "sheet": "idle.png", "frameW": 24, "frameH": 20, "cols": 2,
      "box": { "x": 4, "y": 8, "w": 24, "h": 20 },
      "frames": [ { "i": 0, "ms": 400 }, { "i": 1, "ms": 400 } ]
    },
    "working": {
      "sheet": "working.png", "frameW": 24, "frameH": 20, "cols": 2,
      "box": { "x": 4, "y": 8, "w": 24, "h": 20 },
      "frames": [ { "i": 0, "ms": 200 }, { "i": 1, "ms": 200 } ]
    }
  },
  "states": { "idle": ["idle"], "working": ["working"], "thinking": ["idle"] },
  "reactions": { "tapLeft": "idle", "tapRight": "idle" }
}
```

- `canvas` 是画布；`anchor.baseline = 28` 是脚线（28 行处站立，下方 4 px 可放阴影）。
- `contentBox` 是待机身体框：App 用它定宠物大小、放气泡、兜底命中判定。
- 只做 idle 也能跑：没写的状态自动回落到 `states.idle` 的第一个动画。

打包：

```sh
cd my-cat && zip -r ../my-cat.zip pack.json idle.png working.png
```

## 3. `pack.json` 字段

App 只读它认识的字段，未知字段忽略。**`description` 不读**（那是创意工坊投稿表单里的字段）。

### 3.1 顶层

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `schema` | ✅ | — | 必须是 `1` |
| `id` | ✅ | — | 非空字符串。导入时转成文件夹名：`[a-z0-9]+(-[a-z0-9]+)*` 且 ≤48 字符就原样保留，否则转 slug + 原 id 的 SHA-256 前 8 位；已带 `user-` 前缀的不重复加。同 id 再导入会覆盖 |
| `name` | — | `id` | 宠物选择器里显示 |
| `author` / `license` / `source` | 本机导入可省；**上工坊必填** | — | 宠物页底部显示 `author · license`。工坊另有许可白名单，见 §9 |
| `pixelArt` | — | `true` | 导入时会写进装好的清单 |
| `scale` | — | `1` | 图集像素 ÷ 美术像素的倍率；导入时会写进装好的清单 |
| `canvas` | ✅ | — | `{w,h}`，美术像素，正整数 |
| `anchor` | — | `{x: w/2, baseline: canvas.h}` | `baseline` 是脚线（站位胶囊上沿），`x` 是身体中心、也是左右镜像轴；可写 `.5` |
| `contentBox` | ✅ | — | `{x,y,w,h}`，待机身体框，`w,h > 0`；决定大小、气泡位置和默认命中框 |

### 3.2 `animations`（必填，≥1 段）

每段：`sheet`（PNG 文件名）、`frameW`/`frameH`（一格多少图集像素）、`cols`（一行几格）、`box`（这格贴回画布的位置，美术像素）、`frames`（`[{i, ms}]`，`i` 是第几格，从 0 开始，`ms` 是显示时长）、`loop`（可选，默认 `true`）。

- 动画名随便起（`idle`、`typing`、`react-left`…），`states`/`tiers`/`reactions` 用名字引用。
- 相同帧只存一格：`i` 可以重复，省图。
- 动画级 `ms` **不读**；时长只看每帧的 `ms`。

### 3.3 `states`（必填）

`状态名 → [动画名, …]`。第一个是主动画，其余是变体。**必须包含非空的 `idle`**。状态名见 §5；未知状态名允许写但不会被选中。

### 3.4 可选字段

| 字段 | 作用 |
|---|---|
| `tiers` | `状态 → [{min, anim}]`。`min` 默认 1；忙碌档（working/juggling）按全局对话数/子代理数选「min ≤ 当前档位」里最大的那项 |
| `timings.minDisplay` | `状态 → ms`。一次性态至少显示多久 |
| `timings.autoReturn` | `状态 → ms`。一次性态多久后回到持续态；`notification` 永远持续到处理完，写了也不生效 |
| `timings.playMs` | `动画 → ms`。播一遍的实际时长；默认=帧时长之和 |
| `timings.wakeMs` | 数字，醒来的总时长；默认=waking 动画一遍，没有则 1500 |
| `reactions` | `tapLeft` / `tapRight` / `tickle` / `drag` → 动画名 |
| `roam` | `{anim, faces: left/right/front}`。游走动画和美术朝向；反方向走时按 `anchor.x` 镜像，`front` 不镜像。旧写法 `flip:false` 等于 `front` |
| `sleep` | `{afterMs}`，空闲多久睡觉，默认 60000 |
| `hitBoxes` | `default`/`wide`/`sleeping` 三个矩形（美术像素），`byAnim` 单独指定，`wideAnims`/`sleepingAnims` 分组；查找顺序 `byAnim → sleepingAnims → wideAnims → default → contentBox` |
| `idlePool` | 待机小动作池：`{anims: [{anim, ms, weight}], everyMs: {mean, min, max}}`；不写时用 `states.idle` 除主动画外的其它动画 |
| `bonus` | 非 idle 状态的彩蛋：`状态 → {anims: [...], chance: 0–1}`；`chance` 默认 0，等于不启用 |

**默认值**（不写时生效）：`minDisplay` = attention 5200 / error 4800 / sweeping 5600 / notification 3200 / carrying 3200 / working 1000 / thinking 1000（ms）；`autoReturn` = attention 5200 / error 4800 / sweeping 300000 / carrying 3200；`sleep.afterMs` 60000；`idlePool.everyMs` mean 120000 / min 45000 / max 300000。

## 4. 图集规范

### 4.1 两套坐标

- **美术像素**（`canvas`、`box`、`anchor`、`contentBox`、`hitBoxes`）：作者设计坐标。
- **图集像素**（PNG 里）：`scale` 是两者比值。1x 导出就 `scale: 1`；5 倍导出写 `scale: 5`。
- 每格尺寸必须精确：`frameW = trunc(box.w × scale)`、`frameH = trunc(box.h × scale)`（App 用 Float32 算完再截断比较）。**最省事：box 宽高和 scale 都用整数。**
- 例：`box.w = 36, scale = 5 → frameW = 180`；`box.h = 24 → frameH = 120`。

### 4.2 网格与图集

- 一格里放一帧，按行优先排：第 `i` 帧位于 `col = i % cols`、`row = i ~/ cols`。
- PNG 宽 ≥ `cols × frameW`，高 ≥ `(最大 i ~/ cols + 1) × frameH`；建议正好相等，透明处留空。
- 每张图每边 ≤ 4096 px。帧多时用 `cols` 排成网格，别拉一条超宽横条。
- 图集文件名由 `animations.*.sheet` 指定，同一张 PNG 可以被多段动画共用。

### 4.3 PNG 要求

必须是完整、合法的 PNG：CRC 正确、IDAT 连续、zlib 精确结束、无尾随数据；允许调色板 + `tRNS`；**拒收 APNG**（`acTL`/`fcTL`/`fdAT`）、未知关键块和严重损坏的图。附属文本/ICC 元数据有独立预算，市场归一化会去掉它们——想省体积就用调色板 PNG 或干净 RGBA。

### 4.4 清晰度与物理像素

- `pixelArt: true` 且 `scale: 1`：最近邻绘制，App 选整数倍，让每个美术像素占整数个物理像素（左上角、脚线都对物理像素）。
- `scale > 1` 或 `pixelArt: false`：平滑缩放，倍数不限整数。
- 宠物大小按 `contentBox.h` 定档（小 22dp / 标准 30dp / 大 40dp；用户还能在「自定义」里拖到标准的 50%–300%），不按 canvas。想让宠物显大，调 `contentBox`，别放大 canvas。
- 建议按 1x 美术像素绘制、整像素排版，需要镜像轴落在半像素时再写 `anchor.x: 35.5` 这类值。

### 4.5 锚点与命中框

- `baseline`：身体最低不透明行的下沿（脚线），不要算阴影；它决定宠物站在胶囊上的位置。
- `anchor.x`：身体水平中心，也是镜像轴。
- `contentBox`：待机身体框；也是默认命中框。
- 命中框只量身体：思考云、Zzz、音符这类脱离身体的道具不要框进去；被拎起（drag）姿势如果身体超出 default，用 `byAnim.drag` 单独给。

## 5. 状态与事件

App 把 agent 的活动归约成 11 个状态。**只做 idle 也能用**，其余状态缺失时回落到 idle。

| 状态 | 何时出现 | 类型 |
|---|---|---|
| `idle` | 范围内没有在跑的轮 | 持续 |
| `thinking` | 等模型、推理、重试 | 持续 |
| `working` | 工具运行 / 回复流式输出；按全局运行中对话数分档（1 / 2 / 3+） | 持续，可分档 |
| `juggling` | 子代理在跑；按子代理数分档（1 / 2+） | 持续，可分档 |
| `sweeping` | 上下文压缩 | 持续（autoReturn 300s 兜底） |
| `notification` | 有待确认或待回答的事 | 持续到处理完 |
| `attention` | 一轮完成，且 1.5s 内没有开始新一轮 | 一次性 |
| `error` | 一轮失败（引擎重启不算） | 一次性 |
| `carrying` | 预留：上传/导入文件；**当前不会被触发** | 持续 |
| `sleeping` | 空闲且 60s 没触摸（`sleep.afterMs`） | 持续 |
| `waking` | 睡着时被触摸或来了事件 | 一次性（`wakeMs`） |

**优先级**（高覆盖低）：`error` 8 > `notification` 7 > `sweeping` 6 > `attention` 5 > `carrying`=`juggling` 4 > `working` 3 > `thinking` 2 > `idle`=`waking` 1 > `sleeping` 0。一次性态至少显示 `minDisplay`，到 `autoReturn` 回到当前持续态；低优先级状态不会打断高优先级一次性态。忙碌档升档立即生效，降档要低档持续 5 秒。

**游走**：App 内空闲时随机走动，用 `roam.anim`；悬浮窗不游走。`roam.faces` 决定镜像方向。

**互动**：点身体左/右半边 → `tapLeft`/`tapRight`；1.1 秒内连点 3 次 → `tickle`；拖动 → `drag`。反应动画播完回到原状态；睡着时先播 `waking`。

**不会发生的事**：停止（stopped）安静回 idle，不报错；压缩完成不庆祝；断线或引擎重启不会进 `error`。

## 6. 导入、校验与删除

**入口**：**设置 → 宠物 → 选择器最后一格「导入」**，选 zip。同一个 id 再导入会覆盖成新版（选择器里长按导入的宠物可以删除；删的正好是当前选中那只时换回默认宠物）。

失败时 App 给四类提示，详情里带校验器的英文代码：

| App 提示 | 常见 detail 代码 | 怎么改 |
|---|---|---|
| 这不是 zip 文件 | `archive-invalid`、`archive-header`、`archive-type`、`archive-encoding`、`archive-duplicate`、`archive-multidisk` 等 | 重新用标准 zip 打包；检查是否加密、多卷、重名不合法。注：`archive-path` 会显示成「序列帧图不对」，`archive-member-missing` 显示成「少了序列帧图」 |
| zip 里没有 pack.json | — | 清单放顶层或一层文件夹；确认文件名就是 `pack.json` |
| pack.json 有问题：… | `pack-schema`、`json-*`、`pack-overlay` | 对照 §3；`pack-overlay` 表示没过悬浮窗更严格的整数/几何检查 |
| zip 里少了序列帧图 X | `sheet-missing` | `sheet` 名字与实际文件名不一致 |
| 序列帧图不对：X | `png-*`、`sheet-name`、`sheet-alias`、`sheet-frame-bounds` | PNG 不完整/是 APNG/名不合规/格子超出图 |
| 这个宠物包太大了 | `sheet-size`、`sheet-total-size`、`sheet-count`、`pack-size`、`pack-normalized-size`、`archive-expanded-size`、`archive-member-size`、`archive-entries` | 对照 §1 的限制 |
| 没能存到手机上 | `storage` | 手机空间/权限问题，重试 |

其它常见 detail：
- `archive-pack-count` —— `pack.json` 出现 0 个或多个（例如顶层和子文件夹各一个）。
- `json-duplicate-key` / `json-bom` / `json-depth` —— 清单有重复键 / 带 BOM / 嵌套过深。
- `sheet-count` / `sheet-alias` —— 图太多，或两张图归一化后同名。
- `pack.json: schema` / `pack.json: canvas` / `pack.json: contentBox` / `pack.json: frames of X` —— 对应字段缺失或值不合法。
- `pack-overlay` 的 detail 例如 `pack.json: frameW, frameH of idle ≠ box × scale`。

## 7. Codex 宠物兼容

没有 `pack.json`、但有 Codex 格式的 `pet.json` 时，App 会自动转换后再走同一套校验：

- `pet.json` 放 zip 顶层或一层文件夹，必须唯一。
- `spriteVersionNumber`：`1`（缺省）或 `2`。v1 图集 1536×1872，默认 8 列 × 9 行、每格 192×208；v2 图集 1536×2288，固定 8 列 × 11 行。
- `spritesheetPath`：缺省 `spritesheet.webp`；支持 PNG 或**静态** WebP（WebP 会转成 PNG，保持像素网格）。
- v1 可以覆盖 `animations`（`frames`、`fps` 1–60、`loop`、`fallback`）和图集 `frame` 网格；v2 拒绝自定义网格/动画。
- 转换结果：schema 1、`pixelArt: false`、`scale: 1`，状态映射：thinking→waiting、working/juggling/sweeping/carrying→running、notification→waiting、attention→review、error→failed、sleeping→idle 首帧、waking→jumping、roam→running-right（向左镜像）、tapLeft/tapRight→waving、tickle→jumping、drag→running-right。
- 会降级/丢信息，导入后 App 弹窗列出（也写进装好包的 `codexImport.warnings`）：动作一直循环到状态变化、往左走镜像、拖拽固定用朝右轨道、睡觉用待机首帧、v2 的 look 行不绑定、WebP 转 PNG、自定义轨道没接到状态、fps 取整、一次性动作返回由 DSH 决定、缺 author/license/source。
- 作者、许可、来源按原字段保留；缺失只警告，不推断可公开发布。

## 8. 导出与分享（投稿时会自动打包）

App **没有**给用户单独的「导出宠物包」按钮。投稿时客户端会把选中的宠物重新导出成规范 zip：

- 只含 `pack.json` 和它引用的 PNG；未知元数据、`codexImport`、本地投稿凭据都不进包。
- `pack.json` 的 `id` 改写成投稿表单里的 id；`author`/`license`/`source` 用表单填的值覆盖。
- 规范化后再过一次完整校验；客户端上传 zip 上限 50 MiB，工坊整体按 128 MiB 展开预算（服务端另有规则）。

## 9. 发布到创意工坊

1. 论坛账号登录（第一次会先说明：为了认人，会把论坛登录凭据发给工坊服务，同意后才发）。浏览、安装不用登录；投稿、查看/撤回自己的投稿要登录。
2. **创意工坊 → 我的投稿 → 投稿**，选一只已导入的宠物。
3. 填表：id、版本、minApp、中英文标题、作者、许可、来源链接、描述、标签；勾「我确认自己有权分享这份内容」。
4. 「看一眼打好的包」检查最终 zip；提交后等审核，通过才出现在「发现」，没通过会写原因，改了可以再交；之后可撤回。

**字段规则**（`app/lib/state/workshop_publication.dart`、`app/lib/workshop/workshop_models.dart`）

| 字段 | 规则 |
|---|---|
| `id` | 小写字母/数字/连字符，≤40；形如 `^[a-z0-9]+(-[a-z0-9]+)*$`；与包内 id 无关（导出时改写） |
| `version`、`minApp` | SemVer（≤80 字符）；minApp 是作品要求的最低 App 版本 |
| 标题（中/英） | 两个都必须非空，各 ≤120 字符 |
| `author` | ≤256 字符 |
| `license` | 必须是这几个之一：`CC0-1.0`、`CC-BY-4.0`、`CC-BY-SA-4.0`、`MIT`、`Apache-2.0`、`BSD-2-Clause`、`BSD-3-Clause`、`LicenseRef-Author-Permission` |
| `source` | `https://` 链接，≤2048 字符，不含空白和用户信息 |
| `description` | 可选，≤512 字符 |
| `tags` | 可选，≤8 个，每个 ≤32 字符，不重复 |

**预览图**：宠物默认用「待机动画第一帧」当预览图，可以关掉。客户端只校验并声明 `previewSource = pet-idle`（取 `states.idle` 第一段动画的首格，要求 `frameW`/`frameH` ≤ 512 且 `frameW×frameH` ≤ 262144），实际预览图由工坊生成（服务端实现见 UNVERIFIED）。超了会提示做不了预览图，**关掉预览图仍可照常投稿**。

## 10. 自测清单

目前**没有**面向作者的独立校验 CLI；App 导入就是最终校验，投稿时还会再跑一遍完整校验和预览检查。仓库里可参考的只有内部资料：

| 资料 | 用途 |
|---|---|
| `app/tool/pet-pack.rules.json` | 规则集（revision 3）：限制、必填、默认值、市场/本机差异的权威文字版 |
| `app/test/pets/fixtures/pet-pack-local-v1.json` | 合法/非法包测试向量，每条标了 `parserValid` / `appImportValid` / `marketValid` |
| `app/tool/make_pet_pack.py` | 内置两只宠物的构建管线（Clawd 主题 / 鲸娘横条 → 图集 + pack.json），需要 Pillow + numpy；不是通用校验器 |
| `app/lib/pets/` | 校验、导入、Codex 转换、渲染的实际实现 |

**导入后逐项自测**

- [ ] 导入成功；同 id 再导入是覆盖；长按能删除；删当前选中的会换回默认宠物。
- [ ] 三档大小都正常（小/标准/大），深浅色主题下都不描边、不偏色。
- [ ] 触发各状态看动作是否正确：发一句话看 `thinking`/`working`，用工具、压缩上下文看 `sweeping`，触发确认看 `notification`，一轮完成看 `attention`，一轮失败看 `error`，开子代理/Agent Teams 看 `juggling`，空闲 60 秒看 `sleeping`，睡着时点一下看 `waking`，空闲等游走。`carrying` 目前不会触发，不用画。
- [ ] 点左/右、连点三次、拖动分别触发 `tapLeft`/`tapRight`/`tickle`/`drag`。
- [ ] 打开「App 外显示」：悬浮窗动作、命中区域（只认身体）正常；拖到边会吸附；关掉后不残留。
- [ ] 投稿前用「看一眼打好的包」确认最终 zip 和预览图。

## UNVERIFIED

- 本篇是静态阅读代码写的；本机不跑测试/构建，未在真机上验证导入与投稿全流程。
- 悬浮窗在个别 ROM（vivo/小米等）上的权限、吸附、各 dpr 下的实际渲染未验证。
- 未逐一核对 `docs/design/pets.md` 里的示例：其中 `states` 里写 `"roam"` 的那条不会被使用（游走只认 `roam.anim`，状态枚举里没有 roam）。
- Codex 兼容按转换器代码写，未用真实 Codex 导出包实测各版本。
- 创意工坊服务端行为（审核、预览图实际生成方式）以客户端契约和用户指南为准，未读服务端实现。
