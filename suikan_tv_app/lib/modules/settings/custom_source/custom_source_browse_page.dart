import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/app/custom_source/custom_source_service.dart';
import 'package:simple_live_tv_app/app/custom_source/m3u_models.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/routes/app_navigation.dart';
import 'package:simple_live_tv_app/services/local_storage_service.dart';
import 'package:simple_live_tv_app/widgets/focus_card.dart';
import 'package:simple_live_tv_app/widgets/live_room_grid_layout.dart';
import 'package:simple_live_tv_app/widgets/net_image.dart';
import 'package:simple_live_tv_app/widgets/shadow_card.dart';
import 'package:sticky_headers/sticky_headers.dart';

/// 自定义源频道排序方式。
enum CustomSourceSortMode {
  manual('手动排序'),
  group('按分组'),
  nameAsc('按名称 A-Z'),
  nameDesc('按名称 Z-A');

  const CustomSourceSortMode(this.label);
  final String label;

  static CustomSourceSortMode fromName(String? name) => values
          .firstWhereOrNull((e) => e.name == name) ??
      CustomSourceSortMode.manual;
}

/// 同一频道（同名）合并后的条目，含全部线路。
class M3uChannelGroup {
  final String name;
  final List<M3uChannel> lines;

  M3uChannelGroup({required this.name, required this.lines});

  String get displayName => name.trim().isEmpty ? lines.first.url : name;
  String? get group => lines.first.group;
  String? get logo => lines.first.logo;
  bool get multiLine => lines.length > 1;
}

class CustomSourceBrowseController extends GetxController {
  final String sourceId;
  CustomSourceBrowseController(this.sourceId) {
    // 进入时恢复上次选择的排序方式。
    final src = source;
    sortMode.value = CustomSourceSortMode.fromName(src?.sortMode);
  }

  final sortMode = CustomSourceSortMode.manual.obs;

  /// 数据版本号：刷新直播源后 +1，驱动 Obx 重建列表（原地刷新，不跳转）。
  final version = 0.obs;

  /// 兼容首页/分类传入的带 custom_ 前缀的站点 id 与裸 id。
  String get _bareId => sourceId.startsWith('custom_')
      ? sourceId.substring('custom_'.length)
      : sourceId;

  M3uSource? get source => CustomSourceService.instance.sources
      .firstWhereOrNull((s) => s.id == _bareId);

  Site? get site => CustomSourceService.instance.siteForSource(_bareId);

  /// 同名频道合并为一条（多线路），保持源内出现顺序。
  List<M3uChannelGroup> get lineGroups {
    final src = source;
    if (src == null) return const [];
    final map = <String, List<M3uChannel>>{};
    final order = <String>[];
    for (final c in src.channels) {
      final key = c.name.trim().isEmpty ? c.url : c.name.trim();
      if (!map.containsKey(key)) {
        map[key] = [];
        order.add(key);
      }
      map[key]!.add(c);
    }
    return order
        .map((key) => M3uChannelGroup(name: key, lines: map[key]!))
        .toList();
  }

  /// 按分组：组内按频道名排序，组按名称排序。
  List<MapEntry<String, List<M3uChannelGroup>>> get groupedGroups {
    final map = <String, List<M3uChannelGroup>>{};
    for (final g in lineGroups) {
      final key = (g.group ?? '未分组').trim().isEmpty
          ? '未分组'
          : (g.group!).trim();
      map.putIfAbsent(key, () => []).add(g);
    }
    final entries = map.entries.map((e) {
      final sorted = [...e.value]
        ..sort((a, b) => a.displayName.compareTo(b.displayName));
      return MapEntry(e.key, sorted);
    }).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries;
  }

