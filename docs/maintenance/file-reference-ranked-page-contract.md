# 文件引用补全按页保留排名

每个候选仍评分一次。公开结果依次按分数、目录优先、非空查询的路径长度、原路径字符顺序排序。完全并列时先遍历的候选优先。返回原候选对象，不修改已建立的工作区索引。

当前页限额 K 是配置的正安全整数。每积累 2K 个入围项就稳定排序并保留前 K 个，后续比该页末位更差或相等的项无法进入最终页。每次再次裁剪至少要新收入 K 项，因此 N 项最多需要 O(N log(K+1)) 次比较，且不会按配置限额预分配数组。最后一次稳定排序决定返回顺序。

`file-reference-score-upper-bound.diff` 接在其后：名称和完整路径都不直接包含查询时才走子序列评分，它的得分最多 400 加目录的 25 分。页末位分数已严格高于这个上界时，候选不可能入页，直接跳过子序列查找；相等时照旧评分，保留并列比较。

设置已应用覆片的 DSH_PREFIX，运行 `node --test runtime/tests/file-reference-ranked-page.test.mjs runtime/tests/file-reference-score-upper-bound.test.mjs`。
