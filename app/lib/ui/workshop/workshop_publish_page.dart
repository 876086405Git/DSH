// 投稿: send one of your own pixel pets, or the companion you have now, to
// the workshop for review (docs/design/workshop-app.md「投稿与凭据」).
//
// A form page (docs/design/page-design.md §1 D) that is a different step
// depending on what the state layer says, in this order:
//
//   the workshop is not taking submissions → sign in with GitHub →
//   the credential disclosure → is there an unfinished submission? →
//   pick a source → fill in the form → look at what was packed, tick the
//   rights box → sending → the result
//
// Every step is drawn from workshopAccessProvider and workshopPublishProvider;
// the page keeps only the unsent form text, the picked cover's bytes (for
// its thumbnail) and which step the person chose to look at. An unfinished
// submission is always shown before a new one can start, and when a result
// is unknown the only thing offered is asking again about the same request:
// nothing here can send a second one in its place. When the phone's record
// of it cannot be used at all, the person may let go of that record
// (workshop_publish_recovery.dart); that is said to be local, and is never
// worded as cancelling.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/attachments.dart' show formatBytes;
import '../../state/workshop_auth_state.dart';
import '../../state/workshop_publication.dart';
import '../../state/workshop_publish_sources.dart';
import '../../state/workshop_publish_state.dart';
import '../../workshop/workshop_models.dart';
import '../../workshop/workshop_preview.dart';
import '../common/brief_notice.dart';
import '../common/discard_guard.dart';
import '../common/empty_view.dart';
import '../common/list_page_row.dart';
import '../settings/settings_widgets.dart' show SettingsSection;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'workshop_auto_cover.dart';
import 'workshop_disclosure.dart';
import 'workshop_publish_form.dart';
import 'workshop_publish_preview.dart';
import 'workshop_publish_recovery.dart';
import 'workshop_publish_text.dart';
import 'workshop_sign_in.dart';
import 'workshop_text.dart';
import 'workshop_widgets.dart';

/// The step on screen.
enum _Step {
  loading,
  unreachable,
  closed,
  signIn,
  disclosure,
  profile,
  checkFailed,
  sending,
  result,
  unfinished,
  sources,
  form,
  review,
}

class WorkshopPublishPage extends ConsumerStatefulWidget {
  const WorkshopPublishPage({super.key});

  @override
  ConsumerState<WorkshopPublishPage> createState() => _WorkshopPublishPageState();
}

class _WorkshopPublishPageState extends ConsumerState<WorkshopPublishPage> {
  /// The account session whose unfinished submission this page already asked
  /// about, so one session is asked once and a failure waits for 「重试」.
  Object? _restoreAsked;

  /// A finished submission that was already there when the page opened: the
  /// person came back to send something else, not to read it again.
  WorkshopSubmission? _seenResult;

  /// Looking at the form again after the pack was made (「修改资料」).
  bool _editing = false;

  /// A new form (and new text fields) for every source picked.
  int _formEpoch = 0;

  /// What the next form starts from instead of the source's own defaults:
  /// the details of a rejected or withdrawn submission being sent again.
  WorkshopPublicationInput? _seed;
  ({String kind, WorkshopPublicationInput input})? _carry;

  /// How many times this visit asked again about an unknown result.
  int _rechecks = 0;

  /// Drawn only while its input is the one the state layer has ([_coverOf]).
  WorkshopCover? _cover;
  bool _autoCoverPending = false;

  /// The let-go offer whose dialog was already shown, so one offer asks once.
  WorkshopPendingAbandonOffer? _letGoAsked;

  @override
  void initState() {
    super.initState();
    final publish = ref.read(workshopPublishProvider);
    // An offer left from an earlier visit is not asked about out of nowhere:
    // 「放下这条记录」 gets a fresh one.
    _letGoAsked = publish.abandonOffer;
    final status = publish.result?.status;
    if (publish.phase == WorkshopPublishPhase.complete &&
        !publish.hasPending &&
        !publish.working &&
        publish.preferenceError == null &&
        publish.cleanupError == null &&
        (status == WorkshopSubmissionStatus.pending || status == WorkshopSubmissionStatus.approved)) {
      _seenResult = publish.result;
    }
    _scheduleRestore();
  }

