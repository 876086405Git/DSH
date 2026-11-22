import 'package:dsh_client/dsh_client.dart';

import 'companion_notes_peer.dart';

const receiptSpokenExample =
    '等电脑开了，把我选的‘杭州差旅’这四张票整理成日期、项目、金额。'
    '今晚八点前，在这个文件夹新建《差旅小表.xlsx》，原件别动。我先去吃饭。';

/// Controlled App HTTP observations; these values are not a Host FS run.
final receiptsCapability = <String, Object?>{
  ...notesCapability,
  'kinds': ['host.notes_to_todo', 'host.compare_drafts', 'host.receipts_to_sheet'],
  'receiptInputs': {
    'formats': ['md', 'txt', 'pdf'],
    'maxFiles': 4,
    'maxBytes': 4194304,
    'maxPdfPages': 5,
    'workbookBytes': 262144,
  },
};

List<MemoryRow> receiptInputs() => [
  for (var i = 0; i < 4; i++)
    {
      'v': 1,
      'hostStoreId': 'original-store',
      'sourceRef': 'original-receipt-$i',
      'displayName': ['交通.txt', '住宿.md', '车票.pdf', '扫描件.pdf'][i],
      'version': 'original-version-$i',
      'size': 1024,
      'mediaType': ['text/plain', 'text/markdown', 'application/pdf', 'application/pdf'][i],
    },
];

const receiptOutput = <String, Object?>{
  'v': 1,
  'hostStoreId': 'original-store',
  'folderRef': 'selected-output',
  'displayPath': '/本人选的输出',
};

MemoryRow receiptAgreement({List<MemoryRow>? inputs, String name = '差旅小表.xlsx'}) => {
  'args': {
    'inputs': [
      for (final input in inputs ?? receiptInputs()) {'sourceRef': input['sourceRef'], 'version': input['version']},
    ],
    'outputDirRef': receiptOutput['folderRef'],
    'outputName': name,
    'writeMode': 'createNew',
  },
  'deadlineAtMs': null,
  'afterExit': 'continue',
  'allowQueue': true,
};
