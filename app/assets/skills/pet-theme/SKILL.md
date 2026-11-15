---
# dsh-go:managed — delete this line to keep your own edits.
name: pet-theme
description: 把宠物素材做成 dsh-go 可导入的宠物包：clawd-on-desk 主题、GIF/PNG/WebP 表情包、逐帧目录、Aseprite 导出或单张图片。用于「把这个主题做成宠物」「把表情包做成宠物」「这个能导入吗」和 /pet-theme。
---

# 做一只宠物

把素材目录转成宠物包 zip，用户在「设置 → 宠物 → 导入」里选它。脚本在 scripts/ 下。

支持（按目录内容自动识别，一个目录只放一种）：

- clawd-on-desk 主题：theme.json + assets/
- 图片：GIF / APNG / WebP / PNG，一个文件一个动画；文件名自动认状态
  （idle、thinking、working、error、done、sleep、walk、poke、drag、tickle 等中英文）
- 逐帧目录：walk/01.png、hello_01.png，目录或前缀即动画名
- Aseprite 导出：JSON + 图集 PNG，按 frameTags 分动画
- 单张图片：做一只静态待机

没认出来的动画自动进待机小剧场，不会浪费。

## 步骤

1. 拿到素材目录（用户给链接就 git clone --depth 1，给 zip 就解压）。目录里没有
   theme.json 也没有图片就停下，说清楚支持什么。
2. 缺依赖才装：python3 -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple Pillow numpy
3. 转：

       python3 <scripts>/pet_theme_convert.py --input <目录> --out /tmp/pet-pack --id <id> --input-name <名字> [--source <链接>]

   像素画（小图、硬边）自动保持尺寸锐利绘制；其它素材自动用 144 画布平滑绘制。
   想强制锐利加 --crisp。
4. 校验，必须 PASS：

       python3 <scripts>/pet_pack_check.py /tmp/pet-pack/<id> --compat-reactions

5. 打包：

       cd /tmp/pet-pack/<id> && python3 -m zipfile -c <输出路径>/<id>.zip pack.json *.png

   手机输出到 /sdcard/Download/DSH-Go/。
6. 收尾：告诉用户导入路径，作者与授权显示在宠物页底部；只做自用转换，第三方素材
   （尤其 CC BY-NC-SA 同人作品）不要打包进发行版或市场。

## 边界

- 一个目录只识别一种素材，混放请分开。
- 整张精灵表请先拆帧或导出 Aseprite JSON。
- 状态靠文件名匹配；都没认出来时第一张当待机，其余进小剧场。
- 不手改生成的 pack.json，不跳过校验，不把用户素材上传。
