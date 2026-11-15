# App 创意工坊：数据层、导出与页面

2026-11-12。**未在真机上验证**，下面的行为依据源码和单元测试，真机要看的步骤在文末。接口以 [Worker v1 合同](../../services/share-worker/docs/workshop-api.md) 为准，Worker 一侧的实现见 [workshop-worker.md](workshop-worker.md)。本文记录 App 侧数据层（`app/lib/workshop/`）、伙伴包的完整性检查与换包门、导出和投稿的约定，以及页面（`app/lib/ui/workshop/`）怎么用它们。

## 目录与缓存

目录更新保留已经知道的撤回与 `blockedVersions`：新响应不能把已有被禁版本重新变成可安装状态；这些记录可以在条目与 `withdrawn` 账本之间迁移。未知 kind 只验证通用元数据，允许未来种类使用更大的包或新的许可证标识，仍显示「不支持」，不能投稿、下载或调用当前安装器。

`downloadDirectory` 必须是本模块专用的 App 私有目录。同一 App isolate 内，多个 repository 按规范化绝对 URI 字符串共享串行队列，防止新 provider 清理仍被旧安装器读取的 ZIP。调用方须统一使用同一路径；这个键不解析所有文件系统别名，也不是跨 isolate 或跨进程锁。缓存保留一个可续传资源槽位；选择另一个 SHA 后，只删除本模块格式的旧 `<sha>.zip` / `<sha>.zip.part` 文件，不递归删除其他目录。选择另一资源会放弃前一资源尚未完成的续传。清理失败明确返回存储错误。HTTP 连接建立超时后若请求对象晚到，会立即 abort；设置请求头 / 发送正文失败也关闭请求。

同一 App isolate 内，按相同方式规范化的 `cacheFile` 共享目录事务队列与最新已知撤回集合，队列覆盖请求、解析和落盘；旧客户端不能用自己的旧内存副本覆盖新客户端刚记录的撤回。调用方同样须统一缓存路径，不得依赖跨 isolate 的内存共享。切换 Worker origin 会重新核对磁盘缓存来源。暂停 companion 时主目录会隐藏 companion 行，安装和已装状态因此先看明确开关，报告 `workshop_companion_disabled`；已装撤回标记独立保留。

首次读缓存遇到存储错误且尚无健康内存副本时，下一次串行目录事务可以重试磁盘读取；同规范路径的新客户端也能重试，成功读取会清除旧的 `cache_storage`。若网络已取得较新目录，即使随后保存失败，也保留该内存副本和已知撤回，不再从旧磁盘覆盖它。离线读取恢复只供标记为 `stale` 的浏览，`requireFresh` 的安装门继续拒绝离线。

公开预览的私有缓存格式标记为 `previewSchema: 1`，公共 catalog schema 仍为 1。旧客户端可能丢掉自己不认识的 preview 字段，却保留同一响应的 ETag；因此读取缺少有效新标记的磁盘缓存时，仍保留可用的 stale 文本、fetchedAt 与撤回历史，但丢弃旧 ETag，下次刷新请求完整 200。没有有效本地 ETag 的 304 返回 `workshop_bad_catalog`，不能把不完整副本标为已经迁移。新格式中本来就无图的条目继续正常使用 304；不能把“preview 为空”当作旧缓存判断条件，也不重置已知撤回集合。

## 数据层入口

`WorkshopClient(origin, cacheFile, http?)` 需要调用方明确给定 HTTPS Worker origin 和 App 私有缓存文件，没有隐藏的生产部署地址。`WorkshopRepository(client, packages, downloadDirectory, appVersion, freeBytes?)` 编排下载和安装。生产包存储使用 `LocalWorkshopPackages(pets, companion)`，内部调用既有的 `PetLibrary.install` 与 `CompanionPackStore.install`。

`cachedCatalog()` 只读可用缓存，不发 HTTP；与目录刷新共用同一事务队列及缓存加载逻辑。有副本时返回原 `fetchedAt`、`cacheIssue` 和 `stale=true`，没有可用副本时返回 null，缓存问题仍可从 client 的 `cacheIssue` 读取。它不会更新核验时间、替换较新的内存副本或放松已知撤回检查。页面可以先展示这个结果，再调用 `catalog()` 刷新；安装仍须走既有强制刷新门。

`catalog(requireFresh: false)` 尝试刷新，可在网络失败时返回 `stale: true` 的缓存并附 `refreshError`。`requireFresh: true` 不允许回退；安装前和下载后都用此模式。结果有 `cacheIssue`，客户端的同名 getter 也保留没有可用缓存时的磁盘问题。缓存只含公开目录、ETag、origin、抓取时间和格式标记，不含账号或投稿状态。304 只在已有同 origin 有效缓存及 ETag 时接受。目录声明的 kind、版本、`minApp`、内容寻址 URL、SHA 和大小均检查；未知 kind 保留为不支持类型，不传给宠物安装器。

服务端开关默认开；明确关闭时返回 `workshop_upload_disabled` / `workshop_companion_disabled`。原来已装内容不会因联网失败或服务端关闭而被自动删除。客户端完成一次网络往返后发生的撤回无法提前获知，已下载副本也不能远程追回；这不是「离线目录仍可授权安装」的理由。

版本比较遵循 Worker 的 80 字符 SemVer 合同，不接受 build metadata。源码既有的 `AppVersion` 使用 int，Worker 的数字标识可超过 int64，所以本层比较数字串的长度和字典序，不损失精度。设备版本可带 Android build 后缀，比较前去掉 `+…`。

## 公开预览的地址与页面边界

