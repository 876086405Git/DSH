# 工具作者模式的注解字段

`@deepseek-ai/dsh-tools` 的作者模式编译器使用四个共有注解字段。对象属性可额外声明 `required`。两张私有表在模块内构建，按每个节点已有的 `allowRequired` 选择。各类型继续添加自己的可用字段，逐一检验作者输入并按原先顺序报告错误。

本片对应 Android 与 OHOS 的同名引擎覆片。维护时用 `runtime/tests/tool-author-annotation-keys.test.mjs` 检查必填属性编译和注解表的复用。
