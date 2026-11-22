import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../update/update_http.dart';
import 'workshop_http.dart';
import 'workshop_models.dart';

/// This does not obtain consent. The UI constructs it only after explaining
/// which Worker will receive this account's GitHub token and obtaining
/// confirmation. Neither this class nor WorkshopClient serializes or stores it.
class WorkshopCredential {
  WorkshopCredential.forConsentedWorker({required Uri worker, required Uri account, required String token, required bool disclosureAccepted})
    : worker = workshopOrigin(worker), account = workshopOrigin(account), _token = token {
    if (!disclosureAccepted) workshopInvalid('workshop_consent_required');
    if (!RegExp(r'^[A-Za-z0-9_]{1,255}$').hasMatch(token)) workshopInvalid('workshop_account_auth_required');
  }
  final Uri worker, account;
  final String _token;
  @override
  String toString() => 'WorkshopCredential(redacted)';
}

class WorkshopCatalogSnapshot {
  const WorkshopCatalogSnapshot({required this.catalog, required this.fetchedAt, required this.stale, this.refreshError, this.cacheIssue});
  final WorkshopCatalog catalog;
  final DateTime fetchedAt;
  final bool stale;
  final WorkshopException? refreshError;
  final String? cacheIssue;
}

class _CatalogCopy {
  const _CatalogCopy(this.catalog, this.fetchedAt, this.etag);
  final WorkshopCatalog catalog;
  final DateTime fetchedAt;
  final String? etag;
}

class _CatalogState {
  Future<void> queue = Future.value();
  Uri? origin;
  _CatalogCopy? copy;
  bool loaded = false;
  String? issue;
}

/// An explicit deployment origin and app-private cache are required. There is
/// no production deployment hidden in this constructor and no implicit login.
class WorkshopClient {
  WorkshopClient({required Uri origin, required this.cacheFile, WorkshopHttp? http, DateTime Function()? clock})
    : origin = workshopOrigin(origin), http = http ?? IoWorkshopHttp(origin), _clock = clock ?? DateTime.now;
  final Uri origin;
  final File cacheFile;
  /// No request or credential is involved. Entry parsing already checked the
  /// exact path; the same normalized origin is used for package downloads.
  Uri? publicPreviewUri(WorkshopEntry entry) => entry.preview == null ? null : origin.resolve(entry.preview!.path);
  final WorkshopHttp http;
  final DateTime Function() _clock;
  // Provider replacement does not make the previous client's pending disk
  // write disappear. Share both ordering and the latest accepted history.
  static final _catalogs = <String, _CatalogState>{};
  _CatalogState get _state => _catalogs.putIfAbsent(
    cacheFile.absolute.uri.normalizePath().toString(), _CatalogState.new);

  /// Cache trouble remains inspectable even when no usable cached catalog
  /// exists and the network operation itself also fails.
  String? get cacheIssue => _state.origin == origin ? _state.issue : null;

  void close() => http.close();

