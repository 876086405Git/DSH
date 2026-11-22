# 按需加载产品遥测 HTTP 客户端

默认手机 Web 会话的 OTLP 日志由 OpenTelemetry HTTP 导出器发送。只有桌面产品遥测的独立导出器使用 got。创建产品导出器时从当前模块同步加载锁定版本的 got，仍在返回公开 reporter 前完成加载。Node 的两个入口解析到同一 ES 模块实例。会话授权、产品事件队列、请求设置、重试、取消和关闭沿用各自原有流程。依赖缺失时，首次创建产品通道会报告加载错误。

准备两平台引擎后，分别设置 DSH_TEST_PREFIX，运行 `node --test runtime/tests/otel-product-transport-lazy.test.mjs`。验证先创建并关闭会话通道，再创建产品通道时才解析 got。
