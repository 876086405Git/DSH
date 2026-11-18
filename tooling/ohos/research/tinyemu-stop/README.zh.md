# 904-R2：TinyEMU 输出取消、机器线程 join 与实际 Linux boot

本件是P0原生前置切片，未做HAP/真机验证，未实现VM全部设备释放或guest作业协议。真实反例：输出socket预填饱和且接收端不读，旧入口使机器线程阻塞，2秒pthread_timedjoin超时；接收端关闭，旧入口被SIGPIPE结束宿主（-13）。新controlled入口的输出采用send(MSG_DONTWAIT|MSG_NOSIGNAL)及poll，机器线程检查调用方的stop回调；两例分别返回-4/-5且pthread_join成功，原FD flags不变。不是替换全局SIGPIPE handler，不是pthread_cancel。

## 接口

`temu_embed_run_controlled(path, in_fd, out_fd, initialized, should_stop, opaque)`：in_fd/out_fd均借入stream socket；调用者拥有一个机器线程及这些FD。stop和initialized回调都在机器线程同步执行，必须不阻塞、不调用JS。stop应读native原子标志。输出错误/取消返回后caller join机器线程；其后仍必须保留VM设备owner及库，不能dlclose或重新创建VM。controlled入口用atomic_flag只允许一次真正启动；后续调用返回-6（OWNER_UNRELEASED），测试已核。同一库的旧研究入口仍保留，产品不得混用绕开owner。

- -1：参数/已定义的可回收启动错误；本controlled实现一旦取得owner即不自行解锁，即使启动错误也需保留现状。
- -2：未证明回收的初始化失败。
- -3：HTIF poweroff后CPU分派返回，仍未释放设备（900）。
- -4：已观察到stop，CPU分派返回，仍未释放设备。
- -5：输出transport失败，CPU分派返回，仍未释放设备。
- -6：已有controlled owner，拒绝重新开始。

这不是通用硬超时：初始化文件/设备同步IO、initialized或should_stop回调如果永不返回，仍不能保证停止；任意kernel/CPU缺陷、其它exit/assert/abort仍未全部消除。poll的10ms不是手机总取消延迟承诺；可能正在执行CPU批次。正常job取消不能直接停止VM，要用guest任务范围协议；904只是VM停机接口。没有双流EOF/ACK、文件授权租约或完整D证明。

## 真实guest

固定Bellard 2018 bbl64/Linux4.15 + Alpine3.24.4 riscv64 minirootfs，mke2fs -d生成128MiB ext4（不mount），关闭较新orphan_file/metadata_csum_seed特征。实际库日志确认内核挂载vda、运行Alpine/sbin/dsh-init、输出uname和__904_LINUX_BOOTED__；之后stop/join成功、返回-4。这里仅是boot探针标记，不是可信job协议/READY。无network/9P，不安装Python/gh/git/rg，不称镜像可直接用于生产。

build-image.py保留builderUid。非root构建会保留构建者UID，输出仅作boot fixture；分发镜像必须另外审计/归一化guest文件所有权。首次手工探针mount /dev报Resource busy（内核已挂），正式init删去重复mount，最终日志无此项。没有装fakeroot或新依赖；需要现有mke2fs。

## 命令和门

```sh
python3 -I -B tooling/ohos/research/tinyemu-stop/run.py \
 --source-archive /abs/tinyemu-2019-12-21.tar.gz \
 --diskimage /abs/diskimage-linux-riscv-2018-09-23.tar.gz \
 --alpine /abs/alpine-minirootfs-3.24.4-riscv64.tar.gz \
 --output /abs/new-evidence --cc /usr/bin/cc
```

门tinyemu-stop-boot要求tinyemu_source_archive、tinyemu_diskimage_archive、tinyemu_alpine_archive、cc；单项600秒，未运行完整门。两版707 core3/803 CLINT13/814低字写1均通过。最终run03是新增单次owner拒绝后的真实重编结果；随后只删除镜像脚本不必要的root前置、增加UID范围记录，并在final-image/final-console重新执行实际build+boot。VM补丁/C harness未再改变。run01/run02是更早有限结果，保留原件，不倒填新owner约束。

本补丁自足包含900及更早固定源差，直接对6459f947 apply，无需先合未合包；不是将900研究目录再叠一次。只增tooling研究目录和一条gate，Android/runtime/direct/runtime/ohos/node不变。来源与许可证同900：TinyEMU固定上游MIT、slirp按实际源通知；rootfs和内核各自许可证仍需分发闭包核验；本包没有新增HAP依赖。

## R2：独审输入FD反例已修

R1精确SHA597095d199a8d62868d5a1a6d92e6f5ae6e407026cc8c6abf05166e54c099ebd为BLOCKED：console_init_fds沿用F_SETFL O_NONBLOCK，影响借入in_fd共享OFD；R1测试仅核out_fd。R1包与原反例保留。R2新增0009-controlled-input-socket.patch：controlled输入用recv(MSG_DONTWAIT)，初始化不改flags，透明返回字节、不执行旧Ctrl-A转义；验证输入是stream socket且处于select可表示范围。断开控制输入记录-7 INPUT_UNRELEASED并离开CPU循环，不假装普通job stdin EOF（job EOF应是协议帧）。

三版实跑：旧baseline饱和join超时/closed SIGPIPE；R1两例均能join但inputFlagsUnchanged=false；R2同两例input/output flags均不变。R2另真实启动同一Linux镜像两次（分别新宿主进程）：显式stop返回-4、断开输入返回-7，两次join与双FDflags均成立。每版core3/CLINT13/低字写1通过，原raw命令和日志在raw-run-01。R2没有修改VM device release或其它fatal边界，仍不得dlclose/重复启动。
