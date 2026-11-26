# 鸿蒙发版打包

dsh-Go 的 Release 发布后，`ohos-release-dispatch.yml` 把发布事件对应的完整 commit SHA 交给私有构建仓。私有仓在 GitHub 托管机器上确认提交已进入 dsh-Go 的 `main`，再调用 `OHOS compile` 编译同一提交的 Dart AOT，最后在标有 `harmony` 和 `dsh-go-ohos-build` 的 Linux 自托管 runner 组装运行时和 HAP。

产物 `dsh-go-ohos-<sha>-unsigned-hap` 在私有仓的 Actions 运行记录中。它是 OpenHarmony 构建的旁加载验收包，使用 `check-arkts.sh --full --hms-stubs` 并通过其 HAP 审计。签名和真机安装在维护者的可信主机上完成。应用市场包需要原有的 HarmonyOS Command Line Tools 构建入口。

## 仓库设置

1. 把本目录的 `harmony-hap.yml` 放进 `ccch1mneyyy/dsh-go-ohos-build` 私有仓 `main` 的 `.github/workflows/harmony-hap.yml`。它调用 dsh-Go 公共仓 `main` 上的 AOT 工作流。
2. 创建仅限私有构建仓、仅授予 `Actions: Read and write` 的 fine-grained PAT。把它存到公共仓的 Actions secret `OHOS_BUILD_DISPATCH_TOKEN`。它只传给 GitHub 托管机器上的派单步骤。Runner 的注册令牌另行生成。
3. 用维护者账号为已进入 `main` 的提交发布 Release 会自动触发。若发布动作由仓库工作流的内置 `GITHUB_TOKEN` 完成，GitHub 不会转发 `release` 事件，可从 Actions 手动运行 `Queue HarmonyOS release build`，选择 `main` 或基于 `main` 的发版 tag。

## Linux runner

按私有仓 **Settings → Actions → Runners → New self-hosted runner** 的指引在 Linux 上注册，在 `config.sh` 的标签参数加上 `--labels harmony,dsh-go-ohos-build`。工作流准备 Python 3.12 和仓库锁定的 Node 版本。机器仍需安装 JDK、CMake、Ninja 及 OpenHarmony API 26 SDK。设置以下环境变量给 Runner 服务，修改后重启服务使它读取新配置。

| 变量 | 路径 |
| --- | --- |
| `OHOS_SDK` | 含 `ets`、`js`、`native`、`toolchains` 的 OpenHarmony API 26 SDK 目录 |
| `DSH_OHOS_NATIVE_LIBS` | 已备齐的 `arm64-v8a` 库目录（绝对路径）。基础库由 `runtime/ohos/native/build-hap-libs.py` 准备，另需下述 `libdsh_image_codec.so` 及 AOT 所需的原生资产，如 `libsqlite3.so` |
| `DSH_NODE_HEADERS` | 与该 `libnode.so` 匹配的 Node 源码 `src` 目录或 `include/node` |

原生库或其构建契约变化时，先按 [鸿蒙工程说明](../../../app/ohos/README.md) 更新主机上的相应输入。每次运行会从选定提交重新生成 Dart AOT 和 DSH 运行时。原生库与 AOT 的匹配、原生依赖和运行时文件由现有 HAP 审计检查。

### 图片编解码库（官方包必需）

私有 runner 从 `tooling/ohos/ci/package-hap.sh` 直接把 `DSH_OHOS_NATIVE_LIBS` 传给 `check-arkts.sh --full`。若目录里的 `libdsh_image_codec.so` 缺失、为空或不可读，官方脚本会在安装 npm 依赖前退出，不产出 HAP。供库后，沿用现有 HAP 审计核对包内库集和载入段字节；开发用的 `check-arkts.sh` 和 `build-hap.sh` 不改，图片库仍可选。

基础库脚本不构建图片库，当前 runner 入口也没有接入自动构建所需的完整配对输入。维护者须在可信主机按提交对应的 [SDK 26 图片库配方](../../../runtime/ohos/image/BUILD.zh.md)，使用 SDK 26.0.0.38 的完整 native 工具链和四个 arm64 Image 库、与打包输入一致的 Node 24.22.1 头文件及 `libnode.so`、对应的 `build.json`、clang++ 23.1.1 和配对静态 C++ 运行库，构建 Ninja 的 `dsh_image_codec` 目标。

仅在配方的 ELF 检查完成、产生 `image-build-complete.stamp` 后，才把产物按原名放到 `$DSH_OHOS_NATIVE_LIBS/libdsh_image_codec.so`。不要使用宿主测试夹具或失败构建留下的库；更新时在 runner 空闲时切换完整输入目录，不要在打包期间原地更新。缺任一配对输入或目标构建未通过，就保持阻断，不出缺库包。

## 首次验收

在私有仓手动运行 `Build unsigned dsh-Go HarmonyOS HAP`，填写 dsh-Go 最新主线的完整提交 SHA。确认 macOS 和 Linux 两个任务都成功，并下载对应 SHA 的 HAP。按 [设备文档](../../../docs/design/harmonyos/first-device.md) 签名、安装并启动。首跑成功后，再从公共仓手动触发派单流程核对自动链路，无需预先发新版本。
