import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/bulk_data_import_service.dart';
import 'package:simple_live_app/services/current_room_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/live_notification_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class FollowService extends GetxService with WidgetsBindingObserver {
  /// 关注列表「补封面/画面帧」的节流间隔。
  ///
  /// 对齐平台截图自身的更新节奏（几十秒~几分钟一帧），既能看到较新的
  /// 画面，又不会在连续切分组/翻页时对同一批开播主播反复拉详情。
  static const Duration kPreviewRefreshInterval = Duration(minutes: 3);

  /// 关注刷新链路的「房间详情」请求门控（思路参照 bililive-go 的
  /// WrappedLive：缓存 + 平台级限流 + 请求合并）。
  ///
  /// 关注列表里拉详情只为三件事：抖音身份同步、非抖音开播的已播时长、
  /// 以及开封面时的画面帧。这些都不要求“立刻”，但却是各平台风控最敏感
  /// 的重接口（抖音 444 就打在这里）。此前连续切分组/翻页时，同一批开播
  /// 主播会被反复拉详情，形成短时间内的突发请求。
  ///
  /// 门控做两件事（都只作用于关注刷新，**不影响进房解析**，后者由
  /// controller 直接请求站点、需要最新结果）：
  /// ① 同一房间短时间内的重复/并发请求合并为一次真实请求；
  /// ② 同一平台两次详情之间保持最小间隔，削掉突发尖峰。
  final _RoomDetailGate _detailGate = _RoomDetailGate();

  static const Duration updateStatusCooldown = Duration(seconds: 30);
  static const Duration refreshProgressCompletionHold = Duration(seconds: 2);
  static const int kDouyinLimitedAutoResumeMaxAttempts = 2;
  static const Duration kDouyinLimitedAutoResumeBaseDelay = Duration(
    seconds: 45,
  );
  static const int kFollowProgressUiBurstThreshold = 500;
  static const String _refreshTaskStateStorageKey =
      LocalStorageService.kFollowRefreshTaskState;
  static const String _refreshTaskTargetsStorageKey =
      LocalStorageService.kFollowRefreshTaskTargets;
  StreamSubscription<dynamic>? subscription;
  static FollowService get instance => Get.find<FollowService>();
  Timer? _eventReloadTimer;

  final StreamController _updatedListController = StreamController.broadcast();
  Stream get updatedListStream => _updatedListController.stream;
  final Set<String> _previewRefreshingKeys = <String>{};

  /// 关注用户列表
  RxList<FollowUser> followList = RxList<FollowUser>();

  /// 直播中的用户列表
  RxList<FollowUser> liveList = RxList<FollowUser>();

  /// 未直播的用户列表
  RxList<FollowUser> notLiveList = RxList<FollowUser>();

  /// 用户自定义的tag
  RxList<FollowUserTag> followTagList = RxList<FollowUserTag>();

  /// 当前tag的用户列表
  RxList<FollowUser> curTagFollowList = RxList<FollowUser>();

  /// 是否正在更新
  var updating = false.obs;
  var refreshProgress = const FollowRefreshProgress.idle().obs;

  Timer? updateTimer;
  /// 首次轮询的随机抖动定时器（多端错开，见 [initTimer]）。
  Timer? _biliJitterTimer;

  /// 🔴 周期基准修正（2026-09-12）：本轮自动刷新的**开始**时刻。
  /// 排下一轮时用「interval − 本轮耗时」，让真实周期稳定在设定值上；
  /// 否则"跑 2 分钟 + 等 60s"会让 60s 档实际变成 ~3 分钟一轮。
  DateTime? _autoRefreshRunStartedAt;

  /// 是否处于后台（退后台已停表）。回前台据此决定补轮/续排。
  bool _appInBackground = false;

  /// 退后台的时刻（回前台算停表时长）。
  DateTime? _backgroundedAt;

  /// 最近一次撞平台限流（如抖音 444）的时刻：用于自动刷新退避降频。
  DateTime? _lastPlatformLimitedAt;

  /// 本轮已由「B站 批量状态接口」覆盖的房间（见 [_prefetchBiliStatusBatch]）：
  /// 这些房间本轮不再逐条单查，避免重复请求。
  final Set<String> _biliBatchCovered = <String>{};

  /// 持久化 roomId → 主播 uid 映射的设置键（有 uid 才能走批量接口）。
  static const String _kBiliAnchorUids = "BiliAnchorUids";
  Timer? _refreshProgressResetTimer;
  final Set<String> _liveNotifySentIds = <String>{};
  final Set<String> _liveNotifyReadyIds = <String>{};
  int _updateGeneration = 0;
  DateTime? _lastUpdateStatusStartedAt;

  @override
  void onInit() {
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (p0) {
      _eventReloadTimer?.cancel();
      _eventReloadTimer = Timer(const Duration(milliseconds: 150), () {
        loadData(updateStatus: false);
      });
    });
    _initializeLiveNotificationBaselines();
    if ((Platform.isAndroid || Platform.isIOS) &&
        DBService.instance
            .getFollowList()
            .any((item) => item.isSpecialFollow)) {
      // Ask while the app is available so background/queued refreshes can
      // post a notification without waiting for the next room visit.
      unawaited(LiveNotificationService.requestPermissionIfNeeded());
    }
    // 恢复上次学到的 B站 roomId→uid 映射：有 uid 就能用批量状态接口
    // 一次查完所有 B站 关注（否则每轮首刷只能逐条单查学 uid）。
    _restoreBiliUids();
    // 🔴 2026-09-12：退后台暂停关注定时轮（见 [didChangeAppLifecycleState]）。
    // 必须在 initTimer 之前注册，否则后台事件可能早于首次排期到达。
    WidgetsBinding.instance.addObserver(this);
    initTimer();
    // 局域网共享状态回写：其它端（如 TV）刚拉到的状态，本端拿到后立即更新
    // 列表显示，不用等本端 10 分钟轮询，也不产生任何公网请求。
    _registerPeerStatusCallback();
    _scheduleStartupStatusRefresh();
    super.onInit();
  }

  /// 启动后补一轮关注状态（仅在「自动刷新关注」开启时）。
  ///
  /// 🔴 2026-09-11 定案：**启动补轮只走局域网（P2P）**，不发公网请求。
  /// 理由：这是"打开 App 顺手刷一下"的非用户主动行为，多端同 IP 叠加起来
  /// 是平台风控的重要来源。状态由局域网内其它端（TV 常开）共享过来；
  /// 局域网只有本机、或所有端都没拉过时，保持 DB 里的旧状态，等用户手动下拉。
  void _scheduleStartupStatusRefresh() {
    Timer(const Duration(seconds: 6), () {
      if (isClosed) {
        return;
      }
      if (!AppSettingsController.instance.autoUpdateFollowEnable.value) {
        return; // 用户关了自动刷新 → 不自动刷（仍可手动下拉）
      }
      Log.logPrint("启动后补一轮关注状态（仅局域网快照，无生产者时前 20 条兜底公网）");
      unawaited(refreshPeerOnly(fallbackLimit: kPeerOnlyFallbackLimit));
    });
  }

  /// 只吃局域网共享快照刷新关注状态（启动补轮 / 进页面 / 直播间关注面板 /
  /// 观看记录探测共用）。
  ///
  /// 先主动问一次局域网各端（`queryPeersLiveStatus`），把最新快照收进来，
  /// 再无条件「仅局域网」走一轮 status（peerOnly=true：无快照的项直接跳过）。
  ///
  /// 🔴 2026-09-12 **死锁修复 —— 加"生产者也缺席"兜底**：
  /// 纯 P2P 有个前提：局域网里**必须有一台端在跑定时轮当生产者**（快照的唯一
  /// 生产者是"真实发过公网"的那一端）。若全屋没有任何端拉过公网（例如
  /// WIN + 手机都刚打开、TV 没开），快照表就是**全空**的 → 每个端进页面都
  /// 只当消费者 → 谁也拿不到数据 → 表现为"进页面 2-3 分钟状态纹丝不动"
  /// （用户实测）。
  ///
  /// 因此：**快照一条都没命中时**，允许对 [fallbackLimit] 条走一次公网
  /// （受原有平台节流与风控闸门约束），拿到后本端立刻 `publishLiveStatusItem`
  /// 成为生产者，其它端下次查询即可白拿 → 形成正循环。
  /// 命中快照时行为不变（一个公网请求都不发）。
  /// 上一次"快照全空 → 公网兜底"发生的时刻（60s 内不重复兜底）。
  DateTime? _lastPeerFallbackAt;

  /// 「全屋无生产者」时，一次兜底最多放行多少条走公网。
  /// 20 条 ≈ 覆盖一屏可见范围，既能让用户"进页面立即可见"，又不至于把
  /// 整个关注列表（可能几百条）打一遍。
  static const int kPeerOnlyFallbackLimit = 20;

  Future<void> refreshPeerOnly({
    /// 快照全空时的公网兜底条数上限（0 = 不兜底，保持纯 P2P）。
    /// 只对列表**最前面**这么多条兜底，避免把整个关注列表打一遍。
    int fallbackLimit = 0,

    /// 额外的兜底目标（`(roomKey, roomId, siteId)`）。
    ///
    /// 🔴 2026-09-12：观看记录页里**未关注**的房间不在 `followList` 里，
    /// 而它现在也只走 P2P → 全屋无生产者时那些房间永远拿不到状态。
    /// 由观看记录页把候选传进来，走同一套兜底闸门（同样 60s 冷却、同样
    /// 计入 `fallbackLimit` 总额度），避免两个页面各自发一轮公网。
    List<({String id, String roomId, String siteId})> extraFallbackTargets =
        const [],
  }) async {
    if (Get.isRegistered<SyncService>()) {
      await SyncService.instance.queryPeersLiveStatus();
    }
    if (isClosed || (followList.isEmpty && extraFallbackTargets.isEmpty)) {
      return;
    }
    // 快照命中情况：全空才需要兜底（有一条命中说明局域网有生产者在跑）。
    // 额外目标也要看快照：它们命中就不必占兜底额度。
    final hasAnySnapshot = followList.any(
              (item) => SyncService.instance.sharedLiveStatus(item.id) != null,
            ) ||
        extraFallbackTargets.any(
          (t) => SyncService.instance.sharedLiveStatus(t.id) != null,
        );
    // 兜底还要过 60s 闸门：进页面/进面板/换台这些入口可能连续触发，
    // 不闸门就会每次都打一轮公网（尤其在"全屋真的没有生产者"时）。
    final now = DateTime.now();
    final lastFallback = _lastPeerFallbackAt;
    final fallbackCooledDown = lastFallback == null ||
        now.difference(lastFallback) >= const Duration(seconds: 60);
    final useFallback =
        !hasAnySnapshot && fallbackLimit > 0 && fallbackCooledDown;
    if (useFallback) {
      _lastPeerFallbackAt = now;
      Log.logPrint(
        "局域网快照全空（无生产者在跑）→ 对前 $fallbackLimit 条走公网兜底"
        "（关注 ${followList.length} + 额外 ${extraFallbackTargets.length}）",
      );
    } else if (!hasAnySnapshot && fallbackLimit > 0) {
      Log.logPrint("局域网快照全空，但兜底仍在 60s 冷却内 → 本轮跳过公网");
    }
    if (followList.isNotEmpty) {
      await refreshSelectedStatus(
        followList,
        includeAllNormals: true,
        force: false,
        scope: const FollowRefreshScope.all(automatic: true),
        allowDetailRefresh: false,
        statusOnly: true,
        silent: true,
        // 兜底时不传 peerOnly：让 worker 在没有快照时回退到公网单查。
        peerOnly: !useFallback,
        /// 兜底模式下只允许列表前 N 条走公网，其余仍保留旧状态（不发请求）。
        networkFallbackLimit: useFallback ? fallbackLimit : 0,
      );
    }
    // 额外目标（观看记录的未关注房间）：同样受 60s 冷却 + 条数额度约束。
    if (useFallback && extraFallbackTargets.isNotEmpty) {
      await _probeExtraFallbackTargets(extraFallbackTargets);
    }
  }

  /// 对「额外兜底目标」（当前仅观看记录的未关注房间）逐条发公网查状态，
  /// 查到后 publish 成本机快照，供其它端与本机观看记录页取用。
  ///
  /// 条数上限 = [kPeerOnlyFallbackLimit]，与关注列表共用同一份额度语义
  /// （调用方已在 `useFallback` 成立时才进来，即已过 60s 冷却）。
  Future<void> _probeExtraFallbackTargets(
    List<({String id, String roomId, String siteId})> targets,
  ) async {
    var done = 0;
    for (final t in targets) {
      if (isClosed || done >= kPeerOnlyFallbackLimit) {
        break;
      }
      // 已有新鲜快照（本机或刚收的对端）→ 跳过，省一个请求。
      if (SyncService.instance.sharedLiveStatus(t.id) != null) {
        continue;
      }
      final site = Sites.siteForKey(t.siteId);
      if (site == null) {
        continue;
      }
      if (done > 0) {
        await Future.delayed(const Duration(milliseconds: 400));
      }
      done++;
      try {
        final living = await site.liveSite
            .getLiveStatus(roomId: t.roomId)
            .timeout(const Duration(seconds: 8));
        SyncService.instance.publishLiveStatusItem(t.id, living ? 2 : 1);
      } catch (e) {
        Log.d("观看记录兜底探测失败 ${t.siteId}/${t.roomId}: $e");
      }
    }
    if (done > 0) {
      Log.logPrint("观看记录额外兜底：已查 $done 条并发成本机快照");
    }
  }

  /// 注册「拿到其它端快照 → 立即回写列表」的回调。
  ///
  /// ⚠️ main.dart 里 `Get.put(SyncService())` **晚于** `Get.put(FollowService())`，
  /// 所以 onInit 时 SyncService 往往还没注册 —— 旧实现直接 `Get.isRegistered`
  /// 判断就会静默跳过注册，表现为"局域网共享到了但列表不更新"。这里做有限次
  /// 延时重试（≈3s）兜住注册顺序；桌面副实例不开 SyncService，重试自然结束。
  void _registerPeerStatusCallback({int attempt = 0}) {
    if (isClosed) {
      return;
    }
    if (Get.isRegistered<SyncService>()) {
      SyncService.instance.onPeerLiveStatus = _applySharedLiveStatus;
      // 启动时主动问一次（SyncService 内部另有 1–3s 首次查询兜底）。
      unawaited(SyncService.instance.queryPeersLiveStatus());
      return;
    }
    if (attempt >= 12) {
      return; // ≈3s 内仍未注册（如桌面副实例），放弃（不影响任何功能）
    }
    Future.delayed(const Duration(milliseconds: 250), () {
      _registerPeerStatusCallback(attempt: attempt + 1);
    });
  }

  /// 应用局域网共享的直播状态到关注列表（全平台通用、纯内存、零公网请求）。
  void _applySharedLiveStatus(Map<String, int> items) {
    if (items.isEmpty || followList.isEmpty) {
      return;
    }
    var changed = false;
    for (final item in followList) {
      final status = items[item.id];
      if (status == null || item.liveStatus.value == status) {
        continue;
      }
      item.liveStatus.value = status;
      if (status != 2) {
        item.liveStartTime = null;
        _liveNotifySentIds.remove(item.id);
      }
      changed = true;
    }
    if (changed) {
      filterData();
    }
  }

  void _initializeLiveNotificationBaselines() {
    for (final item in DBService.instance.getFollowList()) {
      if (!item.isSpecialFollow) {
        continue;
      }
      _liveNotifyReadyIds.add(item.id);
      if (item.liveStatus.value == 2) {
        _liveNotifySentIds.add(item.id);
      }
    }
  }

  // 添加标签
  Future<void> addFollowUserTag(String tag) async {
    // 判断待添加tag是否已存在，存在则return
    if (followTagList.any((item) => item.tag == tag)) {
      SmartDialog.showToast("标签名重复，修改失败");
      return;
    }
    FollowUserTag item = await DBService.instance.addFollowTag(tag);
    followTagList.add(item);
  }

  // 删除标签
  Future<void> delFollowUserTag(FollowUserTag tag) async {
    followTagList.remove(tag);
    await DBService.instance.deleteFollowTag(tag.id);
  }

  // 获取用户自定义标签列表
  void getAllTagList() {
    var list = DBService.instance.getFollowTagList();
    followTagList.assignAll(list);
  }

  // 修改标签
  void updateFollowUserTag(FollowUserTag tag) {
    DBService.instance.updateFollowTag(tag);
    // 查找并修改
    var index = followTagList.indexWhere((oTag) => oTag.id == tag.id);
    followTagList[index] = tag;
  }

  // 根据标签筛选数据
  void filterDataByTag(FollowUserTag tag) {
    curTagFollowList.clear();
    // 用一个新的列表来存储需要删除的 userId
    List<String> toRemove = [];
    for (var id in tag.userId) {
      if (followList.any((x) => x.id == id)) {
        // 找到对应的 followUser 添加到 curTagFollowList
        curTagFollowList.add(followList.firstWhere((x) => x.id == id));
      } else {
        // 标记要删除的 id
        toRemove.add(id);
      }
    }
    // 双向确认用户取消关注后标签内是否还有该用户
    // 在遍历结束后统一移除不在 followList 中的 id
    tag.userId.removeWhere((id) => toRemove.contains(id));
    // 更新数据库
    if (toRemove.isNotEmpty) {
      DBService.instance.updateFollowTag(tag);
    }
    curTagFollowList.assignAll(sortFollowUsers(curTagFollowList));
  }

  // 添加关注
  Future<void> addFollow(FollowUser follow) async {
    await DBService.instance.addFollow(follow);
  }

  /// 进直播间后把最新标题（以及可选封面、**开播状态**）回写到关注项。
  ///
  /// 背景：主播改标题是高频操作，而关注列表的标题只在“补详情”链路更新；
  /// 非抖音平台的定时/进页刷新只取开播时间不写标题，手动刷新又是纯状态轮，
  /// 于是列表里的标题会长期停留在关注时的旧值。
  ///
  /// 🔴 2026-09-12 新增 [isLiving]：进房已经**真实拉到详情**（最权威的状态来源），
  /// 顺手把状态回写关注列表 + 覆盖本机 P2P 快照。此前只同步标题/封面，
  /// 导致"点进去是未开播、退出来又被旧快照盖回直播中"的顽固不一致。
  void syncFollowRoomMeta({
    required String siteId,
    required String roomId,
    required String title,
    String cover = "",
    String? altRoomId,
    bool? isLiving,
  }) {
    final newTitle = title.trim();
    if (newTitle.isEmpty) return;
    FollowUser? target;
    // 优先按进房用的 roomId 匹配；匹配不到再试详情返回的真实房间号
    // （抖音迁移 roomId、短号转长号时两者不同）。
    for (final item in followList) {
      if (item.siteId == siteId && item.roomId == roomId) {
        target = item;
        break;
      }
    }
    final alt = altRoomId?.trim() ?? "";
    if (target == null && alt.isNotEmpty && alt != roomId) {
      for (final item in followList) {
        if (item.siteId == siteId && item.roomId == alt) {
          target = item;
          break;
        }
      }
    }
    if (target == null) return; // 没关注，不同步

    // 🔴 状态回写（2026-09-12）：进房拿到的 status 是最权威的真值。
    // 放在标题判断**之前**：标题没变但状态变了（常见于"关播后重进"）也要回写。
    // 同时覆盖本机 P2P 快照，避免旧快照把自己的真值又盖回去。
    if (isLiving != null) {
      final newStatus = isLiving ? 2 : 1;
      if (target.liveStatus.value != newStatus) {
        target.liveStatus.value = newStatus;
        if (!isLiving) {
          target.liveStartTime = null;
          _liveNotifySentIds.remove(target.id);
        }
      }
      SyncService.instance.publishLiveStatusItem(target.id, newStatus);
      if (!_updatedListController.isClosed) {
        _updatedListController.add(null);
      }
    }

    var changed = false;
    if (target.roomTitle != newTitle) {
      target.roomTitle = newTitle;
      changed = true;
    }
    final newCover = cover.trim();
    if (newCover.isNotEmpty &&
        AppSettingsController.instance.followShowLiveCover.value &&
        target.roomCover != newCover) {
      target.roomCover = newCover;
      target.previewUpdatedAt = DateTime.now();
      changed = true;
    }
    if (!changed) return;
    unawaited(DBService.instance.addFollow(target));
    if (!_updatedListController.isClosed) {
      _updatedListController.add(null);
    }
  }

  Future<void> updateSpecialFollow(FollowUser follow, bool value) async {
    follow.isSpecialFollow = value;
    if (value) {
      await LiveNotificationService.requestPermissionIfNeeded();
      if (follow.liveStatus.value != 0) {
        _liveNotifyReadyIds.add(follow.id);
      }
      if (follow.liveStatus.value == 2) {
        _liveNotifySentIds.add(follow.id);
      }
    } else {
      _liveNotifySentIds.remove(follow.id);
    }
    await DBService.instance.addFollow(follow);
    filterData();
  }

  void initTimer() {
    _biliJitterTimer?.cancel();
    updateTimer?.cancel();
    updateTimer = null;
    if (isClosed ||
        _appInBackground ||
        !AppSettingsController.instance.autoUpdateFollowEnable.value) {
      return;
    }
    // 首次启动加 0–30s 随机抖动（多端错开），之后按"分级变速"排期。
    // 抖动期也算作"本轮耗时"的起点，避免首轮多等一整个 interval。
    _autoRefreshRunStartedAt = DateTime.now();
    _biliJitterTimer = Timer(
      Duration(seconds: math.Random().nextInt(30)),
      _scheduleNextAutoRefresh,
    );
  }

  /// 下次自动刷新间隔（分级变速 + 限流退避）：
  /// - 有房间正在直播 → 基准的 1/5（≥60s）：尽快捕捉"下播/换场"；
  /// - 全部未开播 → 基准（设置值，默认 10 分钟）：省请求；
  /// - 最近 5 分钟撞过平台限流 → 间隔 ×3（上限 30 分钟）：风控期自动降频。
  Duration _nextAutoRefreshInterval() {
    var base = AppSettingsController.instance.autoUpdateFollowDuration.value;
    if (base < 1) {
      base = 10;
    }
    final liveCount = followList.where((e) => e.liveStatus.value == 2).length;
    var interval = liveCount > 0
        ? Duration(seconds: math.max(60, (base * 60 / 5).round()))
        : Duration(minutes: base);
    final limitedAt = _lastPlatformLimitedAt;
    if (limitedAt != null &&
        DateTime.now().difference(limitedAt) < const Duration(minutes: 5)) {
      final backedOff = interval * 3;
      interval = backedOff > const Duration(minutes: 30)
          ? const Duration(minutes: 30)
          : backedOff;
    }
    return interval;
  }

  /// 排下一轮自动刷新（**从本轮开始时刻计时，扣掉本轮耗时**）。
  ///
  /// 🔴 2026-09-12 周期基准修正：旧实现是"本轮**跑完**再等一个完整 interval"，
  /// 刷几百个关注耗时 2 分钟时，60s 档的实际周期会变成 ~3 分钟（累积漂移）。
  /// 现在改为：`下次等待 = interval − 本轮耗时`，真实周期稳定贴合设定值。
  /// 耗时已超 interval → 用 [_kMinAutoRefreshGap] 做最小时距保底，
  /// 既不空转也不把请求打成一串连发。
  ///
  /// 退后台时（[_appInBackground]）直接不排期 —— 回前台由
  /// [didChangeAppLifecycleState] 统一续排/补轮，避免停表期间时间白算。
  void _scheduleNextAutoRefresh() {
    updateTimer?.cancel();
    updateTimer = null;
    if (isClosed ||
        _appInBackground ||
        !AppSettingsController.instance.autoUpdateFollowEnable.value) {
      return;
    }
    final interval = _nextAutoRefreshInterval();
    // 从「本轮开始」起算 → 扣掉本轮已耗时。
    final startedAt = _autoRefreshRunStartedAt;
    var wait = interval;
    if (startedAt != null) {
      final elapsed = DateTime.now().difference(startedAt);
      final remaining = interval - elapsed;
      wait = remaining > _kMinAutoRefreshGap ? remaining : _kMinAutoRefreshGap;
    }
    Log.logPrint(
      "下次关注自动刷新：${wait.inSeconds}s"
      "（interval=${interval.inSeconds}s，本轮已耗时=${startedAt == null ? 0 : DateTime.now().difference(startedAt).inSeconds}s）",
    );
    updateTimer = Timer(wait, () async {
      if (isClosed || _appInBackground) {
        return; // 等表期间退后台了 → 不刷，交回前台续排
      }
      _autoRefreshRunStartedAt = DateTime.now();
      // 定时自动刷新：用户没主动发起 → 静默（不弹进度条）
      await loadData(silent: true);
      // 🔴 2026-09-11 定案：**观看记录页不再自建定时器**，由这里统一驱动。
      // 关注列表定时轮跑完 → 通知观看记录页做一轮「P2P 优先 + 未命中补公网」
      // 的未关注房间状态探测。全 App 只有这一套定时器，周期/限流退避/开关
      // 全部一致（此前观看记录另有一套固定周期的 _probeTimer，两套节奏不同
      // 导致行为不一致）。
      _fireAutoRefreshTick();
      _scheduleNextAutoRefresh();
    });
  }

  /// 自动刷新两轮之间的最小时距（本轮耗时超过 interval 时的保底）。
  static const Duration _kMinAutoRefreshGap = Duration(seconds: 10);

  /// 定时轮「跑完一轮」的广播（观看记录页订阅它来驱动自己的状态探测）。
  final StreamController<void> _autoRefreshTickController =
      StreamController<void>.broadcast();

  /// 订阅「关注定时轮完成」事件（观看记录页用）。
  Stream<void> get autoRefreshTickStream => _autoRefreshTickController.stream;

  void _fireAutoRefreshTick() {
    if (!_autoRefreshTickController.isClosed) {
      _autoRefreshTickController.add(null);
    }
  }

  Future<void> loadData({
    bool updateStatus = true,
    bool forceUpdateStatus = false,
    /// true = 后台静默刷新：**不显示顶部进度条**（用于"打开 APP 自动补一轮"
    /// 这类用户没主动发起的刷新）。
    bool silent = false,
  }) async {
    var list = DBService.instance.getFollowList();
    getAllTagList();
    if (list.isEmpty) {
      updating.value = false;
      _resetRefreshProgress();
      followList.assignAll(list);
      return;
    }
    followList.assignAll(list);
    if (updateStatus) {
      unawaited(startUpdateStatus(
        force: forceUpdateStatus,
        statusOnly: forceUpdateStatus,
        silent: silent,
      ));
    }
  }

  /// 手动刷新（直播间关注列表下拉 / 桌面刷新按钮）。
  ///
  /// 语义与关注页 `refreshData(forceStatus: true)` **完全一致**。2026-09-11
  /// 定案：**手动刷新同时拉公网与局域网（两条腿都要）**：
  /// - 先 `queryPeersLiveStatus()` 把局域网各端最新快照收进来 → P2P 这一路；
  /// - 再 `force: true` 真实拉一遍状态 → 公网这一路（绕过 30s 冷却）。
  ///   快照命中的项，worker 内会用快照值覆盖（见 `_updateLiveStatus` 中
  ///   `shared != null` 分支），因此**哪边新用哪边**，不会互相拖累。
  ///
  /// 与 [loadData] 的关键差别是**返回真实完成 Future**（[loadData] 内部对
  /// startUpdateStatus 用的是 unawaited），这样 RefreshIndicator 的转圈能
  /// 与实际刷新进度关联，不会"下拉一闪就收、看着像没刷新"。
  Future<void> refreshManual() async {
    // 先同步 DB → 内存（别处可能刚增删过关注），再收 P2P 快照。
    await loadData(updateStatus: false);
    if (Get.isRegistered<SyncService>()) {
      unawaited(SyncService.instance.queryPeersLiveStatus());
    }
    await startUpdateStatus(force: true, statusOnly: true, silent: false);
  }

  /// 获取关注刷新并发数。
  /// 0 = 自动，自动最多 4；手动 1-8 直接生效。
  int getOptimalConcurrency({
    int? totalCount,
  }) {
    final count = totalCount ?? followList.length;
    if (count <= 0) {
      return 1;
    }
    final manual =
        AppSettingsController.instance.effectiveUpdateFollowThreadCount;
    if (manual > 0) {
      return manual.clamp(1, count).toInt();
    }
    var concurrency = 2;
    if (count <= 50) {
      concurrency = count < 2 ? count : 2;
    } else if (count <= 200) {
      concurrency = 3;
    } else {
      concurrency = 4;
    }
    return concurrency.clamp(1, count).toInt();
  }

  String _getConcurrencyMode() {
    final manual =
        AppSettingsController.instance.effectiveUpdateFollowThreadCount;
    return manual > 0 ? "手动($manual)" : "自动";
  }

  /// 按平台交错排列，避免单一平台阻塞
  List<FollowUser> interleaveByPlatform(List<FollowUser> list) {
    // 按平台分组
    var grouped = <String, Queue<FollowUser>>{};
    for (var item in list) {
      grouped.putIfAbsent(item.siteId, () => Queue<FollowUser>()).add(item);
    }

    // 交错处理
    var result = <FollowUser>[];
    while (grouped.values.any((queue) => queue.isNotEmpty)) {
      for (var queue in grouped.values) {
        if (queue.isNotEmpty) {
          result.add(queue.removeFirst());
        }
      }
    }

    return result;
  }

  List<FollowUser> deprioritizeCurrentRoom(List<FollowUser> items) {
    final currentKey = CurrentRoomService.instance.currentKey;
    if (currentKey.isEmpty) {
      return items;
    }
    final currentItems = <FollowUser>[];
    final others = <FollowUser>[];
    for (final item in items) {
      final itemKey = "${item.siteId}_${item.roomId}";
      if (itemKey == currentKey) {
        currentItems.add(item);
      } else {
        others.add(item);
      }
    }
    return [...others, ...currentItems];
  }

  List<String> _orderedRefreshSiteIds(Iterable<String> siteIds) {
    const preferredOrder = <String>[
      Constant.kBiliBili,
      Constant.kHuya,
      Constant.kDouyu,
      Constant.kDouyin,
      Constant.kKuaishou,
    ];
    final seen = <String>{};
    final result = <String>[];
    for (final siteId in preferredOrder) {
      if (siteIds.contains(siteId) && seen.add(siteId)) {
        result.add(siteId);
      }
    }
    final remaining = siteIds.where((siteId) => seen.add(siteId)).toList()
      ..sort();
    result.addAll(remaining);
    return result;
  }

  List<FollowUser> _orderRefreshBucketBySite(
    List<FollowUser> items, {
    bool moveCurrentRoomToEnd = false,
  }) {
    final grouped = <String, List<FollowUser>>{};
    for (final item in items) {
      grouped.putIfAbsent(item.siteId, () => <FollowUser>[]).add(item);
    }
    final ordered = <FollowUser>[];
    for (final siteId in _orderedRefreshSiteIds(grouped.keys)) {
      var bucket = sortFollowUsers(grouped[siteId] ?? const <FollowUser>[]);
      if (moveCurrentRoomToEnd) {
        bucket = deprioritizeCurrentRoom(bucket);
      }
      ordered.addAll(bucket);
    }
    return ordered;
  }

  List<FollowUser> _buildOrderedRefreshTargets(Iterable<FollowUser> items) {
    final uniqueItems = _distinctFollowUsers(items);
    final specials = uniqueItems.where((item) => item.isSpecialFollow).toList();
    final normals = uniqueItems.where((item) => !item.isSpecialFollow).toList();
    final orderedSpecials = _orderRefreshBucketBySite(specials);
    final orderedNormals = _orderRefreshBucketBySite(
      normals,
      moveCurrentRoomToEnd: true,
    );
    return [...orderedSpecials, ...orderedNormals];
  }

  Duration _douyinLimitedAutoResumeDelay(int attempt) {
    return Duration(
      seconds: kDouyinLimitedAutoResumeBaseDelay.inSeconds * attempt,
    );
  }

  Future<void> startUpdateStatus({
    bool force = false,
    bool statusOnly = false,
    bool silent = false,
  }) async {
    // 「展示直播封面」关闭 = 用户只要开播状态：任何通道（手动/进页/定时）
    // 都走纯状态轮，一个详情请求都不发。
    //
    // 详情请求（getRoomDetail）在刷新链路里只服务两件事：实时画面帧与已播
    // 时长（外加抖音身份同步）。既然列表不展示封面，这些都无意义，而详情
    // 接口恰恰是各平台风控最敏感的重接口（抖音 444、B站 -352 都打在这里）。
    final coverEnabled =
        AppSettingsController.instance.followShowLiveCover.value;
    final effectiveStatusOnly = statusOnly || !coverEnabled;
    return refreshSelectedStatus(
      followList,
      includeAllNormals: true,
      force: force,
      scope: FollowRefreshScope.all(automatic: !force),
      allowDetailRefresh: !effectiveStatusOnly && force,
      statusOnly: effectiveStatusOnly,
      silent: silent,
    );
  }

  Future<_FollowRefreshItemResult> _updateLiveStatus(
    FollowUser item, {
    int? generation,
    DouyinFollowRefreshLimiter? douyinLimiter,
    int workerIndex = 0,
    bool pauseRemainingOnLimited = false,
    bool statusOnly = false,
    bool useSharedStatus = true,
    /// true = 「仅局域网」入口（启动补轮/进页面/观看记录探测）：
    /// 只吃局域网共享快照，快照没覆盖就保留原状态，不发公网请求。
    /// **定时刷新与手动刷新都不传此项。**
    bool peerOnly = false,
  }) async {
    final previousStatus = item.liveStatus.value;
    final notifyReady = _liveNotifyReadyIds.contains(item.id);
    try {
      // ① 全平台通用：优先用局域网共享快照（其它端刚拉过 → 本端 0 公网请求，
      //    虎牙/斗鱼/快手/抖音/B站 一视同仁）。
      //    ⚠️ 命中时**不能直接 return**：后面的"详情/直播封面帧/已播时长、
      //    抖音身份校正"等逻辑必须照常执行（尤其开启「展示直播封面」时），
      //    这里只把"状态请求"这一项跳过。
      //
      //    🔴 TTL 口径（2026-09-12 修正）：
      //    - **手动刷新（useSharedStatus=false）→ 完全跳过快照，全量拉公网**。
      //      用户主动点刷新就是「我要最准的」，拿快照顶替会让刚关播的房间
      //      继续显示"直播中"（尤其多端快照时间戳不精确时），用户根本刷不掉。
      //    - 自动/定时轮（useSharedStatus=true）→ 3 分钟内快照可采用，省公网。
      final shared = useSharedStatus
          ? SyncService.instance.sharedLiveStatus(item.id)
          : null;
      // 本轮已被 B站 批量接口覆盖（见 [_prefetchBiliStatusBatch]）：状态已是
      // 最新（且已发布快照），这里只跳过"状态请求"，详情/封面流程照跑。
      final batchCovered = _biliBatchCovered.remove(item.id);
      final trustShared = batchCovered || shared != null;
      if (!batchCovered && shared != null) {
        item.liveStatus.value = shared;
        if (shared != 2) {
          item.liveStartTime = null;
          _liveNotifySentIds.remove(item.id);
        }
      }
      var site = Sites.siteForKey(item.siteId);
      // 站点已删除/未注册（自定义源/影视库被删后仍在关注列表里）：
      // 刷新状态直接跳过，避免 `Sites.allSites[...]!` 对 null 断言崩溃。
      if (site == null) {
        return const _FollowRefreshItemResult(
            _FollowRefreshItemOutcome.deferred);
      }
      final bool isLiving;
      if (batchCovered) {
        // 批量接口已把最新状态写在 item 上，直接用（不能拿 shared 判断，
        // 否则 shared 为 null 会被误判成"未开播"）。
        isLiving = item.liveStatus.value == 2;
      } else if (trustShared) {
        // 自动轮询命中快照：只省掉状态请求，下方详情/封面流程照跑。
        isLiving = shared == 2;
      } else if (peerOnly) {
        // 「仅局域网」入口（启动补轮 / 进页面 / 观看记录探测）：
        // 没有新鲜快照 → 不发公网请求，保留上一轮状态。
        // 注意：**定时刷新不走这里**（用户要求定时轮仍拉公网）。
        return const _FollowRefreshItemResult(
            _FollowRefreshItemOutcome.skipped);
      } else {
        // ② 平台级节流：抖音走专属 limiter；B站 串行（自动 1s / 手动 400ms）。
        if (item.siteId == Constant.kDouyin && douyinLimiter != null) {
          await douyinLimiter.beforeRequest(workerIndex);
        }
        if (item.siteId == Constant.kBiliBili) {
          await _biliStatusThrottle.wait(
            minInterval: useSharedStatus
                ? _BiliStatusThrottle.autoInterval
                : _BiliStatusThrottle.manualInterval,
          );
        }
        isLiving = await site.liveSite.getLiveStatus(roomId: item.roomId);
        // 全平台：把本机拉到的状态发布成本机快照（其它端 60s 内可取用，
        // 从而全屋公网请求从 N 份降到约 1 份）。
        SyncService.instance.publishLiveStatusItem(item.id, isLiving ? 2 : 1);
      }
      if (generation != null && generation != _updateGeneration) {
        return const _FollowRefreshItemResult(
            _FollowRefreshItemOutcome.deferred);
      }
      if (item.siteId == Constant.kDouyin && douyinLimiter != null) {
        douyinLimiter.onSuccess();
      }
      item.liveStatus.value = isLiving ? 2 : 1;
      if (statusOnly) {
        // 纯状态轮（手动下拉/手动刷新/TV 启动轮）：只回写开播状态，
        // 不再拉详情 —— 抖音身份 reconcile、非抖音开播的 showTime/封面
        // 一律跳过，交给 10 分钟定时轮（automatic）与进房处理，降低手动
        // 高频操作触发平台风控（抖音 444 等）的几率。
        if (!isLiving) {
          item.liveStartTime = null;
          _liveNotifySentIds.remove(item.id);
        }
      } else if (item.siteId == Constant.kDouyin) {
        await _reconcileDouyinFollowIdentity(
          item,
          site.liveSite,
          isLiving: isLiving,
          generation: generation,
        );
      } else if (item.liveStatus.value == 2) {
        // 这一支拉详情只为两件事：实时画面帧（虎牙 sScreenshot / B站 keyframe
        // / 抖音·快手截帧）与已播时长。关掉「展示直播封面」时不会走到这里
        // —— 刷新入口 [startUpdateStatus] 会统一走纯状态轮（见其注释）。
        final detail = await _detailGate.fetch(
          siteId: item.siteId,
          roomId: item.roomId,
          request: () => site.liveSite.getRoomDetail(roomId: item.roomId),
        );
        if (generation != null && generation != _updateGeneration) {
          return const _FollowRefreshItemResult(
              _FollowRefreshItemOutcome.deferred);
        }
        item.liveStartTime = detail.showTime;
      } else {
        item.liveStartTime = null;
        _liveNotifySentIds.remove(item.id);
      }
      if (item.isSpecialFollow &&
          notifyReady &&
          previousStatus != 2 &&
          item.liveStatus.value == 2 &&
          !_liveNotifySentIds.contains(item.id)) {
        _liveNotifySentIds.add(item.id);
        unawaited(LiveNotificationService.showLiveStart(item));
      }
      _liveNotifyReadyIds.add(item.id);
      return const _FollowRefreshItemResult(_FollowRefreshItemOutcome.success);
    } catch (e) {
      if (generation != null && generation != _updateGeneration) {
        return const _FollowRefreshItemResult(
            _FollowRefreshItemOutcome.deferred);
      }
      var limited = false;
      if (_isDouyinLimited(item, e)) {
        limited = true;
        if (douyinLimiter != null) {
          douyinLimiter.onLimited();
          _handleDouyinLimited(
            pauseRemainingOnLimited: pauseRemainingOnLimited,
          );
        } else {
          _handleDouyinLimited(
            pauseRemainingOnLimited: pauseRemainingOnLimited,
          );
        }
      }
      Log.logPrint(e);
      if (limited) {
        if (pauseRemainingOnLimited) {
          return const _FollowRefreshItemResult(
            _FollowRefreshItemOutcome.deferred,
            limited: true,
            keepPending: true,
            pauseRemaining: true,
          );
        }
        return const _FollowRefreshItemResult(
          _FollowRefreshItemOutcome.failed,
          limited: true,
        );
      }
      item.liveStatus.value = 0;
      item.liveStartTime = null;
      return _FollowRefreshItemResult(
        _FollowRefreshItemOutcome.failed,
        limited: limited,
      );
    }
  }

  Future<void> _reconcileDouyinFollowIdentity(
    FollowUser item,
    dynamic liveSite, {
    required bool isLiving,
    required int? generation,
    LiveRoomDetail? detail,
  }) async {
    final resolvedDetail = detail ??
        await _detailGate.fetch(
          siteId: item.siteId,
          roomId: item.roomId,
          request: () => liveSite.getRoomDetail(roomId: item.roomId),
        );
    if (generation != null && generation != _updateGeneration) {
      return;
    }
    final resolvedRoomId = resolvedDetail.roomId.trim();
    if (resolvedRoomId.isNotEmpty && resolvedRoomId != item.roomId) {
      final oldId = item.id;
      final newId = "${item.siteId}_$resolvedRoomId";
      await DBService.instance.deleteFollow(oldId);
      item.id = newId;
      item.roomId = resolvedRoomId;
      await DBService.instance.addFollow(item);
      await _migrateFollowTagReferences(oldId, newId);
    }
    final title = resolvedDetail.title.trim();
    final cover = resolvedDetail.cover.trim();
    if (title.isNotEmpty) {
      item.roomTitle = title;
    }
    if (cover.isNotEmpty) {
      item.roomCover = cover;
    }
    if (title.isNotEmpty || cover.isNotEmpty) {
      item.previewUpdatedAt = DateTime.now();
    }
    item.liveStatus.value = resolvedDetail.status ? 2 : 1;
    item.liveStartTime =
        resolvedDetail.status && isLiving ? resolvedDetail.showTime : null;
    if (item.liveStatus.value != 2) {
      _liveNotifySentIds.remove(item.id);
    }
    await DBService.instance.addFollow(item);
  }

  Future<void> _migrateFollowTagReferences(String oldId, String newId) async {
    if (oldId == newId) {
      return;
    }
    for (final tag in followTagList) {
      final index = tag.userId.indexOf(oldId);
      if (index < 0) {
        continue;
      }
      tag.userId[index] = newId;
      final deduplicated = <String>{};
      tag.userId.removeWhere((id) => !deduplicated.add(id));
      await DBService.instance.updateFollowTag(tag);
    }
  }

  bool _isDouyinLimited(FollowUser item, Object error) {
    return item.siteId == Constant.kDouyin &&
        error is CoreError &&
        error.statusCode == 444;
  }

  void _handleDouyinLimited({required bool pauseRemainingOnLimited}) {
    _lastPlatformLimitedAt = DateTime.now();
    if (pauseRemainingOnLimited) {
      Log.w("抖音访问受限，已自动降速并保留剩余任务供后续继续");
      return;
    }
    Log.w("抖音访问受限，已自动降速并继续处理剩余任务");
  }

  int compareFollowUsers(FollowUser a, FollowUser b) {
    final aBucket = _sortBucket(a);
    final bBucket = _sortBucket(b);
    final liveCompare = aBucket.compareTo(bBucket);
    if (liveCompare != 0) {
      return liveCompare;
    }
    return b.addTime.compareTo(a.addTime);
  }

  int _sortBucket(FollowUser item) {
    final isLiving = item.liveStatus.value == 2;
    if (item.isSpecialFollow) {
      return isLiving ? 0 : 1;
    }
    return isLiving ? 2 : 3;
  }

  List<FollowUser> sortFollowUsers(Iterable<FollowUser> items) {
    return items.toList()..sort(compareFollowUsers);
  }

  List<FollowUser> _distinctFollowUsers(Iterable<FollowUser> items) {
    final result = <FollowUser>[];
    final seenIds = <String>{};
    for (final item in items) {
      final uniqueId = item.id.trim().isNotEmpty
          ? item.id.trim()
          : "${item.siteId}_${item.roomId}";
      if (seenIds.add(uniqueId)) {
        result.add(item);
      }
    }
    return result;
  }

  List<FollowUser> _buildRefreshTargets(
    Iterable<FollowUser> normalTargets, {
    bool includeAllNormals = false,
  }) {
    final specials = followList.where((item) => item.isSpecialFollow).toList();
    final normals = includeAllNormals
        ? followList.where((item) => !item.isSpecialFollow).toList()
        : normalTargets.where((item) => !item.isSpecialFollow).toList();
    return _distinctFollowUsers([
      ...sortFollowUsers(specials),
      ...sortFollowUsers(normals),
    ]);
  }

  List<FollowUser> buildPageFrontTargets(Iterable<FollowUser> pageItems) {
    return _distinctFollowUsers(sortFollowUsers(pageItems));
  }

  String buildPageRefreshScopeKey(String pageKey) => "page:$pageKey";

  String _refreshTargetKey(FollowUser item) {
    final uniqueId = item.id.trim().isNotEmpty
        ? item.id.trim()
        : "${item.siteId}_${item.roomId}";
    return "${item.siteId}|${item.roomId}|$uniqueId";
  }

  bool _sameStringList(List<String> a, List<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  _PersistedFollowRefreshTaskState? _loadPersistedRefreshTask(String scopeKey) {
    try {
      final rawState = LocalStorageService.instance.getValue(
        _refreshTaskStateStorageKey,
        "",
      );
      final rawTargets = LocalStorageService.instance.getValue(
        _refreshTaskTargetsStorageKey,
        "",
      );
      if (rawState.isEmpty || rawTargets.isEmpty) {
        return null;
      }
      final stateMap = jsonDecode(rawState);
      final targetsMap = jsonDecode(rawTargets);
      if (stateMap is! Map || targetsMap is! Map) {
        return null;
      }
      final state = _PersistedFollowRefreshTaskState.fromMaps(
        stateMap.cast<String, dynamic>(),
        targetsMap.cast<String, dynamic>(),
      );
      if (state.scopeKey != scopeKey) {
        return null;
      }
      return state;
    } catch (e) {
      Log.w("读取关注刷新续跑状态失败: $e");
      return null;
    }
  }

  Future<void> _persistRefreshTask({
    required FollowRefreshScope scope,
    required int total,
    required List<String> orderedKeys,
    required List<String> pendingKeys,
    required int successCount,
    required int failedCount,
    required int deferredCount,
  }) async {
    if (!scope.includeAllNormals) {
      return;
    }
    final statePayload = {
      "scopeKey": scope.scopeKey,
      "total": total,
      "successCount": successCount,
      "failedCount": failedCount,
      "deferredCount": deferredCount,
      "updatedAt": DateTime.now().toIso8601String(),
    };
    final targetPayload = {
      "orderedKeys": orderedKeys,
      "pendingKeys": pendingKeys,
    };
    await LocalStorageService.instance.setValue(
      _refreshTaskStateStorageKey,
      jsonEncode(statePayload),
    );
    await LocalStorageService.instance.setValue(
      _refreshTaskTargetsStorageKey,
      jsonEncode(targetPayload),
    );
    // Fix Windows crash on exit: 频繁写入导致localstorage.hive膨胀到2GB，
    // 应用退出时写入LastLiveRoom触发STATUS_STACK_BUFFER_OVERRUN(0xC0000409)
    // 每次persist后尝试compact，失败则忽略，不阻塞刷新流程
    try {
      await LocalStorageService.instance.settingsBox.compact();
    } catch (e) {
      // compact失败不影响刷新，静默忽略
    }
  }

  Future<void> _clearPersistedRefreshTask() async {
    await LocalStorageService.instance.removeValue(_refreshTaskStateStorageKey);
    await LocalStorageService.instance
        .removeValue(_refreshTaskTargetsStorageKey);
  }

  List<FollowUser> _buildManualDetailTargets(List<FollowUser> items) {
    final candidates = _distinctFollowUsers(
      items.where(
        (item) => item.siteId == Constant.kDouyin || item.liveStatus.value == 2,
      ),
    );
    return _orderRefreshBucketBySite(candidates);
  }

  List<FollowUser> _buildPreviewTargets(
    Iterable<FollowUser> items, {
    bool force = false,
  }) {
    final now = DateTime.now();
    return _orderRefreshBucketBySite(
      _distinctFollowUsers(
        items.where((item) {
          if (item.liveStatus.value != 2) {
            return false;
          }
          final targetKey = _refreshTargetKey(item);
          if (_previewRefreshingKeys.contains(targetKey)) {
            return false;
          }
          if (force) {
            return true;
          }
          final missingPreview =
              item.roomTitle.trim().isEmpty || item.roomCover.trim().isEmpty;
          if (missingPreview) {
            return true;
          }
          final updatedAt = item.previewUpdatedAt;
          if (updatedAt == null) {
            return true;
          }
          // 与平台截图的实际更新节奏对齐：B站 keyframe / 虎牙 sScreenshot
          // 这类画面帧通常几十秒~几分钟才换一帧，并不是秒级实时。
          // 取 3 分钟既是“跟着平台走”，又能挡掉连续切分组/翻页时对手滑式
          // 重复主播的重复补帧（0 节流会把这些全打成详情请求）。
          // 图片缓存 TTL 也同步为 3 分钟（见 follow_user_item 的 cacheMaxAge），
          // 避免“拉到新 URL 但图片缓存还没过期”导致的画面不更新。
          return now.difference(updatedAt) > kPreviewRefreshInterval;
        }),
      ),
    );
  }

  /// 单轮可见卡预取上限：列表改多列后同屏卡数变多，若一次把整屏"直播中
  /// 且缺封面/超时"的卡全部打详情（B站 getInfoByRoom 属 WBI 风控接口），
  /// 请求量会成倍上涨并把 B站接口风控推高（连累弹幕 token 获取）。
  /// 每轮最多补 [kMaxPreviewPerRound] 个，其余留到下一轮/下一次滚动。
  static const int kMaxPreviewPerRound = 6;

  Future<void> refreshVisiblePreviews(
    Iterable<FollowUser> pageItems, {
    bool force = false,
  }) async {
    final all = _buildPreviewTargets(pageItems, force: force);
    if (all.isEmpty) {
      return;
    }
    final targets = all.length > kMaxPreviewPerRound
        ? all.sublist(0, kMaxPreviewPerRound)
        : all;
    final keys = targets.map(_refreshTargetKey).toList(growable: false);
    _previewRefreshingKeys.addAll(keys);
    try {
      await _refreshMetadataTargets(
        targets,
        scope: const FollowRefreshScope(
          scopeKey: "preview",
          includeAllNormals: false,
          automatic: true,
          allowBackgroundSpecials: false,
          stage: "正在补齐封面与标题",
          backgroundStage: "",
        ),
        stage: "正在补齐封面与标题",
        refreshProgressUi: false,
        reconcileDouyinIdentity: true,
      );
    } finally {
      _previewRefreshingKeys.removeAll(keys);
    }
  }

  Future<FollowUser> resolveFollowBeforeEnter(FollowUser item) async {
    if (item.siteId != Constant.kDouyin) {
      return item;
    }
    await _refreshMetadataTargets(
      [item],
      scope: const FollowRefreshScope(
        scopeKey: "room-enter",
        includeAllNormals: false,
        automatic: false,
        allowBackgroundSpecials: false,
        stage: "正在校正直播间",
        backgroundStage: "",
      ),
      stage: "正在校正直播间",
      refreshProgressUi: false,
      reconcileDouyinIdentity: true,
    );
    return item;
  }

  Future<void> _refreshMetadataTargets(
    List<FollowUser> targets, {
    required FollowRefreshScope scope,
    required String stage,
    required bool refreshProgressUi,
    required bool reconcileDouyinIdentity,
  }) async {
    if (targets.isEmpty) {
      return;
    }
    final orderedTargets =
        _orderRefreshBucketBySite(_distinctFollowUsers(targets));
    final generation = _updateGeneration;
    var completed = 0;
    var successCount = 0;
    var failedCount = 0;
    var changed = false;

    void updateProgress({required bool done}) {
      if (!refreshProgressUi) {
        return;
      }
      final detail = [
        "成功 $successCount",
        if (failedCount > 0) "失败 $failedCount",
      ].join("  ");
      _setRefreshProgress(
        active: !done,
        automatic: scope.automatic,
        scopeKey: scope.scopeKey,
        stage: stage,
        current: completed,
        total: orderedTargets.length,
        successCount: successCount,
        failedCount: failedCount,
        detail: detail,
        completed: done,
      );
    }

    Future<void> worker(
      Queue<FollowUser> queue, {
      required bool isDouyinQueue,
    }) async {
      while (queue.isNotEmpty) {
        if (generation != _updateGeneration) {
          return;
        }
        final item = queue.removeFirst();
        try {
          final site = Sites.allSites[item.siteId]!;
          final detail = await _detailGate.fetch(
            siteId: item.siteId,
            roomId: item.roomId,
            request: () => site.liveSite.getRoomDetail(roomId: item.roomId),
          );
          if (generation != _updateGeneration) {
            return;
          }
          if (reconcileDouyinIdentity && isDouyinQueue) {
            await _reconcileDouyinFollowIdentity(
              item,
              site.liveSite,
              isLiving: item.liveStatus.value == 2 || detail.status,
              generation: generation,
              detail: detail,
            );
          } else {
            final title = detail.title.trim();
            final cover = detail.cover.trim();
            if (title.isNotEmpty && title != item.roomTitle) {
              item.roomTitle = title;
              changed = true;
            }
            if (cover.isNotEmpty && cover != item.roomCover) {
              item.roomCover = cover;
              changed = true;
            }
            if (detail.status && item.liveStartTime != detail.showTime) {
              item.liveStartTime = detail.showTime;
              changed = true;
            }
            if (title.isNotEmpty || cover.isNotEmpty) {
              item.previewUpdatedAt = DateTime.now();
              changed = true;
            }
            await DBService.instance.addFollow(item);
          }
          changed = true;
          successCount++;
        } catch (e) {
          if (generation != _updateGeneration) {
            return;
          }
          failedCount++;
          Log.logPrint("关注详情补齐失败(${item.siteId}/${item.roomId}): $e");
        } finally {
          completed++;
          updateProgress(done: false);
        }
      }
    }

    if (refreshProgressUi) {
      _cancelRefreshProgressReset();
      updating.value = true;
      _setRefreshProgress(
        active: true,
        automatic: scope.automatic,
        scopeKey: scope.scopeKey,
        stage: stage,
        current: 0,
        total: orderedTargets.length,
      );
      Log.logPrint(
        "关注详情补齐阶段开始，目标数: ${orderedTargets.length}，scope=${scope.scopeKey}",
      );
    }

    try {
      final douyinTargets = orderedTargets
          .where((item) => item.siteId == Constant.kDouyin)
          .toList(growable: false);
      final otherTargets = orderedTargets
          .where((item) => item.siteId != Constant.kDouyin)
          .toList(growable: false);
      for (final group in [douyinTargets, otherTargets]) {
        if (group.isEmpty) {
          continue;
        }
        final queue = Queue<FollowUser>.from(group);
        final isDouyinQueue = group.first.siteId == Constant.kDouyin;
        final workerCount =
            isDouyinQueue ? 1 : group.length.clamp(1, 2).toInt();
        final workers = <Future<void>>[];
        for (var i = 0; i < workerCount; i++) {
          workers.add(worker(queue, isDouyinQueue: isDouyinQueue));
        }
        await Future.wait(workers);
        if (generation != _updateGeneration) {
          return;
        }
      }
      if (changed) {
        filterData();
      }
      updateProgress(done: true);
      if (refreshProgressUi) {
        Log.logPrint(
          "关注详情补齐阶段完成，成功: $successCount，失败: $failedCount，scope=${scope.scopeKey}",
        );
      }
    } finally {
      if (refreshProgressUi && generation == _updateGeneration) {
        updating.value = false;
        _finishRefreshProgressLifecycle(generation);
      }
    }
  }

  _RefreshTargetPolicyResult _applyDouyinRefreshPolicy(
    List<FollowUser> orderedTargets, {
    required FollowRefreshScope scope,
    required bool hasFullDouyinCookie,
  }) {
    return _RefreshTargetPolicyResult(
      allowedTargets: orderedTargets,
      deferredTargets: const [],
      toastMessage:
          hasFullDouyinCookie ? "" : "抖音未登录时将自动降速刷新；若出现 444，会暂停并保留剩余任务供后续继续。",
    );
  }

  Future<void> refreshSelectedStatus(
    Iterable<FollowUser> normalTargets, {
    bool includeAllNormals = false,
    bool force = true,
    FollowRefreshScope? scope,
    bool allowDetailRefresh = true,
    bool statusOnly = false,
    bool silent = false,
    /// true = 自动刷新：只走局域网共享快照，不发任何公网状态请求。
    bool peerOnly = false,
    /// >0 且 [peerOnly] 为 true 时：快照没命中的**前 N 条**允许回退公网单查
    /// （"全屋没有生产者"时的兜底，见 [refreshPeerOnly]）。0 = 严格纯 P2P。
    int networkFallbackLimit = 0,
  }) async {
    final resolvedScope = scope ??
        FollowRefreshScope.all(
          automatic: !force,
        );
    final targets = resolvedScope.includeAllNormals
        ? _buildRefreshTargets(
            normalTargets,
            includeAllNormals: includeAllNormals,
          )
        : buildPageFrontTargets(normalTargets);
    await _refreshStatusTargets(
      targets,
      force: force,
      scope: resolvedScope,
      statusOnly: statusOnly,
      silent: silent,
      peerOnly: peerOnly,
      networkFallbackLimit: networkFallbackLimit,
    );
    if (!allowDetailRefresh ||
        resolvedScope.automatic ||
        statusOnly ||
        targets.isEmpty) {
      return;
    }
    final detailTargets = _buildManualDetailTargets(targets);
    await _refreshMetadataTargets(
      detailTargets,
      scope: resolvedScope,
      stage: "正在补齐封面与标题",
      refreshProgressUi: true,
      reconcileDouyinIdentity: true,
    );
  }

  Future<void> _refreshStatusTargets(
    List<FollowUser> targets, {
    bool force = false,
    required FollowRefreshScope scope,
    bool statusOnly = false,
    bool silent = false,
    bool peerOnly = false,
    int networkFallbackLimit = 0,
  }) async {
    final now = DateTime.now();
    final lastStartedAt = _lastUpdateStatusStartedAt;
    if (!force &&
        lastStartedAt != null &&
        now.difference(lastStartedAt) < updateStatusCooldown) {
      Log.logPrint("关注状态刷新仍在冷却中，跳过本次自动刷新");
      updating.value = false;
      _resetRefreshProgress();
      filterData();
      return;
    }
    if (updating.value &&
        refreshProgress.value.active &&
        refreshProgress.value.scopeKey == scope.scopeKey &&
        !refreshProgress.value.completed) {
      Log.logPrint("同一刷新任务仍在进行，复用当前进度: ${scope.scopeKey}");
      return;
    }
    _lastUpdateStatusStartedAt = now;
    final generation = ++_updateGeneration;
    final automatic = scope.automatic;
    _cancelRefreshProgressReset();
    if (updating.value) {
      Log.logPrint("新的关注刷新任务已启动，旧任务将按 generation 自动退出: ${scope.scopeKey}");
    }
    updating.value = true;
    _setRefreshProgress(
      active: true,
      automatic: automatic,
      background: silent,
      scopeKey: scope.scopeKey,
      stage: scope.stage,
      current: 0,
      total: targets.length,
    );

    if (targets.isEmpty) {
      updating.value = false;
      _resetRefreshProgress();
      filterData();
      return;
    }

    try {
      var concurrency = getOptimalConcurrency(
        totalCount: targets.length,
      );
      final policy = BulkDataImportService.policyForCount(targets.length);
      final hasFullDouyinCookie = DouyinCookieHelper.hasFullCookie(
        (Sites.allSites[Constant.kDouyin]?.liveSite as DouyinSite?)?.cookie ??
            "",
      );

      Log.logPrint(
        "关注状态阶段开始，并发数: $concurrency，模式: ${_getConcurrencyMode()}，目标数: ${targets.length}，策略: ${policy.label}，"
        "scope=${scope.scopeKey} fullDouyinCookie=$hasFullDouyinCookie",
      );

      final orderedTargets = _buildOrderedRefreshTargets(targets);
      final filteredTargets = _applyDouyinRefreshPolicy(
        orderedTargets,
        scope: scope,
        hasFullDouyinCookie: hasFullDouyinCookie,
      );
      final allowedTargets = filteredTargets.allowedTargets;
      final orderedAllowedKeys = allowedTargets.map(_refreshTargetKey).toList();
      final targetByKey = <String, FollowUser>{
        for (final item in allowedTargets) _refreshTargetKey(item): item,
      };
      final persistedTask = _loadPersistedRefreshTask(scope.scopeKey);
      final resumeTask = scope.includeAllNormals &&
          persistedTask != null &&
          _sameStringList(persistedTask.orderedKeys, orderedAllowedKeys) &&
          persistedTask.pendingKeys.isNotEmpty;
      final pendingKeys = resumeTask
          ? persistedTask.pendingKeys
              .where(targetByKey.containsKey)
              .toList(growable: true)
          : orderedAllowedKeys.toList(growable: true);
      final isHugeTask = targets.length >= kFollowProgressUiBurstThreshold;
      final douyinTargetCount = filteredTargets.allowedTargets
          .where((item) => item.siteId == Constant.kDouyin)
          .length;
      final douyinLimiter = douyinTargetCount > 0
          ? DouyinFollowRefreshLimiter.forTargetCount(douyinTargetCount)
          : null;

      final resumedSuccessCount = persistedTask?.successCount ?? 0;
      final resumedFailedCount = persistedTask?.failedCount ?? 0;
      var completed = resumeTask ? resumedSuccessCount + resumedFailedCount : 0;
      var successCount = resumeTask ? resumedSuccessCount : 0;
      var failedCount = resumeTask ? resumedFailedCount : 0;
      var deferredCount = filteredTargets.deferredTargets.length;
      var limitedCount = 0;
      var pausedForResume = false;
      var autoResumeAttempt = 0;

      if (scope.includeAllNormals) {
        unawaited(
          _persistRefreshTask(
            scope: scope,
            total: targets.length,
            orderedKeys: orderedAllowedKeys,
            pendingKeys: pendingKeys,
            successCount: successCount,
            failedCount: failedCount,
            deferredCount: deferredCount,
          ),
        );
      }

      if (filteredTargets.deferredTargets.isNotEmpty) {
        Log.w(
          "抖音全量刷新受限：scope=${scope.scopeKey} deferred=$deferredCount "
          "allowedDouyin=$douyinTargetCount requiresFullCookie=true",
        );
        if (filteredTargets.toastMessage.isNotEmpty) {
          SmartDialog.showToast(filteredTargets.toastMessage);
        }
      }
      if (resumeTask) {
        Log.logPrint(
          "继续上次未完成的全量关注刷新：scope=${scope.scopeKey} remaining=$pendingKeys.length",
        );
      }

      void updateProgress({required bool active, required bool done}) {
        final detail = [
          "成功 $successCount",
          if (failedCount > 0) "失败 $failedCount",
          if (deferredCount > 0) "待续跑 $deferredCount",
        ].join("  ");
        _setRefreshProgress(
          active: active,
          automatic: automatic,
          background: silent,
          scopeKey: scope.scopeKey,
          stage: scope.stage,
          current: completed,
          total: targets.length,
          successCount: successCount,
          failedCount: failedCount,
          deferredCount: deferredCount,
          detail: detail,
          completed: done,
        );
      }

      updateProgress(active: true, done: false);

      // B站 批量状态预取：1 个请求替代 N 次单查（已覆盖的项在 worker 中跳过单查）。
      // 「仅局域网」入口（peerOnly）直接跳过 —— 一个公网请求都不发。
      if (!peerOnly) {
        await _prefetchBiliStatusBatch(
          generation: generation,
          useSharedStatus: !force,
          peerOnly: peerOnly,
        );
      }
      unawaited(_persistBiliUids());

      while (pendingKeys.isNotEmpty) {
        final taskQueue = Queue<FollowUser>.from(
          pendingKeys.map((key) => targetByKey[key]).whereType<FollowUser>(),
        );
        pausedForResume = false;
        // 「全屋无生产者」兜底：只放行列表**最前面** [networkFallbackLimit] 条
        // 走公网。用一个单调递减的额度 counter 在 worker 间共享（单线程事件
        // 循环下 removeFirst 的顺序即列表顺序，故先后取到的就是最前面几条）。
        var fallbackQuota = networkFallbackLimit;

        Future<void> worker(int workerId) async {
          while (taskQueue.isNotEmpty) {
            if (generation != _updateGeneration || pausedForResume) {
              return;
            }
            var item = taskQueue.removeFirst();
            // 该条是否允许走公网兜底（额度还有 → 允许）。
            final allowFallback = fallbackQuota > 0;
            if (allowFallback) {
              fallbackQuota--;
            }
            final result = await _updateLiveStatus(
              item,
              generation: generation,
              douyinLimiter: douyinLimiter,
              workerIndex: workerId,
              pauseRemainingOnLimited: scope.includeAllNormals,
              statusOnly: statusOnly,
              // force（手动刷新）时不走共享快照：用户手动刷就要拿最新。
              // 手动刷新另外再由下方 allowPublic 决定是否额外拉公网。
              useSharedStatus: !force,
              // 「仅局域网」入口：worker 内不允许回退到公网单查。
              // 但若本入口开了兜底（allowFallback）则该条放行。
              peerOnly: peerOnly && !allowFallback,
            );
            if (generation != _updateGeneration) {
              return;
            }
            if (result.limited) {
              limitedCount++;
            }
            final targetKey = _refreshTargetKey(item);
            if (!result.keepPending) {
              pendingKeys.remove(targetKey);
            }

            switch (result.outcome) {
              case _FollowRefreshItemOutcome.success:
                successCount++;
                completed++;
                break;
              case _FollowRefreshItemOutcome.failed:
                failedCount++;
                completed++;
                break;
              case _FollowRefreshItemOutcome.deferred:
              case _FollowRefreshItemOutcome.skipped:
                break;
            }
            if (result.pauseRemaining) {
              pausedForResume = true;
              deferredCount =
                  filteredTargets.deferredTargets.length + pendingKeys.length;
            }
            if (scope.includeAllNormals && !isHugeTask) {
              unawaited(
                _persistRefreshTask(
                  scope: scope,
                  total: targets.length,
                  orderedKeys: orderedAllowedKeys,
                  pendingKeys: pendingKeys,
                  successCount: successCount,
                  failedCount: failedCount,
                  deferredCount: deferredCount,
                ),
              );
            }
            if (!isHugeTask || completed % 20 == 0 || pendingKeys.isEmpty) {
              updateProgress(active: true, done: false);
            }
          }
        }

        var workers = <Future>[];
        for (var i = 0; i < concurrency; i++) {
          workers.add(worker(i));
        }
        await Future.wait(workers);

        if (generation != _updateGeneration) {
          return;
        }
        if (!pausedForResume || pendingKeys.isEmpty) {
          break;
        }
        if (!scope.includeAllNormals ||
            autoResumeAttempt >= kDouyinLimitedAutoResumeMaxAttempts) {
          break;
        }
        autoResumeAttempt++;
        final resumeDelay = _douyinLimitedAutoResumeDelay(autoResumeAttempt);
        Log.w(
          "抖音刷新触发限流，${resumeDelay.inSeconds}s后自动续刷剩余${pendingKeys.length}项 "
          "scope=${scope.scopeKey} attempt=$autoResumeAttempt",
        );
        updateProgress(active: true, done: false);
        await Future.delayed(resumeDelay);
        if (generation != _updateGeneration) {
          return;
        }
        deferredCount = filteredTargets.deferredTargets.length;
      }

      if (generation != _updateGeneration) {
        return;
      }
      if (douyinLimiter != null) {
        final summary = douyinLimiter.finish(douyinTargetCount);
        Log.logPrint(
          "抖音关注刷新总结 scope=${scope.scopeKey} target=${summary.targetCount} "
          "startConcurrency=${summary.initialConcurrency} "
          "startInterval=${summary.initialInterval.inMilliseconds}ms "
          "finalInterval=${summary.finalInterval.inMilliseconds}ms "
          "success=${summary.successCount} limited=${summary.limitedCount} "
          "cooldown=${summary.cooledDown} elapsed=${summary.elapsed.inMilliseconds}ms "
          "failed=$failedCount deferred=$deferredCount limitedObserved=$limitedCount",
        );
      }
      if (pendingKeys.isNotEmpty) {
        if (scope.includeAllNormals) {
          deferredCount =
              filteredTargets.deferredTargets.length + pendingKeys.length;
        } else {
          failedCount += pendingKeys.length;
          completed += pendingKeys.length;
          pendingKeys.clear();
          deferredCount = filteredTargets.deferredTargets.length;
        }
      }
      updateProgress(active: false, done: true);
      if (scope.includeAllNormals) {
        if (pendingKeys.isEmpty) {
          await _clearPersistedRefreshTask();
        } else {
          await _persistRefreshTask(
            scope: scope,
            total: targets.length,
            orderedKeys: orderedAllowedKeys,
            pendingKeys: pendingKeys,
            successCount: successCount,
            failedCount: failedCount,
            deferredCount: deferredCount,
          );
        }
      }
      filterData();

      Log.logPrint("关注状态阶段完成");
    } finally {
      if (generation == _updateGeneration) {
        updating.value = false;
        _finishRefreshProgressLifecycle(generation);
      }
    }
  }

  void _setRefreshProgress({
    required bool active,
    required bool automatic,
    required String scopeKey,
    required String stage,
    required int current,
    required int total,
    int successCount = 0,
    int failedCount = 0,
    int deferredCount = 0,
    int skippedCount = 0,
    bool completed = false,
    bool background = false,
    String detail = "",
  }) {
    refreshProgress.value = FollowRefreshProgress(
      active: active,
      automatic: automatic,
      scopeKey: scopeKey,
      stage: stage,
      current: current.clamp(0, total).toInt(),
      total: total,
      successCount: successCount,
      failedCount: failedCount,
      deferredCount: deferredCount,
      skippedCount: skippedCount,
      completed: completed,
      background: background,
      detail: detail,
    );
  }

  void _resetRefreshProgress() {
    _cancelRefreshProgressReset();
    refreshProgress.value = const FollowRefreshProgress.idle();
  }

  void _cancelRefreshProgressReset() {
    _refreshProgressResetTimer?.cancel();
    _refreshProgressResetTimer = null;
  }

  void _finishRefreshProgressLifecycle(int generation) {
    if (refreshProgress.value.completed) {
      _scheduleRefreshProgressReset(generation);
      return;
    }
    _resetRefreshProgress();
  }

  void _scheduleRefreshProgressReset(int generation) {
    _cancelRefreshProgressReset();
    _refreshProgressResetTimer = Timer(
      refreshProgressCompletionHold,
      () {
        if (generation != _updateGeneration) {
          return;
        }
        if (updating.value || !refreshProgress.value.completed) {
          return;
        }
        _resetRefreshProgress();
      },
    );
  }

  void filterData() {
    followList.assignAll(sortFollowUsers(followList));
    liveList.assignAll(
      sortFollowUsers(followList.where((x) => x.liveStatus.value == 2)),
    );
    notLiveList.assignAll(
      sortFollowUsers(followList.where((x) => x.liveStatus.value != 2)),
    );
    _updatedListController.add(0);
  }

  @override
  void onClose() {
    _updateGeneration++;
    updating.value = false;
    _cancelRefreshProgressReset();
    _resetRefreshProgress();
    WidgetsBinding.instance.removeObserver(this);
    updateTimer?.cancel();
    _biliJitterTimer?.cancel();
    _eventReloadTimer?.cancel();
    subscription?.cancel();
    _autoRefreshTickController.close();
    super.onClose();
  }

  /// 退后台 / 最小化 → 暂停关注定时轮；回前台 → 若已超时则立刻补一轮。
  ///
  /// 🔴 2026-09-12 新增。此前定时器完全不感知生命周期：Windows 最小化、
  /// Android 切后台后仍按 60s~10min 的节奏持续打公网接口，而用户根本看不到
  /// 结果 —— 纯属给平台风控送请求量（也是"切后台还耗电/耗流量"的来源）。
  /// iOS 因为系统会挂起进程而"被动停掉"，三端行为不一致。
  ///
  /// 现在统一为：**后台一律停表**（一个公网请求都不发），回前台按真实流逝
  /// 时间决定"立刻补一轮"还是"接着等剩余时间"，不会因为切出去一趟就丢掉
  /// 一整轮刷新，也不会把停表期间的时间白白算进间隔。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        _onAppResumed();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _onAppBackgrounded();
        break;
    }
  }

  /// 退后台：停表并记下时刻（[onClose] 之外唯一的定时器停止入口）。
  void _onAppBackgrounded() {
    if (_appInBackground) {
      return; // 连续多个后台事件（inactive→paused）只处理一次
    }
    _appInBackground = true;
    _backgroundedAt = DateTime.now();
    _biliJitterTimer?.cancel();
    updateTimer?.cancel();
    updateTimer = null;
    Log.logPrint("App 退后台 → 暂停关注自动刷新定时器");
  }

  /// 回前台：据停表时长决定补一轮 or 续等。
  void _onAppResumed() {
    if (!_appInBackground) {
      return;
    }
    _appInBackground = false;
    final stoppedAt = _backgroundedAt;
    _backgroundedAt = null;
    if (!AppSettingsController.instance.autoUpdateFollowEnable.value) {
      return; // 开关关了 → 不排期（与 initTimer 一致）
    }
    if (stoppedAt != null) {
      final configured = AppSettingsController
          .instance.autoUpdateFollowDuration.value;
      final baseMinutes = configured < 1 ? 10 : configured;
      if (DateTime.now().difference(stoppedAt) >=
          Duration(minutes: baseMinutes)) {
        // 停表时长已超过一个完整周期 → 数据明显过期，立刻补一轮。
        // 走"自动刷新"语义（静默 + 受风控闸门约束），不弹进度条。
        Log.logPrint("App 回前台且停表已超一个周期 → 立刻补一轮关注刷新");
        _autoRefreshRunStartedAt = DateTime.now();
        unawaited(loadData(silent: true));
      }
    }
    _scheduleNextAutoRefresh();
  }
  /// 取 B站 站点实例（用于批量状态接口与 uid 缓存）。
  BiliBiliSite? get _biliSite {
    final live = Sites.siteForKey(Constant.kBiliBili)?.liveSite;
    return live is BiliBiliSite ? live : null;
  }

  /// 恢复上次持久化的 roomId→uid 映射（启动调用）。
  void _restoreBiliUids() {
    try {
      final raw = LocalStorageService.instance
          .getValue<String>(_kBiliAnchorUids, "");
      if (raw.isEmpty) {
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return;
      }
      final map = <String, String>{};
      decoded.forEach((k, v) {
        final key = k?.toString() ?? "";
        final value = v?.toString() ?? "";
        if (key.isNotEmpty && value.isNotEmpty) {
          map[key] = value;
        }
      });
      _biliSite?.restoreRoomUids(map);
    } catch (e) {
      Log.d("恢复B站uid映射失败：$e");
    }
  }

  /// 持久化 roomId→uid 映射（上限 2000 条，避免设置箱膨胀）。
  Future<void> _persistBiliUids() async {
    final site = _biliSite;
    if (site == null) {
      return;
    }
    try {
      final all = site.knownRoomUids;
      if (all.isEmpty) {
        return;
      }
      final keys = all.keys.toList();
      final picked =
          keys.length > 2000 ? keys.sublist(keys.length - 2000) : keys;
      final map = <String, String>{for (final k in picked) k: all[k]!};
      await LocalStorageService.instance
          .setValue(_kBiliAnchorUids, jsonEncode(map));
    } catch (e) {
      Log.d("持久化B站uid映射失败：$e");
    }
  }

  /// **B站 批量状态预取**（治本优化）：B站 官方有免 Cookie 的批量状态接口
  /// (`room/v1/Room/get_status_info_by_uids`)，一次可查多个主播 uid →
  /// 把"每个 B站 关注一个请求"降为"整批一个请求"。B站 风控按 IP 计，
  /// 请求量降下来后弹幕 token 接口就不易被连带限频。
  ///
  /// - 只对「已知 uid」的项生效（uid 由 [BiliBiliSite.getLiveStatus] 的
  ///   get_info 响应顺带学到并持久化）；未知 uid 的项留给原有逐条单查
  ///   ——单查会把 uid 学回来，下一轮即可进批量。
  /// - 少于 2 项不做（1 个请求与单查无差别）。
  /// - 结果同步写入局域网共享快照，供其它端白拿。
  Future<void> _prefetchBiliStatusBatch({
    int? generation,
    bool useSharedStatus = false,
    bool peerOnly = false,
  }) async {
    _biliBatchCovered.clear();
    final site = _biliSite;
    if (site == null || followList.isEmpty) {
      return;
    }
    // 「仅局域网」入口：不发批量请求（调用处通常已拦，这里再兜一层）。
    if (peerOnly) {
      return;
    }
    final uidToItems = <String, List<FollowUser>>{};
    for (final item in followList) {
      if (item.siteId != Constant.kBiliBili) {
        continue;
      }
      final uid = site.uidOfRoom(item.roomId);
      if (uid == null || uid.isEmpty) {
        continue;
      }
      uidToItems.putIfAbsent(uid, () => <FollowUser>[]).add(item);
    }
    if (uidToItems.length < 2) {
      return;
    }
    // 局域网内已有这些房间的新鲜快照 → 让 item 级逻辑白拿，本批一个请求
    // 也不发（多端同 IP，能省则省）。
    // 🔴 2026-09-12：**手动刷新（useSharedStatus=false）不走快照，全量拉公网**
    //    —— 用户点刷新就是"我要最准的"，被快照截胡会表现为"怎么刷都刷不掉"。
    if (useSharedStatus) {
      var snapshotCovered = 0;
      for (final items in uidToItems.values) {
        if (items.isNotEmpty &&
            SyncService.instance.sharedLiveStatus(items.first.id) != null) {
          snapshotCovered++;
        }
      }
      if (snapshotCovered == uidToItems.length) {
        return;
      }
    }
    try {
      final statuses = await site.getLiveStatusByUids(uidToItems.keys.toList());
      if (generation != null && generation != _updateGeneration) {
        return; // 新一轮刷新已开始，丢弃本批结果
      }
      if (statuses.isEmpty) {
        return;
      }
      var applied = 0;
      uidToItems.forEach((uid, items) {
        final living = statuses[uid];
        if (living == null) {
          return;
        }
        for (final item in items) {
          item.liveStatus.value = living ? 2 : 1;
          if (!living) {
            item.liveStartTime = null;
            _liveNotifySentIds.remove(item.id);
          }
          _biliBatchCovered.add(item.id);
          SyncService.instance.publishLiveStatusItem(item.id, living ? 2 : 1);
          applied++;
        }
      });
      if (applied > 0) {
        Log.logPrint("B站批量状态：1 个请求更新 $applied 个房间（替代 $applied 次单查）");
      }
    } catch (e) {
      // 批量失败（风控/网络）：不阻断本轮，退回原有逐条单查兜底。
      Log.d("B站批量状态查询失败，回退逐条：$e");
    }
  }
}

