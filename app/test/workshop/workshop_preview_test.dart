import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/update/update_http.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_repository.dart' show WorkshopPublication;
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Map<String, Object?> _previewContract({List<String> sources = const ['pet-idle', 'companion-preview']}) => {
  'schema': 1, 'sources': sources, 'format': 'png',
  'maxWidth': 512, 'maxHeight': 512, 'maxPixels': 262144, 'maxBytes': 2097152,
};

Map<String, Object?> _previewJson(Map<String, Object?> metadata) {
  final hash = 'b' * 64;
  return {
    'path': '/market/workshop/${metadata['kind']}/${metadata['id']}/${metadata['version']}/${metadata['sha256']}/preview/$hash.png',
    'sha256': hash, 'size': 91, 'width': 2, 'height': 3,
  };
}

Map<String, Object?> _previewEntry() {
  final metadata = {...workshopMeta(), 'previewSource': 'pet-idle'};
  return {...workshopEntryJson(metadata: metadata), 'preview': _previewJson(metadata)};
}

Matcher _notSent(String code) => throwsA(isA<WorkshopException>()
  .having((error) => error.code, 'code', code)
  .having((error) => error.mutationNotSent, 'mutationNotSent', isTrue)
  .having((error) => error.resultUnknown, 'resultUnknown', isFalse));

