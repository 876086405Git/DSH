# 905：可供本机编入HAP的原生Python接线

本累计补丁以6459f947为基底，包含901-R2；不要先打901。901的probe仍保留作回归证据，正式入口是`host.c`、`host.mjs`、`host-worker.mjs`、`platform.py`和`loader.mjs`。正式源在Linux真实共享libpython3.12编译/运行；目标3.14.7、SDK clang15、HAP加载与设备行为仍待本机验证。不是把Linux结果标为OHOS结果。

## 最小产品语义

支持python/python3的`-c CODE [args...]`及工作区文件脚本（相对/绝对路径），独立作业argv/env/cwd，常见open/io/pathlib/os相对路径、SQLite相对文件名、stdlib import、明确CA的SSL/urllib HTTPS、UTF-8文本和二进制stdout/stderr、协作取消。真实测试验证正确CA访问成功，完全无信任根的SSLContext失败CERTIFICATE_VERIFY_FAILED。_ctypes必须编入，保留sizeof/结构/转换等；dlopen只接受宿主approvedLibraries绝对清单，默认不接受任意库。该清单不是用户argv/env字段。

子解释器内显式替换Python路径/环境入口，只影响本作业；没有改Node全局内建，作业不对App进程chdir/setenv。正式桥只在首次初始化前设置固定的 `SSL_CERT_DIR=/etc/security/certificates`，以供 OpenSSL 的 C getenv 使用；不是把用户 env 写进进程。主解释器只初始化一次；每作业在同一个Node Worker线程恢复主thread-state → Py_NewInterpreterFromConfig(shared GIL) → 执行 → Py_EndInterpreter → 恢复主state并释放GIL。新子解释器有新模块缓存；绝不Worker.terminate强杀运行中的C，绝不每次Finalize主解释器。线程/fork/exec在子解释器配置禁用，子解释器保留主allocator兼容已静态编入模块。

这**不是不可信代码安全沙箱**：Python/C扩展在App进程里，直接posix/ctypes等仍可能绕过Python代理或破坏内存。路径代理只保证列明普通入口的功能语义与授权范围；不能包装成完整OS隔离。宿主应按其已有工具授权选择该后端；需要强隔离/真实进程时选App Linux。不要因“不是沙箱”而宣称没有相对路径实现，本包真实测试已覆盖open/pathlib/chdir/SQLite。

明确限制：

- stdin尚未实现：非空写入在副作用前或写入时失败ERR_OHOS_PYTHON_STDIN；Python input/read同样明确失败，不返回假EOF。runtime ignore输入可以运行普通脚本。
- pip/-m尚未实现，ERR_OHOS_PYTHON_ARGUMENTS提示Linux；不会安装C扩展后假称原生可导入。901设计的纯wheel验证是下一阶段。
- subprocess.Popen及os fork/exec/system类操作明确ERR_OHOS_PYTHON_PROCESS，尚未接统一路由；不要把Node router可用误报为Python subprocess已可用。
- 普通路径入口已列在platform.py；dir_fd、裸fd的open、SQLite URI、link/symlink等明确拒绝。其他C扩展内部相对IO未经适配不能声称支持。SQLite非memory连接默认写权限，因此只读工作区也拒绝它；只读URI待专门实现。
- 取消是Python trace协作中断；长C调用或主动捕获中断的脚本无法承诺硬截止。实际close/done等作业结束，不伪造已经终止。
- 输出总量硬限16MiB，超出ERR_OHOS_PYTHON_OUTPUT_LIMIT；首段立即发送，后续按16KiB或约10ms（有写入时）合并，结束前flush，避免逐字符无限消息。不是无限流，也不声称原生反向背压；大的工具输出应写授权工作区文件或走Linux。二进制和stderr同样计入上限。
- 每引擎仅创建一个PythonHost lane。工厂的 `dispose()` 同步关闭新作业准入，协作取消活动作业，等待 `done` 和输出收集器封口，再等 owner Worker 的真实 `exit`。主 CPython 解释器仍不 Finalize，保持 quarantine；同一 App 进程不能重建该 lane，不能声称全部原生内存已释放。空闲 Worker 可以 unref，但 unref 不是退出屏障；后台冻结/恢复待设备。

