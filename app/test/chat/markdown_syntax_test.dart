// Source preparation for the reply renderer: maths delimiters (with the
// currency guard) and the streaming-tail repair.

import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_model.dart';
import 'package:dsh_app/ui/chat/render/markdown_prepare.dart';
import 'package:dsh_app/ui/chat/render/math_syntax.dart';
import 'package:dsh_app/ui/chat/render/stream_repair.dart';
import 'package:dsh_app/ui/chat/render/table_syntax.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeMath', () {
    test('inline dollars become \\( \\)', () {
      expect(normalizeMath(r'质能方程 $E = mc^2$ 写在一行里'), r'质能方程 \(E = mc^2\) 写在一行里');
      expect(normalizeMath(r'分式 $\frac{a+b}{c}$ 也是'), r'分式 \(\frac{a+b}{c}\) 也是');
      expect(normalizeMath(r'$\alpha\beta\gamma \to \infty$'), r'\(\alpha\beta\gamma \to \infty\)');
      expect(normalizeMath(r'there are $3$ cases'), r'there are \(3\) cases');
    });

    test('display dollars become \\[ \\], across lines', () {
      const source = '二阶矩阵的逆：\n\n\$\$\n\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}^{-1}\n\$\$\n\n完';
      expect(normalizeMath(source), '二阶矩阵的逆：\n\n\\[\n\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}^{-1}\n\\]\n\n完');
      expect(normalizeMath(r'$$x^2$$'), r'\[x^2\]');
    });

    test('prices stay prose', () {
      for (final prose in [
        r'午饭 $5 and $10 两档',
        r'from $5-$10 a month',
        r'$5M to $10M',
        r'我有$5，他有$10，',
        r'between $5 and 10$ per seat',
        r'5$ 和 10$',
        r'pay $ 5 now',
        r'US$1,000 vs HK$2,000',
        r'just one $ sign',
      ]) {
        expect(normalizeMath(prose), prose, reason: prose);
      }
    });

    test('a price and a formula on one line', () {
      expect(normalizeMath(r'$5 and $10, but $x^2$ is maths'), r'$5 and $10, but \(x^2\) is maths');
    });

    test('a scan with no delimiter changes reuses its input', () {
      final source = '${'正文 ' * 100}${r'cost $5 and $10; run `echo $HOME $PATH`'}';
      expect(normalizeMath(source, streaming: true), same(source));
    });

    test('escaped dollars are literal', () {
      expect(normalizeMath(r'cost \$5 and \$10'), r'cost \$5 and \$10');
      expect(normalizeMath(r'$\$5 + x$'), r'\(\$5 + x\)');
    });

    test('code stays literal', () {
      expect(normalizeMath(r'run `echo $HOME $PATH` now'), r'run `echo $HOME $PATH` now');
      expect(normalizeMath(r'`$x$` and $y$'), r'`$x$` and \(y\)');
      const fence = '```bash\necho \$a \$b\nexport X=\$\$\n```\n\nthen \$z\$';
      expect(normalizeMath(fence), '```bash\necho \$a \$b\nexport X=\$\$\n```\n\nthen \\(z\\)');
      const quoted = '> ```\n> \$x\$\n> ```';
      expect(normalizeMath(quoted), quoted);
    });

    test('an unclosed double dollar is left alone when finished', () {
      expect(normalizeMath(r'costs $$ more'), r'costs $$ more');
    });

    test('a display formula still streaming becomes a pending block', () {
      const source = '矩阵：\n\n\$\$\n\\begin{pmatrix} a & b';
      expect(normalizeMath(source, streaming: true), '矩阵：\n\n```$pendingMathLanguage\n\\begin{pmatrix} a & b');
      // Opened mid-line, with text on the opener's line.
      expect(normalizeMath(r'于是 $$x = \frac{1}{', streaming: true), '于是 \n```$pendingMathLanguage\nx = \\frac{1}{');
      // Inside a quote the fence keeps the quote marker.
      expect(normalizeMath('> \$\$\n> a + b', streaming: true), '> ```$pendingMathLanguage\n> a + b');
      // `\[` too.
      expect(normalizeMath('\\[\n\\int_0^1', streaming: true), '```$pendingMathLanguage\n\\int_0^1');
      // A closed one is drawn.
      expect(normalizeMath('\$\$\nx\n\$\$', streaming: true), '\\[\nx\n\\]');
      // A bare `$$` waits for its body.
      expect(normalizeMath(r'于是 $$', streaming: true), r'于是 $$');
    });

    test('the closer search is not fooled by inline code later on', () {
      expect(inlineDollarCloser(r'$a `b$`', 0), -1);
      expect(inlineDollarCloser(r'$a$', 0), 2);
    });
  });

  group('repairStreamingMarkdown', () {
    test('closes emphasis that is still open', () {
      expect(repairStreamingMarkdown('这是 **重点'), '这是 **重点**');
      expect(repairStreamingMarkdown('这是 *斜体'), '这是 *斜体*');
      expect(repairStreamingMarkdown('~~删掉'), '~~删掉~~');
      expect(repairStreamingMarkdown('**粗 *斜'), '**粗 *斜***');
      expect(repairStreamingMarkdown('**已闭合** 和 **未'), '**已闭合** 和 **未**');
    });

    test('holds back a marker with nothing after it', () {
      expect(repairStreamingMarkdown('这是 **'), '这是');
      expect(repairStreamingMarkdown('**粗体** 然后 *'), '**粗体** 然后');
      expect(repairStreamingMarkdown('**a *'), '**a**');
    });

    test('leaves snake_case, multiplication and list markers alone', () {
      expect(repairStreamingMarkdown('call my_func_name now'), 'call my_func_name now');
      expect(repairStreamingMarkdown('2 * 3 = 6'), '2 * 3 = 6');
      expect(repairStreamingMarkdown('- 第一项\n- 第二'), '- 第一项\n- 第二');
    });

    test('closes an open code span, holds an empty one', () {
      expect(repairStreamingMarkdown('运行 `npm ins'), '运行 `npm ins`');
      expect(repairStreamingMarkdown('运行 `'), '运行');
      expect(repairStreamingMarkdown('`a` and `b'), '`a` and `b`');
      // Emphasis markers inside code are not emphasis.
      expect(repairStreamingMarkdown('`a **b'), '`a **b`');
    });

    test('links render while their destination arrives; images wait', () {
      expect(repairStreamingMarkdown('见[文档](https://exa'), '见[文档](#)');
      expect(repairStreamingMarkdown('图：![示意图](chart.p'), '图：');
      expect(repairStreamingMarkdown('图：![示意'), '图：');
      expect(repairStreamingMarkdown('[1] 引用'), '[1] 引用');
    });

    test('a table waits for its delimiter row', () {
      expect(repairStreamingMarkdown('前文\n\n| 模型 | 价格 |'), '前文');
      expect(repairStreamingMarkdown('前文\n\n| 模型 | 价格 |\n|---|'), '前文');
      expect(repairStreamingMarkdown('说明：\n| 模型 | 价格 |\n'), '说明：');
      const ready = '| 模型 | 价格 |\n|---|---|\n| V4 | 4'; // rows stream in as they are
      expect(repairStreamingMarkdown(ready), ready);
    });

    test('lines that are only the start of a construct wait', () {
      expect(repairStreamingMarkdown('段落\n\n#'), '段落');
      expect(repairStreamingMarkdown('段落\n\n- '), '段落');
      expect(repairStreamingMarkdown('标题\n=='), '标题');
      expect(repairStreamingMarkdown('段落\n\n```pyth'), '段落');
      expect(repairStreamingMarkdown('段落\n\n```python\nprint("hi'), '段落\n\n```python\nprint("hi');
      expect(repairStreamingMarkdown('换行<b'), '换行');
    });

    test('maths is opaque to the repair', () {
      expect(repairStreamingMarkdown(r'设 \(a_1 * b_2\) 和 **粗'), r'设 \(a_1 * b_2\) 和 **粗**');
    });

    test('finished blocks before the tail are untouched', () {
      const head = '**未闭合的旧段落\n\n';
      expect(repairStreamingMarkdown('$head新段落'), '$head新段落');
    });
  });

  group('boldTableHeaders', () {
    test('header cells become bold, the rest stays', () {
      expect(boldTableHeaders('| 模型 | 价格 |\n|:---|---:|\n| V4 | 4 |'), '| **模型** | **价格** |\n|:---|---:|\n| V4 | 4 |');
      expect(boldTableHeaders('a | b\n--- | ---\nc | d'), '**a** | **b**\n--- | ---\nc | d');
      expect(boldTableHeaders('> | 甲 | 乙 |\n> |---|---|'), '> | **甲** | **乙** |\n> |---|---|');
    });

    test('cells with emphasis, escaped pipes and code fences are left alone', () {
      expect(boldTableHeaders('| **已粗** | snake_case |\n|---|---|'), '| **已粗** | snake_case |\n|---|---|');
      expect(
        boldTableHeaders(
          r'| a \| b | c |'
          '\n|---|---|',
        ),
        r'| **a \| b** | **c** |'
        '\n|---|---|',
      );
      const fenced = '```\n| a | b |\n|---|---|\n```';
      expect(boldTableHeaders(fenced), fenced);
      expect(boldTableHeaders('no table - here | really'), 'no table - here | really');
      // A setext heading, not a table.
      expect(boldTableHeaders('a | b\n---'), 'a | b\n---');
    });
  });

  group('blankLineBeforeTables', () {
    test('a table glued to the paragraph above gets a blank line', () {
      expect(
        blankLineBeforeTables('按症状查的清单：\n| 症状 | 方向 |\n|---|---|\n| 卡顿 | CPU |'),
        '按症状查的清单：\n\n| 症状 | 方向 |\n|---|---|\n| 卡顿 | CPU |',
      );
    });

    test('a table already separated, or under a block that ends it, is left alone', () {
      for (final source in [
        '清单：\n\n| a | b |\n|---|---|',
        '## 清单\n| a | b |\n|---|---|',
        '- 清单\n| a | b |\n|---|---|',
      ]) {
        expect(blankLineBeforeTables(source), source);
      }
    });

    test('a table inside a quote keeps the quote marker', () {
      expect(
        blankLineBeforeTables('> 清单：\n> | a | b |\n> |---|---|'),
        '> 清单：\n>\n> | a | b |\n> |---|---|',
      );
    });

    test('fenced code and indented tables are untouched', () {
      for (final source in [
        '```\n说明：\n| a | b |\n|---|---|\n```',
        '- 条目：\n  | a | b |\n  |---|---|',
      ]) {
        expect(blankLineBeforeTables(source), source);
      }
    });

    test('a bare rule stays a rule', () {
      expect(blankLineBeforeTables('标题\n---'), '标题\n---');
    });
  });

  test('prepareTables is one pass of blankLineBeforeTables then boldTableHeaders', () {
    for (final source in [
      '清单：\n| a | b |\n|---|---|\n| 1 | 2 |',
      // The blank above the second header cuts the first one off its delimiter.
      '| x | y |\n|---|---|\n|---|---|',
      '| a | b |\n|---|---|\n|---|---|\n|---|---|',
    ]) {
      expect(prepareTables(source), boldTableHeaders(blankLineBeforeTables(source)));
    }
    expect(prepareTables('| x | y |\n|---|---|\n|---|---|'), '| x | y |\n\n|**---**|**---**|\n|---|---|');
  });

  test('stream updates prepare only the live tail and preserve whole-reply syntax', () {
    String whole(String input) => prepareTables(normalizeMath(fenceBareDshUiViews(input), streaming: true));
    final lengths = <int>[];
    final cache = StreamingMarkdownPreparation((input) {
      lengths.add(input.length);
      return whole(input);
    });
    void check(String input) => expect(cache.prepare(input), whole(input), reason: input);

    const formula =
        r'Take $x$.'
        '\n\n';
    const table = 'Values\n| Name |\n| --- |\n| Ada |\n\n';
    const code = '```sh\necho "\$HOME"\n```\n\n';
    const sealed = '$formula$table$code';
    check(formula);
    check(formula + table);
    check(sealed);
    lengths.clear();
    check('${sealed}red');
    check('${sealed}redraw');
    expect(lengths, [3, 6]);

    check('$sealed```sh\n');
    lengths.clear();
    check('$sealed```sh\necho "\$HOME"');
    check('$sealed```sh\necho "\$HOME"\n| A | B |\n|---|---|\n');
    expect(lengths, isEmpty, reason: 'an open code body passes through preparation unchanged');

    // A list step's fence indented up to three spaces is trusted like a flush one.
    const step = '1. Run:\n\n   ```sh\n   echo "\$HOME"\n   ```\n\n';
    check(sealed + step);
    lengths.clear();
    check('$sealed${step}red');
    expect(lengths, [3]);

    for (final (start, more) in [
      ('prefix ```inline\n```dart\nx\n```\n\n', r'tail $x$'),
      ('cost \$a\\\n~~~\$\nx\n~~~\n\n', r'tail $x$'),
      ('{\n"type":"text",\n\n', '"text":"a }"}'),
      (
        r'$$'
            '\nx\n\n',
        r'next $$',
      ),
      ('```\nx\n\u0085```\n\n', '{"type":"text","text":"ok"}'),
    ]) {
      check(sealed + start);
      check(sealed + start + more);
    }
    check(r'Replaced with $y$.');
  });
}
