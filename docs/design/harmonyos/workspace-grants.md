# 911：真实目录 FD 授权 owner 与共享文件租约

本补丁从6459f947提供系统选择器授权协议、目录FD发布和宿主文件操作服务。**shell/Linux消费者尚未接上，`engineAttached`固定false；不能把这份补丁标成P1整项完成。** C ABI已具备读写能力，后续消费者不得改用`candidatePath`或自行复制路径根数组。没有改Android、Node内建或现有runtime/direct、runtime/ohos/node。

## 真实接线与能力

EntryAbility注册AuthorizedWorkspacesPlugin并传递前后台/销毁。`dsh/authorized-workspaces`提供capabilities/list/select/persist/activate/attach/deactivate/revoke/forget/cancel。移入805R2已有状态协议，但此次增加真正目录FD持有及退休。

`select`只接受系统DocumentViewPicker的FOLDER返回值。照片仍由原NativeFiles的PhotoViewPicker负责，不进入目录授权。存盘仅记录id和picker URI；不存“已经有权限”的布尔标记。重启后若持久权限/能力缺失，list明确`needsReauthorization`+`unavailable`，不会默默删光记录。若能力存在，activate先向OS查询持久授权再使能；失败须重选。没有为本补丁默认申请、假定获批或动态提升受限权限。

独立的用户操作`attach(id)`验证selected/activated状态，从该记录的URI调用真实`fs.open`，再`fs.stat(fd).isDirectory()`。只把借用FD交给libdsh_host的workspaceGrant；原生fstat再检查目录，并F_DUPFD_CLOEXEC复制持有。Ark随后真实close借用FD。URI转换出的路径仅显示，路径转换失败也不阻止真正URI FD接线。Node/guest/Dart给来的path、URI、FD均不能签发授权。

|入口|已实现语义|边界|
|---|---|---|
|native Publish|固定目录对象、id、generation、grant可写上限|可信Ark owner专用；取得目录FD不证明所有子项可写|
|Acquire|代际相同且active；task write与grant writable相交|消费任务政策后的可信宿主调用；不是guest/Dart RPC|
|Read|每分量NOFOLLOW，最终普通文件，pread、独立offset|每次最多1MiB；不交出FD|
|Write|同样解析，task/grant均可写；创建、偏移写入、显式截断|先打开并fstat普通文件再ftruncate，绝不O_TRUNC后才检查；返回实际短写字节数|
|Rename|同一租约下两个父目录FD，renameat|最终链接本身被移动；无跨grant重命名|
|Remove|unlinkat/AT_REMOVEDIR|删除最终链接本身，绝不realpath后删除目标|
|Mkdir|mkdirat 0700|受同一写权限与代际约束|
|Retire/Status|active=false，关闭根FD；剩余租约引用归零才drained|在途调用先结束；不是有界取消/OS同步撤权|

C ABI在workspace_grants_abi.h。唯一owner由workspace_grants.cpp定义在libdsh_host内；生产Node消费者应通过此C ABI，不能复制一个registry实例，也不能混用Ark/Node N-API环境。测试addon只是测试桥，使用真正Node N-API调用同一原生实现，不打进HAP。

`dsh_workspace_acquire(id,generation,write)`返回opaque指针。`read/write/rename/remove/mkdir`失败返回-1，立即复制`dsh_workspace_error()`的线程局部错误；成功返回字节数或0。用完release，release只调用一次，必须等该lease所有调用结束；调用者保证指针活期，不允许并发release或释放后使用。C字符串参数由可信adapter检查长度及内嵌NUL，不能直接把任意wire字符串无验证地交给C字符串API。指针和FD都不序列化给Dart或guest。原生最多保留128个grant身份历史，防止代际复活；到限返回ERR_WORKSPACE_LIMIT，进程重启重新选择。每次读写最多1MiB。

## 退休不是删除一个字符串

每个原生grant有mutex、active、generation、固定root FD和活lease计数。原生操作在mutex内检查并完成实际系统调用。Retire取得同一锁后停止准入并关闭root；尚有lease引用时状态draining，释放全部引用后才D。旧lease之后的操作会得到ERR_WORKSPACE_RETIRED，即使同一路径/FD对象重新授权也不会复活。新代际要等旧代际drained；拒绝将旧请求改绑到新根。

R是Retire返回的停止准入点。已进入原生操作的调用可能先完成，之后才有R；mutex不会取消阻塞磁盘IO。没有定时轮询，也未声称有界等待。当前同步Ark退休在慢IO时可能阻塞调用线程；在真实大IO/慢存储验证前，不能宣称后台撤销即时或UI无阻塞。后续消费者须有任务取消与IO队列边界，不能用超时伪造drained。

OS持久权限deactivate/revoke单独记录。请求这两项时先退休native，之后才等待OS；即使本安装没有FILE_ACCESS_PERSIST，本地native也停止准入，但仍明确返回persistence_unavailable，不能宣称OS权限已撤销。OS失败保留记录和错误码。forget是本地移除，明确osGrantChanged=false；资源未释放/关闭未确认时拒绝forget。

