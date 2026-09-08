import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/settings/indexed_settings/indexed_settings_controller.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';

class IndexedSettingsPage extends GetView<IndexedSettingsController> {
  const IndexedSettingsPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("主页设置"),
      ),
      body: ListView(
        padding: AppStyle.pagePadding(),
        children: [
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 0),
            child: Text(
              "主页排序 (长按拖动排序，重启后生效)",
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Obx(
              () => ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                onReorder: controller.updateHomeSort,
                children: controller.homeSort.map(
                  (key) {
                    var e = Constant.allHomePages[key]!;
                    return ListTile(
                      key: ValueKey(e.title),
                      title: Text(e.title),
                      visualDensity: VisualDensity.compact,
                      leading: Icon(e.iconData),
                      trailing: const Icon(Icons.drag_handle),
                    );
                  },
                ).toList(),
              ),
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "隐藏平台 (关闭后首页/分类不再显示，立即生效)",
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Obx(
              () => Column(
                children: Sites.allSites.values
                    .map((site) {
                  final hidden = controller.hiddenSites.contains(site.id);
                  return SettingsSwitch(
                    key: ValueKey(site.id),
                    leading: Image.asset(
                      site.logo,
                      width: 24,
                      height: 24,
                    ),
                    title: site.name,
                    value: !hidden,
                    onChanged: (show) {
                      final ok = controller.toggleHiddenSite(
                        site.id,
                        !show,
                      );
                      if (!ok) {
                        Get.snackbar("提示", "至少需要保留一个平台显示");
                      }
                    },
                  );
                }).toList(),
              ),
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "平台排序 (长按拖动排序，立即生效；含自定义直播源与影视库)",
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Obx(
              () => ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                onReorder: controller.updateSiteSort,
                children: controller.effectiveBrowseSiteOrder.map((key) {
                  final site = Sites.allSites[key];
                  if (site == null) {
                    // 自定义源 / 影视库站点
                    final name = key.startsWith('custom_')
                        ? '自定义直播源'
                        : key.startsWith('fnos_')
                            ? '飞牛影视'
                            : key;
                    return ListTile(
                      key: ValueKey(key),
                      visualDensity: VisualDensity.compact,
                      title: Text(name),
                      leading: Image.asset(
                        'assets/images/logo.png',
                        width: 24,
                        height: 24,
                      ),
                      trailing: const Icon(Icons.drag_handle),
                    );
                  }
                  return ListTile(
                    key: ValueKey(site.id),
                    visualDensity: VisualDensity.compact,
                    title: Text(site.name),
                    leading: Image.asset(
                      site.logo,
                      width: 24,
                      height: 24,
                    ),
                    trailing: const Icon(Icons.drag_handle),
                  );
                }).toList(),
              ),
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "聚合入口 (同类源 ≥2 时，首页/分类末尾出现「电视」「影视」汇总 Tab；关闭则逐个显示)",
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Obx(
              () => Column(
                children: [
                  SettingsSwitch(
                    leading: const Icon(Icons.live_tv, size: 22),
                    title: "电视（直播源汇总）",
                    value: AppSettingsController
                        .instance.aggregateLiveEnable.value,
                    onChanged: controller.setAggregateLiveEnable,
                  ),
                  SettingsSwitch(
                    leading: const Icon(Icons.movie_outlined, size: 22),
                    title: "影视（影视库汇总）",
                    value: AppSettingsController
                        .instance.aggregateVodEnable.value,
                    onChanged: controller.setAggregateVodEnable,
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