`WorkshopMetadata.previewSource` 为可选模式；已支持 kind 的 pet / companion 分别只接收 `pet-idle` / `companion-preview`，省略表示无声明。`WorkshopEntry.preview` 与 `WorkshopSubmission.preview` 共用只读 `WorkshopPreview`（path、sha256、size、width、height），没有字段时为 null；JSON 显式 null 或不合法 descriptor 不能伪装成无图。解析严格核 PNG 摘要、1..2097152 字节、宽高各 1..512、面积不超过 262144，以及包含 kind / id / version / ZIP SHA / PNG SHA 的完整固定路径。这里验证的是描述，不是 PNG 解码。未知公共 kind 不解释未来的 previewSource / preview，保留原不支持条目的文字，不能因此破坏其他已知条目或变成可安装项。

`client.publicPreviewUri(entry)` 是同步纯方法：有 descriptor 时将已校验的根相对路径接到该 client 的规范 HTTPS origin，无图返回 null。它不发 HTTP、不读或发送账号、不下载或缓存图片，也不证明条目当前仍公开。页面使用这个完整地址，不拼裸桶 URL、不借另一来源或另一版本的图。Worker 当前公开门仍可能因新版替换、撤回或 companion 关闭而拒绝旧地址。

图片可以用页面的图片组件显示，状态层不抓取图片字节。页面须为无图、加载中及失败保留占位，失败不抹去标题、元数据或原安装状态，不把图像异常解释成 ZIP 损坏。origin、当前条目或 descriptor 变化时清除旧展示；同一 PNG 摘要在不同 release 下也不是同一授权地址。HTTP 库的重定向和缓存策略不能由纯 URI 方法保证，集成方仍须遵守 Worker 直接同源返回 PNG 的合同。图片显示成功不等于本机安装 / 模型渲染成功，已下载的图片也不能被服务端远程追回。

## 下载、安装与本地版本

下载复用 `ApkDownloader`，沿用 Range 续传、取消、重试与 SHA-256。包装传输只接受本次固定的内容寻址 URL，禁止跳转，严格校验 Content-Range 和总长；没有 Content-Length 时也在超过目录 `size` 前中止流。有界正文使用保留上游取消传播的 `Stream.map`，避免额外的异步生成器在等待下一块时阻碍取消；这不承诺网络或文件系统立即完成清理。

空间预检的预算为 ZIP、128 MiB staging、伙伴 runtime 的复制量和 4 MiB 余量。Android 既有的 update info 提供 `cacheDir` 可用空间；调用方可注入与目标目录同文件系统的更精确探针。预检不预留磁盘空间，未知剩余空间也不表示「足够」。本层直接取得的存储错误数字码 28、122 映射成 `workshop_no_space`，其他或未知码为 `workshop_storage`。既有下载器把写入失败归并为 storage，丢失原 errno，因此本层在该失败后再查空间：预算不足返回 `workshop_no_space`，探针不可用或预算足够仍返回 `workshop_storage`。该探针只说明查询时预算是否够用，不能证明刚才的写入失败原因，也不能排除已经丢失的配额错误。

伙伴解压写入失败时保留原始的存储错误类型、errno 和栈，再由既有映射给出 `no_space` 或 `storage`。写入失败后关闭输出流，以及失败事务最后关闭输入流，都不能遮蔽主错误；正常写入后的输出 close 失败仍为 `storage`，非存储的提取错误仍为 `notAPack`。生产路径在 `compute` isolate 里提取；仅测试构造器可替换一个输出文件流边界，并在当前 isolate 执行同一安装事务。依赖的控制流按官方 archive v4.6.0 标签 commit `3852d7e402a2a796d3f2af00ac3c28f129c0bb78` 的源码核对。

下载成功后的次序是：核长度、再次查询安装空间、以 `requireFresh` 取得并核对当前条目、同步检查取消，然后交给 `packages.install`。空间不足会优先失败，并且不会发出最终目录请求；正常成功仍有下载前、交接前两次目录刷新。最终目录请求排在可能暂停的空间查询之后，但目录刷新与包目录提交不是一个原子事务。安装器接手后发生的撤回不取消这次在途安装；后续安装仍须通过新的目录检查。

每个工坊安装目录里有 `.workshop-source.json`，仅记录 kind、id、version、SHA、origin。它在 staging 中写好，随资源目录一起切换，没有先装好资源再补数据库的双写窗口。手工导入没有收据，因此覆盖后不再冒充旧工坊版本。宠物本地 ID 仍走现有的 `userPetIdFor`；网络身份 `(kind, id)` 与本地目录名分别处理。两个网络 ID 映射到一个目录、或者伙伴单槽位已有别的角色时，默认 `workshop_install_conflict`；调用方显式确认后传 `replaceExisting: true`。

提交切换前在原安装器队列内再次核对收据。同版不同 SHA 拒绝，已装新版本不被旧下载降级。卸载传入此前观察到的收据；期间被替换后，旧卸载请求失败，不删除新包。`states(catalog)` 为公开条目给出 `installed`、`updateAvailable`、`installedWithdrawn`、`unavailable`。`installedStates(catalog)` 保留全部已装资源，即使撤回后公开条目已消失，也明确显示被撤回且仍可卸载；来自其他 Worker 的收据不会被当前目录误认。卸载不访问记忆、聊天、语音或作者账号。

宠物列表按条目隔离可识别的收据或包读取问题。`PetLibrary.workshopReceipts()` 以 localId 为 Map 键，每条值为 `(receipt: WorkshopReceipt?, issue: String?)`；无收据的普通本地导入仍不进入工坊列表。共同结果类型 `WorkshopLocalEntry` 包含两种情况：`WorkshopInstalled` 保留非空可信 receipt 和可选 issue，`WorkshopInstallationIssue` 只有本地标识和问题，不伪造网络身份。

