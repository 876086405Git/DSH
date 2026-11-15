# 鸿蒙本机凭据：数据通道、显式恢复与密文仓库

五处默认存储（remote、forum、settings、provider keys、hosted links）通过
`AppSecureStorage` 选择平台。`Platform.operatingSystem == 'ohos'` 且没有显式注入
`FlutterSecureStorage` 时使用 `dsh/secrets`；其他平台和已有测试注入继续调用原
`FlutterSecureStorage`。不替换该依赖的全局 platform instance，不实现本应用没有使用的
`containsKey`、`deleteAll`、监听器或平台选项接口。

## 通道

`SecretsPlugin` 只需要 `FlutterPluginBinding.getApplicationContext()`，不使用 UIAbility。
应用注册代码应添加一个 `new SecretsPlugin()`。它处理以下请求：

| 方法 | 入参 | 成功返回 |
| --- | --- | --- |
| `read` | `{key: String}` | `String` 或 `null` |
| `write` | `{key: String, value: String}` | `null` |
| `delete` | `{key: String}` | `null`，不存在时也成功 |
| `readAll` | 无 | `Map<String, String>` |
| `recover` | `{confirmed: true}`，必须是布尔值 true | `null` |

Dart 的 `write(value: null)` 使用 `delete`，不会向原生发送空值。无效回包或原生错误是
失败，不被适配器转换成空串或空 Map。错误消息不包含键名、凭据、密文或系统路径。
插件支持 `secrets_invalid`、`secrets_unavailable`、`secrets_key_missing`、`secrets_unreadable`、`secrets_io`、`secrets_recovery_failed`
和 `cancelled`。

## 为什么使用 HUKS

官方 Asset ArkTS 合同将单项 `SECRET` 限为 1–1024 字节。这里保存 SSH 私钥、论坛密钥
JSON 和整个 hosted-links 列表，现有调用没有这一上限，不能以 Asset 接口直接替换。
实现使用公开 HUKS AES-256-GCM 和应用私有目录中的一个密文文件，不采用 OH fork 的
preferences/RSA 实现，不把密钥或明文保存到 preferences、文件名或日志。

当前仓库的 compatible/target SDK 都是 26.0.0。密钥别名固定为
`DSH.Go.Secrets.AES256.GCM.v1`，使用 CE 存储等级。生成时设置
`HUKS_TAG_KEY_OVERRIDE = false`；查询只有明确缺失代码 `12000011` 视为不存在。
IPC、不可用等其他错误不会触发替代密钥。密钥生成 API 不返回密钥材料，本实现不调用
导出或明文导入密钥接口。

## 格式和提交顺序

文件为 `<filesDir>/dsh-secrets/vault-v1.bin`。其内容是：

| 字段 | 字节数 | 含义 |
| --- | ---: | --- |
| header | 8 | `44 53 48 53 01 00 00 00`，包含格式版本 |
| nonce | 12 | 每次写入由系统 CryptoFramework 随机源重新生成 |
| ciphertext | 可变 | UTF-8 JSON 记录数组的 AES-256-GCM 密文 |
| tag | 16 | 官方显式 nonce 模式下 `outData` 的尾部认证标签 |

AAD 固定为 UTF-8 `DSH-Go private secrets vault v1`，不是空值。解密将尾部 16 字节作为
`HUKS_TAG_AE_TAG`，其余密文作为输入。HUKS 每次 update/finish 输入最多 64 KiB；输出
先在内存保留，必须等 finish 认证成功才解析 JSON 或交给调用方。使用新随机 nonce
不是数学上的永不碰撞承诺。当前仓库整体在内存处理，内存随已保存数据总量增长；
没有把 Asset 的 1024 字节限制偷偷带入应用。

一次读取必须验证整个仓库，`readAll` 不返回部分结果。只有仓库文件确实不存在才视为
首次空仓库。已经存在的文件缺密钥、格式未知、认证失败或内容损坏时，读、写、删除
都报错并保留该文件。这也防止界面先捕获读取失败后保存空列表而覆盖原密文。

