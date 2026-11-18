// IANA time zones for the run-time editor: the phone's own zone (the
// default, like the official page's system zone), the zone list with UTC
// offsets and Chinese city names, and wall-clock math in any zone. Rules come
// from `package:timezone` (10-year window), the same IANA data the Host's
// Temporal uses.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../l10n/l10n.dart';

bool _ready = false;

/// Loads the zone rules once (a few milliseconds).
void ensureTimeZones() {
  if (_ready) return;
  tzdata.initializeTimeZones();
  _ready = true;
}

/// The location for [name], or null when the rules don't know it.
tz.Location? zoneLocation(String name) {
  ensureTimeZones();
  if (name == 'UTC') return tz.UTC;
  try {
    return tz.getLocation(name);
  } on Object {
    return null;
  }
}

/// Whether the Host would take [name]: `UTC` or an `Area/Location` the rules
/// know.
bool isKnownZone(String name) => zoneLocation(name) != null;

/// `UTC+08:00`, `UTC−03:30`, `UTC` for zero.
String formatUtcOffset(Duration offset) {
  if (offset == Duration.zero) return 'UTC';
  final minutes = offset.inMinutes.abs();
  final sign = offset.isNegative ? '−' : '+';
  return 'UTC$sign${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';
}

/// Current offset of [name] at [at] (default now).
Duration? zoneOffset(String name, {DateTime? at}) {
  final location = zoneLocation(name);
  if (location == null) return null;
  final instant = (at ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
  return location.timeZone(instant).offset;
}

/// Chinese names for the zones people pick most; others show their city part.
Map<String, String> get _zoneNames => {
  'UTC': appL10n.featuresZoneUTC,
  'Asia/Shanghai': appL10n.featuresZoneShanghai,
  'Asia/Urumqi': appL10n.featuresZoneUrumqi,
  'Asia/Hong_Kong': appL10n.featuresZoneHongKong,
  'Asia/Macau': appL10n.featuresZoneMacau,
  'Asia/Taipei': appL10n.featuresZoneTaipei,
  'Asia/Tokyo': appL10n.featuresZoneTokyo,
  'Asia/Seoul': appL10n.featuresZoneSeoul,
  'Asia/Singapore': appL10n.featuresZoneSingapore,
  'Asia/Kuala_Lumpur': appL10n.featuresZoneKualaLumpur,
  'Asia/Bangkok': appL10n.featuresZoneBangkok,
  'Asia/Ho_Chi_Minh': appL10n.featuresZoneHoChiMinh,
  'Asia/Jakarta': appL10n.featuresZoneJakarta,
  'Asia/Manila': appL10n.featuresZoneManila,
  'Asia/Kolkata': appL10n.featuresZoneKolkata,
  'Asia/Dubai': appL10n.featuresZoneDubai,
  'Asia/Jerusalem': appL10n.featuresZoneJerusalem,
  'Europe/London': appL10n.featuresZoneLondon,
  'Europe/Dublin': appL10n.featuresZoneDublin,
  'Europe/Lisbon': appL10n.featuresZoneLisbon,
  'Europe/Paris': appL10n.featuresZoneParis,
  'Europe/Berlin': appL10n.featuresZoneBerlin,
  'Europe/Madrid': appL10n.featuresZoneMadrid,
  'Europe/Rome': appL10n.featuresZoneRome,
  'Europe/Amsterdam': appL10n.featuresZoneAmsterdam,
  'Europe/Zurich': appL10n.featuresZoneZurich,
  'Europe/Stockholm': appL10n.featuresZoneStockholm,
  'Europe/Warsaw': appL10n.featuresZoneWarsaw,
  'Europe/Athens': appL10n.featuresZoneAthens,
  'Europe/Istanbul': appL10n.featuresZoneIstanbul,
  'Europe/Moscow': appL10n.featuresZoneMoscow,
  'Africa/Cairo': appL10n.featuresZoneCairo,
  'Africa/Johannesburg': appL10n.featuresZoneJohannesburg,
  'Africa/Lagos': appL10n.featuresZoneLagos,
  'America/New_York': appL10n.featuresZoneNewYork,
  'America/Toronto': appL10n.featuresZoneToronto,
  'America/Chicago': appL10n.featuresZoneChicago,
  'America/Denver': appL10n.featuresZoneDenver,
  'America/Phoenix': appL10n.featuresZonePhoenix,
  'America/Los_Angeles': appL10n.featuresZoneLosAngeles,
  'America/Vancouver': appL10n.featuresZoneVancouver,
  'America/Anchorage': appL10n.featuresZoneAnchorage,
  'America/Mexico_City': appL10n.featuresZoneMexicoCity,
  'America/Bogota': appL10n.featuresZoneBogota,
  'America/Lima': appL10n.featuresZoneLima,
  'America/Santiago': appL10n.featuresZoneSantiago,
  'America/Sao_Paulo': appL10n.featuresZoneSaoPaulo,
  'America/Argentina/Buenos_Aires': appL10n.featuresZoneBuenosAires,
  'Pacific/Honolulu': appL10n.featuresZoneHonolulu,
  'Pacific/Auckland': appL10n.featuresZoneAuckland,
  'Australia/Sydney': appL10n.featuresZoneSydney,
  'Australia/Melbourne': appL10n.featuresZoneMelbourne,
  'Australia/Brisbane': appL10n.featuresZoneBrisbane,
  'Australia/Perth': appL10n.featuresZonePerth,
};

/// Whether [name] is one of the zones people pick most (it has a Chinese
/// name).
bool isCommonZone(String name) => _zoneNames.containsKey(name);

/// `上海`, `纽约`; unknown zones read their last segment (`Kathmandu`).
String zoneCity(String name) => _zoneNames[name] ?? name.split('/').last.replaceAll('_', ' ');

/// One selectable zone.
class ZoneChoice {
  const ZoneChoice(this.name, this.offset);

  /// IANA name (`Asia/Shanghai`) or `UTC`.
  final String name;
  final Duration offset;

  String get city => zoneCity(name);
  String get offsetLabel => formatUtcOffset(offset);

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        city.toLowerCase().contains(q) ||
        offsetLabel.toLowerCase().replaceAll('−', '-').contains(q.replaceAll('−', '-'));
  }
}

