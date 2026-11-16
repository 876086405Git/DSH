import 'dart:convert';

import 'package:dsh_tavern/src/regex/regex_worker.dart';
import 'package:dsh_tavern/src/state/state_engine.dart' as state;
import 'package:dsh_tavern/src/worldinfo/world_info.dart';
import 'package:test/test.dart';

typedef Json = Map<String, Object?>;

const a = state.StateExecutionSource.pack(installedPackId: 'pack', bindingId: 'a', onceEpoch: 1);
const b = state.StateExecutionSource.pack(installedPackId: 'pack', bindingId: 'b', onceEpoch: 1);
const a2 = state.StateExecutionSource.pack(installedPackId: 'pack', bindingId: 'a', onceEpoch: 2);

late RegexWorker worker;

void main() {
  setUpAll(() {
    worker = RegexWorker();
  });
  tearDownAll(() => worker.close());

  test('original pointers map duplicate native uids before scan and retained hits alone consume', () async {
    final raw = <String, Object?>{
      'entries': {
        'a/~': {
          'uid': 7,
          'constant': true,
          'content': 'first',
          'position': 0,
          'sticky': 3,
          'useProbability': true,
          'probability': 99,
        },
        'b': {
          'uid': 7,
          'constant': true,
          'content': 'second',
          'position': 0,
          'sticky': null,
          'delay': null,
          'useProbability': true,
          'probability': 99,
        },
      },
    };
    final original = WorldInfoBook.fromJson(id: 'original', source: WorldInfoSource.global, json: raw);
    expect(original.entries.map((entry) => entry.sourcePointer), ['/entries/a~1~0', '/entries/b']);
    expect(original.entries.first.timerDeclarations, {'sticky': 3});
    expect(original.entries.last.timerDeclarations, {'sticky': null});
    expect(original.entries.first.delayDeclaration, isEmpty);
    expect(original.entries.last.delayDeclaration, {'delay': null});
    original.entries.first.timerDeclarations['sticky'] = 99;
    expect(original.entries.first.timerDeclarations, {'sticky': 3});
    final v3 = WorldInfoBook.fromJson(
      id: 'v3',
      source: WorldInfoSource.character,
      json: {
        'entries': [
          {'id': 7, 'enabled': true, 'content': 'shadowed'},
          {'id': 7, 'enabled': true, 'content': 'winner'},
          {'id': 'paused', 'enabled': false, 'content': 'paused'},
        ],
      },
    );
    expect(v3.entries.map((entry) => entry.sourcePointer), ['/entries/1', '/entries/2']);
    expect(v3.entries.first.timerDeclarations, {'sticky': null, 'cooldown': null});
    expect(v3.entries.first.delayDeclaration, {'delay': null});
    expect(v3.entries.last.disabled, isTrue);

    final first = remapWorldInfoBook(
      original,
      id: 'book-a',
      stWorldName: 'world-a',
      entryUidsByPointer: const {'/entries/a~1~0': 'first-a', '/entries/b': 'second-a'},
    );
    final second = remapWorldInfoBook(
      original,
      id: 'book-b',
      stWorldName: 'world-b',
      entryUidsByPointer: const {'/entries/a~1~0': 'first-b', '/entries/b': 'second-b'},
    );
    expect(first.entries.map((entry) => entry.uid), ['first-a', 'second-a']);
    expect(first.raw, raw);
    expect(first.entries.first.raw['uid'], 7);
    expect(first.entries.first.sourcePointer, '/entries/a~1~0');
    final saved = <String, Object?>{
      'v': 1,
      'bindings': {
        'a': {
          'installedPackId': 'pack',
          'onceEpoch': 1,
          'rules': ['rule'],
          'events': {
            'once': ['handler'],
          },
          'foreign': {'kept': true},
        },
        'other': {'opaque': 'retained'},
      },
    };
    final before = jsonEncode({'raw': raw, 'book': original.raw, 'saved': saved});
    var draws = 0;
    var expansions = 0;
    final sources = <WorldInfoEntryRef, WorldInfoPackSource>{
      for (final book in [first, second])
        for (final entry in book.entries)
          entry.identity: WorldInfoPackSource(
            source: book.id == 'book-a' ? a : b,
            resourceLocalId: 'lore',
            entryLocalId: entry.sourcePointer == '/entries/a~1~0' ? 'first' : 'second',
            packVersion: '1',
          ),
    };
    final result = await _evaluate(
      [first, second],
      sources: sources,
      saved: saved,
      count: 2,
      random: () {
        draws++;
        return 0;
      },
      expand: (text) {
        expansions++;
        return text;
      },
    );
    expect(result.activated, hasLength(4));
    expect(draws, 4);
    final calls = (draws, expansions);
    final retained = result.withoutEntries({('book-a', 'first-a')});
    final repeated = result.withoutEntries({('book-a', 'first-a')});
    expect((draws, expansions), calls);
    final adopted = _merge(saved, retained.packWorldInfo);
    expect(_merge(saved, repeated.packWorldInfo), adopted);
    expect(_map(_world(adopted, 'a')['entries'])['lore'], {
      'second': {'matches': 1, 'lastMessageCount': 2},
    });
    expect(_entry(adopted, 'b', 'first')['matches'], 1);
    expect(_entry(adopted, 'b', 'first').containsKey('sticky'), isTrue);
    expect(_row(adopted, 'a')['rules'], ['rule']);
    expect(_row(adopted, 'a')['events'], {
      'once': ['handler'],
    });
    expect(_row(adopted, 'other'), {'opaque': 'retained'});
    expect(result.timedWorldInfo, {'sticky': {}, 'cooldown': {}});
    expect(result.decoratorState, isEmpty);
    expect(jsonEncode({'raw': raw, 'book': original.raw, 'saved': saved}), before);
  });

  test('content upgrades keep admissions and old timer deadlines across inactive and count gates', () async {
    final first = _book('@@keep_activate_after_match\nold', sticky: '2', cooldown: '4');
    final firstResult = await _evaluate([first], sources: _sources(first, a, '1'), count: 2);
    final saved = _merge(null, firstResult.packWorldInfo);
    final initial = jsonEncode(saved);
    final timer = _map(_entry(saved, 'a')['sticky']);
    expect(timer['start'], 2);
    expect(timer['end'], 4);
    expect(timer['cooldownOnStickyEnd'], '4');
    expect(_entry(saved, 'a')['matches'], 1);

    // Same-count unprotected timers disappear; one prior match is not "keep".
    final sameCount = await _evaluate(
      [first],
      sources: _sources(first, a, '1'),
      count: 2,
      text: 'absent',
      saved: saved,
    );
    expect(sameCount.activated, isEmpty);
    final sameState = _merge(saved, sameCount.packWorldInfo);
    expect(_entry(sameState, 'a').containsKey('sticky'), isFalse);
    expect(_entry(sameState, 'a').containsKey('cooldown'), isFalse);
    expect(_entry(sameState, 'a')['matches'], 1);

    final stickyHit = await _evaluate(
      [first],
      sources: _sources(first, a, '1'),
      count: 3,
      text: 'absent',
      saved: saved,
    );
    final twice = _merge(saved, stickyHit.packWorldInfo);
    expect(stickyHit.activated.single.reason, 'sticky');
    expect(_entry(twice, 'a')['matches'], 2);
    final upgraded = _book('@@keep_activate_after_match\nchanged', sticky: '2', cooldown: '4');
    expect(upgraded.entries.single.stHash, isNot(first.entries.single.stHash));
    final sameUpgrade = await _evaluate(
      [upgraded],
      sources: _sources(upgraded, a, '2'),
      count: 3,
      text: 'absent',
      saved: twice,
    );
    expect(sameUpgrade.activated.single.reason, 'decorator-keep');
    final upgradedState = _merge(twice, sameUpgrade.packWorldInfo);
    expect(_entry(upgradedState, 'a')['matches'], 2);
    expect(_map(_entry(upgradedState, 'a')['sticky'])['triggeredVersion'], '1');

    final inactive = await _evaluate(const [], count: 100, saved: upgradedState);
    expect(inactive.packWorldInfo.isEmpty, isTrue);
    expect(_merge(upgradedState, inactive.packWorldInfo), upgradedState);
    final restored = await _evaluate(
      [upgraded],
      sources: _sources(upgraded, a, '2'),
      count: 5,
      text: 'absent',
      saved: upgradedState,
    );
    expect(restored.activated, isEmpty);
    final cooling = _merge(upgradedState, restored.packWorldInfo);
    expect(_entry(cooling, 'a').containsKey('sticky'), isFalse);
    expect(_entry(cooling, 'a')['cooldown'], {
      'start': 4,
      'end': 8,
      'protected': true,
      'triggeredHash': timer['triggeredHash'],
      'triggeredVersion': '1',
    });
    final back = await _evaluate(
      [upgraded],
      sources: _sources(upgraded, a, '2'),
      count: 3,
      text: 'absent',
      saved: cooling,
    );
    expect(back.activated, isEmpty);
    expect(_merge(cooling, back.packWorldInfo), cooling);
    final expired = await _evaluate(
      [upgraded],
      sources: _sources(upgraded, a, '2'),
      count: 8,
      text: 'absent',
      saved: cooling,
    );
    expect(expired.activated.single.reason, 'decorator-keep');
    final renewed = _merge(cooling, expired.packWorldInfo);
    expect(_entry(renewed, 'a')['matches'], 3);
    expect(_map(_entry(renewed, 'a')['sticky'])['start'], 8);
    expect(_map(_entry(renewed, 'a')['sticky'])['triggeredVersion'], '2');
    expect(jsonEncode(saved), initial);
  });

  test('bad required carriers stay raw and only actual newer-epoch adoption resets all pack domains', () async {
    final book = _book('entry', sticky: 2);
    final badOuter = <Object?>['kept'];
    final inactive = await _evaluate(const [], saved: badOuter, count: 2);
    expect(inactive.packIssues, isEmpty);
    expect(inactive.packWorldInfo.isEmpty, isTrue);
    expect(_merge(badOuter, inactive.packWorldInfo), badOuter);
    final blocked = await _evaluate([book], sources: _sources(book, a, '1'), saved: badOuter, count: 2);
    expect(blocked.activated, isEmpty);
    expect(blocked.packIssues.map((issue) => issue['code']), contains('pack_runtime_shape'));
    expect(blocked.packWorldInfo.isEmpty, isTrue);
    final old = <String, Object?>{
      'v': 1,
      'bindings': {
        'a': {
          'installedPackId': 'pack',
          'onceEpoch': 1,
          'rules': ['old'],
          'events': {
            'once': ['old'],
          },
          'worldInfo': {
            'entries': {
              'lore': {'entry': null},
            },
          },
          'foreign': 7,
        },
        'b': {'opaque': 'do not inspect'},
      },
    };
    final before = jsonEncode(old);
    final malformed = await _evaluate([book], sources: _sources(book, a, '1'), saved: old, count: 2);
    expect(malformed.activated, isEmpty);
    expect(malformed.packIssues.map((issue) => issue['code']), contains('pack_world_info_shape'));
    expect(malformed.packWorldInfo.isEmpty, isTrue);
    for (final type in const ['sticky', 'cooldown']) {
      final savedTimer = jsonDecode(jsonEncode(old)) as Json;
      _map(_map(_world(savedTimer, 'a')['entries'])['lore'])['entry'] = {type: <String, Object?>{}};
      final beforeTimer = jsonEncode(savedTimer);
      final missingDeadline = await _evaluate([book], sources: _sources(book, a, '1'), saved: savedTimer, count: 3);
      expect(missingDeadline.activated, isEmpty);
      expect(missingDeadline.packIssues, hasLength(1));
      expect(missingDeadline.packIssues.single['code'], 'pack_world_info_shape');
      expect(
        missingDeadline.packIssues.single['path'],
        '/dshgoPackRuntime/bindings/a/worldInfo/entries/lore/entry/$type',
      );
      expect(missingDeadline.packWorldInfo.isEmpty, isTrue);
      expect(_merge(savedTimer, missingDeadline.packWorldInfo), savedTimer);
      expect(jsonEncode(savedTimer), beforeTimer);
    }
    final reset = await _evaluate([book], sources: _sources(book, a2, '2'), saved: old, count: 2);
    expect(reset.packIssues, isEmpty);
    expect(reset.activated, hasLength(1));
    final adopted = _merge(old, reset.packWorldInfo);
    expect(_row(adopted, 'a')['onceEpoch'], 2);
    expect(_row(adopted, 'a').containsKey('rules'), isFalse);
    expect(_row(adopted, 'a').containsKey('events'), isFalse);
    expect(_row(adopted, 'a')['foreign'], 7);
    expect(_entry(adopted, 'a')['matches'], 1);
    expect(_row(adopted, 'b'), {'opaque': 'do not inspect'});
    expect(jsonEncode(old), before);
  });

  test('held secret sessions advance only the WI baseline before one strict state and event finish', () async {
    final raw = <String, Object?>{
      'schema': {
        'type': 'object',
        'required': ['entity', 'secret', 'n'],
        'properties': {
          'entity': {'type': 'string'},
          'secret': {
            'type': ['string', 'null'],
            'x-dsh-hidden': true,
          },
          'n': {'type': 'integer'},
        },
      },
    };
    final definition = state.StateDefinition.compose(
      raw,
      effectiveConfigId: 'config',
      compositionEligible: true,
      sources: [
        state.StateRuleSource(
          source: a,
          state: {
            'rules': [
              {
                'id': 'rule',
                'once': true,
                'when': true,
                'do': [
                  {
                    'type': 'state',
                    'ops': [
                      {'op': 'add', 'path': '/n', 'value': 1, 'why': 'rule'},
                    ],
                  },
                ],
              },
            ],
          },
        ),
      ],
    );
    final baseline = <String, Object?>{'entity': 'E', 'secret': null, 'n': 0};
    final saved = <String, Object?>{
      'v': 1,
      'bindings': {
        'b': {
          'installedPackId': 'pack',
          'onceEpoch': 1,
          'rules': ['kept'],
        },
      },
    };
    final session = definition.startSession(
      valueExists: true,
      value: baseline,
      packRuntimeExists: true,
      packRuntime: saved,
    );
    final prepared = _prepare(session, definition, baseline);
    expect(prepared.accepted, isTrue);
    final book = _book('wi', sticky: 2);
    final wi = await _evaluate([book], sources: _sources(book, a, '1'), saved: saved, count: 2);
    final merged = _merge(saved, wi.packWorldInfo);
    final adopted = session.adoptPackWorldInfo(wi.packWorldInfo);
    expect(adopted.issues, isEmpty);
    expect(adopted.raw, merged);
    expect(prepared.packRuntime, saved);

    final events = state.CardEventDefinition.compose(
      [
        state.CardEventRegistrySource(
          source: a,
          raw: {
            'v': 1,
            'rules': [
              {
                'id': 'handler',
                'name': 'next',
                'once': true,
                'when': true,
                'do': [
                  {
                    'type': 'state',
                    'ops': [
                      {'op': 'add', 'path': '/n', 'value': 2, 'why': 'event'},
                    ],
                  },
                ],
              },
            ],
          },
        ),
      ],
      effectiveConfigId: 'config',
      compositionEligible: true,
    );
    final invocation = state.CardEventInvocation.composed(
      definition: events,
      invocationId: 'event-batch',
      capabilityFingerprint: events.fingerprint,
      authorizedHandlers: events.handlerRefs,
      proposals: const [state.CardEventProposal(eventId: 'e', runId: 'r', name: 'next', data: '', source: a)],
      runtimeExists: false,
      packRuntimeExists: true,
      packRuntime: merged,
      stateActionAllowed: true,
    );
    final stale = definition
        .startSession(valueExists: true, value: prepared.value, packRuntimeExists: true, packRuntime: saved)
        .finishWithEvents(invocation);
    expect(stale.events.valid, isFalse);
    expect(stale.events.issues.map((issue) => issue['code']), contains('card_event_pack_baseline'));

    final finished = session.finishWithEvents(invocation);
    expect(finished.state.valid, isTrue);
    expect(finished.events.valid, isTrue);
    expect(_map(finished.state.value)['n'], 3);
    expect(_entry(finished.state.packRuntime, 'a')['matches'], 1);
    expect(_row(finished.state.packRuntime, 'a')['rules'], ['rule']);
    expect(_map(_row(finished.state.packRuntime, 'a')['events'])['once'], ['handler']);
    expect(_row(finished.state.packRuntime, 'b')['rules'], ['kept']);
    expect(finished.events.packRuntime, finished.state.packRuntime);
    expect(session.secretTerminalPhase(prepared).packRuntime, finished.state.packRuntime);
    expect(prepared.packRuntime, saved);
    expect(() => session.adoptPackWorldInfo(wi.packWorldInfo), throwsStateError);

    final quiet = state.StateDefinition.compose(
      raw,
      effectiveConfigId: 'quiet',
      sources: const [],
      compositionEligible: true,
    );
    final quietSession = quiet.startSession(
      valueExists: true,
      value: baseline,
      packRuntimeExists: true,
      packRuntime: saved,
    );
    final quietPrepared = _prepare(quietSession, quiet, baseline, config: 'quiet');
    expect(quietPrepared.accepted, isTrue);
    expect(quietSession.adoptPackWorldInfo(wi.packWorldInfo).issues, isEmpty);
    quietSession.finish();
    final terminal = quietSession.secretTerminalPhase(quietPrepared);
    expect(terminal.changed, isFalse);
    expect(terminal.packRuntime, merged);
    expect(quietPrepared.packRuntime, saved);
  });
}

