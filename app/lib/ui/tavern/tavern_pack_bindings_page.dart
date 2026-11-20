// The packs one scope uses (STAGE3-APP-INTEGRATION §4, §6): global, a
// character or a chat. Changes gather here — add, turn off, order, pick a
// version, map its characters, remove — and 保存 adopts them in one batch
// against the snapshot they were made on. 预览 composes them without saving.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_packs.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_tool_turns.dart' show tavernNewId;
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/discard_guard.dart';
import '../common/empty_view.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'tavern_pack_preview_page.dart';
import 'tavern_pack_widgets.dart';
import 'tavern_widgets.dart' show kTavernSheetMargin, showTavernActions;

class TavernPackBindingsPage extends ConsumerStatefulWidget {
  const TavernPackBindingsPage({super.key, required this.scope, this.adding, this.characterId, this.chatId});

  final TavernPackScopeKey scope;

  /// A version to add on opening, ready to save.
  final TavernPackVersionRef? adding;

  /// The real context 预览 composes for; without a character there is none.
  final String? characterId;
  final String? chatId;

  static Route<void> route(
    TavernPackScopeKey scope, {
    TavernPackVersionRef? adding,
    String? characterId,
    String? chatId,
  }) => MaterialPageRoute<void>(
    builder: (_) => TavernPackBindingsPage(scope: scope, adding: adding, characterId: characterId, chatId: chatId),
  );

  @override
  ConsumerState<TavernPackBindingsPage> createState() => _TavernPackBindingsPageState();
}

/// One binding as edited here; [saved] is what the snapshot has (null for
/// one added here, whose [id] is its client key until saved).
class _Row {
  _Row.saved(TavernPackBinding this.saved)
    : id = saved.bindingId,
      packRef = saved.packRef,
      enabled = saved.enabled,
      removed = saved.removed,
      castImports = saved.castImports;

  _Row.added(this.packRef) : id = tavernNewId(), saved = null, enabled = true, removed = false, castImports = const {};

  final String id;
  final TavernPackBinding? saved;
  TavernPackVersionRef packRef;
  bool enabled;
  bool removed;
  bool reset = false;
  Map<String, TavernCastImportRef> castImports;
}

class _TavernPackBindingsPageState extends ConsumerState<TavernPackBindingsPage> {
  static final _never = Listenable.merge(const []);

  TavernPackScopeSnapshot? _snapshot;
  Object? _loadError;
  var _rows = <_Row>[];
  bool _busy = false;

  /// The save not answered yet goes again as the same operation; any new
  /// change makes it a new one.
  String? _operation;

  @override
  void initState() {
    super.initState();
    unawaited(_load(adding: widget.adding));
  }

