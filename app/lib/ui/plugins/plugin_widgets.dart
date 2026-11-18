import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/plugins_state.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../common/brief_notice.dart';
import '../common/display_image.dart';

/// Plugin icon, app-store style: a rounded square (continuous corners, about
/// a quarter of the side) holding a lazily loaded https image or an inline
/// PNG/JPEG/WebP data URL; anything else (SVG, failures, while loading) shows
/// the first letter on an identity-tinted square.
class PluginAvatar extends StatelessWidget {
  const PluginAvatar({super.key, required this.name, this.title, this.icon, this.size = 40});

  /// Package name: picks the tint, so a plugin keeps its colour.
  final String name;
  final String? title;
  final String? icon;
  final double size;

  static final Map<String, Uint8List?> _decoded = {};

  static Uint8List? _bytes(String dataUrl) => _decoded.putIfAbsent(dataUrl, () {
    if (!RegExp(r'^data:image/(?:png|jpeg|webp);base64,').hasMatch(dataUrl)) {
      return null;
    }
    try {
      return UriData.parse(dataUrl).contentAsBytes();
    } on FormatException {
      return null;
    }
  });

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    final slot = DshColors.identityIndex(name);
    final shape = Squircle.border(size * 0.25);
    final label = (title?.trim().isNotEmpty ?? false) ? title!.trim() : _bareName(name);
    final fallback = DecoratedBox(
      decoration: ShapeDecoration(color: colors.identity[slot], shape: shape),
      child: Center(
        child: Text(
          String.fromCharCodes(label.runes.take(1)).toUpperCase(),
          style: TextStyle(
            fontSize: size * 0.42,
            fontWeight: FontWeight.w600,
            color: colors.onIdentity[slot],
            height: 1,
          ),
        ),
      ),
    );
    final source = icon;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    ImageProvider displayed(ImageProvider image) => imageForDisplay(image, width: size, height: size, pixelRatio: dpr);
    Widget? image;
    if (source != null && source.startsWith('data:')) {
      final bytes = _bytes(source);
      if (bytes != null) {
        image = Image(
          image: displayed(MemoryImage(bytes)),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => fallback,
        );
      }
    } else if (source != null && source.startsWith('https://')) {
      image = Image(
        image: displayed(NetworkImage(source)),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => fallback,
        frameBuilder: (context, child, frame, sync) => frame == null && !sync ? fallback : child,
      );
    }
    return SizedBox.square(
      dimension: size,
      child: image == null
          ? fallback
          : ClipPath(
              clipper: ShapeBorderClipper(shape: shape),
              child: image,
            ),
    );
  }

  static String _bareName(String name) {
    final slash = name.lastIndexOf('/');
    var bare = slash >= 0 ? name.substring(slash + 1) : name;
    for (final prefix in const ['dsh-plugin-', 'dsh-']) {
      if (bare.startsWith(prefix) && bare.length > prefix.length) {
        bare = bare.substring(prefix.length);
      }
    }
    return bare;
  }
}

/// A plugin's name in a list row: semibold, like an app's name in a store.
TextStyle? pluginRowTitle(BuildContext context) =>
    Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: 15, height: 1.4);

/// Small tinted label ("官方", "编辑推荐", "网页版").
class PluginBadge extends StatelessWidget {
  const PluginBadge(this.text, {super.key, this.tone = PluginBadgeTone.neutral});

  final String text;
  final PluginBadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final (bg, fg) = switch (tone) {
      PluginBadgeTone.official => (scheme.primaryContainer, scheme.onPrimaryContainer),
      PluginBadgeTone.featured || PluginBadgeTone.warning => (colors.warningContainer, colors.onWarningContainer),
      PluginBadgeTone.danger => (colors.dangerContainer, colors.onDangerContainer),
      PluginBadgeTone.neutral => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return DecoratedBox(
      decoration: ShapeDecoration(color: bg, shape: Squircle.border(8)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        child: Text(
          text,
          style: theme.textTheme.labelSmall?.copyWith(color: fg, fontWeight: FontWeight.w600, height: 1.3),
        ),
      ),
    );
  }
}

