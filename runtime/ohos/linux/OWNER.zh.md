# Linux 安装与恢复 owner（917、930、931）

生产入口是 `owner.mjs` 的 `loadLinuxInstallationManifest({assetsDirectory})` 与 `createLinuxInstallationOwner({directory,nativeLibraryDirectory,manifest,exports,onProgress,bootTimeoutMs})`。`exports`（940）是至多四个 `{tag:'dshN', path}` App 目录，安装与恢复的 TinyEMU 配置都写成 `fsN` 9P 设备，backend 只接受这些 tag 的挂载。路径来自可信运行时发布根；清单仅选择固定五个资产名。`owner.install({signal})` 返回 `{backend,active}`，只有实际 guest `opened` 经协议验证且当前 active 记录提交成功后才交出 backend。`opened-private-guest` 与 `workspaceLease:false` 不表示全部 P0、授权目录或所有插件命令已可用。

实际 OHOS subprocess service 在 `/dsh-go/v1/linux` 注册现有 connection 鉴权的 App 数据入口。唯一 host preload 在插件前捕获 `DSH_GO_OHOS_LINUX_DIRECTORY`、`DSH_GO_OHOS_NATIVE_LIBRARY_DIR` 和已链接 publication binding 的 `lockExclusive` 函数。专用目录由可信 `HostOptions.linuxDirectory = filesDir + '/linux-tools'` 提供；普通 profile、argv、后续 env 和 HTTP body 均不能改选路径或锁。缺少真实锁能力时启用明确失败，GET 不因此创建目录、装盘或加载 VM。字段与请求去重见 [CONTROL.zh.md](CONTROL.zh.md)。此入口未给 CommandRouter 注入 Linux，插件路由保持既有能力，宿主 cwd 不静默改成 guest `/workspace`。

## 首次安装与恢复

首次安装仍使用固定 URL、长度和 SHA256 下载归档，宿主只展开普通 gzip 镜像、拷贝归档并补齐512字节边界，不执行 tar/mke2fs/fork，不创建归档内链接。四个盘为只读 bootstrap、只读归档、可写 target、只读工具包；guest 解包、首次初始化私有 `/workspace` 的 UID/GID 60081 与0700权限，随后 pivot_root、卸载 oldroot、启动 agent。

931 将可写盘固定为实例内 `target.ext4`。恢复只接受当前固定 `instance.json` 的 v2 clean 记录；旧930的 v1/retired 描述符没有 guest 同步事实，绝不自动升级。已有记录损坏、丢失、脏状态、多实例、资产代际不符、路径/链接/磁盘身份不符时，明确拒绝，既不另装一套来掩盖错误，也不覆盖或清理旧盘。唯一的删除是用户确认后的 `discardLinuxInstallation`（`instance.mjs` 的 `discardLinuxInstance`）：同一把锁与根身份核对，先把根内各项改名为 `.discard-*` 并同步，再不跟随链接地删除；`openLinuxInstance` 把残留的 `.discard-*` 当垃圾删掉，从不恢复。

恢复建立独立 `resume.cfg`：同一个 target 是唯一可写 `drive0`，kernel `root=/dev/vda rw init=/sbin/dsh-init`。它跳过下载、镜像准备、解包和首次工作区权限初始化。持久 `persistentInstanceId` 不变；每个新 owner 产生新的32随机字节 epoch，经 kernel cmdline 传入新 guest。配置不从持久记录接受任意绝对路径。不可变 bios/kernel/tools 副本重新核实际字节；用户可变 target 核固定角色、dev/ino、普通文件、nlink=1、私有权限和固定尺寸，不拿空模板 SHA 校验用户数据。

## 锁、持久状态和退出顺序

启用时打开真实目录 FD，核对规范路径、名称与 FD 身份，仅收紧该专用根至0700。固定 `.lock` inode 从不删除或替换，实际 `flock(LOCK_EX | LOCK_NB)` 排除其他活 owner。根、实例、锁与 target 的名称/FD 身份在关键操作前复核。普通文件与目录 sync 的测试替换仅在构造器内部第二参数中可注入，生产 factory 不公开该参数。

