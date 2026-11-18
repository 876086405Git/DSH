# 930 明确 App Linux 入口的真实客体验证

`run.py` 是窄门，不启动完整统一门，不构建 HAP。它先核六件资产的实际 SHA/size 和固定 Alpine 归档，再复制当前生产 Linux 源码与网络模块，使用锁定 DSH 依赖、真实 BrowserAuth、真实 loopback HTTP、生产 LinuxControl/owner/backend 和真实 libdsh_linux.so / TinyEMU / guest。

1289 有意改变旧同进程 off/on 复用合同；旧 930 实跑记录只证明旧版本，不能当作下述新流程已运行。当前版本是否完成真实客体验证，以对应 INPUTS/COMMAND/原 stdout 与 RESULT 为准。此说明本身不授通过。

唯一替身是 download 的 fetch：把已核固定归档作为流交给生产 downloader。原生 createSession、requestStop、join 没有替换；不据此声称本执行器实际访问过华为云，也没有 OHOS SDK、HAP 或手机通过。

当前流程是 GET 不安装 → POST 202/GET 安装进度 → python print(1)、gh --version、rg、guest 内真实本地空仓库 git clone → 重复 enabled 保持仍运行的同 owner/epoch/target/数据 → 普通 off 取消实际已运行 job、等待真实退出及最终 native join/drive 退休 → 同 App 重新开启明确拒绝并要求 App 重启 → 再次显式 shutdown 复用已完成退休 → 已发布 target 保留、宿主数据 FD 归零。遵守未授权不得 commit/push：这里只 init/clone 空仓库，不建立提交，也不声称验证非空对象传输。HTTP 202/3 秒成功不代替完成。保留 target 不证明 guest 已 sync，也不证明跨 App 可干净恢复。

```sh
python3 tooling/ohos/research/linux-control/run.py \
  --node /absolute/node \
  --dsh-prefix /absolute/locked-dsh-prefix \
  --native-library-dir /absolute/library-directory \
  --publication-fixture /absolute/libpublication-test-linked.so \
  --assets /absolute/build-output/assets \
  --archive /absolute/alpine-minirootfs-3.24.4-riscv64.tar.gz \
  --output /absolute/new-evidence-directory
```

`INPUTS.json` 保存生产源、native 库、清单/资产、归档、真实 BrowserAuth 和 collector 的身份；`COMMAND.json` 保存精确 argv/必要非敏感测试环境；`guest.stdout`/`guest.stderr` 是原始输出；`RESULT.json` 只在所有断言通过后出现。不得把示例路径当作本机已完成调用，正式证据以实际 COMMAND 为准。产物保留本次 target，调用者负责有意识地安排研究数据清理，不由生产 owner 隐式删除。