`installed()` 与 `installedStates(catalog)` 都保留错误行；公开 `states(catalog)` 只用可信收据匹配。收据无效返回 `workshop_install_record`，收据读取失败返回 `workshop_storage`，均无可信 receipt；包格式错误返回 `workshop_pet_bad_pack`、包读取失败返回 `workshop_storage`，仍保留已读到的有效收据。PetLibrary 的根目录获取、恢复或枚举失败仍使整个列表失败；`StateError` 等未识别异常从 `PetLibrary` 继续向调用方传播，repository 沿用既有整体错误映射，仍以整次查询失败结束。

有效收据对应坏包时，`WorkshopInstalledState.installed.issue` 与远端 `unavailable` / `installedWithdrawn` 分开保留，仍可按原收据围栏卸载；观察后若被替换，旧卸载请求拒绝删除新包。工坊 `uninstall` 接受共同条目类型，但无可信收据的错误行会在调用包存储删除前以 `workshop_install_record` 拒绝，不能从其 localId 猜测远端身份。

Companion 槽位的列表读取将预期的收据、存储和恢复错误经既有映射保留为无可信 receipt 的 `WorkshopInstallationIssue`，不阻止已读取的健康 Pet 行返回。这包括底层已转换为 `CompanionPackException` 的停止读者失败；未被底层转换而直接逸出的程序错误仍由 repository 整体映射，使整次查询失败。成功收据还须 `kind == 'companion'`，否则报 `workshop_install_record`。此隔离只用于列表，不改 store 的恢复、严格安装 / 卸载围栏，也不增加全 pack 完整性扫描。

工坊伙伴包只有 character，必须先有本机钉死摘要的 runtime；缺失返回 `workshop_runtime_missing`，本层不自动下载。来自工坊的角色经现有安装器及完整性门；原有的本地导入仍保留其调用方式。

### 本机诊断分类与移除结果

`workshopPackageValidationCodes` 是公开的 `const Set<String>`，分类的是经过既有映射的包格式、内容、路径、尺寸和兼容性诊断。调用方只在明确的本机诊断载体上使用 `.contains(code)`，例如已装行的本机 issue；不能凭相同字符串鉴别来源，也不能混用远端 `unavailable`。未列出的码继续走原 fallback。收据、存储、缺 runtime、导出目标、预览和目录可用性问题仍分别处理。

集合命中不表示列表已经完整扫描模型或图片，不等于文件永久损坏，也不授予卸载权限。可信收据附带本机 issue 时仍用原收据围栏卸载；只有 issue、没有可信收据的行仍不能调用实际删除。不得用集合成员关系替换 `canUninstall` 或扩大列表的检查深度。

`WorkshopInstalledController.acknowledgeRemoval()` 是同步 `bool`：controller 已 disposed 时返回 false；否则读取当前 state，只将 `succeeded` / `failed` 的 removal 换为默认 idle，并清除该 removal 的 target / error / refreshError。`idle` / `removing` 返回 false。列表、加载和目录诊断保持原值；它不执行 I/O，不重试卸载，不读取或改变共享 mutation 门，也不以门空闲为前提，门仍由原操作释放。不要在监听器里同步调用。页面在用户明确收起的动作里调用它，下拉刷新在本机列表重读成功、且结果仍是刷新开始时那一个时也调用（见「页面」一节）。

## 伙伴完整性与换包门

`CompanionPackStore.unavailableReason()` 返回 `Future<String?>`，null 表示文件完整性门通过。稳定原因有：

- runtime：`companion_runtime_missing`、`companion_runtime_incomplete`、`companion_runtime_mismatch`。
- index：`companion_missing_index`、`companion_bad_index`。
- 模型与引用：`companion_no_model`、`companion_missing_model`、`companion_bad_model`、`companion_bad_reference`、`companion_missing_reference`、`companion_missing_texture`、`companion_missing_file`、`companion_bad_json`、`companion_bad_moc`、`companion_moc_version`。
- 其他：`companion_unsafe_path`、`companion_too_large`、`companion_changed`、`companion_storage`。

检查内容为整套 runtime digest、core / framework / shaders、index 所列文件、model3 的 moc / 纹理 / 物理 / pose / 表情 / 动作引用、严格 JSON 与 moc 格式枚举上界 6。它不运行 Core，不证明模型一致性、GPU 支持或实际画面；这些要由舞台加载和真机验证决定。

同 root 的 store 实例共享队列、`revision` 与 `revisions`。`beforeChanges(Future<void> Function() stopReaders)` 注册换包门，返回注销函数。事务先发布开始 revision，await 每个门关闭读取者，再修改目录；门失败返回明确的 `companion_readers_busy`，不移动 live。成功或失败均发布结束 revision。门内不要等待同 store 的操作，否则等待本身所持的队列会死锁。读者应先订阅 revision，再 await `unavailableReason`，检查前后 revision 一致才使用结果。

悬浮窗一侧的接线顺序：在 `beforeChanges` 中 await 原生 `configure(float: null)` 完成 WebView 销毁，再 await `server.close`；`revisions` 驱动异步重新检查与重建，用自己的检查代次与 revision 丢弃晚到的结果。细节见 [companion-floating.md](companion-floating.md)。`pack.previous` 在进程中断后由下一次操作恢复；删除先 rename 到 trash，避免半删与旧备份复活。

## 导出

`PetLibrary.exportZip(id, destination, publicId?, author?, license?, source?)` 从已解析的行为字段重建 schema-1 manifest，只带引用的 PNG；未知键、额外文件与收据不会携带。产物重新通过同一 `PetPackValidator`。投稿可显式覆盖公开 ID 与署名，使包内外 metadata 一致。

