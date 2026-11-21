import 'dart:convert';

import 'package:dsh_client/companion.dart';

// Synthetic Host envelopes for structural/SQLite tests. These are not outputs
// from the receipt parser, an actual Host runner, or a PDF extractor.
const receiptTime = 1795219200000;
const workbookMediaType = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

MemoryRow receiptCopy(MemoryRow value) => jsonDecode(jsonEncode(value)) as MemoryRow;

List<MemoryRow> receiptBindings({String store = 'original-store', String suffix = ''}) => [
  for (var index = 0; index < 4; index++)
    {
      'v': 1,
      'hostStoreId': store,
      'sourceRef': 'receipt-${index + 1}$suffix',
      'version': 'original-version-${index + 1}$suffix',
      'displayName': index < 2 ? '${index + 1}.txt' : '${index + 1}.pdf',
      'mediaType': index < 2 ? 'text/plain' : 'application/pdf',
      'size': 128,
    },
];

MemoryRow receiptOutput({String store = 'original-store', String ref = 'original-output'}) => {
  'v': 1,
  'hostStoreId': store,
  'folderRef': ref,
  'displayPath': '/chosen/output',
};

MemoryRow receiptAgreement({
  List<MemoryRow>? inputs,
  MemoryRow? output,
  bool allowQueue = true,
  String afterExit = 'continue',
  int? deadline,
}) => {
  'args': {
    'inputs': [
      for (final input in inputs ?? receiptBindings()) {'sourceRef': input['sourceRef'], 'version': input['version']},
    ],
    'outputDirRef': (output ?? receiptOutput())['folderRef'],
    'outputName': '差旅小表.xlsx',
    'writeMode': 'createNew',
  },
  'deadlineAtMs': deadline,
  'afterExit': afterExit,
  'allowQueue': allowQueue,
};

MemoryRow receiptReport({List<MemoryRow>? inputs, Set<int> unread = const {}, bool verifiedAtPublish = true}) {
  final selected = inputs ?? receiptBindings();
  return {
    'sources': [
      for (var index = 0; index < 4; index++)
        {
          for (final key in ['sourceRef', 'version', 'displayName', 'mediaType', 'size']) key: selected[index][key],
          'readComplete': !unread.contains(index),
          'parseComplete': !unread.contains(index),
          'textLayerOnly': selected[index]['mediaType'] == 'application/pdf',
          'verifiedAtPublish': verifiedAtPublish && !unread.contains(index),
          'pageCount': selected[index]['mediaType'] == 'application/pdf' && !unread.contains(index) ? 1 : null,
          'reason': unread.contains(index) ? 'read_unavailable' : null,
        },
    ],
    'rows': [
      for (var index = 0; index < 4; index++)
        {
          'sourceRef': selected[index]['sourceRef'],
          'version': selected[index]['version'],
          for (final name in ['date', 'item', 'amount'])
            name: {
              'state': unread.contains(index) ? 'unverified' : 'verified',
              'value': unread.contains(index)
                  ? null
                  : switch (name) {
                      'date' => '2026-11-21',
                      'item' => '火车票',
                      _ => 'CNY 128.00',
                    },
              'evidence': unread.contains(index)
                  ? null
                  : {
                      'page': selected[index]['mediaType'] == 'application/pdf' ? 1 : null,
                      'lineStart': 1,
                      'lineEnd': 1,
                      'quote': '合成 $name 原文证据',
                    },
              'reason': unread.contains(index) ? 'source_unread' : null,
            },
        },
    ],
    'coverage': {
      'inputCount': 4,
      'readCompleteCount': 4 - unread.length,
      'parseCompleteCount': 4 - unread.length,
      'rowsWithVerifiedFields': 4 - unread.length,
      'fullyVerifiedRows': 4 - unread.length,
      'gaps': [
        for (final index in unread)
          for (final field in ['read', 'parse', 'date', 'item', 'amount'])
            {
              'sourceRef': selected[index]['sourceRef'],
              'version': selected[index]['version'],
              'field': field,
              'reason': ['read', 'parse'].contains(field) ? 'read_unavailable' : 'source_unread',
            },
      ],
    },
  };
}

