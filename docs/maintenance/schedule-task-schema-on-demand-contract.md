# 提醒任务记录规则按需构造

提醒域的 tasks 表继续使用相同的严格对象规则、默认值、转换和投递回执一致性检查。最末的记录规则整体交给现成的 z.lazy；导入模块或打开空表不构造这棵规则，首次解析记录时构造，后续解析复用。

已有记录仍在开表验证时解析，首次写入仍在存储提交前解析。授权、调度、迁移版本及记录编码不变。record、instant、messageId、sessionId、deliveryReceipt、deliveryHistory、createSpec 和 target 这八个私有子规则也随记录规则按需构造。其它独立规则保持原有构造时机。

公开表字段的类型合同为 ZodType。该包装会把 valueSchema 的具体 type / def.type 从 pipe 改为 lazy；JSON Schema override 遍历可额外观察到这个外层 lazy。具体内部类和遍历节点数不作为稳定合同。普通解析结果、错误与单个 valueSchema 的常规 JSON Schema 导出保持原规则。重复 unwrap() 后的嵌套规则身份及组合导出的 $defs 引用布局不作为稳定合同。
