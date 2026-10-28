# dsh-prompt-enhance · 提示词增强

给 DeepSeek Harness 的会话输入框加一个「提示词增强」按钮：点一下，把随手写下的原始内容交给当前默认模型改写成更清晰、具体、结构完整的提示词，**直接自动填入输入框**；按钮随即变成「撤回优化」，点一下即可恢复增强前的原文。

![按钮位置](docs/button.png)

## 交互

1. 在输入框写下内容，点模型选择器左边的 ✨。
2. 生成期间按钮保持 ✨，进入忽明忽暗的闪烁；再点一次可取消。
3. 生成完成后，结果自动填入输入框并聚焦在末尾，可以直接编辑或发送。
4. 按钮同时变成「撤回优化」↺：点击恢复增强前的原文。
5. 一旦你编辑、清空或发送了输入框内容，按钮自动回到 ✨（撤销记录失效），保证按钮状态与输入内容一致。

| 状态 | 按钮 | 说明 |
| --- | --- | --- |
| 空闲 | ✨ | 有内容时可点；空输入只提示 |
| 生成中 | ✨ 闪烁（无边框 / 透明底） | 再点 = 取消；图标在明暗之间循环，不显示外框线和背景 |
| 已填入 | ↺ | 仅在输入框内容仍等于刚填入的增强结果时显示 |

![生成中：✨ 明暗闪烁（透明背景）](docs/loading.png)

> 上图为按钮动画预览（实际 CSS/SVG 渲染的 4 个相位），不是整页截图；生成中按钮不显示外框线、描边、焦点光圈和背景填充。

![已填入，可撤回](docs/undo.png)

## 设计细节

- **动画**：生成中 ✨ 以 1.6s 周期在 0.3～1 不透明度之间循环（叠加轻微亮度变化），形成持续闪烁；不旋转、不位移、不再额外发光。按钮采用无边框 + 透明背景设计：去掉外框线、描边、焦点光圈和背景填充，悬停/按下也不出现底色；尊重 `prefers-reduced-motion`，系统开启减少动态效果时静止显示 ✨。
- **自动填入**：使用宿主官方 `inputActions.setDraft()`，不绕过编辑器、不接管发送链路；发送仍走原来的 Enter / 发送按钮。
- **引用芯片**：增强前的草稿按 `text + references` 结构化快照保存，增强结果里能对上原引用文本时仍写回结构化草稿，文件/文件夹/会话芯片不会降级；点 ↺ 撤回同样还原芯片。模型把引用文本改写掉时，该引用降级为纯文本，绝不按旧位置硬还原。
- **状态联动**：撤销图标由「当前草稿是否等于刚填入的增强结果」推导，不是独立的开关。编辑、清空、发送、切换会话都会让按钮回到 ✨；切换会话还会中止在途请求。
- **不抢改动**：生成期间如果你继续编辑，结果不会覆盖新内容，只提示“输入内容已变化，本次结果未填入”。
- **语言与内容**：跟随输入语言；代码、命令、路径、URL、`@` 引用、`/` 命令、变量名、数字与特殊符号原样保留；不编造用户没提供的信息。
- **模型**：使用 profile 的默认模型（`agentDefaultModel.currentSelection()`），与本机新建会话一致。

## 边界处理

| 场景 | 行为 |
| --- | --- |
| 空输入 / 只有空白 | 按钮可点，但只提示「先输入内容」，不发请求 |
| 超长输入（> 20000 字符） | 客户端先拦下并提示当前字符数；宿主端有同样的硬上限，绝不静默截断 |
| 特殊字符 / 多行 / Markdown | JSON 传输 + React 纯文本渲染；换行、`<b>`、反斜杠路径等原样保留 |
| 生成中 | ✨ 闪烁（无边框 / 透明底）；再次点击取消（中止 fetch 与上游模型请求） |
| 生成期间草稿被改动 | 不自动填入，提示重试；草稿不受影响 |
| 模型/网络失败 | 底部 toast 显示具体错误，草稿保持不变 |
| 填入后手动编辑/清空/发送 | 撤销图标自动消失，回到 ✨ |
| 引用芯片 | 增强结果仍包含同一引用文本时保留文件/文件夹/会话芯片；被模型改写掉的引用降级为纯文本；图片/文件附件不受影响 |
| 模型输出被截断（达到输出上限） | 不填入半截结果，toast 提示「请缩短输入后重试」 |
| 超时 | 宿主 120s 中止上游请求，返回 504；客户端 135s 兜底 |
| 宿主没有默认模型 / 路由未注册 | 返回明确的 `NO_MODEL` / 网络错误提示 |

## 安装

### 方式一：dsh 插件命令（推荐）

```bash
dsh plugin --profile desktop add link:F:/开发/dsh-prompt-enhance/plugins/dsh-prompt-enhance
```

命令会把依赖写进 profile、并把声明了 `dsh.bundle` 的包自动并入 `dsh.profile.bundles`。

