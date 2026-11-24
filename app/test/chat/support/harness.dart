import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/speech/voice_cloud.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/balance_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/commands_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/features_state.dart' show agentPresetsProvider, permissionStateProvider;
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/usage_state.dart';
import 'package:dsh_app/ui/common/side_insets.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_fonts.dart';

export '../../support/test_fonts.dart' show cjkFamily, loadTestFonts;

ThemeData testTheme(Brightness brightness) {
  final base = brightness == Brightness.dark ? buildDarkTheme() : buildLightTheme();
  // The device resolves CJK through the system fallback chain; the test
  // engine only knows what was loaded, so name the fallback explicitly.
  return withTestFonts(base.copyWith(textTheme: base.textTheme.apply(fontFamilyFallback: const [cjkFamily])));
}

/// Phone-sized view (390×844 logical, dpr 2) with a status bar and a
/// gesture bar.
void usePhoneView(WidgetTester tester) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
  tester.view.viewPadding = const FakeViewPadding(top: 48, bottom: 32);
  addTearDown(tester.view.reset);
}

Widget testApp(Widget home, {Brightness brightness = Brightness.light, List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: [accountWalletBalanceProvider.overrideWithValue(null), ...overrides],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: testTheme(Brightness.light),
      darkTheme: testTheme(Brightness.dark),
      themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      // As the app's root does (lib/app.dart).
      builder: (context, child) => MirroredSideInsets(child: child!),
      home: home,
    ),
  );
}

/// A client that is never asked to talk to anything: every provider that
/// would use it is overridden.
final fakeConnection = HostConnection(client: DshClient(DshConnection(Uri.parse('http://127.0.0.1:9'))), isLocal: true);

final testCatalog = ModelCatalog(
  defaultSelection: const ModelSelection(
    provider: 'deepseek-official',
    model: 'deepseek-v4-pro',
    reasoningEffort: 'high',
  ),
  routableProviders: const ['deepseek-official'],
  groups: const [
    ProviderGroup('deepseek-official', 'DeepSeek', [
      ModelInfo(
        provider: 'deepseek-official',
        id: 'deepseek-v4-pro',
        name: 'DeepSeek-V4-Pro',
        description: '更强的推理与编码',
        efforts: [
          ReasoningEffort('off', 'Off', null),
          ReasoningEffort('low', 'Low', null),
          ReasoningEffort('high', 'High', null),
          ReasoningEffort('max', 'Max', null),
        ],
        defaultEffort: 'high',
      ),
      ModelInfo(
        provider: 'deepseek-official',
        id: 'deepseek-flash',
        name: 'DeepSeek-V41-Flash',
        description: '更快、更省',
        efforts: [
          ReasoningEffort('off', 'Off', null),
          ReasoningEffort('low', 'Low', null),
          ReasoningEffort('high', 'High', null),
        ],
        defaultEffort: 'high',
      ),
    ]),
  ],
  failures: const [],
);

/// Chat controller that serves a fixed [ChatState] and records calls.
class FakeChatController extends ChatController {
  FakeChatController(super.sessionId, this.initial);

  final ChatState initial;
  final sent = <String>[];
  final sentAttachments = <List<DraftAttachment>>[];
  final sentModes = <SendMode>[];
  final steered = <String>[];
  final withdrawn = <String>[];
  final sentNow = <String>[];
  final responses = <(ApprovalRequest, ApprovalDecision)>[];
  final answers = <(UserQuestionRequest, List<QuestionAnswer>)>[];
  final models = <ModelSelection>[];
  bool answerSucceeds = true;
  Future<bool>? sendResult;
  var cancels = 0;
  var loadOlderCalls = 0;

  /// Kept alive like the real controller, which outlives a plain read.
  @override
  ChatState build() {
    ref.keepAlive();
    return initial;
  }

  void emit(ChatState next) => state = next;

