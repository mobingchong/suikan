import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:lottie/lottie.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/player/player_controls.dart';
import 'package:simple_live_app/modules/live_room/vod/vod_episode_panel.dart';
import 'package:simple_live_app/modules/live_room/vod/vod_info_panel.dart';
import 'package:simple_live_app/modules/live_room/widgets/live_contribution_rank_panel.dart';
import 'package:simple_live_app/widgets/keep_alive_wrapper.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/settings/settings_action.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/settings/settings_menu.dart';
import 'package:simple_live_app/widgets/settings/settings_number.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';
import 'package:simple_live_app/widgets/status/app_empty_widget.dart';
import 'package:simple_live_app/widgets/superchat_card.dart';
import 'package:simple_live_core/simple_live_core.dart';

class LiveRoomPage extends GetView<LiveRoomController> {
  static const double _desktopSidePanelWidth = 300.0;
  static const double _desktopSidePanelCollapsedWidth = 48.0;

  const LiveRoomPage({Key? key}) : super(key: key);

  double _bottomSafeInset(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final viewPadding = mediaQuery.viewPadding.bottom;
    final padding = mediaQuery.padding.bottom;
    return viewPadding > padding ? viewPadding : padding;
  }

  double _bottomActionInset(BuildContext context) {
    if (Platform.isIOS &&
        MediaQuery.of(context).orientation == Orientation.landscape) {
      return 0;
    }
    final safeInset = _bottomSafeInset(context);
    if (!Platform.isIOS) {
      return safeInset;
    }
    return safeInset.clamp(0.0, 16.0).toDouble();
  }

