# OpenHarmony 固定依赖的第三方通知

本目录与根 `THIRD_PARTY_NOTICES.md` 配套。以下是原始通知和许可文本的收录结果，**当前仍有两项明确 BLOCKED，不能据此声明 HAP 的许可检查通过**。许可字段按各包实际声明列出；对于包内额外声明，单独登记，不让顶层声明覆盖它。

## 固定范围与版本

运行时范围从 `runtime/ohos/process/package-lock.json` 的 just-bash 3.6.0、isomorphic-git 1.44.9、re2js 1.3.3 沿非可选依赖和非可选 peer 边计算，共 91 个包路径。可选边单列在 `manifest.json`；esbuild 0.27.3 和实际主机构建用的 @esbuild/linux-x64 0.27.3 另列，不计入 91。

本次只新增 re2js 1.3.3 的直接声明：119 个已有 resolved 包记录、版本和 integrity 均保持不变。它在 M4-1 前已由 just-bash 固定依赖安装，M4-1 的私有 Unicode 适配从该包固定 sourcemap 重建，没有全局改写原包。其改动说明与可重现构建见 `../process/M4-1.md`，本目录完整保留 re2js 的 MIT 通知。

每份原始文档的字节数、SHA-256、来源包/文件及摘取范围见 [manifest.json](manifest.json)。原包未附完整通知时不补造作者、年份或授权。AUTHORS、TypeScript ThirdPartyNoticeText、run 嵌入通知、双许可文本、源码中的许可注释均按实际来源保留。

## 运行时 91 个包