  static String newRequestId() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  Future<WorkshopCatalogSnapshot> catalog({bool requireFresh = false}) {
    final state = _state;
    final run = state.queue.then((_) => _catalog(requireFresh, state));
    state.queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Returns a usable cached view without contacting the Worker. A caller must
  /// still refresh before treating it as current or allowing an installation.
  Future<WorkshopCatalogSnapshot?> cachedCatalog() {
    final state = _state;
    final run = state.queue.then<WorkshopCatalogSnapshot?>((_) async {
      _selectOrigin(state);
      await _loadCache(state);
      final copy = state.copy;
      if (copy == null) {
        return null;
      }
      return WorkshopCatalogSnapshot(catalog: copy.catalog, fetchedAt: copy.fetchedAt,
        stale: true, cacheIssue: state.issue);
    });
    state.queue = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  void _selectOrigin(_CatalogState state) {
    if (state.origin != origin) {
      state.origin = origin;
      state.copy = null;
      state.loaded = false;
      state.issue = null;
    }
  }

  Future<void> _loadCache(_CatalogState state) async {
    // A failed first disk read may retry, but a newer accepted memory copy
    // must not be replaced by old disk bytes after its own save failed.
    if (state.loaded || state.copy != null) return;
    state.loaded = true;
    try {
      if (!await cacheFile.exists()) return;
      if (await cacheFile.length() > 8 * 1024 * 1024) workshopInvalid('workshop_cache_invalid');
      final map = workshopMap(jsonDecode(await cacheFile.readAsString()));
      if (map['origin'] != origin.toString() || map['schema'] != 1 || map['etag'] != null &&
          (map['etag'] is! String || (map['etag'] as String).length > 512 || RegExp(r'[\r\n]').hasMatch(map['etag'] as String))) {
        workshopInvalid('workshop_cache_invalid');
      }
      // Older writers dropped unknown preview fields but kept the new ETag.
      // Retain their text for offline browsing, then require a complete 200.
      final etag = map['previewSchema'] == 1 ? map['etag'] as String? : null;
      state.copy = _CatalogCopy(WorkshopCatalog.fromJson(map['catalog']), workshopTime(map['fetchedAt']), etag);
      state.issue = null;
    } on FileSystemException {
      state.loaded = false;
      state.issue = 'workshop_cache_storage';
    } on Object {
      state.issue = 'workshop_cache_invalid';
    }
  }

  Future<void> _saveCache(_CatalogCopy copy, _CatalogState state) async {
    final temporary = File('${cacheFile.path}.part');
    try {
      await cacheFile.parent.create(recursive: true);
      await temporary.writeAsString(jsonEncode({'schema': 1, 'previewSchema': 1, 'origin': origin.toString(), 'etag': copy.etag,
        'fetchedAt': copy.fetchedAt.toUtc().toIso8601String(), 'catalog': copy.catalog.toJson()}), flush: true);
      await temporary.rename(cacheFile.path);
      state.issue = null;
    } on FileSystemException {
      state.issue = 'workshop_cache_storage';
      try { if (await temporary.exists()) await temporary.delete(); } on FileSystemException { /* Reported above. */ }
    }
  }

  Future<WorkshopCatalogSnapshot> _catalog(bool requireFresh, _CatalogState state) async {
    _selectOrigin(state);
    await _loadCache(state);
    try {
      final response = await http.get(origin.resolve('/market/workshop.json'), headers: {
        'if-none-match': ?state.copy?.etag,
      });
      final WorkshopCatalog catalog;
      String? etag;
      if (response.status == 304) {
        await response.discard();
        if (state.copy?.etag == null) workshopInvalid('workshop_bad_catalog');
        catalog = state.copy!.catalog;
        etag = state.copy!.etag;
      } else {
        if (response.status != 200) throw await workshopResponseError(response);
        catalog = WorkshopCatalog.fromJson(await workshopResponseJson(response, maxBytes: 8 * 1024 * 1024));
        etag = response.headers['etag'];
        if (etag != null && (etag.length > 512 || RegExp(r'[\r\n]').hasMatch(etag))) workshopInvalid('workshop_bad_catalog');
        final old = state.copy?.catalog;
        if (old != null) {
          Set<String> blocked(WorkshopCatalog value) => {
            for (final gone in value.withdrawn) gone.release,
            for (final entry in value.entries)
              for (final version in entry.blockedVersions) '${entry.metadata.identity}/$version',
          };
          if (catalog.generatedAt.isBefore(old.generatedAt) || !blocked(catalog).containsAll(blocked(old))) {
            workshopInvalid('workshop_catalog_rollback');
          }
        }
      }
      final copy = _CatalogCopy(catalog, DateTime.fromMillisecondsSinceEpoch(_clock().millisecondsSinceEpoch, isUtc: true), etag);
      state.copy = copy;
      await _saveCache(copy, state);
      return WorkshopCatalogSnapshot(catalog: catalog, fetchedAt: copy.fetchedAt, stale: false, cacheIssue: state.issue);
    } on Object catch (error) {
      final failure = workshopTransportError(error);
      if (requireFresh || state.copy == null) throw failure;
      return WorkshopCatalogSnapshot(catalog: state.copy!.catalog, fetchedAt: state.copy!.fetchedAt,
        stale: true, refreshError: failure, cacheIssue: state.issue);
    }
  }

  Future<WorkshopCapabilities> capabilities() async => WorkshopCapabilities.fromJson(await _json('GET', '/api/workshop/v1/capabilities'));

  Future<Map<String, String>> _identity(WorkshopCredential credential, {WorkshopCapabilities? capabilities}) async {
    if (credential.worker != origin) workshopInvalid('workshop_consent_required');
    final caps = capabilities ?? await this.capabilities();
    if (caps.account.origin != credential.account) workshopInvalid('workshop_account_origin');
    return {'Authorization': 'Bearer ${credential._token}', 'X-Workshop-Account-Origin': credential.account.toString()};
  }

  Future<Object?> _json(String method, String path, {Map<String, String> headers = const {}, Object? body,
    Map<String, String>? query, int maxBytes = 1024 * 1024}) async {
    final mutation = method != 'GET';
    try {
      final url = origin.resolve(path).replace(queryParameters: query);
      final response = await http.request(method, url, headers: {
        ...headers, if (body != null) 'content-type': 'application/json',
      }, body: body == null ? null : utf8.encode(jsonEncode(body)));
      if (response.status < 200 || response.status >= 300) throw await workshopResponseError(response, mutation: mutation);
      return await workshopResponseJson(response, maxBytes: maxBytes);
    } on Object catch (error) { throw workshopTransportError(error, mutation: mutation); }
  }

  void _submissionId(String id) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) workshopInvalid('workshop_bad_request');
  }

