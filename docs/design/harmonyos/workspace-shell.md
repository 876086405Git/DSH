# 913：目录 FD 租约的 Node 消费者与虚拟 shell

913是911的累计后继；从6459f947应用本累计补丁，不要再叠加911。它实现了固定虚拟挂载下的真实shell文件命令与原生租约生命周期。**root910仍负责生产任务消费、虚拟cwd准入及固定preload接线；本补丁没有改runtime.mjs、worker.mjs或主preload，也没有接Node脚本/Python/git/Linux9P。** 本文不把单独Bash消费者测试写成整个App P1完成。

## 可信接线合同（910必须执行）

固定主preload在plugins/preload和任何用户Worker之前调用：

```js
import { createGrantAuthority } from './process/files/authority.mjs';
const authority = createGrantAuthority({
  hostLibrary: trustedNativeLibraryDirectory + '/libdsh_host.so',
});
```

`hostLibrary`来自可信原生启动状态。主环境先装载固定签名addon，再通过RTLD_NOLOAD查找已存在的libdsh_host；不运行另一份host，不从URI/candidatePath取库或工作区路径。生产Node loader使用既有`@dsh-go/ohos-native`固定白名单product `workspace-grants`。Node worker不获得任意原生库加载参数。

此调用在原生addon中永久捕获唯一owner napi_env；之后issue/retire要求同一env。owner结束时永久封闭，不能被Worker重新认领。Worker可consume随机一次性ticket，不能通过id/gen直接Acquire。只比较env身份，不跨env调用N-API。首次bindOwner本身依赖上述固定启动顺序；不得把这项初始化推迟到已有不可信Worker之后，也不把任意主线程插件/native代码当已隔离对手。

曾评估`uv_default_loop`主线程判断，但实际node_runner使用专用嵌入环境，且libnode-exports.map明确隐藏uv_*，因此没有采用或扩大导出。公开Node-API只保证napi_get_uv_event_loop返回该env的loop，不证明它等于任意宿主默认loop。

每次任务只在消费真正policy后签发：

```js
const job = authority.issue([trustedGrant], {
  readOnly: consumedPolicy.mode === 'read-only',
  workspaceRoot: consumedPolicy.workspaceRoot,
});
// trustedGrant = {id: actualNativeKey, generation, writable, mountPoint}
// mountPoint固定为 /workspaces/<UUID>
// Worker构造参数仅附上一次性token，不附任何宿主根或URI。
workerData.dshOhosWorkspaceGrants = { mounts: job.mounts };
```

**首版只接受一个grant，且policy.workspaceRoot必须精确等于mountPoint。** 缺失、更窄子目录政策、跨grant任务均ERR_WORKSPACE_SCOPE_UNSUPPORTED；不能把仅授权cwd子目录的任务上扩到整个grant。cwd可位于这个已授权根下。更窄政策需要以后原生pin task子目录，当前未实现。

生产Worker使用filesystem.mjs现有入口，自动读取固定workerData字段；此字段只能由可信factory放入，不能从spec/argv/env透传。Node脚本、Python、git、9P尚无该文件消费者，root910须对访问这些虚拟mount的请求明确拒绝，不能转成宿主裸路径。只有内部shell Worker带grant时，factory才以可信值覆盖DSH_GO_OHOS_NATIVE_LIBRARY_DIR；普通无grant Worker和Node脚本保持原scrub行为。

## 生命周期：退休与实际退出分开

父端先issue，原生立即登记一个等待中的lease；token由Node crypto.randomBytes(32)产生，绑定grant id、generation和任务RO/RW。最多256个未清退ticket。Worker consume只能成功一次。失败或未消费的ticket也可退休并实际释放，不等待虚构的Worker。

- Worker构造失败：调用job.retire()；返回true表示资源已释放。
- 取消：先job.retire()停止该task后续文件操作，再发实际Worker终止。false表示仍有已消费lease，不是取消失败，也不能当done。
- Worker真实exit：再次job.retire()必须为true；addon的env cleanup已经释放实际lease。保留异常/false为未决，不伪造清退。
- authority.close()退休自己所有job；返回值有同样含义。不能只丢弃JS引用。

