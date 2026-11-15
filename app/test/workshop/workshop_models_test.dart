import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_repository.dart' show WorkshopPublication;
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  test('optional display metadata keeps the old empty wire shape', () {
    final original = workshopMeta();
    final defaults = WorkshopMetadata.fromJson(original);
    final empty = WorkshopMetadata.fromJson({...original, 'description': '', 'tags': <String>[]});
    expect(defaults.description, '');
    expect(defaults.tags, isEmpty);
    expect(defaults.toJson(), original);
    expect(empty.toJson(), original);
  });

  test('description and raw unique tags survive publication and public round trips without aliases', () {
    final tags = ['Cat', 'cat', 'é', 'e\u0301'];
    final value = {...workshopMeta(), 'description': '  A small companion  ', 'tags': tags};
    final metadata = WorkshopMetadata.fromJson(value), publication = WorkshopPublication(value);
    tags[0] = 'changed later';
    expect(metadata.description, '  A small companion  ');
    expect(metadata.tags, ['Cat', 'cat', 'é', 'e\u0301']);
    expect(publication.withArchive('b' * 64, 7).description, metadata.description);
    expect(publication.withArchive('b' * 64, 7).tags, metadata.tags);
    final entry = WorkshopEntry.fromJson(workshopEntryJson(metadata: metadata.toJson()));
    final restored = WorkshopEntry.fromJson(entry.toJson());
    expect(restored.metadata.description, metadata.description);
    expect(restored.metadata.tags, metadata.tags);
    expect(() => metadata.tags.add('later'), throwsUnsupportedError);
  });

  test('display metadata uses code point bounds, nonblank text and exact tag uniqueness', () {
    final atLimit = {...workshopMeta(), 'description': '🙂' * 512,
      'tags': [for (var i = 0; i < 8; i++) '$i${'猫' * 31}']};
    expect(WorkshopMetadata.fromJson(atLimit).description.runes.length, 512);
    final invalid = <Map<String, Object?>>[
      {'description': '🙂' * 513}, {'description': ' \u0085'}, {'description': null}, {'description': 7},
      {'tags': ['猫' * 33]}, {'tags': List.generate(9, (i) => '$i')}, {'tags': ['same', 'same']},
      {'tags': ['']}, {'tags': [' \u0085']}, {'tags': [7]}, {'tags': null}, {'tags': 'tag'},
    ];
    for (final fields in invalid) {
      expect(() => WorkshopMetadata.fromJson({...workshopMeta(), ...fields}), workshopError('workshop_bad_metadata'));
      expect(() => WorkshopMetadata.fromJson({...workshopMeta(), ...fields}, submission: false), workshopError('workshop_bad_catalog'));
    }
  });

  test('origin values normalize DNS, default ports and ordinary IPv6 without merging different addresses', () {
    const cases = {
      'https://FORUM.example:443/': 'https://forum.example',
      'https://[2001:0db8:0000:0000:0000:0000:0000:0001]:443/': 'https://[2001:db8::1]',
      'https://[2001:0:0:1:0:0:2:3]': 'https://[2001::1:0:0:2:3]',
      'https://[2001:db8:0:1:2:3:4:5]': 'https://[2001:db8:0:1:2:3:4:5]',
      'https://[0:0:0:0:0:0:0:0]': 'https://[::]',
      'https://[0:0:0:0:0:0:0:1]': 'https://[::1]',
      'https://[2001:db8:0:0:0:0:0:0]': 'https://[2001:db8::]',
      'https://[2001:DB8:0:0:0:0:0:1]:8443': 'https://[2001:db8::1]:8443',
      'https://[::ffff:192.0.2.1]': 'https://[::ffff:c000:201]',
    };
    for (final entry in cases.entries) {
      expect(workshopOrigin(Uri.parse(entry.key)).toString(), entry.value);
    }
    expect(workshopOrigin(Uri(scheme: 'https', host: '2001:DB8::1')), Uri.parse('https://[2001:db8::1]'));
    expect(workshopOrigin(Uri.parse('https://[2001:db8::1]')), isNot(workshopOrigin(Uri.parse('https://[2001:db8::2]'))));
  });

  test('origin normalization still applies every existing origin input gate first', () {
    for (final value in ['http://forum.example', 'https://user@forum.example', 'https://forum.example/path',
      'https://forum.example/?query', 'https://forum.example/#fragment']) {
      expect(() => workshopOrigin(Uri.parse(value)), workshopError('workshop_untrusted_origin'));
    }
    expect(() => workshopOrigin(Uri(scheme: 'https')), workshopError('workshop_untrusted_origin'));
  });

  test('unknown kind is retained but cannot be sent to a pet installer', () {
    final catalog = WorkshopCatalog.fromJson(workshopCatalogJson(entries: [workshopEntryJson(metadata: {
      ...workshopMeta(kind: 'wallpaper'), 'size': 40 * 1024 * 1024, 'license': 'LicenseRef-Future-Kind',
    })]));
    expect(catalog.entries.single.metadata.kind, 'wallpaper');
    expect(catalog.entries.single.metadata.size, 40 * 1024 * 1024);
    expect(catalog.unavailable(catalog.entries.single, '1.0.15'), 'workshop_unsupported_kind');
    expect(() => WorkshopMetadata.fromJson(catalog.entries.single.metadata.toJson()), workshopError('workshop_bad_metadata'));
    final big = WorkshopCatalog.fromJson(workshopCatalogJson(entries: [workshopEntryJson(metadata: {...workshopMeta(), 'size': 60 * 1024 * 1024})]));
    expect(big.unavailable(big.entries.single, '1.0.15'), 'workshop_app_too_old');
    final split = WorkshopCatalog.fromJson({
      ...workshopCatalogJson(entries: []),
      'largeEntries': [workshopEntryJson(metadata: {...workshopMeta(), 'size': 30 * 1024 * 1024})],
    });
    expect(split.entries.single.metadata.size, 30 * 1024 * 1024);
    expect(split.unavailable(split.entries.single, '1.0.15'), isNull);
    expect(() => WorkshopCatalog.fromJson({...workshopCatalogJson(entries: []), 'largeEntries': 1}), workshopError('workshop_bad_catalog'));
    expect(() => WorkshopMetadata.fromJson({...workshopMeta(), 'size': 60 * 1024 * 1024}), workshopError('workshop_bad_metadata'));
  });

  test('minApp, companion switch and withdrawals have stable independent gates', () {
    final entry = workshopEntryJson(metadata: workshopMeta(kind: 'companion', minApp: '1.1.0'));
    var catalog = WorkshopCatalog.fromJson(workshopCatalogJson(entries: [entry]));
    expect(catalog.unavailable(catalog.entries.single, '1.0.15+123'), 'workshop_min_app');
    expect(catalog.unavailable(catalog.entries.single, '1.1.0'), isNull);
    catalog = WorkshopCatalog.fromJson(workshopCatalogJson(entries: [entry], companion: false));
    expect(catalog.unavailable(catalog.entries.single, '1.1.0'), 'workshop_companion_disabled');
    catalog = WorkshopCatalog.fromJson(workshopCatalogJson(entries: [{...entry, 'blockedVersions': ['1.0.0']}]));
    expect(catalog.blocked('companion', 'cat', '1.0.0'), isTrue);
    expect(catalog.unavailable(catalog.entries.single, '1.1.0'), 'workshop_version_withdrawn');
  });

  test('URLs are exact content-addressed paths, not remote links or alternate hashes', () {
    for (final url in ['https://elsewhere.example/file.zip', '//elsewhere.example/file.zip', '/market/workshop/pet/cat/1.0.0/bad.zip']) {
      expect(() => WorkshopEntry.fromJson({...workshopEntryJson(), 'url': url}), throwsA(isA<WorkshopException>()));
    }
  });

  test('public metadata and publication reject raw whitespace in source URLs', () {
    for (final source in ['https://source.example/path value', 'https://source.example/path\u00a0value']) {
      final value = {...workshopMeta(), 'source': source};
      expect(() => WorkshopMetadata.fromJson(value), workshopError('workshop_bad_metadata'));
      expect(() => WorkshopPublication(value), workshopError('workshop_bad_metadata'));
    }
  });

  test('encoded source URLs keep exactly the same bytes through public metadata', () {
    for (final source in ['https://source.example/path%20value', 'https://source.example/path%C2%A0value']) {
      final value = {...workshopMeta(), 'source': source};
      final metadata = WorkshopMetadata.fromJson(value), publication = WorkshopPublication(value);
      expect(metadata.source, source);
      expect(metadata.toJson()['source'], source);
      expect(publication.source, source);
      expect(publication.withArchive('a' * 64, 17).toJson()['source'], source);
    }
  });

  test('metadata and withdrawal reasons reject text containing only trim whitespace', () {
    for (final value in ['', ' ', '\u00a0', '\u0085', ' \u0085\u00a0', '\ufeff\u0085']) {
      expect(workshopText(value, 120), isFalse);
      expect(workshopText(value, 2000), isFalse);
      final metadata = {...workshopMeta(), 'title': {'zh': value, 'en': 'Cat'}};
      expect(() => WorkshopMetadata.fromJson(metadata), workshopError('workshop_bad_metadata'));
      expect(() => WorkshopMetadata.fromJson({...workshopMeta(), 'author': value}), workshopError('workshop_bad_metadata'));
      expect(() => WorkshopEntry.fromJson(workshopEntryJson(metadata: metadata)), workshopError('workshop_bad_catalog'));
      expect(() => WorkshopWithdrawal.fromJson({
        'kind': 'pet', 'id': 'cat', 'version': '1.0.0', 'reason': value, 'at': workshopTestDate,
      }), workshopError('workshop_bad_catalog'));
    }
  });

  test('nonblank metadata retains surrounding next-line characters exactly', () {
    const original = '\u0085示例\u0085';
    final value = {...workshopMeta(), 'title': {'zh': original, 'en': original}, 'author': original};
    final metadata = WorkshopMetadata.fromJson(value);
    expect(workshopText(original, 120), isTrue);
    expect(metadata.title['zh'], original);
    expect(metadata.title['en'], original);
    expect(metadata.author, original);
    expect(metadata.toJson(), value);
  });

  test('duplicate identities, malformed timestamps and source credentials are rejected', () {
    expect(() => WorkshopCatalog.fromJson(workshopCatalogJson(entries: [workshopEntryJson(), workshopEntryJson()])), throwsA(isA<WorkshopException>()));
    expect(() => WorkshopCatalog.fromJson(workshopCatalogJson(at: '2026-02-31T00:00:00.000Z')), throwsA(isA<WorkshopException>()));
    expect(() => WorkshopMetadata.fromJson({...workshopMeta(), 'source': 'https://user:secret@source.example'}), throwsA(isA<WorkshopException>()));
  });

  test('SemVer ordering is exact even above int64 and build metadata is not a release', () {
    const versions = ['1.0.0-alpha', '1.0.0-alpha.1', '1.0.0-alpha.beta', '1.0.0-beta', '1.0.0-beta.2', '1.0.0-beta.11', '1.0.0-rc.1', '1.0.0', '2.0.0'];
    for (var i = 1; i < versions.length; i++) {
      expect(WorkshopVersion.tryParse(versions[i])!.compareTo(WorkshopVersion.tryParse(versions[i - 1])!), greaterThan(0));
    }
    expect(WorkshopVersion.tryParse('999999999999999999999.0.0')!.compareTo(WorkshopVersion.tryParse('1000000000000000000000.0.0')!), lessThan(0));
    for (final bad in ['1.0', '01.0.0', '1.0.0+1', '1.0.0-01', '1.0.0-a..b']) { expect(WorkshopVersion.tryParse(bad), isNull); }
  });

  test('every author status and its review/withdrawal reason survives parsing', () {
    for (final status in WorkshopSubmissionStatus.values) {
      final row = WorkshopSubmission.fromJson(workshopSubmissionJson(status: status.name));
      expect(row.status, status);
      if (status == WorkshopSubmissionStatus.rejected) expect(row.reviewReason, 'review reason');
      if (status == WorkshopSubmissionStatus.withdrawn) expect(row.withdrawalReason, 'author withdrew');
    }
  });
}
