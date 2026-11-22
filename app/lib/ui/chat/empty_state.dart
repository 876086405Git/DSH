import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../pets/pet_signals.dart' show petTakesWhaleProvider;
import '../common/expand_reveal.dart';
import '../common/fade_in.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'empty_actions.dart';
import 'widgets/whale_tail.dart';

/// 一条建议:一枚带色底的线性小图标 + 标题 + 一行说明,点了把 [prompt] 填进输入条。
class ChatSuggestion {
  const ChatSuggestion(this.icon, String label, String prompt, {this._detail, this.tint = SuggestionTint.blue})
    : _label = label,
      _prompt = prompt,
      _defaultIndex = null;

  const ChatSuggestion._default(this.icon, this._defaultIndex, this.tint) : _label = null, _prompt = null, _detail = null;

  final IconData icon;
  final SuggestionTint tint;
  final String? _label;
  final String? _prompt;
  final String? _detail;
  final int? _defaultIndex;

  String get label =>
      _label ??
      switch (_defaultIndex) {
        0 => appL10n.viewSuggestWorkspace,
        1 => appL10n.viewSuggestWordCount,
        2 => appL10n.viewSuggestNode,
        _ => appL10n.viewSuggestGit,
      };

  /// One line under the title: what the suggestion will do.
  String? get detail => _defaultIndex == null
      ? _detail
      : switch (_defaultIndex) {
          0 => appL10n.viewSuggestWorkspaceHint,
          1 => appL10n.viewSuggestWordCountHint,
          2 => appL10n.viewSuggestNodeHint,
          _ => appL10n.viewSuggestGitHint,
        };

  String get prompt =>
      _prompt ??
      switch (_defaultIndex) {
        0 => appL10n.viewSuggestWorkspacePrompt,
        1 => appL10n.viewSuggestWordCountPrompt,
        2 => appL10n.viewSuggestNodePrompt,
        _ => appL10n.viewSuggestGitPrompt,
      };
}

const defaultSuggestions = <ChatSuggestion>[
  ChatSuggestion._default(AppIcons.folderOpen, 0, SuggestionTint.teal),
  ChatSuggestion._default(AppIcons.code, 1, SuggestionTint.violet),
  ChatSuggestion._default(AppIcons.terminal, 2, SuggestionTint.amber),
  ChatSuggestion._default(AppIcons.tip, 3, SuggestionTint.blue),
];

/// Tips about using DSH Go, one at a time under the suggestions. Each names
/// a gesture or entry the app really has (see the handlers it describes).
List<String> defaultTips() => [
  appL10n.viewTipSteer,
  appL10n.viewTipMidRun,
  appL10n.viewTipSlash,
  appL10n.viewTipMention,
  appL10n.viewTipReplyMenu,
  appL10n.viewTipEditResend,
  appL10n.viewTipQuote,
  appL10n.viewTipTitleDetails,
  appL10n.viewTipContextRing,
  appL10n.viewTipDrawerMenu,
  appL10n.viewTipSearch,
  appL10n.viewTipSettingsSearch,
  appL10n.viewTipModelHere,
  appL10n.viewTipQuickPanel,
  appL10n.viewTipFolderNewChat,
  appL10n.viewTipSwitchHost,
  appL10n.viewTipPasteImage,
  appL10n.viewTipLauncher,
  appL10n.viewTipPetBubble,
  appL10n.viewTipPetPlay,
  appL10n.viewTipActivityStrip,
  appL10n.viewTipImageZoom,
  appL10n.viewTipQueuedRecall,
  appL10n.viewTipKeyboard,
  appL10n.viewTipShareIn,
  appL10n.viewTipShareSelect,
  appL10n.viewTipChartDrag,
  appL10n.viewTipCopyPath,
  appL10n.viewTipCompanion,
  appL10n.viewTipAnswerInline,
  appL10n.viewTipWallpaper,
];

/// 当前时间的来源(测试里固定它,让问候语可复现)。
@visibleForTesting
DateTime Function() chatClock = DateTime.now;

