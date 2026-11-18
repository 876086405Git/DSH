import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';

import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';

import '../workspace/support.dart';

class _RenameHost extends FakeWorkspaceHost {
  final renames = <(String, String)>[];

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) {
    if (endpoint != 'session/rename') return super.call(endpoint, args, timeout: timeout);
    final request = args['request']! as Map;
    final id = request['sessionId']! as String;
    final title = request['title']! as String;
    renames.add((id, title));
    final row = sessions.firstWhere((s) => s['sessionId'] == id);
    row['projections'] = {
      'kind': 'hints',
      'asOfSeq': 2,
      'values': {'title': title},
    };
    return Future.value(RpcOk({'title': title}));
  }
}

void main() {
  for (final save in [false, true]) {
    testWidgets('iOS rename ${save ? 'save' : 'cancel'} keeps its controller through route removal', (tester) async {
      final platform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      SharedPreferences.setMockInitialValues({});
      usePhoneView(tester);
      final host = _RenameHost()
        ..seedSession('s1', 'Original A', DateTime.now())
        ..seedSession('s2', 'Original B', DateTime.now());
      try {
        final ui = ChatHarness(session: 's1');
        final connection = workspaceHost(host);
        await tester.pumpWidget(
          testApp(
            Scaffold(
              body: SessionsDrawer(onClose: () {}, onOpen: (_) {}),
            ),
            overrides: [
              for (final o in ui.overrides)
                if (o.origin != activeConnectionProvider && o.origin != sessionsProvider) o,
              activeConnectionProvider.overrideWithValue(AsyncData(connection)),
              workspacePrefsProvider.overrideWith(() => FixedWorkspacePrefs(const WorkspacePrefs(loaded: true))),
            ],
          ),
        );
        final container = ProviderScope.containerOf(tester.element(find.byType(SessionsDrawer)));
        addTearDown(connection.client.close);
        for (var i = 0; i < 50 && container.read(drawerScopeProvider)?.readOnly != false; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(container.read(drawerScopeProvider)?.readOnly, isFalse);
        await tester.pumpAndSettle();
        await tester.longPress(find.widgetWithText(SessionTile, 'Original A'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('重命名'));
        await tester.pumpAndSettle();
        final field = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
        final controller = tester.widget<TextField>(field).controller!;
        final route = ModalRoute.of<String>(tester.element(field))!;
        var removed = false;
        route.completed.then((_) => removed = true);
        await tester.enterText(field, '  中文 ordinary 👋  ');
        await tester.tap(save ? find.widgetWithText(FilledButton, '保存') : find.widgetWithText(TextButton, '取消'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(removed, isTrue);
        expect(find.byType(AlertDialog), findsNothing);
        expect(host.renames, save ? [('s1', '中文 ordinary 👋')] : isEmpty);
        expect(find.widgetWithText(SessionTile, save ? '中文 ordinary 👋' : 'Original A'), findsOneWidget);
        expect(find.widgetWithText(SessionTile, 'Original B'), findsOneWidget);
        // Disposal must still happen once the dialog actually leaves the tree.
        expect(() => controller.addListener(() {}), throwsFlutterError);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = platform;
      }
    });
  }
}
