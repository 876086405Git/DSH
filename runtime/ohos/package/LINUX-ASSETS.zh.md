# 可选 Linux 六资产的构建与发布

`compose-runtime.py --linux-assets <目录>` 将实际 Linux 数据纳入同一个受校验的运行时。参数必须指向可信构建输出的 `assets/`，不接受插件提供的目录或下载端自报的任意清单。不传此参数时，组合器保持原有无 Linux 资产的行为。

## 资产位置与信任来源

目录恰有以下六个普通文件，不能含子目录、符号链接、共享硬链接或其他文件：

| 角色 | 文件名 | 安装后路径 |
|---|---|---|
| 清单 | `install-manifest.json` | `<runtimeRoot>/runtime/ohos/linux/assets/install-manifest.json` |
| BIOS | `bbl64.bin` | 同目录固定文件名 |
| kernel | `kernel-riscv64.bin` | 同目录固定文件名 |
| 工具归档盘 | `tools.block` | 同目录固定文件名 |
| bootstrap | `bootstrap.ext4.gz` | 同目录固定文件名 |
| 空目标盘 | `empty.ext4.gz` | 同目录固定文件名 |

清单保持 `bios/kernel/tools/bootstrap/empty/archive` 六个角色；五个 `path` 只能是固定 basename。组合器核每件真实长度和 SHA256，核两个 gzip 的实际展开长度与 SHA256，并核工具盘的 512 字节对齐。重复 JSON 字段、额外字段、非法大小、路径或摘要均拒绝。单件压缩或展开数据上限为512MiB，清单上限64KiB；不会因一个压缩流声称很小而无限展开。

`archive` 固定为 Alpine 3.24.4 riscv64 的华为源：

```text
https://repo.huaweicloud.com/alpine/v3.24/releases/riscv64/alpine-minirootfs-3.24.4-riscv64.tar.gz
bytes: 3451625
sha256: 010683db6c73b3ad1c334fc8f93f64ae748ef67ae6d69e964929aeaf8517bff3
```

这是首次使用时下载归档的可信身份，归档本身不在六资产中。SHA核验不为任意来源的输入建立发布者身份；本接口以构建方明确选定的目录和签名HAP为信任边界。不要把未审核下载同时提供的数据与自报哈希当作可信构建输入。

## 在构建机准备

构建沿用既有 `mke2fs` 和 Python 标准库，不在App里执行构建命令，也不新增 npm 或其他第三方依赖。

```sh
python3 -I -B tooling/ohos/build-linux-assets.py \
  --diskimage /inputs/diskimage-linux-riscv-2018-09-23.tar.gz \
  --alpine /inputs/alpine-minirootfs-3.24.4-riscv64.tar.gz \
  --tools-root /inputs/approved-tools-root \
  --agent runtime/ohos/linux/guest-agent.py \
  --output /outputs/linux-images
```

脚本固定核Bellard归档、Alpine归档和当前guest-agent的SHA，保留 `image/` 和 `BUILD.json` 供诊断；成功新增的 `assets/` 只有六件。两个512MiB未压缩ext4中间盘留在 `image/`，不进入运行时/HAP。发布资产先写本次私有暂存目录，经实际字节校验后rename；已存在的目标不覆盖，失败删除本次暂存。它是构建机发布步骤，不承诺掉电持久性。

工具树是调用方提供的已批准树，脚本没有把APK获取过程变成独立可复现的依赖流水线。镜像UUID等构建元数据也不保证逐字可复现；每次实际生成的六件SHA由清单及组合报告绑定。既有TinyEMU宿主许可文本仍随运行时发布；guest工具及数据的来源、许可和对应源码记录仍须按其固定输入保留。Bellard归档的 `patches/readme.txt` 给出的源码身份为 `riscv-pk ac2c910b18c3e36cfd85080472e78ad2fe484325` 和 `riscv-linux a3b1e7acc6a181e04e9a943942084395df4498dd`，不能用TinyEMU宿主许可代替这些组件的来源记录。

