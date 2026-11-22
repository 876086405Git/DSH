import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../workshop/workshop_client.dart';
import '../workshop/workshop_models.dart';
import '../workshop/workshop_preview.dart';
import '../workshop/workshop_repository.dart' show workshopLocalError;
import 'workshop_auth_state.dart';
import 'workshop_preferences.dart';
import 'workshop_publication.dart';
import 'workshop_publish_sources.dart';

enum WorkshopPublishPhase { idle, checking, preparing, ready, creating, uploading, awaitingResponse, complete, failed }

/// The page must explain the local loss and possible server submission, then
/// return this exact offer. It is not a server cancellation authorization.
class WorkshopPendingAbandonOffer {
  const WorkshopPendingAbandonOffer._({required this.range, required this.worker,
    required this.account, required this.accountId});
  final WorkshopPendingAbandonRange range;
  final Uri worker, account;
  final int accountId;
}

/// Page state deliberately excludes credentials, authorization objects, files,
/// private directory names, and absolute paths. A completed upload is not a
/// completed submission until the server response has been checked.
class WorkshopPublishState {
  WorkshopPublishState({required this.session, this.source, WorkshopPublicationInput? input,
    this.phase = WorkshopPublishPhase.idle, this.busy = false,
    this.waitingForPreviousOperation = false, this.pendingChecked = false,
    this.hasPending = false, this.pendingKnownUnsent = false, this.preparedMetadata, List<String> files = const [],
    Map<String, String> fieldErrors = const {}, this.sent = 0, this.total = 0,
    this.result, this.error, this.preferenceError, this.cleanupError,
    this.abandonOffer, this.recoveryError})
    : input = input ?? WorkshopPublicationInput(), files = List.unmodifiable(files),
      fieldErrors = Map.unmodifiable(fieldErrors);

  final Object session;
  final WorkshopPublishSource? source;
  final WorkshopPublicationInput input;
  final WorkshopPublishPhase phase;
  final bool busy, waitingForPreviousOperation, pendingChecked, hasPending, pendingKnownUnsent;
  final WorkshopMetadata? preparedMetadata;
  final List<String> files;
  final Map<String, String> fieldErrors;
  final int sent, total;
  final WorkshopSubmission? result;
  final WorkshopException? error, preferenceError, cleanupError;
  final WorkshopPendingAbandonOffer? abandonOffer;
  final WorkshopException? recoveryError;
  bool get working => busy || waitingForPreviousOperation;
  bool get canEditMetadata => pendingChecked && !working && !hasPending;
  bool get canDiscardUnsentSubmission => !working && hasPending && pendingKnownUnsent;
  bool get canRequestPendingAbandonment => !working && (result != null
      ? hasPending && preferenceError != null
      : hasPending || !pendingChecked && preferenceError != null);
  bool get canStartNewSubmission => !working && !hasPending &&
      (result?.status == WorkshopSubmissionStatus.rejected || result?.status == WorkshopSubmissionStatus.withdrawn);

  WorkshopPublishState copyWith({WorkshopPublishSource? source, bool clearSource = false,
    WorkshopPublicationInput? input, WorkshopPublishPhase? phase, bool? busy,
    bool? waitingForPreviousOperation, bool? pendingChecked, bool? hasPending, bool? pendingKnownUnsent,
    WorkshopMetadata? preparedMetadata, bool clearPrepared = false,
    List<String>? files, Map<String, String>? fieldErrors, int? sent, int? total,
    WorkshopSubmission? result, bool clearResult = false, WorkshopException? error,
    bool clearError = false, WorkshopException? preferenceError, bool clearPreferenceError = false,
    WorkshopException? cleanupError, bool clearCleanupError = false,
    WorkshopPendingAbandonOffer? abandonOffer, bool clearAbandonOffer = false,
    WorkshopException? recoveryError, bool clearRecoveryError = false}) => WorkshopPublishState(
      session: session, source: clearSource ? null : source ?? this.source,
      input: input ?? this.input, phase: phase ?? this.phase, busy: busy ?? this.busy,
      waitingForPreviousOperation: waitingForPreviousOperation ?? this.waitingForPreviousOperation,
      pendingChecked: pendingChecked ?? this.pendingChecked, hasPending: hasPending ?? this.hasPending,
      pendingKnownUnsent: pendingKnownUnsent ?? this.pendingKnownUnsent,
      preparedMetadata: clearPrepared ? null : preparedMetadata ?? this.preparedMetadata,
      files: clearPrepared ? const [] : files ?? this.files, fieldErrors: fieldErrors ?? this.fieldErrors,
      sent: sent ?? this.sent, total: total ?? this.total,
      result: clearResult ? null : result ?? this.result,
      error: clearError ? null : error ?? this.error,
      preferenceError: clearPreferenceError ? null : preferenceError ?? this.preferenceError,
      cleanupError: clearCleanupError ? null : cleanupError ?? this.cleanupError,
      abandonOffer: clearAbandonOffer ? null : abandonOffer ?? this.abandonOffer,
      recoveryError: clearRecoveryError ? null : recoveryError ?? this.recoveryError,
    );
}