`CompanionPackStore.exportZip(destination, name?, persona?, author?, license?, source?)` 只从 pack / character 取选定模型和引用资源，重建 Cubism 数据与适配表。runtime、index、收据、未知配置、备注、UserData、动作事件文本、声音与 Sound 引用不导出；原始模板里明确命名的 LICENSE / COPYING / NOTICE 文本保留。index 由安装器重建。适配表保留参数、表情、动作、区域、尾巴、姿态与取景数据。文件系统链接拒绝。

默认名字是中性的 `Companion`，无人设。只有调用方为本次导出显式传入 name / persona 才携带，不自行读取用户偏好。代码不读取 character 目录以外的记忆、聊天、voice-sample 或安全凭据存储。对任意作者素材内嵌文字的语义不能给出程序化保证；本层保证不遍历这些个人数据源，并拒绝通过未知 JSON 字段夹带它们。投稿页面仍须让用户查看最终名单。

`preparePet` / `prepareCompanion` 接受 `WorkshopPublication`，导出后返回 `WorkshopPreparedUpload(file, metadata, files)`，其中 `files` 是实际 ZIP 成员清单。目标文件已存在时拒绝覆盖。

公共 metadata 可含 `description` 与 `tags`：简介省略时为空字符串，非空时最多 512 码点；标签省略时为空列表，最多 8 条，每条最多 32 码点且非空白，原字符串必须唯一，不做大小写或 Unicode 归一化。非空值沿用既有文本门，保留原文字及标签顺序；null 和错误类型拒绝。`WorkshopMetadata` 持有不可变的标签副本，`WorkshopPublication.withArchive`、目录、缓存和投稿保留这两个字段，空值序列化时省略。它们是展示元数据，不嵌入导出的 ZIP；导出器仍只接收原有的明确字段。

导出在 App 拥有者 isolate 里先解析目标父目录的真实路径；宠物和伙伴资源库随后共享一个串行导出队列，所有目标都排队，不按 URI 拼写拆分。队列覆盖 `compute`、最终提交及私有 staging 的清理，因此文件系统视为同一目标的不同大小写拼写也不会同时提交。完成 staging 后再次检查目标不存在，冲突返回 `workshop_export_exists`；失败不会阻塞之后的队列项。

不同目标也会等待前一项完成，资源库可能因此更久持有自己的队列；尚未完成的写入会延迟所有后续导出。写入回调只应生成本次 staging，不得递归等待另一次导出。该并发承诺限于同一 App isolate 的这些导出 API，不是跨 isolate、跨进程或外部文件系统写入者之间的 no-replace 原语；最后一次检查与普通 rename 之间仍不具备这种原子保证。

伙伴导出对每张 PNG 复用 `pngIntact` 的完整校验：8 MiB 文件、每边 4096、16 MiB 解码后 RGBA、CRC / IDAT 和像素解码。超界或损坏在 prepare 返回前以稳定错误拒绝，不缩小一般本地导入范围，也不放宽 Worker。导出的 JSON 成员仍限 1 MiB；空的许可 / notice 文件省略。缺少 `character.model` 时沿用舞台的 index 首模型顺序，不能因为另一个模型路径更浅而换角色。

### 为本次投稿选择公开图

公开图默认关闭，来源加载器不自动选图。`WorkshopPreviewInput.petIdle()` 是明确请求宠物主 idle 首帧的不可变值；`WorkshopPreviewInput.companionPng(Uint8List bytes)` 同步复制并私有持有作者选择的 PNG。后者先检查 2MiB、512 每边和 262144 像素，再调用既有完整 `pngIntact`；只读暴露 source / width / height / size，不暴露可写字节、文件路径或凭据。pet 输入只携带 source，其 width / height / size 始终为 null；实际公开 descriptor 由 Worker 登记后返回。调用方改动原字节数组不会改变已选图片。

PNG 构造失败直接抛 `WorkshopException`，发生在 controller 动作之前，页面须自行捕获并显示；不会自动写入发布状态的 error。`workshop_preview_size` / `workshop_preview_dimensions` 分别说明字节与尺寸门；完整 bool 校验失败使用 `workshop_preview_png`，不伪造更细的 CRC、截断或动画原因。

`WorkshopPublishSource` 的可选 `preview`、`previewSource` getter 与 `withPreview(input?)` 保留来源身份及署名。`WorkshopPublishController.setPreview(input?)` 返回同步 bool：须先选定来源、通过当前账号和 pending 检查，且非 busy、没有待结算投稿；种类必须匹配。成功时保留全部表单文字 / 标签，清除 prepared / result / 文件名单 / 进度，将 rightsConfirmed 设为 false 并回到 idle；旧未保留草稿按原清理队列处理。传 null 是移除图，不必重选来源或重填文字。false 表示这次选择未生效，沿现有 error 告知原因，不可当作准备或上传成功。

`WorkshopPublicationInput.publication(kind, {previewSource})` 把选定模式加入外部 metadata；publisher 从 source 取得该模式，再与 prepare 返回值做完整比较。不能只在准备结果里追加模式、略过期望元数据核对。`preparePet` 签名不变，声明时检查已验证导出 ZIP 中主 idle 动画的 frameW / frameH；不缩放、不新增成员，Worker 才按 `frames[0].i` 裁像素。未声明时不加这个较小尺寸门，合法大格仍走原导出。

`prepareCompanion(..., {name, persona, WorkshopPreviewInput? preview})` 保留原参数，输入与 publication 声明必须一致；明确声明却缺输入返回 `workshop_preview_missing`，其他模式不符返回 `workshop_bad_metadata`。无图走原导出；有图先由原导出器取得清理后的模型快照，再在工坊层加入精确的 `character/preview.png`，重新编码整个 ZIP。与已有文件同名、NFC / casefold 别名冲突，或覆盖既有后代路径时返回 `workshop_preview_conflict`，不覆盖纹理或默默改名。原成员数、压缩 / 展开大小门继续保留，临时 / 最终路径不得进入素材根；最终提交复用原串行导出与不覆盖合同。

