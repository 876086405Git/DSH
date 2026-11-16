// The full-screen change view behind the change card
// (layer 3 of the run information): file chips, swipe between files, a
// unified diff with line-number gutters, wrap toggle and copy patch.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../common/side_insets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'render/diff_view.dart';
import 'turn_summary.dart';
import 'widgets/change_card.dart';
import '../common/brief_notice.dart';

/// 换行开关在一次运行内记住(上次怎么看,下次还怎么看)。默认换行:
/// 手机上横向滚动的代码会吃掉"左右滑切文件"的手势,不换行时切文件靠
/// 顶上的胶囊。
bool _wrapPreference = true;

/// 一组文件的改动:顶上一排文件胶囊,左右滑切换文件;每个文件是带行号的
/// 统一 diff。右上角:换行开关、复制补丁。
class ChangeDiffPage extends StatefulWidget {
  const ChangeDiffPage({super.key, required this.files, this.initialIndex = 0, this.title});

  final List<FileChange> files;
  final int initialIndex;
  final String? title;

  static Route<void> route(List<FileChange> files, {int initialIndex = 0, String? title}) => MaterialPageRoute<void>(
    builder: (_) => ChangeDiffPage(files: files, initialIndex: initialIndex, title: title),
  );

  @override
  State<ChangeDiffPage> createState() => _ChangeDiffPageState();
}

class _ChangeDiffPageState extends State<ChangeDiffPage> {
  late final PageController _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex.clamp(0, widget.files.length - 1);
  bool _wrap = _wrapPreference;
  final _chipKeys = <int, GlobalKey>{};

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _select(int index) {
    if (index == _index) return;
    // A scroll can't animate over zero (reduced motion): it jumps.
    final duration = AppMotion.of(context, AppMotion.standard);
    if (duration == Duration.zero) {
      _pages.jumpToPage(index);
    } else {
      _pages.animateToPage(index, duration: duration, curve: AppMotion.std);
    }
  }

  void _onPage(int index) {
    setState(() => _index = index);
    final chip = _chipKeys[index]?.currentContext;
    if (chip != null) {
      Scrollable.ensureVisible(
        chip,
        alignment: 0.5,
        duration: AppMotion.of(context, AppMotion.standard),
        curve: AppMotion.std,
      );
    }
  }

