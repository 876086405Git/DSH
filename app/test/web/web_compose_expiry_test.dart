// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';

import 'package:dsh_app/ui/web/web_target.dart';
import 'package:dsh_app/ui/web/web_view_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../chat/support/harness.dart';
import 'support/fake_webview.dart';

Future<void> checkExpiry(
  WidgetTester tester, {
  required bool ios,
  required bool attached,
  bool concurrent = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  debugDefaultTargetPlatformOverride = ios ? TargetPlatform.iOS : TargetPlatform.android;
  try {
    final platform = FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
    final link = DshWebLink();
    Future<void> mount() async {
      await tester.pumpWidget(
        testApp(WebViewPage(url: Uri.parse('http://127.0.0.1:3080/'), title: 'DSH', dshWeb: true, link: link)),
      );
      for (var i = 0; i < 20 && platform.controller.loads.isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(platform.controller.loads, isNotEmpty);
    }

    if (attached) await mount();
    await link.open(const DshWebTarget(newSession: true));
    final response = link.compose('expired synthetic draft', timeout: Duration(seconds: concurrent ? 1 : 30));
    final live = concurrent ? link.compose('current synthetic draft') : null;
    await tester.pump();
    await tester.pump(Duration(seconds: concurrent ? 2 : 31));
    expect((await response).text, false);
    if (!attached) await mount();
    platform.controller.finish();
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    const prefix = 'window.__dshAppCompose && window.__dshAppCompose(';
    final emitted = platform.controller.scripts.where((s) => s.startsWith(prefix)).toList();
    if (live != null) {
      expect(emitted, hasLength(1));
      final draft = jsonDecode(emitted.single.substring(prefix.length, emitted.single.length - 2)) as Map;
      expect(draft['text'], 'current synthetic draft');
      platform.controller.post(
        'DshAppCompose',
        jsonEncode({'requestId': draft['requestId'], 'text': true, 'files': 0}),
      );
      expect((await live).text, true);
    } else {
      expect(emitted, ios ? isEmpty : hasLength(1), reason: 'only iOS expires its unsent compose');
    }
    // Navigation retains its existing queue semantics; this fix only expires the paste.
    expect(platform.controller.scripts.where((s) => s.startsWith('window.__dshAppOpen &&')), hasLength(1));
  } finally {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 31));
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  for (final attached in [false, true]) {
    final ready = attached ? 'loading page finishes' : 'page attaches';
    for (final ios in [true, false]) {
      testWidgets('${ios ? 'iOS drops expired compose' : 'Android preserves queued compose'} when $ready', (
        tester,
      ) async {
        await checkExpiry(tester, ios: ios, attached: attached);
      });
    }
    testWidgets('iOS expiring one compose preserves the other when $ready', (tester) async {
      await checkExpiry(tester, ios: true, attached: attached, concurrent: true);
    });
  }
}