final workshopRequestIdProvider = Provider<String Function()>((ref) => WorkshopClient.newRequestId);

class _DraftLease {
  _DraftLease(this.draft);
  final WorkshopPreparedDraft draft;
  int borrowers = 0;
  bool retired = false;
  Future<WorkshopException?>? _cleaning;

  Future<WorkshopException?> clean() {
    if (!retired || borrowers != 0 || draft.retained) return Future<WorkshopException?>.value();
    return _cleaning ??= Future<WorkshopException?>.microtask(() async {
      try {
        await draft.dispose();
        return null;
      } on Object {
        return const WorkshopException('workshop_draft_cleanup');
      } finally {
        _cleaning = null;
      }
    });
  }
}

class _PublishIntent {
  _PublishIntent({required this.scope, required this.pending, required this.lease, this.saved = false,
    this.mayHaveDispatched = false});
  final String scope;
  final WorkshopPendingSubmission pending;
  final _DraftLease lease;
  bool saved, cleared = false;
  // A preflight rejection proves only the current create was not sent. Once
  // any earlier attempt may have been sent, later preflights cannot erase it.
  bool mayHaveDispatched;
  String? submissionId;
  WorkshopSubmission? result;
}

class _PublishContext {
  _PublishContext(this.session);
  final Object session;
  String? scope;
  ({Uri worker, Uri account, int userId})? account;
  bool checked = false, closed = false;
  _DraftLease? prepared;
  _PublishIntent? intent;
  final retired = <_DraftLease>{};
  ({WorkshopPendingRecoveryStore store, WorkshopPendingRecoverySnapshot snapshot})? abandonment;
}

