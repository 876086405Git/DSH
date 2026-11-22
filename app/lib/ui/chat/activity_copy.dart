// What the activity pill says while a turn runs: copy pools, slot-based phrase
// rotation (adjacent windows never repeat), easter eggs keyed on time and on
// the last tool, and the model's `⏵` narration.

import '../../l10n/l10n.dart';
import 'run_info.dart';

// -----------------------------------------------------------------------------
// 轮换:每个窗口一句,同一窗口永远同一句

/// 一句文案停留多久。
const phraseWindow = Duration(seconds: 4);

/// 一轮里第一次思考有 1/150 的机会整段换成稀有彩蛋。
const rareOdds = 150;

/// 一次性提醒(长时间运行)显示多久。
const reminderWindow = Duration(seconds: 8);

int _imul(int a, int b) {
  a &= 0xFFFFFFFF;
  b &= 0xFFFFFFFF;
  final low = (a & 0xFFFF) * b;
  final high = ((a >>> 16) * b) & 0xFFFF;
  return (low + (high << 16)) & 0xFFFFFFFF;
}

/// 种子和窗口序号的确定性 32 位混合(雪崩后取低 32 位)。
///
/// 要的是可重复,不是随机:同样的输入永远同样的输出,界面每秒重画多少次,
/// 这一窗口的那句话都不会动。
int mixSlot(int seed, int slot) {
  var h = (_imul(seed, 0x9E3779B1) ^ _imul(slot, 0x85EBCA6B)) & 0xFFFFFFFF;
  h = _imul(h ^ (h >>> 15), 0x2545F491);
  h = _imul(h ^ (h >>> 13), 0x9E3779B1);
  return (h ^ (h >>> 16)) & 0xFFFFFFFF;
}

/// 第 [slot] 个窗口的那句,池子不随窗口变。见 [_rotateAt]。
String pickAt(List<String> pool, int seed, int slot) => _rotateAt(seed, slot, (_) => pool);

/// 第 [slot] 个窗口的那句;[poolAt] 给出每个窗口用的池子(深夜、想得久了
/// 会换池)。
///
/// 相邻两个窗口*实际显示*的话永远不同(按文字比,两个键译成同一句也算撞),
/// 而且不用从第 0 个窗口回放:偶数窗口在自己的池里按哈希直接取;奇数窗口
/// 按哈希起步,跳过前后两个偶数窗口实际显示的那两句。前后窗口换了池子也一样
/// 成立,因为邻居按它自己的池子算。池里只有两句不同的话时轮流显示;只有一句
/// 就只能重复。
String _rotateAt(int seed, int slot, List<String> Function(int slot) poolAt) {
  List<String> lines(int k) {
    final pool = poolAt(k).toSet().toList();
    assert(pool.isNotEmpty);
    return pool;
  }

  String plain(int k) {
    final pool = lines(k);
    if (pool.length <= 2) return pool[(mixSlot(seed, 0) + k) % pool.length];
    return pool[mixSlot(seed, k) % pool.length];
  }

  final pool = lines(slot);
  if (slot.isEven || pool.length <= 2) return plain(slot);
  final before = plain(slot - 1);
  final after = plain(slot + 1);
  final start = mixSlot(seed, slot) % pool.length;
  for (var i = 0; i < pool.length; i++) {
    final line = pool[(start + i) % pool.length];
    if (line != before && line != after) return line;
  }
  return pool[start]; // unreachable: three different lines leave one free
}

// -----------------------------------------------------------------------------
// 文案池

