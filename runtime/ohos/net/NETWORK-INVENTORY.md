# 锁定依赖中的网络入口

范围：`runtime/locks/dsh-0.2.1-rc.4` 的 `npm ci` 依赖树。Node 24.22.1 内置 Undici 是 7.30.1，npm 锁里的独立 Undici 是 **8.11.2**；不能把二者当作同一回调版本。原始词法扫描命中 39 处、28 个 JS 文件，另存 JSON。它包含浏览器构建、测试、注释和报错文字，因此不把 39 个匹配都称为后端调用。

下列行号对应安装后的原始包，在施加 O5 diff 前核对。测试证据是桌面 Linux/O0 仿真；不是对应云服务的联调或真机验收。

| 入口 | 证据位置 | 处理与验证范围 |
|---|---|---|
| DSH 代理 Agent/Pool/ProxyAgent | `@deepseek-ai/dsh-http-proxy/lib/index.js:389,427,442` | O5b 仅鸿蒙分支使用 Node HTTP dispatcher，保留现有 proxyForUrl 和环境恢复，用公共 setGlobalDispatcher 处理内置7/独立8兼容；本地代理/no_proxy/嵌套恢复/HTTPS CONNECT 实测通过。 |
| DSH 公网抓取独占 Agent 与 fetch | `@deepseek-ai/dsh-web-fetch-http/lib/index.js:154,193` | O5b 保留所有 public IP/NAT64 校验及已解析地址 pin；仅替换 transport。私网拒绝、Host、DNS单次、双栈回退、代理跳不二次解析、跨源 redirect 拒绝均经真实 provider 测试。 |
| MCP SSE | `@modelcontextprotocol/client/dist/index.mjs:4,5079–5089` | 使用锁定 `eventsource@3.0.7`，显式注入已有 fetch；复用 O5 全局/native fetch，不新增 SSE 实现。既有 EventSource 连接本地 SSE 实测通过；具体 MCP 服务鉴权没有联调。 |
| pi-ai Codex WebSocket | `@earendil-works/pi-ai/dist/api/openai-codex-responses.js:756,818` | 取原生 globalThis.WebSocket；DSH 代理服务安装后使用新的默认 dispatcher。原生无参 WebSocket 的握手、正文和关闭已测；没有用真实账号连接 Codex。 |
| DSH Connection / API gateway 客户端 | `@deepseek-ai/dsh-client-connection/lib/client.node.js:456`；`dsh-api-gateway/lib/client.node.js:158` | Node 客户端走已配置的原生 WebSocket；Dart App 的 WebSocket 不经过 Node。浏览器同名构建与 `lib/types/client/stream-client.js:40` 是不同产物，不重复计后端入口。 |
| ACP SDK WebSocket | `@agentclientprotocol/sdk/dist/ws-stream.js:244–251` | 支持调用方 options.WebSocket，否则取全局原生类；可沿默认 dispatcher 或传入特定 factory。只证实通用 transport，不宣称 ACP 协议/凭据联调完成；同目录 `.test.js` 的三次命中是上游测试。 |
| AWS WebSocket handler | `@aws-sdk/middleware-websocket/dist-cjs/index.js:59`；ESM副本57 | 使用全局 WebSocket，默认 transport 可复用。此包54/58的可选 logger.debug 会记录目标信息，鸿蒙 profile 不应传带URL诊断的 logger；本网络模块自身不输出 URL/headers。尚未跑 AWS 业务协议。 |
| OpenAI Realtime WebSocket | `openai/realtime/websocket.mjs:82,138`；beta82,150；对应 CJS副本 | 使用原生 WebSocket，带 headers 的构造器选项保留，由默认 dispatcher 传输。没有改认证逻辑、没有使用真实 API key；实际 OpenAI/Azure服务未联调。 |
| OpenAI X.509 预览 transport | `openai/auth/x509-transport.mjs:7`；`openai/internal/auth/x509-transport-capability.mjs:4`及CJS副本 | **尚不可宣称支持。** 显式新建 Undici Agent/ProxyAgent 并设置证书身份，不会因替换默认 dispatcher 自动可用。后续需把 cert/key/CA/代理语义显式接入现有 Node HTTP TLS 配置，再验证客户端证书与身份绑定；不能静默删掉这些选项。第一阶段能力表应标为未验证/不可用。 |
| Inspector/HMR/浏览器 SDK | inspector `lib/client.js:3229`、devtools chunk；HMR `lib/client.js:299`；`@google/genai/dist/web/index.mjs:25701` | 这些主要为浏览器/UI产物；O1 可按模块实际组成去除调试/HMR，不能因词法匹配就断言它们在引擎中一定执行。浏览器原生网络本身不是 Node llhttp 路径。 |

## 误报与共同边界

`openai/client.mjs:1378` / CJS1382 是错误提示中举出的 import 例子；Excel 预览文件8787 是注释；这些不作为执行入口。`ws` 的 WebSocketServer 是 Node HTTP server 的升级处理，不等同于 Undici 客户端的 WASM解析器；没有把服务器构造器混成此处的失败点。

全局 fetch 替换只覆盖调用此全局函数的代码；显式持有外部 fetch/dispatcher 的代码必须按实际入口处理。O5b 通过既有 DSH 策略服务的公共全局 dispatcher 同时覆盖常规外部 Undici与原生WebSocket，但保留显式指定的 dispatcher。Worker 有自己的 globalThis；不能未经检查把主线程的连接池或含凭据的代理环境转交给模型脚本。O4 的 worker 入口应独立安装所需网络层，并遵守现有隔离契约。

正则扫描没有证明动态构造的 import、用户后来安装的插件或所有可选 provider 都兼容。O9 扫描器仍须把额外插件的 undici/Agent/native/WASM 依赖列为独立可达性检查。
