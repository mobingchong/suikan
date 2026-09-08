import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

import 'package:simple_live_app/app/custom_source/custom_source_service.dart';
import 'package:simple_live_app/app/custom_source/m3u_models.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/widgets/live_room_grid_layout.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/shadow_card.dart';
import 'package:simple_live_app/widgets/status/app_empty_widget.dart';

/// 跨源聚合的一条线路（频道 + 它所属的直播源）。
class AggregateChannelLine {
  final M3uChannel channel;
  final M3uSource source;
  const AggregateChannelLine({required this.channel, required this.source});
}

/// 跨源聚合频道：所有直播源中**同名频道合并成多线路**（与 TV「电视直播」一致）。
class AggregateChannel {
  final String name;
  final List<AggregateChannelLine> lines;
  AggregateChannel({required this.name, required this.lines});

  bool get multiLine => lines.length > 1;
  String get displayName =>
      name.trim().isEmpty ? lines.first.channel.url : name.trim();

  String? get logo {
    for (final l in lines) {
      final v = l.channel.logo;
      if (v != null && v.trim().isNotEmpty) return v;
    }
    return null;
  }

  /// 所属 M3U 分组：取第一条带非空 group 的线路（跨源同名频道组可能不同，
  /// 归入最先出现的那一组的名字）。
  String? get group {
    for (final l in lines) {
      final g = l.channel.group;
      if (g != null && g.trim().isNotEmpty) return g.trim();
    }
    return null;
  }
}

/// 跨源频道汇总：先按源文件名排序，再按源顺序遍历频道，同名合并为多线路。
/// 点击播放沿用上次选择的线路（多线时），长按手动选线路。
class CustomSourceAggregateController extends GetxController {
  /// 数据版本号：直播源增删/刷新后 +1，驱动 Obx 重建。
  final version = 0.obs;

  static const String _kLastLinePrefix = 'AggregateSourceLastLine_';

  static String _keyFor(M3uChannel c) =>
      c.name.trim().isEmpty ? c.url : c.name.trim();

  List<AggregateChannel> get channels {
    final sources = [...CustomSourceService.instance.sources]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final map = <String, List<AggregateChannelLine>>{};
    final order = <String>[];
    for (final src in sources) {
      for (final c in src.channels) {
        final key = _keyFor(c);
        map.putIfAbsent(key, () => []).add(
              AggregateChannelLine(channel: c, source: src),
            );
        if (!order.contains(key)) {
          order.add(key);
        }
      }
    }
    return order
        .map((k) => AggregateChannel(name: k, lines: map[k]!))
        .toList();
  }

  /// 按 M3U 分组的分组建：组顺序 = 组内第一个频道首次出现顺序；
  /// 未分组（无 group 字段）的频道统一归入「其他频道」。
  List<MapEntry<String, List<AggregateChannel>>> get groupedChannels {
    final order = <String>[];
    final map = <String, List<AggregateChannel>>{};
    for (final ch in channels) {
      final g = ch.group;
      final key = (g == null || g.isEmpty) ? '其他频道' : g;
      map.putIfAbsent(key, () => <AggregateChannel>[]).add(ch);
      if (!order.contains(key)) order.add(key);
    }
    return order
        .map((k) => MapEntry(k, map[k]!))
        .toList();
  }