/// 模型在想(推理在流)。
List<String> get thinkingPhrases => [
  appL10n.activityThinkingUntangle,
  appL10n.activityThinkingWorkThrough,
  appL10n.activityThinkingGears,
  appL10n.activityThinkingSecond,
  appL10n.activityThinkingSmoking, //
  appL10n.activityThinkingOnIt,
  appL10n.activityThinkingNoRush,
  appL10n.activityThinkingPonder,
  appL10n.activityThinkingLogic,
  appL10n.activityThinkingBrain,
  appL10n.activityThinkingSort,
  appL10n.activityThinkingMemory,
  appL10n.activityThinkingStorm,
  appL10n.activityThinkingSavor,
  appL10n.activityThinkingMoment,
  appL10n.activityThinkingHeadScratch,
  appL10n.activityThinkingPlayOut,
  appL10n.activityThinkingLoading,
  appL10n.activityThinkingMulling,
  appL10n.activityThinkingBreakDown,
  appL10n.activityThinkingTrain,
  appL10n.activityThinkingSomething,
  appL10n.activityThinkingJog,
  appL10n.activityThinkingPicture,
  appL10n.activityThinkingBubbles,
  appL10n.activityThinkingWaves,
  appL10n.activityThinkingCoffee,
  appL10n.activityThinkingDraft,
  appL10n.activityThinkingComing,
  appL10n.activityThinkingBubbling,
  appL10n.activityThinkingTackle,
  appL10n.activityThinkingSpark,
  appL10n.activityThinkingLogicFirst,
  appL10n.activityThinkingLocate,
  appL10n.activityThinkingInvestigate,
  'loading 99%',
  appL10n.activityThinkingGif,
  appL10n.activityThinkingLook,
  appL10n.activityThinkingInteresting,
  appL10n.activityThinkingHands,
];

/// 想得久了:按这一段思考已经多久换池子(在窗口开始时判断)。
List<(Duration, List<String>)> get thinkingTiers => <(Duration, List<String>)>[
  (
    const Duration(minutes: 5),
    [
      appL10n.activityThinkingFiveMinutes,
      appL10n.activityThinkingSerious,
      appL10n.activityThinkingTricky,
      appL10n.activityThinkingAscend,
      appL10n.activityThinkingAlmostPromise, //
      appL10n.activityThinkingLongWay,
      appL10n.activityThinkingWrapping,
      appL10n.activityThinkingSong,
      appL10n.activityThinkingBigMove,
      appL10n.activityThinkingSimple,
    ],
  ),
  (
    const Duration(minutes: 1),
    [
      appL10n.activityThinkingOneMinute,
      appL10n.activityThinkingChallenge,
      appL10n.activityThinkingDig,
      appL10n.activityThinkingNotSimple,
      appL10n.activityThinkingDeep, //
      appL10n.activityThinkingBurning,
      appL10n.activityThinkingNearlyClear,
      appL10n.activityThinkingTwisty,
      appL10n.activityThinkingWorkout,
      appL10n.activityThinkingStay,
    ],
  ),
  (
    const Duration(seconds: 30),
    [
      appL10n.activityThinkingCloser,
      appL10n.activityThinkingThirtySeconds,
      appL10n.activityThinkingSoon,
      appL10n.activityThinkingAnotherPass, //
      appL10n.activityThinkingTrack,
      appL10n.activityThinkingLead,
      appL10n.activityThinkingCircles,
      appL10n.activityThinkingAnyMoment,
      appL10n.activityThinkingStillLocate,
    ],
  ),
];

/// 请求发出去了,第一个字还没来。
List<String> get waitingPhrases => [
  appL10n.activityWaitingCall,
  appL10n.activityWaitingOnWay,
  appL10n.activityWaitingSpeak,
  appL10n.activityWaitingWords,
  appL10n.activityWaitingAwake, //
  appL10n.activityWaitingStretch,
  appL10n.activityWaitingYawn,
  appL10n.activityWaitingComing,
  appL10n.activityWaitingText,
  appL10n.activityWaitingQueue,
  appL10n.activityWaitingBrew,
  appL10n.activityWaitingWater,
  appL10n.activityWaitingWarmup,
  appL10n.activityWaitingMeditate,
  appL10n.activityWaitingBlink,
  appL10n.activityWaitingMoment,
];

/// 回复正文在流。
List<String> get writingPhrases => [
  appL10n.activityWritingWords,
  appL10n.activityWritingTyping,
  appL10n.activityWritingInspired,
  appL10n.activityWritingOnIt,
  appL10n.activityWritingCareful, //
  appL10n.activityWritingFlow,
  appL10n.activityWritingPlain,
  appL10n.activityWritingIdeas,
  appL10n.activityWritingKeys,
  appL10n.activityWritingAlmost,
  appL10n.activityWritingTell,
  appL10n.activityWritingFast,
  appL10n.activityWritingBreeze,
  appL10n.activityWritingFormat,
];

/// 00:00–06:00 混进思考池。
List<String> get nightPhrases => [
  appL10n.activityNightAscend,
  appL10n.activityNightHello,
  appL10n.activityNightOwl,
  appL10n.activityNightMoon,
  appL10n.activityNightSlow, //
  appL10n.activityNightChampion,
  appL10n.activityNightSleepy,
  appL10n.activityNightMidnight,
  appL10n.activityNightOpen,
  appL10n.activityNightStars,
  appL10n.activityNightDawn,
];

