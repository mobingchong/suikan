import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
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
                //autofocus: true, // 焦点默认给内容区, 与热门直播保持一致
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
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 观看记录卡(头像行卡)紧凑化后按宽度自适应列数：
                // 1920 屏排 4 列(每列约 440 宽), 窄屏自动减列。
                final cols = (constraints.maxWidth / 440).floor().clamp(2, 6);
                return Obx(
                  () => MasonryGridView.count(
                    padding: AppStyle.edgeInsetsH48,
                    itemCount: controller.list.length,
                    crossAxisCount: cols,
                    crossAxisSpacing: 40.w,
                    mainAxisSpacing: 32.w,
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
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
