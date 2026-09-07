import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/fnos/fn_os_models.dart';
import 'package:simple_live_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/widgets/net_image.dart';

/// 飞牛影视「季」详情页：展示该季的海报、简介、集数网格，点集播放。
class FnOsSeasonDetailPage extends StatefulWidget {
  final FnOsServer server;
  final FnOsTvSeries series;
  final FnOsSeason season;

  const FnOsSeasonDetailPage({
    Key? key,
    required this.server,
    required this.series,
    required this.season,
  }) : super(key: key);

  @override
  State<FnOsSeasonDetailPage> createState() => _FnOsSeasonDetailPageState();
}

class _FnOsSeasonDetailPageState extends State<FnOsSeasonDetailPage> {
  late FnOsSeason _season;

  Site? get _site => FnOsService.instance.siteForServer(widget.server.id);

  @override
  void initState() {
    super.initState();
    _season = widget.season;
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
    final eps = _season.episodes;
    if (eps.isEmpty) {
      SmartDialog.showToast('该季暂无集');
      return;
    }
    _play(eps.first.guid);
  }

  void _switchSeason(FnOsSeason newSeason) {
    setState(() => _season = newSeason);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final poster = FnOsService.instance.posterUrl(widget.server, _season.poster);

    return Scaffold(
      appBar: AppBar(
        title: Text(_season.title),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 120,
                  child: AspectRatio(
                    aspectRatio: 2 / 3,
                    child: poster.isNotEmpty
                        ? NetImage(
                            poster,
                            fit: BoxFit.cover,
                            width: 120,
                            httpHeaders: FnOsService.instance.imageHeaders(widget.server),
                          )
                        : ColoredBox(
                            color: colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.tv_outlined,
                              color: colorScheme.primary.withAlpha(120),
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.series.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _season.title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 8),
                    _SeasonMetaRow(
                      rating: _season.rating ?? widget.series.rating,
                      year: widget.series.year,
                      airDate: _season.airDate,
                      episodeCount: _season.episodes.length,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: _playFirst,
                          icon: const Icon(Icons.play_arrow, size: 18),
                          label: Text(_season.episodes.isEmpty
                              ? '播放'
                              : '第 ${_season.episodes.first.episodeNumber} 集'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.outlined(
                          onPressed: () {
                            SmartDialog.showToast('观看标记开发中');
                          },
                          icon: Icon(
                            widget.series.isWatched
                                ? Icons.visibility
                                : Icons.visibility_outlined,
                            size: 20,
                          ),
                          style: IconButton.styleFrom(
                            minimumSize: const Size(40, 40),
                            side: BorderSide(color: colorScheme.outlineVariant),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_season.overview != null && _season.overview!.isNotEmpty) ...[
            const SizedBox(height: 16),
            _Synopsis(text: _season.overview),
          ],
          AppStyle.vGap24,
          // 季切换 + 视图切换占位
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: _showSeasonPicker,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: colorScheme.outlineVariant),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _season.title,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.arrow_drop_down,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _EpisodeGrid(
            episodes: _season.episodes,
            onTap: _play,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  void _showSeasonPicker() {
    final seasons = widget.series.seasons;
    if (seasons.length < 2) return;
    showModalBottomSheet(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    '选择季',
                    style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                ...seasons.map((s) => ListTile(
                      title: Text(s.title),
                      subtitle: Text('${s.episodes.length} 集'),
                      selected: s.guid == _season.guid,
                      onTap: () {
                        _switchSeason(s);
                        Navigator.of(context).pop();
                      },
                    )),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SeasonMetaRow extends StatelessWidget {
  final double? rating;
  final int? year;
  final String? airDate;
  final int episodeCount;

  const _SeasonMetaRow({
    this.rating,
    this.year,
    this.airDate,
    required this.episodeCount,
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
    String? yearText;
    if (airDate != null && airDate!.length >= 4) {
      yearText = airDate!.substring(0, 4);
    } else if (year != null) {
      yearText = year.toString();
    }
    if (yearText != null) {
      if (items.isNotEmpty) {
        items.add(Text(' · ', style: theme.textTheme.bodyMedium));
      }
      items.add(Text(yearText, style: theme.textTheme.bodyMedium));
    }
    if (items.isNotEmpty) {
      items.add(Text(' · ', style: theme.textTheme.bodyMedium));
    }
    items.add(Text('$episodeCount 集', style: theme.textTheme.bodyMedium));
    if (items.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 4,
      children: items,
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

class _EpisodeGrid extends StatelessWidget {
  final List<FnOsEpisode> episodes;
  final void Function(String guid) onTap;

  const _EpisodeGrid({
    required this.episodes,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    if (episodes.isEmpty) {
      return const Text('该季暂无集');
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossCount = (constraints.maxWidth / 64).floor().clamp(5, 12);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossCount,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            mainAxisExtent: 48,
          ),
          itemCount: episodes.length,
          itemBuilder: (_, i) {
            final ep = episodes[i];
            return Semantics(
              button: true,
              label: '第 ${ep.episodeNumber} 集',
              child: InkWell(
                onTap: () => onTap(ep.guid),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(8),
                    color: ep.isWatched
                        ? colorScheme.primaryContainer.withAlpha(60)
                        : colorScheme.surface,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${ep.episodeNumber}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: ep.isWatched
                              ? colorScheme.onPrimaryContainer
                              : colorScheme.onSurface,
                        ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
