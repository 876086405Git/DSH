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

/// Keeps [from]'s name and persona, then puts back [to]'s (none yet: her
/// pack's own name and the default persona).
Future<void> companionSwapIdentity(WidgetRef ref, {required String? from, required String to}) async {
  if (from == to) return;
  final names = ref.read(companionNameProvider.notifier);
  final personas = ref.read(companionPersonaProvider.notifier);
  await personas.ready;
  final persona = ref.read(companionPersonaProvider);
  final prefs = await SharedPreferences.getInstance();
  if (from != null) {
    await prefs.setString(
      '$_identityPrefix$from',
      jsonEncode({'name': ref.read(companionNameProvider), 'custom': persona.custom}),
    );
  }
  Map<Object?, Object?>? saved;
  try {
    final decoded = jsonDecode(prefs.getString('$_identityPrefix$to') ?? 'null');
    if (decoded is Map) saved = decoded;
  } on FormatException {
    // Unreadable: she starts as her pack has her.
  }
  await names.set(saved?['name'] as String?);
  await personas.set(CompanionPersonaSettings(custom: saved?['custom'] as String? ?? '', callMe: persona.callMe));
}

/// Forgets what was kept for [key] (she was removed from the phone).
Future<void> companionForgetIdentity(String key) async {
  await (await SharedPreferences.getInstance()).remove('$_identityPrefix$key');
}
