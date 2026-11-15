import 'package:dsh_app/state/workshop_publication.dart';
import 'package:dsh_app/state/workshop_publish_sources.dart';
import 'package:flutter_test/flutter_test.dart';

WorkshopPublicationInput _valid() => WorkshopPublicationInput(
  id: 'cat', titleZh: '小猫', titleEn: 'Cat', author: 'Author',
  license: 'CC0-1.0', source: 'https://source.example/cat',
);

void main() {
  test('new input has explicit rights failure and field codes without user prose', () {
    final empty = WorkshopPublicationInput().errors();
    expect(empty.keys, containsAll(['id', 'titleZh', 'titleEn', 'author', 'license', 'source', 'rightsConfirmed']));
    expect(empty.values.every((code) => code.startsWith('workshop_')), isTrue);
    expect(_valid().errors(), {'rightsConfirmed': 'workshop_rights_required'});
    expect(_valid().errors(includeRights: false), isEmpty);
    expect(_valid().copyWith(rightsConfirmed: true).errors(), isEmpty);
  });

  test('description and tag bounds use exact strings and Unicode code points', () {
    final tags = [for (var i = 0; i < 8; i++) '$i${'猫' * 31}'];
    final input = _valid().copyWith(description: '🙂' * 512, tags: tags);
    tags[0] = 'changed';
    expect(input.tags.first, '0${'猫' * 31}');
    expect(input.errors(includeRights: false), isEmpty);
    expect(() => input.tags.add('later'), throwsUnsupportedError);
    expect(input.copyWith(description: '🙂' * 513).errors()['description'], 'workshop_bad_description');
    expect(input.copyWith(description: '\n').errors()['description'], 'workshop_bad_description');
    for (final invalid in [<String>['same', 'same'], [''], ['猫' * 33], List.generate(9, (i) => '$i')]) {
      expect(input.copyWith(tags: invalid).errors()['tags'], 'workshop_bad_tags');
    }
    expect(input.copyWith(tags: ['Cat', 'cat', 'é', 'e\u0301']).errors(includeRights: false), isEmpty);
  });

  test('publication adds archive identity later and retains display metadata', () {
    final input = _valid().copyWith(description: 'Description', tags: ['cat']);
    final declaration = input.declaration('pet');
    expect(declaration.containsKey('sha256'), isFalse);
    expect(declaration.containsKey('size'), isFalse);
    expect(declaration.containsKey('rightsConfirmed'), isFalse);
    final metadata = input.publication('pet').withArchive('a' * 64, 4);
    expect(metadata.description, 'Description');
    expect(metadata.tags, ['cat']);
    expect(metadata.sha256, 'a' * 64);
    expect(metadata.size, 4);
    expect(_valid().declaration('pet').containsKey('description'), isFalse);
    expect(_valid().declaration('pet').containsKey('tags'), isFalse);
  });

  test('invalid metadata stays in its field and copied input retains unedited values', () {
    final invalid = _valid().copyWith(id: '../bad', version: 'future', minApp: '',
      titleZh: ' ', author: '', license: 'unknown', source: 'http://source.example');
    expect(invalid.errors(includeRights: false).keys,
      containsAll(['id', 'version', 'minApp', 'titleZh', 'author', 'license', 'source']));
    expect(invalid.titleEn, 'Cat');
  });

  test('restoring original confirmed metadata does not create a new unchecked intent', () {
    final metadata = _valid().copyWith(description: 'Original', tags: ['original'])
      .publication('pet').withArchive('a' * 64, 4);
    final restored = WorkshopPublicationInput.fromMetadata(metadata);
    expect(restored.rightsConfirmed, isTrue);
    expect(restored.errors(), isEmpty);
    expect(restored.description, 'Original');
    expect(restored.tags, ['original']);
    expect(restored.publication('pet').withArchive(metadata.sha256, metadata.size).toJson(), metadata.toJson());
  });

  test('source prefill uses public pack attribution and never copies a companion name', () {
    final pet = const WorkshopPublishSource(kind: 'pet', localId: 'user-cat', name: 'Cat',
      author: 'Author', license: 'CC0-1.0', source: 'https://source.example/cat').initialInput();
    expect(pet.id, 'cat');
    expect(pet.titleZh, 'Cat');
    expect(pet.rightsConfirmed, isFalse);
    final companion = const WorkshopPublishSource(kind: 'companion', localId: 'companion',
      name: 'Private nickname', author: 'Author').initialInput();
    expect(companion.titleZh, isEmpty);
    expect(companion.titleEn, isEmpty);
    expect(companion.author, 'Author');
    expect(companion.rightsConfirmed, isFalse);
  });

  test('only a name is needed: the rest is filled from the account, typed values stay', () {
    final filled = WorkshopPublicationInput(titleZh: '小猫 Cat').withDefaults(login: 'octo', fallbackId: 'pet-abc123');
    expect(filled.titleEn, '小猫 Cat');
    expect(filled.id, 'cat');
    expect(filled.author, 'octo');
    expect(filled.license, 'LicenseRef-Author-Permission');
    expect(filled.source, 'https://github.com/octo');
    expect(filled.version, '1.0.0');
    expect(filled.errors(includeRights: false), isEmpty);
    expect(WorkshopPublicationInput(titleEn: '我的猫').withDefaults(login: 'octo', fallbackId: 'pet-abc123').id, 'pet-abc123');
    expect(_valid().withDefaults(login: 'octo', fallbackId: 'x').errors(includeRights: false), isEmpty);
    expect(_valid().withDefaults(login: 'octo', fallbackId: 'x').source, 'https://source.example/cat');
    // Without an account the author and source still have to be typed.
    expect(WorkshopPublicationInput(titleZh: '猫').withDefaults(fallbackId: 'pet-1').errors(includeRights: false).keys,
      containsAll(['author', 'source']));
    expect(WorkshopPublicationInput(titleZh: '猫', id: 'Bad Id').withDefaults(login: 'o', fallbackId: 'p').errors(includeRights: false).keys,
      contains('id'));
  });
}
