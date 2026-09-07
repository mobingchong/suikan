import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/search/local_content_search_controller.dart';

/// 全局搜索结果分组（一个平台一组，渐进展示）。
class GlobalSearchSection {
  final Site? site;
  final String title;

  /// 结果列表（LiveRoomItem / LiveAnchorItem / LocalSearchResult 混合）
  final RxList<Object> items = <Object>[].obs;

  /// 0=搜索中, 1=成功, 2=失败
  final RxInt status = 0.obs;

  /// 失败原因
  final RxString errorMsg = ''.obs;

  /// 该分组最近一次失败时间（用于冷却）
  DateTime? lastFailAt;

  /// 已拉到的页码(下一页=loadedPage+1);exhausted=该平台已拉空。
  int loadedPage = 1;
  bool exhausted = false;

  GlobalSearchSection({required this.title, this.site});
}

/// 方案 B：彻底单页全局搜索 + 限流对策
///
/// 限流对策（全部实现）：
/// 1. 输入防抖 600ms + generation 版本号，取消上一轮未完成请求
/// 2. 抖音放第二批单飞（与第一批错开 400ms）
/// 3. 渐进式结果展示：每个平台独立分组，先到先显示
/// 4. 失败不重试 + 冷却 3 秒
/// 5. 平台间 400ms 错峰
/// 6. 分页间隔拉取（加载更多时逐平台错开 200ms）
class GlobalSearchController extends GetxController {
  /// 搜索模式，0=直播间，1=主播
  var searchMode = 0.obs;

  /// 输入框控制器
  final TextEditingController searchController = TextEditingController();

  /// 结果列表滚动控制器:常驻复用,重建/渐进返回时不丢滚动位。
  final ScrollController scrollController = ScrollController();

  /// 分组结果（全局搜索列表）
  final RxList<GlobalSearchSection> sections = <GlobalSearchSection>[].obs;

  /// 搜索中
  final RxBool searching = false.obs;

  /// 是否还有更多（聚合分页简化：第一页全量，加载更多逐平台补页）
  final RxBool hasMore = false.obs;

  String keyword = '';

  /// 版本号：新搜索开始时自增，旧请求返回时若版本不匹配则丢弃结果
  int _generation = 0;

  Timer? _debounce;

  /// 各平台最近失败时间（冷却用）
  final Map<String, DateTime> _failCooldown = {};

  static const Duration debounceDuration = Duration(milliseconds: 600);
  static const Duration staggerDelay = Duration(milliseconds: 400);
  static const Duration pageStaggerDelay = Duration(milliseconds: 200);
  static const Duration cooldownDuration = Duration(seconds: 3);

  /// 抖音单独放第二批
  static const String _douyinId = 'douyin';

  /// 可搜索的平台（排除自定义源与影视库，它们归入本地内容）
  List<Site> get _sites => Sites.supportSites
      .where((s) => !s.id.startsWith('custom_') && !s.id.startsWith('fnos_'))
      .toList();

  /// 本地内容搜索控制器（自定义直播源 + 影视库）
  LocalContentSearchController get _localController =>
      Get.find<LocalContentSearchController>();

  /// 输入变化：防抖 600ms 后触发全局搜索
  void onInputChanged(String text) {
    _debounce?.cancel();
    final kw = text.trim();
    if (kw.isEmpty) {
      _generation++; // 取消所有在途请求
      sections.clear();
      searching.value = false;
      return;
    }
    _debounce = Timer(debounceDuration, () => searchGlobal(kw));
  }

  /// 立即触发全局搜索（回车/点按钮时）
  void searchGlobal(String kw) {
    _debounce?.cancel();
    keyword = kw.trim();
    if (keyword.isEmpty) return;
    // 用户主动发起新搜索：清掉上一次失败的冷却记录。
    // 冷却只应作用于"同一次搜索内的自动重试"，否则上一次某平台失败后
    // 3 秒内再搜，该平台会直接显示"限流冷却中"——表现为"两次搜索结果不一致"。
    _failCooldown.clear();
    final gen = ++_generation;
    searching.value = true;
    sections.clear();
    hasMore.value = false;

    // 第一组：本地内容（自定义直播源 + 影视库）
    final localSection = GlobalSearchSection(title: '本地内容');
    sections.add(localSection);

    // 平台分组（保持平台顺序）
    final sites = _sites;
    for (final site in sites) {
      sections.add(GlobalSearchSection(title: site.name, site: site));
    }

    // 本地内容搜索
    _searchLocal(localSection, gen);

    // 平台分批：第一批为除抖音外的所有平台（错峰 400ms），抖音单飞放第二批
    final firstBatch = sites.where((s) => s.id != _douyinId).toList();
    final douyin = sites.where((s) => s.id == _douyinId).toList();
    var delay = Duration.zero;
    for (final site in firstBatch) {
      final section = sections.firstWhere((s) => s.site == site);
      _schedulePlatformSearch(section, site, gen, delay);
      delay += staggerDelay;
    }
    // 抖音第二批（在第一批发完后，单独延迟）
    for (final site in douyin) {
      final section = sections.firstWhere((s) => s.site == site);
      _schedulePlatformSearch(
        section,
        site,
        gen,
        delay + staggerDelay,
      );
    }
  }

