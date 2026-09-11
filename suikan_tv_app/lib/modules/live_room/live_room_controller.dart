import 'dart:async';
import 'package:simple_live_tv_app/app/fnos/fn_os_models.dart';
import 'package:simple_live_tv_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_tv_app/services/local_storage_service.dart';
import 'dart:collection';
import 'dart:io';

import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/desktop_startup_args.dart';
import 'package:simple_live_tv_app/app/dlna/dlna_receiver_service.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/models/db/history.dart';
import 'package:simple_live_tv_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_tv_app/services/current_room_service.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:simple_live_tv_app/services/follow_user_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

class LiveRoomController extends PlayerController with WidgetsBindingObserver {
  static const _appWindowChannel = MethodChannel('simple_live_tv/app_window');
  final Site pSite;
  final String pRoomId;
  final bool pIsVod;
  late LiveDanmaku liveDanmaku;
  /// 点播（影视剧集）所属剧 guid，用于播放页拉季/集做选集。
  final String pVodSeriesGuid;

  // ── 影视续播（TV 端）──────────────────────────────────────────
  /// 距上次落盘进度的时间（秒），用于 5 秒节流。
  int _lastVodLocalSaveSec = 0;
  /// 本次会话已尝试续播的集（避免重复 seek）。
  String _vodResumeHandledFor = "";
  StreamSubscription? _tvVodPositionSub;
  StreamSubscription? _tvVodDurationSub;

