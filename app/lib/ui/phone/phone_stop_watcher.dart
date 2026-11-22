import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/phone_state.dart';
import '../../state/phone_thought.dart';
import '../../state/phone_turn_end.dart';

/// Keeps [phoneStopWatcherProvider] alive under the home shell, so 停止 on
/// the phone-control overlay also ends the running turn while the app is in
/// the background; and [phoneTurnEndProvider], so the overlay closes (and the
/// app comes back) when that turn ends; and [phoneConfirmPendingProvider], so
/// a first-run 确认方式 the phone didn't take yet goes in on the next start;
/// and [phoneThoughtsProvider], so the overlay's card shows what DSH thinks.
class PhoneStopWatcher extends ConsumerWidget {
  const PhoneStopWatcher({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(phoneStopWatcherProvider);
    ref.watch(phoneTurnEndProvider);
    ref.watch(phoneConfirmPendingProvider);
    ref.watch(phoneThoughtsProvider);
    return child;
  }
}
