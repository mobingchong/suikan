import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/app/custom_source/custom_source_service.dart';
import 'package:simple_live_tv_app/app/custom_source/m3u_models.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/routes/app_navigation.dart';
import 'package:simple_live_tv_app/services/local_storage_service.dart';
import 'package:simple_live_tv_app/widgets/focus_card.dart';
import 'package:simple_live_tv_app/widgets/live_room_grid_layout.dart';
import 'package:simple_live_tv_app/widgets/net_image.dart';
import 'package:simple_live_tv_app/widgets/shadow_card.dart';

/// 跨源聚合的一条线路：记录所属源，用于进直播间时定位对应站点。
class AggregatedChannelLine {
  final M3uChannel channel;
  final M3uSource source;
  const AggregatedChannelLine({required this.channel, required this.source});
}

/// 跨源聚合的频道：所有直播源中同名频道合并成多线路。
class AggregatedChannel {
  final String name;
  final List<AggregatedChannelLine> lines;

  AggregatedChannel({required this.name, required this.lines});

  bool get multiLine => lines.length > 1;
  String get displayName => name.trim().isEmpty ? lines.first.channel.url : name.trim();

  /// 取第一条非空 logo，否则 null。
  String? get logo {
    for (final l in lines) {
      final v = l.channel.logo;
      if (v != null && v.trim().isNotEmpty) return v;
    }
    return null;
  }
}

/// 电视直播汇总页：列出所有直播源的频道，同名自动合并为多线路，按源文件名排序。
class LiveChannelsController extends GetxController {
  /// 数据版本号：直播源增删/刷新后 +1，驱动 Obx 重建（原地刷新不跳转）。
  final version = 0.obs;

  static const String _kLastLinePrefix = 'LiveChannelsLastLine_';

  /// 频道合并 key：频道名 trim 后为空则用 url 兜底。
  static String _keyFor(M3uChannel c) =>
      c.name.trim().isEmpty ? c.url : c.name.trim();

  /// 聚合所有直播源的频道。排序：先按源文件名（A-Z，忽略大小写）排源，
  /// 再按源顺序遍历频道，同名频道合并、保留首次出现的位置。
  List<AggregatedChannel> get aggregatedChannels {
    final sources = [...CustomSourceService.instance.sources]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final map = <String, List<AggregatedChannelLine>>{};
    final order = <String>[];
    for (final src in sources) {
      for (final c in src.channels) {
        final key = _keyFor(c);
        map.putIfAbsent(key, () => []).add(AggregatedChannelLine(channel: c, source: src));
        if (!order.contains(key)) {
          order.add(key);
        }
      }
    }
    return order
        .map((k) => AggregatedChannel(name: k, lines: map[k]!))
        .toList();
  }

  /// 刷新所有直播源（逐个重新拉取并合并频道），完成后通知一次。
  Future<void> refreshAll() async {
    SmartDialog.showLoading(msg: '正在刷新直播源…');
    try {
      for (final s
          in List<M3uSource>.from(CustomSourceService.instance.sources)) {
        await CustomSourceService.instance.refreshSource(s.id, notify: false);
      }
      EventBus.instance.emit(EventBus.kCustomSourcesChanged, null);
      version.value++;
      SmartDialog.dismiss();
      SmartDialog.showToast('已刷新');
    } catch (e) {
      SmartDialog.dismiss();
      SmartDialog.showToast('刷新失败：$e');
    }
  }

  /// 点击频道：多线路时沿用上次线路（无记录则第一条），单线路直接第一条。
  void openChannel(AggregatedChannel ch) {
    final line = _pickLine(ch);
    _play(line);
  }