`instance.json` 记录版本、持久ID、本轮 epoch、资产身份、根/实例/target 身份与状态。写入使用同目录排他 pending 文件、文件 sync、rename、目录 sync。任何 VM 可能打开可写盘之前，必须先确认把 clean 消费为本轮 booting；实际 opened 后提交 active。进程死亡会释放 FD 锁，因此持久 booting/active 是下次拒绝自动恢复的依据，不能声称死亡进程仍持锁。

只有**本轮 fulfilled `backend.dispose()`** 返回 `closed:true`、当前 epoch 的 `guestClose:{epoch,rootfsSync:true,syncMethod:'syncfs',syncScope:'rootfs'}`，且实际 native `joined:true`、`retirementError:false`、`apiResult` 为既定 -3/-4，owner 才尝试提交 clean。guest 成功 closed 前必须实际完成根文件系统 `syncfs`。dispose 抛错后，即使 backend getter 保留旧同步帧、稍后 join 成功，也不以这些片段补授 clean。

`cleanCheckpoint:true` 表示当前 owner 已确认完整 clean 文件和目录提交，同时 `resourcesRetired:true`、`dataRetained:true`、`filesRemoved:false`。rename 已可见而最后目录 sync 失败时，当前调用返回 `cleanCheckpoint:false` 和真实错误；catch 没有撤销 rename。下一独立进程持锁后，若实际读到完整且身份有效的当前 clean，可以恢复；若读到 dirty、缺失或损坏则拒绝，不搜索旧备份。该规则依赖写盘前 dirty 提交成功，以及新 clean 仅在真实同步/退休后产生。它不声称掉电耐久或旧内核能完整报告所有写回错误。

未发布的首次 attempt 仅在 native 退休、transport FD 无债务后可清理。已发布实例以及任何恢复尝试从一开始就保留原盘；失败不进入新安装的删除分支。锁覆盖 VM 生命周期和最终元数据处理；native 退休未确认时，活 owner 保留锁与文件。`resourcesRetired`、`filesRemoved`、`dataRetained`、`guestClose`、`cleanCheckpoint` 分开表达，HTTP202、超时、socket关闭和 Node退出均不替代 join。

普通开关 false 仅关准入并取消/等候本 service 的作业，保留同一个 VM；再次 true 复用该 owner。App 最终 shutdown 才 dispose。native VM 堆仍隔离，状态可为 stopped-quarantined；同一 Node 不能解除 native claimed 后再建 VM，恢复只在新的 Node/App 生命周期进行。历史作业 UNKNOWN 不会因资源后来退休而变为成功。

## 构建与验证入口

`tooling/ohos/build-linux-assets.py` 校验固定上游包与 agent SHA，产出干净 `<output>/assets/` 六件目录；`image/` 为构建中间产物。六件为 install-manifest.json、bbl64.bin、kernel-riscv64.bin、tools.block、bootstrap.ext4.gz、empty.ext4.gz。931须使用匹配同步 agent 的资产代际，不能沿用930无同步 agent 的301f…清单。

composer 的 `--linux-assets <output>/assets` 固定发布 `runtime/ohos/linux/assets/`，核 bytes/SHA/展开 SHA，纳入 runtimeVersion、manifest 与 ZIP32 回读。资产存在时 HAP 配对要求 libdsh_linux.so；library-only 保留诊断兼容，运行时缺资产仍失败。构建详情见 `runtime/ohos/package/LINUX-ASSETS.zh.md`；工具归档来源沿用已核材料，不声称另有独立 APK 提取流水线。

`linux-app-control-plain/strict` 覆盖真实 Cordis/BrowserAuth/HTTP、生产 owner/backend、真实 TCP/文件和 linked flock；native session/guest 为明确受控边界。`linux-instance-process` 在外部协调器启动严格独立 Node，检查真实锁、SIGKILL后的脏记录、晚期 env/binding 替换及实际链接负例；其模拟 session 不证明真实 VM join。`research/linux-owner/run.py` 与 `research/linux-control/run.py` 需显式 `--publication-fixture`，保留同源真实内核锁，并使用新记录断言。跨进程恢复须另以两个实际 Node/VM、同一 target、未手动sync的写入/正常同步关闭/重新读回共同证明。

各组是否执行、输入 SHA 和边界以对应报告原件为准。归档传输夹具不证明华为云网络可达；宿主与 guest 结果不替代 SDK/HAP、手机、真实账号或设备掉电测试。
