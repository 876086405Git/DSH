// The star prompt (docs/design/star-prompt.md): half an hour with the app in
// front (29 minutes no, 30 yes), counted only while it is resumed and kept
// across launches; 「下次再说」 (or back) asks again at 2, 5, 10 and 20 hours
// of use (an hour after a late one at least), each time in other words with
// the real hours, and never a sixth time; 「去 GitHub 点 Star」
// opens the repository and 「已经点过啦」 ends it. It only comes up when the
// person is idle in the chat (not during first run, not over another page,
// not while the chat runs, not in a launch that already showed a notice),
// the release switch off keeps it inert, failing preferences change nothing
// visible, the dialog fits 360 wide at 1 and 1.3× text and a tablet, the
// whale bobs in only with animations on, and goldens light and dark.
//
//   flutter test --update-goldens test/star/star_prompt_test.dart

import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/pets/pet_mood.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart' show RuntimePhase, RuntimeStatus;
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/state/phone_state.dart' show phoneChannelProvider;
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/star_prompt.dart';
import 'package:dsh_app/state/voice_state.dart';
import 'package:dsh_app/ui/common/side_insets.dart';
import 'package:dsh_app/ui/settings/about_page.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/shell/root_gate.dart';
import 'package:dsh_app/ui/star/star_prompt_dialog.dart';
import 'package:dsh_app/ui/star/star_prompt_host.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/support.dart' show FixedActiveHost;
import '../shell/golden_harness.dart';
import '../support/test_fonts.dart';
import '../usage/support.dart' show NoPhone;

// ── Fakes ────────────────────────────────────────────────────────────────────

class MemoryStarStore implements StarPromptStore {
  MemoryStarStore([this.record]);

  StarPromptRecord? record;
  var reads = 0;
  var writes = 0;
  var failRead = false;
  var failWrite = false;

  @override
  Future<StarPromptRecord?> read() async {
    reads++;
    if (failRead) throw StateError('no preferences');
    return record;
  }

  @override
  Future<void> write(StarPromptRecord record) async {
    writes++;
    if (failWrite) throw StateError('no preferences');
    this.record = record;
  }
}

/// The prompt's clock, moved by hand.
class TestClock {
  Duration now = const Duration(hours: 1);

  Duration call() => now;
}

/// A value the test sets by hand.
class Value<T> extends Notifier<T> {
  Value(this.initial);

  final T initial;

  @override
  T build() => initial;

  void put(T value) => state = value;
}

final _pending = NotifierProvider<Value<List<PetPending>>, List<PetPending>>(() => Value(const []));

class FakePhone extends PhoneTaskSeenController {
  @override
  ({bool active, Duration? lastActive}) build() => (active: false, lastActive: null);

  void put({required bool active, Duration? lastActive}) => state = (active: active, lastActive: lastActive);
}

const _halfHour = Duration(minutes: 30);

/// Half an hour in: due.
const _due = StarPromptRecord(used: _halfHour);

final _github = Uri.parse('https://github.com/ccch1mneyyy/dsh-go');

String _title(int hours) => lookupL10n(AppLocale.zhCN).starPromptTitle(hours);

// ── Harness ──────────────────────────────────────────────────────────────────

class _Bench {
  _Bench(this.tester, this.store, this.clock);

  final WidgetTester tester;
  final MemoryStarStore store;
  final TestClock clock;
  final opened = <Uri>[];
  var browser = true;

  ProviderContainer get container => ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));

  /// [time] passes with the app in front; the next tick writes it down.
  Future<void> use(Duration time) async {
    clock.now += time;
    await tester.pump(StarPromptRules.tick);
  }

  /// Past the settle time, the dialog (if any) up.
  Future<void> settle() async {
    await tester.pump(StarPromptRules.settle);
    await tester.pumpAndSettle();
  }

  bool get showing => find.byType(StarPromptDialog).evaluate().isNotEmpty;

  Future<void> tap(String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  /// The app leaves the screen and comes back, through the lifecycle.
  Future<void> away() async {
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pump();
  }

  Future<void> back() async {
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pump();
  }

  List<Override> get overrides => [
    starPromptStoreProvider.overrideWithValue(store),
    starPromptClockProvider.overrideWithValue(clock.call),
    starLinkOpenerProvider.overrideWithValue((uri) async {
      opened.add(uri);
      return browser;
    }),
    petPendingProvider.overrideWith((ref) => ref.watch(_pending)),
    phoneTaskSeenProvider.overrideWith(FakePhone.new),
  ];
}