同进程的所有插件/engine 实例共用串行队列。每次修改都重新读取并认证旧文件，然后
加密新内容；使用 `mkdtemp` 创建私有临时目录，循环处理真实短写、fsync 临时密文、关闭、
rename 到最终路径，再 fsync 仓库目录。队列不是跨进程锁；没有推导其他进程并发写入
的保证。

提交边界是 rename。此前的写入失败或已观察到的 engine 退役不会发布新密文；rename
完成后的目录打开、fsync 或关闭失败不会让已提交保存报错，仅在本进程首次发生时
输出固定诊断 `Credential change committed; directory durability unavailable`，不带 key、
凭据、密文、路径或原始错误。目录句柄总会尝试关闭；关闭失败不能当作已释放的证明。
普通密文文件写入、fsync、close 和 rename 失败仍返回错误，旧库不被替换。
迟到 engine 退役仍可能取消通道回包，即使文件已经更新，不能解释为回滚。
首次创建目录时没有据此宣称整个父目录链具备经断电验证的持久性。临时文件只有密文；
清理尽力收束，不承诺任意崩溃后磁盘不存在旧密文残留。

## 显式恢复入口

`secrets_unreadable` 表示已保存的密文无法验证/解析；`secrets_key_missing` 表示已有密文
但 HUKS 明确报告 alias 不存在。`secrets_unavailable` 仍表示系统密钥暂不可用，不把
IPC 等错误误认成密钥丢失。所有错误原样穿过 Dart；读取或写入失败从不自动恢复。

这两类错误（`credentialsUnreadable`）只在这些地方有出口，仅鸿蒙：

| 位置 | 看到什么 |
| --- | --- |
| 设置 › 隐私与分享 | “清除已保存的密钥”一行，只在一次探测读取报这两类错误时出现 |
| API key 页、清除 API key、SSH 主机表单 | 直接弹确认框，不再说“再试一次”；表单内容保留 |
| DSH Remote 登录、论坛登录 | 错误文案说明无法读取并指向隐私页；DSH Remote 不再当网络错误重连 |

确认框按钮是“取消”与“清除密钥”，危险色。用户确认后才调用
`CredentialRecovery.recover`（`app/lib/state/credential_recovery.dart`），它调用一次
`recover(confirmed: true)`。Dart 拒绝 false，原生独立拒绝缺参数、false、字符串或数字；
Android 和显式注入存储不提供这个 OH 恢复入口，不调用原插件的 deleteAll。确认参数是
调用协议，不代替 UI 真实的用户确认。

恢复前后都让内存持有者放手，防止旧值写回：`hostedLinksProvider`（任何改动都重写整个
列表）、`relayBackendProvider`（token 轮换写回）、`forumAuthProvider`（会话和密钥对）。
`settingsProvider` 只重读 API key 和 provider id，因为失效它会让整个应用回到启动页。
五个 store 本身没有缓存。不自动重试旧的编辑提交，也不把内存里的凭据再保存回来。

引擎自己的 `$DSH_HOME/.credentials.yaml` 不在这个密钥库里，恢复不动它：内存里有
DeepSeek key 时，`apiKey` 变空会经 `clearProviderKey` 清掉引擎那份；启动时就读不出来则
没有这一步。自定义 provider 的引擎副本同样保留。

恢复只清除固定 `dsh-secrets/vault-v1.bin` 和本服务固定 CE alias
`DSH.Go.Secrets.AES256.GCM.v1`，不读/解密旧库，不查询密钥是否可用，不递归删除目录，
不触碰其他 alias、主机配置或工作区。目录或库文件已不存在时仍执行 alias 删除，
所以「alias 存在但密钥不可用」也能恢复。公开 `huks.deleteKeyItem` 只传固定 alias 和
`HUKS_TAG_AUTH_STORAGE_LEVEL_CE`；仅 `12000011`（明确不存在）视为已经完成，权限、
IPC、硬件等错误不能吞掉。下一次显式写入才生成新的 AES256 密钥。

删除密文与删除 HUKS 密钥不能合成原子事务。先 unlink 密文，成功后再删密钥，避免
unlink 失败时先毁掉仍可解密旧库的密钥。unlink 的真实错误仍为 `secrets_io`，不开始删
alias；密文已清但 HUKS 删除失败则返回 `secrets_recovery_failed`，提示恢复未完成、
需要重试，不声称原数据完整保留或已完全恢复。重试即使库文件已无，也会继续清理 alias。
目录同步仍只降级持久性并诊断；它不会拦住后续密钥清理。

