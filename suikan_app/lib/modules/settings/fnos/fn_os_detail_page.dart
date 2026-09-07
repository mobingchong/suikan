import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/fnos/fn_os_models.dart';
import 'package:simple_live_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/shadow_card.dart';

import 'fn_os_season_detail_page.dart';

/// 飞牛影视详情页：电影展示海报/简介 + 播放按钮；电视剧展示海报/简介 + 季卡片。
/// 不会自动播放，必须用户点「播放」或某集才进入直播间。
class FnOsDetailPage extends StatefulWidget {
  final FnOsMovie? movie;
  final FnOsTvSeries? series;
  final FnOsServer server;

  const FnOsDetailPage({
    Key? key,
    this.movie,
    this.series,
    required this.server,
  })  : assert(movie != null || series != null,
            'movie 与 series 必须提供一个'),
        super(key: key);

  @override
  State<FnOsDetailPage> createState() => _FnOsDetailPageState();
}

class _FnOsDetailPageState extends State<FnOsDetailPage> {
  bool _loading = true;
  String? _error;
  FnOsMovie? _movie;
  FnOsTvSeries? _series;

  Site? get _site => FnOsService.instance.siteForServer(widget.server.id);

  bool get _isMovie => _movie != null;

  String get _title => _isMovie ? _movie!.title : _series!.title;

  String? get _poster => _isMovie ? _movie!.poster : _series!.poster;

  String? get _backdrop => _isMovie ? _movie!.backdrop : _series!.backdrop;

