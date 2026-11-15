import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/update/update_http.dart';
import 'package:dsh_app/workshop/workshop_http.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

final workshopTestOrigin = Uri.parse('https://workshop.example');
final workshopTestAccount = Uri.parse('https://github.com');
const workshopTestId = '0123456789abcdef0123456789abcdef';
const workshopTestDate = '2026-11-11T00:00:00.000Z';

Matcher workshopError(String code, {bool? unknown}) => throwsA(isA<WorkshopException>()
  .having((e) => e.code, 'code', code)
  .having((e) => e.resultUnknown, 'resultUnknown', unknown ?? anything));

Map<String, Object?> workshopMeta({String kind = 'pet', String id = 'cat', String version = '1.0.0',
  String minApp = '1.0.0', List<int> bytes = const [1, 2, 3, 4]}) => {
  'kind': kind, 'id': id, 'version': version, 'minApp': minApp, 'title': {'zh': '小猫', 'en': 'Cat'},
  'author': 'Author', 'license': 'CC0-1.0', 'source': 'https://source.example/cat',
  'sha256': sha256.convert(bytes).toString(), 'size': bytes.length, 'rightsConfirmed': true,
};

Map<String, Object?> workshopEntryJson({Map<String, Object?>? metadata, List<String> blocked = const []}) {
  final m = metadata ?? workshopMeta();
  return {...m, 'url': '/market/workshop/${m['kind']}/${m['id']}/${m['version']}/${m['sha256']}.zip', 'blockedVersions': blocked};
}

Map<String, Object?> workshopCatalogJson({List<Object?>? entries, List<Object?> withdrawn = const [], bool uploads = true, bool companion = true, String at = workshopTestDate}) => {
  'schema': 1, 'generatedAt': at, 'features': {'uploads': uploads, 'companion': companion},
  'entries': entries ?? [workshopEntryJson()], 'withdrawn': withdrawn,
};

Map<String, Object?> workshopCaps({bool uploads = true, bool companion = true, String? account,
  String? clientId = 'test-client-id'}) => {
  'schema': 1, 'features': {'uploads': uploads, 'companion': companion}, 'kinds': ['pet', 'companion'],
  'licenses': workshopLicenses.toList(), 'account': {'origin': account ?? workshopTestAccount.toString(), 'clientId': clientId},
  'maxMocVersion': 6,
  'limits': {'archiveBytes': workshopArchiveBytes, 'expandedBytes': workshopExpandedBytes, 'companionMemberBytes': 32 * 1024 * 1024, 'companionEntries': 1000, 'petEntries': 256},
};

Map<String, Object?> workshopSubmissionJson({String id = workshopTestId, String status = 'draft', Map<String, Object?>? metadata}) => {
  'submissionId': id, 'owner': {'accountOrigin': workshopTestAccount.toString(), 'accountId': 42, 'username': 'author'},
  'metadata': metadata ?? workshopMeta(), 'status': status, 'createdAt': workshopTestDate, 'updatedAt': workshopTestDate,
  if (status == 'rejected' || status == 'approved') 'review': {'at': workshopTestDate, 'decision': status == 'approved' ? 'approve' : 'reject', 'reason': 'review reason'},
  if (status == 'withdrawn') 'withdrawal': {'at': workshopTestDate, 'reason': 'author withdrew'},
};

typedef WorkshopTestRoute = FutureOr<UpdateHttpResponse> Function(String method, Uri url, Map<String, String> headers, List<int>? body);

class FakeWorkshopHttp extends WorkshopHttp {
  FakeWorkshopHttp(this.route);
  WorkshopTestRoute route;
  final requests = <({String method, Uri url, Map<String, String> headers, List<int>? body})>[];
  @override
  Future<UpdateHttpResponse> request(String method, Uri url, {Map<String, String> headers = const {}, List<int>? body, Duration timeout = const Duration(seconds: 30)}) async {
    requests.add((method: method, url: url, headers: Map.of(headers), body: body == null ? null : List.of(body)));
    return route(method, url, headers, body);
  }
}

