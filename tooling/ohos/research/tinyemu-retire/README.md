# 908：controlled 停机后的自有盘 FILE 退役

本切片只关闭已成功初始化、运行后停止 CPU dispatch 的 controlled VM 所持盘 FILE；VM、virtio 设备、RAM、网络与 console 结构仍保留，owner 全程 quarantine，第二次入口仍 -6。不得 dlclose 或宣称可重启/READY。非 controlled 旧 ABI 不改变释放行为。初始化中途失败不在本补丁新增覆盖范围，原有 -2 必须隔离处理。

0011 在 machine loop 返回后遍历已打开盘；RW 先 fflush，所有模式 fclose。先清空设备内 FILE 指针，保留设备分配，防止后续错误复用 FILE；读写回调对空 FILE 返回错误。fclose 无论返回成功或失败均不得重试原 FILE。任一 flush/close 报错返回 -8 RETIRE_FAILED_UNRELEASED；不得当作成功取消或释放。原触发原因可能为 stop、输入断开、输出错误或 HTIF poweroff，-8 优先报告退役失败。调用方应保留自己的触发原因日志。

## 真实测试

run.py 从固定官方源码逐次应用源差重编 baseline（至 0010）与 candidate（含 0011）。retire-call 真正打开同一路径的 caller FD，再由 TinyEMU 打开自有盘；/proc/self/fd 观测基线停机后仍两个 FD，candidate 只剩 caller 一个，caller 关闭后分别剩一与零。双借入 socket 在返回后真实双向发送接收、flags 保持，stdin/stdout/stderr 均仍开放。每次新宿主进程避免跨用 quarantined owner。

fault-wrap 是仅链接测试库的 --wrap 故障注入，不读生产环境变量、不修改 Node builtin、不进入 HAP。四种测试：正常、fflush 报 EIO、fclose 已实际关闭后报 EIO、fclose 不关闭且报 EIO。后三种候选均 -8；最后一种实际盘 FD 仍存在，证据不伪装清理。每种 owner 再入仍 -6。这里故障不是对底层硬件错误概率的模拟，只证明错误传播与禁止假释放。

受影响回归：每版 core 3、CLINT 13、低字写 1 通过；每版实际 boot Linux 三盘安装、sync/umount、stop/join。真实安装后的打开盘 FD 基线 3、候选 0。该观测证明此 fixture 的盘 FD，不能推导 VM 完全释放。

## 限制和调用责任

fflush/fclose 是同步文件操作，可能受底层 I/O 阻塞；本件不保证有界 join。仍需真实设备验证。不关闭调用方 FD、不关闭或释放 console borrowed transport。关闭盘不代表 guest 正常卸载/业务取消完成；安装取消时应先让 guest 停止写盘/卸载，或将半成品视为不可用，等待机器线程返回并确认无退役错误再删除自有文件。fclose 失败即使某平台实际关掉 FD，也必须保留失败状态。盘 FD 退役不解除 VM heap owner quarantine，也不允许后台关闭后重新启动 VM。

本目录含冻结 900/904-R2/906 前置源差，直接基于 6459f947，自包含，无需先合未合包。上游 TinyEMU 固定 SHA 与所有编译输入见 source-lock.json；Bellard/Alpine 输入见 build-image.py。未新增 HAP 生产依赖；内核、BusyBox/Alpine、TinyEMU/slirp 分发许可证边界同 906。
