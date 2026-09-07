import 'dart:async';
import 'dart:io';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/widgets/ios_render_cap_selector.dart';
import 'package:simple_live_app/modules/live_room/vod/vod_episode_panel.dart';
import 'package:simple_live_app/widgets/superchat_card.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:window_manager/window_manager.dart';

Widget playerControls(
  VideoState videoState,
  LiveRoomController controller,
) {
  return Obx(() {
    if (controller.fullScreenState.value) {
      return buildFullControls(
        videoState,
        controller,
      );
    }
    return buildControls(
      videoState.context.orientation == Orientation.portrait,
      videoState,
      controller,
    );
  });
}

EdgeInsets _fullScreenControlPadding(BuildContext context) {
  final mediaQuery = MediaQuery.of(context);
  if (Platform.isIOS && mediaQuery.orientation == Orientation.landscape) {
    final padding = mediaQuery.viewPadding;
    return EdgeInsets.only(left: padding.left, right: padding.right);
  }
  return mediaQuery.padding;
}

Widget buildFullControls(
  VideoState videoState,
  LiveRoomController controller,
) {
  final padding = _fullScreenControlPadding(videoState.context);
  final volumeButtonKey = GlobalKey();
  final controls = _buildPlayerMouseRegion(
    videoState: videoState,
    controller: controller,
    child: Stack(
      children: [
        const SizedBox.expand(),
        buildDanmuView(videoState, controller),
        _buildPlayerSuperChatOverlay(controller),
        _buildBufferingIndicator(videoState),
        _buildGestureLayer(
          controller,
          enableQuickAccessLongPress: true,
        ),
        _buildFullTopBar(
          controller,
          padding: padding,
        ),
        _buildFullBottomBar(
          controller,
          padding: padding,
          volumeButtonKey: volumeButtonKey,
        ),
        _buildSideLockButton(
          controller,
          padding: padding,
          alignLeft: false,
        ),
        _buildSideLockButton(
          controller,
          padding: padding,
          alignLeft: true,
        ),
        _buildGestureTip(controller),
      ],
    ),
  );

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    return DragToMoveArea(child: controls);
  }
  return controls;
}

Widget buildLockButton(LiveRoomController controller) {
  return Obx(
    () => Center(
      child: InkWell(
        onTap: controller.setLockState,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black45,
            borderRadius: AppStyle.radius8,
          ),
          width: 40,
          height: 40,
          child: Center(
            child: Icon(
              controller.lockControlsState.value
                  ? Icons.lock_outline_rounded
                  : Icons.lock_open_outlined,
              color: Colors.white,
              size: 20,
            ),
          ),
        ),
      ),
    ),
  );
}

Widget buildControls(
  bool isPortrait,
  VideoState videoState,
  LiveRoomController controller,
) {
  final volumeButtonKey = GlobalKey();
  return _buildPlayerMouseRegion(
    videoState: videoState,
    controller: controller,
    child: Stack(
      children: [
        const SizedBox.expand(),
        buildDanmuView(videoState, controller),
        _buildPlayerSuperChatOverlay(controller),
        _buildBufferingIndicator(videoState),
        _buildGestureLayer(controller),
        _buildNormalBottomBar(
          controller,
          isPortrait: isPortrait,
          volumeButtonKey: volumeButtonKey,
        ),
        _buildGestureTip(controller),
      ],
    ),
  );
}

Widget _buildPlayerMouseRegion({
  required VideoState videoState,
  required LiveRoomController controller,
  required Widget child,
}) {
  return Obx(
    () => MouseRegion(
      cursor: controller.hideMouseCursorState.value
          ? SystemMouseCursors.none
          : SystemMouseCursors.basic,
      onEnter: controller.onEnter,
      onExit: controller.onExit,
      onHover: (event) {
        controller.resetHideMouseCursorTimer();
        controller.showMouseCursor();
        controller.onHover(event, videoState.context);
      },
      child: child,
    ),
  );
}

Widget _buildPlayerSuperChatOverlay(LiveRoomController controller) {
  return Obx(() {
    if (!AppSettingsController.instance.playershowSuperChat.value) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: 24,
      bottom: 24,
      child: PlayerSuperChatOverlay(controller: controller),
    );
  });
}


Widget _buildBufferingIndicator(VideoState videoState) {
  return Center(
    child: StreamBuilder<bool>(
      stream: videoState.widget.controller.player.stream.buffering,
      initialData: videoState.widget.controller.player.state.buffering,
      builder: (_, snapshot) {
        if (!(snapshot.data ?? false)) {
          return const SizedBox.shrink();
        }
        return const CircularProgressIndicator();
      },
    ),
  );
}

