import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/mine/history/history_controller.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/live_status_badge.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/page_grid_view.dart';

class HistoryPage extends GetView<HistoryController> {
  const HistoryPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("观看记录"),
        actions: [
          TextButton.icon(
            onPressed: controller.clean,
            icon: const Icon(Icons.delete_outline),
            label: const Text("清空"),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // 多列展示（与关注/首页列表一致）：每行卡最小宽约 300，
          // 手机 1 列、WIN/平板自动多列，宽屏更紧凑。
          final cols =
              (constraints.maxWidth / 300).floor().clamp(1, 8).toInt();
          return PageGridView(
            padding: AppStyle.pagePadding(),
            crossAxisCount: cols,
            crossAxisSpacing: 12,
            mainAxisSpacing: 10,
            mainAxisExtent: 68,
            pageController: controller,
            firstRefresh: true,
            itemBuilder: (_, i) {
              var item = controller.list[i];
              var site = Sites.allSites[item.siteId] ??
                  FnOsService.instance.siteForServer(item.siteId);
              if (site == null) {
                return const SizedBox.shrink();
              }
              return Obx(() {
                // 直播中状态两个来源：
                //  1) 该房间在本机关注列表 → 跟随关注列表后台轮询实时刷新；
                //  2) 不在关注列表 → 进页面时探测一次（extraLiveStatus）。
                var follow = FollowService.instance.followList
                    .where((f) => f.id == item.id)
                    .firstOrNull;
                final extra = controller.extraLiveStatus[item.id];
                final live = follow?.liveStatus.value ?? extra ?? 0;
                return _HistoryCard(
                  item: item,
                  site: site,
                  isLive: live == 2,
                  onTap: () {
                    final onRoomSelected = controller.onRoomSelected;
                    if (onRoomSelected != null) {
                      Get.back();
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        onRoomSelected(site, item.roomId);
                      });
                      return;
                    }
                    AppNavigator.toLiveRoomDetail(
                      site: site,
                      roomId: item.roomId,
                      isVod: FnOsService.instance
                              .serverForSiteId(item.siteId) !=
                          null,
                    );
                  },
                  onLongPress: () async {
                    var result = await Utils.showAlertDialog(
                      "确定要删除此记录吗?",
                      title: "删除记录",
                    );
                    if (result) {
                      controller.removeItem(item);
                    }
                  },
                );
              });
            },
          );
        },
      ),
    );
  }
}

/// 观看记录卡片（与关注列表同款横向紧凑卡）：
/// 小边框描边 + 头像 + 昵称 + 站点/时间。
/// 直播状态红标由外层按「关注轮询 / 进页探测」结果计算后经 [isLive] 传入：
/// 关注过的房间实时刷新；没关注的房间进页面时探测一次。
class _HistoryCard extends StatelessWidget {
  final History item;
  final Site site;
  final bool isLive;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _HistoryCard({
    required this.item,
    required this.site,
    required this.isLive,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(12);
    final subtitleStyle = theme.textTheme.bodySmall?.copyWith(
      color: Colors.grey.shade600,
    );
    // 与关注列表同款小边框：低透明度 outlineVariant 细描边。
    final idleBorderAlpha =
        (16 + (theme.brightness == Brightness.dark ? 72 : 48))
            .clamp(0, 255)
            .toInt();
    return Material(
      color: theme.cardColor,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withAlpha(idleBorderAlpha),
              width: 0.6,
            ),
            borderRadius: radius,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              NetImage(
                item.face,
                width: 48,
                height: 48,
                borderRadius: 24,
              ),
              AppStyle.hGap12,
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.userName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Image.asset(
                          site.logo,
                          width: 16,
                          height: 16,
                        ),
                        AppStyle.hGap4,
                        Flexible(
                          child: Text(
                            site.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: subtitleStyle,
                          ),
                        ),
                        if (isLive) ...[
                          const SizedBox(width: 6),
                          const LiveStatusBadge(status: 2),
                        ],
                        const Spacer(),
                        Text(
                          Utils.parseTime(item.updateTime),
                          style: subtitleStyle,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
