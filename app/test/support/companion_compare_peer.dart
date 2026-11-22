import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';

import 'companion_notes_peer.dart';

const compareSpokenExample =
    '这两份是我明天上台的 A 稿和 B 稿。电脑上线就帮我对一遍，'
    '晚上八点前列至多三处最值得重新练的改动。我先去排练，两个原文件都别动。';
final compareCapability = <String, Object?>{
  ...findCapability,
  'kinds': ['host.notes_to_todo', 'host.find_draft', 'host.compare_drafts'],
};

// The ranges are the SDK fixture's actual pure-comparator output. Bindings and
// Host envelopes below are controlled HTTP observations, not a real Host FS or
// model result. The SDK slice owns this one fixture; the App does not copy it.
final _fixture = jsonDecode(
  File('../packages/dsh_client/test/fixtures/companion_compare_draft/comparator-output.json').readAsStringSync(),
) as MemoryRow;

MemoryRow compareInputs({String hostStoreId = 'original-store'}) => {
  for (final side in ['a', 'b'])
    side: {
      'v': 1,
      'hostStoreId': hostStoreId,
      'sourceRef': 'input-$side',
      'displayName': side == 'a' ? 'A.md' : 'B.txt',
      'version': 'bound-version-$side',
      'size': utf8.encode(_fixture[side]! as String).length,
      'mediaType': side == 'a' ? 'text/markdown' : 'text/plain',
    },
};

MemoryRow compareAgreement({bool queue = true, int? deadline, String afterExit = 'continue'}) => {
  'args': {
    for (final side in ['a', 'b']) side: {'sourceRef': 'input-$side', 'version': 'bound-version-$side'},
    'maxHighlights': 3,
  },
  'deadlineAtMs': deadline,
  'afterExit': afterExit,
  'allowQueue': queue,
};

MemoryRow compareReportStep({
  int revision = 1,
  bool advice = true,
  bool identical = false,
  bool changed = false,
  bool published = true,
}) {
  final comparison = _fixture['comparison']! as MemoryRow;
  final inputs = compareInputs();
  final differences = identical ? <Object?>[] : jsonDecode(jsonEncode(comparison['changes'])) as List<Object?>;
  final complete = published && !changed && (identical || advice);
  return {
    'taskRev': revision,
    'stepKey': 'report',
    'attemptId': 'compare-report-$revision',
    'state': complete ? 'done' : 'partial',
    'startedAtMs': 1795219200000,
    'finishedAtMs': 1795219200010,
    'reason': complete
        ? null
        : !published
        ? 'report_not_published'
        : changed
        ? 'original_changed'
        : 'model_unavailable',
    'result': {
      'completion': {
        'sources': [
          for (final side in ['a', 'b'])
            {
              'side': side,
              for (final key in ['sourceRef', 'version', 'displayName', 'mediaType', 'size'])
                key: (inputs[side]! as MemoryRow)[key],
              'readComplete': true,
              'verifiedAtPublish': side == 'a' || !changed,
              'reason': side == 'b' && changed ? 'original_changed' : null,
            },
        ],
        'coverage': {
          'aComplete': true,
          'bComplete': true,
          'comparisonComplete': true,
          'totalChangeGroups': identical ? 0 : comparison['totalChanges'],
          'displayedChangeGroups': differences.length,
          'algorithm': comparison['algorithm'],
          'gaps': [
            if (changed) {'side': 'b', 'reason': 'original_changed'},
            if (!advice && !identical) {'side': null, 'reason': 'model_unavailable'},
          ],
        },
        'identical': identical,
        'differences': differences,
        'selection': identical
            ? 'none'
            : advice
            ? 'model'
            : 'source_order',
        'suggestions': {
          'status': identical
              ? 'not_needed'
              : advice
              ? 'available'
              : 'unavailable',
          'reason': identical || advice ? null : 'model_unavailable',
          'items': [
            if (advice && !identical)
              for (final difference in differences)
                {'differenceId': (difference! as MemoryRow)['id'], 'practice': '可以重练这一处的停顿。'},
          ],
        },
        'published': published,
      },
    },
  };
}
