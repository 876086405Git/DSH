// 舞台 › 本局 › 本局用量 (费用可见): what
// the replies on a chat's current line took, as the model reported it,
// added up. Alternatives swiped away are not on the line and not counted.

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tavern_provider.dart';

class TavernSessionUsage {
  const TavernSessionUsage({
    this.replies = 0,
    this.prompt = 0,
    this.cacheHit = 0,
    this.completion = 0,
    this.cost = 0,
    this.unpriced = 0,
  });

  /// Replies that carry reported usage.
  final int replies;
  final int prompt;
  final int cacheHit;
  final int completion;

  /// What the priced replies cost, in US dollars, at DeepSeek's list prices
  /// for the time each was written ([tavernReplyCost]).
  final double cost;

  /// Replies whose model is not on the price list: not in [cost].
  final int unpriced;

  TavernSessionUsage operator +(TavernSessionUsage other) => TavernSessionUsage(
    replies: replies + other.replies,
    prompt: prompt + other.prompt,
    cacheHit: cacheHit + other.cacheHit,
    completion: completion + other.completion,
    cost: cost + other.cost,
    unpriced: unpriced + other.unpriced,
  );

  /// With [m]'s reported usage, when it is a reply that has some.
  TavernSessionUsage plus(TavernMessage m) {
    final usage = m.reportedUsage;
    if (m.role != TavernRole.character || usage == null) return this;
    final price = tavernModelPrice(usage.model);
    return this +
        TavernSessionUsage(
          replies: 1,
          prompt: usage.promptTokens,
          cacheHit: usage.cacheHitTokens,
          completion: usage.completionTokens,
          cost: price == null ? 0 : tavernReplyCost(usage, price, m.at),
          unpriced: price == null ? 1 : 0,
        );
  }
}

/// A DeepSeek model's list prices, US dollars per million tokens at peak
/// hours (off-peak is half): input found in the cache, input not, output.
typedef TavernModelPrice = ({double hit, double miss, double out});

/// As https://api-docs.deepseek.com/quick_start/pricing listed them, read
/// 2026-11-13. Reasoning is billed in the output it is part of.
const tavernDeepSeekFlash = (hit: 0.006, miss: 0.3, out: 1.2);
const tavernDeepSeekPro = (hit: 0.044, miss: 1.32, out: 3.96);

/// [model] as a reply reported it, to its prices; null for one not priced
/// here (an older or another provider's model is not guessed at).
TavernModelPrice? tavernModelPrice(String? model) {
  final name = model?.toLowerCase() ?? '';
  if (!name.startsWith('deepseek')) return null;
  if (name.contains('flash')) return tavernDeepSeekFlash;
  if (name.contains('pro')) return tavernDeepSeekPro;
  return null;
}

/// DeepSeek's peak hours: Monday to Friday, 01:00-04:00 and 06:00-10:00 UTC.
/// China's public holidays are off-peak all day; they are not known here, so
/// a reply on one is priced as on a workday (a little high).
bool tavernDeepSeekPeak(DateTime at) {
  final utc = at.toUtc();
  if (utc.weekday == DateTime.saturday || utc.weekday == DateTime.sunday) return false;
  final hour = utc.hour;
  return (hour >= 1 && hour < 4) || (hour >= 6 && hour < 10);
}

/// What one reply cost in US dollars, at [price] for the time it was written.
double tavernReplyCost(TavernUsage usage, TavernModelPrice price, DateTime at) {
  final miss = (usage.promptTokens - usage.cacheHitTokens).clamp(0, usage.promptTokens);
  final peak = usage.cacheHitTokens * price.hit + miss * price.miss + usage.completionTokens * price.out;
  return (tavernDeepSeekPeak(at) ? peak : peak / 2) / 1e6;
}

/// [usd] at a glance: four decimals under a dollar (it is often a fraction
/// of a cent), two above.
String tavernUsd(double usd) => usd < 1 ? usd.toStringAsFixed(4) : usd.toStringAsFixed(2);

/// [chatId]'s current line, its replies' usage summed: the engine adds it up
/// in one query ([Tavern.pathUsage]), by model and by the UTC weekday and
/// hour, which is all DeepSeek's peak and off-peak prices need.
Future<TavernSessionUsage> tavernSessionUsage(Tavern tavern, String chatId) async {
  var total = const TavernSessionUsage();
  for (final bucket in await tavern.pathUsage(chatId)) {
    final usage = TavernUsage(
      promptTokens: bucket.promptTokens,
      cacheHitTokens: bucket.cacheHitTokens,
      completionTokens: bucket.completionTokens,
      model: bucket.model,
    );
    final price = tavernModelPrice(bucket.model);
    total += TavernSessionUsage(
      replies: bucket.replyCount,
      prompt: usage.promptTokens,
      cacheHit: usage.cacheHitTokens,
      completion: usage.completionTokens,
      // 2024-01-01 was a Monday: day N of that month is weekday N.
      cost: price == null ? 0 : tavernReplyCost(usage, price, DateTime.utc(2024, 1, bucket.utcWeekday, bucket.utcHour)),
      unpriced: price == null ? bucket.replyCount : 0,
    );
  }
  return total;
}

/// A token count at a glance: 8,421 as it is; 12,345 as 1.2万 (or 12.3k).
String tavernTokenCount(int tokens, {required bool zh}) {
  if (tokens < 10000) return '$tokens';
  if (zh) {
    final wan = tokens / 10000;
    return '${wan >= 100 ? wan.round() : wan.toStringAsFixed(1)}万';
  }
  final k = tokens / 1000;
  return k >= 1000 ? '${(k / 1000).toStringAsFixed(1)}M' : '${k >= 100 ? k.round() : k.toStringAsFixed(1)}k';
}

/// One chat and what its current line took.
class TavernChatUsage {
  const TavernChatUsage(this.chat, this.usage);

  final TavernChatSummary chat;
  final TavernSessionUsage usage;

  int get total => usage.prompt + usage.completion;
}

/// 用量统计: every chat's current line added up, the ones that took the most
/// first; chats with nothing reported left out. Read afresh each time.
final tavernAllUsageProvider = FutureProvider.autoDispose<List<TavernChatUsage>>((ref) async {
  final tavern = ref.watch(tavernProvider);
  final chats = await tavern.watchChats().first;
  final all = [for (final chat in chats) TavernChatUsage(chat, await tavernSessionUsage(tavern, chat.id))]
    ..removeWhere((c) => c.usage.replies == 0);
  all.sort((a, b) => b.total.compareTo(a.total));
  return all;
}, retry: (_, _) => null);