恢复与完整 load→modify→save 共用同一个静态串行队列，HUKS 删除 Promise 也在队列内。
先排入的旧 RMW 完成后才恢复，后排入的新写等待 alias 删除结束后再生成新密钥。
每个尚未派发的删除前核 engine 代际：已排队退役恢复不执行；unlink 已派发后退役可能
只清了密文；HUKS 删除已派发后退役则不能撤销该 Promise，回包会报 cancelled，新实例
可重试。两种部分完成都不能当成回滚。临时旧密文不再加载，本入口不承诺介质安全擦除。

### 恢复时要对照的内存持有者

`AppSecureStorage` 本身没有值缓存；`SecureSecretStore`、`SecureProviderKeyVault`、
`SecureHostedLinkStore`、`SecureForumStore` 都是直接读写包装，重新创建这些包装不足以
清除上层已持有的秘密。原生队列只串行化已经进入通道的操作，不能撤销稍后由旧 Dart
状态构造的 `_save`、登录回调或远端请求。下表写于 `CredentialRecovery` 之前（基于
718c06a），改恢复流程时逐项对照，现状见表后：

| 持有者/入口 | 需要失效或重新读取的内容 |
| --- | --- |
| `settingsProvider` / `SettingsController`（`state/settings_state.dart`） | `state.apiKey`、`customProviderIds`；新生命周期通过 `_load()` 从空库读回。既有 `_load` 私有，没有公开的恢复重载方法；不能把旧 state 再调用 `setApiKey` 保存。 |
| `hostedLinksProvider` / `HostedLinksController`（`share_hosted/hosted_links_state.dart`） | `links` 含分享解密 key 和删除 token；取消原实例 timers，并收束已有 `_load`、`_save`、`_commit`，新实例从空库加载。只改 loaded 标志或重建 store 不够；旧删除回调不能再把旧列表保存回来。 |
| `forumAuthProvider` / `ForumAuthController`（`forum/forum_auth.dart`） | `state.credentials` 以及私有 `_keys` RSA 对；当前 `build()` 未清 `_keys`，不能假定一次 invalidate 就清空。需要明确清字段或保证新控制器实例，同时使旧 `_restore`/授权回调失效。不要用会远端revoke的 `signOut` 冒充纯本地清理。 |
| `relayBackendProvider` / `relayAccountProvider`（`state/hosts_state.dart`、`packages/dsh_remote/.../remote_account.dart`） | 后端有 `_identity`、`_credentials`、`_pins` 与 `_credentialWrites`；关闭连接并重新创建实例，收束旧异步凭据写入。现有 `close()` 仅关闭连接/API，不证明上述写队列已停止或所有缓存已擦除。 |
| `hostLinkProvider(host)`、`remoteConnectionProvider(host)`（`state/connection_state.dart`） | 已建SSH/relay连接及正在认证的连接持有旧凭据；须关闭/失效，再从SecureSecretStore读取。SSH配置仍由 `HostsController` 的SharedPreferences加载，不能删除主机地址、用户名与配置。 |
| `readListCredentialEpochProvider.notifier.advance()`（`state/read_list_epoch.dart`） | 现有凭据变化失效入口；恢复完成需推进此代际以失效相关读取身份，但这一步不会清空上面那些独立缓存。 |

特别注意 `LocalConnectionController` 对 `settingsProvider.apiKey` 的监听：从非空变空
会调用 `client.clearProviderKey()`，同步删除引擎自己的密钥。若恢复合同只清App凭据库，
主线应先关闭/隔离这条同步链，再更新缓存，不能把本地缓存刷新意外变成引擎凭据删除。
`healProviderKeys()` 同样可能已捕获旧副本并异步回推，要收束这些在途任务。

