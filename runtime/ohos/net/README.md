# 鸿蒙网络传输与 DSH 接入（O5b v3 + M3-3～5）

**未在鸿蒙真机核实。** 本包包含独立网络基础层与 DSH 的地址固定、代理策略接入补丁；整体替代 O5a，不叠加安装。不能把本包的桌面测试称为 O5 全部完成或完整 WHATWG 合规。

## 实现与依据

固定验证版本为 Node **24.22.1**，内置 Undici **7.30.1**。实测原生 Fetch 的失败点是默认 HTTP 客户端的 llhttp WASM 路径，而 Fetch 的 Request、Response、Headers、FormData、重定向、解压和 web stream 算法仍可使用。

`dispatcher.mjs` 按此版本原生 Fetch 实际使用的 内置 Undici 7 legacy 与锁定外部 Undici 8.11.2 Dispatcher 回调契约实现 HTTP/HTTPS 传输，HTTP 解析交给 Node 内建 `node:http` / `node:https`。`fetch.mjs` 把该 dispatcher 传给原生 Fetch，保留四个原生构造器的对象身份、Response 的元数据、clone、不可修改响应头及所有原生正文操作。没有新增 npm 依赖。

`preload.mjs` 仅在 `process.platform === 'openharmony'` 或明确的仿真预加载已设置进程内 `Symbol.for('dsh.go.ohos.sim') === true` 时替换全局 fetch。生产门控不读取 `DSH_GO_OHOS_SIM`；Android 即使继承这个旧环境变量，也继续原路径。普通 Linux/Android 仅导入网络 preload 不安装、不创建连接池。Android 原有启动文件均未修改。`sim/marker.mjs` 只标记本次测试，保留 JIT 与普通 Node 能力；`sim/preload.mjs` 同时设置标记和 O0 限制。网络传输仍由单独的网络 preload 安装。

默认连接预算 10 秒、响应头预算 300 秒、响应正文无进展预算 300 秒；调用方的 AbortSignal 仍由原生 Fetch 处理。正文被消费端背压暂停时不计算正文无进展期限，resume 后重新计时。超时会销毁请求，不能只发 timeout 事件。`close()` 等待已有 HTTP 请求结束再关池，`destroy()` 立即中断它们；已经交给 WebSocket 调用方的升级连接由该调用方关闭。

本模块没有 URL、请求头或正文日志。调用方显式传入的 dispatcher 原样保留，因为它可能持有 DNS 地址固定或代理策略；不以默认连接替换之。M3-4 后，默认 preload 只有在 `NODE_USE_ENV_PROXY === '1'` 时向 Node Agent 传递环境代理；未设置或为 `0` 时显式传空配置。工厂调用方明确传入的 `proxyEnv` 仍然有效。所有本工厂的回环目标使用空代理配置的独立直连池，保留原 lookup、CA 与双栈选项；`close()` / `destroy()` 同时关闭普通池与直连池。`ohos-network-transport.diff` 继续由既有 DSH 策略服务更新默认 dispatcher，并沿用 DSH 的 proxyForUrl 判定。完整规则与真实路由测试见 `M3-4.md`。

## 使用与验证

DSH 鸿蒙产品宿主通过 `dsh_node_start`，以真正的锁定 DSH bin 为主入口，仅加载 `runtime/ohos/preload.mjs`。统一入口在应用、插件及其它 dispatcher 配置之前，首先等待内部 `net/dsh-preload.mjs`，随后加载 publication；完整参数及环境约束见 [统一启动契约](../../../docs/design/harmonyos/startup.md)。它从该入口解析已锁定的 Undici 8.11.2，用公共 API 建立明确的安全基底。全局代理策略卸载时恢复其捕获的实际 prior；安全基底建立后由调用方设置的 custom dispatcher 也原样恢复。若外部 Undici 已载入但尚无本层的启动记录，则明确报 `ERR_OHOS_NET_BOOTSTRAP_ORDER`，不覆盖已有对象。详见 `M3-5.md`。以下只用于网络专项仿真，不是产品宿主启动：

```bash
node --jitless --import ./runtime/ohos/sim/preload.mjs \
  --import ./runtime/ohos/net/dsh-preload.mjs \
  /path/to/dsh-prefix/node_modules/@deepseek-ai/dsh/lib/bin.js
```

普通工厂或非 DSH 入口仍可使用 `preload.mjs` / `createFetch`，不会自动改变外部 Undici 的全局 dispatcher。DSH 全局代理安装要求专用启动前置，缺失时报 `ERR_OHOS_NET_BOOTSTRAP_REQUIRED`。Worker 继承专用 preload 时只安装该 isolate 的普通 fetch，不把 worker 文件误识别为 DSH bin。纯工厂接口适合测试和按请求固定 DNS 地址：

