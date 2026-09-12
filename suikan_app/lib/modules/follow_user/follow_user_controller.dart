// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/platform_utils.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/modules/multi_room/multi_room_models.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/desktop_multi_window_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/sync_service.dart';

enum FollowGroupMode {
  liveStatus,
  platform,
  tag,
}

class FollowGroupOption {
  final String id;
  final String title;
  final String? siteId;
  final int? liveStatus;
  final String? tagName;

  const FollowGroupOption({
    required this.id,
    required this.title,
    this.siteId,
    this.liveStatus,
    this.tagName,
  });
}

class FollowUserController extends BasePageController<FollowUser> {
  static const int paginationThreshold = 400;
  StreamSubscription<dynamic>? onUpdatedIndexedStream;
  StreamSubscription<dynamic>? onUpdatedListStream;

  var groupMode = FollowGroupMode.liveStatus.obs;
  var selectedGroupId = "all".obs;
  var searchKeyword = "".obs;
  var multiSelectMode = false.obs;
  RxSet<String> selectedMultiRoomKeys = <String>{}.obs;
  var currentDisplayPage = 1.obs;
  var totalDisplayPages = 1.obs;
  var paginationEnabled = false.obs;
  RxList<FollowUserTag> tagList = [
    FollowUserTag(id: "0", tag: "全部", userId: []),
    FollowUserTag(id: "1", tag: "直播中", userId: []),
    FollowUserTag(id: "2", tag: "未开播", userId: []),
  ].obs;

  // 用户自定义标签
  RxList<FollowUserTag> userTagList = <FollowUserTag>[].obs;

