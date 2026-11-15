import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_server.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Assets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(
    Uint8List.fromList(utf8.encode('<!doctype html><html lang="zh"><head></head><body></body></html>')),
  );
}

void main() {
  test('iOS scene budget is present in the initial HTML without an inline script', () async {
    final pack = await Directory.systemTemp.createTemp('companion-budget-');
    final server = await CompanionServer.start(_Assets(), pack);
    final client = HttpClient();
    try {
      Future<String> read(Map<String, String> query) async {
        final response = await (await client.getUrl(server.pageUrl(query: query))).close();
        expect(response.statusCode, HttpStatus.ok);
        return utf8.decoder.bind(response).join();
      }
      final low = await read({'gpuBudget': 'low'});
      expect(low, contains('<html data-gpu-budget="low" lang="zh">'));
      expect(low, isNot(contains('<script')));
      final ordinary = await read({});
      expect(ordinary, contains('<html lang="zh">'));
      expect(ordinary, isNot(contains('data-gpu-budget')));
      final unknown = await read({'gpuBudget': '<script>fixture</script>'});
      expect(unknown, ordinary);
    } finally {
      client.close(force: true);
      await server.close();
      await pack.delete(recursive: true);
    }
  });
}