  Future<void> _load({TavernPackVersionRef? adding}) async {
    try {
      final snapshot = await ref.read(tavernProvider).readGameplayBindings(tavernPackScopeTarget(widget.scope));
      if (!mounted) return;
      setState(() {
        _show(snapshot);
        if (adding != null) _rows.add(_Row.added(adding));
      });
    } on Object catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  void _show(TavernPackScopeSnapshot snapshot) {
    _snapshot = snapshot;
    _loadError = null;
    _operation = null;
    _rows = [
      for (final b in [...snapshot.bindings]..sort((a, b) => a.order.compareTo(b.order))) _Row.saved(b),
    ];
  }

  void _edit(VoidCallback change) => setState(() {
    change();
    _operation = null;
  });

  List<TavernPackBindingEdit> _edits() {
    final edits = <TavernPackBindingEdit>[];
    // The store's reorder lists every binding the batch has so far: before
    // any create, those are exactly the saved ones.
    final order = [
      for (final r in _rows)
        if (r.saved != null) r.id,
    ];
    final before = [
      for (final b in [..._snapshot!.bindings]..sort((a, b) => a.order.compareTo(b.order))) b.bindingId,
    ];
    if (!listEquals(order, before)) edits.add(TavernPackBindingEdit.reorder(bindingIds: order));
    for (final r in _rows) {
      final s = r.saved;
      if (s == null) {
        edits.add(
          TavernPackBindingEdit.create(
            clientKey: r.id,
            packRef: r.packRef,
            enabled: r.enabled,
            aliases: const {},
            castImports: r.castImports,
          ),
        );
        continue;
      }
      if (r.packRef.packVersion != s.packRef.packVersion) {
        edits.add(TavernPackBindingEdit.selectVersion(bindingId: r.id, packVersion: r.packRef.packVersion));
      }
      if (r.removed && !s.removed) {
        edits.add(TavernPackBindingEdit.remove(bindingId: r.id));
      } else if (r.enabled != s.enabled || r.removed != s.removed) {
        edits.add(TavernPackBindingEdit.setEnabled(bindingId: r.id, enabled: r.enabled));
      }
      if (r.reset) edits.add(TavernPackBindingEdit.resetOnce(bindingId: r.id));
      if (!mapEquals(r.castImports, s.castImports)) {
        edits.add(TavernPackBindingEdit.setCastImports(bindingId: r.id, imports: r.castImports));
      }
    }
    return edits;
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final edits = _edits();
    setState(() => _busy = true);
    try {
      final receipt = await ref
          .read(tavernProvider)
          .updateGameplayBindings(
            tavernPackScopeTarget(widget.scope),
            expected: _snapshot!.token,
            operationId: _operation ??= tavernNewId(),
            edits: edits,
          );
      if (mounted) {
        setState(() => _show(receipt.snapshot));
        showBriefNotice(context, l10n.tavernPackSaved);
      }
    } on TavernGameplayCommittedException<TavernPackBindingReceipt> catch (e) {
      if (mounted) {
        setState(() => _show(e.result.snapshot));
        showBriefNotice(context, l10n.tavernPackCommitted);
      }
    } on TavernGameplayException catch (e) {
      _operation = null;
      if (!mounted) return;
      if (e.code == 'revision_conflict') {
        // Changed elsewhere: what is there now, and the person decides again.
        await _load();
      }
      if (!mounted) return;
      if (e.code == 'timer_policy_conflict' || e.details.isNotEmpty) {
        unawaited(showTavernPackIssues(context, title: tavernPackErrorText(l10n, e), issues: [e.details]));
      } else {
        showBriefNotice(context, tavernPackErrorText(l10n, e));
      }
    } on Object catch (e) {
      if (mounted) showBriefNotice(context, l10n.tavernPackUnanswered(tavernPackErrorText(l10n, e)));
    }
    if (!mounted) return;
    ref
      ..invalidate(tavernPackScopeProvider(widget.scope))
      ..invalidate(tavernPacksProvider);
    setState(() => _busy = false);
  }

  Future<void> _add(List<TavernPackVersion> installed) {
    // The newest version of each pack still offered.
    final newest = <String, TavernPackVersion>{};
    for (final v in installed) {
      if (!v.removed) newest[v.ref.installedPackId] = v;
    }
    return showAppSheet<void>(
      context,
      builder: (sheet) => SafeArea(
        top: false,
        child: newest.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: EmptyView(icon: AppIcons.zip, title: context.l10n.tavernPacksEmpty, compact: true),
              )
            : SingleChildScrollView(
                child: SheetGroup(
                  margin: kTavernSheetMargin,
                  children: [
                    for (final v in newest.values)
                      SettingsTile(
                        key: ValueKey('tavern-pack-add-${v.ref.installedPackId}'),
                        icon: AppIcons.zip,
                        tinted: false,
                        title: tavernPackTitle(v),
                        value: Text(v.ref.packVersion),
                        chevron: false,
                        onTap: () {
                          Navigator.of(sheet).pop();
                          _edit(() => _rows.add(_Row.added(v.ref)));
                        },
                      ),
                  ],
                ),
              ),
      ),
    );
  }

  /// Moves a saved, live row past its live neighbour; removed rows keep
  /// their slots, added ones stay last until saved.
  void _move(_Row row, int step) {
    final live = [
      for (final r in _rows)
        if (r.saved != null && !r.removed) r,
    ];
    final at = live.indexOf(row) + step;
    if (at < 0 || at >= live.length) return;
    final i = _rows.indexOf(row);
    final j = _rows.indexOf(live[at]);
    _edit(() {
      _rows[i] = live[at];
      _rows[j] = row;
    });
  }

