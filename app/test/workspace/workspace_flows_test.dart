// Workspace flows against the in-memory host: the drawer's switcher filters
// the list and pins conversations, 「添加工作区」 walks the folder picker
// (browse, new folder, add), the management page renames, pins, groups and
// removes, and remote hosts only get what their carrier serves.

import 'dart:ui' show Tristate;

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/common/breadcrumb_row.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:dsh_app/ui/workspace/directory_picker.dart';
import 'package:dsh_app/ui/workspace/workspace_switcher.dart';
import 'package:dsh_app/ui/workspace/workspaces_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<ProviderContainer> _pump(WidgetTester tester, Widget home, List<Override> overrides) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(goldenApp(home: home, brightness: Brightness.light, overrides: overrides));
  await _settle(tester);
  return ProviderScope.containerOf(tester.element(find.byType(home.runtimeType).first));
}

/// A registry whose first baseline arrives only when the test says so.
class _LateWorkspaces extends WorkspacesController {
  @override
  WorkspacesState build() => const WorkspacesState(status: WorkspacesStatus.loading);

  void arrive(FakeWorkspaceHost host) => state = WorkspacesState(
    status: WorkspacesStatus.ready,
    workspaces: host.workspaces.map(Workspace.fromJson).toList(),
  );
}

class _RemoteHost extends ActiveHostController {
  _RemoteHost(this.id);
  final String id;
  @override
  HostRef build() => HostRef.ssh(id);
}

/// The real phone-side view (shared preferences), starting empty.
List<Override> _live(FakeWorkspaceHost host) => workspaceOverrides(host, livePrefs: true);

Finder _tileTitles() => find.descendant(of: find.byType(SessionTile), matching: find.byType(Text));

List<String> _titles(WidgetTester tester) => [for (final t in tester.widgetList<Text>(_tileTitles())) t.data!];

