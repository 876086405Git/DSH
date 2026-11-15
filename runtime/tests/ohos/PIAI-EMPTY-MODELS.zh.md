# OH：直接创建空 pi-ai 模型集合

`ohos-piai-empty-models.diff` 只作用于 OH 目标的
`@deepseek-ai/dsh-llm-pi-ai/lib/index.js`。它使用已有公开窄入口
`@earendil-works/pi-ai/models.createModels`，替代原来先调用
`builtinModels(options)`、再 `clearProviders()` 的私有 helper。
依赖和完整目录的静态导入均保留，Android target 不选择这条差分。

## 为什么需要这项变化

锁定的 pi-ai 1.5.0 中，`setProvider` 与 `clearProviders` 都调用
`supersedeProviderRefresh`。旧 helper 注册全部 42 个内置 provider 后清空，
仍在 `refreshGenerations` 中留下 42 个键。实际
`LlmRuntime.registerAdapter → prepareRoutes → PiAiAdapter.providerInfo`
会创建并 memoize 这个集合。因此，配置一个内置路线时，集合还保留 41 个
未配置 provider 的状态；配置一个私有路线时，还保留 42 个无关内置键。

替换后只为当前配置建立集合状态。没有进行过 refresh 的新集合没有
controller 或 publication promise；首次配置的 generation 从 1 开始。
锁定库的发布检查比较同一集合中的当前 generation 与操作捕获值，
不依赖跨集合的绝对初始数字。旧请求继续持有原 snapshot，热更不清空它。

这是有界冗余状态和构造工作的一项减少，不是无限增长泄漏修复；未测量
对象字节、堆、RSS、PSS、CPU 或设备收益。空配置 plugin 不注册 adapter，
所以单独调用导出类的空配置测试不代表空配置 Host 自动建立了该 snapshot。
完整目录仍同步注册；此项没有延后模型目录加载。

## 有限验证入口

正式 OH 门 `piai-empty-models-plain` 与 `piai-empty-models-jitless` 各执行
`runtime/tests/ohos/piai-empty-models.test.mjs`。它们使用真实 Cordis、
LlmRuntime、pi-ai adapter、公开 volatile-ref 更新，以及仅本地 HTTP 服务；
没有修改全局 Node 内建。网络夹具通过锁定 Undici 的公开
`setGlobalDispatcher` 配置既有 OH HTTP dispatcher，退出时恢复 prior 并销毁
自己拥有的 dispatcher，验证 `fetch/Request/Response/Headers` 对象身份未变。
这是显式宿主测试网络配置，不声称执行了生产 DSH bootstrap。

7 项覆盖：真实内置路线注册、真实私有路线注册、空 plugin 目录与显式空类、
memoization 与热更旧 snapshot、构造选项身份及无提前 IO、凭据缺失/成功/异常、
已准备旧请求与当前新请求的模型/凭据/HTTP 目标隔离。Map 计数绑定当前锁定库
源码，不能外推未验证版本。热更测试直接使用 loader 所用的 `updateVolatile`
及通知，不声称执行了文件 loader 或 UI 更新。

单独复跑示例：

```sh
DSH_PREFIX=/absolute/verified-oh-prefix node --import ./runtime/tests/ohos/piai-empty-models-network.mjs --test --test-reporter=tap runtime/tests/ohos/piai-empty-models.test.mjs
DSH_PREFIX=/absolute/verified-oh-prefix node --jitless --import ./runtime/tests/ohos/piai-empty-models-network.mjs --test --test-reporter=tap runtime/tests/ohos/piai-empty-models.test.mjs
```

独立 a836 版本只增加一个 OH recipe 项；累计合并应保留已存在的其他
OH 项和全部公共项，再接上这一差分及对应 pin。35eedc 主线的公共
`piai-overflow-output-limit.diff` 修改依赖 `pi-ai/dist/utils/overflow.js`；
本项不能覆盖该差分，也不能把仅适配器同哈希称为整个主线依赖已验证。
