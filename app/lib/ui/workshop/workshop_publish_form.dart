// The editing half of 投稿: pick what to send, fill in what the workshop
// shows about it, then look at what was packed and tick the rights box.
//
// What the person types stays on this page until 「下一步」; only then is it
// handed to workshopPublishProvider, checked with the state layer's own
// rules and packed. A change the state layer refuses is never drawn as if it
// had been accepted, and nothing is sent to the workshop from this file
// except through the controller's submit().

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../l10n/l10n.dart';
import '../../state/attachments.dart' show formatBytes;
import '../../state/workshop_account_state.dart';
import '../../state/workshop_auth_state.dart';
import '../../state/workshop_publication.dart';
import '../../state/workshop_publish_sources.dart';
import '../../state/workshop_publish_state.dart';
import '../../workshop/workshop_models.dart';
import '../../workshop/workshop_repository.dart' show workshopLocalError;
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/capsule_chip.dart';
import '../common/discard_guard.dart';
import '../common/empty_view.dart';
import '../common/list_page_row.dart';
import '../plugins/plugin_detail_sheet.dart' show PluginHero, PluginStats;
import '../plugins/plugin_widgets.dart' show PluginAvatar, PluginBadge;
import '../providers/provider_widgets.dart' show FormBottomBar, FormFieldBlock, FormFieldGroup, FormSmallButton;
import '../settings/settings_widgets.dart' show SettingsSection;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'workshop_publish_preview.dart';
import 'workshop_publish_text.dart';
import 'workshop_text.dart';
import 'workshop_widgets.dart';

/// The page's frame at every step: the title, one column, and the step's
/// primary button (when it has one) pinned above the keyboard.
class WorkshopPublishFrame extends StatelessWidget {
  const WorkshopPublishFrame({super.key, required this.children, this.action});

  final List<Widget> children;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      AppPage.list(
        title: context.l10n.workshopPublishTitle,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [...children, if (action != null) const SizedBox(height: FormBottomBar.height)],
          ),
        ],
      ),
      if (action case final action?)
        Positioned(
          left: 0,
          right: 0,
          bottom: MediaQuery.viewInsetsOf(context).bottom,
          child: FormBottomBar(child: action),
        ),
    ],
  );
}

/// The label of a busy primary button: a small ring and what is going on.
class WorkshopPublishBusyLabel extends StatelessWidget {
  const WorkshopPublishBusyLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox.square(
        dimension: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: DshColors.of(context).textDisabled),
      ),
      const SizedBox(width: 10),
      Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis)),
    ],
  );
}

/// Why this account cannot start a submission of [kind] right now, as a
/// stable code; null when it can.
String? workshopPublishBlock(WorkshopAccessState access, String kind) {
  if (access.canSubmit(kind)) return null;
  if (!access.uploadsEnabled) return 'workshop_upload_disabled';
  if (!(access.capabilities?.kinds.contains(kind) ?? false)) return 'workshop_unsupported_kind';
  if (kind == 'companion' && !access.companionEnabled) return 'workshop_companion_disabled';
  return 'workshop_account_auth_required';
}

/// The name a source goes by on this page.
String workshopSourceName(L10n l10n, WorkshopPublishSource source) {
  if (source.kind == 'companion' && !source.fromFile) return l10n.workshopPublishCompanionCurrent;
  final name = source.name?.trim() ?? '';
  return name.isEmpty ? (source.fromFile ? l10n.workshopPublishFromFile : source.localId) : name;
}

/// What on this phone can be sent in: the person's own pixel pets and the
/// companion they have now. A source the workshop will not take is listed
/// with the reason instead of being left out.
class WorkshopPublishSourceList extends ConsumerWidget {
  const WorkshopPublishSourceList({super.key, required this.onPick});

  final ValueChanged<WorkshopPublishSource> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final sources = ref.watch(workshopPublishSourcesProvider);
    final access = ref.watch(workshopAccessProvider);
    void reload() => unawaited(ref.read(workshopPublishSourcesProvider.notifier).refresh());

