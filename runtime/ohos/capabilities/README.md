# O6：运行时能力及发布熔断的 HTTP 读取

本目录实现 O6 v1 约定中的 **GET `/dsh-go/v1/runtime-capabilities`**。第二波在已有发布熔断片段上接入实际 Cordis 执行/锁能力和纯 Dart 模型/API。没有观测依据的原生模块、后台授权仍为 null/unknown；真机验证未执行。字段来源、旧引擎兼容和 Dart 使用约定见 [capabilities-v1.md](../../../docs/design/harmonyos/capabilities-v1.md) 第八节。

## 装配

在鸿蒙专用 Cordis profile 中插入本插件，保持 M6-4 的唯一 `runtime/ohos/preload.mjs` 先于 DSH 主入口。示例中的绝对路径必须由安装后的自有目录生成：

```json
[
  {
    "insert": [
      {
        "id": "ohos-runtime-capabilities",
        "name": "file:///安装目录/runtime/ohos/capabilities/index.mjs"
      }
    ]
  }
]
```

需要同包的 `snapshot.mjs`、`publication/capabilities.mjs`、M6-3b 发布核心以及 M6-3b 原生第五个方法。会话锁的准确观测需在 `--target ohos` 下应用 `zzzzzzzzzzzz-ohos-runtime-capabilities.diff`；Android target 未选择它，其输入摘要不变。普通 Linux / Android 即使遗留旧 `DSH_GO_OHOS_SIM=1`，也不注册路由；只有实际平台 openharmony 或显式仿真 Symbol 才注册。完整鸿蒙 profile 的最终裁剪仍属 O1/O2；本项给出明确插入项，并已在真实 DSH profile 上执行。

## 鉴权与响应

请求调用现有 `connection.requestRejection(req)`，沿用 Host、Origin 与 Cookie/API 凭据判断。connection 未装配时返回503；没有因本机地址或只读属性而开放匿名读取。现有 webServer / bridge 的路由 guard 仍可先拒绝请求。HTTP 拒绝响应不含版本或能力身份。

已鉴权 GET 返回200、JSON和 `Cache-Control: no-store`。已鉴权 POST / HEAD 等其他方法返回405；HEAD 不返回正文。每次 GET 读取真实服务的当前 getter，不缓存启动时状态，不进行 syscall 探测、文件恢复、安装或状态写入。

响应字段：

| 字段 | 当前含义 |
| --- | --- |
| `v` | 1；新增可选字段不改变主版本 |
| `bootId` | 本 Node 实例首次装配本插件时生成的随机标识；同实例不变，和启动凭据、publication 是否存在无关 |
| `platform` / `arch` / `nodeVersion` | 当前进程实值；x64 仿真不报告 arm64 |
| `simulated` | 是否存在显式仿真 Symbol |
| `publication.atomic` | 当前 `untried`、`trying`、`available`、`unsupported`、`disabled-after-crash`；服务缺失、未知协议或未知状态为 `unknown` |
| `publication.systemVersion` | 经验证的系统版本元组身份；缺失/非法为 null；不是 Node 版本，也不暴露原始四字段或设备标识 |
| `shell` / `processSpawn` / `nodeScripts` / `python` | 实际 shell/subprocess 服务，命令表与执行器和工具说明同源；具有可继承预加载器的 Node 脚本后端报 worker-rebased，缺该入口报 none |
| `wasm` | 当前实例缺 WebAssembly 为 unsupported，存在对象但未经执行验证为 unknown |
| `plugins` | bundle 已实际装配的证据；OH 平台已注册纯 JS 安装后端且真实 pluginManager 服务存在时，marketInstall 为 supported，否则 unsupported。安装仍限注册表纯 JS 包，实际请求逐项验包；GET 不发现、安装或恢复插件 |
| `nativeModules` | null，宿主尚无已签名清单及逐模块实际加载观测 |
| `storage.sessionLock` | 真实 JSONL OHOS 分支的 main-thread 标记；服务缺失或不识别为 unknown |
| `background` | may-freeze / unknown / none，不外推设备授权或 O8 恢复实现 |