## 真实收据与组合命令

依赖前缀必须来自既有官方 `prepare-inputs.py` 的锁定安装与OH补丁步骤。使用Node 24.22.1、npm 11.9.0；已有完整缓存时可加 `--offline`。输出必须是仓库外新目录，不能重复patch已准备前缀，也不能手写 `prepared-inputs.json`。

```sh
python3 -I -B runtime/ohos/package/prepare-inputs.py \
  --target ohos --node /tools/node --npm /tools/npm \
  --cache /cache/npm --offline --out /outputs/prepared

python3 -I -B runtime/ohos/package/compose-runtime.py \
  --target ohos \
  --dsh-prefix /outputs/prepared/dsh \
  --process-prefix /outputs/prepared/process \
  --target-report /outputs/prepared/target-report.json \
  --prepared-inputs /outputs/prepared/prepared-inputs.json \
  --regex-artifact /inputs/re2js-unicode.mjs \
  --esbuild-prefix /inputs/esbuild-prefix \
  --linux-assets /outputs/linux-images/assets \
  --imports-report /outputs/linux-imports.json \
  --node /tools/node \
  --runtime-core app/ohos/entry/src/main/ets/runtime/RuntimeCore.ets \
  --out /outputs/runtime-with-linux
```

RE2产物仍须是既有固定私有构建，组合器继续核锁定SHA；esbuild沿原构建输入。可与已有 `--python-bundle` 同时使用，两分支独立校验。

六件经校验后实际复制进payload，复制后的清单、压缩和展开身份再核一次。它们进入 `input-files.json`、`payload-files.json`、runtime manifest、`runtimeVersion` 和ZIP回读；`composition-report.json`增加 `linuxAssets` 明细及 `nativeLibraries.linux`。现有npm收据、补丁身份、导入解析、真实RuntimeCore清单消费者以及最终暂存目录rename均保留。没有另建一份不受现有发布身份约束的数据旁路。

安装器仍按原有暂存、逐文件rename和最终 `installed.json` 提交运行时，不把这描述成整根目录原子替换。guest的可写instance由安装owner另行持有；六资产是不可变输入，不得覆盖DSH_HOME或当前rootfs。

## HAP关联

`build-hap.sh`读取实际内层runtime.zip，在SDK handoff之前核六件字节与清单，并要求本次实际暂存的原生库含 `libdsh_linux.so`。`audit-hap.py`再次对最终HAP中的六件及库集合做同样检查；原有ELF、原生库、完整runtime ZIP核验不放宽。

只有library的922组件/诊断构建继续允许；没有资产不能在运行态宣布Linux可用。六资产存在而缺库则构建/审计失败。资源完整与库存在也不等于Linux READY：实际平台ABI、guest启动、授权根与作业资源合同仍由对应owner和设备验证负责。

## 定向测试接口

```sh
python3 -I -B runtime/tests/ohos/linux-assets-package.test.py

# baseline 是相同来源/收据、不传 --linux-assets 得到的原组合输出。
python3 -I -B runtime/tests/ohos/linux-assets-compose.py \
  --prepared /outputs/prepared --regex-artifact /inputs/re2js-unicode.mjs \
  --esbuild-prefix /inputs/esbuild-prefix --assets /outputs/linux-images/assets \
  --baseline /outputs/runtime-without-linux --node /tools/node \
  --out /outputs/linux-composition-validation
```

第一组测试用小数据验证实际文件复制、ZIP、gzip、路径/链接/重复字段和真实pre-SDK HAP staging；原生库文件及SDK handoff为明确替身，不是HAP或真机编译。第二组使用真实prepared前缀和六资产，调用真实composer，检查除六件外payload逐项相同、版本改变、原收据保留，以及收据篡改/资产路径篡改拒绝且不发布成功输出。两项分别登记 `linux-assets-package` 与 `linux-assets-composition`；统一门的 `linux_install_assets` 应指向新的干净 `assets/`。这些定点检查不要求运行完整门。
