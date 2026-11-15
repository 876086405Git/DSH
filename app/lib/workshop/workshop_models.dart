// The v1 wire contract is services/share-worker/docs/workshop-api.md.
// Nothing here reads credentials, local preferences or a widget tree.

const workshopArchiveBytes = 50 * 1024 * 1024;
const workshopExpandedBytes = 128 * 1024 * 1024;
const workshopPreviewSide = 512;
const workshopPreviewPixels = 262144;
const workshopPreviewBytes = 2 * 1024 * 1024;
const workshopPreviewSources = {'pet': 'pet-idle', 'companion': 'companion-preview'};
const workshopLicenses = {
  'CC0-1.0', 'CC-BY-4.0', 'CC-BY-SA-4.0', 'MIT', 'Apache-2.0',
  'BSD-2-Clause', 'BSD-3-Clause', 'LicenseRef-Author-Permission',
};

/// Stable codes only: never put a key, server body or local path in an error.
class WorkshopException implements Exception {
  const WorkshopException(this.code, {this.status, this.retryAfter, this.resultUnknown = false,
    this.mutationNotSent = false});
  final String code;
  final int? status;
  final Duration? retryAfter;
  /// A write may have reached the server. Reconcile before claiming failure.
  final bool resultUnknown;
  /// Preflight proved this mutation call did not reach the HTTP transport.
  /// Earlier attempts with the same requestId may still have reached the server.
  final bool mutationNotSent;
  @override
  String toString() => 'WorkshopException($code)';
}

Never workshopInvalid([String code = 'workshop_bad_response']) => throw WorkshopException(code);

bool workshopId(Object? value) => value is String && value.length <= 40 &&
    RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(value);
bool workshopHash(Object? value) => value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
bool workshopText(Object? value, int cap) => value is String && value.trim().isNotEmpty &&
    value.runes.length <= cap && !value.runes.any((r) => r < 32 || r >= 0xd800 && r <= 0xdfff);

Uri workshopOrigin(Uri value) {
  if (value.scheme != 'https' || value.host.isEmpty || value.userInfo.isNotEmpty ||
      value.hasQuery || value.hasFragment || value.path.isNotEmpty && value.path != '/') {
    workshopInvalid('workshop_untrusted_origin');
  }
  return Uri(scheme: 'https', host: _workshopOriginHost(value.host), port: value.hasPort ? value.port : null);
}

String _workshopOriginHost(String host) {
  // Uri already validated the host. Normalize ordinary IPv6 by value; zone
  // identifiers and IPvFuture keep their existing handling and support limits.
  if (!host.contains(':') || host.contains('%') || host.startsWith('[')) {
    return host;
  }
  final bytes = Uri.parseIPv6Address(host);
  final pieces = List<int>.generate(8, (i) => (bytes[i * 2] << 8) | bytes[i * 2 + 1], growable: false);
  var longestStart = -1, longestLength = 1;
  for (var i = 0; i < pieces.length;) {
    if (pieces[i] != 0) {
      i++;
      continue;
    }
    final start = i;
    while (i < pieces.length && pieces[i] == 0) {
      i++;
    }
    if (i - start > longestLength) {
      longestStart = start;
      longestLength = i - start;
    }
  }
  final words = pieces.map((piece) => piece.toRadixString(16)).toList(growable: false);
  if (longestStart < 0) {
    return words.join(':');
  }
  return '${words.take(longestStart).join(':')}::${words.skip(longestStart + longestLength).join(':')}';
}

bool workshopSource(Object? value) {
  if (!workshopText(value, 2048)) return false;
  final source = value as String;
  if (RegExp(r'\s').hasMatch(source)) return false;
  final uri = Uri.tryParse(source);
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty && uri.userInfo.isEmpty;
}

