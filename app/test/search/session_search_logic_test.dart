// Matching, ordering and debounce logic of the session search.
//
//   flutter test test/search

import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/session_search.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/shell/session_search_page.dart' show searchDateLabel;
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../plugins/support/fake_plugin_host.dart' show FakePluginCarrier;
import 'support.dart';

List<String> ids(List<SessionSearchResult> results) => [for (final r in results) r.session.sessionId];

void main() {
  group('folding and terms', () {
    test('case and full-width fold without changing offsets', () {
      const text = 'ＡＰＩ Key　登录Ü';
      final folded = foldForSearch(text);
      expect(folded, 'api key 登录ü');
      expect(folded.length, text.length);
      // Surrogate pairs survive untouched.
      expect(foldForSearch('a😀B'), 'a😀b');
    });

    test('terms split on any whitespace, drop repeats', () {
      expect(searchTerms('  登录  Bug\t登录　按钮 '), ['登录', 'bug', '按钮']);
      expect(searchTerms('   '), isEmpty);
      expect(sameSearchQuery('Login  Bug', 'login bug'), isTrue);
      expect(sameSearchQuery('login', 'logi'), isFalse);
    });

    test('match ranges: every occurrence, case-insensitive, overlaps merged', () {
      expect(matchRanges('Login, then LOGIN again', ['login']), [(start: 0, end: 5), (start: 12, end: 17)]);
      expect(matchRanges('修复登录按钮', ['登录', '录按']), [(start: 2, end: 5)]);
      expect(matchRanges('abc', ['x']), isEmpty);
      expect(matchRanges('', ['x']), isEmpty);
    });

    test('folder label is the last path segment', () {
      expect(folderLabel('/home/me/code/dsh-app/'), 'dsh-app');
      expect(folderLabel(r'C:\work\api'), 'api');
      expect(folderLabel('/'), '/');
      expect(folderLabel(null), isNull);
    });
  });

  group('excerpt', () {
    test('keeps a snippet whose match is already near the start', () {
      const text = '用户双击「登录」会发两次请求';
      final ranges = matchRanges(text, ['登录']);
      expect(excerptAround(text, ranges), (text: text, ranges: ranges));
    });

    test('cuts the lead-in so the match shows, shifting the ranges', () {
      final text = '${'前' * 60}跳回「登录」页';
      final out = excerptAround(text, matchRanges(text, ['登录']), lead: 6);
      expect(out.text, '…前前前跳回「登录」页');
      final r = out.ranges.single;
      expect(out.text.substring(r.start, r.end), '登录');
    });

    test('starts on a nearby word boundary in Latin text and never splits a surrogate pair', () {
      const latin = 'lorem ipsum dolor sit amet consectetur the login button';
      final out = excerptAround(latin, matchRanges(latin, ['login']), lead: 10);
      expect(out.text, '…the login button');
      final emoji = '${'😀' * 20}login';
      final cut = excerptAround(emoji, matchRanges(emoji, ['login']), lead: 3);
      expect(cut.text, '…😀😀login');
    });
  });

  group('results', () {
    final sessions = sampleSearchSessions();
    final archived = sampleArchivedSessions();

    test('title matches newest first, every term must match in any order', () {
      final r = deriveSessionSearchResults(query: '登录', sessions: sessions);
      expect(ids(r.active), ['s1', 's2']);
      expect(r.active.every((x) => x.byTitle && x.snippet == null), isTrue);
      expect(ids(deriveSessionSearchResults(query: '按钮 登录', sessions: sessions).active), ['s1']);
      expect(ids(deriveSessionSearchResults(query: 'TOKEN retrofit', sessions: sessions).active), ['s4']);
      expect(deriveSessionSearchResults(query: '登录 深色', sessions: sessions).isEmpty, isTrue);
      expect(deriveSessionSearchResults(query: '  ', sessions: sessions).isEmpty, isTrue);
    });

    test('ordering ignores input order and breaks ties by id', () {
      final at = DateTime(2026, 10, 1);
      final shuffled = [
        searchSession('b', '登录 B', at),
        searchSession('c', '登录 C', DateTime(2026, 10, 2)),
        searchSession('a', '登录 A', at),
      ];
      expect(ids(deriveSessionSearchResults(query: '登录', sessions: shuffled).active), ['c', 'a', 'b']);
    });

    test('untitled sessions never match their placeholder title', () {
      final r = deriveSessionSearchResults(query: '未命名', sessions: [searchSession('x', null, DateTime(2026))]);
      expect(r.isEmpty, isTrue);
    });

    test('content hits: title matches keep their place and gain the excerpt, the rest follow in Host order', () {
      final r = deriveSessionSearchResults(
        query: '登录',
        sessions: sessions,
        archived: archived,
        contentQuery: '登录',
        hits: loginHits,
      );
      expect(ids(r.active), ['s1', 's2', 's4']);
      expect(r.active[0].snippet, startsWith('用户双击'));
      expect(r.active[1].snippet, isNull);
      expect(r.active[2].byTitle, isFalse);
      expect(ids(r.archived), ['a1']);
      expect(r.archived.single.archived, isTrue);
      expect(r.length, 4);
    });

    test('hits for another query, or for sessions not listed, are ignored', () {
      final stale = deriveSessionSearchResults(query: '登录页', sessions: sessions, contentQuery: '登录', hits: loginHits);
      expect(ids(stale.active), ['s2']);
      expect(stale.active.single.snippet, isNull);
      final spaced = deriveSessionSearchResults(query: '登录 ', sessions: sessions, contentQuery: '登录', hits: loginHits);
      expect(ids(spaced.active), ['s1', 's2', 's4']);
      expect(ids(spaced.active), isNot(contains('sub')));
    });

    test('an archived hit is listed with the archived ones', () {
      final r = deriveSessionSearchResults(
        query: '迁移',
        sessions: sessions,
        archived: archived,
        contentQuery: '迁移',
        hits: const [(sessionId: 'a1', snippet: '接口迁移')],
      );
      expect(r.active, isEmpty);
      expect(ids(r.archived), ['a1']);
    });

    test('the folder matches only when the sessions span several folders', () {
      final one = deriveSessionSearchResults(query: 'workspace', sessions: sessions);
      expect(one.isEmpty, isTrue);
      expect(one.showFolders, isFalse);
      final mixed = [
        searchSession('p1', '修复登录', DateTime(2026, 10, 2), cwd: '/home/me/dsh-app'),
        searchSession('p2', '改 README', DateTime(2026, 10, 1), cwd: '/home/me/blog'),
      ];
      final r = deriveSessionSearchResults(query: 'dsh-app', sessions: mixed);
      expect(ids(r.active), ['p1']);
      expect(r.showFolders, isTrue);
      expect(ids(deriveSessionSearchResults(query: 'blog readme', sessions: mixed).active), ['p2']);
    });
  });

  group('view', () {
    final sessions = sampleSearchSessions();

    test('a composition that matches nothing falls back to the committed text', () {
      const pinyin = SessionSearchState(text: '登录deng', committed: '登录', composing: true);
      final view = buildSessionSearchView(pinyin, sessions: sessions);
      expect(view.query, '登录');
      expect(ids(view.results.active), ['s1', 's2']);
      // Nothing committed yet: the idle page, not "no match".
      const fresh = SessionSearchState(text: 'xiu', committed: '', composing: true);
      expect(buildSessionSearchView(fresh, sessions: sessions).query, isEmpty);
    });

    test('a composed Latin word that matches is used as is', () {
      const word = SessionSearchState(text: 'Retro', committed: '', composing: true);
      final view = buildSessionSearchView(word, sessions: sessions);
      expect(view.query, 'Retro');
      expect(ids(view.results.active), ['s4']);
      expect(view.content, ContentSearchStatus.idle);
    });

    test('content status follows the query it belongs to', () {
      const typedPast = SessionSearchState(
        text: '登录页',
        committed: '登录页',
        contentQuery: '登录',
        content: ContentSearchStatus.ready,
        hits: loginHits,
        hasMore: true,
      );
      final view = buildSessionSearchView(typedPast, sessions: sessions);
      expect(view.content, ContentSearchStatus.pending);
      expect(view.hasMore, isFalse);
      const unsupported = SessionSearchState(
        text: '登录页',
        committed: '登录页',
        contentQuery: '登录',
        content: ContentSearchStatus.unsupported,
      );
      expect(buildSessionSearchView(unsupported, sessions: sessions).content, ContentSearchStatus.unsupported);
    });
  });

  group('controller', () {
    final sessionsOverride = sessionsProvider.overrideWith(
      () => SearchSessions(sampleSearchSessions(), sampleArchivedSessions()),
    );

    ProviderContainer containerWith(FakeContentSearch? backend) {
      final container = ProviderContainer(
        overrides: [sessionContentSearchProvider.overrideWithValue(backend), sessionsOverride],
      );
      addTearDown(container.dispose);
      container.listen(sessionSearchProvider, (_, _) {});
      container.listen(sessionsProvider, (_, _) {});
      container.listen(sessionSearchViewProvider, (_, _) {});
      return container;
    }

    void type(ProviderContainer c, String text, {TextRange composing = TextRange.empty}) => c
        .read(sessionSearchProvider.notifier)
        .setInput(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
            composing: composing,
          ),
        );

    void replaceBackend(ProviderContainer c, FakeContentSearch? backend) {
      c.updateOverrides([sessionContentSearchProvider.overrideWithValue(backend), sessionsOverride]);
    }

    testWidgets('a connection becoming available searches the current offline query', (tester) async {
      final c = containerWith(null);
      final controller = c.read(sessionSearchProvider.notifier);
      type(c, '登录');
      await tester.pump(SessionSearchController.debounce);
      expect(c.read(sessionSearchProvider).content, ContentSearchStatus.idle);
      final backend = FakeContentSearch(results: {'登录': (items: loginHits, hasMore: true)});
      replaceBackend(c, backend);
      await tester.pump();
      expect(c.read(sessionSearchProvider.notifier), same(controller));
      expect(c.read(sessionSearchProvider).text, '登录');
      await tester.pump(SessionSearchController.debounce);
      expect(backend.calls, ['登录']);
      expect(c.read(sessionSearchProvider).hits, loginHits);
      await tester.pump(Duration.zero); // Riverpod's own refresh tick.
    });

    for (final refused in [false, true]) {
      testWidgets('a retired backend ${refused ? "refusal" : "answer"} cannot publish into the new connection', (
        tester,
      ) async {
        final old = FakeContentSearch(
          results: {'登录': (items: loginHits, hasMore: true)},
          error: refused ? searchDisabled : null,
        )..gate = Completer<void>();
        final current = FakeContentSearch()..gate = Completer<void>();
        final c = containerWith(old);
        addTearDown(() {
          for (final backend in [old, current]) {
            if (!backend.gate!.isCompleted) backend.gate!.complete();
          }
        });
        type(c, '登录');
        await tester.pump(SessionSearchController.debounce);
        expect(old.calls, ['登录']);
        replaceBackend(c, current);
        await tester.pump();
        await tester.pump(SessionSearchController.debounce);
        old.gate!.complete();
        await tester.pump();
        expect(c.read(sessionSearchProvider).content, ContentSearchStatus.pending);
        expect(c.read(sessionSearchProvider).hits, isEmpty);
        expect(c.read(sessionSearchProvider).hasMore, isFalse);
        expect(current.calls, ['登录']);
        current.gate!.complete();
        await tester.pump();
        expect(c.read(sessionSearchProvider).content, ContentSearchStatus.ready);
        expect(c.read(sessionSearchProvider).hits, isEmpty);
        expect(current.knownUnsupported, isFalse);
        await tester.pump(Duration.zero); // Riverpod's own refresh tick.
      });
    }

    testWidgets('the same backend notification preserves its one pending query', (tester) async {
      final backend = FakeContentSearch(results: {'登录': (items: loginHits, hasMore: false)})..gate = Completer<void>();
      final c = containerWith(backend);
      addTearDown(() {
        if (!backend.gate!.isCompleted) backend.gate!.complete();
      });
      type(c, '登录');
      await tester.pump(SessionSearchController.debounce);
      replaceBackend(c, backend);
      await tester.pump();
      replaceBackend(c, backend);
      await tester.pump(SessionSearchController.debounce);
      expect(backend.calls, ['登录']);
      backend.gate!.complete();
      await tester.pump();
      expect(c.read(sessionSearchProvider).hits, loginHits);
      await tester.pump(Duration.zero); // Riverpod's own refresh tick.
    });

    testWidgets('a connection change preserves unfinished IME text without searching it', (tester) async {
      final old = FakeContentSearch(results: {'登录': (items: loginHits, hasMore: true)})..gate = Completer<void>();
      final c = containerWith(old);
      addTearDown(() {
        if (!old.gate!.isCompleted) old.gate!.complete();
      });
      type(c, '登录');
      await tester.pump(SessionSearchController.debounce);
      type(c, 'denglu', composing: const TextRange(start: 0, end: 6));
      final backend = FakeContentSearch();
      replaceBackend(c, backend);
      await tester.pump();
      await tester.pump(SessionSearchController.debounce);
      expect(c.read(sessionSearchProvider).text, 'denglu');
      expect(c.read(sessionSearchProvider).composing, isTrue);
      expect(backend.calls, isEmpty);
      old.gate!.complete();
      await tester.pump();
      expect(c.read(sessionSearchProvider).content, ContentSearchStatus.idle);
      expect(c.read(sessionSearchProvider).hits, isEmpty);
      type(c, '登录');
      await tester.pump(SessionSearchController.debounce);
      expect(backend.calls, ['登录']);
      await tester.pump(Duration.zero); // Riverpod's own refresh tick.
    });

    testWidgets('a backend change restarts the ordinary debounce without sending early', (tester) async {
      final old = FakeContentSearch();
      final current = FakeContentSearch();
      final c = containerWith(old);
      type(c, '登录');
      await tester.pump(const Duration(milliseconds: 100));
      replaceBackend(c, current);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 249));
      expect(old.calls, isEmpty);
      expect(current.calls, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(current.calls, ['登录']);
      await tester.pump(Duration.zero);
    });

    testWidgets('connection metadata changes keep the same client backend and pending RPC', (tester) async {
      final response = Completer<Object?>();
      final carrier = FakePluginCarrier()..handlers['session/search'] = (_) => response.future;
      final client = DshClient.withCarrier(carrier);
      addTearDown(client.close);
      addTearDown(() {
        if (!response.isCompleted) response.complete({'items': [], 'hasMore': false});
      });
      HostConnection connection(String name) => HostConnection(client: client, isLocal: true, name: name);
      final c = ProviderContainer(
        overrides: [activeConnectionProvider.overrideWithValue(AsyncData(connection('first'))), sessionsOverride],
      );
      addTearDown(c.dispose);
      c.listen(sessionSearchProvider, (_, _) {});
      type(c, '登录');
      await tester.pump(SessionSearchController.debounce);
      expect(carrier.argsOf('session/search'), hasLength(1));
      c.updateOverrides([
        activeConnectionProvider.overrideWithValue(AsyncData(connection('renamed'))),
        sessionsOverride,
      ]);
      expect(c.read(activeConnectionProvider).value!.name, 'renamed');
      await tester.pump(SessionSearchController.debounce);
      expect(carrier.argsOf('session/search'), hasLength(1));
      response.complete({
        'items': [
          {'sessionId': 's1', 'snippet': '登录'},
        ],
        'hasMore': false,
      });
      await tester.pump();
      expect(c.read(sessionSearchProvider).content, ContentSearchStatus.ready);
      expect(c.read(sessionSearchProvider).hits.single.sessionId, 's1');
      await tester.pump(Duration.zero);
    });

    testWidgets('a new client immediately followed by input sends only one debounced RPC', (tester) async {
      final oldCarrier = FakePluginCarrier()..handlers['session/search'] = (_) => {'items': []};
      final currentCarrier = FakePluginCarrier()..handlers['session/search'] = (_) => {'items': []};
      final oldClient = DshClient.withCarrier(oldCarrier);
      final currentClient = DshClient.withCarrier(currentCarrier);
      addTearDown(oldClient.close);
      addTearDown(currentClient.close);
      final c = ProviderContainer(
        overrides: [
          activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: oldClient, isLocal: true))),
          sessionsOverride,
        ],
      );
      addTearDown(c.dispose);
      c.listen(sessionSearchProvider, (_, _) {});
      type(c, 'old');
      c.updateOverrides([
        activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: currentClient, isLocal: true))),
        sessionsOverride,
      ]);
      // Do not pump/read the backend between the connection update and input.
      type(c, 'new');
      await tester.pump(const Duration(milliseconds: 249));
      expect(oldCarrier.argsOf('session/search'), isEmpty);
      expect(currentCarrier.argsOf('session/search'), isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(oldCarrier.argsOf('session/search'), isEmpty);
      expect(currentCarrier.argsOf('session/search'), hasLength(1));
      expect(currentCarrier.argsOf('session/search').single['request'], {'query': 'new'});
      await tester.pump(Duration.zero);
    });

    testWidgets('waits for a pause and only asks for the last query', (tester) async {
      final backend = FakeContentSearch(results: {'登录': (items: loginHits, hasMore: true)});
      final c = containerWith(backend);
      type(c, '登');
      await tester.pump(const Duration(milliseconds: 100));
      type(c, '登录');
      expect(c.read(sessionSearchProvider).content, ContentSearchStatus.pending);
      await tester.pump(const Duration(milliseconds: 249));
      expect(backend.calls, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(backend.calls, ['登录']);
      final state = c.read(sessionSearchProvider);
      expect(state.content, ContentSearchStatus.ready);
      expect(state.hasMore, isTrue);
      final view = c.read(sessionSearchViewProvider);
      expect(ids(view.results.active), ['s1', 's2', 's4']);
      expect(ids(view.results.archived), ['a1']);
      expect(view.hasMore, isTrue);
      // A trailing space or a cursor move is the same search: no new request.
      type(c, '登录 ');
      await tester.pump(const Duration(milliseconds: 300));
      expect(backend.calls, ['登录']);
    });

    testWidgets('an IME composition never reaches the Host', (tester) async {
      final backend = FakeContentSearch();
      final c = containerWith(backend);
      type(c, 'denglu', composing: const TextRange(start: 0, end: 6));
      await tester.pump(const Duration(milliseconds: 400));
      expect(backend.calls, isEmpty);
      expect(c.read(sessionSearchViewProvider).query, isEmpty);
      // Committed: 登录 replaces the pinyin.
      type(c, '登录');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(backend.calls, ['登录']);
      // Composing after committed text: the committed part keeps its results.
      type(c, '登录an', composing: const TextRange(start: 2, end: 4));
      await tester.pump(const Duration(milliseconds: 400));
      expect(backend.calls, ['登录']);
      expect(c.read(sessionSearchViewProvider).query, '登录');
    });

    testWidgets('a late answer for an older query is dropped', (tester) async {
      final backend = FakeContentSearch(
        results: {'登录': (items: loginHits, hasMore: false), '深色': (items: const [], hasMore: false)},
        delay: const Duration(milliseconds: 500),
      );
      final c = containerWith(backend);
      type(c, '登录');
      await tester.pump(const Duration(milliseconds: 260)); // request for 登录 in flight
      type(c, '深色');
      await tester.pump(const Duration(milliseconds: 600)); // 登录 answered at 750 ms; 深色 still in flight
      expect(backend.calls, ['登录', '深色']);
      expect(c.read(sessionSearchProvider).contentQuery, '深色');
      expect(c.read(sessionSearchProvider).content, ContentSearchStatus.pending);
      expect(c.read(sessionSearchProvider).hits, isEmpty);
      await tester.pump(const Duration(milliseconds: 200));
      expect(backend.calls, ['登录', '深色']);
      expect(c.read(sessionSearchProvider).content, ContentSearchStatus.ready);
      expect(ids(c.read(sessionSearchViewProvider).results.active), ['s3']);
    });

    testWidgets('a host without a content index is asked once, then titles only', (tester) async {
      final backend = FakeContentSearch(error: searchDisabled);
      final c = containerWith(backend);
      type(c, '登录');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(c.read(sessionSearchProvider).content, ContentSearchStatus.unsupported);
      type(c, '深色');
      await tester.pump(const Duration(milliseconds: 300));
      expect(backend.calls, ['登录']);
      final view = c.read(sessionSearchViewProvider);
      expect(view.content, ContentSearchStatus.unsupported);
      expect(ids(view.results.active), ['s3']);
    });

    testWidgets('a failure offers a retry that goes out at once', (tester) async {
      final backend = FakeContentSearch(error: const DshTransportException('socket closed'));
      final c = containerWith(backend);
      type(c, '登录');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(c.read(sessionSearchProvider).content, ContentSearchStatus.failed);
      // Titles still match.
      expect(ids(c.read(sessionSearchViewProvider).results.active), ['s1', 's2']);
      backend.error = null;
      c.read(sessionSearchProvider.notifier).retry();
      await tester.pump();
      await tester.pump();
      expect(backend.calls, ['登录', '登录']);
      expect(c.read(sessionSearchProvider).content, ContentSearchStatus.ready);
      await tester.pump(Duration.zero); // Riverpod's own refresh tick
    });

    testWidgets('a Host that never answers times out into a failure', (tester) async {
      final backend = FakeContentSearch()..gate = Completer<void>();
      final c = containerWith(backend);
      type(c, '登录');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(SessionSearchController.timeout);
      expect(c.read(sessionSearchProvider).content, ContentSearchStatus.failed);
      backend.gate!.complete();
      await tester.pump();
      expect(c.read(sessionSearchProvider).content, ContentSearchStatus.failed);
    });

    testWidgets('clearing the field drops content results; no connection means titles only', (tester) async {
      final backend = FakeContentSearch(results: {'登录': (items: loginHits, hasMore: false)});
      final c = containerWith(backend);
      type(c, '登录');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      type(c, '');
      final state = c.read(sessionSearchProvider);
      expect(state.content, ContentSearchStatus.idle);
      expect(state.hits, isEmpty);
      expect(c.read(sessionSearchViewProvider).query, isEmpty);

      final offline = containerWith(null);
      type(offline, '登录');
      await tester.pump(const Duration(milliseconds: 300));
      expect(offline.read(sessionSearchProvider).content, ContentSearchStatus.idle);
      expect(ids(offline.read(sessionSearchViewProvider).results.active), ['s1', 's2']);
    });
  });

  test('which errors mean "no content search here"', () {
    expect(isContentSearchUnsupported(searchDisabled), isTrue);
    expect(
      isContentSearchUnsupported(
        const DshRemoteException(
          'gateway/internal',
          'session search is unavailable: this deployment does not mount @deepseek-ai/dsh-session-query',
        ),
      ),
      isTrue,
    );
    expect(isContentSearchUnsupported(const DshRemoteException('gateway/method-unavailable', 'x')), isTrue);
    expect(
      isContentSearchUnsupported(
        const DshRemoteException('gateway/internal', 'session search failed: SESSION_QUERY_INDEX_FAILED'),
      ),
      isFalse,
    );
    expect(isContentSearchUnsupported(const DshTransportException('timeout')), isFalse);
    expect(isContentSearchUnsupported(StateError('x')), isFalse);
  });

  test('date labels', () {
    expect(searchDateLabel(DateTime(2026, 10, 24, 9, 5), searchNow), '09:05');
    expect(searchDateLabel(DateTime(2026, 10, 23, 23, 59), searchNow), '昨天');
    expect(searchDateLabel(DateTime(2026, 10, 3), searchNow), '10月3日');
    expect(searchDateLabel(DateTime(2025, 12, 30), searchNow), '2025/12/30');
  });

  group('user-message and turn-outline corpus search', () {
    test('extracts full first prompt, turn outline and human inbox while ignoring nested strings', () {
      const checkpointJson = r'''
{
  "version": 7,
  "record": {
    "identity": {"formatVersion": 4, "createdAt": 1700000000000},
    "rows": {
      "contextTimeline": {
        "ver": 1,
        "seq": 20,
        "val": {"note": "string containing \"turnOutline\": {\"val\": {\"turns\": []}}"}
      },
      "titleInput": {
        "ver": 3,
        "seq": 20,
        "val": {
          "first": {
            "seq": 4,
            "text": "帮我排查一下为什么正常模式启动会卡死在健康检查阶段，并且切换安全模式又能恢复"
          },
          "count": 2,
          "lastSeq": 15
        }
      },
      "turnOutline": {
        "ver": 2,
        "seq": 20,
        "val": {
          "turns": [
            {
              "turn": 1,
              "seq": 4,
              "prompt": "帮我排查一下为什么正常模式启动会卡死在…",
              "response": "已定位到 PID 残留导致的门禁死锁。"
            },
            {
              "turn": 2,
              "seq": 14,
              "prompt": "顺便加上回归测试",
              "response": "已补充启动探针测试。"
            }
          ],
          "draft": ""
        }
      },
      "inbox": {
        "ver": 1,
        "seq": 20,
        "val": {
          "next-turn": [
            {
              "id": "m1",
              "role": "user",
              "source": {"kind": "user"},
              "content": [{"type": "text", "text": "排队中的追问消息"}]
            },
            {
              "id": "m2",
              "role": "user",
              "source": {"kind": "runtime-context"},
              "content": [{"type": "text", "text": "系统注入的上下文不应被当成用户提问"}]
            }
          ],
          "next-step": []
        }
      }
    }
  }
}
''';
      final corpus = extractCheckpointJsonSearchCorpus(checkpointJson);
      expect(corpus.userMessages, ['排队中的追问消息', '顺便加上回归测试', '帮我排查一下为什么正常模式启动会卡死在健康检查阶段，并且切换安全模式又能恢复']);
      expect(corpus.assistantPreviews, ['已补充启动探针测试。', '已定位到 PID 残留导致的门禁死锁。']);
    });

    test('matches CJK substrings, multi-turn user terms, and ranks user messages above reply previews', () {
      final s1 = searchSession('s1', '日常杂谈 A', DateTime(2026, 10, 20));
      final s2 = searchSession('s2', '日常杂谈 B', DateTime(2026, 10, 22));
      final s3 = searchSession('s3', '日常杂谈 C', DateTime(2026, 10, 24));
      final corpus = <String, SessionSearchCorpusEntry>{
        // s1: single user message has both terms (tier 0)
        's1': const SessionSearchCorpusEntry(userMessages: ['我想用 Shizuku 调用安卓 Shell 自动化命令']),
        // s2: terms split across two user messages in the same session (tier 1)
        's2': const SessionSearchCorpusEntry(userMessages: ['能不能接上 Shizuku', '再跑一条 Shell 命令']),
        // s3: only the assistant preview has the terms (tier 2)
        's3': const SessionSearchCorpusEntry(
          userMessages: ['帮我看看怎么改'],
          assistantPreviews: ['可以通过 Shizuku 执行 Shell 脚本。'],
        ),
      };
      final page = searchSessionCorpus('shizuku shell', [s3, s2, s1], corpus);
      expect(page.items.map((h) => h.sessionId), ['s1', 's2', 's3']);
      expect(page.items.first.snippet, contains('Shizuku'));
      expect(page.hasMore, isFalse);
    });

    testWidgets('HostContentSearch falls back to user corpus when Host SQLite index is disabled', (tester) async {
      var rpcCalls = 0;
      final carrier = FakePluginCarrier()
        ..handlers['session/search'] = (_) {
          rpcCalls++;
          throw searchDisabled;
        };
      final client = DshClient.withCarrier(carrier);
      addTearDown(client.close);

      final hostSearch = HostContentSearch(
        client,
        fallbackSearch: (query) async =>
            (items: <ContentHit>[(sessionId: 's4', snippet: '用户提问里包含 $query 的完整句子')], hasMore: false),
      );

      final first = await hostSearch.search('健康检查');
      expect(rpcCalls, 1);
      expect(first.items.single.sessionId, 's4');
      expect(hostSearch.knownUnsupported, isFalse);

      // Subsequent searches skip the disabled RPC and use the fallback directly.
      final second = await hostSearch.search('启动卡死');
      expect(rpcCalls, 1);
      expect(second.items.single.snippet, contains('启动卡死'));
    });
  });
}
