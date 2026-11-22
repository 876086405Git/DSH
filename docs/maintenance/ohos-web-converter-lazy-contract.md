# Web 工具首次 HTML 转换

DSH 0.2.2-rc.1 的两端共用已有的 `ohos-web-converter-lazy.diff`。该片跟在 `web-table-pipes.diff` 后面。文件沿用原名，以保留现有覆片内容、摘要和鸿蒙验收入口。

Web 工具注册、纯文本输出和深度超限的 HTML 沿用原处理。首次需要转换 HTML 时，加载锁定的 Turndown、Domino 和 GFM，安装全部既有规则后发布共享实例。构造或安装规则失败时沿用本次安全省略的结果；下次新结果仍可初始化。已初始化后遇到单次转换错误继续复用该实例。

运行 `DSH_PREFIX=/实际前缀 node --test runtime/tests/ohos-web-converter-lazy.test.mjs` 验证真实工具入口的模块加载边界。两端网页输出、表格、连续竖线和故障恢复沿用已有验收。