/// The server permits 80-character SemVer, including numeric identifiers
/// larger than int64. Compare their digit strings without losing precision.
class WorkshopVersion implements Comparable<WorkshopVersion> {
  WorkshopVersion._(this.value, this.core, this.pre);
  final String value;
  final List<String> core;
  final List<String> pre;
  static final _syntax = RegExp(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?$',
  );
  static WorkshopVersion? tryParse(Object? value) {
    if (value is! String || value.length > 80) return null;
    final match = _syntax.firstMatch(value);
    if (match == null) return null;
    return WorkshopVersion._(value, [match[1]!, match[2]!, match[3]!], match[4]?.split('.') ?? const []);
  }
  static int _digits(String a, String b) => a.length == b.length ? a.compareTo(b) : a.length.compareTo(b.length);
  @override
  int compareTo(WorkshopVersion other) {
    for (var i = 0; i < 3; i++) {
      final n = _digits(core[i], other.core[i]);
      if (n != 0) return n;
    }
    if (pre.isEmpty || other.pre.isEmpty) {
      return pre.isEmpty == other.pre.isEmpty ? 0 : (pre.isEmpty ? 1 : -1);
    }
    for (var i = 0; i < pre.length && i < other.pre.length; i++) {
      final a = pre[i], b = other.pre[i];
      final an = RegExp(r'^[0-9]+$').hasMatch(a), bn = RegExp(r'^[0-9]+$').hasMatch(b);
      final n = an && bn ? _digits(a, b) : an != bn ? (an ? -1 : 1) : a.compareTo(b);
      if (n != 0) return n;
    }
    return pre.length.compareTo(other.pre.length);
  }
}

Map<String, Object?> workshopMap(Object? value) {
  if (value is! Map<String, Object?>) workshopInvalid();
  return value;
}

DateTime workshopTime(Object? value) {
  if (value is! String || !RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{3})?Z$').hasMatch(value)) {
    workshopInvalid();
  }
  final time = DateTime.tryParse(value);
  if (time == null || time.toUtc().toIso8601String() != (value.contains('.') ? value : value.replaceFirst('Z', '.000Z'))) {
    workshopInvalid();
  }
  return time;
}

class WorkshopFeatures {
  const WorkshopFeatures({required this.uploads, required this.companion});
  factory WorkshopFeatures.fromJson(Object? value) {
    final map = workshopMap(value);
    if (map['uploads'] is! bool || map['companion'] is! bool) workshopInvalid();
    return WorkshopFeatures(uploads: map['uploads'] as bool, companion: map['companion'] as bool);
  }
  final bool uploads;
  final bool companion;
  Map<String, Object?> toJson() => {'uploads': uploads, 'companion': companion};
}

class WorkshopMetadata {
  WorkshopMetadata._(Map<String, Object?> value)
    : kind = value['kind'] as String, id = value['id'] as String, version = value['version'] as String,
      minApp = value['minApp'] as String, title = Map.unmodifiable((value['title'] as Map).cast<String, String>()),
      author = value['author'] as String, license = value['license'] as String, source = value['source'] as String,
      sha256 = value['sha256'] as String, size = value['size'] as int, description = value['description'] as String,
      tags = List.unmodifiable((value['tags'] as List).cast<String>()),
      previewSource = value['previewSource'] as String?;

  factory WorkshopMetadata.fromJson(Object? value, {bool submission = true}) {
    final m = workshopMap(value), title = m['title'];
    final description = m.containsKey('description') ? m['description'] : '';
    final tags = m.containsKey('tags') ? m['tags'] : const <String>[];
    final supported = const {'pet', 'companion'}.contains(m['kind']);
    // Unknown public kinds retain their existing unsupported-kind projection;
    // this client does not interpret their future preview source modes.
    final previewSource = supported ? m['previewSource'] : null;
    if (!workshopId(m['kind']) || !workshopId(m['id']) || WorkshopVersion.tryParse(m['version']) == null ||
        WorkshopVersion.tryParse(m['minApp']) == null || title is! Map ||
        !workshopText(title['zh'], 120) || !workshopText(title['en'], 120) ||
        !workshopText(m['author'], 256) || !workshopText(m['license'], 100) || !workshopSource(m['source']) ||
        !workshopHash(m['sha256']) || m['size'] is! int || (m['size'] as int) < 1 ||
        (m['size'] as int) > 9007199254740991 || supported &&
        (!workshopLicenses.contains(m['license']) || submission && (m['size'] as int) > workshopArchiveBytes) || submission &&
        (m['rightsConfirmed'] != true || !supported) ||
        description != '' && !workshopText(description, 512) || tags is! List || tags.length > 8 ||
        tags.any((tag) => !workshopText(tag, 32)) || tags.toSet().length != tags.length ||
        supported && m.containsKey('previewSource') && previewSource != workshopPreviewSources[m['kind']]) {
      workshopInvalid(submission ? 'workshop_bad_metadata' : 'workshop_bad_catalog');
    }
    return WorkshopMetadata._({...m, 'title': {'zh': title['zh'], 'en': title['en']}, 'description': description,
      'tags': tags, 'previewSource': previewSource});
  }
  final String kind, id, version, minApp, author, license, source, sha256, description;
  final Map<String, String> title;
  final List<String> tags;
  final int size;
  final String? previewSource;
  String get identity => '$kind/$id';
  String get release => '$identity/$version';
  bool get supported => kind == 'pet' || kind == 'companion';
  String get archivePath => '/market/workshop/$release/$sha256.zip';
  Map<String, Object?> toJson({bool submission = true}) => {
    'kind': kind, 'id': id, 'version': version, 'minApp': minApp, 'title': title,
    'author': author, 'license': license, 'source': source, 'sha256': sha256, 'size': size,
    if (description.isNotEmpty) 'description': description,
    if (tags.isNotEmpty) 'tags': tags,
    if (previewSource != null) 'previewSource': previewSource,
    if (submission) 'rightsConfirmed': true,
  };
}

