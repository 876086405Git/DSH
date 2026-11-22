// Islands that island.js reaches by name (CR-7881a22, the same class as a
// conversation view): a sidebar panel (`main`), a settings section, and a
// right pane tab, run against a model of DSH Web 0.2.1-rc.4's page under
// node (test/plugins/islands/support/island_page_harness.mjs). Names match
// whole; two controls by the name, or another entry dsh-go-bridge reports
// under it, is a miss. Where the client records what it opened (the right
// pane's layout, by kind) that is read back; where it doesn't (panels and
// sections live in memory), the control's own current state
// (`aria-current`) and the slot's content changing are the proof. A
// navigation that misses is `empty`, never `ready` over what the slot
// shows by default (the conversation in `main`, the first section, another
// pane's tab). Needs `node` on PATH; skipped without it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String? _node() {
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    if (dir.isNotEmpty && File('$dir/node').existsSync()) return '$dir/node';
  }
  return null;
}

void main() {
  final node = _node();
  final skip = node == null ? 'node is not installed' : null;

  Future<Map<String, Object?>> open(Map<String, Object?> scenario) async {
    final result = await Process.run(node!, [
      'test/plugins/islands/support/island_page_harness.mjs',
      'assets/islands/island.js',
      jsonEncode(scenario),
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final out = jsonDecode(result.stdout as String) as Map<String, Object?>;
    expect(out['thrown'], isNull, reason: '${out['thrown']}');
    return out;
  }

  List<Map<String, Object?>> messages(Map<String, Object?> out) =>
      (out['messages']! as List).cast<Map<String, Object?>>();

  /// `ready` for [cell], and the outlet the island shows draws [content].
  void opened(Map<String, Object?> out, {required String cell, required String content}) {
    final said = messages(out);
    expect(said.map((m) => m['t']), ['ready'], reason: '${out['trace']}');
    expect(said.single['cell'], cell);
    expect(out['island'], content, reason: 'the island shows what was asked for');
  }

  /// No `ready`: one `empty` after a navigation that missed, which falls
  /// back to 在网页版打开.
  void fellBack(Map<String, Object?> out) {
    final said = messages(out);
    expect(said.map((m) => m['t']), ['empty'], reason: '${out['trace']}');
    expect(said.single['detail'], 'navigation');
  }

  group('a sidebar panel (main)', () {
    const plugins = {'id': 'plugins', 'label': '插件'};
    const notes = {'id': 'notes', 'label': 'Notes'};
    Map<String, Object?> panel(List<Map<String, Object?>> panels, [Map<String, Object?> extra = const {}]) => {
      'target': 'panel',
      'panels': panels,
      'cell': 'notes',
      'names': ['Notes'],
      ...extra,
    };

    test('control: the one row by its name opens it', () async {
      final out = await open(panel([plugins, notes]));
      opened(out, cell: 'notes', content: 'notes');
      expect(out['clicks'], ['panel:notes']);
    }, skip: skip);

    test('a longer name before it that starts with its name is another panel: never pressed', () async {
      final out = await open(
        panel([
          plugins,
          {'id': 'notes-pro', 'label': 'Notes Pro'},
          notes,
        ]),
      );
      opened(out, cell: 'notes', content: 'notes');
      expect(out['clicks'], ['panel:notes']);
    }, skip: skip);

    test('two rows by one name: nothing is pressed', () async {
      final out = await open(
        panel([
          {'id': 'other', 'label': 'Notes'},
          notes,
        ]),
      );
      fellBack(out);
      expect(out['clicks'], isEmpty);
    }, skip: skip);

    test('no row by its name: no ready over the conversation main shows by default', () async {
      final out = await open(panel([plugins]));
      fellBack(out);
      expect(out['shown'], 'conversation');
    }, skip: skip);

    test('a conversation titled like it in the sidebar is not a panel row', () async {
      final out = await open(
        panel(
          [plugins, notes],
          {
            'sessions': ['Notes'],
          },
        ),
      );
      opened(out, cell: 'notes', content: 'notes');
      expect(out['clicks'], ['panel:notes']);
    }, skip: skip);

    test('another panel the bridge reports under its name (not drawn as a row): nothing is pressed', () async {
      final out = await open(
        panel(
          [plugins, notes],
          {
            'occupants': {
              'sidebar.panellist': [
                {'cell': 'notes', 'label': 'Notes'},
                {'cell': 'other', 'label': 'Notes'},
              ],
            },
          },
        ),
      );
      fellBack(out);
      expect(out['clicks'], isEmpty);
    }, skip: skip);

    test('a click that does not take: no ready', () async {
      final out = await open(panel([plugins, notes], {'ignoreClicks': true}));
      fellBack(out);
      expect(out['shown'], 'conversation');
    }, skip: skip);

    test('already the current page: open without a click', () async {
      final out = await open(panel([plugins, notes], {'active': 'notes'}));
      opened(out, cell: 'notes', content: 'notes');
      expect(out['clicks'], isEmpty);
    }, skip: skip);
  });

  group('a settings section', () {
    const general = {'id': 'general', 'label': '通用'};
    const memo = {'id': 'memo', 'label': 'Memo'};
    Map<String, Object?> section(List<Map<String, Object?>> sections, [Map<String, Object?> extra = const {}]) => {
      'target': 'settings',
      'sections': sections,
      'cell': 'memo',
      'names': ['Memo'],
      ...extra,
    };

    test('control: the one section by its name opens it', () async {
      final out = await open(section([general, memo]));
      opened(out, cell: 'memo', content: 'memo');
      expect(out['clicks'], ['open settings:true', 'section:memo']);
    }, skip: skip);

    test('a longer name before it that starts with its name is another section', () async {
      final out = await open(
        section([
          general,
          {'id': 'memo-sync', 'label': 'Memo Sync'},
          memo,
        ]),
      );
      opened(out, cell: 'memo', content: 'memo');
      expect(out['clicks'], ['open settings:true', 'section:memo']);
    }, skip: skip);

    test('two sections by one name: nothing is pressed', () async {
      final out = await open(
        section([
          general,
          {'id': 'other', 'label': 'Memo'},
          memo,
        ]),
      );
      fellBack(out);
      expect(out['clicks'], ['open settings:true']);
    }, skip: skip);

    test('no section by its name: no ready over the first section', () async {
      final out = await open(section([general]));
      fellBack(out);
      expect(out['shown'], 'general');
    }, skip: skip);

    test('another section the bridge reports under its name: nothing is pressed', () async {
      final out = await open(
        section(
          [general, memo],
          {
            'occupants': {
              'settings.section': [
                {'cell': 'memo', 'label': 'Memo'},
                {'cell': 'other', 'label': 'Memo'},
              ],
            },
          },
        ),
      );
      fellBack(out);
      expect(out['clicks'], ['open settings:true']);
    }, skip: skip);

    test('a click that does not take: no ready', () async {
      final out = await open(section([general, memo], {'ignoreClicks': true}));
      fellBack(out);
    }, skip: skip);

    test('a boolean opener keeps the first section until the real section navigation', () async {
      final out = await open(
        section([
          {'id': 'account', 'label': 'Account'},
          general,
          memo,
        ]),
      );
      opened(out, cell: 'memo', content: 'memo');
      expect(out['clicks'], ['open settings:true', 'section:memo']);
    }, skip: skip);

    for (final live in <Map<String, Object?>>[
      {'label': '当前备忘'},
      {'label': 'Live Memo', 'masked': false},
      {'label': '  Live   Memo  ', 'masked': false},
    ]) {
      final label = (live['label']! as String).trim().replaceAll(RegExp(r'\s+'), ' ');
      test('the same package and cell live label ($live) wins over stale names', () async {
        final out = await open(
          section(
            [
              general,
              {'id': 'old-name-owner', 'label': 'Memo'},
              {'id': 'wrong-package', 'label': 'Wrong package'},
              {'id': 'memo', 'label': label},
            ],
            {
              'package': '@acme/memo',
              'occupants': {
                'settings.section': [
                  {'cell': 'memo', 'package': '@other/memo', 'label': 'Wrong package', 'active': true},
                  {'cell': 'memo', 'package': '@acme/memo', 'active': true, ...live},
                ],
              },
            },
          ),
        );
        opened(out, cell: 'memo', content: 'memo');
        expect(out['clicks'], ['open settings:true', 'section:memo']);
      }, skip: skip);
    }

    test('without cfg.package the same cell live label still works', () async {
      final out = await open(
        section(
          [
            general,
            {'id': 'memo', 'label': 'Live Memo'},
          ],
          {
            'occupants': {
              'settings.section': [
                {'cell': 'memo', 'package': '@acme/memo', 'label': 'Live Memo'},
              ],
            },
          },
        ),
      );
      opened(out, cell: 'memo', content: 'memo');
      expect(out['clicks'], ['open settings:true', 'section:memo']);
    }, skip: skip);

    for (final foreign in [
      {'cell': 'other', 'package': '@acme/memo'},
      {'cell': 'memo', 'package': '@other/memo'},
    ]) {
      test('a live name from $foreign is not borrowed', () async {
        final out = await open(
          section(
            [
              general,
              {'id': 'other', 'label': 'Foreign live memo'},
            ],
            {
              'package': '@acme/memo',
              'occupants': {
                'settings.section': [
                  {...foreign, 'label': 'Foreign live memo', 'active': true, 'masked': false},
                ],
              },
            },
          ),
        );
        fellBack(out);
        expect(out['shown'], 'general');
        expect(out['clicks'], ['open settings:true']);
      }, skip: skip);
    }

    for (final unavailable in [
      {'active': false},
      {'masked': true},
    ]) {
      test('a live entry marked $unavailable keeps the old names as fallback', () async {
        final out = await open(
          section(
            [general, memo],
            {
              'package': '@acme/memo',
              'occupants': {
                'settings.section': [
                  {'cell': 'memo', 'package': '@acme/memo', 'label': 'Unavailable live name', ...unavailable},
                ],
              },
            },
          ),
        );
        opened(out, cell: 'memo', content: 'memo');
        expect(out['clicks'], ['open settings:true', 'section:memo']);
      }, skip: skip);
    }

    test('a live name still shared by another cell cannot select the one drawn row', () async {
      final out = await open(
        section(
          [
            general,
            {'id': 'memo', 'label': 'Live Memo'},
          ],
          {
            'package': '@acme/memo',
            'occupants': {
              'settings.section': [
                {'cell': 'memo', 'package': '@acme/memo', 'label': 'Live Memo'},
                {'cell': 'other', 'package': '@other/memo', 'label': 'Live Memo'},
              ],
            },
          },
        ),
      );
      fellBack(out);
      expect(out['clicks'], ['open settings:true']);
    }, skip: skip);

    for (final webOnly in [false, true]) {
      test('a failed web opening with a drawn old slot never becomes ready (webOnly=$webOnly)', () async {
        final out = await open(section([general, memo], {'webOpenOk': false, 'webOnly': webOnly}));
        fellBack(out);
        expect(out['shown'], 'general', reason: 'the old settings slot exists despite the failed opening');
        expect(out['clicks'], ['open settings:true']);
      }, skip: skip);
    }

    test('a button inside the section shown that reads like it is not a section', () async {
      final out = await open(
        section(
          [general, memo],
          {
            'sectionButtons': ['Memo'],
          },
        ),
      );
      opened(out, cell: 'memo', content: 'memo');
      expect(out['clicks'], ['open settings:true', 'section:memo']);
    }, skip: skip);
  });

  group('a right pane tab', () {
    const notes = {'id': 't-notes', 'kind': 'notes', 'title': 'Notes'};
    Map<String, Object?> tab(List<Map<String, Object?>> types, [Map<String, Object?> extra = const {}]) => {
      'target': 'rightbar',
      'types': types,
      'cell': 't-notes',
      'names': ['Notes'],
      ...extra,
    };

    test('the bridge opens it by its id: the island shows that tab, not another pane\'s', () async {
      final out = await open(tab([notes], {'bridge': 'openTab', 'split': 'files'}));
      opened(out, cell: 't-notes', content: 'notes');
      expect(out['clicks'], ['bridge openTab:t-notes']);
    }, skip: skip);

    test('a bridge that can\'t open it by its id is not second-guessed by name', () async {
      final out = await open(tab([notes], {'bridge': 'openTab-fail'}));
      fellBack(out);
      // Asked again on each of island.js's tries, always by its id; nothing on the page is pressed.
      expect(out['clicks'], isNotEmpty);
      expect(out['clicks'], everyElement('bridge openTab:t-notes'));
    }, skip: skip);

    test('without the bridge: the one guide entry by its name, confirmed by the kind the pane records', () async {
      final out = await open(tab([notes]));
      opened(out, cell: 't-notes', content: 'notes');
      expect(out['clicks'], ['expand', 'entry:notes']);
    }, skip: skip);

    test('without the bridge: a longer name before it that starts with its name is another tab', () async {
      final out = await open(
        tab([
          {'id': 't-pro', 'kind': 'notes-pro', 'title': 'Notes Pro'},
          notes,
        ]),
      );
      opened(out, cell: 't-notes', content: 'notes');
      expect(out['clicks'], ['expand', 'entry:notes']);
    }, skip: skip);

    test('without the bridge: two entries by one name, nothing is picked', () async {
      final out = await open(
        tab([
          {'id': 't-other', 'kind': 'other', 'title': 'Notes'},
          notes,
        ]),
      );
      fellBack(out);
      expect(out['clicks'], ['expand']);
    }, skip: skip);

    test('without the bridge: a pick the pane never records can\'t be confirmed', () async {
      final out = await open(tab([notes], {'layoutPersist': false}));
      fellBack(out);
    }, skip: skip);

    test('without the bridge: another pane showing a tab first is not taken for this one', () async {
      final out = await open(tab([notes], {'split': 'files'}));
      opened(out, cell: 't-notes', content: 'notes');
    }, skip: skip);
  });
}
