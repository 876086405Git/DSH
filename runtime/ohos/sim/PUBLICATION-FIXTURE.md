# M3-1：完整回合的 Linux linked 测试库输入

O0 驱动器为引擎构造干净环境，只继承明确列出的字段。首次从外层设置 `LD_PRELOAD` 后运行完整回合，库没有进入子引擎，正式 publication preload 明确报 `ERR_OHOS_PUBLICATION_BINDING_MISSING`，启动 BLOCKED、0 次审批。该负对照保留；不能把驱动器环境过滤误写为原生接口失效。

新选项 `--linked-publication-fixture /绝对路径/libpublication-test-linked.so` 只接受 Linux 测量宿主，校验真实普通 `.so` 路径，拒绝 LD_PRELOAD 的空白和冒号分隔符。它仅在 `--mode sim` 中将这个明确选择的库写进引擎的 `LD_PRELOAD`，记录规范路径、磁盘 SHA256 与测试范围，不会传递父进程的整个环境或任意原有 LD_PRELOAD。JIT/jitless 对照仍验证输入但不加载该库，因此现有 `measure.sh` 可以将同一选项传给三种模式。JS 动态 addon 白名单保持独立。

这用于复现自己的 Node 启动前 linked 注册；目标产品通过 C++ runner 的 `RegisterPublicationBinding()` 注册，不使用 LD_PRELOAD。记录的 SHA 是启动前磁盘文件哈希，不是内存镜像证明或抵抗并发替换的安全边界。CLI 输入应为本次已生成、保持不变的研究产物。

```sh
node runtime/ohos/sim/round.mjs --prefix /独立OH目标prefix --out /新建测量目录 \
  --mode sim --platform \
  --linked-publication-fixture /绝对路径/libpublication-test-linked.so \
  --import runtime/ohos/net/dsh-preload.mjs \
  --import runtime/ohos/publication/preload.mjs \
  --sim-patch /研究profile.patch.yml \
  --allow-addon /独立prefix/实际已核验的native-loader.node
```

没有改写原 O0b 的 HTTP/WS、会话、工具成功、审批或 turn-end 断言。输入负对照在创建测量目录、启动模型或引擎之前拒绝；真实成功路径以同剧本完整回合证据为准。此扩展本身不提供生产持久登记或跨 App 自动恢复。
