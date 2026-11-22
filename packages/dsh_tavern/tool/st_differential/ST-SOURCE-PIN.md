# ST 原始字节与 oracle 复现（ADDENDUM-14 #11）

固定仓库 `SillyTavern/SillyTavern`，commit `7e8663cd9c184a550b37238218bdd32c6efc68e9`。
原始 Git 文件应从该 commit 的 raw URL 保存响应 bytes，或解码 contents API 的 base64；不要 trim、补 LF、加 BOM 或转换行尾。
本次根代理取回七份原件，独立组件逐份重算 SHA256 与 `sha1(b"blob " + size + b"\0" + bytes)`，均匹配固定 Git blob。

| 路径 | 原始 bytes | 原始 SHA256 | Git blob SHA1 |
| --- | ---: | --- | --- |
| public/scripts/openai.js | 307267 | `0b77c30282825540265d5a09e681e5ccacf6760b05111ec880ffe237a9250604` | `bab82eec57e0927b809b0571534e96f1b13360e1` |
| public/scripts/PromptManager.js | 90717 | `b0054793b763d92b265f5f487645b68b4eca0867cb5ad6b5deb1034004b2c1cc` | `20219dc45ffa232ef61ebbfac0836241f168a55a` |
| public/scripts/reasoning.js | 68726 | `c489812f2598d1a4879b1a7287abde092741adafdf67f5b15cf18f2dd71d82d1` | `c82e95fc1abc4d8547254886c758c8b926cf4453` |
| public/scripts/extensions/regex/engine.js | 16189 | `091bb3402a12552cf1754d6e4d2b44df38d3553aa374539896c716e78905d350` | `2b6bdc235816542c6348a558665804388f71e73b` |
| public/script.js | 497669 | `955c603d0bad84bac5a716f0818d85c2543e44d4c43878e0d63ef1e55ca91855` | `777a2d5983a6283ef9b26726e75192da1e3f3cea` |
| public/scripts/utils.js | 113042 | `2a2cfe240d5a84ce2e09ba053db6c0c71473b6406173f614f3521d89f50ada61` | `6d57bb7b1700c06d160df049dea87dd56cbc9f28` |
| public/scripts/tool-calling.js | 48987 | `934be74f6bd672a821e5f3e5dc34ad4548c1cac60ee41c48feaa630e6e2f7712` | `41a3b78ce12926d27dbfb77ca3d74b65bef2a60f` |

前三份及 regex 旧研究副本恰好等于 raw 再追加一个 LF；所有原前缀字节相同，无 BOM/CRLF 转换。后三份原样相同。
旧 SHA 分别为 `09a580a06b351991cecef1577306ae6b4326a3972edd3dceb66dc89c29eacc4a`、`9cb20c2c52fb1e311c5ba95786da42fff459f52db0c02d36901599ea37b624c1`、`0eea2fa307bc67953acce95df5283371ef1af7a248415f084aa79a9efcbe3b2c`、`ffa62c2d165dff82398b4c7d97a0e5c2083b5696522cff7244370bea93a283fb`。
它们仍能描述旧本地副本，但不应作为该 commit 的原始文件 SHA；不是上游提交漂移。没有留存的旧保存命令，不能据此指定是哪次写入加了 LF。
旧 source、研究结果、评审和已发布 ZIP 均保留，不回写成已通过原始字节校验。

## 六个产品 oracle

修正 tool-reasoning、helper-raw-array-admission、helper-history-array-coercion、helper-history-image-failure、spreset-formatter-metadata、spreset-tool-capability 的整文件 guard；不改提取函数、执行逻辑或断言。
相应四份生成 fixture 只变 full-file SHA；formatter 与 history-image-failure 两份输出逐字不变。
`w11_helper_image_paths.json` 的 sourcePins 和 Helper 来源清单同时更正；其 12 路径与 14 gate 期望不变。
六类共 198 控制、另有 history-array media-off 两例：旧 guard + 旧副本通过，旧 guard + raw 拒绝，新 guard + raw 通过，新 guard + 旧副本拒绝。
逐输出除 SHA 元信息完全相同；捕获的 314 次 VM 求值文本也逐字相同。
这些是实际固定函数加各 oracle 明示替身的控制，不是全 ST、浏览器、App 或真实 provider 验收。

