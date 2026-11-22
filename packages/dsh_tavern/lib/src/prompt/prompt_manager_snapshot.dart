// Internal PromptManager view, captured before MessageInjections. This stores
// admitted messages and collection topology, not an alternative prompt run.
import 'preset.dart';
import 'prompt_types.dart';

sealed class PromptManagerItem {
  const PromptManagerItem();
}

final class PromptManagerMessage extends PromptManagerItem {
  PromptManagerMessage(PromptSegment segment, {required this.identifier})
    : segment = PromptSegment(
        id: segment.id,
        message: _freeze(segment.message) as Map<String, Object?>,
        sources: List.unmodifiable([
          for (final source in segment.sources)
            PromptSource(
              source.kind,
              source.id,
              label: source.label,
              details: _freeze(source.details) as Map<String, Object?>,
            ),
        ]),
        tokens: segment.tokens,
        collectionId: segment.collectionId,
      );

  /// ST's logical identifier. A displaced continuation can have no identifier;
  /// a physical database node ID must not silently replace that missing value.
  final String? identifier;
  final PromptSegment segment;

  bool get meaningful => presetTruthy(segment.message['content']) || presetTruthy(segment.message['tool_calls']);

  PromptSegment serialize(PromptTokenCounter counter, {required bool direct, String? collectionId}) {
    final raw = segment.message;
    final message = <String, Object?>{
      'role': raw['role'],
      'content': raw['content'],
      if (presetTruthy(raw['name'])) 'name': raw['name'],
      if (presetTruthy(raw['tool_calls'])) 'tool_calls': raw['tool_calls'],
      if (raw['role'] == 'tool') 'tool_call_id': identifier,
      if (direct ? raw['signature'] != null : presetTruthy(raw['signature'])) 'signature': raw['signature'],
      if (direct ? raw['reasoning'] != null : presetTruthy(raw['reasoning'])) 'reasoning': raw['reasoning'],
    };
    return PromptSegment(
      id: segment.id,
      message: _copy(message) as Map<String, Object?>,
      sources: segment.sources,
      tokens: counter.countMessage(message),
      collectionId: collectionId,
    );
  }
}

final class PromptManagerCollection extends PromptManagerItem {
  PromptManagerCollection(this.identifier, Iterable<PromptManagerMessage> messages)
    : messages = List.unmodifiable(messages);
  final String identifier;
  final List<PromptManagerMessage> messages;
}

final class PromptManagerSnapshot {
  PromptManagerSnapshot(Iterable<PromptManagerItem> items) : items = List.unmodifiable(items);
  final List<PromptManagerItem> items;

  PromptManagerSnapshot mapSegments(PromptSegment Function(PromptSegment) transform) => PromptManagerSnapshot([
    for (final item in items)
      switch (item) {
        PromptManagerMessage() => PromptManagerMessage(transform(item.segment), identifier: item.identifier),
        PromptManagerCollection() => PromptManagerCollection(item.identifier, [
          for (final message in item.messages)
            PromptManagerMessage(transform(message.segment), identifier: message.identifier),
        ]),
      },
  ]);

  /// The fixed ST method mutates its root by flattening, then keeps the first
  /// identifier when joining adjacent eligible systems. No macro/budget replay
  /// or second token-counter invocation is needed for this stored view.
  PromptManagerSnapshot squashSystems() {
    const protected = {'newMainChat', 'newChat', 'groupNudge'};
    bool eligible(PromptManagerMessage item) =>
        item.segment.message['role'] == 'system' &&
        !presetTruthy(item.segment.message['name']) &&
        !protected.contains(item.identifier);
    final output = <PromptManagerMessage>[];
    for (final item in items.expand(
      (item) => switch (item) {
        PromptManagerMessage() => [item],
        PromptManagerCollection() => item.messages,
      },
    )) {
      final raw = item.segment.message;
      if (raw['role'] == 'system' && !presetTruthy(raw['content'])) continue;
      final previous = output.lastOrNull;
      if (previous != null && eligible(previous) && eligible(item)) {
        final before = previous.segment;
        output[output.length - 1] = PromptManagerMessage(
          PromptSegment(
            id: before.id,
            message: {
              ...before.message,
              'content': '${presetString(before.message['content'])}\n${presetString(raw['content'])}',
            },
            sources: [...before.sources, ...item.segment.sources],
            // Stored admission cost only. Serialization counts the resulting
            // actual message when it is read by the later SPreset hook.
            tokens: before.tokens + item.segment.tokens,
          ),
          identifier: previous.identifier,
        );
      } else {
        output.add(item);
      }
    }
    return PromptManagerSnapshot(output);
  }
}

Object? _freeze(Object? value) => switch (value) {
  Map<String, Object?>() => Map<String, Object?>.unmodifiable({
    for (final entry in value.entries) entry.key: _freeze(entry.value),
  }),
  List<Object?>() => List<Object?>.unmodifiable(value.map(_freeze)),
  _ => value,
};

Object? _copy(Object? value) => switch (value) {
  Map<String, Object?>() => {for (final entry in value.entries) entry.key: _copy(entry.value)},
  List<Object?>() => value.map(_copy).toList(),
  _ => value,
};