/// A registered public PNG. Its path is bound to this exact archive and image.
class WorkshopPreview {
  WorkshopPreview._(this.path, this.sha256, this.size, this.width, this.height);
  factory WorkshopPreview.fromJson(Object? value, {required WorkshopMetadata metadata}) {
    final m = workshopMap(value), hash = m['sha256'];
    final size = m['size'], width = m['width'], height = m['height'];
    if (!workshopHash(hash) || size is! int || size < 1 || size > workshopPreviewBytes ||
        width is! int || width < 1 || width > workshopPreviewSide ||
        height is! int || height < 1 || height > workshopPreviewSide ||
        width * height > workshopPreviewPixels ||
        m['path'] != '/market/workshop/${metadata.release}/${metadata.sha256}/preview/$hash.png') {
      workshopInvalid();
    }
    return WorkshopPreview._(m['path'] as String, hash as String, size, width, height);
  }
  final String path, sha256;
  final int size, width, height;
  Map<String, Object?> toJson() => {'path': path, 'sha256': sha256, 'size': size, 'width': width, 'height': height};
}

class WorkshopEntry {
  WorkshopEntry._(this.metadata, this.blockedVersions, this.preview);
  factory WorkshopEntry.fromJson(Object? value) {
    final m = workshopMap(value), meta = WorkshopMetadata.fromJson(value, submission: false), blocked = m['blockedVersions'];
    if (m['url'] != meta.archivePath || blocked is! List || blocked.length > 4000 ||
        blocked.any((v) => WorkshopVersion.tryParse(v) == null) || blocked.toSet().length != blocked.length) {
      workshopInvalid('workshop_bad_catalog');
    }
    return WorkshopEntry._(meta, Set.unmodifiable(blocked.cast<String>()),
      meta.supported && m.containsKey('preview') ? WorkshopPreview.fromJson(m['preview'], metadata: meta) : null);
  }
  final WorkshopMetadata metadata;
  final Set<String> blockedVersions;
  final WorkshopPreview? preview;
  Map<String, Object?> toJson() => {...metadata.toJson(submission: false), 'url': metadata.archivePath,
    'blockedVersions': blockedVersions.toList(), if (preview != null) 'preview': preview!.toJson()};
}

class WorkshopWithdrawal {
  WorkshopWithdrawal._(this.kind, this.id, this.version, this.reason, this.at);
  factory WorkshopWithdrawal.fromJson(Object? value) {
    final m = workshopMap(value);
    if (!workshopId(m['kind']) || !workshopId(m['id']) || WorkshopVersion.tryParse(m['version']) == null || !workshopText(m['reason'], 2000)) {
      workshopInvalid('workshop_bad_catalog');
    }
    return WorkshopWithdrawal._(m['kind'] as String, m['id'] as String, m['version'] as String, m['reason'] as String, workshopTime(m['at']));
  }
  final String kind, id, version, reason;
  final DateTime at;
  String get release => '$kind/$id/$version';
  Map<String, Object?> toJson() => {'kind': kind, 'id': id, 'version': version, 'reason': reason, 'at': at.toUtc().toIso8601String()};
}

