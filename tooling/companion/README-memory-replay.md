# 伙伴记忆离线回放：真实产品入口、独立测试和未运行项

本工具把 09e-r2/r2.1 的 15 组验收映射到现有及新增的真实产品测试。手机侧实际调用 store、parser、worker、selector、Page 和原主动 owner；完整模式侧使用锁定的真实 engine、Session、AgentLoop 和 adapter。仅合成时钟、供应商 HTTP/SSE、系统呈现等外部边界。没有另一份记忆规则、选择器或业务状态机。

## 四类输入与运行

在仓库根目录运行：

```sh
python3 tooling/companion/replay-memory.py \
  --mode offline \
  --cases tooling/companion/memory-replay-cases.json \
  --model-fixtures tooling/companion/memory-model-fixtures.json \
  --output /tmp/companion-memory-replay
```

`cases` 指定 1–15 组、保留的原 07 编号、完整测试名及未接好的观察。`model-fixtures` 是这些**编译进产品测试的合成提案/API夹具**的版本化源文件清单，包含共享 phone golden。启动前按每份真实源文件 SHA256 核对，缺失、重复或不匹配就不启动测试并记 NOT_RUN。回放记录清单哈希和实际校验的源哈希。

这是固定 15 组的编译夹具接口；它不能把任意录制 JSON 注入任何测试，也不是原 52 段的通用步骤 DSL。固定提案通过只证明生产代码如何接收、拒绝、提交和使用该提案，不证明真实模型能够生成它。用到的初始手工卡是夹具明确的输入，不拿期望结果直接填进被测数据库。

新测试经过维护者的 `dart format` / `dart fix` 后，源字节会改变。应先检查实际差异，再明确重建清单：

```sh
python3 tooling/companion/prepare-memory-fixtures.py
```

该准备命令只读清单所列真实文件并写新哈希，输出 PREPARED_NOT_RUN，不运行测试、不产生 PASS。回传时请同时带源差异与新清单。CI 的回放命令不会自行重签不匹配的源；不能把该准备命令放在回放内部来隐藏内容变化。

## 两个 Dart 入口与真实引擎

SDK 入口是 `packages/dsh_client/tool/companion_memory_replay_test.dart`，App 入口是 `app/tool/companion_memory_replay_test.dart`。每个被导入的测试 `main()` 放在原 `test/..._test.dart` 路径的 group 下，以完整名称匹配结果。入口放在 `tool/`，避免普通 `test/` 发现把同一模块重复执行。

App 显式调用已有 `test/flutter_test_config.dart::testExecutable`，加载正常测试字体与默认值，并复用 `test/support/bundle_widgets.dart` 的偏好、资产和 widget 重置。缺字体会真实失败，不用无声替代字体冒充通过。

真实 engine 用既有 `DSH_PREFIX` 加载完整锁定运行时。没有该前缀时，Node 测试的 skip 明确映射为 NOT_RUN，即使 Node 退出码为 0。供应商 fetch 返回合成 SSE；执行的仍是真实主循环、压缩/Session 重放、实例替换、物理 retry 和工具续轮。新增进程重启夹具是两个 OS 子进程及真实 snapshot/seed 恢复，不声称等同整台 WebHost 的自动磁盘启动。

CI 复用同次 runtime job 的真实 JUnit 结果，避免另跑一份换了运行时的假替代：

```sh
python3 tooling/companion/replay-memory.py \
  --engine-report /tmp/runtime-evidence/companion-engine.xml \
  --output /tmp/companion-memory-replay
```

传入该参数只复用 engine XML，SDK 与 App 仍在本次执行。XML 的来源由调用方明确提供；本工具核完整测试名、failure/error/skip，不把一个相同文件名自动当正确 build 的证明。仓库 CI 从同 workflow、同 checkout 的 runtime artifact 取它。

若仅重算已经产生的结果，可以给 `--reports <原结果目录>`。原目录必须含 `run-inputs.json`、`sdk.jsonl`、`app.jsonl`、`engine.xml`；输入记录中的 cases/catalog 哈希须匹配，保留原 run_id 和实际子命令退出码。输入记录在真正执行结束后才标 execution_complete；未完整执行、缺原退出码或清单不同不得用旧绿报表证明当前源。summary 标明 collection_only；重算不产生一次新的产品执行，也不能把原来的非零退出码改成成功。

## 输出怎样读

- `results.jsonl` 固定 15 行，case_id 为 r2-01 至 r2-15，保留 original_ids。每项列实际完整测试名、文件、证据层和限制；未接好的 required_gaps 保持 NOT_RUN。
- `summary.json` 分开列 case_counts、check_reference_counts 和 unique_test_counts。前者是 15 组；检查引用可跨组重复；独立测试按 suite + 完整名去重，**不是断言数或真实模型调用数**。required_gap_counts 另列。
- `run-inputs.json` 绑定本次清单；原始 Dart JSONL、engine XML 和命令日志与结果一起保留。Dart 错误可晚于 testDone，读取全流后再判断，晚失败不能被先前 success 覆盖。
- cases 本身缺失或无效也会写本次 15 项 NOT_RUN 与预检原因，先清掉旧 summary/results；不会因早期异常留下旧的 PASS 摘要。原始输入已无效时不猜测原编号映射，original_ids 留空。
- 同组优先级为 FAIL → NOT_RUN → NEEDS_REVIEW → PASS → NOT_APPLICABLE。缺失、重复名称、隐藏加载测试、skip、未完整结束均不能算执行通过。已证明失败即使后续流截断仍保留 FAIL。
- `execution_status` 聚合该次已列检查、原子命令退出码以及报告整体失败/完成状态；即使命名检查全绿，子命令非零仍是 FAIL。`acceptance_status` 还保留 unresolved_requirements。一般 targetless 同事项的 BLOCKED_SCOPE，以及尚待单独修复的确定产品缺陷，不因有限离线断言通过而关闭，也不改记“不适用”。
- exit 1 表示已列断言失败或启动的测试命令非零；exit 2 表示未运行、未完成或缺证；exit 0 只说明已列有限离线执行完成，不代表真实模型、设备、所有产品语义或未解决要求通过。CI 用这个有界执行门槛，完整验收仍看 summary 和独立复核。