enum _FollowRefreshItemOutcome {
  success,
  failed,
  deferred,
  skipped,
}

class _FollowRefreshItemResult {
  final _FollowRefreshItemOutcome outcome;
  final bool limited;
  final bool keepPending;
  final bool pauseRemaining;

  const _FollowRefreshItemResult(
    this.outcome, {
    this.limited = false,
    this.keepPending = false,
    this.pauseRemaining = false,
  });
}

class _RefreshTargetPolicyResult {
  final List<FollowUser> allowedTargets;
  final List<FollowUser> deferredTargets;
  final String toastMessage;

  const _RefreshTargetPolicyResult({
    required this.allowedTargets,
    required this.deferredTargets,
    this.toastMessage = "",
  });
}

class _PersistedFollowRefreshTaskState {
  final String scopeKey;
  final int total;
  final int successCount;
  final int failedCount;
  final int deferredCount;
  final List<String> orderedKeys;
  final List<String> pendingKeys;

  const _PersistedFollowRefreshTaskState({
    required this.scopeKey,
    required this.total,
    required this.successCount,
    required this.failedCount,
    required this.deferredCount,
    required this.orderedKeys,
    required this.pendingKeys,
  });

  factory _PersistedFollowRefreshTaskState.fromMaps(
    Map<String, dynamic> state,
    Map<String, dynamic> targets,
  ) {
    List<String> readList(dynamic value) {
      if (value is! List) {
        return const [];
      }
      return value.map((item) => item.toString()).toList();
    }

    return _PersistedFollowRefreshTaskState(
      scopeKey: state["scopeKey"]?.toString() ?? "",
      total: (state["total"] as num?)?.toInt() ?? 0,
      successCount: (state["successCount"] as num?)?.toInt() ?? 0,
      failedCount: (state["failedCount"] as num?)?.toInt() ?? 0,
      deferredCount: (state["deferredCount"] as num?)?.toInt() ?? 0,
      orderedKeys: readList(targets["orderedKeys"]),
      pendingKeys: readList(targets["pendingKeys"]),
    );
  }

}

