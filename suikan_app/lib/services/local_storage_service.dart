import 'dart:async';
import 'dart:io';

import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/log.dart';

class LocalStorageService extends GetxService {
  static LocalStorageService get instance => Get.find<LocalStorageService>();

  static const String kFirstRun = "FirstRun";
  static const String kPlayerScaleMode = "ScaleMode";
  static const String kSiteSort = "SiteSort";
  static const String kHiddenSites = "HiddenSites";
  static const String kHomeSort = "HomeSort";
  static const String kLiveRoomTabSort = "LiveRoomTabSort";
  static const String kLiveRoomQuickAccessSort = "LiveRoomQuickAccessSort";
  static const String kLiveRoomQuickAccessEnabled =
      "LiveRoomQuickAccessEnabled";
  static const String kLiveRoomShortcutFullScreen =
      "LiveRoomShortcutFullScreen";
  static const String kLiveRoomShortcutDanmaku = "LiveRoomShortcutDanmaku";
  static const String kLiveRoomShortcutMute = "LiveRoomShortcutMute";
  static const String kLiveRoomShortcutRefresh = "LiveRoomShortcutRefresh";
  static const String kLiveRoomShortcutToggleChat =
      "LiveRoomShortcutToggleChat";
  static const String kLiveRoomShortcutVolumeUp = "LiveRoomShortcutVolumeUp";
  static const String kLiveRoomShortcutVolumeDown =
      "LiveRoomShortcutVolumeDown";
  static const String kFollowGroupMode = "FollowGroupMode";
  static const String kFollowSelectedGroupId = "FollowSelectedGroupId";
  static const String kFollowDisplayStyle = "FollowDisplayStyle";
  static const String kFollowOnlyLive = "FollowOnlyLive";
  static const String kFollowRefreshOnEnter = "FollowRefreshOnEnter";
  static const String kFollowShowLiveCover = "FollowShowLiveCover";
  static const String kRememberWindowPlacement = "RememberWindowPlacement";
  static const String kDesktopWindowBounds = "DesktopWindowBounds";
  static const String kDesktopWindowMaximized = "DesktopWindowMaximized";
  static const String kMultiRoomGap = "MultiRoomGap";
  static const String kMultiRoomCollapseChat = "MultiRoomCollapseChat";
  static const String kThemeMode = "ThemeMode";
  static const String kDebugModeKey = "DebugMode";
  static const String kDanmuSize = "DanmuSize";
  static const String kDanmuSpeed = "DanmuSpeed";
  static const String kDanmuArea = "DanmuArea";
  static const String kDanmuLineCount = "DanmuLineCount";
  static const String kDanmuDelay = "DanmuDelay";
  static const String kDanmuOpacity = "DanmuOpacity";
  static const String kDanmuStrokeWidth = "DanmuStrokeWidth";
  static const String kDanmuHideScroll = "DanmuHideScroll";
  static const String kDanmuHideBottom = "DanmuHideBottom";
  static const String kDanmuHideTop = "DanmuHideTop";
  static const String kDanmuTopMargin = "DanmuTopMargin";
  static const String kDanmuBottomMargin = "DanmuBottomMargin";
  static const String kDanmuEnable = "DanmuEnable";
  static const String kDanmuRenderEmoji = "DanmuRenderEmoji";
  static const String kDanmuShieldEnable = "DanmuShieldEnable";
  static const String kDanmuKeywordShieldEnable = "DanmuKeywordShieldEnable";
  static const String kDanmuUserShieldEnable = "DanmuUserShieldEnable";
  static const String kDanmuFontWeight = "DanmuFontWeight";
  static const String kContributionRankEnable = "ContributionRankEnable";
  static const String kHardwareDecode = "HardwareDecode";
  static const String kIosOriginalQualityPowerSaving =
      "IosOriginalQualityPowerSaving";
  static const String kIosRenderCapLongEdge = "IosRenderCapLongEdge";
  static const String kChatTextSize = "ChatTextSize";
  static const String kChatTextGap = "ChatTextGap";
  static const String kChatBubbleStyle = "ChatBubbleStyle";
  static const String kQualityLevel = "QualityLevel";
  static const String kQualityLevelCellular = "QualityLevelCellular";
  static const String kAutoExitEnable = "AutoExitEnable";
  static const String kAutoExitDuration = "AutoExitDuration";
  static const String kRoomAutoExitDuration = "RoomAutoExitDuration";
  static const String kPlayerCompatMode = "PlayerCompatMode";
  static const String kPlayerAutoPause = "PlayerAutoPause";
  static const String kAllowBackgroundPlayback = "AllowBackgroundPlayback";
  static const String kAudioOnlyBackground = "AudioOnlyBackground";
  static const String kPlayerForceHttps = "PlayerForceHttps";
  static const String kPlayerGestureControlEnable =
      "PlayerGestureControlEnable";
  static const String kAutoSwitchNextOnLiveEnd = "AutoSwitchNextOnLiveEnd";
  static const String kAutoSwitchNextOnPlaybackFailure =
      "AutoSwitchNextOnPlaybackFailure";
  static const String kAutoFullScreen = "AutoFullScreen";
  static const String kAutoPipOnExit = "AutoPipOnExit";
  static const String kPlayerShowSuperChat = "PlayerShowSuperChat";
  static const String kLiveEventFlowEnable = "LiveEventFlowEnable";
  static const String kLiveEventFlowLimit = "LiveEventFlowLimit";
  static const String kLiveEventFlowOverlayEnable =
      "LiveEventFlowOverlayEnable";
  static const String kLiveEventFlowWindowSeconds =
      "LiveEventFlowWindowSeconds";
  static const String kLiveEventFlowDisplaySeconds =
      "LiveEventFlowDisplaySeconds";
  static const String kLiveEventFlowMinCount = "LiveEventFlowMinCount";
  static const String kPlayerVolume = "PlayerVolume";
  static const String kPIPHideDanmu = "PIPHideDanmu";
  static const String kPIPHideDanmuDefaultMigrated =
      "PIPHideDanmuDefaultMigrated";
  static const String kSuperChatSortDesc = "SuperChatSortDesc";
  static const String kDanmuDedupeEnable = "DanmuDedupeEnable";
  static const String kDanmuDedupeMode = "DanmuDedupeMode";
  static const String kDanmuDedupeWindow = "DanmuDedupeWindow";
  static const String kDanmuDedupeStep = "DanmuDedupeStep";
  static const String kBilibiliCookie = "BilibiliCookie";
  static const String kDouyinCookie = "DouyinCookie";
  static const String kKuaishouCookie = "KuaishouCookie";
  static const String kKuaishouKww = "KuaishouKww";
  static const String kKuaishouCookieExpiresAt = "KuaishouCookieExpiresAt";
  static const String kStyleColor = "kStyleColor";
  static const String kIsDynamic = "kIsDynamic";
  static const String kBilibiliLoginTip = "BilibiliLoginTip";
  static const String kLogEnable = "LogEnable";
  static const String kCustomPlayerOutput = "CustomPlayerOutput";
  static const String kVideoOutputDriver = "VideoOutputDriver";
  static const String kVideoHardwareDecoder = "VideoHardwareDecoder";
  static const String kWindowsGpuPreference = "WindowsGpuPreference";
  static const String kAudioOutputDriver = "AudioOutputDriver";
  static const String kMpvProfile = "MpvProfile";
  static const String kMpvAdvancedOptions = "MpvAdvancedOptions";
  static const String kImportedMpvConfPath = "ImportedMpvConfPath";
  static const String kAutoUpdateFollowEnable = "AutoUpdateFollowEnable";
  static const String kUpdateFollowDuration = "AutoUpdateFollowDuration";
  static const String kUpdateFollowThreadCount = "UpdateFollowThreadCount";
  static const String kFollowPageSize = "FollowPageSize";
  static const String kFollowRefreshTaskState = "FollowRefreshTaskState";
  static const String kFollowRefreshTaskTargets = "FollowRefreshTaskTargets";
  static const String kUserRemarks = "UserRemarks";
  static const String kLastLiveRoom = "LastLiveRoom";
  static const String kLastLiveRoomResumePending = "LastLiveRoomResumePending";
  static const String kWebDAVUri = "WebDAVUri";
  static const String kWebDAVUser = "WebDAVUser";
  static const String kWebDAVPassword = "kWebDAVPassword";
  static const String kWebDAVRemotePath = "kWebDAVRemotePath";
  static const String kWebDAVLastModified = "kWebDAVLastModified";
  static const String kBrowseSiteOrder = "kBrowseSiteOrder";
  static const String kFnOsSort = "kFnOsSort";
  static const String kWebDAVLastUploadTime = "kWebDAVLastUploadTime";
  static const String kWebDAVLastRecoverTime = "kWebDAVLastRecoverTime";
  static const String kSyncServerUrl = "SyncServerUrl";
  static const String kSyncProxyUrl = "SyncProxyUrl";

