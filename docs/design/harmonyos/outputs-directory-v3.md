# P3c 专用产出目录与 P2 v6 布局

基底为 `3fc4081`。本增量依赖 P2 v6 的 `RuntimeController.paths`，使用 Controller 保存的同一个 Context 所派生的路径。未经过 HarmonyOS SDK 编译，未在真机核实。

`dsh/files.listOutputs` 只遍历 `<guestRoot>/root/workspace/DSH-Go`，不遍历工作区其他项目文件和依赖。既有深度参数、500 项上限、隐藏文件及符号链接排除、mtime 秒转毫秒和返回 Map 形状不变。专用目录尚不存在时返回空表；其根被替换为链接或普通文件时明确拒绝，不先枚举链接指向的内容。P2 启动时创建此目录，并在受管理的 AGENTS.md 中告诉 agent 将交付文件放在那里；尊重用户已去掉 managed 标记的自有指令文件。

打开与导出的白名单仍为工作区、应用 cache 和 temp。迁移后的工作区根取自 P2，不允许通过 `DSH_HOME`、`.agents`、词法 `..` 或链接访问其他目录。真正读文件仍经既有 C++ `openUserFile` 的逐段 NOFOLLOW 描述符边界。

Linux 验证使用实际产品 ETS 擦除后的实现、实际 RuntimePaths、真实文件和生产 C++ 描述符打开器；Controller 生命周期在 P2 通道套件单独执行，选择器/Flutter/OH fs 外层仍为明示替身。新增断言在同一工作区放入 package.json、node_modules、项目普通文件和 DSH-Go 成品，只有后者进入列表；另测目录不存在、根链接以及私有 DSH_HOME 导出拒绝。最终完整文件通道为 19/19，零跳过；递归公开声明核查的 8 个产品模块图为零 TypeScript 诊断，仍不是 ArkTS 编译。精确补丁、命令和原始记录随本增量交付。

真实 OH 文件授权、系统选择器和多窗口 Context 行为仍需主线编译及设备验证。本修改不增加 READ_MEDIA/WRITE_MEDIA 权限。
