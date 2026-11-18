import 'package:flutter/services.dart';

import 'authorized_workspaces.dart';

class MethodAuthorizedWorkspaces extends AuthorizedWorkspacesClient {
  MethodAuthorizedWorkspaces() : super(_invoke);
  static const _channel = MethodChannel('dsh/authorized-workspaces');

  static Future<Object?> _invoke(
    String method,
    Map<String, Object?> arguments,
  ) async {
    try {
      switch (method) {
        case 'capabilities':
          return await _channel.invokeMethod<Object?>(
            'capabilities',
            arguments,
          );
        case 'list':
          return await _channel.invokeMethod<Object?>('list', arguments);
        case 'select':
          return await _channel.invokeMethod<Object?>('select', arguments);
        case 'attach':
          return await _channel.invokeMethod<Object?>('attach', arguments);
        case 'persist':
          return await _channel.invokeMethod<Object?>('persist', arguments);
        case 'activate':
          return await _channel.invokeMethod<Object?>('activate', arguments);
        case 'deactivate':
          return await _channel.invokeMethod<Object?>('deactivate', arguments);
        case 'revoke':
          return await _channel.invokeMethod<Object?>('revoke', arguments);
        case 'forget':
          return await _channel.invokeMethod<Object?>('forget', arguments);
        case 'cancel':
          return await _channel.invokeMethod<Object?>('cancel', arguments);
        default:
          throw const AuthorizedWorkspaceFailure(
            'unsupported_method',
            '目录授权方法不受支持。',
          );
      }
    } on MissingPluginException {
      throw const AuthorizedWorkspaceFailure('unsupported', '当前平台没有鸿蒙目录授权通道。');
    } on PlatformException catch (error) {
      throw AuthorizedWorkspaceFailure(
        error.code,
        error.message ?? '目录授权操作未完成。',
        details: error.details,
      );
    }
  }

  @override
  Future<AuthorizedWorkspaceCapabilities> capabilities() async {
    try {
      return await super.capabilities();
    } on AuthorizedWorkspaceFailure catch (error) {
      if (error.code != 'unsupported') rethrow;
      return const AuthorizedWorkspaceCapabilities.unavailable();
    }
  }
}
