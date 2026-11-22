# web_fetch 表格连续竖线保留合同（5672）

基底 `3c8637d2b1279d8b420e148bba4624cb355eb182`，DSH `0.2.2-rc.1`。

普通技术文档表格的单元格含 `<code>a || b</code>` 时，Turndown 的 inline-code 规则保留两个竖线，工具自定义 table-cell 规则却用 `/\|+/g` 将连续竖线整体替换成一个 `\|`。GFM 表格外层不恢复字符，因此返回模型的内容丢失一个竖线。这是原文数据损失，不宣称已经测出模型作答错误。

新公共片仅把该行改为 `/\|/g`，逐个转义并保留每个竖线。保留现有空白、换行、表格分隔、span 限制、HTML 深度和输出裁切规则。`ohos-web-converter-lazy.diff` 是随后碰同一文件的 OHOS 专属片；只同步其旧块和新块的同一行，使前像可匹配且 lazy converter 保留修复，不改变 lazy 策略。

已供 tool-web 原文 SHA256 `08a37554c57a8a1a98b47489cd6a0c53c43b646060bdcc94b2b211bf04c2498c` 与当前 Android 最终 pins 一致；已供完整 GFM `1.0.68` 与锁文件一致。结合官方 Turndown `v7.2.5` 源码，规则优先级及缺字路径可由源码推导。局部抽取实际生产 `renderTableCell` 的探针旧版失败、新版通过；不等于完整 SDK 实测。

同名测试从真实 DSH prefix 注册 Cordis、HTTP provider 和公开 `web_fetch`，抓取普通本地 HTTP HTML 表格并断言最终文本保留两个竖线、无截断。当前缺少完整 prefix，未运行该 SDK 测试；完整 Linux CI 和 Android/OHOS pins 重录由本机执行。未编译 Android、未运行设备或真实模型。