    if (sources.loading && sources.values.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 48, bottom: 24),
        child: Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    final issues = sources.issues;
    final notes = [
      if (issues.containsKey('all'))
        WorkshopNote(l10n.workshopPublishSourcesIssue, actionLabel: l10n.commonRetry, onAction: reload),
      if (issues.containsKey('pet'))
        WorkshopNote(l10n.workshopPublishPetsIssue, actionLabel: l10n.commonRetry, onAction: reload),
      if (issues['companion'] case final issue?)
        if (issue.code == 'workshop_companion_unavailable')
          WorkshopNote(l10n.workshopPublishNoCompanion)
        else
          WorkshopNote(l10n.workshopPublishCompanionIssue, actionLabel: l10n.commonRetry, onAction: reload),
    ];
    if (sources.values.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 12),
        child: Column(
          children: [
            EmptyView(
              icon: AppIcons.workshop,
              title: l10n.workshopPublishSourcesEmptyTitle,
              message: l10n.workshopPublishSourcesEmptyMessage,
            ),
            const SizedBox(height: 16),
            ListPageCard(children: [_FileRow(onPick: onPick)]),
            // "No companion here" is what the empty state already says; a
            // companion that could not be read is a reason worth showing.
            if (issues.containsKey('all') ||
                issues.containsKey('pet') ||
                (issues['companion'] != null && issues['companion']!.code != 'workshop_companion_unavailable')) ...[
              const SizedBox(height: 20),
              ...notes,
            ],
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListPageCard(
          children: [
            for (final source in sources.values)
              _SourceRow(
                source: source,
                block: workshopPublishBlock(access, source.kind),
                onTap: () => onPick(source),
              ),
            _FileRow(onPick: onPick),
          ],
        ),
        if (notes.isNotEmpty) ...[const SizedBox(height: 12), ...notes],
      ],
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.source, required this.block, required this.onTap});

  final WorkshopPublishSource source;
  final String? block;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final name = workshopSourceName(l10n, source);
    final row = ListPageRow(
      leading: PluginAvatar(name: '${source.kind}/${source.localId}', title: name),
      leadingWidth: 40,
      title: name,
      subtitle: block == null ? workshopKindText(l10n, source.kind) : workshopErrorLine(l10n, block!),
      subtitleMaxLines: 2,
      onTap: block == null ? onTap : null,
    );
    return block == null ? row : Opacity(opacity: 0.56, child: row);
  }
}

/// 「从文件选择」: a pet or companion zip that is not on this phone. It goes
/// through the same import as 导入 first, so a file of the wrong shape is
/// turned away here with the import's reason; what is in use stays as it is.
class _FileRow extends ConsumerStatefulWidget {
  const _FileRow({required this.onPick});

  final ValueChanged<WorkshopPublishSource> onPick;

  @override
  ConsumerState<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends ConsumerState<_FileRow> {
  bool _busy = false;

  Future<void> _pick() async {
    final stage = ref.read(workshopFileStagerProvider);
    final l10n = context.l10n;
    final picked = await FilePicker.pickFile();
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    File? copy;
    try {
      // Picks may be content URIs: bring it somewhere the unzipper can seek.
      copy = File('${(await getTemporaryDirectory()).path}/workshop-pick-${DateTime.now().microsecondsSinceEpoch}.zip');
      final sink = copy.openWrite();
      try {
        await sink.addStream(picked.readAsByteStream());
      } finally {
        await sink.close();
      }
      final source = await stage(copy);
      if (mounted) widget.onPick(source);
    } on Object catch (error) {
      if (mounted) showBriefNotice(context, workshopErrorLine(l10n, workshopLocalError(error).code));
    } finally {
      try { await copy?.delete(); } on Object { /* A cache file. */ }
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListPageRow(
      icon: AppIcons.files,
      title: l10n.workshopPublishFromFile,
      subtitle: l10n.workshopPublishFromFileHint,
      subtitleMaxLines: 2,
      trailing: _busy ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : null,
      onTap: _busy ? null : () => unawaited(_pick()),
    );
  }
}

/// Lets the person pick another source from a sheet. Null when they closed it.
Future<WorkshopPublishSource?> showWorkshopPublishSources(BuildContext context) => showAppSheet<WorkshopPublishSource>(
  context,
  isScrollControlled: true,
  builder: (sheet) => SafeArea(
    top: false,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(sheet.l10n.workshopPublishChooseTitle),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 12),
            child: WorkshopPublishSourceList(onPick: (source) => Navigator.of(sheet).pop(source)),
          ),
        ),
      ],
    ),
  ),
);