| 包 | 固定版本 | 包声明许可 | 收录的原文 | 状态 |
|---|---|---|---|---|
| `@borewit/text-codec` | 0.2.3 | MIT | [LICENSE.txt](texts/borewit--text-codec-0.2.3/LICENSE.txt) | 已记录 |
| `@mixmark-io/domino` | 2.2.0 | BSD-2-Clause；源内另有 MIT | [LICENSE](texts/mixmark-io--domino-2.2.0/LICENSE)；[ANGULAR-LICENSE.txt](texts/mixmark-io--domino-2.2.0/ANGULAR-LICENSE.txt)；[原始源内声明](texts/mixmark-io--domino-2.2.0/ANGULAR-STYLE-PARSER-NOTICE.txt) | 已记录两类通知 |
| `@nodable/entities` | 3.1.0 | MIT | [UPSTREAM-LICENSE.txt](texts/nodable--entities-3.1.0/UPSTREAM-LICENSE.txt) | 已记录 |
| `@tokenizer/inflate` | 0.4.1 | MIT | [LICENSE](texts/tokenizer--inflate-0.4.1/LICENSE) | 已记录 |
| `@tokenizer/token` | 0.3.0 | MIT | [README-LICENSE.txt](texts/tokenizer--token-0.3.0/README-LICENSE.txt) | 已记录 |
| `abort-controller` | 3.0.0 | MIT | [LICENSE](texts/abort-controller-3.0.0/LICENSE) | 已记录 |
| `anynum` | 1.0.1 | MIT | [LICENSE](texts/anynum-1.0.1/LICENSE) | 已记录 |
| `async-lock` | 1.4.1 | MIT | [LICENSE](texts/async-lock-1.4.1/LICENSE)；[AUTHORS](texts/async-lock-1.4.1/AUTHORS) | 已记录 |
| `available-typed-arrays` | 1.0.7 | MIT | [LICENSE](texts/available-typed-arrays-1.0.7/LICENSE) | 已记录 |
| `base64-js` | 1.5.1 | MIT | [LICENSE](texts/base64-js-1.5.1/LICENSE) | 已记录 |
| `buffer` | 6.0.3 | MIT | [LICENSE](texts/buffer-6.0.3/LICENSE)；[AUTHORS.md](texts/buffer-6.0.3/AUTHORS.md) | 已记录 |
| `call-bind` | 1.0.9 | MIT | [LICENSE](texts/call-bind-1.0.9/LICENSE) | 已记录 |
| `call-bind-apply-helpers` | 1.0.2 | MIT | [LICENSE](texts/call-bind-apply-helpers-1.0.2/LICENSE) | 已记录 |
| `call-bound` | 1.0.4 | MIT | [LICENSE](texts/call-bound-1.0.4/LICENSE) | 已记录 |
| `clean-git-ref` | 2.0.1 | Apache-2.0 | [官方标准全文](texts/clean-git-ref-2.0.1/APACHE-2.0.txt)；[实际 author/license 字段](texts/clean-git-ref-2.0.1/PACKAGE-DECLARATIONS.txt) | 声明、标准条款与实际归属已登记 |
| `commander` | 6.2.1 | MIT | [LICENSE](texts/commander-6.2.1/LICENSE) | 已记录 |
| `crc-32` | 1.2.2 | Apache-2.0 | [LICENSE](texts/crc-32-1.2.2/LICENSE) | 已记录 |
| `debug` | 4.4.3 | MIT | [LICENSE](texts/debug-4.4.3/LICENSE) | 已记录 |
| `decompress-response` | 6.0.0 | MIT | [license](texts/decompress-response-6.0.0/license) | 已记录 |
| `define-data-property` | 1.1.4 | MIT | [LICENSE](texts/define-data-property-1.1.4/LICENSE) | 已记录 |
| `diff` | 8.0.4 | BSD-3-Clause | [LICENSE](texts/diff-8.0.4/LICENSE) | 已记录 |
| `diff3` | 0.0.3 | MIT | [diff3.js-LICENSE.txt](texts/diff3-0.0.3/diff3.js-LICENSE.txt)；[onp.js-LICENSE.txt](texts/diff3-0.0.3/onp.js-LICENSE.txt) | 已记录 |
| `dunder-proto` | 1.0.1 | MIT | [LICENSE](texts/dunder-proto-1.0.1/LICENSE) | 已记录 |
| `es-define-property` | 1.0.1 | MIT | [LICENSE](texts/es-define-property-1.0.1/LICENSE) | 已记录 |
| `es-errors` | 1.3.0 | MIT | [LICENSE](texts/es-errors-1.3.0/LICENSE) | 已记录 |
| `es-object-atoms` | 1.1.2 | MIT | [LICENSE](texts/es-object-atoms-1.1.2/LICENSE) | 已记录 |
| `event-target-shim` | 5.0.1 | MIT | [LICENSE](texts/event-target-shim-5.0.1/LICENSE) | 已记录 |
| `events` | 3.3.0 | MIT | [LICENSE](texts/events-3.3.0/LICENSE) | 已记录 |
| `fast-xml-builder` | 1.3.1 | MIT | [LICENSE](texts/fast-xml-builder-1.3.1/LICENSE) | 已记录 |
| `fast-xml-parser` | 5.11.2 | MIT | [LICENSE](texts/fast-xml-parser-5.11.2/LICENSE) | 已记录 |
| `file-type` | 21.3.4 | MIT | [license](texts/file-type-21.3.4/license) | 已记录 |
| `for-each` | 0.3.5 | MIT | [LICENSE](texts/for-each-0.3.5/LICENSE) | 已记录 |
| `function-bind` | 1.1.2 | MIT | [LICENSE](texts/function-bind-1.1.2/LICENSE) | 已记录 |
| `get-intrinsic` | 1.3.0 | MIT | [LICENSE](texts/get-intrinsic-1.3.0/LICENSE) | 已记录 |
| `get-proto` | 1.0.1 | MIT | [LICENSE](texts/get-proto-1.0.1/LICENSE) | 已记录 |
| `gopd` | 1.2.0 | MIT | [LICENSE](texts/gopd-1.2.0/LICENSE) | 已记录 |
| `guarded-fetch` | 0.1.3 | Apache-2.0 | [LICENSE](texts/guarded-fetch-0.1.3/LICENSE) | 已记录 |
| `has-property-descriptors` | 1.0.2 | MIT | [LICENSE](texts/has-property-descriptors-1.0.2/LICENSE) | 已记录 |
| `has-symbols` | 1.1.0 | MIT | [LICENSE](texts/has-symbols-1.1.0/LICENSE) | 已记录 |
| `has-tostringtag` | 1.0.2 | MIT | [LICENSE](texts/has-tostringtag-1.0.2/LICENSE) | 已记录 |
| `hasown` | 2.0.4 | MIT | [LICENSE](texts/hasown-2.0.4/LICENSE) | 已记录 |
| `ieee754` | 1.2.1 | BSD-3-Clause | [LICENSE](texts/ieee754-1.2.1/LICENSE) | 已记录 |
| `ignore` | 5.3.2 | MIT | [LICENSE-MIT](texts/ignore-5.3.2/LICENSE-MIT) | 已记录 |
| `inherits` | 2.0.4 | ISC | [LICENSE](texts/inherits-2.0.4/LICENSE) | 已记录 |
| `ini` | 6.0.0 | ISC | [LICENSE](texts/ini-6.0.0/LICENSE) | 已记录 |
| `ipaddr.js` | 2.2.0 | MIT | [LICENSE](texts/ipaddr.js-2.2.0/LICENSE) | 已记录 |
| `is-callable` | 1.2.7 | MIT | [LICENSE](texts/is-callable-1.2.7/LICENSE) | 已记录 |
| `is-typed-array` | 1.1.15 | MIT | [LICENSE](texts/is-typed-array-1.1.15/LICENSE) | 已记录 |
| `is-unsafe` | 2.0.2 | MIT | [LICENSE](texts/is-unsafe-2.0.2/LICENSE) | 已记录 |
| `isarray` | 2.0.5 | MIT | [LICENSE](texts/isarray-2.0.5/LICENSE) | 已记录 |
| `isomorphic-git` | 1.44.9 | MIT | [LICENSE.md](texts/isomorphic-git-1.44.9/LICENSE.md)；[index.umd.min.js.LICENSE.txt](texts/isomorphic-git-1.44.9/models/index.umd.min.js.LICENSE.txt)；[index.umd.min.js.LICENSE.txt](texts/isomorphic-git-1.44.9/managers/index.umd.min.js.LICENSE.txt)；[IS-GIT-REF-NAME-VALID-NOTICE.txt](texts/isomorphic-git-1.44.9/IS-GIT-REF-NAME-VALID-NOTICE.txt)；[ZENFS-NOTICE.txt](texts/isomorphic-git-1.44.9/ZENFS-NOTICE.txt) | 已记录；另有 LGPL 片段 |
| `just-bash` | 3.6.0 | Apache-2.0；实际捆绑含其他许可 | [LICENSE](texts/just-bash-3.6.0/LICENSE)；[Angular 捆绑声明](texts/just-bash-3.6.0/ANGULAR-BUNDLED-NOTICE.txt) | 已记录；CPython 通知未闭合 |
| `math-intrinsics` | 1.1.0 | MIT | [LICENSE](texts/math-intrinsics-1.1.0/LICENSE) | 已记录 |
| `mimic-response` | 3.1.0 | MIT | [license](texts/mimic-response-3.1.0/license) | 已记录 |
| `minimist` | 1.2.8 | MIT | [LICENSE](texts/minimist-1.2.8/LICENSE) | 已记录 |
| `minimisted` | 2.0.1 | MIT 已声明 | [实际 author/license 字段](texts/minimisted-2.0.1/PACKAGE-DECLARATIONS.txt) | 对应完整版权/许可通知仍 BLOCKED |
| `modern-tar` | 0.7.7 | MIT | [LICENSE](texts/modern-tar-0.7.7/LICENSE) | 已记录 |
| `ms` | 2.1.3 | MIT | [license.md](texts/ms-2.1.3/license.md) | 已记录 |
| `once` | 1.4.0 | ISC | [LICENSE](texts/once-1.4.0/LICENSE) | 已记录 |
| `pako` | 1.0.11 | (MIT AND Zlib) | [LICENSE](texts/pako-1.0.11/LICENSE)；[ZLIB-NOTICE.txt](texts/pako-1.0.11/ZLIB-NOTICE.txt) | 已记录 |
| `papaparse` | 5.7.0 | MIT | [LICENSE](texts/papaparse-5.7.0/LICENSE) | 已记录 |
| `path-expression-matcher` | 1.6.2 | MIT | [LICENSE](texts/path-expression-matcher-1.6.2/LICENSE) | 已记录 |
| `pify` | 4.0.1 | MIT | [license](texts/pify-4.0.1/license) | 已记录 |
| `possible-typed-array-names` | 1.1.0 | MIT | [LICENSE](texts/possible-typed-array-names-1.1.0/LICENSE) | 已记录 |
| `process` | 0.11.10 | MIT | [LICENSE](texts/process-0.11.10/LICENSE) | 已记录 |
| `re2js` | 1.3.3 | MIT | [LICENSE](texts/re2js-1.3.3/LICENSE) | 已记录 |
| `readable-stream` | 4.8.0 | MIT | [LICENSE](texts/readable-stream-4.8.0/LICENSE) | 已记录 |
| `run` | 2.1.3 | Apache-2.0 | [LICENSE](texts/run-2.1.3/LICENSE)；[THIRD_PARTY_NOTICES.md](texts/run-2.1.3/THIRD_PARTY_NOTICES.md) | 已记录 |
| `safe-buffer` | 5.2.1 | MIT | [LICENSE](texts/safe-buffer-5.2.1/LICENSE) | 已记录 |
| `seek-bzip` | 2.0.0 | MIT | [LICENSE](texts/seek-bzip-2.0.0/LICENSE) | 已记录 |
| `set-function-length` | 1.2.2 | MIT | [LICENSE](texts/set-function-length-1.2.2/LICENSE) | 已记录 |
| `sha.js` | 2.4.12 | (MIT AND BSD-3-Clause) | [LICENSE](texts/sha.js-2.4.12/LICENSE)；[SHA1-NOTICE.txt](texts/sha.js-2.4.12/SHA1-NOTICE.txt) | 已记录 |
| `simple-concat` | 1.0.1 | MIT | [LICENSE](texts/simple-concat-1.0.1/LICENSE) | 已记录 |
| `simple-get` | 4.0.1 | MIT | [LICENSE](texts/simple-get-4.0.1/LICENSE) | 已记录 |
| `smol-toml` | 1.9.1 | BSD-3-Clause | [LICENSE](texts/smol-toml-1.9.1/LICENSE) | 已记录 |
| `sprintf-js` | 1.1.3 | BSD-3-Clause | [LICENSE](texts/sprintf-js-1.1.3/LICENSE) | 已记录 |
| `sql.js` | 1.15.2 | MIT | [LICENSE](texts/sql.js-1.15.2/LICENSE)；[AUTHORS](texts/sql.js-1.15.2/AUTHORS) | 已记录 |
| `string_decoder` | 1.3.0 | MIT | [LICENSE](texts/string_decoder-1.3.0/LICENSE) | 已记录 |
| `strnum` | 2.5.1 | MIT | [LICENSE](texts/strnum-2.5.1/LICENSE) | 已记录 |
| `strtok3` | 10.6.3 | MIT | [LICENSE.txt](texts/strtok3-10.6.3/LICENSE.txt) | 已记录 |
| `to-buffer` | 1.2.2 | MIT | [LICENSE](texts/to-buffer-1.2.2/LICENSE) | 已记录 |
| `token-types` | 6.1.2 | MIT | [LICENSE.txt](texts/token-types-6.1.2/LICENSE.txt) | 已记录 |
| `turndown` | 7.2.4 | MIT | [LICENSE](texts/turndown-7.2.4/LICENSE) | 已记录 |
| `typed-array-buffer` | 1.0.3 | MIT | [LICENSE](texts/typed-array-buffer-1.0.3/LICENSE) | 已记录 |
| `typescript` | 5.9.3 | Apache-2.0 | [LICENSE.txt](texts/typescript-5.9.3/LICENSE.txt)；[ThirdPartyNoticeText.txt](texts/typescript-5.9.3/ThirdPartyNoticeText.txt) | 已记录 |
| `uint8array-extras` | 1.6.0 | MIT | [license](texts/uint8array-extras-1.6.0/license) | 已记录 |
| `undici` | 7.29.0 | MIT | [LICENSE](texts/undici-7.29.0/LICENSE)；[LICENSE](texts/undici-7.29.0/lib/web/fetch/LICENSE) | 已记录 |
| `which-typed-array` | 1.1.24 | MIT | [LICENSE](texts/which-typed-array-1.1.24/LICENSE) | 已记录 |
| `wrappy` | 1.0.2 | ISC | [LICENSE](texts/wrappy-1.0.2/LICENSE) | 已记录 |
| `xml-naming` | 0.3.0 | MIT | [LICENSE](texts/xml-naming-0.3.0/LICENSE) | 已记录 |
| `yaml` | 2.9.1 | ISC | [LICENSE](texts/yaml-2.9.1/LICENSE) | 已记录 |