  Future<void> _copyPatch() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    HapticFeedback.lightImpact();
    await Clipboard.setData(ClipboardData(text: widget.files[_index].patch));
    messenger?.showBriefNotice(l10n.activityDiffCopied);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final files = widget.files;
    final padding = MediaQuery.paddingOf(context);
    const barHeight = 56.0;
    final added = files.fold(0, (sum, f) => sum + f.added);
    final removed = files.fold(0, (sum, f) => sum + f.removed);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(theme.brightness),
      child: AppBackdrop(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          // A phone on its side: clear of the cutout on both sides.
          body: SideSafeArea(
            child: Column(
              children: [
                SizedBox(height: padding.top),
                SizedBox(
                  height: barHeight,
                  child: BackdropGroup(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          GlassIconButton(
                            icon: AppIcons.back,
                            tooltip: l10n.commonBack,
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.title ?? l10n.activityDiffTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(height: 1.25),
                                ),
                                Row(
                                  children: [
                                    Text(
                                      l10n.activityDiffFileCount(files.length),
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        fontSize: 12,
                                        color: dsh.textTertiary,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    DiffCounts(added: added, removed: removed),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          _ToggleButton(
                            icon: AppIcons.wrapLines,
                            tooltip: _wrap ? l10n.activityDiffNoWrap : l10n.activityDiffWrap,
                            active: _wrap,
                            onPressed: () => setState(() => _wrap = _wrapPreference = !_wrap),
                          ),
                          const SizedBox(width: 8),
                          GlassIconButton(icon: AppIcons.copy, tooltip: l10n.activityDiffCopy, onPressed: _copyPatch),
                        ],
                      ),
                    ),
                  ),
                ),
                if (files.length > 1)
                  SizedBox(
                    height: 52,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      itemCount: files.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, i) => _FileChip(
                        key: _chipKeys.putIfAbsent(i, GlobalKey.new),
                        file: files[i],
                        selected: i == _index,
                        onTap: () => _select(i),
                      ),
                    ),
                  )
                else
                  const SizedBox(height: 4),
                Expanded(
                  child: PageView.builder(
                    controller: _pages,
                    itemCount: files.length,
                    onPageChanged: _onPage,
                    itemBuilder: (context, i) => FileDiffPane(
                      key: ValueKey(files[i].path),
                      file: files[i],
                      wrap: _wrap,
                      bottomInset: padding.bottom,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 换行开关:开着时是主色实心圆。
class _ToggleButton extends StatelessWidget {
  const _ToggleButton({required this.icon, required this.tooltip, required this.active, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (!active) {
      return GlassIconButton(icon: icon, tooltip: tooltip, onPressed: onPressed);
    }
    return Semantics(
      button: true,
      toggled: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: SizedBox.square(
          dimension: 44,
          child: Material(
            color: colors.primaryContainer,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: Icon(icon, size: 21, color: colors.primary),
            ),
          ),
        ),
      ),
    );
  }
}

/// 文件胶囊:文件名 + `+n −m`;当前文件是主色容器。
class _FileChip extends StatelessWidget {
  const _FileChip({super.key, required this.file, required this.selected, required this.onTap});

  final FileChange file;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          file.fileName,
          style: theme.textTheme.labelMedium?.copyWith(color: selected ? colors.onPrimaryContainer : colors.onSurface),
        ),
        const SizedBox(width: 6),
        DiffCounts(added: file.added, removed: file.removed),
      ],
    );
    return Semantics(
      button: true,
      selected: selected,
      label: l10n.activityDiffFileSemantics(file.shownPath, file.added, file.removed),
      excludeSemantics: true,
      onTap: onTap,
      child: selected
          ? Material(
              color: colors.primaryContainer,
              shape: StadiumBorder(side: BorderSide(color: colors.primary.withValues(alpha: 0.35), width: 0.8)),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Center(child: label),
                ),
              ),
            )
          : GlassSurface(
              tier: GlassTier.pill,
              stadium: true,
              onTap: onTap,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Center(child: label),
            ),
    );
  }
}

/// 一行要画的东西:hunk 标题,或一行 diff(带旧 / 新行号)。
sealed class _Row {
  const _Row();
}

final class _HunkRow extends _Row {
  const _HunkRow(this.text);
  final String text;
}

final class _LineRow extends _Row {
  const _LineRow(this.kind, this.text, this.oldNo, this.newNo);
  final DiffLineKind kind;
  final String text;
  final int? oldNo;
  final int? newNo;
}

List<_Row> _rowsOf(FileChange file) {
  final rows = <_Row>[];
  final hunks = file.hunks;
  if (hunks.isEmpty) {
    for (final line in file.lines) {
      rows.add(
        line.kind == DiffLineKind.hunk || line.kind == DiffLineKind.meta
            ? _HunkRow(line.text)
            : _LineRow(line.kind, _body(line.text), null, null),
      );
    }
    return rows;
  }
  final perEdit = <int, int>{};
  for (final hunk in hunks) {
    perEdit[hunk.edit] = (perEdit[hunk.edit] ?? 0) + 1;
  }
  final seen = <int, int>{};
  for (final (i, hunk) in hunks.indexed) {
    final nth = seen[hunk.edit] = (seen[hunk.edit] ?? 0) + 1;
    final parts = [
      if (file.edits > 1) appL10n.activityDiffEditNumber(hunk.edit),
      if ((perEdit[hunk.edit] ?? 1) > 1) appL10n.activityDiffHunkNumber(nth),
      if (hunk.newStart case final at? when !file.created) appL10n.activityDiffFromLine(at),
    ];
    if (parts.isNotEmpty) {
      rows.add(_HunkRow(parts.join(' · ')));
    } else if (i > 0) {
      rows.add(const _HunkRow('…'));
    }
    var oldNo = hunk.oldStart;
    var newNo = hunk.newStart;
    for (final line in hunk.lines) {
      switch (line.kind) {
        case DiffLineKind.add:
          rows.add(_LineRow(line.kind, _body(line.text), null, newNo));
          if (newNo != null) newNo++;
        case DiffLineKind.del:
          rows.add(_LineRow(line.kind, _body(line.text), oldNo, null));
          if (oldNo != null) oldNo++;
        default:
          rows.add(_LineRow(line.kind, _body(line.text), oldNo, newNo));
          if (oldNo != null) oldNo++;
          if (newNo != null) newNo++;
      }
    }
  }
  return rows;
}