  WorkshopSubmission _submission(Object? json, WorkshopCredential credential) {
    final result = WorkshopSubmission.fromJson(workshopMap(json)['submission']);
    if (result.ownerOrigin != credential.account) workshopInvalid();
    return result;
  }

  T _mutationResult<T>(T Function() parse) {
    try { return parse(); } on Object {
      throw const WorkshopException('workshop_bad_response', resultUnknown: true);
    }
  }

  Future<WorkshopSubmission> createSubmission(WorkshopMetadata metadata, {required String requestId, required bool rightsConfirmed, required WorkshopCredential credential}) async {
    final Map<String, String> headers;
    try {
      if (!rightsConfirmed) workshopInvalid('workshop_rights_required');
      if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(requestId)) workshopInvalid('workshop_bad_request_id');
      final caps = await capabilities();
      if (!caps.features.uploads) workshopInvalid('workshop_upload_disabled');
      if (metadata.kind == 'companion' && !caps.features.companion) workshopInvalid('workshop_companion_disabled');
      if (!caps.kinds.contains(metadata.kind) || !metadata.supported) workshopInvalid('workshop_unsupported_kind');
      if (!caps.licenses.contains(metadata.license) || metadata.size > caps.archiveBytes) workshopInvalid('workshop_bad_metadata');
      if (metadata.previewSource case final source?) {
        if (!(caps.preview?.sources.contains(source) ?? false)) workshopInvalid('workshop_preview_unsupported');
      }
      headers = await _identity(credential, capabilities: caps);
    } on Object catch (error) {
      final failure = workshopTransportError(error);
      throw WorkshopException(failure.code, status: failure.status, retryAfter: failure.retryAfter,
        mutationNotSent: true);
    }
    final result = await _json('POST', '/api/workshop/v1/submissions', headers: headers,
      body: {'requestId': requestId, ...metadata.toJson()});
    return _mutationResult(() {
      final submission = _submission(result, credential);
      if (submission.metadata.previewSource != metadata.previewSource) workshopInvalid();
      return submission;
    });
  }

  Future<WorkshopSubmission> submission(String id, {required WorkshopCredential credential}) async {
    _submissionId(id);
    return _submission(await _json('GET', '/api/workshop/v1/submissions/$id', headers: await _identity(credential)), credential);
  }

  Future<WorkshopSubmissionPage> submissions({required WorkshopCredential credential, int limit = 20, String? cursor, WorkshopSubmissionStatus? status}) async {
    if (limit < 1 || limit > 100) workshopInvalid('workshop_bad_query');
    if (cursor != null) _submissionId(cursor);
    final headers = {
      ...await _identity(credential),
      'X-Workshop-Supported-Kinds': 'pet,companion,theme',
    };
    final map = workshopMap(await _json('GET', '/api/workshop/v1/submissions', headers: headers,
      maxBytes: 8 * 1024 * 1024, query: {
      'limit': '$limit', 'cursor': ?cursor, if (status != null) 'status': status.name,
    }));
    final rows = map['submissions'], next = map['nextCursor'];
    if (rows is! List || rows.length > limit || next != null && (next is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(next))) workshopInvalid();
    final parsed = rows.map(WorkshopSubmission.fromJson).toList();
    if (parsed.any((s) => s.ownerOrigin != credential.account)) workshopInvalid();
    return WorkshopSubmissionPage(List.unmodifiable(parsed), next as String?);
  }

  /// Verifies and holds the exact bounded byte snapshot that is sent. A file
  /// changing after export cannot substitute different bytes after hashing.
  Future<WorkshopSubmission> upload(WorkshopSubmission draft, File archive, {required WorkshopCredential credential,
    void Function(int sent, int total)? onProgress}) async {
    _submissionId(draft.id);
    final bytes = await workshopArchiveSnapshot(archive, draft.metadata);
    final headers = await _identity(credential);
    try {
      final transport = http;
      final url = origin.resolve('/api/workshop/v1/submissions/${draft.id}/archive');
      final uploadHeaders = {...headers, 'content-type': 'application/zip'};
      final UpdateHttpResponse response;
      if (transport case final WorkshopUploadHttp uploader) {
        response = await uploader.upload(url, headers: uploadHeaders, body: bytes, onProgress: onProgress);
      } else {
        onProgress?.call(0, bytes.length);
        response = await transport.request('PUT', url, headers: uploadHeaders, body: bytes);
        onProgress?.call(bytes.length, bytes.length);
      }
      if (response.status != 200) throw await workshopResponseError(response, mutation: true);
      final result = await workshopResponseJson(response);
      return _mutationResult<WorkshopSubmission>(() => _submission(result, credential));
    } on Object catch (error) { throw workshopTransportError(error, mutation: true); }
  }

  /// The caller persists this non-secret requestId before beginning, and can
  /// repeat the call after a lost response without creating a second draft.
  Future<WorkshopSubmission> submit(WorkshopMetadata metadata, File archive, {required String requestId, required bool rightsConfirmed,
    required WorkshopCredential credential, void Function(int sent, int total)? onProgress}) async {
    if (!rightsConfirmed) workshopInvalid('workshop_rights_required');
    await workshopArchiveSnapshot(archive, metadata);
    final draft = await createSubmission(metadata, requestId: requestId, rightsConfirmed: rightsConfirmed, credential: credential);
    if (draft.metadata.sha256 != metadata.sha256 || draft.metadata.size != metadata.size || draft.metadata.release != metadata.release) {
      throw const WorkshopException('workshop_bad_response', resultUnknown: true);
    }
    if (draft.status != WorkshopSubmissionStatus.draft) return draft;
    return upload(draft, archive, credential: credential, onProgress: onProgress);
  }

  Future<WorkshopSubmission> withdraw(String id, String reason, {required WorkshopCredential credential}) async {
    _submissionId(id);
    if (!workshopText(reason, 2000)) workshopInvalid('workshop_bad_reason');
    final result = await _json('POST', '/api/workshop/v1/submissions/$id/withdraw', headers: await _identity(credential), body: {'reason': reason});
    return _mutationResult(() => _submission(result, credential));
  }

  Future<String> report({required String kind, required String id, required String version, required String reason, required WorkshopCredential credential}) async {
    if (!const {'pet', 'companion', 'theme'}.contains(kind) || !workshopId(id) || WorkshopVersion.tryParse(version) == null) workshopInvalid('workshop_bad_request');
    if (!workshopText(reason, 2000)) workshopInvalid('workshop_bad_reason');
    final result = await _json('POST', '/api/workshop/v1/reports', headers: await _identity(credential),
      body: {'kind': kind, 'id': id, 'version': version, 'reason': reason});
    return _mutationResult(() {
      final reportId = workshopMap(result)['reportId'];
      if (reportId is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(reportId)) workshopInvalid();
      return reportId;
    });
  }
}

