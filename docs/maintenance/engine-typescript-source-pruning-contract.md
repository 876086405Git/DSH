# 引擎层省略 TypeScript 源码

`PRUNE_DEV_METADATA=1`（Android 默认）时，引擎归档不带 `rtbuild.py` 里 `TS_SOURCE_DIRS` 列出目录下的 `.ts`：openai 7.19.0、@anthropic-ai/sdk 0.129.0 和 minisearch 7.2.0 的 `src/`、@js-temporal/polyfill 0.5.1 的 `lib/`。这四个包的 exports、browser 映射和编译产物都只指向这些目录以外的 JS，source map 早已裁掉，`.ts` 运行时不会被读到。目录里的 `.cts`、许可证照常保留；关闭裁剪时全部保留。只动引擎层，不影响基础层和 baseId；OHOS composition 另有自己的省略表。

升级这几个包时，重新核对 exports/imports 条件、编译文件的相对和动态导入、按路径读文件的地方，再决定是否保留。不要扩大到带源码导出条件的包（如 Zod）。

同一开关也裁掉 `.d.mts.map`、`.d.cts.map`（对应的声明本来就裁了），普通 `.mts.map`、`.cts.map` 保留；包测试目录规则另含 gaxios 7.3.1 的 `build/{esm,cjs}/test/`，exports 只指向 `build/*/src/`。

同一开关省略 Koffi 3.1.1 的 C/C++ 编译输入（`.cc`、`.h`、`.hh`）。加载器只找预编译的 `koffi.node`，没有回退到源码编译的路径，引擎构建本来就带 `--ignore-scripts`；JS 加载器、汇编和许可证保留。升级 Koffi 时复查加载器有没有加编译回退。
