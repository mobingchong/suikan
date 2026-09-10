import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
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

  /// 跨页面探测结果缓存（id → 状态 / 抓取时刻）：同一房间 15 分钟内不重复查询,
  /// 避免反复进出观看记录页把请求量堆到平台风控阈值上。
  static final Map<String, int> _probeCache = <String, int>{};
  static final Map<String, DateTime> _probeCacheAt = <String, DateTime>{};
  static const Duration _probeTtl = Duration(minutes: 15);
  static const int _probeMaxPerRun = 10;
  static const Duration _probeGap = Duration(milliseconds: 400);

  /// 风控最敏感的平台：B站逐条状态查询极易把"接口级风控"升级成
  /// "真人验证(去网站验证)"，一旦升级连 B站弹幕 token(getDanmuInfo, WBI)
  /// 都拿不到 → 直播间没弹幕。这类平台不做观看记录状态探测，
  /// 状态只由关注列表(低频轮询)提供。抖音同理(444)。
  static const Set<String> _probeSkipSites = {
    Constant.kBiliBili,
    Constant.kDouyin,
  };

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
  /// 限流三闸门（保护平台风控，尤其 B站弹幕可用性）：
  /// 1. 跳过 B站/抖音（见 [_probeSkipSites]）；
  /// 2. 每次最多查 [_probeMaxPerRun] 条、条间隔 [_probeGap]；
  /// 3. 结果 [_probeTtl] 内跨页面复用缓存。
  Future<void> probeUnfollowedStatus() async {
    if (_probing) return;
    _probing = true;
    try {
      final now = DateTime.now();
      final followIds = <String>{
        for (final f in FollowService.instance.followList) f.id,
      };
      var probed = 0;
      for (final item in list) {
        if (followIds.contains(item.id)) continue; // 关注列表覆盖
        // 风控敏感平台/影视（fnOS 库）跳过，不产生任何请求。
        if (_probeSkipSites.contains(item.siteId)) continue;
        if (FnOsService.instance.serverForSiteId(item.siteId) != null) {
          continue;
        }
        // 缓存命中（含上次探测结果）→ 直接回填，不发请求。
        final cachedAt = _probeCacheAt[item.id];
        if (cachedAt != null &&
            now.difference(cachedAt) < _probeTtl &&
            _probeCache.containsKey(item.id)) {
          extraLiveStatus[item.id] = _probeCache[item.id]!;
          continue;
        }
        if (probed >= _probeMaxPerRun) break;
        final site = Sites.siteForKey(item.siteId);
        if (site == null) continue;
        if (probed > 0) {
          await Future.delayed(_probeGap);
        }
        probed++;
        try {
          final living = await site.liveSite
              .getLiveStatus(roomId: item.roomId)
              .timeout(const Duration(seconds: 8));
          final status = living ? 2 : 1;
          _probeCache[item.id] = status;
          _probeCacheAt[item.id] = now;
          extraLiveStatus[item.id] = status;
        } catch (e) {
          // 风控/超时失败：短缓存(1 分钟内不再重试)，避免失败项反复重打。
          _probeCache[item.id] = 0;
          _probeCacheAt[item.id] = now.subtract(
            _probeTtl - const Duration(minutes: 1),
          );
          extraLiveStatus[item.id] = 0;
          Log.d("观看记录直播状态探测失败 ${item.siteId}/${item.roomId}: $e");
        }
      }
    } finally {
      _probing = false;
    }
  }

  @override
  Future<List<History>> getData(int page, int pageSize) async {
    if (page > 1) {
      return [];
    }
    final all = DBService.instance.getHistores();
    if (all.isEmpty) {
      return all;
    }
    // 自动清理"来源已移除"的记录(站点已删除/未注册)：直接删除并补位,
    // 避免列表里留下无法播放的空记录/占位。
    final keep = <History>[];
    for (final item in all) {
      final site = Sites.allSites[item.siteId] ??
          FnOsService.instance.siteForServer(item.siteId);
      if (site != null) {
        keep.add(item);
        continue;
      }
      await DBService.runExclusive(() => DBService.instance
          .historyBox.delete(DBService.safeBoxKey(item.id)));
    }
    return keep;
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