  bool _identified(WorkshopAccessState access) =>
      !access.loading &&
      access.error == null &&
      access.capabilities != null &&
      access.signedIn &&
      access.disclosureAccepted &&
      access.accountId != null;

  // Outside the provider's own notification: the check changes its state.
  void _scheduleRestore() => scheduleMicrotask(() {
    if (mounted) _restoreOnce();
  });

  /// Asks, once per account session, whether a submission was left
  /// unfinished. Read-only: nothing is created or uploaded by it.
  void _restoreOnce() {
    final publish = ref.read(workshopPublishProvider);
    if (!_identified(ref.read(workshopAccessProvider)) || publish.pendingChecked || publish.working) return;
    if (identical(_restoreAsked, publish.session)) return;
    _restoreAsked = publish.session;
    unawaited(ref.read(workshopPublishProvider.notifier).restorePending());
  }

  void _onPublishChanged(WorkshopPublishState? before, WorkshopPublishState now) {
    if (before != null && !identical(before.session, now.session)) {
      // Another account or workshop: nothing chosen for the old one carries over.
      setState(() {
        _seenResult = null;
        _editing = false;
        _seed = null;
        _carry = null;
        _rechecks = 0;
        _cover = null;
        _autoCoverPending = false;
        _formEpoch++;
      });
      _letGoAsked = null;
    }
    final offer = now.abandonOffer;
    if (offer != null && !identical(offer, _letGoAsked)) {
      _letGoAsked = offer;
      unawaited(_askLetGo(offer));
    }
    _scheduleRestore();
  }

  WorkshopCover? _coverOf(WorkshopPublishState publish) =>
      _cover != null && identical(publish.source?.preview, _cover!.input) ? _cover : null;

  _Step _stepOf(WorkshopAccessState access, WorkshopPublishState publish) {
    if (access.accountRestoring || access.loading && access.capabilities == null) return _Step.loading;
    final stale = access.error?.code == 'workshop_confirmation_stale';
    final reoffer = stale && access.disclosure != null && !access.disclosureAccepted;
    if (access.error != null && !reoffer) return _Step.unreachable;
    if (access.capabilities == null) return _Step.loading;
    final known = access.signedIn && access.disclosureAccepted && access.accountId != null;
    // With uploads off there is no reason to sign in or consent; an account
    // already through both may still have something unfinished to look at.
    if (!access.uploadsEnabled && !known) return _Step.closed;
    if (!access.signedIn) return _Step.signIn;
    if (!access.disclosureAccepted) return access.disclosure == null ? _Step.loading : _Step.disclosure;
    if (access.accountId == null) return _Step.profile;
    if (!publish.pendingChecked) {
      final asked = identical(_restoreAsked, publish.session);
      return publish.working || !asked || access.loading ? _Step.loading : _Step.checkFailed;
    }
    if (const {
      WorkshopPublishPhase.creating,
      WorkshopPublishPhase.uploading,
      WorkshopPublishPhase.awaitingResponse,
    }.contains(publish.phase)) {
      return _Step.sending;
    }
    final restart = publish.result != null && identical(publish.result, _seenResult);
    if (publish.result != null && !restart) return _Step.result;
    if (publish.hasPending) return _Step.unfinished;
    if (!access.uploadsEnabled) return _Step.closed;
    final source = publish.source;
    if (source == null || restart) return _Step.sources;
    if (publish.preparedMetadata != null && publish.phase == WorkshopPublishPhase.ready && !_editing) {
      return _Step.review;
    }
    return _Step.form;
  }

  void _leave() => unawaited(Navigator.of(context).maybePop());

