# SPreset 固定原始文件与 oracle 复现

ADDENDUM-10 纠正整文件字节身份；产品代码与既有向量的行为期望不变。
固定仓库为 `starowo/starowo.github.io`，commit 为 `53bd585da14248ba10baaede7fc7ed0cebe1eeeb`，路径为 `regex_bind/inject.js`。

| 身份 | 原始 Git 文件 | 先前本地研究副本 |
| --- | --- | --- |
| 字节数 | 290243 | 290244 |
| SHA256 | `4858bcb57530e3ff6ef68f0c94a4d291e2914c766c274f888e9a2fdf8d0efb59` | `d0766c830f3bfd4a69c63bba60423d7a797276fbd4695420adb8f17ea330037b` |
| 计算出的 Git blob SHA1 | `efb49a4c8e7a713ada65116f8959183f7d1dd7a5` | `cf2169b37638b964d59910439a951f3a3c496be3` |

完整字节比较确认：旧 `research/spreset/site_inject.js` 恰等于原始文件再追加一个 LF (`0a`)；首 290243 字节完全相同。两者均无 BOM、CR 或 CRLF。
不是固定提交漂移，也不是本次 connector 文本转换：contents API 的 base64 解码、自算 Git blob 及完整文本路线均一致。
旧保存命令没有留存，不能从这一个额外 LF 推断具体写入代码。旧源码、日志、评审与已冻结 ZIP 保留原字节；其中 `d0766…` 只代表当时本地副本。
历史材料若同时列出仓库 blob `efb49…` 和本地 SHA `d0766…`，它们是两种不同字节身份，不能据此声称旧副本已通过该 Git blob 的字节校验；本次按原始字节重新计算纠正。

## 取源与字节校验

按以下固定 raw URL 保存响应内容，或从同 commit 的 GitHub contents API 解码 base64；不要 `trim`、补换行或转换行尾。

```sh
curl --fail --location --output inject.js 'https://raw.githubusercontent.com/starowo/starowo.github.io/53bd585da14248ba10baaede7fc7ed0cebe1eeeb/regex_bind/inject.js'
python3 - <<'PY'
import hashlib
from pathlib import Path
data = Path('inject.js').read_bytes()
assert len(data) == 290243
assert hashlib.sha256(data).hexdigest() == '4858bcb57530e3ff6ef68f0c94a4d291e2914c766c274f888e9a2fdf8d0efb59'
assert hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest() == 'efb49a4c8e7a713ada65116f8959183f7d1dd7a5'
print('Fixed SPreset original bytes verified')
PY
```

## 从 `packages/dsh_tavern` 运行

把下列 `inject.js`、`tool-calling.js`、`openai.js` 换成已校验文件的路径，输出写入独立临时目录。
formatter 另需固定 [ST 7e8663 的 tool-calling.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/scripts/tool-calling.js)（SHA256 `934be74f6bd672a821e5f3e5dc34ad4548c1cac60ee41c48feaa630e6e2f7712`）及同提交 [openai.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/scripts/openai.js)（SHA256 `0b77c30282825540265d5a09e681e5ccacf6760b05111ec880ffe237a9250604`）。

```sh
node tool/st_differential/spreset-conditional-tag-oracle.cjs inject.js > /tmp/spreset-conditional.json
node tool/st_differential/spreset-message-injection-oracle.cjs inject.js /tmp/spreset-message-injection.json
node tool/st_differential/spreset-formatter-metadata-oracle.cjs inject.js tool-calling.js openai.js /tmp/spreset-formatter.json
node tool/st_differential/spreset-squash-boundary-oracle.mjs inject.js /tmp/spreset-squash.json
cmp /tmp/spreset-conditional.json test/fixtures/w11_spreset_conditional_source.json
cmp /tmp/spreset-message-injection.json test/fixtures/spreset/message-injection-aliases.json
cmp /tmp/spreset-formatter.json test/fixtures/spreset/formatter-metadata.json
cmp /tmp/spreset-squash.json test/fixtures/spreset/squash-boundaries.json
```

前三个执行器原本把旧副本 SHA 当作 raw 文件 SHA，故均会拒绝正确下载；现在都校验原始字节。第四个是先前独立 squash probe 的 CLI 复现入口，提取边界、54 个向量与观察替身保持原样，仅显式提供输入、输出与整文件校验。
条件标签 5 项、消息注入 14 项、formatter 9 非流式与 5 流式、squash 20 返回值/10 数组/24 stop 向量均已从原始文件重跑。
条件标签、消息注入、squash 三份 fixture 只更新源 SHA；所有行为字段不变，formatter fixture 完整字节不变。执行的原函数块也逐项比对相同。
这些是固定函数与明确边界替身的 Node 证据，不是完整网站、用户预设或 WebView 验收；没有执行整个外部 runtime。

现有 `spreset_page_runtime_test.cjs`、`spreset_tool_registry_test.cjs`、`spreset_tool_receiver_test.cjs` 的可选原源差分没有旧 whole-file SHA 门禁，传入原始文件仍通过。它们不自行核仓库身份，输入仍须先完成上述字节校验。
`spreset-tool-capability-oracle.cjs` 只读固定 ST 文件，不读 SPreset 原件，不受 ADDENDUM-10 的 SPreset 尾 LF 差异影响。
ADDENDUM-14 #11 随后确认 ST openai.js 的旧副本也多一个尾 LF；上述 formatter 与 capability 的 ST guard 现按原始字节更正。详见 [ST-SOURCE-PIN.md](ST-SOURCE-PIN.md)，旧 ADDENDUM-10 运行记录不回写。