## 构建工具

| 组件 | 版本 | 来源与全文 | 范围 |
|---|---|---|---|
| esbuild | 0.27.3 | [texts/esbuild-0.27.3/LICENSE.md](texts/esbuild-0.27.3/LICENSE.md)；Copyright (c) 2020 Evan Wallace；MIT | 主机构建使用 |
| @esbuild/linux-x64 | 0.27.3 | 同一 esbuild 发布的 MIT；复用上行完整文本 | 本次 Linux x64 主机实际安装的平台二进制，不宣称所有 optional 平台包或最终 HAP 都包含它 |

## 包内嵌入内容

`@mixmark-io/domino@2.2.0/lib/style_parser.js` 保留 Google LLC / MIT-style 许可头，并明确指向 Angular 提交 `92e41e9cb417223d9888a4c23b4c0e73188f87d0`。just-bash 的 `dist/bin/chunks/chunk-DTGQQKI2.js` 也实际包含该声明。这里收录两个发行文件的原始许可块以及该精确 Angular 提交的 [完整 MIT 文本](texts/mixmark-io--domino-2.2.0/ANGULAR-LICENSE.txt)，其 Copyright (c) 2010-2022 Google LLC. 来自上游原文。完整来源摘要、字节区间和版本在 manifest；不以 domino 顶层 BSD 声明覆盖源内 MIT。