class WorkshopCatalog {
  WorkshopCatalog._(this.generatedAt, this.features, this.entries, this.withdrawn);
  factory WorkshopCatalog.fromJson(Object? value) {
    // Entries over 20 MiB come in largeEntries, which apps from before the
    // 50 MiB cap ignore (one such entry made their whole catalog invalid).
    final m = workshopMap(value), small = m['entries'], large = m['largeEntries'] ?? const <Object?>[], gone = m['withdrawn'];
    if (m['schema'] != 1 || small is! List || large is! List || small.length + large.length > 1000 || gone is! List || gone.length > 4000) {
      workshopInvalid('workshop_bad_catalog');
    }
    final rows = [...small, ...large];
    final entries = rows.map(WorkshopEntry.fromJson).toList(), withdrawals = gone.map(WorkshopWithdrawal.fromJson).toList();
    if (entries.map((e) => e.metadata.identity).toSet().length != entries.length ||
        withdrawals.map((e) => e.release).toSet().length != withdrawals.length) {
      workshopInvalid('workshop_bad_catalog');
    }
    return WorkshopCatalog._(workshopTime(m['generatedAt']), WorkshopFeatures.fromJson(m['features']), List.unmodifiable(entries), List.unmodifiable(withdrawals));
  }
  final DateTime generatedAt;
  final WorkshopFeatures features;
  final List<WorkshopEntry> entries;
  final List<WorkshopWithdrawal> withdrawn;
  WorkshopEntry? find(String kind, String id) => entries.where((e) => e.metadata.kind == kind && e.metadata.id == id).firstOrNull;
  bool blocked(String kind, String id, String version) => withdrawn.any((e) => e.release == '$kind/$id/$version') || (find(kind, id)?.blockedVersions.contains(version) ?? false);
  String? unavailable(WorkshopEntry entry, String appVersion) {
    final m = entry.metadata;
    if (!m.supported) return 'workshop_unsupported_kind';
    if (m.kind == 'companion' && !features.companion) return 'workshop_companion_disabled';
    if (blocked(m.kind, m.id, m.version)) return 'workshop_version_withdrawn';
    final installedApp = WorkshopVersion.tryParse(appVersion.split('+').first);
    if (installedApp == null) return 'workshop_app_version_unknown';
    if (installedApp.compareTo(WorkshopVersion.tryParse(m.minApp)!) < 0) return 'workshop_min_app';
    // The server may take larger uploads than this build: such an entry waits
    // for an update instead of making the whole catalog unreadable.
    if (m.size > workshopArchiveBytes) return 'workshop_app_too_old';
    return null;
  }
  Map<String, Object?> toJson() => {'schema': 1, 'generatedAt': generatedAt.toUtc().toIso8601String(), 'features': features.toJson(), 'entries': entries.map((e) => e.toJson()).toList(), 'withdrawn': withdrawn.map((e) => e.toJson()).toList()};
}

class WorkshopPreviewCapabilities {
  WorkshopPreviewCapabilities._(this.sources);
  factory WorkshopPreviewCapabilities.fromJson(Object? value) {
    final m = workshopMap(value), sources = m['sources'];
    if (m['schema'] != 1 || m['format'] != 'png' ||
        m['maxWidth'] != workshopPreviewSide || m['maxHeight'] != workshopPreviewSide ||
        m['maxPixels'] != workshopPreviewPixels || m['maxBytes'] != workshopPreviewBytes ||
        sources is! List || sources.any((source) => !workshopId(source)) ||
        sources.toSet().length != sources.length) {
      workshopInvalid();
    }
    return WorkshopPreviewCapabilities._(Set.unmodifiable(sources.cast<String>()));
  }
  final Set<String> sources;
}