/// 周六日,一轮里第一次思考的第一句。
List<String> get weekendPhrases => [
  appL10n.activityWeekendChill,
  appL10n.activityWeekendHere,
  appL10n.activityWeekendCompany,
  appL10n.activityWeekendOnline,
  appL10n.activityWeekendSneak, //
  appL10n.activityWeekendWorking,
  appL10n.activityWeekendMode,
  appL10n.activityWeekendBugs,
  appL10n.activityWeekendSkin,
];

/// 节日(按 `MM-DD`),同样是一轮第一次思考的第一句。
Map<String, List<String>> get holidayPhrases => <String, List<String>>{
  '01-01': [
    appL10n.activityNewYearCheers,
    appL10n.activityNewYearDay,
    appL10n.activityNewYearBugs,
    appL10n.activityNewYearFirstLine,
    appL10n.activityNewYearWork,
  ],
  '02-14': [
    appL10n.activityValentineCode,
    appL10n.activityValentineLove,
    appL10n.activityValentineDate,
    appL10n.activityValentineKeyboard,
  ],
  '03-14': [appL10n.activityPiDay, '3.1415926…', appL10n.activityPiCircle],
  '04-01': [
    appL10n.activityAprilFools,
    appL10n.activityAprilBug,
    appL10n.activityAprilErrors,
    appL10n.activityAprilKidding,
  ],
  '05-01': [appL10n.activityLaborWorking, appL10n.activityLaborPride, appL10n.activityLaborSpirit],
  '06-01': [appL10n.activityChildrenDay, appL10n.activityChildrenHeart, appL10n.activityChildrenCode],
  '10-24': [
    appL10n.activityProgrammerCheers,
    appL10n.activityProgrammerDay,
    appL10n.activityProgrammer1024,
    appL10n.activityProgrammerCode,
  ],
  '10-31': [appL10n.activityHalloween, appL10n.activityHalloweenTreat, appL10n.activityHalloweenCode],
  '12-24': [appL10n.activityChristmasEve, appL10n.activityChristmasEveThinking, appL10n.activityChristmasEveGift],
  '12-25': [
    appL10n.activityChristmas,
    appL10n.activityChristmasCompany,
    appL10n.activityChristmasEgg,
    appL10n.activityChristmasReindeer,
  ],
  '12-31': [
    appL10n.activityYearEndEve,
    appL10n.activityYearEndLast,
    appL10n.activityYearEndReady,
    appL10n.activityYearEndSeeYou,
  ],
};

/// 春节七天(从正月初一起)。每年补一行;表过期时测试会红。
const lunarNewYearDays = <String>[
  '2025-01-29', '2026-02-17', '2027-02-06', '2028-01-26', '2029-02-13', //
  '2030-02-03', '2031-01-23', '2032-02-11', '2033-01-31', '2034-02-19',
  '2035-02-08',
];

List<String> get _zodiac => [
  appL10n.activityZodiacRat,
  appL10n.activityZodiacOx,
  appL10n.activityZodiacTiger,
  appL10n.activityZodiacRabbit,
  appL10n.activityZodiacDragon,
  appL10n.activityZodiacSnake,
  appL10n.activityZodiacHorse,
  appL10n.activityZodiacGoat,
  appL10n.activityZodiacMonkey,
  appL10n.activityZodiacRooster,
  appL10n.activityZodiacDog,
  appL10n.activityZodiacPig,
];

List<String> lunarNewYearPhrases(int year) => [
  appL10n.activityLunarCheers,
  appL10n.activityLunarCode,
  appL10n.activityLunarEnvelope,
  appL10n.activityLunarSpring,
  appL10n.activityLunarGreeting, //
  appL10n.activityLunarCodeGreeting,
  appL10n.activityLunarZodiac(_zodiac[(year - 4) % 12]),
];

/// 稀有彩蛋(一轮一次,看种子)。
List<String> get rarePhrases => [
  appL10n.activityRareSsr,
  appL10n.activityRareUr,
  appL10n.activityRareLegend,
  appL10n.activityRareOrange,
  appL10n.activityRareEgg,
  appL10n.activityRareChosen, //
  appL10n.activityRareHidden,
  appL10n.activityRareChat,
  appL10n.activityRareMax,
  appL10n.activityRareLucky,
  appL10n.activityRareCritical,
  appL10n.activityRareNextLevel,
];

