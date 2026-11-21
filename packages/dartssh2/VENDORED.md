# dartssh2 本地补丁

- 上游：<https://github.com/vicajilau/dartssh2>，pub.dev `dartssh2 4.1.0`。
- 原版归档：<https://pub.dev/api/archives/dartssh2-4.1.0.tar.gz>。
- 归档 SHA-256：`39359aceafcf5940b868249e3c9c6d86e4e0f989eec7417d033c943157c84c51`。
- 保留上游 MIT 许可证及版权署名，见 [LICENSE](LICENSE)。仅导入源码、测试与必要包配置；不保留演示媒体、示例及上游 Docker/基准脚本。测试目录中的固定私钥均为上游公开测试夹具，不是用户凭据。
- 原版文件除下列补丁外保持字节一致，不改全局 pub cache，不新增密码学/密钥交换实现。

## 修改范围

- `lib/src/ssh_client.dart`：新增 `SSHClient(..., compression: false)` 命名参数并传给 transport。
- `lib/src/ssh_transport.dart`：独立协商两个方向的 `zlib@openssh.com` / `none`；`USERAUTH_SUCCESS` 本身不压缩，之后在应用回调前启用；发送/收到各方向的 `NEWKEYS` 后分别重置该方向的流，含认证后的 rekey。压缩发生在封包加密前，解压发生在完整验签解密后。
- 同一 transport 的已编码 socket 写入与 `flush()` 按调用顺序串行，避免 native `IOSink.flush()` 尚未完成时内部异步写入触发 bound-sink 异常；通常写入仍同步。`test/src/ssh_transport_flush_order_test.dart` 覆盖顺序与错误关闭，OpenSSH 互通回归包含数据写入期间的 flush。此补丁不修 channel/session/forward 异步输入管线尚未排空就调用 transport flush 的既有问题。
- `lib/src/compression/ssh_zlib*.dart`：条件导出 dart:io 的持续 `RawZLibFilter` 流，逐包 `Z_SYNC_FLUSH` 并保留字典，不按包 finish；解压累计上限 35000 字节（兼容 32768 字节 channel data 加消息头），超限或畸形数据以 `SSHPacketError` 终止连接。RawZLibFilter 没有 abort/dispose，关闭或 rekey 时丢弃引用交原生 finalizer；不继续 drain 不可信输入。
- `lib/src/{hostkey/hostkey_ed25519.dart,http/http_client.dart,message/msg_request.dart,sftp/sftp_file.dart,ssh_client.dart,ssh_kex_utils.dart,ssh_message.dart,utils/bcrypt.dart}`：清理上游遗留的注释掉的实现与调试输出；仅移除注释，不改变执行代码、协议或密码学实现。
- `pubspec.yaml`：禁止发布本地补丁包。
- 新增 `test/src/ssh_compression_test.dart`、`test/src/ssh_compression_web_test.dart` 和 `test/src/integration/openssh_compression_test.dart`。

## 使用契约

库默认关闭压缩，保持上游默认行为。App 可显式传 `compression: true`。dart:io 开启后优先广告延迟压缩，再回退 `none`；关闭时或 Web 平台只广告 `none`。不支持立即启用的 `zlib`。不提供自动重试。

## 远端验证入口

手机本机未运行测试、编译或分析器。由远端 CI 在包目录运行：

```sh
dart pub get
dart analyze
dart test --exclude-tags integration
```

浏览器回归单独运行（需要 Chrome）：

```sh
dart test --platform chrome test/src/ssh_compression_web_test.dart
```

OpenSSH 互通测试显式 opt-in（Linux，需安装 openssh-server / ssh-keygen，并预先创建 `/run/sshd`）：

```sh
SSH_COMPRESSION_TEST=1 dart test test/src/integration/openssh_compression_test.dart
```

该测试只创建临时 host/client 密钥及配置，使用运行测试的本机账号和随机 loopback 端口；分别启动 `Compression yes/no` 的一次性 sshd。覆盖启用、关闭、none 回退、GCM/ChaCha/CTR 与 EtM/普通 MAC、双向多包、服务端小 `RekeyLimit` 与客户端主动 rekey，最后关闭 sshd 并清理临时目录。不连接既有服务或使用个人认证资料。