enum PluginBadgeTone { neutral, official, featured, warning, danger }

/// The app-store capsule at the end of a market row: 获取 / 更新 / 已安装,
/// or a small ring with 安装中 while an install runs. Every state opens the
/// detail sheet ([onPressed]); installing always goes through it.
class PluginInstallButton extends StatelessWidget {
  const PluginInstallButton({super.key, required this.status, this.job, this.onPressed});

  final MarketInstallStatus status;
  final PluginInstallJob? job;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final running = job?.isActive ?? false;
    final installed = !running && status == MarketInstallStatus.installed;
    final track = dark ? Colors.white.withValues(alpha: 0.09) : scheme.onSurface.withValues(alpha: 0.06);
    final fg = installed ? colors.textTertiary : scheme.primary;
    final label = running
        ? l10n.pluginsInstalling
        : switch (status) {
            MarketInstallStatus.installed => l10n.commonInstalled,
            MarketInstallStatus.updateAvailable => l10n.commonUpdate,
            MarketInstallStatus.notInstalled => l10n.pluginsGet,
          };
    return FilledButton.tonal(
      style: FilledButton.styleFrom(
        backgroundColor: installed ? Colors.transparent : track,
        foregroundColor: fg,
        minimumSize: const Size(68, 30),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        shape: const StadiumBorder(),
        elevation: 0,
        textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 13.5),
      ),
      onPressed: onPressed,
      child: AnimatedSwitcher(
        duration: AppMotion.of(context, AppMotion.quick),
        child: Row(
          key: ValueKey(label),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (running) ...[
              SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(strokeWidth: 1.8, strokeCap: StrokeCap.round, color: fg),
              ),
              const SizedBox(width: 6),
            ],
            Text(label),
          ],
        ),
      ),
    );
  }
}

/// Live progress of one install: phase, an indeterminate bar, cancel and
/// the pnpm output behind 「查看安装日志」.
class PluginInstallProgress extends StatelessWidget {
  const PluginInstallProgress({super.key, required this.job, this.onCancel});

  final PluginInstallJob job;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: Text(job.phaseLabel, style: theme.textTheme.titleSmall)),
            if (job.cancellable && onCancel != null) TextButton(onPressed: onCancel, child: Text(l10n.commonCancel)),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(borderRadius: AppShape.radiusXs, child: const LinearProgressIndicator(minHeight: 4)),
        const SizedBox(height: 8),
        Text(
          job.phase == PluginInstallPhase.applying ? l10n.pluginsLoadingCannotCancel : l10n.pluginsInstallDuration,
          style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
        ),
        if (job.log.trim().isNotEmpty) PluginLogBox(text: job.log, title: l10n.pluginsViewInstallLogs),
      ],
    );
  }
}

/// Collapsible monospace output with a copy button.
class PluginLogBox extends StatefulWidget {
  const PluginLogBox({super.key, required this.text, this.title});

  final String text;
  final String? title;

  @override
  State<PluginLogBox> createState() => _PluginLogBoxState();
}