/// 上一个工具失败之后。
List<String> get failPhrases => [
  appL10n.activityFailCrash,
  appL10n.activityFailOops,
  appL10n.activityFailRun,
  appL10n.activityFailTrip,
  appL10n.activityFailWrong,
  appL10n.activityFailHiccup,
  appL10n.activityFailBroken, //
  appL10n.activityFailLocal,
  appL10n.activityFailYesterday,
  appL10n.activityFailTough,
  appL10n.activityFailCrack,
  appL10n.activityFailPressure,
  appL10n.activityFailCareless,
  appL10n.activityFailSlip,
  appL10n.activityFailTryAgain,
  appL10n.activityFailChance,
];

/// 测试命令跑过 / 没跑过之后。
List<String> get testPassPhrases => [
  appL10n.activityTestGreen,
  appL10n.activityTestAllGreen,
  appL10n.activityTestFirstTry,
  appL10n.activityTestNoErrors,
  appL10n.activityTestPassed,
  appL10n.activityTestSolid,
];
List<String> get testFailPhrases => [
  appL10n.activityTestRed,
  appL10n.activityTestInvestigate,
  appL10n.activityTestStubborn,
  appL10n.activityTestFix,
];

/// git 提交 / 推送之后。
List<String> get gitCommitPhrases => [
  appL10n.activityGitCommitSave,
  appL10n.activityGitSaved,
  appL10n.activityGitCommitRelief,
];
List<String> get gitPushPhrases => [appL10n.activityGitPushed, appL10n.activityGitPushDone, appL10n.activityGitCodeOut];

/// 装完依赖之后。
List<String> get installPhrases => [
  appL10n.activityInstallDone,
  appL10n.activityInstallInternet,
  appL10n.activityInstallPackages,
];

/// 一轮里第 N 个工具调用完。
Map<int, String> get toolMilestones => <int, String>{
  5: appL10n.activityMilestoneFive,
  10: appL10n.activityMilestoneTen,
  20: appL10n.activityMilestoneTwenty,
  50: appL10n.activityMilestoneFifty,
};

/// 服务方让重试(限流 / 临时错误)。
List<String> get retryPhrases => [appL10n.activityRetryWait, appL10n.activityRetryBackoff, appL10n.activityRetryKnock];
List<String> get rateLimitPhrases => [appL10n.activityRateLimited, appL10n.activityRate429, appL10n.activityRateQueue];

/// 正在压缩上下文。
List<String> get compactionPhrases => [
  appL10n.activityCompactContext,
  appL10n.activityCompactBag,
  appL10n.activityCompactSpace,
  appL10n.activityCompactMemory,
  appL10n.activityCompactChats,
];

// -----------------------------------------------------------------------------
// 日期与工具

bool isNight(DateTime local) => local.hour < 6;

bool isWeekend(DateTime local) => local.weekday == DateTime.saturday || local.weekday == DateTime.sunday;

String _two(int n) => n.toString().padLeft(2, '0');

/// 今天的节日文案池;春节优先,没有为 null。
List<String>? holidayPool(DateTime local) {
  final day = DateTime(local.year, local.month, local.day);
  for (final first in lunarNewYearDays) {
    final start = DateTime.parse(first);
    final offset = day.difference(start).inDays;
    if (offset >= 0 && offset < 7) return lunarNewYearPhrases(start.year);
  }
  return holidayPhrases['${_two(local.month)}-${_two(local.day)}'];
}

final _testCommand = RegExp(
  r'\b(flutter test|dart test|npm (run )?test|pnpm (run )?test|yarn test|'
  r'pytest|go test|cargo test|jest|vitest|gradlew? test|mvn test)\b',
);
final _gitPush = RegExp(r'\bgit\s+push\b');
final _gitCommit = RegExp(r'\bgit\s+commit\b');
final _install = RegExp(
  r'\b(npm (i|install|ci)|pnpm (i|install|add)|yarn (install|add)|'
  r'pip3? install|flutter pub get|dart pub get|cargo fetch|apt(-get)? install)\b',
);

