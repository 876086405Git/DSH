# OTLP 日志直接引用自己的 JSON 序列化器和条数统计

dsh-otel 只发送日志。直接引用锁定 OTLP transformer 中原有的 JsonLogsSerializer 和 LogsExporterMetricsHelper，日志通道启动时省去指标 SDK、trace 与 protobuf 转换器。两项仍在正常静态导入阶段初始化。

两个路径属于 @opentelemetry/otlp-transformer 0.222.0 的已发布 CommonJS 构建。包未声明 exports，聚合入口转出的两个对象就来自这两个文件。依赖升级时复核发布路径和导出身份。在准备好的两个平台前缀设置 DSH_TEST_PREFIX，运行 `node --test runtime/tests/otel-log-transformer-imports.test.mjs`。
