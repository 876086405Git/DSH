# tawcroot 手机存储绑定边界

## 触发条件

已授权的手机存储绑定在 `/sdcard`，`/root/手机存储` 是指向它的符号链接，rootfs 同名 `/sdcard` 下还留有不可搜索的占位目录时，经快捷链接打开子目录会在 tawcroot 的预先解链阶段得到 EACCES，直达 `/sdcard` 的路径却能读。

PRoot 5.1.107.102 的 `build_glue()` 会用模式 000 创建最终绑定点，正常退出时由析构清除；异常终止留下的占位目录是具体的生产来源。不能据此认定所有新安装都会失败，或认定问题发生在 Android FUSE。

## 本地覆片

`runtime/tawcroot/bind-aware-oracle.diff` 针对 `source.json` 固定的 tawc commit。`prod_readlink` 遇到已激活的绑定目标或它的子路径时停止查询 rootfs shadow，使用 resolver 现有的 ENOENT 停步分支保留当前 suffix，再由最后一遍绑定路由选择 fd 并执行只读检查。

它不新增绑定、不读取绑定源中的符号链接、不改变权限。快捷链接自身的 NOFOLLOW/lstat/readlink 仍经过 rootfs；`PhoneStorage`、`TawcrootLaunch` 和硬链接转换规则均不变。同名用户目录及自定义链接不会被覆盖。更深绑定的父级符号链接等其它路径语义没有在本片全面重做。

构建顺序是原 archive SHA256 验证、提取、唯一旧块覆片、两 ABI 编译、ELF 检查及发布。源 commit/archive digest 保持原值；产物 manifest 的 `sourcePatch` 另记本地 diff 的路径与 SHA256。更新上游 pin 时应重新核对该旧块，不得静默跳过覆片。

## 定向验证

```sh
python3 -m unittest discover -s runtime/tests -p test_tawcroot_build.py
python3 runtime/tawcroot/build.py --archive /path/to/pinned-tawc.zip --offline --ndk /path/to/ndk/28.2.13676358
```

前一项检查构建接线、原 archive 身份、本地 diff 身份及旧块唯一性，编译器由测试替代；后一项才是真实 NDK 两 ABI 编译。独立 host C 复算把原/改的实际 `prod_readlink` 与 pinned resolver 一同编译，证据与运行入口随补丁说明交付。host C 复算不替代真机确认。