  /// 调度平台搜索（错峰）
  void _schedulePlatformSearch(
    GlobalSearchSection section,
    Site site,
    int gen,
    Duration delay,
  ) {
    Future.delayed(delay, () async {
      if (gen != _generation) return; // 已取消
      // 冷却检查：该平台上次失败未过 3 秒则不重试
      final lastFail = _failCooldown[site.id];
      if (lastFail != null &&
          DateTime.now().difference(lastFail) < cooldownDuration) {
        section.status.value = 2;
        section.errorMsg.value = '平台限流冷却中，请稍后再试';
        return;
      }
      await _searchPlatform(section, site, gen);
    });
  }

  /// 搜索单个平台第一页
  Future<void> _searchPlatform(
    GlobalSearchSection section,
    Site site,
    int gen,
  ) async {
    section.status.value = 0;
    try {
      final List<Object> items;
      if (searchMode.value == 1) {
        final result = await site.liveSite.searchAnchors(keyword, page: 1);
        items = result.items;
      } else {
        final result = await site.liveSite.searchRooms(keyword, page: 1);
        items = result.items;
      }
      if (gen != _generation) return; // 旧请求，丢弃
      section.items.value = items;
      section.loadedPage = 1;
      section.exhausted = false;
      section.status.value = 1;
      _failCooldown.remove(site.id);
      _refreshHasMore(gen);
    } catch (e) {
      if (gen != _generation) return;
      section.status.value = 2;
      // 显示真实原因（如"需要配置 Cookie"），而不是笼统的"搜索失败"——
      // 否则用户分不清是平台没结果还是被风控拦截。
      section.errorMsg.value = _friendlyError(e);
      _failCooldown[site.id] = DateTime.now();
      _refreshHasMore(gen);
    }
  }

  /// 有"已成功且未拉空"的平台时显示「加载更多」。
  void _refreshHasMore(int gen) {
    if (gen != _generation) return;
    hasMore.value = sections.any(
      (s) => s.site != null && s.status.value == 1 && !s.exhausted,
    );
  }

  static String _friendlyError(Object e) {
    var msg = e.toString();
    for (final prefix in const ['Exception: ', 'CoreError: ']) {
      if (msg.startsWith(prefix)) msg = msg.substring(prefix.length);
    }
    msg = msg.trim();
    if (msg.length > 60) {
      msg = '${msg.substring(0, 60)}…';
    }
    return msg.isEmpty ? '搜索失败' : msg;
  }

  /// 本地内容搜索（直播源频道 + 影视库，全局搜索同时搜两者）
  Future<void> _searchLocal(GlobalSearchSection section, int gen) async {
    section.status.value = 0;
    try {
      await _localController.searchAll(keyword);
      if (gen != _generation) return;
      section.items.value = _localController.results.toList();
      section.status.value = 1;
    } catch (_) {
      if (gen != _generation) return;
      section.status.value = 2;
      section.errorMsg.value = '搜索失败';
    }
  }

  /// 加载更多：逐平台补下一页（错开 200ms），仅对已成功且未拉空的平台补。
  bool _loadingMore = false;
  Future<void> loadMore() async {
    if (searching.value || _loadingMore) return;
    _loadingMore = true;
    final gen = _generation;
    try {
      for (var i = 0; i < sections.length; i++) {
        final section = sections[i];
        if (section.site == null ||
            section.status.value != 1 ||
            section.exhausted) {
          continue;
        }
        await Future.delayed(pageStaggerDelay * i);
        if (gen != _generation) return;
        final nextPage = section.loadedPage + 1;
        try {
          final List<Object> more;
          if (searchMode.value == 1) {
            final result = await section.site!.liveSite
                .searchAnchors(keyword, page: nextPage);
            more = result.items;
          } else {
            final result = await section.site!.liveSite
                .searchRooms(keyword, page: nextPage);
            more = result.items;
          }
          if (gen != _generation) return;
          if (more.isEmpty) {
            section.exhausted = true;
            continue;
          }
          final existing = section.items.map((e) => e.hashCode).toSet();
          final fresh = more.where((e) => !existing.contains(e.hashCode));
          if (fresh.isEmpty) {
            // 翻页结果与首页完全相同 → 视为无更多
            section.exhausted = true;
            continue;
          }
          section.items.addAll(fresh);
          section.loadedPage = nextPage;
        } catch (_) {
          // 单平台补页失败:不拉空处理,下次再点会再试该平台
        }
      }
      hasMore.value = sections.any(
        (s) => s.site != null && s.status.value == 1 && !s.exhausted,
      );
    } finally {
      _loadingMore = false;
    }
  }

  @override
  void onClose() {
    _debounce?.cancel();
    scrollController.dispose();
    _generation++; // 取消在途
    super.onClose();
  }
}