## 统一命令入口

root统一router在RuntimeInstaller安装完成且Python资产存在后，**一次**调用：

```js
import { loadPythonRuntime } from './python/loader.mjs';
const python = loadPythonRuntime({
  runtimeRoot, workspaceRoots, temporaryRoot, readOnly,
  createCollector: (mode, label) => new OutputCollector(mode.maxBytes, label,
    mode.spill && { maxBytes: mode.spill.maxBytes, dir: temporaryRoot, onFailure }),
});
// 与现有VirtualSubprocessRuntime完全同形：
const handle = python.spawn(spec);
```

`spec.argv[0]`支持 python/python3/pip 及各自的 `/bin/`、`/usr/bin/` 绝对别名；cwd/env/stdio/graceMs仍来自当前统一运行时。pip 识别后仍明确返回 `ERR_OHOS_PYTHON_ARGUMENTS`，不自动切到 Linux。作业返回 stdin/stdout/stderr/control/collected/done/started/terminate/waitForExit；工厂公开 `live` 和幂等 `dispose()`。`started` 反映宿主接纳边界，不是作业完成；`done` 等原生末段输出和 collector 封口。loader不改全局 child_process。901-R2的abort-before-entry、幂等terminate和stdin拒绝全部保留。922 的统一路由对 read-only/workspace-write 仍返回 `ERR_OHOS_BACKEND_CONFINEMENT`，不提高原生 Python 的隔离能力。没有 bundle 时不能注册此工厂后把能力标可用。

922 的 owner 回归使用宿主真实共享 libpython3.12，以 pipe 输出检查取消前已产生的 stdout/stderr 尾部和 `/proc/self/task/<tid>` 中 owner OS 线程实际消失；不是用取消请求、unref 或逻辑 done 代替线程退出，也不是目标 OHOS 设备证明。collector 封口由另一个后端单测以显式 native/collector 替身覆盖，不属于此实库 owner 用例。协作取消不承诺所有代码的 finally 都能执行：宿主 3.12 单次取消对照中，单行 `while True: pass` 未产生 finally 尾部，多行循环产生尾部；3.14 目标行为待本机复测。

## 打包与精确构建

1. 采用 ohos10 新 REF 的完整依赖 libpython，精确身份和匹配 pyconfig.h 前置见 `BUILD-OHOS.md`。它由本机以 SDK7 clang15 将 OpenSSL3.5.9/libffi3.8.0/SQLite3.54.1 静态编入，zlib 使用手机系统 `libz.so`；本机已测四模块和显式系统目录 HTTPS。正式 Node 桥、子解释器与 HAP 组合仍待验证。需要重建时按该文件的更新命令，并为新产物记录新哈希。
2. 构建正式桥及验证五个必需模块、无版本SONAME、无RUNPATH、仅允许准确的系统 libz.so 例外和NAPI隔离：

```sh
python3 runtime/ohos/python/build-host.py \
  --sdk-native "$OHOS_SDK/native" \
  --python-source "$SRC/Python-3.14.7" --python-build "$BUILD/python" \
  --libnode "$NATIVE/libnode.so" --node-headers "$NODE_SOURCE/src" \
  --output "$BUILD/python-host"
```

输出`libdsh_python.so`和`libpython3.14.so`。桥用C/SDK clang15，不依赖libc++；强制include现有napi-rename.h，显式NEEDED libnode，禁止plain Ark NAPI；不改runtime/ohos/node。

3. 用**精确Python3.14.7**宿主生成stdlib zip（pyc legacy路径、hash失效模式）、CA和许可证。SOURCE Lib中数据文件也保留；剔除测试/GUI和native资产。依赖许可证完整文本及CA来源许可由本机提供，参数目录的文件名为CPython.txt/OpenSSL.txt/libffi.txt/SQLite.txt/zlib.txt/CA.txt；不得用本测试fixture替代许可证或证书。

