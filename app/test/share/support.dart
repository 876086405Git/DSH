// Sample content and a bare harness for the share-card tests.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/share_code/plugin_share.dart' show pluginShareWebLink;
import 'package:dsh_app/share_code/share_models.dart' show PluginSourceKind, SharedPlugin;
import 'package:dsh_app/state/attachments.dart' show sessionImageProvider;
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/share/share_card.dart';
import 'package:dsh_app/ui/share/share_content.dart';
import 'package:dsh_app/ui/share/share_export.dart';
import 'package:dsh_app/ui/share/share_gallery.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show loadTestFonts;

const sampleTitle = '修复登录按钮重复提交';
const sampleQuestion = '登录按钮连点会提交两次，帮我看看 login_controller.dart 怎么改？';

const sampleAnswer = r'''问题在 `submit()` 没有防重入：第一次请求还没回来，第二次点击又进来了。

加一个 `_submitting` 标记，请求期间直接返回，按钮同时置灰：

```dart
Future<void> submit() async {
  if (_submitting) return;
  _submitting = true;
  try {
    await api.login(username.text, password.text, rememberMe: remember.value);
  } finally {
    _submitting = false;
  }
}
```

| 方案 | 优点 | 缺点 |
|---|---|---|
| 标记位 | 简单直接 | 要记得复位 |
| 防抖 | 通用 | 有 300ms 延迟 |

两次点击间隔 $\Delta t < 0.3$ 秒时只算一次。''';

/// What the sample turn did.
const sampleProcess = [
  ShareProcessItem('查看文件', 4, tool: 'read'),
  ShareProcessItem('修改文件', 2, tool: 'edit'),
  ShareProcessItem('运行命令', 1, tool: 'bash'),
];

ShareContent sampleReplyContent() => ShareContent(
  title: sampleTitle,
  blocks: [const ShareQuestion(sampleQuestion), ShareAnswer(shareMarkdown(sampleAnswer))],
  model: 'deepseek-v4-pro',
  stats: '53 秒 · 8 步',
  process: sampleProcess,
);

/// A reply longer than the old one-card truncation budget.
String longAnswer() =>
    [for (var i = 1; i <= 24; i++) '$i. 第 $i 步：检查 `step_$i.dart` 里的状态机，确认每个分支在出错时都会把按钮恢复成可点状态，并补一条对应的单元测试。']
        .join('\n\n');

ShareContent sampleLongContent() => ShareContent(
  title: '把整个登录流程梳理一遍',
  blocks: [const ShareQuestion('从头到尾梳理一下登录流程，列出每一步要检查的点。'), ShareAnswer(shareMarkdown(longAnswer()))],
  model: 'deepseek-v4-pro',
  stats: '2 分 14 秒 · 21 步',
);

const samplePlugin = SharePlugin(
  name: '@dshfind/dsh-plugin-novel-writer',
  title: '小说写作助手',
  author: 'dshfind',
  description: '大纲、人物卡、章节续写和润色，一套写长篇的工作流。支持把设定存进工作区，下次打开接着写。',
  facts: [('128', '星标'), ('1.4.2', '版本'), ('2026.10.12', '更新')],
);

/// [samplePlugin]'s share-code landing link, as a plugin card carries it
/// (`pluginCardContent`): the whole plugin inline, 400-odd bytes.
String samplePluginLink() => pluginShareWebLink(
  const SharedPlugin(
    name: '@dshfind/dsh-plugin-novel-writer',
    source: PluginSourceKind.npm,
    spec: '@dshfind/dsh-plugin-novel-writer@1.4.2',
    version: '1.4.2',
    title: '小说写作助手',
    author: 'dshfind',
    summary: '大纲、人物卡、章节续写和润色，一套写长篇的工作流。支持把设定存进工作区，下次打开接着写。',
  ),
)!;

/// A widget test whose shadows are drawn soft, as on a phone (tests draw
/// them hard by default). Painters cache their shadow paints, so the switch
/// is thrown before anything is drawn and put back before the test ends.
void softShadowTest(String name, Future<void> Function(WidgetTester tester) body, {bool? skip}) {
  testWidgets(name, (tester) async {
    debugDisableShadows = false;
    try {
      await body(tester);
    } finally {
      debugDisableShadows = true;
    }
  }, skip: skip);
}

// ── Pumping a card ──────────────────────────────────────────────────────────

/// The [RepaintBoundary] around a card pumped by [pumpShareCard].
const shareCardKey = ValueKey('card');

Future<void> pumpShareCard(
  WidgetTester tester,
  ShareCard card, {
  List<Override> overrides = const [],
  double textScale = 1,
  AppAccent accent = AppAccent.mist,
  Key boundary = shareCardKey,
  bool settle = true,
}) async {
  await tester.runAsync(loadTestFonts);
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(ShareCard.width * 2, 4800 * 2);
  addTearDown(tester.view.reset);
  // A fresh scope for every card (a test may draw several).
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(accent: accent),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topLeft,
            child: ShareCaptureBoundary(key: boundary, child: card),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  if (settle) await settleShareImages(tester);
}

