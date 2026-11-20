// 选区朗读不把凭据交给语音：选中的一段属于密钥的部分去掉，按整条消息认。

import 'package:dsh_app/ui/chat/widgets/message_selection.dart';
import 'package:flutter_test/flutter_test.dart';

const _message = '连 postgres://admin:hunter2secret@db.example.com:5432/app 试试 test';

void main() {
  test('a selection inside an address password says nothing', () {
    expect(speakableSelection('hunter2', _message), '');
  });

  test('a selection cut through a password keeps only the words around it', () {
    expect(speakableSelection('连 postgres://admin:hunter', _message), '连 postgres://admin:');
    expect(speakableSelection('2secret@db.example.com', _message), '@db.example.com');
  });

  test('two passwords: each is cut from the selection as it was', () {
    const two = 'postgres://a:abcsecretxyz@db1.example.com postgres://a:qwerty12345@db2.example.com';
    expect(speakableSelection('etxyz@db1.example.com postgres://a:qwerty', two), '@db1.example.com postgres://a:');
  });

  test('a selection without credentials is read as it is', () {
    expect(speakableSelection('试试', _message), '试试');
    expect(speakableSelection('test', _message), 'test');
  });
}
