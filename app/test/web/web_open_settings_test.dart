// The real open bridge on a model of DSH Web's settings dialog. The model
// only renders controls and records clicks/current state; it does not choose
// section names. Needs node on PATH; skipped without it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String? _node() {
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    if (dir.isNotEmpty && File('$dir/node').existsSync()) return '$dir/node';
  }
  return null;
}

const _general = {'id': 'general', 'label': '通用设置'};
const _memo = {'id': 'memo', 'label': 'Memo'};
const _openMemo = {
  'settings': 'memo',
  'settingsLabels': ['备忘', 'Memo'],
};

void main() {
  final node = _node();
  final skip = node == null ? 'node is not installed' : null;

  Future<Map<String, Object?>> page([Map<String, Object?> extra = const {}]) async {
    final result = await Process.run(node!, [
      'test/web/support/settings_page_harness.mjs',
      'assets/web/dsh_web_open.js',
      jsonEncode({
        'open': _openMemo,
        'sections': [_general, _memo],
        ...extra,
      }),
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final out = jsonDecode(result.stdout as String) as Map<String, Object?>;
    expect(out['thrown'], isNull, reason: '${out['thrown']}');
    expect(out['selectorErrors'], isEmpty, reason: 'the model must support the actual selectors');
    expect(out['doneAt'], isNotNull, reason: 'the opening must settle');
    expect(out['pendingTimers'], 0, reason: 'nothing keeps polling after the opening');
    return out;
  }

  List<Map<String, Object?>> presses(Map<String, Object?> out) =>
      (out['presses']! as List).cast<Map<String, Object?>>();

  List<String> pressed(Map<String, Object?> out) => [for (final press in presses(out)) press['name']! as String];

  List<Map<String, Object?>> reports(Map<String, Object?> out) =>
      (out['reports']! as List).cast<Map<String, Object?>>();

  void landed(Map<String, Object?> out, String section) {
    expect(reports(out), hasLength(1), reason: '${out['presses']}');
    expect(reports(out).single['ok'], isTrue);
    expect(reports(out).single['step'], isNull);
    expect(out['current'], section, reason: 'the selected section, not just a successful click');
  }

  void missed(Map<String, Object?> out) {
    expect(reports(out), hasLength(1), reason: '${out['presses']}');
    expect(reports(out).single['ok'], isFalse);
    expect(reports(out).single['step'], 'settings');
    expect(out['doneAt'], lessThan(17000), reason: 'a missing control has a bounded wait');
  }

  group('getting into settings', () {
    test('a direct entry arriving after the sidebar is awaited', () async {
      final out = await page({'entryMs': 900});
      landed(out, 'memo');
      expect(pressed(out), ['direct', 'section:memo']);
      expect(presses(out).first['at'], greaterThanOrEqualTo(900));
    }, skip: skip);

    for (final locale in ['zh', 'en']) {
      test('$locale account menu and its delayed settings item', () async {
        final out = await page({'entry': 'account', 'entryMs': 300, 'menuMs': 500, 'locale': locale});
        landed(out, 'memo');
        expect(pressed(out), ['account', 'menu settings', 'section:memo']);
        expect((presses(out)[1]['at']! as int) - (presses(out)[0]['at']! as int), greaterThanOrEqualTo(500));
      }, skip: skip);
    }

    test('an already open dialog is reused without pressing an opener', () async {
      final out = await page({'opened': true});
      landed(out, 'memo');
      expect(pressed(out), ['section:memo']);
    }, skip: skip);

    test('settings true only opens the dialog and keeps its first section', () async {
      final out = await page({
        'open': {'settings': true},
        'sections': [
          {'id': 'account', 'label': '账号与余额'},
          _general,
        ],
      });
      landed(out, 'account');
      expect(pressed(out), ['direct']);
    }, skip: skip);

    test('general is selected even when account sorts before it', () async {
      final out = await page({
        'open': {'settings': 'general'},
        'sections': [
          {'id': 'account', 'label': '账号与余额'},
          _general,
        ],
      });
      landed(out, 'general');
      expect(pressed(out), ['direct', 'section:general']);
    }, skip: skip);

    test('general in an open dialog is not mistaken for the section already shown', () async {
      final out = await page({
        'open': {'settings': 'general'},
        'opened': true,
        'active': 'memo',
      });
      landed(out, 'general');
      expect(pressed(out), ['section:general']);
    }, skip: skip);
  });

  group('the section name', () {
    for (final label in ['备忘', 'Memo']) {
      test('an arbitrary third-party id by its registered name $label', () async {
        final out = await page({
          'sections': [
            _general,
            {'id': 'memo', 'label': label},
          ],
        });
        landed(out, 'memo');
        expect(pressed(out), ['direct', 'section:memo']);
      }, skip: skip);
    }

    for (final entry in {
      'models': 'Models',
      'plugins': 'Built-in plugins',
      'agent-presets': 'Agent presets',
      'account': 'Account',
    }.entries) {
      test('the legacy built-in label for ${entry.key}', () async {
        final out = await page({
          'open': {'settings': entry.key},
          'sections': [
            _general,
            {'id': entry.key, 'label': entry.value},
          ],
        });
        landed(out, entry.key);
        expect(pressed(out), ['direct', 'section:${entry.key}']);
      }, skip: skip);
    }

    test('the same cell live label wins over a stale registered name', () async {
      final out = await page({
        'sections': [
          _general,
          {'id': 'old-name-owner', 'label': 'Memo'},
          {'id': 'memo', 'label': '当前备忘'},
        ],
        'occupants': [
          {'cell': 'memo', 'label': '当前备忘', 'active': true},
        ],
      });
      landed(out, 'memo');
      expect(pressed(out), ['direct', 'section:memo']);
    }, skip: skip);

    test('an older bridge without active also supplies the live label', () async {
      final out = await page({
        'sections': [
          _general,
          {'id': 'memo', 'label': 'Live memo'},
        ],
        'occupants': [
          {'cell': 'memo', 'label': 'Live memo'},
        ],
      });
      landed(out, 'memo');
    }, skip: skip);

    test('an inactive live entry does not replace the fallback names', () async {
      final out = await page({
        'occupants': [
          {'cell': 'memo', 'label': 'Retired name', 'active': false},
        ],
      });
      landed(out, 'memo');
      expect(pressed(out), ['direct', 'section:memo']);
    }, skip: skip);

    test('another cell live label is never borrowed', () async {
      final out = await page({
        'sections': [
          _general,
          {'id': 'other', 'label': 'Other live label'},
        ],
        'occupants': [
          {'cell': 'other', 'label': 'Other live label', 'active': true},
        ],
      });
      missed(out);
      expect(pressed(out), ['direct']);
      expect(out['current'], 'general');
    }, skip: skip);

    test('a shadowed package cannot open the winning owner of the same id', () async {
      final out = await page({
        'open': {
          'settings': 'memo',
          'settingsPackage': '@acme/a',
          'settingsLabels': ['Memo A'],
        },
        'sections': [
          _general,
          {'id': 'memo', 'label': 'Memo B'},
        ],
        'occupants': [
          {'cell': 'memo', 'package': '@acme/a', 'label': 'Memo A', 'active': false},
          {'cell': 'memo', 'package': '@acme/b', 'label': 'Memo B', 'active': true},
        ],
      });
      missed(out);
      expect(pressed(out), ['direct']);
    }, skip: skip);

    test('the requested package can use its live label despite inactive siblings', () async {
      final out = await page({
        'open': {
          'settings': 'memo',
          'settingsPackage': '@acme/a',
          'settingsLabels': ['Old memo'],
        },
        'sections': [_general, _memo],
        'occupants': [
          {'cell': 'memo', 'package': '@acme/b', 'label': 'Other memo', 'active': false},
          {'cell': 'memo', 'package': '@acme/a', 'label': 'Memo', 'active': true},
        ],
      });
      landed(out, 'memo');
    }, skip: skip);

    test('a package target still works on hosts without an occupancy bridge', () async {
      final out = await page({
        'open': {
          'settings': 'memo',
          'settingsPackage': '@acme/a',
          'settingsLabels': ['Memo'],
        },
      });
      landed(out, 'memo');
    }, skip: skip);

    test('unknown attribution uses registered names instead of a foreign live label', () async {
      final out = await page({
        'open': {
          'settings': 'memo',
          'settingsPackage': '@acme/a',
          'settingsLabels': ['Memo'],
        },
        'occupants': [
          {'cell': 'memo', 'package': null, 'label': 'Unknown name', 'active': true},
        ],
      });
      landed(out, 'memo');
    }, skip: skip);

    test('registered labels are normalized and empty names do not match icons', () async {
      final out = await page({
        'open': {
          'settings': 'memo',
          'settingsLabels': ['', '  ', ' Memo  '],
        },
      });
      landed(out, 'memo');
      expect(pressed(out), ['direct', 'section:memo']);
    }, skip: skip);
  });

  group('exact, unique navigation controls', () {
    for (final icon in ['📝', 'M']) {
      test('a text icon ($icon) does not become part of the section label', () async {
        final out = await page({
          'sections': [
            _general,
            {..._memo, 'icon': icon},
          ],
        });
        landed(out, 'memo');
        expect(pressed(out), ['direct', 'section:memo']);
      }, skip: skip);
    }

    test('another section icon matching the label does not count as a second label', () async {
      final out = await page({
        'sections': [
          _general,
          {'id': 'other', 'label': 'Other', 'icon': 'Memo'},
          _memo,
        ],
      });
      landed(out, 'memo');
      expect(pressed(out), ['direct', 'section:memo']);
    }, skip: skip);

    test('an icon alone cannot select a section whose actual label is different', () async {
      final out = await page({
        'sections': [
          _general,
          {'id': 'other', 'label': 'Other', 'icon': 'Memo'},
        ],
      });
      missed(out);
      expect(pressed(out), ['direct']);
    }, skip: skip);

    test('a longer prefix is not the section; matching content is not navigation', () async {
      final out = await page({
        'sections': [
          _general,
          {'id': 'memo-pro', 'label': 'Memo Pro'},
          _memo,
        ],
        'sectionButtons': ['Memo'],
        'outsideButtons': ['Memo'],
      });
      landed(out, 'memo');
      expect(pressed(out), ['direct', 'section:memo']);
    }, skip: skip);

    test('only the prefix and matching content remain: nothing else is pressed', () async {
      final out = await page({
        'sections': [
          _general,
          {'id': 'memo-pro', 'label': 'Memo Pro'},
        ],
        'sectionButtons': ['Memo'],
        'outsideButtons': ['Memo'],
      });
      missed(out);
      expect(pressed(out), ['direct']);
    }, skip: skip);

    test('two nav buttons with the same name are ambiguous', () async {
      final out = await page({
        'sections': [
          _general,
          {'id': 'other', 'label': 'Memo'},
          _memo,
        ],
      });
      missed(out);
      expect(pressed(out), ['direct']);
    }, skip: skip);

    test('another bridge cell sharing the name is ambiguous even without a row', () async {
      final out = await page({
        'occupants': [
          {'cell': 'memo', 'label': 'Memo', 'active': true},
          {'cell': 'other', 'label': 'Memo', 'active': true},
        ],
      });
      missed(out);
      expect(pressed(out), ['direct']);
    }, skip: skip);

    test('a delayed aria-current update must arrive before success', () async {
      final out = await page({'selectMs': 750});
      landed(out, 'memo');
      expect(pressed(out), ['direct', 'section:memo']);
      expect((reports(out).single['at']! as int) - (presses(out).last['at']! as int), greaterThanOrEqualTo(750));
    }, skip: skip);

    test('a click that does not select the section is a failure', () async {
      final out = await page({'ignoreClicks': true});
      missed(out);
      expect(pressed(out), ['direct', 'section:memo']);
      expect(out['current'], 'general');
    }, skip: skip);

    test('a section already current succeeds without an extra click', () async {
      final out = await page({'opened': true, 'active': 'memo'});
      landed(out, 'memo');
      expect(pressed(out), isEmpty);
    }, skip: skip);
  });

  group('bounded lifetime', () {
    for (final type in ['pointerdown', 'keydown']) {
      test('trusted $type stops the pending navigation without a report', () async {
        final out = await page({'sectionsMs': 2000, 'touchAt': 500, 'touchType': type});
        expect(pressed(out), ['direct']);
        expect(presses(out).every((press) => (press['at']! as int) <= 500), isTrue);
        expect(reports(out), isEmpty);
        expect(out['current'], 'general');
      }, skip: skip);
    }

    test('a new open supersedes the old section navigation', () async {
      final out = await page({
        'sectionsMs': 2000,
        'reopenAt': 500,
        'reopen': {'settings': true},
      });
      landed(out, 'general');
      expect(pressed(out), ['direct']);
    }, skip: skip);

    for (final scenario in <String, Map<String, Object?>>{
      'entry': {'entry': 'none'},
      'account item': {'entry': 'account', 'menuMs': null},
      'dialog': {'dialogMs': null},
      'section': {
        'sections': [_general],
      },
    }.entries) {
      test('a missing ${scenario.key} times out with no leaked polls', () async {
        final out = await page(scenario.value);
        missed(out);
        expect(pressed(out), switch (scenario.key) {
          'entry' => isEmpty,
          'account item' => ['account'],
          _ => ['direct'],
        });
      }, skip: skip);
    }
  });
}