`usage.requests` 指真实供应商模型调用，经过要求的 offline guard 才记 0；同组若引用 engine，其全部指定合成 peer 观察也必须实际通过。Dart guard 不能替未运行的引擎担保，没有足够证据就留 null。它不是合成 HTTP 交换次数。真实模型输出、真人反馈和费用均未测，保持 null / 单列 NOT_RUN；不拿金标台词冒充自然回答，也不把虚拟推进 24 小时当真实运行延迟。

## 被选 Dart HTTP 路径的出网边界

`offline_http.dart` 使用实际 `HttpClient.connectionFactory`，在开始 socket 前只允许数字地址 `127.0.0.1` 与 `::1`；DNS 名、localhost、外部 IP 都拒绝。`findProxy` 初始固定 DIRECT，即使 caller 后来改代理，只要 factory 收到任何代理参数仍拒绝。外部重定向也会走这个检查。允许的本地 socket 使用 InternetAddress，不作 DNS 查询。MockClient 直接在内存返回，不创建这个 socket。

widget bundle 会重置 `HttpOverrides.global`，因此 App 在它的 setUpAll 之后、每个测试之前及注册 widget binding 后都恢复同一个 guard。选择的测试文件不另设覆盖、不改 connectionFactory、不自行起外部 socket。带独立 HttpOverrides 的旧 signal_room 测试不混入本入口；其模块仍由常规完整测试单独跑。

SDK 必须运行并通过：

- `offline rejects external HTTP before DNS`
- `offline allows numeric loopback HTTP`
- `offline rejects external HTTP redirects`

App 还必须通过 `offline reinstalls guard after widget binding` 和 `offline permits MockClient responses`。代理、重定向、真实 loopback 服务器与 widget binding 都走实际 API，不是搜字符串。

这不是 OS 级网络沙箱，不覆盖任意 native socket、子进程、新 isolate 或未来加入的其它覆盖。完整引擎另外由受控 fetch fixture 限定真实模型 peer；本说明不把两者合称整个操作系统零网络。`DshConnection` 遇到自定义 HttpOverrides 会停用可选 background-read 快路；所选 companion 的生产 postJson/流路径仍运行，不声称测到了全部默认 HTTP 优化。

## 依赖准备与未运行门槛

SDK、依赖和字体由维护者现有环境准备。启动前每个 Dart 包必须同时已有 `.dart_tool/package_config.json` 和 `package_graph.json`；缺任一个就不启动该套，不自行 pub get 或安装 SDK。App 命令另用 `--no-pub`。

Dart 3.13.5 的 TestCommand 在测试入口之前调用 NativeAssetsBuilder.ensurePackageConfig，缺上述配置会先触发依赖解析，所以测试内 HttpOverrides 管不到这个阶段。编译、旧依赖解析、build hooks 与 native 资产下载也不在 guard 范围内；CI 准备步骤与费用为零的产品夹具运行分别说明。

本实现环境没有 Dart / Flutter / Android SDK；相应 guard、产品测试和设备结果均 NOT_RUN。Python 单测只验证报告器不会把 skip、晚失败、缺源或重复计数伪成产品通过。Node --check 或无DSH_PREFIX的加载结果也不替代完整 engine 运行。

## API 与源码依据

以下是本次使用并已核的官方入口。源码结论不替代目标版本实际运行。

- [Dart 3.13.5 HttpClient.connectionFactory](https://api.dart.dev/stable/3.13.5/dart-io/HttpClient/connectionFactory.html)
- [Dart 3.13.5 Socket.startConnect](https://api.dart.dev/stable/3.13.5/dart-io/Socket/startConnect.html)
- [Dart 3.13.5 InternetAddress.tryParse](https://api.dart.dev/stable/3.13.5/dart-io/InternetAddress/tryParse.html)
- [Dart 3.13.5 HttpOverrides.createHttpClient](https://api.dart.dev/stable/3.13.5/dart-io/HttpOverrides/createHttpClient.html)
- [Dart SDK 3.13.5 test.dart](https://raw.githubusercontent.com/dart-lang/sdk/3.13.5/pkg/dartdev/lib/src/commands/test.dart)，只读源 SHA256 `306ba029d60768e0df5073c021aec9eb197846d60dda2020e0f1559f2d5625b8`。
- [Dart SDK 3.13.5 native_assets.dart](https://raw.githubusercontent.com/dart-lang/sdk/3.13.5/pkg/dartdev/lib/src/native_assets.dart)，只读源 SHA256 `807cc0eaa54045d9a8ec82e98880b4e9847881718aaf02a2a801c3a0401b32a3`。