  bool get _isDesktop {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  double _landscapeSideWidth(double maxWidth) {
    if (maxWidth <= _desktopSidePanelWidth) {
      return 0.0;
    }
    if (_isDesktop && controller.desktopSidePanelCollapsed.value) {
      return _desktopSidePanelCollapsedWidth;
    }
    return _desktopSidePanelWidth;
  }

  Widget _buildRoomTitleText() {
    return Obx(
      () => Text(
        controller.detail.value?.title ?? "直播间",
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildMobileAppBarTitle(BuildContext context) {
    return SizedBox(
      height: kToolbarHeight,
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: kToolbarHeight),
              child: Center(
                child: _buildRoomTitleText(),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              onPressed: () => _handleBack(context),
              icon: const Icon(Icons.arrow_back),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              onPressed: showMore,
              icon: const Icon(Icons.more_horiz),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLandscapeAppBarTitle(BuildContext context) {
    if (_isDesktop) {
      return Obx(() => _buildLandscapeAppBarTitleContent(context));
    }
    return _buildLandscapeAppBarTitleContent(context);
  }

  Widget _buildLandscapeAppBarTitleContent(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final sidePanelWidth = _landscapeSideWidth(constraints.maxWidth);
        final playerWidth = constraints.maxWidth - sidePanelWidth;
        return SizedBox(
          height: kToolbarHeight,
          child: Row(
            children: [
              SizedBox(
                width: playerWidth,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.only(
                          left: kToolbarHeight,
                          right: 16,
                        ),
                        child: Center(
                          child: _buildRoomTitleText(),
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        onPressed: () => _handleBack(context),
                        icon: const Icon(Icons.arrow_back),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: sidePanelWidth,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    onPressed: showMore,
                    icon: const Icon(Icons.more_horiz),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDesktopOverlayIconButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withAlpha(120),
        borderRadius: AppStyle.radius24,
        child: IconButton(
          onPressed: onPressed,
          icon: Icon(icon),
          color: Colors.white,
        ),
      ),
    );
  }

  List<Widget> _buildDesktopOverlayButtons(BuildContext context) {
    return [
      // Desktop uses an overlay instead of a Flutter AppBar so the player
      // keeps its full video area. Keep the room title visible on all three
      // desktop targets while retaining the existing edge controls.
      Positioned(
        top: 8,
        left: 56,
        right: 56,
        child: IgnorePointer(
          child: Align(
            alignment: Alignment.topCenter,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(110),
                borderRadius: AppStyle.radius8,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: DefaultTextStyle(
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                    child: _buildRoomTitleText(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      Obx(() {
        if (!controller.showControlsState.value) {
          return const SizedBox.shrink();
        }
        return Stack(
          children: [
            Positioned(
              left: 8,
              top: 8,
              child: _buildDesktopOverlayIconButton(
                tooltip: "返回",
                icon: Icons.arrow_back,
                onPressed: () => _handleBack(context),
              ),
            ),
            Positioned(
              right: 8,
              top: controller.desktopSidePanelCollapsed.value ? 56 : 8,
              child: _buildDesktopOverlayIconButton(
                tooltip: "更多",
                icon: Icons.more_horiz,
                onPressed: showMore,
              ),
            ),
            if (Platform.isWindows &&
                controller.desktopSidePanelCollapsed.value)
              Positioned(
                right: 8,
                top: 8,
                child: _buildDesktopOverlayIconButton(
                  tooltip: "关闭",
                  icon: Icons.close,
                  onPressed: () => _handleBack(context),
                ),
              ),
            if (_isDesktop && controller.desktopSidePanelCollapsed.value)
              Positioned(
                right: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _buildDesktopOverlayIconButton(
                    tooltip: "展开聊天区",
                    icon: Icons.chevron_left,
                    onPressed: controller.toggleDesktopSidePanel,
                  ),
                ),
              ),
          ],
        );
      }),
    ];
  }

  bool _allowsNativePopGesture() {
    return Platform.isIOS &&
        !controller.fullScreenState.value &&
        !controller.smallWindowState.value;
  }

  @override
  Widget build(BuildContext context) {
    final page = Obx(() {
      if (Platform.isAndroid && controller.androidInPipState.value) {
        return _buildPipOnlyPage();
      }
      if (controller.loadError.value) {
        return Scaffold(
          appBar: AppBar(
            title: const Text("直播间加载失败"),
          ),
          body: Padding(
            padding: AppStyle.edgeInsetsA12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                LottieBuilder.asset(
                  'assets/lotties/error.json',
                  height: 140,
                  repeat: false,
                ),
                const Text(
                  "直播间加载失败",
                  textAlign: TextAlign.center,
                ),
                AppStyle.vGap4,
                Text(
                  controller.error?.toString() ?? "未知错误",
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                AppStyle.vGap4,
                Text(
                  "${controller.rxSite.value.id} - ${controller.rxRoomId.value}",
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton.icon(
                      onPressed: controller.copyErrorDetail,
                      icon: const Icon(Remix.file_copy_line),
                      label: const Text("复制信息"),
                    ),
                    TextButton.icon(
                      onPressed: controller.refreshRoom,
                      icon: const Icon(Remix.refresh_line),
                      label: const Text("刷新"),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }
      if (controller.fullScreenState.value) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            controller.exitPlayerWindowMode();
          },
          child: Scaffold(
            body: buildMediaPlayer(),
          ),
        );
      }
      return buildPageUI();
    });
    return page;
  }

  /// Android PiP captures the whole activity. Keep the activity tree limited
  /// to a black video surface so the AppBar, chat and player controls cannot
  /// leak into the system floating window.
  Widget _buildPipOnlyPage() {
    return ColoredBox(
      color: Colors.black,
      child: _buildMediaPlayerContent(pipMode: true),
    );
  }

  Widget buildPageUI() {
    return OrientationBuilder(
      builder: (context, orientation) {
        final shortestSide = MediaQuery.sizeOf(context).shortestSide;
        final isCompactMobile = shortestSide < 600;
        final usePortraitLayout = (Platform.isAndroid || Platform.isIOS) &&
            isCompactMobile &&
            !controller.fullScreenState.value &&
            !controller.smallWindowState.value;
        final effectiveOrientation =
            usePortraitLayout ? Orientation.portrait : orientation;
        final hasLandscapeActionPanel =
            effectiveOrientation == Orientation.landscape;
        if (_isDesktop) {
          final body = effectiveOrientation == Orientation.portrait
              ? buildPhoneUI(context)
              : buildTabletUI(context);
          return PopScope(
            canPop: _allowsNativePopGesture(),
            onPopInvokedWithResult: (didPop, result) async {
              if (didPop) {
                await controller.cancelAutoPipOnLeave();
                return;
              }
              await _handleBack(context);
            },
            child: Scaffold(
              body: MouseRegion(
                onEnter: (_) => controller.showControls(),
                onHover: (_) => controller.showControls(),
                child: Stack(
                  children: [
                    body,
                    ..._buildDesktopOverlayButtons(context),
                  ],
                ),
              ),
            ),
          );
        }
        final scaffold = Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            titleSpacing: 0,
            title: hasLandscapeActionPanel
                ? _buildLandscapeAppBarTitle(context)
                : _buildMobileAppBarTitle(context),
          ),
          body: effectiveOrientation == Orientation.portrait
              ? buildPhoneUI(context)
              : buildTabletUI(context),
        );
        return PopScope(
          canPop: _allowsNativePopGesture(),
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) {
              await controller.cancelAutoPipOnLeave();
              return;
            }
            await _handleBack(context);
          },
          child: scaffold,
        );
      },
    );
  }

  Future<void> _handleBack(BuildContext context) async {
    await controller.cancelAutoPipOnLeave();
    // 返回前完整关闭播放器,避免 texture 释放后 player 推帧导致崩溃
    // onClose 是 void async(fire-and-forget), 不能 await
    controller.onClose();
    if (context.mounted) {
      Navigator.of(context).pop();
    }
  }

  Widget buildPhoneUI(BuildContext context) {
    if (_isDesktop && controller.desktopSidePanelCollapsed.value) {
      return Column(
        children: [
          Expanded(
            child: buildMediaPlayer(),
          ),
          _buildCollapsedDesktopBottomPanel(context),
        ],
      );
    }
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: buildMediaPlayer(),
        ),
        buildUserProfile(context),
        buildMessageArea(),
        buildBottomActions(context),
      ],
    );
  }

  Widget buildTabletUI(BuildContext context) {
    return Obx(() {
      final collapsed =
          _isDesktop && controller.desktopSidePanelCollapsed.value;
      return Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: buildMediaPlayer(),
                ),
                if (!collapsed) _buildExpandedSidePanel(context),
              ],
            ),
          ),
          if (!collapsed)
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                border: Border(
                  top: BorderSide(
                    color: Colors.grey.withAlpha(25),
                  ),
                ),
              ),
              padding: AppStyle.edgeInsetsV4.copyWith(
                bottom: _bottomActionInset(context) + 4,
              ),
              child: Row(
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 14),
                    ),
                    onPressed: controller.refreshRoom,
                    icon: const Icon(Remix.refresh_line),
                    label: const Text("刷新"),
                  ),
                  AppStyle.hGap4,
                  Obx(
                    () => controller.followed.value
                        ? TextButton.icon(
                            style: TextButton.styleFrom(
                              textStyle: const TextStyle(fontSize: 14),
                            ),
                            onPressed: controller.removeFollowUser,
                            icon: const Icon(Remix.heart_fill),
                            label: const Text("取消关注"),
                          )
                        : TextButton.icon(
                            style: TextButton.styleFrom(
                              textStyle: const TextStyle(fontSize: 14),
                            ),
                            onPressed: controller.followUser,
                            icon: const Icon(Remix.heart_line),
                            label: const Text("关注"),
                          ),
                  ),
                  const Expanded(child: Center()),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 14),
                    ),
                    onPressed: controller.share,
                    icon: const Icon(Remix.share_line),
                    label: const Text("分享"),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 14),
                    ),
                    onPressed: controller.copyUrl,
                    icon: const Icon(Remix.file_copy_line),
                    label: const Text("复制链接"),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 14),
                    ),
                    onPressed: controller.copyPlayUrl,
                    icon: const Icon(Remix.file_copy_line),
                    label: const Text("复制播放直链"),
                  ),
                ],
              ),
            ),
        ],
      );
    });
  }

  Widget _buildExpandedSidePanel(BuildContext context) {
    final showCollapseAction = _isDesktop;
    return SizedBox(
      width: _desktopSidePanelWidth,
      child: Column(
        children: [
          if (showCollapseAction)
            Container(
              height: 40,
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                border: Border(
                  left: BorderSide(
                    color: Colors.grey.withAlpha(25),
                  ),
                  bottom: BorderSide(
                    color: Colors.grey.withAlpha(25),
                  ),
                ),
              ),
              alignment: Alignment.centerLeft,
              child: Tooltip(
                message: "折叠聊天区",
                child: IconButton(
                  onPressed: controller.toggleDesktopSidePanel,
                  icon: const Icon(Icons.chevron_right),
                ),
              ),
            ),
          Expanded(
            child: Column(
              children: [
                buildUserProfile(context),
                buildMessageArea(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCollapsedDesktopBottomPanel(BuildContext context) {
    return Container(
      height: 48 + _bottomActionInset(context),
      padding: EdgeInsets.only(bottom: _bottomActionInset(context)),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(
          top: BorderSide(
            color: Colors.grey.withAlpha(25),
          ),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Tooltip(
              message: "展开聊天区",
              child: IconButton(
                onPressed: controller.toggleDesktopSidePanel,
                icon: const Icon(Icons.keyboard_arrow_up),
              ),
            ),
          ),
          const Expanded(
            child: Center(
              child: Icon(
                Icons.chat_bubble_outline,
                size: 18,
                color: Colors.grey,
              ),
            ),
          ),
          const SizedBox(width: 56),
        ],
      ),
    );
  }

  Widget buildMediaPlayer() {
    return _buildMediaPlayerContent();
  }

  Widget _buildMediaPlayerContent({bool pipMode = false}) {
    var boxFit = BoxFit.contain;
    double? aspectRatio;
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
    if (pipMode) {
      // The system PiP bounds use the decoded stream dimensions. Keep the
      // Flutter surface on the same ratio regardless of the user's normal
      // player scale preference.
      boxFit = BoxFit.contain;
      final width = controller.player.state.width ?? 0;
      final height = controller.player.state.height ?? 0;
      aspectRatio = width > 0 && height > 0 ? width / height : null;
    }
    return Stack(
      children: [
        const Positioned.fill(
          child: ColoredBox(color: Colors.black),
        ),
        // 视频控件保持常驻（移除会导致 WIN 端重建黑屏、无法恢复画面）。
        // 纯音频模式时用占位层覆盖画面（点按恢复即时）；VOD 才真正停视频轨（见 onInit）。
        Video(
          key: controller.globalPlayerKey,
          controller: controller.videoController,
          // 恒禁 media_kit 内置的"退后台自暂停"：该机制依赖 widget 参数在
          // 退后台前已被 Obx 重建刷新。而"点纯音频后立刻滑后台"时 App 已
          // paused、帧调度停止，Obx 来不及重建 → Video 用旧的
          // pauseUponEnteringBackgroundMode=true 擅自 pause，与
          // LiveRoomController 的手动纯音频豁免打架（实测：收进通知栏但停了，
          // 要手动点一下播放才续）。
          //
          // 退后台暂停/恢复统一交给 controller.didChangeAppLifecycleState →
          // _enterBackgroundState/_exitBackgroundState 实时裁决（同步读 Rx，
          // 无帧调度延迟，且已正确豁免手动纯音频：audioOnlyBackground 开启时
          // 退后台不暂停）。
          pauseUponEnteringBackgroundMode: false,
          resumeUponEnteringForegroundMode: false,
          controls:
              pipMode ? null : (state) => playerControls(state, controller),
          aspectRatio: aspectRatio,
          fit: boxFit,
          // 自己实现
          wakelock: false,
        ),
        // 纯音频模式占位覆盖层：遮住画面、显示 🎵，点按恢复画面
        Obx(
          () => AppSettingsController.instance.audioOnlyBackground.value
              ? Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      AppSettingsController.instance
                          .setAudioOnlyBackground(false);
                    },
                    child: const ColoredBox(
                      color: Color(0xFF14141A),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.music_note,
                              size: 72,
                              color: Colors.white38,
                            ),
                            SizedBox(height: 12),
                            Text(
                              "纯音频模式",
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 15,
                              ),
                            ),
                            SizedBox(height: 6),
                            Text(
                              "点按恢复画面",
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        if (!pipMode)
          Obx(
            () => Visibility(
              visible: !controller.liveStatus.value,
              child: const Center(
                child: Text(
                  "未开播",
                  style: TextStyle(fontSize: 16, color: Colors.white),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget buildUserProfile(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(
          top: BorderSide(
            color: Colors.grey.withAlpha(25),
          ),
          bottom: BorderSide(
            color: Colors.grey.withAlpha(25),
          ),
        ),
      ),
      padding: AppStyle.edgeInsetsA8.copyWith(
        left: 12,
        right: 12,
      ),
      child: Obx(
        () => Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.withAlpha(50)),
                borderRadius: AppStyle.radius24,
              ),
              child: NetImage(
                controller.detail.value?.userAvatar ?? "",
                width: 48,
                height: 48,
                borderRadius: 24,
              ),
            ),
            AppStyle.hGap12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    controller.detail.value?.userName ?? "",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  AppStyle.vGap4,
                  Row(
                    children: [
                      Image.asset(
                        controller.site.logo,
                        width: 20,
                      ),
                      AppStyle.hGap4,
                      Text(
                        controller.site.name,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            AppStyle.hGap12,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Remix.fire_fill,
                  size: 20,
                  color: Colors.orange,
                ),
                AppStyle.hGap4,
                Text(
                  Utils.onlineToString(
                    controller.online.value,
                  ),
                  style: const TextStyle(fontSize: 14),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget buildBottomActions(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(
          top: BorderSide(
            color: Colors.grey.withAlpha(25),
          ),
        ),
      ),
      padding: EdgeInsets.only(bottom: _bottomActionInset(context)),
      child: Row(
        children: [
          Expanded(
            child: Obx(
              () => controller.followed.value
                  ? TextButton.icon(
                      style: TextButton.styleFrom(
                        textStyle: const TextStyle(fontSize: 14),
                      ),
                      onPressed: controller.removeFollowUser,
                      icon: const Icon(Remix.heart_fill),
                      label: const Text("取消关注"),
                    )
                  : TextButton.icon(
                      style: TextButton.styleFrom(
                        textStyle: const TextStyle(fontSize: 14),
                      ),
                      onPressed: controller.followUser,
                      icon: const Icon(Remix.heart_line),
                      label: const Text("关注"),
                    ),
            ),
          ),
          Expanded(
            child: TextButton.icon(
              style: TextButton.styleFrom(
                textStyle: const TextStyle(fontSize: 14),
              ),
              onPressed: controller.refreshRoom,
              icon: const Icon(Remix.refresh_line),
              label: const Text("刷新"),
            ),
          ),
          Expanded(
            child: TextButton.icon(
              style: TextButton.styleFrom(
                textStyle: const TextStyle(fontSize: 14),
              ),
              onPressed: controller.share,
              icon: const Icon(Remix.share_line),
              label: const Text("分享"),
            ),
          ),
        ],
      ),
    );
  }

  /// 五大平台直播：走原有聊天/关注/动态/设置 tab；其余（影视库/自定义源）走点播布局。
  bool _isLegacyLiveSite(String siteId) {
    return siteId == Constant.kBiliBili ||
        siteId == Constant.kDouyu ||
        siteId == Constant.kHuya ||
        siteId == Constant.kDouyin ||
        siteId == Constant.kKuaishou;
  }

  Widget buildMessageArea() {
    // 聊天列表在 Obx 之外预先构建：它内部自带 Obx 订阅 messages（见
    // buildChatList 注释）。若像原来那样在下面这个 Obx 的 builder 里调用
    // buildChatList()，messages 就会被登记成外层 Obx 的依赖 —— 每来一条
    // 消息，整个 TabBar 连同 SC / 关注 / 贡献榜 / 重点动态 等所有分页
    // 都要重建一遍。热门房每秒 10~30 条消息，等于每秒重建几十次整片区域。
    final chatListPage = buildChatList();
    return Obx(() {
      final isVodLayout = !_isLegacyLiveSite(controller.site.id);
      final hasSuperChatTab = controller.site.id == Constant.kBiliBili ||
          controller.site.id == Constant.kHuya;
      final tabs = <Widget>[];
      final pages = <Widget>[];
      final keys = <String>[];
      void addTab(String key) {
        switch (key) {
          case "chat":
            keys.add(key);
            tabs.add(const Tab(text: "聊天"));
            pages.add(chatListPage);
            break;
          case "super_chat":
            if (!hasSuperChatTab) return;
            keys.add(key);
            tabs.add(
              Tab(
                child: Text(
                  controller.superChats.isNotEmpty
                      ? "${controller.site.id == Constant.kHuya ? "头条" : "SC"}(${controller.superChats.length})"
                      : controller.site.id == Constant.kHuya
                          ? "头条"
                          : "SC",
                ),
              ),
            );
            pages.add(buildSuperChats());
            break;
          case "follow":
            keys.add(key);
            tabs.add(const Tab(text: "关注"));
            pages.add(buildFollowList());
            break;
          case "contribution_rank":
            if (!controller.supportsContributionRank ||
                !AppSettingsController.instance.contributionRankEnable.value) {
              return;
            }
            keys.add(key);
            tabs.add(
              Tab(
                text: controller.site.id == Constant.kDouyu ? "亲密榜" : "贡献榜",
              ),
            );
            pages.add(
              KeepAliveWrapper(
                child: LiveContributionRankPanel(controller: controller),
              ),
            );
            break;
          case "event_flow":
            if (!AppSettingsController.instance.liveEventFlowEnable.value) {
              return;
            }
            keys.add(key);
            tabs.add(
              Tab(
                child: Text(
                  controller.liveEventFlows.isNotEmpty
                      ? "动态(${controller.liveEventFlows.length})"
                      : "动态",
                ),
              ),
            );
            pages.add(buildLiveEventFlow());
            break;
          case "settings":
            keys.add(key);
            tabs.add(const Tab(text: "设置"));
            pages.add(buildSettings());
            break;
        }
      }

      if (isVodLayout) {
        // 点播布局（影视库/自定义直播源）：信息(默认) | 集数(有剧集时) | 关注 | 设置
        keys.add("vod_info");
        tabs.add(const Tab(text: "信息"));
        pages.add(VodInfoPanel(controller: controller));
        if (controller.hasVodEpisodes.value) {
          keys.add("vod_episodes");
          tabs.add(const Tab(text: "集数"));
          pages.add(VodEpisodePanel(controller: controller));
        }
        keys.add("follow");
        tabs.add(const Tab(text: "关注"));
        pages.add(buildFollowList());
        keys.add("settings");
        tabs.add(const Tab(text: "设置"));
        pages.add(buildSettings());
      } else {
        for (final key in AppSettingsController.instance.liveRoomTabSort) {
          addTab(key);
        }
      }
      if (tabs.isEmpty) {
        keys.add("chat");
        tabs.add(const Tab(text: "聊天"));
        pages.add(buildChatList());
      }
      final selectedKey = controller.liveRoomSelectedPanelKey.value;
      final initialIndex =
          keys.contains(selectedKey) ? keys.indexOf(selectedKey) : 0;
      return Expanded(
        child: DefaultTabController(
          key: ValueKey(keys.join("|")),
          length: tabs.length,
          initialIndex: initialIndex,
          child: Column(
            children: [
              TabBar(
                indicatorSize: TabBarIndicatorSize.tab,
                labelPadding: EdgeInsets.zero,
                indicatorWeight: 1.0,
                onTap: (index) {
                  if (index >= 0 && index < keys.length) {
                    controller.liveRoomSelectedPanelKey.value = keys[index];
                  }
                },
                tabs: tabs,
              ),
              Expanded(
                child: TabBarView(
                  children: pages,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget buildChatList() {
    // 自带 Obx，把 messages 的订阅范围收敛到本列表内部。
    //
    // 原先本方法是在 buildMessageArea 那个大 Obx 的 builder 里被调用的，
    // 于是每来一条消息都会让 TabBar 和所有分页（SC / 关注 / 贡献榜 /
    // 重点动态）跟着一起重建。而外层 Obx 真正要管的只是「有哪些 tab、
    // tab 标题显示什么」这类结构信息，变化频率很低。
    return Obx(
      () {
        // 聊天外观设置在这里一次性读取，再传给每条消息（见 buildMessageItem
        // 注释）—— 原先每条消息各自套一个 Obx 订阅，屏内就是几十个 Obx。
        final chatTextSize = AppSettingsController.instance.chatTextSize.value;
        final bubbleStyle =
            AppSettingsController.instance.chatBubbleStyle.value;
        final renderEmoji =
            AppSettingsController.instance.danmuRenderEmoji.value;
        return Stack(
          children: [
            ListView.separated(
              controller: controller.scrollController,
              reverse: false,
              separatorBuilder: (_, i) => SizedBox(
                // *2与原来的EdgeInsets.symmetric(vertical: )做兼容
                height: AppSettingsController.instance.chatTextGap.value * 2,
              ),
              padding: AppStyle.edgeInsetsA12,
              itemCount: controller.messages.length,
              itemBuilder: (_, i) {
                var item = controller.messages[i];
                return buildMessageItem(
                  item,
                  chatTextSize: chatTextSize,
                  bubbleStyle: bubbleStyle,
                  renderEmoji: renderEmoji,
                );
              },
            ),
            Visibility(
              visible: controller.disableAutoScroll.value,
              child: Positioned(
                right: 12,
                bottom: 12,
                child: ElevatedButton.icon(
                  onPressed: () {
                    controller.forceChatScrollToBottom();
                  },
                  icon: const Icon(Icons.expand_more),
                  label: const Text("最新"),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget buildLiveEventFlow() {
    return KeepAliveWrapper(
      child: Obx(() {
        if (!AppSettingsController.instance.liveEventFlowEnable.value) {
          return const AppEmptyWidget(message: "重点动态已关闭");
        }
        if (controller.liveEventFlows.isEmpty) {
          return const AppEmptyWidget(message: "暂未捕捉到重复动态");
        }
        return ListView.separated(
          padding: AppStyle.edgeInsetsA12,
          itemCount: controller.liveEventFlows.length,
          separatorBuilder: (_, i) => AppStyle.vGap8,
          itemBuilder: (_, i) {
            final item = controller.liveEventFlows[i];
            return ListTile(
              visualDensity: VisualDensity.compact,
              contentPadding: AppStyle.edgeInsetsL16.copyWith(right: 12),
              leading: const Icon(Remix.pulse_line),
              title: Text(
                item.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(
                "x${item.count}",
                style: Get.textTheme.titleMedium,
              ),
            );
          },
        );
      }),
    );
  }

  /// 渲染单条聊天消息。
  ///
  /// 聊天外观设置（字号 / 气泡样式 / 是否渲染表情）由调用方**一次性读取后
  /// 传入**。原先是每条消息自己套一个 Obx 订阅这些值，屏内 20~40 条消息就是
  /// 20~40 个 Obx；而这些设置极少变动，放在列表层订阅即可 —— 设置一改就整列
  /// 重建一次，完全可接受。
  Widget buildMessageItem(
    LiveMessage message, {
    required double chatTextSize,
    required bool bubbleStyle,
    required bool renderEmoji,
  }) {
    if (message.userName == "LiveSysMessage") {
      return Text(
        message.message,
        style: TextStyle(
          color: Colors.grey,
          fontSize: chatTextSize,
        ),
      );
    }

    Widget buildMessageContent({
      required TextStyle userStyle,
      required TextStyle messageStyle,
    }) {
      final remark = controller.getUserRemark(message.userName);
      return _InteractiveChatText(
        userName: message.userName,
        remark: remark,
        message: message.message,
        imageUrls: renderEmoji ? message.imageUrls : null,
        spans: renderEmoji ? message.spans : null,
        userStyle: userStyle,
        messageStyle: messageStyle,
        onUserTap: () => controller.showUserActions(
          message.userName,
          messageContent: message.message,
        ),
        onUserLongPress: () => controller.copyUserName(message.userName),
      );
    }

    return bubbleStyle
        ? Row(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.blueGrey.withAlpha(25),
                    borderRadius: const BorderRadius.only(
                      topRight: Radius.circular(12),
                      bottomLeft: Radius.circular(12),
                      bottomRight: Radius.circular(12),
                    ),
                  ),
                  padding:
                      AppStyle.edgeInsetsA4.copyWith(left: 12, right: 12),
                  child: buildMessageContent(
                    userStyle: TextStyle(
                      color: Colors.grey,
                      fontSize: chatTextSize,
                    ),
                    messageStyle: TextStyle(
                      color:
                          Get.isDarkMode ? Colors.white : AppColors.black333,
                      fontSize: chatTextSize,
                    ),
                  ),
                ),
              ),
            ],
          )
        : buildMessageContent(
            userStyle: TextStyle(
              color: Colors.grey,
              fontSize: chatTextSize,
            ),
            messageStyle: TextStyle(
              color: Get.isDarkMode ? Colors.white : AppColors.black333,
              fontSize: chatTextSize,
            ),
          );
  }

  Widget buildSuperChats() {
    return KeepAliveWrapper(
      child: Obx(
        () => controller.superChats.isEmpty
            ? AppEmptyWidget(
                message: controller.site.id == Constant.kHuya
                    ? "当前直播间无头条内容"
                    : "当前直播间无 SC 内容",
              )
            : ListView.separated(
                padding: AppStyle.edgeInsetsA12,
                itemCount: controller.superChats.length,
                separatorBuilder: (_, i) => AppStyle.vGap12,
                itemBuilder: (_, i) {
                  var item = controller.sortedSuperChats[i];
                  return SuperChatCard(
                    item,
                    remark: controller.getUserRemark(item.userName),
                    key: ValueKey(
                      item.id ??
                          "${item.userName}|${item.message}|${item.price}|${item.startTime.millisecondsSinceEpoch}",
                    ),
                    onExpire: () {
                      controller.removeSuperChats();
                    },
                    onUserTap: () => controller.showUserActions(
                      item.userName,
                      messageContent: item.message,
                    ),
                    onUserLongPress: () =>
                        controller.copyUserName(item.userName),
                  );
                },
              ),
      ),
    );
  }

  Widget buildSettings() {
    return ListView(
      padding: AppStyle.edgeInsetsA12,
      children: [
        Obx(
          () => Visibility(
            visible: controller.autoExitEnable.value,
            child: ListTile(
              leading: const Icon(Icons.timer_outlined),
              visualDensity: VisualDensity.compact,
              title: Text("${parseDuration(controller.countdown.value)}后自动关闭"),
            ),
          ),
        ),
        Padding(
          padding: AppStyle.edgeInsetsA12,
          child: Text(
            "聊天区",
            style: Get.textTheme.titleSmall,
          ),
        ),
        SettingsCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Obx(
                () => SettingsNumber(
                  title: "文字大小",
                  value:
                      AppSettingsController.instance.chatTextSize.value.toInt(),
                  min: 8,
                  max: 36,
                  onChanged: (e) {
                    AppSettingsController.instance
                        .setChatTextSize(e.toDouble());
                  },
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsNumber(
                  title: "上下间隔",
                  value:
                      AppSettingsController.instance.chatTextGap.value.toInt(),
                  min: 0,
                  max: 12,
                  onChanged: (e) {
                    AppSettingsController.instance.setChatTextGap(e.toDouble());
                  },
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsSwitch(
                  title: "气泡样式",
                  value: AppSettingsController.instance.chatBubbleStyle.value,
                  onChanged: (e) {
                    AppSettingsController.instance.setChatBubbleStyle(e);
                  },
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsSwitch(
                  title: "播放器中显示SC",
                  value:
                      AppSettingsController.instance.playershowSuperChat.value,
                  onChanged: (e) {
                    AppSettingsController.instance.setPlayerShowSuperChat(e);
                  },
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsMenu<bool>(
                  title: controller.site.id == Constant.kHuya ? "头条排序" : "SC排序",
                  value: AppSettingsController.instance.superChatSortDesc.value,
                  valueMap: const {
                    false: "按消失时间正序",
                    true: "按消失时间倒序",
                  },
                  onChanged: (e) {
                    AppSettingsController.instance.setSuperChatSortDesc(e);
                    controller.superChats.refresh();
                  },
                ),
              ),
              if (controller.supportsContributionRank) ...[
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: controller.site.id == Constant.kDouyu
                        ? "显示亲密榜"
                        : "显示贡献榜",
                                        value: AppSettingsController
                        .instance.contributionRankEnable.value,
                    onChanged: (e) {
                      AppSettingsController.instance
                          .setContributionRankEnable(e);
                      if (e) {
                        controller.fetchContributionRank(forceRefresh: true);
                      }
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: AppStyle.edgeInsetsA12,
          child: Text(
            "重点动态",
            style: Get.textTheme.titleSmall,
          ),
        ),
        SettingsCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Obx(
                () => SettingsSwitch(
                  title: "重点动态",
                                    value:
                      AppSettingsController.instance.liveEventFlowEnable.value,
                  onChanged: (e) {
                    AppSettingsController.instance.setLiveEventFlowEnable(e);
                    if (!e) {
                      controller.clearLiveEventFlow();
                    }
                  },
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsSwitch(
                  title: "全屏显示重点动态",
                                    value: AppSettingsController
                      .instance.liveEventFlowOverlayEnable.value,
                  onChanged: AppSettingsController
                      .instance.setLiveEventFlowOverlayEnable,
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsNumber(
                  title: "动态统计跨度",
                  subtitle: "多少秒内的重复弹幕合并计数",
                  value: AppSettingsController
                      .instance.liveEventFlowWindowSeconds.value,
                  min: AppSettingsController.kLiveEventFlowMinWindowSeconds,
                  max: AppSettingsController.kLiveEventFlowMaxWindowSeconds,
                  step: 5,
                  onChanged: AppSettingsController
                      .instance.setLiveEventFlowWindowSeconds,
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsNumber(
                  title: "动态展示时间",
                  subtitle: "一条动态多久没有更新后自动消失",
                  value: AppSettingsController
                      .instance.liveEventFlowDisplaySeconds.value,
                  min: AppSettingsController.kLiveEventFlowMinDisplaySeconds,
                  max: AppSettingsController.kLiveEventFlowMaxDisplaySeconds,
                  step: 1,
                  onChanged: AppSettingsController
                      .instance.setLiveEventFlowDisplaySeconds,
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsNumber(
                  title: "动态起显次数",
                  subtitle: "同一句重复达到多少次后进入重点动态",
                  value: AppSettingsController
                      .instance.liveEventFlowMinCount.value,
                  min: AppSettingsController.kLiveEventFlowMinCount,
                  max: AppSettingsController.kLiveEventFlowMaxCount,
                  step: 1,
                  onChanged:
                      AppSettingsController.instance.setLiveEventFlowMinCount,
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsNumber(
                  title: "动态保留数量",
                  subtitle: "控制动态页最多保留多少条摘要",
                  value:
                      AppSettingsController.instance.liveEventFlowLimit.value,
                  min: AppSettingsController.kLiveEventFlowMinLimit,
                  max: AppSettingsController.kLiveEventFlowMaxLimit,
                  step: 50,
                  onChanged:
                      AppSettingsController.instance.setLiveEventFlowLimit,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: AppStyle.edgeInsetsA12,
          child: Text(
            "过滤",
            style: Get.textTheme.titleSmall,
          ),
        ),
        SettingsCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Obx(
                () => SettingsSwitch(
                  title: "重复弹幕过滤",
                  subtitle: AppSettingsController.instance.danmuDedupeStrictMode
                      ? "刷屏严父：不同用户重复发同一句也只显示一次"
                      : "普通：同一用户在最近若干条内重复发同一句只显示一次",
                  value: AppSettingsController.instance.danmuDedupeEnable.value,
                  onChanged: (e) {
                    AppSettingsController.instance.setDanmuDedupeEnable(e);
                  },
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsMenu<int>(
                  title: "过滤模式",
                  subtitle: "刷屏严父会忽略用户，只按弹幕内容去重",
                  value: AppSettingsController.instance.danmuDedupeMode.value,
                  valueMap: const {
                    AppSettingsController.kDanmuDedupeModeUser: "普通",
                    AppSettingsController.kDanmuDedupeModeStrict: "刷屏严父",
                  },
                  onChanged: (e) {
                    AppSettingsController.instance.setDanmuDedupeMode(e);
                  },
                ),
              ),
              AppStyle.divider,
              Obx(() {
                final strictMode =
                    AppSettingsController.instance.danmuDedupeStrictMode;
                return SettingsNumber(
                  title: "过滤窗口",
                  subtitle: strictMode
                      ? "严父默认 10 条；超过 20 条可能会让弹幕明显变少"
                      : "默认 10 条；窗口越大越容易过滤刷屏",
                  value: AppSettingsController.instance.danmuDedupeWindow.value,
                  min: AppSettingsController.instance.danmuDedupeWindowMin,
                  max: AppSettingsController.kDanmuDedupeMaxWindow,
                  onChanged: (e) {
                    AppSettingsController.instance.setDanmuDedupeWindow(e);
                    if (AppSettingsController.instance.danmuDedupeStrictMode &&
                        AppSettingsController.instance.danmuDedupeWindow.value >
                            AppSettingsController
                                .kDanmuDedupeStrictWarnWindow) {
                      SmartDialog.showToast("过滤窗口超过 20 条后，弹幕可能会明显变少");
                    }
                  },
                );
              }),
              AppStyle.divider,
              Obx(() {
                if (AppSettingsController.instance.danmuDedupeStrictMode) {
                  return const SizedBox.shrink();
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppStyle.divider,
                    SettingsNumber(
                      title: "过滤步长",
                      subtitle: "默认 2；数值越大检查窗口移动越少",
                      value:
                          AppSettingsController.instance.danmuDedupeStep.value,
                      min: 1,
                      max: 20,
                      onChanged: (e) {
                        AppSettingsController.instance.setDanmuDedupeStep(e);
                      },
                    ),
                  ],
                );
              }),
            ],
          ),
        ),
        Padding(
          padding: AppStyle.edgeInsetsA12,
          child: Text(
            "更多设置",
            style: Get.textTheme.titleSmall,
          ),
        ),
        SettingsCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SettingsAction(
                title: "关键词屏蔽",
                onTap: controller.showDanmuShield,
              ),
              AppStyle.divider,
              SettingsAction(
                title: "弹幕设置",
                onTap: controller.showDanmuSettingsSheet,
              ),
              AppStyle.divider,
              SettingsAction(
                title: "直播设置",
                onTap: controller.showLiveSettingsSheet,
              ),
              AppStyle.divider,
              SettingsAction(
                title: "定时关闭",
                onTap: controller.showAutoExitSheet,
              ),
              AppStyle.divider,
              SettingsAction(
                title: "画面尺寸",
                onTap: controller.showPlayerSettingsSheet,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget buildFollowList() {
    return KeepAliveWrapper(
      child: controller.buildFollowUserSelection(
        onClose: () {},
        scrollController: controller.liveRoomFollowScrollController,
      ),
    );
  }

  void showMore() {
    showModalBottomSheet(
      context: Get.context!,
      constraints: const BoxConstraints(
        maxWidth: 600,
      ),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => Utils.bottomSheetSafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: const Text("切换清晰度"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                controller.showQualitySheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.switch_video_outlined),
              title: const Text("切换线路"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                controller.showPlayUrlsSheet();
              },
            ),
            Visibility(
              visible: Platform.isAndroid,
              child: ListTile(
                leading: const Icon(Icons.picture_in_picture),
                title: const Text("小窗播放"),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Get.back();
                  controller.enablePIP();
                },
              ),
            ),
            Obx(
              () => SettingsSwitch(
                leading: const Icon(Icons.headphones_outlined),
                title: "后台播放",
                value: AppSettingsController
                    .instance.allowBackgroundPlayback.value,
                onChanged: (v) {
                  AppSettingsController.instance
                      .setAllowBackgroundPlayback(v);
                },
              ),
            ),
            ListTile(
              leading: const Icon(Icons.interests_outlined),
              title: const Text("同类推荐"),
              subtitle: Text(controller.currentRecommendationSubtitle),
              trailing: const Icon(Icons.chevron_right),
              enabled: controller.hasCategoryRecommendation,
              onTap: !controller.hasCategoryRecommendation
                  ? null
                  : () {
                      Get.back();
                      controller.openCategoryRecommendation();
                    },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text("复制链接"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                controller.copyUrl();
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text("APP中打开"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                controller.openNaviteAPP();
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text("播放信息"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                controller.showDebugInfo();
              },
            ),
          ],
        ),
      ),
    );
  }

  String parseDuration(int sec) {
    // 转为时分秒
    var h = sec ~/ 3600;
    var m = (sec % 3600) ~/ 60;
    var s = sec % 60;
    if (h > 0) {
      return "${h.toString().padLeft(2, '0')}小时${m.toString().padLeft(2, '0')}分钟${s.toString().padLeft(2, '0')}秒";
    }
    if (m > 0) {
      return "${m.toString().padLeft(2, '0')}分钟${s.toString().padLeft(2, '0')}秒";
    }
    return "${s.toString().padLeft(2, '0')}秒";
  }
}

class _InteractiveChatText extends StatelessWidget {
  static final RegExp _emojiTokenPattern = RegExp(r'\[[^\[\]]{1,16}\]');

  final String userName;
  final String? remark;
  final String message;
  final List<String>? imageUrls;
  final List<LiveMessageSpan>? spans;
  final TextStyle userStyle;
  final TextStyle messageStyle;
  final VoidCallback onUserTap;
  final VoidCallback onUserLongPress;

  const _InteractiveChatText({
    required this.userName,
    this.remark,
    required this.message,
    this.imageUrls,
    this.spans,
    required this.userStyle,
    required this.messageStyle,
    required this.onUserTap,
    required this.onUserLongPress,
  });

  TextSpan _buildTextSpan() {
    final richSpans = spans ?? const <LiveMessageSpan>[];
    return TextSpan(
      style: messageStyle,
      children: [
        TextSpan(
          text: '$userName：',
          style: userStyle,
        ),
        if ((remark ?? "").trim().isNotEmpty)
          TextSpan(
            text: '[${remark!.trim()}] ',
            style: userStyle.copyWith(
              color: userStyle.color?.withAlpha(180),
              fontSize: (userStyle.fontSize ?? 14) - 1,
            ),
          ),
        if (richSpans.isNotEmpty)
          for (final span in richSpans)
            if (span.isText)
              TextSpan(text: span.text)
            else if (span.isImage)
              _buildImageSpan(span.imageUrl!.trim()),
        if (richSpans.isEmpty) ...[
          ..._buildFallbackContentSpans(),
        ],
      ],
    );
  }

  List<InlineSpan> _buildFallbackContentSpans() {
    final urls = (imageUrls ?? const <String>[])
        .map((url) => url.trim())
        .where((url) => url.isNotEmpty)
        .toList();
    if (urls.isEmpty) {
      return [TextSpan(text: message)];
    }

    final result = <InlineSpan>[];
    var start = 0;
    var imageIndex = 0;
    for (final match in _emojiTokenPattern.allMatches(message)) {
      if (imageIndex >= urls.length) {
        break;
      }
      if (match.start > start) {
        result.add(TextSpan(text: message.substring(start, match.start)));
      }
      result.add(_buildImageSpan(urls[imageIndex]));
      imageIndex += 1;
      start = match.end;
    }
    if (start < message.length) {
      result.add(TextSpan(text: message.substring(start)));
    }
    for (; imageIndex < urls.length; imageIndex += 1) {
      result.add(_buildImageSpan(urls[imageIndex]));
    }
    return result;
  }

  WidgetSpan _buildImageSpan(String url) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: NetImage(
          url,
          width: (messageStyle.fontSize ?? 14) * 1.35,
          height: (messageStyle.fontSize ?? 14) * 1.35,
          fit: BoxFit.contain,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textSpan = _buildTextSpan();

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onUserTap,
      onLongPress: onUserLongPress,
      child: Text.rich(
        textSpan,
        softWrap: true,
        textWidthBasis: TextWidthBasis.parent,
      ),
    );
  }
}
