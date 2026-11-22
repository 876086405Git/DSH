import 'dart:convert';
import 'dart:io';

import 'workshop_models.dart';

/// Kept beside the installed pack, never inside an exported archive.
const workshopReceiptName = '.workshop-source.json';

class WorkshopReceipt {
  WorkshopReceipt({required this.kind, required this.id, required this.version, required this.sha256, required Uri origin})
    : origin = workshopOrigin(origin) {
    if (!const {'pet', 'companion', 'theme'}.contains(kind) || !workshopId(id) || WorkshopVersion.tryParse(version) == null || !workshopHash(sha256)) {
      workshopInvalid('workshop_install_record');
    }
  }
  factory WorkshopReceipt.fromJson(Object? value) {
    try {
      final m = workshopMap(value);
      if (m['schema'] != 1 || m['kind'] is! String || m['id'] is! String || m['version'] is! String || m['sha256'] is! String || m['origin'] is! String) {
        workshopInvalid('workshop_install_record');
      }
      return WorkshopReceipt(kind: m['kind'] as String, id: m['id'] as String, version: m['version'] as String, sha256: m['sha256'] as String, origin: Uri.parse(m['origin'] as String));
    } on Object {
      throw const WorkshopException('workshop_install_record');
    }
  }
  final String kind, id, version, sha256;
  final Uri origin;
  String get identity => '$kind/$id';
  bool same(WorkshopReceipt other) => identity == other.identity && version == other.version && sha256 == other.sha256 && origin == other.origin;
  Map<String, Object?> toJson() => {'schema': 1, 'kind': kind, 'id': id, 'version': version, 'sha256': sha256, 'origin': origin.toString()};

  static Future<WorkshopReceipt?> read(Directory directory) async {
    final file = File('${directory.path}/$workshopReceiptName');
    if (!await file.exists()) return null;
    try {
      if (await file.length() > 4096) workshopInvalid('workshop_install_record');
      return WorkshopReceipt.fromJson(jsonDecode(await file.readAsString()));
    } on FormatException {
      throw const WorkshopException('workshop_install_record');
    }
  }
}

/// Called inside the existing installer's queue, immediately before staging
/// is promoted. The catalog's public id is not the local folder identity.
Future<void> workshopCheckReplacement(Directory live, WorkshopReceipt next, {required bool replaceExisting}) async {
  if (!await live.exists()) return;
  final old = await WorkshopReceipt.read(live);
  if (old == null || old.identity != next.identity || old.origin != next.origin) {
    if (!replaceExisting) workshopInvalid('workshop_install_conflict');
    return;
  }
  final comparison = WorkshopVersion.tryParse(next.version)!.compareTo(WorkshopVersion.tryParse(old.version)!);
  if (comparison < 0) workshopInvalid('workshop_downgrade');
  if (comparison == 0 && next.sha256 != old.sha256) workshopInvalid('workshop_version_rewritten');
}

Future<void> workshopCheckRemoval(Directory live, WorkshopReceipt expected) async {
  final actual = await WorkshopReceipt.read(live);
  if (actual == null || !actual.same(expected)) workshopInvalid('workshop_install_conflict');
}
