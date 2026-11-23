# 工具 schema 的内置构造函数校验

`hasIntrinsicConstructor` 的两个私有调用点分别检查 `Object` 和 `Array`。每次现场读取原型的自有构造函数描述符，再核对函数名称与原型身份。当前 JavaScript realm 的对应内置构造函数可由对象身份直接确认。其他构造函数继续经 `Function.prototype.toString` 比对预期的完整原生源码常量，包括来自其他 realm 的普通构造函数。新增构造函数类型时须指定对应的身份和完整原生源码。