  void _pick(WorkshopPublishSource source) {
    final l10n = context.l10n;
    if (!ref.read(workshopPublishProvider.notifier).selectSource(source)) {
      final refusal = ref.read(workshopPublishProvider).error;
      showBriefNotice(context, refusal == null ? l10n.workshopErrorBusy : workshopPublishErrorText(l10n, refusal));
      return;
    }
    final takesPreview = workshopTakesPreview(ref.read(workshopAccessProvider), source.kind);
    if (source.kind == 'pet' && takesPreview) {
      workshopPublishSetPreview(context, ref, const WorkshopPreviewInput.petIdle());
    }
    setState(() {
      _seed = _carry?.kind == source.kind ? _carry!.input : null;
      _carry = null;
      _seenResult = null;
      _editing = false;
      _cover = null;
      _autoCoverPending = takesPreview;
      _formEpoch++;
    });
  }

  void _finishAutoCover(int epoch, Uint8List? bytes) {
    if (!mounted || !_autoCoverPending || _formEpoch != epoch) return;
    final publish = ref.read(workshopPublishProvider);
    final source = publish.source;
    WorkshopCover? cover;
    if (bytes != null && source?.kind == 'pet') {
      // The Worker derives the actual upload from the pack, not this thumbnail.
      cover = (input: const WorkshopPreviewInput.petIdle(), bytes: bytes);
    } else if (bytes != null && source != null && source.preview == null && !publish.working &&
        workshopTakesPreview(ref.read(workshopAccessProvider), source.kind)) {
      try {
        final input = source.kind == 'theme'
            ? WorkshopPreviewInput.themePng(bytes)
            : WorkshopPreviewInput.companionPng(bytes);
        if (ref.read(workshopPublishProvider.notifier).setPreview(input)) cover = (input: input, bytes: bytes);
      } on WorkshopException {
        // A generated image can fail the same checks as a picked cover.
      }
    }
    setState(() {
      _autoCoverPending = false;
      if (cover != null) _cover = cover;
    });
  }

  Future<void> _changeSource() async {
    // Another source starts another form: what was typed here goes.
    if (!await DiscardGuard.confirmLeave(context) || !mounted) return;
    final source = await showWorkshopPublishSources(context);
    if (source != null && mounted) _pick(source);
  }

  Future<void> _submit() async {
    final before = ref.read(workshopPublishProvider).error;
    await ref.read(workshopPublishProvider.notifier).submit();
    if (mounted) workshopPublishNoticeDeclined(context, ref.read(workshopPublishProvider), before);
  }

  /// The same request again: an unfinished or unknown submission is never
  /// replaced by a new one from here.
  Future<void> _resume() async {
    final before = ref.read(workshopPublishProvider).error;
    if (before?.resultUnknown ?? false) setState(() => _rechecks++);
    await ref.read(workshopPublishProvider.notifier).retrySubmission();
    if (mounted) workshopPublishNoticeDeclined(context, ref.read(workshopPublishProvider), before);
  }

  /// Nothing of this submission has left the phone (the state layer knows it
  /// was refused before it was sent): let go of it and return to the form,
  /// with what was typed. Asks nothing of the workshop.
  Future<void> _editUnsent() async {
    await ref.read(workshopPublishProvider.notifier).discardUnsentSubmission();
    if (!mounted || ref.read(workshopPublishProvider).hasPending) return;
    setState(() {
      _seed = null;
      _editing = true;
      _formEpoch++;
    });
  }

  Future<void> _sendAgain() async {
    final before = ref.read(workshopPublishProvider);
    final kind = before.result?.metadata.kind;
    await ref.read(workshopPublishProvider.notifier).startNewSubmission();
    if (!mounted) return;
    final after = ref.read(workshopPublishProvider);
    workshopPublishNoticeDeclined(context, after, before.error);
    if (after.result != null) return;
    setState(() {
      // Picking a source resets the state layer's form; the details of the
      // one being sent again are kept here for the form that follows.
      _carry = kind == null ? null : (kind: kind, input: after.input);
      _seed = null;
      _editing = true;
      _formEpoch++;
    });
  }

  /// Only reads the phone's record; when it can be let go, the offer that
  /// appears is asked about in [_askLetGo].
  Future<void> _letGo() async {
    final before = ref.read(workshopPublishProvider).error;
    await ref.read(workshopPublishProvider.notifier).requestPendingAbandonment();
    if (mounted) workshopPublishNoticeDeclined(context, ref.read(workshopPublishProvider), before);
  }

