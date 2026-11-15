# Android / OHOS rc.1 补丁集合（E0 候选）

基于锁定 main 16cb44b7fd652d3545cfe6596a127a7968c18eb3 的 62 个公共补丁。Android按文件名顺序；OHOS先同一62公共链，再21专用层。schema2要求显式target、所有diff恰好登记；无默认目标。原main所有公共diff及rc.1 pin不改。

共享rtbuild只增加显式选择、完整chain预检和目标报告；build-runtime.sh传android。当前已验证npm前缀28296项与原main相同，完整Android归档门尚待执行，不能把前缀结论称整个APK/runtime一致。

rc.4旧集合不再可执行：其21专用diff已为rc.1适配，旧pin历史存在不代表该旧版可应用。鸿蒙分支37aa836e仍rc.4，本候选不修改该远端；其后续若升级必须整体跟随本版锁、集合和组成，不能只复制pins。

具体移植及未采纳配套见交付报告；当前为未冻结中间候选。
