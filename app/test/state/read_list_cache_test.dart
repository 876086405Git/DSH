import 'dart:convert';

import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_app/state/read_list_cache.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ModelCatalog catalog(String title) => ModelCatalog(
  defaultSelection: const ModelSelection(provider: 'p', model: 'm', reasoningEffort: 'high'),
  routableProviders: const ['p'],
  groups: [
    ProviderGroup('p', 'Provider', [
      ModelInfo(
        provider: 'p',
        id: 'm',
        name: title,
        efforts: const [ReasoningEffort('high', 'High', 'think')],
        defaultEffort: 'high',
      ),
    ]),
  ],
  failures: const [(provider: 'p', name: 'p', message: 'SECRET-FAILURE')],
);

void main() {
  late DateTime now;
  late ReadListCache cache;
  final a = ReadListIdentity.of(['host-a', 1]);
  final b = ReadListIdentity.of(['host-b', 1]);
  final client = Object();
  final key = readListKey(a, ReadListKind.models)!;

  setUp(() {
    now = DateTime.utc(2026, 10, 27);
    cache = ReadListCache(now: () => now);
  });
  tearDown(() => cache.close());

  void save(String name, {ReadListIdentity? identity}) {
    final value = cache.stamp(catalog(name), identity ?? a, client);
    expect(cache.put(readListKey(identity ?? a, ReadListKind.models), value, () => CachedModels(value)), isTrue);
  }

  test('every change reaches watchers, not only the first', () async {
    final c = ProviderContainer(overrides: [readListCacheProvider.overrideWithValue(cache)]);
    addTearDown(c.dispose);
    var seen = 0;
    c.listen(readListCacheChangesProvider, (_, _) => seen++);
    for (var i = 0; i < 3; i++) {
      cache.beginRefresh(ReadListKind.models, a);
      await pumpEventQueue();
    }
    expect(seen, 3);
  });

  test('cache contains only model display fields, not failure messages', () {
    save('Model');
    final entry = cache.get<CachedModels>(key)!;
    expect(entry.value.defaultSelection!.reasoningEffort, 'high');
    expect(entry.value.failures, isEmpty);
    expect(jsonEncode(entry.toJson()), isNot(contains('SECRET')));
  });

  test('client reconstruction retains a same-identity display snapshot', () {
    save('Model');
    final old = cache.get<CachedModels>(key)!;
    expect(cache.current(catalog('untagged live override'), a, Object()), isTrue);
    expect(cache.get<CachedModels>(readListKey(a, ReadListKind.models)), same(old));
  });

  test('host, kind, workspace and identity version do not alias', () {
    save('A');
    expect(cache.get<CachedModels>(readListKey(b, ReadListKind.models)), isNull);
    expect(cache.get<CachedModels>(readListKey(a, ReadListKind.plugins)), isNull);
    expect(cache.get<CachedModels>(readListKey(a, ReadListKind.models, 'workspace')), isNull);
    expect(cache.get<CachedModels>(readListKey(ReadListIdentity.of(['host-a', 2]), ReadListKind.models)), isNull);
  });

  test('unknown identities, untagged values and overlong workspace keys are not admitted', () {
    final raw = catalog('Model');
    expect(cache.put(key, raw, () => CachedModels(raw)), isFalse);
    expect(readListKey(null, ReadListKind.models), isNull);
    expect(readListKey(a, ReadListKind.sessions, 's' * 257), isNull);
    cache.stamp(raw, null, client);
    expect(cache.put(key, raw, () => CachedModels(raw)), isFalse);
    expect(cache.entryCount, 0);
  });

  test('late result cannot be relabelled as another source', () {
    final raw = cache.stamp(catalog('A'), a, client);
    expect(cache.put(readListKey(b, ReadListKind.models), raw, () => CachedModels(raw)), isFalse);
    expect(cache.current(raw, b, client), isFalse);
    expect(cache.current(raw, a, Object()), isFalse);
  });

  test('TTL is measured from successful read and is not renewed by rebuilds', () {
    final raw = cache.stamp(catalog('A'), a, client);
    expect(cache.put(key, raw, () => CachedModels(raw)), isTrue);
    now = now.add(const Duration(minutes: 9));
    expect(cache.put(key, raw, () => CachedModels(raw)), isTrue);
    expect(cache.get<CachedModels>(key), isNotNull);
    now = now.add(const Duration(minutes: 1));
    expect(cache.get<CachedModels>(key), isNull);
    expect(cache.put(key, raw, () => CachedModels(raw)), isFalse);
    expect(cache.encodedBytes, 0);
  });

  test('derived session projections keep original age', () {
    final raw = cache.stamp(<Object>[], a, client);
    now = now.add(const Duration(minutes: 9));
    final derived = cache.derive(catalog('Model'), cache.origin(raw));
    expect(cache.put(key, derived, () => CachedModels(derived)), isTrue);
    now = now.add(const Duration(minutes: 1));
    expect(cache.get<CachedModels>(key), isNull);
  });

  test('optimistic state is never promoted to a successful snapshot', () {
    save('Confirmed');
    final source = cache.stamp(catalog('Before'), a, client);
    final optimistic = cache.derive(catalog('Optimistic'), cache.origin(source), confirmed: false);
    expect(cache.put(key, optimistic, () => CachedModels(optimistic)), isFalse);
    expect(cache.get<CachedModels>(key)!.value.models.single.name, 'Confirmed');
  });

  test('LRU evicts least recently displayed entry', () {
    cache.close();
    cache = ReadListCache(now: () => now, maxEntries: 2);
    save('A');
    save('B', identity: b);
    cache.get<CachedModels>(key);
    final c = ReadListIdentity.of(['host-c']);
    save('C', identity: c);
    expect(cache.entryCount, 2);
    expect(cache.get<CachedModels>(readListKey(b, ReadListKind.models)), isNull);
    expect(cache.get<CachedModels>(key), isNotNull);
  });

  test('aggregate encoded-byte budget evicts whole entries', () {
    final bytes = utf8.encode(jsonEncode(CachedModels(catalog('A')).toJson())).length;
    cache.close();
    cache = ReadListCache(now: () => now, maxBytes: bytes + 5);
    save('A');
    save('B', identity: b);
    expect(cache.entryCount, 1);
    expect(cache.encodedBytes, bytes);
    expect(cache.get<CachedModels>(key), isNull);
  });

  test('entry byte rejection removes older success instead of hiding newer rows', () {
    cache.close();
    cache = ReadListCache(now: () => now, maxEntryBytes: 700);
    save('A');
    final large = cache.stamp(catalog('X' * 500), a, client);
    expect(cache.put(key, large, () => CachedModels(large)), isFalse);
    expect(cache.get<CachedModels>(key), isNull);
    expect(large.models.single.name.length, 500, reason: 'authoritative response remains complete');
  });

  test('row, text and cumulative projection budgets reject rather than truncate', () {
    final text = cache.stamp(catalog('X' * 513), a, client);
    expect(cache.put(key, text, () => CachedModels(text)), isFalse);
    final rows = List.generate(513, (i) => PluginBundle(name: 'plugin-$i'));
    expect(() => CachedPlugins(rows), throwsFormatException);
    final many = ModelCatalog(
      defaultSelection: null,
      routableProviders: const [],
      failures: const [],
      groups: [
        ProviderGroup(
          'p',
          'P',
          List.generate(500, (i) => ModelInfo(provider: 'p', id: '$i', name: 'Model', description: 'X' * 1000)),
        ),
      ],
    );
    expect(() => CachedModels(many), throwsFormatException);
  });

  test('provider projection drops URL, headers, key refs, diagnostics and revision', () {
    final source = ProvidersSnapshot(
      supported: true,
      revision: 981234,
      providers: const [
        CustomProvider(
          id: 'p',
          displayName: 'Provider',
          api: ProviderApi.openaiCompletions,
          baseUrl: 'https://SECRET-URL.invalid',
          headers: {'Authorization': 'SECRET-HEADER'},
          apiKeyEnv: 'SECRET-KEY',
        ),
      ],
      diagnostics: const {'p': 'SECRET-DIAGNOSTIC'},
    );
    final data = CachedProviders(source);
    final json = jsonEncode(data.toJson());
    expect(json, isNot(contains('SECRET')));
    expect(json, isNot(contains('981234')));
    expect(data.rows.single.health, ProviderHealth.misconfigured);
  });

  test('plugin projection retains on-demand grouping but no install target or diagnostic', () {
    final data = CachedPlugins([
      PluginBundle.fromJson({
        'name': 'p',
        'official': true,
        'availability': 'missing',
        'installTarget': {'spec': 'SECRET-TARGET', 'version': 'SECRET-VERSION'},
        'source': {'path': 'SECRET-SOURCE'},
        'rows': [
          {'rowId': 'SECRET-ROW'},
        ],
        'overrides': ['SECRET-OVERRIDE'],
        'error': {'code': 'SECRET-ERROR'},
        'meta': {
          'title': {'en': 'Plugin', 'zh': '插件'},
          'icon': 'SECRET-ICON',
        },
      }),
    ]);
    expect(data.rows.single.group, BundleGroup.onDemand);
    final bundle = data.rows.single.bundle;
    expect(bundle.installTargetSpec, isNull);
    expect(bundle.source, isNull);
    expect(bundle.rows, isEmpty);
    expect(bundle.error, isNull);
    expect(bundle.title('zh'), '插件');
    expect(jsonEncode(data.toJson()), isNot(contains('SECRET')));
  });

  test('sessions keep title/id/time only and never advertise stale running state', () {
    final source = SessionSummary(
      sessionId: 's',
      updatedAt: now,
      running: true,
      blank: false,
      agentAvailable: true,
      cwd: 'SECRET-CWD',
      raw: const {'SECRET-RAW': true},
      projections: const SessionProjections(981234, {
        'title': 'Title',
        'inbox': 'SECRET-INBOX',
        'permissions': 'SECRET-PERM',
      }),
    );
    final data = CachedSessions(sessions: [source], bots: const [], workspaceVersion: 'v', scoped: true);
    final row = data.sessions.single;
    expect(row.running, isFalse);
    expect(row.agentAvailable, isFalse);
    expect(row.raw, isEmpty);
    expect(row.projections.values.keys, ['title']);
    expect(jsonEncode(data.toJson()), isNot(contains('SECRET')));
  });

  test('cached projections are immutable detached copies', () {
    final models = <ModelInfo>[const ModelInfo(provider: 'p', id: 'm', name: 'Original')];
    final raw = ModelCatalog(
      defaultSelection: null,
      routableProviders: const [],
      groups: [ProviderGroup('p', 'P', models)],
      failures: const [],
    );
    final copy = CachedModels(raw);
    models.clear();
    expect(copy.value.models.single.name, 'Original');
    expect(() => copy.value.groups.clear(), throwsUnsupportedError);
    expect(() => copy.value.groups.single.models.clear(), throwsUnsupportedError);
  });

  test('workspace path, member set and timestamp participate in version', () {
    Workspace workspace(String path, List<String> members, [DateTime? updated]) =>
        Workspace(workspaceId: 'w', path: path, title: 'W', sessionIds: members, updatedAt: updated);
    final original = readWorkspaceVersion(workspace('/a', ['1', '2']));
    expect(readWorkspaceVersion(workspace('/a', ['2', '1'])), original);
    expect(readWorkspaceVersion(workspace('/b', ['1', '2'])), isNot(original));
    expect(readWorkspaceVersion(workspace('/a', ['1'])), isNot(original));
    expect(readWorkspaceVersion(workspace('/a', ['1', '2'], now)), isNot(original));
    expect(
      readWorkspaceVersion(workspace('/a', List.filled(129, List.filled(256, 'x').join()))),
      isNull,
      reason: 'identity hashing also has a cumulative string bound',
    );
  });
}
