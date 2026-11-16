// 「图片」 (晒成果): the share card with its template and two toggles, then the
// Android share sheet or the photo album. A page of the share panel (and of the
// plugin share sheet), and the parts other share pages reuse: the card preview,
// the toggle capsule, the two-button bar.
//
//   ‹ 图片
//   ( 浅色 │ 深色 │ 纸张 │ 玻璃 │ 卡片 )
//   (✓ 提问) (✓ 模型与过程)
//   [ card ]
//   [ 保存图片 ] [ 分享 ]

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/artifacts.dart' show saveWindowDismissed;
import '../../usage/usage_stats.dart';
import '../common/app_sheet.dart';
import '../common/pressable.dart';
import '../common/scroll_edge_fade.dart';
import '../common/segmented_pill.dart';
import '../shell/adaptive/adaptive_layout.dart' show WindowClass;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'share_card.dart';
import 'share_content.dart';
import 'share_export.dart';

/// How a card is drawn: the template and what it shows besides the answer.
/// Shared by the panel's preview and its image page.
class ShareCardStyle extends ChangeNotifier {
  ShareCardStyle({this._template});

  /// The template picked last time (this app session); before any pick, the
  /// one matching the app's theme.
  static ShareTemplate? lastTemplate;

  ShareTemplate? _template;
  bool _showQuestion = true;
  bool _showMeta = true;

  /// The template for a sheet in [brightness].
  ShareTemplate templateFor(Brightness brightness) =>
      _template ?? lastTemplate ?? (brightness == Brightness.dark ? ShareTemplate.dark : ShareTemplate.light);

  set template(ShareTemplate value) {
    _template = lastTemplate = value;
    notifyListeners();
  }

  bool get showQuestion => _showQuestion;
  set showQuestion(bool value) {
    _showQuestion = value;
    notifyListeners();
  }

  bool get showMeta => _showMeta;
  set showMeta(bool value) {
    _showMeta = value;
    notifyListeners();
  }

  /// [content] drawn in this style.
  ShareCard card(BuildContext context, ShareContent content) => ShareCard(
    content: content,
    template: templateFor(Theme.of(context).brightness),
    showQuestion: _showQuestion,
    showMeta: _showMeta,
  );
}

enum _Busy { sharing, saving }

/// The image page: [content] as a card, its template and toggles, then
/// 「保存图片」 / 「分享」. [linkText] rides along with the image to apps that
/// take text too; [refine] replaces the content when it resolves (a file's
/// picture or first lines, fetched after the page is up).
class ShareImagePage extends ConsumerStatefulWidget {
  const ShareImagePage({super.key, required this.content, this.style, this.linkText, this.refine});

  final ShareContent content;

  /// Shared with the panel's preview; null: the page keeps its own.
  final ShareCardStyle? style;
  final String? linkText;
  final Future<ShareContent?>? refine;

  /// The choices' column beside the preview on a phone on its side.
  static const sideColumn = 320.0;

  @override
  ConsumerState<ShareImagePage> createState() => _ShareImagePageState();
}

class _ShareImagePageState extends ConsumerState<ShareImagePage> {
  final _cardKey = GlobalKey(debugLabel: 'share card');
  late final ShareCardStyle _style = widget.style ?? ShareCardStyle();
  late ShareContent _content = widget.content;
  _Busy? _busy;
  bool _saved = false;
  String? _error;
  Timer? _savedReset;

  @override
  void initState() {
    super.initState();
    _style.addListener(_restyle);
    widget.refine?.then((content) {
      if (mounted && content != null) setState(() => _content = content);
    }, onError: (Object _) {});
  }

  @override
  void didUpdateWidget(ShareImagePage old) {
    super.didUpdateWidget(old);
    if (!identical(old.content, widget.content)) _content = widget.content;
  }

  @override
  void dispose() {
    _style.removeListener(_restyle);
    if (widget.style == null) _style.dispose();
    _savedReset?.cancel();
    super.dispose();
  }

  void _restyle() => setState(() {});