/// 问候语:按本地时间。
String greetingFor(DateTime now) {
  final h = now.hour;
  if (h >= 5 && h < 11) return appL10n.viewGreetingMorning;
  if (h >= 11 && h < 13) return appL10n.viewGreetingNoon;
  if (h >= 13 && h < 18) return appL10n.viewGreetingAfternoon;
  if (h >= 18 && h < 23) return appL10n.viewGreetingEvening;
  return appL10n.viewGreetingNight;
}

/// 新对话的空状态:居中偏上,一尾很淡的鲸尾 + 按时段的问候 + 一句短副标题,
/// 下面是几档控件(empty_actions.dart):
///
/// - 主操作至多一个,只在这一屏自己有出路时出现(连不上引擎:「重新连接」);
/// - 同一规格的安静胶囊:工作区胶囊,以及这次对话的选项(文件夹、预设、权限);
/// - 2×2 的建议卡片:带色底的小图标 + 标题 + 一行说明;
/// - 最下面一行小技巧,点一下换下一条。
///
/// 输入条才是这一屏的主角,这里只是安静地递几个起点。
///
/// ```
///                 ⌒)
///               下午好
///           今天想做点什么？
///         ( ▢ 在「dsh-app」中 ⌄ )        ← 断线时这里换成主色「重新连接」
///      ( ⚒ 标准模式 ⌄ ) ( ⛨ 完全权限 ⌄ )
///
///   ┌ ▣ 看看工作区   ┐ ┌ ▣ 写个小脚本    ┐
///   └ 列出文件和项目 ┘ └ 统计词频并跑一次 ┘
///   ┌ ▣ 新建项目     ┐ ┌ ▣ 讲讲 Git      ┐
///   └ Node.js + TS   ┘ └ rebase 和 merge ┘
///    💡 输入 @ 可以引用工作区里的文件…   3/12 ›
/// ```
///
/// 左右与顶栏、输入条一样离屏幕 12,宽屏时与输入条同宽居中;第一次出现时
/// 由上到下依次淡入。连不上引擎时建议、选项和小技巧都收起,只留「重新连接」。
class ChatEmptyState extends StatelessWidget {
  const ChatEmptyState({
    super.key,
    required this.connected,
    required this.onSuggestion,
    this.connecting = false,
    this.starting = false,
    this.tidying = false,
    this.onReconnect,
    this.idle,
    this.now,
    this.suggestions = defaultSuggestions,
    this.workspace,
    this.onWorkspace,
    this.options,
    this.tips,
    this.tipStart,
  });

  final bool connected;
  final bool connecting;

  /// The on-device engine is booting.
  final bool starting;

  /// Booting includes the one-time tidy of plugin files (RuntimeStatus.tidyingFiles).
  final bool tidying;

  /// The engine could not be reached: the one primary pill, 「重新连接」,
  /// where the workspace chip goes; the suggestions fold away.
  final VoidCallback? onReconnect;

  /// 本机 is down and won't come up by itself (not installed, or stopped
  /// with 打开 App 时自动启动 off): the subtitle says so and the one primary
  /// pill fixes it (「安装运行环境」 / 「启动引擎」).
  final ChatIdleAction? idle;
  final ValueChanged<ChatSuggestion> onSuggestion;

  /// The workspace the new conversation starts in (null: the default).
  final String? workspace;

  /// Switches [workspace].
  final VoidCallback? onWorkspace;

  /// The new conversation's options (folder, preset, permissions), one row of
  /// quiet chips under the workspace chip. Shown only while connected.
  final Widget? options;

  /// The tip line's tips; null = [defaultTips], empty = no tip line.
  final List<String>? tips;

  /// The first tip shown (tests); defaults to a random one.
  final int? tipStart;

  /// 测试注入;默认取当前时间。
  final DateTime? now;
  final List<ChatSuggestion> suggestions;

  /// Same side margin and width cap as the header pills and the composer.
  static const sideMargin = AppSpace.floatInset;
  static const maxWidth = AppSpace.floatingWidth;

  /// Subtitle → the pill or chip under it.
  static const slotGap = 12.0;

