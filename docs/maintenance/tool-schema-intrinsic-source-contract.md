# 工具 schema 的内置构造函数校验

`hasIntrinsicConstructor` 的两个私有调用点分别检查 `Object` 和 `Array`。每次检查仍现场取得原型的自有构造函数描述符，验证函数名称、原型身份，并调用 `Function.prototype.toString` 比对原生源码。两个调用点使用的期望文本均为常量。新增构造函数类型时，须为它提供对应的完整原生源码文本。