/// Where authors sign in. A null [clientId] means this deployment has not
/// registered a GitHub OAuth App, so nobody can sign in to it yet.
class WorkshopAccountCapabilities {
  WorkshopAccountCapabilities._(this.origin, this.clientId);
  factory WorkshopAccountCapabilities.fromJson(Object? value) {
    final m = workshopMap(value), origin = m['origin'], clientId = m['clientId'];
    if (origin is! String || clientId != null && (clientId is! String ||
        !RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(clientId))) {
      workshopInvalid();
    }
    final parsed = Uri.tryParse(origin);
    if (parsed == null) workshopInvalid();
    return WorkshopAccountCapabilities._(workshopOrigin(parsed), clientId as String?);
  }
  final Uri origin;
  final String? clientId;
}

class WorkshopCapabilities {
  WorkshopCapabilities._(this.features, this.kinds, this.licenses, this.account, this.archiveBytes,
    this.expandedBytes, this.maxMocVersion, this.preview);
  factory WorkshopCapabilities.fromJson(Object? value) {
    final m = workshopMap(value), limits = workshopMap(m['limits']);
    final kinds = m['kinds'], licenses = m['licenses'];
    if (m['schema'] != 1 || kinds is! List || kinds.any((k) => !workshopId(k)) || licenses is! List ||
        licenses.any((k) => !workshopText(k, 100)) || limits['archiveBytes'] is! int ||
        (limits['archiveBytes'] as int) < 1 || limits['expandedBytes'] is! int || (limits['expandedBytes'] as int) < 1 ||
        m['maxMocVersion'] is! int || (m['maxMocVersion'] as int) < 1) {
      workshopInvalid();
    }
    return WorkshopCapabilities._(WorkshopFeatures.fromJson(m['features']), Set.unmodifiable(kinds.cast<String>()), Set.unmodifiable(licenses.cast<String>()),
      WorkshopAccountCapabilities.fromJson(m['account']), limits['archiveBytes'] as int, limits['expandedBytes'] as int, m['maxMocVersion'] as int,
      m.containsKey('preview') ? WorkshopPreviewCapabilities.fromJson(m['preview']) : null);
  }
  final WorkshopFeatures features;
  final Set<String> kinds, licenses;
  final WorkshopAccountCapabilities account;
  final int archiveBytes, expandedBytes, maxMocVersion;
  final WorkshopPreviewCapabilities? preview;
}

enum WorkshopSubmissionStatus { draft, pending, approved, rejected, withdrawn }

class WorkshopSubmission {
  WorkshopSubmission._(this.id, this.metadata, this.status, this.createdAt, this.updatedAt, this.ownerOrigin,
      this.ownerId, this.username, this.reviewReason, this.withdrawalReason, this.preview);
  factory WorkshopSubmission.fromJson(Object? value) {
    final m = workshopMap(value), owner = workshopMap(m['owner']);
    final id = m['submissionId'], status = WorkshopSubmissionStatus.values.asNameMap()[m['status']];
    if (id is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) || status == null ||
        owner['accountId'] is! int || (owner['accountId'] as int) < 1 || !workshopText(owner['username'], 256) || owner['accountOrigin'] is! String) {
      workshopInvalid();
    }
    String? reason(Object? v) {
      if (v == null) return null;
      final r = workshopMap(v)['reason'];
      if (!workshopText(r, 2000)) workshopInvalid();
      return r as String;
    }
    final origin = Uri.tryParse(owner['accountOrigin'] as String);
    if (origin == null) workshopInvalid();
    final metadata = WorkshopMetadata.fromJson(m['metadata']);
    return WorkshopSubmission._(id, metadata, status, workshopTime(m['createdAt']), workshopTime(m['updatedAt']),
      workshopOrigin(origin), owner['accountId'] as int, owner['username'] as String, reason(m['review']), reason(m['withdrawal']),
      m.containsKey('preview') ? WorkshopPreview.fromJson(m['preview'], metadata: metadata) : null);
  }
  final String id;
  final WorkshopMetadata metadata;
  final WorkshopSubmissionStatus status;
  final DateTime createdAt, updatedAt;
  final Uri ownerOrigin;
  final int ownerId;
  final String username;
  final String? reviewReason, withdrawalReason;
  final WorkshopPreview? preview;
}

class WorkshopSubmissionPage {
  const WorkshopSubmissionPage(this.submissions, this.nextCursor);
  final List<WorkshopSubmission> submissions;
  final String? nextCursor;
}
