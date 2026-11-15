import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 提示词增强按钮的三态。
enum PromptEnhancePhase {
  /// 输入框有内容、没有可撤回的结果：点一下发起增强。
  idle,

  /// 请求在途：点一下取消。
  busy,

  /// 当前草稿仍等于刚填入的结果：点一下恢复原文。
  undo,
}

/// 一次增强的状态。撤销不是独立开关，而是「草稿 === 刚填入的结果」推导出来的，
/// 所以编辑一个字、清空、发送、切换会话都会自动回到 [PromptEnhancePhase.idle]。
@immutable
class PromptEnhanceState {
  const PromptEnhanceState({
    this.phase = PromptEnhancePhase.idle,
    this.result,
    this.original,
    this.sessionKey = '',
    this.failureCode,
    this.contextUsed = false,
    this.trimmed = false,
  });

  final PromptEnhancePhase phase;

  /// 刚填入输入框的增强结果。
  final String? result;

  /// 增强前的原文（点 ↺ 恢复它）。
  final String? original;

  /// 这轮状态属于哪个会话（或 `new`）；切会话时不相等的状态直接作废。
  final String sessionKey;

  final String? failureCode;
  final bool contextUsed;
  final bool trimmed;

  /// [text] 是当前草稿时，撤销按钮才成立。
  bool canUndoFor(String text) =>
      phase == PromptEnhancePhase.undo && result != null && result == text;

  PromptEnhanceState copyWith({
    PromptEnhancePhase? phase,
    String? result,
    String? original,
    String? sessionKey,
    String? failureCode,
    bool? contextUsed,
    bool? trimmed,
    bool clearResult = false,
  }) {
    return PromptEnhanceState(
      phase: phase ?? this.phase,
      result: clearResult ? null : (result ?? this.result),
      original: clearResult ? null : (original ?? this.original),
      sessionKey: sessionKey ?? this.sessionKey,
      failureCode: failureCode,
      contextUsed: contextUsed ?? this.contextUsed,
      trimmed: trimmed ?? this.trimmed,
    );
  }
}

class PromptEnhanceController extends Notifier<PromptEnhanceState> {
  @override
  PromptEnhanceState build() => const PromptEnhanceState();

  /// 发起请求前：进入 busy，并记住本轮属于哪个会话。
  void start(String sessionKey) {
    state = PromptEnhanceState(phase: PromptEnhancePhase.busy, sessionKey: sessionKey);
  }

  /// 成功填入后：进入 undo，记下原文与结果。
  void succeeded({
    required String sessionKey,
    required String original,
    required String result,
    bool contextUsed = false,
    bool trimmed = false,
  }) {
    state = PromptEnhanceState(
      phase: PromptEnhancePhase.undo,
      sessionKey: sessionKey,
      original: original,
      result: result,
      contextUsed: contextUsed,
      trimmed: trimmed,
    );
  }

  /// 失败或取消：回到 idle，草稿不动。
  void reset({String? sessionKey, String? failureCode}) {
    state = PromptEnhanceState(
      sessionKey: sessionKey ?? state.sessionKey,
      failureCode: failureCode,
    );
  }
}

final promptEnhanceProvider = NotifierProvider<PromptEnhanceController, PromptEnhanceState>(
  PromptEnhanceController.new,
);
