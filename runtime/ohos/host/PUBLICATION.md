# M3-1：宿主内的原子独占发布接缝

**未在真机核实。** 这一目录的 Node runner 是 M3-1 的新原生组成部分，不代表旧 O7c 的 Ark 宿主候选已经通过，也不包含 ArkTS 接口、应用单次启动保护和 ready 通道。`c0949d6` 尚无这些文件，因此本补丁添加最小 Node runner；后续 O7c 应在这个 CMake target 上添加 Ark shim，不能再用旧候选覆盖它。

M6-4 后继的当前产品入口是 `runtime/ohos/preload.mjs`，通过 `dsh_node_start` 以固定单一 `--import` 布局启动；非空 `NODE_OPTIONS` 在 Node 初始化前明确拒绝。详见 [统一启动契约](../../../docs/design/harmonyos/startup.md)。本文后面的独立 publication/linked 命令仍是专项测试，不是产品组合命令。版本校验已统一从 `runtime/ohos/node-version.json` 读取/构建；原生登记方式仍保持本节的固定版本接缝，M6-5 另行评估。

## 选择与接口

本次选择自己的 runner（现编入 `libnode.so`），不修改上游 `node-addon-system`。`dsh_node_start` 由 Ark 侧单次启动保护通过后调用，在初始化 Node 前注册 `dsh_ohos_publication`；库驻留到应用退出。JS 使用固定 Node 24.22.1 的 `process._linkedBinding('dsh_ohos_publication')`。这是 Node 的 linked 模块查找入口，不要求 `--expose-internals`，但它不是跨 Node 版本不变的公共 JavaScript API；版本锁与启动检查仍必要。

30 号版本的函数 `renameNoReplace(temporaryPath, finalPath)` 同步调用 `renameat2(AT_FDCWD, ..., AT_FDCWD, ..., RENAME_NOREPLACE)`。成功返回 `undefined`。失败保留 `code`、负的原始 `errno` 与 `syscall: 'renameat2'`，不在错误消息中拼路径。原生层不复制、不 fsync、不清理文件，也不进行回退；JS 发布协议负责这些步骤。目标文件存在时必须保留两边原样，不能改用普通 `rename`。编译环境缺少 `SYS_renameat2` 时明确返回 `ENOSYS`，不能把它解释成允许回退。M3-1b 后继新增的锁和归属标记函数见文末；这里的改名函数体逐字节保持不变。

Node-API 用版本 8。固定 Node 源中 `src/node_version.h` 的默认模块 API 也是 8；`src/node_api.cc` 将旧式 `napi_module` 转为 context-aware Node descriptor；`src/node_binding.cc` 在 Node 初始化之前把它登记到 linked 列表。`NAPI_MODULE_X` 在该版本忽略 flags，不能用它假装完成 linked 注册。本实现有意使用仍导出的 `napi_module_register`，其弃用状态和固定版本依赖是已知代价；当前 `node::Start` 接缝没有可直接传给 `node::AddLinkedBinding(Environment*, ...)` 的 Environment。不能把初始化后调用旧登记函数当成等价方案。

## 已实际验证的范围

本节记录的是 30 号冻结时的构建与测试身份；M3-1b 后继的新增函数、新源码与二进制摘要单列在文末，不覆盖历史证据。

固定官方 Linux x64 Node 24.22.1，源归档 SHA256 `4f5379796280cdaeb0c2f358fd04b6a16cc4fb7dfa83b5a8c91a9d963b435231`。原生函数在 Linux 编成测试 `.node`，另外编成仅供测试的预启动 `.so`，通过 `LD_PRELOAD` 在 Node 初始化前登记。后者用于验证真实 linked 注册；它不是产品启动方案，不能放进 HAP。

`publication-linked-probe.mjs` 在 JIT 和 O0 严格仿真下都实际成功：主 isolate 与文件型 ESM worker 均查到同一个模块接口；中文、emoji 路径成功提交；已存在的目标返回 `EEXIST` 且原目标和临时文件不变。严格仿真禁止全部动态 addon、禁 spawn/link、无 WebAssembly；linked 调用不依赖动态 addon 白名单。Linux 测试所在文件系统 `statfs.type=2035054128`，不能推及手机应用数据目录。

