# 930：App 内 Linux 控制接线与本机验收

本件承接已复核的922组合，补上可供本机编HAP、从App数据通道和鉴权HTTP启动测量的路径。源码包含不等于设备通过；本环境没有OH SDK、oh-flutter AOT或手机，ArkTS编译、HAP加载、后台行为及实际网络性能仍由本机核实。没有运行或准备完整统一门。

## 实际接线

RuntimePaths.linuxDirectory 固定为 App filesDir/linux-tools。RuntimeController.start 创建该目录并传给 HostOptions.linuxDirectory；N-API和HostCore要求它是现存、无链接的规范绝对目录，不能与已发布runtime根或DSH guest根双向嵌套。宿主只通过受保护的 DSH_GO_OHOS_LINUX_DIRECTORY 交给唯一preload，Dart传入的env不能覆盖它。

runtime/ohos/preload.mjs 在插件执行前捕获宿主目录与原生库目录。实际OH SubprocessRuntime 注册 /dsh-go/v1/linux，复用已有connection的token→cookie与请求鉴权。后续插件改env不改已捕获的目录；Worker不拥有第二个Linux owner。GET不读资产、不联网、不导入原生库、不建立VM，App状态查询也不调用运行时安装/恢复的initialize()。

签名runtime内的六资产入口固定为 runtime/ohos/linux/assets/；首次显式开启才读取清单、下载固定华为源归档、校验字节并安装。实际opened后才开放作业准入，目录、库或HTTP202存在均不能作READY。下载和安装进度来自实际阶段；开关关闭在安装中触发取消。已发布可写instance不会被停止操作删除，也不会在下次开启时被新安装覆盖。

本次运行命令的入口明确名为runPrivateGuest，cwd只能显式写 /workspace。它是guest私有目录，workspaceLease始终为false。用户选择的文件夹、宿主cwd、插件通用shell和stdio MCP尚不经过此入口；没有隐式转到Linux或改写任何Node内建模块。

实际VM曾复现覆盖预置needle.txt时EACCES：目录root:root0777可建文件，但文件root:root0644不能由降权任务覆写。修复只在首次可信tools解包后，将guest私有/workspace初始化给固定作业UID/GID60081，根目录设0700；失败走原安装失败路径。后续启动不重置用户权限，任务仍按原合同降权，host授权范围不变。

## 三种完成事实

| 事实 | 使用方必须观察的条件 | 不能替代它的信号 |
|---|---|---|
| guest可接受任务 | admission=true，来自同一真实opened backend | 文件存在、下载完成、开关请求已接受 |
| 作业完成 | 对应requestId的job settled及真实outcome；输出按backend合同收尾 | HTTP202、socket断开、UI已显示文字 |
| 最终资源退役 | shutdownComplete且retirement.resourcesRetired；有native时须joined=true且retirementError=false | 请求停止已发出、job结束、任意超时 |

普通Linux开关false先关准入；已有backend时进入现有shutdown屏障，取消并等待private/routed job、guest close与真实join。该VM生命周期结束后再次true必须重启App，不创建第二VM。最终引擎停止复用同一shutdown屏障，等真实资源退役后才调用NativeHost.stop。并发stop共享同一个屏障；reset也先等屏障，再写durable reset意图。停止确认失败会抛稳定错误，不先写reset.json或假装Node已安全停止。

历史job UNKNOWN可以与之后真实资源join同时存在，join不会把UNKNOWN改成exitCode=0。未join时native的retirementError/apiResult可以为null；ETS与Dart保留这些未知事实。VM/native owner仍按既有一次性隔离合同保留，没有声明全部VM内存释放或同App重新初始化安全。

本期保留跨App的已安装数据，但尚不恢复启动；发现保留instance时明确拒绝新安装。已有bootstrap安装配置再次启动会重新解包覆盖target，不能复用作恢复配置。guest closed当前也不代表文件系统已sync；资源退役不构成掉电耐久或干净恢复证据。后续恢复必须另以干净关闭事实、新epoch、实际target身份和直接启动配置建立合同。

## 给本机Flutter界面的数据接口

仅新增OH专用 app/lib/runtime/ohos_linux_runtime.dart；没有修改共享Android UI、状态provider或入口。界面可以在OH平台接入OhosLinuxRuntime。三个MethodChannel方法均使用已有dsh/runtime通道：

| Dart方法 | ArkTS方法名 | 返回 |
|---|---|---|
| getStatus() | getLinuxStatus | 完整typed snapshot |
| setEnabled(bool) | setLinuxEnabled | 受理后的snapshot，安装可能仍在进行 |
| runPrivateGuest(scope, argv, cwd, environment, stdin) | runLinuxPrivateGuest | 同一requestId的snapshot |