Future<Uint8List> workshopArchiveSnapshot(File archive, WorkshopMetadata metadata) async {
  if (!metadata.supported) workshopInvalid('workshop_unsupported_kind');
  if (metadata.size > workshopArchiveBytes) workshopInvalid('workshop_body_too_large');
  try {
    if (await archive.length() != metadata.size) workshopInvalid('workshop_size_mismatch');
    final builder = BytesBuilder(copy: false);
    await for (final chunk in archive.openRead()) {
      if (builder.length + chunk.length > metadata.size) workshopInvalid('workshop_size_mismatch');
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.length != metadata.size) workshopInvalid('workshop_size_mismatch');
    final hash = await Isolate.run(() => crypto.sha256.convert(bytes).toString());
    if (hash != metadata.sha256) workshopInvalid('workshop_sha_mismatch');
    return bytes;
  } on FileSystemException catch (error) {
    throw WorkshopException(const {28, 122}.contains(error.osError?.errorCode) ? 'workshop_no_space' : 'workshop_storage');
  }
}

Future<Object?> workshopResponseJson(UpdateHttpResponse response, {int maxBytes = 1024 * 1024}) async {
  if (response.contentLength != null && response.contentLength! > maxBytes) {
    await response.discard();
    workshopInvalid();
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response.body.timeout(const Duration(seconds: 30))) {
    if (bytes.length + chunk.length > maxBytes) workshopInvalid();
    bytes.add(chunk);
  }
  try { return jsonDecode(utf8.decode(bytes.takeBytes())); } on FormatException { workshopInvalid(); }
}