原生task退休不退休整个用户grant；其他独立task不因此失效。任务每次IO仍检查task active和grant active/代际。原生锁覆盖同步系统调用；在途IO完成后退休才返回，未宣称有界取消。同步文件操作在内部Worker执行，不把大量文件IO放回Node主线程；父端退休遇到在途慢IO仍可能等锁，需要设备验证/后续队列设计，不能宣传取消瞬时完成。

消费后的lease由真正Node环境cleanup hook释放。外部JS handle保持私有；GC finalizer与cleanup防止重复release。Worker提前终止、未消费、正常退出、重复消费、部分filesystem构造失败都实测真实FD/lease结果。

## 文件行为

NativeGrantFs挂入现有MountableFs，路径是虚拟`/workspaces/UUID`，不能通过cwd真实路径转换绕到手机宿主。实际C ABI固定在911同一个目录FD owner上。913扩充stat、readdir、带flags写入与task ticket接口；没有Node全局builtin monkeypatch。

支持ls/cat、printf普通文本重定向、文件原始字节重定向、`>`/`>>`、分组与persistent descriptor写游标、mkdir、mv、rm和同grant文件复制。支持递归mkdir/rm/cp的有限实现，深度64；目录列表最多10000项；单次native读写1MiB，文件操作聚合最多64MiB。复制跨grant或跨grant/普通host mount明确EXDEV，避免MountableFs隐式转成另一套权限语义。

遵守项目私有Bash的ohosWritePosition/ohosOverwriteAtStart选项，不把一次独立open的后续写入重新truncate。真实cat产生的FF00等字节通过原生buffer原样写入。原有Bash的`printf '\377\000'`在普通ReadWriteFs和新FS都产生C3BF00，本轮没有擅自修改共享printf语义；证据单列，不把它冒称新消费者FF00通过。

stat/lstat对最终链接只取不跟随元数据；stat碰链接拒绝ELOOP。read/write逐分量NOFOLLOW；rename/unlink操作最终链接本身。readlink、link、symlink、chmod、utimes明确ENOTSUP。对象租约、宿主改名、硬链接别名及非恶意同进程假设继承911，不提升为实时路径树sandbox。

task RO在Native ticket内执行，不能仅绕过JS read-only proxy就写入；测试在外层workspace-write下使用原生RO ticket仍拒绝。未知grant、错误代际、伪造token、复用token也拒绝。

## 打包与本机命令

compose-runtime增加process/files/*.mjs。构建源/测试不进payload。HAP loader固定加入libdsh_workspace_grants.so；build-hap-libs.py新增可选`--workspace-grants`，执行files/build-addon.py；build-hap.sh仅在该库实际存在时带入，audit-hap仅在对应native输入存在时扩展精确白名单，并比较输入字节、沿用整个目录N-API/NEEDED审计。

build-addon.py要求固定Node24.22.1 headers/libnode与napi-rename.h，OH clang、SDK sysroot和已有libc++工具链flags，先核隔离再构建再核隔离。只导入重命名Node N-API，Ark N-API留在libdsh_host；通过dlsym调用不含N-API的C ABI。

```sh
python3 runtime/ohos/native/build-hap-libs.py <原有全部必需输入> --workspace-grants
```

脚本生成精确编译命令与SHA构建记录；本轮没有SDK，因此此目标构建、HAP审计、目标加载、HBN操作均NOT_RUN。没有新第三方依赖，现有Node N-API/libdl/C++17和已锁定Bash依赖继续使用。

## Linux证据范围

真实Node24.22.1 Worker、真实新Node addon、单份libdsh_host文件服务DSO和真实Bash/文件操作；测试publisher只是将夹具目录FD交给实际生产owner，不伪造文件服务。原始filesystem对固定虚拟mount真实EACCES，新消费者执行所需命令并检查实际文件字节/删除结果。

16个新场景在普通模式与jitless模式均通过。911原生34PASS，实际ETS/Entry45PASS；原有字节与游标direct/真实Worker共11PASS；HAP distribution既有6PASS。没有运行完整门。依赖装配早期缺sprintf-js和regex生成物的失败记录保留，不算产品红灯。正式红是原baseline不具备目录FD虚拟挂载的EACCES；这属于新增能力验收，不把旧接口没有这项能力定性为违约。

新增门workspace-shell-host/addon/publisher及workspace-shell-plain/jitless。生产root910的共享路由/输出完成门另行负责；测试Worker只验证同一真实FS/Bash/native消费者，不冒称完整App自动挂载已完成。
