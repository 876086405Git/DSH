// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class L10nZh extends L10n {
  L10nZh([String locale = 'zh']) : super(locale);

  @override
  String get a11yRestoreTitle => '自动恢复无障碍';

  @override
  String get searchKwA11yRestore => '无障碍,恢复,重连,自动恢复,掉线,授权,ADB,Shizuku,Sui,root';

  @override
  String get a11yRestoreNeedsGrant => '需要授权';

  @override
  String get a11yRestoreNotice => '开启后，在系统设置里关掉无障碍会被自动打开；要关闭手机操控，请在 DSH Go 里关。';

  @override
  String get a11yRestoreForceStop => '被强制停止后，重新打开 DSH Go 才能恢复。';

  @override
  String get a11yRestoreGrant => '授权并开启';

  @override
  String get a11yRestoreGrantShizuku => '通过 Shizuku 授予';

  @override
  String get a11yRestoreGrantShizukuPermission => '先授权 Shizuku，再授予权限';

  @override
  String get a11yRestoreGrantAdb => '通过自连 ADB 授予';

  @override
  String get a11yRestoreRootNote => '通过已授权的 root 连接，只授予这一项权限。';

  @override
  String get a11yRestoreSetup => '配置 Shizuku 或无线调试';

  @override
  String get a11yRestoreWaiting => '请在 Shizuku 中允许授权';

  @override
  String get a11yRestoreWaitingSui => '请在 Sui 中允许授权';

  @override
  String get a11yRestoreComputer => '也可以连接电脑，执行一次：';

  @override
  String get a11yRestoreCopy => '复制授权命令';

  @override
  String get a11yRestoreCopied => '授权命令已复制';

  @override
  String get accessPickTitle => '想让 DSH Go 帮你做哪些事';

  @override
  String get accessPickMessage => '选好后逐项开启';

  @override
  String get accessPickConfirm => '开启所选';

  @override
  String get accessSkip => '跳过';

  @override
  String get accessFeatureFiles => '读写手机里的文件';

  @override
  String get accessFeatureFilesNeeds => '需要文件访问权限';

  @override
  String get accessFeaturePet => '桌宠与悬浮窗';

  @override
  String get accessFeaturePetNeeds => '需要悬浮窗权限';

  @override
  String get accessFeaturePhone => '手机操控';

  @override
  String get accessFeaturePhoneNeeds => '需要无障碍和通知权限';

  @override
  String get accessFeatureBackground => '后台持续运行';

  @override
  String get accessFeatureBackgroundNeeds => '任务跑完通知你，需要通知和后台权限';

  @override
  String get accessFeatureVoice => '语音输入';

  @override
  String get accessFeatureVoiceNeeds => '需要麦克风权限';

  @override
  String get accessFeatureAlerts => '回复提醒';

  @override
  String get accessFeatureAlertsNeeds => '需要通知权限';

  @override
  String accessVoiceModel(int size) {
    return '离线识别，需下载约 $size MB 语音模型';
  }

  @override
  String get accessVoiceMetered => '当前是移动数据，下载会消耗流量';

  @override
  String get accessFilesRiskBody => 'AI 能读取和修改相册、下载、文档等手机文件。';

  @override
  String accessStepCount(int index, int total) {
    return '$index / $total';
  }

  @override
  String get accessTurnOn => '去开启';

  @override
  String get accessOpenSettings => '去设置';

  @override
  String get accessItsSet => '设好了';

  @override
  String get accessOpenAgain => '再去一次';

  @override
  String get accessIsOn => '已开启';

  @override
  String get accessNotOnYet => '还没开启';

  @override
  String get accessDidYouSet => '在那一页打开了吗？';

  @override
  String accessWhere(String path) {
    return '位置：$path';
  }

  @override
  String get accessOpenFailed => '没能打开系统设置';

  @override
  String get accessMicTitle => '允许使用麦克风';

  @override
  String get accessMicWhy => '语音输入要用到';

  @override
  String get accessStorageTitle => '允许访问文件';

  @override
  String get accessStorageWhy => '让 AI 读写相册、下载和文档';

  @override
  String get accessNotifyTitle => '允许通知';

  @override
  String get accessNotifyWhy => '任务跑完、需要确认时提醒你';

  @override
  String get accessBatteryTitle => '允许在后台运行';

  @override
  String get accessBatteryWhy => '切到别的 App 时任务照常跑';

  @override
  String get accessVendorBackgroundWhy => '锁屏或切走后，不被系统断网、清理';

  @override
  String get accessAutostartTitle => '允许自启动';

  @override
  String get accessAutostartWhy => '被系统清理后能自己恢复';

  @override
  String accessVivoAutostartPath(String app) {
    return '权限管理 › 自启动 › $app';
  }

  @override
  String accessXiaomiAutostartPath(String app) {
    return '应用管理 › $app › 自启动';
  }

  @override
  String get accessA11yTitle => '打开无障碍';

  @override
  String get accessA11yWhy => '手机操控靠它看屏幕、点按';

  @override
  String get accessPopupTitle => '允许后台弹出界面';

  @override
  String get accessPopupWhy => '手机操控做完能回到 DSH Go';

  @override
  String accessVivoPopupPath(String app) {
    return '权限管理 › $app › 后台弹出界面';
  }

  @override
  String accessXiaomiPopupPath(String app) {
    return '应用管理 › $app › 其他权限 › 后台弹出界面';
  }

  @override
  String get accessOverlayTitle => '允许显示在其他应用上层';

  @override
  String get accessOverlayWhy => '宠物才能出现在别的 App 上';

  @override
  String get accessOverlayGreyed => '开关是灰的？';

  @override
  String get accessRestrictedTitle => '先允许受限制的设置';

  @override
  String get accessRestrictedTap => '在无障碍里点一下「DSH 手机操控」，出现「受限制的设置」时点确定';

  @override
  String get accessRestrictedMenu => '在应用信息里点右上角的三个点，选「允许受限制的设置」';

  @override
  String get accessRestrictedAdvanced => '在应用信息的「高级设置」里打开「允许受限制的设置」';

  @override
  String get accessRestrictedBack => '回到无障碍，打开「DSH 手机操控」';

  @override
  String get accessRestrictedHelp => '看图示';

  @override
  String get accessOpenA11y => '去无障碍';

  @override
  String get accessOpenAppInfo => '去应用信息';

  @override
  String get accessStateOn => '已开启';

  @override
  String get accessStateOff => '未开启';

  @override
  String get accessStateVisited => '已去设置';

  @override
  String get accessStateUnknown => '去设置';

  @override
  String get accessSummaryAllSet => '都开好了';

  @override
  String accessSummaryLeft(int count) {
    return '还有 $count 项没开';
  }

  @override
  String get accessSummaryMessage => '随时可在「设置 › 通用 › 系统权限」补开';

  @override
  String get accessFinishFailed => '没能完成设置';

  @override
  String accessVoiceDownload(int size) {
    return '语音模型（约 $size MB）会在引擎就绪后开始下载，进度在「设置 › 通用 › 语音输入」里查看';
  }

  @override
  String get accessPageTitle => '系统权限';

  @override
  String get accessPageSubtitle => '各项功能用到的系统权限';

  @override
  String get activityThinkingUntangle => '嗯…让我捋捋';

  @override
  String get activityThinkingWorkThrough => '盘一下盘一下';

  @override
  String get activityThinkingGears => '大脑转起来了';

  @override
  String get activityThinkingSecond => '给我一秒';

  @override
  String get activityThinkingSmoking => '脑子在冒烟';

  @override
  String get activityThinkingOnIt => '想呢想呢';

  @override
  String get activityThinkingNoRush => '别催别催';

  @override
  String get activityThinkingPonder => '让我琢磨下';

  @override
  String get activityThinkingLogic => '正在盘逻辑';

  @override
  String get activityThinkingBrain => '小脑瓜动一下';

  @override
  String get activityThinkingSort => '让我理理';

  @override
  String get activityThinkingMemory => '翻翻脑子';

  @override
  String get activityThinkingStorm => '脑内风暴中';

  @override
  String get activityThinkingSavor => '嗯…让我品品';

  @override
  String get activityThinkingMoment => '稍等，在想';

  @override
  String get activityThinkingHeadScratch => '挠头…';

  @override
  String get activityThinkingPlayOut => '让子弹飞一会';

  @override
  String get activityThinkingLoading => '思路加载中';

  @override
  String get activityThinkingMulling => '琢磨中';

  @override
  String get activityThinkingBreakDown => '嗯…让我拆一下';

  @override
  String get activityThinkingTrain => '脑内跑火车';

  @override
  String get activityThinkingSomething => '嗯…有点东西';

  @override
  String get activityThinkingJog => '小跑一下思路';

  @override
  String get activityThinkingPicture => '等下，有画面了';

  @override
  String get activityThinkingBubbles => '思考泡泡';

  @override
  String get activityThinkingWaves => '脑电波传输中';

  @override
  String get activityThinkingCoffee => '脑子在煮咖啡';

  @override
  String get activityThinkingDraft => '我打个腹稿';

  @override
  String get activityThinkingComing => '嗯，来了来了';

  @override
  String get activityThinkingBubbling => '脑子冒泡泡';

  @override
  String get activityThinkingTackle => '嗯…盘它';

  @override
  String get activityThinkingSpark => '闪个思路';

  @override
  String get activityThinkingLogicFirst => '先捋一下逻辑';

  @override
  String get activityThinkingLocate => '定位一下';

  @override
  String get activityThinkingInvestigate => '排查一下';

  @override
  String get activityThinkingGif => '思考.gif';

  @override
  String get activityThinkingLook => '让我康康';

  @override
  String get activityThinkingInteresting => '嗯…有点意思';

  @override
  String get activityThinkingHands => '搓搓手想想';

  @override
  String get activityThinkingFiveMinutes => '5 分钟，大工程';

  @override
  String get activityThinkingSerious => '这把我得认真';

  @override
  String get activityThinkingTricky => '确实有点绕';

  @override
  String get activityThinkingAscend => '我在修仙';

  @override
  String get activityThinkingAlmostPromise => '快好了，真的';

  @override
  String get activityThinkingLongWay => '盘了一大圈';

  @override
  String get activityThinkingWrapping => '在收尾了';

  @override
  String get activityThinkingSong => '给我一首歌的时间';

  @override
  String get activityThinkingBigMove => '憋大招中';

  @override
  String get activityThinkingSimple => '这个需求很简单（不是）';

  @override
  String get activityThinkingOneMinute => '1 分钟，还在想';

  @override
  String get activityThinkingChallenge => '这题有点东西';

  @override
  String get activityThinkingDig => '让我再钻研下';

  @override
  String get activityThinkingNotSimple => '问题不简单';

  @override
  String get activityThinkingDeep => '盘得有点深';

  @override
  String get activityThinkingBurning => '脑细胞在燃烧';

  @override
  String get activityThinkingNearlyClear => '快盘清了';

  @override
  String get activityThinkingTwisty => '这个有点绕…';

  @override
  String get activityThinkingWorkout => '烧脑中…';

  @override
  String get activityThinkingStay => '别走，快了';

  @override
  String get activityThinkingCloser => '嗯，让我细想想';

  @override
  String get activityThinkingThirtySeconds => '30 秒了，还在盘';

  @override
  String get activityThinkingSoon => '别急，快出结果了';

  @override
  String get activityThinkingAnotherPass => '让我再捋一捋';

  @override
  String get activityThinkingTrack => '思路没断';

  @override
  String get activityThinkingLead => '有眉目了';

  @override
  String get activityThinkingCircles => '转圈圈…';

  @override
  String get activityThinkingAnyMoment => '马上马上';

  @override
  String get activityThinkingStillLocate => '还在定位';

  @override
  String get activityWaitingCall => '呼叫模型…';

  @override
  String get activityWaitingOnWay => '模型在路上了';

  @override
  String get activityWaitingSpeak => '等它开口…';

  @override
  String get activityWaitingWords => '它在组织语言';

  @override
  String get activityWaitingAwake => '模型醒了么';

  @override
  String get activityWaitingStretch => '等它伸懒腰';

  @override
  String get activityWaitingYawn => '它打了个哈欠';

  @override
  String get activityWaitingComing => '模型：来了来了';

  @override
  String get activityWaitingText => '等它出字';

  @override
  String get activityWaitingQueue => '还在排队';

  @override
  String get activityWaitingBrew => '它在酝酿';

  @override
  String get activityWaitingWater => '模型在喝水';

  @override
  String get activityWaitingWarmup => '等它热身';

  @override
  String get activityWaitingMeditate => '模型在冥想';

  @override
  String get activityWaitingBlink => '等它眨个眼';

  @override
  String get activityWaitingMoment => '它说稍等';

  @override
  String get activityWritingWords => '组织语言中';

  @override
  String get activityWritingTyping => '码字中';

  @override
  String get activityWritingInspired => '下笔如有神';

  @override
  String get activityWritingOnIt => '在写了在写了';

  @override
  String get activityWritingCareful => '字斟句酌';

  @override
  String get activityWritingFlow => '一气呵成';

  @override
  String get activityWritingPlain => '整理成人话';

  @override
  String get activityWritingIdeas => '把想法写下来';

  @override
  String get activityWritingKeys => '敲字中';

  @override
  String get activityWritingAlmost => '马上写完';

  @override
  String get activityWritingTell => '娓娓道来';

  @override
  String get activityWritingFast => '奋笔疾书';

  @override
  String get activityWritingBreeze => '笔下生风';

  @override
  String get activityWritingFormat => '排个版';

  @override
  String get activityNightAscend => '修仙中…';

  @override
  String get activityNightHello => '深夜冒泡';

  @override
  String get activityNightOwl => '你也是夜猫子呀';

  @override
  String get activityNightMoon => '月亮不睡我不睡';

  @override
  String get activityNightSlow => '夜里脑子慢，谅解';

  @override
  String get activityNightChampion => '熬夜冠军上线';

  @override
  String get activityNightSleepy => '困了，但能行';

  @override
  String get activityNightMidnight => '过了零点照样肝';

  @override
  String get activityNightOpen => '深夜档营业';

  @override
  String get activityNightStars => '星星都睡了';

  @override
  String get activityNightDawn => '凌晨还在盘';

  @override
  String get activityWeekendChill => '周末摸鱼中';

  @override
  String get activityWeekendHere => '周末也在！';

  @override
  String get activityWeekendCompany => '放假也陪你';

  @override
  String get activityWeekendOnline => '周末不关机';

  @override
  String get activityWeekendSneak => '周末偷着盘';

  @override
  String get activityWeekendWorking => '周末也在卷？';

  @override
  String get activityWeekendMode => '周末模式 ON';

  @override
  String get activityWeekendBugs => '周末在修 bug';

  @override
  String get activityWeekendSkin => '周末限定皮肤';

  @override
  String get activityNewYearCheers => '新年快乐！';

  @override
  String get activityNewYearDay => '元旦快乐';

  @override
  String get activityNewYearBugs => '新的一年，新的 bug';

  @override
  String get activityNewYearFirstLine => '新年第一行代码';

  @override
  String get activityNewYearWork => '开工大吉';

  @override
  String get activityValentineCode => '情人节也在敲代码';

  @override
  String get activityValentineLove => '代码才是真爱';

  @override
  String get activityValentineDate => '今天不约会？';

  @override
  String get activityValentineKeyboard => '键盘就是玫瑰';

  @override
  String get activityPiDay => 'π 节快乐';

  @override
  String get activityPiCircle => '今天的圆格外圆';

  @override
  String get activityAprilFools => '愚人节快乐';

  @override
  String get activityAprilBug => '这个 bug 是假的吧';

  @override
  String get activityAprilErrors => '小心假报错';

  @override
  String get activityAprilKidding => '骗你的，没报错';

  @override
  String get activityLaborWorking => '劳动节还在卷';

  @override
  String get activityLaborPride => '劳动最光荣';

  @override
  String get activityLaborSpirit => '打工人打工魂';

  @override
  String get activityChildrenDay => '儿童节快乐';

  @override
  String get activityChildrenHeart => '谁还不是个宝宝';

  @override
  String get activityChildrenCode => '今天代码要写得可爱';

  @override
  String get activityProgrammerCheers => '1024 程序员节快乐';

  @override
  String get activityProgrammerDay => '今天是程序员节';

  @override
  String get activityProgrammer1024 => '1024，节日快乐';

  @override
  String get activityProgrammerCode => '程序员节也在写代码';

  @override
  String get activityHalloween => '万圣节快乐';

  @override
  String get activityHalloweenTreat => '不给糖就捣蛋';

  @override
  String get activityHalloweenCode => '代码也会吓人';

  @override
  String get activityChristmasEve => '平安夜快乐';

  @override
  String get activityChristmasEveThinking => '平安夜也在盘';

  @override
  String get activityChristmasEveGift => '今晚写代码有礼物';

  @override
  String get activityChristmas => '圣诞快乐';

  @override
  String get activityChristmasCompany => '圣诞也陪你';

  @override
  String get activityChristmasEgg => '圣诞限定彩蛋';

  @override
  String get activityChristmasReindeer => '麋鹿送代码来了';

  @override
  String get activityYearEndEve => '跨年夜';

  @override
  String get activityYearEndLast => '今年最后一盘';

  @override
  String get activityYearEndReady => '准备跨年';

  @override
  String get activityYearEndSeeYou => '明年见！';

  @override
  String get activityZodiacRat => '鼠';

  @override
  String get activityZodiacOx => '牛';

  @override
  String get activityZodiacTiger => '虎';

  @override
  String get activityZodiacRabbit => '兔';

  @override
  String get activityZodiacDragon => '龙';

  @override
  String get activityZodiacSnake => '蛇';

  @override
  String get activityZodiacHorse => '马';

  @override
  String get activityZodiacGoat => '羊';

  @override
  String get activityZodiacMonkey => '猴';

  @override
  String get activityZodiacRooster => '鸡';

  @override
  String get activityZodiacDog => '狗';

  @override
  String get activityZodiacPig => '猪';

  @override
  String get activityLunarCheers => '春节快乐！';

  @override
  String get activityLunarCode => '过年还在写代码';

  @override
  String get activityLunarEnvelope => '红包拿来';

  @override
  String get activityLunarSpring => '新春快乐';

  @override
  String get activityLunarGreeting => '过年好';

  @override
  String get activityLunarCodeGreeting => '代码也拜个年';

  @override
  String get activityRareSsr => 'SSR！稀有彩蛋';

  @override
  String get activityRareUr => 'UR 掉落';

  @override
  String get activityRareLegend => '金色传说！';

  @override
  String get activityRareOrange => '出橙了';

  @override
  String get activityRareEgg => '彩蛋砸脸';

  @override
  String get activityRareChosen => '天选时刻';

  @override
  String get activityRareHidden => '你发现了隐藏款';

  @override
  String get activityRareChat => '触发隐藏对话';

  @override
  String get activityRareMax => '稀有度 MAX';

  @override
  String get activityRareLucky => '欧皇降临';

  @override
  String get activityRareCritical => '暴击了';

  @override
  String get activityRareNextLevel => '这波在大气层';

  @override
  String get activityFailCrash => '翻车了';

  @override
  String get activityFailOops => '哎呀';

  @override
  String get activityFailRun => '没跑通';

  @override
  String get activityFailTrip => '摔了一跤';

  @override
  String get activityFailWrong => '这不对';

  @override
  String get activityFailHiccup => '出岔子了';

  @override
  String get activityFailBroken => '不灵了';

  @override
  String get activityFailLocal => '我本地能跑啊';

  @override
  String get activityFailYesterday => '昨天还能跑';

  @override
  String get activityFailTough => '难绷';

  @override
  String get activityFailCrack => '裂开';

  @override
  String get activityFailPressure => '血压上来了';

  @override
  String get activityFailCareless => '这波大意了';

  @override
  String get activityFailSlip => '手滑';

  @override
  String get activityFailTryAgain => '换个姿势再来';

  @override
  String get activityFailChance => '再给我一次机会';

  @override
  String get activityTestGreen => '测试全绿';

  @override
  String get activityTestAllGreen => '全绿，舒服';

  @override
  String get activityTestFirstTry => '一次过！';

  @override
  String get activityTestNoErrors => '没报错';

  @override
  String get activityTestPassed => '过了过了';

  @override
  String get activityTestSolid => '稳了';

  @override
  String get activityTestRed => '红了，看看哪挂了';

  @override
  String get activityTestInvestigate => '测试挂了，排查一下';

  @override
  String get activityTestStubborn => '有个用例不服';

  @override
  String get activityTestFix => '红灯，再改改';

  @override
  String get activityGitCommitSave => '提交了，存个档';

  @override
  String get activityGitSaved => '存档成功';

  @override
  String get activityGitCommitRelief => 'commit 一下，安心';

  @override
  String get activityGitPushed => '推上去了';

  @override
  String get activityGitPushDone => 'push 完成，起飞';

  @override
  String get activityGitCodeOut => '代码出门了';

  @override
  String get activityInstallDone => '依赖装好了';

  @override
  String get activityInstallInternet => '下载了半个互联网';

  @override
  String get activityInstallPackages => '包都到齐了';

  @override
  String get activityMilestoneFive => '工具 x5，手感来了';

  @override
  String get activityMilestoneTen => '工具连击 x10';

  @override
  String get activityMilestoneTwenty => '工具 x20，停不下来';

  @override
  String get activityMilestoneFifty => '工具 x50，劳模本模';

  @override
  String get activityRetryWait => '稍等，重试中';

  @override
  String get activityRetryBackoff => '刚被拒了，退避一下';

  @override
  String get activityRetryKnock => '再敲一次门';

  @override
  String get activityRateLimited => '被限流了，缓缓再试';

  @override
  String get activityRate429 => '429 了，歇口气再来';

  @override
  String get activityRateQueue => '排队的人有点多';

  @override
  String get activityCompactContext => '收拾一下上下文…';

  @override
  String get activityCompactBag => '整理背包中…';

  @override
  String get activityCompactSpace => '腾地方中';

  @override
  String get activityCompactMemory => '给记忆瘦个身';

  @override
  String get activityCompactChats => '打包旧对话';

  @override
  String get activityReminderWater => '半小时了，喝口水？';

  @override
  String get activityReminderTenMinutes => '10 分钟了，这活不小';

  @override
  String get activityDiffTitle => '本轮改动';

  @override
  String get activityDiffCopied => '已复制补丁';

  @override
  String get activityDiffNoWrap => '不换行';

  @override
  String get activityDiffWrap => '自动换行';

  @override
  String get activityDiffCopy => '复制补丁';

  @override
  String get activityDiffEmpty => '空文件，没有可显示的改动';

  @override
  String get activityDiffNewFile => '新建文件';

  @override
  String get activityDiffUnknownLines => '行号未知';

  @override
  String get activityDiffCopyPath => '复制路径';

  @override
  String get activityThinking => '思考';

  @override
  String get activityReplyInterrupted => '回复（已中断）';

  @override
  String get activityWaitingApproval => '等待确认';

  @override
  String get activityWaitingAnswer => '等待回答';

  @override
  String get activityWriting => '写回复中';

  @override
  String get activityThinkingNow => '思考中';

  @override
  String get activityRetrying => '重试中';

  @override
  String get activityCompacting => '压缩上下文';

  @override
  String get activityVerbRun => '跑';

  @override
  String get activityVerbWrite => '写';

  @override
  String get activityVerbEdit => '改';

  @override
  String get activityVerbImage => '看图';

  @override
  String get activityVerbRead => '读';

  @override
  String get activityVerbFind => '找';

  @override
  String get activityVerbSearch => '搜';

  @override
  String get activityVerbWebSearch => '搜网页';

  @override
  String get activityVerbWebView => '看网页';

  @override
  String get activityVerbSubagent => '派子代理';

  @override
  String get activityVerbTodo => '更新待办';

  @override
  String get activitySecretHide => '隐藏密钥';

  @override
  String get activitySecretShow => '显示密钥';

  @override
  String get activitySlashNoMatch => '没有匹配的指令，按普通消息发送';

  @override
  String get activitySlashCommands => '指令';

  @override
  String get activitySlashEnterArgs => '输入参数后发送';

  @override
  String get activitySlashRunIntent => '命令 · 执行';

  @override
  String get activitySlashInsertIntent => '命令 · 填入';

  @override
  String get activitySlashSkillIntent => '技能 · 填入';

  @override
  String get activityStepTitle => '步骤详情';

  @override
  String get activityStepMissing => '这一步不在已加载的记录里';

  @override
  String get activityStepQuestion => '提问';

  @override
  String get activityStepSuccess => '成功';

  @override
  String get activityStepNeedsPermission => '需要授权';

  @override
  String get activityTools => '工具';

  @override
  String get activityStepDispatched => '发出';

  @override
  String get activityStepExecution => '执行';

  @override
  String get activityStepLocation => '所在';

  @override
  String get activityStepArguments => '参数';

  @override
  String get activityStepChanges => '改动';

  @override
  String get activityStepFullScreen => '全屏查看';

  @override
  String get activityStepReadContent => '读到的内容';

  @override
  String get activityStepWrittenContent => '写入的内容';

  @override
  String get activityStepError => '错误';

  @override
  String get activityOutput => '输出';

  @override
  String get activityStepResult => '结果';

  @override
  String get activityStepDeclined => '你拒绝了这次调用';

  @override
  String get activityStepNoOutput => '没有输出';

  @override
  String get activityStepStart => '开始';

  @override
  String get activityDuration => '用时';

  @override
  String get activityFirstToken => '首字';

  @override
  String get activityStepGeneration => '生成';

  @override
  String get activityStepSpeed => '速度';

  @override
  String get activityModel => '模型';

  @override
  String get activityStepTiming => '计时';

  @override
  String get activityUsage => '用量';

  @override
  String get activityInput => '输入';

  @override
  String get activityStepCacheHit => '  命中缓存';

  @override
  String get activityStepCacheMiss => '  未命中';

  @override
  String get activityStepCacheWrite => '  写入缓存';

  @override
  String get activityStepReasoning => '  推理';

  @override
  String get activityStepAnswer => '  回答';

  @override
  String get activityStepThinking => '思考过程';

  @override
  String get activityStepExplanation => '说明';

  @override
  String get activityStepToolCalls => '本步调用的工具';

  @override
  String get activityStepProcessing => '模型正在处理';

  @override
  String get activityApprovalAllowed => '允许了';

  @override
  String get activityApprovalUnanswered => '无人确认';

  @override
  String get activityApprovalAnswered => '已答复';

  @override
  String get activityToolRead => '读取';

  @override
  String get activityToolWrite => '写入';

  @override
  String get activityToolCall => '调用工具';

  @override
  String get activityTraceTitle => '本轮轨迹';

  @override
  String get activityTraceNotLoaded => '本轮记录尚未加载';

  @override
  String get activityTraceOutputLimit => '输出达到上限';

  @override
  String get activityTraceEngineRestarted => '引擎重启，已中断';

  @override
  String get activityTraceBlocked => '已被拦截';

  @override
  String get activityTraceHeading => '本轮轨迹  ';

  @override
  String get activityTraceWaiting => '等你';

  @override
  String get activityTraceNoSteps => '本轮没有可计时的步骤';

  @override
  String get activityUsageInputIncludesCache => '输入含缓存命中';

  @override
  String get activityCacheHit => '缓存命中';

  @override
  String get activitySummaryTodo => '更新了待办';

  @override
  String get activityUsageBalance => 'DeepSeek 余额';

  @override
  String get activityUsageContext => '上下文';

  @override
  String get activityUsageChat => '本对话';

  @override
  String get activityUsageAfterMessage => '发送消息后显示';

  @override
  String get activityUsageWaiting => '等待上下文用量数据';

  @override
  String get activityUsageProjected => '预计下次请求';

  @override
  String get activityUsageLastRequest => '上次请求';

  @override
  String get activityUsageBreakdownEstimate => '分项为独立估算，可能与总量不同';

  @override
  String get activityUsageCumulativeInput => '累计输入';

  @override
  String get activityUsageContextFull => '上下文将满，发送 /compact 可压缩';

  @override
  String get activitySpanZero => '0 秒';

  @override
  String get activitySpanTiny => '<0.1 秒';

  @override
  String activityTokensTenThousands(String value) {
    return '$value 万';
  }

  @override
  String activityTokensHundredMillions(String value) {
    return '$value 亿';
  }

  @override
  String activityUsageContextSemantics(String percent) {
    return '上下文已用 $percent，查看用量';
  }

  @override
  String activityUsageSystemTokens(String tokens) {
    return '系统 $tokens';
  }

  @override
  String activityUsageToolTokens(String tokens) {
    return '工具 $tokens';
  }

  @override
  String activityUsageMessageTokens(String tokens) {
    return '消息 $tokens';
  }

  @override
  String activityUsageTurns(int count) {
    return '共 $count 轮';
  }

  @override
  String activityUsageCacheWriteTokens(String tokens) {
    return '写入缓存 $tokens';
  }

  @override
  String activitySummaryCommands(int count) {
    return '执行 $count 条命令';
  }

  @override
  String activitySummaryEditedFiles(int count) {
    return '改了 $count 个文件';
  }

  @override
  String activitySummaryReadFiles(int count) {
    return '读了 $count 个文件';
  }

  @override
  String activitySummarySearches(int count) {
    return '搜索 $count 次';
  }

  @override
  String activitySummaryWeb(int count) {
    return '联网 $count 次';
  }

  @override
  String activitySummarySubagents(int count) {
    return '调用子代理 $count 次';
  }

  @override
  String activitySummaryOther(int count) {
    return '其他工具 $count 次';
  }

  @override
  String activitySummaryTotal(int count) {
    return '使用了 $count 个工具';
  }

  @override
  String activityDiffBlockMarker(int index, int total) {
    return '@@ 第 $index/$total 处修改 @@';
  }

  @override
  String activityDiffEditMarker(int index, int total) {
    return '第 $index 次修改（共 $total 次）';
  }

  @override
  String activityTraceSpanSemantics(String title, String detail, String duration) {
    return '$title $detail，用时 $duration';
  }

  @override
  String activityTraceGroupSemantics(String label, String duration) {
    return '$label，用时 $duration';
  }

  @override
  String activityTraceEstimatedCost(String cost) {
    return '$cost（按官方单价估算）';
  }

  @override
  String activityTraceReasoningTokens(String tokens) {
    return '其中推理 $tokens';
  }

  @override
  String activityStepPosition(int turn, Object step) {
    return '第 $turn 轮 · 第 $step 步';
  }

  @override
  String activityStepTokenSpeed(String speed) {
    return '$speed tokens/秒';
  }

  @override
  String activityStepRetryCount(int count) {
    return '$count 次';
  }

  @override
  String activityStepTruncated(String text, int count) {
    return '$text\n…（仅显示前 ${count}k 字，复制可得全文）';
  }

  @override
  String activityStepLiveElapsed(String elapsed, String suffix) {
    return '$elapsed · 进行中$suffix';
  }

  @override
  String activityStepCopySection(String title) {
    return '复制$title';
  }

  @override
  String activityStepCopiedSection(String title) {
    return '已复制$title';
  }

  @override
  String activitySlashDescriptionArgs(String description) {
    return '$description · 输入参数后发送';
  }

  @override
  String activitySpanSecondsText(String seconds) {
    return '$seconds 秒';
  }

  @override
  String activitySpanSeconds(int seconds) {
    return '$seconds 秒';
  }

  @override
  String activitySpanMinutesSeconds(int minutes, String seconds) {
    return '$minutes 分 $seconds 秒';
  }

  @override
  String activitySpanHoursMinutes(int hours, String minutes) {
    return '$hours 小时 $minutes 分';
  }

  @override
  String activityCostUnderCent(String symbol) {
    return '不到 ${symbol}0.01';
  }

  @override
  String activityCostApprox(String symbol, String amount) {
    return '约 $symbol$amount';
  }

  @override
  String activitySpanRetries(int count) {
    return '重试 $count 次';
  }

  @override
  String activitySpanToolCalls(int count) {
    return '决定调用 $count 个工具';
  }

  @override
  String activityRunningItems(int count) {
    return '等 $count 项';
  }

  @override
  String activityRetryAttempt(int count) {
    return '第 $count 次';
  }

  @override
  String activityDiffFileCount(int count) {
    return '$count 个文件';
  }

  @override
  String activityDiffFileSemantics(String path, int added, int removed) {
    return '$path，新增 $added 行，删除 $removed 行';
  }

  @override
  String activityDiffEditNumber(int edit) {
    return '第 $edit 次修改';
  }

  @override
  String activityDiffHunkNumber(int index) {
    return '第 $index 处';
  }

  @override
  String activityDiffFromLine(int line) {
    return '第 $line 行起';
  }

  @override
  String activityDiffEditCount(int count) {
    return '修改 $count 次';
  }

  @override
  String activityLunarZodiac(String animal) {
    return '$animal年大吉';
  }

  @override
  String activityReminderHours(int hours) {
    return '已经连续干了 $hours 小时，歇会儿？';
  }

  @override
  String get activityStepModelRequest => '一次模型请求';

  @override
  String activityStepModelRequestDetail(String detail) {
    return '一次模型请求 · $detail';
  }

  @override
  String activityUsageEstimatedCost(String symbol, String amount) {
    return '约 $symbol$amount';
  }

  @override
  String activitySlashCommandSemantics(String label, String name) {
    return '$label，/$name';
  }

  @override
  String get activityQuotaTitle => '订阅额度';

  @override
  String get activityQuotaRefresh => '刷新额度';

  @override
  String get activityQuotaPermissionDenied => '订阅没有权限查询额度';

  @override
  String get activityQuotaAuthError => '登录已过期或无权查询，请检查订阅登录';

  @override
  String get activityQuotaNetworkError => '网络连接失败，请稍后重试';

  @override
  String get activityQuotaRateLimited => '查询过于频繁，请稍后重试';

  @override
  String get activityQuotaLoading => '正在查询订阅额度…';

  @override
  String get activityQuotaUnavailable => '暂时无法查询订阅额度，请稍后重试';

  @override
  String get activityQuotaUnsupported => '此主机暂不支持查询订阅额度';

  @override
  String get activityQuotaSignedOut => '订阅未登录';

  @override
  String get activityQuotaPrimary => '主要额度';

  @override
  String get activityQuotaSecondary => '次要额度';

  @override
  String get activityQuotaFiveHour => '5 小时';

  @override
  String get activityQuotaSevenDay => '7 天';

  @override
  String get activityQuotaSevenDaySonnet => '7 天 · Sonnet';

  @override
  String get activityQuotaSevenDayOpus => '7 天 · Opus';

  @override
  String activityQuotaUsed(String value) {
    return '已使用 $value';
  }

  @override
  String activityQuotaReset(String time) {
    return '重置时间：$time';
  }

  @override
  String get activityToolListSeparator => '、';

  @override
  String get androidShellTitle => 'Android Shell';

  @override
  String get androidShellEntryHint => '独立的系统命令通道，默认关闭';

  @override
  String get androidShellSubtitle => '通过 Shizuku 或自连 ADB 在这台手机上执行 Android 系统命令，不是 Ubuntu 里的 bash。';

  @override
  String get androidShellEnable => '允许 Android Shell';

  @override
  String get androidShellEnableHint =>
      '独立开关，不随不打扰模式或屏幕免确认开启；只增加 Android 命令通道，不影响 Ubuntu 里的 bash / run_code 等工具，两者可同时使用。';

  @override
  String get androidShellConfirmationNote => '每条命令均需确认，可能修改系统和文件。';

  @override
  String get androidShellMasterOff => '先在上一页打开「手机操控」。';

  @override
  String get androidShellRiskTitle => '允许执行 Android 系统命令？';

  @override
  String get androidShellRiskBody => '命令使用所选通道的实际 UID，可能修改应用、系统设置和共享文件。它不受屏幕应用名单完整保护；每条命令仍会单独请求原生确认。只允许你理解并信任的命令。';

  @override
  String get androidShellRiskAction => '允许 Android Shell';

  @override
  String get androidShellBackend => '连接方式';

  @override
  String get androidShellDetails => '详情';

  @override
  String get androidShellReady => '已连接';

  @override
  String get androidShellShizukuHint => '使用已安装并启动的 Shizuku，需单独授权；不需要 Android 14、无障碍或不打扰模式。';

  @override
  String get androidShellAdb => '自连 ADB';

  @override
  String get androidShellAdbHint => '连接本机的无线调试，复用 App 的私有 ADB 身份；不会连接其他设备。';

  @override
  String get androidShellInstalled => 'Shizuku 已安装';

  @override
  String get androidShellRunning => 'Shizuku 正在运行';

  @override
  String get androidShellGranted => 'Shizuku 已授权';

  @override
  String get androidShellPaired => 'ADB 已配对';

  @override
  String get androidShellConnected => 'ADB 已连接';

  @override
  String get androidShellAuthorize => '申请 Shizuku 授权';

  @override
  String get androidShellAuthorizeHint => '先安装并启动 Shizuku，再点此按钮允许 dsh-Go。打开本页或刷新不会申请授权。';

  @override
  String get androidShellStatus => '执行状态';

  @override
  String get androidShellUid => '实际 UID';

  @override
  String get androidShellUidUnknown => '尚未报告';

  @override
  String get androidShellRefresh => '刷新状态';

  @override
  String get androidShellStop => '停止 Android Shell';

  @override
  String get androidShellStopHint => '取消当前命令并停止独立 Shell 执行，不关闭屏幕操控。';

  @override
  String get androidShellPairingGuide => '在开发者选项中打开「无线调试」，选择「使用配对码配对设备」。配对码只在本次配对中使用，不保存、不写入日志。';

  @override
  String get androidShellStartPairing => '打开配对引导';

  @override
  String get androidShellPair => '输入配对码';

  @override
  String get androidShellPairSubmit => '配对';

  @override
  String get androidShellPairCode => '六位配对码';

  @override
  String get androidShellPairPort => '配对端口（可选）';

  @override
  String get androidShellPairPortHint => '填配对弹窗里的端口，不是无线调试主页的连接端口；留空时尝试自动发现。';

  @override
  String get androidShellConnect => '连接 ADB';

  @override
  String get androidShellConnectChannel => '连接所选通道';

  @override
  String get androidShellConnectPort => '连接端口（可选）';

  @override
  String get androidShellConnectPortHint => '填无线调试主页「IP 地址和端口」中的端口，不是配对端口。只连接本机；留空时尝试自动发现。';

  @override
  String androidShellErrorCode(String code) {
    return '错误码：$code';
  }

  @override
  String androidShellLimits(int seconds, int bytes) {
    return '单次最长 $seconds 秒，输出最多 $bytes 字节';
  }

  @override
  String get androidShellErrorDisabled => 'Android Shell 已关闭。';

  @override
  String get androidShellErrorNotConnected => '所选通道尚未连接。';

  @override
  String get androidShellErrorShizukuMissing => '请先安装 Shizuku。';

  @override
  String get androidShellErrorShizukuStopped => '请先启动 Shizuku，再刷新状态。';

  @override
  String get androidShellErrorPermissionRequired => '需要你在 Shizuku 中明确授权。';

  @override
  String get androidShellErrorAdbNotPaired => '请先完成本机无线调试配对，再连接 ADB。';

  @override
  String get androidShellErrorConnectFailed => '连接未成功。请检查所选通道和当前无线调试连接端口，再重试。';

  @override
  String get androidShellErrorIdentityChanged => '通道身份已改变，请停止后重新授权或连接。';

  @override
  String get androidShellErrorHelperStartFailed => 'Android Shell 辅助进程未能启动，命令未执行。';

  @override
  String get androidShellErrorBusy => '另一项操作尚未结束，请稍后重试，或先停止 Android Shell。';

  @override
  String get androidShellErrorInvalidArguments => '输入无效。配对码须为六位数字，端口须在 1–65535 之间。';

  @override
  String get androidShellErrorCancelled => '操作已取消。';

  @override
  String get androidShellErrorTimeout => '操作超时。先核实结果；已派发的命令不要自动重试。';

  @override
  String get androidShellErrorConfirmationDenied => '未获准执行命令。';

  @override
  String get androidShellErrorCleanupFailed => '未能完成停止清理。请重试停止，暂勿执行新命令。';

  @override
  String get androidShellErrorLocked => '手机已锁定，请解锁后重试。';

  @override
  String get androidShellErrorConfirmationUnavailable => '当前无法显示原生确认，请回到 App 并检查通知权限。';

  @override
  String get androidShellErrorTransportLost => '通道已断开。先核实结果；已派发的命令不要自动重试，需要时重新连接。';

  @override
  String get androidShellErrorProtocolMismatch => '当前原生模块不支持此 Shell 协议，请更新 App。';

  @override
  String get androidShellErrorNativeUnavailable => '此构建的 Android Shell 原生模块不可用。';

  @override
  String get androidShellErrorInvalidResponse => '没有收到有效的原生状态，请刷新或更新 App。';

  @override
  String get androidShellErrorStopped => '本轮已结束或暂停，请重新开启后再试。';

  @override
  String get androidShellErrorStopFailed => '未确认已停止，请刷新状态并重试停止。';

  @override
  String get androidShellErrorUnknown => '未能确认操作结果。先核实结果；已派发的命令不要自动重试。';

  @override
  String get androidBackgroundProtectionTitle => '增强保活';

  @override
  String get androidBackgroundProtectionAudioHint => '有本机任务时在后台播放静音音频，可能增加耗电。';

  @override
  String get androidBackgroundProtectionLocationHint => '使用粗略位置，可能增加耗电；不保存或发送坐标。关闭后停止定位，但不撤回系统权限。';

  @override
  String get androidBackgroundProtectionNeedsLocation => '尚未授予位置权限。点此打开 App 的系统设置，在「权限」中允许访问位置。';

  @override
  String get androidBackgroundProtectionNeedsAlways => '后台定位尚未生效。点此打开 App 的系统设置，在「权限」中将位置设为“始终允许”。';

  @override
  String get backgroundProtectionDescription => '默认关闭，仅在有本机任务且 App 退到后台时尝试保护；系统仍可能暂停任务。';

  @override
  String get backgroundProtectionAudio => '静音音频保护';

  @override
  String get backgroundProtectionAudioHint => '任务期间在后台播放静音音频，会增加耗电；不会抢占录音、通话或朗读。';

  @override
  String get backgroundProtectionLocation => '后台定位保护';

  @override
  String get backgroundProtectionLocationHint => '需系统“始终允许”位置权限，会增加耗电并涉及位置隐私；不保存坐标。';

  @override
  String get backgroundProtectionTask => '连续任务保护';

  @override
  String get backgroundProtectionTaskHint => '仅在本机任务期间申请系统连续任务，是否生效取决于当前版本和系统许可。';

  @override
  String get backgroundProtectionStatus => '当前状态';

  @override
  String get backgroundProtectionOff => '未开启增强保护';

  @override
  String get backgroundProtectionReady => '已开启，当前未运行；有本机任务且退到后台时才会尝试保护。';

  @override
  String get backgroundProtectionAudioActive => '静音音频保护正在运行';

  @override
  String get backgroundProtectionLocationActive => '后台定位保护正在运行';

  @override
  String get backgroundProtectionBothActive => '静音音频与后台定位保护正在运行';

  @override
  String get backgroundProtectionTaskActive => '系统连续任务保护正在运行';

  @override
  String get backgroundProtectionLocationRestricted => '定位权限被系统限制，无法开启定位保护；可保持前台或使用远程主机。';

  @override
  String get backgroundProtectionNeedsAlways => '定位保护尚未生效，请点此在系统设置中将位置权限设为“始终允许”。';

  @override
  String get backgroundProtectionLocationServicesOff => '系统定位服务已关闭，请点此检查系统设置。';

  @override
  String get backgroundProtectionTaskUnavailable => '当前版本缺少系统连续任务资格，请保持 App 在前台或使用远程主机。';

  @override
  String get backgroundProtectionUnavailable => '保护暂不可用，请返回 App 重试；长任务可保持前台或使用远程主机。';

  @override
  String get backgroundProtectionCleanup => '正在结束上一次后台保护，尚未完成释放。';

  @override
  String get backgroundProtectionUpdateFailed => '未能更新后台保护，请查看当前状态后重试。';

  @override
  String get botsFolderGone => '这个文件夹已经不在了';

  @override
  String get botsFolderReadFailed => '没能读取这个文件夹';

  @override
  String get botsFolderOpenFailed => '打不开这个文件夹';

  @override
  String botsFolderCount(int count) {
    return '$count 个文件夹';
  }

  @override
  String get botsWorkingFolder => '工作目录';

  @override
  String get botsFolderTeamDefault => '团队工作区';

  @override
  String get botsFolderRoomDefault => '每位 Bot 各自的目录';

  @override
  String get botsFolderHint => '目录位于已连接的主机。';

  @override
  String get botsFolderCurrent => '当前目录';

  @override
  String get botsFolderUnavailable => '连接或目录已变化，请重新打开。';

  @override
  String get botsFolderNoChoices => '主机上暂无其他目录。';

  @override
  String get botsFolderConfirm => '使用此工作目录？';

  @override
  String get botsFolderRefused => '主机拒绝了此目录：它可能已不存在、无法访问或受保护。请另选目录或重试。';

  @override
  String botsChildCount(int count) {
    return '$count 个下级';
  }

  @override
  String get botsCurrentChat => '当前对话';

  @override
  String botsSubagentCount(int count) {
    return '$count 个子代理';
  }

  @override
  String botsRunningCount(int count) {
    return '$count 个运行中';
  }

  @override
  String botsFailedCount(int count) {
    return '$count 个出错';
  }

  @override
  String botsNestedCount(int count) {
    return '含 $count 个下级';
  }

  @override
  String botsBackToParent(String title) {
    return '返回「$title」';
  }

  @override
  String botsTeamMemberCount(int count) {
    return '智能体团队，$count 位成员';
  }

  @override
  String get botsAgentTeam => '智能体团队';

  @override
  String botsSubagentRunningCount(int count, int running) {
    return '$count 个子代理，$running 个运行中';
  }

  @override
  String get botsSubagents => '子代理';

  @override
  String get botsNoSubagents => '没有派出子代理';

  @override
  String get botsOpenChatFirst => '先打开一个对话';

  @override
  String get botsTeamReadFailed => '没能读到团队';

  @override
  String get botsNoTeamOnHost => '这台主机没有智能体团队';

  @override
  String get botsTeamNotEnabled => '智能体团队未开启';

  @override
  String get botsTeamDescription => '多个智能体分工协作，共用一块任务板';

  @override
  String get botsTeamEnabling => '正在开启…';

  @override
  String get botsTeamEnable => '开启团队';

  @override
  String botsMembersWorking(int count) {
    return '$count 位成员在工作';
  }

  @override
  String get botsTeamStandby => '都在待命';

  @override
  String get botsMembers => '成员';

  @override
  String get botsTasks => '任务';

  @override
  String get botsTeamRecordUnreadable => '团队记录有一条读不出来';

  @override
  String get botsMessages => '消息';

  @override
  String get botsOwner => '负责人';

  @override
  String get botsTeamCreateHint => '在对话里请 AI 组建团队';

  @override
  String get botsCurrent => '当前';

  @override
  String get botsNoTasks => '还没有任务';

  @override
  String get botsTodo => '待办';

  @override
  String get botsUnassigned => '未分配';

  @override
  String botsTaskWaitingFor(String dependencies) {
    return '等 $dependencies';
  }

  @override
  String get botsWriteOverlap => '写入范围重叠';

  @override
  String get botsWaitingDependencies => '等依赖';

  @override
  String get botsReadyToStart => '可开始';

  @override
  String get botsTaskId => '编号';

  @override
  String get botsDependencies => '依赖';

  @override
  String get botsWriteScopes => '写入范围';

  @override
  String get botsMessagesReadFailed => '没能读到消息';

  @override
  String get botsNoMemberMessages => '成员之间还没有消息';

  @override
  String get botsMessagesIncomplete => '部分成员的消息没能读到 · 重试';

  @override
  String botsDateTime(String date, String time) {
    return '$date $time';
  }

  @override
  String get botsViewDetails => '查看详情';

  @override
  String get botsAdmin => '管理员';

  @override
  String get botsFullTextChanged => '对话已变化';

  @override
  String get botsFullTextReopen => '请重新打开这条消息';

  @override
  String get botsFullTextReadFailed => '没能读取全文';

  @override
  String get botsShowAll => '显示全部';

  @override
  String get botsImagePlaceholder => '［图片］';

  @override
  String get botsSending => '发送中';

  @override
  String get botsWriteOwn => '自己写';

  @override
  String get botsSubmit => '提交';

  @override
  String botsChooseModelFor(String name) {
    return '给 $name 选一个模型';
  }

  @override
  String get botsModelGreeting => '选好后它就会打招呼';

  @override
  String get botsChooseModel => '选择模型';

  @override
  String get botsSkipAnswer => '不回答';

  @override
  String get botsBotGone => '这个 Bot 已不在';

  @override
  String get botsWaitingModel => '等你选模型';

  @override
  String get botsThinking => '正在思考';

  @override
  String get botsMainBot => '主 Bot';

  @override
  String get botsIdle => '空闲';

  @override
  String get botsAnsweredQuestion => '你回答了它的问题';

  @override
  String get botsEarlierMessages => '更早的部分';

  @override
  String botsComposerHint(String name) {
    return '给 $name 发消息…';
  }

  @override
  String botsDeleteNamed(String name) {
    return '删除「$name」？';
  }

  @override
  String get botsDeleteBotBody => '它的对话还在，记忆会移到归档里。';

  @override
  String get botsTokensToday => '24 小时 tokens';

  @override
  String get botsMemoryUnit => '条记忆';

  @override
  String get botsRoomUnit => '个群聊';

  @override
  String get botsProfile => '资料';

  @override
  String get botsModel => '模型';

  @override
  String get botsBotName => '名字';

  @override
  String get botsRole => '角色';

  @override
  String get botsWriterExample => '比如：写手';

  @override
  String get botsInstructions => '说明';

  @override
  String get botsInstructionsHint => '它该怎么做事';

  @override
  String get botsColor => '颜色';

  @override
  String get botsUsage => '用量';

  @override
  String get botsUsageScanning => '正在统计历史对话，数据稍后补全。';

  @override
  String get botsUsageRefresh => '刷新';

  @override
  String get botsToday => '近 24 小时';

  @override
  String get botsLastWeek => '近 7 天';

  @override
  String get botsLastMonth => '近 30 天';

  @override
  String botsMonthCalls(int count) {
    return '近 30 天 · $count 次调用';
  }

  @override
  String get botsFullRecord => '完整记录';

  @override
  String get botsEveryToolCall => '每一步工具调用';

  @override
  String get botsUnsetMain => '取消主 Bot';

  @override
  String get botsSetMain => '设为主 Bot';

  @override
  String get botsDeleteBot => '删除 Bot';

  @override
  String get botsEffortOff => '不思考';

  @override
  String get botsEffortMinimal => '极少';

  @override
  String get botsEffortLow => '低';

  @override
  String get botsEffortMedium => '中';

  @override
  String get botsEffortHigh => '高';

  @override
  String get botsEffortMax => '最高';

  @override
  String botsNamedRecord(String name) {
    return '$name · 完整记录';
  }

  @override
  String get botsOrganizingNotes => '正在整理笔记';

  @override
  String get botsToolRun => '运行命令';

  @override
  String get botsToolRead => '查看文件';

  @override
  String get botsToolEdit => '修改文件';

  @override
  String get botsToolSearch => '联网搜索';

  @override
  String get botsToolBrowse => '看网页';

  @override
  String get botsToolMessage => '联系其他 Bot';

  @override
  String get botsToolGroup => '在群里沟通';

  @override
  String get botsToolMemory => '整理记忆';

  @override
  String get botsToolRecall => '翻看记录';

  @override
  String get botsToolTeam => '安排团队';

  @override
  String get botsToolAsk => '准备问你';

  @override
  String get botsToolWork => '干活';

  @override
  String get botsJustNow => '刚刚';

  @override
  String botsCountHundredMillion(String value) {
    return '$value 亿';
  }

  @override
  String botsCountTenThousand(String value) {
    return '$value 万';
  }

  @override
  String get botsModelNotSelected => '未选择';

  @override
  String botsYourPreview(String preview) {
    return '你：$preview';
  }

  @override
  String botsEventWorking(String name) {
    return '$name 开始干活';
  }

  @override
  String botsEventApproval(String name) {
    return '$name 在等你批准';
  }

  @override
  String botsEventDone(String name) {
    return '$name 完成了工作';
  }

  @override
  String botsEventStopped(String name) {
    return '你停下了 $name 的工作';
  }

  @override
  String botsEventFailed(String name) {
    return '$name 没能回答';
  }

  @override
  String botsEventMissed(String name) {
    return '$name 没有及时回应';
  }

  @override
  String botsEventLookup(String name) {
    return '$name 翻看了自己的聊天';
  }

  @override
  String botsEventLookupQuery(String name, String query) {
    return '$name 在自己的聊天里找「$query」';
  }

  @override
  String botsEventResumed(String name) {
    return '$name 重启后接着干';
  }

  @override
  String botsEventCut(String name) {
    return '$name 又被重启打断，停下了';
  }

  @override
  String get botsAutomation => '定时任务';

  @override
  String botsAutomationText(String text) {
    return '定时任务：$text';
  }

  @override
  String get botsOtherBot => '其他 Bot';

  @override
  String botsMessageFrom(String name) {
    return '来自 $name 的消息';
  }

  @override
  String botsEventReplied(String name) {
    return '$name 回复了';
  }

  @override
  String get botsGroupReplied => '群里有了回复';

  @override
  String botsNamedGroupReplied(String name) {
    return '「$name」里有了回复';
  }

  @override
  String botsEventCalledStop(String name) {
    return '$name 叫停了工作';
  }

  @override
  String get botsChooseMember => '选择成员';

  @override
  String get botsMentionMember => '提到成员';

  @override
  String get botsRelayUnavailable => '经中转连接时用不了 Bot';

  @override
  String get botsUseSsh => '用 SSH 连接这台电脑即可使用';

  @override
  String get botsTeamLoadFailed => '没能读取 Bot 团队';

  @override
  String botsBotCount(int count) {
    return '$count 个 Bot';
  }

  @override
  String botsRoomCount(int count) {
    return '$count 个群聊';
  }

  @override
  String get botsNewBot => '新建 Bot';

  @override
  String get botsGroupChat => '群聊';

  @override
  String get botsNewGroup => '新建群聊';

  @override
  String get botsDuplicateCreated => '已复制，稍后会出现在列表中。';

  @override
  String get botsDuplicate => '复制 Bot';

  @override
  String get botsDuplicateHint => '沿用设置，对话与记忆从头开始';

  @override
  String botsDuplicateNamed(String name) {
    return '复制 $name？';
  }

  @override
  String get botsDuplicateBody => '新 Bot 沿用职责、指令和模型设置，对话与个人记忆从头开始，名称由主机分配。模型可用时，它会先发送一句问候。';

  @override
  String get botsChooseModelStart => '选一个模型开始';

  @override
  String get botsNoChats => '还没有对话';

  @override
  String botsUnreadCount(int count) {
    return '$count 条未读';
  }

  @override
  String get botsMainTag => '主';

  @override
  String get botsMemberNeedsApproval => '有成员等你批准';

  @override
  String botsNamedWorking(String name) {
    return '$name 正在干活';
  }

  @override
  String botsNamesWorking(String names) {
    return '$names 正在干活';
  }

  @override
  String botsMemberCount(int count) {
    return '$count 位成员';
  }

  @override
  String get botsUpdateRequired => 'DS Bot 需要更新';

  @override
  String get botsInstall => '安装 DS Bot';

  @override
  String get botsUpdateForPhone => '新版才能在手机上用';

  @override
  String get botsInstallDescription => '一组长期在线的 Bot，各有记忆和分工';

  @override
  String botsInstallOnHost(String host) {
    return '在$host上装好后就能用';
  }

  @override
  String botsRunsOnHost(String host) {
    return '在$host上运行';
  }

  @override
  String get botsInstalling => '正在安装';

  @override
  String get botsMemory => '记忆';

  @override
  String get botsEditMemory => '编辑记忆';

  @override
  String get botsAddMemory => '添加记忆';

  @override
  String get botsMemoryReplyExample => '比如：回复尽量简短';

  @override
  String get botsMemoryDraftExample => '比如：周五前交初稿';

  @override
  String botsMemoryCount(int count) {
    return '记忆 · $count';
  }

  @override
  String get botsMemoryReadFailed => '没能读取记忆';

  @override
  String get botsSummary => '概要';

  @override
  String get botsNoMemory => '还没有记忆';

  @override
  String get botsTeam => '团队';

  @override
  String get botsSelf => '自己';

  @override
  String get botsWrittenByYou => '你写的';

  @override
  String get botsNameRequired => '起个名字';

  @override
  String get botsRoleHint => '一句话说它是做什么的';

  @override
  String get botsNewInstructionsHint => '它该怎么做事，有什么要注意的';

  @override
  String get botsAppearance => '外观';

  @override
  String get botsCreating => '正在创建';

  @override
  String get botsGroupNameOptional => '群名（可不填）';

  @override
  String botsMembersSelected(int count) {
    return '成员 · 已选 $count';
  }

  @override
  String get botsPickTwoBots => '至少选两个 Bot';

  @override
  String get botsFullText => '全文';

  @override
  String botsTextPartial(String count) {
    return '仅显示前 $count 个字符';
  }

  @override
  String get botsTextCompletenessUnknown => '无法确认是否为完整内容';

  @override
  String get botsRoomGone => '这个群聊已不在';

  @override
  String botsNamedSpeaking(String name) {
    return '$name 正在发言';
  }

  @override
  String botsNamedActivity(String name, String activity) {
    return '$name $activity';
  }

  @override
  String get botsWorking => '正在干活';

  @override
  String get botsDiscussing => '正在讨论';

  @override
  String get botsTyping => '正在输入';

  @override
  String get botsGroupComposerHint => '给大家发消息…';

  @override
  String get botsDecline => '拒绝';

  @override
  String get botsAllowOnce => '允许本次';

  @override
  String get botsPrivateChat => '私聊';

  @override
  String get botsSetAdmin => '设为管理员';

  @override
  String get botsRemoveMember => '移出群聊';

  @override
  String get botsDeleteRoomBody => '群里的记录还在，群记忆会移到归档里。';

  @override
  String botsNamedAdmin(String name) {
    return '管理员 $name';
  }

  @override
  String botsRoomWorkingCount(int count) {
    return '$count 位在干活';
  }

  @override
  String botsMembersCountTitle(int count) {
    return '成员 · $count';
  }

  @override
  String get botsStopMember => '停下';

  @override
  String get botsAddMember => '添加成员';

  @override
  String get botsWhoAnswers => '谁先回答';

  @override
  String get botsAdminFirst => '管理员先答';

  @override
  String get botsEveryoneInTurn => '全员轮流';

  @override
  String get botsGroupName => '群名';

  @override
  String get botsGroupNotice => '群公告';

  @override
  String get botsGroupNoticeHint => '每个成员发言前都会看到';

  @override
  String get botsDeleteGroup => '删除群聊';

  @override
  String get botsDiscardTitle => '放弃修改？';

  @override
  String get botsKeepEditing => '继续编辑';

  @override
  String get botsDiscard => '放弃';

  @override
  String get botsProgress => '进度';

  @override
  String get botsGlyphRun => '运行';

  @override
  String get botsGlyphJobOutput => '查看后台任务';

  @override
  String get botsGlyphJobs => '后台任务';

  @override
  String get botsGlyphStopJob => '停止后台任务';

  @override
  String get botsGlyphRead => '读取';

  @override
  String get botsGlyphImage => '查看图片';

  @override
  String get botsGlyphDeliver => '交付文件';

  @override
  String get botsGlyphWrite => '写入';

  @override
  String get botsGlyphSearch => '搜索';

  @override
  String get botsGlyphFindFiles => '查找文件';

  @override
  String get botsGlyphOpenWeb => '打开网页';

  @override
  String get botsGlyphMessageAgent => '发消息给子代理';

  @override
  String get botsGlyphInterruptAgent => '打断子代理';

  @override
  String get botsGlyphListModels => '列出子代理模型';

  @override
  String get botsGlyphWorkflow => '工作流';

  @override
  String get botsGlyphLoop => '循环任务';

  @override
  String get botsGlyphSkill => '使用技能';

  @override
  String get botsGlyphTodo => '更新待办';

  @override
  String get botsGlyphSetGoal => '设定目标';

  @override
  String get botsGlyphViewGoal => '查看目标';

  @override
  String get botsGlyphUpdateGoal => '更新目标';

  @override
  String get botsGlyphAsk => '提问';

  @override
  String get botsCommunityEmpty => '暂时没有内容';

  @override
  String get botsCommunityGroups => '交流群';

  @override
  String get botsCommunity => '社区';

  @override
  String get botsForum => '论坛';

  @override
  String get botsForumSubtitle => '提问、分享、找同好';

  @override
  String get botsProjectHome => 'DSH Go 项目主页';

  @override
  String get botsOpenSource => '开源项目';

  @override
  String get botsPluginCatalogFailed => '插件目录没打开';

  @override
  String get botsTapRetry => '点一下重试';

  @override
  String get botsFeaturedPlugins => '精选插件';

  @override
  String get botsPluginSource => '插件信息来自 dshfind';

  @override
  String get botsPromptIdeas => '玩法';

  @override
  String get botsUpdates => '更新动态';

  @override
  String get botsLink => '链接';

  @override
  String botsLinkOpenFailed(String host) {
    return '没能打开 $host';
  }

  @override
  String botsYearMonth(int year, String month) {
    return '$year年$month月';
  }

  @override
  String get botsCopyGroupNumber => '复制群号';

  @override
  String botsQrCodeLabel(String title) {
    return '$title二维码';
  }

  @override
  String get botsFiles => '文件';

  @override
  String get botsEmptyCell => '（空）';

  @override
  String botsYesterdayTime(String time) {
    return '昨天 $time';
  }

  @override
  String get botsOutsideWorkspace => '不在工作区里';

  @override
  String get botsNotFolder => '这不是文件夹';

  @override
  String get botsChatNotFound => '找不到这个对话';

  @override
  String get botsBrowseUnsupported => '这个连接不支持浏览文件';

  @override
  String get botsWorkspace => '工作区';

  @override
  String get botsSearchFiles => '搜索文件';

  @override
  String get botsGoUp => '回到上一级';

  @override
  String get botsEmptyFolder => '空文件夹';

  @override
  String botsFileCount(int count) {
    return '$count 个文件';
  }

  @override
  String botsTruncatedItems(int count) {
    return '只列出了前 $count 项';
  }

  @override
  String get botsMoreActions => '更多操作';

  @override
  String get botsSearchFailed => '没能搜索';

  @override
  String get botsNoResults => '没有找到';

  @override
  String get botsCopyPath => '复制路径';

  @override
  String get botsPetOutsideApp => 'App 外显示';

  @override
  String get botsPetNotAuthorized => '未授权';

  @override
  String get botsPetDisplayWhen => '显示时机';

  @override
  String get botsPetWhenActive => '有事时显示';

  @override
  String get botsPetAlways => '一直显示';

  @override
  String get botsPetOverlayShows => '悬浮窗里显示';

  @override
  String get botsPetOverlayPixel => '像素宠物';

  @override
  String get botsPetOverlayCompanion => '小屋里的她';

  @override
  String botsPetOverlayCompanionNamed(String name) {
    return '小屋里的$name';
  }

  @override
  String get botsPetOverlayNoPack => '先去伙伴小屋里请一位角色';

  @override
  String get botsPetOverlayPackBroken => '角色包不完整，去伙伴小屋里重新导入';

  @override
  String get botsPetOverlayUnavailable => '这台手机暂时请不出她';

  @override
  String get botsPetOverlayCompanionHint => '点一下和她互动，连点两下打开对话。比像素宠物更耗电，熄屏和隐藏时会停下来';

  @override
  String get botsPetOverlayLoading => '正在请她出来…';

  @override
  String get botsPetOverlayFallback => '她没能出来，先由像素宠物顶班';

  @override
  String get botsPetOverlayFraming => '取景';

  @override
  String get botsPetOverlayFramingFull => '全身';

  @override
  String get botsPetOverlayFramingHalf => '半身';

  @override
  String get botsPetOverlayFramingHint => '换取景会重新加载她';

  @override
  String get botsPetSwitchDisabled => '开关点不动';

  @override
  String get botsPetRestrictedSettings => '允许受限制的设置';

  @override
  String get botsPetHiddenToday => '今天不再显示';

  @override
  String get botsPetRestore => '恢复';

  @override
  String get botsPetChange => '换宠物';

  @override
  String get botsPetHideHour => '藏起来 1 小时';

  @override
  String get botsPetSettings => '宠物设置';

  @override
  String get botsPetDeepy => 'Deepy 小鲸鱼';

  @override
  String get botsPetWhaleGirl => '鲸娘';

  @override
  String get botsPetPinkFish => '小粉鱼';

  @override
  String get botsPetNone => '不显示';

  @override
  String get botsPets => '宠物';

  @override
  String get botsPetSource => '来自 DSH-TUI';

  @override
  String get botsPetImport => '导入';

  @override
  String get botsPetImportHint => '导入你自己的像素宠物：一个 zip，里面是 pack.json 和序列帧 PNG，格式见仓库里的 docs/design/pets.md。长按导入的宠物可以删除。';

  @override
  String get botsPetMake => '让 AI 做一只宠物';

  @override
  String get botsPetMakeSubtitle => '把 GIF、表情包或主题转成宠物包';

  @override
  String botsPetImportDone(String name) {
    return '「$name」来了';
  }

  @override
  String botsPetCodexTitle(String name) {
    return '「$name」是从 Codex 宠物转过来的';
  }

  @override
  String get botsPetCodexBody => '大部分照原样，有几处不完全一样：';

  @override
  String get botsPetCodexOk => '知道了';

  @override
  String get botsPetCodexLoops => '动作会一直循环到状态变化，不像 Codex 里跑几遍就回到待机';

  @override
  String get botsPetCodexRoamLeft => '往左走用的是往右走那一行的镜像';

  @override
  String get botsPetCodexDrag => '拖着它时一律用朝右的那一行';

  @override
  String get botsPetCodexSleep => '睡觉时用待机的第一帧';

  @override
  String get botsPetCodexLook => '看向不同方向的那些格子没用上';

  @override
  String get botsPetCodexWebp => 'WebP 图转成了 PNG';

  @override
  String get botsPetCodexCustomTracks => '自定义的动作行没接到任何状态上';

  @override
  String get botsPetCodexFps => '帧率换算成毫秒时取了整';

  @override
  String get botsPetCodexOneShot => '只播一次的动作，播完回到哪里由 DSH 决定';

  @override
  String get botsPetCodexMissingAuthor => '包里没写作者';

  @override
  String get botsPetCodexMissingLicense => '包里没写授权';

  @override
  String get botsPetCodexMissingSource => '包里没写来源';

  @override
  String botsPetImportReplaced(String name) {
    return '「$name」换成了新的';
  }

  @override
  String get botsPetImportNotZip => '这不是 zip 文件';

  @override
  String get botsPetImportNoPack => 'zip 里没有 pack.json';

  @override
  String botsPetImportBadPack(String detail) {
    return 'pack.json 有问题：$detail';
  }

  @override
  String botsPetImportMissingSheet(String name) {
    return 'zip 里少了序列帧图 $name';
  }

  @override
  String botsPetImportBadSheet(String name) {
    return '序列帧图不对：$name（要完整的 PNG，每边不超过 4096 像素，每一帧都在图内）';
  }

  @override
  String get botsPetImportTooLarge => '这个宠物包太大了';

  @override
  String get botsPetImportStorage => '没能存到手机上，再试一次';

  @override
  String botsPetRemoveTitle(String name) {
    return '删除「$name」？';
  }

  @override
  String get botsPetRemoveBody => '删除后可以再导入。';

  @override
  String botsPetRemoveFailed(String name) {
    return '没能删除「$name」，再试一次';
  }

  @override
  String get botsPetSize => '大小';

  @override
  String get botsPetCustomSize => '自定义大小';

  @override
  String get botsPetQuiet => '安静模式';

  @override
  String get botsPetQuietSubtitle => '只做动作，不冒气泡';

  @override
  String get botsPetShowNow => '立即显示';

  @override
  String botsPetHiddenUntil(String time) {
    return '藏到 $time';
  }

  @override
  String get botsKeyEsc => '发送 Esc';

  @override
  String get botsKeyTab => '发送 Tab';

  @override
  String get botsKeyLeft => '左';

  @override
  String get botsKeyUp => '上';

  @override
  String get botsKeyDown => '下';

  @override
  String get botsKeyRight => '右';

  @override
  String get botsKeyPipe => '竖线';

  @override
  String get botsKeyTilde => '波浪号';

  @override
  String get botsKeySlash => '斜杠';

  @override
  String get botsKeyDash => '短横线';

  @override
  String get botsTerminal => '终端';

  @override
  String get botsTerminalShowKeyboard => '唤起键盘';

  @override
  String get botsTerminalRename => '重命名终端';

  @override
  String get botsTerminalName => '终端名称';

  @override
  String get botsTerminalRenameFailed => '没能重命名';

  @override
  String botsTerminalCloseNamed(String title) {
    return '关闭「$title」？';
  }

  @override
  String get botsTerminalCloseBody => '里面的进程会结束';

  @override
  String get botsTerminalUnsupported => '这个连接用不了终端';

  @override
  String get botsTerminalSupportedHosts => '在本机、SSH 主机或 Remote 电脑上可用';

  @override
  String get botsTerminalOpening => '正在打开终端…';

  @override
  String get botsTerminalNone => '没有打开的终端';

  @override
  String get botsTerminalNew => '新建终端';

  @override
  String get botsTerminalClose => '关闭终端';

  @override
  String get botsTerminalChooseShell => '选择 Shell';

  @override
  String get botsTerminalShellFailed => '没能读取 Shell';

  @override
  String get botsTerminalReading => '正在读取…';

  @override
  String get botsTerminalDefaultShell => '默认 Shell';

  @override
  String get botsTerminalOtherDevice => '其他设备正在输入';

  @override
  String get botsTerminalTakeOver => '接管';

  @override
  String get botsTerminalStarting => '正在启动…';

  @override
  String get botsTerminalConnecting => '正在连接…';

  @override
  String get botsTerminalDisconnected => '连接已断开';

  @override
  String get botsTerminalReconnect => '重新连接';

  @override
  String get botsTerminalEnded => '已结束';

  @override
  String botsTerminalExitCode(int code) {
    return '已结束 · 退出码 $code';
  }

  @override
  String get botsTerminalGone => '这个终端已不在了';

  @override
  String get botsTerminalLimit => '先关掉不用的终端';

  @override
  String get botsToolWorkingRun => '正在运行命令';

  @override
  String botsToolApprovalRun(String name) {
    return '$name 想运行命令';
  }

  @override
  String get botsToolWorkingRead => '正在查看文件';

  @override
  String botsToolApprovalRead(String name) {
    return '$name 想查看文件';
  }

  @override
  String get botsToolWorkingEdit => '正在修改文件';

  @override
  String botsToolApprovalEdit(String name) {
    return '$name 想修改文件';
  }

  @override
  String get botsToolWorkingSearch => '正在联网搜索';

  @override
  String botsToolApprovalSearch(String name) {
    return '$name 想联网搜索';
  }

  @override
  String get botsToolWorkingBrowse => '正在看网页';

  @override
  String botsToolApprovalBrowse(String name) {
    return '$name 想看网页';
  }

  @override
  String get botsToolWorkingMessage => '正在联系其他 Bot';

  @override
  String botsToolApprovalMessage(String name) {
    return '$name 想联系其他 Bot';
  }

  @override
  String get botsToolWorkingGroup => '正在在群里沟通';

  @override
  String botsToolApprovalGroup(String name) {
    return '$name 想在群里沟通';
  }

  @override
  String get botsToolWorkingMemory => '正在整理记忆';

  @override
  String botsToolApprovalMemory(String name) {
    return '$name 想整理记忆';
  }

  @override
  String get botsToolWorkingRecall => '正在翻看记录';

  @override
  String botsToolApprovalRecall(String name) {
    return '$name 想翻看记录';
  }

  @override
  String get botsToolWorkingTeam => '正在安排团队';

  @override
  String botsToolApprovalTeam(String name) {
    return '$name 想安排团队';
  }

  @override
  String get botsToolWorkingAsk => '正在准备问你';

  @override
  String botsToolApprovalAsk(String name) {
    return '$name 想准备问你';
  }

  @override
  String get botsToolWorkingWork => '正在干活';

  @override
  String botsToolApprovalWork(String name) {
    return '$name 想干活';
  }

  @override
  String get botsEveryone => '所有人';

  @override
  String get botsActivelyRunning => '正在运行';

  @override
  String get botsListSeparator => '，';

  @override
  String get botsNameSeparator => '、';

  @override
  String get botsGlyphSubagent => '子代理';

  @override
  String get botsGlyphWebSearch => '联网搜索';

  @override
  String botsSenderPreview(String name, String preview) {
    return '$name：$preview';
  }

  @override
  String botsAgentSemantics(String title, String state) {
    return '$title，$state';
  }

  @override
  String botsViewMetric(Object label, Object value) {
    return '$label：$value';
  }

  @override
  String get botsEffortXhigh => '超高';

  @override
  String get botsRelayLimit => 'Bot 互叫上限';

  @override
  String get botsRelayLimitHint => '从你最近一次发言起，Bot 之间互叫达到此次数后暂停。填写 1–200 的整数，留空使用默认值。';

  @override
  String botsRelayLimitDefault(int count) {
    return '默认：$count';
  }

  @override
  String get botsRelayLimitInvalid => '请填写 1–200 的整数';

  @override
  String get botsRelayLimitRestore => '恢复默认';

  @override
  String get botsRelayLimitConnectionChanged => '连接已变化，请关闭后重新打开。';

  @override
  String get botsMobileUnsupportedTitle => 'DS Bot 暂不支持手机端';

  @override
  String get botsMobileApiRequired => '可先在网页版中使用';

  @override
  String get botsMobileApiMissing => '手机端暂不支持，可先在网页版中使用';

  @override
  String get botsCreationConnectionChanged => '连接已变化，请重新打开创建页面后再操作。';

  @override
  String get brandXiaomi => '小米 / Redmi';

  @override
  String get brandHuawei => '华为';

  @override
  String get brandHonor => '荣耀';

  @override
  String get brandOppo => 'OPPO / 一加 / realme';

  @override
  String get brandSamsung => '三星';

  @override
  String get brandVivoOs => 'vivo / iQOO（OriginOS）';

  @override
  String get brandXiaomiOs => '小米 / Redmi（HyperOS、MIUI）';

  @override
  String get brandHuaweiOs => '华为 / 荣耀（HarmonyOS、MagicOS）';

  @override
  String get brandOppoOs => 'OPPO / 一加 / realme（ColorOS）';

  @override
  String get brandSamsungOs => '三星（One UI）';

  @override
  String get brandZhihu => '知乎';

  @override
  String get catalogCurrentChat => '当前对话';

  @override
  String get catalogChatDetails => '对话详情';

  @override
  String get catalogChatDetailsSummary => '轨迹、改动与进度';

  @override
  String get catalogArtifacts => '产出的文件';

  @override
  String get catalogArtifactsSummary => '预览、分享、保存';

  @override
  String get catalogFiles => '文件';

  @override
  String get catalogFilesSummary => '浏览与预览';

  @override
  String get catalogTerminal => '终端';

  @override
  String get catalogTerminalSummary => '工作区里的终端';

  @override
  String get catalogExport => '导出对话日志';

  @override
  String get catalogExportSummary => '打包成 ZIP';

  @override
  String get catalogJobs => '后台任务';

  @override
  String get catalogJobsSummary => '查看输出、停止';

  @override
  String get catalogPlanGoal => '计划与目标';

  @override
  String get catalogPlanGoalSummary => '目标、计划与待办';

  @override
  String get catalogSkills => '技能';

  @override
  String get catalogSkillsSummary => '在对话里用技能';

  @override
  String get catalogSubagents => '子代理';

  @override
  String get catalogSubagentsSummary => '谱系与状态，点开接着聊';

  @override
  String get catalogReference => '引用文件和对话';

  @override
  String get catalogReferenceSummary => '在输入框用 @ 引用';

  @override
  String get catalogAutomationSection => '自动化';

  @override
  String get catalogSchedules => '自动化任务';

  @override
  String get catalogSchedulesSummary => '定时与周期任务';

  @override
  String get catalogAgentModelsSection => 'Agent 与模型';

  @override
  String get catalogPermission => '权限';

  @override
  String get catalogPermissionSummary => '执行前是否确认';

  @override
  String get catalogAgentPresets => 'Agent 预设';

  @override
  String get catalogAgentPresetsSummary => '新对话的工作方式';

  @override
  String get catalogModels => '模型';

  @override
  String get catalogModelsSummary => '订阅与自定义渠道';

  @override
  String get catalogSubagentSettings => '子代理设置';

  @override
  String get catalogSubagentSettingsSummary => '层数、并行与模型';

  @override
  String get catalogAgentLoop => 'Agent 循环';

  @override
  String get catalogAgentLoopSummary => '工具并行上限';

  @override
  String get catalogShellSettings => '命令执行';

  @override
  String get catalogShellSettingsSummary => '超时与输出上限';

  @override
  String get catalogWebSearch => '联网搜索';

  @override
  String get catalogWebSearchSummary => '搜索服务与预算';

  @override
  String get catalogPlugins => '插件';

  @override
  String get catalogPluginsSummary => '已安装与插件市场';

  @override
  String get catalogPluginInventory => '插件清单';

  @override
  String get catalogPluginInventorySummary => '已加载的全部插件';

  @override
  String get catalogCordisSummary => '插件创建的动态面板';

  @override
  String get catalogAgentTeam => '智能体团队';

  @override
  String get catalogAgentTeamSummary => '成员、任务板与消息';

  @override
  String get catalogCotTranslation => '思考过程翻译';

  @override
  String get catalogCotTranslationSummary => '展开思考后点「翻译」';

  @override
  String get catalogVoiceInput => '语音输入';

  @override
  String get catalogVoiceInputSummary => '输入框里的麦克风';

  @override
  String get catalogCommunitySharingSection => '社区与分享';

  @override
  String get catalogForum => '论坛';

  @override
  String get catalogForumSummary => '提问、分享、找同好';

  @override
  String get catalogCommunity => '社区';

  @override
  String get catalogCommunitySummary => '精选与交流群';

  @override
  String get catalogBotSummary => 'Bot 团队与群聊';

  @override
  String get catalogShareProfile => '分享配置';

  @override
  String get catalogShareProfileSummary => '插件、设置与技能';

  @override
  String get catalogHostsSettingsSection => '主机与设置';

  @override
  String get catalogSearch => '搜索对话';

  @override
  String get catalogSearchSummary => '按标题和正文查找';

  @override
  String get catalogNotifications => '通知';

  @override
  String get catalogNotificationsSummary => '完成与待确认提醒';

  @override
  String get catalogWorkspaces => '工作区';

  @override
  String get catalogWorkspacesSummary => '添加与切换目录';

  @override
  String get catalogGeneral => '通用设置';

  @override
  String get catalogGeneralSummary => '显示、发送与日志上传';

  @override
  String get catalogAccount => '账号与余额';

  @override
  String get catalogAccountSummary => '登录、余额与充值';

  @override
  String get catalogRemoteSummary => '连接电脑或服务器';

  @override
  String get catalogPhoneControl => '手机操控';

  @override
  String get catalogPhoneControlSummary => '看屏幕、帮你点按';

  @override
  String get catalogEngine => '本机引擎';

  @override
  String get catalogEngineSummary => '本机引擎状态与日志';

  @override
  String get catalogDiagnostics => '诊断';

  @override
  String get catalogDiagnosticsSummary => '导出诊断包';

  @override
  String get catalogWebSummary => 'DSH 官方界面';

  @override
  String get catalogPluginPanel => '插件面板';

  @override
  String get catalogHostPluginMissing => '这台主机没有这个插件';

  @override
  String get catalogAllFeatures => '全部功能';

  @override
  String get catalogAllFeaturesSubtitle => '网页版的功能，也都在这里';

  @override
  String get catalogOpenChatFirst => '先打开一个对话';

  @override
  String get catalogNoOpenChat => '还没打开对话';

  @override
  String get catalogOpenChat => '当前打开的对话';

  @override
  String get catalogOpenOrCreateChat => '先在聊天里打开或新建一个';

  @override
  String get catalogCordisHostClient => '后台和界面';

  @override
  String get catalogCordisHostOnly => '仅后台';

  @override
  String get catalogCordisClientOnly => '仅界面';

  @override
  String get catalogCordisPluginGone => '插件已经不在了';

  @override
  String get catalogCordisStopFailed => '没能停止';

  @override
  String get catalogCordisRemoveOne => '会停止它并删除。';

  @override
  String get catalogCordisRemove => '移除';

  @override
  String get catalogCordisRemoved => '已移除';

  @override
  String get catalogCordisRemoveFailed => '没能移除';

  @override
  String get catalogCordisChat => '所属对话';

  @override
  String get catalogCordisMakeup => '组成';

  @override
  String get catalogCordisStopping => '正在停止…';

  @override
  String get catalogCordisRemoving => '正在移除…';

  @override
  String get catalogSeatGone => '插件已不可用';

  @override
  String catalogCordisRemoveTitle(String name) {
    return '移除「$name」？';
  }

  @override
  String catalogCordisRemoveVersions(int versions) {
    return '会停止它，并删除全部 $versions 个版本。';
  }

  @override
  String catalogCordisVersionCount(int count) {
    return '$count 个';
  }

  @override
  String get catalogToolsSection => '工具';

  @override
  String get catalogAllSettings => '全部设置';

  @override
  String get diagnosticsForAi => '让 AI 看诊断';

  @override
  String get diagnosticsForAiHint => '把环境快照写进引擎，AI 自己读';

  @override
  String get diagnosticsForAiDone => '已写入诊断，问 AI「看下诊断」就行';

  @override
  String get diagnosticsForAiFailed => '写不进去：本机运行时还没装好';

  @override
  String get chatBackgroundTaskNotice => '后台任务通知';

  @override
  String get chatBackgroundTaskMessage => '后台任务消息';

  @override
  String get chatDeclineQuestion => '不回答';

  @override
  String get chatChats => '对话列表';

  @override
  String get chatViewChatDetails => '查看对话详情';

  @override
  String get chatUnsent => '未发送';

  @override
  String get chatFailedSubmission => '未送达 · 已保留';

  @override
  String get chatEditFailedSubmission => '编辑后重发';

  @override
  String get chatErrReasoningEffortUnsupported => '当前模型不支持此推理档位，请调整档位或换模型';

  @override
  String get chatSteerNextStep => '插话 · 下一步生效';

  @override
  String get chatQueuedAfterTurn => '排队中 · 本轮结束后发送';

  @override
  String get chatSteering => '插话中';

  @override
  String get chatQueued => '排队中';

  @override
  String get chatStoppingTurn => '正在停止本轮';

  @override
  String get chatSending => '发送中';

  @override
  String get chatSendNow => '立即发送';

  @override
  String get chatSwitchToSteer => '改为插话';

  @override
  String get chatWithdraw => '撤回';

  @override
  String get chatContinuedInNewChat => '已在新对话中继续';

  @override
  String get chatReadOriginalImageFailed => '读取原图失败，请重试';

  @override
  String get chatRegenerateFailed => '重新回答失败';

  @override
  String get chatRegeneratedInNewChat => '已在新对话中重新回答';

  @override
  String get chatOpenedInNewChatReattach => '已在新对话中打开，附件需重新添加';

  @override
  String get chatOpenedInNewChat => '已在新对话中打开';

  @override
  String chatForkQueuedLeft(String message, int left) {
    return '$message（$left 条排队消息未能带走）';
  }

  @override
  String get chatReturnToOriginal => '返回原对话';

  @override
  String chatWaitingCount(int count) {
    return '$count 项待确认';
  }

  @override
  String chatWaitingBackToBottom(int count) {
    return '$count 项待确认，回到底部';
  }

  @override
  String get chatBackToBottom => '回到底部';

  @override
  String get chatCreateFailed => '新建对话失败';

  @override
  String get chatSendMode => '发送方式';

  @override
  String get chatSteer => '插话';

  @override
  String get chatSteerHint => '不打断，AI 下一步会看到';

  @override
  String get chatInterruptAndSend => '中断并发送';

  @override
  String get chatInterruptHint => '停下当前任务，先处理这条';

  @override
  String get chatQueue => '排队';

  @override
  String get chatQueueHint => '本轮结束后发送';

  @override
  String get chatWithdrawnEditable => '已撤回，可修改后再发';

  @override
  String get chatWithdrawn => '已撤回';

  @override
  String chatAttachmentLimit(int count) {
    return '每条消息最多 $count 个附件';
  }

  @override
  String get chatAttachmentPermission => '没有权限，可在系统设置中开启';

  @override
  String get chatOpenAttachmentFailed => '没能打开附件';

  @override
  String get chatReadFailed => '读取失败';

  @override
  String get chatReadImageFailed => '没能读取图片';

  @override
  String get chatOpenChatFirst => '先打开一个对话';

  @override
  String get chatTurnCompleted => '这一轮已完成';

  @override
  String get chatTurnError => '这一轮出错了';

  @override
  String get chatAnswerHint => '输入回答…';

  @override
  String get chatAnswerMode => '发送文字将回答待答问题';

  @override
  String get chatMessageMode => '发送新消息';

  @override
  String get chatQuestionAnswered => '已回答';

  @override
  String get chatStarting => '正在启动';

  @override
  String get chatConnecting => '正在连接';

  @override
  String get chatDisconnected => '连接已断开';

  @override
  String get chatReconnecting => '重新连接中';

  @override
  String get chatGenerating => '生成中';

  @override
  String get chatGoToSettings => '去设置';

  @override
  String get chatListeningEllipsis => '正在聆听…';

  @override
  String get chatTranscribingEllipsis => '正在转写…';

  @override
  String get chatConnectToSend => '连接引擎后即可发送';

  @override
  String get chatGeneratingSteerHint => '生成中 · 可直接插话';

  @override
  String get chatComposerHint => '给 DSH 发消息…';

  @override
  String get chatStopGenerating => '停止生成';

  @override
  String get chatVoiceInput => '语音输入';

  @override
  String get chatStopVoiceInput => '停止语音输入';

  @override
  String get chatGoal => '目标';

  @override
  String get chatGoalActions => '目标操作';

  @override
  String get chatGoalBlocked => '受阻';

  @override
  String chatGoalRoundLimit(int rounds, int max) {
    return '第 $rounds / $max 轮';
  }

  @override
  String chatGoalRound(int rounds) {
    return '第 $rounds 轮';
  }

  @override
  String get chatEditGoal => '编辑目标';

  @override
  String get chatPauseGoal => '暂停';

  @override
  String get chatPauseGoalHint => '先不自动推进';

  @override
  String get chatResumeGoal => '恢复';

  @override
  String get chatResumeGoalHint => '继续自动推进';

  @override
  String get chatClearGoal => '清除目标';

  @override
  String get chatGoalHint => '要完成什么';

  @override
  String get chatClearGoalTitle => '清除目标？';

  @override
  String chatTodoCurrent(String content) {
    return '正在：$content';
  }

  @override
  String chatTodoNext(String content) {
    return '下一步：$content';
  }

  @override
  String get chatTodoAllDone => '全部完成';

  @override
  String chatTodoSemantics(String count, String label) {
    return '待办 $count，$label';
  }

  @override
  String get chatCollapseTodos => '收起清单';

  @override
  String get chatExpandTodos => '展开清单';

  @override
  String chatDockFolded(int count) {
    return '$count 条状态已叠起';
  }

  @override
  String get chatDockSpread => '展开';

  @override
  String get chatDockFold => '收起状态条';

  @override
  String get chatDockNext => '下一张';

  @override
  String get chatDockPrevious => '上一张';

  @override
  String get chatTodoNotStarted => '未开始';

  @override
  String get chatFile => '文件';

  @override
  String get chatFolder => '文件夹';

  @override
  String get chatChat => '对话';

  @override
  String get chatSubagent => '子代理';

  @override
  String get chatRecent => '最近';

  @override
  String get chatMentionSearching => '正在查找…';

  @override
  String get chatMentionNoFiles => '没有匹配的文件';

  @override
  String get chatMentionNoMatches => '没有匹配的文件或对话';

  @override
  String get chatQuote => '引用';

  @override
  String get chatOpenFolder => '打开文件夹';

  @override
  String get chatJustNow => '刚刚';

  @override
  String chatMentionAgeMinutes(int count) {
    return '$count分钟';
  }

  @override
  String chatMentionAgeHours(int count) {
    return '$count小时';
  }

  @override
  String chatMentionAgeDays(int count) {
    return '$count天';
  }

  @override
  String chatMentionAgeMonths(int count) {
    return '$count个月';
  }

  @override
  String chatMentionAgeYears(int count) {
    return '$count年';
  }

  @override
  String get chatMermaidChart => 'Mermaid 图表';

  @override
  String get chatPreview => '预览';

  @override
  String get chatUnwrapLines => '不换行';

  @override
  String get chatWrapLines => '自动换行';

  @override
  String get chatAlertNote => '注意';

  @override
  String get chatAlertTip => '提示';

  @override
  String get chatAlertImportant => '重要';

  @override
  String get chatAlertWarning => '警告';

  @override
  String get chatAlertCaution => '小心';

  @override
  String get chatImage => '图片';

  @override
  String get chatImageNotFound => '找不到图片';

  @override
  String get chatImageOffline => '未连接 DSH';

  @override
  String get chatImageTooLarge => '图片过大';

  @override
  String get chatImageReadFailed => '无法读取文件';

  @override
  String get chatImageDisplayFailed => '无法显示';

  @override
  String get chatImageTapToView => '轻点查看';

  @override
  String get chatImageTapToRetry => '轻点重试';

  @override
  String get chatImageUnsupportedAddress => '不支持的地址';

  @override
  String get chatMermaidNeedsNetwork => '需要联网';

  @override
  String get chatMermaidSyntaxError => '图表语法有误';

  @override
  String get chatChartPreview => '图表预览';

  @override
  String get chatCopyCode => '复制代码';

  @override
  String get chatChartClosed => '图表已关闭';

  @override
  String get chatVoiceMicrophoneFailed => '没能打开麦克风';

  @override
  String get chatVoicePermissionOff => '麦克风权限已关闭';

  @override
  String get chatVoicePermissionNeeded => '需要麦克风权限才能语音输入';

  @override
  String get chatVoiceUnavailable => '这台手机没有可用的语音识别';

  @override
  String get chatVoiceNotHeard => '没有听清，再说一次';

  @override
  String get chatVoiceTranscriptionFailed => '没能转写这段语音';

  @override
  String get chatVoiceNetworkFailed => '网络不太好，没能识别';

  @override
  String get chatVoiceLanguageUnsupported => '暂不支持这种语言';

  @override
  String get chatVoiceMicrophoneBusy => '麦克风正被占用';

  @override
  String get chatVoiceBusy => '语音识别正忙，稍后再试';

  @override
  String get chatVoiceRecognitionFailed => '语音识别出错了';

  @override
  String get chatListening => '正在聆听';

  @override
  String get chatTranscribing => '正在转写';

  @override
  String get chatCancelVoiceInput => '取消语音输入';

  @override
  String get chatViewTurnTrace => '查看本轮轨迹';

  @override
  String chatTokensPerSecond(int count) {
    return '约 $count tokens/秒';
  }

  @override
  String get chatNoTokensStreaming => '没有在出字';

  @override
  String chatCurrentStep(String step) {
    return '这一步 $step';
  }

  @override
  String chatTodoProgress(int done, int total) {
    return '待办进度 $done/$total';
  }

  @override
  String chatProgress(int done, int total) {
    return '进度 $done/$total';
  }

  @override
  String get chatApproveCommand => '允许运行这条命令？';

  @override
  String get chatApproveWrite => '允许写入这个文件？';

  @override
  String get chatApproveEdit => '允许修改这个文件？';

  @override
  String get chatApproveWebpage => '允许打开这个网页？';

  @override
  String get chatApproveSearch => '允许联网搜索？';

  @override
  String chatApproveTool(String name) {
    return '允许使用「$name」？';
  }

  @override
  String get chatDecline => '拒绝';

  @override
  String get chatAllowOnce => '允许本次';

  @override
  String get chatAllowForChat => '本对话都允许';

  @override
  String get chatSaveToDownloads => '存到「下载」';

  @override
  String get chatCopyPath => '复制路径';

  @override
  String get chatOpenInDefaultApp => '用默认应用打开';

  @override
  String get chatDownloadsFolderHint => '下载/DSH-Go 文件夹';

  @override
  String chatSavedToDownloadsPath(String path) {
    return '已存到 下载/$path';
  }

  @override
  String chatSavedToPath(String path) {
    return '已存到 $path';
  }

  @override
  String chatDeliveredFiles(int count) {
    return '交付了 $count 个文件';
  }

  @override
  String chatGeneratedFiles(int count) {
    return '生成了 $count 个文件';
  }

  @override
  String chatAllFiles(int count) {
    return '全部 $count 个文件';
  }

  @override
  String get chatCollapseFileList => '收起文件列表';

  @override
  String chatExpandAllFiles(int count) {
    return '展开全部 $count 个文件';
  }

  @override
  String get chatDownloading => '正在下载…';

  @override
  String chatDownloadingPercent(int percent) {
    return '正在下载… $percent%';
  }

  @override
  String get chatOpening => '正在打开…';

  @override
  String get chatSavingToDownloads => '正在存到「下载」…';

  @override
  String get chatOpenInPhoneApp => '用手机上的应用打开';

  @override
  String get chatMoreActions => '更多操作';

  @override
  String get chatAlreadyInDownloads => '已在手机的「下载」里';

  @override
  String get chatArtifactCopyPathOnly => '当前连接无法读取文件，只能复制路径';

  @override
  String get chatReplying => '正在回复';

  @override
  String get chatInterrupted => '已中断';

  @override
  String get chatGallery => '相册';

  @override
  String get chatTakePhoto => '拍照';

  @override
  String get chatAddAttachment => '添加图片或文件';

  @override
  String chatRemoveAttachment(String name) {
    return '移除「$name」';
  }

  @override
  String get chatAutoApproveCommands => '自动允许命令';

  @override
  String get chatAutoApproving => '自动允许中';

  @override
  String chatViewMoreChanges(int count) {
    return '查看改动，还有 $count 个文件';
  }

  @override
  String get chatViewChanges => '查看改动';

  @override
  String chatChangedFiles(int count) {
    return '改动了 $count 个文件';
  }

  @override
  String chatMoreFiles(int count) {
    return '还有 $count 个文件';
  }

  @override
  String chatFileChangeSemantics(String path, int added, int removed) {
    return '$path，新增 $added 行，删除 $removed 行';
  }

  @override
  String get chatNewFileSuffix => '  新建';

  @override
  String get chatPathCopied => '已复制路径';

  @override
  String chatCommandCompacted(int count, String tokens) {
    return '已压缩 $count 条历史记录（约 $tokens tokens）';
  }

  @override
  String chatCommandPermissionChanged(String name) {
    return '已切换为$name';
  }

  @override
  String chatCommandCurrentPermission(String name) {
    return '当前权限：$name';
  }

  @override
  String get chatCommandUnknownPermission => '没有这个权限预设';

  @override
  String get chatCommandFeedbackRequired => '写上反馈内容再发送';

  @override
  String get chatCommandFeedbackSubmitted => '反馈已提交';

  @override
  String get chatCommandNothingToCompact => '还没有可压缩的内容';

  @override
  String get chatCommandCompactionCancelled => '已取消压缩';

  @override
  String get chatCommandCompactionBusy => '正在忙，稍后再压缩';

  @override
  String get chatCommandCompactedSaveFailed => '已压缩，但没能保存';

  @override
  String get chatCommandCompactUsage => '/compact 不带参数';

  @override
  String get chatCommandHistoryChanged => '对话有变化，请再试一次';

  @override
  String get chatCommandCompactionFailed => '没能完成压缩，请再试一次';

  @override
  String get chatCommandCompactionIncomplete => '压缩未完成，请查看对话';

  @override
  String get chatCommandPlanEnabled => '已进入计划模式';

  @override
  String get chatCommandPlanEnabling => '下一步起进入计划模式';

  @override
  String get chatCommandPlanDisabled => '已退出计划模式';

  @override
  String get chatCommandPlanDisabling => '下一步起退出计划模式';

  @override
  String get chatCommandPlanCancelled => '已取消进入计划模式';

  @override
  String get chatCommandPlanInactive => '当前未开启计划模式';

  @override
  String get chatCommandPlanNoAttachments => '退出计划模式时不能附带文件';

  @override
  String get chatCommandNoGoal => '还没有目标';

  @override
  String get chatCommandGoalRequired => '写上新的目标再发送';

  @override
  String get chatCommandGoalAttachments => '附件需要和目标一起发送';

  @override
  String get chatCommandGoalCleared => '已清除目标';

  @override
  String get chatCommandGoalInvalid => '当前无法执行，请查看目标';

  @override
  String get chatCommandGoalExists => '已有目标，请编辑或清除后再设置';

  @override
  String get chatCommandGoalCreated => '已设置目标';

  @override
  String get chatCommandGoalUpdated => '已更新目标';

  @override
  String get chatCommandGoalPaused => '已暂停目标';

  @override
  String get chatCommandGoalResumed => '已继续目标';

  @override
  String get chatCommandCurrentGoal => '当前目标';

  @override
  String get chatCommandGoalBlocked => '等待处理';

  @override
  String chatCommandGoalSummary(String title, String objective, String status, int rounds, int max) {
    return '$title\n$objective\n$status · 第 $rounds/$max 轮';
  }

  @override
  String get chatCommandFailed => '执行失败';

  @override
  String get chatImageStorageDenied => '没有存储权限，未能保存';

  @override
  String get chatImageCannotSave => '这张图片无法保存';

  @override
  String get chatImageDownloadFailed => '图片下载失败，请重试';

  @override
  String get chatImageSaveFailed => '保存失败，请重试';

  @override
  String get chatImageSavedToPhotos => '已保存到相册';

  @override
  String get chatShareFailed => '无法打开分享';

  @override
  String get chatSubmit => '提交';

  @override
  String get chatSelectText => '选择文字';

  @override
  String get chatRegenerate => '重新回答';

  @override
  String get chatBranchFromHere => '从这里分叉';

  @override
  String get chatEditAndResend => '编辑后重发';

  @override
  String get chatRegenerateHint => '在新对话中重新生成，原对话不变';

  @override
  String get chatBranchHint => '在新对话中继续，原对话不变';

  @override
  String get chatEditResendHint => '在新对话中改写，图片和文件需重新添加；原对话不变';

  @override
  String get chatSaveToPhotos => '保存到相册';

  @override
  String get chatCopyAll => '全部复制';

  @override
  String get chatRequestRetrying => '请求失败，正在重试';

  @override
  String chatRequestRetryAttempt(int count) {
    return '请求失败，正在重试（第 $count 次）';
  }

  @override
  String chatRequestRetryLimit(int count, int max) {
    return '请求失败，正在重试（$count/$max）';
  }

  @override
  String chatSubscriptionExpired(String name) {
    return '$name 登录已失效';
  }

  @override
  String get chatProviderKeyMissing => '这个模型渠道还没有密钥';

  @override
  String get chatDeepSeekKeyMissing => '还没有 DeepSeek API Key';

  @override
  String get chatOutputLimitReached => '已达单次输出上限';

  @override
  String get chatTurnBlocked => '本轮已被拦截';

  @override
  String get chatTurnEngineRestarted => '引擎重启过，本轮已中断';

  @override
  String get chatSignInAgain => '重新登录';

  @override
  String chatQuestionsTitle(int count) {
    return '有 $count 个问题想问你';
  }

  @override
  String get chatOneQuestion => '有个问题想问你';

  @override
  String get chatMultipleChoices => '可多选';

  @override
  String get chatCustomAnswer => '其他回答';

  @override
  String get chatCustomAnswerHint => '输入你的回答';

  @override
  String chatQuoteSemantics(String text) {
    return '引用：$text';
  }

  @override
  String get chatRemoveQuote => '移除引用';

  @override
  String get chatReadOnlySubagent => '一次性子代理，只能查看';

  @override
  String get chatThinkingActive => '思考中';

  @override
  String get chatThinking => '思考';

  @override
  String get chatTranslate => '翻译';

  @override
  String get chatTranslationUnavailable => '翻译暂不可用';

  @override
  String get chatViewOriginal => '查看原文';

  @override
  String get chatViewTranslation => '查看译文';

  @override
  String get chatTranslating => '正在翻译';

  @override
  String chatToolFailures(String label, int count) {
    return '$label,$count 个失败';
  }

  @override
  String get chatToolNeedsApproval => '需要授权后才能执行';

  @override
  String get chatCommand => '命令';

  @override
  String chatToolLineRange(int first, int last) {
    return ' · 第 $first⁠–⁠$last 行';
  }

  @override
  String get chatParameters => '参数';

  @override
  String get chatOutput => '输出';

  @override
  String get chatResult => '结果';

  @override
  String get chatError => '错误';

  @override
  String get chatChanges => '改动';

  @override
  String get chatContent => '内容';

  @override
  String get chatNoOutput => '没有输出';

  @override
  String get chatToolDeclined => '已拒绝这次调用';

  @override
  String get chatToolRunning => '正在执行…';

  @override
  String get chatNoDetails => '暂无详情';

  @override
  String chatOutputHiddenLines(int count, String shown) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '中间省略 $shown 行');
    return '$_temp0';
  }

  @override
  String chatOutputHiddenChars(String count) {
    return '中间省略 $count 字';
  }

  @override
  String chatOutputSummary(int count, String lines, String chars) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '共 $lines 行');
    return '$_temp0 · $chars 字';
  }

  @override
  String get chatOutputViewAll => '查看全部';

  @override
  String get chatOutputCopyAll => '复制全文';

  @override
  String get chatOutputCopied => '已复制全文';

  @override
  String get chatOutputToEnd => '跳到末尾';

  @override
  String get chatOutputToStart => '回到开头';

  @override
  String get chatErrApiKey => 'API Key 无效或已过期';

  @override
  String get chatErrForbidden => '凭据不可用或权限不足';

  @override
  String get chatErrBalance => '余额不足';

  @override
  String get chatErrAccountQuota => '账号额度已用完';

  @override
  String get chatErrRateLimit => '请求太频繁，稍后再试';

  @override
  String get chatErrContextLength => '对话太长。若 /compact 也失败，请新建对话或换模型';

  @override
  String get chatErrModelUnavailable => '模型服务暂时不可用';

  @override
  String get chatErrModelTimeout => '模型响应超时';

  @override
  String get chatErrModelConnection => '没能连上模型服务';

  @override
  String get chatErrModelEmpty => '模型没有返回内容';

  @override
  String get chatErrEngineOutdated => '这个模型需要新版引擎';

  @override
  String get chatErrModelUnsupported => '当前模型不可用';

  @override
  String get chatSwitchModel => '换模型';

  @override
  String get chatErrTurn => '本轮出错了';

  @override
  String chatTurnSteps(int count) {
    return '$count 步';
  }

  @override
  String chatTurnFootnoteSemantics(String summary) {
    return '本轮 $summary，查看本轮轨迹';
  }

  @override
  String chatTurnToolCalls(int count) {
    return '$count 次工具调用';
  }

  @override
  String chatTurnMessages(int count) {
    return '$count 条消息';
  }

  @override
  String chatTurnThoughts(int count) {
    return '$count 段思考';
  }

  @override
  String get chatMe => '我';

  @override
  String chatGoalSemantics(String objective) {
    return '目标，$objective';
  }

  @override
  String chatGoalStateSemantics(String objective, String state) {
    return '目标，$objective，$state';
  }

  @override
  String chatTodoItemSemantics(String content, String state) {
    return '$content，$state';
  }

  @override
  String chatMentionSemantics(String kind, String label) {
    return '$kind：$label';
  }

  @override
  String chatArtifactSemantics(String name, String description) {
    return '$name，$description';
  }

  @override
  String get commonCancel => '取消';

  @override
  String get commonRetry => '重试';

  @override
  String get commonClose => '关闭';

  @override
  String get commonCopied => '已复制';

  @override
  String get commonSave => '保存';

  @override
  String get commonSettings => '设置';

  @override
  String get commonBack => '返回';

  @override
  String get commonCopy => '复制';

  @override
  String get commonDone => '完成';

  @override
  String get commonDelete => '删除';

  @override
  String get commonInstall => '安装';

  @override
  String get commonShare => '分享';

  @override
  String get commonAdd => '添加';

  @override
  String get commonEdit => '编辑';

  @override
  String get commonClear => '清除';

  @override
  String get commonCollapse => '收起';

  @override
  String get commonEnable => '启用';

  @override
  String get commonOpen => '打开';

  @override
  String get commonDetails => '详情';

  @override
  String get commonMore => '更多';

  @override
  String get commonCreate => '创建';

  @override
  String get commonSend => '发送';

  @override
  String get commonStop => '停止';

  @override
  String get commonPaste => '粘贴';

  @override
  String get commonHide => '隐藏';

  @override
  String get commonLater => '稍后';

  @override
  String get commonConfirm => '确认';

  @override
  String get commonRename => '重命名';

  @override
  String get commonContinue => '继续';

  @override
  String get commonNotSet => '未设置';

  @override
  String get commonDefault => '默认';

  @override
  String get commonSaved => '已保存';

  @override
  String get commonSaveFailed => '没能保存';

  @override
  String get commonSaveFailedRetry => '没能保存，请重试';

  @override
  String get commonFailedTryAgain => '没能完成，再试一次';

  @override
  String get commonEngineUnreachable => '没能连上引擎';

  @override
  String get commonStorageFull => '存储空间不足';

  @override
  String get commonConnectionFailed => '连接失败';

  @override
  String get commonCopyLink => '复制链接';

  @override
  String get commonOpenWith => '用其他应用打开';

  @override
  String get commonOpenInWeb => '在网页版打开';

  @override
  String get commonUntitledChat => '未命名对话';

  @override
  String get commonNewChat => '新对话';

  @override
  String get commonYesterday => '昨天';

  @override
  String get commonSignedIn => '已登录';

  @override
  String get commonSignIn => '登录';

  @override
  String get commonSignOut => '退出登录';

  @override
  String get commonThisPhone => '本机';

  @override
  String get commonRemoteHost => '远程主机';

  @override
  String get commonWeb => '网页版';

  @override
  String get commonFollowSystem => '跟随系统';

  @override
  String get commonLight => '浅色';

  @override
  String get commonDark => '深色';

  @override
  String get commonInProgress => '进行中';

  @override
  String get commonCompleted => '已完成';

  @override
  String get commonStopped => '已停止';

  @override
  String get commonCancelled => '已取消';

  @override
  String get commonRunning => '运行中';

  @override
  String get commonPaused => '已暂停';

  @override
  String get commonDeclined => '已拒绝';

  @override
  String get commonFailed => '失败';

  @override
  String get commonStopping => '正在停止';

  @override
  String get commonWaitingApproval => '等你确认';

  @override
  String get commonWaitingAnswer => '等你回答';

  @override
  String get commonNotConnected => '未连接';

  @override
  String get commonInstalled => '已安装';

  @override
  String get commonName => '名称';

  @override
  String get commonStatus => '状态';

  @override
  String get commonVersion => '版本';

  @override
  String get commonOther => '其他';

  @override
  String get commonPin => '置顶';

  @override
  String get commonReply => '回复';

  @override
  String get commonUpdate => '更新';

  @override
  String get commonViewLogs => '查看日志';

  @override
  String commonItemCount(int count) {
    return '$count 项';
  }

  @override
  String commonMonthDay(String month, int day) {
    return '$month月$day日';
  }

  @override
  String get companionTitle => '伙伴小屋';

  @override
  String get companionEntrySubtitle => '和她待一会儿';

  @override
  String get companionDefaultName => '她';

  @override
  String companionInputHint(String name) {
    return '和$name说点什么';
  }

  @override
  String get companionMenu => '更多';

  @override
  String get companionVoice => '语音';

  @override
  String get companionSystemAssistant => '系统数字助理';

  @override
  String get companionAssistantChoose => '选择默认数字助理';

  @override
  String get companionAssistantChooseHint => '在 Android 设置选中 DSH Go 小屋伙伴，再用手机的助理手势或按键唤起。';

  @override
  String get companionAssistantSelected => '小屋伙伴已设为默认助理。再次打开可切换回其他助理。';

  @override
  String get companionAssistantSettingsMissing => '找不到助理选择页。请在系统设置搜索「默认数字助理」。';

  @override
  String get companionAssistantSharePage => '带上唤起时的页面文字';

  @override
  String get companionAssistantSharePageHint => '仅使用 Android 允许提供的文字，发送本轮问题时交给伙伴模型。你可以在发送前移除。';

  @override
  String get companionAssistantPageAttached => '已附当前页面文字';

  @override
  String get companionAssistantCalendarAccess => '允许读取日历';

  @override
  String get companionAssistantCalendarHint => '让伙伴和手机工具读取可见日程。查询结果会发给当前模型。';

  @override
  String get companionAssistantCalendarAllowed => '已授权读取。点此可在系统应用权限中撤回。';

  @override
  String get companionAssistantAppPermissions => '打开系统应用权限';

  @override
  String get companionStop => '让她停下';

  @override
  String get companionSend => '发送';

  @override
  String get companionNotConnected => '现在连不上引擎，等一下再和我说吧。';

  @override
  String get companionSendFailed => '这句话没送出去，要不要再说一次？';

  @override
  String get companionAgentRetryClosed => '刚才那件事我可能已经动手了，怕做两遍。你先在「交代的事」里看一眼，再告诉我要不要接着来？';

  @override
  String get companionLogTitle => '聊天记录';

  @override
  String get companionContextUnsupported => '这台主机还不支持她的上下文：名字、设定、刚才发生的事和手机里的记忆都传不过去，只发你说的话。升级主机或换成轻量模式就好。';

  @override
  String get companionLogEmpty => '还没有说过话。';

  @override
  String get companionLogYou => '你';

  @override
  String get companionLogOpenChat => '在主对话里看';

  @override
  String get companionLogOlder => '加载更早的记录';

  @override
  String get companionMenuHistory => '查看聊天记录';

  @override
  String get companionMenuRestart => '重新认识';

  @override
  String get companionMenuRestartHint => '开始一段新对话';

  @override
  String get companionMenuRestartConfirm => '她会忘记这段对话。旧的记录还留在主机上，不会被删除。';

  @override
  String get companionMenuRemovePack => '移除素材';

  @override
  String get companionMenuRemoveConfirm => '这台手机上的角色素材会被删除，聊天记录不受影响。下次进来时要重新导入。';

  @override
  String companionCreditAuthor(String name) {
    return '作者：$name';
  }

  @override
  String get companionSetupTitle => '把她接回家';

  @override
  String get companionSetupBody => '角色素材不在 App 里，要用时才放进手机。选择素材包（zip）导入后就能见到她。';

  @override
  String get companionSetupImport => '导入素材包';

  @override
  String get companionFailedTitle => '她没能出来';

  @override
  String companionFailedBody(String reason) {
    return '这台手机上加载失败了（$reason）。可以重新导入素材包再试一次。';
  }

  @override
  String get companionFailedBodyPlain => '她刚才没加载出来。先重试，还不行再重新导入素材包。';

  @override
  String get companionPackBroken => '这个文件打不开，可能不是素材包或已经损坏。';

  @override
  String get companionPackRuntimeMismatch => '素材包里的运行库和这个版本的 App 对不上。';

  @override
  String get companionPackNoRuntime => '这个包只有角色，手机上还没有运行库。先导入完整的素材包。';

  @override
  String get companionPackNoModel => '包里没有找到 Live2D 模型（.model3.json）。把模型的整个文件夹打成 zip 再试。';

  @override
  String get companionPackUnsafe => '包里有不允许的文件或路径，没有导入。';

  @override
  String get companionPackTooLarge => '素材包太大了。';

  @override
  String get companionPackStorage => '写入失败，看看手机存储空间够不够。';

  @override
  String companionGreetFirst(String name) {
    return '你好呀，我是$name。以后就住在这里了，请多指教。';
  }

  @override
  String get companionGreetMorning => '早呀，今天也要好好吃早饭。';

  @override
  String get companionGreetNoon => '中午啦，吃过饭了吗？';

  @override
  String get companionGreetAfternoon => '下午好，我刚才在发呆。';

  @override
  String get companionGreetEvening => '晚上好，今天过得怎么样？';

  @override
  String get companionGreetLate => '这么晚还没睡呀？';

  @override
  String get companionGreetLong => '好久不见，我还以为你把我忘啦。';

  @override
  String get companionGreetBack => '嗯？又回来啦。';

  @override
  String get companionWake => '嗯……我没睡着，就是眯了一下。';

  @override
  String get companionPat1 => '嘿嘿……再摸一会儿也可以。';

  @override
  String get companionPat2 => '唔，好舒服。';

  @override
  String get companionPat3 => '头发要被你弄乱啦。';

  @override
  String get companionTapHead1 => '怎么啦？';

  @override
  String get companionTapHead2 => '嗯？';

  @override
  String get companionTapFace1 => '别戳脸啦。';

  @override
  String get companionTapFace2 => '哇，手好凉。';

  @override
  String get companionTapFace3 => '我脸上有东西吗？';

  @override
  String get companionTapBody1 => '哎，吓我一跳。';

  @override
  String get companionTapBody2 => '干嘛呀？';

  @override
  String get companionTapBody3 => '围裙刚洗过的！';

  @override
  String get companionTapTail1 => '尾巴不可以随便碰！';

  @override
  String get companionTapTail2 => '呀，好痒。';

  @override
  String get companionTapTail3 => '这可是很重要的尾巴。';

  @override
  String get companionTapLegs1 => '地上有什么吗？';

  @override
  String get companionTapLegs2 => '你在看哪里呀。';

  @override
  String get companionTease1 => '别闹了，头都晕了。';

  @override
  String get companionTease2 => '再戳就不理你了！';

  @override
  String get companionTease3 => '你是不是很闲？';

  @override
  String get companionShake1 => '哇啊，别摇啦！';

  @override
  String get companionShake2 => '头好晕……水都晃起来了。';

  @override
  String get companionShake3 => '再摇我要吐泡泡了！';

  @override
  String get companionStatusIdle => '在发呆';

  @override
  String get companionStatusListening => '在听你说';

  @override
  String get companionStatusThinking => '在想';

  @override
  String get companionStatusSpeaking => '在说话';

  @override
  String get companionStatusSleeping => '睡着了';

  @override
  String get companionStatusAway => '不在';

  @override
  String get companionListening => '在听…';

  @override
  String get companionTouchHint => '摸摸她的头试试';

  @override
  String get companionArriving => '她正在游过来…';

  @override
  String get companionPrivacyLine => '素材只存在这台手机上，聊天走当前主机。';

  @override
  String get companionMemoryTitle => '她记得的事';

  @override
  String get companionMemoryCard => '卡片';

  @override
  String get companionMemoryPerson => '人物档案';

  @override
  String get companionMemoryDiary => '日记';

  @override
  String get companionMemoryImpression => '她对你的印象';

  @override
  String get companionMemorySearchTitle => '记忆检索';

  @override
  String get companionMemorySearchDescription => '下载约24 MB的模型，用手机本地查找意思相近的记忆。';

  @override
  String get companionMemorySearchDownload => '下载模型';

  @override
  String get companionMemorySearchReady => '本地模型已就绪';

  @override
  String get companionMemorySearchDownloading => '正在下载…';

  @override
  String get companionMemorySearchFailed => '暂时无法准备本地模型。可以重试下载。';

  @override
  String get companionMemorySearchUnavailable => '此设备暂不支持本地记忆检索。';

  @override
  String companionMemoryScope(String host) {
    return '保存在$host，两种模式共用。你可以随时改或忘。';
  }

  @override
  String get companionMemoryAdd => '添加';

  @override
  String get companionMemoryEdit => '更新现况';

  @override
  String get companionMemorySave => '保存';

  @override
  String get companionMemoryHint => '比如：我喜欢无糖的茶，不喝咖啡';

  @override
  String get companionMemoryForget => '忘掉';

  @override
  String get companionMemoryForgetTitle => '让她忘掉这件事？';

  @override
  String get companionMemoryEmpty => '还没有记下什么';

  @override
  String get companionMemoryEmptyHint => '你们聊过的事，她会自己慢慢记住。想让她特别记着什么，也可以写在这里。';

  @override
  String get companionMemoryUnsupported => '这台主机还不能保存她的记忆';

  @override
  String get companionMemoryUnsupportedHint => '经 DSH Remote 中继连接时用不了，或者这台主机的 dsh-go 桥接比较旧。';

  @override
  String get companionMemoryLoadFailed => '没读到';

  @override
  String get companionMemoryRetry => '重试';

  @override
  String get companionMemoryConflict => '刚才另一处改过了，已经刷新';

  @override
  String get companionMemoryFull => '记满了，先删掉一些吧';

  @override
  String get companionMemorySaveFailed => '没保存上，再试一次吧';

  @override
  String get companionStatusSnacking => '在吃点心';

  @override
  String get companionStatusPlaying => '在玩泡泡';

  @override
  String get companionStatusResting => '在软垫上歇着';

  @override
  String get companionSnack1 => '啊呜——好吃！';

  @override
  String get companionSnack2 => '是海苔味的，谢谢你。';

  @override
  String get companionSnack3 => '嗯……我还能再吃一块吗？';

  @override
  String get companionPlay1 => '嘿，接住啦！';

  @override
  String get companionPlay2 => '泡泡软软的，好好玩。';

  @override
  String get companionPlay3 => '它又飘回去了。';

  @override
  String get companionRest1 => '那我在这儿靠一会儿。';

  @override
  String get companionRest2 => '你说，我听着呢。';

  @override
  String get companionTouchHintHome => '点点贝壳、泡泡和软垫，点心还能拖到她嘴边';

  @override
  String get companionMenuMode => '对话方式';

  @override
  String get companionModeLight => '轻量';

  @override
  String get companionModeLightHint => '只聊天。手机直连模型，不用启动引擎';

  @override
  String get companionModeFull => '完整';

  @override
  String get companionModeFullHint => '主机上的 DSH 引擎，带工具和手机操控';

  @override
  String get companionLightNoKey => '轻量模式要用 DeepSeek API Key，在设置里填上就能和我聊啦。';

  @override
  String get companionLightBadKey => 'API Key 好像不对，或者已经失效了。';

  @override
  String get companionLightBusy => '那边有点忙，等一下再和我说吧。';

  @override
  String get companionNotConnectedTryLight => '现在连不上电脑那边。你可以检查连接，或在「对话方式」里换成轻量模式。';

  @override
  String get companionHostModelUnavailable => '电脑那边还没选好模型。选好后我们再聊，或在「对话方式」里换成轻量模式。';

  @override
  String get companionHostUnavailable => '电脑那边暂时接不了这次对话。检查连接和更新后再试，或在「对话方式」里换成轻量模式。';

  @override
  String get companionMenuRestartLightHint => '开始新对话，保留旧记录';

  @override
  String get companionMenuRestartLightConfirm => '开始一段新对话。她记得的事和旧聊天记录都会保留。';

  @override
  String get companionInviteRest => '要不要陪我在软垫上歇一会儿？';

  @override
  String get companionInviteAccept => '好呀';

  @override
  String get companionInviteDecline => '等会儿';

  @override
  String get companionInviteYes1 => '嘿嘿，就歇一小会儿。';

  @override
  String get companionInviteYes2 => '那我先躺好啦，你也放松点。';

  @override
  String get companionMenuPace => '她多主动';

  @override
  String get companionPaceHint => '她只在你安静陪着她时开口：邀你歇一会儿，或提一句别的对话。深夜不说，每次进门最多邀一次。';

  @override
  String get companionPaceQuiet => '安静';

  @override
  String get companionPaceQuietHint => '不主动开口，你找她时才说话';

  @override
  String get companionPaceRare => '偶尔';

  @override
  String get companionPaceRareHint => '一天最多 2 次，至少隔 6 小时';

  @override
  String get companionPaceOften => '常常';

  @override
  String get companionPaceOftenHint => '一天最多 6 次，至少隔 2 小时';

  @override
  String get companionPaceChatty => '话多';

  @override
  String get companionPaceChattyHint => '一天最多 12 次，至少隔半小时';

  @override
  String get companionSetupBundled => '接她回家';

  @override
  String get companionSetupBodyBundled => '她就在 App 里，点一下就到，素材只解压到这台手机上。也可以导入别的素材包，或者把 Live2D 模型的文件夹打成 zip 直接导入。';

  @override
  String get companionSetupImportOther => '导入别的素材包';

  @override
  String get companionMenuRemoveConfirmBundled => '这台手机上解压出来的角色素材会被删除，聊天记录不受影响。之后随时可以再接她回来。';

  @override
  String get companionHug1 => '唔……抱抱。';

  @override
  String get companionHug2 => '被你这样抱着，好安心。';

  @override
  String get companionHug3 => '再抱一会儿，就一会儿。';

  @override
  String get companionBondTitle => '你们的关系';

  @override
  String get companionBond0 => '初识';

  @override
  String get companionBond1 => '熟悉';

  @override
  String get companionBond2 => '朋友';

  @override
  String get companionBond3 => '亲近';

  @override
  String get companionBond4 => '很亲';

  @override
  String get companionBond5 => '离不开';

  @override
  String get companionCloser1 => '好像……没那么紧张了。';

  @override
  String get companionCloser2 => '和你待着，越来越自在了。';

  @override
  String get companionCloser3 => '以后也要常来哦，我会想你的。';

  @override
  String get companionCloser4 => '你在的时候，连安静待着都很开心。';

  @override
  String get companionCloser5 => '不知不觉，已经很习惯有你在了。';

  @override
  String get companionPatClose => '最喜欢被你摸头了。';

  @override
  String get companionHugClose => '抱紧一点也没关系哦。';

  @override
  String get companionTaskDoneUntitled => '你那边的任务跑完啦。';

  @override
  String get companionTaskFailedUntitled => '你那边的任务好像出错了，要去看看吗？';

  @override
  String get companionTaskOpen => '去看看';

  @override
  String get companionMenuSignals => '她会提起什么';

  @override
  String get companionAlwaysOn => '她一直在';

  @override
  String get companionAlwaysOnHint => '离开小屋她也在。通知栏里留着她，可以直接回她一句';

  @override
  String get companionAlwaysOnRunning => '她在通知栏里陪着你';

  @override
  String get companionAlwaysOnNoNotify => '通知被关了，打开后才能在通知栏里回她';

  @override
  String get companionAlwaysOnFailed => '这次没能留下来，再开一次试试';

  @override
  String get companionSignalsHint => '这些只在小屋里说给你听，不会发给模型。说多说少跟着「她多主动」，和邀请共用次数，深夜不说；选「安静」她也不说。';

  @override
  String get companionSignalState => '留意别的对话';

  @override
  String get companionSignalStateHint => '这台主机上别的对话跑完或出错时，她心里有数';

  @override
  String get companionSignalSpeech => '提一句';

  @override
  String get companionSignalSpeechHint => '挑你安静的时候说一句';

  @override
  String get companionSignalVoice => '用声音说出来';

  @override
  String get companionSignalVoiceHint => '她的声音开着时，把这句读出来';

  @override
  String get companionSignalNight => '深夜提醒你休息';

  @override
  String get companionSignalNightHint => '深夜在小屋里待了一阵，她轻轻提醒一次';

  @override
  String get companionSignalLateUse => '这么晚了还陪着我……要不要早点歇一会儿？';

  @override
  String get companionRecallTitle => '完整模式里自动想起记忆';

  @override
  String get companionRecallHint => '打开时换一段新对话；改动她记得的事会自动关掉';

  @override
  String get companionRecallConfirm =>
      '打开后，她确认过的记忆（最多 12 条）会跟着完整模式里她的每次回复一起发给模型。会开始一段新对话，现在这段留在主对话列表里。改动记忆后会自动关掉，到时可以再打开。';

  @override
  String get companionRecallTurnOn => '打开';

  @override
  String get companionRecallOn => '好，从这段新对话起，我会想着你让我记住的事。';

  @override
  String get companionRecallBusy => '另一个对话正在用自动想起记忆，先在那边关掉再来';

  @override
  String get companionRecallUnsupported => '这台主机现在开不了自动想起记忆';

  @override
  String get companionRecallFailed => '自动想起记忆没打开，再试一次吧';

  @override
  String get companionRecallOff => '自动想起记忆关了，下一句会开始一段新对话';

  @override
  String get companionRecallOffFailed => '自动想起记忆没关掉，再试一次吧';

  @override
  String get companionRecallStopped => '自动想起记忆停了（她记得的事有改动），换成了一段新对话。想要的话可以在菜单里再打开。';

  @override
  String get companionMenuVoice => '她的声音';

  @override
  String get companionMenuVoiceHint => '用手机自带的语音读出她说的话';

  @override
  String get companionVoiceHello => '你好呀，这是我的声音。喜欢的话就留着吧。';

  @override
  String get companionVoiceUnavailable => '这台手机没有能用的中文语音。可以在系统设置的「文字转语音」里装一个。';

  @override
  String get companionWidgetWaiting => '在小屋里等你';

  @override
  String get companionVoiceOn => '让她出声';

  @override
  String get companionVoiceOffHint => '打开时她会先用选好的声音打个招呼。';

  @override
  String get companionVoiceOff => '关';

  @override
  String get companionVoiceSource => '声音来源';

  @override
  String get companionVoiceSystem => '手机自带';

  @override
  String get companionVoiceSystemHint => '系统的文字转语音，不联网也能用';

  @override
  String get companionVoiceOpenai => 'OpenAI 兼容接口';

  @override
  String get companionVoiceOpenaiHint => 'OpenAI、硅基流动，以及大多数自建的 GPT-SoVITS、CosyVoice、edge-tts 服务';

  @override
  String get companionVoiceCustom => '自定义 HTTP';

  @override
  String get companionVoiceCustomHint => '别的接口：自己填请求和返回的格式';

  @override
  String get companionVoiceApi => '接口';

  @override
  String get companionVoiceBase => '地址';

  @override
  String get companionVoiceBaseHelper => '填到 /v1 为止，App 会接上 /audio/speech';

  @override
  String get companionVoiceKeyHelper => '存在这台手机的安全存储里';

  @override
  String get companionVoiceModel => '模型';

  @override
  String get companionVoiceVoice => '音色';

  @override
  String get companionVoiceVoiceHelper => '服务给的音色名，比如 alloy，或你自建服务里的角色名';

  @override
  String get companionVoiceRequest => '请求';

  @override
  String get companionVoiceUrl => '请求地址';

  @override
  String get companionVoiceUrlHelper => '地址里也可以用 {text}';

  @override
  String get companionVoiceMethod => '方法';

  @override
  String get companionVoiceHeaders => '请求头';

  @override
  String get companionVoiceHeadersHelper => '每行一个；会存进安全存储';

  @override
  String get companionVoiceBody => '请求体';

  @override
  String get companionVoiceBodyHelper => '{text} 会换成她要说的话';

  @override
  String get companionVoiceField => '音频字段';

  @override
  String get companionVoiceFieldHelper => '返回 JSON 时，音频在哪个字段（base64 或链接），比如 data.audio；直接返回音频就留空';

  @override
  String get companionVoicePrivacy => '她要说的话会发给你填的这个服务。';

  @override
  String get companionVoicePreview => '试听';

  @override
  String get companionVoicePreviewing => '正在请求…';

  @override
  String get companionVoicePreviewOk => '能用，听到了吗？';

  @override
  String companionVoicePreviewFailed(String reason) {
    return '没成功：$reason';
  }

  @override
  String get companionVoiceNotSetUp => '先把上面的地址填好。';

  @override
  String get companionVoiceFallback => '外接的声音这次没连上，先用了手机自带的声音';

  @override
  String get companionGreetFirstNameless => '你好呀，以后我就住在这里了，请多指教。';

  @override
  String companionRenamed(String name) {
    return '「$name」……好，以后我就叫这个名字啦。';
  }

  @override
  String get companionVoicePreset => '常用服务';

  @override
  String get companionVoicePresetHint => '小米 MiMo、OpenAI、硅基流动、阿里云百炼：填个 Key 就能用';

  @override
  String get companionVoiceService => '服务';

  @override
  String companionVoiceKeyWhere(String site) {
    return '在 $site 申请；存在这台手机的安全存储里';
  }

  @override
  String get companionVoiceVoiceCustomHelper => '点一个，或者直接填服务给的音色 ID';

  @override
  String get companionVoiceStyle => '说话风格';

  @override
  String get companionVoiceStyleHelper => '描述她说话的语气，服务会照着读；留空用默认的温柔少女音';

  @override
  String get companionVoiceFemale => '女声';

  @override
  String get companionVoiceMale => '男声';

  @override
  String get companionClonePreset => '预置音色';

  @override
  String get companionCloneMine => '克隆声音';

  @override
  String get companionVoicePresetVoice => '预置音色';

  @override
  String get companionCloneRecording => '录音';

  @override
  String get companionCloneHelper => '5–30 秒、只有一个人在说话、没有背景音的 mp3 或 wav，最大 7 MB。请只用你自己的声音，或本人同意过的声音。她说的每句话都会带上这段录音发给小米。';

  @override
  String get companionCloneNone => '还没有录音';

  @override
  String companionCloneReady(String detail) {
    return '已上传 · $detail';
  }

  @override
  String companionCloneSeconds(int n) {
    return '$n 秒';
  }

  @override
  String get companionClonePick => '选一段录音';

  @override
  String get companionCloneReplace => '换一段';

  @override
  String get companionCloneTooLarge => '录音太大了，最大 7 MB。剪短一点再试。';

  @override
  String get companionCloneNotAudio => '只支持 mp3 或 wav 格式的录音。';

  @override
  String get companionCloneFailed => '没能读取这段录音。';

  @override
  String get companionMenuPersona => '她的设定';

  @override
  String get companionPersonaName => '名字';

  @override
  String get companionPersonaNameHelper => '留空用素材包里的名字';

  @override
  String get companionPersonaCallMe => '她怎么叫你';

  @override
  String get companionPersonaCallMeHint => '比如 小周';

  @override
  String get companionPersonaCallMeHelper => '留空就不特别称呼';

  @override
  String get companionPersonaText => '人设';

  @override
  String get companionPersonaTextLabel => '她是谁、怎么说话';

  @override
  String get companionPersonaTextHelper => '性格、身份、说话方式、哪些话不说，都写在这里，删改随你。只有表情动作的标记格式由 App 自动加上。';

  @override
  String get companionPersonaReset => '恢复默认';

  @override
  String get companionPersonaFooter => '轻量模式下一句就生效；完整模式会在你下一条消息里把新设定告诉她。';

  @override
  String get companionMenuMoves => '动作和表情';

  @override
  String get companionMovesHint => '这些是模型自带的。开着的会交给 AI（表情、动作各最多 24 个，按列表顺序），她回复时会自己用；点名字改个好懂的叫法，点 ▶ 先在她身上试试。';

  @override
  String get companionMovesNone => '这个模型没有自带的表情和动作，她用的是内置的那些。';

  @override
  String get companionMovesRename => '改个叫法';

  @override
  String get companionMovesTry => '试一下';

  @override
  String get companionPackLegacyModel =>
      '这是 Cubism 2 的旧模型（.moc 和 model.json），手机上的运行库只认 Cubism 3 以后的 .moc3。用 Cubism Editor 打开后导出成 moc3 再导入就行。';

  @override
  String companionFailedMocVersion(String version, String latest) {
    return '这个模型是用更新版本的 Cubism 导出的（moc 版本 $version），手机上的运行库最高只认到 $latest。在 Cubism Editor 里导出成旧一点的版本再导入就行。';
  }

  @override
  String get companionMenuAdapt => '适配这个模型';

  @override
  String get companionAdaptHint =>
      '用你配好的模型（你的 Key，按次计费）看一遍这个角色，把转头、眨眼、表情和摸哪里对上。会发出去的：模型名、参数名单、表情动作和部件的名字、你下面写的话和现在的适配表；模型文件和贴图不发。';

  @override
  String get companionAdaptOffer => '这个模型要适配一下：用你配好的模型看一遍它的参数名单和表情动作的名字（不发模型文件），会用你的 Key 调用一次。以后的新模型就自动来，菜单里能关。';

  @override
  String get companionAdaptOfferYes => '适配';

  @override
  String get companionAdaptOfferNo => '不用了';

  @override
  String get companionAdaptNote => '哪里不对？（可以不填）';

  @override
  String get companionAdaptNoteHint => '比如：摸头没反应，开心的时候脸是黑的';

  @override
  String get companionAdaptRun => '让 AI 适配';

  @override
  String get companionAdaptUndo => '撤销适配';

  @override
  String get companionAdaptAuto => '导入新模型时自动适配';

  @override
  String get companionAdaptStart => '让我适应一下这个新身体……';

  @override
  String get companionAdaptDone => '好啦，这个身体我会用了。';

  @override
  String companionAdaptDoneNote(String note) {
    return '好啦，这个身体我会用了。$note';
  }

  @override
  String get companionAdaptUndone => '好，换回原来的样子了。';

  @override
  String get companionAdaptNoKey => '要用你的模型帮我适配，先在设置里填上 API Key。';

  @override
  String companionAdaptFailed(String reason) {
    return '这次没适应好（$reason），可以在菜单的「适配这个模型」里再试一次。';
  }

  @override
  String get companionAdaptUnreadable => '模型的回答看不懂';

  @override
  String get companionAdaptEmpty => '模型没找到能用的对应';

  @override
  String get companionAdaptNetwork => '网络不通';

  @override
  String get companionMemoryMigrationPending => '旧记忆还没搬完，原来的资料已保留。稍后可以再试。';

  @override
  String get companionMemoryWaiting => '这次还没整理好，原话已保存在手机上。';

  @override
  String get companionMemoryWidgetPending => '小组件上那句旧话稍后会清掉。';

  @override
  String get companionMemoryConfiguration => '当前通道还不能自动记下新内容。原话已留好，也可以直接改手记。';

  @override
  String get companionMemoryWording => '只改文字';

  @override
  String get companionMemoryPin => '置顶';

  @override
  String get companionMemoryUnpin => '取消置顶';

  @override
  String get companionMemoryConfirmReality => '这是我的现实情况';

  @override
  String get companionMemorySources => '我的原话';

  @override
  String get companionMemoryEditSource => '修改这句原话';

  @override
  String get companionMemoryDeleteSource => '删除手机原话';

  @override
  String get companionMemoryDeleteSourceHint => '删除手机保存的这句原话及只靠它的记忆。主机旧对话和你另存的副本不会随之删除。';

  @override
  String get companionMemoryNoSource => '这条是手写的，或原来的出处已经找不到了。';

  @override
  String get companionMemoryCleanupUnknown => '还不能确认所有该删的原话，这次没有删除。';

  @override
  String get companionMemoryTooLong => '原话太长，这一版未自动提取';

  @override
  String get companionMemoryNotExtracted => '这一批没有自动记下来';

  @override
  String get companionMemoryPending => '还没自动整理';

  @override
  String get companionMemorySourceKept => '原话保留';

  @override
  String get companionMemoryDisplayOnly => '旧记录，仅保留原文';

  @override
  String get companionMemoryCancelled => '计划已取消';

  @override
  String get companionMemoryLess => '少主动提';

  @override
  String get companionMemoryNever => '别主动提';

  @override
  String get companionMemoryNormal => '以后可以聊';

  @override
  String get companionMemoryCancelPlan => '取消这项计划';

  @override
  String get companionMemoryActions => '这件事的选项';

  @override
  String get companionMemoryWhich => '你说的是哪件事呀？';

  @override
  String get companionMemoryForgotten => '好，忘掉了。';

  @override
  String get companionMemoryNeverDone => '嗯，不提了。';

  @override
  String get companionMemoryLessDone => '好，我少说一点。';

  @override
  String get companionMemoryNormalDone => '好呀，想聊的时候随时聊。';

  @override
  String get companionMemoryCancelledDone => '好，那就不等着问你了。';

  @override
  String get companionMemoryCorrected => '啊，是我记岔了。';

  @override
  String get companionMemoryHostSourceRemaining => '手机原话已删除。主机的旧对话仍保留；需要时可在对话列表删除那段对话。';

  @override
  String get companionMemoryHostRestarted => '主机刚重启过。这句话已留好，再点一次发送就能接着聊。';

  @override
  String get companionMemoryUsage => '模型用量';

  @override
  String get companionMemoryUsageHint => '最近的请求记录。未知不表示免费；费用按已核费率估算，不是供应商账单。主机记录只覆盖已捕获的伙伴聊天。';

  @override
  String get companionMemoryUsageUnknown => '未知';

  @override
  String get companionMemoryUsageExtract => '记下内容';

  @override
  String get companionMemoryUsageOrganize => '整理记忆';

  @override
  String get companionMemoryUsageChat => '聊天';

  @override
  String get companionMemoryUsageWaiting => '等待本次的用量记录';

  @override
  String get companionMemoryUsageIncomplete => '本次用量范围仍不完整，已知记录已保留';

  @override
  String get companionMemoryUsageInput => '未缓存输入';

  @override
  String get companionMemoryUsageCacheRead => '缓存读取';

  @override
  String get companionMemoryUsageCacheWrite => '缓存写入';

  @override
  String get companionMemoryUsageOutput => '输出';

  @override
  String get companionMemoryUsageCost => '估算费用';

  @override
  String get companionMemoryUsageNotSent => '本地未发出';

  @override
  String get companionMemoryUsageEmpty => '还没有记录到用量';

  @override
  String get companionMemoryHostUnsupported => '这台主机的版本有点旧，在这里她暂时想不起你们聊过的事。升级主机就好。';

  @override
  String get companionMemoryPostponedDone => '好，那等你定了新时间再说。';

  @override
  String get companionTasksTitle => '交代的事';

  @override
  String get companionTasksEmpty => '你还没交代我什么事呢。';

  @override
  String get companionTasksEarlier => '更早的事';

  @override
  String get companionTaskMissing => '这件事我这儿找不到了。';

  @override
  String get companionTaskChanged => '这件事后来又改过了，我按最新的来。';

  @override
  String get companionReminderEdit => '改提醒';

  @override
  String get companionReminderCancel => '不用提醒了';

  @override
  String get companionReminderText => '提醒你什么';

  @override
  String get companionReminderWhen => '哪天几点';

  @override
  String get companionReminderWhenHint => '比如 2026-11-21 08:00';

  @override
  String get companionReminderZone => '时区';

  @override
  String get companionReminderZoneHint => '比如 Asia/Shanghai 或 +08:00';

  @override
  String get companionReminderQueued => '好，提醒记下了，还没确认设好。';

  @override
  String get companionReminderDone => '设好了，到点我叫你。';

  @override
  String get companionReminderUnknown => '这条提醒我不太确定设上没，你看一眼系统闹钟？';

  @override
  String get companionReminderFailed => '这条提醒没设上，抱歉。';

  @override
  String get companionReminderCancelled => '好，这条不提醒了。';

  @override
  String get companionReminderTextMissing => '要提醒你什么呀？';

  @override
  String get companionReminderDateMissing => '哪天提醒你？';

  @override
  String get companionReminderTimeMissing => '那天几点提醒你？';

  @override
  String get companionReminderZoneMissing => '按哪个时区算？';

  @override
  String get companionReminderGap => '那天这个钟点会被跳过去（夏令时），换个时间吧。';

  @override
  String get companionReminderOverlap => '那天这个钟点有两次，要哪一次？';

  @override
  String get companionReminderFirst => '第一次';

  @override
  String get companionReminderSecond => '第二次';

  @override
  String get companionReminderExactMissing => '手机还没让我准点提醒，这条没设上。去系统设置里打开「闹钟和提醒」就好。';

  @override
  String get companionReminderNotificationsMissing => '通知没开，这条还没设上。去系统设置里打开通知就好。';

  @override
  String get companionReminderChannelMissing => '「提醒」这类通知被关掉了，这条还没设上。去系统设置里打开就好。';

  @override
  String get companionReminderGroupMissing => '提醒所在的那组通知被关掉了，这条还没设上。去系统设置里打开就好。';

  @override
  String get companionReminderTimePassed => '约好的时间已经过了，我就没再补响。';

  @override
  String get companionReminderInvalidTime => '这个时间我没弄明白，再告诉我一次哪天、几点、哪个时区？';

  @override
  String get companionReminderCancelUnknown => '取消的要求已记下，还没确认这条提醒已撤下。';

  @override
  String get companionReminderWhich => '你说的是哪一条？去「交代的事」里点给我看看。';

  @override
  String get companionReminderSyntax => '告诉我哪天几点吧，比如“明早八点提醒我带证件”。';

  @override
  String get companionReminderSaveFailed => '刚才没记下来，你写的还在，再试一次？';

  @override
  String get companionReminderSettings => '去系统设置';

  @override
  String get companionReminderCheck => '刷新';

  @override
  String get companionReminderUnknownNotification => '这条提醒可能已经响过了，我不太确定。';

  @override
  String companionReminderUnhandled(String text) {
    return '这句我还没法帮你办：$text';
  }

  @override
  String companionReminderCancelSource(String text) {
    return '取消$text的提醒';
  }

  @override
  String get companionReminderNotHere => '这条不是在这台手机上设的，我在这儿改不了也撤不了。';

  @override
  String get companionReminderPlatformUnavailable => '现在看不到手机上的提醒，等会儿再看看？';

  @override
  String get companionReminderPastRegistration => '之前是设好过的。';

  @override
  String get companionLookupAccepted => '好，我去查一下，查完放在「交代的事」里。';

  @override
  String get companionLookupSyntax => '想查哪家馆、哪一天？告诉我全名和日期吧。';

  @override
  String get companionLookupDateMissing => '想查哪一天的？给我个具体日期。';

  @override
  String get companionLookupZoneMissing => '那边是哪个时区？日期和时区一起告诉我吧。';

  @override
  String get companionLookupWhich => '你想撤哪个查询？去「交代的事」里点一下。';

  @override
  String get companionLookupQueued => '我在查了，稍等。';

  @override
  String get companionLookupDone => '查到了，出处放在下面。';

  @override
  String get companionLookupPartial => '查到一些，但那天到底怎样还说不准。';

  @override
  String get companionLookupFailed => '这次没找到靠得住的说法，没法确定。';

  @override
  String get companionLookupUnknown => '这次没得到明确结果，我先不重复去查。';

  @override
  String get companionLookupCancelled => '好，不查了。';

  @override
  String get companionLookupCancelUnknown => '已记下不再查，还没确认原来的查询已停。';

  @override
  String get companionLookupUnavailable => '现在连不上能查的地方，还没查到结果。';

  @override
  String get companionLookupDeadline => '约好的时间过了，就查到这儿，不再接着查了。';

  @override
  String get companionLookupInputLimit => '资料太多，我一次读不完，先把出处给你。';

  @override
  String get companionLookupQueryLong => '名字有点长，换个简短点、不会认错的叫法？';

  @override
  String get companionLookupAnswerIncomplete => '资料找到了，但我还没理清楚，先把出处给你。';

  @override
  String get companionLookupNotHere => '这个不是在这台手机上查的，在这儿我只能给你看看结果。';

  @override
  String get companionLookupSources => '我看过的地方';

  @override
  String get companionLookupSearchOnly => '只看了搜索摘要，没点进去细看';

  @override
  String get companionLookupNoTitle => '没有标题';

  @override
  String get companionLookupCancel => '不用查了';

  @override
  String get companionLookupSaveFailed => '刚才没办成，等会儿再试试？';

  @override
  String companionLookupCancelSource(String name) {
    return '取消$name的查询';
  }

  @override
  String companionLookupObservedAt(String time) {
    return '$time 看的';
  }

  @override
  String companionLookupViewSources(String name) {
    return '看看出处 · $name';
  }

  @override
  String get companionNotesTitle => '把笔记整理成待办';

  @override
  String get companionNotesView => '看看这件事';

  @override
  String get companionNotesSyntax => '要整理哪天的笔记？你离开以后要不要接着做？说好了我再请你选文件夹。';

  @override
  String get companionNotesDateMissing => '日期、时区或者截止时间还没说清楚，再告诉我一下？';

  @override
  String get companionNotesConnect => '先连上放笔记的那台电脑，再选文件夹。';

  @override
  String get companionNotesOriginalHost => '这件事在原来那台电脑上，连上它我才能接着看。';

  @override
  String get companionNotesUnavailable => '这台电脑现在还接不了这件事。';

  @override
  String get companionNotesNoDirectory => '还没选文件夹，所以还没开始。';

  @override
  String get companionNotesChooseDirectory => '选笔记文件夹';

  @override
  String get companionNotesChooseOutput => '选存放的文件夹';

  @override
  String get companionNotesKeepDirectory => '笔记文件夹不变';

  @override
  String get companionNotesKeepOutput => '存放的文件夹不变';

  @override
  String get companionNotesWhich => '想撤哪一件整理？去「交代的事」里点一下。';

  @override
  String get companionNotesQueued => '记下了，等电脑接手。';

  @override
  String get companionNotesRunning => '电脑接下这件事了，结果还没出来。';

  @override
  String get companionNotesDone => '整理好了，待办存成了新文件，点开就能看。';

  @override
  String get companionNotesPartial => '只整理了一部分就停了，已有的可以先看看。';

  @override
  String get companionNotesFailed => '这次没整理成。';

  @override
  String get companionNotesWaiting => '这件事暂时还做不了，先留在这里。';

  @override
  String get companionNotesUnknown => '电脑那边现在什么情况，我还不太清楚。';

  @override
  String get companionNotesCancelUnknown => '已记下不再整理，还没确认电脑是否停下。已经写好的文件会保留。';

  @override
  String get companionNotesCancelled => '好，不整理了，已经写好的文件还在。';

  @override
  String get companionNotesPauseUnavailable => '你说过离开就先停，可我现在没法确定你离没离开，所以还没开始。要不改成离开也接着做？';

  @override
  String get companionNotesOpportunityLost => '刚才没赶上交给电脑，你又说过别等它上线。要继续的话再跟我说一声。';

  @override
  String get companionNotesDeadline => '约好的截止时间过了，就不再接着做了。';

  @override
  String get companionNotesOriginalPending => '电脑收到你的修改了，稍等它理一理。';

  @override
  String get companionNotesSaveFailed => '刚才没办成，这件事还在，等会儿再试试？';

  @override
  String get companionNotesModifiedDay => '我会把这个文件夹里那天改过的笔记（Markdown 和纯文本）整理成一页待办，原文件不动。';

  @override
  String get companionNotesNoInputs => '那天这个文件夹里没有改过的笔记，所以没写待办。';

  @override
  String get companionNotesOutputExists => '已经有同名文件了，我没覆盖它。改个新文件名就好。';

  @override
  String get companionNotesFileCountLimit => '符合的笔记超过 20 份，有点多。换个小点的文件夹，或者分几次来？';

  @override
  String get companionNotesFileSizeLimit => '有一份笔记超过 64 KiB，太长了。缩小点范围吧，我不想只读一半。';

  @override
  String get companionNotesTotalSizeLimit => '这些笔记加起来超过 256 KiB，有点多。缩小范围，或者分几次来？';

  @override
  String get companionNotesModelLimit => '笔记太多，我一次读不下。缩小点范围吧，我不想只读一半。';

  @override
  String get companionNotesPause => '离开就先停';

  @override
  String get companionNotesForegroundStart => '在这里继续';

  @override
  String get companionNotesForegroundReady => '留在这里时，我请电脑继续做。离开后会请它先停，回来再核对进度。';

  @override
  String get companionNotesForegroundUnknown => '还没确认电脑现在的进度，先刷新看看。';

  @override
  String get companionNotesContinue => '离开也接着做';

  @override
  String get companionNotesAllowQueue => '电脑不在线就等它上线再做';

  @override
  String get companionNotesNoQueue => '电脑不在线就别等了';

  @override
  String get companionNotesApproval => '电脑那边要你点个头，才能接着做。';

  @override
  String get companionNotesOpenFile => '看看这页待办';

  @override
  String get companionNotesFileMissing => '这个文件找不到了，我没重新生成。';

  @override
  String get companionNotesFileChanged => '这个文件后来被改过，已经不是我当时写的样子了。';

  @override
  String get companionNotesFileUnknown => '这个文件现在打不开。';

  @override
  String get companionNotesCancel => '不用整理了';

  @override
  String get companionNotesEdit => '改一下';

  @override
  String get companionNotesDate => '哪天的笔记';

  @override
  String get companionNotesFilename => '新文件名（.md 或 .txt）';

  @override
  String get companionNotesDeadlineField => '新的截止时间（不填就不变）';

  @override
  String get companionNotesClearDeadline => '不设截止时间';

  @override
  String get companionNotesKeepDeadline => '截止时间不变';

  @override
  String companionNotesSourceDirectory(String path) {
    return '笔记在：$path';
  }

  @override
  String companionNotesOutputDirectory(String path) {
    return '存到：$path';
  }

  @override
  String companionNotesDue(String time) {
    return '$time 前做完';
  }

  @override
  String companionNotesCancelSource(String name) {
    return '取消《$name》的笔记整理';
  }

  @override
  String companionNotesAmendSource(
    String date,
    String name,
    String deadline,
    String afterExit,
    String queue,
    String source,
    String output,
  ) {
    return '把笔记整理改成：$date的笔记，存成《$name》，截止时间：$deadline；$afterExit；$queue；$source；$output。';
  }

  @override
  String get companionNotesRetry => '让电脑接着做';

  @override
  String get companionNotesSubmitSaved => '现在交给电脑';

  @override
  String get companionNotesResendOriginal => '再交给电脑一次';

  @override
  String get companionNotesResendCancel => '再跟电脑说一次不做了';

  @override
  String get companionNotesResendAmend => '再把改动发给电脑';

  @override
  String get companionMapChoose => '用哪个地图打开？';

  @override
  String get companionMapSystemChoice => '让我在系统里选择';

  @override
  String get companionMapDone => '地址已交给地图打开。';

  @override
  String get companionMapUnknown => '还不能确定地图有没有打开，不会自动再打开。';

  @override
  String get companionMapCancelled => '已取消这次打开。如果地图已经打开，不会替你关闭。';

  @override
  String get companionMapUnavailable => '现在用不了地图，地址还在，可以复制。';

  @override
  String get companionMapNotHere => '这是之前留下的记录。需要的话，可以复制地址或再打开一次。';

  @override
  String get companionMapFailed => '地图没打开，地址在这里，可以复制。';

  @override
  String get companionMapChoiceWaiting => '刚才打开的是选择页面，还不能确定地址交给了哪个地图。';

  @override
  String get companionMapWaiting => '这次还没打开地图，地址已保留。';

  @override
  String get companionMapQueued => '地址记下了，还没打开地图。';

  @override
  String get companionMapSyntax => '请给一个明确的完整地址，例如：在地图打开“文华路 18 号东门”。有多个地址时，请先选一个。';

  @override
  String get companionMapWhich => '想改哪个地址，或重新打开哪一个？可以在交代的事里选。';

  @override
  String get companionMapNoTarget => '这次没选地图，还没有打开。';

  @override
  String get companionMapSaveFailed => '这次没能确认地图是否打开；不会自动再试。';

  @override
  String companionMapTarget(String label) {
    return '所选地图：$label';
  }

  @override
  String get companionMapCopy => '复制原地址';

  @override
  String get companionMapView => '查看地址';

  @override
  String get companionMapReopen => '再打开一次';

  @override
  String get companionMapCancel => '取消这次打开';

  @override
  String get companionMapReopenSource => '用地图再次打开这个地址';

  @override
  String get companionMapCancelSource => '取消这个地址的地图打开';

  @override
  String get companionFindTitle => '找稿件';

  @override
  String get companionFindSyntax => '请说明在哪个文件夹这一层找、找哪天改过的稿件，以及你离开后还要不要继续。有截止时间的话，也一起告诉我。';

  @override
  String get companionFindWhich => '要停下哪次找稿？可以在交代的事里选。';

  @override
  String get companionFindConnect => '还没选过这台电脑上的文件夹。请先连上电脑选一下。';

  @override
  String get companionFindSavedDirectory => '选一个之前用过的文件夹';

  @override
  String get companionFindSeven => '你说的七点是上午还是晚上？';

  @override
  String get companionFindMorningSeven => '上午 07:00';

  @override
  String get companionFindEveningSeven => '晚上 19:00';

  @override
  String get companionFindDeadlineMissing => '还没定好截止时间，这次先不开始。';

  @override
  String companionFindChooseDirectory(String name) {
    return '选择“$name”文件夹';
  }

  @override
  String get companionFindChooseAgain => '重新选择文件夹';

  @override
  String get companionFindKeepDirectory => '还找原来的文件夹';

  @override
  String get companionFindUnavailable => '这台电脑现在还不能帮你找稿并打开原稿。';

  @override
  String get companionFindNoDirectory => '还没选文件夹，这次先不开始。';

  @override
  String get companionFindDone => '找完了，结果在下面。';

  @override
  String get companionFindPartial => '这次没能全找完，已找到的稿件和没查完的地方在下面。';

  @override
  String get companionFindFailed => '这次没能找完，原来的记录还在。';

  @override
  String get companionFindWaiting => '暂时还没能继续找，稍后可以再查看。';

  @override
  String get companionFindCancelled => '已停止继续找，之前找到的清单还在。';

  @override
  String get companionFindCancelUnknown => '已记下不再找，但还没确认电脑是否停下。已有清单还在。';

  @override
  String get companionFindCancel => '停止找稿';

  @override
  String get companionFindCancelSource => '取消这次找稿';

  @override
  String companionFindAmendSource(
    String date,
    String formats,
    String deadline,
    String afterExit,
    String queue,
    String source,
  ) {
    return '修改找稿：只找这一层在 $date 改过的 $formats 文件。截止：$deadline；$afterExit；$queue；$source。';
  }

  @override
  String get companionFindDate => '稿件修改日期';

  @override
  String companionFindScope(String formats) {
    return '只找这一层在这一天修改的 $formats 文件，不改原稿。';
  }

  @override
  String companionFindSourceDirectory(String path) {
    return '查找目录：$path';
  }

  @override
  String get companionFindReport => '这次找到的稿件';

  @override
  String get companionFindPreviousReport => '之前找到的稿件';

  @override
  String companionFindCoverage(String entries, String supported, String matches) {
    return '查看了 $entries 项，其中 $supported 份是所选格式，找到 $matches 份符合日期的稿件。';
  }

  @override
  String get companionFindEnumerationComplete => '这一层的文件名已检查完，能否打开见下面的结果。查找时后来加入的文件可能不在结果里。';

  @override
  String get companionFindEnumerationPartial => '还有一些地方没查完。';

  @override
  String get companionFindEntryLimit => '这次最多检查 200 项，剩下的还没查。';

  @override
  String get companionFindCandidateLimit => '符合日期的稿件超过 20 份，这次先列出其中 20 份。';

  @override
  String get companionFindEmpty => '查过的范围里，没有这一天改过的所选格式稿件。';

  @override
  String companionFindGap(String name) {
    return '这项还没查清楚：$name';
  }

  @override
  String companionFindModified(String time) {
    return '修改时间：$time';
  }

  @override
  String get companionFindWasOpenable => '当时能打开；现在点开时会确认它有没有变化。';

  @override
  String get companionFindWasUnreadable => '当时没能读到这份稿件。';

  @override
  String get companionFindOpenSource => '打开这份原稿';

  @override
  String get companionFindSourceOffline => '清单还在。连上原来的电脑后才能打开稿件。';

  @override
  String get companionFindSourceMissing => '这份稿件现在找不到了，当时的清单还在。';

  @override
  String get companionFindSourceChanged => '这份稿件已被替换或修改，不能确认还是当时那一份。';

  @override
  String get companionFindSourceUnreadable => '这份稿件现在没能完整打开；没有换成别的文件。';

  @override
  String get companionFindSourceUnknown => '现在还打不开这份稿件，请连上原来的电脑再试。';

  @override
  String get companionFindDeadline => '已经过了约好的时间，不会再开始新的查找。已有结果会留在这里。';

  @override
  String get companionFindOriginalPending => '电脑已收到修改，还需要确认原先那次找稿。';

  @override
  String get companionFindUnknown => '还没确认电脑有没有收到，或找到了哪一步。';

  @override
  String get companionCompareTitle => '对比两版稿件';

  @override
  String get companionCompareA => 'A · 旧稿';

  @override
  String get companionCompareB => 'B · 新稿';

  @override
  String get companionCompareSyntax => '请按 A 旧稿、B 新稿选这两份，说明是否等电脑上线、离开后是否继续；如果有截止时间，也请说清楚。';

  @override
  String get companionCompareWhich => '要停止哪次对稿？请打开那件事再点停止。';

  @override
  String get companionCompareDeadlineMissing => '这次还没确定截止时刻，请把日期、时间和时区说清楚。';

  @override
  String get companionCompareUnavailable => '这台电脑目前还不能对比两份稿件。';

  @override
  String get companionCompareConnect => '先连上原来的电脑，选好 A 旧稿和 B 新稿；还没有可供离线选择的两份原稿。';

  @override
  String get companionCompareAmbiguousFile => '这个名字对应不止一份已选稿件。请连上原来的电脑重新选。';

  @override
  String get companionCompareNoInputs => '还没选齐两份原稿，这次没有开始对比。';

  @override
  String get companionCompareOriginalHost => '约定和已有结果会保留。连上原来的电脑后再查看。';

  @override
  String get companionCompareSaveFailed => '这次对稿还没核清，请稍后再查看这件事。';

  @override
  String companionCompareSaved(String side) {
    return '选择之前选过的 $side';
  }

  @override
  String companionCompareChooseDirectory(String side) {
    return '选择 $side 所在的文件夹';
  }

  @override
  String companionCompareFilename(String side) {
    return '输入 $side 的文件名';
  }

  @override
  String get companionCompareFileLimit => '输入所选文件夹内的确切文件名。只支持 Markdown 或 txt，每份最多 64 KiB；不会改动原文件。';

  @override
  String get companionCompareFilenameMissing => '请填写文件名。';

  @override
  String get companionCompareQueued => '两份稿件记下了，等电脑接手。';

  @override
  String get companionCompareRunning => '两份稿件已经交给电脑了，对照还没出来。';

  @override
  String get companionCompareDone => '两份稿件的对照已经准备好。';

  @override
  String get companionComparePartial => '这次只完成了一部分，已核的变化和还没核清的地方在下面。';

  @override
  String get companionCompareCancelled => '已停止继续对稿，之前留下的对照还在。';

  @override
  String get companionCompareCancelUnknown => '已记下停止对稿，还没确认电脑是否停下。已有结果会保留。';

  @override
  String get companionCompareWaiting => '这次还不能继续对稿，原来的两份选择和约定会保留。';

  @override
  String get companionCompareUnknown => '还没核清电脑做到哪里，不会自动重新比较。';

  @override
  String get companionCompareFailed => '这次没能完成两稿对比，原文件没有因此被改写。';

  @override
  String get companionCompareDeadline => '原定时间已经到了，不会把这次对稿顺延到别的时间。';

  @override
  String get companionCompareOriginalPending => '修改已经记下，原来的两稿约定还没补齐。';

  @override
  String get companionCompareReport => '这次的文字对照';

  @override
  String get companionCompareUnfinishedReport => '未完成的对照';

  @override
  String get companionComparePreviousReport => '之前留下的文字对照';

  @override
  String get companionCompareUnread => '这份稿件还没有完整读到。';

  @override
  String get companionCompareChanged => '读到过这份稿件，但交还结果时没能确认还是原来那一份。';

  @override
  String get companionCompareIncomplete => '这次还有没完成的部分，已确认的文字变化会保留。';

  @override
  String get companionCompareIdentical => '这次读到的两份稿件没有文字改动。';

  @override
  String companionCompareCoverage(String total, String shown) {
    return '这次核到 $total 组文字变化，列出其中 $shown 组。';
  }

  @override
  String get companionCompareSourceOrder => '下面按原文顺序列出已核的改动，还没排出重练重点。';

  @override
  String companionCompareDifference(String number) {
    return '文字变化 $number';
  }

  @override
  String get companionCompareNoExcerpt => '这一侧没有可展示的原文短句。';

  @override
  String get companionCompareSuggestions => '排练建议';

  @override
  String companionComparePractice(String number, String practice) {
    return '变化 $number：$practice';
  }

  @override
  String get companionCompareSuggestionsUnknown => '排练建议还没核清，已核的文字变化会保留。';

  @override
  String get companionCompareSuggestionsMissing => '还没准备好排练建议，下面保留已核的文字变化。';

  @override
  String companionCompareParagraph(String range) {
    return '第 $range 段';
  }

  @override
  String companionCompareBetween(String before, String after) {
    return '第 $before 段与第 $after 段之间';
  }

  @override
  String companionCompareAfter(String number) {
    return '第 $number 段后';
  }

  @override
  String companionCompareBefore(String number) {
    return '第 $number 段前';
  }

  @override
  String companionCompareLines(String range) {
    return '第 $range 行附近';
  }

  @override
  String get companionCompareCancel => '停止对稿';

  @override
  String get companionCompareCancelSource => '取消这次对稿，保留已经交还的对照。';

  @override
  String companionCompareAmendSource(String deadline, String exit, String queue, String inputs) {
    return '修改这次对稿：$deadline；$exit；$queue；$inputs。两个原文件都别动。';
  }

  @override
  String get companionCompareChooseAgain => '重新选择 A 旧稿和 B 新稿';

  @override
  String get companionCompareKeepInputs => '保留原来选定的 A 旧稿和 B 新稿';

  @override
  String get companionCompareNewDeadline => '填写时按这次修改所用的当地时区解释；留空则保留原定截止。';

  @override
  String get companionReceiptTitle => '票据整理';

  @override
  String get companionReceiptSyntax => '请说清是哪四张票、新表的名字，以及离开后是否继续。我只会新建，不覆盖旧表。';

  @override
  String get companionReceiptUnavailable => '这台电脑目前不能整理这些票据。';

  @override
  String get companionReceiptConnect => '先连回原电脑，选好四张票和放新表的文件夹；没有选过的原件，我不能替你猜。';

  @override
  String get companionReceiptWhich => '想停哪一张表？请到那件事里点取消。';

  @override
  String get companionReceiptSaveFailed => '这次还没交妥，原话留着。稍后可再试。';

  @override
  String get companionReceiptOriginalHost => '要连回原来的电脑才能继续交代或查看结果。';

  @override
  String get companionReceiptNoInputs => '四张票和放表的文件夹还没选齐，这次先不交给电脑。';

  @override
  String companionReceiptInput(String index) {
    return '第 $index 份';
  }

  @override
  String companionReceiptSavedInput(String index) {
    return '选之前选过的第 $index 份票据';
  }

  @override
  String companionReceiptChooseDirectory(String index) {
    return '第 $index 份票据在哪个文件夹？';
  }

  @override
  String companionReceiptFilename(String index) {
    return '第 $index 份票据的文件名';
  }

  @override
  String companionReceiptFormats(String formats) {
    return '这台电脑可读 $formats，每份最多 4 MiB。请填所选文件夹中的文件名。';
  }

  @override
  String get companionReceiptSavedOutput => '把新表放到之前选过的哪个文件夹？';

  @override
  String get companionReceiptQueued => '手机记下了，还没交给电脑。';

  @override
  String get companionReceiptRunning => '电脑已经接了，还没有可交的表。';

  @override
  String get companionReceiptDone => '新表已经写好，约定的字段都核实了。';

  @override
  String get companionReceiptPartial => '新表已经写好，还有几项没核实，表里已说明。';

  @override
  String get companionReceiptCancelled => '后面不再做了。此前已写好的表仍留着。';

  @override
  String get companionReceiptFailed => '这次没做成可交的新表，下面保留已查到的情况。';

  @override
  String get companionReceiptWaiting => '这件事还在等条件，尚未写好表。';

  @override
  String get companionReceiptUnknown => '还没核清表有没有写好，先查原来那件事，不另做一张。';

  @override
  String get companionReceiptCancelUnknown => '已记下先停后面的事；刚才的表有没有写好，还要向原电脑核实。';

  @override
  String get companionReceiptNoFields => '这四张目前没有可用于成表的已核实字段，没有创建空表。';

  @override
  String get companionReceiptOutputExists => '那里已有同名文件，我没有覆盖。可以改一个新文件名再交代。';

  @override
  String get companionReceiptDeadline => '已经过了约定时间，不再开始新的整理；此前的结果仍可核对。';

  @override
  String get companionReceiptOriginalPending => '电脑还没收齐原来的交代，暂时不会开始做表。';

  @override
  String get companionReceiptReport => '已查到的票据字段';

  @override
  String get companionReceiptPreviousReport => '此前查到的票据字段';

  @override
  String companionReceiptCoverage(String count) {
    return '四份里，$count 份有已核实的字段。';
  }

  @override
  String get companionReceiptImageScope => '这里只读取了 PDF 的文字层，图片里的日期或其他字段没有核实。';

  @override
  String get companionReceiptUnread => '这份原件还没完整读到。';

  @override
  String get companionReceiptParseFailed => '这份原件的文字还没完整提取出来。';

  @override
  String get companionReceiptChanged => '发布前没能核准还是原来的那份，这行不能当作已核实。';

  @override
  String get companionReceiptDate => '日期';

  @override
  String get companionReceiptItem => '项目';

  @override
  String get companionReceiptAmount => '金额';

  @override
  String companionReceiptUnverified(String reason) {
    return '未核：$reason';
  }

  @override
  String get companionReceiptFieldUnknown => '原文还不足以确认';

  @override
  String companionReceiptSourcePosition(String from, String to) {
    return '第 $from–$to 行';
  }

  @override
  String companionReceiptPdfPosition(String page, String from, String to) {
    return '第 $page 页，文字提取第 $from–$to 行';
  }

  @override
  String companionReceiptOpenWorkbook(String name) {
    return '打开 $name';
  }

  @override
  String get companionReceiptOpenFailed => '现在没能打开当时那份表。原来的完成记录仍保留，不会自动重做。';

  @override
  String get companionReceiptChooseAgain => '重新选择四张票';

  @override
  String get companionReceiptKeepInputs => '四张票仍用原来的';

  @override
  String get companionReceiptOutputName => '新表文件名（.xlsx）';

  @override
  String get companionReceiptCancelSource => '取消这次整理票据，后面没做的先停，已写好的表保留。';

  @override
  String companionReceiptAmendSource(
    String name,
    String deadline,
    String afterExit,
    String queue,
    String inputs,
    String output,
  ) {
    return '把这次票据整理改为新建《$name》；截止：$deadline；离开以后：$afterExit；等待电脑：$queue；原件：$inputs；目标文件夹：$output。';
  }

  @override
  String get companionReceiptNoText => '没有读到可用文字层，图片里的字段还没核实。';

  @override
  String get companionReceiptPassword => '原件需要密码，这次未能读取。';

  @override
  String get companionReceiptPdfUnavailable => '这台电脑还不能提取 PDF 文字。';

  @override
  String get companionReceiptLimit => '超过这次可读取的大小、页数或文字范围。';

  @override
  String get companionReceiptDateUnknown => '没有可核实的完整日期，或日期有歧义。';

  @override
  String get companionReceiptItemUnknown => '没有可核实的明确项目。';

  @override
  String get companionReceiptAmountUnknown => '金额或币种还不能确认。';

  @override
  String get companionReceiptKeepOutput => '仍放原来的文件夹';

  @override
  String get companionReceiptPriorResult => '此前约定写出的表已找到；新的约定尚未完成。';

  @override
  String get companionLegacyConversation => '旧对话（角色未记录）';

  @override
  String get companionScreen => '陪你看屏幕';

  @override
  String get companionScreenHint => '隔一会儿看一眼屏幕，有值得说的才开口；看到的不会记下来';

  @override
  String get companionScreenNeedsAccess => '要先打开手机操控的无障碍，或者允许她录屏';

  @override
  String get companionScreenAllowProjection => '允许录屏';

  @override
  String get companionScreenVision => '允许发送屏幕图片';

  @override
  String get companionScreenVisionHint => '发图前要先用本机文字识别（OCR）查一遍隐私，所以得开着它。图片最长边 512 像素，不会保存';

  @override
  String get companionScreenVisionTextOnly => '现在的截图方式只能读到文字；要发图片，得用无障碍截图并开着本机文字识别';

  @override
  String get companionScreenVisionModel => '看图使用的模型';

  @override
  String get companionScreenVisionChoose => '选择支持图片的模型';

  @override
  String get companionScreenVisionAvailable => '所选模型能看图；开着本机文字识别时才会发图，图片不会保存';

  @override
  String get companionScreenVisionChecking => '正在检查所选模型，先只用文字';

  @override
  String get companionScreenVisionUnavailable => '当前连接或模型不能看图，看屏时只用文字';

  @override
  String get companionScreenFrequency => '多久开口';

  @override
  String get companionScreenQuiet => '安静';

  @override
  String get companionScreenQuietHint => '很少开口，只说要紧的';

  @override
  String get companionScreenNormal => '正常';

  @override
  String get companionScreenNormalHint => '看到有意思的会说一句';

  @override
  String get companionScreenChatty => '话多';

  @override
  String get companionScreenChattyHint => '多陪你聊几句';

  @override
  String get companionScreenUsageAccess => '让她知道你在用哪个 App';

  @override
  String companionScreenCost(String amount) {
    return '今天大概花了 ¥$amount';
  }

  @override
  String get companionNotices => '她会留意你的通知';

  @override
  String get companionNoticesHint => '你选的 App 来了通知，她看一眼，值得说的才开口';

  @override
  String get companionNoticesNeedsAccess => '还差一步：允许 DSH Go 读取通知';

  @override
  String get companionNoticesAllow => '去授权';

  @override
  String get companionNoticesApps => '她看哪些 App';

  @override
  String get companionNoticesAppsEmpty => '开启后收到过通知的 App 会出现在这里';

  @override
  String companionNoticesAppCount(int count) {
    return '7 天内 $count 条';
  }

  @override
  String get companionNoticesQuiet => '最近没来过通知';

  @override
  String companionNoticesToday(int received, int said) {
    return '今天收到 $received 条 · 她说了 $said 次';
  }

  @override
  String get companionNoticesFooter =>
      '通知会发给你给她配置的模型（现在是 DeepSeek），只发你选的 App 的。原文不存，只存她记下的那几句近况，在记忆页能看到、能删；本机另外只留条数、用量和防重复用的标记。锁屏时她不看。';

  @override
  String get companionNoticesFailed => '没改成，再试一次';

  @override
  String get companionNoticeLevelOff => '不看';

  @override
  String get companionNoticeLevelOffHint => '这个 App 的通知她不读';

  @override
  String get companionNoticeLevelGlance => '看一眼';

  @override
  String get companionNoticeLevelGlanceHint => '只用来决定要不要告诉你，看完就忘';

  @override
  String get companionNoticeLevelRemember => '会记住';

  @override
  String get companionNoticeLevelRememberHint => '值得记的近况，她会记下来';

  @override
  String get companionMemoryAll => '全部';

  @override
  String get companionMemoryFromNotices => '从通知看到的';

  @override
  String get companionMemoryNoticesClear => '全部清掉';

  @override
  String get companionMemoryNoticesClearTitle => '让她忘掉通知里看到的事？';

  @override
  String get companionMemoryNoticesClearBody => '她从通知里记下的近况都会删掉，同样的事以后也不再记。';

  @override
  String get companionPanelCompany => '陪伴';

  @override
  String get companionPanelHer => '她';

  @override
  String get companionPanelTalk => '对话';

  @override
  String get companionPanelMore => '更多';

  @override
  String get companionDrawerHere => '她一直在';

  @override
  String get companionDrawerRoom => '伙伴小屋';

  @override
  String get companionTabRoom => '小屋';

  @override
  String get companionTabMemory => '记忆';

  @override
  String get companionTabTasks => '交代';

  @override
  String get companionTabHer => '她';

  @override
  String companionDrawerReminderToday(String time) {
    return '$time 提醒你';
  }

  @override
  String companionDrawerReminderTomorrow(String time) {
    return '明天 $time';
  }

  @override
  String companionDrawerReminderLater(String date) {
    return '$date 提醒你';
  }

  @override
  String companionRawEraseAsk(String quote) {
    return '「$quote」这句原话也一起删掉吗？删了就找不回来了。';
  }

  @override
  String companionRawEraseAskMany(String quote, int count) {
    return '「$quote」等 $count 句原话也一起删掉吗？删了就找不回来了。';
  }

  @override
  String get companionRawEraseYes => '删掉';

  @override
  String get companionRawEraseNo => '留着';

  @override
  String get companionRawErased => '好，原话也删掉了。';

  @override
  String get companionRawKept => '好，原话留着。';

  @override
  String get companionRawEraseGone => '这次来不及了，原话还留着。';

  @override
  String get automaticDiagnosticsRecover => '恢复本地记录';

  @override
  String get automaticDiagnosticsRecoverHint => '仅在本机恢复分析记录，跳过已留存故障，不重新发送旧请求。';

  @override
  String get automaticDiagnosticsTitle => '自动故障分析';

  @override
  String get automaticDiagnosticsHint => '默认关闭 · 仅本机、前台且引擎可用时发送；同版本同类故障 24 小时内合并。关闭后停止新请求，已发送信息无法撤回。';

  @override
  String get automaticDiagnosticsConsentTitle => '开启自动故障分析？';

  @override
  String get automaticDiagnosticsConsent =>
      '发生故障时，App 会将脱敏的版本、设备与系统信息、运行时状态、错误类别、语音阶段及自身进程退出原因，发送给当前本机引擎配置的模型服务商，可能产生模型费用。不含聊天正文、录音、凭据或原始日志。报告保存在独立的只读分析对话，不自动切换当前对话，不自动执行修复或向 GitHub 外发。关闭或切换主机后不再发起新分析，并尝试停止已有分析；已发送的信息无法撤回。';

  @override
  String get automaticDiagnosticsEnable => '同意并开启';

  @override
  String get automaticDiagnosticsOff => '已关闭';

  @override
  String get automaticDiagnosticsWaiting => '等待本机连接、前台与引擎可用';

  @override
  String get automaticDiagnosticsReady => '已开启 · 等待新故障';

  @override
  String get automaticDiagnosticsCollecting => '正在采集结构化故障信息';

  @override
  String get automaticDiagnosticsAnalyzing => '正在独立对话分析（最多 2 分钟）';

  @override
  String get automaticDiagnosticsComplete => '分析完成';

  @override
  String get automaticDiagnosticsCancelled => '分析已停止或中断；不会自动重试';

  @override
  String get automaticDiagnosticsFailed => '分析失败；本次故障不会自动重试';

  @override
  String get automaticDiagnosticsStoreFailed => '无法保存诊断设置或状态；自动分析已停止';

  @override
  String get automaticDiagnosticsCancelFailed => '停止请求失败；请在报告对话中检查并手动停止';

  @override
  String get automaticDiagnosticsViewReport => '查看最新分析对话';

  @override
  String get automaticDiagnosticsReportHint => '仅点击时打开，不打断当前对话；报告可能仍在生成或已中断。';

  @override
  String get automaticDiagnosticsReportTitle => '自动故障分析报告';

  @override
  String get systemImeTitle => '系统输入法诊断';

  @override
  String get systemImeOhosTitle => '本应用键盘几何';

  @override
  String get systemImeOhosCollect => '导出最近的键盘几何';

  @override
  String get systemImeOhosPrivacy => '复现后再导出。只取本应用主窗口最近 120 秒的键盘弹出、高度和避让位置（最多 64 条），不含输入内容，也不读系统输入法日志。';

  @override
  String get systemImeOhosUnavailable => '主窗口暂时不可用，回到聊天页再试';

  @override
  String get systemImeCollect => '采集本次日志';

  @override
  String get systemImePrivacy => '复现后再采集。每次须在原生弹窗确认，仅读取最近 120 秒的固定事件（最多 64 条），不含输入内容或原始日志；不会自动申请权限。';

  @override
  String get systemImeEvidenceLimits => '请求显示/隐藏不等于键盘实际可见；空结果或采集失败不代表系统正常。';

  @override
  String get systemImeNotCollected => '尚未采集';

  @override
  String get systemImeCollecting => '等待本次确认或采集结果';

  @override
  String get systemImeRetained => '已保留本次证据';

  @override
  String get systemImeNoEvents => '未找到匹配事件';

  @override
  String get systemImeUnavailable => '没有已选且存活的特权通道';

  @override
  String get systemImeUnsupported => '当前版本或通道不支持采集';

  @override
  String get systemImeDenied => '本次采集未获同意';

  @override
  String get systemImeCancelled => '本次采集已取消';

  @override
  String get systemImeBusy => '通道忙，请稍后重试';

  @override
  String get systemImeTimeout => '采集超时，请重试';

  @override
  String get systemImeLimitExceeded => '超出采集上限，未保留事件';

  @override
  String get systemImeFailed => '采集失败或响应无效';

  @override
  String get systemImeEventCount => '保留事件数';

  @override
  String get systemImeCapturedAt => '采集时间';

  @override
  String get systemImePermissions => '手机操控权限设置（可选）';

  @override
  String get systemImePermissionsHint => '可自行配置特权通道，无需为诊断强制开启。原有手机授权不代表同意本次采集。';

  @override
  String get systemImeClear => '清除证据并取消采集';

  @override
  String get systemImeMemory => '证据仅存内存，重启清除；新采集会替换旧证据。仅手动“让 AI 看诊断”或导出 ZIP 时包含。清除不会撤回已写入的快照或导出文件。';

  @override
  String get engineNewChatDefaultsLast => '新对话默认（上次选择）';

  @override
  String get engineNewChatDefaultsFixed => '新对话默认（固定）';

  @override
  String get engineNewChatUseLast => '沿用上次';

  @override
  String get engineNewChatUseFixed => '固定默认';

  @override
  String get engineNewChatDefaultsHint => '保存在当前主机，只影响新对话的模型和思考深度。权限仍用独立默认，不继承临时会话授权。';

  @override
  String get engineNewChatDefaultsLegacy => '此引擎仅支持沿用上次选择；不支持固定默认，也无法确认切换时默认值是否保存成功。';

  @override
  String get engineNewChatDefaultsUnsupported => '此主机没有可编辑的默认模型设置';

  @override
  String get engineNewChatDefaultsSelectionUnavailable => '此模型或思考深度已不可用，请重新选择。';

  @override
  String get engineNewChatDefaultsInheritedEffort => '主机基础配置指定了思考深度，不能在这里为无思考模型清除。请先调整主机配置。';

  @override
  String get engineNewChatDefaultsSaving => '正在保存并确认默认值…';

  @override
  String get engineNewChatDefaultsUnconfirmed => '没能确认完整默认值，请刷新后检查模型和思考深度。主机基础配置或其他客户端可能已改变它们。';

  @override
  String get engineModelDefaultSaveFailed => '当前对话的模型已切换，但新对话默认未保存。请到设置 › 模型检查并重试。';

  @override
  String get engineAccountSignedIn => '已登录 DeepSeek 账号';

  @override
  String get engineAccountSignOutTitle => '退出 DeepSeek 账号？';

  @override
  String get engineAccountSignOutBusy => '有任务正在使用账号模型，退出会立即中断它们。对话和文件都会保留。';

  @override
  String get engineAccountSignOutBody => '账号模型将不可用。对话、文件和 API Key 都会保留，随时可以重新登录。';

  @override
  String get engineAccountSignOutUnknown => '无法确认是否有任务在使用账号模型；如果有，退出会中断它们。';

  @override
  String get engineAccountSignOutFailed => '没能退出，稍后再试';

  @override
  String get engineAccountTitle => '账号';

  @override
  String get engineAccountRefresh => '刷新';

  @override
  String get engineAccountDeepSeek => 'DeepSeek 账号';

  @override
  String get engineAccountProfileUnavailable => '资料暂时读不到';

  @override
  String get engineAccountBalance => '余额';

  @override
  String get engineAccountBalanceHint => '账号模型的费用从余额中扣除';

  @override
  String get engineAccountBalanceEngineOff => '引擎未运行，启动后显示余额';

  @override
  String get engineAccountTopUp => '去充值';

  @override
  String get engineAccountUsageDetails => '用量明细';

  @override
  String get engineAccountToppedUpBalance => '充值余额';

  @override
  String get engineAccountGrantedBalance => '赠送余额';

  @override
  String get engineAccountBalanceUnavailable => '余额暂时读不到';

  @override
  String get engineAccountNoKeyNeeded => '登录后无需 API Key';

  @override
  String get engineAccountUnsupported => '当前引擎不支持账号登录';

  @override
  String get engineAccountSignInDeepSeek => '用 DeepSeek 账号登录';

  @override
  String get engineAccountAutoStart => '引擎未运行，登录时会自动启动';

  @override
  String get engineAccountReplaceKey => '更换 Key';

  @override
  String get engineAccountClearKeyTitle => '清除 API Key？';

  @override
  String get engineAccountClearKeyBody => '删除 App 里保存的 Key。本机引擎运行时，引擎里的 Key 也会一并删除。';

  @override
  String get engineAccountBrowserFailed => '没能打开浏览器';

  @override
  String get engineAccountSignInSuccess => '登录成功';

  @override
  String get engineAccountAlmostReady => '马上就好';

  @override
  String get engineAccountStartingEngine => '正在启动引擎';

  @override
  String get engineAccountOpenSignInNext => '随后打开登录页';

  @override
  String get engineAccountPreparingSignIn => '正在准备登录';

  @override
  String get engineAccountOpenDeepSeekNext => '马上打开 DeepSeek 登录页';

  @override
  String get engineAccountFinishInBrowser => '在浏览器中完成登录';

  @override
  String get engineAccountReturnToDsh => '登录完成后回到 DSH Go';

  @override
  String get engineAccountFinishingSignIn => '正在完成登录';

  @override
  String get engineAccountSavingSignIn => '正在保存登录信息';

  @override
  String get engineAccountAwaitingResult => '还没收到登录结果';

  @override
  String get engineAccountCopySignInLink => '复制登录链接';

  @override
  String get engineAccountReopenSignIn => '重新打开登录页';

  @override
  String get engineAccountCancelSignIn => '取消登录';

  @override
  String get engineAccountSignInLinkCopied => '登录链接已复制';

  @override
  String get engineAccountSigningIn => '登录中';

  @override
  String get engineAccountSignedOut => '未登录';

  @override
  String get engineAccountUsageFact => '用量从账号余额中扣除';

  @override
  String get engineAccountBrowserFact => '在浏览器中登录，密码不经过 DSH';

  @override
  String get engineAccountCredentialsFact => '登录凭据只保存在本机';

  @override
  String get engineSubagentTitle => '子代理';

  @override
  String get engineAgentLoopTitle => 'Agent 循环';

  @override
  String get engineShellTitle => '命令执行';

  @override
  String get engineSearchTitle => '联网搜索';

  @override
  String get engineSearchNewApiBadge => '新版 API';

  @override
  String get engineGeneralTitle => '通用设置';

  @override
  String get engineSettingsTitle => '引擎参数';

  @override
  String get engineSettingsReadFailed => '没能读取设置';

  @override
  String get engineSettingsRun => '运行';

  @override
  String get engineSettingsPlugins => '插件';

  @override
  String get engineSettingsPluginInventory => '插件清单';

  @override
  String get engineSettingsPluginStopped => '插件没有在运行';

  @override
  String get engineSettingsEnablePlugin => '启用后再来设置';

  @override
  String get engineSettingsNoEditableFields => '没有可以在这里改的设置';

  @override
  String get engineFieldRestoreDefault => '恢复默认';

  @override
  String get engineFieldDecrease => '减少';

  @override
  String get engineFieldIncrease => '增加';

  @override
  String get engineFieldRemove => '移除';

  @override
  String get engineFieldShow => '显示';

  @override
  String get engineFieldFromEnvironment => '由启动环境提供';

  @override
  String get engineFieldItem => '项';

  @override
  String get engineFieldAlreadyAdded => '已经添加过';

  @override
  String get engineFieldEnterName => '填写名称';

  @override
  String get engineFieldEnterNumber => '填写数值';

  @override
  String get engineFieldValue => '值';

  @override
  String get engineFieldNew => '新建';

  @override
  String get engineFieldRequired => '必填';

  @override
  String get engineGeneralMissing => '这台主机没有通用设置';

  @override
  String get engineSettingsVersionRequired => '需要 DSH 0.2.1 或更新版本';

  @override
  String get engineGeneralWebDisplay => '网页版显示';

  @override
  String get engineGeneralWebSending => '网页版发送';

  @override
  String get engineGeneralWebOnlyHint => '这组设置仅影响当前主机的网页版，不改变原生聊天。';

  @override
  String get engineGeneralData => '数据';

  @override
  String get engineSubagentModelsTitle => '子代理模型';

  @override
  String get engineChatLogTitle => '对话日志';

  @override
  String get engineThinkingTranslationTitle => '思考过程翻译';

  @override
  String get enginePluginIndexesTitle => '插件市场索引';

  @override
  String get enginePermissionTitle => '权限';

  @override
  String get engineAgentPresetsTitle => 'Agent 预设';

  @override
  String get engineDefaultModelTitle => '默认模型';

  @override
  String get engineWebAppearanceTitle => '网页版外观';

  @override
  String get engineLanguageTitle => '语言';

  @override
  String get engineFieldCommandTimeout => '命令超时';

  @override
  String get engineFieldMaxOutput => '输出上限';

  @override
  String get engineFieldMaxTimeout => '最长可申请超时';

  @override
  String get engineFieldMaxSpill => '转存文件上限';

  @override
  String get engineFieldGracePeriod => '终止宽限时间';

  @override
  String get engineFieldDefaultCwd => '默认工作目录';

  @override
  String get engineFieldFollowChat => '跟随对话';

  @override
  String get engineSubagentMaxDepth => '最大递归深度';

  @override
  String get engineFieldLayersUnit => '层';

  @override
  String get engineSubagentMaxActive => '同时运行上限';

  @override
  String get engineFieldCountUnit => '个';

  @override
  String get engineSubagentAllowModelChoice => '允许 AI 给子代理选模型';

  @override
  String get engineSubagentAllowedModels => '可选模型';

  @override
  String get engineAgentMaxParallelCalls => '每步并行工具调用上限';

  @override
  String get engineFieldSearchProvider => '搜索服务';

  @override
  String get engineFieldFetchProvider => '网页抓取服务';

  @override
  String get engineFieldBaseUrl => '服务地址';

  @override
  String get engineSearchMaxUses => '每次请求最多搜索';

  @override
  String get engineFieldTimesUnit => '次';

  @override
  String get engineSearchHelperModel => '辅助模型';

  @override
  String get engineFieldApiVersion => 'API 版本';

  @override
  String get engineFieldMaxTokens => '最大输出长度';

  @override
  String get engineSearchResultsPerSearch => '每次搜索结果数';

  @override
  String get engineFieldResultsUnit => '条';

  @override
  String get engineSearchSendOriginalQuestion => '搜索时附带用户原问题';

  @override
  String get engineChatLogUpload => '向 DeepSeek 上传对话日志';

  @override
  String get engineTranslationProvider => '翻译服务';

  @override
  String get engineTranslationAccountPaid => 'DeepSeek 账号（付费）';

  @override
  String get engineTranslationApiPaid => 'DeepSeek API（付费）';

  @override
  String get engineTranslationTargetLanguage => '目标语言';

  @override
  String get engineTranslationFollowLanguage => '跟随界面语言';

  @override
  String get engineTranslationLanguageHint => '填 auto 或语言代码，如 zh、en、ja';

  @override
  String get enginePluginIndexSources => '索引源';

  @override
  String get enginePluginIndexUrl => '索引地址';

  @override
  String get engineFieldHttpUrlHint => '以 http:// 或 https:// 开头的地址';

  @override
  String get enginePermissionNewChat => '新对话默认权限';

  @override
  String get engineAgentDefaultPreset => '默认 Agent 预设';

  @override
  String get engineProviderTitle => '渠道';

  @override
  String get engineModelTitle => '模型';

  @override
  String get engineFieldReasoningEffort => '思考深度';

  @override
  String get engineGeneralShowCodingView => '显示代码工作视图';

  @override
  String get engineGeneralWorkDetails => '工作步骤展示';

  @override
  String get engineFieldCompact => '简洁';

  @override
  String get engineFieldStandard => '标准';

  @override
  String get engineFieldDetailed => '详细';

  @override
  String get engineFieldVerbose => '完全展开';

  @override
  String get engineGeneralCollapseTiming => '工作步骤收起时机';

  @override
  String get engineGeneralOnCompletion => '回答结束后';

  @override
  String get engineGeneralOnNewMessage => '有新消息时';

  @override
  String get engineGeneralPerformanceUsage => '性能与用量';

  @override
  String get engineGeneralLinkOpening => '链接打开方式';

  @override
  String get engineGeneralAppSidebar => '应用内侧栏';

  @override
  String get engineGeneralDefaultBrowser => '默认浏览器';

  @override
  String get engineGeneralBusySend => 'AI 工作时发送';

  @override
  String get engineGeneralQueueSend => '排队发送';

  @override
  String get engineGeneralSteerSend => '插话发送';

  @override
  String get engineFieldTheme => '主题';

  @override
  String get engineFieldFontSize => '字号';

  @override
  String get engineFieldCodeFontSize => '代码字号';

  @override
  String get engineFieldTerminalFontSize => '终端字号';

  @override
  String get engineFieldTextFont => '正文字体';

  @override
  String get engineFieldCodeFont => '代码字体';

  @override
  String get engineFieldTerminalFont => '终端字体';

  @override
  String get engineFieldInterfaceLanguage => '界面语言';

  @override
  String get engineFieldSecondsUnit => '秒';

  @override
  String get engineFieldBytesUnit => '字节';

  @override
  String get engineFieldGreaterThanZero => '大于 0';

  @override
  String get engineFieldEnterNumeric => '请填数字';

  @override
  String get engineFieldEnterInteger => '请填整数';

  @override
  String get engineFieldInvalidFormat => '格式不对';

  @override
  String get engineFieldAddress => '地址';

  @override
  String get engineFieldToken => '令牌';

  @override
  String get engineFieldService => '服务';

  @override
  String get engineFieldTimeout => '超时';

  @override
  String get engineFieldQuantity => '数量';

  @override
  String get engineFieldMaxUses => '最多次数';

  @override
  String get engineFieldMaxRetries => '最多重试次数';

  @override
  String get engineFieldConcurrency => '并发数';

  @override
  String get engineFieldInterval => '间隔';

  @override
  String get engineFieldPrompt => '提示词';

  @override
  String get engineFieldSystemPrompt => '系统提示词';

  @override
  String get engineFieldTemperature => '温度';

  @override
  String get engineFieldDebugMode => '调试模式';

  @override
  String get engineFieldVerboseLogs => '详细日志';

  @override
  String get engineFieldPath => '路径';

  @override
  String get engineFieldCwd => '工作目录';

  @override
  String get engineFieldCommand => '命令';

  @override
  String get engineFieldArguments => '参数';

  @override
  String get engineFieldEnvironment => '环境变量';

  @override
  String get engineFieldHeaders => '请求头';

  @override
  String get engineFieldProxy => '代理';

  @override
  String get engineFieldAuto => '自动';

  @override
  String get engineFieldEnabled => '开启';

  @override
  String get engineFieldOn => '开';

  @override
  String get engineFieldOff => '关';

  @override
  String get engineFieldLow => '低';

  @override
  String get engineFieldMedium => '中';

  @override
  String get engineFieldHigh => '高';

  @override
  String get engineFieldMax => '最高';

  @override
  String get engineFieldNone => '无';

  @override
  String get engineFieldModified => '已修改';

  @override
  String get engineFieldLocked => '由配置文件固定';

  @override
  String get engineFieldSharedWithModel => '与模型共用';

  @override
  String get engineFieldNotConfigured => '未配置';

  @override
  String get engineFieldConfigured => '已配置';

  @override
  String get engineSettingsMissing => '这台主机没有这项设置';

  @override
  String get engineSettingsPluginDisabled => '相关插件未启用';

  @override
  String get engineSettingsReadOnly => '引擎设置是只读的，这里只能查看';

  @override
  String get engineSubagentSavedUnavailable => '已保存但当前不可用';

  @override
  String get engineSubagentKeepOneModel => '至少保留一个模型';

  @override
  String get engineSubagentLimits => '运行限制';

  @override
  String get engineSubagentModelSelection => '模型选择';

  @override
  String get engineSubagentPickFirstModel => '选一个模型后生效';

  @override
  String get engineSubagentReadModelsFailed => '没能读取模型';

  @override
  String get engineSubagentNoModels => '还没有可选的模型';

  @override
  String get engineSubagentConnectModel => '接入模型';

  @override
  String get engineSearchDeepSeek => 'DeepSeek 搜索';

  @override
  String get engineSearchNewApi => '新版搜索 API';

  @override
  String get engineProviderDeleteBody => '渠道和它的 API Key 会一起删除，用它的对话需要换个模型。';

  @override
  String get engineProviderReadFailed => '没能读取渠道';

  @override
  String get engineProviderGone => '这个渠道已不在';

  @override
  String get engineProviderProtocol => '协议';

  @override
  String get engineProviderEnterKey => '填写 API Key';

  @override
  String get engineProviderIssues => '问题';

  @override
  String get engineProviderRejectedConfig => '引擎拒绝了部分配置';

  @override
  String get engineProviderConnection => '连接';

  @override
  String get engineProviderHeaders => '请求头（可选）';

  @override
  String get engineProviderHeadersWarning => '请求头以明文保存，不参与日志脱敏。敏感凭据请使用 API Key 或凭据引用。';

  @override
  String get engineProviderHeaderName => '名称';

  @override
  String get engineProviderHeaderValue => '值';

  @override
  String get engineProviderHeaderAdd => '添加请求头';

  @override
  String get engineProviderHeaderInvalidName => '请求头名称只能包含英文字母、数字或 HTTP 标记符号，不能包含空格或冒号';

  @override
  String get engineProviderHeaderReserved => 'User-Agent 由引擎设置，请移除此请求头';

  @override
  String get engineProviderHeaderLocked => '由引擎管理，保留现有配置';

  @override
  String get engineProviderHeaderDuplicate => '请求头名称重复（不区分大小写）';

  @override
  String get engineProviderHeaderInvalidValue => '请求头值只能包含单行 Latin-1 文本，不支持换行或控制字符（制表符除外）';

  @override
  String get engineProviderDefaultUrl => '默认地址';

  @override
  String get engineProviderKeyNotRequired => '不需要';

  @override
  String get engineProviderNoModels => '还没有模型';

  @override
  String get engineProviderWebConfigured => '这个渠道在网页版里配置，这里只能查看和删除';

  @override
  String get engineProviderDelete => '删除渠道';

  @override
  String get engineProviderConfigFile => '由引擎配置文件提供，无法在这里删除';

  @override
  String get engineProviderTesting => '正在测试';

  @override
  String get engineProviderTestConnection => '测试连接';

  @override
  String get engineProviderKeyFirst => '先填写 API Key';

  @override
  String get engineProviderNoDiscoveredModels => '服务没有列出模型，请手动添加';

  @override
  String get engineProviderNeedModel => '至少添加一个模型';

  @override
  String get engineProviderEdit => '编辑渠道';

  @override
  String get engineProviderAdd => '添加渠道';

  @override
  String get engineProviderBasicInfo => '基本信息';

  @override
  String get engineProviderNameHint => '比如：我的网关';

  @override
  String get engineProviderCompatibleProtocol => '兼容协议';

  @override
  String get engineProviderKeepStoredKey => '已保存，留空则不修改';

  @override
  String get engineProviderSaving => '正在保存';

  @override
  String get engineProviderWaitingEngine => '等待引擎连接';

  @override
  String get engineProviderFetchingModels => '正在获取模型';

  @override
  String get engineProviderFetchModels => '获取模型';

  @override
  String get engineProviderAddManually => '手动添加';

  @override
  String get engineProviderManualModel => '手动添加模型';

  @override
  String get engineProviderModelId => '模型 ID';

  @override
  String get engineProviderSelectModels => '选择模型';

  @override
  String get engineProviderSearchModels => '搜索模型';

  @override
  String get engineProviderDeselectAll => '全不选';

  @override
  String get engineProviderSelectAll => '全选';

  @override
  String get engineProviderNoMatchingModels => '没有匹配的模型';

  @override
  String get engineProviderAlreadyAdded => '已添加';

  @override
  String get engineProviderReady => '可用';

  @override
  String get engineProviderMissingKey => '缺少 API Key';

  @override
  String get engineProviderMisconfigured => '配置有误';

  @override
  String get engineProviderInactive => '未启用';

  @override
  String get engineProviderConfiguredInWeb => '网页版配置';

  @override
  String get engineProvidersTitle => '模型';

  @override
  String get engineProvidersNotConnected => '没有连上引擎';

  @override
  String get engineProvidersStartEngine => '引擎运行后可添加渠道';

  @override
  String get engineProvidersUnsupported => '这台主机不支持自定义渠道';

  @override
  String get engineProvidersNotConfiguredHere => '未在这台主机上配置';

  @override
  String get engineProvidersSigningIn => '正在登录…';

  @override
  String get engineProvidersSignInOrKey => '登录账号或填写 API Key';

  @override
  String get engineProvidersOfficial => '官方';

  @override
  String get engineProvidersChatGptOfficial => 'ChatGPT 官方订阅';

  @override
  String get engineSubscriptionReconnectAccount => '登录原账号';

  @override
  String get engineSubscriptionUseAnotherAccount => '使用其他账号';

  @override
  String get engineSubscriptionPlanNotEnabled => '此授权无法使用 ChatGPT 订阅模型。';

  @override
  String get engineSubscriptionRevocationUnconfirmed => '已在本机退出，但没能确认 OpenAI 已撤销授权。';

  @override
  String get engineProvidersSubscription => '订阅';

  @override
  String get engineProvidersCustom => '自定义';

  @override
  String get engineProvidersCompatibleHint => 'OpenAI、Anthropic 兼容的服务';

  @override
  String get engineProvidersReadOnly => '引擎设置是只读的，无法添加';

  @override
  String get engineSubscriptionSignOutBody => '它的模型会从模型选择里移除。';

  @override
  String get engineSubscriptionNoModels => '暂无模型';

  @override
  String get engineSubscriptionModelsFailed => '没能读取模型';

  @override
  String get engineSubscriptionPreparing => '正在准备…';

  @override
  String get engineSubscriptionCancelled => '登录已取消';

  @override
  String get engineSubscriptionIncomplete => '登录没有完成';

  @override
  String get engineSubscriptionWaitingSignIn => '等待登录…';

  @override
  String get engineSubscriptionReopen => '重新打开';

  @override
  String get engineSubscriptionCode => '验证码';

  @override
  String get engineSubscriptionWaitingVerification => '等待验证…';

  @override
  String get engineSubscriptionCopyCode => '复制验证码';

  @override
  String get engineSubscriptionOpenVerification => '打开验证页';

  @override
  String get engineSubscriptionPasteRedirect => '粘贴跳转后的链接';

  @override
  String get engineSubscriptionPasteCode => '粘贴授权码';

  @override
  String get engineSubscriptionPasteHere => '粘贴到这里';

  @override
  String get engineSubscriptionConfirm => '确定';

  @override
  String get engineSubscriptionTryAgain => '再试一次';

  @override
  String engineAccountWelcome(String name) {
    return '欢迎，$name';
  }

  @override
  String engineLayerCount(int count) {
    return '$count 层';
  }

  @override
  String engineFieldDefaultValue(String value) {
    return '默认 $value';
  }

  @override
  String engineFieldDefaultValueUnit(String value, String unit) {
    return '默认 $value $unit';
  }

  @override
  String engineFieldCurrentValue(String value) {
    return '当前 $value';
  }

  @override
  String engineFieldRemoveItem(String name) {
    return '移除 $name';
  }

  @override
  String engineFieldAddItem(String item) {
    return '添加$item';
  }

  @override
  String engineFieldItemIndex(int index) {
    return '第 $index 项';
  }

  @override
  String engineFieldByteCount(int count) {
    return '$count 字节';
  }

  @override
  String engineFieldHours(String value) {
    return '$value 小时';
  }

  @override
  String engineFieldMinutes(String value) {
    return '$value 分钟';
  }

  @override
  String engineFieldSeconds(String value) {
    return '$value 秒';
  }

  @override
  String engineFieldMilliseconds(String value) {
    return '$value 毫秒';
  }

  @override
  String engineFieldPositiveMax(String max) {
    return '大于 0，不超过 $max';
  }

  @override
  String engineFieldMin(String min) {
    return '不小于 $min';
  }

  @override
  String engineFieldMaxBound(String max) {
    return '不超过 $max';
  }

  @override
  String engineFieldBelowMin(String min) {
    return '不能小于 $min';
  }

  @override
  String engineFieldAboveMax(String max) {
    return '不能大于 $max';
  }

  @override
  String engineFieldMultiple(String step) {
    return '需是 $step 的倍数';
  }

  @override
  String engineFieldMinCharacters(int count) {
    return '至少 $count 个字符';
  }

  @override
  String engineFieldMaxCharacters(int count) {
    return '最多 $count 个字符';
  }

  @override
  String engineSubagentUnavailableProvider(String provider) {
    return '$provider · 当前不可用';
  }

  @override
  String engineProviderDeleteTitle(String name) {
    return '删除「$name」？';
  }

  @override
  String engineProviderDeleteFailed(String error) {
    return '没能删除：$error';
  }

  @override
  String engineProviderModelCount(int count) {
    return '模型 · $count';
  }

  @override
  String engineProviderContext(String size) {
    return '上下文 $size';
  }

  @override
  String engineProviderTestPassed(int count) {
    return '连接正常 · 列出 $count 个模型';
  }

  @override
  String engineProviderCompletedUrl(String url) {
    return '已补全为 $url';
  }

  @override
  String engineProviderSaveFailed(String error) {
    return '没能保存：$error';
  }

  @override
  String engineProviderCandidateCount(int count) {
    return '共 $count 个';
  }

  @override
  String engineProviderAddModels(int count) {
    return '添加 $count 个模型';
  }

  @override
  String engineProviderModels(int count) {
    return '$count 个模型';
  }

  @override
  String engineProvidersSummary(int total, int ready) {
    return '$total 个渠道 · $ready 个可用';
  }

  @override
  String engineProvidersAccount(String name) {
    return '账号 · $name';
  }

  @override
  String engineProvidersSignedInAccount(String account) {
    return '已登录 · $account';
  }

  @override
  String engineSubscriptionSignIn(String provider) {
    return '登录 $provider';
  }

  @override
  String engineSubscriptionSignOutTitle(String provider) {
    return '退出 $provider？';
  }

  @override
  String engineSubscriptionSignOutFailed(String error) {
    return '没能退出：$error';
  }

  @override
  String engineSubscriptionCodeSemantics(String code) {
    return '验证码 $code';
  }

  @override
  String engineFieldItemCount(int count) {
    return '$count 个';
  }

  @override
  String engineFieldUseCount(int count) {
    return '$count 次';
  }

  @override
  String engineFieldResultCount(int count) {
    return '$count 条';
  }

  @override
  String engineFieldMinCharactersDecimal(String bound) {
    return '至少 $bound 个字符';
  }

  @override
  String engineFieldMaxCharactersDecimal(String bound) {
    return '最多 $bound 个字符';
  }

  @override
  String engineLayerValue(String value) {
    return '$value 层';
  }

  @override
  String engineFieldEnterPositiveRange(String max) {
    return '请填 大于 0，不超过 $max 之间的数';
  }

  @override
  String engineFieldEnterBoundedRange(String min, String max) {
    return '请填 $min–$max 之间的数';
  }

  @override
  String get engineModelTokenLimits => 'Token 上限';

  @override
  String get engineModelContextLength => '上下文长度';

  @override
  String get engineModelContextOverrideHint => '留空使用渠道目录里的值；改大后引擎按新值计算上下文占用与压缩。';

  @override
  String get engineModelMaxOutput => '最大输出';

  @override
  String engineModelDefaultSize(String size) {
    return '默认 $size';
  }

  @override
  String get engineModelCapabilities => '能力';

  @override
  String get engineModelInputType => '输入类型';

  @override
  String get engineModelInputText => '文本';

  @override
  String get engineModelInputTextImage => '文本和图片';

  @override
  String get engineModelThinking => '思考';

  @override
  String get engineModelVision => '识图';

  @override
  String get engineModelLevels => '可选档位';

  @override
  String get engineModelNeedLevel => '至少选一个档位';

  @override
  String get engineFieldEditOnWeb => '在网页版编辑此项';

  @override
  String get engineSettingsHostChanged => '主机已切换，请重新打开设置后编辑。';

  @override
  String get engineSecretTargetChanged => '此项已变化，请重新打开后编辑。';

  @override
  String engineSettingsGroupCount(int count) {
    return '$count 项';
  }

  @override
  String get featuresCordisSubtitle => '动态插件 · 引擎重启后清空';

  @override
  String get featuresCordisUnavailable => '这个连接看不到 Cordis';

  @override
  String get featuresCordisRemoteUnavailable => '经 DSH Remote 中转时不可用';

  @override
  String get featuresCordisReadFailed => '没能读取插件';

  @override
  String get featuresCordisEmpty => '还没有动态插件';

  @override
  String get featuresCordisEmptyHint => '插件创建后会出现在这里';

  @override
  String get featuresCurrentChat => '当前对话';

  @override
  String get featuresOtherChats => '其他对话';

  @override
  String featuresPresetDefaultSet(String name) {
    return '新对话将使用「$name」';
  }

  @override
  String get featuresPresetDefaultFailed => '没能设为默认';

  @override
  String featuresPresetDeleteTitle(String name) {
    return '删除「$name」？';
  }

  @override
  String get featuresPresetDeleteHint => '新对话不能再选它，已开始的对话不受影响。';

  @override
  String get featuresDeleted => '已删除';

  @override
  String get featuresDeleteFailed => '没能删除';

  @override
  String get featuresPresetAlreadyDefault => '已是新对话默认';

  @override
  String get featuresPresetSetDefault => '设为新对话默认';

  @override
  String get featuresPresetViewConfig => '查看配置';

  @override
  String get featuresPresetDuplicate => '复制为新预设';

  @override
  String get featuresPresetDefaultDeleteHint => '先把别的预设设为新对话默认';

  @override
  String get featuresAgentPresets => 'Agent 预设';

  @override
  String get featuresAgentPresetsSubtitle => '新对话的工具与工作方式';

  @override
  String get featuresNew => '新建';

  @override
  String get featuresPresetsReadFailed => '没能读取 Agent 预设';

  @override
  String get featuresLoadFailed => '加载失败';

  @override
  String get featuresNewChatDefault => '新对话默认';

  @override
  String get featuresEmptyDocument => '（空）';

  @override
  String get featuresReadFailed => '没能读取';

  @override
  String featuresTodayTime(String time) {
    return '今天 $time';
  }

  @override
  String featuresTomorrowTime(String time) {
    return '明天 $time';
  }

  @override
  String featuresYesterdayTime(String time) {
    return '昨天 $time';
  }

  @override
  String featuresScheduleSummaryNext(String rule, String time) {
    return '$rule · 下次 $time';
  }

  @override
  String get featuresEnded => '已结束';

  @override
  String featuresScheduleSummaryEnded(String time) {
    return '已结束 · $time 运行过';
  }

  @override
  String featuresJobElapsed(String span) {
    return '已运行 $span';
  }

  @override
  String featuresJobDuration(String span) {
    return '用时 $span';
  }

  @override
  String get featuresPermissionReadOnly => '仅可查看';

  @override
  String get featuresPermissionWorkspaceWrite => '工作区内修改';

  @override
  String get featuresPermissionFullAccess => '完全权限';

  @override
  String get featuresPermissionAutoReview => '自动审查';

  @override
  String get featuresPermissionCustom => '自定义';

  @override
  String get featuresPermissionReadOnlyHint => '只看文件，不做修改';

  @override
  String get featuresPermissionWorkspaceWriteHint => '可改工作区内的文件，越界先问你';

  @override
  String get featuresPermissionFullAccessHint => '不再确认，直接执行';

  @override
  String get featuresPermissionAutoReviewHint => '由模型逐次审查，拿不准再问你';

  @override
  String get featuresPresetStandard => '标准模式';

  @override
  String get featuresPresetPtc => 'PTC 模式';

  @override
  String get featuresPresetMinimal => '极简模式';

  @override
  String get featuresPresetCreator => '创造模式';

  @override
  String get featuresPresetStandardDescription => '代码、文件和资料，适合大多数任务';

  @override
  String get featuresPresetPtcDescription => '批量调用工具，再筛选、统计、汇总';

  @override
  String get featuresPresetMinimalDescription => '只用终端和读图，适合测试对比';

  @override
  String get featuresPresetCreatorDescription => '让 Agent 写插件，定制 DSH 本身';

  @override
  String featuresHostUnreachable(String name) {
    return '连不上「$name」';
  }

  @override
  String featuresHostConnecting(String name) {
    return '正在连接「$name」…';
  }

  @override
  String get featuresJobs => '后台任务';

  @override
  String get featuresJobsSubtitle => '引擎重启后清空';

  @override
  String get featuresJobsReadFailed => '没能读取后台任务';

  @override
  String get featuresJobsEmpty => '没有后台任务';

  @override
  String get featuresJobsEmptyHint => '开发服务器这类命令会在这里';

  @override
  String featuresJobsEndedCount(int count) {
    return '已结束 · $count';
  }

  @override
  String get featuresJobStopTitle => '停止这个任务？';

  @override
  String get featuresJobAlreadyEnded => '任务已经结束了';

  @override
  String get featuresJobStopFailed => '没能停止';

  @override
  String get featuresJobOutput => '任务输出';

  @override
  String get featuresOutput => '输出';

  @override
  String featuresJobRecentLines(int count) {
    return '最近 $count 行';
  }

  @override
  String get featuresJobOutputSubject => 'DSH 任务输出';

  @override
  String get featuresJobOutputReadFailed => '没能读取输出';

  @override
  String get featuresJobOutputWaiting => '等待输出…';

  @override
  String get featuresJobOutputEmpty => '没有输出';

  @override
  String get featuresPermissionAutoTitle => '开启自动审查？';

  @override
  String get featuresPermissionAutoWarning => '每次操作由模型判断放不放行，可能误判。';

  @override
  String get featuresSwitchFailed => '没能切换';

  @override
  String get featuresPermissions => '权限';

  @override
  String get featuresPermissionsSubtitle => '执行命令、修改文件前，要不要先问你';

  @override
  String get featuresPermissionsReadFailed => '没能读取权限设置';

  @override
  String get featuresPermissionCustomHint => '当前用的是自定义权限，选预设会替换它';

  @override
  String get featuresModuleInstructions => '工作区指令加载';

  @override
  String get featuresModuleTime => '时间感知';

  @override
  String get featuresModuleBash => 'Bash 命令工具';

  @override
  String get featuresModulePersistentBash => '持久 Bash 工具';

  @override
  String get featuresModulePowerShell => 'PowerShell 命令工具';

  @override
  String get featuresModuleFiles => '文件读写工具';

  @override
  String get featuresModuleFileSearch => '文件搜索工具';

  @override
  String get featuresModuleJobs => '后台任务工具';

  @override
  String get featuresModuleSchedule => '自动化任务工具';

  @override
  String get featuresModuleLocalSkills => '本地技能加载';

  @override
  String get featuresModuleSkillTool => '技能加载工具';

  @override
  String get featuresModuleGoalCommand => '目标管理命令';

  @override
  String get featuresModuleGoalTool => '目标管理工具';

  @override
  String get featuresModulePlan => '计划模式';

  @override
  String get featuresModuleCompaction => '上下文压缩';

  @override
  String get featuresModuleCompactCommand => '上下文压缩命令';

  @override
  String get featuresModuleAskUser => '向用户提问工具';

  @override
  String get featuresModuleTodo => '待办清单工具';

  @override
  String get featuresModuleWeb => '网页搜索与读取工具';

  @override
  String get featuresModulePresent => '文件交付工具';

  @override
  String get featuresModuleCordis => '插件 API 查询工具';

  @override
  String get featuresModuleSubagent => '子代理委派工具';

  @override
  String get featuresModuleSubagentControl => '子代理控制工具';

  @override
  String get featuresModuleWorkflow => '工作流工具';

  @override
  String get featuresModulePluginManager => '插件管理工具';

  @override
  String get featuresModulePluginMarket => '插件市场工具';

  @override
  String get featuresModuleToolCalls => '工具调用方式';

  @override
  String get featuresModuleTerminal => '持久终端服务';

  @override
  String get featuresModulePersona => '智能体角色设定';

  @override
  String get featuresGroupDelegation => '子代理委派';

  @override
  String get featuresGroupTerminal => '持久终端';

  @override
  String get featuresPresetIdRequired => '填写标识';

  @override
  String get featuresPresetIdLength => '最多 40 个字符';

  @override
  String get featuresPresetIdFormat => '只用小写字母、数字和连字符';

  @override
  String get featuresPresetIdTaken => '这个标识已被使用';

  @override
  String featuresPresetCopyName(String name) {
    return '$name 副本';
  }

  @override
  String get featuresPresetBasedOn => '基于';

  @override
  String get featuresNameRequired => '填写名称';

  @override
  String get featuresCreatorOpenFailed => '没能打开创造模式';

  @override
  String get featuresPresetNameHint => '比如：代码审查';

  @override
  String get featuresPresetId => '标识';

  @override
  String get featuresPresetIdHint => '小写字母、数字和连字符';

  @override
  String get featuresPresetDescription => '说明';

  @override
  String get featuresPresetDescriptionHint => '一句话说明它适合做什么';

  @override
  String get featuresPresetConfigReadFailed => '没能读取预设配置';

  @override
  String get featuresPresetCreateTitle => '新建 Agent 预设';

  @override
  String get featuresPresetDuplicateTitle => '复制 Agent 预设';

  @override
  String get featuresPresetEditTitle => '编辑 Agent 预设';

  @override
  String get featuresCreatorOpening => '正在打开创造模式';

  @override
  String get featuresWaitingEngine => '等待引擎连接';

  @override
  String get featuresCreatorUnavailable => '创造模式不可用';

  @override
  String get featuresPresetStartUpdate => '开始更新';

  @override
  String get featuresPresetStartCreate => '开始创建';

  @override
  String get featuresPresetSystemPrompt => '系统提示';

  @override
  String get featuresPresetSystemPromptHint => '你是谁、怎么工作';

  @override
  String get featuresPresetReplaceSystemPrompt => '完整替换系统提示';

  @override
  String get featuresPresetTools => '工具';

  @override
  String get featuresSkills => '技能';

  @override
  String get featuresPresetContextModes => '上下文与模式';

  @override
  String get featuresCronMinute => '分钟';

  @override
  String get featuresCronHour => '小时';

  @override
  String get featuresDate => '日期';

  @override
  String get featuresCronMonth => '月份';

  @override
  String get featuresCronWeekday => '星期';

  @override
  String get featuresCronRequired => '填写 5 段 Cron 表达式';

  @override
  String get featuresCronWhitespace => '首尾不能有空格';

  @override
  String featuresCronFieldCount(int count) {
    return '需要 5 段，现在是 $count 段';
  }

  @override
  String featuresCronInvalidField(int index, String name) {
    return '第 $index 段（$name）写法不对';
  }

  @override
  String get featuresWeekdayMon => '一';

  @override
  String get featuresWeekdayTue => '二';

  @override
  String get featuresWeekdayWed => '三';

  @override
  String get featuresWeekdayThu => '四';

  @override
  String get featuresWeekdayFri => '五';

  @override
  String get featuresWeekdaySat => '六';

  @override
  String get featuresWeekdaySun => '日';

  @override
  String get featuresMonthJan => '一月';

  @override
  String get featuresMonthFeb => '二月';

  @override
  String get featuresMonthMar => '三月';

  @override
  String get featuresMonthApr => '四月';

  @override
  String get featuresMonthMay => '五月';

  @override
  String get featuresMonthJun => '六月';

  @override
  String get featuresMonthJul => '七月';

  @override
  String get featuresMonthAug => '八月';

  @override
  String get featuresMonthSep => '九月';

  @override
  String get featuresMonthOct => '十月';

  @override
  String get featuresMonthNov => '十一月';

  @override
  String get featuresMonthDec => '十二月';

  @override
  String featuresWeekdayName(String day) {
    return '周$day';
  }

  @override
  String featuresCronWeekdayRange(String first, String last) {
    return '$first至$last';
  }

  @override
  String featuresCronEveryDay(String months) {
    return '每天$months';
  }

  @override
  String featuresCronMonthDays(String days, String months) {
    return '每月 $days 日$months';
  }

  @override
  String featuresCronMonthDaysAndWeekdays(String days, String weekdays, String months) {
    return '每月 $days 日且$weekdays$months';
  }

  @override
  String featuresCronMonthDaysOrWeekdays(String days, String weekdays, String months) {
    return '每月 $days 日或$weekdays$months';
  }

  @override
  String featuresCronHourRange(String first, String last) {
    return '$first 至 $last';
  }

  @override
  String get featuresEveryMinute => '每分钟';

  @override
  String featuresCronEveryMinutes(int count) {
    return '每 $count 分钟';
  }

  @override
  String get featuresEveryHour => '每小时';

  @override
  String featuresCronHourlyMinutes(String minutes) {
    return '每小时的第 $minutes 分钟';
  }

  @override
  String featuresCronHoursEveryMinute(String hours) {
    return '$hours 点的每分钟';
  }

  @override
  String featuresCronHoursEveryMinutes(String hours, int count) {
    return '$hours 点内每 $count 分钟';
  }

  @override
  String featuresCronEveryHours(int count) {
    return '每 $count 小时';
  }

  @override
  String featuresCronHoursMinutes(String hours, String minutes) {
    return '$hours 点的第 $minutes 分钟';
  }

  @override
  String get featuresRepeatDaily => '每天';

  @override
  String get featuresRepeatWeekdays => '工作日';

  @override
  String get featuresRepeatWeekly => '每周';

  @override
  String get featuresRepeatMonthly => '每月';

  @override
  String get featuresRepeatInterval => '间隔';

  @override
  String get featuresRepeatOnce => '仅一次';

  @override
  String get featuresRepeatAdvanced => '高级';

  @override
  String get featuresRepeatCustom => '自定义';

  @override
  String get featuresIntervalSeconds => '秒';

  @override
  String get featuresZoneUnavailable => '时区不可用';

  @override
  String get featuresChooseDay => '至少选一天';

  @override
  String get featuresIntervalMinimum => '间隔至少为 1';

  @override
  String get featuresMinimumMinute => '至少 1 分钟';

  @override
  String get featuresTimeDoesNotExist => '这个时间在该时区不存在';

  @override
  String get featuresChooseFutureTime => '选一个以后的时间';

  @override
  String get featuresCronNeverRuns => '这个表达式不会运行';

  @override
  String featuresRuleDaily(String time) {
    return '每天 $time';
  }

  @override
  String featuresRuleWeekdays(String time) {
    return '每个工作日 $time';
  }

  @override
  String featuresRuleWeekends(String time) {
    return '每个周末 $time';
  }

  @override
  String featuresRuleWeekly(String days, String time) {
    return '每周$days $time';
  }

  @override
  String featuresRuleMonthly(String days, String time) {
    return '每月 $days 日 $time';
  }

  @override
  String get featuresRepeat => '重复';

  @override
  String get featuresChat => '对话';

  @override
  String get featuresWorkspace => '工作区';

  @override
  String get featuresInstructionRequired => '填写指令';

  @override
  String featuresScheduleSaveError(String reason) {
    return '没能保存：$reason';
  }

  @override
  String featuresScheduleCreateError(String reason) {
    return '没能创建：$reason';
  }

  @override
  String get featuresScheduleNameHint => '比如：每日站会提醒';

  @override
  String get featuresScheduleInstruction => '指令';

  @override
  String get featuresScheduleInstructionHint => '比如：整理昨天的提交，发我摘要';

  @override
  String get featuresScheduleRunTime => '运行时间';

  @override
  String get featuresScheduleOpenChat => '去对话里看看';

  @override
  String get featuresScheduleEditTitle => '编辑自动化任务';

  @override
  String get featuresScheduleCreateTitle => '新建自动化任务';

  @override
  String get featuresScheduleSaving => '正在保存';

  @override
  String get featuresScheduleCreating => '正在对话里创建';

  @override
  String get featuresTime => '时间';

  @override
  String get featuresNotSelected => '未选';

  @override
  String featuresMonthDaysLabel(String days) {
    return '$days 日';
  }

  @override
  String get featuresTimeZone => '时区';

  @override
  String get featuresScheduleRunLocation => '在哪里运行';

  @override
  String get featuresJustCreatedChat => '刚建的对话';

  @override
  String get featuresModel => '模型';

  @override
  String get featuresRequestRefused => '引擎没有接受这个请求';

  @override
  String get featuresScheduleNotFound => '这个任务已经不在了';

  @override
  String get featuresScheduleEndedError => '任务已结束，不能再改';

  @override
  String get featuresScheduleConflict => '任务刚被改过，返回后再试';

  @override
  String get featuresScheduleInvalidPrompt => '名称和指令不能为空，名称最多 120 字';

  @override
  String get featuresScheduleInvalidTime => '运行时间不对';

  @override
  String get featuresScheduleIntervalTooShort => '间隔至少 1 分钟';

  @override
  String get featuresScheduleTimeOutOfRange => '时间超出范围';

  @override
  String get featuresScheduleSubagentError => '这个对话收不到自动化任务';

  @override
  String get featuresEvery => '每';

  @override
  String get featuresCronExpression => 'Cron 表达式';

  @override
  String get featuresCronFieldGuide => '分  时  日  月  周';

  @override
  String featuresZoneTimeSuffix(String city) {
    return '（$city时间）';
  }

  @override
  String get featuresScheduleNextLocal => '接下来（本机时间）';

  @override
  String get featuresScheduleNext => '接下来';

  @override
  String featuresMonthDayChoice(int day) {
    return '$day 日';
  }

  @override
  String get featuresZonesCommon => '常用';

  @override
  String get featuresZonesAll => '全部';

  @override
  String get featuresZoneSearchHint => '搜索城市、时区或 UTC 偏移';

  @override
  String get featuresZonesNoMatch => '没有匹配的时区';

  @override
  String get featuresZoneUTC => '协调世界时';

  @override
  String get featuresZoneShanghai => '上海';

  @override
  String get featuresZoneUrumqi => '乌鲁木齐';

  @override
  String get featuresZoneHongKong => '香港';

  @override
  String get featuresZoneMacau => '澳门';

  @override
  String get featuresZoneTaipei => '台北';

  @override
  String get featuresZoneTokyo => '东京';

  @override
  String get featuresZoneSeoul => '首尔';

  @override
  String get featuresZoneSingapore => '新加坡';

  @override
  String get featuresZoneKualaLumpur => '吉隆坡';

  @override
  String get featuresZoneBangkok => '曼谷';

  @override
  String get featuresZoneHoChiMinh => '胡志明市';

  @override
  String get featuresZoneJakarta => '雅加达';

  @override
  String get featuresZoneManila => '马尼拉';

  @override
  String get featuresZoneKolkata => '加尔各答';

  @override
  String get featuresZoneDubai => '迪拜';

  @override
  String get featuresZoneJerusalem => '耶路撒冷';

  @override
  String get featuresZoneLondon => '伦敦';

  @override
  String get featuresZoneDublin => '都柏林';

  @override
  String get featuresZoneLisbon => '里斯本';

  @override
  String get featuresZoneParis => '巴黎';

  @override
  String get featuresZoneBerlin => '柏林';

  @override
  String get featuresZoneMadrid => '马德里';

  @override
  String get featuresZoneRome => '罗马';

  @override
  String get featuresZoneAmsterdam => '阿姆斯特丹';

  @override
  String get featuresZoneZurich => '苏黎世';

  @override
  String get featuresZoneStockholm => '斯德哥尔摩';

  @override
  String get featuresZoneWarsaw => '华沙';

  @override
  String get featuresZoneAthens => '雅典';

  @override
  String get featuresZoneIstanbul => '伊斯坦布尔';

  @override
  String get featuresZoneMoscow => '莫斯科';

  @override
  String get featuresZoneCairo => '开罗';

  @override
  String get featuresZoneJohannesburg => '约翰内斯堡';

  @override
  String get featuresZoneLagos => '拉各斯';

  @override
  String get featuresZoneNewYork => '纽约';

  @override
  String get featuresZoneToronto => '多伦多';

  @override
  String get featuresZoneChicago => '芝加哥';

  @override
  String get featuresZoneDenver => '丹佛';

  @override
  String get featuresZonePhoenix => '凤凰城';

  @override
  String get featuresZoneLosAngeles => '洛杉矶';

  @override
  String get featuresZoneVancouver => '温哥华';

  @override
  String get featuresZoneAnchorage => '安克雷奇';

  @override
  String get featuresZoneMexicoCity => '墨西哥城';

  @override
  String get featuresZoneBogota => '波哥大';

  @override
  String get featuresZoneLima => '利马';

  @override
  String get featuresZoneSantiago => '圣地亚哥';

  @override
  String get featuresZoneSaoPaulo => '圣保罗';

  @override
  String get featuresZoneBuenosAires => '布宜诺斯艾利斯';

  @override
  String get featuresZoneHonolulu => '檀香山';

  @override
  String get featuresZoneAuckland => '奥克兰';

  @override
  String get featuresZoneSydney => '悉尼';

  @override
  String get featuresZoneMelbourne => '墨尔本';

  @override
  String get featuresZoneBrisbane => '布里斯班';

  @override
  String get featuresZonePerth => '珀斯';

  @override
  String get featuresScheduleCreated => '已创建';

  @override
  String get featuresSchedulesReadFailed => '没能读取自动化任务';

  @override
  String get featuresSchedulesEmpty => '还没有自动化任务';

  @override
  String get featuresSchedulesEmptyHint => '到点自动发进对话，替你跑一遍';

  @override
  String get featuresScheduleNewTask => '新建任务';

  @override
  String get featuresSchedulesNoMatch => '没有匹配的任务';

  @override
  String get featuresSchedulesNoActive => '没有开启中的任务';

  @override
  String get featuresSchedulesNoEnded => '没有已结束的任务';

  @override
  String get featuresSchedules => '自动化任务';

  @override
  String get featuresSchedulesSubtitle => '到点自动发进原来的对话';

  @override
  String get featuresSchedulesSearch => '搜索任务';

  @override
  String featuresSchedulesAllCount(int count) {
    return '全部 $count';
  }

  @override
  String get featuresScheduleUntitled => '未命名任务';

  @override
  String get featuresScheduleSent => '已发进对话';

  @override
  String get featuresView => '查看';

  @override
  String get featuresSendFailed => '没能发送';

  @override
  String get featuresScheduleDeleteTitle => '删除这个任务？';

  @override
  String get featuresScheduleDeleteHint => '会停止之后的运行，并删掉它的运行记录。原来的对话不受影响。';

  @override
  String get featuresScheduleDeleted => '任务已删除';

  @override
  String get featuresScheduleActive => '已开启';

  @override
  String get featuresScheduleRun => '运行';

  @override
  String get featuresScheduleNextRun => '下次';

  @override
  String get featuresScheduleLastRun => '上次';

  @override
  String get featuresScheduleRule => '规则';

  @override
  String get featuresScheduleLinkedChat => '关联对话';

  @override
  String get featuresScheduleChatDeleted => '对话已删除';

  @override
  String get featuresScheduleEdit => '编辑任务';

  @override
  String get featuresScheduleRunNow => '立即运行';

  @override
  String get featuresScheduleHistory => '运行记录';

  @override
  String get featuresScheduleNeverRun => '还没有运行过';

  @override
  String get featuresScheduleHistoryUnavailable => '记录不可用';

  @override
  String get featuresScheduleHistoryReadFailed => '没能读取运行记录';

  @override
  String get featuresScheduleDelete => '删除任务';

  @override
  String featuresExportSavedTo(String path) {
    return '已存到 $path';
  }

  @override
  String get featuresExportTitle => '导出对话日志';

  @override
  String get featuresExportSubtitle => '打包成一个 ZIP，用于反馈或备份';

  @override
  String get featuresExportUnavailable => '这个连接导不了';

  @override
  String get featuresExportRemoteHint => '经 DSH Remote 中转时拿不到日志，可以在电脑上的网页版导出';

  @override
  String get featuresExportShareHint => '附在问题反馈里，或发给自己';

  @override
  String get featuresExportSaveDownloads => '存到「下载」';

  @override
  String get featuresExportDownloadsHint => '存进 下载/DSH-Go';

  @override
  String get featuresExportContents => '含这个对话和子代理的全部记录与附件';

  @override
  String get featuresSkillUseHere => '在对话里用';

  @override
  String get featuresSkillUseNew => '新对话里用';

  @override
  String get featuresSkillsCallHint => '输入 /技能名 调用';

  @override
  String get featuresSkillsReadFailed => '没能读取技能';

  @override
  String get featuresSkillsEmpty => '这个对话还没有技能';

  @override
  String get featuresSkillsEmptyHint => '放进 .dsh/skills 的技能会出现在这里';

  @override
  String get featuresSkillsSourceHint => '来自项目和 ~/.dsh 下的 skills 目录';

  @override
  String featuresSkillUsage(String usage) {
    return '适用：$usage';
  }

  @override
  String get featuresSkillManual => '仅手动';

  @override
  String featuresArtifactsSemantic(int count) {
    return '产出的文件，共 $count 个，查看全部';
  }

  @override
  String get featuresArtifactsTitle => '产出的文件';

  @override
  String featuresArtifactsAllCount(int count) {
    return '全部 $count 个';
  }

  @override
  String featuresArtifactsCount(int count) {
    return '$count 个';
  }

  @override
  String get featuresArtifactsNoFiles => '还没有文件';

  @override
  String featuresArtifactsTotal(int count) {
    return '$count 个文件 · 交付的和生成的';
  }

  @override
  String get featuresArtifactsEmpty => '还没有产出文件';

  @override
  String get featuresArtifactsEmptyHint => 'AI 交付或生成的文件会出现在这里';

  @override
  String get featuresListSeparator => '、';

  @override
  String featuresErrorReason(String title, String reason) {
    return '$title：$reason';
  }

  @override
  String featuresYearDate(int year, String date) {
    return '$year年$date';
  }

  @override
  String featuresDateWeekdayTime(String date, String week, String time) {
    return '$date $week $time';
  }

  @override
  String featuresDateWeekday(String date, String day) {
    return '$date 周$day';
  }

  @override
  String featuresOnceDescription(String rule, String date, String time) {
    return '$rule · $date $time';
  }

  @override
  String featuresCronMonthSuffix(String months) {
    return '（$months）';
  }

  @override
  String featuresRuleIntervalSeconds(int count) {
    return '每 $count 秒';
  }

  @override
  String featuresRuleIntervalMinutes(int count) {
    return '每 $count 分钟';
  }

  @override
  String featuresRuleIntervalHours(int count) {
    return '每 $count 小时';
  }

  @override
  String featuresSchedulesActiveCount(int count) {
    return '已开启 $count';
  }

  @override
  String featuresSchedulesEndedCount(int count) {
    return '已结束 $count';
  }

  @override
  String featuresScheduleRetention(int days, int count) {
    return '只保留最近 $days 天、最多 $count 条';
  }

  @override
  String featuresScheduleRetentionUnknown(int days) {
    return '只保留最近 $days 天、最多 — 条';
  }

  @override
  String featuresArtifactsDeliveredTurn(int turn) {
    return '第 $turn 轮 · 交付';
  }

  @override
  String featuresArtifactsGeneratedTurn(int turn) {
    return '第 $turn 轮 · 生成';
  }

  @override
  String featuresPresetCreateRequest(String name, String id, String directory) {
    return '新建 Agent 预设「$name」（$id）：在工作区写下这两个文件（内容原样），再用 plugin_manager 的 install_bundle 安装 `$directory` 目录。只做这些。\n\n';
  }

  @override
  String featuresPresetUpdateRequest(String name, String id, String replacing, String directory) {
    return '更新 Agent 预设「$name」（$id）：在工作区写下这两个文件（内容原样），用 plugin_manager 先移除组合包 `$replacing`，再用 install_bundle 安装 `$directory` 目录。只做这些。\n\n';
  }

  @override
  String featuresZoneThisPhone(String city) {
    return '$city · 本机';
  }

  @override
  String get featuresPermissionResetHint => '新对话的默认权限已失效';

  @override
  String get featuresPermissionResetDefault => '恢复默认';

  @override
  String get fileImageName => '图片';

  @override
  String get fileSharedText => '分享的文字.txt';

  @override
  String get fileChatFallback => '对话';

  @override
  String get fileUploadToHost => '传文件到电脑';

  @override
  String get fileUploadToHostHint => '放进这个对话在电脑上的工作区，原文件不压缩';

  @override
  String fileUploadProgress(int done, int total, String name) {
    return '正在传 $done/$total：$name';
  }

  @override
  String fileUploadDone(String names) {
    return '已传到电脑：$names';
  }

  @override
  String get fileUploadFailed => '没能传到电脑';

  @override
  String get harmonyUnknownResults => '有工具调用没等到结果，可能已经执行，也可能没有。处理之前，这个对话不能再调用工具。';

  @override
  String get harmonyUnknownResultsReview => '处理';

  @override
  String get harmonyUnknownResultsTitle => '这些工具调用的结果未知';

  @override
  String harmonyUnknownResultsBody(String tools) {
    return '$tools\n\n应用在等结果时中断了，它们可能已经执行，也可能没有。可以先看看实际情况，比如文件改了没有。\n\n继续之后，这些调用不会重新运行，记录也不会改成成功。';
  }

  @override
  String get harmonyUnknownResultsContinue => '继续这个对话';

  @override
  String get harmonyUnknownResultsChanged => '情况变了，请再看一遍。';

  @override
  String get harmonyUnknownResultsFailed => '没有确认成功，请再试一次。';

  @override
  String get harmonyCallsNotRecorded => '本机引擎记不下工具调用的状态，工具调用已暂停。重启引擎后再试。';

  @override
  String get harmonyAccessSubtitle => '各项功能用到的系统权限';

  @override
  String get harmonyNotifyWhy => '应用在运行时，回复跑完、需要确认会提醒你';

  @override
  String get harmonyKwSystemAccess => '权限一览,授权,麦克风,通知权限,回复提醒,语音输入,补开权限';

  @override
  String get harmonyBackgroundSubtitle => '应用离开屏幕后，本机的对话很快会暂停';

  @override
  String get harmonyBackgroundAway => '离开屏幕后';

  @override
  String get harmonyBackgroundLocal => '正在跑的对话可能还能跑一小会儿，多久由系统决定。之后跟着应用暂停，回到应用后会尽量接着跑';

  @override
  String get harmonyBackgroundRemoteTitle => '已连接的远程主机';

  @override
  String get harmonyBackgroundRemote => '上面的回复继续跑，不受影响';

  @override
  String get harmonyBackgroundLong => '长任务';

  @override
  String get harmonyBackgroundStay => '把应用留在屏幕上';

  @override
  String get harmonyBackgroundUseRemote => '或者放到已连接的远程主机上跑';

  @override
  String get harmonyEngineBackgroundHint => '离开屏幕后本机引擎很快会暂停';

  @override
  String get harmonyKwBackground => '后台,保活,挂起,暂停,被杀,杀后台';

  @override
  String get harmonyPausedInBackground => '对话在后台可能暂停过';

  @override
  String get harmonyAlertsRequirement => '提醒要应用在运行才发得出：离开屏幕后系统很快会挂起应用，挂起期间没有提醒';

  @override
  String get harmonyLiveUnavailable => '这个版本没有进度通知';

  @override
  String get harmonySchedulesLocal => '本机的任务只在应用运行时触发：应用被系统挂起时，到点不会运行';

  @override
  String get harmonyPageUnavailable => '这个版本没有这个页面';

  @override
  String get harmonyNotificationSettingsFailed => '没能打开系统设置。到「设置 → 通知和状态栏 → DSH Go」里开启';

  @override
  String get harmonySearchUnavailable => '这个版本没有这项功能';

  @override
  String get harmonyCredentialsSection => '密钥';

  @override
  String get harmonyCredentialsUnreadable => '已保存的密钥无法读取';

  @override
  String get harmonyCredentialsUnreadableHint => '已保存的密钥无法读取。到「设置 → 隐私与分享」清除后再试';

  @override
  String get harmonyCredentialsClear => '清除已保存的密钥';

  @override
  String get harmonyCredentialsClearBody =>
      '重试没有用。清除后，App 保存的 API key、DSH Remote 登录、SSH 密码和私钥、论坛登录都会被删除，需要重新填写或登录。已发布的分享链接还在，但这台手机上删不掉了。对话和主机列表会保留。此操作无法撤销。';

  @override
  String get harmonyCredentialsClearAction => '清除密钥';

  @override
  String get harmonyCredentialsCleared => '已清除，请重新填写或登录';

  @override
  String get harmonyCredentialsClearFailed => '没能清除，再试一次';

  @override
  String get harmonyIconChangeFailed => '没能更换。使用自定义主题或应用分身时不能换桌面图标';

  @override
  String get harmonyEngineUnclean => '没有正常退出';

  @override
  String get harmonyFailureUnclean => '引擎没有正常退出';

  @override
  String get harmonyFailureUncleanHint => '原因不明：可能是系统回收了应用或应用被关掉，也可能是引擎出了错。';

  @override
  String get harmonyFailureHeld => '连续几次都这样，引擎不会自己启动了。可以再试一次，或换一种方式启动。';

  @override
  String get harmonyResetKept => '主机列表、App 设置和已保存的密钥不受影响。确认后 App 会重新打开，在打开时完成重置。';

  @override
  String get harmonyResetReopening => '重置已记下，App 正在重新打开';

  @override
  String get harmonyResetCommittedTitle => '还差重新打开 App';

  @override
  String get harmonyResetCommittedBody => '重置已经记下，下次打开 App 时完成。可以现在重新打开，也可以自己关掉再打开。';

  @override
  String get harmonyResetUnknownTitle => '不确定重置有没有记下';

  @override
  String get harmonyResetUnknownBody => '重新打开 App：记下了就会完成重置，没记下对话和文件都还在。';

  @override
  String get harmonyResetNotCommittedTitle => '没有重置';

  @override
  String get harmonyResetNotCommittedBody => '对话和文件都还在。引擎已经停了，重新打开 App 后恢复。';

  @override
  String get harmonyResetInstalling => '正在安装运行环境，装完再试';

  @override
  String get harmonyResetOlderPendingTitle => '已经有一次重置在等';

  @override
  String get harmonyResetOlderPendingBody => '重新打开 App 完成它。这次的选择没有生效。';

  @override
  String get harmonyReopenApp => '重新打开';

  @override
  String get harmonyResetPendingTitle => '重置还没完成';

  @override
  String get harmonyResetPendingBody => '重新打开 App 继续。在这之前本机引擎不会启动。';

  @override
  String get harmonyResetFinishing => '正在完成重置';

  @override
  String get harmonyResetDone => '运行环境已重置';

  @override
  String get harmonyResetMaybeDone => 'App 已重新打开。如果对话还在，说明这次重置没有生效，可以再试一次。';

  @override
  String get harmonyUninstallHint => '删除已解压的运行环境和本机数据';

  @override
  String get harmonyUninstallBody => '本机的对话、工作区、插件、设置、界面配置和技能会一并删除，App 会重新打开。安装包里自带的那份运行环境还在，只有卸载 App 才会释放。';

  @override
  String get harmonyKwEngineUninstall => '卸载,删除运行环境,清理本机数据';

  @override
  String get harmonyUpdateNoticeTitle => '到发布页看获取方式';

  @override
  String get harmonyUpdateNoticeText => '鸿蒙版不能在应用内更新。发布页可能还没有鸿蒙安装包。';

  @override
  String get harmonyUpdateNoticeNoPage => '这个版本没有给出下载页，过些时候再看看。';

  @override
  String get harmonyLiveTitle => '进度通知';

  @override
  String get harmonyLiveSwitch => '显示进度通知';

  @override
  String get harmonyLiveSubtitle => '对话进行中，在通知栏显示一条状态';

  @override
  String get harmonyLiveFooter => '这是普通通知，应用被系统挂起后不再更新。';

  @override
  String get harmonyLockScreenPrivacy => '锁屏是否显示对话内容由系统决定：设置 › 通知和状态栏 › 锁屏通知';

  @override
  String get harmonyLiveBlockedTitle => '系统没有允许进度通知';

  @override
  String get harmonyLiveBlockedText => '在系统设置里为 DSH Go 打开通知';

  @override
  String get harmonyAlertsOffTitle => '提醒通知已关闭';

  @override
  String get harmonyAlertsOffText => '回复跑完和等你确认都不会提醒';

  @override
  String get harmonyEnableBanner => '横幅默认关闭，要弹出来请开启「横幅通知」';

  @override
  String get harmonyKwNotifyLive => '进度通知,通知栏进度,状态栏进度';

  @override
  String get harmonyTerminalNoPty => '这个引擎没有交互终端，可连 SSH 主机';

  @override
  String get harmonyTerminalSupportedHosts => '在 SSH 主机上可用';

  @override
  String get harmonyPluginRemoveRefused => '这个引擎不能卸载插件';

  @override
  String get harmonyPluginRefusedHint => '可以开关随包插件，或连接电脑管理插件';

  @override
  String get harmonyVoiceLocalLine => '鸿蒙本机没有语音模型';

  @override
  String get harmonyPasswordStorageHelp => '只保存在这台手机上，由系统密钥库加密';

  @override
  String get harmonyKeyStorageHelp => '只保存在这台手机上，由系统密钥库加密。支持 Ed25519、RSA、ECDSA';

  @override
  String get harmonyUsageNotSent => '鸿蒙版暂不发送使用统计';

  @override
  String get harmonyVoiceSystemHint => '使用系统的语音识别';

  @override
  String get harmonyVoiceSystemHintChinese => '使用系统的语音识别，只认中文';

  @override
  String get harmonyVoiceAutoHint => '有 DeepSeek 账号或 API Key 时用 DeepSeek，否则用系统识别';

  @override
  String get harmonyVoiceSystemUnavailable => '系统语音识别不可用';

  @override
  String get harmonyNetworkRelayOnly => '当前版本走 Relay 中继，全程端到端加密。';

  @override
  String get harmonyNetworkFallbackRelayOnly => '当前版本只走 Relay 中继';

  @override
  String get harmonySetupStay => '安装时请留在这个页面';

  @override
  String get harmonyLaunchEmbedded => '应用内启动';

  @override
  String get harmonyLaunchNodeExited => '引擎已退出';

  @override
  String get harmonyKwAccent => '颜色,主题色,强调色';

  @override
  String get harmonyKwPets => '宠物,小鲸,桌宠,鲸鱼';

  @override
  String get harmonyKwVoice => '语音识别,麦克风,听写,说话,语音';

  @override
  String get harmonyBackgroundSubtitleLong => '应用离开屏幕后，正在跑的对话会尽量继续';

  @override
  String get harmonyBackgroundLocalLong => '这个版本可以申请长时任务：对话留在后台继续跑，通知栏会有一条提示。系统不批准或中途收回时，对话跟着应用暂停，回到应用后会尽量接着跑';

  @override
  String get harmonyEngineBackgroundHintLong => '离开屏幕后，正在跑的对话会尽量继续';

  @override
  String get harmonyAlertsRequirementLong => '提醒要应用在运行才发得出：对话在后台继续时会提醒，应用被系统挂起后就没有了';

  @override
  String get harmonySaveToFile => '保存到文件';

  @override
  String get harmonySaveChooseLocation => '选择保存位置';

  @override
  String get harmonySaving => '正在保存…';

  @override
  String get harmonySaved => '已保存';

  @override
  String get harmonyCommandExportDescription => '把这个对话的完整记录打包成 ZIP，分享或保存到文件';

  @override
  String get harmonySafeEnterTitle => '以安全模式启动？';

  @override
  String get harmonySafeEnterBody => '用随包的默认配置启动，不加载你装的插件。对话都在，原来的配置不会改动。';

  @override
  String get harmonySafeReopenNote => '进行中的回复会中断，App 会重新打开。';

  @override
  String get harmonyRestoredReopening => '已恢复上次正常的配置，App 正在重新打开';

  @override
  String harmonySafeRepairPrompt(String what) {
    return '我的 DSH 正常模式出了问题（$what）。现在是安全模式，用的是随包的默认配置，我原来的配置没有动。请帮我找原因，动手改之前先告诉我要改什么。';
  }

  @override
  String get harmonyRemindersTitle => '闹钟和计时器';

  @override
  String get harmonyRemindersCanHint => '到点由系统提醒，引擎不会因此运行。系统也可能不接受，AI 会告诉你';

  @override
  String get harmonyRemindersNoBuild => '这个版本没有开通系统提醒';

  @override
  String get harmonyRemindersNoDevice => '这台设备没有系统提醒';

  @override
  String get harmonyReminderSet => '已设提醒';

  @override
  String get harmonyReminderRefused => '系统没有接受提醒，没有设置。';

  @override
  String get harmonyPluginVoiceUnavailable => '这台设备不能听你开口';

  @override
  String get hostDetailsConnectionType => '连接方式';

  @override
  String get hostDetailsSshNetworkHint => '通过 SSH 隧道连接。此连接不提供 LAN / P2P 路径检测或延迟测量。';

  @override
  String get hubSessionDetails => '对话详情';

  @override
  String get hubTerminal => '终端';

  @override
  String get hubSessionNoTurns => '还没有完整的一轮';

  @override
  String get hubSessionElapsed => '用时';

  @override
  String get hubSessionSteps => '步骤';

  @override
  String get hubSessionChangedFiles => '改动文件';

  @override
  String get hubSessionTrajectoryHint => '每一轮的步骤和用时会排在这里';

  @override
  String get hubSessionLoadEarlier => '加载更早的轮次';

  @override
  String get hubSessionError => '出错';

  @override
  String get hubSessionInterrupted => '被中断';

  @override
  String get hubSessionOutputLimit => '达到输出上限';

  @override
  String get hubSessionNoChanges => '还没有改过文件';

  @override
  String get hubSessionShellChangesHint => '用 shell 命令改的文件不在这里';

  @override
  String get hubSessionChanges => '对话改动';

  @override
  String get hubSessionChangesNote => '只统计已加载的记录里，用写入和编辑工具做的改动';

  @override
  String get hubSessionNoGoal => '还没有目标或待办';

  @override
  String get hubSessionGoalHint => '复杂任务里 AI 会列出待办，进度在这里看';

  @override
  String get hubSessionGoal => '目标';

  @override
  String get hubSessionPlanMode => '计划模式';

  @override
  String get hubSessionPlanSwitching => '正在切换计划模式';

  @override
  String get hubSessionPlanHint => 'AI 先出方案，不改文件';

  @override
  String get hubSessionTodos => '待办';

  @override
  String get hubSessionNotStarted => '未开始';

  @override
  String get hubSessionTurnUsage => '每轮用量';

  @override
  String get hubSessionNoSubagents => '没有派出子代理';

  @override
  String get hubSessionDelegations => '派活记录';

  @override
  String get hubTabTrajectory => '轨迹';

  @override
  String get hubTabChanges => '改动';

  @override
  String get hubTabFiles => '文件';

  @override
  String get hubTabProgress => '进度';

  @override
  String get hubTabContext => '上下文';

  @override
  String get hubTabSubagents => '子代理';

  @override
  String get hubPlugins => '插件';

  @override
  String get hubSettingsFullAccessTitle => '开启完全权限？';

  @override
  String get hubSettingsFullAccessBody => 'AI 执行命令、改动文件前不再问你。';

  @override
  String get hubSettingsStorageTitle => '让 AI 访问手机文件？';

  @override
  String get hubSettingsStorageAllow => '允许读写';

  @override
  String get hubSettingsStorageDenied => '没有拿到存储权限。到系统设置里给 DSH Go 开启「所有文件访问」后再试';

  @override
  String get hubSettingsRestartRequired => '重启引擎后生效';

  @override
  String get hubSettingsRestartNow => '立即重启';

  @override
  String get hubSettingsInterface => '界面';

  @override
  String get hubSettingsChat => '对话';

  @override
  String get hubSettingsAutoCommands => '自动执行命令';

  @override
  String get hubSettingsPhoneFiles => '访问手机文件';

  @override
  String get hubSettingsPhoneFilesHint => 'AI 可读写手机存储';

  @override
  String get hubSettingsVisualReplies => '可视化回复';

  @override
  String get hubSettingsVisualRepliesHint => '图表、对比卡和可点的选项';

  @override
  String get hubSettingsPhoneControl => '手机操控';

  @override
  String get hubSettingsPhoneControlHint => '看屏幕、帮你点按';

  @override
  String get hubSettingsPreferences => '个人偏好';

  @override
  String get hubSettingsAppearance => '外观';

  @override
  String get hubSettingsChatTextSize => '对话字号';

  @override
  String get hubSettingsCollapseSteps => '完成后收起过程';

  @override
  String get hubSettingsCollapseStepsHint => '思考与工具调用收成一行';

  @override
  String get hubSettingsWebPhoneLayout => '网页版手机布局';

  @override
  String get hubSettingsWebPhoneLayoutHint => '为手机屏幕重排网页版';

  @override
  String get hubSettingsEngineExtensions => '引擎与扩展';

  @override
  String get hubSettingsEngine => '本机引擎';

  @override
  String get hubSettingsProviders => '模型';

  @override
  String get hubSettingsEngineSettings => '引擎参数';

  @override
  String get hubSettingsShareConfig => '分享配置';

  @override
  String get hubSettingsAllFeatures => '全部功能';

  @override
  String get hubSettingsAbout => '关于';

  @override
  String get hubSettingsCommunity => '社区';

  @override
  String get hubSettingsLicenses => '开源许可';

  @override
  String get hubSettingsAccount => 'DeepSeek 账号';

  @override
  String get hubSettingsSigningIn => '正在登录…';

  @override
  String get hubSettingsInvalidKey => 'Key 无效，查不到余额';

  @override
  String get hubSettingsNoApiKey => '未设置 API Key';

  @override
  String get hubSettingsApiKeyHint => '填写 Key 后即可对话';

  @override
  String get hubSettingsSignInAccount => '登录 DeepSeek 账号';

  @override
  String get hubSettingsOrApiKey => '或填写 API Key';

  @override
  String get hubPluginShare => '分享插件';

  @override
  String get hubPluginDetails => '插件详情';

  @override
  String get hubPluginFeatured => 'dshfind 推荐';

  @override
  String get hubPluginWebOnly => '仅网页版';

  @override
  String get hubPluginStars => '星标';

  @override
  String get hubPluginSource => '来源';

  @override
  String get hubPluginInstalledVersion => '已装版本';

  @override
  String get hubPluginRequiresDsh => '需要 DSH';

  @override
  String get hubPluginPackageName => '包名';

  @override
  String get hubPluginHomepage => '主页';

  @override
  String get hubPluginRepository => '代码仓库';

  @override
  String get hubPluginManageTitle => '管理插件';

  @override
  String get hubPluginManage => '管理';

  @override
  String get hubPluginSafeModeInstall => '安全模式下不能安装';

  @override
  String get hubPluginInstallCommand => '获取安装命令';

  @override
  String get hubPluginInstallComputer => '在电脑上安装';

  @override
  String get hubPluginInstalling => '安装中…';

  @override
  String get hubPluginAllowBuilds => '允许构建脚本并重试';

  @override
  String get hubPluginRetryInstall => '重试安装';

  @override
  String get hubPluginOfficial => 'DSH 官方';

  @override
  String get hubPluginNotLoaded => '没有正常加载';

  @override
  String get hubPluginComponents => '组件';

  @override
  String get hubPluginSafeModeRemove => '安全模式下不能卸载';

  @override
  String get hubPluginRemoveCommand => '获取卸载命令';

  @override
  String get hubPluginRemoveComputer => '在电脑上卸载';

  @override
  String get hubPluginUninstall => '卸载';

  @override
  String hubSessionTurns(int count) {
    return '共 $count 轮';
  }

  @override
  String hubSessionTurnsRunning(int count) {
    return '共 $count 轮 · 进行中';
  }

  @override
  String hubSessionStepCount(int count) {
    return '$count 步';
  }

  @override
  String hubSessionWaitTime(String duration) {
    return '等你 $duration';
  }

  @override
  String hubSessionTurn(int turn) {
    return '第 $turn 轮';
  }

  @override
  String hubSessionFileCount(int count) {
    return '改动了 $count 个文件';
  }

  @override
  String hubSessionEditCount(int count) {
    return '改了 $count 次';
  }

  @override
  String hubSessionTurnOf(int turn, int total) {
    return '第 $turn / $total 轮';
  }

  @override
  String hubSessionCacheHit(String percent) {
    return '命中 $percent';
  }

  @override
  String get hubSessionBlocked => '受阻';

  @override
  String hubSessionBlockedReason(String reason) {
    return '受阻：$reason';
  }

  @override
  String hubSessionTodoSemantics(String content, String status) {
    return '$content,$status';
  }

  @override
  String get hubSettingsStorageBody => 'AI 能读取和修改相册、下载、文档等手机文件，引擎会重启一次。';

  @override
  String hubSettingsBalance(String amount) {
    return '余额 $amount';
  }

  @override
  String hubSettingsBalanceLow(String amount) {
    return '余额 $amount · 余额不足';
  }

  @override
  String hubSettingsAccountSemantics(String title, String subtitle) {
    return '账号：$title，$subtitle';
  }

  @override
  String hubSettingsHostSemantics(String name, String status) {
    return '远程主机：$name，$status';
  }

  @override
  String get hubSettingsApiKey => 'DeepSeek API Key';

  @override
  String hubPluginBrowserFailed(String address) {
    return '没能打开浏览器，请手动访问 $address';
  }

  @override
  String hubPluginYearMonth(int year, String month) {
    return '$year年$month月';
  }

  @override
  String hubPluginUpdateTo(String version) {
    return '更新到 $version';
  }

  @override
  String hubPluginInstallOn(String host) {
    return '安装到$host';
  }

  @override
  String hubPluginComponentCount(int count) {
    return '$count 个';
  }

  @override
  String get hubPluginComponentSeparator => '、';

  @override
  String get hubGroupAi => 'AI';

  @override
  String get hubGroupCapabilities => '能力';

  @override
  String get hubGroupGeneral => '通用';

  @override
  String get hubGroupHosts => '主机';

  @override
  String get hubGroupHelp => '帮助与关于';

  @override
  String get hubPersonalization => '个性化';

  @override
  String get hubPersonalizationAboutYou => '关于你';

  @override
  String get hubPersonalizationReplies => '回答';

  @override
  String get hubPersonalizationWorkStyle => '工作方式';

  @override
  String get hubPrivacy => '隐私与分享';

  @override
  String get hubPrivacySharing => '分享';

  @override
  String get hubInterfaceHome => '首页';

  @override
  String get hubInterfaceWebHint => 'DSH 官方网页版';

  @override
  String get hubInterfaceOpenWeb => '打开网页版';

  @override
  String get hubInterfacePhoneLayout => '手机布局';

  @override
  String get hubTableTint => '表格底色';

  @override
  String get hubTableTintFollow => '跟随主题';

  @override
  String get hubTableTintFill => '淡底整表';

  @override
  String get hubTableTintNone => '无底色';

  @override
  String get hubTableTintFillHint => '隔行淡一档，长表格更好扫读';

  @override
  String get hubTableTintFollowHint => '表头浅底，表身跟随正文';

  @override
  String get hubTableTintNoneHint => '只剩网格线，最轻';

  @override
  String get hubAbout => '关于 DSH Go';

  @override
  String get hubAboutAuthor => 'DSH Go 原作者';

  @override
  String get hubAboutBilibili => 'B站主页';

  @override
  String get hubAboutX => 'X 主页';

  @override
  String get hubAboutGithub => 'GitHub 主页';

  @override
  String get hubAboutNewVersion => '有新版本';

  @override
  String get hubValueSet => '已设置';

  @override
  String get hubValueOff => '未开启';

  @override
  String get hubValueOneStep => '还差一步';

  @override
  String get hubValueAllowed => '已允许';

  @override
  String get hubValueNeedsSetup => '需设置';

  @override
  String hubValueHosts(int count) {
    return '$count 台';
  }

  @override
  String get hubValueNoHosts => '未添加';

  @override
  String hubValuePlugins(int count) {
    return '$count 个';
  }

  @override
  String get hubEngineStartup => '启动';

  @override
  String get hubThemeLightDark => '明暗';

  @override
  String get hubPermissionPhone => '手机';

  @override
  String get hubPermissionPhoneConfirm => '手机操控确认';

  @override
  String get hubHardwareEnterSends => '外接键盘按 Enter 发送';

  @override
  String get hubHardwareEnterSendsHint => '开启后，Shift+Enter 换行。屏幕键盘仍换行；Ctrl/⌘+Enter 始终可发送。';

  @override
  String get hubQuickPanel => '左滑快捷入口';

  @override
  String get hubQuickPanelSwipe => '左滑打开';

  @override
  String get hubQuickPanelSwipeHint => '在对话里从右向左滑。代码块、表格这些能横向滚动的内容不受影响。';

  @override
  String get hubQuickPanelItems => '显示的入口';

  @override
  String get hubQuickPanelItemsNone => '没有选择，左滑不会打开';

  @override
  String get iosSaveToFiles => '存到「文件」';

  @override
  String get iosFilesFolderHint => '文件 App 的 DSH Go 文件夹';

  @override
  String get iosSavingToFiles => '正在存到「文件」…';

  @override
  String get iosCommandExportDescription => '把这个对话的完整记录打包成 ZIP，分享或存到「文件」';

  @override
  String get iosEnableBanners => '横幅不弹时，到系统设置打开「横幅」';

  @override
  String get iosNotificationSettingsFailed => '没能打开系统设置。到「设置 → DSH Go → 通知」里开启';

  @override
  String get iosVoiceSystemHint => '使用系统的语音识别';

  @override
  String get iosVoiceAllowSystem => '请在系统设置里允许语音识别';

  @override
  String get iosPluginsPermissionLocalThirdParty => '插件以 DSH 的权限运行：能读写文件、执行命令、读取 API Key，不受工作区沙箱限制。由第三方提供，DSH 官方未审核。';

  @override
  String get iosPluginsPermissionLocalTrusted => '插件以 DSH 的权限运行：能读写文件、执行命令、读取 API Key，不受工作区沙箱限制。只装你信任的插件。';

  @override
  String get iosIconChanged => '桌面图标已更换';

  @override
  String get iosPhotosDenied => '没有相册权限，未能保存';

  @override
  String get iosRelocationOriginUnavailable => '发现旧对话，但找不到它们原来的位置。原数据都还在，这些对话暂时不能继续。';

  @override
  String get iosRelocationSessionIsolated => '有些对话没能迁移，已经单独保留。原文件和原因都还在，可以在诊断里导出后反馈。';

  @override
  String get iosAccessSubtitle => '各项功能用到的系统权限';

  @override
  String get iosLinuxTitle => 'Linux 环境';

  @override
  String get iosLinuxIntro => '装好并重启本机引擎后，普通命令会在 Linux 里运行。Python 等软件需用 apk 另装；修改 Linux 系统仍需本次审批。App 文件只开放工作区和临时目录。';

  @override
  String get iosLinuxInstall => '安装 Linux 环境';

  @override
  String get iosLinuxDownloadSize => '约 4 MB';

  @override
  String get iosLinuxDownloading => '正在下载';

  @override
  String get iosLinuxVerifying => '正在校验';

  @override
  String get iosLinuxExtracting => '正在解压';

  @override
  String get iosLinuxFinishing => '即将完成';

  @override
  String get iosLinuxSystem => '系统';

  @override
  String get iosLinuxStorage => '占用空间';

  @override
  String get iosLinuxUninstall => '卸载 Linux 环境';

  @override
  String get iosLinuxUninstallBody => '会删除 Linux 环境和在里面装的所有软件。工作区里的文件不受影响。';

  @override
  String get iosLinuxUninstallConfirm => '卸载';

  @override
  String get iosLinuxUninstalling => '正在卸载…';

  @override
  String get iosLinuxRestartEngine => '已装好。重启本机引擎后，命令才会用上它。';

  @override
  String get iosLinuxErrorNetwork => '下载没成功。检查网络后再试一次。';

  @override
  String get iosLinuxErrorDamaged => '下载的文件不完整，已经丢掉了，再试一次。';

  @override
  String get iosLinuxErrorNoSpace => '手机存储空间不够了。';

  @override
  String get iosLinuxErrorInUse => 'Linux 环境正在使用，重新打开 App 后才能卸载。';

  @override
  String get iosLinuxErrorOther => '没有完成，再试一次。';

  @override
  String get iosLinuxState => '状态';

  @override
  String get iosLinuxStatePaused => '已暂停';

  @override
  String get iosLinuxSuspendedBody => '上次 App 退出时，Linux 里还有命令没跑完，App 可能就是因为它闪退的。为免再闪退，Linux 环境先暂停，其他功能照常。想再用就重新启用。';

  @override
  String get iosLinuxResume => '重新启用 Linux 环境';

  @override
  String get iosLinuxResumed => '已重新启用。重启本机引擎后，命令才会用上它。';

  @override
  String get iosLinuxErrorBusy => 'Linux 环境还在使用。等命令停下再试，不行就重新打开 App。';

  @override
  String get iosPhoneLinkTitle => '本机连接';

  @override
  String get iosPhoneLinkIntro =>
      '用这台 iPhone 自己的开发者服务读屏、点按和输入，不用一直连着电脑。先打开开发者模式，并确认用于本机连接的 LocalDevVPN 已接通。每个任务首次授权一次，最多 30 分钟，可随时暂停。';

  @override
  String get iosPhoneLinkUnavailable => '需要 iOS 17 或更高版本。';

  @override
  String get iosPhoneLinkStepPairing => '导入配对凭据';

  @override
  String get iosPhoneLinkPairingHint => '用 Mac 或 Windows 电脑生成的远程配对文件（.plist）';

  @override
  String get iosPhoneLinkPairingDevice => '已记住在这台手机上';

  @override
  String get iosPhoneLinkPairingSession => '只用这一次，退出 App 后清除';

  @override
  String get iosPhoneLinkPairingLocked => '手机解锁后才能读取保存的凭据';

  @override
  String get iosPhoneLinkPairingUnreadable => '保存的凭据读不出来，重新导入一次';

  @override
  String get iosPhoneLinkImport => '导入';

  @override
  String get iosPhoneLinkReplace => '更换';

  @override
  String get iosPhoneLinkLegacy => '发现旧版本留下的配对文件';

  @override
  String get iosPhoneLinkLegacyHint => '迁移时按你选的方式保存，然后删掉旧文件。迁移前不会用它。';

  @override
  String get iosPhoneLinkMigrate => '迁移';

  @override
  String get iosPhoneLinkStepEnable => '打开开发者连接';

  @override
  String get iosPhoneLinkEnableHint => '默认关闭。关掉会立刻停下正在进行的手机任务。';

  @override
  String get iosPhoneLinkStepCheck => '检查连接';

  @override
  String get iosPhoneLinkCheckHint => '确认 VPN、配对和开发者服务都通';

  @override
  String get iosPhoneLinkCheck => '检查';

  @override
  String get iosPhoneLinkChecked => '连接正常';

  @override
  String get iosPhoneLinkReadOnly => '连接正常，可读屏和打开应用；点按、滚动和输入需使用 XCTest 增强';

  @override
  String get iosPhoneLinkErrorServices => '当前开发者服务不支持这条 CoreDevice 连接。已有镜像时重新下载不一定有用；可启用 XCTest 增强，或交还自己操作。';

  @override
  String get iosPhoneLinkDdi => '开发者镜像';

  @override
  String get iosPhoneLinkDdiHint =>
      '部分功能需要。约 17 MB，来自第三方 DeveloperDiskImage 镜像仓库（不是 Apple 下载站），按固定哈希校验，再由 Apple 为这台手机个性化。';

  @override
  String get iosPhoneLinkDdiPrepare => '准备';

  @override
  String get iosPhoneLinkDdiMounted => '已挂载';

  @override
  String get iosPhoneLinkWorking => '正在处理…';

  @override
  String iosPhoneLinkDownloading(String done, String total) {
    return '正在下载 $done / $total';
  }

  @override
  String get iosPhoneLinkClear => '清除配对凭据';

  @override
  String get iosPhoneLinkClearHint => '同时关掉开发者连接。电脑和「文件」里的原文件需要你自己删。';

  @override
  String get iosPhoneLinkClearConfirm => '清除配对凭据？';

  @override
  String get iosPhoneLinkEnhanceTitle => '可选增强';

  @override
  String get iosPhoneLinkXctest => 'XCTest 增强';

  @override
  String get iosPhoneLinkXctestHint => '需要另外安装并签名 PhoneRunner，能读取界面元素。部分 App 可能要求重新登录或拒绝使用。不开时用本机连接。';

  @override
  String get iosPhoneLinkClipboardTitle => '回到 App 恢复原剪贴板';

  @override
  String get iosPhoneLinkClipboardHint => '输入时临时借用了剪贴板。先核对目标 App 已经完成或取消粘贴，再恢复。';

  @override
  String get iosPhoneLinkClipboardRestore => '恢复';

  @override
  String get iosPhoneLinkClipboardOverwrite => '仍要恢复，覆盖现在的剪贴板';

  @override
  String get iosPhoneLinkClipboardDiscard => '丢弃保存的旧剪贴板';

  @override
  String get iosPhoneLinkErrorBusy => '连接设置仍在处理另一项准备。回到「本机连接」点取消，确认 LocalDevVPN 已接通后再检查。';

  @override
  String get iosPhoneLinkErrorForeground => '要在 App 打开、手机解锁时操作。';

  @override
  String get iosPhoneLinkErrorPairingInvalid => '这个文件不是可用的远程配对凭据。';

  @override
  String get iosPhoneLinkErrorStorage => '保存没成功。「记住在这台手机上」需要手机设了解锁密码。';

  @override
  String get iosPhoneLinkErrorPairingRequired => '先导入配对凭据。';

  @override
  String get iosPhoneLinkErrorTunnel => '连不上本机服务。先确认用于本机连接的 LocalDevVPN 已接通、开发者模式已打开，再检查连接。';

  @override
  String get iosSpeechCallEndNoRecognizer => '语音通话需要能识别录音的方式：登录 DeepSeek 账号、填写 API Key，或配置其他可用的云端识别。iOS 暂不提供本地语音模型下载。';

  @override
  String get iosSpeechCallEndNoRecognizerSignedIn =>
      '当前连接不能用已登录账号识别通话录音（例如经 DSH Remote 中继）；请填写 DeepSeek API Key 或配置其他可用的云端识别。iOS 暂不提供本地语音模型下载。';

  @override
  String get iosPhoneLinkErrorPairingRejected => '手机不认这份配对凭据。重新生成一份再导入。';

  @override
  String get iosPhoneLinkErrorDdiNeeded => '需要先准备开发者镜像。';

  @override
  String get iosPhoneLinkErrorDdiDownload => '镜像下载没成功。检查网络后再试。';

  @override
  String get iosPhoneLinkErrorDdiIntegrity => '下载的镜像没通过校验，已经丢掉了。';

  @override
  String get iosPhoneLinkErrorDdiUnsupported => '没有适合这台手机型号或系统版本的镜像。';

  @override
  String get iosPhoneLinkErrorDdiMount => '挂载没成功。已经在用的其他镜像不会被替换。';

  @override
  String get iosPhoneLinkErrorClipboardChanged => '之后又复制过别的内容，所以没有恢复。';

  @override
  String get iosPhoneLinkFaulted => '上一次连接没能确认已经关掉';

  @override
  String get iosPhoneLinkFaultedHint => '为了不让两条连接同时操作手机，先不再连接。如果上一次连接稍后确认关掉了，这里会自动恢复；一直没恢复的话，在后台彻底关掉 App 再重新打开。';

  @override
  String iosPhoneLinkErrorOther(String code) {
    return '没有完成（$code）。';
  }

  @override
  String get iosPetPipTitle => '宠物画中画';

  @override
  String get iosPetPipHint => '可选的宠物小窗，可以辅助后台运行。手机操控使用系统持续任务，不需要先开启画中画或选择宠物。';

  @override
  String get iosPetPipRequired => '可选，默认关闭';

  @override
  String get iosPetPipReady => '已就绪，手机任务开始时出现';

  @override
  String get iosPetPipKeepingAlive => '正在让 App 在后台继续运行';

  @override
  String get iosPetPipAlways => '任务结束后也留着';

  @override
  String get iosPetPipStart => '开始画中画';

  @override
  String get iosPetPipStartHint => '画中画没有自己出现时，点这里打开';

  @override
  String get iosPetPipPaused => '手机任务在画中画里暂停了';

  @override
  String get iosPetPipReview => '继续或停止';

  @override
  String get iosPetPipResume => '恢复';

  @override
  String get iosPetPipChoosePet => '选宠物';

  @override
  String get iosPetPipErrorNoPet => '先选一只宠物';

  @override
  String get iosPetPipErrorUnsupported => '这台手机不支持画中画';

  @override
  String get iosPetPipErrorLocked => '锁屏时画中画停了';

  @override
  String get iosPetPipErrorAudio => '录音、通话或别的声音占用时，画中画停了';

  @override
  String get iosPetPipErrorPack => '这只宠物的素材有问题，换一只试试';

  @override
  String get iosPetPipErrorStart => '画中画没能打开';

  @override
  String get iosPetPipErrorClosed => '画中画被关掉了';

  @override
  String iosPetPipErrorOther(String code) {
    return '画中画停了（$code）';
  }

  @override
  String get iosPetPipChoosePetHint => '在宠物设置里选一只';

  @override
  String get iosPetPipReopen => '重新准备画中画';

  @override
  String get launchScreenTitle => '启动画面';

  @override
  String get launchDefault => '默认';

  @override
  String get launchCustom => '自定义';

  @override
  String get launchFit => '适配方式';

  @override
  String get launchFitFill => '填满';

  @override
  String get launchFitCenter => '居中';

  @override
  String get launchFrame => '调整位置';

  @override
  String get launchBackground => '背景色';

  @override
  String get launchBackdropAuto => '自动';

  @override
  String get launchBackdropEdge => '取自图片';

  @override
  String get launchBackdropWhite => '白色';

  @override
  String get launchBackdropBlack => '黑色';

  @override
  String get launchReplace => '更换图片或视频';

  @override
  String get launchPreview => '预览';

  @override
  String get launchFooter => '图片、动图 8 MB 以内，视频 30 MB 以内。冷启动时完整播放一遍，轻点可跳过';

  @override
  String get launchChanged => '启动画面已更换';

  @override
  String launchChangedSize(String size) {
    return '启动画面已更换 · $size';
  }

  @override
  String get launchTooLarge => '图片超过 8 MB';

  @override
  String get launchOverLimit => '文件超过 30 MB';

  @override
  String get launchUnsupported => '支持 PNG、JPEG、WebP、GIF 和 MP4';

  @override
  String get launchUnreadable => '无法读取这个文件';

  @override
  String get launchUnavailable => '无法打开相册';

  @override
  String get launchBroken => '无法读取';

  @override
  String get iconShortcutRow => '图片快捷方式';

  @override
  String get iconShortcutRowSubtitle => '用自己的图片在桌面放一个入口';

  @override
  String get iconShortcutPick => '选择图片';

  @override
  String get iconShortcutChange => '换一张';

  @override
  String get iconShortcutHint => '拖动或双指缩放';

  @override
  String get iconShortcutName => '名称';

  @override
  String get iconShortcutAdd => '添加到桌面';

  @override
  String get iconShortcutNote => '系统不允许把桌面图标换成任意图片，这里会另放一个打开 DSH Go 的快捷方式；部分桌面会在它的角上加一个小标';

  @override
  String get iconShortcutAdded => '已添加到桌面';

  @override
  String get iconShortcutConfirm => '在弹出的窗口里确认';

  @override
  String get iconShortcutNoDialog => '没有弹窗？在系统设置里允许 DSH Go 创建桌面快捷方式';

  @override
  String get iconShortcutSettings => '去设置';

  @override
  String get iconShortcutUnsupported => '这个桌面不支持添加快捷方式';

  @override
  String get iconShortcutFailed => '没能添加，稍后再试';

  @override
  String get searchKwLaunchScreen => '开屏,启动动画,闪屏,开机画面,欢迎画面';

  @override
  String get searchKwIconShortcut => '快捷方式,自定义图标,桌面图片,换图标';

  @override
  String get linuxTitle => 'Linux 环境';

  @override
  String get linuxSubtitle => '在手机里运行 gh、Python、git 等命令行工具';

  @override
  String get linuxSwitch => '开启 Linux';

  @override
  String get linuxStatus => '状态';

  @override
  String get linuxFirstHint => '第一次开启会下载约 3.5 MB 的基础系统并安装，大约一两分钟；之后再开几秒就好。';

  @override
  String get linuxMemoryNote => '开着 Linux 时 App 大约多占 100 MB 以上内存；关掉开关会把这部分还给系统，之后要重新打开 App 才能再开启。';

  @override
  String get linuxStateOn => '已开启';

  @override
  String get linuxStateOff => '未开启';

  @override
  String get linuxStateInstalling => '正在准备';

  @override
  String get linuxStateStopping => '正在关闭';

  @override
  String get linuxStateFailed => '出错了';

  @override
  String get linuxStateUnavailable => '暂不可用';

  @override
  String get linuxStageDownload => '下载基础系统';

  @override
  String get linuxStageDisk => '准备磁盘';

  @override
  String get linuxStageBoot => '启动';

  @override
  String get linuxStageTools => '安装工具';

  @override
  String get linuxEngineOffline => '本机引擎没在运行，启动引擎后再来开启。';

  @override
  String get linuxRequestFailed => '没能和引擎通信，请稍后重试。';

  @override
  String get linuxRestartRequired => 'Linux 已经停止，重新打开 App 后才能再开启。';

  @override
  String get linuxReopenApp => '重新打开 App';

  @override
  String get linuxReopenFailed => '没能自动重新打开，请手动退出 App 再打开。';

  @override
  String linuxErrorWithCode(String code) {
    return '没能开启：$code';
  }

  @override
  String get linuxReinstall => '重新安装 Linux';

  @override
  String get linuxReinstallHint => '删除 Linux 里的全部内容，再开启时全新安装';

  @override
  String get linuxReinstallAfterRestart => '这次运行已经启动过 Linux：完全退出并重新打开 App 后才能重新安装';

  @override
  String get linuxReinstallTitle => '重新安装 Linux？';

  @override
  String get linuxReinstallBody =>
      '会删除 Linux 里的全部内容：装过的软件和 Python 包、只存在 Linux 里的文件，以及在 Linux 里登录过的账号（比如 gh）。对话工作区里的文件不受影响。\n\n开关保持关闭；之后打开会重新下载并安装。';

  @override
  String linuxRetainedRefused(String code) {
    return '原来的 Linux 数据没法继续用了（常见于 App 更新之后），App 不会自动覆盖它。点「重新安装 Linux」删除后再开启，即可全新安装。（$code）';
  }

  @override
  String get linuxReinstallRestart => '这次运行已经启动过 Linux，数据可能仍被占用。完全退出并重新打开 App 后，再点「重新安装 Linux」。';

  @override
  String linuxReinstallFailed(String code) {
    return '没能重新安装：$code';
  }

  @override
  String get linuxProxyTitle => '网络代理';

  @override
  String get linuxProxyFooter => '只作用于 Linux 里的命令。gitee、华为云等国内源始终直连。';

  @override
  String get linuxProxyMode => '方式';

  @override
  String get linuxProxyInherit => '跟随 App';

  @override
  String get linuxProxyDirect => '不用代理';

  @override
  String get linuxProxyManual => '手动';

  @override
  String get linuxProxyHttp => 'HTTP 代理';

  @override
  String get linuxProxyHttps => 'HTTPS 代理';

  @override
  String get linuxProxyNoProxy => '不走代理的地址';

  @override
  String get linuxProxyUnset => '未设置';

  @override
  String get linuxProxySameAsHttp => '同 HTTP';

  @override
  String get linuxProxyLoopbackNote => '127.0.0.1 指的是这台手机，不是电脑。';

  @override
  String get linuxProxyUrlInvalid => '请填 http:// 或 https:// 开头的地址，例如 http://127.0.0.1:7890';

  @override
  String get searchKwLinux => 'Linux,终端,命令行,虚拟机,gh,GitHub CLI,python,pip,代理';

  @override
  String get liveThinking => '正在思考';

  @override
  String get liveWorking => '正在干活';

  @override
  String get liveJuggling => '子代理在帮忙';

  @override
  String get liveSweeping => '正在整理上下文';

  @override
  String liveRunsCount(int count) {
    return '$count 个对话在跑';
  }

  @override
  String get liveChipThinking => '思考中';

  @override
  String get liveChipWorking => '干活中';

  @override
  String get liveChipJuggling => '协作中';

  @override
  String get liveChipSweeping => '整理中';

  @override
  String get liveChipApproval => '待确认';

  @override
  String get liveChipQuestion => '待回答';

  @override
  String get liveChipDone => '完成';

  @override
  String get liveChipFailed => '出错';

  @override
  String get livePublicRunning => 'DSH 正在干活';

  @override
  String get livePublicWaiting => 'DSH 在等你处理';

  @override
  String get livePublicDone => 'DSH 做完了';

  @override
  String get livePublicFailed => 'DSH 出错了';

  @override
  String get liveSettingsTitle => '实时活动';

  @override
  String get liveSettingsSwitch => '显示实时活动';

  @override
  String get liveSettingsSubtitle => '干活、等你处理、操作手机时，显示在状态栏胶囊和锁屏上；支持的手机会放进灵动岛';

  @override
  String get liveSettingsFooter =>
      'Android 16 的实时活动（Live Updates）：小米 HyperOS 3.1+、OPPO / 一加 ColorOS 16、荣耀 MagicOS 10 和 Pixel 会显示；vivo 原子岛和三星 Now Bar 目前只对厂商合作的应用开放。';

  @override
  String get liveUnsupported => '这台手机的系统还不支持实时活动';

  @override
  String get liveBlockedTitle => '系统没有允许实时活动';

  @override
  String get liveBlockedText => '在系统设置里为 DSH Go 打开「实时活动」（有的手机叫「在流体云中显示」）';

  @override
  String get liveStop => '停止';

  @override
  String get liveStale => '暂停更新 · 打开 App 查看';

  @override
  String get liveIosSubtitle => '干活、等你处理时，在灵动岛和锁屏上显示宠物、进度和用时';

  @override
  String get liveIosFooter =>
      '需要 iOS 16.2 及以上。有灵动岛的 iPhone 显示在岛上，其他机型只在锁屏上。锁屏上不显示对话标题。iOS 17 起可以在卡片上直接停止这一轮。App 被系统挂起后，卡片会标出「暂停更新」。';

  @override
  String get liveIosUnsupported => '需要 iOS 16.2 或更高版本';

  @override
  String get liveIosBlockedText => '在「设置」→「DSH Go」里打开「实时活动」';

  @override
  String get localeTitle => '语言';

  @override
  String get localeSystem => '跟随系统';

  @override
  String get localeZh => '简体中文';

  @override
  String get localeEn => 'English';

  @override
  String get localEnvChooseTitle => 'DSH 在哪里运行？';

  @override
  String get localEnvChooseMessage => '之后可以在设置里更改';

  @override
  String localEnvThisPhoneDetail(int storage, int memory) {
    return '存储约 $storage MB · 内存约 $memory MB';
  }

  @override
  String localEnvThisPhoneDetailShort(int memory) {
    return '内存约 $memory MB';
  }

  @override
  String localEnvLowStorage(int needed) {
    return '存储空间不足，需要约 $needed MB';
  }

  @override
  String get localEnvRemoteDetail => '连接电脑或服务器上的 DSH';

  @override
  String get localEnvUnavailable => '这台设备暂时不能在本机运行 DSH';

  @override
  String get localEnvUnsupported => '暂不支持';

  @override
  String get localEnvRecommended => '推荐';

  @override
  String get localEnvInstallTitle => '安装本机运行环境';

  @override
  String get localEnvInstallMessage => '在这台手机上运行 DSH';

  @override
  String localEnvFactStorage(int storage) {
    return '约 $storage MB 存储空间';
  }

  @override
  String localEnvFactMemory(int memory) {
    return '运行时约 $memory MB 内存';
  }

  @override
  String get localEnvUseRemote => '改用远程主机';

  @override
  String get localEnvNotInstalled => '本机未安装运行环境';

  @override
  String get localEnvUninstall => '卸载运行环境';

  @override
  String get localEnvUninstallHint => '释放存储空间';

  @override
  String get localEnvUninstallTitle => '卸载运行环境？';

  @override
  String get localEnvUninstallBody => '本机的对话、工作区、插件、设置、界面配置和技能会一并删除。';

  @override
  String get localEnvUninstallConfirm => '卸载';

  @override
  String get localEnvUninstallFailed => '没能卸载，再试一次';

  @override
  String get localEnvPhoneNeedsRuntime => '安装本机运行环境后可用';

  @override
  String get localEnvSignInNeedsRuntime => '需要本机运行环境';

  @override
  String get localEnvSignInInstallFirst => '安装后即可登录';

  @override
  String get engineStartReopensApp => '引擎每次打开 App 只能启动一次，再启动会重新打开 App。';

  @override
  String get engineReopenFailed => '引擎要重新打开 App 才能再启动，请手动重开一次。';

  @override
  String get engineCapShell => '命令行';

  @override
  String engineCapShellBuiltin(int count) {
    return '内置 $count 个命令';
  }

  @override
  String get engineCapShellSystem => '系统';

  @override
  String get engineCapNodeScripts => 'Node 脚本';

  @override
  String get engineCapMarket => '安装市场插件';

  @override
  String get engineCapBackground => '切到后台时';

  @override
  String get engineCapMayFreeze => '可能被系统暂停';

  @override
  String get engineCapKeepsRunning => '继续运行';

  @override
  String get engineCapYes => '可以';

  @override
  String get engineCapNone => '不可用';

  @override
  String get marketInstallRefused => '这个引擎不能安装市场插件';

  @override
  String get localEnvChooseUseTitle => '想怎么用 dsh-Go？';

  @override
  String get localEnvTavernTitle => '和角色聊天';

  @override
  String get localEnvTavernDetail => '接回 DeepSeek 的对话也在这里 · 不用安装';

  @override
  String get marketSectionOfficial => '官方';

  @override
  String get marketSectionAdapted => '适配 DSH Go';

  @override
  String get marketSectionAll => '全部';

  @override
  String get marketSectionLoading => '正在载入…';

  @override
  String get marketSectionFailed => '官方目录没打开';

  @override
  String get marketSectionEmpty => '暂无';

  @override
  String get marketTierOfficial => '官方';

  @override
  String get marketTierAdapted => '适配 DSH Go';

  @override
  String get marketRiskMedium => '中风险';

  @override
  String get marketRiskHigh => '高风险';

  @override
  String get marketFlagInstallScripts => '安装时运行脚本';

  @override
  String get marketFlagInstallScriptsBody => '安装时会自动运行包里的脚本（preinstall、install 或 postinstall）';

  @override
  String get marketFlagNativeCode => '含原生程序';

  @override
  String get marketFlagNativeCodeBody => '包里有编译好的原生程序（.node、binding.gyp 或二进制文件），没法直接阅读';

  @override
  String get marketFlagShell => '执行命令';

  @override
  String get marketFlagShellBody => '代码里会调用系统命令（child_process）';

  @override
  String get marketFlagNetwork => '联网';

  @override
  String get marketFlagNetworkBody => '代码里会发起网络请求（fetch、http、WebSocket）';

  @override
  String get marketFlagFilesystem => '写工作区外的文件';

  @override
  String get marketFlagFilesystemBody => '会写入工作区以外的路径';

  @override
  String get marketFlagObfuscated => '代码难以审阅';

  @override
  String get marketFlagObfuscatedBody => '有压缩或混淆过的大文件，看不出它做什么';

  @override
  String get marketFlagNotAdapted => '未适配 DSH Go';

  @override
  String get marketFlagNotAdaptedBody => '没有声明 DSH Go 原生协议，在 App 里没有原生界面';

  @override
  String get marketFlagOtherBody => '自动检查报告的其他特征';

  @override
  String get marketChecksTitle => '自动检查';

  @override
  String get marketChecksClean => '没有发现风险特征';

  @override
  String get marketChecksNote => '自动检查发现的特征，不代表插件有恶意';

  @override
  String marketCheckedOn(String date) {
    return '检查于 $date';
  }

  @override
  String marketScreenshot(int index) {
    return '截图 $index';
  }

  @override
  String marketRiskConfirmTitle(String name) {
    return '「$name」有风险特征';
  }

  @override
  String get marketRiskConfirmAction => '仍然安装';

  @override
  String get marketPinnedVersion => '锁定版本';

  @override
  String get marketRequiresApp => '需要 DSH Go';

  @override
  String marketNeedsApp(String version) {
    return '需要 DSH Go $version 或更高版本';
  }

  @override
  String get marketUpdateAvailable => '有更新';

  @override
  String get marketBlockedTitle => '这个版本已下架';

  @override
  String marketBlockedMessage(String version) {
    return '已安装的 $version 已从插件市场下架，建议卸载';
  }

  @override
  String get marketBlockedRow => '此版本已下架，建议卸载';

  @override
  String get marketBlockedBadge => '已下架';

  @override
  String get marketVerifying => '正在核对版本…';

  @override
  String get marketMismatchTitle => '版本校验不一致';

  @override
  String marketMismatchMessage(String version) {
    return 'npm 上的 $version 和插件市场检查过的不是同一个包，已停止安装';
  }

  @override
  String get marketSubmit => '提交插件';

  @override
  String get marketSubmitHint => '在 GitHub 提交，通过自动检查即上架';

  @override
  String marketLinkNotFound(String name) {
    return '插件市场里没有 $name';
  }

  @override
  String get marketVerificationUnavailableTitle => '暂时无法核对版本';

  @override
  String get marketVerificationUnavailableBody => '没能取得 npm 的版本校验信息，尚未开始安装。请检查网络后重试。';

  @override
  String marketCombinedCount(int count) {
    return '$count 个插件';
  }

  @override
  String get mediaGenerateTile => '生成';

  @override
  String get mediaAiGenerated => 'AI 生成';

  @override
  String mediaCostEstimate(String amount) {
    return '约 $amount';
  }

  @override
  String mediaSavedCount(int count) {
    return '已保存 $count 张到相册';
  }

  @override
  String get mediaRegenerate => '重新生成';

  @override
  String get mediaCopyPrompt => '复制提示词';

  @override
  String get mediaFileGone => '文件已不在';

  @override
  String get mediaKindImage => '图像';

  @override
  String get mediaKindVideo => '视频';

  @override
  String get mediaTitleImage => '生成图像';

  @override
  String get mediaTitleVideo => '生成视频';

  @override
  String get mediaOpenElsewhere => '在其他应用中打开';

  @override
  String get mediaShowInFiles => '在文件中显示';

  @override
  String get mediaGenerating => '生成中';

  @override
  String mediaGeneratingProgress(String progress) {
    return '生成中 · $progress';
  }

  @override
  String get mediaCancelled => '已取消';

  @override
  String get mediaNotGenerated => '未生成';

  @override
  String mediaPartial(int done, int total) {
    return '$done / $total 张';
  }

  @override
  String mediaCount(int count) {
    return '$count 张';
  }

  @override
  String mediaSeconds(int seconds) {
    return '$seconds 秒';
  }

  @override
  String mediaImageOf(int index, int count) {
    return '第 $index 张，共 $count 张';
  }

  @override
  String mediaPageOf(int index, int count) {
    return '$index / $count';
  }

  @override
  String get mediaErrorPolicyInput => '描述未通过内容审核';

  @override
  String get mediaErrorPolicyOutput => '生成结果未通过内容审核';

  @override
  String get mediaErrorAuth => '服务未授权';

  @override
  String get mediaErrorBalance => '余额不足';

  @override
  String get mediaErrorQuota => '今天的额度已用完';

  @override
  String get mediaErrorUnavailable => '服务暂时不可用';

  @override
  String get mediaErrorExpired => '结果已过期';

  @override
  String get mediaErrorGeneric => '没能生成';

  @override
  String get mediaVary => '变体';

  @override
  String get mediaEdit => '编辑';

  @override
  String get mediaRevise => '修改';

  @override
  String get mediaUpscale => '放大';

  @override
  String get mediaMakeVideo => '做成视频';

  @override
  String get mediaDetailModel => '模型';

  @override
  String get mediaDetailSize => '尺寸';

  @override
  String get mediaDetailCost => '费用';

  @override
  String get mediaDetailProvenance => '来源标识';

  @override
  String get mediaDetailFile => '文件';

  @override
  String mediaOriginalPrompt(String text) {
    return '原文：$text';
  }

  @override
  String get mediaProvenanceC2pa => 'C2PA';

  @override
  String get mediaProvenanceImplicit => '隐式';

  @override
  String get mediaProvenanceVisible => '可见水印';

  @override
  String get mediaModeExit => '退出生成';

  @override
  String mediaModeLabel(String summary) {
    return '生成参数：$summary';
  }

  @override
  String get mediaParamModel => '模型';

  @override
  String get mediaParamAspect => '比例';

  @override
  String get mediaParamCount => '数量';

  @override
  String get mediaParamQuality => '清晰度';

  @override
  String get mediaParamDuration => '时长';

  @override
  String get mediaQualityAuto => '自动';

  @override
  String get mediaQualityStandard => '标准';

  @override
  String get mediaQualityHigh => '高清';

  @override
  String get mediaQuality4k => '4K';

  @override
  String get mediaQualityLevelLow => '低';

  @override
  String get mediaQualityLevelMedium => '中';

  @override
  String get mediaQualityLevelHigh => '高';

  @override
  String get mediaModelPick => '请选择';

  @override
  String get mediaPickModelFirst => '先选一个模型';

  @override
  String mediaPricePerImage(String price) {
    return '$price / 张';
  }

  @override
  String mediaPricePerSecond(String price) {
    return '$price / 秒';
  }

  @override
  String get mediaManageModels => '管理';

  @override
  String get mediaHintImage => '描述你想要的画面…';

  @override
  String get mediaHintVideo => '描述画面和镜头…';

  @override
  String get mediaHintEdit => '想怎么改…';

  @override
  String get mediaFirstFrame => '首帧';

  @override
  String get mediaLastFrame => '尾帧';

  @override
  String get mediaNoLastFrame => '这个模型不支持尾帧';

  @override
  String get mediaNoRefs => '这个模型不支持参考图';

  @override
  String mediaRefLimit(int count) {
    return '最多 $count 张参考图';
  }

  @override
  String get mediaNoDescription => '先写下想要的画面';

  @override
  String get mediaDescriptionTooLong => '描述太长，删短一些再生成';

  @override
  String get mediaInstallTitle => '图像与视频';

  @override
  String get mediaInstallBody => '这台主机还没有图像与视频插件';

  @override
  String get mediaInstallAction => '在此主机上安装';

  @override
  String get mediaUnavailableTitle => '生成模式不可用';

  @override
  String get mediaUnavailableBody => '这台主机的图像与视频插件版本不兼容。仍可直接在对话里描述想要的画面。';

  @override
  String get mediaUnavailableAction => '管理插件';

  @override
  String get mediaSettingsTitle => '图像与视频';

  @override
  String get searchKwMediaGeneration => '生图,画图,文生图,视频生成,AI 绘画,生成图片,生成视频';

  @override
  String get mediaSettingsDefaults => '默认';

  @override
  String get mediaSettingsLegacyDefault => '旧版通用默认';

  @override
  String get mediaSettingsLegacyDefaultHint => '0.2.x 的设置；图片和视频没有单独默认时使用';

  @override
  String get mediaSettingsLegacyDefaultStale => '指向的服务已不可用；清除它可避免生成时报错';

  @override
  String get mediaSettingsLegacyDefaultClear => '清除旧版通用默认';

  @override
  String get mediaSettingsDefaultModel => '默认模型';

  @override
  String get mediaSettingsDefaultFooterLegacy => '旧版插件只有一个默认模型；更新插件后可以分别设置图片和视频。';

  @override
  String get mediaSettingsDefaultsFooter => '图片和视频分别选择默认模型；留空自动使用第一个可用的。';

  @override
  String get mediaSettingsNoVideoModels => '这台主机的目录里还没有视频模型';

  @override
  String get mediaSettingsServices => '服务';

  @override
  String get mediaSettingsAddService => '添加服务';

  @override
  String get mediaSettingsAddServiceHint => '从服务商预设开始，地址、协议和模型都会自动带好';

  @override
  String mediaSettingsServiceLimit(int count) {
    return '最多 $count 个服务';
  }

  @override
  String get mediaSettingsNoServices => '还没有服务。添加一个服务商就能开始生成图片或视频。';

  @override
  String get mediaSettingsNoModels => '未选模型';

  @override
  String get mediaSettingsKeyMissing => '未配置 API Key';

  @override
  String get mediaSettingsCatalogMissing => '这个主机的插件没有提供模型目录；已有服务仍可编辑，但暂时不能新增服务或选择默认模型。';

  @override
  String get mediaSettingsCatalogBroken => '模型目录读不了（可能版本不兼容）；已有服务仍可编辑，但暂时不能新增服务或选择默认模型。';

  @override
  String get mediaSettingsCatalogEmpty => '模型目录里还没有模型；已有服务仍可编辑，但暂时不能新增服务或选择默认模型。';

  @override
  String get mediaSettingsNoPresets => '目录里还没有可添加的服务。';

  @override
  String get mediaSettingsLimits => '请求上限';

  @override
  String get mediaSettingsLimitsHint => '限制单次请求的图片张数和字节数；默认是插件硬上限';

  @override
  String get mediaSettingsMaxImages => '单次图片张数';

  @override
  String get mediaSettingsMaxImageBytes => '单张原件字节上限';

  @override
  String get mediaSettingsMaxResponseBytes => '服务响应字节上限';

  @override
  String get mediaSettingsMaxTotalImageBytes => '单次图片总字节上限';

  @override
  String get mediaSettingsMaxVideoBytes => '视频原件字节上限';

  @override
  String get mediaSettingsBudget => '费用保护';

  @override
  String get mediaSettingsDailyBudget => '每日预算（元）';

  @override
  String get mediaSettingsDailyBudgetHint => '按上海日期重置；用完即暂停生成';

  @override
  String get mediaSettingsUnknownPriceHold => '无可靠价格时每次预留（元）';

  @override
  String get mediaSettingsUnknownPriceHoldHint => '逐次确认的预留金额，不是供应商的收费上限';

  @override
  String get mediaSettingsApiKey => 'API Key';

  @override
  String get mediaSettingsReuseKey => '复用密钥';

  @override
  String get mediaSettingsReuseKeyHint => '同一服务商的图片和视频共用一个 API Key，不用再填一次。';

  @override
  String get mediaSettingsReuseKeyNone => '同一服务商还没有其它服务。';

  @override
  String get mediaSettingsReuseKeyShared => '已复用';

  @override
  String get mediaSettingsModels => '模型';

  @override
  String get mediaSettingsModelsEmpty => '目录里没有这个协议的模型';

  @override
  String get mediaSettingsModelKeepOne => '至少保留一个模型';

  @override
  String get mediaSettingsModelMissing => '目录中不存在';

  @override
  String get mediaSettingsAdvanced => '高级';

  @override
  String get mediaSettingsBaseUrl => 'API 根地址';

  @override
  String get mediaSettingsBaseUrlInvalid => '地址要以 https:// 开头';

  @override
  String get mediaSettingsProvider => '服务商标识';

  @override
  String get mediaSettingsKeyRef => '凭据名';

  @override
  String get mediaSettingsKeyRefInvalid => '凭据名只能包含字母、数字和下划线';

  @override
  String get mediaSettingsResponseFormat => '返回格式';

  @override
  String get mediaSettingsResponseFormatAuto => '按协议';

  @override
  String get mediaSettingsServiceId => '服务 ID';

  @override
  String get mediaSettingsServiceGone => '这个服务已经不在了';

  @override
  String get mediaSettingsServiceGoneBody => '它可能已在别处被删掉。返回上一页可以重新添加。';

  @override
  String get mediaSettingsDelete => '删除服务';

  @override
  String mediaSettingsDeleteTitle(String name) {
    return '删除「$name」？';
  }

  @override
  String get mediaSettingsDeleteBody => '只会从这台主机的设置里删掉这个服务，API Key 会保留；指向它的默认模型会一并清空。';

  @override
  String get mediaSettingsNoImageModels => '目录里还没有图像模型';

  @override
  String get mediaSettingsNoAvailableService => '还没有可用的服务（先添加并填好 Key）';

  @override
  String get mediaSettingsNoImageService => '还没有可用的图像服务（先添加并填好 Key）';

  @override
  String get mediaSettingsNoVideoService => '还没有可用的视频服务（先添加并填好 Key）';

  @override
  String get mediaSettingsKeyExternal => '由其它设置管理，这里只引用';

  @override
  String get mediaSettingsEnabledHint => '关闭后不再用这个服务生成';

  @override
  String get mediaConfigKeySaved => '已保存 · 未验证';

  @override
  String get mediaConfigKeyUnknown => '状态未知';

  @override
  String get mediaConfigKeyNote => '密钥是否存在以主机返回为准。保存不代表已验证身份或模型权限。';

  @override
  String mediaConfigConsumers(String services) {
    return '使用此密钥的媒体服务：$services。修改或移除会影响这些服务；主机上的其他集成也可能使用它。';
  }

  @override
  String get mediaConfigCheck => '检查已保存配置';

  @override
  String get mediaConfigCheckNote => '仅检查本地配置快照，不请求供应商，不产生生成费用。不验证密钥、连通性、余额、模型权限或地区；配置是否接受仍以主机为准。';

  @override
  String get mediaConfigCheckReady => '未发现本地配置问题';

  @override
  String get mediaConfigCheckMissingKey => '主机尚未报告已保存的密钥。';

  @override
  String get mediaConfigCheckModels => '未选择模型，或部分已选模型不在目录中、协议不匹配。';

  @override
  String get mediaConfigCheckDisabled => '此服务已关闭。';

  @override
  String get mediaConfigUrlInvalid => '请输入含主机名的 HTTPS API 根地址，不得包含凭据、查询参数、片段或空白。';

  @override
  String get mediaConfigUrlEndpoint => '这看起来是请求端点。请填写 API 根地址，主机会自动追加请求路径。';

  @override
  String get mediaConfigUrlRoot => '此协议只需来源地址（https://主机名），不要填写 API 路径。';

  @override
  String get mediaConfigUrlHint => '填写 API 根地址，而非生成端点。OpenAI 兼容服务保留其路径前缀（如 /v1）。';

  @override
  String get mediaConfigPreview => '创建请求预览';

  @override
  String get mediaConfigPreviewNote => '仅预览生成/创建请求；编辑和查询状态可能使用不同路径。预览不代表连通或已获主机接受。';

  @override
  String get mediaConfigPreviewUnavailable => '此主机目录未提供请求路径。';

  @override
  String get mediaConfigTargetTitle => '将密钥用于不同目标？';

  @override
  String mediaConfigTargetBody(String before, String after) {
    return '目标将从 $before 更改为 $after。后续请求可能向新目标发送所引用的密钥，仅在信任该目标时继续。主机仍会校验此更改。';
  }

  @override
  String get mediaConfigTargetConfirm => '信任目标并继续';

  @override
  String get mediaVideoLoading => '正在加载视频…';

  @override
  String get mediaVideoCannotPlay => '无法在 App 内播放此视频，请重试或使用其他应用打开。';

  @override
  String get mediaVideoUnsupported => '此版本暂不支持在 App 内播放视频，可保存到相册或在其他应用中打开。';

  @override
  String get mediaVideoPlay => '播放';

  @override
  String get mediaVideoPause => '暂停';

  @override
  String get mediaVideoSaveFailed => '视频保存失败，请重试。';

  @override
  String get mediaImageLoading => '正在加载图片';

  @override
  String get mediaImageReload => '重新加载';

  @override
  String get mediaImageReloadHint => '只重新读取文件，不会重新生成或收费';

  @override
  String get mediaVideoNoPoster => '轻点播放视频';

  @override
  String mediaSavedFilesCount(int count) {
    return '已保存 $count 个文件到相册';
  }

  @override
  String get modeSheetTitle => '模式';

  @override
  String get modeKeyTooltip => '切换模式';

  @override
  String get modeWork => '工作';

  @override
  String get modeWorkSubtitle => '和 DSH 一起干活';

  @override
  String get modeCompanionShort => '伙伴';

  @override
  String get modeTavernSubtitle => '导入角色卡，开始一段故事';

  @override
  String get modeStartup => '启动时进入';

  @override
  String get nearbyThisChat => '本对话';

  @override
  String get nearbyPermissionTitle => '本对话的权限';

  @override
  String nearbyNewChatDefault(String name) {
    return '新对话默认：$name';
  }

  @override
  String get nearbySetAsDefault => '设为新对话默认';

  @override
  String get nearbyManageModels => '管理模型';

  @override
  String nearbyPermissionPill(String name) {
    return '本对话的权限：$name';
  }

  @override
  String get nearbyChange => '更换';

  @override
  String get performanceTitle => '性能';

  @override
  String get performanceAuto => '自动';

  @override
  String get performanceFull => '完整';

  @override
  String get performanceLight => '轻量';

  @override
  String get performanceAutoHint => '按设备调整默认效果';

  @override
  String get performanceFullHint => '保留模糊与动效';

  @override
  String get performanceLightHint => '减少常驻效果和资源占用';

  @override
  String get performanceChoiceHint => '手动选择的宠物和引擎设置优先';

  @override
  String get performanceCooling => '正在减少效果，降温后恢复';

  @override
  String get performanceEffects => '界面效果';

  @override
  String get performanceBlur => '玻璃模糊';

  @override
  String get performanceAnimations => '界面动效';

  @override
  String get performanceSystemMotion => '同时遵循系统的移除动画设置';

  @override
  String get performanceFluid => '灵动动效';

  @override
  String get performanceFluidHint => '弹性回弹、按压光晕、卡片展开成页面。几乎不增加耗电';

  @override
  String get performanceFollowMode => '效果跟随性能模式';

  @override
  String get performanceRemoteHint => '推荐连接电脑或服务器，减少本机负担';

  @override
  String get performanceRefresh => '刷新率';

  @override
  String get performanceRefreshMax => '最高';

  @override
  String get performanceRefreshSystem => '系统';

  @override
  String get performanceRefreshHint => '自动：动时用最高刷新率，停下交回系统；系统：完全由系统决定。';

  @override
  String get performanceRefreshHintOhos => '自动：动画和滚动时用最高刷新率，停下交回系统；最高：一直最高，更耗电也更热；系统：不额外要求。';

  @override
  String get performanceFrameCache => '帧缓存';

  @override
  String get performanceFrameCacheHint => '更顺滑，触摸响应略慢一点';

  @override
  String get searchKwRefreshRate => '刷新率 高刷 120Hz 90Hz 流畅';

  @override
  String get petActionSending => '正在发送…';

  @override
  String get petActionTargetChanged => '主机已变化，重新打开「问一句」；文字已保留';

  @override
  String get petActionSendFailed => '没能发出，文字已保留，请重试';

  @override
  String get petActionBusy => '这个对话正在忙，请选择「新对话」';

  @override
  String get petActionVoiceMissing => '先到 App 下载离线语音模型';

  @override
  String get petActionVoiceTitle => '语音问一句';

  @override
  String get petActionVoiceReturn => '返回桌宠';

  @override
  String get petActionVoiceStop => '结束录音';

  @override
  String get petActionVoiceStart => '开始录音';

  @override
  String get phoneDiagnosticsCollecting => '正在收集…';

  @override
  String get phoneDiagnosticsPacking => '正在打包…';

  @override
  String get phoneDiagnosticsSharing => '正在打开分享…';

  @override
  String get phoneDiagnosticsSaving => '正在存到「下载」…';

  @override
  String get phoneDiagnosticsShare => '分享诊断包';

  @override
  String get phoneDiagnosticsShareHint => '附在问题反馈里';

  @override
  String get phoneDiagnosticsSave => '存到「下载」';

  @override
  String get phoneDiagnosticsSaveHint => '存进 下载/DSH-Go';

  @override
  String get phoneDiagnosticsNote => '含版本、设备、日志和最近一次崩溃，不含 Key 和令牌';

  @override
  String get phoneDiagnosticsExport => '导出诊断包';

  @override
  String get phoneSafeMode => '安全模式';

  @override
  String get phoneEngineStartingSafeEllipsis => '正在以安全模式启动…';

  @override
  String get phoneEngineStartingEllipsis => '正在启动…';

  @override
  String get phoneEngineTidyingFilesEllipsis => '正在整理插件文件…';

  @override
  String get phoneEngineStoppingEllipsis => '正在停止…';

  @override
  String get phoneEngineStoppedNextSafe => '已停止 · 下次以安全模式启动';

  @override
  String get phoneEngineInstallingRuntime => '正在安装运行环境…';

  @override
  String get phoneEngineRuntimeNotInstalled => '运行环境未安装';

  @override
  String get phoneEngineErrorSeeLogs => '引擎出错了，日志里有详情';

  @override
  String get phoneEngineTitle => '本机引擎';

  @override
  String get phoneEngineLocal => '本机引擎';

  @override
  String get phoneEngineLogs => '日志';

  @override
  String get phoneEngineAutoStart => '打开 App 时自动启动';

  @override
  String get phoneEngineKeepAlive => '后台运行';

  @override
  String get phoneEngineKeepAliveHint => '防止引擎被系统结束';

  @override
  String get phoneEngineDiagnostics => '诊断';

  @override
  String get phoneEngineDiagnosticsHint => '运行信息与问题反馈';

  @override
  String get phoneEngineRuntime => '运行环境';

  @override
  String get phoneEngineArchitecture => '架构';

  @override
  String get phoneEngineStopTitle => '停止引擎？';

  @override
  String get phoneEngineStopBody => '进行中的对话会中断，随时可以再启动。';

  @override
  String get phoneEngineInstallRuntime => '安装运行环境';

  @override
  String get phoneEngineStartAgain => '重新启动';

  @override
  String get phoneEngineStart => '启动';

  @override
  String get phoneEngineRestart => '重启';

  @override
  String get phoneEngineResetFailed => '没能重置';

  @override
  String get phoneEngineReset => '重置运行环境';

  @override
  String get phoneEngineResetHint => '删除对话和文件后重新解压';

  @override
  String get phoneEngineResetTitle => '重置运行环境？';

  @override
  String get phoneResetAlsoDeletes => '家目录（/root）里没有保留的内容也会一起删除，包括工作区里的文件、AGENTS.md，以及插件自己存的数据（比如记忆）。';

  @override
  String get phoneEngineKeepUiSkills => '保留界面配置和技能';

  @override
  String get phoneEngineKeepPluginsSettings => '保留已装插件和设置';

  @override
  String get phoneEngineDeleteReset => '删除并重置';

  @override
  String get phoneEngineNotInstalled => '未安装';

  @override
  String get phoneEngineInstalling => '正在安装';

  @override
  String get phoneEngineStoppedSafe => '已停止 · 安全模式';

  @override
  String get phoneEngineStartingSafe => '正在以安全模式启动';

  @override
  String get phoneEngineStarting => '正在启动';

  @override
  String get phoneEngineTidyingFiles => '正在整理插件文件';

  @override
  String get phoneEngineRunningProbation => '运行中 · 试用';

  @override
  String get phoneEngineStartupFailed => '启动失败';

  @override
  String get phoneEngineCrashed => '已崩溃';

  @override
  String get phoneEngineKilled => '被系统结束';

  @override
  String get phoneEngineError => '出错了';

  @override
  String get phoneEngineRuntimeCorrupt => 'App 内的运行环境包已损坏，请重新安装 App';

  @override
  String get phoneEngineExited => '引擎意外退出了';

  @override
  String get phoneEngineRuntimeMissing => '运行环境还没有安装';

  @override
  String get phoneEngineSafeUnsupported => '这个版本的运行环境不支持安全模式，请更新 App';

  @override
  String get phoneEngineRuntimeIncomplete => 'App 内的运行环境包不完整，请重新安装 App';

  @override
  String get phoneLogEmpty => '还没有日志';

  @override
  String get phoneLogShareTitle => 'DSH 引擎日志';

  @override
  String get phoneLogCopyAll => '复制全部';

  @override
  String get phoneBackgroundAllow => '去放行';

  @override
  String get phoneToolScreen => '看屏幕';

  @override
  String get phoneToolCollect => '滚动收集';

  @override
  String get phoneToolTap => '点按';

  @override
  String get phoneToolType => '输入';

  @override
  String get phoneToolScroll => '滑动';

  @override
  String get phoneToolKey => '按键';

  @override
  String get phoneToolTapCoordinates => '点坐标';

  @override
  String get phoneToolHandoff => '交还给你';

  @override
  String get phoneToolOpenApp => '打开 App';

  @override
  String get phoneToolListApps => '查看应用';

  @override
  String get phoneToolIntent => '系统动作';

  @override
  String get phoneToolNotify => '发通知';

  @override
  String get phoneToolClipboard => '剪贴板';

  @override
  String get phoneToolAction => '操作';

  @override
  String get phoneDecisionContinued => '你点了继续';

  @override
  String get phoneDecisionDone => '已执行';

  @override
  String get phoneDecisionAllowed => '你允许了';

  @override
  String get phoneDecisionPauseExpired => '暂停太久';

  @override
  String get phoneDecisionBlocked => '已拦下';

  @override
  String get phoneDecisionTimeout => '超时';

  @override
  String get phoneDecisionUnavailable => '不可用';

  @override
  String get phoneDecisionScreenChanged => '屏幕变了';

  @override
  String get phoneDecisionFailed => '没成功';

  @override
  String get phoneActionLogTitle => '操作记录';

  @override
  String get phoneActionLogSubtitle => '只记做了什么，不记屏幕内容';

  @override
  String get phoneActionLogRefresh => '刷新';

  @override
  String get phoneActionLogEmpty => '还没有记录';

  @override
  String get phoneActionLogEmptyHint => 'DSH 在手机上的每一步都会记在这里';

  @override
  String get phoneAppRuleDeny => '不碰';

  @override
  String get phoneAppRuleConfirm => '每一步都确认';

  @override
  String get phoneAppRuleNormal => '照常';

  @override
  String get phoneAppRuleDenyHint => '不读也不点，银行、支付类默认如此';

  @override
  String get phoneAppRuleConfirmHint => '可以读，点按和输入前先问你';

  @override
  String get phoneAppRuleNormalHint => '只有发送这类敏感操作先问你';

  @override
  String get phoneAppRulesTitle => '应用名单';

  @override
  String get phoneAppRulesSubtitle => '没列出的 App 照常处理，敏感操作仍先问你';

  @override
  String get phoneAppRulesUnavailable => '读不到应用名单';

  @override
  String get phoneTryLater => '稍后再试';

  @override
  String get phoneAppRulesChanged => '照常 · 你改过的';

  @override
  String get phoneAppRulesAdd => '添加 App';

  @override
  String get phoneAppRulesAddHint => '按包名添加';

  @override
  String get phoneSensitiveActionsNote => '密码、验证码、付款和系统设置都由你来';

  @override
  String get phoneAppRulesSaveFailed => '没有保存成功，稍后再试';

  @override
  String get phoneAppRulesAcceptRisk => '我知道风险，仍然修改';

  @override
  String get phoneAppRulesPackage => '包名';

  @override
  String get phoneAppRulesPackageHint => '在「设置 → 应用 → 应用信息」里能找到';

  @override
  String get phoneAlwaysAllowTitle => '始终允许';

  @override
  String get phoneAlwaysAllowOff => '未开启';

  @override
  String phoneAlwaysAllowCount(int count) {
    return '已允许 $count 个应用';
  }

  @override
  String get phoneAlwaysAllowSwitchHint => '不再询问就把内容发到你选的应用';

  @override
  String get phoneAlwaysAllowWarning => '开启后 DSH 可不再询问就把内容发到这些应用，发出后无法撤回。';

  @override
  String get phoneAlwaysAllowConfirm => '确认开启';

  @override
  String get phoneAlwaysAllowAdd => '添加应用';

  @override
  String get phoneAlwaysAllowEmpty => '还没有允许的应用';

  @override
  String get phoneAlwaysAllowRemove => '移除';

  @override
  String get phoneAlwaysAllowSaveFailed => '保存失败';

  @override
  String get phoneDndRequiresAndroid => '需要 Android 14 及以上';

  @override
  String get phoneDndHiddenScreen => '在看不见的屏幕上操作';

  @override
  String get phoneNotReadyYet => '还没准备好';

  @override
  String get phoneActionFailedLater => '没有成功，稍后再试';

  @override
  String get phoneDndDisabled => '不打扰模式已关闭';

  @override
  String get phoneDndEnabled => '不打扰模式已启用';

  @override
  String get phoneDndShizukuPermissionFailed => '没有拿到授权。可以在 Shizuku 的「应用管理」里给 DSH Go 授权';

  @override
  String get phoneDndPairedConnect => '配对成功，点「连接」';

  @override
  String get phoneDndTitle => '不打扰模式';

  @override
  String get phoneDndSubtitle => '在看不见的屏幕上操作，不耽误你用手机';

  @override
  String get phoneDndUnsupported => '这台手机用不了：需要 Android 14 及以上。';

  @override
  String get phoneDndRequirements => '使用条件';

  @override
  String get phoneDndKeepUnlocked => '保持亮屏、解锁。';

  @override
  String get phoneDndReactivate => '重启手机后重新激活。';

  @override
  String get phoneDndKeepDebugging => '用 Shizuku 或自连 ADB 时，连接 Wi‑Fi 并保持无线调试开启。';

  @override
  String get phoneReady => '可以用了';

  @override
  String get phoneDndDirectAdb => '自连 ADB';

  @override
  String get phoneDndChannels => '连接方式';

  @override
  String get phoneDndShizukuFor => '装了 Shizuku App 的手机';

  @override
  String get phoneDndSuiFor => 'Magisk 或 KernelSU 装了 Sui 模块';

  @override
  String get phoneDndRootFor => '已 root 的手机';

  @override
  String get phoneDndAdbFor => '不装别的 App，用无线调试';

  @override
  String get phoneDndStateInUse => '使用中';

  @override
  String get phoneDndStateNotReady => '未就绪';

  @override
  String get phoneDndStateUsable => '可以用';

  @override
  String get phoneDndStateNeedsGrant => '待授权';

  @override
  String get phoneDndStateNotRunning => '未运行';

  @override
  String get phoneDndStateNotInstalled => '未安装';

  @override
  String get phoneDndStateNotFound => '未检测到';

  @override
  String get phoneDndStateViaSui => '由 Sui 提供';

  @override
  String get phoneDndStateWaiting => '等待授权';

  @override
  String get phoneDndStateDisconnected => '未连接';

  @override
  String get phoneDndStateNotPaired => '未配对';

  @override
  String get phoneDndShizukuViaSui => '这台手机的 Shizuku 接口由 Sui 提供，请改用 Sui。';

  @override
  String get phoneDndSuiMissing => '没有检测到 Sui。在 Magisk 或 KernelSU 里装好 Sui 模块并重启手机，再回到这里。';

  @override
  String get phoneDndSuiRunning => 'Sui 接口可用';

  @override
  String get phoneDndSuiStopped => 'Sui 接口当前不可用。确认 Sui 模块已启用，重启手机后再试。';

  @override
  String get phoneDndSuiAllSet => 'Sui 已启动并授权，接下来连接后台屏。';

  @override
  String get phoneDndSuiPermissionFailed => '没能请求 Sui 授权。确认 Sui 模块已启用后再试。';

  @override
  String get phoneDndRootWaiting => '正在等待 root 授权，请在 root 管理器的弹窗里选择。';

  @override
  String get phoneDndRootConnected => 'root 已连接。断开后要回到这里再选一次；打开「更多设置」中的「保持 root 通道」，DSH Go 才会自己再去申请。';

  @override
  String get phoneDndRootConnectedKept => 'root 已连接。断开后 DSH Go 会自己向 root 管理器再次申请。';

  @override
  String get phoneDndRootRetry => '重新申请 root 授权';

  @override
  String get phoneDndInstallShizuku => '先安装 Shizuku（免费、开源）。';

  @override
  String get phoneDndOpenShizukuSite => '打开 Shizuku 官网';

  @override
  String get phoneDndStartShizuku => '打开 Shizuku，按里面「通过无线调试启动」的说明做一遍（要连 Wi‑Fi）。回到这里会自动刷新。';

  @override
  String get phoneDndGrantShizukuHint => 'Shizuku 已在运行，还要给 DSH Go 授权。';

  @override
  String get phoneDndGrantShizuku => '授权给 DSH Go';

  @override
  String get phoneDndShizukuAllSet => 'Shizuku 已启动并授权，接下来连接后台屏。';

  @override
  String get phoneDndShizukuInstalled => '已安装 Shizuku';

  @override
  String get phoneDndShizukuRunning => 'Shizuku 正在运行';

  @override
  String get phoneDndShizukuGranted => '已授权给 DSH Go';

  @override
  String get phoneDndShizukuCompatibility => '这版 Android 与官方版 Shizuku 存在兼容问题。';

  @override
  String get phoneDndWirelessDebuggingOn => '无线调试已打开';

  @override
  String get phoneDndPaired => '已配对';

  @override
  String get phoneDndConnected => '已连接';

  @override
  String get phoneDndDeveloperOptionsStep => '打开开发者选项：在「关于手机」里连点「版本号」7 次。小米在「我的设备 → 全部参数与信息」里点「OS 版本」，vivo 点「软件版本号」。';

  @override
  String get phoneDndWirelessDebuggingStep => '在开发者选项里打开「无线调试」，要连着 Wi‑Fi。开发者选项一般在「系统」或「其他设置」里。';

  @override
  String get phoneDndStartPairingStep => '回到这里点「开始配对」，DSH 会发一条通知。';

  @override
  String get phoneDndGetPairingCodeStep => '在「无线调试」里点「使用配对码配对设备」，屏幕上会出现 6 位配对码。';

  @override
  String get phoneDndEnterPairingCodeStep => '下拉通知栏，把配对码填进 DSH 的通知。配对成功后点「连接」。';

  @override
  String get phoneDndStartPairing => '开始配对';

  @override
  String get phoneDndPairingNotificationSent => '通知已发出，去「无线调试」里拿配对码';

  @override
  String get phoneDndManualEntry => '手动填写';

  @override
  String get phoneDndConnect => '连接';

  @override
  String get phoneDndManualEntryHint => '通知里没有输入框时，用「手动填写」';

  @override
  String get phoneDndXiaomiUsbHint => '打开「USB 调试（安全设置）」需插入 SIM 卡并登录小米账号。';

  @override
  String get phoneDndEnterCodeTitle => '填写配对码';

  @override
  String get phoneDndCodeLabel => '6 位配对码';

  @override
  String get phoneDndPortLabel => '端口（可不填）';

  @override
  String get phoneDndPortHint => '配对码下面「IP 地址和端口」冒号后的数字';

  @override
  String get phoneDndPair => '配对';

  @override
  String get phoneConfirmAsk => '每次都询问';

  @override
  String get phoneConfirmTask => '本任务免确认';

  @override
  String get phoneConfirmAlways => '始终免确认';

  @override
  String get phoneConfirmAskHint => '进新 App、发送、删除、付款前先问你';

  @override
  String get phoneConfirmTaskHint => '本轮只问一次';

  @override
  String get phoneConfirmAlwaysHint => '从不询问，直接操作';

  @override
  String get phoneConfirmTitle => '确认方式';

  @override
  String get phoneConfirmAlwaysTitle => '始终免确认？';

  @override
  String get phoneConfirmAlwaysBody => '打开 App、点按、发送、删除都直接做，不再问你。';

  @override
  String get phoneConfirmSaveFailed => '没改成，稍后再试';

  @override
  String get phoneEnableFailed => '没能开启，稍后再试';

  @override
  String get phoneDisableFailed => '没能关闭，稍后再试';

  @override
  String get phoneEnabled => '已开启';

  @override
  String get phoneDisabled => '已关闭';

  @override
  String get phoneOpenAccessibilityFailed => '打不开系统设置，请到「设置 → 无障碍」里找到 DSH';

  @override
  String get phoneOpenAppInfoFailed => '打不开应用信息，请到「设置 → 应用」里找到 DSH Go';

  @override
  String get phoneStopFailed => '没能停止，可以点悬浮条或通知上的「停止」';

  @override
  String get phoneControlTitle => '手机操控';

  @override
  String get phoneControlSubtitle => '看屏幕、帮你点按，随时可以停';

  @override
  String get phoneControlWorking => '正在操作手机';

  @override
  String get phoneControlTaskNoConfirmHint => '本任务免确认 · 悬浮条上也能暂停或停止';

  @override
  String get phoneControlFloatingBarHint => '悬浮条上也能暂停或停止';

  @override
  String get phoneControlAdvanced => '更多设置';

  @override
  String get phoneDndMoreChannels => '更多连接方式（Root / Sui）';

  @override
  String get phoneDndChangeChannel => '更换连接方式';

  @override
  String get phoneDndPairingHelp => '配对帮助 / 手动填写';

  @override
  String get phoneDndConnectHelp => '连接不上？';

  @override
  String get phoneDndPairNext => '先在系统开发者选项打开「无线调试」，再点「开始配对」，按通知填写配对码。';

  @override
  String get phoneControlKeepAliveHint => '防止系统关掉无障碍';

  @override
  String get phoneControlReadingEllipsis => '正在读取…';

  @override
  String get phoneControlNotReady => '未就绪';

  @override
  String get phoneControlNotEnabled => '未开启';

  @override
  String get phoneControlSafeModeNotLoaded => '安全模式下不加载';

  @override
  String get phoneControlLocalOnly => '只在本机引擎可用';

  @override
  String get phoneControlAfterEngineStarts => '引擎启动后生效';

  @override
  String get phoneControlNeedsAccessibility => '还差一步：打开无障碍';

  @override
  String get phoneControlReady => '可以操作手机';

  @override
  String get phoneControlSetup => '准备';

  @override
  String get phoneControlAccessibilityService => '无障碍服务';

  @override
  String get phoneControlAccessibilityReady => '能看屏幕、帮你点按了';

  @override
  String get phoneControlAccessibilityReconnect => '服务没连上，关掉再打开一次';

  @override
  String get phoneControlAccessibilityHint => '看屏幕和点按都靠它';

  @override
  String get phoneControlGoSettings => '去设置';

  @override
  String get phoneControlGoEnable => '去开启';

  @override
  String get phoneControlAccessibilityBlocked => '无障碍开关点不动？';

  @override
  String get phoneControlRestrictedAfterAttempt => '看起来没开成。侧载的 App 要先「允许受限制的设置」';

  @override
  String get phoneControlRestrictedHint => '侧载安装的 App 要先「允许受限制的设置」';

  @override
  String get phoneControlNotifications => '通知';

  @override
  String get phoneControlNotificationsPairingHint => '确认、停止和配对码都走通知';

  @override
  String get phoneControlNotificationsHint => '确认和「停止」按钮要用到';

  @override
  String get phoneControlAllowed => '已允许';

  @override
  String get phoneControlTry => '试一下';

  @override
  String get phoneControlReadScreen => '读一下当前屏幕';

  @override
  String get phoneControlReadScreenHint => '看看 DSH 读到了什么，不发给模型';

  @override
  String get phoneControlEnableAccessibilityFirst => '先打开无障碍服务';

  @override
  String get phoneControlLoading => '读取中';

  @override
  String get phoneControlRules => '规则';

  @override
  String get phoneControlRecentActions => '最近操作';

  @override
  String get phoneControlRecentActionsHint => '每一步都会记下，不含屏幕内容';

  @override
  String get phoneControlAllActions => '全部记录';

  @override
  String get phoneControlModuleNotReady => '这个版本里，手机操控模块还没有就绪';

  @override
  String get phoneControlSafeModeUnavailable => '安全模式下不可用';

  @override
  String get phoneControlSafeModeHint => '安全模式不加载插件，恢复正常模式后可用';

  @override
  String get phoneControlRemoteHost => '当前连的是远程主机';

  @override
  String get phoneControlCapabilities => '开启后能做什么';

  @override
  String get phoneControlIntents => '定闹钟、建日程、导航、分享';

  @override
  String get phoneControlNoExtraPermissions => '不用额外权限';

  @override
  String get phoneControlReadToTable => '读屏幕，整理成表格或待办';

  @override
  String get phoneControlNeedsAccessibilityHint => '需要打开无障碍';

  @override
  String get phoneControlTapType => '帮你点按、输入';

  @override
  String get phoneControlSensitiveHint => '发送、下单前先问你，付款由你来';

  @override
  String get phoneDisclosureWhatTitle => '读什么';

  @override
  String get phoneDisclosureWhatBody => '当前屏幕上的文字。用能看图的模型时，可能附一张截图。';

  @override
  String get phoneDisclosureWhenTitle => '什么时候读';

  @override
  String get phoneDisclosureWhenBody => '只在你发起任务，或点「读一下当前屏幕」时。平时不读。';

  @override
  String get phoneDisclosureWhoTitle => '发给谁';

  @override
  String get phoneDisclosureWhoBody => '发给你选的 DeepSeek 模型（云端）。银行卡号、身份证号会先打码。';

  @override
  String get phoneDisclosureNeverTitle => '默认不做';

  @override
  String get phoneDisclosureNeverBody => '不输密码和验证码，不改系统设置，遇到就交还给你。银行、支付类 App 也不碰。';

  @override
  String get phoneDisclosureStopTitle => '你随时能停';

  @override
  String get phoneDisclosureStopBody => '操作时屏幕上有悬浮条，可以暂停、停止或插话。手机要亮屏、解锁。';

  @override
  String get phoneDisclosureTitle => '开启手机操控前';

  @override
  String get phoneDisclosureIntro => 'DSH 会像你一样看屏幕、点按，帮你把事办完。开启前，先了解这几点：';

  @override
  String get phoneDisclosureRestartNote => '开启后引擎会重启一次，进行中的回复会中断';

  @override
  String get phoneDisclosureNotNow => '先不开';

  @override
  String get phoneDisclosureAgreeEnable => '同意并开启';

  @override
  String get phoneCheckUnknown => '不确定';

  @override
  String get phoneCheckYes => '是';

  @override
  String get phoneCheckNotYet => '还没有';

  @override
  String get phoneRomStock => '原生 / 其他';

  @override
  String get phoneRestrictedAccessibility => '无障碍';

  @override
  String get phoneRestrictedOpenAccessibility => '去开无障碍';

  @override
  String get phoneRestrictedOverlay => '悬浮窗';

  @override
  String get phoneRestrictedOpenOverlay => '去开悬浮窗';

  @override
  String get phoneRestrictedTryAccessibility => '先去「无障碍」里点一次 DSH 的开关，看到「受限制的设置」提示后点「确定」。做过这一步，下面的选项才会出现。';

  @override
  String get phoneRestrictedOpenInfoStep => '回到这里，点「打开应用信息」。';

  @override
  String get phoneRestrictedBackAccessibility => '回到「无障碍」，打开 DSH。';

  @override
  String get phoneRestrictedMenuStep => '点右上角的三个点，选「允许受限制的设置」，按提示验证锁屏密码。';

  @override
  String get phoneRestrictedTryOverlay => '先去「悬浮窗」设置里点一次 DSH Go 的开关，看到「受限制的设置」提示后点「确定」。做过这一步，下面的选项才会出现。';

  @override
  String get phoneRestrictedBackOverlay => '回到「悬浮窗」设置，打开 DSH Go。';

  @override
  String get phoneRestrictedHuaweiOverlay => '华为 HarmonyOS 4 及更早的系统大多没有这一步，直接去「悬浮窗」设置打开 DSH Go。';

  @override
  String get phoneRestrictedHuaweiAccessibility => '华为 HarmonyOS 4 及更早的系统大多没有这一步，直接去「无障碍」打开 DSH。';

  @override
  String get phoneRestrictedVivoNote => '不同 OriginOS 版本位置可能不同。右上角没有三个点时，把应用信息页往下翻到底找一找。';

  @override
  String get phoneRestrictedAdvancedStep => '在「高级设置」里找到「允许受限制的设置」，打开它。';

  @override
  String get phoneRestrictedOppoNote => 'ColorOS 有时找不到这个选项。这时用系统自带的「文件管理」找到 DSH 的安装包，点它覆盖安装一次（不用卸载，对话和设置都在），再去开无障碍。';

  @override
  String get phoneRestrictedHuaweiNote => '如果在无障碍里看到「受限制的设置」提示，按「原生 / 其他」的步骤做。';

  @override
  String get phoneRestrictedTitle => '允许受限制的设置';

  @override
  String get phoneRestrictedSteps => '步骤';

  @override
  String get phoneRestrictedDiagram => '图示';

  @override
  String get phoneRestrictedOpenInfo => '打开应用信息';

  @override
  String get phoneRestrictedOpenOverlayFailed => '打不开悬浮窗设置，请到「设置」里搜索「悬浮窗」';

  @override
  String get phoneRestrictedOpenAccessibilityFailed => '打不开无障碍设置，请到「设置」里搜索「无障碍」';

  @override
  String get phoneRestrictedFootnote => '名称因系统而异，找不到就在设置里搜「受限制」；仍打不开时重启手机再试';

  @override
  String get phoneRestrictedAppInfo => '应用信息';

  @override
  String get phoneRestrictedPermissionsManager => '权限管理';

  @override
  String get phoneRestrictedBatterySaver => '省电策略';

  @override
  String get phoneRestrictedAdvanced => '高级设置';

  @override
  String get phoneRestrictedPermissions => '权限';

  @override
  String get phoneRestrictedBattery => '电池';

  @override
  String get phoneRestrictedDiagramAdvanced => '图示：应用信息页里点「高级设置」，再打开「允许受限制的设置」';

  @override
  String get phoneRestrictedDiagramMenu => '图示：应用信息页点右上角三个点，再选「允许受限制的设置」';

  @override
  String get phoneRestrictedCaptionAdvanced => '① 点「高级设置」';

  @override
  String get phoneRestrictedCaptionMenu => '① 点右上角三个点';

  @override
  String get phoneRestrictedCaptionToggle => '② 打开这个开关';

  @override
  String get phoneRestrictedCaptionOption => '② 选这一项';

  @override
  String get phoneScreenReadFailed => '没能读到屏幕';

  @override
  String get phoneScreenUnknownReason => '原因不明';

  @override
  String get phoneScreenReadFailedHint => '确认无障碍已开启。密码、支付这类页面系统不让读';

  @override
  String get phoneScreenCurrent => '当前屏幕';

  @override
  String get phoneScreenEmpty => '（屏幕上没有可读的文字）';

  @override
  String get phoneScreenReadNote => '模型看到的就是这些文字，这次读取没有发给模型';

  @override
  String get phoneFailureSafeStartup => '安全模式也没能启动';

  @override
  String get phoneFailureSafeStartupHint => '问题多半在全局配置或运行环境';

  @override
  String get phoneFailureKilled => '引擎被系统结束了';

  @override
  String get phoneFailureKilledHint => '多半是内存不足或系统省电';

  @override
  String get phoneFailureLaunch => '本机运行环境未能启动';

  @override
  String get phoneFailureLaunchHint => '查看日志了解原因，或连接远程主机继续使用';

  @override
  String get phoneFailureTawcHint => 'PRoot 无法执行本机引擎。可以尝试用 tawcroot 启动，继续使用已有的运行环境和数据。';

  @override
  String get phoneFailureRetryWithTawcroot => '用 tawcroot 启动';

  @override
  String get phoneFailureNoSpaceHint => '清理一些空间后重试';

  @override
  String get phoneFailureStartup => 'DSH 启动失败';

  @override
  String get phoneFailureCrashedEarly => 'DSH 启动后很快崩溃了';

  @override
  String get phoneFailureCrashedLate => 'DSH 运行中崩溃了';

  @override
  String get phoneFailureFatal => '引擎报告了致命错误';

  @override
  String get phoneFailureRestore => '恢复配置';

  @override
  String get phoneFailureEnterSafe => '进入安全模式';

  @override
  String get phoneFailureStartNormal => '正常启动';

  @override
  String get phoneFailureGlobalPatch => '全局补丁';

  @override
  String get phoneFailureEnvironment => '环境变量';

  @override
  String get phoneSafeMoveAsideTitle => '先移开这些文件？';

  @override
  String get phoneSafeMoveAsideIntro => '它们对所有配置都生效，安全模式也会受影响：';

  @override
  String get phoneSafeMoveAsideNote => '只是改名（加上 .off-时间），不会删除，修好后可以改回来。';

  @override
  String get phoneSafeStartDirectly => '直接启动';

  @override
  String get phoneSafeMoveAsideStart => '移开并启动';

  @override
  String get phoneSafeNoRestoreNeeded => '配置和上次正常时一样，无需恢复';

  @override
  String get phoneSafeNoRestoreRecord => '还没有正常运行过的配置记录';

  @override
  String get phoneSafeRestoreTitle => '恢复上次正常的配置？';

  @override
  String get phoneSafeRestoreStart => '恢复并启动';

  @override
  String get phoneSafeRestoredStarting => '已恢复上次正常的配置，正在启动…';

  @override
  String get phoneSafeRestoreFailed => '没能恢复';

  @override
  String get phoneSafeStopIncomplete => '还无法确认引擎已停止，未更改配置。请查看引擎日志后重试。';

  @override
  String get phoneSafeRestartIncomplete => '配置操作已完成，但引擎还未停止，暂未重启。请等待停止完成后再启动。';

  @override
  String get phoneSafeRestoreIntro => 'DSH 会回到上次正常运行时的配置：';

  @override
  String get phoneSafeRestoreSettings => '• 设置恢复到当时的版本（现在的另存为备份）';

  @override
  String get phoneSafeRestoreNote => '不会卸载任何插件，也不需要联网。停用的插件以后可以重新打开。';

  @override
  String get phoneSafeLeaveTitle => '恢复正常模式？';

  @override
  String get phoneSafeLeaveBody => '用原来的配置和插件启动。安全模式期间改的网页版设置不会保留。';

  @override
  String get phoneSafeLeave => '恢复正常模式';

  @override
  String get phoneSafeMovePatch => '移开补丁';

  @override
  String get phoneSafeMoveFiles => '移开文件';

  @override
  String get phoneSafeFailureLog => '失败前后的日志';

  @override
  String get phoneSafeFailureLogEmpty => '没有记录到失败时的输出';

  @override
  String get phoneSafeBannerTitle => '安全模式 · 插件没有加载';

  @override
  String get phoneSafeBannerProbation => '正在试用正常模式';

  @override
  String get phoneSafeBannerProbationHint => '2 分钟内不再出错就算恢复，否则自动回到安全模式';

  @override
  String get phoneSafeBannerRunningHint => '对话都在，修好配置后恢复正常模式';

  @override
  String get phoneSafeBannerFailedHint => '安全模式也没能启动，去引擎页查看';

  @override
  String get phoneSafeBannerStoppedHint => '引擎已停止，下次启动仍是安全模式';

  @override
  String get phoneSafeRepair => '帮我修复';

  @override
  String get phoneSafeReasonStartup => '连续两次启动失败';

  @override
  String get phoneSafeReasonProbation => '恢复正常后又崩溃了';

  @override
  String get phoneSafeReasonManual => '手动开启';

  @override
  String get phoneSafeNormalSettingsHint => '用原有配置和插件重启';

  @override
  String get phoneSafeStartSettings => '以安全模式启动';

  @override
  String get phoneSafeStartSettingsHint => '不加载插件，排查启动问题';

  @override
  String get phoneSafeAutoSettings => '自动进入安全模式';

  @override
  String get phoneSafeAutoSettingsHint => '连续启动失败时自动启用';

  @override
  String get phoneAccentMist => '雾蓝';

  @override
  String get phoneAccentDaiqing => '黛青';

  @override
  String get phoneAccentDusk => '暮紫';

  @override
  String get phoneAccentTurquoise => '松石';

  @override
  String get phoneAccentAmber => '琥珀';

  @override
  String get phoneAccentGraphite => '石墨';

  @override
  String get phoneAccentCustom => '自定义';

  @override
  String phoneEngineInstallPercent(int percent) {
    return '正在安装 · $percent%';
  }

  @override
  String phoneEngineStatusSemantics(String prefix, String status) {
    return '$prefix引擎：$status';
  }

  @override
  String phoneLogLineCount(int count) {
    return '$count 行';
  }

  @override
  String phoneLogCopiedLines(int count) {
    return '已复制 $count 行';
  }

  @override
  String phoneAppRuleDefault(String rule) {
    return '默认：$rule';
  }

  @override
  String phoneAppRulesLoosenTitle(String app) {
    return '让 DSH 操作「$app」？';
  }

  @override
  String phoneAppRulesSkipStepsTitle(String app) {
    return '「$app」不再逐步确认？';
  }

  @override
  String phoneDndBrowserFailed(String url) {
    return '打不开浏览器。网址：$url';
  }

  @override
  String phoneDndChannelReady(String channel) {
    return '$channel · 可以用了';
  }

  @override
  String phoneDndChannelStatus(String channel, String reason) {
    return '$channel · $reason';
  }

  @override
  String phoneDndUsing(String channel) {
    return '正在使用：$channel';
  }

  @override
  String phoneDndEnableWith(String mode) {
    String _temp0 = intl.Intl.selectLogic(mode, {
      'shizuku': '用 Shizuku 开启',
      'sui': '用 Sui 开启',
      'root': '用 Root 开启',
      'adb': '用自连 ADB 开启',
      'other': '启用不打扰模式',
    });
    return '$_temp0';
  }

  @override
  String phoneDndSwitchTo(String mode) {
    String _temp0 = intl.Intl.selectLogic(mode, {
      'shizuku': '改用 Shizuku',
      'sui': '改用 Sui',
      'root': '改用 Root',
      'adb': '改用自连 ADB',
      'other': '改用这个通道',
    });
    return '$_temp0';
  }

  @override
  String phoneControlWorkingApp(String app) {
    return '正在操作「$app」';
  }

  @override
  String phoneControlPolicySummary(int denied, int confirmed) {
    return '$denied 个不碰 · $confirmed 个每步确认';
  }

  @override
  String phoneControlRemoteHint(String host) {
    return '「$host」上的 DSH 操作不了这台手机，切回「本机」后可用';
  }

  @override
  String phoneRestrictedSubtitle(String place) {
    return '侧载的 App 要先放行这一项，$place开关才点得动';
  }

  @override
  String phoneRestrictedDone(String place) {
    return '$place已开好，可以返回了';
  }

  @override
  String phoneFailurePlugins(String plugins) {
    return '可能和插件「$plugins」有关';
  }

  @override
  String phoneFailureRequired(String components) {
    return '必需组件 $components 没通过启动检查';
  }

  @override
  String phoneSafeRestoreAt(String when) {
    return 'DSH 会回到 $when 正常运行时的配置：';
  }

  @override
  String phoneSafeRestoreDisable(String plugins) {
    return '• 停用：$plugins';
  }

  @override
  String phoneSafeRestoreChanged(String plugins) {
    return '  （$plugins 之后升级过，只能先停用）';
  }

  @override
  String phoneSafeRestoreEnable(String plugins) {
    return '• 重新启用：$plugins';
  }

  @override
  String phoneSafeTodayTime(String time) {
    return '今天 $time';
  }

  @override
  String phoneSafeReasonPlugins(String plugins) {
    return '连续两次启动失败，可疑插件：$plugins';
  }

  @override
  String get phoneListSeparator => '、';

  @override
  String get phonePluginQuoteSeparator => '」「';

  @override
  String phoneEngineRunningAt(String address) {
    return '运行中 · $address';
  }

  @override
  String phoneEngineSafeAt(String address) {
    return '安全模式 · $address';
  }

  @override
  String get phoneAppRulesLoosenBody => '银行、支付类 App 会检测自动操作，可能限制登录甚至冻结账号；DSH 默认不输密码、不付款。';

  @override
  String get phoneAppRulesSkipStepsBody => '微信这类 App 有风控，曾有手机助手操作后账号被强制下线。改成照常后，只有发消息这类操作还会先问你。';

  @override
  String get phoneResetDeletesChatsWorkspaces => '对话和工作区';

  @override
  String get phoneResetBodyChatsWorkspaces => '会删除对话和工作区，然后重新安装运行环境。';

  @override
  String get phoneResetDeletesWithPlugins => '对话、工作区、插件和设置';

  @override
  String get phoneResetBodyWithPlugins => '会删除对话、工作区、插件和设置，然后重新安装运行环境。';

  @override
  String get phoneResetDeletesWithUi => '对话、工作区、界面配置和技能';

  @override
  String get phoneResetBodyWithUi => '会删除对话、工作区、界面配置和技能，然后重新安装运行环境。';

  @override
  String get phoneResetDeletesEverything => '对话、工作区、插件、设置、界面配置和技能';

  @override
  String get phoneResetBodyEverything => '会删除对话、工作区、插件、设置、界面配置和技能，然后重新安装运行环境。';

  @override
  String phoneEngineStorageDetails(String needed, String free) {
    return '存储空间不足：需要约 $needed MB，当前可用 $free MB';
  }

  @override
  String get phoneControlEnabledRestarting => '已开启，引擎正在重启';

  @override
  String get phoneControlDisabledRestarting => '已关闭，引擎正在重启';

  @override
  String get phoneControlEnabledPending => '已开启，引擎启动后生效';

  @override
  String get phoneReturnAfterDone => '完成后返回 DSH Go';

  @override
  String get phoneReturnAfterDoneHint => '收起悬浮条，回到对话看结果';

  @override
  String get phoneFloatingBar => '悬浮条';

  @override
  String get phoneIdleOpacity => '闲置时不透明度';

  @override
  String get phoneAutoCollapse => '闲置时自动收起';

  @override
  String get phoneAutoCollapseHint => '一会儿不碰就收起卡片、收成小球；关着时只在你点按时收起';

  @override
  String get phoneEdgeGlow => '屏幕边缘光效';

  @override
  String get phoneEdgeGlowHint => '操控时屏幕四周的流光';

  @override
  String get phoneSystemIsland => '用系统灵动岛显示';

  @override
  String get phoneSystemIslandHint => '小米超级岛、ColorOS 流体云、荣耀 MagicOS 上，操作进度放进系统的灵动岛，不再出悬浮条';

  @override
  String get phoneSystemIslandOff => '要先在通知设置里打开「实时活动」，没打开时仍用悬浮条';

  @override
  String get phoneSystemIslandUnsupported => '这台手机没有可用的系统灵动岛，用悬浮条';

  @override
  String get phoneDeveloperOptions => '开发者选项';

  @override
  String get phoneDirectEngine => '直接启动本机引擎';

  @override
  String get phoneDirectHint => '实验功能，默认关闭，下次启动生效。部分手机（例如 Android 16）会拦截直接启动，届时自动改用兼容启动，数据不受影响。';

  @override
  String get phoneDirectFailedHint => '这台手机上直接启动没有成功，已改用兼容启动。停止引擎后打开可再试一次。';

  @override
  String get phoneDirectCompatibleHint => '这次用了兼容启动，原因见上方。已保留此选项，下次启动会再试。';

  @override
  String get phoneDirectStopFirst => '请先停止本机引擎，再切换启动方式。';

  @override
  String get phoneDirectSafeHint => '安全模式使用兼容启动；恢复正常模式后应用此选项。';

  @override
  String get phoneDirectNeedsRuntime => '此选项需要支持直接启动的运行环境。';

  @override
  String get phoneDirectChangeFailed => '未能切换启动方式，请停止本机引擎后重试。';

  @override
  String get phoneTawcEngine => 'tawcroot 加速启动';

  @override
  String get phoneTawcHint =>
      '默认开启，改动下次启动生效，和「直接启动」二选一。用 tawcroot 代替兼容启动运行本机引擎：启动快约三倍，装包、apt 也更快。启动不成功会自动改回兼容启动。关掉后的第一次启动会先把它留下的硬链接整理成普通文件，可能要多等一会。';

  @override
  String get phoneTawcFailedHint => '这台手机上 tawcroot 没有启动成功，已改用兼容启动。停止引擎后打开可再试一次。';

  @override
  String get phoneTawcUnavailable => '这个安装包不含 tawcroot，或系统低于 Android 10。';

  @override
  String get phoneLaunchTawcroot => 'tawcroot';

  @override
  String get phoneTawcLaunchFailed => 'tawcroot 未启动成功';

  @override
  String get phoneTawcUnsupported => '这次的启动参数 tawcroot 还不支持，暂用兼容启动';

  @override
  String get phoneActualLaunchMode => '当前运行方式';

  @override
  String get phoneLaunchNotObserved => '未运行';

  @override
  String get phoneLastLaunchSelection => '上次启动方式';

  @override
  String get phoneDirectRejectedReason => '兼容启动原因';

  @override
  String get phoneLaunchFailureReason => '上次启动失败';

  @override
  String get phoneReturnCompatible => '切回兼容启动';

  @override
  String get phoneLaunchDirect => '直接启动';

  @override
  String get phoneLaunchCompatible => '兼容启动';

  @override
  String get phoneDirectIncompatibleFiles => '插件文件待整理，暂用兼容启动';

  @override
  String get phoneDirectNotEnoughSpace => '空间不足，暂用兼容启动';

  @override
  String get phoneDirectMigrationFailed => '文件整理未完成，暂用兼容启动';

  @override
  String get phoneDirectLaunchFailed => '直接启动未成功';

  @override
  String get phoneLaunchStartFailed => '未能完成启动';

  @override
  String phoneLaunchExited(String code) {
    return '退出码 $code';
  }

  @override
  String get phoneDndManualConnect => '按端口连接';

  @override
  String get phoneDndConnectPortLabel => '连接端口';

  @override
  String get phoneDndConnectPortHint => '在系统「无线调试」首页查看「IP 地址和端口」，填写冒号后的端口。请不要使用配对码页面的端口。';

  @override
  String get phonePreviewTitle => '实时查看后台屏';

  @override
  String get phonePreviewDescription => '仅在预览可见时取帧。画面只留在本机；预览不可点击。';

  @override
  String get phonePreviewOpen => '查看后台屏';

  @override
  String phonePreviewTask(String taskId) {
    return '预览任务 $taskId';
  }

  @override
  String get phonePreviewInUse => '正在预览另一任务';

  @override
  String get phonePreviewOff => '任务已结束或预览已关闭';

  @override
  String get phonePreviewUnavailable => '画面暂不可预览，或受到保护';

  @override
  String get phonePreviewWaiting => '等待后台屏的新画面';

  @override
  String get phoneViewportTitle => '后台视口';

  @override
  String get phoneViewportDescription => '下次新建后台屏时生效；当前后台屏不变，交还后重建会采用新设置。视口方向不会强制应用旋转。';

  @override
  String get phoneViewportPortrait => '竖屏';

  @override
  String get phoneViewportLandscape => '横屏';

  @override
  String get phoneResumeTask => '重新允许手机操控';

  @override
  String get phoneResumeTaskHint => '允许此对话之后的手机操作，不重放已经结束的动作。';

  @override
  String get phoneResumeTaskFailed => '暂时没能恢复，上一动作可能仍在收尾。';

  @override
  String phoneStoppedTask(int task) {
    return '手机任务 $task 已停止';
  }

  @override
  String get phoneTaskDrainingHint => '正在等待上一动作退出并清理后台屏。';

  @override
  String get phoneTaskCleanupFailedHint => '未能确认后台屏已清理，手机操控仍被阻挡。';

  @override
  String phoneFinishingTask(int task) {
    return '手机任务 $task 正在收尾';
  }

  @override
  String get phoneCleanupRetry => '重试清理';

  @override
  String get phoneCleanupRetryFailed => '仍未能确认上一后台屏已清理，屏幕占用继续保留。';

  @override
  String get phoneSelfCheckTitle => '检查手机操控';

  @override
  String get phoneSelfCheckTechnicalDetails => '技术详情';

  @override
  String get phoneLocalOcrSummary => '本机识别；结果可发给模型，SDK 会收集使用统计。';

  @override
  String get phoneLocalOcrPrivacyDetails => '隐私详情';

  @override
  String get phoneSelfCheckPartial => '部分自检：仅已观察的项目有结果';

  @override
  String get phoneSelfCheckScope => '使用已选择并连接的通道和临时展示屏。应用启动、文字输入、截图、OCR及主屏受扰情况均未测试。清理通过不代表展示屏创建成功。';

  @override
  String get phoneSelfCheckStart => '开始检查';

  @override
  String get phoneSelfCheckCancel => '请求取消';

  @override
  String get phoneSelfCheckRefresh => '刷新状态';

  @override
  String get phoneSelfCheckSave => '保存脱敏报告';

  @override
  String get phoneSelfCheckSaving => '保存中…';

  @override
  String get phoneSelfCheckSaved => '报告已存入下载/DSH-Go。';

  @override
  String get phoneSelfCheckSaveFailed => '报告保存失败。';

  @override
  String get phoneSelfCheckReportHint => '仅在你点击保存时导出。本机报告只含固定结果，不含截图、识别文字、日志、账户数据或运行标识。';

  @override
  String phoneSelfCheckRunState(String state) {
    String _temp0 = intl.Intl.selectLogic(state, {
      'idle': '尚未开始',
      'running': '部分自检进行中',
      'cleaning': '正在清理；取消不代表已撤销派发的输入',
      'done': '检查已结束，结果见技术详情',
      'cancelled': '已取消，已观察到的操作仍保留',
      'other': '状态不可用',
    });
    return '$_temp0';
  }

  @override
  String phoneSelfCheckStepState(String state) {
    String _temp0 = intl.Intl.selectLogic(state, {
      'not_run': '未运行／无观察',
      'running': '进行中',
      'pass': '已观察通过',
      'fail': '失败',
      'skipped': '已跳过',
      'unknown': '未确认',
      'cancelled': '已取消',
      'other': '未确认',
    });
    return '$_temp0';
  }

  @override
  String phoneSelfCheckStage(String stage) {
    String _temp0 = intl.Intl.selectLogic(stage, {
      'device': '设备前置条件',
      'channel': '已选通道',
      'display': '临时后台屏创建',
      'input_probe': '触摸接收核验',
      'launch': '应用启动',
      'tree': '控件树',
      'tap': '应用按钮点按',
      'scroll': '应用滚动',
      'back': '应用返回',
      'text_ascii': '固定 ASCII 输入',
      'text_zh': '固定中文输入',
      'capture': '本地图样截图',
      'continuity': '有限受控刷新',
      'main': '有限主屏观察',
      'ocr': '本机OCR',
      'cleanup': '严格清理',
      'other': '未知项目',
    });
    return '$_temp0';
  }

  @override
  String phoneSelfCheckReason(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'busy': '手机或通道正忙。',
      'unsupported': '设备或特权端不支持这项自检。',
      'cancelled': '本次请求已取消或退役。',
      'disabled': '手机操控尚未开启。',
      'locked': '设备已锁定。',
      'identity': '原运行或通道身份已改变。',
      'invalid': '请求或结果无法验证。',
      'display': '临时展示屏未能确认。',
      'input': '输入受理或送达未确认，不会重放已派发输入。',
      'cleanup': '资源清理未确认，请重新连接通道后再检查。',
      'denied': '系统拒绝了操作。',
      'timeout': '操作超时，已派发工作仍可能完成。',
      'unavailable': '本机状态或已选通道不可用。',
      'target_unavailable': '无法核实固定目标，请完成清理后再开始。',
      'target_changed': '原目标已变化，请仅继续清理。',
      'target_cleanup': '目标清理未确认，请重新连接通道后再检查。',
      'target_main': '目标曾出现在主屏，已停止后续步骤，请完成清理。',
      'target_readback': '固定目标计数或文本回读不符，不要重复操作，请完成清理。',
      'tree_cleanup': '树连接清理未确认，请重新连接通道后再检查。',
      'target_launch': '目标启动被拒绝或未确认，请检查设备并完成清理。',
      'frame_unavailable': '未取得可用的本地图样帧，请完成清理后再开始新的自检。',
      'frame_mismatch': '实际画面与本次目标及阶段不符，请完成清理。',
      'continuity': '有限受控刷新序列未确认；这不是帧率结果。',
      'main_changed': '主屏采样点发生变化，也可能包含用户操作；请完成清理，不能据此判定原因。',
      'main_unchanged': '这些有限采样点未见变化，采样之间是否受扰仍未知。',
      'main_incomplete': '主屏样本不完整，不能据此证明没有受扰。',
      'not_installed': '本自检未接入 OCR，未执行识别测试。',
      'other': '收到无法识别的结果。',
    });
    return '$_temp0';
  }

  @override
  String get phoneSelfCheckTargetScope =>
      '使用普通临时后台屏和固定本地目标，检查启动、控件树及一次按钮点击。文字、滚动、截图和 OCR 未测试；主屏只记录实际观察到的受扰失败，不提供通过结论。仅清理完成不证明曾创建后台屏。';

  @override
  String get phoneSelfCheckProfileChoice => '选择下次自检（不会改变下方报告）';

  @override
  String phoneSelfCheckProfile(String profile) {
    String _temp0 = intl.Intl.selectLogic(profile, {
      'probe_b': '输入接收探针（B）',
      'target_c1': '固定目标自检（C1）',
      'target_c2': '固定输入与画面自检（C2）',
      'other': '未知模式',
    });
    return '$_temp0';
  }

  @override
  String phoneSelfCheckReportProfile(String profile) {
    String _temp0 = intl.Intl.selectLogic(profile, {
      'probe_b': '本次报告：输入接收探针（B）',
      'target_c1': '本次报告：固定目标（C1）',
      'target_c2': '本次报告：固定输入与画面（C2）',
      'other': '本次报告模式未确认',
    });
    return '$_temp0';
  }

  @override
  String get phoneSelfCheckTargetC2Scope =>
      '使用固定本机目标核验启动、控件树、单次按钮点按、ASCII／中文 ACTION_SET_TEXT 整框替换与回读、本地图样截图和有限受控刷新；不衡量 FPS 或流畅度。有限主屏样本不能证明采样间全程无扰。OCR、触摸接收探针、滚动和返回不在本次范围。仅清理完成也不证明曾创建展示屏。';

  @override
  String phoneTaskWaiting(int taskId) {
    return '任务 $taskId · 等待资源';
  }

  @override
  String phoneTaskWaitingApp(String packageName, int seconds) {
    return '等待应用 $packageName，已等待 $seconds 秒。';
  }

  @override
  String phoneTaskWaitingUnknown(int seconds) {
    return '等待界面资源（应用身份未确认），已等待 $seconds 秒。';
  }

  @override
  String phoneTaskWaitingScreen(String screen, int seconds) {
    return '等待$screen，已等待 $seconds 秒。';
  }

  @override
  String get phoneTaskMainResource => '主屏';

  @override
  String get phoneTaskBackgroundResource => '后台屏';

  @override
  String get phoneInterruptionTitle => '上次手机任务未确认结束';

  @override
  String get phoneInterruptionLoading => '正在读取任务中断记录…';

  @override
  String get phoneInterruptionStorageError => '无法保存或读取任务结束记录。请重试；这不表示后台资源已清理。';

  @override
  String phoneInterruptionHint(int count) {
    return '有 $count 个任务中断或未能保存结束状态，操作结果可能已发生。请先核对；确认仅表示看过提示，不会恢复操作或证明后台资源已清理。';
  }

  @override
  String get phoneInterruptionAcknowledge => '已核对中断提示';

  @override
  String get phoneInterruptionRetry => '重试保存或读取';

  @override
  String get phoneInterruptionActionFailed => '任务记录尚未确认，请重试';

  @override
  String get phoneLocalOcrTitle => '文字识别';

  @override
  String get phoneLocalOcrUnknown => '暂时无法读取本机文字识别设置，请刷新后再试。';

  @override
  String get phoneLocalOcrDisclosure => '识别在本机进行，截图和文字不会发给 Google；Google 的 SDK 会收集机型、应用版本、耗时等使用统计。';

  @override
  String get phoneLocalOcrDetails =>
      '默认开启。关闭时，文字识别请求不会触发 SDK 加载或初始化；Remote 扫码配对会独立按需初始化共用的 SDK，不会开启文字识别。截图和识别文字可能发送给你配置的模型。关闭后不再开始新的本机文字识别；已经开始的识别可能仍在收尾。关闭不会卸载 SDK，也不承诺清除或停止发送此前积累的 SDK 统计。';

  @override
  String get phoneBackgroundParallelTitle => '后台任务上限';

  @override
  String phoneBackgroundParallelStatus(int configured, int effective, int held) {
    return '设置上限：$configured · 当前可用上限：$effective · 已占用：$held';
  }

  @override
  String get phoneBackgroundParallelDescription => '调低上限会保留已有任务。新任务仍需等待应用和主屏资源可用。';

  @override
  String phoneBackgroundParallelChoice(int limit) {
    return '$limit 个后台任务槽位';
  }

  @override
  String get phoneBackgroundParallelOff => '后台通道已关闭。保存此偏好不会开启通道。';

  @override
  String get phoneBackgroundParallelUnsupported => '此设备当前无法使用后台操作。';

  @override
  String get phoneBackgroundParallelConnection => '建立连接后才能接纳新的后台任务。';

  @override
  String get phoneBackgroundParallelBusy => '后台通道正在准备或维护，暂不能接纳新任务。';

  @override
  String get phoneGateRetest => '重新检查此通道';

  @override
  String get phoneBackgroundParallelSerial => '此连接支持一个后台槽位，设置偏好仍会保留。';

  @override
  String get phoneSkillBundlePublishedUnverified => '文件已发布，但尚未通过完整核验。不要重复保存。';

  @override
  String get phoneSkillBundleUnknown => '保存结果尚未确认，文件可能已经写入。不要重复保存。';

  @override
  String phoneSkillBundleRevision(String revision) {
    return '路线版本：$revision';
  }

  @override
  String get phoneSkillReplayReview => '核对手机路线';

  @override
  String get phoneSkillReplaySourceChanged => '本机会话或连接已改变，请返回当前本机会话重新选择。';

  @override
  String get phoneSkillReplayUnavailable => '此路线尚不能在当前本机安全执行。仍可按普通技能模板使用。';

  @override
  String get phoneSkillReplayConfirm => '我已核对这条路线与本次选择的 App。';

  @override
  String get phoneSkillReplayToComposer => '放入当前对话';

  @override
  String phoneSkillReplayStartText(String request) {
    return '本机已选择并核对手机路线。请仅调用 mcp__phone__replay，参数 $request。若不可用或被拒绝，交回用户/模型，不要改为普通动作重放。';
  }

  @override
  String get phoneSkillReplayQueue => '发送路线（排队）';

  @override
  String get phoneSkillReplayQueued => '路线消息已被接收或排队，尚不代表路线执行成功。';

  @override
  String get phoneSkillReplaySendUncertain => '路线消息未确认发送成功；没有自动重新准备或重放。请核对原对话结果。';

  @override
  String get phoneIosServiceTitle => 'iOS 自动化服务';

  @override
  String get phoneIosServiceHint => '授权后按需启动。任务结束会停止服务，系统的“Automation Running”提示也会结束。';

  @override
  String get phoneIosSetupHint => '保持 LocalDevVPN 已连接，首次使用时允许 30 分钟操控。';

  @override
  String get phoneIosReturnHint => '任务完成后回到当前对话，并停止手机操控服务。';

  @override
  String get phoneIosNeedsSetup => '运行器尚未就绪，请确认本机引擎和开发者环境已配置。';

  @override
  String get phoneTaskResultReady => '任务完成 · 查看结果';

  @override
  String get phoneTaskEndedResult => '任务已结束 · 查看结果';

  @override
  String get phoneBackgroundGuideTitle => '后台确认与返回';

  @override
  String get phoneBackgroundGuideSubtitle => '让确认卡和任务结果及时出现';

  @override
  String get phoneBackgroundGuideBody => '需要你确认时，会显示 DSH Go 卡片。卡片不可用时会尝试通知或回到 App。请在系统设置中允许手机操控通知和弹出提醒。';

  @override
  String get phoneBackgroundOemHint => '在 DSH Go 的系统权限页检查「后台弹出界面」（若提供）。允许后可改善自动返回；菜单名称随系统版本变化。';

  @override
  String get phoneBackgroundReturnHint => '如果任务完成后没有自动返回，可点通知「任务完成 · 查看结果」。系统关闭通知或限制后台弹出时，可能需要手动打开 DSH Go。';

  @override
  String get phoneBackgroundGotIt => '知道了';

  @override
  String get phoneBackgroundOpenSettings => '打开系统设置';

  @override
  String get phoneBackgroundNotificationBlocked => '请允许手机操控通知的弹出提醒';

  @override
  String get phonePrivilegedUpgrade => '此版本尚不支持该特权通道，请更新 DSH Go 后使用。';

  @override
  String get phonePrivilegedSui => 'Sui';

  @override
  String get phonePrivilegedRoot => 'Root';

  @override
  String get phonePrivilegedSuiDescription => '使用 Sui 模块提供的接口，仅在主动点击时申请授权。';

  @override
  String get phonePrivilegedRootDescription => '适用于 Magisk、KernelSU 或 APatch；只有主动选择后才首次执行 root 命令。';

  @override
  String get phonePrivilegedRootPrepare => '申请 root 授权';

  @override
  String get phonePrivilegedRootUnchecked => '尚未检查';

  @override
  String get phonePrivilegedGrantRoot => '通过 root 授予';

  @override
  String get phonePrivilegedGrantSui => '通过 Sui 授予';

  @override
  String get phonePrivilegedGrantSuiPermission => '先授权 Sui，再授予权限';

  @override
  String get phonePrivilegedSuggested => '建议';

  @override
  String get phonePrivilegedRootRiskTitle => '给 DSH Go root 权限？';

  @override
  String get phonePrivilegedRootRiskBody =>
      'root 管理器（Magisk、KernelSU 或 APatch）会弹窗问你。允许后，DSH Go 以 root 运行自己的后台服务；只有打开「保持 root 通道」，断开或重启后才会自己再去申请。';

  @override
  String phoneKeepTitle(String mode) {
    String _temp0 = intl.Intl.selectLogic(mode, {
      'shizuku': '保持 Shizuku 通道',
      'sui': '保持 Sui 通道',
      'root': '保持 root 通道',
      'adb': '保持自连 ADB 通道',
      'other': '保持这个通道',
    });
    return '$_temp0';
  }

  @override
  String get phoneKeepRootDescription => '断开、重开 App 或重启手机后，DSH Go 会自己再向 root 管理器申请；给不给仍由管理器决定。';

  @override
  String get phoneKeepSharedDescription => '断开、重开 App 或重启手机后，DSH Go 用已有的授权自己连回去，不会替你申请授权。';

  @override
  String get phoneKeepAdbDescription => '断开、重开 App 或重启手机后，DSH Go 用已有的配对在 Wi‑Fi 下自己连回去；有「自动恢复无障碍」的权限时，还会试着打开一次无线调试。';

  @override
  String get phoneKeepRestoring => '正在重新连接';

  @override
  String get phoneKeepWaiting => '等通道可用后再连';

  @override
  String get phoneKeepWaitingService => '等所选服务运行后再连';

  @override
  String get phoneKeepWaitingPermission => '还没有授权；授权后会自己连上';

  @override
  String get phoneKeepWaitingNetwork => '等连上 Wi‑Fi 后再连';

  @override
  String get phoneKeepNotPaired => '还没有配对，请先完成无线调试配对';

  @override
  String get phoneKeepFailed => '没连上；下次打开 App 或开始操控时再试';

  @override
  String get phoneSkillsTitle => '手机技能';

  @override
  String get phoneSkillsSummaryNone => '做过的事会在这里变成技能';

  @override
  String phoneSkillsSummary(int count) {
    return '已学会 $count 项';
  }

  @override
  String phoneSkillsSummaryDrafts(int count, int drafts) {
    return '已学会 $count 项 · $drafts 份待确认';
  }

  @override
  String get phoneSkillsLearn => '从做过的事里学';

  @override
  String get phoneSkillsLearnHint => '手机操控办成的事会起草成技能，你收下才会用';

  @override
  String get phoneSkillsLearnOffHint => '关着时不再起草新技能，已收下的照常用';

  @override
  String get phoneSkillsTabMine => '我的技能';

  @override
  String phoneSkillsTabDrafts(int count) {
    return '待确认 $count';
  }

  @override
  String get phoneSkillsTabDraftsNone => '待确认';

  @override
  String get phoneSkillsEmpty => '还没有学会的技能。手机操控办成一件事后，DSH 会起草一份，等你收下。';

  @override
  String get phoneSkillsDraftsEmpty => '没有要确认的草稿';

  @override
  String get phoneSkillsFootnote => '技能是给 DSH 看的做事说明：下次做同类的事，它会先读一遍再动手。用得越多，它越熟练。';

  @override
  String phoneSkillStateActive(int uses) {
    return '常用 · 用了 $uses 次';
  }

  @override
  String get phoneSkillStateTrial => '试用中 · 还没用它办成过事';

  @override
  String get phoneSkillStateSuspended => '已停用';

  @override
  String get phoneSkillStateSuspendedMisses => '已停用 · 最近不灵';

  @override
  String get phoneSkillSourceWritten => '你让 DSH 写的';

  @override
  String get phoneSkillUse => '使用这项技能';

  @override
  String get phoneSkillLearnedTitle => 'DSH 学会了一个新做法';

  @override
  String phoneSkillUpdateTitle(String name) {
    return 'DSH 想改进「$name」';
  }

  @override
  String get phoneSkillAccept => '收下';

  @override
  String get phoneSkillAcceptUpdate => '收下这次修改';

  @override
  String get phoneSkillEditDraft => '改一改';

  @override
  String get phoneSkillDiscard => '不要';

  @override
  String get phoneSkillDiscarded => '没有存这份草稿';

  @override
  String phoneSkillAccepted(String name) {
    return '已收下「$name」，先试用';
  }

  @override
  String get phoneSkillOpenSource => '看那次对话';

  @override
  String get phoneSkillLegacyTitle => '早期存下的';

  @override
  String get phoneSkillLegacyHint => '旧版存下的模板，DSH 不会用它们，可以删掉';

  @override
  String get phoneSkillDelete => '删除技能';

  @override
  String phoneSkillDeleteTitle(String name) {
    return '删除「$name」？';
  }

  @override
  String get phoneSkillDeleteBody => '删了以后 DSH 不再用它做事。';

  @override
  String get phoneSkillRestore => '恢复上一版';

  @override
  String get phoneSkillRestored => '已恢复上一版';

  @override
  String get phoneSkillUseInChat => '在对话里用';

  @override
  String get phoneSkillSaved => '已保存';

  @override
  String get phoneSkillSectionEntry => '入口';

  @override
  String get phoneSkillSectionSteps => '步骤';

  @override
  String get phoneSkillSectionPitfalls => '容易出错的地方';

  @override
  String get phoneSkillSectionSuccess => '怎样算办成';

  @override
  String get phoneSkillSectionHandoff => '什么时候停下交给你';

  @override
  String get phoneSkillFieldName => '名字';

  @override
  String get phoneSkillFieldDescription => '做什么';

  @override
  String get phoneSkillFieldWhen => '什么时候用';

  @override
  String get phoneSkillEditHint => '具体的人名、号码、内容写成 <参数>，DSH 做事时会按这次的要求填进去。';

  @override
  String get phoneSkillRecent => '最近几次';

  @override
  String get phoneSkillRecentNone => '还没用过';

  @override
  String get phoneSkillRecentOk => '办成';

  @override
  String get phoneSkillRecentMiss => '不灵';

  @override
  String get phoneSkillRecentVoid => '不算';

  @override
  String get phoneSkillRecentSeparator => '、';

  @override
  String get phoneSkillErrorChanged => '这项技能在你改的时候变了，这次修改没有覆盖它。回去重新看看。';

  @override
  String get phoneSkillErrorInvalid => '有一节是空的或格式不对，每一节都写上内容再存。';

  @override
  String get phoneSkillErrorSensitive => '里面有密码、验证码这类内容，去掉再存。';

  @override
  String get phoneSkillErrorUnavailable => '手机技能暂时用不了，稍后再试。';

  @override
  String phoneSkillPromoted(String name) {
    return '「$name」用它办成了事，转为常用';
  }

  @override
  String phoneSkillSuspended(String name) {
    return '「$name」最近不灵，先停用了';
  }

  @override
  String get phoneSkillTurnOn => '恢复';

  @override
  String phoneSkillApps(String apps) {
    return '用在 $apps';
  }

  @override
  String get phoneSkillUndo => '撤销';

  @override
  String get searchKwPhoneSkills => '技能、学会、熟练、沉淀、存成技能、做法';

  @override
  String get phoneModeTitle => '选择确认方式';

  @override
  String get phoneModeMessage => '随时可在设置里更改';

  @override
  String get phoneModeAsk => '关键步骤先问我';

  @override
  String get phoneModeAskHint => '进新 App、发送、删除、付款前先问';

  @override
  String get phoneModeAuto => '全程自动';

  @override
  String get phoneModeAutoHint => '不再询问，全程免打扰';

  @override
  String get phoneModeAutoNoteTitle => '这些仍由你来操作';

  @override
  String get phoneModeAutoNote => '系统设置和权限页面、密码和验证码、DSH Go 自身仍由你来操作；银行、支付类 App 默认不碰，可在设置里调整。';

  @override
  String get phoneModeAutoUnlockNote => '如需让 AI 操作系统设置、密码等，可在 设置 › 手机操控 › 解除限制 中开启。';

  @override
  String get phoneModeConfirmAuto => '开启全程自动';

  @override
  String get phoneYoursTitle => '这些由你来操作';

  @override
  String get phoneYoursSystem => '系统设置和权限页面';

  @override
  String get phoneYoursSecrets => '密码和验证码';

  @override
  String get phoneYoursOwnApp => 'DSH Go 自身';

  @override
  String get phoneYoursDenyList => '应用名单里「不碰」的 App，默认含银行、支付类';

  @override
  String get phoneUnlockTitle => '解除限制';

  @override
  String get phoneUnlockSubtitle => '让 AI 去做默认由你来做的事';

  @override
  String get phoneUnlockSystem => '系统设置';

  @override
  String get phoneUnlockSystemHint => '含权限页、安装器、安全中心、通知栏';

  @override
  String get phoneUnlockSecrets => '密码和验证码';

  @override
  String get phoneUnlockSecretsHint => '填写密码、验证码和支付密码';

  @override
  String get phoneUnlockOwnApp => 'DSH Go 自身';

  @override
  String get phoneUnlockOwnAppHint => '在 DSH Go 里点按和输入';

  @override
  String get phoneUnlockBusy => '任务进行中，结束后才能开启';

  @override
  String get phoneUnlockFootnote => '开启后的后果由你承担。建议只在需要时开启，用完关闭。';

  @override
  String get phoneUnlockBanks => '银行、支付类 App';

  @override
  String get phoneUnlockBanksHint => '在应用名单里调整';

  @override
  String get phoneUnlockNone => '均未开启';

  @override
  String phoneUnlockCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '已开启 $count 项');
    return '$_temp0';
  }

  @override
  String get phoneUnlockedBadge => '已解除限制';

  @override
  String get phoneUnlockConfirmSystemTitle => '允许 AI 操作系统设置？';

  @override
  String get phoneUnlockConfirmSecretsTitle => '允许 AI 填写密码和验证码？';

  @override
  String get phoneUnlockConfirmOwnAppTitle => '允许 AI 操作 DSH Go 自身？';

  @override
  String get phoneUnlockCanTitle => '开启后，AI 可以';

  @override
  String get phoneUnlockRiskTitle => '可能出什么事';

  @override
  String get phoneUnlockDisclaimerTitle => '免责声明';

  @override
  String get phoneUnlockSystemCan1 => '打开和更改系统设置，包括权限、无障碍和开发者选项';

  @override
  String get phoneUnlockSystemCan2 => '在安装器里安装、更新或卸载应用';

  @override
  String get phoneUnlockSystemCan3 => '在安全中心和通知栏里点按，包括通知上的按钮';

  @override
  String get phoneUnlockSystemRisk1 => '网页、消息或文件里的恶意指令可能诱导 AI 关掉保护、给其他应用授权或安装应用';

  @override
  String get phoneUnlockSystemRisk2 => '改错的网络、账号或安全设置，需要你自己改回来';

  @override
  String get phoneUnlockSecretsCan1 => '在密码、验证码和支付密码框里输入';

  @override
  String get phoneUnlockSecretsCan2 => '用它在对话、短信或通知里看到的验证码完成登录或验证';

  @override
  String get phoneUnlockSecretsCan3 => '操作记录里只显示 ••••，不记下填写的内容';

  @override
  String get phoneUnlockSecretsRisk1 => '恶意指令可能诱导 AI 把验证码填到别处，让他人登录你的账号';

  @override
  String get phoneUnlockSecretsRisk2 => '可能完成你并不想要的付款或转账';

  @override
  String get phoneUnlockOwnAppCan1 => '在 DSH Go 里点按和输入，包括修改设置';

  @override
  String get phoneUnlockOwnAppCan2 => '读取 DSH Go 界面上的对话和设置';

  @override
  String get phoneUnlockOwnAppRisk1 => '恶意指令可能诱导 AI 批准它自己发起的操作，或关掉确认';

  @override
  String get phoneUnlockOwnAppRisk2 => '这些界面上的内容会发给模型';

  @override
  String get phoneUnlockDisclaimer1 => '开启后，AI 可以在无人确认的情况下执行上述操作。';

  @override
  String get phoneUnlockDisclaimer2 => 'AI 可能被网页、消息或文件中的内容误导。';

  @override
  String get phoneUnlockDisclaimer3 => '由此造成的账号、资金、数据或设备损失由你自行承担，DSH Go 及其开发者不承担责任。';

  @override
  String get phoneUnlockDisclaimer4 => '建议只在需要时临时开启，用完关闭。';

  @override
  String get phoneUnlockDisclaimer5 => '不建议在存有支付或银行信息的设备上开启。';

  @override
  String get phoneUnlockHold => '我了解风险，开启';

  @override
  String get phoneUnlockHoldHint => '按住按钮约 1.5 秒';

  @override
  String phoneUnlockOnNotice(String name) {
    return '已开启「$name」';
  }

  @override
  String phoneUnlockOffNotice(String name) {
    return '已关闭「$name」';
  }

  @override
  String get searchKwPhoneUnlock => '解除限制,放开限制,密码,验证码,系统设置,自身,风险,免责';

  @override
  String get pluginConfigUnsaved => '未保存';

  @override
  String get pluginConfigSecretSet => '已设置';

  @override
  String get pluginConfigAdvanced => '高级';

  @override
  String get pluginConfigSearchHint => '搜索设置';

  @override
  String get pluginConfigNoMatch => '没有匹配的设置';

  @override
  String get pluginConfigOpenWeb => '在网页版设置';

  @override
  String get pluginConfigOpenWebHint => '插件自带的设置页';

  @override
  String get pluginConfigResetAll => '全部恢复默认';

  @override
  String get pluginConfigResetAllTitle => '全部恢复默认？';

  @override
  String get pluginConfigReset => '恢复';

  @override
  String pluginConfigChanges(int count) {
    return '$count 项更改';
  }

  @override
  String get pluginConfigAppliesOnReload => '保存后重新载入插件';

  @override
  String get pluginConfigSaving => '正在保存…';

  @override
  String get pluginConfigReloading => '正在重新载入…';

  @override
  String get pluginConfigApplied => '已生效';

  @override
  String get pluginConfigFailed => '没能生效';

  @override
  String get pluginConfigRestored => '已恢复原设置';

  @override
  String get pluginConfigStopped => '没能生效，原设置也没能恢复';

  @override
  String get pluginConfigRestore => '恢复原设置';

  @override
  String get pluginConfigDiscard => '放弃';

  @override
  String get pluginConfigNotStarted => '插件没有启动';

  @override
  String get pluginConfigNone => '没有可设置的项';

  @override
  String get pluginConfigInvalidOperation => '这项改动无法应用';

  @override
  String get pluginConfigGone => '插件已不在运行，已刷新';

  @override
  String get pluginConfigUnknown => '连接中断，已重新读取';

  @override
  String get pluginConfigUnsupported => '暂不支持在这里设置';

  @override
  String get pluginConfigSecretUnbound => '需插件适配后设置';

  @override
  String get pluginConfigListFailed => '插件清单读取失败，稍后重试';

  @override
  String get pluginConfigListUpdating => '插件清单正在更新，请稍后再试';

  @override
  String get pluginConfigFixed => '由配置文件固定';

  @override
  String get pluginConfigFixedNote => '由配置文件固定，这里只能查看';

  @override
  String get pluginConfigReadOnly => '只读';

  @override
  String pluginConfigEntryTitle(String bundle, String entry) {
    return '$bundle · $entry';
  }

  @override
  String get pluginConfigNameSpeechToText => '语音识别';

  @override
  String get pluginConfigNameSenseVoice => 'SenseVoice 识别';

  @override
  String get pluginConfigNameSpeechApi => '转写接口';

  @override
  String get pluginConfigNameTranslator => '翻译服务';

  @override
  String get pluginConfigNameSessionIndex => '会话索引';

  @override
  String get pluginConfigNameSessionSearchTool => '会话搜索工具';

  @override
  String get pluginConfigNameTerminalService => '终端服务';

  @override
  String get pluginConfigNameTerminalBash => 'Bash 终端';

  @override
  String get pluginConfigNameTerminalPwsh => 'PowerShell 终端';

  @override
  String get pluginConfigNameTerminalTools => '终端工具';

  @override
  String get pluginConfigNameWorktree => '工作树管理';

  @override
  String get pluginConfigNameWorktreeTools => '工作树工具';

  @override
  String get pluginConfigNameRalphWorkflow => '工作流引擎';

  @override
  String get pluginConfigNameRalphTools => 'Ralph 工具';

  @override
  String get plugInputRequired => '请填写此项';

  @override
  String get plugInputInvalidValue => '此处的值无效';

  @override
  String get plugInputNumber => '请输入有效数字';

  @override
  String plugInputBounds(String min, String max) {
    return '请输入 $min–$max 之间的值';
  }

  @override
  String plugInputLength(int min, int max) {
    return '长度需为 $min–$max 个字符';
  }

  @override
  String get plugInputPattern => '格式不正确';

  @override
  String get plugInputDate => '请选择有效日期';

  @override
  String get plugInputTime => '请选择有效时间';

  @override
  String get plugInputUnavailable => '此处不支持这个组件';

  @override
  String get plugInputNoPassword => '插件不能使用密码输入框';

  @override
  String get plugInputBadBinding => '输入绑定必须是 data 下的字段路径';

  @override
  String get plugInputDuplicateBinding => '一个字段只能绑定一个输入组件';

  @override
  String get plugInputNamedPattern => '只支持内置的格式校验';

  @override
  String get plugInputNestedForm => '表单不能嵌套';

  @override
  String get plugInputSubmitMissing => '表单缺少提交动作';

  @override
  String get plugInputTooLarge => '内容过多，请缩短后重试';

  @override
  String get plugInputCheckFields => '请检查标出的项目';

  @override
  String get plugInputFailed => '未保存，请重试';

  @override
  String get plugInputSubmit => '保存';

  @override
  String get plugInputChoose => '选择';

  @override
  String get plugInputPrevious => '上一页';

  @override
  String get plugInputNext => '下一页';

  @override
  String plugInputDecrease(String label) {
    return '减少$label';
  }

  @override
  String plugInputIncrease(String label) {
    return '增加$label';
  }

  @override
  String plugInputRating(String label, int value, int max) {
    return '$label：$value 分，共 $max 分';
  }

  @override
  String get plugInputFormula => '公式无效或超出上限';

  @override
  String get plugInputDatePicker => '插件日期';

  @override
  String get plugInputTimePicker => '插件时间';

  @override
  String get plugInputChoices => '插件选项';

  @override
  String get plugInputGestureRequired => '该效果需要用户点按';

  @override
  String get seamsTitle => 'App 内界面';

  @override
  String get seamsOverlay => '聊天页浮层';

  @override
  String get seamsOverlayNote => '常驻聊天区域，内存紧张时自动让位';

  @override
  String get seamsSidebarPage => '侧栏入口';

  @override
  String get seamsSettingsPage => '插件设置页';

  @override
  String get seamsDetailPage => '插件详情扩展';

  @override
  String get pluginsOperationHostChanged => '主机已切换，未执行';

  @override
  String get pluginsReloadLocal => '重启内核以重载';

  @override
  String get pluginsReloadInterrupts => '会中断正在运行的任务';

  @override
  String pluginsReloadConfirm(String name) {
    return '重载「$name」？';
  }

  @override
  String get pluginsReloadExplanation => '将重启本机内核，重新加载插件。正在运行的任务会中断。';

  @override
  String get pluginsReloadProceed => '重启并重载';

  @override
  String get pluginsReloadRequested => '已请求重启内核';

  @override
  String get pluginsReloadChanged => '主机或插件状态已变化，请重试';

  @override
  String get pluginsReloadFailed => '未能重启内核，请查看引擎日志';

  @override
  String get pluginsFile => '文件';

  @override
  String get pluginsChat => '对话';

  @override
  String get pluginsImage => '图片';

  @override
  String get pluginsNamespaceDefaultModel => '默认模型';

  @override
  String get pluginsNamespaceDefaultPreset => '默认预设';

  @override
  String get pluginsNamespaceAgent => '智能体';

  @override
  String get pluginsNamespaceSubagent => '子代理';

  @override
  String get pluginsNamespaceSubagentModels => '子代理模型';

  @override
  String get pluginsNamespaceDeepSeekModel => 'DeepSeek 模型';

  @override
  String get pluginsNamespaceAccountModel => 'DeepSeek 账号模型';

  @override
  String get pluginsNamespaceCustomModels => '自定义模型服务';

  @override
  String get pluginsNamespaceNetwork => '联网';

  @override
  String get pluginsNamespaceWebSearch => '联网搜索';

  @override
  String get pluginsNamespaceSearchApi => '联网搜索接口';

  @override
  String get pluginsNamespaceCommands => '命令执行';

  @override
  String get pluginsNamespacePermissions => '权限';

  @override
  String get pluginsNamespaceChatLog => '对话日志';

  @override
  String get pluginsNamespaceThinkingTranslation => '思考翻译';

  @override
  String get pluginsNamespaceTranslation => '翻译';

  @override
  String get pluginsNamespaceLanguage => '语言';

  @override
  String get pluginsNamespaceWebAppearance => '网页版外观';

  @override
  String get pluginsNamespaceWebChat => '网页版对话';

  @override
  String get pluginsNamespaceWebInput => '网页版输入';

  @override
  String get pluginsNamespaceWebSettings => '网页版设置';

  @override
  String get pluginsNamespaceWebGeneral => '网页版通用';

  @override
  String get pluginsNamespaceAutoReview => '自动审查';

  @override
  String get pluginsNamespaceAgentTeam => '智能体团队';

  @override
  String get pluginsNamespaceVoiceInput => '语音输入';

  @override
  String get pluginsOfficialPlugin => '官方插件';

  @override
  String get pluginsLocalUnshareable => '本地安装，无法分享';

  @override
  String pluginsIncludesPresets(String names) {
    return '含预设「$names」';
  }

  @override
  String get pluginsSecretsUnshareable => '含有密钥，无法分享';

  @override
  String pluginsLineCount(int count) {
    return '$count 行';
  }

  @override
  String get pluginsEmptyValue => '空';

  @override
  String get pluginsOnValue => '开';

  @override
  String get pluginsOffValue => '关';

  @override
  String get pluginsOfficialUnavailable => '这台主机没有这个官方插件';

  @override
  String get pluginsEnabled => '已启用';

  @override
  String get pluginsVersionMismatch => '与分享时的版本不一致';

  @override
  String get pluginsCurrentVersion => '当前版本';

  @override
  String get pluginsNewVersion => '新版本';

  @override
  String pluginsAddedWith(String title) {
    return '随「$title」添加';
  }

  @override
  String pluginsApplyAfterInstall(String detail) {
    return '装好插件后应用 · $detail';
  }

  @override
  String get pluginsSettingsReadFailed => '没能读取这台主机的设置';

  @override
  String get pluginsSettingUnavailable => '这台主机没有这项设置';

  @override
  String get pluginsSettingsReadOnly => '这台主机的设置是只读的';

  @override
  String get pluginsImportLocalOnly => '只能导入到本机';

  @override
  String get pluginsReplaceSkill => '替换同名技能';

  @override
  String get pluginsReplaceContent => '替换现有内容';

  @override
  String get pluginsSafeModeInstallBlocked => '安全模式下不能安装插件';

  @override
  String get pluginsHostInstallBlocked => '这台主机不能从这里安装插件';

  @override
  String get pluginsInstallFailed => '安装失败';

  @override
  String get pluginsAfterRestart => '重启后生效';

  @override
  String get pluginsSettingsChanged => '设置刚被改过';

  @override
  String get pluginsWriteFailed => '没能写入';

  @override
  String get pluginsHostUnreachable => '没能连上主机';

  @override
  String get pluginsFileWriteFailed => '没能写入文件';

  @override
  String get pluginsProfileTitle => 'DSH Go 配置';

  @override
  String get pluginsGistTokenInvalid => 'GitHub 令牌无效或没有 Gist 权限';

  @override
  String pluginsGistCreateHttpFailed(int status) {
    return '没能创建 Gist（HTTP $status）';
  }

  @override
  String get pluginsGistCreateFailed => '没能创建 Gist';

  @override
  String get pluginsGitHubUnreachable => '连不上 GitHub';

  @override
  String get pluginsGitHubTimeout => '连接 GitHub 超时';

  @override
  String get pluginsGistNotFound => '找不到这个 Gist';

  @override
  String get pluginsGistNoProfile => '这个 Gist 里没有可导入的配置';

  @override
  String get pluginsGistReadFailed => '没能读取 Gist';

  @override
  String get pluginsListReadFailed => '没能读取插件列表';

  @override
  String get pluginsReadingPlugins => '正在读取插件…';

  @override
  String get pluginsDshOfficial => 'DSH 官方';

  @override
  String get pluginsOfficialToggleOnly => '官方组件只能开关，不能卸载；对这台主机上的所有对话生效';

  @override
  String get pluginsOfficial => '官方';

  @override
  String get pluginsNoThirdParty => '还没装第三方插件';

  @override
  String get pluginsPluginsDescription => '插件能给 DSH 加工具、记忆和模型';

  @override
  String get pluginsBrowseMarket => '逛逛插件市场';

  @override
  String get pluginsLoading => '正在加载';

  @override
  String get pluginsIslandClosed => '插件界面已关闭';

  @override
  String get pluginsReopen => '重新打开';

  @override
  String pluginsOpenBrowserHost(String host) {
    return '在浏览器打开 $host？';
  }

  @override
  String get pluginsSearch => '搜索插件';

  @override
  String get pluginsMarketLoading => '正在载入插件目录…';

  @override
  String get pluginsMarketLoadFailed => '插件目录没打开';

  @override
  String get pluginsMarketInvalid => '目录格式有误';

  @override
  String get pluginsAll => '全部';

  @override
  String pluginsMarketCount(int count) {
    return '$count 个插件 · 来自 dshfind';
  }

  @override
  String get pluginsHideWeb => '隐藏网页版插件';

  @override
  String pluginsShowWebCount(int count) {
    return '显示 $count 个网页版插件';
  }

  @override
  String get pluginsNoCategoryPlugins => '这个分类下没有插件';

  @override
  String pluginsNoSearchResults(String query) {
    return '没有找到「$query」';
  }

  @override
  String pluginsFailureDetails(String title) {
    return '$title · 点开查看';
  }

  @override
  String get pluginsFeatured => '推荐';

  @override
  String pluginsInstalledRemoteRestart(String name, String host) {
    return '已安装「$name」，重启$host上的 DSH 后生效';
  }

  @override
  String pluginsInstalledNamed(String name) {
    return '已安装「$name」';
  }

  @override
  String get pluginsInstallCancelled => '已取消安装';

  @override
  String pluginsInstallFailureNamed(String name, String reason) {
    return '「$name」$reason';
  }

  @override
  String get pluginsRestartRequired => '需要重启引擎';

  @override
  String pluginsRestartExplanation(String name) {
    return '「$name」重启引擎后生效，进行中的回复会中断。';
  }

  @override
  String get pluginsRestartEngine => '重启引擎';

  @override
  String get pluginsAllowBuildScripts => '允许构建脚本？';

  @override
  String get pluginsBuildScriptPackages => '下面这些包要在安装时运行脚本：';

  @override
  String pluginsBuildScriptWarning(String host) {
    return '脚本会以 DSH 的权限在$host上执行，能读写文件、联网。只在你信任这个插件时允许。';
  }

  @override
  String get pluginsThisDevice => '这台设备';

  @override
  String get pluginsAllowRetry => '允许并重试';

  @override
  String pluginsUpdateNamed(String name) {
    return '更新「$name」？';
  }

  @override
  String pluginsUninstallNamed(String title) {
    return '卸载「$title」？';
  }

  @override
  String pluginsUninstallExplanation(String host) {
    return '插件会从$host上移除，它保存的数据和设置不会删除。';
  }

  @override
  String get pluginsThisHost => '这台主机';

  @override
  String get pluginsUninstall => '卸载';

  @override
  String pluginsUninstalledNamed(String title) {
    return '已卸载「$title」';
  }

  @override
  String get pluginsRestartNow => '立即重启';

  @override
  String get pluginsUninstallFailed => '没能卸载';

  @override
  String get pluginsThatComputer => '那台电脑';

  @override
  String get pluginsCommandAfterInstall => '装好后重启那台电脑上的 DSH，再回来刷新';

  @override
  String get pluginsError => '出错';

  @override
  String get pluginsInventoryTitle => '插件清单';

  @override
  String get pluginsGlobalPlugins => '全局插件';

  @override
  String get pluginsAgentPresets => 'Agent 预设';

  @override
  String get pluginsInventoryReadFailed => '没能读取插件清单';

  @override
  String pluginsComponentCount(int count) {
    return '$count 个组件';
  }

  @override
  String pluginsEnabledCount(int count) {
    return '$count 个已启用';
  }

  @override
  String pluginsErrorCount(int count) {
    return '$count 个出错';
  }

  @override
  String get pluginsNoPlugins => '没有插件';

  @override
  String get pluginsNoMatchingPlugins => '没有匹配的插件';

  @override
  String get pluginsPresetLoadFailed => '这个预设没能加载';

  @override
  String get pluginsPresetNoPlugins => '这个预设没有插件';

  @override
  String get pluginsStandard => '标准';

  @override
  String get pluginsMinimal => '精简';

  @override
  String pluginsDefaultPresetName(String name) {
    return '$name（默认）';
  }

  @override
  String get pluginsSystemComponents => '系统组件';

  @override
  String pluginsCount(int count) {
    return '$count 个';
  }

  @override
  String get pluginsSource => '来源';

  @override
  String get pluginsDisableCondition => '禁用条件';

  @override
  String get pluginsProvidedByPreset => '由预设提供';

  @override
  String get pluginsDetailsTitle => '插件详情';

  @override
  String pluginsPackageInfoError(String error) {
    return '包信息有误：$error';
  }

  @override
  String get pluginsInstalling => '安装中';

  @override
  String get pluginsGet => '获取';

  @override
  String get pluginsLoadingCannotCancel => '正在加载插件，这一步不能取消';

  @override
  String get pluginsInstallDuration => '约需一两分钟，可以先离开';

  @override
  String get pluginsViewInstallLogs => '查看安装日志';

  @override
  String get pluginsViewDetails => '查看详情';

  @override
  String get pluginsCopyCommand => '复制命令';

  @override
  String get pluginsCommandCopied => '命令已复制';

  @override
  String get pluginsMissingFiles => '插件文件缺失，重新安装可修复';

  @override
  String get pluginsNotDshPlugin => '不是 DSH 插件，无法加载';

  @override
  String get pluginsIncompatible => '与当前 DSH 版本不兼容，未加载';

  @override
  String pluginsRequiresDshVersion(String requiredVersion, String currentVersion) {
    return '需要 DSH $requiredVersion，当前 $currentVersion，未加载';
  }

  @override
  String pluginsLoadFailure(String reason) {
    return '加载失败：$reason';
  }

  @override
  String get pluginsUnknownReason => '原因未知';

  @override
  String pluginsBundleProblem(String reason) {
    return '有问题：$reason';
  }

  @override
  String pluginsRefreshFailure(String reason) {
    return '刷新失败：$reason';
  }

  @override
  String get pluginsTitle => '插件';

  @override
  String get pluginsRefresh => '刷新';

  @override
  String get pluginsMarketTitle => '插件市场';

  @override
  String get pluginsConnectToManage => '连上引擎后管理插件';

  @override
  String get pluginsSafeModeOperationsBlocked => '安全模式下不能安装或卸载插件';

  @override
  String pluginsRelayToggleOnly(String host) {
    return '$host · 经中转只能开关，安装请在那台电脑上进行';
  }

  @override
  String get pluginsInstallThisPhone => '安装到：本机';

  @override
  String pluginsInstallHost(String host) {
    return '安装到：$host';
  }

  @override
  String get pluginsOfflineDescription => '引擎运行后显示已装插件，插件市场现在就能逛';

  @override
  String get pluginsIconChanged => '桌面图标已选择，回到桌面后更新';

  @override
  String get pluginsIconChangeFailed => '没能更换，稍后再试';

  @override
  String get pluginsTheme => '主题';

  @override
  String get pluginsAppearance => '外观';

  @override
  String get pluginsColors => '配色';

  @override
  String get pluginsFeatureIcons => '功能图标';

  @override
  String get pluginsAppIcon => '桌面图标';

  @override
  String get pluginsPet => '宠物';

  @override
  String get pluginsCustomColor => '自定义';

  @override
  String pluginsColorLabel(String label) {
    return '配色：$label';
  }

  @override
  String get pluginsCoral => '珊瑚';

  @override
  String get pluginsRouge => '胭脂';

  @override
  String get pluginsOchre => '赭石';

  @override
  String get pluginsMoss => '苔绿';

  @override
  String get pluginsLake => '湖蓝';

  @override
  String get pluginsIndigo => '靛紫';

  @override
  String get pluginsHue => '色相';

  @override
  String get pluginsWallpaper => '壁纸';

  @override
  String get pluginsFollowWallpaper => '跟随壁纸';

  @override
  String get pluginsAllowHighPower => '允许后台高耗电';

  @override
  String pluginsVivoBatteryPath(String app) {
    return '电池 › 后台耗电管理 › $app';
  }

  @override
  String get pluginsXiaomiBatterySetting => '省电策略：无限制';

  @override
  String pluginsXiaomiBatteryPath(String app) {
    return '应用管理 › $app › 省电策略';
  }

  @override
  String get pluginsHuaweiBatterySetting => '允许后台活动';

  @override
  String pluginsHuaweiBatteryPath(String app) {
    return '电池 › 应用启动管理 › $app';
  }

  @override
  String get pluginsOppoBatterySetting => '允许后台行为';

  @override
  String pluginsOppoBatteryPath(String app) {
    return '电池 › 应用耗电管理 › $app';
  }

  @override
  String get pluginsSamsungBatterySetting => '电池：不受限制';

  @override
  String pluginsSamsungBatteryPath(String app) {
    return '应用程序 › $app › 电池';
  }

  @override
  String get pluginsVivoBatteryStep => '打开「允许后台高耗电」';

  @override
  String pluginsXiaomiBatteryFullPath(String app) {
    return '应用设置 › 应用管理 › $app › 省电策略 › 无限制';
  }

  @override
  String get pluginsXiaomiAutostart => '同一页打开「自启动」';

  @override
  String get pluginsHuaweiBatteryStep => '关闭「自动管理」，打开「允许后台活动」';

  @override
  String get pluginsOppoBatteryStep => '打开「允许后台行为」';

  @override
  String get pluginsSamsungBatteryStep => '选择「不受限制」';

  @override
  String get pluginsBackgroundTitle => '后台运行';

  @override
  String get pluginsBackgroundDescription => '让对话在后台也能跑完';

  @override
  String get pluginsSystem => '系统';

  @override
  String get pluginsSystemBatteryOptimization => '系统电池优化';

  @override
  String get pluginsTurnedOff => '已关闭';

  @override
  String get pluginsNotTurnedOff => '未关闭';

  @override
  String get pluginsStayOnline => '保持在线';

  @override
  String get pluginsKeepEngineNotification => '保留「引擎运行中」通知';

  @override
  String pluginsLockInRecents(String app) {
    return '在最近任务里锁定 $app';
  }

  @override
  String get pluginsPhoneBrands => '各品牌';

  @override
  String get pluginsOtherBrands => '其他品牌';

  @override
  String pluginsConnectedHost(String host) {
    return '已连接（$host）';
  }

  @override
  String pluginsConnectionError(String error) {
    return '连接失败：$error';
  }

  @override
  String get pluginsConnecting => '正在连接';

  @override
  String get pluginsDiagnosticsCopied => '已复制诊断信息';

  @override
  String get pluginsDiagnostics => '诊断';

  @override
  String get pluginsDiagnosticsDescription => '反馈问题时附上，不含 Key 和令牌';

  @override
  String get pluginsRuntime => '运行环境';

  @override
  String get pluginsArchitecture => '架构';

  @override
  String get pluginsBundledVersion => '内置版本';

  @override
  String get pluginsInstalledVersion => '已安装版本';

  @override
  String get pluginsErrorLabel => '错误';

  @override
  String get pluginsConnection => '连接';

  @override
  String get pluginsAddress => '地址';

  @override
  String get pluginsClient => '客户端';

  @override
  String get pluginsConfigured => '已设置';

  @override
  String get pluginsExport => '导出';

  @override
  String get pluginsCopyDiagnostics => '复制诊断信息';

  @override
  String get pluginsDiagnosticsContents => '只含版本和连接状态';

  @override
  String get pluginsNotificationsPartlyBlocked => '部分被系统关闭';

  @override
  String get pluginsNotificationsBlocked => '系统已关闭';

  @override
  String get pluginsTurnedOn => '已开启';

  @override
  String get pluginsNotifications => '通知';

  @override
  String get pluginsNotificationSettingsFailed => '没能打开系统设置。到「设置 → 应用 → DSH Go → 通知」里开启';

  @override
  String get pluginsSystemNotificationsOff => '系统通知已关闭';

  @override
  String get pluginsBackgroundNoAlerts => 'App 在后台时收不到任何提醒';

  @override
  String get pluginsApprovalNotificationsOff => '「等你确认」通知已关闭';

  @override
  String get pluginsBackgroundNoApprovalAlerts => 'App 在后台时，等你确认不会提醒';

  @override
  String get pluginsDoneNotificationsOff => '「一轮结束」通知已关闭';

  @override
  String get pluginsBackgroundNoDoneAlerts => 'App 在后台时，完成或出错不会提醒';

  @override
  String get pluginsTurnOn => '去开启';

  @override
  String get pluginsNotificationsDescription => '对话完成或需要你时提醒你';

  @override
  String get pluginsAllowNotifications => '允许通知';

  @override
  String get pluginsNotificationsAndBanners => '系统通知与顶部横幅';

  @override
  String get pluginsAlerts => '提醒';

  @override
  String get pluginsRemoteAlertsRequirement => '远程主机的提醒需要 App 在运行、连接在线';

  @override
  String get pluginsTurnComplete => '一轮完成';

  @override
  String get pluginsReplyPreview => '附带回复的开头';

  @override
  String get pluginsErrorOrStopped => '出错或被停下';

  @override
  String get pluginsErrorOrStoppedDescription => '请求失败、引擎重启或被停止';

  @override
  String get pluginsApprovalDescription => '运行命令、改文件等需要批准';

  @override
  String get pluginsQuestions => '向你提问';

  @override
  String get pluginsQuestionsDescription => 'AI 需要你回答';

  @override
  String get pluginsSystemSettings => '系统设置';

  @override
  String get pluginsLockScreenPrivacy => '锁屏不显示对话内容';

  @override
  String get pluginsSoundBannerLockScreen => '声音、横幅与锁屏';

  @override
  String get pluginsEnableFloatingNotifications => '横幅不弹时，开启「悬浮通知」';

  @override
  String get pluginsPersonalPreferences => '个人偏好';

  @override
  String get pluginsPreferencesDescription => '新对话会照这里的要求回答';

  @override
  String get pluginsPreferencesHint => '比如：用中文回答，我主要写 Flutter';

  @override
  String get pluginsSaving => '正在保存';

  @override
  String get pluginsShareLink => '分享链接';

  @override
  String get pluginsInstallPlugin => '安装插件';

  @override
  String get pluginsImportProfile => '导入配置';

  @override
  String get pluginsImportTo => '导入到';

  @override
  String get pluginsInstallTo => '安装到';

  @override
  String get pluginsVerification => '校验';

  @override
  String get pluginsSize => '大小';

  @override
  String get pluginsVerified => '校验通过';

  @override
  String get pluginsVerificationMismatch => '校验不一致';

  @override
  String get pluginsCannotVerify => '无法校验';

  @override
  String get pluginsVerifying => '校验中';

  @override
  String get pluginsPresets => '预设';

  @override
  String get pluginsSkills => '技能';

  @override
  String get pluginsAdded => '新增';

  @override
  String get pluginsModified => '修改';

  @override
  String get pluginsNoChanges => '无需改动';

  @override
  String get pluginsUnavailable => '不可用';

  @override
  String get pluginsHostProfileReadFailed => '没能读取这台主机的配置';

  @override
  String get pluginsAlreadyMatches => '这台主机上已经是这样了';

  @override
  String get pluginsUnsuccessful => '没成功';

  @override
  String get pluginsSkipped => '已跳过';

  @override
  String get pluginsView => '查看';

  @override
  String get pluginsImport => '导入';

  @override
  String get pluginsHostPluginsReadFailed => '没能读取这台主机的插件';

  @override
  String pluginsUpdateTo(String version) {
    return '更新到 $version';
  }

  @override
  String pluginsImportCount(int count) {
    return '导入 $count 项';
  }

  @override
  String get pluginsImporting => '正在导入';

  @override
  String get pluginsInstallingActive => '正在安装';

  @override
  String pluginsImportFailedCount(int count) {
    return '$count 项没成功';
  }

  @override
  String get pluginsCouldNotInstall => '没能安装';

  @override
  String get pluginsEngineRestartToApply => '重启引擎后生效';

  @override
  String pluginsRemoteRestartToApply(String host) {
    return '重启$host上的 DSH 后生效';
  }

  @override
  String pluginsImportedCount(int count) {
    return '已导入 $count 项';
  }

  @override
  String get pluginsLocalPluginUnshareable => '这个插件是本地安装的，无法分享';

  @override
  String get pluginsSharePlugin => '分享插件';

  @override
  String pluginsPluginCount(int count) {
    return '$count 个插件';
  }

  @override
  String pluginsSettingsCount(int count) {
    return '$count 项设置';
  }

  @override
  String pluginsPresetCount(int count) {
    return '$count 个预设';
  }

  @override
  String pluginsSkillCount(int count) {
    return '$count 个技能';
  }

  @override
  String get pluginsNothingSelected => '未选择内容';

  @override
  String get pluginsNext => '下一步';

  @override
  String get pluginsNothingToShare => '没有可以分享的内容';

  @override
  String get pluginsProfileReadFailed => '没能读取配置';

  @override
  String get pluginsShareProfile => '分享配置';

  @override
  String pluginsFileCount(int count) {
    return '$count 个文件';
  }

  @override
  String get pluginsShareNeedsUpdate => '需要更新 App 才能打开';

  @override
  String get pluginsShareUnusable => '这个分享码无法使用';

  @override
  String get pluginsShareDamaged => '这个分享码不完整或已损坏';

  @override
  String get pluginsShareFileReadFailed => '没能读取这个文件';

  @override
  String get pluginsShareOpenFailed => '没能打开这个分享码';

  @override
  String get pluginsPluginShareTitle => 'DSH Go 插件';

  @override
  String get pluginsShareSheetOpenFailed => '没能打开分享';

  @override
  String get pluginsSavePermissionDenied => '没有存储权限，没能保存';

  @override
  String get pluginsQrCode => '二维码';

  @override
  String get pluginsSaveAsFile => '存为文件';

  @override
  String get pluginsGistLinkReady => '已生成 Gist 链接';

  @override
  String get pluginsTooLargeShareFile => '内容较多，以文件分享';

  @override
  String get pluginsGenerateLink => '生成链接';

  @override
  String get pluginsGitHubToken => 'GitHub 令牌';

  @override
  String get pluginsGistPermissionNeeded => '需要 gist 权限';

  @override
  String get pluginsGenerateGistLink => '用 Gist 生成链接';

  @override
  String get pluginsShareQrCode => '分享码二维码';

  @override
  String pluginsUpdateCurrentWarning(String to) {
    return '会先卸载当前版本，再安装 $to。如果新版本没装上，插件会处于未安装状态，需要重新安装。';
  }

  @override
  String pluginsUpdateVersionWarning(String from, String to) {
    return '会先卸载 $from，再安装 $to。如果新版本没装上，插件会处于未安装状态，需要重新安装。';
  }

  @override
  String pluginsUninstalledRestartLocal(String title) {
    return '已卸载「$title」，重启引擎后完全移除';
  }

  @override
  String pluginsUninstalledRestartRemote(String title, String host) {
    return '已卸载「$title」，重启$host上的 DSH 后完全移除';
  }

  @override
  String get pluginsEnableFailed => '没能启用';

  @override
  String get pluginsDisableFailed => '没能停用';

  @override
  String get pluginsEnabledRestartLocal => '已启用，重启引擎后生效';

  @override
  String pluginsEnabledRestartRemote(String host) {
    return '已启用，重启$host上的 DSH 后生效';
  }

  @override
  String get pluginsDisabledRestartLocal => '已停用，重启引擎后生效';

  @override
  String pluginsDisabledRestartRemote(String host) {
    return '已停用，重启$host上的 DSH 后生效';
  }

  @override
  String pluginsRelayCommandInstruction(String host) {
    return '经 DSH Remote 中转时只能开关插件。在$host的终端里运行：';
  }

  @override
  String get pluginsPermissionLocalThirdParty =>
      '插件以 DSH 的权限运行：能读写文件、执行命令、读取 API Key 和已授权的手机存储，不受工作区沙箱限制。由第三方提供，DSH 官方未审核。';

  @override
  String get pluginsPermissionLocalTrusted => '插件以 DSH 的权限运行：能读写文件、执行命令、读取 API Key 和已授权的手机存储，不受工作区沙箱限制。只装你信任的插件。';

  @override
  String get pluginsPermissionRemoteThirdParty => '插件以 DSH 的权限运行：能读写文件、执行命令、读取 API Key，不受工作区沙箱限制。由第三方提供，DSH 官方未审核。';

  @override
  String get pluginsPermissionRemoteTrusted => '插件以 DSH 的权限运行：能读写文件、执行命令、读取 API Key，不受工作区沙箱限制。只装你信任的插件。';

  @override
  String pluginsSelectedQrCount(int count) {
    return '已选 $count 项 · 可生成二维码';
  }

  @override
  String pluginsSelectedFileCount(int count) {
    return '已选 $count 项 · 以文件分享';
  }

  @override
  String get pluginsListSeparator => '、';

  @override
  String pluginsActionFailure(String action, String reason) {
    return '$action：$reason';
  }

  @override
  String pluginsInventorySemantics(String title, String status) {
    return '$title，$status';
  }

  @override
  String pluginsSettingsChanges(String shown, int count) {
    return '$shown 等 $count 项';
  }

  @override
  String get pluginsLoadStatus => '加载状态';

  @override
  String get pluginsLoadPartial => '部分生效';

  @override
  String get pluginsLoadFailed => '加载失败';

  @override
  String get pluginsLoadNotReady => '尚未就绪';

  @override
  String get pluginsLoadMetadata => '元数据诊断';

  @override
  String pluginsLoadRunningCount(int running, int total) {
    return '$running / $total 个组件运行中';
  }

  @override
  String get pluginsLoadUnreported => '状态未报告';

  @override
  String get pluginsLoadNoRuntimeDetail => '主机未返回运行时错误详情，请查看引擎日志。';

  @override
  String get pluginsLoadRemoteLogs => '请在这台主机上查看引擎日志。';

  @override
  String get plugslotsSurfaceComposerTools => '加号面板';

  @override
  String get plugslotsSurfaceSessionActions => '对话操作';

  @override
  String get plugslotsSurfaceTurnNote => '回合尾注';

  @override
  String get plugslotsSurfaceComposerActions => '输入框按钮';

  @override
  String get plugslotsSurfaceMessageActions => '消息菜单';

  @override
  String get plugslotsSurfaceComposerStrip => '状态条';

  @override
  String get plugslotsSurfacePanel => '面板';

  @override
  String get plugslotsNativeUi => '原生界面';

  @override
  String plugslotsIssueCount(int count) {
    return '$count 项有误';
  }

  @override
  String get plugslotsAllGood => '正常';

  @override
  String plugslotsViewSize(String size) {
    return '视图 $size';
  }

  @override
  String plugslotsInvokeMs(int ms) {
    return '响应 $ms ms';
  }

  @override
  String get plugslotsLastView => '最近视图';

  @override
  String get plugslotsLastInvoke => '最近响应';

  @override
  String get plugslotsProblems => '问题';

  @override
  String get plugslotsNoProblems => '没有问题';

  @override
  String plugslotsWantsDraft(String plugin) {
    return '「$plugin」要读取输入框';
  }

  @override
  String plugslotsWantsClipboard(String plugin) {
    return '「$plugin」要读取剪贴板';
  }

  @override
  String plugslotsWantsBoth(String plugin) {
    return '「$plugin」要读取输入框和剪贴板';
  }

  @override
  String get plugslotsWantsWhen => '只在点按它时读取';

  @override
  String get plugslotsAllow => '允许';

  @override
  String plugslotsNoResponse(String plugin) {
    return '「$plugin」没有响应';
  }

  @override
  String plugslotsFailed(String plugin) {
    return '「$plugin」出错了';
  }

  @override
  String get plugslotsNeedsChat => '先打开一个对话';

  @override
  String plugslotsFromPlugin(String plugin) {
    return '来自「$plugin」';
  }

  @override
  String get plugslotsPanelOffline => '连不上插件';

  @override
  String plugslotsIssueTooMany(int max) {
    return '最多 $max 个，其余不显示';
  }

  @override
  String plugslotsIssueTrimmed(int max) {
    return '超过 $max 字，已截断';
  }

  @override
  String plugslotsIssueNeedsApp(String version) {
    return '需要 DSH Go $version 或更新版本';
  }

  @override
  String get plugslotsIssueNewerProtocol => '需要更新 App';

  @override
  String get plugslotsIssueUnknownIcon => '不认识的图标，已换成默认图标';

  @override
  String plugslotsIssueUnknownEffect(String name) {
    return '不支持的效果「$name」';
  }

  @override
  String get plugslotsIssueLate => '点按 3 秒后才返回，已忽略';

  @override
  String get plugslotsIssueHttps => '只支持 https 链接';

  @override
  String plugslotsIssueUnknownPage(String page) {
    return '没有「$page」这个页面';
  }

  @override
  String get plugslotsIssueThrottled => '提示太频繁，已略过';

  @override
  String plugslotsIssueInvoke(String message) {
    return '调用失败：$message';
  }

  @override
  String plugslotsIssueStream(String message) {
    return '数据出错：$message';
  }

  @override
  String get plugslotsIssueMissing => '缺少必填项';

  @override
  String get plugslotsIssueDuplicate => 'id 重复，已略过';

  @override
  String get plugslotsIssueNoPlacement => '没有可放的位置';

  @override
  String plugslotsWantsMessage(String plugin) {
    return '「$plugin」要读取这条回复';
  }

  @override
  String get plugslotsCodeInvalidManifest => '声明有误，原生部分已停用';

  @override
  String get plugslotsCodeInvalidField => '格式不对，已略过';

  @override
  String get plugslotsCodeUnknownField => '不认识的字段，已忽略';

  @override
  String get plugslotsCodeUnknownSurface => '这个位置还不支持，已忽略';

  @override
  String get plugslotsCodeTooMany => '超出数量，多余的不显示';

  @override
  String get plugslotsCodeTooLong => '文字太长，已截断';

  @override
  String get plugslotsCodeNoHandler => '插件还没处理这一项，暂不显示';

  @override
  String get plugslotsCodeUndeclared => '注册了清单里没有的项，已忽略';

  @override
  String get plugslotsCodeViewFile => '视图文件读不出';

  @override
  String get plugslotsCodeBadEffect => '动作格式不对，已略过';

  @override
  String plugslotsCodeViolation(int count) {
    return '出错 $count 次';
  }

  @override
  String get plugslotsCodeDegraded => '出错太多，已停用到下次启动';

  @override
  String get plugslotsCodeTimeout => '插件没有及时响应';

  @override
  String get plugslotsCodeRateLimited => '点得太快了';

  @override
  String get plugslotsCodeNotFound => '插件已停用或找不到';

  @override
  String get plugslotsCodePluginError => '插件出错';

  @override
  String get plugslotsCodeInvalidView => '视图有误';

  @override
  String get plugslotsCodeLimit => '订阅太多';

  @override
  String get plugslotsCodeOther => '其他问题';

  @override
  String get plugslotsCodeUnknownEffect => '不支持的动作，已略过';

  @override
  String get plugslotsNotDone => '没完成';

  @override
  String get plugslotsWorking => '进行中';

  @override
  String get plugslotsTapToCancel => '点按取消';

  @override
  String get plugslotsCodeTooManyPending => '还有两件没做完';

  @override
  String get plugslotsCodeNoStream => '连接断了';

  @override
  String plugslotsVoiceAsk(String plugin) {
    return '允许「$plugin」听你开口？';
  }

  @override
  String get plugslotsVoiceWhen => '朗读时你一开口就停。声音只在手机上判断，不保存、不上传';

  @override
  String get plugslotsVoiceDeny => '不允许';

  @override
  String get plugslotsVoiceSwitch => '听你开口';

  @override
  String get plugslotsPickerUnavailable => '此设备暂不支持文件选择';

  @override
  String get plugslotsPickerBusy => '请先完成当前文件选择';

  @override
  String plugslotsPickerLimit(int count) {
    return '最多选 $count 个文件，单个 8 MiB，总计 16 MiB';
  }

  @override
  String get plugslotsPickerFailed => '文件未能交给插件，请重试';

  @override
  String get plugslotsWebPlacesTitle => '网页版界面';

  @override
  String get plugslotsPlaceBesideComposer => '输入框旁';

  @override
  String get plugslotsPlaceHeader => '对话顶栏';

  @override
  String get plugslotsPlaceMessages => '消息里';

  @override
  String get plugslotsPlaceOverlay => '浮层';

  @override
  String get plugslotsPlaceSidebar => '侧栏';

  @override
  String get plugslotsPlaceRightbar => '右侧栏';

  @override
  String get plugslotsPlaceFiles => '文件预览';

  @override
  String get plugslotsPlaceSettings => '设置';

  @override
  String get plugslotsPlacePlugins => '插件页';

  @override
  String get plugslotsPlaceNewChat => '新对话页';

  @override
  String get plugslotsPlaceElsewhere => '其他位置';

  @override
  String get plugslotsPlaceUnknown => '它的网页界面';

  @override
  String get plugslotsChatEntry => '插件';

  @override
  String plugslotsChatWebFrom(String names) {
    return '网页插件 · $names';
  }

  @override
  String get plugViewInvalid => '插件界面有误';

  @override
  String get plugViewEmpty => '暂无数据';

  @override
  String get plugViewImageUnavailable => '图片无法显示';

  @override
  String get plugViewUnavailableList => '列表无法显示';

  @override
  String get plugViewUnavailableKeyValue => '信息无法显示';

  @override
  String get plugViewUnavailableProgress => '进度无法显示';

  @override
  String get plugViewUnavailableTable => '表格无法显示';

  @override
  String get plugViewUnavailableActions => '按钮无法显示';

  @override
  String plugViewFrom(String name) {
    return '来自 $name';
  }

  @override
  String plugViewUnknownTone(String value) {
    return '未知 tone $value，已忽略；可用：good, warn, bad, info, muted';
  }

  @override
  String plugViewBadActionId(String value) {
    return '动作 id $value 不合规，这个元素不可点';
  }

  @override
  String plugViewBadAction(String shape) {
    return '动作应该是 id 字符串或 $shape，已忽略';
  }

  @override
  String plugViewArgsLimit(int limit) {
    return '动作参数超过 $limit 字节，已忽略';
  }

  @override
  String plugViewUnknownIcon(String value) {
    return '未知图标 $value，画默认图标';
  }

  @override
  String plugViewExpectedItems(String shape) {
    return '应该是数组，每项是 $shape';
  }

  @override
  String plugViewSkippedItem(String shape) {
    return '应该是 $shape，这项已跳过';
  }

  @override
  String get plugViewBadMax => 'max 应该是大于 0 的数，按 100 算';

  @override
  String plugViewColumnLimit(int first, int second) {
    return '$first 列，超过上限 $second';
  }

  @override
  String plugViewFirstColumns(int limit) {
    return '只显示前 $limit 列';
  }

  @override
  String plugViewFirstRows(int limit) {
    return '只显示前 $limit 行';
  }

  @override
  String get plugViewOnePrimary => '一张视图只能有一个主按钮，这个按普通按钮画';

  @override
  String get plugViewBadImageSource => '图片只收插件资源 asset:<路径>（png、jpg、webp、gif）或 data:image/…';

  @override
  String get plugViewBadAspect => 'aspect 应该是 0.25 到 4 之间的数，已忽略';

  @override
  String plugViewImageTooLarge(int limit) {
    return 'data: 图片超过 $limit 字节';
  }

  @override
  String get plugViewImageDecode => '图片无法解码（只收 PNG、JPEG、WebP、GIF）';

  @override
  String get plugViewImagePixels => '图片尺寸超过上限：单边 4096、总数 400 万像素';

  @override
  String plugViewTooDeep(int limit) {
    return 'JSON 嵌套超过 $limit 层';
  }

  @override
  String get plugViewV2Content => '插件内容';

  @override
  String plugViewVersionFallback(String version) {
    return '暂不支持视图版本 $version，已使用兼容显示';
  }

  @override
  String plugViewStyleInvalid(String values) {
    return '样式无效，支持 $values';
  }

  @override
  String get plugViewStyleReserved => '此样式由 App 保留，已忽略';

  @override
  String get plugViewStyleContainerOnly => '此样式仅用于 stack 和 row';

  @override
  String get plugViewStyleTextOnly => '此样式仅用于 text、metric 和 callout';

  @override
  String plugViewContrastAdjusted(String mode, String before, String after, String minimum) {
    return '$mode：$before 已校正为 $after，对比度至少 $minimum:1';
  }

  @override
  String get plugViewRichLimit => '富文本超出上限，已截断';

  @override
  String plugViewBadTrend(int max) {
    return 'trend 要 2–$max 个数字（可以有 null），已忽略';
  }

  @override
  String plugViewGalleryPicture(int index) {
    return '第 $index 张';
  }

  @override
  String get readListUpdating => '更新中 · 上次结果';

  @override
  String get readListOffline => '离线 · 上次结果';

  @override
  String get readListFailed => '未更新 · 上次结果';

  @override
  String get remoteDshMode => '实例管理';

  @override
  String get remoteManaged => '托管启动';

  @override
  String get remoteAttachOnly => '只连接';

  @override
  String get remoteManagedHelp => '自动启动或复用 App 托管的 DSH；不会自动替换存活但无法复用的实例。';

  @override
  String get remoteAttachOnlyHelp => '只转发到远端 127.0.0.1 的固定端口；不启动、停止或重启 DSH。';

  @override
  String get remoteDshPort => '远端 DSH 端口';

  @override
  String get remoteDshToken => 'DSH 登录令牌';

  @override
  String get remoteDshTokenHelp => '填写既有实例启动链接中的 token，仅保存在这台手机的安全存储中。';

  @override
  String get remoteAttachWorkingDirectoryHelp => '既有实例不执行目录探测；请填写远端绝对路径，留空使用 DSH 默认目录。';

  @override
  String get remoteSshCompression => 'SSH 压缩';

  @override
  String get remoteSshCompressionHelp => '默认开启；与服务器协商认证后压缩，不支持时使用未压缩传输。';

  @override
  String get remoteRestartManaged => '重启托管 DSH';

  @override
  String get remoteRestartManagedWarning => '这会停止 App 记录的远端 DSH 并重新启动，可能中断其他客户端和进行中的对话。确认没有其他人在使用后再继续。普通测试连接不会执行此操作。';

  @override
  String get remoteErrSharedInstance =>
      '远端托管 DSH 仍在运行，但启动命令不同或缺少有效启动日志。为保护共享实例，未自动重启；请检查配置，改用“只连接”，或在编辑主机中明确选择“重启托管 DSH”。';

  @override
  String get remoteErrAttachSettings => '请填写有效的远端 DSH 端口和登录令牌';

  @override
  String get remoteDshAttached => '已连接既有 DSH';

  @override
  String get remoteConnectionSettings => '连接设置';

  @override
  String get remoteAutoConnectOnStartup => '连接上次使用的主机';

  @override
  String get remoteAutoConnectOnStartupHint => '关闭后从本机开始';

  @override
  String get remoteStepConnect => '连接服务器';

  @override
  String get remoteStepVerifyHostKey => '验证主机指纹';

  @override
  String get remoteStepStartDsh => '启动 DSH';

  @override
  String get remoteStepTunnel => '建立隧道';

  @override
  String get remoteConnecting => '正在连接';

  @override
  String get remoteConnected => '已连接';

  @override
  String get remoteReconnecting => '重新连接中';

  @override
  String remoteReconnectAttempt(int count) {
    return '重新连接中 · 第 $count 次';
  }

  @override
  String get remoteErrInvalidServer => '服务器地址无效';

  @override
  String get remoteErrEmailPassword => '邮箱或密码不对';

  @override
  String get remoteErrHostNotInAccount => '账号下找不到这台主机';

  @override
  String get remoteHostFallback => '这台主机';

  @override
  String get remoteErrHostOffline => '主机现在不在线';

  @override
  String remoteErrHostRemoved(String name) {
    return '$name已不在你的 DSH Remote 账号下';
  }

  @override
  String get remoteErrRelaySignInExpired => 'DSH Remote 登录已失效';

  @override
  String get remoteErrIdentityKeyChanged => '主机身份密钥和上次不一致';

  @override
  String get remoteErrIdentityUnconfirmed => '还没有确认主机身份指纹';

  @override
  String get remoteErrConnectionReplaced => '远程连接已被替换';

  @override
  String get remoteErrHostRejected => '主机拒绝了连接';

  @override
  String get remoteErrHostNotOwned => '主机不在你的 DSH Remote 账号下';

  @override
  String get remoteErrUpdateNeeded => '版本不匹配，请更新 DSH Go 和主机上的远程插件';

  @override
  String get remoteErrVersionIncompatible => '主机上的 DSH 或远程插件需要更新';

  @override
  String get remoteErrSignInTimeout => '登录超时';

  @override
  String get remoteSignInCancelled => '已取消登录';

  @override
  String get remoteErrBrowserSignInUnsupported => '服务器不支持浏览器登录';

  @override
  String get remoteErrTooManyRequests => '请求太频繁';

  @override
  String get remoteErrHostUnreachable => '没能连上远程主机';

  @override
  String get remoteErrRemoteConnection => '远程连接失败';

  @override
  String get remoteOnline => '在线';

  @override
  String get remoteOffline => '离线';

  @override
  String get remoteUnavailable => '暂不可用';

  @override
  String get remoteErrHostNotFound => '找不到这台主机';

  @override
  String get remoteConnectionStopped => '远程连接已停止';

  @override
  String remoteBootstrapReusePort(int port) {
    return '复用已在运行的 DSH（端口 $port）';
  }

  @override
  String get remoteBootstrapStarting => '正在远端启动 DSH…';

  @override
  String remoteErrCommandNotFound(String command) {
    return '远端找不到「$command」';
  }

  @override
  String get remoteErrDshMissing => '主机上没有 dsh，装好后重试，或在启动命令里填完整路径';

  @override
  String get remoteStartCommandExample => '启动命令示例：~/.nvm/versions/node/v22.0.0/bin/dsh web';

  @override
  String get remoteErrDshStartTimeout => '远端 DSH 启动超时';

  @override
  String get remoteErrDshExited => '远端 DSH 启动后立即退出';

  @override
  String get remoteErrDshStart => '没能在远端启动 DSH';

  @override
  String remoteExitCode(int code) {
    return '退出码 $code';
  }

  @override
  String get remoteErrNoShell => '主机上没有 sh，只支持 Linux 和 macOS';

  @override
  String get remoteErrFingerprintChanged => '主机指纹和上次不一致，已断开';

  @override
  String get remoteErrFingerprintUnconfirmed => '还没有确认主机指纹';

  @override
  String get remoteHostTrustCancelled => '已取消信任主机';

  @override
  String get remoteCheckingDsh => '检查远端的 DSH…';

  @override
  String get remoteErrDshPort => '远端 DSH 端口连不上';

  @override
  String get remoteDshReused => '复用了远端已在运行的 DSH';

  @override
  String get remoteDshStarted => '已在远端启动 DSH';

  @override
  String get remoteErrDshTokenRejected => '远端 DSH 拒绝了登录令牌，未自动重启；请检查令牌，或在编辑主机中明确重启托管实例';

  @override
  String get remoteErrDshSignIn => '没能登录远端 DSH';

  @override
  String get remoteErrDshTunnel => '没能通过隧道连接 DSH';

  @override
  String get remoteErrDshSignInExpired => '远端 DSH 登录已失效';

  @override
  String get remoteErrDshStopped => '远端 DSH 已停止运行';

  @override
  String get remoteErrSshDisconnected => 'SSH 连接已断开';

  @override
  String get remoteErrSshUnresponsive => 'SSH 连接没有响应';

  @override
  String remoteRetryCount(int count) {
    return '已重试 $count 次';
  }

  @override
  String get remoteErrSshNetworkChanged => '网络变化后 SSH 连接已断开';

  @override
  String get remoteErrReadFingerprint => '没能读到主机指纹';

  @override
  String get remoteErrNoFingerprint => '服务器没有提供主机指纹';

  @override
  String get remoteErrPasswordMissing => '还没有填写密码';

  @override
  String remoteErrAddressUnresponsive(String host, int port) {
    return '$host:$port 没有响应';
  }

  @override
  String get remoteErrPrivateKeyMissing => '还没有填写私钥';

  @override
  String get remoteErrKeyNeedsPassword => '这把私钥需要密码';

  @override
  String get remoteErrKeyPassword => '私钥密码不对';

  @override
  String get remoteErrKeyUnreadable => '私钥无法读取';

  @override
  String remotePrivateKeyFormats(String error) {
    return '支持 OpenSSH 与 PEM 格式的 Ed25519、RSA、ECDSA 私钥。\n$error';
  }

  @override
  String remoteErrAddressRejected(String address) {
    return '$address 拒绝了连接';
  }

  @override
  String remoteErrSshHostNotFound(String host) {
    return '找不到主机 $host';
  }

  @override
  String remoteErrSshAddressUnresponsive(String address) {
    return '$address 没有响应';
  }

  @override
  String get remoteErrUsernamePassword => '用户名或密码不对';

  @override
  String get remoteErrPrivateKeyRejected => '服务器不接受这把私钥';

  @override
  String remoteAuthorizedKeysHelp(String username, String error) {
    return '确认公钥已加入 $username 的 ~/.ssh/authorized_keys。\n$error';
  }

  @override
  String get remoteErrFingerprintUntrusted => '主机指纹未被信任';

  @override
  String get remoteErrSshHandshakeTimeout => 'SSH 握手超时';

  @override
  String get remoteErrSshInterrupted => 'SSH 连接已中断';

  @override
  String get remoteErrSshConnection => 'SSH 连接失败';

  @override
  String get remoteErrCommandTimeout => '远端命令超时';

  @override
  String get remoteHostedErrNetwork => '没能连上分享服务，检查网络后重试';

  @override
  String get remoteHostedErrTooLarge => '对话太大，生成不了链接';

  @override
  String get remoteHostedErrRateLimited => '分享太频繁，稍后再试';

  @override
  String get remoteHostedErrCreate => '没能生成链接';

  @override
  String get remoteHostedErrUnavailable => '分享服务暂时不可用，稍后再试';

  @override
  String get remoteHostedErrGone => '链接已过期或被删除';

  @override
  String get remoteHostedErrForbidden => '没有权限删除这个链接';

  @override
  String get remoteHostedErrBroken => '链接不完整或已损坏';

  @override
  String get remoteChat => '对话';

  @override
  String get remoteHostedTtlWeek => '7 天';

  @override
  String get remoteHostedTtlMonth => '30 天';

  @override
  String get remoteHostedTtlForever => '永久';

  @override
  String get remoteForumSignIn => '登录论坛';

  @override
  String get remoteForumSignInBenefits => '发帖、回复、点赞';

  @override
  String get remoteForumFinishSignIn => '在浏览器里完成登录';

  @override
  String get remoteReopenBrowser => '重新打开浏览器';

  @override
  String get remoteForumSettings => '论坛设置';

  @override
  String get remoteForumAccount => '论坛账号';

  @override
  String get remoteForumTopic => '话题';

  @override
  String get remoteForumLikesReceived => '获赞';

  @override
  String get remoteForumDaysVisited => '访问天数';

  @override
  String get remoteForumNotifications => '通知';

  @override
  String remoteForumUnreadCount(int count) {
    return '$count 条未读';
  }

  @override
  String get remoteForumErrAddress => '地址不对';

  @override
  String get remoteForumAddress => '论坛地址';

  @override
  String remoteForumDefaultAddress(String host) {
    return '默认：$host';
  }

  @override
  String get remoteRestoreDefault => '恢复默认';

  @override
  String get remoteForumUploadingImage => '正在上传图片…';

  @override
  String get remoteForumErrUploadImage => '图片没传上去';

  @override
  String get remoteForumTitleRequired => '先写标题';

  @override
  String get remoteForumCategoryRequired => '选一个分类';

  @override
  String get remoteForumBodyRequired => '写点内容再发';

  @override
  String remoteForumReplyCaption(String username, String title) {
    return '回复 @$username · $title';
  }

  @override
  String get remoteForumNewTopic => '新话题';

  @override
  String get remoteForumTitle => '标题';

  @override
  String get remoteForumComposerHint => '写点什么，支持 Markdown';

  @override
  String get remoteForumPublish => '发布';

  @override
  String get remoteForumImage => '图片';

  @override
  String get remoteForumAttachShareCode => '附上分享码';

  @override
  String get remoteForumPendingApproval => '已提交，审核后可见';

  @override
  String get remoteForumLatest => '最新';

  @override
  String get remoteForumTop => '热门';

  @override
  String get remoteForumErrOpen => '没能打开论坛';

  @override
  String get remoteForumNoTopics => '还没有话题';

  @override
  String get remoteForumPost => '发帖';

  @override
  String get remoteForum => '论坛';

  @override
  String remoteForumNotificationsUnread(int count) {
    return '通知，$count 条未读';
  }

  @override
  String get remoteForumSearch => '搜索';

  @override
  String get remoteForumSearchHint => '搜索话题和帖子';

  @override
  String get remoteForumSignedIn => '已登录论坛';

  @override
  String get remoteForumSignInForNotifications => '登录后查看通知';

  @override
  String get remoteForumErrNotifications => '没能读取通知';

  @override
  String get remoteForumNoNotifications => '还没有通知';

  @override
  String get remoteForumMarkAllRead => '全部已读';

  @override
  String get remoteForumSomeone => '有人';

  @override
  String remoteForumNotificationMention(String who) {
    return '$who 提到了你';
  }

  @override
  String remoteForumNotificationGroupMention(String who) {
    return '$who 提到了你所在的群组';
  }

  @override
  String remoteForumNotificationReply(String who) {
    return '$who 回复了你';
  }

  @override
  String remoteForumNotificationQuote(String who) {
    return '$who 引用了你';
  }

  @override
  String remoteForumNotificationEdit(String who) {
    return '$who 编辑了你的帖子';
  }

  @override
  String remoteForumNotificationLikes(String who, int count) {
    return '$who 等 $count 人赞了你';
  }

  @override
  String remoteForumNotificationLike(String who) {
    return '$who 赞了你';
  }

  @override
  String remoteForumNotificationLikedPosts(String who, int count) {
    return '$who 赞了你的 $count 个帖子';
  }

  @override
  String remoteForumNotificationReaction(String who) {
    return '$who 回应了你';
  }

  @override
  String remoteForumNotificationMessage(String who) {
    return '$who 发来私信';
  }

  @override
  String remoteForumNotificationMessageInvite(String who) {
    return '$who 邀请你加入私信';
  }

  @override
  String remoteForumNotificationTopicInvite(String who) {
    return '$who 邀请你参与话题';
  }

  @override
  String remoteForumNotificationNewReply(String who) {
    return '$who 发了新回复';
  }

  @override
  String remoteForumNotificationNewTopic(String who) {
    return '$who 发了新话题';
  }

  @override
  String remoteForumNotificationLink(String who) {
    return '$who 链接了你的帖子';
  }

  @override
  String remoteForumNotificationBadge(String badge) {
    return '获得徽章「$badge」';
  }

  @override
  String remoteForumNotificationMoved(String who) {
    return '$who 移动了你的帖子';
  }

  @override
  String get remoteForumBookmarkReminder => '书签提醒';

  @override
  String get remoteForumTopicReminder => '话题提醒';

  @override
  String get remoteForumPostApproved => '你的帖子已通过审核';

  @override
  String get remoteForumAdminProblems => '论坛有待处理的问题';

  @override
  String get remoteForumNewNotification => '新通知';

  @override
  String get remoteForumUnread => '未读';

  @override
  String get remoteForumErrShareCode => '没能打开分享码';

  @override
  String get remoteForumPoll => '投票';

  @override
  String get remoteForumVideo => '视频';

  @override
  String get remoteForumEmbed => '嵌入内容';

  @override
  String get remoteForumVoteOnWeb => '去网页版投票';

  @override
  String get remoteForumErrSearch => '没能搜索';

  @override
  String remoteForumNoSearchResults(String term) {
    return '没有找到「$term」';
  }

  @override
  String get remoteForumBookmarkRemoved => '已取消书签';

  @override
  String get remoteForumBookmarkAdded => '已加入书签';

  @override
  String get remoteLinkCopied => '已复制链接';

  @override
  String get remoteForumErrTopic => '没能打开这个话题';

  @override
  String get remoteForumTopicClosed => '话题已关闭';

  @override
  String get remoteForumReplyHint => '写回复…';

  @override
  String get remoteForumSignInToReply => '登录后回复';

  @override
  String remoteForumReplyTo(String username) {
    return '回复 @$username';
  }

  @override
  String get remoteForumPostDeleted => '帖子已删除';

  @override
  String get remoteForumPostHidden => '帖子已被隐藏';

  @override
  String get remoteForumUnlike => '取消点赞';

  @override
  String get remoteForumLike => '点赞';

  @override
  String get remoteForumRemoveBookmark => '取消书签';

  @override
  String get remoteForumBookmark => '书签';

  @override
  String get remoteForumActionPinned => '置顶了话题';

  @override
  String get remoteForumActionUnpinned => '取消了置顶';

  @override
  String get remoteForumActionClosed => '关闭了话题';

  @override
  String get remoteForumActionReopened => '重新开放了话题';

  @override
  String get remoteForumActionAutoClosed => '话题已自动关闭';

  @override
  String get remoteForumActionAutoOpened => '话题已自动开放';

  @override
  String get remoteForumActionArchived => '归档了话题';

  @override
  String get remoteForumActionUnarchived => '取消了归档';

  @override
  String get remoteForumActionListed => '公开了话题';

  @override
  String get remoteForumActionUnlisted => '隐藏了话题';

  @override
  String get remoteForumActionSplit => '拆分了话题';

  @override
  String get remoteForumActionBanner => '设为横幅';

  @override
  String get remoteForumActionRemoveBanner => '取消了横幅';

  @override
  String get remoteForumActionUpdated => '更新了话题';

  @override
  String get remoteLoading => '正在加载';

  @override
  String get remoteForumJustNow => '刚刚';

  @override
  String remoteForumMinutesAgo(int count) {
    return '$count 分钟前';
  }

  @override
  String remoteForumHoursAgo(int count) {
    return '$count 小时前';
  }

  @override
  String remoteForumDaysAgo(int count) {
    return '$count 天前';
  }

  @override
  String remoteForumReplyCount(int count) {
    return '$count 回复';
  }

  @override
  String remoteForumNewReplyCount(int count) {
    return '$count 条新回复';
  }

  @override
  String get remoteForumNew => '新';

  @override
  String remoteForumErrorRetry(String error) {
    return '$error · 重试';
  }

  @override
  String get remoteForumNoMore => '没有更多了';

  @override
  String get remoteHostKeyTrustTitle => '信任这台主机？';

  @override
  String remoteHostKeyFirstConnection(String name, String address) {
    return '首次连接「$name」（$address）。核对指纹，确认是你自己的主机。';
  }

  @override
  String get remoteHostKeyTrustConnect => '信任并连接';

  @override
  String get remoteHostKeyChangedTitle => '身份指纹变了';

  @override
  String remoteRelayKeyChangedBody(String name) {
    return '「$name」的身份密钥和上次不一样。只在确认这台主机重装过远程插件时继续，否则可能有人冒充它。';
  }

  @override
  String remoteRelayKeyFirstBody(String name) {
    return '首次连接「$name」。核对身份指纹，与主机上远程插件显示的一致再继续。';
  }

  @override
  String get remoteHostKeyChangeWarning => '之后指纹一旦变化，App 会拒绝连接。';

  @override
  String get remoteHostKeyTrustAgain => '重新信任';

  @override
  String get remoteHostKeyReading => '正在读取主机指纹…';

  @override
  String remoteHostSwitcherSemantics(String name, String status) {
    return '当前主机：$name，$status。切换主机';
  }

  @override
  String get remoteSwitchHost => '切换主机';

  @override
  String get remoteThisPhoneDsh => '这台手机上的 DSH';

  @override
  String get remoteRemoteLabel => '远程';

  @override
  String remoteRemotePlatform(String platform) {
    return '远程 · $platform';
  }

  @override
  String get remoteRelaySwitchWarning => 'DSH Remote 一次只连一台主机，切换会断开上一台';

  @override
  String get remoteConnectComputer => '连接电脑或服务器';

  @override
  String get remoteManageHosts => '管理远程主机';

  @override
  String get remoteConnectionMethods => '通过 SSH 或 DSH Remote';

  @override
  String get remoteRelayLoginRequired => '填写服务器地址、邮箱和密码';

  @override
  String get remoteErrSignIn => '没能登录';

  @override
  String get remoteSelfHostedServer => '自建服务器';

  @override
  String get remoteSelfHostedSignInHelp => '填写服务器地址，可用邮箱密码登录，也可先使用此服务器再选择其他登录方式。';

  @override
  String get remoteUseServer => '使用此服务器';

  @override
  String get remoteServerAddress => '服务器地址';

  @override
  String get remoteEmail => '邮箱';

  @override
  String get remotePassword => '密码';

  @override
  String get remoteRestoreServer => '改回默认服务器 dsh.r2049.cn';

  @override
  String get remoteConsole => '远程控制台';

  @override
  String get remoteHostsIntro => '在手机上接着用电脑或服务器上的 DSH';

  @override
  String get remoteSshHosts => 'SSH 主机';

  @override
  String get remoteSshRequirements => '需要那台主机开着 SSH，并装好 DSH';

  @override
  String get remoteAddSshHost => '添加 SSH 主机';

  @override
  String get remoteSshDirect => '不经过第三方服务器';

  @override
  String get remoteWebConsole => '网页版远程控制台';

  @override
  String get remoteWebConsoleProvider => 'dsh.r2049.cn · 第三方页面';

  @override
  String remoteActiveHost(String name) {
    return '正在使用「$name」';
  }

  @override
  String get remoteSwitchToPhone => '切回本机';

  @override
  String get remoteSignInAgain => '重新登录';

  @override
  String get remoteHostSettings => '主机设置';

  @override
  String get remoteReconnect => '重新连接';

  @override
  String get remoteReconnectingEllipsis => '重新连接中…';

  @override
  String remoteReconnectReason(String reason) {
    return '重新连接中 · $reason';
  }

  @override
  String get remoteConnectedEncrypted => '已连接 · 端到端加密';

  @override
  String remoteConnectedVia(String path) {
    return '已连接 · $path · 端到端加密';
  }

  @override
  String get remotePathDirect => '直连';

  @override
  String get remotePathTurn => 'TURN';

  @override
  String get remotePathRelay => 'Relay 中继';

  @override
  String remoteConnectedSsh(String address) {
    return '已连接 · SSH $address';
  }

  @override
  String get remoteErrRefreshHosts => '没能刷新主机列表';

  @override
  String get remoteSwitchWarning => '一次只连一台主机，切换会断开上一台';

  @override
  String remoteHostOfflineHint(String name) {
    return '「$name」现在不在线。在那台电脑上打开 DSH 后再试';
  }

  @override
  String get remoteRefreshHosts => '刷新主机列表';

  @override
  String get remoteSignOut => '退出';

  @override
  String get remoteErrHostsRetry => '没能获取主机列表 · 轻点重试';

  @override
  String get remoteNoHosts => '还没有主机';

  @override
  String get remoteRelaySetupHelp => '在主机的 DSH 里装好远程插件并登录';

  @override
  String get remoteRelaySignOutTitle => '退出 DSH Remote？';

  @override
  String get remoteRelaySignOutBody => '这台手机会从账号中移除。主机上的 DSH 和对话不受影响，随时可以重新登录。';

  @override
  String get remoteRelaySignInTitle => '登录 DSH Remote';

  @override
  String get remoteRelaySignInHelp => '无需配置网络，连接端到端加密';

  @override
  String get remoteBrowserSignIn => '在浏览器中登录';

  @override
  String remoteSignInWithProvider(String provider) {
    return '使用 $provider 登录';
  }

  @override
  String get remoteComingSoon => '即将接入';

  @override
  String get remoteSelfHostedEmailSignIn => '自建服务器 · 邮箱登录';

  @override
  String get remoteBrowserSignInPending => '在浏览器里完成登录…';

  @override
  String get remoteCopySignInLink => '复制登录链接';

  @override
  String get remoteSshAddressRequired => '填写主机地址（IP 或域名）';

  @override
  String get remoteSshUsernameRequired => '填写登录用户名';

  @override
  String get remoteSshPasswordRequired => '填写 SSH 密码，或改用私钥';

  @override
  String get remoteSshKeyRequired => '粘贴私钥（以 -----BEGIN 开头的整段文本）';

  @override
  String get remoteHostKeyResetTitle => '重置主机指纹？';

  @override
  String get remoteHostKeyResetBody => '只在确认这台主机重装或更换过时才这么做。下次连接会重新请你核对指纹。';

  @override
  String get remoteReset => '重置';

  @override
  String remoteDeleteHostTitle(String name) {
    return '删除「$name」？';
  }

  @override
  String get remoteDeleteHostBody => '这台主机的设置和保存在手机上的密码、私钥都会删除。主机上的 DSH 和对话不受影响。';

  @override
  String remoteErrReadKey(String error) {
    return '没能读取：$error';
  }

  @override
  String get remoteErrPublicKeyFile => '这不是私钥文件，请选不带 .pub 的那个（例如 id_ed25519）';

  @override
  String get remotePrivateKeyImported => '已导入私钥，原文件可以删掉了';

  @override
  String get remoteEditHost => '编辑主机';

  @override
  String get remoteSshHostIntro => '连接你电脑或服务器上的 DSH';

  @override
  String get remoteHostBasicInfo => '基本信息';

  @override
  String get remoteHostNameHint => '比如：电脑、家里的 Mac';

  @override
  String get remoteHost => '主机';

  @override
  String get remoteHostAddressHint => '192.168.1.20 或 example.com';

  @override
  String get remoteUsername => '用户名';

  @override
  String get remotePort => '端口';

  @override
  String get remoteAuthentication => '登录方式';

  @override
  String get remotePasswordStorageHelp => '只保存在这台手机上，由 Android Keystore 加密';

  @override
  String get remoteKeyStorageHelp => '只保存在这台手机上，由 Android Keystore 加密。支持 Ed25519、RSA、ECDSA';

  @override
  String get remotePasswordStorageHelpIos => '只保存在这台手机上，由系统钥匙串加密';

  @override
  String get remoteKeyStorageHelpIos => '只保存在这台手机上，由系统钥匙串加密。支持 Ed25519、RSA、ECDSA';

  @override
  String get remotePrivateKey => '私钥';

  @override
  String get remoteShow => '显示';

  @override
  String get remoteImportKeyFile => '从文件导入';

  @override
  String get remotePrivateKeyPassword => '私钥密码（可选）';

  @override
  String get remoteStartCommand => '启动命令';

  @override
  String get remoteStartCommandHelp => '用 nvm 安装的可以填完整路径';

  @override
  String get remoteWorkingDirectory => '工作目录（可选）';

  @override
  String get remoteWorkingDirectoryHelp => '新对话默认在这里，支持 ~/';

  @override
  String get remoteHostFingerprint => '主机指纹';

  @override
  String get remoteHostKeyNotConfirmed => '还没有确认';

  @override
  String get remoteHostKeyFirstCheck => '首次连接时会请你核对指纹';

  @override
  String get remoteDeleteHost => '删除这台主机';

  @override
  String get remoteTesting => '正在测试';

  @override
  String get remoteTestConnection => '测试连接';

  @override
  String get remoteHostedUpdateRequired => '需要更新 App 才能打开';

  @override
  String get remoteHostedCannotOpen => '这个链接无法打开';

  @override
  String get remoteOpening => '正在打开…';

  @override
  String get remoteHostedNeverExpires => '永久有效';

  @override
  String get remoteHostedExpired => '已过期';

  @override
  String get remoteHostedExpiresToday => '今天到期';

  @override
  String get remoteHostedExpiresTomorrow => '明天到期';

  @override
  String remoteHostedExpiresOn(String date) {
    return '$date到期';
  }

  @override
  String get remoteHostedDeleteTitle => '删除这个链接？';

  @override
  String remoteHostedDeleteBody(String title) {
    return '「$title」的链接会立即失效';
  }

  @override
  String get remoteHostedLinkDeleted => '已删除链接';

  @override
  String get remoteUndo => '撤销';

  @override
  String get remoteHostedMyLinks => '我的分享链接';

  @override
  String get remoteHostedNoLinks => '还没有分享链接';

  @override
  String get remoteHostedErrDeleteNetwork => '没能删除，检查网络后重试';

  @override
  String get remoteHostedErrDelete => '没能删除，稍后再试';

  @override
  String get remoteDirectoryPickerTitle => '选择文件夹';

  @override
  String get remoteDirectoryChoose => '选择';

  @override
  String get remoteDirectoryDefault => '默认工作目录';

  @override
  String get remoteDirectoryHome => '主目录';

  @override
  String get remoteDirectoryPhoneStorage => '手机存储';

  @override
  String get remoteDirectoryDownloads => '下载';

  @override
  String get remoteDirectoryDownloadsPath => '手机存储/Download';

  @override
  String get remoteDirectoryDocuments => '文档';

  @override
  String get remoteDirectoryDocumentsPath => '手机存储/Documents';

  @override
  String get remoteDirectoryLocations => '位置';

  @override
  String get remoteDirectoryRecent => '最近';

  @override
  String get remoteDirectoryEnterPath => '输入路径';

  @override
  String get remoteDirectoryGo => '前往';

  @override
  String get remoteDirectoryAbsolutePath => '写完整路径，如 /root/workspace 或 C:/Users/me';

  @override
  String get remoteDirectoryNewFolder => '新建文件夹';

  @override
  String remoteDirectoryParentCaption(String name) {
    return '在「$name」里';
  }

  @override
  String get remoteDirectoryFolderName => '文件夹名称';

  @override
  String get remoteDirectoryRoot => '根目录';

  @override
  String get remoteDirectoryErrCreate => '没能新建文件夹';

  @override
  String get remoteDirectoryNoSubfolders => '这里没有子文件夹';

  @override
  String get remoteDirectoryHideHidden => '收起隐藏文件夹';

  @override
  String remoteDirectoryShowHidden(int count) {
    return '显示 $count 个隐藏文件夹';
  }

  @override
  String get remoteDirectoryTruncated => '文件夹太多，只列出了前面一部分';

  @override
  String get remoteWorkspaceAdd => '添加工作区';

  @override
  String remoteWorkspaceAdded(String name) {
    return '已添加「$name」';
  }

  @override
  String get remoteWorkspaceErrAdd => '没能添加工作区';

  @override
  String get remoteWorkspaceNoChats => '没有对话';

  @override
  String remoteWorkspaceChatCount(int count) {
    return '$count 个对话';
  }

  @override
  String get remoteWorkspaceErrRename => '没能重命名';

  @override
  String remoteWorkspaceRemoved(String name) {
    return '已移除「$name」';
  }

  @override
  String get remoteWorkspaceErrRemove => '没能移除工作区';

  @override
  String get remoteWorkspaceRename => '重命名工作区';

  @override
  String get remoteWorkspaceName => '工作区名称';

  @override
  String get remoteWorkspaceNameRequired => '起个名字';

  @override
  String remoteWorkspaceRemoveTitle(String name) {
    return '移除「$name」？';
  }

  @override
  String get remoteWorkspaceRemoveBody => '文件夹和对话都会保留';

  @override
  String get remoteWorkspaceRemove => '移除';

  @override
  String get remoteWorkspace => '工作区';

  @override
  String get remoteWorkspaceNewChatHere => '在这里新建对话';

  @override
  String get remoteWorkspaceUnpin => '取消置顶';

  @override
  String get remoteWorkspaceGroup => '分组';

  @override
  String get remoteWorkspaceUngrouped => '未分组';

  @override
  String get remoteWorkspaceRemoveAction => '移除工作区';

  @override
  String get remoteWorkspaceNewGroup => '新建分组';

  @override
  String get remoteWorkspaceGroupName => '分组名称';

  @override
  String remoteDirectoryPhonePath(String path) {
    return '手机存储/$path';
  }

  @override
  String get remoteDirectoryInvalidName => '名字里不能有「/」';

  @override
  String get remoteWorkspaceErrNameConflict => '已有同名的工作区';

  @override
  String get remoteWorkspaceErrInvalidPath => '这个文件夹不能用作工作区';

  @override
  String get remoteWorkspaceErrNotFound => '这个工作区已经不在了';

  @override
  String get remoteDirectoryErrUnreadable => '打不开这个文件夹';

  @override
  String get remoteDirectoryErrExists => '已经有同名的文件夹';

  @override
  String get remoteDirectoryErrUnavailable => '这台主机不能在这里浏览文件夹';

  @override
  String get remoteWorkspaceErrUnsupported => '这台主机不支持这个操作';

  @override
  String get remoteWorkspaceAllChats => '全部对话';

  @override
  String remoteWorkspaceSwitcherSemantics(String name) {
    return '工作区：$name。切换工作区';
  }

  @override
  String get remoteWorkspaceManage => '管理工作区';

  @override
  String get remoteWorkspaceErrLoad => '没能读取工作区';

  @override
  String get remoteWorkspaceEmpty => '还没有工作区';

  @override
  String get remoteWorkspaceEmptyHint => '把常用的文件夹加进来';

  @override
  String remoteWorkspaceCount(int count) {
    return '$count 个工作区';
  }

  @override
  String remoteDirectoryConfirmFolder(String action, String name) {
    return '$action「$name」';
  }

  @override
  String remoteHostKeyMismatchDetail(String saved, String received, String type) {
    return '确认主机重装或更换后，可在主机设置中重置指纹。\n已记住：$saved\n这次收到：$received（$type）';
  }

  @override
  String remoteForumCompactReplies(int count, String label) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$label 回复');
    return '$_temp0';
  }

  @override
  String remoteForumCompactViews(int count, String label) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$label 浏览');
    return '$_temp0';
  }

  @override
  String remoteForumYearDate(int year, String month, int day) {
    return '$year年$month月$day日';
  }

  @override
  String remoteHostedMonthDate(String month, int day) {
    return '$month 月 $day 日';
  }

  @override
  String remoteHostedYearDate(int year, String month, int day) {
    return '$year 年 $month 月 $day 日';
  }

  @override
  String remoteForumTenThousands(String value) {
    return '$value万';
  }

  @override
  String get remoteForumSemanticsSeparator => '，';

  @override
  String remoteHostKeyVerifyCommand(String command) {
    return '在那台主机上运行 $command 能看到同样的指纹。之后指纹一旦变化，App 会拒绝连接。';
  }

  @override
  String remoteSshInstallCommand(String command) {
    return '还没装 DSH？在主机上运行 $command';
  }

  @override
  String remoteRelayProvider(String project) {
    return '服务由 $project 提供';
  }

  @override
  String remoteRelayProviderServer(String project, String server) {
    return '服务由 $project 提供 · 当前服务器 $server';
  }

  @override
  String remoteQuotedHostName(String name) {
    return '「$name」';
  }

  @override
  String remoteErrorDetail(String message, String detail) {
    return '$message（$detail）';
  }

  @override
  String get remotePathLan => 'LAN 局域网';

  @override
  String get remotePathP2p => 'P2P 点对点';

  @override
  String get remoteNetworkDetails => '网络详情';

  @override
  String get remoteNetworkAutomatic => '自动依次尝试 LAN → P2P → TURN → Relay，连接全程端到端加密。';

  @override
  String get remoteNetworkCurrentPath => '当前路径';

  @override
  String get remoteNetworkConnectDuration => '连接耗时';

  @override
  String get remoteNetworkRoundTripTime => '往返延迟（RTT）';

  @override
  String get remoteNetworkUnmeasured => '未测量';

  @override
  String get remoteNetworkUnknownPath => '尚未确认';

  @override
  String remoteNetworkMilliseconds(int value) {
    return '$value 毫秒';
  }

  @override
  String get remoteNetworkMeasure => '刷新网络信息 / 测量延迟';

  @override
  String get remoteNetworkMeasuring => '正在测量…';

  @override
  String get remoteNetworkMeasureFailed => '暂时无法测量，可以稍后重试';

  @override
  String get remoteNetworkDisconnected => '连接已断开，重新连接后可测量';

  @override
  String get remoteNetworkFallback => '回落原因';

  @override
  String get remoteNetworkFallbackUnknown => '直连未能建立，已自动使用可用路径';

  @override
  String get remoteNetworkFallbackWebrtcUnavailable => '设备暂不支持 WebRTC，已使用 Relay 中继';

  @override
  String get remoteNetworkFallbackDirectFailed => 'LAN / P2P 直连未成功，已自动尝试后续路径';

  @override
  String get remoteNetworkFallbackDirectTimeout => 'LAN / P2P 直连超时，已自动尝试后续路径';

  @override
  String get remoteNetworkFallbackDirectRecentlyFailed => '近期直连未成功，本次先使用可用中继';

  @override
  String get remoteNetworkFallbackTurnUnavailable => 'TURN 服务暂不可用，已使用 Relay 中继';

  @override
  String get remoteNetworkFallbackTurnFailed => 'TURN 未能连接，已使用 Relay 中继';

  @override
  String get remoteNetworkFallbackTurnTimeout => 'TURN 连接超时，已使用 Relay 中继';

  @override
  String get remoteNetworkFallbackPathUnverified => '尚未确认 WebRTC 路径类型';

  @override
  String get remoteNetworkSnapshotHint => '显示最近一次确认的路径与延迟，刷新可重新检测。';

  @override
  String get remoteNetworkObservedAt => '最近观测';

  @override
  String get remoteHostedLoadFailed => '无法读取已保存的分享链接，请重试。';

  @override
  String get remoteHostedSaveFailed => '分享链接的更改尚未保存，请重试。';

  @override
  String get remoteHostedDeleteSaveFailed => '删除未完成，链接仍然有效。请重试。';

  @override
  String get remoteHostedUndoUnsaved => '本次删除已取消，但撤销尚未保存。重启后可能继续删除，请到“我的分享链接”重试保存。';

  @override
  String get remoteHostedUndoFailed => '无法恢复分享，删除可能已开始。请检查“我的分享链接”。';

  @override
  String get remoteHostedCreatedUnsaved => '链接已创建，可以复制使用，但尚未保存到本机。请保留链接，并到“我的分享链接”重试保存。';

  @override
  String get remoteHostedStopFailed => '未能停止分享，链接仍然有效。请重试。';

  @override
  String get remoteNetworkLocalIpVersion => '手机 ICE IP 版本';

  @override
  String get remoteNetworkRemoteIpVersion => '主机 ICE IP 版本';

  @override
  String get remoteNetworkIceProtocol => 'ICE 协议';

  @override
  String get remoteCompactHistory => '精简历史';

  @override
  String get remoteErrHistoryModeChanged => '主机已不支持精简历史，请切换到其他主机后再连回来，或重启 App，重新加载历史';

  @override
  String get remoteCompactHistoryHint => '支持的 DSH Remote 主机会精简历史工具详情，实时回复和审批不变。切换主机或重启 App 后生效；旧主机仍传输完整历史。';

  @override
  String get searchKwRemoteCompactHistory => '精简 简洁 历史 工具 传输 流量 远程 compact slim lite';

  @override
  String get remotePairEntry => '扫码配对电脑';

  @override
  String get remotePairEntryHint => '扫电脑上 Remote 插件显示的二维码，不用注册 Remote 账号（需要先登录 DeepSeek）';

  @override
  String get remotePairAddComputer => '扫码添加电脑';

  @override
  String get remotePairTitle => '扫码配对电脑';

  @override
  String get remotePairSubtitle => '不用注册 Remote 账号，也不会传 DeepSeek 密码或登录凭据';

  @override
  String get remotePairNeedsDeepSeek => '先登录 DeepSeek 账号';

  @override
  String get remotePairNeedsDeepSeekBody => '扫码配对要先在 DSH Go 里登录 DeepSeek 账号。配对时只附带账号 ID 用来标记这台手机，不传密码、Cookie 或 Token。';

  @override
  String get remotePairScanHint => '对准电脑上 Remote 插件显示的配对二维码';

  @override
  String get remotePairPasteLink => '粘贴配对链接';

  @override
  String get remotePairPasteEmpty => '剪贴板里没有配对链接';

  @override
  String get remotePairScannerFailed => '二维码识别器不可用。可以粘贴配对链接继续配对。';

  @override
  String get remotePairFromImage => '从相册识别';

  @override
  String get remotePairImageNoCode => '这张图里没找到二维码';

  @override
  String get remotePairCameraDenied => '没有相机权限。可以在系统设置里打开，或者用「从相册识别」「粘贴配对链接」';

  @override
  String get remotePairCameraFailed => '相机打不开。可以用「从相册识别」或「粘贴配对链接」';

  @override
  String get remotePairSystemScan => '扫码';

  @override
  String get remotePairSystemScanHint => '打开系统扫码，里面也能从相册选截图';

  @override
  String get remotePairReading => '正在读取配对信息…';

  @override
  String get remotePairConfirmTitle => '要连接这台电脑吗？';

  @override
  String get remotePairComputer => '电脑';

  @override
  String get remotePairServer => '服务器';

  @override
  String get remotePairFingerprint => '电脑指纹';

  @override
  String get remotePairFingerprintHint => '和电脑 Remote 插件上显示的指纹核对一致再继续。';

  @override
  String get remotePairConfirm => '确认是这台电脑，开始配对';

  @override
  String get remotePairNotThis => '不是这台，重新扫';

  @override
  String get remotePairClaiming => '正在生成验证码…';

  @override
  String get remotePairCodeTitle => '在电脑上输入这 8 位验证码';

  @override
  String remotePairCodeSemantics(String digits) {
    return '验证码 $digits';
  }

  @override
  String get remotePairCodeHint => '在电脑的 Remote 插件里输入，点「确认绑定」。手机不用再操作。';

  @override
  String get remotePairOneAttempt => '只有一次机会：输错后这次配对作废，要在电脑上重新生成二维码再扫。';

  @override
  String remotePairWaiting(String countdown) {
    return '等电脑确认 · 剩余 $countdown';
  }

  @override
  String get remotePairApproved => '电脑已确认，正在完成绑定…';

  @override
  String get remotePairCodeExpired => '验证码已过期，请在电脑上重新生成二维码';

  @override
  String remotePairConnecting(String name) {
    return '配对完成，正在连接 $name…';
  }

  @override
  String get remotePairFailedTitle => '没能配对';

  @override
  String remotePairOtherServerBody(String server) {
    return '这个二维码来自 $server，和 DSH Go 现在用的 Remote 服务器不同。切换过去继续吗？两个服务器的登录各自保留。';
  }

  @override
  String get remotePairSwitchServer => '切换服务器并继续';

  @override
  String get remotePairScanAgain => '重新扫码';

  @override
  String get remotePairErrInvalidCode => '这不是 DSH Go 的配对二维码';

  @override
  String get remotePairErrOtherServer => '这个二维码来自另一个 Remote 服务器';

  @override
  String get remotePairErrUnsupported => '这个 Remote 服务器还不支持扫码配对';

  @override
  String get remotePairErrExpired => '二维码已过期或已经用过了。请在电脑上重新生成二维码';

  @override
  String get remotePairErrCodeRejected => '电脑上输入的验证码不对，这次配对已作废。请在电脑上重新生成二维码再扫';

  @override
  String get remotePairErrCancelled => '配对已取消';

  @override
  String get remotePairErrAccountConflict => '这台手机已经登录了另一个 Remote 账号，和这台电脑的账号不一致。原来的登录保持不变；要换绑请先在 Remote 里退出登录';

  @override
  String get remotePairErrIdentity => '配对信息和这台电脑或这台手机对不上，已经停止。请在电脑上重新生成二维码';

  @override
  String get remotePairErrHostLimit => '这个账号绑定的电脑已经到上限了';

  @override
  String get remotePairErrNetwork => '连不上 Remote 服务器，检查网络后重试';

  @override
  String get remotePairErrFailed => '配对没有完成，请重新扫码';

  @override
  String remotePairSwitchFailedTitle(String name) {
    return '已和 $name 配对';
  }

  @override
  String get remotePairSwitchFailedBody => '但没能切换到这台电脑。可以重试，或者回到「远程主机」里点这台电脑。';

  @override
  String get remotePairDone => '完成';

  @override
  String get remotePairErrPinSave => '已经配对，但没能在手机上保存这台电脑的指纹。请在电脑上重新生成二维码，再扫一次';

  @override
  String get stateWorkspaceFilesHint => '已上传到当前工作区的文件：';

  @override
  String get stateRemoteUploadNameInvalid => '文件名不受主机支持，请去掉特殊字符或缩短后再试';

  @override
  String get stateRemoteUploadWorkspaceUnavailable => '当前对话没有可写的工作目录';

  @override
  String get stateRemoteUploadWorkspaceChanged => '工作目录已变化，请确认后重新上传';

  @override
  String get stateRemoteUploadLimit => '主机拒绝了上传，请检查文件大小或稍后重试';

  @override
  String get stateRemoteUploadUnsupported => '这台主机不支持文件上传，请更新主机上的 Remote 插件后重连';

  @override
  String get stateRemoteUploadTooLarge => '文件超过远程上传协议的大小上限';

  @override
  String get remoteWebTitle => 'DSH Web';

  @override
  String get remoteWebOpening => '正在打开 DSH Web…';

  @override
  String get remoteWebFailed => '没能打开 DSH Web';

  @override
  String get remoteWebRefresh => '刷新首页';

  @override
  String get remoteWebBusy => '人太多了，请稍后重试';

  @override
  String get remoteWebPairingRequired => '连接授权失效，请重新连接或配对主机。';

  @override
  String get remoteWebHostNotReady => '主机网页版尚未就绪。请启动 DSH Web，并将 Remote 插件更新到 0.6.6 或更新版本。';

  @override
  String get remoteWebReconnect => '连接已断开，请重新连接主机后再打开。';

  @override
  String get remoteWebUnsafeUrl => '网页地址无法验证，已停止打开。请检查主机配置。';

  @override
  String get remoteWebExchangeRejected => '访问验证没有通过，请重试。';

  @override
  String get remoteWebSessionExpired => '网页连接已过期，请重试。';

  @override
  String get remoteWebPlatformUnavailable => '当前平台暂不支持此网页入口。请使用原生远程界面。';

  @override
  String get remoteWebTryAgain => '暂时无法打开网页，请检查主机连接后重试。';

  @override
  String get remoteWebUnavailable => '暂时无法打开，请稍后重试';

  @override
  String get riskDontShowAgain => '不再提示';

  @override
  String get riskAskAi => '不确定？问 AI';

  @override
  String get riskConfirmAlwaysAction => '始终免确认';

  @override
  String get riskFullAccessAction => '开启完全权限';

  @override
  String get riskAutoReviewAction => '开启自动审查';

  @override
  String get riskAllowForChatTitle => '本对话都允许？';

  @override
  String get riskAllowForChatBody => '这个对话之后的命令和改动都直接放行，可在输入框上方随时关闭。';

  @override
  String get riskAllowForChatAction => '全部允许';

  @override
  String get riskPetOverlayTitle => '显示在其他应用上层？';

  @override
  String get riskPetOverlayBody => '要在系统设置里为 DSH Go 打开「显示在其他应用上层」，宠物才能出现在别的 App 上。';

  @override
  String get riskPetOverlayAction => '去设置';

  @override
  String get askAiTooltip => '问 AI';

  @override
  String get askAiHelpTitle => '使用帮助';

  @override
  String get askAiHelpSubtitle => '不懂的地方，问 AI';

  @override
  String askAiAboutApp(String question) {
    return '关于 DSH Go App：$question';
  }

  @override
  String askAiWithGuide(String question) {
    return '关于 DSH Go App：$question\n请按附件里的使用说明回答。';
  }

  @override
  String get askAiNoGuide => '这台主机没有 DSH Go 使用说明，回答可能不准确';

  @override
  String get askAiQuestionOverview => 'DSH Go 能做什么？我该从哪里开始？';

  @override
  String get askAiQuestionPhoneControl => '手机操控是怎么工作的？有什么风险？';

  @override
  String get askAiQuestionPhoneAlways => '手机操控选「始终免确认」会怎样？和「每次都询问」比风险在哪？';

  @override
  String get askAiQuestionAppRules => '手机操控的应用名单有什么用？放开银行、支付类 App 有什么风险？';

  @override
  String get askAiQuestionFullAccess => '「完全权限」打开后会怎样？有什么风险？';

  @override
  String get askAiQuestionPhoneFiles => '「访问手机文件」打开后，AI 能读写哪些文件？怎么关掉？';

  @override
  String get askAiQuestionAllowForChat => '「本对话都允许」会放行哪些操作？怎么关掉？';

  @override
  String get askAiQuestionPlugins => '插件能做什么？装第三方插件要注意什么？';

  @override
  String get askAiQuestionRemote => '怎么连接自己的电脑或服务器？和用本机有什么不同？';

  @override
  String get phoneRuntimeUpgradeBase => '新引擎与现有 Linux 环境不能确认兼容，更新已停止。原环境和已装工具没有删除。请先完整备份，再联系维护者迁移；不要直接重置或卸载 App。';

  @override
  String get phoneRuntimeUpgradeManifest => '无法安全识别运行时更新清单，更新已停止，原环境保留。请核对安装包并联系维护者，不要直接重置。';

  @override
  String get phoneRuntimeUpgradeInterrupted => '运行时升级尚未完成，数据与恢复现场已保留。请重试安装；仍失败时导出诊断并联系维护者，不要重置或删除恢复目录。';

  @override
  String get phoneRuntimeUpgradeSymlink => '现有环境的系统路径已被自定义链接替换，无法安全更新。原环境保留，请先备份并联系维护者处理。';

  @override
  String get phoneRuntimeUpgradeRunning => '引擎或遗留进程尚未确认停止，更新未开始。请先停止本机引擎，等待清理完成后重试；不要重置环境。';

  @override
  String get schemaDocumentationTitle => '字段说明';

  @override
  String get schemaDocumentationOverview => '概述';

  @override
  String get schemaDocumentationEach => '每一项';

  @override
  String schemaDocumentationPosition(int position) {
    return '第 $position 项';
  }

  @override
  String schemaDocumentationOption(int option) {
    return '选项 $option';
  }

  @override
  String get searchApiKey => 'API Key';

  @override
  String get searchNeedsLocal => '连接本机时可用';

  @override
  String get searchNeedsPhoneControl => '开启手机操控后可用';

  @override
  String get searchNeedsNativeUi => '原生界面可用';

  @override
  String get searchNeedsEngineField => '当前主机提供时可用';

  @override
  String get searchNeedsAnimations => '开启动画时可用';

  @override
  String get searchNeedsWorkshop => '这个版本没有带创意工坊';

  @override
  String get searchNeedsChat => '打开对话时可用';

  @override
  String get searchKwTheme => '外观,配色,颜色,主题色,强调色,图标';

  @override
  String get searchKwPets => '宠物,小鲸,桌宠,悬浮,鲸鱼';

  @override
  String get searchKwPerformance => '省电,流畅,卡顿,发热,轻量,完整';

  @override
  String get searchKwVoice => '语音识别,麦克风,听写,说话,语音,朗读,语音通话,打电话,TTS,声音';

  @override
  String get searchKwVoiceReading => '朗读,朗读的声音,TTS,音色,海星,暗潮,声音';

  @override
  String get searchKwNotifications => '提醒,推送,横幅,消息,铃声';

  @override
  String get searchKwReplyPrefs => '偏好,关于我,自我介绍,回答风格,称呼,AGENTS.md';

  @override
  String get searchKwSharedLinks => '分享链接,链接,公开链接,分享';

  @override
  String get searchKwPhone => '无障碍,操作手机,自动点击,代操作,点按';

  @override
  String get searchKwAppRules => '名单,黑名单,白名单,禁止,应用';

  @override
  String get searchKwDnd => '免打扰,Shizuku,Sui,root,ADB,后台操作';

  @override
  String get searchKwEngine => '引擎,运行环境,启动,停止,重启,DSH';

  @override
  String get searchKwBackground => '后台保活,保活,后台,电池优化,自启动,被杀,杀后台,省电';

  @override
  String get searchKwSystemAccess => '权限一览,授权,悬浮窗,无障碍,后台弹出界面,麦克风,文件访问,通知权限,受限制的设置,补开权限';

  @override
  String get searchKwDiagnostics => '日志,排障,诊断包,问题反馈,报错';

  @override
  String get searchKwModels => '模型渠道,渠道,供应商,换模型,OpenRouter,ChatGPT,Claude';

  @override
  String get searchKwEngineParams => '引擎设置,高级,参数,子代理,命令执行';

  @override
  String get searchKwSubagent => '子代理设置,递归,并发,子任务';

  @override
  String get searchKwAgentLoop => '循环,并行,工具调用';

  @override
  String get searchKwShell => '命令,超时,输出,终端,Shell';

  @override
  String get searchKwWebSearch => '搜索,上网,联网,API Key';

  @override
  String get searchKwGeneral => '通用,网页版设置';

  @override
  String get searchKwPluginInventory => '插件清单,已装插件';

  @override
  String get searchKwPlugins => '扩展,市场,安装插件,插件市场';

  @override
  String get searchKwAllFeatures => '功能,目录,所有功能';

  @override
  String get searchKwAccount => '账号,余额,充值,登录,退出登录,API Key,用量,DeepSeek';

  @override
  String get searchKwRemote => '远程,SSH,电脑,服务器,DSH Remote,连接电脑';

  @override
  String get searchKwPermission => '权限,别问我,确认,审批,自动允许,只读,完全权限,自动执行命令';

  @override
  String get searchKwAgentPresets => '预设,模式,工作方式';

  @override
  String get searchKwUiMode => '原生,网页,网页模式,界面,切换界面';

  @override
  String get searchKwLanguage => '中文,英文,简体,English';

  @override
  String get searchKwAutoCommands => '别问我,不要确认,自动允许,完全权限,免确认';

  @override
  String get searchKwPhoneFiles => '存储,文件,相册,下载,手机存储';

  @override
  String get searchKwVisualReplies => '图表,卡片,可视化,选项';

  @override
  String get searchKwTextSize => '字号,字体,文字大小,大字,字体大小';

  @override
  String get searchKwTableTint => '表格,底色,表头,斑马纹,条纹,背景';

  @override
  String get searchKwFoldTurns => '收起,折叠,过程,步骤';

  @override
  String get searchKwWebPhoneLayout => '网页版手机布局,布局';

  @override
  String get searchKwShareConfig => '分享,导出配置,分享码,配置';

  @override
  String get searchKwOpenWeb => '网页版,网页,浏览器,官方网页版';

  @override
  String get searchKwSafeMode => '安全模式,恢复正常模式,排障,插件崩溃';

  @override
  String get searchKwVersion => '版本号,关于';

  @override
  String get searchKwUpdate => '更新,升级,新版本';

  @override
  String get searchKwUpdateAuto => '自动更新,检查更新';

  @override
  String get searchKwHelp => '帮助,教程,问 AI,怎么用,说明';

  @override
  String get searchKwCommunity => '交流群,QQ 群,论坛,反馈';

  @override
  String get searchKwStar => 'GitHub,星标,点赞';

  @override
  String get searchKwLicenses => '许可证,开源,License';

  @override
  String get searchKwDarkMode => '深色,浅色,暗色,夜间,深色模式,跟随系统,外观';

  @override
  String get searchKwAccent => '颜色,主题色,强调色,壁纸,取色';

  @override
  String get searchKwTileStyle => '图标风格,磁贴';

  @override
  String get searchKwAppIcon => '启动图标,App 图标,图标';

  @override
  String get searchKwPetSize => '宠物大小,宠物尺寸';

  @override
  String get searchKwPetQuiet => '安静,宠物安静';

  @override
  String get searchKwPetOutside => '悬浮窗,桌面宠物,宠物悬浮';

  @override
  String get searchKwPetDisplayWhen => '宠物显示,显示时机';

  @override
  String get searchKwPetOverlayShows => '悬浮伙伴,小屋里的她,像素宠物,Live2D';

  @override
  String get searchKwPetOverlayFraming => '取景,全身,半身';

  @override
  String get searchKwWorkshop => '工坊,下载宠物,下载伙伴,分享宠物,投稿';

  @override
  String get searchKwBlur => '模糊,毛玻璃,玻璃';

  @override
  String get searchKwAnimations => '动画,动效,减少动画';

  @override
  String get searchKwFluidMotion => '灵动,弹性,回弹,光晕,丝滑';

  @override
  String get searchKwNotifyEnabled => '通知开关,关闭通知';

  @override
  String get searchKwNotifyDone => '完成提醒,回复完成';

  @override
  String get searchKwNotifyFailed => '出错提醒,失败';

  @override
  String get searchKwNotifyApproval => '审批提醒,确认提醒';

  @override
  String get searchKwNotifyQuestion => '提问提醒';

  @override
  String get searchKwNotifyLive => '灵动岛,实时活动,流体云,超级岛,原子岛,胶囊,状态栏进度,锁屏进度';

  @override
  String get searchKwNotifySystem => '声音,横幅,锁屏,系统通知';

  @override
  String get searchKwPhoneConfirm => '别问我,免确认,每次都询问,始终免确认,确认';

  @override
  String get searchKwPhoneAutoCollapse => '悬浮条,收起,悬浮球';

  @override
  String get searchKwPhoneEdgeGlow => '边缘光,光效,流光,特效,边框';

  @override
  String get searchKwPhoneSystemIsland => '灵动岛,超级岛,流体云,胶囊,实时活动,悬浮条';

  @override
  String get searchKwPhoneReturn => '返回,完成后返回';

  @override
  String get searchKwPhoneBackgroundGuide => '后台确认,返回 App';

  @override
  String get searchKwAutoStart => '自动启动,开机启动,自启';

  @override
  String get searchKwAutoSafe => '安全模式,自动安全模式';

  @override
  String get searchKwEngineReset => '重置,清空,恢复';

  @override
  String get searchKwEngineUninstall => '卸载,删除运行环境,释放空间';

  @override
  String get searchKwWorkspaceRecovery => '工作区,索引,救援,对话打不开,对话不见了,恢复对话';

  @override
  String get searchKwAddProvider => '添加模型,新渠道,自定义模型,Base URL';

  @override
  String get searchKwSubagentDepth => '递归深度,层数';

  @override
  String get searchKwParallelCalls => '并行,同时调用';

  @override
  String get searchKwCommandTimeout => '超时,命令超时,时间限制';

  @override
  String get searchKwWebSearchKey => '搜索 Key,联网 Key';

  @override
  String get searchKwChatLogUpload => '隐私,日志,上传日志,对话日志';

  @override
  String get searchKwAddSshHost => 'SSH,添加主机,连接电脑';

  @override
  String get searchKwRemoteAutoConnect => '自动连接,启动时连接';

  @override
  String get searchKwPermissionCurrent => '本对话都允许,这个对话,当前权限';

  @override
  String get searchKwPermissionDefault => '默认权限,只读,工作区内修改,完全权限,自动执行命令,别问我';

  @override
  String get searchSettingsHint => '搜索设置';

  @override
  String get searchSuggestDark => '深色模式';

  @override
  String get searchSuggestBackground => '后台运行';

  @override
  String get searchSuggestPermission => '权限';

  @override
  String get searchSuggestTextSize => '字号';

  @override
  String get searchCommon => '常用';

  @override
  String get searchRecent => '最近';

  @override
  String get searchFeatures => '功能';

  @override
  String get searchNoResults => '没有找到相关设置';

  @override
  String searchAskAi(String query) {
    return '问 AI：「$query」';
  }

  @override
  String get searchKwPersonalization => '个性化,偏好,风格,习惯';

  @override
  String get searchKwInterface => '原生,网页,网页模式,网页版,通用设置';

  @override
  String get searchKwPrivacy => '隐私,数据,日志,分享,统计';

  @override
  String get searchKwAbout => '关于,版本,更新,许可,dsh-go';

  @override
  String get searchKwPhoneConfirmEntry => '确认方式,手机操控,免确认';

  @override
  String get searchKwWebCodingView => '代码视图,工作视图,网页版';

  @override
  String get searchKwWebCollapse => '工作步骤,收起,折叠,网页版';

  @override
  String get searchKwWebBusySend => '发送,排队,插话,AI 工作时';

  @override
  String get searchKwPluginsMarket => '插件市场,安装插件,市场,获取插件';

  @override
  String get searchKwUsageStats => '统计,使用统计,匿名,隐私,数据,改进,遥测,分析';

  @override
  String get searchKwQuickPanel => '左滑,快捷入口,手势,滑动,目录,自定义目录,快捷,常用入口';

  @override
  String get selfUpdateTransport => '安装路线';

  @override
  String get selfUpdateSystem => '正常安装（默认）';

  @override
  String get selfUpdateShizuku => 'Shizuku';

  @override
  String get selfUpdateAdb => '本机 ADB';

  @override
  String get selfUpdateSecurityNote => '各路线仍受 APK 签名、Android 与厂商安全策略约束，不保证跳过扫描。不支持 root，也不会在失败后自动切换路线。';

  @override
  String get selfUpdateNativeConfirm => '只安装已校验的本应用更新；稍后仍需原生安装确认。授权 Shizuku 不等于同意安装，不需要开启手机操控或 AI Shell。';

  @override
  String get selfUpdateAuthorize => '申请更新用 Shizuku 授权';

  @override
  String get selfUpdateRefresh => '刷新通道状态';

  @override
  String selfUpdateShizukuStatus(String status) {
    return 'Shizuku：$status';
  }

  @override
  String get selfUpdateReady => '已授权';

  @override
  String get selfUpdatePermissionRequired => '请先安装、启动并授权 Shizuku';

  @override
  String get selfUpdateUnsupportedIdentity => '仅支持 shell UID 2000；root 与其他身份不受支持';

  @override
  String get selfUpdateAdbHint =>
      '使用已配对的本机无线调试身份；点击安装才连接。未配对时可打开现有 Android Shell 配对页，无需开启手机操控或 AI Shell。配对码和端口不保存、不写入日志。';

  @override
  String get selfUpdatePairing => '打开 Android Shell 配对引导';

  @override
  String get selfUpdateAdbPaired => '本机 ADB 已配对';

  @override
  String get selfUpdateAdbNotPaired => '本机 ADB 尚未配对';

  @override
  String get selfUpdatePendingTitle => '正在核实安装结果';

  @override
  String get selfUpdatePendingMessage => '安装请求可能仍在处理。不会自动重试或切换路线；请查看系统提示，再读取实际安装状态。';

  @override
  String get selfUpdateUnknownTitle => '安装结果未知';

  @override
  String get selfUpdateUnknownMessage => '超时、失联或进程退出不能证明失败。不会自动重试或切换路线；请先读取实际安装状态。';

  @override
  String get selfUpdateReadResult => '读取实际安装状态';

  @override
  String get selfUpdateVerifiedTitle => '已核实当前安装版本';

  @override
  String selfUpdateVerifiedVersion(String version, int code) {
    return '当前版本 $version（构建 $code），已由原生层核验。';
  }

  @override
  String get selfUpdateFailedTitle => '安装未完成';

  @override
  String get selfUpdateFailedMessage => '原生层报告本次安装失败。请检查系统提示和错误码，再明确选择安装路线。';

  @override
  String selfUpdateErrorCode(String code) {
    return '错误码：$code';
  }

  @override
  String get selfUpdateEndWaiting => '结束本次等待';

  @override
  String get selfUpdateEndWaitingNote => '只有确认系统已不在安装时才结束等待。清除本次记录不等于取消系统安装；不会自动重试或切换路线，仍需再次原生确认。';

  @override
  String get backupRecordFailed => '手机未能保存恢复记录。请记下上面的对话 ID 并检查目标主机，不要重复导入。';

  @override
  String get backupSearchKeywords => '备份,恢复,迁移,复制对话,同步,backup,restore';

  @override
  String get backupTitle => '对话备份';

  @override
  String get backupHint => '备份到手机后，可切换主机恢复到已有工作区。每次恢复会新建对话；不含附件、源码和跨对话关系。';

  @override
  String get backupCancelled => '已取消，已校验保存的备份仍可恢复。';

  @override
  String get backupUnknown => '结果待核对：请连接原目标主机查询，或先在目标端检查。不会自动重新导入。';

  @override
  String backupFailed(String code) {
    return '操作失败（$code）。请检查连接或存储后重试。';
  }

  @override
  String backupSaved(int count) {
    return '已保存 $count 条备份。';
  }

  @override
  String backupSavedCloseFailed(int count) {
    return '已保存 $count 条备份，源主机导出句柄未能关闭；断线或闲置后会自动释放。';
  }

  @override
  String backupRestoreConfirm(String title, String workspace) {
    return '将“$title”恢复到“$workspace”？会创建一条新对话，不合并或覆盖已有历史。';
  }

  @override
  String backupRestored(String id) {
    return '已恢复，新对话：$id';
  }

  @override
  String backupRestoredDetached(String id) {
    return '历史已恢复，未加入工作区。对话 ID：$id。请在目标端查找，不要重复导入。';
  }

  @override
  String get backupOriginalDevice => '请使用原 Remote 设备身份连接原目标主机，再查询提交结果。';

  @override
  String get backupStorageFailed => '无法读取备份。请检查应用存储和系统密钥；不会重置或覆盖已有备份。';

  @override
  String get backupConnectHost => '连接一台已配对的 Remote 主机，即可备份或恢复。';

  @override
  String get backupNoWorkspace => '等待主机工作区列表；没有工作区时请先在主机上创建。';

  @override
  String get backupWorkspace => '整个工作区';

  @override
  String get backupToPhone => '备份到手机';

  @override
  String get backupExportUnsupported => '此主机未提供对话导出能力，请更新主机 Remote 插件。';

  @override
  String get backupImportUnsupported => '此主机未提供对话恢复能力，请更新主机 Remote 插件。';

  @override
  String get backupPending => '待核对的恢复';

  @override
  String get backupCheck => '查询';

  @override
  String get backupAcknowledge => '已在目标端核对';

  @override
  String get backupAcknowledgeConfirm => '确认已在目标端核对？清除此待确认记录后，可手动再导入，但可能创建重复对话。';

  @override
  String get backupOnPhone => '手机上的备份';

  @override
  String get backupEmpty => '还没有备份。备份仅保存在本机，卸载 App 会丢失。';

  @override
  String get backupRestore => '恢复到当前工作区';

  @override
  String get backupDeleteConfirm => '删除手机上的这条备份及其恢复记录？不会删除主机上的对话。';

  @override
  String get shellDeletePermanently => '永久删除';

  @override
  String get shellDeleteNoUndo => '无法撤销，与归档不同';

  @override
  String get shellDeleteChecking => '正在检查此主机是否支持永久删除…';

  @override
  String get shellDeleteUnsupported => '此主机不支持安全永久删除，仍可使用归档。';

  @override
  String get shellDeleteUnavailable => '安全永久删除暂不可用，请重连或更新此主机；不会改为归档。';

  @override
  String shellDeleteChatConfirmation(String title) {
    return '永久删除「$title」？';
  }

  @override
  String shellDeleteChatsConfirmation(int count) {
    return '永久删除 $count 个对话？';
  }

  @override
  String get shellDeleteWarning =>
      '将从此主机永久删除所选对话记录，无法撤销，与归档不同。\n\n工作目录、生成的文件、分叉对话、共享附件和已发布的云端分享都会保留。云端分享需另行删除。子代理对话会随所选对话一起删除。运行中或有定时任务的对话会被主机拒绝。';

  @override
  String get shellDeleteOwnerChanged => '主机或连接已变化。请取消后重新发起删除，原确认不再有效。';

  @override
  String get shellDeletingChats => '正在删除对话…';

  @override
  String shellChatsDeleted(int count) {
    return '已永久删除 $count 个对话';
  }

  @override
  String shellDeletePartial(int deleted, int failed) {
    return '已删除 $deleted 个，失败 $failed 个';
  }

  @override
  String get shellDeleteRunning => '请先停止运行中的工作；主机还会检查活动任务和定时任务。';

  @override
  String get shellDeleteRelated => '此对话仍有关联的定时任务，主机为保护它们拒绝删除。';

  @override
  String get shellDeleteWriterHeld => '其他进程正在使用此对话，请先在该进程中关闭后重试。';

  @override
  String get shellDeleteNotFound => '此主机上已没有这个对话，请刷新列表。';

  @override
  String get shellDeleteConnectionLost => '连接已断开，删除结果未确认，请刷新对话列表后再操作。';

  @override
  String get shellDeleteArchivePending => '此对话正在等待归档，请先完成或撤销归档。';

  @override
  String get shellDeleteInventoryChanged => '对话列表已变化，请刷新后重新选择。';

  @override
  String get shellDeleteProtocolError => '删除结果未确认，请刷新对话列表后再操作。';

  @override
  String get shellDeleteNotAttempted => '未执行，请核对对话列表后重试。';

  @override
  String get shellDeleteFailed => '主机无法确认删除结果，请刷新后再决定是否重试。';

  @override
  String get setupAppearanceTitle => '选择外观';

  @override
  String get setupAppearanceMessage => '随时可以在设置里更改';

  @override
  String get setupLightMode => '轻量模式';

  @override
  String get setupCapsulePreparing => '准备运行环境';

  @override
  String setupCapsuleProgress(int percent) {
    return '运行环境 $percent%';
  }

  @override
  String setupCapsuleProgressSemantics(int percent) {
    return '正在准备运行环境，已完成 $percent%';
  }

  @override
  String get setupCapsuleReady => '运行环境已就绪';

  @override
  String get setupCapsuleFailed => '安装未完成';

  @override
  String get setupWaitingBody => '完成后自动进入';

  @override
  String get setupNotifyWhenDone => '完成时会通知你';

  @override
  String get setupAwaitSignIn => '就绪后自动打开 DeepSeek 登录';

  @override
  String get shellApiKeyPrefixWarning => 'DeepSeek 的 Key 通常以 sk- 开头，确认没有复制错';

  @override
  String get shellApiKeyIncompleteWarning => 'Key 似乎不完整，确认复制了整串';

  @override
  String get shellBrowserUrlCopied => '没能打开浏览器，网址已复制';

  @override
  String get shellSaveTryAgain => '没能保存，再试一次';

  @override
  String get shellApiKeyUpdated => 'API Key 已更新';

  @override
  String get shellReplaceApiKey => '更换 API Key';

  @override
  String get shellEnterApiKey => '输入 API Key';

  @override
  String get shellApiKeyBilling => '费用由 DeepSeek 开放平台按量结算';

  @override
  String get shellSaving => '正在保存';

  @override
  String get shellSaveContinue => '保存并继续';

  @override
  String get shellSetUpLater => '稍后设置';

  @override
  String get shellClearField => '清空';

  @override
  String get shellShow => '显示';

  @override
  String get shellApiKeyEncrypted => '加密保存在本机';

  @override
  String get shellGetApiKey => '获取 API Key';

  @override
  String get shellConnectDeepSeek => '连接 DeepSeek';

  @override
  String get shellConnectDeepSeekMessage => '登录 DeepSeek 账号即可开始，无需 API Key';

  @override
  String get shellAccountSignInUnsupported => '当前引擎不支持账号登录';

  @override
  String get shellSignInDeepSeek => '用 DeepSeek 账号登录';

  @override
  String get shellUseApiKey => '使用 API Key';

  @override
  String get shellOtherProviders => '其他模型渠道';

  @override
  String shellOnboardingStep(int step, int steps) {
    return '第 $step 步，共 $steps 步';
  }

  @override
  String get shellRuntimeUpdating => '正在更新运行环境';

  @override
  String get shellRuntimePreparing => '正在准备运行环境';

  @override
  String get shellRuntimeReady => '准备就绪';

  @override
  String get shellRuntimeIncomplete => '安装未完成';

  @override
  String get shellRuntimeFilesKept => '对话和文件都会保留';

  @override
  String get shellRuntimeFirstSetup => '首次准备约需一两分钟';

  @override
  String get shellRuntimeContinuing => '即将继续';

  @override
  String get shellRuntimeRestoreFailed => '没能放回保留的内容';

  @override
  String get shellRuntimeExtractFailed => '解压时出错';

  @override
  String get shellInstallLogs => '安装日志';

  @override
  String get shellRuntimeLocalOnly => '全程在本机完成';

  @override
  String get shellRuntimeContinueWithoutKept => '不保留，继续安装';

  @override
  String get shellRuntimeAlmostDone => '马上就好';

  @override
  String shellRuntimeSecondsRemaining(int count) {
    return '约 $count 秒';
  }

  @override
  String shellRuntimeMinutesRemaining(int count) {
    return '约 $count 分钟';
  }

  @override
  String get shellEngineLogs => '引擎日志';

  @override
  String get shellWelcomeMessage => '把 DeepSeek 智能体\n装进口袋';

  @override
  String get shellGetStarted => '开始';

  @override
  String get shellSearchChats => '搜索对话';

  @override
  String get shellCollapseChatList => '收起对话列表';

  @override
  String get shellExpandChatList => '展开对话列表';

  @override
  String get shellChatList => '对话列表';

  @override
  String get shellChatDetails => '对话详情';

  @override
  String get shellCollapseDetails => '收起详情';

  @override
  String get shellExpand => '展开';

  @override
  String get shellUndo => '撤销';

  @override
  String shellFolderDeleted(String name) {
    return '已删除「$name」';
  }

  @override
  String shellMovedToFolder(String name) {
    return '已移到「$name」';
  }

  @override
  String get shellMovedOutOfFolder => '已移出文件夹';

  @override
  String get shellUnpinFailed => '没能取消置顶，稍后再试';

  @override
  String get shellPinFailed => '没能置顶，稍后再试';

  @override
  String shellChatsUnpinned(int count) {
    return '已取消置顶 $count 个对话';
  }

  @override
  String shellChatsPinned(int count) {
    return '已置顶 $count 个对话';
  }

  @override
  String get shellArchiveFailed => '没能归档，稍后再试';

  @override
  String shellChatsStoppedArchived(int count) {
    return '已停止并归档 $count 个对话';
  }

  @override
  String shellChatsArchived(int count) {
    return '已归档 $count 个对话';
  }

  @override
  String shellFilterLabel(String label) {
    return '筛选：$label';
  }

  @override
  String get shellFolders => '文件夹';

  @override
  String get shellNoRunningChats => '没有运行中的对话';

  @override
  String get shellNoPendingChats => '没有待确认的对话';

  @override
  String get shellNoUnreadChats => '没有未读对话';

  @override
  String get shellNoChatsYet => '还没有对话';

  @override
  String shellFolderLabel(String name) {
    return '文件夹「$name」';
  }

  @override
  String shellFolderChatCount(String name, int count) {
    return '文件夹「$name」，$count 个对话';
  }

  @override
  String get shellSort => '排序';

  @override
  String get shellRecentActivity => '最近活动';

  @override
  String get shellCreatedTime => '创建时间';

  @override
  String get shellNewFolder => '新建文件夹';

  @override
  String get shellManageFolders => '管理文件夹';

  @override
  String get shellMultiSelect => '多选';

  @override
  String get shellFolderNameExists => '已有同名文件夹';

  @override
  String get shellEditFolder => '编辑文件夹';

  @override
  String get shellFolderMark => '标记';

  @override
  String shellFolderColor(int number) {
    return '颜色 $number';
  }

  @override
  String get shellMoveToFolder => '移到文件夹';

  @override
  String get shellMoveOutOfFolder => '移出文件夹';

  @override
  String get shellDeleteFolder => '删除文件夹';

  @override
  String get shellDragToReorder => '拖动排序';

  @override
  String get shellSelectChats => '选择对话';

  @override
  String shellSelectedCount(int count) {
    return '已选 $count 个';
  }

  @override
  String get shellDeselectAll => '取消全选';

  @override
  String get shellSelectAll => '全选';

  @override
  String get shellUnpin => '取消置顶';

  @override
  String get shellArchive => '归档';

  @override
  String get shellCurrentlyRunning => '正在运行';

  @override
  String get shellUnread => '未读';

  @override
  String get shellPinned => '已置顶';

  @override
  String get shellEngineNotRunning => '引擎未运行';

  @override
  String shellHostNotConnected(String name) {
    return '还没连上「$name」';
  }

  @override
  String get shellSearchAfterConnecting => '连接后才能搜索';

  @override
  String get shellChatsLoadFailed => '对话列表加载失败';

  @override
  String shellSearchHostChats(String name) {
    return '搜索「$name」上的对话';
  }

  @override
  String get shellSearchTitlesHint => '按标题查找，含已归档的对话';

  @override
  String get shellSearchContentHint => '按标题和内容查找，含已归档的对话';

  @override
  String get shellLoadingChatsEllipsis => '正在加载对话…';

  @override
  String get shellNoMatchingChats => '没有相关对话';

  @override
  String get shellSearchDifferentKeywords => '换个关键词，或用空格分开多个词';

  @override
  String get shellArchived => '已归档';

  @override
  String get shellRestoreBeforeOpening => '已归档的对话需先恢复，才能打开';

  @override
  String get shellRestoreAndOpen => '恢复并打开';

  @override
  String get shellRestoreFailed => '没能恢复，稍后再试';

  @override
  String get shellSearchingMessages => '正在搜索消息内容…';

  @override
  String get shellHostTitleSearchOnly => '这台主机仅支持按标题搜索';

  @override
  String get shellContentSearchFailed => '内容搜索失败，仅显示标题匹配';

  @override
  String get shellContentSearchLimit => '内容匹配仅列出最相关的 20 个对话';

  @override
  String get shellMoveToOtherFolder => '移到其他文件夹';

  @override
  String get shellArchiveStopsTurn => '进行中的一轮会停止';

  @override
  String get shellRenameFailed => '没能重命名，稍后再试';

  @override
  String shellChatStoppedArchived(String title) {
    return '已停止并归档「$title」';
  }

  @override
  String shellChatArchived(String title) {
    return '已归档「$title」';
  }

  @override
  String get shellRenameChat => '重命名对话';

  @override
  String get shellChatTitle => '对话标题';

  @override
  String shellUnreadCount(int count) {
    return '$count 条未读';
  }

  @override
  String get shellLoadingChats => '正在加载对话';

  @override
  String get shellWorkspaceNoChats => '这里还没有对话';

  @override
  String get shellWorkspaceNewChatsHint => '新对话会放进这个工作区。旧对话不会自动移入，可在「全部对话」中找到。';

  @override
  String get shellNewChatsHint => '新对话会出现在这里';

  @override
  String get shellEngineStarting => '引擎正在启动';

  @override
  String get shellChatsAfterStarting => '启动后显示你的对话';

  @override
  String get shellStartEngine => '启动引擎';

  @override
  String get shellEngineStatusHint => '在「引擎」中查看状态';

  @override
  String shellHostUnreachable(String name) {
    return '连不上「$name」';
  }

  @override
  String shellHostReconnecting(String name) {
    return '正在重新连接「$name」…';
  }

  @override
  String get shellRetryNow => '立即重试';

  @override
  String shellHostConnecting(String name) {
    return '正在连接「$name」…';
  }

  @override
  String get shellHostChatsAfterConnecting => '连接后显示这台主机上的对话';

  @override
  String shellCurrentHostLabel(String name, String view) {
    return '当前主机：$name，$view。切换主机';
  }

  @override
  String get shellChatGone => '这个对话已不在了';

  @override
  String get shellAccentMist => '雾蓝';

  @override
  String get shellAccentDaiqing => '黛青';

  @override
  String get shellAccentDusk => '暮紫';

  @override
  String get shellAccentTurquoise => '松石';

  @override
  String get shellAccentAmber => '琥珀';

  @override
  String get shellAccentGraphite => '石墨';

  @override
  String get shellHideTurnFooter => '回合脚注';

  @override
  String get shellHideTokenCount => 'token 数';

  @override
  String get shellHideReasoning => '思考过程';

  @override
  String get shellHideActivityStrip => '活动条';

  @override
  String get shellHideWhaleTail => '鲸尾';

  @override
  String get shellHideTodoPill => '待办条';

  @override
  String get shellHideGoalBar => '目标条';

  @override
  String get shellToday => '今天';

  @override
  String get shellThisWeek => '本周';

  @override
  String get shellEarlier => '更早';

  @override
  String get shellSeatNative => '原生';

  @override
  String get shellSeatIsland => '内嵌网页';

  @override
  String get shellSeatWeb => '网页版打开';

  @override
  String get shellPlugins => '插件';

  @override
  String get shellHeaderActions => '顶栏按钮';

  @override
  String get shellAllHidden => '全部隐藏';

  @override
  String shellSettingCount(int count) {
    return '$count 个';
  }

  @override
  String get shellQuickActions => '快捷胶囊';

  @override
  String get shellSuggestionCards => '建议卡片';

  @override
  String shellSuggestionCardCount(int count) {
    return '$count 张';
  }

  @override
  String get shellDrawerGroups => '抽屉分组';

  @override
  String get shellDrawerSort => '抽屉排序';

  @override
  String get shellDrawerFilter => '抽屉筛选';

  @override
  String get shellPending => '待确认';

  @override
  String get shellAll => '全部';

  @override
  String get shellDensity => '疏密';

  @override
  String get shellCompact => '紧凑';

  @override
  String get shellSpacious => '宽松';

  @override
  String get shellThemeMode => '外观模式';

  @override
  String get shellAccentColor => '强调色';

  @override
  String get shellPet => '宠物';

  @override
  String get shellConfigured => '已设置';

  @override
  String get shellShortcuts => '快捷键';

  @override
  String get shellConfigFileTooLarge => '文件超过 64 KiB';

  @override
  String get shellConfigRootNotObject => '顶层必须是对象';

  @override
  String get shellConfigVersionMissing => '缺少 version';

  @override
  String get shellConfigVersionNotInt => 'version 必须是整数';

  @override
  String get shellConfigVersionTooLow => 'version 从 1 开始';

  @override
  String shellConfigVersionTooHigh(int version) {
    return '需要更新 App 才能使用版本 $version';
  }

  @override
  String get shellConfigNotObject => '应该是对象';

  @override
  String get shellConfigNotArray => '应该是数组';

  @override
  String get shellConfigNotString => '应该是字符串';

  @override
  String get shellConfigNotBool => '应该是 true 或 false';

  @override
  String get shellConfigEmpty => '不能为空';

  @override
  String get shellConfigUnknownKey => '未知的键，已忽略';

  @override
  String get shellConfigDuplicateKey => '重复的键，只认最后一个';

  @override
  String get shellConfigDuplicateItem => '重复了，已忽略';

  @override
  String shellConfigMissing(String key) {
    return '缺少 $key';
  }

  @override
  String shellConfigTruncated(int count) {
    return '超过 $count 个字，已截断';
  }

  @override
  String shellConfigTooLong(int count) {
    return '超过 $count 个字';
  }

  @override
  String shellConfigTooMany(int count) {
    return '最多 $count 个，多出的已忽略';
  }

  @override
  String get shellConfigValueNoun => '值';

  @override
  String shellConfigUnsupportedValue(String noun, String value) {
    return '不支持的$noun「$value」';
  }

  @override
  String get shellConfigHeaderItem => '应该是按钮 id 或对象';

  @override
  String get shellConfigHeaderId => 'id 只能用字母、数字和 -，以小写字母开头';

  @override
  String get shellConfigIdTaken => 'id 重复';

  @override
  String get shellConfigCommandSlash => '命令名不带 /，已去掉';

  @override
  String get shellConfigCommandName => '命令名只能用字母、数字和 : . _ -';

  @override
  String get shellConfigNoNewline => '不能换行';

  @override
  String get shellConfigHttpsOnly => '只支持 https 链接';

  @override
  String get shellConfigBadUrl => '链接格式不对';

  @override
  String get shellConfigAccentFormat => '颜色要写成 #RRGGBB';

  @override
  String get shellConfigAccentBoth => '和 accentPreset 二选一，已用 accentPreset';

  @override
  String get shellConfigPetId => 'id 只能用小写字母、数字和 -';

  @override
  String get shellConfigKeysFormat => '写法不对，例如 ctrl+k';

  @override
  String get shellConfigSystemKey => '不能用系统键';

  @override
  String get shellConfigNeedModifier => '要带 ctrl 或 alt';

  @override
  String get shellConfigReservedKey => '被系统或输入法占用';

  @override
  String shellConfigDuplicateShortcut(String pointer) {
    return '和 $pointer 重复';
  }

  @override
  String get shellConfigSlotName => 'slot 名格式不对';

  @override
  String get shellConfigUnknownSlot => '当前 DSH 没有这个 slot，先保留';

  @override
  String get shellConfigUnseatableSlot => '这个位置不放插件';

  @override
  String get shellConfigPackageName => '包名格式不对';

  @override
  String get shellConfigActionNoun => '动作';

  @override
  String get shellConfigPageNoun => '页面';

  @override
  String get shellConfigButtonNoun => '按钮';

  @override
  String get shellConfigIconNoun => '图标';

  @override
  String get shellConfigNotTextFile => '不是文本文件';

  @override
  String shellJsonPosition(int line, int column, String reason) {
    return '第 $line 行第 $column 列：$reason';
  }

  @override
  String get shellJsonEmptyFile => '文件是空的';

  @override
  String get shellJsonExtraContent => '后面还有多余的内容';

  @override
  String get shellJsonIncompleteFile => '文件不完整';

  @override
  String get shellJsonCommentsUnsupported => '不支持注释';

  @override
  String get shellJsonDoubleQuotes => '字符串要用双引号';

  @override
  String get shellJsonMissingValue => '这里缺少一个值';

  @override
  String shellJsonUnknownContent(String value) {
    return '无法识别的内容「$value」';
  }

  @override
  String get shellJsonTooDeep => '嵌套太深';

  @override
  String get shellJsonExtraComma => '多余的逗号';

  @override
  String get shellJsonQuotedKey => '键要用双引号括起来';

  @override
  String get shellJsonExpectedKey => '这里应该是一个键';

  @override
  String get shellJsonMissingColon => '键后面缺少冒号';

  @override
  String get shellJsonMissingComma => '这里缺少逗号';

  @override
  String shellJsonUnexpectedContent(String value) {
    return '这里不应该出现「$value」';
  }

  @override
  String get shellJsonUnterminatedString => '字符串没有结束';

  @override
  String get shellJsonBadEscape => '字符串里的转义不对';

  @override
  String get shellJsonStringNewline => '字符串里不能直接换行';

  @override
  String get shellJsonControlCharacter => '字符串里有控制字符';

  @override
  String get shellJsonBadNumber => '数字格式不对';

  @override
  String shellSkillInstallPrompt(String skill) {
    return '请在这台主机上安装 DSH Go 的界面技能 $skill：';
  }

  @override
  String shellSkillInstallDirectory(String skill) {
    return '1. 目标目录是 `\$DSH_HOME/skills/$skill/`（没有设置 DSH_HOME 时是 `~/.dsh/skills/$skill/`），不存在就先建。';
  }

  @override
  String get shellSkillInstallFiles => '2. 把下面每个文件按给出的相对路径原样写进去，内容一个字都不要改。';

  @override
  String get shellSkillInstallConfirm => '4. 告诉我装好了。';

  @override
  String shellSkillInstallFile(String path) {
    return '文件 `$path`：';
  }

  @override
  String get shellFromUiJson => '来自 ui.json';

  @override
  String get shellViewSource => '查看来源';

  @override
  String get shellSourcePosition => '位置';

  @override
  String get shellRestoreDefaults => '恢复默认';

  @override
  String get shellConfigNotApplied => '没有生效';

  @override
  String shellConfigDroppedCount(int count) {
    return '$count 处没生效';
  }

  @override
  String shellConfigAppliedCount(int count) {
    return '已应用 $count 项';
  }

  @override
  String get shellInterfaceConfig => '界面配置';

  @override
  String get shellSkillNotInstalled => '未安装技能';

  @override
  String get shellInstallInterfaceSkill => '安装界面技能';

  @override
  String get shellInstallInterfaceSkillMessage => '装好后，可以让 AI 按你的话调整 App 界面';

  @override
  String get shellNoUiJson => '没有 ui.json';

  @override
  String get shellConfigUsingPrevious => '没有生效，仍在用上一次的配置';

  @override
  String get shellConfigDroppedHeading => '没生效';

  @override
  String get shellConfigNotesHeading => '提示';

  @override
  String get shellConfigAppliedHeading => '已应用';

  @override
  String shellConfigValueOptions(String noun, String value, String options) {
    return '不支持的$noun「$value」，可选：$options';
  }

  @override
  String get shellListSeparator => '、';

  @override
  String shellSkillInstallCheck(String command) {
    return '3. 写完运行 $command，能运行就说明装好了（提示还没有 ui.json 是正常的）。';
  }

  @override
  String get shellSemanticsSeparator => '，';

  @override
  String shellChatsArchivedPartial(int count, int failed) {
    return '已归档 $count 个对话，$failed 个没能归档';
  }

  @override
  String get shellPanelOverview => '信息';

  @override
  String get shellPanelWorkspace => '工作区';

  @override
  String get shellPanelModel => '模型';

  @override
  String get shellPanelHost => '主机';

  @override
  String get shellPanelOpenFull => '打开完整页面';

  @override
  String get shellPanelNoPlugins => '这段对话还没有插件面板';

  @override
  String get shellQuickPanel => '快捷入口';

  @override
  String shellQuickPanelHint(String path) {
    return '在「$path」里调整';
  }

  @override
  String get speechReadAloud => '朗读';

  @override
  String get speechReadAloudStop => '停止朗读';

  @override
  String get speechReadSection => '朗读';

  @override
  String get speechReadFooter => '回复下方的朗读键、伙伴小屋和语音通话都用这个声音。';

  @override
  String get speechVoiceTitle => '朗读的声音';

  @override
  String get speechVoiceHello => '你好，这是朗读的声音。';

  @override
  String get speechVoiceDeepseek => 'DeepSeek';

  @override
  String get speechVoiceDeepseekHint => '登录的 DeepSeek 账号付费；没登录，或账号不能用于语音时，用设置里的 API Key。不用另外配置';

  @override
  String get speechVoiceDeepseekFooter => '按朗读的字数计费，价格见 DeepSeek 开放平台。读出前会去掉代码块、表格和链接地址。';

  @override
  String get speechVoiceStella => '海星（女声）';

  @override
  String get speechVoiceTide => '暗潮（男声）';

  @override
  String get speechVoiceStellaShort => '海星';

  @override
  String get speechVoiceTideShort => '暗潮';

  @override
  String get speechVoiceFollow => '跟朗读一样';

  @override
  String get speechVoiceFollowHint => '用设置 › 语音里朗读的声音';

  @override
  String get speechNotSetUp => '朗读的声音还没设置好，去设置 › 语音看看';

  @override
  String get speechNoCredential => '要先登录 DeepSeek 账号，或在设置里填 API Key';

  @override
  String get speechAccountUnusable =>
      '已登录的账号在这里付不了 DeepSeek 语音：当前连接的 DSH 版本较旧（更新后就行），或正经 DSH Remote 中继连接。在设置里填 DeepSeek API Key 就能用';

  @override
  String get speechSignIn => 'DeepSeek 账号用不了语音（可能登录过期，或语音只认 API Key）。重新登录，或在设置里填上 API Key';

  @override
  String get speechUnauthorized => 'DeepSeek API Key 无效，请在设置里检查';

  @override
  String get speechBalance => 'DeepSeek 余额不足';

  @override
  String get speechRateLimited => '请求太频繁，稍后再试';

  @override
  String get speechNothingToRead => '这条回复没有可以朗读的文字';

  @override
  String get speechNotHeard => '没听清，再说一次';

  @override
  String get speechTooLong => '录音太长了，分几段说吧';

  @override
  String get speechBusy => '语音服务正忙，稍后再试';

  @override
  String get speechNetwork => '连不上语音服务，请检查网络';

  @override
  String get speechReadFailed => '朗读失败';

  @override
  String get speechListenFailed => '识别失败';

  @override
  String get speechCloudNotice => '语音会发给 DeepSeek 识别。想在手机上识别，可以换成语音模型。';

  @override
  String get speechCloudNotSetUp => '还没设置云端识别服务';

  @override
  String get speechCallTile => '语音通话';

  @override
  String get speechCallSection => '语音通话';

  @override
  String get speechCallFooter => '通话时说完一句停一下，就会发出去；回答边写边读。';

  @override
  String get speechCallBargeIn => '插话打断';

  @override
  String get speechCallBargeInHint => 'AI 说话时你一开口，它先轻下来；「嗯」「对」它接着说，说别的它就停下听你';

  @override
  String get speechCallSpoken => '口语回答';

  @override
  String get speechCallSpokenHint => '通话的第一条消息会请 AI 简短、口语化地回答';

  @override
  String get speechCallSpeaker => '默认免提';

  @override
  String get speechCallSpeakerHint => '接上耳机时总用耳机';

  @override
  String get speechCallHint => '（这是语音通话，我说的话由语音识别转成文字。请用简短、口语化的中文回答，不要用 Markdown、列表、表格和代码块。）';

  @override
  String speechCallCutNote(String heard) {
    return '（你说到「$heard」时我打断了你，后面的我没听到。）';
  }

  @override
  String get speechCallCutEarly => '（你刚开口我就打断了你，这条回答我没听到。）';

  @override
  String get speechCallCue => '思考提示音';

  @override
  String get speechCallCueHint => '回答一时没出声时，轻响一声表示还在想';

  @override
  String get speechLiveSection => '实时字幕';

  @override
  String get speechLiveName => '流式识别模型';

  @override
  String get speechLiveSystemName => '系统识别（普通话）';

  @override
  String get speechLiveSystemReadyNote => '由鸿蒙系统提供，不用下载模型，通话时自动使用';

  @override
  String get speechLiveSystemBusy => '使用中';

  @override
  String get speechLiveSystemBusyNote => '语音输入或另一项识别正在用它，用完后点重试';

  @override
  String speechLiveSystemFailedNote(String reason) {
    return '这台手机现在用不了系统识别：$reason';
  }

  @override
  String get speechLiveSystemFooter => '字幕和插话判断由鸿蒙系统识别在手机上完成；发给 AI 的文字仍由上面选的识别方式给出，选了云端识别录音就会上传。';

  @override
  String speechLiveAbsentNote(String mb) {
    return '下载后，通话时一边说一边出字，插话也停得更快。约 $mb，在手机上运行';
  }

  @override
  String speechLiveReadyNote(String mb) {
    return '已占用 $mb，通话时自动使用';
  }

  @override
  String get speechLiveBlocked => '已停用';

  @override
  String get speechLiveBlockedNote => '在这台手机上运行时出过问题，实时字幕已停用，通话照常。删除后重新下载可以再试。';

  @override
  String get speechLiveFooter => '字幕和插话判断在手机上完成；发给 AI 的文字仍由上面选的识别方式给出，选了云端识别录音就会上传。';

  @override
  String get speechLiveDeleteTitle => '删除流式识别模型？';

  @override
  String get speechLiveDeleteBody => '删除后通话不再显示实时字幕，随时可以重新下载。';

  @override
  String get speechCallStarting => '正在接通';

  @override
  String get speechCallListening => '在听';

  @override
  String get speechCallHearing => '你在说';

  @override
  String get speechCallThinking => '想一想';

  @override
  String get speechCallSpeaking => '正在说，轻点光球可以跳过';

  @override
  String get speechCallMuted => '已静音';

  @override
  String get speechCallEnded => '通话已结束';

  @override
  String get speechCallEndPermission => '没有麦克风权限';

  @override
  String get speechCallEndMicrophone => '麦克风被占用或打不开';

  @override
  String get speechCallEndNoRecognizerSignedIn =>
      '通话要能识别录音。已登录的账号在这里付不了 DeepSeek 语音（当前连接的 DSH 版本较旧，或经 DSH Remote 中继）：在设置里填 DeepSeek API Key，或在设置 › 语音里下载语音模型';

  @override
  String get speechCallEndNoRecognizer => '通话需要能识别录音的方式：登录 DeepSeek 账号、填 API Key，或下载语音模型';

  @override
  String get speechCallEndBackground => '切到后台时通话会结束';

  @override
  String get speechCallEndFailed => '录音出错，通话已结束';

  @override
  String get speechCallSendFailed => '没发出去，再说一次';

  @override
  String get speechCallSkipHint => '跳过这段回答';

  @override
  String get speechCallTranscript => '字幕';

  @override
  String get speechCallTranscriptHint => '这次通话的全部字幕';

  @override
  String get speechCallTranscriptEmpty => '还没开口。你们说的话会一句句记在这里。';

  @override
  String get speechCallTranscriptCut => '你在这里插话';

  @override
  String get speechCallMute => '静音';

  @override
  String get speechCallUnmute => '取消静音';

  @override
  String get speechCallHangUp => '挂断';

  @override
  String get speechCallSpeakerOn => '免提';

  @override
  String get speechCallEarpiece => '听筒';

  @override
  String get speechBackdropTitle => '通话背景';

  @override
  String get speechCallSettings => '通话设置';

  @override
  String get speechCallPause => '停顿多久算说完';

  @override
  String get speechCallPauseQuick => '快';

  @override
  String get speechCallPauseNormal => '适中';

  @override
  String get speechCallPausePatient => '耐心';

  @override
  String get speechCallPauseHint => '说话爱停顿、常被她抢话，就选「耐心」；嫌她接得慢，选「快」。';

  @override
  String get speechCallSpeechSection => '声音和识别';

  @override
  String get speechCallVoice => '她的声音';

  @override
  String get speechCallSpeechHint => '改了从下一句开始生效。';

  @override
  String get speechBackdropSea => '深海';

  @override
  String get speechBackdropImage => '我的图片';

  @override
  String get speechBackdropImagePick => '选一张图';

  @override
  String get speechBackdropCompanion => '伙伴';

  @override
  String get speechBackdropHint => '图片会虚化、压暗，字幕看得清。选伙伴时，她会跟着声音说话。';

  @override
  String get speechBackdropHintChange => '再点一次「我的图片」可以换一张。选伙伴时，她会跟着声音说话。';

  @override
  String get speechBackdropNoCompanion => '先在伙伴小屋里请她住进来，才能把她放进通话里。';

  @override
  String get speechBackdropReplace => '换一张图';

  @override
  String get speechBackdropPickFailed => '这张图用不了，换一张试试';

  @override
  String get speechCallVisual => '光效';

  @override
  String get speechCallVisualRing => '光环';

  @override
  String get speechCallVisualMono => '细线';

  @override
  String get speechCallVisualGlass => '光球';

  @override
  String get speechInsecure => '这个云端服务的地址不是 https，Key 不能这样发出去';

  @override
  String starPromptTitle(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: '本鱼已经在 DSH Go 里陪你 $hours 个小时啦⁠~',
      one: '本鱼已经在 DSH Go 里陪你一个小时啦⁠~',
      zero: '本鱼已经在 DSH Go 里陪你半个小时啦⁠~',
    );
    return '$_temp0';
  }

  @override
  String get starPromptBody => '这是一个免费开源的项目，如果它让你的移动端体验更好了一点，拜托点个 Star 支持一下，这对本鱼是很大的鼓励！';

  @override
  String get starPromptPlea => '拜托你啦~ 这真的很重要！！';

  @override
  String get starPromptBody2 => '看来你挺喜欢这里嘛！点个 Star 只要几秒钟，却能让更多人发现 DSH Go，本鱼也会更有干劲！';

  @override
  String get starPromptPlea2 => '就差你这一颗星星啦~';

  @override
  String get starPromptBody3 => 'DSH Go 不收费、没有广告，全靠大家的 Star 让更多人看到。如果它帮到了你，就送本鱼一颗星星吧！';

  @override
  String get starPromptPlea3 => '本鱼眼巴巴地等着呢~';

  @override
  String get starPromptBody4 => '这么久了，本鱼一直都在。如果 DSH Go 已经成了你每天都会打开的 App，点个 Star 就是给作者最好的回礼。';

  @override
  String get starPromptPlea4 => '求求你啦，就点一下下~';

  @override
  String get starPromptBody5 => '这是本鱼最后一次问你啦。不管点不点，本鱼都会一直陪着你。要是愿意的话，点个 Star 让本鱼开心一下吧！';

  @override
  String get starPromptPlea5 => '最后一次，拜托啦！';

  @override
  String get starPromptStar => '去 GitHub 点 Star';

  @override
  String get starPromptDone => '已经点过啦';

  @override
  String get starPromptLater => '下次再说';

  @override
  String get starSettingsTitle => '给 DSH Go 点个 star';

  @override
  String get hubStartPage => '起始页';

  @override
  String get hubChatSuggestions => '聊天建议';

  @override
  String get hubChatSuggestionsHint => '显示起始页的聊天建议';

  @override
  String get searchKwChatSuggestions => '起始页,空白页,新对话,聊天建议,建议卡片';

  @override
  String get phoneStartupFailureStopping => '启动失败，正在停止';

  @override
  String phoneStartupFailureStoppingDetail(String reason) {
    return '启动失败，正在停止。$reason';
  }

  @override
  String get phoneStartupTokenTimeout => '启动等待已超时（180 秒内未收到启动标记），请查看日志';

  @override
  String get phoneStartupPortNotReady => '已收到启动标记，但本机服务端口尚未就绪，请查看日志';

  @override
  String get stateDiagnosticsSubject => 'DSH Go 诊断包';

  @override
  String get stateStoragePermission => '没有存储权限，存不进「下载」';

  @override
  String get stateDiagnosticsStorageFull => '存储空间不足，没能生成诊断包';

  @override
  String get stateDiagnosticsExportFailed => '没能导出诊断包';

  @override
  String get stateForumUnreachable => '没能连上论坛';

  @override
  String get stateSignInExpired => '登录已失效，请重新登录';

  @override
  String get stateForbidden => '没有权限';

  @override
  String get stateForumContentMissing => '内容不存在或已删除';

  @override
  String get stateTooManyActions => '操作太频繁，稍后再试';

  @override
  String get stateForumSendFailed => '没能发出去';

  @override
  String get stateForumServerError => '论坛暂时出了问题';

  @override
  String get stateBrowserOpenFailed => '没能打开浏览器';

  @override
  String get stateSignInStartFailed => '没能开始登录';

  @override
  String get stateSignInIncompleteRetry => '登录没有完成，请重试';

  @override
  String get statePluginLabel => '插件';

  @override
  String get stateConfigLabel => '配置';

  @override
  String get stateConfigShare => '配置分享';

  @override
  String get stateShareCode => '分享码';

  @override
  String get stateCopyShareCodeFirst => '先在分享里复制分享码';

  @override
  String get stateFileOpenFailed => '无法打开这个文件';

  @override
  String get stateLinkOpenFailed => '无法打开这个链接';

  @override
  String get stateAlertPublicDone => '有一轮完成了';

  @override
  String get stateAlertPublicFailed => '有一轮出错了';

  @override
  String get stateAlertPublicStopped => '有一轮停下了';

  @override
  String get stateAlertPublicApproval => '有一步等你确认';

  @override
  String get stateAlertPublicQuestion => '有个问题等你回答';

  @override
  String get stateAlertTurnDone => '这一轮已完成';

  @override
  String get stateAlertOutputLimit => '已结束 · 达到单次输出长度上限';

  @override
  String get stateAlertTurnBlocked => '这一轮被拦截了';

  @override
  String get stateAlertEngineRestarted => '已中断 · 引擎重启过';

  @override
  String get stateAlertMissingKey => '出错了 · 还没有配置密钥';

  @override
  String get stateAlertTurnFailed => '这一轮出错了';

  @override
  String get stateRunCommand => '运行命令';

  @override
  String get stateWriteFile => '写入文件';

  @override
  String get stateEditFile => '修改文件';

  @override
  String get stateOpenPage => '打开网页';

  @override
  String get stateWebSearch => '联网搜索';

  @override
  String get stateAlertQuestion => '问你一个问题';

  @override
  String get stateSizeSmall => '小';

  @override
  String get stateSizeStandard => '标准';

  @override
  String get stateSizeLarge => '大';

  @override
  String get stateSizeCustom => '自定义';

  @override
  String get statePetDone => '做完了';

  @override
  String get statePetFailed => '出错了';

  @override
  String get statePhoneNotReady => '手机操控模块未就绪';

  @override
  String get stateBackgroundRestricted => '后台联网被系统限制';

  @override
  String get stateBackgroundFinish => '让对话在后台也能跑完';

  @override
  String get stateDeepSeekAccount => 'DeepSeek 账号';

  @override
  String get stateAccountUnreachable => '连不上 DeepSeek';

  @override
  String get stateAccountUnavailable => 'DeepSeek 暂时无法登录';

  @override
  String get stateSignInIncomplete => '登录没有完成';

  @override
  String get stateSignInTimeout => '登录超时';

  @override
  String get stateSignInSaveFailed => '登录信息没能保存';

  @override
  String get stateEngineNotReady => '引擎还没准备好';

  @override
  String get stateSignInInterrupted => '登录被中断';

  @override
  String get stateAccountUnsupported => '当前引擎不支持账号登录';

  @override
  String get stateCheckPhoneNetwork => '检查手机网络后重试';

  @override
  String get stateServiceUnavailableRetry => '服务暂时不可用，稍后重试';

  @override
  String get stateAuthorizationFailed => '授权没有成功，重新登录';

  @override
  String get stateAuthorizationExpired => '授权页面已失效，重新登录';

  @override
  String get stateRestartEngineRetry => '在「引擎」页重启后重试';

  @override
  String get stateEngineStartingRetry => '引擎正在启动，稍后再试';

  @override
  String get stateEngineDisconnectedSignIn => '引擎连接已断开，重新登录';

  @override
  String get stateUpdateRuntimeOrKey => '更新运行环境，或改用 API Key';

  @override
  String get stateEngineDisconnected => '引擎未连接';

  @override
  String get stateAgentError => '出错';

  @override
  String get stateNotRunning => '未运行';

  @override
  String get stateAgentOneShot => '一次性';

  @override
  String get stateAgentContinuable => '可继续';

  @override
  String get stateAgentExternal => '外部任务';

  @override
  String get stateSubagent => '子代理';

  @override
  String get stateParentChat => '上级对话';

  @override
  String get statePreparing => '准备中';

  @override
  String get stateIconMist => '雾蓝';

  @override
  String get stateIconNight => '夜幕';

  @override
  String get stateIconFrost => '霜白';

  @override
  String get stateIconInk => '墨';

  @override
  String get stateAppDisclaimer => '基于 DeepSeek Harness 构建 · 非 DeepSeek 官方应用';

  @override
  String get stateWallpaper => '壁纸';

  @override
  String get stateFileMissing => '找不到这个文件了，可能已被删除或移走';

  @override
  String get stateFileNoApp => '手机上没有能打开这类文件的应用';

  @override
  String get stateFileConnectionLimit => '文件太大，这个连接传不过来';

  @override
  String get stateFileReadUnsupported => '这个连接不支持读取文件';

  @override
  String get stateArtifactImage => '图片';

  @override
  String get stateArtifactDocument => '文档';

  @override
  String get stateArtifactSheet => '表格';

  @override
  String get stateArtifactSlides => '演示文稿';

  @override
  String get stateArtifactArchive => '压缩包';

  @override
  String get stateArtifactAudio => '音频';

  @override
  String get stateArtifactVideo => '视频';

  @override
  String get stateArtifactWeb => '网页';

  @override
  String get stateArtifactText => '文本';

  @override
  String get stateArtifactFile => '文件';

  @override
  String get statePrivateKeyTooLarge => '文件太大，不像是私钥';

  @override
  String get stateBotTeamBusy => '另一个 DSH 正在使用这个团队';

  @override
  String get stateBotOperationFailed => '没能完成操作，再试一次';

  @override
  String get stateBotMissing => '这台主机没有 DS Bot';

  @override
  String get stateHostAuthFailed => '没能通过主机的验证';

  @override
  String get stateUnexpectedError => '出了点问题';

  @override
  String get stateGroupChat => '群聊';

  @override
  String get stateBotNewMessage => 'Bot 有新消息';

  @override
  String get stateChatAgentBusy => 'AI 正忙，稍后再试';

  @override
  String get stateChatWriterHeld => '这个对话正在别处使用';

  @override
  String get stateChatModelUnavailable => '这个模型现在用不了';

  @override
  String get stateChatAttachmentInvalid => '这个附件发不了';

  @override
  String get stateChatForkUnavailable => '这里不能分叉';

  @override
  String get stateChatImagesTooLarge => '图片太大，少选几张再发';

  @override
  String get stateChatSyncInterrupted => '对话同步中断';

  @override
  String get stateChatSynchronizing => '正在同步对话';

  @override
  String get stateChatSyncRetry => '重新同步';

  @override
  String get stateChatSyncRequired => '对话尚未同步，请重新同步后再试';

  @override
  String get stateChatAutoApproveFailed => '自动允许失败';

  @override
  String get stateCommandMissing => '没有这个指令';

  @override
  String get stateCommandFailed => '指令没有执行';

  @override
  String get stateChatStopSteered => '没能停下本轮，已作为插话发送';

  @override
  String get stateChatTextOnlyModel => '当前模型未声明支持图片，已按文件发送。可换模型，或把自定义模型的输入类型设为「文本和图片」';

  @override
  String get stateAttachmentUploadFailed => '附件上传失败';

  @override
  String get stateChatImageModelRequired => '当前模型未声明支持图片。请换模型，或把自定义模型的输入类型设为「文本和图片」再发';

  @override
  String get stateSendFailed => '发送失败';

  @override
  String get stateChatStopFailed => '没能停下，再试一次';

  @override
  String get stateChatTurnEnded => '这一轮已经结束，消息会作为新一轮发送';

  @override
  String get stateChatSteerFailed => '插话失败';

  @override
  String get stateChatUndoTooLate => '来不及了，AI 已经读到这条消息';

  @override
  String get stateChatUndoFailed => '撤回失败';

  @override
  String get stateChatApprovalFailed => '审批提交失败';

  @override
  String get stateChatAnswerFailed => '回答提交失败';

  @override
  String get stateChatModelSwitchFailed => '切换模型失败';

  @override
  String get stateChatHistoryFailed => '加载历史失败';

  @override
  String get stateChatBranchLastReply => '只能从已完成的一轮的最后一条回复分叉';

  @override
  String get stateChatBranchFailed => '分叉失败';

  @override
  String get stateChatEarlierHistoryFailed => '读取更早的记录失败';

  @override
  String get stateChatNoEarlierHistory => '这条消息之前没有能保留的记录，直接新建对话就好';

  @override
  String get stateCommandNewDescription => '开始一个新对话';

  @override
  String get stateModelLabel => '模型';

  @override
  String get stateCommandModelDescription => '切换模型与思考深度';

  @override
  String get stateCommandExportLabel => '导出日志';

  @override
  String get stateCommandExportDescription => '把这个对话的完整记录打包成 ZIP，分享或存到「下载」';

  @override
  String get stateAllFeatures => '全部功能';

  @override
  String get stateCommandFeaturesDescription => '官方网页版每项功能的入口';

  @override
  String get stateCompactLabel => '压缩';

  @override
  String get stateCommandCompactDescription => '压缩以上对话内容，腾出上下文';

  @override
  String get statePermissionLabel => '权限';

  @override
  String get stateCommandPermissionDescription => '切换权限预设（沙箱模式与审批策略）';

  @override
  String get stateCommandPermissionHint => '<预设名>';

  @override
  String get statePlanLabel => '计划';

  @override
  String get stateCommandPlanDescription => '进入或退出计划模式';

  @override
  String get stateGoalLabel => '目标';

  @override
  String get stateCommandGoalDescription => '设置或查看长期任务目标';

  @override
  String get stateFeedbackLabel => '反馈';

  @override
  String get stateCommandFeedbackDescription => '发送关于当前对话的反馈';

  @override
  String get stateCommandFeedbackHint => '<内容>';

  @override
  String get stateShareFileTooLarge => '有文件太大，未添加';

  @override
  String get stateShareFileUnreadable => '有文件没能读取';

  @override
  String get stateShareImagesOnly => '当前主机只能发送图片';

  @override
  String get stateComposerInserted => '已放进输入框';

  @override
  String get stateCordisPending => '待确认';

  @override
  String get stateCordisStarting => '启动中';

  @override
  String get stateCordisRunFailed => '运行失败';

  @override
  String get stateCordisNoApproval => '没有获得运行许可';

  @override
  String get stateCordisBackendFailed => '后台部分没能启动';

  @override
  String get stateCordisClientLoadFailed => '界面没能加载';

  @override
  String get stateCordisRenderFailed => '界面显示出错';

  @override
  String get stateCordisFailed => '没能运行';

  @override
  String get stateDrawerAll => '全部';

  @override
  String get stateDrawerUnread => '未读';

  @override
  String get stateDrawerToday => '今天';

  @override
  String get stateDrawerThisWeek => '本周';

  @override
  String get stateDrawerEarlier => '更早';

  @override
  String get stateEngineAuthFailed => '没能通过引擎的验证';

  @override
  String get stateChatMissing => '这个对话已经不在了';

  @override
  String get stateChatFormatUnsupported => '当前引擎无法读取此对话的日志格式，请导出诊断包排查';

  @override
  String get stateEngineUnsupported => '当前引擎版本不支持';

  @override
  String get stateEngineServiceUnavailable => '所需的引擎服务未就绪，请查看引擎日志或导出诊断包';

  @override
  String get stateEngineOperationUnavailable => '引擎当前无法执行此操作，请查看引擎日志';

  @override
  String get stateSettingsRefreshed => '刚在别处改过，已刷新';

  @override
  String get stateCredentialFromEnvironment => '引擎的启动环境已提供这个 Key，无法在这里修改';

  @override
  String get stateSettingsFromFile => '由配置文件固定';

  @override
  String get stateSettingsInteger => '请填整数';

  @override
  String get stateSettingsInvalidFormat => '格式不对';

  @override
  String get stateSettingsReadOnly => '引擎设置是只读的';

  @override
  String get statePluginDisabled => '插件已停用';

  @override
  String get stateSettingsRestartRequired => '这一项要重启引擎才能改';

  @override
  String get stateSettingsInvalidValue => '值不合法';

  @override
  String get stateSettingsRejected => '引擎没有接受这个值';

  @override
  String get stateInventoryEnabled => '已启用';

  @override
  String get stateInventoryDisabled => '未启用';

  @override
  String get stateLoading => '加载中';

  @override
  String get stateInventoryWaiting => '等待依赖';

  @override
  String get stateInventoryConditional => '条件启用';

  @override
  String get stateBundleBuiltIn => 'DSH 内置';

  @override
  String get stateBundleHeadless => '无界面运行';

  @override
  String get stateConfigFile => '配置文件';

  @override
  String get stateGoalEmpty => '目标不能为空';

  @override
  String get stateGoalPauseFailed => '没能暂停';

  @override
  String get stateGoalResumeFailed => '没能恢复';

  @override
  String get stateGoalClearOffline => '没能清除：没能连上引擎';

  @override
  String get stateGoalClearFailed => '没能清除';

  @override
  String get stateGoalStale => '目标刚有变化，再试一次';

  @override
  String get stateGoalMissing => '目标已不在';

  @override
  String get stateGoalChatNotReady => '对话未就绪，稍后再试';

  @override
  String get stateGoalTurnsExhausted => '轮次已用完';

  @override
  String get stateGoalStateChanged => '目标状态已变化';

  @override
  String get stateSshHost => 'SSH 主机';

  @override
  String get stateHostBrowserFailed => '没能打开浏览器，可以复制登录链接到浏览器里完成。';

  @override
  String get stateSignInFailed => '没能登录';

  @override
  String get stateMarketTooLarge => '插件目录太大，已停止下载';

  @override
  String get stateMarketUnreachable => '没能连上插件目录';

  @override
  String get stateMarketInsecure => '没能和插件目录建立安全连接';

  @override
  String get stateMarketTimeout => '插件目录加载超时';

  @override
  String get stateMarketInterrupted => '插件目录下载中断';

  @override
  String get stateRegistryDefault => '默认安装源';

  @override
  String get stateRegistryNpm => 'npm 官方源';

  @override
  String get stateRegistryMirror => 'npmmirror 镜像';

  @override
  String get statePluginIncompatible => '这个插件不支持当前的 DSH 版本。';

  @override
  String get statePluginInstallCancelled => '已取消安装';

  @override
  String get statePluginNoChanges => '没有改动任何东西';

  @override
  String get statePluginIncompatibleTitle => '和当前 DSH 不兼容';

  @override
  String get statePluginNetworkFailed => '网络连不上';

  @override
  String get statePluginSourceUnreachable => '连不上插件源码所在的网站';

  @override
  String get statePluginDownloadTimeout => '下载超时';

  @override
  String get statePluginRegistryUnavailable => '安装源暂时没有响应';

  @override
  String get statePluginPnpmMissing => '缺少 pnpm';

  @override
  String get statePluginPhonePnpmMissing => '这台手机缺少 pnpm';

  @override
  String get statePluginHostPnpmMissing => '这台主机缺少 pnpm';

  @override
  String get statePluginNotFound => '找不到这个插件';

  @override
  String get statePluginPackageMissing => '安装源里没有这个包';

  @override
  String get statePluginTooNew => '版本太新';

  @override
  String get statePluginWaitForRelease => '发布满 24 小时后才能安装';

  @override
  String get statePluginVersionMissing => '找不到这个版本';

  @override
  String get statePluginRegistryVersionMissing => '安装源里还没有这个版本';

  @override
  String get stateDeviceStorageFull => '设备存储空间不足';

  @override
  String get statePluginNoWritePermission => '没有写入权限';

  @override
  String get statePluginConfigReadOnly => '引擎配置目录不可写';

  @override
  String get statePluginIntegrityFailed => '文件校验失败';

  @override
  String get statePluginDownloadIncomplete => '下载的文件不完整';

  @override
  String get statePluginBuildScripts => '需要运行构建脚本';

  @override
  String get statePluginBuildApproval => '构建脚本等待允许';

  @override
  String get statePluginAlreadyInstalled => '已经装过了';

  @override
  String get statePluginUninstallFirst => '换版本需先卸载';

  @override
  String get statePluginInvalid => '这不是 DSH 插件';

  @override
  String get statePluginNoEntry => '这个包没有插件入口，已撤销安装';

  @override
  String get statePluginInUse => '插件正在被使用';

  @override
  String get statePluginHasDependents => '有其他插件依赖它';

  @override
  String get statePluginManagedElsewhere => '不能在这里修改';

  @override
  String get statePluginEngineManaged => '这个插件由引擎单独管理';

  @override
  String get statePluginAuthorizationExpired => '授权已过期';

  @override
  String get statePluginBuildChanged => '构建脚本已变化，需要重新安装';

  @override
  String get statePluginInvalidAddress => '安装地址无效';

  @override
  String get statePluginCatalogInvalidAddress => '插件目录的安装地址不正确';

  @override
  String get statePluginOperationIncomplete => '操作没有完成';

  @override
  String get statePluginRemoteForbidden => '这台主机不允许远程安装';

  @override
  String get statePluginRelayToggleOnly => '经中转连接只能开关插件';

  @override
  String get statePluginManagementUnsupported => '主机不支持插件管理';

  @override
  String get statePluginEngineUnsupported => '当前引擎不支持插件管理';

  @override
  String get statePluginResultMissing => '没能拿到安装结果';

  @override
  String get statePluginResultPending => '安装结果待确认';

  @override
  String get statePluginDisconnected => '连接断开了';

  @override
  String get statePluginQueued => '排队中';

  @override
  String get statePluginRemoving => '正在卸载旧版本';

  @override
  String get statePluginInstalling => '正在下载安装';

  @override
  String get statePluginApplying => '正在启用';

  @override
  String get statePluginCancelling => '正在取消';

  @override
  String get statePluginInstalledRestart => '已安装，重启后生效';

  @override
  String get statePluginInstallFailed => '安装失败';

  @override
  String get statePluginConnectFirst => '连接后可安装插件';

  @override
  String get stateProviderOpenAi => 'OpenAI 兼容';

  @override
  String get stateProviderAnthropic => 'Anthropic 兼容';

  @override
  String get stateProviderUrlRequired => '填写 Base URL';

  @override
  String get stateProviderUrlInvalid => '以 http:// 或 https:// 开头的完整地址';

  @override
  String get stateProviderUrlSuffix => '去掉 ? 或 # 之后的部分';

  @override
  String get stateProviderKeyRequired => '填写 API Key';

  @override
  String get stateProviderKeyOnly => '只粘贴 Key 本身，不带变量名';

  @override
  String get stateProviderKeyQuotes => '去掉两边的引号';

  @override
  String get stateProviderKeyInvalid => 'Key 含有无效字符';

  @override
  String get stateProviderModelRequired => '填写模型 ID';

  @override
  String get stateProviderModelSpaces => '模型 ID 不能有空格';

  @override
  String get stateProviderAlreadyAdded => '已经添加过';

  @override
  String get stateProviderConflict => '渠道刚被改过，返回后重试';

  @override
  String get stateProviderUnsupported => '当前引擎版本不支持这个操作';

  @override
  String get stateProviderKeyRejected => 'API Key 无效或没有权限';

  @override
  String get stateProviderModelsMissing => '找不到模型列表。检查 Base URL；有的服务不提供模型列表，可以手动添加模型';

  @override
  String get stateProviderRateLimited => '请求太频繁，稍后再试';

  @override
  String get stateProviderResponseTooLarge => '返回的内容过大';

  @override
  String get stateProviderUnreachable => '连不上这个地址，检查 Base URL 和网络';

  @override
  String get stateProviderModelsUnreadable => '没有读到模型列表，检查 Base URL';

  @override
  String get stateProviderManualModels => '这个协议不能获取模型，请手动添加';

  @override
  String get stateProviderConfigRejected => '引擎拒绝了这个配置，检查协议和模型';

  @override
  String get stateProviderOffline => '没有连上引擎';

  @override
  String get stateSafeStartupFailed => '启动失败';

  @override
  String get stateSafeCrashedEarly => '启动后很快崩溃';

  @override
  String get stateSafeCrashedLate => '运行中崩溃';

  @override
  String get stateSafeKilled => '被系统结束';

  @override
  String get stateSafeManualEntry => '我手动进入了安全模式';

  @override
  String get stateScheduleNotCreated => '对话结束了，但没有建成任务';

  @override
  String get stateScheduleChatFailed => '对话出错了';

  @override
  String get stateScheduleResultPending => '还没等到结果';

  @override
  String get statePlanPending => '计划待审';

  @override
  String get stateQuestionPending => '待回答';

  @override
  String get stateExportRelayUnsupported => '经中转连接暂不支持导出';

  @override
  String get stateExportChatMissing => '找不到这个对话了';

  @override
  String get stateExportFailed => '没能导出';

  @override
  String get stateSizeExtraLarge => '特大';

  @override
  String get stateSubscriptionUnsupported => '当前引擎不支持订阅登录';

  @override
  String get stateSubscriptionUnreachable => '连不上登录服务，检查网络后重试';

  @override
  String get stateSubscriptionSignInFailed => '没能完成登录，再试一次';

  @override
  String get stateSubscriptionTimeout => '请求超时，检查网络后重试';

  @override
  String get stateSubscriptionDisconnected => '和引擎的连接断开了，稍后重试';

  @override
  String get stateTerminalLimit => '终端数量已达上限';

  @override
  String get stateTerminalStartFailed => '没能启动终端';

  @override
  String get stateTerminalDisabledOnHost => '这台电脑关掉了远程终端。在电脑上打开 Remote 设置里的「终端」，再回来重试';

  @override
  String get stateTileDuotone => '扁平双色';

  @override
  String get stateTileGeometric => '极简几何';

  @override
  String get stateTileGlassy => '玻璃渐变';

  @override
  String get stateUiNative => '原生';

  @override
  String get stateDefaultWorkspace => '默认工作区';

  @override
  String stateDiagnosticsSaved(String where) {
    return '已存到 $where';
  }

  @override
  String get stateDownloadsPrefix => '下载/';

  @override
  String stateSharePluginCount(int count) {
    return '$count 个插件';
  }

  @override
  String stateShareSkillCount(int count) {
    return '$count 个技能';
  }

  @override
  String stateShareSettingCount(int count) {
    return '$count 组设置';
  }

  @override
  String stateAlertCompletedReply(String reply) {
    return '已完成 · $reply';
  }

  @override
  String stateAlertErrorDetail(String detail) {
    return '出错了 · $detail';
  }

  @override
  String stateAlertUseTool(String name) {
    return '使用工具 $name';
  }

  @override
  String stateAlertApprovalAction(String action) {
    return '等你确认：$action';
  }

  @override
  String stateAlertApprovalReason(String action, String reason) {
    return '等你确认：$action · $reason';
  }

  @override
  String stateAlertQuestions(String question, int count) {
    return '问你：$question（共 $count 个）';
  }

  @override
  String stateAlertQuestionText(String question) {
    return '问你：$question';
  }

  @override
  String statePetChatsDone(int count) {
    return '$count 个对话做完了';
  }

  @override
  String statePetChatsFailed(int count) {
    return '$count 个对话出错了';
  }

  @override
  String statePetChatsApproval(int count) {
    return '$count 个对话等你确认';
  }

  @override
  String statePetChatsQuestion(int count) {
    return '$count 个对话等你回答';
  }

  @override
  String stateAttachmentEmpty(String name) {
    return '「$name」是空文件';
  }

  @override
  String stateAttachmentImageLimit(String name) {
    return '图片「$name」超过 20 MB';
  }

  @override
  String stateAttachmentFileLimit(String name) {
    return '文件「$name」超过 200 MB';
  }

  @override
  String get stateAttachmentTotalLimit => '附件总大小超过 400 MB';

  @override
  String stateBotFinished(String name) {
    return '$name 完成了工作';
  }

  @override
  String stateBotQuestion(String name, String text) {
    return '$name 问你：$text';
  }

  @override
  String stateBotApproval(String name, String text) {
    return '$name 等你批准：$text';
  }

  @override
  String get stateCommandPlanHint => '[off | 要求]';

  @override
  String get stateCommandGoalHint => '[目标 | clear | pause | resume]';

  @override
  String stateShareReadFailed(String name) {
    return '没能读取「$name」';
  }

  @override
  String stateShareAttachmentLimit(int count) {
    return '每条消息最多 $count 个附件';
  }

  @override
  String stateShareNamedFileTooLarge(String name) {
    return '「$name」太大，未添加';
  }

  @override
  String stateShareTextTruncated(int count) {
    return '文字太长，只保留了前 $count 字';
  }

  @override
  String stateSettingsMinimum(String bound) {
    return '不能小于 $bound';
  }

  @override
  String stateSettingsMaximum(String bound) {
    return '不能大于 $bound';
  }

  @override
  String stateSettingsMultiple(String bound) {
    return '需是 $bound 的倍数';
  }

  @override
  String stateSettingsMinLength(int count) {
    return '至少 $count 个字符';
  }

  @override
  String stateSettingsMaxLength(int count) {
    return '最多 $count 个字符';
  }

  @override
  String stateEngineHttpRejected(int status) {
    return '引擎拒绝了请求（$status）';
  }

  @override
  String stateGoalActionOffline(String action) {
    return '$action：没能连上引擎';
  }

  @override
  String stateHostRemoteLabel(String name) {
    return '$name · 远程';
  }

  @override
  String stateMarketHttpError(int status) {
    return '插件目录暂时打不开（HTTP $status）';
  }

  @override
  String statePluginRuntimeIncompatible(String version) {
    return '这个插件不支持当前的 DSH 版本（$version）。';
  }

  @override
  String statePluginRequiredVersion(String wanted, String current) {
    return '这个插件要求 DSH $wanted，当前是 $current。';
  }

  @override
  String get statePluginRegistryUnreachable => '没能连上安装源';

  @override
  String statePluginNamedRegistryUnreachable(String registry) {
    return '没能连上安装源（$registry）';
  }

  @override
  String statePluginBuildsPending(String builds) {
    return '等待允许：$builds';
  }

  @override
  String statePluginRegistryProgress(String registry, int attempt, int attempts) {
    return '换用$registry下载（第 $attempt/$attempts 个源）';
  }

  @override
  String stateProviderServiceUnavailable(int status) {
    return '服务暂时不可用（$status）';
  }

  @override
  String stateProviderServiceStatus(int status) {
    return '服务返回了 $status';
  }

  @override
  String stateProviderKeySaveFailed(String reason) {
    return '渠道已保存，Key 没有存上：$reason';
  }

  @override
  String stateSafeSuspectPlugins(String what, String plugins) {
    return '$what，可疑插件：$plugins';
  }

  @override
  String stateSafePreflightFailed(String what, String checks) {
    return '$what，启动检查没通过：$checks';
  }

  @override
  String get stateListSeparator => '、';

  @override
  String stateSafeRepairPrompt(String what) {
    return '我的 DSH 正常模式出了问题（$what）。请按「安全模式」说明排查原因，先用可逆的办法修好 web 配置，修完用 dsh-app-plugins trial 试启动验证，再告诉我改了什么。';
  }

  @override
  String stateScheduleCreatePrompt(String title, String rule, String args) {
    return '新建自动化任务「$title」：$rule。\n只调用一次 schedule_create，参数原样使用；现在不要执行任务内容。\n\n```json\n$args\n```';
  }

  @override
  String stateActionReason(String action, String reason) {
    return '$action：$reason';
  }

  @override
  String stateAlertPreviewRun(String value) {
    return '运行：$value';
  }

  @override
  String stateAlertPreviewWrite(String value) {
    return '写入：$value';
  }

  @override
  String stateAlertPreviewEdit(String value) {
    return '修改：$value';
  }

  @override
  String stateAlertPreviewOpen(String value) {
    return '打开：$value';
  }

  @override
  String stateAlertPreviewUse(String value) {
    return '使用工具：$value';
  }

  @override
  String get stateUiWeb => '网页';

  @override
  String statePluginRegistryProgressUnknown(String registry, int attempt) {
    return '换用$registry下载（第 $attempt/null 个源）';
  }

  @override
  String get stateProviderTokenCountInvalid => '填写数字，如 128K';

  @override
  String get appSlogan => '随时随刻，想go就Go！';

  @override
  String get statePasteEmpty => '剪贴板中没有可粘贴的文本。';

  @override
  String get statePasteDenied => '系统未授予粘贴权限，请重新点击粘贴按钮。';

  @override
  String get statePasteBusy => '粘贴窗口尚未结束或仍在关闭，请完成或取消后重试。';

  @override
  String get statePasteFailed => '无法读取剪贴板，请重试或手动输入。';

  @override
  String get systemActionsTitle => '系统操作';

  @override
  String get systemActionsSubtitle => '让 AI 帮你打开应用和系统页面，随时可以关';

  @override
  String get systemActionsReady => '已开启';

  @override
  String get systemActionsWaitingEngine => '已开启，等本机引擎启动';

  @override
  String get systemActionsOffScreen => '已开启，回到 DSH Go 才能用';

  @override
  String get systemActionsConnecting => '正在连接';

  @override
  String get systemActionsUnavailable => '已开启，暂时连不上，正在重试';

  @override
  String get systemActionsUnsupported => '这个版本用不了';

  @override
  String get systemActionsToggleFailed => '没能保存，再试一次';

  @override
  String get systemActionsRemoteTitle => '当前连的是远程主机';

  @override
  String get systemActionsRemoteHint => '系统操作只在本机引擎的对话里有效';

  @override
  String get systemActionsOnScreenTitle => '只在 DSH Go 在屏幕上时有效';

  @override
  String get systemActionsOnScreenBody => '系统不让后台应用做这些。AI 打开别的应用后，要等你回到 DSH Go 才能接着做。';

  @override
  String get systemActionsCanTitle => '能做的';

  @override
  String get systemActionsCanOpen => '打开应用或链接';

  @override
  String get systemActionsCanOpenHint => '应用要写包名，不能按名字找';

  @override
  String get systemActionsCanPages => '日历、拨号、分享、导航';

  @override
  String get systemActionsCanPagesHint => '打开系统界面，最后一步由你确认';

  @override
  String get systemActionsCanSettings => '部分系统设置页';

  @override
  String get systemActionsCanSettingsHint => '移动网络、显示、声音、NFC 和本应用的通知';

  @override
  String get systemActionsCanNotify => '发通知';

  @override
  String get systemActionsCanNotifyHint => '发出去不代表你已经看到';

  @override
  String get systemActionsCanClipboard => '写剪贴板';

  @override
  String get systemActionsCanClipboardHint => '只写不读';

  @override
  String get systemActionsCanHandoff => '交还给你';

  @override
  String get systemActionsCanHandoffHint => '登录、验证码这类步骤你来做，做完点继续';

  @override
  String get systemActionsCannotTitle => '做不到的';

  @override
  String get systemActionsCannotScreen => '看屏幕、点按其他应用';

  @override
  String get systemActionsCannotScreenHint => '系统不允许';

  @override
  String get systemActionsCannotOther => '读剪贴板、按名字找应用、短信';

  @override
  String get systemActionsCannotOtherHint => '没有可靠的公开接口，AI 会直接告诉你不支持';

  @override
  String get systemActionsConfirmTitle => '确认方式';

  @override
  String get systemActionsConfirmValue => '跟随权限';

  @override
  String get systemActionsConfirmHint => '按对话的权限来：一般每次先问你，完全权限时不问';

  @override
  String get systemActionsPermissionNote => '系统操作也按这里的权限询问：完全权限时不问，其他情况每次先问你。';

  @override
  String get systemActionsLogHint => '只记做了什么和结果，不记内容';

  @override
  String get systemActionsLogEmptyHint => 'AI 用过的系统操作都会记在这里';

  @override
  String get systemActionsOpenedUi => '已打开界面';

  @override
  String get systemActionsResultUnknown => '结果未知';

  @override
  String get systemActionsNotSupported => '不支持';

  @override
  String get systemActionsNotRun => '没有执行';

  @override
  String get systemActionsDisclosureTitle => '开启系统操作前';

  @override
  String get systemActionsDisclosureIntro => '开启后，AI 可以在对话里替你打开应用和系统页面。先了解这几点：';

  @override
  String get systemActionsDisclosureWhatTitle => '能做什么';

  @override
  String get systemActionsDisclosureWhatBody => '打开应用或链接，打开日历、拨号、分享、导航界面，发通知，写剪贴板，把步骤交还给你。这个版本开通了系统提醒时，还能设闹钟和计时器。';

  @override
  String get systemActionsDisclosureWhenTitle => '什么时候做';

  @override
  String get systemActionsDisclosureWhenBody => '只在对话用到、DSH Go 在屏幕上时。默认每次先问你，选了完全权限的对话不问。';

  @override
  String get systemActionsDisclosureWhoTitle => '发给谁';

  @override
  String get systemActionsDisclosureWhoBody => '动作的结果会回到对话，发给你选的模型。';

  @override
  String get systemActionsDisclosureNeverTitle => '不会做什么';

  @override
  String get systemActionsDisclosureNeverBody => '不看屏幕，不点按其他应用，不读剪贴板。打电话、分享、建日程的最后一步由你确认。';

  @override
  String get systemActionsDisclosureStopTitle => '怎么停';

  @override
  String get systemActionsDisclosureStopBody => '随时在这里关掉。交还提示可以点停止。';

  @override
  String get systemActionsHandoffTitle => '轮到你来操作';

  @override
  String get systemActionsHandoffNote => '做完回到 DSH Go 点继续。继续只表示你确认了，AI 看不到其他应用里发生了什么。';

  @override
  String get systemActionsHandoffFailed => '这次没算上，提示如果还在可以再点一次';

  @override
  String get systemActionsResultOpened => '已打开界面，还没确认里面的事办完。';

  @override
  String get systemActionsResultContinued => '你点了继续。这只说明你确认了，不代表其他应用里的操作完成了。';

  @override
  String get systemActionsResultNotified => '通知已发出，不确定你有没有看到。';

  @override
  String get systemActionsResultReminder => '已交给系统提醒，到点由系统响。引擎不会因此运行。';

  @override
  String get systemActionsResultClipboard => '文字已写入剪贴板。';

  @override
  String get systemActionsResultUnknownDetail => '系统调用可能已经发出，结果未知。不会自动重试，请自己看一下实际状态。';

  @override
  String get systemActionsResultUnsupported => '鸿蒙版不支持这个动作，没有执行。';

  @override
  String get systemActionsResultOffScreen => 'DSH Go 不在屏幕上，没有执行。';

  @override
  String get systemActionsResultUnavailable => '系统操作没开或暂时连不上，没有执行。到「设置 → 系统操作」看看。';

  @override
  String get systemActionsResultStopped => '已停止。';

  @override
  String get systemActionsResultTimeout => '等待超时，没有结果。';

  @override
  String get systemActionsResultNotRun => '没有执行。';

  @override
  String get catalogSystemActions => '系统操作';

  @override
  String get catalogSystemActionsSummary => '打开应用和系统页面';

  @override
  String get searchKwSystemActions => '手机操控,操作手机,代操作,打开应用,打开链接,日历,拨号,分享,导航,发通知,写剪贴板,交还,闹钟,计时器';

  @override
  String get tavernTitle => '酒馆';

  @override
  String get tavernImport => '导入';

  @override
  String get tavernEmptyTitle => '还没有角色';

  @override
  String get tavernEmptyMessage => '接回 DeepSeek 里的对话，或导入一张角色卡';

  @override
  String get tavernContinue => '继续';

  @override
  String get tavernCharacters => '角色';

  @override
  String tavernImported(String name) {
    return '已导入「$name」';
  }

  @override
  String get tavernImportLorebook => '这是一本世界书，不是角色卡';

  @override
  String get tavernImportFailed => '这张卡读不出来';

  @override
  String get tavernCharacterGone => '这个角色已经不在了';

  @override
  String get tavernDeleteCharacter => '删除角色';

  @override
  String tavernDeleteCharacterTitle(String name) {
    return '删除「$name」？';
  }

  @override
  String get tavernDeleteCharacterMessage => '它的对话也会一起删掉。';

  @override
  String get tavernGreeting => '开场白';

  @override
  String tavernGreetingOf(int index, int count) {
    return '开场白 $index/$count';
  }

  @override
  String get tavernStart => '开始';

  @override
  String get tavernContinueLast => '继续上次';

  @override
  String get tavernStartNew => '用这个开场白开始新对话';

  @override
  String get tavernChats => '对话';

  @override
  String tavernMessageCount(int count) {
    return '$count 条消息';
  }

  @override
  String get tavernCreatorNotes => '作者说明';

  @override
  String get tavernDefinition => '设定';

  @override
  String tavernComposerHint(String name) {
    return '对$name说…';
  }

  @override
  String get tavernReplying => '正在回复…';

  @override
  String get tavernReady => '就绪';

  @override
  String get tavernPreviewStatus => '预览 · 示例回复';

  @override
  String get tavernRegenerate => '重新生成';

  @override
  String get tavernContinueReply => '接着写';

  @override
  String get tavernDeleteFrom => '删除这条及以后';

  @override
  String get tavernPrevious => '上一个回答';

  @override
  String get tavernNext => '下一个回答';

  @override
  String get tavernErrorNoKey => '先在设置里填 DeepSeek API Key';

  @override
  String get tavernKeyMissing => '还没填 DeepSeek API Key';

  @override
  String get tavernKeyMissingAction => '去填写';

  @override
  String get tavernErrorBadKey => 'API Key 不对，去设置里检查一下';

  @override
  String get tavernErrorBusy => '模型现在有点忙，稍后再试';

  @override
  String get tavernErrorNetwork => '连不上，检查网络后重试';

  @override
  String get tavernErrorTooLong => '对话太长了，超出了模型的上下文';

  @override
  String get tavernCutShort => '回复到了回复上限。可以接着写，或调高这段对话所用预设的回复上限。';

  @override
  String get tavernFiltered => '回复有一部分被内容过滤拦下了。';

  @override
  String get tavernErrorBalance => 'DeepSeek 账户余额不足，充值后再试';

  @override
  String get tavernErrorParameters => '模型不接受这次请求的参数';

  @override
  String tavernErrorParametersDetail(String detail) {
    return '模型不接受这次请求的参数：$detail';
  }

  @override
  String tavernErrorDetail(String detail) {
    return '出错了：$detail';
  }

  @override
  String get tavernSettings => '酒馆设置';

  @override
  String get tavernSettingsModel => '模型';

  @override
  String get tavernModelFlash => 'Flash';

  @override
  String get tavernModelPro => 'V4 Pro';

  @override
  String get tavernThinking => '思考';

  @override
  String get tavernThinkingSubtitle => '回复前先想一想';

  @override
  String get tavernApiKey => 'DeepSeek API Key';

  @override
  String get tavernApiKeySet => '已填';

  @override
  String get tavernApiKeyMissing => '未填';

  @override
  String get tavernDeleteChat => '删除对话';

  @override
  String get tavernDeleteChatTitle => '删除这段对话？';

  @override
  String get tavernDeleteChatMessage => '删除后就找不回来了。';

  @override
  String tavernDeleteFromTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '删除这 $count 条消息？', one: '删除这条消息？');
    return '$_temp0';
  }

  @override
  String get tavernDeleteFromMessage => '从这条到最新一条，连同它们的备选回复和分支。删除后就找不回来了。';

  @override
  String get tavernSwitchedBranch => '切到了另一条分支';

  @override
  String get tavernUndo => '撤销';

  @override
  String get tavernSettingsDisplay => '显示';

  @override
  String get tavernPresets => '预设';

  @override
  String get tavernPresetImport => '导入预设';

  @override
  String get tavernPresetStDefault => 'SillyTavern 默认预设';

  @override
  String get tavernPresetStDefaultNote => '没选预设时用它';

  @override
  String get tavernPresetDefault => '默认';

  @override
  String get tavernPresetSetDefault => '设为默认';

  @override
  String get tavernPresetUnsetDefault => '不再作为默认';

  @override
  String get tavernPresetExport => '导出预设';

  @override
  String get tavernPresetDelete => '删除预设';

  @override
  String tavernPresetDeleteTitle(String name) {
    return '删除预设「$name」？';
  }

  @override
  String get tavernPresetDeleteMessage => '用它的对话会改用默认预设。删除后就找不回来了。';

  @override
  String tavernPresetImported(String name) {
    return '已导入「$name」';
  }

  @override
  String tavernPresetImportedWithIssues(String name, int count) {
    return '已导入「$name」，有 $count 处提示';
  }

  @override
  String tavernPresetImportFailed(String reason) {
    return '没能导入：$reason';
  }

  @override
  String get tavernPresetNotText => '这个文件不是文本';

  @override
  String get tavernPresetsEmptyMessage => 'SillyTavern 导出的预设 JSON 和 dsh-preset-enhance 的分享包都能导入。';

  @override
  String get tavernPresetEnvelope => '分享包';

  @override
  String tavernPresetCount(int count) {
    return '$count 个';
  }

  @override
  String get tavernRegex => '正则';

  @override
  String get tavernRegexImport => '导入正则';

  @override
  String get tavernRegexOn => '开';

  @override
  String get tavernRegexOff => '关';

  @override
  String get tavernRegexEnable => '启用';

  @override
  String get tavernRegexDisable => '停用';

  @override
  String get tavernRegexExport => '导出正则';

  @override
  String get tavernRegexDelete => '删除正则';

  @override
  String tavernRegexDeleteTitle(String name) {
    return '删除正则「$name」？';
  }

  @override
  String tavernRegexImported(int count) {
    return '导入了 $count 条正则';
  }

  @override
  String get tavernRegexIncompatible => '这里运行不了，已跳过';

  @override
  String get tavernRegexEmpty => '还没有全局正则';

  @override
  String get tavernRegexEmptyMessage => '可以导入 SillyTavern 导出的正则 JSON，一条或一组';

  @override
  String get tavernRegexUnnamed => '未命名';

  @override
  String tavernRegexCount(int count) {
    return '$count 条';
  }

  @override
  String get tavernLorebooks => '世界书';

  @override
  String get tavernLorebookImport => '导入世界书';

  @override
  String get tavernLorebookGlobal => '全局';

  @override
  String get tavernLorebookBindGlobal => '对所有对话生效';

  @override
  String get tavernLorebookUnbindGlobal => '不再对所有对话生效';

  @override
  String get tavernLorebookExport => '导出世界书';

  @override
  String get tavernLorebookDelete => '删除世界书';

  @override
  String tavernLorebookDeleteTitle(String name) {
    return '删除世界书「$name」？';
  }

  @override
  String get tavernLorebookDeleteMessage => '绑定它的地方会跳过它。删除后就找不回来了。';

  @override
  String tavernLorebookImported(String name, int count) {
    return '已导入「$name」，$count 条';
  }

  @override
  String get tavernLorebooksEmpty => '还没有独立世界书';

  @override
  String get tavernLorebooksEmptyMessage => '可以导入 SillyTavern 导出的世界书 JSON';

  @override
  String tavernLorebookCount(int count) {
    return '$count 本';
  }

  @override
  String get tavernPresetEdit => '编辑预设';

  @override
  String get tavernPresetParams => '参数';

  @override
  String get tavernPresetPrompts => '提示词（按发送顺序）';

  @override
  String get tavernPresetMarker => '占位';

  @override
  String get tavernPresetPromptsEmpty => '这个预设没写提示词顺序，发送时用 SillyTavern 的默认顺序。';

  @override
  String get tavernReport => '导入体检';

  @override
  String get tavernVerdictUsable => '能用';

  @override
  String get tavernVerdictPartial => '部分能用';

  @override
  String get tavernVerdictPreserve => '只保留，不执行';

  @override
  String tavernReportChecked(String time) {
    return '检查于 $time';
  }

  @override
  String get tavernReportStale => '资料改过了，这份体检是旧的';

  @override
  String get tavernReportRecheck => '重新检查';

  @override
  String get tavernReportNone => '还没有体检';

  @override
  String get tavernReportNoneMessage => '这份资料是加体检之前导入的，检查一下就有了。';

  @override
  String get tavernReportCheckNow => '检查一下';

  @override
  String get tavernReportRender0 => '建议显示方式：原生';

  @override
  String get tavernReportRender1 => '建议显示方式：单条消息里的网页';

  @override
  String get tavernReportRender2 => '建议显示方式：整页画布';

  @override
  String get tavernReportCounts => '里面有';

  @override
  String get tavernReportFindings => '没执行或要留意的';

  @override
  String get tavernReportNoFindings => '没有要留意的';

  @override
  String get tavernPresetForChat => '这段对话用的预设';

  @override
  String get tavernPresetFollow => '跟随默认';

  @override
  String tavernPresetFollowDefault(String name) {
    return '跟随默认（$name）';
  }

  @override
  String get tavernPresetPickerEmpty => '在 资源库 › 预设 里导入以后，就能给这段对话换别的。';

  @override
  String get tavernSectionShelf => '书架';

  @override
  String get tavernSectionChats => '对话';

  @override
  String get tavernSectionLibrary => '资源库';

  @override
  String get tavernSectionMe => '我的';

  @override
  String get tavernNoChats => '还没有对话';

  @override
  String get tavernNoChatsMessage => '在书架里点开一个角色，开始第一段对话。';

  @override
  String get tavernSettingsGeneration => '生成';

  @override
  String get tavernMaxContext => '上下文上限';

  @override
  String get tavernMaxReply => '回复上限';

  @override
  String get tavernTemperature => '温度';

  @override
  String get tavernGenerationNote => '上下文越长，角色记得越多，每回合也越贵；数字是 token。这里改的是默认预设，自带预设的对话以它自己的为准。';

  @override
  String get tavernLayout => '排版';

  @override
  String get tavernLayoutBubble => '气泡';

  @override
  String get tavernLayoutNovel => '小说';

  @override
  String get tavernYou => '你';

  @override
  String get tavernSearchHint => '搜索角色、作者、标签';

  @override
  String get tavernAllTags => '全部';

  @override
  String get tavernNoMatch => '没有符合的角色';

  @override
  String get tavernLayoutVisualNovel => '视觉小说';

  @override
  String get tavernCharacterDetails => '角色详情';

  @override
  String get tavernChatLayout => '这段对话的排版';

  @override
  String get tavernFollowSettings => '跟随酒馆设置';

  @override
  String get tavernLog => '记录';

  @override
  String get tavernEditCharacter => '编辑角色';

  @override
  String get tavernNameNeeded => '名字不能空着';

  @override
  String get tavernFieldsBasics => '基本';

  @override
  String get tavernFieldNickname => '昵称';

  @override
  String get tavernFieldNicknameHelp => '填了的话，对话里用它称呼角色';

  @override
  String get tavernFieldTags => '标签';

  @override
  String get tavernFieldTagsHelp => '用逗号隔开';

  @override
  String get tavernFieldCreator => '作者';

  @override
  String get tavernFieldVersion => '版本';

  @override
  String get tavernFieldDescription => '描述';

  @override
  String get tavernFieldPersonality => '性格';

  @override
  String get tavernFieldScenario => '场景';

  @override
  String tavernGreetingNumber(int n) {
    return '开场白 $n';
  }

  @override
  String get tavernFieldGreetingsNote => '新对话可以从任意一条开场白开始。';

  @override
  String get tavernAddGreeting => '加一条开场白';

  @override
  String get tavernMoreFields => '更多字段';

  @override
  String get tavernMoreFieldsSubtitle => '示例对话、系统提示、历史后指令';

  @override
  String get tavernFieldExamples => '示例对话';

  @override
  String get tavernFieldExamplesHelp => '每段示例用一行 <START> 开头';

  @override
  String get tavernFieldPrompts => '提示词';

  @override
  String get tavernFieldPromptsNote => '填了就替换预设里对应的那一段；留空用预设的。';

  @override
  String get tavernFieldSystemPrompt => '系统提示';

  @override
  String get tavernFieldPostHistory => '历史后指令';

  @override
  String get tavernFieldNotesNote => '写给看卡的人，不发给模型。';

  @override
  String tavernEditKeeps(int count) {
    return '卡里还有 $count 项这里改不了的内容（世界书、扩展等），保存时原样保留；已有的对话也不会变。';
  }

  @override
  String get tavernEditKeepsChats => '保存后，已有的对话不会变。';

  @override
  String get tavernPersonas => '人设';

  @override
  String get tavernPersona => '人设';

  @override
  String get tavernPersonaNew => '新建人设';

  @override
  String get tavernPersonasEmpty => '还没有人设';

  @override
  String get tavernPersonasEmptyMessage => '人设是你在对话里扮演的人：一个名字和一段介绍，角色就知道你是谁。';

  @override
  String get tavernPersonasNote => '长按可设为默认或删除';

  @override
  String get tavernPersonaUnsetDefault => '不再作为默认';

  @override
  String get tavernPersonaSetDefault => '设为默认人设';

  @override
  String tavernPersonaDeleteTitle(String name) {
    return '删除「$name」？';
  }

  @override
  String get tavernPersonaDeleteMessage => '用它的对话会改用默认人设，已经写下的内容不变。';

  @override
  String get tavernPersonaEdit => '编辑人设';

  @override
  String get tavernPersonaPickAvatar => '换头像';

  @override
  String get tavernPersonaRemoveAvatar => '去掉头像';

  @override
  String get tavernPersonaAvatarFailed => '没能用上这张图片';

  @override
  String get tavernPersonaNameHint => '角色怎么称呼你';

  @override
  String get tavernPersonaDescriptionHelp => '你是谁、什么样子、和角色的关系';

  @override
  String get tavernPersonaDescriptionHint => '比如：镇上新来的医生，话不多，总拎着一个旧皮箱。';

  @override
  String get tavernPersonaDefaultSubtitle => '没单独选人设的对话都用它';

  @override
  String get tavernPersonaDelete => '删除人设';

  @override
  String get tavernPersonaNone => '没有人设';

  @override
  String tavernPersonaAs(String name) {
    return '以「$name」的身份';
  }

  @override
  String get tavernPersonaForChat => '这段对话里你是';

  @override
  String get tavernPersonaFollowDefault => '跟随默认';

  @override
  String get tavernPersonasManage => '管理人设';

  @override
  String get tavernSettingsYou => '你';

  @override
  String get tavernDefaultPersona => '默认人设';

  @override
  String get tavernPersonaNotSet => '未设置';

  @override
  String get tavernLibraryNone => '无';

  @override
  String get tavernFieldName => '名字';

  @override
  String get tavernOpenFailed => '酒馆没能打开';

  @override
  String get tavernOpenFailedMessage => '存角色和对话的数据没能打开。重试一下；还不行的话，重启 App 再试。';

  @override
  String get tavernExportPng => '导出角色卡（PNG）';

  @override
  String get tavernExportPngSubtitle => 'SillyTavern 等酒馆都能导入';

  @override
  String get tavernExportJson => '导出为 JSON';

  @override
  String get tavernExportFailed => '没能导出这张卡';

  @override
  String get tavernInspectTitle => '这一回合发了什么';

  @override
  String get tavernInspectMenu => '看看发了什么';

  @override
  String get tavernInspectLatest => '上一回合发了什么';

  @override
  String get tavernInspectNone => '这条没有记录';

  @override
  String get tavernInspectNoneMessage => '开场白、接上引擎之前的消息和示例回复没有检视记录。';

  @override
  String get tavernInspectSummary => '概况';

  @override
  String get tavernInspectKind => '类型';

  @override
  String get tavernTurnSend => '发送';

  @override
  String get tavernTurnImpersonate => '代写';

  @override
  String get tavernInspectStatus => '结果';

  @override
  String get tavernInspectPreparing => '准备中';

  @override
  String get tavernInspectReady => '已发出';

  @override
  String get tavernInspectCompleted => '完成';

  @override
  String get tavernInspectFailed => '失败';

  @override
  String get tavernInspectPrompt => '提示词';

  @override
  String tavernTokens(int count) {
    return '$count tokens';
  }

  @override
  String tavernTokensAbout(int count) {
    return '约 $count tokens';
  }

  @override
  String get tavernInspectBudget => '上下文预算剩余';

  @override
  String get tavernInspectUsage => '模型报告的用量';

  @override
  String get tavernInspectNoUsage => '没报告';

  @override
  String tavernInspectUsageValue(int prompt, int hit, int completion) {
    return '输入 $prompt（缓存 $hit）· 输出 $completion';
  }

  @override
  String get tavernInspectCost => '估算费用';

  @override
  String get tavernInspectCostPeak => '按 DeepSeek 官方价，高峰时段';

  @override
  String get tavernInspectCostOffPeak => '按 DeepSeek 官方价，低谷时段（半价）';

  @override
  String tavernInspectSegments(int count) {
    return '发出去的 $count 段';
  }

  @override
  String get tavernInspectSegmentsNote => '按发送顺序。点开看全文，长按复制。';

  @override
  String tavernInspectWorld(int count) {
    return '世界书命中 $count 条';
  }

  @override
  String tavernInspectWorldKey(String key) {
    return '关键词「$key」';
  }

  @override
  String tavernInspectExcluded(int count) {
    return '没发出去的 $count 段';
  }

  @override
  String get tavernExcludeDisabled => '关着';

  @override
  String get tavernExcludeTrigger => '不在这种生成里';

  @override
  String get tavernExcludeHidden => '对模型隐藏';

  @override
  String get tavernExcludeSystem => '系统消息';

  @override
  String get tavernExcludeHistoryBudget => '超出上下文预算';

  @override
  String get tavernExcludeExampleBudget => '示例超出预算';

  @override
  String get tavernRoleSystem => '系统';

  @override
  String get tavernRoleUser => '你';

  @override
  String get tavernRoleCharacter => '角色';

  @override
  String get tavernSourcePreset => '预设';

  @override
  String get tavernSourceCard => '角色卡';

  @override
  String get tavernSourceWorld => '世界书';

  @override
  String get tavernSourcePersona => '人设';

  @override
  String get tavernSourceHistory => '对话';

  @override
  String get tavernSourceControl => '控制';

  @override
  String get tavernWriteForMe => '帮我写';

  @override
  String get tavernHide => '对模型隐藏';

  @override
  String get tavernUnhide => '让模型看到';

  @override
  String get tavernHiddenFromModel => '模型看不到这条';

  @override
  String get tavernTrySample => '试试示范卡';

  @override
  String get tavernImportChats => '导入聊天记录';

  @override
  String get tavernImportChatsSubtitle => 'SillyTavern 的 .jsonl，可以一次选几个';

  @override
  String get tavernOnlyJsonl => '只能导入 .jsonl 聊天记录';

  @override
  String tavernImportChatsFailed(String detail) {
    return '没能导入：$detail';
  }

  @override
  String tavernImportedChats(int count) {
    return '导入了 $count 段对话';
  }

  @override
  String get tavernImportNoticesTitle => '导入时注意到';

  @override
  String get tavernExportChat => '导出聊天记录';

  @override
  String get tavernExportChatFailed => '没能导出这段对话';

  @override
  String get tavernLorebook => '世界书';

  @override
  String get tavernLorebookSubtitle => '卡里自带的条目';

  @override
  String tavernLorebookEntries(int count) {
    return '$count 条';
  }

  @override
  String get tavernLorebookNote => '对话里提到关键词时，对应条目会带进提示词；「常驻」的每次都带。';

  @override
  String tavernLorebookKeys(String keys) {
    return '关键词：$keys';
  }

  @override
  String get tavernLorebookConstant => '常驻';

  @override
  String get tavernLorebookOff => '已关';

  @override
  String get tavernLorebookEmpty => '这张卡没有世界书';

  @override
  String get tavernImportFromFile => '从文件导入';

  @override
  String get tavernImportFromFileSubtitle => '角色卡、预设、世界书等，自动识别';

  @override
  String get tavernImportFromLink => '从链接导入';

  @override
  String get tavernImportFromLinkSubtitle => 'Chub、RisuRealm 或卡文件的链接';

  @override
  String get tavernLinkInvalid => '这不是一个网址';

  @override
  String get tavernLinkFailed => '下载失败，检查网络或链接';

  @override
  String tavernLinkStatus(int status) {
    return '下载失败（HTTP $status）';
  }

  @override
  String get tavernLinkIsPage => '这是网页，不是卡文件。Chub 和 RisuRealm 的角色页可以直接贴；别的站打开网页找「下载」，拿到 .png 或 .json 的链接再试。';

  @override
  String get tavernLinkSiteMissing => '站上没有这个角色，可能删了或没公开';

  @override
  String get tavernQuickReplies => '快速回复';

  @override
  String get tavernQuickRepliesEmpty => '还没有快速回复';

  @override
  String get tavernQuickRepliesNote => '对话里输入框上方会出现这些：点一下直接发出去，长按放进输入框再改。';

  @override
  String get tavernQuickReplyAdd => '加一条';

  @override
  String get tavernQuickReplyHint => '比如：*环顾四周，看有没有别人*';

  @override
  String tavernQuickReplyCount(int count) {
    return '$count 条';
  }

  @override
  String get tavernEditMessage => '编辑消息';

  @override
  String get tavernBackground => '背景图';

  @override
  String get tavernBackgroundNone => '无';

  @override
  String get tavernBackgroundChange => '换一张';

  @override
  String get tavernBackgroundRemove => '去掉背景图';

  @override
  String get tavernDice => '掷骰';

  @override
  String get tavernDiceCount => '个数';

  @override
  String get tavernDiceModifier => '加值';

  @override
  String get tavernDiceFewer => '少一个骰子';

  @override
  String get tavernDiceMore => '多一个骰子';

  @override
  String get tavernDiceModifierDown => '加值减 1';

  @override
  String get tavernDiceModifierUp => '加值加 1';

  @override
  String get tavernDiceRoll => '掷';

  @override
  String get tavernDiceAgain => '再掷一次';

  @override
  String get tavernDiceUse => '放进输入框';

  @override
  String tavernDiceLine(String notation, int total, String working) {
    return '🎲 $notation 掷出 $total$working';
  }

  @override
  String tavernDiceWorking(String working) {
    return '（$working）';
  }

  @override
  String get tavernStorybook => '故事书';

  @override
  String get tavernStorybookMenu => '导出成故事书';

  @override
  String get tavernStorybookTitle => '书名';

  @override
  String tavernStorybookDefaultTitle(String name) {
    return '$name的故事';
  }

  @override
  String tavernStorybookByline(String character, String you) {
    return '$character 和 $you';
  }

  @override
  String get tavernStorybookWhole => '整本';

  @override
  String tavernStorybookWholeNote(int count) {
    return '一共 $count 句，隐藏的消息不放进去';
  }

  @override
  String get tavernStorybookEpub => '电子书（EPUB）';

  @override
  String get tavernStorybookText => '纯文本（TXT）';

  @override
  String get tavernStorybookImage => '长图';

  @override
  String get tavernStorybookLatest => '放最近';

  @override
  String tavernStorybookLines(int count) {
    return '$count 句';
  }

  @override
  String get tavernStorybookSave => '存到相册';

  @override
  String get tavernStorybookShare => '分享长图';

  @override
  String tavernStorybookEarlier(int count) {
    return '前面还有 $count 句没放进图里，整段请导出电子书。';
  }

  @override
  String tavernStorybookEarlierShort(int count) {
    return '…… 前面还有 $count 句 ……';
  }

  @override
  String get tavernStorybookMadeWith => '用 DSH Go 酒馆写成';

  @override
  String get tavernStorybookContents => '目录';

  @override
  String tavernStorybookChapter(int n) {
    return '第 $n 章';
  }

  @override
  String get tavernStorybookSaved => '已存到相册';

  @override
  String get tavernStorybookFailed => '没能导出，再试一次';

  @override
  String get tavernLive2d => 'Live2D 形象';

  @override
  String get tavernLive2dSubtitle => '视觉小说排版里代替卡面';

  @override
  String get tavernLive2dNone => '未导入';

  @override
  String get tavernLive2dSet => '已导入';

  @override
  String get tavernLive2dImported => '导入好了，切到视觉小说排版就能看到她。';

  @override
  String get tavernLive2dReplace => '换一个';

  @override
  String get tavernLive2dRemove => '去掉 Live2D 形象';

  @override
  String get tavernLive2dNoRuntime => '手机上还没有 Live2D 运行库：先在伙伴小屋装一个形象，或者导入完整的素材包。';

  @override
  String get tavernTextSize => '正文字号';

  @override
  String get tavernTextSmall => '小';

  @override
  String get tavernTextMedium => '中';

  @override
  String get tavernTextLarge => '大';

  @override
  String get tavernTextHuge => '特大';

  @override
  String get tavernLineHeight => '行距';

  @override
  String get tavernLineTight => '紧凑';

  @override
  String get tavernLineNormal => '适中';

  @override
  String get tavernLineLoose => '宽松';

  @override
  String get tavernReadingSample => '*她把陶杯推到你面前，炉火在她眼里跳了一下。*\n\n「这么晚了还在赶路？外头的雪今晚停不了，你要是赶路，最好等天亮。」';

  @override
  String get tavernPalette => '配色';

  @override
  String get tavernPalettePlain => '素';

  @override
  String get tavernPaletteEmber => '暖';

  @override
  String get tavernPaletteOcean => '冷';

  @override
  String get tavernPaletteRose => '粉';

  @override
  String get tavernTextSpeed => '逐字速度';

  @override
  String get tavernTextSlow => '慢';

  @override
  String get tavernTextNormal => '中';

  @override
  String get tavernTextFast => '快';

  @override
  String get tavernTextInstant => '立即';

  @override
  String get tavernVnAuto => '自动';

  @override
  String get tavernVnSkip => '跳过';

  @override
  String get tavernStage => '舞台';

  @override
  String get tavernStageSession => '本局';

  @override
  String get tavernSessionUsing => '正在用';

  @override
  String get tavernSessionLook => '外观';

  @override
  String get tavernSessionMore => '更多';

  @override
  String get tavernAudio => '音乐和音效';

  @override
  String get tavernAudioBgm => '背景音乐';

  @override
  String get tavernAudioAmbient => '音效';

  @override
  String get tavernAudioNothing => '没在放';

  @override
  String get tavernAudioPlay => '播放';

  @override
  String get tavernAudioPause => '暂停';

  @override
  String get tavernAudioMode => '播放方式';

  @override
  String get tavernAudioModeOne => '单曲';

  @override
  String get tavernAudioModeAll => '列表';

  @override
  String get tavernAudioModeShuffle => '随机';

  @override
  String get tavernAudioModeOnce => '放一首';

  @override
  String get tavernAudioVolume => '音量';

  @override
  String get tavernAudioAllow => '让角色卡播放';

  @override
  String get tavernAudioAdd => '加一首背景音乐';

  @override
  String get tavernAudioAddTitle => '背景音乐的链接';

  @override
  String get tavernAudioAddNote => '填音频文件的网址（mp3、ogg 等），加进这段对话的背景音乐列表，和卡放的放在一起。';

  @override
  String get tavernAudioAddConfirm => '加入';

  @override
  String get tavernAudioAddInvalid => '要以 http:// 或 https:// 开头';

  @override
  String get tavernStageState => '状态';

  @override
  String get tavernStageDirector => '导演';

  @override
  String get tavernStageTurn => '本回合';

  @override
  String get tavernStageStateEmpty => '这张卡还没有状态';

  @override
  String get tavernStageStateNote => '卡里定义了状态，好感、属性、背包等就会显示在这里。';

  @override
  String get tavernStageDirectorEmpty => '导演还没上场';

  @override
  String get tavernStageDirectorNote => '导演会读剧情，给下一回合留提示，并在输入框上方给出三条建议。';

  @override
  String get tavernStageTurnNone => '还没有可看的回合';

  @override
  String get tavernStageTokensIn => '提示词';

  @override
  String get tavernStageCache => '缓存命中';

  @override
  String get tavernStageTokensOut => '回复';

  @override
  String get tavernStageWorld => '这回合用上的世界书';

  @override
  String get tavernStageWorldNone => '这回合没有条目被触发';

  @override
  String get tavernStageInspect => '看完整的检视';

  @override
  String get tavernLorebookNone => '无';

  @override
  String get tavernLorebooksBound => '绑定的世界书';

  @override
  String get tavernLorebooksBoundCharacter => '这个角色的每段对话都会用';

  @override
  String get tavernLorebooksBoundPersona => '用这个人设的对话都会用';

  @override
  String get tavernLorebookForChat => '这段对话的世界书';

  @override
  String tavernLorebookForCharacter(String name) {
    return '「$name」的世界书';
  }

  @override
  String tavernLorebookForPersona(String name) {
    return '用「$name」时的世界书';
  }

  @override
  String get tavernLorebookChatNote => '只对这段对话。「全局」的对所有对话都生效。';

  @override
  String get tavernLorebookCharacterNote => '这个角色的每段对话都会用，卡自带的世界书照常一起用。';

  @override
  String get tavernLorebookPersonaNote => '你用这个人设时，每段对话都会用。';

  @override
  String get tavernLorebookPickEmpty => '资源库里还没有世界书';

  @override
  String get tavernLorebookOpenLibrary => '去资源库导入';

  @override
  String get tavernLorebookMissing => '已删除的世界书';

  @override
  String get tavernLorebookMissingSubtitle => '还绑着，生成时会跳过；关掉就解除';

  @override
  String get tavernPresetOrder => '调整顺序';

  @override
  String get tavernPresetOrderNote => '按住右边的把手拖动。提示词按这个顺序发给模型，关着的也留在原位。';

  @override
  String get tavernPresetPromptOff => '已关';

  @override
  String get tavernPrefill => '预填充';

  @override
  String get tavernPrefillOn => '回复从这段开头';

  @override
  String get tavernPrefillOnSubtitle => '模型接着这段往下写';

  @override
  String get tavernPrefillText => '开头的文字';

  @override
  String get tavernPrefillTextEmpty => '还没写';

  @override
  String get tavernPrefillTarget => '放在';

  @override
  String get tavernPrefillContent => '正文';

  @override
  String get tavernPrefillReasoning => '思考';

  @override
  String get tavernPrefillNote => '放在「思考」只在开了思考时生效，没开就放进正文。「接着写」的回合不用它。';

  @override
  String get tavernPresetPromptEmpty => '空着';

  @override
  String tavernThinkingSeconds(int seconds) {
    return '$seconds 秒';
  }

  @override
  String tavernDeletedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '删掉了 $count 条', one: '删掉了 1 条');
    return '$_temp0';
  }

  @override
  String get tavernDeleteFromUndoable => '从这条到最新一条，连同它们的备选回复和分支。删完几秒内可以撤销。';

  @override
  String get tavernUndoFailed => '没能撤销';

  @override
  String get tavernShowUsage => '每条回复下显示用量和费用';

  @override
  String get tavernShowUsageSubtitle => '模型报告的输入、输出 token 数；DeepSeek 的模型另按官方价估个费用，分高峰和低谷时段';

  @override
  String tavernUsageLine(int input, int output) {
    final intl.NumberFormat inputNumberFormat = intl.NumberFormat.decimalPattern(localeName);
    final String inputString = inputNumberFormat.format(input);
    final intl.NumberFormat outputNumberFormat = intl.NumberFormat.decimalPattern(localeName);
    final String outputString = outputNumberFormat.format(output);

    return '输入 $inputString · 输出 $outputString';
  }

  @override
  String tavernUsageLineCached(int input, int cached, int output) {
    final intl.NumberFormat inputNumberFormat = intl.NumberFormat.decimalPattern(localeName);
    final String inputString = inputNumberFormat.format(input);
    final intl.NumberFormat cachedNumberFormat = intl.NumberFormat.decimalPattern(localeName);
    final String cachedString = cachedNumberFormat.format(cached);
    final intl.NumberFormat outputNumberFormat = intl.NumberFormat.decimalPattern(localeName);
    final String outputString = outputNumberFormat.format(output);

    return '输入 $inputString（命中缓存 $cachedString）· 输出 $outputString';
  }

  @override
  String tavernUsageCost(String usd) {
    return '约 $usd';
  }

  @override
  String tavernUsageCostUnder(String usd) {
    return '不到 $usd';
  }

  @override
  String get tavernCostAlert => '单回合费用提醒';

  @override
  String get tavernCostAlertSubtitle => '一个回合按 DeepSeek 官方价估的费用超过这条线时，在输入框上方说一声；别的模型不估';

  @override
  String get tavernCostAlertOff => '关';

  @override
  String tavernCostAlertNotice(String cost, String line) {
    return '这一回合$cost，超过了提醒线 $line';
  }

  @override
  String get tavernSearchChat => '在对话里搜索';

  @override
  String get tavernSearchChatHint => '一句话、一个词';

  @override
  String get tavernSearchChatIdle => '搜的是这段对话的所有分支，包括隐藏的消息；不搜思考过程。点一条看全文。';

  @override
  String tavernSearchChatNone(String query) {
    return '没有找到「$query」';
  }

  @override
  String tavernSearchChatFound(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '找到 $count 条，新的在前', one: '找到 1 条');
    return '$_temp0';
  }

  @override
  String get tavernDeleteOne => '只删这一条';

  @override
  String get tavernDeleteOneTitle => '只删除这一条消息？';

  @override
  String get tavernDeleteOneMessage => '后面的消息都留着，接到它前面那条上。这样删除不能撤销。';

  @override
  String get tavernLorebookAdd => '加一条';

  @override
  String get tavernLorebookStart => '这张卡还没有自己的世界书。加一条，对话里提到它的关键词时，内容就会带进提示词。';

  @override
  String get tavernLorebookEntryNew => '新条目';

  @override
  String get tavernLorebookEntryEdit => '编辑条目';

  @override
  String get tavernLorebookFieldName => '条目名';

  @override
  String get tavernLorebookFieldNameHelp => '只给你看，方便找；不发给模型。';

  @override
  String get tavernLorebookFieldKeys => '关键词';

  @override
  String get tavernLorebookFieldKeysHelp => '对话里出现其中任何一个，就把内容带进提示词。用逗号隔开。';

  @override
  String get tavernLorebookFieldSecondary => '次关键词';

  @override
  String get tavernLorebookFieldSecondaryHelp => '填了的话，再按下面「次关键词怎么算」筛一遍才带进去。';

  @override
  String get tavernLorebookFieldContent => '内容';

  @override
  String get tavernLorebookFieldConstantSubtitle => '不管有没有提到关键词，每次都带上';

  @override
  String get tavernLorebookFieldEnabled => '启用';

  @override
  String get tavernLorebookFieldPosition => '放在';

  @override
  String get tavernLorebookBeforeChar => '角色设定前';

  @override
  String get tavernLorebookAfterChar => '角色设定后';

  @override
  String get tavernLorebookFieldOrder => '顺序';

  @override
  String get tavernLorebookFieldOrderHelp => '数字大的排在前面，也先带进去。';

  @override
  String get tavernLorebookEntryDelete => '删除这一条';

  @override
  String tavernLorebookEntryDeleteTitle(String name) {
    return '删除条目「$name」？';
  }

  @override
  String get tavernLorebookEntryDeleteMessage => '这一条会从卡里删掉，删除后就找不回来了。';

  @override
  String get tavernNarrator => '旁白';

  @override
  String get tavernSendOptions => '换种方式发';

  @override
  String get tavernSendOnly => '只发，不回复';

  @override
  String get tavernNarrate => '以旁白身份发';

  @override
  String get tavernSendFailed => '没能发出去';

  @override
  String get tavernStateVariables => '变量';

  @override
  String get tavernStateVariablesNote => '宏（如 {{setvar}}）记下的变量，到当前这条为止。点一项可查看或修改。';

  @override
  String get tavernData => '数据';

  @override
  String get tavernBackup => '备份整个酒馆';

  @override
  String get tavernBackupSubtitle => '角色卡、对话、预设、世界书、人设和设置，打成一个 zip';

  @override
  String get tavernBackingUp => '正在备份…';

  @override
  String tavernBackedUp(int count, String size) {
    return '备份好了：$count 个文件，$size';
  }

  @override
  String tavernBackupFailed(String error) {
    return '没能备份：$error';
  }

  @override
  String get tavernRestore => '从备份恢复';

  @override
  String get tavernRestoreSubtitle => '用一份备份替换现在的酒馆';

  @override
  String get tavernRestoreTitle => '用这份备份替换现在的酒馆？';

  @override
  String get tavernRestoreMessage => '现在的角色、对话、预设和设置都会换成备份里的。想留着现在的，先备份一份。备份不对或者坏了的话，现在的数据不会动。';

  @override
  String get tavernRestoreAction => '恢复';

  @override
  String get tavernRestoring => '正在恢复…';

  @override
  String tavernRestored(int count) {
    return '恢复好了：$count 个文件';
  }

  @override
  String tavernRestoreFailed(String error) {
    return '没能恢复，现在的数据没动：$error';
  }

  @override
  String get tavernLoreTest => '测一下';

  @override
  String get tavernLoreTestTitle => '测一下世界书';

  @override
  String get tavernLoreTestInput => '说一句话';

  @override
  String get tavernLoreTestHint => '比如你希望它带出某一条时会说的话';

  @override
  String get tavernLoreTestNote => '只看这一句，加上常驻的条目；对话里前面说过的、粘性和冷却都不算。不会调用模型。';

  @override
  String tavernLoreTestHits(int count) {
    return '会带进提示词的（$count）';
  }

  @override
  String get tavernLoreTestNone => '这句话不会带出任何条目。';

  @override
  String get tavernLoreTestOverflow => '超出了世界书的预算，排在后面的条目没放进去。';

  @override
  String tavernLoreTestFailed(String error) {
    return '没能测：$error';
  }

  @override
  String tavernLoreReasonKeys(String keys) {
    return '关键词$keys';
  }

  @override
  String get tavernLoreReasonSticky => '粘性，还在生效';

  @override
  String get tavernLoreReasonDecorator => '装饰器';

  @override
  String tavernLoreAtDepth(int depth) {
    return '倒数第 $depth 条消息处';
  }

  @override
  String get tavernLoreNearNote => '作者注释旁';

  @override
  String get tavernLoreNearExamples => '示例对话旁';

  @override
  String get tavernLoreOutlet => '出口';

  @override
  String tavernLoreOrder(String order) {
    return '顺序 $order';
  }

  @override
  String get tavernBranches => '分支';

  @override
  String get tavernBranchesNote => '每行是一段没有分叉的对话。缩进的那行，是从上面那行的末尾岔出去的另一条路。点一行可以切过去、给它起名；没在走的那条也能删掉。';

  @override
  String get tavernBranchesEmpty => '这段对话还没有消息。';

  @override
  String tavernBranchCount(int count) {
    return '$count 条';
  }

  @override
  String tavernBranchUntil(String text) {
    return '到「$text」';
  }

  @override
  String get tavernBranchCurrent => '正在看';

  @override
  String get tavernBranchSwitch => '切到这条分支';

  @override
  String get tavernBranchSwitchSubtitle => '后面接着它上次走到的地方';

  @override
  String get tavernBranchName => '给这条分支起名';

  @override
  String get tavernBranchRename => '改名';

  @override
  String get tavernBranchNameHint => '比如：地下室那条线';

  @override
  String get tavernBranchNameCaption => '只给你看，方便找；留空就去掉名字。';

  @override
  String get tavernBranchSwitched => '切到了这条分支';

  @override
  String tavernBranchFailed(String error) {
    return '没能完成：$error';
  }

  @override
  String get tavernCardTheme => '用卡自带的样式';

  @override
  String get tavernCardThemeSubtitle => '卡里写的强调色、名字颜色、默认排版和背景；关掉就都按这里的设置';

  @override
  String get tavernShelfSort => '排序';

  @override
  String get tavernShelfOrderRecent => '最近聊过';

  @override
  String get tavernShelfOrderName => '名字';

  @override
  String get tavernShelfOrderImported => '最近导入';

  @override
  String get tavernFavorite => '收藏';

  @override
  String get tavernUnfavorite => '取消收藏';

  @override
  String get tavernFavorited => '已收藏';

  @override
  String get tavernChatSearchHint => '搜对话：角色、标题、最后一句';

  @override
  String get tavernNoChatMatch => '没有符合的对话';

  @override
  String get tavernCharacterTabChats => '对话';

  @override
  String get tavernCharacterTabCard => '设定';

  @override
  String get tavernCharacterTabSetup => '配置';

  @override
  String get tavernCharacterNoDefinition => '这张卡没有写设定和说明。';

  @override
  String get tavernNovelIndent => '小说排版段首空两格';

  @override
  String get tavernNovelIndentSubtitle => '像书里那样，每段开头空两个字';

  @override
  String get tavernShelfSelect => '选择';

  @override
  String tavernShelfPicked(int count) {
    return '已选 $count 个';
  }

  @override
  String get tavernShelfExport => '导出选中的角色卡';

  @override
  String tavernDeleteCharactersTitle(int count) {
    return '删除这 $count 个角色？';
  }

  @override
  String get tavernQuickRepliesAll => '全部';

  @override
  String get tavernQuickRepliesManage => '管理快速回复';

  @override
  String tavernSpeakNext(String name) {
    return '让$name接着说';
  }

  @override
  String get tavernSettingsConnection => '模型与连接';

  @override
  String get tavernDefaultPreset => '默认预设';

  @override
  String get tavernDefaultPresetPick => '新对话用的预设';

  @override
  String tavernGenerationInPreset(String name) {
    return '改「$name」的参数';
  }

  @override
  String tavernGenerationPresetNote(String name) {
    return '新对话用「$name」：上下文、回复长度和温度在这份预设里改。自带预设的对话以它自己的为准。';
  }

  @override
  String get tavernStorage => '存储占用';

  @override
  String get tavernStorageCounting => '正在计算…';

  @override
  String get tavernStorageCharacters => '角色卡';

  @override
  String get tavernStorageChats => '对话、预设和人设';

  @override
  String get tavernStorageLive2d => 'Live2D 形象';

  @override
  String get tavernStorageOther => '背景图、世界书、正则和设置';

  @override
  String get tavernStorageNote => '这些都只存在这台设备上；换手机或卸载前，先「备份整个酒馆」。';

  @override
  String get tavernDefaultPresetEmpty => '在 资源库 › 预设 里导入以后，就能换成别的。';

  @override
  String tavernQuickRepliesAdded(int count) {
    return '加了 $count 条快速回复';
  }

  @override
  String tavernQuickRepliesAddedSkipped(int count, int skipped) {
    return '加了 $count 条快速回复；$skipped 条是 ST 的斜杠命令，没有加';
  }

  @override
  String get tavernImportChatNoName => '这份聊天记录没写是哪个角色的，到角色页里导入它';

  @override
  String tavernImportChatNoCharacter(String name) {
    return '书架上找不到唯一的「$name」，到角色页里导入这段聊天';
  }

  @override
  String tavernImportedChatsTo(int count, String name) {
    return '$count 段对话导入到了「$name」';
  }

  @override
  String tavernImportUnknown(String name) {
    return '认不出 $name 是什么文件';
  }

  @override
  String tavernImportFileFailed(String name, String reason) {
    return '$name 没能导入：$reason';
  }

  @override
  String get tavernIslands => '消息里的网页';

  @override
  String get tavernIslandsSubtitle => '卡在消息里写的 HTML 和样式（状态栏、面板），单独放进一个网页里显示；关掉就按文字显示';

  @override
  String get tavernSettingsSafety => '安全';

  @override
  String get tavernIslandNoScripts => '网页里不运行卡的脚本';

  @override
  String get tavernSPresetExternal => '让预设自己加载 SPreset';

  @override
  String get tavernSPresetExternalSubtitle => '默认用内置的 SPreset，不从预设作者的网站加载脚本；打开后改用预设自己加载的';

  @override
  String get tavernIslandNoScriptsSubtitle => '卡自带的 JavaScript 不运行；要靠脚本动起来的状态栏会停住';

  @override
  String get tavernIslandOffline => '网页不联网';

  @override
  String get tavernIslandOfflineSubtitle => '只用卡里自带的图片和字体，不从网上加载任何东西';

  @override
  String get tavernSessionUsage => '本局用量';

  @override
  String tavernSessionUsageNote(int count) {
    return '当前分支 $count 条回复的合计，换掉的备选不算';
  }

  @override
  String get tavernSessionUsageNone => '还没有模型报告过用量';

  @override
  String tavernSessionUsageCost(String usd) {
    return '约 $usd，按 DeepSeek 官方价，分高峰和低谷时段算；法定节假日全天是低谷价，那几天这里会算高一点';
  }

  @override
  String tavernStageCost(String usd) {
    return '约 $usd，按 DeepSeek 官方价估算';
  }

  @override
  String tavernSessionUsageUnpriced(int count) {
    return '$count 条回复用的模型不在价目表里，没算进费用';
  }

  @override
  String get tavernComposerNoKey => '填好 Key 就能开始';

  @override
  String get tavernWriteOwn => '自己写一个角色';

  @override
  String get tavernWriteOwnSubtitle => '从一张空白卡开始';

  @override
  String get tavernNewCharacterName => '新角色';

  @override
  String get tavernSearchGoTo => '到对话里这一条';

  @override
  String get tavernBookmarks => '书签';

  @override
  String get tavernBookmarkAdd => '加书签';

  @override
  String get tavernBookmarkRemove => '去掉书签';

  @override
  String get tavernBookmarkAdded => '加了书签，在 舞台 › 本局 › 书签 里找';

  @override
  String get tavernBookmarkRemoved => '书签去掉了';

  @override
  String get tavernBookmarksEmpty => '还没有书签';

  @override
  String get tavernBookmarksEmptyMessage => '长按一条消息，选「加书签」';

  @override
  String get tavernBookmarkGone => '那一条已经不在了，书签去掉了';

  @override
  String get tavernUsageStats => '用量统计';

  @override
  String get tavernUsageStatsSubtitle => '每段对话用了多少 token、约多少钱';

  @override
  String get tavernUsageAllNote => '所有对话当前线上的回复合计；换掉的备选不算';

  @override
  String tavernUsageChatReplies(int count, String completion) {
    return '$count 条回复 · 回复 $completion';
  }

  @override
  String get tavernSlashNoReply => '还没有可以这样做的回复';

  @override
  String get tavernRegexTest => '试一下';

  @override
  String get tavernRegexTestFind => '查找';

  @override
  String get tavernRegexTestReplace => '替换为';

  @override
  String get tavernRegexTestInput => '一段文字';

  @override
  String get tavernRegexTestHint => '粘一段回复进来试试';

  @override
  String get tavernRegexTestNote => '只用这一条规则在本机试，不发给模型；不管它平时作用在哪、开没开，这里都照样跑。';

  @override
  String get tavernRegexTestMacros => '{{char}} 这类宏这里不展开，照字面算。';

  @override
  String get tavernRegexTestNone => '没有匹配，原样不变';

  @override
  String tavernRegexTestResult(int count) {
    return '替换后（$count 处）';
  }

  @override
  String tavernRegexTestFailed(String reason) {
    return '没能试：$reason';
  }

  @override
  String get tavernStateNote => '到当前这条消息为止。点一项可查看或修改，改动随这条消息回退。';

  @override
  String get tavernStatePreview => '还没有记录，下面是初始值。';

  @override
  String get tavernStateChanged => '变了';

  @override
  String get tavernStateHidden => '剧透 · 点开看';

  @override
  String get tavernStateWhole => '整体';

  @override
  String get tavernStateEdit => '改';

  @override
  String get tavernStateEditText => '这段文字原样保存';

  @override
  String get tavernStateEditJson => '写 JSON：数字、true / false、\"带引号的文字\"、[…]、{…}';

  @override
  String get tavernStateEditBad => '这不是有效的 JSON，没有改';

  @override
  String get tavernStateEditSaved => '改好了';

  @override
  String get tavernStateEditSame => '值没变';

  @override
  String tavernStateEditRefused(String reason) {
    return '没改成：$reason';
  }

  @override
  String get tavernDirectorAuto => '自动导演';

  @override
  String get tavernDirectorAutoNote => '只对这段对话。每隔几个回合多请求一次模型，会多用一些额度。';

  @override
  String get tavernDirectorRun => '让导演想一想';

  @override
  String get tavernDirectorRunning => '导演在想…';

  @override
  String get tavernDirectorBeat => '下一拍';

  @override
  String get tavernDirectorSuggestions => '你可以…';

  @override
  String get tavernDirectorSuggestionsNote => '点一条放进输入框';

  @override
  String get tavernDirectorNotes => '导演笔记';

  @override
  String get tavernDirectorStale => '基于之前的剧情，仅供参考。';

  @override
  String tavernDirectorFailed(String reason) {
    return '上次没想成：$reason';
  }

  @override
  String tavernDirectorRunFailed(String reason) {
    return '没能做到：$reason';
  }

  @override
  String get tavernBranchHere => '从这里分叉';

  @override
  String get tavernBranchedHere => '回到了这一条，后面的内容留在「分支」里';

  @override
  String get tavernBranchHereFailed => '没能回到这一条';

  @override
  String tavernStateItems(int count) {
    return '$count 项';
  }

  @override
  String get tavernStateSearch => '搜变量';

  @override
  String get tavernStateNoMatch => '没有符合的';

  @override
  String get tavernRuns => '后台记录';

  @override
  String get tavernRunsNote => '你、模型和卡的规则改了状态，导演、卡事件和剧情每次跑过，都记在这里；最新的在上，最多 100 条。点一条看原始记录。';

  @override
  String get tavernRunsEmpty => '还没有记录';

  @override
  String get tavernRunsEmptyMessage => '改了状态，或者导演跑过以后，会记在这里。';

  @override
  String get tavernRunUser => '你改的';

  @override
  String get tavernRunModel => '模型改的';

  @override
  String get tavernRunRules => '卡的规则';

  @override
  String get tavernRunStopped => '回合中断';

  @override
  String get tavernRunDirector => '导演';

  @override
  String get tavernRunDirectorFailed => '导演没成';

  @override
  String get tavernRunEvent => '卡事件';

  @override
  String get tavernRunStory => '剧情';

  @override
  String get tavernRunSecret => '秘密';

  @override
  String get tavernRunNotKept => '没收下';

  @override
  String get tavernRunGone => '那条消息已删';

  @override
  String tavernRunMore(int count) {
    return '等 $count 处';
  }

  @override
  String get tavernInspectCache => '缓存';

  @override
  String get tavernInspectCacheKept => '和上一回合同前缀';

  @override
  String tavernInspectCacheBroken(int index) {
    return '从第 $index 段起变了';
  }

  @override
  String tavernInspectCacheMiss(int tokens) {
    return '这一段和它后面约 $tokens tokens 不会命中缓存，前面的和上一回合一样。常是靠前的世界书条目这回合换了。';
  }

  @override
  String get tavernInspectCacheBreak => '缓存从这里断开';

  @override
  String get tavernPaletteSt => 'ST';

  @override
  String tavernStTheme(String name) {
    return 'ST 主题：$name';
  }

  @override
  String get tavernStThemeNote => '配色选「ST」时，引号里的话和 *动作* 用它的颜色；太浅或太深看不清的，会调到看得清。';

  @override
  String get tavernStThemeImport => '导入 ST 主题';

  @override
  String get tavernStThemeImportNote => '从 SillyTavern 导出的主题文件里取引号和斜体的颜色，和它的自定义 CSS。';

  @override
  String get tavernStThemeCss => '用它的自定义 CSS';

  @override
  String get tavernStThemeCssSubtitle => '配色选「ST」时加进整页画布，和在 ST 里一样盖过默认样式。版面乱了就关掉，颜色照用。';

  @override
  String get tavernStThemeRemove => '移除';

  @override
  String tavernStThemeImported(String name) {
    return '换成了 ST 主题「$name」的配色';
  }

  @override
  String tavernStThemeNoColors(String name) {
    return '「$name」里没有能用的引号、斜体颜色或自定义 CSS';
  }

  @override
  String get tavernPromptContent => '内容';

  @override
  String get tavernPromptRole => '谁说';

  @override
  String get tavernPromptRoleSystem => '系统';

  @override
  String get tavernPromptRoleUser => '用户';

  @override
  String get tavernPromptRoleAssistant => '助手';

  @override
  String get tavernPromptPosition => '位置';

  @override
  String get tavernPromptRelative => '按顺序';

  @override
  String get tavernPromptInChat => '对话中';

  @override
  String get tavernPromptDepth => '深度';

  @override
  String tavernPromptDepthNote(int depth) {
    return '插进聊天记录，从最后往前数第 $depth 条之前（0 是最末尾），和 ST 的「对话中」一样。';
  }

  @override
  String get tavernPromptRelativeNote => '照预设的顺序放，和 ST 的「相对」一样。';

  @override
  String tavernPromptPlace(int depth) {
    return '对话中 · 深度 $depth';
  }

  @override
  String get tavernPromptOrder => '同深度的先后';

  @override
  String get tavernPromptOrderNote => '同一深度有几条时，数字小的在前（默认 100）。';

  @override
  String get tavernPromptForbid => '不让角色卡覆盖';

  @override
  String get tavernPromptForbidMain => '角色卡自带的系统提示词不会替换这一条。';

  @override
  String get tavernPromptForbidJailbreak => '角色卡自带的历史后指令不会替换这一条。';

  @override
  String get tavernLoreCommon => '常用';

  @override
  String get tavernLoreMore => '更多';

  @override
  String get tavernLorePosAnTop => '作者注前';

  @override
  String get tavernLorePosAnBottom => '作者注后';

  @override
  String get tavernLorePosExampleTop => '示例前';

  @override
  String get tavernLorePosExampleBottom => '示例后';

  @override
  String get tavernLorePosOutlet => '出口';

  @override
  String get tavernLoreLogic => '次关键词怎么算';

  @override
  String get tavernLoreLogicAndAny => '含任一';

  @override
  String get tavernLoreLogicAndAll => '全都含';

  @override
  String get tavernLoreLogicNotAny => '都不含';

  @override
  String get tavernLoreLogicNotAll => '不全含';

  @override
  String get tavernLoreProbability => '触发概率';

  @override
  String get tavernLoreCase => '区分大小写';

  @override
  String get tavernLoreWhole => '整词匹配';

  @override
  String get tavernLoreDefault => '默认';

  @override
  String get tavernLoreYes => '是';

  @override
  String get tavernLoreNo => '否';

  @override
  String get tavernLorePosDepth => '按深度';

  @override
  String get tavernLibraryBookOpen => '看条目、改条目';

  @override
  String get tavernLibraryBookNote => '改动写回这本书；绑定了它的地方，下一回合就用新内容。';

  @override
  String get tavernBranchDelete => '删掉这条分支';

  @override
  String get tavernBranchDeleteTitle => '删掉这条分支？';

  @override
  String tavernBranchDeleteMessage(int count) {
    return '这条分支上的 $count 条消息，连同从它分出去的，都会删掉；删了之后几秒内可以撤销。正在走的这条不受影响。';
  }

  @override
  String tavernLetterFrom(String from) {
    return '$from的信';
  }

  @override
  String get tavernLetter => '一封信';

  @override
  String get tavernComponentMore => '展开';

  @override
  String get tavernComponentLess => '收起';

  @override
  String get tavernItemTaken => '获得';

  @override
  String get tavernClue => '线索';

  @override
  String tavernPhoneFrom(String from) {
    return '$from 发来消息';
  }

  @override
  String get tavernPhoneMessage => '一条消息';

  @override
  String tavernRollCheck(String skill) {
    return '检定：$skill';
  }

  @override
  String get tavernRoll => '掷骰';

  @override
  String get tavernRollSuccess => '成功';

  @override
  String get tavernRollFailure => '失败';

  @override
  String get tavernGameHere => '这里有一个小游戏，现在还不能在这里玩';

  @override
  String tavernCanvasReplied(String name) {
    return '$name回复了';
  }

  @override
  String get tavernMvuIssues => '这张卡的变量更新有问题';

  @override
  String get tavernMvuUnfinished => '这一层的变量没有更新完，正文已经保留';

  @override
  String get tavernRegexEdit => '编辑规则';

  @override
  String get tavernRegexFieldName => '名字';

  @override
  String get tavernRegexFieldFindHelp => '写法 /规则/标志，如 /(早安|晚安)/gi';

  @override
  String get tavernRegexFieldReplaceHelp => '\$1 是第一组，{{match}} 是整段匹配';

  @override
  String get tavernRegexFieldTrim => '先去掉的字';

  @override
  String get tavernRegexFieldTrimHelp => '每行一个；替换之前先从匹配到的字里删掉';

  @override
  String get tavernRegexPlacement => '用在';

  @override
  String get tavernRegexPlaceUser => '你的话';

  @override
  String get tavernRegexPlaceAi => '回复';

  @override
  String get tavernRegexPlaceSlash => '斜杠命令';

  @override
  String get tavernRegexPlaceWorld => '世界书';

  @override
  String get tavernRegexPlaceReasoning => '思考';

  @override
  String get tavernRegexPhase => '改哪一份';

  @override
  String get tavernRegexPhaseWrite => '原文';

  @override
  String get tavernRegexPhaseDisplay => '只改显示';

  @override
  String get tavernRegexPhasePrompt => '只改发出';

  @override
  String get tavernRegexPhaseBoth => '显示和发出';

  @override
  String get tavernRegexPhaseNote => '原文：改写存下的消息；只改显示：存档不变；只改发出：只改发给模型的那份';

  @override
  String get tavernRegexMinDepth => '最浅';

  @override
  String get tavernRegexMaxDepth => '最深';

  @override
  String get tavernRegexDepthHelp => '空着就是不限；0 是最新一条';

  @override
  String get tavernRegexSubstitute => '查找里的宏';

  @override
  String get tavernRegexSubstituteNone => '不展开';

  @override
  String get tavernRegexSubstituteRaw => '原样展开';

  @override
  String get tavernRegexSubstituteEscaped => '转义后展开';

  @override
  String get tavernRegexRunOnEdit => '编辑消息时也跑';

  @override
  String get tavernRegexFieldEnabled => '启用这条规则';

  @override
  String get tavernRegexSavedIncompatible => '已保存。这条规则在这里跑不了，用的时候会跳过';

  @override
  String get tavernRegexGone => '这条规则已经不在了，回列表刷新一下';

  @override
  String get tavernRegexDeferred => '用到了宏，要到运行时才知道能不能跑';

  @override
  String get tavernRegexTryDraft => '用现在填的试一下';

  @override
  String get tavernRegexDepthAny => '不限';

  @override
  String get tavernCanvas => '整页画布（试用）';

  @override
  String tavernCardScriptsHint(int count) {
    return '$count 个卡片脚本要在整页画布里运行';
  }

  @override
  String get tavernCardScriptsHintAction => '打开';

  @override
  String get tavernRender => '显示方式';

  @override
  String get tavernRenderSubtitle => '只管这个角色的单人对话。状态栏、美化要选网页或画布，脚本只在画布里运行';

  @override
  String get tavernRenderText => '文字';

  @override
  String get tavernRenderIslands => '消息网页';

  @override
  String get tavernRenderCanvas => '整页画布';

  @override
  String get tavernCanvasSubtitle =>
      '整段对话放进一张网页，按 SillyTavern 的结构排，卡写给 ST 的样式能跨消息生效。卡里的脚本会运行，不想让它跑就打开「网页里不运行卡的脚本」。视觉小说不用它。';

  @override
  String get tavernCanvasReloaded => '画面重新加载了';

  @override
  String get tavernLowPower => '省电渲染';

  @override
  String get tavernLowPowerSubtitle => '去掉卡片网页里的模糊和循环动画，手机更流畅';

  @override
  String tavernGroupSpeaking(String name) {
    return '$name 在说';
  }

  @override
  String tavernGroupThen(String names) {
    return '接着是 $names';
  }

  @override
  String get tavernGroupNoSpeakers => '这一轮没人接话。点上面的名字，让谁来说。';

  @override
  String get tavernGroupSpeakNext => '让大家接着说';

  @override
  String get tavernGroupNew => '新建群聊';

  @override
  String get tavernGroupMembers => '谁在里面';

  @override
  String get tavernGroupMembersNote => '按点选的顺序排，第一个是主持';

  @override
  String get tavernGroupHost => '主持';

  @override
  String get tavernGroupTitle => '群名';

  @override
  String get tavernGroupActivation => '怎么轮流说';

  @override
  String get tavernGroupNatural => '自然';

  @override
  String get tavernGroupListOrder => '按顺序';

  @override
  String get tavernGroupRandom => '随机';

  @override
  String get tavernGroupManual => '手动';

  @override
  String get tavernGroupDirector => '导演';

  @override
  String get tavernGroupNaturalNote => '像 SillyTavern：被点到名的先说，其余看各自的话多话少';

  @override
  String get tavernGroupListOrderNote => '每轮按名单从头轮一遍（静音的跳过）。';

  @override
  String get tavernGroupRandomNote => '每轮随机挑一个这轮还没说过的人。';

  @override
  String get tavernGroupManualNote => '谁也不自己开口；点输入框上面的名字，让谁说谁说。';

  @override
  String get tavernGroupDirectorNote => '由导演按剧情点名下一位。';

  @override
  String get tavernGroupPickTwo => '至少选两个角色';

  @override
  String tavernGroupCreate(int count) {
    return '建群（$count 人）';
  }

  @override
  String tavernGroupCreateFailed(String reason) {
    return '没能建群：$reason';
  }

  @override
  String get tavernGroupTag => '群';

  @override
  String tavernGroupMemberCount(int count) {
    return '$count 人';
  }

  @override
  String get tavernGroupSettings => '群聊设置';

  @override
  String get tavernGroupMaxSpeakers => '每轮最多几人';

  @override
  String get tavernGroupSelfResponses => '可以接着自己说';

  @override
  String get tavernGroupSelfResponsesNote => '刚说完的人这一轮还能再说';

  @override
  String tavernGroupHostNote(String name) {
    return '主持是「$name」，故事共用的状态记在它的卡上';
  }

  @override
  String get tavernGroupMuted => '静音';

  @override
  String get tavernGroupMutedNote => '不会自己开口；点名时照样说。';

  @override
  String get tavernGroupTalkativeness => '话多话少';

  @override
  String get tavernGroupTalkativenessNote => '「自然」轮流时，越高越容易开口。';

  @override
  String get tavernGroupHelperModel => '用辅助模型';

  @override
  String get tavernGroupHelperModelNote => '用辅助模型说（自动时 DeepSeek 用 flash 且不思考，其他渠道用主模型），适合配角。';

  @override
  String get tavernGroupMoveUp => '往前挪';

  @override
  String get tavernGroupMoveDown => '往后挪';

  @override
  String get tavernGroupRemove => '移出群聊';

  @override
  String get tavernGroupAdd => '加一个角色';

  @override
  String get tavernGroupNoOthers => '书架上的角色都在群里了';

  @override
  String get tavernGroupUnavailable => '角色卡不在了';

  @override
  String tavernGroupSaveFailed(String reason) {
    return '没能保存：$reason';
  }

  @override
  String get tavernGroupErrorNotGroup => '这已经不是群聊了';

  @override
  String get tavernGroupErrorCharacterNotFound => '这个角色的卡不在了';

  @override
  String get tavernGroupErrorMemberExists => '这个角色已经在群里了';

  @override
  String get tavernGroupErrorMemberNotFound => '这个角色已经不在群里了';

  @override
  String get tavernGroupErrorInvalidMembers => '成员不能重复，群里至少要有一个角色';

  @override
  String get tavernGroupErrorInvalidTalkativeness => '话多程度要在 0 到 1 之间';

  @override
  String get tavernGroupErrorInvalidLimit => '每轮至少要有一个人说话';

  @override
  String get tavernGroupErrorInvalidOrder => '排的顺序和群里的成员对不上，请重新打开再排';

  @override
  String get tavernGroupErrorHostInUse => '这个角色是一个群聊的群主，先删掉那个群聊';

  @override
  String get tavernGroupErrorInvalidTitle => '群聊的名字不能只有空白';

  @override
  String tavernToolRollUnsettled(String dice) {
    return '🎲 $dice：结果还没确认';
  }

  @override
  String tavernToolRollNotDone(String dice) {
    return '🎲 $dice：没有掷';
  }

  @override
  String tavernToolRollPass(int target) {
    return '目标 $target，成功';
  }

  @override
  String tavernToolRollFail(int target) {
    return '目标 $target，没过';
  }

  @override
  String tavernToolMemory(String text) {
    return '想记住：「$text」';
  }

  @override
  String get tavernToolMemoryAccept => '记住';

  @override
  String get tavernToolMemoryReject => '不用';

  @override
  String get tavernToolMemoryStaged => '等这一回合写完再定';

  @override
  String tavernToolMemoryIneligible(String reason) {
    return '现在不能确认：$reason';
  }

  @override
  String get tavernToolMemoryAccepted => '已记住';

  @override
  String get tavernToolMemoryAuto => '已按自动设置记住';

  @override
  String get tavernToolMemoryRejected => '没有记';

  @override
  String get tavernToolMemoryInactive => '这一回合没有正常写完，没有记';

  @override
  String get tavernToolMemoryWaiting => '上次的决定还没确认上';

  @override
  String tavernToolMemoryNotApplied(String reason) {
    return '没记上：$reason';
  }

  @override
  String tavernToolMemoryFailed(String detail) {
    return '没确认上：$detail';
  }

  @override
  String get tavernToolReasonRevision => '它已经变了，刷新后再定';

  @override
  String get tavernToolReasonResolved => '已经定过了';

  @override
  String get tavernToolReasonContext => '对话已经变了';

  @override
  String get tavernToolReasonDeleted => '那条回复被删了';

  @override
  String get tavernToolReasonChanged => '那条回复改过了';

  @override
  String get tavernToolReasonBranch => '不在现在这条线上';

  @override
  String get tavernToolReasonInactive => '已经失效';

  @override
  String get tavernToolReasonUnknown => '原因不明';

  @override
  String get tavernToolPolicy => '工具';

  @override
  String get tavernToolPolicyRoll => '让角色掷骰';

  @override
  String get tavernToolPolicyRollSubtitle => '回复里要掷骰时，由酒馆来掷，点数记下来';

  @override
  String get tavernToolPolicyRemember => '让角色记事';

  @override
  String get tavernToolPolicyRememberSubtitle => '角色觉得值得记住的事，按下面的方式记进记忆';

  @override
  String get tavernToolPolicyMode => '记事方式';

  @override
  String get tavernToolPolicyModeAsk => '先问我';

  @override
  String get tavernToolPolicyModeAuto => '自动';

  @override
  String get tavernToolPolicyDiagnostics => '设置里有一部分读不懂，对应的工具先关着';

  @override
  String get tavernToolPolicyNote => '只在用 DeepSeek、不开思考时，回复里才会用上这些；改了从下一回合起生效，角色卡也可以关掉它们';

  @override
  String tavernToolPolicyFailed(String detail) {
    return '没改成：$detail';
  }

  @override
  String get tavernChatTools => '这局的工具';

  @override
  String get tavernChatToolFollow => '跟设置';

  @override
  String get tavernChatToolOn => '开';

  @override
  String get tavernChatToolOff => '关';

  @override
  String tavernChatToolNow(String roll, String remember) {
    return '这局实际：掷骰$roll，记事$remember';
  }

  @override
  String get tavernChatToolHeld => '酒馆设置里关着的，这里打开也不算';

  @override
  String tavernInspectRequests(int count) {
    return '$count 次请求';
  }

  @override
  String tavernInspectUsageTotals(String prompt, String hit, String completion) {
    return '输入 $prompt（缓存 $hit）· 输出 $completion';
  }

  @override
  String get tavernReqUsagePrompt => '输入';

  @override
  String get tavernReqUsageCache => '缓存';

  @override
  String get tavernReqUsageCompletion => '输出';

  @override
  String tavernReqUsageLine(String field, String parts) {
    return '$field：$parts';
  }

  @override
  String get tavernReqUsageJoin => '，';

  @override
  String tavernReqUsageKnown(String known) {
    return '已明确 $known';
  }

  @override
  String tavernReqUsageUnknown(int count) {
    return '$count 个请求未知';
  }

  @override
  String tavernReqUsageMissing(int count) {
    return '$count 个请求没报告';
  }

  @override
  String tavernReqUsageInvalid(int count) {
    return '$count 个请求报告的数不对';
  }

  @override
  String get tavernToolFailBudget => '这一回合用工具的次数用完了，停在这里；之前已经掷的骰子照样算数';

  @override
  String get tavernToolFailBatch => '模型一次要用的工具太多，这一批没有执行';

  @override
  String get tavernToolFailProtocol => '模型给的工具调用格式不对，没有执行';

  @override
  String get tavernToolFailSnapshot => '这个模型的回复没法接着用工具，停在这里';

  @override
  String get tavernToolFailReceipt => '工具的结果没能存好，稍后看看这一回合';

  @override
  String get tavernToolFailAnchor => '对话在这一回合中途变了，没有接着写';

  @override
  String get tavernToolFail => '用工具时出错了';

  @override
  String tavernToolFailDetail(String detail) {
    return '用工具时出错了：$detail';
  }

  @override
  String get tavernDiceUnsettled => '结果还没确认，可以再查一次';

  @override
  String get tavernDicePending => '上次那次掷骰还没确认';

  @override
  String get tavernDiceRecheck => '再查一次';

  @override
  String get tavernDiceForget => '放弃这次';

  @override
  String get tavernDiceBusy => '现在正忙，等这一回合写完再掷';

  @override
  String get tavernDiceOff => '酒馆设置里关了掷骰';

  @override
  String tavernDiceFailed(String detail) {
    return '没掷成：$detail';
  }

  @override
  String tavernDiceNotSaved(String detail) {
    return '没确认上：$detail';
  }

  @override
  String get tavernChannel => '渠道';

  @override
  String get tavernChannelDeepSeek => 'DeepSeek 官方';

  @override
  String get tavernChannelDeepSeekNote => '用 App 里填的 DeepSeek Key';

  @override
  String get tavernChannelAdd => '添加渠道';

  @override
  String get tavernChannelEdit => '编辑渠道';

  @override
  String get tavernChannelsNote =>
      '兼容 OpenAI 接口的服务都能加：中转站、OpenRouter、自己电脑上跑的模型。Key 只存在这台手机的安全存储里。费用估算只认 DeepSeek 官方的价格，其他渠道只显示 token 数。';

  @override
  String get tavernChannelName => '名称';

  @override
  String get tavernChannelNameHint => '不填就用网址';

  @override
  String get tavernChannelBaseUrlInvalid => '要以 http:// 或 https:// 开头';

  @override
  String get tavernChannelKeyOptional => '本地服务不需要 Key 可以不填';

  @override
  String get tavernChannelKeyKept => '已存了 Key，不填就保持原样';

  @override
  String get tavernChannelFetchModels => '获取列表';

  @override
  String get tavernChannelFetching => '获取中…';

  @override
  String tavernChannelFetchFailed(String detail) {
    return '没拿到模型列表（$detail），直接填模型名也行';
  }

  @override
  String get tavernChannelNoModels => '这个服务没列出模型，直接填模型名就行';

  @override
  String get tavernChannelModelHint => '服务商给的模型名';

  @override
  String get tavernChannelModelMissing => '填一个模型名';

  @override
  String get tavernChannelPickModel => '选模型';

  @override
  String get tavernChannelSearchModels => '搜索模型';

  @override
  String get tavernChannelDeepSeekApi => '按 DeepSeek 接口发送';

  @override
  String get tavernChannelDeepSeekApiNote => '用 DeepSeek 的续写方式和思考开关。只在 DeepSeek 官方或原样转发它的中转上打开。';

  @override
  String get tavernChannelDelete => '删除渠道';

  @override
  String tavernChannelDeleteTitle(String name) {
    return '删除「$name」？';
  }

  @override
  String get tavernChannelDeleteMessage => '它的 Key 也会一起删掉。正在用它的话，换回 DeepSeek 官方。';

  @override
  String get tavernChannelCopyFromApp => '从 App 的渠道复制';

  @override
  String get tavernModelName => '模型名';

  @override
  String get tavernNumberCustom => '自定义';

  @override
  String get tavernNumberType => '输入数值';

  @override
  String tavernNumberRange(String min, String max) {
    return '填 $min 到 $max 之间的数';
  }

  @override
  String tavernNumberRangeWhole(String min, String max) {
    return '填 $min 到 $max 之间的整数';
  }

  @override
  String get tavernTopP => 'Top P';

  @override
  String get tavernPresencePenalty => '存在惩罚';

  @override
  String get tavernFrequencyPenalty => '频率惩罚';

  @override
  String get tavernPresetSampling => '采样';

  @override
  String get tavernChannelHeaders => '请求头（可选）';

  @override
  String get tavernChannelHeadersNote => '每行一个，写成「名称: 值」。和 Key 一样存在这台手机的安全存储里。';

  @override
  String get tavernChannelHeadersInvalid => '每行写成「名称: 值」';

  @override
  String get tavernAuxiliary => '辅助模型';

  @override
  String get tavernAuxiliaryNote => '导演、群聊选人、秘密这些后台请求用它';

  @override
  String get tavernAuxiliaryAuto => '自动';

  @override
  String get tavernAuxiliaryAutoNote => '跟着主渠道：DeepSeek 用 Flash，其他渠道用同一个模型';

  @override
  String get tavernAuxiliaryDeepSeek => 'DeepSeek Flash';

  @override
  String get tavernChannelKeyClear => '清除';

  @override
  String get tavernChannelKeyCleared => 'Key 会在保存时清除';

  @override
  String get tavernDrafts => '草稿';

  @override
  String get tavernDraftsSubtitle => '改动先放在草稿里，挑好再应用到真的卡上';

  @override
  String get tavernDraftsForCard => '用 AI 改这张卡';

  @override
  String get tavernDraftsEmpty => '还没有草稿';

  @override
  String get tavernDraftsEmptyOwn => '新建一份草稿，告诉 AI 想怎么改这张卡。';

  @override
  String get tavernDraftsEmptyAll => '从角色页开一份草稿，或者从文件起稿：文件先当草稿，不会直接导入。';

  @override
  String get tavernDraftNew => '新草稿';

  @override
  String get tavernDraftFromFile => '从文件起稿';

  @override
  String tavernDraftSeedUnsupported(String name) {
    return '$name 不是角色卡或世界书，没法起稿';
  }

  @override
  String get tavernDraft => '草稿';

  @override
  String get tavernDraftSubtitle => '草稿里的改动还没用到真的卡上';

  @override
  String get tavernDraftGone => '这份草稿已经不在了';

  @override
  String get tavernDraftKindCharacter => '角色卡';

  @override
  String get tavernDraftKindPreset => '预设';

  @override
  String tavernDraftNewSource(String name) {
    return '$name（还没存）';
  }

  @override
  String get tavernDraftGreetings => '备选开场白';

  @override
  String tavernDraftEntry(int n) {
    return '第 $n 条';
  }

  @override
  String get tavernDraftNoChanges => '还没有改动';

  @override
  String get tavernDraftNoChangesHint => '在下面告诉 AI 想怎么改';

  @override
  String get tavernDraftBefore => '原来';

  @override
  String get tavernDraftAfter => '改成';

  @override
  String get tavernDraftAbsent => '（没有）';

  @override
  String get tavernDraftRemoved => '删掉';

  @override
  String get tavernDraftAppliedChange => '已应用';

  @override
  String tavernDraftDependsOn(int n) {
    return '要和它前面的 $n 处改动一起用';
  }

  @override
  String get tavernDraftRemoveChange => '从草稿里去掉这处';

  @override
  String tavernDraftApply(int n) {
    return '应用 $n 处';
  }

  @override
  String get tavernDraftSaveNew => '另存为新的';

  @override
  String get tavernDraftSavedNew => '已另存为新的';

  @override
  String get tavernDraftChecked => '检查过，没发现问题';

  @override
  String get tavernDraftCannotApply => '正则和预设的草稿暂时只能预览，不能应用';

  @override
  String tavernDraftApplied(String name) {
    return '已应用到「$name」';
  }

  @override
  String get tavernDraftNoChange => '和现在的一样，没有要改的';

  @override
  String tavernDraftNotApplied(String reason) {
    return '没有应用：$reason';
  }

  @override
  String get tavernDraftUnconfirmed => '写入结果还没确认。先别重复点，过一会儿看历史版本里有没有。';

  @override
  String tavernDraftApplyUnknown(String reason) {
    return '没收到结果（$reason），再点一次会接着同一次操作';
  }

  @override
  String tavernDraftBehind(String name) {
    return '「$name」在起草之后改过了（也可能是刚应用过）。按现在的版本继续，再看一遍改动。';
  }

  @override
  String get tavernDraftCatchUp => '按现在的版本继续';

  @override
  String get tavernDraftChangedMeanwhile => '草稿刚被改过，已刷新';

  @override
  String get tavernDraftPending => '上一次写入还没确认，暂时不能再应用';

  @override
  String get tavernDraftDelete => '删除草稿';

  @override
  String get tavernDraftDeleteTitle => '删除这份草稿？';

  @override
  String get tavernDraftDeleteBody => '只删草稿，已经应用到卡上的不受影响。';

  @override
  String get tavernDraftAskHint => '想怎么改？比如：开场白冷淡一点';

  @override
  String get tavernDraftAiSend => '让 AI 改';

  @override
  String get tavernDraftAiStop => '停下';

  @override
  String get tavernDraftAiTitle => 'AI';

  @override
  String get tavernDraftAiRunning => '正在改…';

  @override
  String get tavernDraftAiDone => '改好了，改动在上面，挑好再应用';

  @override
  String get tavernDraftAiStopped => '已停下';

  @override
  String get tavernDraftAiConflict => '草稿在这期间被改过，AI 停下了';

  @override
  String get tavernDraftAiBudget => '四次请求用完了，先停在这里';

  @override
  String get tavernDraftAiFailed => '出错了';

  @override
  String get tavernDraftAiInterrupted => '中断了（App 关过）';

  @override
  String get tavernDraftEarlier => '之前问过的';

  @override
  String tavernDraftRunReceipts(int changes, int requests) {
    return '改了 $changes 次 · $requests 次请求';
  }

  @override
  String get tavernDraftHistory => '历史版本';

  @override
  String get tavernDraftHistoryEmpty => '还没有记下的版本';

  @override
  String get tavernDraftHistoryNote => '回到某一版会另存成新的一版，之后的版本都还在；图片和对话不受影响。';

  @override
  String tavernDraftVersion(int n) {
    return '第 $n 版';
  }

  @override
  String get tavernDraftVersionCurrent => '现在';

  @override
  String get tavernDraftRestore => '回到这一版';

  @override
  String tavernDraftRestoreTitle(int n) {
    return '回到第 $n 版？';
  }

  @override
  String get tavernDraftRestoreBody => '会另存成新的一版。';

  @override
  String tavernDraftRestored(int n) {
    return '已回到第 $n 版';
  }

  @override
  String get tavernDraftRestoreMoved => '这期间又改过了，刷新后再试';

  @override
  String get tavernDraftPrompt => '用草稿看提示词';

  @override
  String get tavernDraftPromptSubtitle => '把勾选的改动放进去，看下一轮会发什么；什么都不发送';

  @override
  String get tavernDraftPromptFrom => '接着哪段对话';

  @override
  String get tavernDraftPromptFirst => '新对话的第一句';

  @override
  String get tavernDraftPromptText => '下一句（可不填）';

  @override
  String get tavernDraftPromptTextHint => '你会说的话';

  @override
  String get tavernDraftPromptShow => '看提示词';

  @override
  String get tavernDraftPromptComplete => '提示词';

  @override
  String get tavernDraftPromptUnsupported => '这张卡有些内容在预览里没法照实拼出来';

  @override
  String get tavernDraftPromptNote => '卡里的脚本在预览里不运行。';

  @override
  String tavernDraftUsagePartial(String prompt, String completion) {
    return '已报告：输入 $prompt · 输出 $completion（有请求没报告用量）';
  }

  @override
  String get tavernDraftTrial => '试玩';

  @override
  String get tavernDraftTrialSubtitle => '用草稿在一段临时对话里聊几句，真实对话不受影响';

  @override
  String get tavernDraftTrialNote => '会真的请求模型，按实际用量计费；最多四句。';

  @override
  String tavernDraftTrialLine(int n) {
    return '第 $n 句';
  }

  @override
  String get tavernDraftTrialMore => '再加一句';

  @override
  String get tavernDraftTrialPlay => '开始试玩';

  @override
  String get tavernDraftTrialRunning => '正在试…';

  @override
  String get tavernDraftTrialDone => '试完了';

  @override
  String get tavernDraftTrialUnsupported => '这份草稿暂时没法试玩';

  @override
  String get tavernImportFromDeepSeek => '从 DeepSeek 接回来';

  @override
  String get tavernImportFromDeepSeekSubtitle => '选 DeepSeek 设置里导出的 ZIP';

  @override
  String get tavernDeepSeekTitle => '接回 DeepSeek 的对话';

  @override
  String tavernDeepSeekFound(int count) {
    return '找到 $count 段对话，勾上要接回来的';
  }

  @override
  String tavernDeepSeekMessages(int count) {
    return '$count 条';
  }

  @override
  String get tavernDeepSeekUntitled => '没有标题的对话';

  @override
  String get tavernDeepSeekAlready => '已经接回来了，点开继续';

  @override
  String tavernDeepSeekMore(int count) {
    return '显示更多（还有 $count 段）';
  }

  @override
  String tavernDeepSeekTake(int count) {
    return '接回来（$count）';
  }

  @override
  String get tavernDeepSeekTaking => '正在接回…';

  @override
  String get tavernDeepSeekNotExport => '这不是 DeepSeek 导出的对话';

  @override
  String get tavernDeepSeekNotExportMessage => '要选在 DeepSeek 里导出全部历史对话后得到的那个 ZIP';

  @override
  String get tavernDeepSeekFailed => '没接回来，再试一次';

  @override
  String tavernDeepSeekTaken(int count) {
    return '接回了 $count 段，其余的在对话列表里';
  }

  @override
  String get tavernIslandStoryWaiting => '正在读取本条消息的数据…';

  @override
  String tavernIslandStoryFailed(String reason) {
    return '本条消息的数据读取失败：$reason';
  }

  @override
  String get tavernPacks => '玩法包';

  @override
  String get tavernPacksSubtitle => '装上后要在全局、角色或对话里加上才生效';

  @override
  String get tavernPacksEmpty => '还没有玩法包';

  @override
  String get tavernPacksEmptyNote => '导入 .dshpack 文件。导入只是保存，不会启用，也不会建角色。';

  @override
  String get tavernPackImport => '导入玩法包';

  @override
  String tavernPackInstalled(String title, String version) {
    return '已导入「$title」$version';
  }

  @override
  String tavernPackAlreadyInstalled(String title, String version) {
    return '「$title」$version 已经装过，内容一样';
  }

  @override
  String tavernPackVersionCount(int n) {
    return '$n 个版本';
  }

  @override
  String tavernPackWithdrawnShort(String version) {
    return '$version（已撤下）';
  }

  @override
  String get tavernPackWithdrawnLabel => '已撤下';

  @override
  String get tavernPackShowWithdrawn => '显示已撤下的版本';

  @override
  String get tavernPackScopeGlobal => '全局启用';

  @override
  String get tavernPackScopeCharacter => '这个角色的玩法包';

  @override
  String get tavernPackScopeChat => '这段对话的玩法包';

  @override
  String get tavernPackForCardSubtitle => '这张卡的所有对话都用';

  @override
  String get tavernPackBindingsSubtitle => '改完点保存才生效；先预览可以看组合结果';

  @override
  String get tavernPackOrderNote => '按从上到下的顺序组合，同一个字段谁生效以预览为准。点一行可以换版本、调顺序、关联角色。';

  @override
  String get tavernPackAdd => '添加玩法包';

  @override
  String get tavernPackUnsaved => '未保存';

  @override
  String get tavernPackResetPending => '保存时重置一次性状态';

  @override
  String tavernPackCastMappedCount(int n) {
    return '关联了 $n 个角色';
  }

  @override
  String get tavernPackRemovedBindings => '已移除';

  @override
  String get tavernPackPickVersion => '换版本';

  @override
  String get tavernPackMoveUp => '上移';

  @override
  String get tavernPackMoveDown => '下移';

  @override
  String get tavernPackResetOnce => '重置一次性状态';

  @override
  String get tavernPackRestore => '恢复';

  @override
  String get tavernPackRemoveBinding => '移除';

  @override
  String get tavernPackSaved => '已保存';

  @override
  String tavernPackUnanswered(String reason) {
    return '没收到结果：$reason。再点保存会按同一次操作重试';
  }

  @override
  String get tavernPackVersion => '版本';

  @override
  String get tavernPackAddGlobal => '加到全局';

  @override
  String get tavernPackAddNote => '只给某个角色或对话：在角色页或舞台面板里加';

  @override
  String get tavernPackCast => '角色';

  @override
  String get tavernPackCastNote => '导入会新建角色，不改原来的卡';

  @override
  String get tavernPackCastFromCard => '完整角色卡';

  @override
  String get tavernPackCastImportAction => '导入为角色';

  @override
  String tavernPackCastImportTitle(String name) {
    return '把「$name」导入为新角色？';
  }

  @override
  String get tavernPackCastImportNote => '会在角色库里新建一个角色。之后改这个玩法包的版本，不会替换它。';

  @override
  String tavernPackCastImported(String name) {
    return '已导入「$name」';
  }

  @override
  String get tavernPackCastNotAdopted => '这次没有建成角色';

  @override
  String tavernPackCastUnknown(String state) {
    return '结果还没确认（$state），稍后到角色库看看';
  }

  @override
  String get tavernPackCastMapping => '关联角色';

  @override
  String get tavernPackCastMapped => '已关联';

  @override
  String get tavernPackResources => '资源';

  @override
  String tavernPackIssueCount(int n) {
    return '$n 条提示';
  }

  @override
  String get tavernPackDeclaration => '声明检查';

  @override
  String get tavernPackDeclarationNote => '导入时的检查结果。装上了不等于每一块都能执行；标着 conditional 或 opaque 的部分要看具体情况。';

  @override
  String get tavernPackNothingNoted => '没有提示';

  @override
  String get tavernPackExportOriginal => '导出原文件';

  @override
  String get tavernPackWithdraw => '撤下这个版本';

  @override
  String tavernPackWithdrawTitle(String version) {
    return '撤下 $version？';
  }

  @override
  String get tavernPackWithdrawNote => '撤下后不能再新选这个版本；已经在用它的地方保持不变。原文件和记录都保留，还能导出。';

  @override
  String get tavernPackPreview => '预览组合';

  @override
  String get tavernPackPreviewSubtitle => '按现在的改动组合一遍，不保存、不运行';

  @override
  String get tavernPackPreviewSources => '来源';

  @override
  String get tavernPackPreviewDefinitions => '定义';

  @override
  String get tavernPackPreviewConflicts => '组合冲突';

  @override
  String get tavernPackPreviewFields => '字段来源';

  @override
  String get tavernPackPreviewState => '当前的值';

  @override
  String get tavernPackPreviewNote => '预览只读：不保存绑定、不初始化变量、不发模型请求。';

  @override
  String get tavernPackStateUnavailable => '当前对话还没有状态可查';

  @override
  String get tavernPackStateNotValidated => '这次没有验证当前的值，请看定义和组合诊断';

  @override
  String get tavernPackStateValid => '当前的值符合组合后的定义';

  @override
  String get tavernPackStateInvalid => '当前的值和组合后的定义对不上';

  @override
  String get tavernPackStateMissing => '当前对话里没有这个值';

  @override
  String get tavernPackCardExport => '导出（带玩法包）';

  @override
  String get tavernPackCardExportMenuSubtitle => '把选中的玩法包资源并进卡里';

  @override
  String get tavernPackCardExportSubtitle => '先预览，确认没有阻断再导出';

  @override
  String get tavernPackExportFormat => '格式';

  @override
  String get tavernPackExportCopyMedia => '带上卡里的图片';

  @override
  String get tavernPackExportFlattenNote => '资源并进单张卡后，作用域、排序、预算和计时可能和在这里玩时不同';

  @override
  String get tavernPackExportNoResources => '这张卡启用的玩法包里没有能并进卡的资源';

  @override
  String get tavernPackExportFindings => '预览结果';

  @override
  String tavernPackExportMappings(int ids, int resources) {
    return '改写 $ids 个标识、$resources 个资源';
  }

  @override
  String get tavernPackExportGo => '导出';

  @override
  String get tavernPackExportPreviewFirst => '先预览';

  @override
  String get tavernPackExportBlocked => '有阻断项，不能导出';

  @override
  String get tavernPackDraftExport => '导出为玩法包';

  @override
  String tavernPackDraftExportSubtitle(int n) {
    return '用这份草稿的角色定义和全部 $n 处改动做一个新的 .dshpack';
  }

  @override
  String get tavernPackDraftId => '包标识';

  @override
  String get tavernPackDraftRoots => '要带上的状态路径';

  @override
  String get tavernPackDraftRootsHint => '如 /hp /items，空着就带整份';

  @override
  String get tavernPackInstallMade => '装到本机';

  @override
  String get tavernPackCommitted => '修改已生效，但后续通知失败了';

  @override
  String get tavernPackVersionConflict => '同一包标识和版本名已经有不同的内容，请换一个新版本名';

  @override
  String get tavernPackRevisionConflict => '配置在别处变了，已刷新，请重新确认这次修改';

  @override
  String get tavernPackOperationConflict => '这次操作和之前的一次重名了，请重新做一遍';

  @override
  String get tavernPackVersionNotFound => '找不到这个版本';

  @override
  String get tavernPackVersionRemoved => '这个版本已经撤下，不能新选';

  @override
  String get tavernPackTimerConflict => '这次升级改了粘滞或冷却的设置：请同时重置一次性状态，或者新加一个实例';

  @override
  String get tavernPackTargetGone => '要改的角色、对话或绑定已经不在了';

  @override
  String get tavernPackAuthorityConflict => '角色来源变了，请刷新后再确认';

  @override
  String get tavernPackCastUnproven => '确认不了这个角色是从这个包导入的';

  @override
  String get tavernPackCastOtherVersion => '关联的角色来自这个包的另一个版本';

  @override
  String get tavernPackExportChanged => '导出的来源或选项变了，请重新预览';

  @override
  String get tavernScripts => '脚本库';

  @override
  String get tavernScriptsEmpty => '还没有全局脚本';

  @override
  String get tavernScriptsEmptyMessage => '可以导入酒馆助手导出的脚本 JSON，打开的在整页画布里运行';

  @override
  String get tavernScriptsImport => '导入脚本';

  @override
  String tavernScriptsImported(int count) {
    return '$count 个脚本加入了脚本库';
  }

  @override
  String get tavernScriptsExportAll => '导出全部';

  @override
  String get tavernScriptsOrder => '调整顺序';

  @override
  String get tavernScriptsOrderNote => '从上到下依次运行，拖动右边的把手调整。';

  @override
  String tavernScriptCount(int count) {
    return '$count 个';
  }

  @override
  String get tavernScriptUnnamed => '未命名脚本';

  @override
  String get tavernScriptOpenFolder => '打开文件夹';

  @override
  String get tavernScriptExport => '导出';

  @override
  String get tavernScriptDelete => '删除';

  @override
  String tavernScriptDeleteTitle(String name) {
    return '删除「$name」？';
  }

  @override
  String get tavernScriptDeleteMessage => '它的变量和按钮会一起删除，找不回来。';

  @override
  String get tavernChatScripts => '脚本';

  @override
  String get tavernChatScriptsNote => '按运行顺序';

  @override
  String get tavernScriptSourceGlobal => '全局';

  @override
  String get tavernScriptSourcePreset => '预设';

  @override
  String get tavernScriptSourceCard => '卡';

  @override
  String tavernChatScriptsSkipped(int count) {
    return '$count 个脚本没有运行';
  }

  @override
  String get updateCheck => '检查更新';

  @override
  String get updateAutoCheck => '自动检查更新';

  @override
  String get updateAutoCheckDaily => '每天检查一次';

  @override
  String get updateTileDownloading => '下载中';

  @override
  String updateTileDownloadingPercent(int percent) {
    return '下载中 $percent%';
  }

  @override
  String get updateTileVerifying => '校验中';

  @override
  String get updateTileReady => '可以安装';

  @override
  String get updateTileInstalling => '安装中';

  @override
  String updateTileSkipped(String version) {
    return '已跳过 $version';
  }

  @override
  String updateTileNewVersion(String version) {
    return '新版本 $version';
  }

  @override
  String get updateTileUpToDate => '已是最新';

  @override
  String get updateTileUnavailable => '暂时检查不了';

  @override
  String get updateUpToDate => '已是最新版本';

  @override
  String get updateCheckUnavailable => '暂时检查不了更新，稍后再试';

  @override
  String get updateDownloadInterrupted => '下载中断了';

  @override
  String get updateDownloadInterruptedMessage => '网络断开或太慢，重试会接着下载。';

  @override
  String get updateDownloadUnavailable => '下载地址暂时打不开';

  @override
  String get updateDownloadUnavailableMessage => '稍后再试，或去发布页手动下载。';

  @override
  String get updateChecksumFailed => '安装包校验没通过';

  @override
  String get updateChecksumFailedMessage => '文件和发布时不一致，已删除，请重试。';

  @override
  String get updateChecksumMissing => '缺少校验信息';

  @override
  String get updateChecksumMissingMessage => '为了安全不在 App 内安装，可以去发布页手动下载。';

  @override
  String get updateStorageWriteFailed => '写不进安装包';

  @override
  String get updateStorageWriteFailedMessage => '存储可能已满，清理一些空间后重试。';

  @override
  String get updateFreeSpaceRetry => '清理一些空间后重试。';

  @override
  String updateSpaceRequired(String size) {
    return '需要约 $size 可用空间，清理后重试。';
  }

  @override
  String get updateSettingsOpenFailed => '没能打开系统设置';

  @override
  String get updateSettingsOpenFailedMessage => '到「设置 → 应用 → DSH Go」里允许「安装未知应用」，再回来安装。';

  @override
  String get updateInstallCancelled => '已取消安装';

  @override
  String get updateInstallCancelledMessage => '安装包还在，随时可以再装。';

  @override
  String get updateInstallUnconfirmed => '尚未确认安装结果';

  @override
  String get updateInstallUnconfirmedMessage => '安装包已保留。可先检查系统提示，再重试或用系统安装器打开。';

  @override
  String get updateSignatureMismatch => '签名不一致，不能直接覆盖';

  @override
  String get updateSignatureMismatchMessage => '手机上的 DSH Go 签名不同（多半是测试包），需要先卸载旧版再装新版。卸载会清空对话、Linux 环境和设置。';

  @override
  String get updateWrongPackage => '不是 DSH 的安装包';

  @override
  String get updateWrongPackageMessage => '下载到的文件不对，已删除，请稍后重试。';

  @override
  String get updateDowngradeBlocked => '不能降级安装';

  @override
  String get updateDowngradeBlockedMessage => '手机上的 DSH 比这个安装包还新。';

  @override
  String get updateIncompatible => '和这台手机不兼容';

  @override
  String get updateIncompatibleMessage => '安装包要求的系统版本或处理器架构和手机不符。';

  @override
  String get updatePackageCorrupt => '安装包已损坏';

  @override
  String get updatePackageCorruptMessage => '已删除，请重新下载。';

  @override
  String get updateInstallBlocked => '安装被拦截了';

  @override
  String get updateInstallBlockedMessage => '在系统的安装确认里允许；如果系统直接拦下（小米等机型），试试下面的「安装路线」：Shizuku 或本机 ADB，不用重新签名。';

  @override
  String get updateInstallIncomplete => '安装没有完成';

  @override
  String get updateInstallIncompleteMessage => '可以重试，或去发布页手动下载。';

  @override
  String updateBrowserOpenFailed(String host, String path) {
    return '没能打开浏览器，请手动访问 $host$path';
  }

  @override
  String updateUpToDateVersion(String version) {
    return '已是最新版本 $version';
  }

  @override
  String updateCurrentVersion(String version) {
    return '当前 $version';
  }

  @override
  String get updateNewVersionFound => '发现新版本';

  @override
  String get updateReleaseNotes => '更新内容';

  @override
  String get updateNoReleaseNotes => '这个版本没有写更新说明。';

  @override
  String get updateInstallKeepsData => '安装时 DSH Go 会退出，对话和设置都会保留';

  @override
  String get updateNoCompatiblePackage => '没有适合本机的安装包';

  @override
  String get updateDownloading => '正在下载';

  @override
  String updateDownloadSource(String source) {
    return '经由 $source';
  }

  @override
  String get updateDownloadInBackgroundNote => '关掉窗口也会继续下载';

  @override
  String get updateVerifyingPackage => '正在校验安装包…';

  @override
  String get updateVerifyingPackageNote => '确认文件和发布时一致';

  @override
  String get updateInstalling => '正在安装…';

  @override
  String get updateConfirmInstallNote => '在系统弹窗里确认安装';

  @override
  String get updatePackageDownloaded => '安装包已下载';

  @override
  String get updateReadyToInstall => '校验通过，可以安装了。';

  @override
  String get updateAllowInstall => '允许 DSH Go 安装应用';

  @override
  String get updateAllowInstallMessage => '在系统设置里打开「安装未知应用」，回来后自动继续。';

  @override
  String get updateOpenReleasePage => '打开发布页';

  @override
  String get updateUpdateNow => '立即更新';

  @override
  String get updateSkipVersion => '跳过这个版本';

  @override
  String get updateInstallWithSystem => '用系统安装器安装';

  @override
  String get updateSystemInstallerFailed => '没能打开系统安装器';

  @override
  String get updateExportApk => '导出安装包';

  @override
  String get updateExportApkTitle => '导出安装包？';

  @override
  String get updateExportApkMessage =>
      '会把这次下载并校验过的安装包复制到「下载/DSH-Go」，可以用 MT 管理器之类的工具重新签名后再装。\n\n重新签名后，手机上的签名和官方包不同，App 内更新会一直提示「签名不一致」，以后每次更新都要这样手动重签安装。\n\n如果只是系统拦着装不上（小米等机型），先试「安装路线」里的 Shizuku 或本机 ADB，那条路不用重新签名。';

  @override
  String updateExportApkDone(String path) {
    return '已存到 下载/$path';
  }

  @override
  String get updateExportApkFailed => '没能导出安装包';

  @override
  String get updateStarProject => '去 Star';

  @override
  String get updateCancelDownload => '取消下载';

  @override
  String get updateDownloadInBackground => '后台下载';

  @override
  String get updateVerifying => '正在校验…';

  @override
  String get updateInstallingBusy => '安装中…';

  @override
  String get updateOpenPermissionSettings => '去开启';

  @override
  String updateNoAbiPackage(String abi) {
    return '这个版本还没有 $abi 安装包，可以去发布页看看。';
  }

  @override
  String get updateNoPackage => '这个版本还没有安装包，可以去发布页看看。';

  @override
  String updateDownloadingPercent(int percent) {
    return '正在下载 $percent%';
  }

  @override
  String get usageStatsTitle => '发送匿名使用统计';

  @override
  String get usageStatsSection => '改进 DSH Go';

  @override
  String get usageStatsFooter =>
      '这个开关只控制 dsh-go 自身的统计：各功能使用次数（含酒馆消息、伙伴小屋、语音通话）、模型回复报告的 token 数、版本、手机品牌和型号、系统版本，不含对话、角色卡、文件和账号；它不控制 Google ML Kit SDK 的统计。';

  @override
  String get usageNoticeBody => '不含对话和个人信息，可随时关闭';

  @override
  String get usageUpgradeNotice => '新增匿名使用统计，帮助改进 DSH Go。\n不含对话和个人信息';

  @override
  String get usageV4Welcome => '按日汇总使用和模型用量，不含对话。可随时关闭。';

  @override
  String get usageV4Notice => '匿名统计按日汇总功能结果、模型用量和异常退出，不含对话。';

  @override
  String get usageUpgradeLearn => '了解';

  @override
  String get usageUpgradeOff => '关闭';

  @override
  String get usageStatsAndroidFooter =>
      '这个开关只控制 dsh-go 自身的统计：各功能使用次数（含酒馆消息、伙伴小屋、语音通话）、模型回复报告的 token 数、版本、手机品牌和型号、系统版本，不含对话、角色卡、文件和账号；它不控制 Google ML Kit SDK 的统计。 Android 还按日汇总前台及首次参与统计、启动和远程连接结果与耗时区间，以及模型用量、插件执行、引导和系统确认的异常退出。关闭会清空未上报的数据。';

  @override
  String viewArtifactSaved(String value) {
    return '已存到 $value';
  }

  @override
  String get viewDownloadFolder => '下载/';

  @override
  String get viewArtifactNoPreview => '无法预览';

  @override
  String get viewArtifactNotText => '不是文本文件';

  @override
  String get viewArtifactLarge => '文件较大';

  @override
  String get viewArtifactMissing => '文件已经不在了';

  @override
  String get viewArtifactNotFile => '这不是文件';

  @override
  String get viewArtifactOpenFailed => '没能打开';

  @override
  String get viewArtifactMore => '更多操作';

  @override
  String get viewWorkspace => '工作区';

  @override
  String get viewArtifactEmpty => '空文件';

  @override
  String viewArtifactLines(int count) {
    return '文件较大，只显示前 $count 行';
  }

  @override
  String viewArtifactRows(int count) {
    return '只显示前 $count 行';
  }

  @override
  String get viewArtifactColumns => '只显示前 200 列';

  @override
  String viewArtifactWorksheet(int value) {
    return '工作表 $value';
  }

  @override
  String get viewArtifactEmptySheet => '空工作表';

  @override
  String get viewArtifactEmptyTable => '空表格';

  @override
  String get viewArtifactConvertFailed => '没能转换';

  @override
  String get viewArtifactConverting => '正在转换为 PDF 预览…';

  @override
  String get viewArtifactImageFailed => '无法显示这张图片';

  @override
  String get viewArtifactPhoneOpen => '用手机上的应用打开';

  @override
  String get viewArtifactPdfFailed => '无法打开这个 PDF，试试用其他应用打开';

  @override
  String viewArtifactPages(int count) {
    return '共 $count 页';
  }

  @override
  String viewArtifactPage(int value) {
    return '第 $value 页';
  }

  @override
  String get viewBalanceInvalidKey => 'Key 无效，查不到余额';

  @override
  String get viewBalancePrefix => '余额 ';

  @override
  String get viewBalanceLowSuffix => ' · 余额不足';

  @override
  String get viewBalanceUnavailableSuffix => ' · 已不能调用';

  @override
  String get viewBalanceTopUp => '充值';

  @override
  String get viewBalanceTitle => 'DeepSeek 余额';

  @override
  String get viewBalanceKeyRequired => '填写 API Key 后可查询余额';

  @override
  String get viewBalanceKeyInvalid => 'API Key 无效，无法查询余额';

  @override
  String viewBalancePaid(String value) {
    return '充值 $value';
  }

  @override
  String viewBalanceGranted(String value) {
    return '赠送 $value';
  }

  @override
  String get viewBalanceLow => '余额不足';

  @override
  String get viewBalanceUnavailable => '已无法调用';

  @override
  String get viewBalanceChecking => '正在查询余额…';

  @override
  String get viewBalanceCheckFailed => '暂时无法查询余额';

  @override
  String get viewBalanceNoAlert => '不提醒';

  @override
  String get viewBalanceBannerHidden => '本次运行不再显示余额提醒';

  @override
  String get viewBalanceTurnOff => '不再提醒';

  @override
  String viewBalanceBelow(String value) {
    return '低于 $value';
  }

  @override
  String get viewBalanceAlert => '低余额提醒';

  @override
  String get viewBalanceThreshold => '提醒线';

  @override
  String get viewBalanceGoTopUp => '去充值';

  @override
  String viewBalanceRemaining(String value) {
    return '余额仅剩 $value';
  }

  @override
  String get viewBalanceModelDisabled => '余额不足，模型已停用';

  @override
  String get viewBalanceRestore => '充值后恢复';

  @override
  String get viewUiIncomplete => '视图没有生成完';

  @override
  String get viewUiInvalid => '这个视图格式有误';

  @override
  String get viewUiResend => '让它重发';

  @override
  String viewChartUnit(String value) {
    return '单位：$value';
  }

  @override
  String viewChartSeries(int value) {
    return '第 $value 组';
  }

  @override
  String get viewChartTotal => '合计';

  @override
  String get viewChartBar => '柱状图';

  @override
  String get viewChartHorizontalBar => '横向柱状图';

  @override
  String get viewChartLine => '折线图';

  @override
  String get viewChartDonut => '环形图';

  @override
  String viewUiResendMessage(Object value) {
    return '上一个 dsh-ui 视图无法显示：$value。请修正后重发。';
  }

  @override
  String viewUiBytesLimit(int first, int second) {
    return '视图有 $first 字节，超过上限 $second 字节';
  }

  @override
  String get viewUiEmptyCode => '代码块是空的';

  @override
  String viewUiInvalidJson(String message) {
    return '不是合法的 JSON（$message）';
  }

  @override
  String get viewUiJsonRepaired => '含注释或尾逗号，已忽略';

  @override
  String get viewUiExpectedObject => '应该是一个组件对象';

  @override
  String viewUiDepthLimit(int first, int second) {
    return '第 $first 层，超过上限 $second 层';
  }

  @override
  String get viewUiMissingType => '缺少 type';

  @override
  String viewUiUnknownComponent(String value) {
    return '未知组件 $value';
  }

  @override
  String viewUiAvailableTypes(String first, String second) {
    return '$first；可用：$second';
  }

  @override
  String viewUiExpectedChildren(int limit) {
    return '应该是 1 到 $limit 个组件的数组';
  }

  @override
  String viewUiHiddenItems(int count) {
    return '已截断：还有 $count 项没有显示';
  }

  @override
  String viewUiNodeLimit(int first, int second) {
    return '超过 $first 个组件，后 $second 项已截断';
  }

  @override
  String viewUiChildLimit(int first, int second) {
    return '超过 $first 项，后 $second 项已截断';
  }

  @override
  String get viewUiExpectedString => '应该是字符串';

  @override
  String viewUiTextLimit(int first, int second) {
    return '$first 个字符，超过上限 $second';
  }

  @override
  String get viewUiTextTruncated => '已截断：文字过长';

  @override
  String get viewUiExpectedFinite => '应该是有限的数';

  @override
  String get viewUiYes => '是';

  @override
  String get viewUiNo => '否';

  @override
  String get viewUiExpectedStringNumber => '应该是字符串或数字';

  @override
  String viewUiUnknownTone(String value) {
    return '未知 tone $value，已忽略；可用：good, warn, bad';
  }

  @override
  String viewUiUnknownChart(String value) {
    return '未知图表 $value，按柱状图画；可用：bar, hbar, line, donut';
  }

  @override
  String get viewUiExpectedCategories => '应该是非空的标签数组';

  @override
  String viewUiCategoryLimit(int first, int second) {
    return '$first 个类别，超过上限 $second';
  }

  @override
  String viewUiFirstPoints(int limit) {
    return '只显示前 $limit 个点';
  }

  @override
  String viewUiExpectedSeries(String shape) {
    return '应该是非空的数组，每项是 $shape';
  }

  @override
  String get viewUiSkippedSeries => '应该是数字数组，这组已跳过';

  @override
  String viewUiValuesCategories(int first, int second) {
    return '$first 个值对 $second 个类别，多的截掉、缺的留空';
  }

  @override
  String viewUiNonFiniteValues(int count) {
    return '$count 个值不是有限的数，已留空';
  }

  @override
  String get viewUiNoSeries => '没有一组能画的数据';

  @override
  String viewUiDonutSeries(int count) {
    return '环形图只画一组数据，其余 $count 组已忽略';
  }

  @override
  String get viewUiFirstSeries => '只画第一组数据';

  @override
  String viewUiSeriesLimit(int first, int second) {
    return '$first 组数据，超过上限 $second';
  }

  @override
  String viewUiFirstSeriesCount(int limit) {
    return '只显示前 $limit 组数据';
  }

  @override
  String get viewUiNoFiniteValues => '没有一个有限的数值';

  @override
  String viewUiTruncated(String value) {
    return '已截断：$value';
  }

  @override
  String viewUiExpectedCompare(int limit, String shape) {
    return '应该是 2 到 $limit 项的数组，每项是 $shape';
  }

  @override
  String viewUiItemLimit(int first, int second) {
    return '$first 项，超过上限 $second';
  }

  @override
  String viewUiFirstItems(int limit) {
    return '只显示前 $limit 项';
  }

  @override
  String viewUiSkippedCompare(String shape) {
    return '应该是 $shape，已跳过';
  }

  @override
  String get viewUiSkippedItemLabel => '应该是非空字符串，这项已跳过';

  @override
  String viewUiRowLimit(int first, int second) {
    return '$first 行，超过上限 $second';
  }

  @override
  String get viewUiSkippedRow => '应该是 [名称, 值]，已跳过';

  @override
  String get viewUiNoItems => '没有一项能画';

  @override
  String viewUiFirstRows(int limit) {
    return '每项只显示前 $limit 行';
  }

  @override
  String viewUiExpectedSteps(String shape) {
    return '应该是非空数组，每项是 $shape';
  }

  @override
  String viewUiStepLimit(int first, int second) {
    return '$first 步，超过上限 $second';
  }

  @override
  String viewUiFirstSteps(int limit) {
    return '已截断：只显示前 $limit 步';
  }

  @override
  String viewUiSkippedStep(String shape) {
    return '应该是 $shape，已跳过';
  }

  @override
  String viewUiUnknownStatus(String value) {
    return '未知状态 $value，按 todo 画；可用：done, current, todo, failed';
  }

  @override
  String get viewUiNoSteps => '没有一步能画';

  @override
  String viewUiUnknownCalloutTone(String value) {
    return '未知 tone $value，按 info 画；可用：info, good, warn, bad';
  }

  @override
  String viewUiExpectedOptions(int limit, String shape) {
    return '应该是 1 到 $limit 个选项的数组，每项是 $shape';
  }

  @override
  String viewUiOptionLimit(int first, int second) {
    return '$first 个选项，超过上限 $second';
  }

  @override
  String viewUiFirstOptions(int limit) {
    return '已截断：只显示前 $limit 个选项';
  }

  @override
  String viewUiDuplicateLabel(String value) {
    return '重复的 label $value，已跳过';
  }

  @override
  String get viewUiNoOptions => '没有一个能用的选项';

  @override
  String viewUiSummaryBody(String value) {
    return '[视图] $value';
  }

  @override
  String viewUiSummaryTitleBody(String first, String second) {
    return '[视图] $first：$second';
  }

  @override
  String get viewUiSummaryInvalid => '[视图]（格式有误，未能显示）';

  @override
  String viewUiSummaryText(String value) {
    return '文字：$value';
  }

  @override
  String viewUiSummaryChart(String summary) {
    return '图表：$summary';
  }

  @override
  String viewUiSummaryCompare(String value) {
    return '对比：$value';
  }

  @override
  String viewUiSummarySteps(String value) {
    return '步骤：$value';
  }

  @override
  String viewUiSummaryCallout(String value) {
    return '提示：$value';
  }

  @override
  String viewUiSummaryOptions(String value) {
    return '选项：$value';
  }

  @override
  String viewUiSummaryConfirm(String first, String second) {
    return '确认：$first/$second';
  }

  @override
  String viewUiReplyChoice(String value) {
    return '选择：$value';
  }

  @override
  String viewUiReplyConfirm(String value) {
    return '确认：$value';
  }

  @override
  String viewUiReplyCancel(String value) {
    return '取消：$value';
  }

  @override
  String viewUiReplyOther(String value) {
    return '其他：$value';
  }

  @override
  String get viewUiFreeTextHint => '其他（自己填）';

  @override
  String viewUiChosenOther(String value) {
    return '已填写：$value';
  }

  @override
  String viewUiChosen(String value) {
    return '已选择：$value';
  }

  @override
  String get viewUiConfirmed => '已确认';

  @override
  String viewUiConfirmedValue(String value) {
    return '已确认：$value';
  }

  @override
  String viewUiCancelledValue(String value) {
    return '已取消：$value';
  }

  @override
  String get viewUiReplied => '已回复';

  @override
  String get viewUiGenerating => '正在生成视图';

  @override
  String get viewUiReplyAfterEnd => '回复结束后可选';

  @override
  String get viewUiExpired => '已失效';

  @override
  String get viewUiNotStarted => '未开始';

  @override
  String get viewUiMultiple => '可多选';

  @override
  String get viewSuggestWorkspace => '看看工作区';

  @override
  String get viewSuggestWorkspacePrompt => '看看工作区里现在有哪些文件和项目，简单介绍一下。';

  @override
  String get viewSuggestWordCount => '写个小脚本';

  @override
  String get viewSuggestWordCountPrompt => '写一个 Python 脚本：统计一个文本文件里出现最多的 20 个词，并运行一次给我看结果。';

  @override
  String get viewSuggestNode => '新建项目';

  @override
  String get viewSuggestNodePrompt => '在工作区新建一个 Node.js 项目，配好 TypeScript 和一个最小的单元测试。';

  @override
  String get viewSuggestGit => '讲讲 Git';

  @override
  String get viewSuggestGitPrompt => '用一个具体例子解释 git rebase 和 git merge 的区别，各自什么时候用。';

  @override
  String get viewSuggestWorkspaceHint => '列出文件和项目';

  @override
  String get viewSuggestWordCountHint => '统计词频并跑一次';

  @override
  String get viewSuggestNodeHint => 'Node.js 带测试';

  @override
  String get viewSuggestGitHint => 'rebase 和 merge';

  @override
  String get viewTipNext => '下一条小技巧';

  @override
  String viewTipLabel(String value) {
    return '小技巧：$value';
  }

  @override
  String get viewTipSteer => '生成中长按发送键，可以插话、排队或打断';

  @override
  String get viewTipMidRun => 'AI 干活时也能发消息，它下一步就会看到';

  @override
  String get viewTipSlash => '输入 / 唤出指令：压缩上下文、切换模型等';

  @override
  String get viewTipMention => '输入 @ 可以引用工作区里的文件或别的对话';

  @override
  String get viewTipReplyMenu => '长按 AI 的回复，可以复制、引用或重新生成';

  @override
  String get viewTipEditResend => '长按自己的消息，可以改写后重发，原对话不动';

  @override
  String get viewTipQuote => '选中回复里的一段，点「引用」就只追问那一段';

  @override
  String get viewTipTitleDetails => '点顶部的对话标题，能看改动、文件和终端';

  @override
  String get viewTipContextRing => '发送键旁的小圆环是上下文用量，点开看详情';

  @override
  String get viewTipDrawerMenu => '长按侧栏里的对话，可以置顶、改名或归档';

  @override
  String get viewTipSearch => '主机支持时，搜索对话还能搜到聊天内容，不只是标题';

  @override
  String get viewTipSettingsSearch => '长按侧栏的设置键，可以直接搜索设置项';

  @override
  String get viewTipQuickPanel => '在对话页向左滑，打开快捷入口';

  @override
  String get viewTipFolderNewChat => '长按侧栏的文件夹，可以直接在里面开新对话';

  @override
  String get viewTipSwitchHost => '点侧栏底部的主机名，可以切到电脑上的 DSH';

  @override
  String get viewTipPasteImage => '输入法里的截图和贴图，可以直接贴进输入框';

  @override
  String get viewTipLauncher => '长按桌面图标，可以直接语音提问或开新对话';

  @override
  String get viewTipPetBubble => '宠物冒泡时点一下，就跳到等你的那个对话';

  @override
  String get viewTipPetPlay => '连点宠物三下会挠痒痒，长按可以换宠物';

  @override
  String get viewTipActivityStrip => '生成时点一下状态条，看这一轮的完整轨迹';

  @override
  String get viewTipImageZoom => '看图时双击放大、双指缩放，长按可以保存';

  @override
  String get viewTipQueuedRecall => '排队中的消息可以撤回到输入框再改';

  @override
  String get viewTipKeyboard => '接了键盘：Ctrl+Enter 发送，连按两次 Esc 停止';

  @override
  String get viewTipShareIn => '在别的 App 里分享文字或图片给 DSH Go，会填进新对话';

  @override
  String get viewTipShareSelect => '分享对话时长按再滑动，可以一次选中多条消息';

  @override
  String get viewTipChartDrag => '回复里的图表可以左右拖动，看每个点的数值';

  @override
  String get viewTipCopyPath => '改动卡里长按某个文件，可以复制它的路径';

  @override
  String get viewTipCompanion => '「伙伴小屋」藏在切换主机的面板里';

  @override
  String get viewTipAnswerInline => 'AI 向你提问时，直接在输入框里打字就是回答';

  @override
  String get viewTipWallpaper => '壁纸可以拖动、缩放，还能调模糊和明暗';

  @override
  String get viewTipModelHere => '这里就能换模型、预设和权限，只对这次对话生效';

  @override
  String get viewNewChatFolder => '文件夹';

  @override
  String get viewNewChatPresetTitle => '这次对话的预设';

  @override
  String get viewNewChatPermissionTitle => '这次对话的权限';

  @override
  String get viewNewChatDefault => '默认';

  @override
  String get viewNewChatUnavailable => '不可用';

  @override
  String get viewNewChatChange => '更改';

  @override
  String get viewNewChatModesFailed => '没能设置预设或权限，消息还没发出';

  @override
  String get viewGreetingMorning => '早上好';

  @override
  String get viewGreetingNoon => '中午好';

  @override
  String get viewGreetingAfternoon => '下午好';

  @override
  String get viewGreetingEvening => '晚上好';

  @override
  String get viewGreetingNight => '夜深了';

  @override
  String get viewEmptySubtitle => '今天想做点什么？';

  @override
  String get viewEmptyStarting => '正在启动引擎…';

  @override
  String get viewEmptyConnecting => '正在连接引擎…';

  @override
  String get viewEmptyDisconnected => '引擎未连接';

  @override
  String get viewEmptyReconnect => '重新连接';

  @override
  String viewEmptyWorkspace(String value) {
    return '在「$value」中';
  }

  @override
  String get viewEmptySwitchWorkspace => '切换工作区';

  @override
  String get viewEmptyHostDefaultDirectory => '主机默认目录';

  @override
  String get viewScheduleTitle => '自动化任务';

  @override
  String get viewScheduleRefreshFailed => '没能刷新';

  @override
  String get viewScheduleNone => '没有进行中的任务';

  @override
  String viewScheduleNext(String value) {
    return '下次 $value';
  }

  @override
  String get viewScheduleUntitled => '未命名任务';

  @override
  String get viewScheduleSendFailed => '没能发送';

  @override
  String get viewScheduleEnded => '已结束';

  @override
  String get viewScheduleUpcoming => '接下来';

  @override
  String get viewScheduleSending => '发送中…';

  @override
  String get viewScheduleRunNow => '立即运行';

  @override
  String get viewScheduleManage => '管理';

  @override
  String viewScheduleToday(String value) {
    return '今天 $value';
  }

  @override
  String viewScheduleTomorrow(String value) {
    return '明天 $value';
  }

  @override
  String viewScheduleYesterday(String value) {
    return '昨天 $value';
  }

  @override
  String viewScheduleWeekday(String first, String second) {
    return '周$first $second';
  }

  @override
  String get viewScheduleDue => '即将运行';

  @override
  String viewScheduleDaysAhead(int count) {
    return '$count 天后';
  }

  @override
  String viewScheduleDaysOverdue(int count) {
    return '已逾期 $count 天';
  }

  @override
  String viewScheduleSingleLabel(String title) {
    return '自动化任务：$title';
  }

  @override
  String viewScheduleCountLabel(int count) {
    return '$count 个自动化任务';
  }

  @override
  String get viewModelSelect => '选择模型';

  @override
  String get viewModelThinkingOff => '不思考';

  @override
  String get viewModelThinkingMinimal => '极少';

  @override
  String get viewModelThinkingLow => '低';

  @override
  String get viewModelThinkingMedium => '中';

  @override
  String get viewModelThinkingHigh => '高';

  @override
  String get viewModelThinkingMax => '最高';

  @override
  String viewModelLabel(String value) {
    return '模型：$value';
  }

  @override
  String viewModelEffortLabel(String value) {
    return '思考深度$value';
  }

  @override
  String get viewModelLoadFailed => '模型列表加载失败';

  @override
  String get viewModelDisconnected => '未连接引擎';

  @override
  String get viewModelConnectHint => '连接后即可选择模型';

  @override
  String get viewModelEffort => '思考深度';

  @override
  String get viewModelKeyRequired => '需要 API Key';

  @override
  String get viewModelProvidersHint => '支持 DeepSeek 和其他模型渠道';

  @override
  String get viewModelEnterKey => '填写 API Key';

  @override
  String get viewModelAddProvider => '添加其他渠道';

  @override
  String get viewModelNone => '暂无可用模型';

  @override
  String get viewModelKeyHint => 'Key 可能尚未生效或已失效';

  @override
  String get viewModelManageProviders => '管理渠道';

  @override
  String get viewContinuePrompt => '接着附件里这段对话聊：';

  @override
  String viewContinueRange(int first, int second, int third) {
    return '第 $first–$second 轮，共 $third 轮';
  }

  @override
  String viewContinueHeader(String value) {
    return '> 分享的 DSH Go 对话 · $value\n';
  }

  @override
  String get viewContinueUser => '\n## 用户\n\n';

  @override
  String viewImageCount(int count) {
    return '$count 张图片';
  }

  @override
  String viewContinueAttachments(String value) {
    return '\n（附件：$value）\n';
  }

  @override
  String get viewContinueAssistant => '\n## 助手\n\n';

  @override
  String get viewContinueInterrupted => '\n（回复被中断）\n';

  @override
  String get viewContinueFailed => '（失败）';

  @override
  String get viewContinueDeclined => '（被拒绝）';

  @override
  String get viewContinueCancelled => '（已取消）';

  @override
  String get viewLinkWeek => '7 天';

  @override
  String get viewLinkMonth => '30 天';

  @override
  String get viewLinkForever => '永久';

  @override
  String get viewShareChat => '对话';

  @override
  String get viewShareNoPermission => '没有存储权限，没能保存';

  @override
  String get viewShareOpenFailed => '没能打开分享';

  @override
  String get viewShareLinkFailed => '没能生成链接，稍后再试';

  @override
  String viewShareLinkText(String first, String second) {
    return '「$first」· DSH Go 对话\n$second';
  }

  @override
  String get viewShareEmpty => '这个对话还没有内容';

  @override
  String viewShareMessageCount(int count) {
    return '$count 条消息';
  }

  @override
  String viewShareToolCount(int count) {
    return '$count 次工具调用';
  }

  @override
  String get viewShareFileHint => '在 DSH Go 里回放、接着聊';

  @override
  String get viewShareWebHint => '任何浏览器都能打开，不用联网';

  @override
  String get viewShareMarkdownHint => '纯文本，随处可读';

  @override
  String get viewShareLinkHint => '端到端加密，服务器看不到内容';

  @override
  String get viewSharePreview => '预览';

  @override
  String get viewShareWhole => '整段对话';

  @override
  String get viewShareScopeReply => '这条回复';

  @override
  String get viewShareScopePicked => '选中消息';

  @override
  String get viewShareThinking => '思考过程';

  @override
  String get viewShareIncludeTools => '工具调用';

  @override
  String get viewShareChatFile => '对话文件';

  @override
  String get viewShareWebPage => '网页';

  @override
  String get viewShareLink => '链接';

  @override
  String get viewShareAsImage => '图片';

  @override
  String get viewShareAsFile => '文件';

  @override
  String get viewShareAsText => '文字';

  @override
  String get viewShareRedacted => '密钥已隐藏';

  @override
  String get viewShareAdjust => '调整';

  @override
  String viewShareTooLarge(int value) {
    return '超过 $value MB，请缩小范围';
  }

  @override
  String get viewShareCreateLink => '生成链接';

  @override
  String get viewShareStop => '停止分享';

  @override
  String get viewShareStopTitle => '停止分享？';

  @override
  String get viewShareStopped => '已停止分享';

  @override
  String get viewQrCode => '二维码';

  @override
  String viewShareTurn(int value) {
    return '第 $value 轮';
  }

  @override
  String get viewReplayContinue => '接着聊';

  @override
  String viewReplayTurns(int first, int second) {
    return '第 $first–$second 轮';
  }

  @override
  String viewReplaySeconds(int count) {
    return '$count 秒';
  }

  @override
  String viewReplayMinutes(int count) {
    return '$count 分钟';
  }

  @override
  String get viewReplayFull => '全文';

  @override
  String get viewReplayPause => '暂停';

  @override
  String get viewReplayRestart => '重新播放';

  @override
  String get viewReplayPlay => '播放';

  @override
  String viewReplaySpeed(int value) {
    return '倍速 $value×';
  }

  @override
  String get viewTemplatePaper => '纸张';

  @override
  String get viewTemplateGlass => '玻璃';

  @override
  String get viewTemplateCard => '卡片';

  @override
  String get viewShareProjectQr => '项目主页二维码';

  @override
  String get viewShareBrandLine => '手机上的 DSH · 扫码获取';

  @override
  String get viewShareBrandLineNoQr => '手机上的 DSH';

  @override
  String viewShareSteps(int count) {
    return '$count 步';
  }

  @override
  String get viewShareWebSearch => '联网搜索';

  @override
  String get viewShareOpenPage => '打开网页';

  @override
  String get viewShareRunCommand => '运行命令';

  @override
  String get viewShareReadFile => '查看文件';

  @override
  String get viewShareEditFile => '修改文件';

  @override
  String get viewShareSubagent => '子代理';

  @override
  String get viewShareSkill => '使用技能';

  @override
  String get viewSharePresentFiles => '交付文件';

  @override
  String get viewShareWorkflow => '工作流';

  @override
  String get viewSharePlugin => '调用插件';

  @override
  String get viewShareStars => '星标';

  @override
  String viewSharePluginTitle(String value) {
    return 'DSH 插件「$value」';
  }

  @override
  String viewShareInstallCommand(String value) {
    return '安装：dsh plugin add $value';
  }

  @override
  String viewSharePhoneInstall(String value) {
    return '手机上一键安装：$value';
  }

  @override
  String get viewShareImages => '图片';

  @override
  String get viewSharePickMessages => '选择消息';

  @override
  String viewShareDoneCount(int count) {
    return '完成（$count）';
  }

  @override
  String get viewShareImageMarker => '〔图片〕';

  @override
  String viewShareImagesMarker(int count) {
    return '〔$count 张图片〕';
  }

  @override
  String get viewShareYou => '你';

  @override
  String get viewShareImageFailed => '没能生成图片，请重试';

  @override
  String get viewShareQuestion => '提问';

  @override
  String get viewShareModelSteps => '模型与过程';

  @override
  String get viewShareImagePreview => '分享图片预览';

  @override
  String get viewShareSaveImage => '保存图片';

  @override
  String viewScheduleHoursAhead(int count) {
    return '$count 小时后';
  }

  @override
  String viewScheduleHoursOverdue(int count) {
    return '已逾期 $count 小时';
  }

  @override
  String viewScheduleMinutesAhead(int count) {
    return '$count 分钟后';
  }

  @override
  String viewScheduleMinutesOverdue(int count) {
    return '已逾期 $count 分钟';
  }

  @override
  String viewScheduleSecondsAhead(int count) {
    return '$count 秒后';
  }

  @override
  String viewScheduleSecondsOverdue(int count) {
    return '已逾期 $count 秒';
  }

  @override
  String viewScheduleDate(String date, String clock) {
    return '$date $clock';
  }

  @override
  String viewScheduleYearDate(String year, String date, String clock) {
    return '$year年$date $clock';
  }

  @override
  String viewScheduleWeekdayName(String day) {
    String _temp0 = intl.Intl.selectLogic(day, {
      '1': '一',
      '2': '二',
      '3': '三',
      '4': '四',
      '5': '五',
      '6': '六',
      'other': '日',
    });
    return '$_temp0';
  }

  @override
  String viewReplayDate(String month, int day) {
    return '$month 月 $day 日';
  }

  @override
  String viewReplayHours(int count) {
    return '$count 小时';
  }

  @override
  String viewReplayHoursMinutes(int hours, int minutes) {
    return '$hours 小时 $minutes 分钟';
  }

  @override
  String viewUiHundredMillion(String value) {
    return '$value亿';
  }

  @override
  String viewUiTenThousand(String value) {
    return '$value万';
  }

  @override
  String viewUiMillion(String value) {
    return '${value}M';
  }

  @override
  String get viewListSeparator => '，';

  @override
  String get viewAttachmentSeparator => '、';

  @override
  String viewUiInvalidJsonOffset(String message, int offset) {
    return '不是合法的 JSON（$message，第 $offset 个字符附近）';
  }

  @override
  String get viewUiUnavailableChart => '图表无法显示';

  @override
  String get viewUiUnavailableMetric => '指标无法显示';

  @override
  String get viewUiUnavailableCompare => '对比无法显示';

  @override
  String get viewUiUnavailableSteps => '步骤无法显示';

  @override
  String get viewUiUnavailableCallout => '提示无法显示';

  @override
  String get viewUiUnavailableOptions => '选项无法显示';

  @override
  String get viewUiUnavailableConfirm => '确认无法显示';

  @override
  String get viewUiUnavailableText => '文字无法显示';

  @override
  String get viewUiUnavailableGroup => '这一组无法显示';

  @override
  String get viewUiUnavailablePart => '这部分无法显示';

  @override
  String viewScheduleSingleNextLabel(String title, String when) {
    return '自动化任务：$title，下次$when';
  }

  @override
  String viewScheduleCountNextLabel(int count, String when) {
    return '$count 个自动化任务，下次$when';
  }

  @override
  String get viewUiSkippedStepLabel => '应该是字符串，这步已跳过';

  @override
  String viewLabeledValue(String label, String value) {
    return '$label：$value';
  }

  @override
  String viewDescribedValue(String label, String description) {
    return '$label，$description';
  }

  @override
  String get viewSemicolonSeparator => '；';

  @override
  String viewChartSemantics(String kind, String data) {
    return '$kind。$data';
  }

  @override
  String viewMetricSemantics(String label, String value) {
    return '$label $value';
  }

  @override
  String viewMetricCaptionSemantics(String label, String value, String caption) {
    return '$label $value，$caption';
  }

  @override
  String viewScheduleZone(String rule, String city, String offset) {
    return '$rule（$city · $offset）';
  }

  @override
  String viewContinueNotice(String text) {
    return '\n（$text）\n';
  }

  @override
  String viewShareAltMarker(String alt) {
    return '〔$alt〕';
  }

  @override
  String get viewModelThinkingXhigh => '超高';

  @override
  String viewUiDialectWebOnly(String kind) {
    return '$kind · 在网页版查看';
  }

  @override
  String get viewUiDialectKindInteractive => '可交互内容';

  @override
  String get viewUiDialectKindChart => '图表';

  @override
  String get viewUiDialectKindDiagram => '示意图';

  @override
  String get viewUiDialectKindImage => '图片';

  @override
  String get viewUiDialectKindAudio => '音频';

  @override
  String get viewUiDialectKindVideo => '视频';

  @override
  String get viewUiDialectKindScene => '3D 场景';

  @override
  String get viewUiDialectKindFiles => '文件树';

  @override
  String get viewUiDialectKindMap => '地图';

  @override
  String get viewUiDialectKindOther => '这部分';

  @override
  String get viewUiDialectInvalid => '这块内容在网页版查看';

  @override
  String get viewUiDialectNote => '在网页版查看';

  @override
  String get voiceSettingsTitle => '语音';

  @override
  String get voiceModeAuto => '自动';

  @override
  String get voiceModeSystem => '系统';

  @override
  String get voiceModeEngine => '语音模型';

  @override
  String get voiceModeAutoHint => '有 DeepSeek 账号或 API Key 时用 DeepSeek，否则用语音模型或系统识别';

  @override
  String get voiceModeSystemHint => '使用手机设置中的识别服务';

  @override
  String get voiceModeEngineHint => '用引擎里的语音模型识别';

  @override
  String get voiceFallbackStarted => '已改用语音模型，请再说一次';

  @override
  String get voiceChooseSystem => '请在系统设置中选择语音识别服务';

  @override
  String get voiceConfigureEngine => '请先在语音设置里下载语音模型';

  @override
  String get voiceConfigureEither => '系统识别用不了，可以在语音设置里下载语音模型';

  @override
  String get voiceErrorNetworkTimeout => '语音识别连接超时，请检查网络';

  @override
  String get voiceErrorNetwork => '语音识别网络连接失败';

  @override
  String get voiceErrorAudio => '语音录音失败，请检查麦克风';

  @override
  String get voiceErrorServer => '系统识别服务出错，请稍后再试';

  @override
  String get voiceErrorClient => '无法启动系统识别，请检查语音服务';

  @override
  String get voiceErrorSpeechTimeout => '没有听到声音，请再说一次';

  @override
  String get voiceErrorNoMatch => '没有听清，再说一次';

  @override
  String get voiceErrorBusy => '系统识别正忙，请稍后再试';

  @override
  String get voiceErrorPermission => '需要麦克风权限才能语音输入';

  @override
  String get voiceErrorTooManyRequests => '语音识别请求太频繁，请稍后再试';

  @override
  String get voiceErrorDisconnected => '系统识别服务已断开';

  @override
  String get voiceErrorLanguageUnsupported => '系统识别不支持这种语言';

  @override
  String get voiceErrorLanguageUnavailable => '请先在语音服务中下载这种语言';

  @override
  String get voiceErrorSupportCheck => '语音服务不支持检查识别能力';

  @override
  String get voiceErrorDownloadEvents => '语音服务不支持查询模型下载进度';

  @override
  String voiceErrorUnknown(int code) {
    return '语音服务返回错误 $code，请更换识别服务';
  }

  @override
  String get voiceSettingsFailed => '没能读取语音设置，请重试';

  @override
  String get voiceModeSection => '识别方式';

  @override
  String get voiceModelSection => '语音模型';

  @override
  String get voiceModelFooter => '下载后在手机上识别中文、英文、粤语、日语和韩语，录音不出手机。';

  @override
  String get voiceModelWaiting => '引擎启动后可以下载';

  @override
  String get voiceModelUnsupported => '当前引擎不支持语音模型';

  @override
  String get voiceModelAbsent => '未下载';

  @override
  String get voiceModelDownloading => '下载中';

  @override
  String get voiceModelPreparing => '正在校验和加载';

  @override
  String get voiceModelReady => '已就绪';

  @override
  String get voiceModelFailed => '下载失败';

  @override
  String voiceModelBytes(String done, String total) {
    return '$done / $total';
  }

  @override
  String voiceModelReadyNote(String size) {
    return '已占用 $size，可以离线使用';
  }

  @override
  String voiceModelAbsentNote(String size) {
    return '下载约 $size';
  }

  @override
  String get voiceModelWaitingNote => '下载会在引擎启动后开始';

  @override
  String get voiceModelFailNetwork => '网络连接失败';

  @override
  String get voiceModelFailTimeout => '下载长时间没有进展';

  @override
  String get voiceModelFailCertificate => '安全连接失败，请检查手机时间';

  @override
  String get voiceModelFailServer => '下载源暂时不可用';

  @override
  String get voiceModelFailIntegrity => '文件校验没有通过';

  @override
  String voiceModelFailStorage(String size) {
    return '存储空间不足，还需要约 $size';
  }

  @override
  String get voiceModelFailEngine => '引擎没有响应';

  @override
  String get voiceModelFailUnknown => '下载没有完成';

  @override
  String get voiceModelDownload => '下载';

  @override
  String get voiceModelResume => '继续下载';

  @override
  String get voiceModelRedownload => '重新下载';

  @override
  String get voiceModelMeteredTitle => '用移动数据下载？';

  @override
  String voiceModelMeteredBody(String size) {
    return '语音模型约 $size，会使用移动数据流量。';
  }

  @override
  String get voiceModelDeleteTitle => '删除语音模型？';

  @override
  String get voiceModelDeleteBody => '删除后语音输入改用系统识别，需要时可以重新下载。';

  @override
  String get voiceModelDeleteFailed => '没能删除语音模型，请重试';

  @override
  String get voiceModelDeleteStopping => '下载还在停止，请稍后再删';

  @override
  String voiceModelStartedToast(String size) {
    return '语音模型开始下载 · 约 $size';
  }

  @override
  String voiceModelResumedToast(String size) {
    return '继续下载语音模型 · 还剩约 $size';
  }

  @override
  String get voiceModelReadyToast => '语音输入已就绪';

  @override
  String voiceModelFailedToast(String reason) {
    return '语音模型下载失败：$reason';
  }

  @override
  String voiceModelNoticeDownloading(int percent) {
    return '正在下载语音模型 $percent%';
  }

  @override
  String get voiceModelNoticePreparing => '正在校验语音模型';

  @override
  String get voiceModelNoticeFailed => '语音模型下载失败，打开 App 重试';

  @override
  String get voiceModeDeepseek => 'DeepSeek';

  @override
  String get voiceModeDeepseekHint => '用 DeepSeek 的语音识别，登录的账号或 API Key 付费';

  @override
  String get voiceModeCloud => '其他云端服务';

  @override
  String get voiceModeCloudHint => 'OpenAI 兼容的语音转写接口，例如 Whisper、硅基流动';

  @override
  String get voiceCloudSection => '云端识别服务';

  @override
  String get voiceCloudFooter => '录音会发给这个服务识别。Key 只存在这台手机上。';

  @override
  String get voiceCloudBaseHelper => '填到 /v1 为止，App 会请求 …/audio/transcriptions';

  @override
  String get voiceCloudModelHelper => '例如 whisper-1、FunAudioLLM/SenseVoiceSmall';

  @override
  String get voiceScribeReadFailed => '没能读取语音设置，请重试。';

  @override
  String get voiceScribeSavedReadFailed => '已保存，刷新后可查看最新设置。';

  @override
  String get voiceScribeSaveUnconfirmed => '没能确认保存，请刷新或重试。';

  @override
  String get voiceScribeTitle => '语音设置';

  @override
  String get voiceScribePolishPrompt => '润色提示词';

  @override
  String get voiceScribeLanguage => '识别语言';

  @override
  String get voiceScribeRefresh => '刷新';

  @override
  String get voiceScribeHostChanged => '连接已变化，请重新打开。';

  @override
  String get voiceScribeUnsupported => '当前连接暂不支持语音设置。';

  @override
  String get voiceScribePluginDefault => '默认';

  @override
  String get voiceScribeBuiltInPrompt => '内置提示词';

  @override
  String get voiceScribeProviders => '识别服务';

  @override
  String get voiceScribeKeySet => '已设置密钥';

  @override
  String get voiceScribeNoKey => '未设置密钥';

  @override
  String get voiceScribeHotwords => '热词';

  @override
  String voiceScribeHotwordRules(int count) {
    return '$count 条规则';
  }

  @override
  String get wallpaperTitle => '壁纸';

  @override
  String get wallpaperDefault => '默认';

  @override
  String get wallpaperCustom => '自定义';

  @override
  String get wallpaperFrame => '调整位置';

  @override
  String get wallpaperBlur => '模糊';

  @override
  String get wallpaperLighten => '提亮';

  @override
  String get wallpaperDim => '压暗';

  @override
  String get wallpaperGuard => '自动保证文字清晰';

  @override
  String get wallpaperGuardHint => '关闭后完全按上面的滑块，调到 0 就是原图';

  @override
  String get wallpaperGuardMotionHint => '播放动图时只调文字颜色，画面不加遮罩';

  @override
  String get wallpaperPlay => '播放动图';

  @override
  String get wallpaperPlayHint => '减少动效时只显示第一帧';

  @override
  String get wallpaperReplace => '更换图片';

  @override
  String get wallpaperPreview => '预览';

  @override
  String get wallpaperFooter => '用于首页、对话和抽屉。提亮在浅色模式、压暗在深色模式下各自生效。PNG、JPEG、WebP、GIF，15 MB 以内';

  @override
  String get wallpaperChanged => '壁纸已更换';

  @override
  String get wallpaperTooLarge => '图片超过 15 MB';

  @override
  String get wallpaperUnsupported => '支持 PNG、JPEG 和 WebP';

  @override
  String get wallpaperUnreadable => '无法读取这张图片';

  @override
  String get wallpaperUnavailable => '无法打开相册';

  @override
  String get wallpaperBroken => '无法读取';

  @override
  String get wallpaperEditorHint => '拖动、双指缩放';

  @override
  String get wallpaperEditorReset => '复原';

  @override
  String get wallpaperSampleTitle => '周末去海边';

  @override
  String get wallpaperSampleStatus => '刚刚';

  @override
  String get wallpaperSampleQuestion => '这周六适合去海边吗？';

  @override
  String get wallpaperSampleAnswer => '适合。周六午后晴，风力 2 级，浪高不到半米，是这周最好的一天。';

  @override
  String get wallpaperSampleNote => '傍晚降温明显，带一件薄外套。';

  @override
  String get wallpaperSampleTool => '查了 3 个天气来源';

  @override
  String get searchKwWallpaper => '背景,背景图,聊天背景,自定义背景,换背景,模糊,壁纸图片,动图,动态壁纸,GIF';

  @override
  String get webTitle => 'DSH 网页版';

  @override
  String get webSshAppOnly => '经 SSH 隧道的地址只能在 App 内打开';

  @override
  String get webRelayUnavailable => '经 DSH Remote 中转时打不开网页版，请在那台电脑上打开';

  @override
  String get webSshHost => 'SSH 主机';

  @override
  String get webLocalAppOnly => '本机地址带启动令牌，只能在 App 内打开';

  @override
  String get webEngineStatus => '引擎状态';

  @override
  String get webEngineStarting => '正在启动引擎';

  @override
  String get webEngineStartFailed => '引擎没能启动';

  @override
  String get webEngineNotRunning => '引擎没有运行';

  @override
  String get webEngineProblem => '引擎遇到了问题';

  @override
  String get webStartingSoon => '稍等片刻，网页版马上就好';

  @override
  String get webStartToOpen => '网页版由本机引擎提供，启动后就能打开';

  @override
  String get webRestart => '重新启动';

  @override
  String get webStartEngine => '启动引擎';

  @override
  String get webSwitchToWeb => '切换到网页界面';

  @override
  String get webNativeFeatures => '原生功能';

  @override
  String get webSwitchToNative => '切回原生界面';

  @override
  String get webAppSettings => 'App 设置';

  @override
  String get webSwitchHost => '切换主机';

  @override
  String get webAttachmentTooLarge => '附件太大，没能带进网页版';

  @override
  String get webTextCopied => '文字已复制，粘贴到输入框即可';

  @override
  String get webAttachmentFailed => '附件没能带进网页版';

  @override
  String get webHostUnavailable => '这台主机打不开网页版';

  @override
  String get webChatGone => '这个对话已不在了';

  @override
  String get webPageClosed => '网页已关闭';

  @override
  String get webChatsWorkspaces => '对话与工作区';

  @override
  String get webRefresh => '刷新';

  @override
  String get webOpenInBrowser => '在浏览器打开';

  @override
  String get webBrowserUnavailable => '不能在浏览器打开';

  @override
  String get webReopen => '重新打开';

  @override
  String get webPageNotOpened => '页面没有打开';

  @override
  String get webCheckConnection => '检查网络或引擎状态后再试';

  @override
  String get webTargetSessionMissing => '网页版里没找到这个对话，已停在首页';

  @override
  String get webTargetNotLoaded => '网页版没有加载完成';

  @override
  String get webTargetSettingsMissing => '没找到这页设置，可能需要先登录或开启对应插件';

  @override
  String get webTargetPluginMissing => '没找到这个插件，可能当前配置里没有它';

  @override
  String get webTargetSidebarFailed => '没能打开侧边栏，先在网页版里打开这个对话再试';

  @override
  String get webTargetCordisMissing => '没找到 Cordis 面板，插件可能已经移除';

  @override
  String get webTargetNewChatFailed => '没能新建对话，已停在网页版首页';

  @override
  String get webTargetPageFailed => '没能直接打开这一页，已停在网页版首页';

  @override
  String webConnectHostFirst(String name) {
    return '还没连上「$name」，连上后再打开网页版';
  }

  @override
  String get workshopTitle => '创意工坊';

  @override
  String get workshopSubtitle => '大家做的宠物和伙伴，挑喜欢的装上';

  @override
  String get workshopEntrySubtitle => '找别人做的宠物和伙伴';

  @override
  String get workshopTabBrowse => '发现';

  @override
  String get workshopTabMine => '我的投稿';

  @override
  String get workshopKindAll => '全部';

  @override
  String get workshopKindPet => '像素宠物';

  @override
  String get workshopKindCompanion => '伙伴';

  @override
  String get workshopSearchHint => '搜索名称或作者';

  @override
  String get workshopGet => '获取';

  @override
  String get workshopRefresh => '刷新';

  @override
  String workshopByAuthor(String author) {
    return '$author 制作';
  }

  @override
  String get workshopEmptyTitle => '这里还空着';

  @override
  String get workshopEmptyMessage => '还没有人投稿。做了宠物或伙伴的话，可以第一个发上来。';

  @override
  String get workshopNoMatchTitle => '没有找到';

  @override
  String get workshopNoMatchMessage => '换个名字或作者再试试。';

  @override
  String get workshopUnavailableTitle => '暂时打不开工坊';

  @override
  String get workshopNotOpenTitle => '工坊还没有开放';

  @override
  String get workshopNotOpenMessage => '这个版本还没有接入工坊服务。';

  @override
  String workshopShowingOlder(String when) {
    return '没能刷新，显示的是 $when 取到的内容。';
  }

  @override
  String get workshopLocalUnknown => '读不出本机已装了哪些，「已安装」的标记可能不准。';

  @override
  String get workshopStatVersion => '版本';

  @override
  String get workshopStatSize => '大小';

  @override
  String get workshopStatLicense => '许可';

  @override
  String get workshopAbout => '简介';

  @override
  String get workshopNoDescription => '作者没有写简介。';

  @override
  String get workshopSource => '来源';

  @override
  String workshopMinApp(String version) {
    return '需要 DSH Go $version 或更新的版本。';
  }

  @override
  String workshopInstalledVersion(String version) {
    return '已安装 $version';
  }

  @override
  String workshopUpdateTo(String version) {
    return '更新到 $version';
  }

  @override
  String get workshopInstalledWithdrawn => '你装的这个版本已经被撤回。它还能用；有新版本就更新，没有的话建议卸载。';

  @override
  String get workshopPhasePreparing => '正在准备…';

  @override
  String get workshopPhaseDownloading => '正在下载';

  @override
  String get workshopPhaseVerifying => '正在校验…';

  @override
  String get workshopPhaseCancelling => '正在取消…';

  @override
  String workshopProgressBytes(String received, String total) {
    return '$received / $total';
  }

  @override
  String get workshopInstallDone => '装好了';

  @override
  String get workshopInstallDonePet => '装好了，到宠物页就能换上它。';

  @override
  String get workshopInstallDoneCompanion => '装好了，到伙伴小屋就能见到她。';

  @override
  String get workshopInstallDoneRefreshIssue => '装好了，但列表没能刷新，重新进来就能看到。';

  @override
  String get workshopInstallCancelled => '已取消，没有改动本机的内容。';

  @override
  String get workshopInstallBusy => '上一个安装或卸载还没结束，等它完成再试。';

  @override
  String get workshopReplaceTitle => '覆盖本机已有的？';

  @override
  String workshopReplaceMessage(String title) {
    return '本机已经有一个同名的资源，不是从工坊这一条装的。继续会用「$title」替换它，替换后找不回来。';
  }

  @override
  String get workshopReplaceConfirm => '覆盖';

  @override
  String get workshopReport => '举报';

  @override
  String get workshopErrorNetwork => '网络不通，稍后再试。';

  @override
  String get workshopErrorTimeout => '等得太久没有回应，稍后再试。';

  @override
  String get workshopErrorServer => '工坊服务暂时出了问题，稍后再试。';

  @override
  String get workshopErrorRateLimited => '操作太频繁了，过一会儿再试。';

  @override
  String get workshopErrorBadData => '工坊返回的内容不对，没有采用。稍后再试。';

  @override
  String get workshopErrorCatalogChanged => '这个作品刚刚有变化，请刷新后再看。';

  @override
  String get workshopErrorNotFound => '找不到这个作品了，可能已经下架。';

  @override
  String get workshopErrorWithdrawn => '这个版本已经被撤回，不能安装。';

  @override
  String get workshopErrorMinApp => 'App 版本太旧，更新后才能安装。';

  @override
  String get workshopErrorUnsupported => '这个版本的 App 还不认识这类作品。';

  @override
  String get workshopErrorCompanionOff => '伙伴类作品暂时关闭了。';

  @override
  String get workshopErrorUploadOff => '工坊暂时不接收投稿。';

  @override
  String get workshopErrorNoSpace => '手机空间不够，腾出一些再试。';

  @override
  String get workshopErrorStorage => '没能读写手机上的文件。';

  @override
  String get workshopErrorIntegrity => '下载的内容和登记的不一致，已丢弃。请重试。';

  @override
  String get workshopErrorDowngrade => '本机装的版本更新，不会换成旧的。';

  @override
  String get workshopErrorRuntimeMissing => '要先在伙伴小屋里请过一位角色，才能装别的伙伴。';

  @override
  String get workshopErrorReadersBusy => '她正在用着，先离开伙伴小屋或关掉悬浮窗再试。';

  @override
  String get workshopErrorInstallRecord => '本机的安装记录对不上，没有动它。';

  @override
  String get workshopErrorOtherOrigin => '这是从别的工坊装的。';

  @override
  String get workshopErrorSignIn => '需要先登录 GitHub 账号。';

  @override
  String get workshopErrorConsent => '需要先同意把登录凭据交给工坊核对身份。';

  @override
  String get workshopErrorAccountMismatch => '登录的账号来源和工坊认的不一致，请重新登录。';

  @override
  String get workshopErrorAccountDown => '暂时没能向 GitHub 核对身份，稍后再试。';

  @override
  String get workshopErrorPreferences => '没能保存本机的记录，这一步没有继续。';

  @override
  String get workshopErrorBusy => '上一步还没结束，稍等。';

  @override
  String get workshopErrorCancelled => '已取消。';

  @override
  String get workshopErrorUnknownResult => '不确定有没有成功。先刷新看看，别急着重试。';

  @override
  String get workshopErrorGeneric => '没有成功，稍后再试。';

  @override
  String workshopErrorWithCode(String code) {
    return '没有成功，稍后再试。（$code）';
  }

  @override
  String workshopErrorPackage(String code) {
    return '包里有文件不符合要求，没法上传（$code）。';
  }

  @override
  String get workshopDisclosureTitle => '让工坊核对你的 GitHub 身份';

  @override
  String get workshopDisclosureLead => '投稿、管理自己的投稿和举报，工坊都要先知道你是谁。办法是把你的 GitHub 登录凭据发给下面这个工坊服务，由它去问 GitHub 你是哪个账号。';

  @override
  String get workshopDisclosureWorker => '收到凭据的工坊';

  @override
  String get workshopDisclosureAccount => '核对身份的账号服务';

  @override
  String get workshopDisclosureUse => '投稿、查看或撤回自己的投稿、举报时都会带上它。工坊只拿它向 GitHub 确认身份，不保存。';

  @override
  String get workshopDisclosureKept => '凭据只存在这台手机上，本机另外记下你同意过这两个地址；换了其中一个会再问。';

  @override
  String get workshopDisclosureStale => '地址刚刚有变化，请按现在显示的重新确认。';

  @override
  String get workshopDisclosureAccept => '同意并继续';

  @override
  String get workshopDisclosureDecline => '暂不';

  @override
  String get workshopDisclosureUnsaved => '这次同意已经生效，但没能记在本机，下次可能再问一遍。';

  @override
  String get workshopSignInTitle => '用 GitHub 登录';

  @override
  String get workshopSignInLead => '工坊用 GitHub 账号认人。这次授权只能读你的公开资料（用户名和账号编号），不能动你的仓库。';

  @override
  String get workshopSignInPreparing => '正在向 GitHub 要验证码…';

  @override
  String get workshopSignInSteps => '在 GitHub 验证页输入验证码并授权，再回到这里。';

  @override
  String get workshopSignInOpen => '复制并打开 GitHub';

  @override
  String get workshopSignInCopied => '验证码已复制';

  @override
  String get workshopSignInWaiting => '等你在 GitHub 上授权…';

  @override
  String get workshopSignInExpired => '验证码过期了。';

  @override
  String get workshopSignInDenied => '你在 GitHub 上取消了授权。';

  @override
  String get workshopSignInNetwork => '连不上 GitHub，检查网络后再试。';

  @override
  String get workshopSignInUnconfigured => '这个工坊还没开通 GitHub 登录。';

  @override
  String get workshopSignInAgain => '重新获取验证码';

  @override
  String workshopAccountLine(String login) {
    return 'GitHub 账号 $login';
  }

  @override
  String get workshopAccountSignOut => '退出登录';

  @override
  String get workshopAccountSignedOut => '已退出。要彻底收回授权，去 GitHub 设置里的 Applications 页撤销。';

  @override
  String get workshopAccountSignOutFailed => '没能退出，稍后再试。';

  @override
  String get workshopInstalledEmptyTitle => '还没有从工坊装过东西';

  @override
  String get workshopInstalledEmptyMessage => '在「发现」里装上的宠物和伙伴会列在这里。';

  @override
  String get workshopInstalledEmptyAction => '去发现';

  @override
  String get workshopInstalledLoadFailedTitle => '读不出已安装的内容';

  @override
  String get workshopInstalledLoadStale => '没能重新读取，显示的是上一次的。';

  @override
  String get workshopInstalledCatalogStale => '更新和撤回的信息可能不是最新的。';

  @override
  String get workshopInstalledCatalogUnknown => '暂时查不到更新和撤回的信息。';

  @override
  String get workshopInstalledStatusUpdate => '有更新';

  @override
  String get workshopInstalledStatusWithdrawn => '这个版本已被撤回';

  @override
  String get workshopInstalledStatusOtherOrigin => '来自别的工坊';

  @override
  String get workshopInstalledStatusNotListed => '工坊里现在找不到它';

  @override
  String get workshopInstalledStatusCompanionOff => '伙伴类作品暂时关闭';

  @override
  String get workshopInstalledStatusRewritten => '和工坊里的同一版本不一致';

  @override
  String get workshopInstalledStatusRemoving => '正在卸载…';

  @override
  String get workshopInstalledStatusRemoveFailed => '没能卸载';

  @override
  String get workshopInstalledStatusRemoved => '已卸载';

  @override
  String get workshopInstalledIssueBroken => '这个包损坏了';

  @override
  String get workshopInstalledIssueUnreadable => '读不出这个包';

  @override
  String get workshopInstalledIssueRecord => '安装记录对不上';

  @override
  String get workshopInstalledIssueOther => '这一项有问题';

  @override
  String get workshopInstalledNoteBroken => '这个包损坏了，可能用不了。';

  @override
  String get workshopInstalledNoteUnreadable => '没能读出这个包的文件。';

  @override
  String get workshopInstalledNoteRecord => '它的安装记录对不上。';

  @override
  String get workshopInstalledNoteOther => '这一项有问题，读不出更多信息。';

  @override
  String get workshopInstalledNoteUntrusted => '安装记录不可信，没法从这里卸载它。';

  @override
  String get workshopInstalledNoteOtherOrigin => '这是从别的工坊装的，这里查不到它的更新。';

  @override
  String get workshopInstalledNoteNotListed => '工坊里现在找不到它，本机的这一份不受影响。';

  @override
  String get workshopInstalledNoteRewritten => '工坊里同一版本的内容和本机的不一样，本机的这一份没有改动。';

  @override
  String get workshopInstalledNoteMinApp => '工坊里现在的版本需要更新 App 才能安装。';

  @override
  String get workshopInstalledNoteUnavailable => '工坊里现在的版本暂时不能安装。';

  @override
  String get workshopInstalledNoteGone => '这一项已经不在本机了。';

  @override
  String get workshopInstalledNoteUnread => '暂时读不到本机的安装记录，下面是刚才看到的状态。';

  @override
  String workshopInstalledRemoveFailed(String reason) {
    return '没能卸载。$reason';
  }

  @override
  String get workshopInstalledFactKind => '类型';

  @override
  String get workshopInstalledFactId => '作品 ID';

  @override
  String get workshopInstalledFactOrigin => '来自';

  @override
  String get workshopInstalledFactLocalId => '本机标识';

  @override
  String workshopInstalledRemoveTitle(String title) {
    return '卸载「$title」？';
  }

  @override
  String get workshopInstalledRemoveMessage => '会删掉这台手机上的这一份。想再用，要回工坊重新获取。';

  @override
  String get workshopInstalledRemoveNoReinstall => '工坊里现在找不到它，卸载后可能装不回来。';

  @override
  String get workshopInstalledRemovedRefreshIssue => '已卸载，但列表没能刷新，下拉刷新一下。';

  @override
  String get workshopInstalledRemovedLocalIssue => '已卸载，但有些地方没能跟着更新，重新打开 App 就好。';

  @override
  String get workshopInstalledDismissFailure => '知道了';

  @override
  String get workshopMinePublish => '投稿';

  @override
  String get workshopMinePublishHint => '审核通过后出现在「发现」里';

  @override
  String get workshopMineSignInTitle => '投稿记在 GitHub 账号上';

  @override
  String get workshopMineSignInMessage => '登录后就能看到自己发过的作品。';

  @override
  String get workshopMineConsentTitle => '还差一步确认';

  @override
  String get workshopMineConsentMessage => '工坊要用你的 GitHub 登录凭据核对身份，同意后才能看到自己的投稿。';

  @override
  String get workshopMineConsentAction => '查看说明';

  @override
  String get workshopMineEmptyTitle => '还没有投稿';

  @override
  String get workshopMineEmptyMessage => '做了宠物或伙伴的话，可以发上来给大家用。';

  @override
  String get workshopMineEmptyFiltered => '没有这类投稿';

  @override
  String get workshopMineLoadFailed => '没能读到投稿';

  @override
  String get workshopMineStale => '没读到最新内容，下面是之前读到的。';

  @override
  String get workshopMineLoadMore => '加载更多';

  @override
  String get workshopMineStatusPending => '待审核';

  @override
  String get workshopMineStatusApproved => '已通过';

  @override
  String get workshopMineStatusRejected => '已拒绝';

  @override
  String get workshopMineStatusWithdrawn => '已撤回';

  @override
  String get workshopMineStatusDraft => '草稿';

  @override
  String get workshopMineDetailTitle => '投稿详情';

  @override
  String get workshopMineRefreshOne => '刷新这一条';

  @override
  String get workshopMineAboutPending => '已经提交，正在等审核。通过后会出现在「发现」里。';

  @override
  String get workshopMineAboutApproved => '审核通过了。现在是否公开，以「发现」里看到的为准。';

  @override
  String get workshopMineAboutRejected => '没有通过审核。';

  @override
  String get workshopMineAboutWithdrawn => '已经撤回，不能恢复。';

  @override
  String get workshopMineAboutDraft => '文件还没有传完，不会进入审核。';

  @override
  String get workshopMineReviewReason => '审核意见';

  @override
  String get workshopMineWithdrawReason => '撤回原因';

  @override
  String get workshopMineWithdrawReasonHint => '比如传错了文件、想改了再发';

  @override
  String get workshopMineCreatedAt => '提交时间';

  @override
  String get workshopMineUpdatedAt => '最近更新';

  @override
  String get workshopMineDetailStale => '这一条没能刷新，显示的是之前读到的状态。';

  @override
  String get workshopMineAccountChanged => '账号已经换了';

  @override
  String get workshopMineAccountChangedMessage => '这条投稿属于之前的账号，不再显示。';

  @override
  String get workshopMineWithdraw => '撤回投稿';

  @override
  String get workshopMineWithdrawConfirmTitle => '撤回这条投稿？';

  @override
  String workshopMineWithdrawConfirmMessage(String title) {
    return '撤回后不能恢复。如果「$title」已经公开，所有人都不能再下载这个版本，同一个版本号也不能重新发布。';
  }

  @override
  String get workshopMineWithdrawConfirm => '撤回';

  @override
  String get workshopMineWithdrawing => '正在撤回…';

  @override
  String get workshopMineWithdrawDone => '这条投稿已撤回';

  @override
  String get workshopMineWithdrawUnknown => '不确定有没有撤回成功。先查询结果，不要重复撤回。';

  @override
  String get workshopMineWithdrawQuery => '查询结果';

  @override
  String get workshopMineWithdrawStill => '查到它还没有撤回。需要的话可以再撤回一次。';

  @override
  String get workshopMineWithdrawReconciled => '查到它现在已经是撤回状态。';

  @override
  String get workshopMineReasonEmpty => '先写下原因。';

  @override
  String workshopMineReasonTooLong(String max) {
    return '最多 $max 字，现在超了。';
  }

  @override
  String get workshopMineReasonBadChars => '里面有不能用的字符，删掉后再试。';

  @override
  String get workshopMineReasonRejected => '这段原因没有被接受，改一下再试。';

  @override
  String workshopReportTarget(String title, String version) {
    return '$title · $version';
  }

  @override
  String get workshopReportReason => '举报原因';

  @override
  String get workshopReportReasonHint => '它有什么问题，比如侵权、内容不合适';

  @override
  String get workshopReportNote => '审核员会查看这条举报。作品不会因为举报自动下架。';

  @override
  String get workshopReportSubmit => '提交举报';

  @override
  String get workshopReportSending => '正在提交…';

  @override
  String get workshopReportDone => '举报已送达，审核员会查看。';

  @override
  String get workshopReportSignInTitle => '举报需要 GitHub 账号';

  @override
  String get workshopReportSignInMessage => '登录后才能提交举报。';

  @override
  String get workshopReportConsentMessage => '工坊要用你的 GitHub 登录凭据核对身份，同意后才能举报。';

  @override
  String get workshopReportUnknownTitle => '不确定有没有送达';

  @override
  String get workshopReportUnknownMessage => '上一次举报可能已经收到，也可能没有，现在查不到结果。再发一次可能变成重复举报。';

  @override
  String workshopReportUnknownOther(String id, String version) {
    return '那一次举报的是 $id $version。';
  }

  @override
  String get workshopReportUnknownAgain => '知道可能重复，重新填写';

  @override
  String get workshopPublishTitle => '投稿';

  @override
  String get workshopPublishClosedTitle => '工坊暂时不接收投稿';

  @override
  String get workshopPublishClosedMessage => '已经交上去的仍然可以在「我的投稿」里看。';

  @override
  String get workshopPublishSignInTitle => '先登录 GitHub 账号';

  @override
  String get workshopPublishSignInMessage => '工坊靠 GitHub 账号确认投稿的人是谁。';

  @override
  String get workshopPublishProfileTitle => '还没读到 GitHub 账号资料';

  @override
  String get workshopPublishProfileMessage => '要先知道你是哪个账号，才能投稿。';

  @override
  String get workshopPublishCheckFailedTitle => '没能读出上一次投稿的记录';

  @override
  String get workshopPublishCheckLocked => '为了不重复投稿，读出来之前不能开始新的。';

  @override
  String get workshopPublishWaitingPrevious => '上一个操作还没结束，稍等。';

  @override
  String get workshopPublishChooseTitle => '选一个要投稿的';

  @override
  String get workshopPublishCompanionCurrent => '现在的伙伴';

  @override
  String get workshopPublishSourcesEmptyTitle => '还没有可以投稿的';

  @override
  String get workshopPublishSourcesEmptyMessage => '自己导入的像素宠物和现在的伙伴可以投稿，也可以直接从文件选一个。';

  @override
  String get workshopPublishFromFile => '从文件选择';

  @override
  String get workshopPublishFromFileHint => '宠物或伙伴的 zip，不用先导入';

  @override
  String get workshopPublishTitleEnHelper => '选填，留空就用中文名称';

  @override
  String get workshopPublishAuthorHelper => '选填，留空就用你的 GitHub 用户名';

  @override
  String get workshopPublishLicenseHelper => '选填，不选就是「作者授权」';

  @override
  String get workshopPublishSourcesIssue => '没能读出本机可以投稿的内容。';

  @override
  String get workshopPublishPetsIssue => '没能读出本机的像素宠物。';

  @override
  String get workshopPublishCompanionIssue => '没能读出本机的伙伴。';

  @override
  String get workshopPublishNoCompanion => '本机还没有伙伴，先到伙伴小屋请一位。';

  @override
  String get workshopPublishSectionSource => '投稿内容';

  @override
  String get workshopPublishChange => '更换';

  @override
  String get workshopPublishSectionNames => '名称';

  @override
  String get workshopPublishTitleZh => '中文名称';

  @override
  String get workshopPublishTitleEn => '英文名称';

  @override
  String get workshopPublishSectionInfo => '作品信息';

  @override
  String get workshopPublishId => '作品 ID';

  @override
  String get workshopPublishIdHelper => '选填，留空按名称自动生成；小写字母、数字和短横线';

  @override
  String get workshopPublishAuthor => '作者';

  @override
  String get workshopPublishLicenseAuthor => '作者授权';

  @override
  String get workshopPublishSourceLink => '来源链接';

  @override
  String get workshopPublishSourceHelper => '选填，留空就用你的 GitHub 主页；以 https:// 开头';

  @override
  String get workshopPublishSectionAbout => '介绍（选填）';

  @override
  String get workshopPublishTags => '标签';

  @override
  String get workshopPublishTagsHelper => '用逗号分开，最多 8 个';

  @override
  String get workshopPublishNext => '下一步';

  @override
  String get workshopPublishPreparing => '正在打包…';

  @override
  String get workshopPublishBadTitle => '名称不能为空，最多 120 个字';

  @override
  String get workshopPublishBadId => '只能用小写字母、数字和短横线，最多 40 个字符';

  @override
  String get workshopPublishBadVersion => '写成 1.0.0 这样的版本号';

  @override
  String get workshopPublishBadAuthor => '作者不能为空，最多 256 个字';

  @override
  String get workshopPublishBadLicense => '选一个许可';

  @override
  String get workshopPublishBadSource => '填一个以 https:// 开头的链接';

  @override
  String get workshopPublishBadDescription => '简介最多 512 个字';

  @override
  String get workshopPublishBadTags => '最多 8 个标签，每个不超过 32 个字，不能重复';

  @override
  String get workshopPublishBadRights => '先确认你有权分享这份内容';

  @override
  String get workshopPublishFiles => '包里的文件';

  @override
  String get workshopPublishEdit => '修改资料';

  @override
  String get workshopPublishRights => '我确认自己有权分享这份内容';

  @override
  String get workshopPublishReviewNote => '交上去后先由工坊审核，通过了大家才能看到。';

  @override
  String get workshopPublishSubmit => '投稿';

  @override
  String get workshopPublishPhaseWorking => '正在处理…';

  @override
  String get workshopPublishPhaseUploading => '正在上传';

  @override
  String get workshopPublishPhaseWaiting => '已经传完，等工坊确认…';

  @override
  String get workshopPublishStay => '离开这一页不会中断。';

  @override
  String get workshopPublishDoneTitle => '已交给工坊，等待审核';

  @override
  String get workshopPublishDoneMessage => '进度可以在「我的投稿」里看。';

  @override
  String get workshopPublishBackToMine => '回到我的投稿';

  @override
  String get workshopPublishApprovedTitle => '这份投稿已经通过审核';

  @override
  String get workshopPublishApprovedMessage => '有没有上架，以「发现」里看到的为准。';

  @override
  String get workshopPublishRejectedTitle => '这份投稿没有通过审核';

  @override
  String get workshopPublishWithdrawnTitle => '这份投稿已经撤回';

  @override
  String workshopPublishReason(String reason) {
    return '原因：$reason';
  }

  @override
  String get workshopPublishAgain => '重新投稿';

  @override
  String get workshopPublishAgainMessage => '改好以后可以重新投一次。';

  @override
  String get workshopPublishRecordKept => '结果已经确认，但本机的投稿记录没能清掉。';

  @override
  String get workshopPublishLeftovers => '本机留下的临时文件没能清掉。';

  @override
  String get workshopPublishPendingTitle => '有一份投稿还没结束';

  @override
  String get workshopPublishPendingMessage => '上次没有交完。继续会用同一份内容接着交，不会多出一份。';

  @override
  String get workshopPublishPendingLocked => '这份投稿的内容已经定下，暂时不能修改，也不能换成别的。问题解决后可以接着交。';

  @override
  String get workshopPublishPendingUnsent => '这次还没有发出去。问题解决后可以接着交，也可以回去修改资料或换一个来投。';

  @override
  String get workshopPublishEditUnsent => '回去修改';

  @override
  String get workshopPublishUnknownTitle => '不确定有没有交上去';

  @override
  String get workshopPublishUnknownMessage => '工坊没有回话，结果还不知道。查看结果会拿同一份投稿再问一次：已经交上的不会重复，没交完的接着交。';

  @override
  String get workshopPublishContinue => '继续投稿';

  @override
  String get workshopPublishCheckResult => '查看结果';

  @override
  String get workshopPublishCheckAgain => '重新查询';

  @override
  String get workshopPublishErrorInvalid => '有几项资料要改一下。';

  @override
  String get workshopPublishErrorMismatch => '打好的包和填写的资料对不上，请再试一次。';

  @override
  String get workshopPublishErrorPending => '还有一份投稿没有结束，先把它处理完。';

  @override
  String get workshopPublishErrorTooLarge => '包太大了，超过了工坊的上限。';

  @override
  String get workshopPublishErrorMetadata => '资料没有通过工坊的检查，改一改再试。';

  @override
  String get workshopPublishErrorNotReady => '还没准备好，稍等再试。';

  @override
  String get workshopPublishErrorAgain => '现在还不能重新投稿。';

  @override
  String get workshopPublishSectionPreview => '预览图';

  @override
  String get workshopPublishPreviewSwitch => '在工坊里显示预览图';

  @override
  String get workshopPublishPreviewIdle => '用待机动画的第一帧';

  @override
  String get workshopPublishSectionCover => '封面（选填）';

  @override
  String get workshopPublishCoverPick => '选一张封面';

  @override
  String get workshopPublishCoverHelper => '支持 JPEG、PNG、WebP 等，上传前自动缩小。不选就显示名字的第一个字。';

  @override
  String get workshopPublishCoverGenerating => '正在生成封面，也可以自己选。';

  @override
  String get workshopPublishCoverChosen => '投稿封面';

  @override
  String get workshopPublishCoverReplace => '换一张';

  @override
  String get workshopPublishCoverRemove => '移除';

  @override
  String get workshopPublishCoverBadSize => '图片为空或超过 32 MB，换一张试试。';

  @override
  String get workshopPublishCoverBadPng => '图片损坏或格式不支持，换一张试试。';

  @override
  String get workshopPublishCoverBadDimensions => '图片分辨率过高，缩小后再选。';

  @override
  String get workshopPublishCoverUnreadable => '没能读出这张图，换一张试试。';

  @override
  String get workshopPublishReviewPreviewIdle => '待机动画第一帧';

  @override
  String get workshopPublishReviewPreviewNone => '不带预览图';

  @override
  String get workshopPublishErrorPreviewPet => '这只宠物的画面超过 512 像素，做不了预览图。关掉预览图可以照常投稿。';

  @override
  String get workshopPublishErrorPreviewConflict => '伙伴的包里已经有一个 preview.png，封面放不进去。移除封面可以照常投稿。';

  @override
  String get workshopPublishErrorPreviewMissing => '没找到要用的预览图。重新选一次，或者去掉预览图再投稿。';

  @override
  String get workshopPublishErrorPreviewUnsupported => '这个工坊现在不收预览图。去掉预览图可以照常投稿。';

  @override
  String get workshopPublishLetGo => '放下这条记录';

  @override
  String get workshopPublishLetGoTitle => '放下本机的这条记录？';

  @override
  String workshopPublishLetGoAccount(String worker) {
    return '只删除这台手机上，这个 GitHub 账号在工坊 $worker 的这条未完成记录。';
  }

  @override
  String workshopPublishLetGoAll(String worker) {
    return '这台手机上的投稿记录整体读不出来了。放下会清掉本机所有账号的未完成投稿记录，不只是这个 GitHub 账号在工坊 $worker 的这一条。';
  }

  @override
  String get workshopPublishLetGoFacts => '工坊不会收到取消：它要是已经收到这份投稿，投稿还在那里，会出现在「我的投稿」。要是没收到，就得重新投稿；万一其实收到了，会多出一份。';

  @override
  String get workshopPublishLetGoFactsKnown => '工坊不会收到取消，那边的结果不变，这份投稿仍在「我的投稿」里。';

  @override
  String get workshopPublishLetGoConfirm => '放下记录';

  @override
  String get workshopPublishLetGoDone => '已放下本机的记录';

  @override
  String get workshopPublishLetGoStale => '记录刚刚有变化，再点一次重新确认。';

  @override
  String get workshopPublishLetGoUnsupported => '这个版本没法在这里放下记录。';

  @override
  String get workspaceRecoveryTitle => '工作区索引救援';

  @override
  String get workspaceRecoveryEnable => '启用工作区索引救援';

  @override
  String get workspaceRecoveryDisable => '恢复使用原索引';

  @override
  String get workspaceRecoveryHint => '仅本机：原工作区索引异常时，使用另一份索引访问可读取的对话。';

  @override
  String get workspaceRecoveryActive => '已选择独立救援索引；原索引和救援索引都会保留。';

  @override
  String get workspaceRecoveryWorking => '处理中…';

  @override
  String get workspaceRecoveryEnableBody =>
      '将停止本机引擎，改用独立救援索引后重新启动。原工作区索引保持不动，对话文件、插件和凭据不删除。\n\n首次启用时，新索引从可读取的会话及其仍存在的目录建立。旧工作区名称、顺序、默认、归档和置顶等设置不会自动继承；空工作区或目录已失效的会话不保证出现在新列表中。本机原有分组和置顶偏好保留。\n\n救援索引会保留，下次启用继续使用。这是绕过原索引故障，未修复原索引。';

  @override
  String get workspaceRecoveryDisableBody =>
      '将停止本机引擎，恢复使用原工作区索引后重新启动。原故障可能再次出现。\n\n救援期间产生的对话文件和救援索引都会保留；两个索引的工作区关系和排序不会自动同步。原索引可能不显示救援期间新增的会话，再次启用可继续使用救援索引。';

  @override
  String get workspaceRecoveryEnableStart => '启用并重启';

  @override
  String get workspaceRecoveryDisableStart => '使用原索引并重启';

  @override
  String get workspaceRecoveryUnavailable => '当前版本尚不支持工作区索引救援，请检查本机引擎状态并更新应用。';

  @override
  String get workspaceRecoveryRestartIncomplete => '索引模式已切换，但还无法确认引擎已停止，未重新启动。请等停止完成后再启动。';

  @override
  String get workspaceRecoverySaveFailed => '索引模式保存失败，未请求重新启动。请查看本机引擎状态和日志。';

  @override
  String get workspaceRecoveryFailed => '操作未完成，请查看本机引擎状态和日志。已切换的模式可在本页确认。';
}
