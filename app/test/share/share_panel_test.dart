// The share panel (「分享」): goldens of its pages, the scope and privacy choices
// driving every way out (card, file, link, text), a link's life (make, copy, QR,
// share, stop, undo), the three file forms, large text and narrow phones, and
// the symmetry of every row.
//
//   flutter test --update-goldens test/share/share_panel_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/share_code/conversation_share.dart';
import 'package:dsh_app/state/artifacts.dart' show FilesChannel;
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/common/segmented_pill.dart';
import 'package:dsh_app/ui/replay/conversation_out.dart';
import 'package:dsh_app/ui/replay/replay_page.dart';
import 'package:dsh_app/ui/share/share_card.dart';
import 'package:dsh_app/ui/share/share_content.dart';
import 'package:dsh_app/ui/share/share_export.dart';
import 'package:dsh_app/ui/share/share_image_page.dart';
import 'package:dsh_app/ui/share/share_panel.dart';
import 'package:dsh_app/ui/share/share_panel_pages.dart';
import 'package:dsh_app/ui/share/share_picker.dart';
import 'package:dsh_app/ui/share_code/share_code_panel.dart' show ShareQrPage;
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show AsyncData, ProviderScope;
import 'package:dsh_app/state/android_features.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

import '../chat/support/harness.dart';
import '../replay/support/conversation_fixture.dart';
import '../support/english_preview.dart';
import 'support.dart';

// ── Fakes ───────────────────────────────────────────────────────────────────

class _Exporter extends ShareExporter {
  _Exporter(Directory dir)
    : super(files: const FilesChannel(), cacheRoot: () async => dir, clock: () => DateTime(2026, 10, 24, 15, 30, 12));

  final shared = <ShareParams>[];
  final saved = <File>[];
  Object? saveError;

  @override
  Future<void> share(File image, {String? text}) async =>
      shared.add(ShareParams(files: [XFile(image.path)], text: text));

  @override
  Future<String> save(File image) async {
    if (saveError case final error?) throw error;
    saved.add(image);
    return 'Download/DSH-Go/${image.uri.pathSegments.last}';
  }
}

class _Out extends ConversationOut {
  _Out(Directory dir) : super(files: const FilesChannel(), cacheRoot: () async => dir);

  final shared = <(File, ConversationFormat)>[];
  final saved = <(File, ConversationFormat)>[];
  final texts = <String>[];
  Object? saveError;

  @override
  Future<void> shareFile(File file, ConversationFormat format) async => shared.add((file, format));

  @override
  Future<void> shareText(String text) async => texts.add(text);

  @override
  Future<String> save(String name, String content, ConversationFormat format) async {
    if (saveError case final error?) throw error;
    final file = await write(name, content);
    saved.add((file, format));
    return 'Download/DSH-Go/${file.uri.pathSegments.last}';
  }
}

class _Links implements ConversationLinkMaker {
  final uploads = <(Uint8List, LinkExpiry, String)>[];
  final revoked = <String>[];
  final restored = <String>[];
  bool fail = false;
  bool unsaved = false;
  bool undoUnsaved = false;

  @override
  Future<ConversationLink> upload(Uint8List fileBytes, LinkExpiry expiry, {required String title}) async {
    if (fail) throw const SocketException('offline');
    uploads.add((fileBytes, expiry, title));
    return ConversationLink(
      url: Uri.parse('https://go.example.cn/c/a1B2c3D4e5#k=${'K' * 43}'),
      expiresAt: expiry == LinkExpiry.forever ? null : DateTime.utc(2026, 11, 24, 12),
      id: 'a1B2c3D4e5',
      locallySaved: !unsaved,
    );
  }

  @override
  Future<void> revoke(ConversationLink link) async {
    if (fail) throw StateError('controlled failure');
    revoked.add(link.id!);
  }

  @override
  Future<void> restore(ConversationLink link) async {
    if (fail) throw StateError('controlled failure');
    if (undoUnsaved) throw const ConversationLinkRestoreUnsaved();
    restored.add(link.id!);
  }

  @override
  Duration get undoWindow => const Duration(seconds: 4);
}

/// A conversation with a durable log (todos, goals, times of notices).
class _Chat extends FakeChatController {
  _Chat(super.sessionId, super.initial, this.log);

  final List<SessionLogEvent> log;

  @override
  Iterable<SessionLogEvent> get events => log;
}

class _Panel {
  _Panel(this.exporter, this.out, this.links);

  final _Exporter exporter;
  final _Out out;
  final _Links links;
}

/// The two-turn conversation of the export tests, as the chat holds it.
ChatState _fixture() =>
    ChatState(items: fixtureItems, turns: fixtureTurns, commands: fixtureCommands, title: '修复登录重复提交', loading: false);

AssistantChatItem _reply(ChatState state, String id) =>
    state.items.whereType<AssistantChatItem>().firstWhere((r) => r.id == id);

/// Opens the panel on [state] (default: the share-card sample), from the
/// reply [reply] (`first`: its first reply; null: from the drawer).
Future<_Panel> _open(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  ChatState? state,
  String? reply = 'first',
  ShareScope? scope,
  bool links = true,
  double textScale = 1,
  Size? size,
  String? operatingSystem,
}) async {
  await tester.runAsync(loadTestFonts);
  usePhoneView(tester);
  if (size != null) tester.view.physicalSize = size * 2;
  if (textScale != 1) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  ShareCardStyle.lastTemplate = null;
  final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('share-panel')))!;
  addTearDown(() => dir.deleteSync(recursive: true));
  final panel = _Panel(_Exporter(dir), _Out(dir), _Links());
  final chat = state ?? shareChatState();
  final anchor = switch (reply) {
    null => null,
    'first' => firstReply(chat),
    final id => _reply(chat, id),
  };
  // A fresh app for every open (a test may open twice).
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    testApp(
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            // No ink and no visible text: nothing shows through the glass sheet.
            child: GestureDetector(
              onTap: () => showAppSheet<void>(
                context,
                dismissal: SheetDismissal.drag,
                heightFactor: 0.92,
                builder: (_) => SharePanel(
                  subject: ConversationSubject(sessionId: 's1', reply: anchor),
                  scope: scope,
                  clock: () => DateTime.utc(2026, 10, 25, 3),
                  loadImage: (_) async => tinyPng,
                ),
              ),
              child: const Text('open', style: TextStyle(color: Colors.transparent)),
            ),
          ),
        ),
      ),
      brightness: brightness,
      overrides: [
        if (operatingSystem != null) operatingSystemProvider.overrideWithValue(operatingSystem),
        settingsProvider.overrideWith(() => TestSettings()),
        // No engine: pictures in replies give up at once.
        activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
        localConnectionProvider.overrideWith(NoLocalEngine.new),
        localRuntimeProvider.overrideWith(StaticRuntime.new),
        shareExporterProvider.overrideWithValue(panel.exporter),
        conversationOutProvider.overrideWithValue(panel.out),
        conversationLinkMakerProvider.overrideWithValue(links ? panel.links : null),
        chatProvider.overrideWith2((id) => _Chat(id, chat, state == null ? const [] : fixtureEvents)),
      ],
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return panel;
}