```js
import { createHttpDispatcher } from './dispatcher.mjs';
import { createFetch } from './fetch.mjs';
const dispatcher = createHttpDispatcher({ lookup: verifiedLookup });
const fetch = createFetch(dispatcher);
try {
  const response = await fetch(url);
  // 消费或取消正文后再关闭独占 dispatcher。
  await response.body.cancel();
} finally {
  await dispatcher.close();
}
```

从仓库根运行，仅需 Node 24.22.1 与 OpenSSL。测试证书在临时目录生成并清理，不提交证书、私钥或生成文件：

```bash
NODE=/path/to/node-v24.22.1/bin/node bash runtime/ohos/net/test.sh
```

与 O0 的全部限制组合（测试运行器需 `--test-isolation=none`，否则运行器本身会派生子进程；脚本在传入下列参数后自动加入）：

```bash
NODE=/path/to/node-v24.22.1/bin/node \
OHOS_SIM_PRELOAD="$PWD/runtime/ohos/sim/preload.mjs" \
DSH_GO_OHOS_SIM_PLATFORM=openharmony \
bash runtime/ohos/net/test.sh
```

桌面实际验证包括 JIT、jitless、O0 全限制。最新核心 41 项中 **36 通过、5 TODO、0 SKIP**。TODO 保留原始失败断言，进程退出 0 不表示它们通过。覆盖：真实本地 HTTP/HTTPS、SSE 首 chunk、multipart、Request 输入、301/302/303/307/308、跨源凭据清除、20 跳限制、不同阶段取消、超时、背压、gzip/br/deflate/zstd、堆叠编码、损坏正文、连接截断、正文取消、Content-Length、固定 DNS、显式 dispatcher、HTTP 代理、TLS 校验、资源关闭、WebSocket 升级、平台门控。

## 已确认的原生规范缺口

1. **FormData 经 307/308 重定向**：Node 24.22.1 原生 Fetch 第二跳重新生成 multipart 正文边界，但沿用第一跳的 Content-Type，导致边界不匹配。已用没有本补丁的原生 Fetch 独立复现，测试仍要求边界匹配并标记 TODO。两个独立 TODO 覆盖 307 和 308。不能当成本补丁新缺陷，也不能宣称该场景已经可用。暂不以全量缓冲或猜测正文内容的方式绕过；后续单独修正并验证大正文与取消。
2. **Response 正文阶段的 falsy abort reason**：`null`、`0`、`false` 在此原生版本会被替换成 AbortError；预先已 aborted 的同样值则能保留。三个独立 TODO 保留规范期望。默认 abort 的 AbortError 正常。自定义 reason 语义以 WHATWG 为准，不把“所有取消一律 AbortError”写成规范。

## 接入边界

- `dsh-web-fetch-http` 的 `requestPinned` 用独立 Undici Agent 保护 DNS 地址固定；换传输仍须把已验证的 lookup 传入本工厂，不能绕过原有公有地址/NAT64检查。
- `dsh-http-proxy` 维护自己的代理策略、no_proxy 与 dispatcher；需要仅鸿蒙分支接入，不静默退成直连。
- Node 原生 WebSocket 可通过 `new WebSocket(url, { dispatcher })` 使用本传输，已在 jitless 下完成真实握手、接收和关闭；O5b 在 DSH 既有代理服务里通过公共 setGlobalDispatcher 安装后，无参数原生 WebSocket 同样通过实测；不全局改写 WebSocket 类。
- 锁文件里的 `eventsource@3.0.7` 使用可注入 fetch，属于可复用现有依赖，不需要新增另一套 SSE 解析器。
- v3 已增加并实测锁定 Undici 8.11.2 的 controller 回调契约，沿用其公共 setGlobalDispatcher 兼容桥连接内置 7；未直接修改 Undici 私有全局符号。更新 Node 或外部 Undici 版本后应重新运行同一矩阵。
- 鸿蒙系统 CA、DNS、真实 HTTPS 访问、设备冻结后的连接状态及后台行为仍待真机核实。桌面耗时不能作为手机性能数字。

## 来源

- WHATWG Fetch：https://fetch.spec.whatwg.org/#http-redirect-fetch 与 https://fetch.spec.whatwg.org/#abort-fetch
- DOM AbortSignal：https://dom.spec.whatwg.org/#abortsignal
- Node HTTP：https://nodejs.org/docs/latest-v24.x/api/http.html
- Undici Dispatcher：https://undici.nodejs.org/api/Dispatcher （当前在线主文档会变化；本轮另核对 Node 24.22.1 内置 Undici 7.30.1 的实际 callback 形状）
- 当前原生实现依据来自已校验的官方 Node 24.22.1 发行物，仅用于审阅，未将提取的第三方源码放入此补丁。

## DSH 接入补丁与安装

`runtime/patches/ohos-network-transport.diff` 仅改变两个锁定 DSH 包的鸿蒙分支，并在 pins.json 登记精确前后哈希：

