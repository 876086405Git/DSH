# O5：FormData 重放与响应体取消原因

**Linux 原生验证已经完成；精确补丁待独立复核。未编译为鸿蒙目标，未在真机核实。** 下面区分官方桌面 Node、显式源码 bundle、重新构建的 Linux Node 和主线鸿蒙 libnode；前一层通过不能代替后一层。

## 改动与已有修复的关系

基底是 `56e682bf76368074e14c4d9be02db53cc6616c4b`（追加9），归档 SHA256 `8f76055097f92fac97752baffd4f17ebea8418c08a52cd8ede4c396f037d8064`。基底的 `runtime/ohos/node/patch-undici.mjs` 已包含 O7a 的 FormData 重定向修复：把重放源保留为包含固定 multipart 边界及条目快照的 Blob。本次不改这个禁改目录，也不把已合入的 O7a 算作新成果。旧网络矩阵的两个 307/308 TODO 必须在真正采用该构建输入的 Node 上重新验证，不能仅删 TODO 后看退出码。

本次新增 `tooling/ohos/prepare-node-fetch.mjs`，在允许的工具路径组合 **完全相同的 O7a body.js 字节** 与一个新的取消原因修复。Node 24.22.1 内置 Undici 7.30.1 的 `Fetch.abort(error)` 用 `if (!error)` 选择默认 AbortError，响应已返回后，正文错误沿 controller 的 `serializedAbortReason` 传播，因此 null、0、false 等合法原因在这条路径被覆盖。唯一新增的 Undici 源码语义修改是：

```diff
-    if (!error) {
+    if (error === undefined) {
```