  /// Asks about [offer] and, on 「放下记录」, hands the same object back. Only
  /// the phone's record goes: nothing is sent to the workshop, and nothing
  /// here says the submission was cancelled.
  Future<void> _askLetGo(WorkshopPendingAbandonOffer offer) async {
    final l10n = context.l10n;
    final before = ref.read(workshopPublishProvider);
    if (!await showWorkshopLetGoDialog(context, offer, resultKnown: before.result != null) || !mounted) return;
    await ref.read(workshopPublishProvider.notifier).confirmPendingAbandonment(offer);
    if (!mounted) return;
    final after = ref.read(workshopPublishProvider);
    if (after.recoveryError != null) return; // Said in place, beside the action.
    if (after.abandonOffer != null) {
      // Not started: something else was running.
      showBriefNotice(context, l10n.workshopErrorBusy);
      return;
    }
    showBriefNotice(context, l10n.workshopPublishLetGoDone);
    // A known result stays on screen. Otherwise the details are editable
    // again: in the form when the source is still chosen, and carried to
    // the next form when a record from an earlier visit had none.
    if (after.result != null) return;
    final kind = before.preparedMetadata?.kind;
    setState(() {
      _carry = after.source == null && kind != null ? (kind: kind, input: after.input) : null;
      _seed = null;
      _editing = true;
      _formEpoch++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    ref.listen(workshopAccessProvider, (_, _) => _scheduleRestore());
    ref.listen(workshopPublishProvider, _onPublishChanged);
    final access = ref.watch(workshopAccessProvider);
    final publish = ref.watch(workshopPublishProvider);
    final notes = [
      // Accepted for now, but the phone did not keep it: it may be asked again.
      if (access.disclosureAccepted &&
          !access.disclosureSaved &&
          !access.savingDisclosure &&
          access.preferenceError != null)
        WorkshopNote(l10n.workshopDisclosureUnsaved),
    ];

    switch (_stepOf(access, publish)) {
      case _Step.loading:
        return WorkshopPublishFrame(
          children: [_Waiting(caption: publish.waitingForPreviousOperation ? l10n.workshopPublishWaitingPrevious : null)],
        );
      case _Step.unreachable:
        final code = access.error!.code;
        final unconfigured = code == 'workshop_unconfigured' || code == 'workshop_untrusted_origin';
        return _Statement(
          icon: unconfigured ? AppIcons.workshop : AppIcons.offline,
          title: unconfigured ? l10n.workshopNotOpenTitle : l10n.workshopUnavailableTitle,
          message: workshopExceptionText(l10n, access.error!),
          actionLabel: unconfigured ? null : l10n.commonRetry,
          onAction: unconfigured || access.loading
              ? null
              : () => unawaited(ref.read(workshopAccessProvider.notifier).refresh()),
        );
      case _Step.closed:
        return _Statement(
          icon: AppIcons.workshop,
          title: l10n.workshopPublishClosedTitle,
          message: l10n.workshopPublishClosedMessage,
        );
      case _Step.signIn:
        return _Statement(
          icon: AppIcons.profile,
          title: l10n.workshopPublishSignInTitle,
          message: l10n.workshopPublishSignInMessage,
          actionLabel: l10n.workshopSignInTitle,
          // The sign-in sheet's own flow; this page only waits for its outcome.
          onAction: () => unawaited(showWorkshopSignInSheet(context)),
        );
      case _Step.disclosure:
        return WorkshopPublishFrame(
          children: [
            WorkshopDisclosureView(
              offer: access.disclosure!,
              stale: access.error?.code == 'workshop_confirmation_stale',
              onAccept: (offer) => unawaited(ref.read(workshopAccessProvider.notifier).confirmDisclosure(offer)),
              onDecline: _leave,
            ),
          ],
        );
      case _Step.profile:
        return _Statement(
          icon: AppIcons.profile,
          title: l10n.workshopPublishProfileTitle,
          message: l10n.workshopPublishProfileMessage,
          actionLabel: l10n.commonRetry,
          onAction: () => unawaited(ref.read(workshopAccessProvider.notifier).refresh()),
        );
      case _Step.checkFailed:
        final error = publish.error;
        return _Statement(
          icon: AppIcons.warning,
          title: l10n.workshopPublishCheckFailedTitle,
          // An unreadable record is not an empty one: no new submission
          // starts over it.
          message: error == null || error.code == 'workshop_preferences'
              ? l10n.workshopPublishCheckLocked
              : workshopPublishErrorText(l10n, error),
          actionLabel: l10n.commonRetry,
          onAction: () => unawaited(ref.read(workshopPublishProvider.notifier).restorePending()),
          below: WorkshopPublishLetGo(publish: publish, onLetGo: () => unawaited(_letGo()), centered: true),
        );
      case _Step.sending:
        return WorkshopPublishFrame(children: [...notes, _Sending(publish: publish)]);
      case _Step.result:
        return _Result(
          publish: publish,
          notes: notes,
          onBack: _leave,
          onSendAgain: () => unawaited(_sendAgain()),
          onClearRecord: () => unawaited(_resume()),
          onClearFiles: () => unawaited(ref.read(workshopPublishProvider.notifier).retryCleanup()),
          onLetGo: () => unawaited(_letGo()),
        );
      case _Step.unfinished:
        return _Unfinished(
          publish: publish,
          notes: notes,
          asked: _rechecks > 0,
          onResume: () => unawaited(_resume()),
          onEdit: () => unawaited(_editUnsent()),
          onTick: () => workshopPublishTickRights(context, ref),
          onLetGo: () => unawaited(_letGo()),
        );
      case _Step.sources:
        return WorkshopPublishFrame(
          children: [
            ...notes,
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Semantics(
                header: true,
                child: Text(l10n.workshopPublishChooseTitle, style: SettingsSection.titleStyle(context)),
              ),
            ),
            WorkshopPublishSourceList(onPick: _pick),
          ],
        );
      case _Step.form:
        final epoch = _formEpoch;
        final form = WorkshopPublishForm(
          key: ValueKey(epoch),
          source: publish.source!,
          seed: _seed ?? publish.input,
          cover: _coverOf(publish),
          generatingCover: _autoCoverPending,
          onCover: (cover) => setState(() {
            _autoCoverPending = false;
            _cover = cover;
          }),
          notes: notes,
          onChangeSource: () => unawaited(_changeSource()),
          // From here the state layer has the details: a later look at the
          // form starts from what it accepted.
          onNext: () => setState(() {
            _autoCoverPending = false;
            _editing = false;
            _seed = null;
          }),
        );
        return Stack(
          fit: StackFit.passthrough,
          children: [
            if (_autoCoverPending)
              Positioned(
                key: ValueKey(('auto-cover', epoch)),
                top: 0,
                left: 0,
                child: ExcludeSemantics(
                  child: IgnorePointer(
                    child: ref.read(workshopAutoCoverBuilderProvider)(
                      publish.source!,
                      (bytes) => _finishAutoCover(epoch, bytes),
                    ),
                  ),
                ),
              ),
            form,
          ],
        );
      case _Step.review:
        return WorkshopPublishReview(
          cover: _coverOf(publish),
          notes: notes,
          onEdit: () => setState(() => _editing = true),
          onSubmit: () => unawaited(_submit()),
        );
    }
  }
}

/// A quiet ring while something is read, with one line when the wait has a
/// reason worth saying.
class _Waiting extends StatelessWidget {
  const _Waiting({this.caption});

