import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../state/app_info.dart';
import '../../state/onboarding_state.dart';
import '../../state/settings_state.dart';
import '../common/field_paste.dart';
import '../providers/provider_widgets.dart' show FormBottomBar;
import '../settings/credential_recovery_dialog.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'onboarding_scaffold.dart';
import '../common/brief_notice.dart';

/// Removes whitespace a copy/paste may have picked up; keys never contain spaces.
String normalizeApiKey(String raw) => raw.replaceAll(RegExp(r'\s'), '');

/// Light, non-blocking checks: DeepSeek keys start with `sk-`, but other
/// OpenAI-compatible keys are allowed through with a warning.
String? apiKeyWarning(String key) {
  if (key.isEmpty) return null;
  if (!key.startsWith('sk-')) return appL10n.shellApiKeyPrefixWarning;
  if (key.length < 20) return appL10n.shellApiKeyIncompleteWarning;
  return null;
}

/// Short masked form for display: `sk-…a3f9`.
String maskApiKey(String key) {
  final k = key.trim();
  if (k.isEmpty) return '';
  if (k.length <= 8) return '••••';
  final head = k.startsWith('sk-') ? 'sk-' : k.substring(0, 2);
  return '$head…${k.substring(k.length - 4)}';
}

/// DeepSeek API key entry, used by onboarding and by settings ("更换 API Key").
class ApiKeyPage extends ConsumerStatefulWidget {
  const ApiKeyPage({super.key, this.onDone, this.onboarding = true, this.onBack});

  /// Onboarding: called after save or skip. Settings: null, the page pops itself.
  final VoidCallback? onDone;

  /// Onboarding only: shows a back button that returns to the sign-in choice.
  final VoidCallback? onBack;

  /// Shows "稍后设置" and no back button.
  final bool onboarding;

  @override
  ConsumerState<ApiKeyPage> createState() => _ApiKeyPageState();
}

class _ApiKeyPageState extends ConsumerState<ApiKeyPage> with FieldPaste<ApiKeyPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _obscure = true;
  bool _saving = false;
  late final bool _replacing;

  @override
  void initState() {
    super.initState();
    _replacing = ref.read(settingsProvider).hasApiKey;
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final text = normalizeApiKey(await readClipboard() ?? '');
    if (text.isEmpty || !mounted) return;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> _openPlatform() async {
    if (await launchUrl(Uri.parse(AppInfo.deepseekPlatform), mode: LaunchMode.externalApplication)) return;
    await Clipboard.setData(const ClipboardData(text: AppInfo.deepseekPlatform));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.shellBrowserUrlCopied)));
  }

  Future<void> _save() async {
    final key = normalizeApiKey(_controller.text);
    if (key.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      await ref.read(settingsProvider.notifier).setApiKey(key);
      await ref.read(onboardingPrefsProvider.notifier).setKeySkipped(false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      // Not saved again by itself after clearing: the field still has the key.
      if (await offerCredentialRecovery(context, ref, e) || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.shellSaveTryAgain)));
      return;
    }
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    if (widget.onDone case final done?) {
      done();
    } else {
      Navigator.of(context).maybePop();
      showBriefNotice(context, context.l10n.shellApiKeyUpdated);
    }
  }

  Future<void> _skip() async {
    FocusScope.of(context).unfocus();
    await ref.read(onboardingPrefsProvider.notifier).setKeySkipped(true);
    widget.onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final ready = normalizeApiKey(_controller.text).isNotEmpty && !_saving;

    if (!widget.onboarding) {
      // Settings: the form-page frame, the back key where every page has it.
      return Stack(
        children: [
          AppPage.list(
            title: _replacing ? l10n.shellReplaceApiKey : l10n.shellEnterApiKey,
            subtitle: Text(l10n.shellApiKeyBilling),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _fields(context)),
              ),
              const SizedBox(height: FormBottomBar.height),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: FormBottomBar(
              child: FilledButton(
                onPressed: ready ? _save : null,
                child: Text(_saving ? l10n.shellSaving : l10n.commonSave),
              ),
            ),
          ),
        ],
      );
    }
    return OnboardingScaffold(
      leading: widget.onBack == null
          ? null
          : GlassIconButton(icon: AppIcons.back, tooltip: l10n.commonBack, grouped: false, onPressed: widget.onBack),
      children: [
        const Spacer(),
        OnboardingHeader(icon: AppIcons.apiKey, title: l10n.shellEnterApiKey, message: l10n.shellApiKeyBilling),
        const SizedBox(height: 28),
        ..._fields(context),
        const Spacer(flex: 2),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: ready ? _save : null,
          child: _saving
              ? SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.2, color: scheme.onPrimary),
                )
              : Text(l10n.shellSaveContinue),
        ),
        const SizedBox(height: 6),
        TextButton(
          onPressed: _saving ? null : _skip,
          style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
          child: Text(l10n.shellSetUpLater),
        ),
      ],
    );
  }

  /// The key field, its hint line and the 「获取 API Key」 card, shared by both frames.
  List<Widget> _fields(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final key = normalizeApiKey(_controller.text);
    final warning = apiKeyWarning(key);
    return [
      TextField(
        controller: _controller,
        focusNode: _focus,
        obscureText: _obscure,
        obscuringCharacter: '•',
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        keyboardType: TextInputType.visiblePassword,
        textInputAction: TextInputAction.done,
        autofillHints: const [AutofillHints.password],
        onSubmitted: (_) => _save(),
        style: AppType.mono(size: 15, color: scheme.onSurface, height: 1.4),
        decoration: InputDecoration(
          hintText: 'sk-…',
          hintStyle: AppType.mono(size: 15, color: colors.textTertiary, height: 1.4),
          contentPadding: const EdgeInsets.fromLTRB(16, 15, 8, 15),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (key.isEmpty)
                TextButton(onPressed: _paste, child: Text(l10n.commonPaste))
              else
                IconButton(
                  tooltip: l10n.shellClearField,
                  icon: const Icon(AppIcons.close, size: 20),
                  onPressed: _controller.clear,
                ),
              IconButton(
                tooltip: _obscure ? l10n.shellShow : l10n.commonHide,
                icon: Icon(_obscure ? AppIcons.showSecret : AppIcons.hideSecret, size: 20),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
      const SizedBox(height: 10),
      AnimatedSwitcher(
        duration: AppMotion.of(context, AppMotion.quick),
        child: Row(
          key: ValueKey(warning),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                warning == null ? AppIcons.lock : AppIcons.info,
                size: 15,
                color: warning == null ? colors.textTertiary : colors.warning,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                warning ?? l10n.shellApiKeyEncrypted,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: warning == null ? colors.textTertiary : colors.warning,
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      GlassSurface(
        tier: GlassTier.card,
        borderRadius: AppShape.radiusLg,
        onTap: _openPlatform,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.shellGetApiKey, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text('platform.deepseek.com', style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(AppIcons.openLink, size: 18, color: colors.textTertiary),
          ],
        ),
      ),
    ];
  }
}
