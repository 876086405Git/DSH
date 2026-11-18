# OH 私有挂载文件系统的符号链接目标

OH 的 shell 工作区与临时目录作为独立 ReadWriteFs 挂载到 MountableFs。`ln -s` 的目标使用外层虚拟路径，不能将它直接交给以单个挂载根为 `/` 的子文件系统。过去同工作区内的绝对目标会被重复拼接根目录，`ln` 返回成功但随后的 `cat` 找不到文件。

本项仅由 `bash-src/rewrite.py` 变换固定 just-bash 3.6.0 发布字节。MountableFs 同时定位目标与链接位置：同一挂载内的绝对目标转为该挂载内的绝对路径；相对目标仍按链接父目录解释。ReadWriteFs 继续创建真实绝对链接，并在既有目标解析安全检查通过后返回其绝对首跳；MountableFs 将该绝对返回值还原为外层挂载路径。`readlink` 不把这个绝对首跳替换成链末端。尚不存在的同挂载目标仍可创建为悬空链接。

ReadWriteFs 的目标跟随边界仍是单个根。不同挂载的目标不再假成功地生成另一个错误路径，而是明确报 `EXDEV`，不创建链接。工作区外的目标继续由原 OH 授权门以 `EACCES` 拒绝；挂载集合本身没有扩大。跨挂载 copy/move 和 hard link 不在此修改范围。

本项没有重写相对目标的既有归一化行为。例如 `./` 或可折叠的 `..` 文本可能由底层规范化；并未新增对所有相对目标字面字符串的逐字保留承诺。相对父目录目标及现有域外目标隐藏行为保留。原有检查不是原子的，仍不能抵御另一个宿主同时替换路径的竞态。

验证入口 `runtime/tests/ohos/process-symlink-mount.test.mjs` 使用真实 VirtualSubprocessRuntime / Worker / Bash / ln / readlink，覆盖同挂载绝对目标、绝对首跳链、相对父目录、合法悬空目标、两种跨挂载目标和域外哨兵。构建器需核完整上游输入、唯一替换锚点与变换后 SHA；不能手改共享 npm 或已生成 bundle。Linux fixture 结果不代表 OH 设备执行。

## 后续 Git 相对首跳更正

真实 Git add 将 readlink 返回值作为 120000 blob。上节保留的相对目标归一化会把链首跳 hop 替成末端 payload，也会删除 ./ 等实际链接文本，导致与原 Git 索引内容不同。后续仅在既有 resolved-target 授权检查通过后返回原相对目标；绝对目标继续按挂载还原，外侧目标的隐藏及读取拒绝不变。原 . / .. 文本、合法悬空目标现在按实际链接字节保留；不放宽根边界，也不声称消除宿主竞态。process-git-link-first-hop.test.mjs 通过真实 ownership native fixture 核 Git blob/模式及外侧控制，并由既有 client suite 一并注册。
