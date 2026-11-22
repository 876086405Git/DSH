# 子进程增量输出的尾块读取

每个 stdout 或 stderr 读取者持有自己的绝对字节游标。若多块尾缓冲的最新 Buffer 从 total − last.length 开始，且读取者已经到达该位置，所需字节完全位于这一块。readFrom 可直接按选中缓冲在整个输出中的起点取视图，然后执行既有的 UTF-8 完整性判断。

未送达的 UTF-8 前缀可能位于上一块，旧游标也可能横跨多块。在这些情况下仍通过原有拼接取得完整尾窗口。超出尾保留范围的读取继续按原规则标记 lossy。空尾、单块、原生 Uint8Array、封口、多个独立游标、spillPath 和 snapshot 的独立副本约定均保持原样。

同名测试以一个已送达的 65,536 字节窗口开头，逐次追加并读取 128 个最新块，要求增量读取拼接的输入字节数为零。已有 subprocess-utf8-cursor、subprocess-single-read 和 subprocess-zero-tail 测试覆盖跨块、封口和零容量。公共覆片排在 zzzzzzzzz-subprocess-zzzero-tail.diff 之后。OHOS 专属 ohos-output-utf8.diff 继续仅修改 push 的首块裁剪，并在公共链之后重新录制其 pin。
