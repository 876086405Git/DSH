// Adapted from SillyTavern src/prompt-converters.js (AGPL-3.0).
// Source commit: 7e8663cd9c184a550b37238218bdd32c6efc68e9 (1.19.0).
import 'dart:convert';
import 'dart:math';

import 'preset.dart';
import 'prompt_types.dart';

/// ST's user-selected prompt conversion, before provider-specific conversion.
/// Unknown/none modes leave the sequence unchanged, as ST's switch does.
List<PromptSegment> postProcessPrompt(
  List<PromptSegment> input,
  String mode, {
  required String userName,
  required String characterName,
  List<String> groupNames = const [],
  required PromptTokenCounter counter,
  bool separateLast = false,
}) {
  final options = switch (mode) {
    'merge' || 'claude' => (strict: false, placeholders: false, single: false, tools: false),
    'merge_tools' => (strict: false, placeholders: false, single: false, tools: true),
    'semi' => (strict: true, placeholders: false, single: false, tools: false),
    'semi_tools' => (strict: true, placeholders: false, single: false, tools: true),
    'strict' => (strict: true, placeholders: true, single: false, tools: false),
    'strict_tools' => (strict: true, placeholders: true, single: false, tools: true),
    'single' => (strict: true, placeholders: false, single: true, tools: false),
    _ => null,
  };
  if (options == null) return input;
  return _mergeMessages(
    input,
    userName: userName,
    characterName: characterName,
    groupNames: groupNames,
    counter: counter,
    strict: options.strict,
    placeholders: options.placeholders,
    single: options.single,
    tools: options.tools,
    separateLast: separateLast,
  );
}

