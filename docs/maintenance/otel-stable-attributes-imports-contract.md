# OTel 的 Node SDK 直接读取稳定属性

默认 Web Host 创建会话日志通道时，core 的 Node SDK 信息、resources 的资源实现和环境探测器、sdk-logs 的日志记录实现只使用八个稳定属性名或枚举值。锁定的 `@opentelemetry/semantic-conventions@1.44.0` 在公共 CommonJS 入口从 `dist/stable_attributes.cjs` 直接转出这八个值。四个消费者经包子路径 `./stable-attributes` 读取同一源文件。公共聚合入口仍供调用者按原路径加载，其 CommonJS 和 ESM 导出均沿用上游实现。

升级依赖时核对四个消费者访问的全部键及聚合入口的转出来源。用准备好的引擎前缀设置 `DSH_TEST_PREFIX`，运行 `node --test runtime/tests/otel-stable-attributes-imports.test.mjs`。
