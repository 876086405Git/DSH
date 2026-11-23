# 客户端合包直接编码到最终 Buffer

`client-modules-combo-buffer.diff` 改 `dsh-client-modules/lib/index.js` 的合包编码，登记在 `client-modules-manifest-read.diff` 后，Android 与 OHOS 共用。它们的原始输入末态相同；后续没有改同一文件的 OHOS 专属覆片。

## 场景和改法

首次打开 Web 界面时，`fetchBundle` 的首次 GET 才构造默认前端合包。原实现先拼接所有准备后的脚本，再将完整中间字符串编码为 Buffer。现在保留按序准备的字符串段，求其 UTF-8 字节数，分配一次最终 Buffer 并依次写入。HEAD 和热读继续使用原有惰性响应与缓存机制。

源码清理、插件顺序、每段末尾的 `;\n`、source-map 尾注、响应类型、revision 和 HMR 缓存规则不变。每段脚本末尾先有换行，故相邻段之间不会跨段拼接 UTF-16 代理对；各段编码与原聚合串的 UTF-8 字节一致。默认合包的首次 GET 解码、准备已由 `record.bundle` 持有的源码；首次 chunk GET 仍按原路径读文件。新增逐段求 UTF-8 长度，不声称 CPU 时间或常驻响应大小下降。

原实现中间单串受 V8 的最大字符串长度限制。按已批准的运行时性能合同，合包不再保留这一实现上限；不引入新上限、校验、回退或开关。最终 Buffer 的分配仍由 Node 决定。

## 验证

`runtime/tests/client-modules-combo-buffer.test.mjs` 只有一例：通过真实 `ClientModuleRegistry.fetchBundle` 获取包含中文与 emoji 的两插件合包，比较全部字节和热读 Buffer 身份，同时确认完整中间字符串的 `Buffer.from` 编码次数为零。测试需 `DSH_TEST_PREFIX` 或 `DSH_PREFIX` 指向已准备的引擎前缀。没有前缀的跳过不能当通过。

性能量来自独立测量，仓内小夹具只防回退，不把夹具规模当普通用户数据。Android 设备、完整发布前缀与 CI 的结论应以实际执行记录为准。
