# 901 — 原生Python快车道：可执行接缝与产品边界

本轮在Linux真实libpython3.12共享库上编译C Node-API探针，Node Worker中执行Python；不是shell启动python、不是伪stdout fixture。提供`createPythonBackend`和显式测量入口`createPythonProbeHost`。它们不自动注册生产。产品CPython3.14.7设备探针23–30ms初始化/三次再初始化/原生速度事实来自本机REF，本轮未重复真机测量。

## 能直接决定下一步的结论

选择Node侧C Node-API桥：强制包含现有napi-rename.h、只链接libnode公开dsh_napi_*；C代码无需clang23/libc++，SDK clang15可编。Ark侧只通过既有libdsh_host，绝不新建导入Ark plain NAPI的libdsh_python.so。并入libdsh_host可省一个addon文件，但必须另建线程安全纯C job API，不能混用两套napi_env；正式首版更易审计的是Node addon。扩展与OpenSSL/libffi/SQLite静态进libpython3.14.so；ohos10追加1批准使用鸿蒙系统libz.so，构建身份见BUILD-OHOS.md。

## 本补丁实际支持矩阵

|能力|Linux实际实现/验证|产品状态|
|---|---|---|
|python/python3 -c、绝对脚本路径|真实Python执行、argv按数据编码|probe可测|
|绝对路径文件读写|真实open写文件再Node读回|probe可测；不是授权沙箱|
|stdout/stderr/退出码|分开、异常/SystemExit分别处理|probe文本实时流式（early/late实测）；无二进制buffer|
|多次调用|常驻解释器、每次新globals|模块缓存仍共享；不是新进程隔离|
|取消/超时|trace中KeyboardInterrupt；Node循环保持响应|只协作取消，C阻塞期间不保证时限|
|任意cwd/env|显式ERR_OHOS_PYTHON_CWD/ENV|待解释器专用平台适配|
|stdin、二进制stdout.buffer|probe未实现|产品host契约需实现，不能宣称MCP就绪|
|pip/-m|统一adapter映射pip为-m pip|probe明确ERR_ARGUMENTS；未安装pip|
|subprocess|本文规定路由设计|未实现，不宣称可运行|
|安全隔离|probe执行可信测量脚本|不能运行不信任插件；os._exit/ctypes可终止App|

`probe-host.mjs`是显式测试/测量入口，不是生产后端发现逻辑。它不接受不同cwd/env，且不修改Node的cwd/env/内建。原生probe也不防恶意Python；产品不得将它接给智能体任意脚本。直接run的无回调模式用StringIO；probe-host实际使用写回调，经Worker消息实时输出，但队列未限制总内存，只可跑本包小测量脚本。产品host需要有界流队列和磁盘spill，超过限制明确错误，而不是悄悄截断。

## 标准库和首次安装

HAP rawfile放`python314.zip`、版本manifest、pip纯Python wheel及许可证/证书文件；nativeLibraryPath只放签名过的库。zip可直接import，不需要解包550个pyc：第一次使用按版本复制到filesDir/python/3.14.7/<content-hash>/临时文件，校验清单SHA256、fsync文件并rename，再发布ready清单。复制阶段进度以字节计数，可以取消，失败只清理临时文件。旧版本在无作业使用后删；不覆盖正被解释器读取的zip，不建立软/硬链接。

需实体文件的pip资源、证书和site-packages逐个安全解包：拒绝绝对路径、..、链接和重复目标；目标必须属于私有版本目录，写临时文件再rename，关闭所有FD后发布。纯Python包保留.py和数据文件，不能只取.pyc；importlib.resources常需数据。标准库按REF用完全相同3.14宿主compileall(legacy=True)，保留encodings/importlib、_sysconfigdata与pip所需venv/ensurepip策略说明（不盲目照probe裁掉全部资源）。产品PyConfig_InitIsolatedConfig，明确home、module_search_paths、argv、install_signal_handlers=0，不采纳App进程PYTHONPATH。证书使用明确打包CA路径并验证HTTPS成功/错误证书失败，不得verify=False。

## 生命周期与运行隔离

推荐一个永久主解释器的专用原生线程，作业串行；每作业子解释器以Py_NewInterpreterFromConfig创建，禁fork/exec、禁daemon threads，检查所有静态扩展的多解释器支持。不能简单把PyGILState_*混进多解释器线程状态；由明确PyThreadState管理GIL。本轮probe是主解释器+新globals，不等同产品子解释器。

本机三次Py_Initialize/Finalize成功只证明那组probe可重入，不能证明所有扩展/线程/缓存可无穷重入；不每条命令Finalize。产品只在所有作业和Python线程退出后做最终teardown，冻结/恢复不Finalize。子解释器也不是安全边界：cwd、环境、C全局和原生内存仍在App进程内。

