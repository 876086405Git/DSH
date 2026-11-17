// 她记得的事: the companion's confirmed memories on the active host
// (packages/dsh_client/lib/src/companion_api.dart). Every change shows only
// once the Host has answered; a conflict reads the list again instead of
// writing over someone else's change.

import 'dart:async';
import 'dart:math';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_keeper.dart';
import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/empty_view.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/semantic_colors.dart';

/// The bridge's limit for one memory, in code points.
const _maxLength = 512;

/// A v4 UUID: memories are named by the client so a retried save can't add two.
String companionMemoryId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

class CompanionMemoryPage extends ConsumerStatefulWidget {
  const CompanionMemoryPage({super.key, this.phone});

  /// Light mode: her memories on this phone instead of the active host.
  final CompanionKeeper? phone;

  @override
  ConsumerState<CompanionMemoryPage> createState() => _CompanionMemoryPageState();
}

enum _Load { loading, ready, unsupported, failed }

class _CompanionMemoryPageState extends ConsumerState<CompanionMemoryPage> {
  _Load _load = _Load.loading;
  CompanionMemories? _list;
  DshClient? _client;
  late HostRef _bindingHost;
  int _bindingEpoch = 0;
  int _readSerial = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _bindingHost = ref.read(activeHostProvider);
    _client = ref.read(activeConnectionProvider).value?.client;
    unawaited(_read());
  }

  /// Where the list is kept: this phone (light mode) or the active host.
  CompanionKeeper? get _keeper {
    final phone = widget.phone;
    if (phone != null) return phone;
    final client = _client;
    return client == null ? null : HostKeeper(client);
  }

  /// A read, write or dialog belongs to this visit, including after A→B→A.
  bool Function() _currentRoom() {
    final epoch = _bindingEpoch;
    // The phone's list belongs to no host.
    if (widget.phone != null) return () => mounted && epoch == _bindingEpoch;
    final host = _bindingHost;
    final client = _client;
    return () =>
        mounted &&
        epoch == _bindingEpoch &&
        host == ref.read(activeHostProvider) &&
        identical(client, ref.read(activeConnectionProvider).value?.client);
  }

  void _bindingChanged() {
    if (widget.phone != null) return;
    final host = ref.read(activeHostProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    if (host == _bindingHost && identical(client, _client)) return;
    setState(() {
      _bindingHost = host;
      _client = client;
      _bindingEpoch++;
      _list = null;
      _load = _Load.loading;
      _busy = false;
    });
    unawaited(_read());
  }

  Future<void> _read() async {
    if (!mounted) return;
    final owner = _currentRoom();
    final serial = ++_readSerial;
    bool current() => serial == _readSerial && owner();
    final keeper = _keeper;
    if (!current()) return;
    if (keeper == null) {
      setState(() {
        _list = null;
        _load = _Load.failed;
      });
      return;
    }
    try {
      final snapshot = await keeper.snapshot();
      if (!current()) return;
      if (snapshot == null || !snapshot.memories) {
        setState(() {
          _list = null;
          _load = _Load.unsupported;
        });
        return;
      }
      final list = await keeper.memories();
      if (!current()) return;
      setState(() {
        _list = list;
        _load = _Load.ready;
      });
    } on Object {
      if (!current()) return;
      setState(() {
        _list = null;
        _load = _Load.failed;
      });
    }
  }

  /// One write, then the list as it is now kept.
  Future<void> _write(Future<int> Function(CompanionKeeper keeper, CompanionMemories list) write) async {
    if (!mounted) return;
    final current = _currentRoom();
    final keeper = _keeper;
    final list = _list;
    if (!current() || keeper == null || list == null || _load != _Load.ready || _busy) return;
    final l10n = context.l10n;
    setState(() => _busy = true);
    try {
      await write(keeper, list);
      if (!current()) return;
      await _read();
    } on DshRemoteException catch (error) {
      if (!mounted || !current()) return;
      showBriefNotice(
        context,
        error.code.endsWith('conflict') || error.code.endsWith('store-changed')
            ? l10n.companionMemoryConflict
            : error.code.endsWith('limit-reached')
            ? l10n.companionMemoryFull
            : l10n.companionMemorySaveFailed,
      );
      await _read();
    } on Object {
      if (!mounted || !current()) return;
      showBriefNotice(context, l10n.companionMemorySaveFailed);
      // The write may have landed before the reply was lost; show what is kept.
      await _read();
    } finally {
      if (current()) setState(() => _busy = false);
    }
  }

  Future<void> _edit([CompanionMemory? memory]) async {
    if (!mounted) return;
    final current = _currentRoom();
    if (!current()) return;
    final l10n = context.l10n;
    var input = memory?.text ?? '';
    String? tooLong;
    final text = await showAppDialog<String>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, setDialog) => AlertDialog(
          title: Text(memory == null ? l10n.companionMemoryAdd : l10n.companionMemoryEdit),
          content: TextFormField(
            initialValue: input,
            onChanged: (value) {
              input = value;
              if (tooLong != null) setDialog(() => tooLong = null);
            },
            autofocus: true,
            minLines: 2,
            maxLines: 5,
            maxLength: _maxLength,
            decoration: InputDecoration(hintText: l10n.companionMemoryHint, errorText: tooLong),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog), child: Text(dialog.l10n.commonCancel)),
            FilledButton(
              onPressed: () {
                final value = input.trim();
                // The field counts what shows as one character, the Host code points (👍🏽 is
                // two): over the Host's limit, the text stays here to be cut.
                if (value.runes.length > _maxLength) {
                  setDialog(() => tooLong = dialog.l10n.engineFieldMaxCharacters(_maxLength));
                } else {
                  Navigator.pop(dialog, value);
                }
              },
              child: Text(dialog.l10n.companionMemorySave),
            ),
          ],
        ),
      ),
    );
    if (!current() || text == null || text.isEmpty || text == memory?.text) return;
    final next = CompanionMemory(
      id: memory?.id ?? companionMemoryId(),
      text: text,
      kind: memory?.kind ?? 'fact',
      keywords: memory?.keywords ?? const [],
      pinned: memory?.pinned ?? false,
      source: memory?.source ?? const CompanionMemorySource(),
      expiresAt: memory?.expiresAt,
    );
    await _write((keeper, list) => keeper.saveMemory(list.storeId, list.revision, next));
  }

  Future<void> _delete(CompanionMemory memory) async {
    if (!mounted) return;
    final current = _currentRoom();
    if (!current()) return;
    final l10n = context.l10n;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.companionMemoryForgetTitle),
        content: Text(memory.text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(dialog.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(dialog.l10n.companionMemoryForget),
          ),
        ],
      ),
    );
    if (!current() || ok != true) return;
    await _write((keeper, list) => keeper.deleteMemory(list.storeId, list.revision, memory.id));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(activeHostProvider, (_, _) => _bindingChanged());
    ref.listen(activeConnectionProvider.select((value) => value.value?.client), (_, _) => _bindingChanged());
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final host = ref.watch(activeHostProvider);
    final hostName = widget.phone != null
        ? l10n.commonThisPhone
        : ref.watch(hostNameProvider(host)) ?? (host.isLocal ? l10n.commonThisPhone : l10n.commonRemoteHost);
    final list = _list;
    final Widget body;
    switch (_load) {
      case _Load.loading:
        body = const Padding(
          padding: EdgeInsets.only(top: 64),
          child: Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.2))),
        );
      case _Load.unsupported:
        body = EmptyView(
          icon: AppIcons.unsupported,
          title: l10n.companionMemoryUnsupported,
          message: l10n.companionMemoryUnsupportedHint,
        );
      case _Load.failed:
        body = EmptyView(
          icon: AppIcons.offline,
          title: l10n.companionMemoryLoadFailed,
          onAction: _read,
          actionLabel: l10n.companionMemoryRetry,
        );
      case _Load.ready when list!.memories.isEmpty:
        body = EmptyView(
          icon: AppIcons.bookmark,
          title: l10n.companionMemoryEmpty,
          message: l10n.companionMemoryEmptyHint,
          onAction: _busy ? null : _edit,
          actionLabel: l10n.companionMemoryAdd,
        );
      case _Load.ready:
        body = SheetGroup(
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          children: [
            for (final memory in list!.memories)
              SettingsTile(
                icon: memory.pinned ? AppIcons.pinActive : AppIcons.bookmark,
                tinted: false,
                title: memory.text,
                onTap: _busy ? null : () => _edit(memory),
                trailing: IconButton(
                  tooltip: l10n.companionMemoryForget,
                  icon: const Icon(AppIcons.delete, size: 20),
                  onPressed: _busy ? null : () => _delete(memory),
                ),
              ),
          ],
        );
    }
    return AppPage(
      title: l10n.companionMemoryTitle,
      subtitle: Text(
        l10n.companionMemoryScope(hostName),
        style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
      ),
      actions: [
        if (_load == _Load.ready)
          IconButton(tooltip: l10n.companionMemoryAdd, icon: const Icon(AppIcons.add), onPressed: _busy ? null : _edit),
      ],
      slivers: [SliverToBoxAdapter(child: body)],
    );
  }
}
