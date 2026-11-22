# 冷会话索引不编码未使用的事件指纹

引擎版本为 0.2.2-rc.1。补丁只删除 `dsh-session-query-sqlite/lib/index.js` 中 `observeSession` 返回值的 `fingerprint` 计算，保留头部和逐事件 `structuredClone`，保留文档构建及其错误顺序。

`_observeStable` 是这个私有函数的唯一调用者。冷记录是否更新由持久层的 `revision` 决定；`_replacePersistedSession` 使用头部、继承事件数与搜索文档，不读取指纹。live 会话另走 `observeLive`，仍计算、缓存并比较指纹。两个路径不能合并处理。

正常触发是已有会话尚未进入 SQLite 索引，或磁盘 revision 改变后的首次搜索。仓库三份已捕获的用户回复、审批恢复、取消记录合计 70 个事件，重建两种合法 Zstandard 帧布局后，真实 SQLite 冷搜索均删除 3 次指纹编码及 40,326 UTF-8 字节的哈希输入；三个命中及结果摘要一致。编码字节是实际计数，不等于 V8 分配、峰值内存或手机耗时。样本来自客户端事件捕获，帧布局为实验重建，并非原始手机磁盘文件。

实际格式目录只安装图片移出投影。它创建派生消息，可能冻结共享后代，但不改变事件的 JSON 键值、不引入环或 BigInt。正常图片决策和重复决策、越界图片、非当前目标三个错误样本，两版公开搜索结果与错误一致。保留克隆也保留合法 getter 的捕获边界，以及透明 Proxy 在原生克隆处报错的边界。

适用边界是持久层声明的 JSON 事件契约。绕过写入边界而返回 BigInt 或环的伪后端原本会在这个无用编码处失败；移除后不会因该编码失败。真实 `materializeAppendBatch` 不接受这些事件，JSONL 也不能编码它们。该差异已明确记录；本片不为契约外对象增加校验或降级路径。

公共链在 `sqlite-document-count` 之后登记，Android 与 OHOS 使用同一个唯一旧块。没有 OHOS 专属覆片再改此文件。`pins.json` 只改 targetSets，哈希由本机在两个干净完整前缀重新记录，再用另外两个干净前缀校验。现有 companion 源码钉子和 OHOS dynamic-omissions 均未引用这个 SQLite 文件。

同名测试通过实际 JSONL 写读和公开 SQLite 搜索，计数冷事件仍克隆、未使用指纹不再编码，并检查相同 revision 的复用；没有挂钟断言。完整锁定前缀、正式 SOURCE 测试和真机结果以本机代跑回执为准。