  @override
  Future<bool> send(
    String text, {
    List<DraftAttachment> attachments = const [],
    SendMode mode = SendMode.now,
    bool verbatim = false,
    String? originalRequestId,
    Future<bool> Function(String requestId)? beforeDeliver,
    bool Function()? deliveryAllowed,
  }) async {
    sent.add(text);
    sentAttachments.add(attachments);
    sentModes.add(mode);
    return await (sendResult ?? Future.value(true));
  }

  @override
  Future<bool> retryFailed(PendingPrompt prompt, String text) async {
    final ok = await send(text, attachments: prompt.attachments);
    if (ok) {
      state = state.copyWith(
        pending: [
          for (final p in state.pending)
            if (p.requestId != prompt.requestId) p,
        ],
      );
    }
    return ok;
  }

  @override
  Future<bool> steerQueued(PendingPrompt prompt) async {
    steered.add(prompt.requestId);
    return true;
  }

  @override
  Future<bool> withdrawQueued(PendingPrompt prompt) async {
    withdrawn.add(prompt.requestId);
    state = state.copyWith(
      pending: [
        for (final p in state.pending)
          if (p.requestId != prompt.requestId) p,
      ],
    );
    return true;
  }

  @override
  Future<List<PendingPrompt>> sendNow(PendingPrompt prompt) async {
    sentNow.add(prompt.requestId);
    return const [];
  }

  @override
  Future<List<PendingPrompt>> cancel() async {
    cancels++;
    return const [];
  }

  @override
  Future<void> respond(ApprovalRequest request, ApprovalDecision decision) async {
    responses.add((request, decision));
  }

  @override
  Future<bool> answer(UserQuestionRequest request, List<QuestionAnswer> answers) async {
    this.answers.add((request, answers));
    return answerSucceeds;
  }

  @override
  Future<bool> setModel(ModelSelection selection) async {
    models.add(selection);
    return true;
  }

  @override
  Future<void> loadOlder() async => loadOlderCalls++;

  final commandLines = <String>[];

  @override
  Future<bool> runCommand(String line) async {
    commandLines.add(line);
    return true;
  }

  final allowAllRequests = <ApprovalRequest>[];
  final autoApproveToggles = <bool>[];

  @override
  Future<void> allowAll(ApprovalRequest request) async {
    allowAllRequests.add(request);
    autoApproveToggles.add(true);
    state = state.copyWith(autoApprove: true, autoAnswered: {...state.autoAnswered, request.eventId});
  }

  @override
  void setAutoApprove(bool enabled) {
    autoApproveToggles.add(enabled);
    state = state.copyWith(autoApprove: enabled);
  }

  // Message actions: nothing is branchable or ratable unless a test says so.

  /// Reply seq -> fork cut, for [branchPointAfter].
  final branchPoints = <int, int>{};

  /// Reply seq -> DSH message id, for [replyMessageId].
  final replyIds = <int, String>{};
  final branched = <int>[];
  final edited = <int>[];
  final reported = <String>[];

  /// What a fork returns; null = it failed.
  ForkOutcome? forkOutcome = const ForkOutcome('fork-session');

  @override
  int? branchPointAfter(AssistantChatItem item) => branchPoints[item.seq];

  @override
  String? replyMessageId(AssistantChatItem item) => replyIds[item.seq];

  @override
  Future<ForkOutcome?> branchAfter(AssistantChatItem item) async {
    branched.add(item.seq!);
    return forkOutcome;
  }

  /// The `action` each fork before a prompt was asked with.
  final forkActions = <String>[];

  @override
  Future<ForkOutcome?> forkBeforePrompt(UserChatItem item, {String? action}) async {
    edited.add(item.seq);
    forkActions.add(action ?? '分叉失败');
    return forkOutcome;
  }

  @override
  void reportError(String message) {
    reported.add(message);
    state = state.copyWith(error: message);
  }
}

class FakeSessions extends SessionsController {
  FakeSessions({this.created = 'new-session'});