WorldInfoBook _book(String content, {Object? sticky, Object? cooldown}) => remapWorldInfoBook(
  WorldInfoBook.fromJson(
    id: 'source',
    source: WorldInfoSource.global,
    json: {
      'entries': {
        'original': {
          'uid': 7,
          'key': ['key'],
          'content': content,
          'position': 0,
          'sticky': ?sticky,
          'cooldown': ?cooldown,
        },
      },
    },
  ),
  id: 'book',
  stWorldName: 'world',
  entryUidsByPointer: const {'/entries/original': 'uid'},
);

Map<WorldInfoEntryRef, WorldInfoPackSource> _sources(
  WorldInfoBook book,
  state.StateExecutionSource source,
  String version,
) => {
  book.entries.single.identity: WorldInfoPackSource(
    source: source,
    resourceLocalId: 'lore',
    entryLocalId: 'entry',
    packVersion: version,
  ),
};

Future<WorldInfoResult> _evaluate(
  List<WorldInfoBook> books, {
  Map<WorldInfoEntryRef, WorldInfoPackSource> sources = const {},
  Object? saved,
  required int count,
  String text = 'key',
  double Function()? random,
  String Function(String)? expand,
}) => WorldInfoEngine(worker: worker).evaluate(
  WorldInfoInput(
    books: books,
    messages: [WorldInfoMessage(text)],
    messageCount: count,
    maxContext: 100000,
    tokenCount: (value) => value.length,
    settings: const WorldInfoSettings(budgetPercent: 100),
    random: random ?? () => 0,
    expand: expand ?? (value) => value,
    packSources: sources,
    packWorldInfo: state.StatePackWorldInfoSnapshot(exists: saved != null, raw: saved),
  ),
);

