import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/search/global_search_controller.dart';
import 'package:simple_live_app/modules/search/local_content_search_controller.dart';
import 'package:simple_live_app/modules/settings/fnos/fn_os_detail_page.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/widgets/live_room_card.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 方案 B：全局搜索结果视图（分组渐进展示）
class GlobalSearchView extends StatelessWidget {
  const GlobalSearchView({Key? key}) : super(key: key);

  GlobalSearchController get controller =>
      Get.find<GlobalSearchController>();

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final sections = controller.sections;
      if (sections.isEmpty) {
        return const _EmptyHint();
      }
      return ListView.builder(
        controller: controller.scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: AppStyle.edgeInsetsA12,
        itemCount: sections.length + 1,
        itemBuilder: (context, i) {
          if (i >= sections.length) {
            // 底部「加载更多」触发（聚合分页）;所有平台都拉空后自动隐藏
            return SizedBox(
              height: 56,
              child: Center(
                child: controller.searching.value
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : controller.hasMore.value
                        ? TextButton(
                            onPressed: controller.loadMore,
                            child: const Text('加载更多'),
                          )
                        : const SizedBox.shrink(),
              ),
            );
          }
          final section = sections[i];
          return _SectionView(section: section, index: i);
        },
      );
    });
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        '搜索所有平台与本地内容\n输入关键词试试',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.grey),
      ),
    );
  }
}

class _SectionView extends StatelessWidget {
  final GlobalSearchSection section;
  final int index;
  const _SectionView({required this.section, required this.index});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // 头部：平台名 + 状态
      final status = section.status.value;
      final titleRow = Row(
        children: [
          Text(
            section.title,
            style: Get.textTheme.titleSmall,
          ),
          const Spacer(),
          if (status == 0)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (status == 2)
            Text(
              section.errorMsg.value,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            )
          else
            Text(
              '${section.items.length} 个结果',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
        ],
      );

      // 本地内容：列表卡片；平台：网格卡片
      Widget body;
      if (section.site == null) {
        body = _buildLocalList();
      } else {
        body = _buildSiteGrid(section.site!);
      }

      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            titleRow,
            AppStyle.vGap8,
            body,
            const Divider(height: 24),
          ],
        ),
      );
    });
  }

  /// 本地内容（自定义源频道 + 影视库）网格卡片，与平台结果样式一致
  Widget _buildLocalList() {
    if (section.items.isEmpty && section.status.value == 1) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text('无匹配内容', style: TextStyle(color: Colors.grey)),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = _resolveGrid(constraints.maxWidth);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: layout,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            mainAxisExtent: 200,
          ),
          itemCount: section.items.length,
          itemBuilder: (_, i) {
            final r = section.items[i] as LocalSearchResult;
            return _LocalResultCard(result: r, onTap: () => _openLocal(r));
          },
        );
      },
    );
  }

  void _openLocal(LocalSearchResult r) {
    switch (r.kind) {
      case LocalSearchResult.kChannel:
        final p = r.payload as ChannelSearchPayload;
        AppNavigator.toLiveRoomDetail(
          site: p.site as Site,
          roomId: p.url,
        );
        break;
      case LocalSearchResult.kMovie:
        final p = r.payload as MovieSearchPayload;
        Get.to(() => FnOsDetailPage(movie: p.movie, server: p.server));
        break;
      case LocalSearchResult.kSeries:
        final p = r.payload as SeriesSearchPayload;
        Get.to(() => FnOsDetailPage(series: p.series, server: p.server));
        break;
    }
  }

  /// 平台房间网格
  Widget _buildSiteGrid(Site site) {
    if (section.items.isEmpty && section.status.value == 1) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text('无结果', style: TextStyle(color: Colors.grey)),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = _resolveGrid(constraints.maxWidth);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: layout,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            mainAxisExtent: 200,
          ),
          itemCount: section.items.length,
          itemBuilder: (_, i) {
            final item = section.items[i];
            if (item is LiveRoomItem) {
              return LiveRoomCard(site, item);
            }
            if (item is LiveAnchorItem) {
              return _AnchorCard(site: site, item: item);
            }
            return const SizedBox.shrink();
          },
        );
      },
    );
  }

  int _resolveGrid(double width) {
    if (width >= 900) return 5;
    if (width >= 700) return 4;
    if (width >= 500) return 3;
    if (width >= 320) return 2;
    return 1;
  }
}

/// 本地内容结果卡片（自定义源频道/影视库），封面+标题+副标题，与平台卡片同风格。
class _LocalResultCard extends StatelessWidget {
  final LocalSearchResult result;
  final VoidCallback onTap;
  const _LocalResultCard({required this.result, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cover = result.cover;
    final isChannel = result.kind == LocalSearchResult.kChannel;
    return InkWell(
      onTap: onTap,
      borderRadius: AppStyle.radius8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: AppStyle.radius8,
              child: SizedBox(
                width: double.infinity,
                child: cover == null
                    ? Container(
                        color: Colors.black26,
                        child: const Icon(
                          Icons.play_circle_outline,
                          color: Colors.white54,
                          size: 40,
                        ),
                      )
                    : isChannel
                        // 直播源频道：cover 是台标 logo，等比完整显示（不裁剪）
                        ? Container(
                            color: Colors.black26,
                            alignment: Alignment.center,
                            child: NetImage(
                              cover,
                              fit: BoxFit.contain,
                              httpHeaders: result.httpHeaders,
                            ),
                          )
                        // 影视海报：封面铺满裁剪
                        : NetImage(
                            cover,
                            fit: BoxFit.cover,
                            httpHeaders: result.httpHeaders,
                          ),
              ),
            ),
          ),
          AppStyle.vGap4,
          Text(
            result.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          Text(
            result.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

/// 主播搜索结果卡片（搜索结果中主播按头像+名字展示）
class _AnchorCard extends StatelessWidget {
  final Site site;
  final LiveAnchorItem item;
  const _AnchorCard({required this.site, required this.item});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        AppNavigator.toLiveRoomDetail(
          site: site,
          roomId: item.roomId,
        );
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ClipOval(
            child: NetImage(
              item.avatar,
              width: 72,
              height: 72,
            ),
          ),
          AppStyle.vGap8,
          Text(
            item.userName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }
}