/// The metadata form for one source. [seed] fills the fields when the form
/// opens; after that the fields are the page's draft, and the state layer
/// hears of them at 「下一步」.
class WorkshopPublishForm extends ConsumerStatefulWidget {
  const WorkshopPublishForm({
    super.key,
    required this.source,
    required this.seed,
    required this.onChangeSource,
    required this.onNext,
    required this.onCover,
    this.cover,
    this.notes = const [],
  });

  final WorkshopPublishSource source;
  final WorkshopPublicationInput seed;

  /// The page's copy of the companion cover in [source], for its thumbnail.
  final WorkshopCover? cover;

  /// Another cover was taken by the state layer, or none.
  final ValueChanged<WorkshopCover?> onCover;

  /// 「更换」: the page asks about unsaved edits and shows the sources.
  final VoidCallback onChangeSource;

  /// 「下一步」 was accepted: the page may show the packed result when ready.
  final VoidCallback onNext;

  /// Page-level lines above the form (a consent that could not be saved).
  final List<Widget> notes;

  @override
  ConsumerState<WorkshopPublishForm> createState() => _WorkshopPublishFormState();
}

class _WorkshopPublishFormState extends ConsumerState<WorkshopPublishForm> {
  late final _titleZh = TextEditingController(text: widget.seed.titleZh);
  late final _titleEn = TextEditingController(text: widget.seed.titleEn);
  late final _id = TextEditingController(text: widget.seed.id);
  late final _version = TextEditingController(text: widget.seed.version);
  late final _author = TextEditingController(text: widget.seed.author);
  late final _source = TextEditingController(text: widget.seed.source);
  late final _description = TextEditingController(text: widget.seed.description);
  late final _tags = TextEditingController(text: workshopTagsLine(widget.seed.tags));
  // A licence the workshop does not offer is not kept behind the chips.
  late final _license = ValueNotifier(_offered().contains(widget.seed.license) ? widget.seed.license : '');
  late final _minApp = widget.seed.minApp;
  late final _edits = Listenable.merge([
    _titleZh,
    _titleEn,
    _id,
    _version,
    _author,
    _source,
    _description,
    _tags,
    _license,
  ]);
  final _fieldKeys = {for (final field in PublishField.drawn) field: GlobalKey()};

  /// Field → stable code, from the last 「下一步」. Editing a field clears its own.
  Map<String, String> _errors = const {};

  @override
  void dispose() {
    for (final controller in [_titleZh, _titleEn, _id, _version, _author, _source, _description, _tags]) {
      controller.dispose();
    }
    _license.dispose();
    super.dispose();
  }

  /// The licences to choose from: the app's list, narrowed to what this
  /// workshop says it takes.
  List<String> _offered() {
    final allowed = ref.read(workshopAccessProvider).capabilities?.licenses ?? const <String>{};
    return [
      for (final license in workshopLicenses)
        if (allowed.contains(license)) license,
    ];
  }

  static final _lineBreaks = RegExp(r'[\u0000-\u001f]');

  /// What the fields say now. The rights tick is not part of the form: it is
  /// given on the next step, for the packed result.
  WorkshopPublicationInput _draft() => _typed().withDefaults(
    login: ref.read(workshopAccountProvider).login,
    fallbackId: _fallbackId,
  );

  /// An id for a work with no English name to make one from; kept for this
  /// form, so the draft does not change under the person.
  late final _fallbackId = '${widget.source.kind}-${math.Random().nextInt(1 << 24).toRadixString(16).padLeft(6, '0')}';