/// Every `Area/Location` zone plus `UTC`, by current offset then name.
List<ZoneChoice> allZones({DateTime? at}) {
  ensureTimeZones();
  final instant = (at ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
  final zones = <ZoneChoice>[
    const ZoneChoice('UTC', Duration.zero),
    for (final MapEntry(:key, :value) in tz.timeZoneDatabase.locations.entries)
      if (key.contains('/') && !key.startsWith('Etc/')) ZoneChoice(key, value.timeZone(instant).offset),
  ];
  zones.sort((a, b) {
    final byOffset = a.offset.compareTo(b.offset);
    return byOffset != 0 ? byOffset : a.name.compareTo(b.name);
  });
  return zones;
}

/// Zones preferred when only an offset is known, one per common offset.
const _byOffset = {
  480: 'Asia/Shanghai',
  540: 'Asia/Tokyo',
  420: 'Asia/Bangkok',
  330: 'Asia/Kolkata',
  240: 'Asia/Dubai',
  180: 'Europe/Moscow',
  120: 'Europe/Athens',
  60: 'Europe/Berlin',
  0: 'Europe/London',
  -300: 'America/New_York',
  -360: 'America/Chicago',
  -420: 'America/Denver',
  -480: 'America/Los_Angeles',
  600: 'Australia/Sydney',
};

/// The phone's IANA zone: `TZ`, then the system's default time zone (Android,
/// HarmonyOS), then the Linux zone files, then a zone with the current offset, then `UTC`.
Future<String> detectDeviceTimeZone() async {
  ensureTimeZones();
  bool usable(String? name) => name != null && name.isNotEmpty && isKnownZone(name);
  final env = Platform.environment['TZ']?.replaceFirst(RegExp(r'^:'), '');
  if (usable(env)) return env!;
  try {
    if (Platform.isAndroid || Platform.isIOS || Platform.operatingSystem == 'ohos') {
      return await detectAndroidTimeZone();
    } else if (Platform.isLinux || Platform.isMacOS) {
      final file = File('/etc/timezone');
      if (file.existsSync()) {
        final name = file.readAsStringSync().trim();
        if (usable(name)) return name;
      }
      final link = Link('/etc/localtime');
      if (link.existsSync()) {
        final target = link.targetSync();
        final at = target.indexOf('zoneinfo/');
        if (at >= 0) {
          final name = target.substring(at + 'zoneinfo/'.length);
          if (usable(name)) return name;
        }
      }
    }
  } on Object {
    // Fall through to the offset match.
  }
  return _zoneForOffset(DateTime.now().timeZoneOffset);
}

/// Android's system zone without starting a child process. The optional offset
/// makes the existing fallback deterministic in channel tests.
Future<String> detectAndroidTimeZone({Duration? fallbackOffset}) async {
  try {
    final name = (await const MethodChannel('dsh/app').invokeMethod<String>('getTimeZoneId'))?.trim();
    if (name != null && name.isNotEmpty && isKnownZone(name)) return name;
  } on Object {
    // A missing activity channel or platform failure uses the same fallback.
  }
  return _zoneForOffset(fallbackOffset ?? DateTime.now().timeZoneOffset);
}

String _zoneForOffset(Duration offset) {
  final preferred = _byOffset[offset.inMinutes];
  if (preferred != null) return preferred;
  for (final zone in allZones()) {
    if (zone.offset == offset) return zone.name;
  }
  return 'UTC';
}

/// [instant] as wall-clock fields in [zone] (null when the zone is unknown).
tz.TZDateTime? inZone(DateTime instant, String zone) {
  final location = zoneLocation(zone);
  return location == null ? null : tz.TZDateTime.from(instant, location);
}

/// The instant of a wall-clock time in [zone]; null for an unknown zone or a
/// time the zone skips (a DST gap), which the Host also skips.
DateTime? zonedInstant(String zone, int year, int month, int day, int hour, int minute, [int second = 0]) {
  final location = zoneLocation(zone);
  if (location == null) return null;
  final at = tz.TZDateTime(location, year, month, day, hour, minute, second);
  if (at.year != year || at.month != month || at.day != day || at.hour != hour || at.minute != minute) {
    return null;
  }
  return DateTime.fromMillisecondsSinceEpoch(at.millisecondsSinceEpoch, isUtc: true);
}