状态含实际progress、最近一个job、两个有界字节尾部、取消事实和retirement。每个输出流最多保留16KiB，totalBytes与当前保留长度分开；bytes保留原始字节，text仅作允许替换非法UTF-8的显示用途。它不是无限日志或完整文件传输接口。

    const linux = OhosLinuxRuntime();
    await linux.setEnabled(true);
    // 界面按需查询并展示实际progress；不要以这个Future返回判定安装完成。
    final scope = await linux.getStatus();
    if (scope.admission) {
      await linux.runPrivateGuest(
        scope: scope,
        argv: ['python3', '-c', 'print(1)'],
        cwd: '/workspace',
      );
    }

一次作业的scope固定instanceId/attemptId/nextRequestId。传输结果不确定时保留原scope和完全相同的参数，先查状态，必要时仍用原身份重试；不可重新GET后换nextRequestId重做有副作用的命令。同号同参返回原作业，同号异参/旧号拒绝。Dart、ArkTS和Node不自动换号重试。

取消本期唯一当前作业用setEnabled(false)；随后展示真实取消/退出结果。错误保留稳定code；UNKNOWN必须显示未确认，不能写“成功”。完整字段、界限、身份与HTTP合同见 runtime/ohos/linux/CONTROL.zh.md。

## 构建输入与命令

下面路径均为构建机输入/输出示例，需替换为本机的真实固定输入。已有922所需Node24.22.1、renamed N-API、主线libnode工具链及完整CPython输入继续沿用。本件不修改runtime/ohos/node/，不把Linux宿主--host-test库放入HAP。

### 1. 构建可进入HAP的TinyEMU库

在本机已准备的原生库集合上构建实际OH目标：

    cmake -S runtime/ohos/linux/native -B /build/linux-oh -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE=/sdk/native/build/cmake/ohos.toolchain.cmake \
      -DOHOS_ARCH=arm64-v8a \
      -DDSH_TINYEMU_ARCHIVE=/inputs/tinyemu-2019-12-21.tar.gz \
      -DDSH_NODE_HEADERS=/inputs/node-v24.22.1/src \
      -DDSH_NODE_LIBRARY=/build/arm64-v8a/libnode.so \
      -DDSH_NODE_RENAME_HEADER="$PWD/runtime/ohos/node/napi-rename.h" \
      -DDSH_OH_SDK_NATIVE=/sdk/native
    cmake --build /build/linux-oh
    cp /build/linux-oh/generated-linux/libdsh_linux.so /build/arm64-v8a/libdsh_linux.so

如从头构建完整原生集合，沿用runtime/ohos/native/build-hap-libs.py的全部现有参数并加--tinyemu-source /inputs/tinyemu-2019-12-21.tar.gz；该入口会把库纳入既有ELF/renamed-N-API审计。C TinyEMU库不新增C++运行时。SDK clang不能据此替代主线libnode的新clang与自建libc++。

### 2. 构建六资产和runtime ZIP

在有Python、tar与mke2fs的构建机上，固定工具包获取/解包脚本为tooling/ohos/research/linux-job/prepare-inputs.py与build-image.py，31件APK的实际文件及SHA在同目录packages.lock.json。它们是构建机步骤，不能在手机App沙箱执行，也不要执行归档中的安装脚本。工具树与来源许可记录应来自本机批准的输入；本件没有新增依赖版本或把宿主TinyEMU许可替代guest组件许可。

    python3 -I -B tooling/ohos/research/linux-job/prepare-inputs.py \
      --out /inputs/linux \
      --alpine-mirror https://repo.huaweicloud.com/alpine
    python3 -I -B tooling/ohos/research/linux-job/build-image.py \
      --inputs /inputs/linux --agent runtime/ohos/linux/guest-agent.py \
      --output /build/linux-tools
    python3 -I -B tooling/ohos/build-linux-assets.py \
      --diskimage /inputs/linux/diskimage-linux-riscv-2018-09-23.tar.gz \
      --alpine /inputs/linux/alpine-minirootfs-3.24.4-riscv64.tar.gz \
      --tools-root /build/linux-tools/root \
      --agent runtime/ohos/linux/guest-agent.py \
      --output /build/linux-images

固定下载失败/哈希不匹配必须修正输入来源，不能删校验或替换清单为服务器自报值。实际手机首次使用仍只下载固定base归档，工具、固件和两压缩盘随六资产发布。两512MiB未压缩构建中间盘不会进入HAP。

按runtime/ohos/package/LINUX-ASSETS.zh.md的完整命令生成真实prepared收据并组合runtime；在原compose-runtime.py --target ohos命令中增加：

    --linux-assets /build/linux-images/assets

输出是该组合目录的dsh-runtime-rawfile.zip。六资产参与实际payload清单、runtimeVersion、ZIP回读与RuntimeCore清单消费者校验；无资产的旧组合路径保持。旧922 prepared收据可在其固定依赖输入不变时复用，不能手写收据或省略核验。

