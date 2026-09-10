import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/services/current_room_service.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:simple_live_tv_app/services/local_storage_service.dart';
import 'package:simple_live_tv_app/services/sync_service.dart';

class FollowUserService extends BasePageController<FollowUser> {
  static const Duration updateStatusCooldown = Duration(seconds: 10);
  static const Duration refreshProgressCompletionHold = Duration(seconds: 2);
  static const int paginationThreshold = 400;
  static const String _refreshTaskStateStorageKey =
      LocalStorageService.kFollowRefreshTaskState;
  static const String _refreshTaskTargetsStorageKey =
      LocalStorageService.kFollowRefreshTaskTargets;

  static FollowUserService get instance => Get.find<FollowUserService>();

  StreamSubscription<dynamic>? subscription;
  RxList<FollowUser> allList = RxList<FollowUser>();
  RxList<FollowUser> livingList = RxList<FollowUser>();
  final Set<String> _previewRefreshingKeys = <String>{};
  var searchKeyword = "".obs;
  var currentDisplayPage = 1.obs;
  var totalDisplayPages = 1.obs;
  var paginationEnabled = false.obs;
  var updating = false.obs;
  var refreshProgress = const FollowRefreshProgress.idle().obs;

  Timer? updateTimer;
  /// 首次轮询的随机抖动定时器（多端错开，见 [initTimer]）。
  Timer? _biliJitterTimer;

  /// 最近一次撞平台限流（如抖音 444）的时刻：用于自动刷新退避降频。
  DateTime? _lastPlatformLimitedAt;

  /// 本轮已由「B站 批量状态接口」覆盖的房间（见 [_prefetchBiliStatusBatch]）：
  /// 这些房间本轮不再逐条单查，避免重复请求。
  final Set<String> _biliBatchCovered = <String>{};

  /// 持久化 roomId → 主播 uid 映射的设置键（有 uid 才能走批量接口）。
  static const String _kBiliAnchorUids = "BiliAnchorUids";
  Timer? _eventReloadTimer;
  Timer? _refreshProgressResetTimer;
  bool needUpdate = true;
  int _updateGeneration = 0;
  DateTime? _lastUpdateStatusStartedAt;
  DateTime? _lastEnterRefreshAt;
  bool _enterRefreshInFlight = false;
  bool _forceNextStatusRefresh = false;
  bool _startupRefreshInFlight = false;

  FollowUserService() {
    pageSize = AppSettingsController.kFollowPageSizeDefault;
  }

  @override
  void onInit() {
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (p0) {
      needUpdate = false;
      // 延迟 150ms 再刷新，避免同步完成瞬间并发触发大量状态请求拖慢界面。
      _eventReloadTimer?.cancel();
      _eventReloadTimer = Timer(const Duration(milliseconds: 150), () {
        refreshData(forceStatus: false);
      });
    });

