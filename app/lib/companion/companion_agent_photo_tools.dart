import 'dart:convert';

import 'package:dsh_client/dsh_client.dart' show CompanionScreenImage;
import 'package:flutter/services.dart';

import 'companion_light.dart';

/// What the picture model saw: its words, or why there are none.
class CompanionPhotoSight {
  const CompanionPhotoSight.seen(String this.text) : noModel = false;

  /// No picture model is chosen, or the current connection cannot reach one.
  const CompanionPhotoSight.noModel() : text = null, noModel = true;

  /// The request failed, was cut off or was stopped: worth another try.
  const CompanionPhotoSight.failed() : text = null, noModel = false;

  final String? text;
  final bool noModel;
}

/// Her look at the person's photo album (media/MediaPlugin.kt). They asked her
/// to, so the only ask is Android's own photo permission, made natively.
class CompanionAgentPhotoTools {
  CompanionAgentPhotoTools({required this.describe, this.channel = const MethodChannel('dsh/media')});

  /// What the selected picture model sees in [image].
  final Future<CompanionPhotoSight> Function(CompanionScreenImage image, String question) describe;
  final MethodChannel channel;

  static const _recent = CompanionAgentTool(
    name: 'photos_recent',
    description: '列出对方相册里最近的照片（新的在前）：编号、文件名、拍摄时间、相册和尺寸。对方让你看相册、找照片时直接用。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 50, 'description': '最多几张，默认 20'},
      },
      'additionalProperties': false,
    },
  );

  static const _view = CompanionAgentTool(
    name: 'photo_view',
    description: '看相册里的一张照片，返回画面描述。id 取自 photos_recent；question 写想从照片里看什么。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'photos_recent 返回的编号'},
        'question': {'type': 'string', 'description': '想看什么，例如「这是在哪拍的」；可省略'},
      },
      'required': ['id'],
      'additionalProperties': false,
    },
  );

  List<({CompanionAgentTool definition, Future<CompanionAgentToolResult> Function(CompanionAgentToolCall) execute})>
  get bindings => [(definition: _recent, execute: _list), (definition: _view, execute: _look)];

  Future<CompanionAgentToolResult> _list(CompanionAgentToolCall call) async {
    try {
      final limit = call.input['limit'];
      final rows = await channel.invokeListMethod<Object?>('recentPhotos', {'limit': limit is int ? limit : 20});
      return CompanionAgentToolResult(
        content: jsonEncode({
          'photos': [
            for (final row in rows ?? const [])
              if (row is Map)
                {
                  'id': row['id'],
                  'name': row['name'],
                  if (row['taken_at_ms'] case final int at)
                    'taken_at': DateTime.fromMillisecondsSinceEpoch(at).toIso8601String().substring(0, 16),
                  'album': row['album'],
                  'width': row['width'],
                  'height': row['height'],
                },
          ],
        }),
      );
    } on PlatformException catch (error) {
      return _failed(error);
    } on MissingPluginException {
      return _error('photos_unavailable', '这台设备上读不了相册。');
    }
  }

  Future<CompanionAgentToolResult> _look(CompanionAgentToolCall call) async {
    final id = call.input['id'];
    if (id is! String || id.isEmpty) return _error('photo_id_missing', '先用 photos_recent 拿到照片编号。');
    try {
      final image = CompanionScreenImage.fromNative(
        await channel.invokeMethod<Object?>('readPhoto', {'id': id, 'maxEdge': 512}),
      );
      if (image == null) return _error('photo_unreadable', '这张照片读不出来，换一张试试。');
      final question = call.input['question'];
      final seen = await describe(
        image,
        question is String && question.trim().isNotEmpty ? question.trim() : '这张照片里有什么？',
      );
      if (seen.noModel) {
        return _error(
          'photo_no_vision',
          '照片拿到了，但现在没有能看图的模型。请对方在伙伴小屋的「陪你看屏幕」里选「看图使用的模型」'
              '（要连着电脑上的 DSH），选好再让你看。',
        );
      }
      final text = seen.text;
      if (text == null) return _error('photo_look_failed', '这次没看成（请求失败或被打断），再看一次就好。');
      // Words in a picture are data, like a page on screen.
      return CompanionAgentToolResult(content: jsonEncode({'id': id, 'description': text}), externalWebContent: true);
    } on PlatformException catch (error) {
      return _failed(error);
    } on MissingPluginException {
      return _error('photos_unavailable', '这台设备上读不了相册。');
    }
  }

  CompanionAgentToolResult _failed(PlatformException error) => switch (error.code) {
    'permission' => _error(
      'photos_permission',
      '还没有相册权限。系统弹窗里点允许就行；没弹窗的话，请对方到 系统设置 → 应用 → DSH Go → 权限 里打开「照片和视频」，再让你看。',
    ),
    'missing' => _error('photo_missing', '这张照片已经不在相册里了，重新列一下。'),
    _ => _error('photos_failed', '没读到相册：${error.message ?? error.code}'),
  };

  CompanionAgentToolResult _error(String code, String message) =>
      CompanionAgentToolResult(content: jsonEncode({'code': code, 'message': message}), isError: true);
}