### 3. HAP

    FLUTTER_OHOS=/tools/flutter-ohos/bin/flutter \
    DSH_OHOS_NATIVE_LIBS=/build/arm64-v8a \
    DSH_NODE_HEADERS=/inputs/node-v24.22.1/src \
    DSH_OHOS_RUNTIME=/build/runtime-with-linux/dsh-runtime-rawfile.zip \
      tooling/ohos/build-hap.sh --release --distribution device

签名文件、别名与密码按本机既有DSH_OHOS_SIGN_*注入；不要把它们放命令行、日志或交付包。此命令使用既有macOS oh-flutter AOT/HAP流程；本环境未执行。资产存在而缺libdsh_linux.so会在SDK交接前拒绝；最终HAP审计还会再核配对与字节身份。仅有库的922诊断构建继续允许，但运行态缺资产不能READY。

## 证据与验收范围

本件的机器可核原始命令、输入SHA、stdout/stderr、先红后绿、独立复核报告随正式ZIP交付。真实host N-API、TypeScript转译后的实际ETS方法、实际Dart、真实本地HTTP、真实TinyEMU与手机是不同测量层，报告分别标明边界替身，不能互相代替。

以下是原930/931组合路径已在真实TinyEMU中完成的17项历史检查；普通off/on合同在追加10后已改变，历史原数不冒充1289新候选结果。使用实际BrowserAuth、HTTP、生产control/owner/backend和native/guest；唯一替换是归档下载传输，流入已核SHA的真实Alpine归档，不能据此声明华为源或手机网络通过。

| 用例 | 本次宿主真实guest观察 | 本机验收要求 |
|---|---|---|
| python3 -c 'print(1)' | stdout为1加换行，exitCode=0 | 同样输出，并记录实际耗时 |
| gh --version | gh version 2.97.0 (2026-10-14)，exitCode=0 | 版本与本机所用锁定资产一致 |
| rg私有文件 | beta needle加换行，exitCode=0 | 用已写入的确定内容核结果 |
| git clone本地空bare仓库 | 工作树rev-parse为true，退出0；有正常空仓库warning | 此结果只覆盖本地空仓库，远程非空仓库另测 |
| gh pr list | NOT_RUN | 本机显式提供真实账号与目标仓库，不在交付包中保存凭据 |
| off/on（历史原数） | owner创建数1、下载数1；epoch、target和实际data FD保持 | 新合同为普通off等join且须重启App再开；本行只保留旧观察，新候选量化另验 |
| 取消运行中任务 | requestedSignal=SIGTERM；实际signal=SIGKILL、exitCode=null、cancelled=true | 展示实际结局，不把请求的信号当实际退出原因 |
| 最终shutdown | native joined=true、retirementError=false、apiResult=-4；所拥有的data FD数回到0 | 必须观察真实屏障，不以202或超时替代 |

最终关闭的filesRemoved=false、dataRetained=true、ownerQuarantined=true：保留可写镜像与隔离owner符合本期合同，不表示整个VM堆已释放。跨App恢复及guest同步另列未完成。

受影响ETS/RuntimeChannel合跑86/86绿，实际Dart21项检查通过；独立RuntimePlugin环境变量probe保留原3/4红与修复4/4绿。真实host N-API目录合同、两个实际DSO与原C++范围测试均有原始记录。保护边界复核确认Android target pins与diff输入、实际Android版本配方及受保护目录未变；这里没有重复运行完整Android构建或统一门。

设备测量脚本与详细命令在tooling/ohos/linux-device-measure.mjs和同名.zh.md。脚本有12项宿主HTTP定点绿，包含初始检查后被其他客户端抢号的实红→同测绿。它另以冻结字节接入实际guest控制链：两个Node进程、66.643秒、默认8项PASS与2项NOT_RUN、13项生产者/消费者交叉核对通过；退休与data FD清零先于harness清理。真实账号与HTTPS远程clone仍未运行。使用脚本须保证独占测量窗口：当前GET到后续owner级off/shutdown不是原子租约，不能声称任意多客户端并发均被隔离。

设备至少验：首次安装实际进度/取消/失败清理；python/gh/rg/小仓库clone；普通关闭取消当前job并等真实join，再开要求重启App；最终App引擎关闭等真实join；未知状态不误报成功；DSH主引擎/rootfs与Android产物不受影响。gh pr list的真实账号和远程仓库访问由本机显式提供，默认测量不执行账号操作。

完整统一门按tooling/ohos/run-gates.py的新增登记由本机执行。已知设备待验证项是SDK26 HTTP拦截器/头表示、oh-flutter Map桥接、HAP native加载、首次华为下载和耗时、后台冻结/保活、TinyEMU实际内存与功耗。任何设备失败保留实际状态与原始输出，不由宿主通过推断修正为通过。
