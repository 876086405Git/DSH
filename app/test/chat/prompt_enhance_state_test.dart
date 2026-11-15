// 提示词增强三态状态机：撤销由内容推导，失败/取消不污染草稿。

import 'package:dsh_app/state/prompt_enhance_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  PromptEnhanceState state() => container.read(promptEnhanceProvider);
  PromptEnhanceController controller() => container.read(promptEnhanceProvider.notifier);

  test('初始是 idle，没有任何结果', () {
    expect(state().phase, PromptEnhancePhase.idle);
    expect(state().result, isNull);
    expect(state().original, isNull);
  });

  test('start 进入 busy 并记住会话键', () {
    controller().start('session-a');
    expect(state().phase, PromptEnhancePhase.busy);
    expect(state().sessionKey, 'session-a');
    expect(state().canUndoFor('任何内容'), isFalse, reason: '生成中不能撤销');
  });

  test('succeeded 进入 undo，且只在草稿等于结果时可撤销', () {
    controller().succeeded(
      sessionKey: 'session-a',
      original: '加个删除按钮',
      result: '请给会话列表加一个删除按钮，长按弹出确认。',
    );
    expect(state().phase, PromptEnhancePhase.undo);
    expect(state().original, '加个删除按钮');
    expect(state().canUndoFor('请给会话列表加一个删除按钮，长按弹出确认。'), isTrue);
    expect(state().canUndoFor('请给会话列表加一个删除按钮，长按弹出确认。 '), isFalse, reason: '差一个空格也不算');
    expect(state().canUndoFor('加个删除按钮'), isFalse, reason: '原文不等于结果');
  });

  test('reset 回到 idle 并清空结果（失败/取消/发送后）', () {
    controller().succeeded(sessionKey: 's', original: 'a', result: 'b');
    controller().reset(sessionKey: 's', failureCode: 'TIMEOUT');
    expect(state().phase, PromptEnhancePhase.idle);
    expect(state().result, isNull);
    expect(state().original, isNull);
    expect(state().failureCode, 'TIMEOUT');
  });

  test('收到结果时的上下文/截断标记被保留', () {
    controller().succeeded(
      sessionKey: 's',
      original: '就按刚才那个方案改',
      result: '按方案二改：先改 bridge，再改 UI。',
      contextUsed: true,
      trimmed: true,
    );
    expect(state().contextUsed, isTrue);
    expect(state().trimmed, isTrue);
  });
}
