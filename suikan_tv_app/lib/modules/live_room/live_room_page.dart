import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/widgets/tv_focus_style.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/fnos/fn_os_models.dart';
import 'package:simple_live_tv_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_tv_app/modules/live_room/player/player_controls.dart';
import 'package:simple_live_tv_app/widgets/focus_card.dart';

class LiveRoomPage extends GetView<LiveRoomController> {
  const LiveRoomPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          requestExitPlayer();
        }
      },
      child: Focus(
        focusNode: controller.focusNode,
        autofocus: true,
        onKeyEvent: onKeyEvent,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Obx(
            () => buildMediaPlayer(),
          ),
        ),
      ),
    );
  }

  /// 返回 KeyEventResult.handled 表示已消费该键, 阻止 Flutter 默认行为与
  /// 原生 backChannel 再次触发, 解决"按一下返回顶两下"的问题。
  KeyEventResult onKeyEvent(FocusNode node, KeyEvent key) {
    if (key is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    Log.logPrint(key);

    if (key.logicalKey == LogicalKeyboardKey.escape ||
        key.logicalKey == LogicalKeyboardKey.backspace ||
        key.logicalKey == LogicalKeyboardKey.goBack ||
        key.logicalKey == LogicalKeyboardKey.browserBack) {
      // 直播间内弹出菜单(设置/关注用户等 Get.dialog)打开时, 返回键先关闭菜单
      if (Get.isDialogOpen == true || Get.isBottomSheetOpen == true) {
        Get.back();
        return KeyEventResult.handled;
      }
      requestExitPlayer();
      return KeyEventResult.handled;
    }
    // 点击OK、Enter、Select键
    if (key.logicalKey == LogicalKeyboardKey.select ||
        key.logicalKey == LogicalKeyboardKey.enter ||
        key.logicalKey == LogicalKeyboardKey.space) {
      // 点播（影视库/投屏影视）：确认键按主流 TV 播放器做成**两级**——
      //   控制条没出来 → 呼出控制条（看进度）；
      //   控制条已出来 → 播放/暂停。
      // 直播保持原样（只切换控制条）：直播暂停后画面停在旧帧、恢复还要重新
      // 追帧，误触代价太大，且用户没要求。
      if (controller.isVod && controller.showControlsState.value) {
        unawaited(controller.togglePlayPause());
        controller.resetHideControlsTimer();
        return KeyEventResult.handled;
      }
      if (!controller.showControlsState.value) {
        controller.showControls();
      } else {
        controller.hideControls();
      }
      return KeyEventResult.handled;
    }

    if (controller.handleKeyboardShortcut(key.logicalKey)) {
      return KeyEventResult.handled;
    }

    // 点播（影视库/投屏影视）遥控器键位，按主流 TV 播放器规范：
    //   左右  快退/快进（按**按住时长**分级：10 → 30 → 60 → 120 秒）
    //   上下  音量 ±5
    //   确认  播放/暂停（见上）
    //   菜单  设置
    //
    // 这里**不要求控制条已呼出**。旧实现要求 showControlsState 为 true 才接管，
    // 结果用户投屏完按左右键 → 控制条是隐藏的 → 左键开了关注列表、右键开了设置，
    // 快进快退一次都没触发，功能等于不存在。
    // 点播场景下"关注列表/切频道"优先级远低于拖进度，且投屏内容根本没有这些概念；
    // 设置仍可用菜单键打开。直播行为完全不变（左右仍是设置/关注，上下仍是切频道）。
    if (controller.isVod) {
      if (key.logicalKey == LogicalKeyboardKey.arrowLeft) {
        controller.seekRelative(-10);
        controller.showControls(); // 保持控制条显示，便于连续调整
        return KeyEventResult.handled;
      }
      if (key.logicalKey == LogicalKeyboardKey.arrowRight) {
        controller.seekRelative(10);
        controller.showControls();
        return KeyEventResult.handled;
      }
      // 上下键：点播没有"上一个/下一个频道"的概念（影视库选集在详情页完成），
      // 按主流播放器做成音量调节，别让两个键空着。直播仍走频道切换。
      if (key.logicalKey == LogicalKeyboardKey.arrowUp) {
        unawaited(controller.adjustVolume(5).then((v) {
          SmartDialog.showToast("音量 $v%");
        }));
        controller.showControls();
        return KeyEventResult.handled;
      }
      if (key.logicalKey == LogicalKeyboardKey.arrowDown) {
        // 点播影视剧：遥控器「下键」= 选集（季/集）；否则是音量 -
        if (controller.canPickEpisode) {
          _openEpisodePicker(controller);
          return KeyEventResult.handled;
        }
        unawaited(controller.adjustVolume(-5).then((v) {
          SmartDialog.showToast("音量 $v%");
        }));
        controller.showControls();
        return KeyEventResult.handled;
      }
    }

    // 点击Menu打开/关闭设置
    if (key.logicalKey == LogicalKeyboardKey.contextMenu ||
        key.logicalKey == LogicalKeyboardKey.arrowRight) {
      showPlayerSettings(controller);
      return KeyEventResult.handled;
    }

    // 点击左键显示关注用户
    if (key.logicalKey == LogicalKeyboardKey.arrowLeft) {
      showFollowUser(controller);
      return KeyEventResult.handled;
    }

    // // 点击右键关注/取消关注
    // if (key.logicalKey == LogicalKeyboardKey.arrowRight) {
    //   if (controller.followed.value) {
    //     controller.removeFollowUser();
    //   } else {
    //     controller.followUser();
    //   }

    //   return;
    // }

    // 点击上键切换上一个直播
    if (key.logicalKey == LogicalKeyboardKey.arrowUp) {
      controller.prevChannel();
      return KeyEventResult.handled;
    }

    // 点击下键切换下一个直播
    if (key.logicalKey == LogicalKeyboardKey.arrowDown) {
      controller.nextChannel();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void requestExitPlayer() {
    // 直播间内弹出菜单(设置/关注用户等 Get.dialog)打开时, 返回键先关闭菜单, 不触发退出
    if (Get.isDialogOpen == true || Get.isBottomSheetOpen == true) {
      Get.back();
      return;
    }
    // 双击返回键退出：第一次只提示，第二次才退出。
    if (controller.doubleClickExit) {
      controller.doubleClickTimer?.cancel();
      controller.doubleClickTimer = null;
      controller.doubleClickExit = false;
      SmartDialog.dismiss();
      Get.back();
      return;
    }
    controller.doubleClickExit = true;
    SmartDialog.dismiss();
    SmartDialog.showToast("再按一次退出播放器");
    controller.doubleClickTimer?.cancel();
    controller.doubleClickTimer = Timer(const Duration(seconds: 2), () {
      controller.doubleClickExit = false;
      controller.doubleClickTimer = null;
    });
  }

  Widget buildMediaPlayer() {
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
    return Stack(
      children: [
        Video(
          key: controller.globalPlayerKey,
          controller: controller.videoController,
          pauseUponEnteringBackgroundMode:
              AppSettingsController.instance.playerAutoPause.value,
          resumeUponEnteringForegroundMode:
              AppSettingsController.instance.playerAutoPause.value,
          controls: (state) {
            return playerControls(state, controller);
          },
          aspectRatio: aspectRatio,
          fit: boxFit,
        ),
        Obx(
          () => Visibility(
            visible:
                !controller.liveStatus.value && !controller.pageLoadding.value,
            child: Center(
              child: Text(
                "未开播",
                style: AppStyle.textStyleWhite,
              ),
            ),
          ),
        ),
        if (controller.playbackLoadError.value.isNotEmpty)
          Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 520),
              padding: AppStyle.edgeInsetsA24,
              color: Colors.black87,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    controller.playbackLoadError.value,
                    textAlign: TextAlign.center,
                    style: AppStyle.textStyleWhite,
                  ),
                  AppStyle.vGap16,
                  ElevatedButton.icon(
                    autofocus: true,
                    onPressed: controller.refreshRoom,
                    icon: const Icon(Icons.refresh),
                    label: const Text("重试"),
                  ),
                ],
              ),
            ),
          ),
        Obx(
          () => Visibility(
            visible: controller.autoExitEnable.value,
            child: Positioned(
              right: 24,
              top: 24,
              child: Text(
                "${parseDuration(controller.countdown.value)}后自动关闭",
                style: AppStyle.textStyleWhite,
              ),
            ),
          ),
        ),
      ],
    );
  }

  String parseDuration(int duration) {
    int hours = duration ~/ 3600;
    int minutes = duration % 3600 ~/ 60;
    int seconds = duration % 60;

    return "${hours.toString().padLeft(2, '0')}:"
        "${minutes.toString().padLeft(2, '0')}:"
        "${seconds.toString().padLeft(2, '0')}";
  }
}