/// 刚结束的那个工具值得说一句吗;不值得为 null。
List<String>? afterToolPool(AfterTool tool) {
  final command = tool.command;
  final isTest = command != null && _testCommand.hasMatch(command);
  if (tool.failed) return isTest ? testFailPhrases : failPhrases;
  if (command == null) return null;
  if (isTest) return testPassPhrases;
  if (_gitPush.hasMatch(command)) return gitPushPhrases;
  if (_gitCommit.hasMatch(command)) return gitCommitPhrases;
  if (_install.hasMatch(command)) return installPhrases;
  return null;
}

/// 一轮跑了很久时的提醒:10 分钟、半小时、之后每整小时,各显示
/// [reminderWindow];不在窗口里为 null。
String? longTurnReminder(Duration elapsed) {
  String? within(Duration mark, String text) {
    final past = elapsed - mark;
    return !past.isNegative && past < reminderWindow ? text : null;
  }

  final hours = elapsed.inHours;
  if (hours >= 1) {
    return within(Duration(hours: hours), appL10n.activityReminderHours(hours));
  }
  return within(const Duration(minutes: 30), appL10n.activityReminderWater) ??
      within(const Duration(minutes: 10), appL10n.activityReminderTenMinutes);
}

// -----------------------------------------------------------------------------
// 模型自述(`⏵` 行)

const _narrationMaxColumns = 80;

bool _wide(int rune) =>
    (rune >= 0x1100 && rune <= 0x115F) ||
    (rune >= 0x2E80 && rune <= 0xA4CF) ||
    (rune >= 0xAC00 && rune <= 0xD7A3) ||
    (rune >= 0xF900 && rune <= 0xFAFF) ||
    (rune >= 0xFE30 && rune <= 0xFE4F) ||
    (rune >= 0xFF00 && rune <= 0xFF60) ||
    (rune >= 0xFFE0 && rune <= 0xFFE6) ||
    (rune >= 0x1F000 && rune <= 0x1FAFF) ||
    (rune >= 0x20000 && rune <= 0x3FFFD);

/// 模型写在正文里的最新一行 `⏵ 在做什么`;没有为 null。
///
/// `⏵` 必须在行首(句中的 `⏵` 是模型在*提*这个格式,不是在用它);只取到
/// 第一个句末标点,按显示宽度截到 80 列(约 40 个汉字),去掉控制字符。
String? extractNarration(String text) {
  final lastLine = text.lastIndexOf('\n⏵');
  if (lastLine < 0 && !text.startsWith('⏵')) return null;
  final match = RegExp(r'(?:^|\n)⏵[ \t]*([^\n⏵]*)').matchAsPrefix(text, lastLine < 0 ? 0 : lastLine);
  if (match == null) return null;
  var line = match.group(1)!.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
  if (line.isEmpty) return null;
  // l10n:keep narration punctuation parser
  final end = RegExp(r'[。．!?！？;；]|\.(?=\s|$|[A-Z][a-z])').firstMatch(line);
  if (end != null) line = line.substring(0, end.end);

  var width = 0;
  var cut = line.length;
  var offset = 0;
  for (final rune in line.runes) {
    final w = _wide(rune) ? 2 : 1;
    if (width + w > _narrationMaxColumns) {
      cut = offset;
      break;
    }
    width += w;
    offset += rune > 0xFFFF ? 2 : 1;
  }
  if (cut < line.length) {
    final head = line.substring(0, cut);
    final soft = [
      ' ',
      '，', // l10n:keep narration punctuation boundary
      '、', // l10n:keep narration punctuation boundary
      ',',
      ';',
      '；', // l10n:keep narration punctuation boundary
    ].map(head.lastIndexOf).fold(-1, (a, b) => a > b ? a : b);
    line = soft > 0 ? head.substring(0, soft) : head;
  }
  // l10n:keep narration punctuation parser
  line = line.replaceFirst(RegExp(r'[。．.!！,，、;；]+$'), '').trim();
  return line.isEmpty ? null : line;
}

// -----------------------------------------------------------------------------
// 这一刻胶囊上那句话

enum FlavorSource {
  /// 模型自述(`⏵`)。
  narration,

  /// 彩蛋:节日、周末、稀有、工具情境、长时间提醒。
  egg,

  /// 普通轮换文案。
  phrase,
}

/// 活动条标题后面那句话。
typedef ActivityFlavor = ({String text, FlavorSource source});

