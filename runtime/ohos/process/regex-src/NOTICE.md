# re2js 私有构建归属

来源：re2js 1.3.3，Copyright (c) 2023 Alexey Vasiliev，MIT License。构建从该固定 npm 包的原始 sourcemap 恢复源码；不修改 npm 安装本身。

OHOS rg 修改：Unicode 16 shorthand/word 分类；UTF-8 continuation 位置的零宽上下文与有效标量判断。修改由相邻最小 source diff 和 UnicodeGroups.js 表达；它们只进入 OHOS rg 私有构建，不替换其他消费者的模块。

构建器从原包 LICENSE 逐字读取完整 MIT 文本，并把它和修改说明保留在生成物头部。产物仅在 build/ 生成，不作为源码提交。具体源、工具和输出 SHA256 见 ../M4-1.md 及构建 proof。