/// diff 行去掉首列的 +/−/空格。
String _body(String text) => text.isEmpty ? '' : text.substring(1);

/// 一个文件的整页 diff:文件头(目录、事实、复制路径)+ 行号栏 + 代码。
/// 不换行时整块横向滚动(行号跟着走,手机上留给代码的宽度更多)。
class FileDiffPane extends StatelessWidget {
  const FileDiffPane({super.key, required this.file, required this.wrap, this.bottomInset = 0});

  final FileChange file;
  final bool wrap;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final dsh = DshColors.of(context);
    final rows = _rowsOf(file);
    final lines = rows.whereType<_LineRow>();
    final hasOld = lines.any((l) => l.oldNo != null);
    final hasNew = lines.any((l) => l.newNo != null);
    final maxNo = lines.fold(0, (m, l) => math.max(m, math.max(l.oldNo ?? 0, l.newNo ?? 0)));
    final style = AppType.mono(size: 12, height: 1.6, color: dsh.codeWellFg);
    final numberStyle = AppType.mono(size: 11, height: 1.6 * 12 / 11, color: dsh.lineNumberFg);
    final charWidth = _charWidth(context, style);
    final numberWidth = '$maxNo'.length * charWidth * 11 / 12 + 10;
    final gutter = (hasOld ? numberWidth : 0) + (hasNew ? numberWidth : 0) + 18.0;
    final longest = lines.fold(0, (m, l) => math.max(m, l.text.length));

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.maxWidth;
        // 与页面内容同一条左右边线(16),和上方文件胶囊、文件头对齐。
        const sideMargin = 16.0;
        final wellWidth = viewport - sideMargin * 2;
        final contentWidth = wrap ? wellWidth : math.max(wellWidth, gutter + longest * charWidth + 28);

        Widget row(int i) {
          final r = rows[i];
          return switch (r) {
            _HunkRow(:final text) => Container(
              color: dsh.codeWellHeader,
              padding: EdgeInsets.fromLTRB(gutter - 4, 4, 16, 4),
              child: Text(text, style: AppType.mono(size: 11.5, color: dsh.diffHunkFg, height: 1.4)),
            ),
            _LineRow() => _DiffLineRow(
              line: r,
              wrap: wrap,
              showOld: hasOld,
              showNew: hasNew,
              numberWidth: numberWidth,
              style: style,
              numberStyle: numberStyle,
            ),
          };
        }