  final String? caption;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 64),
    child: Column(
      children: [
        const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)),
        if (caption case final caption?)
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 16, 32, 0),
            child: Text(
              caption,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
            ),
          ),
      ],
    ),
  );
}

/// A step that only says something: one glyph, one line, a short reason and
/// at most one button. [below] is for a quiet second way on, under it.
class _Statement extends StatelessWidget {
  const _Statement({
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.below,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Widget? below;

  @override
  Widget build(BuildContext context) => WorkshopPublishFrame(
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 40),
        child: EmptyView(icon: icon, title: title, message: message, actionLabel: actionLabel, onAction: onAction),
      ),
      ?below,
    ],
  );
}

/// The submission as one row: its square, its name, what it is.
class _Summary extends StatelessWidget {
  const _Summary(this.metadata);

  final WorkshopMetadata metadata;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListPageCard(
      children: [
        ListPageRow(
          leading: WorkshopAvatar(metadata),
          leadingWidth: 40,
          title: workshopTitleOf(metadata, Localizations.localeOf(context).languageCode),
          subtitle: [
            workshopKindText(l10n, metadata.kind),
            metadata.version,
            formatBytes(metadata.size),
          ].join(' · '),
        ),
      ],
    );
  }
}

/// While the submission is being sent. The bar shows a fraction only from
/// bytes the upload reported; every byte sent is still not a result, so the
/// last stretch says it is waiting for the workshop.
class _Sending extends StatelessWidget {
  const _Sending({required this.publish});