  /// 按名称 A-Z / Z-A。
  List<M3uChannelGroup> get sortedGroups {
    final list = [...lineGroups];
    final cmp = sortMode.value == CustomSourceSortMode.nameDesc
        ? (M3uChannelGroup a, M3uChannelGroup b) =>
            b.displayName.toLowerCase().compareTo(a.displayName.toLowerCase())
        : (M3uChannelGroup a, M3uChannelGroup b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    list.sort(cmp);
    return list;
  }

  /// 手动排序（设置页拖拽）：以合并条目为单位移动，持久化底层 channels 顺序。
  Future<void> reorderGroups(int oldIndex, int newIndex) async {
    final src = source;
    if (src == null) return;
    final groups = [...lineGroups];
    if (oldIndex < 0 || oldIndex >= groups.length) return;
    if (newIndex < 0) newIndex = 0;
    if (newIndex > groups.length) newIndex = groups.length;
    if (oldIndex < newIndex) newIndex -= 1;
    if (oldIndex == newIndex) return;
    final item = groups.removeAt(oldIndex);
    groups.insert(newIndex, item);
    final ordered = groups.expand((g) => g.lines).toList();
    await CustomSourceService.instance.reorderChannels(_bareId, ordered);
  }

  /// 切换排序方式并持久化。
  void setSortMode(CustomSourceSortMode mode) {
    if (sortMode.value == mode) return;
    sortMode.value = mode;
    CustomSourceService.instance.updateSortMode(_bareId, mode.name);
  }

  /// 上次播放/选择的线路持久化键前缀。
  static const String _kLastLinePrefix = 'CustomSourceLastLine_';

  /// 点击频道：自动选择上次播放/选择的线路；无记录则选第一条线路，直接进入直播间。
  /// 手动选线路请长按卡片（showLinePicker）。
  void openGroup(M3uChannelGroup group) {
    final M3uChannel line;
    if (group.multiLine) {
      final last = getLastLineUrl(group);
      line = last != null
          ? (group.lines.firstWhereOrNull((l) => l.url == last) ??
              group.lines.first)
          : group.lines.first;
    } else {
      line = group.lines.first;
    }
    _openChannel(line, group);
  }

  /// 长按卡片：手动选择线路，选完记录为「上次线路」，下次进入沿用。
  void showLinePicker(M3uChannelGroup group) {
    showModalBottomSheet(
      context: Get.context!,
      builder: (context) {
        final lastUrl = getLastLineUrl(group);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '${group.displayName}（${group.lines.length} 条线路）',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Divider(height: 1),
              ...group.lines.asMap().entries.map((e) {
                final i = e.key;
                final line = e.value;
                final lineName =
                    line.name.trim() == group.name.trim() || line.name.isEmpty
                        ? '线路 ${i + 1}'
                        : line.name;
                final isLast = lastUrl == line.url;
                return ListTile(
                  leading: Icon(
                    isLast ? Icons.history : Icons.play_circle_outline,
                    color: Get.theme.colorScheme.primary,
                  ),
                  title: Text(lineName),
                  subtitle: Text(
                    line.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: isLast
                      ? Icon(
                          Icons.check,
                          color: Get.theme.colorScheme.primary,
                        )
                      : null,
                  onTap: () {
                    Get.back();
                    _openChannel(line, group);
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

  /// 读取某频道上次播放/选择的线路 URL（仅当该线路仍存在时有效，否则返回 null）。
  String? getLastLineUrl(M3uChannelGroup group) {
    final saved = LocalStorageService.instance
        .getValue<String?>(_lastLineKey(group), null);
    if (saved == null) return null;
    final match = group.lines.firstWhereOrNull((l) => l.url == saved);
    return match?.url;
  }

  void _recordLastLine(M3uChannelGroup group, M3uChannel line) {
    LocalStorageService.instance.setValue(_lastLineKey(group), line.url);
  }

  String _lastLineKey(M3uChannelGroup group) =>
      '$_kLastLinePrefix${_bareId}_${group.displayName}';

  void _openChannel(M3uChannel channel, M3uChannelGroup group) {
    _recordLastLine(group, channel);
    final s = site;
    if (s == null) return;
    AppNavigator.toLiveRoomDetail(site: s, roomId: channel.url);
  }
}

class CustomSourceBrowsePage extends StatelessWidget {
  final String sourceId;
  CustomSourceBrowsePage({Key? key, required this.sourceId})
      : super(key: key);

  // 详情行只放频道名+线路角标，56 太高把整卡撑大、台标区域留白明显。
  static const double _detailsExtent = 44;

  CustomSourceBrowseController get controller =>
      Get.isRegistered<CustomSourceBrowseController>(tag: sourceId)
          ? Get.find<CustomSourceBrowseController>(tag: sourceId)
          : Get.put(CustomSourceBrowseController(sourceId), tag: sourceId);

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Scaffold(
      // 首页/分类内嵌 tab 页：无上级路由可返回，隐藏返回按钮。
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Obx(
          () => Text(
            c.source == null
                ? '自定义源'
                : (c.source!.name.isEmpty ? c.source!.url : c.source!.name),
          ),
        ),
        actions: [
          IconButton(
            tooltip: '刷新直播源',
            icon: const Icon(Icons.refresh),
            onPressed: () => _refreshSource(c),
          ),
          Obx(() {
            if (c.sortMode.value == CustomSourceSortMode.manual) {
              return IconButton(
                tooltip: '编辑手动排序',
                icon: const Icon(Icons.edit_note),
                onPressed: () => Get.to(
                  () => CustomSourceSortEditPage(sourceId: sourceId),
                ),
              );
            }
            return const SizedBox.shrink();
          }),
          Obx(() => _buildSortButton(c)),
        ],
      ),
      body: Obx(() {
        c.version; // 依赖版本号：刷新后重建列表
        final src = c.source;
        if (src == null) {
          return const Center(child: Text('该直播源不存在或已删除'));
        }
        if (src.channels.isEmpty) {
          return const Center(child: Text('该直播源暂无频道'));
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final layout = LiveRoomGridLayout.resolve(
              constraints.maxWidth,
              // 频道卡比直播封面小：最小宽 132、最多 12 列 → 卡更矮更密，
              // 台标 contain 显示的留白随卡片一起变小，观感更紧凑。
              minCardWidth: 132,
              maxColumns: 12,
              detailsExtent: _detailsExtent,
            );
            switch (c.sortMode.value) {
              case CustomSourceSortMode.manual:
                return _buildChannelGrid(c, c.lineGroups, layout);
              case CustomSourceSortMode.group:
                return _buildGroup(c, layout);
              case CustomSourceSortMode.nameAsc:
              case CustomSourceSortMode.nameDesc:
                return _buildChannelGrid(c, c.sortedGroups, layout);
            }
          },
        );
      }),
    );
  }

  /// 刷新直播源：重新拉取 M3U，更新频道地址、台标、分组等所有内容。
  /// notify:false 不触发首页/分类重建标签页，避免刷新后跳转到其它平台。
  Future<void> _refreshSource(CustomSourceBrowseController c) async {
    final id = c.source?.id;
    if (id == null) return;
    SmartDialog.showLoading(msg: '正在刷新直播源…');
    try {
      await CustomSourceService.instance.refreshSource(id, notify: false);
      c.version.value++;
      SmartDialog.dismiss();
      SmartDialog.showToast('刷新完成');
    } catch (e) {
      SmartDialog.dismiss();
      SmartDialog.showToast('刷新失败：$e');
    }
  }

  /// 排序按钮：显示当前方式，点击弹出「如何排序」菜单。
  Widget _buildSortButton(CustomSourceBrowseController c) {
    return TextButton.icon(
      onPressed: () => _showSortSheet(c),
      icon: const Icon(Icons.sort),
      label: Text(c.sortMode.value.label),
    );
  }

  Future<void> _showSortSheet(CustomSourceBrowseController c) async {
    await showModalBottomSheet(
      context: Get.context!,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '如何排序',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              const Divider(height: 1),
              ...CustomSourceSortMode.values.map((mode) {
                final selected = c.sortMode.value == mode;
                return ListTile(
                  leading: Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: selected
                        ? Get.theme.colorScheme.primary
                        : Get.theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(mode.label),
                  trailing: mode == CustomSourceSortMode.manual
                      ? const Icon(Icons.edit_note)
                      : (selected
                          ? Icon(
                              Icons.check,
                              color: Get.theme.colorScheme.primary,
                            )
                          : null),
                  onTap: () {
                    c.setSortMode(mode);
                    Get.back();
                    if (mode == CustomSourceSortMode.manual) {
                      // 手动排序需要先设置顺序
                      Get.to(
                        () => CustomSourceSortEditPage(sourceId: sourceId),
                      );
                    }
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

  /// 按分组：分组吸顶 + 组内频道网格。
  Widget _buildGroup(CustomSourceBrowseController c, LiveRoomGridLayout layout) {
    final groups = c.groupedGroups
        .map((e) => MapEntry(e.key, e.value))
        .where((e) => e.value.isNotEmpty)
        .toList();
    return ListView.builder(
      padding: AppStyle.edgeInsetsA12,
      itemCount: groups.length,
      itemBuilder: (_, gi) {
        final entry = groups[gi];
        return StickyHeader(
          header: Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            color: Get.theme.scaffoldBackgroundColor,
            alignment: Alignment.centerLeft,
            child: Text(
              '${entry.key}（${entry.value.length}）',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          content: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: layout.crossAxisCount,
              mainAxisSpacing: LiveRoomGridLayout.defaultSpacing,
              crossAxisSpacing: LiveRoomGridLayout.defaultSpacing,
              mainAxisExtent: layout.mainAxisExtent,
            ),
            itemCount: entry.value.length,
            itemBuilder: (_, i) {
              final g = entry.value[i];
              return FocusCard(
                onActivate: () => c.openGroup(g),
                child: _ChannelCard(
                  group: g,
                  onTap: () => c.openGroup(g),
                  onLongPress: () => c.showLinePicker(g),
                ),
              );
            },
          ),
        );
      },
    );
  }

  /// 全量网格。
  Widget _buildChannelGrid(
    CustomSourceBrowseController c,
    List<M3uChannelGroup> list,
    LiveRoomGridLayout layout,
  ) {
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
        final g = list[i];
        return FocusCard(
          onActivate: () => c.openGroup(g),
          child: _ChannelCard(
            group: g,
            onTap: () => c.openGroup(g),
            onLongPress: () => c.showLinePicker(g),
          ),
        );
      },
    );
  }
}

/// 手动排序设置页：以合并条目为单位拖拽，保存后浏览页网格按新顺序显示。
class CustomSourceSortEditPage extends StatelessWidget {
  final String sourceId;
  const CustomSourceSortEditPage({Key? key, required this.sourceId})
      : super(key: key);

  CustomSourceBrowseController get controller =>
      Get.find<CustomSourceBrowseController>(tag: sourceId);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("手动排序"),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text("完成"),
          ),
        ],
      ),
      body: Obx(() {
        final groups = controller.lineGroups;
        if (groups.isEmpty) {
          return const Center(child: Text("暂无频道"));
        }
        return ReorderableListView.builder(
          padding: AppStyle.edgeInsetsA12,
          itemCount: groups.length,
          onReorder: (oldIndex, newIndex) =>
              controller.reorderGroups(oldIndex, newIndex),
          itemBuilder: (_, i) {
            final g = groups[i];
            return _ManualCard(
              key: ValueKey('${g.displayName}_${i}'),
              group: g,
            );
          },
        );
      }),
    );
  }
}

/// 平台直播间同款网格卡片：封面（logo/占位）+ 频道名 + 分组 + 线路数徽标。
class _ChannelCard extends StatelessWidget {
  final M3uChannelGroup group;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _ChannelCard({
    required this.group,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasLogo = group.logo?.isNotEmpty ?? false;
    return Semantics(
      button: true,
      label: group.displayName,
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
                          child: NetImage(
                            group.logo!,
                            fit: BoxFit.contain,
                          ),
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
              height: CustomSourceBrowsePage._detailsExtent,
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
                            group.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (group.multiLine)
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
                              '${group.lines.length} 线路',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontSize: 10,
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (group.group?.isNotEmpty ?? false)
                      Text(
                        group.group!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
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

/// 手动排序设置页用的横向卡片：左侧封面缩略图 + 名称/分组/线路数 + 拖拽手柄。
class _ManualCard extends StatelessWidget {
  final M3uChannelGroup group;
  const _ManualCard({Key? key, required this.group}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasLogo = group.logo?.isNotEmpty ?? false;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ShadowCard(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 96,
                  height: 54,
                  child: ColoredBox(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: hasLogo
                        ? SizedBox.expand(
                            child: NetImage(group.logo!, fit: BoxFit.contain))
                        : Icon(
                            Icons.live_tv,
                            size: 24,
                            color: theme.colorScheme.primary.withAlpha(120),
                          ),
                  ),
                ),
              ),
              AppStyle.hGap12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      group.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (group.group?.isNotEmpty ?? false)
                      Text(
                        group.multiLine
                            ? '${group.group!} · ${group.lines.length} 条线路'
                            : group.group!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.drag_handle,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
