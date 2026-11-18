# P2 v6：鸿蒙托管技能安装

基底 `3fc4081`。实现复用 Android runtime 的协议和提交粒度；Android 源码、构建输入及 Flutter UI 均未改。纯逻辑、真实 Linux 文件系统适配和真实 Kotlin 参考已运行；**UNCOMPILED_SDK / NOT_RUN_DEVICE**。公开 TypeScript 声明检查不等于 ArkTS 编译，也不证明目标设备文件系统行为。

## 路径与调用

同一个 ApplicationContext 提供 `guestRoot = filesDir + '/runtime/rootfs'`。安装目标固定为 `guestRoot/root/.dsh/skills/<name>`，请求不能选择其他写入根。Service 构造、engine attach、ready、状态查询和 cancel 都只处理内存；首次 install 才读取目录。`.dsh` 尚未建立时回 `noHome`，不擅自创建一套未启动的运行环境。

`dsh/runtime.installManagedSkill` 接收 Map，字段与 Kotlin 相同：

| 字段 | 条件 |
|---|---|
| `requestId` | 非空字符串，最多 200 个 UTF-16 单元，同一 owner 未结束请求不能重名 |
| `expectedRoot` / `expectedToken` | 非空字符串，各最多 4096 个单元；root 在 IO 阶段比较 canonical path，token 只在内存比较 |
| `expectedGeneration` | 已公布的正安全整数，必须与 owner 当前许可相等 |
| `name` | 仅 `dsh-go-ui`、`dsh-go-plugin`、`dsh-go-guide`、`dsh-go-support` |
| `files` | 1–64 项字符串 Map，必须含 `SKILL.md`；路径最多 512 字符，只允许 ASCII 字母、数字、下划线、连字符开头的安全段，禁止绝对路径、空段、`.` 和 `..` |
| 文本预算 | 每项 UTF-16 单元先限 512 Ki，总量先限 1 Mi；严格编码后仍分别限 UTF-8 512 KiB / 1 MiB，不截断 |

回包仍为 `{result, current, reason}`。`result` 是 `installed`、`updated`、`unchanged`、`userOwned`、`noHome` 或 null；`current` 在回调交付时再次校验；`reason` 只使用固定协议值，不返回文件正文、token 或系统错误文本。`cancelManagedSkill` 仅取消当前 owner 的精确 `requestId`，非法或不存在的 id 不改变其他事务。

Flutter OH StandardMessageCodec 将 INT32、可安全表示的 INT64 和 FLOAT64 解成 JS number，因此安装器只能验证正安全整数，不能再区分 wire 上的 `1` 与 `1.0`。超出 JS 安全整数的值拒绝；许可计数到达 `Number.MAX_SAFE_INTEGER` 后不再签发，不发生取整复用。该限制来自实际编码器声明与实现，不伪称完全保留 Kotlin Int/Long 的运行时类型区别。

## 运行许可与 owner

`ManagedSkillGate` 保存真正 ready 的运行代次、token 和当前 Flutter engine attachment。Activity 的更换不更换 owner；旧 engine 的迟到 detach 不能退休新的 owner。对同一运行和 token 重报 ready 保持同一许可，新 owner 在引擎仍 ready 时获得新许可。stop 立即清除许可并记录已停止代次，迟到的同代次 ready 不能恢复它。

请求在到达时捕获 owner、token、技能许可代次；排队或执行时不会给旧请求补领新许可。Controller 还核实际 native running、运行代次、停止标记和 token。无效请求不开始 IO。回包用 callback 直接交给 MethodResult，交付前再验一次当前性；若文件已完成但回包前许可退休，保留实际 `installed` 等结果，同时回 `current:false, reason:stale`。

这不跨应用进程死亡保存许可。进程重启后旧 messenger、回调和 writer 都不存在，不应把旧代次当成持久身份。

## 有界队列与取消

一个 Service 最多一项物理执行和一项最新待办。100 个连续待办只执行 active 和最后一个 pending；被替换的 pending 精确回包一次，不把文件 Map 保留在待交付闭包中。取消 active 会退休写入许可并回包，但直到已经开始的 IO 返回，才释放物理槽。新请求不能利用反复取消在文件系统排出多个并行 writer。

使用公开异步 fs Promise 接口。同步 wire 预检、UTF-16 校验及编码仍在 Ark JS 执行线程发生，虽然输入有固定预算，也不能据此声称全部 CPU 工作都移到后台线程。没有新增 Worker、依赖、权限或启动引擎的旁路。

## 文件提交和用户接管

