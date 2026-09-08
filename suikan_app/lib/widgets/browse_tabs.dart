import 'package:flutter/material.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/settings/custom_source/custom_source_aggregate_page.dart';
import 'package:simple_live_app/modules/settings/fnos/fn_os_browse_page.dart';

/// 首页/分类页浏览 Tab 的统一描述（多直播源/多影视库聚合，与 TV 一致）。
///
/// - 自定义直播源 **≥2**：折叠为单个「电视」聚合 tab（跨源同名频道合并多线）；
/// - 飞牛影视服务器 **≥2**：折叠为单个「影视」聚合 tab（多库合并浏览）；
/// - 其余站点按原浏览顺序展示（单源用户界面不变，不会被折叠）。
///
/// 两处调用方（首页/分类页）的 TabBar、TabBarView 与 TabController.length
/// 都必须基于同一次解析，避免 index 错位。
class BrowseTabEntry {
  /// null 表示聚合 tab；否则为该站点 id。
  final String? siteId;

  /// 聚合类别：live=电视（直播源聚合）vod=影视（影视库聚合）。
  final String? aggregate;

  BrowseTabEntry.site(String id)
      : siteId = id,
        aggregate = null;
  BrowseTabEntry.aggregateLive()
      : siteId = null,
        aggregate = 'live';
  BrowseTabEntry.aggregateVod()
      : siteId = null,
        aggregate = 'vod';
}

/// 一次性解析浏览 tab 条目。
///
/// 顺序：各平台（含未折叠的单源自定义源/影视库）按「主页设置」的浏览顺序
/// 排列，聚合入口（电视/影视）**统一殿后**；聚合入口是否显示由
/// 「主页设置 → 聚合入口」开关控制，仅当同类源 ≥2 时才折叠成一个聚合 tab，
/// 关闭开关即退回逐个显示。
List<BrowseTabEntry> buildBrowseTabEntries() {
  final settings = AppSettingsController.instance;
  final sites = Sites.browseSites;
  final customSites =
      sites.where((s) => s.id.startsWith('custom_')).toList();
  final fnosSites = sites.where((s) => s.id.startsWith('fnos_')).toList();
  final foldCustom =
      customSites.length > 1 && settings.aggregateLiveEnable.value;
  final foldVod = fnosSites.length > 1 && settings.aggregateVodEnable.value;

  final entries = <BrowseTabEntry>[];
  for (final s in sites) {
    if (foldCustom && s.id.startsWith('custom_')) continue;
    if (foldVod && s.id.startsWith('fnos_')) continue;
    entries.add(BrowseTabEntry.site(s.id));
  }
  // 聚合入口固定在平台（含单源）之后。
  if (foldCustom) entries.add(BrowseTabEntry.aggregateLive());
  if (foldVod) entries.add(BrowseTabEntry.aggregateVod());
  return entries;
}

/// Tab 标题控件（图标/文字；聚合 tab 用 Icon，站点用图片 logo）。
class BrowseTabLabel extends StatelessWidget {
  final BrowseTabEntry entry;
  const BrowseTabLabel({Key? key, required this.entry}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final siteId = entry.siteId;
    if (siteId != null) {
      final e = Sites.siteForKey(siteId);
      if (e == null) return const SizedBox.shrink();
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(e.logo, width: 24),
          const SizedBox(width: 8),
          Text(e.name),
        ],
      );
    }
    if (entry.aggregate == 'live') {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.live_tv, size: 22),
          SizedBox(width: 6),
          Text('电视'),
        ],
      );
    }
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.movie_outlined, size: 22),
        SizedBox(width: 6),
        Text('影视'),
      ],
    );
  }
}

/// 对应 TabBarView 的内容页。
///
/// [siteBuilder]：普通站点页构造器（含单源的影视库/自定义源页与平台列表页），
/// 首页/分类页各自传入自己的列表页实现。
class BrowseTabContent extends StatelessWidget {
  final BrowseTabEntry entry;
  final Widget Function(String siteId) siteBuilder;
  const BrowseTabContent({
    Key? key,
    required this.entry,
    required this.siteBuilder,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final siteId = entry.siteId;
    if (siteId != null) return siteBuilder(siteId);
    // 聚合 tab
    return entry.aggregate == 'live'
        ? const CustomSourceAggregatePage(embedded: true)
        : const FnOsBrowsePage(server: null, embedded: true);
  }
}
