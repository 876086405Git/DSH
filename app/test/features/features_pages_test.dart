// 全部功能 and the native mirrors of official pages (自动化任务, 后台任务,
// 技能, 权限, Agent 预设): navigation, the RPCs behind their actions, and
// goldens (light + dark). Regenerate the goldens with
// `flutter test --update-goldens test/features/features_pages_test.dart`.

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/features_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/settings/search/settings_search_page.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/features/agent_presets_page.dart';
import 'package:dsh_app/ui/features/all_features_page.dart';
import 'package:dsh_app/ui/features/jobs_page.dart';
import 'package:dsh_app/ui/features/permission_page.dart';
import 'package:dsh_app/ui/features/schedules_page.dart';
import 'package:dsh_app/ui/features/skills_page.dart';
import 'package:dsh_app/ui/terminal/terminal_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/ui/web/web_target.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../phone/support.dart' show FixedActiveHost;
import '../plugins/support/fake_plugin_host.dart';
import '../shell/golden_harness.dart' show FakeRuntime, runningStatus;

final _now = DateTime(2026, 10, 24, 15, 20);

SessionSummary _session(String id, String title) => SessionSummary(
  sessionId: id,
  updatedAt: _now,
  running: false,
  blank: false,
  agentAvailable: false,
  cwd: '/root/workspace',
  projections: SessionProjections(1, {'title': title}),
);

final _sessions = [_session('s1', '修复登录按钮重复提交'), _session('s2', '每天的构建检查')];

class _Sessions extends SessionsController {
  @override
  Future<List<SessionSummary>> build() async => _sessions;
}

class _Current extends CurrentSessionController {
  _Current(this.id);
  final String? id;

  @override
  String? build() => id;
}

class _Settings extends SettingsController {
  _Settings(this.initial);
  final AppSettings initial;

  @override
  AppSettings build() => initial;

  @override
  Future<void> setAutoApproveCommands(bool value) async {
    state = state.copyWith(autoApproveCommands: value);
  }
}

ScheduleTask _task(
  String id,
  String title,
  String kind, {
  String session = 's1',
  bool active = true,
  String? time,
  List<int> weekdays = const [],
  int? everySeconds,
  DateTime? next,
  DateTime? last,
}) => ScheduleTask(
  id: id,
  sessionId: session,
  kind: kind,
  title: title,
  prompt: '$title：整理一下，发我一段摘要。',
  active: active,
  record: {'id': id, 'kind': kind, 'title': title},
  time: time,
  timeZone: time == null ? null : 'Asia/Shanghai',
  weekdays: weekdays,
  everySeconds: everySeconds,
  scheduledAt: next,
  lastDeliveredAt: last,
);

final _tasks = [
  _task('sch-1', '日报提醒', 'daily', time: '09:00', next: DateTime(2026, 10, 25, 9), last: DateTime(2026, 10, 24, 9)),
  _task('sch-2', '周报草稿', 'weekly', time: '18:30', weekdays: [1, 2, 3, 4, 5], next: DateTime(2026, 10, 26, 18, 30)),
  _task('sch-3', '检查夜间构建', 'every', session: 's2', everySeconds: 7200, next: DateTime(2026, 10, 24, 16)),
  _task('sch-4', '提醒我看发布结果', 'at', active: false, last: DateTime(2026, 10, 23, 20, 15)),
];

final _jobs = [
  JobInfo(
    id: 'job-1',
    kind: 'bash',
    label: 'npm run dev -- --host 0.0.0.0',
    status: 'running',
    startedAt: _now.subtract(const Duration(minutes: 3, seconds: 5)),
    progress: 'ready on :5173',
  ),
  JobInfo(
    id: 'job-2',
    kind: 'bash',
    label: 'flutter test test/auth --reporter compact',
    status: 'completed',
    startedAt: _now.subtract(const Duration(minutes: 9)),
    finishedAt: _now.subtract(const Duration(minutes: 8, seconds: 18)),
  ),
  JobInfo(
    id: 'job-3',
    kind: 'bash',
    label: 'pnpm build',
    status: 'failed',
    startedAt: _now.subtract(const Duration(minutes: 20)),
    finishedAt: _now.subtract(const Duration(minutes: 19, seconds: 48)),
  ),
];

