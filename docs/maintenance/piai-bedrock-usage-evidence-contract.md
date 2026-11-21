# Bedrock Converse 缓存用量证据

## 触发条件

用户使用 pi-ai 的 Amazon Bedrock Converse 路由，正常完成一次带缓存读或写用量的
模型调用。当前固定版 pi-ai 1.5.0 将含 `metadata.usage` 的 AWS 原始事件传给
`onProviderStreamEvent`，同时在 `handleMetadata` 中保存普通输入、输出、缓存读和
缓存写。DSH 的 `observedPiUsage` 原来没有识别这层形状；`mapUsage` 只从归一化值
回退非零的普通输入及输出。桥接优先使用 `reported`，因此虽然旧数值字段仍有缓存，
统计输入累计没有加上它。

例如合成的正常终态报告普通输入 23、输出 7、缓存读 4096、缓存写 0：修复前
`reported` 只有输入 23、输出 7，桥接输入累计为 23；修复后为 4119，缓存读为
4096。缓存写 4096 的同类响应也有相同漏计。

## 提供方契约与修复范围

[AWS prompt caching 文档](https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-caching.html)
在 Converse 响应说明中明确：普通 `inputTokens` 不含缓存读、写；总输入等于这三项
之和。[TokenUsage 文档](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_TokenUsage.html)
将两个缓存字段列为可选字段。

新增 `piai-bedrock-usage-evidence.diff`，在既有 `observedPiUsage` 中把
`metadata.usage` 的四个实际字段交给现有 `field()`：`inputTokens`、`outputTokens`、
`cacheReadInputTokens`、`cacheWriteInputTokens`。明确的 0 保留为 0，未报的可选
字段继续缺失；不从 SDK 初始化的 0 补证据，不从 `totalTokens` 或 `cacheDetails`
重复计数。SDK 的归一化用量、现有 UI 使用的数值、请求参数与桥接统计规则不变。

固定输入为 `@earendil-works/pi-ai@1.5.0`：

- `dist/api/bedrock-converse-stream.js`，54796 字节，SHA256
  `3f908ff6e6c67fac3681199140ac0117bbd465f2a8f736acc3a4466d5227a213`。
- `dist/api/simple-options.js`，3508 字节，SHA256
  `ff234becff46a6c25c1e437c86d72fbe7aeb4e107266d1bf6951622d223b0ae0`。

`streamSimple` 经 `buildBaseOptions` 保留钩子；`stream` 在处理每个 AWS modeled
event 前调用它，随后 `handleMetadata` 更新归一化值，结束事件再由 DSH 映射。
因此读取的是 SDK 生产路径实际提供的原始形状。

## 登记与验证

公共片在 `series`、`targetSets.android`、`targetSets.ohos` 中接在
`piai-tool-call-id.diff` 后，保持 Android 链为 OHOS 前缀。
`ohos-attachment-diagnostic.diff`、`ohos-piai-empty-models.diff`
和 `ohos-piai-text-preabort.diff` 也修改同一适配器文件，须随链由本机重录 pins。

同名测试使用完整安装前缀中真实公开的 DSH adapter、Bedrock `streamSimple`、
`buildBaseOptions`、流组装器以及仓库 bridge。只替换 AWS SDK `send()` 的返回值，
输入缓存读、缓存写、可选缓存字段缺失三组 modeled event，检查实际 `reported`
与桥接计数。这不验证 AWS HTTP 帧解码、真实账号缓存命中或账单，也不重测未改变的
异常、取消及持久化分支。

```bash
DSH_TEST_PREFIX=/path/to/prefix node --test runtime/tests/piai-bedrock-usage-evidence.test.mjs
```

前缀必须是 DSH `0.2.2-rc.1` 经 `rtbuild.py patch-dsh --target android` 应用完整链
所得。没有前缀时明确 skip，不能记为通过；pins 和完整 Linux CI 由本机重录及代跑。
