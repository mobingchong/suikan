import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:auto_orientation_v2/auto_orientation_v2.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:floating/floating.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/custom_throttle.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/services/background_playback_service.dart';
import 'package:simple_live_app/services/ios_video_output_size.dart';
import 'package:simple_live_app/services/media_control_service.dart';
import 'package:simple_live_app/services/mpv_options_service.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

const _windowsChromeChannel = MethodChannel('simple_live/windows_chrome');
const _androidWindowChannel = MethodChannel('simple_live/app_window');
const liveRoomVolumeSliderDialogTag = 'live_room_volume_slider';
int _androidWindowHandlerGeneration = 0;

/// Android OEMs do not use one consistent windowing mode for their system
/// floating windows: some report freeform, while others only report
/// multi-window. Both keep the app outside the normal fullscreen task.
bool isAndroidExternalPlayerWindow({
  required bool inPip,
  required bool inMultiWindow,
  required bool isFreeform,
}) {
  return !inPip && (inMultiWindow || isFreeform);
}

/// Android 16 ignores orientation requests on large displays. Use the full
/// display, rather than a letterboxed or freeform Flutter view, so tablets do
/// not inherit a phone-only orientation policy.
bool shouldUseAndroidPhoneOrientationPolicy({
  required double displayWidth,
  required double displayHeight,
  required double devicePixelRatio,
}) {
  if (!displayWidth.isFinite ||
      !displayHeight.isFinite ||
      !devicePixelRatio.isFinite ||
      displayWidth <= 0 ||
      displayHeight <= 0 ||
      devicePixelRatio <= 0) {
    return false;
  }
  return math.min(displayWidth, displayHeight) / devicePixelRatio < 600;
}

bool shouldRequestLandscapeForAndroidExternalWindow({
  required bool inPip,
  required bool inMultiWindow,
  required bool isFreeform,
  required bool playerFullscreen,
  required bool isVerticalVideo,
  required bool canLockOrientation,
}) {
  return isAndroidExternalPlayerWindow(
        inPip: inPip,
        inMultiWindow: inMultiWindow,
        isFreeform: isFreeform,
      ) &&
      playerFullscreen &&
      !isVerticalVideo &&
      canLockOrientation;
}

bool shouldRestoreAndroidFullscreenAfterExternalWindowExit({
  required bool wasInExternalWindow,
  required bool isInExternalWindow,
  required bool playerFullscreen,
  required bool hasPendingLandscapeRequest,
  required bool isVerticalVideo,
  required bool canLockOrientation,
}) {
  return wasInExternalWindow &&
      !isInExternalWindow &&
      playerFullscreen &&
      hasPendingLandscapeRequest &&
      !isVerticalVideo &&
      canLockOrientation;
}

class _DanmakuReplayEntry {
  final String message;
  final Color color;
  final List<String>? imageUrls;
  final List<DanmakuContentPart>? parts;
  final DateTime visibleFrom;
  final DateTime visibleUntil;

  const _DanmakuReplayEntry({
    required this.message,
    required this.color,
    this.imageUrls,
    this.parts,
    required this.visibleFrom,
    required this.visibleUntil,
  });

  bool isVisibleAt(DateTime now) {
    return !now.isBefore(visibleFrom) && now.isBefore(visibleUntil);
  }
}

const int _kDanmakuReplayLimit = 300;

mixin PlayerMixin {
  bool _playerInitialized = false;
  GlobalKey<VideoState> globalPlayerKey = GlobalKey<VideoState>();
  GlobalKey globalDanmuKey = GlobalKey();

  /// 播放器实例
  late final player = Player(
    configuration: PlayerConfiguration(
      title: "随看",
      logLevel: AppSettingsController.instance.logEnable.value
          ? MPVLogLevel.info
          : MPVLogLevel.error,
    ),
  );

  /// 当前 mpv 视频轨是否被停用（即 `vid=no`，对应 [setAudioOnlyMode]）。
  ///
  /// [setAudioOnlyMode] 原来只写 mpv 属性、不留任何 Dart 状态，于是没有任何
  /// 地方能判断「现在是不是纯音频」，Surface 健康检查只能靠 `width` 是否为
  /// null 来猜。补上这个状态后检查才能准确短路。
  ///
  /// 声明在 [PlayerMixin] 而不是 [PlayerController]：[setAudioOnlyMode] 就在
  /// 这个 mixin 里，mixin 引用不到宿主类的私有成员，而宿主类可以引用 mixin
  /// 的成员（同一 library 内私有可见），所以放这里两边都能用。
  bool _audioOnlyMode = false;

  /// 当前是否是「没有画面可恢复」的纯音频播放。
  ///
  /// **只认 [_audioOnlyMode]**（mpv `vid` 的实际状态），刻意不把
  /// [_autoAudioOnlyActivated] 也算进来，原因有两个：
  /// ① 那是「探测状态」不是「播放器状态」，用它判断有没有画面并不精确；
  ///    自动纯音频的所有路径最终都会调 [setAudioOnlyMode]，这里已覆盖。
  /// ② 它存在一个弱网误判且**不会自愈**的场景：4 秒探测期内没解出视频参数
  ///    就会被判成纯音频并锁定，之后视频轨出现也不会撤销。若把它算进守卫，
  ///    误判后 Surface 失效将永久无法恢复（黑屏卡死）；只看 [_audioOnlyMode]
  ///    则只要 vid 回到 auto，守卫就自动失效。
  ///
  /// 判定纯音频用这个 getter，不要再用 `width == null` 反推 —— 详见
  /// [_hasInvalidVideoSize] 上的说明。
  bool get _isAudioOnlyPlayback => _audioOnlyMode;

  /// 纯音频模式：停用/恢复视频轨道（mpv vid=no / auto），直播与影视一视同仁。
  /// 停轨后只解码音频，视频解码与渲染开销全部省掉。
  /// 恢复时调用方需负责让画面回来：影视切回 auto 即出画面，
  /// 直播需重新开一次流（见 LiveRoomController._restoreVideoTrack）。
  Future<void> setAudioOnlyMode(bool enable) async {
    try {
      final native = player.platform as NativePlayer;
      await native.setProperty('vid', enable ? 'no' : 'auto');
      // 只在属性确实设成功之后才记状态：这个标志一旦为 true，Surface 健康
      // 检查就会短路。记错（比如设失败了却记成 true）等于把真正的 Surface
      // 失效也一起放过，比漏记危险得多。
      _audioOnlyMode = enable;
    } catch (e) {
      Log.d('setAudioOnlyMode($enable) error: $e');
    }
  }

  /// 初始化播放器并设置静态 mpv 参数。
  Future<void> initializePlayer({bool isVod = false}) async {
    if (_playerInitialized) {
      return;
    }
    _playerInitialized = true;
    await MpvOptionsService.applyToPlayer(player, isVod: isVod);
    final nativePlayer = player.platform as NativePlayer;
    // 设置音频输出驱动
    if (AppSettingsController.instance.customPlayerOutput.value) {
      if (player.platform is NativePlayer) {
        await (player.platform as dynamic).setProperty(
          'ao',
          AppSettingsController.instance.audioOutputDriver.value,
        );
      }
    }
    // media_kit 仓库更新导致的问题，临时解决办法
    if (Platform.isAndroid) {
      await nativePlayer.setProperty('force-seekable', 'yes');
    }
  }

  /// 视频控制器
  late final videoController = VideoController(
    player,
    configuration: MpvOptionsService.videoControllerConfiguration(),
  );
}