首轮 native 编译因局部变量重名失败，已修复，原日志保留。首轮测试用 CommonJS `eval` worker，观察到该 worker 没有重建 `--import` 仿真标记，严格断言失败；随后改为与当前 O4 一致的文件型 ESM worker，断言不变并通过。旧测试和失败日志保留，不能将后者的通过冒充前者已经验证。

手工相对路径编译与脚本绝对路径编译还暴露了 `__FILE__` 进入注册 descriptor 的构建差异。随后只将该字段改为固定仓库相对文件名；旧两套二进制及其既有实验哈希保留。规范脚本连续重建的 `.node` SHA256 均为 `2870d10332dd2bdb34102ac35de8d8e423592017cf4889a190ecf08ee941e823`，linked 测试 `.so` 均为 `8c0813da5e0773ecab3233565fdf023cda516e496149c837621350f3a8851797`；两套产物逐字节相同。最终源码 SHA256 `454e3b58be5ff23f20ca2b901d306330810df955219329dc841c3afe44f3c420` 已再次完成上述 JIT/严格探针。这个重建结论只覆盖本 Linux 编译环境，不是 OpenHarmony 交叉产物复现证明。

## 生成与执行

原生源码补丁可应用于 `c0949d6`，但下面的严格仿真命令**要求先合入 23 号 M3-3 主包的新版 `sim/preload.mjs` 与 marker**；不能用 c094 原有的环境变量门控预加载器代替。主代理的实际严格实验使用已审 `work-approved` 中的新版 preload。`--strict` 会在主 isolate 和文件型 worker 分别核实 marker、无 WebAssembly，以及 spawn/link/dlopen 的明确拒绝，缺少任一约束都会失败。只加 `--jitless` 不能算严格仿真。

在仓库根目录，用已核哈希的 Linux Node 分发目录作为第一参数：

```sh
bash runtime/tests/ohos/build-publication-native.sh "$NODE24_ROOT" out/publication-linux
LD_PRELOAD="$PWD/out/publication-linux/libpublication-test-linked.so" \
  "$NODE24_ROOT/bin/node" runtime/tests/ohos/publication-linked-probe.mjs
DSH_GO_OHOS_SIM_PLATFORM=openharmony DSH_GO_OHOS_SIM_ADDONS='[]' \
  LD_PRELOAD="$PWD/out/publication-linux/libpublication-test-linked.so" \
  "$NODE24_ROOT/bin/node" --jitless --import ./runtime/ohos/sim/preload.mjs \
  runtime/tests/ohos/publication-linked-probe.mjs --strict
```

原生 v1 候选 `c31270dd…` 的代码函数没有因此改变；独审指出该候选没有写出 M3-3 的测试前置，且探针只比较主/worker 标记是否相等，二者都 false 也能通过。v2 保留旧候选与反例，并添加上述强制断言；不能将旧候选在干净 c094 上的 jitless 结果误称严格通过。最终 C++ 源码和两种测试原生二进制哈希保持不变。

产品构建由 `runtime/ohos/node/build-node.py` 完成：runner 和绑定用 libnode 目标自身的编译参数编译，链入 `libnode.so`。这一步已离线通过；arm64 ABI、Ark/Node 符号隔离、HAP 签名与实机加载的实际运行全部 `NOT_RUN`。产品构建 force-include `runtime/ohos/node/napi-rename.h`，绑定的 N-API 调用都走 libnode 的 `dsh_*` 名字，不与 Ark 的 `napi_*` 同名（见 `runtime/ohos/node/BUILD.md`）。

## 设备核验与结论边界

设备上必须分别验证：实际 `renameat2` 系统调用是否放行；应用数据所在文件系统是否支持 `RENAME_NOREPLACE`；已有文件/目录/悬空链接不被覆盖；两个并发发布者至多一个成功；写中、fsync 后、改名后杀进程并重启；真正原生错误码 `EINVAL` 才进入经说明的旧回退分支。普通 `rename()` 成功不能证明 `renameat2` 放行：固定 OpenHarmony 6.1 musl 的 arm64 分支可使用 `renameat`（38），而 `renameat2` 是另一个系统调用（276）。

文件 fsync 后的 SIGKILL 实验只检验进程终止前后的文件可见性。它不包含突然断电的目录项持久性证明。临时文件的创建与持久归属登记之间仍有崩溃窗口，未确认归属的残留不能按前缀删除；这部分须由上层登记/恢复协议明确限制，不能借原子改名宣称已完全解决。

