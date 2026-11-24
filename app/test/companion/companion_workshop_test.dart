import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/pets/pet_library.dart';
import 'package:dsh_app/workshop/workshop_receipt.dart';
import 'package:dsh_app/workshop/workshop_repository.dart'
    show LocalWorkshopPackages, WorkshopInstalled, workshopLocalError;
import 'package:flutter_test/flutter_test.dart';

import '../workshop/support.dart';

/// Real file IO with one controllable write/close failure. ArchiveFile and
/// OutputFileStream still execute their ordinary extraction/buffering paths.
class _ExtractionHandle extends AbstractFileHandle {
  _ExtractionHandle(String path, {this.writeFailure, this.closeFailure})
      : delegate = FileHandle(path, mode: FileAccess.write);
  final AbstractFileHandle delegate;
  final Object? writeFailure;
  final Object? closeFailure;
  int writeCalls = 0, closeCalls = 0, written = 0;
  static final writeStack = StackTrace.fromString('7153 extraction write boundary');
  static final closeStack = StackTrace.fromString('7153 extraction close boundary');

  @override int get position => delegate.position;
  @override set position(int value) => delegate.position = value;
  @override int get length => delegate.length;
  @override bool get isOpen => delegate.isOpen;
  @override int readInto(Uint8List buffer, [int? length]) => delegate.readInto(buffer, length);
  @override void closeSync() => delegate.closeSync();
  @override Future<void> close() async {
    closeCalls++;
    await delegate.close();
    if (closeFailure != null) Error.throwWithStackTrace(closeFailure!, closeStack);
  }
  @override void writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    writeCalls++;
    final count = (end ?? buffer.length) - start;
    if (writeFailure != null) {
      final partial = count < 7 ? count : 7;
      delegate.writeFromSync(buffer, start, start + partial);
      written += partial;
      Error.throwWithStackTrace(writeFailure!, writeStack);
    }
    delegate.writeFromSync(buffer, start, end);
    written += count;
  }
}

Map<String, String> _packBytes(Directory root) => {
  for (final file in root.listSync(recursive: true).whereType<File>())
    file.path.substring(root.path.length): base64Encode(file.readAsBytesSync()),
};

