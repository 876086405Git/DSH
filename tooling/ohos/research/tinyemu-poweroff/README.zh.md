# TinyEMU guest poweroff 返回宿主

这是 P0 的独立前置修复，**不是 App 内 Linux READY 或可构建 HAP 接线**。固定 TinyEMU 2019-12-21 加已归档 707/803/812/815/814 补丁后，HTIF tohost=1 仍执行 exit(0)。本修复让嵌入模式记录 machine-thread 私有 poweroff 标记，当前 CPU 批次结束后从嵌入调用返回 -3（STOPPED_UNRELEASED）。CLI 分支保留 exit(0)。没有捕获信号、longjmp 或全局覆盖 exit。

返回 -3 只证明 CPU 分派循环已返回，设备及文件引用仍保留。调用方必须保持 owner 隔离，不能再次初始化、dlclose 或宣布取消/清理完成。本入口不导入旧 console wrapper，因为其运行期返回、线程join和输出drain尚未完成。没有生产能力开关，Android、runtime/direct 和 runtime/ohos/node 不变。

从仓库根运行（Python >=3.12，现有 C 编译器）：

```sh
python3 -I -B tooling/ohos/research/tinyemu-poweroff/run.py \
  --source-archive /absolute/path/tinyemu-2019-12-21.tar.gz \
  --output /absolute/path/new-evidence --cc /usr/bin/cc
```

源归档 SHA256 be8351f2121819b3172fcedce5cb1826fa12c87da1b7ed98f269d3e802a05555。脚本不联网、不安装依赖、不构建 HAP。门登记 tinyemu-poweroff，需 config 的 tinyemu_source_archive 和 cc。基线与候选均真实编译；19字节 BIOS 标记通过实际 HTIF 输出后触发 guest poweroff。基线进程 exit0但 API 不返回是红；候选返回-3且 caller继续是绿，不能把两个exit0都算成功。

同次运行保留 707 core 3项、803 CLINT 13项、814低字写1项，两棵源均通过。该观测不是全Linux、工具命令或设备测量。全部命令与stdout/stderr、库/源输入SHA保留。普通CLI条件分支仅源码复核，未执行独立CLI构建。

构建配方自足包含原补丁字节，不需要先应用未合815/814主补丁。来源包名和SHA见 provenance.json；0007是本次新修复。TinyEMU上游MIT；随源slirp按各源文件保留BSD类通知，不能把整库简单称作全部MIT。没有新增第三方版本，未把任何库加入HAP。本机正式接线仍需审核实际链接闭包与完整许可证。

P0尚缺：运行期其它fatal/error返回；可唤醒的stop/join；完整设备回收或明确常驻owner；guest job独立stdout/stderr与EOF/ACK；9P授权根与FID租约；华为云固定镜像下载/安装；Node N-API隔离插件；OH交叉编译及实际HAP。不能仅打此补丁就对用户开启Linux。