  @override
  void onInit() {
    pageSize = AppSettingsController.instance.followPageSize.value;
    _restoreGroupSelection();
    unawaited(_loadInitialData());
    onUpdatedIndexedStream = EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
      (index) {
        if (index == 1) {
          scrollToTopOrRefresh();
        }
      },
    );
    onUpdatedListStream =
        FollowService.instance.updatedListStream.listen((event) {
      filterData();
    });
    super.onInit();
  }

  Future<void> _loadInitialData() async {
    // 🔴 2026-09-11 定案：进页面**只读本地 + 局域网快照，不发公网请求**。
    // loadData(updateStatus: false) 只把 DB 同步到内存；状态由下面的
    // 「仅局域网轮」从 P2P 快照补齐。想拿公网最新 → 用户手动下拉。
    await refreshData(forceStatus: false);
    if (AppSettingsController.instance.followRefreshOnEnter.value &&
        FollowService.instance.followList.isNotEmpty) {
      unawaited(
        // 进页自动刷新（用户没点刷新）→ 静默 + 仅局域网；
        // 局域网若全空（无生产者在跑）→ 前 20 条兜底公网，保证进页面可见。
        FollowService.instance
            .refreshPeerOnly(
          fallbackLimit: FollowService.kPeerOnlyFallbackLimit,
        )
            .then((_) {
          filterData();
        }),
      );
    }
  }

  void _restoreGroupSelection() {
    final settings = AppSettingsController.instance;
    groupMode.value = switch (settings.followGroupMode.value) {
      "platform" => FollowGroupMode.platform,
      "tag" => FollowGroupMode.tag,
      _ => FollowGroupMode.liveStatus,
    };
    selectedGroupId.value = settings.followSelectedGroupId.value;
  }

  @override
  Future refreshData({bool forceStatus = true}) async {
    pageSize = AppSettingsController.instance.followPageSize.value;
    // 🔴 2026-09-11 定案：
    // - 手动刷新（forceStatus=true，下拉/刷新按钮）→ 走公网 + P2P 快照；
    // - 非手动（进页面等）→ **不在这里发任何公网请求**，只同步 DB；
    //   局域网状态由调用方 `refreshPeerOnly()` 补齐。
    await FollowService.instance.loadData(
      updateStatus: forceStatus,
      forceUpdateStatus: forceStatus,
      silent: !forceStatus,
    );
    updateTagList();
    filterData();
  }

  @override
  Future<List<FollowUser>> getData(int page, int pageSize) async {
    final items = _buildFilteredList();
    final start = (page - 1) * pageSize;
    if (start >= items.length) {
      return Future.value([]);
    }
    final end = (start + pageSize).clamp(0, items.length).toInt();
    return items.sublist(start, end);
  }

  void updateTagList() {
    userTagList.assignAll(FollowService.instance.followTagList);
    tagList.value = tagList.take(3).toList();
    for (var i in userTagList) {
      if (!tagList.contains(i)) {
        tagList.add(i);
      }
    }
  }

  /// ---- 列表滚动锚点：按「条目身份」锚定（2026-09-13）----
  ///
  /// 目标：**用户从列表哪一条进的直播间，返回后还在哪一条**（行业通行做法，
  /// Android 官方把"列表滚动位置"列为必须保留的导航状态）。
  ///
  /// 为什么用「条目 key」而不是「像素偏移」：关注列表会随开播状态**重新排序**
  /// （直播中的往前排、关播的往后掉）。离开一会儿回来，同一个像素位置对应的
  /// 往往已经是别的条目了。官方对此的建议很明确 —— 数据可能重排时，按
  /// **条目 id** 锚定优于按位置锚定。
  ///
  /// 做法：每次重建列表**之前**先记下"视口顶部那一行最左边的条目 key + 它
  /// 被滚过了多少像素"；换完数据后按 key 在新列表里找到它，把它摆回同一视觉
  /// 位置（`jumpTo`，无动画 —— 返回时不该看到列表还在自己往上滑）。
  ///
  /// 索引 → 像素的换算（固定网格 + `mainAxisExtent` 定高）：
  /// `top(index) = (index ~/ crossAxisCount) * (mainAxisExtent + mainAxisSpacing)`
  /// 列表顶部 padding 恒为 0（见 follow_user_page.dart 的 `fromLTRB(8, 0, 8, 96)`）。
  int _gridCrossAxisCount = 1;
  double _gridMainAxisExtent = 0;
  double _gridMainAxisSpacing = 0;

  /// 页面在 build 时把当前生效的网格度量回填进来（纯赋值，不触发重建）。
  /// 窗口尺寸/显示样式都会改列数与行高，所以必须每次 build 同步。
  void updateFollowGridMetrics({
    required int crossAxisCount,
    required double mainAxisExtent,
    required double mainAxisSpacing,
  }) {
    if (crossAxisCount <= 0 || mainAxisExtent <= 0) {
      return;
    }
    _gridCrossAxisCount = crossAxisCount;
    _gridMainAxisExtent = mainAxisExtent;
    _gridMainAxisSpacing = mainAxisSpacing;
  }

  /// 一行占用的垂直像素（行高 + 行间距）。
  double _rowExtent() {
    final extent = _gridMainAxisExtent + _gridMainAxisSpacing;
    return extent > 0 ? extent : 0;
  }

  /// 第 [index] 个条目顶边对应的滚动偏移。
  double _itemTop(int index) {
    final rowExtent = _rowExtent();
    if (rowExtent <= 0 || _gridCrossAxisCount <= 0) {
      return 0;
    }
    return (index ~/ _gridCrossAxisCount) * rowExtent;
  }

  String _followItemKey(FollowUser item) => "${item.siteId}_${item.roomId}";

  /// 已算出、但还没在新布局上执行的锚点（下一帧恢复完即清空）。
  ///
  /// 为什么要这个字段：`filterData()` 会在同一帧里被连续调用多次（进房回写
  /// 紧跟一轮 P2P 刷新完成 / 对端快照回调）。若每次都重新取锚点，第二次读到
  /// 的是**已经被重排过的 list**，取出来的只是"当前像素位置"这个无意义结果，
  /// 执行顺序上它会盖掉第一次算对的目标 → 位置又不准了。
  /// 有 pending 时直接沿用第一次的锚点，多次恢复就变成幂等的。
  _FollowListAnchor? _pendingAnchor;

  /// 本帧已决定"回顶部"（见 [_jumpToTopAfterLayout]）。用于阻止同帧后续的
  /// `filterData()` 再按"尚未生效的旧偏移"取锚点。
  bool _pendingTopJump = false;

  /// 记录当前视口顶部的锚点条目（拿不到有效值就返回 null → 本次不恢复）。
  _FollowListAnchor? _captureAnchor() {
    if (_pendingTopJump) {
      return null; // 本帧已决定回顶部 → 不再取锚点
    }
    final pending = _pendingAnchor;
    if (pending != null) {
      return pending; // 本帧已锚定过 → 沿用，避免用重排后的列表重复取锚点
    }
    if (list.isEmpty || !scrollController.hasClients) {
      return null;
    }
    final rowExtent = _rowExtent();
    if (rowExtent <= 0) {
      return null; // 度量还没回填 → 这轮先不锚定
    }
    final offset = scrollController.offset;
    if (offset <= 0) {
      return null; // 本来就在顶部 → 天然保持，无需锚定
    }
    final index = (offset / rowExtent).floor() * _gridCrossAxisCount;
    if (index < 0 || index >= list.length) {
      return null;
    }
    return _FollowListAnchor(
      key: _followItemKey(list[index]),
      delta: offset - _itemTop(index),
    );
  }

  /// 布局完成后把列表跳回顶部（无动画）。
  ///
  /// 用在「用户看到的那一批内容被整体换掉」之后 —— 翻页 / 切分组 / 搜索 /
  /// 只看直播中（统一由 [_restoreAnchor] 里"锚点找不到"这条兜住）。
  /// 此时旧偏移对应的是**已经不存在的那批内容**，保留它只会让人对不上号，
  /// 行业做法就是回到顶部重看。
  ///
  /// 与「返回时保持位置」不冲突：那个场景用户**没换内容**，才会走锚点恢复。
  void _jumpToTopAfterLayout() {
    _pendingTopJump = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingTopJump = false;
      if (!scrollController.hasClients) {
        return;
      }
      scrollController.jumpTo(0);
    });
  }

  /// 把锚点条目摆回它原来的视觉位置（按新列表里的索引重新计算）。
  void _restoreAnchor(_FollowListAnchor? anchor) {
    if (_pendingTopJump) {
      return; // 本帧已决定回顶部 → 不再做锚点恢复
    }
    if (anchor == null || list.isEmpty) {
      return;
    }
    final index = list.indexWhere((item) => _followItemKey(item) == anchor.key);
    if (index < 0) {
      // 锚点条目已不在当前列表 → 用户看到的那批内容被整体换掉了
      // （翻页 / 切分组 / 搜索 / 只看直播中，或那条被取消关注）→ 回顶部。
      _jumpToTopAfterLayout();
      return;
    }
    _pendingAnchor = anchor;
    // 等新数据完成布局后再跳：① 否则 maxScrollExtent 还是旧值会被夹断；
    // ② `_itemTop` 依赖的网格度量（列数/行高）也在这时才更新 —— 切换显示
    //    样式或"展示直播封面"会改行高，提前用旧度量算会偏。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 本帧恢复已完成 → 释放锚点，下一帧重新按用户当时的视口取。
      _pendingAnchor = null;
      if (!scrollController.hasClients) {
        return;
      }
      final target = _itemTop(index) + anchor.delta;
      scrollController.jumpTo(
        target.clamp(0.0, scrollController.position.maxScrollExtent),
      );
    });
  }

  /// 重建列表数据（**不滚到"当前房间"，而是保持用户原来看到的位置**）。
  ///
  /// 🔴 2026-09-13：**返回关注列表时保持原位置**（行业通行做法）。
  ///
  /// 此前这里每重建一次就调 `_scrollToCurrentRoom()` 把列表滚到"当前正在
  /// 播放的房间"。问题有三层：
  /// ① 进直播间会回写状态 → 触发列表重建 → 滚一次；
  /// ② 同期 P2P 刷新完成 / 对端快照回调 / 兜底公网回来都会再触发重建
  ///    → 多个 `animateTo`(260ms) 互相打断 → 最终停位随时序漂移；
  /// ③ 那个偏移算法本身是错的（`index * 132`，实际是多列 GridView、
  ///    行高随样式在 66~190 之间变），列数还会随窗口宽度变。
  ///
  /// 现在改为：
  /// - **同一条目还在**（只是被重排）→ 按锚点把它摆回原来的视觉位置；
  /// - **锚点条目已不在列表**（翻页 / 切分组 / 搜索 / 只看直播中 → 整批内容
  ///   被换掉）→ 回列表顶部（旧偏移对新内容没有意义，见 [_jumpToTopAfterLayout]）；
  /// - **没换内容**（后台刷新导致的重排）→ 位置稳定不动，返回时看到的就是原来那条。
  ///
  /// 想定位到正在播放的房间时，用户可自己滚过去（该条本身有 `playing` 高亮，
  /// 见 follow_user_page.dart）；想回顶部则点底部导航栏的「关注」tab（已实现）。
  void filterData() {
    final items = _buildFilteredList();
    _rebuildPagedList(items);
    pageEmpty.value = items.isEmpty;
  }

  void _rebuildPagedList(List<FollowUser> items) {
    // 换数据**之前**先记锚点：必须用旧 list + 旧滚动偏移，换完就取不到了。
    final anchor = _captureAnchor();
    pageSize = AppSettingsController.instance.followPageSize.value;
    paginationEnabled.value = items.length > paginationThreshold;
    if (!paginationEnabled.value) {
      currentDisplayPage.value = 1;
      totalDisplayPages.value = 1;
      currentPage = items.isEmpty ? 1 : 2;
      canLoadMore.value = false;
      list.assignAll(items);
      _restoreAnchor(anchor);
      _requestVisiblePreviews(items);
      return;
    }

    final maxPageSize = ((items.length / 2).floor() + 1).clamp(2, items.length);
    final effectivePageSize = pageSize.clamp(2, maxPageSize).toInt();
    if (effectivePageSize != pageSize) {
      pageSize = effectivePageSize;
      AppSettingsController.instance.setFollowPageSize(effectivePageSize);
    }
    totalDisplayPages.value =
        (items.length / effectivePageSize).ceil().clamp(1, items.length);
    if (currentDisplayPage.value > totalDisplayPages.value) {
      currentDisplayPage.value = totalDisplayPages.value;
    }
    if (currentDisplayPage.value < 1) {
      currentDisplayPage.value = 1;
    }
    final start = (currentDisplayPage.value - 1) * effectivePageSize;
    final end = (start + effectivePageSize).clamp(0, items.length).toInt();
    list.assignAll(items.sublist(start, end));
    currentPage = currentDisplayPage.value;
    canLoadMore.value = false;
    _restoreAnchor(anchor);
    _requestVisiblePreviews(list.toList());
  }

  List<FollowUser> get currentPageTargets => list.toList();

  String get currentRefreshScopeKey {
    final mode =
        groupMode.value == FollowGroupMode.platform ? "platform" : "live";
    return "${currentDisplayPage.value}:${selectedGroupId.value}:$mode";
  }

  Future<void> refreshCurrentPageStatus() async {
    final pageItems =
        paginationEnabled.value ? currentPageTargets : _buildFilteredList();
    await FollowService.instance.refreshSelectedStatus(
      FollowService.instance.buildPageFrontTargets(pageItems),
      force: true,
      statusOnly: true,
      scope: FollowRefreshScope.page(
        scopeKey: FollowService.instance.buildPageRefreshScopeKey(
          currentRefreshScopeKey,
        ),
      ),
    );
    filterData();
  }

  Future<void> refreshAllStatus() async {
    // 与 refreshCurrentPageStatus / refreshManual 同一语义：手动 = 公网 + P2P。
    if (Get.isRegistered<SyncService>()) {
      await SyncService.instance.queryPeersLiveStatus();
    }
    await FollowService.instance.refreshSelectedStatus(
      _buildFilteredList(),
      includeAllNormals: true,
      force: true,
      statusOnly: true,
      scope: const FollowRefreshScope.all(),
    );
    filterData();
  }

  void goToNextPage() {
    if (!paginationEnabled.value ||
        currentDisplayPage.value >= totalDisplayPages.value) {
      return;
    }
    currentDisplayPage.value += 1;
    filterData();
  }

  void goToPreviousPage() {
    if (!paginationEnabled.value || currentDisplayPage.value <= 1) {
      return;
    }
    currentDisplayPage.value -= 1;
    filterData();
  }

  List<FollowUser> _distinctFollowUsers(Iterable<FollowUser> items) {
    final result = <FollowUser>[];
    final seenIds = <String>{};
    for (final item in items) {
      final id = item.id.trim().isNotEmpty
          ? item.id.trim()
          : "${item.siteId}_${item.roomId}";
      if (seenIds.add(id)) {
        result.add(item);
      }
    }
    return result;
  }

  List<FollowGroupOption> get groupOptions {
    final options = <FollowGroupOption>[
      const FollowGroupOption(id: "all", title: "全部"),
    ];
    if (groupMode.value == FollowGroupMode.liveStatus) {
      options.addAll(const [
        FollowGroupOption(id: "live", title: "直播中", liveStatus: 2),
        FollowGroupOption(id: "not_live", title: "未开播", liveStatus: 1),
      ]);
    } else if (groupMode.value == FollowGroupMode.tag) {
      // 按标签：全部 + 用户自定义标签（没有自定义标签时只有"全部"）。
      options.addAll(
        userTagList.map(
          (tag) => FollowGroupOption(
            id: "tag:${tag.tag}",
            title: tag.tag,
            tagName: tag.tag,
          ),
        ),
      );
    } else {
      final siteIds = FollowService.instance.followList
          .map((item) => item.siteId)
          .toSet()
          .toList();
      final siteSort = Sites.supportSites.map((site) => site.id).toList();
      siteIds.sort((a, b) {
        final aIndex = siteSort.indexOf(a);
        final bIndex = siteSort.indexOf(b);
        if (aIndex < 0 && bIndex < 0) {
          return a.compareTo(b);
        }
        if (aIndex < 0) {
          return 1;
        }
        if (bIndex < 0) {
          return -1;
        }
        return aIndex.compareTo(bIndex);
      });
      for (final siteId in siteIds) {
        final site = Sites.allSites[siteId];
        options.add(
          FollowGroupOption(
            id: "site:$siteId",
            title: site?.name ?? siteId,
            siteId: siteId,
          ),
        );
      }
    }
    return options;
  }

  List<FollowUser> _filterBySelectedGroup() {
    FollowGroupOption? selected;
    for (final option in groupOptions) {
      if (option.id == selectedGroupId.value) {
        selected = option;
        break;
      }
    }
    final source = FollowService.instance.followList;
    if (selected == null || selected.id == "all") {
      selectedGroupId.value = "all";
      return FollowService.instance.sortFollowUsers(
        _distinctFollowUsers(source),
      );
    }
    final liveStatus = selected.liveStatus;
    if (liveStatus != null) {
      final expectedStatus = liveStatus == 1 ? {0, 1} : {liveStatus};
      return FollowService.instance.sortFollowUsers(
        _distinctFollowUsers(
          source
              .where((item) => expectedStatus.contains(item.liveStatus.value)),
        ),
      );
    }
    final siteId = selected.siteId;
    if (siteId != null) {
      return FollowService.instance.sortFollowUsers(
        _distinctFollowUsers(source.where((item) => item.siteId == siteId)),
      );
    }
    final tagName = selected.tagName;
    if (tagName != null) {
      return FollowService.instance.sortFollowUsers(
        _distinctFollowUsers(source.where((item) => item.tag == tagName)),
      );
    }
    return FollowService.instance.sortFollowUsers(
      _distinctFollowUsers(source),
    );
  }

  List<FollowUser> _buildFilteredList() {
    Iterable<FollowUser> items = _filterBySelectedGroup();
    if (AppSettingsController.instance.followOnlyLive.value) {
      items = items.where((item) => item.liveStatus.value == 2);
    }
    final keyword = searchKeyword.value.trim().toLowerCase();
    if (keyword.isNotEmpty) {
      items = items.where(
        (item) => item.userName.toLowerCase().contains(keyword),
      );
    }
    return FollowService.instance.sortFollowUsers(_distinctFollowUsers(items));
  }

  void setSearchKeyword(String value) {
    searchKeyword.value = value.trim();
    currentDisplayPage.value = 1;
    filterData();
  }

  void clearSearchKeyword() {
    if (searchKeyword.value.isEmpty) {
      return;
    }
    searchKeyword.value = "";
    currentDisplayPage.value = 1;
    filterData();
  }

  void _requestVisiblePreviews(List<FollowUser> items) {
    if (items.isEmpty ||
        !AppSettingsController.instance.followShowLiveCover.value) {
      return;
    }
    unawaited(FollowService.instance.refreshVisiblePreviews(items));
  }

  void setDisplayStyle(String value) {
    AppSettingsController.instance.setFollowDisplayStyle(value);
    filterData();
  }

  void setOnlyLive(bool value) {
    AppSettingsController.instance.setFollowOnlyLive(value);
    currentDisplayPage.value = 1;
    filterData();
  }

  void setRefreshOnEnter(bool value) {
    AppSettingsController.instance.setFollowRefreshOnEnter(value);
  }

  void setShowLiveCover(bool value) {
    AppSettingsController.instance.setFollowShowLiveCover(value);
    filterData();
  }

  void setGroupMode(FollowGroupMode mode) {
    groupMode.value = mode;
    selectedGroupId.value = "all";
    _saveGroupSelection();
    filterData();
  }

  void setGroupOption(FollowGroupOption option) {
    selectedGroupId.value = option.id;
    _saveGroupSelection();
    filterData();
  }

  void _saveGroupSelection() {
    AppSettingsController.instance.setFollowGroupSelection(
      mode: switch (groupMode.value) {
        FollowGroupMode.platform => "platform",
        FollowGroupMode.tag => "tag",
        FollowGroupMode.liveStatus => "liveStatus",
      },
      groupId: selectedGroupId.value,
    );
  }

  void removeItem(FollowUser item) async {
    var result =
        await Utils.showAlertDialog("确定要取消关注${item.userName}吗?", title: "取消关注");
    if (!result) {
      return;
    }
    // 取消关注同时删除标签内的 userId
    if (item.tag != "全部") {
      var tag = tagList.firstWhere((tag) => tag.tag == item.tag);
      tag.userId.remove(item.id);
      updateTag(tag);
    }
    await DBService.runExclusive(() => DBService.instance.followBox.delete(DBService.safeBoxKey(item.id)));
    refreshData();
  }

  void updateItem(FollowUser item) {
    FollowService.instance.addFollow(item);
  }

  bool isSelectedForMultiRoom(FollowUser item) {
    return selectedMultiRoomKeys.contains(item.id);
  }

  void toggleMultiSelectMode() {
    if (!PlatformUtils.supportsInlineMultiRoom) {
      return;
    }
    multiSelectMode.value = !multiSelectMode.value;
    if (!multiSelectMode.value) {
      selectedMultiRoomKeys.clear();
    }
  }

  void toggleMultiRoomItem(FollowUser item) {
    if (!PlatformUtils.supportsInlineMultiRoom) {
      return;
    }
    if (item.liveStatus.value != 2) {
      SmartDialog.showToast("只能选择直播中的关注");
      return;
    }
    if (selectedMultiRoomKeys.contains(item.id)) {
      selectedMultiRoomKeys.remove(item.id);
      return;
    }
    selectedMultiRoomKeys.add(item.id);
  }

  void openSelectedMultiRooms() async {
    if (!PlatformUtils.supportsInlineMultiRoom) {
      SmartDialog.showToast("当前移动端版本已关闭多开同屏");
      return;
    }
    final selected = list
        .where((item) =>
            selectedMultiRoomKeys.contains(item.id) &&
            item.liveStatus.value == 2 &&
            Sites.allSites.containsKey(item.siteId))
        .map(MultiRoomItem.fromFollow)
        .whereType<MultiRoomItem>()
        .toList();
    if (selected.length < 2) {
      SmartDialog.showToast("至少选择 2 个直播中的关注");
      return;
    }
    if (await DesktopMultiWindowService.openRooms(selected)) {
      return;
    }
    AppNavigator.toMultiRoom(selected);
  }

  void toggleSpecialFollow(FollowUser item) async {
    await FollowService.instance.updateSpecialFollow(
      item,
      !item.isSpecialFollow,
    );
    filterData();
  }

  Future<void> openFollowRoom(FollowUser item) async {
    final resolved =
        await FollowService.instance.resolveFollowBeforeEnter(item);
    // 飞牛影视的 site 不在静态列表，需从 FnOsService 注册表取。
    final site = Sites.allSites[resolved.siteId] ??
        FnOsService.instance.siteForServer(resolved.siteId);
    if (site == null) {
      return;
    }
    final isVod =
        FnOsService.instance.serverForSiteId(resolved.siteId) != null;
    AppNavigator.toLiveRoomDetail(
      site: site,
      roomId: resolved.roomId,
      isVod: isVod,
    );
  }

  // 修改item的标签
  void setItemTag(FollowUser item, FollowUserTag targetTag) {
    FollowUserTag tarTag = targetTag;
    FollowUserTag curTag = tagList.firstWhere((tag) => tag.tag == item.tag);
    // 从当前标签（非全部）删除item 向目标标签(全部包含所有item == 非全部)添加item
    curTag.userId.remove(item.id);
    tarTag.userId.addIf(!tarTag.userId.contains(item.id), item.id);
    // 数据库更新
    item.tag = tarTag.tag;
    updateTag(curTag);
    updateTag(tarTag);
    updateItem(item);
    filterData();
  }

  Future<void> removeTag(FollowUserTag tag) async {
    // 将tag下的所有follow设置为全部
    for (var i in tag.userId) {
      var follow = DBService.instance.followBox.get(DBService.safeBoxKey(i));
      if (follow != null) {
        follow.tag = "全部";
        updateItem(follow);
      }
    }
    await FollowService.instance.delFollowUserTag(tag);
    updateTagList();
    Log.i('删除tag${tag.tag}');
  }

  void addTag(String tag) async {
    FollowService.instance
        .addFollowUserTag(tag)
        .then((value) => updateTagList());
  }

  void updateTag(FollowUserTag followUserTag) {
    if (followUserTag.tag == '全部') {
      return;
    }
    FollowService.instance.updateFollowUserTag(followUserTag);
  }

  void updateTagName(FollowUserTag followUserTag, String newTagName) {
    // 未操作
    if (followUserTag.tag == newTagName) {
      return;
    }
    // 避免重名
    if (tagList.any((item) => item.tag == newTagName)) {
      SmartDialog.showToast("标签名重复，修改失败");
      return;
    }
    final FollowUserTag newTag = followUserTag.copyWith(tag: newTagName);
    updateTag(newTag);
    // update item's tag when update tagName
    for (var i in newTag.userId) {
      var follow = DBService.instance.followBox.get(DBService.safeBoxKey(i));
      if (follow != null) {
        follow.tag = newTagName;
        updateItem(follow);
      }
    }
    SmartDialog.showToast("标签名修改成功");
    updateTagList();
  }

  // 调整标签顺序
  void updateTagOrder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1; // 处理索引调整
    final item = userTagList.removeAt(oldIndex);
    userTagList.insert(newIndex, item);
    tagList.value = tagList.take(3).toList();
    tagList.addAll(userTagList);
    DBService.instance.updateFollowTagOrder(userTagList);
  }

  @override
  void onClose() {
    onUpdatedIndexedStream?.cancel();
    onUpdatedListStream?.cancel();
    super.onClose();
  }
}

/// 关注列表的滚动锚点：记住"视口顶部那一行最左边的条目"是谁、以及它被
/// 滚过了多少像素。列表重排后靠 [key] 找回它，把它摆回原来的视觉位置。
///
/// 见 [FollowUserController._captureAnchor] / [_restoreAnchor]。
class _FollowListAnchor {
  /// 条目标识（`siteId_roomId`）—— 与页面 `playing` 高亮用同一套 key。
  final String key;

  /// 该条目顶边超出视口顶部的像素（∈ [0, 一行高度)）。
  final double delta;

  const _FollowListAnchor({required this.key, required this.delta});
}