```sh
python3.14 runtime/ohos/python/prepare-bundle.py \
  --stdlib "$SRC/Python-3.14.7/Lib" \
  --sysconfig "$BUILD/python/build/lib.linux-aarch64-3.14/_sysconfigdata__linux_aarch64-linux-ohos.py" \
  --version 3.14.7 --ca-bundle "$VERIFIED_CA_PEM" --licenses "$VERIFIED_LICENSES" \
  --output "$BUILD/python-bundle"
```

sysconfig输出目录随本机configure结果可能不同，须用实际构建文件路径；不得用宿主sysconfig。源码依赖版本/许可证逐项在BUILD-OHOS/DESIGN，本包不含依赖源码/外部CA/伪造hash。

4. 在原compose-runtime.py命令追加`--python-bundle "$BUILD/python-bundle"`。composer校验版本/每文件hash/大小，拒绝native命名/链接/重复名。它把zip本体作为普通runtime数据文件加入现有受校验runtime.zip。首次RuntimeInstaller按既有原子版本发布解包一次：Python zip保持一个文件，不再展开550个pyc，不建立链接。版本hash变更自然走新runtime版本；取消/清理复用已实现安装器，不另造ArkTS安装状态。
5. 把两个产物复制到本机用于DSH_OHOS_NATIVE_LIBS的目录。build-hap.sh只在发现任一Python库时要求完整两库，按固定白名单复制；不任意收集*.so。audit-hap.py要求native双库与runtime内Python manifest同时存在，检查NEEDED完整闭包及plain/renamed NAPI原规则，并拒绝libpython额外libssl/libcrypto/libffi/libsqlite3及版本化libz动态依赖；只有准确 `libz.so` 是本机已批准的系统依赖。缺一个库/缺stdlib不是降级成功。
6. 原build-hap.sh命令不变。本机跑完整门、交叉编译、HAP audit与设备验收：python3 -c print(1)、脚本相对读写、HTTPS正确/错误证书、SQLite、ctypes sizeof、多次执行、早输出/取消、后台冻结恢复。标准库Zip与API版本/真实符号隔离在设备再次核实。

## 证据边界

905先红对照是901真实probe不支持异cwd/env（red-901-cwd.log）。生产绿色使用同进程共享库实际执行，不exec Python、不伪造平台环境变量。9个生产测试、2个实际bundle/composer测试、1个loader篡改/路径测试、8个adapter回归及6个已有child-process边界测试；另跑既有composition archive 12和inputs17。run-gates登记全部新测试，但完整门未在沙箱运行。Linux实际证书由openssl CLI临时生成，只做本地回环TLS信任/拒绝验证；不是访问公网或设备网络测量。

## R2 独审修复

R1独审三个实红原件保留：unlink最终软链接被错误realpath成目标并删目标；用户from __future__声明因平台前缀拼接变SyntaxError；脚本同目录helper导入失败。R2按操作选择是否跟随最终路径分量：unlink/remove/lstat/readlink/rmdir/mkdir/rename/replace和exclusive/no-follow open保留叶子，授权检查仍解析父目录。link/symlink继续明确不支持。用户代码单独compile，正确建立__main__/__file__，不把平台适配文本拼到用户源码前；sys.path[0]使用脚本目录，-c的虚拟chdir更新其目录。

新增真实共享库回归覆盖上述三项及readlink/lstat、rename/replace、不存在目标的exclusive open。生产11PASS，独审原三断言复跑3PASS。不能使用已BLOCKED的R1。

## R3：尾斜杠与可信运行边界

R2独审抓到`os.utime('outside-link/', follow_symlinks=False)`仍可能由内核跟随末级目录软链接。R3对带尾斜杠的no-follow操作额外解析最终实际目录用于范围检查，同时保留传给内核的叶子和尾斜杠；不通过删除斜杠改变unlink/rename语义。真实回归确认外部目录mtime逐字未变，独审原两案2PASS，生产13PASS。

