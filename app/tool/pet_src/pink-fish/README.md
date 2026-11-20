# 小粉鱼

内置宠物 `pink-fish` 的来源。作者与授权见仓库根目录的 `ASSETS.md`。

- `reference.png`：原图（1219×1290，透明底，胸口以上），作者用 AI 生成。所有动画都以它为母版：等比缩放 32/43 放进 1024×1024 画布，偏移 (58.42, 41)，下沿切口在 y=1000。
- 动画帧由 GPT 生图在母版上逐帧绘制：只重画会动的部分（眼睛、手、道具），其余区域与母版逐像素一致。帧源文件体积大，不进仓库。目录按交付批次分层，同一段以序号最大的那次为准（后一次可以只改 `timing.json`，缺的帧从更早的批次找）：

```
<帧目录>/
  011/B1-idle/timing.json, frames/idle_00.png …
  030/C4-think-in/…
  …
```

  `B<n>` 是状态和反应的循环或一次性动作，`C<n>` 是进场片段（首帧等于待机首帧，末帧等于对应循环的首帧），`timing.json` 写逐帧毫秒。
- `build.py`：把帧缩到 320 px（scale 2，画布 160），每段动画共用一个 256 色调色板，写出 `app/assets/pets/pink-fish/`。

```
cd app
python3 -I tool/pet_src/pink-fish/build.py <帧目录> assets/pets
```

段名与宠物状态的对应写在 `build.py` 的 `SEGMENTS`、`STATES`、`REACTIONS` 里。
