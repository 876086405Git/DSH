// What a turn that asked the model more than once (dice, memories between
// requests) was reported to use, from the engine's
// TavernToolTurnSnapshot.usageSummary (STAGE1-APP-INTEGRATION §7): per field,
// the sum of what was reported and which requests it is short of. A sum short
// of any request is never a total.

/// One field (prompt_tokens, completion_tokens, cache_hit_tokens) across the
/// turn's requests.
class TavernUsageField {
  const TavernUsageField({
    required this.known,
    required this.complete,
    this.missing = const [],
    this.invalid = const [],
    this.unknown = const [],
  });

  /// The exact decimal sum of the values reported (also past 64 bits).
  final String known;

  /// Every request reported it, and the sum held: [known] is the total.
  final bool complete;

  /// Requests (1…) that said nothing of it, said it wrong, or are not known.
  final List<int> missing, invalid, unknown;

  static TavernUsageField? fromJson(Object? json) {
    if (json is! Map) return null;
    final known = json['exactKnownSubtotal'];
    if (known is! String || !RegExp(r'^\d+$').hasMatch(known)) return null;
    List<int> indexes(String key) => [
      for (final i in json[key] is List ? json[key] as List : const <Object?>[])
        if (i is int) i,
    ];
    return TavernUsageField(
      known: known,
      complete: json['complete'] == true && json['overflow'] != true,
      missing: indexes('missingRequestIndexes'),
      invalid: indexes('invalidRequestIndexes'),
      unknown: indexes('unknownRequestIndexes'),
    );
  }
}

class TavernUsageSummary {
  const TavernUsageSummary({
    required this.requests,
    required this.prompt,
    required this.completion,
    required this.cacheHit,
  });

  final int requests;
  final TavernUsageField prompt, completion, cacheHit;

  bool get complete => prompt.complete && completion.complete && cacheHit.complete;

  /// The engine's summary; null for a shape not known here, or a turn with
  /// no request yet.
  static TavernUsageSummary? fromJson(Map<String, Object?> json) {
    final count = json['requestCount'];
    if (json['version'] != 1 || count is! int || count < 1) return null;
    final fields = json['fields'];
    if (fields is! Map) return null;
    final prompt = TavernUsageField.fromJson(fields['prompt_tokens']);
    final completion = TavernUsageField.fromJson(fields['completion_tokens']);
    final cacheHit = TavernUsageField.fromJson(fields['cache_hit_tokens']);
    if (prompt == null || completion == null || cacheHit == null) return null;
    return TavernUsageSummary(requests: count, prompt: prompt, completion: completion, cacheHit: cacheHit);
  }
}