本清单核验固定上游包及已识别嵌入来源，不宣称已经穷尽所有源文件的许可。OH 私有构建若修改 just-bash，须由该构建另行固定输入/输出、保留原始 LICENSE 与捆绑通知，并标明修改；这里的原包摘要不冒充修改后生成物的摘要。

isomorphic-git 1.44.9 的 Node 入口 `index.cjs` 明确含有从 @zenfs/core/path 复制的片段，SPDX 为 `LGPL-3.0-or-later`，版权行为 James Prevett and other ZenFS contributors；这段代码并非只在浏览器备用文件中。这里保留原始通知、上游 Windows 适配说明，以及 GNU 官方 [LGPL 3.0](texts/GNU-LGPL-3.0/LGPL-3.0.txt) 和其所引用的 [GPL 3.0](texts/GNU-GPL-3.0/GPL-3.0.txt) 全文。对应源码定位到 isomorphic-git 发布提交 `86df2db391962c8690a7550c6887ca0e87798542` 的 `src/utils/join.js`，SHA-256 为 `748dfaa1d7b2871912c447b0cd8616d083d22e52a0c62d43de81c5b45096c242`。这些事实不能被顶层 `MIT` 字段替代；最终发行的源码提供及其他适用要求仍要按实际制品核对。

同一包 `isValidRef` 的原注释还声明 `is-git-ref-name-valid`、MIT、Copyright © Vincent Weevers；通知原样收录，不推测年份。pako 为 MIT **且** Zlib；sha.js 为 MIT **且** BSD-3-Clause；diff3 两个源文件各自的作者通知均保留，不能只展示一种许可或一位作者。