最终仍只有一份 `archive.zip`：模型、署名与选择的 PNG 一起计算 SHA / size，返回实际成员清单。没有第二次图片上传、journal、偏好键或发布 phase。prepare provider 先核 source 与 publication 模式一致，失败清理它拥有的私有草稿目录。pending journal 保存包含模式的完整 metadata 与同一 ZIP 身份；可能已发送后不能改图。冷恢复可以没有当前 source，仍用原 requestId、metadata 和归档对账，不从当前模型或新图重建另一份投稿。

## 作者登录

作者用 GitHub 账号登录工坊，走 OAuth 设备码流程（`lib/workshop/github_device_flow.dart`），App 不持有 client secret，也不需要回跳地址：

1. `POST https://github.com/login/device/code`（表单 `client_id`、空 `scope`）拿到设备码、要用户输入的短码和验证页。验证页必须是 `https://github.com/…`，否则按 `workshop_account_unavailable` 拒绝。`device_flow_disabled` / `incorrect_client_credentials` 记为未配置。
2. 按返回的 `interval` 轮询 `POST https://github.com/login/oauth/access_token`（`grant_type=urn:ietf:params:oauth:grant-type:device_code`）：`authorization_pending` 继续，`slow_down` 把间隔加 5 秒，`expired_token` / `access_denied` 结束本次登录。
3. 拿到 token 后 `GET https://api.github.com/user` 取 `id` 与 `login`。

空 scope 意味着 token 只能读公开资料，正好是 Worker 核身份所需。两个主机各用一个工坊的无重定向传输，响应体限 64 KiB；token 不出现在错误、日志或 `toString` 里。`client_id` 来自 Worker 的 capabilities：`"account": {"origin": "https://github.com", "clientId": …}`；`clientId` 为 null 表示该部署还没登记 GitHub OAuth App，此时不能登录（`WorkshopAccessState.signInAvailable` 为 false）。

`workshopAccountProvider`（`lib/state/workshop_account_state.dart`）持有登录状态：`restoring → signedOut → awaitingCode → signedIn`。`{token, id, login}` 存在 flutter_secure_storage 的 `workshop.github.account.v1` 一个键下，读不出或格式不对就当作未登录。这和论坛 User API Key（`forum_auth.dart`）、模型服务商 key（`provider_keys.dart`）一样只放系统安全存储：AGENTS.md「不持久化完整 token」指的是日志、偏好、普通文件和诊断包，不包括系统钥匙串；令牌不进 SharedPreferences、日志、错误文本或 toString。`startSignIn()` 读 capabilities 的 clientId、请求短码、轮询、取资料，先写存储再切到 signedIn；`cancelSignIn()` 停止等待；`signOut()` 只删本机 token，撤销 App 的授权要用户自己到 GitHub 设置里做；Worker 回 `account_auth_invalid` 时，作者操作在记下失败的同时调用 `markInvalid()`，删掉 token 回到未登录，页面随之请用户重新登录。待结算投稿的 journal 按 worker / 账号来源 / 账号 id 分区，同一个 GitHub 账号重新登录后能接着对账。以前按论坛账号记下的 journal 不迁移，和别的账号的记录一样留在原处。

## 投稿与凭据

`WorkshopCredential.forConsentedWorker(worker, account, token, disclosureAccepted)` 只表示外层已完成确认，不会替用户获得授权。token 只用于本次 API 请求；不进入缓存、收据、JSON 正文或错误信息。工坊 origin 必须与确认目标相同，capabilities 的 `account.origin` 必须与该账号来源（`https://github.com`）相同。真实传输禁止重定向，不把 token 发给下载裸桶或任意网址。

作者请求以 `Authorization: Bearer <token>` 携带 token，并带 `X-Workshop-Account-Origin`，值为该 credential 的规范化账号 origin。Worker 在向 GitHub 核身份前再次与自己的账号来源严格比较，缺失或不等返回 `409 / workshop_account_origin`；断言不选择上游地址。capabilities 之后的配置变化因此不能靠前一次检查放行。收到该错误应重新核对账号来源与转交目标，不自动把 credential 的来源改成服务器新值；公开查询不携带 token 或此断言。投稿响应的 owner 为 `{accountOrigin, accountId, username}`。

Worker 目标、credential、capabilities 和投稿 owner 响应共用 `workshopOrigin`。它先执行 HTTPS、无 userInfo / query / fragment、路径为空或单斜杠的既有门，再重建 origin；普通 ASCII 主机转小写、默认 443 消去、根路径省略。普通 IPv6 按地址值输出最短小写十六进制段，并压缩最长的至少两段连续零；并列时取左侧。展开式与压缩式因此相等，不同地址仍不同。zone 标识和 IPvFuture 不在该规范化支持承诺内；其他输入门没有因此放宽。capabilities 与单条 / 分页投稿响应的来源比较全部保留。

作者 API 为 `createSubmission`、`upload`、`submit`、`submission`、`submissions`、`withdraw`、`report`。create / submit 要求单独显式传 `rightsConfirmed: true`，不能因为拿到一个目录条目就推断用户声明有权分享。`requestId` 由调用方在操作前保存；`newRequestId()` 给出随机的 32 位十六进制值。相同 `requestId` 重试创建有服务端幂等保证；pending / approved / rejected / withdrawn 不被便利方法重新上传。