Widget _buildGestureLayer(
  LiveRoomController controller, {
  bool enableQuickAccessLongPress = false,
}) {
  return Positioned.fill(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(
          constraints.hasBoundedWidth ? constraints.maxWidth : Get.width,
          constraints.hasBoundedHeight ? constraints.maxHeight : Get.height,
        );
        return Obx(() {
          final gestureEnabled =
              AppSettingsController.instance.playerGestureControlEnable.value;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: controller.onTap,
            onDoubleTap: controller.onDoubleTap,
            onLongPress: !enableQuickAccessLongPress
                ? null
                : () {
                    if (controller.lockControlsState.value) {
                      return;
                    }
                    showQuickAccess(controller);
                  },
            onVerticalDragStart: gestureEnabled
                ? (details) => controller.onVerticalDragStart(
                      details,
                      viewportSize: viewportSize,
                    )
                : null,
            onVerticalDragUpdate:
                gestureEnabled ? controller.onVerticalDragUpdate : null,
            onVerticalDragEnd:
                gestureEnabled ? controller.onVerticalDragEnd : null,
            onVerticalDragCancel:
                gestureEnabled ? controller.onVerticalDragCancel : null,
            child: const SizedBox.expand(),
          );
        });
      },
    ),
  );
}

Widget _buildFullTopBar(
  LiveRoomController controller, {
  required EdgeInsets padding,
}) {
  return Obx(() {
    final visible = controller.showControlsState.value &&
        !controller.lockControlsState.value;
    final detail = controller.detail.value;
    final title = detail?.title ?? "直播间";
    final userName = detail?.userName ?? "";
    final displayTitle = userName.isEmpty ? title : "$title - $userName";

    return AnimatedPositioned(
        left: 0,
        right: 0,
        top: visible ? 0 : -(48 + padding.top),
      duration: const Duration(milliseconds: 200),
      child: Container(
        height: 48 + padding.top,
        padding: EdgeInsets.only(
          left: padding.left + 12,
          right: padding.right + 12,
          top: padding.top,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Colors.transparent,
              Colors.black87,
            ],
          ),
        ),
        child: Row(
          children: [
            IconButton(
              onPressed: () {
                if (controller.smallWindowState.value) {
                  controller.exitSmallWindow();
                } else {
                  controller.exitFull();
                }
              },
              icon: const Icon(
                Icons.arrow_back,
                color: Colors.white,
                size: 24,
              ),
            ),
            AppStyle.hGap12,
            Expanded(
              child: Text(
                displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                ),
              ),
            ),
            AppStyle.hGap12,
            IconButton(
              onPressed: () => showQuickAccess(controller),
              icon: const Icon(
                Remix.play_list_2_line,
                color: Colors.white,
                size: 24,
              ),
            ),
            if (Platform.isAndroid)
              IconButton(
                onPressed: controller.enablePIP,
                icon: const Icon(
                  Icons.picture_in_picture,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            IconButton(
              onPressed: () => showPlayerSettings(controller),
              icon: const Icon(
                Icons.more_horiz,
                color: Colors.white,
                size: 24,
              ),
            ),
          ],
        ),
      ),
    );
  });
}

