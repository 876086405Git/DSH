/// Fixed, content-free evidence only. Never retain the native response map.
class SystemImeEvidence {
  SystemImeEvidence._(this.code, this.capturedAt, List<SystemImeEvent> events, {this.source = 'privilegedIme'})
    : events = List.unmodifiable(events);

  static const maxEvents = 64;
  static const windowMs = 120000;
  static const codes = {
    'ok', 'noEvents', 'unavailable', 'unsupported', 'denied', 'cancelled',
    'busy', 'timeout', 'limitExceeded', 'failed',
  };
  static const reasons = {
    'SHOW_SOFT_INPUT', 'SHOW_SOFT_INPUT_FROM_IME', 'SHOW_AUTO_EDITOR_FORWARD_NAV',
    'SHOW_STATE_VISIBLE_FORWARD_NAV', 'SHOW_STATE_ALWAYS_VISIBLE', 'HIDE_SOFT_INPUT',
    'HIDE_SOFT_INPUT_FROM_IME', 'HIDE_STATE_HIDDEN_FORWARD_NAV',
    'HIDE_ALWAYS_HIDDEN_STATE', 'HIDE_WINDOW_LOST_FOCUS',
  };

  final String source;
  final String code;
  final int capturedAt;
  final List<SystemImeEvent> events;
  bool get ok => code == 'ok' || code == 'noEvents';

  factory SystemImeEvidence.failure(String code, DateTime at, {String source = 'privilegedIme'}) =>
      SystemImeEvidence._(codes.contains(code) && code != 'ok' && code != 'noEvents' ? code : 'failed',
          at.millisecondsSinceEpoch, const [], source: source == 'ohosWindowGeometry' ? source : 'privilegedIme');

  factory SystemImeEvidence.fromNative(Object? raw, {required DateTime now}) {
    final source = raw is Map && raw['source'] == 'ohosWindowGeometry' ? 'ohosWindowGeometry' : 'privilegedIme';
    SystemImeEvidence invalid() => SystemImeEvidence.failure('failed', now, source: source);
    if (raw is! Map) return invalid();
    final code = raw['code'];
    final capturedAt = raw['capturedAt'];
    final rows = raw['events'];
    final nowMs = now.millisecondsSinceEpoch;
    if (code is! String || !codes.contains(code) ||
        raw['source'] != source || raw['ok'] is! bool ||
        raw['ok'] != (code == 'ok' || code == 'noEvents') ||
        capturedAt is! int || capturedAt <= 0 ||
        capturedAt > nowMs || capturedAt < nowMs - windowMs || rows is! List) {
      return invalid();
    }
    if (rows.length > maxEvents) return SystemImeEvidence.failure('limitExceeded', now, source: source);
    if ((code == 'ok' && rows.isEmpty) || (code != 'ok' && rows.isNotEmpty)) return invalid();
    final events = <SystemImeEvent>[];
    for (final row in rows) {
      if (row is! Map) return invalid();
      final timestamp = row['timestamp'];
      final event = row['event'];
      final fromUser = row['fromUser'];
      final reason = row['reason'];
      final origin = row['origin'];
      if (timestamp is! int || timestamp < capturedAt - windowMs || timestamp > capturedAt ||
          !row.containsKey('fromUser') || (fromUser != null && fromUser is! bool) ||
          event is! String || reason is! String || origin is! String) {
        return invalid();
      }
      if (source == 'ohosWindowGeometry') {
        if (origin != 'ohosWindow' || reason != 'unknown' || fromUser != null) return invalid();
        final geometry = _keyboardGeometry(event, row['geometry']);
        if (geometry == null) return invalid();
        events.add(SystemImeEvent._(timestamp, event, null, reason, origin, geometry: geometry));
        continue;
      }
      final request = event == 'requestShow' || event == 'requestHide';
      final valid = switch (origin) {
        'imeTracker' => request && reasons.contains(reason),
        'inputMethodManager' => request && fromUser == null && reason == 'unknown',
        'inputConnection' => event == 'connectionClosed' && fromUser == null && reason == 'unknown',
        _ => false,
      };
      if (!valid) return invalid();
      events.add(SystemImeEvent._(timestamp, event, fromUser, reason, origin));
    }
    if (source == 'privilegedIme') {
      events.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    }
    return SystemImeEvidence._(code, capturedAt, events, source: source);
  }

  Map<String, Object?> toJson() => {
    'ok': ok,
    'code': code,
    'capturedAt': capturedAt,
    'source': source,
    'events': events.map((event) => event.toJson()).toList(),
  };
}

class SystemImeEvent {
  const SystemImeEvent._(this.timestamp, this.event, this.fromUser, this.reason, this.origin, {this.geometry});

  final int timestamp;
  final String event;
  final bool? fromUser;
  final String reason;
  final String origin;
  final Map<String, Object?>? geometry;

  Map<String, Object?> toJson() => {
    'timestamp': timestamp,
    'event': event,
    'fromUser': fromUser,
    'reason': reason,
    'origin': origin,
    if (geometry != null) 'geometry': geometry,
  };
}

/// Fixed SDK geometry fields in pixels. The timestamp is callback receipt time.
Map<String, Object?>? _keyboardGeometry(String event, Object? raw) {
  if (raw is! Map) return null;
  final out = <String, Object?>{};
  bool finite(Object? value) => value is num && value.isFinite;
  bool rectangle(String key) {
    final values = raw[key];
    if (values is! List || values.length != 4 || !values.every(finite) ||
        (values[2] as num) < 0 || (values[3] as num) < 0) {
      return false;
    }
    out[key] = List<num>.unmodifiable(values.cast<num>());
    return true;
  }
  switch (event) {
    case 'willShow' || 'willHide' || 'didShow' || 'didHide':
      if (!rectangle('begin') || !rectangle('end')) return null;
      if (raw.containsKey('animated')) {
        if (raw['animated'] is! bool) return null;
        out['animated'] = raw['animated'];
      }
      if (raw.containsKey('curve')) {
        if (!finite(raw['curve'])) return null;
        out['curve'] = raw['curve'];
      }
      if (raw.containsKey('durationMs')) {
        final duration = raw['durationMs'];
        if (!finite(duration) || (duration as num) < 0 || duration > 3000) return null;
        out['durationMs'] = duration;
      }
      if (raw.containsKey('curveParams')) {
        final values = raw['curveParams'];
        if (values is! List || values.length > 4 || !values.every(finite)) return null;
        out['curveParams'] = List<num>.unmodifiable(values.cast<num>());
      }
    case 'height':
      final height = raw['height'];
      if (!finite(height) || (height as num) < 0) return null;
      out['height'] = height;
    case 'avoidArea':
      if (!['left', 'top', 'right', 'bottom'].every(rectangle)) return null;
    default:
      return null;
  }
  return Map.unmodifiable(out);
}
