import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/custom_source/custom_source_service.dart';
import 'package:simple_live_app/app/custom_source/m3u_models.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
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
  const CustomSourceAggregatePage({Key? key}) : super(key: key);

  CustomSourceAggregateController get controller =>
      Get.isRegistered<CustomSourceAggregateController>()
          ? Get.find<CustomSourceAggregateController>()
          : Get.put(CustomSourceAggregateController());

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Scaffold(
      appBar: AppBar(
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
        final list = c.channels;
        if (list.isEmpty) {
          return const AppEmptyWidget(message: '暂无频道\n请先添加直播源');
        }
        return ListView.separated(
          padding: AppStyle.edgeInsetsA12,
          itemCount: list.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final ch = list[i];
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              leading: SizedBox(
                width: 40,
                height: 28,
                child: ch.logo != null && ch.logo!.isNotEmpty
                    ? Image.network(
                        ch.logo!,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.live_tv_outlined, size: 20),
                      )
                    : const Icon(Icons.live_tv_outlined, size: 20),
              ),
              title: Text(
                ch.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                ch.multiLine ? '${ch.lines.length} 个线路' : '1 个源',
              ),
              trailing: ch.multiLine
                  ? const Icon(Icons.more_vert)
                  : const Icon(Icons.play_arrow),
              onTap: () => c.openChannel(ch),
              onLongPress: ch.multiLine ? () => _showLinePicker(c, ch) : null,
            );
          },
        );
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