下面从 `packages/dsh_tavern` 运行，输出到自选空目录；ST_FILES 指原始 `public/scripts` 目录，OUT 为输出目录。
EVIDENCE_ROOT 的 research/helper 放固定 Helper `29331c36fb9b2e880d4d488ff919317e1bc95684` 原件；research/st/public/scripts 放上述 raw；PromptManager.js 另按既有路径别名放 research/st/PromptManager.js。
SPRESET_JS 指 [SPRESET-SOURCE-PIN.md](SPRESET-SOURCE-PIN.md) 已校验的原始 inject.js；旧研究目录可保留，使用独立证据根镜像。

```sh
node tool/st_differential/tool-reasoning-oracle.cjs "$ST_FILES/openai.js" "$ST_FILES/PromptManager.js" "$ST_FILES/reasoning.js" > "$OUT/tool-reasoning.json"
node tool/st_differential/helper-raw-array-admission-oracle.cjs "$EVIDENCE_ROOT" > "$OUT/raw-array.json"
node tool/st_differential/helper-history-array-coercion-oracle.cjs "$EVIDENCE_ROOT" > "$OUT/history-array.json"
node tool/st_differential/helper-history-array-coercion-oracle.cjs "$EVIDENCE_ROOT" --media-off-control > "$OUT/history-media-off.json"
node tool/st_differential/helper-history-image-failure-oracle.cjs "$ST_FILES/openai.js" "$EVIDENCE_ROOT/research/helper/src/function/generate/utils.ts" > "$OUT/history-image-failure.json"
node tool/st_differential/spreset-formatter-metadata-oracle.cjs "$SPRESET_JS" "$ST_FILES/tool-calling.js" "$ST_FILES/openai.js" "$OUT/formatter.json"
node tool/st_differential/spreset-tool-capability-oracle.cjs "$ST_FILES/tool-calling.js" "$ST_FILES/openai.js" test/fixtures/spreset/tool-capability.json "$OUT/tool-capability.json"
```

## 已发布 R2 / R3 来源更正附记

R2 `producer-r2-probe.cjs` 的 44 控制、R3 `nonstream-source-probe.cjs` 的 19 控制在新独立镜像仅改 source SHA，再以同一 vectors 原字节重放，均 exit 0；观察结果逐项相同。
不能泛称所有抽取块 hash 不变：两探针的 `/^}\s*$/` 吃入 regex 文件结尾空白，最后 filterString 块从旧 `} + LF + LF` 变成 raw `} + LF`。
该块末尾减少 1 byte / 1 line；旧 block SHA `946cf21490b878b272436238d63613c39e92884ac2fb2b7e94eae06070776131` → raw `c7b3f50dce0a0cb97865a83bb373217fac9075591bd4556b1e716a17b4442b30`；函数正文逐字相同。
其余 R2 41 / R3 65 个记录块相同；记录块载入数不等于完整分支覆盖。所有 44 / 19 行为、输入、时序观察和边界声明保持原值。
首次重放的“只变全文件 SHA”比较器因此如实失败，原 Node 44 控制已成功；修正比较资格后复用该次输出，没有伪造第二次测量或抹掉失败。
历史图片窄探针的 12 路径 / 14 gate 也用同样 raw 校正重放通过，除整文件 SHA 外输出逐字相同。
其中历史 raw array→history 探针以 identity substituteParams 为边界；不能用它为当前 fixture 最后一条的 String coercion 期望背书。该条保持现有值，并由本次 26+2 个实际 substituteParams oracle 控制继续支持；前 11 路径和 14 gate 均与对应历史观察一致。
本附记只纠正来源字节身份；旧 R2/R3 冻结件与原签不回写，未据此新增 Dart 实现或产品采用结论。
