import 'dart:async';

import 'package:flutter/material.dart';

import 'package:get/get.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/widgets/browse_tabs.dart';
import 'package:simple_live_app/modules/category/category_list_controller.dart';

class CategoryController extends GetxController
    with GetSingleTickerProviderStateMixin {
  late TabController tabController;
  final tabVersion = 0.obs;
  StreamSubscription<dynamic>? streamSubscription;
  StreamSubscription<dynamic>? _customSub;
  StreamSubscription<dynamic>? _siteSub;

  CategoryController() {
    tabController =
        TabController(length: buildBrowseTabEntries().length, vsync: this);
  }

  @override
  void onInit() {
    streamSubscription = EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
      (index) {
        if (index == 2) {
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
      if (!Get.isRegistered<CategoryListController>(tag: site.id)) {
        Get.put(CategoryListController(site), tag: site.id);
      }
    }
  }

  void _rebuildTabs() {
    // ⚠️ 重建时保留当前 Tab，而不是跳回第 0 个：
    // 直播源刷新/影视库变更等事件都会走到这里，若硬回 index=0，用户在
    // 末尾的聚合 Tab（电视/影视）上点「刷新全部」会被直接弹回首个平台 Tab。
    final oldEntries = buildBrowseTabEntries();
    final oldLen = oldEntries.length;
    final oldIndex = oldLen == 0
        ? -1
        : tabController.index.clamp(0, oldLen - 1);
    final String? identity = oldIndex >= 0
        ? _entryIdentity(oldEntries[oldIndex])
        : null;

    final entries = buildBrowseTabEntries();
    final newLen = entries.length;
    var target = 0;
    if (identity != null) {
      // 源增删/折叠开关变化后按相同条目身份回到对应 Tab。
      for (var i = 0; i < newLen; i++) {
        if (_entryIdentity(entries[i]) == identity) {
          target = i;
          break;
        }
      }
    }
    target = target.clamp(0, newLen == 0 ? 0 : newLen - 1);

    final old = tabController;
    tabController = TabController(length: newLen, vsync: this);
    try {
      old.dispose();
    } catch (_) {}
    if (tabController.length > 0) {
      tabController.index = target;
    }
    _registerSiteControllers();
    tabVersion.value++;
  }

  /// Tab 条目身份：站点 id；聚合 tab 用 agg_live / agg_vod。
  static String? _entryIdentity(BrowseTabEntry e) {
    final siteId = e.siteId;
    if (siteId != null) return siteId;
    return 'agg_${e.aggregate}';
  }

  BrowseTabEntry? get currentEntry {
    final entries = buildBrowseTabEntries();
    final i = tabController.index;
    if (i < 0 || i >= entries.length) return null;
    return entries[i];
  }

  void refreshOrScrollTop() {
    final e = currentEntry;
    if (e == null || e.siteId == null) return;
    final siteId = e.siteId!;
    if (siteId.startsWith('custom_') || siteId.startsWith('fnos_')) return;
    final controller = Get.find<CategoryListController>(tag: siteId);
    controller.scrollToTopOrRefresh();
  }

  @override
  void onClose() {
    streamSubscription?.cancel();
    _customSub?.cancel();
    _siteSub?.cancel();
    super.onClose();
  }
}