`createPythonRuntimeBackend.capabilities`明确`{confinement:'none', trustedOnly:true}`；提供`spec.policy`时直接ERR_OHOS_PYTHON_CONFINEMENT。router必须在消费prepare票据时拒绝选择Python或交给具备相应约束的Linux实现，不能清除policy后转交。旧runtime把policy保存在内部票据而不放spec的路径，更需要router在票据解析处执行这一判断。无论read-only还是受限workspace-write，本Python后端都不提供强约束。

路径代理还存在检查与使用之间的TOCTOU，直接C/posix接口也可以绕开它。因此roots/readOnly用于可信脚本的功能语义/误用保护，不是安全授权实现；不得把全局可写lane接给既有受限工具任务，不能因为本次修复一个范围反例就提升为沙箱能力。只有明确不要求这些限制的可信执行入口可以注册。该限制必须在root统一router中保持，不能隐式降级以求可执行。

## 922-R2：宿主动态扩展、证书夹具与失败观察

本机完整门的Python3.14原始stdout显示，`_dsh_install`导入sqlite3时，其动态 `_sqlite3` 扩展报 `undefined symbol: PyList_New`。默认局部加载addon虽能调用所链接的libpython，却不能向另行加载、未显式链接libpython的扩展提供公共Python ABI。正式host与owner Worker现在都以 `RTLD_NOW | RTLD_GLOBAL` 打开既有可信addon；仍只接受宿主给出的固定addon路径，没有新增来自argv/env的库选择入口。OHOS静态内置扩展要求、NAPI隔离、系统libz.so例外及目标3.14.7库身份不变。

新增实际C扩展回归有意不链接libpython，保留未定义的 `PyList_New` 等公共ABI符号。相同addon/libpython/扩展字节在旧loader下实际导入失败，在新loader下于两个新子解释器中成功导入并返回空list。沙箱宿主为CPython3.12.14；其首个未解析符号是 `PyModuleDef_Init`，与本机 `_sqlite3` 的首个符号不同，因此这是相同符号可见性机制的实证，不冒称已重放本机3.14的原二进制。

本机日志中的15秒“dispose”用例超时发生在等待owner线程marker阶段，当时尚未调用dispose；另一用例只等待stdout而没有观察作业已失败，可以拖至门的120秒上限。测试现在把marker/首输出观察与真实 `job.done` 结局竞速：作业提前结束即保留退出结果和原始stderr，明确失败并停止等待；成功路径仍等待真实owner线程exit。额外两个真实Python错误作业验证这一失败路径，未把运行错误改为通过或缩短产品取消语义。

宿主TLS负向输入改用**实际存在的空目录和空CA文件**，仍无信任锚。不存在目录会使同进程Node的系统CA扫描报 `Cannot open directory`，该警告本身在实际单独重放中退出0。空store保留证书验证强度：故意省略C初始化的CA目录编译宏时，真实系统CA HTTPS回归仍失败 `CERTIFICATE_VERIFY_FAILED`；正常宏下成功。正式手机入口继续在初始化时设 `/etc/security/certificates`。

定点入口仍为：

```sh
"$HOST_PYTHON" -I -B runtime/tests/ohos/python-native.py \
  --production --node-headers "$NODE_HEADERS" --output "$NEW_TEST_OUTPUT"
```

`HOST_PYTHON` 必须是本机可运行、与其开发头和共享库一致的Python；不是OHOS AArch64的REF库。脚本从该解释器的sysconfig/base_prefix取include、stdlib和共享库，从PATH解析实际cc/openssl/node，写 `host-inputs.json` 保存精确路径、编译argv、库/产物SHA及证书目录角色。`NODE_HEADERS` 是对应宿主Node的 `src` 或发行headers的 `include/node`。输出需使用新目录，临时TLS私钥只用于该本地回环测试，不进入交付包。目标SDK的源码Include、匹配pyconfig.h、REF共享库和stdlib/CA/许可证资产仍按前述BUILD-OHOS与构建命令提供；本轮宿主定向通过不能替代本机Python3.14、SDK、HAP或手机复跑。