void main() {
  late Directory temp;
  late CompanionPackStore store;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('companion-workshop');
    store = CompanionPackStore(Directory('${temp.path}/home'), expectedRuntime: workshopRuntimeDigest());
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<void> seed() => store.install(workshopZip(temp, {...workshopRuntime(), ...workshopCharacter()}).path);
  WorkshopReceipt receipt({String id = 'cat', String version = '1.0.0', String? hash}) => WorkshopReceipt(kind: 'companion', id: id,
    version: version, sha256: hash ?? 'a' * 64, origin: workshopTestOrigin);

  Future<(CompanionPackException, StackTrace, _ExtractionHandle)> failedExtraction({
    Object? writeFailure, Object? closeFailure,
  }) async {
    await seed();
    await store.install(workshopZip(temp, workshopCharacter()).path,
      workshop: receipt(), replaceExisting: true);
    final before = _packBytes(store.pack);
    final oldReceipt = File('${store.pack.path}/$workshopReceiptName').readAsBytesSync();
    final archive = Archive();
    // A normal STORE member of exactly one output-buffer size exercises the
    // direct-write path: after its failure close has no buffered retry.
    final body = Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, 65);
    archive.add(ArchiveFile.noCompress('character/LICENSE.txt', body.length, body));
    for (final entry in workshopCharacter(name: 'Replacement').entries) {
      if (entry.key != 'character/LICENSE.txt') {
        archive.add(ArchiveFile.noCompress(entry.key, entry.value.length, entry.value));
      }
    }
    final zip = File('${temp.path}/extract-fault.zip')..writeAsBytesSync(ZipEncoder().encode(archive));
    late _ExtractionHandle handle;
    final failing = CompanionPackStore.withOutputForTesting(store.root, expectedRuntime: workshopRuntimeDigest(),
      openOutput: (path) {
        if (!path.endsWith('/character/LICENSE.txt')) return OutputFileStream(path);
        handle = _ExtractionHandle(path, writeFailure: writeFailure, closeFailure: closeFailure);
        return OutputFileStream.withFileHandle(handle);
      });
    CompanionPackException? caught;
    StackTrace? caughtStack;
    try {
      await failing.install(zip.path, workshop: receipt(version: '1.1.0', hash: 'b' * 64));
    } on CompanionPackException catch (error, stack) {
      caught = error;
      caughtStack = stack;
    }
    expect(caught, isNotNull, reason: 'the injected extraction failure must abort the real transaction');
    expect(handle.writeCalls, 1);
    expect(handle.closeCalls, 1);
    expect(handle.isOpen, isFalse);
    expect(_packBytes(store.pack), before, reason: 'every old resource and receipt byte stays intact');
    expect(File('${store.pack.path}/$workshopReceiptName').readAsBytesSync(), oldReceipt);
    expect(Directory('${store.root.path}/pack.staging').existsSync(), isFalse);
    expect(Directory('${store.root.path}/pack.previous').existsSync(), isFalse);
    // A new normal store observes the same old identity after failure.
    final restarted = CompanionPackStore(store.root, expectedRuntime: workshopRuntimeDigest());
    expect((await restarted.workshopReceipt())!.same(receipt()), isTrue);
    expect(await restarted.unavailableReason(), isNull);
    return (caught!, caughtStack!, handle);
  }

  test('real ArchiveFile write failure preserves storage errno, stack and the installed receipt', () async {
    for (final code in [28, 5]) {
      final (error, stack, handle) = await failedExtraction(
        writeFailure: FileSystemException('injected write failure', 'synthetic', OSError('write failed', code)));
      expect(error.problem, CompanionPackProblem.storage);
      expect(error.osErrorCode, code);
      expect(stack.toString(), contains('7153 extraction write boundary'));
      expect(workshopLocalError(error).code, code == 28 ? 'workshop_no_space' : 'workshop_storage');
      expect(handle.written, 7, reason: 'partial bytes were really written before the injected error');
    }
  });

  test('cleanup close failure cannot replace the primary extraction error', () async {
    final (error, stack, handle) = await failedExtraction(
      writeFailure: const FileSystemException('write failed', 'synthetic', OSError('no space', 28)),
      closeFailure: const FileSystemException('close failed', 'synthetic', OSError('IO error', 5)));
    expect(error.problem, CompanionPackProblem.storage);
    expect(error.osErrorCode, 28);
    expect(stack.toString(), contains('7153 extraction write boundary'));
    expect(workshopLocalError(error).code, 'workshop_no_space');
    expect(handle.written, 7);
  });

  test('successful extraction followed by close failure remains a storage failure', () async {
    final (error, stack, handle) = await failedExtraction(
      closeFailure: const FileSystemException('close failed', 'synthetic', OSError('no space', 28)));
    expect(error.problem, CompanionPackProblem.storage);
    expect(error.osErrorCode, 28);
    expect(stack.toString(), contains('7153 extraction close boundary'));
    expect(workshopLocalError(error).code, 'workshop_no_space');
    expect(handle.written, 1024 * 1024);
  });

  test('a non-storage extraction error stays notAPack when cleanup also fails', () async {
    final (error, stack, _) = await failedExtraction(
      writeFailure: ArchivePasswordException('injected invalid archive password'),
      closeFailure: const FileSystemException('close failed', 'synthetic', OSError('no space', 28)));
    expect(error.problem, CompanionPackProblem.notAPack);
    expect(error.osErrorCode, isNull);
    expect(stack.toString(), contains('7153 extraction write boundary'));
    expect(workshopLocalError(error).code, 'workshop_companion_not_a_pack');
  });

  for (final (name, bare) in const [
    ('Character.json', false), ('Index.JSON', false),
    ('Character.json', true), ('Index.JSON', true),
  ]) {
    test('generated root names reject $name in ${bare ? 'a bare model' : 'a character pack'} before extraction', () async {
      await seed();
      await store.install(workshopZip(temp, workshopCharacter()).path,
        workshop: receipt(), replaceExisting: true);
      final before = _packBytes(store.pack);
      final oldReceipt = File('${store.pack.path}/$workshopReceiptName').readAsBytesSync();
      final files = workshopCharacter(name: 'Replacement');
      files['character/$name'] = name == 'Character.json'
          ? files.remove('character/character.json')!
          : utf8.encode('{"note":"Ordinary imported metadata"}');
      final incoming = workshopZip(temp, bare
          ? {for (final entry in files.entries) 'download/${entry.key.substring('character/'.length)}': entry.value}
          : files);
      final incomingBytes = incoming.readAsBytesSync();
      var opened = 0;
      final checked = CompanionPackStore.withOutputForTesting(store.root, expectedRuntime: workshopRuntimeDigest(),
        openOutput: (path) { opened++; return OutputFileStream(path); });
      await expectLater(checked.install(incoming.path),
        throwsA(isA<CompanionPackException>().having((e) => e.problem, 'problem', CompanionPackProblem.unsafePath)));
      expect(opened, 0, reason: 'the whole target list is checked before opening any extraction output');
      expect(incoming.readAsBytesSync(), incomingBytes, reason: 'the original input is not renamed, edited or removed');
      expect(_packBytes(store.pack), before);
      expect(File('${store.pack.path}/$workshopReceiptName').readAsBytesSync(), oldReceipt);
      expect(Directory('${store.root.path}/pack.staging').existsSync(), isFalse);
      expect(Directory('${store.root.path}/pack.previous').existsSync(), isFalse);
      final restarted = CompanionPackStore(store.root, expectedRuntime: workshopRuntimeDigest());
      expect((await restarted.workshopReceipt())!.same(receipt()), isTrue);
      expect(await restarted.unavailableReason(), isNull);
    });
  }

  test('canonical root character is preserved and a canonical local index is rebuilt', () async {
    await seed();
    final files = workshopCharacter(name: 'Canonical character');
    final character = List<int>.of(files['character/character.json']!);
    files['character/index.json'] = utf8.encode('["stale-entry.json"]');
    await store.install(workshopZip(temp, files).path);
    expect(File('${store.pack.path}/character/character.json').readAsBytesSync(), character);
    final index = jsonDecode(File('${store.pack.path}/character/index.json').readAsStringSync()) as List;
    expect(index, containsAll(['character.json', 'index.json', 'm.model3.json', 'm.moc3', 'texture.png']));
    expect(index, isNot(contains('stale-entry.json')));
    expect(await store.unavailableReason(), isNull);
  });

  test('canonical uploaded index remains forbidden and leaves the installed receipt intact', () async {
    await seed();
    await store.install(workshopZip(temp, workshopCharacter()).path,
      workshop: receipt(), replaceExisting: true);
    final before = _packBytes(store.pack);
    final files = workshopCharacter(name: 'Replacement')
      ..['character/index.json'] = utf8.encode('["character.json"]');
    await expectLater(store.install(workshopZip(temp, files).path,
      workshop: receipt(version: '1.1.0', hash: 'b' * 64)),
      throwsA(isA<CompanionPackException>().having((e) => e.problem, 'problem', CompanionPackProblem.forbiddenFile)));
    expect(_packBytes(store.pack), before);
    expect((await store.workshopReceipt())!.same(receipt()), isTrue);
  });

  test('nested ordinary reserved basenames and Unicode names stay intact beside generated root files', () async {
    await seed();
    final files = workshopCharacter()..remove('character/character.json');
    final ordinary = {
      'character/资料/Character.json': utf8.encode('{"label":"Nested character data"}'),
      'character/资料/Index.JSON': utf8.encode('{"label":"Nested index data"}'),
      'character/猫咪说明.json': utf8.encode('{"label":"正常 Unicode 文件名"}'),
    };
    files.addAll(ordinary);
    await store.install(workshopZip(temp, files).path);
    for (final entry in ordinary.entries) {
      expect(File('${store.pack.path}/${entry.key}').readAsBytesSync(), entry.value);
    }
    final character = jsonDecode(File('${store.pack.path}/character/character.json').readAsStringSync()) as Map;
    expect(character, {'schema': 1, 'name': 'm', 'model': 'm.model3.json'});
    final index = jsonDecode(File('${store.pack.path}/character/index.json').readAsStringSync()) as List;
    expect(index, containsAll(['character.json', '资料/Character.json', '资料/Index.JSON', '猫咪说明.json']));
    expect(await store.unavailableReason(), isNull);
  });

  test('availability checks the whole runtime, model references and moc version', () async {
    expect(await store.unavailableReason(), 'companion_runtime_missing');
    await seed();
    expect(await store.unavailableReason(), isNull);
    final framework = File('${store.pack.path}/runtime/cubism-framework.js');
    framework.writeAsStringSync('changed');
    expect(await store.unavailableReason(), 'companion_runtime_mismatch');
    framework.deleteSync();
    expect(await store.unavailableReason(), 'companion_runtime_incomplete');
    await seed();
    File('${store.pack.path}/character/texture.png').deleteSync();
    expect(await store.unavailableReason(), 'companion_bad_index');
    await seed();
    File('${store.pack.path}/character/m.moc3').writeAsBytesSync([...ascii.encode('MOC3'), 7]);
    expect(await store.unavailableReason(), 'companion_moc_version');
  });

  test('missing physics and pose references are not accepted just because an index exists', () async {
    for (final field in ['Physics', 'Pose']) {
      final files = workshopCharacter();
      final model = jsonDecode(utf8.decode(files['character/m.model3.json']!)) as Map;
      (model['FileReferences'] as Map)[field] = 'missing.json';
      files['character/m.model3.json'] = utf8.encode(jsonEncode(model));
      await store.install(workshopZip(temp, {...workshopRuntime(), ...files}).path);
      expect(await store.unavailableReason(), 'companion_missing_reference');
    }
  });

  for (final (shape, contents, expected) in const [
    ('object', '{"label":"普通数据"}', null),
    ('array', '[]', 'companion_bad_json'),
    ('truncated object', '{"label":', 'companion_bad_json'),
  ]) {
    test('referenced dependency JSON $shape has the same gate across extension case', () async {
      for (final (field, dependency) in const [
        ('Physics', '资料/e\u0301.physics3.json'),
        ('Physics', '资料/e\u0301.PHYSICS3.JSON'),
        ('Pose', '资料/姿态.pose3.json'),
        ('Pose', '资料/姿态.PoSe3.JsOn'),
      ]) {
        final files = workshopCharacter();
        // Keep the model3 itself valid and lowercase. Only this referenced
        // dependency varies, so its JSON gate must run in the final refs pass.
        final model = jsonDecode(utf8.decode(files['character/m.model3.json']!)) as Map;
        (model['FileReferences'] as Map)[field] = dependency;
        files['character/m.model3.json'] = utf8.encode(jsonEncode(model));
        files['character/$dependency'] = utf8.encode(contents);
        await store.install(workshopZip(temp, {...workshopRuntime(), ...files}).path);
        expect(await store.unavailableReason(), expected, reason: '$field -> $dependency ($shape)');
        final root = '${store.pack.path}/character';
        final installedModel = jsonDecode(File('$root/m.model3.json').readAsStringSync()) as Map;
        expect((installedModel['FileReferences'] as Map)[field], dependency);
        final index = jsonDecode(File('$root/index.json').readAsStringSync()) as List;
        expect(index, contains(dependency));
        expect(File('$root/$dependency').readAsBytesSync(), orderedEquals(utf8.encode(contents)),
          reason: 'availability must preserve the original dependency bytes and spelling');
      }
    });
  }

  test('character-only export has no personal state, audio, runtime or local receipt and round-trips', () async {
    await seed();
    File('${store.root.path}/memory.json').writeAsStringSync('PRIVATE_MEMORY');
    File('${store.root.path}/light-chat.json').writeAsStringSync('PRIVATE_CHAT');
    File('${store.root.path}/voice-sample.wav').writeAsStringSync('PRIVATE_CLONE');
    File('${store.pack.path}/$workshopReceiptName').writeAsStringSync(jsonEncode(receipt().toJson()));
    File('${store.pack.path}/character/adapter.json').writeAsStringSync(jsonEncode({
      'adapter': 1, 'moc': 'a' * 64, 'params': {'ParamAngleX': {'id': 'ParamAngleX', 'scale': 1, 'key': 'PRIVATE_PARAM_KEY'}},
      'emotions': {'happy': {'face': {'ParamMouthForm': 0.5}, 'notes': 'PRIVATE_EMOTION_NOTE'}},
      'actions': {'wave': {'motion': 'Idle', 'apiKey': 'PRIVATE_ACTION_KEY'}},
      'notes': 'PRIVATE_ADAPT_NOTE', 'apiKey': 'PRIVATE_ADAPT_KEY',
    }));
    final exported = await store.exportZip(File('${temp.path}/export.zip'));
    final files = workshopUnzip(exported);
    expect(files.keys.every((p) => p.startsWith('character/')), isTrue);
    expect(files.keys, isNot(contains('character/index.json')));
    expect(files.keys.any((p) => p.endsWith('.wav') || p.endsWith('.mp3') || p.contains(workshopReceiptName)), isFalse);
    final textual = files.entries.where((e) => e.key.endsWith('.json')).map((e) => utf8.decode(e.value)).join('\n');
    expect(textual, isNot(contains('PRIVATE_')));
    expect(textual, isNot(contains('Private name')));
    expect(files.keys, isNot(contains('character/notes.json')));
    final character = jsonDecode(utf8.decode(files['character/character.json']!)) as Map;
    expect(character['name'], 'Companion');
    expect(character.containsKey('persona'), isFalse);
    final adapter = jsonDecode(utf8.decode(files['character/adapter.json']!)) as Map;
    expect((adapter['actions'] as Map)['wave'], {'motion': 'Idle'});
    expect((adapter['params'] as Map)['ParamAngleX'], {'id': 'ParamAngleX', 'scale': 1});
    expect(utf8.decode(files['character/LICENSE.txt']!), 'Public licence text');
    await store.install(exported.path, workshop: receipt(), replaceExisting: true);
    expect(await store.unavailableReason(), isNull);
    expect((await store.workshopReceipt())!.same(receipt()), isTrue);
    final index = jsonDecode(File('${store.pack.path}/character/index.json').readAsStringSync()) as List;
    expect(index, contains('adapter.json'));
    expect(index, isNot(contains('voice.wav')));
  });

  test('only explicitly supplied name and persona are included', () async {
    await seed();
    final exported = await store.exportZip(File('${temp.path}/explicit.zip'), name: 'Public name', persona: 'Explicit public persona');
    final json = jsonDecode(utf8.decode(workshopUnzip(exported)['character/character.json']!)) as Map;
    expect(json['name'], 'Public name');
    expect(json['persona'], 'Explicit public persona');
    expect(json.toString(), isNot(contains('PRIVATE_PERSONA')));
  });

  test('a Live2D-sized texture and a motion saved with a BOM still export', () async {
    // Only the header is read: 4096 a side is far past a pet sheet's limit.
    final header = BytesBuilder()
      ..add([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13])
      ..add(ascii.encode('IHDR'))
      ..add([0, 0, 16, 0, 0, 0, 16, 0, 8, 6, 0, 0, 0, 0, 0, 0, 0]);
    final texture = header.takeBytes();
    final files = workshopCharacter();
    files['character/texture.png'] = texture;
    files['character/idle.motion3.json'] = [0xef, 0xbb, 0xbf, ...files['character/idle.motion3.json']!];
    await store.install(workshopZip(temp, {...workshopRuntime(), ...files}).path);
    final exported = await store.exportZip(File('${temp.path}/large-texture.zip'));
    expect(workshopUnzip(exported)['character/texture.png'], texture);
  });

  test('export refuses new files inside its managed root and existing external files', () async {
    await seed();
    final managed = File('${store.pack.path}/character/new-export.zip');
    await expectLater(store.exportZip(managed), throwsA(isA<CompanionPackException>()));
    expect(managed.existsSync(), isFalse);
    final existing = File('${temp.path}/saved.zip')..writeAsStringSync('keep');
    await expectLater(store.exportZip(existing), workshopError('workshop_export_exists'));
    expect(existing.readAsStringSync(), 'keep');
  });

  test('model fallback preserves the stage index order instead of choosing the shallowest', () async {
    final original = workshopCharacter();
    final config = (jsonDecode(utf8.decode(original['character/character.json']!)) as Map)..remove('model');
    final files = <String, List<int>>{
      ...workshopRuntime(),
      'character/character.json': utf8.encode(jsonEncode(config)),
      'character/deep/a.model3.json': utf8.encode(jsonEncode({'Version': 3,
        'FileReferences': {'Moc': 'a.moc3', 'Textures': ['a.png']}})),
      'character/deep/a.moc3': original['character/m.moc3']!,
      'character/deep/a.png': workshopPng(1, 1),
      'character/b.model3.json': original['character/m.model3.json']!,
      for (final e in original.entries) if (e.key != 'character/character.json' && e.key != 'character/m.model3.json') e.key: e.value,
    };
    await store.install(workshopZip(temp, files).path);
    final index = jsonDecode(File('${store.pack.path}/character/index.json').readAsStringSync()) as List;
    expect(index.where((n) => (n as String).endsWith('.model3.json')).first, 'deep/a.model3.json');
    final exported = workshopUnzip(await store.exportZip(File('${temp.path}/selected.zip')));
    final configOut = jsonDecode(utf8.decode(exported['character/character.json']!)) as Map;
    expect(configOut['model'], 'deep/a.model3.json');
    expect(exported.keys, contains('character/deep/a.model3.json'));
    expect(exported.keys, isNot(contains('character/b.model3.json')));
  });

  test('empty optional notices are omitted instead of producing a rejected upload member', () async {
    await seed();
    File('${store.pack.path}/character/NOTICE.txt').writeAsBytesSync([]);
    final files = workshopUnzip(await store.exportZip(File('${temp.path}/notice.zip')));
    expect(files.keys, isNot(contains('character/NOTICE.txt')));
    expect(files.keys, contains('character/LICENSE.txt'));
  });

  test('export rejects filesystem links instead of reading another private file', () async {
    await seed();
    final secret = File('${store.root.path}/secret.json')..writeAsStringSync('{"key":"PRIVATE_KEY"}');
    Link('${store.pack.path}/character/link.json').createSync(secret.path);
    expect(await store.unavailableReason(), 'companion_unsafe_path');
    await expectLater(store.exportZip(File('${temp.path}/linked.zip')), throwsA(isA<CompanionPackException>()));
    expect(File('${temp.path}/linked.zip').existsSync(), isFalse);
  });

  test('a change waits for readers to stop and broadcasts start and settlement', () async {
    await seed();
    final base = store.revision, revisions = <int>[];
    final sub = store.revisions.listen(revisions.add);
    addTearDown(sub.cancel);
    final entered = Completer<void>(), stopped = Completer<void>();
    final unregister = store.beforeChanges(() async { entered.complete(); await stopped.future; });
    addTearDown(unregister);
    final installing = store.install(workshopZip(temp, {...workshopRuntime(), ...workshopCharacter(name: 'New name')}).path);
    final settled = installing.then<void>((_) {}, onError: (Object _) {});
    try {
      await entered.future;
      expect(store.revision, base + 1);
      expect(jsonDecode(File('${store.pack.path}/character/character.json').readAsStringSync())['name'], 'Private name');
      stopped.complete();
      await installing;
      expect(revisions, [base + 1, base + 2]);
      expect((await store.character()).name, 'New name');
    } finally {
      if (!stopped.isCompleted) stopped.complete();
      await settled;
    }
  });

  test('a failed stop-readers hook leaves the old directory intact', () async {
    await seed();
    final before = File('${store.pack.path}/character/character.json').readAsBytesSync();
    final unregister = store.beforeChanges(() async => throw StateError('cannot close renderer'));
    addTearDown(unregister);
    await expectLater(store.install(workshopZip(temp, {...workshopRuntime(), ...workshopCharacter(name: 'Replacement')}).path),
      throwsA(isA<CompanionPackException>().having((e) => e.detail, 'detail', 'companion_readers_busy')));
    expect(File('${store.pack.path}/character/character.json').readAsBytesSync(), before);
  });

  test('stores of the same root share the mutation queue and revision', () async {
    await seed();
    final other = CompanionPackStore(store.root, expectedRuntime: workshopRuntimeDigest());
    final entered = Completer<void>(), release = Completer<void>();
    var calls = 0;
    final unregister = store.beforeChanges(() async { if (++calls == 1) entered.complete(); await release.future; });
    addTearDown(unregister);
    final install = store.install(workshopZip(temp, workshopCharacter()).path);
    final installSettled = install.then<void>((_) {}, onError: (Object _) {});
    Future<void>? removeSettled;
    try {
      await entered.future;
      var removed = false;
      final remove = other.remove().then((_) => removed = true);
      removeSettled = remove.then<void>((_) {}, onError: (Object _) {});
      await Future<void>.delayed(Duration.zero);
      expect(removed, isFalse);
      expect(other.revision, store.revision);
      release.complete();
      await install;
      await remove;
      expect(await store.installed(), isFalse);
      expect(calls, 2);
    } finally {
      if (!release.isCompleted) release.complete();
      await installSettled;
      if (removeSettled != null) await removeSettled;
    }
  });

  test('interrupted promotion restores previous before a read or next installation', () async {
    await seed();
    store.pack.renameSync('${store.root.path}/pack.previous');
    Directory('${store.root.path}/pack.staging').createSync();
    File('${store.root.path}/pack.staging/junk').writeAsStringSync('incomplete');
    final restarted = CompanionPackStore(store.root, expectedRuntime: workshopRuntimeDigest());
    expect(await restarted.unavailableReason(), isNull);
    expect((await restarted.character()).name, 'Private name');
    expect(Directory('${store.root.path}/pack.previous').existsSync(), isFalse);
    expect(Directory('${store.root.path}/pack.staging').existsSync(), isFalse);
  });

  test('workshop replacement and stale removal are checked inside the store queue', () async {
    await seed();
    final zip = workshopZip(temp, workshopCharacter());
    // Another character comes in without asking: the one here waits on the shelf.
    await store.install(zip.path, workshop: receipt());
    expect([for (final entry in await store.roster()) entry.active], [true, false]);
    final next = receipt(version: '1.1.0', hash: 'b' * 64);
    await store.install(zip.path, workshop: next);
    await expectLater(store.remove(expectedWorkshop: receipt()), workshopError('workshop_install_conflict'));
    expect((await store.workshopReceipt())!.version, '1.1.0');
    await store.install(zip.path);
    expect(await store.workshopReceipt(), isNull);
  });

  test('companions waiting on the shelf are installed in the Workshop and can be removed there', () async {
    final packages = LocalWorkshopPackages(pets: PetLibrary(() async => Directory('${temp.path}/pets')), companion: store);
    await seed();
    final zip = workshopZip(temp, workshopCharacter());
    await packages.install(zip, receipt(), replaceExisting: false);
    await packages.install(zip, receipt(id: 'dog'), replaceExisting: false);
    final installed = (await packages.installed()).whereType<WorkshopInstalled>().toList();
    expect([for (final item in installed) item.receipt.id], unorderedEquals(['dog', 'cat']));
    await packages.remove(installed.singleWhere((item) => item.receipt.id == 'cat'));
    expect([for (final entry in await store.roster()) entry.workshop?.id], ['dog', null]);
  });
}