const _skills = [
  SkillInfo(name: 'code-review', description: '按团队规范审查改动，列出问题和修改建议。'),
  SkillInfo(name: 'pdf', description: '读取、拆分、合并 PDF，提取表格和文字。', whenToUse: '用户给了 PDF 文件时'),
  SkillInfo(name: 'release-notes', description: '根据提交记录写发布说明。', modelInvocable: false),
];

const _presets = [
  AgentPresetInfo(id: 'standard', isDefault: true, order: 1),
  AgentPresetInfo(id: 'ptc', order: 2),
  AgentPresetInfo(id: 'minimal', order: 3),
  AgentPresetInfo(id: 'cordis', order: 4),
];

const _permissions = PermissionState(
  options: [
    PermissionOption('read-only', 'read-only'),
    PermissionOption('workspace-write', 'workspace-write'),
    PermissionOption('danger-full-access', 'danger-full-access'),
  ],
  hostDefault: 'workspace-write',
  current: 'read-only',
  defaultRevision: 2,
);

/// Fixed data for every feature provider (goldens and navigation).
List<Override> _fixed({String? current = 's1', bool autoApprove = false}) => [
  activeConnectionProvider.overrideWithValue(AsyncData(fakeConnection)),
  localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus))),
  sessionsProvider.overrideWith(_Sessions.new),
  currentSessionProvider.overrideWith(() => _Current(current)),
  settingsProvider.overrideWith(() => _Settings(AppSettings(loaded: true, autoApproveCommands: autoApprove))),
  schedulesProvider.overrideWith((ref) async => _tasks),
  scheduleHistoryProvider.overrideWith(
    (ref, task) async => ScheduleHistory(
      runs: [
        ScheduleRun(
          scheduledAt: DateTime(2026, 10, 24, 9),
          deliveredAt: DateTime(2026, 10, 24, 9, 0, 1),
          prompt: task.prompt,
        ),
        ScheduleRun(
          scheduledAt: DateTime(2026, 10, 23, 9),
          deliveredAt: DateTime(2026, 10, 23, 9, 0, 2),
          prompt: task.prompt,
        ),
      ],
    ),
  ),
  jobsProvider.overrideWith((ref, id) => Stream.value(_jobs)),
  skillsProvider.overrideWith((ref, id) async => _skills),
  agentPresetsProvider.overrideWith((ref) async => _presets),
  permissionStateProvider.overrideWith((ref, id) async => _permissions),
];

/// Scrolls [finder] into the middle of the page (clear of the floating bar).
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await pumpFrames(tester);
}

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  Brightness brightness = Brightness.light,
  List<Override>? overrides,
}) async {
  usePhoneView(tester);
  await tester.pumpWidget(testApp(page, brightness: brightness, overrides: overrides ?? _fixed()));
  await pumpFrames(tester, 6);
}

