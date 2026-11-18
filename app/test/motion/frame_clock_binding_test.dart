// The real binding, driven by hand: widget tests have their own binding with fake
// time, which never goes through SteadyFrameBinding. So no testWidgets in this file.

import 'package:dsh_app/clipboard/paste_button_messenger.dart';
import 'package:dsh_app/ui/theme/frame_clock.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tickers run on the steadied clock: a stall moves them one step, not through the stall', () {
    final binding = SteadyFrameBinding();
    expect(binding.defaultBinaryMessenger, isNot(isA<PasteButtonMessenger>()), reason: 'not on this OS');
    const frame = Duration(milliseconds: 16);
    const stall = Duration(milliseconds: 250);

    var raw = const Duration(seconds: 10);
    void beginAndDraw(Duration step) {
      raw += step;
      binding.handleBeginFrame(raw);
      binding.handleDrawFrame();
    }

    /// The biggest step a fresh ticker's clock takes across a stalled frame.
    Duration biggestStep() {
      final seen = <Duration>[];
      final ticker = Ticker(seen.add);
      addTearDown(ticker.dispose);
      ticker.start();
      for (final step in [frame, frame, stall, frame, frame]) {
        beginAndDraw(step);
      }
      ticker.stop();
      var biggest = Duration.zero;
      for (var i = 1; i < seen.length; i++) {
        final step = seen[i] - seen[i - 1];
        if (step > biggest) biggest = step;
      }
      expect(seen, hasLength(5));
      return biggest;
    }

    FrameClock.instance.enabled = false;
    expect(biggestStep(), stall);

    FrameClock.instance.enabled = true;
    expect(biggestStep(), FrameClock.instance.maxStep);

    // Idle for a minute with nothing running: the next animation starts from zero.
    raw += const Duration(minutes: 1);
    expect(biggestStep(), FrameClock.instance.maxStep);
  });
}
