import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';

class HistoryController extends BasePageController<History> {
  final RoomSelectionCallback? onRoomSelected;

  HistoryController({
    this.onRoomSelected,
  });

  /// 未关注房间的直播状态探测结果（id=siteId_roomId → 0未知/1未播/2直播中）。
  /// 只探测「观看过但不在关注列表」的房间：已关注的房间状态由关注列表
  /// 后台轮询实时驱动，这里只管关注列表覆盖不到的。
  final RxMap<String, int> extraLiveStatus = <String, int>{}.obs;
  bool _probed = false;
  bool _probing = false;

  @override
  void onInit() {
    super.onInit();
    // 列表首次非空（首次加载完成）后探测一次；refreshData 会先清空再赋值，
    // 但 _probed 保证一次页面生命周期只探测一次。
    ever<List<History>>(list, (_) {
      if (!_probed && list.isNotEmpty) {
        _probed = true;
        probeUnfollowedStatus();
      }
    });
  }

  /// 进入页面后对「未关注」的观看记录房间做一次轻量直播状态探测。
  ///
  /// 为什么只查一次、不用后台定时：观看记录可能几十条，逐条打平台状态接口
  /// 正是各平台风控最敏感的动作（抖音 444 / B 站限频都打这类接口）。页面级
  /// 一次性、串行、失败即弃，把请求量压到最小；状态变化靠重进页面/下拉刷新
  /// 重新探测。
  Future<void> probeUnfollowedStatus() async {
    if (_probing) return;
    _probing = true;
    try {
      final followIds = <String>{
        for (final f in FollowService.instance.followList) f.id,
      };
      for (final item in list) {
        if (followIds.contains(item.id)) continue; // 关注列表覆盖
        // 影视（fnOS 库）不是直播，没有开播状态概念，跳过。
        if (FnOsService.instance.serverForSiteId(item.siteId) != null) {
          continue;
        }
        if (extraLiveStatus.containsKey(item.id)) continue; // 已探测过
        final site = Sites.siteForKey(item.siteId);
        if (site == null) continue;
        try {
          final living = await site.liveSite
              .getLiveStatus(roomId: item.roomId)
              .timeout(const Duration(seconds: 8));
          extraLiveStatus[item.id] = living ? 2 : 1;
        } catch (e) {
          // 风控/超时/站点失效：保持未知，不重试，绝不影响列表展示。
          Log.d("观看记录直播状态探测失败 ${item.siteId}/${item.roomId}: $e");
          extraLiveStatus[item.id] = 0;
        }
      }
    } finally {
      _probing = false;
    }
  }

  @override
  Future<List<History>> getData(int page, int pageSize) {
    if (page > 1) {
      return Future.value([]);
    }
    return Future.value(DBService.instance.getHistores());
  }

  void clean() async {
    var result = await Utils.showAlertDialog("确定要清空观看记录吗?", title: "清空观看记录");
    if (!result) {
      return;
    }
    await DBService.runExclusive(() => DBService.instance.historyBox.clear());
    refreshData();
  }

  void removeItem(History item) async {
    await DBService.runExclusive(() => DBService.instance.historyBox.delete(DBService.safeBoxKey(item.id)));
    refreshData();
  }
}