声明预览时，create 的 POST 前还核 `capabilities.preview` 的 schema、PNG 限制与 source 集合；缺能力或不支持该模式返回 `workshop_preview_unsupported`，本次 `mutationNotSent=true`。这只证明本次调用未发 create POST，不证明此前同一意图从未发送。只有发布控制器仍允许显式放弃已知未发送意图时，才可先退出该意图，再 `setPreview(null)`、重新准备与确认；未知结果或冷恢复不得据这一错误改图重建。create 的写后响应若丢失或改变 previewSource，仍是 `workshop_bad_response`、`resultUnknown=true`，须保留原 requestId 对账。

上传先持有精确、受大小限制的字节快照并校验 SHA，再发送同一快照，防止哈希后文件被替换。状态、审核与撤回原因均保留；分页是服务端的实时视图，不承诺同一 revision 的快照。投稿的 approved 表示审核历史，当前是否公开以重新验证的目录为准，不能只据这个历史状态显示「正在公开」。

`upload` / `submit` 可接收 `onProgress(sent, total)`，单位为已交给传输层的字节和本次精确快照的总字节。真实 HTTP 先报告 0，再按最多 64 KiB 的块提交并 flush 后报告进度；完整 body 泵送与响应头共用一次超时预算，超时会 abort，迟到的 flush 不能继续写入或报告进度。到达 total 只说明字节已交给传输层，不表示服务端已接收、验证、进入 pending 或批准；结果必须等方法完成并读取响应。未实现可选上传接口的旧 HTTP 替身只报告 0 与取得响应后的 total；它不是吞吐测量。幂等返回已有非 draft 投稿时没有新的上传，也不伪造上传进度。

超时、连接丢失或无法解析的写入成功响应将 `resultUnknown` 标为 true；对有投稿 ID 或 requestId 的操作，调用方应重查或保留原 requestId 恢复，不能声称未提交。便利方法 `submit` 包含创建草稿和上传两个阶段：草稿创建成功后，上传前的 capabilities 查询或文件校验仍可能失败。这类失败的 `resultUnknown` 可以是 false，但不能据此断言整次操作未产生远端记录。任何失败都应保留原 requestId；需要立即保存投稿 ID 的页面可拆开调用 `createSubmission` 与 `upload`。

举报没有投稿创建的 requestId 幂等合同，也没有作者侧举报查询接口。举报结果未知时不得自动按「肯定失败」重复发送。客户端本身不自动重试这些写操作。撤回与举报在暂停新投稿时仍可调用。App 不保存管理员 Key，不实现运维审核页。

token 的本地格式门与 Worker 一致，为 1–255 个 `[A-Za-z0-9_]` 字符。本人列表允许 100 条合法多字节记录，所以该接口单独采用 8 MiB 有界响应门（与 Worker 状态对象上限一致）；其他普通 JSON 请求仍限 1 MiB。最大页不是无界读流。

### 本机待结算记录的恢复能力

恢复由可选的 `WorkshopPendingRecoveryStore` 能力提供；`workshopPendingRecoveryProvider` 只从同一个 preferences 实例取得该能力，原偏好接口不变。未实现能力的存储仍可用于原流程，但恢复请求会在 `recoveryError` 给出 `workshop_recovery_unsupported`。`canRequestPendingAbandonment` 只说明当前状态允许请求，不保证存储支持或读取成功：非 working 时，无 result 分支要求有 pending，或首次 pending 检查未完成且有 preferenceError；有 result 分支要求同时有 pending 和 preferenceError。

`WorkshopPublishController.requestPendingAbandonment()` 返回 **`Future<void>`**，不返回 offer。调用方应 await，再检查页面仍 mounted、session 未变，然后从**当前 state**读取 `abandonOffer`；没有 offer 就不能确认清理。请求只读取本机恢复版本，受理新的读取时先使旧 offer 失效。offer 只带公开的 worker / account / accountId 和 `range`，不带 token、文件路径、坏记录原文或其中声称的投稿 ID。

确认必须先展示 offer 的来源、账号、范围与本机恢复线索丢失的风险。`currentAccount` 仅清对应来源与账号的本机 pending 记录；`allLocalAccounts` 明确清整个本机 pending 容器，可能包含其他账号的续传线索，不能从不可读内容虚构数量或标题。用户明确确认后，调用 `confirmPendingAbandonment(offer)`，交回当前 state 中的**同一对象**；该方法也是 `Future<void>`，完成后以当前状态判断结果。working 时不受理；旧 offer 被拒绝，存储层还重读并核对绑定版本，不能用旧确认清除新记录。若前次写入实际成功后才报错，重试确认目标 scope 已不存在（全范围则 key 已不存在）时，可只完成本机收尾而不再写入；变化后目标仍存在则须重新读取、展示并确认。只读到了错误、或只显示过一个通用确认框，都不构成清理授权。

两种成功分支按是否已有经核对的 `result` 区分，不按错误码名称猜远端结果：

| 确认时的状态 | 条件清除成功后的本机状态 |
| --- | --- |
| 没有 result | 清除待结算意图、prepared 和进度，保留表单文字，rightsConfirmed 重置为 false，回 idle；冷恢复时 source 仍可能为空，需重选来源，不自动 POST。 |
| 已有 result，且 pending 收尾被 preferenceError 阻塞 | 保留同一 result、意图和原 prepared 展示，回 complete、hasPending=false；不把已知结果改写成未知，也不丢掉原请求号映射。只有 rejected / withdrawn 的原合同才允许随后显式 `startNewSubmission()`；pending / approved 不因此获得另发许可。 |