- **Host 半侧**：运行中的 profile 会由 HMR 自动重构，路由立即注册（`GET /dsh-prompt-enhance/status` 返回 `401` = 路由已注册，`404` = 未加载）。
- **浏览器半侧**：前端插件清单在页面加载时组装，装完或更新后请 **刷新页面（Ctrl+R）**。

### 方式二：手工挂载

1. 在 profile 的 `node_modules` 下建立目录联接：

   ```cmd
   mklink /J "%USERPROFILE%\.dsh\profiles\desktop\node_modules\dsh-prompt-enhance" "F:\开发\dsh-prompt-enhance\plugins\dsh-prompt-enhance"
   ```

2. 在 `%USERPROFILE%\.dsh\profiles\desktop\cordis.patch.yml` 末尾追加：

   ```yaml
   - insert:
       - id: dsh-prompt-enhance
         name: dsh-prompt-enhance
   ```

3. 刷新页面；必要时重启 DeepSeek Harness。

> 不要在 profile 的 `cordis.patch.yml` 里重复插入已经由 `dsh.profile.bundles` 选中的条目，否则同一路由会注册两次而报错。

## 结构

```
dsh-prompt-enhance/
  package.json           dsh.bundle / dsh.client 声明
  cordis.patch.yml       bundle 层：插入 Host 插件
  lib/index.js          Host 半侧：HTTP 路由 + ctx.llm 流式改写
  lib/client.js          浏览器半侧：按钮 + 自动填入 + 撤回（手写 ModuleLoader bundle）
  test/smoke-host.mjs    Host 逻辑冒烟测试（无依赖，node 直接跑）
  test/client-draft.test.mjs  引用芯片映射纯函数测试（Node vm 直接跑 bundle）
  test/client-ui.test.mjs     按钮组件集成测试（增强填入 / 撤回 / 结构化降级回退）
  docs/                  截图
```

## 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/dsh-prompt-enhance/status` | 诊断：插件版本、默认模型、输入/输出上限 |
| `POST` | `/dsh-prompt-enhance/enhance` | 请求体 `{ text, sessionId? }`，返回 `{ ok, text, unchanged, model, finish, elapsedMs }` |

两条路由都会先经过宿主 `connection.requestRejection()` 的浏览器信任栅栏；只监听本机回环地址。

Host 侧不 import 任何 `@deepseek-ai/*` 包，只使用 `ctx.llm.stream` 的公开协议（`text-delta` / `finish`），避免第三方插件的模块解析差异。

## 验证

```bash
node test/smoke-host.mjs
node test/client-draft.test.mjs
node test/client-ui.test.mjs
```

覆盖：空输入、超长输入、非法 JSON、正常改写（含代码围栏、波浪围栏、中英文“以下是增强后的提示词：”前言清理）、真实 `finish.reason` 协议下的模型失败映射、输出截断（`max-tokens`）、流未收尾、空结果回退、方法限制、路由释放；以及引用芯片的原始快照、增强后重定位、重复引用、引用被改写后的降级、非法投影过滤，按钮组件层的结构化写入、撤回还原和宿主拒绝结构化草稿时的纯文本回退，还有生成中只渲染 `__dpe_sparkle`、三点样式已移除、闪烁关键帧已打包、busy 态无边框+透明背景规则（`background:transparent` + `border-color:transparent` + `box-shadow:none`）存在，悬停/按下也不会出现填充。

端到端在隔离 profile（独立 `DSH_HOME`、Web profile、同一个 `deepseek-account` 默认模型）上用无头 Chromium 验证过（以下交互在本次动画改动后未变）：

- 完成后自动填入，按钮变为 ↺；
- 点击 ↺ 恢复原文，按钮回到 ✨；
- 填入后手动编辑草稿，按钮立刻回到 ✨；清空/发送后同样回到 ✨；
- 发送出去的内容与填入的增强结果一致（换行未破坏），发送链路与原生一致；
- 空输入、20001 字符、生成中取消均不影响草稿。

本次只把生成中的三点波纹换成无边框+透明背景的 ✨ 明暗闪烁：`test/client-ui.test.mjs` 断言 busy 态只渲染 `__dpe_sparkle`、页面样式包含闪烁关键帧、三点样式已移除且 busy 态外框/焦点光圈/背景填充都被清掉，观感见 `docs/loading.png`；整页 E2E 没有针对新动画重跑。引用芯片的结构化写入与撤回还原同样由该测试覆盖；真实编辑器里的最终点验需刷新页面后手动确认。

## 已知限制

- 撤销图标只在输入框内容仍等于刚填入的增强结果时出现；一旦手动编辑，本次撤销记录即失效（避免覆盖你的修改）。
- 引用芯片按引用文本精确匹配重定位：模型把引用文本改写掉、拆开或换序时会降级为纯文本，不会猜位置；附件 id 不受影响。
- 增强结果使用默认模型，不读取当前会话里临时切换的模型；如需固定其它模型，可在 Host 侧改 `readDefaultRoute()`。