## 源依据

- [Node 24.22.1 固定源码](https://nodejs.org/dist/v24.22.1/node-v24.22.1.tar.xz)：`src/node_api.cc`、`src/node_api.h`、`src/node_binding.cc`、`src/node.h`、`src/node_version.h`；交付证据记录逐文件哈希，不随包放上游归档。
- [Linux rename(2)](https://man7.org/linux/man-pages/man2/rename.2.html)：不覆盖标志、已有目标、文件系统支持和错误码。
- [Linux fsync(2)](https://man7.org/linux/man-pages/man2/fsync.2.html)：文件同步与目录同步的区别。
- [OpenHarmony 6.1 musl rename.c](https://raw.githubusercontent.com/openharmony/third_party_musl/OpenHarmony-v6.1-Release/src/stdio/rename.c) 与 [aarch64 syscall 头](https://raw.githubusercontent.com/openharmony/third_party_musl/OpenHarmony-v6.1-Release/arch/aarch64/bits/syscall.h.in)：这里只作为固定分支源分析，不作实际设备 allowlist 的证明。

## M3-1b 后继：账本的进程排他锁

持久账本的读、修改、原子替换必须位于同一个进程拥有的排他区间。仅比较 owner UUID 不足以证明另一个进程已经死亡；两份完整 JSON 各自原子替换，也仍可能丢掉另一进程刚登记的条目。本后继在原 linked 模块上新增 `lockExclusive(fd)`，供上层账本在恢复和写入前取得真实内核锁。

### 接口与调用方责任

`lockExclusive(fd)` 同步调用 `flock(fd, LOCK_EX | LOCK_NB)`。成功返回 `undefined`；不等待另一个持有者。失败沿用现有原生错误风格：`code` 通过 libuv 映射，`errno` 为捕获的原始 errno 的负数，`syscall` 固定为 `flock`；错误消息不包含路径。Linux 竞争实测为 `EAGAIN`、`-11`，无效描述符实测为 `EBADF`、`-9`。本实现不把任何错误降级成进程内锁或假成功。

参数必须是 number 类型、有限、非负、没有小数且不超过 C++ `int` 最大值；字符串、BigInt、NaN、无穷值、小数和溢出不会被强制转型到另一个 fd。合法范围内无效的 fd 交给真正的 flock 返回错误。原生层不检查路径或文件类型，也不替调用方取得描述符。

账本 JS 必须先打开应用私有目录里的一个**固定锁文件**，持有其 FileHandle，取得锁后才读取/恢复/更新账本，并在所有相关操作结束后关闭句柄。锁文件从创建后就不应 unlink 或通过 rename 换成另一个 inode。它是单独的锁对象，不能用会被原子替换的账本 JSON 自身作为锁对象。原生层只取锁，既不打开/关闭 fd，也不创建/删除锁文件；文件和目录的归属检查由上层负责。

Linux flock 关联于打开的文件描述，而非路径字符串。重复打开同一个锁文件会形成独立描述符并竞争；同一已持有的描述符再次请求排他锁仍成功。若描述符被 dup/fork 共享，须到最后一个关联引用关闭后锁才完全释放，不能把“关闭任意一个 fd”写成普遍释放保证。此处进程死亡实验没有将锁 fd 传给其他进程。

该锁是协作式协议：所有账本参与者必须锁同一个 inode，私有目录也必须防止其他代码绕过协议直接改账本/锁文件。它不自动提供账本原子写、文件/目录 fsync、临时文件身份登记或重启清理；这些由 M3-1b JS 协议另包实现。特别是 pre-create reserved 记录还没有 inode，不能将同名现存文件直接当作己方文件删除。

### 真实 Linux 证据

基底为已审 30 号 native v2，原 `publication_binding.cc` SHA-256 为 `454e3b58be5ff23f20ca2b901d306330810df955219329dc841c3afe44f3c420`。第一轮只加 flock 的候选源为 `a90599db019e81be55d0780d03e3b5e29cf664dee434f2061251bc828dd9dd53`。这一轮保留为历史 checkpoint；最终增加 xattr 的版本见下一节。`RenameNoReplace` 函数体字节逐项比较相同；原注册方式、版本检查、CMake 和构建脚本不变。

用原规范脚本、官方 Node 24.22.1、Ubuntu c++ 13.3.0 连续构建两次，两种产物逐字节相同：

| Linux 测试产物 | 字节数 | SHA-256 |
|---|---:|---|
| publication.node | 60,184 | `c035a21963743ec61e2bfd17659f50e94dede92fce804cd8de999bb17b91493f` |
| libpublication-test-linked.so | 60,128 | `ff2fbf243798ff4f1a7a0e1669346714cb562f805dec15b61354939fa11d08c4` |

`publication-lock.test.mjs` 的四项在普通 JIT actors 与严格 O0 actors 下各 4/4、零跳过：

1. 参数不截断/不溢出；真实 EBADF 与 EAGAIN 映射；同一 fd 重复加锁以及独立 fd 的冲突。
2. 两个真实子进程先到 ready 门闩，再一起尝试加锁，只一方成功。胜者关闭句柄但保持进程存活，第三个进程能够取得同一个 inode 的锁。
3. 持锁者被真实 SIGKILL；协调器等到进程终止后再启动继任者，后者不删除、不更换固定 `.lock` 就能取得锁，文件内容和 inode 保持不变。
4. 明确的协议反例：仅在测试私有目录里故意 unlink 并重建锁文件，两个仍活着的进程可分别锁住两个不同 inode。该断言通过的是“反例确实存在”，不被计作生产协议允许删除锁文件。

跨进程测试的外层协调器必须能 spawn/kill，因此**协调器不在 O0 内**。严格组中的每个 actor 使用 `--jitless --import <已审 M3-3 preload>`，逐一断言 marker、无 WebAssembly、spawn/link/dlopen 拒绝；报告保留完整 argv、PID、真实错误码和 inode。没有把仅 `--jitless` 或仅 WebAssembly 缺失当成完整严格验证。

原 linked 主 isolate/文件型 ESM Worker 改名探针在 JIT 与完整严格 O0 下重新通过；同时核实两个 isolate 均导出新增锁函数。另将已审边界包 `fadf4e14…` 的原 12 项真实改名测试指向新的 `.node` 与新 SHA，12/12 通过，包括两个并发发布者、已有文件/目录/悬空 symlink、EXDEV、实际降权后的 EACCES 和 NUL 参数。没有以新增功能测试代替旧改名回归。

### 重跑与目标边界

仍使用本文件上方的 Linux 构建脚本。锁竞争测试要求先设置新 linked 测试库，再执行：

```sh
LD_PRELOAD="$PWD/out/publication-linux/libpublication-test-linked.so" \
  "$NODE24_ROOT/bin/node" --test runtime/tests/ohos/publication-lock.test.mjs
DSH_TEST_LOCK_STRICT=1 \
  DSH_TEST_SIM_PRELOAD="$PWD/runtime/ohos/sim/preload.mjs" \
  LD_PRELOAD="$PWD/out/publication-linux/libpublication-test-linked.so" \
  "$NODE24_ROOT/bin/node" --test runtime/tests/ohos/publication-lock.test.mjs
```

第二条命令的主协调器有意不加 `--jitless --import`；它会给每个 actor 添加正确参数并检查约束。预加载必须是已审 M3-3 marker 版。原 linked 改名探针仍按前文命令运行。

官方固定 OpenHarmony 6.1 源可确认：`include/sys/file.h` 声明 flock 和 LOCK_EX/LOCK_NB；通用 `src/linux/flock.c` 与 `porting/linux/user/src/linux/flock.c` 都调用 `SYS_flock`；aarch64 头给出的编号为 32；公开 app、app-atomic、app-custom 策略均有 `flock;all`。锁相关八个来源的 URL/字节数/SHA 与下文 xattr 来源同列在 `runtime/tests/ohos/publication-lock-sources.json`。它们只证明该源码分支具备此接口与所示策略条目，不能证明实际手机使用这些有效策略或实际挂载的锁语义。

**OHOS SDK 交叉编译、arm64 ABI、目标 libnode/loader、实际应用 sandbox、f2fs/hmdfs/sharefs 的有效锁行为仍为 NOT_RUN。** Linux 的 `.node` 和 LD_PRELOAD `.so` 只作测试夹具，不可放进 OHOS HAP。也没有做断电持久性实验；SIGKILL 释放锁不等于目录项已经跨断电落盘。

来源：[Linux flock(2)](https://man7.org/linux/man-pages/man2/flock.2.html)、[OHOS sys/file.h](https://raw.githubusercontent.com/openharmony/third_party_musl/OpenHarmony-v6.1-Release/include/sys/file.h)、[OHOS 通用实现](https://raw.githubusercontent.com/openharmony/third_party_musl/OpenHarmony-v6.1-Release/src/linux/flock.c)、[OHOS 移植实现](https://raw.githubusercontent.com/openharmony/third_party_musl/OpenHarmony-v6.1-Release/porting/linux/user/src/linux/flock.c)。没有随此后继补丁附上第三方实现或源码归档。

## M3-1b 收敛版：fd 上的随机归属标记

只比较跨重启的 dev/ino 不足以证明归属：旧临时文件被删除后，文件系统可能立即把同一 inode 编号分给一个外来新文件。审查方已经实际复现了这种情况下的错误删除。随机文件名与持久账本不会使 inode 编号变成永久身份。

本版因此再新增两个薄 API，属性名固定为 `user.dsh_go_ownership`：

| API | 成功结果 | 错误与边界 |
|---|---|---|
| `setOwnershipMarker(fd, token)` | `undefined`；以 `fsetxattr(..., XATTR_CREATE)` 创建属性 | 不覆盖已有值；原生失败保留 code、负 errno、`syscall: fsetxattr` |
| `getOwnershipMarker(fd)` | 属性字符串；仅 ENODATA 表示缺失而返回 `undefined` | 其他错误全部抛出，包含 ENOTSUP、ERANGE、EBADF；没有 dev/ino 回退 |

fd 的验证与锁接口相同。token 必须是非空、不含 NUL 的字符串，UTF-8 字节数为 1–65,536；超过范围在调用系统前拒绝。实际资源协议由 JS 生成随机 UUID，native 不自行生成或推测归属。接口允许一般 UTF-8 token 以便验证完整长度，不能据此把可猜测常量当作生产归属标记。

getter 先查询长度，再按实际返回长度构造字符串。第一次返回零时仍分配至少一个字节，避免第二次 `size=0` 退化成另一次查询而被误当成数据。两次调用之间变长导致的 ERANGE 原样抛出，变短则只返回 actual 个字节；中途消失导致的 ENODATA 仍返回 undefined。异常消息不拼路径、marker 或文件正文。

上层协议必须在新文件上设置标记并 fsync，然后把 identified 记录持久化后才开始写正文。重启清理应以 `O_NOFOLLOW` 打开并持有待检查文件，核对 dev/ino 和 marker 与账本 token，持 fd 到同步 lstat/unlink 判定完成后再 close。持 fd 可防止这一个已打开 inode 在检查期间被回收复用；它不等于抵御任意同 UID 恶意修改者的全局原子 compare-and-unlink。私有目录与协作式宿主模型仍是必要前提。

不支持属性、权限拒绝或读取长度冲突都必须使上层失败或保留 unresolved，不能回退到仅 dev/ino 的删除规则。本增量只提供四个 native 函数，不实现或宣称上层 ledger 恢复已经通过；上层的真正 inode 复用先失败/后通过用例由 M3-1b 集成包另行绑定。

### 最终构建与测试身份

最终源 SHA-256 为 `df2285896ff979ea36cd92bec0bfdacdcd0fcb558803b3c595a3b3b62dcb087a`。前述 flock-only 的 `build-01` / `build-02` 与源码 checkpoint 保留不覆盖；本版另在 `build-xattr-01` / `build-xattr-02` 连续重建，逐字节相同：

| Linux 测试产物 | 字节数 | SHA-256 |
|---|---:|---|
| publication.node | 60,880 | `fb9c889c84f5f533d394a089f404347273403b2ee8399e4dbb4280451fdc09e0` |
| libpublication-test-linked.so | 60,832 | `569b89fc39d9bac0001fff032b54eea7a66f3c89d22c9f1f40f0d71d07d056aa` |

新二进制完成以下重跑，未复用旧 binary 的通过数：

- 真实 fd xattr 六项：JIT 6/6、完整严格 O0 6/6，零跳过。包含缺失、写入、fsync、关闭重开、原协议 `wx` 仅写 fd、已有属性 EEXIST 且值不变、参数边界、超过 1 KiB 的 UTF-8 值、持旧 fd 时路径替换以及实际 procfs 的 ENOTSUP。
- flock 四项：JIT actors 4/4、严格 O0 actors 4/4。协调器仍在 O0 外，范围与前文一致。
- 原 linked 主 isolate/ESM Worker 的 JIT、严格探针均通过，四个 API 在两个 isolate 可见；原 12 项真实改名边界再次 12/12。
- 八项**明确注入的系统调用返回**单列通过：查询后 ERANGE、零长度后增长、第二次读 ENODATA、值变短、空值、getter ENOTSUP、setter EIO/ENOTSUP。它们验证分支，不冒称本机真实文件系统产生了这些竞争或证明手机支持属性。注入库不属于宿主 target。

最初另用 Python 在自己新建的 Linux 文件 fd 上实际执行 fset/getxattr、fsync、重复 XATTR_CREATE，观察到缺失 errno 61、重复创建 errno 17，原值未变。它只用于先证实本测试环境支持该属性，然后才实现原生 API；最终结论仍以上述新二进制的实际测试为准。

### xattr 复跑

真实 API 测试使用同一规范构建产生的 linked 库：

```sh
LD_PRELOAD="$PWD/out/publication-linux/libpublication-test-linked.so" \
  "$NODE24_ROOT/bin/node" --test runtime/tests/ohos/publication-xattr.test.mjs
DSH_TEST_XATTR_STRICT=1 DSH_GO_OHOS_SIM_PLATFORM=openharmony DSH_GO_OHOS_SIM_ADDONS='[]' \
  LD_PRELOAD="$PWD/out/publication-linux/libpublication-test-linked.so" \
  "$NODE24_ROOT/bin/node" --jitless --import ./runtime/ohos/sim/preload.mjs \
  --test runtime/tests/ohos/publication-xattr.test.mjs
```

错误注入库可以在 Linux 单独编译；不修改原生构建脚本或产品 CMake：

```sh
cc -std=c11 -shared -fPIC runtime/tests/ohos/publication-xattr-faults.c -ldl \
  -o out/publication-linux/libxattr-test-faults.so
DSH_TEST_XATTR_GET_FAULT=range-after-size \
  LD_PRELOAD="$PWD/out/publication-linux/libxattr-test-faults.so:$PWD/out/publication-linux/libpublication-test-linked.so" \
  "$NODE24_ROOT/bin/node" runtime/tests/ohos/publication-xattr-fault-probe.mjs
```

getter 模式共有 `range-after-size`、`empty-then-grow`、`missing-after-size`、`shrink-after-size`、`empty`、`unsupported`；setter 改用 `DSH_TEST_XATTR_SET_FAULT=io` 或 `unsupported`。同次进程只设置其中一个变量。报告明确写出 `injectedSyscallOutcome: true`。

### OHOS 与文件系统边界

固定 [OHOS sys/xattr.h](https://raw.githubusercontent.com/openharmony/third_party_musl/OpenHarmony-v6.1-Release/include/sys/xattr.h) 声明两个 fd 接口和 XATTR_CREATE；[xattr.c](https://raw.githubusercontent.com/openharmony/third_party_musl/OpenHarmony-v6.1-Release/src/linux/xattr.c) 分别调用 SYS_fsetxattr / SYS_fgetxattr。已有 aarch64 头对应编号为 7 / 10，三个公开 app 策略都有这两个 syscall 的 `;all` 条目。新增来源与前文锁来源合计 12 条，逐项摘要在 `publication-lock-sources.json`。

源码条目不证明实际手机的应用权限、有效 sandbox、挂载参数或 f2fs/hmdfs/sharefs 对 `user.*` 的支持。**OHOS SDK/ABI/应用权限与目标文件系统的 fset/getxattr 实测全部 NOT_RUN。** 不支持时必须明确失败并保留资源；不会偷偷改成仅 inode、文件名前缀或普通文件正文标记。Linux 的成功与注入测试都不能改变这一状态。

原始语义参照 [Linux setxattr(2)](https://man7.org/linux/man-pages/man2/setxattr.2.html) 和 [getxattr(2)](https://man7.org/linux/man-pages/man2/getxattr.2.html)。文件和目录 fsync、真正断电恢复以及同 UID 任意伪造 marker 不在这组 native 测试的结论范围内。
