# 图片容器规则来源与采纳边界

前波资料记录的读取日期：2026-11-09。本波沿用这份规则来源记录；本波行为证据以新运行的宿主测试为准。下列为格式制定者／原作者公开资料；代码是本任务自行实现，不复制外部解码器或参考实现，不增加第三方依赖。网页／PDF由只读检索取得，其链接与节号是规则出处，不冒充已保存到本地并有逐字节SHA的规范副本。

| 主源 | 本任务实际采纳的规则 |
|---|---|
| W3C PNG Third Edition（2025-06-24），https://www.w3.org/TR/png-3/ | §5/§7 块长度、命名、字节序和CRC；§11.2 IHDR/PLTE/IDAT/IEND；§11.3 tRNS、色彩块与eXIf。扫描所有块到IEND；IHDR决定编码精度，索引色RGB色表为8位。cICP存在时不把sRGB当有效颜色结论；不inflate文本/profile。 |
| ITU-T T.81（1992）原PDF，W3C托管：https://www.w3.org/Graphics/JPEG/itu-t81.pdf | 本轮新取得可检索的186页原PDF，核读Annex B.1、B.2及表B.1/B.2/B.3：marker、长度、SOF、SOS、DQT、DHT、DRI、APP/COM及熵段转义/restart。R3当时未取得T.81的历史文字不回写；这次未宣称读完全部压缩／解码章节。只采纳非分层Huffman SOF0/1/2，最多4组件；其他过程返回UNSUPPORTED。 |
| Eric Hamilton / C-Cube，JFIF 1.02（1992-09-01），https://www.w3.org/Graphics/JPEG/jfif3.pdf | APP0完整字段、首位要求、版本、density、缩略图长度及无缩略图形式。JFIF说明的一/三组件没有alpha；未知APP扩展仍使alpha未知。JFIF不是已验证的SRGB转换，因此JPEG的space不由本扫描器填SRGB。 |
| Google WebP Container Specification，https://developers.google.com/speed/webp/docs/riff_container | RIFF精确总长、偶数padding、VP8X/ICCP/ANIM/ANMF/ALPH/VP8/VP8L/EXIF/XMP顺序与数量；canvas尺寸积限制、帧矩形。遍历所有块，未知块保留unknown。无ICC的SRGB仅作为容器约定，不代表实际颜色转换。 |
| Google WebP Lossless Bitstream Specification，https://developers.google.com/speed/webp/docs/webp_lossless_bitstream_specification | §3固定头、14位尺寸、版本及8位样本。alpha_is_used明确只是提示，位0或1都不能由此证明实际alpha；本实现将VP8L的alpha保持unknown，不展开熵编码。 |
| RFC 6386（2011），https://www.rfc-editor.org/rfc/rfc6386.html | §9.1 VP8未压缩关键帧头、版本、show_frame、签名、尺寸和first-partition长度（不含未压缩头）。拒绝缩放版本这一当前不支持的子集；不复制该文参考解码代码。 |
| CompuServe GIF89a（1990-07-31），https://www.w3.org/Graphics/GIF/spec-gif89a.txt | §§15–27 的子块、header、LSD、色表、图像描述符、GCE作用域、扩展、trailer。逐块计图像，不解LZW；GIF及其服务标记归CompuServe所有。应用扩展为opaque，Plain Text不冒充图像帧。 |
| CIPA DC-X008-Translation-2019-E（公开2019草案），https://www.cipa.jp/std/documents/e/DC-X008-Translation-2019-E.pdf | §4.6.2 IFD表结构、§4.6.5.A Orientation：tag274、SHORT、count1、1–8、缺省1。仅读classic TIFF IFD0，不追子IFD/缩略图/像素指针。此处明确是草案原作者文本，不将它冒充2026正式版。CIPA当前页面可读，但当前正式下载正文未取得；不据此扩展标签支持。 |
| Adobe Photoshop File Formats（2019-11），https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/ | Photoshop-specific TIFF Tags表把700列为XMP。IFD0出现该opaque包时不推断全局方向缺省，即使另有Orientation也保持unknown。 |

## 本实现主动收窄的部分

JPEG完成结构遍历需要SOI、支持的SOF、至少一SOS及最终EOI，无多余尾部；输出子集进一步只收8位三组件baseline单次interleaved scan、无metadata／未知扩展。它核编码表边界，但不执行Huffman、DCT、颜色或像素解码；即使output_subset为1，仍可能被真正解码器拒绝。其他JPEG过程是UNSUPPORTED，不是测得损坏。

PNG对每个块核CRC，对采用的基础字段核语义；APNG控制块被辨认后不填写帧数，不宣称APNG时序或组合经过验证。其他已知但未解释的metadata块只说明存在，不从内容推导颜色。未知critical块不支持，未知ancillary保持metadata／方向未知。

WebP输出仅结构白名单：单图，VP8/VP8L及必要VP8X/ALPH；ICCP/EXIF/XMP、动画、未知块或尾部不允许作为clean output。VP8L的output_subset可为1而alpha仍unknown，这是两个不同谓词；后续桥必须读取known位并据R3完成实际解码，不能拿subset位代替字段闭合。

GIF的alpha是受GCE控制的图像中存在透明声明的汇总，不是已合成首帧或实际像素。Plain Text／未知扩展可能改变graphic作用域时不填alpha及frames。应用块未解释，因此不声称所有GIF应用扩展都可处理；无scope疑问时frames仅为图像描述符数量。

## 输出和未知的统一语义

metadata=true表示观察到本策略计入的profile/Exif/XMP/文本/comment/缩略图等，未声称解析完整内容。必要图像结构（色表、透明度数据、无缩略图JFIF）不算retained metadata。metadata=false只有完整已支持的路径无这些块且无未知扩展时才填写；存在一个已知metadata块时，可以确认true，即使还有未解释内容。

orientation的known=1来自无方向容器的完整遍历或有界IFD0证明；冲突、多Exif、不合结构、opaque XMP/未知扩展保持unknown。读取IFD0只证明该表的方向，其他metadata或像素内容不因此通过。源码不会据空值/失败补false或1。

本扫描器未接任何NDK、Node-API、颜色manager或attachment调用；R3系统getter、完整解码与输出验证仍在后续组件。追加28的颜色getter编译期方案不影响这个无SDK组件，也不在这里宣称其所有权已获证明。