  final String created;
  var creates = 0;

  /// What the session list says.
  var listed = const <SessionSummary>[];

  @override
  Future<List<SessionSummary>> build() async => listed;

  @override
  Future<String> create({bool autoApprove = true}) async {
    creates++;
    return created;
  }

  @override
  Future<void> refresh() async {}
}

class FixedSession extends CurrentSessionController {
  FixedSession(this.initial);
  final String? initial;

  @override
  String? build() => initial;
}

/// Settings with a key, no storage behind them.
class TestSettings extends SettingsController {
  TestSettings([this.initial = const AppSettings(loaded: true, apiKey: testKey)]);
  final AppSettings initial;

  @override
  AppSettings build() => initial;

  @override
  Future<void> setApiKey(String key) async => state = state.copyWith(apiKey: key);
}

const testKey = 'sk-0123456789abcdef0123456789abcdef';

const healthyBalance = BalanceOk(DeepSeekBalance(currency: 'CNY', total: 110, granted: 10, toppedUp: 100));

const lowBalance = BalanceOk(DeepSeekBalance(currency: 'CNY', total: 3.2, granted: 0, toppedUp: 3.2));

/// Serves a fixed [SessionUsage] instead of watching the Host.
class FakeUsage extends SessionUsageController {
  FakeUsage(super.sessionId, this.usage);
  final SessionUsage usage;

  @override
  SessionUsage build() => usage;
}

/// `commands/list` as DSH 0.2.x returns it (descriptor JSON).
final testHostCommands = parseCommandList([
  {
    'definitionId': '@deepseek-ai/dsh-command-goal',
    'name': 'goal',
    'description': 'Set or view the goal for a long-running task',
    'input': {'hint': '[<objective>|clear|edit <objective>|pause|resume]', 'attachments': true},
  },
  {
    'definitionId': '@deepseek-ai/dsh-plan-mode',
    'name': 'plan',
    'description': 'Enter or leave plan mode',
    'input': {'hint': '[off|message]', 'attachments': true},
  },
  {
    'definitionId': '@deepseek-ai/dsh-command-feedback',
    'name': 'feedback',
    'description': 'Record feedback about this session',
    'input': {'hint': '<text>'},
  },
  {
    'definitionId': '@deepseek-ai/dsh-command-compact',
    'name': 'compact',
    'description': 'Compact older conversation history',
  },
  {
    'definitionId': '@deepseek-ai/dsh-permission-presets',
    'name': 'permission',
    'description': 'Switch the permission preset (sandbox mode + approval policy)',
    'input': {'hint': '<preset>'},
  },
  {
    'definitionId': '@deepseek-ai/dsh-session-log-export',
    'name': 'export',
    'description': 'Download this Session log as a ZIP archive',
  },
]);

/// Everything ChatScreen reads, overridden with fakes.
class ChatHarness {
  ChatHarness({
    this.session,
    this.states = const {},
    this.connected = true,
    String created = 'new-session',
    this.usage = const {},
    this.balance = healthyBalance,
    this.settings = const AppSettings(loaded: true, apiKey: testKey),
    this.catalog,
    this.runtime,
    this.extra = const [],
    this.newChatCatalogs = false,
    FakePicker? picker,
  }) : sessions = FakeSessions(created: created),
       picker = picker ?? FakePicker();

  final String? session;
  final Map<String, ChatState> states;
  final bool connected;
  final FakeSessions sessions;
  final Map<String, SessionUsage> usage;
  final BalanceResult balance;
  final AppSettings settings;
  final ModelCatalog? catalog;
  final LocalRuntimeController Function()? runtime;

  /// Overrides of providers the harness leaves alone (the active host, updates).
  final List<Override> extra;
  final FakePicker picker;

  /// Let the new-chat preset/permission chips read the Host's catalogs.
  /// Off by default: suites that script their Host's traffic must not leave
  /// catalog requests in flight (test/chat/new_chat_options_test.dart opts in).
  final bool newChatCatalogs;
  final controllers = <String, FakeChatController>{};
  final balanceRequests = <String>[];

