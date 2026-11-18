import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';

/// Local data adapter. Owner UI enables the setting, observes DshPhoneSession,
/// and calls its explicit continue/stop actions; this file creates no widgets.
final class OhosPhoneNative implements DshPhoneNative {
  const OhosPhoneNative();
  static const _channel = MethodChannel('dsh/runtime');

  Future<Object?> _call(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      throw const DshPhoneException('unsupported', 0);
    } on PlatformException catch (error) {
      final code = RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(error.code) ? error.code : 'native_unavailable';
      throw DshPhoneException(code, 0);
    }
  }

  @override
  Future<DshPhoneOwner> attach() async => DshPhoneOwner.fromNative(await _call('phoneAttach', {'enabled': true}));

  @override
  Future<void> retire(DshPhoneOwner owner) async {
    await _call('phoneRetire', owner.nativeScope);
  }

  @override
  Future<DshPhoneResult> execute(DshPhoneClaim claim) async =>
      DshPhoneResult.fromJson(await _call('phoneExecute', claim.nativeIdentity));

  @override
  Future<DshPhoneResult> continueHandoff(DshPhoneClaim claim) async =>
      DshPhoneResult.fromJson(await _call('phoneHandoffContinue', claim.nativeIdentity));

  @override
  Future<bool?> cancel(DshPhoneClaim claim) async {
    final raw = await _call('phoneCancel', claim.nativeIdentity);
    if (raw is! Map ||
        raw.length != 1 ||
        !raw.containsKey('dispatched') ||
        raw['dispatched'] != null && raw['dispatched'] is! bool) {
      throw const DshProtocolException('Invalid native phone cancellation');
    }
    return raw['dispatched'] as bool?;
  }

  @override
  Future<DshPhoneCheck> check(DshPhoneClaim claim) async =>
      DshPhoneCheck.fromNative(await _call('phoneCheck', claim.nativeIdentity));
}
