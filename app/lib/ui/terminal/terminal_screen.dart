// The dark terminal card of the terminal page — the xterm screen, pinch to
// resize the font, long-press selection with copy / paste, the composing
// preview and the bottom slot (key row or status).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../l10n/l10n.dart';
import '../../state/terminal_state.dart';
import '../common/empty_view.dart';
import '../common/field_paste.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'terminal_keyboard.dart';
import 'terminal_keys.dart';
import 'terminal_palette.dart';
import '../common/brief_notice.dart';

/// The card shell: the engine log card's dark surface (dark in both themes),
/// with the dark theme inside so buttons and empty states read on it.
class TerminalCardFrame extends StatelessWidget {
  const TerminalCardFrame({super.key, required this.child});

  final Widget child;

  /// The dark theme of the current palette (light mode keeps the card dark).
  static final _darkThemes = <AppAccent, ThemeData>{};

  static ThemeData _darkThemeFor(AppAccent accent) {
    if (_darkThemes.length > 4) _darkThemes.clear();
    return _darkThemes.putIfAbsent(accent, () => buildDarkTheme(accent: accent));
  }

  @override
  Widget build(BuildContext context) {
    final ambient = Theme.of(context);
    final palette = TerminalPalette.of(context);
    return Theme(
      data: ambient.brightness == Brightness.dark ? ambient : _darkThemeFor(DshSurfaces.of(context).accent),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: palette.background,
          shape: RoundedSuperellipseBorder(
            borderRadius: AppShape.radiusLg,
            side: BorderSide(color: palette.hairline, width: 0.5),
          ),
        ),
        child: ClipRSuperellipse(
          borderRadius: AppShape.radiusLg,
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

/// A card with nothing but a status in its bottom slot (loading the list).
class TerminalCardPlaceholder extends StatelessWidget {
  const TerminalCardPlaceholder({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return TerminalCardFrame(
      child: Column(
        children: [
          const Spacer(),
          _Divider(),
          TerminalStatusBar(label: label, busy: true),
        ],
      ),
    );
  }
}

/// One tab's screen inside the card.
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({
    super.key,
    required this.sessionId,
    required this.tab,
    required this.focusNode,
    required this.modifiers,
  });

  final String sessionId;
  final TerminalTab tab;
  final FocusNode focusNode;
  final TerminalModifiers modifiers;

  /// Inner padding of the screen inside the card.
  static const padding = EdgeInsets.fromLTRB(12, 12, 12, 6);

  @override
  ConsumerState<TerminalScreen> createState() => TerminalScreenState();
}

class TerminalScreenState extends ConsumerState<TerminalScreen> with FieldPaste<TerminalScreen> {
  final _selection = TerminalController();
  var _scroll = ScrollController();
  final _stack = GlobalKey();
  var _view = GlobalKey<TerminalViewState>();
  final _keyboard = GlobalKey<TerminalKeyboardState>();
  final _pointers = <int, Offset>{};
  double? _pinchSpan;
  double _pinchFont = TerminalFontSize.fallback;
  String? _composing;

  TerminalTab get _tab => widget.tab;
  Terminal get _terminal => widget.tab.terminal;
  bool get _canType => _tab.phase == TerminalPhase.live && _tab.writable;

  TerminalWorkspace get _workspace => ref.read(terminalWorkspaceProvider(widget.sessionId).notifier);

  @override
  void didUpdateWidget(TerminalScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Anchors belong to the old screen buffer.
    if (oldWidget.tab.terminal != widget.tab.terminal || oldWidget.tab.id != widget.tab.id) {
      _selection.clearSelection();
      // A paste still waiting on the system was for that terminal.
      cancelPaste();
    }
    if (oldWidget.tab.id != widget.tab.id) {
      // Each tab gets its own view (and scroll position); the old controller
      // goes once the old view has let go of it.
      _composing = null;
      _view = GlobalKey<TerminalViewState>();
      final old = _scroll;
      _scroll = ScrollController();
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  @override
  void dispose() {
    _selection.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ── Input ──

  void _toBottom() {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  void _onText(String text) {
    if (widget.modifiers.any && text.runes.length == 1) {
      final m = widget.modifiers.consume();
      _terminal.textInput(withModifiers(text, ctrl: m.ctrl, alt: m.alt));
    } else {
      _terminal.textInput(text);
    }
    _toBottom();
  }

  void _onBackspace() {
    final m = widget.modifiers.consume();
    _terminal.keyInput(TerminalKey.backspace, ctrl: m.ctrl, alt: m.alt);
    _toBottom();
  }

  void _onEnter() {
    final m = widget.modifiers.consume();
    _terminal.keyInput(TerminalKey.enter, ctrl: m.ctrl, alt: m.alt);
    _toBottom();
  }

  void _onExtraKey(TerminalExtraKey key) {
    _keyboard.currentState?.flushComposing();
    final m = widget.modifiers.consume();
    key.send(_terminal, ctrl: m.ctrl, alt: m.alt);
    _toBottom();
  }

  /// Hardware keys: wait while the IME composes; sticky modifiers apply to
  /// the next printable key.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (_keyboard.currentState?.composing ?? false) return KeyEventResult.skipRemainingHandlers;
    if (event is KeyUpEvent || !widget.modifiers.any) return KeyEventResult.ignored;
    final character = event.character;
    if (character == null || character.runes.length != 1 || character.codeUnitAt(0) < 0x20) {
      return KeyEventResult.ignored;
    }
    _onText(character);
    return KeyEventResult.handled;
  }

  // ── Pinch ──

  double _span() {
    final points = _pointers.values.take(2).toList();
    return (points[0] - points[1]).distance;
  }

  void _pointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.position;
    if (_pointers.length == 2) {
      _pinchSpan = _span();
      _pinchFont = ref.read(terminalFontSizeProvider);
      _selection.clearSelection();
    }
  }

  void _pointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.position;
    final start = _pinchSpan;
    if (start == null || start < 16 || _pointers.length < 2) return;
    ref.read(terminalFontSizeProvider.notifier).set(_pinchFont * _span() / start);
  }

  void _pointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length < 2) _pinchSpan = null;
  }

  // ── Selection ──

  Future<void> _copy() async {
    final range = _selection.selection;
    if (range == null) return;
    final text = _terminal.buffer.getText(range);
    _selection.clearSelection();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    showBriefNotice(context, appL10n.commonCopied);
  }

  Future<void> _paste() async {
    final terminal = _terminal;
    _selection.clearSelection();
    final text = await readClipboard();
    if (text == null || text.isEmpty || !mounted) return;
    // A reconnect can replace the attachment before this widget rebuilds.
    final current = ref.read(terminalWorkspaceProvider(widget.sessionId)).selected;
    if (current == null || current.terminal != terminal || current.phase != TerminalPhase.live || !current.writable) {
      return;
    }
    terminal.paste(text);
    _toBottom();
  }

  /// Where the 复制 / 粘贴 bar goes: just above the selection, or just below
  /// it when the selection starts near the top. Null without a selection.
  Offset? _selectionBarAnchor() {
    final range = _selection.selection?.normalized;
    final render = _view.currentState?.renderTerminal;
    final stack = _stack.currentContext?.findRenderObject();
    if (range == null || render == null || !render.hasSize || stack is! RenderBox || !stack.hasSize) return null;
    Offset at(Offset local) => stack.globalToLocal(render.localToGlobal(local));
    final begin = at(render.getOffset(range.begin));
    final end = at(render.getOffset(range.end));
    final cell = render.cellSize;
    const gap = 8.0;
    final above = begin.dy - gap - _SelectionBar.height;
    final below = end.dy + cell.height + gap;
    final limit = stack.size.height - _SelectionBar.height - gap;
    final top = (above >= gap ? above : below).clamp(gap, limit < gap ? gap : limit);
    // Over the selection on one line; the middle of the screen across lines.
    final x = range.begin.y == range.end.y ? (begin.dx + end.dx) / 2 : stack.size.width / 2;
    return Offset(x, top);
  }

  // ── Build ──

  Widget? _bottom() {
    final tab = _tab;
    return switch (tab.phase) {
      TerminalPhase.live when tab.writable => ExtraKeysRow(modifiers: widget.modifiers, onKey: _onExtraKey),
      TerminalPhase.live => TerminalStatusBar(
        label: appL10n.botsTerminalOtherDevice,
        actionLabel: appL10n.botsTerminalTakeOver,
        onAction: () => _workspace.reconnect(tab.id),
      ),
      TerminalPhase.starting => TerminalStatusBar(label: appL10n.botsTerminalStarting, busy: true),
      TerminalPhase.connecting => TerminalStatusBar(label: appL10n.botsTerminalConnecting, busy: true),
      TerminalPhase.disconnected => TerminalStatusBar(
        label: tab.message ?? appL10n.botsTerminalDisconnected,
        actionLabel: appL10n.botsTerminalReconnect,
        onAction: () => _workspace.reconnect(tab.id),
      ),
      TerminalPhase.ended => TerminalStatusBar(
        label: switch (tab.exitCode) {
          null || 0 => appL10n.botsTerminalEnded,
          final code => appL10n.botsTerminalExitCode(code),
        },
        actionLabel: appL10n.botsTerminalNew,
        onAction: () => unawaited(_workspace.newTerminal(replacing: tab.id)),
      ),
      TerminalPhase.missing || TerminalPhase.failed => null,
    };
  }

  Widget? _blocked() {
    final tab = _tab;
    return switch (tab.phase) {
      TerminalPhase.missing => EmptyView(
        key: const ValueKey('terminal-missing'),
        icon: AppIcons.terminal,
        title: appL10n.botsTerminalGone,
        action: _CardButton(
          label: appL10n.botsTerminalNew,
          onPressed: () => unawaited(_workspace.newTerminal(replacing: tab.id)),
        ),
      ),
      TerminalPhase.failed => EmptyView(
        key: const ValueKey('terminal-failed'),
        icon: AppIcons.terminal,
        title: tab.message ?? TerminalCopy.startFailed,
        message: tab.message == TerminalCopy.limit ? appL10n.botsTerminalLimit : null,
        action: _CardButton(label: appL10n.commonRetry, onPressed: () => unawaited(_workspace.retry(tab.id))),
      ),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final font = ref.watch(terminalFontSizeProvider);
    final tab = _tab;
    final canType = _canType;
    final blocked = _blocked();
    final bottom = _bottom();

    Widget screen = TerminalView(
      _terminal,
      key: _view,
      controller: _selection,
      scrollController: _scroll,
      theme: canType ? TerminalPalette.of(context).theme : TerminalPalette.of(context).quiet,
      textStyle: TerminalStyle(
        fontSize: font,
        fontFamily: AppType.monoFamily,
        fontFamilyFallback: AppType.monoFallback,
      ),
      backgroundOpacity: 0,
      focusNode: widget.focusNode,
      autofocus: canType,
      hardwareKeyboardOnly: true,
      readOnly: !canType,
      keyboardAppearance: Brightness.dark,
      onTapUp: (_, _) => _keyboard.currentState?.show(),
      onKeyEvent: _onKeyEvent,
    );
    // The card is already inside the safe area; xterm would pad it again.
    screen = MediaQuery.removePadding(
      context: context,
      removeTop: true,
      removeBottom: true,
      removeLeft: true,
      removeRight: true,
      child: screen,
    );
    screen = Listener(
      onPointerDown: _pointerDown,
      onPointerMove: _pointerMove,
      onPointerUp: _pointerUp,
      onPointerCancel: _pointerUp,
      child: Padding(padding: TerminalScreen.padding, child: screen),
    );
    screen = TerminalKeyboard(
      key: _keyboard,
      focusNode: widget.focusNode,
      enabled: canType,
      onText: _onText,
      onBackspace: _onBackspace,
      onEnter: _onEnter,
      onComposing: (text) {
        if (text != _composing && mounted) setState(() => _composing = text);
      },
      child: screen,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Stack(
            key: _stack,
            children: [
              Positioned.fill(child: blocked == null ? screen : Center(child: blocked)),
              if (blocked == null)
                ListenableBuilder(
                  listenable: _selection,
                  builder: (context, _) {
                    final anchor = _selectionBarAnchor();
                    if (anchor == null) return const SizedBox.shrink();
                    return Positioned.fill(
                      child: CustomSingleChildLayout(
                        delegate: _CenteredAt(anchor),
                        child: _SelectionBar(onCopy: _copy, onPaste: canType ? _paste : null),
                      ),
                    );
                  },
                ),
              if (_composing case final text? when text.isNotEmpty && blocked == null)
                Positioned(left: 12, bottom: 8, child: _ComposingPill(text: text)),
            ],
          ),
        ),
        if (bottom != null) ...[
          _Divider(),
          AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.quick),
            child: KeyedSubtree(key: ValueKey(bottom.runtimeType.toString() + tab.phase.name), child: bottom),
          ),
        ],
      ],
    );
  }
}