  /// 长按频道：手动选线路，选完记录为「上次线路」。
  void showLinePicker(AggregatedChannel ch) {
    showModalBottomSheet(
      context: Get.context!,
      builder: (context) {
        final lastUrl = getLastLineUrl(ch);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '${ch.displayName}（${ch.lines.length} 条线路）',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Divider(height: 1),
              ...ch.lines.asMap().entries.map((e) {
                final i = e.key;
                final line = e.value;
                final lineName = line.channel.name.trim() == ch.name.trim() ||
                        line.channel.name.isEmpty
                    ? '线路 ${i + 1}'
                    : line.channel.name;
                final isLast = lastUrl == line.channel.url;
                return ListTile(
                  leading: Icon(
                    isLast ? Icons.history : Icons.play_circle_outline,
                    color: Get.theme.colorScheme.primary,
                  ),
                  title: Text(lineName),
                  subtitle: Text(
                    line.channel.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: isLast
                      ? Icon(Icons.check, color: Get.theme.colorScheme.primary)
                      : null,
                  onTap: () {
                    Get.back();
                    _play(line);
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  AggregatedChannelLine _pickLine(AggregatedChannel ch) {
    if (ch.multiLine) {
      final last = getLastLineUrl(ch);
      if (last != null) {
        return ch.lines.firstWhere(
          (l) => l.channel.url == last,
          orElse: () => ch.lines.first,
        );
      }
    }
    return ch.lines.first;
  }

  void _play(AggregatedChannelLine line) {
    _recordLastLine(line);
    final site = CustomSourceService.instance.siteForSource(line.source.id);
    if (site == null) return;
    AppNavigator.toLiveRoomDetail(site: site, roomId: line.channel.url);
  }

  String? getLastLineUrl(AggregatedChannel ch) {
    final saved =
        LocalStorageService.instance.getValue<String?>(_lastLineKey(ch.name), null);
    if (saved == null) return null;
    final match = ch.lines.firstWhereOrNull((l) => l.channel.url == saved);
    return match?.channel.url;
  }

  void _recordLastLine(AggregatedChannelLine line) {
    LocalStorageService.instance
        .setValue(_lastLineKey(_keyFor(line.channel)), line.channel.url);
  }

  String _lastLineKey(String key) => '$_kLastLinePrefix$key';
}

class LiveChannelsPage extends StatelessWidget {
  const LiveChannelsPage({Key? key}) : super(key: key);

  static const double _detailsExtent = 56;

  LiveChannelsController get controller =>
      Get.isRegistered<LiveChannelsController>()
          ? Get.find<LiveChannelsController>()
          : Get.put(LiveChannelsController());

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('电视直播'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新直播源',
            onPressed: () => c.refreshAll(),
          ),
        ],
      ),
      body: Obx(() {
        c.version.value;
        final list = c.aggregatedChannels;
        if (list.isEmpty) {
          return Center(
            child: Text(
              '还没有直播源\n请在「设置 - 自定义直播源」添加 M3U 直播源',
              textAlign: TextAlign.center,
              style: AppStyle.textStyleWhite,
            ),
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final layout = LiveRoomGridLayout.resolve(
              constraints.maxWidth,
              detailsExtent: _detailsExtent,
            );
            return GridView.builder(
              padding: AppStyle.edgeInsetsA12,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: layout.crossAxisCount,
                mainAxisSpacing: LiveRoomGridLayout.defaultSpacing,
                crossAxisSpacing: LiveRoomGridLayout.defaultSpacing,
                mainAxisExtent: layout.mainAxisExtent,
              ),
              itemCount: list.length,
              itemBuilder: (_, i) {
                final ch = list[i];
                return FocusCard(
                  // 进页面即聚焦列表首项：遥控器方向键直接操作内容网格，
                  // 不需要先点一下键才"唤醒"焦点。
                  autofocus: i == 0,
                  onActivate: () => c.openChannel(ch),
                  child: _LiveChannelCard(
                    channel: ch,
                    onTap: () => c.openChannel(ch),
                    onLongPress: () => c.showLinePicker(ch),
                  ),
                );
              },
            );
          },
        );
      }),
    );
  }
}

class _LiveChannelCard extends StatelessWidget {
  final AggregatedChannel channel;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _LiveChannelCard({
    required this.channel,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasLogo = channel.logo?.isNotEmpty ?? false;
    return Semantics(
      button: true,
      label: channel.displayName,
      child: ShadowCard(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: LiveRoomGridLayout.coverAspectRatio,
              child: ClipRRect(
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  topRight: Radius.circular(8),
                ),
                child: ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: hasLogo
                      ? SizedBox.expand(
                          child: NetImage(channel.logo!, fit: BoxFit.contain),
                        )
                      : Center(
                          child: Icon(
                            Icons.live_tv,
                            size: 32,
                            color: theme.colorScheme.primary.withAlpha(120),
                          ),
                        ),
                ),
              ),
            ),
            SizedBox(
              height: LiveChannelsPage._detailsExtent,
              child: Padding(
                padding: AppStyle.edgeInsetsA8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            channel.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (channel.multiLine)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withAlpha(25),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '${channel.lines.length} 线路',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontSize: 10,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