/// B站状态请求「串行 + 最小间隔」门。
///
/// 家里四端（手机/iPad/WIN/TV）在同一局域网 = 同一公网 IP，而 B站风控按
/// IP 维度计：状态接口(get_info)在多 worker 并发下几十个请求几秒内打完，
/// 叠加多端后极易触发限频（-412/-509/-799），进一步被推成真人验证，
/// 连累弹幕 token 接口(getDanmuInfo)。这里强制 B站状态请求串行且间隔 ≥1s。
class _BiliStatusThrottle {
  _BiliStatusThrottle._();

  /// 自动轮询间隔（平稳、最保守）。
  static const Duration autoInterval = Duration(milliseconds: 1000);

  /// 手动刷新间隔（用户主动操作 → 适当加快，仍保持串行不突发）。
  static const Duration manualInterval = Duration(milliseconds: 400);

  static const Duration minInterval = autoInterval;
  Future<void> _chain = Future<void>.value();
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> wait({Duration? minInterval}) {
    final interval = minInterval ?? _BiliStatusThrottle.minInterval;
    final next = _chain.then((_) async {
      final now = DateTime.now();
      final elapsed = now.difference(_last);
      if (elapsed < interval) {
        await Future<void>.delayed(interval - elapsed);
      }
      _last = DateTime.now();
    });
    _chain = next;
    return next;
  }
}