/// [now] 是设备本地时间(节日、周末、深夜按它算,而且按每个窗口开始那一刻
/// 算:一句话不会在自己的窗口里变);经过的时间按 Host 时钟
/// (`now - activity.skew`)。只有模型阶段、重试和压缩有这句话;工具、
/// 等你确认、等你回答各有自己的目标,不再加料。
///
/// 轮换的话和相邻窗口实际显示的那句不重复([_rotateAt]);同样的输入永远
/// 同样的输出。去重不看时区(种子、窗口都按时间戳和经过的时间算);节日、
/// 周末、深夜照旧按本地时间。
ActivityFlavor? activityFlavor(RunActivity a, DateTime now) {
  final hostNow = now.subtract(a.skew);
  final phaseStart = a.since ?? a.turnStart;
  final elapsed = phaseStart == null ? Duration.zero : _nonNegative(hostNow.difference(phaseStart));
  final slot = elapsed.inMilliseconds ~/ phraseWindow.inMilliseconds;
  final seed = (phaseStart?.millisecondsSinceEpoch ?? 0) ^ (a.turnStart?.millisecondsSinceEpoch ?? 0);

  /// Device-local time when window [k] began.
  DateTime windowStart(int k) => now.subtract(elapsed - phraseWindow * k);

  ActivityFlavor phrase(List<String> pool) => (text: pickAt(pool, seed, slot), source: FlavorSource.phrase);

  switch (a.kind) {
    case ActivityKind.stopping || ActivityKind.tool || ActivityKind.approval || ActivityKind.question:
      return null;
    case ActivityKind.compaction:
      return phrase(compactionPhrases);
    case ActivityKind.retry:
      return phrase(a.rateLimited ? rateLimitPhrases : retryPhrases);
    case ActivityKind.waiting || ActivityKind.thinking || ActivityKind.writing:
      break;
  }

  final narration = a.narration;
  if (narration != null) {
    return (text: narration, source: FlavorSource.narration);
  }

  // What window k draws from. The first window may open with an egg; a rare
  // turn rotates through the rare lines; otherwise the phase's own copy, and
  // for thinking the longer-thinking tiers, both judged at the window's start
  // so crossing 30 s or 06:00 halfway through a window doesn't swap the line
  // under the reader. The neighbours' pools are what [_rotateAt] compares with.
  (List<String>, FlavorSource) poolAt(int k) {
    if (k == 0) {
      final after = a.after;
      final afterPool = after == null ? null : afterToolPool(after);
      if (afterPool != null) return (afterPool, FlavorSource.egg);
      final milestone = toolMilestones[a.toolsDone];
      if (after != null && milestone != null) return ([milestone], FlavorSource.egg);
      if (a.firstStep) {
        final local = windowStart(0);
        final holiday = holidayPool(local);
        if (holiday != null) return (holiday, FlavorSource.egg);
        if (rareTurn(a.turnStart)) return (rarePhrases, FlavorSource.egg);
        if (isWeekend(local)) return (weekendPhrases, FlavorSource.egg);
      }
    }
    if (a.firstStep && rareTurn(a.turnStart)) return (rarePhrases, FlavorSource.egg);
    switch (a.kind) {
      case ActivityKind.waiting:
        return (waitingPhrases, FlavorSource.phrase);
      case ActivityKind.writing:
        return (writingPhrases, FlavorSource.phrase);
      default:
        for (final (at, pool) in thinkingTiers) {
          if (phraseWindow * k >= at) return (pool, FlavorSource.phrase);
        }
        final night = isNight(windowStart(k));
        return (night ? [...thinkingPhrases, ...nightPhrases] : thinkingPhrases, FlavorSource.phrase);
    }
  }

  final (_, source) = poolAt(slot);
  // A first-window egg outranks the long-turn reminder; the reminder outranks
  // the rest.
  final turnStart = a.turnStart;
  if (turnStart != null && !(slot == 0 && source == FlavorSource.egg)) {
    final reminder = longTurnReminder(_nonNegative(hostNow.difference(turnStart)));
    if (reminder != null) return (text: reminder, source: FlavorSource.egg);
  }
  return (text: _rotateAt(seed, slot, (k) => poolAt(k).$1), source: source);
}

Duration _nonNegative(Duration d) => d.isNegative ? Duration.zero : d;

/// 这一轮是不是抽中了稀有彩蛋(看种子,不掷骰子:读多少次都一样)。
bool rareTurn(DateTime? turnStart) =>
    turnStart != null && mixSlot(turnStart.millisecondsSinceEpoch, 0x5EED) % rareOdds == 0;