恢复只放下或修复本机续传线索，不撤回或删除服务器投稿；服务器可能已有 draft / pending。请求号映射与凭据披露记录不随此清除，改 metadata、换图或重导出产生不同 ZIP 后仍可能获得新请求号，不能承诺没有重复投稿。偏好读取或写入失败放在独立的 `recoveryError`，不把原 unknown 或已知 result 改写为另一种服务器结论；`workshop_confirmation_stale` 使旧 offer 失效。条件清除成功后，已持有的合法私有 lease 若清理失败，沿原 `cleanupError` / `retryCleanup` 处理，不复活已清的 journal；没有合法 lease 时不按坏记录的路径删除文件。

默认偏好实现与原 pending 方法共用同一 Dart isolate 的静态队列，比对读取到的类型及精确存储值，不是跨进程 CAS。账号切换会阻止旧请求结果回填新 session；已经受理并进入偏好队列的确认仍可能按旧 offer 的目标和版本完成本机写入，不能把切换账号说成撤销这次确认。原 `canDiscardUnsentSubmission` 仍只用于整个已知历史均未派发的轻量退出，与上述知情放下分开。页面怎么接见「页面」一节。

## 页面

页面在 `app/lib/ui/workshop/`，只画 `app/lib/state/workshop_*.dart` 给出的状态，不自己判断能不能装、能不能卸、能不能投。入口有两处：宠物设置页和伙伴小屋菜单各一行「创意工坊」。工坊地址默认是 `https://go.dshtui.com`，构建时用 `--dart-define=DSH_WORKSHOP_ORIGIN=<地址>` 换成别的部署；设成空串时 `workshopAvailableProvider` 为假，两行都不出现。

`WorkshopScreen` 是一个列表页，三个页签：

- 发现（`workshop_browse.dart`、`workshop_item_sheet.dart`）：搜索、按种类筛选；先画缓存，再刷新，刷新失败保留旧行并在上方说明。详情弹层里安装，进度按真实字节画，可以取消。要覆盖本机已有资源时先问，回答时交回状态层给的那个请求对象。控制器拒绝受理（已有别的安装在跑）时给一句提示。
- 已安装（`workshop_installed.dart`、`workshop_installed_sheet.dart`）：列表来自本机记录，目录只往行上加「有更新」「已撤回」之类的状态，不决定某一行在不在。离线、没有配置工坊、作品下架后列表照旧。下拉刷新先读目录，再让本机行取目录带来的变化。卸载的结果从控制器的移除状态读，不看调用的返回值。
- 我的投稿（`workshop_mine.dart`、`workshop_mine_sheet.dart`）：本人投稿及审核状态，撤回要写原因并二次确认。撤回结果未知时只提供「查询结果」，查到确实没撤回才允许再撤一次。

投稿页（`workshop_publish_page.dart`、`workshop_publish_form.dart`）是一个随状态换步骤的表单页，顺序为：工坊暂不收稿 → 用 GitHub 登录 → 凭据说明 → 有没有没交完的投稿 → 选来源 → 填资料 → 查看打好的包并勾选权利声明 → 发送 → 结果。没交完的投稿总是先于新投稿显示；结果未知时只能就同一个请求再问一次，页面上没有办法另发一份顶替它。只有一种情况可以放下没交完的投稿回到表单：状态层确认创建请求从未发出（`canDiscardUnsentSubmission`）。这时页面提供「回去修改」，只清本机记录，不向工坊发任何请求；之前可能发出过、或是重启后恢复出来的投稿没有这个选项；它们在本机记录用不了时可以走下面的「放下用不了的本机记录」。

举报（`workshop_report_sheet.dart`）从详情弹层进入。举报没有幂等合同，结果未知时页面如实说明，不替用户重发。

凭据说明只有一个组件（`workshop_disclosure.dart`）：投稿页把它作为一步显示，我的投稿和举报把同一个视图作为弹层升起。屏幕上的两个地址取自状态层给出的 offer，点「同意并继续」时交回的是同一个对象，所以同意不会落到用户没看到的地址上。同意已生效但没能写进本机时，页面说明下次可能再问。

文案集中在 `workshop_text.dart`、`workshop_mine_text.dart`、`workshop_publish_text.dart`：状态层只给稳定错误码，页面上的每句话都从这里取；不认识的码显示通用的一句，不按码名猜。组件测试检查屏幕上没有 `workshop_` 开头的码和异常原文。

伙伴小屋开着时在工坊里安装或卸载伙伴，换包门会让小屋的舞台先停止读取。从工坊返回时小屋重新检查素材包：有包就为包里现在的角色重建舞台，没有就回到导入页，不停在失败页上。

公开预览图：条目带 `preview` 时，发现页的行、详情（行首方块和一张大图）和已安装页的行显示它；地址只取 `WorkshopClient.publicPreviewUri`，和包同一个来源，页面不自己拼。像素宠物按 `FilterQuality.none` 画，伙伴封面按显示尺寸解码。没有图、还没加载出来或加载失败时退回标题首字的方块，不影响安装和刷新，也不当作包有问题。组件在 `workshop_widgets.dart`（`WorkshopEntryAvatar`、`WorkshopPreviewPanel`）。

投稿时选预览（`workshop_publish_preview.dart`）：工坊的 capabilities 声明收 `pet-idle` 时，宠物默认带预览，表单里一个开关可以关掉；收 `companion-preview` 时，伙伴可以选一张 PNG 当封面。选文件先看大小，超过 2 MiB 不读；封面按数据层的上限先在本机校验，不合格的原因写在那一行下面，什么也不设。每次改动都交给 `setPreview`，它丢掉已打好的包并收回权利声明，表单里已填的文字不动。打好的包那一步写明会公开的是哪张图，或者不带图。

