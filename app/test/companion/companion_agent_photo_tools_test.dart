import 'dart:convert';

import 'package:dsh_app/companion/companion_agent_photo_tools.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _media = MethodChannel('dsh/media');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(_media, null));

  test('lists the album and describes the chosen photo through the picture model', () async {
    final asked = <String>[];
    messenger.setMockMethodCallHandler(_media, (call) async {
      switch (call.method) {
        case 'recentPhotos':
          return [
            {
              'id': '41',
              'name': 'IMG_1.jpg',
              'taken_at_ms': 1795309200000,
              'album': 'Camera',
              'width': 4000,
              'height': 3000,
            },
          ];
        case 'readPhoto':
          expect(call.arguments, {'id': '41', 'maxEdge': 512});
          return {
            'bytes': Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]),
            'width': 512,
            'height': 384,
            'mime_type': 'image/jpeg',
          };
      }
      throw StateError(call.method);
    });
    final tools = CompanionAgentPhotoTools(
      describe: (image, question) async {
        asked.add(question);
        return const CompanionPhotoSight.seen('海边的日落。');
      },
    );
    final list = await tools.bindings.first.execute(
      const CompanionAgentToolCall(id: 'list', name: 'photos_recent', input: {}),
    );
    final photo = ((jsonDecode(list.content) as Map)['photos'] as List).single as Map;
    expect(photo['id'], '41');
    expect(photo['taken_at'], isA<String>());
    final view = await tools.bindings.last.execute(
      const CompanionAgentToolCall(id: 'view', name: 'photo_view', input: {'id': '41', 'question': '在哪拍的？'}),
    );
    expect(view.isError, isFalse);
    expect((jsonDecode(view.content) as Map)['description'], '海边的日落。');
    expect(asked, ['在哪拍的？']);
  });

  test('a refused permission, a missing picture model or a failed look each say what to do', () async {
    messenger.setMockMethodCallHandler(_media, (call) async {
      if (call.method == 'recentPhotos') throw PlatformException(code: 'permission');
      return {
        'bytes': Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]),
        'width': 10,
        'height': 10,
        'mime_type': 'image/jpeg',
      };
    });
    var sight = const CompanionPhotoSight.noModel();
    final tools = CompanionAgentPhotoTools(describe: (_, _) async => sight);
    final list = await tools.bindings.first.execute(
      const CompanionAgentToolCall(id: 'list', name: 'photos_recent', input: {}),
    );
    expect((jsonDecode(list.content) as Map)['code'], 'photos_permission');
    const look = CompanionAgentToolCall(id: 'view', name: 'photo_view', input: {'id': '41'});
    expect((jsonDecode((await tools.bindings.last.execute(look)).content) as Map)['code'], 'photo_no_vision');
    sight = const CompanionPhotoSight.failed();
    expect((jsonDecode((await tools.bindings.last.execute(look)).content) as Map)['code'], 'photo_look_failed');
  });
}