1. 在执行阶段验证根、严格编码和字节上限。OH TextEncoder 会替换未配对 surrogate，所以显式先查 UTF-16；与实际 Kotlin 编码异常一样回 `io`，不写替代字符。
2. `SKILL.md` 必须以 frontmatter 开头，且 managed marker 位于其中。已有 SKILL 无 marker、不可读、非严格 UTF-8 或超过读取上界时回 `userOwned`，不覆盖用户接管的文件。比较保留既有单个开头 BOM 的兼容规则。
3. 非 SKILL 文件按请求顺序比较、提交；相同文本不写。`SKILL.md` 永远最后。先写同目录隐藏临时文件、处理短写、fsync、关闭，再重验许可和路径并 rename；之后 fsync 父目录。
4. 临时名是 `.dsh-go-tmp-<basename>`。请求路径段不允许以点开头，因此合法输入文件不会与另一文件的临时名碰撞。异常或取消尽力清理已打开但未提交的临时文件；文件描述符在 finally 关闭。
5. 逐组件 lstat 和末端 NOFOLLOW 拒绝已存在的静态 symlink，末端打开使用 NONBLOCK 并以 fstat 要求普通文件。`File.path` 只用于入口 canonical 比较；它对原路径字符串做 realpath，不能证明 fd 的根包含关系。

取消不回滚已提交文件。新装取消后可能留下部分普通文件，但没有最后的 SKILL；升级取消后可能是新数据与旧 SKILL，后续正常安装修复。若取消发生在已经开始的 rename 内，该次 rename 仍可能完成；队列保持槽直到物理操作结束。**这不是整包原子事务，也不提供对抗另一个并发恶意改父目录的 writer 的文件系统沙箱**，与 Android 文档边界一致。系统 fsync/rename 的持久化和中断行为仍待设备测量。

## 实际证据和重跑

`tooling/ohos/tests/managed-skill.test.mjs` 导入实际三个 ETS 文件，测试 loader 只替换扩展名、平台 fs/util 入口和类型 import；没有为产品添加测试分支。fs fixture 使用 Linux 的真实 fd、read/write/fsync/rename，保留与 OH File.path 相同的「原字符串 realpath」语义。19 项覆盖中文/短读短写/BOM、字节预算、非法 UTF-16、用户接管、根和静态 symlink、fsync 后取消、部分提交重试、临时名碰撞、Uint8Array 子视图、迟到 ready、owner 替换、100 个 pending、rename 在途取消和一次回包。运行命令：

```sh
node --test --test-isolation=none tooling/ohos/tests/managed-skill.test.mjs
```

参考 Kotlin 不是手译替身：使用固定 Kotlin 2.4.0 编译器直接编译未修改的 `app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/runtime/ManagedSkillInstaller.kt`，在真实 JVM/Linux 文件系统运行 16 组场景。源 SHA256 为 `08262d4928cca8116c9b8f8c460e2766c6f5bbf12bdaf91c5ca949bd09dc439f`；探针、命令、原始结果和官方 Maven 文件校验随交接材料保存。这不等于 Android App 构建或设备测量。

公开 API 来自固定 OpenHarmony 6.1 声明：

- `interface_sdk-js` commit `8a86234f0d542e5062e24e948652f5a484d90904` 的 `api/@ohos.file.fs.d.ts`，SHA256 `9ec958b39f4e0382462e04980f31abfcee9219c8e09d39e6a91f33df2951e6a8`；只调用其中公开的 open、close、read、write、lstat、stat、mkdir、rename、unlink、fsync，不使用未公开 EXCL。
- 同 commit `api/@ohos.util.d.ts`，SHA256 `4c5c9b22df7175392d9c5258cc923c53dcb0b8cb96414a853f573b33bc8a748c`。
- `filemanagement_file_api` commit `53a68044278f75bdc7141d9124b31db4342940c2` 中 `fs_file.cpp::GetPath` 的实现用于确认 File.path 边界。
- 固定 Flutter OH embedding 的 `StandardMessageCodec.ets`，SHA256 `6f5fb3d4e307b4598a37f7beaf98a829ab8b04cdbe3301454086f60830b207f8`，用于确认 number / INT64 的实际解码。

设备还需验证：真实 MethodCodec Map、ArkTS 编译、文件权限和 URI/Context 生命周期；目录 fsync 支持；安装期间滚动、stop 和 engine 重建；SKILL 最后、无变化时 mtime 不变、用户接管不覆盖、取消后无多 writer 和 fd 泄漏。测试日志必须避开 token 与技能正文。