建议入口先阻止新的凭据相关操作、关闭旧连接并等待/使旧异步任务代际失效，再执行
显式恢复；成功后保证上述持有者为新实例或有经过验证的清字段/重载路径，再开放操作。
`secrets_recovery_failed` 或迟到 `cancelled` 也可能已经清掉密文，仍需保持旧写入隔离，
不能自动重放旧提交。单纯 `ref.invalidate` 的实例复用/在途回调行为必须逐处验证；
若主线选择重新启动应用或替换整个ProviderContainer，同样要先收束旧实例的异步写入。
这些是恢复流程的验收条件，Dart 没有全局缓存清理 API。

表后现状：`CredentialRecovery` 在恢复前后都推进代际并失效 hosted links、relay 和论坛，
`ForumAuthController.build()` 已清 `_keys`，`settingsProvider` 用公开的
`reloadCredentials` 重读；SSH 和本地连接没有在恢复时关闭。`apiKey` 变空会清引擎那份，
这是上一节写明的现行选择，对话框也说了会清哪些内容。

公开文档核查（2026-11-03）：[官方 fs API 入口](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-file-fs)
经允许的 web 入口仅取得导航壳；OpenHarmony 官方 raw 文档抓取被拒。现有材料不足以
确认目标 API26 的目录 fsync 或断电保证，因此按追加17采用提交后的降级语义。
这只降低断电持久性保证，不降低普通文件完整写入与关闭要求；未在真机核实。

## 升级、删除和设备范围

普通覆盖升级复用同一 alias、算法参数和 v1 文件；不自动更换密钥或将未知版本重建为
空库。删除一条记录会重写其余记录的密文，不删除仍供其他记录使用的 HUKS 密钥。
没有从旧 fork preferences 自动迁移数据，也不宣称所有历史安装都没有遗留数据。

华为官方说明应用卸载会销毁应用 HUKS 密钥，重装后不能用新密钥解开旧密文。这个
接口合同不等于本项目已经验证设备卸载清理、物理介质擦除、系统备份恢复或断电时点。
真机确认应分别做：同 bundle/signature 覆盖升级后四方法读回；卸载重装后旧密文不能
解开；锁屏/首次解锁的 CE 行为；系统 HUKS 不可用时可读错误且已有文件不被替换。

## 可重跑检查

Node 组件入口（`OHOS_TYPESCRIPT_PREFIX` 指向已有 TypeScript 5.9.3 前缀）：

```sh
node --test --test-isolation=none --test-reporter=tap --test-timeout=15000 runtime/tests/ohos/secrets.test.mjs
node --jitless --test --test-isolation=none --test-reporter=tap --test-timeout=15000 runtime/tests/ohos/secrets.test.mjs
```

组件执行真实 ETS、真实 Linux 文件和显式 HUKS/Flutter 替身；Node AES-GCM 只验证协议和
认证失败控制流，不作为设备 HUKS 的实现证明。Dart consumer 入口是
`app/test/secrets/secure_storage_test.dart`，覆盖 OH 通道、错误传播及五默认的 Android
行为。普通 `check-arkts.sh --hms-stubs` 的最终组合结果另附实际记录；HMS 非官方桩的
限制不被本次公开 HUKS API 编译消除。

Dart consumer 是非 UI 测试，子目录 `flutter_test_config.dart` 不加载字体；
应用其他目录的视觉测试配置保持原样。依赖准备后可在 `app` 执行：

```sh
flutter test --no-pub --no-test-assets test/secrets/secure_storage_test.dart
```

OH 分支在 Linux 测试中使用适配器的显式平台测试入口；五处默认对象的原 key 和
Android 存储选择使用真实 Dart 调用核对。它不将 Linux 的 `Platform.operatingSystem`
改成设备值，也不是设备通道或 HUKS 的端到端测试。

## 官方来源

- [Asset 新增数据](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/asset-js-add.md)：SECRET 容量和持久性选项。
- [HUKS ArkTS API](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/js-apis-huks.md)：密钥生成、查询、会话和 KEY_OVERRIDE。
- [HUKS 加解密](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/huks-encryption-decryption-arkts.md)：显式 nonce 的 GCM 数据和 AE_TAG 拆分。
- [随机数](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/crypto-generate-random-number.md)：CryptoFramework 随机源。
- [卸载与升级 FAQ](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-universal-keystore-16.md)：应用密钥生命周期和升级参数边界。
