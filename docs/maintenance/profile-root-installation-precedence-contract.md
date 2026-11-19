# Profile 根入口的 installation 选源合同

本改动按第十七波 ADDENDUM-02 的明确决定改变默认优先级。它是 Android 与 OHOS 共用链上的引擎覆片：放在 Android 链末尾，OHOS 链里同一位置也有它，因为 OHOS 链必须以 Android 链为前缀（test_shipped_android_chain_is_the_ohos_prefix）。它是新的产品规则；此前 profile 内普通副本优先的行为不能被描述成原本就违反此规则。

## 生效条件

一个裸包请求同时满足以下条件时，优先使用当前 installation resolution 提供的包：

- 发起位置是当前 active profile 的根目录 URL，也就是普通根 Include 导入条目和预检所用的基址。
- 当前 resolution 有该包名，且其 scope 为 `installation`。
- profile 的 manifest 没有在 `dependencies`、`peerDependencies`、`optionalDependencies` 中直接声明该包名。
- 当前 resolution 的 `linkedRoots` 没有该包名的 external link。

包名按现有 `barePackageName` 解析，规则不按 `@deepseek-ai` 前缀猜所有权，也不按版本号大小选包。

只有这一根入口分支跳过 profile 内的候选扫描；它随后沿既有 interception 分支完成解析。自引用、第三方模块自身的 private/hoisted 依赖、linked 模块、非 active profile，以及未由 installation 提供的包继续采用原规则。兼容性判定、包的 exports、资源错误以及已加载模块的缓存规则不改变。

## 直接声明与 external link

`localPackageNames` 仍表示“已安装直接依赖”，继续服务原有 `routeLocalPackage` 和 replacement 检查。它不能作为新规则中“有直接声明”的完整集合。

`declaredPackageNames` 从本次构造 resolution 时已经读取的 profile manifest 生成，包含上述三种直接声明，即使对应包尚未安装。它随不可变 resolution 传递，编译为名称集合，并进入原有 generation 发布比较；不为每次请求重读磁盘或新增重启策略。

external link 的豁免只来自当前 resolution 的 `linkedRoots`。router 的 `linkedTargets` 会保留用于重定位的历史名称，不能拿它判断当前是否仍有外链。

用户手工放进 `profile/node_modules`、却没声明的同名包，会改用 installation 的版本。想保留自己那份，在 profile 里声明它就行。

显式 `file:` 依赖同样保留原选择，包括 `plugin-config-r7-live.py --mode optional-profile` 使用的官方 optional 模块副本：该夹具将副本以 external symlink 放入 profile，并在 `dependencies` 显式写 `file:`。因此它同时满足直接声明和当前 external link 的豁免。原 r7 对实际来源路径、callback/service prototype、配置读写以及原授权拒绝的断言保持，不改该夹具。

本改动不做安装、重装或 profile 清理，不删除用户数据，不添加选项，也不放宽版本兼容及权限门禁。

## 验证范围

同名 Node 测试通过准备好的 DSH prefix 加载真实 `createRuntimeResolution`、Cordis `Context` 和 `PluginPackages`，核对根入口的实际包 metadata 选择。它覆盖旧未声明副本改选 installation、三种显式声明保留旧副本，以及直接受影响的 private/hoisted 和 external/file 布局边界。另核未安装的直接声明不会被混入原 `localPackageNames` 合同。

```bash
DSH_PREFIX=/path/to/prepared-runtime node --test runtime/tests/profile-root-installation-precedence.test.mjs
```

没有 prefix 时测试明确失败提示，不静默跳过。本执行器没有完整 prefix；正式测试及 r7 live 未运行，须由本机完整 Linux CI/既有 live 检查验证。

本地只对已校验发布原文抽取出的实际 resolution producer/router 运行真实文件夹具，验证相同选源条件；该结果不等于完整 Host、原生 Node loader 拦截、手机升级现场或 r7 live 已通过。原件为 Android 全覆片末态。pins 由本机分别按 Android 和 OHOS 链录制；OHOS 链上随后改同一文件的 ohos-plugin-* 五片都仍能打上，它们的 pins 随之更新。
