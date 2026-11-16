# 906：普通文件镜像准备与真实三盘首次安装

这是 P0 安装前置切片，尚非 HAP/设备 READY。App 侧 prepareLinuxImages 只校验、gunzip 普通镜像文件和复制/补齐归档；不创建 symlink，不调用外部程序。构建机 build-image.py 用 mke2fs 产生 bootstrap 和空 ext4 压缩种子。guest 从第二块只读 virtio disk 读取下载归档，在第三块可写 ext4 内执行 tar，链接仅产生在 guest 文件系统内。

run.py 接收 --source-archive、--diskimage、--alpine、--output（新目录）、--cc、--node。固定输入 SHA 由 source-lock.json 和 build-image.py 校验。Node 生产入口需由安装 owner 提供可信私有绝对路径及固定 manifest；返回 prepared-images，不提交 active，不产生 READY。取消准备会销毁本次自有 staging。

## 真实证据

基线 0001–0009 中 JSON readOnly 未生效；专用 guest 探针对归档写入成功，实际破坏归档，安装失败。候选 0010 同时选 BF_MODE_RO 并提供 VIRTIO_BLK_F_RO；guest 写入拒绝，归档 SHA 保持，实际 tar 完成，chroot 执行读取 Alpine 3.24.4 与 /bin/sh 链接。sync/umount 后 marker 成立，stop/join 成功、借入双 FD flags 不变。测试用 --readonly-probe 才打开破坏探针，默认镜像不包含此探针。

最终还由 strict/jitless Node 实际解压压缩种子、复制归档生成镜像，再启动同一原生库完成真实 guest 安装。core 3、CLINT 13、低字写 1 在基线和候选均通过。prepare-images 三项测试覆盖成功、取消、压缩/展开/归档完整性错误，jit 与 strict 均通过。

## 尚未闭合的边界

这里 chroot 仅为执行结果探针，不宣称文件隔离。没有 gh/git/python/rg 工具安装、正式 guest agent、授权文件服务或 HAP 装配。安装 VM stop 后仍保留设备堆与 drive FILE；不得删除文件来伪装取消完成，不得重用 owner 或 dlclose。908 将单独研究实际盘 FD retirement；完整释放/同 App 重启仍未完成。成功后正式路径需同 VM 进入安装后的系统，或完整 teardown 后重启；本件未实现。不得将 minirootfs 校验、prepared-images 或 marker 当 READY。

生产 bootstrap 镜像目前仍由 Alpine 构建，因此最终分发应审计 BusyBox/Alpine 包许可证，Bellard 内核 GPL 对应源码与 TinyEMU MIT/slirp 通知。本件不新增生产 HAP 依赖，也不替本机批准分发依赖。

VIRTIO 只读设备能力采用官方规范 bit 5：https://docs.oasis-open.org/virtio/virtio/v1.0/virtio-v1.0.html 。只在宿主拒绝 block write 不足以使 guest buffered write 同步失败，早期 run-01 保留了此反例。
