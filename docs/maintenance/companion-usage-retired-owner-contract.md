# 伙伴普通聊天的用量回执与已释放会话

完整模式的用量账本用实际 Session 对象核对手机请求归属。同一字符串会话 ID 可属于重建的对象。活动会话沿用原对象。当 bridge 收到 Agent 释放事件，或上下文被新 Agent 替换时，旧回执只保留能匹配原对象的弱身份引用。已退休组不再接收新模型调用；同对象重试、迟到的错误与已打开的调用继续按原归属处理。

普通归档保留活动的 Session。实际释放后，用量回执仍可按 Host 实例、会话 ID 和请求 ID 读取，直到原有根数量、回执数量或字节预算触发淘汰。对已删除会话，保留回执本身无需保持整个事件日志可达。

运行 `node --test runtime/tests/companion-usage-retired-owner.test.mjs` 联验身份、回执和强制 GC。`runtime/tests/companion-chat-usage.test.mjs` 另覆盖迟到物理回执和容量处理。