cwd应成为作业值而非chdir；专用解释器内适配os/pathlib/io入口可支持常见纯Python文件操作，环境映射不得调用putenv。要维护完整路径API清单，先支持绝对路径与授权根，拒绝未分类的相对路径能力。SQLite的C文件IO需独立VFS或强制绝对数据库路径；_ctypes允许调用已签名已批准库也仍可破坏进程，不得宣传安全沙箱。平台适配可放专用Python模块/定制stdlib中，无须改全局Node builtin。实现并测试前保持生产不可用；用户可选Linux执行同一命令。

## 共用分发契约

`createPythonBackend({native}).supports(name)`识别python/python3/pip；`spawn(command,args,{cwd,env,signal,timeoutMs})`提供Child-like stdin/stdout/stderr和exit/close，供共用process分发适配。native.contract须为dsh-python-1；native.start接结构化argv/cwd/env、stdin流及分开stdout/stderr字节回调，返回completion与cancel。完成必须在最后字节之后；close不能在取消请求时伪造。timeout只是请求协作取消，C阻塞不宣称硬截止；SIGKILL明确拒绝并提示Linux。

Node原生线程用TSFN投递输出，Python线程通过带上限队列同步读stdin；生产consumer应等两个输出EOF、原生线程实际退出/作业资源清理后resolve completion。Node退出前需async cleanup hook等待原生线程；不能直接Worker.terminate杀正在C调用的线程。probe不做生产线程关闭。

Python subprocess的正式接缝是在专用stdlib的Popen实现中调用内建_dsh_process桥，以结构化argv/env/cwd/stdio映射统一分发，不拼接shell字符串。shell=True只有明确交给虚拟bash。stdin/输出流、wait/communicate/timeout/terminate均复用job契约；stdout=PIPE真正流式。拒绝preexec_fn、pass_fds、exec/fork、真实PID/信号假象；Popen.pid不能伪造OS PID。节点递归python调用必须单独调度或拒绝重入避免主作业等自己队列死锁。尚未实现时错误码ERR_OHOS_PYTHON_SUBPROCESS并提供Linux路径。

## pip与C扩展

产品pip命令只能安装匹配py3-none-any/py2.py3-none-any等纯Pythonwheel，固定`--only-binary=:all:`与私有target；还必须检查wheel WHEEL/RECORD中的平台标签及.so/.pyd等native payload，拒绝sdist和PEP517构建回退。仅加--only-binary并不充分：CPython默认tags可能接受本平台二进制wheel，必须限定支持tags/验证全部依赖。requirements/直接URL/本地wheel同样检查，不能让用户参数覆盖规则。

拒绝应为ERR_OHOS_PIP_NATIVE_EXTENSION，解释此包需要本机未签名C扩展/构建工具，建议在App Linux执行原命令或连接电脑；不自动安装到另一环境后谎称原生可import。若后端Linux未就绪，明确不可用。纯Python安装也可能有入口脚本，需命令清单分发，不生成symlink。当前probe无pip，不宣称已经支持pip install。

## 许可证清单与新增依赖理由

|组件|固定候选版本|许可证/分发动作|理由|
|---|---|---|---|
|CPython|3.14.7|PSF License及发行LICENSE中历史授权；保留完整LICENSE|已批准原生解释器|
|OpenSSL|3.5.9|Apache-2.0；保留LICENSE/NOTICE（若源码包含）|_ssl/_hashlib与HTTPS必需；本机新REF|
|libffi|3.8.0|MIT；保留LICENSE和版权|_ctypes必需，回调可执行内存仍待设备验证；本机新REF|
|SQLite|3.54.1|Public Domain；保留来源声明|_sqlite3必需；本机新REF|
|zlib|目标SDK/系统libz.so|Zlib；保留实际来源版权/许可证|新REF的系统动态依赖，不从guest复制|
|pip|未选择/未引入|MIT与vendored多种许可证须锁版本后逐项保留|后续纯Python安装器，不能省略vendored notices|

上述依赖没有复制源码进本补丁，没有新npm运行时依赖。构建候选是明确建议，正式源码锁和本机安全审核未完成。官方依据见BUILD-OHOS.md；CPython生命周期官方文档警告Finalize重入及扩展状态，子解释器不能隔离C全局。Node-API官方文档说明TSFN/异步工作仅可在对应线程使用env和值；本实现只在所属Node Worker线程调用NAPI；Python write在该同线程调用JS回调，parentPort将字节投递主Node线程，不跨线程复用env。

## 现有Runtime facade（已实现）

`createPythonRuntimeBackend({native, createCollector}).spawn(spec)`严格复用现有argv/cwd/env/stdio/graceMs形状，返回stdin/stdout/stderr/control/collected/done/terminate/waitForExit。宿主注入`createCollector: (mode,label) => new OutputCollector(mode.maxBytes,label,mode.spill && {maxBytes:mode.spill.maxBytes,dir:temporaryRoot,onFailure})`，从而复用现有spill/输出上限；没有重复造另一套collector。control pipe明确拒绝。done等close才settle，collector seal失败会reject。graceMs不是硬杀计时器，嵌入Python无法强杀C调用。生产未注册，因此统一router只能在显式可信host可用且授权校验完成后选中；不得仅凭supports就把不可用能力标成功。