/// 打开影视选集面板（若已在对话框则不重复弹）。
void _openEpisodePicker(LiveRoomController controller) {
  if (Get.isDialogOpen == true) return;
  unawaited(controller.openEpisodePicker());
  Get.dialog(
    TvEpisodePickerDialog(controller: controller),
    // 遮罩完全透明：选集面板只是"贴底的浮层"，上面画面不被压暗。
    barrierColor: Colors.transparent,
    barrierDismissible: true,
  );
}

/// 影视选集面板（遥控器操作）：底部弹出，顶行切季、下方网格选集。
/// 由播放页「下键」打开（点播影视剧时），当前集高亮，左右/上下/确认导航。
class TvEpisodePickerDialog extends StatefulWidget {
  final LiveRoomController controller;
  const TvEpisodePickerDialog({Key? key, required this.controller})
      : super(key: key);

  @override
  State<TvEpisodePickerDialog> createState() => _TvEpisodePickerDialogState();
}

class _TvEpisodePickerDialogState extends State<TvEpisodePickerDialog> {
  LiveRoomController get controller => widget.controller;

  /// 季 chip（强焦点视觉：放大 + 高亮描边）。
  Widget _buildSeasonChip(BuildContext context, FnOsSeason season, int i) {
    final selected = controller.currentSeasonIndex.value == i;
    return FocusCard(
      // 初始焦点在集网格的「当前集」；想切季时按「上」到季行 —— 聚焦态
      // （放大+描边）清晰可见即可，不设 autofocus，避免和当前集抢焦点。
      focusScale: TvFocusStyle.scaleChip,
      onActivate: () => controller.selectSeason(i),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Colors.white12,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          season.title.isEmpty ? '第 ${season.seasonNumber} 季' : season.title,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white,
            fontSize: 13,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 底部紧凑面板（不全屏居中遮挡画面）：
    // 高度约屏高 55%、贴底、宽度自适应，画面中上部仍可见正在播放的内容。
    // 参考主流 TV 播放器（Emby/Kodi/B站TV）：选集是「底部小抽屉」，
    // 只占屏高约 1/5（≤5 行小方块），画面大部分保持可见。
    final screenH = MediaQuery.of(context).size.height;
    // 尽量矮：约屏高 1/6，够「季行 + 2 行小方块集」即可，最大程度不挡画面。
    final panelH = (screenH / 6).clamp(210.0, 290.0);
    return Material(
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          height: panelH,
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(28, 0, 28, 28),
          decoration: BoxDecoration(
            color: const Color(0xF0111111),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white24),
          ),
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 季选择行（遥控器左右切，紧凑）。
              // 用与集网格一致的强焦点视觉（放大 + 高亮描边），避免普通
              // ChoiceChip 聚焦态过弱、切季时看不清焦点落在哪个季上。
              Obx(() {
                final seasons = controller.episodeSeasons;
                if (seasons.isEmpty) {
                  return const SizedBox.shrink();
                }
                // ⚠️ 不能用横向 ListView（懒加载）：滚出视口的季 chip 会被销毁，
                // 遥控焦点左右移动时找不到已销毁的项 → 「切到第二季后回不到
                // 其它季」。季数量少，改成 SingleChildScrollView+Row **全构建**，
                // 所有季常驻可聚焦；季多超出宽度时靠 FocusCard 的 ensureVisible
                // 自动滚入视口。
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  // 季 chip 聚焦会放大 1.1，默认 hardEdge 会裁掉溢出的高亮
                  // 边缘 → 关闭裁剪，放大后的焦点态完整可见。
                  clipBehavior: Clip.none,
                  child: Row(
                    children: [
                      for (var i = 0; i < seasons.length; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        _buildSeasonChip(context, seasons[i], i),
                      ],
                    ],
                  ),
                );
              }),
              const SizedBox(height: 8),
              // 集列表
              Expanded(
                child: Obx(() {
                  if (controller.episodePickerLoading.value) {
                    return const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    );
                  }
                  final err = controller.episodePickerError.value;
                  if (err.isNotEmpty &&
                      controller.episodeSeasons.isEmpty) {
                    return Center(
                      child: Text(err,
                          style: const TextStyle(color: Colors.white)),
                    );
                  }
                  final seasons = controller.episodeSeasons;
                  if (seasons.isEmpty) {
                    return const Center(
                      child: Text('暂无剧集',
                          style: TextStyle(color: Colors.white)),
                    );
                  }
                  final idx = controller.currentSeasonIndex.value;
                  if (idx >= seasons.length) {
                    return const SizedBox.shrink();
                  }
                  final eps = seasons[idx].episodes;
                  if (eps.isEmpty) {
                    return const Center(
                      child: Text('该季暂无剧集',
                          style: TextStyle(color: Colors.white)),
                    );
                  }
                  final currentEp = controller.roomId;
                  // 自适应列数：抽屉很矮，集号用「小横条」格子（高约 46、一行
                  // 多放几个），横向一次容纳更多集，垂直只占 2 行上下。
                  return LayoutBuilder(builder: (context, c) {
                    const double cell = 92;
                    final cols = (c.maxWidth / cell).floor().clamp(6, 22);
                    return GridView.builder(
                      // 遥控焦点连续导航的关键：cacheExtent 放大后，向下翻集
                      // 时下一屏仍是已构建，焦点不会因懒加载找不到项而卡住。
                      cacheExtent: 1200,
                      gridDelegate:
                          SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        // 宽:高≈2:1 的小横条，高度小、占屏少。
                        childAspectRatio: 2.0,
                      ),
                      itemCount: eps.length,
                    itemBuilder: (_, i) {
                      final ep = eps[i];
                      final isCurrent = ep.guid == currentEp;
                      return FocusCard(
                        autofocus: isCurrent,
                        onActivate: () => controller.playEpisode(ep),
                        child: Container(
                          decoration: BoxDecoration(
                            color: isCurrent
                                ? Theme.of(context).colorScheme.primary
                                : Colors.white10,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            ep.episodeNumber > 0
                                ? '第 ${ep.episodeNumber} 集'
                                : (ep.title.isEmpty ? ep.guid : ep.title),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isCurrent ? Colors.black : Colors.white,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      );
                    },
                  );
                    });
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
