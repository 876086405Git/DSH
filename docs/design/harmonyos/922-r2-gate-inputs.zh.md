# 922-R2：本机失败修复与 TinyEMU 输入说明

本文对应 `6459f947` 上的 922-R2 累计补丁。922 原补丁的本机完整门为
266 PASS / 7 FAIL / 1 INCOMPLETE / 16 BLOCKED_NOT_RUN，不能沿用之前的
定向 PASS_SCOPED 作为合入依据。922-R2 的实际红绿与最终补丁 SHA256
以交付 ZIP 的测试和独审报告为准；本文件给出输入合同与复跑方法。
没有在研究环境准备或运行完整门，ArkTS、SDK、HAP、Flutter 和手机结果由本机确认。

## 1. 原始阻断的精确分类

原始 `summary.json` 的 16 个阻断中，7 个直接报告路径缺失，1 个由
`tinyemu-stop-boot` 的缺输入连带阻断，8 个在
`ets-runtime-tooling → install-record-wire → flutter-*` 依赖链上。
因此，“8 个由 TinyEMU 输入引起”包括一个间接阻断，不能写成八个都直接缺路径。

| 门 | 必须提供的 TinyEMU 输入 |
|---|---|
| `tinyemu-poweroff` | `tinyemu_source_archive` |
| `tinyemu-native` | `tinyemu_source_archive`、`tinyemu_guest_config`，以及既有 Node 头文件和 C 编译器 |
| `tinyemu-stop-boot` | `tinyemu_source_archive`、`tinyemu_diskimage_archive`、`tinyemu_alpine_archive` |
| `tinyemu-retire` | 同上三个归档 |
| `tinyemu-install` | 同上三个归档 |
| `linux-runtime-backend` | `tinyemu_native_library_dir`、`tinyemu_guest_config` |
| `linux-installation-owner` | `tinyemu_native_library_dir`、`linux_install_assets`、`tinyemu_alpine_archive` |
| `linux-guest-jobs` | `linux_job_inputs`；另依赖 `tinyemu-stop-boot` 产出的受控 `libtemu.so` |

依据：`tooling/ohos/run-gates.py` 中同名门的参数和 `needs`。
这里只列这些门的新增输入；`prepared`、`node_root`、`node_source`、`cc`、
`cxx` 等原有配置继续使用本机已经核验的值。

## 2. 配置键、文件类型与位置

所有键都放在配置 JSON 的 `paths` 对象中。相对路径按**配置文件所在目录**
解析。`gate-inputs.example.json` 已补齐下列七个键，避免先补两个首缺项后，
才发现同一门后面的输入也没有配置。

| 完整键名 | 指向什么 |
|---|---|
| `paths.tinyemu_source_archive` | 原始 `tinyemu-2019-12-21.tar.gz` 文件，未解包、未打补丁 |
| `paths.tinyemu_native_library_dir` | 本机 CPU/操作系统编出的目录，内有真实 `libdsh_linux.so`；不是文件路径，也不是手机 AArch64 库目录 |
| `paths.tinyemu_diskimage_archive` | 原始 `diskimage-linux-riscv-2018-09-23.tar.gz` 文件 |
| `paths.tinyemu_alpine_archive` | 原始 `alpine-minirootfs-3.24.4-riscv64.tar.gz` 文件 |
| `paths.tinyemu_guest_config` | 下述专用四盘夹具的 `candidate/install.cfg` 文件；相关镜像和工具盘必须仍可按其中的绝对路径访问 |
| `paths.linux_job_inputs` | 含上述 Bellard/Alpine 归档和 `apks/` 中 31 个锁定 APK 的输入目录 |
| `paths.linux_install_assets` | 正式 `build-linux-assets.py` 生成的 `image/` 目录，内有 `install-manifest.json` 和它引用的五个文件 |

