// The Theme Studio's preview: a small page under the draft's own ThemeData, built from the widgets the chat
// itself draws with, so a setting looks here the way it will look there.

import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart' show AssistantChatItem;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../pets/pet_signals.dart' show petTakesWhaleProvider;
import '../../chat/composer.dart';
import '../../chat/empty_state.dart';
import '../../chat/widgets/assistant_message.dart';
import '../../chat/widgets/attachments.dart' show AttachButton;
import '../../chat/widgets/user_bubble.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

enum StudioPreviewPage { chat, newChat }

const _replyZh = '''## 调好了

这是一段回复，带 `行内代码` 和一个[链接](https://example.com)。

- 圆角和间距
- 颜色和材质

```dart
// 套用主题
Theme load(String id) {
  return Theme('\$id.json', size: 16);
}
```''';

const _replyEn = '''## All set

A reply with `inline code` and a [link](https://example.com).

- Corners and spacing
- Colours and material

```dart
// Apply the theme
Theme load(String id) {
  return Theme('\$id.json', size: 16);
}
```''';

/// One page of the app under [theme], scaled to fit: a stretch of conversation, or the new-chat page.
class ThemeStudioPreview extends StatefulWidget {
  const ThemeStudioPreview({super.key, required this.theme, required this.page, this.height = fullHeight});

  /// The draft, resolved. A new instance is what redraws the preview.
  final ThemeData theme;
  final StudioPreviewPage page;

  /// The page the widgets are laid out on, a phone's width, before it is scaled down.
  static const canvas = Size(390, 500);

  /// The room the studio gives it; less while the keyboard is up.
  final double height;

  static const fullHeight = 250.0;

  @override
  State<ThemeStudioPreview> createState() => _ThemeStudioPreviewState();
}

class _ThemeStudioPreviewState extends State<ThemeStudioPreview> {
  final _idle = TextEditingController();
  late final _draft = TextEditingController(text: AppLocale.isEnglish ? 'Tidy up this folder' : '帮我整理一下这个文件夹');

  /// Built once per theme and page: the studio around it rebuilds on every slider tick.
  Widget? _built;

  @override
  void didUpdateWidget(ThemeStudioPreview old) {
    super.didUpdateWidget(old);
    if (!identical(old.theme, widget.theme) || old.page != widget.page) _built = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _built = null;
  }

  @override
  void dispose() {
    _idle.dispose();
    _draft.dispose();
    super.dispose();
  }

