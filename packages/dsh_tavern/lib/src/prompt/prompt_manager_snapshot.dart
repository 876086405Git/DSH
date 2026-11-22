// Internal PromptManager view, captured before MessageInjections. This stores
// admitted messages and collection topology, not an alternative prompt run.
import 'preset.dart';
import 'prompt_types.dart';

sealed class PromptManagerItem {
  const PromptManagerItem();
}

final class PromptManagerMessage extends PromptManagerItem {
  PromptManagerMessage(
    PromptSegment segment, {
    required this.identifier,
    this.collectionIdentifier,
    bool preserveCurrentWire = false,
  }) : _preserveCurrentWire = preserveCurrentWire,
       segment = PromptSegment(
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

  PromptManagerMessage._(this.segment, this.identifier, this.collectionIdentifier, this._preserveCurrentWire);

  /// ST's logical identifier. A displaced continuation can have no identifier;
  /// a physical database node ID must not silently replace that missing value.
  final String? identifier;
  final String? collectionIdentifier;
  final PromptSegment segment;
  final bool _preserveCurrentWire;

  bool get meaningful =>
      segment.message['role'] == 'tool' ||
      presetTruthy(segment.message['content']) ||
      presetTruthy(segment.message['tool_calls']) ||
      _preserveCurrentWire &&
          (presetTruthy(segment.message['reasoning']) ||
              presetTruthy(segment.message['reasoning_content']) ||
              presetTruthy(segment.message['signature']));

  PromptManagerMessage _inCollection(String identifier) =>
      PromptManagerMessage._(segment, this.identifier, identifier, _preserveCurrentWire);

  PromptSegment serialize(PromptTokenCounter counter, {required bool direct, String? collectionId}) {
    final raw = segment.message;
    // Current wire rows have already passed their provider/MI conversion.
    // Reusing admission topology must not rebuild them through ST's older
    // Message field whitelist (for example, dropping reasoning_content).
    final message = _preserveCurrentWire
        ? _copy(raw) as Map<String, Object?>
        : <String, Object?>{
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
  PromptManagerSnapshot(Iterable<PromptManagerItem> items) : this._(items, null);
  PromptManagerSnapshot._(Iterable<PromptManagerItem> items, this._flattenedOrigins) : items = List.unmodifiable(items);
  final List<PromptManagerItem> items;
  // Keep every original member when system squash retains only the first ID.
  // Later MessageInjections can turn a merged-away system into several rows.
  final Map<String, ({String? identifier, String? collection, bool direct})>? _flattenedOrigins;

  PromptManagerSnapshot mapSegments(PromptSegment Function(PromptSegment) transform) => PromptManagerSnapshot._([
    for (final item in items)
      switch (item) {
        PromptManagerMessage() => PromptManagerMessage(
          transform(item.segment),
          identifier: item.identifier,
          collectionIdentifier: item.collectionIdentifier,
          preserveCurrentWire: item._preserveCurrentWire,
        ),
        PromptManagerCollection() => PromptManagerCollection(item.identifier, [
          for (final message in item.messages)
            PromptManagerMessage(
              transform(message.segment),
              identifier: message.identifier,
              collectionIdentifier: message.collectionIdentifier,
              preserveCurrentWire: message._preserveCurrentWire,
            ),
        ]),
      },
  ], _flattenedOrigins);

  Map<String, ({String? identifier, String? collection, bool direct})> _origins() => {
    for (final item in items)
      if (item is PromptManagerCollection)
        for (final message in item.messages)
          message.segment.id: (identifier: message.identifier, collection: item.identifier, direct: false)
      else if (item is PromptManagerMessage)
        item.segment.id: (identifier: item.identifier, collection: item.collectionIdentifier, direct: true),
  };

  /// Reuse admission topology, not the older message contents. Current rows
  /// drive order and multiplicity, including one-to-many injections and media.
  PromptManagerSnapshot withCurrentMessages(List<PromptSegment> current) {
    final origins = _flattenedOrigins ?? _origins();
    final output = <PromptManagerItem>[];
    var collection = <PromptManagerMessage>[];
    String? collectionId;
    void flush() {
      if (collectionId == null) return;
      output.add(PromptManagerCollection(collectionId!, collection));
      collection = [];
      collectionId = null;
    }

    for (final segment in current) {
      final origin = origins[segment.id];
      final parent = origin?.collection ?? segment.collectionId;
      final direct = _flattenedOrigins != null || (origin?.direct ?? parent == null);
      final identifier = segment.message['role'] == 'tool'
          ? segment.message['tool_call_id'] as String?
          : origin == null
          ? segment.id
          : origin.identifier;
      final message = PromptManagerMessage(
        segment,
        identifier: identifier,
        collectionIdentifier: parent,
        preserveCurrentWire: true,
      );
      if (direct) {
        flush();
        output.add(message);
      } else {
        if (collectionId != parent) flush();
        collectionId = parent;
        collection.add(message);
      }
    }
    flush();
    return PromptManagerSnapshot._(output, _flattenedOrigins);
  }

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
        PromptManagerCollection() => item.messages.map((message) => message._inCollection(item.identifier)),
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
          collectionIdentifier: previous.collectionIdentifier == item.collectionIdentifier
              ? previous.collectionIdentifier
              : null,
        );
      } else {
        output.add(item);
      }
    }
    return PromptManagerSnapshot._(output, _flattenedOrigins ?? Map.unmodifiable(_origins()));
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
