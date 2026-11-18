# 公开 ArkTS 检查的证据范围

基底：530f183。本工具补丁保留该基底的 `--full` 装配步骤；本次本地缺少完整 Dart/AOT 与目标原生库，只运行普通检查。`--full` 的现行输入仍是基底旧展开 rawfile 格式；单 runtime.zip 的配套校验由归档格式包另行给出，不能混用格式。`tooling/ohos/build-hap.sh` 不在本补丁。

## 执行及结果

按照原入口设置 JDK17，指定 `--sdk`、`--work`，可用 `--source` 指向应用的 ohos 目录。保留已固定的下载缓存，不使用 `--clean`。不带 `--with-forks` 的普通检查只验证应用模块和固定 embedding；不证明完整 Flutter 或 native 产物可运行。

每次调用在 work 下创建唯一 `check-XXXXXXXX`，标准输出打印 `check-arkts: run-root ...`。该目录保存当次 `hvigor.log`、`diagnostics.txt`、`check-inputs.json`、`build-identity.json`、`diagnostic-source-paths.json` 与 HAP/字节码；工作目录根的同名文件只是兼容旧用法的副本。应从唯一运行目录封存证据。

曾实测在复用工作根后，当前项目已产生新的 HAP，工作根的 hvigor.log 却与上一轮故意错误实验逐字相同，且保留旧 mtime。根因未定，不把它推断成产品错误或编译成功。旧日志及输入保留；工具已按路径归属硬拒绝该回合。现在日志、身份和诊断全在唯一运行目录计算，最后才发布兼容副本；不会把外来项目的自有错误降为依赖警告。

## 真实验证层

公开最小归档组合21输入0错误；同一 work 的故意 `any` 私有 Entry 正确失败（10605008），不生成 HAP；HMS 占位组合44输入0错误。保存实际源码、命令、诊断、HAP、提取ABC及反汇编SHA。HMS始终 UNCOMPILED_HMS。此次没有声称运行目标设备，也没有把普通HAP称作完整App。

身份门比较私有工程和输入源码的所有ETS/DTS（生成注册表单列排除），核对HAP内ABC与提取ABC一致，检查每个ETS是否进入反汇编记录。诊断里的自有文件路径若不属于当轮工程则报 CHECK_DIAGNOSTIC_SOURCE。非零编译器退出、失败task、源/工件身份不一致、诊断错误或未编译源都会失败。
