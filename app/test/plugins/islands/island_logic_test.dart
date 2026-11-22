// The islands' pure parts: the bridge's message parsing (untrusted input),
// recipes and navigation targets, the memory policy, the security gate, the
// navigation fence and the theme tokens.

import 'dart:io';

import 'package:dsh_app/plugins/seams/seat_models.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/plugins/islands/islands.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

IslandSpec _spec(String slot, {String? cell, IslandForm form = IslandForm.page, String? session, String? package}) =>
    IslandSpec(host: HostRef.local, form: form, slot: slot, cell: cell, sessionId: session, package: package);

void main() {
  group('messages', () {
    test('ready, size, hit, link, session', () {
      final ready = parseIslandMessage(
        '{"t":"ready","slot":"settings.section","cell":"pet","release":"0.2.1-rc.2","found":2}',
      );
      expect(ready, isA<IslandReady>().having((m) => m.found, 'found', 2).having((m) => m.cell, 'cell', 'pet'));
      expect(parseIslandMessage('{"t":"size","h":212.5}'), isA<IslandSize>().having((m) => m.height, 'h', 212.5));
      final hit = parseIslandMessage('{"t":"hit","rects":[[10,20,30,40],[0,0,0,5]],"dpr":2.6}') as IslandHit;
      expect(hit.rects, [const Rect.fromLTWH(10, 20, 30, 40)]); // empty boxes dropped
      expect(parseIslandMessage('{"t":"link","url":"https://example.com/a"}'), isA<IslandLink>());
      expect(parseIslandMessage('{"t":"session","id":"session-1a2b"}'), isA<IslandOpenSession>());
    });

    test('failures map to their codes', () {
      IslandFailure? f(String raw) => (parseIslandMessage(raw) as IslandGaveUp?)?.failure;
      expect(f('{"t":"empty","slot":"x","code":"slot-missing"}'), IslandFailure.slotMissing);
      expect(f('{"t":"empty","slot":"x","code":"empty"}'), IslandFailure.empty);
      expect(f('{"t":"error","slot":"x","code":"boot"}'), IslandFailure.boot);
      expect(f('{"t":"error","slot":"x","code":"whatever"}'), IslandFailure.crash);
    });

    test('untrusted input is dropped, not trusted', () {
      for (final raw in [
        'not json',
        '[]',
        '{"t":"nope"}',
        '{"t":"size","h":-1}',
        '{"t":"size","h":"10"}',
        '{"t":"link","url":"http://example.com"}', // https only
        '{"t":"link","url":"javascript:alert(1)"}',
        '{"t":"link","url":"https://user:pw@example.com"}',
        '{"t":"session","id":"../../etc"}',
        '{"t":"hit","rects":[[1,2,3]]}',
        '{"t":"hit","rects":${List.filled(17, [0, 0, 1, 1])}}', // > 16 regions
        '{"t":"ready","pad":"${'x' * (17 * 1024)}"}', // > 16 KiB
      ]) {
        expect(parseIslandMessage(raw), isNull, reason: raw);
      }
      final huge = parseIslandMessage('{"t":"size","h":1e12}') as IslandSize;
      expect(huge.height, IslandMessageLimits.maxExtent);
    });
  });

  group('recipes', () {
    final book = IslandRecipeBook.parse(File('assets/islands/recipes.json').readAsStringSync());

    test('the shipped book reads', () {
      expect(book.release, '0.2.2-rc.1');
      expect(book.officialSettings, containsAll(['general', 'models']));
      expect(book.recipeFor('settings.section')!.stretch, IslandStretch.scroller);
      expect(book.recipeFor('main')!.stretch, IslandStretch.child);
      expect(book.recipeFor('conversation.input.dock')!.forms, {IslandForm.panel});
      expect(book.recipeFor('shell.overlay')!.forms, {IslandForm.overlay});
      expect(book.labels['pluginsBack'], contains('返回插件'));
    });

    test('settings: official ids directly, third-party by label', () {
      expect(book.targetFor(_spec('settings.section', cell: 'models')), {
        'web': {'settings': 'models'},
      });
      expect(book.targetFor(_spec('settings.section', cell: 'pet')), isNull, reason: 'nothing to find it by');
      expect(book.targetFor(_spec('settings.section', cell: 'pet'), labels: ['桌宠配置', ' ']), {
        'web': {'settings': true},
        'then': {
          'settings': ['桌宠配置'],
        },
      });
      expect(book.targetFor(_spec('settings.section', cell: 'pet'), labels: ['Desktop\n  pet', '\t']), {
        'web': {'settings': true},
        'then': {
          'settings': ['Desktop pet'],
        },
      });
    });

    test('plugin pages by package (and row)', () {
      expect(book.targetFor(_spec('plugins.bundle.config', cell: 'dsh-pet')), {
        'web': {'panel': 'plugins'},
        'then': {'plugin': 'dsh-pet'},
      });
      expect(book.targetFor(_spec('plugins.row.config', cell: '@a/b#voice')), {
        'web': {'panel': 'plugins'},
        'then': {'plugin': '@a/b', 'row': 'voice'},
      });
      expect(book.targetFor(_spec('plugins.row.config', cell: 'no-row')), isNull);
    });

    test('long-tail pages require package and cell and navigate their real owner', () {
      const slots = ['sidebar.footer.action', 'settings.plugins.tab', 'plugins.detail.section'];
      for (final slot in slots) {
        expect(book.recipeFor(slot)!.forms, {IslandForm.page});
        expect(book.targetFor(_spec(slot, cell: 'entry')), isNull);
        expect(book.targetFor(_spec(slot, package: 'one')), isNull);
      }
      expect(book.targetFor(_spec(slots[0], cell: 'entry', package: 'one')), {
        'web': {'sidebar': true},
        'then': {'sidebar': true},
      });
      expect(book.targetFor(_spec(slots[1], cell: 'entry', package: 'one')), {
        'web': {'settings': 'plugins'},
        'then': {'settingsPlugin': 'entry'},
      });
      expect(book.targetFor(_spec(slots[2], cell: 'entry', package: 'one')), {
        'web': {'panel': 'plugins'},
        'then': {'plugin': 'one'},
      });
    });

    test('conversation slots need a conversation', () {
      expect(book.targetFor(_spec('sidebar.right.pane.tab', cell: 'files')), isNull);
      expect(book.targetFor(_spec('sidebar.right.pane.tab', cell: 'files', session: 's1')), {
        'session': 's1',
        'web': {'rightbar': 'files'},
      });
      expect(
        book.targetFor(
          _spec('sidebar.right.pane.tab', cell: 'pet-chat', session: 's1'),
          labels: ['宠物'],
        ),
        {
          'session': 's1',
          'then': {
            'rightbar': ['宠物'],
          },
        },
      );
      expect(book.targetFor(_spec('sidebar.right.pane.tab', cell: 'pet-chat', session: 's1')), {
        'session': 's1',
        'then': {'rightbar': <String>[]},
      }, reason: 'the bridge opens it by id');
      expect(book.targetFor(_spec('conversation.input.dock', form: IslandForm.panel, session: 's1')), {
        'session': 's1',
      });
    });

    test('a form the slot does not take, or no recipe: no island', () {
      expect(book.targetFor(_spec('conversation.input.dock', session: 's1')), isNull); // page
      expect(book.targetFor(_spec('conversation.chat.turnTail', session: 's1')), isNull);
      expect(book.supports(_spec('anything', form: IslandForm.probe)), isTrue);
    });

    test('a broken book degrades to no recipes', () {
      expect(IslandRecipeBook.parse('{').slots, isEmpty);
      expect(IslandRecipeBook.parse('{"slots":{"x":{"forms":["nope"],"open":"none"}}}').slots, isEmpty);
    });
  });

  group('budget', () {
    const gb = 1 << 30;
    test('memory classes', () {
      expect(maxLiveIslands(const IslandDevice(totalMem: 0)), 1);
      expect(maxLiveIslands(const IslandDevice(totalMem: 4 * gb)), 1);
      expect(maxLiveIslands(IslandDevice(totalMem: (5.6 * gb).round())), 2, reason: 'a "6 GB" phone');
      expect(maxLiveIslands(IslandDevice(totalMem: (7.4 * gb).round())), 2);
      expect(maxLiveIslands(IslandDevice(totalMem: (11.2 * gb).round())), 3);
      expect(maxLiveIslands(const IslandDevice(totalMem: 16 * gb, lowRam: true)), 1);
      expect(maxLiveIslands(const IslandDevice(totalMem: 16 * gb), islandMb: 160), 1, reason: 'heavy islands');
    });

    final t0 = DateTime(2026);
    LiveIsland live(String key, IslandForm form, {bool visible = true, int age = 0}) => LiveIsland(
      key: key,
      form: form,
      visible: visible,
      lastSeen: t0.add(Duration(seconds: age)),
    );

    test('evicts overlays and probes first, then the least recently seen', () {
      expect(evictionsFor(IslandForm.page, [], 1), isEmpty);
      expect(evictionsFor(IslandForm.page, [live('a', IslandForm.page)], 1), isNull, reason: 'on screen');
      expect(evictionsFor(IslandForm.page, [live('a', IslandForm.page)], 1, key: 'a'), isEmpty, reason: 'already live');
      expect(evictionsFor(IslandForm.page, [live('o', IslandForm.overlay)], 1), ['o']);
      expect(
        evictionsFor(IslandForm.page, [
          live('old', IslandForm.page, visible: false, age: 1),
          live('new', IslandForm.page, visible: false, age: 9),
          live('p', IslandForm.probe),
        ], 2),
        ['p', 'old'],
      );
      expect(evictionsFor(IslandForm.overlay, [live('o', IslandForm.overlay)], 1), isNull);
      expect(evictionsFor(IslandForm.probe, [live('h', IslandForm.page, visible: false)], 1), isNull);
    });

    test('a timeout is forgiven soon, a missing slot only after a while', () {
      expect(IslandBudgetRules.memoryFor(IslandFailure.slotMissing), IslandBudgetRules.failureMemory);
      expect(IslandBudgetRules.memoryFor(IslandFailure.empty), IslandBudgetRules.failureMemory);
      expect(IslandBudgetRules.memoryFor(IslandFailure.timeout), IslandBudgetRules.transientFailureMemory);
      expect(IslandBudgetRules.memoryFor(IslandFailure.load), IslandBudgetRules.transientFailureMemory);
      expect(IslandBudgetRules.memoryFor(IslandFailure.evicted), isNull);
      expect(IslandBudgetRules.memoryFor(IslandFailure.renderer), isNull);
    });

    test('the snapshot answers the planner', () {
      final spec = _spec('settings.section', cell: 'models');
      IslandBudgetSnapshot snap({
        bool supported = true,
        bool lost = false,
        Set<String> failed = const {},
        bool allow = true,
        List<LiveIsland> live = const [],
      }) => IslandBudgetSnapshot(
        supported: supported,
        max: 1,
        live: live,
        rendererLost: lost,
        failed: failed,
        allowHost: (_) => allow,
      );
      expect(snap().canOpen(spec), isTrue);
      expect(snap(supported: false).canOpen(spec), isFalse);
      expect(snap(lost: true).canOpen(spec), isFalse);
      expect(snap(allow: false).canOpen(spec), isFalse);
      expect(snap(failed: {spec.key}).canOpen(spec), isFalse);
      expect(snap(live: [live('other', IslandForm.page)]).canOpen(spec), isFalse);
      expect(
        snap(live: [live(spec.key, IslandForm.page)]).canOpen(spec),
        isTrue,
        reason: 'its own island never blocks it',
      );
      expect(
        const IslandBudgetSnapshot(supported: true, max: 1, live: []).canOpen(spec),
        isFalse,
        reason: 'no gate, no island',
      );
    });
  });

  group('gate', () {
    test('relay never, SSH yes, on-device only with a verified guard', () {
      expect(islandHostAllowed(HostKind.relay, override: true), isFalse);
      expect(islandHostAllowed(HostKind.ssh), isTrue);
      expect(islandHostAllowed(HostKind.local), isFalse);
      expect(islandHostAllowed(HostKind.local, reported: true), isFalse, reason: 'self-report alone');
      expect(islandHostAllowed(HostKind.local, probed: RouteGuard.present), isFalse);
      expect(islandHostAllowed(HostKind.local, reported: true, probed: RouteGuard.absent), isFalse);
      expect(islandHostAllowed(HostKind.local, reported: true, probed: RouteGuard.present), isTrue);
      expect(islandHostAllowed(HostKind.local, override: true), isTrue);
      expect(islandsWithoutGuard, isFalse, reason: 'never on in a normal build');
    });

    test('the probe calls a plugin route without a cookie', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var status = 401;
      final seen = <String>[];
      server.listen((request) {
        seen.add('${request.uri.path} cookie=${request.headers.value('cookie')}');
        request.response.statusCode = status;
        request.response.close();
      });
      final base = Uri.parse('http://127.0.0.1:${server.port}/?token=secret');
      expect(await probeRouteGuard(base), RouteGuard.present);
      status = 403;
      expect(await probeRouteGuard(base), RouteGuard.present);
      status = 200;
      expect(await probeRouteGuard(base), RouteGuard.absent);
      status = 404;
      expect(await probeRouteGuard(base), RouteGuard.unknown);
      await server.close(force: true);
      expect(await probeRouteGuard(base), RouteGuard.unknown, reason: 'nothing listening');
      expect(seen.first, '/dsh-go/v1/inventory cookie=null');
    });

    test('launch URL is the 网页版 one', () {
      expect(islandLaunchUri('http://127.0.0.1:3080', 't0k').toString(), 'http://127.0.0.1:3080/?token=t0k');
    });
  });

  group('navigation', () {
    final base = Uri.parse('http://127.0.0.1:3080/?token=t');
    test('same origin stays, https elsewhere asks, the rest is blocked', () {
      expect(islandNavigation(base, 'http://127.0.0.1:3080/'), IslandNavigation.stay);
      expect(islandNavigation(base, 'http://127.0.0.1:3080/dsh-pet-7340/page'), IslandNavigation.stay);
      expect(islandNavigation(base, 'https://github.com/x'), IslandNavigation.external);
      expect(islandNavigation(base, 'http://example.com'), IslandNavigation.block);
      expect(islandNavigation(base, 'http://127.0.0.1:9999/'), IslandNavigation.block);
      expect(islandNavigation(base, 'intent://scan#Intent;end'), IslandNavigation.block);
      expect(islandNavigation(base, 'file:///sdcard/x'), IslandNavigation.block);
      expect(islandNavigation(base, 'https://a:b@example.com'), IslandNavigation.block);
      expect(islandNavigation(base, 'https://ads.example/frame', isMainFrame: false), IslandNavigation.stay);
    });
  });

  group('theme', () {
    test('css colours', () {
      expect(cssColor(const Color(0xFF112233)), '#112233');
      expect(cssColor(const Color(0x80FFFFFF)), '#ffffff80');
    });

    test('App tokens for both themes, accent on the primary roles', () {
      for (final (theme, dark) in [(buildLightTheme(), false), (buildDarkTheme(accent: AppAccent.dusk), true)]) {
        final island = IslandTheme.fromTheme(theme, textScale: 1.3);
        expect(island.dark, dark);
        expect(island.textZoom, 130);
        expect(island.tokens['--dsw-alias-bg-base'], 'transparent');
        expect(island.tokens['--dsw-alias-brand-primary'], cssColor(theme.colorScheme.primary));
        expect(island.tokens['--dsw-alias-label-primary'], cssColor(theme.colorScheme.onSurface));
        expect(island.tokens['--dsw-alias-state-error-primary'], cssColor(theme.extension<DshColors>()!.danger));
        for (final MapEntry(:key, :value) in island.tokens.entries) {
          expect(key, matches(RegExp(r'^--dsw-alias-[a-z0-9-]+$')));
          expect(value, matches(RegExp(r'^(transparent|#[0-9a-f]{6}([0-9a-f]{2})?)$')), reason: key);
        }
      }
      expect(IslandTheme.fromTheme(buildLightTheme(), textScale: 5).textZoom, 300);
      expect(IslandTheme.fromTheme(buildLightTheme()), IslandTheme.fromTheme(buildLightTheme()));
      expect(IslandTheme.fromTheme(buildLightTheme()) == IslandTheme.fromTheme(buildDarkTheme()), isFalse);
    });
  });
}