  /// How many times the model catalog was read (`session/modelCatalog`).
  var catalogReads = 0;

  /// While set, a catalog read waits for it (the Host still listing models).
  Completer<void>? catalogHold;

  List<Override> get overrides => [
    activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(connected ? fakeConnection : null)),
    // Local-engine features (account sign-in) read the on-device engine
    // directly; there is no native runtime in tests.
    localConnectionProvider.overrideWith(NoLocalEngine.new),
    // The engine banners (safe mode, failures) read the runtime status.
    localRuntimeProvider.overrideWith(runtime ?? StaticRuntime.new),
    modelCatalogProvider.overrideWith((ref) async {
      catalogReads++;
      await catalogHold?.future;
      return catalog ?? testCatalog;
    }),
    attachmentPickerProvider.overrideWithValue(picker),
    settingsProvider.overrideWith(() => TestSettings(settings)),
    // The test key must not send dictation to DeepSeek: the phone's and the
    // engine's recognizers as before (test/speech covers the cloud ones).
    voiceCloudProvider.overrideWithValue((_) async => null),
    voiceCloudLikelyProvider.overrideWithValue(() => false),
    balanceFetcherProvider.overrideWithValue((key) async {
      balanceRequests.add(key);
      return balance;
    }),
    hostCommandsProvider.overrideWith((ref, sessionId) async => testHostCommands),
    if (!newChatCatalogs) ...[
      agentPresetsProvider.overrideWith((ref) async => null),
      permissionStateProvider.overrideWith((ref, sessionId) async => null),
    ],
    sessionUsageProvider.overrideWith2((id) => FakeUsage(id, usage[id] ?? SessionUsage.empty)),
    sessionsProvider.overrideWith(() => sessions),
    currentSessionProvider.overrideWith(() => FixedSession(session)),
    chatProvider.overrideWith2(
      (id) => controllers[id] = FakeChatController(id, states[id] ?? const ChatState(loading: false)),
    ),
    ...extra,
  ];
}

/// Pumps a few frames without waiting for repeating animations to settle.
Future<void> pumpFrames(WidgetTester tester, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Clipboard calls in tests go nowhere instead of throwing.
void mockClipboard(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
}

Uint8List bytesOf(String path) => File(path).readAsBytesSync();

/// The on-device engine isn't running (no platform channels in tests).
class NoLocalEngine extends LocalConnectionController {
  @override
  Future<HostConnection?> build() async => null;
}

/// A 4×4 PNG: real bytes, so thumbnails decode in tests.
final tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGPwTt/yHxkzkC4AAAPnJlH/osXzAAAAAElFTkSuQmCC',
);

/// System pickers stand-in: hands back whatever the test queued.
class FakePicker implements AttachmentPicker {
  List<DraftAttachment> images = [];
  DraftAttachment? photo;
  List<DraftAttachment> files = [];
  String? text;
  final calls = <String>[];

  @override
  Future<List<DraftAttachment>> pickImages({required int limit}) async {
    calls.add('images:$limit');
    return images.take(limit).toList();
  }

  @override
  Future<DraftAttachment?> takePhoto() async {
    calls.add('camera');
    return photo;
  }

  @override
  Future<PickedAttachments> pickFiles({int limit = maxAttachments, int heldBytes = 0}) async {
    calls.add('files');
    return PickedAttachments(files);
  }

  @override
  Future<String?> pickTextFile({int maxBytes = 64 * 1024}) async {
    calls.add('text');
    return text;
  }
}

/// The on-device runtime, running normally (no native side in tests).
class StaticRuntime extends LocalRuntimeController {
  @override
  LocalRuntimeState build() =>
      const LocalRuntimeState(loaded: true, status: RuntimeStatus(phase: RuntimePhase.running));

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}
