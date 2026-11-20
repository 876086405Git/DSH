// Credential masking in sent user text: the matcher against the official
// table (each format with near misses), overlaps, linear time on hostile
// input, and the bubble (masked display, the eye, copy keeps the original).

import 'package:dsh_app/ui/chat/secret_mask.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// [n] characters cycling through [alphabet].
String fill(int n, [String alphabet = 'a1B2c3D4e5F6g7H8']) =>
    List.generate(n, (i) => alphabet[i % alphabet.length]).join();

/// Each credential found: its original spelling and its display form.
List<(String, String)> found(String text) => [
  for (final s in findSecrets(text)) (text.substring(s.start, s.end), s.masked),
];

/// A prefixed key as displayed: eight characters, then one `*` each.
String keep8(String token) => token.substring(0, 8) + '*' * (token.length - 8);

const _sk = 'sk-4c1f0e7b9a2d4e6f8a1b3c5d7e9fa3f9';
const _jwt =
    'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.'
    'dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U';
final _ghp = 'ghp_${fill(36)}';

void main() {
  group('prefixed keys keep their first eight characters', () {
    final keys = <String, String>{
      'sk- (DeepSeek)': _sk,
      'sk- with dashes': 'sk-proj-${fill(40, 'Ab1-cD2_')}',
      'AIza': 'AIza${fill(35, 'Sy0_9-xQ')}',
      'ghp_': _ghp,
      'gho_': 'gho_${fill(36)}',
      'ghu_': 'ghu_${fill(36)}',
      'ghs_': 'ghs_${fill(36)}',
      'ghr_': 'ghr_${fill(36)}',
      'github_pat_': 'github_pat_${fill(82, 'A1b2_C3')}',
      'glpat-': 'glpat-${fill(20, 'xY-z9_')}',
      'npm_': 'npm_${fill(36)}',
      'hf_': 'hf_${fill(34)}',
      'AKIA': 'AKIAIOSFODNN7EXAMPLE',
      'ASIA': 'ASIA${fill(16, 'QWERTY0123')}',
      'LTAI (12)': 'LTAI${fill(12)}',
      'LTAI (20)': 'LTAI${fill(20)}',
      'AKID': 'AKID${fill(32)}',
      'xoxa-': 'xoxa-2-${fill(30)}',
      'xoxb-': 'xoxb-123456789012-1234567890123-${fill(24)}',
      'xoxp-': 'xoxp-${fill(40, 'a1-B2')}',
      'xoxr-': 'xoxr-${fill(12)}',
      'xoxs-': 'xoxs-${fill(12)}',
      'sk_live_': 'sk_live_${fill(24)}',
      'sk_test_': 'sk_test_${fill(24)}',
      'rk_live_': 'rk_live_${fill(24)}',
      'rk_test_': 'rk_test_${fill(24)}',
      'whsec_': 'whsec_${fill(32)}',
      'JWT': _jwt,
    };
    for (final MapEntry(key: name, value: token) in keys.entries) {
      test(name, () {
        expect(found('用这个:$token 试试'), [(token, keep8(token))]);
        expect(found(token), [(token, keep8(token))]);
      });
    }

    test('AIza is exactly 35 characters after the prefix', () {
      final key = 'AIza${fill(35)}';
      expect(found('${key}XYZ'), [(key, keep8(key))]);
    });
  });

  group('near misses stay as written', () {
    final misses = <String, String>{
      'sk- without a digit': 'sk-abcdefghijklmnopqrstuvwxyz',
      'sk- too short': 'sk-${fill(19)}',
      'sk- inside a word': 'task-${fill(30)}',
      'sk- digit past 256': 'sk-${'a' * 300}1bcdef',
      'AIza too short': 'AIza${fill(34)}',
      'ghp_ too short': 'ghp_${fill(35)}',
      'npm_ too short': 'npm_${fill(35)}',
      'hf_ too short': 'hf_${fill(29)}',
      'AKIA too long': 'AKIAIOSFODNN7EXAMPLEX',
      'AKIA into lowercase': 'AKIAIOSFODNN7EXAMPLEx',
      'LTAI too short': 'LTAI${fill(11)}',
      'LTAI too long': 'LTAI${fill(21)}',
      'AKID too short': 'AKID${fill(27)}',
      'xoxb- too short': 'xoxb-123',
      'whsec_ too short': 'whsec_${fill(23)}',
      'sk_live_ too short': 'sk_live_${fill(15)}',
      'JWT header alone': 'eyJhbGciOiJIUzI1NiJ9',
      'JWT short signature': 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abc',
      'named assignments': 'password=hunter2 API_KEY=abc123 token: 123456',
      'public key block': '-----BEGIN PUBLIC KEY-----\nMIIBIjANBg\n-----END PUBLIC KEY-----',
      'port, no password': 'https://example.com:8080/path',
      'user, no password': 'ssh://git@github.com/o/r',
      'empty password': 'https://user:@host',
      'no scheme': 'user:pass@host',
      'uppercase scheme (a Windows path)': 'C://u:pw@host',
    };
    for (final MapEntry(key: name, value: text) in misses.entries) {
      test(name, () => expect(findSecrets(text), isEmpty));
    }
  });

  group('address passwords are masked whole', () {
    test('a plain password', () {
      expect(found('postgres://admin:p%40ss-w0rd@db.internal:5432/app'), [('p%40ss-w0rd', '*' * 11)]);
    });

    test('a password may hold colons; the user name may be empty', () {
      expect(found('redis://:a:b:c@cache'), [('a:b:c', '*****')]);
    });

    test('a token used as the password is masked whole', () {
      expect(found('https://x-access-token:$_ghp@github.com/o/r.git'), [(_ghp, '*' * _ghp.length)]);
    });

    test('a token as the user name keeps its prefix', () {
      expect(found('https://$_ghp:x-oauth-basic@github.com'), [(_ghp, keep8(_ghp)), ('x-oauth-basic', '*' * 13)]);
    });

    test('one mark per character, a surrogate pair is one', () {
      expect(found('https://u:密码🔑@host'), [('密码🔑', '***')]);
    });
  });

  group('private key blocks keep BEGIN and END', () {
    test('the body is masked line by line', () {
      const block =
          '-----BEGIN RSA PRIVATE KEY-----\n'
          'MIIEowIBAAK\n'
          'CAQEAx\n'
          '-----END RSA PRIVATE KEY-----';
      expect(found('私钥:\n$block\n用完删掉'), [
        (
          block,
          '-----BEGIN RSA PRIVATE KEY-----\n'
              '***********\n'
              '******\n'
              '-----END RSA PRIVATE KEY-----',
        ),
      ]);
    });

    test('CRLF line breaks stay in place', () {
      const block =
          '-----BEGIN OPENSSH PRIVATE KEY-----\r\n'
          'b3Blbn\r\n'
          '-----END OPENSSH PRIVATE KEY-----';
      expect(found(block), [
        (
          block,
          '-----BEGIN OPENSSH PRIVATE KEY-----\r\n'
              '******\r\n'
              '-----END OPENSSH PRIVATE KEY-----',
        ),
      ]);
    });

    test('without an END line the block runs to the end of the text', () {
      const text = '看 -----BEGIN EC PRIVATE KEY-----\nabc\ndef 后面';
      expect(found(text), [
        ('-----BEGIN EC PRIVATE KEY-----\nabc\ndef 后面', '-----BEGIN EC PRIVATE KEY-----\n***\n******'),
      ]);
    });

    test('a block written on one line is masked whole', () {
      const block = '-----BEGIN PRIVATE KEY----- MIIB -----END PRIVATE KEY-----';
      expect(found(block), [(block, '*' * block.length)]);
    });
  });

  group('overlaps', () {
    test('a key inside another key joins the earlier one', () {
      final token = 'glpat-abcdefghij-sk-${fill(24)}';
      expect(found(token), [(token, keep8(token))]);
    });

    test('a key block whose first dash ends sk- is still seen', () {
      const block = '-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----';
      // `sk-----BEGIN`: the scan resumes inside `sk-`, at its dash.
      final spans = findSecrets('sk$block');
      expect(spans, hasLength(1));
      expect(spans.single.start, 2);
      expect(spans.single.end, 2 + block.length);
    });

    test('a JWT as an address password takes the address mask', () {
      expect(found('wss://bot:$_jwt@chat.example.com'), [(_jwt, '*' * _jwt.length)]);
    });

    test('several credentials, in order', () {
      final text = '$_sk 和 $_ghp,还有 mysql://root:toor@localhost';
      expect(found(text), [(_sk, keep8(_sk)), (_ghp, keep8(_ghp)), ('toor', '****')]);
      expect(maskSecrets(text), '${keep8(_sk)} 和 ${keep8(_ghp)},还有 mysql://root:****@localhost');
    });

    test('no credential: the text itself', () {
      const text = '帮我看看这个报错';
      expect(maskSecrets(text), same(text));
    });
  });

  group('linear time', () {
    // Each input is about a million code units built to defeat a naive
    // matcher: runs re-measured from every candidate, a password run walked
    // again after every key, a key block searched for an END that never
    // comes. A backtracking or quadratic matcher takes minutes here.
    const size = 1 << 20;
    String repeat(String unit) => unit * (size ~/ unit.length);
    final hostile = <String, String>{
      'prose': repeat('这是一段普通的文字,没有凭据。hello world 12345 '),
      'sk- chain without digits': repeat('sk-'),
      'sk- run, digit far away': '${repeat('sk-a')}1',
      'keys before an endless password': repeat('AKIAIOSFODNN7EXAMPLE:'),
      'schemes without passwords': repeat('ab://cd:'),
      'BEGIN headers without END': repeat('-----BEGIN RSA PRIVATE KEY-----\n'),
      'BEGIN, then END lines without labels': '-----BEGIN RSA PRIVATE KEY-----\n${repeat('-----END x ')}',
      'JWT fragments': repeat('eyJaaaaaaaa.eyJbbbbbbbb.'),
      'many valid keys': repeat('$_sk '),
    };
    for (final MapEntry(key: name, value: text) in hostile.entries) {
      test(name, () {
        final watch = Stopwatch()..start();
        findSecrets(text);
        watch.stop();
        // Typically tens of milliseconds; the bound leaves room for a slow CI.
        expect(watch.elapsedMilliseconds, lessThan(2000), reason: name);
      });
    }
  });

  group('bubble', () {
    final text = '用这个 Key 跑一下:$_sk 谢谢';
    final display = keep8(_sk);

    Future<void> pump(WidgetTester tester, Widget bubble) async {
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Padding(padding: const EdgeInsets.all(16), child: bubble),
          ),
        ),
      );
    }

    testWidgets('a sent message masks the key; the eye shows and hides it', (tester) async {
      await pump(tester, UserBubble(text: text));
      expect(find.bySemanticsLabel(display), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(_sk)), findsNothing);
      expect(find.textContaining(_sk), findsNothing);
      final masked = tester.getSize(find.byType(SecretText));

      await tester.tap(find.bySemanticsLabel('显示密钥'));
      await tester.pump();
      expect(find.bySemanticsLabel(_sk), findsOneWidget);
      expect(find.bySemanticsLabel('隐藏密钥'), findsOneWidget);
      // Monospace, same length: showing it moves nothing around it.
      expect(tester.getSize(find.byType(SecretText)), masked);

      await tester.tap(find.bySemanticsLabel('隐藏密钥'));
      await tester.pump();
      expect(find.bySemanticsLabel(display), findsOneWidget);
    });

    testWidgets('copy and the menu use the original; the preview is masked', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      await pump(tester, UserBubble(text: text));
      // On the plain words before the key: the key itself is a masked run.
      await tester.longPressAt(tester.getTopLeft(find.byType(SecretText)) + const Offset(8, 10));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextSelectionToolbarTextButton, '更多'));
      await tester.pumpAndSettle();
      expect(find.text(maskSecrets(text, mark: '•')), findsOneWidget);
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(copied, text);
    });

    testWidgets('an optimistic bubble masks without the eye', (tester) async {
      await pump(tester, UserBubble(text: text, pendingLabel: '排队中'));
      expect(find.bySemanticsLabel(display), findsOneWidget);
      expect(find.bySemanticsLabel('显示密钥'), findsNothing);
    });

    testWidgets('every mount, and every other value, starts masked', (tester) async {
      await pump(tester, UserBubble(text: text));
      await tester.tap(find.bySemanticsLabel('显示密钥'));
      await tester.pump();
      expect(find.bySemanticsLabel(_sk), findsOneWidget);

      // Same place, another key: masked again.
      final other = 'sk-${fill(32, '0123456789abcdef')}';
      await pump(tester, UserBubble(text: '用这个 Key 跑一下:$other 谢谢'));
      expect(find.bySemanticsLabel(keep8(other)), findsOneWidget);

      // Remounted: masked again.
      await pump(tester, const SizedBox());
      await pump(tester, UserBubble(text: text));
      expect(find.bySemanticsLabel(display), findsOneWidget);
    });

    testWidgets('the chat text size scales the value once', (tester) async {
      Future<Size> sizeAt(double scale) async {
        await tester.pumpWidget(
          testApp(
            MediaQuery.withClampedTextScaling(
              minScaleFactor: scale,
              maxScaleFactor: scale,
              child: const Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SecretText(
                    'AKIAIOSFODNN7EXAMPLE',
                    style: TextStyle(fontSize: 16, height: 1.65),
                    interactive: true,
                  ),
                ),
              ),
            ),
          ),
        );
        return tester.getSize(find.byType(SecretText));
      }

      final base = await sizeAt(1);
      final large = await sizeAt(1.3);
      // WidgetSpan already scales its child; scaling the mono text again
      // would make this 1.69.
      expect(large.width / base.width, closeTo(1.3, 0.02));
      expect(large.height / base.height, closeTo(1.3, 0.02));
    });

    testWidgets('text without credentials is a plain Text', (tester) async {
      await pump(tester, const UserBubble(text: '帮我看看这个报错'));
      expect(find.text('帮我看看这个报错'), findsOneWidget);
      expect(find.bySemanticsLabel('显示密钥'), findsNothing);
    });
  });
}
