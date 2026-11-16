import 'dart:convert';
import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

DshPhoneRequest request(String tool, String kind) => DshPhoneRequest.fromJson({
  'v': 1,
  'engineId': 'engine-a',
  'bridgeGeneration': 1,
  'requestId': '22222222-2222-4222-8222-222222222222',
  'sessionId': 'session-a',
  'callId': 'call-a',
  'tool': tool,
  'args': {'kind': kind},
  'timeoutMs': 30000,
  'deadlineMs': 31000,
});
Map<String, Object?> receipt({
  String effect = 'reminder_scheduled',
  String evidence = 'unknown',
  bool dispatched = true,
}) => {
  'status': 'succeeded',
  'effect': effect,
  'evidence': evidence,
  'dispatched': dispatched,
  'code': 'reminder_scheduled',
  'message': '系统已接受提醒，不代表引擎任务会运行。',
};
void main() {
  test('public result parser accepts honest alarm and timer reminder receipts', () {
    for (final kind in ['alarm', 'timer']) {
      final result = DshPhoneResult.fromJson(receipt());
      result.validateFor(request('mcp__phone__intent', kind));
      expect(result.effect.wire, 'reminder_scheduled');
      expect(result.evidence, DshPhoneEvidence.unknown);
      expect(result.toJson(), receipt());
    }
  });
  test('reminder receipts cannot claim other effects or execution evidence', () {
    for (final pair in [
      ('mcp__phone__open', 'alarm'),
      ('mcp__phone__intent', 'calendar'),
      ('mcp__phone__notify', 'timer'),
    ]) {
      final result = DshPhoneResult.fromJson(receipt());
      expect(() => result.validateFor(request(pair.$1, pair.$2)), throwsA(isA<DshProtocolException>()));
    }
    for (final value in [
      receipt(evidence: 'opened_ui'),
      receipt(evidence: 'user_confirmed'),
      receipt(dispatched: false),
    ]) {
      expect(
        () => DshPhoneResult.fromJson(value).validateFor(request('mcp__phone__intent', 'alarm')),
        throwsA(isA<DshProtocolException>()),
      );
    }
  });
  test('old Android opened UI receipts retain their exact encoding and acceptance', () {
    final wire = receipt(effect: 'opened_ui', evidence: 'opened_ui');
    for (final kind in ['alarm', 'timer', 'calendar']) {
      final result = DshPhoneResult.fromJson(wire);
      result.validateFor(request('mcp__phone__intent', kind));
      expect(jsonEncode(result.toJson()), jsonEncode(wire));
    }
  });
  test('failure cannot carry a scheduled reminder effect', () {
    final value = {...receipt(), 'status': 'unknown'};
    expect(
      () => DshPhoneResult.fromJson(value).validateFor(request('mcp__phone__intent', 'timer')),
      throwsA(isA<DshProtocolException>()),
    );
  });
}
