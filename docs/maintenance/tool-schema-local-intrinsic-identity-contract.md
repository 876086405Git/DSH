# 工具 schema 用同一 realm 的内置构造函数身份完成校验

工具注册和 schema 校验使用当前 Node realm 的 `Object` 或 `Array` 时，原型自有的构造函数已经通过名称与 `constructor.prototype` 身份检查。此时再把内置函数转成源码只会生成相同的预期字符串，直接比较构造函数身份即可。外部 realm 的对象和数组，以及同名的其他构造函数，仍走原生源码比较。拥有名为 `constructor` 的普通数据字段不影响原型判断。

本约定针对宿主内建保持正常的运行环境。主动替换全局 `Object`、`Array` 或 `Function.prototype.toString` 时，旧实现每次调用它们的可观察行为可能与身份短路不同。