UpdateHttpResponse workshopJsonResponse(Object? json, {int status = 200, Map<String, String> headers = const {}}) {
  final bytes = utf8.encode(jsonEncode(json));
  return UpdateHttpResponse(status: status, contentLength: bytes.length, headers: headers, body: Stream.value(bytes));
}

Uint8List workshopPng([int width = 32, int height = 16]) => image.encodePng(image.Image(width: width, height: height, numChannels: 4));

Map<String, Object?> workshopPet({String id = 'cat'}) => {
  'schema': 1, 'id': id, 'name': 'Cat', 'author': 'Author', 'license': 'CC0-1.0', 'source': 'https://source.example/cat',
  'canvas': {'w': 16, 'h': 16}, 'contentBox': {'x': 0, 'y': 0, 'w': 16, 'h': 16},
  'animations': {'idle': {'sheet': 'idle.png', 'frameW': 16, 'frameH': 16, 'cols': 2,
    'box': {'x': 0, 'y': 0, 'w': 16, 'h': 16}, 'frames': [{'i': 0, 'ms': 200}, {'i': 1, 'ms': 300}]}},
  'states': {'idle': ['idle']},
};

Map<String, List<int>> workshopRuntime() => {
  'runtime/live2dcubismcore.min.js': utf8.encode('test core'),
  'runtime/cubism-framework.js': utf8.encode('test framework'),
  'runtime/shaders/test.vert': utf8.encode('test shader'),
};

String workshopRuntimeDigest() => runtimeDigest({for (final e in workshopRuntime().entries) e.key: sha256.convert(e.value).toString()});

Map<String, List<int>> workshopCharacter({String name = 'Private name', int moc = 6}) => {
  'character/character.json': utf8.encode(jsonEncode({'schema': 1, 'name': name, 'persona': 'PRIVATE_PERSONA',
    'model': 'm.model3.json', 'author': 'Author', 'license': 'CC0-1.0', 'source': 'https://source.example/cat',
    'apiKey': 'PRIVATE_CHARACTER_KEY', 'tail': ['ParamTail'], 'framing': {'zoom': 1.2, 'y': 0, 'key': 'PRIVATE_FRAMING_KEY'}})),
  'character/m.model3.json': utf8.encode(jsonEncode({'Version': 3, 'FileReferences': {'Moc': 'm.moc3', 'Textures': ['texture.png'],
    'Motions': {'Idle': [{'File': 'idle.motion3.json', 'Sound': 'voice.wav'}]}, 'key': 'PRIVATE_REF_KEY'},
    'custom': {'key': 'PRIVATE_MODEL_KEY'}})),
  'character/m.moc3': [...ascii.encode('MOC3'), moc, ...List.filled(32, 0)],
  'character/texture.png': workshopPng(1, 1),
  'character/idle.motion3.json': utf8.encode(jsonEncode({'Version': 3, 'Meta': {'Duration': 1.0, 'Fps': 30, 'Loop': true, 'CurveCount': 0, 'TotalSegmentCount': 0, 'TotalPointCount': 0},
    'Curves': [], 'UserData': [{'Time': 0, 'Value': 'PRIVATE_EVENT'}], 'apiKey': 'PRIVATE_MOTION_KEY'})),
  'character/voice.wav': utf8.encode('PRIVATE_AUDIO'),
  'character/notes.json': utf8.encode('{"apiKey":"PRIVATE_NOTES"}'),
  'character/LICENSE.txt': utf8.encode('Public licence text'),
};

File workshopZip(Directory directory, Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, bytes) => archive.add(ArchiveFile.bytes(name, bytes)));
  return File('${directory.path}/input-${DateTime.now().microsecondsSinceEpoch}.zip')..writeAsBytesSync(ZipEncoder().encode(archive));
}

Map<String, Uint8List> workshopUnzip(File file) {
  final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
  return {for (final member in archive.files) if (member.isFile) member.name: (() {
    final output = OutputMemoryStream();
    member.writeContent(output);
    return output.getBytes();
  })()};
}
