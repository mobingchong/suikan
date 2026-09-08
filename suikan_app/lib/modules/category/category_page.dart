import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_app/modules/category/category_controller.dart';
import 'package:simple_live_app/modules/category/category_list_view.dart';
import 'package:simple_live_app/widgets/browse_tabs.dart';
import 'package:simple_live_app/modules/settings/custom_source/custom_source_browse_page.dart';
import 'package:simple_live_app/modules/settings/fnos/fn_os_browse_page.dart';

class CategoryPage extends GetView<CategoryController> {
  const CategoryPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // 自定义源 / 飞牛影视 增删后实时重建标签
      controller.tabVersion.value;
      final entries = buildBrowseTabEntries();
      return Scaffold(
        appBar: AppBar(
          titleSpacing: 8,
          title: TabBar(
            controller: controller.tabController,
            padding: EdgeInsets.zero,
            tabAlignment: TabAlignment.center,
            tabs: entries
                .map((e) => Tab(child: BrowseTabLabel(entry: e)))
                .toList(),
            labelPadding: AppStyle.edgeInsetsH20,
            isScrollable: true,
            indicatorSize: TabBarIndicatorSize.label,
          ),
        ),
        body: TabBarView(
          controller: controller.tabController,
          children: entries
              .map(
                (e) => BrowseTabContent(
                  entry: e,
                  siteBuilder: (siteId) => siteId.startsWith('fnos_')
                      ? FnOsBrowsePage(
                          server: FnOsService.instance.serverForSiteId(siteId)!,
                          embedded: true,
                        )
                      : siteId.startsWith('custom_')
                          ? CustomSourceBrowsePage(sourceId: siteId)
                          : CategoryListView(siteId),
                ),
              )
              .toList(),
        ),
      );
    });
  }
}
