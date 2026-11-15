// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class L10nEn extends L10n {
  L10nEn([String locale = 'en']) : super(locale);

  @override
  String get a11yRestoreTitle => 'Restore accessibility automatically';

  @override
  String get searchKwA11yRestore =>
      'accessibility,restore,reconnect,automatic recovery,permission,ADB,Shizuku,Sui,root';

  @override
  String get a11yRestoreNeedsGrant => 'Authorization required';

  @override
  String get a11yRestoreNotice =>
      'Once authorized, accessibility will be turned back on if disabled in system settings. To stop phone control, turn it off in DSH Go.';

  @override
  String get a11yRestoreForceStop => 'After a force stop, reopen DSH Go to restore the service.';

  @override
  String get a11yRestoreGrant => 'Authorize and enable';

  @override
  String get a11yRestoreGrantShizuku => 'Grant with Shizuku';

  @override
  String get a11yRestoreGrantShizukuPermission => 'Authorize Shizuku, then grant';

  @override
  String get a11yRestoreGrantAdb => 'Grant with Direct ADB';

  @override
  String get a11yRestoreRootNote => 'Uses the authorized root connection to grant only this permission.';

  @override
  String get a11yRestoreSetup => 'Set up Shizuku or wireless debugging';

  @override
  String get a11yRestoreWaiting => 'Allow the request in Shizuku';

  @override
  String get a11yRestoreWaitingSui => 'Allow the request in Sui';

  @override
  String get a11yRestoreComputer => 'Or connect to a computer and run once:';

  @override
  String get a11yRestoreCopy => 'Copy command';

  @override
  String get a11yRestoreCopied => 'Command copied';

  @override
  String get accessPickTitle => 'What should DSH Go help with?';

  @override
  String get accessPickMessage => 'Pick any, then turn each one on';

  @override
  String get accessPickConfirm => 'Turn on selected';

  @override
  String get accessSkip => 'Skip';

  @override
  String get accessFeatureFiles => 'Read and write phone files';

  @override
  String get accessFeatureFilesNeeds => 'Needs file access';

  @override
  String get accessFeaturePet => 'Pet over other apps';

  @override
  String get accessFeaturePetNeeds => 'Needs display over other apps';

  @override
  String get accessFeaturePhone => 'Phone control';

  @override
  String get accessFeaturePhoneNeeds => 'Needs accessibility and notifications';

  @override
  String get accessFeatureBackground => 'Keep running in background';

  @override
  String get accessFeatureBackgroundNeeds => 'Tells you when tasks finish; needs notifications and background access';

  @override
  String get accessFeatureVoice => 'Voice input';

  @override
  String get accessFeatureVoiceNeeds => 'Needs the microphone';

  @override
  String accessVoiceModel(int size) {
    return 'Works offline; downloads a voice model of about $size MB';
  }

  @override
  String get accessVoiceMetered => 'You\'re on mobile data; the download will use it';

  @override
  String get accessFilesRiskBody => 'AI can read and change your photos, downloads and documents.';

  @override
  String accessStepCount(int index, int total) {
    return '$index / $total';
  }

  @override
  String get accessTurnOn => 'Turn on';

  @override
  String get accessOpenSettings => 'Open settings';

  @override
  String get accessItsSet => 'It\'s set';

  @override
  String get accessOpenAgain => 'Open again';

  @override
  String get accessIsOn => 'On';

  @override
  String get accessNotOnYet => 'Not on yet';

  @override
  String get accessDidYouSet => 'Did you turn it on there?';

  @override
  String accessWhere(String path) {
    return 'Where: $path';
  }

  @override
  String get accessOpenFailed => 'Couldn\'t open system settings';

  @override
  String get accessMicTitle => 'Allow the microphone';

  @override
  String get accessMicWhy => 'For voice input';

  @override
  String get accessStorageTitle => 'Allow file access';

  @override
  String get accessStorageWhy => 'Lets AI read and write photos, downloads and documents';

  @override
  String get accessNotifyTitle => 'Allow notifications';

  @override
  String get accessNotifyWhy => 'Tells you when a task finishes or needs you';

  @override
  String get accessBatteryTitle => 'Allow background running';

  @override
  String get accessBatteryWhy => 'Tasks keep going when you switch apps';

  @override
  String get accessVendorBackgroundWhy => 'Keeps the system from cutting tasks off in the background';

  @override
  String get accessAutostartTitle => 'Allow auto-start';

  @override
  String get accessAutostartWhy => 'Lets DSH Go come back after the system clears it';

  @override
  String accessVivoAutostartPath(String app) {
    return 'Permission management › Auto-start › $app';
  }

  @override
  String accessXiaomiAutostartPath(String app) {
    return 'Manage apps › $app › Autostart';
  }

  @override
  String get accessA11yTitle => 'Turn on accessibility';

  @override
  String get accessA11yWhy => 'Phone control reads the screen and taps through it';

  @override
  String get accessPopupTitle => 'Allow pop-ups in background';

  @override
  String get accessPopupWhy => 'Brings you back to DSH Go when phone control is done';

  @override
  String accessVivoPopupPath(String app) {
    return 'Permission management › $app › Display pop-up windows in background';
  }

  @override
  String accessXiaomiPopupPath(String app) {
    return 'Manage apps › $app › Other permissions › Display pop-up windows while running in the background';
  }

  @override
  String get accessOverlayTitle => 'Allow display over other apps';

  @override
  String get accessOverlayWhy => 'Lets your pet appear over other apps';

  @override
  String get accessOverlayGreyed => 'Switch greyed out?';

  @override
  String get accessRestrictedTitle => 'Allow restricted settings first';

  @override
  String get accessRestrictedTap =>
      'In Accessibility, tap “DSH Phone Control”; when “Restricted setting” appears, tap OK';

  @override
  String get accessRestrictedMenu =>
      'In App info, tap the three dots at the top right and choose “Allow restricted settings”';

  @override
  String get accessRestrictedAdvanced =>
      'In App info, open “Advanced settings” and turn on “Allow restricted settings”';

  @override
  String get accessRestrictedBack => 'Back in Accessibility, turn on “DSH Phone Control”';

  @override
  String get accessRestrictedHelp => 'See how';

  @override
  String get accessOpenA11y => 'Open accessibility';

  @override
  String get accessOpenAppInfo => 'Open app info';

  @override
  String get accessStateOn => 'On';

  @override
  String get accessStateOff => 'Off';

  @override
  String get accessStateVisited => 'Visited';

  @override
  String get accessStateUnknown => 'Set up';

  @override
  String get accessSummaryAllSet => 'All set';

  @override
  String accessSummaryLeft(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count still off', one: '1 still off');
    return '$_temp0';
  }

  @override
  String get accessSummaryMessage => 'Turn on the rest anytime in Settings › General › System permissions';

  @override
  String get accessFinishFailed => 'Couldn’t finish setup';

  @override
  String accessVoiceDownload(int size) {
    return 'The voice model (about $size MB) starts downloading once the engine is ready. Follow it in Settings › General › Voice input.';
  }

  @override
  String get accessPageTitle => 'System permissions';

  @override
  String get accessPageSubtitle => 'What each feature needs from Android';

  @override
  String get activityThinkingUntangle => 'Hmm… let me untangle this';

  @override
  String get activityThinkingWorkThrough => 'Let’s work through this';

  @override
  String get activityThinkingGears => 'Brain gears turning';

  @override
  String get activityThinkingSecond => 'Give me a second';

  @override
  String get activityThinkingSmoking => 'Brain’s working overtime';

  @override
  String get activityThinkingOnIt => 'Thinking, thinking';

  @override
  String get activityThinkingNoRush => 'One thought at a time';

  @override
  String get activityThinkingPonder => 'Let me ponder that';

  @override
  String get activityThinkingLogic => 'Working through the logic';

  @override
  String get activityThinkingBrain => 'Putting my brain to work';

  @override
  String get activityThinkingSort => 'Let me sort this out';

  @override
  String get activityThinkingMemory => 'Searching my memory';

  @override
  String get activityThinkingStorm => 'Brainstorming';

  @override
  String get activityThinkingSavor => 'Hmm… let that sink in';

  @override
  String get activityThinkingMoment => 'One moment, thinking';

  @override
  String get activityThinkingHeadScratch => 'Scratching my head…';

  @override
  String get activityThinkingPlayOut => 'Let’s see where this goes';

  @override
  String get activityThinkingLoading => 'Thoughts loading';

  @override
  String get activityThinkingMulling => 'Mulling it over';

  @override
  String get activityThinkingBreakDown => 'Hmm… let me break it down';

  @override
  String get activityThinkingTrain => 'All aboard the thought train';

  @override
  String get activityThinkingSomething => 'Hmm… there’s something here';

  @override
  String get activityThinkingJog => 'Taking this idea for a jog';

  @override
  String get activityThinkingPicture => 'Wait, I can picture it';

  @override
  String get activityThinkingBubbles => 'Thought bubbles';

  @override
  String get activityThinkingWaves => 'Brainwaves incoming';

  @override
  String get activityThinkingCoffee => 'Brain’s brewing coffee';

  @override
  String get activityThinkingDraft => 'Drafting it in my head';

  @override
  String get activityThinkingComing => 'Ah, it’s coming to me';

  @override
  String get activityThinkingBubbling => 'Ideas bubbling up';

  @override
  String get activityThinkingTackle => 'Hmm… let’s tackle it';

  @override
  String get activityThinkingSpark => 'A spark of an idea';

  @override
  String get activityThinkingLogicFirst => 'Let’s sort the logic first';

  @override
  String get activityThinkingLocate => 'Pinpointing it';

  @override
  String get activityThinkingInvestigate => 'Looking into it';

  @override
  String get activityThinkingGif => 'thinking.gif';

  @override
  String get activityThinkingLook => 'Lemme take a look';

  @override
  String get activityThinkingInteresting => 'Hmm… interesting';

  @override
  String get activityThinkingHands => 'Warming up my brain';

  @override
  String get activityThinkingFiveMinutes => 'Five minutes. Quite a project';

  @override
  String get activityThinkingSerious => 'Time to get serious';

  @override
  String get activityThinkingTricky => 'This is a bit tricky';

  @override
  String get activityThinkingAscend => 'Reaching a higher plane';

  @override
  String get activityThinkingAlmostPromise => 'Almost there, promise';

  @override
  String get activityThinkingLongWay => 'Took the scenic route';

  @override
  String get activityThinkingWrapping => 'Wrapping things up';

  @override
  String get activityThinkingSong => 'Give me one song’s worth';

  @override
  String get activityThinkingBigMove => 'Preparing the big move';

  @override
  String get activityThinkingSimple => 'Easy request. Or is it?';

  @override
  String get activityThinkingOneMinute => 'One minute, still thinking';

  @override
  String get activityThinkingChallenge => 'Now that’s a challenge';

  @override
  String get activityThinkingDig => 'Let me dig a little deeper';

  @override
  String get activityThinkingNotSimple => 'There’s more to this';

  @override
  String get activityThinkingDeep => 'Getting deep into it';

  @override
  String get activityThinkingBurning => 'Brain cells firing away';

  @override
  String get activityThinkingNearlyClear => 'Almost figured it out';

  @override
  String get activityThinkingTwisty => 'This one’s a little twisty…';

  @override
  String get activityThinkingWorkout => 'Giving my brain a workout…';

  @override
  String get activityThinkingStay => 'Stay with me, almost there';

  @override
  String get activityThinkingCloser => 'Let me think this through';

  @override
  String get activityThinkingThirtySeconds => 'Thirty seconds, still at it';

  @override
  String get activityThinkingSoon => 'Hang tight, nearly there';

  @override
  String get activityThinkingAnotherPass => 'Let me take another pass';

  @override
  String get activityThinkingTrack => 'Still on track';

  @override
  String get activityThinkingLead => 'Getting somewhere';

  @override
  String get activityThinkingCircles => 'Going in circles…';

  @override
  String get activityThinkingAnyMoment => 'Any moment now';

  @override
  String get activityThinkingStillLocate => 'Still narrowing it down';

  @override
  String get activityWaitingCall => 'Calling the model…';

  @override
  String get activityWaitingOnWay => 'Model’s on its way';

  @override
  String get activityWaitingSpeak => 'Waiting for a word…';

  @override
  String get activityWaitingWords => 'Finding the right words';

  @override
  String get activityWaitingAwake => 'Is the model awake yet?';

  @override
  String get activityWaitingStretch => 'Letting it stretch';

  @override
  String get activityWaitingYawn => 'The model just yawned';

  @override
  String get activityWaitingComing => 'Model: on my way';

  @override
  String get activityWaitingText => 'Waiting for the first words';

  @override
  String get activityWaitingQueue => 'Still in the queue';

  @override
  String get activityWaitingBrew => 'Something’s brewing';

  @override
  String get activityWaitingWater => 'Model’s taking a sip';

  @override
  String get activityWaitingWarmup => 'Letting it warm up';

  @override
  String get activityWaitingMeditate => 'Model’s meditating';

  @override
  String get activityWaitingBlink => 'Waiting for it to blink';

  @override
  String get activityWaitingMoment => 'It says, “one moment”';

  @override
  String get activityWritingWords => 'Finding the words';

  @override
  String get activityWritingTyping => 'Typing away';

  @override
  String get activityWritingInspired => 'Words flowing like magic';

  @override
  String get activityWritingOnIt => 'Writing, writing';

  @override
  String get activityWritingCareful => 'Choosing each word';

  @override
  String get activityWritingFlow => 'All in one flow';

  @override
  String get activityWritingPlain => 'Putting it in plain words';

  @override
  String get activityWritingIdeas => 'Putting ideas into words';

  @override
  String get activityWritingKeys => 'Tapping away';

  @override
  String get activityWritingAlmost => 'Almost done writing';

  @override
  String get activityWritingTell => 'Let me tell you';

  @override
  String get activityWritingFast => 'Writing up a storm';

  @override
  String get activityWritingBreeze => 'Words flying onto the page';

  @override
  String get activityWritingFormat => 'Tidying up the layout';

  @override
  String get activityNightAscend => 'Transcending bedtime…';

  @override
  String get activityNightHello => 'A little late-night hello';

  @override
  String get activityNightOwl => 'You’re a night owl too?';

  @override
  String get activityNightMoon => 'If the moon’s up, I’m up';

  @override
  String get activityNightSlow => 'Late-night brain, go easy';

  @override
  String get activityNightChampion => 'Night owl champion online';

  @override
  String get activityNightSleepy => 'Sleepy, but I’ve got this';

  @override
  String get activityNightMidnight => 'Still going past midnight';

  @override
  String get activityNightOpen => 'Open for the night shift';

  @override
  String get activityNightStars => 'Even the stars are asleep';

  @override
  String get activityNightDawn => 'Thinking into the small hours';

  @override
  String get activityWeekendChill => 'A little weekend chill';

  @override
  String get activityWeekendHere => 'Here on weekends too!';

  @override
  String get activityWeekendCompany => 'Here on days off too';

  @override
  String get activityWeekendOnline => 'No weekend shutdown';

  @override
  String get activityWeekendSneak => 'Sneaky weekend thinking';

  @override
  String get activityWeekendWorking => 'Working on the weekend too?';

  @override
  String get activityWeekendMode => 'Weekend mode ON';

  @override
  String get activityWeekendBugs => 'Weekend bug fixing';

  @override
  String get activityWeekendSkin => 'Weekend-exclusive look';

  @override
  String get activityNewYearCheers => 'Happy New Year!';

  @override
  String get activityNewYearDay => 'Happy New Year';

  @override
  String get activityNewYearBugs => 'New year, new bugs';

  @override
  String get activityNewYearFirstLine => 'First line of code this year';

  @override
  String get activityNewYearWork => 'Here’s to a great start';

  @override
  String get activityValentineCode => 'Coding on Valentine’s Day too';

  @override
  String get activityValentineLove => 'Code is true love';

  @override
  String get activityValentineDate => 'No date today?';

  @override
  String get activityValentineKeyboard => 'Keyboards are my roses';

  @override
  String get activityPiDay => 'Happy π Day';

  @override
  String get activityPiCircle => 'Extra-round circles today';

  @override
  String get activityAprilFools => 'Happy April Fools’ Day';

  @override
  String get activityAprilBug => 'This bug’s a prank, right?';

  @override
  String get activityAprilErrors => 'Watch out for prank errors';

  @override
  String get activityAprilKidding => 'Just kidding, no errors';

  @override
  String get activityLaborWorking => 'Still working on Labor Day';

  @override
  String get activityLaborPride => 'A little pride in the work';

  @override
  String get activityLaborSpirit => 'Worker mode: all in';

  @override
  String get activityChildrenDay => 'Happy Children’s Day';

  @override
  String get activityChildrenHeart => 'We’re all kids at heart';

  @override
  String get activityChildrenCode => 'Cute code only today';

  @override
  String get activityProgrammerCheers => 'Happy 1024 Programmers’ Day';

  @override
  String get activityProgrammerDay => 'It’s Programmers’ Day';

  @override
  String get activityProgrammer1024 => '1024, happy coding day';

  @override
  String get activityProgrammerCode => 'Coding on our holiday too';

  @override
  String get activityHalloween => 'Happy Halloween';

  @override
  String get activityHalloweenTreat => 'Trick or treat';

  @override
  String get activityHalloweenCode => 'Code can be spooky too';

  @override
  String get activityChristmasEve => 'Happy Christmas Eve';

  @override
  String get activityChristmasEveThinking => 'Thinking on Christmas Eve too';

  @override
  String get activityChristmasEveGift => 'Code tonight, gifts await';

  @override
  String get activityChristmas => 'Merry Christmas';

  @override
  String get activityChristmasCompany => 'Here with you for Christmas';

  @override
  String get activityChristmasEgg => 'A Christmas-only Easter egg';

  @override
  String get activityChristmasReindeer => 'Reindeer delivering code';

  @override
  String get activityYearEndEve => 'New Year’s Eve';

  @override
  String get activityYearEndLast => 'One last thought this year';

  @override
  String get activityYearEndReady => 'Ready for the new year';

  @override
  String get activityYearEndSeeYou => 'See you next year!';

  @override
  String get activityZodiacRat => 'Rat';

  @override
  String get activityZodiacOx => 'Ox';

  @override
  String get activityZodiacTiger => 'Tiger';

  @override
  String get activityZodiacRabbit => 'Rabbit';

  @override
  String get activityZodiacDragon => 'Dragon';

  @override
  String get activityZodiacSnake => 'Snake';

  @override
  String get activityZodiacHorse => 'Horse';

  @override
  String get activityZodiacGoat => 'Goat';

  @override
  String get activityZodiacMonkey => 'Monkey';

  @override
  String get activityZodiacRooster => 'Rooster';

  @override
  String get activityZodiacDog => 'Dog';

  @override
  String get activityZodiacPig => 'Pig';

  @override
  String get activityLunarCheers => 'Happy Lunar New Year!';

  @override
  String get activityLunarCode => 'Still coding over New Year';

  @override
  String get activityLunarEnvelope => 'Red envelopes, please';

  @override
  String get activityLunarSpring => 'Happy Spring Festival';

  @override
  String get activityLunarGreeting => 'New Year greetings';

  @override
  String get activityLunarCodeGreeting => 'The code says Happy New Year';

  @override
  String get activityRareSsr => 'SSR! Rare Easter egg';

  @override
  String get activityRareUr => 'UR drop';

  @override
  String get activityRareLegend => 'Legendary drop!';

  @override
  String get activityRareOrange => 'An orange-tier drop';

  @override
  String get activityRareEgg => 'An Easter egg found you';

  @override
  String get activityRareChosen => 'The chosen moment';

  @override
  String get activityRareHidden => 'You found the hidden edition';

  @override
  String get activityRareChat => 'Secret chat unlocked';

  @override
  String get activityRareMax => 'Rarity MAX';

  @override
  String get activityRareLucky => 'Luck is on your side';

  @override
  String get activityRareCritical => 'Critical hit';

  @override
  String get activityRareNextLevel => 'Next-level thinking';

  @override
  String get activityFailCrash => 'Well, that went sideways';

  @override
  String get activityFailOops => 'Oops';

  @override
  String get activityFailRun => 'That didn’t run';

  @override
  String get activityFailTrip => 'A little stumble';

  @override
  String get activityFailWrong => 'That’s not right';

  @override
  String get activityFailHiccup => 'Hit a hiccup';

  @override
  String get activityFailBroken => 'That’s not working';

  @override
  String get activityFailLocal => 'It works on my machine';

  @override
  String get activityFailYesterday => 'It worked yesterday';

  @override
  String get activityFailTough => 'That’s a tough one';

  @override
  String get activityFailCrack => 'Well, that fell apart';

  @override
  String get activityFailPressure => 'Feeling the pressure';

  @override
  String get activityFailCareless => 'Got a little careless there';

  @override
  String get activityFailSlip => 'A slip of the keys';

  @override
  String get activityFailTryAgain => 'Let’s try another way';

  @override
  String get activityFailChance => 'Give me another shot';

  @override
  String get activityTestGreen => 'All tests green';

  @override
  String get activityTestAllGreen => 'All green. Nice';

  @override
  String get activityTestFirstTry => 'Passed first try!';

  @override
  String get activityTestNoErrors => 'No errors';

  @override
  String get activityTestPassed => 'It passed!';

  @override
  String get activityTestSolid => 'Looking solid';

  @override
  String get activityTestRed => 'Red. Let’s see what broke';

  @override
  String get activityTestInvestigate => 'Tests failed. Looking into it';

  @override
  String get activityTestStubborn => 'One stubborn test';

  @override
  String get activityTestFix => 'Red light. Back to fixing';

  @override
  String get activityGitCommitSave => 'Committed. Progress saved';

  @override
  String get activityGitSaved => 'Progress saved';

  @override
  String get activityGitCommitRelief => 'Committed. Peace of mind';

  @override
  String get activityGitPushed => 'Pushed';

  @override
  String get activityGitPushDone => 'Pushed. Off it goes';

  @override
  String get activityGitCodeOut => 'Code’s out the door';

  @override
  String get activityInstallDone => 'Dependencies installed';

  @override
  String get activityInstallInternet => 'Downloaded half the internet';

  @override
  String get activityInstallPackages => 'All packages present';

  @override
  String get activityMilestoneFive => 'Tools x5, getting into it';

  @override
  String get activityMilestoneTen => 'Tool combo x10';

  @override
  String get activityMilestoneTwenty => 'Tools x20, on a roll';

  @override
  String get activityMilestoneFifty => 'Tools x50, working overtime';

  @override
  String get activityRetryWait => 'Hang tight, retrying';

  @override
  String get activityRetryBackoff => 'Turned away. Backing off';

  @override
  String get activityRetryKnock => 'Knocking once more';

  @override
  String get activityRateLimited => 'Rate limited. Taking a break';

  @override
  String get activityRate429 => '429. A breather, then retry';

  @override
  String get activityRateQueue => 'Quite a queue today';

  @override
  String get activityCompactContext => 'Tidying up the context…';

  @override
  String get activityCompactBag => 'Organizing my backpack…';

  @override
  String get activityCompactSpace => 'Making some room';

  @override
  String get activityCompactMemory => 'Trimming my memory';

  @override
  String get activityCompactChats => 'Packing up old chats';

  @override
  String get activityReminderWater => 'Half an hour. Water break?';

  @override
  String get activityReminderTenMinutes => 'Ten minutes. Quite a task';

  @override
  String get activityDiffTitle => 'Turn changes';

  @override
  String get activityDiffCopied => 'Patch copied';

  @override
  String get activityDiffNoWrap => 'Don’t wrap lines';

  @override
  String get activityDiffWrap => 'Wrap lines';

  @override
  String get activityDiffCopy => 'Copy patch';

  @override
  String get activityDiffEmpty => 'Empty file, no changes to show';

  @override
  String get activityDiffNewFile => 'New file';

  @override
  String get activityDiffUnknownLines => 'Line numbers unknown';

  @override
  String get activityDiffCopyPath => 'Copy path';

  @override
  String get activityThinking => 'Thinking';

  @override
  String get activityReplyInterrupted => 'Reply (interrupted)';

  @override
  String get activityWaitingApproval => 'Waiting for approval';

  @override
  String get activityWaitingAnswer => 'Waiting for answer';

  @override
  String get activityWriting => 'Writing reply';

  @override
  String get activityThinkingNow => 'Thinking';

  @override
  String get activityRetrying => 'Retrying';

  @override
  String get activityCompacting => 'Compacting context';

  @override
  String get activityVerbRun => 'Run';

  @override
  String get activityVerbWrite => 'Write';

  @override
  String get activityVerbEdit => 'Edit';

  @override
  String get activityVerbImage => 'View image';

  @override
  String get activityVerbRead => 'Read';

  @override
  String get activityVerbFind => 'Find';

  @override
  String get activityVerbSearch => 'Search';

  @override
  String get activityVerbWebSearch => 'Search web';

  @override
  String get activityVerbWebView => 'View web';

  @override
  String get activityVerbSubagent => 'Send subagent';

  @override
  String get activityVerbTodo => 'Update to-dos';

  @override
  String get activitySecretHide => 'Hide key';

  @override
  String get activitySecretShow => 'Show key';

  @override
  String get activitySlashNoMatch => 'No matching command. Send as a message';

  @override
  String get activitySlashCommands => 'Commands';

  @override
  String get activitySlashEnterArgs => 'Enter arguments, then send';

  @override
  String get activitySlashRunIntent => 'Command · Run';

  @override
  String get activitySlashInsertIntent => 'Command · Insert';

  @override
  String get activitySlashSkillIntent => 'Skill · Insert';

  @override
  String get activityStepTitle => 'Step details';

  @override
  String get activityStepMissing => 'This step isn’t in the loaded history';

  @override
  String get activityStepQuestion => 'Question';

  @override
  String get activityStepSuccess => 'Succeeded';

  @override
  String get activityStepNeedsPermission => 'Needs permission';

  @override
  String get activityTools => 'Tools';

  @override
  String get activityStepDispatched => 'Dispatched';

  @override
  String get activityStepExecution => 'Execution';

  @override
  String get activityStepLocation => 'Location';

  @override
  String get activityStepArguments => 'Arguments';

  @override
  String get activityStepChanges => 'Changes';

  @override
  String get activityStepFullScreen => 'View full screen';

  @override
  String get activityStepReadContent => 'Content read';

  @override
  String get activityStepWrittenContent => 'Content written';

  @override
  String get activityStepError => 'Error';

  @override
  String get activityOutput => 'Output';

  @override
  String get activityStepResult => 'Result';

  @override
  String get activityStepDeclined => 'You declined this tool call';

  @override
  String get activityStepNoOutput => 'No output';

  @override
  String get activityStepStart => 'Started';

  @override
  String get activityDuration => 'Duration';

  @override
  String get activityFirstToken => 'First token';

  @override
  String get activityStepGeneration => 'Generation';

  @override
  String get activityStepSpeed => 'Speed';

  @override
  String get activityModel => 'Model';

  @override
  String get activityStepTiming => 'Timing';

  @override
  String get activityUsage => 'Usage';

  @override
  String get activityInput => 'Input';

  @override
  String get activityStepCacheHit => '  Cache hit';

  @override
  String get activityStepCacheMiss => '  Cache miss';

  @override
  String get activityStepCacheWrite => '  Cache write';

  @override
  String get activityStepReasoning => '  Reasoning';

  @override
  String get activityStepAnswer => '  Answer';

  @override
  String get activityStepThinking => 'Thinking';

  @override
  String get activityStepExplanation => 'Explanation';

  @override
  String get activityStepToolCalls => 'Tools called in this step';

  @override
  String get activityStepProcessing => 'Model is processing';

  @override
  String get activityApprovalAllowed => 'Allowed';

  @override
  String get activityApprovalUnanswered => 'No approval received';

  @override
  String get activityApprovalAnswered => 'Answered';

  @override
  String get activityToolRead => 'Read';

  @override
  String get activityToolWrite => 'Write';

  @override
  String get activityToolCall => 'Call tool';

  @override
  String get activityTraceTitle => 'Turn trajectory';

  @override
  String get activityTraceNotLoaded => 'This turn’s history hasn’t loaded yet';

  @override
  String get activityTraceOutputLimit => 'Output limit reached';

  @override
  String get activityTraceEngineRestarted => 'Interrupted by engine restart';

  @override
  String get activityTraceBlocked => 'Blocked';

  @override
  String get activityTraceHeading => 'Turn trajectory  ';

  @override
  String get activityTraceWaiting => 'Waiting for you';

  @override
  String get activityTraceNoSteps => 'No timed steps in this turn';

  @override
  String get activityUsageInputIncludesCache => 'Input includes cache hits';

  @override
  String get activityCacheHit => 'Cache hit';

  @override
  String get activitySummaryTodo => 'Updated to-dos';

  @override
  String get activityUsageBalance => 'DeepSeek balance';

  @override
  String get activityUsageContext => 'Context';

  @override
  String get activityUsageChat => 'This chat';

  @override
  String get activityUsageAfterMessage => 'Appears after you send a message';

  @override
  String get activityUsageWaiting => 'Waiting for context usage data';

  @override
  String get activityUsageProjected => 'Estimated next request';

  @override
  String get activityUsageLastRequest => 'Last request';

  @override
  String get activityUsageBreakdownEstimate =>
      'Breakdown items are independent estimates and may differ from the total';

  @override
  String get activityUsageCumulativeInput => 'Total input';

  @override
  String get activityUsageContextFull => 'Context nearly full. Send /compact to compact it';

  @override
  String get activitySpanZero => '0 sec';

  @override
  String get activitySpanTiny => '<0.1 sec';

  @override
  String activityTokensTenThousands(String value) {
    return '${value}K';
  }

  @override
  String activityTokensHundredMillions(String value) {
    return '${value}M';
  }

  @override
  String activityUsageContextSemantics(String percent) {
    return 'Context $percent used, view usage';
  }

  @override
  String activityUsageSystemTokens(String tokens) {
    return 'System $tokens';
  }

  @override
  String activityUsageToolTokens(String tokens) {
    return 'Tools $tokens';
  }

  @override
  String activityUsageMessageTokens(String tokens) {
    return 'Messages $tokens';
  }

  @override
  String activityUsageTurns(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count turns total', one: '1 turn total');
    return '$_temp0';
  }

  @override
  String activityUsageCacheWriteTokens(String tokens) {
    return 'Cache write $tokens';
  }

  @override
  String activitySummaryCommands(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Ran $count commands',
      one: 'Ran 1 command',
    );
    return '$_temp0';
  }

  @override
  String activitySummaryEditedFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Edited $count files',
      one: 'Edited 1 file',
    );
    return '$_temp0';
  }

  @override
  String activitySummaryReadFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'Read $count files', one: 'Read 1 file');
    return '$_temp0';
  }

  @override
  String activitySummarySearches(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Searched $count times',
      one: 'Searched 1 time',
    );
    return '$_temp0';
  }

  @override
  String activitySummaryWeb(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Used the web $count times',
      one: 'Used the web 1 time',
    );
    return '$_temp0';
  }

  @override
  String activitySummarySubagents(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Called subagents $count times',
      one: 'Called a subagent 1 time',
    );
    return '$_temp0';
  }

  @override
  String activitySummaryOther(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Other tools: $count calls',
      one: 'Other tools: 1 call',
    );
    return '$_temp0';
  }

  @override
  String activitySummaryTotal(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'Used $count tools', one: 'Used 1 tool');
    return '$_temp0';
  }

  @override
  String activityDiffBlockMarker(int index, int total) {
    return '@@ Change $index/$total @@';
  }

  @override
  String activityDiffEditMarker(int index, int total) {
    return 'Edit $index of $total';
  }

  @override
  String activityTraceSpanSemantics(String title, String detail, String duration) {
    return '$title $detail, duration $duration';
  }

  @override
  String activityTraceGroupSemantics(String label, String duration) {
    return '$label, duration $duration';
  }

  @override
  String activityTraceEstimatedCost(String cost) {
    return '$cost (estimated at official rates)';
  }

  @override
  String activityTraceReasoningTokens(String tokens) {
    return 'Reasoning: $tokens';
  }

  @override
  String activityStepPosition(int turn, Object step) {
    return 'Turn $turn · Step $step';
  }

  @override
  String activityStepTokenSpeed(String speed) {
    return '$speed tokens/sec';
  }

  @override
  String activityStepRetryCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count times', one: '1 time');
    return '$_temp0';
  }

  @override
  String activityStepTruncated(String text, int count) {
    return '$text\n… (Showing only the first ${count}k characters. Copy for the full text)';
  }

  @override
  String activityStepLiveElapsed(String elapsed, String suffix) {
    return '$elapsed · In progress$suffix';
  }

  @override
  String activityStepCopySection(String title) {
    return 'Copy $title';
  }

  @override
  String activityStepCopiedSection(String title) {
    return 'Copied $title';
  }

  @override
  String activitySlashDescriptionArgs(String description) {
    return '$description · Enter arguments, then send';
  }

  @override
  String activitySpanSecondsText(String seconds) {
    return '$seconds sec';
  }

  @override
  String activitySpanSeconds(int seconds) {
    return '$seconds sec';
  }

  @override
  String activitySpanMinutesSeconds(int minutes, String seconds) {
    return '$minutes min $seconds sec';
  }

  @override
  String activitySpanHoursMinutes(int hours, String minutes) {
    return '$hours h $minutes min';
  }

  @override
  String activityCostUnderCent(String symbol) {
    return 'Under ${symbol}0.01';
  }

  @override
  String activityCostApprox(String symbol, String amount) {
    return '≈ $symbol$amount';
  }

  @override
  String activitySpanRetries(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Retried $count times',
      one: 'Retried 1 time',
    );
    return '$_temp0';
  }

  @override
  String activitySpanToolCalls(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Chose to call $count tools',
      one: 'Chose to call 1 tool',
    );
    return '$_temp0';
  }

  @override
  String activityRunningItems(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'among $count items', one: 'among 1 item');
    return '$_temp0';
  }

  @override
  String activityRetryAttempt(int count) {
    return 'Attempt $count';
  }

  @override
  String activityDiffFileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count files', one: '1 file');
    return '$_temp0';
  }

  @override
  String activityDiffFileSemantics(String path, int added, int removed) {
    String _temp0 = intl.Intl.pluralLogic(added, locale: localeName, other: '$added lines added', one: '1 line added');
    String _temp1 = intl.Intl.pluralLogic(
      removed,
      locale: localeName,
      other: '$removed lines removed',
      one: '1 line removed',
    );
    return '$path, $_temp0, $_temp1';
  }

  @override
  String activityDiffEditNumber(int edit) {
    return 'Edit $edit';
  }

  @override
  String activityDiffHunkNumber(int index) {
    return 'Change $index';
  }

  @override
  String activityDiffFromLine(int line) {
    return 'From line $line';
  }

  @override
  String activityDiffEditCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Edited $count times',
      one: 'Edited 1 time',
    );
    return '$_temp0';
  }

  @override
  String activityLunarZodiac(String animal) {
    return 'Good luck in the Year of the $animal';
  }

  @override
  String activityReminderHours(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: '$hours hours straight. Take a break?',
      one: 'One hour straight. Take a break?',
    );
    return '$_temp0';
  }

  @override
  String get activityStepModelRequest => 'One model request';

  @override
  String activityStepModelRequestDetail(String detail) {
    return 'One model request · $detail';
  }

  @override
  String activityUsageEstimatedCost(String symbol, String amount) {
    return '≈ $symbol$amount';
  }

  @override
  String activitySlashCommandSemantics(String label, String name) {
    return '$label, /$name';
  }

  @override
  String get activityQuotaTitle => 'Subscription usage';

  @override
  String get activityQuotaRefresh => 'Refresh usage';

  @override
  String get activityQuotaPermissionDenied => 'This subscription does not have permission to access usage.';

  @override
  String get activityQuotaAuthError => 'Sign-in expired or access denied. Check your subscription sign-in.';

  @override
  String get activityQuotaNetworkError => 'Network error. Try again later.';

  @override
  String get activityQuotaRateLimited => 'Too many requests. Try again later.';

  @override
  String get activityQuotaLoading => 'Loading subscription usage…';

  @override
  String get activityQuotaUnavailable => 'Can\'t load subscription usage right now. Try again later.';

  @override
  String get activityQuotaUnsupported => 'This host does not support subscription usage';

  @override
  String get activityQuotaSignedOut => 'Subscription is signed out';

  @override
  String get activityQuotaPrimary => 'Primary limit';

  @override
  String get activityQuotaSecondary => 'Secondary limit';

  @override
  String get activityQuotaFiveHour => '5 hours';

  @override
  String get activityQuotaSevenDay => '7 days';

  @override
  String get activityQuotaSevenDaySonnet => '7 days · Sonnet';

  @override
  String get activityQuotaSevenDayOpus => '7 days · Opus';

  @override
  String activityQuotaUsed(String value) {
    return '$value used';
  }

  @override
  String activityQuotaReset(String time) {
    return 'Resets: $time';
  }

  @override
  String get activityToolListSeparator => ', ';

  @override
  String get androidShellTitle => 'Android Shell';

  @override
  String get androidShellEntryHint => 'Separate system-command channel, off by default';

  @override
  String get androidShellSubtitle =>
      'Run Android system commands on this phone through Shizuku or self-ADB, not bash inside Ubuntu.';

  @override
  String get androidShellEnable => 'Allow Android Shell';

  @override
  String get androidShellEnableHint =>
      'A separate switch, independent of non-disruptive mode and screen confirmation settings.';

  @override
  String get androidShellConfirmationNote =>
      'Every command needs confirmation and may change system settings and files.';

  @override
  String get androidShellMasterOff => 'Turn on Phone control on the previous page first.';

  @override
  String get androidShellRiskTitle => 'Allow Android system commands?';

  @override
  String get androidShellRiskBody =>
      'Commands use the selected channel\'s actual UID and may change apps, system settings, and shared files. Screen app rules cannot fully protect against them. Every command still requires separate native confirmation. Only allow commands you understand and trust.';

  @override
  String get androidShellRiskAction => 'Allow Android Shell';

  @override
  String get androidShellBackend => 'Connection method';

  @override
  String get androidShellDetails => 'Details';

  @override
  String get androidShellReady => 'Connected';

  @override
  String get androidShellShizukuHint =>
      'Use an installed, running Shizuku with explicit authorization. Android 14, accessibility, and non-disruptive mode are not required.';

  @override
  String get androidShellAdb => 'Self-ADB';

  @override
  String get androidShellAdbHint =>
      'Connect to this phone\'s wireless debugging with the app\'s private ADB identity. Other devices are not contacted.';

  @override
  String get androidShellInstalled => 'Shizuku installed';

  @override
  String get androidShellRunning => 'Shizuku running';

  @override
  String get androidShellGranted => 'Shizuku authorized';

  @override
  String get androidShellPaired => 'ADB paired';

  @override
  String get androidShellConnected => 'ADB connected';

  @override
  String get androidShellAuthorize => 'Request Shizuku authorization';

  @override
  String get androidShellAuthorizeHint =>
      'Install and start Shizuku, then press this button to authorize dsh-Go. Opening or refreshing this page never requests permission.';

  @override
  String get androidShellStatus => 'Execution status';

  @override
  String get androidShellUid => 'Actual UID';

  @override
  String get androidShellUidUnknown => 'Not reported yet';

  @override
  String get androidShellRefresh => 'Refresh status';

  @override
  String get androidShellStop => 'Stop Android Shell';

  @override
  String get androidShellStopHint =>
      'Cancel current commands and stop separate Shell execution without turning off screen control.';

  @override
  String get androidShellPairingGuide =>
      'In Developer options, enable Wireless debugging and choose Pair device with pairing code. The code is used only for this pairing and is not saved or logged.';

  @override
  String get androidShellStartPairing => 'Open pairing guidance';

  @override
  String get androidShellPair => 'Enter pairing code';

  @override
  String get androidShellPairSubmit => 'Pair';

  @override
  String get androidShellPairCode => 'Six-digit pairing code';

  @override
  String get androidShellPairPort => 'Pairing port (optional)';

  @override
  String get androidShellPairPortHint =>
      'Use the port in the pairing dialog, not the connection port on the main Wireless debugging page. Leave blank for discovery.';

  @override
  String get androidShellConnect => 'Connect ADB';

  @override
  String get androidShellConnectChannel => 'Connect selected channel';

  @override
  String get androidShellConnectPort => 'Connection port (optional)';

  @override
  String get androidShellConnectPortHint =>
      'Use the port under IP address & port on the main Wireless debugging page, not the pairing port. Only this phone is contacted. Leave blank for discovery.';

  @override
  String androidShellErrorCode(String code) {
    return 'Error code: $code';
  }

  @override
  String androidShellLimits(int seconds, int bytes) {
    return 'Up to $seconds seconds and $bytes output bytes per command';
  }

  @override
  String get androidShellErrorDisabled => 'Android Shell is off.';

  @override
  String get androidShellErrorNotConnected => 'The selected channel is not connected.';

  @override
  String get androidShellErrorShizukuMissing => 'Install Shizuku first.';

  @override
  String get androidShellErrorShizukuStopped => 'Start Shizuku, then refresh the status.';

  @override
  String get androidShellErrorPermissionRequired => 'Explicit authorization in Shizuku is required.';

  @override
  String get androidShellErrorAdbNotPaired => 'Pair this phone with wireless debugging, then connect ADB.';

  @override
  String get androidShellErrorConnectFailed =>
      'Connection failed. Check the selected channel and current wireless-debugging connection port, then retry.';

  @override
  String get androidShellErrorIdentityChanged => 'The channel identity changed. Stop, then authorize or connect again.';

  @override
  String get androidShellErrorBusy => 'Another operation is still pending. Retry later or stop Android Shell first.';

  @override
  String get androidShellErrorInvalidArguments =>
      'Invalid input. Use a six-digit pairing code and a port from 1 to 65535.';

  @override
  String get androidShellErrorCancelled => 'The operation was cancelled.';

  @override
  String get androidShellErrorTimeout =>
      'The operation timed out. Verify its outcome first; never automatically retry a dispatched command.';

  @override
  String get androidShellErrorConfirmationDenied => 'The command was not approved.';

  @override
  String get androidShellErrorCleanupFailed =>
      'Stop cleanup did not finish. Retry stopping before running new commands.';

  @override
  String get androidShellErrorLocked => 'The phone is locked. Unlock it and retry.';

  @override
  String get androidShellErrorConfirmationUnavailable =>
      'Native confirmation cannot be shown. Return to the app and check notification permission.';

  @override
  String get androidShellErrorTransportLost =>
      'The channel disconnected. Verify the outcome first; never automatically retry a dispatched command. Reconnect if needed.';

  @override
  String get androidShellErrorProtocolMismatch =>
      'The native module does not support this Shell protocol. Update the app.';

  @override
  String get androidShellErrorNativeUnavailable => 'The Android Shell native module is unavailable in this build.';

  @override
  String get androidShellErrorInvalidResponse => 'No valid native status was received. Refresh or update the app.';

  @override
  String get androidShellErrorStopFailed => 'Stopping was not confirmed. Refresh the status and retry stopping.';

  @override
  String get androidShellErrorUnknown =>
      'The outcome could not be confirmed. Verify it first; never automatically retry a dispatched command.';

  @override
  String get botsFolderGone => 'This folder is gone';

  @override
  String get botsFolderReadFailed => 'Couldn’t read this folder';

  @override
  String get botsFolderOpenFailed => 'Couldn’t open this folder';

  @override
  String botsFolderCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count folders', one: '1 folder');
    return '$_temp0';
  }

  @override
  String get botsWorkingFolder => 'Working directory';

  @override
  String get botsFolderTeamDefault => 'Team workspace';

  @override
  String get botsFolderRoomDefault => 'Each Bot’s own directory';

  @override
  String get botsFolderHint => 'Folders on the connected host.';

  @override
  String get botsFolderCurrent => 'Current directory';

  @override
  String get botsFolderUnavailable => 'The connection or folder changed. Reopen to continue.';

  @override
  String get botsFolderNoChoices => 'No other folders on the host.';

  @override
  String get botsFolderConfirm => 'Use this working directory?';

  @override
  String get botsFolderRefused =>
      'The host refused this folder. It may be gone, inaccessible or protected. Choose another or retry.';

  @override
  String botsChildCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count child agents',
      one: '1 child agent',
    );
    return '$_temp0';
  }

  @override
  String get botsCurrentChat => 'Current chat';

  @override
  String botsSubagentCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count subagents', one: '1 subagent');
    return '$_temp0';
  }

  @override
  String botsRunningCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count running', one: '1 running');
    return '$_temp0';
  }

  @override
  String botsFailedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count failed', one: '1 failed');
    return '$_temp0';
  }

  @override
  String botsNestedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Includes $count child agents',
      one: 'Includes 1 child agent',
    );
    return '$_temp0';
  }

  @override
  String botsBackToParent(String title) {
    return 'Back to “$title”';
  }

  @override
  String botsTeamMemberCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Agent team, $count members',
      one: 'Agent team, 1 member',
    );
    return '$_temp0';
  }

  @override
  String get botsAgentTeam => 'Agent team';

  @override
  String botsSubagentRunningCount(int count, int running) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count subagents', one: '1 subagent');
    String _temp1 = intl.Intl.pluralLogic(running, locale: localeName, other: '$running running', one: '1 running');
    return '$_temp0, $_temp1';
  }

  @override
  String get botsSubagents => 'Subagents';

  @override
  String get botsNoSubagents => 'No subagents sent';

  @override
  String get botsOpenChatFirst => 'Open a chat first';

  @override
  String get botsTeamReadFailed => 'Couldn’t load the team';

  @override
  String get botsNoTeamOnHost => 'No agent team on this host';

  @override
  String get botsTeamNotEnabled => 'Agent team is off';

  @override
  String get botsTeamDescription => 'Agents work together on a shared task board';

  @override
  String get botsTeamEnabling => 'Turning on…';

  @override
  String get botsTeamEnable => 'Turn on team';

  @override
  String botsMembersWorking(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count members working',
      one: '1 member working',
    );
    return '$_temp0';
  }

  @override
  String get botsTeamStandby => 'All on standby';

  @override
  String get botsMembers => 'Members';

  @override
  String get botsTasks => 'Tasks';

  @override
  String get botsTeamRecordUnreadable => 'Couldn’t read a team record';

  @override
  String get botsMessages => 'Messages';

  @override
  String get botsOwner => 'Owner';

  @override
  String get botsTeamCreateHint => 'Ask AI to form a team in a chat';

  @override
  String get botsCurrent => 'Current';

  @override
  String get botsNoTasks => 'No tasks yet';

  @override
  String get botsTodo => 'To do';

  @override
  String get botsUnassigned => 'Unassigned';

  @override
  String botsTaskWaitingFor(String dependencies) {
    return 'Waiting for $dependencies';
  }

  @override
  String get botsWriteOverlap => 'Overlapping write scopes';

  @override
  String get botsWaitingDependencies => 'Waiting on dependencies';

  @override
  String get botsReadyToStart => 'Ready to start';

  @override
  String get botsTaskId => 'ID';

  @override
  String get botsDependencies => 'Dependencies';

  @override
  String get botsWriteScopes => 'Write scopes';

  @override
  String get botsMessagesReadFailed => 'Couldn’t load messages';

  @override
  String get botsNoMemberMessages => 'No messages between members yet';

  @override
  String get botsMessagesIncomplete => 'Some members’ messages didn’t load · Retry';

  @override
  String botsDateTime(String date, String time) {
    return '$date $time';
  }

  @override
  String get botsViewDetails => 'View details';

  @override
  String get botsAdmin => 'Admin';

  @override
  String get botsFullTextChanged => 'This conversation has changed';

  @override
  String get botsFullTextReopen => 'Open the message again';

  @override
  String get botsFullTextReadFailed => 'Couldn’t load the full text';

  @override
  String get botsShowAll => 'Show all';

  @override
  String get botsImagePlaceholder => '[Image]';

  @override
  String get botsSending => 'Sending';

  @override
  String get botsWriteOwn => 'Write your own';

  @override
  String get botsSubmit => 'Submit';

  @override
  String botsChooseModelFor(String name) {
    return 'Choose a model for $name';
  }

  @override
  String get botsModelGreeting => 'It’ll say hello once you choose';

  @override
  String get botsChooseModel => 'Choose model';

  @override
  String get botsSkipAnswer => 'Skip';

  @override
  String get botsBotGone => 'This bot is gone';

  @override
  String get botsWaitingModel => 'Choose a model';

  @override
  String get botsThinking => 'Thinking';

  @override
  String get botsMainBot => 'Main bot';

  @override
  String get botsIdle => 'Idle';

  @override
  String get botsAnsweredQuestion => 'You answered its question';

  @override
  String get botsEarlierMessages => 'Earlier messages';

  @override
  String botsComposerHint(String name) {
    return 'Message $name…';
  }

  @override
  String botsDeleteNamed(String name) {
    return 'Delete “$name”?';
  }

  @override
  String get botsDeleteBotBody => 'Its chats stay. Its memories move to the archive.';

  @override
  String get botsTokensToday => '24h tokens';

  @override
  String get botsMemoryUnit => 'Memories';

  @override
  String get botsRoomUnit => 'Group chats';

  @override
  String get botsProfile => 'Profile';

  @override
  String get botsModel => 'Model';

  @override
  String get botsBotName => 'Name';

  @override
  String get botsRole => 'Role';

  @override
  String get botsWriterExample => 'For example: Writer';

  @override
  String get botsInstructions => 'Instructions';

  @override
  String get botsInstructionsHint => 'How it should work';

  @override
  String get botsColor => 'Color';

  @override
  String get botsUsage => 'Usage';

  @override
  String get botsUsageScanning => 'Still counting older chats. Totals will fill in.';

  @override
  String get botsUsageRefresh => 'Refresh';

  @override
  String get botsToday => 'Last 24 hours';

  @override
  String get botsLastWeek => 'Last 7 days';

  @override
  String get botsLastMonth => 'Last 30 days';

  @override
  String botsMonthCalls(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Last 30 days · $count calls',
      one: 'Last 30 days · 1 call',
    );
    return '$_temp0';
  }

  @override
  String get botsFullRecord => 'Full record';

  @override
  String get botsEveryToolCall => 'Every tool call';

  @override
  String get botsUnsetMain => 'Unset main bot';

  @override
  String get botsSetMain => 'Set as main';

  @override
  String get botsDeleteBot => 'Delete bot';

  @override
  String get botsEffortOff => 'No thinking';

  @override
  String get botsEffortMinimal => 'Minimal';

  @override
  String get botsEffortLow => 'Low';

  @override
  String get botsEffortMedium => 'Medium';

  @override
  String get botsEffortHigh => 'High';

  @override
  String get botsEffortMax => 'Max';

  @override
  String botsNamedRecord(String name) {
    return '$name · Full record';
  }

  @override
  String get botsOrganizingNotes => 'Organizing notes';

  @override
  String get botsToolRun => 'run commands';

  @override
  String get botsToolRead => 'view files';

  @override
  String get botsToolEdit => 'edit files';

  @override
  String get botsToolSearch => 'search the web';

  @override
  String get botsToolBrowse => 'browse the web';

  @override
  String get botsToolMessage => 'contact other bots';

  @override
  String get botsToolGroup => 'chat with the group';

  @override
  String get botsToolMemory => 'organize memories';

  @override
  String get botsToolRecall => 'look through records';

  @override
  String get botsToolTeam => 'organize the team';

  @override
  String get botsToolAsk => 'ask you something';

  @override
  String get botsToolWork => 'work';

  @override
  String get botsJustNow => 'Just now';

  @override
  String botsCountHundredMillion(String value) {
    return '${value}M';
  }

  @override
  String botsCountTenThousand(String value) {
    return '${value}K';
  }

  @override
  String get botsModelNotSelected => 'Not selected';

  @override
  String botsYourPreview(String preview) {
    return 'You: $preview';
  }

  @override
  String botsEventWorking(String name) {
    return '$name started working';
  }

  @override
  String botsEventApproval(String name) {
    return '$name needs your approval';
  }

  @override
  String botsEventDone(String name) {
    return '$name finished working';
  }

  @override
  String botsEventStopped(String name) {
    return 'You stopped $name’s work';
  }

  @override
  String botsEventFailed(String name) {
    return '$name couldn’t answer';
  }

  @override
  String botsEventMissed(String name) {
    return '$name didn’t respond in time';
  }

  @override
  String botsEventLookup(String name) {
    return '$name looked through its chats';
  }

  @override
  String botsEventLookupQuery(String name, String query) {
    return '$name searched its chats for “$query”';
  }

  @override
  String botsEventResumed(String name) {
    return '$name resumed after restarting';
  }

  @override
  String botsEventCut(String name) {
    return '$name stopped after another restart interrupted it';
  }

  @override
  String get botsAutomation => 'Automation';

  @override
  String botsAutomationText(String text) {
    return 'Automation: $text';
  }

  @override
  String get botsOtherBot => 'Another bot';

  @override
  String botsMessageFrom(String name) {
    return 'Message from $name';
  }

  @override
  String botsEventReplied(String name) {
    return '$name replied';
  }

  @override
  String get botsGroupReplied => 'A reply in the group';

  @override
  String botsNamedGroupReplied(String name) {
    return 'A reply in “$name”';
  }

  @override
  String botsEventCalledStop(String name) {
    return '$name stopped the work';
  }

  @override
  String get botsChooseMember => 'Choose member';

  @override
  String get botsMentionMember => 'Mention member';

  @override
  String get botsRelayUnavailable => 'Bots aren’t available over Relay';

  @override
  String get botsUseSsh => 'Connect to this computer over SSH to use bots';

  @override
  String get botsTeamLoadFailed => 'Couldn’t load the bot team';

  @override
  String botsBotCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count bots', one: '1 bot');
    return '$_temp0';
  }

  @override
  String botsRoomCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count group chats', one: '1 group chat');
    return '$_temp0';
  }

  @override
  String get botsNewBot => 'New bot';

  @override
  String get botsGroupChat => 'Group chat';

  @override
  String get botsNewGroup => 'New group';

  @override
  String get botsDuplicateCreated => 'Copied. It will show up in the list shortly.';

  @override
  String get botsDuplicate => 'Duplicate Bot';

  @override
  String get botsDuplicateHint => 'Same settings, fresh chat and memory';

  @override
  String botsDuplicateNamed(String name) {
    return 'Duplicate $name?';
  }

  @override
  String get botsDuplicateBody =>
      'The new Bot keeps its job, instructions and model settings, starts with a fresh chat and personal memory, and gets its name from the host. When a model is available, it opens with a greeting.';

  @override
  String get botsChooseModelStart => 'Choose a model to start';

  @override
  String get botsNoChats => 'No chats yet';

  @override
  String botsUnreadCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count unread', one: '1 unread');
    return '$_temp0';
  }

  @override
  String get botsMainTag => 'Main';

  @override
  String get botsMemberNeedsApproval => 'A member needs approval';

  @override
  String botsNamedWorking(String name) {
    return '$name is working';
  }

  @override
  String botsNamesWorking(String names) {
    return '$names are working';
  }

  @override
  String botsMemberCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count members', one: '1 member');
    return '$_temp0';
  }

  @override
  String get botsUpdateRequired => 'DS Bot needs an update';

  @override
  String get botsInstall => 'Install DS Bot';

  @override
  String get botsUpdateForPhone => 'Update to use it on your phone';

  @override
  String get botsInstallDescription => 'Always-on bots, each with its own memory and role';

  @override
  String botsInstallOnHost(String host) {
    return 'Install on $host to get started';
  }

  @override
  String botsRunsOnHost(String host) {
    return 'Runs on $host';
  }

  @override
  String get botsInstalling => 'Installing';

  @override
  String get botsMemory => 'Memory';

  @override
  String get botsEditMemory => 'Edit memory';

  @override
  String get botsAddMemory => 'Add memory';

  @override
  String get botsMemoryReplyExample => 'For example: Keep replies short';

  @override
  String get botsMemoryDraftExample => 'For example: First draft by Friday';

  @override
  String botsMemoryCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'Memory · $count', one: 'Memory · 1');
    return '$_temp0';
  }

  @override
  String get botsMemoryReadFailed => 'Couldn’t load memories';

  @override
  String get botsSummary => 'Summary';

  @override
  String get botsNoMemory => 'No memories yet';

  @override
  String get botsTeam => 'Team';

  @override
  String get botsSelf => 'Self';

  @override
  String get botsWrittenByYou => 'Written by you';

  @override
  String get botsNameRequired => 'Enter a name';

  @override
  String get botsRoleHint => 'What it does, in one sentence';

  @override
  String get botsNewInstructionsHint => 'How it should work and what to keep in mind';

  @override
  String get botsAppearance => 'Appearance';

  @override
  String get botsCreating => 'Creating';

  @override
  String get botsGroupNameOptional => 'Group name (optional)';

  @override
  String botsMembersSelected(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Members · $count selected',
      one: 'Members · 1 selected',
    );
    return '$_temp0';
  }

  @override
  String get botsPickTwoBots => 'Pick at least two bots';

  @override
  String get botsFullText => 'Full text';

  @override
  String botsTextPartial(String count) {
    return 'Showing the first $count characters';
  }

  @override
  String get botsTextCompletenessUnknown => 'Couldn’t confirm this is the complete text';

  @override
  String get botsRoomGone => 'This group chat is gone';

  @override
  String botsNamedSpeaking(String name) {
    return '$name is speaking';
  }

  @override
  String botsNamedActivity(String name, String activity) {
    return '$name: $activity';
  }

  @override
  String get botsWorking => 'Working';

  @override
  String get botsDiscussing => 'Discussing';

  @override
  String get botsTyping => 'Typing';

  @override
  String get botsGroupComposerHint => 'Message everyone…';

  @override
  String get botsDecline => 'Decline';

  @override
  String get botsAllowOnce => 'Allow once';

  @override
  String get botsPrivateChat => 'Chat privately';

  @override
  String get botsSetAdmin => 'Make admin';

  @override
  String get botsRemoveMember => 'Remove from group';

  @override
  String get botsDeleteRoomBody => 'The group’s records stay. Its memories move to the archive.';

  @override
  String botsNamedAdmin(String name) {
    return 'Admin $name';
  }

  @override
  String botsRoomWorkingCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count working', one: '1 working');
    return '$_temp0';
  }

  @override
  String botsMembersCountTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'Members · $count', one: 'Members · 1');
    return '$_temp0';
  }

  @override
  String get botsStopMember => 'Stop';

  @override
  String get botsAddMember => 'Add members';

  @override
  String get botsWhoAnswers => 'Who answers first';

  @override
  String get botsAdminFirst => 'Admin first';

  @override
  String get botsEveryoneInTurn => 'Take turns';

  @override
  String get botsGroupName => 'Group name';

  @override
  String get botsGroupNotice => 'Group notice';

  @override
  String get botsGroupNoticeHint => 'Every member sees this before speaking';

  @override
  String get botsDeleteGroup => 'Delete group';

  @override
  String get botsDiscardTitle => 'Discard changes?';

  @override
  String get botsKeepEditing => 'Keep editing';

  @override
  String get botsDiscard => 'Discard';

  @override
  String get botsProgress => 'Progress';

  @override
  String get botsGlyphRun => 'Run';

  @override
  String get botsGlyphJobOutput => 'List background jobs';

  @override
  String get botsGlyphJobs => 'Background jobs';

  @override
  String get botsGlyphStopJob => 'Stop background job';

  @override
  String get botsGlyphRead => 'Read';

  @override
  String get botsGlyphImage => 'View image';

  @override
  String get botsGlyphDeliver => 'Present files';

  @override
  String get botsGlyphWrite => 'Write';

  @override
  String get botsGlyphSearch => 'Search';

  @override
  String get botsGlyphFindFiles => 'Find files';

  @override
  String get botsGlyphOpenWeb => 'Open webpage';

  @override
  String get botsGlyphMessageAgent => 'Message subagent';

  @override
  String get botsGlyphInterruptAgent => 'Interrupt subagent';

  @override
  String get botsGlyphListModels => 'List subagent models';

  @override
  String get botsGlyphWorkflow => 'Workflow';

  @override
  String get botsGlyphLoop => 'Loop task';

  @override
  String get botsGlyphSkill => 'Use skill';

  @override
  String get botsGlyphTodo => 'Update to-dos';

  @override
  String get botsGlyphSetGoal => 'Set goal';

  @override
  String get botsGlyphViewGoal => 'View goal';

  @override
  String get botsGlyphUpdateGoal => 'Update goal';

  @override
  String get botsGlyphAsk => 'Ask question';

  @override
  String get botsCommunityEmpty => 'Nothing here yet';

  @override
  String get botsCommunityGroups => 'Chat groups';

  @override
  String get botsCommunity => 'Community';

  @override
  String get botsForum => 'Forum';

  @override
  String get botsForumSubtitle => 'Ask, share, connect';

  @override
  String get botsProjectHome => 'DSH Go project home';

  @override
  String get botsOpenSource => 'Open-source project';

  @override
  String get botsPluginCatalogFailed => 'Couldn’t open the plugin catalog';

  @override
  String get botsTapRetry => 'Tap to retry';

  @override
  String get botsFeaturedPlugins => 'Featured plugins';

  @override
  String get botsPluginSource => 'Plugin info from dshfind';

  @override
  String get botsPromptIdeas => 'Try this';

  @override
  String get botsUpdates => 'What’s new';

  @override
  String get botsLink => 'link';

  @override
  String botsLinkOpenFailed(String host) {
    return 'Couldn’t open $host';
  }

  @override
  String botsYearMonth(int year, String month) {
    String _temp0 = intl.Intl.selectLogic(month, {
      '1': 'Jan',
      '2': 'Feb',
      '3': 'Mar',
      '4': 'Apr',
      '5': 'May',
      '6': 'Jun',
      '7': 'Jul',
      '8': 'Aug',
      '9': 'Sep',
      '10': 'Oct',
      '11': 'Nov',
      '12': 'Dec',
      'other': '$month',
    });
    return '$_temp0 $year';
  }

  @override
  String get botsCopyGroupNumber => 'Copy group number';

  @override
  String botsQrCodeLabel(String title) {
    return '$title QR code';
  }

  @override
  String get botsFiles => 'Files';

  @override
  String get botsEmptyCell => '(empty)';

  @override
  String botsYesterdayTime(String time) {
    return 'Yesterday $time';
  }

  @override
  String get botsOutsideWorkspace => 'Outside the workspace';

  @override
  String get botsNotFolder => 'This isn’t a folder';

  @override
  String get botsChatNotFound => 'Chat not found';

  @override
  String get botsBrowseUnsupported => 'This connection doesn’t support file browsing';

  @override
  String get botsWorkspace => 'Workspace';

  @override
  String get botsSearchFiles => 'Search files';

  @override
  String get botsGoUp => 'Go up';

  @override
  String get botsEmptyFolder => 'Empty folder';

  @override
  String botsFileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count files', one: '1 file');
    return '$_temp0';
  }

  @override
  String botsTruncatedItems(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Only the first $count items are shown',
      one: 'Only the first item is shown',
    );
    return '$_temp0';
  }

  @override
  String get botsMoreActions => 'More actions';

  @override
  String get botsSearchFailed => 'Couldn’t search';

  @override
  String get botsNoResults => 'No results';

  @override
  String get botsCopyPath => 'Copy path';

  @override
  String get botsPetOutsideApp => 'Show outside the app';

  @override
  String get botsPetNotAuthorized => 'Not allowed';

  @override
  String get botsPetDisplayWhen => 'When to show';

  @override
  String get botsPetWhenActive => 'When active';

  @override
  String get botsPetAlways => 'Always';

  @override
  String get botsPetOverlayShows => 'Show in the floating window';

  @override
  String get botsPetOverlayPixel => 'Pixel pet';

  @override
  String get botsPetOverlayCompanion => 'Room companion';

  @override
  String botsPetOverlayCompanionNamed(String name) {
    return '$name from the Room';
  }

  @override
  String get botsPetOverlayNoPack => 'Invite a character in the Companion Room first';

  @override
  String get botsPetOverlayPackBroken => 'The character pack is incomplete. Import it again in the Companion Room';

  @override
  String get botsPetOverlayUnavailable => 'This phone can\'t show your companion right now';

  @override
  String get botsPetOverlayCompanionHint =>
      'Tap to play with her, tap twice to open the chat. Uses more battery than the pixel pet. It stops when the screen is off or the window is hidden';

  @override
  String get botsPetOverlayLoading => 'Bringing your companion out…';

  @override
  String get botsPetOverlayFallback => 'Your companion couldn\'t come out. The pixel pet is filling in';

  @override
  String get botsPetOverlayFraming => 'Framing';

  @override
  String get botsPetOverlayFramingFull => 'Full body';

  @override
  String get botsPetOverlayFramingHalf => 'Half body';

  @override
  String get botsPetOverlayFramingHint => 'Changing the framing reloads the character';

  @override
  String get botsPetSwitchDisabled => 'Switch disabled';

  @override
  String get botsPetRestrictedSettings => 'Allow restricted settings';

  @override
  String get botsPetHiddenToday => 'Hidden for today';

  @override
  String get botsPetRestore => 'Restore';

  @override
  String get botsPetChange => 'Change pet';

  @override
  String get botsPetHideHour => 'Hide for 1 hour';

  @override
  String get botsPetSettings => 'Pet settings';

  @override
  String get botsPetDeepy => 'Deepy';

  @override
  String get botsPetWhaleGirl => 'Whale girl';

  @override
  String get botsPetNone => 'None';

  @override
  String get botsPets => 'Pets';

  @override
  String get botsPetSource => 'From DSH-TUI';

  @override
  String get botsPetImport => 'Import';

  @override
  String get botsPetImportHint =>
      'Bring your own pixel pet: a zip with pack.json and PNG frame sheets; the format is in docs/design/pets.md in the repository. Long-press an imported pet to delete it.';

  @override
  String botsPetImportDone(String name) {
    return '$name is here';
  }

  @override
  String botsPetCodexTitle(String name) {
    return '$name was converted from a Codex pet';
  }

  @override
  String get botsPetCodexBody => 'Most of it carries over as it was. A few things differ:';

  @override
  String get botsPetCodexOk => 'Got it';

  @override
  String get botsPetCodexLoops =>
      'Motions loop until the state changes, instead of settling back to idle after a few rounds as in Codex';

  @override
  String get botsPetCodexRoamLeft => 'Walking left mirrors the walking-right row';

  @override
  String get botsPetCodexDrag => 'Dragging always uses the facing-right row';

  @override
  String get botsPetCodexSleep => 'Sleeping shows the first idle frame';

  @override
  String get botsPetCodexLook => 'The look-in-each-direction cells are not used';

  @override
  String get botsPetCodexWebp => 'The WebP sheet was converted to PNG';

  @override
  String get botsPetCodexCustomTracks => 'Custom motion rows are not tied to any state';

  @override
  String get botsPetCodexFps => 'Frame rates were rounded to whole milliseconds';

  @override
  String get botsPetCodexOneShot => 'Where a play-once motion returns to is decided by DSH';

  @override
  String get botsPetCodexMissingAuthor => 'The pack names no author';

  @override
  String get botsPetCodexMissingLicense => 'The pack names no license';

  @override
  String get botsPetCodexMissingSource => 'The pack names no source';

  @override
  String botsPetImportReplaced(String name) {
    return '$name was updated';
  }

  @override
  String get botsPetImportNotZip => 'That isn\'t a zip file';

  @override
  String get botsPetImportNoPack => 'There\'s no pack.json in the zip';

  @override
  String botsPetImportBadPack(String detail) {
    return 'pack.json has a problem: $detail';
  }

  @override
  String botsPetImportMissingSheet(String name) {
    return 'The zip is missing the sheet $name';
  }

  @override
  String botsPetImportBadSheet(String name) {
    return 'A sheet isn\'t right: $name (a complete PNG, at most 4096 pixels a side, every frame inside it)';
  }

  @override
  String get botsPetImportTooLarge => 'This pet pack is too big';

  @override
  String get botsPetImportStorage => 'Couldn\'t save it on the phone. Try again';

  @override
  String botsPetRemoveTitle(String name) {
    return 'Delete $name?';
  }

  @override
  String get botsPetRemoveBody => 'You can import it again later.';

  @override
  String botsPetRemoveFailed(String name) {
    return 'Couldn\'t delete $name. Try again';
  }

  @override
  String get botsPetSize => 'Size';

  @override
  String get botsPetCustomSize => 'Custom size';

  @override
  String get botsPetQuiet => 'Quiet mode';

  @override
  String get botsPetQuietSubtitle => 'Animations only, no bubbles';

  @override
  String get botsPetShowNow => 'Show now';

  @override
  String botsPetHiddenUntil(String time) {
    return 'Hidden until $time';
  }

  @override
  String get botsKeyEsc => 'Send Esc';

  @override
  String get botsKeyTab => 'Send Tab';

  @override
  String get botsKeyLeft => 'Left';

  @override
  String get botsKeyUp => 'Up';

  @override
  String get botsKeyDown => 'Down';

  @override
  String get botsKeyRight => 'Right';

  @override
  String get botsKeyPipe => 'Pipe';

  @override
  String get botsKeyTilde => 'Tilde';

  @override
  String get botsKeySlash => 'Slash';

  @override
  String get botsKeyDash => 'Hyphen';

  @override
  String get botsTerminal => 'Terminal';

  @override
  String get botsTerminalRename => 'Rename terminal';

  @override
  String get botsTerminalName => 'Terminal name';

  @override
  String get botsTerminalRenameFailed => 'Couldn’t rename';

  @override
  String botsTerminalCloseNamed(String title) {
    return 'Close “$title”?';
  }

  @override
  String get botsTerminalCloseBody => 'Processes inside will end';

  @override
  String get botsTerminalUnsupported => 'Terminal isn’t available on this connection';

  @override
  String get botsTerminalSupportedHosts => 'Available on this phone, an SSH host or a Remote computer';

  @override
  String get botsTerminalOpening => 'Opening terminal…';

  @override
  String get botsTerminalNone => 'No open terminals';

  @override
  String get botsTerminalNew => 'New terminal';

  @override
  String get botsTerminalClose => 'Close terminal';

  @override
  String get botsTerminalChooseShell => 'Choose shell';

  @override
  String get botsTerminalShellFailed => 'Couldn’t load shells';

  @override
  String get botsTerminalReading => 'Reading…';

  @override
  String get botsTerminalDefaultShell => 'Default shell';

  @override
  String get botsTerminalOtherDevice => 'Another device is typing';

  @override
  String get botsTerminalTakeOver => 'Take over';

  @override
  String get botsTerminalStarting => 'Starting…';

  @override
  String get botsTerminalConnecting => 'Connecting…';

  @override
  String get botsTerminalDisconnected => 'Disconnected';

  @override
  String get botsTerminalReconnect => 'Reconnect';

  @override
  String get botsTerminalEnded => 'Ended';

  @override
  String botsTerminalExitCode(int code) {
    return 'Ended · Exit code $code';
  }

  @override
  String get botsTerminalGone => 'This terminal is gone';

  @override
  String get botsTerminalLimit => 'Close unused terminals first';

  @override
  String get botsToolWorkingRun => 'Running commands';

  @override
  String botsToolApprovalRun(String name) {
    return '$name wants to run commands';
  }

  @override
  String get botsToolWorkingRead => 'Viewing files';

  @override
  String botsToolApprovalRead(String name) {
    return '$name wants to view files';
  }

  @override
  String get botsToolWorkingEdit => 'Editing files';

  @override
  String botsToolApprovalEdit(String name) {
    return '$name wants to edit files';
  }

  @override
  String get botsToolWorkingSearch => 'Searching the web';

  @override
  String botsToolApprovalSearch(String name) {
    return '$name wants to search the web';
  }

  @override
  String get botsToolWorkingBrowse => 'Browsing the web';

  @override
  String botsToolApprovalBrowse(String name) {
    return '$name wants to browse the web';
  }

  @override
  String get botsToolWorkingMessage => 'Contacting other bots';

  @override
  String botsToolApprovalMessage(String name) {
    return '$name wants to contact other bots';
  }

  @override
  String get botsToolWorkingGroup => 'Chatting with the group';

  @override
  String botsToolApprovalGroup(String name) {
    return '$name wants to chat with the group';
  }

  @override
  String get botsToolWorkingMemory => 'Organizing memories';

  @override
  String botsToolApprovalMemory(String name) {
    return '$name wants to organize memories';
  }

  @override
  String get botsToolWorkingRecall => 'Looking through records';

  @override
  String botsToolApprovalRecall(String name) {
    return '$name wants to look through records';
  }

  @override
  String get botsToolWorkingTeam => 'Organizing the team';

  @override
  String botsToolApprovalTeam(String name) {
    return '$name wants to organize the team';
  }

  @override
  String get botsToolWorkingAsk => 'Preparing to ask you';

  @override
  String botsToolApprovalAsk(String name) {
    return '$name wants to ask you something';
  }

  @override
  String get botsToolWorkingWork => 'Working';

  @override
  String botsToolApprovalWork(String name) {
    return '$name wants to work';
  }

  @override
  String get botsEveryone => 'Everyone';

  @override
  String get botsActivelyRunning => 'Running';

  @override
  String get botsListSeparator => ', ';

  @override
  String get botsNameSeparator => ', ';

  @override
  String get botsGlyphSubagent => 'Subagent';

  @override
  String get botsGlyphWebSearch => 'Web search';

  @override
  String botsSenderPreview(String name, String preview) {
    return '$name: $preview';
  }

  @override
  String botsAgentSemantics(String title, String state) {
    return '$title, $state';
  }

  @override
  String botsViewMetric(Object label, Object value) {
    return '$label: $value';
  }

  @override
  String get botsEffortXhigh => 'Extra high';

  @override
  String get botsRelayLimit => 'Bot relay limit';

  @override
  String get botsRelayLimitHint =>
      'Pause after this many Bot-to-Bot calls since your last message. Enter a whole number from 1 to 200, or leave empty for the default.';

  @override
  String botsRelayLimitDefault(int count) {
    return 'Default: $count';
  }

  @override
  String get botsRelayLimitInvalid => 'Enter a whole number from 1 to 200.';

  @override
  String get botsRelayLimitRestore => 'Restore default';

  @override
  String get botsRelayLimitConnectionChanged => 'The connection changed. Close this sheet and open it again.';

  @override
  String get botsMobileUnsupportedTitle => 'DS Bot isn\'t on mobile yet';

  @override
  String get botsMobileApiRequired => 'Use it in DSH Web for now';

  @override
  String get botsMobileApiMissing => 'Not on mobile yet. Use it in DSH Web for now';

  @override
  String get botsCreationConnectionChanged => 'The connection changed. Reopen this form to create on the current host.';

  @override
  String get brandXiaomi => 'Xiaomi / Redmi';

  @override
  String get brandHuawei => 'Huawei';

  @override
  String get brandHonor => 'Honor';

  @override
  String get brandOppo => 'OPPO / OnePlus / realme';

  @override
  String get brandSamsung => 'Samsung';

  @override
  String get brandVivoOs => 'vivo / iQOO (OriginOS)';

  @override
  String get brandXiaomiOs => 'Xiaomi / Redmi (HyperOS, MIUI)';

  @override
  String get brandHuaweiOs => 'Huawei / Honor (HarmonyOS, MagicOS)';

  @override
  String get brandOppoOs => 'OPPO / OnePlus / realme (ColorOS)';

  @override
  String get brandSamsungOs => 'Samsung (One UI)';

  @override
  String get brandZhihu => 'Zhihu';

  @override
  String get catalogCurrentChat => 'Current chat';

  @override
  String get catalogChatDetails => 'Chat details';

  @override
  String get catalogChatDetailsSummary => 'Trajectory, changes and progress';

  @override
  String get catalogArtifacts => 'Output files';

  @override
  String get catalogArtifactsSummary => 'Preview, share and save';

  @override
  String get catalogFiles => 'Files';

  @override
  String get catalogFilesSummary => 'Browse and preview';

  @override
  String get catalogTerminal => 'Terminal';

  @override
  String get catalogTerminalSummary => 'Workspace terminal';

  @override
  String get catalogExport => 'Export chat log';

  @override
  String get catalogExportSummary => 'Save as ZIP';

  @override
  String get catalogJobs => 'Background jobs';

  @override
  String get catalogJobsSummary => 'View output or stop jobs';

  @override
  String get catalogPlanGoal => 'Plan and goal';

  @override
  String get catalogPlanGoalSummary => 'Goals, plans and to-dos';

  @override
  String get catalogSkills => 'Skills';

  @override
  String get catalogSkillsSummary => 'Use skills in chats';

  @override
  String get catalogSubagents => 'Subagents';

  @override
  String get catalogSubagentsSummary => 'Lineage and status; tap to chat';

  @override
  String get catalogReference => 'Reference files and chats';

  @override
  String get catalogReferenceSummary => 'Use @ in the composer';

  @override
  String get catalogAutomationSection => 'Automation';

  @override
  String get catalogSchedules => 'Automations';

  @override
  String get catalogSchedulesSummary => 'Scheduled and recurring tasks';

  @override
  String get catalogAgentModelsSection => 'Agents and models';

  @override
  String get catalogPermission => 'Permissions';

  @override
  String get catalogPermissionSummary => 'Choose when to ask for approval';

  @override
  String get catalogAgentPresets => 'Agent presets';

  @override
  String get catalogAgentPresetsSummary => 'How new chats work';

  @override
  String get catalogModels => 'Models';

  @override
  String get catalogModelsSummary => 'Subscriptions and custom providers';

  @override
  String get catalogSubagentSettings => 'Subagent settings';

  @override
  String get catalogSubagentSettingsSummary => 'Depth, parallelism and models';

  @override
  String get catalogAgentLoop => 'Agent loop';

  @override
  String get catalogAgentLoopSummary => 'Parallel tool call limit';

  @override
  String get catalogShellSettings => 'Command execution';

  @override
  String get catalogShellSettingsSummary => 'Timeouts and output limits';

  @override
  String get catalogWebSearch => 'Web search';

  @override
  String get catalogWebSearchSummary => 'Search service and budget';

  @override
  String get catalogPlugins => 'Plugins';

  @override
  String get catalogPluginsSummary => 'Installed plugins and markets';

  @override
  String get catalogPluginInventory => 'Plugin inventory';

  @override
  String get catalogPluginInventorySummary => 'All loaded plugins';

  @override
  String get catalogCordisSummary => 'Dynamic panels from plugins';

  @override
  String get catalogAgentTeam => 'Agent team';

  @override
  String get catalogAgentTeamSummary => 'Members, task board and messages';

  @override
  String get catalogCotTranslation => 'Translate thinking';

  @override
  String get catalogCotTranslationSummary => 'Expand thinking, then tap “Translate”';

  @override
  String get catalogVoiceInput => 'Voice input';

  @override
  String get catalogVoiceInputSummary => 'Microphone in the composer';

  @override
  String get catalogCommunitySharingSection => 'Community and sharing';

  @override
  String get catalogForum => 'Forum';

  @override
  String get catalogForumSummary => 'Ask, share and meet others';

  @override
  String get catalogCommunity => 'Community';

  @override
  String get catalogCommunitySummary => 'Highlights and group chats';

  @override
  String get catalogBotSummary => 'Bot teams and group chats';

  @override
  String get catalogShareProfile => 'Share configuration';

  @override
  String get catalogShareProfileSummary => 'Plugins, settings and skills';

  @override
  String get catalogHostsSettingsSection => 'Hosts and settings';

  @override
  String get catalogSearch => 'Search chats';

  @override
  String get catalogSearchSummary => 'Find by title or content';

  @override
  String get catalogNotifications => 'Notifications';

  @override
  String get catalogNotificationsSummary => 'Completion and approval alerts';

  @override
  String get catalogWorkspaces => 'Workspaces';

  @override
  String get catalogWorkspacesSummary => 'Add and switch folders';

  @override
  String get catalogGeneral => 'General';

  @override
  String get catalogGeneralSummary => 'Display, sending and log uploads';

  @override
  String get catalogAccount => 'Account';

  @override
  String get catalogAccountSummary => 'Sign in, balance and top-ups';

  @override
  String get catalogRemoteSummary => 'Connect to a computer or server';

  @override
  String get catalogPhoneControl => 'Phone control';

  @override
  String get catalogPhoneControlSummary => 'See your screen and tap for you';

  @override
  String get catalogEngine => 'Local engine';

  @override
  String get catalogEngineSummary => 'Engine status and logs on this phone';

  @override
  String get catalogDiagnostics => 'Diagnostics';

  @override
  String get catalogDiagnosticsSummary => 'Export diagnostics bundle';

  @override
  String get catalogWebSummary => 'Official DSH interface';

  @override
  String get catalogPluginPanel => 'Plugin panel';

  @override
  String get catalogHostPluginMissing => 'This host doesn’t have this plugin';

  @override
  String get catalogAllFeatures => 'All features';

  @override
  String get catalogAllFeaturesSubtitle => 'DSH Web features, all here';

  @override
  String get catalogOpenChatFirst => 'Open a chat first';

  @override
  String get catalogNoOpenChat => 'No chat open';

  @override
  String get catalogOpenChat => 'Currently open chat';

  @override
  String get catalogOpenOrCreateChat => 'Open or start a chat first';

  @override
  String get catalogCordisHostClient => 'Backend and interface';

  @override
  String get catalogCordisHostOnly => 'Backend only';

  @override
  String get catalogCordisClientOnly => 'Interface only';

  @override
  String get catalogCordisPluginGone => 'This plugin is gone';

  @override
  String get catalogCordisStopFailed => 'Couldn’t stop';

  @override
  String get catalogCordisRemoveOne => 'This will stop and delete it.';

  @override
  String get catalogCordisRemove => 'Remove';

  @override
  String get catalogCordisRemoved => 'Removed';

  @override
  String get catalogCordisRemoveFailed => 'Couldn’t remove';

  @override
  String get catalogCordisChat => 'Chat';

  @override
  String get catalogCordisMakeup => 'Components';

  @override
  String get catalogCordisStopping => 'Stopping…';

  @override
  String get catalogCordisRemoving => 'Removing…';

  @override
  String get catalogSeatGone => 'Plugin no longer available';

  @override
  String catalogCordisRemoveTitle(String name) {
    return 'Remove “$name”?';
  }

  @override
  String catalogCordisRemoveVersions(int versions) {
    String _temp0 = intl.Intl.pluralLogic(
      versions,
      locale: localeName,
      other: 'This will stop it and delete all $versions versions.',
      one: 'This will stop it and delete 1 version.',
    );
    return '$_temp0';
  }

  @override
  String catalogCordisVersionCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count versions', one: '1 version');
    return '$_temp0';
  }

  @override
  String get catalogToolsSection => 'Tools';

  @override
  String get catalogAllSettings => 'All settings';

  @override
  String get diagnosticsForAi => 'Let the AI read diagnostics';

  @override
  String get diagnosticsForAiHint => 'Write the snapshot where the engine can read it';

  @override
  String get diagnosticsForAiDone => 'Written — ask the AI to \"check the diagnostics\"';

  @override
  String get diagnosticsForAiFailed => 'Not written: the local runtime is not installed';

  @override
  String get chatBackgroundTaskNotice => 'Background task notice';

  @override
  String get chatBackgroundTaskMessage => 'Background task message';

  @override
  String get chatDeclineQuestion => 'Skip';

  @override
  String get chatChats => 'Chats';

  @override
  String get chatViewChatDetails => 'View chat details';

  @override
  String get chatUnsent => 'Not sent';

  @override
  String get chatFailedSubmission => 'Failed · Input kept';

  @override
  String get chatEditFailedSubmission => 'Edit and resend';

  @override
  String get chatErrReasoningEffortUnsupported =>
      'This model does not support the selected reasoning effort. Change the effort or model.';

  @override
  String get chatSteerNextStep => 'Steer · Next step';

  @override
  String get chatQueuedAfterTurn => 'Queued · Next turn';

  @override
  String get chatSteering => 'Steering';

  @override
  String get chatQueued => 'Queued';

  @override
  String get chatStoppingTurn => 'Stopping this turn';

  @override
  String get chatSending => 'Sending';

  @override
  String get chatSendNow => 'Send now';

  @override
  String get chatSwitchToSteer => 'Steer instead';

  @override
  String get chatWithdraw => 'Undo';

  @override
  String get chatContinuedInNewChat => 'Continued in a new chat';

  @override
  String get chatReadOriginalImageFailed => 'Couldn’t read the original image. Try again.';

  @override
  String get chatRegenerateFailed => 'Couldn’t regenerate';

  @override
  String get chatRegeneratedInNewChat => 'Regenerated in a new chat';

  @override
  String get chatOpenedInNewChatReattach => 'Opened in a new chat. Add attachments again.';

  @override
  String get chatOpenedInNewChat => 'Opened in a new chat';

  @override
  String chatForkQueuedLeft(String message, int left) {
    String _temp0 = intl.Intl.pluralLogic(
      left,
      locale: localeName,
      other: '$message ($left queued messages stayed behind)',
      one: '$message (1 queued message stayed behind)',
    );
    return '$_temp0';
  }

  @override
  String get chatReturnToOriginal => 'Back to original chat';

  @override
  String chatWaitingCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items need approval',
      one: '1 item needs approval',
    );
    return '$_temp0';
  }

  @override
  String chatWaitingBackToBottom(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items need approval, back to bottom',
      one: '1 item needs approval, back to bottom',
    );
    return '$_temp0';
  }

  @override
  String get chatBackToBottom => 'Back to bottom';

  @override
  String get chatCreateFailed => 'Couldn’t create chat';

  @override
  String get chatSendMode => 'Send mode';

  @override
  String get chatSteer => 'Steer';

  @override
  String get chatSteerHint => 'The AI sees it next step, without interrupting';

  @override
  String get chatInterruptAndSend => 'Interrupt and send';

  @override
  String get chatInterruptHint => 'Stop the current task and handle this first';

  @override
  String get chatQueue => 'Queue';

  @override
  String get chatQueueHint => 'Send after this turn';

  @override
  String get chatWithdrawnEditable => 'Undone. Edit and send again.';

  @override
  String get chatWithdrawn => 'Undone';

  @override
  String chatAttachmentLimit(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Up to $count attachments per message',
      one: 'Up to 1 attachment per message',
    );
    return '$_temp0';
  }

  @override
  String get chatAttachmentPermission => 'Permission denied. Turn it on in system settings.';

  @override
  String get chatOpenAttachmentFailed => 'Couldn’t open attachment';

  @override
  String get chatReadFailed => 'Couldn’t read';

  @override
  String get chatReadImageFailed => 'Couldn’t read image';

  @override
  String get chatOpenChatFirst => 'Open a chat first';

  @override
  String get chatTurnCompleted => 'This turn is complete';

  @override
  String get chatTurnError => 'Something went wrong this turn';

  @override
  String get chatAnswerHint => 'Type your answer…';

  @override
  String get chatAnswerMode => 'Send text as an answer';

  @override
  String get chatMessageMode => 'Send a new message';

  @override
  String get chatQuestionAnswered => 'Answered';

  @override
  String get chatStarting => 'Starting';

  @override
  String get chatConnecting => 'Connecting';

  @override
  String get chatDisconnected => 'Disconnected';

  @override
  String get chatReconnecting => 'Reconnecting';

  @override
  String get chatGenerating => 'Generating';

  @override
  String get chatGoToSettings => 'Open settings';

  @override
  String get chatListeningEllipsis => 'Listening…';

  @override
  String get chatTranscribingEllipsis => 'Transcribing…';

  @override
  String get chatConnectToSend => 'Connect to the engine to send';

  @override
  String get chatGeneratingSteerHint => 'Generating · Type to steer';

  @override
  String get chatComposerHint => 'Message DSH…';

  @override
  String get chatStopGenerating => 'Stop generating';

  @override
  String get chatVoiceInput => 'Voice input';

  @override
  String get chatStopVoiceInput => 'Stop voice input';

  @override
  String get chatGoal => 'Goal';

  @override
  String get chatGoalActions => 'Goal actions';

  @override
  String get chatGoalBlocked => 'Blocked';

  @override
  String chatGoalRoundLimit(int rounds, int max) {
    return 'Round $rounds / $max';
  }

  @override
  String chatGoalRound(int rounds) {
    return 'Round $rounds';
  }

  @override
  String get chatEditGoal => 'Edit goal';

  @override
  String get chatPauseGoal => 'Pause';

  @override
  String get chatPauseGoalHint => 'Pause automatic progress';

  @override
  String get chatResumeGoal => 'Resume';

  @override
  String get chatResumeGoalHint => 'Resume automatic progress';

  @override
  String get chatClearGoal => 'Clear goal';

  @override
  String get chatGoalHint => 'What do you want to achieve?';

  @override
  String get chatClearGoalTitle => 'Clear goal?';

  @override
  String chatTodoCurrent(String content) {
    return 'Working on: $content';
  }

  @override
  String chatTodoNext(String content) {
    return 'Next: $content';
  }

  @override
  String get chatTodoAllDone => 'All done';

  @override
  String chatTodoSemantics(String count, String label) {
    return 'To-do $count, $label';
  }

  @override
  String get chatCollapseTodos => 'Collapse list';

  @override
  String get chatExpandTodos => 'Expand list';

  @override
  String chatDockFolded(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count status bars stacked',
      one: '1 status bar stacked',
    );
    return '$_temp0';
  }

  @override
  String get chatDockSpread => 'Expand';

  @override
  String get chatDockFold => 'Fold the status bars';

  @override
  String get chatDockNext => 'Next card';

  @override
  String get chatDockPrevious => 'Previous card';

  @override
  String get chatTodoNotStarted => 'Not started';

  @override
  String get chatFile => 'File';

  @override
  String get chatFolder => 'Folder';

  @override
  String get chatChat => 'Chat';

  @override
  String get chatSubagent => 'Subagent';

  @override
  String get chatRecent => 'Recent';

  @override
  String get chatMentionSearching => 'Searching…';

  @override
  String get chatMentionNoFiles => 'No matching files';

  @override
  String get chatMentionNoMatches => 'No matching files or chats';

  @override
  String get chatQuote => 'Quote';

  @override
  String get chatOpenFolder => 'Open folder';

  @override
  String get chatJustNow => 'Just now';

  @override
  String chatMentionAgeMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count min', one: '1 min');
    return '$_temp0';
  }

  @override
  String chatMentionAgeHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count h', one: '1 h');
    return '$_temp0';
  }

  @override
  String chatMentionAgeDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count days', one: '1 day');
    return '$_temp0';
  }

  @override
  String chatMentionAgeMonths(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count months', one: '1 month');
    return '$_temp0';
  }

  @override
  String chatMentionAgeYears(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count years', one: '1 year');
    return '$_temp0';
  }

  @override
  String get chatMermaidChart => 'Mermaid chart';

  @override
  String get chatPreview => 'Preview';

  @override
  String get chatUnwrapLines => 'Unwrap lines';

  @override
  String get chatWrapLines => 'Wrap lines';

  @override
  String get chatAlertNote => 'Note';

  @override
  String get chatAlertTip => 'Tip';

  @override
  String get chatAlertImportant => 'Important';

  @override
  String get chatAlertWarning => 'Warning';

  @override
  String get chatAlertCaution => 'Caution';

  @override
  String get chatImage => 'Image';

  @override
  String get chatImageNotFound => 'Image not found';

  @override
  String get chatImageOffline => 'Not connected to DSH';

  @override
  String get chatImageTooLarge => 'Image too large';

  @override
  String get chatImageReadFailed => 'Can’t read file';

  @override
  String get chatImageDisplayFailed => 'Can’t display';

  @override
  String get chatImageTapToView => 'Tap to view';

  @override
  String get chatImageTapToRetry => 'Tap to retry';

  @override
  String get chatImageUnsupportedAddress => 'Unsupported address';

  @override
  String get chatMermaidNeedsNetwork => 'Needs internet';

  @override
  String get chatMermaidSyntaxError => 'Invalid chart syntax';

  @override
  String get chatChartPreview => 'Chart preview';

  @override
  String get chatCopyCode => 'Copy code';

  @override
  String get chatChartClosed => 'Chart closed';

  @override
  String get chatVoiceMicrophoneFailed => 'Couldn’t open microphone';

  @override
  String get chatVoicePermissionOff => 'Microphone access is off';

  @override
  String get chatVoicePermissionNeeded => 'Voice input needs microphone access';

  @override
  String get chatVoiceUnavailable => 'Speech recognition isn’t available on this phone';

  @override
  String get chatVoiceNotHeard => 'Didn’t catch that. Try again.';

  @override
  String get chatVoiceTranscriptionFailed => 'Couldn’t transcribe this recording';

  @override
  String get chatVoiceNetworkFailed => 'Couldn’t transcribe. Check your connection.';

  @override
  String get chatVoiceLanguageUnsupported => 'This language isn’t supported yet';

  @override
  String get chatVoiceMicrophoneBusy => 'Microphone is in use';

  @override
  String get chatVoiceBusy => 'Speech recognition is busy. Try again later.';

  @override
  String get chatVoiceRecognitionFailed => 'Speech recognition failed';

  @override
  String get chatListening => 'Listening';

  @override
  String get chatTranscribing => 'Transcribing';

  @override
  String get chatCancelVoiceInput => 'Cancel voice input';

  @override
  String get chatViewTurnTrace => 'View turn trajectory';

  @override
  String chatTokensPerSecond(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'About $count tokens/s',
      one: 'About 1 token/s',
    );
    return '$_temp0';
  }

  @override
  String get chatNoTokensStreaming => 'No text streaming';

  @override
  String chatCurrentStep(String step) {
    return 'This step $step';
  }

  @override
  String chatTodoProgress(int done, int total) {
    return 'To-do progress $done/$total';
  }

  @override
  String chatProgress(int done, int total) {
    return 'Progress $done/$total';
  }

  @override
  String get chatApproveCommand => 'Allow this command?';

  @override
  String get chatApproveWrite => 'Allow writing this file?';

  @override
  String get chatApproveEdit => 'Allow editing this file?';

  @override
  String get chatApproveWebpage => 'Allow opening this page?';

  @override
  String get chatApproveSearch => 'Allow web search?';

  @override
  String chatApproveTool(String name) {
    return 'Allow “$name”?';
  }

  @override
  String get chatDecline => 'Decline';

  @override
  String get chatAllowOnce => 'Allow once';

  @override
  String get chatAllowForChat => 'Allow for chat';

  @override
  String get chatSaveToDownloads => 'Save to Downloads';

  @override
  String get chatCopyPath => 'Copy path';

  @override
  String get chatOpenInDefaultApp => 'Open in default app';

  @override
  String get chatDownloadsFolderHint => 'Downloads/DSH-Go folder';

  @override
  String chatSavedToDownloadsPath(String path) {
    return 'Saved to Downloads/$path';
  }

  @override
  String chatSavedToPath(String path) {
    return 'Saved to $path';
  }

  @override
  String chatDeliveredFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delivered $count files',
      one: 'Delivered 1 file',
    );
    return '$_temp0';
  }

  @override
  String chatGeneratedFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Generated $count files',
      one: 'Generated 1 file',
    );
    return '$_temp0';
  }

  @override
  String chatAllFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'All $count files', one: '1 file in total');
    return '$_temp0';
  }

  @override
  String get chatCollapseFileList => 'Collapse file list';

  @override
  String chatExpandAllFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Expand all $count files',
      one: 'Expand 1 file',
    );
    return '$_temp0';
  }

  @override
  String get chatDownloading => 'Downloading…';

  @override
  String chatDownloadingPercent(int percent) {
    return 'Downloading… $percent%';
  }

  @override
  String get chatOpening => 'Opening…';

  @override
  String get chatSavingToDownloads => 'Saving to Downloads…';

  @override
  String get chatOpenInPhoneApp => 'Open in an app on this phone';

  @override
  String get chatMoreActions => 'More actions';

  @override
  String get chatAlreadyInDownloads => 'Already in Downloads on this phone';

  @override
  String get chatArtifactCopyPathOnly => 'This connection can’t read files. You can copy the path.';

  @override
  String get chatReplying => 'Replying';

  @override
  String get chatInterrupted => 'Interrupted';

  @override
  String get chatGallery => 'Photos';

  @override
  String get chatTakePhoto => 'Take photo';

  @override
  String get chatAddAttachment => 'Add image or file';

  @override
  String chatRemoveAttachment(String name) {
    return 'Remove “$name”';
  }

  @override
  String get chatAutoApproveCommands => 'Allow commands automatically';

  @override
  String get chatAutoApproving => 'Auto-approving';

  @override
  String chatViewMoreChanges(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'View changes, $count more files',
      one: 'View changes, 1 more file',
    );
    return '$_temp0';
  }

  @override
  String get chatViewChanges => 'View changes';

  @override
  String chatChangedFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Changed $count files',
      one: 'Changed 1 file',
    );
    return '$_temp0';
  }

  @override
  String chatMoreFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count more files', one: '1 more file');
    return '$_temp0';
  }

  @override
  String chatFileChangeSemantics(String path, int added, int removed) {
    String _temp0 = intl.Intl.pluralLogic(added, locale: localeName, other: '$added lines added', one: '1 line added');
    String _temp1 = intl.Intl.pluralLogic(
      removed,
      locale: localeName,
      other: '$removed lines deleted',
      one: '1 line deleted',
    );
    return '$path, $_temp0, $_temp1';
  }

  @override
  String get chatNewFileSuffix => '  New';

  @override
  String get chatPathCopied => 'Path copied';

  @override
  String chatCommandCompacted(int count, String tokens) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Compacted $count history items (~$tokens tokens)',
      one: 'Compacted 1 history item (~$tokens tokens)',
    );
    return '$_temp0';
  }

  @override
  String chatCommandPermissionChanged(String name) {
    return 'Switched to $name';
  }

  @override
  String chatCommandCurrentPermission(String name) {
    return 'Current permissions: $name';
  }

  @override
  String get chatCommandUnknownPermission => 'No such permission preset';

  @override
  String get chatCommandFeedbackRequired => 'Add feedback before sending';

  @override
  String get chatCommandFeedbackSubmitted => 'Feedback submitted';

  @override
  String get chatCommandNothingToCompact => 'Nothing to compact yet';

  @override
  String get chatCommandCompactionCancelled => 'Compaction cancelled';

  @override
  String get chatCommandCompactionBusy => 'Busy. Try compacting later.';

  @override
  String get chatCommandCompactedSaveFailed => 'Compacted, but couldn’t save';

  @override
  String get chatCommandCompactUsage => '/compact takes no arguments';

  @override
  String get chatCommandHistoryChanged => 'The chat changed. Try again.';

  @override
  String get chatCommandCompactionFailed => 'Couldn’t compact. Try again.';

  @override
  String get chatCommandCompactionIncomplete => 'Compaction incomplete. Check the chat.';

  @override
  String get chatCommandPlanEnabled => 'Plan mode on';

  @override
  String get chatCommandPlanEnabling => 'Plan mode starts next step';

  @override
  String get chatCommandPlanDisabled => 'Plan mode off';

  @override
  String get chatCommandPlanDisabling => 'Plan mode ends next step';

  @override
  String get chatCommandPlanCancelled => 'Plan mode entry cancelled';

  @override
  String get chatCommandPlanInactive => 'Plan mode is off';

  @override
  String get chatCommandPlanNoAttachments => 'Can’t attach files when leaving plan mode';

  @override
  String get chatCommandNoGoal => 'No goal yet';

  @override
  String get chatCommandGoalRequired => 'Add a new goal before sending';

  @override
  String get chatCommandGoalAttachments => 'Send attachments with a goal';

  @override
  String get chatCommandGoalCleared => 'Goal cleared';

  @override
  String get chatCommandGoalInvalid => 'Can’t do that now. Check the goal.';

  @override
  String get chatCommandGoalExists => 'A goal exists. Edit or clear it first.';

  @override
  String get chatCommandGoalCreated => 'Goal set';

  @override
  String get chatCommandGoalUpdated => 'Goal updated';

  @override
  String get chatCommandGoalPaused => 'Goal paused';

  @override
  String get chatCommandGoalResumed => 'Goal resumed';

  @override
  String get chatCommandCurrentGoal => 'Current goal';

  @override
  String get chatCommandGoalBlocked => 'Needs attention';

  @override
  String chatCommandGoalSummary(String title, String objective, String status, int rounds, int max) {
    return '$title\n$objective\n$status · Round $rounds/$max';
  }

  @override
  String get chatCommandFailed => 'Command failed';

  @override
  String get chatImageStorageDenied => 'Couldn’t save. Storage access is off.';

  @override
  String get chatImageCannotSave => 'Can’t save this image';

  @override
  String get chatImageDownloadFailed => 'Couldn’t download image. Try again.';

  @override
  String get chatImageSaveFailed => 'Couldn’t save. Try again.';

  @override
  String get chatImageSavedToPhotos => 'Saved to Photos';

  @override
  String get chatShareFailed => 'Couldn’t open sharing';

  @override
  String get chatSubmit => 'Submit';

  @override
  String get chatSelectText => 'Select text';

  @override
  String get chatRegenerate => 'Regenerate';

  @override
  String get chatBranchFromHere => 'Branch here';

  @override
  String get chatEditAndResend => 'Edit and resend';

  @override
  String get chatRegenerateHint => 'Regenerate in a new chat. The original stays as is.';

  @override
  String get chatBranchHint => 'Continue in a new chat. The original stays as is.';

  @override
  String get chatEditResendHint => 'Rewrite in a new chat. Reattach images and files; the original stays as is.';

  @override
  String get chatSaveToPhotos => 'Save to Photos';

  @override
  String get chatCopyAll => 'Copy all';

  @override
  String get chatRequestRetrying => 'Request failed, retrying';

  @override
  String chatRequestRetryAttempt(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Request failed, retrying (attempt $count)',
      one: 'Request failed, retrying (attempt 1)',
    );
    return '$_temp0';
  }

  @override
  String chatRequestRetryLimit(int count, int max) {
    return 'Request failed, retrying ($count/$max)';
  }

  @override
  String chatSubscriptionExpired(String name) {
    return '$name sign-in expired';
  }

  @override
  String get chatProviderKeyMissing => 'No API key for this provider yet';

  @override
  String get chatDeepSeekKeyMissing => 'No DeepSeek API key yet';

  @override
  String get chatOutputLimitReached => 'Output limit reached';

  @override
  String get chatTurnBlocked => 'This turn was blocked';

  @override
  String get chatTurnEngineRestarted => 'The engine restarted, interrupting this turn';

  @override
  String get chatSignInAgain => 'Sign in again';

  @override
  String chatQuestionsTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count questions for you',
      one: '1 question for you',
    );
    return '$_temp0';
  }

  @override
  String get chatOneQuestion => 'A question for you';

  @override
  String get chatMultipleChoices => 'Select any';

  @override
  String get chatCustomAnswer => 'Other answer';

  @override
  String get chatCustomAnswerHint => 'Type your answer';

  @override
  String chatQuoteSemantics(String text) {
    return 'Quote: $text';
  }

  @override
  String get chatRemoveQuote => 'Remove quote';

  @override
  String get chatReadOnlySubagent => 'One-shot subagent · View only';

  @override
  String get chatThinkingActive => 'Thinking';

  @override
  String get chatThinking => 'Thinking';

  @override
  String get chatTranslate => 'Translate';

  @override
  String get chatTranslationUnavailable => 'Translation unavailable';

  @override
  String get chatViewOriginal => 'View original';

  @override
  String get chatViewTranslation => 'View translation';

  @override
  String get chatTranslating => 'Translating';

  @override
  String chatToolFailures(String label, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$label, $count failed',
      one: '$label, 1 failed',
    );
    return '$_temp0';
  }

  @override
  String get chatToolNeedsApproval => 'Approval needed to run';

  @override
  String get chatCommand => 'Command';

  @override
  String chatToolLineRange(int first, int last) {
    return ' · Lines $first⁠–⁠$last';
  }

  @override
  String get chatParameters => 'Parameters';

  @override
  String get chatOutput => 'Output';

  @override
  String get chatResult => 'Result';

  @override
  String get chatError => 'Error';

  @override
  String get chatChanges => 'Changes';

  @override
  String get chatContent => 'Content';

  @override
  String get chatNoOutput => 'No output';

  @override
  String get chatToolDeclined => 'This tool call was declined';

  @override
  String get chatToolRunning => 'Running…';

  @override
  String get chatNoDetails => 'No details yet';

  @override
  String chatOutputHiddenLines(int count, String shown) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$shown lines hidden',
      one: '1 line hidden',
    );
    return '$_temp0';
  }

  @override
  String chatOutputHiddenChars(String count) {
    return '$count characters hidden';
  }

  @override
  String chatOutputSummary(int count, String lines, String chars) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$lines lines', one: '1 line');
    return '$_temp0 · $chars characters';
  }

  @override
  String get chatOutputViewAll => 'View all';

  @override
  String get chatOutputCopyAll => 'Copy all';

  @override
  String get chatOutputCopied => 'Copied the full text';

  @override
  String get chatOutputToEnd => 'Jump to end';

  @override
  String get chatOutputToStart => 'Back to top';

  @override
  String get chatErrApiKey => 'API key is invalid or expired';

  @override
  String get chatErrBalance => 'Insufficient balance';

  @override
  String get chatErrAccountQuota => 'Account quota used up';

  @override
  String get chatErrRateLimit => 'Too many requests. Try again later.';

  @override
  String get chatErrContextLength => 'Chat too long. If /compact fails, try a new chat or model.';

  @override
  String get chatErrModelUnavailable => 'Model service temporarily unavailable';

  @override
  String get chatErrModelTimeout => 'Model response timed out';

  @override
  String get chatErrModelConnection => 'Couldn’t reach the model service';

  @override
  String get chatErrModelEmpty => 'The model returned no content';

  @override
  String get chatErrEngineOutdated => 'This model needs a newer engine';

  @override
  String get chatErrModelUnsupported => 'This model isn’t available';

  @override
  String get chatSwitchModel => 'Switch model';

  @override
  String get chatErrTurn => 'Something went wrong this turn';

  @override
  String chatTurnSteps(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count steps', one: '1 step');
    return '$_temp0';
  }

  @override
  String chatTurnFootnoteSemantics(String summary) {
    return 'This turn: $summary, view turn trajectory';
  }

  @override
  String chatTurnToolCalls(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count tool calls', one: '1 tool call');
    return '$_temp0';
  }

  @override
  String chatTurnMessages(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count messages', one: '1 message');
    return '$_temp0';
  }

  @override
  String chatTurnThoughts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count thinking blocks',
      one: '1 thinking block',
    );
    return '$_temp0';
  }

  @override
  String get chatMe => 'Me';

  @override
  String chatGoalSemantics(String objective) {
    return 'Goal, $objective';
  }

  @override
  String chatGoalStateSemantics(String objective, String state) {
    return 'Goal, $objective, $state';
  }

  @override
  String chatTodoItemSemantics(String content, String state) {
    return '$content, $state';
  }

  @override
  String chatMentionSemantics(String kind, String label) {
    return '$kind: $label';
  }

  @override
  String chatArtifactSemantics(String name, String description) {
    return '$name, $description';
  }

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonClose => 'Close';

  @override
  String get commonCopied => 'Copied';

  @override
  String get commonSave => 'Save';

  @override
  String get commonSettings => 'Settings';

  @override
  String get commonBack => 'Back';

  @override
  String get commonCopy => 'Copy';

  @override
  String get commonDone => 'Done';

  @override
  String get commonDelete => 'Delete';

  @override
  String get commonInstall => 'Install';

  @override
  String get commonShare => 'Share';

  @override
  String get commonAdd => 'Add';

  @override
  String get commonEdit => 'Edit';

  @override
  String get commonClear => 'Clear';

  @override
  String get commonCollapse => 'Show less';

  @override
  String get commonEnable => 'Enable';

  @override
  String get commonOpen => 'Open';

  @override
  String get commonDetails => 'Details';

  @override
  String get commonMore => 'More';

  @override
  String get commonCreate => 'Create';

  @override
  String get commonSend => 'Send';

  @override
  String get commonStop => 'Stop';

  @override
  String get commonPaste => 'Paste';

  @override
  String get commonHide => 'Hide';

  @override
  String get commonLater => 'Later';

  @override
  String get commonConfirm => 'Confirm';

  @override
  String get commonRename => 'Rename';

  @override
  String get commonContinue => 'Continue';

  @override
  String get commonNotSet => 'Not set';

  @override
  String get commonDefault => 'Default';

  @override
  String get commonSaved => 'Saved';

  @override
  String get commonSaveFailed => 'Couldn’t save';

  @override
  String get commonSaveFailedRetry => 'Couldn’t save. Try again.';

  @override
  String get commonFailedTryAgain => 'Something went wrong. Try again.';

  @override
  String get commonEngineUnreachable => 'Can’t reach the engine';

  @override
  String get commonStorageFull => 'Not enough storage';

  @override
  String get commonConnectionFailed => 'Couldn’t connect';

  @override
  String get commonCopyLink => 'Copy link';

  @override
  String get commonOpenWith => 'Open in another app';

  @override
  String get commonOpenInWeb => 'Open in DSH Web';

  @override
  String get commonUntitledChat => 'Untitled chat';

  @override
  String get commonNewChat => 'New chat';

  @override
  String get commonYesterday => 'Yesterday';

  @override
  String get commonSignedIn => 'Signed in';

  @override
  String get commonSignIn => 'Sign in';

  @override
  String get commonSignOut => 'Sign out';

  @override
  String get commonThisPhone => 'This phone';

  @override
  String get commonRemoteHost => 'Remote host';

  @override
  String get commonWeb => 'Web';

  @override
  String get commonFollowSystem => 'System';

  @override
  String get commonLight => 'Light';

  @override
  String get commonDark => 'Dark';

  @override
  String get commonInProgress => 'In progress';

  @override
  String get commonCompleted => 'Completed';

  @override
  String get commonStopped => 'Stopped';

  @override
  String get commonCancelled => 'Cancelled';

  @override
  String get commonRunning => 'Running';

  @override
  String get commonPaused => 'Paused';

  @override
  String get commonDeclined => 'Declined';

  @override
  String get commonFailed => 'Failed';

  @override
  String get commonStopping => 'Stopping';

  @override
  String get commonWaitingApproval => 'Needs approval';

  @override
  String get commonWaitingAnswer => 'Needs your answer';

  @override
  String get commonNotConnected => 'Not connected';

  @override
  String get commonInstalled => 'Installed';

  @override
  String get commonName => 'Name';

  @override
  String get commonStatus => 'Status';

  @override
  String get commonVersion => 'Version';

  @override
  String get commonOther => 'Other';

  @override
  String get commonPin => 'Pin';

  @override
  String get commonReply => 'Reply';

  @override
  String get commonUpdate => 'Update';

  @override
  String get commonViewLogs => 'View logs';

  @override
  String commonItemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count items', one: '1 item');
    return '$_temp0';
  }

  @override
  String commonMonthDay(String month, int day) {
    String _temp0 = intl.Intl.selectLogic(month, {
      '1': 'Jan',
      '2': 'Feb',
      '3': 'Mar',
      '4': 'Apr',
      '5': 'May',
      '6': 'Jun',
      '7': 'Jul',
      '8': 'Aug',
      '9': 'Sep',
      '10': 'Oct',
      '11': 'Nov',
      '12': 'Dec',
      'other': '$month',
    });
    return '$_temp0 $day';
  }

  @override
  String get companionTitle => 'Companion room';

  @override
  String get companionEntrySubtitle => 'Spend some time with her';

  @override
  String get companionDefaultName => 'her';

  @override
  String companionInputHint(String name) {
    return 'Say something to $name';
  }

  @override
  String get companionMenu => 'More';

  @override
  String get companionVoice => 'Voice';

  @override
  String get companionStop => 'Ask her to stop';

  @override
  String get companionSend => 'Send';

  @override
  String get companionNotConnected => 'I can\'t reach the engine right now. Tell me again in a bit?';

  @override
  String get companionSendFailed => 'That didn\'t get through. Say it again?';

  @override
  String get companionLogTitle => 'Log';

  @override
  String get companionContextUnsupported =>
      'This host can\'t take her context yet: her name, persona and what just happened won\'t reach her, only what you say. Update the host or switch to light mode.';

  @override
  String get companionLogEmpty => 'Nothing said yet.';

  @override
  String get companionLogYou => 'You';

  @override
  String get companionLogOpenChat => 'Open in chat';

  @override
  String get companionLogOlder => 'Load earlier messages';

  @override
  String get companionMenuHistory => 'View chat history';

  @override
  String get companionMenuRestart => 'Start over';

  @override
  String get companionMenuRestartHint => 'Begin a new conversation';

  @override
  String get companionMenuRestartConfirm =>
      'She will forget this conversation. The old record stays on the host and is not deleted.';

  @override
  String get companionMenuRemovePack => 'Remove assets';

  @override
  String get companionMenuRemoveConfirm =>
      'The character assets on this phone will be deleted. Chats aren\'t affected. You\'ll need to import them again next time.';

  @override
  String companionCreditAuthor(String name) {
    return 'By $name';
  }

  @override
  String get companionSetupTitle => 'Bring her home';

  @override
  String get companionSetupBody =>
      'Character assets aren\'t part of the app and only land on your phone when you want them. Import an asset pack (zip) to meet her.';

  @override
  String get companionSetupImport => 'Import asset pack';

  @override
  String get companionFailedTitle => 'She couldn\'t come out';

  @override
  String companionFailedBody(String reason) {
    return 'Loading failed on this phone ($reason). You can import the asset pack again and retry.';
  }

  @override
  String get companionFailedBodyPlain =>
      'Your companion didn\'t load just now. Try again first; if that doesn\'t help, import the asset pack again.';

  @override
  String get companionPackBroken => 'This file can\'t be opened. It may not be an asset pack, or it may be damaged.';

  @override
  String get companionPackRuntimeMismatch => 'The runtime in this pack doesn\'t match this version of the app.';

  @override
  String get companionPackNoRuntime =>
      'This pack only has a character and there\'s no runtime on this phone yet. Import a full asset pack first.';

  @override
  String get companionPackNoModel =>
      'No Live2D model (.model3.json) found in the pack. Zip the model\'s whole folder and try again.';

  @override
  String get companionPackUnsafe => 'The pack has files or paths that aren\'t allowed, so it wasn\'t imported.';

  @override
  String get companionPackTooLarge => 'This asset pack is too large.';

  @override
  String get companionPackStorage => 'Couldn\'t write the files. Check your phone\'s free storage.';

  @override
  String companionGreetFirst(String name) {
    return 'Hi, I\'m $name. I live here now, nice to meet you.';
  }

  @override
  String get companionGreetMorning => 'Morning! Don\'t skip breakfast today.';

  @override
  String get companionGreetNoon => 'It\'s noon already. Have you eaten?';

  @override
  String get companionGreetAfternoon => 'Good afternoon. I was just daydreaming.';

  @override
  String get companionGreetEvening => 'Good evening. How was your day?';

  @override
  String get companionGreetLate => 'Still up this late?';

  @override
  String get companionGreetLong => 'It\'s been a while! I thought you\'d forgotten me.';

  @override
  String get companionGreetBack => 'Hm? Back again.';

  @override
  String get companionWake => 'Mm... I wasn\'t asleep. Just resting my eyes.';

  @override
  String get companionPat1 => 'Hehe... you can keep going a little longer.';

  @override
  String get companionPat2 => 'Mmm, that\'s nice.';

  @override
  String get companionPat3 => 'You\'re messing up my hair.';

  @override
  String get companionTapHead1 => 'What\'s up?';

  @override
  String get companionTapHead2 => 'Hm?';

  @override
  String get companionTapFace1 => 'Don\'t poke my face.';

  @override
  String get companionTapFace2 => 'Whoa, your hands are cold.';

  @override
  String get companionTapFace3 => 'Is there something on my face?';

  @override
  String get companionTapBody1 => 'Oh! You startled me.';

  @override
  String get companionTapBody2 => 'What is it?';

  @override
  String get companionTapBody3 => 'I just washed this apron!';

  @override
  String get companionTapTail1 => 'Tails are not for touching!';

  @override
  String get companionTapTail2 => 'Eek, that tickles.';

  @override
  String get companionTapTail3 => 'This is a very important tail.';

  @override
  String get companionTapLegs1 => 'Is something on the floor?';

  @override
  String get companionTapLegs2 => 'Where are you looking?';

  @override
  String get companionTease1 => 'Stop it, I\'m getting dizzy.';

  @override
  String get companionTease2 => 'One more poke and I\'m ignoring you!';

  @override
  String get companionTease3 => 'Don\'t you have anything better to do?';

  @override
  String get companionShake1 => 'Whoa, stop shaking!';

  @override
  String get companionShake2 => 'I\'m so dizzy… the water\'s sloshing everywhere.';

  @override
  String get companionShake3 => 'Keep that up and I\'ll start blowing bubbles!';

  @override
  String get companionStatusIdle => 'Daydreaming';

  @override
  String get companionStatusListening => 'Listening';

  @override
  String get companionStatusThinking => 'Thinking';

  @override
  String get companionStatusSpeaking => 'Talking';

  @override
  String get companionStatusSleeping => 'Asleep';

  @override
  String get companionStatusAway => 'Away';

  @override
  String get companionListening => 'Listening…';

  @override
  String get companionTouchHint => 'Try patting her head';

  @override
  String get companionArriving => 'She\'s swimming over…';

  @override
  String get companionPrivacyLine => 'Assets stay on this phone. Chats go through the current host.';

  @override
  String get companionMemoryTitle => 'What she remembers';

  @override
  String companionMemoryScope(String host) {
    return 'Kept on $host. She doesn\'t bring these up by herself yet; a later version will.';
  }

  @override
  String get companionMemoryAdd => 'Add';

  @override
  String get companionMemoryEdit => 'Edit';

  @override
  String get companionMemorySave => 'Save';

  @override
  String get companionMemoryHint => 'For example: I like unsweetened tea and don\'t drink coffee';

  @override
  String get companionMemoryForget => 'Forget';

  @override
  String get companionMemoryForgetTitle => 'Have her forget this?';

  @override
  String get companionMemoryEmpty => 'Nothing saved yet';

  @override
  String get companionMemoryEmptyHint =>
      'Write down what you\'d like her to remember. It stays on the current host, and you can edit or delete it anytime.';

  @override
  String get companionMemoryUnsupported => 'This host can\'t keep her memories yet';

  @override
  String get companionMemoryUnsupportedHint =>
      'It isn\'t available over the DSH Remote relay, or this host\'s dsh-go bridge is older.';

  @override
  String get companionMemoryLoadFailed => 'Couldn\'t load';

  @override
  String get companionMemoryRetry => 'Retry';

  @override
  String get companionMemoryConflict => 'It was just changed elsewhere, so it\'s been refreshed';

  @override
  String get companionMemoryFull => 'The list is full. Delete some first';

  @override
  String get companionMemorySaveFailed => 'Couldn\'t save. Try again?';

  @override
  String get companionStatusSnacking => 'Having a snack';

  @override
  String get companionStatusPlaying => 'Playing with the bubble';

  @override
  String get companionStatusResting => 'Resting on the cushion';

  @override
  String get companionSnack1 => 'Nom! So good!';

  @override
  String get companionSnack2 => 'Seaweed flavour. Thank you.';

  @override
  String get companionSnack3 => 'Mm... can I have another?';

  @override
  String get companionPlay1 => 'Hey, got it!';

  @override
  String get companionPlay2 => 'The bubble is so squishy. Fun!';

  @override
  String get companionPlay3 => 'It floated back again.';

  @override
  String get companionRest1 => 'I\'ll lean here for a while, then.';

  @override
  String get companionRest2 => 'Go on, I\'m listening.';

  @override
  String get companionTouchHintHome => 'Tap the shell, the bubble and the cushion, or drag a snack to her mouth';

  @override
  String get companionMenuMode => 'How she talks';

  @override
  String get companionModeLight => 'Light';

  @override
  String get companionModeLightHint => 'Chat only. The phone talks to the model; no engine';

  @override
  String get companionModeFull => 'Full';

  @override
  String get companionModeFullHint => 'DSH on the host, with tools and phone control';

  @override
  String get companionLightNoKey => 'Light mode needs a DeepSeek API key. Add one in Settings and we can talk.';

  @override
  String get companionLightBadKey => 'The API key seems wrong, or it is no longer valid.';

  @override
  String get companionLightBusy => 'It is busy over there. Tell me again in a bit?';

  @override
  String get companionNotConnectedTryLight =>
      'I can\'t reach the host right now. If you just want to chat, switch to Light in the menu at the top right.';

  @override
  String get companionMenuRestartLightHint => 'Clear the chat on this phone';

  @override
  String get companionMenuRestartLightConfirm =>
      'She will forget this conversation, and the chat on this phone is deleted.';

  @override
  String get companionInviteRest => 'Rest on the cushion with me for a bit?';

  @override
  String get companionInviteAccept => 'Sure';

  @override
  String get companionInviteDecline => 'Not now';

  @override
  String get companionInviteYes1 => 'Hehe, just for a little while.';

  @override
  String get companionInviteYes2 => 'I\'ll get comfy. You relax too.';

  @override
  String get companionMenuPace => 'How often she speaks up';

  @override
  String get companionPaceHint =>
      'She speaks up only while you sit quietly with her: asking you to rest together, or mentioning another conversation. Never late at night, and at most one invitation per visit.';

  @override
  String get companionPaceQuiet => 'Quiet';

  @override
  String get companionPaceQuietHint => 'Never unasked; she talks when you talk to her';

  @override
  String get companionPaceRare => 'Now and then';

  @override
  String get companionPaceRareHint => 'Up to 2 times a day, at least 6 hours apart';

  @override
  String get companionPaceOften => 'Often';

  @override
  String get companionPaceOftenHint => 'Up to 6 times a day, at least 2 hours apart';

  @override
  String get companionPaceChatty => 'Chatty';

  @override
  String get companionPaceChattyHint => 'Up to 12 times a day, at least half an hour apart';

  @override
  String get companionSetupBundled => 'Bring her home';

  @override
  String get companionSetupBodyBundled =>
      'She comes with the app: one tap and she\'s here, unpacked only on this phone. You can also import another asset pack, or zip up a Live2D model\'s folder and import that.';

  @override
  String get companionSetupImportOther => 'Import another pack';

  @override
  String get companionMenuRemoveConfirmBundled =>
      'The character assets unpacked on this phone will be deleted. Chats aren\'t affected. You can bring her back anytime.';

  @override
  String get companionHug1 => 'Mm... a hug.';

  @override
  String get companionHug2 => 'I feel safe like this.';

  @override
  String get companionHug3 => 'A little longer, just a little.';

  @override
  String get companionBondTitle => 'You two';

  @override
  String get companionBond0 => 'Just met';

  @override
  String get companionBond1 => 'Getting to know each other';

  @override
  String get companionBond2 => 'Close';

  @override
  String get companionBond3 => 'Very close';

  @override
  String get companionCloser1 => 'I think... I\'m not so nervous anymore.';

  @override
  String get companionCloser2 => 'Being with you feels easier and easier.';

  @override
  String get companionCloser3 => 'Keep coming back, okay? I\'ll miss you.';

  @override
  String get companionPatClose => 'I love it when you pat my head.';

  @override
  String get companionHugClose => 'You can hold me tighter, you know.';

  @override
  String get companionTaskDoneUntitled => 'Your task over there is done.';

  @override
  String get companionTaskFailedUntitled => 'Your task over there seems to have hit an error. Take a look?';

  @override
  String get companionTaskOpen => 'Take a look';

  @override
  String get companionMenuSignals => 'What she brings up';

  @override
  String get companionSignalsHint =>
      'These are said only to you, here in her room; nothing goes to the model. How often follows How often she speaks up, shared with invitations, and never late at night. On Quiet she says nothing.';

  @override
  String get companionSignalState => 'Keep track of other conversations';

  @override
  String get companionSignalStateHint => 'She notices when another conversation on this host finishes or fails';

  @override
  String get companionSignalSpeech => 'Mention it';

  @override
  String get companionSignalSpeechHint => 'She says a short line while you\'re quiet';

  @override
  String get companionSignalVoice => 'Say it out loud';

  @override
  String get companionSignalVoiceHint => 'Reads the line aloud when her voice is on';

  @override
  String get companionSignalNight => 'Late-night reminder to rest';

  @override
  String get companionSignalNightHint => 'After a while in her room late at night, she gently reminds you once';

  @override
  String get companionSignalLateUse => 'It\'s so late and you\'re still here with me... maybe rest a little?';

  @override
  String get companionRecallTitle => 'Remember things in full mode';

  @override
  String get companionRecallHint => 'Turning it on starts a new conversation; changing what she remembers turns it off';

  @override
  String get companionRecallConfirm =>
      'Once on, her confirmed memories (up to 12) go to the model along with each of her replies in full mode. A new conversation starts; the current one stays in the main chat list. Changing her memories turns this off, and you can turn it on again.';

  @override
  String get companionRecallTurnOn => 'Turn on';

  @override
  String get companionRecallOn => 'From this new conversation on, I\'ll keep in mind what you asked me to remember.';

  @override
  String get companionRecallBusy => 'Another conversation is already using automatic recall. Turn it off there first.';

  @override
  String get companionRecallUnsupported => 'This host can\'t turn on automatic recall right now';

  @override
  String get companionRecallFailed => 'Automatic recall didn\'t turn on. Try again.';

  @override
  String get companionRecallOff => 'Automatic recall is off. Your next message starts a new conversation.';

  @override
  String get companionRecallOffFailed => 'Automatic recall didn\'t turn off. Try again.';

  @override
  String get companionRecallStopped =>
      'Automatic recall stopped (what she remembers changed), so a new conversation began. You can turn it on again from the menu.';

  @override
  String get companionMenuVoice => 'Her voice';

  @override
  String get companionMenuVoiceHint => 'Reads her words aloud with the phone\'s own voice';

  @override
  String get companionVoiceHello => 'Hi, this is my voice. Keep it on if you like it.';

  @override
  String get companionVoiceUnavailable =>
      'This phone has no Chinese voice to use. You can add one under Text-to-speech in system settings.';

  @override
  String get companionWidgetWaiting => 'Waiting for you in the room';

  @override
  String get companionVoiceOn => 'Let her speak';

  @override
  String get companionVoiceOffHint => 'When you turn it on, she says hello in the chosen voice first.';

  @override
  String get companionVoiceOff => 'Off';

  @override
  String get companionVoiceSource => 'Voice';

  @override
  String get companionVoiceSystem => 'The phone\'s own';

  @override
  String get companionVoiceSystemHint => 'System text-to-speech, works offline';

  @override
  String get companionVoiceOpenai => 'OpenAI-compatible API';

  @override
  String get companionVoiceOpenaiHint =>
      'OpenAI, SiliconFlow, and most self-hosted GPT-SoVITS, CosyVoice or edge-tts servers';

  @override
  String get companionVoiceCustom => 'Custom HTTP';

  @override
  String get companionVoiceCustomHint => 'Anything else: describe the request and the reply';

  @override
  String get companionVoiceApi => 'API';

  @override
  String get companionVoiceBase => 'Address';

  @override
  String get companionVoiceBaseHelper => 'Up to /v1; the app adds /audio/speech';

  @override
  String get companionVoiceKeyHelper => 'Kept in this phone\'s secure storage';

  @override
  String get companionVoiceModel => 'Model';

  @override
  String get companionVoiceVoice => 'Voice';

  @override
  String get companionVoiceVoiceHelper => 'The service\'s voice name, like alloy, or a speaker on your own server';

  @override
  String get companionVoiceRequest => 'Request';

  @override
  String get companionVoiceUrl => 'Request URL';

  @override
  String get companionVoiceUrlHelper => '{text} works in the URL too';

  @override
  String get companionVoiceMethod => 'Method';

  @override
  String get companionVoiceHeaders => 'Headers';

  @override
  String get companionVoiceHeadersHelper => 'One per line; kept in secure storage';

  @override
  String get companionVoiceBody => 'Body';

  @override
  String get companionVoiceBodyHelper => '{text} becomes what she says';

  @override
  String get companionVoiceField => 'Audio field';

  @override
  String get companionVoiceFieldHelper =>
      'If the reply is JSON: where the audio is (base64 or a link), like data.audio. Leave empty when it returns audio';

  @override
  String get companionVoicePrivacy => 'What she says is sent to the service you enter.';

  @override
  String get companionVoicePreview => 'Preview';

  @override
  String get companionVoicePreviewing => 'Requesting…';

  @override
  String get companionVoicePreviewOk => 'It works. Did you hear her?';

  @override
  String companionVoicePreviewFailed(String reason) {
    return 'Didn\'t work: $reason';
  }

  @override
  String get companionVoiceNotSetUp => 'Fill in the address above first.';

  @override
  String get companionVoiceFallback => 'Couldn\'t reach her voice service, so the phone\'s own voice stood in';

  @override
  String get companionGreetFirstNameless => 'Hi, I live here now. Nice to meet you.';

  @override
  String companionRenamed(String name) {
    return '\"$name\"... okay, that\'s my name from now on.';
  }

  @override
  String get companionVoicePreset => 'Popular services';

  @override
  String get companionVoicePresetHint => 'Xiaomi MiMo, OpenAI, SiliconFlow, Alibaba Model Studio: just add a key';

  @override
  String get companionVoiceService => 'Service';

  @override
  String companionVoiceKeyWhere(String site) {
    return 'Get one at $site; kept in this phone\'s secure storage';
  }

  @override
  String get companionVoiceVoiceCustomHelper => 'Pick one, or type a voice ID the service gave you';

  @override
  String get companionVoiceStyle => 'Speaking style';

  @override
  String get companionVoiceStyleHelper =>
      'Describe her tone and the service reads in it; leave empty for the default gentle girl\'s voice';

  @override
  String get companionVoiceFemale => 'female';

  @override
  String get companionVoiceMale => 'male';

  @override
  String get companionClonePreset => 'Preset voices';

  @override
  String get companionCloneMine => 'Clone a voice';

  @override
  String get companionVoicePresetVoice => 'Preset voice';

  @override
  String get companionCloneRecording => 'Recording';

  @override
  String get companionCloneHelper =>
      '5–30 seconds of one person speaking with no background noise, mp3 or wav, up to 7 MB. Only use your own voice, or one whose owner agreed. Every line she says sends this recording to Xiaomi.';

  @override
  String get companionCloneNone => 'No recording yet';

  @override
  String companionCloneReady(String detail) {
    return 'Uploaded · $detail';
  }

  @override
  String companionCloneSeconds(int n) {
    return '$n s';
  }

  @override
  String get companionClonePick => 'Choose a recording';

  @override
  String get companionCloneReplace => 'Replace';

  @override
  String get companionCloneTooLarge => 'The recording is too large (7 MB at most). Trim it and try again.';

  @override
  String get companionCloneNotAudio => 'Only mp3 or wav recordings work.';

  @override
  String get companionCloneFailed => 'Couldn\'t read that recording.';

  @override
  String get companionMenuPersona => 'About her';

  @override
  String get companionPersonaName => 'Name';

  @override
  String get companionPersonaNameHelper => 'Leave empty for the pack\'s name';

  @override
  String get companionPersonaCallMe => 'What she calls you';

  @override
  String get companionPersonaCallMeHint => 'e.g. Sam';

  @override
  String get companionPersonaCallMeHelper => 'Leave empty for nothing in particular';

  @override
  String get companionPersonaText => 'Persona';

  @override
  String get companionPersonaTextLabel => 'Who she is and how she talks';

  @override
  String get companionPersonaTextHelper =>
      'Her personality, who she is, how she talks, what she won\'t say: all yours to write or delete. Only the format of her expression marks is added by the app.';

  @override
  String get companionPersonaReset => 'Reset';

  @override
  String get companionPersonaFooter =>
      'Light mode uses it from her next reply; full mode tells her with your next message.';

  @override
  String get companionMenuMoves => 'Moves and faces';

  @override
  String get companionMovesHint =>
      'These come with the model. The ones switched on are offered to the AI (up to 24 expressions and 24 motions, in list order) and she uses them in her replies; tap a name to give it a clearer one, tap ▶ to try it on her.';

  @override
  String get companionMovesNone =>
      'This model brings no expressions or motions of its own; she uses her built-in ones.';

  @override
  String get companionMovesRename => 'Rename';

  @override
  String get companionMovesTry => 'Try it';

  @override
  String get companionPackLegacyModel =>
      'This is an old Cubism 2 model (.moc and model.json); the runtime on the phone only reads .moc3 from Cubism 3 on. Open it in Cubism Editor, export it as moc3 and import that.';

  @override
  String companionFailedMocVersion(String version, String latest) {
    return 'This model was exported by a newer Cubism (moc version $version); the runtime on the phone reads up to $latest. Export it for an older version in Cubism Editor and import that.';
  }

  @override
  String get companionMenuAdapt => 'Fit this model';

  @override
  String get companionAdaptHint =>
      'Your own model (your key, billed per request) reads this character and matches up her head, eyes, expressions and where she can be touched. Sent: the model\'s name, its parameter list, the names of its expressions, motions and parts, what you write below and the current fitting. Never the model files or textures.';

  @override
  String get companionAdaptOffer =>
      'This model needs fitting: your own model reads its parameter list and the names of its expressions and motions (never the model files), using your key once. New models after this are fitted on their own; you can turn that off in the menu.';

  @override
  String get companionAdaptOfferYes => 'Fit it';

  @override
  String get companionAdaptOfferNo => 'Not now';

  @override
  String get companionAdaptNote => 'What\'s off? (optional)';

  @override
  String get companionAdaptNoteHint =>
      'For example: patting her head does nothing, her face goes dark when she\'s happy';

  @override
  String get companionAdaptRun => 'Let the AI fit it';

  @override
  String get companionAdaptUndo => 'Undo the fitting';

  @override
  String get companionAdaptAuto => 'Fit new models when they\'re imported';

  @override
  String get companionAdaptStart => 'Let me get used to this new body…';

  @override
  String get companionAdaptDone => 'There, I\'ve got the hang of this body.';

  @override
  String companionAdaptDoneNote(String note) {
    return 'There, I\'ve got the hang of this body. $note';
  }

  @override
  String get companionAdaptUndone => 'OK, back to how I was.';

  @override
  String get companionAdaptNoKey => 'To fit me with your model, add an API key in Settings first.';

  @override
  String companionAdaptFailed(String reason) {
    return 'That didn\'t work ($reason). You can try again from Fit this model in the menu.';
  }

  @override
  String get companionAdaptUnreadable => 'the model\'s answer made no sense';

  @override
  String get companionAdaptEmpty => 'the model found nothing to match';

  @override
  String get companionAdaptNetwork => 'no connection';

  @override
  String get automaticDiagnosticsRecover => 'Recover local records';

  @override
  String get automaticDiagnosticsRecoverHint =>
      'Only recovers analysis records on this phone, skips retained failures, and never resends old requests.';

  @override
  String get automaticDiagnosticsTitle => 'Automatic failure analysis';

  @override
  String get automaticDiagnosticsHint =>
      'Off by default. Local, foreground and engine-ready only. Same-version failures are merged for 24 hours. Disabling stops new requests; sent data cannot be retracted.';

  @override
  String get automaticDiagnosticsConsentTitle => 'Enable automatic failure analysis?';

  @override
  String get automaticDiagnosticsConsent =>
      'On a failure, the app sends redacted versions, Android system facts, runtime state, error categories, voice stages and its own process exit reasons to the model provider configured on your local engine. Model charges may apply. No chat text, recordings, credentials or raw logs are included. Reports stay in a separate read-only analysis conversation without changing your current chat. No automatic repairs or GitHub publication. Disabling or switching hosts blocks new analyses and attempts to stop existing analysis; data already sent cannot be retracted.';

  @override
  String get automaticDiagnosticsEnable => 'Agree and enable';

  @override
  String get automaticDiagnosticsOff => 'Off';

  @override
  String get automaticDiagnosticsWaiting => 'Waiting for a local connection, foreground and ready engine';

  @override
  String get automaticDiagnosticsReady => 'Enabled; waiting for a new failure';

  @override
  String get automaticDiagnosticsCollecting => 'Collecting structured failure facts';

  @override
  String get automaticDiagnosticsAnalyzing => 'Analyzing in a separate conversation (up to 2 minutes)';

  @override
  String get automaticDiagnosticsComplete => 'Analysis complete';

  @override
  String get automaticDiagnosticsCancelled => 'Stopped or interrupted; no automatic retry';

  @override
  String get automaticDiagnosticsFailed => 'Analysis failed; this failure will not be retried automatically';

  @override
  String get automaticDiagnosticsStoreFailed => 'Cannot save diagnostics settings or state; automatic analysis stopped';

  @override
  String get automaticDiagnosticsCancelFailed => 'Stop request failed; check the report conversation and stop manually';

  @override
  String get automaticDiagnosticsViewReport => 'View latest analysis conversation';

  @override
  String get automaticDiagnosticsReportHint =>
      'Opens only when tapped; never interrupts your current chat. The report may still be running or interrupted.';

  @override
  String get automaticDiagnosticsReportTitle => 'Automatic failure analysis report';

  @override
  String get systemImeTitle => 'System input-method diagnostics';

  @override
  String get systemImeCollect => 'Capture recent events';

  @override
  String get systemImePrivacy =>
      'Reproduce first. Each attempt needs native confirmation: fixed events from the last 120 seconds, up to 64; no input contents or raw logs. Permissions are never requested automatically.';

  @override
  String get systemImeEvidenceLimits =>
      'Show/hide requests do not prove keyboard visibility. Empty or failed capture does not mean the system behaved normally.';

  @override
  String get systemImeNotCollected => 'Not collected';

  @override
  String get systemImeCollecting => 'Awaiting this attempt’s consent or result';

  @override
  String get systemImeRetained => 'Evidence retained';

  @override
  String get systemImeNoEvents => 'No matching events found';

  @override
  String get systemImeUnavailable => 'No selected, live privileged channel';

  @override
  String get systemImeUnsupported => 'This version or channel does not support capture';

  @override
  String get systemImeDenied => 'This attempt was not approved';

  @override
  String get systemImeCancelled => 'This attempt was cancelled';

  @override
  String get systemImeBusy => 'Channel busy; try again later';

  @override
  String get systemImeTimeout => 'Capture timed out; try again';

  @override
  String get systemImeLimitExceeded => 'Capture limit exceeded; no events retained';

  @override
  String get systemImeFailed => 'Capture failed or response was invalid';

  @override
  String get systemImeEventCount => 'Retained events';

  @override
  String get systemImeCapturedAt => 'Captured at';

  @override
  String get systemImePermissions => 'Phone-control permissions (optional)';

  @override
  String get systemImePermissionsHint =>
      'Configure a privileged channel only if you wish; it is not required for diagnostics. Existing phone permissions are not consent for this capture.';

  @override
  String get systemImeClear => 'Clear evidence and cancel capture';

  @override
  String get systemImeMemory =>
      'Memory only; cleared on restart. A new capture replaces old evidence. Included only in manual AI diagnostics or ZIP exports. Clearing does not retract snapshots or files already exported.';

  @override
  String get engineNewChatDefaultsLast => 'New chat defaults (last choice)';

  @override
  String get engineNewChatDefaultsFixed => 'New chat defaults (fixed)';

  @override
  String get engineNewChatUseLast => 'Last choice';

  @override
  String get engineNewChatUseFixed => 'Fixed default';

  @override
  String get engineNewChatDefaultsHint =>
      'Saved on the current host; affects only the model and thinking effort of new chats. Permissions keep their separate default and never inherit temporary session grants.';

  @override
  String get engineNewChatDefaultsLegacy =>
      'This engine only supports remembering the last choice, not fixed defaults. It cannot confirm whether defaults were saved when switching models.';

  @override
  String get engineNewChatDefaultsUnsupported => 'This host has no editable default model settings';

  @override
  String get engineNewChatDefaultsSelectionUnavailable =>
      'This model or thinking effort is no longer available. Choose again.';

  @override
  String get engineNewChatDefaultsInheritedEffort =>
      'Host base settings specify a thinking effort that cannot be cleared here for a non-thinking model. Update the host configuration first.';

  @override
  String get engineNewChatDefaultsSaving => 'Saving and confirming defaults…';

  @override
  String get engineNewChatDefaultsUnconfirmed =>
      'Could not confirm the complete defaults. Refresh and check the model and thinking effort; host base settings or another client may have changed them.';

  @override
  String get engineModelDefaultSaveFailed =>
      'The model changed for this chat, but new chat defaults were not saved. Check Settings › Models and retry.';

  @override
  String get engineAccountSignedIn => 'Signed in to DeepSeek';

  @override
  String get engineAccountSignOutTitle => 'Sign out of DeepSeek?';

  @override
  String get engineAccountSignOutBusy =>
      'Some tasks are using account models. Signing out interrupts them immediately. Your chats and files stay.';

  @override
  String get engineAccountSignOutBody =>
      'Account models will be unavailable. Your chats, files and API key stay. You can sign in again anytime.';

  @override
  String get engineAccountSignOutUnknown =>
      'Can’t check whether any tasks are using account models. Signing out interrupts any that are.';

  @override
  String get engineAccountSignOutFailed => 'Couldn’t sign out. Try again later.';

  @override
  String get engineAccountTitle => 'Account';

  @override
  String get engineAccountRefresh => 'Refresh';

  @override
  String get engineAccountDeepSeek => 'DeepSeek account';

  @override
  String get engineAccountProfileUnavailable => 'Can’t load account details right now';

  @override
  String get engineAccountBalance => 'Balance';

  @override
  String get engineAccountBalanceHint => 'Account models are charged to your balance';

  @override
  String get engineAccountBalanceEngineOff => 'Start the engine to see your balance';

  @override
  String get engineAccountTopUp => 'Top up';

  @override
  String get engineAccountUsageDetails => 'Usage details';

  @override
  String get engineAccountToppedUpBalance => 'Topped-up balance';

  @override
  String get engineAccountGrantedBalance => 'Granted balance';

  @override
  String get engineAccountBalanceUnavailable => 'Can’t load your balance right now';

  @override
  String get engineAccountNoKeyNeeded => 'No API key needed when signed in';

  @override
  String get engineAccountUnsupported => 'This engine doesn’t support account sign-in';

  @override
  String get engineAccountSignInDeepSeek => 'Sign in with DeepSeek';

  @override
  String get engineAccountAutoStart => 'Signing in starts the engine automatically';

  @override
  String get engineAccountReplaceKey => 'Replace key';

  @override
  String get engineAccountClearKeyTitle => 'Clear API key?';

  @override
  String get engineAccountClearKeyBody =>
      'Deletes the key saved in the app. While the engine on this phone is running, the key in the engine is deleted too.';

  @override
  String get engineAccountBrowserFailed => 'Couldn’t open the browser';

  @override
  String get engineAccountSignInSuccess => 'Signed in';

  @override
  String get engineAccountAlmostReady => 'Almost ready';

  @override
  String get engineAccountStartingEngine => 'Starting engine';

  @override
  String get engineAccountOpenSignInNext => 'The sign-in page opens next';

  @override
  String get engineAccountPreparingSignIn => 'Preparing sign-in';

  @override
  String get engineAccountOpenDeepSeekNext => 'Opening DeepSeek sign-in';

  @override
  String get engineAccountFinishInBrowser => 'Finish sign-in in your browser';

  @override
  String get engineAccountReturnToDsh => 'Return to DSH Go after signing in';

  @override
  String get engineAccountFinishingSignIn => 'Finishing sign-in';

  @override
  String get engineAccountSavingSignIn => 'Saving sign-in details';

  @override
  String get engineAccountAwaitingResult => 'Still waiting for sign-in';

  @override
  String get engineAccountCopySignInLink => 'Copy sign-in link';

  @override
  String get engineAccountReopenSignIn => 'Reopen sign-in';

  @override
  String get engineAccountCancelSignIn => 'Cancel sign-in';

  @override
  String get engineAccountSignInLinkCopied => 'Sign-in link copied';

  @override
  String get engineAccountSigningIn => 'Signing in';

  @override
  String get engineAccountSignedOut => 'Signed out';

  @override
  String get engineAccountUsageFact => 'Usage is charged to your account balance';

  @override
  String get engineAccountBrowserFact => 'Sign in with your browser. DSH never sees your password';

  @override
  String get engineAccountCredentialsFact => 'Sign-in credentials stay on this phone';

  @override
  String get engineSubagentTitle => 'Subagent';

  @override
  String get engineAgentLoopTitle => 'Agent loop';

  @override
  String get engineShellTitle => 'Command execution';

  @override
  String get engineSearchTitle => 'Web search';

  @override
  String get engineSearchNewApiBadge => 'New API';

  @override
  String get engineGeneralTitle => 'General';

  @override
  String get engineSettingsTitle => 'Engine parameters';

  @override
  String get engineSettingsReadFailed => 'Couldn’t load settings';

  @override
  String get engineSettingsRun => 'Runtime';

  @override
  String get engineSettingsPlugins => 'Plugins';

  @override
  String get engineSettingsPluginInventory => 'Plugin inventory';

  @override
  String get engineSettingsPluginStopped => 'Plugin isn’t running';

  @override
  String get engineSettingsEnablePlugin => 'Enable it to change its settings';

  @override
  String get engineSettingsNoEditableFields => 'No settings to change here';

  @override
  String get engineFieldRestoreDefault => 'Reset to default';

  @override
  String get engineFieldDecrease => 'Decrease';

  @override
  String get engineFieldIncrease => 'Increase';

  @override
  String get engineFieldRemove => 'Remove';

  @override
  String get engineFieldShow => 'Show';

  @override
  String get engineFieldFromEnvironment => 'Provided by the startup environment';

  @override
  String get engineFieldItem => 'item';

  @override
  String get engineFieldAlreadyAdded => 'Already added';

  @override
  String get engineFieldEnterName => 'Enter a name';

  @override
  String get engineFieldEnterNumber => 'Enter a number';

  @override
  String get engineFieldValue => 'Value';

  @override
  String get engineFieldNew => 'New';

  @override
  String get engineFieldRequired => 'Required';

  @override
  String get engineGeneralMissing => 'This host has no general settings';

  @override
  String get engineSettingsVersionRequired => 'Requires DSH 0.2.1 or later';

  @override
  String get engineGeneralWebDisplay => 'Web display';

  @override
  String get engineGeneralWebSending => 'Web sending';

  @override
  String get engineGeneralWebOnlyHint => 'These settings only affect this host’s web app, not native chat.';

  @override
  String get engineGeneralData => 'Data';

  @override
  String get engineSubagentModelsTitle => 'Subagent models';

  @override
  String get engineChatLogTitle => 'Chat logs';

  @override
  String get engineThinkingTranslationTitle => 'Thinking translation';

  @override
  String get enginePluginIndexesTitle => 'Plugin market indexes';

  @override
  String get enginePermissionTitle => 'Permission';

  @override
  String get engineAgentPresetsTitle => 'Agent presets';

  @override
  String get engineDefaultModelTitle => 'Default model';

  @override
  String get engineWebAppearanceTitle => 'Web appearance';

  @override
  String get engineLanguageTitle => 'Language';

  @override
  String get engineFieldCommandTimeout => 'Command timeout';

  @override
  String get engineFieldMaxOutput => 'Output limit';

  @override
  String get engineFieldMaxTimeout => 'Max requested timeout';

  @override
  String get engineFieldMaxSpill => 'Spill file limit';

  @override
  String get engineFieldGracePeriod => 'Termination grace period';

  @override
  String get engineFieldDefaultCwd => 'Default working directory';

  @override
  String get engineFieldFollowChat => 'Follow chat';

  @override
  String get engineSubagentMaxDepth => 'Maximum recursion depth';

  @override
  String get engineFieldLayersUnit => 'levels';

  @override
  String get engineSubagentMaxActive => 'Max active subagents';

  @override
  String get engineFieldCountUnit => 'items';

  @override
  String get engineSubagentAllowModelChoice => 'Let AI choose subagent models';

  @override
  String get engineSubagentAllowedModels => 'Available models';

  @override
  String get engineAgentMaxParallelCalls => 'Parallel tool calls per step';

  @override
  String get engineFieldSearchProvider => 'Search service';

  @override
  String get engineFieldFetchProvider => 'Web fetch service';

  @override
  String get engineFieldBaseUrl => 'Service URL';

  @override
  String get engineSearchMaxUses => 'Max searches per request';

  @override
  String get engineFieldTimesUnit => 'times';

  @override
  String get engineSearchHelperModel => 'Helper model';

  @override
  String get engineFieldApiVersion => 'API version';

  @override
  String get engineFieldMaxTokens => 'Max output length';

  @override
  String get engineSearchResultsPerSearch => 'Results per search';

  @override
  String get engineFieldResultsUnit => 'results';

  @override
  String get engineSearchSendOriginalQuestion => 'Include your original question in searches';

  @override
  String get engineChatLogUpload => 'Upload chat logs to DeepSeek';

  @override
  String get engineTranslationProvider => 'Translation service';

  @override
  String get engineTranslationAccountPaid => 'DeepSeek account (paid)';

  @override
  String get engineTranslationApiPaid => 'DeepSeek API (paid)';

  @override
  String get engineTranslationTargetLanguage => 'Target language';

  @override
  String get engineTranslationFollowLanguage => 'Follow interface language';

  @override
  String get engineTranslationLanguageHint => 'Enter auto or a language code, such as zh, en or ja';

  @override
  String get enginePluginIndexSources => 'Index sources';

  @override
  String get enginePluginIndexUrl => 'Index URL';

  @override
  String get engineFieldHttpUrlHint => 'A URL starting with http:// or https://';

  @override
  String get enginePermissionNewChat => 'New chat permissions';

  @override
  String get engineAgentDefaultPreset => 'Default agent preset';

  @override
  String get engineProviderTitle => 'Provider';

  @override
  String get engineModelTitle => 'Model';

  @override
  String get engineFieldReasoningEffort => 'Thinking depth';

  @override
  String get engineGeneralShowCodingView => 'Show coding view';

  @override
  String get engineGeneralWorkDetails => 'Work details';

  @override
  String get engineFieldCompact => 'Compact';

  @override
  String get engineFieldStandard => 'Standard';

  @override
  String get engineFieldDetailed => 'Detailed';

  @override
  String get engineFieldVerbose => 'Verbose';

  @override
  String get engineGeneralCollapseTiming => 'When to collapse work details';

  @override
  String get engineGeneralOnCompletion => 'On completion';

  @override
  String get engineGeneralOnNewMessage => 'On new message';

  @override
  String get engineGeneralPerformanceUsage => 'Performance & usage';

  @override
  String get engineGeneralLinkOpening => 'Open links in';

  @override
  String get engineGeneralAppSidebar => 'App sidebar';

  @override
  String get engineGeneralDefaultBrowser => 'Default browser';

  @override
  String get engineGeneralBusySend => 'Send while AI is working';

  @override
  String get engineGeneralQueueSend => 'Queue';

  @override
  String get engineGeneralSteerSend => 'Steer';

  @override
  String get engineFieldTheme => 'Theme';

  @override
  String get engineFieldFontSize => 'Text size';

  @override
  String get engineFieldCodeFontSize => 'Code font size';

  @override
  String get engineFieldTerminalFontSize => 'Terminal font size';

  @override
  String get engineFieldTextFont => 'Text font';

  @override
  String get engineFieldCodeFont => 'Code font';

  @override
  String get engineFieldTerminalFont => 'Terminal font';

  @override
  String get engineFieldInterfaceLanguage => 'Interface language';

  @override
  String get engineFieldSecondsUnit => 's';

  @override
  String get engineFieldBytesUnit => 'bytes';

  @override
  String get engineFieldGreaterThanZero => 'Greater than 0';

  @override
  String get engineFieldEnterNumeric => 'Enter a number';

  @override
  String get engineFieldEnterInteger => 'Enter a whole number';

  @override
  String get engineFieldInvalidFormat => 'Invalid format';

  @override
  String get engineFieldAddress => 'Address';

  @override
  String get engineFieldToken => 'Token';

  @override
  String get engineFieldService => 'Service';

  @override
  String get engineFieldTimeout => 'Timeout';

  @override
  String get engineFieldQuantity => 'Count';

  @override
  String get engineFieldMaxUses => 'Max uses';

  @override
  String get engineFieldMaxRetries => 'Max retries';

  @override
  String get engineFieldConcurrency => 'Concurrency';

  @override
  String get engineFieldInterval => 'Interval';

  @override
  String get engineFieldPrompt => 'Prompt';

  @override
  String get engineFieldSystemPrompt => 'System prompt';

  @override
  String get engineFieldTemperature => 'Temperature';

  @override
  String get engineFieldDebugMode => 'Debug mode';

  @override
  String get engineFieldVerboseLogs => 'Verbose logs';

  @override
  String get engineFieldPath => 'Path';

  @override
  String get engineFieldCwd => 'Working directory';

  @override
  String get engineFieldCommand => 'Command';

  @override
  String get engineFieldArguments => 'Arguments';

  @override
  String get engineFieldEnvironment => 'Environment variables';

  @override
  String get engineFieldHeaders => 'Headers';

  @override
  String get engineFieldProxy => 'Proxy';

  @override
  String get engineFieldAuto => 'Auto';

  @override
  String get engineFieldEnabled => 'Enabled';

  @override
  String get engineFieldOn => 'On';

  @override
  String get engineFieldOff => 'Off';

  @override
  String get engineFieldLow => 'Low';

  @override
  String get engineFieldMedium => 'Medium';

  @override
  String get engineFieldHigh => 'High';

  @override
  String get engineFieldMax => 'Max';

  @override
  String get engineFieldNone => 'None';

  @override
  String get engineFieldModified => 'Modified';

  @override
  String get engineFieldLocked => 'Fixed by config file';

  @override
  String get engineFieldSharedWithModel => 'Shared with models';

  @override
  String get engineFieldNotConfigured => 'Not configured';

  @override
  String get engineFieldConfigured => 'Configured';

  @override
  String get engineSettingsMissing => 'This host has no such setting';

  @override
  String get engineSettingsPluginDisabled => 'Required plugin isn’t enabled';

  @override
  String get engineSettingsReadOnly => 'Engine settings are read-only';

  @override
  String get engineSubagentSavedUnavailable => 'Saved but currently unavailable';

  @override
  String get engineSubagentKeepOneModel => 'Keep at least one model';

  @override
  String get engineSubagentLimits => 'Limits';

  @override
  String get engineSubagentModelSelection => 'Model selection';

  @override
  String get engineSubagentPickFirstModel => 'Choose a model to apply';

  @override
  String get engineSubagentReadModelsFailed => 'Couldn’t load models';

  @override
  String get engineSubagentNoModels => 'No models available yet';

  @override
  String get engineSubagentConnectModel => 'Add provider';

  @override
  String get engineSearchDeepSeek => 'DeepSeek search';

  @override
  String get engineSearchNewApi => 'New search API';

  @override
  String get engineProviderDeleteBody =>
      'This deletes the provider and its API key. Chats using it will need another model.';

  @override
  String get engineProviderReadFailed => 'Couldn’t load providers';

  @override
  String get engineProviderGone => 'This provider is gone';

  @override
  String get engineProviderProtocol => 'Protocol';

  @override
  String get engineProviderEnterKey => 'Enter API key';

  @override
  String get engineProviderIssues => 'Issues';

  @override
  String get engineProviderRejectedConfig => 'The engine rejected some settings';

  @override
  String get engineProviderConnection => 'Connection';

  @override
  String get engineProviderHeaders => 'Request headers (optional)';

  @override
  String get engineProviderHeadersWarning =>
      'Headers are stored as plain text and are not redacted from logs. Use API Key or a credential reference for sensitive credentials.';

  @override
  String get engineProviderHeaderName => 'Name';

  @override
  String get engineProviderHeaderValue => 'Value';

  @override
  String get engineProviderHeaderAdd => 'Add header';

  @override
  String get engineProviderHeaderInvalidName =>
      'Use letters, digits or HTTP token symbols in header names; no spaces or colons';

  @override
  String get engineProviderHeaderReserved => 'User-Agent is set by the engine; remove this header';

  @override
  String get engineProviderHeaderLocked => 'Managed by the engine; the existing setting is preserved';

  @override
  String get engineProviderHeaderDuplicate => 'Header names must be unique (case-insensitive)';

  @override
  String get engineProviderHeaderInvalidValue =>
      'Use single-line Latin-1 values without control characters (tabs are allowed)';

  @override
  String get engineProviderDefaultUrl => 'Default URL';

  @override
  String get engineProviderKeyNotRequired => 'Not needed';

  @override
  String get engineProviderNoModels => 'No models yet';

  @override
  String get engineProviderWebConfigured => 'Configured in DSH Web. You can view or delete it here';

  @override
  String get engineProviderDelete => 'Delete provider';

  @override
  String get engineProviderConfigFile => 'Provided by the engine config file. Can’t delete it here';

  @override
  String get engineProviderTesting => 'Testing';

  @override
  String get engineProviderTestConnection => 'Test connection';

  @override
  String get engineProviderKeyFirst => 'Enter an API key first';

  @override
  String get engineProviderNoDiscoveredModels => 'The service listed no models. Add them manually.';

  @override
  String get engineProviderNeedModel => 'Add at least one model';

  @override
  String get engineProviderEdit => 'Edit provider';

  @override
  String get engineProviderAdd => 'Add provider';

  @override
  String get engineProviderBasicInfo => 'Basic info';

  @override
  String get engineProviderNameHint => 'e.g. My gateway';

  @override
  String get engineProviderCompatibleProtocol => 'Compatible protocol';

  @override
  String get engineProviderKeepStoredKey => 'Saved. Leave blank to keep it';

  @override
  String get engineProviderSaving => 'Saving';

  @override
  String get engineProviderWaitingEngine => 'Waiting for engine';

  @override
  String get engineProviderFetchingModels => 'Fetching models';

  @override
  String get engineProviderFetchModels => 'Fetch models';

  @override
  String get engineProviderAddManually => 'Add manually';

  @override
  String get engineProviderManualModel => 'Add model manually';

  @override
  String get engineProviderModelId => 'Model ID';

  @override
  String get engineProviderSelectModels => 'Select models';

  @override
  String get engineProviderSearchModels => 'Search models';

  @override
  String get engineProviderDeselectAll => 'Deselect all';

  @override
  String get engineProviderSelectAll => 'Select all';

  @override
  String get engineProviderNoMatchingModels => 'No matching models';

  @override
  String get engineProviderAlreadyAdded => 'Added';

  @override
  String get engineProviderReady => 'Ready';

  @override
  String get engineProviderMissingKey => 'Missing API key';

  @override
  String get engineProviderMisconfigured => 'Invalid config';

  @override
  String get engineProviderInactive => 'Not enabled';

  @override
  String get engineProviderConfiguredInWeb => 'Configured in Web';

  @override
  String get engineProvidersTitle => 'Models';

  @override
  String get engineProvidersNotConnected => 'Not connected to the engine';

  @override
  String get engineProvidersStartEngine => 'Start the engine to add providers';

  @override
  String get engineProvidersUnsupported => 'This host doesn’t support custom providers';

  @override
  String get engineProvidersNotConfiguredHere => 'Not configured on this host';

  @override
  String get engineProvidersSigningIn => 'Signing in…';

  @override
  String get engineProvidersSignInOrKey => 'Sign in or enter an API key';

  @override
  String get engineProvidersOfficial => 'Official';

  @override
  String get engineProvidersSubscription => 'Subscriptions';

  @override
  String get engineProvidersCustom => 'Custom';

  @override
  String get engineProvidersCompatibleHint => 'OpenAI- and Anthropic-compatible services';

  @override
  String get engineProvidersReadOnly => 'Engine settings are read-only. Can’t add providers';

  @override
  String get engineSubscriptionSignOutBody => 'Its models will be removed from the model picker.';

  @override
  String get engineSubscriptionNoModels => 'No models';

  @override
  String get engineSubscriptionModelsFailed => 'Couldn’t load models';

  @override
  String get engineSubscriptionPreparing => 'Preparing…';

  @override
  String get engineSubscriptionCancelled => 'Sign-in cancelled';

  @override
  String get engineSubscriptionIncomplete => 'Sign-in incomplete';

  @override
  String get engineSubscriptionWaitingSignIn => 'Waiting for sign-in…';

  @override
  String get engineSubscriptionReopen => 'Reopen';

  @override
  String get engineSubscriptionCode => 'Verification code';

  @override
  String get engineSubscriptionWaitingVerification => 'Waiting for verification…';

  @override
  String get engineSubscriptionCopyCode => 'Copy code';

  @override
  String get engineSubscriptionOpenVerification => 'Open verification';

  @override
  String get engineSubscriptionPasteRedirect => 'Paste the redirected URL';

  @override
  String get engineSubscriptionPasteCode => 'Paste the authorization code';

  @override
  String get engineSubscriptionPasteHere => 'Paste here';

  @override
  String get engineSubscriptionConfirm => 'Confirm';

  @override
  String get engineSubscriptionTryAgain => 'Try again';

  @override
  String engineAccountWelcome(String name) {
    return 'Welcome, $name';
  }

  @override
  String engineLayerCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count levels', one: '1 level');
    return '$_temp0';
  }

  @override
  String engineFieldDefaultValue(String value) {
    return 'Default $value';
  }

  @override
  String engineFieldDefaultValueUnit(String value, String unit) {
    return 'Default $value $unit';
  }

  @override
  String engineFieldCurrentValue(String value) {
    return 'Current $value';
  }

  @override
  String engineFieldRemoveItem(String name) {
    return 'Remove $name';
  }

  @override
  String engineFieldAddItem(String item) {
    return 'Add $item';
  }

  @override
  String engineFieldItemIndex(int index) {
    return 'Item $index';
  }

  @override
  String engineFieldByteCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count bytes', one: '1 byte');
    return '$_temp0';
  }

  @override
  String engineFieldHours(String value) {
    return '$value h';
  }

  @override
  String engineFieldMinutes(String value) {
    return '$value min';
  }

  @override
  String engineFieldSeconds(String value) {
    return '$value s';
  }

  @override
  String engineFieldMilliseconds(String value) {
    return '$value ms';
  }

  @override
  String engineFieldPositiveMax(String max) {
    return 'Greater than 0, up to $max';
  }

  @override
  String engineFieldMin(String min) {
    return 'At least $min';
  }

  @override
  String engineFieldMaxBound(String max) {
    return 'At most $max';
  }

  @override
  String engineFieldBelowMin(String min) {
    return 'Must be at least $min';
  }

  @override
  String engineFieldAboveMax(String max) {
    return 'Must be at most $max';
  }

  @override
  String engineFieldMultiple(String step) {
    return 'Must be a multiple of $step';
  }

  @override
  String engineFieldMinCharacters(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'At least $count characters',
      one: 'At least 1 character',
    );
    return '$_temp0';
  }

  @override
  String engineFieldMaxCharacters(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'At most $count characters',
      one: 'At most 1 character',
    );
    return '$_temp0';
  }

  @override
  String engineSubagentUnavailableProvider(String provider) {
    return '$provider · Currently unavailable';
  }

  @override
  String engineProviderDeleteTitle(String name) {
    return 'Delete “$name”?';
  }

  @override
  String engineProviderDeleteFailed(String error) {
    return 'Couldn’t delete: $error';
  }

  @override
  String engineProviderModelCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'Models · $count', one: 'Model · 1');
    return '$_temp0';
  }

  @override
  String engineProviderContext(String size) {
    return 'Context $size';
  }

  @override
  String engineProviderTestPassed(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Connected · Listed $count models',
      one: 'Connected · Listed 1 model',
    );
    return '$_temp0';
  }

  @override
  String engineProviderCompletedUrl(String url) {
    return 'Completed as $url';
  }

  @override
  String engineProviderSaveFailed(String error) {
    return 'Couldn’t save: $error';
  }

  @override
  String engineProviderCandidateCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count total', one: '1 total');
    return '$_temp0';
  }

  @override
  String engineProviderAddModels(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'Add $count models', one: 'Add 1 model');
    return '$_temp0';
  }

  @override
  String engineProviderModels(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count models', one: '1 model');
    return '$_temp0';
  }

  @override
  String engineProvidersSummary(int total, int ready) {
    String _temp0 = intl.Intl.pluralLogic(total, locale: localeName, other: '$total providers', one: '1 provider');
    return '$_temp0 · $ready ready';
  }

  @override
  String engineProvidersAccount(String name) {
    return 'Account · $name';
  }

  @override
  String engineProvidersSignedInAccount(String account) {
    return 'Signed in · $account';
  }

  @override
  String engineSubscriptionSignIn(String provider) {
    return 'Sign in to $provider';
  }

  @override
  String engineSubscriptionSignOutTitle(String provider) {
    return 'Sign out of $provider?';
  }

  @override
  String engineSubscriptionSignOutFailed(String error) {
    return 'Couldn’t sign out: $error';
  }

  @override
  String engineSubscriptionCodeSemantics(String code) {
    return 'Verification code $code';
  }

  @override
  String engineFieldItemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count items', one: '1 item');
    return '$_temp0';
  }

  @override
  String engineFieldUseCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count times', one: '1 time');
    return '$_temp0';
  }

  @override
  String engineFieldResultCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count results', one: '1 result');
    return '$_temp0';
  }

  @override
  String engineFieldMinCharactersDecimal(String bound) {
    return 'At least $bound characters';
  }

  @override
  String engineFieldMaxCharactersDecimal(String bound) {
    return 'At most $bound characters';
  }

  @override
  String engineLayerValue(String value) {
    return '$value levels';
  }

  @override
  String engineFieldEnterPositiveRange(String max) {
    return 'Enter a number greater than 0 and no more than $max';
  }

  @override
  String engineFieldEnterBoundedRange(String min, String max) {
    return 'Enter a number from $min to $max';
  }

  @override
  String get engineModelTokenLimits => 'Token limits';

  @override
  String get engineModelContextLength => 'Context length';

  @override
  String get engineModelContextOverrideHint =>
      'Empty uses the catalog\'s figure. A larger value is what the engine counts context pressure and compaction against.';

  @override
  String get engineModelMaxOutput => 'Max output';

  @override
  String engineModelDefaultSize(String size) {
    return 'Default $size';
  }

  @override
  String get engineModelCapabilities => 'Capabilities';

  @override
  String get engineModelInputType => 'Input';

  @override
  String get engineModelInputText => 'Text';

  @override
  String get engineModelInputTextImage => 'Text + image';

  @override
  String get engineModelThinking => 'Thinking';

  @override
  String get engineModelVision => 'Vision';

  @override
  String get engineModelLevels => 'Available levels';

  @override
  String get engineModelNeedLevel => 'Pick at least one level';

  @override
  String get engineFieldEditOnWeb => 'Edit this item on the web';

  @override
  String get engineSettingsHostChanged => 'The host changed. Reopen these settings to edit.';

  @override
  String get engineSecretTargetChanged => 'This field changed. Reopen it to edit.';

  @override
  String engineSettingsGroupCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count settings', one: '1 setting');
    return '$_temp0';
  }

  @override
  String get featuresCordisSubtitle => 'Dynamic plugins · Cleared when the engine restarts';

  @override
  String get featuresCordisUnavailable => 'Cordis isn’t available here';

  @override
  String get featuresCordisRemoteUnavailable => 'Unavailable over DSH Remote';

  @override
  String get featuresCordisReadFailed => 'Couldn’t load plugins';

  @override
  String get featuresCordisEmpty => 'No dynamic plugins yet';

  @override
  String get featuresCordisEmptyHint => 'Plugins appear here once created';

  @override
  String get featuresCurrentChat => 'Current chat';

  @override
  String get featuresOtherChats => 'Other chats';

  @override
  String featuresPresetDefaultSet(String name) {
    return 'New chats will use “$name”';
  }

  @override
  String get featuresPresetDefaultFailed => 'Couldn’t set as default';

  @override
  String featuresPresetDeleteTitle(String name) {
    return 'Delete “$name”?';
  }

  @override
  String get featuresPresetDeleteHint => 'It won’t be available for new chats. Existing chats stay as they are.';

  @override
  String get featuresDeleted => 'Deleted';

  @override
  String get featuresDeleteFailed => 'Couldn’t delete';

  @override
  String get featuresPresetAlreadyDefault => 'Default for new chats';

  @override
  String get featuresPresetSetDefault => 'Use for new chats';

  @override
  String get featuresPresetViewConfig => 'View configuration';

  @override
  String get featuresPresetDuplicate => 'Duplicate preset';

  @override
  String get featuresPresetDefaultDeleteHint => 'Set another preset as the default for new chats first';

  @override
  String get featuresAgentPresets => 'Agent presets';

  @override
  String get featuresAgentPresetsSubtitle => 'Tools and behavior for new chats';

  @override
  String get featuresNew => 'New';

  @override
  String get featuresPresetsReadFailed => 'Couldn’t load agent presets';

  @override
  String get featuresLoadFailed => 'Couldn’t load';

  @override
  String get featuresNewChatDefault => 'Default for new chats';

  @override
  String get featuresEmptyDocument => '(Empty)';

  @override
  String get featuresReadFailed => 'Couldn’t read';

  @override
  String featuresTodayTime(String time) {
    return 'Today $time';
  }

  @override
  String featuresTomorrowTime(String time) {
    return 'Tomorrow $time';
  }

  @override
  String featuresYesterdayTime(String time) {
    return 'Yesterday $time';
  }

  @override
  String featuresScheduleSummaryNext(String rule, String time) {
    return '$rule · Next $time';
  }

  @override
  String get featuresEnded => 'Ended';

  @override
  String featuresScheduleSummaryEnded(String time) {
    return 'Ended · Ran $time';
  }

  @override
  String featuresJobElapsed(String span) {
    return 'Running for $span';
  }

  @override
  String featuresJobDuration(String span) {
    return 'Took $span';
  }

  @override
  String get featuresPermissionReadOnly => 'Read only';

  @override
  String get featuresPermissionWorkspaceWrite => 'Workspace write';

  @override
  String get featuresPermissionFullAccess => 'Full access';

  @override
  String get featuresPermissionAutoReview => 'Auto review';

  @override
  String get featuresPermissionCustom => 'Custom';

  @override
  String get featuresPermissionReadOnlyHint => 'View files without changing them';

  @override
  String get featuresPermissionWorkspaceWriteHint => 'Edit workspace files; ask before going beyond';

  @override
  String get featuresPermissionFullAccessHint => 'Run without asking';

  @override
  String get featuresPermissionAutoReviewHint => 'The model reviews each action and asks when unsure';

  @override
  String get featuresPresetStandard => 'Standard mode';

  @override
  String get featuresPresetPtc => 'PTC mode';

  @override
  String get featuresPresetMinimal => 'Minimal mode';

  @override
  String get featuresPresetCreator => 'Creator mode';

  @override
  String get featuresPresetStandardDescription => 'Code, files, and research for most tasks';

  @override
  String get featuresPresetPtcDescription => 'Batch tool calls, then filter, analyze, and summarize';

  @override
  String get featuresPresetMinimalDescription => 'Terminal and image viewing only, for testing and comparison';

  @override
  String get featuresPresetCreatorDescription => 'Have the agent write plugins to customize DSH';

  @override
  String featuresHostUnreachable(String name) {
    return 'Can’t connect to “$name”';
  }

  @override
  String featuresHostConnecting(String name) {
    return 'Connecting to “$name”…';
  }

  @override
  String get featuresJobs => 'Background jobs';

  @override
  String get featuresJobsSubtitle => 'Cleared when the engine restarts';

  @override
  String get featuresJobsReadFailed => 'Couldn’t load background jobs';

  @override
  String get featuresJobsEmpty => 'No background jobs';

  @override
  String get featuresJobsEmptyHint => 'Commands such as dev servers appear here';

  @override
  String featuresJobsEndedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'Ended · $count', one: 'Ended · 1');
    return '$_temp0';
  }

  @override
  String get featuresJobStopTitle => 'Stop this job?';

  @override
  String get featuresJobAlreadyEnded => 'This job has already ended';

  @override
  String get featuresJobStopFailed => 'Couldn’t stop';

  @override
  String get featuresJobOutput => 'Job output';

  @override
  String get featuresOutput => 'Output';

  @override
  String featuresJobRecentLines(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'Last $count lines', one: 'Last 1 line');
    return '$_temp0';
  }

  @override
  String get featuresJobOutputSubject => 'DSH job output';

  @override
  String get featuresJobOutputReadFailed => 'Couldn’t read output';

  @override
  String get featuresJobOutputWaiting => 'Waiting for output…';

  @override
  String get featuresJobOutputEmpty => 'No output';

  @override
  String get featuresPermissionAutoTitle => 'Turn on Auto review?';

  @override
  String get featuresPermissionAutoWarning => 'The model decides whether to allow each action. It may get it wrong.';

  @override
  String get featuresSwitchFailed => 'Couldn’t switch';

  @override
  String get featuresPermissions => 'Permissions';

  @override
  String get featuresPermissionsSubtitle => 'Choose when to ask before running commands or editing files';

  @override
  String get featuresPermissionsReadFailed => 'Couldn’t load permissions';

  @override
  String get featuresPermissionCustomHint => 'Choosing a preset replaces your custom permissions';

  @override
  String get featuresModuleInstructions => 'Workspace instructions';

  @override
  String get featuresModuleTime => 'Time awareness';

  @override
  String get featuresModuleBash => 'Bash command tool';

  @override
  String get featuresModulePersistentBash => 'Persistent Bash tool';

  @override
  String get featuresModulePowerShell => 'PowerShell command tool';

  @override
  String get featuresModuleFiles => 'File read/write tool';

  @override
  String get featuresModuleFileSearch => 'File search tool';

  @override
  String get featuresModuleJobs => 'Background job tool';

  @override
  String get featuresModuleSchedule => 'Automation tool';

  @override
  String get featuresModuleLocalSkills => 'Local skill loading';

  @override
  String get featuresModuleSkillTool => 'Skill loading tool';

  @override
  String get featuresModuleGoalCommand => 'Goal management command';

  @override
  String get featuresModuleGoalTool => 'Goal management tool';

  @override
  String get featuresModulePlan => 'Plan mode';

  @override
  String get featuresModuleCompaction => 'Context compaction';

  @override
  String get featuresModuleCompactCommand => 'Context compaction command';

  @override
  String get featuresModuleAskUser => 'Ask user tool';

  @override
  String get featuresModuleTodo => 'Todo list tool';

  @override
  String get featuresModuleWeb => 'Web search and fetch tool';

  @override
  String get featuresModulePresent => 'File delivery tool';

  @override
  String get featuresModuleCordis => 'Plugin API lookup tool';

  @override
  String get featuresModuleSubagent => 'Subagent delegation tool';

  @override
  String get featuresModuleSubagentControl => 'Subagent control tool';

  @override
  String get featuresModuleWorkflow => 'Workflow tool';

  @override
  String get featuresModulePluginManager => 'Plugin management tool';

  @override
  String get featuresModulePluginMarket => 'Plugin marketplace tool';

  @override
  String get featuresModuleToolCalls => 'Tool call style';

  @override
  String get featuresModuleTerminal => 'Persistent terminal service';

  @override
  String get featuresModulePersona => 'Agent persona';

  @override
  String get featuresGroupDelegation => 'Subagent delegation';

  @override
  String get featuresGroupTerminal => 'Persistent terminal';

  @override
  String get featuresPresetIdRequired => 'Enter an ID';

  @override
  String get featuresPresetIdLength => 'Up to 40 characters';

  @override
  String get featuresPresetIdFormat => 'Use lowercase letters, numbers, and hyphens';

  @override
  String get featuresPresetIdTaken => 'This ID is already in use';

  @override
  String featuresPresetCopyName(String name) {
    return '$name copy';
  }

  @override
  String get featuresPresetBasedOn => 'Based on';

  @override
  String get featuresNameRequired => 'Enter a name';

  @override
  String get featuresCreatorOpenFailed => 'Couldn’t open Creator mode';

  @override
  String get featuresPresetNameHint => 'For example: Code review';

  @override
  String get featuresPresetId => 'ID';

  @override
  String get featuresPresetIdHint => 'Lowercase letters, numbers, and hyphens';

  @override
  String get featuresPresetDescription => 'Description';

  @override
  String get featuresPresetDescriptionHint => 'Describe what it’s for in one sentence';

  @override
  String get featuresPresetConfigReadFailed => 'Couldn’t load preset configuration';

  @override
  String get featuresPresetCreateTitle => 'New agent preset';

  @override
  String get featuresPresetDuplicateTitle => 'Duplicate agent preset';

  @override
  String get featuresPresetEditTitle => 'Edit agent preset';

  @override
  String get featuresCreatorOpening => 'Opening Creator mode';

  @override
  String get featuresWaitingEngine => 'Waiting for the engine';

  @override
  String get featuresCreatorUnavailable => 'Creator mode unavailable';

  @override
  String get featuresPresetStartUpdate => 'Start updating';

  @override
  String get featuresPresetStartCreate => 'Start creating';

  @override
  String get featuresPresetSystemPrompt => 'System prompt';

  @override
  String get featuresPresetSystemPromptHint => 'Who you are and how you work';

  @override
  String get featuresPresetReplaceSystemPrompt => 'Replace the full system prompt';

  @override
  String get featuresPresetTools => 'Tools';

  @override
  String get featuresSkills => 'Skills';

  @override
  String get featuresPresetContextModes => 'Context and modes';

  @override
  String get featuresCronMinute => 'Minutes';

  @override
  String get featuresCronHour => 'Hours';

  @override
  String get featuresDate => 'Date';

  @override
  String get featuresCronMonth => 'Month';

  @override
  String get featuresCronWeekday => 'Day of week';

  @override
  String get featuresCronRequired => 'Enter a 5-field Cron expression';

  @override
  String get featuresCronWhitespace => 'No leading or trailing spaces';

  @override
  String featuresCronFieldCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Expected 5 fields, got $count',
      one: 'Expected 5 fields, got 1',
    );
    return '$_temp0';
  }

  @override
  String featuresCronInvalidField(int index, String name) {
    return 'Field $index ($name) is invalid';
  }

  @override
  String get featuresWeekdayMon => 'Mon';

  @override
  String get featuresWeekdayTue => 'Tue';

  @override
  String get featuresWeekdayWed => 'Wed';

  @override
  String get featuresWeekdayThu => 'Thu';

  @override
  String get featuresWeekdayFri => 'Fri';

  @override
  String get featuresWeekdaySat => 'Sat';

  @override
  String get featuresWeekdaySun => 'Sun';

  @override
  String get featuresMonthJan => 'January';

  @override
  String get featuresMonthFeb => 'February';

  @override
  String get featuresMonthMar => 'March';

  @override
  String get featuresMonthApr => 'April';

  @override
  String get featuresMonthMay => 'May';

  @override
  String get featuresMonthJun => 'June';

  @override
  String get featuresMonthJul => 'July';

  @override
  String get featuresMonthAug => 'August';

  @override
  String get featuresMonthSep => 'September';

  @override
  String get featuresMonthOct => 'October';

  @override
  String get featuresMonthNov => 'November';

  @override
  String get featuresMonthDec => 'December';

  @override
  String featuresWeekdayName(String day) {
    return '$day';
  }

  @override
  String featuresCronWeekdayRange(String first, String last) {
    return '$first–$last';
  }

  @override
  String featuresCronEveryDay(String months) {
    return 'Every day$months';
  }

  @override
  String featuresCronMonthDays(String days, String months) {
    return 'Monthly on $days$months';
  }

  @override
  String featuresCronMonthDaysAndWeekdays(String days, String weekdays, String months) {
    return 'Monthly on $days, if $weekdays$months';
  }

  @override
  String featuresCronMonthDaysOrWeekdays(String days, String weekdays, String months) {
    return 'Monthly on $days or $weekdays$months';
  }

  @override
  String featuresCronHourRange(String first, String last) {
    return '$first to $last';
  }

  @override
  String get featuresEveryMinute => 'Every minute';

  @override
  String featuresCronEveryMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Every $count minutes',
      one: 'Every minute',
    );
    return '$_temp0';
  }

  @override
  String get featuresEveryHour => 'Every hour';

  @override
  String featuresCronHourlyMinutes(String minutes) {
    return 'At minute $minutes of every hour';
  }

  @override
  String featuresCronHoursEveryMinute(String hours) {
    return 'Every minute during hour $hours';
  }

  @override
  String featuresCronHoursEveryMinutes(String hours, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Every $count minutes during hour $hours',
      one: 'Every minute during hour $hours',
    );
    return '$_temp0';
  }

  @override
  String featuresCronEveryHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'Every $count hours', one: 'Every hour');
    return '$_temp0';
  }

  @override
  String featuresCronHoursMinutes(String hours, String minutes) {
    return 'At minute $minutes during hour $hours';
  }

  @override
  String get featuresRepeatDaily => 'Daily';

  @override
  String get featuresRepeatWeekdays => 'Weekdays';

  @override
  String get featuresRepeatWeekly => 'Weekly';

  @override
  String get featuresRepeatMonthly => 'Monthly';

  @override
  String get featuresRepeatInterval => 'Interval';

  @override
  String get featuresRepeatOnce => 'Once';

  @override
  String get featuresRepeatAdvanced => 'Advanced';

  @override
  String get featuresRepeatCustom => 'Custom';

  @override
  String get featuresIntervalSeconds => 'Seconds';

  @override
  String get featuresZoneUnavailable => 'Time zone unavailable';

  @override
  String get featuresChooseDay => 'Choose at least one day';

  @override
  String get featuresIntervalMinimum => 'Interval must be at least 1';

  @override
  String get featuresMinimumMinute => 'At least 1 minute';

  @override
  String get featuresTimeDoesNotExist => 'This time doesn’t exist in this time zone';

  @override
  String get featuresChooseFutureTime => 'Choose a future time';

  @override
  String get featuresCronNeverRuns => 'This expression never runs';

  @override
  String featuresRuleDaily(String time) {
    return 'Daily at $time';
  }

  @override
  String featuresRuleWeekdays(String time) {
    return 'Weekdays at $time';
  }

  @override
  String featuresRuleWeekends(String time) {
    return 'Weekends at $time';
  }

  @override
  String featuresRuleWeekly(String days, String time) {
    return 'Every $days at $time';
  }

  @override
  String featuresRuleMonthly(String days, String time) {
    return 'Monthly on $days at $time';
  }

  @override
  String get featuresRepeat => 'Repeat';

  @override
  String get featuresChat => 'Chat';

  @override
  String get featuresWorkspace => 'Workspace';

  @override
  String get featuresInstructionRequired => 'Enter instructions';

  @override
  String featuresScheduleSaveError(String reason) {
    return 'Couldn’t save: $reason';
  }

  @override
  String featuresScheduleCreateError(String reason) {
    return 'Couldn’t create: $reason';
  }

  @override
  String get featuresScheduleNameHint => 'For example: Daily standup reminder';

  @override
  String get featuresScheduleInstruction => 'Instructions';

  @override
  String get featuresScheduleInstructionHint => 'For example: Summarize yesterday’s commits for me';

  @override
  String get featuresScheduleRunTime => 'Run time';

  @override
  String get featuresScheduleOpenChat => 'View chat';

  @override
  String get featuresScheduleEditTitle => 'Edit automation';

  @override
  String get featuresScheduleCreateTitle => 'New automation';

  @override
  String get featuresScheduleSaving => 'Saving';

  @override
  String get featuresScheduleCreating => 'Creating in chat';

  @override
  String get featuresTime => 'Time';

  @override
  String get featuresNotSelected => 'Not selected';

  @override
  String featuresMonthDaysLabel(String days) {
    return 'Day $days';
  }

  @override
  String get featuresTimeZone => 'Time zone';

  @override
  String get featuresScheduleRunLocation => 'Run in';

  @override
  String get featuresJustCreatedChat => 'Just-created chat';

  @override
  String get featuresModel => 'Model';

  @override
  String get featuresRequestRefused => 'The engine didn’t accept this request';

  @override
  String get featuresScheduleNotFound => 'This automation no longer exists';

  @override
  String get featuresScheduleEndedError => 'This automation has ended and can’t be edited';

  @override
  String get featuresScheduleConflict => 'This automation just changed. Go back and try again.';

  @override
  String get featuresScheduleInvalidPrompt => 'Enter a name and instructions. Names can have up to 120 characters.';

  @override
  String get featuresScheduleInvalidTime => 'Invalid run time';

  @override
  String get featuresScheduleIntervalTooShort => 'Interval must be at least 1 minute';

  @override
  String get featuresScheduleTimeOutOfRange => 'Time is out of range';

  @override
  String get featuresScheduleSubagentError => 'This chat can’t receive automations';

  @override
  String get featuresEvery => 'Every';

  @override
  String get featuresCronExpression => 'Cron expression';

  @override
  String get featuresCronFieldGuide => 'Min  Hour  Day  Month  Weekday';

  @override
  String featuresZoneTimeSuffix(String city) {
    return ' ($city time)';
  }

  @override
  String get featuresScheduleNextLocal => 'Next runs (this phone’s time)';

  @override
  String get featuresScheduleNext => 'Next runs';

  @override
  String featuresMonthDayChoice(int day) {
    return 'Day $day';
  }

  @override
  String get featuresZonesCommon => 'Common';

  @override
  String get featuresZonesAll => 'All';

  @override
  String get featuresZoneSearchHint => 'Search cities, time zones, or UTC offsets';

  @override
  String get featuresZonesNoMatch => 'No matching time zones';

  @override
  String get featuresZoneUTC => 'Coordinated Universal Time';

  @override
  String get featuresZoneShanghai => 'Shanghai';

  @override
  String get featuresZoneUrumqi => 'Urumqi';

  @override
  String get featuresZoneHongKong => 'Hong Kong';

  @override
  String get featuresZoneMacau => 'Macau';

  @override
  String get featuresZoneTaipei => 'Taipei';

  @override
  String get featuresZoneTokyo => 'Tokyo';

  @override
  String get featuresZoneSeoul => 'Seoul';

  @override
  String get featuresZoneSingapore => 'Singapore';

  @override
  String get featuresZoneKualaLumpur => 'Kuala Lumpur';

  @override
  String get featuresZoneBangkok => 'Bangkok';

  @override
  String get featuresZoneHoChiMinh => 'Ho Chi Minh City';

  @override
  String get featuresZoneJakarta => 'Jakarta';

  @override
  String get featuresZoneManila => 'Manila';

  @override
  String get featuresZoneKolkata => 'Kolkata';

  @override
  String get featuresZoneDubai => 'Dubai';

  @override
  String get featuresZoneJerusalem => 'Jerusalem';

  @override
  String get featuresZoneLondon => 'London';

  @override
  String get featuresZoneDublin => 'Dublin';

  @override
  String get featuresZoneLisbon => 'Lisbon';

  @override
  String get featuresZoneParis => 'Paris';

  @override
  String get featuresZoneBerlin => 'Berlin';

  @override
  String get featuresZoneMadrid => 'Madrid';

  @override
  String get featuresZoneRome => 'Rome';

  @override
  String get featuresZoneAmsterdam => 'Amsterdam';

  @override
  String get featuresZoneZurich => 'Zurich';

  @override
  String get featuresZoneStockholm => 'Stockholm';

  @override
  String get featuresZoneWarsaw => 'Warsaw';

  @override
  String get featuresZoneAthens => 'Athens';

  @override
  String get featuresZoneIstanbul => 'Istanbul';

  @override
  String get featuresZoneMoscow => 'Moscow';

  @override
  String get featuresZoneCairo => 'Cairo';

  @override
  String get featuresZoneJohannesburg => 'Johannesburg';

  @override
  String get featuresZoneLagos => 'Lagos';

  @override
  String get featuresZoneNewYork => 'New York';

  @override
  String get featuresZoneToronto => 'Toronto';

  @override
  String get featuresZoneChicago => 'Chicago';

  @override
  String get featuresZoneDenver => 'Denver';

  @override
  String get featuresZonePhoenix => 'Phoenix';

  @override
  String get featuresZoneLosAngeles => 'Los Angeles';

  @override
  String get featuresZoneVancouver => 'Vancouver';

  @override
  String get featuresZoneAnchorage => 'Anchorage';

  @override
  String get featuresZoneMexicoCity => 'Mexico City';

  @override
  String get featuresZoneBogota => 'Bogota';

  @override
  String get featuresZoneLima => 'Lima';

  @override
  String get featuresZoneSantiago => 'Santiago';

  @override
  String get featuresZoneSaoPaulo => 'Sao Paulo';

  @override
  String get featuresZoneBuenosAires => 'Buenos Aires';

  @override
  String get featuresZoneHonolulu => 'Honolulu';

  @override
  String get featuresZoneAuckland => 'Auckland';

  @override
  String get featuresZoneSydney => 'Sydney';

  @override
  String get featuresZoneMelbourne => 'Melbourne';

  @override
  String get featuresZoneBrisbane => 'Brisbane';

  @override
  String get featuresZonePerth => 'Perth';

  @override
  String get featuresScheduleCreated => 'Created';

  @override
  String get featuresSchedulesReadFailed => 'Couldn’t load automations';

  @override
  String get featuresSchedulesEmpty => 'No automations yet';

  @override
  String get featuresSchedulesEmptyHint => 'Send to a chat and run automatically at the scheduled time';

  @override
  String get featuresScheduleNewTask => 'New automation';

  @override
  String get featuresSchedulesNoMatch => 'No matching automations';

  @override
  String get featuresSchedulesNoActive => 'No active automations';

  @override
  String get featuresSchedulesNoEnded => 'No ended automations';

  @override
  String get featuresSchedules => 'Automations';

  @override
  String get featuresSchedulesSubtitle => 'Send to the original chat at the scheduled time';

  @override
  String get featuresSchedulesSearch => 'Search automations';

  @override
  String featuresSchedulesAllCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'All $count', one: 'All 1');
    return '$_temp0';
  }

  @override
  String get featuresScheduleUntitled => 'Untitled automation';

  @override
  String get featuresScheduleSent => 'Sent to chat';

  @override
  String get featuresView => 'View';

  @override
  String get featuresSendFailed => 'Couldn’t send';

  @override
  String get featuresScheduleDeleteTitle => 'Delete this automation?';

  @override
  String get featuresScheduleDeleteHint =>
      'Future runs will stop and run history will be deleted. The original chat stays as it is.';

  @override
  String get featuresScheduleDeleted => 'Automation deleted';

  @override
  String get featuresScheduleActive => 'Active';

  @override
  String get featuresScheduleRun => 'Run';

  @override
  String get featuresScheduleNextRun => 'Next';

  @override
  String get featuresScheduleLastRun => 'Last';

  @override
  String get featuresScheduleRule => 'Rule';

  @override
  String get featuresScheduleLinkedChat => 'Linked chat';

  @override
  String get featuresScheduleChatDeleted => 'Chat deleted';

  @override
  String get featuresScheduleEdit => 'Edit automation';

  @override
  String get featuresScheduleRunNow => 'Run now';

  @override
  String get featuresScheduleHistory => 'Run history';

  @override
  String get featuresScheduleNeverRun => 'No runs yet';

  @override
  String get featuresScheduleHistoryUnavailable => 'History unavailable';

  @override
  String get featuresScheduleHistoryReadFailed => 'Couldn’t load run history';

  @override
  String get featuresScheduleDelete => 'Delete automation';

  @override
  String featuresExportSavedTo(String path) {
    return 'Saved to $path';
  }

  @override
  String get featuresExportTitle => 'Export chat logs';

  @override
  String get featuresExportSubtitle => 'A ZIP for feedback or backup';

  @override
  String get featuresExportUnavailable => 'Can’t export over this connection';

  @override
  String get featuresExportRemoteHint =>
      'Logs aren’t available over DSH Remote. Export them from DSH Web on your computer.';

  @override
  String get featuresExportShareHint => 'Attach to feedback or send to yourself';

  @override
  String get featuresExportSaveDownloads => 'Save to Downloads';

  @override
  String get featuresExportDownloadsHint => 'Save in Downloads/DSH-Go';

  @override
  String get featuresExportContents => 'All records and attachments from this chat and its subagents';

  @override
  String get featuresSkillUseHere => 'Use in chat';

  @override
  String get featuresSkillUseNew => 'New chat';

  @override
  String get featuresSkillsCallHint => 'Type /skill-name to use';

  @override
  String get featuresSkillsReadFailed => 'Couldn’t load skills';

  @override
  String get featuresSkillsEmpty => 'No skills in this chat yet';

  @override
  String get featuresSkillsEmptyHint => 'Skills in .dsh/skills appear here';

  @override
  String get featuresSkillsSourceHint => 'From the project’s and ~/.dsh skills folders';

  @override
  String featuresSkillUsage(String usage) {
    return 'For: $usage';
  }

  @override
  String get featuresSkillManual => 'Manual only';

  @override
  String featuresArtifactsSemantic(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Output files, $count files, view all',
      one: 'Output files, 1 file, view all',
    );
    return '$_temp0';
  }

  @override
  String get featuresArtifactsTitle => 'Output files';

  @override
  String featuresArtifactsAllCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'All $count', one: 'All 1');
    return '$_temp0';
  }

  @override
  String featuresArtifactsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count files', one: '1 file');
    return '$_temp0';
  }

  @override
  String get featuresArtifactsNoFiles => 'No files yet';

  @override
  String featuresArtifactsTotal(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files · Delivered and generated',
      one: '1 file · Delivered and generated',
    );
    return '$_temp0';
  }

  @override
  String get featuresArtifactsEmpty => 'No output files yet';

  @override
  String get featuresArtifactsEmptyHint => 'Files delivered or generated by AI appear here';

  @override
  String get featuresListSeparator => ', ';

  @override
  String featuresErrorReason(String title, String reason) {
    return '$title: $reason';
  }

  @override
  String featuresYearDate(int year, String date) {
    return '$date, $year';
  }

  @override
  String featuresDateWeekdayTime(String date, String week, String time) {
    return '$week, $date $time';
  }

  @override
  String featuresDateWeekday(String date, String day) {
    return '$day, $date';
  }

  @override
  String featuresOnceDescription(String rule, String date, String time) {
    return '$rule · $date $time';
  }

  @override
  String featuresCronMonthSuffix(String months) {
    return ' ($months)';
  }

  @override
  String featuresRuleIntervalSeconds(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Every $count seconds',
      one: 'Every second',
    );
    return '$_temp0';
  }

  @override
  String featuresRuleIntervalMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Every $count minutes',
      one: 'Every minute',
    );
    return '$_temp0';
  }

  @override
  String featuresRuleIntervalHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'Every $count hours', one: 'Every hour');
    return '$_temp0';
  }

  @override
  String featuresSchedulesActiveCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'Active $count', one: 'Active 1');
    return '$_temp0';
  }

  @override
  String featuresSchedulesEndedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'Ended $count', one: 'Ended 1');
    return '$_temp0';
  }

  @override
  String featuresScheduleRetention(int days, int count) {
    String _temp0 = intl.Intl.pluralLogic(days, locale: localeName, other: 'Last $days days', one: 'Last 1 day');
    String _temp1 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'up to $count entries',
      one: 'up to 1 entry',
    );
    return '$_temp0, $_temp1';
  }

  @override
  String featuresScheduleRetentionUnknown(int days) {
    String _temp0 = intl.Intl.pluralLogic(days, locale: localeName, other: 'Last $days days', one: 'Last 1 day');
    return '$_temp0, entry limit unavailable';
  }

  @override
  String featuresArtifactsDeliveredTurn(int turn) {
    return 'Turn $turn · Delivered';
  }

  @override
  String featuresArtifactsGeneratedTurn(int turn) {
    return 'Turn $turn · Generated';
  }

  @override
  String featuresPresetCreateRequest(String name, String id, String directory) {
    return 'Create agent preset “$name” ($id): Write these two files verbatim in the workspace, then use plugin_manager’s install_bundle to install the `$directory` directory. Do only this.\n\n';
  }

  @override
  String featuresPresetUpdateRequest(String name, String id, String replacing, String directory) {
    return 'Update agent preset “$name” ($id): Write these two files verbatim in the workspace. Use plugin_manager to remove bundle `$replacing`, then use install_bundle to install the `$directory` directory. Do only this.\n\n';
  }

  @override
  String featuresZoneThisPhone(String city) {
    return '$city · This phone';
  }

  @override
  String get featuresPermissionResetHint => 'The new-chat default is no longer valid';

  @override
  String get featuresPermissionResetDefault => 'Restore default';

  @override
  String get fileImageName => 'image';

  @override
  String get fileSharedText => 'Shared text.txt';

  @override
  String get fileChatFallback => 'chat';

  @override
  String get fileUploadToHost => 'Send files to the computer';

  @override
  String get fileUploadToHostHint => 'Into this conversation’s workspace on the computer, uncompressed';

  @override
  String fileUploadProgress(int done, int total, String name) {
    return 'Sending $done/$total: $name';
  }

  @override
  String fileUploadDone(String names) {
    return 'Sent to the computer: $names';
  }

  @override
  String get fileUploadFailed => 'Couldn’t send to the computer';

  @override
  String get hostDetailsConnectionType => 'Connection type';

  @override
  String get hostDetailsSshNetworkHint =>
      'Uses an SSH tunnel. LAN / P2P route inspection and latency measurements are not available for this connection.';

  @override
  String get hubSessionDetails => 'Chat details';

  @override
  String get hubTerminal => 'Terminal';

  @override
  String get hubSessionNoTurns => 'No complete turns yet';

  @override
  String get hubSessionElapsed => 'Time';

  @override
  String get hubSessionSteps => 'Steps';

  @override
  String get hubSessionChangedFiles => 'Files changed';

  @override
  String get hubSessionTrajectoryHint => 'Steps and time for each turn appear here';

  @override
  String get hubSessionLoadEarlier => 'Load earlier turns';

  @override
  String get hubSessionError => 'Error';

  @override
  String get hubSessionInterrupted => 'Interrupted';

  @override
  String get hubSessionOutputLimit => 'Output limit reached';

  @override
  String get hubSessionNoChanges => 'No files changed yet';

  @override
  String get hubSessionShellChangesHint => 'Files changed with shell commands aren’t shown here';

  @override
  String get hubSessionChanges => 'Chat changes';

  @override
  String get hubSessionChangesNote => 'Only changes made with write and edit tools in loaded history are included';

  @override
  String get hubSessionNoGoal => 'No goal or to-dos yet';

  @override
  String get hubSessionGoalHint => 'AI lists to-dos for complex tasks. Follow their progress here';

  @override
  String get hubSessionGoal => 'Goal';

  @override
  String get hubSessionPlanMode => 'Plan mode';

  @override
  String get hubSessionPlanSwitching => 'Switching plan mode';

  @override
  String get hubSessionPlanHint => 'AI plans first, without changing files';

  @override
  String get hubSessionTodos => 'To-dos';

  @override
  String get hubSessionNotStarted => 'Not started';

  @override
  String get hubSessionTurnUsage => 'Usage by turn';

  @override
  String get hubSessionNoSubagents => 'No subagents sent';

  @override
  String get hubSessionDelegations => 'Delegation history';

  @override
  String get hubTabTrajectory => 'Trajectory';

  @override
  String get hubTabChanges => 'Changes';

  @override
  String get hubTabFiles => 'Files';

  @override
  String get hubTabProgress => 'Progress';

  @override
  String get hubTabContext => 'Context';

  @override
  String get hubTabSubagents => 'Subagents';

  @override
  String get hubPlugins => 'Plugins';

  @override
  String get hubSettingsFullAccessTitle => 'Turn on Full access?';

  @override
  String get hubSettingsFullAccessBody => 'AI won’t ask before running commands or changing files.';

  @override
  String get hubSettingsStorageTitle => 'Let AI access phone files?';

  @override
  String get hubSettingsStorageAllow => 'Allow access';

  @override
  String get hubSettingsStorageDenied =>
      'Storage access wasn’t granted. Allow “All files access” for DSH Go in system settings, then try again.';

  @override
  String get hubSettingsRestartRequired => 'Takes effect after restarting the engine';

  @override
  String get hubSettingsRestartNow => 'Restart now';

  @override
  String get hubSettingsInterface => 'Interface';

  @override
  String get hubSettingsChat => 'Chat';

  @override
  String get hubSettingsAutoCommands => 'Auto-run commands';

  @override
  String get hubSettingsPhoneFiles => 'Access phone files';

  @override
  String get hubSettingsPhoneFilesHint => 'AI can read and write phone storage';

  @override
  String get hubSettingsVisualReplies => 'Visual replies';

  @override
  String get hubSettingsVisualRepliesHint => 'Charts, comparisons and tappable options';

  @override
  String get hubSettingsPhoneControl => 'Phone control';

  @override
  String get hubSettingsPhoneControlHint => 'See your screen and tap for you';

  @override
  String get hubSettingsPreferences => 'Personal preferences';

  @override
  String get hubSettingsAppearance => 'Appearance';

  @override
  String get hubSettingsChatTextSize => 'Chat text size';

  @override
  String get hubSettingsCollapseSteps => 'Collapse steps when done';

  @override
  String get hubSettingsCollapseStepsHint => 'Fold thinking and tool calls into one line';

  @override
  String get hubSettingsWebPhoneLayout => 'Web phone layout';

  @override
  String get hubSettingsWebPhoneLayoutHint => 'Adapt DSH Web to phone screens';

  @override
  String get hubSettingsEngineExtensions => 'Engine and extensions';

  @override
  String get hubSettingsEngine => 'Local engine';

  @override
  String get hubSettingsProviders => 'Models';

  @override
  String get hubSettingsEngineSettings => 'Engine parameters';

  @override
  String get hubSettingsShareConfig => 'Share configuration';

  @override
  String get hubSettingsAllFeatures => 'All features';

  @override
  String get hubSettingsAbout => 'About';

  @override
  String get hubSettingsCommunity => 'Community';

  @override
  String get hubSettingsLicenses => 'Open-source licenses';

  @override
  String get hubSettingsAccount => 'DeepSeek account';

  @override
  String get hubSettingsSigningIn => 'Signing in…';

  @override
  String get hubSettingsInvalidKey => 'Invalid API key. Can’t check balance';

  @override
  String get hubSettingsNoApiKey => 'No API key set';

  @override
  String get hubSettingsApiKeyHint => 'Add an API key to start chatting';

  @override
  String get hubSettingsSignInAccount => 'Sign in to DeepSeek';

  @override
  String get hubSettingsOrApiKey => 'Or add an API key';

  @override
  String get hubPluginShare => 'Share plugin';

  @override
  String get hubPluginDetails => 'Plugin details';

  @override
  String get hubPluginFeatured => 'Featured on dshfind';

  @override
  String get hubPluginWebOnly => 'Web only';

  @override
  String get hubPluginStars => 'Stars';

  @override
  String get hubPluginSource => 'Source';

  @override
  String get hubPluginInstalledVersion => 'Installed version';

  @override
  String get hubPluginRequiresDsh => 'Requires DSH';

  @override
  String get hubPluginPackageName => 'Package name';

  @override
  String get hubPluginHomepage => 'Homepage';

  @override
  String get hubPluginRepository => 'Repository';

  @override
  String get hubPluginManageTitle => 'Manage plugin';

  @override
  String get hubPluginManage => 'Manage';

  @override
  String get hubPluginSafeModeInstall => 'Can’t install in Safe mode';

  @override
  String get hubPluginInstallCommand => 'Get install command';

  @override
  String get hubPluginInstallComputer => 'Install on computer';

  @override
  String get hubPluginInstalling => 'Installing…';

  @override
  String get hubPluginAllowBuilds => 'Allow scripts and retry';

  @override
  String get hubPluginRetryInstall => 'Retry install';

  @override
  String get hubPluginOfficial => 'Official DSH';

  @override
  String get hubPluginNotLoaded => 'Couldn’t load';

  @override
  String get hubPluginComponents => 'Components';

  @override
  String get hubPluginSafeModeRemove => 'Can’t uninstall in Safe mode';

  @override
  String get hubPluginRemoveCommand => 'Get uninstall command';

  @override
  String get hubPluginRemoveComputer => 'Uninstall on computer';

  @override
  String get hubPluginUninstall => 'Uninstall';

  @override
  String hubSessionTurns(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count turns', one: '1 turn');
    return '$_temp0';
  }

  @override
  String hubSessionTurnsRunning(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count turns · In progress',
      one: '1 turn · In progress',
    );
    return '$_temp0';
  }

  @override
  String hubSessionStepCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count steps', one: '1 step');
    return '$_temp0';
  }

  @override
  String hubSessionWaitTime(String duration) {
    return 'Waited $duration for you';
  }

  @override
  String hubSessionTurn(int turn) {
    return 'Turn $turn';
  }

  @override
  String hubSessionFileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Changed $count files',
      one: 'Changed 1 file',
    );
    return '$_temp0';
  }

  @override
  String hubSessionEditCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'Edited $count times', one: 'Edited once');
    return '$_temp0';
  }

  @override
  String hubSessionTurnOf(int turn, int total) {
    return 'Turn $turn / $total';
  }

  @override
  String hubSessionCacheHit(String percent) {
    return '$percent cached';
  }

  @override
  String get hubSessionBlocked => 'Blocked';

  @override
  String hubSessionBlockedReason(String reason) {
    return 'Blocked: $reason';
  }

  @override
  String hubSessionTodoSemantics(String content, String status) {
    return '$content, $status';
  }

  @override
  String get hubSettingsStorageBody =>
      'AI can read and change your photos, downloads and documents. The engine restarts once.';

  @override
  String hubSettingsBalance(String amount) {
    return 'Balance $amount';
  }

  @override
  String hubSettingsBalanceLow(String amount) {
    return 'Balance $amount · Low balance';
  }

  @override
  String hubSettingsAccountSemantics(String title, String subtitle) {
    return 'Account: $title, $subtitle';
  }

  @override
  String hubSettingsHostSemantics(String name, String status) {
    return 'Remote host: $name, $status';
  }

  @override
  String get hubSettingsApiKey => 'DeepSeek API key';

  @override
  String hubPluginBrowserFailed(String address) {
    return 'Couldn’t open the browser. Visit $address manually';
  }

  @override
  String hubPluginYearMonth(int year, String month) {
    String _temp0 = intl.Intl.selectLogic(month, {
      '1': 'Jan',
      '2': 'Feb',
      '3': 'Mar',
      '4': 'Apr',
      '5': 'May',
      '6': 'Jun',
      '7': 'Jul',
      '8': 'Aug',
      '9': 'Sep',
      '10': 'Oct',
      '11': 'Nov',
      '12': 'Dec',
      'other': '$month',
    });
    return '$_temp0 $year';
  }

  @override
  String hubPluginUpdateTo(String version) {
    return 'Update to $version';
  }

  @override
  String hubPluginInstallOn(String host) {
    return 'Install on $host';
  }

  @override
  String hubPluginComponentCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count components', one: '1 component');
    return '$_temp0';
  }

  @override
  String get hubPluginComponentSeparator => ', ';

  @override
  String get hubGroupAi => 'AI';

  @override
  String get hubGroupCapabilities => 'Capabilities';

  @override
  String get hubGroupGeneral => 'General';

  @override
  String get hubGroupHosts => 'Hosts';

  @override
  String get hubGroupHelp => 'Help and about';

  @override
  String get hubPersonalization => 'Personalization';

  @override
  String get hubPersonalizationAboutYou => 'About you';

  @override
  String get hubPersonalizationReplies => 'Replies';

  @override
  String get hubPersonalizationWorkStyle => 'Working style';

  @override
  String get hubPrivacy => 'Privacy and sharing';

  @override
  String get hubPrivacySharing => 'Sharing';

  @override
  String get hubInterfaceHome => 'Home';

  @override
  String get hubInterfaceWebHint => 'DSH\'s own web app';

  @override
  String get hubInterfaceOpenWeb => 'Open the web app';

  @override
  String get hubInterfacePhoneLayout => 'Phone layout';

  @override
  String get hubTableTint => 'Table tint';

  @override
  String get hubTableTintFollow => 'Theme';

  @override
  String get hubTableTintFill => 'Tinted';

  @override
  String get hubTableTintNone => 'Plain';

  @override
  String get hubTableTintFillHint => 'Alternating rows, easier to scan long tables';

  @override
  String get hubTableTintFollowHint => 'Header tint only, body follows the reply';

  @override
  String get hubTableTintNoneHint => 'Grid lines only, the lightest';

  @override
  String get hubAbout => 'About DSH Go';

  @override
  String get hubAboutAuthor => 'Original author of DSH Go';

  @override
  String get hubAboutBilibili => 'Bilibili profile';

  @override
  String get hubAboutX => 'X profile';

  @override
  String get hubAboutGithub => 'GitHub profile';

  @override
  String get hubAboutNewVersion => 'Update available';

  @override
  String get hubValueSet => 'Set';

  @override
  String get hubValueOff => 'Off';

  @override
  String get hubValueOneStep => 'One step left';

  @override
  String get hubValueAllowed => 'Allowed';

  @override
  String get hubValueNeedsSetup => 'Set up';

  @override
  String hubValueHosts(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count hosts', one: '1 host');
    return '$_temp0';
  }

  @override
  String get hubValueNoHosts => 'None';

  @override
  String hubValuePlugins(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count plugins', one: '1 plugin');
    return '$_temp0';
  }

  @override
  String get hubEngineStartup => 'Startup';

  @override
  String get hubThemeLightDark => 'Light and dark';

  @override
  String get hubPermissionPhone => 'Phone';

  @override
  String get hubPermissionPhoneConfirm => 'Phone control confirmation';

  @override
  String get hubHardwareEnterSends => 'Send with hardware Enter';

  @override
  String get hubHardwareEnterSendsHint =>
      'When on, Shift+Enter inserts a new line. The on-screen keyboard keeps newlines; Ctrl/⌘+Enter always sends.';

  @override
  String get hubQuickPanel => 'Swipe-left shortcuts';

  @override
  String get hubQuickPanelSwipe => 'Open with a left swipe';

  @override
  String get hubQuickPanelSwipeHint =>
      'Swipe right to left over the chat. Code blocks, tables and other content that scrolls sideways aren’t affected.';

  @override
  String get hubQuickPanelItems => 'What it lists';

  @override
  String get hubQuickPanelItemsNone => 'Nothing chosen: a left swipe won\'t open it';

  @override
  String get launchScreenTitle => 'Launch screen';

  @override
  String get launchDefault => 'Default';

  @override
  String get launchCustom => 'Custom';

  @override
  String get launchFit => 'Fit';

  @override
  String get launchFitFill => 'Fill';

  @override
  String get launchFitCenter => 'Center';

  @override
  String get launchFrame => 'Reposition';

  @override
  String get launchBackground => 'Background';

  @override
  String get launchBackdropAuto => 'Auto';

  @override
  String get launchBackdropEdge => 'From picture';

  @override
  String get launchBackdropWhite => 'White';

  @override
  String get launchBackdropBlack => 'Black';

  @override
  String get launchReplace => 'Replace picture or video';

  @override
  String get launchPreview => 'Preview';

  @override
  String get launchFooter =>
      'Pictures and animations up to 8 MB, videos up to 30 MB. Plays through once on a cold start; tap to skip.';

  @override
  String get launchChanged => 'Launch screen changed';

  @override
  String launchChangedSize(String size) {
    return 'Launch screen changed · $size';
  }

  @override
  String get launchTooLarge => 'The picture is over 8 MB';

  @override
  String get launchOverLimit => 'The file is over 30 MB';

  @override
  String get launchUnsupported => 'Use a PNG, JPEG, WebP, GIF or MP4';

  @override
  String get launchUnreadable => 'Couldn’t read this file';

  @override
  String get launchUnavailable => 'Couldn’t open your photos';

  @override
  String get launchBroken => 'Can’t be read';

  @override
  String get iconShortcutRow => 'Picture shortcut';

  @override
  String get iconShortcutRowSubtitle => 'Your own picture on the home screen';

  @override
  String get iconShortcutPick => 'Choose a picture';

  @override
  String get iconShortcutChange => 'Another picture';

  @override
  String get iconShortcutHint => 'Drag or pinch to fit';

  @override
  String get iconShortcutName => 'Name';

  @override
  String get iconShortcutAdd => 'Add to home screen';

  @override
  String get iconShortcutNote =>
      'Android doesn’t let an app use any picture as its icon, so this adds a separate shortcut that opens DSH Go. Some home screens put a small badge on its corner.';

  @override
  String get iconShortcutAdded => 'Added to your home screen';

  @override
  String get iconShortcutConfirm => 'Confirm in the dialog that appears';

  @override
  String get iconShortcutNoDialog => 'No dialog? Allow DSH Go to create home screen shortcuts in system settings.';

  @override
  String get iconShortcutSettings => 'Settings';

  @override
  String get iconShortcutUnsupported => 'This home screen doesn’t take shortcuts';

  @override
  String get iconShortcutFailed => 'Couldn’t add it. Try again later.';

  @override
  String get searchKwLaunchScreen => 'splash,startup,launch animation,opening screen';

  @override
  String get searchKwIconShortcut => 'shortcut,custom icon,home screen picture';

  @override
  String get liveThinking => 'Thinking';

  @override
  String get liveWorking => 'Working';

  @override
  String get liveJuggling => 'Subagents at work';

  @override
  String get liveSweeping => 'Compacting the context';

  @override
  String liveRunsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count chats running',
      one: '1 chat running',
    );
    return '$_temp0';
  }

  @override
  String get liveChipThinking => 'Thinking';

  @override
  String get liveChipWorking => 'Working';

  @override
  String get liveChipJuggling => 'Helpers';

  @override
  String get liveChipSweeping => 'Tidying';

  @override
  String get liveChipApproval => 'Approve';

  @override
  String get liveChipQuestion => 'Reply';

  @override
  String get liveChipDone => 'Done';

  @override
  String get liveChipFailed => 'Failed';

  @override
  String get livePublicRunning => 'DSH is working';

  @override
  String get livePublicWaiting => 'DSH is waiting for you';

  @override
  String get livePublicDone => 'DSH is done';

  @override
  String get livePublicFailed => 'DSH ran into an error';

  @override
  String get liveSettingsTitle => 'Live activity';

  @override
  String get liveSettingsSwitch => 'Show live activity';

  @override
  String get liveSettingsSubtitle =>
      'While DSH works, waits on you or controls the phone: in the status bar chip and on the lock screen, and in the island on phones that have one';

  @override
  String get liveSettingsFooter =>
      'Android 16 Live Updates. Shown on Xiaomi HyperOS 3.1+, OPPO / OnePlus ColorOS 16, Honor MagicOS 10 and Pixel; vivo\'s Atomic Island and Samsung\'s Now Bar are open only to apps the maker partners with.';

  @override
  String get liveUnsupported => 'This phone\'s system doesn\'t support live activities yet';

  @override
  String get liveBlockedTitle => 'Live activities are off for DSH Go';

  @override
  String get liveBlockedText =>
      'Turn on live activities for DSH Go in system settings (some phones call it “Show on Live Alerts”)';

  @override
  String get localeTitle => 'Language';

  @override
  String get localeSystem => 'System';

  @override
  String get localeZh => '简体中文';

  @override
  String get localeEn => 'English';

  @override
  String get localEnvChooseTitle => 'Where should DSH run?';

  @override
  String get localEnvChooseMessage => 'You can change this later in Settings';

  @override
  String localEnvThisPhoneDetail(int storage, int memory) {
    return '$storage MB storage · $memory MB memory';
  }

  @override
  String localEnvThisPhoneDetailShort(int memory) {
    return '$memory MB memory while running';
  }

  @override
  String localEnvLowStorage(int needed) {
    return 'Needs about $needed MB free';
  }

  @override
  String get localEnvRemoteDetail => 'Use DSH on your computer or server';

  @override
  String get localEnvRecommended => 'Recommended';

  @override
  String get localEnvInstallTitle => 'Install on this phone';

  @override
  String get localEnvInstallMessage => 'Run DSH right on this phone';

  @override
  String localEnvFactStorage(int storage) {
    return 'About $storage MB of storage';
  }

  @override
  String localEnvFactMemory(int memory) {
    return 'About $memory MB of memory while running';
  }

  @override
  String get localEnvUseRemote => 'Use a remote host instead';

  @override
  String get localEnvNotInstalled => 'Not installed on this phone';

  @override
  String get localEnvUninstall => 'Uninstall runtime';

  @override
  String get localEnvUninstallHint => 'Free up storage';

  @override
  String get localEnvUninstallTitle => 'Uninstall the runtime?';

  @override
  String get localEnvUninstallBody =>
      'Chats, workspaces, plugins, settings, interface settings and skills on this phone will be deleted.';

  @override
  String get localEnvUninstallConfirm => 'Uninstall';

  @override
  String get localEnvUninstallFailed => 'Couldn’t uninstall. Try again.';

  @override
  String get localEnvPhoneNeedsRuntime => 'Available after installing on this phone';

  @override
  String get localEnvSignInNeedsRuntime => 'Needs DSH on this phone';

  @override
  String get localEnvSignInInstallFirst => 'Install it to sign in';

  @override
  String get marketSectionOfficial => 'Official';

  @override
  String get marketSectionAdapted => 'Made for DSH Go';

  @override
  String get marketSectionAll => 'All';

  @override
  String get marketSectionLoading => 'Loading…';

  @override
  String get marketSectionFailed => 'The official catalogue didn\'t load';

  @override
  String get marketSectionEmpty => 'None yet';

  @override
  String get marketTierOfficial => 'Official';

  @override
  String get marketTierAdapted => 'Made for DSH Go';

  @override
  String get marketRiskMedium => 'Medium risk';

  @override
  String get marketRiskHigh => 'High risk';

  @override
  String get marketFlagInstallScripts => 'Runs install scripts';

  @override
  String get marketFlagInstallScriptsBody =>
      'Runs the package\'s own scripts while installing (preinstall, install or postinstall)';

  @override
  String get marketFlagNativeCode => 'Native code';

  @override
  String get marketFlagNativeCodeBody =>
      'Contains compiled native code (.node, binding.gyp or binaries) that can\'t be read as source';

  @override
  String get marketFlagShell => 'Runs commands';

  @override
  String get marketFlagShellBody => 'Its code runs system commands (child_process)';

  @override
  String get marketFlagNetwork => 'Network access';

  @override
  String get marketFlagNetworkBody => 'Its code makes network requests (fetch, http, WebSocket)';

  @override
  String get marketFlagFilesystem => 'Writes outside the workspace';

  @override
  String get marketFlagFilesystemBody => 'Writes to paths outside the workspace';

  @override
  String get marketFlagObfuscated => 'Hard to review';

  @override
  String get marketFlagObfuscatedBody => 'Has large minified or obfuscated files; hard to tell what they do';

  @override
  String get marketFlagNotAdapted => 'Not made for DSH Go';

  @override
  String get marketFlagNotAdaptedBody => 'Declares no DSH Go native protocol, so it has no native screens in the app';

  @override
  String get marketFlagOtherBody => 'Another trait the automatic checks reported';

  @override
  String get marketChecksTitle => 'Automatic checks';

  @override
  String get marketChecksClean => 'No risky traits found';

  @override
  String get marketChecksNote => 'Traits the automatic checks found; they don\'t mean the plugin is malicious';

  @override
  String marketCheckedOn(String date) {
    return 'Checked $date';
  }

  @override
  String marketScreenshot(int index) {
    return 'Screenshot $index';
  }

  @override
  String marketRiskConfirmTitle(String name) {
    return '$name has risky traits';
  }

  @override
  String get marketRiskConfirmAction => 'Install anyway';

  @override
  String get marketPinnedVersion => 'Pinned version';

  @override
  String get marketRequiresApp => 'Requires DSH Go';

  @override
  String marketNeedsApp(String version) {
    return 'Needs DSH Go $version or later';
  }

  @override
  String get marketUpdateAvailable => 'Update available';

  @override
  String get marketBlockedTitle => 'This version was withdrawn';

  @override
  String marketBlockedMessage(String version) {
    return 'The installed $version was withdrawn from the plugin market. Uninstalling it is recommended.';
  }

  @override
  String get marketBlockedRow => 'Withdrawn version: uninstall recommended';

  @override
  String get marketBlockedBadge => 'Withdrawn';

  @override
  String get marketVerifying => 'Checking the version…';

  @override
  String get marketMismatchTitle => 'Version check failed';

  @override
  String marketMismatchMessage(String version) {
    return '$version on npm isn\'t the package the plugin market checked. Nothing was installed.';
  }

  @override
  String get marketSubmit => 'Submit a plugin';

  @override
  String get marketSubmitHint => 'On GitHub; listed once the automatic checks pass';

  @override
  String marketLinkNotFound(String name) {
    return '$name isn\'t in the plugin market';
  }

  @override
  String get marketVerificationUnavailableTitle => 'Could not verify the version';

  @override
  String get marketVerificationUnavailableBody =>
      'npm did not return integrity information. Installation has not started. Check your connection and try again.';

  @override
  String marketCombinedCount(int count) {
    return '$count plugins';
  }

  @override
  String get mediaGenerateTile => 'Create';

  @override
  String get mediaAiGenerated => 'AI-generated';

  @override
  String mediaCostEstimate(String amount) {
    return 'About $amount';
  }

  @override
  String mediaSavedCount(int count) {
    return 'Saved $count to Photos';
  }

  @override
  String get mediaRegenerate => 'Regenerate';

  @override
  String get mediaCopyPrompt => 'Copy prompt';

  @override
  String get mediaFileGone => 'File is gone';

  @override
  String get mediaKindImage => 'Image';

  @override
  String get mediaKindVideo => 'Video';

  @override
  String get mediaTitleImage => 'New image';

  @override
  String get mediaTitleVideo => 'New video';

  @override
  String get mediaOpenElsewhere => 'Open in another app';

  @override
  String get mediaShowInFiles => 'Show in files';

  @override
  String get mediaGenerating => 'Generating';

  @override
  String mediaGeneratingProgress(String progress) {
    return 'Generating · $progress';
  }

  @override
  String get mediaCancelled => 'Cancelled';

  @override
  String get mediaNotGenerated => 'Not created';

  @override
  String mediaPartial(int done, int total) {
    return '$done of $total';
  }

  @override
  String mediaCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count images', one: '1 image');
    return '$_temp0';
  }

  @override
  String mediaSeconds(int seconds) {
    return '$seconds s';
  }

  @override
  String mediaImageOf(int index, int count) {
    return 'Image $index of $count';
  }

  @override
  String mediaPageOf(int index, int count) {
    return '$index / $count';
  }

  @override
  String get mediaErrorPolicyInput => 'The description didn\'t pass content review';

  @override
  String get mediaErrorPolicyOutput => 'The result didn\'t pass content review';

  @override
  String get mediaErrorAuth => 'Service not authorized';

  @override
  String get mediaErrorBalance => 'Insufficient balance';

  @override
  String get mediaErrorQuota => 'Today\'s limit is used up';

  @override
  String get mediaErrorUnavailable => 'Service unavailable for now';

  @override
  String get mediaErrorExpired => 'The result expired';

  @override
  String get mediaErrorGeneric => 'Couldn\'t create it';

  @override
  String get mediaVary => 'Vary';

  @override
  String get mediaEdit => 'Edit';

  @override
  String get mediaRevise => 'Revise';

  @override
  String get mediaUpscale => 'Upscale';

  @override
  String get mediaMakeVideo => 'Make a video';

  @override
  String get mediaDetailModel => 'Model';

  @override
  String get mediaDetailSize => 'Size';

  @override
  String get mediaDetailCost => 'Cost';

  @override
  String get mediaDetailProvenance => 'Provenance';

  @override
  String get mediaDetailFile => 'File';

  @override
  String mediaOriginalPrompt(String text) {
    return 'Original: $text';
  }

  @override
  String get mediaProvenanceC2pa => 'C2PA';

  @override
  String get mediaProvenanceImplicit => 'Embedded';

  @override
  String get mediaProvenanceVisible => 'Visible mark';

  @override
  String get mediaModeExit => 'Leave create mode';

  @override
  String mediaModeLabel(String summary) {
    return 'Create settings: $summary';
  }

  @override
  String get mediaParamModel => 'Model';

  @override
  String get mediaParamAspect => 'Aspect';

  @override
  String get mediaParamCount => 'Number';

  @override
  String get mediaParamQuality => 'Quality';

  @override
  String get mediaParamDuration => 'Length';

  @override
  String get mediaQualityAuto => 'Auto';

  @override
  String get mediaQualityStandard => 'Standard';

  @override
  String get mediaQualityHigh => 'HD';

  @override
  String get mediaQuality4k => '4K';

  @override
  String get mediaQualityLevelLow => 'Low';

  @override
  String get mediaQualityLevelMedium => 'Medium';

  @override
  String get mediaQualityLevelHigh => 'High';

  @override
  String get mediaModelPick => 'Choose';

  @override
  String get mediaPickModelFirst => 'Choose a model first';

  @override
  String mediaPricePerImage(String price) {
    return '$price / image';
  }

  @override
  String mediaPricePerSecond(String price) {
    return '$price / s';
  }

  @override
  String get mediaManageModels => 'Manage';

  @override
  String get mediaHintImage => 'Describe the picture…';

  @override
  String get mediaHintVideo => 'Describe the scene and the shot…';

  @override
  String get mediaHintEdit => 'How should it change…';

  @override
  String get mediaFirstFrame => 'First';

  @override
  String get mediaLastFrame => 'Last';

  @override
  String get mediaNoLastFrame => 'This model takes no last frame';

  @override
  String get mediaNoRefs => 'This model takes no reference images';

  @override
  String mediaRefLimit(int count) {
    return 'Up to $count reference images';
  }

  @override
  String get mediaNoDescription => 'Describe it first';

  @override
  String get mediaDescriptionTooLong => 'Too long to generate. Shorten the description';

  @override
  String get mediaInstallTitle => 'Images and video';

  @override
  String get mediaInstallBody => 'This host has no image and video plugin yet';

  @override
  String get mediaInstallAction => 'Install on this host';

  @override
  String get mediaUnavailableTitle => 'Generation mode unavailable';

  @override
  String get mediaUnavailableBody =>
      'The image and video plugin on this host isn\'t compatible. You can still describe what you want in chat.';

  @override
  String get mediaUnavailableAction => 'Manage plugins';

  @override
  String get mediaSettingsTitle => 'Images and video';

  @override
  String get searchKwMediaGeneration =>
      'image generation,text to image,video generation,AI art,generate images,generate video';

  @override
  String get mediaSettingsDefaults => 'Defaults';

  @override
  String get mediaSettingsLegacyDefault => 'Older general default';

  @override
  String get mediaSettingsLegacyDefaultHint => 'The 0.2.x setting; used when a kind has no default of its own';

  @override
  String get mediaSettingsLegacyDefaultStale => 'Its service is unavailable; clear it so generation does not fail';

  @override
  String get mediaSettingsLegacyDefaultClear => 'Clear the older general default';

  @override
  String get mediaSettingsDefaultModel => 'Default model';

  @override
  String get mediaSettingsDefaultFooterLegacy =>
      'An older plugin has one default model; update it to set images and video separately.';

  @override
  String get mediaSettingsDefaultsFooter =>
      'Choose a default model for images and for video; leave it on Auto to use the first available one.';

  @override
  String get mediaSettingsNoVideoModels => 'This host\'s catalogue has no video models yet';

  @override
  String get mediaSettingsServices => 'Services';

  @override
  String get mediaSettingsAddService => 'Add service';

  @override
  String get mediaSettingsAddServiceHint =>
      'Start from a provider preset; endpoint, protocol and models come filled in';

  @override
  String mediaSettingsServiceLimit(int count) {
    return 'Up to $count services';
  }

  @override
  String get mediaSettingsNoServices => 'No services yet. Add a provider to start making images or video.';

  @override
  String get mediaSettingsNoModels => 'No models selected';

  @override
  String get mediaSettingsKeyMissing => 'No API key';

  @override
  String get mediaSettingsCatalogMissing =>
      'The plugin on this host offers no model catalogue. Existing services can still be edited, but nothing can be added and no default chosen yet.';

  @override
  String get mediaSettingsCatalogBroken =>
      'The model catalogue can\'t be read (it may be an incompatible version). Existing services can still be edited, but nothing can be added and no default chosen yet.';

  @override
  String get mediaSettingsCatalogEmpty =>
      'The model catalogue has no models yet. Existing services can still be edited, but nothing can be added and no default chosen yet.';

  @override
  String get mediaSettingsNoPresets => 'There are no services to add from this catalogue yet.';

  @override
  String get mediaSettingsLimits => 'Request limits';

  @override
  String get mediaSettingsLimitsHint => 'Caps images and bytes per request; defaults are the plugin hard limits';

  @override
  String get mediaSettingsMaxImages => 'Images per request';

  @override
  String get mediaSettingsMaxImageBytes => 'Max bytes per original';

  @override
  String get mediaSettingsMaxResponseBytes => 'Max provider response bytes';

  @override
  String get mediaSettingsMaxTotalImageBytes => 'Max image bytes per request';

  @override
  String get mediaSettingsMaxVideoBytes => 'Max video bytes';

  @override
  String get mediaSettingsBudget => 'Cost protection';

  @override
  String get mediaSettingsDailyBudget => 'Daily budget (CNY)';

  @override
  String get mediaSettingsDailyBudgetHint => 'Resets on the Shanghai date; generation pauses once it\'s used up';

  @override
  String get mediaSettingsUnknownPriceHold => 'Hold per request when the price is unknown (CNY)';

  @override
  String get mediaSettingsUnknownPriceHoldHint => 'Reserved per request; not a cap the provider charges by';

  @override
  String get mediaSettingsApiKey => 'API key';

  @override
  String get mediaSettingsReuseKey => 'Reuse key';

  @override
  String get mediaSettingsReuseKeyHint =>
      'Images and video from one provider can share one API key; no need to enter it again.';

  @override
  String get mediaSettingsReuseKeyNone => 'No other service from this provider yet.';

  @override
  String get mediaSettingsReuseKeyShared => 'Shared';

  @override
  String get mediaSettingsModels => 'Models';

  @override
  String get mediaSettingsModelsEmpty => 'The catalogue has no models for this protocol';

  @override
  String get mediaSettingsModelKeepOne => 'Keep at least one model';

  @override
  String get mediaSettingsModelMissing => 'Not in the catalogue';

  @override
  String get mediaSettingsAdvanced => 'Advanced';

  @override
  String get mediaSettingsBaseUrl => 'API base URL';

  @override
  String get mediaSettingsBaseUrlInvalid => 'The address must start with https://';

  @override
  String get mediaSettingsProvider => 'Provider id';

  @override
  String get mediaSettingsKeyRef => 'Credential name';

  @override
  String get mediaSettingsKeyRefInvalid => 'Use letters, digits and underscores only';

  @override
  String get mediaSettingsResponseFormat => 'Response format';

  @override
  String get mediaSettingsResponseFormatAuto => 'By protocol';

  @override
  String get mediaSettingsServiceId => 'Service ID';

  @override
  String get mediaSettingsServiceGone => 'This service is gone';

  @override
  String get mediaSettingsServiceGoneBody => 'It may have been removed elsewhere. Go back to add it again.';

  @override
  String get mediaSettingsDelete => 'Delete service';

  @override
  String mediaSettingsDeleteTitle(String name) {
    return 'Delete “$name”?';
  }

  @override
  String get mediaSettingsDeleteBody =>
      'Only this host\'s service entry is removed; the API key is kept. Defaults pointing at it are cleared too.';

  @override
  String get mediaSettingsNoImageModels => 'The catalogue has no image models yet';

  @override
  String get mediaSettingsNoAvailableService => 'No service is ready yet (add one and enter its key)';

  @override
  String get mediaSettingsNoImageService => 'No image service is ready yet (add one and enter its key)';

  @override
  String get mediaSettingsNoVideoService => 'No video service is ready yet (add one and enter its key)';

  @override
  String get mediaSettingsKeyExternal => 'Managed by another setting; only referenced here';

  @override
  String get mediaSettingsEnabledHint => 'Turns this service off for generation';

  @override
  String get mediaConfigKeySaved => 'Saved · not verified';

  @override
  String get mediaConfigKeyUnknown => 'Status unavailable';

  @override
  String get mediaConfigKeyNote =>
      'Key presence is reported by the host. Saving a key does not verify authentication or model access.';

  @override
  String mediaConfigConsumers(String services) {
    return 'Media services using this key: $services. Changing or removing it affects all of them; other host integrations may also use it.';
  }

  @override
  String get mediaConfigCheck => 'Check saved configuration';

  @override
  String get mediaConfigCheckNote =>
      'Local snapshot only; no provider request or generation charge. Does not verify the key, connectivity, balance, model access, or region. The host remains the authority on accepted settings.';

  @override
  String get mediaConfigCheckReady => 'No local configuration issues found';

  @override
  String get mediaConfigCheckMissingKey => 'The host has not reported a saved key.';

  @override
  String get mediaConfigCheckModels =>
      'No selected models, or some selected models are missing or use a different protocol.';

  @override
  String get mediaConfigCheckDisabled => 'This service is switched off.';

  @override
  String get mediaConfigUrlInvalid =>
      'Enter an HTTPS API root with a host, without credentials, query, fragment, or whitespace.';

  @override
  String get mediaConfigUrlEndpoint =>
      'This looks like a request endpoint. Enter the API root instead; the host appends the request path.';

  @override
  String get mediaConfigUrlRoot => 'This protocol needs the origin only (https://host), without an API path.';

  @override
  String get mediaConfigUrlHint =>
      'Enter the API root, not a generation endpoint. OpenAI-compatible roots keep their prefix (for example /v1).';

  @override
  String get mediaConfigPreview => 'Create request preview';

  @override
  String get mediaConfigPreviewNote =>
      'Generation/create request only; edits and status requests may use different paths. Preview is not proof of connectivity or host acceptance.';

  @override
  String get mediaConfigPreviewUnavailable => 'Request path unavailable in this host catalogue.';

  @override
  String get mediaConfigTargetTitle => 'Reuse key at a different target?';

  @override
  String mediaConfigTargetBody(String before, String after) {
    return 'Target changes from $before to $after. Future requests may send the referenced key to the new target. Only continue if you trust it. The host still validates the change.';
  }

  @override
  String get mediaConfigTargetConfirm => 'Trust target and continue';

  @override
  String get mediaVideoLoading => 'Loading video…';

  @override
  String get mediaVideoCannotPlay => 'This video could not be played here. Retry or open it in another app.';

  @override
  String get mediaVideoPlay => 'Play';

  @override
  String get mediaVideoPause => 'Pause';

  @override
  String get mediaVideoSaveFailed => 'Couldn’t save the video. Try again.';

  @override
  String get mediaImageLoading => 'Loading image';

  @override
  String get mediaImageReload => 'Reload image';

  @override
  String get mediaImageReloadHint => 'Reads the file again; does not generate again or incur generation charges';

  @override
  String get mediaVideoNoPoster => 'Tap to play video';

  @override
  String mediaSavedFilesCount(int count) {
    return 'Saved $count files to gallery';
  }

  @override
  String get modeSheetTitle => 'Mode';

  @override
  String get modeKeyTooltip => 'Switch mode';

  @override
  String get modeWork => 'Work';

  @override
  String get modeWorkSubtitle => 'Get things done with DSH';

  @override
  String get modeCompanionShort => 'Companion';

  @override
  String get modeTavernSubtitle => 'Import a character card and start a story';

  @override
  String get modeStartup => 'Open on launch';

  @override
  String get nearbyThisChat => 'This chat';

  @override
  String get nearbyPermissionTitle => 'Permissions for this chat';

  @override
  String nearbyNewChatDefault(String name) {
    return 'New chats: $name';
  }

  @override
  String get nearbySetAsDefault => 'Use for new chats';

  @override
  String get nearbyManageModels => 'Manage models';

  @override
  String nearbyPermissionPill(String name) {
    return 'Permissions for this chat: $name';
  }

  @override
  String get nearbyChange => 'Change';

  @override
  String get performanceTitle => 'Performance';

  @override
  String get performanceAuto => 'Auto';

  @override
  String get performanceFull => 'Full';

  @override
  String get performanceLight => 'Light';

  @override
  String get performanceAutoHint => 'Adjust default effects for this device';

  @override
  String get performanceFullHint => 'Keep blur and animation';

  @override
  String get performanceLightHint => 'Reduce ongoing effects and resource use';

  @override
  String get performanceChoiceHint => 'Your pet and engine choices take priority';

  @override
  String get performanceCooling => 'Reducing effects until the device cools';

  @override
  String get performanceEffects => 'Interface effects';

  @override
  String get performanceBlur => 'Glass blur';

  @override
  String get performanceAnimations => 'Interface animation';

  @override
  String get performanceSystemMotion => 'Also follows the system\'s remove animations setting';

  @override
  String get performanceFluid => 'Fluid motion';

  @override
  String get performanceFluidHint =>
      'Springy releases, a soft glow under your finger, cards that open into pages. Costs almost no battery';

  @override
  String get performanceFollowMode => 'Follow the performance mode';

  @override
  String get performanceRemoteHint => 'Connect to a computer or server to reduce work on this phone';

  @override
  String get performanceRefresh => 'Refresh rate';

  @override
  String get performanceRefreshMax => 'Max';

  @override
  String get performanceRefreshSystem => 'System';

  @override
  String get performanceRefreshHint =>
      'Auto: fastest while drawing, handed back when still; System: the system decides.';

  @override
  String get searchKwRefreshRate => 'refresh rate high refresh 120Hz 90Hz smooth';

  @override
  String get petActionSending => 'Sending…';

  @override
  String get petActionTargetChanged => 'Host changed. Reopen Quick ask; your text is kept.';

  @override
  String get petActionSendFailed => 'Couldn’t send. Your text is kept; try again.';

  @override
  String get petActionBusy => 'This chat is busy. Choose New chat.';

  @override
  String get petActionVoiceMissing => 'Download the offline voice model in the app first.';

  @override
  String get petActionVoiceTitle => 'Voice for Quick ask';

  @override
  String get petActionVoiceReturn => 'Back to pet';

  @override
  String get petActionVoiceStop => 'Finish recording';

  @override
  String get petActionVoiceStart => 'Record';

  @override
  String get phoneDiagnosticsCollecting => 'Collecting…';

  @override
  String get phoneDiagnosticsPacking => 'Packing…';

  @override
  String get phoneDiagnosticsSharing => 'Opening share sheet…';

  @override
  String get phoneDiagnosticsSaving => 'Saving to Downloads…';

  @override
  String get phoneDiagnosticsShare => 'Share diagnostics bundle';

  @override
  String get phoneDiagnosticsShareHint => 'Attach to a bug report';

  @override
  String get phoneDiagnosticsSave => 'Save to Downloads';

  @override
  String get phoneDiagnosticsSaveHint => 'Save in Downloads/DSH-Go';

  @override
  String get phoneDiagnosticsNote =>
      'Includes versions, device info, logs and the latest crash. No API keys or tokens.';

  @override
  String get phoneDiagnosticsExport => 'Export diagnostics bundle';

  @override
  String get phoneSafeMode => 'Safe mode';

  @override
  String get phoneEngineStartingSafeEllipsis => 'Starting in Safe mode…';

  @override
  String get phoneEngineStartingEllipsis => 'Starting…';

  @override
  String get phoneEngineTidyingFilesEllipsis => 'Tidying plugin files…';

  @override
  String get phoneEngineStoppingEllipsis => 'Stopping…';

  @override
  String get phoneEngineStoppedNextSafe => 'Stopped · Next start in Safe mode';

  @override
  String get phoneEngineInstallingRuntime => 'Installing runtime…';

  @override
  String get phoneEngineRuntimeNotInstalled => 'Runtime not installed';

  @override
  String get phoneEngineErrorSeeLogs => 'Engine error. See logs for details.';

  @override
  String get phoneEngineTitle => 'Local engine';

  @override
  String get phoneEngineLocal => 'This phone’s engine';

  @override
  String get phoneEngineLogs => 'Logs';

  @override
  String get phoneEngineAutoStart => 'Start when DSH Go opens';

  @override
  String get phoneEngineKeepAlive => 'Background running';

  @override
  String get phoneEngineKeepAliveHint => 'Prevent Android from stopping the engine';

  @override
  String get phoneEngineDiagnostics => 'Diagnostics';

  @override
  String get phoneEngineDiagnosticsHint => 'Runtime info and bug reports';

  @override
  String get phoneEngineRuntime => 'Runtime';

  @override
  String get phoneEngineArchitecture => 'Architecture';

  @override
  String get phoneEngineStopTitle => 'Stop the engine?';

  @override
  String get phoneEngineStopBody => 'Active chats will be interrupted. You can start it again anytime.';

  @override
  String get phoneEngineInstallRuntime => 'Install runtime';

  @override
  String get phoneEngineStartAgain => 'Start again';

  @override
  String get phoneEngineStart => 'Start';

  @override
  String get phoneEngineRestart => 'Restart';

  @override
  String get phoneEngineResetFailed => 'Couldn’t reset';

  @override
  String get phoneEngineReset => 'Reset runtime';

  @override
  String get phoneEngineResetHint => 'Delete chats and files, then extract again';

  @override
  String get phoneEngineResetTitle => 'Reset the runtime?';

  @override
  String get phoneResetAlsoDeletes =>
      'Anything else in the home folder (/root) goes too, including files in your workspaces, AGENTS.md and data that plugins store themselves, such as memories.';

  @override
  String get phoneEngineKeepUiSkills => 'Keep interface settings and skills';

  @override
  String get phoneEngineKeepPluginsSettings => 'Keep installed plugins and settings';

  @override
  String get phoneEngineDeleteReset => 'Delete and reset';

  @override
  String get phoneEngineNotInstalled => 'Not installed';

  @override
  String get phoneEngineInstalling => 'Installing';

  @override
  String get phoneEngineStoppedSafe => 'Stopped · Safe mode';

  @override
  String get phoneEngineStartingSafe => 'Starting in Safe mode';

  @override
  String get phoneEngineStarting => 'Starting';

  @override
  String get phoneEngineTidyingFiles => 'Tidying plugin files';

  @override
  String get phoneEngineRunningProbation => 'Running · Trial';

  @override
  String get phoneEngineStartupFailed => 'Couldn’t start';

  @override
  String get phoneEngineCrashed => 'Crashed';

  @override
  String get phoneEngineKilled => 'Stopped by Android';

  @override
  String get phoneEngineError => 'Something went wrong';

  @override
  String get phoneEngineRuntimeCorrupt => 'The bundled runtime is damaged. Reinstall DSH.';

  @override
  String get phoneEngineExited => 'The engine quit unexpectedly';

  @override
  String get phoneEngineRuntimeMissing => 'The runtime isn’t installed yet';

  @override
  String get phoneEngineSafeUnsupported => 'This runtime doesn’t support Safe mode. Update DSH.';

  @override
  String get phoneEngineRuntimeIncomplete => 'The bundled runtime is incomplete. Reinstall DSH.';

  @override
  String get phoneLogEmpty => 'No logs yet';

  @override
  String get phoneLogShareTitle => 'DSH engine logs';

  @override
  String get phoneLogCopyAll => 'Copy all';

  @override
  String get phoneBackgroundAllow => 'Allow access';

  @override
  String get phoneToolScreen => 'Read screen';

  @override
  String get phoneToolCollect => 'Scroll and collect';

  @override
  String get phoneToolTap => 'Tap';

  @override
  String get phoneToolType => 'Type';

  @override
  String get phoneToolScroll => 'Swipe';

  @override
  String get phoneToolKey => 'Press key';

  @override
  String get phoneToolTapCoordinates => 'Tap coordinates';

  @override
  String get phoneToolHandoff => 'Hand back to you';

  @override
  String get phoneToolOpenApp => 'Open app';

  @override
  String get phoneToolListApps => 'View apps';

  @override
  String get phoneToolIntent => 'System action';

  @override
  String get phoneToolNotify => 'Send notification';

  @override
  String get phoneToolClipboard => 'Clipboard';

  @override
  String get phoneToolAction => 'Action';

  @override
  String get phoneDecisionContinued => 'You continued';

  @override
  String get phoneDecisionDone => 'Executed';

  @override
  String get phoneDecisionAllowed => 'You allowed it';

  @override
  String get phoneDecisionPauseExpired => 'Paused too long';

  @override
  String get phoneDecisionBlocked => 'Blocked';

  @override
  String get phoneDecisionTimeout => 'Timed out';

  @override
  String get phoneDecisionUnavailable => 'Unavailable';

  @override
  String get phoneDecisionScreenChanged => 'Screen changed';

  @override
  String get phoneDecisionFailed => 'Didn’t work';

  @override
  String get phoneActionLogTitle => 'Action log';

  @override
  String get phoneActionLogSubtitle => 'Records actions, never screen contents';

  @override
  String get phoneActionLogRefresh => 'Refresh';

  @override
  String get phoneActionLogEmpty => 'No actions yet';

  @override
  String get phoneActionLogEmptyHint => 'Every step DSH takes on your phone appears here';

  @override
  String get phoneAppRuleDeny => 'Hands off';

  @override
  String get phoneAppRuleConfirm => 'Every step';

  @override
  String get phoneAppRuleNormal => 'As usual';

  @override
  String get phoneAppRuleDenyHint => 'No reading or tapping. Default for banking and payment apps.';

  @override
  String get phoneAppRuleConfirmHint => 'Can read. Asks before tapping or typing.';

  @override
  String get phoneAppRuleNormalHint => 'Asks only before sensitive actions, like sending';

  @override
  String get phoneAppRulesTitle => 'App rules';

  @override
  String get phoneAppRulesSubtitle => 'Unlisted apps work as usual. Sensitive actions still need approval.';

  @override
  String get phoneAppRulesUnavailable => 'Can’t read app rules';

  @override
  String get phoneTryLater => 'Try again later';

  @override
  String get phoneAppRulesChanged => 'As usual · Changed by you';

  @override
  String get phoneAppRulesAdd => 'Add app';

  @override
  String get phoneAppRulesAddHint => 'Add by package name';

  @override
  String get phoneSensitiveActionsNote => 'Passwords, verification codes, payments and system settings are up to you';

  @override
  String get phoneAppRulesSaveFailed => 'Couldn’t save. Try again later.';

  @override
  String get phoneAppRulesAcceptRisk => 'Change anyway';

  @override
  String get phoneAppRulesPackage => 'Package name';

  @override
  String get phoneAppRulesPackageHint => 'Find it in Settings → Apps → App info';

  @override
  String get phoneDndRequiresAndroid => 'Requires Android 14 or later';

  @override
  String get phoneDndHiddenScreen => 'Works on a hidden screen';

  @override
  String get phoneNotReadyYet => 'Not ready yet';

  @override
  String get phoneActionFailedLater => 'Couldn’t complete. Try again later.';

  @override
  String get phoneDndDisabled => 'Non-disruptive mode is off';

  @override
  String get phoneDndEnabled => 'Non-disruptive mode is on';

  @override
  String get phoneDndShizukuPermissionFailed =>
      'Permission not granted. Allow DSH Go in Shizuku’s “Application management”.';

  @override
  String get phoneDndPairedConnect => 'Paired. Tap “Connect”.';

  @override
  String get phoneDndTitle => 'Non-disruptive mode';

  @override
  String get phoneDndSubtitle => 'Works on a hidden screen while you use your phone';

  @override
  String get phoneDndUnsupported => 'This phone needs Android 14 or later to use this feature.';

  @override
  String get phoneDndRequirements => 'Requirements';

  @override
  String get phoneDndKeepUnlocked => 'Keep the screen on and unlocked.';

  @override
  String get phoneDndReactivate => 'Reactivate after restarting your phone.';

  @override
  String get phoneDndKeepDebugging => 'With Shizuku or Direct ADB, stay on Wi-Fi with Wireless debugging on.';

  @override
  String get phoneReady => 'Ready';

  @override
  String get phoneDndDirectAdb => 'Direct ADB';

  @override
  String get phoneDndChannels => 'Connection';

  @override
  String get phoneDndShizukuFor => 'Phones with the Shizuku app';

  @override
  String get phoneDndSuiFor => 'Sui module on Magisk or KernelSU';

  @override
  String get phoneDndRootFor => 'Rooted phones';

  @override
  String get phoneDndAdbFor => 'No extra app, uses wireless debugging';

  @override
  String get phoneDndStateInUse => 'In use';

  @override
  String get phoneDndStateNotReady => 'Not ready';

  @override
  String get phoneDndStateUsable => 'Ready';

  @override
  String get phoneDndStateNeedsGrant => 'Needs permission';

  @override
  String get phoneDndStateNotRunning => 'Not running';

  @override
  String get phoneDndStateNotInstalled => 'Not installed';

  @override
  String get phoneDndStateNotFound => 'Not found';

  @override
  String get phoneDndStateViaSui => 'Via Sui';

  @override
  String get phoneDndStateWaiting => 'Waiting';

  @override
  String get phoneDndStateDisconnected => 'Not connected';

  @override
  String get phoneDndStateNotPaired => 'Not paired';

  @override
  String get phoneDndShizukuViaSui => 'On this phone the Shizuku interface comes from Sui. Use Sui instead.';

  @override
  String get phoneDndSuiMissing =>
      'Sui wasn’t found. Install the Sui module in Magisk or KernelSU, restart the phone, then come back.';

  @override
  String get phoneDndSuiRunning => 'Sui interface available';

  @override
  String get phoneDndSuiStopped =>
      'The Sui interface isn’t available. Check that the Sui module is enabled, restart the phone and try again.';

  @override
  String get phoneDndSuiAllSet => 'Sui is running and authorized. Connect the background screen next.';

  @override
  String get phoneDndSuiPermissionFailed =>
      'Couldn’t ask Sui for permission. Check that the Sui module is enabled and try again.';

  @override
  String get phoneDndRootWaiting => 'Waiting for root. Answer your root manager’s prompt.';

  @override
  String get phoneDndRootConnected =>
      'Root is connected. If it drops, choose it here again; DSH Go asks for root on its own only with “Keep root channel” enabled under More settings.';

  @override
  String get phoneDndRootConnectedKept =>
      'Root is connected. If it drops, DSH Go asks your root manager again on its own.';

  @override
  String get phoneDndRootRetry => 'Ask for root again';

  @override
  String get phoneDndInstallShizuku => 'Install Shizuku first (free and open source).';

  @override
  String get phoneDndOpenShizukuSite => 'Open Shizuku website';

  @override
  String get phoneDndStartShizuku =>
      'Open Shizuku and follow “Start via Wireless debugging” (requires Wi-Fi). This page refreshes when you return.';

  @override
  String get phoneDndGrantShizukuHint => 'Shizuku is running. Allow DSH Go to use it next.';

  @override
  String get phoneDndGrantShizuku => 'Allow DSH Go';

  @override
  String get phoneDndShizukuAllSet => 'Shizuku is running and authorized. Connect the background screen next.';

  @override
  String get phoneDndShizukuInstalled => 'Shizuku installed';

  @override
  String get phoneDndShizukuRunning => 'Shizuku running';

  @override
  String get phoneDndShizukuGranted => 'DSH Go allowed';

  @override
  String get phoneDndShizukuCompatibility =>
      'This Android version has compatibility issues with the official Shizuku release.';

  @override
  String get phoneDndWirelessDebuggingOn => 'Wireless debugging on';

  @override
  String get phoneDndPaired => 'Paired';

  @override
  String get phoneDndConnected => 'Connected';

  @override
  String get phoneDndDeveloperOptionsStep =>
      'Turn on Developer options: tap “Build number” 7 times in “About phone”. On Xiaomi, tap “OS version” in “My device → Detailed info and specs”; on vivo, tap “Software version”.';

  @override
  String get phoneDndWirelessDebuggingStep =>
      'Turn on “Wireless debugging” in Developer options while connected to Wi-Fi. Developer options is usually in “System” or “Additional settings”.';

  @override
  String get phoneDndStartPairingStep => 'Return here and tap “Start pairing”. DSH sends a notification.';

  @override
  String get phoneDndGetPairingCodeStep =>
      'In “Wireless debugging”, tap “Pair device with pairing code” to see a 6-digit code.';

  @override
  String get phoneDndEnterPairingCodeStep =>
      'Pull down notifications and enter the code in DSH’s notification. Once paired, tap “Connect”.';

  @override
  String get phoneDndStartPairing => 'Start pairing';

  @override
  String get phoneDndPairingNotificationSent => 'Notification sent. Get the code in “Wireless debugging”.';

  @override
  String get phoneDndManualEntry => 'Enter manually';

  @override
  String get phoneDndConnect => 'Connect';

  @override
  String get phoneDndManualEntryHint => 'No input field in the notification? Use “Enter manually”.';

  @override
  String get phoneDndXiaomiUsbHint =>
      'Turning on “USB debugging (Security settings)” requires a SIM card and a Xiaomi account.';

  @override
  String get phoneDndEnterCodeTitle => 'Enter pairing code';

  @override
  String get phoneDndCodeLabel => '6-digit pairing code';

  @override
  String get phoneDndPortLabel => 'Port (optional)';

  @override
  String get phoneDndPortHint => 'The number after the colon in “IP address & port” below the pairing code';

  @override
  String get phoneDndPair => 'Pair';

  @override
  String get phoneConfirmAsk => 'Always ask';

  @override
  String get phoneConfirmTask => 'This task';

  @override
  String get phoneConfirmAlways => 'Always skip';

  @override
  String get phoneConfirmAskHint => 'Asks before entering a new app, sending, deleting or paying';

  @override
  String get phoneConfirmTaskHint => 'Asks once per task';

  @override
  String get phoneConfirmAlwaysHint => 'Acts without asking';

  @override
  String get phoneConfirmTitle => 'Confirmation';

  @override
  String get phoneConfirmAlwaysTitle => 'Always skip confirmation?';

  @override
  String get phoneConfirmAlwaysBody => 'Opening apps, tapping, sending and deleting will happen without asking you.';

  @override
  String get phoneConfirmSaveFailed => 'Couldn’t change. Try again later.';

  @override
  String get phoneEnableFailed => 'Couldn’t turn on. Try again later.';

  @override
  String get phoneDisableFailed => 'Couldn’t turn off. Try again later.';

  @override
  String get phoneEnabled => 'On';

  @override
  String get phoneDisabled => 'Off';

  @override
  String get phoneOpenAccessibilityFailed => 'Can’t open settings. Find DSH in Settings → Accessibility.';

  @override
  String get phoneOpenAppInfoFailed => 'Can’t open app info. Find DSH Go in Settings → Apps.';

  @override
  String get phoneStopFailed => 'Couldn’t stop. Tap “Stop” on the floating bar or notification.';

  @override
  String get phoneControlTitle => 'Phone control';

  @override
  String get phoneControlSubtitle => 'Reads the screen and taps for you. Stop anytime.';

  @override
  String get phoneControlWorking => 'Operating your phone';

  @override
  String get phoneControlTaskNoConfirmHint =>
      'Confirmation skipped for this task · Pause or stop from the floating bar';

  @override
  String get phoneControlFloatingBarHint => 'Pause or stop from the floating bar';

  @override
  String get phoneControlAdvanced => 'More settings';

  @override
  String get phoneDndMoreChannels => 'More connections (Root / Sui)';

  @override
  String get phoneDndChangeChannel => 'Change connection';

  @override
  String get phoneDndPairingHelp => 'Pairing help / manual entry';

  @override
  String get phoneDndConnectHelp => 'Cannot connect?';

  @override
  String get phoneDndPairNext =>
      'Enable Wireless debugging in Developer options, then start pairing and enter the pairing code in the notification.';

  @override
  String get phoneControlKeepAliveHint => 'Prevent Android from turning off accessibility';

  @override
  String get phoneControlReadingEllipsis => 'Reading…';

  @override
  String get phoneControlNotReady => 'Not ready';

  @override
  String get phoneControlNotEnabled => 'Off';

  @override
  String get phoneControlSafeModeNotLoaded => 'Not loaded in Safe mode';

  @override
  String get phoneControlLocalOnly => 'Only available with this phone’s engine';

  @override
  String get phoneControlAfterEngineStarts => 'Takes effect when the engine starts';

  @override
  String get phoneControlNeedsAccessibility => 'One step left: turn on accessibility';

  @override
  String get phoneControlReady => 'Ready to control your phone';

  @override
  String get phoneControlSetup => 'Setup';

  @override
  String get phoneControlAccessibilityService => 'Accessibility service';

  @override
  String get phoneControlAccessibilityReady => 'Ready to read the screen and tap';

  @override
  String get phoneControlAccessibilityReconnect => 'Service disconnected. Turn it off and on again.';

  @override
  String get phoneControlAccessibilityHint => 'Needed to read the screen and tap';

  @override
  String get phoneControlGoSettings => 'Open settings';

  @override
  String get phoneControlGoEnable => 'Turn on';

  @override
  String get phoneControlAccessibilityBlocked => 'Accessibility switch disabled?';

  @override
  String get phoneControlRestrictedAfterAttempt =>
      'Looks like it didn’t turn on. Sideloaded apps need “Allow restricted settings” first.';

  @override
  String get phoneControlRestrictedHint => 'Sideloaded apps need “Allow restricted settings” first';

  @override
  String get phoneControlNotifications => 'Notifications';

  @override
  String get phoneControlNotificationsPairingHint => 'Used for approvals, stopping and pairing codes';

  @override
  String get phoneControlNotificationsHint => 'Needed for approvals and the “Stop” button';

  @override
  String get phoneControlAllowed => 'Allowed';

  @override
  String get phoneControlTry => 'Try it';

  @override
  String get phoneControlReadScreen => 'Read current screen';

  @override
  String get phoneControlReadScreenHint => 'See what DSH reads, without sending it to the model';

  @override
  String get phoneControlEnableAccessibilityFirst => 'Turn on the accessibility service first';

  @override
  String get phoneControlLoading => 'Loading';

  @override
  String get phoneControlRules => 'Rules';

  @override
  String get phoneControlRecentActions => 'Recent actions';

  @override
  String get phoneControlRecentActionsHint => 'Every step is logged, without screen contents';

  @override
  String get phoneControlAllActions => 'All actions';

  @override
  String get phoneControlModuleNotReady => 'Phone control isn’t ready in this version';

  @override
  String get phoneControlSafeModeUnavailable => 'Unavailable in Safe mode';

  @override
  String get phoneControlSafeModeHint => 'Safe mode skips plugins. Switch to normal mode to use this.';

  @override
  String get phoneControlRemoteHost => 'Connected to a remote host';

  @override
  String get phoneControlCapabilities => 'What you can do';

  @override
  String get phoneControlIntents => 'Alarms, events, maps, sharing';

  @override
  String get phoneControlNoExtraPermissions => 'No extra permissions needed';

  @override
  String get phoneControlReadToTable => 'Read the screen into tables or tasks';

  @override
  String get phoneControlNeedsAccessibilityHint => 'Requires accessibility';

  @override
  String get phoneControlTapType => 'Tap and type for you';

  @override
  String get phoneControlSensitiveHint => 'Asks before sending or buying. Never pays.';

  @override
  String get phoneDisclosureWhatTitle => 'What it reads';

  @override
  String get phoneDisclosureWhatBody =>
      'Text on the current screen. With a vision model, a screenshot may be included.';

  @override
  String get phoneDisclosureWhenTitle => 'When it reads';

  @override
  String get phoneDisclosureWhenBody => 'Only when you start a task or tap “Read current screen”. Never otherwise.';

  @override
  String get phoneDisclosureWhoTitle => 'Who receives it';

  @override
  String get phoneDisclosureWhoBody =>
      'Your chosen DeepSeek model in the cloud. Bank card and ID numbers are masked first.';

  @override
  String get phoneDisclosureNeverTitle => 'What it won’t do by default';

  @override
  String get phoneDisclosureNeverBody =>
      'Doesn’t enter passwords or verification codes, or change system settings. Hands back to you instead, and stays out of banking and payment apps.';

  @override
  String get phoneDisclosureStopTitle => 'Stop anytime';

  @override
  String get phoneDisclosureStopBody =>
      'A floating bar lets you pause, stop or steer. Keep the screen on and unlocked.';

  @override
  String get phoneDisclosureTitle => 'Before turning on Phone control';

  @override
  String get phoneDisclosureIntro =>
      'DSH reads the screen and taps like you do to get things done. Before turning it on, here’s what to know:';

  @override
  String get phoneDisclosureRestartNote => 'The engine will restart, interrupting any reply in progress';

  @override
  String get phoneDisclosureNotNow => 'Not now';

  @override
  String get phoneDisclosureAgreeEnable => 'Agree';

  @override
  String get phoneCheckUnknown => 'Not sure';

  @override
  String get phoneCheckYes => 'Yes';

  @override
  String get phoneCheckNotYet => 'Not yet';

  @override
  String get phoneRomStock => 'Stock / Other';

  @override
  String get phoneRestrictedAccessibility => 'Accessibility';

  @override
  String get phoneRestrictedOpenAccessibility => 'Turn on accessibility';

  @override
  String get phoneRestrictedOverlay => 'Floating window';

  @override
  String get phoneRestrictedOpenOverlay => 'Turn on floating window';

  @override
  String get phoneRestrictedTryAccessibility =>
      'First try turning on DSH in “Accessibility”. When “Restricted setting” appears, tap “OK”. The option below appears only after this step.';

  @override
  String get phoneRestrictedOpenInfoStep => 'Return here and tap “Open app info”.';

  @override
  String get phoneRestrictedBackAccessibility => 'Return to “Accessibility” and turn on DSH.';

  @override
  String get phoneRestrictedMenuStep =>
      'Tap the three dots at the top right, choose “Allow restricted settings”, then verify your lock screen password.';

  @override
  String get phoneRestrictedTryOverlay =>
      'First try turning on DSH Go in floating window settings. When “Restricted setting” appears, tap “OK”. The option below appears only after this step.';

  @override
  String get phoneRestrictedBackOverlay => 'Return to floating window settings and turn on DSH Go.';

  @override
  String get phoneRestrictedHuaweiOverlay =>
      'HarmonyOS 4 and earlier usually skip this step. Turn on DSH Go directly in floating window settings.';

  @override
  String get phoneRestrictedHuaweiAccessibility =>
      'HarmonyOS 4 and earlier usually skip this step. Turn on DSH directly in “Accessibility”.';

  @override
  String get phoneRestrictedVivoNote =>
      'The location varies by OriginOS version. If there are no three dots, scroll to the bottom of App info.';

  @override
  String get phoneRestrictedAdvancedStep => 'In “Advanced settings”, find “Allow restricted settings” and turn it on.';

  @override
  String get phoneRestrictedOppoNote =>
      'ColorOS may hide this option. Use the built-in Files app to find DSH’s installer and install over the existing app (no need to uninstall; chats and settings stay). Then turn on accessibility.';

  @override
  String get phoneRestrictedHuaweiNote =>
      'If “Restricted setting” appears in Accessibility, follow the “Stock / Other” steps.';

  @override
  String get phoneRestrictedTitle => 'Allow restricted settings';

  @override
  String get phoneRestrictedSteps => 'Steps';

  @override
  String get phoneRestrictedDiagram => 'Illustration';

  @override
  String get phoneRestrictedOpenInfo => 'Open app info';

  @override
  String get phoneRestrictedOpenOverlayFailed =>
      'Can’t open floating window settings. Search for “Floating window” in Settings.';

  @override
  String get phoneRestrictedOpenAccessibilityFailed =>
      'Can’t open accessibility settings. Search for “Accessibility” in Settings.';

  @override
  String get phoneRestrictedFootnote =>
      'Names vary by system. Search Settings for “Restricted” if needed. If it still won’t open, restart your phone and try again.';

  @override
  String get phoneRestrictedAppInfo => 'App info';

  @override
  String get phoneRestrictedPermissionsManager => 'Permission manager';

  @override
  String get phoneRestrictedBatterySaver => 'Battery saver';

  @override
  String get phoneRestrictedAdvanced => 'Advanced settings';

  @override
  String get phoneRestrictedPermissions => 'Permissions';

  @override
  String get phoneRestrictedBattery => 'Battery';

  @override
  String get phoneRestrictedDiagramAdvanced =>
      'Illustration: In App info, tap “Advanced settings”, then turn on “Allow restricted settings”.';

  @override
  String get phoneRestrictedDiagramMenu =>
      'Illustration: In App info, tap the three dots at the top right, then choose “Allow restricted settings”.';

  @override
  String get phoneRestrictedCaptionAdvanced => '① Tap “Advanced settings”';

  @override
  String get phoneRestrictedCaptionMenu => '① Tap the three dots';

  @override
  String get phoneRestrictedCaptionToggle => '② Turn on this switch';

  @override
  String get phoneRestrictedCaptionOption => '② Choose this option';

  @override
  String get phoneScreenReadFailed => 'Couldn’t read the screen';

  @override
  String get phoneScreenUnknownReason => 'Unknown reason';

  @override
  String get phoneScreenReadFailedHint =>
      'Check that accessibility is on. Android blocks reading password and payment screens.';

  @override
  String get phoneScreenCurrent => 'Current screen';

  @override
  String get phoneScreenEmpty => '(No readable text on screen)';

  @override
  String get phoneScreenReadNote => 'This is what the model would see. This read wasn’t sent to the model.';

  @override
  String get phoneFailureSafeStartup => 'Couldn’t start even in Safe mode';

  @override
  String get phoneFailureSafeStartupHint => 'Likely a global configuration or runtime issue';

  @override
  String get phoneFailureKilled => 'Android stopped the engine';

  @override
  String get phoneFailureKilledHint => 'Likely low memory or battery restrictions';

  @override
  String get phoneFailureLaunch => 'Local runtime couldn’t start';

  @override
  String get phoneFailureLaunchHint => 'Check the logs, or connect to a remote host to continue';

  @override
  String get phoneFailureNoSpaceHint => 'Free up some space and try again';

  @override
  String get phoneFailureStartup => 'DSH couldn’t start';

  @override
  String get phoneFailureCrashedEarly => 'DSH crashed soon after starting';

  @override
  String get phoneFailureCrashedLate => 'DSH crashed while running';

  @override
  String get phoneFailureFatal => 'The engine reported a fatal error';

  @override
  String get phoneFailureRestore => 'Restore configuration';

  @override
  String get phoneFailureEnterSafe => 'Enter Safe mode';

  @override
  String get phoneFailureStartNormal => 'Start normally';

  @override
  String get phoneFailureGlobalPatch => 'Global patch';

  @override
  String get phoneFailureEnvironment => 'Environment variables';

  @override
  String get phoneSafeMoveAsideTitle => 'Move these files aside first?';

  @override
  String get phoneSafeMoveAsideIntro => 'They affect all configurations, including Safe mode:';

  @override
  String get phoneSafeMoveAsideNote =>
      'Files are renamed (with .off-timestamp), never deleted. You can rename them back after fixing the issue.';

  @override
  String get phoneSafeStartDirectly => 'Start directly';

  @override
  String get phoneSafeMoveAsideStart => 'Move and start';

  @override
  String get phoneSafeNoRestoreNeeded => 'Configuration matches the last working version. No restore needed.';

  @override
  String get phoneSafeNoRestoreRecord => 'No previous working configuration recorded';

  @override
  String get phoneSafeRestoreTitle => 'Restore the last working configuration?';

  @override
  String get phoneSafeRestoreStart => 'Restore and start';

  @override
  String get phoneSafeRestoredStarting => 'Restored the last working configuration. Starting…';

  @override
  String get phoneSafeRestoreFailed => 'Couldn’t restore';

  @override
  String get phoneSafeStopIncomplete =>
      'Could not confirm that the engine has stopped. Configuration was not changed. Check the engine logs before trying again.';

  @override
  String get phoneSafeRestartIncomplete =>
      'The configuration operation finished, but the engine has not stopped or restarted. Wait for it to stop before starting it again.';

  @override
  String get phoneSafeRestoreIntro => 'DSH will restore the last working configuration:';

  @override
  String get phoneSafeRestoreSettings => '• Restore settings to that version (save current settings as a backup)';

  @override
  String get phoneSafeRestoreNote =>
      'No plugins will be uninstalled. No internet needed. You can re-enable disabled plugins later.';

  @override
  String get phoneSafeLeaveTitle => 'Return to normal mode?';

  @override
  String get phoneSafeLeaveBody =>
      'Start with your original configuration and plugins. Web settings changed in Safe mode won’t be kept.';

  @override
  String get phoneSafeLeave => 'Return to normal mode';

  @override
  String get phoneSafeMovePatch => 'Move patch aside';

  @override
  String get phoneSafeMoveFiles => 'Move files aside';

  @override
  String get phoneSafeFailureLog => 'Logs around the failure';

  @override
  String get phoneSafeFailureLogEmpty => 'No output recorded at the time of failure';

  @override
  String get phoneSafeBannerTitle => 'Safe mode · Plugins not loaded';

  @override
  String get phoneSafeBannerProbation => 'Trying normal mode';

  @override
  String get phoneSafeBannerProbationHint =>
      'If no errors occur within 2 minutes, recovery is complete. Otherwise, Safe mode returns automatically.';

  @override
  String get phoneSafeBannerRunningHint => 'Your chats are safe. Fix the configuration, then return to normal mode.';

  @override
  String get phoneSafeBannerFailedHint => 'Couldn’t start even in Safe mode. Check the engine page.';

  @override
  String get phoneSafeBannerStoppedHint => 'Engine stopped. Next start will still use Safe mode.';

  @override
  String get phoneSafeRepair => 'Help me fix it';

  @override
  String get phoneSafeReasonStartup => 'Failed to start twice in a row';

  @override
  String get phoneSafeReasonProbation => 'Crashed again after recovery';

  @override
  String get phoneSafeReasonManual => 'Turned on manually';

  @override
  String get phoneSafeNormalSettingsHint => 'Restart with original configuration and plugins';

  @override
  String get phoneSafeStartSettings => 'Start in Safe mode';

  @override
  String get phoneSafeStartSettingsHint => 'Skip plugins to troubleshoot startup';

  @override
  String get phoneSafeAutoSettings => 'Automatic Safe mode';

  @override
  String get phoneSafeAutoSettingsHint => 'Turn on after repeated startup failures';

  @override
  String get phoneAccentMist => 'Mist';

  @override
  String get phoneAccentDaiqing => 'Teal';

  @override
  String get phoneAccentDusk => 'Dusk';

  @override
  String get phoneAccentTurquoise => 'Aqua';

  @override
  String get phoneAccentAmber => 'Amber';

  @override
  String get phoneAccentGraphite => 'Slate';

  @override
  String get phoneAccentCustom => 'Custom';

  @override
  String phoneEngineInstallPercent(int percent) {
    return 'Installing · $percent%';
  }

  @override
  String phoneEngineStatusSemantics(String prefix, String status) {
    return '$prefix engine: $status';
  }

  @override
  String phoneLogLineCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count lines', one: '1 line');
    return '$_temp0';
  }

  @override
  String phoneLogCopiedLines(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Copied $count lines',
      one: 'Copied 1 line',
    );
    return '$_temp0';
  }

  @override
  String phoneAppRuleDefault(String rule) {
    return 'Default: $rule';
  }

  @override
  String phoneAppRulesLoosenTitle(String app) {
    return 'Let DSH operate “$app”?';
  }

  @override
  String phoneAppRulesSkipStepsTitle(String app) {
    return 'Stop confirming each step in “$app”?';
  }

  @override
  String phoneDndBrowserFailed(String url) {
    return 'Can’t open the browser. URL: $url';
  }

  @override
  String phoneDndChannelReady(String channel) {
    return '$channel · Ready';
  }

  @override
  String phoneDndChannelStatus(String channel, String reason) {
    return '$channel · $reason';
  }

  @override
  String phoneDndUsing(String channel) {
    return 'Using $channel';
  }

  @override
  String phoneDndEnableWith(String mode) {
    String _temp0 = intl.Intl.selectLogic(mode, {
      'shizuku': 'Turn on with Shizuku',
      'sui': 'Turn on with Sui',
      'root': 'Turn on with Root',
      'adb': 'Turn on with Direct ADB',
      'other': 'Turn on',
    });
    return '$_temp0';
  }

  @override
  String phoneDndSwitchTo(String mode) {
    String _temp0 = intl.Intl.selectLogic(mode, {
      'shizuku': 'Switch to Shizuku',
      'sui': 'Switch to Sui',
      'root': 'Switch to Root',
      'adb': 'Switch to Direct ADB',
      'other': 'Switch to this channel',
    });
    return '$_temp0';
  }

  @override
  String phoneControlWorkingApp(String app) {
    return 'Operating “$app”';
  }

  @override
  String phoneControlPolicySummary(int denied, int confirmed) {
    String _temp0 = intl.Intl.pluralLogic(
      denied,
      locale: localeName,
      other: '$denied apps off limits',
      one: '1 app off limits',
    );
    String _temp1 = intl.Intl.pluralLogic(
      confirmed,
      locale: localeName,
      other: '$confirmed apps confirm each step',
      one: '1 app confirms each step',
    );
    return '$_temp0 · $_temp1';
  }

  @override
  String phoneControlRemoteHint(String host) {
    return 'DSH on “$host” can’t control this phone. Switch to “This phone” to use it.';
  }

  @override
  String phoneRestrictedSubtitle(String place) {
    return 'Allow this for sideloaded apps to enable the $place switch';
  }

  @override
  String phoneRestrictedDone(String place) {
    return '$place is on. You can go back.';
  }

  @override
  String phoneFailurePlugins(String plugins) {
    return 'May be related to plugins “$plugins”';
  }

  @override
  String phoneFailureRequired(String components) {
    return 'Required components $components failed startup checks';
  }

  @override
  String phoneSafeRestoreAt(String when) {
    return 'DSH will restore the working configuration from $when:';
  }

  @override
  String phoneSafeRestoreDisable(String plugins) {
    return '• Disable: $plugins';
  }

  @override
  String phoneSafeRestoreChanged(String plugins) {
    return '  ($plugins updated since then; can only be disabled for now)';
  }

  @override
  String phoneSafeRestoreEnable(String plugins) {
    return '• Re-enable: $plugins';
  }

  @override
  String phoneSafeTodayTime(String time) {
    return 'Today $time';
  }

  @override
  String phoneSafeReasonPlugins(String plugins) {
    return 'Failed to start twice in a row. Suspected plugins: $plugins';
  }

  @override
  String get phoneListSeparator => ', ';

  @override
  String get phonePluginQuoteSeparator => '”, “';

  @override
  String phoneEngineRunningAt(String address) {
    return 'Running · $address';
  }

  @override
  String phoneEngineSafeAt(String address) {
    return 'Safe mode · $address';
  }

  @override
  String get phoneAppRulesLoosenBody =>
      'Banking and payment apps detect automation and may restrict sign-in or freeze your account. By default, DSH won’t enter passwords or pay.';

  @override
  String get phoneAppRulesSkipStepsBody =>
      'Apps like WeChat watch for automation, and phone assistants have had accounts signed out. With “As usual”, only actions like sending messages still ask first.';

  @override
  String get phoneResetDeletesChatsWorkspaces => 'chats and workspaces';

  @override
  String get phoneResetBodyChatsWorkspaces => 'This will delete chats and workspaces, then reinstall the runtime.';

  @override
  String get phoneResetDeletesWithPlugins => 'chats, workspaces, plugins and settings';

  @override
  String get phoneResetBodyWithPlugins =>
      'This will delete chats, workspaces, plugins and settings, then reinstall the runtime.';

  @override
  String get phoneResetDeletesWithUi => 'chats, workspaces, interface settings and skills';

  @override
  String get phoneResetBodyWithUi =>
      'This will delete chats, workspaces, interface settings and skills, then reinstall the runtime.';

  @override
  String get phoneResetDeletesEverything => 'chats, workspaces, plugins, settings, interface settings and skills';

  @override
  String get phoneResetBodyEverything =>
      'This will delete chats, workspaces, plugins, settings, interface settings and skills, then reinstall the runtime.';

  @override
  String phoneEngineStorageDetails(String needed, String free) {
    return 'Not enough storage: about $needed MB needed, $free MB available';
  }

  @override
  String get phoneControlEnabledRestarting => 'On · Restarting the engine';

  @override
  String get phoneControlDisabledRestarting => 'Off · Restarting the engine';

  @override
  String get phoneControlEnabledPending => 'On · Takes effect when the engine starts';

  @override
  String get phoneReturnAfterDone => 'Back to DSH Go when done';

  @override
  String get phoneReturnAfterDoneHint => 'Closes the bar, opens the chat';

  @override
  String get phoneFloatingBar => 'Floating bar';

  @override
  String get phoneIdleOpacity => 'Idle opacity';

  @override
  String get phoneAutoCollapse => 'Collapse when idle';

  @override
  String get phoneAutoCollapseHint => 'Shrinks to a ball; tap to open';

  @override
  String get phoneDeveloperOptions => 'Developer options';

  @override
  String get phoneDirectEngine => 'Direct local engine launch';

  @override
  String get phoneDirectHint =>
      'Experimental and off by default; applies on the next start. Some phones (Android 16, for one) block a direct start, and the app then goes back to compatible launch on its own. Your data isn’t affected.';

  @override
  String get phoneDirectFailedHint =>
      'Direct launch didn’t work on this phone, so compatible launch is used. Stop the engine and turn this on to try again.';

  @override
  String get phoneDirectCompatibleHint =>
      'This start used compatible launch; the reason is above. Your choice is kept, and the next start tries again.';

  @override
  String get phoneDirectStopFirst => 'Stop the local engine before changing its launch method.';

  @override
  String get phoneDirectSafeHint =>
      'Safe mode uses compatible launch. This choice applies when you return to normal mode.';

  @override
  String get phoneDirectNeedsRuntime => 'This option needs a runtime with direct launch support.';

  @override
  String get phoneDirectChangeFailed => 'Could not change the launch method. Stop the local engine and try again.';

  @override
  String get phoneTawcEngine => 'tawcroot fast launch';

  @override
  String get phoneTawcHint =>
      'Experimental and off by default; applies on the next start. Only one of this and direct launch can be on. Runs the local engine with tawcroot instead of compatible launch: it starts about three times faster, and package installs and apt get faster too. If it can’t start, the app goes back to compatible launch on its own. The first start after you turn it off first turns the hard links it made into ordinary files, which can take a little longer.';

  @override
  String get phoneTawcFailedHint =>
      'tawcroot didn’t start on this phone, so compatible launch is used. Stop the engine and turn this on to try again.';

  @override
  String get phoneTawcUnavailable =>
      'This build doesn’t include tawcroot, or the phone runs a version older than Android 10.';

  @override
  String get phoneLaunchTawcroot => 'tawcroot';

  @override
  String get phoneTawcLaunchFailed => 'tawcroot failed to start';

  @override
  String get phoneTawcUnsupported =>
      'This start’s settings aren’t supported by tawcroot yet, compatible launch for now';

  @override
  String get phoneActualLaunchMode => 'Current launch';

  @override
  String get phoneLaunchNotObserved => 'Not running';

  @override
  String get phoneLastLaunchSelection => 'Last launch';

  @override
  String get phoneDirectRejectedReason => 'Fallback reason';

  @override
  String get phoneLaunchFailureReason => 'Last failure';

  @override
  String get phoneReturnCompatible => 'Use compatible launch';

  @override
  String get phoneLaunchDirect => 'Direct launch';

  @override
  String get phoneLaunchCompatible => 'Compatible launch';

  @override
  String get phoneDirectIncompatibleFiles => 'Plugin files not tidied yet, compatible launch for now';

  @override
  String get phoneDirectNotEnoughSpace => 'Not enough storage, compatible launch for now';

  @override
  String get phoneDirectMigrationFailed => 'File tidy-up unfinished, compatible launch for now';

  @override
  String get phoneDirectLaunchFailed => 'Direct launch failed';

  @override
  String get phoneLaunchStartFailed => 'Didn\'t finish starting';

  @override
  String phoneLaunchExited(String code) {
    return 'Exit code $code';
  }

  @override
  String get phoneDndManualConnect => 'Connect by port';

  @override
  String get phoneDndConnectPortLabel => 'Connection port';

  @override
  String get phoneDndConnectPortHint =>
      'On the main Wireless debugging settings page, find “IP address & port” and enter the port after the colon. Do not use the pairing-code dialog’s port.';

  @override
  String get phonePreviewTitle => 'Live background preview';

  @override
  String get phonePreviewDescription =>
      'Frames are read only while the preview is visible and stay on this device. The preview is view-only.';

  @override
  String get phonePreviewOpen => 'View background screen';

  @override
  String phonePreviewTask(String taskId) {
    return 'Preview task $taskId';
  }

  @override
  String get phonePreviewInUse => 'Another task is being previewed';

  @override
  String get phonePreviewOff => 'The task ended or preview is off';

  @override
  String get phonePreviewUnavailable => 'Preview is unavailable or the screen is protected';

  @override
  String get phonePreviewWaiting => 'Waiting for a new background frame';

  @override
  String get phoneViewportTitle => 'Background viewport';

  @override
  String get phoneViewportDescription =>
      'Applies when the next background screen is created. The current screen stays unchanged; recreating it after handoff uses the new setting. This does not force apps to rotate.';

  @override
  String get phoneViewportPortrait => 'Portrait';

  @override
  String get phoneViewportLandscape => 'Landscape';

  @override
  String get phoneResumeTask => 'Allow phone control again';

  @override
  String get phoneResumeTaskHint =>
      'Allow future phone actions in this conversation. Finished actions will not be replayed.';

  @override
  String get phoneResumeTaskFailed => 'Could not resume. The previous action may still be finishing.';

  @override
  String phoneStoppedTask(int task) {
    return 'Phone task $task stopped';
  }

  @override
  String get phoneTaskDrainingHint => 'Waiting for the previous action and background screen cleanup to finish.';

  @override
  String get phoneTaskCleanupFailedHint =>
      'Background screen cleanup could not be confirmed. Phone control remains blocked.';

  @override
  String phoneFinishingTask(int task) {
    return 'Phone task $task is finishing';
  }

  @override
  String get phoneCleanupRetry => 'Retry cleanup';

  @override
  String get phoneCleanupRetryFailed =>
      'The previous background screen is still unconfirmed. Its screen access remains reserved.';

  @override
  String get phoneSelfCheckTitle => 'Check phone control';

  @override
  String get phoneSelfCheckTechnicalDetails => 'Technical details';

  @override
  String get phoneLocalOcrSummary =>
      'On-device recognition; results may go to your model. The SDK collects usage statistics.';

  @override
  String get phoneLocalOcrPrivacyDetails => 'Privacy details';

  @override
  String get phoneSelfCheckPartial => 'Partial check — only observed items have results';

  @override
  String get phoneSelfCheckScope =>
      'Uses the selected connected channel and a temporary presentation display. App launch, text input, screenshots, OCR and MAIN disturbance are not tested. Cleanup alone does not prove a display was created.';

  @override
  String get phoneSelfCheckStart => 'Start check';

  @override
  String get phoneSelfCheckCancel => 'Request cancellation';

  @override
  String get phoneSelfCheckRefresh => 'Refresh status';

  @override
  String get phoneSelfCheckSave => 'Save sanitized report';

  @override
  String get phoneSelfCheckSaving => 'Saving…';

  @override
  String get phoneSelfCheckSaved => 'Report saved to Downloads/DSH-Go.';

  @override
  String get phoneSelfCheckSaveFailed => 'Could not save the report.';

  @override
  String get phoneSelfCheckReportHint =>
      'Save only when you choose. The local report contains fixed results, with no screenshots, recognized text, logs, account data or run identifier.';

  @override
  String phoneSelfCheckRunState(String state) {
    String _temp0 = intl.Intl.selectLogic(state, {
      'idle': 'Not started',
      'running': 'Running partial check',
      'cleaning': 'Cleaning up; cancellation does not undo sent input',
      'done': 'Check ended; see Technical details for results',
      'cancelled': 'Cancelled; observed actions remain recorded',
      'other': 'Status unavailable',
    });
    return '$_temp0';
  }

  @override
  String phoneSelfCheckStepState(String state) {
    String _temp0 = intl.Intl.selectLogic(state, {
      'not_run': 'Not run / no observation',
      'running': 'Running',
      'pass': 'Observed pass',
      'fail': 'Failed',
      'skipped': 'Skipped',
      'unknown': 'Unconfirmed',
      'cancelled': 'Cancelled',
      'other': 'Unconfirmed',
    });
    return '$_temp0';
  }

  @override
  String phoneSelfCheckStage(String stage) {
    String _temp0 = intl.Intl.selectLogic(stage, {
      'device': 'Device preconditions',
      'channel': 'Selected channel',
      'display': 'Temporary background display',
      'input_probe': 'Touch receiver',
      'launch': 'App launch',
      'tree': 'Accessibility tree',
      'tap': 'App button tap',
      'scroll': 'App scrolling',
      'back': 'App back action',
      'text_ascii': 'Fixed ASCII input',
      'text_zh': 'Fixed Chinese input',
      'capture': 'Local pattern capture',
      'continuity': 'Limited controlled refresh',
      'main': 'Limited MAIN observations',
      'ocr': 'Local OCR',
      'cleanup': 'Strict cleanup',
      'other': 'Unknown item',
    });
    return '$_temp0';
  }

  @override
  String phoneSelfCheckReason(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'busy': 'The phone or channel is busy.',
      'unsupported': 'This device or peer does not support this check.',
      'cancelled': 'This request was cancelled or retired.',
      'disabled': 'Phone control is turned off.',
      'locked': 'The device is locked.',
      'identity': 'The original run or channel no longer matches.',
      'invalid': 'The request or result could not be verified.',
      'display': 'The temporary display could not be verified.',
      'input': 'Input acceptance or delivery was not confirmed. Sent input is not retried.',
      'cleanup': 'Resource cleanup is unconfirmed. Reconnect the channel, then check again.',
      'denied': 'The system denied the operation.',
      'timeout': 'The operation timed out; sent work may still complete.',
      'unavailable': 'The local status or selected channel is unavailable.',
      'target_unavailable': 'The fixed target could not be verified. Finish cleanup before starting again.',
      'target_changed': 'The original target changed. Continue only with cleanup.',
      'target_cleanup': 'Target cleanup is unconfirmed. Reconnect the channel, then check again.',
      'target_main': 'The target was observed on MAIN. Further steps stopped; complete cleanup.',
      'target_readback': 'The fixed target count or text did not match. Do not repeat the action; complete cleanup.',
      'tree_cleanup': 'Tree connection cleanup is unconfirmed. Reconnect the channel, then check again.',
      'target_launch': 'Target launch was denied or unconfirmed. Check the device and complete cleanup.',
      'frame_unavailable': 'No usable local pattern frame was observed. Complete cleanup before a new check.',
      'frame_mismatch': 'The actual frame did not match this target and phase. Complete cleanup.',
      'continuity': 'The limited controlled refresh sequence was not confirmed. This is not a frame-rate result.',
      'main_changed':
          'MAIN samples changed; this may include user actions. Complete cleanup. This does not establish the cause.',
      'main_unchanged': 'No change was seen at these finite sampling points. Disturbance between them remains unknown.',
      'main_incomplete': 'MAIN samples are incomplete. They cannot establish absence of disturbance.',
      'not_installed': 'This self-check does not include OCR. OCR was not tested.',
      'other': 'An unrecognized result was received.',
    });
    return '$_temp0';
  }

  @override
  String get phoneSelfCheckTargetScope =>
      'Uses an ordinary temporary display and a fixed local target for launch, tree reading and one button tap. Text, scrolling, screenshots and OCR are not tested. MAIN can only record an observed failure, never a pass. Cleanup alone does not prove a display was created.';

  @override
  String get phoneSelfCheckProfileChoice => 'Choose the next check (does not change the report below)';

  @override
  String phoneSelfCheckProfile(String profile) {
    String _temp0 = intl.Intl.selectLogic(profile, {
      'probe_b': 'Input receiver check (B)',
      'target_c1': 'Fixed target check (C1)',
      'target_c2': 'Fixed input and frames (C2)',
      'other': 'Unknown profile',
    });
    return '$_temp0';
  }

  @override
  String phoneSelfCheckReportProfile(String profile) {
    String _temp0 = intl.Intl.selectLogic(profile, {
      'probe_b': 'Report profile: input receiver (B)',
      'target_c1': 'Report profile: fixed target (C1)',
      'target_c2': 'Report profile: fixed input and frames (C2)',
      'other': 'Report profile: unconfirmed',
    });
    return '$_temp0';
  }

  @override
  String get phoneSelfCheckTargetC2Scope =>
      'Uses a fixed local target for launch, tree reading, one button tap, ASCII and Chinese ACTION_SET_TEXT replacement/readback, local pattern capture and limited controlled refresh. This does not measure FPS or smoothness. Finite MAIN samples cannot prove there was no disturbance between samples. OCR, touch reception, scrolling and back are not tested. Cleanup alone does not prove a display was created.';

  @override
  String phoneTaskWaiting(int taskId) {
    return 'Task $taskId · Waiting for resources';
  }

  @override
  String phoneTaskWaitingApp(String packageName, int seconds) {
    return 'Waiting for app $packageName · $seconds seconds elapsed.';
  }

  @override
  String phoneTaskWaitingUnknown(int seconds) {
    return 'Waiting for the interface (app identity unconfirmed) · $seconds seconds elapsed.';
  }

  @override
  String phoneTaskWaitingScreen(String screen, int seconds) {
    return 'Waiting for $screen · $seconds seconds elapsed.';
  }

  @override
  String get phoneTaskMainResource => 'the main screen';

  @override
  String get phoneTaskBackgroundResource => 'the background screen';

  @override
  String get phoneInterruptionTitle => 'Previous phone tasks did not confirm completion';

  @override
  String get phoneInterruptionLoading => 'Reading interrupted task records…';

  @override
  String get phoneInterruptionStorageError =>
      'Task completion records could not be saved or read. Retry; this does not mean background resources were released.';

  @override
  String phoneInterruptionHint(int count) {
    return '$count tasks were interrupted or could not save completion. Actions may already have taken effect. Check first. Acknowledging only confirms you saw this notice; it does not resume actions or prove background resources were released.';
  }

  @override
  String get phoneInterruptionAcknowledge => 'I checked the interruption notice';

  @override
  String get phoneInterruptionRetry => 'Retry saving or reading';

  @override
  String get phoneInterruptionActionFailed => 'Task records are not confirmed yet. Please retry.';

  @override
  String get phoneLocalOcrTitle => 'Text recognition';

  @override
  String get phoneLocalOcrUnknown => 'This setting could not be read. Refresh and try again.';

  @override
  String get phoneLocalOcrDisclosure =>
      'Recognition runs on this device. Screenshots and text are not sent to Google; Google’s SDK collects usage statistics such as device model, app version and processing time.';

  @override
  String get phoneLocalOcrDetails =>
      'Enabled by default. While off, text recognition requests do not trigger SDK loading or initialization. Remote pairing initializes the shared SDK separately when its scanner opens; it does not enable text recognition. Screenshots and recognized text may be sent to your configured model. Turning this off prevents new local recognition; work already started may still finish. It does not uninstall the SDK or promise to clear or stop sending previously accumulated SDK statistics.';

  @override
  String get phoneBackgroundParallelTitle => 'Background task limit';

  @override
  String phoneBackgroundParallelStatus(int configured, int effective, int held) {
    return 'Configured: $configured · Available limit: $effective · Occupied: $held';
  }

  @override
  String get phoneBackgroundParallelDescription =>
      'A lower limit keeps existing tasks. New tasks still wait for apps and the main screen to become available.';

  @override
  String phoneBackgroundParallelChoice(int limit) {
    return '$limit background task slots';
  }

  @override
  String get phoneBackgroundParallelOff => 'The background channel is off. Saving this preference does not turn it on.';

  @override
  String get phoneBackgroundParallelUnsupported => 'Background operation is unavailable on this device.';

  @override
  String get phoneBackgroundParallelConnection => 'A connection is required before a new background task can start.';

  @override
  String get phoneBackgroundParallelBusy =>
      'The background channel is being prepared or maintained. New tasks cannot start yet.';

  @override
  String get phoneGateRetest => 'Check this channel again';

  @override
  String get phoneBackgroundParallelSerial =>
      'This connection supports one background slot. Your preference remains saved.';

  @override
  String get phoneSkillBundlePublishedUnverified =>
      'The files were published, but full verification has not succeeded. Do not save again.';

  @override
  String get phoneSkillBundleUnknown =>
      'The save result is not confirmed. Files may already have been written. Do not save again.';

  @override
  String phoneSkillBundleRevision(String revision) {
    return 'Route revision: $revision';
  }

  @override
  String get phoneSkillReplayReview => 'Review phone route';

  @override
  String get phoneSkillReplaySourceChanged =>
      'The local session or connection changed. Select the route again from the current local conversation.';

  @override
  String get phoneSkillReplayUnavailable =>
      'This route is not available for controlled execution on this phone. The ordinary skill template remains available.';

  @override
  String get phoneSkillReplayConfirm => 'I have reviewed this route and the app selected for this use.';

  @override
  String get phoneSkillReplayToComposer => 'Insert into this conversation';

  @override
  String phoneSkillReplayStartText(String request) {
    return 'A phone route has been selected and reviewed locally. Call only mcp__phone__replay with $request. If unavailable or refused, hand back to the user/model; do not replay it as ordinary actions.';
  }

  @override
  String get phoneSkillReplayQueue => 'Send route (queue)';

  @override
  String get phoneSkillReplayQueued =>
      'The route message was accepted or queued. This does not mean the route has executed successfully.';

  @override
  String get phoneSkillReplaySendUncertain =>
      'Delivery of the route message was not confirmed. It has not been prepared or replayed again. Check the original conversation.';

  @override
  String get phoneTaskResultReady => 'Task complete · View result';

  @override
  String get phoneTaskEndedResult => 'Task ended · View result';

  @override
  String get phoneBackgroundGuideTitle => 'Confirmations and return';

  @override
  String get phoneBackgroundGuideSubtitle => 'See confirmations and task results in time';

  @override
  String get phoneBackgroundGuideBody =>
      'When a step needs your decision, a DSH Go card appears. If the card is unavailable, the app tries a notification or returns here. Allow phone-control notifications and pop-up alerts in system settings.';

  @override
  String get phoneBackgroundOemHint =>
      'In the system permissions for DSH Go, check “Display pop-up windows while running in the background”, if available. Allowing it can help the app return automatically. Menu names vary by system version.';

  @override
  String get phoneBackgroundReturnHint =>
      'If the app does not return when a task finishes, tap “Task complete · View result”. If system notifications or background windows are blocked, you may need to open DSH Go yourself.';

  @override
  String get phoneBackgroundGotIt => 'Got it';

  @override
  String get phoneBackgroundOpenSettings => 'Open system settings';

  @override
  String get phoneBackgroundNotificationBlocked => 'Allow pop-up alerts for phone-control notifications';

  @override
  String get phonePrivilegedUpgrade =>
      'This app build does not support that privileged channel. Update DSH Go to use it.';

  @override
  String get phonePrivilegedSui => 'Sui';

  @override
  String get phonePrivilegedRoot => 'Root';

  @override
  String get phonePrivilegedSuiDescription =>
      'Use the Sui module interface. Authorization is requested only when you tap.';

  @override
  String get phonePrivilegedRootDescription =>
      'For Magisk, KernelSU or APatch. The first root command runs only after you choose this channel.';

  @override
  String get phonePrivilegedRootPrepare => 'Authorize root';

  @override
  String get phonePrivilegedRootUnchecked => 'Not checked';

  @override
  String get phonePrivilegedGrantRoot => 'Grant with root';

  @override
  String get phonePrivilegedGrantSui => 'Grant with Sui';

  @override
  String get phonePrivilegedGrantSuiPermission => 'Authorize Sui, then grant';

  @override
  String get phonePrivilegedSuggested => 'Suggested';

  @override
  String get phonePrivilegedRootRiskTitle => 'Give DSH Go root access?';

  @override
  String get phonePrivilegedRootRiskBody =>
      'Your root manager (Magisk, KernelSU or APatch) will ask you. If you allow it, DSH Go runs its own background service as root. It asks again on its own after a disconnect or restart only with “Keep root channel” on.';

  @override
  String phoneKeepTitle(String mode) {
    String _temp0 = intl.Intl.selectLogic(mode, {
      'shizuku': 'Keep Shizuku channel',
      'sui': 'Keep Sui channel',
      'root': 'Keep root channel',
      'adb': 'Keep Direct ADB channel',
      'other': 'Keep this channel',
    });
    return '$_temp0';
  }

  @override
  String get phoneKeepRootDescription =>
      'After a drop, an app restart or a reboot, DSH Go asks your root manager again by itself. The manager still decides.';

  @override
  String get phoneKeepSharedDescription =>
      'After a drop, an app restart or a reboot, DSH Go reconnects with the permission it already has. It never asks for permission.';

  @override
  String get phoneKeepAdbDescription =>
      'After a drop, an app restart or a reboot, DSH Go reconnects over Wi‑Fi with the existing pairing. With the permission from “Restore accessibility automatically”, it also tries once to turn on wireless debugging.';

  @override
  String get phoneKeepRestoring => 'Reconnecting';

  @override
  String get phoneKeepWaiting => 'Waiting for the channel';

  @override
  String get phoneKeepWaitingService => 'Waiting for the service to run';

  @override
  String get phoneKeepWaitingPermission => 'Not authorized. Reconnects once you grant it.';

  @override
  String get phoneKeepWaitingNetwork => 'Waiting for Wi‑Fi';

  @override
  String get phoneKeepNotPaired => 'Not paired. Pair wireless debugging first.';

  @override
  String get phoneKeepFailed => 'Couldn’t reconnect. Tries again when you open the app or start a task.';

  @override
  String get phoneSkillSectionTitle => 'Completed tasks and skills';

  @override
  String get phoneSkillAskAfterSuccess => 'Ask to save a skill after a successful task';

  @override
  String get phoneSkillAskAfterSuccessHint =>
      'Off by default. A newly completed task asks once while this page is visible. You can also choose a task manually.';

  @override
  String phoneSkillTask(int taskId, int steps) {
    return 'Task $taskId · $steps steps';
  }

  @override
  String get phoneSkillCandidateHint =>
      'Check the actual result first; successful tool calls do not prove that your goal was achieved.';

  @override
  String get phoneSkillSaveAction => 'Save as a skill';

  @override
  String get phoneSkillConfirmGoal => 'Did this task achieve your goal?';

  @override
  String get phoneSkillConfirmGoalBody =>
      'Check the actual result. Your confirmation creates a draft that you can review and edit before saving.';

  @override
  String get phoneSkillGoalDone => 'Goal achieved · Review draft';

  @override
  String get phoneSkillPrivacyHint =>
      'The draft stays on this device. Do not enter passwords, keys, or verification codes. In this version, free text becomes parameters; removing or reordering steps is kept. Review the final preview.';

  @override
  String get phoneSkillGoal => 'Goal';

  @override
  String get phoneSkillPrerequisites => 'Requirements (app, version, sign-in state)';

  @override
  String phoneSkillStep(int number) {
    return 'Original step $number';
  }

  @override
  String get phoneSkillCheckpoint => 'What should appear after this step';

  @override
  String get phoneSkillMoveUp => 'Move step up';

  @override
  String get phoneSkillMoveDown => 'Move step down';

  @override
  String get phoneSkillUpdatePreview => 'Update the redacted preview';

  @override
  String get phoneSkillPreviewTitle => 'Complete content to be saved';

  @override
  String get phoneSkillParameterizedHint =>
      'Free text has been replaced with parameters to fill in and check when using this skill.';

  @override
  String get phoneSkillFinalConfirmation =>
      'I have reviewed the complete current preview and agree to save this version.';

  @override
  String get phoneSkillSavedBody =>
      'The file was written to the local skills directory. The engine’s refreshed skill list has not been verified; check the Skills page.';

  @override
  String get phoneSkillWriting => 'Writing the skill';

  @override
  String get phoneSkillCannotCancel =>
      'The write may have reached its commit stage and cannot be guaranteed to cancel. Closing only closes this page; a committed file will still be saved.';

  @override
  String get phoneSkillKeepWaiting => 'Keep viewing';

  @override
  String get phoneSkillCheckWrite => 'Check write result';

  @override
  String get phoneSkillStale => 'This draft is no longer current. Close it and choose the task again.';

  @override
  String get phoneSkillSensitive => 'The edit contains sensitive content. Remove it before updating the preview.';

  @override
  String get phoneSkillInvalid =>
      'The edit or step order exceeds the limits. Shorten the text and keep at least one step.';

  @override
  String get phoneSkillWriteFailed =>
      'The file could not be written. Check the local runtime and storage; edit and update the preview before confirming another save.';

  @override
  String get phoneSkillUnavailable => 'Skill drafts are unavailable. Check the local engine state and try again.';

  @override
  String get phoneModeTitle => 'How DSH confirms';

  @override
  String get phoneModeMessage => 'You can change this in Settings anytime';

  @override
  String get phoneModeAsk => 'Ask me at key steps';

  @override
  String get phoneModeAskHint => 'Before a new app, sending, deleting or paying';

  @override
  String get phoneModeAuto => 'Fully automatic';

  @override
  String get phoneModeAutoHint => 'Never asks, never interrupts';

  @override
  String get phoneModeAutoNoteTitle => 'These stay with you';

  @override
  String get phoneModeAutoNote =>
      'System settings and permission pages, passwords and verification codes, and DSH Go itself stay with you. Banking and payment apps are off limits by default; you can change that in Settings.';

  @override
  String get phoneModeAutoUnlockNote =>
      'To let AI handle system settings, passwords and the like, turn it on in Settings › Phone control › Lift limits.';

  @override
  String get phoneModeConfirmAuto => 'Go fully automatic';

  @override
  String get phoneYoursTitle => 'These stay with you';

  @override
  String get phoneYoursSystem => 'System settings and permission pages';

  @override
  String get phoneYoursSecrets => 'Passwords and verification codes';

  @override
  String get phoneYoursOwnApp => 'DSH Go itself';

  @override
  String get phoneYoursDenyList => 'Apps set to Hands off in App rules, banking and payment by default';

  @override
  String get phoneUnlockTitle => 'Lift limits';

  @override
  String get phoneUnlockSubtitle => 'Let AI do what’s yours by default';

  @override
  String get phoneUnlockSystem => 'System settings';

  @override
  String get phoneUnlockSystemHint => 'Permissions, installers, security center, notifications';

  @override
  String get phoneUnlockSecrets => 'Passwords and codes';

  @override
  String get phoneUnlockSecretsHint => 'Fill in passwords, verification and payment codes';

  @override
  String get phoneUnlockOwnApp => 'DSH Go itself';

  @override
  String get phoneUnlockOwnAppHint => 'Tap and type inside DSH Go';

  @override
  String get phoneUnlockBusy => 'Can’t turn on while a task is running';

  @override
  String get phoneUnlockFootnote => 'Once on, the consequences are yours. Turn on only when needed, and off when done.';

  @override
  String get phoneUnlockBanks => 'Banking and payment apps';

  @override
  String get phoneUnlockBanksHint => 'Change in App rules';

  @override
  String get phoneUnlockNone => 'None on';

  @override
  String phoneUnlockCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count on', one: '1 on');
    return '$_temp0';
  }

  @override
  String get phoneUnlockedBadge => 'Limits lifted';

  @override
  String get phoneUnlockConfirmSystemTitle => 'Let AI operate system settings?';

  @override
  String get phoneUnlockConfirmSecretsTitle => 'Let AI fill in passwords and codes?';

  @override
  String get phoneUnlockConfirmOwnAppTitle => 'Let AI operate DSH Go itself?';

  @override
  String get phoneUnlockCanTitle => 'Once on, AI can';

  @override
  String get phoneUnlockRiskTitle => 'What could go wrong';

  @override
  String get phoneUnlockDisclaimerTitle => 'Disclaimer';

  @override
  String get phoneUnlockSystemCan1 =>
      'Open and change system settings, including permissions, accessibility and developer options';

  @override
  String get phoneUnlockSystemCan2 => 'Install, update or uninstall apps in the installer';

  @override
  String get phoneUnlockSystemCan3 =>
      'Tap in the security center and the notification shade, including buttons on notifications';

  @override
  String get phoneUnlockSystemRisk1 =>
      'Malicious instructions in a web page, message or file could lead AI to turn off protections, grant permissions to other apps or install apps';

  @override
  String get phoneUnlockSystemRisk2 => 'Network, account or security settings changed by mistake are yours to restore';

  @override
  String get phoneUnlockSecretsCan1 => 'Type into password, verification-code and payment-code fields';

  @override
  String get phoneUnlockSecretsCan2 => 'Use codes it sees in chats, texts or notifications to sign in or verify';

  @override
  String get phoneUnlockSecretsCan3 => 'The action log shows •••• and never what was typed';

  @override
  String get phoneUnlockSecretsRisk1 =>
      'Malicious instructions could lead AI to enter a code somewhere else, letting someone into your account';

  @override
  String get phoneUnlockSecretsRisk2 => 'It could complete a payment or transfer you didn’t intend';

  @override
  String get phoneUnlockOwnAppCan1 => 'Tap and type inside DSH Go, including changing settings';

  @override
  String get phoneUnlockOwnAppCan2 => 'Read conversations and settings on DSH Go’s screens';

  @override
  String get phoneUnlockOwnAppRisk1 =>
      'Malicious instructions could lead AI to approve its own requests or turn confirmations off';

  @override
  String get phoneUnlockOwnAppRisk2 => 'What’s on these screens is sent to the model';

  @override
  String get phoneUnlockDisclaimer1 => 'Once on, AI can do the above without anyone confirming.';

  @override
  String get phoneUnlockDisclaimer2 => 'AI can be misled by content in web pages, messages or files.';

  @override
  String get phoneUnlockDisclaimer3 =>
      'Any resulting loss to your accounts, money, data or device is yours to bear. DSH Go and its developers accept no liability.';

  @override
  String get phoneUnlockDisclaimer4 => 'Turn it on only when you need it, and off when you’re done.';

  @override
  String get phoneUnlockDisclaimer5 =>
      'We advise against turning it on for a device that holds payment or banking details.';

  @override
  String get phoneUnlockHold => 'I understand the risks, turn on';

  @override
  String get phoneUnlockHoldHint => 'Press and hold for about 1.5 seconds';

  @override
  String phoneUnlockOnNotice(String name) {
    return '“$name” is on';
  }

  @override
  String phoneUnlockOffNotice(String name) {
    return '“$name” is off';
  }

  @override
  String get searchKwPhoneUnlock => 'lift limits,unlock,passwords,codes,system settings,itself,risk,disclaimer';

  @override
  String get pluginConfigUnsaved => 'Unsaved';

  @override
  String get pluginConfigSecretSet => 'Set';

  @override
  String get pluginConfigAdvanced => 'Advanced';

  @override
  String get pluginConfigSearchHint => 'Search settings';

  @override
  String get pluginConfigNoMatch => 'No matching settings';

  @override
  String get pluginConfigOpenWeb => 'Set up on the web';

  @override
  String get pluginConfigOpenWebHint => 'The plugin\'s own page';

  @override
  String get pluginConfigResetAll => 'Reset all to defaults';

  @override
  String get pluginConfigResetAllTitle => 'Reset all to defaults?';

  @override
  String get pluginConfigReset => 'Reset';

  @override
  String pluginConfigChanges(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count changes', one: '1 change');
    return '$_temp0';
  }

  @override
  String get pluginConfigAppliesOnReload => 'Saving reloads the plugin';

  @override
  String get pluginConfigSaving => 'Saving…';

  @override
  String get pluginConfigReloading => 'Reloading…';

  @override
  String get pluginConfigApplied => 'Applied';

  @override
  String get pluginConfigFailed => 'Didn\'t take effect';

  @override
  String get pluginConfigRestored => 'Previous settings restored';

  @override
  String get pluginConfigStopped => 'Didn\'t take effect, and the previous settings couldn\'t be restored';

  @override
  String get pluginConfigRestore => 'Restore';

  @override
  String get pluginConfigDiscard => 'Discard';

  @override
  String get pluginConfigNotStarted => 'The plugin didn\'t start';

  @override
  String get pluginConfigNone => 'Nothing to set';

  @override
  String get pluginConfigInvalidOperation => 'This change can\'t be applied';

  @override
  String get pluginConfigGone => 'The plugin is no longer running. Refreshed.';

  @override
  String get pluginConfigUnknown => 'Connection lost. Settings reloaded.';

  @override
  String get pluginConfigUnsupported => 'Can\'t be set here yet';

  @override
  String get pluginConfigSecretUnbound => 'Needs plugin support';

  @override
  String get pluginConfigListFailed => 'Couldn\'t read the plugin list. Try again later.';

  @override
  String get pluginConfigListUpdating => 'The plugin list is updating. Try again in a moment.';

  @override
  String get pluginConfigFixed => 'Set by configuration file';

  @override
  String get pluginConfigFixedNote => 'Set by a configuration file. View only here.';

  @override
  String get pluginConfigReadOnly => 'Read-only';

  @override
  String pluginConfigEntryTitle(String bundle, String entry) {
    return '$bundle · $entry';
  }

  @override
  String get pluginConfigNameSpeechToText => 'Speech recognition';

  @override
  String get pluginConfigNameSenseVoice => 'SenseVoice recognition';

  @override
  String get pluginConfigNameSpeechApi => 'Transcription API';

  @override
  String get pluginConfigNameTranslator => 'Translation service';

  @override
  String get pluginConfigNameSessionIndex => 'Session index';

  @override
  String get pluginConfigNameSessionSearchTool => 'Session search tool';

  @override
  String get pluginConfigNameTerminalService => 'Terminal service';

  @override
  String get pluginConfigNameTerminalBash => 'Bash terminal';

  @override
  String get pluginConfigNameTerminalPwsh => 'PowerShell terminal';

  @override
  String get pluginConfigNameTerminalTools => 'Terminal tools';

  @override
  String get pluginConfigNameWorktree => 'Worktree manager';

  @override
  String get pluginConfigNameWorktreeTools => 'Worktree tools';

  @override
  String get pluginConfigNameRalphWorkflow => 'Workflow engine';

  @override
  String get pluginConfigNameRalphTools => 'Ralph tools';

  @override
  String get plugInputRequired => 'Complete this field';

  @override
  String get plugInputInvalidValue => 'Invalid value';

  @override
  String get plugInputNumber => 'Enter a valid number';

  @override
  String plugInputBounds(String min, String max) {
    return 'Enter a value from $min to $max';
  }

  @override
  String plugInputLength(int min, int max) {
    return 'Use $min–$max characters';
  }

  @override
  String get plugInputPattern => 'Check the format';

  @override
  String get plugInputDate => 'Choose a valid date';

  @override
  String get plugInputTime => 'Choose a valid time';

  @override
  String get plugInputUnavailable => 'This component is not supported here';

  @override
  String get plugInputNoPassword => 'Plugins cannot use password fields';

  @override
  String get plugInputBadBinding => 'Input binding must be a field path under data';

  @override
  String get plugInputDuplicateBinding => 'Each field can bind to only one input';

  @override
  String get plugInputNamedPattern => 'Use a built-in validation pattern';

  @override
  String get plugInputNestedForm => 'Forms cannot be nested';

  @override
  String get plugInputSubmitMissing => 'Form needs a submit action';

  @override
  String get plugInputTooLarge => 'Too much content. Shorten it and try again';

  @override
  String get plugInputCheckFields => 'Check the highlighted fields';

  @override
  String get plugInputFailed => 'Not saved. Try again';

  @override
  String get plugInputSubmit => 'Save';

  @override
  String get plugInputChoose => 'Choose';

  @override
  String get plugInputPrevious => 'Previous';

  @override
  String get plugInputNext => 'Next';

  @override
  String plugInputDecrease(String label) {
    return 'Decrease $label';
  }

  @override
  String plugInputIncrease(String label) {
    return 'Increase $label';
  }

  @override
  String plugInputRating(String label, int value, int max) {
    return '$label: $value out of $max';
  }

  @override
  String get plugInputFormula => 'Invalid formula or formula limit exceeded';

  @override
  String get plugInputDatePicker => 'Plugin date';

  @override
  String get plugInputTimePicker => 'Plugin time';

  @override
  String get plugInputChoices => 'Plugin choices';

  @override
  String get plugInputGestureRequired => 'This effect requires a user tap';

  @override
  String get seamsTitle => 'In-app interface';

  @override
  String get seamsOverlay => 'Chat overlay';

  @override
  String get seamsOverlayNote => 'Stays over the chat and yields when memory is tight';

  @override
  String get seamsSidebarPage => 'Sidebar entry';

  @override
  String get seamsSettingsPage => 'Plugin settings page';

  @override
  String get seamsDetailPage => 'Plugin detail extension';

  @override
  String get pluginsOperationHostChanged => 'Host changed — nothing was done';

  @override
  String get pluginsReloadLocal => 'Restart engine to reload';

  @override
  String get pluginsReloadInterrupts => 'Interrupts running tasks';

  @override
  String pluginsReloadConfirm(String name) {
    return 'Reload “$name”?';
  }

  @override
  String get pluginsReloadExplanation =>
      'This restarts the local engine and reloads plugins. Running tasks will be interrupted.';

  @override
  String get pluginsReloadProceed => 'Restart and reload';

  @override
  String get pluginsReloadRequested => 'Engine restart requested';

  @override
  String get pluginsReloadChanged => 'The host or plugin state changed. Try again.';

  @override
  String get pluginsReloadFailed => 'Couldn’t restart the engine. Check its logs.';

  @override
  String get pluginsFile => 'File';

  @override
  String get pluginsChat => 'Chat';

  @override
  String get pluginsImage => 'Image';

  @override
  String get pluginsNamespaceDefaultModel => 'Default model';

  @override
  String get pluginsNamespaceDefaultPreset => 'Default preset';

  @override
  String get pluginsNamespaceAgent => 'Agent';

  @override
  String get pluginsNamespaceSubagent => 'Subagent';

  @override
  String get pluginsNamespaceSubagentModels => 'Subagent models';

  @override
  String get pluginsNamespaceDeepSeekModel => 'DeepSeek model';

  @override
  String get pluginsNamespaceAccountModel => 'DeepSeek account model';

  @override
  String get pluginsNamespaceCustomModels => 'Custom model service';

  @override
  String get pluginsNamespaceNetwork => 'Internet access';

  @override
  String get pluginsNamespaceWebSearch => 'Web search';

  @override
  String get pluginsNamespaceSearchApi => 'Web search API';

  @override
  String get pluginsNamespaceCommands => 'Command execution';

  @override
  String get pluginsNamespacePermissions => 'Permissions';

  @override
  String get pluginsNamespaceChatLog => 'Chat log';

  @override
  String get pluginsNamespaceThinkingTranslation => 'Thinking translation';

  @override
  String get pluginsNamespaceTranslation => 'Translation';

  @override
  String get pluginsNamespaceLanguage => 'Language';

  @override
  String get pluginsNamespaceWebAppearance => 'Web appearance';

  @override
  String get pluginsNamespaceWebChat => 'Web chat';

  @override
  String get pluginsNamespaceWebInput => 'Web input';

  @override
  String get pluginsNamespaceWebSettings => 'Web settings';

  @override
  String get pluginsNamespaceWebGeneral => 'Web general';

  @override
  String get pluginsNamespaceAutoReview => 'Auto review';

  @override
  String get pluginsNamespaceAgentTeam => 'Agent team';

  @override
  String get pluginsNamespaceVoiceInput => 'Voice input';

  @override
  String get pluginsOfficialPlugin => 'Official plugin';

  @override
  String get pluginsLocalUnshareable => 'Installed locally, can’t share';

  @override
  String pluginsIncludesPresets(String names) {
    return 'Includes presets “$names”';
  }

  @override
  String get pluginsSecretsUnshareable => 'Contains secrets, can’t share';

  @override
  String pluginsLineCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count lines', one: '1 line');
    return '$_temp0';
  }

  @override
  String get pluginsEmptyValue => 'Empty';

  @override
  String get pluginsOnValue => 'On';

  @override
  String get pluginsOffValue => 'Off';

  @override
  String get pluginsOfficialUnavailable => 'This host doesn’t have this official plugin';

  @override
  String get pluginsEnabled => 'Enabled';

  @override
  String get pluginsVersionMismatch => 'Version differs from the shared version';

  @override
  String get pluginsCurrentVersion => 'Current version';

  @override
  String get pluginsNewVersion => 'New version';

  @override
  String pluginsAddedWith(String title) {
    return 'Added with “$title”';
  }

  @override
  String pluginsApplyAfterInstall(String detail) {
    return 'Apply after installing plugins · $detail';
  }

  @override
  String get pluginsSettingsReadFailed => 'Couldn’t read this host’s settings';

  @override
  String get pluginsSettingUnavailable => 'This host doesn’t have this setting';

  @override
  String get pluginsSettingsReadOnly => 'This host’s settings are read-only';

  @override
  String get pluginsImportLocalOnly => 'Can only import to this phone';

  @override
  String get pluginsReplaceSkill => 'Replace skill with the same name';

  @override
  String get pluginsReplaceContent => 'Replace existing content';

  @override
  String get pluginsSafeModeInstallBlocked => 'Can’t install plugins in Safe mode';

  @override
  String get pluginsHostInstallBlocked => 'Can’t install plugins on this host from here';

  @override
  String get pluginsInstallFailed => 'Installation failed';

  @override
  String get pluginsAfterRestart => 'Takes effect after restart';

  @override
  String get pluginsSettingsChanged => 'Settings just changed';

  @override
  String get pluginsWriteFailed => 'Couldn’t write';

  @override
  String get pluginsHostUnreachable => 'Can’t reach the host';

  @override
  String get pluginsFileWriteFailed => 'Couldn’t write the file';

  @override
  String get pluginsProfileTitle => 'DSH Go settings';

  @override
  String get pluginsGistTokenInvalid => 'GitHub token is invalid or lacks Gist permission';

  @override
  String pluginsGistCreateHttpFailed(int status) {
    return 'Couldn’t create Gist (HTTP $status)';
  }

  @override
  String get pluginsGistCreateFailed => 'Couldn’t create Gist';

  @override
  String get pluginsGitHubUnreachable => 'Can’t reach GitHub';

  @override
  String get pluginsGitHubTimeout => 'Connection to GitHub timed out';

  @override
  String get pluginsGistNotFound => 'Gist not found';

  @override
  String get pluginsGistNoProfile => 'This Gist has no settings to import';

  @override
  String get pluginsGistReadFailed => 'Couldn’t read Gist';

  @override
  String get pluginsListReadFailed => 'Couldn’t read the plugin list';

  @override
  String get pluginsReadingPlugins => 'Reading plugins…';

  @override
  String get pluginsDshOfficial => 'DSH official';

  @override
  String get pluginsOfficialToggleOnly =>
      'Official components can only be turned on or off, and apply to all chats on this host';

  @override
  String get pluginsOfficial => 'Official';

  @override
  String get pluginsNoThirdParty => 'No third-party plugins yet';

  @override
  String get pluginsPluginsDescription => 'Add tools, memory, and models to DSH';

  @override
  String get pluginsBrowseMarket => 'Browse plugins';

  @override
  String get pluginsLoading => 'Loading';

  @override
  String get pluginsIslandClosed => 'Plugin interface closed';

  @override
  String get pluginsReopen => 'Reopen';

  @override
  String pluginsOpenBrowserHost(String host) {
    return 'Open $host in your browser?';
  }

  @override
  String get pluginsSearch => 'Search plugins';

  @override
  String get pluginsMarketLoading => 'Loading plugin directory…';

  @override
  String get pluginsMarketLoadFailed => 'Couldn’t open the plugin directory';

  @override
  String get pluginsMarketInvalid => 'Invalid directory format';

  @override
  String get pluginsAll => 'All';

  @override
  String pluginsMarketCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count plugins', one: '1 plugin');
    return '$_temp0 · from dshfind';
  }

  @override
  String get pluginsHideWeb => 'Hide Web plugins';

  @override
  String pluginsShowWebCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Show $count Web plugins',
      one: 'Show 1 Web plugin',
    );
    return '$_temp0';
  }

  @override
  String get pluginsNoCategoryPlugins => 'No plugins in this category';

  @override
  String pluginsNoSearchResults(String query) {
    return 'No results for “$query”';
  }

  @override
  String pluginsFailureDetails(String title) {
    return '$title · Tap to view';
  }

  @override
  String get pluginsFeatured => 'Recommended';

  @override
  String pluginsInstalledRemoteRestart(String name, String host) {
    return 'Installed “$name”. Restart DSH on $host to apply.';
  }

  @override
  String pluginsInstalledNamed(String name) {
    return 'Installed “$name”';
  }

  @override
  String get pluginsInstallCancelled => 'Installation cancelled';

  @override
  String pluginsInstallFailureNamed(String name, String reason) {
    return '“$name” $reason';
  }

  @override
  String get pluginsRestartRequired => 'Engine restart needed';

  @override
  String pluginsRestartExplanation(String name) {
    return 'Restart the engine to apply “$name”. Replies in progress will be interrupted.';
  }

  @override
  String get pluginsRestartEngine => 'Restart engine';

  @override
  String get pluginsAllowBuildScripts => 'Allow build scripts?';

  @override
  String get pluginsBuildScriptPackages => 'These packages run scripts during installation:';

  @override
  String pluginsBuildScriptWarning(String host) {
    return 'Scripts run with DSH’s permissions on $host and can read and write files and access the internet. Only allow this if you trust the plugin.';
  }

  @override
  String get pluginsThisDevice => 'This device';

  @override
  String get pluginsAllowRetry => 'Allow and retry';

  @override
  String pluginsUpdateNamed(String name) {
    return 'Update “$name”?';
  }

  @override
  String pluginsUninstallNamed(String title) {
    return 'Uninstall “$title”?';
  }

  @override
  String pluginsUninstallExplanation(String host) {
    return 'The plugin will be removed from $host. Its data and settings will stay.';
  }

  @override
  String get pluginsThisHost => 'This host';

  @override
  String get pluginsUninstall => 'Uninstall';

  @override
  String pluginsUninstalledNamed(String title) {
    return 'Uninstalled “$title”';
  }

  @override
  String get pluginsRestartNow => 'Restart now';

  @override
  String get pluginsUninstallFailed => 'Couldn’t uninstall';

  @override
  String get pluginsThatComputer => 'That computer';

  @override
  String get pluginsCommandAfterInstall => 'After installing, restart DSH on that computer, then refresh here';

  @override
  String get pluginsError => 'Error';

  @override
  String get pluginsInventoryTitle => 'Plugin inventory';

  @override
  String get pluginsGlobalPlugins => 'Global plugins';

  @override
  String get pluginsAgentPresets => 'Agent presets';

  @override
  String get pluginsInventoryReadFailed => 'Couldn’t read the plugin inventory';

  @override
  String pluginsComponentCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count components', one: '1 component');
    return '$_temp0';
  }

  @override
  String pluginsEnabledCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count enabled', one: '1 enabled');
    return '$_temp0';
  }

  @override
  String pluginsErrorCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count errors', one: '1 error');
    return '$_temp0';
  }

  @override
  String get pluginsNoPlugins => 'No plugins';

  @override
  String get pluginsNoMatchingPlugins => 'No matching plugins';

  @override
  String get pluginsPresetLoadFailed => 'Couldn’t load this preset';

  @override
  String get pluginsPresetNoPlugins => 'This preset has no plugins';

  @override
  String get pluginsStandard => 'Standard';

  @override
  String get pluginsMinimal => 'Minimal';

  @override
  String pluginsDefaultPresetName(String name) {
    return '$name (default)';
  }

  @override
  String get pluginsSystemComponents => 'System components';

  @override
  String pluginsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count items', one: '1 item');
    return '$_temp0';
  }

  @override
  String get pluginsSource => 'Source';

  @override
  String get pluginsDisableCondition => 'Disabled when';

  @override
  String get pluginsProvidedByPreset => 'Provided by preset';

  @override
  String get pluginsDetailsTitle => 'Plugin details';

  @override
  String pluginsPackageInfoError(String error) {
    return 'Invalid package info: $error';
  }

  @override
  String get pluginsInstalling => 'Installing';

  @override
  String get pluginsGet => 'Get';

  @override
  String get pluginsLoadingCannotCancel => 'Loading the plugin. This step can’t be cancelled.';

  @override
  String get pluginsInstallDuration => 'Takes a minute or two. You can leave this page.';

  @override
  String get pluginsViewInstallLogs => 'View install logs';

  @override
  String get pluginsViewDetails => 'View details';

  @override
  String get pluginsCopyCommand => 'Copy command';

  @override
  String get pluginsCommandCopied => 'Command copied';

  @override
  String get pluginsMissingFiles => 'Plugin files are missing. Reinstall to fix.';

  @override
  String get pluginsNotDshPlugin => 'Not a DSH plugin, can’t load';

  @override
  String get pluginsIncompatible => 'Incompatible with this DSH version, not loaded';

  @override
  String pluginsRequiresDshVersion(String requiredVersion, String currentVersion) {
    return 'Requires DSH $requiredVersion, currently $currentVersion, not loaded';
  }

  @override
  String pluginsLoadFailure(String reason) {
    return 'Couldn’t load: $reason';
  }

  @override
  String get pluginsUnknownReason => 'Unknown reason';

  @override
  String pluginsBundleProblem(String reason) {
    return 'Problem: $reason';
  }

  @override
  String pluginsRefreshFailure(String reason) {
    return 'Couldn’t refresh: $reason';
  }

  @override
  String get pluginsTitle => 'Plugins';

  @override
  String get pluginsRefresh => 'Refresh';

  @override
  String get pluginsMarketTitle => 'Plugin market';

  @override
  String get pluginsConnectToManage => 'Connect to the engine to manage plugins';

  @override
  String get pluginsSafeModeOperationsBlocked => 'Can’t install or uninstall plugins in Safe mode';

  @override
  String pluginsRelayToggleOnly(String host) {
    return '$host · Relay only supports turning plugins on or off. Install on that computer.';
  }

  @override
  String get pluginsInstallThisPhone => 'Install to: This phone';

  @override
  String pluginsInstallHost(String host) {
    return 'Install to: $host';
  }

  @override
  String get pluginsOfflineDescription =>
      'Installed plugins appear when the engine is running. You can browse the market now.';

  @override
  String get pluginsIconChanged => 'Icon selected. Return to your home screen to see the change.';

  @override
  String get pluginsIconChangeFailed => 'Couldn’t change the icon. Try again later.';

  @override
  String get pluginsTheme => 'Theme';

  @override
  String get pluginsAppearance => 'Appearance';

  @override
  String get pluginsColors => 'Colors';

  @override
  String get pluginsFeatureIcons => 'Feature icons';

  @override
  String get pluginsAppIcon => 'App icon';

  @override
  String get pluginsPet => 'Pet';

  @override
  String get pluginsCustomColor => 'Custom';

  @override
  String pluginsColorLabel(String label) {
    return 'Color: $label';
  }

  @override
  String get pluginsCoral => 'Coral';

  @override
  String get pluginsRouge => 'Rouge';

  @override
  String get pluginsOchre => 'Ochre';

  @override
  String get pluginsMoss => 'Moss';

  @override
  String get pluginsLake => 'Lake';

  @override
  String get pluginsIndigo => 'Indigo';

  @override
  String get pluginsHue => 'Hue';

  @override
  String get pluginsWallpaper => 'Wallpaper';

  @override
  String get pluginsFollowWallpaper => 'Use wallpaper colors';

  @override
  String get pluginsAllowHighPower => 'Allow high background power usage';

  @override
  String pluginsVivoBatteryPath(String app) {
    return 'Battery › Background power consumption management › $app';
  }

  @override
  String get pluginsXiaomiBatterySetting => 'Battery saver: No restrictions';

  @override
  String pluginsXiaomiBatteryPath(String app) {
    return 'Manage apps › $app › Battery saver';
  }

  @override
  String get pluginsHuaweiBatterySetting => 'Allow background activity';

  @override
  String pluginsHuaweiBatteryPath(String app) {
    return 'Battery › App launch › $app';
  }

  @override
  String get pluginsOppoBatterySetting => 'Allow background activity';

  @override
  String pluginsOppoBatteryPath(String app) {
    return 'Battery › App battery management › $app';
  }

  @override
  String get pluginsSamsungBatterySetting => 'Battery: Unrestricted';

  @override
  String pluginsSamsungBatteryPath(String app) {
    return 'Apps › $app › Battery';
  }

  @override
  String get pluginsVivoBatteryStep => 'Turn on “Allow high background power usage”';

  @override
  String pluginsXiaomiBatteryFullPath(String app) {
    return 'App settings › Manage apps › $app › Battery saver › No restrictions';
  }

  @override
  String get pluginsXiaomiAutostart => 'Turn on “Autostart” on the same page';

  @override
  String get pluginsHuaweiBatteryStep => 'Turn off “Manage automatically” and turn on “Allow background activity”';

  @override
  String get pluginsOppoBatteryStep => 'Turn on “Allow background activity”';

  @override
  String get pluginsSamsungBatteryStep => 'Select “Unrestricted”';

  @override
  String get pluginsBackgroundTitle => 'Background running';

  @override
  String get pluginsBackgroundDescription => 'Let chats finish in the background';

  @override
  String get pluginsSystem => 'System';

  @override
  String get pluginsSystemBatteryOptimization => 'System battery optimization';

  @override
  String get pluginsTurnedOff => 'Off';

  @override
  String get pluginsNotTurnedOff => 'On';

  @override
  String get pluginsStayOnline => 'Stay online';

  @override
  String get pluginsKeepEngineNotification => 'Keep the “Engine running” notification';

  @override
  String pluginsLockInRecents(String app) {
    return 'Lock $app in recent apps';
  }

  @override
  String get pluginsPhoneBrands => 'Phone brands';

  @override
  String get pluginsOtherBrands => 'Other brands';

  @override
  String pluginsConnectedHost(String host) {
    return 'Connected ($host)';
  }

  @override
  String pluginsConnectionError(String error) {
    return 'Couldn’t connect: $error';
  }

  @override
  String get pluginsConnecting => 'Connecting';

  @override
  String get pluginsDiagnosticsCopied => 'Diagnostics copied';

  @override
  String get pluginsDiagnostics => 'Diagnostics';

  @override
  String get pluginsDiagnosticsDescription => 'Include with bug reports. No API keys or tokens.';

  @override
  String get pluginsRuntime => 'Runtime';

  @override
  String get pluginsArchitecture => 'Architecture';

  @override
  String get pluginsBundledVersion => 'Bundled version';

  @override
  String get pluginsInstalledVersion => 'Installed version';

  @override
  String get pluginsErrorLabel => 'Error';

  @override
  String get pluginsConnection => 'Connection';

  @override
  String get pluginsAddress => 'Address';

  @override
  String get pluginsClient => 'Client';

  @override
  String get pluginsConfigured => 'Set';

  @override
  String get pluginsExport => 'Export';

  @override
  String get pluginsCopyDiagnostics => 'Copy diagnostics';

  @override
  String get pluginsDiagnosticsContents => 'Versions and connection status only';

  @override
  String get pluginsNotificationsPartlyBlocked => 'Some blocked by system';

  @override
  String get pluginsNotificationsBlocked => 'Blocked by system';

  @override
  String get pluginsTurnedOn => 'On';

  @override
  String get pluginsNotifications => 'Notifications';

  @override
  String get pluginsNotificationSettingsFailed =>
      'Couldn’t open system settings. Turn on notifications in Settings → Apps → DSH Go → Notifications.';

  @override
  String get pluginsSystemNotificationsOff => 'System notifications are off';

  @override
  String get pluginsBackgroundNoAlerts => 'You won’t get alerts while the app is in the background';

  @override
  String get pluginsApprovalNotificationsOff => '“Needs approval” notifications are off';

  @override
  String get pluginsBackgroundNoApprovalAlerts => 'You won’t get approval alerts while the app is in the background';

  @override
  String get pluginsDoneNotificationsOff => '“Turn ended” notifications are off';

  @override
  String get pluginsBackgroundNoDoneAlerts =>
      'You won’t get completion or error alerts while the app is in the background';

  @override
  String get pluginsTurnOn => 'Turn on';

  @override
  String get pluginsNotificationsDescription => 'Get alerts when chats finish or need you';

  @override
  String get pluginsAllowNotifications => 'Allow notifications';

  @override
  String get pluginsNotificationsAndBanners => 'System notifications and top banners';

  @override
  String get pluginsAlerts => 'Alerts';

  @override
  String get pluginsRemoteAlertsRequirement => 'Remote host alerts need the app running and connected';

  @override
  String get pluginsTurnComplete => 'Turn complete';

  @override
  String get pluginsReplyPreview => 'Include the start of the reply';

  @override
  String get pluginsErrorOrStopped => 'Error or stopped';

  @override
  String get pluginsErrorOrStoppedDescription => 'Request failed, engine restarted, or stopped';

  @override
  String get pluginsApprovalDescription => 'Approval needed to run commands, edit files, and more';

  @override
  String get pluginsQuestions => 'Questions for you';

  @override
  String get pluginsQuestionsDescription => 'AI needs your answer';

  @override
  String get pluginsSystemSettings => 'System settings';

  @override
  String get pluginsLockScreenPrivacy => 'Chat content stays hidden on the lock screen';

  @override
  String get pluginsSoundBannerLockScreen => 'Sound, banners, and lock screen';

  @override
  String get pluginsEnableFloatingNotifications => 'Turn on “Floating notifications” if banners don’t appear';

  @override
  String get pluginsPersonalPreferences => 'Personal preferences';

  @override
  String get pluginsPreferencesDescription => 'New chats will follow these instructions';

  @override
  String get pluginsPreferencesHint => 'For example: Reply in Chinese. I mainly write Flutter.';

  @override
  String get pluginsSaving => 'Saving';

  @override
  String get pluginsShareLink => 'Share link';

  @override
  String get pluginsInstallPlugin => 'Install plugin';

  @override
  String get pluginsImportProfile => 'Import settings';

  @override
  String get pluginsImportTo => 'Import to';

  @override
  String get pluginsInstallTo => 'Install to';

  @override
  String get pluginsVerification => 'Verification';

  @override
  String get pluginsSize => 'Size';

  @override
  String get pluginsVerified => 'Verified';

  @override
  String get pluginsVerificationMismatch => 'Verification mismatch';

  @override
  String get pluginsCannotVerify => 'Can’t verify';

  @override
  String get pluginsVerifying => 'Verifying';

  @override
  String get pluginsPresets => 'Presets';

  @override
  String get pluginsSkills => 'Skills';

  @override
  String get pluginsAdded => 'Added';

  @override
  String get pluginsModified => 'Modified';

  @override
  String get pluginsNoChanges => 'No changes needed';

  @override
  String get pluginsUnavailable => 'Unavailable';

  @override
  String get pluginsHostProfileReadFailed => 'Couldn’t read this host’s settings';

  @override
  String get pluginsAlreadyMatches => 'This host already matches';

  @override
  String get pluginsUnsuccessful => 'Failed';

  @override
  String get pluginsSkipped => 'Skipped';

  @override
  String get pluginsView => 'Inspect';

  @override
  String get pluginsImport => 'Import';

  @override
  String get pluginsHostPluginsReadFailed => 'Couldn’t read this host’s plugins';

  @override
  String pluginsUpdateTo(String version) {
    return 'Update to $version';
  }

  @override
  String pluginsImportCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Import $count items',
      one: 'Import 1 item',
    );
    return '$_temp0';
  }

  @override
  String get pluginsImporting => 'Importing';

  @override
  String get pluginsInstallingActive => 'Installing';

  @override
  String pluginsImportFailedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items failed',
      one: '1 item failed',
    );
    return '$_temp0';
  }

  @override
  String get pluginsCouldNotInstall => 'Couldn’t install';

  @override
  String get pluginsEngineRestartToApply => 'Restart the engine to apply';

  @override
  String pluginsRemoteRestartToApply(String host) {
    return 'Restart DSH on $host to apply';
  }

  @override
  String pluginsImportedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Imported $count items',
      one: 'Imported 1 item',
    );
    return '$_temp0';
  }

  @override
  String get pluginsLocalPluginUnshareable => 'This plugin was installed locally and can’t be shared';

  @override
  String get pluginsSharePlugin => 'Share plugin';

  @override
  String pluginsPluginCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count plugins', one: '1 plugin');
    return '$_temp0';
  }

  @override
  String pluginsSettingsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count settings', one: '1 setting');
    return '$_temp0';
  }

  @override
  String pluginsPresetCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count presets', one: '1 preset');
    return '$_temp0';
  }

  @override
  String pluginsSkillCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count skills', one: '1 skill');
    return '$_temp0';
  }

  @override
  String get pluginsNothingSelected => 'Nothing selected';

  @override
  String get pluginsNext => 'Next';

  @override
  String get pluginsNothingToShare => 'Nothing to share';

  @override
  String get pluginsProfileReadFailed => 'Couldn’t read settings';

  @override
  String get pluginsShareProfile => 'Share configuration';

  @override
  String pluginsFileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count files', one: '1 file');
    return '$_temp0';
  }

  @override
  String get pluginsShareNeedsUpdate => 'Update the app to open this';

  @override
  String get pluginsShareUnusable => 'This share code can’t be used';

  @override
  String get pluginsShareDamaged => 'This share code is incomplete or damaged';

  @override
  String get pluginsShareFileReadFailed => 'Couldn’t read this file';

  @override
  String get pluginsShareOpenFailed => 'Couldn’t open this share code';

  @override
  String get pluginsPluginShareTitle => 'DSH Go plugin';

  @override
  String get pluginsShareSheetOpenFailed => 'Couldn’t open sharing';

  @override
  String get pluginsSavePermissionDenied => 'Couldn’t save without storage permission';

  @override
  String get pluginsQrCode => 'QR code';

  @override
  String get pluginsSaveAsFile => 'Save as file';

  @override
  String get pluginsGistLinkReady => 'Gist link created';

  @override
  String get pluginsTooLargeShareFile => 'Too much content. Share as a file.';

  @override
  String get pluginsGenerateLink => 'Create link';

  @override
  String get pluginsGitHubToken => 'GitHub token';

  @override
  String get pluginsGistPermissionNeeded => 'Gist permission required';

  @override
  String get pluginsGenerateGistLink => 'Create Gist link';

  @override
  String get pluginsShareQrCode => 'Share code QR code';

  @override
  String pluginsUpdateCurrentWarning(String to) {
    return 'The current version will be uninstalled, then $to installed. If installation fails, the plugin will need to be reinstalled.';
  }

  @override
  String pluginsUpdateVersionWarning(String from, String to) {
    return '$from will be uninstalled, then $to installed. If installation fails, the plugin will need to be reinstalled.';
  }

  @override
  String pluginsUninstalledRestartLocal(String title) {
    return 'Uninstalled “$title”. Restart the engine to finish removing it.';
  }

  @override
  String pluginsUninstalledRestartRemote(String title, String host) {
    return 'Uninstalled “$title”. Restart DSH on $host to finish removing it.';
  }

  @override
  String get pluginsEnableFailed => 'Couldn’t enable';

  @override
  String get pluginsDisableFailed => 'Couldn’t disable';

  @override
  String get pluginsEnabledRestartLocal => 'Enabled. Restart the engine to apply.';

  @override
  String pluginsEnabledRestartRemote(String host) {
    return 'Enabled. Restart DSH on $host to apply.';
  }

  @override
  String get pluginsDisabledRestartLocal => 'Disabled. Restart the engine to apply.';

  @override
  String pluginsDisabledRestartRemote(String host) {
    return 'Disabled. Restart DSH on $host to apply.';
  }

  @override
  String pluginsRelayCommandInstruction(String host) {
    return 'DSH Remote only supports turning plugins on or off. Run this in a terminal on $host:';
  }

  @override
  String get pluginsPermissionLocalThirdParty =>
      'Plugins run with DSH’s permissions: they can read and write files, run commands, and read API keys and phone storage you’ve granted access to. They aren’t restricted by the workspace sandbox. Provided by a third party and not reviewed by DSH.';

  @override
  String get pluginsPermissionLocalTrusted =>
      'Plugins run with DSH’s permissions: they can read and write files, run commands, and read API keys and phone storage you’ve granted access to. They aren’t restricted by the workspace sandbox. Only install plugins you trust.';

  @override
  String get pluginsPermissionRemoteThirdParty =>
      'Plugins run with DSH’s permissions: they can read and write files, run commands, and read API keys. They aren’t restricted by the workspace sandbox. Provided by a third party and not reviewed by DSH.';

  @override
  String get pluginsPermissionRemoteTrusted =>
      'Plugins run with DSH’s permissions: they can read and write files, run commands, and read API keys. They aren’t restricted by the workspace sandbox. Only install plugins you trust.';

  @override
  String pluginsSelectedQrCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items selected',
      one: '1 item selected',
    );
    return '$_temp0 · QR code available';
  }

  @override
  String pluginsSelectedFileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items selected',
      one: '1 item selected',
    );
    return '$_temp0 · Share as a file';
  }

  @override
  String get pluginsListSeparator => ', ';

  @override
  String pluginsActionFailure(String action, String reason) {
    return '$action: $reason';
  }

  @override
  String pluginsInventorySemantics(String title, String status) {
    return '$title, $status';
  }

  @override
  String pluginsSettingsChanges(String shown, int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count items', one: '1 item');
    return '$shown and more · $_temp0';
  }

  @override
  String get pluginsLoadStatus => 'Load status';

  @override
  String get pluginsLoadPartial => 'Partly active';

  @override
  String get pluginsLoadFailed => 'Load failed';

  @override
  String get pluginsLoadNotReady => 'Not ready';

  @override
  String get pluginsLoadMetadata => 'Metadata diagnostics';

  @override
  String pluginsLoadRunningCount(int running, int total) {
    return '$running of $total components running';
  }

  @override
  String get pluginsLoadUnreported => 'Not reported';

  @override
  String get pluginsLoadNoRuntimeDetail => 'The host did not return the runtime error details. Check its engine logs.';

  @override
  String get pluginsLoadRemoteLogs => 'Check the engine logs on this host.';

  @override
  String get plugslotsSurfaceComposerTools => 'Plus panel tools';

  @override
  String get plugslotsSurfaceSessionActions => 'Chat actions';

  @override
  String get plugslotsSurfaceTurnNote => 'Turn notes';

  @override
  String get plugslotsSurfaceComposerActions => 'Composer buttons';

  @override
  String get plugslotsSurfaceMessageActions => 'Message menu';

  @override
  String get plugslotsSurfaceComposerStrip => 'Status line';

  @override
  String get plugslotsSurfacePanel => 'Panels';

  @override
  String get plugslotsNativeUi => 'Native UI';

  @override
  String plugslotsIssueCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count problems', one: '1 problem');
    return '$_temp0';
  }

  @override
  String get plugslotsAllGood => 'No problems';

  @override
  String plugslotsViewSize(String size) {
    return 'View $size';
  }

  @override
  String plugslotsInvokeMs(int ms) {
    return '$ms ms';
  }

  @override
  String get plugslotsLastView => 'Last view';

  @override
  String get plugslotsLastInvoke => 'Last response';

  @override
  String get plugslotsProblems => 'Problems';

  @override
  String get plugslotsNoProblems => 'No problems';

  @override
  String plugslotsWantsDraft(String plugin) {
    return '$plugin wants to read your draft';
  }

  @override
  String plugslotsWantsClipboard(String plugin) {
    return '$plugin wants to read your clipboard';
  }

  @override
  String plugslotsWantsBoth(String plugin) {
    return '$plugin wants to read your draft and clipboard';
  }

  @override
  String get plugslotsWantsWhen => 'Only when you tap it';

  @override
  String get plugslotsAllow => 'Allow';

  @override
  String plugslotsNoResponse(String plugin) {
    return '$plugin didn\'t respond';
  }

  @override
  String plugslotsFailed(String plugin) {
    return '$plugin ran into a problem';
  }

  @override
  String get plugslotsNeedsChat => 'Open a chat first';

  @override
  String plugslotsFromPlugin(String plugin) {
    return 'From $plugin';
  }

  @override
  String get plugslotsPanelOffline => 'Can\'t reach the plugin';

  @override
  String plugslotsIssueTooMany(int max) {
    return 'Up to $max; the rest are hidden';
  }

  @override
  String plugslotsIssueTrimmed(int max) {
    return 'Over $max characters; shortened';
  }

  @override
  String plugslotsIssueNeedsApp(String version) {
    return 'Needs DSH Go $version or later';
  }

  @override
  String get plugslotsIssueNewerProtocol => 'Needs a newer app';

  @override
  String get plugslotsIssueUnknownIcon => 'Unknown icon; using the default';

  @override
  String plugslotsIssueUnknownEffect(String name) {
    return 'Unsupported effect \"$name\"';
  }

  @override
  String get plugslotsIssueLate => 'Came back more than 3 s after the tap; ignored';

  @override
  String get plugslotsIssueHttps => 'Only https links';

  @override
  String plugslotsIssueUnknownPage(String page) {
    return 'No page called \"$page\"';
  }

  @override
  String get plugslotsIssueThrottled => 'Notices too frequent; skipped';

  @override
  String plugslotsIssueInvoke(String message) {
    return 'Call failed: $message';
  }

  @override
  String plugslotsIssueStream(String message) {
    return 'Data failed: $message';
  }

  @override
  String get plugslotsIssueMissing => 'Missing a required field';

  @override
  String get plugslotsIssueDuplicate => 'Duplicate id; skipped';

  @override
  String get plugslotsIssueNoPlacement => 'Nowhere to show it';

  @override
  String plugslotsWantsMessage(String plugin) {
    return '$plugin wants to read this reply';
  }

  @override
  String get plugslotsCodeInvalidManifest => 'The declaration is invalid; native parts are off';

  @override
  String get plugslotsCodeInvalidField => 'Wrong format; skipped';

  @override
  String get plugslotsCodeUnknownField => 'Unknown field; ignored';

  @override
  String get plugslotsCodeUnknownSurface => 'Not supported here yet; ignored';

  @override
  String get plugslotsCodeTooMany => 'Too many; the extras are hidden';

  @override
  String get plugslotsCodeTooLong => 'Too long; shortened';

  @override
  String get plugslotsCodeNoHandler => 'Not handled by the plugin yet; hidden';

  @override
  String get plugslotsCodeUndeclared => 'Registered but not declared; ignored';

  @override
  String get plugslotsCodeViewFile => 'Couldn\'t read the view file';

  @override
  String get plugslotsCodeBadEffect => 'Malformed action; skipped';

  @override
  String plugslotsCodeViolation(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count times', one: 'once');
    return 'Failed $_temp0';
  }

  @override
  String get plugslotsCodeDegraded => 'Too many errors; off until the next start';

  @override
  String get plugslotsCodeTimeout => 'The plugin didn\'t answer in time';

  @override
  String get plugslotsCodeRateLimited => 'Tapped too fast';

  @override
  String get plugslotsCodeNotFound => 'The plugin is off or missing';

  @override
  String get plugslotsCodePluginError => 'The plugin failed';

  @override
  String get plugslotsCodeInvalidView => 'The view is invalid';

  @override
  String get plugslotsCodeLimit => 'Too many subscriptions';

  @override
  String get plugslotsCodeOther => 'Other problem';

  @override
  String get plugslotsCodeUnknownEffect => 'Unsupported action; skipped';

  @override
  String get plugslotsNotDone => 'Didn\'t finish';

  @override
  String get plugslotsWorking => 'Working';

  @override
  String get plugslotsTapToCancel => 'Tap to cancel';

  @override
  String get plugslotsCodeTooManyPending => 'Two are still running';

  @override
  String get plugslotsCodeNoStream => 'The connection dropped';

  @override
  String plugslotsVoiceAsk(String plugin) {
    return 'Let $plugin hear you speak?';
  }

  @override
  String get plugslotsVoiceWhen =>
      'Reading stops the moment you speak. Your voice is checked on this phone, never saved or sent';

  @override
  String get plugslotsVoiceDeny => 'Don\'t allow';

  @override
  String get plugslotsVoiceSwitch => 'Hear you speak';

  @override
  String get plugslotsPickerUnavailable => 'File selection is unavailable on this device';

  @override
  String get plugslotsPickerBusy => 'Finish the current file selection first';

  @override
  String plugslotsPickerLimit(int count) {
    return 'Up to $count files, 8 MiB each and 16 MiB total';
  }

  @override
  String get plugslotsPickerFailed => 'Could not share the files with this plugin. Try again';

  @override
  String get plugslotsWebPlacesTitle => 'In DSH Web';

  @override
  String get plugslotsPlaceBesideComposer => 'Beside the composer';

  @override
  String get plugslotsPlaceHeader => 'Conversation header';

  @override
  String get plugslotsPlaceMessages => 'In messages';

  @override
  String get plugslotsPlaceOverlay => 'Floating layer';

  @override
  String get plugslotsPlaceSidebar => 'Sidebar';

  @override
  String get plugslotsPlaceRightbar => 'Right sidebar';

  @override
  String get plugslotsPlaceFiles => 'File previews';

  @override
  String get plugslotsPlaceSettings => 'Settings';

  @override
  String get plugslotsPlacePlugins => 'Plugins page';

  @override
  String get plugslotsPlaceNewChat => 'New conversation';

  @override
  String get plugslotsPlaceElsewhere => 'Elsewhere';

  @override
  String get plugslotsPlaceUnknown => 'Its web interface';

  @override
  String get plugslotsChatEntry => 'Plugins';

  @override
  String plugslotsChatWebFrom(String names) {
    return 'Web plugins · $names';
  }

  @override
  String get plugViewInvalid => 'Plugin view has an error';

  @override
  String get plugViewEmpty => 'No data yet';

  @override
  String get plugViewImageUnavailable => 'Can’t display image';

  @override
  String get plugViewUnavailableList => 'Can’t display list';

  @override
  String get plugViewUnavailableKeyValue => 'Can’t display details';

  @override
  String get plugViewUnavailableProgress => 'Can’t display progress';

  @override
  String get plugViewUnavailableTable => 'Can’t display table';

  @override
  String get plugViewUnavailableActions => 'Can’t display buttons';

  @override
  String plugViewFrom(String name) {
    return 'From $name';
  }

  @override
  String plugViewUnknownTone(String value) {
    return 'Unknown tone $value, ignored; available: good, warn, bad, info, muted';
  }

  @override
  String plugViewBadActionId(String value) {
    return 'Invalid action id $value; this element isn’t tappable';
  }

  @override
  String plugViewBadAction(String shape) {
    return 'An action must be an id string or $shape; ignored';
  }

  @override
  String plugViewArgsLimit(int limit) {
    String _temp0 = intl.Intl.pluralLogic(limit, locale: localeName, other: '$limit bytes', one: '1 byte');
    return 'Action args exceed $_temp0; ignored';
  }

  @override
  String plugViewUnknownIcon(String value) {
    return 'Unknown icon $value; drawn with the default icon';
  }

  @override
  String plugViewExpectedItems(String shape) {
    return 'Expected an array of $shape';
  }

  @override
  String plugViewSkippedItem(String shape) {
    return 'Expected $shape; item skipped';
  }

  @override
  String get plugViewBadMax => 'max must be a number above 0; using 100';

  @override
  String plugViewColumnLimit(int first, int second) {
    String _temp0 = intl.Intl.pluralLogic(first, locale: localeName, other: '$first columns', one: '1 column');
    return '$_temp0, exceeding the limit of $second';
  }

  @override
  String plugViewFirstColumns(int limit) {
    String _temp0 = intl.Intl.pluralLogic(limit, locale: localeName, other: '$limit columns', one: '1 column');
    return 'Showing only the first $_temp0';
  }

  @override
  String plugViewFirstRows(int limit) {
    String _temp0 = intl.Intl.pluralLogic(limit, locale: localeName, other: '$limit rows', one: '1 row');
    return 'Showing only the first $_temp0';
  }

  @override
  String get plugViewOnePrimary => 'A view has at most one primary button; this one is drawn as plain';

  @override
  String get plugViewBadImageSource =>
      'Images take a plugin asset (asset:<path>, png, jpg, webp or gif) or a data:image/… URL';

  @override
  String get plugViewBadAspect => 'aspect must be a number from 0.25 to 4; ignored';

  @override
  String plugViewImageTooLarge(int limit) {
    String _temp0 = intl.Intl.pluralLogic(limit, locale: localeName, other: '$limit bytes', one: '1 byte');
    return 'data: image exceeds $_temp0';
  }

  @override
  String get plugViewImageDecode => 'Image can’t be decoded (PNG, JPEG, WebP or GIF only)';

  @override
  String get plugViewImagePixels => 'Image exceeds the size limit: 4096 per side, 4 million pixels in total';

  @override
  String plugViewTooDeep(int limit) {
    String _temp0 = intl.Intl.pluralLogic(limit, locale: localeName, other: '$limit levels', one: '1 level');
    return 'JSON nested deeper than $_temp0';
  }

  @override
  String get plugViewV2Content => 'Plugin content';

  @override
  String plugViewVersionFallback(String version) {
    return 'View version $version is not supported; using the compatible view';
  }

  @override
  String plugViewStyleInvalid(String values) {
    return 'Invalid style; expected $values';
  }

  @override
  String get plugViewStyleReserved => 'This appearance is reserved for the app; ignored';

  @override
  String get plugViewStyleContainerOnly => 'This style is only available on stack and row';

  @override
  String get plugViewStyleTextOnly => 'This style is only available on text, metric and callout';

  @override
  String plugViewContrastAdjusted(String mode, String before, String after, String minimum) {
    return '$mode: $before adjusted to $after, contrast at least $minimum:1';
  }

  @override
  String get plugViewRichLimit => 'Rich text exceeds the limit; truncated';

  @override
  String plugViewBadTrend(int max) {
    return 'trend takes 2–$max numbers (nulls allowed); ignored';
  }

  @override
  String plugViewGalleryPicture(int index) {
    return 'Picture $index';
  }

  @override
  String get readListUpdating => 'Updating · previous results';

  @override
  String get readListOffline => 'Offline · previous results';

  @override
  String get readListFailed => 'Not updated · previous results';

  @override
  String get remoteDshMode => 'Instance management';

  @override
  String get remoteManaged => 'Managed';

  @override
  String get remoteAttachOnly => 'Attach only';

  @override
  String get remoteManagedHelp =>
      'Start or reuse app-managed DSH. A live instance that cannot be reused is never replaced automatically.';

  @override
  String get remoteAttachOnlyHelp =>
      'Forward only to a fixed port on remote 127.0.0.1. Never start, stop or restart DSH.';

  @override
  String get remoteDshPort => 'Remote DSH port';

  @override
  String get remoteDshToken => 'DSH launch token';

  @override
  String get remoteDshTokenHelp =>
      'Enter the token from the existing instance’s launch URL. It stays in secure storage on this phone.';

  @override
  String get remoteAttachWorkingDirectoryHelp =>
      'Existing instances are not probed for a home directory. Use a remote absolute path, or leave empty for DSH’s default.';

  @override
  String get remoteSshCompression => 'SSH compression';

  @override
  String get remoteSshCompressionHelp =>
      'On by default. Negotiate compression after authentication; use uncompressed transport if unsupported.';

  @override
  String get remoteRestartManaged => 'Restart managed DSH';

  @override
  String get remoteRestartManagedWarning =>
      'This stops the remote DSH recorded by the app and starts it again. Other clients and active chats may be interrupted. Continue only after checking nobody else is using it. Normal connection tests never do this.';

  @override
  String get remoteErrSharedInstance =>
      'Remote managed DSH is still running, but its start command differs or its launch log is missing. To protect shared use, it was not restarted. Check the settings, use Attach only, or explicitly choose Restart managed DSH in Edit host.';

  @override
  String get remoteErrAttachSettings => 'Enter a valid remote DSH port and launch token';

  @override
  String get remoteDshAttached => 'Connected to existing DSH';

  @override
  String get remoteStartupSection => 'On launch';

  @override
  String get remoteAutoConnectOnStartup => 'Connect to the last host';

  @override
  String get remoteAutoConnectOnStartupHint => 'When off, start on this phone';

  @override
  String get remoteStepConnect => 'Connect to server';

  @override
  String get remoteStepVerifyHostKey => 'Verify host fingerprint';

  @override
  String get remoteStepStartDsh => 'Start DSH';

  @override
  String get remoteStepTunnel => 'Create tunnel';

  @override
  String get remoteConnecting => 'Connecting';

  @override
  String get remoteConnected => 'Connected';

  @override
  String get remoteReconnecting => 'Reconnecting';

  @override
  String remoteReconnectAttempt(int count) {
    return 'Reconnecting · Attempt $count';
  }

  @override
  String get remoteErrInvalidServer => 'Invalid server address';

  @override
  String get remoteErrEmailPassword => 'Incorrect email or password';

  @override
  String get remoteErrHostNotInAccount => 'This host isn’t in your account';

  @override
  String get remoteHostFallback => 'This host';

  @override
  String get remoteErrHostOffline => 'Host is offline';

  @override
  String remoteErrHostRemoved(String name) {
    return '$name is no longer in your DSH Remote account';
  }

  @override
  String get remoteErrRelaySignInExpired => 'DSH Remote sign-in expired';

  @override
  String get remoteErrIdentityKeyChanged => 'Host identity key has changed';

  @override
  String get remoteErrIdentityUnconfirmed => 'Host identity fingerprint hasn’t been confirmed';

  @override
  String get remoteErrConnectionReplaced => 'Remote connection was replaced';

  @override
  String get remoteErrHostRejected => 'Host declined the connection';

  @override
  String get remoteErrHostNotOwned => 'Host isn’t in your DSH Remote account';

  @override
  String get remoteErrUpdateNeeded => 'Version mismatch. Update DSH Go and the host’s remote plugin';

  @override
  String get remoteErrVersionIncompatible => 'Update DSH or the remote plugin on the host';

  @override
  String get remoteErrSignInTimeout => 'Sign-in timed out';

  @override
  String get remoteSignInCancelled => 'Sign-in cancelled';

  @override
  String get remoteErrBrowserSignInUnsupported => 'Server doesn’t support browser sign-in';

  @override
  String get remoteErrTooManyRequests => 'Too many requests';

  @override
  String get remoteErrHostUnreachable => 'Can’t reach the remote host';

  @override
  String get remoteErrRemoteConnection => 'Couldn’t connect remotely';

  @override
  String get remoteOnline => 'Online';

  @override
  String get remoteOffline => 'Offline';

  @override
  String get remoteUnavailable => 'Unavailable';

  @override
  String get remoteErrHostNotFound => 'Host not found';

  @override
  String get remoteConnectionStopped => 'Remote connection stopped';

  @override
  String remoteBootstrapReusePort(int port) {
    return 'Using running DSH (port $port)';
  }

  @override
  String get remoteBootstrapStarting => 'Starting remote DSH…';

  @override
  String remoteErrCommandNotFound(String command) {
    return '“$command” not found on the host';
  }

  @override
  String get remoteErrDshMissing =>
      'dsh isn’t installed on the host. Install it and retry, or enter its full path as the start command.';

  @override
  String get remoteStartCommandExample => 'Example start command: ~/.nvm/versions/node/v22.0.0/bin/dsh web';

  @override
  String get remoteErrDshStartTimeout => 'Remote DSH took too long to start';

  @override
  String get remoteErrDshExited => 'Remote DSH exited right after starting';

  @override
  String get remoteErrDshStart => 'Couldn’t start remote DSH';

  @override
  String remoteExitCode(int code) {
    return 'Exit code $code';
  }

  @override
  String get remoteErrNoShell => 'Host has no sh. Only Linux and macOS are supported.';

  @override
  String get remoteErrFingerprintChanged => 'Host fingerprint changed. Disconnected.';

  @override
  String get remoteErrFingerprintUnconfirmed => 'Host fingerprint hasn’t been confirmed';

  @override
  String get remoteHostTrustCancelled => 'Host trust cancelled';

  @override
  String get remoteCheckingDsh => 'Checking remote DSH…';

  @override
  String get remoteErrDshPort => 'Can’t reach the remote DSH port';

  @override
  String get remoteDshReused => 'Using DSH already running on the host';

  @override
  String get remoteDshStarted => 'Started DSH on the host';

  @override
  String get remoteErrDshTokenRejected =>
      'Remote DSH rejected the token; it was not restarted. Check the token, or explicitly restart the managed instance in Edit host.';

  @override
  String get remoteErrDshSignIn => 'Couldn’t sign in to remote DSH';

  @override
  String get remoteErrDshTunnel => 'Couldn’t connect to DSH through the tunnel';

  @override
  String get remoteErrDshSignInExpired => 'Remote DSH sign-in expired';

  @override
  String get remoteErrDshStopped => 'Remote DSH stopped running';

  @override
  String get remoteErrSshDisconnected => 'SSH disconnected';

  @override
  String get remoteErrSshUnresponsive => 'SSH isn’t responding';

  @override
  String remoteRetryCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Retried $count times',
      one: 'Retried once',
    );
    return '$_temp0';
  }

  @override
  String get remoteErrSshNetworkChanged => 'SSH disconnected after a network change';

  @override
  String get remoteErrReadFingerprint => 'Couldn’t read the host fingerprint';

  @override
  String get remoteErrNoFingerprint => 'Server didn’t provide a host fingerprint';

  @override
  String get remoteErrPasswordMissing => 'Enter a password';

  @override
  String remoteErrAddressUnresponsive(String host, int port) {
    return '$host:$port isn’t responding';
  }

  @override
  String get remoteErrPrivateKeyMissing => 'Enter a private key';

  @override
  String get remoteErrKeyNeedsPassword => 'This private key needs a passphrase';

  @override
  String get remoteErrKeyPassword => 'Incorrect private key passphrase';

  @override
  String get remoteErrKeyUnreadable => 'Couldn’t read the private key';

  @override
  String remotePrivateKeyFormats(String error) {
    return 'Supports Ed25519, RSA and ECDSA private keys in OpenSSH and PEM formats.\n$error';
  }

  @override
  String remoteErrAddressRejected(String address) {
    return '$address refused the connection';
  }

  @override
  String remoteErrSshHostNotFound(String host) {
    return 'Host $host not found';
  }

  @override
  String remoteErrSshAddressUnresponsive(String address) {
    return '$address isn’t responding';
  }

  @override
  String get remoteErrUsernamePassword => 'Incorrect username or password';

  @override
  String get remoteErrPrivateKeyRejected => 'Server doesn’t accept this private key';

  @override
  String remoteAuthorizedKeysHelp(String username, String error) {
    return 'Check that the public key is in $username’s ~/.ssh/authorized_keys.\n$error';
  }

  @override
  String get remoteErrFingerprintUntrusted => 'Host fingerprint isn’t trusted';

  @override
  String get remoteErrSshHandshakeTimeout => 'SSH handshake timed out';

  @override
  String get remoteErrSshInterrupted => 'SSH connection interrupted';

  @override
  String get remoteErrSshConnection => 'Couldn’t connect over SSH';

  @override
  String get remoteErrCommandTimeout => 'Remote command timed out';

  @override
  String get remoteHostedErrNetwork => 'Can’t reach the sharing service. Check your connection and try again.';

  @override
  String get remoteHostedErrTooLarge => 'Chat is too large to create a link';

  @override
  String get remoteHostedErrRateLimited => 'Sharing too often. Try again later.';

  @override
  String get remoteHostedErrCreate => 'Couldn’t create link';

  @override
  String get remoteHostedErrUnavailable => 'Sharing service is unavailable. Try again later.';

  @override
  String get remoteHostedErrGone => 'Link expired or was deleted';

  @override
  String get remoteHostedErrForbidden => 'You don’t have permission to delete this link';

  @override
  String get remoteHostedErrBroken => 'Link is incomplete or damaged';

  @override
  String get remoteChat => 'Chat';

  @override
  String get remoteHostedTtlWeek => '7 days';

  @override
  String get remoteHostedTtlMonth => '30 days';

  @override
  String get remoteHostedTtlForever => 'Forever';

  @override
  String get remoteForumSignIn => 'Sign in to Forum';

  @override
  String get remoteForumSignInBenefits => 'Post, reply and like';

  @override
  String get remoteForumFinishSignIn => 'Finish signing in in your browser';

  @override
  String get remoteReopenBrowser => 'Reopen browser';

  @override
  String get remoteForumSettings => 'Forum settings';

  @override
  String get remoteForumAccount => 'Forum account';

  @override
  String get remoteForumTopic => 'Topic';

  @override
  String get remoteForumLikesReceived => 'Likes received';

  @override
  String get remoteForumDaysVisited => 'Days visited';

  @override
  String get remoteForumNotifications => 'Notifications';

  @override
  String remoteForumUnreadCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count unread', one: '1 unread');
    return '$_temp0';
  }

  @override
  String get remoteForumErrAddress => 'Invalid address';

  @override
  String get remoteForumAddress => 'Forum address';

  @override
  String remoteForumDefaultAddress(String host) {
    return 'Default: $host';
  }

  @override
  String get remoteRestoreDefault => 'Restore default';

  @override
  String get remoteForumUploadingImage => 'Uploading image…';

  @override
  String get remoteForumErrUploadImage => 'Couldn’t upload image';

  @override
  String get remoteForumTitleRequired => 'Add a title first';

  @override
  String get remoteForumCategoryRequired => 'Choose a category';

  @override
  String get remoteForumBodyRequired => 'Write something before sending';

  @override
  String remoteForumReplyCaption(String username, String title) {
    return 'Reply to @$username · $title';
  }

  @override
  String get remoteForumNewTopic => 'New topic';

  @override
  String get remoteForumTitle => 'Title';

  @override
  String get remoteForumComposerHint => 'Write something. Markdown supported.';

  @override
  String get remoteForumPublish => 'Publish';

  @override
  String get remoteForumImage => 'Image';

  @override
  String get remoteForumAttachShareCode => 'Attach share code';

  @override
  String get remoteForumPendingApproval => 'Submitted. Visible after approval.';

  @override
  String get remoteForumLatest => 'Latest';

  @override
  String get remoteForumTop => 'Top';

  @override
  String get remoteForumErrOpen => 'Couldn’t open Forum';

  @override
  String get remoteForumNoTopics => 'No topics yet';

  @override
  String get remoteForumPost => 'Post';

  @override
  String get remoteForum => 'Forum';

  @override
  String remoteForumNotificationsUnread(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Notifications, $count unread',
      one: 'Notifications, 1 unread',
    );
    return '$_temp0';
  }

  @override
  String get remoteForumSearch => 'Search';

  @override
  String get remoteForumSearchHint => 'Search topics and posts';

  @override
  String get remoteForumSignedIn => 'Signed in to Forum';

  @override
  String get remoteForumSignInForNotifications => 'Sign in to see notifications';

  @override
  String get remoteForumErrNotifications => 'Couldn’t load notifications';

  @override
  String get remoteForumNoNotifications => 'No notifications yet';

  @override
  String get remoteForumMarkAllRead => 'Mark all read';

  @override
  String get remoteForumSomeone => 'Someone';

  @override
  String remoteForumNotificationMention(String who) {
    return '$who mentioned you';
  }

  @override
  String remoteForumNotificationGroupMention(String who) {
    return '$who mentioned your group';
  }

  @override
  String remoteForumNotificationReply(String who) {
    return '$who replied to you';
  }

  @override
  String remoteForumNotificationQuote(String who) {
    return '$who quoted you';
  }

  @override
  String remoteForumNotificationEdit(String who) {
    return '$who edited your post';
  }

  @override
  String remoteForumNotificationLikes(String who, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$who and others ($count people) liked your post',
      one: '$who liked your post',
    );
    return '$_temp0';
  }

  @override
  String remoteForumNotificationLike(String who) {
    return '$who liked your post';
  }

  @override
  String remoteForumNotificationLikedPosts(String who, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$who liked $count of your posts',
      one: '$who liked 1 of your posts',
    );
    return '$_temp0';
  }

  @override
  String remoteForumNotificationReaction(String who) {
    return '$who reacted to your post';
  }

  @override
  String remoteForumNotificationMessage(String who) {
    return '$who sent you a private message';
  }

  @override
  String remoteForumNotificationMessageInvite(String who) {
    return '$who invited you to a private message';
  }

  @override
  String remoteForumNotificationTopicInvite(String who) {
    return '$who invited you to a topic';
  }

  @override
  String remoteForumNotificationNewReply(String who) {
    return '$who posted a new reply';
  }

  @override
  String remoteForumNotificationNewTopic(String who) {
    return '$who posted a new topic';
  }

  @override
  String remoteForumNotificationLink(String who) {
    return '$who linked to your post';
  }

  @override
  String remoteForumNotificationBadge(String badge) {
    return 'Earned the “$badge” badge';
  }

  @override
  String remoteForumNotificationMoved(String who) {
    return '$who moved your post';
  }

  @override
  String get remoteForumBookmarkReminder => 'Bookmark reminder';

  @override
  String get remoteForumTopicReminder => 'Topic reminder';

  @override
  String get remoteForumPostApproved => 'Your post was approved';

  @override
  String get remoteForumAdminProblems => 'Forum has issues to resolve';

  @override
  String get remoteForumNewNotification => 'New notification';

  @override
  String get remoteForumUnread => 'Unread';

  @override
  String get remoteForumErrShareCode => 'Couldn’t open share code';

  @override
  String get remoteForumPoll => 'Poll';

  @override
  String get remoteForumVideo => 'Video';

  @override
  String get remoteForumEmbed => 'Embedded content';

  @override
  String get remoteForumVoteOnWeb => 'Vote on Web';

  @override
  String get remoteForumErrSearch => 'Couldn’t search';

  @override
  String remoteForumNoSearchResults(String term) {
    return 'No results for “$term”';
  }

  @override
  String get remoteForumBookmarkRemoved => 'Bookmark removed';

  @override
  String get remoteForumBookmarkAdded => 'Bookmarked';

  @override
  String get remoteLinkCopied => 'Link copied';

  @override
  String get remoteForumErrTopic => 'Couldn’t open this topic';

  @override
  String get remoteForumTopicClosed => 'Topic is closed';

  @override
  String get remoteForumReplyHint => 'Write a reply…';

  @override
  String get remoteForumSignInToReply => 'Sign in to reply';

  @override
  String remoteForumReplyTo(String username) {
    return 'Reply to @$username';
  }

  @override
  String get remoteForumPostDeleted => 'Post deleted';

  @override
  String get remoteForumPostHidden => 'Post hidden';

  @override
  String get remoteForumUnlike => 'Unlike';

  @override
  String get remoteForumLike => 'Like';

  @override
  String get remoteForumRemoveBookmark => 'Remove bookmark';

  @override
  String get remoteForumBookmark => 'Bookmark';

  @override
  String get remoteForumActionPinned => 'Pinned the topic';

  @override
  String get remoteForumActionUnpinned => 'Unpinned the topic';

  @override
  String get remoteForumActionClosed => 'Closed the topic';

  @override
  String get remoteForumActionReopened => 'Reopened the topic';

  @override
  String get remoteForumActionAutoClosed => 'Topic closed automatically';

  @override
  String get remoteForumActionAutoOpened => 'Topic opened automatically';

  @override
  String get remoteForumActionArchived => 'Archived the topic';

  @override
  String get remoteForumActionUnarchived => 'Unarchived the topic';

  @override
  String get remoteForumActionListed => 'Made the topic public';

  @override
  String get remoteForumActionUnlisted => 'Unlisted the topic';

  @override
  String get remoteForumActionSplit => 'Split the topic';

  @override
  String get remoteForumActionBanner => 'Made the topic a banner';

  @override
  String get remoteForumActionRemoveBanner => 'Removed the banner';

  @override
  String get remoteForumActionUpdated => 'Updated the topic';

  @override
  String get remoteLoading => 'Loading';

  @override
  String get remoteForumJustNow => 'Just now';

  @override
  String remoteForumMinutesAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count min ago', one: '1 min ago');
    return '$_temp0';
  }

  @override
  String remoteForumHoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count h ago', one: '1 h ago');
    return '$_temp0';
  }

  @override
  String remoteForumDaysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count days ago', one: '1 day ago');
    return '$_temp0';
  }

  @override
  String remoteForumReplyCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count replies', one: '1 reply');
    return '$_temp0';
  }

  @override
  String remoteForumNewReplyCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count new replies', one: '1 new reply');
    return '$_temp0';
  }

  @override
  String get remoteForumNew => 'New';

  @override
  String remoteForumErrorRetry(String error) {
    return '$error · Retry';
  }

  @override
  String get remoteForumNoMore => 'No more';

  @override
  String get remoteHostKeyTrustTitle => 'Trust this host?';

  @override
  String remoteHostKeyFirstConnection(String name, String address) {
    return 'First connection to “$name” ($address). Check the fingerprint to confirm it’s your host.';
  }

  @override
  String get remoteHostKeyTrustConnect => 'Trust and connect';

  @override
  String get remoteHostKeyChangedTitle => 'Identity fingerprint changed';

  @override
  String remoteRelayKeyChangedBody(String name) {
    return 'The identity key for “$name” has changed. Continue only if you’ve reinstalled the remote plugin on this host. Someone may be impersonating it.';
  }

  @override
  String remoteRelayKeyFirstBody(String name) {
    return 'First connection to “$name”. Check that the identity fingerprint matches the one shown by the host’s remote plugin before continuing.';
  }

  @override
  String get remoteHostKeyChangeWarning => 'DSH will refuse to connect if the fingerprint changes.';

  @override
  String get remoteHostKeyTrustAgain => 'Trust again';

  @override
  String get remoteHostKeyReading => 'Reading host fingerprint…';

  @override
  String remoteHostSwitcherSemantics(String name, String status) {
    return 'Current host: $name, $status. Switch host';
  }

  @override
  String get remoteSwitchHost => 'Switch host';

  @override
  String get remoteThisPhoneDsh => 'DSH on this phone';

  @override
  String get remoteRemoteLabel => 'Remote';

  @override
  String remoteRemotePlatform(String platform) {
    return 'Remote · $platform';
  }

  @override
  String get remoteRelaySwitchWarning =>
      'DSH Remote connects to one host at a time. Switching disconnects the previous host.';

  @override
  String get remoteConnectComputer => 'Connect a computer or server';

  @override
  String get remoteManageHosts => 'Manage remote hosts';

  @override
  String get remoteConnectionMethods => 'Via SSH or DSH Remote';

  @override
  String get remoteRelayLoginRequired => 'Enter the server address, email and password';

  @override
  String get remoteErrSignIn => 'Couldn’t sign in';

  @override
  String get remoteSelfHostedServer => 'Self-hosted server';

  @override
  String get remoteSelfHostedSignInHelp =>
      'Enter your server address. Sign in with email and password, or use this server to choose another sign-in method.';

  @override
  String get remoteUseServer => 'Use this server';

  @override
  String get remoteServerAddress => 'Server address';

  @override
  String get remoteEmail => 'Email';

  @override
  String get remotePassword => 'Password';

  @override
  String get remoteRestoreServer => 'Restore default server dsh.r2049.cn';

  @override
  String get remoteConsole => 'Remote console';

  @override
  String get remoteHostsIntro => 'Keep using DSH from your computer or server on your phone';

  @override
  String get remoteSshHosts => 'SSH hosts';

  @override
  String get remoteSshRequirements => 'Host needs SSH enabled and DSH installed';

  @override
  String get remoteAddSshHost => 'Add SSH host';

  @override
  String get remoteSshDirect => 'No third-party server';

  @override
  String get remoteOtherMethods => 'Other methods';

  @override
  String get remoteWebConsole => 'Web remote console';

  @override
  String get remoteWebConsoleProvider => 'dsh.r2049.cn · Third-party page';

  @override
  String remoteActiveHost(String name) {
    return 'Using “$name”';
  }

  @override
  String get remoteSwitchToPhone => 'Use this phone';

  @override
  String get remoteSignInAgain => 'Sign in again';

  @override
  String get remoteHostSettings => 'Host settings';

  @override
  String get remoteReconnect => 'Reconnect';

  @override
  String get remoteReconnectingEllipsis => 'Reconnecting…';

  @override
  String remoteReconnectReason(String reason) {
    return 'Reconnecting · $reason';
  }

  @override
  String get remoteConnectedEncrypted => 'Connected · End-to-end encrypted';

  @override
  String remoteConnectedVia(String path) {
    return 'Connected · $path · End-to-end encrypted';
  }

  @override
  String get remotePathDirect => 'Direct';

  @override
  String get remotePathTurn => 'TURN';

  @override
  String get remotePathRelay => 'Relay';

  @override
  String remoteConnectedSsh(String address) {
    return 'Connected · SSH $address';
  }

  @override
  String get remoteErrRefreshHosts => 'Couldn’t refresh host list';

  @override
  String get remoteSwitchWarning => 'Connects to one host at a time. Switching disconnects the previous host.';

  @override
  String get remoteRefreshHosts => 'Refresh hosts';

  @override
  String get remoteSignOut => 'Sign out';

  @override
  String get remoteErrHostsRetry => 'Couldn’t load hosts · Tap to retry';

  @override
  String get remoteNoHosts => 'No hosts yet';

  @override
  String get remoteRelaySetupHelp => 'Install the remote plugin in the host’s DSH and sign in';

  @override
  String get remoteRelaySignOutTitle => 'Sign out of DSH Remote?';

  @override
  String get remoteRelaySignOutBody =>
      'This phone will be removed from your account. DSH and chats on the host stay. You can sign in again anytime.';

  @override
  String get remoteRelaySignInTitle => 'Sign in to DSH Remote';

  @override
  String get remoteRelaySignInHelp => 'No network setup. End-to-end encrypted connection.';

  @override
  String get remoteBrowserSignIn => 'Sign in in browser';

  @override
  String remoteSignInWithProvider(String provider) {
    return 'Continue with $provider';
  }

  @override
  String get remoteComingSoon => 'Coming soon';

  @override
  String get remoteSelfHostedEmailSignIn => 'Self-hosted server · Email sign-in';

  @override
  String get remoteBrowserSignInPending => 'Finish signing in in your browser…';

  @override
  String get remoteCopySignInLink => 'Copy sign-in link';

  @override
  String get remoteSshAddressRequired => 'Enter a host address (IP or domain)';

  @override
  String get remoteSshUsernameRequired => 'Enter a username';

  @override
  String get remoteSshPasswordRequired => 'Enter an SSH password, or use a private key';

  @override
  String get remoteSshKeyRequired => 'Paste the full private key (starting with -----BEGIN)';

  @override
  String get remoteHostKeyResetTitle => 'Reset host fingerprint?';

  @override
  String get remoteHostKeyResetBody =>
      'Only do this if the host was reinstalled or replaced. You’ll be asked to check the fingerprint next time you connect.';

  @override
  String get remoteReset => 'Reset';

  @override
  String remoteDeleteHostTitle(String name) {
    return 'Delete “$name”?';
  }

  @override
  String get remoteDeleteHostBody =>
      'This host’s settings and the password and private key saved on this phone will be deleted. DSH and chats on the host stay.';

  @override
  String remoteErrReadKey(String error) {
    return 'Couldn’t read: $error';
  }

  @override
  String get remoteErrPublicKeyFile => 'This isn’t a private key. Choose the file without .pub (such as id_ed25519).';

  @override
  String get remotePrivateKeyImported => 'Private key imported. You can delete the original file.';

  @override
  String get remoteEditHost => 'Edit host';

  @override
  String get remoteSshHostIntro => 'Connect to DSH on your computer or server';

  @override
  String get remoteHostBasicInfo => 'Basic information';

  @override
  String get remoteHostNameHint => 'For example: computer, home Mac';

  @override
  String get remoteHost => 'Host';

  @override
  String get remoteHostAddressHint => '192.168.1.20 or example.com';

  @override
  String get remoteUsername => 'Username';

  @override
  String get remotePort => 'Port';

  @override
  String get remoteAuthentication => 'Sign-in method';

  @override
  String get remotePasswordStorageHelp => 'Saved only on this phone, encrypted by Android Keystore';

  @override
  String get remoteKeyStorageHelp =>
      'Saved only on this phone, encrypted by Android Keystore. Supports Ed25519, RSA and ECDSA.';

  @override
  String get remotePrivateKey => 'Private key';

  @override
  String get remoteShow => 'Show';

  @override
  String get remoteImportKeyFile => 'Import from file';

  @override
  String get remotePrivateKeyPassword => 'Private key passphrase (optional)';

  @override
  String get remoteStartCommand => 'Start command';

  @override
  String get remoteStartCommandHelp => 'If installed with nvm, you can enter the full path';

  @override
  String get remoteWorkingDirectory => 'Working directory (optional)';

  @override
  String get remoteWorkingDirectoryHelp => 'Default folder for new chats. Supports ~/.';

  @override
  String get remoteHostFingerprint => 'Host fingerprint';

  @override
  String get remoteHostKeyNotConfirmed => 'Not confirmed yet';

  @override
  String get remoteHostKeyFirstCheck => 'You’ll be asked to check the fingerprint on first connection';

  @override
  String get remoteDeleteHost => 'Delete this host';

  @override
  String get remoteTesting => 'Testing';

  @override
  String get remoteTestConnection => 'Test';

  @override
  String get remoteHostedUpdateRequired => 'Update DSH to open this link';

  @override
  String get remoteHostedCannotOpen => 'Can’t open this link';

  @override
  String get remoteOpening => 'Opening…';

  @override
  String get remoteHostedNeverExpires => 'Never expires';

  @override
  String get remoteHostedExpired => 'Expired';

  @override
  String get remoteHostedExpiresToday => 'Expires today';

  @override
  String get remoteHostedExpiresTomorrow => 'Expires tomorrow';

  @override
  String remoteHostedExpiresOn(String date) {
    return 'Expires $date';
  }

  @override
  String get remoteHostedDeleteTitle => 'Delete this link?';

  @override
  String remoteHostedDeleteBody(String title) {
    return 'The link for “$title” will stop working immediately';
  }

  @override
  String get remoteHostedLinkDeleted => 'Link deleted';

  @override
  String get remoteUndo => 'Undo';

  @override
  String get remoteHostedMyLinks => 'My shared links';

  @override
  String get remoteHostedNoLinks => 'No shared links yet';

  @override
  String get remoteHostedErrDeleteNetwork => 'Couldn’t delete. Check your connection and try again.';

  @override
  String get remoteHostedErrDelete => 'Couldn’t delete. Try again later.';

  @override
  String get remoteDirectoryPickerTitle => 'Choose folder';

  @override
  String get remoteDirectoryChoose => 'Choose';

  @override
  String get remoteDirectoryDefault => 'Default working directory';

  @override
  String get remoteDirectoryHome => 'Home';

  @override
  String get remoteDirectoryPhoneStorage => 'Phone storage';

  @override
  String get remoteDirectoryDownloads => 'Downloads';

  @override
  String get remoteDirectoryDownloadsPath => 'Phone storage/Download';

  @override
  String get remoteDirectoryDocuments => 'Documents';

  @override
  String get remoteDirectoryDocumentsPath => 'Phone storage/Documents';

  @override
  String get remoteDirectoryLocations => 'Locations';

  @override
  String get remoteDirectoryRecent => 'Recent';

  @override
  String get remoteDirectoryEnterPath => 'Enter path';

  @override
  String get remoteDirectoryGo => 'Go';

  @override
  String get remoteDirectoryAbsolutePath => 'Enter the full path, starting with “/”';

  @override
  String get remoteDirectoryNewFolder => 'New folder';

  @override
  String remoteDirectoryParentCaption(String name) {
    return 'In “$name”';
  }

  @override
  String get remoteDirectoryFolderName => 'Folder name';

  @override
  String get remoteDirectoryRoot => 'Root';

  @override
  String get remoteDirectoryErrCreate => 'Couldn’t create folder';

  @override
  String get remoteDirectoryNoSubfolders => 'No subfolders here';

  @override
  String get remoteDirectoryHideHidden => 'Hide hidden folders';

  @override
  String remoteDirectoryShowHidden(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Show $count hidden folders',
      one: 'Show 1 hidden folder',
    );
    return '$_temp0';
  }

  @override
  String get remoteDirectoryTruncated => 'Too many folders. Only the first ones are listed.';

  @override
  String get remoteWorkspaceAdd => 'Add workspace';

  @override
  String remoteWorkspaceAdded(String name) {
    return 'Added “$name”';
  }

  @override
  String get remoteWorkspaceErrAdd => 'Couldn’t add workspace';

  @override
  String get remoteWorkspaceNoChats => 'No chats';

  @override
  String remoteWorkspaceChatCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count chats', one: '1 chat');
    return '$_temp0';
  }

  @override
  String get remoteWorkspaceErrRename => 'Couldn’t rename';

  @override
  String remoteWorkspaceRemoved(String name) {
    return 'Removed “$name”';
  }

  @override
  String get remoteWorkspaceErrRemove => 'Couldn’t remove workspace';

  @override
  String get remoteWorkspaceRename => 'Rename workspace';

  @override
  String get remoteWorkspaceName => 'Workspace name';

  @override
  String get remoteWorkspaceNameRequired => 'Give it a name';

  @override
  String remoteWorkspaceRemoveTitle(String name) {
    return 'Remove “$name”?';
  }

  @override
  String get remoteWorkspaceRemoveBody => 'Folder and chats stay';

  @override
  String get remoteWorkspaceRemove => 'Remove';

  @override
  String get remoteWorkspace => 'Workspace';

  @override
  String get remoteWorkspaceNewChatHere => 'New chat here';

  @override
  String get remoteWorkspaceUnpin => 'Unpin';

  @override
  String get remoteWorkspaceGroup => 'Group';

  @override
  String get remoteWorkspaceUngrouped => 'Ungrouped';

  @override
  String get remoteWorkspaceRemoveAction => 'Remove workspace';

  @override
  String get remoteWorkspaceNewGroup => 'New group';

  @override
  String get remoteWorkspaceGroupName => 'Group name';

  @override
  String remoteDirectoryPhonePath(String path) {
    return 'Phone storage/$path';
  }

  @override
  String get remoteDirectoryInvalidName => 'Name can’t contain “/”';

  @override
  String get remoteWorkspaceErrNameConflict => 'A workspace with this name already exists';

  @override
  String get remoteWorkspaceErrInvalidPath => 'This folder can’t be used as a workspace';

  @override
  String get remoteWorkspaceErrNotFound => 'This workspace no longer exists';

  @override
  String get remoteDirectoryErrUnreadable => 'Couldn’t open this folder';

  @override
  String get remoteDirectoryErrExists => 'A folder with this name already exists';

  @override
  String get remoteDirectoryErrUnavailable => 'This host can’t browse folders here';

  @override
  String get remoteWorkspaceErrUnsupported => 'This host doesn’t support this action';

  @override
  String get remoteWorkspaceAllChats => 'All chats';

  @override
  String remoteWorkspaceSwitcherSemantics(String name) {
    return 'Workspace: $name. Switch workspace';
  }

  @override
  String get remoteWorkspaceManage => 'Manage workspaces';

  @override
  String get remoteWorkspaceErrLoad => 'Couldn’t load workspaces';

  @override
  String get remoteWorkspaceEmpty => 'No workspaces yet';

  @override
  String get remoteWorkspaceEmptyHint => 'Add the folders you use most';

  @override
  String remoteWorkspaceCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count workspaces', one: '1 workspace');
    return '$_temp0';
  }

  @override
  String remoteDirectoryConfirmFolder(String action, String name) {
    return '$action “$name”';
  }

  @override
  String remoteHostKeyMismatchDetail(String saved, String received, String type) {
    return 'If the host was reinstalled or replaced, reset its fingerprint in host settings.\nSaved: $saved\nReceived: $received ($type)';
  }

  @override
  String remoteForumCompactReplies(int count, String label) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$label replies', one: '$label reply');
    return '$_temp0';
  }

  @override
  String remoteForumCompactViews(int count, String label) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$label views', one: '$label view');
    return '$_temp0';
  }

  @override
  String remoteForumYearDate(int year, String month, int day) {
    String _temp0 = intl.Intl.selectLogic(month, {
      '1': 'Jan',
      '2': 'Feb',
      '3': 'Mar',
      '4': 'Apr',
      '5': 'May',
      '6': 'Jun',
      '7': 'Jul',
      '8': 'Aug',
      '9': 'Sep',
      '10': 'Oct',
      '11': 'Nov',
      '12': 'Dec',
      'other': '$month',
    });
    return '$_temp0 $day, $year';
  }

  @override
  String remoteHostedMonthDate(String month, int day) {
    String _temp0 = intl.Intl.selectLogic(month, {
      '1': 'Jan',
      '2': 'Feb',
      '3': 'Mar',
      '4': 'Apr',
      '5': 'May',
      '6': 'Jun',
      '7': 'Jul',
      '8': 'Aug',
      '9': 'Sep',
      '10': 'Oct',
      '11': 'Nov',
      '12': 'Dec',
      'other': '$month',
    });
    return '$_temp0 $day';
  }

  @override
  String remoteHostedYearDate(int year, String month, int day) {
    String _temp0 = intl.Intl.selectLogic(month, {
      '1': 'Jan',
      '2': 'Feb',
      '3': 'Mar',
      '4': 'Apr',
      '5': 'May',
      '6': 'Jun',
      '7': 'Jul',
      '8': 'Aug',
      '9': 'Sep',
      '10': 'Oct',
      '11': 'Nov',
      '12': 'Dec',
      'other': '$month',
    });
    return '$_temp0 $day, $year';
  }

  @override
  String remoteForumTenThousands(String value) {
    return '$value × 10,000';
  }

  @override
  String get remoteForumSemanticsSeparator => ', ';

  @override
  String remoteHostKeyVerifyCommand(String command) {
    return 'Run $command on that host to see the same fingerprint. DSH will refuse to connect if it changes.';
  }

  @override
  String remoteSshInstallCommand(String command) {
    return 'DSH not installed? Run $command on the host.';
  }

  @override
  String remoteRelayProvider(String project) {
    return 'Service by $project';
  }

  @override
  String remoteRelayProviderServer(String project, String server) {
    return 'Service by $project · Current server: $server';
  }

  @override
  String remoteQuotedHostName(String name) {
    return '“$name”';
  }

  @override
  String remoteErrorDetail(String message, String detail) {
    return '$message ($detail)';
  }

  @override
  String get remotePathLan => 'LAN';

  @override
  String get remotePathP2p => 'P2P';

  @override
  String get remoteNetworkDetails => 'Network details';

  @override
  String get remoteNetworkAutomatic =>
      'Automatically tries LAN → P2P → TURN → Relay, with end-to-end encryption throughout.';

  @override
  String get remoteNetworkCurrentPath => 'Current path';

  @override
  String get remoteNetworkConnectDuration => 'Connection time';

  @override
  String get remoteNetworkRoundTripTime => 'Round-trip time (RTT)';

  @override
  String get remoteNetworkUnmeasured => 'Not measured';

  @override
  String get remoteNetworkUnknownPath => 'Not confirmed';

  @override
  String remoteNetworkMilliseconds(int value) {
    return '$value ms';
  }

  @override
  String get remoteNetworkMeasure => 'Refresh network / measure latency';

  @override
  String get remoteNetworkMeasuring => 'Measuring…';

  @override
  String get remoteNetworkMeasureFailed => 'Couldn’t measure latency. Try again later.';

  @override
  String get remoteNetworkDisconnected => 'Disconnected. Reconnect to measure latency.';

  @override
  String get remoteNetworkFallback => 'Fallback reason';

  @override
  String get remoteNetworkFallbackUnknown =>
      'A direct connection wasn’t available; an available route was selected automatically.';

  @override
  String get remoteNetworkFallbackWebrtcUnavailable => 'WebRTC is unavailable on this device; using Relay.';

  @override
  String get remoteNetworkFallbackDirectFailed => 'LAN / P2P couldn’t connect; tried the next available route.';

  @override
  String get remoteNetworkFallbackDirectTimeout => 'LAN / P2P timed out; tried the next available route.';

  @override
  String get remoteNetworkFallbackDirectRecentlyFailed =>
      'A recent direct attempt failed; using an available relay for this connection.';

  @override
  String get remoteNetworkFallbackTurnUnavailable => 'TURN is unavailable; using Relay.';

  @override
  String get remoteNetworkFallbackTurnFailed => 'TURN couldn’t connect; using Relay.';

  @override
  String get remoteNetworkFallbackTurnTimeout => 'TURN timed out; using Relay.';

  @override
  String get remoteNetworkFallbackPathUnverified => 'The WebRTC route type hasn’t been confirmed.';

  @override
  String get remoteNetworkSnapshotHint => 'Shows the last confirmed route and latency. Refresh to check again.';

  @override
  String get remoteNetworkObservedAt => 'Last checked';

  @override
  String get remoteNetworkLocalIpVersion => 'Phone ICE IP version';

  @override
  String get remoteNetworkRemoteIpVersion => 'Host ICE IP version';

  @override
  String get remoteNetworkIceProtocol => 'ICE protocol';

  @override
  String get remoteTransferSettings => 'Remote transfer';

  @override
  String get remoteCompactHistory => 'Compact history';

  @override
  String get remoteErrHistoryModeChanged =>
      'The Host no longer supports compact history. Switch to another host and back, or restart the app, to reload history.';

  @override
  String get remoteCompactHistoryHint =>
      'Reduces historical tool details on supporting DSH Remote Hosts; live replies and approvals stay unchanged. Switch hosts or restart the app to apply. Older Hosts keep full history.';

  @override
  String get searchKwRemoteCompactHistory => 'compact slim lite history tools transfer bandwidth remote';

  @override
  String get remotePairEntry => 'Pair a computer by scanning';

  @override
  String get remotePairEntryHint =>
      'Scan the code the Remote plugin shows on your computer. No Remote account needed; sign in to DeepSeek first.';

  @override
  String get remotePairAddComputer => 'Add a computer by scanning';

  @override
  String get remotePairTitle => 'Pair a computer';

  @override
  String get remotePairSubtitle =>
      'No Remote account needed. Your DeepSeek password and sign-in tokens are never sent.';

  @override
  String get remotePairNeedsDeepSeek => 'Sign in to DeepSeek first';

  @override
  String get remotePairNeedsDeepSeekBody =>
      'Pairing needs the DeepSeek account signed in on DSH Go. Only its account ID goes along, to label this phone; no password, cookie or token.';

  @override
  String get remotePairScanHint => 'Point the camera at the pairing code the Remote plugin shows on your computer';

  @override
  String get remotePairPasteLink => 'Paste pairing link';

  @override
  String get remotePairPasteEmpty => 'No pairing link on the clipboard';

  @override
  String get remotePairScannerFailed => 'The QR reader is unavailable. Paste the pairing link to continue pairing.';

  @override
  String get remotePairFromImage => 'From photos';

  @override
  String get remotePairImageNoCode => 'No QR code found in that image';

  @override
  String get remotePairCameraDenied =>
      'No camera access. Turn it on in system settings, or use From photos or Paste pairing link.';

  @override
  String get remotePairCameraFailed => 'The camera didn’t open. Use From photos or Paste pairing link.';

  @override
  String get remotePairReading => 'Reading the pairing code…';

  @override
  String get remotePairConfirmTitle => 'Connect to this computer?';

  @override
  String get remotePairComputer => 'Computer';

  @override
  String get remotePairServer => 'Server';

  @override
  String get remotePairFingerprint => 'Computer fingerprint';

  @override
  String get remotePairFingerprintHint =>
      'Check that it matches the fingerprint in the Remote plugin on your computer before you continue.';

  @override
  String get remotePairConfirm => 'It’s this computer, pair';

  @override
  String get remotePairNotThis => 'Not this one, scan again';

  @override
  String get remotePairClaiming => 'Getting a verification code…';

  @override
  String get remotePairCodeTitle => 'Enter this 8-digit code on the computer';

  @override
  String remotePairCodeSemantics(String digits) {
    return 'Verification code $digits';
  }

  @override
  String get remotePairCodeHint =>
      'Type it into the Remote plugin on your computer, then click Confirm binding. Nothing more to do on the phone.';

  @override
  String get remotePairOneAttempt =>
      'One attempt only: a wrong code ends this pairing, and you’ll need a new code on the computer.';

  @override
  String remotePairWaiting(String countdown) {
    return 'Waiting for the computer · $countdown left';
  }

  @override
  String get remotePairApproved => 'The computer confirmed. Finishing…';

  @override
  String get remotePairCodeExpired => 'The code expired. Show a new pairing code on the computer.';

  @override
  String remotePairConnecting(String name) {
    return 'Paired. Connecting to $name…';
  }

  @override
  String get remotePairFailedTitle => 'Couldn’t pair';

  @override
  String remotePairOtherServerBody(String server) {
    return 'This code is from $server, not the Remote server DSH Go uses now. Switch to it and continue? Each server keeps its own sign-in.';
  }

  @override
  String get remotePairSwitchServer => 'Switch server and continue';

  @override
  String get remotePairScanAgain => 'Scan again';

  @override
  String get remotePairErrInvalidCode => 'That isn’t a DSH Go pairing code';

  @override
  String get remotePairErrOtherServer => 'This code is from another Remote server';

  @override
  String get remotePairErrUnsupported => 'This Remote server doesn’t support pairing by scanning yet';

  @override
  String get remotePairErrExpired => 'The code expired or was already used. Show a new pairing code on the computer.';

  @override
  String get remotePairErrCodeRejected =>
      'The computer entered a wrong code, so this pairing is over. Show a new pairing code on the computer and scan again.';

  @override
  String get remotePairErrCancelled => 'Pairing cancelled';

  @override
  String get remotePairErrAccountConflict =>
      'This phone is signed in to another Remote account than the computer’s. That sign-in is kept; to switch, sign out of Remote first.';

  @override
  String get remotePairErrIdentity =>
      'The pairing no longer matches this computer or this phone, so it stopped. Show a new pairing code on the computer.';

  @override
  String get remotePairErrHostLimit => 'This account already has the maximum number of computers';

  @override
  String get remotePairErrNetwork => 'Can’t reach the Remote server. Check your network and try again.';

  @override
  String get remotePairErrFailed => 'Pairing didn’t finish. Scan again.';

  @override
  String remotePairSwitchFailedTitle(String name) {
    return 'Paired with $name';
  }

  @override
  String get remotePairSwitchFailedBody => 'But switching to it didn’t work. Try again, or pick it under Remote hosts.';

  @override
  String get remotePairDone => 'Done';

  @override
  String get remotePairErrPinSave =>
      'Paired, but this phone couldn’t store the computer’s fingerprint. Show a new pairing code on the computer and scan it again.';

  @override
  String get stateWorkspaceFilesHint => 'Files uploaded to the current workspace:';

  @override
  String get stateRemoteUploadNameInvalid =>
      'The host rejected the filename. Shorten it or remove special characters and try again.';

  @override
  String get stateRemoteUploadWorkspaceUnavailable => 'This chat has no writable working directory';

  @override
  String get stateRemoteUploadWorkspaceChanged => 'The working directory changed. Check it before uploading again.';

  @override
  String get stateRemoteUploadLimit => 'The host refused the upload. Check the file size or try again later.';

  @override
  String get stateRemoteUploadUnsupported =>
      'This host does not support file uploads. Update its Remote plugin and reconnect.';

  @override
  String get stateRemoteUploadTooLarge => 'The file exceeds the remote upload protocol\'s size limit';

  @override
  String get riskDontShowAgain => 'Don’t show again';

  @override
  String get riskAskAi => 'Not sure? Ask AI';

  @override
  String get riskConfirmAlwaysAction => 'Skip confirmation';

  @override
  String get riskFullAccessAction => 'Turn on Full access';

  @override
  String get riskAutoReviewAction => 'Turn on Auto review';

  @override
  String get riskAllowForChatTitle => 'Allow everything in this chat?';

  @override
  String get riskAllowForChatBody =>
      'Commands and changes in this chat run without asking. Turn it off above the message box anytime.';

  @override
  String get riskAllowForChatAction => 'Allow all';

  @override
  String get riskPetOverlayTitle => 'Show over other apps?';

  @override
  String get riskPetOverlayBody =>
      'Turn on “Display over other apps” for DSH Go in system settings so your pet can appear outside the app.';

  @override
  String get riskPetOverlayAction => 'Open settings';

  @override
  String get askAiTooltip => 'Ask AI';

  @override
  String get askAiHelpTitle => 'Help';

  @override
  String get askAiHelpSubtitle => 'Ask AI about anything here';

  @override
  String askAiAboutApp(String question) {
    return 'About the DSH Go app: $question';
  }

  @override
  String askAiWithGuide(String question) {
    return 'About the DSH Go app: $question\nPlease answer from the attached guide.';
  }

  @override
  String get askAiNoGuide => 'This host doesn’t have the DSH Go guide, so answers may be off';

  @override
  String get askAiQuestionOverview => 'What can DSH Go do, and where should I start?';

  @override
  String get askAiQuestionPhoneControl => 'How does phone control work, and what are the risks?';

  @override
  String get askAiQuestionPhoneAlways =>
      'What changes with “Always skip confirmation” in phone control, and how is it riskier than asking each time?';

  @override
  String get askAiQuestionAppRules =>
      'What is the app list in phone control for, and what are the risks of allowing banking and payment apps?';

  @override
  String get askAiQuestionFullAccess => 'What happens with full access on, and what are the risks?';

  @override
  String get askAiQuestionPhoneFiles =>
      'With “Access phone files” on, which files can AI read and change, and how do I turn it off?';

  @override
  String get askAiQuestionAllowForChat => 'What does “Allow for chat” let through, and how do I turn it off?';

  @override
  String get askAiQuestionPlugins => 'What can plugins do, and what should I watch for with third-party ones?';

  @override
  String get askAiQuestionRemote =>
      'How do I connect my own computer or server, and how is that different from this phone?';

  @override
  String get phoneRuntimeUpgradeBase =>
      'The new engine cannot be confirmed compatible with your Linux environment, so the update stopped. Your environment and installed tools were not deleted. Make a full backup and contact the maintainer for migration; do not reset or uninstall the app.';

  @override
  String get phoneRuntimeUpgradeManifest =>
      'The runtime update manifest could not be safely identified. The update stopped and your environment was kept. Check the APK and contact the maintainer; do not reset the environment.';

  @override
  String get phoneRuntimeUpgradeInterrupted =>
      'The runtime upgrade is incomplete. Your data and recovery state were kept. Retry installation. If it still fails, export diagnostics and contact the maintainer; do not reset or delete recovery directories.';

  @override
  String get phoneRuntimeUpgradeSymlink =>
      'A system path was replaced by a custom link, so the environment cannot be updated safely. Your environment was kept. Back it up and contact the maintainer.';

  @override
  String get phoneRuntimeUpgradeRunning =>
      'The engine or a leftover process has not been confirmed stopped. The update has not started. Stop the local engine and wait for cleanup before retrying; do not reset the environment.';

  @override
  String get schemaDocumentationTitle => 'Field descriptions';

  @override
  String get schemaDocumentationOverview => 'Overview';

  @override
  String get schemaDocumentationEach => 'Each item';

  @override
  String schemaDocumentationPosition(int position) {
    return 'Item $position';
  }

  @override
  String schemaDocumentationOption(int option) {
    return 'Option $option';
  }

  @override
  String get searchApiKey => 'API Key';

  @override
  String get searchNeedsLocal => 'Available on this phone\'s engine';

  @override
  String get searchNeedsPhoneControl => 'Available once phone control is on';

  @override
  String get searchNeedsNativeUi => 'Available in the native interface';

  @override
  String get searchNeedsEngineField => 'Available when the host has it';

  @override
  String get searchNeedsAnimations => 'Available with animations on';

  @override
  String get searchNeedsWorkshop => 'This build doesn\'t include the Workshop';

  @override
  String get searchNeedsChat => 'Available with a chat open';

  @override
  String get searchKwTheme => 'appearance,colors,colours,accent,icons';

  @override
  String get searchKwPets => 'pet,pets,companion,whale,overlay';

  @override
  String get searchKwPerformance => 'battery,smooth,lag,lite,full,speed';

  @override
  String get searchKwVoice => 'speech recognition,dictation,microphone,mic,voice,read aloud,voice call,call,TTS,speech';

  @override
  String get searchKwVoiceReading => 'read aloud,reading voice,TTS,voice,Stella,Tide,speech';

  @override
  String get searchKwNotifications => 'alerts,push,banner,sound';

  @override
  String get searchKwReplyPrefs => 'about me,style,tone,instructions,AGENTS.md';

  @override
  String get searchKwSharedLinks => 'links,share,shared,public link';

  @override
  String get searchKwPhone => 'accessibility,automation,tap,control phone';

  @override
  String get searchKwAppRules => 'apps,blocklist,allowlist,deny,app list';

  @override
  String get searchKwDnd => 'dnd,shizuku,sui,root,adb,background';

  @override
  String get searchKwEngine => 'engine,runtime,start,stop,restart,DSH';

  @override
  String get searchKwBackground => 'keep alive,background activity,battery optimization,autostart,killed';

  @override
  String get searchKwSystemAccess =>
      'permissions,grant,overlay,display over other apps,accessibility,background pop-ups,microphone,file access,notification permission,restricted settings';

  @override
  String get searchKwDiagnostics => 'logs,troubleshoot,report,bug,errors';

  @override
  String get searchKwModels => 'model providers,providers,provider,switch model,OpenRouter,ChatGPT,Claude';

  @override
  String get searchKwEngineParams => 'engine settings,advanced,parameters,subagent,commands';

  @override
  String get searchKwSubagent => 'subagent settings,depth,concurrency,subtasks';

  @override
  String get searchKwAgentLoop => 'loop,parallel,tool calls';

  @override
  String get searchKwShell => 'commands,timeout,output,terminal,shell,bash';

  @override
  String get searchKwWebSearch => 'search,internet,browse,api key';

  @override
  String get searchKwGeneral => 'general,web settings';

  @override
  String get searchKwPluginInventory => 'inventory,installed plugins,bundles';

  @override
  String get searchKwPlugins => 'extensions,market,install,marketplace';

  @override
  String get searchKwAllFeatures => 'features,catalog,everything';

  @override
  String get searchKwAccount => 'account,balance,top up,sign in,sign out,api key,usage,DeepSeek';

  @override
  String get searchKwRemote => 'remote,ssh,computer,server,DSH Remote,connect';

  @override
  String get searchKwPermission => 'permissions,approval,don\'t ask,read only,full access,auto-run commands';

  @override
  String get searchKwAgentPresets => 'presets,mode,agent mode';

  @override
  String get searchKwUiMode => 'native,web,web mode,interface';

  @override
  String get searchKwLanguage => 'chinese,english,locale';

  @override
  String get searchKwAutoCommands => 'don\'t ask,auto approve,full access,no confirmation';

  @override
  String get searchKwPhoneFiles => 'storage,files,downloads,photos';

  @override
  String get searchKwVisualReplies => 'charts,cards,visual,options';

  @override
  String get searchKwTextSize => 'font,font size,text size,larger text';

  @override
  String get searchKwTableTint => 'table,tint,header,stripe,row,background';

  @override
  String get searchKwFoldTurns => 'collapse,fold,steps';

  @override
  String get searchKwWebPhoneLayout => 'web phone layout,layout';

  @override
  String get searchKwShareConfig => 'share,export,share code,config';

  @override
  String get searchKwOpenWeb => 'web,browser,web ui';

  @override
  String get searchKwSafeMode => 'safe mode,leave safe mode,troubleshoot';

  @override
  String get searchKwVersion => 'version,about,build';

  @override
  String get searchKwUpdate => 'update,upgrade,new version';

  @override
  String get searchKwUpdateAuto => 'auto update,updates';

  @override
  String get searchKwHelp => 'help,guide,ask ai,how to';

  @override
  String get searchKwCommunity => 'group,forum,feedback,chat group';

  @override
  String get searchKwStar => 'github,star';

  @override
  String get searchKwLicenses => 'license,open source';

  @override
  String get searchKwDarkMode => 'dark,light,dark mode,night,theme,system,appearance';

  @override
  String get searchKwAccent => 'color,colour,accent,palette,wallpaper';

  @override
  String get searchKwTileStyle => 'icon style,tiles';

  @override
  String get searchKwAppIcon => 'launcher icon,icon';

  @override
  String get searchKwPetSize => 'pet size';

  @override
  String get searchKwPetQuiet => 'quiet,pet quiet';

  @override
  String get searchKwPetOutside => 'overlay,floating pet,outside app';

  @override
  String get searchKwPetDisplayWhen => 'pet display,when to show';

  @override
  String get searchKwPetOverlayShows => 'floating companion,room companion,pixel pet,live2d';

  @override
  String get searchKwPetOverlayFraming => 'framing,full body,half body';

  @override
  String get searchKwWorkshop => 'workshop,download pets,download companions,share pets,submit';

  @override
  String get searchKwBlur => 'blur,glass,frosted';

  @override
  String get searchKwAnimations => 'animation,motion,reduce motion';

  @override
  String get searchKwFluidMotion => 'fluid,spring,bounce,glow,smooth';

  @override
  String get searchKwNotifyEnabled => 'notifications on,turn off notifications';

  @override
  String get searchKwNotifyDone => 'reply done,finished';

  @override
  String get searchKwNotifyFailed => 'error,failed,stopped';

  @override
  String get searchKwNotifyApproval => 'approval,waiting for you';

  @override
  String get searchKwNotifyQuestion => 'question,asks you';

  @override
  String get searchKwNotifyLive =>
      'dynamic island,live update,live activity,status bar chip,now bar,live alerts,lock screen progress';

  @override
  String get searchKwNotifySystem => 'sound,banner,lock screen,system';

  @override
  String get searchKwPhoneConfirm => 'don\'t ask,confirm,always ask,no confirmation';

  @override
  String get searchKwPhoneAutoCollapse => 'floating bar,collapse,bubble';

  @override
  String get searchKwPhoneReturn => 'return,come back';

  @override
  String get searchKwPhoneBackgroundGuide => 'background confirmation,return';

  @override
  String get searchKwAutoStart => 'auto start,launch';

  @override
  String get searchKwAutoSafe => 'safe mode,automatic safe mode';

  @override
  String get searchKwEngineReset => 'reset,wipe,restore';

  @override
  String get searchKwEngineUninstall => 'uninstall,remove,free space';

  @override
  String get searchKwWorkspaceRecovery => 'workspace,index,recovery,rescue,missing chats,chats won\'t open';

  @override
  String get searchKwAddProvider => 'add model,new provider,custom model,base url';

  @override
  String get searchKwSubagentDepth => 'depth,levels';

  @override
  String get searchKwParallelCalls => 'parallel,concurrent calls';

  @override
  String get searchKwCommandTimeout => 'timeout,time limit';

  @override
  String get searchKwWebSearchKey => 'search key,web search key';

  @override
  String get searchKwChatLogUpload => 'privacy,logs,upload logs,telemetry';

  @override
  String get searchKwAddSshHost => 'ssh,add host,connect computer';

  @override
  String get searchKwRemoteAutoConnect => 'auto connect,on launch';

  @override
  String get searchKwPermissionCurrent => 'allow for this chat,this chat';

  @override
  String get searchKwPermissionDefault =>
      'default permission,read only,workspace,full access,auto-run commands,don\'t ask';

  @override
  String get searchSettingsHint => 'Search settings';

  @override
  String get searchSuggestDark => 'Dark mode';

  @override
  String get searchSuggestBackground => 'Background';

  @override
  String get searchSuggestPermission => 'Permissions';

  @override
  String get searchSuggestTextSize => 'Text size';

  @override
  String get searchCommon => 'Common';

  @override
  String get searchRecent => 'Recent';

  @override
  String get searchFeatures => 'Features';

  @override
  String get searchNoResults => 'No matching settings';

  @override
  String searchAskAi(String query) {
    return 'Ask AI: “$query”';
  }

  @override
  String get searchKwPersonalization => 'personalization,preferences,style';

  @override
  String get searchKwInterface => 'native,web,web mode,web app,general';

  @override
  String get searchKwPrivacy => 'privacy,data,logs,sharing,statistics';

  @override
  String get searchKwAbout => 'about,version,update,licenses';

  @override
  String get searchKwPhoneConfirmEntry => 'confirmation,phone control,don\'t ask';

  @override
  String get searchKwWebCodingView => 'coding view,work view,web';

  @override
  String get searchKwWebCollapse => 'work steps,collapse,web';

  @override
  String get searchKwWebBusySend => 'send,queue,while AI works';

  @override
  String get searchKwPluginsMarket => 'plugin market,install plugins,marketplace';

  @override
  String get searchKwUsageStats => 'statistics,stats,usage data,analytics,telemetry,anonymous,privacy,data';

  @override
  String get searchKwQuickPanel => 'swipe,left swipe,shortcuts,gesture,quick panel,quick access';

  @override
  String get selfUpdateTransport => 'Installation route';

  @override
  String get selfUpdateSystem => 'Normal installation (default)';

  @override
  String get selfUpdateShizuku => 'Shizuku';

  @override
  String get selfUpdateAdb => 'Local ADB';

  @override
  String get selfUpdateSecurityNote =>
      'Every route remains subject to APK signatures and Android/vendor security policies. Skipping scans is not guaranteed. Root is unsupported; routes never switch automatically after a failure.';

  @override
  String get selfUpdateNativeConfirm =>
      'Only a verified update for this app is installed, with native confirmation still required. Authorizing Shizuku does not approve installation. Phone control and AI Shell can remain off.';

  @override
  String get selfUpdateAuthorize => 'Request Shizuku authorization for updates';

  @override
  String get selfUpdateRefresh => 'Refresh transport status';

  @override
  String selfUpdateShizukuStatus(String status) {
    return 'Shizuku: $status';
  }

  @override
  String get selfUpdateReady => 'Authorized';

  @override
  String get selfUpdatePermissionRequired => 'Install, start, and authorize Shizuku first';

  @override
  String get selfUpdateUnsupportedIdentity =>
      'Only shell UID 2000 is supported; root and other identities are unsupported';

  @override
  String get selfUpdateAdbHint =>
      'Use this phone\'s paired wireless-debugging identity; connection starts only when you press Install. If unpaired, open the existing Android Shell pairing page without enabling Phone control or AI Shell. Pairing codes and ports are not saved or logged.';

  @override
  String get selfUpdatePairing => 'Open Android Shell pairing guidance';

  @override
  String get selfUpdateAdbPaired => 'Local ADB paired';

  @override
  String get selfUpdateAdbNotPaired => 'Local ADB not paired';

  @override
  String get selfUpdatePendingTitle => 'Verifying installation outcome';

  @override
  String get selfUpdatePendingMessage =>
      'The installation may still be running. There is no automatic retry or route switch. Check system prompts, then read the actual installed state.';

  @override
  String get selfUpdateUnknownTitle => 'Installation outcome unknown';

  @override
  String get selfUpdateUnknownMessage =>
      'A timeout, lost connection, or exited process does not prove failure. There is no automatic retry or route switch. Read the actual installed state first.';

  @override
  String get selfUpdateReadResult => 'Read actual installed state';

  @override
  String get selfUpdateVerifiedTitle => 'Installed version verified';

  @override
  String selfUpdateVerifiedVersion(String version, int code) {
    return 'Current version $version (build $code), verified by the native layer.';
  }

  @override
  String get selfUpdateFailedTitle => 'Installation did not complete';

  @override
  String get selfUpdateFailedMessage =>
      'The native layer reported this installation failed. Check system prompts and the error code, then explicitly choose an installation route.';

  @override
  String selfUpdateErrorCode(String code) {
    return 'Error code: $code';
  }

  @override
  String get selfUpdateEndWaiting => 'End this wait';

  @override
  String get selfUpdateEndWaitingNote =>
      'End this wait only after confirming the system is no longer installing. Clearing the record does not cancel a system installation or retry/switch routes. Native confirmation is required again.';

  @override
  String get shellDeletePermanently => 'Delete permanently';

  @override
  String get shellDeleteNoUndo => 'Cannot be undone; this is not archive';

  @override
  String get shellDeleteChecking => 'Checking whether this host supports permanent deletion…';

  @override
  String get shellDeleteUnsupported =>
      'This host does not support safe permanent deletion. Archive is still available.';

  @override
  String get shellDeleteUnavailable =>
      'Safe permanent deletion is unavailable. Reconnect or update this host; nothing was archived instead.';

  @override
  String shellDeleteChatConfirmation(String title) {
    return 'Permanently delete “$title”?';
  }

  @override
  String shellDeleteChatsConfirmation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Permanently delete $count chats?',
      one: 'Permanently delete 1 chat?',
    );
    return '$_temp0';
  }

  @override
  String get shellDeleteWarning =>
      'The selected chat history will be permanently deleted from this host. This cannot be undone and is not archive.\n\nWorking directories, generated files, forks, shared attachments and published cloud shares are kept. Cloud shares must be removed separately. Subagent chats are deleted along with the chat. The host refuses a running chat or one with scheduled tasks.';

  @override
  String get shellDeleteOwnerChanged =>
      'The host or connection changed. Cancel and start deletion again; the old confirmation is no longer valid.';

  @override
  String get shellDeletingChats => 'Deleting chats…';

  @override
  String shellChatsDeleted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Permanently deleted $count chats',
      one: 'Permanently deleted 1 chat',
    );
    return '$_temp0';
  }

  @override
  String shellDeletePartial(int deleted, int failed) {
    String _temp0 = intl.Intl.pluralLogic(
      deleted,
      locale: localeName,
      other: 'Deleted $deleted chats',
      one: 'Deleted 1 chat',
    );
    String _temp1 = intl.Intl.pluralLogic(failed, locale: localeName, other: '$failed failed', one: '1 failed');
    return '$_temp0; $_temp1';
  }

  @override
  String get shellDeleteRunning =>
      'Stop running work before deleting. The host also checks active tasks and schedules.';

  @override
  String get shellDeleteRelated => 'This chat still has scheduled tasks. The host refused deletion to protect them.';

  @override
  String get shellDeleteWriterHeld => 'Another process is using this chat. Close it there and try again.';

  @override
  String get shellDeleteNotFound => 'The chat no longer exists on this host. Refresh the list.';

  @override
  String get shellDeleteConnectionLost =>
      'The connection was lost and the deletion result is unconfirmed. Refresh the chat list before taking further action.';

  @override
  String get shellDeleteArchivePending => 'An archive operation is pending. Finish or undo it before deleting.';

  @override
  String get shellDeleteInventoryChanged => 'The chat list changed. Refresh and select the chats again.';

  @override
  String get shellDeleteProtocolError =>
      'The deletion result is unconfirmed. Refresh the chat list before taking further action.';

  @override
  String get shellDeleteNotAttempted => 'Not attempted. Check the chat list before trying again.';

  @override
  String get shellDeleteFailed => 'The host could not confirm deletion. Refresh before retrying.';

  @override
  String get setupAppearanceTitle => 'Choose a look';

  @override
  String get setupAppearanceMessage => 'You can change this anytime in Settings';

  @override
  String get setupLightMode => 'Lightweight mode';

  @override
  String get setupCapsulePreparing => 'Preparing runtime';

  @override
  String setupCapsuleProgress(int percent) {
    return 'Runtime $percent%';
  }

  @override
  String setupCapsuleProgressSemantics(int percent) {
    return 'Preparing the runtime, $percent% done';
  }

  @override
  String get setupCapsuleReady => 'Runtime ready';

  @override
  String get setupCapsuleFailed => 'Install failed';

  @override
  String get setupWaitingBody => 'Continues on its own when ready';

  @override
  String get setupNotifyWhenDone => 'We’ll notify you when it’s done';

  @override
  String get setupAwaitSignIn => 'DeepSeek sign-in opens when it’s ready';

  @override
  String get shellApiKeyPrefixWarning => 'DeepSeek keys usually start with sk-. Check you copied the right key.';

  @override
  String get shellApiKeyIncompleteWarning => 'This key looks incomplete. Check you copied it all.';

  @override
  String get shellBrowserUrlCopied => 'Couldn’t open your browser. URL copied.';

  @override
  String get shellSaveTryAgain => 'Couldn’t save. Try again.';

  @override
  String get shellApiKeyUpdated => 'API key updated';

  @override
  String get shellReplaceApiKey => 'Replace API key';

  @override
  String get shellEnterApiKey => 'Enter API key';

  @override
  String get shellApiKeyBilling => 'Billed by the DeepSeek platform based on usage';

  @override
  String get shellSaving => 'Saving';

  @override
  String get shellSaveContinue => 'Save and continue';

  @override
  String get shellSetUpLater => 'Set up later';

  @override
  String get shellClearField => 'Clear';

  @override
  String get shellShow => 'Show';

  @override
  String get shellApiKeyEncrypted => 'Encrypted on this phone';

  @override
  String get shellGetApiKey => 'Get API key';

  @override
  String get shellConnectDeepSeek => 'Connect DeepSeek';

  @override
  String get shellConnectDeepSeekMessage => 'Sign in to DeepSeek to start. No API key needed.';

  @override
  String get shellAccountSignInUnsupported => 'This engine doesn’t support account sign-in';

  @override
  String get shellSignInDeepSeek => 'Sign in with DeepSeek';

  @override
  String get shellUseApiKey => 'Use API key';

  @override
  String get shellOtherProviders => 'Other providers';

  @override
  String shellOnboardingStep(int step, int steps) {
    return 'Step $step of $steps';
  }

  @override
  String get shellRuntimeUpdating => 'Updating runtime';

  @override
  String get shellRuntimePreparing => 'Preparing runtime';

  @override
  String get shellRuntimeReady => 'Ready';

  @override
  String get shellRuntimeIncomplete => 'Installation incomplete';

  @override
  String get shellRuntimeFilesKept => 'Your chats and files stay';

  @override
  String get shellRuntimeFirstSetup => 'First setup takes a minute or two';

  @override
  String get shellRuntimeContinuing => 'Continuing shortly';

  @override
  String get shellRuntimeRestoreFailed => 'Couldn’t restore saved content';

  @override
  String get shellRuntimeExtractFailed => 'Couldn’t extract files';

  @override
  String get shellInstallLogs => 'Installation logs';

  @override
  String get shellRuntimeLocalOnly => 'Everything runs on this phone';

  @override
  String get shellRuntimeContinueWithoutKept => 'Continue without restoring';

  @override
  String get shellRuntimeAlmostDone => 'Almost done';

  @override
  String shellRuntimeSecondsRemaining(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'About $count seconds',
      one: 'About 1 second',
    );
    return '$_temp0';
  }

  @override
  String shellRuntimeMinutesRemaining(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'About $count minutes',
      one: 'About 1 minute',
    );
    return '$_temp0';
  }

  @override
  String get shellEngineLogs => 'Engine logs';

  @override
  String get shellWelcomeMessage => 'The DeepSeek agent,\nin your pocket';

  @override
  String get shellGetStarted => 'Start';

  @override
  String get shellSearchChats => 'Search chats';

  @override
  String get shellCollapseChatList => 'Collapse chat list';

  @override
  String get shellExpandChatList => 'Expand chat list';

  @override
  String get shellChatList => 'Chats';

  @override
  String get shellChatDetails => 'Chat details';

  @override
  String get shellCollapseDetails => 'Collapse details';

  @override
  String get shellExpand => 'Expand';

  @override
  String get shellUndo => 'Undo';

  @override
  String shellFolderDeleted(String name) {
    return 'Deleted “$name”';
  }

  @override
  String shellMovedToFolder(String name) {
    return 'Moved to “$name”';
  }

  @override
  String get shellMovedOutOfFolder => 'Moved out of folder';

  @override
  String get shellUnpinFailed => 'Couldn’t unpin. Try again later.';

  @override
  String get shellPinFailed => 'Couldn’t pin. Try again later.';

  @override
  String shellChatsUnpinned(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Unpinned $count chats',
      one: 'Unpinned 1 chat',
    );
    return '$_temp0';
  }

  @override
  String shellChatsPinned(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Pinned $count chats',
      one: 'Pinned 1 chat',
    );
    return '$_temp0';
  }

  @override
  String get shellArchiveFailed => 'Couldn’t archive. Try again later.';

  @override
  String shellChatsStoppedArchived(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Stopped and archived $count chats',
      one: 'Stopped and archived 1 chat',
    );
    return '$_temp0';
  }

  @override
  String shellChatsArchived(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Archived $count chats',
      one: 'Archived 1 chat',
    );
    return '$_temp0';
  }

  @override
  String shellFilterLabel(String label) {
    return 'Filter: $label';
  }

  @override
  String get shellFolders => 'Folders';

  @override
  String get shellNoRunningChats => 'No running chats';

  @override
  String get shellNoPendingChats => 'No chats need approval';

  @override
  String get shellNoUnreadChats => 'No unread chats';

  @override
  String get shellNoChatsYet => 'No chats yet';

  @override
  String shellFolderLabel(String name) {
    return 'Folder “$name”';
  }

  @override
  String shellFolderChatCount(String name, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Folder “$name”, $count chats',
      one: 'Folder “$name”, 1 chat',
    );
    return '$_temp0';
  }

  @override
  String get shellSort => 'Sort';

  @override
  String get shellRecentActivity => 'Recent activity';

  @override
  String get shellCreatedTime => 'Date created';

  @override
  String get shellNewFolder => 'New folder';

  @override
  String get shellManageFolders => 'Manage folders';

  @override
  String get shellMultiSelect => 'Select';

  @override
  String get shellFolderNameExists => 'A folder with this name already exists';

  @override
  String get shellEditFolder => 'Edit folder';

  @override
  String get shellFolderMark => 'Mark';

  @override
  String shellFolderColor(int number) {
    return 'Color $number';
  }

  @override
  String get shellMoveToFolder => 'Move to folder';

  @override
  String get shellMoveOutOfFolder => 'Move out of folder';

  @override
  String get shellDeleteFolder => 'Delete folder';

  @override
  String get shellDragToReorder => 'Drag to reorder';

  @override
  String get shellSelectChats => 'Select chats';

  @override
  String shellSelectedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count selected', one: '1 selected');
    return '$_temp0';
  }

  @override
  String get shellDeselectAll => 'Deselect all';

  @override
  String get shellSelectAll => 'Select all';

  @override
  String get shellUnpin => 'Unpin';

  @override
  String get shellArchive => 'Archive';

  @override
  String get shellCurrentlyRunning => 'Running';

  @override
  String get shellUnread => 'Unread';

  @override
  String get shellPinned => 'Pinned';

  @override
  String get shellEngineNotRunning => 'Engine isn’t running';

  @override
  String shellHostNotConnected(String name) {
    return 'Not connected to “$name” yet';
  }

  @override
  String get shellSearchAfterConnecting => 'Connect to search';

  @override
  String get shellChatsLoadFailed => 'Couldn’t load chats';

  @override
  String shellSearchHostChats(String name) {
    return 'Search chats on “$name”';
  }

  @override
  String get shellSearchTitlesHint => 'Search titles, including archived chats';

  @override
  String get shellSearchContentHint => 'Search titles and content, including archived chats';

  @override
  String get shellLoadingChatsEllipsis => 'Loading chats…';

  @override
  String get shellNoMatchingChats => 'No matching chats';

  @override
  String get shellSearchDifferentKeywords => 'Try another keyword, or separate words with spaces';

  @override
  String get shellArchived => 'Archived';

  @override
  String get shellRestoreBeforeOpening => 'Restore this archived chat to open it';

  @override
  String get shellRestoreAndOpen => 'Restore and open';

  @override
  String get shellRestoreFailed => 'Couldn’t restore. Try again later.';

  @override
  String get shellSearchingMessages => 'Searching message content…';

  @override
  String get shellHostTitleSearchOnly => 'This host only supports title search';

  @override
  String get shellContentSearchFailed => 'Couldn’t search content. Showing title matches only.';

  @override
  String get shellContentSearchLimit => 'Content search shows the 20 most relevant chats';

  @override
  String get shellMoveToOtherFolder => 'Move to another folder';

  @override
  String get shellArchiveStopsTurn => 'The current turn will stop';

  @override
  String get shellRenameFailed => 'Couldn’t rename. Try again later.';

  @override
  String shellChatStoppedArchived(String title) {
    return 'Stopped and archived “$title”';
  }

  @override
  String shellChatArchived(String title) {
    return 'Archived “$title”';
  }

  @override
  String get shellRenameChat => 'Rename chat';

  @override
  String get shellChatTitle => 'Chat title';

  @override
  String shellUnreadCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count unread', one: '1 unread');
    return '$_temp0';
  }

  @override
  String get shellLoadingChats => 'Loading chats';

  @override
  String get shellWorkspaceNoChats => 'No chats here yet';

  @override
  String get shellWorkspaceNewChatsHint =>
      'New chats go in this workspace. Earlier chats are not moved here automatically; find them in All chats.';

  @override
  String get shellNewChatsHint => 'New chats appear here';

  @override
  String get shellEngineStarting => 'Engine is starting';

  @override
  String get shellChatsAfterStarting => 'Your chats appear once it starts';

  @override
  String get shellStartEngine => 'Start engine';

  @override
  String get shellEngineStatusHint => 'View status in “Engine”';

  @override
  String shellHostUnreachable(String name) {
    return 'Can’t reach “$name”';
  }

  @override
  String shellHostReconnecting(String name) {
    return 'Reconnecting to “$name”…';
  }

  @override
  String get shellRetryNow => 'Retry now';

  @override
  String shellHostConnecting(String name) {
    return 'Connecting to “$name”…';
  }

  @override
  String get shellHostChatsAfterConnecting => 'This host’s chats appear once connected';

  @override
  String shellCurrentHostLabel(String name, String view) {
    return 'Current host: $name, $view. Switch host';
  }

  @override
  String get shellChatGone => 'This chat is gone';

  @override
  String get shellAccentMist => 'Mist';

  @override
  String get shellAccentDaiqing => 'Teal';

  @override
  String get shellAccentDusk => 'Dusk';

  @override
  String get shellAccentTurquoise => 'Aqua';

  @override
  String get shellAccentAmber => 'Amber';

  @override
  String get shellAccentGraphite => 'Slate';

  @override
  String get shellHideTurnFooter => 'Turn footer';

  @override
  String get shellHideTokenCount => 'Token count';

  @override
  String get shellHideReasoning => 'Thinking';

  @override
  String get shellHideActivityStrip => 'Activity strip';

  @override
  String get shellHideWhaleTail => 'Whale tail';

  @override
  String get shellHideTodoPill => 'To-do bar';

  @override
  String get shellHideGoalBar => 'Goal bar';

  @override
  String get shellToday => 'Today';

  @override
  String get shellThisWeek => 'This week';

  @override
  String get shellEarlier => 'Earlier';

  @override
  String get shellSeatNative => 'Native';

  @override
  String get shellSeatIsland => 'Embedded Web';

  @override
  String get shellSeatWeb => 'Open in DSH Web';

  @override
  String get shellPlugins => 'Plugins';

  @override
  String get shellHeaderActions => 'Header buttons';

  @override
  String get shellAllHidden => 'All hidden';

  @override
  String shellSettingCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count items', one: '1 item');
    return '$_temp0';
  }

  @override
  String get shellQuickActions => 'Quick actions';

  @override
  String get shellSuggestionCards => 'Suggestion cards';

  @override
  String shellSuggestionCardCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count cards', one: '1 card');
    return '$_temp0';
  }

  @override
  String get shellDrawerGroups => 'Drawer groups';

  @override
  String get shellDrawerSort => 'Drawer sort order';

  @override
  String get shellDrawerFilter => 'Drawer filter';

  @override
  String get shellPending => 'Pending';

  @override
  String get shellAll => 'All';

  @override
  String get shellDensity => 'Density';

  @override
  String get shellCompact => 'Compact';

  @override
  String get shellSpacious => 'Spacious';

  @override
  String get shellThemeMode => 'Appearance mode';

  @override
  String get shellAccentColor => 'Accent color';

  @override
  String get shellPet => 'Pet';

  @override
  String get shellConfigured => 'Set';

  @override
  String get shellShortcuts => 'Keyboard shortcuts';

  @override
  String get shellConfigFileTooLarge => 'File exceeds 64 KiB';

  @override
  String get shellConfigRootNotObject => 'Top level must be an object';

  @override
  String get shellConfigVersionMissing => 'Missing version';

  @override
  String get shellConfigVersionNotInt => 'version must be an integer';

  @override
  String get shellConfigVersionTooLow => 'version starts at 1';

  @override
  String shellConfigVersionTooHigh(int version) {
    return 'Update the app to use version $version';
  }

  @override
  String get shellConfigNotObject => 'Expected an object';

  @override
  String get shellConfigNotArray => 'Expected an array';

  @override
  String get shellConfigNotString => 'Expected a string';

  @override
  String get shellConfigNotBool => 'Expected true or false';

  @override
  String get shellConfigEmpty => 'Can’t be empty';

  @override
  String get shellConfigUnknownKey => 'Unknown key, ignored';

  @override
  String get shellConfigDuplicateKey => 'Duplicate key, only the last one applies';

  @override
  String get shellConfigDuplicateItem => 'Duplicate, ignored';

  @override
  String shellConfigMissing(String key) {
    return 'Missing $key';
  }

  @override
  String shellConfigTruncated(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Exceeds $count characters, truncated',
      one: 'Exceeds 1 character, truncated',
    );
    return '$_temp0';
  }

  @override
  String shellConfigTooLong(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Exceeds $count characters',
      one: 'Exceeds 1 character',
    );
    return '$_temp0';
  }

  @override
  String shellConfigTooMany(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Up to $count items, extras ignored',
      one: 'Up to 1 item, extras ignored',
    );
    return '$_temp0';
  }

  @override
  String get shellConfigValueNoun => 'value';

  @override
  String shellConfigUnsupportedValue(String noun, String value) {
    return 'Unsupported $noun “$value”';
  }

  @override
  String get shellConfigHeaderItem => 'Expected a button ID or object';

  @override
  String get shellConfigHeaderId => 'IDs can use letters, numbers, and -, starting with a lowercase letter';

  @override
  String get shellConfigIdTaken => 'Duplicate ID';

  @override
  String get shellConfigCommandSlash => 'Command names don’t include /, removed';

  @override
  String get shellConfigCommandName => 'Command names can only use letters, numbers, and : . _ -';

  @override
  String get shellConfigNoNewline => 'Line breaks aren’t allowed';

  @override
  String get shellConfigHttpsOnly => 'Only HTTPS links are supported';

  @override
  String get shellConfigBadUrl => 'Invalid link format';

  @override
  String get shellConfigAccentFormat => 'Use #RRGGBB for colors';

  @override
  String get shellConfigAccentBoth => 'Choose either this or accentPreset; accentPreset used';

  @override
  String get shellConfigPetId => 'IDs can only use lowercase letters, numbers, and -';

  @override
  String get shellConfigKeysFormat => 'Invalid format, for example ctrl+k';

  @override
  String get shellConfigSystemKey => 'System keys aren’t allowed';

  @override
  String get shellConfigNeedModifier => 'Include ctrl or alt';

  @override
  String get shellConfigReservedKey => 'Used by the system or keyboard';

  @override
  String shellConfigDuplicateShortcut(String pointer) {
    return 'Duplicates $pointer';
  }

  @override
  String get shellConfigSlotName => 'Invalid slot name format';

  @override
  String get shellConfigUnknownSlot => 'This slot isn’t in DSH yet, kept for later';

  @override
  String get shellConfigUnseatableSlot => 'Plugins aren’t supported here';

  @override
  String get shellConfigPackageName => 'Invalid package name format';

  @override
  String get shellConfigActionNoun => 'action';

  @override
  String get shellConfigPageNoun => 'page';

  @override
  String get shellConfigButtonNoun => 'button';

  @override
  String get shellConfigIconNoun => 'icon';

  @override
  String get shellConfigNotTextFile => 'Not a text file';

  @override
  String shellJsonPosition(int line, int column, String reason) {
    return 'Line $line, column $column: $reason';
  }

  @override
  String get shellJsonEmptyFile => 'File is empty';

  @override
  String get shellJsonExtraContent => 'Extra content at the end';

  @override
  String get shellJsonIncompleteFile => 'File is incomplete';

  @override
  String get shellJsonCommentsUnsupported => 'Comments aren’t supported';

  @override
  String get shellJsonDoubleQuotes => 'Strings need double quotes';

  @override
  String get shellJsonMissingValue => 'Missing a value here';

  @override
  String shellJsonUnknownContent(String value) {
    return 'Unrecognized content “$value”';
  }

  @override
  String get shellJsonTooDeep => 'Nesting is too deep';

  @override
  String get shellJsonExtraComma => 'Extra comma';

  @override
  String get shellJsonQuotedKey => 'Keys need double quotes';

  @override
  String get shellJsonExpectedKey => 'Expected a key here';

  @override
  String get shellJsonMissingColon => 'Missing a colon after the key';

  @override
  String get shellJsonMissingComma => 'Missing a comma here';

  @override
  String shellJsonUnexpectedContent(String value) {
    return 'Unexpected “$value” here';
  }

  @override
  String get shellJsonUnterminatedString => 'Unterminated string';

  @override
  String get shellJsonBadEscape => 'Invalid string escape';

  @override
  String get shellJsonStringNewline => 'Strings can’t contain literal line breaks';

  @override
  String get shellJsonControlCharacter => 'String contains a control character';

  @override
  String get shellJsonBadNumber => 'Invalid number format';

  @override
  String shellSkillInstallPrompt(String skill) {
    return 'Install the DSH Go interface skill $skill on this host:';
  }

  @override
  String shellSkillInstallDirectory(String skill) {
    return '1. Create the target folder `\$DSH_HOME/skills/$skill/` if needed (or `~/.dsh/skills/$skill/` if DSH_HOME isn’t set).';
  }

  @override
  String get shellSkillInstallFiles =>
      '2. Write each file below at its given relative path, keeping the contents exactly as provided.';

  @override
  String get shellSkillInstallConfirm => '4. Tell me when it’s installed.';

  @override
  String shellSkillInstallFile(String path) {
    return 'File `$path`:';
  }

  @override
  String get shellFromUiJson => 'From ui.json';

  @override
  String get shellViewSource => 'View source';

  @override
  String get shellSourcePosition => 'Location';

  @override
  String get shellRestoreDefaults => 'Reset to default';

  @override
  String get shellConfigNotApplied => 'Not applied';

  @override
  String shellConfigDroppedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count issues not applied',
      one: '1 issue not applied',
    );
    return '$_temp0';
  }

  @override
  String shellConfigAppliedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Applied $count items',
      one: 'Applied 1 item',
    );
    return '$_temp0';
  }

  @override
  String get shellInterfaceConfig => 'UI config';

  @override
  String get shellSkillNotInstalled => 'Skill not installed';

  @override
  String get shellInstallInterfaceSkill => 'Install interface skill';

  @override
  String get shellInstallInterfaceSkillMessage => 'Once installed, AI can adjust the app’s interface as you ask';

  @override
  String get shellNoUiJson => 'No ui.json';

  @override
  String get shellConfigUsingPrevious => 'Not applied, still using the previous configuration';

  @override
  String get shellConfigDroppedHeading => 'Not applied';

  @override
  String get shellConfigNotesHeading => 'Warnings';

  @override
  String get shellConfigAppliedHeading => 'Applied';

  @override
  String shellConfigValueOptions(String noun, String value, String options) {
    return 'Unsupported $noun “$value”, options: $options';
  }

  @override
  String get shellListSeparator => ', ';

  @override
  String shellSkillInstallCheck(String command) {
    return '3. Run $command after writing the files. If it runs, installation is complete (a message about ui.json not existing yet is normal).';
  }

  @override
  String get shellSemanticsSeparator => ', ';

  @override
  String shellChatsArchivedPartial(int count, int failed) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Archived $count chats',
      one: 'Archived 1 chat',
    );
    String _temp1 = intl.Intl.pluralLogic(
      failed,
      locale: localeName,
      other: 'couldn’t archive $failed chats',
      one: 'couldn’t archive 1 chat',
    );
    return '$_temp0; $_temp1';
  }

  @override
  String get shellPanelOverview => 'Info';

  @override
  String get shellPanelWorkspace => 'Workspace';

  @override
  String get shellPanelModel => 'Model';

  @override
  String get shellPanelHost => 'Host';

  @override
  String get shellPanelOpenFull => 'Open full page';

  @override
  String get shellPanelNoPlugins => 'No plugin panels for this chat yet';

  @override
  String get shellQuickPanel => 'Shortcuts';

  @override
  String shellQuickPanelHint(String path) {
    return 'Change these in $path';
  }

  @override
  String get speechReadAloud => 'Read aloud';

  @override
  String get speechReadAloudStop => 'Stop reading';

  @override
  String get speechReadSection => 'Read aloud';

  @override
  String get speechReadFooter => 'Used by the read-aloud key under replies, the companion room and voice calls.';

  @override
  String get speechVoiceTitle => 'Reading voice';

  @override
  String get speechVoiceHello => 'Hello, this is the reading voice.';

  @override
  String get speechVoiceDeepseek => 'DeepSeek';

  @override
  String get speechVoiceDeepseekHint =>
      'Paid by your signed-in DeepSeek account; the API key in Settings when signed out or when the account can\'t pay for speech. Nothing to set up';

  @override
  String get speechVoiceDeepseekFooter =>
      'Billed by the number of characters read; see the DeepSeek platform for prices. Code blocks, tables and link addresses are left out.';

  @override
  String get speechVoiceStella => 'Stella (female)';

  @override
  String get speechVoiceTide => 'Tide (male)';

  @override
  String get speechVoiceStellaShort => 'Stella';

  @override
  String get speechVoiceTideShort => 'Tide';

  @override
  String get speechVoiceFollow => 'Same as read aloud';

  @override
  String get speechVoiceFollowHint => 'The reading voice in Settings › Voice';

  @override
  String get speechNotSetUp => 'The reading voice isn\'t set up yet. See Settings › Voice';

  @override
  String get speechNoCredential => 'Sign in to DeepSeek or add an API key in Settings first';

  @override
  String get speechAccountUnusable =>
      'Your signed-in account can\'t pay for DeepSeek speech here: the DSH you\'re connected to is older (updating fixes it), or you\'re going through DSH Remote. Add a DeepSeek API key in Settings to use it';

  @override
  String get speechSignIn =>
      'Your DeepSeek account can\'t pay for speech (sign-in expired, or speech takes only an API key). Sign in again, or add an API key in Settings';

  @override
  String get speechUnauthorized => 'The DeepSeek API key was refused. Check it in Settings';

  @override
  String get speechBalance => 'Not enough DeepSeek balance';

  @override
  String get speechRateLimited => 'Too many requests. Try again shortly';

  @override
  String get speechNothingToRead => 'This reply has no text to read';

  @override
  String get speechNotHeard => 'Didn\'t catch that. Say it again';

  @override
  String get speechTooLong => 'That recording is too long. Try shorter parts';

  @override
  String get speechBusy => 'The speech service is busy. Try again shortly';

  @override
  String get speechNetwork => 'Can\'t reach the speech service. Check the network';

  @override
  String get speechReadFailed => 'Couldn\'t read it aloud';

  @override
  String get speechListenFailed => 'Couldn\'t recognize it';

  @override
  String get speechCloudNotice =>
      'Your voice is sent to DeepSeek to be recognized. To recognize on the phone, switch to the voice model.';

  @override
  String get speechCloudNotSetUp => 'No cloud recognition service is set up';

  @override
  String get speechCallTile => 'Voice call';

  @override
  String get speechCallSection => 'Voice calls';

  @override
  String get speechCallFooter =>
      'In a call, pause after you speak and it is sent; the answer is read while it is written.';

  @override
  String get speechCallBargeIn => 'Interrupt by speaking';

  @override
  String get speechCallBargeInHint =>
      'When you speak over the AI it goes quiet; a “yeah” lets it go on, anything else stops it';

  @override
  String get speechCallSpoken => 'Spoken answers';

  @override
  String get speechCallSpokenHint => 'The call\'s first message asks for short, conversational answers';

  @override
  String get speechCallSpeaker => 'Speakerphone by default';

  @override
  String get speechCallSpeakerHint => 'Headphones always win when connected';

  @override
  String get speechCallHint =>
      '(This is a voice call; what I say comes through speech recognition. Please answer briefly and conversationally, without Markdown, lists, tables or code blocks.)';

  @override
  String speechCallCutNote(String heard) {
    return '(I cut you off at “$heard”; I didn\'t hear the rest.)';
  }

  @override
  String get speechCallCutEarly => '(I cut you off before you said anything; I didn\'t hear that answer.)';

  @override
  String get speechCallCue => 'Thinking sound';

  @override
  String get speechCallCueHint => 'A soft chime when an answer is slow to start';

  @override
  String get speechLiveSection => 'Live captions';

  @override
  String get speechLiveName => 'Streaming recognizer';

  @override
  String speechLiveAbsentNote(String mb) {
    return 'Download it and calls show your words as you speak, and stop sooner when you cut in. About $mb; it runs on the phone';
  }

  @override
  String speechLiveReadyNote(String mb) {
    return 'Using $mb. Calls use it automatically';
  }

  @override
  String get speechLiveBlocked => 'Off';

  @override
  String get speechLiveBlockedNote =>
      'It crashed on this phone, so live captions are off; calls work as before. Delete it and download again to try once more.';

  @override
  String get speechLiveFooter =>
      'Captions and cut-ins run on the phone; the text sent to the AI still comes from the recognition chosen above, and cloud recognition uploads the recording.';

  @override
  String get speechLiveDeleteTitle => 'Delete the streaming recognizer?';

  @override
  String get speechLiveDeleteBody => 'Calls will stop showing live captions. You can download it again any time.';

  @override
  String get speechCallStarting => 'Connecting';

  @override
  String get speechCallListening => 'Listening';

  @override
  String get speechCallHearing => 'You\'re speaking';

  @override
  String get speechCallThinking => 'Thinking';

  @override
  String get speechCallSpeaking => 'Speaking. Tap the light to skip';

  @override
  String get speechCallMuted => 'Muted';

  @override
  String get speechCallEnded => 'Call ended';

  @override
  String get speechCallEndPermission => 'No microphone permission';

  @override
  String get speechCallEndMicrophone => 'The microphone is busy or can\'t be opened';

  @override
  String get speechCallEndNoRecognizerSignedIn =>
      'A call needs a way to recognize speech. Your signed-in account can\'t pay for DeepSeek speech here (the DSH you\'re connected to is older, or you\'re going through DSH Remote): add a DeepSeek API key in Settings, or download the voice model in Settings › Voice';

  @override
  String get speechCallEndNoRecognizer =>
      'A call needs a recognizer that takes recordings: sign in to DeepSeek, add an API key, or download the voice model';

  @override
  String get speechCallEndBackground => 'Calls end when the app goes to the background';

  @override
  String get speechCallEndFailed => 'Recording failed; the call has ended';

  @override
  String get speechCallSendFailed => 'That didn\'t go through. Say it again';

  @override
  String get speechCallSkipHint => 'Skip this answer';

  @override
  String get speechCallTranscript => 'Captions';

  @override
  String get speechCallTranscriptHint => 'Everything said on this call';

  @override
  String get speechCallTranscriptEmpty => 'Nothing said yet. What you both say is written down here, line by line.';

  @override
  String get speechCallTranscriptCut => 'You cut in here';

  @override
  String get speechCallMute => 'Mute';

  @override
  String get speechCallUnmute => 'Unmute';

  @override
  String get speechCallHangUp => 'Hang up';

  @override
  String get speechCallSpeakerOn => 'Speaker';

  @override
  String get speechCallEarpiece => 'Earpiece';

  @override
  String get speechBackdropTitle => 'Call background';

  @override
  String get speechCallSettings => 'Call settings';

  @override
  String get speechCallPause => 'Pause before she answers';

  @override
  String get speechCallPauseQuick => 'Short';

  @override
  String get speechCallPauseNormal => 'Medium';

  @override
  String get speechCallPausePatient => 'Long';

  @override
  String get speechCallPauseHint => 'Pick Long if she cuts in while you pause; Short if she feels slow to answer.';

  @override
  String get speechCallSpeechSection => 'Voice and recognition';

  @override
  String get speechCallVoice => 'Her voice';

  @override
  String get speechCallSpeechHint => 'Changes apply from the next sentence.';

  @override
  String get speechBackdropSea => 'Deep sea';

  @override
  String get speechBackdropImage => 'My picture';

  @override
  String get speechBackdropImagePick => 'Pick a picture';

  @override
  String get speechBackdropCompanion => 'Companion';

  @override
  String get speechBackdropHint =>
      'Pictures are softened and darkened so captions stay readable. With your companion, she speaks along with the voice.';

  @override
  String get speechBackdropHintChange =>
      'Tap My picture again to change it. With your companion, she speaks along with the voice.';

  @override
  String get speechBackdropNoCompanion => 'Set her up in the companion room first to bring her into calls.';

  @override
  String get speechBackdropReplace => 'Change picture';

  @override
  String get speechBackdropPickFailed => 'That picture can\'t be used. Try another';

  @override
  String get speechCallVisual => 'Light';

  @override
  String get speechCallVisualRing => 'Ring';

  @override
  String get speechCallVisualMono => 'Line';

  @override
  String get speechCallVisualGlass => 'Orb';

  @override
  String get speechInsecure => 'That service\'s address isn\'t https; the key can\'t be sent that way';

  @override
  String starPromptTitle(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: 'I’ve kept you company in DSH Go for $hours hours now~',
      one: 'I’ve kept you company in DSH Go for an hour now~',
      zero: 'I’ve kept you company in DSH Go for half an hour now~',
    );
    return '$_temp0';
  }

  @override
  String get starPromptBody =>
      'DSH Go is free and open source. If it’s made your phone a little nicer to use, please give it a Star — it means so much to this little whale!';

  @override
  String get starPromptPlea => 'Pretty please~ It really matters!!';

  @override
  String get starPromptStar => 'Star it on GitHub';

  @override
  String get starPromptDone => 'Already starred';

  @override
  String get starPromptLater => 'Maybe later';

  @override
  String get starSettingsTitle => 'Star DSH Go on GitHub';

  @override
  String get hubStartPage => 'Start page';

  @override
  String get hubChatSuggestions => 'Chat suggestions';

  @override
  String get hubChatSuggestionsHint => 'Show chat suggestions on the start page';

  @override
  String get searchKwChatSuggestions => 'start page,empty page,new chat,chat suggestions,suggestion cards';

  @override
  String get phoneStartupFailureStopping => 'Startup failed; stopping';

  @override
  String phoneStartupFailureStoppingDetail(String reason) {
    return 'Startup failed; stopping. $reason';
  }

  @override
  String get phoneStartupTokenTimeout =>
      'Startup timed out: no startup token arrived within 180 seconds. Check the logs.';

  @override
  String get phoneStartupPortNotReady =>
      'The startup token arrived, but the local service port did not become ready. Check the logs.';

  @override
  String get stateDiagnosticsSubject => 'DSH Go diagnostics bundle';

  @override
  String get stateStoragePermission => 'No storage permission to save to Downloads';

  @override
  String get stateDiagnosticsStorageFull => 'Not enough storage to create the diagnostics bundle';

  @override
  String get stateDiagnosticsExportFailed => 'Couldn’t export diagnostics bundle';

  @override
  String get stateForumUnreachable => 'Can’t reach the forum';

  @override
  String get stateSignInExpired => 'Sign-in expired. Sign in again.';

  @override
  String get stateForbidden => 'Permission denied';

  @override
  String get stateForumContentMissing => 'Content not found or deleted';

  @override
  String get stateTooManyActions => 'Too many actions. Try again later.';

  @override
  String get stateForumSendFailed => 'Couldn’t send';

  @override
  String get stateForumServerError => 'The forum is having trouble';

  @override
  String get stateBrowserOpenFailed => 'Couldn’t open the browser';

  @override
  String get stateSignInStartFailed => 'Couldn’t start sign-in';

  @override
  String get stateSignInIncompleteRetry => 'Sign-in didn’t finish. Try again.';

  @override
  String get statePluginLabel => 'Plugin';

  @override
  String get stateConfigLabel => 'Configuration';

  @override
  String get stateConfigShare => 'Shared configuration';

  @override
  String get stateShareCode => 'Share code';

  @override
  String get stateCopyShareCodeFirst => 'Copy a share code from Share first';

  @override
  String get stateFileOpenFailed => 'Can’t open this file';

  @override
  String get stateLinkOpenFailed => 'Can’t open this link';

  @override
  String get stateAlertPublicDone => 'A turn finished';

  @override
  String get stateAlertPublicFailed => 'A turn failed';

  @override
  String get stateAlertPublicStopped => 'A turn stopped';

  @override
  String get stateAlertPublicApproval => 'A step needs your approval';

  @override
  String get stateAlertPublicQuestion => 'A question needs your answer';

  @override
  String get stateAlertTurnDone => 'This turn finished';

  @override
  String get stateAlertOutputLimit => 'Ended · Output limit reached';

  @override
  String get stateAlertTurnBlocked => 'This turn was blocked';

  @override
  String get stateAlertEngineRestarted => 'Interrupted · Engine restarted';

  @override
  String get stateAlertMissingKey => 'Error · No API key set';

  @override
  String get stateAlertTurnFailed => 'This turn failed';

  @override
  String get stateRunCommand => 'Run command';

  @override
  String get stateWriteFile => 'Write file';

  @override
  String get stateEditFile => 'Edit file';

  @override
  String get stateOpenPage => 'Open web page';

  @override
  String get stateWebSearch => 'Web search';

  @override
  String get stateAlertQuestion => 'A question for you';

  @override
  String get stateSizeSmall => 'Small';

  @override
  String get stateSizeStandard => 'Standard';

  @override
  String get stateSizeLarge => 'Large';

  @override
  String get stateSizeCustom => 'Custom';

  @override
  String get statePetDone => 'Done';

  @override
  String get statePetFailed => 'Something went wrong';

  @override
  String get statePhoneNotReady => 'Phone control isn’t ready';

  @override
  String get stateBackgroundRestricted => 'Background network access is restricted';

  @override
  String get stateBackgroundFinish => 'Let chats finish in the background';

  @override
  String get stateDeepSeekAccount => 'DeepSeek account';

  @override
  String get stateAccountUnreachable => 'Can’t reach DeepSeek';

  @override
  String get stateAccountUnavailable => 'DeepSeek sign-in is unavailable';

  @override
  String get stateSignInIncomplete => 'Sign-in didn’t finish';

  @override
  String get stateSignInTimeout => 'Sign-in timed out';

  @override
  String get stateSignInSaveFailed => 'Couldn’t save sign-in details';

  @override
  String get stateEngineNotReady => 'The engine isn’t ready';

  @override
  String get stateSignInInterrupted => 'Sign-in interrupted';

  @override
  String get stateAccountUnsupported => 'This engine doesn’t support account sign-in';

  @override
  String get stateCheckPhoneNetwork => 'Check your phone’s network and try again';

  @override
  String get stateServiceUnavailableRetry => 'Service unavailable. Try again later.';

  @override
  String get stateAuthorizationFailed => 'Authorization failed. Sign in again.';

  @override
  String get stateAuthorizationExpired => 'Authorization page expired. Sign in again.';

  @override
  String get stateRestartEngineRetry => 'Restart from Engine, then try again';

  @override
  String get stateEngineStartingRetry => 'The engine is starting. Try again later.';

  @override
  String get stateEngineDisconnectedSignIn => 'Engine disconnected. Sign in again.';

  @override
  String get stateUpdateRuntimeOrKey => 'Update the runtime or use an API key';

  @override
  String get stateEngineDisconnected => 'Engine disconnected';

  @override
  String get stateAgentError => 'Error';

  @override
  String get stateNotRunning => 'Not running';

  @override
  String get stateAgentOneShot => 'One-shot';

  @override
  String get stateAgentContinuable => 'Continuable';

  @override
  String get stateAgentExternal => 'External task';

  @override
  String get stateSubagent => 'Subagent';

  @override
  String get stateParentChat => 'Parent chat';

  @override
  String get statePreparing => 'Provisioning';

  @override
  String get stateIconMist => 'Mist blue';

  @override
  String get stateIconNight => 'Nightfall';

  @override
  String get stateIconFrost => 'Frost white';

  @override
  String get stateIconInk => 'Ink';

  @override
  String get stateAppDisclaimer => 'Built on DeepSeek Harness · Unofficial DeepSeek app';

  @override
  String get stateWallpaper => 'Wallpaper';

  @override
  String get stateFileMissing => 'File not found. It may have been deleted or moved.';

  @override
  String get stateFileNoApp => 'No app on this phone can open this file type';

  @override
  String get stateFileConnectionLimit => 'File is too large for this connection';

  @override
  String get stateFileReadUnsupported => 'This connection can’t read files';

  @override
  String get stateArtifactImage => 'Image';

  @override
  String get stateArtifactDocument => 'Document';

  @override
  String get stateArtifactSheet => 'Spreadsheet';

  @override
  String get stateArtifactSlides => 'Presentation';

  @override
  String get stateArtifactArchive => 'Archive';

  @override
  String get stateArtifactAudio => 'Audio';

  @override
  String get stateArtifactVideo => 'Video';

  @override
  String get stateArtifactWeb => 'Web page';

  @override
  String get stateArtifactText => 'Text';

  @override
  String get stateArtifactFile => 'File';

  @override
  String get statePrivateKeyTooLarge => 'File is too large to be a private key';

  @override
  String get stateBotTeamBusy => 'Another DSH is using this team';

  @override
  String get stateBotOperationFailed => 'Couldn’t finish. Try again.';

  @override
  String get stateBotMissing => 'This host doesn’t have DS Bot';

  @override
  String get stateHostAuthFailed => 'Host authentication failed';

  @override
  String get stateUnexpectedError => 'Something went wrong';

  @override
  String get stateGroupChat => 'Group chat';

  @override
  String get stateBotNewMessage => 'New bot message';

  @override
  String get stateChatAgentBusy => 'AI is busy. Try again later.';

  @override
  String get stateChatWriterHeld => 'This chat is in use elsewhere';

  @override
  String get stateChatModelUnavailable => 'This model is unavailable';

  @override
  String get stateChatAttachmentInvalid => 'Can’t send this attachment';

  @override
  String get stateChatForkUnavailable => 'Can’t branch here';

  @override
  String get stateChatImagesTooLarge => 'Images are too large. Send fewer at once.';

  @override
  String get stateChatSyncInterrupted => 'Chat sync interrupted';

  @override
  String get stateChatSynchronizing => 'Syncing chat';

  @override
  String get stateChatSyncRetry => 'Sync again';

  @override
  String get stateChatSyncRequired => 'Chat is not synced yet. Sync again and retry.';

  @override
  String get stateChatAutoApproveFailed => 'Couldn’t allow automatically';

  @override
  String get stateCommandMissing => 'Command not found';

  @override
  String get stateCommandFailed => 'Command didn’t run';

  @override
  String get stateChatStopSteered => 'Couldn’t stop this turn. Sent as a steer.';

  @override
  String get stateChatTextOnlyModel =>
      'Sent as files: this model doesn’t list image input. Switch models or set its Input to Text + image.';

  @override
  String get stateAttachmentUploadFailed => 'Couldn’t upload attachment';

  @override
  String get stateChatImageModelRequired =>
      'This model doesn’t list image input. Switch models or set its Input to Text + image and resend.';

  @override
  String get stateSendFailed => 'Couldn’t send';

  @override
  String get stateChatStopFailed => 'Couldn’t stop. Try again.';

  @override
  String get stateChatTurnEnded => 'This turn has ended. Your message will start a new turn.';

  @override
  String get stateChatSteerFailed => 'Couldn’t steer';

  @override
  String get stateChatUndoTooLate => 'Too late. AI has already read this message.';

  @override
  String get stateChatUndoFailed => 'Couldn’t undo';

  @override
  String get stateChatApprovalFailed => 'Couldn’t submit approval';

  @override
  String get stateChatAnswerFailed => 'Couldn’t submit answer';

  @override
  String get stateChatModelSwitchFailed => 'Couldn’t switch model';

  @override
  String get stateChatHistoryFailed => 'Couldn’t load history';

  @override
  String get stateChatBranchLastReply => 'Branch from the last reply of a finished turn';

  @override
  String get stateChatBranchFailed => 'Couldn’t branch';

  @override
  String get stateChatEarlierHistoryFailed => 'Couldn’t load earlier history';

  @override
  String get stateChatNoEarlierHistory => 'There’s no history before this message. Start a new chat.';

  @override
  String get stateCommandNewDescription => 'Start a new chat';

  @override
  String get stateModelLabel => 'Model';

  @override
  String get stateCommandModelDescription => 'Change model and thinking depth';

  @override
  String get stateCommandExportLabel => 'Export logs';

  @override
  String get stateCommandExportDescription => 'Export this chat’s full history as a ZIP to share or save to Downloads';

  @override
  String get stateAllFeatures => 'All features';

  @override
  String get stateCommandFeaturesDescription => 'Access every feature in DSH Web';

  @override
  String get stateCompactLabel => 'Compact';

  @override
  String get stateCommandCompactDescription => 'Compact the chat above to free up context';

  @override
  String get statePermissionLabel => 'Permission';

  @override
  String get stateCommandPermissionDescription => 'Switch the permission preset (sandbox mode + approval policy)';

  @override
  String get stateCommandPermissionHint => '<preset name>';

  @override
  String get statePlanLabel => 'Plan';

  @override
  String get stateCommandPlanDescription => 'Enter or leave Plan mode';

  @override
  String get stateGoalLabel => 'Goal';

  @override
  String get stateCommandGoalDescription => 'Set or view the goal for a long-running task';

  @override
  String get stateFeedbackLabel => 'Feedback';

  @override
  String get stateCommandFeedbackDescription => 'Send feedback on this chat';

  @override
  String get stateCommandFeedbackHint => '<message>';

  @override
  String get stateShareFileTooLarge => 'A file was too large and wasn’t added';

  @override
  String get stateShareFileUnreadable => 'Couldn’t read a file';

  @override
  String get stateShareImagesOnly => 'This host can only send images';

  @override
  String get stateComposerInserted => 'Added to the composer';

  @override
  String get stateCordisPending => 'Pending';

  @override
  String get stateCordisStarting => 'Starting';

  @override
  String get stateCordisRunFailed => 'Run failed';

  @override
  String get stateCordisNoApproval => 'Run permission wasn’t granted';

  @override
  String get stateCordisBackendFailed => 'Couldn’t start the background component';

  @override
  String get stateCordisClientLoadFailed => 'Couldn’t load the interface';

  @override
  String get stateCordisRenderFailed => 'Couldn’t display the interface';

  @override
  String get stateCordisFailed => 'Couldn’t run';

  @override
  String get stateDrawerAll => 'All';

  @override
  String get stateDrawerUnread => 'Unread';

  @override
  String get stateDrawerToday => 'Today';

  @override
  String get stateDrawerThisWeek => 'This week';

  @override
  String get stateDrawerEarlier => 'Earlier';

  @override
  String get stateEngineAuthFailed => 'Engine authentication failed';

  @override
  String get stateChatMissing => 'This chat is gone';

  @override
  String get stateChatFormatUnsupported =>
      'This engine cannot read this chat\'s log format. Export diagnostics to investigate.';

  @override
  String get stateEngineUnsupported => 'Not supported by this engine version';

  @override
  String get stateEngineServiceUnavailable =>
      'The required engine service is not ready. Check the engine logs or export diagnostics.';

  @override
  String get stateEngineOperationUnavailable =>
      'The engine cannot run this operation right now. Check the engine logs.';

  @override
  String get stateSettingsRefreshed => 'Changed elsewhere. Refreshed.';

  @override
  String get stateCredentialFromEnvironment => 'This key comes from the engine’s environment and can’t be changed here';

  @override
  String get stateSettingsFromFile => 'Set by configuration file';

  @override
  String get stateSettingsInteger => 'Enter a whole number';

  @override
  String get stateSettingsInvalidFormat => 'Invalid format';

  @override
  String get stateSettingsReadOnly => 'Engine settings are read-only';

  @override
  String get statePluginDisabled => 'Plugin is disabled';

  @override
  String get stateSettingsRestartRequired => 'Restart the engine to change this';

  @override
  String get stateSettingsInvalidValue => 'Invalid value';

  @override
  String get stateSettingsRejected => 'The engine didn’t accept this value';

  @override
  String get stateInventoryEnabled => 'Enabled';

  @override
  String get stateInventoryDisabled => 'Disabled';

  @override
  String get stateLoading => 'Loading';

  @override
  String get stateInventoryWaiting => 'Waiting for dependencies';

  @override
  String get stateInventoryConditional => 'Conditional';

  @override
  String get stateBundleBuiltIn => 'Built into DSH';

  @override
  String get stateBundleHeadless => 'Headless';

  @override
  String get stateConfigFile => 'Configuration file';

  @override
  String get stateGoalEmpty => 'Goal can’t be empty';

  @override
  String get stateGoalPauseFailed => 'Couldn’t pause';

  @override
  String get stateGoalResumeFailed => 'Couldn’t resume';

  @override
  String get stateGoalClearOffline => 'Couldn’t clear: Can’t reach the engine';

  @override
  String get stateGoalClearFailed => 'Couldn’t clear';

  @override
  String get stateGoalStale => 'Goal changed. Try again.';

  @override
  String get stateGoalMissing => 'Goal is gone';

  @override
  String get stateGoalChatNotReady => 'Chat isn’t ready. Try again later.';

  @override
  String get stateGoalTurnsExhausted => 'No turns left';

  @override
  String get stateGoalStateChanged => 'Goal status changed';

  @override
  String get stateSshHost => 'SSH host';

  @override
  String get stateHostBrowserFailed => 'Couldn’t open the browser. Copy the sign-in link and open it in a browser.';

  @override
  String get stateSignInFailed => 'Couldn’t sign in';

  @override
  String get stateMarketTooLarge => 'Plugin catalog is too large. Download stopped.';

  @override
  String get stateMarketUnreachable => 'Can’t reach the plugin catalog';

  @override
  String get stateMarketInsecure => 'Couldn’t connect securely to the plugin catalog';

  @override
  String get stateMarketTimeout => 'Plugin catalog timed out';

  @override
  String get stateMarketInterrupted => 'Plugin catalog download interrupted';

  @override
  String get stateRegistryDefault => 'Default registry';

  @override
  String get stateRegistryNpm => 'Official npm registry';

  @override
  String get stateRegistryMirror => 'npmmirror mirror';

  @override
  String get statePluginIncompatible => 'This plugin doesn’t support the current DSH version.';

  @override
  String get statePluginInstallCancelled => 'Installation cancelled';

  @override
  String get statePluginNoChanges => 'Nothing was changed';

  @override
  String get statePluginIncompatibleTitle => 'Incompatible with this DSH';

  @override
  String get statePluginNetworkFailed => 'Can’t connect';

  @override
  String get statePluginSourceUnreachable => 'Can’t reach the plugin’s source website';

  @override
  String get statePluginDownloadTimeout => 'Download timed out';

  @override
  String get statePluginRegistryUnavailable => 'Registry isn’t responding';

  @override
  String get statePluginPnpmMissing => 'pnpm missing';

  @override
  String get statePluginPhonePnpmMissing => 'pnpm is missing on this phone';

  @override
  String get statePluginHostPnpmMissing => 'pnpm is missing on this host';

  @override
  String get statePluginNotFound => 'Plugin not found';

  @override
  String get statePluginPackageMissing => 'Package not found in the registry';

  @override
  String get statePluginTooNew => 'Version is too new';

  @override
  String get statePluginWaitForRelease => 'Available to install 24 hours after release';

  @override
  String get statePluginVersionMissing => 'Version not found';

  @override
  String get statePluginRegistryVersionMissing => 'This version isn’t in the registry yet';

  @override
  String get stateDeviceStorageFull => 'Not enough device storage';

  @override
  String get statePluginNoWritePermission => 'No write permission';

  @override
  String get statePluginConfigReadOnly => 'Engine configuration directory isn’t writable';

  @override
  String get statePluginIntegrityFailed => 'File verification failed';

  @override
  String get statePluginDownloadIncomplete => 'Downloaded file is incomplete';

  @override
  String get statePluginBuildScripts => 'Build scripts required';

  @override
  String get statePluginBuildApproval => 'Build scripts need approval';

  @override
  String get statePluginAlreadyInstalled => 'Already installed';

  @override
  String get statePluginUninstallFirst => 'Uninstall before switching versions';

  @override
  String get statePluginInvalid => 'Not a DSH plugin';

  @override
  String get statePluginNoEntry => 'This package has no plugin entry. Installation rolled back.';

  @override
  String get statePluginInUse => 'Plugin is in use';

  @override
  String get statePluginHasDependents => 'Other plugins depend on it';

  @override
  String get statePluginManagedElsewhere => 'Can’t change this here';

  @override
  String get statePluginEngineManaged => 'This plugin is managed by the engine';

  @override
  String get statePluginAuthorizationExpired => 'Authorization expired';

  @override
  String get statePluginBuildChanged => 'Build scripts changed. Reinstall the plugin.';

  @override
  String get statePluginInvalidAddress => 'Invalid installation URL';

  @override
  String get statePluginCatalogInvalidAddress => 'The catalog’s installation URL is invalid';

  @override
  String get statePluginOperationIncomplete => 'Operation didn’t finish';

  @override
  String get statePluginRemoteForbidden => 'This host doesn’t allow remote installation';

  @override
  String get statePluginRelayToggleOnly => 'Relay connections can only turn plugins on or off';

  @override
  String get statePluginManagementUnsupported => 'Host doesn’t support plugin management';

  @override
  String get statePluginEngineUnsupported => 'This engine doesn’t support plugin management';

  @override
  String get statePluginResultMissing => 'Couldn’t get the installation result';

  @override
  String get statePluginResultPending => 'Installation result pending';

  @override
  String get statePluginDisconnected => 'Disconnected';

  @override
  String get statePluginQueued => 'Queued';

  @override
  String get statePluginRemoving => 'Uninstalling old version';

  @override
  String get statePluginInstalling => 'Downloading and installing';

  @override
  String get statePluginApplying => 'Enabling';

  @override
  String get statePluginCancelling => 'Cancelling';

  @override
  String get statePluginInstalledRestart => 'Installed. Restart to apply.';

  @override
  String get statePluginInstallFailed => 'Couldn’t install';

  @override
  String get statePluginConnectFirst => 'Connect to install plugins';

  @override
  String get stateProviderOpenAi => 'OpenAI compatible';

  @override
  String get stateProviderAnthropic => 'Anthropic compatible';

  @override
  String get stateProviderUrlRequired => 'Enter a Base URL';

  @override
  String get stateProviderUrlInvalid => 'Enter a full URL starting with http:// or https://';

  @override
  String get stateProviderUrlSuffix => 'Remove the part after ? or #';

  @override
  String get stateProviderKeyRequired => 'Enter an API key';

  @override
  String get stateProviderKeyOnly => 'Paste only the key, without the variable name';

  @override
  String get stateProviderKeyQuotes => 'Remove the surrounding quotes';

  @override
  String get stateProviderKeyInvalid => 'Key contains invalid characters';

  @override
  String get stateProviderModelRequired => 'Enter a model ID';

  @override
  String get stateProviderModelSpaces => 'Model ID can’t contain spaces';

  @override
  String get stateProviderAlreadyAdded => 'Already added';

  @override
  String get stateProviderConflict => 'Provider changed. Go back and try again.';

  @override
  String get stateProviderUnsupported => 'This engine version doesn’t support this action';

  @override
  String get stateProviderKeyRejected => 'API key is invalid or lacks permission';

  @override
  String get stateProviderModelsMissing => 'Model list not found. Check the Base URL.';

  @override
  String get stateProviderRateLimited => 'Too many requests. Try again later.';

  @override
  String get stateProviderResponseTooLarge => 'Response is too large';

  @override
  String get stateProviderUnreachable => 'Can’t reach this address. Check the Base URL and network.';

  @override
  String get stateProviderModelsUnreadable => 'Couldn’t read the model list. Check the Base URL.';

  @override
  String get stateProviderManualModels => 'This protocol can’t list models. Add them manually.';

  @override
  String get stateProviderConfigRejected => 'The engine rejected this configuration. Check the protocol and model.';

  @override
  String get stateProviderOffline => 'Can’t reach the engine';

  @override
  String get stateSafeStartupFailed => 'Failed to start';

  @override
  String get stateSafeCrashedEarly => 'Crashed shortly after starting';

  @override
  String get stateSafeCrashedLate => 'Crashed while running';

  @override
  String get stateSafeKilled => 'Stopped by the system';

  @override
  String get stateSafeManualEntry => 'I entered Safe mode manually';

  @override
  String get stateScheduleNotCreated => 'Chat ended without creating the automation';

  @override
  String get stateScheduleChatFailed => 'Chat failed';

  @override
  String get stateScheduleResultPending => 'Still waiting for a result';

  @override
  String get statePlanPending => 'Plan review';

  @override
  String get stateQuestionPending => 'Needs an answer';

  @override
  String get stateExportRelayUnsupported => 'Export isn’t available over Relay yet';

  @override
  String get stateExportChatMissing => 'Chat not found';

  @override
  String get stateExportFailed => 'Couldn’t export';

  @override
  String get stateSizeExtraLarge => 'Extra large';

  @override
  String get stateSubscriptionUnsupported => 'This engine doesn’t support subscription sign-in';

  @override
  String get stateSubscriptionUnreachable => 'Can’t reach the sign-in service. Check your network and try again.';

  @override
  String get stateSubscriptionSignInFailed => 'Couldn’t finish signing in. Try again.';

  @override
  String get stateSubscriptionTimeout => 'Request timed out. Check your network and try again.';

  @override
  String get stateSubscriptionDisconnected => 'Engine disconnected. Try again later.';

  @override
  String get stateTerminalLimit => 'Terminal limit reached';

  @override
  String get stateTerminalStartFailed => 'Couldn’t start terminal';

  @override
  String get stateTerminalDisabledOnHost =>
      'This computer turned off the remote terminal. Turn on “Terminal” in Remote settings on the computer, then try again.';

  @override
  String get stateTileDuotone => 'Duotone';

  @override
  String get stateTileGeometric => 'Geometric';

  @override
  String get stateTileGlassy => 'Glass';

  @override
  String get stateUiNative => 'Native';

  @override
  String get stateDefaultWorkspace => 'Default workspace';

  @override
  String stateDiagnosticsSaved(String where) {
    return 'Saved to $where';
  }

  @override
  String get stateDownloadsPrefix => 'Downloads/';

  @override
  String stateSharePluginCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count plugins', one: '1 plugin');
    return '$_temp0';
  }

  @override
  String stateShareSkillCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count skills', one: '1 skill');
    return '$_temp0';
  }

  @override
  String stateShareSettingCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count settings groups',
      one: '1 settings group',
    );
    return '$_temp0';
  }

  @override
  String stateAlertCompletedReply(String reply) {
    return 'Completed · $reply';
  }

  @override
  String stateAlertErrorDetail(String detail) {
    return 'Error · $detail';
  }

  @override
  String stateAlertUseTool(String name) {
    return 'Use tool $name';
  }

  @override
  String stateAlertApprovalAction(String action) {
    return 'Needs approval: $action';
  }

  @override
  String stateAlertApprovalReason(String action, String reason) {
    return 'Needs approval: $action · $reason';
  }

  @override
  String stateAlertQuestions(String question, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Question for you: $question ($count total)',
      one: 'Question for you: $question (1 total)',
    );
    return '$_temp0';
  }

  @override
  String stateAlertQuestionText(String question) {
    return 'Question for you: $question';
  }

  @override
  String statePetChatsDone(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count chats finished',
      one: '1 chat finished',
    );
    return '$_temp0';
  }

  @override
  String statePetChatsFailed(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count chats failed',
      one: '1 chat failed',
    );
    return '$_temp0';
  }

  @override
  String statePetChatsApproval(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count chats need approval',
      one: '1 chat needs approval',
    );
    return '$_temp0';
  }

  @override
  String statePetChatsQuestion(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count chats need your answer',
      one: '1 chat needs your answer',
    );
    return '$_temp0';
  }

  @override
  String stateAttachmentEmpty(String name) {
    return '“$name” is empty';
  }

  @override
  String stateAttachmentImageLimit(String name) {
    return 'Image “$name” exceeds 20 MB';
  }

  @override
  String stateAttachmentFileLimit(String name) {
    return 'File “$name” exceeds 200 MB';
  }

  @override
  String get stateAttachmentTotalLimit => 'Attachments exceed 400 MB in total';

  @override
  String stateBotFinished(String name) {
    return '$name finished working';
  }

  @override
  String stateBotQuestion(String name, String text) {
    return '$name asks: $text';
  }

  @override
  String stateBotApproval(String name, String text) {
    return '$name needs approval: $text';
  }

  @override
  String get stateCommandPlanHint => '[off | request]';

  @override
  String get stateCommandGoalHint => '[goal | clear | pause | resume]';

  @override
  String stateShareReadFailed(String name) {
    return 'Couldn’t read “$name”';
  }

  @override
  String stateShareAttachmentLimit(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Up to $count attachments per message',
      one: 'Up to 1 attachment per message',
    );
    return '$_temp0';
  }

  @override
  String stateShareNamedFileTooLarge(String name) {
    return '“$name” is too large and wasn’t added';
  }

  @override
  String stateShareTextTruncated(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Text is too long. Kept the first $count characters.',
      one: 'Text is too long. Kept the first character.',
    );
    return '$_temp0';
  }

  @override
  String stateSettingsMinimum(String bound) {
    return 'Must be at least $bound';
  }

  @override
  String stateSettingsMaximum(String bound) {
    return 'Must be at most $bound';
  }

  @override
  String stateSettingsMultiple(String bound) {
    return 'Must be a multiple of $bound';
  }

  @override
  String stateSettingsMinLength(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'At least $count characters',
      one: 'At least 1 character',
    );
    return '$_temp0';
  }

  @override
  String stateSettingsMaxLength(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'At most $count characters',
      one: 'At most 1 character',
    );
    return '$_temp0';
  }

  @override
  String stateEngineHttpRejected(int status) {
    return 'The engine rejected the request ($status)';
  }

  @override
  String stateGoalActionOffline(String action) {
    return '$action: Can’t reach the engine';
  }

  @override
  String stateHostRemoteLabel(String name) {
    return '$name · Remote';
  }

  @override
  String stateMarketHttpError(int status) {
    return 'Can’t open the plugin catalog (HTTP $status)';
  }

  @override
  String statePluginRuntimeIncompatible(String version) {
    return 'This plugin doesn’t support the current DSH version ($version).';
  }

  @override
  String statePluginRequiredVersion(String wanted, String current) {
    return 'This plugin requires DSH $wanted. Current version: $current.';
  }

  @override
  String get statePluginRegistryUnreachable => 'Can’t reach the registry';

  @override
  String statePluginNamedRegistryUnreachable(String registry) {
    return 'Can’t reach the registry ($registry)';
  }

  @override
  String statePluginBuildsPending(String builds) {
    return 'Needs approval: $builds';
  }

  @override
  String statePluginRegistryProgress(String registry, int attempt, int attempts) {
    return 'Downloading from $registry (registry $attempt/$attempts)';
  }

  @override
  String stateProviderServiceUnavailable(int status) {
    return 'Service unavailable ($status)';
  }

  @override
  String stateProviderServiceStatus(int status) {
    return 'Service returned $status';
  }

  @override
  String stateProviderKeySaveFailed(String reason) {
    return 'Provider saved, but the key wasn’t: $reason';
  }

  @override
  String stateSafeSuspectPlugins(String what, String plugins) {
    return '$what, suspected plugins: $plugins';
  }

  @override
  String stateSafePreflightFailed(String what, String checks) {
    return '$what, startup checks failed: $checks';
  }

  @override
  String get stateListSeparator => ', ';

  @override
  String stateSafeRepairPrompt(String what) {
    return 'My DSH has a problem in normal mode ($what). Follow the Safe mode instructions to find the cause. Fix the web configuration using reversible changes, verify startup with dsh-app-plugins trial, then tell me what changed.';
  }

  @override
  String stateScheduleCreatePrompt(String title, String rule, String args) {
    return 'Create automation “$title”: $rule.\nCall schedule_create exactly once, using these arguments unchanged. Don’t run the task now.\n\n```json\n$args\n```';
  }

  @override
  String stateActionReason(String action, String reason) {
    return '$action: $reason';
  }

  @override
  String stateAlertPreviewRun(String value) {
    return 'Run: $value';
  }

  @override
  String stateAlertPreviewWrite(String value) {
    return 'Write: $value';
  }

  @override
  String stateAlertPreviewEdit(String value) {
    return 'Edit: $value';
  }

  @override
  String stateAlertPreviewOpen(String value) {
    return 'Open: $value';
  }

  @override
  String stateAlertPreviewUse(String value) {
    return 'Use tool: $value';
  }

  @override
  String get stateUiWeb => 'Web';

  @override
  String statePluginRegistryProgressUnknown(String registry, int attempt) {
    return 'Downloading from $registry (registry $attempt/null)';
  }

  @override
  String get stateProviderTokenCountInvalid => 'Enter a number, like 128K';

  @override
  String get appSlogan => 'Anytime, anywhere. Just Go!';

  @override
  String get tavernTitle => 'Tavern';

  @override
  String get tavernImport => 'Import';

  @override
  String get tavernEmptyTitle => 'No characters yet';

  @override
  String get tavernEmptyMessage => 'Import a character card: PNG, JSON or CHARX';

  @override
  String get tavernContinue => 'Continue';

  @override
  String get tavernCharacters => 'Characters';

  @override
  String tavernImported(String name) {
    return 'Imported “$name”';
  }

  @override
  String get tavernImportLorebook => 'This is a lorebook, not a character card';

  @override
  String get tavernImportFailed => 'Couldn\'t read this card';

  @override
  String get tavernCharacterGone => 'This character is gone';

  @override
  String get tavernDeleteCharacter => 'Delete character';

  @override
  String tavernDeleteCharacterTitle(String name) {
    return 'Delete “$name”?';
  }

  @override
  String get tavernDeleteCharacterMessage => 'Its chats are deleted too.';

  @override
  String get tavernGreeting => 'Greeting';

  @override
  String tavernGreetingOf(int index, int count) {
    return 'Greeting $index/$count';
  }

  @override
  String get tavernStart => 'Start';

  @override
  String get tavernContinueLast => 'Continue where you left off';

  @override
  String get tavernStartNew => 'New chat from this greeting';

  @override
  String get tavernChats => 'Chats';

  @override
  String tavernMessageCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count messages', one: '1 message');
    return '$_temp0';
  }

  @override
  String get tavernCreatorNotes => 'Creator\'s notes';

  @override
  String get tavernDefinition => 'Definition';

  @override
  String tavernComposerHint(String name) {
    return 'Say something to $name…';
  }

  @override
  String get tavernReplying => 'Replying…';

  @override
  String get tavernReady => 'Ready';

  @override
  String get tavernPreviewStatus => 'Preview · sample replies, no model yet';

  @override
  String get tavernRegenerate => 'Regenerate';

  @override
  String get tavernContinueReply => 'Continue writing';

  @override
  String get tavernDeleteFrom => 'Delete this and everything after';

  @override
  String get tavernPrevious => 'Previous reply';

  @override
  String get tavernNext => 'Next reply';

  @override
  String get tavernErrorNoKey => 'Add a DeepSeek API key in Settings first';

  @override
  String get tavernKeyMissing => 'Add your DeepSeek API key, and the story can start.';

  @override
  String get tavernKeyMissingAction => 'Add key';

  @override
  String get tavernErrorBadKey => 'The API key was refused; check it in Settings';

  @override
  String get tavernErrorBusy => 'The model is busy; try again in a moment';

  @override
  String get tavernErrorNetwork => 'Can\'t connect; check the network and retry';

  @override
  String get tavernErrorTooLong => 'The chat is longer than the model\'s context';

  @override
  String get tavernCutShort =>
      'The reply reached the reply limit and stopped here. Continue it, or raise the limit in Tavern settings › Generation.';

  @override
  String get tavernFiltered => 'The model\'s content filter stopped part of this reply.';

  @override
  String get tavernErrorBalance => 'Your DeepSeek balance is too low. Top up, then try again';

  @override
  String get tavernErrorParameters => 'The model didn\'t accept this request\'s parameters';

  @override
  String tavernErrorParametersDetail(String detail) {
    return 'The model didn\'t accept this request\'s parameters: $detail';
  }

  @override
  String tavernErrorDetail(String detail) {
    return 'Something went wrong: $detail';
  }

  @override
  String get tavernSettings => 'Tavern settings';

  @override
  String get tavernSettingsModel => 'Model';

  @override
  String get tavernModelFlash => 'Flash';

  @override
  String get tavernModelPro => 'V4 Pro';

  @override
  String get tavernThinking => 'Thinking';

  @override
  String get tavernThinkingSubtitle => 'Think before replying';

  @override
  String get tavernApiKey => 'DeepSeek API key';

  @override
  String get tavernApiKeySet => 'Set';

  @override
  String get tavernApiKeyMissing => 'Not set';

  @override
  String get tavernDeleteChat => 'Delete chat';

  @override
  String get tavernDeleteChatTitle => 'Delete this chat?';

  @override
  String get tavernDeleteChatMessage => 'It can\'t be brought back.';

  @override
  String tavernDeleteFromTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delete these $count messages?',
      one: 'Delete this message?',
    );
    return '$_temp0';
  }

  @override
  String get tavernDeleteFromMessage =>
      'From this one to the latest, with their alternative replies and branches. They can\'t be brought back.';

  @override
  String get tavernSwitchedBranch => 'Switched to another branch';

  @override
  String get tavernUndo => 'Undo';

  @override
  String get tavernSettingsDisplay => 'Display';

  @override
  String get tavernPresets => 'Presets';

  @override
  String get tavernPresetImport => 'Import preset';

  @override
  String get tavernPresetStDefault => 'SillyTavern default';

  @override
  String get tavernPresetStDefaultNote => 'Used when no preset is chosen';

  @override
  String get tavernPresetDefault => 'Default';

  @override
  String get tavernPresetSetDefault => 'Make default';

  @override
  String get tavernPresetUnsetDefault => 'Stop using as default';

  @override
  String get tavernPresetExport => 'Export preset';

  @override
  String get tavernPresetDelete => 'Delete preset';

  @override
  String tavernPresetDeleteTitle(String name) {
    return 'Delete the preset “$name”?';
  }

  @override
  String get tavernPresetDeleteMessage => 'Chats that use it switch to the default preset. It can\'t be brought back.';

  @override
  String tavernPresetImported(String name) {
    return 'Imported “$name”';
  }

  @override
  String tavernPresetImportedWithIssues(String name, int count) {
    return 'Imported “$name”, with $count notes';
  }

  @override
  String tavernPresetImportFailed(String reason) {
    return 'Couldn\'t import: $reason';
  }

  @override
  String get tavernPresetNotText => 'This file isn\'t text';

  @override
  String get tavernPresetsEmpty => 'No presets yet';

  @override
  String get tavernPresetsEmptyMessage =>
      'Presets exported from SillyTavern as JSON, and dsh-preset-enhance share packages, can be imported.';

  @override
  String get tavernPresetEnvelope => 'Share package';

  @override
  String tavernPresetCount(int count) {
    return '$count';
  }

  @override
  String get tavernRegex => 'Regex';

  @override
  String get tavernRegexImport => 'Import regex';

  @override
  String get tavernRegexOn => 'On';

  @override
  String get tavernRegexOff => 'Off';

  @override
  String get tavernRegexEnable => 'Turn on';

  @override
  String get tavernRegexDisable => 'Turn off';

  @override
  String get tavernRegexExport => 'Export regex';

  @override
  String get tavernRegexDelete => 'Delete regex';

  @override
  String tavernRegexDeleteTitle(String name) {
    return 'Delete the regex “$name”?';
  }

  @override
  String tavernRegexImported(int count) {
    return 'Imported $count regex scripts';
  }

  @override
  String get tavernRegexIncompatible => 'Can\'t run here; skipped';

  @override
  String get tavernRegexEmpty => 'No global regex yet';

  @override
  String get tavernRegexEmptyMessage =>
      'Regex JSON exported from SillyTavern, one script or a list, can be imported. Global regex applies to every chat; the regex a card or preset brings goes with it.';

  @override
  String get tavernRegexUnnamed => 'Untitled';

  @override
  String tavernRegexCount(int count) {
    return '$count';
  }

  @override
  String get tavernLorebooks => 'Lorebooks';

  @override
  String get tavernLorebookImport => 'Import lorebook';

  @override
  String get tavernLorebookGlobal => 'Global';

  @override
  String get tavernLorebookBindGlobal => 'Use in every chat';

  @override
  String get tavernLorebookUnbindGlobal => 'Stop using in every chat';

  @override
  String get tavernLorebookExport => 'Export lorebook';

  @override
  String get tavernLorebookDelete => 'Delete lorebook';

  @override
  String tavernLorebookDeleteTitle(String name) {
    return 'Delete the lorebook “$name”?';
  }

  @override
  String get tavernLorebookDeleteMessage => 'Wherever it is bound, it is skipped. It can\'t be brought back.';

  @override
  String tavernLorebookImported(String name, int count) {
    return 'Imported “$name”, $count entries';
  }

  @override
  String get tavernLorebooksEmpty => 'No standalone lorebooks yet';

  @override
  String get tavernLorebooksEmptyMessage =>
      'Lorebook JSON exported from SillyTavern can be imported. Made global, it applies to every chat; a card\'s own lorebook goes with the card.';

  @override
  String tavernLorebookCount(int count) {
    return '$count';
  }

  @override
  String get tavernPresetEdit => 'Edit preset';

  @override
  String get tavernPresetParams => 'Numbers';

  @override
  String get tavernPresetPrompts => 'Prompts, in the order they\'re sent';

  @override
  String get tavernPresetMarker => 'Placeholder';

  @override
  String get tavernPresetPromptsEmpty => 'This preset sets no prompt order; SillyTavern\'s default order is used.';

  @override
  String get tavernReport => 'Import check';

  @override
  String get tavernVerdictUsable => 'Works';

  @override
  String get tavernVerdictPartial => 'Partly works';

  @override
  String get tavernVerdictPreserve => 'Kept, not run';

  @override
  String tavernReportChecked(String time) {
    return 'Checked $time';
  }

  @override
  String get tavernReportStale => 'Changed since this check';

  @override
  String get tavernReportRecheck => 'Check again';

  @override
  String get tavernReportNone => 'Not checked yet';

  @override
  String get tavernReportNoneMessage => 'This was imported before checks existed; check it now.';

  @override
  String get tavernReportCheckNow => 'Check now';

  @override
  String get tavernReportRender0 => 'Suggested display: native';

  @override
  String get tavernReportRender1 => 'Suggested display: a web view in the message';

  @override
  String get tavernReportRender2 => 'Suggested display: a whole-page canvas';

  @override
  String get tavernReportCounts => 'Contains';

  @override
  String get tavernReportFindings => 'Not run, or worth a look';

  @override
  String get tavernReportNoFindings => 'Nothing to look at';

  @override
  String get tavernPresetForChat => 'This chat\'s preset';

  @override
  String get tavernPresetFollow => 'Default';

  @override
  String tavernPresetFollowDefault(String name) {
    return 'Default ($name)';
  }

  @override
  String get tavernPresetPickerEmpty => 'Import presets in Library › Presets to give this chat another.';

  @override
  String get tavernSectionShelf => 'Shelf';

  @override
  String get tavernSectionChats => 'Chats';

  @override
  String get tavernSectionLibrary => 'Library';

  @override
  String get tavernSectionMe => 'Me';

  @override
  String get tavernNoChats => 'No chats yet';

  @override
  String get tavernNoChatsMessage => 'Open a character on the shelf to start your first chat.';

  @override
  String get tavernSettingsGeneration => 'Generation';

  @override
  String get tavernMaxContext => 'Context limit';

  @override
  String get tavernMaxReply => 'Reply limit';

  @override
  String get tavernTemperature => 'Temperature';

  @override
  String get tavernGenerationNote =>
      'A longer context remembers more and costs more each turn; numbers are tokens. This changes the default preset; a chat that brought its own preset keeps it.';

  @override
  String get tavernLayout => 'Layout';

  @override
  String get tavernLayoutBubble => 'Bubbles';

  @override
  String get tavernLayoutNovel => 'Novel';

  @override
  String get tavernYou => 'You';

  @override
  String get tavernSearchHint => 'Search characters, creators, tags';

  @override
  String get tavernAllTags => 'All';

  @override
  String get tavernNoMatch => 'No matching characters';

  @override
  String get tavernLayoutVisualNovel => 'Visual novel';

  @override
  String get tavernCharacterDetails => 'Character details';

  @override
  String get tavernChatLayout => 'Layout for this chat';

  @override
  String get tavernFollowSettings => 'Follow tavern settings';

  @override
  String get tavernLog => 'Backlog';

  @override
  String get tavernEditCharacter => 'Edit character';

  @override
  String get tavernNameNeeded => 'A name is needed';

  @override
  String get tavernFieldsBasics => 'Basics';

  @override
  String get tavernFieldNickname => 'Nickname';

  @override
  String get tavernFieldNicknameHelp => 'If set, chats call the character this';

  @override
  String get tavernFieldTags => 'Tags';

  @override
  String get tavernFieldTagsHelp => 'Separate with commas';

  @override
  String get tavernFieldCreator => 'Creator';

  @override
  String get tavernFieldVersion => 'Version';

  @override
  String get tavernFieldDescription => 'Description';

  @override
  String get tavernFieldPersonality => 'Personality';

  @override
  String get tavernFieldScenario => 'Scenario';

  @override
  String tavernGreetingNumber(int n) {
    return 'Greeting $n';
  }

  @override
  String get tavernFieldGreetingsNote => 'A new chat can start from any of these.';

  @override
  String get tavernAddGreeting => 'Add a greeting';

  @override
  String get tavernMoreFields => 'More fields';

  @override
  String get tavernMoreFieldsSubtitle => 'Example dialogue, system prompt, post-history instructions';

  @override
  String get tavernFieldExamples => 'Example dialogue';

  @override
  String get tavernFieldExamplesHelp => 'Start each example with a <START> line';

  @override
  String get tavernFieldPrompts => 'Prompts';

  @override
  String get tavernFieldPromptsNote =>
      'When set, these replace the matching part of the preset; leave empty to use the preset\'s.';

  @override
  String get tavernFieldSystemPrompt => 'System prompt';

  @override
  String get tavernFieldPostHistory => 'Post-history instructions';

  @override
  String get tavernFieldNotesNote => 'For people reading the card; not sent to the model.';

  @override
  String tavernEditKeeps(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'This card has $count more items you can\'t edit here (lorebook, extensions…). Saving keeps them as they are, and existing chats don\'t change.',
      one: 'This card has 1 more item you can\'t edit here (lorebook, extensions…). Saving keeps it as it is, and existing chats don\'t change.',
    );
    return '$_temp0';
  }

  @override
  String get tavernEditKeepsChats => 'Saving doesn\'t change existing chats.';

  @override
  String get tavernPersonas => 'Personas';

  @override
  String get tavernPersona => 'Persona';

  @override
  String get tavernPersonaNew => 'New persona';

  @override
  String get tavernPersonasEmpty => 'No personas yet';

  @override
  String get tavernPersonasEmptyMessage =>
      'A persona is who you play in chats: a name and a few lines, so characters know who you are.';

  @override
  String get tavernPersonasNote =>
      'Long-press to make one the default or delete it. Chats without their own persona use the default.';

  @override
  String get tavernPersonaUnsetDefault => 'Stop using as default';

  @override
  String get tavernPersonaSetDefault => 'Use as default';

  @override
  String tavernPersonaDeleteTitle(String name) {
    return 'Delete “$name”?';
  }

  @override
  String get tavernPersonaDeleteMessage =>
      'Chats that use it switch to the default persona; what\'s already written stays.';

  @override
  String get tavernPersonaEdit => 'Edit persona';

  @override
  String get tavernPersonaPickAvatar => 'Change picture';

  @override
  String get tavernPersonaRemoveAvatar => 'Remove picture';

  @override
  String get tavernPersonaAvatarFailed => 'Couldn\'t use that picture';

  @override
  String get tavernPersonaNameHint => 'What characters call you';

  @override
  String get tavernPersonaDescriptionHelp =>
      'The model reads this: who you are, what you\'re like, how you know the character.';

  @override
  String get tavernPersonaDescriptionHint => 'e.g. The town\'s new doctor: quiet, always carrying an old leather case.';

  @override
  String get tavernPersonaDefaultSubtitle => 'New chats, and chats without their own persona, use it';

  @override
  String get tavernPersonaDelete => 'Delete persona';

  @override
  String get tavernPersonaNone => 'No persona';

  @override
  String tavernPersonaAs(String name) {
    return 'As $name';
  }

  @override
  String get tavernPersonaForChat => 'In this chat you are';

  @override
  String get tavernPersonaFollowDefault => 'Use the default';

  @override
  String get tavernPersonasManage => 'Manage personas';

  @override
  String get tavernSettingsYou => 'You';

  @override
  String get tavernDefaultPersona => 'Default persona';

  @override
  String get tavernPersonaNotSet => 'Not set';

  @override
  String get tavernFieldName => 'Name';

  @override
  String get tavernOpenFailed => 'The tavern couldn\'t open';

  @override
  String get tavernOpenFailedMessage =>
      'The data for characters and chats couldn\'t be opened. Try again; if it still fails, restart the app.';

  @override
  String get tavernExportPng => 'Export card (PNG)';

  @override
  String get tavernExportPngSubtitle =>
      'The card rides inside the picture; SillyTavern and other taverns can import it';

  @override
  String get tavernExportJson => 'Export as JSON';

  @override
  String get tavernExportFailed => 'Couldn\'t export this card';

  @override
  String get tavernInspectTitle => 'What this turn sent';

  @override
  String get tavernInspectMenu => 'See what was sent';

  @override
  String get tavernInspectLatest => 'What the last turn sent';

  @override
  String get tavernInspectNone => 'Nothing recorded';

  @override
  String get tavernInspectNoneMessage =>
      'Greetings, messages from before the engine and sample replies have no record.';

  @override
  String get tavernInspectSummary => 'Summary';

  @override
  String get tavernInspectKind => 'Type';

  @override
  String get tavernTurnSend => 'Send';

  @override
  String get tavernTurnImpersonate => 'Write for me';

  @override
  String get tavernInspectStatus => 'Result';

  @override
  String get tavernInspectPreparing => 'Preparing';

  @override
  String get tavernInspectReady => 'Sent';

  @override
  String get tavernInspectCompleted => 'Done';

  @override
  String get tavernInspectFailed => 'Failed';

  @override
  String get tavernInspectPrompt => 'Prompt';

  @override
  String tavernTokens(int count) {
    return '$count tokens';
  }

  @override
  String tavernTokensAbout(int count) {
    return 'about $count tokens';
  }

  @override
  String get tavernInspectBudget => 'Context budget left';

  @override
  String get tavernInspectUsage => 'Usage the model reported';

  @override
  String get tavernInspectNoUsage => 'Not reported';

  @override
  String tavernInspectUsageValue(int prompt, int hit, int completion) {
    return 'In $prompt (cached $hit) · out $completion';
  }

  @override
  String get tavernInspectCost => 'Estimated cost';

  @override
  String get tavernInspectCostPeak => 'At DeepSeek\'s list prices, peak hours';

  @override
  String get tavernInspectCostOffPeak => 'At DeepSeek\'s list prices, off-peak (half price)';

  @override
  String tavernInspectSegments(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count parts sent', one: '1 part sent');
    return '$_temp0';
  }

  @override
  String get tavernInspectSegmentsNote => 'In the order sent. Tap for the full text; long-press to copy.';

  @override
  String tavernInspectWorld(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lorebook entries matched',
      one: '1 lorebook entry matched',
    );
    return '$_temp0';
  }

  @override
  String tavernInspectWorldKey(String key) {
    return 'key “$key”';
  }

  @override
  String tavernInspectExcluded(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count parts left out',
      one: '1 part left out',
    );
    return '$_temp0';
  }

  @override
  String get tavernExcludeDisabled => 'Turned off';

  @override
  String get tavernExcludeTrigger => 'Not for this kind of turn';

  @override
  String get tavernExcludeHidden => 'Hidden from the model';

  @override
  String get tavernExcludeSystem => 'System message';

  @override
  String get tavernExcludeHistoryBudget => 'Over the context budget';

  @override
  String get tavernExcludeExampleBudget => 'Examples over budget';

  @override
  String get tavernRoleSystem => 'System';

  @override
  String get tavernRoleUser => 'You';

  @override
  String get tavernRoleCharacter => 'Character';

  @override
  String get tavernSourcePreset => 'Preset';

  @override
  String get tavernSourceCard => 'Card';

  @override
  String get tavernSourceWorld => 'Lorebook';

  @override
  String get tavernSourcePersona => 'Persona';

  @override
  String get tavernSourceHistory => 'Chat';

  @override
  String get tavernSourceControl => 'Control';

  @override
  String get tavernWriteForMe => 'Write it for me';

  @override
  String get tavernHide => 'Hide from the model';

  @override
  String get tavernUnhide => 'Show to the model';

  @override
  String get tavernHiddenFromModel => 'The model can\'t see this';

  @override
  String get tavernTrySample => 'Try the sample card';

  @override
  String get tavernImportChats => 'Import chats';

  @override
  String get tavernImportChatsSubtitle => 'SillyTavern .jsonl files, one or several';

  @override
  String get tavernOnlyJsonl => 'Only .jsonl chat files can be imported';

  @override
  String tavernImportChatsFailed(String detail) {
    return 'Couldn\'t import: $detail';
  }

  @override
  String tavernImportedChats(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Imported $count chats',
      one: 'Imported 1 chat',
    );
    return '$_temp0';
  }

  @override
  String get tavernImportNoticesTitle => 'Notes from the import';

  @override
  String get tavernExportChat => 'Export chat';

  @override
  String get tavernExportChatFailed => 'Couldn\'t export this chat';

  @override
  String get tavernLorebook => 'Lorebook';

  @override
  String get tavernLorebookSubtitle => 'The entries this card carries';

  @override
  String tavernLorebookEntries(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count entries', one: '1 entry');
    return '$_temp0';
  }

  @override
  String get tavernLorebookNote =>
      'When a key comes up in the chat, its entry goes into the prompt; \'Always\' entries go in every time.';

  @override
  String tavernLorebookKeys(String keys) {
    return 'Keys: $keys';
  }

  @override
  String get tavernLorebookConstant => 'Always';

  @override
  String get tavernLorebookOff => 'Off';

  @override
  String get tavernLorebookEmpty => 'This card has no lorebook';

  @override
  String get tavernImportFromFile => 'From a file';

  @override
  String get tavernImportFromFileSubtitle =>
      'Cards, presets, lorebooks, regex, quick replies or chats, told apart for you';

  @override
  String get tavernImportFromLink => 'From a link';

  @override
  String get tavernImportFromLinkSubtitle => 'A character page on Chub or RisuRealm, or a direct link to the card file';

  @override
  String get tavernLinkInvalid => 'That isn\'t a web address';

  @override
  String get tavernLinkFailed => 'Couldn\'t download it; check the connection or the link';

  @override
  String tavernLinkStatus(int status) {
    return 'Couldn\'t download it (HTTP $status)';
  }

  @override
  String get tavernLinkIsPage =>
      'That\'s a web page, not a card file. Character pages on Chub and RisuRealm work as they are; elsewhere, find the download link to the .png or .json and try that.';

  @override
  String get tavernLinkSiteMissing => 'The site has no such character; it may be deleted or private';

  @override
  String get tavernQuickReplies => 'Quick replies';

  @override
  String get tavernQuickRepliesEmpty => 'No quick replies yet';

  @override
  String get tavernQuickRepliesNote =>
      'They sit above the input in every chat: tap to send, long-press to put it in the box first.';

  @override
  String get tavernQuickReplyAdd => 'Add one';

  @override
  String get tavernQuickReplyHint => 'e.g. *looks around for anyone else*';

  @override
  String tavernQuickReplyCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count lines', one: '1 line');
    return '$_temp0';
  }

  @override
  String get tavernEditMessage => 'Edit message';

  @override
  String get tavernBackground => 'Background picture';

  @override
  String get tavernBackgroundNone => 'None';

  @override
  String get tavernBackgroundChange => 'Change';

  @override
  String get tavernBackgroundRemove => 'Remove the picture';

  @override
  String get tavernDice => 'Roll dice';

  @override
  String get tavernDiceCount => 'Dice';

  @override
  String get tavernDiceModifier => 'Modifier';

  @override
  String get tavernDiceFewer => 'One die fewer';

  @override
  String get tavernDiceMore => 'One more die';

  @override
  String get tavernDiceModifierDown => 'Modifier −1';

  @override
  String get tavernDiceModifierUp => 'Modifier +1';

  @override
  String get tavernDiceRoll => 'Roll';

  @override
  String get tavernDiceAgain => 'Roll again';

  @override
  String get tavernDiceUse => 'Put it in the box';

  @override
  String tavernDiceLine(String notation, int total, String working) {
    return '🎲 $notation rolled $total$working';
  }

  @override
  String tavernDiceWorking(String working) {
    return ' ($working)';
  }

  @override
  String get tavernStorybook => 'Storybook';

  @override
  String get tavernStorybookMenu => 'Export as a storybook';

  @override
  String get tavernStorybookTitle => 'Title';

  @override
  String tavernStorybookDefaultTitle(String name) {
    return 'A story with $name';
  }

  @override
  String tavernStorybookByline(String character, String you) {
    return '$character and $you';
  }

  @override
  String get tavernStorybookWhole => 'The whole story';

  @override
  String tavernStorybookWholeNote(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count lines', one: '1 line');
    return '$_temp0; hidden messages are left out. The EPUB opens in Apple Books and most reading apps.';
  }

  @override
  String get tavernStorybookEpub => 'E-book (EPUB)';

  @override
  String get tavernStorybookText => 'Plain text (TXT)';

  @override
  String get tavernStorybookImage => 'Long image';

  @override
  String get tavernStorybookLatest => 'The latest';

  @override
  String tavernStorybookLines(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count lines', one: '1 line');
    return '$_temp0';
  }

  @override
  String get tavernStorybookSave => 'Save to photos';

  @override
  String get tavernStorybookShare => 'Share the image';

  @override
  String tavernStorybookEarlier(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count earlier lines are',
      one: '1 earlier line is',
    );
    return '$_temp0 left out of the image; export the e-book for all of it.';
  }

  @override
  String tavernStorybookEarlierShort(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count lines', one: '1 line');
    return '… $_temp0 before this …';
  }

  @override
  String get tavernStorybookMadeWith => 'Written in the DSH Go tavern';

  @override
  String get tavernStorybookContents => 'Contents';

  @override
  String tavernStorybookChapter(int n) {
    return 'Chapter $n';
  }

  @override
  String get tavernStorybookSaved => 'Saved to photos';

  @override
  String get tavernStorybookFailed => 'Couldn’t export it; try again';

  @override
  String get tavernLive2d => 'Live2D model';

  @override
  String get tavernLive2dSubtitle => 'Stands in for the card picture in the visual novel layout, moving as she talks';

  @override
  String get tavernLive2dNone => 'None';

  @override
  String get tavernLive2dSet => 'Imported';

  @override
  String get tavernLive2dImported => 'Imported. Switch the chat to the visual novel layout to see her.';

  @override
  String get tavernLive2dReplace => 'Replace it';

  @override
  String get tavernLive2dRemove => 'Remove the model';

  @override
  String get tavernLive2dNoRuntime =>
      'There’s no Live2D runtime on this phone yet: set one up in the companion room first, or import a whole pack.';

  @override
  String get tavernTextSize => 'Text size';

  @override
  String get tavernTextSmall => 'S';

  @override
  String get tavernTextMedium => 'M';

  @override
  String get tavernTextLarge => 'L';

  @override
  String get tavernTextHuge => 'XL';

  @override
  String get tavernLineHeight => 'Line spacing';

  @override
  String get tavernLineTight => 'Tight';

  @override
  String get tavernLineNormal => 'Normal';

  @override
  String get tavernLineLoose => 'Loose';

  @override
  String get tavernReadingSample =>
      '*She pushes a clay cup across to you; the firelight jumps in her eyes.*\n\n\"Still on the road this late? The snow won\'t stop tonight. If you\'re travelling, wait for daylight.\"';

  @override
  String get tavernPalette => 'Colours';

  @override
  String get tavernPalettePlain => 'Plain';

  @override
  String get tavernPaletteEmber => 'Warm';

  @override
  String get tavernPaletteOcean => 'Cool';

  @override
  String get tavernPaletteRose => 'Rose';

  @override
  String get tavernTextSpeed => 'Text speed';

  @override
  String get tavernTextSlow => 'Slow';

  @override
  String get tavernTextNormal => 'Medium';

  @override
  String get tavernTextFast => 'Fast';

  @override
  String get tavernTextInstant => 'Instant';

  @override
  String get tavernVnAuto => 'Auto';

  @override
  String get tavernVnSkip => 'Skip';

  @override
  String get tavernStage => 'Stage';

  @override
  String get tavernStageSession => 'This chat';

  @override
  String get tavernSessionUsing => 'In use';

  @override
  String get tavernSessionLook => 'Look';

  @override
  String get tavernSessionMore => 'More';

  @override
  String get tavernAudio => 'Music and sound';

  @override
  String get tavernAudioBgm => 'Music';

  @override
  String get tavernAudioAmbient => 'Sound effects';

  @override
  String get tavernAudioNothing => 'Not playing';

  @override
  String get tavernAudioPlay => 'Play';

  @override
  String get tavernAudioPause => 'Pause';

  @override
  String get tavernAudioMode => 'Play mode';

  @override
  String get tavernAudioModeOne => 'One';

  @override
  String get tavernAudioModeAll => 'All';

  @override
  String get tavernAudioModeShuffle => 'Shuffle';

  @override
  String get tavernAudioModeOnce => 'Once';

  @override
  String get tavernAudioVolume => 'Volume';

  @override
  String get tavernAudioAllow => 'Let the card play';

  @override
  String get tavernAudioAdd => 'Add background music';

  @override
  String get tavernAudioAddTitle => 'Link to the music';

  @override
  String get tavernAudioAddNote =>
      'The web address of an audio file (mp3, ogg…). It joins this chat\'s music list, with the card\'s own.';

  @override
  String get tavernAudioAddConfirm => 'Add';

  @override
  String get tavernAudioAddInvalid => 'Starts with http:// or https://';

  @override
  String get tavernStageState => 'State';

  @override
  String get tavernStageDirector => 'Director';

  @override
  String get tavernStageTurn => 'This turn';

  @override
  String get tavernStageStateEmpty => 'This card keeps no state yet';

  @override
  String get tavernStageStateNote =>
      'Once a card defines its state, relations, numbers, belongings and the time and place show here, each turn\'s changes marked (\"+5\"), and you can change them yourself. An older card without one lists its variables here.';

  @override
  String get tavernStageDirectorEmpty => 'No director yet';

  @override
  String get tavernStageDirectorNote =>
      'With the director on, it reads the story in the background after each turn: it leaves the next turn an unseen hint, keeps its own notes (hidden by default, they may spoil), and puts three suggested replies over the box. It never speaks for you or writes the story.';

  @override
  String get tavernStageTurnNone => 'No turn to look at yet';

  @override
  String get tavernStageTokensIn => 'Prompt';

  @override
  String get tavernStageCache => 'Cache hit';

  @override
  String get tavernStageTokensOut => 'Reply';

  @override
  String get tavernStageWorld => 'Lorebook entries this turn';

  @override
  String get tavernStageWorldNone => 'No entry came up this turn';

  @override
  String get tavernStageInspect => 'See the whole inspection';

  @override
  String get tavernLorebookNone => 'None';

  @override
  String get tavernLorebooksBound => 'Bound lorebooks';

  @override
  String get tavernLorebooksBoundCharacter => 'Used in every chat with this character';

  @override
  String get tavernLorebooksBoundPersona => 'Used in every chat where you\'re this persona';

  @override
  String get tavernLorebookForChat => 'Lorebooks for this chat';

  @override
  String tavernLorebookForCharacter(String name) {
    return 'Lorebooks for $name';
  }

  @override
  String tavernLorebookForPersona(String name) {
    return 'Lorebooks as $name';
  }

  @override
  String get tavernLorebookChatNote => 'Used only in this chat. The ones marked Global are on in every chat anyway.';

  @override
  String get tavernLorebookCharacterNote =>
      'Every chat with this character uses these, along with the card\'s own lorebook.';

  @override
  String get tavernLorebookPersonaNote => 'Every chat where you\'re this persona uses these.';

  @override
  String get tavernLorebookPickEmpty => 'No lorebooks in the library yet';

  @override
  String get tavernLorebookOpenLibrary => 'Import one in the library';

  @override
  String get tavernLorebookMissing => 'A deleted lorebook';

  @override
  String get tavernLorebookMissingSubtitle => 'Still bound and skipped when replying; turn off to unbind';

  @override
  String get tavernPresetOrder => 'Reorder';

  @override
  String get tavernPresetOrderNote =>
      'Drag by the handle on the right. Prompts go to the model in this order; the ones switched off keep their place.';

  @override
  String get tavernPresetPromptOff => 'Off';

  @override
  String get tavernPrefill => 'Prefill';

  @override
  String get tavernPrefillOn => 'Start the reply with this';

  @override
  String get tavernPrefillOnSubtitle => 'The model writes on from it';

  @override
  String get tavernPrefillText => 'Opening text';

  @override
  String get tavernPrefillTextEmpty => 'Not written yet';

  @override
  String get tavernPrefillTarget => 'Goes in';

  @override
  String get tavernPrefillContent => 'Reply';

  @override
  String get tavernPrefillReasoning => 'Thinking';

  @override
  String get tavernPrefillNote =>
      'When on, this goes to the model as the start of the reply, and it writes on from there. In Thinking it applies only with thinking on; otherwise it goes in the reply. Continuing a reply doesn\'t use it.';

  @override
  String get tavernPresetPromptEmpty => 'Empty';

  @override
  String tavernThinkingSeconds(int seconds) {
    return '${seconds}s';
  }

  @override
  String tavernDeletedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Deleted $count messages',
      one: 'Deleted 1 message',
    );
    return '$_temp0';
  }

  @override
  String get tavernDeleteFromUndoable =>
      'From this one to the latest, with their alternatives and branches. You can undo for a few seconds after.';

  @override
  String get tavernUndoFailed => 'Couldn\'t undo';

  @override
  String get tavernShowUsage => 'Show usage and cost under each reply';

  @override
  String get tavernShowUsageSubtitle =>
      'Input and output tokens as the model reports them; for DeepSeek models, a cost at their list prices, peak and off-peak hours apart';

  @override
  String tavernUsageLine(int input, int output) {
    final intl.NumberFormat inputNumberFormat = intl.NumberFormat.decimalPattern(localeName);
    final String inputString = inputNumberFormat.format(input);
    final intl.NumberFormat outputNumberFormat = intl.NumberFormat.decimalPattern(localeName);
    final String outputString = outputNumberFormat.format(output);

    return 'In $inputString · out $outputString';
  }

  @override
  String tavernUsageLineCached(int input, int cached, int output) {
    final intl.NumberFormat inputNumberFormat = intl.NumberFormat.decimalPattern(localeName);
    final String inputString = inputNumberFormat.format(input);
    final intl.NumberFormat cachedNumberFormat = intl.NumberFormat.decimalPattern(localeName);
    final String cachedString = cachedNumberFormat.format(cached);
    final intl.NumberFormat outputNumberFormat = intl.NumberFormat.decimalPattern(localeName);
    final String outputString = outputNumberFormat.format(output);

    return 'In $inputString ($cachedString cached) · out $outputString';
  }

  @override
  String tavernUsageCost(String usd) {
    return 'about $usd';
  }

  @override
  String tavernUsageCostUnder(String usd) {
    return 'under $usd';
  }

  @override
  String get tavernCostAlert => 'Per-turn cost reminder';

  @override
  String get tavernCostAlertSubtitle =>
      'When a turn costs more than this at DeepSeek\'s list prices, say so over the composer; other models aren\'t estimated';

  @override
  String get tavernCostAlertOff => 'Off';

  @override
  String tavernCostAlertNotice(String cost, String line) {
    return 'This turn cost $cost, over your reminder line of $line';
  }

  @override
  String get tavernSearchChat => 'Search this chat';

  @override
  String get tavernSearchChatHint => 'A line, a word';

  @override
  String get tavernSearchChatIdle =>
      'Searches every branch of this chat, hidden messages too, but not the thinking. Tap a hit to read it whole.';

  @override
  String tavernSearchChatNone(String query) {
    return 'Nothing found for “$query”';
  }

  @override
  String tavernSearchChatFound(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count found, newest first',
      one: '1 found',
    );
    return '$_temp0';
  }

  @override
  String get tavernDeleteOne => 'Delete just this one';

  @override
  String get tavernDeleteOneTitle => 'Delete just this message?';

  @override
  String get tavernDeleteOneMessage =>
      'The messages after it stay, joined to the one before it. This can\'t be undone.';

  @override
  String get tavernLorebookAdd => 'Add an entry';

  @override
  String get tavernLorebookStart =>
      'This card has no lorebook of its own. Add an entry: when a chat mentions one of its keys, its text goes into the prompt.';

  @override
  String get tavernLorebookEntryNew => 'New entry';

  @override
  String get tavernLorebookEntryEdit => 'Edit entry';

  @override
  String get tavernLorebookFieldName => 'Entry name';

  @override
  String get tavernLorebookFieldNameHelp => 'Only for you, to find it by; not sent to the model.';

  @override
  String get tavernLorebookFieldKeys => 'Keys';

  @override
  String get tavernLorebookFieldKeysHelp =>
      'When a chat mentions any of these, the text goes into the prompt. Separate with commas.';

  @override
  String get tavernLorebookFieldSecondary => 'Secondary keys';

  @override
  String get tavernLorebookFieldSecondaryHelp => 'If filled, the entry is also checked against them as set below.';

  @override
  String get tavernLorebookFieldContent => 'Text';

  @override
  String get tavernLorebookFieldConstantSubtitle => 'Always included, keys or not';

  @override
  String get tavernLorebookFieldEnabled => 'On';

  @override
  String get tavernLorebookFieldPosition => 'Goes';

  @override
  String get tavernLorebookBeforeChar => 'Before the character';

  @override
  String get tavernLorebookAfterChar => 'After the character';

  @override
  String get tavernLorebookFieldOrder => 'Order';

  @override
  String get tavernLorebookFieldOrderHelp => 'Higher numbers come first, and go in first.';

  @override
  String get tavernLorebookEntryDelete => 'Delete this entry';

  @override
  String tavernLorebookEntryDeleteTitle(String name) {
    return 'Delete the entry “$name”?';
  }

  @override
  String get tavernLorebookEntryDeleteMessage => 'It goes from the card for good.';

  @override
  String get tavernNarrator => 'Narrator';

  @override
  String get tavernSendOptions => 'Other ways to send';

  @override
  String get tavernSendOnly => 'Send without a reply';

  @override
  String get tavernSendOnlySubtitle => 'It goes into the story; no one answers yet';

  @override
  String get tavernNarrate => 'Send as narration';

  @override
  String get tavernNarrateSubtitle => 'It goes into the story as narration, not as your line';

  @override
  String get tavernSendFailed => 'Couldn\'t send';

  @override
  String get tavernStateVariables => 'Variables';

  @override
  String get tavernStateVariablesNote =>
      'What macros like {{setvar}} saved in the card and this chat, as of the current message. Tap one to see it whole or change it.';

  @override
  String get tavernData => 'Data';

  @override
  String get tavernBackup => 'Back up the whole tavern';

  @override
  String get tavernBackupSubtitle => 'Cards, chats, presets, lorebooks, personas and settings, in one zip';

  @override
  String get tavernBackingUp => 'Backing up…';

  @override
  String tavernBackedUp(int count, String size) {
    return 'Backed up: $count files, $size';
  }

  @override
  String tavernBackupFailed(String error) {
    return 'Couldn\'t back up: $error';
  }

  @override
  String get tavernRestore => 'Restore from a backup';

  @override
  String get tavernRestoreSubtitle => 'Replace this tavern with a backup';

  @override
  String get tavernRestoreTitle => 'Replace this tavern with this backup?';

  @override
  String get tavernRestoreMessage =>
      'The cards, chats, presets and settings here are all replaced by the backup\'s. To keep what is here, back it up first. A wrong or damaged backup changes nothing.';

  @override
  String get tavernRestoreAction => 'Restore';

  @override
  String get tavernRestoring => 'Restoring…';

  @override
  String tavernRestored(int count) {
    return 'Restored: $count files';
  }

  @override
  String tavernRestoreFailed(String error) {
    return 'Couldn\'t restore; nothing here changed: $error';
  }

  @override
  String get tavernLoreTest => 'Try it';

  @override
  String get tavernLoreTestTitle => 'Try the lorebook';

  @override
  String get tavernLoreTestInput => 'Say something';

  @override
  String get tavernLoreTestHint => 'A line you\'d expect to bring an entry in';

  @override
  String get tavernLoreTestNote =>
      'Only this line, plus the always-on entries; earlier messages, sticky and cooldown don\'t count. No model is called.';

  @override
  String tavernLoreTestHits(int count) {
    return 'Goes into the prompt ($count)';
  }

  @override
  String get tavernLoreTestNone => 'This line brings in no entry.';

  @override
  String get tavernLoreTestOverflow => 'Over the lorebook budget; the later entries were left out.';

  @override
  String tavernLoreTestFailed(String error) {
    return 'Couldn\'t try it: $error';
  }

  @override
  String tavernLoreReasonKeys(String keys) {
    return 'Keyword $keys';
  }

  @override
  String get tavernLoreReasonSticky => 'Sticky, still on';

  @override
  String get tavernLoreReasonDecorator => 'Decorator';

  @override
  String tavernLoreAtDepth(int depth) {
    return 'At depth $depth';
  }

  @override
  String get tavernLoreNearNote => 'By the author\'s note';

  @override
  String get tavernLoreNearExamples => 'By the example dialogue';

  @override
  String get tavernLoreOutlet => 'Outlet';

  @override
  String tavernLoreOrder(String order) {
    return 'Order $order';
  }

  @override
  String get tavernBranches => 'Branches';

  @override
  String get tavernBranchesNote =>
      'Each row is a stretch with no fork. An indented row is another way out of the end of the row above. Tap a row to switch to it or name it; one the story is not on can also be deleted.';

  @override
  String get tavernBranchesEmpty => 'No messages in this chat yet.';

  @override
  String tavernBranchCount(int count) {
    return '$count messages';
  }

  @override
  String tavernBranchUntil(String text) {
    return 'to “$text”';
  }

  @override
  String get tavernBranchCurrent => 'Current';

  @override
  String get tavernBranchSwitch => 'Switch to this branch';

  @override
  String get tavernBranchSwitchSubtitle => 'Carries on where it last left off';

  @override
  String get tavernBranchName => 'Name this branch';

  @override
  String get tavernBranchRename => 'Rename';

  @override
  String get tavernBranchNameHint => 'e.g. The cellar route';

  @override
  String get tavernBranchNameCaption => 'Only for you, to find it again; leave empty to remove it.';

  @override
  String get tavernBranchSwitched => 'Switched to this branch';

  @override
  String tavernBranchFailed(String error) {
    return 'Couldn\'t do that: $error';
  }

  @override
  String get tavernCardTheme => 'Use the card\'s own look';

  @override
  String get tavernCardThemeSubtitle =>
      'The accent, name colours, layout and background a card sets; off, this page decides';

  @override
  String get tavernShelfSort => 'Sort';

  @override
  String get tavernShelfOrderRecent => 'Recently played';

  @override
  String get tavernShelfOrderName => 'Name';

  @override
  String get tavernShelfOrderImported => 'Recently imported';

  @override
  String get tavernFavorite => 'Favorite';

  @override
  String get tavernUnfavorite => 'Remove from favorites';

  @override
  String get tavernFavorited => 'Favorite';

  @override
  String get tavernChatSearchHint => 'Search chats: who, title, last line';

  @override
  String get tavernNoChatMatch => 'No matching chats';

  @override
  String get tavernCharacterTabChats => 'Chats';

  @override
  String get tavernCharacterTabCard => 'Card';

  @override
  String get tavernCharacterTabSetup => 'Setup';

  @override
  String get tavernCharacterNoDefinition => 'This card has no definition or notes.';

  @override
  String get tavernNovelIndent => 'Indent paragraphs in 小说';

  @override
  String get tavernNovelIndentSubtitle => 'Each paragraph opens two characters in, as in a book';

  @override
  String get tavernShelfSelect => 'Select';

  @override
  String tavernShelfPicked(int count) {
    return '$count selected';
  }

  @override
  String get tavernShelfExport => 'Export the selected cards';

  @override
  String tavernDeleteCharactersTitle(int count) {
    return 'Delete these $count characters?';
  }

  @override
  String get tavernQuickRepliesAll => 'All';

  @override
  String get tavernQuickRepliesManage => 'Manage quick replies';

  @override
  String tavernSpeakNext(String name) {
    return 'Let $name go on';
  }

  @override
  String get tavernSettingsConnection => 'Model & connection';

  @override
  String get tavernDefaultPreset => 'Default preset';

  @override
  String get tavernDefaultPresetPick => 'The preset new chats use';

  @override
  String tavernGenerationInPreset(String name) {
    return 'Change $name\'s settings';
  }

  @override
  String tavernGenerationPresetNote(String name) {
    return 'New chats use $name: change context, reply length and temperature in that preset. A chat with a preset of its own keeps to it.';
  }

  @override
  String get tavernStorage => 'Storage';

  @override
  String get tavernStorageCounting => 'Counting…';

  @override
  String get tavernStorageCharacters => 'Character cards';

  @override
  String get tavernStorageChats => 'Chats, presets and personas';

  @override
  String get tavernStorageLive2d => 'Live2D figures';

  @override
  String get tavernStorageOther => 'Backgrounds, lorebooks, regex and settings';

  @override
  String get tavernStorageNote =>
      'All of it lives on this device only; before you change phones or uninstall, back up the whole tavern.';

  @override
  String get tavernDefaultPresetEmpty => 'Import presets in Library › Presets to pick another.';

  @override
  String tavernQuickRepliesAdded(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Added $count quick replies',
      one: 'Added 1 quick reply',
    );
    return '$_temp0';
  }

  @override
  String tavernQuickRepliesAddedSkipped(int count, int skipped) {
    return 'Added $count quick replies; $skipped were ST slash commands and left out';
  }

  @override
  String get tavernImportChatNoName => 'This chat doesn\'t say whose it is; import it from the character\'s page';

  @override
  String tavernImportChatNoCharacter(String name) {
    return 'No single “$name” on the shelf; import this chat from the character\'s page';
  }

  @override
  String tavernImportedChatsTo(int count, String name) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Imported $count chats to “$name”',
      one: 'Imported 1 chat to “$name”',
    );
    return '$_temp0';
  }

  @override
  String tavernImportUnknown(String name) {
    return 'Can\'t tell what $name is';
  }

  @override
  String tavernImportFileFailed(String name, String reason) {
    return 'Couldn\'t import $name: $reason';
  }

  @override
  String get tavernIslands => 'Web pages in messages';

  @override
  String get tavernIslandsSubtitle =>
      'HTML and styles a card writes in its messages (status bars, panels) show in a web page of their own; off, as text';

  @override
  String get tavernSettingsSafety => 'Safety';

  @override
  String get tavernIslandNoScripts => 'No card scripts in those pages';

  @override
  String get tavernIslandNoScriptsSubtitle =>
      'The card\'s own JavaScript doesn\'t run; status bars that need it stay still';

  @override
  String get tavernIslandOffline => 'Keep those pages offline';

  @override
  String get tavernIslandOfflineSubtitle =>
      'Only pictures and fonts inside the card; nothing is loaded from the internet';

  @override
  String get tavernSessionUsage => 'This chat\'s usage';

  @override
  String tavernSessionUsageNote(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count replies on the current line',
      one: '1 reply on the current line',
    );
    return '$_temp0, added up; replaced alternatives aren\'t counted';
  }

  @override
  String get tavernSessionUsageNone => 'The model hasn\'t reported any usage yet';

  @override
  String tavernSessionUsageCost(String usd) {
    return 'About $usd at DeepSeek\'s list prices, peak and off-peak hours apart; China\'s public holidays are off-peak all day, so those days come out a little high here';
  }

  @override
  String tavernSessionUsageUnpriced(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count replies used a model not on the price list and aren\'t in the cost',
      one: '1 reply used a model not on the price list and isn\'t in the cost',
    );
    return '$_temp0';
  }

  @override
  String get tavernComposerNoKey => 'Add a key to begin';

  @override
  String get tavernWriteOwn => 'Write your own character';

  @override
  String get tavernWriteOwnSubtitle => 'Start from a blank card and fill in the name, setting and greeting';

  @override
  String get tavernNewCharacterName => 'New character';

  @override
  String get tavernSearchGoTo => 'Go to it in the chat';

  @override
  String get tavernBookmarks => 'Bookmarks';

  @override
  String get tavernBookmarkAdd => 'Bookmark';

  @override
  String get tavernBookmarkRemove => 'Remove bookmark';

  @override
  String get tavernBookmarkAdded => 'Bookmarked; find it in Stage › This chat › Bookmarks';

  @override
  String get tavernBookmarkRemoved => 'Bookmark removed';

  @override
  String get tavernBookmarksEmpty => 'No bookmarks yet';

  @override
  String get tavernBookmarksEmptyMessage => 'Long-press a message and choose Bookmark';

  @override
  String get tavernBookmarkGone => 'That line is gone; its bookmark was removed';

  @override
  String get tavernUsageStats => 'Usage';

  @override
  String get tavernUsageStatsSubtitle => 'How many tokens each chat has taken, and about what it cost';

  @override
  String get tavernUsageAllNote =>
      'Replies on every chat\'s current line, added up; replaced alternatives aren\'t counted';

  @override
  String tavernUsageChatReplies(int count, String completion) {
    return '$count replies · $completion out';
  }

  @override
  String get tavernSlashNoReply => 'There\'s no reply to do that to yet';

  @override
  String get tavernRegexTest => 'Try it';

  @override
  String get tavernRegexTestFind => 'Find';

  @override
  String get tavernRegexTestReplace => 'Replace with';

  @override
  String get tavernRegexTestInput => 'Some text';

  @override
  String get tavernRegexTestHint => 'Paste a reply to try it on';

  @override
  String get tavernRegexTestNote =>
      'Only this rule, on this device, with no model call; it runs here whatever it applies to and whether or not it is on.';

  @override
  String get tavernRegexTestMacros => 'Macros like {{char}} are not filled in here; they are taken as written.';

  @override
  String get tavernRegexTestNone => 'No match; the text stays as it is';

  @override
  String tavernRegexTestResult(int count) {
    return 'After ($count replaced)';
  }

  @override
  String tavernRegexTestFailed(String reason) {
    return 'Could not try it: $reason';
  }

  @override
  String get tavernStateNote =>
      'The card\'s own state, as of the current message. What changed this turn is marked (like +5); tap one to see it whole or change it. A change is kept on this message, so swiping or switching branches takes it back with the rest.';

  @override
  String get tavernStatePreview => 'Nothing is saved yet; these are the card\'s starting values.';

  @override
  String get tavernStateChanged => 'changed';

  @override
  String get tavernStateHidden => 'Spoiler · tap to see';

  @override
  String get tavernStateWhole => 'All of it';

  @override
  String get tavernStateEdit => 'Change';

  @override
  String get tavernStateEditText => 'The text is kept as written';

  @override
  String get tavernStateEditJson => 'Write JSON: a number, true / false, \"quoted text\", […], {…}';

  @override
  String get tavernStateEditBad => 'That is not valid JSON; nothing changed';

  @override
  String get tavernStateEditSaved => 'Changed';

  @override
  String get tavernStateEditSame => 'It was already that';

  @override
  String tavernStateEditRefused(String reason) {
    return 'Not changed: $reason';
  }

  @override
  String get tavernDirectorAuto => 'Director runs on its own';

  @override
  String get tavernDirectorAutoNote =>
      'For this chat only. Every few turns, after a reply, the model is asked once more: where the next beat goes, and three things you might do. Each time uses a little more.';

  @override
  String get tavernDirectorRun => 'Ask the director now';

  @override
  String get tavernDirectorRunning => 'The director is thinking…';

  @override
  String get tavernDirectorBeat => 'The next beat';

  @override
  String get tavernDirectorSuggestions => 'You might…';

  @override
  String get tavernDirectorSuggestionsNote => 'Tap one to put it in the box; changing and sending it is up to you.';

  @override
  String get tavernDirectorNotes => 'The director\'s notes';

  @override
  String get tavernDirectorStale =>
      'This was thought out for an earlier moment and may not fit now; it is kept to read.';

  @override
  String tavernDirectorFailed(String reason) {
    return 'The last try did not work: $reason';
  }

  @override
  String tavernDirectorRunFailed(String reason) {
    return 'Could not do that: $reason';
  }

  @override
  String get tavernBranchHere => 'Branch from here';

  @override
  String get tavernBranchedHere => 'Back to this message; what came after is kept in Branches';

  @override
  String get tavernBranchHereFailed => 'Could not go back to this message';

  @override
  String tavernStateItems(int count) {
    return '$count items';
  }

  @override
  String get tavernStateSearch => 'Search the values';

  @override
  String get tavernStateNoMatch => 'Nothing matches';

  @override
  String get tavernRuns => 'Background log';

  @override
  String get tavernRunsNote =>
      'Every change to the state by you, the model or the card\'s rules, and every run of the director, card events and the story; newest first, up to 100. Tap one for the raw record.';

  @override
  String get tavernRunsEmpty => 'Nothing yet';

  @override
  String get tavernRunsEmptyMessage => 'Changes to the state and director runs show up here.';

  @override
  String get tavernRunUser => 'You';

  @override
  String get tavernRunModel => 'The model';

  @override
  String get tavernRunRules => 'Card rules';

  @override
  String get tavernRunStopped => 'Turn cut off';

  @override
  String get tavernRunDirector => 'Director';

  @override
  String get tavernRunDirectorFailed => 'Director failed';

  @override
  String get tavernRunEvent => 'Card event';

  @override
  String get tavernRunStory => 'Story';

  @override
  String get tavernRunSecret => 'Secret';

  @override
  String get tavernRunNotKept => 'Not kept';

  @override
  String get tavernRunGone => 'Its message is gone';

  @override
  String tavernRunMore(int count) {
    return 'and $count more';
  }

  @override
  String get tavernInspectCache => 'Cache';

  @override
  String get tavernInspectCacheKept => 'Same start as the last turn';

  @override
  String tavernInspectCacheBroken(int index) {
    return 'Changed from part $index';
  }

  @override
  String tavernInspectCacheMiss(int tokens) {
    return 'This part and about $tokens tokens after it miss the cache; the parts before match the last turn. Usually a lorebook entry near the top changed this turn.';
  }

  @override
  String get tavernInspectCacheBreak => 'The cache breaks here';

  @override
  String get tavernPaletteSt => 'ST';

  @override
  String tavernStTheme(String name) {
    return 'ST theme: $name';
  }

  @override
  String get tavernStThemeNote =>
      'With 「ST」 as the colours, quotes and *actions* take its colours; one too faint to read here is adjusted until it reads.';

  @override
  String get tavernStThemeImport => 'Import an ST theme';

  @override
  String get tavernStThemeImportNote =>
      'Takes the quote and italics colours, and its custom CSS, from a theme file exported from SillyTavern.';

  @override
  String get tavernStThemeCss => 'Use its custom CSS';

  @override
  String get tavernStThemeCssSubtitle =>
      'With 「ST」 as the colours, it goes into the whole-story canvas and overrides the default look, as in ST. Turn it off if the page comes apart; the colours stay.';

  @override
  String get tavernStThemeRemove => 'Remove';

  @override
  String tavernStThemeImported(String name) {
    return 'Now using the colours of the ST theme “$name”';
  }

  @override
  String tavernStThemeNoColors(String name) {
    return '“$name” has no quote or italics colour or custom CSS to use';
  }

  @override
  String get tavernPromptContent => 'Content';

  @override
  String get tavernPromptRole => 'Spoken as';

  @override
  String get tavernPromptRoleSystem => 'System';

  @override
  String get tavernPromptRoleUser => 'User';

  @override
  String get tavernPromptRoleAssistant => 'Assistant';

  @override
  String get tavernPromptPosition => 'Position';

  @override
  String get tavernPromptRelative => 'In order';

  @override
  String get tavernPromptInChat => 'In chat';

  @override
  String get tavernPromptDepth => 'Depth';

  @override
  String tavernPromptDepthNote(int depth) {
    return 'Goes into the chat history, $depth messages up from the end (0 is the very end), as ST\'s In-Chat does.';
  }

  @override
  String get tavernPromptRelativeNote => 'Sent where the preset\'s order puts it, as ST\'s Relative does.';

  @override
  String tavernPromptPlace(int depth) {
    return 'In chat · depth $depth';
  }

  @override
  String get tavernPromptOrder => 'Order at this depth';

  @override
  String get tavernPromptOrderNote => 'When several sit at one depth, the smaller number comes first (100 by default).';

  @override
  String get tavernPromptForbid => 'Keep the card from replacing it';

  @override
  String get tavernPromptForbidMain => 'A card\'s own system prompt won\'t replace this one.';

  @override
  String get tavernPromptForbidJailbreak => 'A card\'s own post-history instructions won\'t replace this one.';

  @override
  String get tavernLoreCommon => 'Common';

  @override
  String get tavernLoreMore => 'More';

  @override
  String get tavernLorePosAnTop => 'Before author\'s note';

  @override
  String get tavernLorePosAnBottom => 'After author\'s note';

  @override
  String get tavernLorePosExampleTop => 'Before examples';

  @override
  String get tavernLorePosExampleBottom => 'After examples';

  @override
  String get tavernLorePosOutlet => 'Outlet';

  @override
  String get tavernLoreLogic => 'How secondary keys count';

  @override
  String get tavernLoreLogicAndAny => 'Any';

  @override
  String get tavernLoreLogicAndAll => 'All';

  @override
  String get tavernLoreLogicNotAny => 'None';

  @override
  String get tavernLoreLogicNotAll => 'Not all';

  @override
  String get tavernLoreProbability => 'Chance';

  @override
  String get tavernLoreCase => 'Case-sensitive';

  @override
  String get tavernLoreWhole => 'Whole words';

  @override
  String get tavernLoreDefault => 'Default';

  @override
  String get tavernLoreYes => 'Yes';

  @override
  String get tavernLoreNo => 'No';

  @override
  String get tavernLorePosDepth => 'At depth';

  @override
  String get tavernLibraryBookOpen => 'Entries';

  @override
  String get tavernLibraryBookNote =>
      'Changes are written back to this book; wherever it is bound uses them from the next turn.';

  @override
  String get tavernBranchDelete => 'Delete this branch';

  @override
  String get tavernBranchDeleteTitle => 'Delete this branch?';

  @override
  String tavernBranchDeleteMessage(int count) {
    return 'Its $count messages, and every branch that grew from it, will go; you can take it back for a few seconds. The way the story is on now is not touched.';
  }

  @override
  String tavernLetterFrom(String from) {
    return 'A letter from $from';
  }

  @override
  String get tavernLetter => 'A letter';

  @override
  String get tavernComponentMore => 'Show all';

  @override
  String get tavernComponentLess => 'Show less';

  @override
  String get tavernItemTaken => 'Got';

  @override
  String get tavernClue => 'Clue';

  @override
  String tavernPhoneFrom(String from) {
    return 'Message from $from';
  }

  @override
  String get tavernPhoneMessage => 'A message';

  @override
  String tavernRollCheck(String skill) {
    return 'Check: $skill';
  }

  @override
  String get tavernRoll => 'Roll';

  @override
  String get tavernRollSuccess => 'Success';

  @override
  String get tavernRollFailure => 'Failure';

  @override
  String get tavernGameHere => 'A mini-game goes here; it can\'t be played here yet';

  @override
  String tavernCanvasReplied(String name) {
    return '$name replied';
  }

  @override
  String get tavernRegexEdit => 'Edit rule';

  @override
  String get tavernRegexFieldName => 'Name';

  @override
  String get tavernRegexFieldFindHelp => 'SillyTavern\'s form: /pattern/flags, e.g. /(hi|bye)/gi';

  @override
  String get tavernRegexFieldReplaceHelp => '\$1 is the first group; {{match}} is the whole match';

  @override
  String get tavernRegexFieldTrim => 'Trim out first';

  @override
  String get tavernRegexFieldTrimHelp => 'One per line, cut from the match before it is replaced';

  @override
  String get tavernRegexPlacement => 'Applies to';

  @override
  String get tavernRegexPlaceUser => 'Your messages';

  @override
  String get tavernRegexPlaceAi => 'Replies';

  @override
  String get tavernRegexPlaceSlash => 'Slash commands';

  @override
  String get tavernRegexPlaceWorld => 'World info';

  @override
  String get tavernRegexPlaceReasoning => 'Reasoning';

  @override
  String get tavernRegexPhase => 'Changes';

  @override
  String get tavernRegexPhaseWrite => 'The text';

  @override
  String get tavernRegexPhaseDisplay => 'Display';

  @override
  String get tavernRegexPhasePrompt => 'Prompt';

  @override
  String get tavernRegexPhaseBoth => 'Both';

  @override
  String get tavernRegexPhaseNote =>
      'The text: rewrites the saved message. Display: the saved text stays; only what you see changes. Prompt: only what is sent to the model.';

  @override
  String get tavernRegexMinDepth => 'From depth';

  @override
  String get tavernRegexMaxDepth => 'To depth';

  @override
  String get tavernRegexDepthHelp => 'Empty means any; 0 is the newest message';

  @override
  String get tavernRegexSubstitute => 'Macros in the pattern';

  @override
  String get tavernRegexSubstituteNone => 'Leave';

  @override
  String get tavernRegexSubstituteRaw => 'Expand';

  @override
  String get tavernRegexSubstituteEscaped => 'Expand escaped';

  @override
  String get tavernRegexRunOnEdit => 'Also when a message is edited';

  @override
  String get tavernRegexFieldEnabled => 'Use this rule';

  @override
  String get tavernRegexSavedIncompatible => 'Saved. This rule can\'t run here, so it is skipped';

  @override
  String get tavernRegexGone => 'This rule is gone; go back to the list';

  @override
  String get tavernRegexDeferred => 'It uses macros; whether it runs is known only when it does';

  @override
  String get tavernRegexTryDraft => 'Try it as filled in';

  @override
  String get tavernRegexDepthAny => 'Any';

  @override
  String get tavernCanvas => 'Whole-page canvas (trial)';

  @override
  String tavernCardScriptsHint(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'This card has $count scripts; they run only with Whole-page canvas (trial) on',
      one: 'This card has a script; it runs only with Whole-page canvas (trial) on',
    );
    return '$_temp0';
  }

  @override
  String get tavernCardScriptsHintAction => 'Turn on';

  @override
  String get tavernRender => 'How it shows';

  @override
  String get tavernRenderSubtitle =>
      'Only this character\'s own chats: a card\'s status bars and styling need pages or the canvas, and its scripts run only on the canvas';

  @override
  String get tavernRenderText => 'Text';

  @override
  String get tavernRenderIslands => 'Pages';

  @override
  String get tavernRenderCanvas => 'Canvas';

  @override
  String get tavernCanvasSubtitle =>
      'The whole chat in one web page laid out as SillyTavern does, so a card\'s ST styles reach across messages. Card scripts run here; turn on \"No card scripts in those pages\" to stop them. Not for visual novel.';

  @override
  String get tavernCanvasReloaded => 'The page reloaded';

  @override
  String tavernGroupSpeaking(String name) {
    return '$name is speaking';
  }

  @override
  String tavernGroupThen(String names) {
    return 'then $names';
  }

  @override
  String get tavernGroupNoSpeakers => 'No one took this turn. Tap a name above to have them speak.';

  @override
  String get tavernGroupSpeakNext => 'Let them go on';

  @override
  String get tavernGroupNew => 'New group chat';

  @override
  String get tavernGroupMembers => 'Who\'s in it';

  @override
  String get tavernGroupMembersNote =>
      'In the order picked; the first hosts it, and the story\'s shared state lives on that card.';

  @override
  String get tavernGroupHost => 'Host';

  @override
  String get tavernGroupTitle => 'Name';

  @override
  String get tavernGroupActivation => 'Taking turns';

  @override
  String get tavernGroupNatural => 'Natural';

  @override
  String get tavernGroupListOrder => 'In order';

  @override
  String get tavernGroupRandom => 'Random';

  @override
  String get tavernGroupManual => 'Manual';

  @override
  String get tavernGroupDirector => 'Director';

  @override
  String get tavernGroupNaturalNote =>
      'As SillyTavern does: whoever is named speaks first, the rest by how talkative each is; the most per turn is in the group\'s settings.';

  @override
  String get tavernGroupListOrderNote => 'Each turn goes down the list from the top (the muted are skipped).';

  @override
  String get tavernGroupRandomNote => 'Each turn picks one who hasn\'t spoken since your last line.';

  @override
  String get tavernGroupManualNote => 'No one speaks on their own; tap a name above the box to have them speak.';

  @override
  String get tavernGroupDirectorNote => 'The director picks who speaks next, as the story goes.';

  @override
  String get tavernGroupPickTwo => 'Pick at least two';

  @override
  String tavernGroupCreate(int count) {
    return 'Create ($count)';
  }

  @override
  String tavernGroupCreateFailed(String reason) {
    return 'Couldn\'t create the group: $reason';
  }

  @override
  String get tavernGroupTag => 'Group';

  @override
  String tavernGroupMemberCount(int count) {
    return '$count members';
  }

  @override
  String get tavernGroupSettings => 'Group settings';

  @override
  String get tavernGroupMaxSpeakers => 'Most to speak each turn';

  @override
  String get tavernGroupSelfResponses => 'May answer themselves';

  @override
  String get tavernGroupSelfResponsesNote => 'Whoever spoke last may still go first this turn.';

  @override
  String tavernGroupHostNote(String name) {
    return 'Hosted by $name: the story\'s shared state, director and secrets live on that card; the host need not be among the speakers.';
  }

  @override
  String get tavernGroupMuted => 'Muted';

  @override
  String get tavernGroupMutedNote => 'Won\'t speak on their own; still speaks when named.';

  @override
  String get tavernGroupTalkativeness => 'Talkativeness';

  @override
  String get tavernGroupTalkativenessNote => 'In natural turns, the higher, the likelier to speak.';

  @override
  String get tavernGroupHelperModel => 'Helper model';

  @override
  String get tavernGroupHelperModelNote =>
      'Speaks with the helper model (automatic: flash without thinking on DeepSeek, the main model elsewhere): for side characters.';

  @override
  String get tavernGroupMoveUp => 'Move up';

  @override
  String get tavernGroupMoveDown => 'Move down';

  @override
  String get tavernGroupRemove => 'Remove from the group';

  @override
  String get tavernGroupAdd => 'Add a character';

  @override
  String get tavernGroupNoOthers => 'Everyone on the shelf is in it';

  @override
  String get tavernGroupUnavailable => 'Card missing';

  @override
  String tavernGroupSaveFailed(String reason) {
    return 'Couldn\'t save: $reason';
  }

  @override
  String get tavernGroupErrorNotGroup => 'This is no longer a group chat';

  @override
  String get tavernGroupErrorCharacterNotFound => 'That character\'s card is gone';

  @override
  String get tavernGroupErrorMemberExists => 'That character is already in the group';

  @override
  String get tavernGroupErrorMemberNotFound => 'That character is no longer in the group';

  @override
  String get tavernGroupErrorInvalidMembers => 'Members can\'t repeat, and a group needs at least one character';

  @override
  String get tavernGroupErrorInvalidTalkativeness => 'Talkativeness goes from 0 to 1';

  @override
  String get tavernGroupErrorInvalidLimit => 'At least one member speaks each round';

  @override
  String get tavernGroupErrorInvalidOrder => 'That order doesn\'t match the members; open it again and reorder';

  @override
  String get tavernGroupErrorHostInUse => 'This character hosts a group chat; delete that chat first';

  @override
  String get tavernGroupErrorInvalidTitle => 'A group chat\'s name can\'t be blank';

  @override
  String tavernToolRollUnsettled(String dice) {
    return '🎲 $dice: result not confirmed yet';
  }

  @override
  String tavernToolRollNotDone(String dice) {
    return '🎲 $dice: not rolled';
  }

  @override
  String tavernToolRollPass(int target) {
    return 'target $target, passed';
  }

  @override
  String tavernToolRollFail(int target) {
    return 'target $target, missed';
  }

  @override
  String tavernToolMemory(String text) {
    return 'Wants to remember: \"$text\"';
  }

  @override
  String get tavernToolMemoryAccept => 'Remember';

  @override
  String get tavernToolMemoryReject => 'No';

  @override
  String get tavernToolMemoryStaged => 'Decided once this turn is written';

  @override
  String tavernToolMemoryIneligible(String reason) {
    return 'Can\'t be decided now: $reason';
  }

  @override
  String get tavernToolMemoryAccepted => 'Remembered';

  @override
  String get tavernToolMemoryAuto => 'Remembered by the automatic setting';

  @override
  String get tavernToolMemoryRejected => 'Not remembered';

  @override
  String get tavernToolMemoryInactive => 'This turn didn\'t finish normally; not remembered';

  @override
  String get tavernToolMemoryWaiting => 'Your last decision hasn\'t gone through yet';

  @override
  String tavernToolMemoryNotApplied(String reason) {
    return 'Not remembered: $reason';
  }

  @override
  String tavernToolMemoryFailed(String detail) {
    return 'Didn\'t go through: $detail';
  }

  @override
  String get tavernToolReasonRevision => 'it has changed; refresh and decide again';

  @override
  String get tavernToolReasonResolved => 'already decided';

  @override
  String get tavernToolReasonContext => 'the chat has changed';

  @override
  String get tavernToolReasonDeleted => 'that reply was deleted';

  @override
  String get tavernToolReasonChanged => 'that reply was edited';

  @override
  String get tavernToolReasonBranch => 'not on the current branch';

  @override
  String get tavernToolReasonInactive => 'no longer active';

  @override
  String get tavernToolReasonUnknown => 'reason unknown';

  @override
  String get tavernToolPolicy => 'Tools';

  @override
  String get tavernToolPolicyRoll => 'Let characters roll dice';

  @override
  String get tavernToolPolicyRollSubtitle => 'When a reply needs a roll, the tavern rolls it and keeps the result';

  @override
  String get tavernToolPolicyRemember => 'Let characters keep notes';

  @override
  String get tavernToolPolicyRememberSubtitle =>
      'What a character finds worth remembering goes into memory, as set below';

  @override
  String get tavernToolPolicyMode => 'Keeping notes';

  @override
  String get tavernToolPolicyModeAsk => 'Ask me first';

  @override
  String get tavernToolPolicyModeAuto => 'Automatically';

  @override
  String get tavernToolPolicyDiagnostics =>
      'Part of this setting couldn\'t be read; the tool it belongs to is off for now';

  @override
  String get tavernToolPolicyNote =>
      'Replies only use these with DeepSeek and thinking off; a change applies from the next turn, and a character card can turn them off';

  @override
  String tavernToolPolicyFailed(String detail) {
    return 'Didn\'t change: $detail';
  }

  @override
  String get tavernChatTools => 'Tools in this chat';

  @override
  String get tavernChatToolFollow => 'As set';

  @override
  String get tavernChatToolOn => 'On';

  @override
  String get tavernChatToolOff => 'Off';

  @override
  String tavernChatToolNow(String roll, String remember) {
    return 'In this chat: dice $roll, memories $remember';
  }

  @override
  String get tavernChatToolHeld => 'What tavern settings turned off stays off, even if on here';

  @override
  String tavernInspectRequests(int count) {
    return '$count requests';
  }

  @override
  String tavernInspectUsageTotals(String prompt, String hit, String completion) {
    return 'In $prompt (cached $hit) · out $completion';
  }

  @override
  String get tavernReqUsagePrompt => 'In';

  @override
  String get tavernReqUsageCache => 'Cached';

  @override
  String get tavernReqUsageCompletion => 'Out';

  @override
  String tavernReqUsageLine(String field, String parts) {
    return '$field: $parts';
  }

  @override
  String get tavernReqUsageJoin => ', ';

  @override
  String tavernReqUsageKnown(String known) {
    return '$known known';
  }

  @override
  String tavernReqUsageUnknown(int count) {
    return '$count not known';
  }

  @override
  String tavernReqUsageMissing(int count) {
    return '$count not reported';
  }

  @override
  String tavernReqUsageInvalid(int count) {
    return '$count reported wrongly';
  }

  @override
  String get tavernToolFailBudget =>
      'This turn has used up its tool requests and stops here; dice already rolled still count';

  @override
  String get tavernToolFailBatch => 'The model asked for too many tools at once; that batch was not run';

  @override
  String get tavernToolFailProtocol => 'The model\'s tool call was malformed and was not run';

  @override
  String get tavernToolFailSnapshot => 'This model\'s reply can\'t continue with tools, so it stops here';

  @override
  String get tavernToolFailReceipt => 'A tool\'s result couldn\'t be saved; check this turn again shortly';

  @override
  String get tavernToolFailAnchor => 'The chat changed during this turn, so it did not go on';

  @override
  String get tavernToolFail => 'Something went wrong with a tool';

  @override
  String tavernToolFailDetail(String detail) {
    return 'Something went wrong with a tool: $detail';
  }

  @override
  String get tavernDiceUnsettled => 'The result is not confirmed yet; check again';

  @override
  String get tavernDicePending => 'Your last roll isn\'t confirmed yet';

  @override
  String get tavernDiceRecheck => 'Check again';

  @override
  String get tavernDiceForget => 'Let it go';

  @override
  String get tavernDiceBusy => 'Busy right now; roll once this turn is written';

  @override
  String get tavernDiceOff => 'Dice are turned off in tavern settings';

  @override
  String tavernDiceFailed(String detail) {
    return 'Didn\'t roll: $detail';
  }

  @override
  String tavernDiceNotSaved(String detail) {
    return 'Didn\'t go through: $detail';
  }

  @override
  String get tavernChannel => 'Channel';

  @override
  String get tavernChannelDeepSeek => 'DeepSeek';

  @override
  String get tavernChannelDeepSeekNote => 'Uses the app\'s DeepSeek key';

  @override
  String get tavernChannelAdd => 'Add a channel';

  @override
  String get tavernChannelEdit => 'Edit channel';

  @override
  String get tavernChannelsNote =>
      'Any OpenAI-compatible service works: a relay, OpenRouter, a model running on your own computer. Keys stay in this phone\'s secure storage. Cost estimates know DeepSeek\'s prices only; other channels show token counts.';

  @override
  String get tavernChannelName => 'Name';

  @override
  String get tavernChannelNameHint => 'Leave empty to use the address';

  @override
  String get tavernChannelBaseUrlInvalid => 'Starts with http:// or https://';

  @override
  String get tavernChannelKeyOptional => 'A local server without a key can leave this empty';

  @override
  String get tavernChannelKeyKept => 'A key is saved; leave empty to keep it';

  @override
  String get tavernChannelFetchModels => 'Fetch list';

  @override
  String get tavernChannelFetching => 'Fetching…';

  @override
  String tavernChannelFetchFailed(String detail) {
    return 'Couldn\'t get the model list ($detail). You can type the model name.';
  }

  @override
  String get tavernChannelNoModels => 'This service lists no models. Type the model name.';

  @override
  String get tavernChannelModelHint => 'The model name your provider gives';

  @override
  String get tavernChannelModelMissing => 'Enter a model name';

  @override
  String get tavernChannelPickModel => 'Pick a model';

  @override
  String get tavernChannelSearchModels => 'Search models';

  @override
  String get tavernChannelDeepSeekApi => 'Send as DeepSeek\'s API';

  @override
  String get tavernChannelDeepSeekApiNote =>
      'Uses DeepSeek\'s continuation and the Thinking switch. Turn on only for DeepSeek itself or a relay that forwards it as is.';

  @override
  String get tavernChannelDelete => 'Delete channel';

  @override
  String tavernChannelDeleteTitle(String name) {
    return 'Delete “$name”?';
  }

  @override
  String get tavernChannelDeleteMessage => 'Its key is deleted too. If it\'s in use, DeepSeek takes over.';

  @override
  String get tavernChannelCopyFromApp => 'Copy from the app\'s channels';

  @override
  String get tavernModelName => 'Model name';

  @override
  String get tavernNumberCustom => 'Custom';

  @override
  String get tavernNumberType => 'Enter a number';

  @override
  String tavernNumberRange(String min, String max) {
    return 'Enter a number from $min to $max';
  }

  @override
  String tavernNumberRangeWhole(String min, String max) {
    return 'Enter a whole number from $min to $max';
  }

  @override
  String get tavernTopP => 'Top P';

  @override
  String get tavernPresencePenalty => 'Presence penalty';

  @override
  String get tavernFrequencyPenalty => 'Frequency penalty';

  @override
  String get tavernPresetSampling => 'Sampling';

  @override
  String get tavernChannelHeaders => 'Request headers (optional)';

  @override
  String get tavernChannelHeadersNote =>
      'One per line, as “Name: value”. Kept in this phone\'s secure storage, like the key.';

  @override
  String get tavernChannelHeadersInvalid => 'Write each line as “Name: value”';

  @override
  String get tavernAuxiliary => 'Helper model';

  @override
  String get tavernAuxiliaryNote => 'Used for the director, picking who speaks in a group, and secrets';

  @override
  String get tavernAuxiliaryAuto => 'Automatic';

  @override
  String get tavernAuxiliaryAutoNote => 'Follows the main channel: Flash on DeepSeek, the same model elsewhere';

  @override
  String get tavernAuxiliaryDeepSeek => 'DeepSeek Flash';

  @override
  String get tavernChannelKeyClear => 'Clear';

  @override
  String get tavernChannelKeyCleared => 'The key is cleared when you save';

  @override
  String get tavernDrafts => 'Drafts';

  @override
  String get tavernDraftsSubtitle => 'Changes wait in a draft until you pick what goes into the real one';

  @override
  String get tavernDraftsForCard => 'Change this card with AI';

  @override
  String get tavernDraftsForCardSubtitle => 'In a draft; apply what you pick';

  @override
  String get tavernDraftsEmpty => 'No drafts yet';

  @override
  String get tavernDraftsEmptyOwn => 'Start a draft and tell the AI how to change this card.';

  @override
  String get tavernDraftsEmptyAll =>
      'Start one from a character\'s page, or from a file: it stays a draft, nothing is imported.';

  @override
  String get tavernDraftNew => 'New draft';

  @override
  String get tavernDraftFromFile => 'Draft from a file';

  @override
  String tavernDraftSeedUnsupported(String name) {
    return '$name isn\'t a card or a lorebook';
  }

  @override
  String get tavernDraft => 'Draft';

  @override
  String get tavernDraftSubtitle => 'Nothing here is in the real one yet';

  @override
  String get tavernDraftGone => 'This draft is gone';

  @override
  String get tavernDraftKindCharacter => 'Card';

  @override
  String get tavernDraftKindPreset => 'Preset';

  @override
  String tavernDraftNewSource(String name) {
    return '$name (not saved yet)';
  }

  @override
  String get tavernDraftGreetings => 'Other greetings';

  @override
  String tavernDraftEntry(int n) {
    return 'Entry $n';
  }

  @override
  String get tavernDraftNoChanges => 'No changes yet';

  @override
  String get tavernDraftNoChangesHint => 'Tell the AI below what to change';

  @override
  String get tavernDraftBefore => 'Was';

  @override
  String get tavernDraftAfter => 'Becomes';

  @override
  String get tavernDraftAbsent => '(none)';

  @override
  String get tavernDraftRemoved => 'Removed';

  @override
  String get tavernDraftAppliedChange => 'Applied';

  @override
  String tavernDraftDependsOn(int n) {
    return 'Goes with $n earlier change(s)';
  }

  @override
  String get tavernDraftRemoveChange => 'Take this out of the draft';

  @override
  String tavernDraftApply(int n) {
    return 'Apply $n';
  }

  @override
  String get tavernDraftSaveNew => 'Save as new';

  @override
  String get tavernDraftSavedNew => 'Saved as new';

  @override
  String get tavernDraftChecked => 'Checked: nothing found';

  @override
  String get tavernDraftCannotApply => 'Regex and preset drafts can be previewed, not applied yet';

  @override
  String tavernDraftApplied(String name) {
    return 'Applied to $name';
  }

  @override
  String get tavernDraftNoChange => 'Same as now: nothing to change';

  @override
  String tavernDraftNotApplied(String reason) {
    return 'Not applied: $reason';
  }

  @override
  String get tavernDraftUnconfirmed =>
      'The write isn\'t confirmed yet. Don\'t repeat it; check the history in a while.';

  @override
  String tavernDraftApplyUnknown(String reason) {
    return 'No answer ($reason); tapping again continues the same one';
  }

  @override
  String tavernDraftBehind(String name) {
    return '$name changed after this draft began (maybe just now, by applying). Continue from it and look the changes over again.';
  }

  @override
  String get tavernDraftCatchUp => 'Continue from now';

  @override
  String get tavernDraftChangedMeanwhile => 'The draft just changed; reloaded';

  @override
  String get tavernDraftPending => 'The last write isn\'t confirmed; it can\'t be applied again yet';

  @override
  String get tavernDraftDelete => 'Delete draft';

  @override
  String get tavernDraftDeleteTitle => 'Delete this draft?';

  @override
  String get tavernDraftDeleteBody => 'Only the draft goes; what was applied stays.';

  @override
  String get tavernDraftAskHint => 'What to change? e.g. a cooler greeting';

  @override
  String get tavernDraftAiSend => 'Ask the AI';

  @override
  String get tavernDraftAiStop => 'Stop';

  @override
  String get tavernDraftAiTitle => 'AI';

  @override
  String get tavernDraftAiRunning => 'Working…';

  @override
  String get tavernDraftAiDone => 'Done: the changes are above; pick and apply';

  @override
  String get tavernDraftAiStopped => 'Stopped';

  @override
  String get tavernDraftAiConflict => 'The draft changed meanwhile; the AI stopped';

  @override
  String get tavernDraftAiBudget => 'Four requests used; it stopped here';

  @override
  String get tavernDraftAiFailed => 'Something went wrong';

  @override
  String get tavernDraftAiInterrupted => 'Interrupted (the app closed)';

  @override
  String get tavernDraftEarlier => 'Asked before';

  @override
  String tavernDraftRunReceipts(int changes, int requests) {
    return '$changes edit(s) · $requests request(s)';
  }

  @override
  String get tavernDraftHistory => 'Versions';

  @override
  String get tavernDraftHistoryEmpty => 'No versions recorded yet';

  @override
  String get tavernDraftHistoryNote =>
      'Going back saves it as a new version; later ones stay. Pictures and chats aren\'t touched.';

  @override
  String tavernDraftVersion(int n) {
    return 'Version $n';
  }

  @override
  String get tavernDraftVersionCurrent => 'Current';

  @override
  String get tavernDraftRestore => 'Go back to it';

  @override
  String tavernDraftRestoreTitle(int n) {
    return 'Go back to version $n?';
  }

  @override
  String get tavernDraftRestoreBody => 'It is saved as a new version.';

  @override
  String tavernDraftRestored(int n) {
    return 'Back to version $n';
  }

  @override
  String get tavernDraftRestoreMoved => 'It changed meanwhile; try again';

  @override
  String get tavernDraftPrompt => 'Prompt with the draft';

  @override
  String get tavernDraftPromptSubtitle => 'What the next turn would send with the ticked changes; nothing is sent';

  @override
  String get tavernDraftPromptFrom => 'After which chat';

  @override
  String get tavernDraftPromptFirst => 'A new chat';

  @override
  String get tavernDraftPromptText => 'Next line (optional)';

  @override
  String get tavernDraftPromptTextHint => 'What you would say';

  @override
  String get tavernDraftPromptShow => 'Show the prompt';

  @override
  String get tavernDraftPromptComplete => 'Prompt';

  @override
  String get tavernDraftPromptUnsupported => 'Part of this card can\'t be put together faithfully in a preview';

  @override
  String get tavernDraftPromptNote => 'The card\'s scripts don\'t run in a preview.';

  @override
  String tavernDraftUsagePartial(String prompt, String completion) {
    return 'Reported: in $prompt · out $completion (some requests reported nothing)';
  }

  @override
  String get tavernDraftTrial => 'Try it';

  @override
  String get tavernDraftTrialSubtitle => 'A few lines with the draft in a chat of its own; real chats aren\'t touched';

  @override
  String get tavernDraftTrialNote => 'The model is really asked and billed as used; four lines at most.';

  @override
  String tavernDraftTrialLine(int n) {
    return 'Line $n';
  }

  @override
  String get tavernDraftTrialMore => 'Add a line';

  @override
  String get tavernDraftTrialPlay => 'Start';

  @override
  String get tavernDraftTrialRunning => 'Playing…';

  @override
  String get tavernDraftTrialDone => 'Done';

  @override
  String get tavernDraftTrialUnsupported => 'This draft can\'t be tried yet';

  @override
  String get tavernPacks => 'Gameplay packs';

  @override
  String get tavernPacksSubtitle =>
      'Installed packs. Installing doesn\'t turn one on: add it globally, to a character or to a chat.';

  @override
  String get tavernPacksEmpty => 'No gameplay packs yet';

  @override
  String get tavernPacksEmptyNote =>
      'Import a .dshpack file. Importing only keeps it: nothing is turned on and no character is made.';

  @override
  String get tavernPackImport => 'Import pack';

  @override
  String tavernPackInstalled(String title, String version) {
    return 'Imported $title $version';
  }

  @override
  String tavernPackAlreadyInstalled(String title, String version) {
    return '$title $version is already installed with the same content';
  }

  @override
  String tavernPackVersionCount(int n) {
    return '$n versions';
  }

  @override
  String tavernPackWithdrawnShort(String version) {
    return '$version (withdrawn)';
  }

  @override
  String get tavernPackWithdrawnLabel => 'Withdrawn';

  @override
  String get tavernPackShowWithdrawn => 'Show withdrawn versions';

  @override
  String get tavernPackScopeGlobal => 'On everywhere';

  @override
  String get tavernPackScopeGlobalSubtitle => 'Packs every chat uses';

  @override
  String get tavernPackScopeCharacter => 'This character\'s packs';

  @override
  String get tavernPackScopeChat => 'This chat\'s packs';

  @override
  String get tavernPackForCardSubtitle => 'Used by every chat with this card';

  @override
  String get tavernPackBindingsSubtitle => 'Changes take effect when saved; preview to see what they compose into';

  @override
  String get tavernPackOrderNote =>
      'Composed top to bottom; the preview shows which pack wins each field. Tap a row to change its version, order or characters.';

  @override
  String get tavernPackAdd => 'Add a pack';

  @override
  String get tavernPackUnsaved => 'Not saved';

  @override
  String get tavernPackResetPending => 'Once-only state resets on save';

  @override
  String tavernPackCastMappedCount(int n) {
    return '$n characters linked';
  }

  @override
  String get tavernPackRemovedBindings => 'Removed';

  @override
  String get tavernPackPickVersion => 'Change version';

  @override
  String get tavernPackMoveUp => 'Move up';

  @override
  String get tavernPackMoveDown => 'Move down';

  @override
  String get tavernPackResetOnce => 'Reset once-only state';

  @override
  String get tavernPackRestore => 'Restore';

  @override
  String get tavernPackRemoveBinding => 'Remove';

  @override
  String get tavernPackSaved => 'Saved';

  @override
  String tavernPackUnanswered(String reason) {
    return 'No answer: $reason. Saving again retries the same operation';
  }

  @override
  String get tavernPackVersion => 'Version';

  @override
  String get tavernPackAddGlobal => 'Turn on everywhere';

  @override
  String get tavernPackAddNote =>
      'For one character or chat only, add it from the character\'s page or the chat\'s stage panel';

  @override
  String get tavernPackCast => 'Characters';

  @override
  String get tavernPackCastNote =>
      'Importing makes a new character; the original card is untouched and no group chat is joined';

  @override
  String get tavernPackCastFromCard => 'Full character card';

  @override
  String get tavernPackCastImportAction => 'Import as character';

  @override
  String tavernPackCastImportTitle(String name) {
    return 'Import $name as a new character?';
  }

  @override
  String get tavernPackCastImportNote =>
      'A new character goes into the library. Changing this pack\'s version later won\'t replace it.';

  @override
  String tavernPackCastImported(String name) {
    return 'Imported $name';
  }

  @override
  String get tavernPackCastNotAdopted => 'No character was made this time';

  @override
  String tavernPackCastUnknown(String state) {
    return 'Not confirmed yet ($state); check the library in a moment';
  }

  @override
  String get tavernPackCastMapping => 'Linked characters';

  @override
  String get tavernPackCastMapped => 'Linked';

  @override
  String get tavernPackResources => 'Resources';

  @override
  String tavernPackIssueCount(int n) {
    return '$n notes';
  }

  @override
  String get tavernPackDeclaration => 'Declaration check';

  @override
  String get tavernPackDeclarationNote =>
      'What the import found. Installed doesn\'t mean every block runs; conditional and opaque parts depend on the case.';

  @override
  String get tavernPackNothingNoted => 'Nothing to note';

  @override
  String get tavernPackExportOriginal => 'Export the original file';

  @override
  String get tavernPackWithdraw => 'Withdraw this version';

  @override
  String tavernPackWithdrawTitle(String version) {
    return 'Withdraw $version?';
  }

  @override
  String get tavernPackWithdrawNote =>
      'It can\'t be chosen anew; places already using it stay as they are. The file and its history are kept and can still be exported.';

  @override
  String get tavernPackPreview => 'Preview';

  @override
  String get tavernPackPreviewSubtitle => 'Composed with the current changes; nothing is saved or run';

  @override
  String get tavernPackPreviewSources => 'Sources';

  @override
  String get tavernPackPreviewDefinitions => 'Definitions';

  @override
  String get tavernPackPreviewConflicts => 'Conflicts';

  @override
  String get tavernPackPreviewFields => 'Field sources';

  @override
  String get tavernPackPreviewState => 'Current value';

  @override
  String get tavernPackPreviewNote => 'Read only: no binding is saved, no variable set up, no model asked.';

  @override
  String get tavernPackStateUnavailable => 'This chat has no state to check yet';

  @override
  String get tavernPackStateNotValidated =>
      'The current value wasn\'t validated this time; see the definitions and conflicts';

  @override
  String get tavernPackStateValid => 'The current value fits the composed definition';

  @override
  String get tavernPackStateInvalid => 'The current value doesn\'t fit the composed definition';

  @override
  String get tavernPackStateMissing => 'This chat has no such value';

  @override
  String get tavernPackCardExport => 'Export with packs';

  @override
  String get tavernPackCardExportMenuSubtitle => 'Fold chosen pack resources into the card';

  @override
  String get tavernPackCardExportSubtitle => 'Preview first; export once nothing blocks it';

  @override
  String get tavernPackExportFormat => 'Format';

  @override
  String get tavernPackExportCopyMedia => 'Include the card\'s images';

  @override
  String get tavernPackExportFlattenNote =>
      'Inside a single card, scope, order, budget and timing may behave differently than here';

  @override
  String get tavernPackExportNoResources => 'The packs on for this card have no resources a card can carry';

  @override
  String get tavernPackExportFindings => 'Preview';

  @override
  String tavernPackExportMappings(int ids, int resources) {
    return '$ids identities and $resources resources rewritten';
  }

  @override
  String get tavernPackExportGo => 'Export';

  @override
  String get tavernPackExportPreviewFirst => 'Preview first';

  @override
  String get tavernPackExportBlocked => 'Something blocks the export';

  @override
  String get tavernPackDraftExport => 'Export as pack';

  @override
  String tavernPackDraftExportSubtitle(int n) {
    return 'A new .dshpack from this draft\'s character definition and all $n changes';
  }

  @override
  String get tavernPackDraftId => 'Pack ID';

  @override
  String get tavernPackDraftRoots => 'State paths to include';

  @override
  String get tavernPackDraftRootsHint => 'e.g. /hp /items; empty for all of it';

  @override
  String get tavernPackInstallMade => 'Install here';

  @override
  String get tavernPackCommitted => 'The change took effect, but a later notice failed';

  @override
  String get tavernPackVersionConflict =>
      'This pack ID and version already exist with different content; use a new version name';

  @override
  String get tavernPackRevisionConflict => 'Changed elsewhere. Refreshed: please make this change again';

  @override
  String get tavernPackOperationConflict => 'This operation\'s ID was already used; please do it again';

  @override
  String get tavernPackVersionNotFound => 'Version not found';

  @override
  String get tavernPackVersionRemoved => 'This version is withdrawn and can\'t be chosen anew';

  @override
  String get tavernPackTimerConflict =>
      'This upgrade changes sticky or cooldown settings: reset once-only state with it, or add a new instance';

  @override
  String get tavernPackTargetGone => 'The character, chat or binding is gone';

  @override
  String get tavernPackAuthorityConflict => 'The character\'s source changed; refresh and confirm again';

  @override
  String get tavernPackCastUnproven => 'Can\'t confirm this character was imported from this pack';

  @override
  String get tavernPackCastOtherVersion => 'The linked character comes from another version of this pack';

  @override
  String get tavernPackExportChanged => 'The export\'s sources or options changed; preview again';

  @override
  String get updateCheck => 'Check for updates';

  @override
  String get updateAutoCheck => 'Check automatically';

  @override
  String get updateAutoCheckDaily => 'Once a day';

  @override
  String get updateTileDownloading => 'Downloading';

  @override
  String updateTileDownloadingPercent(int percent) {
    return 'Downloading $percent%';
  }

  @override
  String get updateTileVerifying => 'Verifying';

  @override
  String get updateTileReady => 'Ready to install';

  @override
  String get updateTileInstalling => 'Installing';

  @override
  String updateTileSkipped(String version) {
    return 'Skipped $version';
  }

  @override
  String updateTileNewVersion(String version) {
    return 'New: $version';
  }

  @override
  String get updateTileUpToDate => 'Up to date';

  @override
  String get updateTileUnavailable => 'Can’t check right now';

  @override
  String get updateUpToDate => 'You’re up to date';

  @override
  String get updateCheckUnavailable => 'Can’t check for updates right now. Try again later.';

  @override
  String get updateDownloadInterrupted => 'Download interrupted';

  @override
  String get updateDownloadInterruptedMessage => 'The network is disconnected or too slow. Retry to resume.';

  @override
  String get updateDownloadUnavailable => 'Download link unavailable';

  @override
  String get updateDownloadUnavailableMessage => 'Try again later, or download from the release page.';

  @override
  String get updateChecksumFailed => 'Package verification failed';

  @override
  String get updateChecksumFailedMessage => 'The file doesn’t match the release and was deleted. Try again.';

  @override
  String get updateChecksumMissing => 'Verification info missing';

  @override
  String get updateChecksumMissingMessage => 'For safety, download from the release page to install.';

  @override
  String get updateStorageWriteFailed => 'Couldn’t save package';

  @override
  String get updateStorageWriteFailedMessage => 'Storage may be full. Free up space and try again.';

  @override
  String get updateFreeSpaceRetry => 'Free up space and try again.';

  @override
  String updateSpaceRequired(String size) {
    return 'About $size of free space needed. Free up space and try again.';
  }

  @override
  String get updateSettingsOpenFailed => 'Couldn’t open system settings';

  @override
  String get updateSettingsOpenFailedMessage =>
      'Allow “Install unknown apps” in Settings → Apps → DSH Go, then return to install.';

  @override
  String get updateInstallCancelled => 'Installation cancelled';

  @override
  String get updateInstallCancelledMessage => 'The package is saved. You can install it anytime.';

  @override
  String get updateInstallUnconfirmed => 'Installation result not confirmed';

  @override
  String get updateInstallUnconfirmedMessage =>
      'The package is saved. Check any system prompts, then retry or open it with the system installer.';

  @override
  String get updateSignatureMismatch => 'App signatures don’t match';

  @override
  String get updateSignatureMismatchMessage =>
      'The DSH Go on your phone has a different signature (usually a test build). Uninstall it before installing this version. Uninstalling erases your chats, Linux environment, and settings.';

  @override
  String get updateWrongPackage => 'This isn’t a DSH package';

  @override
  String get updateWrongPackageMessage => 'The wrong file was downloaded and deleted. Try again later.';

  @override
  String get updateDowngradeBlocked => 'Can’t install an older version';

  @override
  String get updateDowngradeBlockedMessage => 'The DSH on your phone is newer than this package.';

  @override
  String get updateIncompatible => 'Incompatible with this phone';

  @override
  String get updateIncompatibleMessage =>
      'The package’s required Android version or processor architecture doesn’t match your phone.';

  @override
  String get updatePackageCorrupt => 'Package is damaged';

  @override
  String get updatePackageCorruptMessage => 'It was deleted. Download it again.';

  @override
  String get updateInstallBlocked => 'Installation blocked';

  @override
  String get updateInstallBlockedMessage =>
      'Allow installation in the system prompt. If the system blocks it outright (Xiaomi and others), try Shizuku or on-device ADB under Installation route; that needs no new signature.';

  @override
  String get updateInstallIncomplete => 'Installation incomplete';

  @override
  String get updateInstallIncompleteMessage => 'Try again, or download from the release page.';

  @override
  String updateBrowserOpenFailed(String host, String path) {
    return 'Couldn’t open your browser. Visit $host$path manually.';
  }

  @override
  String updateUpToDateVersion(String version) {
    return 'You’re up to date: $version';
  }

  @override
  String updateCurrentVersion(String version) {
    return 'Current $version';
  }

  @override
  String get updateNewVersionFound => 'New version available';

  @override
  String get updateReleaseNotes => 'What’s new';

  @override
  String get updateNoReleaseNotes => 'No release notes for this version.';

  @override
  String get updateInstallKeepsData => 'DSH Go closes to install. Your chats and settings stay.';

  @override
  String get updateNoCompatiblePackage => 'No package for this phone';

  @override
  String get updateDownloading => 'Downloading';

  @override
  String updateDownloadSource(String source) {
    return 'Via $source';
  }

  @override
  String get updateDownloadInBackgroundNote => 'Download continues after you close this window';

  @override
  String get updateVerifyingPackage => 'Verifying package…';

  @override
  String get updateVerifyingPackageNote => 'Checking the file matches the release';

  @override
  String get updateInstalling => 'Installing…';

  @override
  String get updateConfirmInstallNote => 'Confirm installation in the system prompt';

  @override
  String get updatePackageDownloaded => 'Package downloaded';

  @override
  String get updateReadyToInstall => 'Verified and ready to install.';

  @override
  String get updateAllowInstall => 'Allow DSH Go to install apps';

  @override
  String get updateAllowInstallMessage =>
      'Turn on “Install unknown apps” in system settings. Installation resumes when you return.';

  @override
  String get updateOpenReleasePage => 'Open release page';

  @override
  String get updateUpdateNow => 'Update now';

  @override
  String get updateSkipVersion => 'Skip this version';

  @override
  String get updateInstallWithSystem => 'Install with the system installer';

  @override
  String get updateSystemInstallerFailed => 'Couldn\'t open the system installer';

  @override
  String get updateExportApk => 'Save the package';

  @override
  String get updateExportApkTitle => 'Save the package?';

  @override
  String get updateExportApkMessage =>
      'Copies the package downloaded and verified now into Downloads/DSH-Go, so you can sign it yourself (MT Manager and the like) and install that.\n\nA package you signed has a different signature from ours: in-app updates then always report a signature mismatch, and every later version has to be signed and installed by hand.\n\nIf the system simply blocks the install (Xiaomi and other vendors), try Shizuku or on-device ADB under Installation route first; that needs no signing.';

  @override
  String updateExportApkDone(String path) {
    return 'Saved to Downloads/$path';
  }

  @override
  String get updateExportApkFailed => 'Couldn\'t save the package';

  @override
  String get updateStarProject => 'Star it';

  @override
  String get updateCancelDownload => 'Cancel download';

  @override
  String get updateDownloadInBackground => 'Download in background';

  @override
  String get updateVerifying => 'Verifying…';

  @override
  String get updateInstallingBusy => 'Installing…';

  @override
  String get updateOpenPermissionSettings => 'Turn on';

  @override
  String updateNoAbiPackage(String abi) {
    return 'No $abi package for this release yet. Check the release page.';
  }

  @override
  String get updateNoPackage => 'No package for this release yet. Check the release page.';

  @override
  String updateDownloadingPercent(int percent) {
    return 'Downloading $percent%';
  }

  @override
  String get usageStatsTitle => 'Send anonymous usage stats';

  @override
  String get usageStatsSection => 'Improve DSH Go';

  @override
  String get usageStatsFooter =>
      'This switch controls dsh-go’s own statistics: feature counts (tavern messages, companion room visits and voice calls included), the token counts model replies report, versions, phone maker and model, and system version. It includes no chats, character cards, files or accounts, and does not control Google ML Kit SDK statistics.';

  @override
  String get usageNoticeBody => 'No chats or personal info.\nTurn off anytime.';

  @override
  String get usageUpgradeNotice => 'New: anonymous usage stats, to help improve DSH Go.\nNo chats or personal info.';

  @override
  String get usageUpgradeLearn => 'Learn more';

  @override
  String get usageUpgradeOff => 'Turn off';

  @override
  String viewArtifactSaved(String value) {
    return 'Saved to $value';
  }

  @override
  String get viewDownloadFolder => 'Downloads/';

  @override
  String get viewArtifactNoPreview => 'Can’t preview';

  @override
  String get viewArtifactNotText => 'Not a text file';

  @override
  String get viewArtifactLarge => 'Large file';

  @override
  String get viewArtifactMissing => 'This file is no longer available';

  @override
  String get viewArtifactNotFile => 'This isn’t a file';

  @override
  String get viewArtifactOpenFailed => 'Couldn’t open';

  @override
  String get viewArtifactMore => 'More actions';

  @override
  String get viewWorkspace => 'Workspace';

  @override
  String get viewArtifactEmpty => 'Empty file';

  @override
  String viewArtifactLines(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count lines', one: '1 line');
    return 'Large file. Showing the first $_temp0';
  }

  @override
  String viewArtifactRows(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count rows', one: '1 row');
    return 'Showing the first $_temp0';
  }

  @override
  String get viewArtifactColumns => 'Showing the first 200 columns';

  @override
  String viewArtifactWorksheet(int value) {
    return 'Sheet $value';
  }

  @override
  String get viewArtifactEmptySheet => 'Empty sheet';

  @override
  String get viewArtifactEmptyTable => 'Empty table';

  @override
  String get viewArtifactConvertFailed => 'Couldn’t convert';

  @override
  String get viewArtifactConverting => 'Converting to PDF…';

  @override
  String get viewArtifactImageFailed => 'Can’t display this image';

  @override
  String get viewArtifactPhoneOpen => 'Open in an app on this phone';

  @override
  String get viewArtifactPdfFailed => 'Can’t open this PDF. Try another app.';

  @override
  String viewArtifactPages(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count pages', one: '1 page');
    return '$_temp0';
  }

  @override
  String viewArtifactPage(int value) {
    return 'Page $value';
  }

  @override
  String get viewBalanceInvalidKey => 'Invalid key. Can’t check balance.';

  @override
  String get viewBalancePrefix => 'Balance ';

  @override
  String get viewBalanceLowSuffix => ' · Low balance';

  @override
  String get viewBalanceUnavailableSuffix => ' · Calls unavailable';

  @override
  String get viewBalanceTopUp => 'Top up';

  @override
  String get viewBalanceTitle => 'DeepSeek balance';

  @override
  String get viewBalanceKeyRequired => 'Enter an API key to check your balance';

  @override
  String get viewBalanceKeyInvalid => 'Invalid API key. Can’t check balance.';

  @override
  String viewBalancePaid(String value) {
    return 'Paid $value';
  }

  @override
  String viewBalanceGranted(String value) {
    return 'Bonus $value';
  }

  @override
  String get viewBalanceLow => 'Low balance';

  @override
  String get viewBalanceUnavailable => 'Calls unavailable';

  @override
  String get viewBalanceChecking => 'Checking balance…';

  @override
  String get viewBalanceCheckFailed => 'Can’t check balance right now';

  @override
  String get viewBalanceNoAlert => 'Off';

  @override
  String get viewBalanceBannerHidden => 'Balance alert hidden until DSH Go restarts';

  @override
  String get viewBalanceTurnOff => 'Turn off';

  @override
  String viewBalanceBelow(String value) {
    return 'Below $value';
  }

  @override
  String get viewBalanceAlert => 'Low balance alert';

  @override
  String get viewBalanceThreshold => 'Alert threshold';

  @override
  String get viewBalanceGoTopUp => 'Top up';

  @override
  String viewBalanceRemaining(String value) {
    return 'Only $value left';
  }

  @override
  String get viewBalanceModelDisabled => 'Insufficient balance. Model disabled.';

  @override
  String get viewBalanceRestore => 'Top up to resume';

  @override
  String get viewUiIncomplete => 'View is still generating';

  @override
  String get viewUiInvalid => 'This view has a formatting error';

  @override
  String get viewUiResend => 'Ask to resend';

  @override
  String viewChartUnit(String value) {
    return 'Unit: $value';
  }

  @override
  String viewChartSeries(int value) {
    return 'Series $value';
  }

  @override
  String get viewChartTotal => 'Total';

  @override
  String get viewChartBar => 'Bar chart';

  @override
  String get viewChartHorizontalBar => 'Horizontal bar chart';

  @override
  String get viewChartLine => 'Line chart';

  @override
  String get viewChartDonut => 'Donut chart';

  @override
  String viewUiResendMessage(Object value) {
    return 'The previous dsh-ui view couldn’t be displayed: $value. Fix it and resend.';
  }

  @override
  String viewUiBytesLimit(int first, int second) {
    String _temp0 = intl.Intl.pluralLogic(first, locale: localeName, other: '$first bytes', one: 'second byte');
    String _temp1 = intl.Intl.pluralLogic(second, locale: localeName, other: '$second bytes', one: 'second byte');
    return 'View is $_temp0, exceeding the limit of $_temp1';
  }

  @override
  String get viewUiEmptyCode => 'Code block is empty';

  @override
  String viewUiInvalidJson(String message) {
    return 'Invalid JSON ($message)';
  }

  @override
  String get viewUiJsonRepaired => 'Comments or trailing commas ignored';

  @override
  String get viewUiExpectedObject => 'Expected a component object';

  @override
  String viewUiDepthLimit(int first, int second) {
    return 'Depth $first exceeds the limit of $second';
  }

  @override
  String get viewUiMissingType => 'Missing type';

  @override
  String viewUiUnknownComponent(String value) {
    return 'Unknown component $value';
  }

  @override
  String viewUiAvailableTypes(String first, String second) {
    return '$first; available: $second';
  }

  @override
  String viewUiExpectedChildren(int limit) {
    return 'Expected an array of 1 to $limit components';
  }

  @override
  String viewUiHiddenItems(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count more items hidden',
      one: '1 more item hidden',
    );
    return 'Truncated: $_temp0';
  }

  @override
  String viewUiNodeLimit(int first, int second) {
    String _temp0 = intl.Intl.pluralLogic(
      first,
      locale: localeName,
      other: '$first components',
      one: 'second component',
    );
    String _temp1 = intl.Intl.pluralLogic(
      second,
      locale: localeName,
      other: '$second items truncated',
      one: 'second item truncated',
    );
    return 'Exceeded $_temp0; last $_temp1';
  }

  @override
  String viewUiChildLimit(int first, int second) {
    String _temp0 = intl.Intl.pluralLogic(first, locale: localeName, other: '$first items', one: 'second item');
    String _temp1 = intl.Intl.pluralLogic(
      second,
      locale: localeName,
      other: '$second items truncated',
      one: 'second item truncated',
    );
    return 'Exceeded $_temp0; last $_temp1';
  }

  @override
  String get viewUiExpectedString => 'Expected a string';

  @override
  String viewUiTextLimit(int first, int second) {
    String _temp0 = intl.Intl.pluralLogic(
      first,
      locale: localeName,
      other: '$first characters',
      one: 'second character',
    );
    return '$_temp0, exceeding the limit of $second';
  }

  @override
  String get viewUiTextTruncated => 'Truncated: text too long';

  @override
  String get viewUiExpectedFinite => 'Expected a finite number';

  @override
  String get viewUiYes => 'Yes';

  @override
  String get viewUiNo => 'No';

  @override
  String get viewUiExpectedStringNumber => 'Expected a string or number';

  @override
  String viewUiUnknownTone(String value) {
    return 'Unknown tone $value, ignored; available: good, warn, bad';
  }

  @override
  String viewUiUnknownChart(String value) {
    return 'Unknown chart $value, drawn as bars; available: bar, hbar, line, donut';
  }

  @override
  String get viewUiExpectedCategories => 'Expected a non-empty array of labels';

  @override
  String viewUiCategoryLimit(int first, int second) {
    String _temp0 = intl.Intl.pluralLogic(
      first,
      locale: localeName,
      other: '$first categories',
      one: 'second category',
    );
    return '$_temp0, exceeding the limit of $second';
  }

  @override
  String viewUiFirstPoints(int limit) {
    String _temp0 = intl.Intl.pluralLogic(limit, locale: localeName, other: '$limit points', one: '1 point');
    return 'Showing only the first $_temp0';
  }

  @override
  String viewUiExpectedSeries(String shape) {
    return 'Expected a non-empty array of $shape objects';
  }

  @override
  String get viewUiSkippedSeries => 'Expected an array of numbers; series skipped';

  @override
  String viewUiValuesCategories(int first, int second) {
    String _temp0 = intl.Intl.pluralLogic(first, locale: localeName, other: '$first values', one: 'second value');
    String _temp1 = intl.Intl.pluralLogic(
      second,
      locale: localeName,
      other: '$second categories',
      one: 'second category',
    );
    return '$_temp0 for $_temp1; extra values dropped, missing values left blank';
  }

  @override
  String viewUiNonFiniteValues(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count non-finite values',
      one: '1 non-finite value',
    );
    return '$_temp0 left blank';
  }

  @override
  String get viewUiNoSeries => 'No series to draw';

  @override
  String viewUiDonutSeries(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count other series ignored',
      one: '1 other series ignored',
    );
    return 'Donut chart uses one series; $_temp0';
  }

  @override
  String get viewUiFirstSeries => 'Drawing only the first series';

  @override
  String viewUiSeriesLimit(int first, int second) {
    String _temp0 = intl.Intl.pluralLogic(first, locale: localeName, other: '$first series', one: 'second series');
    return '$_temp0, exceeding the limit of $second';
  }

  @override
  String viewUiFirstSeriesCount(int limit) {
    String _temp0 = intl.Intl.pluralLogic(limit, locale: localeName, other: '$limit series', one: '1 series');
    return 'Showing only the first $_temp0';
  }

  @override
  String get viewUiNoFiniteValues => 'No finite values';

  @override
  String viewUiTruncated(String value) {
    return 'Truncated: $value';
  }

  @override
  String viewUiExpectedCompare(int limit, String shape) {
    return 'Expected an array of 2 to $limit $shape objects';
  }

  @override
  String viewUiItemLimit(int first, int second) {
    String _temp0 = intl.Intl.pluralLogic(first, locale: localeName, other: '$first items', one: 'second item');
    return '$_temp0, exceeding the limit of $second';
  }

  @override
  String viewUiFirstItems(int limit) {
    String _temp0 = intl.Intl.pluralLogic(limit, locale: localeName, other: '$limit items', one: '1 item');
    return 'Showing only the first $_temp0';
  }

  @override
  String viewUiSkippedCompare(String shape) {
    return 'Expected $shape; item skipped';
  }

  @override
  String get viewUiSkippedItemLabel => 'Expected a non-empty string; item skipped';

  @override
  String viewUiRowLimit(int first, int second) {
    String _temp0 = intl.Intl.pluralLogic(first, locale: localeName, other: '$first rows', one: 'second row');
    return '$_temp0, exceeding the limit of $second';
  }

  @override
  String get viewUiSkippedRow => 'Expected [name, value]; row skipped';

  @override
  String get viewUiNoItems => 'No items to draw';

  @override
  String viewUiFirstRows(int limit) {
    String _temp0 = intl.Intl.pluralLogic(limit, locale: localeName, other: '$limit rows', one: '1 row');
    return 'Showing only the first $_temp0 per item';
  }

  @override
  String viewUiExpectedSteps(String shape) {
    return 'Expected a non-empty array of $shape objects';
  }

  @override
  String viewUiStepLimit(int first, int second) {
    String _temp0 = intl.Intl.pluralLogic(first, locale: localeName, other: '$first steps', one: 'second step');
    return '$_temp0, exceeding the limit of $second';
  }

  @override
  String viewUiFirstSteps(int limit) {
    String _temp0 = intl.Intl.pluralLogic(limit, locale: localeName, other: '$limit steps', one: '1 step');
    return 'Truncated: showing only the first $_temp0';
  }

  @override
  String viewUiSkippedStep(String shape) {
    return 'Expected $shape; step skipped';
  }

  @override
  String viewUiUnknownStatus(String value) {
    return 'Unknown status $value, drawn as todo; available: done, current, todo, failed';
  }

  @override
  String get viewUiNoSteps => 'No steps to draw';

  @override
  String viewUiUnknownCalloutTone(String value) {
    return 'Unknown tone $value, drawn as info; available: info, good, warn, bad';
  }

  @override
  String viewUiExpectedOptions(int limit, String shape) {
    return 'Expected an array of 1 to $limit $shape options';
  }

  @override
  String viewUiOptionLimit(int first, int second) {
    String _temp0 = intl.Intl.pluralLogic(first, locale: localeName, other: '$first options', one: 'second option');
    return '$_temp0, exceeding the limit of $second';
  }

  @override
  String viewUiFirstOptions(int limit) {
    String _temp0 = intl.Intl.pluralLogic(limit, locale: localeName, other: '$limit options', one: '1 option');
    return 'Truncated: showing only the first $_temp0';
  }

  @override
  String viewUiDuplicateLabel(String value) {
    return 'Duplicate label $value; skipped';
  }

  @override
  String get viewUiNoOptions => 'No usable options';

  @override
  String viewUiSummaryBody(String value) {
    return '[View] $value';
  }

  @override
  String viewUiSummaryTitleBody(String first, String second) {
    return '[View] $first: $second';
  }

  @override
  String get viewUiSummaryInvalid => '[View] (formatting error, couldn’t display)';

  @override
  String viewUiSummaryText(String value) {
    return 'Text: $value';
  }

  @override
  String viewUiSummaryChart(String summary) {
    return 'Chart: $summary';
  }

  @override
  String viewUiSummaryCompare(String value) {
    return 'Compare: $value';
  }

  @override
  String viewUiSummarySteps(String value) {
    return 'Steps: $value';
  }

  @override
  String viewUiSummaryCallout(String value) {
    return 'Note: $value';
  }

  @override
  String viewUiSummaryOptions(String value) {
    return 'Options: $value';
  }

  @override
  String viewUiSummaryConfirm(String first, String second) {
    return 'Confirm: $first/$second';
  }

  @override
  String viewUiReplyChoice(String value) {
    return 'Select: $value';
  }

  @override
  String viewUiReplyConfirm(String value) {
    return 'Confirm: $value';
  }

  @override
  String viewUiReplyCancel(String value) {
    return 'Cancel: $value';
  }

  @override
  String viewUiReplyOther(String value) {
    return 'Other: $value';
  }

  @override
  String get viewUiFreeTextHint => 'Other (type your own)';

  @override
  String viewUiChosenOther(String value) {
    return 'Wrote: $value';
  }

  @override
  String viewUiChosen(String value) {
    return 'Selected: $value';
  }

  @override
  String get viewUiConfirmed => 'Confirmed';

  @override
  String viewUiConfirmedValue(String value) {
    return 'Confirmed: $value';
  }

  @override
  String viewUiCancelledValue(String value) {
    return 'Cancelled: $value';
  }

  @override
  String get viewUiReplied => 'Replied';

  @override
  String get viewUiGenerating => 'Generating view';

  @override
  String get viewUiReplyAfterEnd => 'Choose when the reply is complete';

  @override
  String get viewUiExpired => 'Expired';

  @override
  String get viewUiNotStarted => 'Not started';

  @override
  String get viewUiMultiple => 'Select multiple';

  @override
  String get viewSuggestWorkspace => 'Explore workspace';

  @override
  String get viewSuggestWorkspacePrompt =>
      'Check what files and projects are in the workspace and give me a brief overview.';

  @override
  String get viewSuggestWordCount => 'Write a script';

  @override
  String get viewSuggestWordCountPrompt =>
      'Write a Python script that finds the 20 most frequent words in a text file, then run it and show me the results.';

  @override
  String get viewSuggestNode => 'New project';

  @override
  String get viewSuggestNodePrompt =>
      'Create a Node.js project in the workspace with TypeScript and a minimal unit test.';

  @override
  String get viewSuggestGit => 'Explain Git';

  @override
  String get viewSuggestGitPrompt =>
      'Use a concrete example to explain the difference between git rebase and git merge, and when to use each.';

  @override
  String get viewSuggestWorkspaceHint => 'List files and projects';

  @override
  String get viewSuggestWordCountHint => 'Count words, then run it';

  @override
  String get viewSuggestNodeHint => 'Node.js with tests';

  @override
  String get viewSuggestGitHint => 'Rebase or merge?';

  @override
  String get viewTipNext => 'Next tip';

  @override
  String viewTipLabel(String value) {
    return 'Tip: $value';
  }

  @override
  String get viewTipSteer => 'While it works, long-press Send to steer, queue or interrupt';

  @override
  String get viewTipMidRun => 'You can message mid-run — it reads it at the next step';

  @override
  String get viewTipSlash => 'Type / for commands: compact the context, switch models and more';

  @override
  String get viewTipMention => 'Type @ to reference a workspace file or another chat';

  @override
  String get viewTipReplyMenu => 'Long-press a reply to copy, quote or regenerate it';

  @override
  String get viewTipEditResend => 'Long-press your own message to edit and resend — the original stays';

  @override
  String get viewTipQuote => 'Select part of a reply and tap Quote to ask about just that';

  @override
  String get viewTipTitleDetails => 'Tap the chat title for changes, files and a terminal';

  @override
  String get viewTipContextRing => 'The ring by Send shows context use — tap it for details';

  @override
  String get viewTipDrawerMenu => 'Long-press a chat in the sidebar to pin, rename or archive it';

  @override
  String get viewTipSearch => 'Where the host supports it, chat search matches message content, not just titles';

  @override
  String get viewTipSettingsSearch => 'Long-press Settings in the sidebar to search settings';

  @override
  String get viewTipQuickPanel => 'Swipe left on a chat to open the quick panel';

  @override
  String get viewTipFolderNewChat => 'Long-press a folder in the sidebar to start a chat inside it';

  @override
  String get viewTipSwitchHost => 'Tap the host name at the sidebar\'s foot to switch to DSH on your computer';

  @override
  String get viewTipPasteImage => 'Screenshots and stickers from your keyboard can go straight into the composer';

  @override
  String get viewTipLauncher => 'Long-press the app icon to ask by voice or start a new chat';

  @override
  String get viewTipPetBubble => 'When the pet pops a bubble, tap it to jump to the chat that\'s waiting';

  @override
  String get viewTipPetPlay => 'Tap the pet three times to tickle it; long-press to swap it';

  @override
  String get viewTipActivityStrip => 'While it works, tap the status strip to see this turn\'s full trace';

  @override
  String get viewTipImageZoom => 'In the image viewer, double-tap or pinch to zoom; long-press to save';

  @override
  String get viewTipQueuedRecall => 'A queued message can be pulled back into the composer to edit';

  @override
  String get viewTipKeyboard => 'With a keyboard: Ctrl+Enter sends, Esc twice stops';

  @override
  String get viewTipShareIn => 'Share text or images to DSH Go from another app to start a new chat with them';

  @override
  String get viewTipShareSelect => 'When sharing a chat, long-press and slide to pick several messages at once';

  @override
  String get viewTipChartDrag => 'Drag across a chart in a reply to read each point';

  @override
  String get viewTipCopyPath => 'Long-press a file in a changes card to copy its path';

  @override
  String get viewTipCompanion => 'The Companion Room lives in the Switch Host sheet';

  @override
  String get viewTipAnswerInline => 'When the AI asks you something, just type the answer in the composer';

  @override
  String get viewTipWallpaper => 'Wallpapers can be dragged, zoomed, blurred and dimmed';

  @override
  String get viewTipModelHere => 'Pick the model, preset and permissions right here — for this chat only';

  @override
  String get viewNewChatFolder => 'Folder';

  @override
  String get viewNewChatPresetTitle => 'Preset for this chat';

  @override
  String get viewNewChatPermissionTitle => 'Permissions for this chat';

  @override
  String get viewNewChatDefault => 'Default';

  @override
  String get viewNewChatUnavailable => 'Unavailable';

  @override
  String get viewNewChatChange => 'Change';

  @override
  String get viewNewChatModesFailed => 'Couldn’t set the preset or permissions. The message wasn’t sent.';

  @override
  String get viewGreetingMorning => 'Good morning';

  @override
  String get viewGreetingNoon => 'Good afternoon';

  @override
  String get viewGreetingAfternoon => 'Good afternoon';

  @override
  String get viewGreetingEvening => 'Good evening';

  @override
  String get viewGreetingNight => 'It’s late';

  @override
  String get viewEmptySubtitle => 'What would you like to do today?';

  @override
  String get viewEmptyStarting => 'Starting engine…';

  @override
  String get viewEmptyConnecting => 'Connecting to engine…';

  @override
  String get viewEmptyDisconnected => 'Engine not connected';

  @override
  String get viewEmptyReconnect => 'Reconnect';

  @override
  String viewEmptyWorkspace(String value) {
    return 'In “$value”';
  }

  @override
  String get viewEmptySwitchWorkspace => 'Switch workspace';

  @override
  String get viewEmptyHostDefaultDirectory => 'Host default folder';

  @override
  String get viewScheduleTitle => 'Automations';

  @override
  String get viewScheduleRefreshFailed => 'Couldn’t refresh';

  @override
  String get viewScheduleNone => 'No active automations';

  @override
  String viewScheduleNext(String value) {
    return 'Next $value';
  }

  @override
  String get viewScheduleUntitled => 'Untitled automation';

  @override
  String get viewScheduleSendFailed => 'Couldn’t send';

  @override
  String get viewScheduleEnded => 'Ended';

  @override
  String get viewScheduleUpcoming => 'Up next';

  @override
  String get viewScheduleSending => 'Sending…';

  @override
  String get viewScheduleRunNow => 'Run now';

  @override
  String get viewScheduleManage => 'Manage';

  @override
  String viewScheduleToday(String value) {
    return 'Today $value';
  }

  @override
  String viewScheduleTomorrow(String value) {
    return 'Tomorrow $value';
  }

  @override
  String viewScheduleYesterday(String value) {
    return 'Yesterday $value';
  }

  @override
  String viewScheduleWeekday(String first, String second) {
    return '$first $second';
  }

  @override
  String get viewScheduleDue => 'Due now';

  @override
  String viewScheduleDaysAhead(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count days', one: '1 day');
    return 'In $_temp0';
  }

  @override
  String viewScheduleDaysOverdue(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count days', one: '1 day');
    return '$_temp0 overdue';
  }

  @override
  String viewScheduleSingleLabel(String title) {
    return 'Automation: $title';
  }

  @override
  String viewScheduleCountLabel(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count automations', one: '1 automation');
    return '$_temp0';
  }

  @override
  String get viewModelSelect => 'Choose model';

  @override
  String get viewModelThinkingOff => 'Off';

  @override
  String get viewModelThinkingMinimal => 'Minimal';

  @override
  String get viewModelThinkingLow => 'Low';

  @override
  String get viewModelThinkingMedium => 'Medium';

  @override
  String get viewModelThinkingHigh => 'High';

  @override
  String get viewModelThinkingMax => 'Max';

  @override
  String viewModelLabel(String value) {
    return 'Model: $value';
  }

  @override
  String viewModelEffortLabel(String value) {
    return 'Thinking effort $value';
  }

  @override
  String get viewModelLoadFailed => 'Couldn’t load models';

  @override
  String get viewModelDisconnected => 'Engine not connected';

  @override
  String get viewModelConnectHint => 'Connect to choose a model';

  @override
  String get viewModelEffort => 'Thinking effort';

  @override
  String get viewModelKeyRequired => 'API key needed';

  @override
  String get viewModelProvidersHint => 'Supports DeepSeek and other model providers';

  @override
  String get viewModelEnterKey => 'Enter API key';

  @override
  String get viewModelAddProvider => 'Add provider';

  @override
  String get viewModelNone => 'No models available';

  @override
  String get viewModelKeyHint => 'Key may not be active or may have expired';

  @override
  String get viewModelManageProviders => 'Manage providers';

  @override
  String get viewContinuePrompt => 'Continue the chat attached here:';

  @override
  String viewContinueRange(int first, int second, int third) {
    String _temp0 = intl.Intl.pluralLogic(third, locale: localeName, other: '$third turns', one: '1 turn');
    return 'Turns $first–$second of $_temp0';
  }

  @override
  String viewContinueHeader(String value) {
    return '> Shared DSH Go chat · $value\n';
  }

  @override
  String get viewContinueUser => '\n## User\n\n';

  @override
  String viewImageCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count images', one: '1 image');
    return '$_temp0';
  }

  @override
  String viewContinueAttachments(String value) {
    return '\n(Attachments: $value)\n';
  }

  @override
  String get viewContinueAssistant => '\n## Assistant\n\n';

  @override
  String get viewContinueInterrupted => '\n(Reply interrupted)\n';

  @override
  String get viewContinueFailed => '(Failed)';

  @override
  String get viewContinueDeclined => '(Declined)';

  @override
  String get viewContinueCancelled => '(Cancelled)';

  @override
  String get viewLinkWeek => '7 days';

  @override
  String get viewLinkMonth => '30 days';

  @override
  String get viewLinkForever => 'Forever';

  @override
  String get viewShareChat => 'Chat';

  @override
  String get viewShareNoPermission => 'No storage permission. Couldn’t save.';

  @override
  String get viewShareOpenFailed => 'Couldn’t open share sheet';

  @override
  String get viewShareLinkFailed => 'Couldn’t create link. Try again later.';

  @override
  String viewShareLinkText(String first, String second) {
    return '“$first” · DSH Go chat\n$second';
  }

  @override
  String get viewShareEmpty => 'This chat has no content yet';

  @override
  String viewShareMessageCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count messages', one: '1 message');
    return '$_temp0';
  }

  @override
  String viewShareToolCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count tool calls', one: '1 tool call');
    return '$_temp0';
  }

  @override
  String get viewShareFileHint => 'Replay and continue in DSH Go';

  @override
  String get viewShareWebHint => 'Opens in any browser, even offline';

  @override
  String get viewShareMarkdownHint => 'Plain text, readable anywhere';

  @override
  String get viewShareLinkHint => 'End-to-end encrypted. The server can’t see your content.';

  @override
  String get viewSharePreview => 'Preview';

  @override
  String get viewShareWhole => 'Entire chat';

  @override
  String get viewShareScopeReply => 'This reply';

  @override
  String get viewShareScopePicked => 'Selected';

  @override
  String get viewShareThinking => 'Thinking';

  @override
  String get viewShareIncludeTools => 'Tool calls';

  @override
  String get viewShareChatFile => 'Chat file';

  @override
  String get viewShareWebPage => 'Web page';

  @override
  String get viewShareLink => 'Link';

  @override
  String get viewShareAsImage => 'Image';

  @override
  String get viewShareAsFile => 'File';

  @override
  String get viewShareAsText => 'Text';

  @override
  String get viewShareRedacted => 'Secrets hidden';

  @override
  String get viewShareAdjust => 'Edit';

  @override
  String viewShareTooLarge(int value) {
    return 'Over $value MB. Select fewer messages.';
  }

  @override
  String get viewShareCreateLink => 'Create link';

  @override
  String get viewShareStop => 'Stop sharing';

  @override
  String get viewShareStopTitle => 'Stop sharing?';

  @override
  String get viewShareStopped => 'Sharing stopped';

  @override
  String get viewQrCode => 'QR code';

  @override
  String viewShareTurn(int value) {
    return 'Turn $value';
  }

  @override
  String get viewReplayContinue => 'Continue chat';

  @override
  String viewReplayTurns(int first, int second) {
    return 'Turns $first–$second';
  }

  @override
  String viewReplaySeconds(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count sec', one: '1 sec');
    return '$_temp0';
  }

  @override
  String viewReplayMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count min', one: '1 min');
    return '$_temp0';
  }

  @override
  String get viewReplayFull => 'Full chat';

  @override
  String get viewReplayPause => 'Pause';

  @override
  String get viewReplayRestart => 'Replay';

  @override
  String get viewReplayPlay => 'Play';

  @override
  String viewReplaySpeed(int value) {
    return 'Speed $value×';
  }

  @override
  String get viewTemplatePaper => 'Paper';

  @override
  String get viewTemplateGlass => 'Glass';

  @override
  String get viewTemplateCard => 'Card';

  @override
  String get viewShareProjectQr => 'Project QR code';

  @override
  String get viewShareBrandLine => 'DSH on your phone · Scan to get it';

  @override
  String get viewShareBrandLineNoQr => 'DSH on your phone';

  @override
  String viewShareSteps(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count steps', one: '1 step');
    return '$_temp0';
  }

  @override
  String get viewShareWebSearch => 'Web search';

  @override
  String get viewShareOpenPage => 'Open web page';

  @override
  String get viewShareRunCommand => 'Run command';

  @override
  String get viewShareReadFile => 'View file';

  @override
  String get viewShareEditFile => 'Edit file';

  @override
  String get viewShareSubagent => 'Subagent';

  @override
  String get viewShareSkill => 'Use skill';

  @override
  String get viewSharePresentFiles => 'Present files';

  @override
  String get viewShareWorkflow => 'Workflow';

  @override
  String get viewSharePlugin => 'Call plugin';

  @override
  String get viewShareStars => 'Stars';

  @override
  String viewSharePluginTitle(String value) {
    return 'DSH plugin “$value”';
  }

  @override
  String viewShareInstallCommand(String value) {
    return 'Install: dsh plugin add $value';
  }

  @override
  String viewSharePhoneInstall(String value) {
    return 'Install on your phone: $value';
  }

  @override
  String get viewShareImages => 'Images';

  @override
  String get viewSharePickMessages => 'Select messages';

  @override
  String viewShareDoneCount(int count) {
    return 'Done ($count)';
  }

  @override
  String get viewShareImageMarker => '[Image]';

  @override
  String viewShareImagesMarker(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count images', one: '1 image');
    return '[$_temp0]';
  }

  @override
  String get viewShareYou => 'You';

  @override
  String get viewShareImageFailed => 'Couldn’t create image. Try again.';

  @override
  String get viewShareQuestion => 'Question';

  @override
  String get viewShareModelSteps => 'Model and steps';

  @override
  String get viewShareImagePreview => 'Share image preview';

  @override
  String get viewShareSaveImage => 'Save image';

  @override
  String viewScheduleHoursAhead(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count h', one: '1 h');
    return 'In $_temp0';
  }

  @override
  String viewScheduleHoursOverdue(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count h', one: '1 h');
    return '$_temp0 overdue';
  }

  @override
  String viewScheduleMinutesAhead(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count min', one: '1 min');
    return 'In $_temp0';
  }

  @override
  String viewScheduleMinutesOverdue(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count min', one: '1 min');
    return '$_temp0 overdue';
  }

  @override
  String viewScheduleSecondsAhead(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count sec', one: '1 sec');
    return 'In $_temp0';
  }

  @override
  String viewScheduleSecondsOverdue(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count sec', one: '1 sec');
    return '$_temp0 overdue';
  }

  @override
  String viewScheduleDate(String date, String clock) {
    return '$date $clock';
  }

  @override
  String viewScheduleYearDate(String year, String date, String clock) {
    return '$date, $year $clock';
  }

  @override
  String viewScheduleWeekdayName(String day) {
    String _temp0 = intl.Intl.selectLogic(day, {
      '1': 'Mon',
      '2': 'Tue',
      '3': 'Wed',
      '4': 'Thu',
      '5': 'Fri',
      '6': 'Sat',
      'other': 'Sun',
    });
    return '$_temp0';
  }

  @override
  String viewReplayDate(String month, int day) {
    String _temp0 = intl.Intl.selectLogic(month, {
      '1': 'Jan',
      '2': 'Feb',
      '3': 'Mar',
      '4': 'Apr',
      '5': 'May',
      '6': 'Jun',
      '7': 'Jul',
      '8': 'Aug',
      '9': 'Sep',
      '10': 'Oct',
      '11': 'Nov',
      '12': 'Dec',
      'other': '$month',
    });
    return '$_temp0 $day';
  }

  @override
  String viewReplayHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count h', one: '1 h');
    return '$_temp0';
  }

  @override
  String viewReplayHoursMinutes(int hours, int minutes) {
    String _temp0 = intl.Intl.pluralLogic(hours, locale: localeName, other: '$hours h', one: '1 h');
    String _temp1 = intl.Intl.pluralLogic(minutes, locale: localeName, other: '$minutes min', one: '1 min');
    return '$_temp0 $_temp1';
  }

  @override
  String viewUiHundredMillion(String value) {
    return '${value}B';
  }

  @override
  String viewUiTenThousand(String value) {
    return '${value}K';
  }

  @override
  String viewUiMillion(String value) {
    return '${value}M';
  }

  @override
  String get viewListSeparator => ', ';

  @override
  String get viewAttachmentSeparator => ', ';

  @override
  String viewUiInvalidJsonOffset(String message, int offset) {
    return 'Invalid JSON ($message, near character $offset)';
  }

  @override
  String get viewUiUnavailableChart => 'Can’t display chart';

  @override
  String get viewUiUnavailableMetric => 'Can’t display metric';

  @override
  String get viewUiUnavailableCompare => 'Can’t display comparison';

  @override
  String get viewUiUnavailableSteps => 'Can’t display steps';

  @override
  String get viewUiUnavailableCallout => 'Can’t display note';

  @override
  String get viewUiUnavailableOptions => 'Can’t display options';

  @override
  String get viewUiUnavailableConfirm => 'Can’t display confirmation';

  @override
  String get viewUiUnavailableText => 'Can’t display text';

  @override
  String get viewUiUnavailableGroup => 'Can’t display this group';

  @override
  String get viewUiUnavailablePart => 'Can’t display this section';

  @override
  String viewScheduleSingleNextLabel(String title, String when) {
    return 'Automation: $title, next $when';
  }

  @override
  String viewScheduleCountNextLabel(int count, String when) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count automations', one: '1 automation');
    return '$_temp0, next $when';
  }

  @override
  String get viewUiSkippedStepLabel => 'Expected a string; step skipped';

  @override
  String viewLabeledValue(String label, String value) {
    return '$label: $value';
  }

  @override
  String viewDescribedValue(String label, String description) {
    return '$label, $description';
  }

  @override
  String get viewSemicolonSeparator => '; ';

  @override
  String viewChartSemantics(String kind, String data) {
    return '$kind. $data';
  }

  @override
  String viewMetricSemantics(String label, String value) {
    return '$label $value';
  }

  @override
  String viewMetricCaptionSemantics(String label, String value, String caption) {
    return '$label $value, $caption';
  }

  @override
  String viewScheduleZone(String rule, String city, String offset) {
    return '$rule ($city · $offset)';
  }

  @override
  String viewContinueNotice(String text) {
    return '\n($text)\n';
  }

  @override
  String viewShareAltMarker(String alt) {
    return '[$alt]';
  }

  @override
  String get viewModelThinkingXhigh => 'Extra high';

  @override
  String viewUiDialectWebOnly(String kind) {
    return '$kind · View in DSH Web';
  }

  @override
  String get viewUiDialectKindInteractive => 'Interactive part';

  @override
  String get viewUiDialectKindChart => 'Chart';

  @override
  String get viewUiDialectKindDiagram => 'Diagram';

  @override
  String get viewUiDialectKindImage => 'Image';

  @override
  String get viewUiDialectKindAudio => 'Audio';

  @override
  String get viewUiDialectKindVideo => 'Video';

  @override
  String get viewUiDialectKindScene => '3D scene';

  @override
  String get viewUiDialectKindFiles => 'File tree';

  @override
  String get viewUiDialectKindMap => 'Map';

  @override
  String get viewUiDialectKindOther => 'This part';

  @override
  String get viewUiDialectInvalid => 'This block shows in DSH Web';

  @override
  String get viewUiDialectNote => 'Shown in DSH Web';

  @override
  String get voiceSettingsTitle => 'Voice';

  @override
  String get voiceModeAuto => 'Automatic';

  @override
  String get voiceModeSystem => 'System';

  @override
  String get voiceModeEngine => 'Voice model';

  @override
  String get voiceModeAutoHint =>
      'Uses DeepSeek when you’re signed in or have an API key, otherwise the voice model or the phone’s service';

  @override
  String get voiceModeSystemHint => 'Use the recognition service selected on this phone';

  @override
  String get voiceModeEngineHint => 'Recognizes speech with the engine’s voice model';

  @override
  String get voiceFallbackStarted => 'Switched to the voice model. Please speak again.';

  @override
  String get voiceChooseSystem => 'Select a speech recognition service in system settings';

  @override
  String get voiceConfigureEngine => 'Download the voice model in voice settings first';

  @override
  String get voiceConfigureEither => 'The phone’s service isn’t available. Download the voice model in voice settings.';

  @override
  String get voiceErrorNetworkTimeout => 'Speech recognition timed out. Check your connection.';

  @override
  String get voiceErrorNetwork => 'Speech recognition could not connect to the network';

  @override
  String get voiceErrorAudio => 'Audio recording failed. Check the microphone.';

  @override
  String get voiceErrorServer => 'The system speech service failed. Try again later.';

  @override
  String get voiceErrorClient => 'Could not start system recognition. Check the speech service.';

  @override
  String get voiceErrorSpeechTimeout => 'No speech was detected. Please speak again.';

  @override
  String get voiceErrorNoMatch => 'Didn’t catch that. Try again.';

  @override
  String get voiceErrorBusy => 'The system speech service is busy. Try again later.';

  @override
  String get voiceErrorPermission => 'Voice input needs microphone access';

  @override
  String get voiceErrorTooManyRequests => 'Too many speech requests. Try again later.';

  @override
  String get voiceErrorDisconnected => 'The system speech service disconnected';

  @override
  String get voiceErrorLanguageUnsupported => 'System recognition does not support this language';

  @override
  String get voiceErrorLanguageUnavailable => 'Download this language in the speech service first';

  @override
  String get voiceErrorSupportCheck => 'The speech service cannot check recognition support';

  @override
  String get voiceErrorDownloadEvents => 'The speech service cannot report model download progress';

  @override
  String voiceErrorUnknown(int code) {
    return 'Speech service error $code. Try another recognition service.';
  }

  @override
  String get voiceSettingsFailed => 'Couldn’t read speech settings. Try again.';

  @override
  String get voiceModeSection => 'Recognition';

  @override
  String get voiceModelSection => 'Voice model';

  @override
  String get voiceModelFooter =>
      'Once downloaded, Chinese, English, Cantonese, Japanese and Korean are recognized on the phone; recordings stay on it.';

  @override
  String get voiceModelWaiting => 'Available once the engine is running';

  @override
  String get voiceModelUnsupported => 'This engine has no voice model';

  @override
  String get voiceModelAbsent => 'Not downloaded';

  @override
  String get voiceModelDownloading => 'Downloading';

  @override
  String get voiceModelPreparing => 'Checking and loading';

  @override
  String get voiceModelReady => 'Ready';

  @override
  String get voiceModelFailed => 'Download failed';

  @override
  String voiceModelBytes(String done, String total) {
    return '$done of $total';
  }

  @override
  String voiceModelReadyNote(String size) {
    return 'Uses $size; works offline';
  }

  @override
  String voiceModelAbsentNote(String size) {
    return 'About $size to download';
  }

  @override
  String get voiceModelWaitingNote => 'The download starts once the engine is running';

  @override
  String get voiceModelFailNetwork => 'Couldn’t reach the download source';

  @override
  String get voiceModelFailTimeout => 'The download stopped making progress';

  @override
  String get voiceModelFailCertificate => 'Secure connection failed; check the phone’s date';

  @override
  String get voiceModelFailServer => 'The download source is unavailable for now';

  @override
  String get voiceModelFailIntegrity => 'The files didn’t pass verification';

  @override
  String voiceModelFailStorage(String size) {
    return 'Not enough storage; about $size more is needed';
  }

  @override
  String get voiceModelFailEngine => 'The engine didn’t respond';

  @override
  String get voiceModelFailUnknown => 'The download didn’t finish';

  @override
  String get voiceModelDownload => 'Download';

  @override
  String get voiceModelResume => 'Resume';

  @override
  String get voiceModelRedownload => 'Re-download';

  @override
  String get voiceModelMeteredTitle => 'Download over mobile data?';

  @override
  String voiceModelMeteredBody(String size) {
    return 'The voice model is about $size and will use mobile data.';
  }

  @override
  String get voiceModelDeleteTitle => 'Delete the voice model?';

  @override
  String get voiceModelDeleteBody =>
      'Voice input will use the phone’s service. You can download the model again any time.';

  @override
  String get voiceModelDeleteFailed => 'Couldn’t delete the voice model. Try again.';

  @override
  String get voiceModelDeleteStopping => 'The download is still stopping. Delete again in a moment.';

  @override
  String voiceModelStartedToast(String size) {
    return 'Downloading the voice model · about $size';
  }

  @override
  String voiceModelResumedToast(String size) {
    return 'Resuming the voice model · about $size left';
  }

  @override
  String get voiceModelReadyToast => 'Voice input is ready';

  @override
  String voiceModelFailedToast(String reason) {
    return 'Voice model download failed: $reason';
  }

  @override
  String voiceModelNoticeDownloading(int percent) {
    return 'Downloading the voice model $percent%';
  }

  @override
  String get voiceModelNoticePreparing => 'Checking the voice model';

  @override
  String get voiceModelNoticeFailed => 'Voice model download failed. Open the app to retry.';

  @override
  String get voiceModeDeepseek => 'DeepSeek';

  @override
  String get voiceModeDeepseekHint => 'DeepSeek’s recognizer, paid by your signed-in account or API key';

  @override
  String get voiceModeCloud => 'Another cloud service';

  @override
  String get voiceModeCloudHint => 'An OpenAI-compatible transcription API, such as Whisper or SiliconFlow';

  @override
  String get voiceCloudSection => 'Cloud recognition service';

  @override
  String get voiceCloudFooter => 'Recordings are sent to this service. The key stays on this phone.';

  @override
  String get voiceCloudBaseHelper => 'Up to /v1; the app calls …/audio/transcriptions';

  @override
  String get voiceCloudModelHelper => 'For example whisper-1 or FunAudioLLM/SenseVoiceSmall';

  @override
  String get voiceScribeReadFailed => 'Could not read voice settings. Retry.';

  @override
  String get voiceScribeSavedReadFailed => 'Saved. Refresh to see the latest settings.';

  @override
  String get voiceScribeSaveUnconfirmed => 'Couldn’t confirm the save. Refresh or retry.';

  @override
  String get voiceScribeTitle => 'Voice settings';

  @override
  String get voiceScribePolishPrompt => 'Polish prompt';

  @override
  String get voiceScribeLanguage => 'Recognition language';

  @override
  String get voiceScribeRefresh => 'Refresh';

  @override
  String get voiceScribeHostChanged => 'The connection changed. Reopen to continue.';

  @override
  String get voiceScribeUnsupported => 'Voice settings aren’t available on this connection.';

  @override
  String get voiceScribePluginDefault => 'Default';

  @override
  String get voiceScribeBuiltInPrompt => 'Built-in prompt';

  @override
  String get voiceScribeProviders => 'Recognition services';

  @override
  String get voiceScribeKeySet => 'Key set';

  @override
  String get voiceScribeNoKey => 'No key';

  @override
  String get voiceScribeHotwords => 'Hotwords';

  @override
  String voiceScribeHotwordRules(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count rules', one: '1 rule');
    return '$_temp0';
  }

  @override
  String get wallpaperTitle => 'Wallpaper';

  @override
  String get wallpaperDefault => 'Default';

  @override
  String get wallpaperCustom => 'Custom';

  @override
  String get wallpaperFrame => 'Reposition';

  @override
  String get wallpaperBlur => 'Blur';

  @override
  String get wallpaperLighten => 'Lighten';

  @override
  String get wallpaperDim => 'Dim';

  @override
  String get wallpaperReplace => 'Replace picture';

  @override
  String get wallpaperPreview => 'Preview';

  @override
  String get wallpaperFooter =>
      'Shown on home, in chats and in the drawer. Lighten applies in light mode, Dim in dark mode; text always stays clear. PNG, JPEG or WebP, up to 15 MB.';

  @override
  String get wallpaperChanged => 'Wallpaper changed';

  @override
  String get wallpaperTooLarge => 'The picture is over 15 MB';

  @override
  String get wallpaperUnsupported => 'Use a PNG, JPEG or WebP';

  @override
  String get wallpaperUnreadable => 'Couldn’t read this picture';

  @override
  String get wallpaperUnavailable => 'Couldn’t open your photos';

  @override
  String get wallpaperBroken => 'Can’t be read';

  @override
  String get wallpaperEditorHint => 'Drag or pinch';

  @override
  String get wallpaperEditorReset => 'Reset';

  @override
  String get wallpaperSampleTitle => 'A weekend by the sea';

  @override
  String get wallpaperSampleStatus => 'Just now';

  @override
  String get wallpaperSampleQuestion => 'Is Saturday a good day for the beach?';

  @override
  String get wallpaperSampleAnswer =>
      'Yes. Saturday afternoon is sunny with a light breeze and waves under half a metre, the best day this week.';

  @override
  String get wallpaperSampleNote => 'It cools down fast in the evening, so bring a light jacket.';

  @override
  String get wallpaperSampleTool => 'Checked 3 weather sources';

  @override
  String get searchKwWallpaper => 'background,background image,chat background,custom background,backdrop,blur,photo';

  @override
  String get webTitle => 'DSH Web';

  @override
  String get webSshAppOnly => 'SSH tunnel links only open in the app';

  @override
  String get webRelayUnavailable => 'DSH Web isn’t available through DSH Remote. Open it on that computer.';

  @override
  String get webSshHost => 'SSH host';

  @override
  String get webLocalAppOnly => 'This phone’s link has a launch token and only opens in the app';

  @override
  String get webEngineStatus => 'Engine status';

  @override
  String get webEngineStarting => 'Starting engine';

  @override
  String get webEngineStartFailed => 'Couldn’t start the engine';

  @override
  String get webEngineNotRunning => 'Engine isn’t running';

  @override
  String get webEngineProblem => 'The engine ran into a problem';

  @override
  String get webStartingSoon => 'DSH Web will be ready in a moment';

  @override
  String get webStartToOpen => 'Start this phone’s engine to open DSH Web';

  @override
  String get webRestart => 'Restart';

  @override
  String get webStartEngine => 'Start engine';

  @override
  String get webSwitchToWeb => 'Switch to Web';

  @override
  String get webNativeFeatures => 'Native features';

  @override
  String get webSwitchToNative => 'Switch to native';

  @override
  String get webAppSettings => 'App settings';

  @override
  String get webSwitchHost => 'Switch host';

  @override
  String get webAttachmentTooLarge => 'Attachment is too large for DSH Web';

  @override
  String get webTextCopied => 'Text copied. Paste it into the input box.';

  @override
  String get webAttachmentFailed => 'Couldn’t add attachments to DSH Web';

  @override
  String get webHostUnavailable => 'DSH Web isn’t available on this host';

  @override
  String get webChatGone => 'This chat is gone';

  @override
  String get webPageClosed => 'Page closed';

  @override
  String get webChatsWorkspaces => 'Chats and workspaces';

  @override
  String get webRefresh => 'Refresh';

  @override
  String get webOpenInBrowser => 'Open in browser';

  @override
  String get webBrowserUnavailable => 'Can’t open in browser';

  @override
  String get webReopen => 'Reopen';

  @override
  String get webPageNotOpened => 'Couldn’t open the page';

  @override
  String get webCheckConnection => 'Check your network or engine status and try again';

  @override
  String get webTargetSessionMissing => 'Couldn’t find this chat in DSH Web. You’re on the home page.';

  @override
  String get webTargetNotLoaded => 'DSH Web hasn’t finished loading';

  @override
  String get webTargetSettingsMissing => 'Couldn’t find these settings. You may need to sign in or enable the plugin.';

  @override
  String get webTargetPluginMissing => 'Couldn’t find this plugin. It may be missing from this profile.';

  @override
  String get webTargetSidebarFailed => 'Couldn’t open the sidebar. Open this chat in DSH Web and try again.';

  @override
  String get webTargetCordisMissing => 'Couldn’t find the Cordis panel. The plugin may have been removed.';

  @override
  String get webTargetNewChatFailed => 'Couldn’t start a chat. You’re on the DSH Web home page.';

  @override
  String get webTargetPageFailed => 'Couldn’t open this page. You’re on the DSH Web home page.';

  @override
  String webConnectHostFirst(String name) {
    return 'Connect to “$name” to open DSH Web';
  }

  @override
  String get workshopTitle => 'Workshop';

  @override
  String get workshopSubtitle => 'Pets and companions made by others. Install the ones you like';

  @override
  String get workshopEntrySubtitle => 'Find pets and companions made by others';

  @override
  String get workshopTabBrowse => 'Browse';

  @override
  String get workshopTabMine => 'My uploads';

  @override
  String get workshopKindAll => 'All';

  @override
  String get workshopKindPet => 'Pixel pets';

  @override
  String get workshopKindCompanion => 'Companions';

  @override
  String get workshopSearchHint => 'Search by name or author';

  @override
  String get workshopGet => 'Get';

  @override
  String get workshopRefresh => 'Refresh';

  @override
  String workshopByAuthor(String author) {
    return 'By $author';
  }

  @override
  String get workshopEmptyTitle => 'Nothing here yet';

  @override
  String get workshopEmptyMessage =>
      'No one has uploaded anything. If you made a pet or a companion, yours can be the first.';

  @override
  String get workshopNoMatchTitle => 'No matches';

  @override
  String get workshopNoMatchMessage => 'Try another name or author.';

  @override
  String get workshopUnavailableTitle => 'The Workshop can\'t be opened right now';

  @override
  String get workshopNotOpenTitle => 'The Workshop isn\'t open yet';

  @override
  String get workshopNotOpenMessage => 'This version isn\'t connected to a Workshop service.';

  @override
  String workshopShowingOlder(String when) {
    return 'Couldn\'t refresh. Showing what was fetched $when.';
  }

  @override
  String get workshopLocalUnknown =>
      'Couldn\'t read what is installed on this phone, so the Installed marks may be wrong.';

  @override
  String get workshopStatVersion => 'Version';

  @override
  String get workshopStatSize => 'Size';

  @override
  String get workshopStatLicense => 'License';

  @override
  String get workshopAbout => 'About';

  @override
  String get workshopNoDescription => 'The author didn\'t write a description.';

  @override
  String get workshopSource => 'Source';

  @override
  String workshopMinApp(String version) {
    return 'Needs DSH Go $version or later.';
  }

  @override
  String workshopInstalledVersion(String version) {
    return 'Installed $version';
  }

  @override
  String workshopUpdateTo(String version) {
    return 'Update to $version';
  }

  @override
  String get workshopInstalledWithdrawn =>
      'The version you installed has been withdrawn. It still works; update if a newer version is listed, otherwise consider removing it.';

  @override
  String get workshopPhasePreparing => 'Getting ready…';

  @override
  String get workshopPhaseDownloading => 'Downloading';

  @override
  String get workshopPhaseVerifying => 'Verifying…';

  @override
  String get workshopPhaseCancelling => 'Cancelling…';

  @override
  String workshopProgressBytes(String received, String total) {
    return '$received / $total';
  }

  @override
  String get workshopInstallDone => 'Installed';

  @override
  String get workshopInstallDonePet => 'Installed. Pick it on the Pets page.';

  @override
  String get workshopInstallDoneCompanion => 'Installed. She\'s in the Companion room.';

  @override
  String get workshopInstallDoneRefreshIssue =>
      'Installed, but the list couldn\'t refresh. Open this page again to see it.';

  @override
  String get workshopInstallCancelled => 'Cancelled. Nothing on this phone was changed.';

  @override
  String get workshopInstallBusy => 'Another install or removal is still running. Try again when it finishes.';

  @override
  String get workshopReplaceTitle => 'Replace what\'s on this phone?';

  @override
  String workshopReplaceMessage(String title) {
    return 'This phone already has something with the same name that didn\'t come from this Workshop entry. Continuing replaces it with \"$title\", and the old one can\'t be brought back.';
  }

  @override
  String get workshopReplaceConfirm => 'Replace';

  @override
  String get workshopReport => 'Report';

  @override
  String get workshopErrorNetwork => 'No connection. Try again later.';

  @override
  String get workshopErrorTimeout => 'No response in time. Try again later.';

  @override
  String get workshopErrorServer => 'The Workshop service has a problem right now. Try again later.';

  @override
  String get workshopErrorRateLimited => 'Too many requests. Try again in a while.';

  @override
  String get workshopErrorBadData => 'The Workshop sent something unexpected, so it wasn\'t used. Try again later.';

  @override
  String get workshopErrorCatalogChanged => 'This item just changed. Refresh and look again.';

  @override
  String get workshopErrorNotFound => 'This item can\'t be found. It may have been taken down.';

  @override
  String get workshopErrorWithdrawn => 'This version has been withdrawn and can\'t be installed.';

  @override
  String get workshopErrorMinApp => 'This app is too old. Update it to install this.';

  @override
  String get workshopErrorUnsupported => 'This version of the app doesn\'t know this kind of item.';

  @override
  String get workshopErrorCompanionOff => 'Companion items are turned off for now.';

  @override
  String get workshopErrorUploadOff => 'The Workshop isn\'t taking uploads right now.';

  @override
  String get workshopErrorNoSpace => 'Not enough storage on this phone. Free some up and try again.';

  @override
  String get workshopErrorStorage => 'Couldn\'t read or write files on this phone.';

  @override
  String get workshopErrorIntegrity =>
      'The download didn\'t match what was registered, so it was discarded. Try again.';

  @override
  String get workshopErrorDowngrade => 'The version on this phone is newer and won\'t be replaced with an older one.';

  @override
  String get workshopErrorRuntimeMissing =>
      'Invite a character in the Companion room first. Then other companions can be installed.';

  @override
  String get workshopErrorReadersBusy =>
      'She\'s in use. Leave the Companion room or close the floating window, then try again.';

  @override
  String get workshopErrorInstallRecord => 'The install record on this phone doesn\'t match, so nothing was changed.';

  @override
  String get workshopErrorOtherOrigin => 'This was installed from a different Workshop.';

  @override
  String get workshopErrorSignIn => 'Sign in with GitHub first.';

  @override
  String get workshopErrorConsent => 'Agree to let the Workshop check your sign-in first.';

  @override
  String get workshopErrorAccountMismatch =>
      'The account you signed in with isn\'t the kind this Workshop uses. Sign in again.';

  @override
  String get workshopErrorAccountDown => 'Couldn\'t confirm who you are with GitHub right now. Try again later.';

  @override
  String get workshopErrorPreferences => 'Couldn\'t save the record on this phone, so this step didn\'t continue.';

  @override
  String get workshopErrorBusy => 'The previous step is still running. One moment.';

  @override
  String get workshopErrorCancelled => 'Cancelled.';

  @override
  String get workshopErrorUnknownResult =>
      'It\'s unclear whether that went through. Refresh and check before trying again.';

  @override
  String get workshopErrorGeneric => 'That didn\'t work. Try again later.';

  @override
  String get workshopDisclosureTitle => 'Let the Workshop confirm your GitHub identity';

  @override
  String get workshopDisclosureLead =>
      'To submit, manage your submissions or report something, the Workshop needs to know who you are. To find out, your GitHub sign-in credential is sent to the Workshop service below, which asks GitHub which account it belongs to.';

  @override
  String get workshopDisclosureWorker => 'Workshop that receives the credential';

  @override
  String get workshopDisclosureAccount => 'Account service that confirms who you are';

  @override
  String get workshopDisclosureUse =>
      'It is sent when you submit, view or withdraw your submissions, or report something. The Workshop only uses it to confirm your identity with GitHub and does not keep it.';

  @override
  String get workshopDisclosureKept =>
      'The credential stays on this phone, which also remembers that you agreed to these two addresses. If either changes, you\'ll be asked again.';

  @override
  String get workshopDisclosureStale => 'The addresses just changed. Please confirm the ones shown now.';

  @override
  String get workshopDisclosureAccept => 'Agree and continue';

  @override
  String get workshopDisclosureDecline => 'Not now';

  @override
  String get workshopDisclosureUnsaved =>
      'Your consent counts for now, but it couldn\'t be saved on this phone. You may be asked again.';

  @override
  String get workshopSignInTitle => 'Sign in with GitHub';

  @override
  String get workshopSignInLead =>
      'The Workshop knows authors by their GitHub account. This sign-in can only read your public profile (username and account number), not your repositories.';

  @override
  String get workshopSignInPreparing => 'Getting a code from GitHub…';

  @override
  String get workshopSignInSteps =>
      'Enter this code on GitHub\'s verification page and authorize, then come back here.';

  @override
  String get workshopSignInOpen => 'Copy and open GitHub';

  @override
  String get workshopSignInCopied => 'Code copied';

  @override
  String get workshopSignInWaiting => 'Waiting for you to authorize on GitHub…';

  @override
  String get workshopSignInExpired => 'The code expired.';

  @override
  String get workshopSignInDenied => 'You cancelled the authorization on GitHub.';

  @override
  String get workshopSignInNetwork => 'Can\'t reach GitHub. Check the connection and try again.';

  @override
  String get workshopSignInUnconfigured => 'This Workshop hasn\'t set up GitHub sign-in yet.';

  @override
  String get workshopSignInAgain => 'Get a new code';

  @override
  String workshopAccountLine(String login) {
    return 'GitHub account $login';
  }

  @override
  String get workshopAccountSignOut => 'Sign out';

  @override
  String get workshopAccountSignedOut =>
      'Signed out. To withdraw the authorization completely, revoke it under Applications in your GitHub settings.';

  @override
  String get workshopAccountSignOutFailed => 'Couldn\'t sign out. Try again later.';

  @override
  String get workshopInstalledEmptyTitle => 'Nothing from the Workshop yet';

  @override
  String get workshopInstalledEmptyMessage => 'Pets and companions you get in Browse show up here.';

  @override
  String get workshopInstalledEmptyAction => 'Browse';

  @override
  String get workshopInstalledLoadFailedTitle => 'Can\'t read what\'s installed';

  @override
  String get workshopInstalledLoadStale => 'Couldn\'t read this phone again. Showing the last result.';

  @override
  String get workshopInstalledCatalogStale => 'Update and withdrawal info may be out of date.';

  @override
  String get workshopInstalledCatalogUnknown => 'Update and withdrawal info isn\'t available right now.';

  @override
  String get workshopInstalledStatusUpdate => 'Update available';

  @override
  String get workshopInstalledStatusWithdrawn => 'This version was withdrawn';

  @override
  String get workshopInstalledStatusOtherOrigin => 'From a different Workshop';

  @override
  String get workshopInstalledStatusNotListed => 'Not in the Workshop right now';

  @override
  String get workshopInstalledStatusCompanionOff => 'Companion items are off for now';

  @override
  String get workshopInstalledStatusRewritten => 'Differs from the same version in the Workshop';

  @override
  String get workshopInstalledStatusRemoving => 'Uninstalling…';

  @override
  String get workshopInstalledStatusRemoveFailed => 'Couldn\'t uninstall';

  @override
  String get workshopInstalledStatusRemoved => 'Uninstalled';

  @override
  String get workshopInstalledIssueBroken => 'This pack is damaged';

  @override
  String get workshopInstalledIssueUnreadable => 'This pack can\'t be read';

  @override
  String get workshopInstalledIssueRecord => 'Install record doesn\'t match';

  @override
  String get workshopInstalledIssueOther => 'Something is wrong with this item';

  @override
  String get workshopInstalledNoteBroken => 'This pack is damaged and may not work.';

  @override
  String get workshopInstalledNoteUnreadable => 'Couldn\'t read this pack\'s files.';

  @override
  String get workshopInstalledNoteRecord => 'Its install record doesn\'t match.';

  @override
  String get workshopInstalledNoteOther => 'Something is wrong with this item, and nothing more can be read.';

  @override
  String get workshopInstalledNoteUntrusted =>
      'Its install record can\'t be trusted, so it can\'t be uninstalled from here.';

  @override
  String get workshopInstalledNoteOtherOrigin =>
      'This came from a different Workshop, so its updates can\'t be checked here.';

  @override
  String get workshopInstalledNoteNotListed =>
      'The Workshop doesn\'t list it right now. The copy on this phone isn\'t affected.';

  @override
  String get workshopInstalledNoteRewritten =>
      'The same version in the Workshop has different contents. The copy on this phone wasn\'t changed.';

  @override
  String get workshopInstalledNoteMinApp => 'The version now in the Workshop needs a newer app.';

  @override
  String get workshopInstalledNoteUnavailable => 'The version now in the Workshop can\'t be installed right now.';

  @override
  String get workshopInstalledNoteGone => 'This item is no longer on this phone.';

  @override
  String get workshopInstalledNoteUnread =>
      'The install records on this phone can\'t be read right now. This is what was there a moment ago.';

  @override
  String workshopInstalledRemoveFailed(String reason) {
    return 'Couldn\'t uninstall. $reason';
  }

  @override
  String get workshopInstalledFactKind => 'Kind';

  @override
  String get workshopInstalledFactId => 'Item ID';

  @override
  String get workshopInstalledFactOrigin => 'From';

  @override
  String get workshopInstalledFactLocalId => 'Local ID';

  @override
  String workshopInstalledRemoveTitle(String title) {
    return 'Uninstall \"$title\"?';
  }

  @override
  String get workshopInstalledRemoveMessage =>
      'This deletes the copy on this phone. To use it again, get it from the Workshop again.';

  @override
  String get workshopInstalledRemoveNoReinstall =>
      'The Workshop doesn\'t list it right now, so you may not be able to get it back.';

  @override
  String get workshopInstalledRemovedRefreshIssue =>
      'Uninstalled, but the list couldn\'t refresh. Pull down to refresh it.';

  @override
  String get workshopInstalledRemovedLocalIssue =>
      'Uninstalled, but some places didn\'t catch up. Reopen the app to bring them up to date.';

  @override
  String get workshopInstalledDismissFailure => 'Got it';

  @override
  String get workshopMinePublish => 'Submit';

  @override
  String get workshopMinePublishHint => 'Shows up in Discover once approved';

  @override
  String get workshopMineSignInTitle => 'Submissions belong to a GitHub account';

  @override
  String get workshopMineSignInMessage => 'Sign in to see what you have sent in.';

  @override
  String get workshopMineConsentTitle => 'One more step';

  @override
  String get workshopMineConsentMessage =>
      'The workshop checks who you are with your GitHub sign-in. Agree to that to see your submissions.';

  @override
  String get workshopMineConsentAction => 'See details';

  @override
  String get workshopMineEmptyTitle => 'No submissions yet';

  @override
  String get workshopMineEmptyMessage => 'Made a pet or a companion? Send it in for others to use.';

  @override
  String get workshopMineEmptyFiltered => 'Nothing with this status';

  @override
  String get workshopMineLoadFailed => 'Couldn\'t load your submissions';

  @override
  String get workshopMineStale => 'Couldn\'t get the latest. Showing what was loaded before.';

  @override
  String get workshopMineLoadMore => 'Load more';

  @override
  String get workshopMineStatusPending => 'In review';

  @override
  String get workshopMineStatusApproved => 'Approved';

  @override
  String get workshopMineStatusRejected => 'Rejected';

  @override
  String get workshopMineStatusWithdrawn => 'Withdrawn';

  @override
  String get workshopMineStatusDraft => 'Draft';

  @override
  String get workshopMineDetailTitle => 'Submission';

  @override
  String get workshopMineRefreshOne => 'Refresh this one';

  @override
  String get workshopMineAboutPending => 'Sent and waiting for review. It shows up in Discover once approved.';

  @override
  String get workshopMineAboutApproved => 'Approved. Whether it is public right now is what Discover shows.';

  @override
  String get workshopMineAboutRejected => 'Not approved.';

  @override
  String get workshopMineAboutWithdrawn => 'Withdrawn. This can\'t be undone.';

  @override
  String get workshopMineAboutDraft => 'The file hasn\'t finished uploading, so it isn\'t in review.';

  @override
  String get workshopMineReviewReason => 'Reviewer\'s note';

  @override
  String get workshopMineWithdrawReason => 'Reason for withdrawing';

  @override
  String get workshopMineWithdrawReasonHint => 'For example: wrong file, want to change it first';

  @override
  String get workshopMineCreatedAt => 'Submitted';

  @override
  String get workshopMineUpdatedAt => 'Last updated';

  @override
  String get workshopMineDetailStale => 'Couldn\'t refresh this one. Showing the status loaded before.';

  @override
  String get workshopMineAccountChanged => 'The account has changed';

  @override
  String get workshopMineAccountChangedMessage =>
      'This submission belongs to the previous account and is no longer shown.';

  @override
  String get workshopMineWithdraw => 'Withdraw';

  @override
  String get workshopMineWithdrawConfirmTitle => 'Withdraw this submission?';

  @override
  String workshopMineWithdrawConfirmMessage(String title) {
    return 'This can\'t be undone. If \"$title\" is already public, nobody will be able to download this version, and the same version number can\'t be published again.';
  }

  @override
  String get workshopMineWithdrawConfirm => 'Withdraw';

  @override
  String get workshopMineWithdrawing => 'Withdrawing…';

  @override
  String get workshopMineWithdrawDone => 'Submission withdrawn';

  @override
  String get workshopMineWithdrawUnknown =>
      'Not sure whether it was withdrawn. Check the result first; don\'t withdraw again yet.';

  @override
  String get workshopMineWithdrawQuery => 'Check result';

  @override
  String get workshopMineWithdrawStill => 'It hasn\'t been withdrawn. You can withdraw it again if you still want to.';

  @override
  String get workshopMineWithdrawReconciled => 'It is withdrawn now.';

  @override
  String get workshopMineReasonEmpty => 'Write a reason first.';

  @override
  String workshopMineReasonTooLong(String max) {
    return 'At most $max characters. This is too long.';
  }

  @override
  String get workshopMineReasonBadChars => 'It contains characters that can\'t be used. Remove them and try again.';

  @override
  String get workshopMineReasonRejected => 'This reason wasn\'t accepted. Change it and try again.';

  @override
  String workshopReportTarget(String title, String version) {
    return '$title · $version';
  }

  @override
  String get workshopReportReason => 'Reason';

  @override
  String get workshopReportReasonHint => 'What\'s wrong with it, e.g. infringement or unsuitable content';

  @override
  String get workshopReportNote =>
      'A reviewer will look at this report. Reporting doesn\'t take the item down by itself.';

  @override
  String get workshopReportSubmit => 'Send report';

  @override
  String get workshopReportSending => 'Sending…';

  @override
  String get workshopReportDone => 'Report received. A reviewer will look at it.';

  @override
  String get workshopReportSignInTitle => 'Reporting needs a GitHub account';

  @override
  String get workshopReportSignInMessage => 'Sign in to send a report.';

  @override
  String get workshopReportConsentMessage =>
      'The workshop checks who you are with your GitHub sign-in. Agree to that to report.';

  @override
  String get workshopReportUnknownTitle => 'Not sure it arrived';

  @override
  String get workshopReportUnknownMessage =>
      'The last report may or may not have been received, and there is no way to check. Sending again could create a duplicate.';

  @override
  String workshopReportUnknownOther(String id, String version) {
    return 'That report was about $id $version.';
  }

  @override
  String get workshopReportUnknownAgain => 'I understand, write it again';

  @override
  String get workshopPublishTitle => 'Submit';

  @override
  String get workshopPublishClosedTitle => 'The Workshop isn\'t taking submissions right now';

  @override
  String get workshopPublishClosedMessage => 'What you already sent is still under My uploads.';

  @override
  String get workshopPublishSignInTitle => 'Sign in with GitHub first';

  @override
  String get workshopPublishSignInMessage => 'The Workshop uses your GitHub account to know who is submitting.';

  @override
  String get workshopPublishProfileTitle => 'Couldn\'t read your GitHub account yet';

  @override
  String get workshopPublishProfileMessage => 'Submitting needs to know which account you are.';

  @override
  String get workshopPublishCheckFailedTitle => 'Couldn\'t read the record of your last submission';

  @override
  String get workshopPublishCheckLocked => 'To avoid sending something twice, a new one can\'t start until it is read.';

  @override
  String get workshopPublishWaitingPrevious => 'The previous step is still finishing.';

  @override
  String get workshopPublishChooseTitle => 'Choose what to submit';

  @override
  String get workshopPublishCompanionCurrent => 'Your current companion';

  @override
  String get workshopPublishSourcesEmptyTitle => 'Nothing to submit yet';

  @override
  String get workshopPublishSourcesEmptyMessage =>
      'Pixel pets you imported and your current companion can be submitted, or pick a file directly.';

  @override
  String get workshopPublishFromFile => 'Choose a file';

  @override
  String get workshopPublishFromFileHint => 'A pet or companion zip; no need to import it first';

  @override
  String get workshopPublishTitleEnHelper => 'Optional; the Chinese name is used if empty';

  @override
  String get workshopPublishAuthorHelper => 'Optional; your GitHub username is used if empty';

  @override
  String get workshopPublishLicenseHelper => 'Optional; Author permission if none is picked';

  @override
  String get workshopPublishSourcesIssue => 'Couldn\'t read what can be submitted from this phone.';

  @override
  String get workshopPublishPetsIssue => 'Couldn\'t read the pixel pets on this phone.';

  @override
  String get workshopPublishCompanionIssue => 'Couldn\'t read the companion on this phone.';

  @override
  String get workshopPublishNoCompanion =>
      'There\'s no companion on this phone yet. Invite one in the Companion room first.';

  @override
  String get workshopPublishSectionSource => 'What to submit';

  @override
  String get workshopPublishChange => 'Change';

  @override
  String get workshopPublishSectionNames => 'Name';

  @override
  String get workshopPublishTitleZh => 'Chinese name';

  @override
  String get workshopPublishTitleEn => 'English name';

  @override
  String get workshopPublishSectionInfo => 'Details';

  @override
  String get workshopPublishId => 'Item ID';

  @override
  String get workshopPublishIdHelper => 'Optional; made from the name if empty. Lowercase letters, digits and hyphens';

  @override
  String get workshopPublishAuthor => 'Author';

  @override
  String get workshopPublishLicenseAuthor => 'Author permission';

  @override
  String get workshopPublishSourceLink => 'Source link';

  @override
  String get workshopPublishSourceHelper => 'Optional; your GitHub page is used if empty. Starts with https://';

  @override
  String get workshopPublishSectionAbout => 'About (optional)';

  @override
  String get workshopPublishTags => 'Tags';

  @override
  String get workshopPublishTagsHelper => 'Separate with commas, up to 8';

  @override
  String get workshopPublishNext => 'Next';

  @override
  String get workshopPublishPreparing => 'Packing…';

  @override
  String get workshopPublishBadTitle => 'Enter a name, up to 120 characters';

  @override
  String get workshopPublishBadId => 'Lowercase letters, digits and hyphens only, up to 40 characters';

  @override
  String get workshopPublishBadVersion => 'Write a version like 1.0.0';

  @override
  String get workshopPublishBadAuthor => 'Enter an author, up to 256 characters';

  @override
  String get workshopPublishBadLicense => 'Choose a license';

  @override
  String get workshopPublishBadSource => 'Enter a link starting with https://';

  @override
  String get workshopPublishBadDescription => 'Up to 512 characters';

  @override
  String get workshopPublishBadTags => 'Up to 8 tags of 32 characters each, with no repeats';

  @override
  String get workshopPublishBadRights => 'Confirm that you have the right to share this first';

  @override
  String get workshopPublishFiles => 'Files in the package';

  @override
  String get workshopPublishEdit => 'Edit details';

  @override
  String get workshopPublishRights => 'I confirm I have the right to share this';

  @override
  String get workshopPublishReviewNote => 'The Workshop reviews it first. Others see it once it is approved.';

  @override
  String get workshopPublishSubmit => 'Submit';

  @override
  String get workshopPublishPhaseWorking => 'Working…';

  @override
  String get workshopPublishPhaseUploading => 'Uploading';

  @override
  String get workshopPublishPhaseWaiting => 'All sent. Waiting for the Workshop…';

  @override
  String get workshopPublishStay => 'Leaving this page won\'t interrupt it.';

  @override
  String get workshopPublishDoneTitle => 'Sent to the Workshop, waiting for review';

  @override
  String get workshopPublishDoneMessage => 'Follow it under My uploads.';

  @override
  String get workshopPublishBackToMine => 'Back to My uploads';

  @override
  String get workshopPublishApprovedTitle => 'This submission has been approved';

  @override
  String get workshopPublishApprovedMessage => 'Whether it is listed is what Browse shows.';

  @override
  String get workshopPublishRejectedTitle => 'This submission wasn\'t approved';

  @override
  String get workshopPublishWithdrawnTitle => 'This submission was withdrawn';

  @override
  String workshopPublishReason(String reason) {
    return 'Reason: $reason';
  }

  @override
  String get workshopPublishAgain => 'Submit again';

  @override
  String get workshopPublishAgainMessage => 'Fix it and you can submit it again.';

  @override
  String get workshopPublishRecordKept => 'The result is confirmed, but the record on this phone couldn\'t be cleared.';

  @override
  String get workshopPublishLeftovers => 'Temporary files left on this phone couldn\'t be removed.';

  @override
  String get workshopPublishPendingTitle => 'One submission isn\'t finished';

  @override
  String get workshopPublishPendingMessage =>
      'It didn\'t finish last time. Continuing sends the same content on, without creating a second one.';

  @override
  String get workshopPublishPendingLocked =>
      'Its details are fixed for now: they can\'t be edited or swapped for something else. Once the problem is solved you can continue.';

  @override
  String get workshopPublishPendingUnsent =>
      'This one hasn\'t been sent yet. You can continue once the problem is solved, or go back to edit it or pick something else.';

  @override
  String get workshopPublishEditUnsent => 'Go back and edit';

  @override
  String get workshopPublishUnknownTitle => 'Not sure whether it was sent';

  @override
  String get workshopPublishUnknownMessage =>
      'The Workshop didn\'t answer, so the result isn\'t known. Checking asks again about the same submission: if it arrived it isn\'t repeated, and if it didn\'t it carries on.';

  @override
  String get workshopPublishContinue => 'Continue';

  @override
  String get workshopPublishCheckResult => 'Check result';

  @override
  String get workshopPublishCheckAgain => 'Check again';

  @override
  String get workshopPublishErrorInvalid => 'A few details need fixing.';

  @override
  String get workshopPublishErrorMismatch => 'The package doesn\'t match the details you entered. Please try again.';

  @override
  String get workshopPublishErrorPending => 'Another submission isn\'t finished. Deal with it first.';

  @override
  String get workshopPublishErrorTooLarge => 'The package is larger than the Workshop accepts.';

  @override
  String get workshopPublishErrorMetadata => 'The Workshop didn\'t accept these details. Change them and try again.';

  @override
  String get workshopPublishErrorNotReady => 'Not ready yet. Try again in a moment.';

  @override
  String get workshopPublishErrorAgain => 'It can\'t be submitted again right now.';

  @override
  String get workshopPublishSectionPreview => 'Preview';

  @override
  String get workshopPublishPreviewSwitch => 'Show a preview in the Workshop';

  @override
  String get workshopPublishPreviewIdle => 'The first frame of the idle animation';

  @override
  String get workshopPublishSectionCover => 'Cover (optional)';

  @override
  String get workshopPublishCoverPick => 'Choose a cover';

  @override
  String get workshopPublishCoverHelper =>
      'PNG, up to 512 px a side and 2 MB. Without one, the first letter of the name is shown.';

  @override
  String get workshopPublishCoverChosen => 'Your cover';

  @override
  String get workshopPublishCoverReplace => 'Replace';

  @override
  String get workshopPublishCoverRemove => 'Remove';

  @override
  String get workshopPublishCoverBadSize => 'This image is empty or larger than 2 MB. Try another.';

  @override
  String get workshopPublishCoverBadPng => 'This isn\'t an intact PNG image. Try another.';

  @override
  String get workshopPublishCoverBadDimensions =>
      'This image is too large: 512 px a side at most. Shrink it and choose again.';

  @override
  String get workshopPublishCoverUnreadable => 'Couldn\'t read this image. Try another.';

  @override
  String get workshopPublishReviewPreviewIdle => 'First idle frame';

  @override
  String get workshopPublishReviewPreviewNone => 'No preview';

  @override
  String get workshopPublishErrorPreviewPet =>
      'This pet\'s frame is larger than 512 px, so it can\'t have a preview. Turn the preview off to submit as usual.';

  @override
  String get workshopPublishErrorPreviewConflict =>
      'The companion\'s package already has a preview.png, so the cover can\'t be added. Remove the cover to submit as usual.';

  @override
  String get workshopPublishErrorPreviewMissing =>
      'The preview to use wasn\'t found. Choose it again, or submit without one.';

  @override
  String get workshopPublishErrorPreviewUnsupported =>
      'This Workshop isn\'t taking previews right now. Submit without one as usual.';

  @override
  String get workshopPublishLetGo => 'Let go of this record';

  @override
  String get workshopPublishLetGoTitle => 'Let go of this phone\'s record?';

  @override
  String workshopPublishLetGoAccount(String worker) {
    return 'Only this phone\'s unfinished record for this GitHub account at Workshop $worker is removed.';
  }

  @override
  String workshopPublishLetGoAll(String worker) {
    return 'The submission records on this phone can\'t be read as a whole. Letting go removes the unfinished-submission records of every account on this phone, not just the one for this GitHub account at Workshop $worker.';
  }

  @override
  String get workshopPublishLetGoFacts =>
      'The Workshop isn\'t told to cancel: if it already received this submission, it stays there and shows under My uploads. If it didn\'t, you\'ll need to submit again, and if it did arrive after all there will be two.';

  @override
  String get workshopPublishLetGoFactsKnown =>
      'The Workshop isn\'t told to cancel: its result stays as it is, and this submission is still under My uploads.';

  @override
  String get workshopPublishLetGoConfirm => 'Let go';

  @override
  String get workshopPublishLetGoDone => 'This phone\'s record was let go';

  @override
  String get workshopPublishLetGoStale => 'The record just changed. Tap again to confirm it anew.';

  @override
  String get workshopPublishLetGoUnsupported => 'This version can\'t let go of the record here.';

  @override
  String get workspaceRecoveryTitle => 'Workspace index recovery';

  @override
  String get workspaceRecoveryEnable => 'Use a recovery workspace index';

  @override
  String get workspaceRecoveryDisable => 'Use the original index again';

  @override
  String get workspaceRecoveryHint =>
      'This phone only: use a separate index to access readable conversations when the original workspace index fails.';

  @override
  String get workspaceRecoveryActive =>
      'The separate recovery index is selected. Both the original and recovery indexes are retained.';

  @override
  String get workspaceRecoveryWorking => 'Working…';

  @override
  String get workspaceRecoveryEnableBody =>
      'The local engine will stop, switch to a separate recovery index, and start again. The original workspace index stays untouched. Conversation files, plugins, and credentials are not deleted.\n\nOn first use, the new index is built from readable conversations whose folders still exist. Old workspace names, order, defaults, archived state, and pins are not inherited automatically. Empty workspaces and conversations with missing folders may not appear. Original local grouping and pin preferences are retained.\n\nThe recovery index is retained and reused the next time you enable it. This bypasses the original index failure; it does not repair the original index.';

  @override
  String get workspaceRecoveryDisableBody =>
      'The local engine will stop, switch back to the original workspace index, and start again. The original failure may return.\n\nConversation files created during recovery and the recovery index are both retained. Workspace membership and order do not sync between the two indexes. Some conversations created during recovery may not appear with the original index. Enable the recovery index again to continue using it.';

  @override
  String get workspaceRecoveryEnableStart => 'Enable and restart';

  @override
  String get workspaceRecoveryDisableStart => 'Use original and restart';

  @override
  String get workspaceRecoveryUnavailable =>
      'This version does not support workspace index recovery. Check the local engine status and update the app.';

  @override
  String get workspaceRecoveryRestartIncomplete =>
      'The index mode changed, but the engine has not been confirmed stopped or restarted. Wait for it to stop before starting it again.';

  @override
  String get workspaceRecoverySaveFailed =>
      'The index mode could not be saved. No new start was requested. Check the local engine status and logs.';

  @override
  String get workspaceRecoveryFailed =>
      'The operation did not finish. Check the local engine status and logs. This page shows whether the index mode changed.';
}