  late Box settingsBox;
  late Box<String> shieldBox;
  late Box<String> shieldPresetBox;

  Future init() async {
    // 三个箱是不同文件、不同锁，彼此没有依赖，串行等是白白多花三倍时间。
    // 每个 openBox 最坏要等满 5 秒超时（见 _openBoxSafe），串行最坏 15 秒；
    // 先一起发起再分别 await，最坏仍只有 5 秒。
    //
    // 这里刻意不用 Future.wait：三个 openBox 的泛型不同（Box<dynamic> /
    // Box<String> 等），Future.wait 会把类型擦成 List<Object> 需要再强转；
    // 分别 await 类型更清楚，并行效果和 Future.wait 完全一样。
    // 泛型要显式写：结果先落到中间变量后，Dart 没法再从赋值目标反推 T，
    // 不写会被推断成 Box<dynamic> 而报类型不匹配。
    final settingsFuture = _openBoxSafe("LocalStorage");
    final shieldFuture = _openBoxSafe<String>("DanmuShield");
    final presetFuture = _openBoxSafe<String>("DanmuShieldPreset");
    settingsBox = await settingsFuture;
    shieldBox = await shieldFuture;
    shieldPresetBox = await presetFuture;
  }

  /// 打开 Hive 箱（带超时与空箱兜底）。
  /// 损坏/被占用文件会让 Hive.openBox 挂起（不抛异常）→ 必须限时；超时改用
  /// 临时目录空箱，保证 App 启动永不因设置箱卡死（设置项丢失可由用户重设）。
  Future<Box<T>> _openBoxSafe<T>(String name) async {
    try {
      final future = Hive.openBox<T>(name);
      // 超时后原始 future 仍可能在后台完成并抛错 → 消费其错误，避免 Unhandled Exception。
      unawaited(future.then((_) {}, onError: (Object _) {}));
      return await future.timeout(const Duration(seconds: 5));
    } catch (e) {
      Log.logPrint("打开[$name]箱超时/异常($e)，改用临时空箱兜底");
    }
    final fallbackDir =
        p.join(Directory.systemTemp.path, 'suikan_box_fallback');
    return Hive.openBox('${name}_fb', path: fallbackDir);
  }

  T getValue<T>(dynamic key, T defaultValue) {
    try {
      final value = settingsBox.get(key, defaultValue: defaultValue) as T;
      // 原有一行 Log.d("Get LocalStorage: $key")：设置项在渲染/播放里被高频读取
      // （每次取值都走一次字符串拼接 + 日志落盘），纯噪音，去掉。
      return value;
    } catch (e) {
      Log.logPrint(e);
      return defaultValue;
    }
  }

  Future setValue<T>(dynamic key, T value) async {
    Log.d("Set LocalStorage: $key");
    return await settingsBox.put(key, value);
  }

  Future removeValue<T>(dynamic key) async {
    Log.d("Remove LocalStorage: $key");
    return await settingsBox.delete(key);
  }
}
