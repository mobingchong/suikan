import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/widgets/net_image.dart';

/// 点播（影视）播放页的「信息」tab：
/// 影片信息（封面/标题/评分/年份/时长/简介）+ 播放进度（续播卡片）。
class VodInfoPanel extends StatelessWidget {
  final LiveRoomController controller;
  const VodInfoPanel({super.key, required this.controller});

  String _itemField(Map<String, dynamic> detail, String key) {
    final item = detail['item'];
    if (item is Map) {
      final v = item[key];
      if (v != null) return v.toString();
    }
    final v = detail[key];
    return v?.toString() ?? '';
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      final detail = controller.vodDetailJson.value;
      final title = controller.vodTitle.value;
      final poster = controller.vodPoster.value;
      final hasFnOs = detail.isNotEmpty;
      final server = controller.fnOsServer;

      final rating = _itemField(detail, 'vote_average');
      final year = _itemField(detail, 'year');
      final type = _itemField(detail, 'type');
      final overview = _itemField(detail, 'overview');
      final durationSec = int.tryParse(_itemField(detail, 'duration')) ?? 0;

      // 进度数值放卡片内用 StreamBuilder 订阅 player.stream.position 实时取:
      // player.state 是 Flutter ChangeNotifier,GetX 的 Obx 不监听它,
      // 直接在 Obx 里读 state.position 只会得到面板 build 时刻的旧值,
      // 拖动进度条后这里显示的进度不会跟着变。
      return ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          // ── 头部：海报 + 标题/元数据 ────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (poster.isNotEmpty && server != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: NetImage(
                    FnOsService.instance.posterUrl(server, poster),
                    width: 96,
                    height: 134,
                    fit: BoxFit.cover,
                    httpHeaders: FnOsService.instance.imageHeaders(server),
                  ),
                )
              else if (!hasFnOs)
                // 自定义直播源：台标（横向小方块，与频道列表一致）；
                // 无台标显示频道列表同款默认图（live_tv 图标）
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 96,
                    height: 54,
                    child: ColoredBox(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child:
                          (controller.detail.value?.userAvatar ?? '').isNotEmpty
                              ? SizedBox.expand(
                                  child: NetImage(
                                    controller.detail.value!.userAvatar,
                                    fit: BoxFit.contain,
                                  ),
                                )
                              : Icon(
                                  Icons.live_tv,
                                  size: 24,
                                  color: theme.colorScheme.primary
                                      .withAlpha(120),
                                ),
                    ),
                  ),
                )
              else
                Container(
                  width: 96,
                  height: 134,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.movie_outlined, size: 40),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      // 飞牛用影片标题；自定义直播源用频道名（台标右侧），地址兜底
                      title.isNotEmpty
                          ? title
                          : ((controller.detail.value?.userName ?? '')
                                  .isNotEmpty
                              ? controller.detail.value!.userName
                              : controller.roomId),
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    AppStyle.vGap8,
                    if (type.isNotEmpty || year.isNotEmpty || durationSec > 0)
                      Text(
                        [
                          if (type.isNotEmpty) type,
                          if (year.isNotEmpty) year,
                          if (durationSec > 0)
                            '${durationSec ~/ 60}分钟',
                        ].join(' · '),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.hintColor),
                      ),
                    if (rating.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          children: [
                            const Icon(Icons.star_rounded,
                                size: 16, color: Colors.amber),
                            const SizedBox(width: 4),
                            Text(
                              rating,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),

          AppStyle.vGap12,

          // ── 进度卡片：当前播放进度（实时） ────────
          StreamBuilder<Duration>(
            stream: controller.player.stream.position,
            builder: (_, posSnap) {
              // duration/position 流无缓存(broadcast),控件重建后新订阅
              // 可能收不到已发事件 → 用 state 当前值兜底(与全屏进度条同修)。
              final position = posSnap.data ?? controller.player.state.position;
              final total = controller.player.state.duration;
              final progress = (total.inMilliseconds > 0)
                  ? (position.inMilliseconds / total.inMilliseconds)
                      .clamp(0.0, 1.0)
                  : 0.0;
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: .5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.play_circle_outline, size: 18),
                        const SizedBox(width: 6),
                        Text(
                          '播放进度',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        Text(
                          '${_fmt(position)} / ${_fmt(total)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                    AppStyle.vGap8,
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress.toDouble(),
                        minHeight: 6,
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          // ── 简介 ──────────────────────────────────
          if (overview.isNotEmpty) ...[
            AppStyle.vGap12,
            Text(
              '简介',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            AppStyle.vGap8,
            Text(
              overview,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
            ),
          ],

          // ── 自定义源降级信息（无飞牛数据时）─────────────
          if (!hasFnOs) ...[
            AppStyle.vGap12,
            Text(
              '来源信息',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            AppStyle.vGap8,
            Text(
              '站点：${controller.site.name}\n房间：${controller.roomId}',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
            ),
          ],
          const SizedBox(height: 24),
        ],
      );
    });
  }
}
