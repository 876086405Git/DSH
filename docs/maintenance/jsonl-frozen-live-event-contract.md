# JSONL 实时事件缓冲

Session 在发布核心事件或插件记录前完成 JSON 快照并深度冻结。JSONL 的实时监听器可在缓冲和重试期间保留同一记录。批量落盘仍通过 materializeAppendBatch 校验并复制，公开 handle.append 也继续在接受输入时取得独立快照。