void main() {
  setUpAll(loadTestFonts);

  group('自动化任务 on HarmonyOS', () {
    final note = lookupL10n(AppLocale.zhCN).harmonySchedulesLocal;

    Future<void> schedules(WidgetTester tester, {required String os, HostRef host = HostRef.local}) => _pump(
      tester,
      SchedulesPage(now: _now),
      overrides: [
        ..._fixed(),
        operatingSystemProvider.overrideWithValue(os),
        activeHostProvider.overrideWith(() => FixedActiveHost(host)),
      ],
    );

    testWidgets('on-device tasks only fire while the app runs, and it says so', (tester) async {
      await schedules(tester, os: 'ohos');
      expect(find.text(note), findsOneWidget);
    });

    testWidgets('a remote host\'s tasks run regardless', (tester) async {
      await schedules(tester, os: 'ohos', host: const HostRef.relay('r1'));
      expect(find.text(note), findsNothing);
    });

    testWidgets('Android has nothing to add', (tester) async {
      await schedules(tester, os: 'android');
      expect(find.text(note), findsNothing);
    });
  });

  group('全部功能', () {
    testWidgets('native items push their page; web items deep-link', (tester) async {
      final opened = <DshWebTarget>[];
      await _pump(
        tester,
        const AllFeaturesPage(),
        overrides: [..._fixed(), dshWebOpenerProvider.overrideWithValue((context, ref, target) => opened.add(target))],
      );
      // The overview card names the conversation the tiles act on.
      expect(find.text('当前打开的对话'), findsOneWidget);
      expect(find.text('修复登录按钮重复提交'), findsOneWidget);

      // Native terminal keeps its conversation; no redundant web fallback.
      await _reveal(tester, find.text('终端'));
      final terminal = find.ancestor(of: find.text('终端'), matching: find.byType(FeatureTileFor));
      final terminalPage = tester.widget<FeatureTileFor>(terminal).item.native!('s1');
      expect(terminalPage, isA<TerminalPage>());
      expect((terminalPage as TerminalPage).sessionId, 's1');
      expect(find.descendant(of: terminal, matching: find.byTooltip('在网页版打开')), findsNothing);

      // The row opens the native automation page, without a web fallback.
      await _reveal(tester, find.text('自动化任务'));
      await tester.tap(find.text('自动化任务'));
      await tester.pumpAndSettle();
      expect(find.byType(SchedulesPage), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      final row = find.ancestor(of: find.text('自动化任务'), matching: find.byType(FeatureTileFor));
      expect(find.descendant(of: row, matching: find.byTooltip('在网页版打开')), findsNothing);
      expect(tester.widget<FeatureTileFor>(row).item.native!('s1'), isA<SchedulesPage>());
      expect(opened, isEmpty);

      // Settings shortcuts open the same pages as 设置.
      await _reveal(tester, find.text('远程主机'));
      final remote = find.ancestor(of: find.text('远程主机'), matching: find.byType(FeatureTileFor));
      expect(tester.widget<FeatureTileFor>(remote).item.native!(null), isA<RemoteScreen>());
      expect(find.text('Agent 循环'), findsNothing, reason: 'settings live in 设置');
      expect(opened, isEmpty);

      // Web-only: 网页版 itself.
      await _reveal(tester, find.text('网页版'));
      await tester.tap(find.text('网页版'));
      await pumpFrames(tester);
      expect(opened.last, const DshWebTarget());
    });

    testWidgets('settings shortcuts last, then all-settings spanning the grid', (tester) async {
      await _pump(tester, const AllFeaturesPage());
      await _reveal(tester, find.text('全部设置'));
      Rect card(String title) =>
          tester.getRect(find.ancestor(of: find.text(title), matching: find.byType(FeatureTileFor)).first);
      final all = tester.getRect(find.ancestor(of: find.text('全部设置'), matching: find.byType(GlassSurface)).first);
      expect(all.left, card('模型').left);
      expect(all.right, card('权限').right);
      expect(all.left, card('手机操控').left);
      expect(all.right, card('远程主机').right);
      expect(all.top - card('远程主机').bottom, 12, reason: 'the grid\'s own gap');
      final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(all.left, 16);
      expect(width - all.right, 16);

      // Search over the settings hub: back lands on the hub.
      await tester.tap(find.text('全部设置'));
      await pumpFrames(tester, 6);
      expect(find.byType(SettingsSearchPage), findsOneWidget);
      expect(find.byType(SettingsScreen, skipOffstage: false), findsOneWidget);
    });

    testWidgets('引用 goes back to the chat, where @ lives', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AllFeaturesPage())),
                  child: const Text('聊天'),
                ),
              ),
            ),
          ),
          overrides: _fixed(),
        ),
      );
      await tester.tap(find.text('聊天'));
      await tester.pumpAndSettle();
      expect(find.byType(AllFeaturesPage), findsOneWidget);
      await _reveal(tester, find.text('引用文件和对话'));
      await tester.tap(find.text('引用文件和对话'));
      await tester.pumpAndSettle();
      expect(find.byType(AllFeaturesPage), findsNothing);
      expect(find.text('聊天'), findsOneWidget);
    });

    testWidgets('conversation items are disabled without a conversation', (tester) async {
      final opened = <DshWebTarget>[];
      await _pump(
        tester,
        const AllFeaturesPage(),
        overrides: [
          ..._fixed(current: null),
          dshWebOpenerProvider.overrideWithValue((context, ref, target) => opened.add(target)),
        ],
      );
      expect(find.text('还没打开对话'), findsOneWidget);
      expect(find.text('先打开一个对话'), findsWidgets);
      Future<void> tapItem(String title) async {
        await tester.ensureVisible(find.text(title));
        await pumpFrames(tester);
        await tester.tap(find.text(title));
      }

      await tapItem('后台任务');
      await tapItem('终端');
      await pumpFrames(tester);
      expect(find.byType(JobsPage), findsNothing);
      expect(opened, isEmpty);
      // Not bound to a conversation: still opens (the web home here).
      await _reveal(tester, find.text('网页版'));
      await tester.tap(find.text('网页版'));
      await pumpFrames(tester);
      expect(opened.single, const DshWebTarget());
    });
  });

  group('actions call the Host', () {
    late FakePluginCarrier carrier;
    late DshClient client;

    setUp(() {
      carrier = FakePluginCarrier();
      client = DshClient.withCarrier(carrier);
    });
    tearDown(() => client.close());

    List<Override> live() => [
      activeConnectionProvider.overrideWithValue(AsyncData(fakeHost(client))),
      sessionsProvider.overrideWith(_Sessions.new),
      currentSessionProvider.overrideWith(() => _Current('s1')),
      settingsProvider.overrideWith(() => _Settings(const AppSettings(loaded: true))),
    ];

    testWidgets('自动化任务: list from the catalog, filter, delete', (tester) async {
      carrier.handlers['schedule/catalog'] = (_) => [
        {
          'id': 'sch-1',
          'kind': 'daily',
          'title': '日报提醒',
          'prompt': '写日报',
          'time': '09:00',
          'timeZone': 'Asia/Shanghai',
          'scheduledAt': '2026-10-25T01:00:00.000Z',
          'sessionId': 's1',
          'status': 'active',
        },
        {
          'id': 'sch-2',
          'kind': 'at',
          'title': '看发布结果',
          'prompt': '看看',
          'scheduledAt': '2026-10-20T01:00:00.000Z',
          'sessionId': 's1',
          'status': 'inactive',
        },
      ];
      carrier.handlers['schedule/history'] = (_) => {
        'id': 'sch-1',
        'records': <Object?>[],
        'earlierRecordsUnavailable': false,
        'earlierRecordsPruned': false,
        'retention': {'days': 30, 'records': 200},
      };
      carrier.handlers['schedule/delete'] = (_) => {'id': 'sch-1', 'deleted': true};
      await _pump(tester, const SchedulesPage(), overrides: live());

      expect(find.text('日报提醒'), findsOneWidget);
      expect(find.text('看发布结果'), findsOneWidget);
      await tester.tap(find.text('已结束 1'));
      await pumpFrames(tester);
      expect(find.text('日报提醒'), findsNothing);
      await tester.tap(find.text('全部 2'));
      await pumpFrames(tester);

      await tester.tap(find.text('日报提醒'));
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleDetailPage), findsOneWidget);
      expect(find.text('每天 09:00'), findsOneWidget);
      expect(find.text('修复登录按钮重复提交'), findsOneWidget, reason: 'related conversation by title');

      await _reveal(tester, find.text('删除任务'));
      await tester.tap(find.text('删除任务'));
      await tester.pumpAndSettle();
      final delete = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '删除'));
      expect(
        delete.style?.foregroundColor?.resolve({}),
        DshColors.of(tester.element(find.byType(AlertDialog))).onDanger,
      );
      expect(find.text('sch-1'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(carrier.argsOf('schedule/delete').single, {
        'request': {'sessionId': 's1', 'id': 'sch-1'},
      });
      expect(find.byType(ScheduleDetailPage), findsNothing);
      expect(find.text('任务已删除'), findsOneWidget);
    });

    testWidgets('权限: current via /permission, default via settings', (tester) async {
      carrier.handlers['permissionPresets/catalog'] = (_) => {
        'options': [
          {'value': 'read-only', 'name': 'read-only'},
          {'value': 'workspace-write', 'name': 'workspace-write'},
          {'value': 'danger-full-access', 'name': 'danger-full-access'},
        ],
        'defaultOptions': [
          {'value': 'read-only', 'name': 'read-only'},
          {'value': 'workspace-write', 'name': 'workspace-write'},
          {'value': 'danger-full-access', 'name': 'danger-full-access'},
        ],
        'defaultPreset': 'workspace-write',
      };
      carrier.handlers['settings/describe'] = (_) => {
        'writable': true,
        'namespaces': [
          {'ns': 'permission', 'value': <String, Object?>{}, 'revision': 4},
        ],
      };
      carrier.handlers['session/projections'] = (_) => {
        'kind': 'sequenced',
        'asOfSeq': 3,
        'values': {
          'permissions': {'currentValue': 'read-only'},
        },
      };
      carrier.handlers['commands/execute'] = (_) => {
        'commandId': 'c1',
        'result': {'kind': 'success', 'text': 'ok'},
      };
      carrier.handlers['settings/mutate'] = (args) => {
        'ns': 'permission',
        'value': {'defaultPreset': 'read-only'},
        'revision': 5,
      };
      await _pump(tester, const PermissionPage(sessionId: 's1'), overrides: live());

      expect(find.text('当前对话'), findsOneWidget);
      // First group: current conversation.
      await tester.tap(find.text('工作区内修改').first);
      await tester.pumpAndSettle();
      expect(carrier.argsOf('commands/execute').single, {
        'agentId': 's1',
        'line': '/permission workspace-write',
        'submittedAttachments': <Object?>[],
      });

      // Full access asks first.
      await tester.tap(find.text('完全权限').last);
      await tester.pumpAndSettle();
      expect(find.text('开启完全权限？'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '开启完全权限'), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(SheetHeader), matching: find.byType(SheetIconButton)));
      await tester.pumpAndSettle();
      expect(carrier.argsOf('settings/mutate'), isEmpty);

      await tester.tap(find.text('仅可查看').last);
      await tester.pumpAndSettle();
      expect(carrier.argsOf('settings/mutate').single, {
        'ns': 'permission',
        'ops': [
          {
            'op': 'set',
            'path': ['defaultPreset'],
            'value': 'read-only',
          },
        ],
        'expectedRevision': 4,
      });
    });

    testWidgets('Agent 预设: set the default for new conversations', (tester) async {
      carrier.handlers['agentPresets/list'] = (_) => {
        'presets': [
          {'id': 'standard', 'order': 1, 'isDefault': true},
          {'id': 'ptc', 'order': 2, 'isDefault': false},
        ],
      };
      carrier.handlers['settings/describe'] = (_) => {
        'writable': true,
        'namespaces': [
          {'ns': 'agent-preset-registry', 'value': <String, Object?>{}, 'revision': 1},
        ],
      };
      carrier.handlers['settings/update'] = (args) => {
        'ns': 'agent-preset-registry',
        'value': args['patch'],
        'revision': 2,
      };
      await _pump(tester, const AgentPresetsPage(), overrides: live());
      expect(find.text('标准模式'), findsOneWidget);
      expect(find.text('新对话默认'), findsOneWidget);
      await tester.tap(find.text('PTC 模式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设为新对话默认'));
      await tester.pumpAndSettle();
      expect(carrier.argsOf('settings/update').single, {
        'ns': 'agent-preset-registry',
        'patch': {'selectedDefault': 'ptc'},
        'expectedRevision': 1,
      });
    });

    testWidgets('后台任务: stop asks, then kills', (tester) async {
      carrier.handlers['job/kill'] = (_) => {'outcome': 'requested'};
      await _pump(
        tester,
        JobsPage(sessionId: 's1', now: _now),
        overrides: [...live(), jobsProvider.overrideWith((ref, id) => Stream.value(_jobs))],
      );
      expect(find.text('进行中'), findsOneWidget);
      expect(find.text('已结束 · 2'), findsOneWidget);
      await tester.tap(find.text('npm run dev -- --host 0.0.0.0'));
      await tester.pumpAndSettle();
      expect(find.byType(JobOutputPage), findsOneWidget);
      await tester.tap(find.byTooltip('停止'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '停止'));
      await tester.pumpAndSettle();
      expect(carrier.argsOf('job/kill').single, {
        'request': {'sessionId': 's1', 'jobId': 'job-1'},
      });
    });
  });

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    group('goldens ($mode)', () {
      Future<void> golden(WidgetTester tester, String name, Widget page, {List<Override>? overrides}) async {
        await _pump(tester, page, brightness: brightness, overrides: overrides);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${name}_$mode.png'));
      }

      testWidgets('all features', (tester) => golden(tester, 'all_features', const AllFeaturesPage()));
      testWidgets('schedules', (tester) => golden(tester, 'schedules', SchedulesPage(now: _now)));
      testWidgets(
        'schedule detail',
        (tester) => golden(tester, 'schedule_detail', ScheduleDetailPage(task: _tasks.first, now: _now)),
      );
      testWidgets('jobs', (tester) => golden(tester, 'jobs', JobsPage(sessionId: 's1', now: _now)));
      testWidgets('skills', (tester) => golden(tester, 'skills', const SkillsPage(sessionId: 's1')));
      testWidgets(
        'permission',
        (tester) =>
            golden(tester, 'permission', const PermissionPage(sessionId: 's1'), overrides: _fixed(autoApprove: true)),
      );
      testWidgets('agent presets', (tester) => golden(tester, 'agent_presets', const AgentPresetsPage()));
    });
  }
}