`available` 表示该版本已有一次真实 NOREPLACE 成功记录；新进程首次实际调用仍会重新写入 trying。`disabled-after-crash` 只表示上次尝试未记录正常完成，不等于已经证明 SIGSYS。状态详情由 M6-3b 核心文档定义。能力响应不授予操作权限；未知字段、未知枚举及未知协议的客户端兼容行为保持 O6 v1 先行约定。

## Linux 实测与范围

`publication-capabilities-http.mjs` 启动真实锁定 DSH / Cordis / connection，子进程使用完整 O0 严格预加载、正常新的原生加载器和 M6-3b publication binding。

首次执行4个场景通过：

1. 不插入本插件的同一真实 DSH，对已鉴权能力请求返回404，证明原缺口。
2. 真实 NOREPLACE 发布成功后，HTTP 从 untried 动态变为 available。
3. 明确的测试专用 native EINVAL 注入后，HTTP 变为 unsupported，实际完成非原子回退。**这不是目标设备或此 Linux 文件系统不支持 flags 的测量。**
4. 独立准备进程用真实 ledger / fuse 把 trying 持久化，在原生调用前的同步屏障被父进程实际 SIGKILL；完整 DSH 使用同一 home、同一系统版本随后启动，HTTP 返回 disabled-after-crash，实际发布走回退且 native rename 次数为0。父进程没有改写 trying 或手动设 disabled。

每个正向场景还发出无Cookie、错误Cookie、错误Origin、错误Host、POST、HEAD请求并核对拒绝；连续21次已鉴权查询前后，状态文件和账本的内容SHA、dev/ino、mtime及 native 调用计数均不变。测试只用私有父子 IPC 调用真实服务以触发状态改变，没有增加HTTP写接口。CLI 主入口实际已启动；这组是能力HTTP集成测试，**不替代 O0 五工具完整回合**。

另有4个真实 Cordis 平台门控/未就绪测试：普通 Linux 与模拟 Android 携带旧环境变量不注册，实际 openharmony 分支和显式 Symbol 分支注册后在没有connection时经真实HTTP返回503，dispose移除路由。这里的 Android 是平台分支对照，不是 Android 设备运行。

复现所需前缀使用此前已锁定并按 OHOS pins 打补丁的 DSH 依赖。外层协调器可以创建子进程，不加载 O0；其启动的 DSH 子进程才严格受限：

```sh
/绝对路径/node/bin/node runtime/tests/ohos/publication-capabilities-http.mjs \
  --tree /绝对路径/本次已整合源码 \
  --prefix /绝对路径/已锁定OHOS前缀 \
  --linked /绝对路径/libpublication-test-linked.so \
  --native-library-dir /绝对路径/含libdsh_require_builtin.so与libdsh_flock.so的目录 \
  --out /绝对路径/不存在的输出目录 \
  --base-profile /绝对路径/已验证的鸿蒙profile补丁.yml
```

`--base-profile` 需包含 O4 虚拟进程/工作区显式根等既有装配；协调器另外生成本接口的插入项。测试报告绑定输入源码、前缀入口、profile、两种原生产物和执行脚本的 SHA256，并保留各进程的实际退出结果。日志会去除临时 launch token 和会话 Cookie。

平台门控测试：设置 `M6_TEST_PREFIX` 为上述前缀，`M6_TEST_CAPABILITIES_MODULE` 为本目录 index.mjs 的绝对路径，执行 `node --jitless --test runtime/tests/ohos/publication-capabilities-route.test.mjs`，不加载仿真预载；该测试自己控制明确的门控输入。

第二波在同一四场景上增加完整 O6 字段断言，并在严格仿真下执行真实五工具回合；纯 Dart 3.11.0 模型和实际 HTTP 客户端测试也已经执行，精确结果见交付说明。`node --jitless --test --test-isolation=none runtime/tests/ohos/runtime-capabilities.test.mjs` 另检服务缺失/卸载及只读快照。目标 SDK、arm64/musl、HAP、手机挂载和真实 SIGSYS 尚未执行；Linux 的设备信息实现是明确的 `DSH-Linux-Test-*` C API 夹具。
