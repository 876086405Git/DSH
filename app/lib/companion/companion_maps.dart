import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final companionMapsProvider = Provider((_) => const CompanionMaps());

/// Only named geo operations. The native writer reads the original address
/// and target from SQLite; no caller can provide an executable Intent here.
class CompanionMaps {
  const CompanionMaps({this.channel = const MethodChannel('dsh/companion_maps')});
  final MethodChannel channel;

  Future<String> executorId() async =>
      (await channel.invokeMapMethod<String, Object?>('capabilities'))!['executorId']! as String;

  Future<MemoryRow> targets(String address) async =>
      (await channel.invokeMapMethod<String, Object?>('targets', {'address': address}))!;

  Future<String> openScope(String sourceSessionId) async =>
      (await channel.invokeMapMethod<String, Object?>('openScope', {'sourceSessionId': sourceSessionId}))!['scopeId']!
          as String;

  Future<void> closeScope(String scopeId) => channel.invokeMethod<void>('closeScope', {'scopeId': scopeId});

  Future<void> handoff(String taskId, int taskRev, String scopeId) =>
      channel.invokeMethod<void>('handoff', {'taskId': taskId, 'taskRev': taskRev, 'scopeId': scopeId});
}

/// One actual page owns its short-lived native scope. Invalidation is
/// synchronous even when openScope has not returned yet. No receipt is written
/// here, and leaving never retries an already accepted handoff.
class CompanionMapHandoff {
  CompanionMapHandoff(this.maps);
  final CompanionMaps maps;
  int _generation = 0;
  ({String id, String sourceSessionId, CompanionMemoryStore store})? _scope;
  int get generation => _generation;

  void close() {
    _generation++;
    final scope = _scope;
    _scope = null;
    if (scope != null) {
      // The synchronous SQLite write is the route/control boundary. A queued
      // native handoff checks the same row under its final dispatch transaction.
      // Merely queuing closeScope after handoff cannot provide that ordering.
      try {
        scope.store.closeMapHandoffScope(scopeId: scope.id, sourceSessionId: scope.sourceSessionId);
      } on Object catch (error, stack) {
        // Keep lifecycle cleanup running, but report the failed barrier. There
        // is no successful effect/stop receipt to infer from this failure.
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'companion maps',
            context: ErrorDescription('closing the original map scope'),
          ),
        );
      } finally {
        unawaited(_release(scope.id));
      }
    }
  }

  Future<void> _release(String scope) async {
    try {
      await maps.closeScope(scope);
    } on PlatformException {
      // A failed close cannot assert either a dispatch or a successful stop.
      // The original native claim, if any, remains the only effect evidence.
    } on MissingPluginException {
      // A detached platform has no usable entry; never reopen it from here.
    }
  }

  Future<void> execute(CompanionMemoryStore store, MemoryRow task, {required bool Function() isCurrent}) async {
    final generation = _generation;
    if (!isCurrent()) {
      return;
    }
    final sourceSessionId = task['source_session_id']! as String;
    final scope = await maps.openScope(sourceSessionId);
    if (generation != _generation || !isCurrent()) {
      try {
        store.closeMapHandoffScope(scopeId: scope, sourceSessionId: sourceSessionId);
      } finally {
        await _release(scope);
      }
      return;
    }
    _scope = (id: scope, sourceSessionId: sourceSessionId, store: store);
    try {
      await maps.handoff(task['task_id']! as String, task['task_rev']! as int, scope);
    } finally {
      if (_scope?.id == scope) {
        _scope = null;
      }
      try {
        store.closeMapHandoffScope(scopeId: scope, sourceSessionId: sourceSessionId);
      } finally {
        await _release(scope);
      }
    }
  }
}

/// Delimited complete addresses keep punctuation and spaces as source data.
/// This finite grammar does not geocode a place name or resolve multiple gates.
MemoryRow? parseCompanionMap(String raw) {
  final text = raw.trim();
  if (RegExp(r'^(?:[“「『"\x27]|不要|别|假设|故事|台词|他说|她说)').hasMatch(text)) {
    return null;
  }
  final command = text.replaceFirst(RegExp(r'[。.!！]+$'), '');
  if (const ['取消打开地图', '取消地图打开', '取消这次地图交接', '不用打开地图了'].contains(command)) {
    return {'operation': 'cancel', 'target': null};
  }
  if (const ['重新打开地图', '重新打开刚才的地图'].contains(command)) {
    return {'operation': 'reopen', 'target': null};
  }
  final cancel = RegExp(r'^取消(?:打开)?“([^”]+)”的地图$').firstMatch(command);
  if (cancel != null) {
    return {'operation': 'cancel', 'target': cancel.group(1)};
  }
  final reopen = RegExp(r'^重新打开“([^”]+)”的地图$').firstMatch(command);
  if (reopen != null) {
    return {'operation': 'reopen', 'target': reopen.group(1)};
  }
  final amend = RegExp(r'^(?:把“([^”]+)”的地图地址|地图地址)改成“([^”]+)”$').firstMatch(command);
  final direct = RegExp(r'^(?:请|帮我)?(?:在地图(?:里)?打开|用地图打开)[：:]?\s*“([^”]+)”(?:[，,]我自己看路线)?$').firstMatch(command);
  final explicit = RegExp(r'^(?:请|帮我)?把(?:地址)?“([^”]+)”在地图(?:里)?打开(?:[，,]我自己看路线)?$').firstMatch(command);
  final address = amend?.group(2) ?? direct?.group(1) ?? explicit?.group(1);
  if (address != null) {
    if (address.trim().isEmpty ||
        RegExp(r'或者|还是|两个|两处|两个同名').hasMatch(address) ||
        const ['东门', '西门', '南门', '北门', '这里', '那里', '这个地址', '那个地址'].contains(address.trim())) {
      return {'operation': 'clarify'};
    }
    return {'operation': amend == null ? 'create' : 'amend', 'address': address, 'target': amend?.group(1)};
  }
  return RegExp(r'^(?:请|帮我)?(?:把|在地图|用地图|打开地图|地图地址|重新打开|取消)').hasMatch(command) && command.contains('地图')
      ? {'operation': 'clarify'}
      : null;
}
