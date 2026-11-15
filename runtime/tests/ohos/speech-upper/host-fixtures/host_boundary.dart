// Explicit app services not exercised by these host speech tests.
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

final accountProvider = Provider<dynamic>((_) => throw UnimplementedError('account boundary'));
final activeConnectionProvider = Provider<dynamic>((_) => throw UnimplementedError('connection boundary'));
final settingsProvider = Provider<dynamic>((_) => throw UnimplementedError('settings boundary'));

class DiagnosticsChannel {
  const DiagnosticsChannel();
  final MethodChannel channel = const MethodChannel('dsh/diagnostics');
  Future<void> recordVoiceStage(String stage, {String? backend}) async {}
}

enum CompanionVoiceSource { deepseek, system, preset, openai, custom }
class CompanionVoiceSettings {
  const CompanionVoiceSettings({this.source = CompanionVoiceSource.deepseek, this.deepseekVoice = 'stella'});
  final CompanionVoiceSource source;
  final String deepseekVoice;
}
enum CompanionVoiceEventType { start, done, stopped, error, range, fallback }
class CompanionVoiceEvent {
  const CompanionVoiceEvent(this.type, this.id, {this.loudness});
  final CompanionVoiceEventType type;
  final String id;
  final List<double>? loudness;
}
class CompanionSpeaker {
  set settings(CompanionVoiceSettings next) {}
  String? lastError;
  Stream<CompanionVoiceEvent> get events => const Stream.empty();
  Future<bool> ready(CompanionVoiceSettings next) async => false;
  Future<bool> warmPhone() async => false;
  Future<String?> preview(CompanionVoiceSettings next, String text) async => throw UnimplementedError();
  void speak(String id, String text, {bool flush = false}) => throw UnimplementedError('not a companion playback test');
  void stop() {}
  void dispose() {}
}
