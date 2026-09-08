import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/fnos/fn_os_models.dart';
import 'package:simple_live_tv_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_tv_app/modules/settings/fnos/fn_os_season_detail_page.dart';
import 'package:simple_live_tv_app/routes/app_navigation.dart';
import 'package:simple_live_tv_app/services/local_storage_service.dart';
import 'package:simple_live_tv_app/widgets/focus_card.dart';
import 'package:simple_live_tv_app/widgets/net_image.dart';
import 'package:simple_live_tv_app/widgets/shadow_card.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

/// 飞牛影视浏览页：先显示影视库（媒体数据库）网格，点选后显示该库内容——
/// 电影库展示电影海报，电视剧库展示「电视剧」海报（一部一海报）。
///
/// 与其它端保持一致：
/// - 点电影 → 直接进播放页（信息 tab 承担详情职能），不再经过详情页；
/// - 点电视剧 → 进选集页（可切季/切集，页内有「播放第一集」），不再是详情页。
/// 影视详情页（FnOsDetailPage）已从 TV 端移除。
class FnOsBrowsePage extends StatefulWidget {
  /// 单个服务器浏览时传 server；null 表示聚合所有服务器（「电影电视」首页入口）。
  final FnOsServer? server;
  final bool embedded; // 作为首页/分类标签页嵌入时不显示返回箭头
  const FnOsBrowsePage({
    Key? key,
    this.server,
    this.embedded = false,
  }) : super(key: key);

  @override
  State<FnOsBrowsePage> createState() => _FnOsBrowsePageState();
}

/// 排序字段。
/// 排序字段（顺序同参考图：添加日期/发行日期/标题/评分）。
enum _SortBy { addDate, releaseDate, title, rating }

/// 排序方向哨兵（用于排序下拉的「升序/降序」菜单项）。
const _kSortAsc = '__sort_asc__';
const _kSortDesc = '__sort_desc__';

class _FnOsBrowsePageState extends State<FnOsBrowsePage> {
  bool _loadingLibs = true;
  String? _libsError;
  /// mediadb/sum 精确统计：movie/tv/total/各库 guid 计数（与飞牛 UI 一致）。
  Map<String, int> _librarySummary = {};

  /// 全部影视库合并内容（电影 + 剧集）。
  final List<FnOsMovie> _allMovies = [];
  final List<FnOsTvSeries> _allSeries = [];

  /// 聚合模式（server==null）下，记录每个内容所属的服务器（guid → server）。
  final Map<String, FnOsServer> _movieServer = {};
  final Map<String, FnOsServer> _seriesServer = {};

  /// 类型切换：0=全部 1=电影 2=电视剧（AppBar 右上角二级选择）。
  int _contentType = 0;

  late final StreamSubscription<dynamic> _sourcesSub;

  _SortBy _sortBy = _SortBy.addDate;
  bool _sortAsc = true;

  /// 内容所属服务器：单服务器模式返回 widget.server，聚合模式按 guid 查映射。
  FnOsServer? _serverForMovie(FnOsMovie m) =>
      widget.server ?? _movieServer[m.guid];
  FnOsServer? _serverForSeries(FnOsTvSeries s) =>
      widget.server ?? _seriesServer[s.guid];

  /// 排序记忆（跨平台、跨页面保持，不随切换恢复默认）。
  void _restoreSortPrefs() {
    final saved = LocalStorageService.instance
        .getValue(LocalStorageService.kFnOsSort, "");
    if (saved.isEmpty) return;
    final parts = saved.split("|");
    if (parts.length < 2) return;
    _sortBy = _SortBy.values.firstWhere(
      (e) => e.name == parts[0],
      orElse: () => _SortBy.addDate,
    );
    _sortAsc = parts[1] == "asc";
  }

  void _saveSortPrefs() {
    LocalStorageService.instance.setValue(
      LocalStorageService.kFnOsSort,
      "${_sortBy.name}|${_sortAsc ? 'asc' : 'desc'}",
    );
  }

  @override
  void initState() {
    super.initState();
    _restoreSortPrefs();
    // 自动刷新调度触发时，重新拉取本服务器的影视库内容。
    _sourcesSub = EventBus.instance.listen(
      EventBus.kCustomSourcesChanged,
      (_) => _loadLibraries(showLoading: false),
    );
    _loadLibraries();
  }