/// Lets real async work (pictures shrunk, files written, PNGs encoded) run,
/// pumping frames in between until nothing is busy.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 16));
    if (i > 4 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await _settle(tester);
}

Future<void> _key(WidgetTester tester, String key) => _tap(tester, find.byKey(ValueKey(key)));

Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.byTooltip('返回'));
  await tester.pumpAndSettle();
}

// The undo checks need no image decoding or real-time settling.
ChatState _undoFixture() {
  final state = _fixture();
  return ChatState(
    items: [
      for (final item in state.items)
        if (item is UserChatItem)
          UserChatItem(seq: item.seq, time: item.time, text: item.text, images: const [], files: item.files)
        else
          item,
    ],
    turns: state.turns,
    commands: state.commands,
    title: state.title,
    loading: state.loading,
  );
}

Future<void> _tapAndPump(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

ShareCard _card(WidgetTester tester) => tester.widget<ShareCard>(find.byType(ShareCard));

String _summary(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('share-summary'))).data!;

String _status(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('share-status'))).data!;

ConversationShare _decode(String text) => decodeConversationFile(text).share;

/// [text] is drawn whole: not cut, not past the screen's edges.
void _expectWhole(WidgetTester tester, String text) {
  final finder = find.text(text);
  expect(finder, findsWidgets, reason: text);
  for (final element in finder.evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    expect(paragraph.didExceedMaxLines, isFalse, reason: '「$text」 is cut');
    final rect = tester.getRect(find.byElementPredicate((e) => e == element));
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(rect.left, greaterThanOrEqualTo(-0.5), reason: '「$text」 past the left edge');
    expect(rect.right, lessThanOrEqualTo(screen.width + 0.5), reason: '「$text」 past the right edge');
  }
}