final _biliStatusThrottle = _BiliStatusThrottle._();

class DouyinFollowRefreshLimiter {
  final int initialConcurrency;
  final Duration initialInterval;
  Duration _currentInterval;
  final Stopwatch _stopwatch = Stopwatch()..start();
  Future<void> _gate = Future.value();
  DateTime? _lastRequestAt;
  int _successCount = 0;
  int _limitedCount = 0;
  bool _cooledDown = false;

  DouyinFollowRefreshLimiter._({
    required this.initialConcurrency,
    required this.initialInterval,
  }) : _currentInterval = initialInterval;

  factory DouyinFollowRefreshLimiter.forTargetCount(int targetCount) {
    if (targetCount <= 20) {
      return DouyinFollowRefreshLimiter._(
        initialConcurrency: targetCount.clamp(1, 4).toInt(),
        initialInterval: const Duration(milliseconds: 220),
      );
    }
    if (targetCount <= 100) {
      return DouyinFollowRefreshLimiter._(
        initialConcurrency: 4,
        initialInterval: const Duration(milliseconds: 360),
      );
    }
    return DouyinFollowRefreshLimiter._(
      initialConcurrency: 4,
      initialInterval: const Duration(milliseconds: 520),
    );
  }

  Future<void> beforeRequest(int workerIndex) {
    final next = _gate.then((_) async {
      final lastRequestAt = _lastRequestAt;
      if (lastRequestAt != null) {
        final elapsed = DateTime.now().difference(lastRequestAt);
        if (elapsed < _currentInterval) {
          await Future.delayed(_currentInterval - elapsed);
        }
      }
      _lastRequestAt = DateTime.now();
    });
    _gate = next.catchError((_) {});
    return next;
  }