`tinyemu_native_library_dir` 与既有 `native_library_dir` 是两个用途不同的键。
后者不能仅因名字相似就替代前者。缺失输入仍报告 BLOCKED_NOT_RUN，
没有放宽门或把缺项改成 PASS。

## 3. 归档来源、版本和固定 SHA256

| 文件 | 固定来源 | SHA256 |
|---|---|---|
| `tinyemu-2019-12-21.tar.gz` | `https://bellard.org/tinyemu/tinyemu-2019-12-21.tar.gz` | `be8351f2121819b3172fcedce5cb1826fa12c87da1b7ed98f269d3e802a05555` |
| `diskimage-linux-riscv-2018-09-23.tar.gz` | `https://bellard.org/tinyemu/diskimage-linux-riscv-2018-09-23.tar.gz` | `808ecc1b32efdd76103172129b77b46002a616dff2270664207c291e4fde9e14` |
| `alpine-minirootfs-3.24.4-riscv64.tar.gz` | `https://repo.huaweicloud.com/alpine/v3.24/releases/riscv64/alpine-minirootfs-3.24.4-riscv64.tar.gz` | `010683db6c73b3ad1c334fc8f93f64ae748ef67ae6d69e964929aeaf8517bff3` |

这些值来自仓库实际 builder 的校验常量及
`runtime/ohos/linux/native/source-lock.json`，不是按下载文件名推定。
TinyEMU 归档也已在 ohos9 的 900 正式包 `inputs/` 提供，可以复用相同字节。
镜像下载返回错误页、改版内容或其他版本时必须拒绝，不修改 SHA 来迁就它。

31 个工具 APK 的版本、文件名、来源、字节数和 SHA 以
`tooling/ohos/research/linux-job/packages.lock.json` 为准，文件 SHA256 为
`549dd31d71bdce15722b5e7f2ccba0f1661c439ce4511d771c8a8c64f03622e4`。
其中包含 gh 2.97.0-r2、git 2.54.0-r0、Python 3.14.10-r1、ripgrep 15.1.0-r0。
没有新增或升级依赖。TinyEMU/slirp 通知见 native 目录的
`THIRD-PARTY-NOTICES.txt`，guest 工具许可证继续以锁文件及原有分发说明为准。

## 4. 构建本机 `libdsh_linux.so`

以下是在已应用 922-R2 的仓库根目录执行的**本机输入构建示例**。
变量必须换成本机真实绝对路径；各 `--output` 目录必须尚不存在。
`DSH_GATE_INPUTS` 不应放在统一门的输出目录里，避免执行门时被清理或覆盖。

```sh
DSH_GATE_INPUTS=/absolute/path/gate-inputs
DSH_NODE_HEADERS=/absolute/path/node-v24.22.1/include/node

python3 -I -B runtime/ohos/linux/native/build.py \
  --source-archive "$DSH_GATE_INPUTS/tinyemu-2019-12-21.tar.gz" \
  --node-headers "$DSH_NODE_HEADERS" \
  --output "$DSH_GATE_INPUTS/tinyemu-native-host" \
  --cc /usr/bin/cc --host-test
```

头文件必须来自 **Node 24.22.1**，且目录直接包含 `node_api.h` 和
`node_version.h`；完整源码的 `src/` 也可用。脚本实际检查三段版本号、
上游归档 SHA 和 source-lock 中所有原生源文件/补丁，按序应用 0001–0014，
编译并产生 `BUILD.json`、逐命令日志和 `libdsh_linux.so`。
使用候选构建，不能加只供反例的 `--host-baseline`。

研究环境已经用相同 922 原生源码、Node 24.22.1 头和 GCC 13.3 编出并实测：
`libdsh_linux.so` SHA256
`82f0e6842f8b58097d5bf953548f06b3bd6abfea8d30e7243edf5843bc96f763`。
这是该次**宿主产物身份**，不是所有工具链都必须产生的通用二进制 SHA。
本机应保存自己的 `BUILD.json` 和库 SHA；源 SHA、编译命令和实际测试共同决定证据范围。

