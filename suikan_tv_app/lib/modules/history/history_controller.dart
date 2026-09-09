import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/history.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:simple_live_tv_app/services/follow_user_service.dart';

class HistoryController extends BasePageController<History> {
  /// 未关注房间的直播状态探测结果（id=siteId_roomId → 0未知/1未播/2直播中）。
  /// 已关注的房间状态由 FollowUserService 轮询实时驱动，这里只管关注列表
  /// 覆盖不到的「只看过没关注」的房间。
  final RxMap<String, int> extraLiveStatus = <String, int>{}.obs;
  bool _probed = false;
  bool _probing = false;

  @override
  void onInit() {
    refreshData();
    super.onInit();
    // 列表首次非空（首次加载完成）后探测一次。
    ever<List<History>>(list, (_) {
      if (!_probed && list.isNotEmpty) {
        _probed = true;
        probeUnfollowedStatus();
      }
    });
  }

  /// 进入页面后对「未关注」的观看记录房间做一次轻量直播状态探测。
  ///
  /// 只查一次、串行、失败即弃：观看记录可能几十条，逐条打平台状态接口是
  /// 风控最敏感的动作，页面级一次性把请求量压到最小；状态变化靠重进页面
  /// （每次进入都会新建本 controller）重新探测。
  Future<void> probeUnfollowedStatus() async {
    if (_probing) return;
    _probing = true;
    try {
      final followIds = <String>{
        for (final f in FollowUserService.instance.allList) f.id,
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
    var result = await Utils.showAlertDialog("确定要删除此记录吗?", title: "删除记录");
    if (!result) {
      return;
    }
    await DBService.runExclusive(() => DBService.instance.historyBox.delete(DBService.safeBoxKey(item.id)));
    refreshData();
  }
}