  /// The workspace chip → the options row.
  static const optionsGap = 8.0;

  /// The pill or chips → the suggestions.
  static const suggestionsGap = 28.0;

  /// The suggestions → the tip line.
  static const tipGap = 6.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final themeStyle = DshThemeStyle.of(context);
    final emptySpec = themeStyle.emptyState;
    final editorial = emptySpec.layout == ThemeEmptyLayout.editorial;
    final compact = emptySpec.layout == ThemeEmptyLayout.compact;
    final textAlign = editorial ? TextAlign.start : TextAlign.center;
    final blockAlign = editorial ? Alignment.centerLeft : Alignment.center;
    final baseGreeting = (compact ? theme.textTheme.headlineMedium! : theme.textTheme.displaySmall!).copyWith(
      color: theme.colorScheme.onSurface,
    );
    final greetingStyle = emptySpec.useReadingFontForGreeting
        ? themeStyle.readingTextStyle(baseGreeting).copyWith(
            fontSize: (compact ? 24 : 32) * themeStyle.typography.headingScale,
          )
        : baseGreeting;
    final effectiveSlotGap = compact ? 10.0 : slotGap;
    final effectiveOptionsGap = compact ? 8.0 : optionsGap;
    final effectiveSuggestionsGap = compact ? 14.0 : suggestionsGap;
    final retry = connected ? null : onReconnect;
    final idle = connected || retry != null ? null : this.idle;
    final subtitle = connected
        ? l10n.viewEmptySubtitle
        : retry != null
        ? l10n.commonEngineUnreachable
        : idle != null
        ? idle.message
        : starting
        ? (tidying ? l10n.phoneEngineTidyingFilesEllipsis : l10n.viewEmptyStarting)
        : connecting
        ? l10n.viewEmptyConnecting
        : l10n.viewEmptyDisconnected;

    var order = 0;
    Widget enter(Widget child) => FadeSlideIn(index: order++, child: child);
    final tipList = tips ?? defaultTips();