  /// 刷新全部直播源后统一通知一次。
  Future<void> refreshAll() async {
    SmartDialog.showLoading(msg: '正在刷新直播源…');
    try {
      for (final s in List<M3uSource>.from(CustomSourceService.instance.sources)) {
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

  void openChannel(AggregateChannel ch) => _play(_pickLine(ch));

  AggregateChannelLine _pickLine(AggregateChannel ch) {
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

  void _play(AggregateChannelLine line) {
    _recordLastLine(line);
    final site = CustomSourceService.instance.siteForSource(line.source.id);
    if (site == null) {
      SmartDialog.showToast('未找到该直播源');
      return;
    }
    AppNavigator.toLiveRoomDetail(site: site, roomId: line.channel.url);
  }

  String? getLastLineUrl(AggregateChannel ch) {
    final saved = LocalStorageService.instance
        .getValue<String?>(_lastLineKey(ch.name), null);
    if (saved == null) return null;
    final match = ch.lines.firstWhereOrNull((l) => l.channel.url == saved);
    return match?.channel.url;
  }

  void _recordLastLine(AggregateChannelLine line) {
    LocalStorageService.instance
        .setValue(_lastLineKey(_keyFor(line.channel)), line.channel.url);
  }

  String _lastLineKey(String key) => '$_kLastLinePrefix$key';
}

/// 跨源直播频道汇总页（多直播源同名合并多线）。
class CustomSourceAggregatePage extends StatelessWidget {
  /// 与单源浏览页一致：频道名详情行高。
  static const double _detailsExtent = 44;

  /// 作为首页/分类页 Tab 内嵌时隐藏返回箭头。
  final bool embedded;
  const CustomSourceAggregatePage({Key? key, this.embedded = false})
      : super(key: key);

  CustomSourceAggregateController get controller =>
      Get.isRegistered<CustomSourceAggregateController>()
          ? Get.find<CustomSourceAggregateController>()
          : Get.put(CustomSourceAggregateController());

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: embedded ? false : true,
        title: const Text('频道汇总'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新全部直播源',
            onPressed: () => c.refreshAll(),
          ),
        ],
      ),
      body: Obx(() {
        c.version.value;
        final groups = c.groupedChannels;
        var total = 0;
        for (final g in groups) {
          total += g.value.length;
        }
        if (total == 0) {
          return const AppEmptyWidget(message: '暂无频道\n请先添加直播源');
        }
        // 网格与单源浏览页完全同构（LiveRoomGridLayout 一套参数）：
        // 无论 1 个源还是多个源，频道卡样式/密度保持一致。
        return LayoutBuilder(
          builder: (context, constraints) {
            final layout = LiveRoomGridLayout.resolve(
              constraints.maxWidth,
              // 与单源浏览页一致：min 108 → 手机 3 列，宽屏自适应更多列。
              minCardWidth: 108,
              detailsExtent: CustomSourceAggregatePage._detailsExtent,
            );
            const pad = LiveRoomGridLayout.defaultHorizontalPadding;
        return ListView.builder(
          padding: EdgeInsets.all(pad),
          itemCount: groups.length,
          itemBuilder: (_, gi) {
            final g = groups[gi];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
                  child: Text(
                    '${g.key}（${g.value.length}）',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: layout.crossAxisCount,
                    mainAxisSpacing: LiveRoomGridLayout.defaultSpacing,
                    crossAxisSpacing: LiveRoomGridLayout.defaultSpacing,
                    mainAxisExtent: layout.mainAxisExtent,
                  ),
                  itemCount: g.value.length,
                  itemBuilder: (_, i) {
                    final ch = g.value[i];
                    return _AggregateChannelCard(
                      channel: ch,
                      onTap: () => c.openChannel(ch),
                      onLongPress: ch.multiLine
                          ? () => _showLinePicker(c, ch)
                          : null,
                    );
                  },
                ),
                const SizedBox(height: 6),
              ],
            );
          },
        );
        });
      }),
    );
  }

  void _showLinePicker(
      CustomSourceAggregateController c, AggregateChannel ch) {
    showModalBottomSheet(
      context: Get.context!,
      builder: (context) {
        final lastUrl = c.getLastLineUrl(ch);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  ch.displayName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: ch.lines.length,
                  itemBuilder: (context, i) {
                    final line = ch.lines[i];
                    final selected = line.channel.url == lastUrl;
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: Text(
                        line.source.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        line.channel.group?.isNotEmpty == true
                            ? line.channel.group!
                            : line.channel.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        c._play(line);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}


/// 聚合频道卡片（手机 3 列小卡）：上部方形台标区 + 底部频道名；
/// 多线路频道右上角显示「N线」徽章，长按可手动选线路。
class _AggregateChannelCard extends StatefulWidget {
  final AggregateChannel channel;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _AggregateChannelCard({
    required this.channel,
    required this.onTap,
    this.onLongPress,
  });

  @override
  State<_AggregateChannelCard> createState() => _AggregateChannelCardState();
}

class _AggregateChannelCardState extends State<_AggregateChannelCard> {
  bool _logoFailed = false;

  AggregateChannel get channel => widget.channel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final logo = _logoFailed ? null : channel.logo;
    return ShadowCard(
      radius: 10,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 与 TV「电视直播」同款：16:9 台标区，横向台标贴图不悬空。
          AspectRatio(
            aspectRatio: LiveRoomGridLayout.coverAspectRatio,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(10),
              ),
              child: ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
                      child: logo != null && logo.isNotEmpty
                          ? NetImage(
                              logo,
                              fit: BoxFit.contain,
                              onLoadFailed: () {
                                if (mounted) setState(() => _logoFailed = true);
                              },
                            )
                          : Icon(
                              Icons.live_tv,
                              size: 30,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      channel.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                  if (channel.multiLine)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${channel.lines.length}线',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