Widget _buildFullBottomBar(
  LiveRoomController controller, {
  required EdgeInsets padding,
  required GlobalKey volumeButtonKey,
}) {
  return Obx(() {
    final visible = controller.showControlsState.value &&
        !controller.lockControlsState.value;
    final showDanmaku = controller.showDanmakuState.value;

    return AnimatedPositioned(
        left: 0,
        right: 0,
        bottom: visible ? 0 : -(80 + padding.bottom),
      duration: const Duration(milliseconds: 200),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black87,
            ],
          ),
        ),
        padding: EdgeInsets.only(
          left: padding.left + 12,
          right: padding.right + 12,
          bottom: padding.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // VOD（影视库）时顶部叠一条进度条，其余按钮与直播完全一致
            if (controller.isVod) _VodProgressBar(controller: controller),
            Row(
              children: [
            IconButton(
              onPressed: controller.refreshRoom,
              icon: const Icon(
                Remix.refresh_line,
                color: Colors.white,
              ),
            ),
            IconButton(
              onPressed: () {
                controller.setDanmakuVisible(!showDanmaku);
              },
              icon: ImageIcon(
                AssetImage(
                  showDanmaku
                      ? 'assets/icons/icon_danmaku_close.png'
                      : 'assets/icons/icon_danmaku_open.png',
                ),
                size: 24,
                color: Colors.white,
              ),
            ),
            IconButton(
              onPressed: () => controller.showCastSheet(),
              icon: const Icon(Icons.cast, color: Colors.white),
            ),
            Obx(
              () => IconButton(
                tooltip: "纯音频模式",
                onPressed: () {
                  AppSettingsController.instance.setAudioOnlyBackground(
                    !AppSettingsController.instance.audioOnlyBackground.value,
                  );
                },
                icon: Icon(
                  AppSettingsController.instance.audioOnlyBackground.value
                      ? Icons.music_note_rounded
                      : Icons.music_note_outlined,
                  color:
                      AppSettingsController.instance.audioOnlyBackground.value
                          ? const Color(0xFFFF8FAB)
                          : Colors.white,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                controller.liveDuration.value,
                style: const TextStyle(fontSize: 14, color: Colors.white),
              ),
            ),
            const Expanded(child: SizedBox()),
            if (!Platform.isAndroid && !Platform.isIOS)
              IconButton(
                key: volumeButtonKey,
                onPressed: () {
                  final context = volumeButtonKey.currentContext;
                  if (context == null) {
                    return;
                  }
                  controller.showVolumeSlider(
                    context,
                    keepAlive: true,
                  );
                },
                icon: Icon(
                  controller.mutedState.value
                      ? Icons.volume_off
                      : Icons.volume_down,
                  size: 24,
                  color: Colors.white,
                ),
              ),
            IconButton(
              onPressed: controller.toggleMute,
              icon: Icon(
                controller.mutedState.value
                    ? Icons.volume_off
                    : Icons.volume_up,
                size: 24,
                color: Colors.white,
              ),
            ),
            TextButton(
              onPressed: () => showQualitesInfo(controller),
              child: Text(
                controller.currentQualityInfo.value,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
            TextButton(
              onPressed: () => showLinesInfo(controller),
              child: Text(
                controller.currentLineInfo.value,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
            if (controller.isVod)
              TextButton(
                onPressed: () => showPlaybackSpeedSheet(controller),
                child: Obx(
                  () => Text(
                    '${controller.playbackRate.value.toStringAsFixed(2)}x',
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  ),
                ),
              ),
            IconButton(
              onPressed: () {
                if (controller.smallWindowState.value) {
                  controller.exitSmallWindow();
                } else {
                  controller.exitFull();
                }
              },
              icon: const Icon(
                Remix.fullscreen_exit_fill,
                color: Colors.white,
              ),
            ),
              ],
            ),
          ],
        ),
      ),
    );
  });
}