void main() {
  _selectionTests();
  _wholeScopeAfterUpdateTests();
  // ── Goldens ───────────────────────────────────────────────────────────────

  for (final brightness in Brightness.values) {
    final mode = brightness.name;
    testWidgets('golden: the first page ($mode)', (tester) async {
      await _open(tester, brightness: brightness);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/share_panel_$mode.png'));
    });

    testWidgets('golden: 图片 ($mode)', (tester) async {
      await _open(tester, brightness: brightness);
      await _key(tester, 'share-to-image');
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/share_image_$mode.png'));
    });
  }

  testWidgets('golden: the first page (en)', (tester) async {
    useEnglish();
    await _open(tester);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/en_share_panel_light.png'));
  });

  testWidgets('golden: 链接 before and after it is made', (tester) async {
    await _open(tester, state: _fixture(), reply: 'a6');
    await _key(tester, 'share-to-link');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/share_link_light.png'));
    await _key(tester, 'share-link-make');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/share_link_ready_light.png'));
  });

  testWidgets('golden: 文件', (tester) async {
    await _open(tester, state: _fixture(), reply: 'a6', scope: ShareScope.whole);
    await _key(tester, 'share-to-file');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/share_file_light.png'));
  });

  // ── Scope and privacy ─────────────────────────────────────────────────────

  testWidgets('the scope drives the preview; 选中消息 picks, 调整 changes the picks', (tester) async {
    await _open(tester);
    expect(_card(tester).content.blocks, hasLength(2));
    expect(_summary(tester), '2 条消息 · 密钥已隐藏');
    expect(find.byKey(const ValueKey('share-adjust')), findsNothing);

    await _tap(tester, find.text('整段对话'));
    expect(_card(tester).content.blocks, hasLength(4));
    expect(_summary(tester), '4 条消息 · 密钥已隐藏');

    await _tap(tester, find.text('选中消息'));
    expect(find.byType(MessagePicker), findsOneWidget);
    expect(find.text('完成（2）'), findsOneWidget, reason: 'the reply and its question to start with');
    expect(find.byTooltip('关闭'), findsNothing);
    await tester.tap(find.textContaining('顺便把按钮置灰'));
    await tester.tap(find.textContaining('加好了'));
    await tester.pump();
    await _tap(tester, find.text('完成（4）'));
    expect(find.byType(MessagePicker), findsNothing);
    final pill = tester.widget<SegmentedPill<ShareScope>>(find.byType(SegmentedPill<ShareScope>));
    expect(pill.selected, ShareScope.picked);
    expect(_card(tester).content.blocks, hasLength(4));

    await _key(tester, 'share-adjust');
    expect(find.text('完成（4）'), findsOneWidget, reason: 'the picks so far');
    await tester.tap(find.textContaining('登录按钮连点'));
    await tester.pump();
    await _tap(tester, find.text('完成（3）'));
    expect(_card(tester).content.blocks.map((b) => b.runtimeType), [ShareAnswer, ShareQuestion, ShareAnswer]);
    expect(_summary(tester), '3 条消息 · 密钥已隐藏');

    // Back to the reply: its two messages again.
    await _tap(tester, find.text('这条回复'));
    expect(_card(tester).content.blocks, hasLength(2));
  });

  testWidgets('from the drawer: no 这条回复, the whole conversation first', (tester) async {
    await _open(tester, reply: null);
    final pill = tester.widget<SegmentedPill<ShareScope>>(find.byType(SegmentedPill<ShareScope>));
    expect([for (final s in pill.segments) s.label], ['选中消息', '整段对话']);
    expect(pill.selected, ShareScope.whole);
    expect(_card(tester).content.blocks, hasLength(4));
    await _tap(tester, find.text('选中消息'));
    expect(find.text('完成（2）'), findsOneWidget, reason: 'the last exchange to start with');
  });

  testWidgets('privacy capsules change the card at once', (tester) async {
    await _open(tester, state: _fixture(), reply: 'a6');
    var card = _card(tester).content;
    final question = card.blocks.first as ShareQuestion;
    expect(question.text, startsWith('帮我看看 ~/code/app'), reason: 'home folders go as on a file');
    expect(question.text, isNot(contains('abcdefghij0123456789')));
    expect(question.images, hasLength(1));
    expect((card.blocks.last as ShareAnswer).markdown, contains('![](/root/workspace/shot.png)'));
    expect(_summary(tester), '2 条消息 · 1 次工具调用 · 1 张图片 · 密钥已隐藏');

    await _tap(tester, find.byKey(const ValueKey('share-toggle-图片')));
    card = _card(tester).content;
    expect((card.blocks.first as ShareQuestion).images, isEmpty);
    expect((card.blocks.last as ShareAnswer).markdown, contains('〔截图〕'));
    expect(_summary(tester), '2 条消息 · 1 次工具调用 · 密钥已隐藏');

    await _open(tester);
    expect(find.byKey(const ValueKey('share-process')), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('share-toggle-工具调用')));
    expect(_card(tester).content.process, isEmpty);
    expect(find.byKey(const ValueKey('share-process')), findsNothing);
    expect(find.byKey(const ValueKey('share-toggle-check-工具调用')), findsNothing);
  });

  testWidgets('privacy reaches the file, the link and the text alike', (tester) async {
    final panel = await _open(tester, state: _fixture(), reply: 'a6', scope: ShareScope.whole);

    await _key(tester, 'share-to-file');
    await _key(tester, 'share-file-send');
    var file = decodeConversationFile(panel.out.shared.last.$1.readAsStringSync());
    expect(file.share.entries.whereType<ToolEntry>(), isNotEmpty);
    expect(file.share.entries.whereType<ReplyEntry>().any((r) => r.thinking != null), isTrue);
    expect(file.assets, hasLength(1));
    await _back(tester);

    for (final label in ['思考过程', '工具调用', '图片']) {
      await _tap(tester, find.byKey(ValueKey('share-toggle-$label')));
    }
    expect(_summary(tester), '5 条消息 · 密钥已隐藏');

    void quiet(ConversationShare share, {required String why}) {
      expect(share.entries.whereType<ToolEntry>(), isEmpty, reason: why);
      expect(share.entries.whereType<TodosEntry>(), isEmpty, reason: why);
      expect(share.entries.whereType<GoalEntry>(), isEmpty, reason: why);
      expect(share.entries.whereType<ReplyEntry>().every((r) => r.thinking == null), isTrue, reason: why);
      expect(share.images, isEmpty, reason: why);
      expect(share.toJson()['include'], {'thinking': false, 'tools': false}, reason: why);
    }

    await _key(tester, 'share-to-file');
    await _key(tester, 'share-file-send');
    file = decodeConversationFile(panel.out.shared.last.$1.readAsStringSync());
    quiet(file.share, why: 'file');
    expect(file.assets, isEmpty);
    await _back(tester);

    await _key(tester, 'share-to-link');
    await _key(tester, 'share-link-make');
    quiet(_decode(utf8.decode(panel.links.uploads.single.$1)), why: 'link');
    await _back(tester);

    await _key(tester, 'share-to-text');
    final text = panel.out.texts.single;
    expect(text, startsWith('# 修复登录重复提交'));
    expect(text, isNot(contains('npm test')), reason: 'no tool lines');
    expect(text, isNot(contains(secret)));
    expect(text, isNot(contains('/home/user')));
  });

  testWidgets('文字 on a reply: its own words, redacted; pictures as alt text when left out', (tester) async {
    final panel = await _open(tester, state: _fixture(), reply: 'a6');
    await _key(tester, 'share-to-text');
    expect(panel.out.texts.last, startsWith('登录测试挂在重复提交上。看图：![截图](/root/workspace/shot.png)'));
    expect(panel.out.texts.last, isNot(contains('dsh-ui')), reason: 'a visual reply as its one line');
    await _tap(tester, find.byKey(const ValueKey('share-toggle-图片')));
    await _key(tester, 'share-to-text');
    expect(panel.out.texts.last, startsWith('登录测试挂在重复提交上。看图：〔截图〕'));
  });

  // ── 链接 ──────────────────────────────────────────────────────────────────

  testWidgets('链接: 30 天 by default, the reply uploaded, copy / QR / share, stop and undo', (tester) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
      return null;
    });
    final panel = await _open(tester, state: _fixture(), reply: 'a6');
    await _key(tester, 'share-to-link');
    expect(find.text('端到端加密，服务器看不到内容'), findsOneWidget);
    expect(tester.widget<SegmentedPill<LinkExpiry>>(find.byType(SegmentedPill<LinkExpiry>)).selected, LinkExpiry.month);
    expect(find.byTooltip('关闭'), findsNothing);
    await _tap(tester, find.text('永久'));
    await _key(tester, 'share-link-make');
    final (bytes, expiry, title) = panel.links.uploads.single;
    expect(expiry, LinkExpiry.forever);
    expect(title, '修复登录重复提交');
    final uploaded = decodeConversationFile(utf8.decode(bytes));
    expect(uploaded.share.entries.map((e) => e.type), ['turn', 'user', 'tool', 'todos', 'reply']);
    expect(uploaded.share.range, (from: 1, to: 1, of: 2));
    expect(uploaded.assets, hasLength(1));
    expect(find.text('go.example.cn/c/a1B2c3D4e5'), findsOneWidget);
    expect(find.text('永久有效'), findsOneWidget);

    await _key(tester, 'share-link-copy');
    expect(clipboard, startsWith('https://go.example.cn/c/a1B2c3D4e5#k='));
    expect(find.text('已复制'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));

    await _key(tester, 'share-link-share');
    expect(panel.out.texts.single, contains('「修复登录重复提交」'));
    expect(panel.out.texts.single, contains('https://go.example.cn/c/'));

    await _key(tester, 'share-link-qr');
    expect(find.byType(ShareQrPage), findsOneWidget);
    expect(find.byTooltip('关闭'), findsNothing);
    await _back(tester);

    await _key(tester, 'share-link-stop');
    expect(find.text('停止分享？'), findsOneWidget);
    expect(find.text('「修复登录重复提交」的链接会立即失效'), findsOneWidget);
    await _key(tester, 'share-link-stop-confirm');
    expect(panel.links.revoked, ['a1B2c3D4e5']);
    expect(find.text('已停止分享'), findsOneWidget);
    expect(find.byKey(const ValueKey('share-link-make')), findsOneWidget);
    await _key(tester, 'share-link-restore');
    expect(panel.links.restored, ['a1B2c3D4e5']);
    expect(find.text('go.example.cn/c/a1B2c3D4e5'), findsOneWidget);

    // Stopped again, the undo goes once the window has passed.
    await _key(tester, 'share-link-stop');
    await _key(tester, 'share-link-stop-confirm');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('已停止分享'), findsNothing);
    expect(find.byKey(const ValueKey('share-link-make')), findsOneWidget);
  });

  testWidgets('failed revoke remains an active link and reports an error without an unhandled future', (tester) async {
    final panel = await _open(tester, state: _fixture(), reply: 'a6', operatingSystem: 'ohos');
    await _key(tester, 'share-to-link');
    await _key(tester, 'share-link-make');
    final model = tester.widget<SharePanelScope>(find.byType(SharePanelScope)).notifier!;
    final original = model.link;
    panel.links.fail = true;
    await model.stopLink();
    expect(model.link, same(original));
    expect(model.error, isNot(contains('生成')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed restore keeps the stopped state and its expiry timer', (tester) async {
    final panel = await _open(tester, state: _fixture(), reply: 'a6', operatingSystem: 'ohos');
    await _key(tester, 'share-to-link');
    await _key(tester, 'share-link-make');
    final model = tester.widget<SharePanelScope>(find.byType(SharePanelScope)).notifier!;
    await model.stopLink();
    panel.links.fail = true;
    await model.restoreLink();
    expect(model.link, isNull);
    expect(model.error, isNot(contains('生成')));
    await tester.pump(const Duration(seconds: 5));
    expect(model.stopped, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an uploaded unsaved link stays copyable and explains the save failure', (tester) async {
    final panel = await _open(tester, state: _fixture(), reply: 'a6', operatingSystem: 'ohos');
    panel.links.unsaved = true;
    await _key(tester, 'share-to-link');
    await _key(tester, 'share-link-make');
    expect(find.byKey(const ValueKey('share-link-copy')), findsOneWidget);
    expect(find.textContaining('链接已创建'), findsOneWidget);
  });
  testWidgets('session-only undo restores the link and displays restart warning', (tester) async {
    final panel = await _open(tester, state: _fixture(), reply: 'a6', operatingSystem: 'ohos');
    await _key(tester, 'share-to-link');
    await _key(tester, 'share-link-make');
    final model = tester.widget<SharePanelScope>(find.byType(SharePanelScope)).notifier!;
    await model.stopLink();
    panel.links.undoUnsaved = true;
    await model.restoreLink();
    await tester.pump();
    expect(model.link, isNotNull);
    expect(model.stopped, isNull);
    expect(find.textContaining('重启后可能继续删除'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(model.link, isNotNull);
  });
  testWidgets('a new scope or privacy asks for a new link; the old one stays in 我的分享链接', (tester) async {
    await _open(tester, state: _fixture(), reply: 'a6');
    await _key(tester, 'share-to-link');
    await _key(tester, 'share-link-make');
    expect(find.byKey(const ValueKey('share-link-copy')), findsOneWidget);
    await _back(tester);
    await _tap(tester, find.byKey(const ValueKey('share-toggle-工具调用')));
    await _key(tester, 'share-to-link');
    expect(find.byKey(const ValueKey('share-link-make')), findsOneWidget);
    await _back(tester);
    await _tap(tester, find.byKey(const ValueKey('share-toggle-工具调用')));
    await _key(tester, 'share-to-link');
    expect(find.byKey(const ValueKey('share-link-copy')), findsOneWidget, reason: 'the same content, the same link');
    expect(find.text('我的分享链接'), findsOneWidget);
  });

  testWidgets('[link-undo] restoring unchanged settings keeps the original link', (tester) async {
    final panel = await _open(tester, state: _undoFixture(), reply: 'a6');
    try {
      await _tapAndPump(tester, find.byKey(const ValueKey('share-to-link')));
      await _tapAndPump(tester, find.byKey(const ValueKey('share-link-make')));
      expect(panel.links.uploads, hasLength(1));
      expect(find.byKey(const ValueKey('share-link-copy')), findsOneWidget);
      await _tapAndPump(tester, find.byKey(const ValueKey('share-link-stop')));
      await _tapAndPump(tester, find.byKey(const ValueKey('share-link-stop-confirm')));
      expect(panel.links.revoked, ['a1B2c3D4e5']);
      await _tapAndPump(tester, find.byKey(const ValueKey('share-link-restore')));
      expect(panel.links.restored, ['a1B2c3D4e5']);
      expect(panel.links.uploads, hasLength(1), reason: 'undo restores the old bytes, without uploading again');
      expect(find.byKey(const ValueKey('share-link-copy')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('[link-undo] restored bytes do not acquire the new privacy selection', (tester) async {
    final panel = await _open(tester, state: _undoFixture(), reply: 'a6');
    try {
      await _tapAndPump(tester, find.byKey(const ValueKey('share-to-link')));
      await _tapAndPump(tester, find.byKey(const ValueKey('share-link-make')));
      final uploaded = decodeConversationFile(utf8.decode(panel.links.uploads.single.$1));
      expect(uploaded.share.entries.where((entry) => entry.type == 'tool'), isNotEmpty);
      await _tapAndPump(tester, find.byKey(const ValueKey('share-link-stop')));
      await _tapAndPump(tester, find.byKey(const ValueKey('share-link-stop-confirm')));
      await _back(tester);
      await _tapAndPump(tester, find.byKey(const ValueKey('share-toggle-工具调用')));
      await _tapAndPump(tester, find.byKey(const ValueKey('share-to-link')));
      final model = SharePanelScope.of(tester.element(find.byType(ShareLinkPage)));
      expect(model.privacy.tools, isFalse);
      expect(model.built!.share.entries.where((entry) => entry.type == 'tool'), isEmpty);
      expect(find.byKey(const ValueKey('share-link-restore')), findsOneWidget);
      await _tapAndPump(tester, find.byKey(const ValueKey('share-link-restore')));
      expect(panel.links.restored, ['a1B2c3D4e5']);
      expect(panel.links.uploads, hasLength(1), reason: 'undo did not publish the new tool-free content');
      expect(find.byKey(const ValueKey('share-link-copy')), findsNothing);
      expect(find.byKey(const ValueKey('share-link-make')), findsOneWidget);
      await _back(tester);
      await _tapAndPump(tester, find.byKey(const ValueKey('share-toggle-工具调用')));
      await _tapAndPump(tester, find.byKey(const ValueKey('share-to-link')));
      expect(
        find.byKey(const ValueKey('share-link-copy')),
        findsOneWidget,
        reason: 'the old privacy still owns the restored link',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('[link-undo] restoring a month link does not make it permanent', (tester) async {
    final panel = await _open(tester, state: _undoFixture(), reply: 'a6');
    try {
      await _tapAndPump(tester, find.byKey(const ValueKey('share-to-link')));
      await _tapAndPump(tester, find.byKey(const ValueKey('share-link-make')));
      expect(panel.links.uploads.single.$2, LinkExpiry.month);
      await _tapAndPump(tester, find.byKey(const ValueKey('share-link-stop')));
      await _tapAndPump(tester, find.byKey(const ValueKey('share-link-stop-confirm')));
      await _tapAndPump(tester, find.text(LinkExpiry.forever.label));
      expect(
        tester.widget<SegmentedPill<LinkExpiry>>(find.byType(SegmentedPill<LinkExpiry>)).selected,
        LinkExpiry.forever,
      );
      await _tapAndPump(tester, find.byKey(const ValueKey('share-link-restore')));
      expect(panel.links.restored, ['a1B2c3D4e5']);
      expect(panel.links.uploads, hasLength(1), reason: 'undo did not create a permanent upload');
      expect(find.byKey(const ValueKey('share-link-copy')), findsNothing);
      expect(find.byKey(const ValueKey('share-link-make')), findsOneWidget);
      await _tapAndPump(tester, find.text(LinkExpiry.month.label));
      expect(
        find.byKey(const ValueKey('share-link-copy')),
        findsOneWidget,
        reason: 'returning to the original expiry reuses its link',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('a failed upload says so; without a share host there is no 链接', (tester) async {
    final panel = await _open(tester, state: _fixture(), reply: 'a6');
    panel.links.fail = true;
    await _key(tester, 'share-to-link');
    await _key(tester, 'share-link-make');
    expect(_status(tester), '没能生成链接，稍后再试');

    await _open(tester, links: false);
    expect(find.byKey(const ValueKey('share-to-link')), findsNothing);
    for (final key in ['share-to-image', 'share-to-file', 'share-to-text']) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
  });

  // ── 文件 ──────────────────────────────────────────────────────────────────

  testWidgets('文件: backing out of the save window reads as neither saved nor failed', (tester) async {
    final panel = await _open(tester, state: _fixture(), reply: 'a6', scope: ShareScope.whole);
    await _key(tester, 'share-to-file');
    panel.out.saveError = PlatformException(code: 'cancelled');
    await _key(tester, 'share-file-save');
    expect(find.text('已保存'), findsNothing);
    expect(find.text('没能保存，请重试'), findsNothing);

    panel.out.saveError = PlatformException(code: 'failed');
    await _key(tester, 'share-file-save');
    expect(find.text('没能保存，请重试'), findsOneWidget);
  });

  testWidgets('文件: a DSH Go file, a web page, Markdown; 预览 opens the replay', (tester) async {
    final panel = await _open(tester, state: _fixture(), reply: 'a6', scope: ShareScope.whole);
    await _key(tester, 'share-to-file');
    expect(find.text('修复登录重复提交.dshgo'), findsOneWidget);
    expect(find.text('在 DSH Go 里回放、接着聊'), findsOneWidget);
    await _key(tester, 'share-file-save');
    final (saved, format) = panel.out.saved.single;
    expect(format, ConversationFormat.file);
    expect(saved.uri.pathSegments.last, '修复登录重复提交.dshgo');
    expect(_decode(saved.readAsStringSync()).range, isNull, reason: 'the whole conversation');
    expect(find.text('已保存'), findsOneWidget);

    await _tap(tester, find.text('网页'));
    expect(find.text('任何浏览器都能打开，不用联网'), findsOneWidget);
    await _key(tester, 'share-file-send');
    final (page, pageFormat) = panel.out.shared.single;
    expect(pageFormat, ConversationFormat.page);
    expect(page.uri.pathSegments.last, '修复登录重复提交.html');
    final html = page.readAsStringSync();
    expect(html, contains('<title>修复登录重复提交 · DSH Go</title>'));
    expect(html, contains("connect-src 'none'"));

    await _tap(tester, find.text('Markdown'));
    expect(find.text('纯文本，随处可读'), findsOneWidget);
    expect(find.byKey(const ValueKey('share-preview-replay')), findsNothing, reason: 'Markdown does not replay');
    await _key(tester, 'share-file-send');
    final (md, mdFormat) = panel.out.shared.last;
    expect(mdFormat, ConversationFormat.markdown);
    expect(md.uri.pathSegments.last, '修复登录重复提交.md');
    expect(md.readAsStringSync(), startsWith('# 修复登录重复提交'));

    await _tap(tester, find.text('对话文件'));
    await tester.tap(find.byKey(const ValueKey('share-preview-replay')));
    await tester.pumpAndSettle();
    expect(find.byType(ReplayPage), findsOneWidget);
    expect(tester.widget<ReplayPage>(find.byType(ReplayPage)).preview, isTrue);
  });

  testWidgets('over the limit: the file and the link say so and nothing goes out; Markdown still does', (tester) async {
    final random = Random(7);
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final noise = String.fromCharCodes(List.generate(5200000, (_) => alphabet.codeUnitAt(random.nextInt(64))));
    final state = ChatState(
      title: '很长',
      loading: false,
      items: [
        UserChatItem(seq: 1, time: t0, text: '把日志原样贴回来', images: const [], files: const []),
        AssistantChatItem(id: 'a2', seq: 2, time: t0, text: noise, reasoning: ''),
      ],
    );
    final panel = await _open(tester, state: state, reply: 'a2');
    await _key(tester, 'share-to-file');
    expect(_status(tester), '超过 4 MB，请缩小范围');
    await tester.tap(find.byKey(const ValueKey('share-file-send')));
    await _settle(tester);
    expect(panel.out.shared, isEmpty);
    await _tap(tester, find.text('Markdown'));
    expect(find.byKey(const ValueKey('share-status')), findsNothing);
    await _back(tester);
    await _key(tester, 'share-to-link');
    expect(_status(tester), '超过 4 MB，请缩小范围');
    await tester.tap(find.byKey(const ValueKey('share-link-make')));
    await _settle(tester);
    expect(panel.links.uploads, isEmpty);
  });

  // ── 图片 ──────────────────────────────────────────────────────────────────

  testWidgets('图片: templates and toggles drive the card, and the first page keeps them', (tester) async {
    await _open(tester);
    await _key(tester, 'share-to-image');
    expect(_card(tester).template, ShareTemplate.light);
    await _tap(tester, find.text('卡片'));
    expect(_card(tester).template, ShareTemplate.card);
    expect(ShareCardStyle.lastTemplate, ShareTemplate.card, reason: 'remembered for the next card');

    expect(find.text(sampleQuestion), findsOneWidget);
    await _tap(tester, find.text('提问'));
    expect(_card(tester).showQuestion, isFalse);
    expect(find.text(sampleQuestion), findsNothing);

    for (final pill in ['deepseek-v4-pro', '53 秒', '8 步']) {
      expect(find.byKey(ValueKey('share-pill-$pill')), findsOneWidget);
    }
    await _tap(tester, find.text('模型与过程'));
    expect(find.byKey(const ValueKey('share-pills')), findsNothing);
    expect(find.byKey(const ValueKey('share-process')), findsNothing);

    await _back(tester);
    final home = _card(tester);
    expect(home.template, ShareTemplate.card);
    expect(home.showQuestion, isFalse);
    expect(home.showMeta, isFalse);
  });

  testWidgets('图片: 分享 hands a 1170 px wide PNG over, 保存图片 confirms in place', (tester) async {
    final panel = await _open(tester);
    await _key(tester, 'share-to-image');
    final cardHeight = tester.getSize(find.byType(ShareCard)).height;
    await tester.tap(find.byKey(const ValueKey('share-send')));
    await _settle(tester);
    final file = File(panel.exporter.shared.single.files!.single.path);
    expect(file.path, endsWith('dsh-go-20261024-153012.png'));
    final bytes = (await tester.runAsync(file.readAsBytes))!;
    final image = (await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(bytes);
      return (await codec.getNextFrame()).image;
    }))!;
    expect(image.width, (ShareCard.width * 3).round());
    expect(image.height, closeTo(cardHeight * 3, 3));

    await tester.tap(find.byKey(const ValueKey('share-save')));
    await _settle(tester);
    expect(panel.exporter.saved, hasLength(1));
    expect(find.text('已保存'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('保存图片'), findsOneWidget);
  });

  testWidgets('图片: backing out of the save window reads as neither saved nor failed', (tester) async {
    final panel = await _open(tester, state: _fixture(), reply: 'a6', scope: ShareScope.whole);
    await _key(tester, 'share-to-image');
    panel.exporter.saveError = PlatformException(code: 'cancelled');
    await tester.tap(find.byKey(const ValueKey('share-save')));
    await _settle(tester);
    expect(find.text('已保存'), findsNothing);
    expect(find.text('没能保存，请重试'), findsNothing);
    expect(find.text('保存图片'), findsOneWidget);

    panel.exporter.saveError = PlatformException(code: 'failed');
    await tester.tap(find.byKey(const ValueKey('share-save')));
    await _settle(tester);
    expect(find.text('没能保存，请重试'), findsOneWidget);
  });

  // ── Large text, narrow phones ─────────────────────────────────────────────

  for (final (scale, size) in [(1.3, const Size(390, 844)), (2.0, const Size(320, 640)), (1.3, const Size(320, 640))]) {
    testWidgets('$scale× text at ${size.width.round()} wide: every page fits, no label cut', (tester) async {
      await _open(tester, state: _fixture(), reply: 'a6', textScale: scale, size: size);
      expect(tester.takeException(), isNull);
      for (final label in ['这条回复', '选中消息', '整段对话', '思考过程', '工具调用', '链接', '文件', '文字']) {
        _expectWhole(tester, label);
      }
      _expectWhole(tester, '2 条消息 · 1 次工具调用 · 1 张图片 · 密钥已隐藏');

      await _key(tester, 'share-to-link');
      expect(tester.takeException(), isNull);
      for (final label in ['7 天', '30 天', '永久', '生成链接', '我的分享链接']) {
        _expectWhole(tester, label);
      }
      await _key(tester, 'share-link-make');
      expect(tester.takeException(), isNull);
      for (final label in ['复制链接', '二维码', '分享', '停止分享']) {
        _expectWhole(tester, label);
      }
      _expectWhole(tester, 'go.example.cn/c/a1B2c3D4e5');
      await _back(tester);

      await _key(tester, 'share-to-file');
      expect(tester.takeException(), isNull);
      for (final label in ['对话文件', '网页', 'Markdown', '保存', '分享', '在 DSH Go 里回放、接着聊']) {
        _expectWhole(tester, label);
      }
      await _back(tester);

      await _key(tester, 'share-to-image');
      expect(tester.takeException(), isNull);
      for (final label in ['浅色', '深色', '纸张', '玻璃', '卡片', '提问', '模型与过程', '保存图片', '分享']) {
        _expectWhole(tester, label);
      }
    });
  }

  // ── Symmetry ──────────────────────────────────────────────────────────────

  testWidgets('the destinations: equal cells, 52 keys, mirrored edges, labels under their keys', (tester) async {
    await _open(tester);
    final sheet = tester.getRect(find.byType(SharePanel));
    final keys = [
      for (final k in ['share-to-link', 'share-to-image', 'share-to-file', 'share-to-text'])
        tester.getRect(find.byKey(ValueKey(k))),
    ];
    for (final cell in keys) {
      expect(cell.width, moreOrLessEquals(keys.first.width));
      expect(cell.top, moreOrLessEquals(keys.first.top));
    }
    expect(keys.first.left - sheet.left, moreOrLessEquals(20));
    expect(sheet.right - keys.last.right, moreOrLessEquals(20));
    for (final (k, label) in [('share-to-link', '链接'), ('share-to-text', '文字')]) {
      final cell = tester.getRect(find.byKey(ValueKey(k)));
      final text = tester.getRect(find.descendant(of: find.byKey(ValueKey(k)), matching: find.text(label)));
      final circle = tester.getRect(
        find.descendant(of: find.byKey(ValueKey(k)), matching: find.byType(DecoratedBox)).first,
      );
      expect(circle.width, 52);
      expect(circle.height, 52);
      expect(circle.center.dx, moreOrLessEquals(cell.center.dx));
      expect(text.center.dx, moreOrLessEquals(cell.center.dx, epsilon: 0.5));
    }
  });

  testWidgets('privacy capsules: 12 of air at both ends, one height, on one line', (tester) async {
    await _open(tester);
    final rects = <Rect>[];
    for (final label in ['思考过程', '工具调用', '图片']) {
      final capsule = tester.getRect(find.byKey(ValueKey('share-toggle-$label')));
      final check = tester.getRect(find.byKey(ValueKey('share-toggle-check-$label')));
      final text = tester.getRect(
        find.descendant(of: find.byKey(ValueKey('share-privacy')), matching: find.text(label)),
      );
      expect(capsule.height, ShareToggle.height);
      expect(check.left - capsule.left, moreOrLessEquals(ShareToggle.padding));
      expect(capsule.right - text.right, moreOrLessEquals(ShareToggle.padding));
      expect(check.center.dy, moreOrLessEquals(text.center.dy, epsilon: 0.5));
      expect(capsule.center.dy, moreOrLessEquals(text.center.dy, epsilon: 0.5));
      rects.add(capsule);
    }
    for (final r in rects) {
      expect(r.center.dy, moreOrLessEquals(rects.first.center.dy));
    }
    // Off: no check, the same air.
    await _tap(tester, find.byKey(const ValueKey('share-toggle-图片')));
    final capsule = tester.getRect(find.byKey(const ValueKey('share-toggle-图片')));
    final text = tester.getRect(
      find.descendant(of: find.byKey(const ValueKey('share-privacy')), matching: find.text('图片')),
    );
    expect(text.left - capsule.left, moreOrLessEquals(ShareToggle.padding));
    expect(capsule.right - text.right, moreOrLessEquals(ShareToggle.padding));
  });

  testWidgets('the summary line: its glyph centred on the text; 调整 does not move it', (tester) async {
    await _open(tester);
    final row = find.byKey(const ValueKey('share-summary'));
    final glyph = tester.getRect(find.byIcon(AppIcons.redacted));
    final before = tester.getRect(row);
    expect(glyph.center.dy, moreOrLessEquals(before.center.dy, epsilon: 0.5));
    expect(glyph.left, moreOrLessEquals(tester.getRect(find.byType(SharePanel)).left + 20));
    await _tap(tester, find.text('选中消息'));
    await _tap(tester, find.text('完成（2）'));
    final after = tester.getRect(row);
    expect(after.center.dy, moreOrLessEquals(before.center.dy, epsilon: 0.5));
    final adjust = tester.getRect(find.byKey(const ValueKey('share-adjust')));
    expect(adjust.center.dy, moreOrLessEquals(after.center.dy, epsilon: 0.5));
  });

  testWidgets('文件 and 链接 buttons: equal halves 12 apart on the 20 gutter; the make button full width', (tester) async {
    await _open(tester, state: _fixture(), reply: 'a6');
    final sheet = tester.getRect(find.byType(SharePanel));
    await _key(tester, 'share-to-file');
    final save = tester.getRect(find.byKey(const ValueKey('share-file-save')));
    final send = tester.getRect(find.byKey(const ValueKey('share-file-send')));
    expect(save.height, ShareActionBar.height);
    expect(send.height, ShareActionBar.height);
    expect(save.width, moreOrLessEquals(send.width));
    expect(send.left - save.right, moreOrLessEquals(ShareActionBar.gap));
    expect(save.left - sheet.left, moreOrLessEquals(20));
    expect(sheet.right - send.right, moreOrLessEquals(20));
    expect(save.top, send.top);
    await _back(tester);

    await _key(tester, 'share-to-link');
    final make = tester.getRect(find.byKey(const ValueKey('share-link-make')));
    expect(make.left - sheet.left, moreOrLessEquals(20));
    expect(sheet.right - make.right, moreOrLessEquals(20));
    expect(make.height, ShareActionBar.height);
    await _key(tester, 'share-link-make');
    final cells = [
      for (final k in ['share-link-copy', 'share-link-qr', 'share-link-share', 'share-link-stop'])
        tester.getRect(find.byKey(ValueKey(k))),
    ];
    for (final c in cells) {
      expect(c.width, moreOrLessEquals(cells.first.width));
    }
    expect(cells.first.left - sheet.left, moreOrLessEquals(20));
    expect(sheet.right - cells.last.right, moreOrLessEquals(20));
  });

  testWidgets('no close key anywhere: the panel and its pages drag down to close', (tester) async {
    await _open(tester);
    expect(find.byTooltip('关闭'), findsNothing);
    for (final key in ['share-to-link', 'share-to-image', 'share-to-file']) {
      await _key(tester, key);
      expect(find.byTooltip('关闭'), findsNothing, reason: key);
      expect(find.byTooltip('返回'), findsOneWidget, reason: key);
      await _back(tester);
    }
    expect(find.byType(SharePanelHome), findsOneWidget);
  });
}

ChatState _selectionFixture() {
  final source = _fixture();
  return ChatState(
    items: [
      for (final item in source.items)
        if (item is UserChatItem)
          UserChatItem(seq: item.seq, time: item.time, text: item.text, images: const [], files: item.files)
        else
          item,
    ],
    turns: source.turns,
    commands: source.commands,
    title: source.title,
    loading: false,
  );
}

Future<void> _selectionTap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void _selectionTests() {
  for (final append in [false, true]) {
    testWidgets(
      '[share-new-selection] explicitly selected reply is exported after initial preparation: append=$append',
      (tester) async {
        final initial = _selectionFixture();
        await _open(tester, state: initial, reply: null);
        try {
          final home = tester.element(find.byType(SharePanelHome));
          final container = ProviderScope.containerOf(home, listen: false);
          final controller = container.read(chatProvider('s1').notifier) as _Chat;
          final model = SharePanelScope.of(home);
          expect(model.scope, ShareScope.whole);
          await _selectionTap(tester, find.byKey(const ValueKey('share-to-file')));
          final first = await model.prepare();
          expect(first.share.entries.whereType<ReplyEntry>().map((e) => e.text), contains(_reply(initial, 'a15').text));
          await _selectionTap(tester, find.byTooltip('返回'));

          final addedPrompt = UserChatItem(
            seq: 19,
            time: at(150100),
            text: '请补充本轮验收结论',
            images: const [],
            files: const [],
          );
          final addedReply = AssistantChatItem(
            id: 'a20',
            seq: 20,
            time: at(151000),
            text: '新增验收结论：第三轮已完整核对。',
            reasoning: '',
            model: 'deepseek-v4-pro',
          );
          if (append) {
            controller.emit(
              ChatState(
                items: [...initial.items, addedPrompt, addedReply],
                turns: [
                  ...initial.turns,
                  TurnTrace(
                    turn: 3,
                    startSeq: 18,
                    start: at(150000),
                    endSeq: 21,
                    end: at(151100),
                    endReason: const TurnEndReason('completed'),
                    spans: [_selectionModelSpan()],
                  ),
                ],
                commands: initial.commands,
                title: initial.title,
                loading: false,
              ),
            );
            await tester.pump();
            expect(model.shareable.map((i) => i.key), contains(addedReply.key));
            expect(model.card!.blocks.whereType<ShareAnswer>().map((b) => b.markdown), contains(addedReply.text));
            expect(first.share.entries.whereType<ReplyEntry>().map((e) => e.text), isNot(contains(addedReply.text)));
          }
          final target = append ? addedReply : _reply(initial, 'a15');
          final prompt = append ? addedPrompt : initial.items.whereType<UserChatItem>().last;
          await _selectionTap(tester, find.text('选中消息'));
          final picker = tester.widget<MessagePicker>(find.byType(MessagePicker));
          expect(picker.items.map((i) => i.key), contains(target.key));
          expect(picker.selected, {prompt.key, target.key});
          final promptRow = find.byWidgetPredicate((w) => w is MessagePickRow && w.item.key == prompt.key);
          await _selectionTap(tester, promptRow);
          final targetRow = tester.widget<MessagePickRow>(
            find.byWidgetPredicate((w) => w is MessagePickRow && w.item.key == target.key),
          );
          expect(targetRow.picked, isTrue);
          await _selectionTap(tester, find.text('完成（1）'));
          expect(model.keys, {target.key});
          expect(model.scope, ShareScope.picked);
          expect(model.card!.blocks.whereType<ShareAnswer>().map((b) => b.markdown), [target.text]);
          await _selectionTap(tester, find.byKey(const ValueKey('share-to-file')));
          final selected = await model.prepare();
          final decoded = decodeConversationFile(selected.file.text);
          expect(selected.share.entries.whereType<ReplyEntry>().map((e) => e.text), [target.text]);
          expect(decoded.share.entries.whereType<ReplyEntry>().map((e) => e.text), [target.text]);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      },
    );
  }
}

TraceSpan _selectionModelSpan() => TraceSpan(
  kind: TraceKind.model,
  step: 1,
  seq: 20,
  start: at(150200),
  firstToken: at(150300),
  lastToken: at(151000),
  end: at(151000),
);

Future<void> _wholeScopeTap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void _wholeScopeAfterUpdateTests() {
  for (final append in [false, true]) {
    testWidgets('[share-whole-update] whole export uses current messages: append=$append', (tester) async {
      final source = _fixture();
      final initial = ChatState(
        items: [
          for (final item in source.items)
            if (item is UserChatItem)
              UserChatItem(seq: item.seq, time: item.time, text: item.text, images: const [], files: item.files)
            else
              item,
        ],
        turns: [...source.turns],
        commands: [...source.commands],
        title: source.title,
        loading: false,
      );
      try {
        final panel = await _open(tester, state: initial, reply: 'a15');
        final panelState = tester.state(find.byType(SharePanel));
        final home = tester.element(find.byType(SharePanelHome));
        final container = ProviderScope.containerOf(home, listen: false);
        final controller = container.read(chatProvider('s1').notifier) as _Chat;
        final model = SharePanelScope.of(home);
        expect(model.scope, ShareScope.reply);
        expect(model.anchor?.id, 'a15');
        await _wholeScopeTap(tester, find.byKey(const ValueKey('share-to-file')));
        final first = await model.prepare();
        expect(
          first.share.entries.whereType<ReplyEntry>().where((entry) => entry.text == _reply(initial, 'a15').text),
          hasLength(1),
        );
        await _wholeScopeTap(tester, find.byTooltip('返回'));
        expect(tester.state(find.byType(SharePanel)), same(panelState));
        expect(SharePanelScope.of(tester.element(find.byType(SharePanelHome))), same(model));

        final addedPrompt = UserChatItem(
          seq: 19,
          time: at(150100),
          text: '请补充本轮验收结论',
          images: const [],
          files: const [],
        );
        final addedReply = AssistantChatItem(
          id: 'a20',
          seq: 20,
          time: at(151000),
          text: '新增验收结论：第三轮已完整核对。',
          reasoning: '',
          model: 'deepseek-v4-pro',
        );
        if (append) {
          final updated = ChatState(
            items: [...initial.items, addedPrompt, addedReply],
            turns: [
              ...initial.turns,
              TurnTrace(
                turn: 3,
                startSeq: 18,
                start: at(150000),
                endSeq: 21,
                end: at(151100),
                endReason: const TurnEndReason('completed'),
                spans: [
                  TraceSpan(
                    kind: TraceKind.model,
                    step: 1,
                    seq: 20,
                    start: at(150200),
                    firstToken: at(150300),
                    lastToken: at(151000),
                    end: at(151000),
                  ),
                ],
              ),
            ],
            commands: [...initial.commands],
            title: initial.title,
            loading: false,
          );
          controller.emit(updated);
          await tester.pump();
          expect(container.read(chatProvider('s1')), same(updated));
          expect(model.shareable.map((item) => item.key), contains(addedReply.key));
          expect(initial.items.map((item) => item.key), isNot(contains(addedReply.key)));
        }
        expect(first.share.entries.whereType<ReplyEntry>().map((e) => e.text), isNot(contains(addedReply.text)));
        await _wholeScopeTap(tester, find.text('整段对话'));
        expect(
          tester.widget<SegmentedPill<ShareScope>>(find.byType(SegmentedPill<ShareScope>)).selected,
          ShareScope.whole,
        );
        expect(model.scope, ShareScope.whole);
        expect(find.byType(MessagePicker), findsNothing);
        expect(tester.state(find.byType(SharePanel)), same(panelState));
        expect(SharePanelScope.of(tester.element(find.byType(SharePanelHome))), same(model));
        expect(model.keys, {for (final item in model.shareable) item.key});
        await _wholeScopeTap(tester, find.byKey(const ValueKey('share-to-file')));
        final whole = await model.prepare();
        await tester.runAsync(() => model.saveFile());
        expect(model.fileSaved, isTrue);
        expect(panel.out.saved, hasLength(1));
        final (saved, format) = panel.out.saved.single;
        expect(format, ConversationFormat.file);
        final text = (await tester.runAsync(saved.readAsString))!;
        final decoded = _decode(text);
        for (final share in [decoded, whole.share]) {
          expect(share.range, isNull, reason: 'the whole conversation');
          final replies = share.entries.whereType<ReplyEntry>();
          expect(replies.where((entry) => entry.text == _reply(initial, 'a15').text), hasLength(1));
          expect(replies.where((entry) => entry.text == addedReply.text), hasLength(append ? 1 : 0));
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    });
  }
}
