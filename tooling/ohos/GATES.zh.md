# OHOS 单入口门禁

在仓库根执行：

```sh
bash tooling/ohos/run-gates.sh --config ../gate-inputs.json --out ../gate-run-001
```

配置参照 `gate-inputs.example.json`，只供应工具/输入路径和受限 Flutter 环境，路径相对配置文件解析。Flutter命令默认设`CI=true`（官方bot检测直接识别本自动测试环境，避免metadata探测），使用官方禁遥测环境与`--suppress-analytics --no-version-check`参数。输出目录必须不存在且位于源码树外。入口将冻结候选分别复制为native/Android验证树和独立`flutter-source`，并把已核安装输入复制到自己的输出，调用现有测试；不修改调用者源码、Android pristine 或 prepared receipt。完整矩阵通常耗时数分钟至数十分钟，取决于机器与输入。

## 结果合同

每组保留原始 stdout/stderr、argv、cwd、环境覆盖、开始/结束时间、退出码与超时；`progress.json` 在每组结束即写入，最终 `summary.json` / `SUMMARY.md` 汇总，`plan.json` 列依赖和测试映射。`coverage.json` 检查两个 OHOS 测试目录中 `.test.mjs` / `.test.py` 是否遗漏。

| 状态 | 含义 |
|---|---|
| PASS | 子命令实际退出0，且未报告 skip/todo；各组结论仍受原测试范围限制。 |
| FAIL | 已执行命令失败、超时或证据核验失败。 |
| INCOMPLETE | 子命令虽然退出0，但报告未执行的 skip/todo 断言或完整桥接清单仍不完整。 |
| BLOCKED_NOT_RUN | 必需工具/输入缺失、真实环境能力不可用，或前置组未通过；该组未执行。 |

Flutter的pub/vendor/l10n/test/analyze只操作独立`flutter-source`，其Android registrant、local.properties和解析生成物不进入native/Android身份对照树。Flutter执行前后逐文件核app/lib、app/test、packages及app/pubspec.yaml原有输入，并拒绝新增Dart/ARB源码；测试失败生成的图片只记录为产物。package_config中dsh_app、dsh_client、dsh_remote的rootUri必须实际解析到该副本，packageUri必须选择各自lib；受保护输入中的文件/目录symlink直接拒绝，包根和lib本身也不得重定向，旧好树/子目录重定向会失败。受保护树完整扫描，不因源码子目录名为build或node_modules而忽略；复制前后也与冻结候选逐项比较。字体只补缺件，不覆盖原资产。原候选应直接从基底和补丁冻结，禁止提前在它里面运行Flutter pub生成Android文件。

继承环境中的OHOS/DSH/M3/M4/M6等测试源码选择器一律移除；必需外部输入由本次配置及各组明确参数提供，旧好源码不能暗中覆盖本次候选。Flutter消费者使用官方JSON reporter并逐项核testDone.skipped及done.success，expanded的视觉格式不作为判断依据。已知wrapper隐藏的TAP只从其固定声明日志读取、核执行总数与skip/todo，并保存hash，不递归猜测其它文件。

桥接审计保留`gateStatus`与`fullInventoryStatus`两个字段：group1限定检查通过不能盖掉完整清单的INCOMPLETE。

任何非PASS、调用者/副本原有源码变化或未映射测试都会让总状态非PASS、总退出非0。不能只看某个子命令退出0。入口不提供跳过Dart或Android对照的成功模式。`diagnostics-linux.py` 的 `--dart` 现在必需，并核 `commands.json` 确实运行一次真实 consumer、退出0且产物存在；performance还要求 `consumerExitCode=0`。

CI现有 Python tooling 之后运行入口合同自测；runtime路径过滤含 `tooling/ohos/**`。该CI自测验证错误传播/skip/必需consumer等，不冒充全量矩阵。完整矩阵依赖本机固定输入，发布/合包检查应运行上面同一命令并保留完整汇总，缺输入时不得把CI自测的绿替代全量门。

## 输入准备

