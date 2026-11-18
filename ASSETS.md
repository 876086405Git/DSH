# 品牌与吉祥物素材

DSH Go 的源码以 AGPL-3.0 发布（见 [LICENSE](LICENSE)），但下面这些品牌和美术素材**不在 AGPL-3.0 授权范围内**。它们的版权归 ccch1mneyyy（DSH-TUI）所有，保留所有权利。

你可以为了构建、测试和运行本仓库而使用它们。如果你以修改版或衍生作品的身份再发布，请换成自己的名称和素材。

| 素材 | 位置 | 来源 |
|---|---|---|
| DSH Go 品牌标识（鱼尾与气泡） | `app/assets/brand/`；由它生成的 `app/lib/ui/shell/brand_glyph.g.dart`、启动图标 `app/android/app/src/main/res/mipmap-*/`、`drawable/ic_launcher_*`，鸿蒙的 `app/ohos/AppScope/resources/base/media/`、`app/ohos/entry/src/main/resources/base/media/`（`tooling/ohos/make-launcher-icons.py`） | DSH Go 自己的品牌图形 |
| Deepy 小鲸鱼（像素鲸鱼桌宠） | 源文件 `app/tool/pet_src/deepy-whale/`；宠物包 `app/assets/pets/deepy-whale/` | DSH-TUI 的吉祥物。源文件按 [Clawd on Desk](https://github.com/rullerzhou-afk/clawd-on-desk) 的主题包格式制作，只沿用了它的格式 |
| 鲸娘（像素鲸鱼娘表情） | 源文件 `app/tool/pet_src/whale-girl/`（`index.html` 是 https://dshtui.com/pets/whale-girl-emoji/ 原页面，里面有事件对应关系和逐帧时长）；宠物包 `app/assets/pets/whale-girl/`；求 Star 弹窗的贴纸 `app/assets/star/star_whale.webp` | DSH-TUI 的吉祥物，最初发布在 dshtui.com |

鲸鱼尾巴图形（`app/assets/whale/`，源文件 `app/tool/whale_src/`）：其中一个是 DeepSeek 的官方图标，版权和商标归 DeepSeek 所有，仅用于表明本应用连接的是 DeepSeek 服务；其余几张是基于它的二创。它们同样不在 AGPL-3.0 授权范围内。如果权利人提出要求，我们会替换。

这些鲸鱼形象是 DSH-TUI 自己的非官方形象，和 DeepSeek 没有关系，也不代表 DeepSeek。

go.dshtui.com 首页（`site/home/`）由社区开发者 ClayGao233 / 采云师烧饼制作，网页本身的来源和使用条件见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。其中的 `dist/assets/dsh-go.svg`（`app/assets/brand/tile.svg` 的副本）、`dist/assets/dsh-go-pop.svg`（由品牌图形改出的立体版）、`dist/assets/author/share.png`（`docs/assets/social-preview.png` 的副本）和功能展示图里的品牌图形、鲸娘形象同样适用本页的条件。

仓库首页 README 用到的展示素材 `docs/assets/`（首图、社交预览图、桌宠动图、社群二维码）同样适用本页的条件：可以随本仓库一起查看和转载介绍，不要用在你自己发布的产品上。

宠物包由 `app/tool/make_pet_pack.py` 从 `app/tool/pet_src/` 生成，品牌图形的代码由 `app/tool/make_brand_mark.py` 从 `app/assets/brand/` 生成。工具脚本本身和其他源码一样，以 AGPL-3.0 发布。

伙伴小屋的 Live2D 素材不在这个仓库和 APK 里：Cubism Core（Live2D 专有许可）、Cubism Web Framework（Live2D Open Software License）和角色模型都打成单独的素材包，用时才放进手机，见 [docs/design/companion.md](docs/design/companion.md)。模型的作者和授权写在素材包的 `character.json` 里，App 菜单底部原样显示。

第三方的代码、字体、图标和运行时组件见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 端上语音模型

语音通话的判停模型放在 `app/android/app/src/main/assets/speech/`，随 APK 打包，按各自的许可证使用，不受上面的品牌素材限制。
要重新下载并校验，运行 `python3 app/tool/fetch_speech_models.py`。

| 文件 / 版本 | 固定来源 | SHA256 | 许可 |
|---|---|---|---|
| `silero_vad.onnx` / Silero VAD v6.2 | [snakers4/silero-vad, be95df9](https://raw.githubusercontent.com/snakers4/silero-vad/be95df9152c0d7618fa1edfeb296fc3dae32376f/src/silero_vad/data/silero_vad.onnx) | `1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3` | MIT；同目录 `silero-LICENSE.txt` |
| `smart-turn-v3.2-cpu.onnx` / smart-turn v3.2 int8 | [pipecat-ai/smart-turn-v3, f766f81](https://huggingface.co/pipecat-ai/smart-turn-v3/resolve/f766f81d3cfdf7737ac64aad813d91bbfd56bf93/smart-turn-v3.2-cpu.onnx) | `2bb026316b14a660486a75b1733cd3fbab8c2fd0314dc9af7be49f8cca967e4f` | BSD-2-Clause；同目录 `smart-turn-LICENSE.txt` |

前端按 [smart-turn 的官方推理示例](https://github.com/pipecat-ai/smart-turn/blob/main/inference.py)
使用 Whisper 8 秒特征，含补齐后的波形标准化 `do_normalize=True`。
Android / JVM 的 ONNX Runtime 均固定 1.27.0（MIT）。