  void onSuccess() {
    _successCount++;
  }

  void onLimited() {
    _limitedCount++;
    _cooledDown = true;
    final nextMs = (_currentInterval.inMilliseconds * 1.8).round();
    _currentInterval = Duration(
      milliseconds: nextMs.clamp(600, 2600).toInt(),
    );
  }

  DouyinFollowRefreshSummary finish(int targetCount) {
    _stopwatch.stop();
    return DouyinFollowRefreshSummary(
      targetCount: targetCount,
      initialConcurrency: initialConcurrency,
      initialInterval: initialInterval,
      finalInterval: _currentInterval,
      successCount: _successCount,
      limitedCount: _limitedCount,
      cooledDown: _cooledDown,
      elapsed: _stopwatch.elapsed,
    );
  }
}

class DouyinFollowRefreshSummary {
  final int targetCount;
  final int initialConcurrency;
  final Duration initialInterval;
  final Duration finalInterval;
  final int successCount;
  final int limitedCount;
  final bool cooledDown;
  final Duration elapsed;

  const DouyinFollowRefreshSummary({
    required this.targetCount,
    required this.initialConcurrency,
    required this.initialInterval,
    required this.finalInterval,
    required this.successCount,
    required this.limitedCount,
    required this.cooledDown,
    required this.elapsed,
  });
}