  Future<void> _run(_Busy busy) async {
    final l10n = context.l10n;
    if (_busy != null) return;
    final exporter = ref.read(shareExporterProvider);
    setState(() {
      _busy = busy;
      _error = null;
    });
    String? error;
    var dismissed = false;
    try {
      await settleShareCard(context, _content);
      final png = await captureShareCard(_cardKey);
      final file = await exporter.write(png);
      if (busy == _Busy.sharing) {
        await exporter.share(file, text: widget.linkText);
      } else {
        await exporter.save(file);
      }
      if (mounted) ref.read(usageStatsProvider.notifier).count(UsageCount.share);
    } on PlatformException catch (e) {
      dismissed = busy == _Busy.saving && saveWindowDismissed(e);
      if (!dismissed) {
        error = busy == _Busy.saving
            ? (e.code == 'permission' ? l10n.viewShareNoPermission : l10n.commonSaveFailedRetry)
            : l10n.viewShareOpenFailed;
      }
    } catch (_) {
      error = l10n.viewShareImageFailed;
    }
    if (!mounted) return;
    setState(() {
      _busy = null;
      _error = error;
      _saved = busy == _Busy.saving && error == null && !dismissed;
    });
    if (_saved) {
      HapticFeedback.lightImpact();
      _savedReset?.cancel();
      _savedReset = Timer(const Duration(milliseconds: 2400), () {
        if (mounted) setState(() => _saved = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final content = _content;
    final style = _style;
    final template = style.templateFor(Theme.of(context).brightness);
    final options = [
      if (content.hasQuestion)
        ShareToggle(
          label: l10n.viewShareQuestion,
          selected: style.showQuestion,
          onSelected: () => style.showQuestion = !style.showQuestion,
        ),
      if (content.hasMeta)
        ShareToggle(
          label: l10n.viewShareModelSteps,
          selected: style.showMeta,
          onSelected: () => style.showMeta = !style.showMeta,
        ),
    ];
    final choices = [
      SegmentedPill<ShareTemplate>(
        segments: [for (final t in ShareTemplate.values) PillSegment(t, t.label)],
        selected: template,
        onChanged: (t) => style.template = t,
      ),
      if (options.isNotEmpty) ...[const SizedBox(height: 12), Wrap(spacing: 8, runSpacing: 8, children: options)],
    ];
    final preview = ShareCardPreview(boundaryKey: _cardKey, card: style.card(context, content));
    final actions = ShareStatusBar(
      error: _error,
      child: ShareActionBar(
        busy: switch (_busy) {
          _Busy.saving => ShareActionBusy.saving,
          _Busy.sharing => ShareActionBusy.sharing,
          null => null,
        },
        saved: _saved,
        onSave: () => _run(_Busy.saving),
        onShare: () => _run(_Busy.sharing),
      ),
    );
    return SharePageLayout(title: l10n.viewShareAsImage, top: choices, preview: preview, bottom: actions);
  }
}

/// Pictures on [content]'s card are in before it is captured.
Future<void> settleShareCard(BuildContext context, ShareContent content) async {
  final pending = <Future<void>>[];
  final dpr = MediaQuery.devicePixelRatioOf(context);
  for (final block in content.blocks) {
    if (block case ShareFile(:final image?)) {
      pending.add(
        precacheImage(ResizeImage(image, width: (ShareCard.width * 3).round(), policy: ResizeImagePolicy.fit), context),
      );
    } else if (block case SharePlugin(:final icon?) when icon.startsWith('https://')) {
      pending.add(precacheImage(ResizeImage(NetworkImage(icon), width: (64 * dpr).round()), context));
    }
  }
  try {
    await Future.wait(pending).timeout(const Duration(seconds: 4));
  } catch (_) {}
  await WidgetsBinding.instance.endOfFrame;
}

/// A share page's frame: the title (no close key: the sheet drags down), then
/// [top] and [preview] scrolling as one, and [bottom] pinned under them. On a
/// phone on its side the preview takes the left and the rest a column on the
/// right.
class SharePageLayout extends StatelessWidget {
  const SharePageLayout({super.key, required this.title, this.top = const [], this.preview, required this.bottom});

  final String title;
  final List<Widget> top;
  final Widget? preview;
  final Widget bottom;

  @override
  Widget build(BuildContext context) {
    final header = SheetHeader(title);
    if (MediaQuery.sizeOf(context).height < WindowClass.compactHeight && preview != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ScrollEdgeFade(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(kSheetGutter, 4, kSheetGutter, 16),
                      child: preview,
                    ),
                  ),
                ),
                SizedBox(
                  width: ShareImagePage.sideColumn,
                  child: SafeArea(
                    top: false,
                    left: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 4, kSheetGutter, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // The options scroll; the actions rest at the bottom, as upright.
                          Expanded(
                            child: ScrollEdgeFade(
                              child: SingleChildScrollView(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: top),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          bottom,
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Expanded(
          child: ScrollEdgeFade(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...top,
                  if (preview case final preview?) ...[if (top.isNotEmpty) const SizedBox(height: 16), preview],
                ],
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(padding: const EdgeInsets.fromLTRB(kSheetGutter, 8, kSheetGutter, 12), child: bottom),
        ),
      ],
    );
  }
}

/// [child] with a one-line [error] above it, when there is one.
class ShareStatusBar extends StatelessWidget {
  const ShareStatusBar({super.key, required this.child, this.error, this.status});

  final Widget child;
  final String? error;

  /// A quiet line when there is no [error] (a size, a link).
  final String? status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final text = error ?? status;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (text != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              text,
              key: const ValueKey('share-status'),
              textAlign: TextAlign.center,
              style: AppType.tabular(
                theme.textTheme.bodySmall!.copyWith(color: error != null ? colors.danger : colors.textTertiary),
              ),
            ),
          ),
        child,
      ],
    );
  }
}

/// An on / off capsule: ink check and label when on, a quiet label when off.
/// 12 of air at both ends; at least 32 tall, taller with large text.
class ShareToggle extends StatelessWidget {
  const ShareToggle({super.key, required this.label, required this.selected, required this.onSelected});

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  static const height = 32.0;
  static const padding = 12.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      onTap: onSelected,
      excludeSemantics: true,
      child: Pressable(
        onTap: onSelected,
        child: Container(
          key: ValueKey('share-toggle-$label'),
          constraints: const BoxConstraints(minHeight: height),
          padding: const EdgeInsets.symmetric(horizontal: padding, vertical: 6),
          decoration: ShapeDecoration(
            color: theme.colorScheme.onSurface.withValues(alpha: selected ? 0.10 : 0.04),
            shape: const StadiumBorder(),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                Icon(
                  AppIcons.selected,
                  key: ValueKey('share-toggle-check-$label'),
                  size: 16,
                  color: theme.colorScheme.onSurface,
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? theme.colorScheme.onSurface : colors.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The card at the page's width (the export keeps the card's own size), in a
/// soft frame. [boundaryKey] marks what an export captures.
class ShareCardPreview extends StatelessWidget {
  const ShareCardPreview({super.key, this.boundaryKey, required this.card});

  final GlobalKey? boundaryKey;
  final ShareCard card;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth < ShareCard.width ? constraints.maxWidth : ShareCard.width;
        return Center(
          child: Semantics(
            image: true,
            label: l10n.viewShareImagePreview,
            child: DecoratedBox(
              key: const ValueKey('share-preview'),
              position: DecorationPosition.foreground,
              decoration: ShapeDecoration(
                shape: RoundedSuperellipseBorder(
                  borderRadius: AppShape.radiusMd,
                  side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7), width: 0.5),
                ),
              ),
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusMd),
                  shadows: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: dark ? 0.32 : 0.10),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRSuperellipse(
                  borderRadius: AppShape.radiusMd,
                  child: SizedBox(
                    width: width,
                    child: FittedBox(
                      fit: BoxFit.fitWidth,
                      alignment: Alignment.topCenter,
                      child: RepaintBoundary(
                        key: boundaryKey,
                        child: ExcludeSemantics(child: card),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// What the action bar is doing.
enum ShareActionBusy { saving, sharing }

/// 「保存」 and 「分享」: two equal halves, 48 tall, 12 apart; the one at work
/// shows a small ring in place of its icon. Labels default to the image's
/// (「保存图片」); a label too wide shrinks rather than being cut.
class ShareActionBar extends StatelessWidget {
  const ShareActionBar({
    super.key,
    required this.onSave,
    required this.onShare,
    this.busy,
    this.saved = false,
    this.saveLabel,
    this.saveKey = const ValueKey('share-save'),
    this.shareKey = const ValueKey('share-send'),
  });

  /// Null disables 「保存」.
  final VoidCallback? onSave;

  /// Null disables 「分享」.
  final VoidCallback? onShare;
  final ShareActionBusy? busy;

  /// Just saved: 「已保存」 with a check for a moment.
  final bool saved;
  final String? saveLabel;
  final Key saveKey;
  final Key shareKey;

  static const height = 48.0;
  static const gap = 12.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    Widget icon(IconData data, bool working, Color color) => SizedBox.square(
      dimension: 18,
      child: working
          ? Padding(
              padding: const EdgeInsets.all(1),
              child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round, color: color),
            )
          : Icon(data, size: 18),
    );
    Widget label(String text) => FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1, softWrap: false));
    final idle = busy == null;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            key: saveKey,
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(height)),
            onPressed: idle ? onSave : null,
            icon: icon(saved ? AppIcons.done : AppIcons.save, busy == ShareActionBusy.saving, scheme.onSurfaceVariant),
            label: label(saved ? l10n.commonSaved : saveLabel ?? l10n.viewShareSaveImage),
          ),
        ),
        const SizedBox(width: gap),
        Expanded(
          child: FilledButton.icon(
            key: shareKey,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(height)),
            onPressed: idle ? onShare : null,
            icon: icon(AppIcons.share, busy == ShareActionBusy.sharing, scheme.onPrimary),
            label: label(l10n.commonShare),
          ),
        ),
      ],
    );
  }
}
