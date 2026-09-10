import 'package:simple_live_core/src/model/live_anchor_item.dart';

import '../interface/live_danmaku.dart';
import '../model/live_category_result.dart';
import '../model/live_contribution_rank.dart';
import '../model/live_message.dart';
import '../model/live_play_url.dart';
import '../model/live_room_detail.dart';
import '../model/live_room_online_info.dart';
import '../model/live_search_result.dart';

import '../model/live_category.dart';
import '../model/live_play_quality.dart';
import '../model/live_room_item.dart';

class LiveSite {
  /// 站点唯一ID
  String id = "";

  /// 站点名称
  String name = "";

  /// 站点名称
  LiveDanmaku getDanmaku() => LiveDanmaku();

  /// 读取网站的分类
  Future<List<LiveCategory>> getCategores() {
    return Future.value(<LiveCategory>[]);
  }

  /// 搜索直播间
  Future<LiveSearchRoomResult> searchRooms(String keyword, {int page = 1}) {
    return Future.value(
      LiveSearchRoomResult(hasMore: false, items: <LiveRoomItem>[]),
    );
  }

  /// 搜索直播间
  Future<LiveSearchAnchorResult> searchAnchors(String keyword, {int page = 1}) {
    return Future.value(
      LiveSearchAnchorResult(hasMore: false, items: <LiveAnchorItem>[]),
    );
  }

  /// 读取类目下房间
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) {
    return Future.value(
      LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]),
    );
  }

  /// 读取推荐的房间
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) {
    return Future.value(
      LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]),
    );
  }

  /// 读取房间详情
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) {
    return Future.value(
      LiveRoomDetail(
        cover: '',
        online: 0,
        roomId: '',
        status: false,
        title: '',
        url: '',
        userAvatar: '',
        userName: '',
      ),
    );
  }

  /// 轻量在线信息（在线人数 + 在播状态），**不取弹幕 token、不取标题封面**。
  ///
  /// 直播间每 10 秒的在线刷新应当走这里，而不是 [getRoomDetail]：后者在有
  /// 弹幕 token 的平台（B站）会顺带请求 getDanmuInfo，而 B站 的 getInfoByRoom
  /// 与 getDanmuInfo 都在 WBI 接口族里 —— 10 秒 × 多端叠加会把 IP 维度风控
  /// 推成「真人验证」，验证后也因请求持续而无法恢复（弹幕一起挂）。
  ///
  /// 返回 `null` = 该站点未实现轻量接口，调用方**回退到 [getRoomDetail]**。
  Future<LiveRoomOnlineInfo?> getRoomOnlineInfo({required String roomId}) async {
    return null;
  }

  /// 读取房间清晰度
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) {
    return Future.value(<LivePlayQuality>[]);
  }

  /// 读取播放链接
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) {
    return Future.value(LivePlayUrl(urls: []));
  }

  /// 是否支持「真·纯音频流」——服务端能直接返回一条不含视频轨的流。
  /// 默认 false：多数直播是单路音视频交织流（HTTP-FLV / TS），客户端无法只拉音频，
  /// 只能下载后丢弃视频数据，也就省不了流量。
  bool get supportsAudioOnlyStream => false;

  /// 读取纯音频流（流中不含视频轨）。
  /// 返回 null 表示取不到，调用方应回退到「停视频轨 + 降最低清晰度」。
  Future<LivePlayUrl?> getAudioOnlyPlayUrls({
    required LiveRoomDetail detail,
  }) {
    return Future.value(null);
  }

  /// 查询直播状态
  Future<bool> getLiveStatus({required String roomId}) {
    return Future.value(false);
  }

  /// 读取指定房间的SC
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
    LiveRoomDetail? detail,
  }) {
    return Future.value([]);
  }

  /// 读取指定房间的贡献榜
  Future<List<LiveContributionRankItem>> getContributionRank({
    required String roomId,
    LiveRoomDetail? detail,
  }) {
    return Future.value([]);
  }
}