    // 启动：先加载本地关注列表（轻量、不阻塞首帧），随后异步刷新一次主播状态，
    // 让用户一进首页就看到当前谁在播。状态刷新走 startUpdateStatus 的并发限流
    // （自动 2~4 并发 worker 队列），几百个关注也是分批刷、不会同时打爆；旧的
    // 「启动全量刷新会拖死盒子」顾虑已不成立（并发早已限流）。unawaited 保证不
    // 阻塞首帧，刷新期间 UI 先显示本地缓存的在线状态、刷完自动更新。
    unawaited(_startupLoadAndRefresh());
    // 恢复上次学到的 B站 roomId→uid 映射：有 uid 就能用批量状态接口
    // 一次查完所有 B站 关注（否则每轮首刷只能逐条单查学 uid）。
    _restoreBiliUids();
    initTimer();
    // 局域网共享状态回写：其它端（如手机/WIN）刚拉到的状态，本端拿到后
    // 立即更新列表显示，不用等本端 10 分钟轮询，也不产生任何公网请求。
    _registerPeerStatusCallback();
    super.onInit();
  }

  /// 注册「拿到其它端快照 → 立即回写列表」的回调（有限次延时重试，
  /// 防止 SyncService 注册顺序晚于本服务时静默跳过，导致共享状态不生效）。
  void _registerPeerStatusCallback({int attempt = 0}) {
    if (isClosed) {
      return;
    }
    if (Get.isRegistered<SyncService>()) {
      SyncService.instance.onPeerLiveStatus = _applySharedLiveStatus;
      unawaited(SyncService.instance.queryPeersLiveStatus());
      return;
    }
    if (attempt >= 12) {
      return; // ≈3s 内仍未注册，放弃（不影响任何功能）
    }
    Future.delayed(const Duration(milliseconds: 250), () {
      _registerPeerStatusCallback(attempt: attempt + 1);
    });
  }

  /// 应用局域网共享的直播状态到关注列表（全平台、纯内存、零公网请求）。
  void _applySharedLiveStatus(Map<String, int> items) {
    if (items.isEmpty || allList.isEmpty) {
      return;
    }
    for (final item in allList) {
      final status = items[item.id];
      if (status == null || item.liveStatus.value == status) {
        continue;
      }
      item.liveStatus.value = status;
    }
  }

  /// 启动加载 + 刷新：先加载本地关注列表，再异步刷新一次主播状态。
  /// 串行执行（先 await 加载完、再刷新）避免和 refreshData 内部的 loadLocalList
  /// 并发竞态；由 onInit 以 unawaited 调用，不阻塞首帧。
  Future<void> _startupLoadAndRefresh() async {
    await refreshData(forceStatus: false);
    await _startAutomaticRefresh();
  }

  /// Load local follows immediately, then perform one status refresh before
  /// the home page is shown when periodic automatic refresh is enabled.
  Future<void> _refreshOnHomeStartup() async {
    if (_startupRefreshInFlight ||
        !AppSettingsController.instance.autoUpdateFollowEnable.value) {
      return;
    }
    loadLocalList();
    if (allList.isEmpty || updating.value) {
      return;
    }
    _startupRefreshInFlight = true;
    try {
      await _startAutomaticRefresh();
    } finally {
      _startupRefreshInFlight = false;
    }
  }

  Future<void> refreshImmediatelyIfAutomaticEnabled() {
    return _refreshOnHomeStartup();
  }

  void initTimer() {
    _biliJitterTimer?.cancel();
    updateTimer?.cancel();
    if (!AppSettingsController.instance.autoUpdateFollowEnable.value) {
      updateTimer = null;
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
    final liveCount =
        allList.where((e) => e.liveStatus.value == 2).length;
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
      if (updating.value) {
        Log.logPrint("上一轮仍在刷新，跳过本次自动刷新");
      } else {
        await _startAutomaticRefresh();
      }
      _scheduleNextAutoRefresh();
    });
  }

  Future<void> _startAutomaticRefresh() async {
    loadLocalList();
    final targets = _buildRefreshTargets(allList, includeAllNormals: true);
    if (targets.isEmpty) {
      return;
    }
    await startUpdateStatus(
      targets,
      force: false,
      scope: const FollowRefreshScope.all(automatic: true),
    );
  }

  void loadLocalList() {
    pageSize = AppSettingsController.instance.followPageSize.value;
    allList.assignAll(
      _sortFollowUsers(
          _distinctFollowUsers(DBService.instance.getFollowList())),
    );
    updateLivingList();
    sortList();
    if (allList.isEmpty) {
      updating.value = false;
    }
  }

  Future<void> onFollowPageEntered() async {
    loadLocalList();
    final now = DateTime.now();
    final shouldRefresh =
        AppSettingsController.instance.followRefreshOnEnter.value &&
            allList.isNotEmpty &&
            !updating.value &&
            !_enterRefreshInFlight &&
            (_lastEnterRefreshAt == null ||
                now.difference(_lastEnterRefreshAt!) >=
                    BasePageController.refreshCooldown);
    if (shouldRefresh) {
      _lastEnterRefreshAt = now;
      _enterRefreshInFlight = true;
      final refreshFuture = startUpdateStatus(
        _buildRefreshTargets(allList, includeAllNormals: true),
        force: false,
        scope: const FollowRefreshScope.all(automatic: true),
      );
      // Keep rapid route rebuilds from launching a second full refresh.
      unawaited(
        refreshFuture.whenComplete(() => _enterRefreshInFlight = false),
      );
    }
  }

  @override
  Future refreshData({bool forceStatus = true}) async {
    pageSize = AppSettingsController.instance.followPageSize.value;
    _forceNextStatusRefresh = forceStatus;
    await super.refreshData();
  }

  @override
  Future<List<FollowUser>> getData(int page, int pageSize) async {
    if (page == 1) {
      loadLocalList();
      if (needUpdate && _forceNextStatusRefresh) {
        unawaited(
          startUpdateStatus(
            allList.toList(),
            force: _forceNextStatusRefresh,
            statusOnly: _forceNextStatusRefresh,
          ),
        );
      }
      _forceNextStatusRefresh = false;
      needUpdate = true;
      if (allList.isEmpty) {
        updating.value = false;
      }
    }

    final displayList = _buildDisplaySource();
    paginationEnabled.value = displayList.length > paginationThreshold;
    if (!paginationEnabled.value) {
      currentDisplayPage.value = 1;
      totalDisplayPages.value = 1;
      return displayList;
    }

    final effectivePageSize = _effectivePageSizeFor(displayList.length);
    final pageCount = _pageCountFor(displayList.length);
    final safePage = currentDisplayPage.value.clamp(1, pageCount);
    currentDisplayPage.value = safePage;
    totalDisplayPages.value = pageCount;

    final start = (safePage - 1) * effectivePageSize;
    if (start >= displayList.length) {
      return [];
    }
    final end =
        (start + effectivePageSize).clamp(0, displayList.length).toInt();
    return displayList.sublist(start, end);
  }

  void sortList() {
    allList.assignAll(_sortFollowUsers(allList));
    final displayList = _buildDisplaySource();
    paginationEnabled.value = displayList.length > paginationThreshold;
    if (!paginationEnabled.value) {
      currentDisplayPage.value = 1;
      totalDisplayPages.value = 1;
      list.assignAll(displayList);
    } else {
      final pageCount = _pageCountFor(displayList.length);
      totalDisplayPages.value = pageCount;
      if (currentDisplayPage.value > pageCount) {
        currentDisplayPage.value = pageCount;
      }
      if (currentDisplayPage.value < 1) {
        currentDisplayPage.value = 1;
      }
      final pageSize = _effectivePageSizeFor(displayList.length);
      final start = (currentDisplayPage.value - 1) * pageSize;
      final end = (start + pageSize).clamp(0, displayList.length).toInt();
      list.assignAll(displayList.sublist(start, end));
    }
    currentPage = currentDisplayPage.value;
    canLoadMore.value = false;
    updateLivingList();
  }

  int _effectivePageSizeFor(int total) {
    if (total <= paginationThreshold) {
      return total <= 0 ? pageSize : total;
    }
    final maxPageSize = ((total / 2).floor() + 1).clamp(2, total).toInt();
    final effective = AppSettingsController.instance.followPageSize.value
        .clamp(2, maxPageSize)
        .toInt();
    if (effective != AppSettingsController.instance.followPageSize.value) {
      AppSettingsController.instance.setFollowPageSize(effective);
    }
    pageSize = effective;
    return effective;
  }

  int _pageCountFor(int total) {
    if (total <= paginationThreshold) {
      return 1;
    }
    return (total / _effectivePageSizeFor(total)).ceil().clamp(1, total);
  }

  void applyPageSizeSetting() {
    currentDisplayPage.value = 1;
    sortList();
  }

  List<FollowUser> get currentPageTargets => list.toList();

  String get currentRefreshScopeKey => "page:${currentDisplayPage.value}";

  Future<void> refreshCurrentPageStatus() async {
    await startUpdateStatus(
      paginationEnabled.value ? currentPageTargets : _buildDisplaySource(),
      force: true,
      statusOnly: true,
      scope: FollowRefreshScope.page(scopeKey: currentRefreshScopeKey),
    );
  }

  Future<void> refreshAllStatus() async {
    await startUpdateStatus(
      _buildRefreshTargets(allList, includeAllNormals: true),
      force: true,
      statusOnly: true,
      scope: const FollowRefreshScope.all(),
    );
  }

  List<FollowUser> _buildDisplaySource() {
    Iterable<FollowUser> items = allList;
    if (AppSettingsController.instance.followOnlyLive.value) {
      items = items.where((item) => item.liveStatus.value == 2);
    }
    final keyword = searchKeyword.value.trim().toLowerCase();
    if (keyword.isNotEmpty) {
      items = items.where(
        (item) => item.userName.toLowerCase().contains(keyword),
      );
    }
    return _sortFollowUsers(items);
  }

  void setSearchKeyword(String value) {
    searchKeyword.value = value.trim();
    currentDisplayPage.value = 1;
    sortList();
  }

  void clearSearchKeyword() {
    if (searchKeyword.value.isEmpty) {
      return;
    }
    searchKeyword.value = "";
    currentDisplayPage.value = 1;
    sortList();
  }

  void setDisplayStyle(String value) {
    AppSettingsController.instance.setFollowDisplayStyle(value);
    sortList();
  }

  void setOnlyLive(bool value) {
    AppSettingsController.instance.setFollowOnlyLive(value);
    currentDisplayPage.value = 1;
    sortList();
  }

  void setRefreshOnEnter(bool value) {
    AppSettingsController.instance.setFollowRefreshOnEnter(value);
  }

  void setShowLiveCover(bool value) {
    AppSettingsController.instance.setFollowShowLiveCover(value);
    sortList();
  }

  List<FollowUser> _buildRefreshTargets(
    Iterable<FollowUser> normalTargets, {
    bool includeAllNormals = false,
  }) {
    final specials = allList.where((item) => item.isSpecialFollow).toList();
    final normals = includeAllNormals
        ? allList.where((item) => !item.isSpecialFollow).toList()
        : normalTargets.where((item) => !item.isSpecialFollow).toList();
    return _distinctFollowUsers([
      ..._sortFollowUsers(specials),
      ..._sortFollowUsers(normals),
    ]);
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

  List<FollowUser> _distinctFollowUsers(Iterable<FollowUser> items) {
    final result = <FollowUser>[];
    final seenIds = <String>{};
    for (final item in items) {
      final siteId = item.siteId.trim();
      final roomId = item.roomId.trim();
      final uniqueId =
          siteId.isEmpty || roomId.isEmpty ? item.id.trim() : "$siteId|$roomId";
      if (seenIds.add(uniqueId)) {
        result.add(item);
      }
    }
    return result;
  }

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
    // Fix TV多开灰屏: 频繁写入导致localstorage膨胀，compact防止文件过大
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

  void goToNextPage() {
    if (!paginationEnabled.value ||
        currentDisplayPage.value >= totalDisplayPages.value) {
      return;
    }
    currentDisplayPage.value += 1;
    sortList();
  }

  void goToPreviousPage() {
    if (!paginationEnabled.value || currentDisplayPage.value <= 1) {
      return;
    }
    currentDisplayPage.value -= 1;
    sortList();
  }

  List<FollowUser> _sortFollowUsers(Iterable<FollowUser> items) {
    return items.toList()..sort(compareFollowUsers);
  }

  int compareFollowUsers(FollowUser a, FollowUser b) {
    if (a.isSpecialFollow != b.isSpecialFollow) {
      return a.isSpecialFollow ? -1 : 1;
    }
    final aLiving = a.liveStatus.value == 2;
    final bLiving = b.liveStatus.value == 2;
    if (aLiving != bLiving) {
      return aLiving ? -1 : 1;
    }
    return b.addTime.compareTo(a.addTime);
  }

  void updateLivingList() {
    livingList.assignAll(
      _sortFollowUsers(allList.where((x) => x.liveStatus.value == 2)),
    );
  }

  int _getConcurrency(
    int total,
  ) {
    if (total <= 0) {
      return 1;
    }
    final manual =
        AppSettingsController.instance.effectiveUpdateFollowThreadCount;
    var concurrency = 8;
    if (manual > 0) {
      concurrency = manual.clamp(1, total).toInt();
    } else if (total <= 50) {
      concurrency = total < 2 ? total : 2;
    } else if (total <= 200) {
      concurrency = 3;
    } else {
      concurrency = 4;
    }
    return concurrency.clamp(1, total).toInt();
  }

  List<FollowUser> _buildManualDetailTargets(List<FollowUser> items) {
    final candidates = _distinctFollowUsers(
      items.where(
        (item) => item.siteId == Constant.kDouyin || item.liveStatus.value == 2,
      ),
    ).toList();
    return _deprioritizeCurrentRoom(_interleaveByPlatform(candidates));
  }

  String _detailRefreshStageLabel() => "正在补齐封面与标题";

  String _metadataFailureLabel(bool reconcileDouyinIdentity) {
    return reconcileDouyinIdentity ? "TV 关注详情补齐失败" : "TV 关注封面补齐失败";
  }

  String _metadataPhaseLogLabel(bool reconcileDouyinIdentity) {
    return reconcileDouyinIdentity ? "关注详情补齐阶段" : "关注封面补齐阶段";
  }

  String _metadataPhaseSummaryLabel(bool reconcileDouyinIdentity) {
    return reconcileDouyinIdentity ? "关注详情补齐" : "关注封面补齐";
  }

  String _metadataPhaseDetail(bool reconcileDouyinIdentity, int count) {
    final label = _metadataPhaseSummaryLabel(reconcileDouyinIdentity);
    return "$label完成 $count";
  }

  String _metadataPhaseDoneDetail(
    bool reconcileDouyinIdentity,
    int successCount,
    int failedCount,
  ) {
    final label = _metadataPhaseSummaryLabel(reconcileDouyinIdentity);
    if (failedCount <= 0) {
      return "$label完成 $successCount";
    }
    return "$label完成 $successCount  失败 $failedCount";
  }

  String _metadataPhaseLog(bool reconcileDouyinIdentity, int count) {
    final label = _metadataPhaseLogLabel(reconcileDouyinIdentity);
    return "$label开始，总数: $count";
  }

  String _metadataPhaseLogDone(
    bool reconcileDouyinIdentity,
    int successCount,
    int failedCount,
  ) {
    final label = _metadataPhaseLogLabel(reconcileDouyinIdentity);
    return "$label完成，成功: $successCount，失败: $failedCount";
  }

  String _metadataScopeStage(bool reconcileDouyinIdentity) {
    return reconcileDouyinIdentity ? _detailRefreshStageLabel() : "正在补齐预览";
  }

  int _capConcurrencyForCurrentContext(int value) {
    if (CurrentRoomService.instance.siteId.value == Constant.kDouyin) {
      return value.clamp(1, 4).toInt();
    }
    return value;
  }

  int _previewMetadataWorkerCount(List<FollowUser> orderedTargets) {
    final hasOthers = orderedTargets.any(
      (item) => item.siteId != Constant.kDouyin,
    );
    if (!hasOthers) {
      return 1;
    }
    return _capConcurrencyForCurrentContext(2);
  }

  int _detailMetadataWorkerCount(List<FollowUser> orderedTargets) {
    final hasOthers = orderedTargets.any(
      (item) => item.siteId != Constant.kDouyin,
    );
    if (!hasOthers) {
      return 1;
    }
    return _capConcurrencyForCurrentContext(2);
  }

  String _metadataStageProgressDetail(
    bool reconcileDouyinIdentity,
    int successCount,
    int failedCount,
  ) {
    if (failedCount <= 0) {
      return _metadataPhaseDetail(reconcileDouyinIdentity, successCount);
    }
    return _metadataPhaseDoneDetail(
      reconcileDouyinIdentity,
      successCount,
      failedCount,
    );
  }

  bool _shouldRefreshMetadataProgress(String? progressScopeKey) {
    return progressScopeKey != null && progressScopeKey.isNotEmpty;
  }

  int _normalizedMetadataCurrent(int current, int total) {
    return current.clamp(0, total).toInt();
  }

  int _normalizedMetadataTotal(int total) {
    return total < 0 ? 0 : total;
  }

  int _normalizedMetadataFailed(int failedCount) {
    return failedCount < 0 ? 0 : failedCount;
  }

  int _normalizedMetadataSuccess(int successCount) {
    return successCount < 0 ? 0 : successCount;
  }

  int _normalizedMetadataSkipped(int skippedCount) {
    return skippedCount < 0 ? 0 : skippedCount;
  }

  void _setMetadataRefreshProgress({
    required bool reconcileDouyinIdentity,
    required bool automatic,
    required String? progressScopeKey,
    required int current,
    required int total,
    required int successCount,
    required int failedCount,
    bool completed = false,
  }) {
    if (!_shouldRefreshMetadataProgress(progressScopeKey)) {
      return;
    }
    final normalizedTotal = _normalizedMetadataTotal(total);
    _setRefreshProgress(
      active: !completed,
      automatic: automatic,
      scopeKey: progressScopeKey!,
      stage: _metadataScopeStage(reconcileDouyinIdentity),
      current: _normalizedMetadataCurrent(current, normalizedTotal),
      total: normalizedTotal,
      successCount: _normalizedMetadataSuccess(successCount),
      failedCount: _normalizedMetadataFailed(failedCount),
      skippedCount: _normalizedMetadataSkipped(0),
      completed: completed,
      detail: _metadataStageProgressDetail(
        reconcileDouyinIdentity,
        successCount,
        failedCount,
      ),
    );
  }

  int _metadataWorkerCount(
    List<FollowUser> orderedTargets, {
    required bool reconcileDouyinIdentity,
  }) {
    final manual =
        AppSettingsController.instance.effectiveUpdateFollowThreadCount;
    if (manual > 0) {
      return _capConcurrencyForCurrentContext(
        manual.clamp(1, orderedTargets.length).toInt(),
      );
    }
    return reconcileDouyinIdentity
        ? _detailMetadataWorkerCount(orderedTargets)
        : _previewMetadataWorkerCount(orderedTargets);
  }

  String _getConcurrencyMode() {
    final manual =
        AppSettingsController.instance.effectiveUpdateFollowThreadCount;
    return manual > 0 ? "手动($manual)" : "自动";
  }

  List<FollowUser> _interleaveByPlatform(List<FollowUser> items) {
    final grouped = <String, Queue<FollowUser>>{};
    for (final item in items) {
      grouped.putIfAbsent(item.siteId, () => Queue<FollowUser>()).add(item);
    }

    final result = <FollowUser>[];
    while (grouped.values.any((queue) => queue.isNotEmpty)) {
      for (final queue in grouped.values) {
        if (queue.isNotEmpty) {
          result.add(queue.removeFirst());
        }
      }
    }
    return result;
  }

  List<FollowUser> _deprioritizeCurrentRoom(List<FollowUser> items) {
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

  Future<void> startUpdateStatus(
    List<FollowUser> followList, {
    bool force = false,
    FollowRefreshScope? scope,
    bool statusOnly = false,
  }) async {
    final resolvedScope = scope ?? FollowRefreshScope.all(automatic: !force);
    final now = DateTime.now();
    final lastStartedAt = _lastUpdateStatusStartedAt;
    if (!force &&
        lastStartedAt != null &&
        now.difference(lastStartedAt) < updateStatusCooldown) {
      Log.logPrint("关注状态刷新过于频繁，已跳过本次网络刷新");
      updating.value = false;
      _resetRefreshProgress();
      sortList();
      return;
    }

    if (updating.value &&
        refreshProgress.value.active &&
        refreshProgress.value.scopeKey == resolvedScope.scopeKey &&
        !refreshProgress.value.completed) {
      Log.logPrint("同一刷新任务仍在进行，复用当前进度: ${resolvedScope.scopeKey}");
      return;
    }

    _lastUpdateStatusStartedAt = now;
    final generation = ++_updateGeneration;
    final automatic = resolvedScope.automatic;
    _cancelRefreshProgressReset();
    if (updating.value) {
      Log.logPrint("已有关注状态刷新任务，旧任务会被新任务替换");
    }
    updating.value = true;
    _setRefreshProgress(
      active: true,
      automatic: automatic,
      scopeKey: resolvedScope.scopeKey,
      stage: resolvedScope.stage,
      current: 0,
      total: followList.length,
    );

    try {
      if (followList.isEmpty) {
        sortList();
        return;
      }

      final concurrency = _getConcurrency(
        followList.length,
      );
      final hasFullDouyinCookie = DouyinCookieHelper.hasFullCookie(
        (Sites.allSites[Constant.kDouyin]?.liveSite as DouyinSite?)?.cookie ??
            "",
      );
      Log.logPrint(
        "开始更新关注状态，并发数: $concurrency，模式: ${_getConcurrencyMode()}，总数: ${followList.length}，"
        "scope=${resolvedScope.scopeKey} fullDouyinCookie=$hasFullDouyinCookie",
      );

      final orderedTargets = _deprioritizeCurrentRoom(
        _interleaveByPlatform(followList),
      );
      final filteredTargets = _applyDouyinRefreshPolicy(
        orderedTargets,
        scope: resolvedScope,
        hasFullDouyinCookie: hasFullDouyinCookie,
      );
      final allowedTargets = filteredTargets.allowedTargets;
      final orderedAllowedKeys = allowedTargets.map(_refreshTargetKey).toList();
      final targetByKey = <String, FollowUser>{
        for (final item in allowedTargets) _refreshTargetKey(item): item,
      };
      final persistedTask = _loadPersistedRefreshTask(resolvedScope.scopeKey);
      final resumeTask = resolvedScope.includeAllNormals &&
          persistedTask != null &&
          _sameStringList(persistedTask.orderedKeys, orderedAllowedKeys) &&
          persistedTask.pendingKeys.isNotEmpty;
      final pendingKeys = resumeTask
          ? persistedTask.pendingKeys
              .where(targetByKey.containsKey)
              .toList(growable: true)
          : orderedAllowedKeys.toList(growable: true);
      final taskQueue = Queue<FollowUser>.from(
        pendingKeys.map((key) => targetByKey[key]).whereType<FollowUser>(),
      );
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

      if (resolvedScope.includeAllNormals) {
        unawaited(
          _persistRefreshTask(
            scope: resolvedScope,
            total: followList.length,
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
          "抖音全量刷新受限：scope=${resolvedScope.scopeKey} deferred=$deferredCount "
          "allowedDouyin=$douyinTargetCount requiresFullCookie=true",
        );
        if (filteredTargets.toastMessage.isNotEmpty) {
          SmartDialog.showToast(filteredTargets.toastMessage);
        }
      }
      if (resumeTask) {
        Log.logPrint(
          "继续上次未完成的全量关注刷新：scope=${resolvedScope.scopeKey} remaining=$pendingKeys.length",
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
          scopeKey: resolvedScope.scopeKey,
          stage: resolvedScope.stage,
          current: completed,
          total: followList.length,
          successCount: successCount,
          failedCount: failedCount,
          deferredCount: deferredCount,
          detail: detail,
          completed: done,
        );
      }

      updateProgress(active: true, done: false);

      // B站 批量状态预取：1 个请求替代 N 次单查（已覆盖的项在 worker 中跳过单查）。
      await _prefetchBiliStatusBatch(
        generation: generation,
        useSharedStatus: automatic,
      );
      unawaited(_persistBiliUids());

      Future<void> worker(int workerIndex) async {
        while (taskQueue.isNotEmpty) {
          if (generation != _updateGeneration || pausedForResume) {
            return;
          }
          final item = taskQueue.removeFirst();
          final result = await _updateLiveStatus(
            item,
            generation: generation,
            douyinLimiter: douyinLimiter,
            workerIndex: workerIndex,
            // 自动轮询才用局域网共享快照；手动/启动刷新（automatic=false）
            // 一律自己拉，保证用户主动刷时拿到最新状态。
            useSharedStatus: automatic,
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
          if (resolvedScope.includeAllNormals) {
            unawaited(
              _persistRefreshTask(
                scope: resolvedScope,
                total: followList.length,
                orderedKeys: orderedAllowedKeys,
                pendingKeys: pendingKeys,
                successCount: successCount,
                failedCount: failedCount,
                deferredCount: deferredCount,
              ),
            );
          }
          updateProgress(active: true, done: false);
        }
      }

      final workers = <Future<void>>[];
      for (var i = 0; i < concurrency; i++) {
        workers.add(worker(i));
      }
      await Future.wait(workers);

      if (generation != _updateGeneration) {
        return;
      }
      sortList();
      if (douyinLimiter != null) {
        final summary = douyinLimiter.finish(douyinTargetCount);
        Log.logPrint(
          "抖音关注刷新总结 scope=${resolvedScope.scopeKey} target=${summary.targetCount} "
          "startConcurrency=${summary.initialConcurrency} "
          "startInterval=${summary.initialInterval.inMilliseconds}ms "
          "finalInterval=${summary.finalInterval.inMilliseconds}ms "
          "success=${summary.successCount} limited=${summary.limitedCount} "
          "cooldown=${summary.cooledDown} elapsed=${summary.elapsed.inMilliseconds}ms "
          "failed=$failedCount deferred=$deferredCount limitedObserved=$limitedCount",
        );
      }
      if (pendingKeys.isNotEmpty) {
        deferredCount =
            filteredTargets.deferredTargets.length + pendingKeys.length;
      }
      updateProgress(active: false, done: true);
      if (resolvedScope.includeAllNormals) {
        if (pendingKeys.isEmpty) {
          await _clearPersistedRefreshTask();
        } else {
          await _persistRefreshTask(
            scope: resolvedScope,
            total: followList.length,
            orderedKeys: orderedAllowedKeys,
            pendingKeys: pendingKeys,
            successCount: successCount,
            failedCount: failedCount,
            deferredCount: deferredCount,
          );
        }
      }
      if (!automatic && !statusOnly && generation == _updateGeneration) {
        final detailTargets = _buildManualDetailTargets(followList);
        if (detailTargets.isNotEmpty) {
          Log.logPrint(
            "${_metadataPhaseLog(true, detailTargets.length)}，scope=${resolvedScope.scopeKey}",
          );
          await _refreshMetadataTargets(
            detailTargets,
            reconcileDouyinIdentity: true,
            progressScopeKey: resolvedScope.scopeKey,
            automatic: automatic,
          );
        }
      }
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

  Future<_FollowRefreshItemResult> _updateLiveStatus(
    FollowUser item, {
    int? generation,
    DouyinFollowRefreshLimiter? douyinLimiter,
    int workerIndex = 0,
    bool useSharedStatus = true,
  }) async {
    try {
      // ① 全平台通用：优先用局域网共享快照（其它端刚拉过 → 本端 0 公网请求）。
      //    ⚠️ 命中时**不能直接 return**：后面的"详情/直播封面帧"等逻辑必须
      //    照常执行（开启「展示直播封面」时尤其需要），只跳过状态请求本身。
      final shared = SyncService.instance.sharedLiveStatus(item.id);
      // 本轮已被 B站 批量接口覆盖（见 [_prefetchBiliStatusBatch]）：状态已是
      // 最新（且已发布快照），这里只跳过"状态请求"，详情/封面流程照跑。
      final batchCovered = _biliBatchCovered.remove(item.id);
      final trustShared = batchCovered || (useSharedStatus && shared != null);
      if (!batchCovered && shared != null) {
        item.liveStatus.value = shared;
      }
      final site = Sites.allSites[item.siteId]!;
      final bool isLiving;
      if (batchCovered) {
        // 批量接口已把最新状态写在 item 上，直接用（shared 为 null 时
        // 不能拿它判断，否则会被误判成"未开播"）。
        isLiving = item.liveStatus.value == 2;
      } else if (trustShared) {
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
        // 全平台：把本机拉到的状态发布成本机快照，供其它端取用。
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
      await DBService.instance.addFollow(item);
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
          _handleDouyinLimited();
        } else {
          _handleDouyinLimited();
        }
      }
      Log.logPrint(e);
      if (limited) {
        return const _FollowRefreshItemResult(
          _FollowRefreshItemOutcome.deferred,
          limited: true,
          keepPending: true,
          pauseRemaining: true,
        );
      }
      return _FollowRefreshItemResult(
        _FollowRefreshItemOutcome.failed,
        limited: limited,
      );
    }
  }

  Future<void> _reconcileDouyinFollowIdentity(
    FollowUser item,
    dynamic liveSite, {
    required int? generation,
    LiveRoomDetail? detail,
  }) async {
    final resolvedDetail =
        detail ?? await liveSite.getRoomDetail(roomId: item.roomId);
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
    await DBService.instance.addFollow(item);
  }

  List<FollowUser> _buildPreviewTargets(
    Iterable<FollowUser> items, {
    bool force = false,
  }) {
    final now = DateTime.now();
    return _sortFollowUsers(
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
          return now.difference(updatedAt) > const Duration(minutes: 30);
        }),
      ),
    );
  }

  /// 单轮可见卡预取上限：列表改多列后同屏卡数变多，若一次把整屏"直播中
  /// 且缺封面/超时"的卡全部打详情（B站 getInfoByRoom 属 WBI 风控接口），
  /// 请求量会成倍上涨并把 B站接口风控推高（连累弹幕 token 获取）。
  static const int kMaxPreviewPerRound = 6;

  Future<void> refreshVisiblePreviews(
    Iterable<FollowUser> items, {
    bool force = false,
  }) async {
    if (!AppSettingsController.instance.followShowLiveCover.value) {
      return;
    }
    final all = _buildPreviewTargets(items, force: force);
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
        reconcileDouyinIdentity: false,
      );
    } finally {
      _previewRefreshingKeys.removeAll(keys);
    }
  }

  Future<FollowUser> resolveFollowBeforeEnter(FollowUser item) async {
    if (item.siteId != Constant.kDouyin) {
      return item;
    }
    await _refreshMetadataTargets([item], reconcileDouyinIdentity: true);
    return item;
  }

  Future<void> _refreshMetadataTargets(
    List<FollowUser> targets, {
    required bool reconcileDouyinIdentity,
    String? progressScopeKey,
    bool automatic = false,
  }) async {
    final orderedTargets = _sortFollowUsers(_distinctFollowUsers(targets));
    if (orderedTargets.isEmpty) {
      return;
    }
    final generation = _updateGeneration;
    var changed = false;
    var completed = 0;
    var successCount = 0;
    var failedCount = 0;
    void updateMetadataProgress({required bool done}) {
      _setMetadataRefreshProgress(
        reconcileDouyinIdentity: reconcileDouyinIdentity,
        automatic: automatic,
        progressScopeKey: progressScopeKey,
        current: completed,
        total: orderedTargets.length,
        successCount: successCount,
        failedCount: failedCount,
        completed: done,
      );
    }

    updateMetadataProgress(done: false);

    Future<void> worker(Queue<FollowUser> queue) async {
      while (queue.isNotEmpty) {
        if (generation != _updateGeneration) {
          return;
        }
        final item = queue.removeFirst();
        try {
          final site = Sites.allSites[item.siteId]!;
          final detail = await site.liveSite.getRoomDetail(roomId: item.roomId);
          if (generation != _updateGeneration) {
            return;
          }
          if (reconcileDouyinIdentity && item.siteId == Constant.kDouyin) {
            await _reconcileDouyinFollowIdentity(
              item,
              site.liveSite,
              generation: generation,
              detail: detail,
            );
            changed = true;
            successCount++;
            completed++;
            updateMetadataProgress(done: false);
            continue;
          }
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
          if (title.isNotEmpty || cover.isNotEmpty) {
            item.previewUpdatedAt = DateTime.now();
            changed = true;
          }
          await DBService.instance.addFollow(item);
          successCount++;
        } catch (e) {
          failedCount++;
          Log.logPrint(
            "${_metadataFailureLabel(reconcileDouyinIdentity)}(${item.siteId}/${item.roomId}): $e",
          );
        }
        completed++;
        updateMetadataProgress(done: false);
      }
    }

    final douyinQueue = Queue<FollowUser>.from(
      orderedTargets.where((item) => item.siteId == Constant.kDouyin),
    );
    final otherQueue = Queue<FollowUser>.from(
      orderedTargets.where((item) => item.siteId != Constant.kDouyin),
    );
    final futures = <Future<void>>[];
    if (douyinQueue.isNotEmpty) {
      futures.add(worker(douyinQueue));
    }
    if (otherQueue.isNotEmpty) {
      final workerCount = _metadataWorkerCount(
        orderedTargets,
        reconcileDouyinIdentity: reconcileDouyinIdentity,
      );
      futures.addAll(List.generate(workerCount, (_) => worker(otherQueue)));
    }
    await Future.wait(futures);
    if (generation != _updateGeneration) {
      return;
    }
    updateMetadataProgress(done: true);
    Log.logPrint(
      _metadataPhaseLogDone(
        reconcileDouyinIdentity,
        successCount,
        failedCount,
      ),
    );
    if (changed) {
      sortList();
    }
  }

  bool _isDouyinLimited(FollowUser item, Object error) {
    return item.siteId == Constant.kDouyin &&
        error is CoreError &&
        error.statusCode == 444;
  }

  void _handleDouyinLimited() {
    _lastPlatformLimitedAt = DateTime.now();
    Log.w("抖音访问受限，已自动降速并继续刷新当前任务");
  }

  void removeItem(FollowUser item, {bool refresh = true}) async {
    final result = await Utils.showAlertDialog(
      "确定要取消关注 ${item.userName} 吗?",
      title: "取消关注",
    );
    if (!result) {
      return;
    }
    await DBService.runExclusive(() => DBService.instance.followBox.delete(DBService.safeBoxKey(item.id)));
    if (refresh) {
      refreshData(forceStatus: false);
    } else {
      allList.remove(item);
      list.remove(item);
      livingList.remove(item);
    }
  }

  @override
  void onClose() {
    _updateGeneration++;
    updating.value = false;
    _cancelRefreshProgressReset();
    _resetRefreshProgress();
    _eventReloadTimer?.cancel();
    updateTimer?.cancel();
    subscription?.cancel();
    super.onClose();
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
  }) async {
    _biliBatchCovered.clear();
    final site = _biliSite;
    if (site == null || allList.isEmpty) {
      return;
    }
    final uidToItems = <String, List<FollowUser>>{};
    for (final item in allList) {
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
    // 自动轮询且局域网内已有这些房间的新鲜快照 → 让 item 级逻辑白拿，
    // 本批一个请求也不发（多端同 IP，能省则省）。
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
