import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/ssh/ssh_link.dart';
import '../../state/android_features.dart';
import '../../state/attachments.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../providers/provider_widgets.dart' show FormFieldBlock, FormFieldGroup;
import '../common/app_dialog.dart';
import '../settings/credential_recovery_dialog.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'host_key_dialog.dart';
import 'link_progress.dart';
import '../common/discard_guard.dart';
import '../common/smooth_size.dart';
import '../common/brief_notice.dart';

/// Add or edit an SSH host, with a "测试连接" that runs the real connect flow
/// and shows each step.
class SshHostFormPage extends ConsumerStatefulWidget {
  const SshHostFormPage({super.key, this.existing, this.initialStatus});

  /// Null to add a new host.
  final SshHostConfig? existing;

  /// Pre-filled test progress (goldens).
  @visibleForTesting
  final HostLinkStatus? initialStatus;

  @override
  ConsumerState<SshHostFormPage> createState() => _SshHostFormPageState();
}

class _SshHostFormPageState extends ConsumerState<SshHostFormPage> {
  late final String _id = widget.existing?.id ?? SshHostConfig.newId();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _host = TextEditingController(text: widget.existing?.host ?? '');
  late final _port = TextEditingController(text: '${widget.existing?.port ?? 22}');
  late final _user = TextEditingController(text: widget.existing?.user ?? '');
  late final _command = TextEditingController(text: widget.existing?.launchCommand ?? defaultDshLaunchCommand);
  late final _cwd = TextEditingController(text: widget.existing?.workingDirectory ?? '');
  final _password = TextEditingController();
  final _privateKey = TextEditingController();
  final _passphrase = TextEditingController();
  final _attachToken = TextEditingController();
  late final _remotePort = TextEditingController(text: '${widget.existing?.remotePort ?? 3080}');
  late SshDshMode _dshMode = widget.existing?.dshMode ?? SshDshMode.managed;
  late bool _compression = widget.existing?.compression ?? true;

  late SshAuthMethod _auth = widget.existing?.auth ?? SshAuthMethod.password;
  late String? _keyType = widget.existing?.hostKeyType;
  late String? _keyFingerprint = widget.existing?.hostKeyFingerprint;

  /// `host:port` the pinned key belongs to; a key never follows the host to
  /// another address.
  late String? _keyFor = widget.existing == null ? null : '${widget.existing!.host}:${widget.existing!.port}';
  bool _obscure = true;
  bool _saving = false;

  /// A problem that isn't about one field (saving failed).
  String? _formError;

  /// What is missing or wrong, shown under the field it is about.
  Map<_F, String> _errors = const {};

  /// To bring the first field with a problem into view.
  final _fieldKeys = {for (final f in _F.values) f: GlobalKey()};

  SshHostLink? _test;
  StreamSubscription<HostLinkStatus>? _testSub;
  late HostLinkStatus? _testStatus = widget.initialStatus;

  bool get _editing => widget.existing != null;

  /// The form as opened (with the saved secrets once they are read).
  late String _clean;
  late final Listenable _edits = Listenable.merge([
    _name,
    _host,
    _port,
    _user,
    _command,
    _cwd,
    _password,
    _privateKey,
    _passphrase,
    _attachToken,
    _remotePort,
  ]);

  String _signature() => jsonEncode({
    'name': _name.text,
    'host': _host.text,
    'port': _port.text,
    'user': _user.text,
    'command': _command.text,
    'cwd': _cwd.text,
    'password': _password.text,
    'privateKey': _privateKey.text,
    'passphrase': _passphrase.text,
    'auth': _auth.name,
    'dshMode': _dshMode.name,
    'remotePort': _remotePort.text,
    'attachToken': _attachToken.text,
    'compression': _compression,
    'keyType': _keyType,
    'keyFingerprint': _keyFingerprint,
    'keyFor': _keyFor,
  });

  @override
  void initState() {
    super.initState();
    _clean = _signature();
    if (_editing) unawaited(_loadSecrets());
    // The pinned key only shows while the address it belongs to is entered.
    _host.addListener(_onAddress);
    _port.addListener(_onAddress);
  }

