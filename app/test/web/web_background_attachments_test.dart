import 'dart:async';

// ignore_for_file: depend_on_referenced_packages
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/ui/web/dsh_web_launcher.dart';
import 'package:dsh_app/ui/web/web_home.dart';
import 'package:dsh_app/ui/web/web_view_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../chat/support/harness.dart';
import 'support/fake_webview.dart';

final url = Uri.parse('http://127.0.0.1:41234/');

Future<void> cycle(WidgetTester tester) async {
  for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  // _onHide uses DateTime.now(), so advance actual time, not only the fake clock.
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pump();
}

void main() {
  for (final os in ['ios', 'android', 'ohos']) {
    for (final entry in ['home', 'launcher']) {
      testWidgets('$os $entry SSH background reload policy', (tester) async {
        SharedPreferences.setMockInitialValues({});
        debugDefaultTargetPlatformOverride = os == 'ios' ? TargetPlatform.iOS : TargetPlatform.android;
        try {
          final platform = FakeWebViewPlatform();
          WebViewPlatform.instance = platform;
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          for (final channel in ['dsh/share', 'dsh/shortcuts']) {
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(channel), (_) async => true);
          }
          addTearDown(() {
            debugDefaultTargetPlatformOverride = null;
            for (final channel in ['dsh/share', 'dsh/shortcuts']) {
              tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(channel), null);
            }
          });
          final harness = ChatHarness();
          await tester.pumpWidget(
            testApp(
              entry == 'home'
                  ? const WebHome()
                  : Consumer(
                      builder: (context, ref, _) => Scaffold(
                        body: TextButton(onPressed: () => openDshWeb(context, ref), child: const Text('open SSH')),
                      ),
                    ),
              overrides: [
                ...harness.overrides,
                operatingSystemProvider.overrideWithValue(os),
                dshWebAccessProvider.overrideWithValue(SshDshWeb(url, 'fixture SSH')),
              ],
            ),
          );
          await tester.pump();
          if (entry == 'launcher') {
            await tester.tap(find.text('open SSH'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
          }
          final page = tester.widget<WebViewPage>(find.byType(WebViewPage));
          final policy = page.reloadAfterBackground;
          expect(
            policy,
            const Duration(seconds: 60),
            reason: 'both SSH entries retain the original 60 second recovery policy',
          );
          // Reuse the actual entry policy decision with a shorter existing public
          // threshold. No clock hook, private callback or fake lifecycle listener.
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(milliseconds: 500));
          final isolated = FakeWebViewPlatform();
          WebViewPlatform.instance = isolated;
          await tester.pumpWidget(
            testApp(
              WebViewPage(
                url: page.url,
                title: page.title,
                dshWeb: page.dshWeb,
                reloadAfterBackground: policy == null ? null : const Duration(milliseconds: 5),
              ),
            ),
          );
          await tester.pump();
          isolated.controller.results = (_) => 2;
          await cycle(tester);
          expect(isolated.controller.reloads, os == 'ios' ? 0 : 1);
          // A second show without a new hidden interval must not replay reload.
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await tester.pump();
          expect(isolated.controller.reloads, os == 'ios' ? 0 : 1);
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(milliseconds: 500));
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(milliseconds: 500));
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }
  for (final answer in <Object>[0, -1, 1.5, '2', false, double.nan, double.infinity]) {
    testWidgets('iOS reloads for non-positive or non-count answer $answer', (tester) async {
      final platform = await mountProbe(tester);
      platform.controller.results = (_) => answer;
      await cycle(tester);
      expect(platform.controller.reloads, 1);
      await unmountProbe(tester);
    });
  }
  testWidgets('iOS missing bridge or WebView error keeps reload', (tester) async {
    final platform = await mountProbe(tester);
    platform.controller.results = (_) => throw PlatformException(code: 'script-unavailable');
    await cycle(tester);
    expect(platform.controller.reloads, 1);
    await unmountProbe(tester);
  });
  testWidgets('iOS unanswered count times out and late positive does not undo reload', (tester) async {
    final platform = await mountProbe(tester);
    final reply = Completer<Object>();
    platform.controller.results = (_) => reply.future;
    await cycle(tester);
    expect(platform.controller.reloads, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(platform.controller.reloads, 1);
    reply.complete(1);
    await tester.pump();
    expect(platform.controller.reloads, 1);
    await unmountProbe(tester);
  });
  for (final leave in ['hide', 'dispose']) {
    testWidgets('iOS does not reload after $leave while attachment count is pending', (tester) async {
      final platform = await mountProbe(tester);
      final reply = Completer<Object>();
      platform.controller.results = (_) => reply.future;
      await cycle(tester);
      if (leave == 'hide') {
        for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
      } else {
        await tester.pumpWidget(const SizedBox());
      }
      reply.complete(0);
      await tester.pump();
      expect(platform.controller.reloads, 0);
      await unmountProbe(tester);
    });
  }
}

Future<FakeWebViewPlatform> mountProbe(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  final platform = FakeWebViewPlatform();
  WebViewPlatform.instance = platform;
  await tester.pumpWidget(
    testApp(
      WebViewPage(url: url, title: 'SSH fixture', dshWeb: true, reloadAfterBackground: const Duration(milliseconds: 5)),
    ),
  );
  await tester.pump();
  return platform;
}

Future<void> unmountProbe(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 500));
  debugDefaultTargetPlatformOverride = null;
}
