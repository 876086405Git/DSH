# 私有 Linux 作业代理

本接口只管理当前 Node 服务通过 `LinuxControl.runPrivateGuest` 接收的私有客体作业。它不改变所有插件的路由，也不改变 App 下载器、安装归档下载或整个客体的全局配置。现有 App 没有专用代理偏好持久化字段；未显式设置时，`inherit` 读取既有 `dsh-subprocess.scrubbedParentEnv()` 与 `dsh-http-proxy.proxyEnvironmentForChild()` 的实际父环境／活动策略。普通 App 启动未传入代理环境时，不能把这个来源描述为“已经配置的用户代理”。

## App 数据接口

现有 `dsh/runtime` MethodChannel 新增 `setLinuxProxy`，参数为 `{proxy: configuration}`。Dart 提供 `OhosLinuxProxyConfiguration.inherit()`、`.direct()`、`.manual(httpProxy:, httpsProxy:, noProxy:)` 和 `OhosLinuxRuntime.setProxy()`。ArkTS 从现有 NativeHost 取得控制地址与 token，不接受调用方自选宿主控制地址。控制 HTTP 本身保持 `usingProxy: false`。

配置只在本次 Node／App 引擎会话内有效。引擎重启后回到 `inherit`、revision 0；UI／调用方若要延续用户选择，需重新提供配置。本补丁不新增磁盘保存、明文密码文件、Flutter UI 或系统代理设置。

鉴权后的现有 `POST /dsh-go/v1/linux` 接收：

```json
{"v":1,"instanceId":"当前 GET 的服务身份","attemptId":null,"action":"setProxy","proxy":{"mode":"direct"}}
```

`attemptId` 使用当前 GET 的原值，可能为字符串或 null。`inherit`、`direct` 只允许 `mode`；`manual` 另允许字符串 `httpProxy`、`httpsProxy`、`noProxy`，每项最多 4096 UTF-8 字节。至少一个代理 URL 非空；未提供 HTTPS 目的地代理时沿用 HTTP 目的地代理。成功是 HTTP 202 与当前状态，同一规范化配置不递增版本。设置可发生在已有作业运行时，只影响随后新接收的 requestId。

| 模式 | 新作业的环境 |
| --- | --- |
| `inherit` | 读取既有活动策略／父代理环境，保留调用方显式 env 的既有优先级；合并国内直连名单。 |
| `direct` | 显式删除 HTTP(S)、ALL、NO_PROXY 的大小写别名与 `NODE_USE_ENV_PROXY`，防止后端重新继承旧代理。 |
| `manual` | 先清除旧代理别名，按新配置一致写入大小写 HTTP(S)/NO_PROXY；不留下 ALL_PROXY 回退。 |

`manual` 与 `direct` 下，作业 `env` 若同时显式提供上述任一代理键，返回 `ERR_OHOS_LINUX_PROXY_ENV_CONFLICT`，不会暗中选择一方。`inherit` 保留显式作业环境的地址语义，不把调用方刻意写入的客体 loopback 值重新解释为 App 地址。

新作业先按原始请求内容处理 requestId 去重，再冻结当次有效代理环境与 `proxyRevision`。因此一次已接受的请求，即使随后更改配置，使用同 requestId、同原参数重试仍返回原作业；不会再执行，也不会被新策略冲突校验改判。

`proxyRevision` 是本控制器配置修订号。`inherit` 的外部活动策略／父环境可以在两次新请求之间变化而不触发 `setProxy`，此时修订号不变；不能仅凭两个作业的修订号相同断言其有效代理环境完全一致。

## 地址与国内直连边界

固定 TinyEMU IPv4 usernet 的 `10.0.2.2` 会连接宿主 `127.0.0.1` 相同端口。继承的 App HTTP 代理与 manual HTTP 代理若正规化后为 `localhost` 或 `127.0.0.1`，转为 `10.0.2.2`。其余 `127/8`、`::1` 明确拒绝，避免把原监听地址悄悄改成另一端。HTTPS loopback 代理也拒绝：改主机名会改变 TLS 名称验证，不能通过关闭证书验证解决。远端 HTTP(S) 代理地址保持原主机名。

`NO_PROXY` 与 `no_proxy` 保留原有／显式条目并包含 `localhost,127.0.0.1,::1,[::1],gitee.com,.gitee.com,huaweicloud.com,.huaweicloud.com`。已有整值 `*` 保持为 `*`，避免破坏 Python 等客户端的通配语义。具体工具如何匹配域名必须由实际客户端对照确认，字符串包含不等于网络已绕过代理。

“HTTPS 目的地经 HTTP 代理 CONNECT”与“代理服务器 URL 自身为 `https://`，先对代理进行 TLS”是两种传输。配置层接受 HTTP(S) URL不证明每个客户端都支持两者；本次配置窄门只验证接线、地址与环境契约，真实 Git／gh／客体网络和手机运行结果应另列。测试不得关闭 TLS 校验，也不据此新增产品证书配置接口。

## 公开状态与错误

GET 的 `proxy` 恰含 `source: inherit|direct|manual`、非负安全整数 `revision`、布尔 `httpConfigured`、`httpsConfigured`。作业含接收时固定的非负安全整数 `proxyRevision`。状态与配置错误不投影配置 URL、userinfo、密码、NO_PROXY 原串、env 或 argv；ArkTS/Dart 拒绝 proxy 状态中的额外私有字段。

这不改变 stdout/stderr 的原始字节契约。作业自己可以打印任意内容，因此不能把整个 GET 或输出文件描述为“永不含敏感信息”。代理验收器必须省略可能包含凭据的原始请求／start.env／响应输出，仅保存明确允许的安全事实。

配置错误使用固定通用消息和 `ERR_OHOS_LINUX_PROXY_CONFIG`、`ERR_OHOS_LINUX_PROXY_URL`、`ERR_OHOS_LINUX_PROXY_ADDRESS`、`ERR_OHOS_LINUX_PROXY_ENV_CONFLICT`、`ERR_OHOS_LINUX_PROXY_REVISION`（HTTP 400）；不拼接原 URL 或底层异常。既有 stale、closed、请求重复等生命周期错误保留原语义。

## 已登记的定向验证

`linux-proxy-control.test.mjs` 执行生产 control/owner/backend 和真实 TCP 客体协议边界，native/guest 收尾由明确夹具应答；`linux-proxy-policy.test.mjs` 调用实际锁定公共代理安装 API，覆盖无活动配置时 direct 清别名、活动策略继承和 URL 正规化。它们分别加入 `linux-app-control-{plain,strict}` 与 `linux-proxy-policy-{plain,strict}` 窄门。

既有 `linux-control.test.mjs`、`runtime-channel.test.mjs` 执行生产 ArkTS 方法体并替换不可用平台边界；`linux-runtime-dart.py` 执行生产 Dart 模型与 MethodChannel 消费代码。它们不替代 HarmonyOS SDK 编译、真实 Flutter 引擎或手机 HTTP 代理验证。