Future<void> _openSwitcher(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byType(WorkspaceSwitcher), matching: find.byType(InkWell)));
  await _settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('drawer', () {
    testWidgets('the switcher filters the list; 全部对话 shows everything again', (tester) async {
      final host = sampleWorkspaceHost();
      final container = await _pump(
        tester,
        HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
        _live(host),
      );
      expect(find.text('全部对话'), findsOneWidget);
      expect(_titles(tester), hasLength(6));

      await _openSwitcher(tester);
      expect(find.text('工作区'), findsOneWidget);
      await tester.tap(find.text('博客'));
      await _settle(tester);
      expect(_titles(tester), ['写一篇 proot 入门']);
      expect(container.read(workspacePrefsProvider).selected, 'ws-2');

      // New conversations now start there.
      await container.read(sessionsProvider.notifier).create();
      expect(host.argsOf('session/create').last, {
        'request': {'workspaceId': 'ws-2'},
      });

      // An empty workspace says so.
      await _openSwitcher(tester);
      await tester.tap(find.text('notes'));
      await _settle(tester);
      expect(find.text('这里还没有对话'), findsOneWidget);

      await _openSwitcher(tester);
      await tester.tap(find.text('全部对话').last);
      await _settle(tester);
      expect(_titles(tester), hasLength(6));
      expect(container.read(workspacePrefsProvider).selected, isNull);
    });

    testWidgets('long-press pins a conversation into 置顶 and unpins it', (tester) async {
      final host = sampleWorkspaceHost();
      await _pump(tester, HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true), _live(host));
      expect(find.text('置顶'), findsNothing);

      await tester.longPress(find.text('DeepSeek API 计费怎么算'));
      await _settle(tester);
      await tester.tap(find.text('置顶'));
      await _settle(tester);
      expect(host.argsOf('workspace/pinSession').single, {
        'request': {'sessionId': 's6'},
      });
      expect(find.text('置顶'), findsOneWidget);
      expect(_titles(tester).first, 'DeepSeek API 计费怎么算');

      await tester.longPress(find.text('DeepSeek API 计费怎么算'));
      await _settle(tester);
      await tester.tap(find.text('取消置顶'));
      await _settle(tester);
      expect(host.argsOf('workspace/unpinSession'), hasLength(1));
      expect(find.text('置顶'), findsNothing);
    });

    testWidgets('no switcher while the host is offline', (tester) async {
      await _pump(tester, HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true), [
        sessionsProvider.overrideWith(() => FakeSessions(sampleSessions())),
      ]);
      expect(find.text('全部对话'), findsNothing);
      expect(find.byType(WorkspaceSwitcher), findsNothing);
    });
  });

  group('添加工作区', () {
    testWidgets('browse from 主目录, create a folder, add it; it becomes the shown workspace', (tester) async {
      final host = sampleWorkspaceHost();
      final container = await _pump(
        tester,
        HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
        _live(host),
      );
      await _openSwitcher(tester);
      await tester.tap(find.text('添加工作区'));
      await _settle(tester);
      expect(find.byType(DirectoryLocationsSheet), findsOneWidget);
      expect(find.text('手机存储'), findsOneWidget);

      await tester.tap(find.text('主目录'));
      await _settle(tester);
      expect(find.byType(DirectoryBrowserPage), findsOneWidget);
      expect(host.argsOf('directoryPicker/list').last, {'path': '/root'});
      await tester.tap(find.text('code'));
      await _settle(tester);
      expect(host.argsOf('directoryPicker/list').last, {'path': '/root/code'});
      // Dot folders wait behind a toggle.
      expect(find.text('.cache'), findsNothing);
      await tester.tap(find.text('显示 1 个隐藏文件夹'));
      await _settle(tester);
      expect(find.text('.cache'), findsOneWidget);

      await tester.tap(find.byTooltip('新建文件夹'));
      await _settle(tester);
      await tester.tap(find.text('创建'));
      await tester.pump();
      expect(find.text('起个名字'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'new-app');
      await tester.tap(find.text('创建'));
      await _settle(tester);
      expect(host.argsOf('directoryPicker/createDirectory').single, {'path': '/root/code', 'name': 'new-app'});
      expect(find.text('添加「new-app」'), findsOneWidget);

      // Back goes up one level before it leaves the browser.
      await tester.tap(find.byTooltip('返回'));
      await _settle(tester);
      expect(find.text('添加「code」'), findsOneWidget);
      await tester.tap(find.text('new-app'));
      await _settle(tester);

      await tester.tap(find.text('添加「new-app」'));
      await _settle(tester);
      expect(host.argsOf('workspace/create').single, {
        'request': {'path': '/root/code/new-app'},
      });
      expect(find.byType(DirectoryBrowserPage), findsNothing);
      expect(find.text('已添加「new-app」'), findsOneWidget);
      final prefs = container.read(workspacePrefsProvider);
      expect(container.read(workspacesProvider).byId(prefs.selected)?.path, '/root/code/new-app');
      expect(prefs.recent, ['/root/code']);
      // The drawer now shows the new, empty workspace.
      expect(find.text('这里还没有对话'), findsOneWidget);
    });

    testWidgets('a typed path opens the browser there; a missing one stays put', (tester) async {
      final host = sampleWorkspaceHost();
      await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(onPressed: () => showDirectoryPicker(context), child: const Text('open')),
        ),
        _live(host),
      );
      await tester.tap(find.text('open'));
      await _settle(tester);
      await tester.tap(find.text('输入路径'));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), 'sdcard');
      await tester.tap(find.text('前往'));
      await tester.pump();
      expect(find.text('写完整路径，如 /root/workspace 或 C:/Users/me'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '/sdcard/Documents/');
      await tester.tap(find.text('前往'));
      await _settle(tester);
      expect(host.argsOf('directoryPicker/list').last, {'path': '/sdcard/Documents'});
      // Phone storage reads as such in the crumbs.
      expect(find.widgetWithText(BreadcrumbCapsule, '手机存储'), findsOneWidget);
      expect(find.text('blog'), findsOneWidget);
    });

    // A Windows host (#1309): its drive paths go as typed, the root keeps its slash.
    for (final path in ['C:/Users/me/project', 'C:/']) {
      testWidgets('a Windows host path goes to the host as typed: $path', (tester) async {
        final host = sampleWorkspaceHost();
        await _pump(
          tester,
          Builder(
            builder: (context) => TextButton(onPressed: () => showDirectoryPicker(context), child: const Text('open')),
          ),
          _live(host),
        );
        await tester.tap(find.text('open'));
        await _settle(tester);
        await tester.tap(find.text('输入路径'));
        await _settle(tester);
        await tester.enterText(find.byType(TextField), path);
        await tester.tap(find.text('前往'));
        await _settle(tester);
        expect(host.argsOf('directoryPicker/list').last, {'path': path});
      });
    }
  });

  group('管理工作区', () {
    testWidgets('rename (with a clash), pin, group, remove with confirmation', (tester) async {
      final host = sampleWorkspaceHost();
      final container = await _pump(tester, const WorkspacesPage(), _live(host));
      expect(find.text('3 个工作区'), findsOneWidget);
      expect(find.text('4 个对话'), findsOneWidget);
      expect(find.text('没有对话'), findsOneWidget);

      Future<void> openSheet(String title) async {
        await tester.tap(find.text(title).first);
        await _settle(tester);
      }

      // Rename: a clash is refused, a new name lands.
      await openSheet('notes');
      await tester.tap(find.text('重命名'));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), '博客');
      await tester.tap(find.text('保存'));
      await _settle(tester);
      expect(find.text('已有同名的工作区'), findsOneWidget);
      await openSheet('notes');
      await tester.tap(find.text('重命名'));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), '笔记');
      await tester.tap(find.text('保存'));
      await _settle(tester);
      expect(host.argsOf('workspace/rename').last, {
        'request': {'workspaceId': 'ws-1', 'title': '笔记'},
      });
      expect(find.text('笔记'), findsOneWidget);

      // Pin: a 置顶 section on top.
      await openSheet('笔记');
      await tester.tap(find.text('置顶'));
      await _settle(tester);
      expect(container.read(workspacePrefsProvider).pinned, ['ws-1']);
      Navigator.of(tester.element(find.text('取消置顶'))).pop();
      await _settle(tester);
      expect(find.text('置顶'), findsOneWidget);

      // Group: a new group becomes a section.
      await openSheet('博客');
      await tester.tap(find.text('分组'));
      await _settle(tester);
      final semantics = tester.ensureSemantics();
      await tester.pump();
      final ungrouped = tester.getSemantics(find.byKey(const ValueKey('workspace-group-ungrouped')));
      expect(ungrouped.flagsCollection.isSelected, Tristate.isTrue);
      expect(ungrouped.flagsCollection.isInMutuallyExclusiveGroup, isTrue);
      semantics.dispose();
      await tester.tap(find.text('新建分组'));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), '个人');
      await tester.tap(find.text('创建'));
      await _settle(tester);
      expect(container.read(workspacePrefsProvider).groups, {'ws-2': '个人'});
      Navigator.of(tester.element(find.text('移除工作区'))).pop();
      await _settle(tester);
      expect(find.text('个人'), findsOneWidget); // the section title
      expect(find.text('其他'), findsOneWidget);

      // Remove: asks first; cancelling keeps it.
      await openSheet('dsh-app');
      await tester.tap(find.text('移除工作区'));
      await _settle(tester);
      expect(find.text('移除「dsh-app」？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await _settle(tester);
      expect(host.argsOf('workspace/delete'), isEmpty);
      await openSheet('dsh-app');
      await tester.tap(find.text('移除工作区'));
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '移除'));
      await _settle(tester);
      expect(host.argsOf('workspace/delete').single, {
        'request': {'workspaceId': 'ws-3'},
      });
      expect(find.text('已移除「dsh-app」'), findsOneWidget);
      expect(find.text('2 个工作区'), findsOneWidget);
    });

    testWidgets('「在这里新建对话」 selects the workspace and opens a new chat', (tester) async {
      final host = sampleWorkspaceHost();
      final container = await _pump(tester, const WorkspacesPage(), _live(host));
      await tester.tap(find.text('博客'));
      await _settle(tester);
      await tester.tap(find.text('在这里新建对话'));
      await _settle(tester);
      expect(container.read(workspacePrefsProvider).selected, 'ws-2');
      expect(container.read(currentSessionProvider), isNull);
    });
  });

  group('remote hosts', () {
    testWidgets('listing-only carriers get no 新建文件夹', (tester) async {
      final relay = FakeWorkspaceHost(home: '/Users/me', folders: ['/Users/me/code'], canCreate: false);
      await _pump(tester, const DirectoryBrowserPage(), workspaceOverrides(relay));
      expect(find.text('选择「主目录」'), findsOneWidget);
      expect(find.text('code'), findsOneWidget);
      expect(find.byTooltip('新建文件夹'), findsNothing);
    });

    testWidgets('a native-picker host says it can’t browse here', (tester) async {
      final native = FakeWorkspaceHost(browse: false);
      await _pump(tester, const DirectoryBrowserPage(), workspaceOverrides(native));
      expect(find.text('这台主机不能在这里浏览文件夹'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });
  });

  group('a new conversation with no workspace selected', () {
    Future<ProviderContainer> pumpOn(
      WidgetTester tester,
      FakeWorkspaceHost host,
      HostConnection connection, [
      List<Override> more = const [],
    ]) async {
      final container = await _pump(
        tester,
        HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
        [
          ...workspaceOverrides(host, livePrefs: true, connection: connection),
          if (!connection.isLocal) activeHostProvider.overrideWith(() => _RemoteHost(connection.hostId!)),
          ...more,
        ],
      );
      await container.read(sessionsProvider.future);
      await _settle(tester);
      return container;
    }

    testWidgets('a remote host without a directory uses the workspace used last', (tester) async {
      final host = sampleWorkspaceHost();
      final container = await pumpOn(tester, host, workspaceHost(host, local: false));
      expect(container.read(newChatInHostDefaultProvider), isFalse);

      await container.read(sessionsProvider.notifier).create();
      expect(host.argsOf('session/create').last, {
        'request': {'workspaceId': 'ws-3'},
      });
    });

    testWidgets('a send that beats the lists waits for them', (tester) async {
      final host = sampleWorkspaceHost();
      final late = _LateWorkspaces();
      final container = await pumpOn(tester, host, workspaceHost(host, local: false), [
        workspacesProvider.overrideWith(() => late),
      ]);

      final created = container.read(sessionsProvider.notifier).create();
      await _settle(tester);
      expect(host.argsOf('session/create'), isEmpty);

      late.arrive(host);
      await _settle(tester);
      await created;
      expect(host.argsOf('session/create').last, {
        'request': {'workspaceId': 'ws-3'},
      });
    });

    testWidgets('lists that never arrive still let the conversation start', (tester) async {
      final host = sampleWorkspaceHost();
      final container = await pumpOn(tester, host, workspaceHost(host, local: false), [
        workspacesProvider.overrideWith(_LateWorkspaces.new),
      ]);

      final created = container.read(sessionsProvider.notifier).create();
      await tester.pump(const Duration(seconds: 3));
      await _settle(tester);
      await created;
      expect(host.argsOf('session/create').last, {'request': <String, Object?>{}});
    });

    testWidgets('a remote host with its own directory keeps it', (tester) async {
      final host = sampleWorkspaceHost();
      final container = await pumpOn(tester, host, workspaceHost(host, local: false, workingDirectory: '/srv/work'));
      expect(container.read(recentWorkspaceForNewChatProvider), isNull);

      await container.read(sessionsProvider.notifier).create();
      expect(host.argsOf('session/create').last, {
        'request': {'cwd': '/srv/work'},
      });
    });

    testWidgets('this phone keeps its own default directory', (tester) async {
      final host = sampleWorkspaceHost();
      final container = await pumpOn(tester, host, workspaceHost(host));
      expect(container.read(recentWorkspaceForNewChatProvider), isNull);
      expect(container.read(newChatInHostDefaultProvider), isFalse);
    });

    testWidgets('a remote host with no workspace at all runs it in the host default, and says so', (tester) async {
      final host = FakeWorkspaceHost();
      final container = await pumpOn(tester, host, workspaceHost(host, local: false));
      expect(container.read(recentWorkspaceForNewChatProvider), isNull);
      expect(container.read(newChatInHostDefaultProvider), isTrue);

      await container.read(sessionsProvider.notifier).create();
      expect(host.argsOf('session/create').last, {'request': <String, Object?>{}});
    });
  });

  group('small screen, large text: nothing overflows', () {
    final screens = <String, (Widget Function(), String?)>{
      'drawer + switcher sheet': (
        () => HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
        'switcher',
      ),
      'browser': (() => const DirectoryBrowserPage(start: '/root/code', confirmLabel: '添加'), null),
      'management page + sheet': (() => const WorkspacesPage(), 'dsh-app'),
    };
    for (final MapEntry(key: name, value: (build, tap)) in screens.entries) {
      testWidgets(name, (tester) async {
        tester.view.devicePixelRatio = 2;
        tester.view.physicalSize = const Size(320 * 2, 568 * 2);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          goldenApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
                child: build(),
              ),
            ),
            brightness: Brightness.light,
            overrides: workspaceOverrides(sampleWorkspaceHost()),
          ),
        );
        await _settle(tester);
        expect(tester.takeException(), isNull);
        if (tap == 'switcher') {
          await _openSwitcher(tester);
        } else if (tap != null) {
          await tester.tap(find.text(tap).first);
          await _settle(tester);
        }
        expect(tester.takeException(), isNull);
      });
    }
  });
}
