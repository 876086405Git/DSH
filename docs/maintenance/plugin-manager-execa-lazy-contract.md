# 按需加载插件管理的子进程模块

普通 Web 启动会加载插件管理服务。只有执行包管理命令或探测 Git 仓库时，该服务才需要 execa。七个调用点都同步取得原函数返回值。安装及恢复流程由此仍能立即读取子进程 PID、注册退出监听、跟踪取消和回滚。依赖缺失时，首次需要启动子进程的操作会收到加载错误。

在已准备好的 Android 和 OpenHarmony 前缀运行 `node --test runtime/tests/plugin-manager-execa-lazy.test.mjs`，用 DSH_TEST_PREFIX 指定目标前缀。原有两平台执行限制、包与注册源选择、退出码、并发互斥和日志归属继续生效。
