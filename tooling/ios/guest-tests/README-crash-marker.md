# W1 中断记录验证

本测试只使用合成路径和数据。原生改动未在 Apple SDK、NodeMobile 或真机核实，Linux 结果不能替代 iOS guest CI。

## 可直接运行的验证

从仓库根目录执行：

```sh
python3 tooling/ios/guest-tests/test-crash-marker.py
python3 tooling/ios/guest-tests/test-crash-addon.py /absolute/path/to/matching/include/node
```

第一项用系统 C 编译器执行正式 `guest_crash.h`，真实创建/同步/删除文件：杀掉持有记录的子进程，另一进程必须看到暂停且不能开始任务；显式恢复后才能重新执行。其余覆盖文件与目录 fsync 失败、截断写、EINTR/短写、代次误清、记录 inode 被替换、未 settled 保留记录、已释放 fd 以及符号链接不能写到别的文件。fsync/write 故障是测试局部注入，产品没有故障开关。

第二项用正式 `guest_addon.cc` 编出 Linux N-API addon，只把 kernel backend 换成合成夹具：它执行正式marker helper，在真实文件上注入fsync失败，然后在N-API事件派发之前模拟用户resume，实际删除记录。实测这时exit仍携带 `ios_guest_suspended`、没有 started 事件，且尚未进内核的拒绝确实 `resourcesSettled=true`。这验证暂停分类在持锁失败时就已固定，不能靠派发时再读文件推断。夹具的 start/wait 等函数如果误被调用会立即失败。它不执行 iSH，不证明 guest 指令、Apple 链接或信号共存。

已在 Linux x86_64、系统 gcc/g++、Node 24.22.1 执行以上两项：10 个 POSIX 用例通过，真实 N-API 适配器连续两次暂停拒绝通过。另用固定上游 c5c264da 加本基底的 build.patch 和 job-runtime.patch 的真实头文件，对正式 guest_backend.c 执行了 gcc C 语法/类型检查；因为本机没有 SQLite 开发包，仅为未调用的 SQLite 句柄提供了三项 opaque typedef，未声称完成 iSH 链接或运行。

## 待主线验证

- Apple 模拟器 guest CI：正常 deny/identity/exit/cancel/after，正常和取消结束均不存在 active-task。
- 在首次初始化及正在跑命令时终止 App：重启后 status 暂停、guest 路由不载入 Bridge，Linux 命令给出明确错误；虚拟 shell 仍可用。
- 安装/卸载/重装保留暂停记录，显式 resume 后下一次引擎启动恢复。
- 真机文件与父目录 fsync 行为、后台/系统终止、实际 Swift C 符号解析。

现有 touched-start 失败的 resourcesSettled 报告问题属于上一波 19；本补丁只保留该路径的记录，不把该问题称为已修复。
