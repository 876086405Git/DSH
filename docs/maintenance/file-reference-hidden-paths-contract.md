# 工作区文件补全的隐藏路径

用户在输入框输入裸文件名时，WorkspaceFileSearch 从现有工作区索引里选取候选。普通查询排除路径中任一以 ASCII 点号开头的段。根目录的 .env 和 src/.cache/item 都隐藏，src/name.test 保持可见。显式以点号开头的裸查询允许隐藏候选。排序、返回数及文件与目录优先级仍由 rankCandidates 决定。

输入中的反斜杠先归一化。空查询与含斜杠的查询继续实时读取相应目录。只有其余裸查询会进入全局索引；对这种查询，显式点号只需判断一次。路径开头为点号或含有 /. 就等价于至少一个隐藏段。排名函数仅读取索引项，在自己的结果数组中排序。

同名覆片在 Android 与 OHOS 的公共顺序中跟随 zzzzzzz-file-reference-owner-dispose.diff。完整 DSH 0.2.2-rc.1 前缀可运行同名测试及 file-reference-query-cost.test.mjs。前者同时检查首段和嵌套隐藏目录、普通文件名中的点、显式点号查询及目录分隔符，计数要求普通裸查询不再按斜杠分割索引路径。