  final WorkshopPublishState publish;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final uploading = publish.phase == WorkshopPublishPhase.uploading;
    final counted = uploading && publish.total > 0;
    final label = switch (publish.phase) {
      WorkshopPublishPhase.uploading => l10n.workshopPublishPhaseUploading,
      WorkshopPublishPhase.awaitingResponse => l10n.workshopPublishPhaseWaiting,
      _ => l10n.workshopPublishPhaseWorking,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        if (publish.preparedMetadata case final metadata?) _Summary(metadata),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(label, style: theme.textTheme.titleSmall)),
                  if (counted)
                    Text(
                      l10n.workshopProgressBytes(formatBytes(publish.sent), formatBytes(publish.total)),
                      style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary)),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: AppShape.radiusXs,
                child: LinearProgressIndicator(
                  minHeight: 4,
                  value: counted ? (publish.sent / publish.total).clamp(0.0, 1.0) : null,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.workshopPublishStay,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.5),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// What the workshop answered. A result the workshop confirmed stays a
/// result even when the phone could not tidy up after it: those are said
/// beside it, each with its own retry that sends nothing.
class _Result extends StatelessWidget {
  const _Result({
    required this.publish,
    required this.notes,
    required this.onBack,
    required this.onSendAgain,
    required this.onClearRecord,
    required this.onClearFiles,
    required this.onLetGo,
  });

  final WorkshopPublishState publish;
  final List<Widget> notes;
  final VoidCallback onBack;
  final VoidCallback onSendAgain;
  final VoidCallback onClearRecord;
  final VoidCallback onClearFiles;

  /// 「放下这条记录」, for when clearing the record keeps failing.
  final VoidCallback onLetGo;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final result = publish.result!;
    final busy = publish.working;
    final failure = workshopPublishFailure(publish);
    final again = result.status == WorkshopSubmissionStatus.rejected || result.status == WorkshopSubmissionStatus.withdrawn;
    final reason = result.status == WorkshopSubmissionStatus.rejected ? result.reviewReason : result.withdrawalReason;
    final (icon, title) = switch (result.status) {
      WorkshopSubmissionStatus.approved => (AppIcons.verified, l10n.workshopPublishApprovedTitle),
      WorkshopSubmissionStatus.rejected => (AppIcons.blocked, l10n.workshopPublishRejectedTitle),
      WorkshopSubmissionStatus.withdrawn => (AppIcons.stopped, l10n.workshopPublishWithdrawnTitle),
      _ => (AppIcons.success, l10n.workshopPublishDoneTitle),
    };
    return WorkshopPublishFrame(
      children: [
        ...notes,
        Padding(
          padding: const EdgeInsets.only(top: 40),
          child: EmptyView(
            icon: icon,
            title: title,
            message: result.status == WorkshopSubmissionStatus.approved
                // Approved is the review's answer, not proof it is listed now.
                ? l10n.workshopPublishApprovedMessage
                : !again
                ? l10n.workshopPublishDoneMessage
                : reason == null
                ? l10n.workshopPublishAgainMessage
                : l10n.workshopPublishReason(reason),
            // Sending it again needs the old record cleared first.
            actionLabel: again && !publish.hasPending ? l10n.workshopPublishAgain : l10n.workshopPublishBackToMine,
            onAction: busy ? null : (again && !publish.hasPending ? onSendAgain : onBack),
          ),
        ),
        const SizedBox(height: 24),
        if (publish.preferenceError != null)
          WorkshopNote(
            l10n.workshopPublishRecordKept,
            tone: WorkshopNoteTone.warning,
            actionLabel: l10n.commonRetry,
            // With the record still there, clearing it is what failed. With
            // it gone, what failed was letting go of the old request for a
            // new submission: that is the step to try again.
            onAction: busy ? null : (publish.hasPending || !again ? onClearRecord : onSendAgain),
          ),
        // The result is the workshop's and stays; only the phone's record
        // of it is let go.
        WorkshopPublishLetGo(publish: publish, onLetGo: onLetGo),
        if (publish.cleanupError != null)
          WorkshopNote(
            l10n.workshopPublishLeftovers,
            actionLabel: l10n.commonRetry,
            onAction: busy ? null : onClearFiles,
          ),
        if (failure != null && failure.code != 'workshop_preferences')
          WorkshopNote(workshopPublishErrorText(l10n, failure), tone: WorkshopNoteTone.danger),
      ],
    );
  }
}

