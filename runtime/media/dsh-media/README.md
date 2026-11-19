# @ccch1mneyyy/dsh-media

DSH Go 的主机侧媒体插件，版本 `0.3.0`。提供生成图片、用一句话编辑图片、后台生成视频；服务密钥留在 Host credentials，原件保存到当前工作区。设置命名空间保持 `dsh-media`，媒体结果使用冻结的 `meta["dsh-go/media"]` v1。

0.3.0 声明兼容 DSH `0.2.1-rc.4` 与 `0.2.2-rc.1`，验证使用各版已有 runtime 锁，不重新解析生产依赖。实际验证范围与未验证项见 `VERIFICATION.md`。模型可用性、审核、配额和最终费用由供应商决定。App 内置的是设置与媒体展示入口，主机插件仍单独安装；本次不发布 npm、不预装或自动启用插件，也不调用真实付费服务。

## 支持范围

| 服务 / profile | 图片与编辑 | 视频 | 取消 |
|---|---|---|---|
| OpenAI / `openai-gpt-image` | GPT Image 2、2.5 Sunburst / Flare；单参考图编辑 | 无 | 同步请求停止等待不等于供应商停止计费 |
| Gemini OpenAI 兼容 / `openai-compatible` | Gemini 2.5 Flash Image，单张、显式 `b64_json` | 无 | 同上 |
| 火山方舟 / `ark-image`、`ark-video` | Seedream 5.0 Pro；单参考图编辑 | Seedance 2.5 文生 / 单首帧图生 | 仅 queued，真实 DELETE 后再查询确认 |
| 阿里云百炼 / `ali-wan-image`、`ali-video` | Wan 2.7 Image；单参考图编辑 | Wan 2.7 文生 / 单首帧图生 | 仅 PENDING，真实取消请求后再查询确认 |
| 硅基流动 / `silicon-image`、`silicon-video` | Qwen Image；Qwen Image Edit 2509 单参考图编辑 | Wan 2.2 T2V / I2V | 当前官方接口未提供取消；停止本地等待可能继续收费 |