| 配置输入 | 来源与准备 |
|---|---|
| `node_root` | 固定Node24.22.1完整发行目录，含`bin/node`与`include/node`。仅`node --version`成功不足以编译native夹具。 |
| `fetch_node` | 单独的、已按项目固定Undici方案构建的Node24.22.1，用于原`net/test.sh`的builtin fetch契约。其它组仍使用`node_root`；stock Node不能冒充此工具。 |
| `cxx` / `cc` | 本机C++20/C编译器；还需Python3、Git、openssl、zlib开发库、pdfinfo、pdftoppm。 |
| `prepared` | 用下列原准备器执行两锁全新npm-ci及显式OH目标补丁，含`dsh/process/prepared-inputs.json/target-report.json/patch-results.json`。 |
| `android_pristine` | `runtime/locks/dsh-0.2.2-rc.1`完整未补丁npm-ci前缀，保留Linux optional loader与固定rg15；不能用OH omit-optional组成输入代替。 |
| `android_baseline` | 本轮权威基底源码。实际Android补丁选择、完整安装树、真实版本配方和两ABI输入流均与其对照，不写死历史文件数或hash。 |
| `pnpm_prefix` | 按 `runtime/build-runtime.sh` 的 PNPM_VERSION/PNPM_INTEGRITY，从对应 `runtime/locks/pnpm-<version>` 完整复制两锁到独立目录，执行 main CI 原 `npm ci --prefix <prefix> --ignore-scripts --no-audit --no-fund`。保留实际安装收据及 `node_modules/.package-lock.json`。门禁核原锁、安装版本/integrity、可执行 bin，并用无排除的文件/链接清单记录整个安装身份；不自行下载。两个完整 shared-suite 仅使用该输入的显式 PNPM_BIN，不继承父进程同名变量。 |
| `typescript_prefix` | 安装可执行原ETS夹具的TypeScript；这只是Linux转译适配器，非严格ArkTS编译证明。 |
| `esbuild_prefix` | `runtime/ohos/node/build-tools`既有锁的独立npm-ci安装，固定esbuild0.27.3。不修改node目录。 |
| `native_library_dir` | 两个Linux夹具库`libdsh_flock.so` / `libdsh_require_builtin.so`。前者可从固定flock.c用本机编译器构建，后者可用固定Linux require-builtin addon；都不得进HAP。publication/opener/zlib夹具由入口本轮重新编译。 |
| `ohos_headers` | host-adapter要求的公开native_api/common与hilog/log头，来源需保留，不能拿自造空头当原API。 |
| `node_source` | 同版本官方Node源码中的`src/node_version.h`及完整`deps/undici`；先核官方归档校验，入口只私拷这些输入，不编译或修改用户node源。 |
| `lifecycle_before_route` | 原HTTP回归要求的真实530 lifecycle路由单文件前像；须保留出处/hash，不能用当前路由伪造前像。 |
| `image_size` | 原r7全量/optional profile测试固定依赖。 |
| `market_modules` | `market`既有锁的独立npm-ci安装的`node_modules`，供市场测试和`scripts/check.mjs`使用。 |
| `dart` / `flutter` | 能实际运行Linux消费者的完整SDK。仅版本输出成功不是执行证明；ZIP恢复时需保留可执行权限。 |
| `secure_fork` / `picker_fork` | 可选固定fork覆盖。未提供时按产品pubspec/lock正常解析；resolver产物保留。实际oh-flutter枚举存在ohos时才调用现有vendor生成器，普通Linux Flutter不注入不存在的枚举值。 |
| `app_fonts` / Flutter环境 | 应用真实字体，以及`DSH_TEST_FONT_DIR`指定的Noto字体。保留原全局测试配置和asset/shader构建，不用`--no-test-assets`绕过。 |
| `webview_original` / `fork_roots` | 固定WebView原包与机械桥接审计的实际fork根映射。错误原包/SHA仍硬失败。 |
| `path_provider_source` / `embedding_har` | 原native-media/clipboard测试要求的公开固定来源文件或HAR。 |
| `sdk` / `java_home` / `sdk_cache` / `sdk_resources` | API26 SDK、JDK、固定hvigor/embedding缓存，以及明确标记的五张缺失编译资源PNG。入口私拷缓存，调用普通`check-arkts --hms-stubs`，不写共享work，不调用full/clean。 |

OH组成输入准备：

```sh
python3 -I -B runtime/ohos/package/prepare-inputs.py \
  --target ohos --node "$GATE_NODE" --npm "$GATE_NPM" \
  --cache "$GATE_NPM_CACHE" --out "$GATE_PREPARED"
```