  Widget _page(BuildContext context) {
    final chat = widget.page == StudioPreviewPage.chat;
    return Theme(
      data: widget.theme,
      // The chat page's pet hides the new-chat whale; there is no pet in here.
      child: ProviderScope(
        overrides: [petTakesWhaleProvider.overrideWithValue(false)],
        // The widgets size themselves to the screen they think they are on.
        child: MediaQuery(
          data: MediaQueryData(
            size: ThemeStudioPreview.canvas,
            devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            textScaler: MediaQuery.textScalerOf(context),
            disableAnimations: MediaQuery.disableAnimationsOf(context),
          ),
          child: AppBackdrop(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(title: chat ? studioPreviewTitle : (AppLocale.isEnglish ? 'New chat' : '新对话')),
                Expanded(
                  // Large type or wide gaps: the middle shrinks rather than run under the composer.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: chat ? Alignment.topCenter : Alignment.center,
                    child: SizedBox(
                      width: ThemeStudioPreview.canvas.width,
                      child: chat
                          ? const _Conversation()
                          : ChatEmptyState(
                              connected: true,
                              onSuggestion: (_) {},
                              suggestions: defaultSuggestions.sublist(0, 2),
                              tips: const [],
                            ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpace.floatInset, 8, AppSpace.floatInset, 12),
                  // A draft on the new-chat page shows the send key lit; the idle one shows the hint.
                  child: Composer(
                    controller: chat ? _idle : _draft,
                    connected: true,
                    running: false,
                    onSend: () {},
                    onStop: () {},
                    leading: AttachButton(onPressed: () {}),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: widget.height,
      child: Center(
        child: AspectRatio(
          aspectRatio: ThemeStudioPreview.canvas.aspectRatio,
          child: Semantics(
            image: true,
            label: AppLocale.isEnglish ? 'Theme preview' : '主题预览',
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(14),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                // Looked at, not used: no taps, no focus, nothing for a screen reader to walk through.
                child: IgnorePointer(
                  child: ExcludeFocus(
                    child: ExcludeSemantics(
                      child: RepaintBoundary(
                        child: FittedBox(
                          child: SizedBox.fromSize(size: ThemeStudioPreview.canvas, child: _built ??= _page(context)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String get studioPreviewTitle => AppLocale.isEnglish ? 'Live preview' : '实时预览';

/// The end of one turn and the start of the next, with the pack's mark between them.
class _Conversation extends StatelessWidget {
  const _Conversation();

  @override
  Widget build(BuildContext context) {
    final english = AppLocale.isEnglish;
    final style = DshThemeStyle.of(context);
    final shapes = style.shapes;
    final gutter = shapes.gutter;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 0),
          child: AssistantMessage(
            item: AssistantChatItem(id: 'a1', text: english ? _replyEn : _replyZh, reasoning: ''),
          ),
        ),
        CustomPaint(
          foregroundPainter: _TurnDividerPainter(
            style.components.turnDivider,
            Theme.of(context).colorScheme.outlineVariant,
            shapes.turnGap,
            gutter,
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(gutter, shapes.turnGap, gutter, 8),
            child: UserBubble(text: english ? 'Now try it in dark mode' : '再换成深色看看'),
          ),
        ),
      ],
    );
  }
}

/// The chat list's mark between two turns (its own painter is private to the list): in the middle of the gap
/// above the turn's first message, as wide as the text column.
class _TurnDividerPainter extends CustomPainter {
  const _TurnDividerPainter(this.style, this.color, this.gap, this.gutter);

  final ThemeTurnDivider style;
  final Color color;
  final double gap;
  final double gutter;

  @override
  void paint(Canvas canvas, Size size) {
    final y = gap / 2;
    final right = size.width - gutter;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    switch (style) {
      case ThemeTurnDivider.none:
        break;
      case ThemeTurnDivider.hairline:
        canvas.drawLine(Offset(gutter, y), Offset(right, y), paint);
      case ThemeTurnDivider.dashed:
        for (var x = gutter; x < right; x += 8) {
          canvas.drawLine(Offset(x, y), Offset(math.min(x + 4, right), y), paint);
        }
      case ThemeTurnDivider.dots:
        for (final dx in const [-8.0, 0.0, 8.0]) {
          canvas.drawCircle(Offset(size.width / 2 + dx, y), 1.5, paint);
        }
    }
  }

  @override
  bool shouldRepaint(_TurnDividerPainter old) =>
      old.style != style || old.color != color || old.gap != gap || old.gutter != gutter;
}

/// The chat header's keys and title pill, drawn the way the header draws them. The header itself needs a live
/// session behind it.
class _Header extends StatelessWidget {
  const _Header({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final style = DshThemeStyle.of(context);
    final GlassStyle? glass = switch (style.components.headerStyle) {
      ThemeHeaderStyle.glass => null,
      ThemeHeaderStyle.ghost => const GlassStyle(
        fill: Colors.transparent,
        fallbackFill: Colors.transparent,
        hairline: Colors.transparent,
        rim: Colors.transparent,
      ),
      ThemeHeaderStyle.outlined => GlassStyle(
        fill: Colors.transparent,
        fallbackFill: Colors.transparent,
        hairline: colors.outlineVariant,
        hairlineWidth: 1.0,
        rim: Colors.transparent,
      ),
      ThemeHeaderStyle.minimal => GlassStyle(
        fill: colors.surfaceContainerLow.withValues(alpha: 0.72),
        fallbackFill: colors.surfaceContainerLow,
        hairline: Colors.transparent,
        rim: Colors.transparent,
      ),
    };
    Widget key(IconData icon) => SizedBox.square(
      dimension: 44,
      child: GlassSurface(
        tier: GlassTier.chrome,
        style: glass,
        circle: true,
        child: Center(child: Icon(icon, size: 22, color: colors.onSurface)),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.floatInset, 8, AppSpace.floatInset, 4),
      child: Row(
        children: [
          key(AppIcons.menu),
          const SizedBox(width: 8),
          GlassSurface(
            tier: GlassTier.chrome,
            style: glass,
            stadium: true,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    title,
                    style: style.headerTitleTextStyle(theme.textTheme.titleSmall!.copyWith(fontSize: 15, height: 1.3)),
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          key(AppIcons.newChat),
        ],
      ),
    );
  }
}
