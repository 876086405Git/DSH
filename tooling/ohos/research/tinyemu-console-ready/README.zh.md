# 控制台输入就绪边界：有限原生门

本门覆盖TinyEMU一次事件轮询：console的VirtIO RX队列未ready或ready但无可用descriptor时，slirp的真实UDP回复仍会使select可读。产品只在实际把console FD放进read set后才检查它，避免未赋值的局部FD被用于FD_ISSET。

测试包含完整产品temu.c翻译单元、实际slirp_open/fill/poll、真实loopback UDP和实际virtio_net_init/virtio_console_init。CPU发Ethernet包、guest console ring/MMIO写入和IRQ送达为显式夹具；实际控制台read走原controlled console_read/recv。select/recv的链接观察器只转发真实syscall并计数，不制造readiness。case是独立进程，本门不检验其保留队列的最终free或产品shutdown。

旧版诊断七项中两项因FD非法运算为红，另外五控制绿；候选在同一诊断编译和普通产品flags各七项全通过。诊断明确使用宿主编译器的-ftrivial-auto-var-init=pattern与UBSan（本次GCC14.2）。这不是生产flags，不据此宣称普通构建/真实guest/设备实际发生同一崩溃。普通控制覆盖真实console四字节写入guest ring、同时network和console可读、EOF保留原input-failed语义，以及无事件和无console。

实际登记tinyemu-console-ready只需要固定TinyEMU archive、Node24.22.1 headers与具备上述诊断flags/UBSan的宿主C编译器。run.py在新目录按source-lock新编完整当前native，反向移除唯一0022形成旧对照；两个源只差temu.c的两行。再以实际build flags及同一批未改变objects链接探针。输出report.json保留argv/源码和对象SHA/两诊断红的原stderr/全部绿原数。没有完整门准备、guest kernel、SDK/HAP/设备或CPU/PSS收益宣称。

该原生补丁是OH native source-lock的0022增量，不改10ms cap、stop/join、ABI、RAM/磁盘退休。单项从a836880原native24锁构建为25锁，包含原16patch加0022；它可独立构建，不需要此前0017–0021。合到最新累计时，只追加同一0022和对应lock条目，保留已有0017–0021与binding/RAM改动，不能用单项旧基底的整个lock覆盖新累计。

SDK构建入口不变；本机在已有匹配Node/SDK/rename输入下运行：

```sh
python runtime/ohos/linux/native/build.py \
  --source-archive /absolute/input/tinyemu-2019-12-21.tar.gz \
  --node-headers /absolute/node-24.22.1/include/node \
  --cc /absolute/approved-clang/bin/clang \
  --sdk-native /absolute/api26-sdk/native \
  --libnode /absolute/renamed/libnode.so \
  --rename-header /absolute/source/runtime/ohos/node/napi-rename.h \
  --output /absolute/new-build-output
```

示例绝对目录由本机替换为其已锁输入；不能把宿主gcc诊断命令当作OH构建命令，也不假设SDK自带clang可替代libnode既有工具链。此处没有新Node/C++依赖或ABI改动，既有dsh_napi隔离与NODELETE验证继续由build.py执行。完整1211 waker/deadline/FD生命周期仍独立BLOCKED，本门不放行长等待。