mixin PlayerStateMixin on PlayerMixin {
  bool _playerClosing = false;

  ///音量控制条计时器
  Timer? hidevolumeTimer;

  /// 是否进入桌面端小窗
  RxBool smallWindowState = false.obs;

  /// 是否显示弹幕
  RxBool showDanmakuState = false.obs;

  RxBool mutedState = false.obs;
  double _volumeBeforeMute = 100.0;

  void onPlayerWindowModeExited() {}

  /// 是否显示控制器
  RxBool showControlsState = false.obs;

  RxBool hideMouseCursorState = false.obs;

  /// 是否显示设置窗口
  RxBool showSettingState = false.obs;

  /// 是否显示弹幕设置窗口
  RxBool showDanmakuSettingState = false.obs;

  /// 是否处于锁定控制器状态
  RxBool lockControlsState = false.obs;
  RxBool showLockEdgeState = false.obs;

  /// 是否处于全屏状态
  RxBool fullScreenState = false.obs;

  /// Android 系统窗口状态。系统分屏/自由窗和应用自己的小窗是两套状态，
  /// 不能用 [smallWindowState] 互相代替。
  RxBool androidInPipState = false.obs;
  RxBool androidInMultiWindowState = false.obs;
  RxBool androidFreeformState = false.obs;

  /// 显示手势Tip
  RxBool showGestureTip = false.obs;

  /// 手势Tip文本
  RxString gestureTipText = "".obs;

  /// 显示提示底部Tip
  RxBool showBottomTip = false.obs;

  /// 提示底部Tip文本
  RxString bottomTipText = "".obs;

  /// 自动隐藏控制器计时器
  Timer? hideControlsTimer;

  /// 音量滑条浮层正在显示，播放器底层鼠标离开时不能隐藏控制器。
  bool volumeSliderVisible = false;

  /// 自动隐藏鼠标光标计时器
  Timer? hideMouseCursorTimer;

  Timer? _mobileLockRevealTimer;

  /// 自动隐藏提示计时器
  Timer? hideSeekTipTimer;

  /// 是否为竖屏直播间
  var isVertical = false.obs;

  RxInt danmakuViewVersion = 0.obs;

  var showQualites = false.obs;
  var showLines = false.obs;

  bool get useBottomSheetPlayerMenus =>
      (Platform.isAndroid || Platform.isIOS) && !fullScreenState.value;

  bool get isPlayerClosing => _playerClosing;

  Timer? _gestureTipTimer;

  void showGestureTipText(String text) {
    final value = text.trim();
    if (value.isEmpty || _playerClosing) {
      return;
    }
    gestureTipText.value = value;
    showGestureTip.value = true;
    _gestureTipTimer?.cancel();
    _gestureTipTimer = Timer(const Duration(seconds: 2), clearGestureTip);
  }

  void clearGestureTip() {
    _gestureTipTimer?.cancel();
    _gestureTipTimer = null;
    showGestureTip.value = false;
    gestureTipText.value = "";
  }

  void clearTransientPlayerOverlays() {
    clearGestureTip();
    cancelVerticalDrag();
    _mobileLockRevealTimer?.cancel();
    _mobileLockRevealTimer = null;
    showLockEdgeState.value = false;
    hidevolumeTimer?.cancel();
    hidevolumeTimer = null;
    volumeSliderVisible = false;
    SmartDialog.dismiss(tag: liveRoomVolumeSliderDialogTag);
  }

  void cancelVerticalDrag() {}

  /// 隐藏控制器
  void hideControls() {
    clearTransientPlayerOverlays();
    showControlsState.value = false;
    hideControlsTimer?.cancel();
    hideMouseCursor();
  }

  void setLockState() {
    clearGestureTip();
    _mobileLockRevealTimer?.cancel();
    _mobileLockRevealTimer = null;
    lockControlsState.value = !lockControlsState.value;
    showLockEdgeState.value = false;
    if (lockControlsState.value) {
      showControlsState.value = false;
    } else {
      showControlsState.value = true;
    }
  }

  void revealMobileLockControls() {
    // The lock overlay is used by every full-screen target. On desktop the
    // previous edge-hover-only path made the unlock button unreachable when a
    // trackpad/mouse click was the first interaction after locking.
    if (!lockControlsState.value) {
      return;
    }
    showLockEdgeState.value = true;
    _mobileLockRevealTimer?.cancel();
    _mobileLockRevealTimer = Timer(const Duration(seconds: 3), () {
      if (lockControlsState.value) {
        showLockEdgeState.value = false;
      }
    });
  }

  /// 显示控制器
  void showControls() {
    showControlsState.value = true;
    showMouseCursor();
    resetHideControlsTimer();
    resetHideMouseCursorTimer();
  }

  /// 显示鼠标光标
  void showMouseCursor() {
    if (!Platform.isWindows) {
      return;
    }
    hideMouseCursorTimer?.cancel();
    hideMouseCursorState.value = false;
  }

  /// 隐藏鼠标光标
  void hideMouseCursor() {
    if (!Platform.isWindows) {
      return;
    }
    hideMouseCursorTimer?.cancel();
    hideMouseCursorState.value = true;
  }

  /// 开始隐藏控制器计时
  /// - 当点击控制器上时功能时需要重新计时
  void resetHideControlsTimer() {
    hideControlsTimer?.cancel();

    hideControlsTimer = Timer(
      const Duration(
        seconds: 5,
      ),
      hideControls,
    );
  }

  /// 开始隐藏鼠标光标计时
  void resetHideMouseCursorTimer() {
    if (!Platform.isWindows) {
      return;
    }

    hideMouseCursorTimer?.cancel();
    hideMouseCursorTimer = Timer(
      const Duration(
        seconds: 5,
      ),
      hideMouseCursor,
    );
  }

  void updateScaleMode() {
    var boxFit = BoxFit.contain;
    double? aspectRatio;
    if (player.state.width != null && player.state.height != null) {
      aspectRatio = player.state.width! / player.state.height!;
    }

    if (AppSettingsController.instance.scaleMode.value == 0) {
      boxFit = BoxFit.contain;
    } else if (AppSettingsController.instance.scaleMode.value == 1) {
      boxFit = BoxFit.fill;
    } else if (AppSettingsController.instance.scaleMode.value == 2) {
      boxFit = BoxFit.cover;
    } else if (AppSettingsController.instance.scaleMode.value == 3) {
      boxFit = BoxFit.contain;
      aspectRatio = 16 / 9;
    } else if (AppSettingsController.instance.scaleMode.value == 4) {
      boxFit = BoxFit.contain;
      aspectRatio = 4 / 3;
    }
    globalPlayerKey.currentState?.update(
      aspectRatio: aspectRatio,
      fit: boxFit,
    );
  }
}
mixin PlayerDanmakuMixin on PlayerStateMixin {
  /// 弹幕控制器
  DanmakuController? danmakuController;
  final List<_DanmakuReplayEntry> _danmakuReplayHistory = [];
  bool _danmakuReplayScheduled = false;

  void initDanmakuController(DanmakuController e) {
    danmakuController = e;
    // danmakuController?.updateOption(
    //   DanmakuOption(
    //     fontSize: AppSettingsController.instance.danmuSize.value,
    //     area: AppSettingsController.instance.danmuArea.value,
    //     duration: AppSettingsController.instance.danmuSpeed.value,
    //     opacity: AppSettingsController.instance.danmuOpacity.value,
    //     strokeWidth: AppSettingsController.instance.danmuStrokeWidth.value,
    //     fontWeight: FontWeight
    //         .values[AppSettingsController.instance.danmuFontWeight.value],
    //   ),
    // );
  }

  void updateDanmuOption(DanmakuOption? option) {
    if (danmakuController == null || option == null) return;
    danmakuController!.updateOption(option);
  }

  void disposeDanmakuController() {
    danmakuController?.clear();
    danmakuController = null;
  }

  void setDanmakuVisible(bool visible) {
    if (showDanmakuState.value == visible) {
      return;
    }
    showDanmakuState.value = visible;
    if (visible) {
      danmakuController?.resume();
    } else {
      // 先 clear 再 pause：pause() 只停动画和定时器，不会释放已存在的弹幕，
      // 而每条 DanmakuItem 都持有 Paragraph / strokeParagraph（Skia native
      // 内存，Dart GC 管不到），热门房一屏能堆上百条。
      // 副作用：重开弹幕从空屏开始（原来会残留关闭前那一屏继续飘完）。
      danmakuController?.clear();
      danmakuController?.pause();
    }
  }

  void clearDanmakuReplayHistory() {
    _danmakuReplayHistory.clear();
  }

  void rememberDanmakuReplay(
    String message,
    Color color, {
    Duration delay = Duration.zero,
    List<String>? imageUrls,
    List<DanmakuContentPart>? parts,
  }) {
    var durationSeconds =
        AppSettingsController.instance.danmuSpeed.value.toInt();
    if (durationSeconds < 1) {
      durationSeconds = 1;
    }

    final visibleFrom = DateTime.now().add(delay);
    _danmakuReplayHistory.add(
      _DanmakuReplayEntry(
        message: message,
        color: color,
        imageUrls: imageUrls,
        parts: parts,
        visibleFrom: visibleFrom,
        visibleUntil: visibleFrom.add(Duration(seconds: durationSeconds)),
      ),
    );
    _pruneDanmakuReplayHistory();
  }

  void _pruneDanmakuReplayHistory([DateTime? now]) {
    final current = now ?? DateTime.now();
    _danmakuReplayHistory.removeWhere(
      (item) => !item.visibleUntil.isAfter(current),
    );
    if (_danmakuReplayHistory.length > _kDanmakuReplayLimit) {
      _danmakuReplayHistory.removeRange(
        0,
        _danmakuReplayHistory.length - _kDanmakuReplayLimit,
      );
    }
  }

  void _scheduleDanmakuReplay() {
    if (_danmakuReplayScheduled) {
      return;
    }
    _danmakuReplayScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _danmakuReplayScheduled = false;
      _replayDanmakuOverlay();
    });
  }

  void _replayDanmakuOverlay() {
    if (!showDanmakuState.value ||
        AppSettingsController.instance.danmuLineCount.value <= 0 ||
        danmakuController == null) {
      return;
    }
    final now = DateTime.now();
    _pruneDanmakuReplayHistory(now);
    for (final item in _danmakuReplayHistory) {
      if (!item.isVisibleAt(now)) {
        continue;
      }
      danmakuController?.addDanmaku(
        DanmakuContentItem(
          item.message,
          color: item.color,
          imageUrls: item.imageUrls,
          parts: item.parts,
        ),
      );
    }
  }

  void rebuildDanmakuView({bool clearCurrent = true}) {
    if (clearCurrent) {
      danmakuController?.clear();
    }
    globalDanmuKey = GlobalKey();
    danmakuViewVersion.value += 1;
    _scheduleDanmakuReplay();
  }

  void addDanmaku(List<DanmakuContentItem> items) {
    if (!showDanmakuState.value ||
        AppSettingsController.instance.danmuLineCount.value <= 0) {
      return;
    }
    for (var item in items) {
      danmakuController?.addDanmaku(item);
    }
  }
}
mixin PlayerSystemMixin on PlayerMixin, PlayerStateMixin, PlayerDanmakuMixin {
  final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();

  final pip = Floating();
  StreamSubscription<PiPStatus>? _pipSubscription;
  bool _androidWindowChannelActive = false;
  int? _androidWindowHandlerToken;
  bool _mobileSystemUiApplied = false;
  int _systemLifecycleGeneration = 0;
  bool _androidLandscapePendingAfterExternalWindow = false;
  int _androidExternalWindowExitGeneration = 0;

  //final VolumeController volumeController = VolumeController();

  /// 初始化一些系统状态
  Future<void> initSystem() async {
    final generation = ++_systemLifecycleGeneration;
    if (Platform.isAndroid) {
      await _initializeAndroidWindowState();
    }
    if (_playerClosing || generation != _systemLifecycleGeneration) {
      return;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      VolumeController.instance.showSystemUI = false;
    }

    // 屏幕常亮
    //WakelockPlus.enable();

    // 开始隐藏计时
    resetHideControlsTimer();

    // 进入全屏模式
    if (AppSettingsController.instance.autoFullScreen.value) {
      await enterFullScreen();
    }
  }

  /// 释放一些系统状态
  Future resetSystem() async {
    _systemLifecycleGeneration += 1;
    final hadAndroidExternalLandscape =
        Platform.isAndroid && _androidLandscapePendingAfterExternalWindow;
    _androidLandscapePendingAfterExternalWindow = false;
    _androidExternalWindowExitGeneration += 1;
    _pipSubscription?.cancel();
    if (Platform.isAndroid && _androidWindowChannelActive) {
      final token = _androidWindowHandlerToken;
      _androidWindowChannelActive = false;
      _androidWindowHandlerToken = null;
      if (token != null && token == _androidWindowHandlerGeneration) {
        _androidWindowChannel.setMethodCallHandler(null);
      }
    }
    //pip.dispose();
    if (_mobileSystemUiApplied) {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.edgeToEdge,
        overlays: SystemUiOverlay.values,
      );
      await resetPreferredOrientation();
      _mobileSystemUiApplied = false;
    } else if (hadAndroidExternalLandscape) {
      await resetPreferredOrientation();
    }
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      // 亮度重置,桌面平台可能会报错,暂时不处理桌面平台的亮度
      try {
        await ScreenBrightness.instance.resetApplicationScreenBrightness();
      } catch (e) {
        Log.logPrint(e);
      }
    }

    await WakelockPlus.disable();
  }

  /// 进入全屏
  Future<void> enterFullScreen() async {
    clearTransientPlayerOverlays();
    if (smallWindowState.value) {
      await exitSmallWindow();
      return;
    }
    fullScreenState.value = true;
    if (Platform.isAndroid || Platform.isIOS) {
      if (Platform.isAndroid) {
        await _refreshAndroidWindowState();
        final canLockAndroidOrientation =
            _shouldUseAndroidPhoneOrientationPolicy();
        final isExternalWindow = isAndroidExternalPlayerWindow(
          inPip: androidInPipState.value,
          inMultiWindow: androidInMultiWindowState.value,
          isFreeform: androidFreeformState.value,
        );
        if (isExternalWindow) {
          // A system freeform/split window owns its bounds. Only switch the
          // Flutter page to the player and leave its system bars alone. Some
          // OEM freeform windows are only reported as multi-window, but both
          // modes can honour an orientation request. Do not leave a landscape
          // stream trapped in the portrait floating window.
          _androidLandscapePendingAfterExternalWindow =
              canLockAndroidOrientation && !isVertical.value;
          if (shouldRequestLandscapeForAndroidExternalWindow(
            inPip: androidInPipState.value,
            inMultiWindow: androidInMultiWindowState.value,
            isFreeform: androidFreeformState.value,
            playerFullscreen: fullScreenState.value,
            isVerticalVideo: isVertical.value,
            canLockOrientation: canLockAndroidOrientation,
          )) {
            await setLandscapeOrientation();
          }
          return;
        }
        _androidLandscapePendingAfterExternalWindow = false;
      }
      //全屏
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: [],
      );
      _mobileSystemUiApplied = true;
      if (!isVertical.value &&
          (!Platform.isAndroid || _shouldUseAndroidPhoneOrientationPolicy())) {
        //横屏
        await setLandscapeOrientation();
      }
    } else {
      _windowMaximizedBeforeFullScreen = await windowManager.isMaximized();
      await _applyWindowsFullScreenChrome();
      await windowManager.setFullScreen(true);
      await _waitForWindowsFullScreenState(true);
      await _applyWindowsFullScreenChrome();
      unawaited(
        Future.delayed(const Duration(milliseconds: 900), () async {
          if (!fullScreenState.value || smallWindowState.value) {
            return;
          }
          await _applyWindowsFullScreenChrome();
        }),
      );
      await Future.delayed(const Duration(milliseconds: 32));
    }
    //danmakuController?.clear();
  }

  Future<void> toggleFullScreen() async {
    if (fullScreenState.value || smallWindowState.value) {
      await exitPlayerWindowMode();
    } else {
      await enterFullScreen();
    }
  }

  /// 退出全屏
  Future<void> exitFull() async {
    clearTransientPlayerOverlays();
    final hadAndroidExternalLandscape =
        Platform.isAndroid && _androidLandscapePendingAfterExternalWindow;
    _androidLandscapePendingAfterExternalWindow = false;
    _androidExternalWindowExitGeneration += 1;
    if (smallWindowState.value) {
      await exitSmallWindow();
      return;
    }
    if (Platform.isAndroid) {
      // Clear this before asking Android for updated window state. OEM freeform
      // callbacks can arrive while fullscreen is being dismissed; retaining the
      // old value lets the callback re-apply landscape after it was restored.
      fullScreenState.value = false;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      if (Platform.isAndroid) {
        await _refreshAndroidWindowState();
      }
      if (_mobileSystemUiApplied) {
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.edgeToEdge,
          overlays: SystemUiOverlay.values,
        );
        await resetPreferredOrientation();
        _mobileSystemUiApplied = false;
        await Future.delayed(const Duration(milliseconds: 32));
      } else if (Platform.isAndroid && hadAndroidExternalLandscape) {
        // The system window owned its bars, but the landscape preference was
        // still applied to the activity. Return to the regular policy.
        await resetPreferredOrientation();
      }
    } else {
      await windowManager.setFullScreen(false);
      await _waitForWindowsFullScreenState(false);
      await _restoreWindowsWindowChrome();
      await _refreshWindowsWindowBounds();
      if (_windowMaximizedBeforeFullScreen) {
        await windowManager.maximize();
        await _waitForWindowMaximizedState(true);
      }
      _windowMaximizedBeforeFullScreen = false;
    }
    if (!Platform.isAndroid) {
      fullScreenState.value = false;
    }
    onPlayerWindowModeExited();

    //danmakuController?.clear();
  }

  Size? _lastWindowSize;
  Offset? _lastWindowPosition;
  bool _windowMaximizedBeforeFullScreen = false;
  bool _windowMaximizedBeforeSmallWindow = false;

  Future<void> _waitForWindowMaximizedState(bool value) async {
    if (!Platform.isWindows) {
      return;
    }

    final deadline = DateTime.now().add(const Duration(milliseconds: 600));
    while (DateTime.now().isBefore(deadline)) {
      if (await windowManager.isMaximized() == value) {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 16));
    }
  }

  Future<void> _waitForWindowsFullScreenState(bool value) async {
    if (!Platform.isWindows) {
      await Future.delayed(const Duration(milliseconds: 16));
      return;
    }

    final deadline = DateTime.now().add(const Duration(milliseconds: 800));
    while (DateTime.now().isBefore(deadline)) {
      if (await windowManager.isFullScreen() == value) {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 16));
    }
  }

  Future<void> _waitForWindowBoundsToChange(Rect previousBounds) async {
    if (!Platform.isWindows) {
      return;
    }

    final deadline = DateTime.now().add(const Duration(milliseconds: 800));
    while (DateTime.now().isBefore(deadline)) {
      final currentBounds = await windowManager.getBounds();
      final moved = (currentBounds.left - previousBounds.left).abs() > 0.5 ||
          (currentBounds.top - previousBounds.top).abs() > 0.5 ||
          (currentBounds.width - previousBounds.width).abs() > 0.5 ||
          (currentBounds.height - previousBounds.height).abs() > 0.5;
      if (moved) {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 16));
    }
  }

  Future<void> _refreshWindowsWindowBounds() async {
    if (!Platform.isWindows) {
      return;
    }

    try {
      final size = await windowManager.getSize();
      if (size.width <= 1 || size.height <= 1) {
        return;
      }
      final nudgedSize = Size(size.width + 1, size.height + 1);
      await windowManager.setSize(nudgedSize);
      await windowManager.setSize(size);
    } catch (e) {
      Log.logPrint(e);
    }
  }

  Future<void> _applyWindowsFullScreenChrome() async {
    if (!Platform.isWindows) {
      return;
    }

    try {
      await _windowsChromeChannel.invokeMethod<void>('apply');
    } catch (e) {
      Log.logPrint(e);
    }
  }

  ///小窗模式()
  Future<void> _restoreWindowsWindowChrome() async {
    if (!Platform.isWindows) {
      return;
    }

    try {
      await _windowsChromeChannel.invokeMethod<void>('restore');
    } catch (e) {
      Log.logPrint(e);
    }
  }

  Future<void> enterSmallWindow() async {
    clearTransientPlayerOverlays();
    if (Platform.isAndroid || Platform.isIOS || smallWindowState.value) {
      return;
    }

    _windowMaximizedBeforeSmallWindow = await windowManager.isMaximized();
    if (_windowMaximizedBeforeSmallWindow) {
      final maximizedBounds = await windowManager.getBounds();
      await windowManager.restore();
      await _waitForWindowMaximizedState(false);
      await _waitForWindowBoundsToChange(maximizedBounds);
      await _refreshWindowsWindowBounds();
      await Future.delayed(const Duration(milliseconds: 120));
    }
    fullScreenState.value = true;
    smallWindowState.value = true;

    // 读取窗口大小
    _lastWindowSize = await windowManager.getSize();
    _lastWindowPosition = await windowManager.getPosition();

    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    // 获取视频窗口大小
    var width = player.state.width ?? 16;
    var height = player.state.height ?? 9;

    // 横屏还是竖屏
    if (height > width) {
      var aspectRatio = width / height;
      await windowManager.setSize(Size(400, 400 / aspectRatio));
    } else {
      var aspectRatio = height / width;
      await windowManager.setSize(Size(280 / aspectRatio, 280));
    }

    await windowManager.setAlwaysOnTop(true);
    danmakuController?.resume();
  }

  ///退出小窗模式()
  Future<void> exitSmallWindow() async {
    clearTransientPlayerOverlays();
    if (Platform.isAndroid || Platform.isIOS || !smallWindowState.value) {
      return;
    }

    fullScreenState.value = false;
    smallWindowState.value = false;
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    if (_lastWindowPosition != null) {
      await windowManager.setPosition(_lastWindowPosition!);
    }
    if (_lastWindowSize != null) {
      await windowManager.setSize(_lastWindowSize!);
    }
    if (_windowMaximizedBeforeSmallWindow) {
      await windowManager.maximize();
      await _waitForWindowMaximizedState(true);
    } else {
      await _refreshWindowsWindowBounds();
    }
    _windowMaximizedBeforeSmallWindow = false;
    danmakuController?.resume();
    onPlayerWindowModeExited();
    //windowManager.setAlignment(Alignment.center);
  }

  Future<void> exitPlayerWindowMode() async {
    if (smallWindowState.value) {
      await exitSmallWindow();
      return;
    }
    if (fullScreenState.value) {
      await exitFull();
    }
  }

  void toggleDanmakuByShortcut() {
    setDanmakuVisible(!showDanmakuState.value);
  }

  Future<void> toggleMute() async {
    if (mutedState.value) {
      final restoreVolume =
          _volumeBeforeMute <= 0 ? 100.0 : _volumeBeforeMute.clamp(0.0, 100.0);
      await setSessionPlayerVolume(restoreVolume);
      return;
    }
    _volumeBeforeMute = player.state.volume <= 0
        ? AppSettingsController.instance.playerVolume.value
        : player.state.volume;
    mutedState.value = true;
    await player.setVolume(0);
  }

  Future<void> setSessionPlayerVolume(
    double volume, {
    bool persist = false,
  }) async {
    final requestedValue = volume.clamp(0.0, 100.0).toDouble();
    final mobile = Platform.isAndroid || Platform.isIOS;
    final value = requestedValue <= 0 ? 0.0 : (mobile ? 100.0 : requestedValue);
    if (value <= 0) {
      mutedState.value = true;
      await player.setVolume(0);
    } else {
      mutedState.value = false;
      _volumeBeforeMute = value;
      await player.setVolume(value);
    }
    if (persist && !mobile) {
      AppSettingsController.instance.setPlayerVolume(requestedValue);
    }
  }

  Future<void> adjustDesktopPlayerVolume(int delta) async {
    if (delta == 0 || Platform.isAndroid || Platform.isIOS) {
      return;
    }
    final current = player.state.volume.clamp(0.0, 100.0).toDouble();
    final target = (current + delta).clamp(0.0, 100.0).toDouble();
    await setSessionPlayerVolume(target, persist: true);
    showGestureTipText("音量 ${target.round()}%");
  }

  bool _shouldUseAndroidPhoneOrientationPolicy() {
    if (!Platform.isAndroid) {
      return false;
    }
    final context = Get.context;
    final display = context == null ? null : View.maybeOf(context)?.display;
    final fallbackViews = WidgetsBinding.instance.platformDispatcher.views;
    final resolvedDisplay =
        display ?? (fallbackViews.isEmpty ? null : fallbackViews.first.display);
    if (resolvedDisplay == null) {
      // If the full display cannot be read, keep the system policy instead of
      // risking a tablet letterbox through a forced orientation.
      return false;
    }
    return shouldUseAndroidPhoneOrientationPolicy(
      displayWidth: resolvedDisplay.size.width,
      displayHeight: resolvedDisplay.size.height,
      devicePixelRatio: resolvedDisplay.devicePixelRatio,
    );
  }

  /// 设置横屏
  Future setLandscapeOrientation() async {
    if (await beforeIOS16()) {
      AutoOrientation.landscapeAutoMode();
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  /// 设置竖屏
  Future setPortraitOrientation() async {
    if (await beforeIOS16()) {
      AutoOrientation.portraitAutoMode();
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  /// Restore the orientation policy after leaving mobile fullscreen.
  /// Compact phones always return to portrait, including OEM-managed floating
  /// windows. Releasing the orientation instead can leave those tasks stuck in
  /// the landscape request used by fullscreen playback. Tablets keep the OS
  /// orientation policy so their layouts are not forced through portrait.
  Future resetPreferredOrientation() async {
    if (Platform.isIOS) {
      await setPortraitOrientation();
      return;
    }
    if (Platform.isAndroid) {
      if (_shouldUseAndroidPhoneOrientationPolicy()) {
        await setPortraitOrientation();
      } else {
        await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      }
      return;
    }
    if (await beforeIOS16()) {
      AutoOrientation.fullAutoMode();
    } else {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }

  /// 是否是IOS16以下
  Future<bool> beforeIOS16() async {
    if (Platform.isIOS) {
      var info = await deviceInfo.iosInfo;
      var version = info.systemVersion;
      var versionInt = int.tryParse(version.split('.').first) ?? 0;
      return versionInt < 16;
    } else {
      return false;
    }
  }

  /// 开启小窗播放前弹幕状态
  bool danmakuStateBeforePIP = false;
  bool _pipStateApplied = false;
  bool _autoPipOnLeaveConfigured = false;
  bool _autoPipReconfigureInFlight = false;
  bool _autoPipReconfigurePending = false;
  int? _autoPipConfiguredVideoWidth;
  int? _autoPipConfiguredVideoHeight;

  Rational _resolvePipAspectRatio() {
    final width = player.state.width ?? 0;
    final height = player.state.height ?? 0;
    if (width > 0 && height > 0) {
      final divisor = _greatestCommonDivisor(width, height);
      final numerator = width ~/ divisor;
      final denominator = height ~/ divisor;
      final ratio = numerator / denominator;
      if (ratio >= (1 / 2.39) && ratio <= 2.39) {
        return Rational(numerator, denominator);
      }
    }
    return height > width
        ? const Rational.vertical()
        : const Rational.landscape();
  }

  int _greatestCommonDivisor(int a, int b) {
    var left = a.abs();
    var right = b.abs();
    while (right != 0) {
      final remainder = left % right;
      left = right;
      right = remainder;
    }
    return left == 0 ? 1 : left;
  }

  math.Rectangle<int>? _buildPipSourceRectHint() {
    final context = globalPlayerKey.currentContext;
    if (context == null) {
      return null;
    }
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.hasSize ||
        renderObject.size.isEmpty) {
      return null;
    }
    final offset = renderObject.localToGlobal(Offset.zero);
    var sourceWidth = renderObject.size.width;
    var sourceHeight = renderObject.size.height;
    final videoWidth = player.state.width ?? 0;
    final videoHeight = player.state.height ?? 0;
    if (videoWidth > 0 && videoHeight > 0) {
      final videoRatio = videoWidth / videoHeight;
      final viewRatio = renderObject.size.width / renderObject.size.height;
      if (viewRatio > videoRatio) {
        sourceWidth = renderObject.size.height * videoRatio;
        sourceHeight = renderObject.size.height;
      } else {
        sourceWidth = renderObject.size.width;
        sourceHeight = renderObject.size.width / videoRatio;
      }
    }
    final sourceOffset = Offset(
      offset.dx + (renderObject.size.width - sourceWidth) / 2,
      offset.dy + (renderObject.size.height - sourceHeight) / 2,
    );
    final pixelRatio = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    return math.Rectangle<int>(
      (sourceOffset.dx * pixelRatio).round(),
      (sourceOffset.dy * pixelRatio).round(),
      math.max(1, (sourceWidth * pixelRatio).round()),
      math.max(1, (sourceHeight * pixelRatio).round()),
    );
  }

  Future<void> _initializeAndroidWindowState() async {
    if (!Platform.isAndroid || _androidWindowChannelActive) {
      return;
    }
    _androidWindowChannelActive = true;
    final token = ++_androidWindowHandlerGeneration;
    _androidWindowHandlerToken = token;
    _androidWindowChannel.setMethodCallHandler((call) async {
      if (!_androidWindowChannelActive ||
          _androidWindowHandlerToken != token ||
          call.method != 'windowStateChanged') {
        return null;
      }
      _applyAndroidWindowState(call.arguments);
      return null;
    });
    await _refreshAndroidWindowState();
  }

  Future<void> _refreshAndroidWindowState() async {
    if (!Platform.isAndroid || !_androidWindowChannelActive) {
      return;
    }
    final token = _androidWindowHandlerToken;
    try {
      final state = await _androidWindowChannel.invokeMethod<dynamic>(
        'getWindowState',
      );
      if (!_androidWindowChannelActive || _androidWindowHandlerToken != token) {
        return;
      }
      _applyAndroidWindowState(state);
    } catch (e) {
      Log.d("读取 Android 窗口状态失败：$e");
    }
  }

  void _applyAndroidWindowState(dynamic arguments) {
    if (arguments is! Map) {
      return;
    }
    final inPip = arguments['inPip'] == true;
    final inMultiWindow = arguments['inMultiWindow'] == true;
    final isFreeform = arguments['isFreeform'] == true;
    final wasInPip = androidInPipState.value;
    final wasInExternalWindow = isAndroidExternalPlayerWindow(
      inPip: wasInPip,
      inMultiWindow: androidInMultiWindowState.value,
      isFreeform: androidFreeformState.value,
    );
    final isInExternalWindow = isAndroidExternalPlayerWindow(
      inPip: inPip,
      inMultiWindow: inMultiWindow,
      isFreeform: isFreeform,
    );
    androidInPipState.value = inPip;
    androidInMultiWindowState.value = inMultiWindow;
    androidFreeformState.value = isFreeform;
    unawaited(_syncAndroidExternalWindowLandscapeOrientation());
    if (shouldRestoreAndroidFullscreenAfterExternalWindowExit(
      wasInExternalWindow: wasInExternalWindow,
      isInExternalWindow: isInExternalWindow,
      playerFullscreen: fullScreenState.value,
      hasPendingLandscapeRequest: _androidLandscapePendingAfterExternalWindow,
      isVerticalVideo: isVertical.value,
      canLockOrientation: _shouldUseAndroidPhoneOrientationPolicy(),
    )) {
      unawaited(_restoreAndroidFullscreenAfterExternalWindowExit());
    }
    if (inPip && !wasInPip) {
      _applyPipEnteredState();
    } else if (!inPip && wasInPip) {
      _restorePipExitedState();
    }
  }

  /// System floating windows are often created using the app's default
  /// portrait task orientation. Re-apply the active landscape player
  /// orientation as soon as Android reports the external-window transition.
  Future<void> _syncAndroidExternalWindowLandscapeOrientation() async {
    if (!Platform.isAndroid ||
        !shouldRequestLandscapeForAndroidExternalWindow(
          inPip: androidInPipState.value,
          inMultiWindow: androidInMultiWindowState.value,
          isFreeform: androidFreeformState.value,
          playerFullscreen: fullScreenState.value,
          isVerticalVideo: isVertical.value,
          canLockOrientation: _shouldUseAndroidPhoneOrientationPolicy(),
        )) {
      return;
    }
    try {
      await setLandscapeOrientation();
    } catch (e) {
      Log.d("系统自由窗请求横屏失败: $e");
    }
  }

  /// System-owned windows may ignore immersive mode while floating. Once the
  /// user expands that window, apply the fullscreen request again after the
  /// new task bounds have reached Flutter.
  Future<void> _restoreAndroidFullscreenAfterExternalWindowExit() async {
    final token = ++_androidExternalWindowExitGeneration;
    await Future.delayed(const Duration(milliseconds: 160));
    if (!Platform.isAndroid ||
        token != _androidExternalWindowExitGeneration ||
        !fullScreenState.value ||
        isVertical.value ||
        !_shouldUseAndroidPhoneOrientationPolicy() ||
        !_androidLandscapePendingAfterExternalWindow ||
        isAndroidExternalPlayerWindow(
          inPip: androidInPipState.value,
          inMultiWindow: androidInMultiWindowState.value,
          isFreeform: androidFreeformState.value,
        )) {
      return;
    }
    try {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: [],
      );
      _mobileSystemUiApplied = true;
      await setLandscapeOrientation();
      _androidLandscapePendingAfterExternalWindow = false;
    } catch (e) {
      Log.d("系统小窗展开后恢复横屏失败: $e");
    }
  }

  void _ensurePipStatusListener() {
    _pipSubscription ??= pip.pipStatusStream.listen((event) {
      if (event == PiPStatus.enabled) {
        _applyPipEnteredState();
      } else if (event == PiPStatus.disabled) {
        _restorePipExitedState();
      }
      Log.w(event.toString());
    });
  }

  void _applyPipEnteredState() {
    androidInPipState.value = true;
    if (_pipStateApplied) {
      return;
    }
    _pipStateApplied = true;
    danmakuStateBeforePIP = showDanmakuState.value;
    if (AppSettingsController.instance.pipHideDanmu.value &&
        danmakuStateBeforePIP) {
      setDanmakuVisible(false);
    }
    showControlsState.value = false;
  }

  void _restorePipExitedState() {
    androidInPipState.value = false;
    if (!_pipStateApplied && !_autoPipOnLeaveConfigured) {
      return;
    }
    _pipStateApplied = false;
    _autoPipOnLeaveConfigured = false;
    _autoPipConfiguredVideoWidth = null;
    _autoPipConfiguredVideoHeight = null;
    setDanmakuVisible(danmakuStateBeforePIP);
  }

  Future<void> cancelAutoPipOnLeave() async {
    if (!Platform.isAndroid) {
      return;
    }
    _autoPipOnLeaveConfigured = false;
    _autoPipReconfigurePending = false;
    try {
      await pip.cancelOnLeavePiP();
    } catch (e) {
      Log.d("取消自动小窗失败: $e");
    }
  }

  Future<bool> prepareAutoPipOnLeave() async {
    if (!Platform.isAndroid) {
      return _autoPipOnLeaveConfigured;
    }
    final videoWidth = player.state.width ?? 0;
    final videoHeight = player.state.height ?? 0;
    if (_autoPipOnLeaveConfigured &&
        videoWidth > 0 &&
        videoHeight > 0 &&
        _autoPipConfiguredVideoWidth == videoWidth &&
        _autoPipConfiguredVideoHeight == videoHeight) {
      return true;
    }
    if (await pip.isPipAvailable == false) {
      return false;
    }
    _ensurePipStatusListener();
    try {
      final status = await pip.enable(
        OnLeavePiP(
          aspectRatio: _resolvePipAspectRatio(),
          sourceRectHint: _buildPipSourceRectHint(),
        ),
      );
      if (status != PiPStatus.automatic && status != PiPStatus.enabled) {
        _autoPipOnLeaveConfigured = false;
        return false;
      }
      _autoPipOnLeaveConfigured = true;
      _autoPipConfiguredVideoWidth = videoWidth > 0 ? videoWidth : null;
      _autoPipConfiguredVideoHeight = videoHeight > 0 ? videoHeight : null;
      showControlsState.value = false;
      return true;
    } catch (e) {
      Log.d("配置退后台自动小窗失败: $e");
      return false;
    }
  }

  Future<void> refreshAutoPipOnVideoSize() async {
    if (!Platform.isAndroid || !_autoPipOnLeaveConfigured) {
      return;
    }
    if (_autoPipReconfigureInFlight) {
      _autoPipReconfigurePending = true;
      return;
    }
    _autoPipReconfigureInFlight = true;
    try {
      do {
        _autoPipReconfigurePending = false;
        if (!_autoPipOnLeaveConfigured) {
          break;
        }
        await prepareAutoPipOnLeave();
      } while (_autoPipReconfigurePending && _autoPipOnLeaveConfigured);
    } finally {
      _autoPipReconfigureInFlight = false;
      if (_autoPipReconfigurePending && _autoPipOnLeaveConfigured) {
        _autoPipReconfigurePending = false;
        unawaited(refreshAutoPipOnVideoSize());
      }
    }
  }

  Future enablePIP() async {
    if (!Platform.isAndroid) {
      SmartDialog.showToast("当前平台暂不支持小窗播放");
      return;
    }
    if (await pip.isPipAvailable == false) {
      SmartDialog.showToast("设备不支持小窗播放");
      return;
    }
    await cancelAutoPipOnLeave();
    _ensurePipStatusListener();
    final status = await pip.enable(
      ImmediatePiP(
        aspectRatio: _resolvePipAspectRatio(),
        sourceRectHint: _buildPipSourceRectHint(),
      ),
    );
    if (status != PiPStatus.enabled) {
      SmartDialog.showToast("进入小窗失败");
    }
  }
}
mixin PlayerGestureControlMixin
    on PlayerStateMixin, PlayerMixin, PlayerSystemMixin {
  /// 单击显示/隐藏控制器
  void onTap() {
    if (volumeSliderVisible) {
      return;
    }
    if (lockControlsState.value) {
      revealMobileLockControls();
      return;
    }
    if (showControlsState.value) {
      hideControls();
    } else {
      showControls();
    }
  }

  // 桌面端鼠标操控
  void onEnter(PointerEnterEvent event) {
    showMouseCursor();
    resetHideMouseCursorTimer();
    if (lockControlsState.value) {
      return;
    }
    if (!showControlsState.value) {
      showControls();
    }
  }

  void onExit(PointerExitEvent event) {
    hideMouseCursorTimer?.cancel();
    hideControlsTimer?.cancel();
    showLockEdgeState.value = false;
    if (volumeSliderVisible) {
      return;
    }
    if (lockControlsState.value) {
      return;
    }
    if (!showControlsState.value) {
      return;
    }
    hideControlsTimer = Timer(
      const Duration(milliseconds: 180),
      () {
        if (showControlsState.value) {
          hideControls();
        }
      },
    );
  }

  void onHover(PointerHoverEvent event, BuildContext context) {
    showMouseCursor();
    resetHideMouseCursorTimer();
    if (volumeSliderVisible) {
      return;
    }
    if (lockControlsState.value) {
      final width = context.size?.width ?? 0;
      showLockEdgeState.value = fullScreenState.value &&
          width > 0 &&
          (event.localPosition.dx <= 48 ||
              event.localPosition.dx >= width - 48);
      return;
    }
    resetHideControlsTimer();
    if (!showControlsState.value) {
      showControls();
    }
  }

  /// 双击全屏/退出全屏
  void onDoubleTap() {
    if (lockControlsState.value) {
      return;
    }
    clearTransientPlayerOverlays();
    if (smallWindowState.value) {
      exitSmallWindow();
    } else if (fullScreenState.value) {
      exitFull();
    } else {
      enterFullScreen();
    }
  }

  bool verticalDragging = false;
  bool leftVerticalDrag = false;
  var _currentVolume = 0.0;
  var _currentBrightness = 1.0;
  var verStartPosition = 0.0;
  var _verticalDragExtent = 1.0;
  var _useLocalDragPosition = false;
  var _verticalDragGeneration = 0;
  var _verticalDragReady = false;

  DelayedThrottle? throttle;

  @override
  void cancelVerticalDrag() {
    _verticalDragGeneration += 1;
    throttle?.cancel();
    throttle = null;
    verticalDragging = false;
    leftVerticalDrag = false;
    _useLocalDragPosition = false;
    _verticalDragReady = false;
  }

  /// 竖向手势开始
  Future<void> onVerticalDragStart(
    DragStartDetails details, {
    Size? viewportSize,
  }) async {
    clearGestureTip();
    // A new drag invalidates any pending system-volume/brightness read from
    // the previous drag before checking whether this gesture is usable.
    cancelVerticalDrag();
    showMouseCursor();
    resetHideMouseCursorTimer();
    if (lockControlsState.value && fullScreenState.value) {
      return;
    }
    if (!AppSettingsController.instance.playerGestureControlEnable.value) {
      return;
    }

    final width = viewportSize?.width ?? Get.width;
    final height = viewportSize?.height ?? Get.height;
    if (width <= 0 || height <= 0) {
      return;
    }
    final localX = details.localPosition.dx;
    final localY = details.localPosition.dy;
    if (Platform.isWindows || Platform.isLinux) {
      final sideGestureWidth = width * 0.28;
      if (localX > sideGestureWidth && localX < width - sideGestureWidth) {
        return;
      }
    }

    _useLocalDragPosition = viewportSize != null;
    final dy = _useLocalDragPosition ? localY : details.globalPosition.dy;
    // 开始位置必须是中间2/4的位置
    if (dy < height * 0.25 || dy > height * 0.75) {
      return;
    }

    verStartPosition = dy;
    _verticalDragExtent = math.max(height * 0.5, 1.0);
    leftVerticalDrag = localX < width / 2;

    throttle?.cancel();
    throttle = DelayedThrottle(
      200,
      onError: (error, stackTrace) {
        Log.e("调整系统音量失败: $error", stackTrace);
      },
    );
    lastVolume = -1;
    lastBrightness = -1;

    verticalDragging = true;
    _verticalDragReady = false;
    final dragGeneration = ++_verticalDragGeneration;
    double? initialVolume;
    var initialBrightness = 1.0;
    var volumeReadSucceeded = true;
    if (Platform.isWindows || Platform.isLinux) {
      final currentPlayerVolume = player.state.volume;
      if (currentPlayerVolume > 0) {
        initialVolume = currentPlayerVolume.clamp(0.0, 100.0) / 100;
      } else {
        initialVolume = AppSettingsController.instance.playerVolume.value
                .clamp(0.0, 100.0) /
            100;
      }
    } else if (Platform.isAndroid || Platform.isIOS) {
      try {
        initialVolume = await VolumeController.instance.getVolume();
      } catch (e, stackTrace) {
        volumeReadSucceeded = false;
        Log.e("读取系统音量失败: $e", stackTrace);
      }
    }
    if (Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux) {
      try {
        initialBrightness = await ScreenBrightness.instance.application;
      } catch (e, stackTrace) {
        Log.e("读取应用亮度失败: $e", stackTrace);
      }
    }
    if (dragGeneration != _verticalDragGeneration || !verticalDragging) {
      return;
    }
    if (!leftVerticalDrag && !volumeReadSucceeded) {
      // Do not calculate a new value from the previous gesture when the
      // system-volume read failed; the next gesture can retry the read.
      verticalDragging = false;
      return;
    }
    _currentVolume = initialVolume ?? _currentVolume;
    _currentBrightness = initialBrightness;
    _verticalDragReady = true;
  }

  /// 竖向手势更新
  void onVerticalDragUpdate(DragUpdateDetails e) async {
    if (lockControlsState.value && fullScreenState.value) {
      return;
    }
    if (!AppSettingsController.instance.playerGestureControlEnable.value) {
      return;
    }
    if (verticalDragging == false || !_verticalDragReady) return;
    if (!Platform.isAndroid &&
        !Platform.isIOS &&
        !Platform.isWindows &&
        !Platform.isLinux) {
      return;
    }
    //String text = "";
    //double value = 0.0;

    final dragPosition =
        _useLocalDragPosition ? e.localPosition.dy : e.globalPosition.dy;
    Log.logPrint("$verStartPosition/$dragPosition");

    if (leftVerticalDrag) {
      setGestureBrightness(dragPosition);
    } else {
      setGestureVolume(dragPosition);
    }
  }

  int lastVolume = -1; // it's ok to be -1
  int lastBrightness = -1; // it's ok to be -1

  void setGestureVolume(double dy) {
    double value = 0.0;
    double seek;
    if (dy > verStartPosition) {
      value = ((dy - verStartPosition) / _verticalDragExtent);

      seek = _currentVolume - value;
      if (seek < 0) {
        seek = 0;
      }
    } else {
      value = ((dy - verStartPosition) / _verticalDragExtent);
      seek = value.abs() + _currentVolume;
      if (seek > 1) {
        seek = 1;
      }
    }
    int volume = _convertVolume((seek * 100).round());
    if (volume == lastVolume) {
      return;
    }
    lastVolume = volume;
    // update UI outside throttle to make it more fluent
    showGestureTipText("音量 $volume%");
    throttle?.invoke(() async => await _realSetVolume(volume));
  }

  // 0 to 100, 5 step each
  int _convertVolume(int volume) {
    return (volume / 5).round() * 5;
  }

  Future<void> _realSetVolume(int volume) async {
    Log.logPrint(volume);
    if (Platform.isWindows || Platform.isLinux) {
      await setSessionPlayerVolume(volume.toDouble(), persist: true);
      return;
    }
    // 手势只调系统音量，播放器内部音量由独立设置控制。
    await VolumeController.instance.setVolume(volume / 100);
  }

  void setGestureBrightness(double dy) {
    double value = 0.0;
    double seek;
    if (dy > verStartPosition) {
      value = ((dy - verStartPosition) / _verticalDragExtent);

      seek = _currentBrightness - value;
      if (seek < 0) {
        seek = 0;
      }
    } else {
      value = ((dy - verStartPosition) / _verticalDragExtent);
      seek = value.abs() + _currentBrightness;
      if (seek > 1) {
        seek = 1;
      }
    }
    // 与音量路径（:1715-1722）同构的 5 档量化 + 去重。
    // 原来每次 update 都直调平台通道，一次 3 秒拖拽约 180 次调用；
    // 量化后一次手势最多 21 次，且重复值直接跳过。
    //
    // 这里**刻意不套 DelayedThrottle**：DelayedThrottle.cancel() 会丢弃
    // 暂存的那次调用（custom_throttle.dart:22），而 cancelVerticalDrag()
    // 在抬手时就会 cancel —— 快速松手会把最后一次亮度丢掉，
    // 停在错误的档位。量化后的调用次数已经足够低，逐个应用最稳。
    final int brightness = _convertBrightness((seek * 100).round());
    if (brightness == lastBrightness) {
      return;
    }
    lastBrightness = brightness;
    showGestureTipText("亮度 $brightness%");
    ScreenBrightness.instance.setApplicationScreenBrightness(brightness / 100);
  }

  // 0 to 100, 5 step each
  int _convertBrightness(int brightness) {
    return (brightness / 5).round() * 5;
  }

  /// 竖向手势完成
  void onVerticalDragEnd(DragEndDetails details) async {
    cancelVerticalDrag();
    clearGestureTip();
  }

  void onVerticalDragCancel() {
    cancelVerticalDrag();
    clearGestureTip();
  }
}

class PlayerController extends BaseController
    with
        PlayerMixin,
        PlayerStateMixin,
        PlayerDanmakuMixin,
        PlayerSystemMixin,
        PlayerGestureControlMixin {
  /// 播放恢复操作所属的加载代次。
  ///
  /// 普通播放器没有房间切换概念，使用固定代次；直播间控制器会覆盖此值，
  /// 让延迟重试在切换房间后自动失效。
  int get playbackLoadGeneration => 0;

  /// Changes whenever the current media is deliberately reopened.
  int get playbackMediaGeneration => 0;

  // 🔴 全局播放器串行门（2026-09-04）：
  // 直播间返回时 `onClose()` 是 fire-and-forget（_handleBack 不能 await，
  // 否则 pop 会卡住），旧播放器的 stop/dispose 链在后台要跑数百毫秒~数秒；
  // 若用户此时快速进另一个直播间，新房 player 立刻 open → 两个 Player
  // 并发操作 mpv（双实例纹理/解码器）→ native 竞态偶发崩，与「返回后再
  // 进直播间容易闪退」的现象吻合。
  // 新房 open 前先等旧播放器完全关闭（带超时，坏流关闭卡住不拖死新房）。
  static Completer<void>? _playerShutdownGate;

  static Future<void> _waitForOtherPlayerShutdown() async {
    final gate = _playerShutdownGate;
    if (gate == null) {
      return;
    }
    try {
      await gate.future.timeout(const Duration(seconds: 2));
    } catch (_) {
      // 旧播放器关闭超时：不阻塞新房（最坏退回老行为，不引入新故障）
    }
  }

  bool isPlaybackLoadGenerationCurrent(int generation) {
    return !_playerClosing && generation == playbackLoadGeneration;
  }

  Future<void>? _playbackOpenFuture;

  bool _isPlaybackOwnerCurrent(
    int loadGeneration,
    int mediaGeneration,
    bool Function()? isStillOwner,
  ) {
    return isPlaybackLoadGenerationCurrent(loadGeneration) &&
        mediaGeneration == playbackMediaGeneration &&
        (isStillOwner?.call() ?? true);
  }

  /// Serializes every media open so a stale recovery cannot finish after a
  /// newer room open and replace its media.
  Future<bool> openPlaybackMedia(
    Media media, {
    required int loadGeneration,
    required int mediaGeneration,
    bool Function()? isStillOwner,
    // 换直播间/换流时为 true：重置纯音频锁定，让新直播间重新探测
    // （否则从纯音频直播间切走会残留 vid=no 无画面）。
    // 同一直播间重连（mediaError/surface 恢复）保持 false 不打扰（2026-09-01）。
    bool resetAudioOnlyLock = false,
  }) async {
    // 等其它播放器（旧直播间）关闭完成，避免双 Player 并发 mpv 竞态崩。
    await _waitForOtherPlayerShutdown();
    while (true) {
      if (!_isPlaybackOwnerCurrent(
        loadGeneration,
        mediaGeneration,
        isStillOwner,
      )) {
        return false;
      }
      final activeOpen = _playbackOpenFuture;
      if (activeOpen == null) {
        break;
      }
      try {
        await activeOpen;
      } catch (e, stackTrace) {
        Log.e("等待旧媒体打开失败: $e", stackTrace);
      }
    }

    if (!_isPlaybackOwnerCurrent(
      loadGeneration,
      mediaGeneration,
      isStillOwner,
    )) {
      return false;
    }
    _surfaceRecoveryGraceUntil =
        DateTime.now().add(_surfaceRecoveryGraceDuration);
    // 换直播间时重置纯音频锁定（重新探测）；重连则保留锁定不打扰。
    if (resetAudioOnlyLock) {
      _autoAudioOnlyActivated = false;
      _audioOnlyProbeTimer?.cancel();
      _audioOnlyProbeTimer = null;
      // 🔴 vid=no 是 mpv 全局属性，换流后仍残留 → 新直播间视频轨被禁无画面
      // （"从纯音频直播间切走一直只有音频"真因，2026-09-01）。必须恢复视频轨。
      await setAudioOnlyMode(false);
    }
    final opening = Future<void>.microtask(() => player.open(media));
    _playbackOpenFuture = opening;
    try {
      await opening;
      _scheduleAudioOnlyProbe(loadGeneration, mediaGeneration);
      return _isPlaybackOwnerCurrent(
        loadGeneration,
        mediaGeneration,
        isStillOwner,
      );
    } finally {
      if (identical(_playbackOpenFuture, opening)) {
        _playbackOpenFuture = null;
      }
    }
  }

  /// 纯音频流探测：延迟检查视频轨是否始终未出现。
  /// 若 videoParams 为空但有音频轨 → 自动切 vid=no（音频链路，避免 mpv
  /// 按视频流处理纯音频源导致卡顿）。收到视频参数或用户已手动纯音频则放弃。
  /// **一旦识别为纯音频流（[_autoAudioOnlyActivated]）就锁定音频模式**：
  /// 直播纯音频源周期性重连（ifeng audio 约 30s）时直接保持 vid=no，
  /// 不再启动探测、不再弹提示（用户要求"只要是音频流就一直以音频流播放"）。
  ///
  /// 2026-09-04 修复误判：部分 HLS 直播源带 302 防盗链跳转，视频轨出帧
  /// 可能超过 4s（如 gfjs.m3u8 案例）。改为两级探测——首轮 4s 未出视频
  /// 不立即锁定，再给 4s 缓冲（共 8s），且任一时点 track-list 声明了
  /// 视频轨（[Tracks.video] 非空）即视为视频流，彻底避免慢起播误判。
  void _scheduleAudioOnlyProbe(int loadGeneration, int mediaGeneration) {
    // 本播放会话已识别为纯音频：不再探测，静默保持音频模式。
    if (_autoAudioOnlyActivated) {
      unawaited(setAudioOnlyMode(true));
      return;
    }
    _audioOnlyProbeTimer?.cancel();
    _audioOnlyProbeTimer = Timer(const Duration(seconds: 4), () {
      _audioOnlyProbeTimer = null;
      if (!_isPlaybackOwnerCurrent(
        loadGeneration,
        mediaGeneration,
        null,
      )) {
        return;
      }
      // 用户已手动开启纯音频，无需重复处理。
      if (AppSettingsController.instance.audioOnlyBackground.value) {
        return;
      }
      // 有视频尺寸（视频轨已出现）→ 正常视频流，不是纯音频。
      if (player.state.videoParams.w != null) {
        return;
      }
      // track-list 已声明视频轨（HLS 分片 PMT 解析出轨道、尚未出帧）→
      // 是视频流慢起播，不是纯音频：再给 4s 缓冲，避免 302 防盗链误判。
      if (player.state.tracks.video.isNotEmpty) {
        Log.d("纯音频探测：track-list 含视频轨，等待视频出帧…");
        _audioOnlyProbeTimer?.cancel();
        _audioOnlyProbeTimer = Timer(const Duration(seconds: 4), () {
          _audioOnlyProbeTimer = null;
          if (!_isPlaybackOwnerCurrent(
            loadGeneration,
            mediaGeneration,
            null,
          )) {
            return;
          }
          if (AppSettingsController.instance.audioOnlyBackground.value) {
            return;
          }
          if (player.state.videoParams.w != null) {
            return;
          }
          if (player.state.tracks.video.isNotEmpty) {
            Log.d("纯音频探测：8s 后 track-list 仍有视频轨但无画面，按视频流处理");
            return;
          }
          _lockAudioOnlyMode(loadGeneration, mediaGeneration);
        });
        return;
      }
      _lockAudioOnlyMode(loadGeneration, mediaGeneration);
    });
  }

  Future<void> _lockAudioOnlyMode(int loadGeneration, int mediaGeneration) async {
    if (!_isPlaybackOwnerCurrent(loadGeneration, mediaGeneration, null)) {
      return;
    }
    Log.d("检测到纯音频流（无视频轨），锁定音频模式");
    _autoAudioOnlyActivated = true;
    SmartDialog.showToast("该源为纯音频流，已自动切换音频模式");
    unawaited(setAudioOnlyMode(true));
  }

  Future<void> waitForPlaybackOpen() async {
    final activeOpen = _playbackOpenFuture;
    if (activeOpen == null) {
      return;
    }
    try {
      // 限时等待：open 可能卡在慢源/坏源的网络阶段（mpv/opener 线程）。
      // close 路径不能无限等——用户已离开页面，继续等只会让后续播放器
      // 一直排队（串行门 2s 超时后放行，又会制造双 mpv 并发）。
      // 超时后由调用方执行 player.stop() 中断进行中的 open。
      await activeOpen.timeout(const Duration(milliseconds: 1500));
    } catch (e, stackTrace) {
      Log.e("等待媒体打开结束超时/失败: $e", stackTrace);
    }
  }

  @override
  void onInit() {
    unawaited(initSystem());
    initStream();
    //设置音量
    player.setVolume(_resolvedPlayerVolume());
    super.onInit();
  }

  StreamSubscription<String>? _errorSubscription;
  StreamSubscription? _completedSubscription;
  StreamSubscription? _widthSubscription;
  StreamSubscription? _heightSubscription;
  StreamSubscription<VideoParams>? _videoParamsSubscription;
  StreamSubscription<Tracks>? _tracksSubscription;
  StreamSubscription? _logSubscription;
  StreamSubscription? _playingSubscription;
  /// iOS 音频中断（来电/闹钟）前的播放状态，用于中断结束后恢复
  bool _lastPlayingState = false;
  MethodChannel? _iosAudioChannel;
  Timer? _iosVideoOutputSyncTimer;
  Worker? _iosOriginalQualityPowerSavingWorker;
  Worker? _iosRenderCapWorker;
  Worker? _allowBackgroundWorker;
  Worker? _audioOnlyWorker;
  IosVideoOutputSize? _iosVideoOutputSize;
  int? _iosVideoSourceWidth;
  int? _iosVideoSourceHeight;
  bool _iosVideoOutputForceApply = false;

  /// 纯音频流自动识别（2026-08-31 新增）：
  /// 部分直播源本身只有音频轨（如 ifeng 的 _audio 流，TS 内无视频 PID），
  /// mpv 按视频流对待会缓冲/解码错配导致卡顿。加载后延迟探测一次：
  /// videoParams 始终为空且有音频轨 → 判定纯音频流 → 自动 vid=no 走音频链路。
  Timer? _audioOnlyProbeTimer;
  /// 已自动进入纯音频模式（本次播放会话内只提示一次，重连不再打扰）。
  bool _autoAudioOnlyActivated = false;

  String get videoOutputResolution {
    final output = _iosVideoOutputSize;
    if (output != null) {
      return output.toString();
    }
    return '${player.state.width ?? 0}x${player.state.height ?? 0}';
  }

  void _handleVideoParamsForIosOutput(VideoParams params) {
    var width = params.dw ?? params.w ?? player.state.width;
    var height = params.dh ?? params.h ?? player.state.height;
    final rotate = params.rotate ?? 0;
    if (rotate % 180 != 0) {
      final originalWidth = width;
      width = height;
      height = originalWidth;
    }
    _scheduleIosVideoOutputSync(
      sourceWidth: width,
      sourceHeight: height,
      force: true,
    );
  }

  void refreshIosVideoOutputLimit({bool force = true}) {
    _scheduleIosVideoOutputSync(
      sourceWidth: _iosVideoSourceWidth ?? player.state.width,
      sourceHeight: _iosVideoSourceHeight ?? player.state.height,
      force: force,
    );
  }

  void _scheduleIosVideoOutputSync({
    int? sourceWidth,
    int? sourceHeight,
    bool force = false,
  }) {
    if (!Platform.isIOS || _playerClosing) {
      return;
    }
    if (sourceWidth != null && sourceWidth > 0) {
      _iosVideoSourceWidth = sourceWidth;
    }
    if (sourceHeight != null && sourceHeight > 0) {
      _iosVideoSourceHeight = sourceHeight;
    }
    _iosVideoOutputForceApply = _iosVideoOutputForceApply || force;
    _iosVideoOutputSyncTimer?.cancel();
    _iosVideoOutputSyncTimer = Timer(
      const Duration(milliseconds: 120),
      () {
        final shouldForce = _iosVideoOutputForceApply;
        _iosVideoOutputForceApply = false;
        unawaited(_applyIosVideoOutputLimit(force: shouldForce));
      },
    );
  }

  Future<void> _applyIosVideoOutputLimit({required bool force}) async {
    if (!Platform.isIOS || _playerClosing) {
      return;
    }
    final settings = AppSettingsController.instance;
    if (!settings.iosOriginalQualityPowerSaving.value) {
      if (force || _iosVideoOutputSize != null) {
        try {
          await videoController.setSize();
          _iosVideoOutputSize = null;
          Log.d("iOS 原画省电优化已关闭，恢复源分辨率纹理");
        } catch (e) {
          Log.w("恢复 iOS 源分辨率纹理失败: $e");
        }
      }
      return;
    }

    final sourceWidth = _iosVideoSourceWidth;
    final sourceHeight = _iosVideoSourceHeight;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (sourceWidth == null ||
        sourceHeight == null ||
        sourceWidth <= 0 ||
        sourceHeight <= 0 ||
        views.isEmpty) {
      return;
    }
    final physicalSize = views.first.physicalSize;
    // iPad 破例：屏幕物理短边 > 1366 视为大屏 iPad（iPhone 普遍 ≤1290），
    // 开启「原画省电优化」时把渲染纹理压到 kIosRenderCapLongEdge 以降温。
    // 手机不传 maxLongEdge，保持原「不超过屏幕」逻辑不变。
    final isIpad = physicalSize.shortestSide > 1366;
    final target = calculateIosVideoOutputSize(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      screenPhysicalWidth: physicalSize.width,
      screenPhysicalHeight: physicalSize.height,
      maxLongEdge: isIpad ? settings.iosRenderCapMaxLongEdge : null,
    );
    if (target == null || (!force && target == _iosVideoOutputSize)) {
      return;
    }

    try {
      if (force && _iosVideoOutputSize != null) {
        // 每个新 VideoParams（开播/重连/切清晰度）media_kit 都会把表面
        // 重置回源分辨率，这里先恢复再重压，保证上限一直生效
        // （2026-09-03 hotfix 曾加幂等去重，结果把同清晰度重连后的
        // 重设跳过了 → 上限悄悄失效 → 用户"1280 没感觉"，已回滚）。
        await videoController.setSize();
      }
      await videoController.setSize(
        width: target.width,
        height: target.height,
      );
      _iosVideoOutputSize = target;
      Log.i(
        "iOS 视频纹理限幅：source=${sourceWidth}x$sourceHeight "
        "screen=${physicalSize.width.toInt()}x${physicalSize.height.toInt()} "
        "output=$target",
      );
    } catch (e, stackTrace) {
      Log.e("应用 iOS 视频纹理限幅失败: $e", stackTrace);
    }
  }

  // Fix Issue #57: 流错误重试计数器
  int _streamErrorRetryCount = 0;
  DateTime? _lastStreamErrorTime;
  DateTime? _lastAudioDiagnosticTime;
  bool _streamErrorRetrying = false;
  int? _streamErrorRetryGeneration;
  int? _streamErrorGeneration;
  Timer? _streamErrorStablePlaybackTimer;
  Timer? _surfaceHealthCheckTimer;
  Timer? _playbackStallWatchdogTimer;
  Timer? _playbackStallStableTimer;
  // 退后台挂起时记录「当时是否在跑」，回前台只恢复原来在跑的那些，
  // 避免把本来没启动的定时器凭空拉起来。
  bool _surfaceHealthCheckWasActive = false;
  bool _stallWatchdogWasActive = false;
  bool _surfaceRecoveryInFlight = false;
  int _surfaceRecoveryAttempts = 0;
  int? _surfaceRecoveryLoadGeneration;
  int? _surfaceRecoveryMediaGeneration;
  int _surfaceRecoveryToken = 0;
  DateTime? _lastSurfaceRecoveryAt;
  DateTime? _surfaceRecoveryGraceUntil;
  Duration? _stallLastPosition;
  DateTime? _stallLastProgressAt;
  DateTime? _lastPlaybackStallRecoveryAt;
  int? _stallLoadGeneration;
  String? _stallMediaUri;
  int _playbackStallRecoveryAttempts = 0;
  bool _playbackStallRecoveryInFlight = false;

  // === 跨链路重连节流（P0-10）===
  //
  // 四套重连链路（流错误 / Surface / 停滞 / 业务层）原本互不知情，各自独立
  // 计数，坏流时可以在很短时间内叠加触发多次「重开解码器」。这里只加一层
  // 跨链路的**节奏约束**：把重开动作拉开间隔 + 让重试间隔指数增长。
  //
  // 刻意**不**做「四条共用一个重连预算」：那样会出现预算被别的链路用掉后
  // 「该重试的没重试」，反而改变重试语义。这里只改节奏，每条链路该重试几次
  // 还是几次，只是彼此之间不再挤在一起。
  /// 最近一次破坏性重连（重开解码器 / 刷新播放地址 / 切线路）的时刻。
  DateTime? _lastHeavyReconnectAt;
  /// 连续重连次数，只用于计算退避时长，不参与任何「还能不能重试」的判断。
  int _heavyReconnectStreak = 0;

  /// 任意两次破坏性重连之间的最小间隔。
  static const _heavyReconnectCooldown = Duration(seconds: 3);
  /// 距上次重连这么久仍在正常播放，就认为流已恢复，连续计数归零。
  static const _heavyReconnectResetAfter = Duration(seconds: 60);
  static const _heavyReconnectBackoffCeilingStep = 3;

  static const _stablePlaybackDuration = Duration(seconds: 30);
  static const _surfaceRecoveryCooldown = Duration(seconds: 3);
  static const _surfaceRecoveryGraceDuration = Duration(seconds: 8);
  static const _surfaceRecoveryValidationDelay = Duration(milliseconds: 600);
  static const _maxSurfaceRecoveryAttempts = 3;
  static const _playbackStallSampleInterval = Duration(seconds: 3);
  static const _playbackStallTimeout = Duration(seconds: 15);
  static const _playbackBufferingStallTimeout = Duration(seconds: 30);
  static const _playbackStallCooldown = Duration(seconds: 5);

  void _syncStreamErrorGeneration(int generation) {
    if (_streamErrorGeneration == generation) {
      return;
    }
    _streamErrorGeneration = generation;
    _streamErrorRetryCount = 0;
    _lastStreamErrorTime = null;
    _streamErrorStablePlaybackTimer?.cancel();
    _streamErrorStablePlaybackTimer = null;
  }

  void _cancelStablePlaybackTimer() {
    _streamErrorStablePlaybackTimer?.cancel();
    _streamErrorStablePlaybackTimer = null;
  }

  void _scheduleStablePlaybackReset(int generation) {
    _cancelStablePlaybackTimer();
    _streamErrorStablePlaybackTimer = Timer(_stablePlaybackDuration, () {
      _streamErrorStablePlaybackTimer = null;
      if (!isPlaybackLoadGenerationCurrent(generation) ||
          !player.state.playing ||
          _streamErrorRetrying) {
        return;
      }
      if (_streamErrorGeneration == generation) {
        _streamErrorRetryCount = 0;
        _lastStreamErrorTime = null;
        if (_surfaceRecoveryLoadGeneration == generation) {
          _surfaceRecoveryAttempts = 0;
          _lastSurfaceRecoveryAt = null;
        }
        Log.d("播放器已稳定播放，重置流错误重试计数");
      }
    });
  }

  /// iOS 音频会话同步：播放中激活（保证退后台能续播），停止播放时释放
  /// 会话把音频还给其它 App。原生侧见 SuikanAudioSession.swift。
  /// Android：同一通道复用为音频焦点请求/释放（来电、导航、其它媒体避让）。
  Future<void> _syncIosAudioSession({required bool active}) async {
    try {
      if (Platform.isIOS) {
        await _iosAudioChannel?.invokeMethod(
          active ? 'activate' : 'deactivate',
        );
      } else if (Platform.isAndroid) {
        await _iosAudioChannel?.invokeMethod(
          active ? 'requestFocus' : 'abandonFocus',
        );
      }
    } catch (e) {
      Log.d("音频会话/焦点同步失败: $e");
    }
  }

  /// 系统媒体中心「下一首」命令（直播=切下一线路，影视=下一集）。
  /// 具体行为由子类 LiveRoomController override 实现。
  Future<void> onMediaNext() async {}

  /// 系统媒体中心「上一首」命令（直播=切上一线路，影视=上一集）。
  Future<void> onMediaPrev() async {}

  /// 系统媒体中心进度拖动命令（仅影视；直播忽略）。
  Future<void> onMediaSeek(Duration position) async {}

  /// 是否需要在系统媒体中心显示实时进度（仅影视返回 true）。
  bool shouldSyncMediaProgress() => false;

  /// 影视播放中周期同步进度到系统媒体中心（锁屏/通知栏进度条走动）。
  Timer? _mediaProgressTimer;

  void _startMediaProgressSync() {
    if (_mediaProgressTimer != null || !shouldSyncMediaProgress()) {
      return;
    }
    _mediaProgressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!player.state.playing) {
        return;
      }
      unawaited(
        MediaControlService.setPosition(
          player.state.position.inSeconds.toDouble(),
        ),
      );
    });
  }

  void _stopMediaProgressSync() {
    _mediaProgressTimer?.cancel();
    _mediaProgressTimer = null;
  }

  void initStream() {
    if (Platform.isIOS || Platform.isAndroid) {
      MediaControlService.init();
      MediaControlService.onCommand = (cmd) {
        switch (cmd.command) {
          case 'play':
            unawaited(player.play());
            break;
          case 'pause':
            unawaited(player.pause());
            break;
          case 'next':
            // 直播=切下一线路，影视=下一集（子类 LiveRoomController override）
            unawaited(onMediaNext());
            break;
          case 'prev':
            // 直播=切上一线路，影视=上一集
            unawaited(onMediaPrev());
            break;
          case 'seek':
            final pos = cmd.position;
            if (pos != null) {
              unawaited(
                onMediaSeek(Duration(milliseconds: (pos * 1000).round())),
              );
            }
            break;
          default:
            if (player.state.playing) {
              unawaited(player.pause());
            } else {
              unawaited(player.play());
            }
        }
      };
      // iOS 音频会话：播放时激活（后台续播前提），来电/闹钟中断结束后
      // 若中断前在播则恢复播放（原生侧见 SuikanAudioSession.swift）。
      // Android 音频焦点：来电/导航时通知暂停，焦点回来后恢复
      // （原生侧见 MainActivity.kt）。
      _iosAudioChannel ??= const MethodChannel('suikan/audio');
      _iosAudioChannel?.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'onInterruptionEnded':
            final shouldResume = call.arguments as bool? ?? false;
            if (shouldResume && _lastPlayingState && !player.state.playing) {
              Log.d("iOS 音频中断结束，恢复播放");
              unawaited(player.play());
            }
            break;
          case 'onAudioFocusLost':
            // 来电/导航等：暂停播放（仅在真的在播时）
            if (player.state.playing) {
              Log.d("Android 失去音频焦点，暂停播放");
              unawaited(player.pause());
            }
            break;
          case 'onAudioFocusGained':
            if (_lastPlayingState && !player.state.playing) {
              Log.d("Android 重新获得音频焦点，恢复播放");
              unawaited(player.play());
            }
            break;
        }
        return null;
      });
    }
    if (Platform.isIOS) {
      _iosOriginalQualityPowerSavingWorker = ever<bool>(
        AppSettingsController.instance.iosOriginalQualityPowerSaving,
        (_) => refreshIosVideoOutputLimit(),
      );
      // 2026-09-03：接线「渲染上限档位」即时重设 —— 用户在弹窗切档
      // 立刻重算纹理尺寸生效（无需重开流），便于当场对比糊度/温度。
      _iosRenderCapWorker = ever<int>(
        AppSettingsController.instance.iosRenderCapLongEdge,
        (_) => refreshIosVideoOutputLimit(),
      );
    }
    if (Platform.isAndroid) {
      // 设置开关变化 → 按「当前是否在播 × 开关」重算前台服务启停。
      // 播放中打开后台播放/纯音频：服务即刻就位，退后台时不会因没有
      // 前台服务被系统回收；关闭开关即停、撤通知。服务启停的唯一裁决
      // 仍收敛在 _syncBackgroundPlaybackService，这里只做"重算触发"。
      final settings = AppSettingsController.instance;
      _allowBackgroundWorker = ever<bool>(
        settings.allowBackgroundPlayback,
        (_) => _resyncBackgroundPlaybackService(settings),
      );
      _audioOnlyWorker = ever<bool>(
        settings.audioOnlyBackground,
        (_) => _resyncBackgroundPlaybackService(settings),
      );
    }
    _errorSubscription = player.stream.error.listen((event) {
      if (PlayerErrorClassifier.isRecoverableAudioDiagnostic(event)) {
        final now = DateTime.now();
        if (_lastAudioDiagnosticTime == null ||
            now.difference(_lastAudioDiagnosticTime!) >=
                const Duration(seconds: 15)) {
          _lastAudioDiagnosticTime = now;
          Log.d("播放器音频诊断（已忽略）：$event");
        }
        return;
      }
      Log.d("播放器错误：$event");

      // Fix Issue #57: 检测流错误并自动重试
      if (_isStreamError(event)) {
        _cancelStablePlaybackTimer();
        unawaited(_handleStreamError(event));
        return;
      }

      //SmartDialog.showToast(event);
      _cancelStablePlaybackTimer();
      mediaError(event);
    });

    _playingSubscription = player.stream.playing.listen((event) {
      final generation = playbackLoadGeneration;
      _syncStreamErrorGeneration(generation);
      _lastPlayingState = event;
      // 系统媒体中心同步播放状态（锁屏按钮 / 通知栏按钮）
      if (Platform.isIOS || Platform.isAndroid) {
        unawaited(MediaControlService.setPlaying(event));
      }
      // iOS：音频会话必须在真正播放时激活（playback 类别 + active），
      // 否则退后台会被系统挂起 → 手动纯音频/后台播放返回桌面即停。
      // Android：播放时申请音频焦点（来电/导航自动避让）。
      if (Platform.isIOS || Platform.isAndroid) {
        unawaited(_syncIosAudioSession(active: event));
      }
      if (event) {
        _surfaceRecoveryGraceUntil =
            DateTime.now().add(_surfaceRecoveryGraceDuration);
        unawaited(_applyResolvedPlayerVolume());
        WakelockPlus.enable();
        unawaited(_syncBackgroundPlaybackService(true));
        Log.d("Playing");
        refreshIosVideoOutputLimit(force: true);
        // 只有持续播放一段时间才清零，避免坏流在每次重开后立刻绕过上限。
        _scheduleStablePlaybackReset(generation);
        // 影视播放中周期同步进度到系统媒体中心（锁屏进度条走动）。
        if (Platform.isIOS || Platform.isAndroid) {
          _startMediaProgressSync();
        }
      } else {
        _cancelStablePlaybackTimer();
        if (Platform.isIOS || Platform.isAndroid) {
          _stopMediaProgressSync();
        }
        // 暂停 / 停止 / 播放结束都要释放屏幕常亮。原来只在 mediaEnd、
        // mediaError、exitFullScreen 三处释放，手动暂停或退后台暂停之后
        // 标志会一直残留到下次终止流程，白耗电。
        //
        // 不会误伤卡顿场景：查过 media_kit 1.2.6 源码，playing 只由 mpv 的
        // `pause` 属性、MPV_EVENT_START_FILE 和 eof-reached 三个来源驱动；
        // 缓冲（core-idle / paused-for-cache）走的是 buffering 流，不会把
        // playing 打成 false。所以网络卡顿期间屏幕不会突然变暗。
        unawaited(WakelockPlus.disable());
        // 停止播放事件（含手动暂停/停播/退房/异常触发的 playing=false）：
        // 立刻停前台服务、撤通知——与 true 分支对称，构成服务启停的唯一
        // 裁决闭环，杜绝"已不播但通知残留"的任何旁路。
        unawaited(_syncBackgroundPlaybackService(false));
      }
    });

    _completedSubscription = player.stream.completed.listen((event) {
      if (event) {
        _cancelStablePlaybackTimer();
        mediaEnd();
      }
    });
    // mpv 日志在发行版没有任何用处：Log.d 内部本就有 kReleaseMode 守卫、
    // 不会真的打印，但订阅仍会把每一条日志送过 Dart 侧，并白执行一次字符串
    // 插值。卡顿 / 重连时日志非常密集，这笔开销不小，故发行版直接不订阅。
    if (!kReleaseMode) {
      _logSubscription = player.stream.log.listen((event) {
        Log.d("播放器日志：$event");
      });
    }
    _widthSubscription = player.stream.width.listen((event) {
      // 同上：仅调试构建打印，发行版省掉插值开销（尺寸检测逻辑照常执行）。
      if (!kReleaseMode) {
        Log.d(
            'width:$event  W:${(player.state.width)}  H:${(player.state.height)}');
      }

      // Fix Issue #57: 检测异常的视频尺寸
      if (event == null || event <= 0) {
        // 纯音频下 width 本就恒为 null（见 _hasInvalidVideoSize 注释），
        // 不是 Surface 失效，不能触发恢复。
        if (player.state.playing && !_isAudioOnlyPlayback) {
          Log.w("播放器宽度异常: $event (播放中)，可能是Surface失效");
          unawaited(_handleInvalidVideoSize());
        }
        return;
      }

      isVertical.value =
          (player.state.height ?? 9) > (player.state.width ?? 16);
      unawaited(refreshAutoPipOnVideoSize());
      unawaited(_syncAndroidExternalWindowLandscapeOrientation());
    });
    _heightSubscription = player.stream.height.listen((event) {
      Log.d(
          'height:$event  W:${(player.state.width)}  H:${(player.state.height)}');

      // Fix Issue #57: 检测异常的视频尺寸
      if (event == null || event <= 0) {
        // 同 width：纯音频下 height 恒为 null，不是 Surface 失效。
        if (player.state.playing && !_isAudioOnlyPlayback) {
          Log.w("播放器高度异常: $event (播放中)，可能是Surface失效");
          unawaited(_handleInvalidVideoSize());
        }
        return;
      }

      isVertical.value =
          (player.state.height ?? 9) > (player.state.width ?? 16);
      unawaited(refreshAutoPipOnVideoSize());
      unawaited(_syncAndroidExternalWindowLandscapeOrientation());
    });
    _videoParamsSubscription = player.stream.videoParams.listen((params) {
      // 出现视频参数说明有视频轨，纯音频探测作废。
      _audioOnlyProbeTimer?.cancel();
      _audioOnlyProbeTimer = null;
      _handleVideoParamsForIosOutput(params);
    });
    // 纯音频误判自愈：若已被自动判定为纯音频（vid=no），但 track-list
    // 后续声明出视频轨（慢 HLS/302 防盗链起播晚于探测窗口），立即恢复
    // 视频，避免画面被永久禁用。（2026-09-04 gfjs.m3u8 误判修复）
    _tracksSubscription = player.stream.tracks.listen((tracks) {
      if (!_autoAudioOnlyActivated) {
        return;
      }
      if (tracks.video.isNotEmpty && player.state.videoParams.w == null) {
        Log.d("纯音频锁定被推翻：track-list 出现视频轨，恢复视频显示");
        _audioOnlyProbeTimer?.cancel();
        _audioOnlyProbeTimer = null;
        _autoAudioOnlyActivated = false;
        unawaited(setAudioOnlyMode(false));
        // 复核：恢复 vid=auto 后若 4s 内 videoParams 仍无尺寸（track-list
        // 虚报视频轨的纯音频源），重新锁回音频模式，避免画面空转。
        _audioOnlyProbeTimer = Timer(const Duration(seconds: 4), () {
          _audioOnlyProbeTimer = null;
          if (_autoAudioOnlyActivated) {
            return;
          }
          if (player.state.videoParams.w == null &&
              player.state.tracks.video.isNotEmpty) {
            Log.d("纯音频复核：恢复后仍无视频出帧，重新锁定音频模式");
            _autoAudioOnlyActivated = true;
            unawaited(setAudioOnlyMode(true));
          }
        });
      }
    });

    // Fix Issue #57: 启动Surface健康检查
    _startSurfaceHealthCheck();
    _startPlaybackStallWatchdog();
  }

  void disposeStream() {
    if (Platform.isIOS) {
      _iosAudioChannel?.setMethodCallHandler(null);
    }
    _stopMediaProgressSync();
    _cancelStablePlaybackTimer();
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    _widthSubscription?.cancel();
    _heightSubscription?.cancel();
    _videoParamsSubscription?.cancel();
    _tracksSubscription?.cancel();
    _logSubscription?.cancel();
    _pipSubscription?.cancel();
    _playingSubscription?.cancel();
    _surfaceHealthCheckTimer?.cancel();
    _playbackStallWatchdogTimer?.cancel();
    _playbackStallStableTimer?.cancel();
    _iosVideoOutputSyncTimer?.cancel();
    _iosOriginalQualityPowerSavingWorker?.dispose();
    _iosOriginalQualityPowerSavingWorker = null;
    _iosRenderCapWorker?.dispose();
    _iosRenderCapWorker = null;
    _allowBackgroundWorker?.dispose();
    _allowBackgroundWorker = null;
    _audioOnlyWorker?.dispose();
    _audioOnlyWorker = null;
    _iosVideoOutputSyncTimer = null;
    _audioOnlyProbeTimer?.cancel();
    _audioOnlyProbeTimer = null;
    _autoAudioOnlyActivated = false;
    _surfaceHealthCheckTimer = null;
    _surfaceRecoveryToken += 1;
    _surfaceRecoveryInFlight = false;
    _surfaceRecoveryAttempts = 0;
    _surfaceRecoveryLoadGeneration = null;
    _surfaceRecoveryMediaGeneration = null;
    _lastSurfaceRecoveryAt = null;
    _surfaceRecoveryGraceUntil = null;
    _stallLastPosition = null;
    _stallLastProgressAt = null;
    _lastPlaybackStallRecoveryAt = null;
    _stallLoadGeneration = null;
    _stallMediaUri = null;
    _playbackStallRecoveryAttempts = 0;
    _playbackStallRecoveryInFlight = false;
    // 换流/销毁时跨链路重连计数一并归零：新的一条流不该背上前一条流的退避。
    _lastHeavyReconnectAt = null;
    _heavyReconnectStreak = 0;
  }

  // Fix Issue #57: 判断是否为流错误（网络/解码错误）
  bool _isStreamError(String error) {
    return error.contains('mbedtls_ssl_read') ||
        error.contains('Packet corrupt') ||
        error.contains('Packet corupt') ||
        error.contains('tls:') ||
        error.contains('Invalid NAL unit') ||
        error.contains('missing picture');
  }

  // Fix Issue #57: 处理流错误，自动重试
  Future<void> _handleStreamError(String error) async {
    final generation = playbackLoadGeneration;
    final mediaGeneration = playbackMediaGeneration;
    if (!isPlaybackLoadGenerationCurrent(generation)) {
      return;
    }
    _syncStreamErrorGeneration(generation);
    if (_streamErrorRetrying && _streamErrorRetryGeneration == generation) {
      return;
    }
    _streamErrorRetrying = true;
    _streamErrorRetryGeneration = generation;
    final mediaAtError = player.state.playlist.medias.isNotEmpty
        ? player.state.playlist.medias[player.state.playlist.index]
        : null;
    final mediaUriAtError = mediaAtError?.uri;
    final now = DateTime.now();

    // 防止短时间内重复触发
    if (_lastStreamErrorTime != null &&
        now.difference(_lastStreamErrorTime!) < const Duration(seconds: 2)) {
      _streamErrorRetrying = false;
      _streamErrorRetryGeneration = null;
      if (player.state.playing) {
        _scheduleStablePlaybackReset(generation);
      }
      return;
    }
    _lastStreamErrorTime = now;

    if (_streamErrorRetryCount >= 3) {
      Log.e("流错误重试次数已达上限(3次)，停止重试: $error", StackTrace.current);
      mediaError(error);
      _streamErrorRetrying = false;
      _streamErrorRetryGeneration = null;
      return;
    }

    _streamErrorRetryCount++;
    // 先按「当前」连续次数算退避（第 1 次 = 0 → 等 1 秒），再累加计数，
    // 顺序反了会让第一次重试就变成 2 秒。
    final backoff = _heavyReconnectBackoff();
    _noteHeavyReconnect(now);
    Log.w(
      "检测到流错误，自动重试解码器 ($_streamErrorRetryCount/3)，"
      "等待 ${backoff.inMilliseconds}ms: $error",
      false,
    );

    // 原来固定等 1 秒：坏流时会在 1s / 2s / 3s 连续三次重开解码器，这正是
    // 方案里说的重连风暴——网络根本来不及恢复就又被推倒重来。改成指数退避
    // （1→2→4→8 秒）后，三次重试分布在 1s / 3s / 7s。
    // 第 1 次仍是 1 秒，所以瞬时抖动的恢复速度和原来完全一样。
    await Future.delayed(backoff);

    try {
      if (!isPlaybackLoadGenerationCurrent(generation)) {
        return;
      }
      final currentMedia = player.state.playlist.medias.isNotEmpty
          ? player.state.playlist.medias[player.state.playlist.index]
          : null;

      if (mediaGeneration != playbackMediaGeneration ||
          mediaAtError == null ||
          mediaUriAtError == null ||
          currentMedia == null ||
          currentMedia.uri != mediaUriAtError) {
        return;
      }

      if (isPlaybackLoadGenerationCurrent(generation)) {
        Log.i("正在重启解码器...");
        await player.pause();
        if (!isPlaybackLoadGenerationCurrent(generation) ||
            mediaGeneration != playbackMediaGeneration) {
          return;
        }
        await Future.delayed(const Duration(milliseconds: 200));
        if (!isPlaybackLoadGenerationCurrent(generation) ||
            mediaGeneration != playbackMediaGeneration) {
          return;
        }
        final reopened = await openPlaybackMedia(
          currentMedia,
          loadGeneration: generation,
          mediaGeneration: mediaGeneration,
          isStillOwner: () {
            final activeMedia = player.state.playlist.medias.isNotEmpty
                ? player.state.playlist.medias[player.state.playlist.index]
                : null;
            return activeMedia?.uri == mediaUriAtError;
          },
        );
        if (!reopened) {
          return;
        }
      }
    } catch (e, stackTrace) {
      Log.e("重启解码器失败: $e", stackTrace);
      if (isPlaybackLoadGenerationCurrent(generation)) {
        mediaError(error);
      }
    } finally {
      if (_streamErrorRetryGeneration == generation) {
        _streamErrorRetrying = false;
        _streamErrorRetryGeneration = null;
      }
    }
  }

  double _resolvedPlayerVolume() {
    return PlayerVolumePolicy.internalVolume(
      mobile: Platform.isAndroid || Platform.isIOS,
      muted: mutedState.value,
      persisted: AppSettingsController.instance.playerVolume.value,
    );
  }

  Future<void> _applyResolvedPlayerVolume() async {
    if (_playerClosing) {
      return;
    }
    await player.setVolume(_resolvedPlayerVolume());
  }

  // Fix Issue #57 & #97: 处理异常的视频尺寸（Surface失效）。
  // Recovery is bounded and serialized so startup events cannot storm the decoder.
  Future<void> _handleInvalidVideoSize() async {
    // 纯音频播放没有视频轨，width/height 恒为 null，这里的「异常」是预期的，
    // 无画面可恢复。放在入口兜底，将来新增调用点也不会漏掉这个守卫。
    if (_isAudioOnlyPlayback) {
      return;
    }
    final generation = playbackLoadGeneration;
    final mediaGeneration = playbackMediaGeneration;
    if (!isPlaybackLoadGenerationCurrent(generation) ||
        !player.state.playing ||
        _playerClosing) {
      return;
    }
    if (_streamErrorRetrying && _streamErrorRetryGeneration == generation) {
      return;
    }

    final now = DateTime.now();
    if (_surfaceRecoveryGraceUntil != null &&
        now.isBefore(_surfaceRecoveryGraceUntil!)) {
      return;
    }
    if (_surfaceRecoveryInFlight) {
      return;
    }
    if (_surfaceRecoveryLoadGeneration != generation ||
        _surfaceRecoveryMediaGeneration != mediaGeneration) {
      _surfaceRecoveryLoadGeneration = generation;
      _surfaceRecoveryMediaGeneration = mediaGeneration;
      _surfaceRecoveryAttempts = 0;
      _lastSurfaceRecoveryAt = null;
    }
    if (_surfaceRecoveryAttempts >= _maxSurfaceRecoveryAttempts) {
      Log.w("Surface恢复次数已达上限（$_maxSurfaceRecoveryAttempts次），暂不重复重启");
      return;
    }
    if (_lastSurfaceRecoveryAt != null &&
        now.difference(_lastSurfaceRecoveryAt!) < _surfaceRecoveryCooldown) {
      return;
    }
    // 跨链路冷却：别的链路刚重连过，本次先让路（P0-10）。
    //
    // 这里是 3 秒轮询，跳过本次后下个周期自然会再来，而且 _surfaceRecoveryAttempts
    // 在跳过时不递增 —— 所以「最多尝试恢复 3 次」这个语义一点没变，只是间隔
    // 被拉开，不再和流错误重试撞在一起。
    if (_isHeavyReconnectCoolingDown(now)) {
      return;
    }

    final media = player.state.playlist.medias.isNotEmpty
        ? player.state.playlist.medias[player.state.playlist.index]
        : null;
    final mediaUri = media?.uri;
    if (media == null || mediaUri == null || mediaUri.isEmpty) {
      return;
    }

    _surfaceRecoveryInFlight = true;
    _surfaceRecoveryAttempts += 1;
    _lastSurfaceRecoveryAt = now;
    final recoveryToken = ++_surfaceRecoveryToken;
    Log.w(
      "检测到视频尺寸异常，尝试恢复Surface "
      "($_surfaceRecoveryAttempts/$_maxSurfaceRecoveryAttempts)",
    );

    try {
      await player.pause();
      await Future.delayed(const Duration(milliseconds: 300));
      if (recoveryToken != _surfaceRecoveryToken ||
          !isPlaybackLoadGenerationCurrent(generation) ||
          mediaGeneration != playbackMediaGeneration ||
          _playerClosing) {
        return;
      }
      await player.play();
      await Future.delayed(_surfaceRecoveryValidationDelay);
      if (recoveryToken != _surfaceRecoveryToken ||
          !isPlaybackLoadGenerationCurrent(generation) ||
          mediaGeneration != playbackMediaGeneration ||
          _playerClosing) {
        return;
      }
      if (!_hasInvalidVideoSize() || !player.state.playing) {
        return;
      }

      final currentMedia = player.state.playlist.medias.isNotEmpty
          ? player.state.playlist.medias[player.state.playlist.index]
          : null;
      if (currentMedia?.uri != mediaUri) {
        return;
      }
      Log.w("Surface恢复失败，重开当前媒体");
      // 只有走到这一步才是真正的「重开解码器 + 重连网络」，上面那些
      // pause/play 只是轻量试探，不计入跨链路重连计数。
      _noteHeavyReconnect(DateTime.now());
      final reopened = await openPlaybackMedia(
        currentMedia!,
        loadGeneration: generation,
        mediaGeneration: mediaGeneration,
        isStillOwner: () {
          final activeMedia = player.state.playlist.medias.isNotEmpty
              ? player.state.playlist.medias[player.state.playlist.index]
              : null;
          return activeMedia?.uri == mediaUri;
        },
      );
      if (reopened) {
        _surfaceRecoveryGraceUntil =
            DateTime.now().add(_surfaceRecoveryGraceDuration);
      }
    } catch (e, stackTrace) {
      Log.e("恢复Surface失败: $e", stackTrace);
    } finally {
      if (recoveryToken == _surfaceRecoveryToken) {
        _surfaceRecoveryInFlight = false;
      }
    }
  }

  /// 视频尺寸是否异常（Surface 失效的典型表现）。
  ///
  /// ⚠️ **纯音频播放时这个方法恒为 true，并不代表 Surface 有问题。**
  /// 已查 media_kit 1.2.6 源码确认（不是推断）：
  /// ① open/stop 时 `PlayerState` 被整体重建，`width` 因此重置为 null
  ///    （`real.dart:267` 重建 state + `:337` 向 width 流推 null）；
  /// ② 此后 `width` 只在 `video-params` 的 `dw` 为整数时才被赋值
  ///    （`real.dart:2025-2048`），纯音频流永远等不到那一刻。
  /// 于是纯音频下 `width` 从重置起就一直是 null。
  ///
  /// 顺带纠正一个容易搞错的点：`state.width` 与 `state.videoParams.w` **是
  /// 同源的**（都来自 `video-params`，前者取 `dw` 并处理了旋转），不是两套
  /// 独立数据，所以不能指望用 videoParams 去纠正 width。
  ///
  /// 调用方必须先用 [_isAudioOnlyPlayback] 排除纯音频，否则会把纯音频当成
  /// Surface 失效，每 3 秒触发一轮重开流（P0-11）。
  bool _hasInvalidVideoSize() {
    final width = player.state.width;
    final height = player.state.height;
    return width == null || width <= 0 || height == null || height <= 0;
  }

  // Fix Issue #57: Surface健康检查（每3秒检查一次）
  void _startSurfaceHealthCheck() {
    if (!Platform.isAndroid) {
      return; // 仅Android需要
    }

    _surfaceHealthCheckTimer?.cancel();
    _surfaceHealthCheckTimer = Timer.periodic(
      const Duration(seconds: 3),
      (timer) {
        if (_playerClosing) {
          timer.cancel();
          return;
        }

        // 检测：播放中但尺寸为null = Surface异常。
        //
        // 必须排除纯音频：纯音频没有视频轨，width/height 恒为 null，不排掉
        // 就会每 3 秒误判一次、触发一轮完整重开流（pause → 重开解码器与网络
        // 连接），表现是持续发热 + 每隔一阵断一下音。这就是 P0-11。
        //
        // 三处判定里只有这一处会真正误触发：width/height 是值变化流，纯音频
        // 下 open 时置 null 之后就不再变化（那时 playing 还是 false），所以
        // 那两个监听其实打不到 —— 它们的守卫是防御性的。
        if (player.state.playing &&
            _hasInvalidVideoSize() &&
            !_isAudioOnlyPlayback) {
          Log.w(
            "Surface健康检查失败: playing=${player.state.playing} "
            "width=${player.state.width} height=${player.state.height}",
          );
          unawaited(_handleInvalidVideoSize());
        }
      },
    );
  }

  /// A network outage can leave mpv in `playing == true` without emitting an
  /// error or end event. Watch the media position and route a confirmed stall
  /// through the existing bounded `mediaError` recovery path.
  void _startPlaybackStallWatchdog() {
    _playbackStallWatchdogTimer?.cancel();
    _playbackStallWatchdogTimer = Timer.periodic(
      _playbackStallSampleInterval,
      (_) => _checkPlaybackStall(),
    );
  }

  /// 退后台时停掉这两个播放健康定时器（Surface 3s 检查 + 停滞看门狗 3s）。
  ///
  /// 后台本来就不该做这两件事：不允许后台播放时播放器已经 pause；允许后台
  /// 播放时会降级为纯音频，而纯音频下 `width`/`height` 恒为 null，Surface
  /// 检查会把它当成异常、白白触发一轮重开流。
  void suspendPlaybackHealthTimers() {
    _surfaceHealthCheckWasActive = _surfaceHealthCheckTimer != null;
    _stallWatchdogWasActive = _playbackStallWatchdogTimer != null;
    _surfaceHealthCheckTimer?.cancel();
    _surfaceHealthCheckTimer = null;
    _playbackStallWatchdogTimer?.cancel();
    _playbackStallWatchdogTimer = null;
    _resetPlaybackStallSample();
  }

  /// 回到前台恢复。只恢复挂起时确实在跑的那些；两个 start 方法都是
  /// 「先 cancel 再 new」，重复调用幂等。
  void resumePlaybackHealthTimers() {
    if (_playerClosing) {
      _surfaceHealthCheckWasActive = false;
      _stallWatchdogWasActive = false;
      return;
    }
    if (_surfaceHealthCheckWasActive) {
      _startSurfaceHealthCheck();
    }
    if (_stallWatchdogWasActive) {
      _startPlaybackStallWatchdog();
    }
    _surfaceHealthCheckWasActive = false;
    _stallWatchdogWasActive = false;
  }

  void _checkPlaybackStall() {
    if (_playerClosing ||
        !isPlaybackLoadGenerationCurrent(playbackLoadGeneration)) {
      return;
    }
    final state = player.state;
    if (!state.playing || state.completed) {
      _resetPlaybackStallSample();
      return;
    }
    final media = state.playlist.medias.isNotEmpty
        ? state.playlist.medias[state.playlist.index]
        : null;
    final mediaUri = media?.uri.trim();
    if (mediaUri == null || mediaUri.isEmpty) {
      return;
    }
    final generation = playbackLoadGeneration;
    if (_stallLoadGeneration != generation || _stallMediaUri != mediaUri) {
      _stallLoadGeneration = generation;
      _stallMediaUri = mediaUri;
      _stallLastPosition = state.position;
      _stallLastProgressAt = DateTime.now();
      _playbackStallRecoveryAttempts = 0;
      _playbackStallStableTimer?.cancel();
      _playbackStallStableTimer = null;
      return;
    }

    final now = DateTime.now();
    final position = state.position;
    if (_stallLastPosition == null || position != _stallLastPosition) {
      _stallLastPosition = position;
      _stallLastProgressAt = now;
      // 播放有进展 → 流还在动。距上次重连已超过阈值就认为彻底恢复，
      // 连续重连计数归零（下次再出问题从 1 秒档重新开始，不会一直呆在 8 秒）。
      _maybeResetHeavyReconnectStreak(now);
      if (_playbackStallRecoveryAttempts > 0 &&
          _playbackStallStableTimer == null) {
        _playbackStallStableTimer = Timer(_stablePlaybackDuration, () {
          _playbackStallStableTimer = null;
          if (isPlaybackLoadGenerationCurrent(generation) &&
              player.state.playing) {
            _playbackStallRecoveryAttempts = 0;
          }
        });
      }
      return;
    }
    final lastProgressAt = _stallLastProgressAt;
    if (lastProgressAt == null ||
        now.difference(lastProgressAt) <
            (state.buffering
                ? _playbackBufferingStallTimeout
                : _playbackStallTimeout)) {
      return;
    }
    if (_surfaceRecoveryGraceUntil != null &&
        now.isBefore(_surfaceRecoveryGraceUntil!)) {
      return;
    }
    if (_playbackStallRecoveryInFlight ||
        _playbackStallRecoveryAttempts >= _maxSurfaceRecoveryAttempts ||
        (_lastPlaybackStallRecoveryAt != null &&
            now.difference(_lastPlaybackStallRecoveryAt!) <
                _playbackStallCooldown)) {
      return;
    }
    // 跨链路冷却：停滞判定是 3 秒采样一次，跳过本次后下个周期自然会再来
    // （_stallLastProgressAt 没被重置，停滞条件仍成立），且不会消耗
    // _playbackStallRecoveryAttempts，所以重试次数语义不变。
    if (_isHeavyReconnectCoolingDown(now)) {
      return;
    }
    unawaited(_recoverPlaybackStall(generation, mediaUri));
  }

  Future<void> _recoverPlaybackStall(int generation, String mediaUri) async {
    if (_playbackStallRecoveryInFlight ||
        !isPlaybackLoadGenerationCurrent(generation) ||
        _stallMediaUri != mediaUri) {
      return;
    }
    final now = DateTime.now();
    _playbackStallRecoveryInFlight = true;
    _playbackStallRecoveryAttempts += 1;
    _lastPlaybackStallRecoveryAt = now;
    _stallLastProgressAt = now;
    // 本链路的恢复动作会经 mediaError 走到业务层的 setPlayer（重建播放器），
    // 属于破坏性重连，计入跨链路计数，让后续重试按退避节奏来。
    _noteHeavyReconnect(now);
    Log.w(
      "检测到直播流长时间无进度，自动刷新播放 "
      "($_playbackStallRecoveryAttempts/$_maxSurfaceRecoveryAttempts)",
    );
    try {
      // LiveRoomController overrides mediaError and refreshes the current
      // line/URL with its existing generation and retry guards.
      mediaError("直播流停滞，自动刷新");
    } finally {
      _playbackStallRecoveryInFlight = false;
    }
  }

  void _resetPlaybackStallSample() {
    _stallLastPosition = null;
    _stallLastProgressAt = null;
    _playbackStallStableTimer?.cancel();
    _playbackStallStableTimer = null;
  }

  // === 跨链路重连节流（P0-10）===

  /// 是否处在全局重连冷却中。
  ///
  /// 只用于**周期轮询型**的链路（Surface 检查、停滞看门狗）：它们在冷却期
  /// 直接跳过本次，下个采样周期自然会再来，重试次数不会被消耗，所以最终
  /// 该重试的仍然会重试，只是被推后了最多一个采样间隔（3 秒）。
  bool _isHeavyReconnectCoolingDown(DateTime now) {
    final last = _lastHeavyReconnectAt;
    return last != null && now.difference(last) < _heavyReconnectCooldown;
  }

  /// 记录一次破坏性重连并累加连续次数。
  ///
  /// 必须在真正执行重连动作**之前**调用，这样其它链路的冷却判断才生效。
  /// 注意调用顺序：先算 [_heavyReconnectBackoff] 再调本方法 —— 本方法会让
  /// streak +1，顺序反了会把「第 1 次重试」算成 2 秒。
  void _noteHeavyReconnect(DateTime now) {
    _lastHeavyReconnectAt = now;
    _heavyReconnectStreak += 1;
  }

  /// 本次重连前应等待的退避时长：1 → 2 → 4 → 8 秒。
  ///
  /// 第一次重试仍是 1 秒（连续次数为 0），瞬时抖动不受影响；只有反复失败才
  /// 逐步拉长，给网络/源站留出恢复时间。封顶 8 秒，避免卡太久。
  Duration _heavyReconnectBackoff() {
    final step = _heavyReconnectStreak.clamp(0, _heavyReconnectBackoffCeilingStep);
    return Duration(seconds: 1 << step);
  }

  /// 播放有进展时调用：距上次重连已超过阈值，就认为流已经恢复。
  ///
  /// 刻意用「播放有进展」这个现成信号来复位，不新增定时器（新增定时器本身
  /// 就是开销，也和 P0-16 的结论冲突）。这里只做一次时间比较，非常轻。
  void _maybeResetHeavyReconnectStreak(DateTime now) {
    if (_heavyReconnectStreak == 0) {
      return;
    }
    final last = _lastHeavyReconnectAt;
    if (last == null || now.difference(last) >= _heavyReconnectResetAfter) {
      _heavyReconnectStreak = 0;
      _lastHeavyReconnectAt = null;
    }
  }

  void mediaEnd() {
    WakelockPlus.disable();
    unawaited(stopBackgroundPlaybackService());
  }

  void mediaError(String error) {
    WakelockPlus.disable();
    unawaited(stopBackgroundPlaybackService());
  }

  /// Android 前台服务（通知栏"随看-正在后台播放"）的【唯一】启停裁决点。
  ///
  /// 通知存在 ⟺ 正在播放 且（后台播放开关 或 纯音频开关）；其余一律停。
  /// 手动暂停也撤通知（暂停后后台保活无意义；恢复播放再拉起）。
  /// playing 订阅 true/false 两分支都会调本方法；退房/关播放器另有 stop
  /// 兜底（幂等，多调无害）。原生不得反向拉起服务（见
  /// BackgroundPlaybackService.kt 类注释的决策表）。
  Future<void> _syncBackgroundPlaybackService(bool playing) async {
    if (!Platform.isAndroid) {
      return;
    }
    if (playing &&
        (AppSettingsController.instance.allowBackgroundPlayback.value ||
            AppSettingsController.instance.audioOnlyBackground.value)) {
      await BackgroundPlaybackService.instance.start();
    } else {
      await BackgroundPlaybackService.instance.stop();
    }
  }

  /// 设置开关变化时，按当前播放状态重算服务启停
  /// （见 _syncBackgroundPlaybackService 的决策表）。
  Future<void> _resyncBackgroundPlaybackService(
    AppSettingsController settings,
  ) async {
    if (!Platform.isAndroid) {
      return;
    }
    final playing = player.state.playing;
    final want = playing &&
        (settings.allowBackgroundPlayback.value ||
            settings.audioOnlyBackground.value);
    await _syncBackgroundPlaybackService(want);
  }

  Future<void> stopBackgroundPlaybackService() {
    return BackgroundPlaybackService.instance.stop();
  }

  Future<Map<String, String>> _readMpvDiagnosticProperties() async {
    final platform = player.platform;
    if (platform is! NativePlayer) {
      return const {};
    }

    final result = <String, String>{};
    for (final name in const [
      'hwdec-current',
      'video-codec',
      'estimated-vf-fps',
      'container-fps',
      'video-bitrate',
    ]) {
      try {
        final value = (await platform.getProperty(name)).trim();
        if (value.isNotEmpty) {
          result[name] = value;
        }
      } catch (e) {
        Log.d("读取 mpv 播放属性 $name 失败: $e", false);
      }
    }
    return result;
  }

  Future<void> showDebugInfo() async {
    final mpvProperties = await _readMpvDiagnosticProperties();
    final videoTrack = player.state.track.video;
    final sourceResolution =
        '${player.state.width ?? 0}x${player.state.height ?? 0}';
    final outputResolution = videoOutputResolution;
    final hwdec = mpvProperties['hwdec-current'] ?? '无（软件解码或尚未开始）';
    final codec = mpvProperties['video-codec'] ?? videoTrack.codec ?? '未知';
    final fps = mpvProperties['estimated-vf-fps'] ??
        mpvProperties['container-fps'] ??
        videoTrack.fps?.toString() ??
        '未知';
    final videoBitrate = mpvProperties['video-bitrate'] ??
        videoTrack.bitrate?.toString() ??
        '未知';

    Widget diagnosticTile(String title, Object? value) {
      final text = value?.toString() ?? '未知';
      return ListTile(
        title: Text(title),
        subtitle: Text(text),
        onTap: () {
          Clipboard.setData(ClipboardData(text: '$title\n$text'));
        },
      );
    }

    Log.i(
      '播放诊断：hwdec=$hwdec codec=$codec fps=$fps bitrate=$videoBitrate '
      'source=$sourceResolution output=$outputResolution',
    );
    Utils.showBottomSheet(
      title: "播放信息",
      child: ListView(
        children: [
          diagnosticTile('实际硬件解码', hwdec),
          diagnosticTile('视频编码', codec),
          diagnosticTile('视频 FPS', fps),
          diagnosticTile('视频码率（bit/s）', videoBitrate),
          diagnosticTile('源分辨率', sourceResolution),
          diagnosticTile('输出纹理分辨率', outputResolution),
          diagnosticTile('VideoParams', player.state.videoParams),
          diagnosticTile('AudioParams', player.state.audioParams),
          diagnosticTile('Media', player.state.playlist),
          diagnosticTile('AudioTrack', player.state.track.audio),
          diagnosticTile('VideoTrack', videoTrack),
          diagnosticTile('AudioBitrate', player.state.audioBitrate),
          diagnosticTile('Volume', player.state.volume),
        ],
      ),
    );
  }

  Future<void> closePlayerResources() async {
    if (_playerClosing) {
      return;
    }
    _playerClosing = true;
    // 建门：新房 open（openPlaybackMedia）会先等本门完成，
    // 从而把「旧房关闭」与「新房打开」串行化。
    final shutdownGate = Completer<void>();
    _playerShutdownGate = shutdownGate;
    try {
      _cancelStablePlaybackTimer();
      clearTransientPlayerOverlays();
      await stopBackgroundPlaybackService();
      // iOS：释放音频会话，把音频还给其它 App（不释放会一直占用后台音频）
      if (Platform.isIOS) {
        await _syncIosAudioSession(active: false);
      }
      // 清掉锁屏/通知栏的"正在播放"
      if (Platform.isIOS || Platform.isAndroid) {
        await MediaControlService.clear();
      }
      await waitForPlaybackOpen();
      await player.stop();
      if (smallWindowState.value) {
        await exitSmallWindow();
      }
      disposeStream();
      disposeDanmakuController();
      await resetSystem();
      // 🔴 dispose 竞态规避（2026-09-04，真机崩溃栈实锤）：
      // dropbox 多起 SIGABRT "Callback invoked after it has been deleted"
      // （tid=Thread-8 = mpv 工作线程，栈在 FfiCallbackMetadata::TrampolinePage）。
      // media_kit 的 Player.dispose() 会立即删除 Dart FFI 回调，但 mpv 的
      // 事件线程在 stop 之后仍在排空剩余事件，稍后调用已删回调 → VM abort。
      // 上游 PR #1356 未合并、1.2.0~1.2.6 均未修复（#1324）。规避：stop 之后
      // 延迟 500ms 再 dispose，让 mpv 线程把 stop 相关事件全部处理完，
      // 命中竞态的概率大幅下降。closePlayerResources 是 fire-and-forget
      // 路径（页面已 pop），延迟不影响 UI 手感。
      final playerToDispose = player;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await playerToDispose.dispose();
    } finally {
      if (identical(_playerShutdownGate, shutdownGate)) {
        _playerShutdownGate = null;
      }
      shutdownGate.complete();
    }
  }

  @override
  void onClose() async {
    Log.w("播放器关闭");
    await closePlayerResources();
    super.onClose();
  }
}