MemoryRow receiptArtifact({
  int revision = 1,
  String id = 'original-artifact',
  int size = 128,
  String hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
}) => {
  'artifactId': id,
  'taskRev': revision,
  'stepKey': 'writeSheet',
  'relativePath': '差旅小表.xlsx',
  'mediaType': workbookMediaType,
  'size': size,
  'sha256': hash,
  'verifiedAtMs': receiptTime,
  'sourceCount': 4,
};

MemoryRow receiptSnapshot(
  CompanionMemoryStore store,
  String id, {
  int revision = 1,
  int seq = 1,
  String state = 'running',
  bool original = true,
  Map<int, MemoryRow> readReports = const {},
  Map<int, MemoryRow> writeReports = const {},
  List<MemoryRow> artifacts = const [],
  List<MemoryRow> extraSteps = const [],
  String? reason,
}) {
  final commands = store.hostTaskCommands(id);
  final first = commands.first['request']! as MemoryRow;
  MemoryRow? plan(MemoryRow command) {
    final request = command['request']! as MemoryRow;
    return switch (command['operation']) {
      'create' => {
        for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: request[key],
      },
      'amend' => Map<String, Object?>.from(request['changes']! as MemoryRow),
      _ => null,
    };
  }

  final revisions = commands
      .where((command) => (command['task_rev']! as int) <= revision && (original || command['operation'] != 'create'))
      .toList();
  return {
    'v': 1,
    'hostStoreId': 'original-store',
    'taskId': id,
    'hostExecutionId': 'original-execution',
    'kind': 'host.receipts_to_sheet',
    'taskRev': revision,
    'runnerReceiptSeq': seq,
    'originalCreatePresent': original,
    'origin': original ? first['origin'] : null,
    'hostSessionId': null,
    'state': state,
    'waitReason': reason ?? (original ? null : 'original_create_missing'),
    'cancelRequested': revisions.last['operation'] == 'cancel',
    'createdAtMs': receiptTime,
    'updatedAtMs': receiptTime,
    'agreement': revisions.reversed.map(plan).whereType<MemoryRow>().firstOrNull,
    'revisions': [
      for (final command in revisions)
        {
          'taskRev': command['task_rev'],
          'operation': command['operation'],
          'acceptedAtMs': receiptTime,
          'agreement': plan(command),
        },
    ],
    'steps': [
      for (final entry in readReports.entries)
        {
          'taskRev': entry.key,
          'stepKey': 'readInputs',
          'attemptId': 'read-${entry.key}',
          'state': 'done',
          'startedAtMs': receiptTime,
          'finishedAtMs': receiptTime,
          'reason': null,
          'result': {
            'completion': {'report': entry.value},
          },
        },
      for (final entry in writeReports.entries)
        {
          'taskRev': entry.key,
          'stepKey': 'writeSheet',
          'attemptId': 'write-${entry.key}',
          'state':
              (entry.value['coverage']! as MemoryRow)['fullyVerifiedRows'] == 4 &&
                  (entry.value['sources']! as List<Object?>).every(
                    (source) => (source! as MemoryRow)['verifiedAtPublish'] == true,
                  )
              ? 'done'
              : 'partial',
          'startedAtMs': receiptTime,
          'finishedAtMs': receiptTime,
          'reason': null,
          'result': {
            'completion': {
              'artifactId': artifacts.singleWhere((artifact) => artifact['taskRev'] == entry.key)['artifactId'],
              'report': entry.value,
            },
          },
        },
      ...extraSteps,
    ],
    'artifacts': artifacts,
    'approval': null,
    'budget': {'limitMs': 300000, 'spentMs': 120, 'heldMs': 0},
  };
}