class _PluginLogBoxState extends State<PluginLogBox> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: colors.textTertiary,
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 36),
              textStyle: theme.textTheme.labelMedium,
            ),
            onPressed: () => setState(() => _open = !_open),
            icon: Icon(_open ? AppIcons.collapse : AppIcons.expand, size: 18),
            label: Text(_open ? l10n.commonCollapse : (widget.title ?? l10n.pluginsViewDetails)),
          ),
        ),
        if (_open)
          DecoratedBox(
            decoration: ShapeDecoration(color: colors.codeWellBg, shape: Squircle.border(AppShape.sm)),
            child: Stack(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: SingleChildScrollView(
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(12, 10, 36, 10),
                    child: SelectableText(widget.text.trimRight(), style: AppType.monoSmall(color: colors.codeWellFg)),
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: IconButton(
                    tooltip: l10n.commonCopy,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(AppIcons.copy, size: 16, color: colors.textTertiary),
                    onPressed: () => Clipboard.setData(ClipboardData(text: widget.text)),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A failed operation: title, plain explanation, optional actions and the
/// diagnostic behind 「查看详情」.
class PluginFailureBox extends StatelessWidget {
  const PluginFailureBox({super.key, required this.failure, this.actions = const []});

  final PluginFailure failure;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final cancelled = failure.kind == PluginFailureKind.cancelled;
    final fg = cancelled ? theme.colorScheme.onSurfaceVariant : colors.onDangerContainer;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: cancelled ? theme.colorScheme.surfaceContainerHighest : colors.dangerContainer,
        shape: Squircle.border(AppShape.md),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(failure.title, style: theme.textTheme.titleSmall?.copyWith(color: fg)),
            const SizedBox(height: 4),
            Text(failure.message, style: theme.textTheme.bodySmall?.copyWith(color: fg, height: 1.55)),
            if (actions.isNotEmpty) ...[const SizedBox(height: 8), Wrap(spacing: 8, runSpacing: 4, children: actions)],
            if (failure.detail case final detail? when detail.trim().isNotEmpty) PluginLogBox(text: detail),
            if (actions.isEmpty && (failure.detail?.trim().isEmpty ?? true)) const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// Amber "this runs code with full access" note shown before installing.
class PluginTrustNote extends StatelessWidget {
  const PluginTrustNote({super.key, this.local = true, this.thirdParty = false});

  final bool local;
  final bool thirdParty;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(color: colors.warningContainer, shape: Squircle.border(AppShape.md)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(AppIcons.permissions, size: 18, color: colors.onWarningContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                local
                    ? switch ((thirdParty, wordsForIos)) {
                        (true, true) => l10n.iosPluginsPermissionLocalThirdParty,
                        (false, true) => l10n.iosPluginsPermissionLocalTrusted,
                        (true, false) => l10n.pluginsPermissionLocalThirdParty,
                        (false, false) => l10n.pluginsPermissionLocalTrusted,
                      }
                    : (thirdParty ? l10n.pluginsPermissionRemoteThirdParty : l10n.pluginsPermissionRemoteTrusted),
                style: theme.textTheme.bodySmall?.copyWith(color: colors.onWarningContainer, height: 1.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Monospace command with a copy button (relay hosts).
class PluginCommandBox extends StatelessWidget {
  const PluginCommandBox({super.key, required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(color: colors.codeWellBg, shape: Squircle.border(AppShape.sm)),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              child: SelectableText(command, style: AppType.monoSmall(color: colors.codeWellFg)),
            ),
          ),
          IconButton(
            tooltip: l10n.pluginsCopyCommand,
            icon: Icon(AppIcons.copy, size: 18, color: colors.textTertiary),
            onPressed: () async {
              final messenger = ScaffoldMessenger.maybeOf(context);
              await Clipboard.setData(ClipboardData(text: command));
              messenger?.showBriefNotice(l10n.pluginsCommandCopied);
            },
          ),
        ],
      ),
    );
  }
}

/// Chinese line for a listed bundle's `error`.
String bundleErrorText(PluginBundle bundle) {
  final error = bundle.error;
  if (error == null) {
    return bundle.installed && bundle.availability == 'missing' ? appL10n.pluginsMissingFiles : '';
  }
  return switch (error.code) {
    'not-bundle' => appL10n.pluginsNotDshPlugin,
    'incompatible-version' =>
      error.incompatible.isEmpty
          ? appL10n.pluginsIncompatible
          : appL10n.pluginsRequiresDshVersion(
              error.incompatible.first.requirements.values.join(appL10n.pluginsListSeparator),
              error.incompatible.first.runtimeVersion,
            ),
    'operation-error' => appL10n.pluginsLoadFailure(_firstLine(error.diagnostic) ?? appL10n.pluginsUnknownReason),
    _ => appL10n.pluginsBundleProblem(_firstLine(error.diagnostic) ?? error.code),
  };
}

String? _firstLine(String? text) {
  if (text == null) return null;
  for (final line in const LineSplitter().convert(text)) {
    if (line.trim().isNotEmpty) return line.trim();
  }
  return null;
}
