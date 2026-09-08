import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/widgets/browse_tabs.dart';
import 'package:simple_live_app/modules/home/home_list_controller.dart';
import 'package:simple_live_app/routes/route_path.dart';

class HomeController extends GetxController
    with GetSingleTickerProviderStateMixin {
  late TabController tabController;
  final tabVersion = 0.obs;
  StreamSubscription<dynamic>? streamSubscription;
  StreamSubscription<dynamic>? _customSub;
  StreamSubscription<dynamic>? _siteSub;

  HomeController() {
    tabController =
        TabController(length: buildBrowseTabEntries().length, vsync: this);
  }

  @override
  void onInit() {
    streamSubscription = EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
      (index) {
        if (index == 0) {
          refreshOrScrollTop();
        }
      },
    );
    _registerSiteControllers();
    _customSub = EventBus.instance.listen(
      EventBus.kCustomSourcesChanged,
      (_) => _rebuildTabs(),
    );
    _siteSub = EventBus.instance.listen(
      EventBus.kSiteSettingsChanged,
      (_) => _rebuildTabs(),
    );
    super.onInit();
  }

  void _registerSiteControllers() {
    for (var site in Sites.browseSites) {
      if (site.id.startsWith('custom_') || site.id.startsWith('fnos_')) {
        continue;
      }
      if (!Get.isRegistered<HomeListController>(tag: site.id)) {
        Get.put(HomeListController(site), tag: site.id);
      }
    }
  }

  void _rebuildTabs() {
    // 先创建新控制器再释放旧的，避免视图在重建期间引用到已 dispose 的控制器
    // （release 模式下会表现为整页空白）。
    final old = tabController;
    tabController =
        TabController(length: buildBrowseTabEntries().length, vsync: this);
    try {
      old.dispose();
    } catch (_) {}
    if (tabController.length > 0) {
      tabController.index = 0;
    }
    _registerSiteControllers();
    tabVersion.value++;
  }

  /// 当前 tab 的条目（聚合/站点通用）。
  BrowseTabEntry? get currentEntry {
    final entries = buildBrowseTabEntries();
    final i = tabController.index;
    if (i < 0 || i >= entries.length) return null;
    return entries[i];
  }

  void refreshOrScrollTop() {
    final e = currentEntry;
    if (e == null || e.siteId == null) return; // 聚合 tab 无滚动列表
    final siteId = e.siteId!;
    if (siteId.startsWith('custom_') || siteId.startsWith('fnos_')) return;
    final controller = Get.find<HomeListController>(tag: siteId);
    controller.scrollToTopOrRefresh();
  }

  void toSearch() {
    final e = currentEntry;
    if (e == null || e.siteId == null) return;
    Get.toNamed(
      RoutePath.kSearch,
      arguments: {"siteId": e.siteId!},
    );
  }

  @override
  void onClose() {
    streamSubscription?.cancel();
    _customSub?.cancel();
    _siteSub?.cancel();
    super.onClose();
  }
}