/// A submission that was started and has no confirmed result: left over
/// from before, failed part-way, or sent with no answer. Its details are
/// fixed, and the one button goes on with the same request.
class _Unfinished extends StatelessWidget {
  const _Unfinished({
    required this.publish,
    required this.notes,
    required this.asked,
    required this.onResume,
    required this.onEdit,
    required this.onTick,
    required this.onLetGo,
  });

  final WorkshopPublishState publish;
  final List<Widget> notes;

  /// This visit already asked about the unknown result at least once.
  final bool asked;
  final VoidCallback onResume;

  /// Back to the form. Only offered while the state layer says this
  /// submission was never sent.
  final VoidCallback onEdit;
  final VoidCallback onTick;

  /// 「放下这条记录」: the phone's record only, never the primary button.
  final VoidCallback onLetGo;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final failure = workshopPublishFailure(publish);
    final unknown = failure?.resultUnknown ?? false;
    final unsent = publish.canDiscardUnsentSubmission && !unknown;
    final unsaved = publish.preferenceError != null;
    final rightsError = workshopFieldErrorText(l10n, publish.fieldErrors[PublishField.rights]);
    return WorkshopPublishFrame(
      action: FilledButton(
        onPressed: publish.working ? null : onResume,
        child: Text(
          !unknown
              ? l10n.workshopPublishContinue
              : asked
              ? l10n.workshopPublishCheckAgain
              : l10n.workshopPublishCheckResult,
        ),
      ),
      children: [
        ...notes,
        Padding(
          padding: const EdgeInsets.only(top: 24),
          child: EmptyView(
            icon: unknown ? AppIcons.question : AppIcons.workshop,
            title: unknown ? l10n.workshopPublishUnknownTitle : l10n.workshopPublishPendingTitle,
            message: unknown
                ? l10n.workshopPublishUnknownMessage
                : unsent
                ? l10n.workshopPublishPendingUnsent
                : failure == null && !unsaved
                ? l10n.workshopPublishPendingMessage
                : l10n.workshopPublishPendingLocked,
          ),
        ),
        const SizedBox(height: 24),
        if (publish.preparedMetadata case final metadata?) _Summary(metadata),
        const SizedBox(height: 12),
        if (failure != null && !unknown)
          WorkshopNote(workshopPublishErrorText(l10n, failure), tone: WorkshopNoteTone.danger)
        else if (unsaved)
          WorkshopNote(l10n.workshopErrorPreferences, tone: WorkshopNoteTone.danger),
        // The tick was given when this submission was first sent. If it has
        // been taken back, going on needs it again.
        if (!publish.input.rightsConfirmed)
          WorkshopPublishRights(ticked: false, onTap: publish.working ? null : onTick, error: rightsError),
        WorkshopPublishLetGo(
          publish: publish,
          onLetGo: onLetGo,
          beside: [
            if (unsent)
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 44)),
                onPressed: onEdit,
                child: Text(l10n.workshopPublishEditUnsent),
              ),
          ],
        ),
      ],
    );
  }
}
