  /// On Android the click system sound is played. On iOS this is a no-op.
  ///
  /// See also:
  ///
  ///  * [wrapForTap] to trigger platform-specific feedback before executing a
  ///    [GestureTapCallback].
  static Future<void> forTap(BuildContext context) async {
    context.findRenderObject()!.sendSemanticsEvent(const TapSemanticEvent());
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
        return SystemSound.play(SystemSoundType.click);
      case TargetPlatform.iOS:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.ohos:
        return Future<void>.value();
    }
  }
  ///
  /// On Android the platform-typical vibration is triggered. On iOS a
  /// heavy-impact haptic feedback is triggered alongside the click system
  /// sound, which was observed to be the default behavior on a physical iPhone
  /// 15 Pro running iOS version 17.5.
  ///
  /// See also:
  ///
  ///  * [wrapForLongPress] to trigger platform-specific feedback before
  ///    executing a [GestureLongPressCallback].
  static Future<void> forLongPress(BuildContext context) {
    context.findRenderObject()!.sendSemanticsEvent(const LongPressSemanticsEvent());
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
        return HapticFeedback.vibrate();
      case TargetPlatform.iOS:
        return Future.wait(<Future<void>>[
          SystemSound.play(SystemSoundType.click),
          HapticFeedback.heavyImpact(),
        ]);
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.ohos:
        return Future<void>.value();
    }
  }

  /// Wraps a [GestureLongPressCallback] to provide platform specific feedback
  /// for a long press before the provided callback is executed.
  ///
