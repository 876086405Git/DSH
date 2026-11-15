import 'dart:io' show Platform;
import 'package:flutter_test/flutter_test.dart';
import '../../../../../app/lib/runtime/ios_guest.dart';

Map<Object?, Object?> status({bool suspended = false}) => {
  'schema': 1,
  'phase': 'installed',
  'available': true,
  'installed': true,
  'usable': !suspended,
  'busy': false,
  'version': '3.24.4',
  'suspended': suspended,
  'suspendedReason': suspended ? 'crashed' : null,
  'error': null,
};

void main() {
  test('suspension preserves installation and distinguishes capability from use', () {
    final value = IosGuestStatus.fromMap(status(suspended: true));
    expect(value.installed, isTrue);
    expect(value.available, isTrue);
    expect(value.usable, isFalse);
    expect(value.suspended, isTrue);
    expect(value.suspendedReason, 'crashed');
    expect(value.errorCode, isNull);
  });

  test('resume response does not mutate the earlier immutable status', () {
    final paused = IosGuestStatus.fromMap(status(suspended: true));
    final resumed = IosGuestStatus.fromMap(status());
    expect(resumed.suspended, isFalse);
    expect(resumed.suspendedReason, isNull);
    expect(resumed.usable, isTrue);
    expect(paused.suspended, isTrue);
    expect(paused.usable, isFalse);
  });

  test('older status payloads default to unsuspended', () {
    final legacy = status()..remove('suspended')..remove('suspendedReason');
    final value = IosGuestStatus.fromMap(legacy);
    expect(value.suspended, isFalse);
    expect(value.suspendedReason, isNull);
  });

  test('crash gate failure exposes the native error without claiming suspension', () {
    final payload = status()
      ..['phase'] = 'error'
      ..['usable'] = false
      ..['error'] = {'code': 'ios_guest_io', 'message': 'Cannot inspect the Linux crash record.'};
    final value = IosGuestStatus.fromMap(payload);
    expect(value.installed, isTrue);
    expect(value.usable, isFalse);
    expect(value.suspended, isFalse);
    expect(value.errorCode, 'ios_guest_io');
  });

  test('uninstalled paused state retains its crash reason', () {
    final payload = status(suspended: true)
      ..['phase'] = 'notInstalled'
      ..['installed'] = false
      ..['version'] = null;
    final value = IosGuestStatus.fromMap(payload);
    expect(value.installed, isFalse);
    expect(value.suspended, isTrue);
    expect(value.suspendedReason, 'crashed');
    expect(value.usable, isFalse);
  });

  test('resume keeps the iOS-only platform guard', () async {
    if (Platform.isIOS) return;
    await expectLater(IosGuestBridge().resume(), throwsUnsupportedError);
  });
}
