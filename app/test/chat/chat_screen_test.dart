import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show SemanticsAction;

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/remote/link_status.dart' show RelayPath;
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/composer_quote.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/empty_actions.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/chat/widgets/activity_strip.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/chat/dock/dock_stack.dart' show DockStackMetrics;
import 'package:dsh_app/ui/chat/widgets/auto_approve_pill.dart';
import 'package:dsh_app/ui/chat/widgets/permission_pill.dart' show StripRiskChip;
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

Future<void> pumpScreen(WidgetTester tester, ChatHarness harness, {int frames = 6}) async {
  usePhoneView(tester);
  mockClipboard(tester);
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester, frames);
}

ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));

ScrollPosition listPosition(WidgetTester tester) =>
    tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller!.position;

class _RemoteHost extends ActiveHostController {
  static const host = HostRef.relay('workstation');

  @override
  HostRef build() => host;
}

class _StartingRuntime extends LocalRuntimeController {
  @override
  LocalRuntimeState build() => const LocalRuntimeState(status: RuntimeStatus(phase: RuntimePhase.starting));
}

class _InteractionChat extends FakeChatController {
  _InteractionChat(String sessionId) : super(sessionId, const ChatState(loading: false));
  final allowed = <bool Function()>[];
  int released = 0;
  @override
  void Function() beginInteraction(bool Function() check) {
    allowed.add(check);
    return () {
      released++;
    };
  }
}

