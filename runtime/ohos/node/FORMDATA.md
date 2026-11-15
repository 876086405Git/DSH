# O7a：Node 24.22.1 内置 FormData 的重定向重放

## 结论与适用范围

官方 Node 24.22.1 内置 Undici 7.30.1 有可复现的 multipart 问题：307 / 308 重定向重新编码 `FormData`，生成另一条 boundary，却保留第一次的 `Content-Type`。因此第二跳的请求头和实体分隔符不一致。保持请求体的 PUT 301 / 302 也走同一条路径。O5 的 HTTP 传输不能修正其上层已经生成的错误字节。

本补丁**只作为鸿蒙专用 Node 构建的输入**。它不修改 Android 运行时、已有 Node 二进制、全局 `Request` / `Response` / `Headers` / `FormData` 构造器或它们的原型。它也没有把整个上传体先读到内存。修复在固定版本的 Undici 源码中，把 `body.source` 从原始 `FormData` 改为保存已选 boundary 和已取样条目的 `Blob(blobParts)`；第一次上传的生成器保持不变，后续重放从同一份序列化来源读取。

**本次未重编 Node C++ 共享库，未在手机执行。** 已通过的是精确 JavaScript 源码 → 官方构建规则再生成 bundle → 本地真实 HTTP 服务器/O0 仿真这一条链。当前官方 Node 的内置版本仍有这个缺陷；不能把加载了本地候选 bundle 的测试写成已发布 Node 二进制修复。

## 证据链