  // ---- TV 选集面板（点播影视剧，遥控器下键打开）----
  /// 面板是否可见。
  final episodePickerVisible = false.obs;
  /// 剧的季列表。
  final RxList<FnOsSeason> episodeSeasons = <FnOsSeason>[].obs;
  /// 当前选中的季索引。
  final currentSeasonIndex = 0.obs;
  /// 面板加载中。
  final episodePickerLoading = false.obs;
  /// 加载失败信息。
  final episodePickerError = ''.obs;
  String _vodProgressKey(String guid) => 'vod_progress_$guid';
  String _lastEpisodeKey(String seriesGuid) => 'fnos_last_ep_$seriesGuid';
  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
    this.pIsVod = false,
    this.pVodSeriesGuid = "",
  }) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    rxIsVod = pIsVod.obs;
    rxVodSeriesGuid = pVodSeriesGuid.obs;
    liveDanmaku = site.liveSite.getDanmaku();
  }
  final FocusNode focusNode = FocusNode();
  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;
  late Rx<String> rxVodSeriesGuid;
  String get vodSeriesGuid => rxVodSeriesGuid.value;
  late Rx<bool> rxIsVod;
  bool get isVod => rxIsVod.value;

  /// 当前播放内容是否来自**投屏接收**（而非从关注列表/分类进的直播间）。
  ///
  /// 投屏会话没有"上一个/下一个直播间"的概念，播放中断时**绝不能**走直播间那套
  /// 自动切换逻辑。虎牙 APP 投上来"播一会就自动停"就是这么来的：直播流一次轻微
  /// EOF 触发 completed → mediaEnd → 重试两次后 _tryAutoSwitchToNextLiveRoom
  /// → 切房间/退出，用户看到的就是"莫名其妙自己停了"。
  bool get isCastSession => site.id == 'cast_receiver';

  /// 投屏重试计数（与直播间的 mediaErrorRetryCount 分开，避免互相污染）
  int _castRetryCount = 0;
  DateTime? _castLastFailAt;
  static const int _castMaxRetry = 5;

  /// 记一次投屏播放失败。返回本次是第几次连续失败。
  ///
  /// 与上次失败间隔超过 30 秒就重新计数——否则"看了一个钟头后又断一次"时，
  /// 重试额度早被前面几次小抖动耗光，直接弹错误。
  int _bumpCastRetry() {
    final now = DateTime.now();
    if (_castLastFailAt != null &&
        now.difference(_castLastFailAt!) > const Duration(seconds: 30)) {
      _castRetryCount = 0;
    }
    _castLastFailAt = now;
    _castRetryCount += 1;
    return _castRetryCount;
  }

  /// 投屏中断后重连同一 URL（退避：0/1/2/3/3 秒）。
  Future<void> _castReconnect() async {
    final attempt = _castRetryCount;
    final delay = attempt <= 1 ? 0 : (attempt - 1).clamp(1, 3);
    if (delay > 0) {
      await Future<void>.delayed(Duration(seconds: delay));
    }
    // 投屏的 roomId 就是直链，refreshUrls 必须为 false（没有平台接口可刷新）。
    // 注意 setPlayer 是 void async，不能 await（原有调用点都是不 await 的）。
    setPlayer(refreshUrls: false);
  }

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  var specialFollowed = false.obs;
  var liveStatus = false.obs;
  var playbackLoadError = "".obs;
  var muted = false.obs;
  bool _autoSwitchingRoom = false;
  String _lastShortcutKey = "";
  String _lastShortcutSource = "";
  DateTime? _lastShortcutHandledAt;

  /// 清晰度数据
  RxList<LivePlayQuality> qualites = RxList<LivePlayQuality>();

  /// 当前清晰度
  var currentQuality = -1;
  var currentQualityInfo = "".obs;

  /// 线路数据
  RxList<String> playUrls = RxList<String>();

  Map<String, String>? playHeaders;

  /// 当前线路
  var currentLineIndex = -1;
  var currentLineInfo = "".obs;

  /// 是否处于后台
  var isBackground = false;

  /// 自动退出倒计时，单位秒
  var countdown = 60.obs;

  Timer? autoExitTimer;
  final AutoExitSession _autoExitSession = AutoExitSession();
  final autoExitSource = AutoExitSource.none.obs;
  bool _autoExitCompleting = false;
  bool _roomDisposed = false;
  // 播放地址预解析缓存：detail 就绪后立即解析，首次进房消费（进房秒出画面）。
  Future<List<String>>? _preloadPlayUrlsFuture;
  Map<String, String>? _preloadPlayHeaders;
  String? _preloadQuality;
  bool _preloadConsumed = false;

  /// 设置的自动关闭时长，单位分钟
  var autoExitMinutes = 60.obs;

  /// 是否已请求延迟自动关闭
  var delayAutoExit = false.obs;

  /// 是否启用自动关闭
  var autoExitEnable = false.obs;

  var datetime = "00:00".obs;
  Timer? _clockTimer;

  void initTimer() {
    _clockTimer?.cancel();
    // 时钟只显示到「时:分」，每秒 tick 有 59/60 次赋的是同一个值，纯属浪费
    // （每次赋值都会通知 Obx 重建）。改成对齐到下一个整分后按分钟走：
    // 回调从 60 次/分钟降到 1 次，而且因为对齐了整分，显示反而更准 —— 不会
    // 出现「系统时间已过整分、界面还慢几秒」的情况。
    _updateClockText();
    final secondsToNextMinute = 60 - DateTime.now().second;
    _clockTimer = Timer(Duration(seconds: secondsToNextMinute), () {
      _updateClockText();
      _clockTimer =
          Timer.periodic(const Duration(minutes: 1), (_) => _updateClockText());
    });
  }

  void _updateClockText() {
    final now = DateTime.now();
    datetime.value =
        "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
  }

  /// 双击退出Flag
  bool doubleClickExit = false;

  /// 双击退出Timer
  Timer? doubleClickTimer;
  final Queue<String> _recentDanmuFingerprints = Queue<String>();
  final Map<String, int> _recentDanmuCounts = <String, int>{};
  int _recentDanmuEventsSincePrune = 0;
  RxList<LiveRepeatedDanmuSummary> liveEventFlows =
      <LiveRepeatedDanmuSummary>[].obs;
  LiveRepeatedDanmuAggregator _liveEventFlowAggregator =
      LiveRepeatedDanmuAggregator();
  Timer? _liveEventFlowTimer;

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    CurrentRoomService.instance.setRoom(site, roomId);
    initTimer();
    _startLiveEventFlowTimer();
    initAutoExit();
    showDanmakuState.value = DesktopStartupArgs.isSecondaryDesktopInstance
        ? false
        : AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
    specialFollowed.value = DBService.instance.followBox
            .get("${site.id}_$roomId")
            ?.isSpecialFollow ??
        false;

    loadData();
    unawaited(syncDesktopFullscreenState());

    super.onInit();
  }

  void initAutoExit() {
    final settings = AppSettingsController.instance;
    autoExitTimer?.cancel();
    _autoExitSession.stop();
    autoExitSource.value = AutoExitSource.none;
    _autoExitCompleting = false;
    autoExitEnable.value = settings.autoExitEnable.value;
    if (!autoExitEnable.value) {
      autoExitMinutes.value = settings.roomAutoExitDuration.value;
      countdown.value = 0;
      return;
    }
    autoExitMinutes.value = settings.autoExitDuration.value;
    _autoExitSession.startGlobal(
      now: DateTime.now(),
      minutes: autoExitMinutes.value,
    );
    autoExitSource.value = AutoExitSource.global;
    _startAutoExitTicker();
  }

  void setAutoExit() {
    if (!autoExitEnable.value) {
      stopAutoExit();
      return;
    }
    _autoExitSession.startRoomOverride(
      now: DateTime.now(),
      minutes: autoExitMinutes.value,
    );
    autoExitSource.value = AutoExitSource.roomOverride;
    _startAutoExitTicker();
  }

  void _startAutoExitTicker() {
    autoExitTimer?.cancel();
    _autoExitCompleting = false;
    _refreshAutoExitCountdown();
    autoExitTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _refreshAutoExitCountdown(),
    );
  }

  void _refreshAutoExitCountdown() {
    if (!autoExitEnable.value || !_autoExitSession.enabled) {
      return;
    }
    final now = DateTime.now();
    final remaining = _autoExitSession.remaining(now);
    countdown.value = remaining == Duration.zero ? 0 : remaining.inSeconds + 1;
    if (_autoExitSession.isDue(now)) {
      unawaited(_completeAutoExit());
    }
  }

  Future<void> _completeAutoExit() async {
    if (_autoExitCompleting || _roomDisposed) {
      return;
    }
    _autoExitCompleting = true;
    autoExitTimer?.cancel();
    _autoExitSession.stop();
    autoExitSource.value = AutoExitSource.none;
    autoExitEnable.value = false;
    countdown.value = 0;
    Log.i(
        "定时关闭到点：platform=${Platform.operatingSystem} room=${site.id}/$roomId");
    await _runAutoExitStep("停止弹幕", liveDanmaku.stop);
    await _runAutoExitStep("停止播放器", player.stop);
    await _runAutoExitStep("释放唤醒锁", WakelockPlus.disable);
    await _finishAutoExit();
  }

  Future<void> _runAutoExitStep(
    String label,
    Future<void> Function() action, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      await action().timeout(timeout);
    } on TimeoutException catch (e, stackTrace) {
      Log.e("定时关闭步骤超时（$label）: $e", stackTrace);
    } catch (e, stackTrace) {
      Log.e("定时关闭步骤失败（$label）: $e", stackTrace);
    }
  }

  Future<void> _finishAutoExit() async {
    if (Platform.isAndroid) {
      try {
        final finished = await _appWindowChannel
            .invokeMethod<bool>(
              'finishAndRemoveTask',
            )
            .timeout(const Duration(seconds: 2));
        if (finished == true) {
          return;
        }
      } catch (e) {
        Log.d("原生移除任务失败，回退 Flutter 退出：$e");
      }
      await _runAutoExitStep("Flutter 退出应用", SystemNavigator.pop);
      return;
    }
    try {
      if (Platform.isWindows) {
        await windowManager
            .setPreventClose(false)
            .timeout(const Duration(seconds: 1));
      }
      await windowManager.close().timeout(const Duration(seconds: 2));
    } catch (e, stackTrace) {
      Log.e("关闭桌面窗口失败，尝试销毁窗口: $e", stackTrace);
      await _runAutoExitStep("销毁桌面窗口", windowManager.destroy);
    }
  }

  void stopAutoExit() {
    autoExitEnable.value = false;
    autoExitTimer?.cancel();
    _autoExitSession.stop();
    autoExitSource.value = AutoExitSource.none;
    _autoExitCompleting = false;
    countdown.value = 0;
  }

  void refreshRoom() {
    //messages.clear();

    liveDanmaku.stop();
    _clearDanmuDedupeState();

    loadData();
  }

  Future<void> syncDesktopFullscreenState() async {
    if (!Platform.isWindows) {
      fullScreenState.value = false;
      return;
    }
    try {
      fullScreenState.value = await windowManager.isFullScreen();
    } catch (e) {
      Log.logPrint(e);
    }
  }

  Future<void> toggleDesktopFullscreen() async {
    if (!Platform.isWindows) {
      return;
    }
    try {
      final nextValue = !await windowManager.isFullScreen();
      await windowManager.setFullScreen(nextValue);
      fullScreenState.value = nextValue;
      SmartDialog.showToast(nextValue ? "已进入全屏" : "已退出全屏");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("切换全屏失败");
    }
  }

  void toggleDanmaku() {
    setDanmakuVisible(!showDanmakuState.value);
    AppSettingsController.instance.setDanmuEnable(showDanmakuState.value);
    SmartDialog.showToast(showDanmakuState.value ? "弹幕已开启" : "弹幕已关闭");
  }

  Future<void> toggleMute() async {
    muted.value = !muted.value;
    await player.setVolume(muted.value ? 0 : 100);
    SmartDialog.showToast(muted.value ? "已静音" : "已恢复声音");
  }

  bool handleDesktopShortcut(
    String key, {
    required String source,
  }) {
    final now = DateTime.now();
    if (_lastShortcutKey == key &&
        _lastShortcutSource != source &&
        _lastShortcutHandledAt != null &&
        now.difference(_lastShortcutHandledAt!) <
            const Duration(milliseconds: 160)) {
      _lastShortcutHandledAt = now;
      _lastShortcutSource = source;
      return true;
    }
    _lastShortcutKey = key;
    _lastShortcutSource = source;
    _lastShortcutHandledAt = now;
    switch (key) {
      case "keyF":
        unawaited(toggleDesktopFullscreen());
        return true;
      case "keyD":
        toggleDanmaku();
        return true;
      case "keyR":
        refreshRoom();
        return true;
      case "keyM":
        unawaited(toggleMute());
        return true;
      default:
        return false;
    }
  }

  bool handleKeyboardShortcut(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.keyF) {
      return handleDesktopShortcut("keyF", source: "keyboard");
    }
    if (key == LogicalKeyboardKey.keyD) {
      return handleDesktopShortcut("keyD", source: "keyboard");
    }
    if (key == LogicalKeyboardKey.keyR) {
      return handleDesktopShortcut("keyR", source: "keyboard");
    }
    if (key == LogicalKeyboardKey.keyM) {
      return handleDesktopShortcut("keyM", source: "keyboard");
    }
    return false;
  }

  void showAutoExitSheet() {
    Utils.showRightDialog(
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          Padding(
            padding: AppStyle.edgeInsetsA12,
            child: Text(
              "定时关闭",
              style: AppStyle.titleStyleWhite,
            ),
          ),
          Obx(
            () => SwitchListTile(
              title: Text(
                "启用定时关闭",
                style: Get.textTheme.titleMedium,
              ),
              value: autoExitEnable.value,
              onChanged: (e) {
                autoExitEnable.value = e;
                if (e) {
                  autoExitMinutes.value =
                      AppSettingsController.instance.roomAutoExitDuration.value;
                  setAutoExit();
                } else {
                  stopAutoExit();
                }
              },
            ),
          ),
          Obx(
            () => ListTile(
              enabled: autoExitEnable.value,
              title: Text(
                autoExitSource.value == AutoExitSource.global
                    ? "全局定时关闭：${autoExitMinutes.value ~/ 60}小时${autoExitMinutes.value % 60}分钟"
                    : "本次观看：${autoExitMinutes.value ~/ 60}小时${autoExitMinutes.value % 60}分钟",
                style: Get.textTheme.titleMedium,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                var value = await showTimePicker(
                  context: Get.context!,
                  initialTime: TimeOfDay(
                    hour: autoExitMinutes.value ~/ 60,
                    minute: autoExitMinutes.value % 60,
                  ),
                  initialEntryMode: TimePickerEntryMode.inputOnly,
                  builder: (_, child) {
                    return MediaQuery(
                      data: Get.mediaQuery.copyWith(
                        alwaysUse24HourFormat: true,
                      ),
                      child: child!,
                    );
                  },
                );
                if (value == null || (value.hour == 0 && value.minute == 0)) {
                  return;
                }
                var duration =
                    Duration(hours: value.hour, minutes: value.minute);
                autoExitMinutes.value = duration.inMinutes;
                AppSettingsController.instance
                    .setRoomAutoExitDuration(autoExitMinutes.value);
                if (autoExitEnable.value) {
                  setAutoExit();
                } else {
                  countdown.value = 0;
                }
              },
            ),
          ),
          Obx(
            () {
              countdown.value;
              final globalRemaining = _autoExitSession.globalRemaining(
                DateTime.now(),
              );
              if (autoExitSource.value != AutoExitSource.roomOverride ||
                  globalRemaining <= Duration.zero) {
                return const SizedBox.shrink();
              }
              return ListTile(
                title: Text(
                  "全局定时关闭剩余：${_formatAutoExitDuration(globalRemaining)}",
                ),
                subtitle: const Text("当前修改只影响本次观看，不会修改全局设置"),
              );
            },
          ),
        ],
      ),
    );
  }

  String _formatAutoExitDuration(Duration duration) {
    final minutes = (duration.inSeconds + 59) ~/ 60;
    final hours = minutes ~/ 60;
    final remainMinutes = minutes % 60;
    return hours > 0 ? "$hours小时$remainMinutes分钟" : "$remainMinutes分钟";
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
    liveDanmaku.onClose = onWSClose;
    liveDanmaku.onReady = onWSReady;
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (msg.type == LiveMessageType.chat) {
      // 关键词屏蔽检查
      for (var keyword in AppSettingsController.instance.shieldList) {
        Pattern? pattern;
        if (Utils.isRegexFormat(keyword)) {
          String removedSlash = Utils.removeRegexFormat(keyword);
          try {
            pattern = RegExp(removedSlash);
          } catch (e) {
            // should avoid this during add keyword
            Log.d("关键词：$keyword 正则格式错误");
          }
        } else {
          pattern = keyword;
        }
        if (pattern != null && msg.message.contains(pattern)) {
          Log.d("关键词：$keyword\n已屏蔽消息内容：${msg.message}");
          return;
        }
      }

      if (_isDuplicateDanmu(msg)) {
        return;
      }

      _recordLiveEventFlow(msg);

      if (!liveStatus.value || isBackground) {
        return;
      }

      final renderEmoji = AppSettingsController.instance.danmuRenderEmoji.value;
      final parts = renderEmoji ? _buildDanmakuContentParts(msg.spans) : null;
      addDanmaku([
        DanmakuContentItem(
          msg.message,
          color: Color.fromARGB(255, msg.color.r, msg.color.g, msg.color.b),
          imageUrls: renderEmoji && parts == null ? msg.imageUrls : null,
          parts: parts,
        ),
      ]);
    } else if (msg.type == LiveMessageType.online) {
      online.value = msg.data;
    } else if (msg.type == LiveMessageType.superChat) {
      //superChats.add(msg.data);
    }
  }

  List<DanmakuContentPart>? _buildDanmakuContentParts(
    List<LiveMessageSpan>? spans,
  ) {
    final source = spans ?? const <LiveMessageSpan>[];
    if (source.isEmpty) {
      return null;
    }
    final parts = <DanmakuContentPart>[];
    for (final span in source) {
      if (span.isText) {
        final text = span.text ?? "";
        if (text.isNotEmpty) {
          parts.add(DanmakuContentPart.text(text));
        }
      } else if (span.isImage) {
        final imageUrl = (span.imageUrl ?? "").trim();
        if (imageUrl.isNotEmpty) {
          parts.add(DanmakuContentPart.image(imageUrl));
        }
      }
    }
    return parts.isEmpty ? null : parts;
  }

  bool _isDuplicateDanmu(LiveMessage msg) {
    final settings = AppSettingsController.instance;
    if (!settings.danmuDedupeEnable.value) {
      return false;
    }
    final strictMode = settings.danmuDedupeStrictMode;
    final fingerprint = _buildDanmuFingerprint(
      msg,
      includeUserName: !strictMode,
    );
    if (fingerprint == null) {
      return false;
    }
    final windowSize = settings.effectiveDanmuDedupeWindow;
    final duplicate = _recentDanmuCounts.containsKey(fingerprint);
    _recentDanmuFingerprints.addLast(fingerprint);
    _recentDanmuCounts[fingerprint] =
        (_recentDanmuCounts[fingerprint] ?? 0) + 1;
    if (strictMode) {
      _recentDanmuEventsSincePrune = 0;
      _pruneRecentDanmuFingerprints(windowSize);
      return duplicate;
    }

    final step = settings.danmuDedupeStep.value.clamp(1, 20).toInt();
    _recentDanmuEventsSincePrune += 1;
    final shouldPrune = _recentDanmuEventsSincePrune >= step ||
        _recentDanmuFingerprints.length > windowSize + step - 1;
    if (shouldPrune) {
      _recentDanmuEventsSincePrune = 0;
    }
    if (shouldPrune) {
      _pruneRecentDanmuFingerprints(windowSize);
    }
    return duplicate;
  }

  void _pruneRecentDanmuFingerprints(int windowSize) {
    while (_recentDanmuFingerprints.length > windowSize) {
      final removed = _recentDanmuFingerprints.removeFirst();
      final count = (_recentDanmuCounts[removed] ?? 0) - 1;
      if (count <= 0) {
        _recentDanmuCounts.remove(removed);
      } else {
        _recentDanmuCounts[removed] = count;
      }
    }
  }

  String? _buildDanmuFingerprint(
    LiveMessage msg, {
    required bool includeUserName,
  }) {
    final parts = <String>[];
    final message = _normalizeDanmuFingerprintPart(msg.message);
    if (message.isNotEmpty) {
      parts.add("m:$message");
    }
    for (final span in msg.spans ?? const <LiveMessageSpan>[]) {
      final text = _normalizeDanmuFingerprintPart(span.text ?? "");
      final imageUrl = _normalizeDanmuFingerprintPart(span.imageUrl ?? "");
      if (text.isNotEmpty) {
        parts.add("t:$text");
      }
      if (imageUrl.isNotEmpty) {
        parts.add("i:$imageUrl");
      }
    }
    for (final imageUrl in msg.imageUrls ?? const <String>[]) {
      final value = _normalizeDanmuFingerprintPart(imageUrl);
      if (value.isNotEmpty) {
        parts.add("u:$value");
      }
    }
    if (parts.isEmpty) {
      return null;
    }
    if (!includeUserName) {
      return parts.join("\u0002");
    }
    final userName = _normalizeDanmuFingerprintPart(msg.userName);
    if (userName.isEmpty) {
      return null;
    }
    return "$userName\u0001${parts.join("\u0002")}";
  }

  String _normalizeDanmuFingerprintPart(String value) {
    return value.trim().replaceAll(RegExp(r"\s+"), " ");
  }

  void _clearDanmuDedupeState() {
    _recentDanmuFingerprints.clear();
    _recentDanmuCounts.clear();
    _recentDanmuEventsSincePrune = 0;
  }

  void _startLiveEventFlowTimer() {
    _liveEventFlowTimer?.cancel();
    _liveEventFlowTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _flushLiveEventFlow(),
    );
  }

  void _recordLiveEventFlow(LiveMessage msg) {
    if (msg.userName == "LiveSysMessage") {
      return;
    }
    final settings = AppSettingsController.instance;
    if (!settings.liveEventFlowEnable.value) {
      clearLiveEventFlow();
      return;
    }
    final text = _normalizeDanmuFingerprintPart(msg.message);
    if (text.isEmpty) {
      return;
    }
    _ensureLiveEventFlowAggregatorSettings();
    _liveEventFlowAggregator.add(text);
    _flushLiveEventFlow();
  }

  void _flushLiveEventFlow() {
    final settings = AppSettingsController.instance;
    if (!settings.liveEventFlowEnable.value) {
      clearLiveEventFlow();
      return;
    }
    _ensureLiveEventFlowAggregatorSettings();
    final summaries = _liveEventFlowAggregator.preview(
      displayTtl: Duration(
        seconds: settings.effectiveLiveEventFlowDisplaySeconds,
      ),
    );
    liveEventFlows.assignAll(summaries);
  }

  void _ensureLiveEventFlowAggregatorSettings() {
    final settings = AppSettingsController.instance;
    final countWindow = Duration(
      seconds: settings.effectiveLiveEventFlowWindowSeconds,
    );
    final minDisplayCount = settings.effectiveLiveEventFlowMinCount;
    if (_liveEventFlowAggregator.countWindow == countWindow &&
        _liveEventFlowAggregator.minDisplayCount == minDisplayCount) {
      return;
    }
    _liveEventFlowAggregator = LiveRepeatedDanmuAggregator(
      countWindow: countWindow,
      minDisplayCount: minDisplayCount,
    );
    liveEventFlows.clear();
  }

  void clearLiveEventFlow() {
    _liveEventFlowAggregator.clear();
    liveEventFlows.clear();
  }

  /// 接收 WebSocket 关闭消息
  void onWSClose(String msg) {
    Log.d("弹幕服务器连接状态：$msg");
    final shouldNotify = msg.contains("失败") || msg.contains("超过最大次数");
    if (shouldNotify && AppSettingsController.instance.danmuEnable.value) {
      SmartDialog.showToast("弹幕连接异常：$msg");
    }
  }

  /// WebSocket 已连接完成
  void onWSReady() {
    Log.d("弹幕服务器连接成功");
  }

  /// 加载直播间信息
  void loadData() async {
    playbackLoadError.value = "";
    try {
      pageLoadding.value = true;
      detail.value = await site.liveSite.getRoomDetail(roomId: roomId);

      addHistory();
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      // 🔴 2026-09-12：进房详情是**最权威的开播状态来源** → 回写关注列表 +
      // 覆盖本机 P2P 快照。此前 TV 只回写标题/封面（且仅限补详情链路），
      // 于是"点进去显示未开播、退出来列表还写着直播中"。点播/录播不算直播中。
      if (Get.isRegistered<FollowUserService>()) {
        FollowUserService.instance.syncFollowRoomMeta(
          siteId: site.id,
          roomId: roomId,
          title: detail.value!.title,
          cover: detail.value!.cover,
          altRoomId: detail.value!.roomId,
          isLiving: isVod ? false : detail.value!.status,
        );
      }
      if (liveStatus.value) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        SmartDialog.showToast("当前主播未开播，正在轮播录像");
      }

      initDanmau();
      liveDanmaku.start(detail.value?.danmakuData);
    } catch (e) {
      SmartDialog.showToast(e.toString());
    } finally {
      pageLoadding.value = false;
    }
  }

  /// 投屏接收专用：同一页面/同一播放器原地切换播放源（新投屏顶掉旧投屏）。
  ///
  /// 不能走"导航替换页面"（Get.offNamed）：替换期间新旧 controller 并存，
  /// 后续 SOAP Play/查询动作可能命中旧 controller，旧播放器不停 → 双声音。
  /// 这里直接复用当前 controller：先停旧流 → 改 roomId → loadData 重新拉取播放。
  ///
  /// [newSite] 投屏接入专用：必须换成"URL 直播"的投屏接收 site（CastReceiverSite）。
  /// 否则若 TV 此前开着某平台直播间，会用旧 site 把投屏 URL 当房间号去请求
  /// 平台 API → 解析失败 → 误报"未开播"（虎牙/斗鱼投屏黑屏的根因）。
  Future<void> switchRoom(
    String newRoomId, {
    Site? newSite,
    bool? newIsVod,
  }) async {
    final sameSite = newSite == null || newSite == site;
    if (roomId == newRoomId &&
        sameSite &&
        (newIsVod == null || newIsVod == isVod)) {
      // 同一 URL 重复投屏：恢复播放即可（不重置进度/不重拉流）
      try {
        await player.play();
      } catch (_) {}
      return;
    }
    if (newIsVod != null && newIsVod != isVod) {
      // 点播↔直播切换（如投屏影视库后再投直播）：决定是否有进度条/可拖动。
      rxIsVod.value = newIsVod;
    }
    // 新的一次投屏：重置重连计数，别让上一条流的重试次数拖累这一条。
    _castRetryCount = 0;
    _castLastFailAt = null;
    if (newSite != null && newSite != site) {
      // 换源站点：重建弹幕等站点相关状态（同 resetRoom）
      rxSite.value = newSite;
      CurrentRoomService.instance.setRoom(newSite, newRoomId);
      liveDanmaku.stop();
      _clearDanmuDedupeState();
      clearLiveEventFlow();
      danmakuController?.clear();
      liveDanmaku = newSite.liveSite.getDanmaku();
    }
    // 先停旧流，确保换源瞬间没有新旧两个声音
    try {
      await player.stop();
    } catch (_) {}
    rxRoomId.value = newRoomId;
    currentLineIndex = -1;
    playUrls.clear();
    currentQuality = -1;
    qualites.clear();
    liveStatus.value = false;
    loadData();
  }

  /// 初始化播放器
  Future<void> getPlayQualites() async {
    playbackLoadError.value = "";
    qualites.clear();
    currentQuality = -1;
    try {
      var playQualites =
          await site.liveSite.getPlayQualites(detail: detail.value!);

      if (playQualites.isEmpty) {
        playbackLoadError.value = "无法读取播放清晰度，请稍后重试";
        Log.e(
          "播放清晰度列表为空：${site.id}/$roomId",
          StackTrace.current,
        );
        return;
      }
      qualites.value = playQualites;
      var qualityLevel = AppSettingsController.instance.qualityLevel.value;
      if (qualityLevel == 2) {
        //最高
        currentQuality = 0;
      } else if (qualityLevel == 0) {
        //最低
        currentQuality = playQualites.length - 1;
      } else {
        //中间值
        int middle = (playQualites.length / 2).floor();
        currentQuality = middle;
      }

      // 播放地址预解析：清晰度确定后立即发起（fire-and-forget），
      // 首次播放直接消费缓存（进房秒出画面）；失败/换质量/重试仍走原逻辑。
      if (currentQuality >= 0 && currentQuality < qualites.length) {
        _preloadConsumed = false;
        final q = qualites[currentQuality];
        final detail0 = detail.value;
        _preloadPlayUrlsFuture = site.liveSite
            .getPlayUrls(detail: detail0!, quality: q)
            .then((r) {
          _preloadQuality = q.quality;
          _preloadPlayHeaders = r.headers;
          return r.urls;
        }).catchError((Object _) {
          _preloadPlayUrlsFuture = null;
          return <String>[];
        });
      }

      await getPlayUrl();
    } catch (e, stackTrace) {
      Log.e("读取播放清晰度失败：${site.id}/$roomId error=$e", stackTrace);
      playbackLoadError.value = e.toString();
    }
  }

  Future<void> getPlayUrl() async {
    playUrls.clear();
    currentQualityInfo.value = qualites[currentQuality].quality;
    currentLineInfo.value = "";
    currentLineIndex = -1;
    // 预解析缓存消费：首次进房且质量匹配时直接使用（省一次网络往返，进房秒出画面）。
    List<String>? urls;
    Map<String, String>? headers;
    final pre = _preloadPlayUrlsFuture;
    if (!_preloadConsumed &&
        pre != null &&
        _preloadQuality == qualites[currentQuality].quality) {
      _preloadConsumed = true;
      try {
        urls = await pre;
        headers = _preloadPlayHeaders;
      } catch (_) {
        urls = null;
      }
    }
    if (urls == null) {
      final playUrl = await site.liveSite
          .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
      urls = playUrl.urls;
      headers = playUrl.headers;
    }
    if (urls.isEmpty) {
      playbackLoadError.value = "无法读取播放地址，请稍后重试";
      return;
    }
    playUrls.value = urls;
    playHeaders = headers;
    currentLineIndex = 0;
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    //重置错误次数
    mediaErrorRetryCount = 0;
    setPlayer();
  }

  Future<bool> _reloadPlayUrls({bool silent = false}) async {
    if (detail.value == null ||
        currentQuality < 0 ||
        currentQuality >= qualites.length) {
      return false;
    }
    currentQualityInfo.value = qualites[currentQuality].quality;
    var playUrl = await site.liveSite
        .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
    if (playUrl.urls.isEmpty) {
      if (!silent) {
        SmartDialog.showToast("无法读取播放地址");
      }
      return false;
    }
    playUrls.value = playUrl.urls;
    playHeaders = playUrl.headers;
    if (currentLineIndex < 0) {
      currentLineIndex = 0;
    } else if (currentLineIndex >= playUrls.length) {
      currentLineIndex = playUrls.length - 1;
    }
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    return true;
  }

  void changePlayLine(int index) {
    currentLineIndex = index;
    //重置错误次数
    mediaErrorRetryCount = 0;
    setPlayer();
  }

  void setPlayer({bool refreshUrls = false}) async {
    if (refreshUrls) {
      var reloaded = await _reloadPlayUrls(silent: true);
      if (!reloaded) {
        return;
      }
    }
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";
    await initializePlayer(isVod: isVod);
    player.open(
      Media(
        playUrls[currentLineIndex],
        httpHeaders: playHeaders,
      ),
    );
    await player.setVolume(muted.value ? 0 : 100);

    Log.d("播放链接\r\n：${playUrls[currentLineIndex]}");
  }

  bool get _shouldRefreshUrlsOnPlaybackRetry =>
      site.id == Constant.kHuya || site.id == Constant.kDouyu;

  /// 探测到明确总时长 → 补判为点播（仅投屏会话）。
  ///
  /// 第三方投屏端（飞牛影视等）不发 SuikanCastType，isVod 恒为 false，
  /// 于是进度条被隐藏、左右键跑去开"关注列表/设置"，用户只看到按键说明。
  /// 这里按 mpv 上报的总时长补上：直播流 duration 恒为 0，有总时长即点播。
  ///
  /// 只对投屏会话生效：自有影视库/录播会显式带 isVod，类型明确，不需要猜，
  /// 也避免直播间的按键行为被悄悄改掉。
  @override
  void onDurationDetected(int seconds) {
    if (!isCastSession || isVod) return;
    rxIsVod.value = true;
    Log.d("投屏内容探测到总时长 ${seconds}s，自动按点播处理（显示进度条）");
    // 同步给投屏代理：放开 Range 请求，否则拖进度时源站不认、拖动无效。
    DlnaReceiverService.instance.markVodDetected();
    try {
      SmartDialog.showToast("已识别为影视，左右键快进快退");
    } catch (_) {}
  }

  /// 音量调整后同步静音标记（控制条上的"静音"状态展示用）。
  @override
  Future<int> adjustVolume(int delta) async {
    final v = await super.adjustVolume(delta);
    muted.value = v <= 0;
    return v;
  }

  /// 投屏会话的播放结束：不切房间、不退出，只重连或提示。
  Future<void> _handleCastPlaybackEnd() async {
    if (isVod) {
      // 点播正常播完（不是故障）——给个明确提示，别去重试，否则会从头再播一遍。
      Log.d("投屏点播播放结束");
      playbackLoadError.value = "播放结束";
      _castRetryCount = 0;
      return;
    }
    final attempt = _bumpCastRetry();
    if (attempt <= _castMaxRetry) {
      Log.d("投屏直播中断，第$attempt/$_castMaxRetry 次重连");
      await _castReconnect();
      return;
    }
    _castRetryCount = 0;
    playbackLoadError.value = "投屏播放中断，请在投屏端重新投一次";
    SmartDialog.showToast("投屏播放中断");
  }

  /// 投屏会话的播放失败：同样只重连，绝不做"跳下一个直播间"。
  Future<void> _handleCastPlaybackError(String error) async {
    final attempt = _bumpCastRetry();
    Log.d("投屏播放失败($error)，第$attempt/$_castMaxRetry 次重连");
    if (attempt <= _castMaxRetry) {
      await _castReconnect();
      return;
    }
    _castRetryCount = 0;
    errorMsg.value = "播放失败：$error";
    playbackLoadError.value = "播放失败：$error";
    SmartDialog.showToast("播放失败:$error");
    Log.e("投屏播放失败详情：$error", StackTrace.current);
  }

  @override
  void mediaEnd() async {
    // 投屏会话的"播放结束"含义完全不同：直播流偶发 EOF 也会触发 completed，
    // 但用户并没有结束播放。这里静默重连，绝不切房间、绝不退出播放器。
    if (isCastSession) {
      await _handleCastPlaybackEnd();
      return;
    }
    if (mediaErrorRetryCount < 2) {
      Log.d("播放结束，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount == 1) {
        //延迟一秒再刷新
        await Future.delayed(const Duration(seconds: 1));
      }
      mediaErrorRetryCount += 1;
      //刷新一次
      setPlayer(refreshUrls: _shouldRefreshUrlsOnPlaybackRetry);
      return;
    }

    Log.d("播放结束");
    // 遍历线路，如果全部链接都断开就是直播结束了
    if (playUrls.length - 1 == currentLineIndex) {
      liveStatus.value = false;
      await _tryAutoSwitchToNextLiveRoom(reason: "live_end");
    } else {
      changePlayLine(currentLineIndex + 1);

      //setPlayer();
    }
  }

  int mediaErrorRetryCount = 0;
  @override
  void mediaError(String error) async {
    if (isCastSession) {
      await _handleCastPlaybackError(error);
      return;
    }
    if (mediaErrorRetryCount < 2) {
      Log.d("播放失败，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount == 1) {
        //延迟一秒再刷新
        await Future.delayed(const Duration(seconds: 1));
      }
      mediaErrorRetryCount += 1;
      //刷新一次
      setPlayer(refreshUrls: _shouldRefreshUrlsOnPlaybackRetry);
      return;
    }

    if (playUrls.length - 1 == currentLineIndex) {
      // 完整保留 mpv 原始错误：toast 一闪而过（投屏/电视场景用户根本来不及看），
      // 同步写入 playbackLoadError → 画面居中持久显示，便于反馈定位
      // （403 防盗链 / 超时 / 解码失败原因各不相同，必须看原文）。
      errorMsg.value = "播放失败：$error";
      playbackLoadError.value = "播放失败：$error";
      SmartDialog.showToast("播放失败:$error");
      Log.e("播放失败详情：$error", StackTrace.current);
      await _tryAutoSwitchToNextLiveRoom(reason: "playback_failure");
    } else {
      //currentLineIndex += 1;
      //setPlayer();
      changePlayLine(currentLineIndex + 1);
    }
  }

  Future<void> _tryAutoSwitchToNextLiveRoom({required String reason}) async {
    final settings = AppSettingsController.instance;
    final enabled = reason == "live_end"
        ? settings.autoSwitchNextOnLiveEnd.value
        : settings.autoSwitchNextOnPlaybackFailure.value;
    if (!enabled || _autoSwitchingRoom) {
      return;
    }

    final liveChannels = FollowUserService.instance.livingList.toList();
    if (liveChannels.isEmpty) {
      return;
    }

    final currentId = "${site.id}_$roomId";
    final currentIndex =
        liveChannels.indexWhere((item) => item.id == currentId);
    final candidates =
        liveChannels.where((item) => item.id != currentId).toList();
    if (candidates.isEmpty) {
      return;
    }

    FollowUser target;
    if (currentIndex < 0 || currentIndex >= liveChannels.length - 1) {
      target = candidates.first;
    } else {
      target = liveChannels[currentIndex + 1];
      if (target.id == currentId) {
        target = candidates.first;
      }
    }

    _autoSwitchingRoom = true;
    try {
      // 目标站点可能已被删除/未注册（自定义源/影视库被删后仍在关注列表里），
      // 此时不能直接切（原 `Sites.allSites[...]!` 对 null 断言崩溃），跳过切换。
      final targetSite = Sites.siteForKey(target.siteId);
      if (targetSite == null) {
        Log.d("自动切换直播间失败：站点未注册 siteId=${target.siteId}");
        return;
      }
      SmartDialog.showToast(
        reason == "live_end" ? "当前直播已结束，已切换到下一个直播间" : "当前直播播放失败，已切换到下一个直播间",
      );
      resetRoom(targetSite, target.roomId);
    } finally {
      _autoSwitchingRoom = false;
    }
  }

  /// 添加历史记录
  void addHistory() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    var history = DBService.instance.getHistory(id);
    if (history != null) {
      history.updateTime = DateTime.now();
    }
    history ??= History(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      updateTime: DateTime.now(),
    );

    DBService.instance.addOrUpdateHistory(history);
  }

  /// 关注用户
  void followUser() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    DBService.instance.addFollow(
      FollowUser(
        id: id,
        roomId: roomId,
        siteId: site.id,
        userName: detail.value?.userName ?? "",
        face: detail.value?.userAvatar ?? "",
        addTime: DateTime.now(),
      ),
    );
    followed.value = true;
    specialFollowed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
    SmartDialog.showToast("已关注");
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    // if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) {
    //   return;
    // }

    var id = "${site.id}_$roomId";
    DBService.instance.deleteFollow(id);
    followed.value = false;
    specialFollowed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
    SmartDialog.showToast("已取消关注");
  }

  void toggleSpecialFollow(bool enabled) {
    if (detail.value == null) {
      return;
    }
    final id = "${site.id}_$roomId";
    var follow = DBService.instance.followBox.get(DBService.safeBoxKey(id));
    follow ??= FollowUser(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      addTime: DateTime.now(),
    );
    follow.isSpecialFollow = enabled;
    DBService.instance.addFollow(follow);
    followed.value = true;
    specialFollowed.value = enabled;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
    SmartDialog.showToast(enabled ? "已设为特别关注" : "已取消特别关注");
  }

  void resetRoom(Site site, String roomId) async {
    if (this.site == site && this.roomId == roomId) {
      return;
    }

    // 🔴 2026-09-12：换台 = 用户即将看到新的关注面板/切台列表 →
    // 顺手吃一遍局域网快照（**纯 P2P**，全屋无生产者时前 20 条兜底公网）。
    // 3s 去重保证连续切台零成本。
    FollowUserService.instance.refreshFollowPanelFromPeers();

    rxSite.value = site;
    rxRoomId.value = roomId;
    // 从投屏切回普通直播间时清掉点播态：isVod 可能是投屏影视被自动补判出来的，
    // 不复位的话切回直播仍按点播处理（左右键去快进而非开设置）。
    // resetRoom 的调用方全是平台直播间，置 false 是准确的。
    rxIsVod.value = false;
    _castRetryCount = 0;
    _castLastFailAt = null;
    CurrentRoomService.instance.setRoom(site, roomId);
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
    specialFollowed.value = DBService.instance.followBox
            .get("${site.id}_$roomId")
            ?.isSpecialFollow ??
        false;

    // 清除全部消息
    liveDanmaku.stop();
    _clearDanmuDedupeState();
    clearLiveEventFlow();

    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();

    // 停止播放
    await player.stop();

    // 刷新信息
    loadData();
  }

  void nextChannel() {
    //读取正在直播的频道
    var liveChannels = FollowUserService.instance.livingList;
    if (liveChannels.isEmpty) {
      SmartDialog.showToast("没有正在直播的频道");
      return;
    }
    var index = liveChannels
        .indexWhere((element) => element.id == "${site.id}_$roomId");
    // 当前频道不在在线关注列表（如直播源频道直接播放、未关注）：按下键从第一个开始，
    // 统一所有平台「上下键循环切在线关注频道」的行为。
    if (index == -1) {
      index = 0;
    } else {
      index += 1;
      if (index >= liveChannels.length) {
        index = 0;
      }
    }
    var nextChannel = liveChannels[index];
    final nextSite = Sites.siteForKey(nextChannel.siteId);
    if (nextSite == null) {
      Log.d("切频道失败：站点未注册 siteId=${nextChannel.siteId}");
      return;
    }
    resetRoom(nextSite, nextChannel.roomId);
  }

  void prevChannel() {
    //读取正在直播的频道
    var liveChannels = FollowUserService.instance.livingList;
    if (liveChannels.isEmpty) {
      SmartDialog.showToast("没有正在直播的频道");
      return;
    }
    var index = liveChannels
        .indexWhere((element) => element.id == "${site.id}_$roomId");
    // 当前频道不在在线关注列表（如直播源频道直接播放、未关注）：按上键从最后一个开始，
    // 统一所有平台「上下键循环切在线关注频道」的行为。
    if (index == -1) {
      index = liveChannels.length - 1;
    } else {
      index -= 1;
      if (index < 0) {
        index = liveChannels.length - 1;
      }
    }
    var nextChannel = liveChannels[index];
    final nextSite = Sites.siteForKey(nextChannel.siteId);
    if (nextSite == null) {
      Log.d("切频道失败：站点未注册 siteId=${nextChannel.siteId}");
      return;
    }
    resetRoom(nextSite, nextChannel.roomId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      Log.d("进入后台:$state");
      //进入后台，关闭弹幕
      danmakuController?.clear();
      isBackground = true;
    } else
    //返回前台
    if (state == AppLifecycleState.resumed) {
      Log.d("返回前台");
      _refreshAutoExitCountdown();
      isBackground = false;
    }
  }

  /// 影视（fnOS/自定义影视库）播放进度：每 5 秒落盘一次本地进度，
  /// 并在开播时 seek 到上次位置 —— 让 TV 端点剧能"接着上次看"。
  void _bindVodProgressSubscriptions() {
    _tvVodPositionSub?.cancel();
    _tvVodDurationSub?.cancel();
    if (!isVod) return;
    _tvVodPositionSub = player.stream.position.listen((pos) {
      _maybeHandleVodProgress(pos);
    });
    _tvVodDurationSub = player.stream.duration.listen((total) {
      _maybeResumeVod(total);
    });
  }

  void _maybeHandleVodProgress(Duration position) {
    if (!isVod) return;
    final sec = position.inSeconds;
    if (sec >= 5 && sec - _lastVodLocalSaveSec >= 5) {
      _lastVodLocalSaveSec = sec;
      unawaited(
        LocalStorageService.instance.setValue(_vodProgressKey(roomId), sec),
      );
    }
  }

  /// 续播恢复：单集只尝试一次；>5s 且未到片尾 15s 才 seek，避免误跳/看完重播。
  void _maybeResumeVod(Duration total) {
    if (!isVod) return;
    if (_vodResumeHandledFor == roomId) return;
    final totalSec = total.inSeconds;
    if (totalSec <= 0) return;
    _vodResumeHandledFor = roomId;
    final saved =
        LocalStorageService.instance.getValue(_vodProgressKey(roomId), 0);
    if (saved > 5 && saved < totalSec - 15) {
      unawaited(player.seek(Duration(seconds: saved)));
    }
  }

  /// 记录「该剧上次播放到哪一集」，供影视库点剧时直接续播。
  void _recordLastEpisode() {
    if (!isVod) return;
    final series = vodSeriesGuid.trim();
    if (series.isEmpty) return;
    unawaited(
      LocalStorageService.instance.setValue(_lastEpisodeKey(series), roomId),
    );
  }

  /// 可选集播放？点播影视 + 带了所属剧 guid。
  bool get canPickEpisode =>
      isVod && vodSeriesGuid.trim().isNotEmpty;

  /// 打开选集面板（由播放页按键调用）——只负责加载季/集数据。
  Future<void> openEpisodePicker() async {
    if (!canPickEpisode) return;
    if (episodeSeasons.isNotEmpty) return;
    episodePickerLoading.value = true;
    episodePickerError.value = '';
    try {
      final srv = FnOsService.instance.serverForSiteId(site.id);
      if (srv == null) {
        episodePickerError.value = "未找到该影视站点";
        return;
      }
      var seasons = <FnOsSeason>[];
      try {
        seasons =
            await FnOsService.instance.getSeasons(srv, vodSeriesGuid);
      } catch (_) {}
      if (seasons.isEmpty) {
        episodePickerError.value = "该剧暂无剧集";
        return;
      }
      var idx = 0;
      for (var i = 0; i < seasons.length; i++) {
        for (final e in seasons[i].episodes) {
          if (e.guid == roomId) {
            idx = i;
            break;
          }
        }
      }
      currentSeasonIndex.value = idx;
      episodeSeasons.assignAll(seasons);
      await _ensureCurrentSeasonEpisodes();
    } catch (e) {
      episodePickerError.value = "加载失败：$e";
    } finally {
      episodePickerLoading.value = false;
    }
  }

  Future<void> _ensureCurrentSeasonEpisodes() async {
    final srv = FnOsService.instance.serverForSiteId(site.id);
    if (srv == null) return;
    final seasons = episodeSeasons;
    if (seasons.isEmpty ||
        currentSeasonIndex.value >= seasons.length) {
      return;
    }
    final season = seasons[currentSeasonIndex.value];
    if (season.episodes.isNotEmpty) return;
    try {
      final eps =
          await FnOsService.instance.getEpisodes(srv, season.guid);
      if (season.episodes.isEmpty) {
        seasons[currentSeasonIndex.value] = FnOsSeason(
          guid: season.guid,
          title: season.title,
          seasonNumber: season.seasonNumber,
          overview: season.overview,
          poster: season.poster,
          airDate: season.airDate,
          episodeCount: season.episodeCount,
          episodes: eps,
          rating: season.rating,
        );
      }
    } catch (_) {}
  }

  /// 选择某一季。
  Future<void> selectSeason(int index) async {
    if (index < 0 || index >= episodeSeasons.length) return;
    currentSeasonIndex.value = index;
    await _ensureCurrentSeasonEpisodes();
  }

  /// 播放指定集（若就是当前集则只关面板）。
  Future<void> playEpisode(FnOsEpisode ep) async {
    episodePickerVisible.value = false;
    if (ep.guid == roomId) return;
    _vodResumeHandledFor = "";
    _lastVodLocalSaveSec = 0;
    // 复用当前 controller 原地切集：停旧流 -> 改 roomId -> loadData。
    try {
      await player.stop();
    } catch (_) {}
    rxRoomId.value = ep.guid;
    currentLineIndex = -1;
    playUrls.clear();
    currentQuality = -1;
    qualites.clear();
    liveStatus.value = false;
    loadData();
  }

  /// 播放器初始化完成后挂影视进度订阅（保存/续播），并记录上次播放的集。
  @override
  Future<void> initializePlayer({bool isVod = false}) async {
    await super.initializePlayer(isVod: isVod);
    _bindVodProgressSubscriptions();
    _recordLastEpisode();
  }

  @override
  void onClose() {
    _roomDisposed = true;
    _preloadPlayUrlsFuture = null;
    _preloadPlayHeaders = null;
    _preloadQuality = null;
    _preloadConsumed = true;
    WidgetsBinding.instance.removeObserver(this);
    autoExitTimer?.cancel();
    _autoExitSession.stop();
    _clockTimer?.cancel();
    doubleClickTimer?.cancel();
    liveDanmaku.stop();
    _liveEventFlowTimer?.cancel();
    clearLiveEventFlow();
    _tvVodPositionSub?.cancel();
    _tvVodDurationSub?.cancel();

    danmakuController = null;
    super.onClose();
  }
}
