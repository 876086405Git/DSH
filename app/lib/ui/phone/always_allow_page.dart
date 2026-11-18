// 设置 › 手机操控 › 始终允许: a switch and the apps it covers. Turning it on
// asks once each time (a one-sentence danger notice); turning it off is one tap.
// Adding only picks a package name: the modal channel has no installed-app
// list, so the app is named the same way 应用名单 does it.
//
// ```
//   始终允许
//   ╭──────────────────────────────────╮
//   │ ⚿ 始终允许                  ( ●) │
//   │   不再询问就把内容发到你选的应用   │
//   ╰──────────────────────────────────╯
//   ╭──────────────────────────────────╮
//   │ ▶ 淘宝                      移除 │
//   │ ▶ 微信                      移除 │
//   ╰──────────────────────────────────╯
//   ╭──────────────────────────────────╮
//   │ ＋ 添加应用                      │
//   ╰──────────────────────────────────╯
// ```

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/phone_state.dart';
import '../common/app_dialog.dart';
import '../common/brief_notice.dart';
import '../common/list_page_row.dart';
import '../features/feature_kit.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';

/// The row value for 始终允许: 未开启 / 已允许 N 个应用; null while unread.
String? phoneAlwaysAllowSummary(L10n l10n, PhonePolicies? policies) {
  if (policies == null) return null;
  return policies.alwaysAllowEnabled
      ? l10n.phoneAlwaysAllowCount(policies.alwaysAllowPackages.length)
      : l10n.phoneAlwaysAllowOff;
}

class PhoneAlwaysAllowPage extends ConsumerStatefulWidget {
  const PhoneAlwaysAllowPage({super.key});

  @override
  ConsumerState<PhoneAlwaysAllowPage> createState() => _PhoneAlwaysAllowPageState();
}

class _PhoneAlwaysAllowPageState extends ConsumerState<PhoneAlwaysAllowPage> {
  /// A write is in flight: the switch and the list wait.
  bool _busy = false;

  PhoneController get _phone => ref.read(phoneProvider.notifier);

  @override
  void initState() {
    super.initState();
    // Fresh: the lists may have changed since the provider's last read.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_phone.refresh());
    });
  }

  Future<void> _setEnabled(bool on) async {
    if (_busy) return;
    final policies = ref.read(phoneProvider).policies;
    if (policies == null) return;
    if (on) {
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          content: Text(context.l10n.phoneAlwaysAllowWarning),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(context.l10n.phoneAlwaysAllowConfirm),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    // Read again after the dialog: another write may have landed meanwhile.
    final current = ref.read(phoneProvider).policies;
    if (current == null) return;
    await _write(enabled: on, packages: current.alwaysAllowPackages);
  }

  Future<void> _remove(String package) async {
    final policies = ref.read(phoneProvider).policies;
    if (policies == null) return;
    await _write(enabled: policies.alwaysAllowEnabled, packages: [...policies.alwaysAllowPackages]..remove(package));
  }

  Future<void> _add() async {
    final policies = ref.read(phoneProvider).policies;
    if (policies == null || _busy) return;
    final picked = await showAppDialog<String>(context: context, builder: (_) => const _AddAppDialog());
    if (picked == null || !mounted) return;
    final current = ref.read(phoneProvider).policies;
    if (current == null || current.alwaysAllowPackages.contains(picked)) return;
    await _write(enabled: true, packages: [...current.alwaysAllowPackages, picked]);
  }

  Future<void> _write({required bool enabled, required List<String> packages}) async {
    setState(() => _busy = true);
    final ok = await _phone.setAlwaysAllow(enabled: enabled, packages: packages);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) showBriefNotice(context, context.l10n.phoneAlwaysAllowSaveFailed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(phoneProvider);
    final policies = state.policies;
    final on = policies?.alwaysAllowEnabled ?? false;
    final packages = policies?.alwaysAllowPackages ?? const <String>[];
    return AppPage.list(
      title: l10n.phoneAlwaysAllowTitle,
      children: [
        if (!state.loaded)
          const QuietSpinner(padding: EdgeInsets.symmetric(vertical: 32))
        else ...[
          ListPageCard(
            children: [
              MergeSemantics(
                child: ListPageRow(
                  key: const ValueKey('always-allow-row'),
                  icon: AppIcons.unlocks,
                  title: l10n.phoneAlwaysAllowTitle,
                  subtitle: l10n.phoneAlwaysAllowSwitchHint,
                  subtitleMaxLines: 2,
                  chevron: false,
                  onTap: policies == null || _busy ? null : () => unawaited(_setEnabled(!on)),
                  trailing: _busy
                      ? const SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round),
                        )
                      : Switch(
                          key: const ValueKey('always-allow-switch'),
                          value: on,
                          onChanged: policies == null ? null : (value) => unawaited(_setEnabled(value)),
                        ),
                ),
              ),
            ],
          ),
          if (on && policies != null) ...[
            const SizedBox(height: 24),
            ListPageCard(
              children: [
                if (packages.isEmpty)
                  ListPageRow(leading: const SizedBox.shrink(), title: l10n.phoneAlwaysAllowEmpty)
                else
                  for (final package in packages)
                    ListPageRow(
                      key: ValueKey('always-allow-$package'),
                      icon: AppIcons.allowed,
                      title: policies.labelFor(package),
                      subtitle: policies.labelFor(package) == package ? null : package,
                      chevron: false,
                      trailing: TextButton(
                        onPressed: _busy ? null : () => unawaited(_remove(package)),
                        child: Text(l10n.phoneAlwaysAllowRemove),
                      ),
                    ),
              ],
            ),
            const SizedBox(height: 24),
            ListPageCard(
              children: [
                ListPageRow(
                  icon: AppIcons.add,
                  title: l10n.phoneAlwaysAllowAdd,
                  chevron: false,
                  onTap: _busy ? null : () => unawaited(_add()),
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }
}

/// A package name to add to 始终允许. The same field and format check as
/// 应用名单's 添加 App, without the rule picker.
class _AddAppDialog extends StatefulWidget {
  const _AddAppDialog();

  @override
  State<_AddAppDialog> createState() => _AddAppDialogState();
}

class _AddAppDialogState extends State<_AddAppDialog> {
  final _package = TextEditingController();

  static final _pattern = RegExp(r'^[A-Za-z][\w]*(\.[A-Za-z][\w]*)+$');

  @override
  void dispose() {
    _package.dispose();
    super.dispose();
  }

  bool get _valid => _pattern.hasMatch(_package.text.trim());

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.phoneAlwaysAllowAdd),
      content: TextField(
        controller: _package,
        autofocus: true,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: l10n.phoneAppRulesPackage,
          hintText: 'com.taobao.taobao',
          helperText: l10n.phoneAppRulesPackageHint,
        ),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
        FilledButton(
          onPressed: _valid ? () => Navigator.pop(context, _package.text.trim()) : null,
          child: Text(l10n.commonAdd),
        ),
      ],
    );
  }
}
