# 会话哨兵 · dsh-session-watchdog

> v0.3.3 · 完成卡片不再误显示历史工具错误码（CODE_RUN_FAILED） · v0.3.2 · 完成卡片固定右下角、会话名与会话列表一致 · 崩溃恢复自动续跑补读真实会话日志 · v0.3.1 · 修复续跑路径读取未注入服务导致宿主崩溃 · v0.3.0 · 新增任务完成提醒 + 6 种叮咚提示音；续跑指令改为依据会话真实内容生成（模型生成 / 上下文拼装双模式）

> DeepSeek Harness 插件：实时监控会话运行状态；会话异常停止时提醒，并可依据该会话的断点上下文自动续跑。

## 它解决什么问题

DSH 的一次 turn 可能因为模型报错、限流、进程被杀、输出超长或长时间假死而中断。人不在电脑前时，会话就停在半路，任务没人接。会话哨兵做三件事：

1. **看得见**：宿主侧订阅 `session/event`，以 turn 结束原因 + 假死心跳 + 启动恢复三通道判定「异常停止」。
2. **叫得应**：浏览器半侧弹出页面卡片、侧栏徽标和系统通知；异常停止可一键「续跑」，**任务完成也会弹窗并播放叮咚提示音（6 种可选）**。
3. **接得上**：从会话事件流提取**真实对话原文 / 未完成待办 / 目标 / 最后动作与错误**，默认让该会话自己的模型据此写出承接上下文的续跑指令（失败回落到上下文拼装），通过宿主自己的 `sessionController.prompt` 通道发回会话（与 GUI 发消息同一条路径）。

## 安装

~~~powershell
# 方式一：从发布包（仓库根目录）
dsh plugin --profile desktop add ./dsh-session-watchdog-0.3.3.tgz

# 方式二：从本地源码（开发态，link 本地目录）
dsh plugin --profile desktop add link:/path/to/plugins/dsh-session-watchdog
~~~

装完通常**无需重启**：新插件会被桌面版 HMR 热加载（实测 `dsh plugin add` 后宿主路由立即 200）；如果设置页没出现新条目，刷新一次页面或重开桌面版。

设置入口：**设置 → 左侧「会话哨兵」**。真机截图：`docs/preview/截图1~7`（1-5 基础面板，6 完成提醒与提示音，7 续跑指令生成方式）。

卸载：

~~~powershell
dsh plugin --profile desktop remove dsh-session-watchdog
~~~

## 配置

在 profile 的 `cordis.patch.yml` 里覆盖本插件条目的 `config`（整块替换，不深合并）：

~~~yaml
- insert:
    - id: dsh-session-watchdog
      name: dsh-session-watchdog
      config:
        autoResume: true
        resumeKinds: [error, interrupted, max-tokens, blocked]
        maxResumesPerSession: 2
        notifyOs: true
~~~

完整字段见 [docs/01-设计说明.md](docs/01-设计说明.md) 的配置项总表。

## 目录

- `lib/index.js` —— 宿主入口：事件订阅、编排、路由、启动恢复
- `lib/detector.js` —— 停止判定状态机（纯逻辑）
- `lib/policy.js` —— 提醒/续跑策略：去重、预算、熔断（纯逻辑）
- `lib/context.js` —— 结构化提取 + 真实对话原文摘录（纯逻辑）
- `lib/resume-instruction.js` —— 依据真实会话内容生成续跑指令（llm / context 双模式，失败回落）
- `lib/runner.js` —— 续跑执行（sessionController.prompt → agent.followup 兜底）
- `lib/notify.js` —— 提醒事件流 + webServer 路由
- `lib/store.js` —— 状态持久化（原子写）
- `lib/config-store.js` —— 运行时配置（设置面板写入，覆盖 patch 静态配置）
- `lib/client.js` —— 浏览器半侧：页面卡片、侧栏徽标、系统通知、设置面板
- `docs/` —— 设计说明 + 实现方案
- `test/` —— 58 个单测/集成测试（含设置面板/铃声自测）+ 反向插桩脚本

## 验证

~~~powershell
cd F:\开发\Dsh-chajian\dsh-session-watchdog
node --test                                    # 63 tests pass（含完成提醒、真实指令、设置面板/铃声、崩溃与恢复上下文回归）
powershell -NoProfile -ExecutionPolicy Bypass -File test\mutation-check.ps1   # 反向插桩：4 个变异体全部被杀死
~~~

## 边界（做不到 / 默认不做）

- **不往会话里插「系统消息」**：DSH 没有公开的「只记录、不进模型上下文」的第三方 API；替代方案是提醒流 + 续跑指令。
- **用户主动停止（aborted/user）默认不提醒、不续跑**；宿主退出（aborted/disposed）不报警。
- **子代理会话默认不监控**（`monitorSubagents: false`）。
- 自动续跑有预算与熔断，不会无限重试；等待用户审批时只提醒。
- 插件必须重启桌面版生效；宿主退出只有 5 秒窗口，状态采用「写一条落一条」的原子写。
