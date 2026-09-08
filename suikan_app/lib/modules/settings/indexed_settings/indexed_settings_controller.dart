import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/sites.dart';

class IndexedSettingsController extends GetxController {
  RxList<String> siteSort = RxList<String>();
  RxList<String> homeSort = RxList<String>();
  RxList<String> hiddenSites = RxList<String>();
  RxList<String> liveRoomTabSort = RxList<String>();
  RxList<String> liveRoomQuickAccessSort = RxList<String>();
  RxSet<String> liveRoomQuickAccessEnabled = <String>{}.obs;
  RxBool contributionRankEnable = false.obs;
  RxBool liveEventFlowEnable = false.obs;
  @override
  void onInit() {
    siteSort = AppSettingsController.instance.siteSort;
    homeSort = AppSettingsController.instance.homeSort;
    hiddenSites = AppSettingsController.instance.hiddenSites;
    liveRoomTabSort = AppSettingsController.instance.liveRoomTabSort;
    liveRoomQuickAccessSort =
        AppSettingsController.instance.liveRoomQuickAccessSort;
    liveRoomQuickAccessEnabled =
        AppSettingsController.instance.liveRoomQuickAccessEnabled;
    contributionRankEnable =
        AppSettingsController.instance.contributionRankEnable;
    liveEventFlowEnable = AppSettingsController.instance.liveEventFlowEnable;
    super.onInit();
  }

  /// 首页/分类完整平台顺序（内置 + 自定义源 + 影视库，含运行期新增）。
  RxList<String> get browseSiteOrder =>
      AppSettingsController.instance.browseSiteOrder;

  /// 设置页展示用的有效顺序（含新增源、剔除已删源）。
  List<String> get effectiveBrowseSiteOrder =>
      AppSettingsController.instance.effectiveBrowseSiteOrder;

  void updateSiteSort(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final effective = effectiveBrowseSiteOrder;
    final String item = effective.removeAt(oldIndex);
    effective.insert(newIndex, item);
    // ignore: invalid_use_of_protected_member
    AppSettingsController.instance.setBrowseSiteOrder(effective);
    EventBus.instance.emit(EventBus.kSiteSettingsChanged, null);
  }

  /// 切换平台隐藏状态。hidden=true 表示隐藏该平台。
  /// 返回是否成功（至少保留一个平台可见）。
  bool toggleHiddenSite(String id, bool hidden) {
    final current = [...hiddenSites];
    if (hidden && !current.contains(id)) {
      final visibleCount = Sites.allSites.length - current.length;
      if (visibleCount <= 1) return false;
    }
    AppSettingsController.instance.toggleHiddenSite(id, hidden);
    EventBus.instance.emit(EventBus.kSiteSettingsChanged, null);
    return true;
  }

  /// 聚合入口开关（电视/影视）切换后广播站点变更事件，让首页/分类立即重建 Tab。
  void setAggregateLiveEnable(bool enable) {
    AppSettingsController.instance.setAggregateLiveEnable(enable);
    EventBus.instance.emit(EventBus.kSiteSettingsChanged, null);
  }

  void setAggregateVodEnable(bool enable) {
    AppSettingsController.instance.setAggregateVodEnable(enable);
    EventBus.instance.emit(EventBus.kSiteSettingsChanged, null);
  }

  void updateHomeSort(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final String item = homeSort.removeAt(oldIndex);
    homeSort.insert(newIndex, item);
    // ignore: invalid_use_of_protected_member
    AppSettingsController.instance.setHomeSort(homeSort.value);
  }

  void updateLiveRoomTabSort(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final String item = liveRoomTabSort.removeAt(oldIndex);
    liveRoomTabSort.insert(newIndex, item);
    // ignore: invalid_use_of_protected_member
    AppSettingsController.instance.setLiveRoomTabSort(liveRoomTabSort.value);
  }

  void updateLiveRoomQuickAccessSort(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final String item = liveRoomQuickAccessSort.removeAt(oldIndex);
    liveRoomQuickAccessSort.insert(newIndex, item);
    AppSettingsController.instance.setLiveRoomQuickAccessSort(
      liveRoomQuickAccessSort.toList(),
    );
  }

  void setLiveRoomQuickAccessEnabled(String key, bool enabled) {
    AppSettingsController.instance.setLiveRoomQuickAccessEnabled(key, enabled);
  }

  void setContributionRankEnable(bool enabled) {
    AppSettingsController.instance.setContributionRankEnable(enabled);
  }

  void setLiveEventFlowEnable(bool enabled) {
    AppSettingsController.instance.setLiveEventFlowEnable(enabled);
  }
}
