import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/custom_source/custom_m3u_site.dart';
import 'package:simple_live_app/app/custom_source/custom_source_service.dart';
import 'package:simple_live_app/app/desktop_startup_args.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/fnos/fn_os_models.dart';
import 'package:simple_live_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_app/modules/live_room/widgets/ios_render_cap_selector.dart';
import 'package:simple_live_app/modules/live_room/live_status_refresh_policy.dart';
import 'package:simple_live_app/modules/live_room/widgets/live_contribution_rank_panel.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/current_room_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/media_control_service.dart';
import 'package:simple_live_app/services/mpv_options_service.dart';
import 'package:simple_live_app/widgets/filter_button.dart';
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';
import 'package:simple_live_app/widgets/cast_sheet.dart';
import 'package:simple_live_app/widgets/status/app_empty_widget.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

class LiveRoomController extends PlayerController
    with WidgetsBindingObserver, WindowListener {
  static const volumeSliderDialogTag = liveRoomVolumeSliderDialogTag;
  static const _appWindowChannel = MethodChannel('simple_live/app_window');
  final Site pSite;
  final String pRoomId;
  final bool initialDesktopSidePanelCollapsed;
  /// 是否为点播（如飞牛影视电影/电视剧），启用进度条/倍速等 VOD 控制。
  final bool isVod;
  /// 剧集元数据基准 guid（剧集本身 guid）。入口传剧集 guid，切集后
  /// 仍能以此拉取季/集列表；电影/自定义源为 null（用 roomId 兜底）。
  final String? vodSeriesGuid;
  late LiveDanmaku liveDanmaku;

  // ─── 点播（影视）元数据：信息页 / 集数页 / 自动连播 ─────────────
  /// 当前影片原始详情 JSON（item 接口，含评分/年代/简介/视频流）。
  Rx<Map<String, dynamic>> vodDetailJson = Rx<Map<String, dynamic>>({});
  Rx<String> vodTitle = Rx<String>('');
  Rx<String> vodPoster = Rx<String>('');
  final RxBool hasVodEpisodes = false.obs;
  final RxList<FnOsSeason> vodSeasons = RxList<FnOsSeason>();
  bool _vodMetaLoaded = false;

  FnOsServer? get fnOsServer {
    if (!isVod) return null;
    return FnOsService.instance.serverForSiteId(site.id);
  }

  /// 加载点播元数据：影片详情 + 剧集（决定"集数" tab 是否显示）。
  Future<void> loadVodMeta() async {
    if (!isVod || _vodMetaLoaded) return;
    _vodMetaLoaded = true;
    final server = fnOsServer;
    if (server == null) return;
    try {
      final detail = await FnOsService.instance.getItemDetail(server, roomId);
      vodDetailJson.value = detail;
      final item = detail['item'];
      if (item is Map) {
        vodTitle.value = (item['title'] ?? '').toString();
        vodPoster.value = (item['posters'] ?? '').toString();
      }
      if (vodTitle.value.isEmpty) vodTitle.value = (detail['title'] ?? '').toString();
      if (vodPoster.value.isEmpty) vodPoster.value = (detail['posters'] ?? '').toString();
      // 剧集 guid：入口传入优先；否则从当前集的 parent 链推导（关注/历史回播场景）。
      String seriesGuid = vodSeriesGuid ?? '';
      if (seriesGuid.isEmpty) {
        seriesGuid = await _resolveSeriesGuid(server, roomId);
      }
      final seasons = await FnOsService.instance.getSeasons(server, seriesGuid);
      if (seasons.isNotEmpty) {
        vodSeasons.value = seasons;
        hasVodEpisodes.value = true;
        await _loadSeasonEpisodes(seasons.first);
      }
    } catch (e) {
      Log.d('加载点播元数据失败: $e');
    }
  }

  /// 从当前集 guid 推导剧集 guid：集 → 季（parent_guid）→ 剧集（季的 parent_guid）。
  Future<String> _resolveSeriesGuid(FnOsServer server, String guid) async {
    try {
      final detail = await FnOsService.instance.getItemDetail(server, guid);
      final item = detail['item'];
      if (item is Map) {
        final seasonGuid = (item['parent_guid'] ?? '').toString();
        if (seasonGuid.isNotEmpty) {
          final seasonDetail =
              await FnOsService.instance.getItemDetail(server, seasonGuid);
          final sItem = seasonDetail['item'];
          if (sItem is Map) {
            final series = (sItem['parent_guid'] ?? '').toString();
            if (series.isNotEmpty) return series;
          }
          return seasonGuid;
        }
      }
    } catch (_) {}
    return guid;
  }

  Future<void> _loadSeasonEpisodes(FnOsSeason season) async {
    final server = fnOsServer;
    if (server == null) return;
    try {
      final eps = await FnOsService.instance.getEpisodes(server, season.guid);
      final idx = vodSeasons.indexWhere((s) => s.guid == season.guid);
      if (idx < 0) return;
      final list = List<FnOsSeason>.from(vodSeasons);
      list[idx] = FnOsSeason(
        guid: season.guid,
        title: season.title,
        seasonNumber: season.seasonNumber,
        overview: season.overview,
        poster: season.poster,
        airDate: season.airDate,
        episodeCount: season.episodeCount,
        episodes: eps,
        rating: season.rating,
      );
      vodSeasons.value = list;
    } catch (_) {
      // 单季拉取失败不影响其它
    }
  }

  /// 切换季（集数页点季时触发，预拉该季集列表）。
  Future<void> selectVodSeason(FnOsSeason season) async {
    if (season.episodes.isNotEmpty) return;
    await _loadSeasonEpisodes(season);
  }

  /// 切播指定集：改 roomId 后完整重走加载（getRoomDetail→getPlayUrl→setPlayer）。
  Future<void> playVodEpisode(FnOsEpisode ep) async {
    if (rxRoomId.value == ep.guid) return;
    rxRoomId.value = ep.guid;
    loadData();
  }

  /// 当前集是否属于某个剧集（集数 tab 高亮用）。
  bool get isVodEpisodeActive => isVod && hasVodEpisodes.value;

  /// 查找下一集：同季内下一集，跨季继续；无则 null。
  FnOsEpisode? _nextVodEpisode(String currentGuid) {
    for (final season in vodSeasons) {
      for (var i = 0; i < season.episodes.length; i++) {
        if (season.episodes[i].guid == currentGuid) {
          if (i + 1 < season.episodes.length) return season.episodes[i + 1];
          final idx = vodSeasons.indexOf(season);
          if (idx + 1 < vodSeasons.length &&
              vodSeasons[idx + 1].episodes.isNotEmpty) {
            return vodSeasons[idx + 1].episodes.first;
          }
          return null;
        }
      }
    }
    return null;
  }

  /// 查找上一集：同季内上一集，跨季继续；无则 null。
  FnOsEpisode? _prevVodEpisode(String currentGuid) {
    for (final season in vodSeasons) {
      for (var i = 0; i < season.episodes.length; i++) {
        if (season.episodes[i].guid == currentGuid) {
          if (i - 1 >= 0) return season.episodes[i - 1];
          final idx = vodSeasons.indexOf(season);
          if (idx - 1 >= 0 && vodSeasons[idx - 1].episodes.isNotEmpty) {
            return vodSeasons[idx - 1].episodes.last;
          }
          return null;
        }
      }
    }
    return null;
  }

  /// 系统媒体中心「下一首」：影视=下一集，直播=切下一线路（只有一条线路则无动作）。
  @override
  Future<void> onMediaNext() async {
    if (isVod) {
      final next = _nextVodEpisode(rxRoomId.value);
      if (next != null) {
        await playVodEpisode(next);
      }
    } else if (playUrls.length > 1) {
      await changePlayLine((currentLineIndex + 1) % playUrls.length);
    }
  }

  /// 系统媒体中心「上一首」：影视=上一集，直播=切上一线路。
  @override
  Future<void> onMediaPrev() async {
    if (isVod) {
      final prev = _prevVodEpisode(rxRoomId.value);
      if (prev != null) {
        await playVodEpisode(prev);
      }
    } else if (playUrls.length > 1) {
      await changePlayLine(
        (currentLineIndex - 1 + playUrls.length) % playUrls.length,
      );
    }
  }

  /// 系统媒体中心进度拖动：仅影视 seek；直播忽略。
  @override
  Future<void> onMediaSeek(Duration position) async {
    if (!isVod) return;
    await player.seek(position);
  }

  /// 仅影视在系统媒体中心显示实时进度。
  @override
  bool shouldSyncMediaProgress() => isVod;

  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
    this.initialDesktopSidePanelCollapsed = false,
    this.isVod = false,
    this.vodSeriesGuid,
  }) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    desktopSidePanelCollapsed.value = initialDesktopSidePanelCollapsed;
    liveDanmaku = site.liveSite.getDanmaku();
    // 抖音直播间默认按竖屏处理。
    if (site.id == "douyin") {
      isVertical.value = true;
    }
  }

  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  @override
  int get playbackLoadGeneration => _loadGeneration;

  int _playbackMediaGeneration = 0;

  @override
  int get playbackMediaGeneration => _playbackMediaGeneration;

  @override
  bool isPlaybackLoadGenerationCurrent(int generation) {
    return !_roomDisposed &&
        !_roomSwitching &&
        super.isPlaybackLoadGenerationCurrent(generation);
  }

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  var liveStatus = false.obs;

  /// 点播播放速率（倍速），默认 1.0。
  final RxDouble playbackRate = 1.0.obs;

  void setPlaybackRate(double rate) {
    playbackRate.value = rate;
    try {
      player.setRate(rate);
    } catch (_) {
      // 部分平台 media_kit 不支持 setRate 时静默忽略。
    }
  }
  RxList<LiveSuperChatMessage> superChats = RxList<LiveSuperChatMessage>();
  RxList<LiveContributionRankItem> contributionRanks =
      RxList<LiveContributionRankItem>();
  RxList<LiveRepeatedDanmuSummary> liveEventFlows =
      RxList<LiveRepeatedDanmuSummary>();
  bool _autoSwitchingRoom = false;
  bool _roomSwitching = false;
  Site? _pendingRoomSite;
  String? _pendingRoomId;
  var contributionRankLoading = false.obs;
  var contributionRankFetched = false.obs;
  Rx<String?> contributionRankError = Rx<String?>(null);
  Rx<DateTime?> contributionRankUpdatedAt = Rx<DateTime?>(null);
  RxDouble danmakuViewportHeight = 0.0.obs;
  final liveRoomFollowFilterMode = 0.obs;
  final liveRoomSelectedPanelKey = "chat".obs;
  final desktopSidePanelCollapsed = false.obs;
  RxSet<String> tempMutedUsers = <String>{}.obs;
  bool get supportsContributionRank => const {
        Constant.kBiliBili,
        Constant.kDouyu,
        Constant.kDouyin,
      }.contains(site.id);

  void toggleDesktopSidePanel() {
    desktopSidePanelCollapsed.value = !desktopSidePanelCollapsed.value;
  }

  /// 聊天列表滚动控制器
  final ScrollController scrollController = ScrollController();

  /// 直播间右侧关注列表滚动控制器
  final ScrollController liveRoomFollowScrollController = ScrollController();

  /// 直播间弹窗关注列表滚动控制器
  final ScrollController liveRoomFollowDialogScrollController =
      ScrollController();

  /// 直播间弹窗历史列表滚动控制器
  final ScrollController liveRoomHistoryScrollController = ScrollController();

  /// 直播间弹窗同类推荐列表滚动控制器
  final ScrollController liveRoomRecommendationScrollController =
      ScrollController();

  /// 聊天消息列表
  RxList<LiveMessage> messages = RxList<LiveMessage>();

  /// 清晰度列表
  RxList<LivePlayQuality> qualites = RxList<LivePlayQuality>();

  /// 当前清晰度索引
  var currentQuality = -1;
  var currentQualityInfo = "".obs;

  /// 播放线路列表
  RxList<String> playUrls = RxList<String>();

  /// 自定义源线路显示名（与频道名相同/为空时显示「线路 n」）；非自定义源为 null。
  List<String>? _customLineNames;

  Map<String, String>? playHeaders;

  /// 当前播放线路索引
  var currentLineIndex = -1;
  var currentLineInfo = "".obs;

  /// 当前实际播放直链（投屏用）
  String? get currentPlayUrl =>
      (currentLineIndex >= 0 && currentLineIndex < playUrls.length)
          ? playUrls[currentLineIndex]
          : null;
  Map<String, String>? get currentPlayHeaders => playHeaders;

  /// 弹出投屏到设备面板（DLNA 局域网推流）
  void showCastSheet() async {
    final url = currentPlayUrl;
    if (url == null || url.isEmpty) {
      SmartDialog.showToast("暂无可投屏的播放地址");
      return;
    }
    // 为接收端单独申请一份播放地址：斗鱼/虎牙等带签名的直播直链不允许
    // 两个客户端同时使用——手机正在播时把同一条地址投给电视，CDN 会把
    // 其中一个踢掉（表现为投屏播 1~2 秒就停）。申请新地址后两端各用各的，
    // 互不干扰，本机播放也不会被中断。
    var castUrl = url;
    var castHeaders = currentPlayHeaders;
    final fresh = await _fetchFreshPlayUrl();
    if (fresh != null) {
      castUrl = fresh.url;
      castHeaders = fresh.headers;
    }
    if (!Get.isRegistered<LiveRoomController>()) return;
    showModalBottomSheet(
      context: Get.context!,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => CastSheet(
        url: castUrl,
        headers: castHeaders,
        title: detail.value?.title ?? "随看直播",
        isVod: isVod,
      ),
    );
  }

  /// 重新向平台申请一条播放直链（不影响当前播放）。
  Future<({String url, Map<String, String>? headers})?> _fetchFreshPlayUrl() async {
    try {
      if (detail.value == null || currentQuality < 0) return null;
      if (currentQuality >= qualites.length) return null;
      final result = await site.liveSite.getPlayUrls(
        detail: detail.value!,
        quality: qualites[currentQuality],
      );
      if (result.urls.isEmpty) return null;
      final first = result.urls.first;
      if (first.isEmpty || first == currentPlayUrl) return null;
      return (url: first, headers: result.headers);
    } catch (_) {
      return null;
    }
  }

  /// 自动退出倒计时，单位秒
  var countdown = 60.obs;

  Timer? autoExitTimer;
  Timer? _autoExitDeadlineTimer;
  final AutoExitSession _autoExitSession = AutoExitSession();
  final autoExitSource = AutoExitSource.none.obs;
  bool _autoExitCompleting = false;

  /// 设置的自动关闭时长，单位分钟
  var autoExitMinutes = 60.obs;

  /// 是否已请求延迟自动关闭
  var delayAutoExit = false.obs;

  /// 是否启用自动关闭
  var autoExitEnable = false.obs;

  /// 是否禁用聊天自动滚动
  /// - 用户手动上拉聊天列表后，不再自动滚到底部
  var disableAutoScroll = false.obs;

  /// 聊天消息上限（跟随底部时的常态上限）。
  static const int _maxChatMessages = 200;
  /// 用户上滑看历史时的放宽上限。
  ///
  /// 看历史时删头部会打断阅读，所以放宽；但不能不设限 —— 原来裁剪完全挂在
  /// 「未禁用自动滚动」的前提下，用户一上滑就永不裁剪，热门房挂机几小时
  /// 消息量无上限增长。500 条是可控内存，同时足够回看。
  static const int _maxChatMessagesWhilePaused = 500;

  /// 应用是否处于后台
  var isBackground = false;

  /// 退后台是否继续播放的裁决条件。
  /// 规则：「后台播放」总开关为准，**但用户手动开启的纯音频模式豁免**——
  /// 手动开启表达的是"我就是要一直听声音"的明确意图，因此前台、后台都
  /// 保持纯音频（只放声音），不因总开关关闭而被暂停（用户 2026-09-04 拍板）。
  /// 真正受总开关约束的是「自动后台降级」（退后台 30s 停画面）这类自动行为：
  /// 总开关关闭时不进入降级流程（因为那时已暂停）。
  bool get _allowBackgroundPlayback =>
      AppSettingsController.instance.allowBackgroundPlayback.value ||
      // 手动纯音频：用户显式意图，前后台都保持，豁免总开关。
      AppSettingsController.instance.audioOnlyBackground.value;

  /// 退到后台后是否已自动降级为纯音频（停掉视频轨），回前台需恢复画面。
  bool _backgroundAudioOnly = false;
  Timer? _backgroundDowngradeTimer;

  /// 视频轨当前是否被强制停用（mpv vid=no）——恢复画面时直播需要重开流才出画面。
  bool _videoTrackDisabled = false;

  /// 纯音频期间自动降到「最低清晰度」之前的清晰度序号，-1 表示没降过、无需还原。
  /// 只有多档清晰度的源才降（自定义 M3U 只有 1 档，降了没意义还会白重开一次流）。
  int _qualityBeforeAudioOnly = -1;

  /// 纯音频期间是否已切换为站点提供的「真·纯音频流」（目前仅 B 站支持）。
  /// 该流本身不含视频轨，比降清晰度省得多；退出纯音频时必须切回正常流才有画面。
  bool _usingAudioOnlyStream = false;

  /// 直播间加载是否失败
  var loadError = false.obs;
  Object? error;
  StackTrace? errorStackTrace;

  // 开播时长展示状态
  var liveDuration = "00:00:00".obs;
  Timer? _liveDurationTimer;
  StreamSubscription<Duration>? _positionSubscription;
  Duration _lastKnownPlayerPosition = Duration.zero;

  /// VOD 本地续播状态（单集只恢复一次;换集后 roomId 变自然重置）。
  String _vodResumeHandledFor = '';
  int _lastVodLocalSaveSec = 0;

  String _vodProgressKey(String guid) => 'vod_progress_$guid';
  Duration? _positionBeforeBackground;
  DateTime? _backgroundedAt;
  Duration? _positionBeforeWindowBlur;
  DateTime? _windowBlurredAt;
  /// 桌面端窗口是否处于最小化（用于区分"从最小化恢复"与其它 restore 事件，
  /// 免得最大化/还原等场景误触发回前台逻辑）。
  bool _windowMinimized = false;
  Future<void>? _playerReopeningFuture;
  int? _playerReopeningGeneration;
  bool _roomDisposed = false;
  int _loadGeneration = 0;
  // 播放地址预解析缓存：detail 就绪后立即解析，首次进房消费（进房秒出画面）。
  Future<List<String>>? _preloadPlayUrlsFuture;
  Map<String, String>? _preloadPlayHeaders;
  String? _preloadQuality;
  int _preloadGeneration = 0;
  bool _preloadConsumed = false;
  final Set<String> _superChatFingerprints = <String>{};
  LiveRepeatedDanmuAggregator _liveEventFlowAggregator =
      LiveRepeatedDanmuAggregator();
  final Queue<String> _recentDanmuFingerprints = Queue<String>();
  final Map<String, int> _recentDanmuCounts = <String, int>{};
  int _recentDanmuEventsSincePrune = 0;
  final Set<Timer> _pendingDanmakuTimers = <Timer>{};
  Timer? _liveEventFlowTimer;
  Timer? _superChatRefreshTimer;
  Timer? _chatBottomRestoreTimer;
  Timer? _onlineRefreshTimer;
  bool _onlineRefreshInFlight = false;
  final LiveStatusRefreshPolicy _onlineStatusRefreshPolicy =
      LiveStatusRefreshPolicy();
  bool _volumeSliderPointerEntered = false;
  bool _autoPipAttempting = false;

  @override
  void onInit() {
    CurrentRoomService.instance.setRoom(site, roomId);
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows) {
      windowManager.addListener(this);
    }
    if (initialDesktopSidePanelCollapsed ||
        DesktopStartupArgs.startupCollapseChat) {
      desktopSidePanelCollapsed.value = true;
    }
    if (FollowService.instance.followList.isEmpty) {
      FollowService.instance.loadData(updateStatus: false);
    }
    initAutoExit();
    showDanmakuState.value = DesktopStartupArgs.isSecondaryDesktopInstance
        ? false
        : AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
    loadData();
    _startLiveEventFlowTimer();

    // 纯音频模式：占位层遮画面 + 停用视频轨 + 降到最低清晰度，三者一起做：
    // 停轨省解码/渲染，降清晰度省流量（视频数据照样下载，只是码率大幅下降）。
    ever(
      AppSettingsController.instance.audioOnlyBackground,
      (bool v) {
        if (v) {
          // 手动开启：立刻停轨 + 降清晰度。用户主动开启、对中断有预期，
          // 不受网络类型限制；只有「后台自动降级」才挑移动网络降档。
          unawaited(_enterAudioOnly(reason: "手动开启纯音频"));
        } else {
          _backgroundAudioOnly = false;
          // 关闭：轨和清晰度都要还原，否则 vid=no 或低清会一直留着。
          unawaited(_restoreVideoTrack());
        }
      },
    );
    if (AppSettingsController.instance.audioOnlyBackground.value) {
      unawaited(_enterAudioOnly(reason: "进房即为纯音频"));
    }

    // SuperChat 排序缓存的失效条件：列表本身增删，或排序方向设置被改动。
    ever(superChats, (_) => _sortedSuperChatsCache = null);
    ever(
      AppSettingsController.instance.superChatSortDesc,
      (_) => _sortedSuperChatsCache = null,
    );
    // 屏蔽词正则缓存的失效条件：屏蔽词集合被改动（增删、清空或同步覆盖）。
    ever(
      AppSettingsController.instance.shieldList,
      (_) => _shieldPatternCache.clear(),
    );

    scrollController.addListener(scrollListener);

    super.onInit();
    _positionSubscription = player.stream.position.listen((event) {
      _lastKnownPlayerPosition = event;
      _maybeHandleVodProgress(event);
    });
  }

  /// fnOS 影视本地续播 + 进度保存：
  /// ① 单集首次有播放位置且媒体就绪(duration>0)时,读上次进度 seek 续播
  ///    （>5s 且未到片尾 15s 才续,避免误跳/秒完重播）;
  /// ② 每 5 秒把当前秒写入本地（App 被杀/异常退出也不丢最后进度）;
  /// ③ 服务端 30 秒上报继续走 [_maybeReportFnOsProgress]。
  void _maybeHandleVodProgress(Duration position) {
    if (!isVod) return;
    final sid = site.id;
    if (!sid.startsWith('fnos_')) return;
    final sec = position.inSeconds;
    if (_vodResumeHandledFor != roomId) {
      _vodResumeHandledFor = roomId;
      final total = player.state.duration.inSeconds;
      if (total > 0) {
        final saved =
            LocalStorageService.instance.getValue(_vodProgressKey(roomId), 0);
        if (saved > 5 && saved < total - 15) {
          unawaited(player.seek(Duration(seconds: saved)));
        }
      }
    }
    if (sec >= 5 && sec - _lastVodLocalSaveSec >= 5) {
      _lastVodLocalSaveSec = sec;
      unawaited(
        LocalStorageService.instance.setValue(_vodProgressKey(roomId), sec),
      );
    }
    _maybeReportFnOsProgress(position);
  }

  /// fnOS 影视播放进度上报节流（秒），用于「继续观看」。
  int _lastFnOsReportSec = 0;

  /// fnOS 影视（fnos_ 站点 + VOD）播放时，每 30 秒上报一次进度到服务器。
  void _maybeReportFnOsProgress(Duration position) {
    if (!isVod) return;
    final sid = site.id;
    if (!sid.startsWith('fnos_')) return;
    final server = FnOsService.instance.serverForSiteId(sid);
    if (server == null) return;
    final nowSec = position.inSeconds;
    if (nowSec - _lastFnOsReportSec < 30) return;
    _lastFnOsReportSec = nowSec;
    final total = player.state.duration.inSeconds;
    unawaited(
      FnOsService.instance.recordPlayStatus(
        server,
        roomId,
        ts: nowSec,
        duration: total > 0 ? total : 0,
      ),
    );
  }

  void scrollListener() {
    if (!scrollController.hasClients) {
      return;
    }
    if (_isChatNearBottom()) {
      disableAutoScroll.value = false;
      // 回到跟随状态，把看历史期间攒下的放宽额度裁回常态上限。
      _trimChatMessages();
      return;
    }
    if (scrollController.position.userScrollDirection ==
        ScrollDirection.forward) {
      disableAutoScroll.value = true;
    }
  }

  bool _isChatNearBottom() {
    if (!scrollController.hasClients) {
      return true;
    }
    return scrollController.position.extentAfter <= 24;
  }

  /// 屏蔽词 → 编译后 Pattern 的缓存。
  ///
  /// 原实现**每条消息**都对每个正则型屏蔽词重新 RegExp(...) 编译一次：
  /// 热门房每秒数十条消息 × 数十个屏蔽词 = 每秒上千次正则编译。
  /// 屏蔽词是全局设置，缓存按 keyword 为 key；编译失败不入缓存（与原本
  /// 每次重试的行为一致）。失效由 onInit 里对 shieldList 的 ever 监听负责。
  static final Map<String, Pattern> _shieldPatternCache = <String, Pattern>{};

  bool _isKeywordShielded(LiveMessage msg) {
    final settings = AppSettingsController.instance;
    if (!settings.danmuShieldEnable.value ||
        !settings.danmuKeywordShieldEnable.value) {
      return false;
    }
    for (var keyword in settings.shieldList) {
      var pattern = _shieldPatternCache[keyword];
      if (pattern == null) {
        if (Utils.isRegexFormat(keyword)) {
          final String removedSlash = Utils.removeRegexFormat(keyword);
          try {
            pattern = RegExp(removedSlash);
          } catch (e) {
            Log.d("正则屏蔽词 $keyword 无法编译，已跳过");
            continue;
          }
        } else {
          pattern = keyword;
        }
        _shieldPatternCache[keyword] = pattern;
      }
      if (msg.message.contains(pattern)) {
        Log.d("命中屏蔽词 $keyword\n已过滤消息: ${msg.message}");
        return true;
      }
    }
    return false;
  }

  bool _isDuplicateDanmu(LiveMessage msg) {
    if (msg.userName == "LiveSysMessage") {
      return false;
    }
    final settings = AppSettingsController.instance;
    if (!settings.danmuDedupeEnable.value) {
      return false;
    }
    final strictMode = settings.danmuDedupeStrictMode;
    final fingerprint = _buildDanmuFingerprint(
      msg,
      includeUserName: !strictMode,
    );
    if (fingerprint == null) {
      return false;
    }
    final windowSize = settings.effectiveDanmuDedupeWindow;
    final duplicate = _recentDanmuCounts.containsKey(fingerprint);
    _recentDanmuFingerprints.addLast(fingerprint);
    _recentDanmuCounts[fingerprint] =
        (_recentDanmuCounts[fingerprint] ?? 0) + 1;
    if (strictMode) {
      _recentDanmuEventsSincePrune = 0;
      _pruneRecentDanmuFingerprints(windowSize);
      return duplicate;
    }

    final step = settings.danmuDedupeStep.value.clamp(1, 20).toInt();
    _recentDanmuEventsSincePrune += 1;
    final shouldPrune = _recentDanmuEventsSincePrune >= step ||
        _recentDanmuFingerprints.length > windowSize + step - 1;
    if (shouldPrune) {
      _recentDanmuEventsSincePrune = 0;
    }
    if (shouldPrune) {
      _pruneRecentDanmuFingerprints(windowSize);
    }
    return duplicate;
  }

  void _pruneRecentDanmuFingerprints(int windowSize) {
    while (_recentDanmuFingerprints.length > windowSize) {
      final removed = _recentDanmuFingerprints.removeFirst();
      final count = (_recentDanmuCounts[removed] ?? 0) - 1;
      if (count <= 0) {
        _recentDanmuCounts.remove(removed);
      } else {
        _recentDanmuCounts[removed] = count;
      }
    }
  }

  String? _buildDanmuFingerprint(
    LiveMessage msg, {
    required bool includeUserName,
  }) {
    final parts = <String>[];
    final message = _normalizeDanmuFingerprintPart(msg.message);
    if (message.isNotEmpty) {
      parts.add("m:$message");
    }
    for (final span in msg.spans ?? const <LiveMessageSpan>[]) {
      final text = _normalizeDanmuFingerprintPart(span.text ?? "");
      final imageUrl = _normalizeDanmuFingerprintPart(span.imageUrl ?? "");
      if (text.isNotEmpty) {
        parts.add("t:$text");
      }
      if (imageUrl.isNotEmpty) {
        parts.add("i:$imageUrl");
      }
    }
    for (final imageUrl in msg.imageUrls ?? const <String>[]) {
      final value = _normalizeDanmuFingerprintPart(imageUrl);
      if (value.isNotEmpty) {
        parts.add("u:$value");
      }
    }
    if (parts.isEmpty) {
      return null;
    }
    if (!includeUserName) {
      return parts.join("\u0002");
    }
    final userName = _normalizeDanmuFingerprintPart(msg.userName);
    if (userName.isEmpty) {
      return null;
    }
    return "$userName\u0001${parts.join("\u0002")}";
  }

  /// 预编译：原实现每次调用都新建 RegExp，而本方法在去重指纹里会对正文、
  /// 每个 span 文本、每个 span 图片、每个图片 URL 各调一次（单条消息 2~10 次）。
  /// 热门房每秒数十条消息 → 每秒上百次正则编译。改为静态复用，行为完全不变。
  static final RegExp _whitespacePattern = RegExp(r"\s+");

  String _normalizeDanmuFingerprintPart(String value) {
    return value.trim().replaceAll(_whitespacePattern, " ");
  }

  void _clearDanmuDedupeState() {
    _recentDanmuFingerprints.clear();
    _recentDanmuCounts.clear();
    _recentDanmuEventsSincePrune = 0;
  }

  /// SuperChat 排序结果缓存。
  ///
  /// 原实现每次访问都 toList()+sort()，而面板的 itemBuilder 是「每个可见
  /// item 调一次 getter」（live_room_page.dart:1221 的
  /// `controller.sortedSuperChats[i]`）→ 可见 n 项就排序 n 次，O(n² log n)。
  /// 排序依据只有 endTime（不随时间变化）与排序方向开关，故可安全缓存；
  /// 失效由 onInit 里的 ever 监听 superChats / superChatSortDesc 负责。
  List<LiveSuperChatMessage>? _sortedSuperChatsCache;

  List<LiveSuperChatMessage> get sortedSuperChats {
    final cached = _sortedSuperChatsCache;
    if (cached != null) {
      return cached;
    }
    final list = superChats.toList();
    list.sort((a, b) => a.endTime.compareTo(b.endTime));
    final result = AppSettingsController.instance.superChatSortDesc.value
        ? list.reversed.toList()
        : list;
    _sortedSuperChatsCache = result;
    return result;
  }

  bool _isUserShielded(String userName) {
    return AppSettingsController.instance.shouldShieldUser(
      userName,
      siteId: site.id,
    );
  }

  String _normalizeMessageText(String message) {
    return message.trim();
  }

  LiveRoomDetail _sanitizeRoomDetail(LiveRoomDetail detail) {
    return LiveRoomDetail(
      roomId: detail.roomId.trim(),
      title: detail.title.trim(),
      cover: detail.cover,
      userName: _normalizeUserName(detail.userName),
      userAvatar: detail.userAvatar,
      online: detail.online,
      introduction: detail.introduction?.trim(),
      notice: detail.notice?.trim(),
      status: detail.status,
      data: detail.data,
      danmakuData: detail.danmakuData,
      url: detail.url,
      isRecord: detail.isRecord,
      showTime: detail.showTime?.trim(),
      categoryId: detail.categoryId?.trim(),
      categoryName: detail.categoryName?.trim(),
      categoryParentId: detail.categoryParentId?.trim(),
      categoryParentName: detail.categoryParentName?.trim(),
      categoryPic: detail.categoryPic?.trim(),
    );
  }

  LiveMessage _sanitizeLiveMessage(LiveMessage message) {
    final normalizedUserName = message.userName == "LiveSysMessage"
        ? message.userName
        : _normalizeUserName(message.userName);
    final normalizedMessage = _normalizeMessageText(message.message);
    if (normalizedUserName == message.userName &&
        normalizedMessage == message.message) {
      return message;
    }

    return LiveMessage(
      type: message.type,
      userName: normalizedUserName,
      message: normalizedMessage,
      data: message.data,
      color: message.color,
      imageUrls: message.imageUrls,
      spans: message.spans,
    );
  }

  LiveMessage _superChatToLiveMessage(LiveSuperChatMessage superChat) {
    return LiveMessage(
      type: LiveMessageType.superChat,
      userName: superChat.userName,
      message: superChat.message,
      color: LiveMessageColor.white,
    );
  }

  String _normalizeUserName(String userName) {
    return userName.trim();
  }

  LiveSuperChatMessage _sanitizeSuperChatMessage(LiveSuperChatMessage message) {
    final normalizedUserName = _normalizeUserName(message.userName);
    final normalizedMessage = _normalizeMessageText(message.message);
    if (normalizedUserName == message.userName &&
        normalizedMessage == message.message) {
      return message;
    }

    return LiveSuperChatMessage(
      id: message.id,
      backgroundBottomColor: message.backgroundBottomColor,
      backgroundColor: message.backgroundColor,
      endTime: message.endTime,
      face: message.face,
      message: normalizedMessage,
      price: message.price,
      startTime: message.startTime,
      userName: normalizedUserName,
    );
  }

  LiveContributionRankItem _sanitizeContributionRankItem(
    LiveContributionRankItem item,
  ) {
    return LiveContributionRankItem(
      rank: item.rank,
      userName: _normalizeUserName(item.userName),
      avatar: item.avatar,
      scoreText: item.scoreText.trim(),
      scoreDetail: item.scoreDetail?.trim(),
      userLevel: item.userLevel,
      userLevelText: item.userLevelText?.trim(),
      userLevelIcon: item.userLevelIcon,
      fansLevel: item.fansLevel,
      fansName: item.fansName?.trim(),
      fansIcon: item.fansIcon,
    );
  }

  void toggleUserShield(String userName) {
    final value = _normalizeUserName(userName);
    if (value.isEmpty) {
      SmartDialog.showToast("用户名不能为空");
      return;
    }

    final settings = AppSettingsController.instance;
    if (settings.isUserShielded(value, siteId: site.id)) {
      settings.removeUserShieldList(value, siteId: site.id);
      SmartDialog.showToast("已取消屏蔽用户：$value");
      return;
    }

    settings.setDanmuShieldEnable(true);
    settings.setDanmuUserShieldEnable(true);
    settings.addUserShieldList(value, siteId: site.id);
    SmartDialog.showToast("已屏蔽用户：$value");
  }

  bool isTempMutedUser(String userName) {
    final value = _normalizeUserName(userName);
    if (value.isEmpty) {
      return false;
    }
    return tempMutedUsers.contains(value);
  }

  void toggleTempMuteUser(String userName) {
    final value = _normalizeUserName(userName);
    if (value.isEmpty) {
      SmartDialog.showToast("用户名不能为空");
      return;
    }
    if (tempMutedUsers.contains(value)) {
      tempMutedUsers.remove(value);
      tempMutedUsers.refresh();
      SmartDialog.showToast("已取消临时禁言：$value");
      return;
    }
    tempMutedUsers.add(value);
    tempMutedUsers.refresh();
    SmartDialog.showToast("已加入临时禁言：$value");
  }

  void clearTempMutedUsers() {
    if (tempMutedUsers.isEmpty) {
      SmartDialog.showToast("当前没有临时禁言用户");
      return;
    }
    tempMutedUsers.clear();
    tempMutedUsers.refresh();
    SmartDialog.showToast("已恢复全部临时禁言用户");
  }

  String? getUserRemark(String userName) {
    final value = _normalizeUserName(userName);
    if (value.isEmpty) {
      return null;
    }
    return AppSettingsController.instance.getUserRemark(
      value,
      siteId: site.id,
    );
  }

  Future<void> editUserRemark(String userName) async {
    final value = _normalizeUserName(userName);
    if (value.isEmpty) {
      SmartDialog.showToast("用户名不能为空");
      return;
    }
    final currentRemark = getUserRemark(value) ?? "";
    final result = await Utils.showEditTextDialog(
      currentRemark,
      title: "备注用户",
      hintText: "留空表示删除备注",
    );
    if (result == null) {
      return;
    }
    await AppSettingsController.instance.setUserRemark(
      siteId: site.id,
      userName: value,
      remark: result,
    );
    SmartDialog.showToast(
      result.trim().isEmpty ? "已删除备注" : "已更新备注：${result.trim()}",
    );
  }

  void showUserActions(
    String userName, {
    String? messageContent,
  }) {
    final value = _normalizeUserName(userName);
    if (value.isEmpty) {
      SmartDialog.showToast("用户名不能为空");
      return;
    }
    final normalizedMessage = messageContent == null
        ? null
        : _normalizeMessageText(messageContent).trim();
    final isShielded = AppSettingsController.instance.isUserShielded(
      value,
      siteId: site.id,
    );
    final isTempMuted = tempMutedUsers.contains(value);
    final remark = getUserRemark(value);

    Utils.showBottomSheet(
      title: value,
      child: ListView(
        children: [
          if (remark != null && remark.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: Text("当前备注：$remark"),
              dense: true,
            ),
          ListTile(
            leading: Icon(
              isShielded ? Icons.visibility_outlined : Icons.block_outlined,
            ),
            title: Text(isShielded ? "取消平台屏蔽" : "屏蔽当前平台"),
            subtitle: Text("仅对 ${site.name} 生效，不会误伤其他平台同名用户"),
            onTap: () {
              Get.back();
              toggleUserShield(value);
            },
          ),
          ListTile(
            leading: Icon(
              isTempMuted
                  ? Icons.volume_up_outlined
                  : Icons.volume_off_outlined,
            ),
            title: Text(isTempMuted ? "取消临时禁言" : "加入临时禁言"),
            subtitle: const Text("只在当前直播间本次会话内有效"),
            onTap: () {
              Get.back();
              toggleTempMuteUser(value);
            },
          ),
          ListTile(
            leading: const Icon(Icons.sticky_note_2_outlined),
            title: const Text("快捷备注"),
            onTap: () async {
              Get.back();
              await editUserRemark(value);
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy_outlined),
            title: const Text("复制用户名"),
            onTap: () {
              Get.back();
              copyUserName(value);
            },
          ),
          if (normalizedMessage != null && normalizedMessage.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text("复制弹幕内容"),
              subtitle: Text(
                normalizedMessage,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                Get.back();
                copyMessageContent(normalizedMessage);
              },
            ),
          ListTile(
            leading: const Icon(Icons.restore_outlined),
            title: const Text("批量恢复临时禁言"),
            enabled: tempMutedUsers.isNotEmpty,
            onTap: tempMutedUsers.isEmpty
                ? null
                : () {
                    Get.back();
                    clearTempMutedUsers();
                  },
          ),
        ],
      ),
    );
  }

  void copyUserName(String userName) {
    final value = _normalizeUserName(userName);
    if (value.isEmpty) {
      SmartDialog.showToast("用户名不能为空");
      return;
    }
    Utils.copyToClipboard(value);
    SmartDialog.showToast("已复制用户名：$value");
  }

  void copyMessageContent(String message) {
    final value = _normalizeMessageText(message).trim();
    if (value.isEmpty) {
      SmartDialog.showToast("弹幕内容为空");
      return;
    }
    Utils.copyToClipboard(value);
    SmartDialog.showToast("已复制弹幕内容");
  }

  void updateDanmakuViewportHeight(double value) {
    if (value <= 0) {
      return;
    }
    if ((danmakuViewportHeight.value - value).abs() < 0.5) {
      return;
    }
    danmakuViewportHeight.value = value;
  }

  void _cancelPendingDanmakuTimers() {
    for (final timer in _pendingDanmakuTimers.toList()) {
      timer.cancel();
    }
    _pendingDanmakuTimers.clear();
  }

  void _scheduleOverlayDanmaku(LiveMessage msg) {
    final color = Color.fromARGB(
      255,
      msg.color.r,
      msg.color.g,
      msg.color.b,
    );
    final baseDelayMs = AppSettingsController.instance.getDanmuDelayMs(site.id);
    final totalDelayMs = baseDelayMs + (site.id == Constant.kHuya ? 1000 : 0);
    final delay = Duration(milliseconds: totalDelayMs.clamp(0, 6000));
    final renderEmoji = AppSettingsController.instance.danmuRenderEmoji.value;
    final parts = renderEmoji ? _buildDanmakuContentParts(msg.spans) : null;
    rememberDanmakuReplay(
      msg.message,
      color,
      delay: delay,
      imageUrls: renderEmoji && parts == null ? msg.imageUrls : null,
      parts: parts,
    );

    void emit() {
      if (!showDanmakuState.value ||
          !liveStatus.value ||
          (isBackground && !_allowBackgroundPlayback)) {
        return;
      }
      addDanmaku([
        DanmakuContentItem(
          msg.message,
          color: color,
          imageUrls: renderEmoji && parts == null ? msg.imageUrls : null,
          parts: parts,
        ),
      ]);
    }

    if (delay == Duration.zero) {
      emit();
      return;
    }

    Timer? timer;
    timer = Timer(delay, () {
      if (timer != null) {
        _pendingDanmakuTimers.remove(timer);
      }
      emit();
    });
    _pendingDanmakuTimers.add(timer);
  }

  List<DanmakuContentPart>? _buildDanmakuContentParts(
    List<LiveMessageSpan>? spans,
  ) {
    final source = spans ?? const <LiveMessageSpan>[];
    if (source.isEmpty) {
      return null;
    }
    final parts = <DanmakuContentPart>[];
    for (final span in source) {
      if (span.isText) {
        final text = span.text ?? "";
        if (text.isNotEmpty) {
          parts.add(DanmakuContentPart.text(text));
        }
      } else if (span.isImage) {
        final imageUrl = (span.imageUrl ?? "").trim();
        if (imageUrl.isNotEmpty) {
          parts.add(DanmakuContentPart.image(imageUrl));
        }
      }
    }
    return parts.isEmpty ? null : parts;
  }

  String _buildSuperChatFingerprint(LiveSuperChatMessage message) {
    final id = message.id?.trim();
    if (id != null && id.isNotEmpty) {
      return "id:$id";
    }

    return [
      message.userName,
      message.message,
      message.price,
      message.startTime.millisecondsSinceEpoch,
      message.endTime.millisecondsSinceEpoch,
    ].join("|");
  }

  bool _shouldUpdateSuperChat(
    LiveSuperChatMessage current,
    LiveSuperChatMessage next,
  ) {
    if ((current.endTime.difference(next.endTime).inSeconds).abs() > 1) {
      return true;
    }

    return current.startTime != next.startTime ||
        current.face != next.face ||
        current.message != next.message ||
        current.price != next.price ||
        current.userName != next.userName ||
        current.backgroundColor != next.backgroundColor ||
        current.backgroundBottomColor != next.backgroundBottomColor;
  }

  void _appendSuperChats(Iterable<LiveSuperChatMessage> items) {
    final now = DateTime.now();
    final added = <LiveSuperChatMessage>[];
    for (final item in items) {
      if (!item.endTime.isAfter(now)) {
        continue;
      }
      final fingerprint = _buildSuperChatFingerprint(item);
      final existingIndex = superChats.indexWhere(
        (existing) => _buildSuperChatFingerprint(existing) == fingerprint,
      );
      if (existingIndex >= 0) {
        if (_shouldUpdateSuperChat(superChats[existingIndex], item)) {
          superChats[existingIndex] = item;
        }
        continue;
      }
      if (_superChatFingerprints.add(fingerprint)) {
        added.add(item);
      }
    }
    if (added.isNotEmpty) {
      superChats.addAll(added);
    }
    _sortSuperChats();
  }

  void _sortSuperChats() {
    superChats.sort((a, b) => a.endTime.compareTo(b.endTime));
  }

  void _refreshSuperChatFingerprints() {
    _superChatFingerprints
      ..clear()
      ..addAll(superChats.map(_buildSuperChatFingerprint));
  }

  void _restartSuperChatRefreshTimer() {
    _superChatRefreshTimer?.cancel();
    if (site.id != Constant.kHuya || !liveStatus.value) {
      return;
    }
    _superChatRefreshTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      removeSuperChats();
      getSuperChatMessage(silent: true);
    });
  }

  void _clearSuperChatState() {
    superChats.clear();
    _superChatFingerprints.clear();
    _superChatRefreshTimer?.cancel();
    _superChatRefreshTimer = null;
  }

  /// [refreshImmediately] 为 true 时，除了起 10 秒周期定时器，还立刻跑一次。
  /// 回到前台用它（退后台期间攒下的热度/开播状态要尽快跟上）；普通加载路径
  /// 不传，避免每次 loadData 都多打一次网络请求。
  void _restartOnlineRefreshTimer({bool refreshImmediately = false}) {
    _onlineRefreshTimer?.cancel();
    _onlineRefreshInFlight = false;
    _onlineStatusRefreshPolicy.reset();
    if (!liveStatus.value) {
      return;
    }
    final refreshGeneration = _loadGeneration;
    final refreshSiteId = site.id;
    final refreshRoomId = roomId;
    Future<void> tick() async {
      if (_onlineRefreshInFlight ||
          !_isCurrentLoad(refreshGeneration) ||
          site.id != refreshSiteId ||
          roomId != refreshRoomId ||
          !liveStatus.value) {
        return;
      }
      _onlineRefreshInFlight = true;
      try {
        final roomDetail = _sanitizeRoomDetail(
          await site.liveSite
              .getRoomDetail(roomId: refreshRoomId)
              .timeout(const Duration(seconds: 8)),
        );
        if (!_isCurrentLoad(refreshGeneration) ||
            site.id != refreshSiteId ||
            roomId != refreshRoomId) {
          return;
        }
        final reportedLive = roomDetail.status || roomDetail.isRecord;
        if (reportedLive) {
          _onlineStatusRefreshPolicy.reset();
          online.value = roomDetail.online;
          liveStatus.value = true;
          return;
        }
        final confirmedOffline = _onlineStatusRefreshPolicy.confirmOffline(
          reportedLive: false,
          hasActivePlaybackEvidence:
              player.state.playing || player.state.buffering,
        );
        if (!confirmedOffline) {
          Log.d(
            "刷新${site.name}状态暂未确认下播: "
            "${_onlineStatusRefreshPolicy.consecutiveOfflineCount}/"
            "${_onlineStatusRefreshPolicy.requiredOfflineConfirmations}",
          );
          return;
        }
        online.value = roomDetail.online;
        liveStatus.value = false;
        _onlineRefreshTimer?.cancel();
        _onlineRefreshTimer = null;
        _restartSuperChatRefreshTimer();
      } catch (e) {
        _onlineStatusRefreshPolicy.reset();
        Log.d("刷新${site.name}热度失败: $e");
      } finally {
        if (_isCurrentLoad(refreshGeneration)) {
          _onlineRefreshInFlight = false;
        }
      }
    }

    _onlineRefreshTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => unawaited(tick()));
    if (refreshImmediately) {
      unawaited(tick());
    }
  }

  void _refreshDanmakuOverlay(String reason) {
    if (!showDanmakuState.value) {
      return;
    }
    Log.d("$reason 后恢复弹幕覆盖层");
    danmakuController?.resume();
  }

  void _clearContributionRankState() {
    contributionRanks.clear();
    contributionRankFetched.value = false;
    contributionRankLoading.value = false;
    contributionRankError.value = null;
    contributionRankUpdatedAt.value = null;
  }

  void _startLiveEventFlowTimer() {
    _liveEventFlowTimer?.cancel();
    _liveEventFlowTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _flushLiveEventFlow(),
    );
  }

  void _recordLiveEventFlow(LiveMessage msg) {
    if (msg.userName == "LiveSysMessage") {
      return;
    }
    final settings = AppSettingsController.instance;
    if (!settings.liveEventFlowEnable.value) {
      _liveEventFlowAggregator.clear();
      liveEventFlows.clear();
      return;
    }
    final text = _normalizeMessageText(msg.message);
    if (text.isEmpty) {
      return;
    }
    _ensureLiveEventFlowAggregatorSettings();
    _liveEventFlowAggregator.add(text);
    _flushLiveEventFlow();
  }

  void _flushLiveEventFlow() {
    final settings = AppSettingsController.instance;
    if (!settings.liveEventFlowEnable.value) {
      _liveEventFlowAggregator.clear();
      liveEventFlows.clear();
      return;
    }
    _ensureLiveEventFlowAggregatorSettings();
    final summaries = _liveEventFlowAggregator.preview(
      displayTtl: Duration(
        seconds: settings.effectiveLiveEventFlowDisplaySeconds,
      ),
    );
    liveEventFlows.assignAll(summaries);
    final limit = settings.liveEventFlowLimit.value;
    if (liveEventFlows.length > limit) {
      liveEventFlows.removeRange(limit, liveEventFlows.length);
    }
  }

  void _ensureLiveEventFlowAggregatorSettings() {
    final settings = AppSettingsController.instance;
    final countWindow = Duration(
      seconds: settings.effectiveLiveEventFlowWindowSeconds,
    );
    final minDisplayCount = settings.effectiveLiveEventFlowMinCount;
    if (_liveEventFlowAggregator.countWindow == countWindow &&
        _liveEventFlowAggregator.minDisplayCount == minDisplayCount) {
      return;
    }
    _liveEventFlowAggregator = LiveRepeatedDanmuAggregator(
      countWindow: countWindow,
      minDisplayCount: minDisplayCount,
    );
    liveEventFlows.clear();
  }

  void clearLiveEventFlow() {
    _liveEventFlowAggregator.clear();
    liveEventFlows.clear();
  }

  Future<void> fetchContributionRank({bool forceRefresh = false}) async {
    if (!AppSettingsController.instance.contributionRankEnable.value ||
        !supportsContributionRank ||
        detail.value == null) {
      return;
    }
    if (contributionRankLoading.value) {
      return;
    }
    if (!forceRefresh &&
        contributionRanks.isNotEmpty &&
        contributionRankError.value == null) {
      return;
    }

    final requestSiteId = site.id;
    final requestRoomId = roomId;
    contributionRankLoading.value = true;
    contributionRankError.value = null;
    try {
      final ranks = await site.liveSite.getContributionRank(
        roomId: detail.value!.roomId,
        detail: detail.value,
      );
      if (site.id != requestSiteId || roomId != requestRoomId) {
        return;
      }
      contributionRanks.assignAll(ranks.map(_sanitizeContributionRankItem));
      contributionRankFetched.value = true;
      contributionRankUpdatedAt.value = DateTime.now();
    } catch (e) {
      Log.logPrint(e);
      if (site.id != requestSiteId || roomId != requestRoomId) {
        return;
      }
      contributionRankError.value = e.toString();
    } finally {
      if (site.id == requestSiteId && roomId == requestRoomId) {
        contributionRankLoading.value = false;
      }
    }
  }

  /// 初始化自动关闭计时器
  void initAutoExit() {
    final settings = AppSettingsController.instance;
    _cancelAutoExitTimers();
    _autoExitSession.stop();
    autoExitSource.value = AutoExitSource.none;
    _autoExitCompleting = false;
    autoExitEnable.value = settings.autoExitEnable.value;
    if (!autoExitEnable.value) {
      autoExitMinutes.value = settings.roomAutoExitDuration.value;
      countdown.value = 0;
      return;
    }
    autoExitMinutes.value = settings.autoExitDuration.value;
    _autoExitSession.startGlobal(
      now: DateTime.now(),
      minutes: autoExitMinutes.value,
    );
    autoExitSource.value = AutoExitSource.global;
    Log.i("定时关闭已启用，将在${autoExitMinutes.value}分钟后关闭");
    _startAutoExitTicker();
  }

  void setAutoExit() {
    if (!autoExitEnable.value) {
      stopAutoExit();
      return;
    }
    _autoExitSession.startRoomOverride(
      now: DateTime.now(),
      minutes: autoExitMinutes.value,
    );
    autoExitSource.value = AutoExitSource.roomOverride;
    Log.i("定时关闭（房间覆盖）已设置，将在${autoExitMinutes.value}分钟后关闭");
    _startAutoExitTicker();
  }

  void _cancelAutoExitTimers() {
    autoExitTimer?.cancel();
    autoExitTimer = null;
    _autoExitDeadlineTimer?.cancel();
    _autoExitDeadlineTimer = null;
  }

  void _scheduleAutoExitDeadline() {
    _autoExitDeadlineTimer?.cancel();
    _autoExitDeadlineTimer = null;
    if (!autoExitEnable.value || !_autoExitSession.enabled) {
      return;
    }
    final deadline = _autoExitSession.deadline;
    if (deadline == null) {
      return;
    }
    final delay =
        deadline.difference(DateTime.now()) + const Duration(milliseconds: 80);
    if (delay <= Duration.zero) {
      unawaited(_completeAutoExit());
      return;
    }
    _autoExitDeadlineTimer = Timer(delay, () {
      _autoExitDeadlineTimer = null;
      _refreshAutoExitCountdown();
    });
  }

  void _startAutoExitTicker() {
    _cancelAutoExitTimers();
    _autoExitCompleting = false;
    _refreshAutoExitCountdown();
    // Keep a 1s UI tick for the countdown label, and also schedule a one-shot
    // timer to the absolute deadline so a delayed periodic tick cannot miss it.
    autoExitTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _refreshAutoExitCountdown(),
    );
    _scheduleAutoExitDeadline();
  }

  void _refreshAutoExitCountdown() {
    if (!autoExitEnable.value || !_autoExitSession.enabled) {
      return;
    }
    final now = DateTime.now();
    final remaining = _autoExitSession.remaining(now);
    countdown.value = remaining == Duration.zero ? 0 : remaining.inSeconds + 1;

    if (_autoExitSession.isDue(now)) {
      unawaited(_completeAutoExit());
      return;
    }
    _scheduleAutoExitDeadline();
  }

  Future<void> _completeAutoExit() async {
    if (_autoExitCompleting || _roomDisposed) {
      return;
    }
    _autoExitCompleting = true;
    _cancelAutoExitTimers();
    _autoExitSession.stop();
    autoExitSource.value = AutoExitSource.none;
    autoExitEnable.value = false;
    countdown.value = 0;
    Log.i(
        "定时关闭到点：platform=${Platform.operatingSystem} room=${site.id}/$roomId");
    Log.i("定时关闭开始执行，准备关闭播放器和服务");
    await _runAutoExitStep("取消自动画中画", cancelAutoPipOnLeave);
    await _runAutoExitStep("停止后台播放服务", stopBackgroundPlaybackService);
    await _runAutoExitStep("停止弹幕", liveDanmaku.stop);
    await _runAutoExitStep("停止播放器", player.stop);
    await _runAutoExitStep("释放唤醒锁", WakelockPlus.disable);
    Log.i("定时关闭准备退出应用");
    await _finishAutoExit();
  }

  Future<void> _runAutoExitStep(
    String label,
    Future<void> Function() action, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      await action().timeout(timeout);
    } on TimeoutException catch (e, stackTrace) {
      Log.e("定时关闭步骤超时（$label）: $e", stackTrace);
    } catch (e, stackTrace) {
      Log.e("定时关闭步骤失败（$label）: $e", stackTrace);
    }
  }

  Future<void> _finishAutoExit() async {
    if (Platform.isIOS) {
      await _runAutoExitStep("退出播放器窗口模式", () async {
        if (fullScreenState.value || smallWindowState.value) {
          await exitPlayerWindowMode();
        }
      });
      Get.offAllNamed(RoutePath.kIndex);
      return;
    }
    if (Platform.isAndroid) {
      try {
        final finished = await _appWindowChannel
            .invokeMethod<bool>(
              'finishAndRemoveTask',
            )
            .timeout(const Duration(seconds: 2));
        if (finished == true) {
          return;
        }
      } catch (e) {
        Log.d("原生移除任务失败，回退 Flutter 退出：$e");
      }
      await _runAutoExitStep("Flutter 退出应用", SystemNavigator.pop);
      return;
    }
    try {
      if (Platform.isWindows) {
        await windowManager
            .setPreventClose(false)
            .timeout(const Duration(seconds: 1));
      }
      await windowManager.close().timeout(const Duration(seconds: 2));
    } catch (e, stackTrace) {
      Log.e("关闭桌面窗口失败，尝试销毁窗口: $e", stackTrace);
      await _runAutoExitStep("销毁桌面窗口", windowManager.destroy);
    }
  }

  void stopAutoExit() {
    autoExitEnable.value = false;
    _cancelAutoExitTimers();
    _autoExitSession.stop();
    autoExitSource.value = AutoExitSource.none;
    _autoExitCompleting = false;
    countdown.value = 0;
  }

  Future<bool> syncAutoPipOnLeave() async {
    if (_autoPipAttempting) {
      return false;
    }
    if (!Platform.isAndroid ||
        !AppSettingsController.instance.autoPipOnExit.value ||
        !liveStatus.value) {
      if (Platform.isAndroid) {
        await cancelAutoPipOnLeave();
      }
      return false;
    }
    _autoPipAttempting = true;
    try {
      return await prepareAutoPipOnLeave();
    } catch (e) {
      Log.d("配置退后台自动小窗失败: $e");
      return false;
    } finally {
      _autoPipAttempting = false;
    }
  }
  // 页面刷新与重载逻辑

  void refreshRoom() {
    //messages.clear();
    _clearDanmuDedupeState();
    _clearSuperChatState();
    _clearContributionRankState();
    clearLiveEventFlow();
    liveDanmaku.stop();
    if (detail.value != null) {
      getSuperChatMessage();
    }

    loadData();
  }

  @override
  void onPlayerWindowModeExited() {
    clearTransientPlayerOverlays();
    forceChatScrollToBottom(delay: const Duration(milliseconds: 120));
  }

  @override
  void onClose() async {
    _roomDisposed = true;
    _preloadPlayUrlsFuture = null;
    _preloadPlayHeaders = null;
    _preloadQuality = null;
    _preloadConsumed = true;
    clearTransientPlayerOverlays();
    _loadGeneration += 1;
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isWindows) {
      windowManager.removeListener(this);
    }
    unawaited(cancelAutoPipOnLeave());
    CurrentRoomService.instance.clearRoom();
    scrollController.removeListener(scrollListener);
    // 补上 dispose：此前只解除监听、从未释放控制器本身，反复进出直播间会
    // 持续累积（同批另外 4 个 ScrollController 都已正确 dispose）。
    scrollController.dispose();
    liveRoomFollowScrollController.dispose();
    liveRoomFollowDialogScrollController.dispose();
    liveRoomHistoryScrollController.dispose();
    liveRoomRecommendationScrollController.dispose();
    _cancelAutoExitTimers();
    _autoExitSession.stop();
    // 聊天批量入列的定时器与残留缓冲：退出房间后已无必要再入列，直接清掉，
    // 同时避免定时器继续持有 controller 引用。
    _chatFlushTimer?.cancel();
    _chatFlushTimer = null;
    _pendingChatBuffer.clear();
    _superChatRefreshTimer?.cancel();
    _backgroundDowngradeTimer?.cancel();
    _usingAudioOnlyStream = false;
    _liveEventFlowTimer?.cancel();
    _onlineRefreshTimer?.cancel();
    _onlineStatusRefreshPolicy.reset();
    _chatBottomRestoreTimer?.cancel();
    _cancelPendingDanmakuTimers();
    clearDanmakuReplayHistory();
    _liveDurationTimer?.cancel();
    _positionSubscription?.cancel();
    unawaited(
      AppSettingsController.instance.setLastLiveRoomResumePending(false),
    );
    await _waitForPlayerReopen();
    if (!isPlayerClosing) {
      await player.stop();
    }
    await liveDanmaku.stop();
    // fnOS 影视退出时上报最终进度（含看完标记）。
    if (isVod) {
      final sid = site.id;
      if (sid.startsWith('fnos_')) {
        final server = FnOsService.instance.serverForSiteId(sid);
        if (server != null) {
          final pos = _lastKnownPlayerPosition.inSeconds;
          final total = player.state.duration.inSeconds;
          unawaited(
            FnOsService.instance.recordPlayStatus(
              server,
              roomId,
              ts: pos,
              duration: total > 0 ? total : 0,
            ),
          );
          if (total > 0 && pos >= total * 0.9) {
            unawaited(FnOsService.instance.setWatched(server, roomId));
            // 看完:清除本地续播点,下次从头播
            unawaited(
              LocalStorageService.instance
                  .removeValue(_vodProgressKey(roomId)),
            );
          } else if (pos > 5) {
            // 退出前把最终秒数落本地(覆盖 5s 节流没赶上的一段)
            unawaited(
              LocalStorageService.instance
                  .setValue(_vodProgressKey(roomId), pos),
            );
          }
        }
      }
    }
    super.onClose();
  }

  /// 裁剪聊天消息，保住内存上限。
  ///
  /// 裁剪与「是否在自动滚动」**解耦**：两种状态都裁，只是看历史时放宽到
  /// [_maxChatMessagesWhilePaused]。原因是原来把它挂在 !disableAutoScroll 下，
  /// 用户上滑看历史期间就完全不裁，热门房挂机会无限增长。
  ///
  /// 批量 [removeRange] 而不是逐条 [removeAt]：删 N 条时后者是 N 次数组搬移
  /// + N 次 Rx 通知，前者只有一次。
  void _trimChatMessages() {
    final limit =
        disableAutoScroll.value ? _maxChatMessagesWhilePaused : _maxChatMessages;
    final excess = messages.length - limit;
    if (excess <= 0) {
      return;
    }
    messages.removeRange(0, excess);
  }

  /// 距上次真正裁剪之间累计收到的聊天消息条数。
  int _chatSinceLastTrim = 0;

  /// 聊天列表裁剪的批量阈值：每累计这么多条才真正裁剪一次。
  ///
  /// 原实现在**每来一条消息**时都先 _trimChatMessages() 再 messages.add()。
  /// 列表未超上限时裁剪会直接 return、没有额外通知；但直播间开久了列表
  /// 一直处于满的状态，此时每条消息都会走 removeRange → **每条消息触发
  /// 2 次 Rx 通知**（裁剪一次 + 添加一次），进而让聊天区整片重建两遍。
  /// 热门房每秒 10~30 条消息 = 每秒 20~60 次重建。
  ///
  /// 改成累计到阈值才裁一次后，稳态下每条消息只剩 1 次通知，重建次数减半。
  /// 代价是消息数最多临时超出上限本阈值条（上限本身是 200/500，几十条的
  /// 浮动不影响内存保护的实际效果）。
  static const int _chatTrimBatch = 32;

  void _maybeTrimChatMessages() {
    _chatSinceLastTrim += 1;
    if (_chatSinceLastTrim < _chatTrimBatch) {
      return;
    }
    _chatSinceLastTrim = 0;
    _trimChatMessages();
  }

  /// 待批量入列的聊天消息缓冲。
  ///
  /// 原本每来一条消息就 messages.add() 一次 → 一次 Rx 通知 → 聊天区（连同
  /// 设置面板、SuperChat、关注列表等一大片 widget）整片重建一遍。热门房
  /// 每秒 10~30 条消息 = 每秒 10~30 次重建。
  ///
  /// 改成攒一批再一次性入列后，重建频率降到约每 80ms 一次。消息内容与顺序
  /// 完全一致，仅仅是最多晚 80ms 出现在列表里 —— 抖音数据源本来就自带
  /// 80ms/50 条的批处理，这里是把同样的策略统一到所有平台。
  ///
  /// 注意：画面上滚动的弹幕走 _scheduleOverlayDanmaku，仍然逐条立即上屏，
  /// 不受本缓冲影响，因此观感上不会有延迟。
  final List<LiveMessage> _pendingChatBuffer = <LiveMessage>[];
  Timer? _chatFlushTimer;

  /// 聊天消息批量入列的时间窗口。
  static const Duration _chatFlushWindow = Duration(milliseconds: 80);

  /// 缓冲达到这个条数就立即入列，不等窗口到点。
  static const int _chatFlushMaxBatch = 50;

  void _enqueueChatMessage(LiveMessage msg) {
    _pendingChatBuffer.add(msg);
    if (_pendingChatBuffer.length >= _chatFlushMaxBatch) {
      _flushChatBuffer();
      return;
    }
    _chatFlushTimer ??= Timer(_chatFlushWindow, _flushChatBuffer);
  }

  /// 把缓冲里的消息一次性入列，只触发一次 Rx 通知。
  void _flushChatBuffer() {
    _chatFlushTimer?.cancel();
    _chatFlushTimer = null;
    if (_pendingChatBuffer.isEmpty) {
      return;
    }
    final batch = List<LiveMessage>.of(_pendingChatBuffer);
    _pendingChatBuffer.clear();
    messages.addAll(batch);
    _scheduleChatScrollToBottom();
  }

  /// 本帧是否已经排过「滚动到底部」。
  bool _chatBottomScrollScheduled = false;

  /// 请求在下一帧把聊天列表滚到底部，同一帧内的重复请求会被合并。
  ///
  /// 原来每条弹幕都直接 addPostFrameCallback，热门房一帧来几十条就排几十个
  /// 一模一样的回调。这些回调做的事完全相同（jumpTo 到 maxScrollExtent），
  /// 执行 N 次和执行 1 次的结果没有区别 —— 中间那些是纯浪费。
  ///
  /// 注意这是**等价**优化：最终都停在「本帧最后一条消息加入后的底部」，
  /// 只是省掉了中间几次无意义的 jumpTo。
  void _scheduleChatScrollToBottom() {
    if (_chatBottomScrollScheduled) {
      return;
    }
    _chatBottomScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chatBottomScrollScheduled = false;
      chatScrollToBottom();
    });
  }

  /// 聊天列表滚动到底部
  void chatScrollToBottom() {
    if (scrollController.hasClients) {
      // 用户手动上拉过时，不再自动滚到底部。
      if (disableAutoScroll.value) {
        return;
      }
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
    }
  }

  void forceChatScrollToBottom({Duration delay = Duration.zero}) {
    _chatBottomRestoreTimer?.cancel();
    _chatBottomRestoreTimer = Timer(delay, () {
      disableAutoScroll.value = false;
      // 同上：回到跟随状态后裁回常态上限。
      _trimChatMessages();
      if (!scrollController.hasClients) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!scrollController.hasClients) {
          return;
        }
        scrollController.jumpTo(scrollController.position.maxScrollExtent);
      });
    });
  }

  /// 初始化弹幕连接回调
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
    liveDanmaku.onClose = onWSClose;
    liveDanmaku.onReady = onWSReady;
  }

  /// 接收 WebSocket 消息
  void onWSMessage(LiveMessage msg) {
    msg = _sanitizeLiveMessage(msg);
    if (msg.type == LiveMessageType.chat) {
      // 裁剪与滚动状态解耦，保住内存上限（见 _trimChatMessages 注释）。
      // 走批量版本：避免每来一条消息都额外触发一次 Rx 通知（含整片重建）。
      _maybeTrimChatMessages();
      if (_isUserShielded(msg.userName) || isTempMutedUser(msg.userName)) {
        Log.d("已过滤被屏蔽用户: ${msg.userName}");
        return;
      }

      if (_isKeywordShielded(msg)) {
        return;
      }

      _recordLiveEventFlow(msg);

      if (_isDuplicateDanmu(msg)) {
        return;
      }

      // 批量入列（见 _enqueueChatMessage 注释）：逐条 add 会让聊天区整片
      // 重建一次，攒一批则只重建一次；滚动调度随之移入 _flushChatBuffer。
      _enqueueChatMessage(msg);
      if (!liveStatus.value || (isBackground && !_allowBackgroundPlayback)) {
        return;
      }
      _scheduleOverlayDanmaku(msg);
      return;
    } else if (msg.type == LiveMessageType.online) {
      online.value = msg.data;
    } else if (msg.type == LiveMessageType.superChat) {
      if (msg.data is! LiveSuperChatMessage) {
        return;
      }
      final superChat =
          _sanitizeSuperChatMessage(msg.data as LiveSuperChatMessage);
      if (_isUserShielded(superChat.userName) ||
          isTempMutedUser(superChat.userName)) {
        return;
      }
      if (_isKeywordShielded(_superChatToLiveMessage(superChat))) {
        return;
      }
      _appendSuperChats([superChat]);
      return;
    }
  }

  /// 添加一条系统消息
  void addSysMsg(String msg) {
    messages.add(
      LiveMessage(
        type: LiveMessageType.chat,
        userName: "LiveSysMessage",
        message: _normalizeMessageText(msg),
        color: LiveMessageColor.white,
      ),
    );
  }

  /// 接收 WebSocket 关闭消息
  void onWSClose(String msg) {
    addSysMsg(msg);
  }

  /// WebSocket 已连接完成
  void onWSReady() {
    addSysMsg("弹幕服务器连接成功");
  }

  /// 加载直播间信息
  void loadData() async {
    final loadGeneration = ++_loadGeneration;
    final targetSite = site;
    final targetRoomId = roomId;
    final loadStopwatch = Stopwatch()..start();
    _dismissLiveRoomLoadingOverlay();
    try {
      loadError.value = false;
      error = null;
      errorStackTrace = null;
      update();
      await liveDanmaku.stop();
      if (!_isCurrentLoad(loadGeneration)) {
        return;
      }
      liveDanmaku = targetSite.liveSite.getDanmaku();
      _clearContributionRankState();
      _clearSuperChatState();
      _cancelPendingDanmakuTimers();
      clearDanmakuReplayHistory();
      rebuildDanmakuView();
      addSysMsg("正在读取直播间信息");
      final detailStopwatch = Stopwatch()..start();
      // 进房主链路唯一的超时保护：原来没有 .timeout()，弱网下要一直卡到 Dio
      // 全局 20s 超时才报错，界面停在「正在读取直播间信息」没有任何反馈。
      // 8 秒与在线刷新（_restartOnlineRefreshTimer）保持一致。
      // 超时后走原有 catch → loadError → 错误页可重试，失败语义不变，只是
      // 让用户更早拿到「可以重试」的机会。
      final loadedDetail = _sanitizeRoomDetail(
        await targetSite.liveSite
            .getRoomDetail(roomId: targetRoomId)
            .timeout(const Duration(seconds: 8)),
      );
      detailStopwatch.stop();
      Log.i(
        "读取直播间信息完成：${targetSite.id}/$targetRoomId ${detailStopwatch.elapsedMilliseconds}ms",
      );
      if (!_isCurrentLoad(loadGeneration)) {
        return;
      }
      detail.value = loadedDetail;
      // 系统媒体中心（锁屏/控制中心/通知栏）显示当前房间信息：
      // 标题=直播间标题，副标题=主播名（点播则为平台名）。
      // 直播：封面+可切台（线路数>1）；影视：时长/进度+可切集。
      if (Platform.isIOS || Platform.isAndroid) {
        final curGuid = rxRoomId.value;
        unawaited(
          MediaControlService.update(
            title: loadedDetail.title.isEmpty ? "随看直播" : loadedDetail.title,
            artist: loadedDetail.userName,
            isLive: !isVod,
            playing: player.state.playing,
            coverUrl: loadedDetail.cover.isEmpty
                ? loadedDetail.userAvatar
                : loadedDetail.cover,
            duration: isVod
                ? player.state.duration.inSeconds.toDouble()
                : null,
            position: isVod
                ? player.state.position.inSeconds.toDouble()
                : null,
            canNext: isVod
                ? _nextVodEpisode(curGuid) != null
                : playUrls.length > 1,
            canPrev: isVod
                ? _prevVodEpisode(curGuid) != null
                : playUrls.length > 1,
          ),
        );
      }
      // 点播（影视）：异步加载影片详情与剧集（信息页/集数页数据源）。
      if (isVod) {
        unawaited(loadVodMeta());
      }

      if (site.id == Constant.kDouyin) {
        // 1.6.0 之前收藏的是 WebRid，中间一版收藏的是 RoomID，
        // 这里统一修正回当前实际 roomId。
        if (detail.value!.roomId != roomId) {
          var oldId = roomId;
          final resolvedRoomId = detail.value!.roomId;
          rxRoomId.value = detail.value!.roomId;
          if (followed.value) {
            // 同步修正已关注房间的主键
            DBService.instance.deleteFollow("${site.id}_$oldId");
            DBService.instance.addFollow(
              FollowUser(
                id: "${site.id}_$resolvedRoomId",
                roomId: resolvedRoomId,
                siteId: site.id,
                userName: detail.value!.userName,
                face: detail.value!.userAvatar,
                addTime: DateTime.now(),
              ),
            );
          } else {
            followed.value = DBService.instance.getFollowExist(
              "${site.id}_$resolvedRoomId",
            );
          }
        }
      }
      unawaited(
        AppSettingsController.instance.saveLastLiveRoom(
          siteId: site.id,
          roomId: roomId,
        ),
      );

      getSuperChatMessage();
      if (AppSettingsController.instance.contributionRankEnable.value) {
        fetchContributionRank();
      }
      if (!_isCurrentLoad(loadGeneration)) {
        return;
      }

      addHistory();
      // 刷新关注状态
      followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      _restartSuperChatRefreshTimer();
      _restartOnlineRefreshTimer();
      unawaited(syncAutoPipOnLeave());
      if (liveStatus.value) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        addSysMsg("当前主播未开播，正在转播录像");
      }
      addSysMsg("正在连接弹幕服务器");
      if (!_isCurrentLoad(loadGeneration)) {
        return;
      }
      initDanmau();
      liveDanmaku.start(detail.value?.danmakuData);
      if (!isVod) {
        startLiveDurationTimer();
      }
    } catch (e, stackTrace) {
      Log.logPrint(e);
      //SmartDialog.showToast(e.toString());
      if (!_isCurrentLoad(loadGeneration)) {
        return;
      }
      loadError.value = true;
      error = e;
      errorStackTrace = stackTrace;
    } finally {
      if (_isCurrentLoad(loadGeneration)) {
        _dismissLiveRoomLoadingOverlay();
      }
      loadStopwatch.stop();
      Log.i(
        "直播间加载流程结束：${targetSite.id}/$targetRoomId ${loadStopwatch.elapsedMilliseconds}ms",
      );
    }
  }

  void _dismissLiveRoomLoadingOverlay() {
    unawaited(SmartDialog.dismiss(status: SmartStatus.loading));
  }

  bool _isCurrentLoad(int loadGeneration) {
    return !_roomDisposed && loadGeneration == _loadGeneration;
  }

  /// 读取可用清晰度并选择默认值
  Future<void> getPlayQualites() async {
    final loadGeneration = _loadGeneration;
    final roomDetail = detail.value;
    if (roomDetail == null || !_isCurrentLoad(loadGeneration)) {
      return;
    }
    qualites.clear();
    currentQuality = -1;

    try {
      var playQualites =
          await site.liveSite.getPlayQualites(detail: roomDetail);
      if (!_isCurrentLoad(loadGeneration)) {
        return;
      }

      if (playQualites.isEmpty) {
        final qualityError = CoreError("无法读取播放清晰度，请稍后重试");
        Log.e(
          "播放清晰度列表为空：${site.id}/$roomId generation=$loadGeneration",
          StackTrace.current,
        );
        loadError.value = true;
        error = qualityError;
        errorStackTrace = StackTrace.current;
        return;
      }
      var qualityLevel = await getQualityLevel();
      if (!_isCurrentLoad(loadGeneration)) {
        return;
      }
      qualites.value = playQualites;
      int preferred;
      if (qualityLevel == 2) {
        // 最高
        preferred = 0;
      } else if (qualityLevel == 0) {
        // 最低
        preferred = playQualites.length - 1;
      } else {
        // 中间档
        preferred = (playQualites.length / 2).floor();
      }
      final lowest = playQualites.length - 1;
      if (AppSettingsController.instance.audioOnlyBackground.value &&
          preferred != lowest) {
        // 进房时纯音频已开启：直接用最低档开播，省得播起来再换流（换流会中断 1-2 秒）。
        // 记下用户本应选的档位，关闭纯音频时还原回去。
        _qualityBeforeAudioOnly = preferred;
        currentQuality = lowest;
      } else {
        currentQuality = preferred;
      }

      // 播放地址预解析：清晰度确定后立即发起（fire-and-forget），
      // 首次播放直接消费缓存（进房秒出画面）；失败/换质量/重试仍走原逻辑。
      if (currentQuality >= 0 && currentQuality < qualites.length) {
        _preloadGeneration = loadGeneration;
        _preloadConsumed = false;
        final q = qualites[currentQuality];
        final detail0 = roomDetail;
        _preloadPlayUrlsFuture = site.liveSite
            .getPlayUrls(detail: detail0, quality: q)
            .then((r) {
          _preloadQuality = q.quality;
          _preloadPlayHeaders = r.headers;
          return r.urls;
        }).catchError((Object _) {
          _preloadPlayUrlsFuture = null;
          return <String>[];
        });
      }

      await getPlayUrl();
    } catch (e, stackTrace) {
      if (!_isCurrentLoad(loadGeneration)) {
        return;
      }
      Log.e(
        "读取播放清晰度失败：${site.id}/$roomId generation=$loadGeneration error=$e",
        stackTrace,
      );
      loadError.value = true;
      error = e;
      errorStackTrace = stackTrace;
    }
  }

  Future<int> getQualityLevel() async {
    var qualityLevel = AppSettingsController.instance.qualityLevel.value;
    try {
      var connectivityResult = await (Connectivity().checkConnectivity());
      if (connectivityResult.first == ConnectivityResult.mobile) {
        qualityLevel =
            AppSettingsController.instance.qualityLevelCellular.value;
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return qualityLevel;
  }

  Future<bool> _reloadPlayUrls(
      {bool resetLine = false, bool silent = false}) async {
    final loadGeneration = _loadGeneration;
    if (_roomDisposed) {
      return false;
    }
    if (detail.value == null ||
        currentQuality < 0 ||
        currentQuality >= qualites.length) {
      return false;
    }
    currentQualityInfo.value = qualites[currentQuality].quality;
    // 预解析缓存消费：首次进房且质量匹配时直接使用（省一次网络往返，进房秒出画面）。
    // 换质量/重试/切线路等场景 _preloadConsumed 已为 true，走原逻辑重新解析。
    List<String>? urls;
    Map<String, String>? headers;
    final pre = _preloadPlayUrlsFuture;
    if (!_preloadConsumed &&
        pre != null &&
        _preloadGeneration == loadGeneration &&
        _preloadQuality == qualites[currentQuality].quality) {
      _preloadConsumed = true;
      try {
        urls = await pre;
        headers = _preloadPlayHeaders;
      } catch (_) {
        urls = null;
      }
    }
    if (urls == null) {
      try {
        final playUrl = await site.liveSite
            .getPlayUrls(
              detail: detail.value!,
              quality: qualites[currentQuality],
            )
            // 进房主链路第二段超时保护：getRoomDetail 已加（P0-15），这里同样
            // 补上——弱网下详情秒回、播放地址卡住，用户会卡在「正在加载播放地址」。
            // 8 秒与 getRoomDetail 保持一致。超时后返回 false 走失败路径，语义
            // 与「拿不到地址」一致，不改变任何重试/换线路逻辑。
            .timeout(const Duration(seconds: 8));
        urls = playUrl.urls;
        headers = playUrl.headers;
      } catch (e) {
        if (!silent) {
          SmartDialog.showToast("读取播放地址超时，请稍后重试");
        }
        Log.d("读取播放地址超时/失败: $e");
        return false;
      }
    }
    if (!_isCurrentLoad(loadGeneration)) {
      return false;
    }
    if (urls.isEmpty) {
      if (!silent) {
        SmartDialog.showToast("无法读取播放地址");
      }
      return false;
    }
    playUrls.value = urls;
    playHeaders = headers;
    if (resetLine || currentLineIndex < 0) {
      currentLineIndex = 0;
    } else if (currentLineIndex >= playUrls.length) {
      currentLineIndex = playUrls.length - 1;
    }
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    // 自定义源：把 playUrls 扩展为该频道全部线路，使播放器内可切换线路。
    _applyCustomSourceLines();
    return true;
  }

  /// 自定义源多线路支持：按 roomId（播放地址）反查同名频道组，
  /// 将 playUrls 扩展为全部线路，并定位当前线路索引；
  /// 同时记录「上次线路」持久化，与浏览页点击频道的记忆互通。
  void _applyCustomSourceLines() {
    _customLineNames = null;
    if (site.liveSite is! CustomM3uSite) {
      return;
    }
    final svc = CustomSourceService.instance;
    final lines = svc.linesForUrl(roomId);
    if (lines == null || lines.isEmpty) {
      return;
    }
    final urls = lines.map((e) => e.url).toList();
    playUrls.value = urls;
    final idx = urls.indexOf(roomId);
    if (idx >= 0) {
      currentLineIndex = idx;
    } else if (currentLineIndex >= urls.length) {
      currentLineIndex = urls.length - 1;
    }
    if (currentLineIndex < 0) {
      currentLineIndex = 0;
    }
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    final baseName = lines.first.name.trim();
    _customLineNames = lines
        .map((l) {
          final n = l.name.trim();
          return (n.isEmpty || n == baseName) ? '' : n;
        })
        .toList();
    _recordCustomSourceLastLine(currentLineIndex);
  }

  /// 记录自定义源「上次线路」（键与浏览页一致：CustomSourceLastLine_<裸id>_<频道名>）。
  void _recordCustomSourceLastLine(int index) {
    if (index < 0 || index >= playUrls.length) return;
    final svc = CustomSourceService.instance;
    final url = playUrls[index];
    final srcId = svc.sourceIdForUrl(url);
    final ch = svc.channelForUrl(url);
    if (srcId == null || ch == null) return;
    final displayName = ch.name.trim().isEmpty ? url : ch.name.trim();
    if (displayName == url) return; // 无名称频道无合并组，无需记录
    LocalStorageService.instance.setValue(
      'CustomSourceLastLine_${srcId}_$displayName',
      url,
    );
  }

  Future<void> getPlayUrl() async {
    final loadGeneration = _loadGeneration;
    playUrls.clear();
    currentLineInfo.value = "";
    currentLineIndex = -1;
    if (!await _reloadPlayUrls(resetLine: true)) {
      return;
    }
    if (!_isCurrentLoad(loadGeneration)) {
      return;
    }
    // 重置播放器错误重试次数
    mediaErrorRetryCount = 0;
    await initPlaylist();
  }

  Future<void> changePlayLine(int index) async {
    currentLineIndex = index;
    // 自定义源：切换后记录为「上次线路」，浏览页下次点击沿用。
    _recordCustomSourceLastLine(index);
    // 切线时同样重置重试次数
    mediaErrorRetryCount = 0;
    await setPlayer();
  }

  Future<void> initPlaylist() async {
    final loadGeneration = _loadGeneration;
    if (_roomDisposed ||
        currentLineIndex < 0 ||
        currentLineIndex >= playUrls.length) {
      return;
    }

    // A room switch may leave an old open() in flight. Wait for that operation
    // to finish before opening the new room, otherwise its stale completion can
    // stop the new media or prevent the new room from starting at all.
    while (true) {
      if (!_isCurrentLoad(loadGeneration) ||
          currentLineIndex < 0 ||
          currentLineIndex >= playUrls.length) {
        return;
      }
      final reopening = _playerReopeningFuture;
      if (reopening == null) {
        break;
      }
      if (_playerReopeningGeneration == loadGeneration) {
        return;
      }
      try {
        await reopening;
      } catch (e, stackTrace) {
        Log.e("等待旧播放器打开完成失败: $e", stackTrace);
      }
    }

    if (!_isCurrentLoad(loadGeneration) ||
        currentLineIndex < 0 ||
        currentLineIndex >= playUrls.length) {
      return;
    }
    final reopening = _openPlaylist(loadGeneration);
    _playerReopeningGeneration = loadGeneration;
    _playerReopeningFuture = reopening;
    try {
      await reopening;
    } finally {
      if (identical(_playerReopeningFuture, reopening)) {
        _playerReopeningFuture = null;
        _playerReopeningGeneration = null;
      }
    }
  }

  Future<void> _openPlaylist(int loadGeneration) async {
    final mediaGeneration = ++_playbackMediaGeneration;
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";

    var finalUrl = playUrls[currentLineIndex];
    if (AppSettingsController.instance.playerForceHttps.value) {
      finalUrl = finalUrl.replaceAll("http://", "https://");
    }

    final previousWidth = player.state.width;
    final previousHeight = player.state.height;
    final wasPlaying = player.state.playing;
    Log.i(
      "准备打开播放器：target=${site.id}/$roomId "
      "quality=${currentQualityInfo.value} line=${currentLineIndex + 1}/${playUrls.length} "
      "previousPlaying=$wasPlaying previousSize=${previousWidth}x$previousHeight "
      "${MpvOptionsService.diagnosticsSummary()}",
    );

    // 重新初始化播放器，并带上当前线路的请求头。
    final openStopwatch = Stopwatch()..start();
    await initializePlayer(isVod: isVod);
    if (!_isCurrentLoad(loadGeneration)) {
      return;
    }

    await _stopDesktopPlayerBeforeOpen();
    if (!_isCurrentLoad(loadGeneration)) {
      return;
    }

    final opened = await openPlaybackMedia(
      Media(
        finalUrl,
        httpHeaders: playHeaders,
      ),
      loadGeneration: loadGeneration,
      mediaGeneration: mediaGeneration,
      // 换直播间/换流：重置纯音频锁定，新直播间重新探测（2026-09-01）
      resetAudioOnlyLock: true,
    );
    if (!opened) {
      return;
    }
    openStopwatch.stop();
    Log.i(
      "播放器打开完成：${site.id}/$roomId ${openStopwatch.elapsedMilliseconds}ms "
      "line=${currentLineIndex + 1}/${playUrls.length} "
      "size=${player.state.width}x${player.state.height}",
    );
    Log.d("播放链接\n$finalUrl");
    // 换文件后 mpv 会重新做轨道选择、vid 重置为 auto → 纯音频期间必须补停一次轨。
    // 覆盖所有重开路径：切清晰度、切线路、播放重试、后台恢复等。
    if (_videoTrackDisabled) {
      await setAudioOnlyMode(true);
    }
  }

  Future<void> _waitForPlayerReopen() async {
    final reopening = _playerReopeningFuture;
    if (reopening != null) {
      try {
        await reopening;
      } catch (e, stackTrace) {
        Log.e("等待播放器打开完成失败: $e", stackTrace);
      }
    }
    await waitForPlaybackOpen();
  }

  Future<void> _stopDesktopPlayerBeforeOpen() async {
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return;
    }
    if (!player.state.playing && player.state.playlist.medias.isEmpty) {
      return;
    }
    try {
      await player.stop();
      await Future.delayed(const Duration(milliseconds: 120));
    } catch (e, stackTrace) {
      Log.e("切换直播间前停止旧播放失败: $e", stackTrace);
    }
  }

  Future<void> setPlayer({bool refreshUrls = false}) async {
    if (refreshUrls) {
      var reloaded = await _reloadPlayUrls(silent: true);
      if (!reloaded) {
        return;
      }
    }
    await initPlaylist();
  }

  bool get _shouldRefreshUrlsOnPlaybackRetry =>
      site.id == Constant.kHuya || site.id == Constant.kDouyu;

  bool _isPlaybackEventCurrent(int loadGeneration, int mediaGeneration) {
    return _isCurrentLoad(loadGeneration) &&
        mediaGeneration == _playbackMediaGeneration;
  }

  @override
  void mediaEnd() async {
    final loadGeneration = _loadGeneration;
    final mediaGeneration = _playbackMediaGeneration;
    if (!_isPlaybackEventCurrent(loadGeneration, mediaGeneration)) {
      return;
    }
    super.mediaEnd();
    // 点播（影视）：播放结束 → 自动连播下一集；无下一集则停在结束态，
    // 不走直播的"刷新重试/切线路/切下一房间"逻辑。
    if (isVod && hasVodEpisodes.value) {
      final next = _nextVodEpisode(roomId);
      if (next != null) {
        Log.i("自动连播下一集：${next.displayTitle}");
        await playVodEpisode(next);
      } else {
        Log.i("点播播放结束（无下一集）");
        liveStatus.value = false;
      }
      return;
    }
    if (mediaErrorRetryCount < 2) {
      Log.d("播放结束，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount == 1) {
        // 第二次重试前稍等一秒
        await Future.delayed(const Duration(seconds: 1));
      }
      if (!_isPlaybackEventCurrent(loadGeneration, mediaGeneration)) {
        return;
      }
      mediaErrorRetryCount += 1;
      await setPlayer(refreshUrls: _shouldRefreshUrlsOnPlaybackRetry);
      return;
    }

    Log.d("播放结束");
    // 依次尝试剩余线路，全部失败后再判定为已下播。
    if (playUrls.length - 1 == currentLineIndex) {
      if (site.id == Constant.kHuya) {
        currentLineIndex = 0;
        mediaErrorRetryCount = 0;
        await setPlayer(refreshUrls: true);
        return;
      }
      liveStatus.value = false;
      await _tryAutoSwitchToNextLiveRoom(reason: "live_end");
    } else {
      await changePlayLine(currentLineIndex + 1);

      //setPlayer();
    }
  }

  int mediaErrorRetryCount = 0;
  @override
  void mediaError(String error) async {
    final loadGeneration = _loadGeneration;
    final mediaGeneration = _playbackMediaGeneration;
    if (!_isPlaybackEventCurrent(loadGeneration, mediaGeneration)) {
      return;
    }
    super.mediaError(error);
    if (mediaErrorRetryCount < 2) {
      Log.d("播放失败，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount == 1) {
        // 第二次重试前稍等一秒
        await Future.delayed(const Duration(seconds: 1));
      }
      if (!_isPlaybackEventCurrent(loadGeneration, mediaGeneration)) {
        return;
      }
      mediaErrorRetryCount += 1;
      await setPlayer(refreshUrls: _shouldRefreshUrlsOnPlaybackRetry);
      return;
    }

    if (playUrls.length - 1 == currentLineIndex) {
      if (site.id == Constant.kHuya) {
        currentLineIndex = 0;
        mediaErrorRetryCount = 0;
        await setPlayer(refreshUrls: true);
        return;
      }
      errorMsg.value = "播放失败";
      SmartDialog.showToast("播放失败: $error");
      await _tryAutoSwitchToNextLiveRoom(reason: "playback_failure");
    } else {
      //currentLineIndex += 1;
      //setPlayer();
      await changePlayLine(currentLineIndex + 1);
    }
  }

  Future<void> _tryAutoSwitchToNextLiveRoom({required String reason}) async {
    final settings = AppSettingsController.instance;
    final enabled = reason == "live_end"
        ? settings.autoSwitchNextOnLiveEnd.value
        : settings.autoSwitchNextOnPlaybackFailure.value;
    if (!enabled || _autoSwitchingRoom) {
      return;
    }

    final liveChannels = FollowService.instance.sortFollowUsers(
      FollowService.instance.liveList,
    );
    if (liveChannels.isEmpty) {
      return;
    }

    final currentId = "${site.id}_$roomId";
    final currentIndex =
        liveChannels.indexWhere((item) => item.id == currentId);
    final candidates =
        liveChannels.where((item) => item.id != currentId).toList();
    if (candidates.isEmpty) {
      return;
    }

    FollowUser target;
    if (currentIndex < 0 || currentIndex >= liveChannels.length - 1) {
      target = candidates.first;
    } else {
      target = liveChannels[currentIndex + 1];
      if (target.id == currentId) {
        target = candidates.first;
      }
    }

    _autoSwitchingRoom = true;
    try {
      // 目标站点可能已被删除/未注册（自定义源/影视库被删后仍在关注列表里），
      // 此时不能直接切（原 `Sites.allSites[...]!` 对 null 断言崩溃），跳过切换。
      final targetSite = Sites.siteForKey(target.siteId);
      if (targetSite == null) {
        Log.d("自动切换直播间失败：站点未注册 siteId=${target.siteId}");
        return;
      }
      SmartDialog.showToast(
        reason == "live_end" ? "当前直播已结束，已切换到下一个直播间" : "当前直播播放失败，已切换到下一个直播间",
      );
      resetRoom(targetSite, target.roomId);
    } finally {
      _autoSwitchingRoom = false;
    }
  }

  /// 读取头条 / SC
  void getSuperChatMessage({bool silent = false}) async {
    if (detail.value == null) {
      return;
    }
    try {
      var sc = await site.liveSite.getSuperChatMessage(
        roomId: detail.value!.roomId,
        detail: detail.value,
      );
      final filtered = sc.map(_sanitizeSuperChatMessage).where((item) {
        if (_isUserShielded(item.userName) || isTempMutedUser(item.userName)) {
          return false;
        }
        return !_isKeywordShielded(_superChatToLiveMessage(item));
      });
      _appendSuperChats(filtered);
      removeSuperChats();
    } catch (e) {
      Log.logPrint(e);
      if (silent) {
        return;
      }
      addSysMsg("SC 读取失败");
    }
  }

  /// 移除已经过期的头条 / SC
  void removeSuperChats() async {
    var now = DateTime.now().millisecondsSinceEpoch;
    superChats.value = superChats
        .where((x) => x.endTime.millisecondsSinceEpoch > now)
        .toList();
    _sortSuperChats();
    _refreshSuperChatFingerprints();
  }

  /// 娣诲姞鍘嗗彶璁板綍
  void addHistory() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    var history = DBService.instance.getHistory(id);
    if (history != null) {
      history.updateTime = DateTime.now();
    }
    history ??= History(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      updateTime: DateTime.now(),
    );

    DBService.instance.addOrUpdateHistory(history);
  }

  /// 关注用户
  void followUser() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    DBService.instance.addFollow(
      FollowUser(
        id: id,
        roomId: roomId,
        siteId: site.id,
        userName: detail.value?.userName ?? "",
        face: detail.value?.userAvatar ?? "",
        addTime: DateTime.now(),
      ),
    );
    followed.value = true;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  /// 取消关注当前主播
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    if (!await Utils.showAlertDialog(
      "确定要取消关注这位主播吗？",
      title: "取消关注",
    )) {
      return;
    }

    var id = "${site.id}_$roomId";
    DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  void share() {
    if (detail.value == null) {
      return;
    }
    final url = detail.value!.url;
    if (Platform.isWindows) {
      Utils.copyToClipboard(url);
      return;
    }
    SharePlus.instance.share(ShareParams(uri: Uri.parse(url)));
  }

  void copyUrl() {
    if (detail.value == null) {
      return;
    }
    Utils.copyToClipboard(detail.value!.url);
    SmartDialog.showToast("已复制直播间链接");
  }

  /// 复制当前生成的播放直链
  void copyPlayUrl() async {
    // 未开播时不复制
    if (!liveStatus.value) {
      return;
    }
    var playUrl = await site.liveSite
        .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
    if (playUrl.urls.isEmpty) {
      SmartDialog.showToast("无法读取播放地址");
      return;
    }
    Utils.copyToClipboard(playUrl.urls.first);
    SmartDialog.showToast("已复制播放直链");
  }

  /// 底部弹出弹幕设置
  void showDanmuSettingsSheet() {
    Utils.showBottomSheet(
      title: "弹幕设置",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          DanmuSettingsView(
            danmakuController: danmakuController,
            siteId: site.id,
            previewViewportHeight: danmakuViewportHeight.value,
            onTapDanmuShield: () {
              Get.back();
              showDanmuShield();
            },
          ),
        ],
      ),
    );
  }

  void showLiveSettingsSheet() {
    final settings = AppSettingsController.instance;
    Utils.showBottomSheet(
      title: "直播设置",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          SettingsCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(
                  () => SettingsSwitch(
                    title: "硬件解码",
                    subtitle: "播放失败可尝试关闭此选项",
                    value: settings.hardwareDecode.value,
                    onChanged: settings.setHardwareDecode,
                  ),
                ),
                if (Platform.isAndroid) ...[
                  AppStyle.divider,
                  Obx(
                    () => SettingsSwitch(
                      title: "兼容模式",
                      subtitle: "若播放卡顿可尝试打开此选项",
                      value: settings.playerCompatMode.value,
                      onChanged: settings.setPlayerCompatMode,
                    ),
                  ),
                ],
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "强制 HTTPS",
                    subtitle: "将 http 播放链接替换为 https",
                    value: settings.playerForceHttps.value,
                    onChanged: settings.setPlayerForceHttps,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _cancelVolumeSliderDismiss() {
    hidevolumeTimer?.cancel();
    hidevolumeTimer = null;
  }

  void _scheduleVolumeSliderDismiss(Duration delay) {
    _cancelVolumeSliderDismiss();
    hidevolumeTimer = Timer(delay, () {
      hidevolumeTimer = null;
      _volumeSliderPointerEntered = false;
      volumeSliderVisible = false;
      SmartDialog.dismiss(tag: volumeSliderDialogTag);
    });
  }

  void showVolumeSlider(
    BuildContext targetContext, {
    bool keepAlive = false,
  }) {
    // The attach dialog uses a full-screen mask. Keep the player controls from
    // treating that mask transition as a pointer exit and dismissing the
    // slider immediately after it opens.
    hideControlsTimer?.cancel();
    hideControlsTimer = null;
    _cancelVolumeSliderDismiss();
    volumeSliderVisible = true;
    _volumeSliderPointerEntered = false;
    _scheduleVolumeSliderDismiss(
      keepAlive ? const Duration(seconds: 6) : const Duration(seconds: 4),
    );
    SmartDialog.showAttach(
      targetContext: targetContext,
      alignment: Alignment.topCenter,
      displayTime: null,
      maskColor: const Color(0x00000000),
      clickMaskDismiss: false,
      usePenetrate: true,
      useAnimation: false,
      tag: volumeSliderDialogTag,
      keepSingle: true,
      builder: (context) {
        return MouseRegion(
          onEnter: (_) {
            _volumeSliderPointerEntered = true;
            _cancelVolumeSliderDismiss();
          },
          onExit: (_) => hideVolumeSlider(),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: AppStyle.radius12,
              color: Theme.of(context).cardColor,
            ),
            padding: AppStyle.edgeInsetsA4,
            child: Obx(
              () => SizedBox(
                width: 200,
                child: Slider(
                  min: 0,
                  max: 100,
                  value: AppSettingsController.instance.playerVolume.value,
                  onChangeStart: (_) => _cancelVolumeSliderDismiss(),
                  onChanged: (newValue) {
                    setSessionPlayerVolume(newValue, persist: true);
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void hideVolumeSlider() {
    if (!_volumeSliderPointerEntered) {
      return;
    }
    _scheduleVolumeSliderDismiss(const Duration(milliseconds: 600));
  }

  void showQualitySheet() {
    Utils.showBottomSheet(
      title: "切换清晰度",
      child: RadioGroup(
        groupValue: currentQuality,
        onChanged: (e) async {
          Get.back();
          // 切清晰度会重开流，影视会从头播 → 先记住进度，重开后 seek 回去。
          final previousPosition =
              isVod ? player.state.position : Duration.zero;
          currentQuality = e ?? 0;
          // 用户已手动指定清晰度 → 纯音频期间的自动降档记录作废，退出时不再还原。
          _qualityBeforeAudioOnly = -1;
          // getPlayUrl 解析的是正常流（不是站点纯音频流），标记同步清掉，
          // 否则退出纯音频时会多一次无谓的重开。
          _usingAudioOnlyStream = false;
          await getPlayUrl();
          if (isVod && previousPosition > Duration.zero) {
            await _seekAfterQualitySwitch(previousPosition);
          }
        },
        child: ListView.builder(
          itemCount: qualites.length,
          itemBuilder: (_, i) {
            var item = qualites[i];
            return RadioListTile(
              value: i,
              title: Text(item.quality),
            );
          },
        ),
      ),
    );
  }

  void showPlayUrlsSheet() {
    Utils.showBottomSheet(
      title: "线路选择",
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RadioGroup(
            groupValue: currentLineIndex,
            onChanged: (e) {
              Get.back();
              //currentLineIndex = i;
              //setPlayer();
              changePlayLine(e ?? 0);
            },
            child: ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: playUrls.length,
              itemBuilder: (_, i) {
                final customName = (_customLineNames != null &&
                        i < _customLineNames!.length)
                    ? _customLineNames![i]
                    : '';
                return RadioListTile(
                  value: i,
                  title: Text(
                    customName.isEmpty ? "线路${i + 1}" : customName,
                  ),
                  secondary: Text(
                    playUrls[i].contains(".flv") ? "FLV" : "HLS",
                  ),
                );
              },
            ),
          ),
          buildIosRenderCapSelector(),
        ],
      ),
    );
  }

  void showPlayerSettingsSheet() {
    Utils.showBottomSheet(
      title: "画面尺寸",
      child: Obx(
        () => RadioGroup(
          groupValue: AppSettingsController.instance.scaleMode.value,
          onChanged: (e) {
            AppSettingsController.instance.setScaleMode(e ?? 0);
            updateScaleMode();
          },
          child: ListView(
            padding: AppStyle.edgeInsetsV12,
            children: const [
              RadioListTile(
                value: 0,
                title: Text("适应"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 1,
                title: Text("拉伸"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 2,
                title: Text("铺满"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 3,
                title: Text("16:9"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 4,
                title: Text("4:3"),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showDanmuShield() {
    Get.toNamed(RoutePath.kSettingsDanmuShield);
  }

  LiveSubCategory? _buildRecommendationCategory() {
    final roomDetail = detail.value;
    if (roomDetail == null) {
      return null;
    }
    final categoryId = (roomDetail.categoryId ?? "").trim();
    final categoryName = (roomDetail.categoryName ?? "").trim();
    final parentId = (roomDetail.categoryParentId ?? "").trim();
    final parentName = (roomDetail.categoryParentName ?? "").trim();
    if (categoryId.isEmpty && parentId.isEmpty) {
      return null;
    }
    final resolvedId = categoryId.isNotEmpty ? categoryId : parentId;
    final resolvedParentId = parentId.isNotEmpty ? parentId : resolvedId;
    final resolvedName = categoryName.isNotEmpty
        ? categoryName
        : parentName.isNotEmpty
            ? parentName
            : roomDetail.title.trim();
    if (resolvedId.isEmpty || resolvedName.isEmpty) {
      return null;
    }
    final pic = roomDetail.categoryPic?.trim();
    return LiveSubCategory(
      id: resolvedId,
      name: resolvedName,
      parentId: resolvedParentId,
      pic: pic == null || pic.isEmpty ? null : pic,
    );
  }

  bool get hasCategoryRecommendation => _buildRecommendationCategory() != null;

  String get currentRecommendationSubtitle {
    final roomDetail = detail.value;
    final category = _buildRecommendationCategory();
    if (roomDetail == null || category == null) {
      return "当前直播间暂时还没有可用的分区标签";
    }
    final parentName = (roomDetail.categoryParentName ?? "").trim();
    if (parentName.isNotEmpty && parentName != category.name) {
      return "${site.name} / $parentName / ${category.name}";
    }
    return "${site.name} / ${category.name}";
  }

  bool get useFullscreenSidePanelMenus =>
      fullScreenState.value && (Platform.isAndroid || Platform.isIOS);

  List<String> get enabledQuickAccessKeys {
    final settings = AppSettingsController.instance;
    return settings.liveRoomQuickAccessSort
        .where((key) =>
            settings.liveRoomQuickAccessEnabled.contains(key) &&
            Constant.allLiveRoomQuickAccess.containsKey(key) &&
            (key != "contribution_rank" ||
                (supportsContributionRank &&
                    settings.contributionRankEnable.value)))
        .toList();
  }

  String quickAccessTitle(String key) {
    if (key == "contribution_rank") {
      return site.id == Constant.kDouyu ? "亲密榜" : "贡献榜";
    }
    return Constant.allLiveRoomQuickAccess[key]?.title ?? "";
  }

  String quickAccessSubtitle(String key) {
    if (key == "recommendation") {
      return currentRecommendationSubtitle;
    }
    if (key == "contribution_rank") {
      return "";
    }
    return Constant.allLiveRoomQuickAccess[key]?.subtitle ?? "";
  }

  void showContributionRankSheet() {
    if (!supportsContributionRank) {
      return;
    }
    if (!AppSettingsController.instance.contributionRankEnable.value) {
      return;
    }
    fetchContributionRank(forceRefresh: true);
    Utils.showBottomSheet(
      title: site.id == Constant.kDouyu ? "亲密榜" : "贡献榜",
      child: SizedBox(
        height: Get.height * 0.75,
        child: LiveContributionRankPanel(controller: this),
      ),
    );
  }

  Widget buildHistorySelection({
    required VoidCallback onClose,
    ScrollController? scrollController,
  }) {
    final currentSite = site;
    final histories = <History>[].obs;
    final loading = true.obs;

    Future<void> loadHistory() async {
      loading.value = true;
      try {
        histories.value = DBService.instance.getHistores();
      } finally {
        loading.value = false;
      }
    }

    unawaited(loadHistory());

    return Obx(() {
      if (loading.value && histories.isEmpty) {
        return const Center(child: CircularProgressIndicator());
      }
      if (histories.isEmpty) {
        return AppEmptyWidget(
          message: "暂无观看历史",
          onRefresh: loadHistory,
        );
      }
      return RefreshIndicator(
        onRefresh: loadHistory,
        child: ListView.separated(
          key: const PageStorageKey<String>("liveRoomHistorySelection"),
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: AppStyle.edgeInsetsA12,
          itemCount: histories.length,
          separatorBuilder: (_, __) => AppStyle.divider,
          itemBuilder: (_, i) {
            final item = histories[i];
            final historySite = Sites.allSites[item.siteId];
            final isCurrent =
                currentSite.id == item.siteId && roomId == item.roomId;
            return Material(
              color: Colors.transparent,
              child: ListTile(
                selected: isCurrent,
                contentPadding: AppStyle.edgeInsetsL16.copyWith(right: 8),
                leading: NetImage(
                  item.face,
                  width: 48,
                  height: 48,
                  borderRadius: 24,
                ),
                title: Text(
                  item.userName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Row(
                  children: [
                    if (historySite != null) ...[
                      Image.asset(
                        historySite.logo,
                        width: 20,
                      ),
                      AppStyle.hGap4,
                    ],
                    Expanded(
                      child: Text(
                        historySite?.name ?? item.siteId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                    AppStyle.hGap8,
                    Text(
                      Utils.parseTime(item.updateTime),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
                onTap: historySite == null
                    ? null
                    : () {
                        onClose();
                        resetRoom(historySite, item.roomId);
                      },
                onLongPress: () async {
                  final confirmed = await Utils.showAlertDialog(
                    "确定要删除此记录吗?",
                    title: "删除记录",
                  );
                  if (!confirmed) {
                    return;
                  }
                  await DBService.runExclusive(() => DBService.instance.historyBox.delete(DBService.safeBoxKey(item.id)));
                  await loadHistory();
                },
              ),
            );
          },
        ),
      );
    });
  }

  Widget buildCategoryRecommendationSelection({
    required VoidCallback onClose,
    ScrollController? scrollController,
  }) {
    final currentSite = site;
    final currentRoomId = roomId;
    final category = _buildRecommendationCategory();
    if (category == null) {
      return const AppEmptyWidget(
        message: "当前直播间暂无同类推荐内容",
      );
    }

    final rooms = <LiveRoomItem>[].obs;
    final loading = true.obs;
    final page = 1.obs;
    final hasMore = true.obs;

    Future<void> loadRecommendations({bool refresh = false}) async {
      if (loading.value && !refresh) {
        return;
      }
      loading.value = true;
      try {
        final targetPage = refresh ? 1 : page.value;
        final result = await site.liveSite.getCategoryRooms(
          category,
          page: targetPage,
        );
        final fetched =
            result.items.where((item) => item.roomId != roomId).toList();
        if (refresh) {
          rooms.assignAll(fetched);
          page.value = 2;
        } else {
          final existingRoomIds = rooms.map((item) => item.roomId).toSet();
          rooms.addAll(
            fetched.where((item) => !existingRoomIds.contains(item.roomId)),
          );
          page.value = targetPage + 1;
        }
        hasMore.value = fetched.isNotEmpty;
      } catch (e) {
        if (rooms.isEmpty) {
          SmartDialog.showToast("加载同类推荐失败: ${exceptionToString(e)}");
        } else {
          handleError(e);
        }
      } finally {
        loading.value = false;
      }
    }

    unawaited(loadRecommendations(refresh: true));

    return Obx(() {
      if (loading.value && rooms.isEmpty) {
        return const Center(child: CircularProgressIndicator());
      }
      if (rooms.isEmpty) {
        return AppEmptyWidget(
          message: "当前分区暂无可用推荐",
          onRefresh: () => loadRecommendations(refresh: true),
        );
      }
      return RefreshIndicator(
        onRefresh: () => loadRecommendations(refresh: true),
        child: ListView.builder(
          key: const PageStorageKey<String>(
            "liveRoomCategoryRecommendationSelection",
          ),
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: AppStyle.edgeInsetsA12,
          itemCount: rooms.length + 2,
          itemBuilder: (_, i) {
            if (i == 0) {
              return Padding(
                padding: AppStyle.edgeInsetsB12,
                child: Text(
                  currentRecommendationSubtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                  ),
                ),
              );
            }
            if (i == rooms.length + 1) {
              if (loading.value) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (!hasMore.value) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: Text(
                      "已经到底了",
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: TextButton.icon(
                  onPressed: () => loadRecommendations(),
                  icon: const Icon(Icons.expand_more),
                  label: const Text("加载更多"),
                ),
              );
            }

            final item = rooms[i - 1];
            final isCurrent =
                currentSite.id == site.id && currentRoomId == item.roomId;
            return Padding(
              padding: EdgeInsets.only(bottom: i == rooms.length ? 0 : 8),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    onClose();
                    resetRoom(site, item.roomId);
                  },
                  child: Ink(
                    padding: AppStyle.edgeInsetsA8,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: isCurrent
                          ? Get.theme.colorScheme.primary.withAlpha(25)
                          : Get.theme.cardColor,
                      border: Border.all(
                        color: isCurrent
                            ? Get.theme.colorScheme.primary.withAlpha(120)
                            : Colors.grey.withAlpha(25),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: NetImage(
                            item.cover,
                            width: 108,
                            height: 60,
                            fit: BoxFit.cover,
                          ),
                        ),
                        AppStyle.hGap12,
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              AppStyle.vGap4,
                              Text(
                                item.userName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                              AppStyle.vGap4,
                              Text(
                                "热度 ${Utils.onlineToString(item.online)}",
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    });
  }

  void openHistoryPage() {
    if (useFullscreenSidePanelMenus) {
      Utils.showRightDialog(
        title: "观看历史",
        width: 420,
        useSystem: true,
        child: buildHistorySelection(
          onClose: Utils.hideRightDialog,
          scrollController: liveRoomHistoryScrollController,
        ),
      );
      return;
    }
    AppNavigator.toHistory(
      onRoomSelected: (selectedSite, selectedRoomId) {
        resetRoom(selectedSite, selectedRoomId);
      },
    );
  }

  void openCategoryRecommendation() {
    final category = _buildRecommendationCategory();
    if (category == null) {
      SmartDialog.showToast("当前直播间还没有可用的分区标签");
      return;
    }
    if (useFullscreenSidePanelMenus) {
      Utils.showRightDialog(
        title: "同类推荐",
        width: 420,
        useSystem: true,
        child: buildCategoryRecommendationSelection(
          onClose: Utils.hideRightDialog,
          scrollController: liveRoomRecommendationScrollController,
        ),
      );
      return;
    }
    AppNavigator.toCategoryDetail(
      site: site,
      category: category,
      excludedRoomId: roomId,
      onRoomSelected: (selectedSite, selectedRoomId) {
        resetRoom(selectedSite, selectedRoomId);
      },
    );
  }

  void showQuickAccessSheet() {
    final keys = enabledQuickAccessKeys;
    Utils.showBottomSheet(
      title: "快捷入口",
      child: ListView(
        children: keys.map((key) {
          final item = Constant.allLiveRoomQuickAccess[key]!;
          final enabled = key != "recommendation" || hasCategoryRecommendation;
          final sub = quickAccessSubtitle(key);
          return ListTile(
            leading: Icon(item.iconData),
            title: Text(quickAccessTitle(key)),
            subtitle: sub.isEmpty ? null : Text(sub),
            enabled: enabled,
            onTap: !enabled
                ? null
                : () {
                    Get.back();
                    switch (key) {
                      case "follow":
                        showFollowUserSheet();
                        break;
                      case "history":
                        openHistoryPage();
                        break;
                      case "recommendation":
                        openCategoryRecommendation();
                        break;
                      case "contribution_rank":
                        showContributionRankSheet();
                        break;
                    }
                  },
          );
        }).toList(),
      ),
    );
  }

  List<FollowUser> _followUsersByFilterMode(int filterMode) {
    switch (filterMode) {
      case 1:
        return FollowService.instance.sortFollowUsers(
          FollowService.instance.liveList,
        );
      case 2:
        return FollowService.instance.sortFollowUsers(
          FollowService.instance.notLiveList,
        );
      default:
        return FollowService.instance.sortFollowUsers(
          FollowService.instance.followList,
        );
    }
  }

  Widget buildFollowUserSelection({
    required VoidCallback onClose,
    ScrollController? scrollController,
  }) {
    const options = ["全部", "直播中", "未开播"];
    return Obx(() {
      final filterMode = liveRoomFollowFilterMode.value;
      final followUsers = _followUsersByFilterMode(filterMode);
      return Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: AppStyle.edgeInsetsA12.copyWith(bottom: 0),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: List.generate(options.length, (index) {
                      return Padding(
                        padding: EdgeInsets.only(
                          right: index == options.length - 1 ? 0 : 12,
                        ),
                        child: FilterButton(
                          text: options[index],
                          selected: filterMode == index,
                          onTap: () {
                            liveRoomFollowFilterMode.value = index;
                          },
                        ),
                      );
                    }),
                  ),
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: FollowService.instance.loadData,
                  child: ListView.builder(
                    key: const PageStorageKey<String>(
                      "liveRoomFollowUserSelection",
                    ),
                    controller: scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: AppStyle.edgeInsetsV8,
                    itemCount: followUsers.length,
                    itemBuilder: (_, i) {
                      var item = followUsers[i];
                      return _buildLiveRoomFollowItem(
                        item: item,
                        onClose: onClose,
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
          if (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
            Positioned(
              right: 12,
              bottom: 12,
              child: Obx(
                () => DesktopRefreshButton(
                  refreshing: FollowService.instance.updating.value,
                  onPressed: FollowService.instance.loadData,
                ),
              ),
            ),
        ],
      );
    });
  }

  Widget _buildLiveRoomFollowItem({
    required FollowUser item,
    required VoidCallback onClose,
  }) {
    return Obx(
      () => FollowUserItem(
        item: item,
        showSpecialMark: true,
        playing:
            rxSite.value.id == item.siteId && rxRoomId.value == item.roomId,
        onTap: () {
          // 站点可能已删除/未注册（自定义源/影视库被删后仍在关注列表里），
          // 点击进入时兜底处理，避免 `Sites.allSites[...]!` 对 null 断言崩溃。
          final targetSite = Sites.siteForKey(item.siteId);
          if (targetSite == null) {
            SmartDialog.showToast("该直播间所属站点已不存在");
            return;
          }
          onClose();
          resetRoom(
            targetSite,
            item.roomId,
          );
        },
      ),
    );
  }

  void showFollowUserSheet() {
    Utils.showBottomSheet(
      title: "关注列表",
      child: buildFollowUserSelection(
        onClose: Get.back,
      ),
    );
  }

  void showAutoExitSheet() {
    Utils.showBottomSheet(
      title: "定时关闭",
      child: ListView(
        children: [
          Obx(
            () => SettingsSwitch(
              title: "启用定时关闭",
              titleStyle: Get.textTheme.titleMedium,
              value: autoExitEnable.value,
              onChanged: (e) {
                autoExitEnable.value = e;
                if (e) {
                  autoExitMinutes.value =
                      AppSettingsController.instance.roomAutoExitDuration.value;
                  setAutoExit();
                } else {
                  stopAutoExit();
                }
              },
            ),
          ),
          Obx(
            () => ListTile(
              enabled: autoExitEnable.value,
              title: Text(
                autoExitSource.value == AutoExitSource.global
                    ? "全局定时关闭：${autoExitMinutes.value ~/ 60}小时${autoExitMinutes.value % 60}分钟"
                    : "本次观看：${autoExitMinutes.value ~/ 60}小时${autoExitMinutes.value % 60}分钟",
                style: Get.textTheme.titleMedium,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                var value = await showTimePicker(
                  context: Get.context!,
                  initialTime: TimeOfDay(
                    hour: autoExitMinutes.value ~/ 60,
                    minute: autoExitMinutes.value % 60,
                  ),
                  initialEntryMode: TimePickerEntryMode.inputOnly,
                  builder: (_, child) {
                    return MediaQuery(
                      data: Get.mediaQuery.copyWith(
                        alwaysUse24HourFormat: true,
                      ),
                      child: child!,
                    );
                  },
                );
                if (value == null || (value.hour == 0 && value.minute == 0)) {
                  return;
                }
                var duration =
                    Duration(hours: value.hour, minutes: value.minute);
                autoExitMinutes.value = duration.inMinutes;
                AppSettingsController.instance
                    .setRoomAutoExitDuration(autoExitMinutes.value);
                if (autoExitEnable.value) {
                  setAutoExit();
                } else {
                  countdown.value = 0;
                }
              },
            ),
          ),
          Obx(
            () {
              countdown.value;
              final globalRemaining = _autoExitSession.globalRemaining(
                DateTime.now(),
              );
              if (autoExitSource.value != AutoExitSource.roomOverride ||
                  globalRemaining <= Duration.zero) {
                return const SizedBox.shrink();
              }
              return ListTile(
                dense: true,
                title: Text(
                  "全局定时关闭剩余：${_formatAutoExitDuration(globalRemaining)}",
                ),
                subtitle: const Text("当前修改只影响本次观看，不会修改全局设置"),
              );
            },
          ),
        ],
      ),
    );
  }

  String _formatAutoExitDuration(Duration duration) {
    final minutes = (duration.inSeconds + 59) ~/ 60;
    final hours = minutes ~/ 60;
    final remainMinutes = minutes % 60;
    return hours > 0 ? "$hours小时$remainMinutes分钟" : "$remainMinutes分钟";
  }

  void openNaviteAPP() async {
    var naviteUrl = "";
    var webUrl = "";
    if (site.id == Constant.kBiliBili) {
      naviteUrl = "bilibili://live/${detail.value?.roomId}";
      webUrl = "https://live.bilibili.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyin) {
      var args = detail.value?.danmakuData as DouyinDanmakuArgs;
      naviteUrl = "snssdk1128://webcast_room?room_id=${args.roomId}";
      webUrl = "https://live.douyin.com/${args.webRid}";
    } else if (site.id == Constant.kHuya) {
      var args = detail.value?.danmakuData as HuyaDanmakuArgs;
      naviteUrl =
          "yykiwi://homepage/index.html?banneraction=https%3A%2F%2Fdiy-front.cdn.huya.com%2Fzt%2Ffrontpage%2Fcc%2Fupdate.html%3Fhyaction%3Dlive%26channelid%3D${args.subSid}%26subid%3D${args.subSid}%26liveuid%3D${args.subSid}%26screentype%3D1%26sourcetype%3D0%26fromapp%3Dhuya_wap%252Fclick%252Fopen_app_guide%26&fromapp=huya_wap/click/open_app_guide";
      webUrl = "https://www.huya.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyu) {
      naviteUrl =
          "douyulink://?type=90001&schemeUrl=douyuapp%3A%2F%2Froom%3FliveType%3D0%26rid%3D${detail.value?.roomId}";
      webUrl = "https://www.douyu.com/${detail.value?.roomId}";
    }
    try {
      await launchUrlString(naviteUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法打开 APP，将使用浏览器打开");
      await launchUrlString(webUrl, mode: LaunchMode.externalApplication);
    }
  }

  void resetRoom(Site site, String roomId) async {
    if (this.site == site && this.roomId == roomId) {
      return;
    }

    if (_roomSwitching) {
      _pendingRoomSite = site;
      _pendingRoomId = roomId;
      return;
    }

    _roomSwitching = true;
    try {
      while (true) {
        final currentSite = site;
        final currentRoomId = roomId;
        rxSite.value = currentSite;
        rxRoomId.value = currentRoomId;
        CurrentRoomService.instance.setRoom(currentSite, currentRoomId);
        _roomDisposed = false;
        _loadGeneration += 1;
        tempMutedUsers.clear();
        danmakuViewportHeight.value = 0;

        // 清理当前房间的会话状态
        await liveDanmaku.stop();
        messages.clear();
        _clearDanmuDedupeState();
        _clearSuperChatState();
        _clearContributionRankState();
        clearLiveEventFlow();
        _cancelPendingDanmakuTimers();
        clearDanmakuReplayHistory();
        danmakuController?.clear();
        rebuildDanmakuView();

        // 重新创建弹幕连接对象
        liveDanmaku = currentSite.liveSite.getDanmaku();

        // 停止当前播放
        await stopBackgroundPlaybackService();
        await _waitForPlayerReopen();
        await player.stop();

        // 重新拉取房间信息
        loadData();

        final pendingSite = _pendingRoomSite;
        final pendingRoomId = _pendingRoomId;
        _pendingRoomSite = null;
        _pendingRoomId = null;
        if (pendingSite == null || pendingRoomId == null) {
          break;
        }
        site = pendingSite;
        roomId = pendingRoomId;
      }
    } finally {
      _roomSwitching = false;
    }
  }

  void copyErrorDetail() {
    Utils.copyToClipboard('''直播平台：${rxSite.value.name}
房间号：${rxRoomId.value}
错误信息：
${error?.toString()}
----------------
${errorStackTrace ?? ""}''');
    SmartDialog.showToast("已复制错误信息");
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    refreshIosVideoOutputLimit(force: true);
  }

  /// 退后台要停掉的常驻定时器。
  ///
  /// 原来这里只做「保存房间 + player.pause()」，下面四个定时器一个不停：
  /// 10s 在线刷新（每次一个 getRoomDetail 网络请求）、4s SuperChat、
  /// 3s 事件流、1s 开播时长；播放器那边的 3s Surface 检查与 3s 停滞看门狗
  /// 也照跑 —— 退后台后每 10 秒 6 次唤醒 + 持续网络请求。
  void _suspendBackgroundTimers() {
    _onlineRefreshTimer?.cancel();
    _onlineRefreshTimer = null;
    _onlineRefreshInFlight = false;
    _superChatRefreshTimer?.cancel();
    _superChatRefreshTimer = null;
    _liveEventFlowTimer?.cancel();
    _liveEventFlowTimer = null;
    _liveDurationTimer?.cancel();
    _liveDurationTimer = null;
    suspendPlaybackHealthTimers();
    Log.d("退后台：常驻定时器已暂停");
  }

  /// 回到前台恢复常驻定时器。
  ///
  /// 其中三个各自带前置守卫（在线刷新要 liveStatus、SuperChat 要虎牙平台
  /// + liveStatus、开播时长要 status + showTime），不满足就直接 return，
  /// 所以无条件调用不会把本来不该跑的定时器拉起来。
  ///
  /// 事件流定时器没有前置守卫，但它是幂等的（内部先 cancel 旧的），重复调用
  /// 不会变成两个。它刻意**不**按「功能开关」守卫：开关判断在
  /// _recordLiveEventFlow（记录侧）而不在定时器侧，且它只在进房时启动一次
  /// （onInit :476），全仓库没有「开关改动后重启定时器」的监听，一旦按开关
  /// 跳过就再也起不来了，那才是真 bug。
  void _resumeBackgroundTimers() {
    _restartOnlineRefreshTimer(refreshImmediately: true);
    _restartSuperChatRefreshTimer();
    _startLiveEventFlowTimer();
    startLiveDurationTimer();
    resumePlaybackHealthTimers();
    Log.d("返回前台：常驻定时器已恢复");
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state != AppLifecycleState.resumed) {
      clearTransientPlayerOverlays();
    }

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _enterBackgroundState(state.toString());
    } else if (state == AppLifecycleState.resumed) {
      Log.d("返回前台");
      // 定时关闭倒计时只在移动端生命周期里刷新（桌面端走窗口事件路径）。
      _refreshAutoExitCountdown();
      _exitBackgroundState("应用回到前台");
    } else if (state == AppLifecycleState.inactive) {
      Log.d("应用短暂失焦:$state");
      unawaited(syncAutoPipOnLeave());
    }
  }

  /// 进入「后台」态的统一处理：移动端退到后台（paused/hidden）与桌面端
  /// **窗口最小化**都走这里，由「后台播放」总开关裁决（手动纯音频按其自身
  /// 规则豁免，见 [_allowBackgroundPlayback]）：
  /// - 不允许后台 → 明确暂停并记续播点（回前台续播）
  /// - 允许后台   → 继续播，30 秒后自动停画面只解码声音（回前台自动恢复画面）
  void _enterBackgroundState(String reason) {
    Log.d("进入后台:$reason");
    isBackground = true;
    _backgroundedAt = DateTime.now();
    _positionBeforeBackground = _lastKnownPlayerPosition;
    if (!_allowBackgroundPlayback) {
      unawaited(
        AppSettingsController.instance.saveLastLiveRoom(
          siteId: site.id,
          roomId: roomId,
          resumePending: true,
        ),
      );
      // 明确暂停：不依赖 Video 控件的构建期参数，改设置后当次即可生效。
      unawaited(
        player.pause().catchError((Object e) {
          Log.d("退后台暂停失败: $e");
        }),
      );
    } else {
      // 允许后台播放：退后台后自动降级为纯音频，只解码声音、不解码画面。
      _scheduleBackgroundAudioOnlyDowngrade();
    }
    // 无论是否允许后台播放都要停：后台不需要刷新热度/SuperChat/事件流/
    // 开播时长，Surface 检查在纯音频下还会把 width=null 误判成异常。
    _suspendBackgroundTimers();
  }

  /// 回到「前台」态的统一处理（移动端 resumed / 桌面端窗口从最小化恢复）。
  void _exitBackgroundState(String reason) {
    Log.d("返回前台:$reason");
    isBackground = false;
    _resumeBackgroundTimers();
    unawaited(
      AppSettingsController.instance.setLastLiveRoomResumePending(false),
    );
    _refreshDanmakuOverlay("返回前台");
    var backgroundedAt = _backgroundedAt;
    var positionBeforeBackground = _positionBeforeBackground;
    _backgroundedAt = null;
    _positionBeforeBackground = null;
    unawaited(
      _handleForegroundRestore(
        since: backgroundedAt,
        previousPosition: positionBeforeBackground,
      ),
    );
  }

  Future<void> _recoverPlaybackAfterForeground(
    String reason, {
    required DateTime? since,
    required Duration? previousPosition,
  }) async {
    final loadGeneration = _loadGeneration;
    if (since == null ||
        previousPosition == null ||
        !liveStatus.value ||
        currentLineIndex < 0 ||
        playUrls.isEmpty) {
      return;
    }
    if (DateTime.now().difference(since) < const Duration(seconds: 3)) {
      return;
    }
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!_isCurrentLoad(loadGeneration) || isBackground) {
      return;
    }
    var currentPosition = _lastKnownPlayerPosition;
    var stalled = currentPosition <= previousPosition ||
        player.state.buffering ||
        player.state.completed ||
        !player.state.playing;
    if (!stalled) {
      return;
    }
    if (!_isCurrentLoad(loadGeneration)) {
      return;
    }
    Log.d("$reason 后检测到播放停滞，尝试恢复");
    await setPlayer(refreshUrls: _shouldRefreshUrlsOnPlaybackRetry);
  }

  /// 返回前台：先撤销后台降级（恢复画面），没重开流再走原有的停滞恢复逻辑。
  Future<void> _handleForegroundRestore({
    required DateTime? since,
    required Duration? previousPosition,
  }) async {
    if (await _restoreFromBackgroundAudioOnly()) {
      return;
    }
    await _recoverPlaybackAfterForeground(
      "返回前台",
      since: since,
      previousPosition: previousPosition,
    );
  }

  /// 退到后台超过阈值后自动停掉视频轨（只留声音，省电）。
  ///
  /// 视频轨，返回前台时由 _handleForegroundRestore →
  /// _restoreFromBackgroundAudioOnly 自动恢复画面，无需用户干预。
  ///
  /// 注：桌面端「退后台」表现为窗口失焦，切到别的窗口同样会进入该流程，
  /// 回来时自动恢复（重开流，中断约 1 秒）。这是与移动端对齐后的预期行为。
  void _scheduleBackgroundAudioOnlyDowngrade() {
    _backgroundDowngradeTimer?.cancel();
    // 手动纯音频已经停过轨，无需后台再降一次。
    if (_backgroundAudioOnly || _videoTrackDisabled) {
      return;
    }
    _backgroundDowngradeTimer = Timer(const Duration(seconds: 30), () async {
      if (!isBackground || _backgroundAudioOnly) {
        return;
      }
      _backgroundAudioOnly = true;
      // 降档要重开流，会中断 1~2 秒声音。WiFi/有线流量不值钱，不值得为此打断听感；
      // 只有移动数据才降档省流量。停轨（省电）与网络类型无关，始终执行。
      final downgrade = await _isMobileNetwork();
      Log.d(
        "后台超过 30 秒，自动降级为纯音频（停视频轨，只解码声音）"
        "${downgrade ? " + 移动网络，降最低清晰度省流量" : "，非移动网络，不降档"}",
      );
      await _enterAudioOnly(reason: "后台自动降级", downgrade: downgrade);
    });
  }

  /// 当前是否为移动数据网络。用于判断「值不值得为省流量重开流」：
  /// 降档会中断 1~2 秒声音，WiFi/有线网络下这点流量收益远小于打断的损失。
  /// 取不到网络类型时按非移动网络处理——宁可不省流量，也不打断播放。
  Future<bool> _isMobileNetwork() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return false;
    }
    try {
      final result = await Connectivity().checkConnectivity();
      // 7.x 返回 List（可能同时有多种连接）；只要含移动数据就算移动网络。
      return result.contains(ConnectivityResult.mobile) &&
          !result.contains(ConnectivityResult.wifi);
    } catch (e) {
      Log.d("获取网络类型失败: $e，按非移动网络处理（不降档）");
      return false;
    }
  }

  /// 进入纯音频：停视频轨（省解码/渲染）+ 可选降到最低清晰度（省流量）。
  /// 顺序很关键：先停轨（立刻生效，不等网络），再降档；降档会重开流、
  /// 播放器重建后 vid 被重置，所以降档成功必须补停一次轨。
  /// [downgrade] = false 时只停轨不换清晰度（WiFi 下后台降级用，避免打断听感）。
  Future<void> _enterAudioOnly({
    required String reason,
    bool downgrade = true,
  }) async {
    _videoTrackDisabled = true;
    await setAudioOnlyMode(true);
    if (!downgrade || _roomDisposed) {
      return;
    }
    // 站点能直接给纯音频流（B站）→ 优先用它：流里没有视频轨，
    // 比"降到最低清晰度"再省 60~70% 流量，且播放器完全不做视频解码。
    // 取不到才回退到降清晰度。
    if (await _switchToAudioOnlyStream(reason: reason)) {
      if (!_roomDisposed) {
        await setAudioOnlyMode(true);
      }
      return;
    }
    final switched = await _downgradeQualityForAudioOnly(reason: reason);
    if (switched && !_roomDisposed) {
      await setAudioOnlyMode(true);
    }
  }

  /// 切到站点提供的「真·纯音频流」（目前仅 B 站支持，实测 192~448 kbps）。
  /// 返回 true 表示已换流；取不到/失败一律返回 false，由调用方回退到降清晰度。
  Future<bool> _switchToAudioOnlyStream({required String reason}) async {
    if (!site.liveSite.supportsAudioOnlyStream || _usingAudioOnlyStream) {
      return false;
    }
    final roomDetail = detail.value;
    if (roomDetail == null || _roomDisposed) {
      return false;
    }
    final loadGeneration = _loadGeneration;
    // 换流会重开：VOD 会从头播，先记住进度稍后 seek 回去。
    final resumeAt = isVod ? player.state.position : Duration.zero;
    LivePlayUrl? playUrl;
    try {
      playUrl = await site.liveSite.getAudioOnlyPlayUrls(detail: roomDetail);
    } catch (e) {
      Log.d("$reason：取纯音频流异常，回退降清晰度: $e");
      return false;
    }
    if (playUrl == null ||
        playUrl.urls.isEmpty ||
        !_isCurrentLoad(loadGeneration) ||
        _roomDisposed) {
      return false;
    }
    _usingAudioOnlyStream = true;
    playUrls.value = playUrl.urls;
    playHeaders = playUrl.headers;
    currentLineIndex = 0;
    currentLineInfo.value = "线路1";
    await initPlaylist();
    if (!_isCurrentLoad(loadGeneration)) {
      return true;
    }
    if (resumeAt > Duration.zero) {
      await _seekAfterQualitySwitch(resumeAt);
    }
    Log.d("$reason：已切到纯音频流（${playUrl.urls.length} 条线路，无视频轨）");
    return true;
  }

  /// 纯音频期间把清晰度降到最低档。直播是单路交织流，音视频无法分离，
  /// 唯一能省流量的办法就是换成码率更低的那条流。
  /// 返回 true 表示已重开流。
  Future<bool> _downgradeQualityForAudioOnly({required String reason}) async {
    // 清晰度列表按「高 → 低」排列（index 0 = 最高，末位 = 最低）。
    if (qualites.length <= 1 || currentQuality < 0) {
      return false;
    }
    final lowest = qualites.length - 1;
    if (currentQuality == lowest) {
      return false;
    }
    final previous = currentQuality;
    final previousInfo = currentQualityInfo.value;
    // 降档会重开流：VOD 会从头播，先记住进度稍后 seek 回去。
    final resumeAt = isVod ? player.state.position : Duration.zero;
    final loadGeneration = _loadGeneration;
    _qualityBeforeAudioOnly = previous;
    currentQuality = lowest;
    // 先解析新地址：失败就回滚，旧流继续播、声音不中断（后台尤其不能断）。
    final reloaded = await _reloadPlayUrls(resetLine: true, silent: true);
    if (!reloaded || !_isCurrentLoad(loadGeneration)) {
      _qualityBeforeAudioOnly = -1;
      currentQuality = previous;
      currentQualityInfo.value = previousInfo;
      return false;
    }
    await initPlaylist();
    if (!_isCurrentLoad(loadGeneration)) {
      return true;
    }
    if (resumeAt > Duration.zero) {
      await _seekAfterQualitySwitch(resumeAt);
    }
    Log.d("$reason：清晰度降到最低档（${qualites[lowest].quality}），省流量");
    return true;
  }

  /// 切清晰度后 VOD 会从头播，seek 回切档前的进度。
  /// mpv 刚 open 时 duration 可能还是 0，此时 seek 无效，需等一等再试。
  Future<void> _seekAfterQualitySwitch(Duration target) async {
    for (var i = 0; i < 3; i++) {
      try {
        if (player.state.duration > Duration.zero || i == 2) {
          await player.seek(target);
          return;
        }
      } catch (e) {
        Log.d("切清晰度后恢复进度失败: $e");
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// 恢复视频轨 + 还原纯音频期间降过的清晰度。
  /// 返回 true 表示已重开流，调用方无需再走停滞恢复逻辑。
  Future<bool> _restoreVideoTrack() async {
    if (!_videoTrackDisabled) {
      return false;
    }
    _videoTrackDisabled = false;
    await setAudioOnlyMode(false);
    // 之前切过站点纯音频流 → playUrls 现在是音频流，必须解析回正常流才有画面。
    if (_usingAudioOnlyStream) {
      _usingAudioOnlyStream = false;
      // 音频流与清晰度无关，但「进房即为纯音频」时清晰度被压到了最低档；
      // 切回正常流前要把原档位还原，否则用户的画质设置会被悄悄留在最低档。
      final pendingQuality = _qualityBeforeAudioOnly;
      _qualityBeforeAudioOnly = -1;
      if (pendingQuality >= 0 &&
          pendingQuality < qualites.length &&
          pendingQuality != currentQuality) {
        currentQuality = pendingQuality;
      }
      final loadGeneration = _loadGeneration;
      final resumeAt = isVod ? player.state.position : Duration.zero;
      final reloaded = await _reloadPlayUrls(resetLine: true, silent: true);
      if (reloaded && _isCurrentLoad(loadGeneration)) {
        await initPlaylist();
        if (_isCurrentLoad(loadGeneration)) {
          if (resumeAt > Duration.zero) {
            await _seekAfterQualitySwitch(resumeAt);
          }
          Log.d("退出纯音频：已切回正常视频流"
              "${pendingQuality >= 0 ? "，画质还原为 ${qualites[currentQuality].quality}" : ""}");
        }
        // 已经重开过流，画面随之恢复，无需再走下面的直播重开分支。
        return true;
      }
      // 切回失败：交给下面的逻辑兜底（直播仍需重开流出画面）。
      Log.d("退出纯音频：切回正常流失败，走兜底重开");
    }
    // 纯音频期间降过清晰度 → 切回原档（会重开流，vid 已先恢复为 auto）。
    final restore = _qualityBeforeAudioOnly;
    _qualityBeforeAudioOnly = -1;
    if (restore >= 0 &&
        restore < qualites.length &&
        restore != currentQuality &&
        _isCurrentLoad(_loadGeneration)) {
      final previous = currentQuality;
      final previousInfo = currentQualityInfo.value;
      final resumeAt = isVod ? player.state.position : Duration.zero;
      final loadGeneration = _loadGeneration;
      currentQuality = restore;
      final reloaded = await _reloadPlayUrls(resetLine: true, silent: true);
      if (reloaded && _isCurrentLoad(loadGeneration)) {
        await initPlaylist();
        if (_isCurrentLoad(loadGeneration)) {
          if (resumeAt > Duration.zero) {
            await _seekAfterQualitySwitch(resumeAt);
          }
          Log.d("退出纯音频：清晰度还原为 ${qualites[restore].quality}");
        }
        // 已经重开过流，画面随之恢复，无需再走下面的直播重开分支。
        return true;
      }
      // 还原失败：回滚清晰度，交给下面的逻辑兜底（直播仍需重开流出画面）。
      currentQuality = previous;
      currentQualityInfo.value = previousInfo;
    }
    if (!isVod && _isCurrentLoad(_loadGeneration)) {
      await setPlayer(refreshUrls: false);
      return true;
    }
    return false;
  }

  /// 恢复后台降级的视频轨。返回 true 表示已重新开流，无需再走停滞恢复。
  Future<bool> _restoreFromBackgroundAudioOnly() async {
    _backgroundDowngradeTimer?.cancel();
    if (!_backgroundAudioOnly) {
      return false;
    }
    _backgroundAudioOnly = false;
    // 用户手动开着纯音频 → 保持停轨，画面继续由占位层遮住（关掉时再恢复，见 _restoreVideoTrack）。
    if (AppSettingsController.instance.audioOnlyBackground.value) {
      return false;
    }
    Log.d("返回前台，恢复视频轨");
    return _restoreVideoTrack();
  }

  @override
  void onWindowBlur() {
    clearTransientPlayerOverlays();
    _windowBlurredAt = DateTime.now();
    _positionBeforeWindowBlur = _lastKnownPlayerPosition;
  }

  @override
  void onWindowMinimize() {
    // 桌面端「退后台」= 窗口最小化，与移动端对齐后同样由「后台播放」总开关
    // 裁决。单纯失焦（切到别的窗口）不算后台：桌面多窗口是常态，边看边干活
    // 不该被暂停或降级。桌面小窗是主窗口缩小置顶，只要没最小化就照常播放。
    _windowMinimized = true;
    if (isBackground) {
      return;
    }
    _enterBackgroundState("窗口最小化");
  }

  @override
  void onWindowRestore() {
    if (!_windowMinimized) {
      return;
    }
    _windowMinimized = false;
    _exitBackgroundState("窗口从最小化恢复");
  }

  @override
  void onWindowFocus() {
    var windowBlurredAt = _windowBlurredAt;
    var positionBeforeWindowBlur = _positionBeforeWindowBlur;
    _windowBlurredAt = null;
    _positionBeforeWindowBlur = null;
    _refreshDanmakuOverlay("窗口重新聚焦");
    unawaited(
      _recoverPlaybackAfterForeground(
        "窗口重新聚焦",
        since: windowBlurredAt,
        previousPosition: positionBeforeWindowBlur,
      ),
    );
  }

  // 启动并更新开播时长计时器
  void startLiveDurationTimer() {
    // 非开播状态，或没有 showTime 时，不启动计时器。
    if (!(detail.value?.status ?? false) || detail.value?.showTime == null) {
      liveDuration.value = "00:00:00"; // 未开播时显示 00:00:00
      _liveDurationTimer?.cancel();
      return;
    }

    try {
      int startTimeStamp = int.parse(detail.value!.showTime!);
      // 先取消旧计时器，再启动新的。
      _liveDurationTimer?.cancel();
      _liveDurationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        liveDuration.value = formattedDuration;
      });
    } catch (e) {
      liveDuration.value = "--:--:--"; // 解析失败时显示占位值
    }
  }

  // ignore: unused_element
  void _legacyOnClose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isWindows) {
      windowManager.removeListener(this);
    }
    scrollController.removeListener(scrollListener);
    _cancelAutoExitTimers();
    _positionSubscription?.cancel();

    liveDanmaku.stop();
    danmakuController = null;
    _liveDurationTimer?.cancel(); // 页面关闭时取消计时器
    super.onClose();
  }
}