void _phoneSurface(WidgetTester tester, {double width = 390, double height = 844, double ratio = 2}) {
  tester.view.devicePixelRatio = ratio;
  tester.view.physicalSize = Size(width * ratio, height * ratio);
  tester.view.padding = FakeViewPadding(top: 32 * ratio, bottom: 24 * ratio);
  tester.view.viewPadding = FakeViewPadding(top: 32 * ratio, bottom: 24 * ratio);
  addTearDown(tester.view.reset);
}

Widget _app({
  required List<Override> overrides,
  required Widget home,
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool reduceMotion = true,
  Locale locale = const Locale('zh', 'CN'),
}) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: withTestFonts(buildLightTheme()),
    darkTheme: withTestFonts(buildDarkTheme()),
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    locale: locale,
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion, textScaler: TextScaler.linear(scale)),
      child: MirroredSideInsets(child: child!),
    ),
    home: home,
  ),
);

/// The home shell's stand-in: the host under a page.
Future<_Bench> _pumpHost(
  WidgetTester tester, {
  StarPromptRecord? record,
  MemoryStarStore? store,
  bool gate = true,
  ValueNotifier<double>? drawer,
}) async {
  _phoneSurface(tester);
  final bench = _Bench(tester, store ?? MemoryStarStore(record), TestClock());
  await tester.pumpWidget(
    _app(
      overrides: [starPromptGateProvider.overrideWithValue(gate), ...bench.overrides],
      home: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            StarPromptHost(drawer: drawer),
            const Center(child: Text('对话')),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
  return bench;
}

/// A page with one key that opens the dialog.
Future<_Bench> _pumpDialog(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  double width = 390,
  double height = 844,
  double scale = 1,
  bool reduceMotion = true,
  int hours = 0,
  Locale locale = const Locale('zh', 'CN'),
}) async {
  _phoneSurface(tester, width: width, height: height);
  final bench = _Bench(tester, MemoryStarStore(_due), TestClock());
  await tester.pumpWidget(
    _app(
      overrides: bench.overrides,
      brightness: brightness,
      scale: scale,
      reduceMotion: reduceMotion,
      locale: locale,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showStarPrompt(context, hours: hours),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  // Decoded for real (FakeAsync never finishes a decode), as the host does before it opens.
  await tester.runAsync(
    () => precacheImage(const AssetImage(StarPromptDialog.asset), tester.element(find.byType(Scaffold))),
  );
  await tester.tap(find.text('打开'));
  await tester.pump();
  return bench;
}

Finder get _dialog => find.byType(StarPromptDialog);
Finder _key(String key) => find.byKey(ValueKey(key));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // A decode begun under FakeAsync never ends: no test inherits one.
    imageCache
      ..clear()
      ..clearLiveImages();
  });

  group('the record', () {
    test('first ask at half an hour: 29 minutes no, 30 yes', () {
      expect(const StarPromptRecord(used: Duration(minutes: 29)).due, isFalse);
      expect(const StarPromptRecord(used: Duration(minutes: 30)).due, isTrue);
    });

    test('after 下次再说: at 2, 5, 10 and 20 hours, an hour after a late one at least; five at most', () {
      expect(StarPromptRules.asks, const [
        Duration(minutes: 30),
        Duration(hours: 2),
        Duration(hours: 5),
        Duration(hours: 10),
        Duration(hours: 20),
      ]);
      const asked = StarPromptRecord(used: Duration(minutes: 40), shows: 1, askedAt: Duration(minutes: 31));
      expect(asked.due, isFalse);
      expect(asked.copyWith(used: const Duration(hours: 1, minutes: 59)).due, isFalse);
      expect(asked.copyWith(used: const Duration(hours: 2)).due, isTrue);
      const third = StarPromptRecord(used: Duration(hours: 4, minutes: 59), shows: 2, askedAt: Duration(hours: 2));
      expect(third.due, isFalse);
      expect(third.copyWith(used: const Duration(hours: 5)).due, isTrue);
      // The first came up late (idle only then): the second waits an hour more.
      const late = StarPromptRecord(
        used: Duration(hours: 4, minutes: 29),
        shows: 1,
        askedAt: Duration(hours: 3, minutes: 30),
      );
      expect(late.due, isFalse);
      expect(late.copyWith(used: const Duration(hours: 4, minutes: 30)).due, isTrue);
      expect(asked.copyWith(used: const Duration(hours: 99), shows: 5).due, isFalse);
      expect(asked.copyWith(used: const Duration(hours: 99), shows: 5).over, isTrue);
      expect(_due.copyWith(finished: true).due, isFalse);
    });

    test('each ask in its own words; the last says it is the last', () {
      for (final l10n in [lookupL10n(AppLocale.zhCN), lookupL10n(AppLocale.en)]) {
        final words = [for (var i = 0; i < StarPromptRules.maxShows; i++) StarPromptDialog.words(l10n, i)];
        expect(words.toSet(), hasLength(StarPromptRules.maxShows));
        expect(StarPromptDialog.words(l10n, StarPromptRules.maxShows), words.last);
      }
      expect(StarPromptDialog.words(lookupL10n(AppLocale.zhCN), 4).$1, contains('最后一次'));
      expect(StarPromptDialog.words(lookupL10n(AppLocale.en), 4).$1, contains('last time'));
    });

    test('the first line tells the real time: half an hour, then whole hours', () {
      final zh = lookupL10n(AppLocale.zhCN);
      final en = lookupL10n(AppLocale.en);
      expect(zh.starPromptTitle(0), '本鱼已经在 DSH Go 里陪你半个小时啦⁠~');
      expect(zh.starPromptTitle(1), '本鱼已经在 DSH Go 里陪你一个小时啦⁠~');
      expect(zh.starPromptTitle(5), '本鱼已经在 DSH Go 里陪你 5 个小时啦⁠~');
      expect(en.starPromptTitle(0), 'I’ve kept you company in DSH Go for half an hour now~');
      expect(en.starPromptTitle(1), 'I’ve kept you company in DSH Go for an hour now~');
      expect(en.starPromptTitle(6), 'I’ve kept you company in DSH Go for 6 hours now~');
    });

    test('keeps through JSON; the earlier prompt’s record keeps only whether it was finished', () {
      const full = StarPromptRecord(
        used: Duration(hours: 6, seconds: 7),
        shows: 2,
        askedAt: Duration(minutes: 31),
        finished: true,
      );
      expect(StarPromptRecord.fromJson(jsonDecode(jsonEncode(full.toJson()))), full);
      expect(StarPromptRecord.fromJson(jsonDecode(jsonEncode(_due.toJson()))), _due);
      expect(
        StarPromptRecord.fromJson({'v': 1, 'firstSeen': 1, 'replies': 10, 'shows': 3, 'finished': true}),
        const StarPromptRecord(finished: true),
      );
      expect(StarPromptRecord.fromJson({'v': 1, 'firstSeen': 1, 'shows': 1}), const StarPromptRecord());
      expect(StarPromptRecord.fromJson({'v': 3}), isNull);
      expect(StarPromptRecord.fromJson('x'), isNull);
    });

    test('in SharedPreferences: one entry; an unreadable one is none', () async {
      const store = PrefsStarPromptStore();
      expect(await store.read(), isNull);
      await store.write(_due);
      expect((await SharedPreferences.getInstance()).getString(PrefsStarPromptStore.key), isNotNull);
      expect(await store.read(), _due);
      SharedPreferences.setMockInitialValues({PrefsStarPromptStore.key: '{not json'});
      expect(await store.read(), isNull);
    });
  });

  group('time in front', () {
    testWidgets('29 minutes: nothing; at 30 it comes up', (tester) async {
      final bench = await _pumpHost(tester);
      for (var i = 0; i < 29; i++) {
        await bench.use(const Duration(minutes: 1));
      }
      await bench.settle();
      expect(bench.showing, isFalse);
      expect(bench.store.record!.used, const Duration(minutes: 29));
      await bench.use(const Duration(minutes: 1));
      await bench.settle();
      expect(bench.showing, isTrue);
      expect(find.text(_title(0)), findsOneWidget);
      expect(find.text('本鱼已经在 DSH Go 里陪你半个小时啦⁠~'), findsOneWidget);
      expect(bench.store.record, const StarPromptRecord(used: _halfHour, shows: 1, askedAt: _halfHour));
    });

    testWidgets('due at launch: three seconds of quiet first', (tester) async {
      final bench = await _pumpHost(tester, record: _due);
      await tester.pump(StarPromptRules.settle - const Duration(milliseconds: 100));
      expect(bench.showing, isFalse);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(bench.showing, isTrue);
    });

    testWidgets('only while resumed, and it keeps across launches', (tester) async {
      final bench = await _pumpHost(tester, record: const StarPromptRecord(used: Duration(minutes: 20)));
      await bench.use(const Duration(minutes: 5));
      expect(bench.store.record!.used, const Duration(minutes: 25));
      // Part of a minute, then away: written on the way out.
      bench.clock.now += const Duration(seconds: 40);
      await bench.away();
      expect(bench.store.record!.used, const Duration(minutes: 25, seconds: 40));
      // Two hours in the background count nothing.
      bench.clock.now += const Duration(hours: 2);
      await tester.pump(const Duration(hours: 2));
      expect(bench.store.record!.used, const Duration(minutes: 25, seconds: 40));
      await bench.settle();
      expect(bench.showing, isFalse);
      await bench.back();
      await bench.use(const Duration(minutes: 4, seconds: 20));
      await bench.settle();
      expect(bench.showing, isTrue);
      expect(bench.store.record!.used, _halfHour);
    });

    testWidgets('the release switch off: nothing, not even the record', (tester) async {
      final bench = await _pumpHost(tester, record: _due, gate: false);
      await bench.use(const Duration(hours: 6));
      await bench.settle();
      expect(bench.showing, isFalse);
      expect(bench.store.reads, 0);
      expect(bench.store.writes, 0);
    });

    testWidgets('preferences that cannot be read: nothing stored is overwritten', (tester) async {
      final stored = _due.copyWith(finished: true);
      final store = MemoryStarStore(stored)..failRead = true;
      final bench = await _pumpHost(tester, store: store);
      await bench.use(const Duration(minutes: 10));
      expect(tester.takeException(), isNull);
      expect(bench.container.read(starPromptProvider).used, const Duration(minutes: 10));
      expect(store.writes, 0);
      expect(store.record, stored);
    });

    testWidgets('preferences that cannot be written: it still comes up, and still goes for good', (tester) async {
      final store = MemoryStarStore(_due)..failWrite = true;
      final bench = await _pumpHost(tester, store: store);
      await bench.settle();
      expect(bench.showing, isTrue);
      await bench.tap('star-done');
      await bench.use(const Duration(hours: 6));
      await bench.settle();
      expect(bench.showing, isFalse);
    });
  });

  group('the answers', () {
    Future<_Bench> up(WidgetTester tester) async {
      final bench = await _pumpHost(tester, record: _due);
      await bench.settle();
      expect(bench.showing, isTrue);
      return bench;
    }

    Future<bool> comesBack(_Bench bench, Duration after) async {
      await bench.use(after);
      await bench.settle();
      return bench.showing;
    }

    testWidgets('去 GitHub 点 Star opens the repository in the browser, and never again', (tester) async {
      final bench = await up(tester);
      await bench.tap('star-go');
      expect(bench.showing, isFalse);
      expect(bench.opened, [_github]);
      expect(bench.store.record!.finished, isTrue);
      expect(await comesBack(bench, const Duration(hours: 6)), isFalse);
      // Nothing more to count.
      expect(bench.store.record!.used, _halfHour);
    });

    testWidgets('no browser: the address is copied instead', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final bench = await up(tester);
      bench.browser = false;
      await bench.tap('star-go');
      expect(bench.opened, [_github]);
      expect(copied, _github.toString());
      expect(find.text('没能打开浏览器，网址已复制'), findsOneWidget);
    });

    testWidgets('已经点过啦: never again, and nothing opens', (tester) async {
      final bench = await up(tester);
      await bench.tap('star-done');
      expect(bench.opened, isEmpty);
      expect(bench.store.record!.finished, isTrue);
      expect(await comesBack(bench, const Duration(hours: 6)), isFalse);
    });

    testWidgets(
      '下次再说: again at 2, 5, 10 and 20 hours in other words, with the real hours; back is the same; then no more',
      (tester) async {
        final bench = await up(tester);
        await bench.tap('star-later');
        expect(bench.showing, isFalse);
        expect(bench.opened, isEmpty);
        expect(bench.store.record, const StarPromptRecord(used: _halfHour, shows: 1, askedAt: _halfHour));
        final zh = lookupL10n(AppLocale.zhCN);
        for (final (ask, hours) in [(1, 2), (2, 5), (3, 10), (4, 20)]) {
          final left = Duration(hours: hours) - bench.store.record!.used;
          expect(await comesBack(bench, left - const Duration(minutes: 1)), isFalse, reason: 'ask $ask');
          expect(await comesBack(bench, const Duration(minutes: 1)), isTrue, reason: 'ask $ask');
          expect(find.text(_title(hours)), findsOneWidget);
          expect(find.text(StarPromptDialog.words(zh, ask).$1), findsOneWidget);
          expect(find.text(StarPromptDialog.words(zh, ask).$2), findsOneWidget);
          if (ask < 4) {
            await bench.tap('star-later');
          } else {
            // The back gesture: as 下次再说.
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
          }
          expect(bench.showing, isFalse);
        }
        expect(find.text('本鱼已经在 DSH Go 里陪你 20 个小时啦⁠~'), findsNothing);
        expect(bench.store.record!.shows, StarPromptRules.maxShows);
        expect(bench.store.record!.finished, isFalse);
        expect(await comesBack(bench, const Duration(hours: 24)), isFalse);
        expect(bench.store.record!.used, const Duration(hours: 20), reason: 'counting stopped');
      },
    );

    testWidgets('a tap outside: as 下次再说', (tester) async {
      final bench = await up(tester);
      await tester.tapAt(const Offset(8, 60));
      await tester.pumpAndSettle();
      expect(bench.showing, isFalse);
      expect(bench.store.record!.shows, 1);
      expect(bench.store.record!.finished, isFalse);
    });

    testWidgets('the second ask tells the hours actually spent', (tester) async {
      final bench = await _pumpHost(
        tester,
        record: const StarPromptRecord(used: Duration(hours: 7, minutes: 50), shows: 1, askedAt: Duration(hours: 2)),
      );
      await bench.settle();
      expect(find.text(_title(7)), findsOneWidget);
    });
  });

  group('only when the person is idle', () {
    /// [make] keeps it away; [lift] (if any) lets it come.
    Future<void> blocked(
      WidgetTester tester,
      Future<void> Function(_Bench bench) make, {
      Future<void> Function(_Bench bench)? lift,
      ValueNotifier<double>? drawer,
    }) async {
      final bench = await _pumpHost(
        tester,
        drawer: drawer,
        record: const StarPromptRecord(used: Duration(minutes: 29)),
      );
      await make(bench);
      await bench.use(const Duration(minutes: 1));
      await bench.settle();
      await bench.use(const Duration(minutes: 5));
      await bench.settle();
      expect(bench.showing, isFalse);
      expect(bench.store.record!.shows, 0);
      if (lift == null) return;
      await lift(bench);
      await bench.settle();
      expect(bench.showing, isTrue, reason: 'once it is quiet again');
    }

    testWidgets('a turn runs in the conversation on screen', (tester) async {
      const busy = PetFocus(host: HostRef.local, sessionId: 's1', activity: PetActivity.working);
      await blocked(
        tester,
        (b) async => b.container.read(petFocusProvider.notifier).report(busy),
        lift: (b) async =>
            b.container.read(petFocusProvider.notifier).report(const PetFocus(host: HostRef.local, sessionId: 's1')),
      );
    });

    testWidgets('an approval or a question waits', (tester) async {
      await blocked(
        tester,
        (b) async => b.container.read(_pending.notifier).put([
          const PetPending(host: HostRef.local, sessionId: 's3', key: 'e1'),
        ]),
        lift: (b) async => b.container.read(_pending.notifier).put(const []),
      );
    });

    testWidgets('a page, sheet or dialog is over the chat', (tester) async {
      await blocked(
        tester,
        (b) async => b.container.read(chatOnScreenProvider.notifier).set(false),
        lift: (b) async => b.container.read(chatOnScreenProvider.notifier).set(true),
      );
    });

    testWidgets('the app is not on screen', (tester) async {
      await blocked(
        tester,
        (b) async => b.container.read(appForegroundProvider.notifier).set(false),
        lift: (b) async => b.container.read(appForegroundProvider.notifier).set(true),
      );
    });

    testWidgets('phone control runs, or ended under two minutes ago', (tester) async {
      await blocked(
        tester,
        (b) async =>
            (b.container.read(phoneTaskSeenProvider.notifier) as FakePhone).put(active: true, lastActive: b.clock.now),
        lift: (b) async {
          (b.container.read(phoneTaskSeenProvider.notifier) as FakePhone).put(active: false, lastActive: b.clock.now);
          await b.settle();
          expect(b.showing, isFalse, reason: 'it just ended');
          await b.use(StarPromptRules.phoneCooldown);
        },
      );
    });

    testWidgets('dictation is on', (tester) async {
      await blocked(
        tester,
        (b) async => b.container.read(voiceInputActiveProvider.notifier).set(true),
        lift: (b) async => b.container.read(voiceInputActiveProvider.notifier).set(false),
      );
    });

    testWidgets('the composer holds a draft', (tester) async {
      await blocked(
        tester,
        (b) async {
          b.container.read(draftStoreProvider.notifier).save('new', '帮我看看', const []);
          await tester.pump(const Duration(milliseconds: 500));
        },
        lift: (b) async {
          b.container.read(draftStoreProvider.notifier).save('new', '', const []);
          await tester.pump(const Duration(milliseconds: 500));
        },
      );
    });

    testWidgets('the keyboard is up', (tester) async {
      await blocked(
        tester,
        (b) async {
          tester.view.viewInsets = const FakeViewPadding(bottom: 300 * 2);
          await tester.pump();
        },
        lift: (b) async {
          tester.view.resetViewInsets();
          // The next look, a minute on.
          await b.use(const Duration(minutes: 1));
        },
      );
    });

    testWidgets('the drawer is open', (tester) async {
      final drawer = ValueNotifier<double>(0.4);
      await blocked(
        tester,
        (b) async {},
        drawer: drawer,
        lift: (b) async {
          drawer.value = 0;
          await b.use(const Duration(minutes: 1));
        },
      );
    });

    testWidgets('another notice came up in this launch: not until the next', (tester) async {
      await blocked(tester, (b) async => b.container.read(launchNoticeShownProvider.notifier).set(true));
    });

    group('first run', () {
      Future<_Bench> pumpGate(WidgetTester tester, {required bool connected}) async {
        usePhoneSurface(tester);
        final bench = _Bench(tester, MemoryStarStore(_due), TestClock());
        await tester.pumpWidget(
          goldenApp(
            home: RootGate(
              home: Scaffold(
                body: Stack(
                  children: [
                    const StarPromptHost(),
                    Center(child: Text(connected ? '对话' : '')),
                  ],
                ),
              ),
            ),
            brightness: Brightness.light,
            overrides: [
              starPromptGateProvider.overrideWithValue(true),
              ...bench.overrides,
              localRuntimeProvider.overrideWith(
                () => FakeRuntime(
                  const LocalRuntimeState(
                    loaded: true,
                    status: RuntimeStatus(phase: RuntimePhase.installed, installedVersion: 'r1', bundledVersion: 'r1'),
                  ),
                ),
              ),
              settingsProvider.overrideWith(
                () => FakeSettings(AppSettings(loaded: true, apiKey: connected ? 'sk-0123456789abcdef' : '')),
              ),
              phoneChannelProvider.overrideWithValue(NoPhone()),
            ],
          ),
        );
        await tester.pump();
        return bench;
      }

      testWidgets('never during it', (tester) async {
        final bench = await pumpGate(tester, connected: false);
        await bench.use(const Duration(minutes: 5));
        await bench.settle();
        expect(bench.showing, isFalse);
        expect(bench.store.record!.shows, 0);
      });

      testWidgets('on the home, after it', (tester) async {
        final bench = await pumpGate(tester, connected: true);
        await bench.settle();
        expect(bench.showing, isTrue);
      });
    });
  });

  group('设置 › 关于 DSH Go', () {
    testWidgets('给 DSH Go 点个 star opens GitHub and ends the prompt', (tester) async {
      usePhoneSurface(tester);
      final bench = _Bench(tester, MemoryStarStore(_due), TestClock());
      await tester.pumpWidget(
        goldenApp(
          home: const AboutPage(),
          brightness: Brightness.light,
          overrides: [
            activeHostProvider.overrideWith(() => FixedActiveHost(HostRef.local)),
            localRuntimeProvider.overrideWith(
              () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
            ),
            settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
            ...bench.overrides,
          ],
        ),
      );
      await tester.pumpAndSettle();
      final row = find.widgetWithText(SettingsTile, '给 DSH Go 点个 star');
      await tester.scrollUntilVisible(row, 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(bench.opened, [_github]);
      final container = ProviderScope.containerOf(tester.element(find.byType(AboutPage)));
      expect(container.read(starPromptProvider).finished, isTrue);
      expect(bench.store.record!.finished, isTrue);
    });
  });

  group('the dialog', () {
    void fits(WidgetTester tester) {
      expect(tester.takeException(), isNull);
      final card = tester.getRect(find.descendant(of: _dialog, matching: find.byType(Material)).first);
      for (final paragraph in tester.renderObjectList<RenderParagraph>(
        find.descendant(of: _dialog, matching: find.byType(RichText)),
      )) {
        final text = paragraph.text.toPlainText();
        expect(paragraph.didExceedMaxLines, isFalse, reason: text);
        final box = paragraph.localToGlobal(Offset.zero) & paragraph.size;
        expect(box.left, greaterThanOrEqualTo(card.left), reason: text);
        expect(box.right, lessThanOrEqualTo(card.right + .01), reason: text);
      }
    }

    for (final (height, scale) in [(780.0, 1.0), (780.0, 1.3), (640.0, 1.0), (640.0, 1.3)]) {
      testWidgets('360×$height, ${scale}x text: whole, centred, stacked, nothing cut', (tester) async {
        await _pumpDialog(tester, width: 360, height: height, scale: scale);
        await tester.pumpAndSettle();
        fits(tester);
        final card = tester.getRect(find.descendant(of: _dialog, matching: find.byType(Material)).first);
        expect(card.width, 360 - 48);
        final picture = tester.getRect(_key('star-picture'));
        expect(picture.width, moreOrLessEquals(picture.height, epsilon: 1e-6));
        expect(picture.width, inInclusiveRange(StarPromptDialog.pictureMin, StarPromptDialog.pictureMax));
        if (height == 780) expect(picture.width, StarPromptDialog.pictureMax);
        expect(picture.center.dx, moreOrLessEquals(card.center.dx, epsilon: .5));
        expect(picture.top, greaterThanOrEqualTo(card.top));
        // The words centred, the keys stacked: the star full width on top.
        for (final key in ['star-body', 'star-plea']) {
          expect(tester.widget<Text>(_key(key)).textAlign, TextAlign.center);
        }
        final title = find.descendant(of: _key('star-title'), matching: find.byType(Text));
        expect(tester.widget<Text>(title).textAlign, TextAlign.center);
        expect(tester.getRect(title).center.dx, moreOrLessEquals(card.center.dx, epsilon: .5));
        // Balanced: the last line no stub (「啦~」 alone), at most two lines at ordinary text.
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: title, matching: find.byType(RichText)),
        );
        final widths = <int, (double, double)>{};
        for (final box in paragraph.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: paragraph.text.toPlainText().length),
        )) {
          final (left, right) = widths[box.bottom.round()] ?? (double.infinity, double.negativeInfinity);
          widths[box.bottom.round()] = (left < box.left ? left : box.left, right > box.right ? right : box.right);
        }
        final lines = [for (final (left, right) in widths.values) right - left];
        if (scale == 1) expect(lines, hasLength(2));
        expect(lines.last, greaterThan(lines.first * 0.6), reason: '$lines');
        final go = tester.getRect(_key('star-go'));
        expect(go.left - card.left, moreOrLessEquals(StarPromptDialog.gutter, epsilon: .01));
        expect(card.right - go.right, moreOrLessEquals(StarPromptDialog.gutter, epsilon: .01));
        expect(go.height, greaterThanOrEqualTo(48));
        // The last key reachable (scrolled to on a short screen), below the others.
        await tester.ensureVisible(_key('star-later'));
        await tester.pumpAndSettle();
        final done = tester.getRect(_key('star-done'));
        final later = tester.getRect(_key('star-later'));
        final goNow = tester.getRect(_key('star-go'));
        expect(goNow.bottom, lessThanOrEqualTo(done.top));
        expect(done.bottom, lessThanOrEqualTo(later.top + .01));
        expect(later.bottom, lessThanOrEqualTo(card.bottom + .01));
        expect(later.height, greaterThanOrEqualTo(44));
      });
    }

    testWidgets('a tablet keeps a phone’s dialog', (tester) async {
      await _pumpDialog(tester, width: 800, height: 1280);
      await tester.pumpAndSettle();
      fits(tester);
      final card = tester.getRect(find.descendant(of: _dialog, matching: find.byType(Material)).first);
      expect(card.width, StarPromptDialog.maxWidth);
      expect(tester.getRect(_key('star-picture')).width, StarPromptDialog.pictureMax);
    });

    testWidgets('English at 360 wide, 1.3x text', (tester) async {
      AppLocale.use(AppLocale.en);
      addTearDown(() => AppLocale.use(AppLocale.zhCN));
      await _pumpDialog(tester, width: 360, height: 780, scale: 1.3, locale: const Locale('en'), hours: 6);
      await tester.pumpAndSettle();
      fits(tester);
      expect(find.text('I’ve kept you company in DSH Go for 6 hours now~'), findsOneWidget);
    });

    testWidgets('animations on: the whale bobs in and comes to rest at full size', (tester) async {
      await _pumpDialog(tester, reduceMotion: false);
      final opacity = find.ancestor(of: _key('star-picture'), matching: find.byType(Opacity)).first;
      final scaled = find.ancestor(of: _key('star-picture'), matching: find.byType(Transform)).first;
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.widget<Opacity>(opacity).opacity, lessThan(1));
      await tester.pump(StarPicture.entrance * 0.6);
      // Past full size for a moment (the bob).
      expect(tester.widget<Transform>(scaled).transform.getMaxScaleOnAxis(), greaterThan(1));
      await tester.pumpAndSettle();
      expect(tester.widget<Opacity>(opacity).opacity, 1);
      expect(tester.widget<Transform>(scaled).transform.getMaxScaleOnAxis(), moreOrLessEquals(1));
    });

    testWidgets('animations off: she is simply there', (tester) async {
      await _pumpDialog(tester);
      await tester.pump();
      expect(find.ancestor(of: _key('star-picture'), matching: find.byType(Opacity)), findsNothing);
      expect(find.descendant(of: _dialog, matching: find.byType(TweenAnimationBuilder<double>)), findsNothing);
    });
  });

  group('goldens', () {
    for (final brightness in Brightness.values) {
      testWidgets('the dialog (${brightness.name})', (tester) async {
        await tester.runAsync(loadTestFonts);
        await _pumpDialog(tester, brightness: brightness);
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/star_prompt_${brightness.name}.png'));
      });
    }
  });
}
