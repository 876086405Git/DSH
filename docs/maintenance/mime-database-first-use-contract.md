# 首次查询 MIME 类型时加载数据库

默认 Web Host 同时装入 gzip 中间件和会话文件控制器。compressible 在首次收到非空字符串类型时读取并保留 mime-db。会话的 /api/file 处理器在路径、类型、体积与版本检查通过后加载 mime-types，GET 和 HEAD 使用原有的扩展名映射和未知类型回退。压缩判断继续以数据库明确的 true/false 为先，并使用原有的缺项回退规则。两条路径共享同一份锁定的 CommonJS 数据库。首个需要压缩判断的 HTTP 响应会承担加载成本。

依赖升级时核对 compressible 和 mime-types 是否解析到同一 mime-db。以已准备的引擎前缀设置 DSH_TEST_PREFIX，运行 `node --test runtime/tests/mime-database-first-use.test.mjs`。