/// 关注刷新链路的房间详情请求门控：同房间合并 + 平台级最小间隔。
///
/// 只用于「不要求实时」的关注刷新（身份同步/已播时长/封面帧），
/// 不用于进房解析 —— 后者必须拿最新 roomId，不能被合并或延迟。
class _RoomDetailGate {
  /// 同一平台两次详情请求之间的最小间隔（削峰用，不追求严格串行）。
  static const Duration minPlatformInterval = Duration(milliseconds: 150);

  /// 同一房间在这个窗口内的重复请求共享一次真实请求结果。
  static const Duration mergeWindow = Duration(milliseconds: 800);

  final Map<String, Future<LiveRoomDetail>> _inflight = {};
  final Map<String, DateTime> _lastPlatformRequestAt = {};

  Future<LiveRoomDetail> fetch({
    required String siteId,
    required String roomId,
    required Future<LiveRoomDetail> Function() request,
  }) async {
    final key = "$siteId|$roomId";
    final ongoing = _inflight[key];
    if (ongoing != null) {
      return ongoing;
    }
    final future = _requestWithPlatformGap(siteId, request);
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      Future<void>.delayed(mergeWindow, () => _inflight.remove(key));
    }
  }

  Future<LiveRoomDetail> _requestWithPlatformGap(
    String siteId,
    Future<LiveRoomDetail> Function() request,
  ) async {
    final last = _lastPlatformRequestAt[siteId];
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      if (elapsed < minPlatformInterval) {
        await Future<void>.delayed(minPlatformInterval - elapsed);
      }
    }
    _lastPlatformRequestAt[siteId] = DateTime.now();
    return request();
  }
}