`--host-test` 输出导入普通 Node N-API，只用于运行这些宿主门。
手机库必须走 `runtime/ohos/linux/native/README.md` 中的 SDK/CMake 路径，
使用匹配的 renamed libnode、`napi-rename.h` 和 SDK N-API 审计，不能把上述库放进 HAP。
本次没有运行手机交叉编译，也没有修改 `runtime/ohos/node/`。

## 5. 生成客体输入：两类夹具分别构建

需要 Linux 构建机上的 Python 3、`mke2fs`、C 编译器，以及原门已有的 Node、
git 等工具。脚本只在构建机展开锁定归档，不在 App 中调用宿主 shell 或创建链接。

### 5.1 取得锁定包并生成工具根

```sh
python3 -I -B tooling/ohos/research/linux-job/prepare-inputs.py \
  --out "$DSH_GATE_INPUTS/linux-inputs" \
  --alpine-mirror https://repo.huaweicloud.com/alpine

python3 -I -B tooling/ohos/research/linux-job/build-image.py \
  --inputs "$DSH_GATE_INPUTS/linux-inputs" \
  --agent "$PWD/runtime/ohos/linux/guest-agent.py" \
  --output "$DSH_GATE_INPUTS/linux-tools-fixture"
```

获取脚本验证固定 SHA 后才发布文件；也可以把已经核验的同字节归档/APK放进
相同目录再运行，脚本会再次核验。华为镜像当前是否可达由本机网络决定，
本说明不把某次宿主获取结果当作手机网络证据。上游同字节输入可以用于宿主研究，
App 默认下载地址继续是题面要求的华为云。

`linux-tools-fixture/root/` 是后续两个 builder 的 `--tools-root`。
它的 `BUILD.json` 记录实际来源和 31 个包；其 `sbin/dsh-init` 使用固定的
`01` 重复 32 次 epoch，且有 `/workspace/needle.txt`。这是明确的测试夹具，
不是生产安装生成的随机 epoch。

### 5.2 912/914 四盘 handoff 夹具

```sh
python3 -I -B tooling/ohos/research/tinyemu-native/build-guest-fixture.py \
  --diskimage "$DSH_GATE_INPUTS/linux-inputs/diskimage-linux-riscv-2018-09-23.tar.gz" \
  --alpine "$DSH_GATE_INPUTS/linux-inputs/alpine-minirootfs-3.24.4-riscv64.tar.gz" \
  --tools-root "$DSH_GATE_INPUTS/linux-tools-fixture/root" \
  --output "$DSH_GATE_INPUTS/tinyemu-guest"
```

配置 `paths.tinyemu_guest_config` 为
`$DSH_GATE_INPUTS/tinyemu-guest/candidate/install.cfg`。
新增 builder 把此前仅在 909 WIP 中的已实测夹具配方纳入仓库；
原 builder 来源 SHA256 为
`3eb95fd72559390d8fd1f942230ca2a029e67dd264317c98398d040c74f6e4b9`。
它使用当前仓库的真实 guest-agent，核对工具根 BUILD 的源码/包锁身份与固定 epoch，
建立只读 bootstrap、只读下载归档、独立可写 target 和只读工具盘，保留
`__909_HANDOFF__` 原断言要求的真实 `pivot_root`/旧根卸载过程。

不能拿 903 直启单盘 `alpine.cfg` 代替：912 测试要求四盘安装交接标志。
也不能拿 917 owner 的安装配置代替：生产标志和随机 epoch 与此消费合同不同。
922-R2 没有删除或放宽这些断言。配置内使用绝对路径；移动整套输入后应重建，
不能只搬一个 JSON 文件。ext4 UUID、时间戳和工具根构建时间可能变化，
按每次 `BUILD.json` 记录镜像 SHA，不承诺不同构建逐字一致。

### 5.3 917 installation owner 资产

