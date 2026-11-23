# Cordis effect 的一次性 setup 引用

`Fiber.effect` 为一次注册创建局部 runner。`_execute` 同步调用 setup，并把调用栈读取函数按值交给 `composeError`。成功返回后，局部 runner 释放 setup 与读取函数。未决异步操作仍可通过错误处理闭包取得注册处的栈；异步迭代继续通过 runner 的 epoch 和 collect 处理取消与清理。

清理函数的执行次序、并发处置和错误组合沿用已有实现。同步抛错仍走已有失败清理路径。插件生命周期的 `Fiber._runner` 继续保存执行函数，供 restart 与依赖切换时再次激活。