  Future<void> _rowActions(_Row row, List<TavernPackVersion> installed) {
    final l10n = context.l10n;
    final versions = [
      for (final v in installed)
        if (v.ref.installedPackId == row.packRef.installedPackId &&
            (!v.removed || tavernPackSameRef(v.ref, row.packRef)))
          v,
    ];
    final current = versions.where((v) => v.ref.packVersion == row.packRef.packVersion).firstOrNull;
    return showTavernActions(context, [
      if (versions.length > 1)
        (AppIcons.history, l10n.tavernPackPickVersion, () => unawaited(_pickVersion(row, versions))),
      if (row.saved != null && !row.removed) ...[
        (AppIcons.scrollToTop, l10n.tavernPackMoveUp, () => _move(row, -1)),
        (AppIcons.scrollToBottom, l10n.tavernPackMoveDown, () => _move(row, 1)),
      ],
      if (current != null && tavernPackCast(current).isNotEmpty)
        (AppIcons.profile, l10n.tavernPackCast, () => unawaited(_cast(row, current))),
      if (row.saved != null && !row.reset)
        (AppIcons.restart, l10n.tavernPackResetOnce, () => _edit(() => row.reset = true)),
      if (row.removed)
        (
          AppIcons.restart,
          l10n.tavernPackRestore,
          () => _edit(
            () => row
              ..removed = false
              ..enabled = true,
          ),
        )
      else
        (
          AppIcons.remove,
          l10n.tavernPackRemoveBinding,
          () => _edit(() {
            if (row.saved == null) {
              _rows.remove(row);
            } else {
              row
                ..removed = true
                ..enabled = false;
            }
          }),
        ),
    ]);
  }

