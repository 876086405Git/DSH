// 设置 → 通知, back from the system page where 实时活动 was just allowed: the
// running activity is offered again instead of waiting for it to change.
import 'package:dsh_app/state/live_activity_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/ui/settings/notification_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../access/support.dart' show awayAndBack;
import '../chat/support/harness.dart';
import 'support.dart';

class _Channel extends FakeNotifyChannel {
  final lives = <LivePush>[];

  @override
  Future<void> live(LivePush push) async => lives.add(push);
}

class _Prefs extends NotifyPrefsController {
  @override
  NotifyPrefs build() => const NotifyPrefs(loaded: true);
}

void main() {
  testWidgets('coming back to 设置 → 通知 offers the same live activity again', (tester) async {
    final channel = _Channel();
    const push = LivePush(enabled: true, packId: 'cat');
    await tester.pumpWidget(
      testApp(
        const NotificationSettingsPage(),
        overrides: [
          notifyChannelProvider.overrideWithValue(channel),
          notifyPrefsProvider.overrideWith(_Prefs.new),
          livePushProvider.overrideWithValue(push),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(channel.lives, isEmpty);

    await awayAndBack(tester);
    expect(channel.lives, [push]);
  });
}