  WorkshopPublicationInput _typed() => WorkshopPublicationInput(
    id: _id.text,
    version: _version.text,
    minApp: _minApp,
    titleZh: _titleZh.text,
    titleEn: _titleEn.text,
    author: _author.text,
    license: _license.value,
    source: _source.text,
    description: _description.text,
    tags: workshopTagsOf(_tags.text),
  );

  bool _dirty() => !workshopSameDeclaration(
    _draft(),
    ref.read(workshopPublishProvider).input.withDefaults(login: ref.read(workshopAccountProvider).login, fallbackId: _fallbackId),
  );

  void _edited(String field) {
    if (_errors.containsKey(field)) setState(() => _errors = {..._errors}..remove(field));
  }

  void _showErrors(Map<String, String> errors) {
    setState(() => _errors = errors);
    final first = PublishField.drawn.where(errors.containsKey).firstOrNull;
    final target = first == null ? null : _fieldKeys[first]?.currentContext;
    if (target == null) return;
    // Far enough down that the field's label clears the page's top bar.
    unawaited(
      Scrollable.ensureVisible(target, alignment: 0.16, duration: AppMotion.of(context, AppMotion.standard)),
    );
  }

  Future<void> _next() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final draft = _draft();
    // The state layer's own rules, before anything is packed or sent.
    final errors = draft.errors(includeRights: false);
    if (errors.isNotEmpty) {
      _showErrors(errors);
      return;
    }
    final l10n = context.l10n;
    final controller = ref.read(workshopPublishProvider.notifier);
    if (!workshopSameDeclaration(draft, ref.read(workshopPublishProvider).input) && !controller.setInput(draft)) {
      // Not accepted: the fields stay as typed, and nothing is packed.
      final refusal = ref.read(workshopPublishProvider).error;
      showBriefNotice(context, refusal == null ? l10n.workshopErrorBusy : workshopPublishErrorText(l10n, refusal));
      return;
    }
    setState(() => _errors = const {});
    widget.onNext();
    final accepted = ref.read(workshopPublishProvider);
    if (accepted.preparedMetadata != null && accepted.phase == WorkshopPublishPhase.ready) return;
    final before = accepted.error;
    await ref.read(workshopPublishProvider.notifier).prepare();
    if (!mounted) return;
    final after = ref.read(workshopPublishProvider);
    if (after.fieldErrors.isNotEmpty) _showErrors(after.fieldErrors);
    workshopPublishNoticeDeclined(context, after, before);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final publish = ref.watch(workshopPublishProvider);
    final access = ref.watch(workshopAccessProvider);
    final block = workshopPublishBlock(access, widget.source.kind);
    final busy = publish.working;
    final licenses = _offered();
    final failure = workshopPublishFailure(publish);
    String? error(String field) => workshopFieldErrorText(l10n, _errors[field]);
    InputDecoration decoration(String field, {String? hint}) =>
        InputDecoration(hintText: hint, error: _errors.containsKey(field) ? const SizedBox.shrink() : null);
    final name = workshopSourceName(l10n, widget.source);