Object? _merge(Object? raw, state.StatePackWorldInfoDelta delta) {
  final result = state.mergeStatePackWorldInfo(exists: raw != null, raw: raw, delta: delta);
  expect(result.issues, isEmpty);
  return result.raw;
}

state.StateSecretPrepared _prepare(
  state.StateSession session,
  state.StateDefinition definition,
  Json baseline, {
  String config = 'config',
}) {
  final secret = state.SecretDefinition.parse(
    {
      'v': 1,
      'slots': [
        {
          'id': 'slot',
          'path': '/secret',
          'entityPath': '/entity',
          'unbound': {'exists': true, 'value': null},
          'bindWhen': true,
          'release': {'id': 'tell', 'audience': 'currentCharacter', 'when': true, 'template': '{{fact}}'},
        },
      ],
    },
    state: definition,
    source: a,
    effectiveConfigId: config,
  );
  final capability = secret.capture(valueExists: true, value: baseline, boundKeys: const [], characterId: 'character');
  final proposal = capability.parseProposal({
    'notes': '',
    'facts': [
      {'slotId': 'slot', 'value': 'fact'},
    ],
  });
  return session.prepareSecretFacts(capability.plan(proposal, id: 'bind'));
}

Json _map(Object? value) => value! as Json;
Json _row(Object? value, String binding) => _map(_map(_map(value)['bindings'])[binding]);
Json _world(Object? value, String binding) => _map(_row(value, binding)['worldInfo']);
Json _entry(Object? value, String binding, [String id = 'entry']) =>
    _map(_map(_map(_world(value, binding)['entries'])['lore'])[id]);
