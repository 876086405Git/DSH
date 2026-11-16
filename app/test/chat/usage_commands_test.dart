// Slash-command catalog parsing and filtering, session usage from captured
// `session/control` frames, and the DeepSeek balance state.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/balance_state.dart';
import 'package:dsh_app/state/commands_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/usage_state.dart';
import 'package:dsh_app/ui/chat/balance_widgets.dart';
import 'package:dsh_app/ui/chat/slash_palette.dart';
import 'package:dsh_app/ui/chat/usage_sheet.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

void main() {
  group('slash commands', () {
    final all = mergeSlashCommands(testHostCommands);

    test('/export: Android says 下载; HarmonyOS, where the system asks where, says 保存到文件', () {
      String export(List<SlashCommand> commands) => commands.firstWhere((c) => c.name == 'export').description;
      expect(export(all), '把这个对话的完整记录打包成 ZIP，分享或存到「下载」');
      expect(export(mergeSlashCommands(testHostCommands, harmony: true)), '把这个对话的完整记录打包成 ZIP，分享或保存到文件');

      String palette(String os) {
        final container = ProviderContainer(
          overrides: [
            operatingSystemProvider.overrideWithValue(os),
            activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
          ],
        );
        addTearDown(container.dispose);
        return export(container.read(slashCommandsProvider(null)));
      }

      expect(palette('android'), '把这个对话的完整记录打包成 ZIP，分享或存到「下载」');
      expect(palette('ohos'), '把这个对话的完整记录打包成 ZIP，分享或保存到文件');
    });

    test('catalog: Chinese faces by definitionId, Web-only /export hidden', () {
      expect(testHostCommands.map((c) => c.name), ['goal', 'plan', 'feedback', 'compact', 'permission']);
      final compact = testHostCommands.firstWhere((c) => c.name == 'compact');
      expect(compact.label, '压缩');
      expect(compact.takesInput, isFalse);
      final permission = testHostCommands.firstWhere((c) => c.name == 'permission');
      expect(permission.hint, '<预设名>');
      expect(permission.takesInput, isTrue);
    });

    test('a same-name plugin override keeps its own copy', () {
      final parsed = parseCommandList([
        {'definitionId': 'my-plugin#compact', 'name': 'compact', 'description': 'Mine'},
        {
          'name': 'deploy',
          'description': 'Ship it',
          'input': {'hint': '<env>'},
        },
        {'description': 'no name'},
      ]);
      expect(parsed.map((c) => (c.name, c.label, c.description, c.hint)), [
        ('compact', 'compact', 'Mine', null),
        ('deploy', 'deploy', 'Ship it', '<env>'),
      ]);
    });

    test('palette order: app commands, first-party, then the rest', () {
      final withPlugin = mergeSlashCommands([
        ...parseCommandList([
          {'name': 'deploy', 'description': 'Ship it'},
        ]),
        ...testHostCommands,
      ]);
      expect(withPlugin.map((c) => c.name), [
        'new',
        'model',
        'compact',
        'permission',
        'plan',
        'goal',
        'feedback',
        'export',
        'features',
        'deploy',
      ]);
    });

    test('filter: name prefix, title, substring, subsequence', () {
      List<String> names(String q) => filterSlashCommands(all, q).map((c) => c.name).toList();
      expect(names(''), hasLength(all.length));
      expect(names('p'), ['permission', 'plan', 'compact', 'export']);
      expect(names('压'), ['compact']);
      expect(names('cpt'), ['compact']);
      expect(names('MOD'), ['model']);
      expect(names('zzz'), isEmpty);
    });

    test('parse and resolve a command line', () {
      expect(parseSlashInput('hello /compact'), isNull);
      final partial = parseSlashInput('/per')!;
      expect((partial.token, partial.hasArgs), ('per', false));
      final full = parseSlashInput('/permission read-only')!;
      expect((full.token, full.rest), ('permission', ' read-only'));
      final indented = parseSlashInput(' \t/permission read-only')!;
      expect((indented.token, indented.rest), ('permission', ' read-only'));
      expect(parseSlashInput(' \thello /permission'), isNull);
      expect(resolveSlashCommand(all, '压缩')?.name, 'compact');
      expect(resolveSlashCommand(all, 'perm'), isNull);
    });

    test('palette content: matches while typing, a hint once input starts', () {
      expect(PaletteContent.of(all, 'hi'), isNull);
      expect(PaletteContent.of(all, '/'), isA<PaletteMatches>());
      final hint = PaletteContent.of(all, '/permission ');
      expect(hint, isA<PaletteHint>());
      expect((hint! as PaletteHint).command.name, 'permission');
      expect(PaletteContent.of(all, '/compact now'), isNull);
      expect(PaletteContent.of(all, '/sdcard/a.txt 看看'), isNull);
    });

    test('palette filters the first token only up to the caret', () {
      final inserted = PaletteContent.of(all, '/已有文字', caret: 1) as PaletteMatches;
      expect(inserted.commands, all);
      expect(inserted.typed, isFalse);
      expect(PaletteContent.of(all, ' \t/已有文字', caret: 3), isA<PaletteMatches>());
      final partial = PaletteContent.of(all, '/permission read-only', caret: 4) as PaletteMatches;
      expect(partial.commands.first.name, 'permission');
      expect(PaletteContent.of(all, 'hello /', caret: 7), isNull);
      expect(PaletteContent.of(all, '/', caret: 0), isNull);
      expect(PaletteContent.of(all, '/', caret: -1), isNull);
      expect(PaletteContent.of(all, '/', caret: 2), isNull);
    });
  });

  group('session usage', () {
    test('folds captured session/control frames', () {
      final lines = File('../packages/dsh_client/test/fixtures/control_reply_ok.jsonl')
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty);
      var values = <String, Object?>{};
      String? session;
      for (final line in lines) {
        final frame = jsonDecode(line) as Map<String, Object?>;
        if (frame['type'] == 'baseline') {
          final projections = (frame['value']! as Map)['projections'] as Map<String, Object?>;
          session ??= projections.keys.first;
          values = {...((projections[session]! as Map)['values'] as Map<String, Object?>)};
        } else if (frame['sessionId'] == session) {
          values[frame['key']! as String] = frame['value'];
        }
      }
      final usage = SessionUsage.fromProjections(values);
      expect(usage.uncachedInput, 10129);
      expect(usage.output, 2);
      expect(usage.input, 10129);
      expect(usage.cacheHitRate, 0);
      expect(usage.contextWindow, 1000000);
      expect(usage.pressureTokens, 10129);
      expect(usage.projectedTokens, 10142);
      expect(usage.contextTokens, 10142);
      expect(usage.contextFraction, closeTo(0.010142, 0.000001));
      expect(usage.systemTokens, 1467);
      expect(usage.toolsTokens, 5157);
      expect(usage.turns, 1);
      expect(formatPercent(usage.contextFraction!), '1%');
    });

    test('empty projections: no window, no hit rate', () {
      final usage = SessionUsage.fromProjections(const {});
      expect(usage.contextFraction, isNull);
      expect(usage.cacheHitRate, isNull);
      expect(usage.hasTokens, isFalse);
    });

    test('context estimate follows compaction and falls back to the last sample', () {
      const before = SessionUsage(pressureTokens: 840, projectedTokens: 840, contextWindow: 1000);
      const after = SessionUsage(pressureTokens: 840, projectedTokens: 400, contextWindow: 1000);
      const fallback = SessionUsage(pressureTokens: 840, contextWindow: 1000);
      const unknown = SessionUsage(contextWindow: 1000);
      const zero = SessionUsage(projectedTokens: 0, pressureTokens: 840, contextWindow: 1000);
      expect(before.contextFraction, 0.84);
      expect(after.contextTokens, 400);
      expect(after.contextFraction, 0.4);
      expect(fallback.contextFraction, 0.84);
      expect(unknown.contextFraction, isNull);
      expect(zero.contextFraction, 0);
      expect(const SessionUsage(projectedTokens: 1200, contextWindow: 1000).contextFraction, 1);
      expect(const SessionUsage(projectedTokens: 1, contextWindow: 0).contextFraction, isNull);
    });

    test('cache hit rate and cost need real numbers', () {
      const usage = SessionUsage(uncachedInput: 2000, cacheRead: 6000, output: 500);
      expect(usage.cacheHitRate, 0.75);
      expect(knownPricing, isEmpty, reason: 'no prices are made up');
      const pricing = TokenPricing(currency: 'CNY', inputPerMillion: 2, cacheHitPerMillion: 0.5, outputPerMillion: 8);
      expect(estimateCost(usage, pricing), closeTo(0.011, 1e-9));
    });

    test('token and percent formatting', () {
      // K/M in every language: no 万/亿, whatever the UI language is.
      expect(formatTokens(0), '0');
      expect(formatTokens(999), '999');
      expect(formatTokens(1000), '1K');
      expect(formatTokens(8421), '8.4K');
      expect(formatTokens(15000), '15K');
      expect(formatTokens(43000), '43K');
      expect(formatTokens(500000), '500K');
      expect(formatTokens(999999), '1M'); // never 1000K
      expect(formatTokens(1000000), '1M');
      expect(formatTokens(1048576), '1.05M');
      expect(formatTokens(1050000), '1.05M');
      expect(formatTokens(100000000), '100M');
      expect(formatTokens(150000000), '150M');
      expect(formatPercent(0.004), '<1%');
      expect(formatPercent(0), '0%');
      expect(formatPercent(0.876), '88%');
    });
  });

  group('balance', () {
    test('parses /user/balance, preferring CNY', () {
      const body =
          '{"is_available":true,"balance_infos":['
          '{"currency":"USD","total_balance":"1.00","granted_balance":"0.00","topped_up_balance":"1.00"},'
          '{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}';
      final result = balanceResultOf(200, body);
      expect(result, isA<BalanceOk>());
      final b = (result as BalanceOk).balance;
      expect((b.currency, b.total, b.granted, b.toppedUp), ('CNY', 110.0, 10.0, 100.0));
      expect(formatMoney(b), '¥110.00');
      expect(formatThreshold(5), '¥5');
    });

    test('401 is an invalid key; anything else is quietly unavailable', () {
      expect(balanceResultOf(401, '{"error":{}}'), isA<BalanceInvalidKey>());
      expect(balanceResultOf(500, ''), isA<BalanceUnavailable>());
      expect(balanceResultOf(200, 'not json'), isA<BalanceUnavailable>());
      expect(balanceResultOf(200, '{"balance_infos":[]}'), isA<BalanceUnavailable>());
    });

    group('controller', () {
      late DateTime clock;
      late List<String> requests;
      late BalanceResult answer;

      setUp(() {
        SharedPreferences.setMockInitialValues({});
        clock = DateTime(2026, 10, 23, 12);
        BalanceController.now = () => clock;
        requests = [];
        answer = healthyBalance;
      });
      tearDown(() => BalanceController.now = DateTime.now);

      ProviderContainer container([String key = testKey]) {
        final c = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(() => TestSettings(AppSettings(loaded: true, apiKey: key))),
            balanceFetcherProvider.overrideWithValue((k) async {
              requests.add(k);
              return answer;
            }),
            accountWalletBalanceProvider.overrideWithValue(null),
          ],
        );
        addTearDown(c.dispose);
        c.listen(balanceProvider, (_, _) {});
        return c;
      }

      Future<void> settle() => Future<void>.delayed(Duration.zero);

      test('asks on first read, then at most once a minute', () async {
        final c = container();
        await settle();
        expect(requests, [testKey]);
        expect(c.read(balanceProvider).status, BalanceStatus.ok);
        expect(c.read(balanceProvider).balance?.total, 110);

        await c.read(balanceProvider.notifier).refresh();
        expect(requests, hasLength(1), reason: 'throttled');
        clock = clock.add(const Duration(seconds: 61));
        await c.read(balanceProvider.notifier).refresh();
        expect(requests, hasLength(2));
      });

      test('a key change asks again right away', () async {
        final c = container();
        await settle();
        await c.read(settingsProvider.notifier).setApiKey('sk-other-key-000000000000');
        await settle();
        expect(requests, [testKey, 'sk-other-key-000000000000']);
      });

      test('no key: nothing is requested', () async {
        final c = container('');
        await settle();
        expect(requests, isEmpty);
        expect(c.read(balanceProvider).status, BalanceStatus.noKey);
        expect(c.read(balanceProvider).isLow, isFalse);
      });

      test('low balance shows the banner until dismissed; 0 = never', () async {
        answer = lowBalance;
        final c = container();
        await settle();
        expect(c.read(balanceProvider).isLow, isTrue);
        expect(c.read(balanceProvider).showBanner, isTrue);
        c.read(balanceProvider.notifier).dismissBanner();
        expect(c.read(balanceProvider).showBanner, isFalse);
        await c.read(balanceProvider.notifier).setThreshold(0);
        expect(c.read(balanceProvider).isLow, isFalse);
        expect(c.read(balanceProvider).showBanner, isFalse);
        await c.read(balanceProvider.notifier).setThreshold(10);
        expect(c.read(balanceProvider).showBanner, isTrue);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getDouble('low_balance_threshold'), 10);
      });

      test('「不提醒」 also silences a balance that can no longer pay', () async {
        answer = const BalanceOk(DeepSeekBalance(currency: 'CNY', total: 0, available: false));
        final c = container();
        await settle();
        expect(c.read(balanceProvider).isLow, isTrue);
        expect(c.read(balanceProvider).showBanner, isTrue);
        await c.read(balanceProvider.notifier).setThreshold(0);
        expect(c.read(balanceProvider).isLow, isTrue);
        expect(c.read(balanceProvider).showBanner, isFalse);
      });

      test('invalid key and offline are told apart, quietly', () async {
        answer = const BalanceInvalidKey();
        final c = container();
        await settle();
        expect(c.read(balanceProvider).status, BalanceStatus.invalidKey);

        answer = healthyBalance;
        clock = clock.add(const Duration(minutes: 2));
        await c.read(balanceProvider.notifier).refresh();
        answer = const BalanceUnavailable();
        clock = clock.add(const Duration(minutes: 2));
        await c.read(balanceProvider.notifier).refresh();
        final state = c.read(balanceProvider);
        expect(state.status, BalanceStatus.unavailable);
        expect(state.balance?.total, 110, reason: 'keeps the last good value');
      });
    });
  });

  test('ModelCatalog from 0.2.1 without a key is empty', () {
    final catalog = ModelCatalog.fromJson({
      'default': null,
      'routableProviders': <Object?>[],
      'groups': <Object?>[],
      'failures': <Object?>[],
    });
    expect(catalog.models, isEmpty);
  });
}
