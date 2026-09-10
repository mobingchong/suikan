import 'dart:async';

import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
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

  /// 跨页面探测结果缓存（id → 状态 / 抓取时刻）：同一房间 [_probeTtl] 内
  /// 不重复查询。TTL 取 5 分钟(小于默认 10 分钟刷新周期)，保证每个周期
  /// 都能实查一次；主要是挡住"反复进出页面/连续手动刷新"的重复请求。
  static final Map<String, int> _probeCache = <String, int>{};
  static final Map<String, DateTime> _probeCacheAt = <String, DateTime>{};
  static const Duration _probeTtl = Duration(minutes: 5);

  /// 每轮最多实查条数 + 条间隔（最小量拉取）。
  static const int _probeMaxPerRun = 10;
  static const Duration _probeGap = Duration(milliseconds: 400);

  /// 轮转游标：未关注房间多于每轮上限时，下一轮从上次结束处继续，
  /// 保证每轮都只发最多 [_probeMaxPerRun] 个请求、且最终覆盖全部。
  int _probeCursor = 0;

  /// 自动刷新定时器：周期**直接跟随设置里的「关注自动刷新间隔」**
  /// (AppSettingsController.autoUpdateFollowDuration，默认 10 分钟)，
  /// 设置改动即时重建；观看记录页打开期间才跑，页面销毁即停。
  Timer? _probeTimer;

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
    refreshData();
    super.onInit();
    // 列表首次非空（首次加载完成）后探测一次。
    ever<List<History>>(list, (_) {
      if (!_probed && list.isNotEmpty) {
        _probed = true;
        probeUnfollowedStatus();
      }
    });
    _startProbeTimer();
    // 设置里的「关注自动刷新」(开关 + 间隔)改动 → 观看记录同步生效。
    ever<int>(AppSettingsController.instance.autoUpdateFollowDuration, (_) {
      _startProbeTimer();
    });
    ever<bool>(AppSettingsController.instance.autoUpdateFollowEnable, (_) {
      _startProbeTimer();
    });
  }

  @override
  void onClose() {
    _probeTimer?.cancel();
    _probeTimer = null;
    super.onClose();
  }

  /// 与关注列表同一套设置：受「自动刷新关注」开关控制、
  /// 周期用「关注自动刷新间隔」(默认 10 分钟)。
  void _startProbeTimer() {
    _probeTimer?.cancel();
    _probeTimer = null;
    if (!AppSettingsController.instance.autoUpdateFollowEnable.value) {
      return; // 总开关关闭 → 观看记录也不自动查（仍可手动刷新）
    }
    var minutes =
        AppSettingsController.instance.autoUpdateFollowDuration.value;
    if (minutes < 1) {
      minutes = 10;
    }
    _probeTimer = Timer.periodic(Duration(minutes: minutes), (_) {
      if (isClosed) {
        return;
      }
      probeUnfollowedStatus();
    });
  }

  /// 手动刷新（页面"刷新"按钮）：列表重载后立即强制查一轮(忽略缓存)。
  @override
  Future<void> refreshData() async {
    await super.refreshData();
    probeUnfollowedStatus(force: true);
  }

  /// 对「未关注」的观看记录房间做一次轻量直播状态探测（最小量拉取）。
  ///
  /// 限流四闸门（保护平台风控，尤其 B站弹幕可用性）：
  /// 1. 跳过 B站/抖音（见 [_probeSkipSites]）；
  /// 2. 每轮最多查 [_probeMaxPerRun] 条、条间隔 [_probeGap]，游标轮转；
  /// 3. 结果 [_probeTtl] 内复用缓存（[force] 时忽略缓存）；
  /// 4. 定时周期跟随「关注自动刷新间隔」设置，页面销毁即停。
  Future<void> probeUnfollowedStatus({bool force = false}) async {
    if (_probing) return;
    _probing = true;
    try {
      final now = DateTime.now();
      final followIds = <String>{
        for (final f in FollowUserService.instance.allList) f.id,
      };
      // 候选 = 未关注 + 非风控平台 + 非影视，保序。
      final candidates = <History>[];
      for (final item in list) {
        if (followIds.contains(item.id)) continue;
        if (_probeSkipSites.contains(item.siteId)) continue;
        if (FnOsService.instance.serverForSiteId(item.siteId) != null) {
          continue;
        }
        candidates.add(item);
      }
      if (candidates.isEmpty) {
        return;
      }
      // 缓存回填（不 force 时）：所有在 TTL 内的直接回填,不占用本轮配额。
      final pending = <History>[];
      for (final item in candidates) {
        final cachedAt = _probeCacheAt[item.id];
        final fresh = cachedAt != null &&
            now.difference(cachedAt) < _probeTtl &&
            _probeCache.containsKey(item.id);
        if (!force && fresh) {
          extraLiveStatus[item.id] = _probeCache[item.id]!;
          continue;
        }
        pending.add(item);
      }
      if (pending.isEmpty) {
        return;
      }
      // 游标轮转：从上次结束处继续，每轮最多 _probeMaxPerRun 条。
      if (_probeCursor >= pending.length) {
        _probeCursor = 0;
      }
      final picked = <History>[];
      for (var i = 0; i < pending.length && picked.length < _probeMaxPerRun; i++) {
        picked.add(pending[(_probeCursor + i) % pending.length]);
      }
      _probeCursor = (_probeCursor + picked.length) % pending.length;
      var index = 0;
      for (final item in picked) {
        final site = Sites.siteForKey(item.siteId);
        if (site == null) continue;
        if (index > 0) {
          await Future.delayed(_probeGap);
        }
        index++;
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
    var result = await Utils.showAlertDialog("确定要删除此记录吗?", title: "删除记录");
    if (!result) {
      return;
    }
    await DBService.runExclusive(() => DBService.instance.historyBox.delete(DBService.safeBoxKey(item.id)));
    refreshData();
  }
}
