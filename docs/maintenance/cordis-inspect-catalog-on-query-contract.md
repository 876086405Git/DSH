# 查询 Cordis 服务或事件时加载生成目录

Host 启动时注册 Service、Event、Config、Tool 四种检查功能。生成的服务、事件和类型目录（api-catalog.js，约 760 KB 源码）只在前两种查询中使用。普通会话连接、列出提供者、查看 Tool 或 Config 不加载它。

Service、Event 的查询回调在第一次调用时动态导入目录，事件目录沿用首次筛出的 Host Event 集合。输入在调用回调前已由注册表按 schema 校验。这段实现原是 OpenHarmony 独有的覆片，现在两端共用同一份，OpenHarmony 末态不变。目录缺失时，错误后移到第一次需要目录的查询。

在准备好的前缀设置 DSH_TEST_PREFIX 并执行 `node --test runtime/tests/cordis-inspect-catalog-on-query.test.mjs`。`runtime/tests/ohos/cordis-catalog-lazy.test.mjs` 另覆盖并发首次查询、无效输入与逐条契约金标。