Node/npm、两锁及安装参数来自 `composition.json`（包含omit-optional、hoisted与install-links）。完整npm缓存存在可加原`--offline`；入口验证逐文件receipt后独立copy2，不用可写硬链接。Android pristine独立安装且保留optional。入口从它复制不同目标前缀，每次 `patch-dsh` 明写 `--target android` 或 `--target ohos`。

环境必须允许本机端口、子进程、编译及原权限负控。proc-mapping-tools核父进程`/proc/self`链接与status/stat的PID、NSpid末项与实际进程PID、namespace和多次读取的稳定starttime；经过身份核验的外层procfs PID可与信号PID不同，缺失/变化/不一致仍BLOCKED。匹配的freeze控制器还须自行核child自报PID、PPid、namespace、starttime及真实停止状态；前置通过不代替这些断言。root但没有setuid/setgid能力时，相应降UID组BLOCKED，不能删除EACCES断言；不能枚举真实非loopback接口时，原网络路由组同样BLOCKED。`ownedHttpHost`须是调用者明确拥有的本机非loopback地址，不能代填公网地址。

## 覆盖与依赖

| 组族 | 执行范围和主要前置 |
|---|---|
| target/Android | 全pristine、基底；三独立目标树完整bytes/mode/link比较、重复apply、错误target拒绝且零写；composition-android另外跑真实build-runtime两ABI版本配方。外部归档为两边同样的合成字节，非APK/rootfs成品字节证明。 |
| 组成 | 固定prepared receipt、RE2/esbuild；真实compose、manifest/archive/import审计、实际组成payload过程矩阵。 |
| Host/ADD13 | headers、publication与native库、真实组成payload；Host::Start预检、profile、strict完整回合、bridge/MCP路由。开发prefix不能替代组成物门。 |
| 网络 | 原四个shell矩阵、bootstrap、Node fetch source/build/Abort/FormData；builtin组明确单独fetch_node。 |
| process/Git/rg | fulloptional OH测试前缀及process依赖；原process两shell、Git/owned双模式、M4固定oracle、gitfile本轮native录制与双重放、description五分支、全有效标量比较；降UID组另需权限。 |
| publication/lifecycle | 真native fixture；installed与locks/xattr、fuse/scanners、各独立lifecycle进程及crash/freeze/HTTP。strict锁仅约束子actor，外层协调器保持可spawn。 |
| deletion/schedule/upload | 本次compose生成的core/route、目录同步负控，以及独立实际prefix消费者。 |
| ArkTS通道 | 原files/media/PDF/voice/HMS-share、links/connectivity/notify/runtime/archive/managed-skill、secrets/attachments、clipboard、WebView及静态Dart桥接审计。718新增islands通道必须使用本轮prepare-forks的真实prepared fork；框架补丁器与installed-path合同单独必跑。embedding-member-identity逐个验证固定原HAR生成包的路径/类型/mode/内容，合法gzip编码差异不失败；错误源HAR仍硬拒。Linux API doubles仍是doubles。 |
| Dart/Flutter | diagnostics/performance真实Dart消费者；secrets/attachments、原预算/owner/callback及share_hosted目录完整测试，相关数据层analyze。 |
| native协议 | Android和OH选中prefix分别跑原完整run-native-tests；缺失dot.png和Host桥接proof.png由入口在私有树生成固定69B RGB PNG，逐项记录是否新生成和SHA，明确为新测试资源。 |
| 普通SDK | 私有输入/缓存运行严格ArkTS，保留原诊断和build identity；HMS stubs恒标UNCOMPILED_HMS，不代表官方HMS编译/设备。 |

`gate-coverage.json`仅列shell/Python内部间接调用的测试。两个明确排除项是旧f387 Android recipe历史比较与publication-fallback研究；本轮真实Android/当前publication门仍必需。gitfile oracle为本轮真实native录制，不冒称恢复历史记录；description前像按当前目标实际后续pin逐层逆向还原并逐层核hash。

成功结论只覆盖Linux控制链、真实Dart消费者和普通SDK的实际范围。设备权限、UIAbility/系统picker时序、HUKS服务、官方HMS能力、OH AOT、完整HAP及Android APK另验。性能消费者通过也不是启动性能提升结论。