void main() {
  testWidgets('interaction follows selection, foreground resume, and screen disposal', (tester) async {
    usePhoneView(tester);
    final harness = ChatHarness(session: 'a');
    final chats = <String, _InteractionChat>{};
    await tester.pumpWidget(
      testApp(
        const ChatScreen(),
        overrides: [
          ...harness.overrides.take(harness.overrides.length - 1),
          chatProvider.overrideWith2((id) => chats[id] = _InteractionChat(id)),
        ],
      ),
    );
    await pumpFrames(tester);
    final a = chats['a']!;
    expect(a.allowed.single(), isTrue);
    containerOf(tester).read(currentSessionProvider.notifier).select('b');
    await pumpFrames(tester);
    expect(a.released, 1);
    expect(a.allowed.single(), isFalse);
    final b = chats['b']!;
    expect(b.allowed.single(), isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(b.allowed.last(), isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpFrames(tester);
    expect(b.allowed.length, 2);
    expect(b.released, 1);
    expect(b.allowed.last(), isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(b.released, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(b.allowed.length, 2, reason: 'disposed screen is no longer an observer');
  });

  setUpAll(() => chatClock = () => DateTime(2026, 10, 23, 9));

  testWidgets('covering and returning to chat renews interaction; direct disposal releases it', (tester) async {
    usePhoneView(tester);
    final harness = ChatHarness(session: 'a');
    late _InteractionChat chat;
    await tester.pumpWidget(
      testApp(
        const ChatScreen(),
        overrides: [
          ...harness.overrides.take(harness.overrides.length - 1),
          chatProvider.overrideWith2((id) => chat = _InteractionChat(id)),
        ],
      ),
    );
    await pumpFrames(tester);
    expect(chat.allowed.single(), isTrue);
    final navigator = Navigator.of(tester.element(find.byType(ChatScreen)));
    final route = MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('covered')));
    navigator.push(route);
    expect(chat.allowed.last(), isFalse, reason: 'route is covered before the next frame');
    await pumpFrames(tester);
    expect(chat.allowed.last(), isFalse);
    expect(chat.released, 1);
    navigator.pop();
    await pumpFrames(tester);
    expect(chat.allowed.length, 2);
    expect(chat.allowed.last(), isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(chat.released, 2);
    expect(chat.allowed.last(), isFalse);
  });

  testWidgets('a lost stream is announced as disconnected', (tester) async {
    await pumpScreen(
      tester,
      ChatHarness(
        session: 's1',
        states: {'s1': const ChatState(loading: false, streamLost: true, error: '对话同步中断')},
      ),
    );
    expect(find.text('连接已断开'), findsOneWidget);
    expect(find.text('对话同步中断'), findsOneWidget);
  });

  testWidgets('header and drawer recover the same remote host independently of chat sync', (tester) async {
    final changes = StreamController<HostLinkStatus>.broadcast(sync: true);
    addTearDown(changes.close);
    final harness = ChatHarness(
      session: 's1',
      extra: [
        activeHostProvider.overrideWith(_RemoteHost.new),
        hostNameProvider.overrideWith((ref, host) => 'Workstation'),
        hostLinkStatusProvider(_RemoteHost.host).overrideWith((ref) => changes.stream),
      ],
    );
    usePhoneView(tester);
    mockClipboard(tester);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Column(
            children: [
              const Expanded(child: ChatScreen()),
              IdentityBar(onHost: () {}, onFeatures: () {}, onSettings: () {}),
            ],
          ),
        ),
        overrides: harness.overrides,
      ),
    );
    await pumpFrames(tester);
    final headerFinder = find.byType(ChatHeader);
    ChatHeader header() => tester.widget<ChatHeader>(headerFinder);
    void expectLinkLabel(String label) {
      expect(header().status.label, label);
      expect(find.descendant(of: find.byType(IdentityBar), matching: find.text(label)), findsOneWidget);
    }

    changes.add(const HostLinkStatus(HostLinkPhase.connected, path: RelayPath.p2p));
    await pumpFrames(tester);
    expectLinkLabel(RelayPath.p2p.label);

    changes.add(const HostLinkStatus(HostLinkPhase.reconnecting, path: RelayPath.p2p));
    await pumpFrames(tester);
    expectLinkLabel(appL10n.remoteReconnecting);
    expect(find.text(RelayPath.p2p.label), findsNothing);

    final chat = harness.controllers['s1']!;
    chat.emit(chat.state.copyWith(streamLost: true));
    changes.add(const HostLinkStatus(HostLinkPhase.connected));
    await pumpFrames(tester);
    expectLinkLabel(appL10n.remoteConnected);
    expect(header().sessionStatus?.label, appL10n.stateChatSyncInterrupted);
    expect(
      find.descendant(of: headerFinder, matching: find.text(' · ${appL10n.stateChatSyncInterrupted}')),
      findsOneWidget,
    );

    chat.emit(chat.state.copyWith(streamLost: false, syncing: true));
    await pumpFrames(tester);
    expectLinkLabel(appL10n.remoteConnected);
    expect(header().sessionStatus?.label, appL10n.stateChatSynchronizing);

    chat.emit(chat.state.copyWith(syncing: false));
    await pumpFrames(tester);
    expectLinkLabel(appL10n.remoteConnected);
    expect(header().sessionStatus, isNull);
  });

  testWidgets('local startup has its own header and empty-state copy', (tester) async {
    usePhoneView(tester);
    final harness = ChatHarness(connected: false, runtime: _StartingRuntime.new);
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: [...harness.overrides]));
    await pumpFrames(tester);
    expect(find.text('正在启动'), findsOneWidget);
    expect(find.text('正在启动引擎…'), findsOneWidget);
    expect(find.text('未连接'), findsNothing);
  });

  testWidgets('a failed local connection offers reconnect', (tester) async {
    usePhoneView(tester);
    final harness = ChatHarness(connected: false);
    await tester.pumpWidget(
      testApp(
        const ChatScreen(),
        overrides: [
          activeConnectionProvider.overrideWithValue(AsyncError<HostConnection?>(StateError('raw'), StackTrace.empty)),
          ...harness.overrides.skip(1),
        ],
      ),
    );
    await pumpFrames(tester);
    expect(find.text('没能连上引擎'), findsOneWidget);
    expect(find.text('重新连接'), findsOneWidget);
    expect(tester.getCenter(find.text('重新连接')).dx, 195);
  });

  testWidgets('reconnect and workspace chips use the same subtitle gap', (tester) async {
    usePhoneView(tester);
    Future<double> gap(bool failed) async {
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: ChatEmptyState(
              connected: !failed,
              onSuggestion: (_) {},
              suggestions: const [],
              workspace: failed ? null : '项目',
              onWorkspace: () {},
              onReconnect: failed ? () {} : null,
            ),
          ),
        ),
      );
      await pumpFrames(tester);
      final chipText = find.text(failed ? '重新连接' : '在「项目」中');
      final chip = find.ancestor(of: chipText, matching: find.byType(InkWell)).first;
      final subtitle = find.text(failed ? '没能连上引擎' : '今天想做点什么？');
      expect(tester.getRect(chip).height, EmptyActions.height);
      expect(tester.getCenter(chip).dx, 195);
      return tester.getRect(chip).top - tester.getRect(subtitle).bottom;
    }

    expect(await gap(true), closeTo(await gap(false), 0.1));
  });

  testWidgets('relay attachment menu keeps two equal targets', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () => showAttachMenu(context, files: false), child: const Text('附件')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('附件'));
    await pumpFrames(tester);
    expect(find.text('文件'), findsNothing);
    final album = find.ancestor(of: find.text('相册'), matching: find.byType(InkWell)).first;
    final camera = find.ancestor(of: find.text('拍照'), matching: find.byType(InkWell)).first;
    final left = tester.getRect(album);
    final right = tester.getRect(camera);
    expect(left.width, right.width);
    expect(left.left, closeTo(390 - right.right, 0.1));
  });

  group('direct question answers', () {
    // The question card has its own (folded) 「其他回答」 field.
    final field = find.descendant(of: find.byType(Composer), matching: find.byType(TextField));
    for (final count in [1, 2]) {
      testWidgets('$count questions choose the appropriate send route', (tester) async {
        final request = UserQuestionRequest(
          eventId: 'q',
          sessionId: 's1',
          questions: [for (var i = 0; i < count; i++) UserQuestion(id: '$i', question: '选什么？')],
        );
        final harness = ChatHarness(
          session: 's1',
          states: {
            's1': ChatState(running: true, loading: false, questions: [request]),
          },
        );
        await pumpScreen(tester, harness);
        expect(tester.widget<TextField>(field).decoration!.hintText, count == 1 ? '输入回答…' : '等你回答');
        await tester.enterText(field, '蓝色');
        await tester.pump();
        expect(find.text(count == 1 ? '发送文字将回答待答问题' : '发送新消息'), findsOneWidget);
        expect(tester.widget<ChatHeader>(find.byType(ChatHeader)).status.label, '等你回答');
        await tester.tap(find.byIcon(AppIcons.send));
        await pumpFrames(tester);
        final controller = harness.controllers['s1']!;
        if (count == 1) {
          expect(controller.answers.single.$2.single.custom, '蓝色');
          expect(controller.sent, isEmpty);
        } else {
          expect(controller.answers, isEmpty);
          expect(controller.sent, ['蓝色']);
        }
      });
    }

    testWidgets('a rejected answer returns to its own draft', (tester) async {
      final harness = ChatHarness(
        session: 's1',
        states: {
          's1': const ChatState(
            running: true,
            loading: false,
            questions: [
              UserQuestionRequest(
                eventId: 'q',
                sessionId: 's1',
                questions: [UserQuestion(id: 'q1', question: '选什么？')],
              ),
            ],
          ),
        },
      );
      await pumpScreen(tester, harness);
      harness.controllers['s1']!.answerSucceeds = false;
      await tester.enterText(field, '蓝色');
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      expect(tester.widget<TextField>(field).controller!.text, '蓝色');
      expect(harness.controllers['s1']!.sent, isEmpty);
      expect(find.text('发送文字将回答待答问题'), findsOneWidget);
      expect(find.text('已回答'), findsNothing, reason: 'a failed send is not a durable answer');
    });

    testWidgets('attachments keep the normal prompt route during a single question', (tester) async {
      final harness = ChatHarness(
        session: 's1',
        states: {
          's1': const ChatState(
            running: true,
            loading: false,
            questions: [
              UserQuestionRequest(
                eventId: 'q',
                sessionId: 's1',
                questions: [UserQuestion(id: 'q1', question: '选什么？')],
              ),
            ],
          ),
        },
      );
      await pumpScreen(tester, harness);
      tester
          .state<EditableTextState>(find.descendant(of: field, matching: find.byType(EditableText)))
          .insertContent(KeyboardInsertedContent(mimeType: 'image/png', uri: 'content://test/image', data: tinyPng));
      await tester.pump();
      await tester.enterText(field, '看图');
      await tester.pump();
      expect(find.text('发送新消息'), findsOneWidget);
      expect(find.text('发送文字将回答待答问题'), findsNothing);
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      expect(harness.controllers['s1']!.sent, ['看图']);
      expect(harness.controllers['s1']!.answers, isEmpty);
      expect(harness.controllers['s1']!.sentAttachments.single, hasLength(1));
    });

    testWidgets('a quote switches the visible intent back to a message', (tester) async {
      final harness = ChatHarness(
        session: 's1',
        states: {
          's1': const ChatState(
            running: true,
            loading: false,
            questions: [
              UserQuestionRequest(
                eventId: 'q',
                sessionId: 's1',
                questions: [UserQuestion(id: 'q1', question: '选什么？')],
              ),
            ],
          ),
        },
      );
      await pumpScreen(tester, harness);
      containerOf(tester).read(composerQuoteProvider.notifier).set('s1', '引用原文');
      await tester.enterText(field, '另外说一句');
      await tester.pump();
      expect(find.text('发送新消息'), findsOneWidget);
      expect(find.text('发送文字将回答待答问题'), findsNothing);
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      expect(harness.controllers['s1']!.answers, isEmpty);
      expect(harness.controllers['s1']!.sent.single, contains('引用原文'));
    });
  });

  testWidgets('keyboard images enter the tray, stop at nine, and never send automatically', (tester) async {
    final harness = ChatHarness(session: 's1');
    await pumpScreen(tester, harness);
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    final content = KeyboardInsertedContent(mimeType: 'image/png', uri: 'content://test/image', data: tinyPng);
    for (var i = 0; i < maxAttachments; i++) {
      editable.insertContent(content);
      await tester.pump();
    }
    expect(tester.widget<ComposerTray>(find.byType(ComposerTray)).items, hasLength(9));
    expect(harness.controllers['s1']!.sent, isEmpty);
    editable.insertContent(content);
    await tester.pump();
    expect(tester.widget<ComposerTray>(find.byType(ComposerTray)).items, hasLength(9));
    expect(find.text('每条消息最多 9 个附件'), findsOneWidget);
  });

  testWidgets('new conversation header action clears the selection', (tester) async {
    await pumpScreen(tester, ChatHarness(session: 's1'));
    expect(find.byKey(const ValueKey('chat-new-chat')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-new-chat')));
    await pumpFrames(tester);
    expect(containerOf(tester).read(currentSessionProvider), isNull);
    expect(find.byKey(const ValueKey('chat-new-chat')), findsNothing);
  });

  testWidgets('while a reply generates, auto-approve sits beside the activity strip, not on a row of its own', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final harness = ChatHarness(
      session: 's1',
      states: {'s1': const ChatState(running: true, autoApprove: true, loading: false)},
    );
    await pumpScreen(tester, harness);
    expect(find.byType(AutoApprovePill), findsNothing);
    final strip = tester.getRect(find.byType(ActivityStrip));
    final chip = tester.getRect(find.byType(StripRiskChip));
    final composer = tester.getRect(find.byType(Composer));
    expect(strip.left, 12);
    expect(composer.left, 12);
    // One row: the chip is as high as the strip, on its line, flush with the composer's right edge.
    expect(chip.top, strip.top);
    expect(chip.height, strip.height);
    expect(chip.left - strip.right, DockStackMetrics.accessoryGap);
    expect(chip.right, moreOrLessEquals(composer.right, epsilon: 0.01));
    // Its words first, then only its icons; read out whole all along.
    expect(find.text('自动允许中'), findsOneWidget);
    await tester.pump(StripRiskChip.wordsFor);
    await pumpFrames(tester);
    expect(find.text('自动允许中'), findsNothing);
    final auto = tester.getSemantics(find.bySemanticsLabel('自动允许命令')).getSemanticsData();
    expect(auto.hasAction(SemanticsAction.tap), isTrue);
    final activity = tester.getSemantics(find.byType(ActivityStrip)).getSemanticsData();
    expect(activity.hasAction(SemanticsAction.tap), isTrue);
    // One tap turns it off.
    await tester.tap(find.byType(StripRiskChip));
    await pumpFrames(tester, 4);
    expect(harness.controllers['s1']!.autoApproveToggles, [false]);
    semantics.dispose();
  });

  group('new chat', () {
    testWidgets('greets and fills the composer from a suggestion', (tester) async {
      await pumpScreen(tester, ChatHarness());
      expect(find.text('早上好'), findsOneWidget);
      expect(find.text('新对话'), findsOneWidget);

      await tester.tap(find.text(defaultSuggestions.first.label));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, defaultSuggestions.first.prompt);
    });

    testWidgets('first send creates, selects, then sends', (tester) async {
      final harness = ChatHarness(created: 'fresh');
      await pumpScreen(tester, harness);

      await tester.enterText(find.byType(TextField), '你好');
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);

      expect(harness.sessions.creates, 1);
      expect(containerOf(tester).read(currentSessionProvider), 'fresh');
      expect(harness.controllers['fresh']!.sent, ['你好']);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, isEmpty);
    });

    testWidgets('model picked before the session exists is applied to it', (tester) async {
      final harness = ChatHarness(created: 'fresh');
      await pumpScreen(tester, harness);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('composer-model')));
      await pumpFrames(tester, 4);
      expect(find.text('选择模型'), findsOneWidget);
      await tester.tap(find.text('V41 Flash'));
      await pumpFrames(tester, 2);
      final pending = containerOf(tester).read(pendingModelProvider)!;
      expect(pending.model, 'deepseek-flash');
      // Effort carried over because the flash model supports it.
      expect(pending.reasoningEffort, 'high');
      await tester.tapAt(const Offset(20, 120)); // dismiss the sheet
      await pumpFrames(tester, 4);

      await tester.enterText(find.byType(TextField), '你好');
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);

      final chat = harness.controllers['fresh']!;
      expect(chat.models.single.model, 'deepseek-flash');
      expect(chat.sent, ['你好']);
      expect(containerOf(tester).read(pendingModelProvider), isNull);
    });

    testWidgets('disconnected: hint shown and nothing is sent', (tester) async {
      final harness = ChatHarness(connected: false);
      await pumpScreen(tester, harness);
      expect(find.text('连接引擎后即可发送'), findsOneWidget);
      expect(find.text('引擎未连接'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '你好');
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      expect(harness.sessions.creates, 0);
    });
  });

  group('conversation', () {
    testWidgets('approval card answers through the controller', (tester) async {
      final harness = ChatHarness(session: 's1', states: {'s1': conversationState()});
      await pumpScreen(tester, harness);
      expect(find.text('修复登录重复提交'), findsOneWidget);
      expect(find.descendant(of: find.byType(ChatHeader), matching: find.text('等你确认')), findsOneWidget);
      expect(find.text('允许运行这条命令？'), findsOneWidget);

      await tester.tap(find.text('允许本次'));
      await tester.pump();
      final (request, decision) = harness.controllers['s1']!.responses.single;
      expect(request.eventId, approval.eventId);
      expect(decision, ApprovalDecision.allowOnce);
    });

    testWidgets('reject is a separate, explicit action', (tester) async {
      final harness = ChatHarness(session: 's1', states: {'s1': conversationState()});
      await pumpScreen(tester, harness);
      await tester.tap(find.text('拒绝'));
      await tester.pump();
      expect(harness.controllers['s1']!.responses.single.$2, ApprovalDecision.reject);
    });

    testWidgets('本对话都允许 allows this request and turns on auto mode', (tester) async {
      // The first-time notice reads whether it was silenced.
      SharedPreferences.setMockInitialValues({});
      final harness = ChatHarness(session: 's1', states: {'s1': conversationState()});
      await pumpScreen(tester, harness);
      expect(find.text('自动允许中'), findsNothing);

      await tester.tap(find.text('本对话都允许'));
      await pumpFrames(tester, 4);
      final chat = harness.controllers['s1']!;
      // Said once first: the whole conversation stops asking.
      expect(find.text('本对话都允许？'), findsOneWidget);
      expect(chat.allowAllRequests, isEmpty);
      await tester.tap(find.byKey(const ValueKey('risk-confirm')));
      await pumpFrames(tester, 4);
      expect(chat.allowAllRequests.single.eventId, approval.eventId);
      expect(chat.responses, isEmpty);
      // The auto-allowed request no longer shows a card; the mode is visible.
      expect(find.text('允许运行这条命令？'), findsNothing);
      expect(find.text('等待确认'), findsNothing);
      expect(find.text('自动允许中'), findsOneWidget);

      // One tap on the pill turns it off.
      await tester.tap(find.text('自动允许中'));
      await pumpFrames(tester, 4);
      expect(chat.autoApproveToggles, [true, false]);
      expect(find.text('自动允许中'), findsNothing);
    });

    testWidgets('本对话都允许 › 问 AI leaves the request waiting and asks in a new chat', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final harness = ChatHarness(session: 's1', states: {'s1': conversationState()});
      await pumpScreen(tester, harness);
      await tester.tap(find.text('本对话都允许'));
      await pumpFrames(tester, 4);
      await tester.tap(find.text('不确定？问 AI'));
      await pumpFrames(tester, 8);
      expect(harness.controllers['s1']!.allowAllRequests, isEmpty);
      expect(containerOf(tester).read(currentSessionProvider), isNull, reason: 'a new conversation');
      final field = tester.widget<TextField>(
        find.descendant(of: find.byType(Composer), matching: find.byType(TextField)),
      );
      expect(field.controller!.text, '/dsh-go-guide 「本对话都允许」会放行哪些操作？怎么关掉？');
      // Waits for the person to send it.
      expect(harness.sessions.creates, 0);
    });

    testWidgets('a new request in auto mode never shows a card', (tester) async {
      final base = conversationState();
      final harness = ChatHarness(
        session: 's1',
        states: {
          's1': ChatState(
            items: base.items,
            title: base.title,
            running: true,
            approvals: base.approvals,
            loading: false,
            autoApprove: true,
            autoAnswered: {approval.eventId},
          ),
        },
      );
      await pumpScreen(tester, harness);
      expect(find.text('允许运行这条命令？'), findsNothing);
      expect(find.text('本对话都允许'), findsNothing);
      expect(find.text('自动允许中'), findsOneWidget);
      // Nothing is waiting on the person any more.
      expect(find.descendant(of: find.byType(ChatHeader), matching: find.text('等你确认')), findsNothing);
      expect(find.text('生成中'), findsOneWidget);
    });

    testWidgets('sandbox refusal reads as a neutral authorisation step', (tester) async {
      final harness = ChatHarness(session: 's1', states: {'s1': conversationState()});
      await pumpScreen(tester, harness);
      expect(find.text('需要授权后才能执行'), findsOneWidget);
      expect(find.byIcon(AppIcons.lock), findsOneWidget);
      expect(find.textContaining('no sandbox backend'), findsNothing);
    });

    testWidgets('stop button cancels while running with an empty input', (tester) async {
      final harness = ChatHarness(session: 's2', states: {'s2': streamingState()});
      await pumpScreen(tester, harness);
      await tester.tap(find.byIcon(AppIcons.stopGenerating));
      await tester.pump();
      expect(harness.controllers['s2']!.cancels, 1);

      // With text in the field the same button sends (DSH queues it).
      await tester.enterText(find.byType(TextField), '再补充一句');
      await pumpFrames(tester, 3);
      expect(find.byIcon(AppIcons.stopGenerating), findsNothing);
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester, 2);
      expect(harness.controllers['s2']!.sent, ['再补充一句']);
    });

    testWidgets('error banner is dismissible', (tester) async {
      final base = conversationState();
      final harness = ChatHarness(
        session: 's1',
        states: {'s1': ChatState(items: base.items, title: base.title, loading: false, error: '发送失败:连接已断开')},
      );
      await pumpScreen(tester, harness);
      expect(find.text('发送失败:连接已断开'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await pumpFrames(tester, 4);
      expect(find.text('发送失败:连接已断开'), findsNothing);
    });

    testWidgets('question card submits the picked option', (tester) async {
      const question = UserQuestionRequest(
        eventId: 'q1',
        sessionId: 's3',
        questions: [
          UserQuestion(
            id: 'db',
            question: '数据库用哪一个?',
            options: [QuestionOption('SQLite', null), QuestionOption('PostgreSQL', null)],
          ),
        ],
      );
      final harness = ChatHarness(
        session: 's3',
        states: {
          's3': ChatState(items: [user(1, '帮我搭个后端')], running: true, questions: const [question], loading: false),
        },
      );
      await pumpScreen(tester, harness);
      expect(find.text('有个问题想问你'), findsOneWidget);
      await tester.tap(find.text('PostgreSQL'));
      await tester.pump();
      await tester.tap(find.text('提交'));
      await tester.pump();
      final (request, answers) = harness.controllers['s3']!.answers.single;
      expect(request.eventId, 'q1');
      expect(answers.single.id, 'db');
      expect(answers.single.selected, ['PostgreSQL']);
    });

    testWidgets('tool row expands to arguments and output', (tester) async {
      final harness = ChatHarness(
        session: 's1',
        states: {
          's1': ChatState(
            items: [
              user(1, '看看目录'),
              tool('ls', 'bash', {'command': 'ls -la'}, result: 'total 8\n\x1B[34mlib\x1B[0m\n'),
            ],
            loading: false,
          ),
        },
      );
      await pumpScreen(tester, harness);
      expect(find.text('ls -la'), findsOneWidget);
      expect(find.text('输出'), findsNothing);
      await tester.tap(find.text('ls -la'));
      await pumpFrames(tester, 4);
      expect(find.text('命令'), findsOneWidget);
      expect(find.text('输出'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is SelectableText && (w.textSpan?.toPlainText().contains('lib') ?? false)),
        findsOneWidget,
      );
    });
  });

  group('scrolling', () {
    ChatState longChat({required String tail, bool running = true}) {
      final items = <ChatItem>[
        for (var i = 0; i < 12; i++) ...[
          user(i * 2, '第 $i 个问题:这段代码是做什么的?'),
          assistant(i * 2 + 1, '这是第 $i 个回答。\n\n${'内容很长的一段解释。' * 12}'),
        ],
        assistant(100, tail, streaming: running),
      ];
      return ChatState(items: items, running: running, loading: false);
    }

    testWidgets('follows the stream at the bottom, holds still when '
        'scrolled up', (tester) async {
      final harness = ChatHarness(
        session: 's4',
        states: {'s4': longChat(tail: '开始')},
      );
      await pumpScreen(tester, harness);
      final chat = harness.controllers['s4']!;
      var position = listPosition(tester);
      expect(position.pixels, closeTo(position.maxScrollExtent, 1));

      chat.emit(longChat(tail: '开始${'继续输出更多的文字。' * 40}'));
      await pumpFrames(tester, 4);
      position = listPosition(tester);
      expect(position.maxScrollExtent, greaterThan(0));
      expect(position.pixels, closeTo(position.maxScrollExtent, 1));

      // The reader scrolls up: new tokens must not drag the view.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
      await pumpFrames(tester, 6);
      final held = listPosition(tester).pixels;
      chat.emit(longChat(tail: '开始${'继续输出更多的文字。' * 80}'));
      await pumpFrames(tester, 4);
      expect(listPosition(tester).pixels, closeTo(held, 1));
      expect(find.byIcon(AppIcons.scrollToBottom), findsOneWidget);

      // Jump back down and follow again.
      await tester.tap(find.byIcon(AppIcons.scrollToBottom));
      await pumpFrames(tester, 6);
      position = listPosition(tester);
      expect(position.pixels, closeTo(position.maxScrollExtent, 1));
    });

    testWidgets('older history loads at the top without moving the view', (tester) async {
      ChatState page(int from) => ChatState(
        items: [for (var i = from; i < 24; i++) user(i, '第 $i 条消息${'。' * 30}')],
        hasMoreHistory: from > 0,
        loading: false,
      );
      final harness = ChatHarness(session: 's6', states: {'s6': page(12)});
      await pumpScreen(tester, harness);
      final chat = harness.controllers['s6']!;

      // Scroll to the top of what is loaded: the list asks for more.
      await tester.fling(find.byType(CustomScrollView), const Offset(0, 3000), 3000);
      await pumpFrames(tester, 10);
      expect(chat.loadOlderCalls, greaterThan(0));

      final anchor = find.textContaining('第 13 条消息');
      final before = tester.getTopLeft(anchor);
      chat.emit(page(0));
      await pumpFrames(tester, 4);
      expect(tester.getTopLeft(anchor).dy, closeTo(before.dy, 1));
      expect(find.textContaining('第 11 条消息'), findsOneWidget);
    });

    testWidgets('a captured DSH turn renders through the transcript', (tester) async {
      final transcript = ChatTranscript();
      final file = File('../packages/dsh_client/test/fixtures/follow_approval_with_resync.jsonl');
      for (final line in file.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        transcript.apply(parseFollowFrame('s5', jsonDecode(line)));
      }
      final harness = ChatHarness(
        session: 's5',
        states: {
          's5': ChatState(
            items: transcript.items,
            running: transcript.running,
            title: transcript.title,
            loading: false,
          ),
        },
      );
      await pumpScreen(tester, harness);
      expect(find.text(transcript.title!), findsOneWidget);
      expect(find.text('echo hi'), findsOneWidget);
    });
  });
}