  @override
  void initState() {
    super.initState();
    _movie = widget.movie;
    _series = widget.series;
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    try {
      if (_isMovie) {
        final enriched = await FnOsService.instance.fetchMovieDetail(
          widget.server,
          _movie!,
        );
        if (mounted) {
          setState(() {
            _movie = enriched;
            _loading = false;
          });
        }
      } else {
        final enriched = await FnOsService.instance.fetchTvSeriesDetail(
          widget.server,
          _series!,
        );
        // 用官方 season/episode 接口重建正确层级（item 详情不含 seasons，
        // item/list 的 parent_guid 关系不可靠，参照 thshu/fnos-tv）。
        var seasons = <FnOsSeason>[];
        try {
          final official = await FnOsService.instance.getSeasons(
            widget.server,
            enriched.guid,
          );
          if (official.isNotEmpty) {
            seasons = <FnOsSeason>[];
            for (var i = 0; i < official.length; i++) {
              final eps = await FnOsService.instance.getEpisodes(
                widget.server,
                official[i].guid,
              );
              seasons.add(official[i].copyWith(episodes: eps));
            }
            seasons.sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
          }
        } catch (_) {
          seasons = const [];
        }
        if (seasons.isEmpty) {
          seasons = enriched.seasons; // 官方接口不可用时退回列表重建数据
        }
        final updated = enriched.copyWith(seasons: seasons);
        if (mounted) {
          setState(() {
            _series = updated;
            _loading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _play(String guid) {
    final site = _site;
    if (site == null) {
      SmartDialog.showToast('服务器未就绪');
      return;
    }
    AppNavigator.toLiveRoomDetail(site: site, roomId: guid, isVod: true);
  }

  void _playFirst() {
    if (_isMovie) {
      _play(_movie!.guid);
    } else {
      final seasons = _series!.seasons;
      if (seasons.isEmpty) return;
      final eps = seasons.first.episodes;
      if (eps.isEmpty) {
        SmartDialog.showToast('暂无剧集');
        return;
      }
      _play(eps.first.guid);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _loadDetail)
              : CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: _DetailHeader(
                        server: widget.server,
                        title: _title,
                        poster: FnOsService.instance.posterUrl(
                          widget.server,
                          _poster,
                        ),
                        backdrop: FnOsService.instance.posterUrl(
                          widget.server,
                          _backdrop,
                        ),
                        rating: _isMovie ? _movie!.rating : _series!.rating,
                        contentRating: _isMovie
                            ? _movie!.contentRating
                            : _series!.contentRating,
                        year: _isMovie ? _movie!.year : _series!.year,
                        duration: _isMovie ? _movie!.durationText : '',
                        genres: _isMovie ? _movie!.genres : _series!.genres,
                        productionCountries: _isMovie
                            ? _movie!.productionCountries
                            : _series!.productionCountries,
                        mediaStream: _isMovie
                            ? _movie!.mediaStream
                            : _series!.mediaStream,
                        typeText: _isMovie ? '电影' : '电视剧',
                        onPlay: _playFirst,
                        isFavorite: _isMovie
                            ? _movie!.isFavorite
                            : _series!.isFavorite,
                        isWatched: _isMovie
                            ? _movie!.isWatched
                            : _series!.isWatched,
                        playLabel: _isMovie
                            ? '播放'
                            : _series!.seasons.isEmpty
                                ? '播放'
                                : '第 ${_series!.seasons.first.seasonNumber} 季 第 1 集',
                      ),
                    ),
                    SliverPadding(
                      padding: AppStyle.edgeInsetsH12 +
                          const EdgeInsets.only(bottom: 12),
                      sliver: SliverToBoxAdapter(
                        child: _Synopsis(
                          text: _isMovie
                              ? _movie!.overview
                              : _series!.overview,
                        ),
                      ),
                    ),
                    if (_isMovie && _movie!.cast.isNotEmpty)
                      _sliverSection(context, '演职人员', _CastRow(
                        cast: _movie!.cast,
                        server: widget.server,
                      )),
                    if (!_isMovie && _series!.cast.isNotEmpty)
                      _sliverSection(context, '演职人员', _CastRow(
                        cast: _series!.cast,
                        server: widget.server,
                      )),
                    if (_isMovie) ...[
                      _buildFileInfo(context, _movie!),
                      _buildVideoInfo(context, _movie!.mediaStream),
                    ],
                    if (!_isMovie) ...[
                      _sliverSection(
                        context,
                        '季',
                        _SeasonList(
                          server: widget.server,
                          series: _series!,
                        ),
                      ),
                    ],
                    const SliverPadding(
                      padding: EdgeInsets.only(bottom: 24),
                    ),
                  ],
                ),
    );
  }

  Widget _sliverSection(BuildContext context, String title, Widget child) {
    final theme = Theme.of(context);
    return SliverPadding(
      padding: AppStyle.edgeInsetsH12 +
          const EdgeInsets.only(top: 24, bottom: 0),
      sliver: SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            AppStyle.vGap12,
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildFileInfo(BuildContext context, FnOsMovie movie) {
    // 列表接口不返回文件信息，仅详情可能返回 path/file_name。
    // 这里主要展示时长等可用信息，文件大小等字段暂无数据则隐藏。
    final rows = <Widget>[];
    if (movie.durationText.isNotEmpty) {
      rows.add(_infoRow(context, '时长', movie.durationText));
    }
    if (rows.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
    return _sliverSection(
      context,
      '文件信息',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  Widget _buildVideoInfo(BuildContext context, FnOsMediaStream mediaStream) {
    if (mediaStream.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
    final rows = <Widget>[
      if (mediaStream.resolutions.isNotEmpty)
        _infoRow(context, '分辨率', mediaStream.resolutions.join(' / ')),
      if (mediaStream.audioTypes.isNotEmpty)
        _infoRow(context, '音频', mediaStream.audioTypes.join(' / ')),
      if (mediaStream.colorRangeTypes.isNotEmpty)
        _infoRow(context, '色彩范围', mediaStream.colorRangeTypes.join(' / ')),
    ];
    if (rows.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
    return _sliverSection(
      context,
      '视频信息',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  static Widget _infoRow(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailHeader extends StatelessWidget {
  final FnOsServer server;
  final String title;
  final String poster;
  final String backdrop;
  final double? rating;
  final String? contentRating;
  final int? year;
  final String duration;
  final List<String> genres;
  final List<String> productionCountries;
  final FnOsMediaStream mediaStream;
  final String typeText;
  final VoidCallback onPlay;
  final bool isFavorite;
  final bool isWatched;
  final String playLabel;

  const _DetailHeader({
    required this.server,
    required this.title,
    required this.poster,
    required this.backdrop,
    this.rating,
    this.contentRating,
    this.year,
    required this.duration,
    required this.genres,
    required this.productionCountries,
    required this.mediaStream,
    required this.typeText,
    required this.onPlay,
    required this.isFavorite,
    required this.isWatched,
    required this.playLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasBackdrop = backdrop.isNotEmpty;
    final hasPoster = poster.isNotEmpty;

    return Stack(
      children: [
        // 背景海报
        if (hasBackdrop)
          Positioned.fill(
            child: NetImage(
              backdrop,
              fit: BoxFit.cover,
              width: double.infinity,
              height: 300,
              httpHeaders: FnOsService.instance.imageHeaders(server),
            ),
          ),
        // 渐变遮罩（上淡下深，确保文字可读）
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: hasBackdrop
                  ? [
                      colorScheme.surface.withAlpha(40),
                      colorScheme.surface.withAlpha(180),
                      colorScheme.surface,
                    ]
                  : [colorScheme.surface, colorScheme.surface],
            ),
          ),
          padding: EdgeInsets.fromLTRB(
            12,
            MediaQuery.of(context).padding.top + 8,
            12,
            16,
          ),
          child: SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部返回 + 操作区占位
                SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // 海报
                    if (hasPoster)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 150,
                          child: AspectRatio(
                            aspectRatio: 2 / 3,
                            child: NetImage(
                              poster,
                              fit: BoxFit.cover,
                              width: 150,
                              httpHeaders: FnOsService.instance.imageHeaders(server),
                            ),
                          ),
                        ),
                      )
                    else
                      SizedBox(
                        width: 150,
                        child: AspectRatio(
                          aspectRatio: 2 / 3,
                          child: ColoredBox(
                            color: colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.movie_outlined,
                              size: 40,
                              color: colorScheme.primary.withAlpha(120),
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(width: 16),
                    // 标题与元信息
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title.isEmpty ? '未命名' : title,
                            style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 8),
                          _MetaRow(
                            rating: rating,
                            contentRating: contentRating,
                            year: year,
                            duration: duration,
                            genres: genres,
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              FilledButton.icon(
                                onPressed: onPlay,
                                icon: const Icon(Icons.play_arrow, size: 18),
                                label: Text(playLabel),
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              _CircleAction(
                                icon: isFavorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                onPressed: () {
                                  SmartDialog.showToast('收藏功能开发中');
                                },
                              ),
                              const SizedBox(width: 8),
                              _CircleAction(
                                icon: isWatched
                                    ? Icons.visibility
                                    : Icons.visibility_outlined,
                                onPressed: () {
                                  SmartDialog.showToast('观看标记开发中');
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 第二行元信息：国家 / 分辨率 / 音频类型 / SDR / 类型
                _SecondaryMetaRow(
                  countries: productionCountries,
                  mediaStream: mediaStream,
                  typeText: typeText,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MetaRow extends StatelessWidget {
  final double? rating;
  final String? contentRating;
  final int? year;
  final String duration;
  final List<String> genres;

  const _MetaRow({
    this.rating,
    this.contentRating,
    this.year,
    required this.duration,
    required this.genres,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = <Widget>[];
    if (rating != null && rating! > 0) {
      items.add(Text(
        '${rating!.toStringAsFixed(1)} 分',
        style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.orange,
              fontWeight: FontWeight.w600,
            ),
      ));
    }
    if (contentRating != null && contentRating!.isNotEmpty) {
      _addSeparator(items);
      items.add(Text(contentRating!, style: theme.textTheme.bodyMedium));
    }
    if (year != null) {
      _addSeparator(items);
      items.add(Text(year.toString(), style: theme.textTheme.bodyMedium));
    }
    if (duration.isNotEmpty) {
      _addSeparator(items);
      items.add(Text(duration, style: theme.textTheme.bodyMedium));
    }
    if (genres.isNotEmpty) {
      _addSeparator(items);
      items.add(Text(genres.join(' · '), style: theme.textTheme.bodyMedium));
    }
    if (items.isEmpty) return const SizedBox.shrink();
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      runSpacing: 4,
      children: items,
    );
  }

  void _addSeparator(List<Widget> items) {
    if (items.isNotEmpty) {
      items.add(Text('·', style: Theme.of(Get.context!).textTheme.bodyMedium));
    }
  }
}

class _SecondaryMetaRow extends StatelessWidget {
  final List<String> countries;
  final FnOsMediaStream mediaStream;
  final String typeText;

  const _SecondaryMetaRow({
    required this.countries,
    required this.mediaStream,
    required this.typeText,
  });

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[];

    if (countries.isNotEmpty) {
      chips.add(_Chip(countries.join(' / ')));
    }
    if (mediaStream.resolutions.isNotEmpty) {
      chips.add(_Chip(mediaStream.resolutions.first.toUpperCase()));
    }
    if (mediaStream.colorRangeTypes.isNotEmpty) {
      chips.add(_Chip(mediaStream.colorRangeTypes.first));
    }
    if (mediaStream.audioTypes.isNotEmpty) {
      chips.add(_Chip(mediaStream.audioTypes.first));
    }
    chips.add(_Chip(typeText));

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: chips,
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  const _Chip(this.label);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}

class _CircleAction extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  const _CircleAction({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IconButton.outlined(
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      style: IconButton.styleFrom(
        minimumSize: const Size(40, 40),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
    );
  }
}

class _Synopsis extends StatefulWidget {
  final String? text;
  const _Synopsis({this.text});

  @override
  State<_Synopsis> createState() => _SynopsisState();
}

class _SynopsisState extends State<_Synopsis> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = widget.text;
    if (text == null || text.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final span = TextSpan(
          text: text,
          style: theme.textTheme.bodyMedium,
        );
        final painter = TextPainter(
          text: span,
          maxLines: 3,
          textDirection: TextDirection.ltr,
        );
        painter.layout(maxWidth: constraints.maxWidth);
        final exceeded = painter.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              style: theme.textTheme.bodyMedium,
              maxLines: _expanded ? null : 3,
              overflow: _expanded ? null : TextOverflow.ellipsis,
            ),
            if (exceeded)
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _expanded ? '收起' : '更多',
                    style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CastRow extends StatelessWidget {
  final List<FnOsCastMember> cast;
  final FnOsServer server;
  const _CastRow({required this.cast, required this.server});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 110,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: cast.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final c = cast[i];
          final photo = FnOsService.instance.posterUrl(server, c.photo);
          return SizedBox(
            width: 70,
            child: Column(
              children: [
                ClipOval(
                  child: photo.isNotEmpty
                      ? NetImage(
                          photo,
                          fit: BoxFit.cover,
                          width: 56,
                          height: 56,
                          httpHeaders: FnOsService.instance.imageHeaders(server),
                        )
                      : Container(
                          width: 56,
                          height: 56,
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.person_outline,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                ),
                const SizedBox(height: 6),
                Text(
                  c.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SeasonList extends StatelessWidget {
  final FnOsServer server;
  final FnOsTvSeries series;
  const _SeasonList({required this.server, required this.series});

  @override
  Widget build(BuildContext context) {
    final seasons = series.seasons;
    if (seasons.isEmpty) {
      return const Text('暂无分季信息');
    }
    return SizedBox(
      height: 180,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: seasons.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final s = seasons[i];
          final poster = FnOsService.instance.posterUrl(server, s.poster);
          return SizedBox(
            width: 110,
            child: ShadowCard(
              onTap: () {
                Get.to(() => FnOsSeasonDetailPage(
                      server: server,
                      series: series,
                      season: s,
                    ));
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(8),
                        topRight: Radius.circular(8),
                      ),
                      child: ColoredBox(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        child: poster.isNotEmpty
                            ? NetImage(
                                poster,
                                fit: BoxFit.cover,
                                width: double.infinity,
                                httpHeaders: FnOsService.instance.imageHeaders(server),
                              )
                            : Center(
                                child: Icon(
                                  Icons.tv_outlined,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary
                                      .withAlpha(120),
                                ),
                              ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: AppStyle.edgeInsetsA8,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '${s.episodes.length} 集${s.airDate != null && s.airDate!.length >= 4 ? ' · ${s.airDate!.substring(0, 4)}' : ''}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
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