/// Puts its child's top centre at [anchor], kept 8 inside the sides.
class _CenteredAt extends SingleChildLayoutDelegate {
  const _CenteredAt(this.anchor);

  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const margin = 8.0;
    final maxLeft = size.width - childSize.width - margin;
    final left = (anchor.dx - childSize.width / 2).clamp(margin, maxLeft < margin ? margin : maxLeft);
    return Offset(left, anchor.dy);
  }

  @override
  bool shouldRelayout(_CenteredAt oldDelegate) => oldDelegate.anchor != anchor;
}

/// EmptyView's button on the card (label in the theme's text style).
class _CardButton extends StatelessWidget {
  const _CardButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        textStyle: Theme.of(context).textTheme.labelLarge,
      ),
      child: Text(label),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(height: 0.5, color: TerminalPalette.of(context).hairline);
}

/// 「复制 | 粘贴」 over the selection.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.onCopy, this.onPaste});

  static const height = 36.0;

  final VoidCallback onCopy;
  final VoidCallback? onPaste;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = TerminalPalette.of(context);
    final style = Theme.of(context).textTheme.labelLarge?.copyWith(color: palette.foreground);
    Widget action(String label, VoidCallback onTap) => InkWell(
      key: ValueKey('terminal-$label'),
      onTap: onTap,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Center(child: Text(label, style: style)),
        ),
      ),
    );
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: palette.key,
        shape: StadiumBorder(side: BorderSide(color: palette.hairline, width: 0.5)),
        shadows: const [BoxShadow(color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 4))],
      ),
      child: ClipPath(
        clipper: const ShapeBorderClipper(shape: StadiumBorder()),
        child: Material(
          type: MaterialType.transparency,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              action(l10n.commonCopy, onCopy),
              if (onPaste case final paste?) ...[
                Container(width: 0.5, height: 16, color: palette.muted.withValues(alpha: 0.5)),
                action(l10n.commonPaste, paste),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// What the IME is composing, until a candidate is picked.
class _ComposingPill extends StatelessWidget {
  const _ComposingPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = TerminalPalette.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(color: palette.key, shape: const StadiumBorder()),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          text,
          style: AppType.mono(
            size: 14,
            color: palette.foreground,
          ).copyWith(decoration: TextDecoration.underline, decorationColor: palette.accent),
        ),
      ),
    );
  }
}