  bool get _keyMatches => _keyFingerprint != null && _keyFor == '${_host.text.trim()}:${_port.text.trim()}';
  bool _lastKeyMatches = true;

  void _onAddress() {
    if (_keyMatches != _lastKeyMatches) setState(() => _lastKeyMatches = _keyMatches);
  }

  Future<void> _loadSecrets() async {
    final clean = jsonDecode(_clean) as Map<String, dynamic>;
    final controllers = [_password, _privateKey, _passphrase, _attachToken];
    final initial = {for (final controller in controllers) controller: controller.text};
    final edited = <TextEditingController>{};
    void trackEdits() {
      for (final controller in controllers) {
        if (controller.text != initial[controller]) edited.add(controller);
      }
    }

    for (final controller in controllers) {
      controller.addListener(trackEdits);
    }
    final SshSecrets secrets;
    try {
      secrets = await ref.read(hostsProvider.notifier).loadSecrets(_id);
    } finally {
      for (final controller in controllers) {
        controller.removeListener(trackEdits);
      }
    }
    if (!mounted) return;
    setState(() {
      // Text edits (including paste and an explicit clear) win over a late
      // storage read. Selection-only changes still allow the initial load.
      if (!edited.contains(_password)) _password.text = secrets.password ?? '';
      if (!edited.contains(_privateKey)) _privateKey.text = secrets.privateKey ?? '';
      if (!edited.contains(_passphrase)) _passphrase.text = secrets.passphrase ?? '';
      if (!edited.contains(_attachToken)) _attachToken.text = secrets.attachToken ?? '';
      // Hydrate only the original secret values in the clean baseline. Other
      // fields may have been edited while secure storage was being read.
      _clean = jsonEncode({
        ...clean,
        'password': secrets.password ?? '',
        'privateKey': secrets.privateKey ?? '',
        'passphrase': secrets.passphrase ?? '',
        'attachToken': secrets.attachToken ?? '',
      });
    });
  }

  @override
  void dispose() {
    unawaited(_testSub?.cancel());
    unawaited(_test?.close());
    for (final c in [_name, _host, _port, _user, _command, _cwd, _password, _privateKey, _passphrase, _attachToken, _remotePort]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The config as typed; null (with [_errors] set) when incomplete.
  SshHostConfig? _draft() {
    final host = _host.text.trim();
    final user = _user.text.trim();
    final port = int.tryParse(_port.text.trim());
    final remotePort = int.tryParse(_remotePort.text.trim());
    final errors = <_F, String>{
      if (host.isEmpty) _F.host: context.l10n.remoteSshAddressRequired,
      if (user.isEmpty) _F.user: context.l10n.remoteSshUsernameRequired,
      if (port == null || port <= 0 || port > 65535) _F.port: '1–65535',
      if (_auth == SshAuthMethod.password && _password.text.isEmpty)
        _F.password: context.l10n.remoteSshPasswordRequired,
      if (_auth == SshAuthMethod.privateKey && _privateKey.text.trim().isEmpty)
        _F.key: context.l10n.remoteSshKeyRequired,
      if (_dshMode == SshDshMode.attachOnly && (remotePort == null || remotePort < 1 || remotePort > 65535))
        _F.remotePort: '1–65535',
      if (_dshMode == SshDshMode.attachOnly && _attachToken.text.trim().isEmpty)
        _F.attachToken: context.l10n.remoteErrAttachSettings,
    };
    setState(() {
      _errors = errors;
      _formError = null;
    });
    if (errors.isNotEmpty) {
      final first = _F.values.firstWhere(errors.containsKey);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _fieldKeys[first]!.currentContext;
        if (target == null || !target.mounted) return;
        unawaited(
          Scrollable.ensureVisible(
            target,
            alignment: 0.3,
            duration: AppMotion.of(context, AppMotion.emphasized),
            curve: AppMotion.glide,
          ),
        );
      });
      return null;
    }
    final keyValid = _keyFor == '$host:$port';
    return SshHostConfig(
      id: _id,
      name: _name.text.trim().isEmpty ? host : _name.text.trim(),
      host: host,
      port: port!,
      user: user,
      auth: _auth,
      dshMode: _dshMode,
      remotePort: remotePort ?? 3080,
      compression: _compression,
      launchCommand: _command.text.trim().isEmpty ? defaultDshLaunchCommand : _command.text.trim(),
      workingDirectory: _cwd.text.trim().isEmpty ? null : _cwd.text.trim(),
      hostKeyType: keyValid ? _keyType : null,
      hostKeyFingerprint: keyValid ? _keyFingerprint : null,
    );
  }