确切模型 ID、地址、参数白名单与官方资料在 `data/models.json`。本版本只开放有文档依据的子集，不代表供应商完整能力。Seedream Lite 已停止新购，因此使用官方列出的 Pro 替代型号；不会发送 Pro 不支持的 Lite 组图字段。[方舟下线公告](https://docs.volcengine.com/docs/ark/model-deprecation-notice?lang=en)

没有启用且凭据已配置的服务时，不注册生成工具或系统提示。`edit_image` 只在配置了支持编辑的模型时出现。原生服务只接受目录中核实的 HTTPS 主机和路径；OpenAI 兼容服务可配置 HTTPS API 根路径，仍执行公网地址与下载安全校验。

## 配置

三步即可开始：

1. **添加服务**：从服务商预设中选择图片或视频（火山方舟、阿里云百炼、硅基流动、OpenAI、Gemini）。服务 ID、请求协议、API 根地址、返回格式和模型 ID 会按预设自动带入，无需手动拼写。图片与视频分别建一个服务；同一服务商的图片和视频可以共用同一个凭据。
2. **填 API Key**：新版 App 会为每个服务自动生成凭据名（例如方舟图片和视频都用 `DSH_MEDIA_ARK_API_KEY`，同一服务商复用同一个），只需要在服务详情里保存一次 Key；也可以在「高级」里改成任意已配置的 env 风格凭据名来引用已有 Key。旧版四个固定槽 `DSH_MEDIA_SLOT_1_API_KEY` 至 `DSH_MEDIA_SLOT_4_API_KEY` 仍可用，但仅为兼容保留，新版设置不需要在这里重复填写。
3. **启用**：分别选择图片默认服务和模型、视频默认服务和模型，检查费用保护后启用。`generate_image` / `edit_image` 使用图片默认值，`generate_video` 使用视频默认值；类型默认值解析不到时回落旧版通用 `defaults.serviceId` / `defaults.modelId`，再回落首个可用候选。

预设来自 `data/models.json` 的 `presets[]`，App 通过服务的目录元数据读取；旧版 App 忽略该字段，现有配置与旧版通用默认值保持原行为。

例如方舟图片与视频服务（只有引用，不含 Key）：

```yaml
services:
  - id: ark_image
    enabled: true
    provider: ark
    baseUrl: https://ark.cn-beijing.volces.com
    profile: ark-image
    models: doubao-seedream-5-0-pro-260628
    keyRef: DSH_MEDIA_ARK_API_KEY
  - id: ark_video
    enabled: true
    provider: ark
    baseUrl: https://ark.cn-beijing.volces.com
    profile: ark-video
    models: doubao-seedance-2-5-260628
    keyRef: DSH_MEDIA_ARK_API_KEY
defaults:
  imageServiceId: ark_image
  imageModelId: doubao-seedream-5-0-pro-260628
  videoServiceId: ark_video
  videoModelId: doubao-seedance-2-5-260628
budget:
  dailyCny: '20'
  unknownPriceHoldCny: '20'
limits:
  maxImages: 1
```

百炼两个 profile 的根地址都是 `https://dashscope.aliyuncs.com`，也支持目录声明的北京工作空间地址。硅基流动为 `https://api.siliconflow.cn`；OpenAI 为 `https://api.openai.com/v1`。Gemini 兼容根地址为 `https://generativelanguage.googleapis.com/v1beta/openai`，`responseFormat: b64_json`。其他 profile 的 `responseFormat` 留空；预设已包含上述值。

## 使用与恢复

普通对话可要求“画一张蓝色的猫”“用这张参考图把背景改成夜晚”“生成一个 5 秒视频”。生成模式沿用普通用户消息参数头，不新增命令或自定义会话事件。视频可用参数依模型决定；硅基流动当前只开放尺寸映射，不猜测秒数或分辨率字段。首帧图生视频省略 `aspect`。

`generate_image` / `edit_image` 完成后返回实际文件和 v1 元数据。`generate_video` 立即返回 `rid` 和后台 job：真实 `ctx.jobs` 跟踪排队、运行、终态，完成通知叫醒 Agent，再调用 `get_media_result(job_id)` 获取最终媒体卡片。插件不调用 `jobs.wait`，不自行伪造会话事件。v1 没有独立 cancelled 状态，确认取消使用 `status: failed` 和 `error.code: cancelled`；未确认远端取消使用 `remote_may_continue`。

Host 重启后，原会话可调用 `resume_media(rid)` 继续查询已保存的供应商 task ID。恢复不新建供应商任务，不再次预留费用；仅接受原 session、工作区、服务端点、凭据引用和模型身份。已完成的本地索引可直接复用。此版本是**显式恢复**，尚不自动重建全部 jobs；POST 已受理但响应丢失、没有 task ID 时不能自动找回，也绝不重试创建。

图片原件写入 `<cwd>/generated/<UTC 日期>/`，视频为原始 MP4（上限 300 MiB）。视频宽高、时长、编码从文件头读取，不冒充完整解码验证。支持目录校验的 MP4 编码不等于每台 Android 都能硬解。Host 私有索引与预算账本位于 `<DSH_HOME>/media/dsh-media/`，包含 prompt 与任务恢复身份，不应纳入公开诊断包。

参考图限当前可写工作区内的普通 PNG / JPEG / WebP 文件，最多一张、10 MiB。拒绝符号链接、命名管道和工作区外路径。每次审批列出实际路径与目标服务；内容在审批前读取并固定，审批后文件身份改变则拒绝提交，不上传替换后的文件。

## 费用保护的实际含义

当前没有足够可靠、覆盖所有输入计费项的报价，因此**每次图片、编辑、视频均须单次明确同意**，卡片不显示虚构估价。默认每天本地预算 ¥20、每次未知价请求预留 ¥20；默认设置一天只容纳一次此类预留。日期按上海时区。

预留是本地记账护栏，**不是供应商实际金额的硬上限**。实际账单可能高于预留。调低未知价预留会放行更多请求，不会降低供应商价格。账本在提交前持久化不确定状态，接受后的失败、超时、取消或断网均保留预留；本插件不声称退款。明确尚未提交的请求才释放预留。账本的内部 `basis: estimate` 记录本地预留结算，不是经过核实的供应商报价。

媒体插件启动时，在注册工具前释放账本中全部尚未进入 `begin` 的 `reserved`，让进程中断后的用户能在同一上海日重新审批生成；`submission_unknown`、`submitted`、`settled` 保持原样。此恢复采用 Android 同一个 `DSH_HOME` 只有一个 Host 的部署合同。非常规地让两个 Host 共用同一个 `DSH_HOME` 时，后启动的一方也会释放另一方尚未 `begin` 的预留；一次清理最多重新放行一份当日日额的本地预留容量，实际供应商费用仍不受该金额封顶。普通配置或凭据刷新不会执行此清理。详见[启动恢复合同](../../../docs/maintenance/media-reserved-startup-contract.md)。

方舟和百炼仅排队时可能取消。取消请求与状态变化可能竞争，只有后续查询明确 cancelled / CANCELED 才显示已取消；运行中、查询失败、供应商不支持时都提示服务端可能继续生成并收费。付费 POST 不自动重试。

## English

`@ccch1mneyyy/dsh-media` is a Host-side DeepSeek Harness plugin. It keeps credentials on the Host, saves original media in the current workspace and emits DSH Go media metadata v1. The settings namespace remains `dsh-media`. Node `^22.19.0 || >=24.0.0` and DSH `0.2.1-rc.4` or `0.2.2-rc.1` peers are required; the DSH Go manifest declares app `1.0.2` or later.

It supports OpenAI / Gemini-compatible images, Ark Seedream / Seedance, Alibaba Wan and SiliconFlow Qwen / Wan. Editing uses one workspace image. Video generation runs as a real background job; `get_media_result` retrieves its media result after the completion notice. `resume_media(rid)` explicitly resumes a saved provider task in its original session without submitting again. Provider cancellation is confirmed only when the API reports it; SiliconFlow cancellation is unavailable.

All currently bundled prices are unknown. Every generation requires explicit one-time approval. The default CNY 20 daily ledger and CNY 20 per-request hold limit local reservations, **not actual provider bills**. Accepted or uncertain submissions retain their hold. Validation uses each supported runtime version’s existing pinned dependency graph; see `VERIFICATION.md` for current evidence. No paid-provider or Android App installation/media-viewer validation is claimed. The package is prepared for publication but this change does not publish or preinstall it.

Before registering tools at startup, the plugin releases every `reserved` entry that has not entered `begin`, allowing a new approved request on the same Shanghai budget day after process loss. It preserves `submission_unknown`, `submitted` and `settled`. This uses the Android deployment contract of one Host per `DSH_HOME`. If two Hosts share a home, the later startup also releases the other Host's pre-begin holds; one cleanup can reopen at most one daily limit of local reservation capacity, without capping actual provider charges. Configuration and credential refreshes do not perform this cleanup. See the [startup recovery contract](../../../docs/maintenance/media-reserved-startup-contract.md).

Version 0.3.0 also publishes provider presets in the plugin catalogue. The App builds a service from a preset, writes any env-style credential name such as `DSH_MEDIA_ARK_API_KEY`, reuses one key for the image and video services of the same provider, and keeps separate image/video defaults. The four fixed slots remain for compatibility only, and a legacy `serviceId`/`modelId` default keeps its exact previous behavior.