Widget _buildNormalBottomBar(
  LiveRoomController controller, {
  required bool isPortrait,
  required GlobalKey volumeButtonKey,
}) {
  return Obx(() {
    final showDanmaku = controller.showDanmakuState.value;
    return AnimatedPositioned(
      left: 0,
      right: 0,
      bottom: controller.showControlsState.value ? 0 : -48,
      duration: const Duration(milliseconds: 200),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black87,
            ],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // VOD（影视库）时顶部叠一条进度条，其余按钮与直播完全一致
            if (controller.isVod) _VodProgressBar(controller: controller),
            Row(
              children: [
            IconButton(
              onPressed: controller.refreshRoom,
              icon: const Icon(
                Remix.refresh_line,
                color: Colors.white,
              ),
            ),
            IconButton(
              onPressed: () {
                controller.setDanmakuVisible(!showDanmaku);
              },
              icon: ImageIcon(
                AssetImage(
                  showDanmaku
                      ? 'assets/icons/icon_danmaku_close.png'
                      : 'assets/icons/icon_danmaku_open.png',
                ),
                size: 24,
                color: Colors.white,
              ),
            ),
            IconButton(
              onPressed: () => controller.showCastSheet(),
              icon: const Icon(Icons.cast, color: Colors.white),
            ),
            Obx(
              () => IconButton(
                tooltip: "纯音频模式",
                onPressed: () {
                  AppSettingsController.instance.setAudioOnlyBackground(
                    !AppSettingsController.instance.audioOnlyBackground.value,
                  );
                },
                icon: Icon(
                  AppSettingsController.instance.audioOnlyBackground.value
                      ? Icons.music_note_rounded
                      : Icons.music_note_outlined,
                  color:
                      AppSettingsController.instance.audioOnlyBackground.value
                          ? const Color(0xFFFF8FAB)
                          : Colors.white,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                controller.liveDuration.value,
                style: const TextStyle(fontSize: 14, color: Colors.white),
              ),
            ),
            const Expanded(child: SizedBox()),
            if (!Platform.isAndroid && !Platform.isIOS)
              IconButton(
                key: volumeButtonKey,
                onPressed: () {
                  final context = volumeButtonKey.currentContext;
                  if (context == null) {
                    return;
                  }
                  controller.showVolumeSlider(
                    context,
                    keepAlive: true,
                  );
                },
                icon: Icon(
                  controller.mutedState.value
                      ? Icons.volume_off
                      : Icons.volume_down,
                  size: 24,
                  color: Colors.white,
                ),
              ),
            IconButton(
              onPressed: controller.toggleMute,
              icon: Icon(
                controller.mutedState.value
                    ? Icons.volume_off
                    : Icons.volume_up,
                size: 24,
                color: Colors.white,
              ),
            ),
            if (!isPortrait)
              TextButton(
                onPressed: () => showQualitesInfo(controller),
                child: Text(
                  controller.currentQualityInfo.value,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
            if (!isPortrait)
              TextButton(
                onPressed: () => showLinesInfo(controller),
                child: Text(
                  controller.currentLineInfo.value,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
            if (controller.isVod)
              TextButton(
                onPressed: () => showPlaybackSpeedSheet(controller),
                child: Obx(
                  () => Text(
                    '${controller.playbackRate.value.toStringAsFixed(2)}x',
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  ),
                ),
              ),
            if (controller.isVod)
              Obx(
                () => controller.hasVodEpisodes.value
                    ? TextButton(
                        onPressed: () => showVodEpisodeSheet(controller),
                        child: const Text(
                          '选集',
                          style: TextStyle(color: Colors.white, fontSize: 15),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            if (!Platform.isAndroid && !Platform.isIOS)
              IconButton(
                onPressed: controller.enterSmallWindow,
                icon: const Icon(
                  Icons.picture_in_picture,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            IconButton(
              onPressed: controller.enterFullScreen,
              icon: const Icon(
                Remix.fullscreen_line,
                color: Colors.white,
              ),
            ),
              ],
            ),
          ],
        ),
      ),
    );
  });
}

Widget _buildSideLockButton(
  LiveRoomController controller, {
  required EdgeInsets padding,
  required bool alignLeft,
}) {
  return Obx(() {
    final visible = controller.lockControlsState.value
        ? controller.showLockEdgeState.value
        : controller.showControlsState.value;
    final offset = -(64 + (alignLeft ? padding.left : padding.right));
    return AnimatedPositioned(
      top: 0,
      bottom: 0,
      left: alignLeft ? (visible ? padding.left + 12 : offset) : null,
      right: alignLeft ? null : (visible ? padding.right + 12 : offset),
      duration: const Duration(milliseconds: 200),
      child: buildLockButton(controller),
    );
  });
}

Widget _buildGestureTip(LiveRoomController controller) {
  return Obx(() {
    final text = controller.gestureTipText.value.trim();
    if (!controller.showGestureTip.value || text.isEmpty) {
      return const SizedBox.shrink();
    }
    return Center(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          text,
          style: const TextStyle(fontSize: 18, color: Colors.white),
        ),
      ),
    );
  });
}

Widget buildDanmuView(VideoState videoState, LiveRoomController controller) {
  var padding = controller.fullScreenState.value
      ? _fullScreenControlPadding(videoState.context)
      : MediaQuery.of(videoState.context).padding;
  return Positioned.fill(
    top: padding.top,
    bottom: padding.bottom,
    child: Obx(
      () {
        controller.danmakuViewVersion.value;
        return Offstage(
          offstage: !controller.showDanmakuState.value,
          child: Padding(
            padding: controller.fullScreenState.value
                ? EdgeInsets.only(
                    top: AppSettingsController.instance.danmuTopMargin.value,
                    bottom: AppSettingsController.instance.danmuBottomMargin.value,
                  )
                : EdgeInsets.zero,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final viewportHeight = constraints.maxHeight > 0
                    ? constraints.maxHeight
                    : MediaQuery.sizeOf(context).height;
                controller.updateDanmakuViewportHeight(viewportHeight);
                final settings = AppSettingsController.instance;
                final resolvedLineCount = settings.resolveDanmuTargetLineCount(
                  viewportHeight: viewportHeight,
                  area: settings.danmuArea.value,
                  fontSize: settings.danmuSize.value,
                  lineCount: settings.danmuLineCount.value,
                );
                final hideDanmu = resolvedLineCount <= 0;
                return DanmakuScreen(
                  key: controller.globalDanmuKey,
                  createdController: controller.initDanmakuController,
                  option: DanmakuOption(
                    fontSize: settings.danmuSize.value,
                    fontFamily: Platform.isWindows ? "Microsoft YaHei" : null,
                    area: settings.resolveDanmuEffectiveArea(
                      viewportHeight: viewportHeight,
                      area: settings.danmuArea.value,
                      fontSize: settings.danmuSize.value,
                      lineCount: settings.danmuLineCount.value,
                    ),
                    lineHeight: settings.resolveDanmuLineHeight(
                      viewportHeight: viewportHeight,
                      area: settings.danmuArea.value,
                      fontSize: settings.danmuSize.value,
                      lineCount: settings.danmuLineCount.value,
                    ),
                    duration: settings.danmuSpeed.value.toInt(),
                    opacity: settings.danmuOpacity.value,
                    fontWeight: settings.danmuFontWeight.value,
                    // iPad 弹幕降帧：ProMotion 机型（iPad Pro）上 Flutter 界面
                    // 会跑 120Hz，而弹幕是整块全屏 CustomPaint、每帧重绘，
                    // 按 120fps 走等于白烧一倍填充率。这里限定 60fps；滚动
                    // 位置仍由库内 _tick 按时间推进，速度不受影响。
                    //
                    // 只在 iOS 传值：安卓上 Timer 降帧实测抖动 10~50ms、反而
                    // 更卡（2.2.0 已因此回退过一次），iOS 的定时器精度足够，
                    // 且 60fps 本就是目标帧率，不损失观感。
                    frameRate: Platform.isIOS ? 60.0 : null,
                    // 拍板项 A：把「描边宽度」设置项接到 showStroke。
                    // 描边宽度 0 = 关闭描边（每条弹幕少一个 strokeParagraph + 每帧
                    // 少画一遍，CPU 绘制量直接减半）；>0 保持描边（宽度仍由
                    // canvas_danmaku 库内 generateStrokeParagraph 硬编码 2）。
                    showStroke: settings.danmuStrokeWidth.value > 0,
                    hideTop: hideDanmu,
                    hideBottom: hideDanmu,
                    hideScroll: hideDanmu,
                    hideSpecial: hideDanmu,
                  ),
                );
              },
            ),
          ),
        );
      },
    ),
  );
}

void showLinesInfo(LiveRoomController controller) {
  if (controller.useBottomSheetPlayerMenus) {
    controller.showPlayUrlsSheet();
    return;
  }
  Utils.showRightDialog(
    title: "线路选择",
    useSystem: true,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          itemCount: controller.playUrls.length,
          itemBuilder: (_, i) {
            return ListTile(
              selected: controller.currentLineIndex == i,
              title: Text.rich(
                TextSpan(
                  text: "线路${i + 1}",
                  children: [
                    WidgetSpan(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: AppStyle.radius4,
                          border: Border.all(
                            color: Colors.grey,
                          ),
                        ),
                        padding: AppStyle.edgeInsetsH4,
                        margin: AppStyle.edgeInsetsL8,
                        child: Text(
                          controller.playUrls[i].contains(".flv")
                              ? "FLV"
                              : "HLS",
                          style: const TextStyle(
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                style: const TextStyle(fontSize: 14),
              ),
              minLeadingWidth: 16,
              onTap: () {
                Utils.hideRightDialog();
                //controller.currentLineIndex = i;
                //controller.setPlayer();
                controller.changePlayLine(i);
              },
            );
          },
        ),
        buildIosRenderCapSelector(),
      ],
    ),
  );
}

void showQualitesInfo(LiveRoomController controller) {
  if (controller.useBottomSheetPlayerMenus) {
    controller.showQualitySheet();
    return;
  }
  Utils.showRightDialog(
    title: "清晰度",
    useSystem: true,
    child: ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: controller.qualites.length,
      itemBuilder: (_, i) {
        var item = controller.qualites[i];
        return ListTile(
          selected: controller.currentQuality == i,
          title: Text(
            item.quality,
            style: const TextStyle(fontSize: 14),
          ),
          minLeadingWidth: 16,
          onTap: () {
            Utils.hideRightDialog();
            controller.currentQuality = i;
            controller.getPlayUrl();
          },
        );
      },
    ),
  );
}

void showPlayerSettings(LiveRoomController controller) {
  if (controller.useBottomSheetPlayerMenus) {
    controller.showPlayerSettingsSheet();
    return;
  }
  Utils.showRightDialog(
    title: "设置",
    width: 320,
    useSystem: true,
    child: Obx(
      () => RadioGroup(
        groupValue: AppSettingsController.instance.scaleMode.value,
        onChanged: (e) {
          AppSettingsController.instance.setScaleMode(e ?? 0);
          controller.updateScaleMode();
        },
        child: ListView(
          padding: AppStyle.edgeInsetsV12,
          children: [
            Padding(
              padding: AppStyle.edgeInsetsH16,
              child: Text(
                "画面尺寸",
                style: Get.textTheme.titleMedium,
              ),
            ),
            const RadioListTile(
              value: 0,
              contentPadding: AppStyle.edgeInsetsH4,
              title: Text("适应"),
              visualDensity: VisualDensity.compact,
            ),
            const RadioListTile(
              value: 1,
              contentPadding: AppStyle.edgeInsetsH4,
              title: Text("拉伸"),
              visualDensity: VisualDensity.compact,
            ),
            const RadioListTile(
              value: 2,
              contentPadding: AppStyle.edgeInsetsH4,
              title: Text("铺满"),
              visualDensity: VisualDensity.compact,
            ),
            const RadioListTile(
              value: 3,
              contentPadding: AppStyle.edgeInsetsH4,
              title: Text("16:9"),
              visualDensity: VisualDensity.compact,
            ),
            const RadioListTile(
              value: 4,
              contentPadding: AppStyle.edgeInsetsH4,
              title: Text("4:3"),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    ),
  );
}

/// 点播进度条：播放/暂停 + 可拖动进度 + 当前/总时长。
class _VodProgressBar extends StatefulWidget {
  final LiveRoomController controller;
  const _VodProgressBar({required this.controller});

  @override
  State<_VodProgressBar> createState() => _VodProgressBarState();
}

class _VodProgressBarState extends State<_VodProgressBar> {
  bool _dragging = false;
  double _dragValue = 0;

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '${h.toString().padLeft(2, '0')}:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final player = c.player;
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      builder: (_, posSnap) {
        return StreamBuilder<Duration>(
          stream: player.stream.duration,
          builder: (_, durSnap) {
            // media_kit 的 position/duration 流是 broadcast 无缓存：媒体时长只
            // 在加载/变化时发一次，控件切全屏/重建后新建订阅永远收不到旧事件，
            // duration 会一直显示 0（进度条 max=1 拖不动）。用 state.* 当前值
            // 兜底 —— state 是属性镜像，保留最后值，新订阅者随时能读到。
            final position = posSnap.data ?? player.state.position;
            final duration = durSnap.data ?? player.state.duration;
            final totalSec =
                duration.inSeconds > 0 ? duration.inSeconds.toDouble() : 1.0;
            final currentSec = _dragging
                ? _dragValue
                : position.inSeconds.toDouble();
            return Row(
              children: [
                StreamBuilder<bool>(
                  stream: player.stream.playing,
                  builder: (_, playingSnap) {
                    final playing = playingSnap.data ?? false;
                    return IconButton(
                      icon: Icon(
                        playing ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                        size: 22,
                      ),
                      onPressed: () {
                        if (player.state.playing) {
                          player.pause();
                        } else {
                          player.play();
                        }
                      },
                    );
                  },
                ),
                const SizedBox(width: 4),
                Text(
                  _fmt(position),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white38,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white24,
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                    ),
                    child: Slider(
                      value: currentSec.clamp(0, totalSec),
                      max: totalSec,
                      onChanged: (v) {
                        setState(() {
                          _dragging = true;
                          _dragValue = v;
                        });
                      },
                      onChangeEnd: (v) {
                        _dragging = false;
                        player.seek(Duration(seconds: v.toInt()));
                      },
                    ),
                  ),
                ),
                Text(
                  _fmt(duration),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                const SizedBox(width: 4),
              ],
            );
          },
        );
      },
    );
  }
}

/// 倍速选择：移动端用底部弹层，桌面端用右侧对话框。
void showPlaybackSpeedSheet(LiveRoomController controller) {
  final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  if (controller.useBottomSheetPlayerMenus) {
    Get.bottomSheet(
      SafeArea(
        child: Obx(
          () => Column(
            mainAxisSize: MainAxisSize.min,
            children: speeds
                .map(
                  (s) => ListTile(
                    selected: (controller.playbackRate.value - s).abs() < 0.001,
                    title: Text('${s.toStringAsFixed(2)}x'),
                    onTap: () {
                      controller.setPlaybackRate(s);
                      Get.back();
                    },
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
    return;
  }
  Utils.showRightDialog(
    title: '播放速度',
    width: 240,
    useSystem: true,
    child: Obx(
      () => ListView(
        padding: AppStyle.edgeInsetsA12,
        children: speeds
            .map(
              (s) => RadioListTile<double>(
                title: Text('${s.toStringAsFixed(2)}x'),
                value: s,
                groupValue: controller.playbackRate.value,
                onChanged: (v) {
                  if (v != null) controller.setPlaybackRate(v);
                  Utils.hideRightDialog();
                },
              ),
            )
            .toList(),
      ),
    ),
  );
}

void showQuickAccess(LiveRoomController controller) {
  final keys = controller.enabledQuickAccessKeys;
  if (keys.isEmpty) {
    SmartDialog.showToast("没有东西可展示");
    return;
  }
  if (keys.length == 1) {
    _openQuickAccessItem(controller, keys.single);
    return;
  }
  if (controller.useBottomSheetPlayerMenus) {
    controller.showQuickAccessSheet();
    return;
  }

  Utils.showRightDialog(
    title: "快捷入口",
    width: 320,
    useSystem: true,
    child: ListView(
      padding: AppStyle.edgeInsetsV12,
      children:
          keys.map((key) => _buildQuickAccessTile(controller, key)).toList(),
    ),
  );
}

Widget _buildQuickAccessTile(LiveRoomController controller, String key) {
  final item = Constant.allLiveRoomQuickAccess[key]!;
  final enabled =
      key != "recommendation" || controller.hasCategoryRecommendation;
  final sub = controller.quickAccessSubtitle(key);
  return ListTile(
    leading: Icon(item.iconData),
    title: Text(controller.quickAccessTitle(key)),
    subtitle: sub.isEmpty ? null : Text(sub),
    enabled: enabled,
    onTap: !enabled
        ? null
        : () async {
            await Utils.switchRightDialog(() async {
              _openQuickAccessItem(controller, key);
            });
          },
  );
}

void _openQuickAccessItem(LiveRoomController controller, String key) {
  switch (key) {
    case "follow":
      showFollowUser(controller);
      break;
    case "history":
      controller.openHistoryPage();
      break;
    case "recommendation":
      controller.openCategoryRecommendation();
      break;
    case "contribution_rank":
      controller.showContributionRankSheet();
      break;
  }
}

void showFollowUser(LiveRoomController controller) {
  if (controller.useBottomSheetPlayerMenus) {
    controller.showFollowUserSheet();
    return;
  }

  Utils.showRightDialog(
    title: "关注列表",
    width: 400,
    useSystem: true,
    child: controller.buildFollowUserSelection(
      onClose: Utils.hideRightDialog,
      scrollController: controller.liveRoomFollowDialogScrollController,
    ),
  );
}

class PlayerSuperChatCard extends StatefulWidget {
  final LiveSuperChatMessage message;
  final VoidCallback onExpire;
  final int duration;
  final VoidCallback? onUserTap;
  final VoidCallback? onUserLongPress;
  const PlayerSuperChatCard(
      {required this.message,
      required this.onExpire,
      required this.duration,
      this.onUserTap,
      this.onUserLongPress,
      Key? key})
      : super(key: key);
  @override
  State<PlayerSuperChatCard> createState() => _PlayerSuperChatCardState();
}

class _PlayerSuperChatCardState extends State<PlayerSuperChatCard> {
  Timer? timer;
  late int countdown;
  @override
  void initState() {
    super.initState();
    _restartCountdown();
  }

  void _restartCountdown() {
    timer?.cancel();
    countdown = widget.duration;
    timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (countdown <= 1) {
        widget.onExpire();
        timer?.cancel();
        return;
      }
      setState(() {
        countdown = (countdown - 1).clamp(0, 1 << 30).toInt();
      });
    });
  }

  @override
  void didUpdateWidget(covariant PlayerSuperChatCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message != widget.message ||
        oldWidget.duration != widget.duration) {
      _restartCountdown();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.65,
      child: SuperChatCard(
        widget.message,
        onExpire: () {},
        customCountdown: countdown,
        onUserTap: widget.onUserTap,
        onUserLongPress: widget.onUserLongPress,
      ),
    );
  }
}

class LocalDisplaySC {
  LiveSuperChatMessage sc;
  final DateTime expireAt;
  final int duration;
  LocalDisplaySC(this.sc, this.expireAt, this.duration);

  String get fingerprint {
    final id = sc.id?.trim();
    if (id != null && id.isNotEmpty) {
      return "id:$id";
    }
    return "${sc.userName}|${sc.message}|${sc.price}|${sc.startTime.millisecondsSinceEpoch}";
  }
}

class PlayerSuperChatOverlay extends StatefulWidget {
  final LiveRoomController controller;
  const PlayerSuperChatOverlay({required this.controller, Key? key})
      : super(key: key);
  @override
  State<PlayerSuperChatOverlay> createState() => _PlayerSuperChatOverlayState();
}

class _PlayerSuperChatOverlayState extends State<PlayerSuperChatOverlay> {
  final List<LocalDisplaySC> _displayed = [];
  final Map<LocalDisplaySC, Timer> _timers = {};
  late Worker _worker;

  String _fingerprintOf(LiveSuperChatMessage sc) {
    final id = sc.id?.trim();
    if (id != null && id.isNotEmpty) {
      return "id:$id";
    }
    return "${sc.userName}|${sc.message}|${sc.price}|${sc.startTime.millisecondsSinceEpoch}";
  }

  void _removeLocalSC(LocalDisplaySC localSC) {
    _displayed.remove(localSC);
    _timers.remove(localSC)?.cancel();
  }

  void _addSC(LiveSuperChatMessage sc, {int? customSeconds}) {
    final fingerprint = _fingerprintOf(sc);
    int showSeconds = (customSeconds ?? 15).clamp(1, 1 << 30).toInt();
    final currentIndex = _displayed.indexWhere(
      (e) => e.fingerprint == fingerprint,
    );
    if (currentIndex >= 0) {
      final current = _displayed[currentIndex];
      current.sc = sc;
      setState(() {});
      return;
    }
    final expireAt = DateTime.now().add(Duration(seconds: showSeconds));
    final localSC = LocalDisplaySC(sc, expireAt, showSeconds);
    _displayed.add(localSC);
    _timers[localSC] = Timer(Duration(seconds: showSeconds), () {
      setState(() {
        _removeLocalSC(localSC);
      });
    });
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    // 初始化时先把仍在有效期内的头条恢复到播放器悬浮层里。
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var sc in widget.controller.superChats) {
      int remain = (sc.endTime.millisecondsSinceEpoch - now) ~/ 1000;
      if (remain > 0) {
        _addSC(sc, customSeconds: remain < 15 ? remain : 15);
      }
    }
    // 监听头条列表变化，同步更新悬浮展示队列。
    _worker =
        ever<List<LiveSuperChatMessage>>(widget.controller.superChats, (list) {
      for (var sc in list) {
        final remain = sc.endTime.difference(DateTime.now()).inSeconds;
        _addSC(sc, customSeconds: remain > 0 && remain < 15 ? remain : 15);
      }
      final latestFingerprints = list.map(_fingerprintOf).toSet();
      for (final localSC in _displayed.toList()) {
        if (!latestFingerprints.contains(localSC.fingerprint)) {
          _removeLocalSC(localSC);
        }
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _worker.dispose();
    for (var t in _timers.values) {
      t.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _displayed.toList()
      ..sort((a, b) => a.sc.endTime.compareTo(b.sc.endTime));
    if (AppSettingsController.instance.superChatSortDesc.value) {
      sorted.replaceRange(0, sorted.length, sorted.reversed);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var localSC in sorted)
          Padding(
            key: ValueKey(localSC.fingerprint),
            padding: const EdgeInsets.only(bottom: 12),
            child: SizedBox(
              width: 240,
              child: PlayerSuperChatCard(
                key: ValueKey(localSC.fingerprint),
                message: localSC.sc,
                onExpire: () {
                  setState(() {
                    _removeLocalSC(localSC);
                  });
                },
                duration: localSC.duration,
                onUserTap: () => widget.controller.showUserActions(
                  localSC.sc.userName,
                  messageContent: localSC.sc.message,
                ),
                onUserLongPress: () =>
                    widget.controller.copyUserName(localSC.sc.userName),
              ),
            ),
          ),
      ],
    );
  }
}

/// 选集弹层：全屏时点「选集」按钮弹出季/集面板（复用集数 tab 组件）。
void showVodEpisodeSheet(LiveRoomController controller) {
  final child = SizedBox(
    height: 360,
    child: VodEpisodePanel(controller: controller),
  );
  if (controller.useBottomSheetPlayerMenus) {
    Utils.showBottomSheet(
      title: "选集",
      child: child,
    );
    return;
  }
  Utils.showRightDialog(
    title: "选集",
    useSystem: true,
    child: child,
  );
}
