# OHOS 进程输出的增量 UTF-8 边界

## 问题

固定 DSH `0.2.1-rc.4` 的 `OutputCollector` 保存原始 Buffer，终态从头读取能拼回跨 chunk 的字符；但活跃期每次 `readFrom(fromByte)` 都直接解码当前尾片，并将 `nextOffset` 推到总字节数。

例如“中”的 UTF-8 字节分两次到达：`e4 b8`，然后 `ad`。若两次到达之间有增量读取，原行为依次返回 `�`（offset2）和 `�`（offset3），都标 `lossy=false`；同一收集器终态从0读取却仍为“中”。后台 jobs 的原150ms泵确实沿用这个offset，并在结束时再读一次；增加一个末尾flush不能修复已经前移的cursor。

这个模块与未补丁的锁定 npm 前缀同字节，属于上游既有边界。OH 后端实际将 Buffer 保真交给收集器，且在 Worker 退出、两条读流结束之后才seal，本补丁不改变这些线程或流的退出屏障。

## 修复契约

`runtime/patches/ohos-output-utf8.diff` 只在明确的 `--target ohos` 集合中应用，钉死原文件SHA，不修改Android集合。

- 无损、仍活跃的读取只暂缓末端有希望由后续字节补齐的合法UTF-8前缀，最多3字节。已经完整的文本立即返回。
- `nextOffset` 停在暂缓字节之前。因此同一读者继续使用返回offset就能在后续拼回字符；两个独立读者仍分别持有自己的整流字节offset，没有共享解码消费状态。
- `seal()` 对没有spill的普通收集也记录终态。输入确实以残片结束时，按原 `Buffer.toString('utf8')` 的替换规则交付，随后从返回offset读取为空。
- 已不可能构成合法UTF-8的字节不等待未来数据，保持原替换行为。`finalize()` 的最终文本、原始snapshot、容量计量和spill内容保持原义。
- 已经丢失头部的lossy窗口保留原裁剪和标记语义；本补丁不声称能从缺失字节中恢复完整字符。

活跃期返回的 `nextOffset` 可以比已收到的总字节数少1–3。它是下一次读取的位置，不是进度统计。原有 `snapshot().totalBytes` 继续表示完整观测字节数。

## 验证方式

`runtime/tests/ohos/output-utf8.test.mjs` 包含所选2/3/4字节字符的所有内部切点、独立读者、合法边界字符、非法UTF-8、真正终态残片、lossy尾窗和普通真实spill文件等10项小测试。测试输入明确指向独立补丁前缀的模块，并核SHA；下面两个变量只由测试文件读取，不是生产环境开关：

```sh
DSH_OUTPUT_COLLECTOR_TEST_MODULE=/absolute/patched-prefix/node_modules/@deepseek-ai/dsh-subprocess-local/lib/output.js \
DSH_OUTPUT_COLLECTOR_TEST_SHA256=3be3d0fe5376087a57af7f881cf889bc6cedc2f821f5e6b08324d82414cb8445 \
node --test --test-isolation=none --test-reporter=tap runtime/tests/ohos/output-utf8.test.mjs
```

目标隔离由真实patcher另测。它只复制注册补丁会读取的锁定npm文件，保留共享前缀只读，检查Android输入指纹及对应文件字节不变、OH首次应用和幂等、Android到OH续打、错误目标拒绝且不写入：

```sh
python3 -I -B runtime/tests/ohos/output-utf8-patches.py \
  --base-repo /absolute/verified-base \
  --candidate-repo /absolute/this-source \
  --pristine-prefix /absolute/locked-pristine-prefix \
  --out /absolute/new-private-report-directory
```

这些是Linux固定Node和源文件补丁验证，不代表手机、完整Android/APK/HAP或全部DSH回合。交付中的原失败日志、单Worker泵观察、精确源码身份和独立复核结果分别保留，不用后继通过覆盖前像。

## 相关原回归范围

本次还保留 accepted52+57 的以下三个原测试文件，完整执行其原断言和原单项超时：`process.test.mjs` 的24项（收集、尾窗、spill、大于读流高水位的双流收束等），`process-streaming.test.mjs` 的12项（分段输出、取消和退出排空），以及 `process-cancel-before-start.test.mjs` 的4项（启动前取消、空收集器seal和后继请求）。JIT和严格模拟模式各40项；没有以10项新增反例测试替代这些完整原文件。

运行时使用独立私有模块替换：真实 `VirtualSubprocessRuntime` 所构造 stdout/stderr 收集器的构造器确认为补丁后的唯一 `OutputCollector`。Worker、运行时、私有Bash产物和三个上游消费者保持锁定原字节。该验证树并非重新组成的60号runtime归档；本包没有重写其runtimeVersion，也没有宣称新完整DSH/HAP/设备验收。