```sh
python3 -I -B tooling/ohos/build-linux-assets.py \
  --diskimage "$DSH_GATE_INPUTS/linux-inputs/diskimage-linux-riscv-2018-09-23.tar.gz" \
  --alpine "$DSH_GATE_INPUTS/linux-inputs/alpine-minirootfs-3.24.4-riscv64.tar.gz" \
  --tools-root "$DSH_GATE_INPUTS/linux-tools-fixture/root" \
  --agent "$PWD/runtime/ohos/linux/guest-agent.py" \
  --output "$DSH_GATE_INPUTS/linux-install"
```

配置 `paths.linux_install_assets` 为 `$DSH_GATE_INPUTS/linux-install/image`。
此处沿用 922 中的正式 builder 和 `install-init.sh` / `agent-init.sh`，
没有混入暂停中的 930 资产封装、私有目录权限或 931 恢复协议。
owner 门验证 manifest 中的固定文件和 archive；真实下载传输仍使用门明确声明的
固定归档替身，不能据此声称华为 HTTP、HAP 或手机通过。

## 6. Python 门输入与目标库的区别

`python-production` 是**宿主生产源码测试**。它使用执行
`runtime/tests/ohos/python-native.py --production` 的 Python 的 `sysconfig`，
取得该宿主 Python 的 include、stdlib、lib-dynload 和共享 libpython，
实际编译生产 `host.c` 并加载真实扩展。需要同版本开发头、共享库、`cc`、
`openssl` 与 Node 24.22.1；不把本机 AArch64 OH libpython 塞进 x86_64 门。
922-R2 记录这些实际输入，保持测试证书严格验证，并将缺失动态符号和启动失败
作为失败直接报告。没有需要用户另外填写的 Python target 路径键。

手机正式构建仍按追加1使用
`REF-本机完整依赖libpython真机通过-20261108.zip` 的 `libpython3.14.so`：
17,242,880 字节，SHA256
`4ff425ab68e719a7b5f98ffcc98c37f82897353f464287b541bc765b83014447`，
并在初始化使用 `/etc/security/certificates`。
它与宿主测试库的 ABI、证书位置和执行环境不能混淆；手机验收仍由本机完成。
该 REF ZIP 只有库和四份文本，没有同版 `Include`、目标 `pyconfig.h`、
目标 `_sysconfigdata_*.py`、完整 stdlib、CA/许可证资产。正式构建仍需来自
原 CPython 3.14.7 目标构建/同版源码及可信资产的配套输入；不能拿宿主 Python
或 guest Python 3.14.10 的头和标准库替代。继承的
`PYTHON-BUILD-AND-DEVICE.zh.md` 详列这些要求；其中 17/17 属原922历史结果，
922-R2 的新宿主生产测试为另行记录的20/20。

## 7. 修复范围与复跑判读

`AuthorizedWorkspacesPlugin.ets` 的四个 Error 子类实参显式转换为 `Error`，
两个 Any 容器变量显式写出 `Map<string, Any>`。这与已定严格 ArkTS 写法一致，
但宿主执行 ETS 方法体不等于 ArkTS 编译，六处诊断是否全部消失需本机编译确认。

EntryAbility 的公共 import 清单原本已有 `AuthorizedWorkspacesPlugin`；
实际缺失的是 `runtime-channel.test.mjs` 去掉 import 后的显式消费者绑定。
修复该边界后原四个失败回调恢复，原 283 项同组测试可以继续产出
`install-record-wire.json`。Flutter 下游是否全绿仍需本机完整门确认。

`workspace-fid-identity-barrier` 原来已执行测试，遗漏的是 `tests` 覆盖元数据。
现登记 Python 入口和两个 C++ 驱动，不改变原命令或原生断言。
进程路由、内部 Worker resolver 和 Python 动态符号分别是独立修复，
不可用其中一项变绿推断另外几项已经通过；逐项实证见本次 ZIP。