void main() {
  test('old metadata, entries, submissions and capabilities keep absent preview fields', () {
    final original = workshopMeta();
    final metadata = WorkshopMetadata.fromJson(original);
    expect(metadata.previewSource, isNull);
    expect(metadata.toJson(), original);
    final entry = WorkshopEntry.fromJson(workshopEntryJson());
    expect(entry.preview, isNull);
    expect(entry.toJson().containsKey('preview'), isFalse);
    expect(entry.toJson().containsKey('previewSource'), isFalse);
    expect(WorkshopSubmission.fromJson(workshopSubmissionJson()).preview, isNull);
    expect(WorkshopCapabilities.fromJson(workshopCaps()).preview, isNull);
  });

  test('preview source is a kind-bound declaration preserved through publication and metadata', () {
    for (final pair in {'pet': 'pet-idle', 'companion': 'companion-preview'}.entries) {
      final value = {...workshopMeta(kind: pair.key), 'previewSource': pair.value};
      final metadata = WorkshopMetadata.fromJson(value);
      expect(metadata.previewSource, pair.value);
      expect(metadata.source, 'https://source.example/cat');
      expect(metadata.toJson(), value);
      expect(WorkshopMetadata.fromJson(metadata.toJson()).previewSource, pair.value);
      expect(WorkshopPublication(value).withArchive('c' * 64, 8).previewSource, pair.value);
      final public = WorkshopEntry.fromJson(workshopEntryJson(metadata: value));
      expect(public.metadata.previewSource, pair.value);
      expect(WorkshopEntry.fromJson(public.toJson()).metadata.previewSource, pair.value);
    }
  });

  test('known kinds reject mismatched, null and unknown source declarations', () {
    for (final pair in {'pet': 'companion-preview', 'companion': 'pet-idle'}.entries) {
      for (final mode in <Object?>[pair.value, null, '', 'future-preview', 7]) {
        final value = {...workshopMeta(kind: pair.key), 'previewSource': mode};
        expect(() => WorkshopMetadata.fromJson(value), workshopError('workshop_bad_metadata'));
        expect(() => WorkshopMetadata.fromJson(value, submission: false), workshopError('workshop_bad_catalog'));
      }
    }
  });

  test('unknown public kinds retain their unsupported projection without interpreting a future mode', () {
    final catalog = WorkshopCatalog.fromJson(workshopCatalogJson(entries: [workshopEntryJson(metadata: {
      ...workshopMeta(kind: 'wallpaper'), 'size': 40 * 1024 * 1024,
      'license': 'LicenseRef-Future-Kind', 'previewSource': 'wallpaper-first-page',
    })]));
    final entry = catalog.entries.single;
    expect(entry.metadata.kind, 'wallpaper');
    expect(entry.metadata.previewSource, isNull);
    expect(catalog.unavailable(entry, '2.0.0'), 'workshop_unsupported_kind');
    expect(() => WorkshopMetadata.fromJson(entry.metadata.toJson()), workshopError('workshop_bad_metadata'));
  });

  test('public entries and submissions parse the same registered five-field descriptor', () {
    final value = _previewEntry();
    final entry = WorkshopEntry.fromJson(value);
    final preview = entry.preview!;
    expect(preview.path, (value['preview'] as Map)['path']);
    expect(preview.sha256, 'b' * 64);
    expect((preview.size, preview.width, preview.height), (91, 2, 3));
    expect(preview.toJson(), value['preview']);
    final restored = WorkshopEntry.fromJson(entry.toJson());
    expect(restored.preview!.toJson(), preview.toJson());
    final submission = WorkshopSubmission.fromJson({
      ...workshopSubmissionJson(status: 'pending', metadata: entry.metadata.toJson()),
      'preview': value['preview'],
    });
    expect(submission.preview!.toJson(), preview.toJson());
    expect(submission.metadata.previewSource, 'pet-idle');
  });

  test('unknown public kinds ignore a future preview shape while known kinds still reject it', () {
    final futurePreview = {'format': 'webp', 'asset': 'cover', 'width': 1024};
    final catalog = WorkshopCatalog.fromJson(workshopCatalogJson(entries: [{
      ...workshopEntryJson(metadata: workshopMeta(kind: 'wallpaper')),
      'preview': futurePreview,
    }]));
    final entry = catalog.entries.single;
    expect(entry.metadata.title['zh'], '小猫');
    expect(entry.preview, isNull);
    expect(entry.toJson().containsKey('preview'), isFalse);
    expect(catalog.unavailable(entry, '2.0.0'), 'workshop_unsupported_kind');
    expect(() => WorkshopEntry.fromJson({...workshopEntryJson(), 'preview': futurePreview}),
      workshopError('workshop_bad_response'));
  });

  test('preview dimensions and byte lengths enforce the exact descriptor bounds', () {
    final metadata = WorkshopMetadata.fromJson(workshopMeta());
    final valid = {..._previewJson(metadata.toJson()), 'width': 512, 'height': 512, 'size': 2097152};
    expect(WorkshopPreview.fromJson(valid, metadata: metadata).size, 2097152);
    for (final fields in <Map<String, Object?>>[
      {'width': 0}, {'width': 513}, {'width': 1.5}, {'height': 0}, {'height': 513},
      {'size': 0}, {'size': 2097153}, {'size': 91.5}, {'sha256': 'B' * 64},
    ]) {
      expect(() => WorkshopPreview.fromJson({...valid, ...fields}, metadata: metadata),
        workshopError('workshop_bad_response'));
    }
    expect(() => WorkshopEntry.fromJson({...workshopEntryJson(), 'preview': null}),
      workshopError('workshop_bad_response'));
  });

  test('preview paths cannot change origin, release, archive hash or image hash', () {
    final metadata = WorkshopMetadata.fromJson(workshopMeta());
    final value = _previewJson(metadata.toJson());
    final path = value['path'] as String;
    for (final candidate in [
      'https://elsewhere.example$path', '//elsewhere.example$path', '$path?download=1', '$path#image',
      path.replaceFirst('/pet/cat/', '/pet/another-cat/'),
      path.replaceFirst('/1.0.0/', '/2.0.0/'),
      path.replaceFirst(metadata.sha256, 'c' * 64),
      path.replaceFirst('b' * 64, 'c' * 64),
    ]) {
      expect(() => WorkshopPreview.fromJson({...value, 'path': candidate}, metadata: metadata),
        workshopError('workshop_bad_response'));
    }
  });

  test('preview capability is optional but a present v1 contract is checked completely', () {
    final caps = WorkshopCapabilities.fromJson({...workshopCaps(), 'preview': _previewContract()});
    expect(caps.preview!.sources, {'pet-idle', 'companion-preview'});
    expect(() => caps.preview!.sources.add('later'), throwsUnsupportedError);
    for (final fields in <Map<String, Object?>>[
      {'schema': 2}, {'format': 'jpeg'}, {'maxWidth': 513}, {'maxHeight': 513},
      {'maxPixels': 262145}, {'maxBytes': 2097153},
      {'sources': ['pet-idle', 'pet-idle']}, {'sources': [7]},
    ]) {
      expect(() => WorkshopCapabilities.fromJson({
        ...workshopCaps(), 'preview': {..._previewContract(), ...fields},
      }), workshopError('workshop_bad_response'));
    }
  });

  test('pet idle downscaling requires an explicitly advertised boolean true', () {
    WorkshopPreviewCapabilities parse(Map<String, Object?> fields) => WorkshopCapabilities.fromJson({
      ...workshopCaps(), 'preview': {..._previewContract(), ...fields},
    }).preview!;

    expect(parse({}).petIdleDownscale, isFalse);
    for (final value in <Object?>[false, null, 'true', 1]) {
      expect(parse({'petIdleDownscale': value}).petIdleDownscale, isFalse);
    }
    expect(parse({'petIdleDownscale': true}).petIdleDownscale, isTrue);
  });

  group('real client with controlled HTTP and private cache', () {
    late Directory temporary;
    late FakeWorkshopHttp http;
    late WorkshopClient client;
    late WorkshopCredential credential;

    setUp(() {
      temporary = Directory.systemTemp.createTempSync('workshop-preview');
      http = FakeWorkshopHttp((_, _, _, _) => throw StateError('unexpected request'));
      client = WorkshopClient(origin: workshopTestOrigin,
        cacheFile: File('${temporary.path}/catalog.json'), http: http);
      credential = WorkshopCredential.forConsentedWorker(worker: workshopTestOrigin,
        account: workshopTestAccount, token: 'synthetic_preview_token', disclosureAccepted: true);
    });
    tearDown(() => temporary.deleteSync(recursive: true));

    void legacyCache({List<Object?> withdrawn = const []}) {
      client.cacheFile.writeAsStringSync(jsonEncode({
        'schema': 1, 'origin': workshopTestOrigin.toString(), 'etag': '"preview-current"',
        'fetchedAt': workshopTestDate, 'catalog': workshopCatalogJson(withdrawn: withdrawn),
      }));
    }

    test('public URI uses the current normalized origin without HTTP or identity', () {
      final current = WorkshopClient(origin: Uri.parse('https://WORKSHOP.example:8443/'),
        cacheFile: client.cacheFile, http: http);
      final entry = WorkshopEntry.fromJson(_previewEntry());
      expect(current.publicPreviewUri(entry), Uri.parse('https://workshop.example:8443${entry.preview!.path}'));
      expect(client.publicPreviewUri(entry), Uri.parse('https://workshop.example${entry.preview!.path}'));
      expect(client.publicPreviewUri(WorkshopEntry.fromJson(workshopEntryJson())), isNull);
      expect(http.requests, isEmpty);
    });

    test('an old Worker still accepts a create with no preview declaration', () async {
      http.route = (method, _, _, body) {
        if (method == 'GET') return workshopJsonResponse(workshopCaps());
        expect((jsonDecode(utf8.decode(body!)) as Map).containsKey('previewSource'), isFalse);
        return workshopJsonResponse({'submission': workshopSubmissionJson()}, status: 201);
      };
      final row = await client.createSubmission(WorkshopMetadata.fromJson(workshopMeta()),
        requestId: workshopTestId, rightsConfirmed: true, credential: credential);
      expect(row.metadata.previewSource, isNull);
      expect(http.requests.where((request) => request.method == 'POST').length, 1);
    });

    test('absent or missing-mode preview capability refuses before the create POST', () async {
      final metadata = WorkshopMetadata.fromJson({...workshopMeta(), 'previewSource': 'pet-idle'});
      for (final caps in [
        workshopCaps(),
        {...workshopCaps(), 'preview': _previewContract(sources: ['companion-preview'])},
      ]) {
        http.route = (_, _, _, _) => workshopJsonResponse(caps);
        await expectLater(client.createSubmission(metadata, requestId: workshopTestId,
          rightsConfirmed: true, credential: credential), _notSent('workshop_preview_unsupported'));
      }
      expect(http.requests.map((request) => request.method), ['GET', 'GET']);
    });

    test('create sends the requested mode and accepts the unchanged declaration', () async {
      final metadata = WorkshopMetadata.fromJson({...workshopMeta(), 'previewSource': 'pet-idle'});
      http.route = (method, _, _, body) {
        if (method == 'GET') return workshopJsonResponse({...workshopCaps(), 'preview': _previewContract()});
        final sent = jsonDecode(utf8.decode(body!)) as Map;
        expect(sent['previewSource'], 'pet-idle');
        expect(sent['source'], metadata.source);
        return workshopJsonResponse({'submission': workshopSubmissionJson(metadata: metadata.toJson())}, status: 201);
      };
      final row = await client.createSubmission(metadata, requestId: workshopTestId,
        rightsConfirmed: true, credential: credential);
      expect(row.metadata.previewSource, 'pet-idle');
      expect(row.preview, isNull, reason: 'the create response is still a draft, before archive validation');
      expect(http.requests.where((request) => request.method == 'POST').length, 1);
    });

    test('a create response that drops the mode is unknown after exactly one POST', () async {
      final metadata = WorkshopMetadata.fromJson({...workshopMeta(), 'previewSource': 'pet-idle'});
      http.route = (method, _, _, _) => method == 'GET'
        ? workshopJsonResponse({...workshopCaps(), 'preview': _previewContract()})
        : workshopJsonResponse({'submission': workshopSubmissionJson()}, status: 201);
      await expectLater(client.createSubmission(metadata, requestId: workshopTestId,
        rightsConfirmed: true, credential: credential), throwsA(isA<WorkshopException>()
          .having((error) => error.code, 'code', 'workshop_bad_response')
          .having((error) => error.resultUnknown, 'resultUnknown', isTrue)
          .having((error) => error.mutationNotSent, 'mutationNotSent', isFalse)));
      expect(http.requests.where((request) => request.method == 'POST').length, 1);
    });

    test('legacy lossy text is shown first, then refresh omits its ETag and restores preview fields', () async {
      legacyCache();
      final cached = (await client.cachedCatalog())!;
      expect(cached.stale, isTrue);
      expect(cached.catalog.entries.single.preview, isNull);
      expect(cached.catalog.entries.single.metadata.title['zh'], '小猫');
      expect(http.requests, isEmpty);
      http.route = (_, _, headers, _) {
        expect(headers.containsKey('if-none-match'), isFalse);
        return workshopJsonResponse(workshopCatalogJson(entries: [_previewEntry()]),
          headers: {'etag': '"preview-current"'});
      };
      final fresh = await client.catalog(requireFresh: true);
      expect(fresh.stale, isFalse);
      expect(fresh.catalog.entries.single.preview, isNotNull);
      expect(fresh.catalog.entries.single.metadata.previewSource, 'pet-idle');
      final disk = jsonDecode(client.cacheFile.readAsStringSync()) as Map;
      expect(disk['schema'], 1);
      expect(disk['previewSchema'], 1);
      expect(disk['etag'], '"preview-current"');

      final restoredFile = client.cacheFile.copySync('${temporary.path}/restart.json');
      final restarted = WorkshopClient(origin: workshopTestOrigin, cacheFile: restoredFile, http: http);
      http.route = (_, _, headers, _) {
        expect(headers['if-none-match'], '"preview-current"');
        return UpdateHttpResponse(status: 304, body: const Stream.empty());
      };
      final restored = await restarted.catalog(requireFresh: true);
      expect(restored.catalog.entries.single.preview!.toJson(), fresh.catalog.entries.single.preview!.toJson());
      expect(restored.catalog.entries.single.metadata.previewSource, 'pet-idle');
    });

    test('an unsolicited 304 cannot mark a legacy lossy copy as upgraded', () async {
      legacyCache();
      http.route = (_, _, headers, _) {
        expect(headers.containsKey('if-none-match'), isFalse);
        return UpdateHttpResponse(status: 304, body: const Stream.empty());
      };
      final fallback = await client.catalog();
      expect(fallback.stale, isTrue);
      expect(fallback.refreshError?.code, 'workshop_bad_catalog');
      expect(fallback.catalog.entries.single.metadata.id, 'cat');
      expect((jsonDecode(client.cacheFile.readAsStringSync()) as Map).containsKey('previewSchema'), isFalse);
      await expectLater(client.catalog(requireFresh: true), workshopError('workshop_bad_catalog'));
    });

    test('a current cache for a legitimate entry without an image continues to use 304', () async {
      http.route = (_, _, _, _) => workshopJsonResponse(workshopCatalogJson(), headers: {'etag': '"no-image"'});
      final first = await client.catalog(requireFresh: true);
      expect(first.catalog.entries.single.preview, isNull);
      http.route = (_, _, headers, _) {
        expect(headers['if-none-match'], '"no-image"');
        return UpdateHttpResponse(status: 304, body: const Stream.empty());
      };
      final next = await client.catalog(requireFresh: true);
      expect(next.stale, isFalse);
      expect(next.catalog.entries.single.preview, isNull);
      expect(http.requests.length, 2);
    });

    test('dropping the legacy ETag does not drop its known withdrawal history', () async {
      final withdrawal = {'kind': 'pet', 'id': 'cat', 'version': '0.9.0',
        'reason': '作者撤回旧版', 'at': workshopTestDate};
      legacyCache(withdrawn: [withdrawal]);
      http.route = (_, _, headers, _) {
        expect(headers.containsKey('if-none-match'), isFalse);
        return workshopJsonResponse(workshopCatalogJson(entries: [_previewEntry()]),
          headers: {'etag': '"preview-current"'});
      };
      await expectLater(client.catalog(requireFresh: true), workshopError('workshop_catalog_rollback'));
      expect((await client.cachedCatalog())!.catalog.blocked('pet', 'cat', '0.9.0'), isTrue);
      http.route = (_, _, headers, _) {
        expect(headers.containsKey('if-none-match'), isFalse);
        return workshopJsonResponse(workshopCatalogJson(entries: [_previewEntry()], withdrawn: [withdrawal]),
          headers: {'etag': '"preview-current"'});
      };
      expect((await client.catalog(requireFresh: true)).catalog.entries.single.preview, isNotNull);
    });
  });
}
