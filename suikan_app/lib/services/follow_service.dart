import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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

class FollowService extends GetxService {
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

  /// 最近一次撞平台限流（如抖音 444）的时刻：用于自动刷新退避降频。
  DateTime? _lastPlatformLimitedAt;
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
    initTimer();
    // 局域网共享状态回写：其它端（如 TV）刚拉到的 B站 状态，本端拿到后
    // 立即更新列表显示，不用等本端 10 分钟轮询，也不产生任何公网请求。
    if (Get.isRegistered<SyncService>()) {
      SyncService.instance.onPeerLiveStatus = _applySharedLiveStatus;
      // 启动时也主动问一次（SyncService 内部另有 1-3s 首次查询兜底）。
      unawaited(SyncService.instance.queryPeersLiveStatus());
    }
    super.onInit();
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

  /// 进直播间后把最新标题（以及可选封面）回写到关注项。
  ///
  /// 背景：主播改标题是高频操作，而关注列表的标题只在“补详情”链路更新；
  /// 非抖音平台的定时/进页刷新只取开播时间不写标题，手动刷新又是纯状态轮，
  /// 于是列表里的标题会长期停留在关注时的旧值。
  ///
  /// 进房本身一定会拉一次详情（[LiveRoomDetail]），这里顺手把标题同步掉，
  /// 不加任何额外请求。封面只在「展示直播封面」开启时同步 —— 关掉时用户
  /// 不要实时画面帧，就没必要把 keyframe/截图 URL 写进本地。
  void syncFollowRoomMeta({
    required String siteId,
    required String roomId,
    required String title,
    String cover = "",
    String? altRoomId,
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
    if (!AppSettingsController.instance.autoUpdateFollowEnable.value) {
      return;
    }
    // 首次启动加 0–30s 随机抖动（多端错开），之后按"分级变速"排期。
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

  void _scheduleNextAutoRefresh() {
    updateTimer?.cancel();
    if (isClosed ||
        !AppSettingsController.instance.autoUpdateFollowEnable.value) {
      return;
    }
    final interval = _nextAutoRefreshInterval();
    Log.logPrint("下次关注自动刷新：${interval.inSeconds}s");
    updateTimer = Timer(interval, () async {
      await loadData();
      _scheduleNextAutoRefresh();
    });
  }

  Future<void> loadData({
    bool updateStatus = true,
    bool forceUpdateStatus = false,
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
      ));
    }
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
  }) async {
    final previousStatus = item.liveStatus.value;
    final notifyReady = _liveNotifyReadyIds.contains(item.id);
    try {
      // ① 全平台通用：优先用局域网共享快照（其它端刚拉过 → 本端 0 公网请求，
      //    虎牙/斗鱼/快手/抖音/B站 一视同仁）。
      //    ⚠️ 命中时**不能直接 return**：后面的"详情/直播封面帧/已播时长、
      //    抖音身份校正"等逻辑必须照常执行（尤其开启「展示直播封面」时），
      //    这里只把"状态请求"这一项跳过。
      final shared = SyncService.instance.sharedLiveStatus(item.id);
      final trustShared = useSharedStatus && shared != null;
      if (shared != null) {
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
      if (trustShared) {
        // 自动轮询命中快照：只省掉状态请求，下方详情/封面流程照跑。
        isLiving = shared == 2;
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

      while (pendingKeys.isNotEmpty) {
        final taskQueue = Queue<FollowUser>.from(
          pendingKeys.map((key) => targetByKey[key]).whereType<FollowUser>(),
        );
        pausedForResume = false;

        Future<void> worker(int workerId) async {
          while (taskQueue.isNotEmpty) {
            if (generation != _updateGeneration || pausedForResume) {
              return;
            }
            var item = taskQueue.removeFirst();
            final result = await _updateLiveStatus(
              item,
              generation: generation,
              douyinLimiter: douyinLimiter,
              workerIndex: workerId,
              pauseRemainingOnLimited: scope.includeAllNormals,
              statusOnly: statusOnly,
              // force（手动刷新）时不走共享快照：用户手动刷就要拿最新。
              useSharedStatus: !force,
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
    updateTimer?.cancel();
    _eventReloadTimer?.cancel();
    subscription?.cancel();
    super.onClose();
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
