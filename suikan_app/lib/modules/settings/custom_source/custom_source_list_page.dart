import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/custom_source/custom_source_service.dart';
import 'package:simple_live_app/app/custom_source/m3u_models.dart';
import 'package:simple_live_app/widgets/shadow_card.dart';
import 'package:simple_live_app/widgets/status/app_empty_widget.dart';

import 'custom_source_aggregate_page.dart';
import 'custom_source_browse_page.dart';

class CustomSourceListPage extends StatelessWidget {
  const CustomSourceListPage({Key? key}) : super(key: key);

  String _formatTime(int? ts) {
    if (ts == null) return '未更新';
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    String p(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  Future<void> _showAddDialog(BuildContext context) async {
    final result = await Get.dialog<bool>(
      const CustomSourceEditDialog(),
    );
    if (result == true) {
      SmartDialog.showToast('添加成功');
    }
  }

  Future<void> _edit(M3uSource src) async {
    final result = await Get.dialog<bool>(
      CustomSourceEditDialog(source: src),
    );
    if (result == true) {
      SmartDialog.showToast('已保存');
    }
  }

  Future<void> _refresh(M3uSource src) async {
    SmartDialog.showLoading(msg: '正在刷新…');
    try {
      await CustomSourceService.instance.refreshSource(src.id);
      SmartDialog.dismiss();
      SmartDialog.showToast('已刷新');
    } catch (e) {
      SmartDialog.dismiss();
      SmartDialog.showToast('刷新失败：$e');
    }
  }

  Future<void> _remove(M3uSource src) async {
    final ok = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('删除直播源'),
        content: Text('确定删除「${src.name}」？'),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await CustomSourceService.instance.removeSource(src.id);
      SmartDialog.showToast('已删除');
    }
  }

  Future<void> _refreshAll() async {
    final list = CustomSourceService.instance.sources;
    if (list.isEmpty) {
      SmartDialog.showToast('暂无直播源');
      return;
    }
    SmartDialog.showLoading(msg: '正在刷新全部直播源…');
    var ok = 0;
    var fail = 0;
    for (final src in list) {
      try {
        await CustomSourceService.instance.refreshSource(src.id);
        ok++;
      } catch (_) {
        fail++;
      }
    }
    SmartDialog.dismiss();
    SmartDialog.showToast(fail == 0 ? '已刷新 $ok 个直播源' : '刷新完成：成功 $ok，失败 $fail');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('自定义直播源'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新全部直播源',
            onPressed: _refreshAll,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddDialog(context),
        tooltip: '添加直播源',
        child: const Icon(Icons.add),
      ),
      body: Obx(
        () {
          final list = CustomSourceService.instance.sources;
          if (list.isEmpty) {
            return AppEmptyWidget(
              message: '还没有自定义直播源\n点击右下角添加 M3U 地址',
              onRefresh: () async {},
            );
          }
          // 源列表也用与频道卡一致的圆角卡片语言（统一观感）。
          // 多直播源时顶部提供「频道汇总」入口：跨源同名频道合并多线路。
          final withAggregate = list.length > 1;
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: list.length + (withAggregate ? 1 : 0),
            itemBuilder: (_, i) {
              if (withAggregate && i == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ShadowCard(
                    radius: 14,
                    onTap: () => Get.to(const CustomSourceAggregatePage()),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      child: Row(
                        children: [
                          Icon(Icons.auto_awesome_mosaic_outlined,
                              size: 28, color: Colors.deepOrange),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '频道汇总',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Icon(Icons.chevron_right),
                        ],
                      ),
                    ),
                  ),
                );
              }
              final src = list[withAggregate ? i - 1 : i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ShadowCard(
                  radius: 14,
                  onTap: () {
                    final site = CustomSourceService.instance.siteForSource(
                      src.id,
                    );
                    if (site == null) return;
                    // 直达新样式频道页(16:9 频道卡/分组吸顶/名称居中,
                    // 与首页自定义源 Tab、聚合页同款视觉)。
                    Get.to(
                      () => CustomSourceBrowsePage(
                        sourceId: site.id,
                        showBackButton: true,
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                    child: Row(
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.playlist_play,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                src.name.isEmpty ? src.url : src.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${src.groupCountText} · 更新于 '
                                '${_formatTime(src.lastUpdated)}'
                                '${src.autoRefresh ? ' · 自动刷新' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          tooltip: '编辑',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _edit(src),
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 20),
                          tooltip: '刷新',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _refresh(src),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          tooltip: '删除',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _remove(src),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// 添加/编辑直播源对话框：含名称、M3U 地址与自动刷新规则。
class CustomSourceEditDialog extends StatefulWidget {
  final M3uSource? source; // 为 null 表示新增
  const CustomSourceEditDialog({Key? key, this.source}) : super(key: key);

  @override
  State<CustomSourceEditDialog> createState() => _CustomSourceEditDialogState();
}

class _CustomSourceEditDialogState extends State<CustomSourceEditDialog> {
  final nameCtl = TextEditingController();
  final urlCtl = TextEditingController();
  final intervalCtl = TextEditingController(text: '6');
  final hourCtl = TextEditingController(text: '4');

  bool autoRefresh = false;
  String refreshMode = kRefreshModeInterval;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final s = widget.source;
    if (s != null) {
      nameCtl.text = s.name;
      urlCtl.text = s.url;
      autoRefresh = s.autoRefresh;
      refreshMode = s.refreshMode;
      intervalCtl.text = s.refreshIntervalHours.toString();
      hourCtl.text = s.refreshHour.toString();
    }
  }

  Future<void> _save() async {
    final url = urlCtl.text.trim();
    if (url.isEmpty) {
      SmartDialog.showToast('请填写 M3U 地址');
      return;
    }
    final name = nameCtl.text.trim().isEmpty ? url : nameCtl.text.trim();
    final interval = int.tryParse(intervalCtl.text.trim()) ?? 6;
    final hour = (int.tryParse(hourCtl.text.trim()) ?? 4).clamp(0, 23);
    if (autoRefresh && refreshMode == kRefreshModeDaily && hour < 0) {
      SmartDialog.showToast('小时需在 0-23 之间');
      return;
    }
    setState(() => _saving = true);
    SmartDialog.showLoading(msg: widget.source == null ? '正在拉取直播源…' : '正在保存…');
    try {
      if (widget.source == null) {
        final src = await CustomSourceService.instance
            .addSource(name: name, url: url);
        await CustomSourceService.instance.setRefreshRule(
          src.id,
          autoRefresh: autoRefresh,
          refreshMode: refreshMode,
          refreshIntervalHours: interval,
          refreshHour: hour,
        );
      } else {
        await CustomSourceService.instance.updateSource(
          widget.source!.id,
          name: name,
          url: url,
        );
        await CustomSourceService.instance.setRefreshRule(
          widget.source!.id,
          autoRefresh: autoRefresh,
          refreshMode: refreshMode,
          refreshIntervalHours: interval,
          refreshHour: hour,
        );
      }
      SmartDialog.dismiss();
      Get.back(result: true);
    } catch (e) {
      SmartDialog.dismiss();
      SmartDialog.showToast('保存失败：$e');
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.source == null ? '添加直播源' : '编辑直播源'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameCtl,
              decoration: const InputDecoration(
                labelText: '名称（选填）',
                hintText: '例如：我的IPTV',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlCtl,
              decoration: const InputDecoration(
                labelText: 'M3U 地址',
                hintText: 'http://.../xxx.m3u',
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '自动刷新',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Transform.scale(
                  scale: 0.75,
                  child: Switch(
                    value: autoRefresh,
                    onChanged: (v) => setState(() => autoRefresh = v),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            if (autoRefresh) ...[
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: kRefreshModeInterval,
                    label: Text('每隔 N 小时'),
                  ),
                  ButtonSegment(
                    value: kRefreshModeDaily,
                    label: Text('每天指定时间'),
                  ),
                ],
                selected: {refreshMode},
                onSelectionChanged: (s) =>
                    setState(() => refreshMode = s.first),
              ),
              const SizedBox(height: 12),
              if (refreshMode == kRefreshModeInterval)
                TextField(
                  controller: intervalCtl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '刷新间隔（小时）',
                    hintText: '例如 6',
                  ),
                )
              else
                TextField(
                  controller: hourCtl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '每天刷新时间（0-23 点）',
                    hintText: '例如 4',
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Get.back(result: false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