Object? _canonical(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

String _digest(Object? value) => sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();
bool _sameMetadata(WorkshopMetadata left, WorkshopMetadata right) =>
    jsonEncode(_canonical(left.toJson())) == jsonEncode(_canonical(right.toJson()));
String _fingerprint(String scope, WorkshopMetadata metadata) => _digest([scope, metadata.toJson()]);

/// One publisher per container. The operation gate survives account rebuilds:
/// a replacement session cannot restore/borrow an old operation's draft until
/// that operation has settled. It does not claim cross-process coordination.
class WorkshopPublishController extends Notifier<WorkshopPublishState> {
  _PublishContext? _context;
  Object? _operation;

  @override
  WorkshopPublishState build() {
    final session = ref.watch(workshopAccessProvider.select((value) => value.session));
    final context = _PublishContext(session);
    _context = context;
    ref.onDispose(() {
      context.closed = true;
      final prepared = context.prepared;
      if (prepared != null) _retire(context, prepared);
      for (final lease in context.retired.toList()) {
        unawaited(lease.clean());
      }
    });
    return WorkshopPublishState(session: session, waitingForPreviousOperation: _operation != null);
  }

  bool _current(_PublishContext context) {
    if (!ref.mounted || context.closed) return false;
    final current = state; // Flush Riverpod's possibly pending session rebuild.
    return identical(_context, context) && identical(current.session, context.session);
  }

  void _requireCurrent(_PublishContext context) {
    if (!_current(context)) workshopInvalid('workshop_cancelled');
  }

  Object? _begin(_PublishContext context, WorkshopPublishPhase phase, {bool recoveringPending = false}) {
    if (!_current(context)) return null;
    if (_operation != null) {
      state = state.copyWith(error: const WorkshopException('workshop_busy'));
      return null;
    }
    final token = Object();
    _operation = token;
    if (!recoveringPending) context.abandonment = null;
    state = state.copyWith(busy: true, waitingForPreviousOperation: false, phase: phase,
      clearError: !recoveringPending, clearAbandonOffer: !recoveringPending, clearRecoveryError: true);
    return token;
  }

  void _end(Object token) {
    if (!identical(_operation, token)) return;
    _operation = null;
    if (!ref.mounted) return;
    // Even an old session may release the gate, but none of its form/result
    // fields are copied into the replacement session.
    state = state.copyWith(busy: false, waitingForPreviousOperation: false);
  }

  bool _editorReady(_PublishContext context, {bool requireProfile = true}) {
    if (!_current(context)) return false;
    final access = ref.read(workshopAccessProvider);
    final code = state.working ? 'workshop_busy'
        : requireProfile && access.accountId == null ? 'workshop_profile_required'
        : !context.checked ? 'workshop_pending_check_required' : null;
    if (code == null) return true;
    state = state.copyWith(error: WorkshopException(code));
    return false;
  }

  Future<WorkshopAuthorization> _authorize(_PublishContext context) async {
    final authorization = await ref.read(workshopAccessProvider.notifier).authorize();
    _requireCurrent(context);
    if (!identical(authorization.session, context.session)) workshopInvalid('workshop_cancelled');
    if (authorization.requestScope == null || authorization.accountId == null) {
      workshopInvalid('workshop_profile_required');
    }
    final scope = _digest([authorization.client.origin.toString(),
      authorization.credential.account.toString(), authorization.accountId]);
    if (context.scope != null && context.scope != scope) workshopInvalid('workshop_cancelled');
    context.scope = scope;
    context.account = (worker: authorization.client.origin,
      account: authorization.credential.account, userId: authorization.accountId!);
    return authorization;
  }

  void _retire(_PublishContext context, _DraftLease lease) {
    lease.retired = true;
    context.retired.add(lease);
    unawaited(_clean(context, lease));
  }

  Future<bool> _clean(_PublishContext context, _DraftLease lease) async {
    // A skipped cleanup is not evidence that disposal succeeded. In
    // particular, do not remove the retry entry merely because a borrower
    // happened to finish while this async caller was yielding.
    if (!lease.retired || lease.borrowers != 0 || lease.draft.retained) return true;
    final error = await lease.clean();
    if (lease.borrowers != 0 || lease.draft.retained) return true;
    if (error == null) context.retired.remove(lease);
    if (_current(context) && error != null) state = state.copyWith(cleanupError: error);
    return error == null;
  }

  Future<bool> _cleanRetired(_PublishContext context) async {
    var cleaned = true;
    for (final lease in context.retired.toList()) {
      if (!await _clean(context, lease)) cleaned = false;
    }
    if (cleaned && _current(context)) state = state.copyWith(clearCleanupError: true);
    return cleaned;
  }

  /// Read-only, explicit initialization/recovery. No create or upload is sent.
  /// A successful check is reused for subsequent synchronous form edits.
  Future<void> restorePending() async {
    final current = state;
    final context = _context!;
    if (context.checked && !current.working) return;
    final token = _begin(context, WorkshopPublishPhase.checking);
    if (token == null) return;
    try {
      await _authorize(context);
      final preferences = ref.read(workshopPreferencesProvider);
      final restore = ref.read(workshopRestoreDraftProvider);
      final pending = await preferences.pendingSubmission(context.scope!);
      _requireCurrent(context);
      if (pending != null) {
        if (_fingerprint(context.scope!, pending.metadata) != pending.fingerprint) {
          workshopInvalid('workshop_preferences');
        }
        final draft = await restore(pending);
        draft.retained = true;
        final lease = _DraftLease(draft);
        if (!_current(context)) {
          _retire(context, lease);
          return;
        }
        context.prepared = lease;
        context.intent = _PublishIntent(scope: context.scope!, pending: pending, lease: lease,
          saved: true, mayHaveDispatched: true);
        state = state.copyWith(input: WorkshopPublicationInput.fromMetadata(pending.metadata),
          preparedMetadata: pending.metadata, files: pending.files, hasPending: true, pendingKnownUnsent: false,
          phase: WorkshopPublishPhase.ready, fieldErrors: const {});
      } else {
        state = state.copyWith(phase: WorkshopPublishPhase.idle);
      }
      context.checked = true;
      state = state.copyWith(pendingChecked: true, clearError: true, clearPreferenceError: true);
    } on Object catch (error) {
      if (_current(context)) {
        final mapped = workshopLocalError(error);
        state = state.copyWith(phase: WorkshopPublishPhase.failed,
          error: mapped, preferenceError: mapped.code == 'workshop_preferences' ? mapped : null);
      }
    } finally {
      _end(token);
    }
  }

  bool selectSource(WorkshopPublishSource source) {
    final current = state;
    final context = _context!;
    if (!_editorReady(context)) return false;
    if (current.hasPending) {
      state = state.copyWith(error: const WorkshopException('workshop_pending_submission'));
      return false;
    }
    if ((source.kind != 'pet' && source.kind != 'companion' && source.kind != 'theme') || source.localId.isEmpty) {
      state = state.copyWith(error: const WorkshopException('workshop_unsupported_kind'));
      return false;
    }
    if (source.previewSource != null && source.previewSource != workshopPreviewSources[source.kind]) {
      state = state.copyWith(error: const WorkshopException('workshop_bad_metadata'));
      return false;
    }
    _changeSource(context, source, source.initialInput());
    return true;
  }

  /// A preview change is an archive/content change. Keep the author's text,
  /// invalidate the old prepared ZIP, and require a fresh rights confirmation.
  bool setPreview(WorkshopPreviewInput? preview) {
    final current = state;
    final context = _context!;
    if (!_editorReady(context)) return false;
    if (current.hasPending) {
      state = state.copyWith(error: const WorkshopException('workshop_pending_submission'));
      return false;
    }
    final source = current.source;
    if (source == null) {
      state = state.copyWith(error: const WorkshopException('workshop_source_required'));
      return false;
    }
    if (preview != null && preview.source != workshopPreviewSources[source.kind]) {
      state = state.copyWith(error: const WorkshopException('workshop_bad_metadata'));
      return false;
    }
    _changeSource(context, source.withPreview(preview), current.input.copyWith(rightsConfirmed: false));
    return true;
  }

  void _changeSource(_PublishContext context, WorkshopPublishSource source, WorkshopPublicationInput input) {
    final old = context.prepared;
    context.prepared = null;
    context.intent = null;
    context.abandonment = null;
    if (old != null) _retire(context, old);
    state = state.copyWith(source: source, input: input, clearPrepared: true,
      clearResult: true, fieldErrors: const {}, sent: 0, total: 0,
      phase: WorkshopPublishPhase.idle, clearError: true, clearPreferenceError: true,
      clearAbandonOffer: true, clearRecoveryError: true);
  }

  bool setInput(WorkshopPublicationInput input) {
    final current = state;
    final context = _context!;
    if (!_editorReady(context)) return false;
    final kind = current.source?.kind ?? context.intent?.pending.metadata.kind;
    if (kind == null) {
      state = state.copyWith(error: const WorkshopException('workshop_source_required'));
      return false;
    }
    final changed = jsonEncode(_canonical(current.input.declaration(kind))) !=
        jsonEncode(_canonical(input.declaration(kind)));
    if (changed && current.hasPending) {
      state = state.copyWith(error: const WorkshopException('workshop_pending_submission'));
      return false;
    }
    if (changed) {
      final old = context.prepared;
      context.prepared = null;
      context.intent = null;
      context.abandonment = null;
      if (old != null) _retire(context, old);
    }
    state = state.copyWith(input: input, clearPrepared: changed, clearResult: changed,
      fieldErrors: const {}, clearError: true, clearAbandonOffer: changed, clearRecoveryError: changed,
      phase: changed ? WorkshopPublishPhase.idle : current.phase,
      sent: changed ? 0 : current.sent, total: changed ? 0 : current.total);
    return true;
  }

  Future<void> prepare() async {
    final current = state;
    final context = _context!;
    if (!_editorReady(context)) return;
    if (current.hasPending) {
      state = state.copyWith(error: const WorkshopException('workshop_pending_submission'));
      return;
    }
    final source = current.source;
    if (source == null) {
      state = state.copyWith(error: const WorkshopException('workshop_source_required'));
      return;
    }
    final errors = current.input.errors(includeRights: false);
    if (errors.isNotEmpty) {
      state = state.copyWith(fieldErrors: errors, error: const WorkshopException('workshop_invalid_publication'));
      return;
    }
    final token = _begin(context, WorkshopPublishPhase.preparing);
    if (token == null) return;
    try {
      final prepareDraft = ref.read(workshopPrepareDraftProvider);
      final old = context.prepared;
      context.prepared = null;
      context.intent = null;
      if (old != null) _retire(context, old);
      state = state.copyWith(clearPrepared: true, clearResult: true, fieldErrors: const {}, sent: 0, total: 0);
      if (!await _cleanRetired(context)) {
        if (_current(context)) state = state.copyWith(phase: WorkshopPublishPhase.failed);
        return;
      }
      _requireCurrent(context);
      final publication = current.input.publication(source.kind, previewSource: source.previewSource);
      final draft = await prepareDraft(source, publication);
      final lease = _DraftLease(draft);
      if (!_current(context)) {
        _retire(context, lease);
        await _clean(context, lease);
        return;
      }
      final metadata = draft.upload.metadata;
      if (!_sameMetadata(metadata, publication.withArchive(metadata.sha256, metadata.size))) {
        _retire(context, lease);
        await _clean(context, lease);
        workshopInvalid('workshop_prepared_mismatch');
      }
      context.prepared = lease;
      state = state.copyWith(preparedMetadata: metadata, files: draft.upload.files,
        phase: WorkshopPublishPhase.ready, clearError: true);
    } on Object catch (error) {
      if (_current(context)) state = state.copyWith(error: workshopLocalError(error), phase: WorkshopPublishPhase.failed);
    } finally {
      _end(token);
    }
  }

  void _checkSubmission(WorkshopSubmission result, _PublishIntent intent, WorkshopAuthorization authorization) {
    if (intent.submissionId != null && result.id != intent.submissionId ||
        !_sameMetadata(result.metadata, intent.pending.metadata) ||
        result.ownerOrigin != authorization.credential.account || result.ownerId != authorization.accountId) {
      throw const WorkshopException('workshop_bad_response', resultUnknown: true);
    }
    // A request id is the client's idempotency token, not a submission id.
    intent.submissionId = result.id;
  }

  Future<void> _finishKnown(_PublishContext context, _PublishIntent intent,
    WorkshopSubmission result, WorkshopPreferences preferences) async {
    intent.result = result;
    if (_current(context)) state = state.copyWith(result: result, phase: WorkshopPublishPhase.complete, clearError: true);
    try {
      await preferences.clearPendingSubmission(intent.scope, intent.pending.requestId);
    } on Object {
      if (_current(context)) state = state.copyWith(preferenceError: const WorkshopException('workshop_preferences'));
      return;
    }
    intent.cleared = true;
    intent.lease.draft.retained = false;
    _retire(context, intent.lease);
    if (_current(context)) state = state.copyWith(hasPending: false, pendingKnownUnsent: false, clearPreferenceError: true);
  }

  /// Every retry uses the same persisted metadata/request id. In particular,
  /// create precedes opening the archive when recovering an unknown result.
  Future<void> submit() async {
    final current = state;
    final context = _context!;
    final known = context.intent?.result != null;
    if (!_editorReady(context, requireProfile: !known)) return;
    final errors = known ? const <String, String>{} : current.input.errors();
    if (errors.isNotEmpty) {
      state = state.copyWith(fieldErrors: errors, error: const WorkshopException('workshop_invalid_publication'));
      return;
    }
    final lease = context.intent?.lease ?? context.prepared;
    if (lease == null) {
      state = state.copyWith(error: const WorkshopException('workshop_prepare_required'));
      return;
    }
    final token = _begin(context, WorkshopPublishPhase.creating);
    if (token == null) return;
    lease.borrowers++;
    try {
      final preferences = ref.read(workshopPreferencesProvider);
      var intent = context.intent;
      // A known result needs only local journal/cleanup work. Revoking the
      // checkbox cannot undo it, and this branch never requests credentials
      // or sends another create/upload.
      final completed = intent;
      if (completed != null && completed.result != null) {
        final result = completed.result!;
        if (!completed.cleared) {
          await _finishKnown(context, completed, result, preferences);
        } else {
          state = state.copyWith(result: result, phase: WorkshopPublishPhase.complete);
        }
        return;
      }
      final requestId = ref.read(workshopRequestIdProvider);
      final authorization = await _authorize(context);
      if (intent == null) {
        final metadata = lease.draft.upload.metadata;
        final fingerprint = _fingerprint(context.scope!, metadata);
        final id = await preferences.reserveSubmissionRequestId(fingerprint, requestId());
        _requireCurrent(context);
        final pending = WorkshopPendingSubmission.fromJson(WorkshopPendingSubmission(
          requestId: id, fingerprint: fingerprint, directoryName: lease.draft.directoryName,
          metadata: metadata, files: lease.draft.upload.files).toJson());
        intent = _PublishIntent(scope: context.scope!, pending: pending, lease: lease);
        context.intent = intent;
      }
      if (!intent.saved) {
        // A platform setter can report failure after a write reached disk.
        // Retention is deliberately conservative before the first attempt.
        lease.draft.retained = true;
        state = state.copyWith(hasPending: true, pendingKnownUnsent: !intent.mayHaveDispatched);
        try {
          await preferences.savePendingSubmission(intent.scope, intent.pending);
          intent.saved = true;
        } on Object {
          if (_current(context)) {
            state = state.copyWith(preferenceError: const WorkshopException('workshop_preferences'),
              phase: WorkshopPublishPhase.failed);
          }
          return;
        }
      }
      _requireCurrent(context);
      state = state.copyWith(clearPreferenceError: true);
      final previouslyDispatched = intent.mayHaveDispatched;
      intent.mayHaveDispatched = true;
      state = state.copyWith(pendingKnownUnsent: false);
      late WorkshopSubmission result;
      try {
        result = await authorization.client.createSubmission(intent.pending.metadata,
          requestId: intent.pending.requestId, rightsConfirmed: true, credential: authorization.credential);
      } on Object catch (error) {
        if (!previouslyDispatched && error is WorkshopException && error.mutationNotSent) {
          intent.mayHaveDispatched = false;
        }
        rethrow;
      }
      _checkSubmission(result, intent, authorization);
      _requireCurrent(context);
      if (result.status == WorkshopSubmissionStatus.draft) {
        state = state.copyWith(phase: WorkshopPublishPhase.uploading, sent: 0, total: intent.pending.metadata.size);
        result = await authorization.client.upload(result, lease.draft.upload.file,
          credential: authorization.credential, onProgress: (sent, total) {
            if (!_current(context) || !identical(_operation, token)) return;
            final current = state;
            if (current.phase != WorkshopPublishPhase.uploading &&
                current.phase != WorkshopPublishPhase.awaitingResponse) {
              return;
            }
            state = current.copyWith(sent: sent, total: total,
              phase: sent == total ? WorkshopPublishPhase.awaitingResponse : WorkshopPublishPhase.uploading);
          });
        _checkSubmission(result, intent, authorization);
        _requireCurrent(context);
        if (result.status == WorkshopSubmissionStatus.draft) {
          throw const WorkshopException('workshop_bad_response', resultUnknown: true);
        }
      }
      await _finishKnown(context, intent, result, preferences);
    } on Object catch (error) {
      if (_current(context)) {
        final mapped = workshopLocalError(error);
        state = state.copyWith(error: mapped,
          pendingKnownUnsent: context.intent != null && !context.intent!.mayHaveDispatched,
          preferenceError: mapped.code == 'workshop_preferences' ? mapped : null,
          phase: WorkshopPublishPhase.failed);
        // The journal keeps the request id, so signing in again resumes it.
        workshopForgetRefusedAccount(ref, mapped);
      }
    } finally {
      lease.borrowers--;
      try { await _clean(context, lease); } finally { _end(token); }
    }
  }

  Future<void> retrySubmission() => submit();

  /// Only reads the local journal. No remote preflight or mutation is needed
  /// after this session has captured a confirmed public account identity.
  Future<void> requestPendingAbandonment() async {
    final current = state;
    final context = _context!;
    if (!current.canRequestPendingAbandonment) return;
    final account = context.account;
    if (account == null) {
      state = state.copyWith(recoveryError: const WorkshopException('workshop_profile_required'));
      return;
    }
    final token = _begin(context, current.phase, recoveringPending: true);
    if (token == null) return;
    context.abandonment = null;
    state = state.copyWith(clearAbandonOffer: true);
    try {
      final store = ref.read(workshopPendingRecoveryProvider);
      if (store == null) workshopInvalid('workshop_recovery_unsupported');
      final snapshot = await store.pendingRecovery(context.scope!);
      _requireCurrent(context);
      final offer = WorkshopPendingAbandonOffer._(range: snapshot.range,
        worker: account.worker, account: account.account, accountId: account.userId);
      context.abandonment = (store: store, snapshot: snapshot);
      state = state.copyWith(abandonOffer: offer, clearRecoveryError: true);
    } on Object catch (error) {
      if (_current(context)) {
        state = state.copyWith(recoveryError: error is WorkshopException ? error
            : const WorkshopException('workshop_preferences'));
      }
    } finally {
      _end(token);
    }
  }

  /// Explicitly loses local recovery linkage, not a remote draft/submission.
  /// The store compares the offered raw version before any journal write.
  Future<void> confirmPendingAbandonment(WorkshopPendingAbandonOffer offered) async {
    final current = state;
    final context = _context!;
    if (current.working) return;
    if (!identical(current.abandonOffer, offered)) {
      state = state.copyWith(recoveryError: const WorkshopException('workshop_confirmation_stale'));
      return;
    }
    final binding = context.abandonment!;
    final token = _begin(context, current.phase, recoveringPending: true);
    if (token == null) return;
    final intent = context.intent;
    final result = intent?.result;
    final lease = intent?.lease ?? context.prepared;
    if (lease != null) lease.borrowers++;
    try {
      await binding.store.abandonPendingRecovery(binding.snapshot);
      context.abandonment = null;
      if (result != null) {
        // The server result was already checked. Repair only its blocked
        // local finish, preserving the explicit rejected/withdrawn restart.
        intent!.cleared = true;
      } else {
        context.intent = null;
        context.prepared = null;
      }
      context.checked = true;
      // A corrupt record never constructed a lease. Only the controller's
      // already validated private directory may enter the cleanup queue.
      if (lease != null) {
        lease.draft.retained = false;
        _retire(context, lease);
      }
      if (_current(context)) {
        if (result != null) {
          state = state.copyWith(result: result, phase: WorkshopPublishPhase.complete,
            hasPending: false, pendingKnownUnsent: false, clearError: true,
            clearPreferenceError: true, clearAbandonOffer: true, clearRecoveryError: true);
        } else {
          state = state.copyWith(input: current.input.copyWith(rightsConfirmed: false),
            hasPending: false, pendingKnownUnsent: false, pendingChecked: true,
            clearPrepared: true, clearResult: true, sent: 0, total: 0,
            fieldErrors: const {}, phase: WorkshopPublishPhase.idle,
            clearError: true, clearPreferenceError: true, clearAbandonOffer: true, clearRecoveryError: true);
        }
      }
    } on Object catch (error) {
      if (_current(context)) {
        final mapped = error is WorkshopException ? error : const WorkshopException('workshop_preferences');
        final stale = mapped.code == 'workshop_confirmation_stale';
        if (stale) context.abandonment = null;
        state = state.copyWith(recoveryError: mapped, clearAbandonOffer: stale);
      }
    } finally {
      if (lease != null) {
        lease.borrowers--;
        try { await _clean(context, lease); } finally { _end(token); }
      } else {
        _end(token);
      }
    }
  }

  /// Leaves only a locally saved intent whose entire observed history is
  /// known not to have dispatched create. A restored journal has no such
  /// proof. The request-id binding is kept, so identical metadata reuses it.
  /// No authorization refresh, create, upload, or server deletion is sent.
  Future<void> discardUnsentSubmission() async {
    final current = state;
    final context = _context!;
    if (!current.canDiscardUnsentSubmission) return;
    final intent = context.intent!;
    final token = _begin(context, WorkshopPublishPhase.checking);
    if (token == null) return;
    final lease = intent.lease;
    lease.borrowers++;
    try {
      final preferences = ref.read(workshopPreferencesProvider);
      await preferences.clearPendingSubmission(intent.scope, intent.pending.requestId);
      intent.cleared = true;
      lease.draft.retained = false;
      context.intent = null;
      context.prepared = null;
      _retire(context, lease);
      if (_current(context)) {
        state = state.copyWith(input: current.input.copyWith(rightsConfirmed: false),
          hasPending: false, pendingKnownUnsent: false, clearPrepared: true, clearResult: true,
          sent: 0, total: 0, fieldErrors: const {}, phase: WorkshopPublishPhase.idle,
          clearError: true, clearPreferenceError: true);
      }
    } on Object catch (error) {
      if (_current(context)) {
        final mapped = workshopLocalError(error);
        state = state.copyWith(error: mapped,
          preferenceError: mapped.code == 'workshop_preferences' ? mapped : null,
          phase: WorkshopPublishPhase.failed);
      }
    } finally {
      lease.borrowers--;
      try { await _clean(context, lease); } finally { _end(token); }
    }
  }

  /// A new id for identical metadata is an explicit action, available only
  /// after a known rejected/withdrawn result and successful journal removal.
  Future<void> startNewSubmission() async {
    final current = state;
    final context = _context!;
    if (!_editorReady(context)) return;
    final intent = context.intent;
    if (!current.canStartNewSubmission || intent == null || !intent.cleared) {
      state = state.copyWith(error: const WorkshopException('workshop_new_submission_unavailable'));
      return;
    }
    final token = _begin(context, WorkshopPublishPhase.checking);
    if (token == null) return;
    try {
      await _authorize(context);
      await ref.read(workshopPreferencesProvider).retireSubmissionRequestId(
        intent.pending.fingerprint, intent.pending.requestId);
      _requireCurrent(context);
      state = state.copyWith(clearPreferenceError: true);
      if (!await _cleanRetired(context)) {
        if (_current(context)) state = state.copyWith(phase: WorkshopPublishPhase.complete);
        return;
      }
      _requireCurrent(context);
      context.intent = null;
      context.prepared = null;
      state = state.copyWith(input: current.input.copyWith(rightsConfirmed: false), clearPrepared: true,
        clearResult: true, hasPending: false, sent: 0, total: 0, fieldErrors: const {},
        phase: WorkshopPublishPhase.idle, clearError: true, clearPreferenceError: true);
    } on Object catch (error) {
      if (_current(context)) {
        final mapped = workshopLocalError(error);
        state = state.copyWith(error: mapped,
          preferenceError: mapped.code == 'workshop_preferences' ? mapped : null,
          phase: WorkshopPublishPhase.complete);
      }
    } finally {
      _end(token);
    }
  }

  Future<void> retryCleanup() async {
    final current = state;
    final context = _context!;
    if (current.working) return;
    final token = _begin(context, current.phase);
    if (token == null) return;
    try { await _cleanRetired(context); } finally { _end(token); }
  }
}

final workshopPublishProvider = NotifierProvider<WorkshopPublishController, WorkshopPublishState>(
  WorkshopPublishController.new,
);