List<PromptSegment> _mergeMessages(
  List<PromptSegment> input, {
  required String userName,
  required String characterName,
  required List<String> groupNames,
  required PromptTokenCounter counter,
  required bool strict,
  required bool placeholders,
  required bool single,
  required bool tools,
  required bool separateLast,
}) {
  final media = <String, Map<String, Object?>>{};
  var merged = <PromptSegment>[];
  bool hasCharacterPrefix(String text) =>
      text.startsWith('$characterName: ') || groupNames.any((name) => text.startsWith('$name: '));
  for (var index = 0; index < input.length; index++) {
    final original = input[index];
    final message = jsonDecode(jsonEncode(original.message)) as Map<String, Object?>;
    Object? content = presetTruthy(message['content']) ? message['content'] : '';
    if (content is List<Object?>) {
      content = content
          .map((part) {
            if (part != null && part is! Map<String, Object?>) return '';
            final item = part as Map<String, Object?>;
            if (item['type'] == 'text') return item['text'] == null ? '' : presetString(item['text']);
            if (const ['image_url', 'video_url', 'audio_url'].contains(item['type'])) {
              final random = Random.secure();
              final token = base64Encode(List<int>.generate(32, (_) => random.nextInt(256)));
              media[token] = item;
              return token;
            }
            return '';
          })
          .join('\n\n');
    }
    var text = content;
    final name = message['name'];
    final role = message['role'];
    if (role == 'system' &&
        name == 'example_assistant' &&
        characterName.isNotEmpty &&
        !hasCharacterPrefix(text as String)) {
      text = '$characterName: ${presetString(text)}';
    }
    if (role == 'system' &&
        name == 'example_user' &&
        userName.isNotEmpty &&
        !(text as String).startsWith('$userName: ')) {
      text = '$userName: ${presetString(text)}';
    }
    if (presetTruthy(name) && role != 'system' && !(text as String).startsWith('${presetString(name)}: ')) {
      text = '${presetString(name)}: ${presetString(text)}';
    }
    if (role == 'tool' && !tools) message['role'] = 'user';
    if (single) {
      if (message['role'] == 'assistant' && characterName.isNotEmpty && !hasCharacterPrefix(text as String)) {
        text = '$characterName: ${presetString(text)}';
      }
      if (message['role'] == 'user' && userName.isNotEmpty && !(text as String).startsWith('$userName: ')) {
        text = '$userName: ${presetString(text)}';
      }
      message['role'] = 'user';
    }
    message['content'] = text;
    message.remove('name');
    if (!tools) {
      message.remove('tool_calls');
      message.remove('tool_call_id');
    }
    final segment = _replace(original, message, counter);
    if (merged.isNotEmpty &&
        !(separateLast && index == input.length - 1) &&
        merged.last.message['role'] == message['role'] &&
        presetTruthy(text) &&
        // W11 owner correction: ST 1.19 merges only content here and loses
        // later tool calls. Preserve their message boundary and call metadata.
        !(tools && message['tool_calls'] is List && (message['tool_calls']! as List).isNotEmpty) &&
        message['role'] != 'tool') {
      final previous = merged.removeLast();
      final joined = {
        ...previous.message,
        'content': '${presetString(previous.message['content'])}\n\n${presetString(text)}',
      };
      merged.add(
        PromptSegment(
          id: '${previous.id}+${segment.id}',
          message: joined,
          sources: [...previous.sources, ...segment.sources],
          tokens: counter.countMessage(joined),
          collectionId: previous.collectionId == segment.collectionId ? previous.collectionId : null,
        ),
      );
    } else {
      merged.add(segment);
    }
  }
  PromptSegment placeholder() {
    const message = <String, Object?>{'role': 'user', 'content': "Let's get started."};
    return PromptSegment(
      id: 'empty-prompt',
      message: message,
      sources: const [PromptSource('control', 'empty-prompt')],
      tokens: counter.countMessage(message),
    );
  }

  if (merged.isEmpty) merged.add(placeholder());
  if (media.isNotEmpty) {
    merged = [for (final segment in merged) _restoreMedia(segment, media, counter)];
  }
  if (strict) {
    for (var i = 1; i < merged.length; i++) {
      if (merged[i].message['role'] == 'system') {
        merged[i] = _replace(merged[i], {...merged[i].message, 'role': 'user'}, counter);
      }
    }
    if (placeholders) {
      if (merged.first.message['role'] == 'system' && (merged.length == 1 || merged[1].message['role'] != 'user')) {
        merged.insert(1, placeholder());
      } else if (merged.first.message['role'] != 'system' && merged.first.message['role'] != 'user') {
        merged.insert(0, placeholder());
      }
    }
    return _mergeMessages(
      merged,
      userName: userName,
      characterName: characterName,
      groupNames: groupNames,
      counter: counter,
      strict: false,
      placeholders: placeholders,
      single: false,
      tools: tools,
      separateLast: separateLast,
    );
  }
  return merged;
}

PromptSegment _restoreMedia(
  PromptSegment segment,
  Map<String, Map<String, Object?>> media,
  PromptTokenCounter counter,
) {
  final text = segment.message['content']! as String;
  if (!media.keys.any(text.contains)) return segment;
  final content = <Map<String, Object?>>[];
  final pattern = RegExp(media.keys.map(RegExp.escape).join('|'));
  for (final part in text.split('\n\n')) {
    var at = 0;
    var found = false;
    for (final match in pattern.allMatches(part)) {
      final prefix = part.substring(at, match.start);
      if (prefix.isNotEmpty) {
        if (!found && content.isNotEmpty && content.last['type'] == 'text') {
          content.last['text'] = '${content.last['text']}\n\n$prefix';
        } else {
          content.add({'type': 'text', 'text': prefix});
        }
      }
      content.add(media[match[0]]!);
      at = match.end;
      found = true;
    }
    final suffix = part.substring(at);
    if (!found && content.isNotEmpty && content.last['type'] == 'text') {
      content.last['text'] = '${content.last['text']}\n\n$suffix';
    } else if (!found || suffix.isNotEmpty) {
      content.add({'type': 'text', 'text': suffix});
    }
  }
  return _replace(segment, {...segment.message, 'content': content}, counter);
}

PromptSegment _replace(PromptSegment original, Map<String, Object?> message, PromptTokenCounter counter) =>
    PromptSegment(
      id: original.id,
      message: message,
      sources: original.sources,
      tokens: counter.countMessage(message),
      collectionId: original.collectionId,
    );
