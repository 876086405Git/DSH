# 鸿蒙 PDF 预览适配与边界

本候选基于 `fd2890cf9ae5ee2bb4faead2fbbf3689a4a29b92`，HMS 状态 **UNCOMPILED_HMS**。`HmsPdfPages.ets` 只按用户 `hms-contracts.md` D 部分实现，未取得官方 HMS 声明，也没有设备。`PdfInput.ets` 只用公开文件 API；输入通过宿主提供的异步安全 fd opener。

## 真实调用契约

PDF 不是新通道，继续使用 `dsh/files`。真实消费端是 `app/lib/state/artifacts.dart` 的 FilesChannel 和 `app/lib/ui/chat/artifact_preview.dart` 的 `_PdfPages` / `_PdfPage`。Android 参考是 `files/PdfPages.kt` 与 FilesPlugin 的三个分支。

| 方法 | 参数 | 返回 |
| --- | --- | --- |
| `pdfInfo` | `{path}`，已在本机工作区或应用缓存的普通文件路径 | `[{width,height}, …]`，正整数页面尺寸（PDF points） |
| `pdfPage` | `{path,page,width}`，page 从零开始 | PNG Uint8Array |
| `pdfClose` | 无参数 | 清理后返回 null |

宽度像 Android 一样限制在 64–2400；高度按页面比例向下取整，再限制在 1–4800。info 的正数尺寸取最近整数，最小为 1，以免 Dart 的比例布局出现零宽度。不会把 file:// 直接传给 PDFKit。Dart 的失败文案是“无法打开这个 PDF，试试用其他应用打开”；原有打开/保存入口保留，不修改 Flutter 界面。

服务 API：

```ts
new HmsPdfPages(context, openLocal: (path: string) => Promise<number>)
info(path: string): Promise<Map<string, Any>[]>
render(path: string, index: number, requestedWidth: number): Promise<Uint8Array>
close(): Promise<void>
retire(): Promise<void>
```

最终 FilesMediaPlugin 接线由根代理统一合入最新 P3c/lazy-native 组合：引擎 attach 创建服务；三个现有方法分派到 info/render/close；engine detach 调用 retire。方法闭包与 detach 必须绑定原引擎身份，不能让旧闭包转调新 `this.pdf`。构造函数不创建文件，不调用 PDFKit，不加载 libdsh_host；opener 由 FilesMedia 的异步 `openLocal(path,generation)` 提供。服务自身没有 native import，不能绕过新增的懒加载门。

## 输入副本与权限边界

输入 fd 必须来自现有 `openUserFile` 的受限目录和逐层 O_NOFOLLOW 路径检查。`PdfInput` 不重复定义工作区根，也不接受 Dart 自报的额外目录。opener Promise 回来后再次检查服务是否仍是当前 owner；即使该时刻已经退休，取得的 fd 也由 finally 关闭。

PDFKit 公开合约只接受路径，未确认 fd 或 file:// 参数。于是先从可信 fd 复制进应用 cache 的独占 `dsh-pdf/page-XXXXXX/document.pdf`，关闭输入/输出 fd，然后才调用 loadDocument。文件至少 1 字节、不超过 **64 MiB**；这是内嵌预览的产品资源限制，不是 PDFKit 官方格式上限。更大的文件仍可用现有系统应用打开。

复制处理短读/短写，拒绝零进度和越界返回，并在前后核对源大小。原路径被替换不会改变已经打开的 fd；同长度原地写入仍可能产生混合内容，**没有声称得到任意并发写入下的原子时间点快照**。缓存目录是应用自有位置；lstat 检查不构成对已控制同 UID 的恶意目录替换的完整防御。

关闭 fd 失败会保留句柄以便重试，不把清理异常视为成功。快照只在原生文档释放后删除。OH rmdir 会递归删除，故只在确认该独占目录仍是非符号链接目录、且已经为空时调用；不主动清理非预期内容。

## 串行执行与内存边界

一个模块级 Promise 队列串行所有实例，避免旧 owner 尚在 packToData 时新 owner 先释放它的 PixelMap 或打开第二份文档。普通工作在模块待处理数量达到 **32** 时明确返回 busy；必需的清理不受同一个拒绝门阻塞。重复 close 在没有夹入新页面请求时合并；如果中间有新 info/render，请求后的 close 仍保持顺序。没有资源/工作时的 owner 替换和 close 是纯内存操作，不填满队列。

正常只缓存一份文档和一份自有输入副本。切路径、新 owner 或显式 close 都先清理上一份。页面、PixelMap、ImagePacker 在 finally 释放，顺序为 packer → PixelMap → page；文档与文件副本随后释放。释放失败保留对象，后续操作必须先重试，不能忘掉旧资源再开新对象。显式关闭失败的文档标记为必须关闭，不能凭原路径命中而复用可能失效的缓存。

