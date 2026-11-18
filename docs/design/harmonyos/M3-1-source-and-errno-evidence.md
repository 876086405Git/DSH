# M3-1：原子发布的源码前提和错误边界证据

## 结论范围

本材料新增源码核对与可重复测试，不改发布实现。固定 Linux x64 Node 24.22.1 上，薄原生接口的 **12 项测试通过**；直接调用当前发布核心的 **8 项错误门控测试通过**，均 0 skip / TODO。已有空文件、普通文件、目录、普通符号链接和悬空链接都没有被覆盖；两个等待同一门闩的 Worker 提交时，一个成功、一个得到 EEXIST，最终内容完整。

这些是 Linux 宿主结果。所读 OpenHarmony 6.1 参考源里，普通 App seccomp 的 allowList 包含 renameat2，f2fs 接受 RENAME_NOREPLACE，hmdfs 的所读入口接受/转发该标志；**sharefs 的所读 rename 实现却直接拒绝任何非零 flags，返回 EINVAL**。不能据此宣称真实应用目录支持该系统调用与标志，不能删掉题面要求的 EINVAL 回退风险说明。

| 绑定对象 | 精确身份 |
| --- | --- |
| 实际 `.node` | SHA256 `2870d10332dd2bdb34102ac35de8d8e423592017cf4889a190ecf08ee941e823`，由 M3-1 主代理构建的最终测试产物 |
| 发布核心 `atomic.mjs` | SHA256 `c774041d8174cd495bfcb4e2deda2dc3f5eb8100ffcb5557ceae2a107d7f78cc`；测试前后核对源码没有变化 |
| Native 测试 | SHA256 `5edadbe3ba06ed2de36a52c1a3c211c4d1fcd061a0dad1d0a42397a608cb0177` |
| 发布核心错误测试 | SHA256 `b52d766e3a49f678bdd7925454ca724718fdead2cac89e13d605fa8965855bf6` |
| 宿主 | Node v24.22.1，Linux 6.18.57 x64，主测试文件系统 statfs.type=2035054128（overlay） |
| 报告 | `native-boundaries.json`：12/12；`publisher-error-boundaries.json`：8/8，随包 manifest 记录各自 SHA256 |

早期 native `9ae0a3ed…` 在本组边界测试中没有运行；不能将本结果倒填给那个哈希。此前其他代理的早期试验由其原记录独立保留。

## 公开源码的适用版本

参考分支/标签为 **OpenHarmony-v6.1-Release**，沿用本轮 O7 SDK 候选版本的源码调查口径，不推定用户设备正运行该版本。官方 `manifest/default.xml` 将默认 remote 指向 gitcode，revision 指向这个 tag。GitHub kernel 6.6 镜像的该 tag 路径返回 404；kernel 文件实际从官方 GitCode raw URL 获取，未换成无版本的 master。

所有有效来源的 URL、字节数与 SHA256 写在 `runtime/tests/ohos/publication-source-manifest.json`。`publication-source-fetch.py` 按清单下载和校验；本补丁不包含第三方源码正文或 tarball。初始错误路径/404 以及成功抓取元数据保留在证据中，HTTP 200 的 HTML 不计为源码。

### 系统调用与 libc

| 参考源码 | 直接可推出的事实 |
| --- | --- |
| musl `src/stdio/rename.c` | 条件分支优先 SYS_rename，其次 SYS_renameat，最后才是 SYS_renameat2 且 flags=0。 |
| musl `arch/aarch64/bits/syscall.h.in` | __NR_renameat 为 38，__NR_renameat2 为 276；arm64 表没有独立 rename 项。 |
| musl `src/unistd/renameat.c` | 文件同时定义 renameat 与 renameat2，后者将传入的 flags 交给 SYS_renameat2。 |

因此普通 rename 能运行，不能单独证明另一个调用号 276 被沙箱放行。薄 native 实现直接调用 SYS_renameat2 并保留真实 errno，没有通过普通 rename 近似独占发布。