DOM 的 abort 约定只对未提供的原因采用默认 AbortError；Fetch 的 controller 和正文错误路径保留调用方给定的原因。本次按这两条规范修正此分支，不宣称完整 Fetch 合规。来源：[DOM AbortController](https://dom.spec.whatwg.org/#dom-abortcontroller-abort)、[Fetch controller abort](https://fetch.spec.whatwg.org/#fetch-controller-abort)、[abort fetch](https://fetch.spec.whatwg.org/#abort-fetch)，读取日期 2026-11-02。具体实现来源是下表 SHA 锁定的官方 Node 源码，而不是在线文档中随时可能变化的实现。

未更改生产 dispatcher、fetch 包装器、全局构造器身份或 Node 内建模块。本工具只对显式 `--target ohos` 的独立 Node 构建源码运行；Android 入口、版本串、锁文件和 pins 均不变。新增测试允许显式载入某个 bundle 作为被测对象，未替换全局 Fetch 类。

## 固定输入与输出

| 输入或产物 | 版本或 SHA256 |
| --- | --- |
| 官方 Node 源码 | 24.22.1；[node-v24.22.1.tar.xz](https://nodejs.org/dist/v24.22.1/node-v24.22.1.tar.xz) |
| 官方源码归档 SHA256 | `4f5379796280cdaeb0c2f358fd04b6a16cc4fb7dfa83b5a8c91a9d963b435231` |
| 校验来源 | [官方 SHASUMS256.txt](https://nodejs.org/dist/v24.22.1/SHASUMS256.txt) |
| 内置 Undici | 7.30.1 |
| 构建依赖 | 已批准并锁定的 esbuild 0.27.3，MIT；使用已有 `runtime/ohos/node/build-tools/package-lock.json`，不新增依赖 |
| 原 body.js | `fd7e1fe68e263f3296ecf0f4f799b3099717ecd8c9626db9bab73b7a4db7eb7d` |
| 原 index.js | `2cf8903bb2c17d83794edbd800adac4e8077cf9a21d315acf812d2f614e24bd6` |
| 原内置 bundle | `50a6f643f00499ef75c5a36a0a610e7db4f5fbb0a2093ad4942b46fc797f7e26` |
| 已合入 O7a body.js，组合后保持相同 | `3e57dbca4505d41f0eff63be2d7c631bb4bd0dce8562b4d098e38d1c10281eb7` |
| 仅 O7a 的 bundle | `2c28f6f03b582ab4b4fb5db594386a50041c28f9050fe5c70b9a8e4422fe2b22` |
| 新 index.js | `26701b1c1fd7a2b1240476165fde7661071da4d8ffba1e4624d7b9904cd14fd8` |
| 两项修复组合后的内置 bundle | `db17946f41981758f1d4328836360fe3d62818b12b73eb12a7198b39e2e61630` |

脚本先重建当前源码的完整 bundle 并核对固定哈希，再改两处源叶子与 bundle。这样不仅核对两个叶子，也拒绝会改变 bundle 的传递源码漂移。接受官方原树、原 O7a 后的树、已经组合修复的树，以及这些已知源码/已知 bundle 的中途写入不一致；未知输入拒绝。重复运行输出字节相同。单文件用临时文件与 rename 替换；这不是三文件跨断电原子事务，遇到未知不一致应恢复已校验原源码再重跑。

## 主线接入要求

本补丁不改主线正在重写的 `runtime/ohos/node/`。主线需将原来的 O7a preparation 调用 **替换成** 新工具调用：

```bash
# 在独立构建依赖目录使用基底已有、锁定的 esbuild 配方。
mkdir -p /path/to/build-tools
cp runtime/ohos/node/build-tools/package.json /path/to/build-tools/
cp runtime/ohos/node/build-tools/package-lock.json /path/to/build-tools/
npm ci --prefix /path/to/build-tools

node tooling/ohos/prepare-node-fetch.mjs \
  --target ohos \
  --build-tools /path/to/build-tools \
  /path/to/node-v24.22.1-source
```

不能在每次构建中先调用原 O7a 工具再追加新工具：第一次可组合成功，但原 O7a 工具的允许 bundle 集合不含新 bundle，第二次会拒绝。新工具已包含完全相同的 O7a 变换，所以替换调用后只需一个准备入口。对 Node 升级或其他 Undici 补丁必须重新核对来源、哈希与同一网络矩阵，不放宽白名单蒙混通过。

主线继续负责 N-API 改名头、clang/libc++、目标架构、libnode 链接和 HAP；本工具处理的是嵌入的 JavaScript 输入，与这些 ABI 工作相互独立。仍须在实际 libnode 构建产物上验收五项原 TODO。

## 现有执行证据

以下均为实际执行记录。Linux 原生二进制由上述固定官方源与组合 bundle 构建，没有用环境变量载入外部 Undici bundle。

| 被测对象与范围 | 修复前 | 修复后 |
| --- | --- | --- |
| 官方未修 Node 内置 Fetch，取消旧矩阵中 5 个 TODO 标记后的原断言 | 0/5，通过数为零；307/308 与 null/0/false 均真实失败 | 新原生二进制同一完整网络矩阵 41/41，包含原5项；严格模式亦41/41 |
| O7a 源 bundle，真实 HTTP 响应体取消扩展矩阵 | 7/24 通过，17 失败 | 组合 bundle 24/24 通过 |
| 组合 bundle，严格仿真下取消 24 项 + 已有 FormData 9 项 | 不适用 | 33/33 通过 |
| 构建输入门 | 不适用 | 9/9 通过 |
| 新 Linux 原生二进制，取消24项 + FormData9项，生产 HTTP 引导 | 裸 Linux 无引导时8个HTTP FormData失败，详见下文 | 显式OH激活33/33；严格仿真33/33；均无skip/TODO |

取消测试先收到真实 HTTP 响应/首数据，再令读取处于 pending；分别测 reader、text 消费和 clone 双分支，并等待实际连接关闭。原因覆盖 null、0、false、空串、负零、NaN、0n、对象、Error 与默认 undefined；用 `Object.is` 判断原因，避免深相等掩盖值或身份变化。消费完成再取消不改写已完成结果。

构建门覆盖：官方原输入、原 O7a 输入、重复运行、Node 版本漂移、叶子源码漂移、bundle 漂移、传递源码漂移、非 ohos 目标/空目标、错误 esbuild 版本及已知中途状态恢复。九个 test 中有子循环，不把每个分支虚增为单独测试数。

已有 FormData 9 项保留 307/308、301/302 PUT、空表单、请求构造后修改原 FormData、Request clone、303 丢弃正文、文件 Blob 惰性行为。128 MiB 稀疏文件测试只测重放源构造与文件句柄语义，**不测完整上传的内存峰值**。正文来自真实 HTTP；最后一项直接读取精确源树的 extractBody，报告中单独标明。

严格仿真使用已有测试 preload：jitless、无 wasm、禁 child_process 和动态 addon 等。它用于暴露受限运行路径，不是鸿蒙系统仿真器。Linux 的 CA、DNS、文件打开和调度行为不能替代手机。

## Linux 原生构建与引导边界

构建实际使用 GCC 13、`make -j4`，配置为 `--without-npm --without-corepack --without-inspector --without-intl --v8-lite-mode --without-node-snapshot`。这是 Linux x64 验证二进制，不是鸿蒙 ABI 或主线 libnode 链接产物。构建日志、完整命令、源准备输出与 `config.gypi` 随包保存。

- 原生二进制：74,215,504字节，SHA256 `d8c84738f4e3c5c5ce68c39501a887ccf5df1412938193b5a53583b45e44e48a`。
- `config.gypi` SHA256 `d3978dded3bf3ed9e40c66b9a6509d57edfdbb3e2c7ba85348022e22dec6a174`。
- 从该二进制的 `process.binding('natives')['internal/deps/undici/undici']` 读回768,798字节，SHA256 **正是** `db17946f41981758f1d4328836360fe3d62818b12b73eb12a7198b39e2e61630`；不是只核磁盘上的外部 bundle。
- 真实运行报告 Node24.22.1、Undici7.30.1、V8 lite=1、`typeof WebAssembly === 'undefined'`；`DSH_GO_UNDICI_BUNDLE`、`NODE_OPTIONS`、`NODE_PATH` 均未设置。

第一次扩展矩阵使用裸 Linux 默认 Fetch，24个取消测试通过，但8个 FormData HTTP 测试失败；第二次仅加载网络 preload 仍相同。最小本地 GET 因果探针实得 `TypeError: fetch failed`，cause 是 `ReferenceError: WebAssembly is not defined`。源码表明 `installFetch()` 只在真实 `process.platform === 'openharmony'` 或显式测试 marker 下激活，Linux 单独 import 网络 preload 不生效。这两轮失败全部保留，不删除或淡化。

正确的 Linux 验证入口先显式加载 `runtime/ohos/sim/marker.mjs`，再加载原生产 `runtime/ohos/net/preload.mjs`；严格模式使用原 `sim/preload.mjs` 加同一网络 preload。它们使用内置 Fetch 和现有生产 HTTP dispatcher，未载入源码 Fetch bundle、未更改生产平台判断、未新增环境开关。完整41项网络矩阵本身明确构造生产dispatcher；取消24项也明确构造dispatcher。FormData8项真实HTTP使用经过上述引导的global Fetch。第9项惰性Blob仍是精确源叶子检查，不能把它冒称全部来自二进制。

因此本次结论是：**固定原生二进制 + 生产 HTTP dispatcher 的五项旧失败及扩展矩阵闭合**。没有宣称未启用OH网络层的默认Undici客户端可以在无Wasm下联网。

## 尚待主线和设备验收

1. 独立只审复核绑定最终补丁 SHA256；任何修改后重新绑定。
2. 主线将旧准备调用替换为新入口并编出鸿蒙 libnode，重新核嵌入 bundle 与原五项失败断言。
3. 手机 TLS/系统 CA、冻结期间网络、后台限制、目标ABI及真实HAP仍未验证。Linux结果不撤销其他专项文档中的设备与SDK边界。
