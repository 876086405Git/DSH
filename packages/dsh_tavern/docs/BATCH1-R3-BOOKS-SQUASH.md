# Batch1-r3：独立世界书与条件标签

本组件相对 owner 指定的 `54e79e30b`，仅处理 ADDENDUM-06 #2 与 ADDENDUM-07 #5。
父 Tavern tree 为 `fe070322e8c4c6988d0fc39c6c51cc39b15e008e`；未带入后续 Helper、图片、Entry 或 formatter 候选。

## #2：目录不可读的独立世界书

问题成立。基底 `engine_script_book_directory.dart` 的 `_bookDirectoryEntriesFailure` 已要求 `entries` 为 object 或 array；目录因此将不合条件的文件标为 `readable=false`。
基底 `_loadBooks` 统一加载五类 source 列表、角色 additional/primary 与 persona additional，却没有检查这项资格，最终 `WorldInfoBook` 抛出 FormatException，阻断生成。

修复位于仅供 `_loadBooks` 使用的 `_readBookSnapshot`，保持同一 book queue：

- 已被目录观测为不可读的独立书返回缺失；既有 `bookId/source/reason:missing` 诊断仍进入真实 turn inspection。
- 尚未枚举目录时，对已读取的 raw 使用同一个 entries 容器资格判断，显式 primary 也经过这个入口。
- 原始读取、编辑、导出和修复不经过这项筛选；原绑定列表保留。有效修复发布后目录重新可读，后续真实生成恢复扫描。

没有增加 catch-all，也没有更改嵌入书。冷目录且文件本身不是合法 JSON/object 时，原解析错误仍保留；本项覆盖的是**已观测不可读**和**非法 entries 容器**，不是承诺把所有未观测的文件故障都当作不存在。
entries 容器内部的无效条目也保留原编译诊断，不借此扩大静默跳过范围。

`w11_batch1_r3_books_test.dart` 用真实引擎、SQLite、公共绑定 API 与生产 HTTP 编解码覆盖 12 项：五类 source、chat override、角色/人设 additional、显式 primary、冷 primary、已观测坏 JSON/root、修复恢复。
原产品 12 项均失败，错误包括 `invalidCard: turn_failed (FormatException)`；修复后 12 项通过，并验证可读书仍进入实际 wire、缺失诊断落入 inspection、raw 仍可读取和修复。

## #5：条件标签仍作用于 tool content

固定 [SPreset 53bd 的 consumeConditionalTag](https://github.com/starowo/starowo.github.io/blob/53bd585da14248ba10baaede7fc7ed0cebe1eeeb/regex_bind/inject.js#L4185) 遍历每个有 content 的 prompt；递归删除 content 中字符串、数组和 object 值里的目标 tag，没有 role=tool 例外。
[生成处理器](https://github.com/starowo/starowo.github.io/blob/53bd585da14248ba10baaede7fc7ed0cebe1eeeb/regex_bind/inject.js#L4110) 在调用 squashPrompts 前运行该步骤。
因此 `conditional_enabled=true`、tag=`<yes>` 时，tool 结果 `value<yes>` 变为 `value` 是上游行为；本组件**不修改 squash 产品逻辑**。

这和 batch1-r2 的 follow 工具边界修正是不同阶段：后者按 owner 明示保留进入该分支时的 tool ID/附加字段，不撤销前面已经按源执行的条件 tag 消费。
只对 content 递归；消息的 tool_call_id、signature 和对象键名没有因此改写。

`w11_batch1_r3_squash_test.dart` 对照五个实际源码向量：开启、关闭、未命中、空 tag、嵌套 parts；新增前后均通过。
源 oracle 抽取真实 handler 与 consume 函数，在下游 squash 边界观察已变更的输入；没有用完整源 follow 输出声称 tool 关联全等价。

```sh
node tool/st_differential/spreset-conditional-tag-oracle.cjs /path/to/pinned/regex_bind/inject.js
```

ADDENDUM-10 已纠正整文件 pin：固定提交的原始文件为 290243 字节，Git blob 为 `efb49a4c8e7a713ada65116f8959183f7d1dd7a5`。源 SHA256 为 `4858bcb57530e3ff6ef68f0c94a4d291e2914c766c274f888e9a2fdf8d0efb59`，oracle 输出须与 `test/fixtures/w11_spreset_conditional_source.json` 逐字节一致。旧本地副本比 Git 原件多一个末尾 LF；这次只改源身份与复现入口，没有改产品逻辑或五个向量。取源、另外三个 oracle 与历史边界见 [SPreset 原始源 pin](../tool/st_differential/SPRESET-SOURCE-PIN.md)。

## 门禁边界

新增 17 项和既有 book directory/bindings/identity、r2 protocol 回归合计 37 项通过；全 lib 与两新测试 fatal-infos 为零，三 Dart 文件格式检查无变化。
这是本组件定向验证，未代替根累计 full suite，也没有 App/Flutter/WebView 断言。窗口修复及 ADD06/07 的其余四项由其它独立组件提供。
