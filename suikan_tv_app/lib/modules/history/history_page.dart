import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/modules/history/history_controller.dart';
import 'package:simple_live_tv_app/routes/app_navigation.dart';
import 'package:simple_live_tv_app/services/follow_user_service.dart';
import 'package:simple_live_tv_app/widgets/app_scaffold.dart';
import 'package:simple_live_tv_app/widgets/button/highlight_button.dart';
import 'package:simple_live_tv_app/widgets/card/anchor_card.dart';
import 'package:simple_live_tv_app/widgets/tv_list_grid.dart';

class HistoryPage extends GetView<HistoryController> {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      child: Column(
        children: [
          AppStyle.vGap32,
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AppStyle.hGap48,
              HighlightButton(
                focusNode: AppFocusNode(),
                iconData: Icons.arrow_back,
                text: "返回",
                // 不加 autofocus：进页焦点默认落到列表首张卡（itemBuilder 首项 autofocus），
                // 遥控下键即可在记录间移动；返回用遥控返回键。
                onTap: () {
                  Get.back();
                },
              ),
              AppStyle.hGap32,
              Text(
                "观看记录",
                style: AppStyle.titleStyleWhite.copyWith(
                  fontSize: 36.w,
                  fontWeight: FontWeight.bold,
                ),
              ),
              AppStyle.hGap24,
              const Spacer(),
              HighlightButton(
                focusNode: AppFocusNode(),
                iconData: Icons.delete_outline_rounded,
                text: "清空",
                onTap: () {
                  controller.clean();
                },
              ),
              AppStyle.hGap48,
            ],
          ),
          AppStyle.vGap48,
          Expanded(
            // 等高山字网格(与关注列表同款行列距/等高), 不再用瀑布流 → 各行严格对齐
            child: Obx(() {
              // 与关注列表共用同一列数口径(每列 400.w): 盒子 density=320
              // → 物理 1920 只有 960 逻辑宽 → 4 列。
              final cols = tvListColumnCount(MediaQuery.sizeOf(context).width);
              return GridView.builder(
                padding: AppStyle.edgeInsetsH48,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  crossAxisSpacing: 28.w,
                  mainAxisSpacing: 24.w,
                  mainAxisExtent: 116.w,
                ),
                itemCount: controller.list.length,
                itemBuilder: (_, i) {
                  var item = controller.list[i];
                  final site = Sites.allSites[item.siteId] ??
                      FnOsService.instance.siteForServer(item.siteId);
                  if (site == null) {
                    return const SizedBox.shrink();
                  }
                  // 影视（fnOS 影视库）历史必须带 isVod=true 进播放页：
                  // 否则被当直播打开 → 无点播进度条/左右键调速，
                  // 也丢了"接着上次看"的进度续播（从头开始）。
                  return Obx(() {
                    // 直播中状态两个来源：
                    //  1) 该房间在本机关注列表 → 跟随 FollowUserService 轮询实时刷新；
                    //  2) 不在关注列表 → 进页面时探测一次（extraLiveStatus）。
                    var follow = FollowUserService.instance.allList
                        .where((f) => f.id == item.id)
                        .firstOrNull;
                    final live = follow?.liveStatus.value ??
                        controller.extraLiveStatus[item.id] ??
                        0;
                    return AnchorCard(
                      face: item.face,
                      name: item.userName,
                      siteId: item.siteId,
                      liveStatus: live,
                      roomId: item.roomId,
                      // 首项自动聚焦：进页焦点直接落在列表, 遥控可立即上下左右移动
                      autofocus: i == 0,
                      onTap: () => AppNavigator.toLiveRoomDetail(
                        site: site,
                        roomId: item.roomId,
                        isVod: FnOsService.instance
                                .serverForSiteId(item.siteId) !=
                            null,
                      ),
                    );
                  });
                },
              );
            }),
          ),
        ],
      ),
    );
  }
}
