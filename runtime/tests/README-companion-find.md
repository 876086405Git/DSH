# 固定找稿的文件接点（H01）

本片只提供有界只读接点，必须随 H02 Host、H03 SDK、H04 App 一起作为完整找稿功能交付。它不宣称 H 已可从手机使用。基底为完整 G04；没有新依赖或任何原生目录改动。

`LocalFileSystem.dshGoListDrafts(directory,{startAtMs,endAtMs,extensions},signal)` 接实际已绑定的目录对象；日期半开窗、格式子集由具名 Host schema 验证。它保持原目录身份，使用已打开目录描述符下的 `/proc/self/fd` 锚点，`opendir({bufferSize:1})` 每次处理一项；最多检查200项，第201项只证明有更多项，不取其metadata。最多保留20个真实日期/格式匹配，发现第21个后只记超限，不把它交给正文读取。

目录、链接、不支持格式都占目录项数；链接不跟。只读metadata搜索，不叫模型、不读取全文；后续 H02 仅对最多20个已定版本复用完整<=64KiB的 `dshGoReadNote` 核可打开。公开报告不是目录总数猜测：matchingCandidates=21是下界；枚举结束也不承诺把遍历中新加入的文件全收齐。中途IO/metadata失败保留已核覆盖与缺口；目录在扫描后被同名替换仍保当时观察，后续打开拒绝新对象。

`bufferSize` 控制 Node 内部目录项缓冲，不能据此声称内核不会预读目录块。依据 [Node 官方 opendir 文档](https://nodejs.org/api/fs.html#fspromisesopendirpath-options)（2026-11-21查阅）。真实行为以同一测试进程中观测的 Dir.read/lstat 次数和已返回数据验证。

## 已跑范围

同22个H用例加原F24个文件回归，共同46项，在严格锁定的Android/OHOS **JS源码变体**分别于Linux实际运行，均46 PASS、0skip。它不是Android/OHOS原生执行、完整引擎、设备或真实用户目录的验证。实际Node IO、目录交换、同size/mtime对象替换使用临时合成文件。只读权限拒绝由实际非root子进程核真实EACCES；父进程为root时降至uid/gid65534，否则保持父进程非root身份。运行日志记录实际uid/gid，本次为1000/1000。中途stream EIO和metadata EACCES用例明确为受控故障。

原F写入回归的statfs支持类型注入沿原fixture保留；H没有发布写入，不把该注入当支持新文件系统。生产F在本机overlay仍拒发布。新H方法沿实际Linux锚定能力，其它平台不在可运行承诺内。

初次H测试7通过/8失败是close观察器把Node无callback Promise入口及其内部callback委托各算一次，并误用async包装；检查实际Dir.close后只观测外部无callback入口，移除多余async，产品未为此修改。原失败日志随证据保存。

## 本机模拟清单

在已按runtime锁准备的测试prefix下：

```sh
DSH_PREFIX=/absolute/prepared-prefix node --test \
  runtime/tests/companion-find-files-source.test.mjs \
  runtime/tests/companion-notes-files-source.test.mjs
```

源码fixture拒不匹配pin，不通过skip逃过缺source。现CI的 `runtime/tests/*.test.mjs` 已包含新文件，无需额外工作流步骤。真机、完整runtime和原任务/HTTP/H App组合由后续整组及owner实际环境验证。

| 场景 | 判据 |
| --- | --- |
| 本层/时区窗/格式 | A.md/B.txt真实原mtime，外层/子目录/链接/窗外文件不进候选 |
| 199/200/201项、19/20/21匹配 | 实际Dir.read最多一个哨兵；第201不stat、第21不成为正文候选 |
| 枚举中断、属性失败、原目录被换 | 留实际覆盖与缺口；不能说“就这些”或跟去新目录 |
| 同size/mtime替换A，B未动 | A拒旧版本，B仍按原对象读；不靠名字/大小/mtime认领 |
| 可列而不可读 | 真OS权限拒A，B可读；后续H报告保位置并标未能打开 |

## 界面需求与回退

H04需显示原目录、原当地日/时区、已检查范围、每个匹配原mtime，以及不能打开/未查全原因；不能把未核项说成“没有稿子”。点击来源要走原task/sourceRef，不能把本层路径交给普通文件API替换目标。布局视觉本机做，本片无手机入口。

H整组未进入验证前不单独合此底座。回退按H最终顺序逆序；本片无DDL或用户文件写入，不删除原任务记录。保留原F两个source变体的旧pin，不能用--whitespace=fix重写嵌套diff上下文。

## H01-r2注册顺序更正

原H01-r1源码IO39项各变体通过，但独审发现targetSets两数组把新diff列在末尾，违背TARGETS.md要求数组也按series顺序书写，因此r1按精确补丁BLOCKED。r2仅按既有series过滤重排两数组；所有diff、pin值、实际source body、测试源码及已有39项运行日志保持原字节。源码未变，不声称另跑一批测试。r2是相对G04的完整替代片，不能先r1再叠r2。

## H01-r3末次目录重核更正

r1/r2在完成实际扫描后的目录移除/换成普通文件时会抛出ENOENT/FS_NOT_DIRECTORY而丢弃已核结果；独审真实改名复现随证据保留。r3只对已有observed后的可识别目录身份/IO重核失败保留原metadata，并追加directory_changed或directory_unavailable。初始失败、abort和意外编程错误仍抛出；不重新打开替代目录、不重扫。增加7个直接覆盖这些边界的用例，原39项也随变更再跑。r3是相对G04的完整替代片，不在r1/r2上叠加。

## 新公共前缀适配（e638 实测 / a841 基底）

本次基底为 `a8417082cea25c50b12e7e59d56e018dd87661d2`。它沿用 e638 已由实际锁定源码重放的公共补丁顺序；已有 diff 原字节保留，找稿 diff 也未改。Android 完整公共链仍是 OHOS 的前缀，受新增找稿接点影响的两项 OHOS 文件 pin 保持实际源码重放所得值。

e638 当时的任务测试准备器仍把 DeepSeek 绑定到旧 `7bdd4173…072a`，实际新链会明确拒绝该绑定。原失败日志、按真实重放改为 `e38d5962…ac583` 后的准备器成功，以及两目标各46项 PASS、0skip 的源码 IO 记录均保留。ADDENDUM-17 的 owner 提交已经纳入同一份修正；当前基底该文件与当时已跑版本全字节一致，本片不再修改它，也没有新增 provider 行为或放松 pin 检查。

本后继的执行源码、pins 与测试字节仍逐项绑定到上述 e638 实际运行后态；只有本段说明更新。这里没有声称重新运行 Dart、Flutter、原生、完整引擎或 a841 CI。
