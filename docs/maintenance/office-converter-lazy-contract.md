# 首次 Office 转换才加载 LibreOffice

默认 Web Host 会挂载文档预览。服务构造时验证配置、建立队列并登记关闭回调。队列首次执行一项实际转换时沿用转换槽已有的 Promise，通过动态导入取得 LibreOffice 工厂。并发转换、取消、错误映射、缓存及输出沿用现有实现。

这段加载代码来自已发布的 OHOS 组合覆片，现移入两端共用序列。OHOS 仍在转换前返回原来的不可用提示；完整 OHOS 文件及动态省略清单引用的末态哈希保持相同。Android 首次转换加载原包和原引擎，后续调用使用已有转换槽。

主线程的包入口不导入 fontkit。字体解析只在转换 worker 和字体快照 worker 里发生，两个 worker 各自导入 fontkit；CLI 保留原导入。升级 libreoffice-kit 时复核主入口是否开始直接使用字体 API。

转换 worker 在一个同步函数里读取 `soffice.data` 并复制成独立的 ArrayBuffer，读出的原 Buffer（约 22 MB）不会跟着异步会话一直活到转换结束；工厂的 `getPreloadedPackage` 只拿到副本。
