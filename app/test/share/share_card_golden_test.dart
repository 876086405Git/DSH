// Goldens of the share card itself at its export size (390 logical wide):
// a reply with code / table / maths in every template, a file,
// a plugin (also with its own landing link, too long for
// a QR code), cards with pictures (a prompt's attachments, a
// reply's own, too many for the grid, ones that cannot be had), a
// chat-style long image of several exchanges, and the accent colour.
// Shadows are drawn soft, as the export on a phone draws them.
//
//   flutter test --update-goldens test/share/share_card_golden_test.dart

import 'package:dsh_app/ui/share/qr_code.dart';
import 'package:dsh_app/ui/share/share_card.dart';
import 'package:dsh_app/ui/share/share_content.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart' show ImageAttachment;
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const _cardKey = shareCardKey;

void main() {
  for (final template in ShareTemplate.values) {
    softShadowTest('reply card (${template.name})', (tester) async {
      await pumpShareCard(tester, ShareCard(content: sampleReplyContent(), template: template));
      await expectLater(find.byKey(_cardKey), matchesGoldenFile('goldens/card_reply_${template.name}.png'));
    });
  }

  softShadowTest('file card with its first lines', (tester) async {
    await pumpShareCard(
      tester,
      const ShareCard(
        template: ShareTemplate.dark,
        content: ShareContent(
          title: '整理销售数据',
          blocks: [
            ShareFile(
              name: 'summarize.py',
              typeLabel: '文本 · PY · 2.1 KB',
              description: '按季度汇总销售额',
              excerpt: 'import csv\n\ndef quarter(month: int) -> int:\n    return (month - 1) // 3 + 1\n\nwith open("sales.csv") as f:\n    rows = list(csv.DictReader(f))',
              excerptLanguage: 'python',
            ),
          ],
        ),
      ),
    );
    await expectLater(find.byKey(_cardKey), matchesGoldenFile('goldens/card_file_dark.png'));
  });

  softShadowTest('plugin card', (tester) async {
    await pumpShareCard(
      tester,
      const ShareCard(
        content: ShareContent(blocks: [samplePlugin]),
        template: ShareTemplate.card,
      ),
    );
    await expectLater(find.byKey(_cardKey), matchesGoldenFile('goldens/card_plugin_card.png'));
  });

  for (final template in [ShareTemplate.light, ShareTemplate.card]) {
    softShadowTest('plugin card with its own landing link: too long to scan, no QR code (${template.name})', (
      tester,
    ) async {
      await pumpShareCard(
        tester,
        ShareCard(
          content: ShareContent(blocks: const [samplePlugin], link: samplePluginLink()),
          template: template,
        ),
      );
      expect(find.byType(QrCodeView), findsNothing);
      expect(find.text('手机上的 DSH'), findsOneWidget);
      await expectLater(find.byKey(_cardKey), matchesGoldenFile('goldens/card_plugin_link_${template.name}.png'));
    });
  }

  softShadowTest('pictures: the prompt\'s above its bubble, the reply\'s where they stand', (tester) async {
    final p = await photos(tester);
    final answer = [
      '这两张都是傍晚的逆光：天空过曝，前景偏暗。先看调整后的效果：',
      dataImage(p[2]),
      '曝光降了 0.7 档，阴影提亮 30%，色温往暖调了 300K。其余几种裁切也放在下面，挑一张喜欢的：',
      [dataImage(p[3]), dataImage(p[4]), dataImage(p[5])].join('\n'),
    ].join('\n\n');
    await pumpShareCard(
      tester,
      ShareCard(
        content: ShareContent(
          title: '傍晚照片调色',
          sessionId: 's1',
          blocks: [
            ShareQuestion(
              '这两张拍得有点灰，帮我调一下',
              images: [
                ShareAttachmentImage(
                  ImageAttachment(attachmentId: 'p0', mediaType: 'image/png', width: 1200, height: 900),
                ),
                ShareAttachmentImage(
                  ImageAttachment(attachmentId: 'p1', mediaType: 'image/png', width: 900, height: 1200),
                ),
              ],
            ),
            ShareAnswer(shareMarkdown(answer, images: true)),
          ],
          model: 'deepseek-v4-pro',
          stats: '1 分 08 秒 · 6 步',
          process: const [
            ShareProcessItem('查看文件', 2, tool: 'read_image'),
            ShareProcessItem('运行命令', 3, tool: 'bash'),
          ],
        ),
      ),
      overrides: [attachmentsFrom(p)],
    );
    await expectLater(find.byKey(_cardKey), matchesGoldenFile('goldens/card_images_light.png'));
  });

  softShadowTest('pictures: more than four leave 「+N」 on the fourth (dark)', (tester) async {
    final p = await photos(tester);
    await pumpShareCard(
      tester,
      ShareCard(
        template: ShareTemplate.dark,
        content: ShareContent(
          title: '旅行照片挑选',
          sessionId: 's1',
          blocks: [
            const ShareQuestion(
              '挑几张适合做封面的',
              images: [
                ShareAttachmentImage(
                  ImageAttachment(attachmentId: 'p3', mediaType: 'image/png', width: 1000, height: 1000),
                ),
              ],
            ),
            ShareAnswer(shareMarkdown('这几张构图最稳：\n\n${[for (final b in p) dataImage(b)].join('\n')}', images: true)),
          ],
          model: 'deepseek-v4-pro',
        ),
      ),
      overrides: [attachmentsFrom(p)],
    );
    expect(find.text('+2'), findsOneWidget);
    await expectLater(find.byKey(_cardKey), matchesGoldenFile('goldens/card_images_grid_dark.png'));
  });

  softShadowTest('pictures that cannot be had are quiet tiles, no words', (tester) async {
    final p = await photos(tester);
    await pumpShareCard(
      tester,
      ShareCard(
        template: ShareTemplate.paper,
        content: ShareContent(
          title: '远程主机上的截图',
          sessionId: 's1',
          blocks: [
            const ShareQuestion(
              '这个报错什么意思',
              images: [
                ShareAttachmentImage(
                  ImageAttachment(attachmentId: 'gone', mediaType: 'image/png', width: 1080, height: 2340),
                ),
              ],
            ),
            ShareAnswer(
              shareMarkdown(
                '截图里是权限错误：\n\n![](javascript:alert(1))\n\n两张都已过期：\n\n${dataImage(p[0])}\n![](data:image/png;base64,AAAA)',
                images: true,
              ),
            ),
          ],
        ),
      ),
      overrides: [attachmentsFrom(p)],
    );
    for (final word in ['无法显示', '找不到图片', '未连接 DSH', '轻点重试']) {
      expect(find.textContaining(word), findsNothing);
    }
    await expectLater(find.byKey(_cardKey), matchesGoldenFile('goldens/card_images_missing_paper.png'));
  });

  softShadowTest('several exchanges make a chat-style long image', (tester) async {
    final p = await photos(tester);
    await pumpShareCard(
      tester,
      ShareCard(
        content: ShareContent(
          title: '周末去杭州的安排',
          sessionId: 's1',
          blocks: [
            const ShareQuestion('周六一早出发，帮我排一下西湖一天的路线'),
            ShareAnswer(
              shareMarkdown(
                '按「北线 → 苏堤 → 南线」走，避开中午的人流：\n\n1. **07:30** 断桥看晨雾，沿白堤到孤山\n2. **10:00** 北山街喝咖啡，坐游船到三潭印月\n3. **13:30** 苏堤骑行，花港观鱼\n4. **17:00** 雷峰塔看日落',
                images: true,
              ),
            ),
            const ShareQuestion(
              '拍了一张断桥的，帮我看看构图',
              images: [
                ShareAttachmentImage(
                  ImageAttachment(attachmentId: 'p0', mediaType: 'image/png', width: 1200, height: 900),
                ),
              ],
            ),
            ShareAnswer(shareMarkdown('地平线压在三分线上，很稳。右侧的树枝可以裁掉一点，让桥成为唯一的主体：\n\n${dataImage(p[2])}', images: true)),
            const ShareQuestion('晚上住哪儿方便？'),
            const ShareAnswer('住**龙翔桥**附近：地铁一号线直达，步行到湖边十分钟，晚上吃饭的选择也多。'),
          ],
          model: 'deepseek-v4-pro',
          stats: '3 分 42 秒 · 17 步',
          process: const [
            ShareProcessItem('联网搜索', 6, tool: 'web_search'),
            ShareProcessItem('打开网页', 4, tool: 'web_fetch'),
            ShareProcessItem('运行命令', 1, tool: 'bash'),
          ],
        ),
      ),
      overrides: [attachmentsFrom(p)],
    );
    await expectLater(find.byKey(_cardKey), matchesGoldenFile('goldens/card_rounds_light.png'));
  });

  for (final (template, accent) in [(ShareTemplate.card, AppAccent.dusk), (ShareTemplate.glass, AppAccent.turquoise)]) {
    softShadowTest('follows the accent colour (${template.name}, ${accent.id})', (tester) async {
      await pumpShareCard(
        tester,
        ShareCard(content: sampleReplyContent(), template: template),
        accent: accent,
      );
      await expectLater(
        find.byKey(_cardKey),
        matchesGoldenFile('goldens/card_reply_${template.name}_${accent.id}.png'),
      );
    });
  }
}
