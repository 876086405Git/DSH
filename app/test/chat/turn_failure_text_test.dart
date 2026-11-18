import 'package:dsh_app/ui/chat/widgets/turn_failure_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cases = <String?, String>{
    'AUTH': 'API Key 无效或已过期',
    'INVALID_CREDENTIAL': 'API Key 无效或已过期',
    'QUOTA': '余额不足',
    'ACCOUNT_QUOTA': '账号额度已用完',
    'RATE_LIMIT': '请求太频繁，稍后再试',
    'CONTEXT_WINDOW_EXCEEDED': '对话太长。若 /compact 也失败，请新建对话或换模型',
    'SERVER': '模型服务暂时不可用',
    'HTTP_503': '模型服务暂时不可用',
    'TIMEOUT': '模型响应超时',
    'TRANSPORT': '没能连上模型服务',
    'EMPTY_RESPONSE': '模型没有返回内容',
    // DSH 0.2.1-rc.4's listed-catalog refusals (llm-deepseek refuseListedModel).
    'CLIENT_UPGRADE_REQUIRED': '这个模型需要新版引擎',
    'MODEL_UNSUPPORTED': '当前模型不可用',
    'UNSUPPORTED_REASONING_EFFORT': '当前模型不支持此推理档位，请调整档位或换模型',
    null: '本轮出错了',
    'unknown: raw exception': '本轮出错了',
  };
  for (final entry in cases.entries) {
    test('${entry.key}', () => expect(turnFailureText(entry.key), entry.value));
  }

  group('AUTH says which kind', () {
    for (final message in const [
      '403 {"error":{"type":"permission_denied"}}',
      'OpenAI API error: 403 forbidden',
      'permission_error: this key cannot use this model',
    ]) {
      test(message, () => expect(turnFailureText('AUTH', message: message), '凭据不可用或权限不足'));
    }
    for (final message in const [null, '', '401 invalid api key', 'authentication_error: expired']) {
      test('$message', () => expect(turnFailureText('AUTH', message: message), 'API Key 无效或已过期'));
    }
    test('the message only matters for AUTH', () {
      expect(turnFailureText('INVALID_CREDENTIAL', message: '403'), 'API Key 无效或已过期');
      expect(turnFailureText('SERVER', message: '403'), turnFailureText('SERVER'));
    });
  });
}