放下用不了的本机记录（`workshop_publish_recovery.dart`）：`canRequestPendingAbandonment` 为真时，检查失败、没交完和结果这三步多一个次要的「放下这条记录」。点了先只读本机记录（`requestPendingAbandonment`），拿到 offer 后用对话框说清范围：只是这个账号在这个工坊的一条，还是本机记录整体读不出、要清掉所有账号的未完成记录；并写明工坊不会收到取消。确认时交回的是对话框据以显示的同一个 offer 对象；过期的确认显示成文字，让用户再点一次。

卸载结果的收起：「没能卸载」的提示带「知道了」，由用户点了才调 `acknowledgeRemoval`；已安装页的下拉刷新在本机列表重读成功后也收起上一次的结果。不在监听器里自动调用。

本机包诊断码按数据层的 `workshopPackageValidationCodes` 归为「包本身有问题」，页面不另抄名单。

## 测试覆盖

- `app/test/workshop/`：`workshop_models_test.dart`（模型与版本比较）、`workshop_client_test.dart`（目录缓存与离线重启、撤回与 `blockedVersions`、重定向不带 token、凭据与投稿 API、分页与响应上限）、`workshop_http_test.dart`（超时后晚到的请求、请求头失败时关闭请求）、`workshop_repository_test.dart`（续传 / 校验 / 取消、低空间、下载中撤回、离线浏览与拒绝离线安装、已装撤回状态、卸载、ENOSPC 映射、伙伴导出的 PNG 门）、`workshop_export_test.dart`（导出目标队列、提交处再次检查目标、悬空链接）、`github_device_flow_test.dart`（设备码请求、验证页主机门、pending → slow_down → token、过期与拒绝、取资料）。
- `app/test/state/workshop_account_state_test.dart`：恢复与坏记录、登录全程与存储、过期 / 拒绝 / 未配置 / 网络、取消后不再领取 token、登出与 `markInvalid` 删除存储。
- `app/test/workshop/workshop_installed_test.dart`：混合健康条目、坏收据、坏包与无收据本地包，核对逐条错误、可信身份匹配及有效收据的卸载围栏；单条读取失败在委托边界注入，根目录失败和意外 `StateError` 继续传播。
- 公开预览测试覆盖 descriptor / capability 解析、未知 kind、同源纯地址、旧缓存 ETag 迁移、写前与写后错误、单 ZIP 准备、固定成员冲突，以及真实发布 controller 的选择 / 替换 / 移除、pending / busy 和恢复围栏；图像及 HTTP 替身不构成浏览器或真机显示验收。
- `app/test/pets/pet_workshop_export_test.dart`：宠物导出。
- `app/test/companion/companion_workshop_test.dart`：伙伴的完整性门、解压写入失败时的存储错误映射（部分写入、errno 28 / 5、主错误加 close 失败、仅 close 失败、归档错误，并核对旧包与收据逐字节不变、staging 清理）、导出往返与隐私哨兵、换包门（停止读取者、中断恢复、同 root 共享队列与 revision）。这几项使用实际 `ArchiveFile`、真实临时 ZIP / 文件及 `FileHandle` 委托；注入失败不是实盘耗尽测量。
- `app/test/workshop/workshop_export_contract_test.dart` 的三项 App 测试覆盖普通导出、Unicode 路径和公开预览准备。显式设置 `DSH_WORKSHOP_CONTRACT_OUT` 到空目录时，保存真实 App 导出的 pet、companion、pet-unicode、companion-unicode、pet-idle、companion-preview 六份 ZIP 和各自 metadata；未设置时仍执行 App 往返和准备断言，不留下文件。随后 `services/share-worker/test/workshop-export-contract.test.ts` 的六项测试从同一个 `DSH_WORKSHOP_CONTRACT_OUT` 目录消费这六份原字节，核对 metadata、ZIP 身份、包校验和声明的预览。Worker 未设置该环境变量时六项都 skip，不算跨运行时验收；显式设置后缺文件或校验不符必须失败。Unicode 用例保留引用路径及原始资源字节。合成 MOC 仅用于格式合同，不能运行 Core。跨运行时往返需要「同一份 App 导出字节被 Worker 接受」的记录才算证据，Node 自行生成的 ZIP 不算。
- `app/test/ui/workshop/`：`workshop_browse_test.dart`（目录各状态、刷新失败保留旧行、安装与覆盖确认）、`workshop_installed_test.dart`（各行状态、更新、卸载及其结果）、`workshop_mine_test.dart`（登录与同意两道门、列表、撤回及结果未知）、`workshop_report_test.dart`（举报表单与结果未知）、`workshop_publish_test.dart`（投稿页每一步、未完成投稿、结果未知、360dp 宽 1.3 倍字号不溢出）。控制器用状态层自己的替身，不开网络、不写文件。
- `app/test/companion/companion_room_guard_test.dart`：从工坊返回、素材包已换时小屋重建舞台。

## 真机上要看的

低空间、断网 / 杀进程后的续传、换包时悬浮窗的销毁重建、已有 runtime 缺失 / 损坏、厂商 WebView / GPU，以及导出后的分享流程。公开图还需核有图 / 无图占位、加载失败、origin 与条目切换后的旧图清理、撤回 / 关闭后的重新请求，以及真实图片组件的缓存、重定向和设备内存表现。

页面这一层没有在真机上跑过：工坊未部署，App 也没有连过真实的工坊和 GitHub。上线前要在真机上走一遍浏览、安装、卸载、投稿、撤回和举报，并看小屋开着时安装伙伴后的换人。

## 还没有做的

- 公开预览图没有条件请求：Worker 每次都回整张图（`no-store`，无 304），页面也不按摘要另做本地缓存。条目多时的流量和 Worker 成本还没量过。
- 选封面在真机的系统文件选择器上没试过；页面关掉再打开后，已选封面只能画占位图标（字节在状态层里不外露）。
- 投稿来源列表里的宠物用字块，没有画它自己的图。
- 页面没有 goldens。