    // One slot under the subtitle: the primary pill or the workspace chip,
    // the same height, swapped in place.
    final Widget? slot = retry != null
        ? EmptyPrimaryPill(key: const ValueKey('reconnect'), label: l10n.viewEmptyReconnect, onTap: retry)
        : idle != null
        ? EmptyPrimaryPill(key: ValueKey(idle.label), label: idle.label, onTap: idle.onTap)
        : workspace != null && connected
        ? ConstrainedBox(
            key: const ValueKey('workspace'),
            constraints: const BoxConstraints(maxWidth: 280),
            child: QuietChip(
              icon: AppIcons.workspace,
              label: l10n.viewEmptyWorkspace(workspace!),
              trailing: onWorkspace == null ? null : AppIcons.expand,
              onTap: onWorkspace,
              onTapHint: l10n.viewEmptySwitchWorkspace,
            ),
          )
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: sideMargin),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The pet stands on the composer below: one mascot a screen,
              // so the still whale tail fades while the pet is drawn. Its
              // room stays, so nothing moves when the pet comes and goes.
              if (emptySpec.heroStyle != ThemeHeroStyle.hidden)
                enter(
                  Consumer(
                    builder: (context, ref, child) => AnimatedOpacity(
                      opacity: ref.watch(petTakesWhaleProvider) ? 0 : 1,
                      duration: AppMotion.of(context, AppMotion.standard),
                      curve: AppMotion.std,
                      child: child,
                    ),
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: compact ? 8 : (emptySpec.heroStyle == ThemeHeroStyle.badge ? 18 : 12),
                      ),
                      child: Align(
                        alignment: blockAlign,
                        child: _buildHero(context, theme, themeStyle, emptySpec, compact: compact),
                      ),
                    ),
                  ),
                ),
              enter(
                Text(
                  greetingFor(now ?? chatClock()),
                  textAlign: textAlign,
                  style: greetingStyle,
                ),
              ),
              if (emptySpec.showConnectedSubtitle || !connected) ...[
                const SizedBox(height: 4),
                enter(
                  AnimatedSwitcher(
                    duration: AppMotion.of(context, AppMotion.quick),
                    child: Text(
                      subtitle,
                      key: ValueKey(subtitle),
                      textAlign: textAlign,
                      style: theme.textTheme.bodyLarge?.copyWith(color: dsh.textTertiary),
                    ),
                  ),
                ),
              ],
              if (slot != null) ...[
                SizedBox(height: effectiveSlotGap),
                enter(
                  Align(
                    alignment: blockAlign,
                    child: AnimatedSwitcher(duration: AppMotion.of(context, AppMotion.quick), child: slot),
                  ),
                ),
              ],
              if (connected && options != null) ...[
                SizedBox(height: effectiveOptionsGap),
                enter(Align(alignment: blockAlign, child: options!)),
              ],
              if (emptySpec.suggestionsDisplay == ThemeSuggestionsDisplay.collapsible &&
                  connected &&
                  (suggestions.isNotEmpty || tipList.isNotEmpty))
                Padding(
                  padding: EdgeInsets.only(top: compact ? 14 : 24),
                  child: ExpansionTile(
                    shape: const Border(),
                    collapsedShape: const Border(),
                    leading: const Icon(AppIcons.tip, size: 18),
                    title: Text(AppLocale.isEnglish ? 'Quick start' : '快速上手'),
                    children: [
                      _suggestionsBlock(order, tipList),
                    ],
                  ),
                )
              else if (suggestions.isNotEmpty || tipList.isNotEmpty)
                ExpandReveal(
                  open: retry == null && idle == null,
                  child: Padding(
                    padding: EdgeInsets.only(top: effectiveSuggestionsGap),
                    child: _suggestionsBlock(order, tipList),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHero(
    BuildContext context,
    ThemeData theme,
    DshThemeStyle themeStyle,
    ThemeEmptyStateSpec emptySpec, {
    bool compact = false,
  }) {
    Widget badge() => DecoratedBox(
      decoration: ShapeDecoration(
        color: theme.colorScheme.primaryContainer,
        shape: themeStyle.pack == null ? AppShape.card : themeStyle.cardShape(),
      ),
      child: Padding(
        padding: EdgeInsets.all(compact ? 8 : 10),
        child: WhaleTail(still: true, height: compact ? 20 : 26, color: theme.colorScheme.primary),
      ),
    );
    return switch (emptySpec.heroStyle) {
      ThemeHeroStyle.whale => WhaleTail(
        still: true,
        height: compact ? 30 : 40,
        color: whaleColorFor(theme.brightness).withValues(alpha: 0.4),
      ),
      ThemeHeroStyle.badge => badge(),
      ThemeHeroStyle.customImage =>
        (themeStyle.folderPath != null && emptySpec.heroImage != null)
            ? ClipRRect(
                borderRadius: themeStyle.scaledBorderRadius(AppShape.md),
                child: Image.file(
                  File('${themeStyle.folderPath}/${emptySpec.heroImage}'),
                  key: ValueKey('${themeStyle.folderPath}/${emptySpec.heroImage}#${themeStyle.assetRevision}'),
                  height: compact ? 48 : 64,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => badge(),
                ),
              )
            : badge(),
      ThemeHeroStyle.hidden => const SizedBox.shrink(),
    };
  }

  Widget _suggestionsBlock(int order, List<String> tipList) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (suggestions.isNotEmpty)
        SuggestionCards(
          suggestions: suggestions,
          enabled: connected,
          onSuggestion: onSuggestion,
          firstIndex: order,
        ),
      if (connected && tipList.isNotEmpty) ...[
        const SizedBox(height: tipGap),
        FadeSlideIn(
          index: order + suggestions.length,
          child: TipLine(tips: tipList, start: tipStart),
        ),
      ],
    ],
  );
}

/// [ChatEmptyState.idle]: what the subtitle says and the pill under it.
class ChatIdleAction {
  const ChatIdleAction({required this.message, required this.label, required this.onTap});

  final String message;
  final String label;
  final VoidCallback onTap;
}