发布之后关闭借用FD期间仍可取消：WorkspaceOperation记录这次发布的entry；cancel立即改变代际并Retire，不只取消Flutter回复。物理操作占用保持到fs.close完成。close失败保留FD记录并quarantine，不再attach或forget，不把未知关闭当成功。后台和engine/ability脱离也失效当前证据；重新前台不会自动复活。

## 对象范围与明确未实现项

本服务采用820/824讨论的**目录对象租约**，不是“始终位于当前字符串路径树内”。打开root后，宿主把它改名，租约仍访问原对象，原路径新建的替代目录不获权。逐分量打开的子目录若被宿主移走，本次已取得目录对象仍可能用于后续lookup。没有把这种行为当做实时路径安全证明。现存硬链接也可能有根外别名；此服务不声称整个inode只有根内名字。

NOFOLLOW阻止链接重新定向；不使用realpath/前缀作为权限证明。rename/unlink最终链接遵循内核本来语义。拒绝空分量、`.`、`..`、绝对路径和尾斜杠。mkdir/rename/remove是一般目录项操作；读写只接受普通文件。最终open后fstat拒绝FIFO/设备等类型，但不能据此证明面对恶意宿主同时换入设备节点时open本身绝无设备副作用；没有开放mknod、设备或任意同进程恶意native插件作为受信输入。

没有实现完整9P wire/FID服务、guest mount/transport隔离、工具票据消费、实例盘只读、跨进程共享FD。818原fs_disk不能直接接入；824的Linux O_PATH/proc研究也未被偷偷加入OH生产。shell与Linux必须从同一可信服务Acquire，以各自已消费的task模式取交集，并持有至真实任务/输出/mount清退屏障。D不能代替这些其他屏障。

`nativeGrant: ready`只表示目录FD已发布，`nativeGeneration`为已发布代际；`nativeKey`只是身份，不是令牌。后台后metadata中的nativeGeneration可能落后于当前授权generation，属于已退休旧对象；consumer必须通过当前可信owner检查，不能用列表快照恢复授权。`nodeAccess: unverified`、`engineAttached: false`准确表达两条lane尚未接入。设备上fs.open(directory URI)、dup/openat、NOFOLLOW和系统撤权后的旧FD语义仍需本机验证。

## 证据与复放

Linux实测34个原生检查：真实普通读写、创建、truncate、rename、unlink、根外字节保全、代际、任务RO/系统RO交集、目录对象改名、C ABI同一owner、真实pread的并发退休屏障。wrapper只在指定时点暂停，随后执行真实pread。既有OpenUserFile拿到的真实FD在授权退休后仍可读，说明仅删记录不能撤权；新服务旧lease拒绝后续读写。不能把旧API没有租约接口算作旧API违约。

实际ETS夹具+Entry契约45PASS，其中38个授权行为、7个Entry import契约。系统选择器/OS授权/Preferences/生命周期为明确SDK夹具；Preferences落真实临时文件，URI映射到真实Linux目录，fs.open/stat/close是真实FD，publish/retire/status调用真实C++ addon。借用FDclose等待时取消的实际反例先红后绿。

原有NativeFiles33PASS；原有file-access10000次路径替换检查PASS，FD4→4。纯Dart3.13.7执行6个实际ETS快照和10个客户端调用PASS；Flutter传输/界面未执行。Dart只提供协议和通道，未改任何用户界面。TypeScript转译不是严格ArkTS SDK编译证明。

新增run-gates行workspace-grants-build/workspace-grants/workspace-grants-addon/authorized-workspaces/authorized-workspaces-dart。未运行完整门、SDK、HAP、AOT、HBN。最终交付目录保存命令、stdout/stderr、patch应用检查和精确SHA；由独立reviewer复核。

无新第三方依赖。805R2来源为同项目冻结代码；C++17/POSIX、现有Node N-API头、TypeScript5.9.3、Dart3.13.7仅沿用已有工具。生产NativeHost保持Ark N-API；C文件服务ABI没有N-API符号。

## 官方API核对（2026-11-08）

- https://developer.huawei.com/consumer/en/doc/harmonyos-guides/file-persistpermission/ ：临时选择的读写权限会随退出/重启失效；持久权限需另外查询和激活。
- https://developer.huawei.com/consumer/en/doc/harmonyos-references/js-apis-fileshare/ ：FolderAuthorization系统能力与FILE_ACCESS_PERSIST；远程URI不作为持久授权对象。
- https://developer.huawei.com/consumer/en/doc/harmonyos-guides/restricted-permissions/ ：FILE_ACCESS_PERSIST在API12以后本地调试与应用市场发布要求不同，本补丁仍检查实际grant，不从版本号推断。
- https://developer.huawei.com/consumer/en/doc/harmonyos-references/js-apis-file-fileuri/ ：path为字符串转换且不验证可访问性。
- https://developer.huawei.com/consumer/en/doc/harmonyos-references/js-apis-file-fs/ ：stat支持FD；此文档不能代替HBN上目录openat行为实测。