load 后只接受 **1–1000 页**。首次验证的页数保存在字段内，info 循环和 render 范围检查均使用它；不在循环前再相信第二次未经验证的返回值。info 每处理 8 页让出一次 JS 事件循环。SDK 的 load/getPage/render 本身是同步操作，依旧不可抢占；**没有证据证明它们可以放进 Worker/TaskPool，也没有宣称此版本满足手机主线程延迟预算**。

最大指定渲染面积为 2400×4800=11,520,000 像素。若实际返回的是 4 字节每像素格式，仅该像素面约 46,080,000 字节；真实 PixelMap 格式、解析器占用、编码峰值和 Flutter 复制还需设备测量。PNG 输出另设 **48 MiB** 上限。不能把这些局部上限当成整个进程的峰值内存。

## PDFKit 调用与尚需定论的语义

唯一 HMS import 是 `HmsPdfPages.ets` 中的 `@kit.PDFKit`。每个 PdfDocument 只调用一次 loadDocument；ParseResult 非成功一律进入已有失败回退，其中密码错误单独提示用系统应用打开。没有猜测密码输入通道。

渲染选择 `getAreaPixelMapWithOptions`，矩阵使用 x=0、y=0、width=W、height=H、rotate=0；显式 `isGray=false`、`drawAnnotations=true`、`isTransparent=false`。**这个矩阵的整页缩放语义来自用户合约所列 FAQ 的推断，尚不是手机测量结论**。没有再擅自读取 getRotation 后叠加旋转，避免在尺寸/方向语义不明时双重旋转。

取得 PixelMap 后先用公开 `getImageInfo()` 核对实际宽高；编码后再检查 PNG 签名与 IHDR 宽高。尺寸不同就失败回退，不让错尺寸通过。但像素尺寸相同仍不能证明内容完整缩放而非裁切，因此必须在真机用带边界标尺、彩色块、不同旋转角的 PDF 视觉对照。

使用公开 `image.createImagePacker().packToData` 生成 image/png，quality 100，最后返回 Uint8Array。系统模块缺失时的模块加载方式、境外地区失败形式、同步大文件耗时均未验证；本地“工厂/解析抛错”夹具不能证明所有 Kit 不可用情形。

## 真实测试与解释

```sh
python3 runtime/tests/ohos/pdf-linux.py \
  --node /path/to/node-v24.22.1/bin/node \
  --node-headers /path/to/node-v24.22.1/include/node \
  --typescript-prefix /path/to/pinned-process-prefix \
  --out /path/to/pdf-evidence
```

辅助程序用自己的绘图指令生成两页有效 PDF，实际运行 Poppler pdfinfo 获取 200×300、400×200 points，再用 pdftoppm 渲染 64×96、100×150、2400×3600 彩色 PNG。重编译生产 file_access.h 的 Linux NAPI 桥，测试实际 ETS 方法体、真实文件读写和安全 fd。HMS 文档/页面/位图/打包器是明确边界替身；PNG 对照与产品返回逐字相同，证明本地逻辑的格式/尺寸/传递，**不证明 PDFKit 已渲染过任何一页**。

保留的前像：首次 15 项中 12 通过，1 个产品问题是空 owner 退休排满队列，另 2 个是测试对不同 VM 数组原型做 strict 比较；两者已区分。随后 16/16。增加释放失败缓存与二次页数反例后，18 项中 16 通过、2 个产品失败，原代码和日志都保留；修复后同输入 18/18。

公开 TypeScript 类型核查只使用固定 OH 声明、最小 Flutter 接口和用户合约的 **非官方 PDF stub**。最终还要交真实 check-arkts.sh --hms-stubs 的精确组合结果。即使严格 ArkTS 零错误，HMS 仍保持 UNCOMPILED_HMS，直到本机真实声明/构建/设备证明闭合。
# v2：系统清理缓存后的幂等退休

独立评审对原 v1 实际 ETS、真实 Linux FS 与安全 native opener 做反例：成功 info 后删除自有 `document.pdf` 或整个独占 slot，再 close/新 service.info，旧实现每次都因 ENOENT 失败，即使 native document 已释放且 FD 数为零仍占用全局 physical。系统/用户清理 cacheDir 是公开沙箱目录语义，因此必须处理。

v2 仅在自有 document 的 unlink、自有 slot 的 lstat/listFile/rmdir 这几处，将公开 OH BusinessError `13900002`（No such file or directory）视为已清理；真实 native/FD 释放仍先行，其他权限、I/O、类型变化和非空目录失败仍保留引用与占用。不会忽略所有文件错误，也不递归删除未知内容。

同一个独审探针逐字复跑旧代码失败、新代码成功；Linux 适配器仅把真实 ENOENT 映射为公开 OH 数字错误码。为排除“改变替身掩盖问题”，先在旧产品+数字码适配器上再次复现失败，再修改产品。原18项之外新增缓存文件/slot清理、清理过程中目录消失、权限失败、非预期内容和 native release 仍失败的反例；HMS 渲染/设备结论范围不变。