  Future<void> _pickVersion(_Row row, List<TavernPackVersion> versions) => showAppSheet<void>(
    context,
    builder: (sheet) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: SheetGroup(
          margin: kTavernSheetMargin,
          children: [
            for (final v in versions.reversed)
              SettingsTile(
                key: ValueKey('tavern-pack-pick-${v.ref.packVersion}'),
                tinted: false,
                title: v.ref.packVersion,
                trailing: v.ref.packVersion == row.packRef.packVersion ? const Icon(AppIcons.selected, size: 20) : null,
                chevron: false,
                onTap: () {
                  Navigator.of(sheet).pop();
                  _edit(() => row.packRef = v.ref);
                },
              ),
          ],
        ),
      ),
    ),
  );

  /// The characters of this binding's version: each mapped to one imported
  /// from this pack, or imported now and mapped (saved with the rest).
  Future<void> _cast(_Row row, TavernPackVersion version) => showAppSheet<void>(
    context,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, setSheet) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: SheetGroup(
            margin: kTavernSheetMargin,
            title: context.l10n.tavernPackCastMapping,
            children: [
              for (final member in tavernPackCast(version))
                SettingsTile(
                  key: ValueKey('tavern-pack-map-${member.localId}'),
                  icon: AppIcons.profile,
                  tinted: false,
                  title: member.name,
                  value: Text(
                    row.castImports.containsKey(member.localId)
                        ? context.l10n.tavernPackCastMapped
                        : context.l10n.tavernPackCastImportAction,
                  ),
                  chevron: false,
                  onTap: () async {
                    if (row.castImports.containsKey(member.localId)) {
                      _edit(() => row.castImports = {...row.castImports}..remove(member.localId));
                    } else {
                      final mapping = await importTavernPackCast(context, ref, version.ref, member);
                      if (mapping == null || !mounted) return;
                      _edit(
                        () => row.castImports = {
                          ...row.castImports,
                          member.localId: TavernCastImportRef(
                            domainId: mapping.domainId,
                            operationId: mapping.operationId,
                          ),
                        },
                      );
                    }
                    if (sheet.mounted) setSheet(() {});
                  },
                ),
            ],
          ),
        ),
      ),
    ),
  );

  void _preview() {
    final scope = TavernPackScopePreview(
      scope: widget.scope.kind,
      targetId: widget.scope.targetId,
      bindings: [
        for (final r in _rows)
          if (!r.removed)
            TavernPackBindingPreview(
              bindingId: r.id,
              packRef: r.packRef,
              enabled: r.enabled,
              aliases: r.saved?.aliases ?? const {},
            ),
      ],
    );
    unawaited(
      Navigator.of(context).push(
        TavernPackPreviewPage.route(
          TavernGameplayContext(characterId: widget.characterId!, chatId: widget.chatId),
          proposed: [scope],
        ),
      ),
    );
  }

  String _title(L10n l10n) => switch (widget.scope.kind) {
    TavernGameplayScope.global => l10n.tavernPackScopeGlobal,
    TavernGameplayScope.character => l10n.tavernPackScopeCharacter,
    TavernGameplayScope.chat => l10n.tavernPackScopeChat,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final installed = ref.watch(tavernPacksProvider(true)).value ?? const <TavernPackVersion>[];
    final snapshot = _snapshot;
    final dirty = snapshot != null && _edits().isNotEmpty;
    Widget tile(_Row row) {
      final version = installed.where((v) => tavernPackSameRef(v.ref, row.packRef)).firstOrNull;
      final notes = [
        row.packRef.packVersion,
        if (row.saved == null) l10n.tavernPackUnsaved,
        if (version?.removed ?? false) l10n.tavernPackWithdrawnLabel,
        if (row.reset) l10n.tavernPackResetPending,
        if (row.castImports.isNotEmpty) l10n.tavernPackCastMappedCount(row.castImports.length),
      ];
      return SettingsTile(
        key: ValueKey('tavern-pack-binding-${row.id}'),
        icon: AppIcons.zip,
        tinted: false,
        title: version == null ? row.packRef.installedPackId : tavernPackTitle(version),
        subtitle: notes.join(' · '),
        trailing: row.removed
            ? null
            : Switch(
                key: ValueKey('tavern-pack-binding-on-${row.id}'),
                value: row.enabled,
                onChanged: _busy ? null : (value) => _edit(() => row.enabled = value),
              ),
        chevron: false,
        onTap: _busy ? null : () => unawaited(_rowActions(row, installed)),
      );
    }

    final live = [
      for (final r in _rows)
        if (!r.removed) r,
    ];
    final removed = [
      for (final r in _rows)
        if (r.removed) r,
    ];
    return DiscardGuard(
      listenable: _never,
      isDirty: () => dirty,
      child: AppPage.list(
        title: _title(l10n),
        subtitle: Text(l10n.tavernPackBindingsSubtitle),
        actions: [
          if (widget.characterId != null)
            GlassIconButton(
              key: const ValueKey('tavern-pack-preview'),
              icon: AppIcons.preview,
              tooltip: l10n.tavernPackPreview,
              onPressed: snapshot == null ? null : _preview,
            ),
          GlassIconButton(
            key: const ValueKey('tavern-pack-save'),
            icon: AppIcons.save,
            tooltip: l10n.commonSave,
            onPressed: dirty && !_busy ? () => unawaited(_save()) : null,
          ),
        ],
        children: [
          if (snapshot == null)
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: Center(
                child: _loadError == null ? const QuietSpinner() : Text(tavernPackErrorText(l10n, _loadError!)),
              ),
            )
          else ...[
            if (snapshot.issues.isNotEmpty)
              SettingsSection(
                key: const ValueKey('tavern-pack-scope-issues'),
                children: [for (final issue in snapshot.issues) TavernPackIssueText(issue)],
              ),
            SettingsSection(
              key: const ValueKey('tavern-pack-bindings'),
              footer: Text(l10n.tavernPackOrderNote),
              children: [
                for (final row in live) tile(row),
                SettingsTile(
                  key: const ValueKey('tavern-pack-add'),
                  icon: AppIcons.add,
                  tinted: false,
                  title: l10n.tavernPackAdd,
                  chevron: false,
                  onTap: _busy ? null : () => unawaited(_add(installed)),
                ),
              ],
            ),
            if (removed.isNotEmpty)
              SettingsSection(
                key: const ValueKey('tavern-pack-removed'),
                title: l10n.tavernPackRemovedBindings,
                children: [for (final row in removed) tile(row)],
              ),
          ],
        ],
      ),
    );
  }
}