run 2.1.3 的完整 THIRD_PARTY_NOTICES 包含 devalue 5.8.2、quickjs-wasi 3.6.0 和 QuickJS 的作者与 MIT 全文；TypeScript 的完整 ThirdPartyNoticeText 也保留。关闭这些命令或者没有调用它们，不证明实际分发的字节已经不存在。

## 标准条款与实际归属

clean-git-ref 的精确 `package.json` 已声明 Apache-2.0；本次从 [Apache 官方](https://www.apache.org/licenses/LICENSE-2.0.txt) 收录未改写标准全文，并逐字保留 `Eli White <github@eli-white.com>` 这一 author 字段与许可字段。实际发行的 README、lib/index.js、package.json 三文件已逐一核摘要与现有声明，发行包没有附带 NOTICE。Apache §4(a) 要求随分发提供许可副本，§4(c) 要求保留适用的已有通知；§4(d) 的 NOTICE 保留义务以原作品附带 NOTICE 为条件。标准条款来源与实际包的归属来源在清单中分开记录，不创造原文没有的版权行或年份。

首版把没有独立 LICENSE/NOTICE 直接列为该包的登记阻断，表述过宽；本版补全文及实际归属后解除这一项。对最终制品与修改文件的义务仍需按实际内容核对。

## 尚未闭合的证据

| 项目 | 已取得的证据 | 缺少的证据与定论条件 |
|---|---|---|
| minimisted 2.0.1 | MIT 声明、README 与实际 author/license 字段已保留；精确 gitHead `95fdfb8d6efb9546c1117854fe3a58105f6332ce` 的文件树 | 尚未取得对应完整版权/许可通知；不称许可名称未知，也不把 author 字段改造成推测 copyright 行。取得对应原文或由主线明确登记替代依据，或批准排除/替换后验最终制品。 |
| just-bash 的 CPython/Emscripten vendor | `just-bash@3.6.0`、提交 `7537a260e38648e8998db7a95504102ad80b0194`；python.cjs/python313.zip 的 Git blob 同一，python.wasm 的 LFS SHA-256 同一；二进制可观察 3.13.2-dirty | 实际 dirty 源修订、工具链和嵌入组件的完整许可汇编仍缺。通用 CPython 3.13.2 LICENSE 不能冒充该定制构建的完整通知。需取得对应资料，或 O2 排除并证明最终 HAP 不含这些文件。 |

## 发行与裁剪边界

本次未创建或运行最终 HAP。原样许可文件和收录清单不等于完成 GPL/LGPL 等适用源码义务；也不等于 APK/HAP 中的许可界面已经收录这些文件。安卓资产与界面未在本次修改。O2 应将此目录作为 OHOS 发行核验输入，记录实际打包路径/摘要，并对仍未闭合的项目停止“许可证齐全”的结论。

独立 shadow 裁剪实验只证明现有注册命令的一组测试可以在移除 TypeScript/sql.js/CPython 后运行，未改共享 node_modules 或打包配置；原版 ESM sqlite3 的真实查询成功，裁剪后会明确因缺 sql.js 失败。因此这些删除只能是当前未启用功能配置下的候选，不能无条件用于 just-bash 的全部 API。
