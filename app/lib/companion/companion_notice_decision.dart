// A model can select an input index. It cannot author the source app, time or key.
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';

import 'companion_notice_channel.dart';

enum CompanionNoticeAction { say, remember }

class CompanionNoticeDecision {
  const CompanionNoticeDecision({
    required this.action,
    required this.pkg,
    required this.appName,
    required this.text,
    required this.key,
    required this.eventId,
    required this.personId,
    required this.atMs,
    required this.epoch,
    required this.consentEpoch,
    required this.offerReply,
  });

  final CompanionNoticeAction action;
  final String pkg, appName, text, key, eventId;
  final String? personId;
  final int atMs, epoch, consentEpoch;
  final bool offerReply;
}

final _unsafeCharacters = RegExp(r'[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]');

bool _shortLine(Object? value, int max) =>
    value is String && value.trim().isNotEmpty && value.runes.length <= max && !_unsafeCharacters.hasMatch(value);

String _normalized(String value) => value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
// Native puts distinct Android title/body/line fields in a segment separated
// by a middle dot. Compare every field in the batch: a model can misattribute
// a different input index or wrap a complete body in the companion's own words.
bool _copiesSource(String text, Iterable<String> fields) {
  final output = _normalized(text);
  final runes = output.runes.toList();
  final excerpts = <String>{
    for (var i = 0; i + 12 <= runes.length; i++) String.fromCharCodes(runes.getRange(i, i + 12)),
  };
  for (final source in fields) {
    if (source == output || (source.runes.length >= 4 && output.contains(source)) || excerpts.any(source.contains)) {
      return true;
    }
  }
  return false;
}

List<CompanionNoticeDecision> companionNoticeDecisions(
  String json,
  CompanionNoticeBatch batch, {
  required String Function(String kind, String value) fingerprint,
}) {
  if (json.length > 16000) {
    throw const FormatException('Oversize notice response');
  }
  final decoded = jsonDecode(json);
  if (decoded is! List || decoded.length != batch.items.length) {
    throw const FormatException('Invalid decision count');
  }
  final fields = {
    for (final item in batch.items)
      for (final segment in item.segments)
        for (final part in segment.text.split(RegExp(r' · |[\r\n]+')))
          if (part.trim().isNotEmpty) _normalized(part),
  };
  final seen = <int>{};
  final decisions = <CompanionNoticeDecision>[];
  for (final row in decoded) {
    if (row is! Map) throw const FormatException('Invalid decision');
    final id = row['id'];
    if (id is! int || id < 0 || id >= batch.items.length || !seen.add(id)) {
      throw const FormatException('Invalid decision index');
    }
    final action = row['action'];
    if (action == 'ignore' && row.length == 2) continue;
    if (action != 'remember' && action != 'say') {
      throw const FormatException('Unknown notice action');
    }
    final say = action == 'say';
    final keys = {
      'id',
      'segment',
      'action',
      'text',
      'person',
      if (say) 'offerReply' else ...['topic', 'sensitive'],
    };
    if (row.length != keys.length || !row.keys.every(keys.contains)) continue;
    final text = row['text'];
    final person = row['person'];
    if (!_shortLine(text, say ? 60 : 120) || person is! String || (person.isNotEmpty && !_shortLine(person, 40))) {
      continue;
    }
    final item = batch.items[id];
    final index = row['segment'];
    if (index is! int || index < 0 || index >= item.segments.length) continue;
    final source = item.segments[index];
    final contents = [batch.appName, source.text, text, person].join('\n');
    // App attribution is required in every say. The same label is commonly
    // also the Android title of an email or delivery notice.
    final summary = say ? (text as String).replaceFirst(batch.appName, '').trim() : text as String;
    // An actual body can also contain the app name. Preserve matching on the
    // whole output; only a field equal to the required app label is exempt.
    final appLabel = _normalized(batch.appName);
    if (summary.isEmpty ||
        (say && _copiesSource(text, fields.where((field) => field != appLabel))) ||
        batch.level == CompanionNoticeLevel.off ||
        companionNoticeContainsSecret(contents) ||
        _copiesSource(summary, fields)) {
      continue;
    }
    final named = person.trim();
    if (named.isNotEmpty && !source.text.contains(named)) continue;
    if (say) {
      if (source.personId == null ||
          row['offerReply'] is! bool ||
          (row['offerReply'] == true && person.trim().isEmpty) ||
          !text.contains(batch.appName)) {
        continue;
      }
    } else if (batch.level != CompanionNoticeLevel.remember ||
        row['sensitive'] != false ||
        !const {'delivery', 'logistics', 'schedule', 'task'}.contains(row['topic']) ||
        companionNoticeContainsSensitiveTopic(contents) ||
        fields.any(companionNoticeContainsSensitiveTopic)) {
      continue;
    }
    decisions.add(
      CompanionNoticeDecision(
        action: say ? CompanionNoticeAction.say : CompanionNoticeAction.remember,
        pkg: batch.pkg,
        appName: batch.appName,
        text: text.trim(),
        key: item.key,
        eventId: fingerprint('event/${batch.pkg}', _normalized(source.text)),
        personId: source.personId,
        atMs: source.atMs,
        epoch: batch.epoch,
        consentEpoch: batch.consentEpoch,
        offerReply: say && row['offerReply'] == true,
      ),
    );
  }
  return decisions;
}