  @override
  void dispose() {
    _sourcesSub.cancel();
    super.dispose();
  }

  /// 拉取全部影视库内容并合并（电影 + 剧集），一次展示。
  /// 聚合模式（server==null）下遍历所有服务器并合并，记录每个内容的来源服务器。
  Future<void> _loadLibraries({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _loadingLibs = true;
        _libsError = null;
      });
    }
    try {
      final servers = widget.server != null
          ? <FnOsServer>[widget.server!]
          : List<FnOsServer>.from(FnOsService.instance.servers);
      _allMovies.clear();
      _allSeries.clear();
      _movieServer.clear();
      _seriesServer.clear();
      final summary = <String, int>{};
      for (final server in servers) {
        try {
          final libs = await FnOsService.instance.getLibraries(server);
          for (final lib in libs) {
            final content =
                await FnOsService.instance.getLibraryContent(server, lib);
            _allMovies.addAll(content.movies);
            _allSeries.addAll(content.series);
            for (final m in content.movies) {
              _movieServer[m.guid] = server;
            }
            for (final s in content.series) {
              _seriesServer[s.guid] = server;
            }
          }
        } catch (_) {
          // 单个服务器失败不影响其余
        }
        try {
          final s = await FnOsService.instance.getLibrarySummary(server);
          s.forEach((k, v) {
            summary[k] = (summary[k] ?? 0) + v;
          });
        } catch (_) {
          // 统计失败不影响内容展示
        }
      }
      _librarySummary = summary;
    } catch (e) {
      _libsError = e.toString();
    } finally {
      if (mounted) setState(() => _loadingLibs = false);
    }
  }

  void _refreshLibraries() {
    _loadLibraries();
  }

  void _openMovie(FnOsMovie movie) {
    final server = _serverForMovie(movie);
    if (server == null) return;
    final site = FnOsService.instance.siteForServer(server.id);
    if (site == null) {
      SmartDialog.showToast("未找到该影视站点，请在设置里重新添加");
      return;
    }
    // 与其它端一致：电影点击直接进播放页（信息 tab 承担详情职能）。
    AppNavigator.toLiveRoomDetail(site: site, roomId: movie.guid, isVod: true);
  }

  Future<void> _openSeries(FnOsTvSeries series) async {
    final server = _serverForSeries(series);
    if (server == null) return;
    final site = FnOsService.instance.siteForServer(server.id);
    if (site == null) {
      SmartDialog.showToast("未找到该影视站点，请在设置里重新添加");
      return;
    }
    try {
      // 必须用 season/list 取季（item/list 的 parent_guid 实测大量失配），
      // 取不到再退到列表构建时匹配到的季。
      var seasons = <FnOsSeason>[];
      try {
        seasons = await FnOsService.instance.getSeasons(server, series.guid);
      } catch (_) {
        // 接口失败走下面兜底
      }
      if (seasons.isEmpty) {
        seasons = series.seasons;
      }
      if (seasons.isNotEmpty) {
        // 剧：进选集页（可切季/切集，页内「播放第一集」一键开播），
        // 不再是详情页。
        Get.to(
          () => FnOsSeasonDetailPage(
            server: server,
            series: series,
            season: seasons.first,
          ),
        );
        return;
      }
      // 兜底：该条目本身就是季（部分库没有剧层级，顶层即 Season）。
      final eps = await FnOsService.instance.getEpisodes(server, series.guid);
      if (eps.isNotEmpty) {
        AppNavigator.toLiveRoomDetail(
          site: site,
          roomId: eps.first.guid,
          isVod: true,
        );
        return;
      }
      SmartDialog.showToast("该剧暂无剧集");
    } catch (e) {
      SmartDialog.showToast("无法打开：$e");
    }
  }

  // ─────────────── 排序/筛选/布局 ───────────────

  List<FnOsMovie> _sortedMovies() {
    final src = _allMovies;
    var filtered = src.toList();
    if (_sortBy == _SortBy.addDate) {
      // 「添加日期」按服务器返回顺序（通常即添加顺序）；降序=反转
      if (!_sortAsc) filtered = filtered.reversed.toList();
      return filtered;
    }
    filtered.sort((a, b) {
      int cmp;
      switch (_sortBy) {
        case _SortBy.title:
          cmp = a.title.compareTo(b.title);
          break;
        case _SortBy.rating:
          cmp = (a.rating ?? 0).compareTo(b.rating ?? 0);
          break;
        case _SortBy.releaseDate:
          cmp = (a.releaseDate ?? '').compareTo(b.releaseDate ?? '');
          break;
        case _SortBy.addDate:
          cmp = 0;
          break;
      }
      if (cmp == 0) cmp = a.title.compareTo(b.title);
      return _sortAsc ? cmp : -cmp;
    });
    return filtered;
  }

  List<FnOsTvSeries> _sortedSeries() {
    final src = _allSeries;
    var filtered = src.toList();
    if (_sortBy == _SortBy.addDate) {
      if (!_sortAsc) filtered = filtered.reversed.toList();
      return filtered;
    }
    filtered.sort((a, b) {
      int cmp;
      switch (_sortBy) {
        case _SortBy.title:
          cmp = a.title.compareTo(b.title);
          break;
        case _SortBy.rating:
          cmp = (a.rating ?? 0).compareTo(b.rating ?? 0);
          break;
        case _SortBy.releaseDate:
          cmp = (a.firstAirDate ?? '').compareTo(b.firstAirDate ?? '');
          break;
        case _SortBy.addDate:
          cmp = 0;
          break;
      }
      if (cmp == 0) cmp = a.title.compareTo(b.title);
      return _sortAsc ? cmp : -cmp;
    });
    return filtered;
  }

  String get _sortByLabel {
    switch (_sortBy) {
      case _SortBy.addDate:
        return '添加日期';
      case _SortBy.releaseDate:
        return '发行日期';
      case _SortBy.title:
        return '标题';
      case _SortBy.rating:
        return '评分';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: widget.embedded ? false : true,
        // 标题两行：服务器名 + 全局统计（与右侧「类型/刷新」按钮同一行展示）。
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.server == null
                  ? '电影电视'
                  : (widget.server!.name.isEmpty
                      ? 'NAS影视库'
                      : widget.server!.name),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            if (_summaryText.isNotEmpty)
              Text(
                _summaryText,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          // 类型二级选择：全部 / 电影 / 电视剧
          PopupMenuButton<int>(
            tooltip: '类型',
            icon: const Icon(Icons.filter_list),
            initialValue: _contentType,
            onSelected: (v) => setState(() => _contentType = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 0, child: Text('全部')),
              PopupMenuItem(value: 1, child: Text('电影')),
              PopupMenuItem(value: 2, child: Text('电视剧')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新影视库',
            onPressed: _refreshLibraries,
          ),
        ],
      ),
      body: _buildAllContent(),
    );
  }

  /// 全部影视内容（按类型过滤展示）。
  Widget _buildAllContent() {
    if (_loadingLibs) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_libsError != null) {
      return _ErrorView(message: _libsError!, onRetry: _loadLibraries);
    }
    final movies = _sortedMovies();
    final series = _sortedSeries();
    if (movies.isEmpty && series.isEmpty) {
      return const Center(child: Text('该服务器暂无影视内容'));
    }
    final showMovies = _contentType != 2;
    final showSeries = _contentType != 1;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildContentToolbar()),
        if (showMovies && movies.isNotEmpty) _buildMovieSliver(movies),
        if (showSeries && series.isNotEmpty) _buildSeriesSliver(series),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  /// 全局统计文本：mediadb/sum 的 total/movie/tv（与飞牛 UI 精确一致），显示在标题副行。
  String get _summaryText {
    final total = _librarySummary['total'];
    final movie = _librarySummary['movie'];
    final tv = _librarySummary['tv'];
    final parts = <String>[];
    if (movie != null) parts.add('电影 $movie');
    if (tv != null) parts.add('电视剧 $tv');
    if (parts.isEmpty) return '';
    return total != null
        ? '共 $total 部 · ${parts.join(' · ')}'
        : parts.join(' · ');
  }


  /// 影视库内容区顶部工具栏：排序（统计已上移标题栏，刷新在 AppBar）。
  Widget _buildContentToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        children: [
          const Spacer(),
          PopupMenuButton<Object?>(
            tooltip: '排序',
            onSelected: (v) => setState(() {
              if (v is _SortBy) {
                _sortBy = v;
              } else if (v == _kSortAsc) {
                _sortAsc = true;
              } else if (v == _kSortDesc) {
                _sortAsc = false;
              }
              _saveSortPrefs();
            }),
            itemBuilder: (_) => [
              for (final v in _SortBy.values)
                PopupMenuItem(
                  value: v,
                  child: Row(
                    children: [
                      Icon(
                        _sortBy == v ? Icons.check : null,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(_labelFor(v)),
                    ],
                  ),
                ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: _kSortAsc,
                child: Row(
                  children: [
                    Icon(
                      _sortAsc ? Icons.check : null,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    const Text('升序'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: _kSortDesc,
                child: Row(
                  children: [
                    Icon(
                      !_sortAsc ? Icons.check : null,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    const Text('降序'),
                  ],
                ),
              ),
            ],
            child: Row(
              children: [
                Text('$_sortByLabel${_sortAsc ? '↑' : '↓'}'),
                const Icon(Icons.arrow_drop_down, size: 18),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _labelFor(_SortBy v) {
    switch (v) {
      case _SortBy.addDate:
        return '添加日期';
      case _SortBy.releaseDate:
        return '发行日期';
      case _SortBy.title:
        return '标题';
      case _SortBy.rating:
        return '评分';
    }
  }

  /// 影视海报网格：portrait 2:3 紧凑卡片（固定竖幅）。
  static const double _kGridPadding = 10;
  static const double _kGridSpacing = 10;
  // 与其它端（手机/iOS/Windows）保持一致：同为 100，列密度/卡片观感一致
  // （TV 只是屏幕更大 → 列数更多，单卡最小宽度不变）。
  static const double _kMinCardWidth = 100;
  static const int _kMinColumns = 2;
  static const int _kMaxColumns = 8;

  Widget _buildMovieSliver(List<FnOsMovie> movies) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(_kGridPadding, 4, _kGridPadding, _kGridPadding),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final columns = _gridColumns(constraints.crossAxisExtent);
          final contentWidth = math.max(
            0.0,
            constraints.crossAxisExtent - _kGridPadding * 2,
          );
          final cardsWidth = math.max(
            0.0,
            contentWidth - _kGridSpacing * (columns - 1),
          );
          final itemWidth = cardsWidth / columns;
          final mainAxisExtent = itemWidth / (2 / 3);
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: _kGridSpacing,
              crossAxisSpacing: _kGridSpacing,
              mainAxisExtent: mainAxisExtent,
            ),
            delegate: SliverChildBuilderDelegate(
              (_, i) {
                final m = movies[i];
                return FocusCard(
                  onActivate: () => _openMovie(m),
                  child: _buildPortraitMovieCard(m),
                );
              },
              childCount: movies.length,
            ),
          );
        },
      ),
    );
  }

  Widget _buildSeriesSliver(List<FnOsTvSeries> series) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(_kGridPadding, 4, _kGridPadding, _kGridPadding),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final columns = _gridColumns(constraints.crossAxisExtent);
          final contentWidth = math.max(
            0.0,
            constraints.crossAxisExtent - _kGridPadding * 2,
          );
          final cardsWidth = math.max(
            0.0,
            contentWidth - _kGridSpacing * (columns - 1),
          );
          final itemWidth = cardsWidth / columns;
          final mainAxisExtent = itemWidth / (2 / 3);
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: _kGridSpacing,
              crossAxisSpacing: _kGridSpacing,
              mainAxisExtent: mainAxisExtent,
            ),
            delegate: SliverChildBuilderDelegate(
              (_, i) {
                final s = series[i];
                return FocusCard(
                  onActivate: () => _openSeries(s),
                  child: _buildPortraitSeriesCard(s),
                );
              },
              childCount: series.length,
            ),
          );
        },
      ),
    );
  }

  int _gridColumns(double viewportWidth) {
    final contentWidth = math.max(0.0, viewportWidth - _kGridPadding * 2);
    final desired = ((contentWidth + _kGridSpacing) /
            (_kMinCardWidth + _kGridSpacing))
        .floor();
    return desired.clamp(_kMinColumns, _kMaxColumns);
  }

  Widget _buildPortraitMovieCard(FnOsMovie m) {
    final server = _serverForMovie(m)!;
    final poster = FnOsService.instance.posterUrl(server, m.poster);
    final hasPoster = poster.isNotEmpty;
    final theme = Theme.of(context);
    return ShadowCard(
      onTap: () => _openMovie(m),
      child: AspectRatio(
        aspectRatio: 2 / 3, // 电影海报竖向比例，避免 16:9 横向造成灰色留白
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: hasPoster
                    ? NetImage(poster,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        httpHeaders: FnOsService.instance.imageHeaders(server),
                        )
                    : Center(
                        child: Icon(Icons.movie_outlined,
                            size: 32,
                            color:
                                theme.colorScheme.primary.withAlpha(120)),
                      ),
              ),
              // 评分角标（左上）
              if (m.rating != null && m.rating! > 0)
                Positioned(
                  top: 6,
                  left: 6,
                  child: _ScoreBadge(rating: m.rating!),
                ),
              // 分辨率角标（右上）
              if (m.mediaStream.resolutions.isNotEmpty)
                Positioned(
                  top: 6,
                  right: 6,
                  child: _InfoBadge(
                    label: m.mediaStream.resolutions.first.toUpperCase(),
                  ),
                ),
              // 底部黑色渐变 + 标题 + 元数据（Jellyfin 风格：海报底部一体化）
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding:
                      const EdgeInsets.fromLTRB(8, 16, 8, 6),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black87,
                      ],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        m.title.isEmpty ? m.guid : m.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                          height: 1.2,
                        ),
                      ),
                      if (m.year != null || m.durationText.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          [
                            if (m.year != null) '${m.year}',
                            if (m.durationText.isNotEmpty) m.durationText,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPortraitSeriesCard(FnOsTvSeries s) {
    final server = _serverForSeries(s)!;
    final poster = FnOsService.instance.posterUrl(server, s.poster);
    final hasPoster = poster.isNotEmpty;
    final theme = Theme.of(context);
    return ShadowCard(
      onTap: () => _openSeries(s),
      child: AspectRatio(
        aspectRatio: 2 / 3, // 剧集海报竖向比例，避免 16:9 横向造成灰色留白
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: hasPoster
                    ? NetImage(poster,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        httpHeaders: FnOsService.instance.imageHeaders(server),
                        )
                    : Center(
                        child: Icon(Icons.tv_outlined,
                            size: 32,
                            color:
                                theme.colorScheme.primary.withAlpha(120)),
                      ),
              ),
              // 评分角标（左上）
              if (s.rating != null && s.rating! > 0)
                Positioned(
                  top: 6,
                  left: 6,
                  child: _ScoreBadge(rating: s.rating!),
                ),
              // 分辨率角标（右上）
              if (s.mediaStream.resolutions.isNotEmpty)
                Positioned(
                  top: 6,
                  right: 6,
                  child: _InfoBadge(
                    label: s.mediaStream.resolutions.first.toUpperCase(),
                  ),
                ),
              // 底部黑色渐变 + 标题 + 季/集数（Jellyfin 风格：海报底部一体化）
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding:
                      const EdgeInsets.fromLTRB(8, 16, 8, 6),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black87,
                      ],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        s.title.isEmpty ? s.guid : s.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                          height: 1.2,
                        ),
                      ),
                      if (s.numberOfSeasons > 0 || s.numberOfEpisodes > 0) ...[
                        const SizedBox(height: 2),
                        Text(
                          s.numberOfSeasons > 0
                              ? '${s.numberOfSeasons} 季 · ${s.numberOfEpisodes} 集'
                              : '${s.numberOfEpisodes} 集',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('加载失败：$message'),
          const SizedBox(height: 12),
          ElevatedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

/// 海报角标：评分（橙底胶囊 ★ 9.1）。
class _ScoreBadge extends StatelessWidget {
  final double rating;
  const _ScoreBadge({required this.rating});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF5A623),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '★ ${rating.toStringAsFixed(1)}',
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// 海报角标：通用信息（分辨率等，半透明黑底）。
class _InfoBadge extends StatelessWidget {
  final String label;
  const _InfoBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(150),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}