权威输入为 [Node v24.22.1 的 body.js](https://github.com/nodejs/node/blob/v24.22.1/deps/undici/src/lib/web/fetch/body.js)，其 FormData 分支约 159 行保存 `source = object`；[内置 bundle](https://github.com/nodejs/node/blob/v24.22.1/deps/undici/undici.js) 的重定向代码约 13619 行使用 `safelyExtractBody(request.body.source)` 再提取，未重新设置请求体头。

构建按 [该固定版本 package.json](https://github.com/nodejs/node/blob/v24.22.1/deps/undici/src/package.json) 的 `build:node` 和 `scripts/strip-comments.js` 执行。esbuild 固定为 **0.27.3，MIT**，npm 完整性在 `build-tools/package-lock.json` 中；Undici 为 **7.30.1，MIT**，沿用 Node 所带源码和许可证，没有新增运行时依赖。

| 对象 | 修改前 SHA256 | 修改后 SHA256 |
| --- | --- | --- |
| `deps/undici/src/lib/web/fetch/body.js` | `fd7e1fe68e263f3296ecf0f4f799b3099717ecd8c9626db9bab73b7a4db7eb7d` | `3e57dbca4505d41f0eff63be2d7c631bb4bd0dce8562b4d098e38d1c10281eb7` |
| `deps/undici/undici.js` | `50a6f643f00499ef75c5a36a0a610e7db4f5fbb0a2093ad4942b46fc797f7e26` | `2c28f6f03b582ab4b4fb5db594386a50041c28f9050fe5c70b9a8e4422fe2b22` |

未修改源码经 esbuild 0.27.3 再生成，得到 **768775 字节、与官方内置 bundle 完全相同的哈希**。修改后为 768788 字节。`patch-undici.mjs` 先重建并核验原始 bundle，再原子替换源码、重建并核验修复产物；有任何版本或哈希偏离都失败。生成失败会恢复它刚修改的源码。生成物不放入仓库补丁。

[Fetch 的 HTTP-redirect fetch](https://fetch.spec.whatwg.org/#http-redirect-fetch) 要求保留请求体时由其 source 再提取；[RFC 7578 §4.1](https://www.rfc-editor.org/rfc/rfc7578#section-4.1) 要求实体分隔符对应 Content-Type 中的 boundary。本实现用内部 Blob 表示可重放的序列化来源，没有改变可见的 FormData 条目 API。重定向期间即使调用方修改原 FormData，已创建的请求仍使用其原来的条目取样和边界。

## File 的惰性与内存证据

[Node 的 `lib/internal/blob.js`](https://github.com/nodejs/node/blob/v24.22.1/lib/internal/blob.js) 中，`getSource` 遇到现有 Blob 时返回其大小和内部 handle；[Node 的 `src/node_blob.cc`](https://github.com/nodejs/node/blob/v24.22.1/src/node_blob.cc) 中 `Blob::New` 遇到已有 Blob 时创建引用原 `data_queue_` 的条目。因此包装 File / 文件支持的 Blob 不需要先把其完整数据读出来。字符串及 boundary 的 Uint8Array 则需要小额或与文本大小相称的复制。

测试用 `fs.openAsBlob` 包装 **128 MiB 的真实稀疏文件**，构造重放 source 后改变底层文件的时间戳，再从 source 中的文件区间读取，得到 `NotReadableError`。这证明该区间仍依赖文件支持的惰性 handle，而不是已缓存的 128 MiB 数据。在一次 JIT 和一次 O0 运行中，该构造步骤的实测 RSS 增量为 0，ArrayBuffers 增量为 370 字节；生成器整体验证的另一轮 RSS 增量为 131072 字节、ArrayBuffers 仍为 370 字节。这些是单次测量，不是所有环境的固定上界。

该测量刻意隔离了重放 source 的构造：暂时让第一次上传的 File.stream 返回空流，避免未修改的上游第一跳生产器参与测量。**它不能证明整个生产上传的峰值内存有界，也不能替代大附件端到端压力测试。** 真实网络回归另行使用未替换 stream 的普通 File。

## 已执行的测试

`runtime/tests/ohos/node-formdata.test.mjs` 的 9 项测试包括 POST 307 / 308、PUT 301 / 302、空 FormData、创建 Request 后修改原表单、Request.clone、303 丢弃请求体的对照，以及上述文件支持的 Blob。

| 配置 | 通过 | 失败 | skip / todo |
| --- | ---: | ---: | ---: |
| 官方未修改 bundle 与原始源码 | 1 | 8 | 0 / 0 |
| 修复源码的官方规则再生成 bundle，JIT | 9 | 0 | 0 / 0 |
| 同一候选 bundle，O0 `--jitless` + O5 HTTP dispatcher | 9 | 0 | 0 / 0 |
| 实际 `patch-undici.mjs` 生成器产物，再跑 O0 | 9 | 0 | 0 / 0 |

还验证了生成器重复运行保持精确哈希，以及篡改 body.js 后在修改任何输入之前拒绝。独立审阅结论以随包报告绑定的 SHA256 为准。

## 重现与本机构建

使用 Node 24.22.1，在 **独立的鸿蒙 Node 源码构建目录** 执行：

```sh
npm ci --ignore-scripts --no-audit --no-fund --prefix runtime/ohos/node/build-tools
node runtime/ohos/node/patch-undici.mjs /absolute/node-v24.22.1-ohos-source

DSH_GO_UNDICI_BUNDLE=/absolute/node-v24.22.1-ohos-source/deps/undici/undici.js \
DSH_GO_UNDICI_SOURCE=/absolute/node-v24.22.1-ohos-source/deps/undici/src \
node --test runtime/tests/ohos/node-formdata.test.mjs

DSH_GO_OHOS_SIM=1 DSH_GO_OHOS_SIM_PLATFORM=openharmony \
DSH_GO_UNDICI_BUNDLE=/absolute/node-v24.22.1-ohos-source/deps/undici/undici.js \
DSH_GO_UNDICI_SOURCE=/absolute/node-v24.22.1-ohos-source/deps/undici/src \
DSH_GO_HTTP_DISPATCHER=/absolute/repository/runtime/ohos/net/dispatcher.mjs \
node --jitless --import ./runtime/ohos/sim/preload.mjs --test --test-isolation=none \
  runtime/tests/ohos/node-formdata.test.mjs
```

最后一条需要另行应用 O0/O5 的独立包；本包不复制它们。补丁中 `undici-formdata.diff` 用于人工审阅源码变化，`patch-undici.mjs` 是带前后哈希核验的实际生成入口。对最终重编后的 Node，去掉 `DSH_GO_UNDICI_BUNDLE`，使测试使用真正内置 Fetch，再执行同样的真实网络回归；手机必须通过签名宿主进入测试，不能把共享库当可执行文件启动。
