import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/sync_service.dart';

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

  /// 风控最敏感的平台：B站逐条状态查询极易把"接口级风控"升级成
  /// "真人验证(去网站验证)"，一旦升级连 B站弹幕 token(getDanmuInfo, WBI)
  /// 都拿不到 → 直播间没弹幕。这类平台不做观看记录状态探测，
  /// 状态只由关注列表(低频轮询)提供。抖音同理(444)。
  static const Set<String> _probeSkipSites = {
    Constant.kBiliBili,
    Constant.kDouyin,
    // 快手也跳过：它的状态查询要抓整页 HTML（几百 KB），观看记录一轮最多探 10 条，
    // 叠加关注列表轮询会把这条 IP 打成「请求过快」限流 —— 而快手下限流后连弹幕
    // 凭证（token/websocketUrls）都拿不到，代价远大于"观看记录显示实时状态"。
    Constant.kKuaishou,
  };

  /// 订阅关注列表「定时轮完成」事件的句柄。
  ///
  /// 🔴 2026-09-11 定案：**观看记录不再自建定时器**。全 App 只有关注列表
  /// 那一套定时器（分级变速 + 限流退避 + 受「自动刷新关注」开关控制），
  /// 它每跑完一轮就广播一次，观看记录收到后做一轮未关注房间状态探测。
  /// 这样两边的刷新节奏、限流退避、开关语义天然一致。
  StreamSubscription<void>? _autoRefreshSub;

  @override
  void onInit() {
    super.onInit();
    // 进页面立即探一次（**只 P2P**：吃局域网快照，未命中不发公网），
    // 保证一进页面就能看到"直播中"标签（前提是局域网里有端拉过）。
    // ⚠️ 不能只靠下面的 ever：list 在本页打开前若已有缓存（或首次先空后满），
    //    ever 可能错过首次时机，导致"进页面永远没有直播中标签"。
    // ⚠️ 2026-09-11 统一：与首页关注页同一个「进页刷新」开关
    //    （followRefreshOnEnter），关掉则本页进页也不自动探（下拉仍可手动刷）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isClosed) {
        return;
      }
      if (!AppSettingsController.instance.followRefreshOnEnter.value) {
        return;
      }
      _probed = true;
      probeUnfollowedStatus();
    });
    // 兜底：列表后续变为非空时再补一次（页面首次打开时 list 还空的情况）。
    ever<List<History>>(list, (_) {
      if (!_probed && list.isNotEmpty) {
        if (!AppSettingsController.instance.followRefreshOnEnter.value) {
          return;
        }
        _probed = true;
        probeUnfollowedStatus();
      }
    });
    // 跟随关注列表定时轮：它每跑完一轮就驱动这里探一次，不再自建定时器。
    _autoRefreshSub = FollowService.instance.autoRefreshTickStream.listen((_) {
      if (isClosed) {
        return;
      }
      probeUnfollowedStatus();
    });
    // 设置里的「关注自动刷新」开关关掉时 → 关注列表定时器也停，自然不再广播。
  }

  @override
  void onClose() {
    _autoRefreshSub?.cancel();
    _autoRefreshSub = null;
    super.onClose();
  }

  /// 手动刷新（下拉）：列表重载后立即强制查一轮(忽略缓存)。
  ///
  /// 🔴 手动 = 用户主动要最准的 → `peerOnly: false`（P2P 优先 + 未命中补公网）。
  /// 进页面/定时轮走默认 `peerOnly: true`（只 P2P）。
  @override
  Future<void> refreshData() async {
    await super.refreshData();
    probeUnfollowedStatus(force: true, peerOnly: false);
  }

  /// 对「未关注」的观看记录房间做一次轻量直播状态探测（最小量拉取）。
  ///
  /// 🔴 2026-09-12 定案：**进页面 / 定时轮 = 只 P2P**（[peerOnly] 默认 true）。
  /// 用户明确要求"打开观看记录只 P2P" —— 这是非用户主动行为，统一走局域网
  /// 快照，命中就回填，未命中保持原状态（不发公网）。理由与关注列表一致：
  /// 三个入口 × 多端叠加的自动请求是平台风控的主要来源。
  /// **手动下拉（[refreshData]）走 `peerOnly: false`** —— 用户主动要最准的，
  /// 保留"P2P 优先 + 未命中补公网"。
  ///
  /// 限流四闸门（仅 `peerOnly: false` 时用到，保护平台风控）：
  /// 1. 跳过 B站/抖音/快手（见 [_probeSkipSites]）；
  /// 2. 每轮最多查 [_probeMaxPerRun] 条、条间隔 [_probeGap]，游标轮转；
  /// 3. 结果 [_probeTtl] 内复用缓存（[force] 时忽略缓存）；
  /// 4. 定时周期跟随「关注自动刷新间隔」设置，页面销毁即停。
  Future<void> probeUnfollowedStatus({
    bool force = false,
    /// true（默认）= 只吃局域网快照，未命中不发公网。
    /// false = 手动入口：P2P 优先 + 未命中补公网。
    bool peerOnly = true,
  }) async {
    if (_probing) return;
    _probing = true;
    try {
      final now = DateTime.now();
      final followIds = <String>{
        for (final f in FollowService.instance.followList) f.id,
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
      // ① P2P 优先（所有入口统一）：先从局域网快照取，命中的直接回填、
      //    这条就不再发公网请求；未命中的进 `rest` 走下面的公网实查。
      //    快照门槛 3 分钟 —— 与关注列表定时轮同一口径（≤3 分钟内任一端
      //    拉过的状态就采用，超过则自己走公网）。
      if (Get.isRegistered<SyncService>()) {
        await SyncService.instance.queryPeersLiveStatus();
      }
      var hit = 0;
      final rest = <History>[];
      for (final item in pending) {
        final shared = SyncService.instance.sharedLiveStatus(
          item.id,
          ttl: SyncService.biliShareTtl,
        );
        if (shared != null) {
          _probeCache[item.id] = shared;
          _probeCacheAt[item.id] = now;
          extraLiveStatus[item.id] = shared;
          hit++;
        } else {
          rest.add(item);
        }
      }
      if (hit > 0) {
        Log.logPrint("观看记录状态：局域网快照命中 $hit 条（省下 $hit 个公网请求）");
      }
      // 🔴 2026-09-12：**进页面/定时轮只 P2P** —— 未命中部分不再补公网，
      // 保持上一轮状态即可（用户明确要求）。手动下拉才会走到下面补公网。
      //
      // ⚠️ 「全屋无生产者」死锁：若局域网里没有任何端跑过公网（都刚开机），
      // 快照必然全空 → 只 P2P 就永远没有"直播中"标签。本页不自建公网轮次，
      // 而是把这些**未关注**房间作为额外目标交给关注列表那套统一兜底
      // （同一 60s 冷却 + 同一 20 条额度，避免两个页面各打一轮公网）。
      // 兜底拿到后 publish 成本机快照，本页下轮即可命中。
      if (peerOnly) {
        if (hit == 0) {
          Log.logPrint("观看记录状态：仅 P2P，快照 0 命中 → 交给关注列表统一兜底");
          unawaited(FollowService.instance.refreshPeerOnly(
            fallbackLimit: FollowService.kPeerOnlyFallbackLimit,
            extraFallbackTargets: [
              for (final item in pending)
                (id: item.id, roomId: item.roomId, siteId: item.siteId),
            ],
          ));
        }
        return;
      }
      // ② 未命中部分补公网（保留原有风控四闸门：每轮 ≤10 条、400ms 间隔、
      //    游标轮转、5min 缓存），保证"直播中"标签能正常出现。
      pending
        ..clear()
        ..addAll(rest);
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
    await DBService.runExclusive(() => DBService.instance.historyBox.delete(DBService.safeBoxKey(item.id)));
    refreshData();
  }
}