Future<WorkshopException> workshopResponseError(UpdateHttpResponse response, {bool mutation = false}) async {
  var code = response.status >= 300 && response.status < 400 ? 'workshop_redirect' : 'workshop_http';
  try {
    final body = await workshopResponseJson(response, maxBytes: 8192);
    final remote = body is Map ? body['error'] : null;
    if (remote is String && RegExp(r'^workshop_[a-z0-9_]{1,100}$').hasMatch(remote)) code = remote;
  } on Object { /* Only a stable code is retained; never the response body. */ }
  final retry = int.tryParse(response.headers['retry-after'] ?? '');
  return WorkshopException(code, status: response.status, retryAfter: retry != null && retry >= 0 ? Duration(seconds: retry) : null,
    resultUnknown: mutation && (response.status >= 500 || response.status >= 300 && response.status < 400));
}

WorkshopException workshopTransportError(Object error, {bool mutation = false}) {
  if (error is WorkshopException) {
    if (mutation && error.code == 'workshop_bad_response' && !error.resultUnknown) return WorkshopException(error.code, status: error.status, resultUnknown: true);
    return error;
  }
  if (error is TimeoutException) return WorkshopException('workshop_timeout', resultUnknown: mutation);
  if (error is SocketException || error is HttpException) return WorkshopException('workshop_network', resultUnknown: mutation);
  if (error is FileSystemException) return WorkshopException('workshop_storage', resultUnknown: mutation);
  return WorkshopException('workshop_bad_response', resultUnknown: mutation);
}