/// Lets the card's pictures decode (real async work), pumping in between.
Future<void> settleShareImages(WidgetTester tester) async {
  final context = tester.element(find.byType(ShareCard));
  for (var i = 0; i < 60 && shareImagesPending(context) > 0; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
  expect(shareImagesPending(context), 0, reason: 'every picture is in or given up on');
  await tester.pump();
}

/// Photos for the picture cards, made once per test.
Future<List<Uint8List>> photos(WidgetTester tester) async => (await tester.runAsync(
  () => Future.wait([
    samplePhoto(1200, 900, seed: 0),
    samplePhoto(900, 1200, seed: 1),
    samplePhoto(1200, 800, seed: 2),
    samplePhoto(1000, 1000, seed: 3),
    samplePhoto(1280, 720, seed: 4),
    samplePhoto(800, 1000, seed: 5),
  ]),
))!;

/// Attachments `p0`… of conversation `s1`, served from [bytes].
Override attachmentsFrom(List<Uint8List> bytes) => sessionImageProvider.overrideWith((ref, key) async {
  final (sessionId, attachment) = key;
  final id = attachment.attachmentId;
  if (sessionId != 's1' || !id.startsWith('p')) throw StateError('gone');
  return bytes[int.parse(id.substring(1))];
});

// ── Pictures ────────────────────────────────────────────────────────────────

/// A small landscape "photo" drawn in code: a sky, a sun, two hills. [seed]
/// picks the palette. Call inside `tester.runAsync`.
Future<Uint8List> samplePhoto(int width, int height, {int seed = 0}) async {
  const palettes = [
    (Color(0xFF9CC3F5), Color(0xFFF6D6B8), Color(0xFF5E8C6A), Color(0xFF3F6B55), Color(0xFFFFF1C9)),
    (Color(0xFF2B3A67), Color(0xFFE58F65), Color(0xFF4B4E6D), Color(0xFF2D2F45), Color(0xFFFFD4A3)),
    (Color(0xFFBFE3E0), Color(0xFFF3F1E7), Color(0xFF7FB3A8), Color(0xFF4F8A80), Color(0xFFFFFFFF)),
    (Color(0xFFF2C6C2), Color(0xFFFBE7D3), Color(0xFFB98B8B), Color(0xFF8C6464), Color(0xFFFFF6E8)),
    (Color(0xFFC9D6F2), Color(0xFFEEF1FA), Color(0xFF8E9CC4), Color(0xFF5D6B96), Color(0xFFFFFFFF)),
  ];
  final (skyTop, skyBottom, hillFar, hillNear, sun) = palettes[seed % palettes.length];
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final w = width.toDouble(), h = height.toDouble();
  final rect = Rect.fromLTWH(0, 0, w, h);
  canvas.drawRect(rect, Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(0, h), [skyTop, skyBottom]));
  canvas.drawCircle(
    Offset(w * (0.25 + 0.5 * ((seed * 37) % 10) / 10), h * 0.34),
    math.min(w, h) * 0.11,
    Paint()..color = sun,
  );
  Path hill(double base, double amp, double phase) {
    final path = Path()..moveTo(0, h);
    for (var x = 0.0; x <= w; x += w / 40) {
      path.lineTo(x, h * base - amp * h * math.sin(x / w * math.pi * 1.6 + phase));
    }
    return path
      ..lineTo(w, h)
      ..close();
  }

  canvas.drawPath(hill(0.66, 0.10, seed.toDouble()), Paint()..color = hillFar);
  canvas.drawPath(hill(0.80, 0.07, seed + 2.0), Paint()..color = hillNear);
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// [bytes] as a Markdown picture.
String dataImage(Uint8List bytes) => '![](data:image/png;base64,${base64Encode(bytes)})';

// ── A finished conversation ─────────────────────────────────────────────────

final _t0 = DateTime(2026, 10, 24, 15, 30);

TraceSpan _tool(String name, int step, int seq) =>
    TraceSpan(kind: TraceKind.tool, step: step, seq: seq, start: _t0, end: _t0, toolName: name);

/// Two exchanges; the first turn took 53 s over 8 model steps, reading four
/// files, editing two and running one command.
ChatState shareChatState() {
  final items = <ChatItem>[
    UserChatItem(seq: 1, time: _t0, text: sampleQuestion, images: const [], files: const []),
    AssistantChatItem(id: 'a10', seq: 10, text: sampleAnswer, reasoning: '', model: 'deepseek-v4-pro'),
    UserChatItem(
      seq: 11,
      time: _t0,
      text: '顺便把按钮置灰也加上，token 是 sk-test1234567890abcdef',
      images: const [],
      files: const [],
    ),
    const AssistantChatItem(id: 'a14', seq: 14, text: '加好了：请求期间 `onPressed` 为 null，按钮自动置灰。', reasoning: ''),
  ];
  return ChatState(
    items: items,
    title: sampleTitle,
    loading: false,
    turns: [
      TurnTrace(
        turn: 1,
        startSeq: 1,
        start: _t0,
        end: _t0.add(const Duration(seconds: 53)),
        endSeq: 10,
        spans: [
          for (var i = 0; i < 8; i++)
            TraceSpan(kind: TraceKind.model, step: i + 1, seq: 2 + i, start: _t0, end: _t0, model: 'deepseek-v4-pro'),
          _tool('read', 1, 2),
          _tool('grep', 1, 3),
          _tool('read', 2, 4),
          _tool('todo_write', 2, 4),
          _tool('read', 3, 5),
          _tool('edit', 4, 6),
          _tool('edit', 5, 7),
          _tool('bash', 6, 8),
        ],
      ),
    ],
  );
}

AssistantChatItem firstReply(ChatState state) => state.items.whereType<AssistantChatItem>().first;