    return DiscardGuard(
      listenable: _edits,
      isDirty: _dirty,
      child: WorkshopPublishFrame(
        action: FilledButton(
          onPressed: busy || block != null ? null : () => unawaited(_next()),
          child: publish.phase == WorkshopPublishPhase.preparing && publish.busy
              ? WorkshopPublishBusyLabel(l10n.workshopPublishPreparing)
              : Text(l10n.workshopPublishNext),
        ),
        children: [
          ...widget.notes,
          if (block != null) WorkshopNote(workshopErrorLine(l10n, block), tone: WorkshopNoteTone.warning),
          SettingsSection(
            title: l10n.workshopPublishSectionSource,
            children: [
              ListPageRow(
                leading: PluginAvatar(name: '${widget.source.kind}/${widget.source.localId}', title: name),
                leadingWidth: 40,
                title: name,
                subtitle: workshopKindText(l10n, widget.source.kind),
                trailing: FormSmallButton(
                  label: l10n.workshopPublishChange,
                  onPressed: busy ? null : widget.onChangeSource,
                ),
              ),
            ],
          ),
          IgnorePointer(
            ignoring: busy,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Part of what is sent, so it sits with the source. Changing
                // it leaves the fields below as typed.
                WorkshopPublishPreviewGroup(
                  source: widget.source,
                  cover: widget.cover,
                  onCover: widget.onCover,
                  enabled: !busy,
                ),
                SettingsSection(
                  title: l10n.workshopPublishSectionNames,
                  children: [
                    FormFieldGroup(
                      children: [
                        FormFieldBlock(
                          key: _fieldKeys[PublishField.titleZh],
                          label: l10n.workshopPublishTitleZh,
                          error: error(PublishField.titleZh),
                          child: TextField(
                            key: const ValueKey('workshop-publish-title-zh'),
                            controller: _titleZh,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) => _edited(PublishField.titleZh),
                            decoration: decoration(PublishField.titleZh),
                          ),
                        ),
                        FormFieldBlock(
                          key: _fieldKeys[PublishField.titleEn],
                          label: l10n.workshopPublishTitleEn,
                          error: error(PublishField.titleEn),
                          helper: l10n.workshopPublishTitleEnHelper,
                          child: TextField(
                            key: const ValueKey('workshop-publish-title-en'),
                            controller: _titleEn,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) => _edited(PublishField.titleEn),
                            decoration: decoration(PublishField.titleEn),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                SettingsSection(
                  title: l10n.workshopPublishSectionInfo,
                  children: [
                    FormFieldGroup(
                      children: [
                        FormFieldBlock(
                          key: _fieldKeys[PublishField.id],
                          label: l10n.workshopPublishId,
                          error: error(PublishField.id),
                          helper: l10n.workshopPublishIdHelper,
                          child: TextField(
                            key: const ValueKey('workshop-publish-id'),
                            controller: _id,
                            autocorrect: false,
                            textCapitalization: TextCapitalization.none,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) => _edited(PublishField.id),
                            decoration: decoration(PublishField.id, hint: 'my-pet'),
                          ),
                        ),
                        FormFieldBlock(
                          key: _fieldKeys[PublishField.version],
                          label: l10n.commonVersion,
                          error: error(PublishField.version),
                          child: TextField(
                            key: const ValueKey('workshop-publish-version'),
                            controller: _version,
                            autocorrect: false,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) => _edited(PublishField.version),
                            decoration: decoration(PublishField.version, hint: '1.0.0'),
                          ),
                        ),
                        FormFieldBlock(
                          key: _fieldKeys[PublishField.author],
                          label: l10n.workshopPublishAuthor,
                          error: error(PublishField.author),
                          helper: l10n.workshopPublishAuthorHelper,
                          child: TextField(
                            key: const ValueKey('workshop-publish-author'),
                            controller: _author,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) => _edited(PublishField.author),
                            decoration: decoration(PublishField.author),
                          ),
                        ),
                        FormFieldBlock(
                          key: _fieldKeys[PublishField.license],
                          label: l10n.workshopStatLicense,
                          error: error(PublishField.license),
                          helper: l10n.workshopPublishLicenseHelper,
                          child: ValueListenableBuilder<String>(
                            valueListenable: _license,
                            builder: (context, selected, _) => Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final license in licenses)
                                  CapsuleChoiceChip(
                                    label: workshopLicenseText(l10n, license),
                                    selected: selected == license,
                                    // Tapped again: none, which publishes as 作者授权.
                                    onSelected: () {
                                      _license.value = selected == license ? '' : license;
                                      _edited(PublishField.license);
                                    },
                                  ),
                              ],
                            ),
                          ),
                        ),
                        FormFieldBlock(
                          key: _fieldKeys[PublishField.source],
                          label: l10n.workshopPublishSourceLink,
                          error: error(PublishField.source),
                          helper: l10n.workshopPublishSourceHelper,
                          child: TextField(
                            key: const ValueKey('workshop-publish-source'),
                            controller: _source,
                            autocorrect: false,
                            keyboardType: TextInputType.url,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) => _edited(PublishField.source),
                            decoration: decoration(PublishField.source, hint: 'https://'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                SettingsSection(
                  title: l10n.workshopPublishSectionAbout,
                  children: [
                    FormFieldGroup(
                      children: [
                        FormFieldBlock(
                          key: _fieldKeys[PublishField.description],
                          label: l10n.workshopAbout,
                          error: error(PublishField.description),
                          child: TextField(
                            key: const ValueKey('workshop-publish-description'),
                            controller: _description,
                            minLines: 3,
                            maxLines: 6,
                            // One paragraph: the workshop takes no line breaks,
                            // so Enter ends the field and a pasted break
                            // becomes a space.
                            keyboardType: TextInputType.text,
                            textInputAction: TextInputAction.done,
                            inputFormatters: [FilteringTextInputFormatter.deny(_lineBreaks, replacementString: ' ')],
                            onChanged: (_) => _edited(PublishField.description),
                            decoration: decoration(PublishField.description),
                          ),
                        ),
                        FormFieldBlock(
                          key: _fieldKeys[PublishField.tags],
                          label: l10n.workshopPublishTags,
                          error: error(PublishField.tags),
                          helper: l10n.workshopPublishTagsHelper,
                          child: TextField(
                            key: const ValueKey('workshop-publish-tags'),
                            controller: _tags,
                            textInputAction: TextInputAction.done,
                            onChanged: (_) => _edited(PublishField.tags),
                            decoration: decoration(PublishField.tags),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (failure != null) WorkshopNote(workshopPublishErrorText(l10n, failure), tone: WorkshopNoteTone.danger),
          // Files of an earlier try that could not be cleared stop the next
          // pack; say so here, with the way to clear them.
          if (publish.cleanupError != null)
            WorkshopNote(
              l10n.workshopPublishLeftovers,
              tone: WorkshopNoteTone.warning,
              actionLabel: l10n.commonRetry,
              onAction: publish.working
                  ? null
                  : () => unawaited(ref.read(workshopPublishProvider.notifier).retryCleanup()),
            ),
        ],
      ),
    );
  }
}

/// Says once, in a notice, that the controller did not start a command
/// ([workshopPublishDeclined]). [before] is the error that was already there.
void workshopPublishNoticeDeclined(BuildContext context, WorkshopPublishState after, WorkshopException? before) {
  final error = after.error;
  if (error == null || identical(error, before) || !workshopPublishDeclined(error)) return;
  showBriefNotice(context, workshopPublishErrorText(context.l10n, error));
}

/// Flips the rights tick in the state layer. A refusal (something is still
/// running) leaves the tick as the state layer has it and says so.
void workshopPublishTickRights(BuildContext context, WidgetRef ref) {
  final input = ref.read(workshopPublishProvider).input;
  final accepted = ref
      .read(workshopPublishProvider.notifier)
      .setInput(input.copyWith(rightsConfirmed: !input.rightsConfirmed));
  if (!accepted) showBriefNotice(context, context.l10n.workshopErrorBusy);
}

/// The rights tick: 「投稿」 is only sent with it, and only the person can
/// give it. [error] replaces the line under it.
class WorkshopPublishRights extends StatelessWidget {
  const WorkshopPublishRights({super.key, required this.ticked, required this.onTap, this.error, this.note});

  final bool ticked;
  final VoidCallback? onTap;
  final String? error;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final line = error ?? note;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListPageCard(
          children: [
            Semantics(
              checked: ticked,
              child: InkWell(
                key: const ValueKey('workshop-publish-rights'),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(ListPageRow.horizontal, 14, ListPageRow.horizontal, 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        ticked ? AppIcons.checkboxOn : AppIcons.checkboxOff,
                        size: 22,
                        color: ticked ? theme.colorScheme.primary : colors.textTertiary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          l10n.workshopPublishRights,
                          style: theme.textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        if (line != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Semantics(
              liveRegion: error != null,
              child: Text(
                line,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: error != null ? colors.danger : colors.textTertiary,
                  height: 1.5,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// What was packed, as the workshop will show it, and the rights tick that
/// 「投稿」 needs. Everything here is read from the state layer's prepared
/// result, not from the form.
class WorkshopPublishReview extends ConsumerWidget {
  const WorkshopPublishReview({
    super.key,
    required this.onEdit,
    required this.onSubmit,
    this.cover,
    this.notes = const [],
  });

  /// 「修改资料」: back to the form.
  final VoidCallback onEdit;
  final VoidCallback onSubmit;

  /// The page's copy of the companion cover that was packed, when it has one.
  final WorkshopCover? cover;
  final List<Widget> notes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final publish = ref.watch(workshopPublishProvider);
    final access = ref.watch(workshopAccessProvider);
    final meta = publish.preparedMetadata!;
    final block = workshopPublishBlock(access, meta.kind);
    final busy = publish.working;
    final ticked = publish.input.rightsConfirmed;
    final rightsError = workshopFieldErrorText(l10n, publish.fieldErrors[PublishField.rights]);
    final failure = workshopPublishFailure(publish);
    final description = meta.description.trim();
    void tick() => workshopPublishTickRights(context, ref);

    return WorkshopPublishFrame(
      action: FilledButton(
        onPressed: busy || block != null ? null : onSubmit,
        child: Text(l10n.workshopPublishSubmit),
      ),
      children: [
        ...notes,
        if (block != null) WorkshopNote(workshopErrorLine(l10n, block), tone: WorkshopNoteTone.warning),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: PluginHero(
            avatar: WorkshopAvatar(meta, size: 64),
            title: workshopTitleOf(meta, Localizations.localeOf(context).languageCode),
            subtitle: l10n.workshopByAuthor(meta.author),
            badges: [PluginBadge(workshopKindText(l10n, meta.kind))],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: PluginStats([
            (meta.version, l10n.workshopStatVersion),
            (formatBytes(meta.size), l10n.workshopStatSize),
            (workshopLicenseText(l10n, meta.license), l10n.workshopStatLicense),
          ]),
        ),
        ListPageCard(
          children: [
            ListPageRow(title: l10n.workshopPublishId, value: meta.id),
            ListPageRow(title: l10n.workshopSource, value: Uri.tryParse(meta.source)?.host ?? ''),
            ListPageRow(
              title: l10n.workshopPublishFiles,
              meta: '${publish.files.length}',
              chevron: true,
              onTap: () => unawaited(_showFiles(context, publish.files)),
            ),
            // The one thing here that is public before anyone installs it.
            WorkshopPublishPreviewRow(source: meta.previewSource, cover: cover),
          ],
        ),
        if (description.isNotEmpty || meta.tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (description.isNotEmpty)
                  Text(
                    description,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.6),
                  ),
                if (description.isNotEmpty && meta.tags.isNotEmpty) const SizedBox(height: 12),
                if (meta.tags.isNotEmpty)
                  Wrap(spacing: 6, runSpacing: 6, children: [for (final tag in meta.tags) PluginBadge(tag)]),
              ],
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: TextButton(onPressed: busy ? null : onEdit, child: Text(l10n.workshopPublishEdit)),
          ),
        ),
        WorkshopPublishRights(
          ticked: ticked,
          onTap: busy ? null : tick,
          error: rightsError,
          note: l10n.workshopPublishReviewNote,
        ),
        if (failure != null) WorkshopNote(workshopPublishErrorText(l10n, failure), tone: WorkshopNoteTone.danger),
      ],
    );
  }
}

/// The archive's members, as the packer listed them.
Future<void> _showFiles(BuildContext context, List<String> files) => showAppSheet<void>(
  context,
  heightFactor: 0.6,
  builder: (sheet) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SheetHeader(sheet.l10n.workshopPublishFiles),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 16),
          itemCount: files.length,
          itemBuilder: (context, i) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(files[i], style: AppType.monoLabel(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
        ),
      ),
    ],
  ),
);
