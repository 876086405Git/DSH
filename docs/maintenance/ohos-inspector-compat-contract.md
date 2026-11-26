# 鸿蒙 Inspector 不可用时的行为

鸿蒙 Node 的正式构建使用 `--without-inspector`，Node 24.22.1 因此报告 `process.features.inspector === false`。DSH `0.2.2-rc.1` 的 Inspector Worker 在模块入口静态导入 `node:inspector`；不能把缺少原生会话伪装成已连接。

保持官方实验 profile 的默认状态。手动启用 Inspector 且无编译能力时，在分配 MessageChannel、启动 Worker 之前返回 `ERR_FEATURE_UNAVAILABLE_ON_PLATFORM`。插件沿用上游不可用分支：发一次告警，bootstrap 返回无响应体、不可缓存的 HTTP 503；不注册 Inspector 服务、DevTools 静态资源或 CDP upgrade，也不发布浏览器连接参数。直接请求该 upgrade 时，WebServer 没有匹配路由，按既有行为关闭 socket，不返回 101。其他启动错误不转成能力不可用。

补丁只针对 `targetSets.ohos` 的 `@deepseek-ai/dsh-experimental-inspector@0.2.2-rc.1` 正式发布入口。npm 归档用 [主线 SRI](../../runtime/locks/dsh-0.2.2-rc.1/package-lock.json) 校验；[pins](../../runtime/patches/pins.json) 固定入口的补丁前后 SHA-256。Android 不选此补丁。

远端门禁的 `inspector-compat` 组复用 `android-targets` 生成的 OH 已打补丁前缀，加载实际 npm 入口，用替身模拟缺少 Inspector 的编译能力，断言不加载 Inspector、不启动 Worker、bootstrap 降级、不发布连接并能卸载。可用同一前缀独立运行：

```sh
DSH_TEST_PREFIX=/absolute/ohos-prefix node --test runtime/tests/ohos/inspector-compat.test.mjs
```

该用例不是鸿蒙真机证明。真机需确认手动启用后引擎仍健康、bootstrap 返回 503、直接 upgrade 不返回 101 且连接终止。
