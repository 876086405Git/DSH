// Several companions on one phone (the pack store keeps the others on a
// shelf). Who she is goes with her: the name the person gave her and the
// persona they wrote are kept per character and put back when she returns.
// How she calls the person is about the person, so it stays as it is; so do
// memory and reminders, which are about the person too.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'companion_state.dart';

const _identityPrefix = 'companion_identity_v1:';

/// Whose name and persona the settings hold right now.
const _ownerKey = 'companion_identity_owner';

/// One handoff at a time: a second switch waits for the first to finish.
Future<bool> _queue = Future.value(false);

/// Makes the name and persona settings [key]'s: whoever they belonged to
/// keeps hers for when she's back, and [key] gets what she had (none yet:
/// her pack's name and the default persona). The first character ever seen
/// simply owns what is there. True when they changed hands.
///
/// It runs wherever she arrives (a switch here, a Workshop install made
/// elsewhere, a restart after one was cut short), so the settings always
/// follow whoever is in the room.
Future<bool> companionAdoptIdentity(WidgetRef ref, String key) =>
    _queue = _queue.then((_) => _safely(() => _adopt(ref, key)));

/// Settings that can't be read or written (or a room already gone) leave
/// things as they are; the next arrival tries again.
Future<bool> _safely(Future<bool> Function() step) async {
  try {
    return await step();
  } on Object {
    return false;
  }
}

Future<bool> _adopt(WidgetRef ref, String key) async {
  final names = ref.read(companionNameProvider.notifier);
  final personas = ref.read(companionPersonaProvider.notifier);
  await personas.ready;
  final prefs = await SharedPreferences.getInstance();
  final owner = prefs.getString(_ownerKey);
  if (owner == key) return false;
  if (owner == null) {
    await prefs.setString(_ownerKey, key);
    return false;
  }
  final persona = ref.read(companionPersonaProvider);
  await prefs.setString(
    '$_identityPrefix$owner',
    jsonEncode({'name': ref.read(companionNameProvider), 'custom': persona.custom}),
  );
  Map<Object?, Object?>? saved;
  try {
    final decoded = jsonDecode(prefs.getString('$_identityPrefix$key') ?? 'null');
    if (decoded is Map) saved = decoded;
  } on FormatException {
    // Unreadable: she starts as her pack has her.
  }
  await names.set(saved?['name'] as String?);
  await personas.set(CompanionPersonaSettings(custom: saved?['custom'] as String? ?? '', callMe: persona.callMe));
  await prefs.setString(_ownerKey, key);
  return true;
}

/// [key] left the phone: what was kept for her goes, and if the settings were
/// hers they go back to the defaults (how she calls the person stays).
Future<void> companionForgetIdentity(WidgetRef ref, String key) =>
    _queue = _queue.then((_) => _safely(() => _forget(ref, key)));

Future<bool> _forget(WidgetRef ref, String key) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('$_identityPrefix$key');
  if (prefs.getString(_ownerKey) != key) return false;
  await prefs.remove(_ownerKey);
  final persona = ref.read(companionPersonaProvider);
  await ref.read(companionNameProvider.notifier).set(null);
  await ref.read(companionPersonaProvider.notifier).set(CompanionPersonaSettings(callMe: persona.callMe));
  return true;
}