- `dsh-web-fetch-http` 保留原有 public IP、NAT64、同源重定向与读取上限检查，只把已验证地址交给原生 HTTP dispatcher；保留原来明确开启的 IPv4/IPv6 回退。
- `dsh-http-proxy` 保留 proxyForUrl、no_proxy、loopback bypass、环境发布与嵌套恢复逻辑。在鸿蒙分支用 dispatcher 工厂替换 Undici Agent/Pool/ProxyAgent 的传输，并用现有公共 setGlobalDispatcher API 安装。未配置代理也安装直连传输，使原生 WebSocket 和外部 Undici 的默认客户端能工作。
- 所有分支在普通 Android 上直接走原路径。只读源码与真实 HTTP 对照均验证过；没有进行 Android 真机验证。

下面命令在自己的验证目录执行，不能对仍在运行的用户引擎目录操作：

```bash
mkdir -p verify/base
cp runtime/locks/dsh-0.2.1-rc.4/package*.json verify/base/
(cd verify/base && npm ci)
cp -a verify/base verify/ohos
python3 runtime/lib/rtbuild.py patch-dsh --prefix verify/ohos --dsh-version 0.2.1-rc.4 --target ohos
NODE=/path/to/node-v24.22.1/bin/node \
OHOS_TEST_BASE_PREFIX="$PWD/verify/base" \
OHOS_TEST_DSH_PREFIX="$PWD/verify/ohos" \
OHOS_SIM_PRELOAD="$PWD/runtime/ohos/sim/preload.mjs" \
DSH_GO_OHOS_SIM_PLATFORM=openharmony \
bash runtime/ohos/net/test-integration.sh
```

实际结果：Android 平台分支对照（包含旧环境变量为 1）**4/4 PASS**；JIT 集成 **13/13 PASS**；O0 全限制集成 **13/13 PASS**。集成包含未打补丁/已打补丁的 Android 请求轨迹一致、OHOS 分支未被调用，真实 provider 的固定 DNS/双栈回退/私有地址拒绝、代理路由、no_proxy、嵌套恢复、HTTP CONNECT 到 HTTPS 的证书验证、默认 WebSocket、既有 EventSource、内置7和外部8的共享路由。

外部 `undici.fetch` 保留其自己的 Request/Response 类型；`network.fetch` 与全局 fetch 始终保留 Node 内置类型。不要混用两套 FormData/Request。测试没有以外部 Undici 替换全局构造器。

主动上传源仍须接收自己的取消信号：独立原生/O5a对照中，一个只产出首 chunk 后保持打开的自建 ReadableStream，在取消请求后服务器连接已关闭，但其 cancel 回调在 200 ms 观察期内均未触发。这个观察不等于证明任意源会永久泄漏，也不宣称本层能替生产者结束所有自建定时器。

`NETWORK-INVENTORY.md` 列出依赖盘点及逐类替代路径。自定义 X.509 SDK 的显式 Undici Agent 不会被默认 dispatcher 覆盖，仍需专门适配和验证；没有把它偷偷改为直连。鸿蒙真实设备与现有原生规范缺口仍然 BLOCKED。

## 独立复核后的 v3 修正

v2（补丁 SHA256 e0d1995f3056fbb0ab776cfc515f54390974d4778edec27b0c76041878b6c439）在复核中被阻断：传输错误错误地把 v8 controller.aborted 设为 true，锁定 Undici RetryAgent 因而不再重试；连续两次 controller.abort 会把 reason 改成第二次原因。两条真实本地 HTTP 回归先在 v2 上失败，再修改实现。

v3 只有显式 abort 会改变 controller 的只读 aborted/reason 状态，且保留第一次调用；网络错误继续交给 onResponseError，不伪装成调用方取消。resume 也按锁定 Undici 的语义，仅在已暂停时起效。DSH 集成新增首次连接断开、第二次恢复的真实 RetryAgent 测试，以及开连接前连续取消仍保持首 reason 的测试。复核员独立 6 项夹具在完整 O0 下通过，包括背压期间停计 bodyTimeout、正文超时关闭连接、正文自定义 reason 取消及 upgrade 拒绝后一次收尾。

此修复不消除上文的 5 个原生规范 TODO。旧 v2 文件保留供追溯，不允许把 v2 的哈希当作 v3 的审查结果。

## M3-5 回归

`M3-5.md` 记录默认 dispatcher 恢复、closed 回调及不可修改请求头三个子项的先失败证据、必要启动前提和复跑命令。请求头会独立复制并按小写归一，混合大小写 Content-Length 与实际上传字节数比较；非法或重复长度走错误回调。策略关闭后的 dispatch 返回 false，并异步单次通知 legacy/v8 handler，不再同步 throw。新的 JIT/严格 O0 header+closed 矩阵各 27/27，启动矩阵合计 18/18；本页上文的五个原生规范 TODO 未消失。
