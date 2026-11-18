#!/usr/bin/env python3
"""Sends three framework behaviours down Android's branch on HarmonyOS.

They read defaultTargetPlatform, so ThemeData.platform can't reach them: a long press
vibrates, a long-press drag over text shows the magnifier, the selection toolbar fades
while scrolling. This edits the SDK's own copy of packages/flutter and leaves it so:
only ohos takes these branches. A second run changes nothing; anything but the expected
source stops the build with nothing written. Feedback.forTap stays: on HarmonyOS its
sound channel doesn't reply. See tooling/ohos/build-hap.sh.

oh-flutter's own early return in onSingleLongTapEnd, for an IME composing, used to have
no magnifier to hide; a composition that starts mid-press would now leave one on screen.
"""
import pathlib
import sys

OHOS = '      case TargetPlatform.ohos:\n'
LONG_PRESS = '''\
      case TargetPlatform.android:
%s      case TargetPlatform.fuchsia:
        return HapticFeedback.vibrate();
      case TargetPlatform.iOS:
        return Future.wait(<Future<void>>[
          SystemSound.play(SystemSoundType.click),
          HapticFeedback.heavyImpact(),
        ]);
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
%s        return Future<void>.value();
'''
MAGNIFIER = '''\
      case TargetPlatform.android:
%s      case TargetPlatform.iOS:
        editableText.%s;
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
%s    }
'''
LONG_TAP_END = '''\
  void onSingleLongTapEnd(LongPressEndDetails details) {
    final TextEditingValue value = editableText.textEditingValue;
    if (defaultTargetPlatform == TargetPlatform.ohos &&
        value.composing.isValid &&
        value.composing.isNormalized) {
%s      return;
    }
    _onSingleLongTapEndOrCancel();
'''
FADE = '''\
  final bool _platformSupportsFadeOnScroll = switch (defaultTargetPlatform) {
    TargetPlatform.android%s || TargetPlatform.iOS => true,
    TargetPlatform.fuchsia ||
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows%s => false,
'''
EDITS = (
    ('feedback.dart', LONG_PRESS % ('', OHOS), LONG_PRESS % (OHOS, '')),
    ('text_selection.dart', MAGNIFIER % ('', 'showMagnifier(positionToShow)', OHOS), MAGNIFIER % (OHOS, 'showMagnifier(positionToShow)', '')),
    ('text_selection.dart', MAGNIFIER % ('', 'hideMagnifier()', OHOS), MAGNIFIER % (OHOS, 'hideMagnifier()', '')),
    ('text_selection.dart', LONG_TAP_END % '', LONG_TAP_END % '      _hideMagnifierIfSupportedByPlatform();\n'),
    ('editable_text.dart', FADE % ('', ' ||\n    TargetPlatform.ohos'), FADE % (' || TargetPlatform.ohos', '')),
)


def main():
    widgets = pathlib.Path(sys.argv[1]) / 'packages/flutter/lib/src/widgets'
    sources = {name: (widgets / name).read_text() for name, _, _ in EDITS}
    for name, old, new in EDITS:
        if sources[name].count(new) != 1:
            if sources[name].count(old) != 1:
                sys.exit(f'{widgets / name}: not the source patch_framework.py expects:\n{old}')
            sources[name] = sources[name].replace(old, new)
    for name, source in sources.items():
        if (widgets / name).read_text() != source:
            (widgets / name).write_text(source)
            print(f'{name}: patched')


if __name__ == '__main__':
    main()