        final header = _FileHeader(file: file);
        final body = file.lines.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  l10n.activityDiffEmpty,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: dsh.textTertiary),
                ),
              )
            : null;

        final list = ListView.builder(
          padding: EdgeInsets.only(bottom: bottomInset + 24),
          itemCount: rows.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              // Stays at the viewport's width while the code scrolls sideways.
              return Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(width: viewport, child: header),
              );
            }
            final index = i - 1;
            final first = index == 0;
            final last = index == rows.length - 1;
            // The well: one continuous squircle, its ends drawn by the first
            // and last rows.
            Widget child = ColoredBox(
              color: dsh.codeWellBg,
              child: Padding(
                padding: EdgeInsets.only(top: first ? 8 : 0, bottom: last ? 8 : 0),
                child: row(index),
              ),
            );
            if (first || last) {
              child = ClipRSuperellipse(
                borderRadius: BorderRadius.vertical(
                  top: first ? const Radius.circular(AppShape.md) : Radius.zero,
                  bottom: last ? const Radius.circular(AppShape.md) : Radius.zero,
                ),
                child: child,
              );
            }
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: sideMargin),
              child: child,
            );
          },
        );

        if (body != null) {
          return ListView(children: [header, body]);
        }
        if (wrap) return list;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: contentWidth + sideMargin * 2, height: constraints.maxHeight, child: list),
        );
      },
    );
  }

  static double _charWidth(BuildContext context, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: '0000000000', style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = painter.width / 10;
    painter.dispose();
    return width;
  }
}

class _DiffLineRow extends StatelessWidget {
  const _DiffLineRow({
    required this.line,
    required this.wrap,
    required this.showOld,
    required this.showNew,
    required this.numberWidth,
    required this.style,
    required this.numberStyle,
  });

  final _LineRow line;
  final bool wrap;
  final bool showOld;
  final bool showNew;
  final double numberWidth;
  final TextStyle style;
  final TextStyle numberStyle;

  @override
  Widget build(BuildContext context) {
    final dsh = DshColors.of(context);
    final (Color? bg, Color markColor, String mark) = switch (line.kind) {
      DiffLineKind.add => (dsh.diffAddBg, dsh.diffAddFg, '+'),
      DiffLineKind.del => (dsh.diffDelBg, dsh.diffDelFg, '−'),
      _ => (null, dsh.lineNumberFg, ' '),
    };
    Widget number(int? n) => SizedBox(
      width: numberWidth,
      child: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Text(
          n == null ? '' : '$n',
          textAlign: TextAlign.right,
          style: bg == null ? numberStyle : numberStyle.copyWith(color: markColor),
        ),
      ),
    );
    return Container(
      color: bg,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showOld) number(line.oldNo),
          if (showNew) number(line.newNo),
          SizedBox(
            width: 18,
            child: Text(
              mark,
              textAlign: TextAlign.center,
              style: style.copyWith(color: markColor),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Text(
                line.text.isEmpty ? ' ' : line.text,
                softWrap: wrap,
                overflow: wrap ? null : TextOverflow.visible,
                style: line.kind == DiffLineKind.del
                    ? style.copyWith(color: dsh.diffDelFg)
                    : line.kind == DiffLineKind.add
                    ? style.copyWith(color: dsh.diffAddFg)
                    : style,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 文件头:文件名、目录、+/−、新建 / 修改次数、复制路径。
class _FileHeader extends StatelessWidget {
  const _FileHeader({required this.file});

  final FileChange file;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final directory = file.directory;
    final facts = [
      if (file.created) l10n.activityDiffNewFile else if (file.edits > 1) l10n.activityDiffEditCount(file.edits),
      if (!file.created && file.hunks.isNotEmpty && !file.hunks.any((h) => h.numbered)) l10n.activityDiffUnknownLines,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(file.fileName, style: theme.textTheme.titleMedium?.copyWith(height: 1.3)),
                if (directory.isNotEmpty)
                  Text(
                    directory,
                    style: AppType.mono(size: 12, height: 1.45, color: theme.colorScheme.onSurfaceVariant),
                  ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    DiffCounts(added: file.added, removed: file.removed),
                    for (final fact in facts) ...[
                      const SizedBox(width: 8),
                      Text(fact, style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary)),
                    ],
                  ],
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () => copyPath(context, file.path),
            icon: const Icon(AppIcons.link, size: 16),
            label: Text(l10n.activityDiffCopyPath),
          ),
        ],
      ),
    );
  }
}
