# Brotli 静态词典

Android 与 OHOS 共用引擎链中的 `brotli@1.3.3`。加载 `dec/dictionary-data.js` 时，Node 使用内建 Brotli 解开同一发布包的 `dec/dictionary.bin.js`，一次性构造标准的、可写的 `Uint8Array`。导出的 `dictionary` 保存该数组，`init()` 继续读取当前的 `exports.dictionary`。字体库读取 WOFF2 所用的 `brotli/decompress.js` 和包声明的浏览器入口照原路加载。

完整词典有 122,784 字节。测试核对 SHA-256、数组类型、缓冲区长度和引用，并从包的解码入口还原一个 Brotli 样本。升级依赖时，通过两端的引擎 pins 校验和同一测试核对字典版本。

在仓库根对 Android、OHOS 两个打好补丁的前缀各跑一次：`DSH_TEST_PREFIX=<前缀> node --test runtime/tests/brotli-packed-dictionary.test.mjs`；不设前缀时测试会跳过，结果里不能有 skip。
