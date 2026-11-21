// Fitting a model to her with the person's own AI (docs/design/companion-adapt.md).
//
// The stage reports what the model is (its probe: parameters with the names
// the editor gave them, expressions, motions, what the rules already linked).
// When something only judgement can settle is left — which parameter turns
// the head, which expression is shy, where the head is — the person's model
// is asked once and answers with an adapter: data only, never code. Every
// part of the answer is checked against the probe before it's written to
// `character/adapter.json`, which the stage wears at once (stage.js
// `adapter`). Nothing of the model itself is sent: names and numbers only.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'companion_adapt_contract.dart';
import 'companion_light.dart';

export 'companion_adapt_contract.dart';

class CompanionAdaptError implements Exception {
  const CompanionAdaptError(this.reason);

  /// `unreadable`: the answer had no adapter in it; `empty`: nothing usable.
  final String reason;

  @override
  String toString() => 'CompanionAdaptError($reason)';
}

/// Asks the person's model (the light route) and checks its answer.
/// Throws [CompanionLightError] for the request, [CompanionAdaptError] for
/// an answer that can't be used.
Future<Map<String, Object?>> companionAdaptAsk({
  required http.Client client,
  required String apiKey,
  required CompanionProbe probe,
  String? note,
  Map<String, Object?>? current,
  CompanionAdaptEvidence evidence = const CompanionAdaptEvidence(),
  void Function(int input, int output)? onUsage,
  void Function(Map<String, Object?> usage, {required bool partial})? onUsageSettled,
}) async {
  final text = StringBuffer();
  await for (final delta in streamCompanionReply(
    client: client,
    apiKey: apiKey,
    system: companionAdaptSystem,
    lines: [CompanionLine.user(companionAdaptRequest(probe, note: note, current: current, evidence: evidence))],
    maxTokens: 3000,
    onUsage: onUsage,
    onUsageSettled: onUsageSettled,
  )) {
    text.write(delta);
  }
  final answer = companionAdaptJson(text.toString());
  if (answer == null) throw const CompanionAdaptError('unreadable');
  final (:adapter, dropped: _) = companionAdapterCheck(answer, probe, evidence: evidence);
  if (companionAdapterEmpty(adapter)) throw const CompanionAdaptError('empty');
  return adapter;
}

/// `character/adapter.json` of the pack at [pack].
File companionAdapterFile(Directory pack) => File('${pack.path}/character/adapter.json');

Future<Map<String, Object?>?> companionAdapterRead(Directory pack) async {
  try {
    final decoded = jsonDecode(await companionAdapterFile(pack).readAsString());
    return decoded is Map ? decoded.cast<String, Object?>() : null;
  } on Object {
    return null;
  }
}

/// Writes [adapter] for the model at [probe] (with its moc3's fingerprint,
/// so it can be matched to the same model later).
Future<void> companionAdapterWrite(Directory pack, CompanionProbe probe, Map<String, Object?> adapter) async {
  final file = companionAdapterFile(pack);
  final fingerprint = await companionMocFingerprint(pack, probe);
  final temp = File('${file.path}.part');
  await temp.writeAsString(jsonEncode({...adapter, 'moc': ?fingerprint}), flush: true);
  await temp.rename(file.path);
}

Future<void> companionAdapterRemove(Directory pack) async {
  final file = companionAdapterFile(pack);
  if (await file.exists()) await file.delete();
}

/// The moc3's sha256, or null when it can't be read.
Future<String?> companionMocFingerprint(Directory pack, CompanionProbe probe) async {
  if (probe.moc.isEmpty || probe.moc.split('/').contains('..')) return null;
  try {
    return (await sha256.bind(File('${pack.path}/character/${probe.moc}').openRead()).first).toString();
  } on Object {
    return null;
  }
}

/// Whether the person has said yes to a fitting once (an offer, or the menu):
/// until then nothing goes out on its own.
const _consentKey = 'companion_adapt_consented';

Future<bool> companionAdaptConsented() async {
  try {
    return (await SharedPreferences.getInstance()).getBool(_consentKey) ?? false;
  } on Object {
    return false;
  }
}

Future<void> companionAdaptSetConsented(bool yes) async =>
    (await SharedPreferences.getInstance()).setBool(_consentKey, yes);

/// Whether models are fitted on their own when they arrive (on unless turned off).
const _autoKey = 'companion_adapt_auto';

Future<bool> companionAdaptAuto() async {
  try {
    return (await SharedPreferences.getInstance()).getBool(_autoKey) ?? true;
  } on Object {
    return true;
  }
}

Future<void> companionAdaptSetAuto(bool on) async => (await SharedPreferences.getInstance()).setBool(_autoKey, on);

/// An automatic try happens once per model, whatever came of it.
String _triedKey(String fingerprint) => 'companion_adapt_tried_$fingerprint';

Future<bool> companionAdaptTried(String fingerprint) async {
  try {
    return (await SharedPreferences.getInstance()).getBool(_triedKey(fingerprint)) ?? false;
  } on Object {
    return false;
  }
}

Future<void> companionAdaptMarkTried(String fingerprint) async {
  try {
    await (await SharedPreferences.getInstance()).setBool(_triedKey(fingerprint), true);
  } on Object {
    // Then it may try again next time.
  }
}
