// Adapted from SillyTavern public/scripts/openai.js, src/constants.js and
// src/endpoints/backends/chat-completions.js (AGPL-3.0).
// Source commit: 7e8663cd9c184a550b37238218bdd32c6efc68e9 (1.19.0).
import 'preset.dart';

/// Reasoning fields for the engine's OpenAI-compatible transport. [source]
/// describes the active connection; imported connection fields do not select it.
Map<String, Object?> genericReasoningFields(Map<String, Object?> settings, String model, String source) {
  final show = presetTruthy(settings['show_thoughts']);
  final effort = _resolveEffort(settings['reasoning_effort'], model, source, show);
  if (source == 'openrouter') {
    return {
      'reasoning': {'exclude': !show, if (presetTruthy(effort)) 'effort': effort},
    };
  }
  // Azure applies its fixed-model mapping even when auto omitted the effort.
  // Unlike the OpenAI/custom branch, it also preserves explicitly null/falsy
  // effort values for other supported models.
  if (source == 'azure_openai') {
    if (!_openAiReasoningModels.contains(model)) return const {};
    if (model == 'gpt-5.3-chat-latest') return const {'reasoning_effort': 'medium'};
    if (!settings.containsKey('reasoning_effort') || settings['reasoning_effort'] == 'auto') return const {};
    return {'reasoning_effort': effort == 'min' ? 'minimal' : effort};
  }
  if (!const {'openai', 'custom'}.contains(source) || !presetTruthy(effort)) return const {};
  if (_openAiReasoningModels.contains(model)) {
    return {
      'reasoning_effort': model == 'gpt-5.3-chat-latest'
          ? 'medium'
          : effort == 'min'
          ? 'minimal'
          : effort,
    };
  }
  if (source == 'custom' && RegExp(r'^koboldcpp/(.+)$').hasMatch(model)) {
    return {'reasoning_effort': effort};
  }
  return const {};
}

Object? _resolveEffort(Object? effort, String model, String source, bool show) {
  if (effort == 'auto' || effort == null) return null;
  if (source == 'custom' && RegExp(r'^koboldcpp/(.+)$').hasMatch(model)) {
    return switch (effort) {
      'min' => 'minimal',
      'max' => 'xhigh',
      _ => effort,
    };
  }
  final openAi = source == 'openai' || source == 'azure_openai';
  if (effort == 'min') {
    if (source == 'openrouter' && !show) return 'none';
    if (openAi && RegExp(r'^gpt-5\.(4|5|6)').hasMatch(model)) return 'none';
    if (openAi && model.startsWith('gpt-5')) return 'min';
    return 'low';
  }
  if (effort == 'max') {
    if (openAi && model.startsWith('gpt-6-astra')) return 'max';
    if (openAi && model.startsWith('gpt-5.6')) return 'xhigh';
    return 'high';
  }
  return effort;
}

const _openAiReasoningModels = {
  'o1',
  'o3-mini',
  'o3-mini-2025-01-31',
  'o4-mini',
  'o4-mini-2025-04-16',
  'o3',
  'o3-2025-04-16',
  'gpt-5',
  'gpt-5-2025-08-07',
  'gpt-5-mini',
  'gpt-5-mini-2025-08-07',
  'gpt-5-nano',
  'gpt-5-nano-2025-08-07',
  'gpt-5.1',
  'gpt-5.1-2025-11-13',
  'gpt-5.1-chat-latest',
  'gpt-5.2',
  'gpt-5.2-2025-12-11',
  'gpt-5.2-chat-latest',
  'gpt-5.3-chat-latest',
  'gpt-5.4',
  'gpt-5.4-2026-03-05',
  'gpt-5.4-mini',
  'gpt-5.4-mini-2026-03-17',
  'gpt-5.4-nano',
  'gpt-5.4-nano-2026-03-17',
  'gpt-5.5',
  'gpt-5.5-2026-04-23',
  'gpt-5.6',
  'gpt-5.6-sol',
  'gpt-5.6-terra',
  'gpt-5.6-luna',
  'gpt-6-astra',
};