  /// Typing in a field clears its error.
  void _edited(_F field) {
    if (_errors.containsKey(field)) setState(() => _errors = {..._errors}..remove(field));
  }

  SshSecrets get _secrets =>
      SshSecrets(
        password: _password.text, privateKey: _privateKey.text, passphrase: _passphrase.text,
        attachToken: _attachToken.text.trim(),
      );

  Future<void> _runTest({bool restart = false}) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final config = _draft();
    if (config == null) return;
    await _testSub?.cancel();
    await _test?.close();
    final secrets = _secrets;
    final link = SshHostLink(
      config: config,
      loadSecrets: () async => secrets,
      promptHostKey: (prompt) async => mounted && await confirmHostKey(context, prompt),
      pinHostKey: (key) async {
        if (mounted) {
          setState(() {
            _keyType = key.type;
            _keyFingerprint = key.fingerprint;
            _keyFor = '${config.host}:${config.port}';
          });
        }
      },
      transportFactory: ref.read(sshTransportFactoryProvider),
      retryFirstOpen: false,
    );
    _test = link;
    setState(() => _testStatus = const HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect));
    _testSub = link.statuses.listen((s) {
      if (mounted && s.phase != HostLinkPhase.idle) setState(() => _testStatus = s);
    });
    try {
      if (restart) {
        await link.restartManaged();
      } else {
        await link.open();
      }
    } catch (_) {
      // Shown in the progress card.
    } finally {
      await _testSub?.cancel();
      _testSub = null;
      if (identical(_test, link)) {
        _test = null;
        // The terminal status may have painted before async cleanup finished.
        if (mounted) setState(() {});
      }
      // The remote dsh keeps running for the real connection; only our
      // test session closes.
      await link.close();
    }
  }

  Future<void> _confirmRestart() async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.remoteRestartManaged),
        content: Text(context.l10n.remoteRestartManagedWarning),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.remoteRestartManaged),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await _runTest(restart: true);
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final config = _draft();
    if (config == null) return;
    setState(() => _saving = true);
    try {
      final saved = await ref.read(hostsProvider.notifier).saveSsh(config, secrets: _secrets);
      if (!mounted) return;
      if (!saved) {
        setState(() => _formError = context.l10n.commonSaveFailed);
        return;
      }
      Navigator.of(context).pop(config);
    } catch (e) {
      if (mounted) {
        setState(() => _formError = context.l10n.commonSaveFailed);
        // Cleared or not, nothing was saved: the form stays filled in.
        await offerCredentialRecovery(context, ref, e);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetKey() async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.remoteHostKeyResetTitle),
        content: Text(context.l10n.remoteHostKeyResetBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
          // Weakens the one check against an impostor: the danger colour, as
          // 「重新信任」 has.
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.remoteReset),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _keyType = null;
      _keyFingerprint = null;
      _testStatus = null;
    });
    if (_editing) await ref.read(hostsProvider.notifier).resetHostKey(_id);
  }

  Future<void> _delete() async {
    final name = widget.existing!.name;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.remoteDeleteHostTitle(name)),
        content: Text(context.l10n.remoteDeleteHostBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(hostsProvider.notifier).removeSsh(_id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pasteKey() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text;
    if (text != null && text.trim().isNotEmpty) setState(() => _privateKey.text = text.trim());
  }

  /// A key file from the phone (Download, a file manager, a cloud drive), for
  /// people who'd rather not move a private key through the clipboard.
  Future<void> _importKey() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    String? text;
    try {
      text = await ref.read(attachmentPickerProvider).pickTextFile();
    } catch (e) {
      if (!mounted) return;
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.remoteErrReadKey((e is FormatException ? e.message : e).toString()))),
      );
      return;
    }
    if (text == null || !mounted) return;
    if (!text.contains('PRIVATE KEY-----')) {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.remoteErrPublicKeyFile)));
      return;
    }
    setState(() => _privateKey.text = text!.trim());
    messenger?.showBriefNotice(l10n.remotePrivateKeyImported);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    const installCommand = 'npm i -g @deepseek-ai/dsh';
    final installHint = l10n.remoteSshInstallCommand(installCommand).split(installCommand);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final testing = _test != null;
    final mono = AppType.mono(size: 15, color: scheme.onSurface, height: 1.4);

    final page = AppPage.list(
      title: _editing ? l10n.remoteEditHost : l10n.remoteAddSshHost,
      subtitle: _editing ? null : Text(l10n.remoteSshHostIntro),
      // One column, not a lazy list: every field stays built so the first one
      // with a problem can be scrolled into view.
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSection(
              title: l10n.remoteHostBasicInfo,
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      label: l10n.commonName,
                      child: TextField(
                        controller: _name,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(hintText: l10n.remoteHostNameHint),
                      ),
                    ),
                    FormFieldBlock(
                      key: _fieldKeys[_F.host],
                      error: _errors[_F.host],
                      label: l10n.remoteHost,
                      child: TextField(
                        controller: _host,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        style: mono,
                        onChanged: (_) => _edited(_F.host),
                        decoration: InputDecoration(
                          hintText: l10n.remoteHostAddressHint,
                          error: _errors[_F.host] == null ? null : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: FormFieldBlock(
                            key: _fieldKeys[_F.user],
                            error: _errors[_F.user],
                            label: l10n.remoteUsername,
                            child: TextField(
                              controller: _user,
                              autocorrect: false,
                              textInputAction: TextInputAction.next,
                              style: mono,
                              onChanged: (_) => _edited(_F.user),
                              decoration: InputDecoration(
                                hintText: 'me',
                                error: _errors[_F.user] == null ? null : const SizedBox.shrink(),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 96,
                          child: FormFieldBlock(
                            key: _fieldKeys[_F.port],
                            error: _errors[_F.port],
                            label: l10n.remotePort,
                            child: TextField(
                              controller: _port,
                              keyboardType: TextInputType.number,
                              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                              textInputAction: TextInputAction.next,
                              style: mono,
                              onChanged: (_) => _edited(_F.port),
                              decoration: InputDecoration(
                                error: _errors[_F.port] == null ? null : const SizedBox.shrink(),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: l10n.remoteAuthentication,
              footer: Text(switch ((_auth == SshAuthMethod.password, ref.watch(operatingSystemProvider) == 'ios')) {
                (true, true) => l10n.remotePasswordStorageHelpIos,
                (true, false) => l10n.remotePasswordStorageHelp,
                (false, true) => l10n.remoteKeyStorageHelpIos,
                (false, false) => l10n.remoteKeyStorageHelp,
              }),
              children: [
                FormFieldGroup(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: SegmentedPill<SshAuthMethod>(
                        segments: [
                          PillSegment(SshAuthMethod.password, l10n.remotePassword),
                          PillSegment(SshAuthMethod.privateKey, l10n.remotePrivateKey),
                        ],
                        selected: _auth,
                        onChanged: (v) => setState(() => _auth = v),
                      ),
                    ),
                    if (_auth == SshAuthMethod.password)
                      FormFieldBlock(
                        key: _fieldKeys[_F.password],
                        error: _errors[_F.password],
                        label: l10n.remotePassword,
                        child: TextField(
                          controller: _password,
                          obscureText: _obscure,
                          obscuringCharacter: '•',
                          autocorrect: false,
                          enableSuggestions: false,
                          enableIMEPersonalizedLearning: false,
                          keyboardType: TextInputType.visiblePassword,
                          onChanged: (_) => _edited(_F.password),
                          decoration: InputDecoration(
                            error: _errors[_F.password] == null ? null : const SizedBox.shrink(),
                            suffixIcon: IconButton(
                              tooltip: _obscure ? l10n.remoteShow : l10n.commonHide,
                              icon: Icon(_obscure ? AppIcons.showSecret : AppIcons.hideSecret, size: 20),
                              onPressed: () => setState(() => _obscure = !_obscure),
                            ),
                          ),
                        ),
                      )
                    else ...[
                      FormFieldBlock(
                        key: _fieldKeys[_F.key],
                        error: _errors[_F.key],
                        label: l10n.remotePrivateKey,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _SmallTextButton(label: l10n.remoteImportKeyFile, onPressed: _importKey),
                            _SmallTextButton(label: l10n.commonPaste, onPressed: _pasteKey),
                          ],
                        ),
                        child: TextField(
                          controller: _privateKey,
                          minLines: 3,
                          maxLines: 6,
                          autocorrect: false,
                          enableSuggestions: false,
                          enableIMEPersonalizedLearning: false,
                          keyboardType: TextInputType.multiline,
                          onChanged: (_) => _edited(_F.key),
                          style: AppType.mono(size: 12, color: scheme.onSurface, height: 1.45),
                          decoration: InputDecoration(
                            hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\n…',
                            hintStyle: AppType.mono(size: 12, color: colors.textTertiary, height: 1.45),
                            error: _errors[_F.key] == null ? null : const SizedBox.shrink(),
                          ),
                        ),
                      ),
                      FormFieldBlock(
                        label: l10n.remotePrivateKeyPassword,
                        child: TextField(
                          controller: _passphrase,
                          obscureText: true,
                          obscuringCharacter: '•',
                          autocorrect: false,
                          enableSuggestions: false,
                          enableIMEPersonalizedLearning: false,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: 'DSH',
              footer: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: installHint.first),
                    TextSpan(
                      text: installCommand,
                      style: AppType.monoLabel(color: scheme.onSurfaceVariant),
                    ),
                    TextSpan(text: installHint.last),
                  ],
                ),
              ),
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      label: l10n.remoteDshMode,
                      helper: _dshMode == SshDshMode.managed ? l10n.remoteManagedHelp : l10n.remoteAttachOnlyHelp,
                      child: SegmentedPill<SshDshMode>(
                        segments: [
                          PillSegment(SshDshMode.managed, l10n.remoteManaged),
                          PillSegment(SshDshMode.attachOnly, l10n.remoteAttachOnly),
                        ],
                        selected: _dshMode,
                        onChanged: (v) => setState(() {
                          _dshMode = v;
                          _testStatus = null;
                        }),
                      ),
                    ),
                    if (_dshMode == SshDshMode.managed)
                      FormFieldBlock(
                        label: l10n.remoteStartCommand,
                        helper: l10n.remoteStartCommandHelp,
                        child: TextField(controller: _command, autocorrect: false, style: mono),
                      )
                    else ...[
                      FormFieldBlock(
                        key: _fieldKeys[_F.remotePort],
                        error: _errors[_F.remotePort],
                        label: l10n.remoteDshPort,
                        child: TextField(
                          controller: _remotePort,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          style: mono,
                          onChanged: (_) => _edited(_F.remotePort),
                        ),
                      ),
                      FormFieldBlock(
                        key: _fieldKeys[_F.attachToken],
                        error: _errors[_F.attachToken],
                        label: l10n.remoteDshToken,
                        helper: l10n.remoteDshTokenHelp,
                        child: TextField(
                          controller: _attachToken,
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          enableIMEPersonalizedLearning: false,
                          onChanged: (_) => _edited(_F.attachToken),
                        ),
                      ),
                    ],
                    FormFieldBlock(
                      label: l10n.remoteWorkingDirectory,
                      helper: _dshMode == SshDshMode.attachOnly
                          ? l10n.remoteAttachWorkingDirectoryHelp : l10n.remoteWorkingDirectoryHelp,
                      child: TextField(
                        controller: _cwd,
                        autocorrect: false,
                        style: mono,
                        decoration: InputDecoration(hintText: _dshMode == SshDshMode.attachOnly ? '/srv/code' : '~/code'),
                      ),
                    ),
                  ],
                ),
                SettingsSwitchTile(
                  title: l10n.remoteSshCompression,
                  subtitle: l10n.remoteSshCompressionHelp,
                  value: _compression,
                  onChanged: (v) => setState(() => _compression = v),
                ),
                if (_dshMode == SshDshMode.managed)
                  TextButton(
                    onPressed: testing || _saving ? null : _confirmRestart,
                    child: Text(l10n.remoteRestartManaged),
                  ),
              ],
            ),
            SettingsSection(
              title: l10n.remoteHostFingerprint,
              children: [
                if (!_keyMatches)
                  SettingsTile(
                    icon: AppIcons.fingerprint,
                    tinted: false,
                    title: l10n.remoteHostKeyNotConfirmed,
                    subtitle: l10n.remoteHostKeyFirstCheck,
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 10, SettingsMetrics.trailingPad, 10),
                    child: Row(
                      children: [
                        SizedBox.square(
                          dimension: SettingsMetrics.icon,
                          child: Icon(AppIcons.verified, size: SettingsMetrics.lineGlyph, color: colors.success),
                        ),
                        const SizedBox(width: SettingsMetrics.iconGap),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                PresentedHostKey(_keyType ?? '', _keyFingerprint!).shortType,
                                style: AppType.monoLabel(color: colors.textTertiary),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _keyFingerprint!,
                                style: AppType.mono(size: 12, color: scheme.onSurfaceVariant, height: 1.45),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        _SmallTextButton(label: l10n.remoteReset, onPressed: _resetKey),
                      ],
                    ),
                  ),
              ],
            ),
            _Reveal(
              child: _testStatus == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      child: LinkProgressCard(status: _testStatus!, onRetry: testing ? null : _runTest),
                    ),
            ),
            if (_formError case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Text(error, style: theme.textTheme.bodySmall?.copyWith(color: colors.danger)),
              ),
            if (_editing)
              Center(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: colors.danger),
                  onPressed: _delete,
                  icon: const Icon(AppIcons.delete, size: 19),
                  label: Text(l10n.remoteDeleteHost),
                ),
              ),
            const SizedBox(height: _FormBar.height),
          ],
        ),
      ],
    );

    return DiscardGuard(
      listenable: _edits,
      isDirty: () => !_saving && _signature() != _clean,
      child: Stack(
        children: [
          page,
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: _FormBar(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: testing || _saving ? null : _runTest,
                    icon: testing
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(AppIcons.testConnection, size: 19),
                    label: Text(testing ? l10n.remoteTesting : l10n.remoteTestConnection),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(onPressed: _saving ? null : _save, child: Text(l10n.commonSave)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The fields of a form page.
enum _F { host, user, port, password, key, remotePort, attachToken }

/// A compact text action in a field label row; its label ends flush with the
/// field's edge.
class _SmallTextButton extends StatelessWidget {
  const _SmallTextButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        textStyle: Theme.of(context).textTheme.labelMedium,
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// The form page's bottom bar: the actions stay put above the page (and above
/// the keyboard), over a soft fade of the page background.
class _FormBar extends StatelessWidget {
  const _FormBar({required this.children});

  final List<Widget> children;

  /// Room to leave at the end of the page so nothing hides under the bar.
  static const height = 88.0;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom > 0 ? 0.0 : MediaQuery.viewPaddingOf(context).bottom;
    final base = DshSurfaces.of(context).backdropBottom;
    // The page fades out above the keys; under them the bar is solid, so
    // nothing scrolls through a tonal or disabled fill.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [base.withValues(alpha: 0), base],
            ),
          ),
          child: const SizedBox(height: 24),
        ),
        ColoredBox(
          color: base,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + bottom),
            child: Row(children: children),
          ),
        ),
      ],
    );
  }
}

/// [AnimatedSize] unless animations are off (a zero-duration AnimatedSize
/// re-dirties itself during layout).
class _Reveal extends StatelessWidget {
  const _Reveal({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.of(context, AppMotion.standard);
    if (duration == Duration.zero) return child;
    return SmoothSize(duration: duration, curve: AppMotion.std, alignment: Alignment.topCenter, child: child);
  }
}
