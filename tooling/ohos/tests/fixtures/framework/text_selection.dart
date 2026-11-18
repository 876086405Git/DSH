  // Shows the magnifier on supported platforms at the given offset, currently
  // only Android and iOS.
  void _showMagnifierIfSupportedByPlatform(Offset positionToShow) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        editableText.showMagnifier(positionToShow);
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.ohos:
    }
  }

  // Hides the magnifier on supported platforms, currently only Android and iOS.
  void _hideMagnifierIfSupportedByPlatform() {
    if (!_isEditableTextMounted) {
      return;
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        editableText.hideMagnifier();
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.ohos:
    }
  }

  /// Returns true if lastSecondaryTapDownPosition was on selection.
  bool get _lastSecondaryTapWasOnSelection {
  void onSingleLongTapEnd(LongPressEndDetails details) {
    final TextEditingValue value = editableText.textEditingValue;
    if (defaultTargetPlatform == TargetPlatform.ohos &&
        value.composing.isValid &&
        value.composing.isNormalized) {
      return;
    }
    _onSingleLongTapEndOrCancel();
    if (shouldShowSelectionToolbar) {
      editableText.showToolbar();
    }
  }

