# J 票据 PDF 文字层依赖

`pdfjs-dist` **6.5.438** 是 Mozilla PDF.js 的官方 npm 发布，采用 Apache-2.0。
本仓库只提交依赖声明、标准 npm lock 和调用源码，不提交官方生成代码、字体、CMap 或安装目录。

- 官方包：`https://registry.npmjs.org/pdfjs-dist/-/pdfjs-dist-6.5.438.tgz`
- npm integrity：`sha512-vg8Pw1x+AFKy4AMDvhuWl5cOYV8d698UoEANoFFhc79hqXDnZQqnOXoxw3HG907WHOg1JYOvLhP756boddFxpA==`
- Node 要求沿官方包 `>=22.13.0 || >=24`；该功能另核当前 Node 提供 `registerHooks`。
- 原许可证随安装包保留：`LICENSE`、`cmaps/LICENSE`、`standard_fonts/LICENSE_FOXIT`、`standard_fonts/LICENSE_LIBERATION`。

## 本机准备与装配

从仓库根运行：

```sh
python3 -I runtime/tests/test_bridge_dependencies.py
npm ci --prefix runtime/bridge/dsh-go-bridge --ignore-scripts --omit=optional --no-audit --no-fund
node --test runtime/tests/companion-receipt-pdf.test.mjs
```

Python tooling 测试各自创建临时的假安装目录，只验证真实 staging、OH composer 的文件选择/复制、
许可证路径保留和 Android recipe 输入边界；这些字节不是可执行 PDF.js，不运行或冒充 PDF 解析。
因此 Generated files 任务的 Python discovery 无需事先安装 bridge 依赖，也不改工作区的安装目录。
真实已安装依赖的版本、许可证及 **stage 后实际 PDF 文字提取**在上面的 Node suite 中硬性验证；
缺少真包会失败，不自动跳过。现 Runtime CI 先执行同一 `npm ci`，再以 `runtime/tests/*.test.mjs`
运行该 suite；这与不需要 npm 安装的 Python 工具测试是两项不同证据。

`runtime/build-runtime.sh` 采用独立 bridge npm prefix，按同一 lock 运行 `npm ci --omit=optional`，再通过
`runtime/lib/bridge_dependencies.py` 复制解析用的 190 个官方文件到临时 bridge，交给现有 `rtbuild --bridge`。
OHOS 的现有 `prepare-inputs.py` 同样准备第三个 bridge prefix；`compose-runtime.py` 核对其安装收据和
精确 lock，然后取同一子集。没有改变原生目录、模块补丁、Android/OHOS 补丁前缀或全局 provider。
CI 也先按 lock 安装，然后运行原 source harness 和测试。

APK 使用已准备的 `runtime/out/<ABI>/assets`：Gradle 的两个 ABI sourceSets 会把对应 runtime 归档带入包。
`tooling/build-apk.sh` 的 release 入口先核该归档与 manifest，打 APK 本身不会代替上述 runtime/npm 准备；
需要从当前源码先生成所选 ABI 的 runtime，再构建 APK。归档内的 bridge 保留所选 PDF 文件及以下许可证。

保留的子集是原始 package/README/许可证、`legacy/build/pdf.min.mjs`、`pdf.worker.min.mjs`、`cmaps/` 和
`standard_fonts/`。不装 optional canvas，不装载 native addon，也不把 viewer、Wasm、源码映射和声明文件放进
这两个手机运行时的 bridge payload。标准 npm 安装目录和临时运行时产物不属于提交内容。

lock 由 `npm install --package-lock-only --ignore-scripts --omit=optional --no-audit --no-fund` 生成。
optional canvas 及平台包在标准 lock 中有记录，`--omit=optional` 不安装它们；worker 的实际 resolver 也拒绝
`@napi-rs/canvas`，不因环境已有该包而加载它。

## 执行边界

只走 `receipt-pdf.js` 创建的有限 worker：继承原 Node preload/flags，使用原任务 abort，输入最多 4 MiB、
最多 5 页、有限文本和条目预算。只提取 PDF 文字层，图片不做 OCR，不执行文档动作。
worker 的 `fetch` 被拒绝；CMap/字体仅允许源码中的官方文件名集合，资源只能来自这个已安装包。
解析缺依赖、版本不符、加密、限额或错误都明确失败，不以空成功代替。

本机还须实际执行完整 `npm ci`、两端运行时组成、完整 Node CI 和目标设备验证；源码轻测不能替代这些步骤。