来源：[rename.c](https://raw.githubusercontent.com/openharmony/third_party_musl/OpenHarmony-v6.1-Release/src/stdio/rename.c)、[arm64 表](https://raw.githubusercontent.com/openharmony/third_party_musl/OpenHarmony-v6.1-Release/arch/aarch64/bits/syscall.h.in)、[renameat/renameat2](https://raw.githubusercontent.com/openharmony/third_party_musl/OpenHarmony-v6.1-Release/src/unistd/renameat.c)。对应 SHA256 分别是 `48087ba007f7736aef77a0382a30a7e059a29384be100d2fd8906cd95721d067`、`0cf2ce52a191ae36b768b932197e31d5c9b0c6980e0d4f132a5b194d2f013e14`、`b2f59611306699e7f0d9c3058e9c6a3476cbb2601adc96545c75ccbc87aca20c`。

### 参考沙箱策略

`startup_init` 的 `app.seccomp.policy` 在 allowList 内列出 `renameat2;all`（该文件第 242 行）；普通 app、atomic 和 custom 这三份参考策略都包含该条目。普通策略缺省 returnValue 为 TRAP。`startup_appspawn/modules/common/appspawn_adapter.cpp` 的 SetSeccompFilter 在 WITH_SECCOMP 下按构建和进程属性选择具体策略；`startup_init/services/modules/seccomp/seccomp_policy.c` 再定位并加载构建的 filter 库。

这是参考策略的正面证据，但没有读取目标镜像最终 filter、厂商覆写、进程的实际 seccomp 状态或额外限制。因此不把它改写成“目标 HAP 已允许 renameat2”。

来源：[app 策略](https://raw.githubusercontent.com/openharmony/startup_init/OpenHarmony-v6.1-Release/services/modules/seccomp/seccomp_policy/app.seccomp.policy)、[appspawn 选择](https://raw.githubusercontent.com/openharmony/startup_appspawn/OpenHarmony-v6.1-Release/modules/common/appspawn_adapter.cpp)、[filter 装载](https://raw.githubusercontent.com/openharmony/startup_init/OpenHarmony-v6.1-Release/services/modules/seccomp/seccomp_policy.c)。普通 app 策略 SHA256 `83a5a0d0a835b1dc3593bdb5507d2e76f18e22027c5b05bfb400807979bbdfd5`；其他源哈希见清单。

### 参考文件系统

| kernel_linux_6.6 的固定源 | 可核事实 | 尚不能推出的结论 |
| --- | --- | --- |
| `fs/f2fs/namei.c`，f2fs_rename2 | flags 白名单包含 NOREPLACE；存在目标的处理由上层 VFS 完成，随后走普通改名主体。 | 目标设备实际启用了同一实现，或应用数据必在 f2fs。 |
| `fs/hmdfs/inode_local.c` | 将 flags 交给下层 vfs_rename。 | 下层具体文件系统、挂载组合和权限必然支持。 |
| `fs/hmdfs/inode_merge.c` | 只允许 0/NOREPLACE，并传给下层 vfs_rename。 | 所有 merge 目录布局和目标镜像均支持成功提交。 |
| `fs/hmdfs/inode_remote.c` | 入口允许 NOREPLACE，向远端请求传递 flags；还有 EACCES、EPERM、EXDEV 等分支。 | 本材料未验证远端服务端全链路、网络故障及分布式持久性。 |
| `fs/sharefs/inode.c`，sharefs_rename | 第 264 行的非零 flags 检查直接返回 EINVAL。 | 不知道用户应用数据路径是否经过这层，也不将这个版本推广到全部 OHOS 版本。 |

来源：[f2fs](https://raw.gitcode.com/openharmony/kernel_linux_6.6/raw/OpenHarmony-v6.1-Release/fs/f2fs/namei.c)、[hmdfs local](https://raw.gitcode.com/openharmony/kernel_linux_6.6/raw/OpenHarmony-v6.1-Release/fs/hmdfs/inode_local.c)、[hmdfs merge](https://raw.gitcode.com/openharmony/kernel_linux_6.6/raw/OpenHarmony-v6.1-Release/fs/hmdfs/inode_merge.c)、[hmdfs remote](https://raw.gitcode.com/openharmony/kernel_linux_6.6/raw/OpenHarmony-v6.1-Release/fs/hmdfs/inode_remote.c)、[sharefs](https://raw.gitcode.com/openharmony/kernel_linux_6.6/raw/OpenHarmony-v6.1-Release/fs/sharefs/inode.c)。sharefs SHA256 `7478c2b95cae359130dde7c283bba3d033c3855963300d463b9b01af3104b111`。

## 实测与注入对照严格分开

### 薄 native 的 12 项

- 成功提交保留完整 inode 与内容，返回 undefined，临时路径消失。
- 已有空文件、普通文件、目录、普通 symlink、dangling symlink 五类全部返回 EEXIST，原目标 identity 不变；普通 symlink 的 referent 内容也不变。
- 两个真实 Worker 先各自加载 native，等待同一 SharedArrayBuffer 门闩再提交；结果一胜一 EEXIST，winner 全内容一致，loser 自己的 stage 仍在。
- 缺源为 ENOENT，目标父路径是普通文件为 ENOTDIR。
- 主目录 dev=27 与 `/dev/shm` 临时目录 dev=26 真实跨文件系统，返回 EXDEV/-18，没有创建 final。
- 测试子进程降到 uid 65534，在无权限目录提交，真实返回 EACCES/-13；不是 root 的 chmod 假阴性。
- 参数类型与嵌入 NUL 被拒绝，没有以截断后的路径进行系统调用。

所有测试只清理自身明确创建的测试目录，没有按发布临时文件前缀清理应用文件。

### 直接复用发布核心的 8 项

前五项实际调用同一个 native：EXDEV、ENOENT、ENOTDIR、EEXIST、EACCES 均通过原 publisher 拒绝，onFallback 调用数为 0，输入源保持完整，属于该调用的临时条目被收尾。

核心本来把 stage 放在 final 同目录。因此 EXDEV/ENOENT/ENOTDIR 这三项在 **native 调用边界**刻意更换操作数来触发真实错误；不能声称正常同目录发布会自发发生跨设备错误。EACCES 在降权子进程中，仅于提交瞬间将该私有目录切成 0500，调用 native 后还原成 0700，使上层能完成精确清理。

后三项是明确注入的正负对照：native ENOSYS 不降级；fsync 的 EINVAL 在 native 之前拒绝；只有带 syscall=renameat2 的 native EINVAL 进入用户指定的旧独占复制回退，事件中保留“进程死亡可能留下 partial final”的风险。当前 Linux 文件系统没有真实触发不支持标志的 EINVAL，这一点不能伪装成实测。

本组没有重复主发布实验的 copy 中途 SIGKILL、重启登记恢复或完整 provider 写入。它们由 M3-1 主协议包独立保存。本材料的通过数不能代替这些结果。

## 持久性与真机待验

[Linux rename(2)](https://man7.org/linux/man-pages/man2/rename.2.html) 区分已有目标、跨挂载点和不支持 flags 等错误；不能把任意 errno 都解释成 EINVAL 回退。[fsync(2)](https://man7.org/linux/man-pages/man2/fsync.2.html) 说明文件同步不保证目录项同步；若以后扩展到断电/内核崩溃的持久性承诺，还需核实目录 fsync。SIGKILL 实验验证进程死亡前后的可见性，不证明断电持久性。

真机清单应记录目标镜像/SDK/内核、实际应用数据路径挂载链、具体 syscall 返回、errno 或异常信号、同目录 stage/file.sync/NOREPLACE 流程、已存在五类目标、竞争与进程死亡恢复。如果得到 EINVAL 并走旧回退，继续保留旧回退的半文件风险，不能标记原子发布全域成立。

## 重现入口

先构建 M3-1 主包的固定 Linux 测试 `.node`，然后明确指定接口和核心路径。两个测试默认核对作者构建的 `.node` 哈希 `2870d103…`；其他编译器产出的字节不同，用 `M3_PUBLICATION_SHA256` 传入本地构建的 SHA256：

```sh
M3_PUBLICATION_ADDON=/path/to/final/publication.node \
M3_NATIVE_REPORT=/path/to/native-boundaries.json \
node --test --test-isolation=none runtime/tests/ohos/publication-native-boundaries.test.mjs

M3_PUBLICATION_ADDON=/path/to/final/publication.node \
M3_PUBLICATION_MODULE=/path/to/atomic.mjs \
M3_PUBLISHER_ERROR_REPORT=/path/to/publisher-error-boundaries.json \
node --test --test-isolation=none runtime/tests/ohos/publication-errno-boundaries.test.mjs

python3 runtime/tests/ohos/publication-source-fetch.py /source-audit-output
```

需要真实不同文件系统和可运行降权子进程的 Linux 测试环境；默认跨设备目录为 `/dev/shm`，可以用 `M3_OTHER_FILESYSTEM` 指向另一个已授权、不同 dev 的目录。若夹具条件不满足，测试会失败，不跳过后仍报告全过。源文件下载只用于核对，不进入产品包。
