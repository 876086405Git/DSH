---
# dsh-go:managed — delete this line to keep your own edits.
name: pet-theme
description: 把 clawd-on-desk 主题（Clawd on Desk 的 theme.json + APNG + SVG 格式）转成 dsh-go 可导入的宠物包，用于「把这个主题做成宠物」「把 clawd 主题转成宠物包」「这个主题能导入吗」「转成宠物包」和 /pet-theme。
---

# 把 clawd-on-desk 主题做成宠物包

输入是一个 clawd-on-desk 主题目录（theme.json + assets/），输出是一个能在
「设置 → 宠物 → 导入」里直接导入的 zip。转换脚本随本技能分发，在 scripts/ 下（相对本技能目录）：

    scripts/pet_theme_convert.py    主题 → 宠物包目录
    scripts/pet_pack_check.py       导入前校验（模拟 App 的两套解析器）
    scripts/pet_svg_frames.py       SVG / CSS 动画渲染器（被 convert 调用）
    scripts/make_pet_pack.py        包格式写图工具（被 convert 调用）

本机引擎在跑时脚本目录是 $DSH_HOME/skills/pet-theme/scripts/；找不到就用
find "$HOME" -path '*skills/pet-theme/scripts/pet_theme_convert.py' 定位。

## 步骤

1. 拿到主题目录。
   - 用户给 GitHub 链接：git clone --depth 1 <url> /tmp/pet-theme/<name>。下载慢时告诉用户
     也可以下载仓库 zip 再给路径。
   - 用户给 zip：解压到 /tmp/pet-theme/<name>。
   - 目录里必须有 theme.json 和 assets/。没有就停下：本技能只支持 clawd-on-desk 主题格式；
     普通宠物包（pack.json + PNG）直接导入，不需要转换。
2. 装依赖（缺才装）：python3 -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple Pillow numpy。
   已有就跳过，不要重复装。
3. 定名字和来源：
   - --input-name：宠物页显示的名字；用户没指定就用 theme.json 的 name
   - --source：主题来源 URL，照实填
   - --id：文件夹名，小写字母 / 数字 / 连字符；默认取主题目录名
4. 转换：

       python3 <scripts>/pet_theme_convert.py --theme /tmp/pet-theme/<name> --out /tmp/pet-pack --id <id> --input-name <名字> --source <URL>

   日志里出现 "not exported (dsh-Go keeps one animation per tier)" 是已知损失，照实说。
5. 校验（必须 PASS 才能继续）：

       python3 <scripts>/pet_pack_check.py /tmp/pet-pack/<id>

   目标 App 可能是旧版（不认识编号反应）时再加 --compat-reactions。
   失败就按报错修输入或参数，不要绕过、不要手改 pack.json。
6. 打包：

       cd /tmp/pet-pack/<id> && python3 -m zipfile -c <输出路径>/<id>.zip pack.json *.png

   手机上输出到 /sdcard/Download/DSH-Go/；别的环境放到用户能找到的位置并给出完整路径。
7. 收尾说明：
   - 「设置 → 宠物 → 导入」选这个 zip；同 id 再导入会覆盖。
   - 作者与授权显示在宠物页底部。
   - 下面的已知限制挑相关的说 1–3 条，不要倒一大段。

## 已知限制（必要时要告诉用户）

- 主题每档多个动画（workingTiers / jugglingTiers 的 files 变体）只保留主文件，dsh-Go 每档一段动画。
- dizzy / yawning / dozing / collapsing / mini 模式这些 clawd-on-desk 有的状态，dsh-Go 没有挂载点，不转换。
- SVG 动画（待机 / 走路 / 被拎起）按本技能里的 CSS 参数渲染；主题改过 CSS 可能对不上。
- 输出画布 144、pixelArt:false：素材带亚像素动画，像素画的整数放大在手机上会一卡一跳，
  所以走平滑渲染；边缘不会像纯像素画那么硬。
- 只做自用转换：Clawd 主题美术通常是 CC BY-NC-SA 4.0 同人作品，别把主题或转好的包
  打包进发行版 / 市场，除非确认许可。

## 不要做

- 不改主题素材、不手改生成的 pack.json。
- 不跳过 pet_pack_check。
- 不把用户主题上传或外发。
- 不声称渲染效果已经在真机上验证过；用户导入后自己看效果。
