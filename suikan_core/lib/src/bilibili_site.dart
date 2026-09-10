import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:simple_live_core/src/common/convert_helper.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/danmaku/bilibili_danmaku.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/interface/live_site.dart';
import 'package:simple_live_core/src/model/live_anchor_item.dart';
import 'package:simple_live_core/src/model/live_category.dart';
import 'package:simple_live_core/src/model/live_contribution_rank.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/model/live_room_item.dart';
import 'package:simple_live_core/src/model/live_search_result.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';
import 'package:simple_live_core/src/model/live_room_online_info.dart';
import 'package:simple_live_core/src/model/live_play_quality.dart';
import 'package:simple_live_core/src/model/live_category_result.dart';

class BiliBiliSite implements LiveSite {
  @override
  String id = "bilibili";

  @override
  String name = "哔哩哔哩直播";

  String cookie = "";
  int userId = 0;

  @override
  LiveDanmaku getDanmaku() => BiliBiliDanmaku();

  static const String kDefaultUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0";
  static const String kDefaultReferer = "https://live.bilibili.com/";

  String buvid3 = "";
  String buvid4 = "";
  String accessId = "";

  /// bili_ticket(设备凭证,JWT,约 3 天 TTL):2024+ 官方安全机制,携带可降低
  /// 触发风控/自动验证几率(见 bilibili-API-collect sign/bili_ticket.md)。
  /// 会话内缓存,提前到 48h 刷新;获取失败 1 小时内不重试(避免连环请求)。
  String biliTicket = "";
  DateTime _biliTicketFetchedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _biliTicketLastAttemptAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _biliTicketTtl = Duration(hours: 48);
  static const Duration _biliTicketRetryCooldown = Duration(hours: 1);

  /// 获取/刷新 bili_ticket;响应同时带回最新 WBI key(nav.img/sub),
  /// 顺手保鲜 kImgKey/kSubKey(与 wbi TTL 双保险)。
  Future<void> _ensureBiliTicket() async {
    final now = DateTime.now();
    final need = biliTicket.isEmpty ||
        now.difference(_biliTicketFetchedAt) >= _biliTicketTtl;
    if (!need ||
        now.difference(_biliTicketLastAttemptAt) <
            _biliTicketRetryCooldown) {
      return;
    }
    _biliTicketLastAttemptAt = now;
    try {
      final ts = (now.millisecondsSinceEpoch ~/ 1000).toString();
      final hexsign =
          Hmac(sha256, utf8.encode("XgwSnGZ1p")).convert(utf8.encode("ts$ts"));
      final resp = await HttpClient.instance.postJson(
        "https://api.bilibili.com/bapis/bilibili.api.ticket.v1.Ticket/"
        "GenWebTicket",
        queryParameters: {
          "key_id": "ec02",
          "hexsign": hexsign.toString(),
          "context[ts]": ts,
        },
        header: await getHeader(includeTicket: false),
      );
      if (resp is! Map) {
        return;
      }
      final data = resp["data"];
      if (data is Map) {
        final ticket = data["ticket"]?.toString() ?? "";
        if (ticket.isNotEmpty) {
          biliTicket = ticket;
          _biliTicketFetchedAt = now;
        }
        // nav 返回的最新 WBI key(可选保鲜,失败不影响 ticket 使用)
        final nav = data["nav"];
        if (nav is Map) {
          final imgUrl = nav["img"]?.toString() ?? "";
          final subUrl = nav["sub"]?.toString() ?? "";
          if (imgUrl.contains('/') && subUrl.contains('/')) {
            final imgKey =
                imgUrl.substring(imgUrl.lastIndexOf('/') + 1).split('.').first;
            final subKey =
                subUrl.substring(subUrl.lastIndexOf('/') + 1).split('.').first;
            if (imgKey.isNotEmpty && subKey.isNotEmpty) {
              kImgKey = imgKey;
              kSubKey = subKey;
              _wbiKeysFetchedAt = now;
            }
          }
        }
      }
    } catch (e) {
      CoreLog.w("bili_ticket 获取失败(不影响请求): $e");
    }
  }

  static Future<void> _playInfoRequestQueue = Future.value();
  static DateTime _lastPlayInfoRequestAt = DateTime.fromMillisecondsSinceEpoch(
    0,
  );

  Future<Map<String, String>> getHeader({bool includeTicket = true}) async {
    if (includeTicket) {
      await _ensureBiliTicket();
    }
    if (buvid3.isEmpty) {
      var buvidInfo = await getBuvid();
      buvid3 = buvidInfo["b_3"] ?? "";
      buvid4 = buvidInfo["b_4"] ?? "";
    }
    // bili_ticket 与 buvid 一起作为设备凭证;buvid3/4 一旦生成保持稳定,
    // 不因风控反复更换(高频换指纹=更强风控信号,会升级到真人验证)。
    final baseCookie = cookie.isEmpty
        ? 'buvid3=$buvid3;buvid4=$buvid4;'
        : cookie.contains("buvid3")
            ? cookie
            : "$cookie;buvid3=$buvid3;buvid4=$buvid4;";
    final finalCookie = includeTicket && biliTicket.isNotEmpty
        ? '$baseCookie;bili_ticket=$biliTicket;'
        : baseCookie;
    return cookie.isEmpty
        ? {
            "user-agent": kDefaultUserAgent,
            "referer": kDefaultReferer,
            "cookie": finalCookie,
          }
        : {
            "cookie": finalCookie,
            "user-agent": kDefaultUserAgent,
            "referer": kDefaultReferer,
          };
  }

  @override
  Future<List<LiveCategory>> getCategores() async {
    List<LiveCategory> categories = [];
    var result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/room/v1/Area/getList",
      queryParameters: {"need_entrance": 1, "parent_id": 0},
      header: await getHeader(),
    );
    for (var item in result["data"]) {
      List<LiveSubCategory> subs = [];
      for (var subItem in item["list"]) {
        var subCategory = LiveSubCategory(
          id: subItem["id"].toString(),
          name: asT<String?>(subItem["name"]) ?? "",
          parentId: asT<String?>(subItem["parent_id"]) ?? "",
          pic: "${asT<String?>(subItem["pic"]) ?? ""}@100w.png",
        );
        subs.add(subCategory);
      }
      var category = LiveCategory(
        children: subs,
        id: item["id"].toString(),
        name: asT<String?>(item["name"]) ?? "",
      );
      categories.add(category);
    }
    return categories;
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) async {
    var result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/room/v1/Area/getRoomList",
      queryParameters: {
        "platform": "web",
        "parent_area_id": category.parentId,
        "area_id": category.id,
        "page": page,
        "page_size": 30,
      },
      header: await getHeader(),
    );

    var data = (result["data"] as List?) ?? const [];
    var hasMore = data.length >= 30;
    var items = <LiveRoomItem>[];
    for (var item in data) {
      var cover =
          item["cover"]?.toString() ??
          item["user_cover"]?.toString() ??
          item["system_cover"]?.toString() ??
          "";
      var roomItem = LiveRoomItem(
        roomId: item["roomid"].toString(),
        title: item["title"].toString(),
        cover: cover.isEmpty ? "" : "$cover@400w.jpg",
        userName: item["uname"].toString(),
        online: int.tryParse(item["online"].toString()) ?? 0,
      );
      items.add(roomItem);
    }
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    final qualities = <LivePlayQuality>[];
    var result = await _getRoomPlayInfo(
      queryParameters: {
        "room_id": detail.roomId,
        "protocol": "0,1",
        "format": "0,1,2",
        "codec": "0,1",
        "platform": "web",
      },
    );
    final playUrl = _readBilibiliPlayUrl(result, detail.roomId);
    var qualitiesMap = <int, String>{};
    for (var item in (playUrl["g_qn_desc"] as List?) ?? const []) {
      qualitiesMap[int.tryParse(item["qn"].toString()) ?? 0] = item["desc"]
          .toString();
    }

    final streams = (playUrl["stream"] as List?) ?? const [];
    final formats = streams.isEmpty
        ? const []
        : (streams.first["format"] as List?) ?? const [];
    final codecs = formats.isEmpty
        ? const []
        : (formats.first["codec"] as List?) ?? const [];
    final accepted = codecs.isEmpty
        ? const []
        : (codecs.first["accept_qn"] as List?) ?? const [];
    for (var item in accepted) {
      var qualityItem = LivePlayQuality(
        quality: qualitiesMap[item] ?? "未知清晰度",
        data: item,
      );
      qualities.add(qualityItem);
    }
    if (qualities.isEmpty) {
      CoreLog.w("B站播放信息未返回清晰度：roomId=${detail.roomId}");
      throw CoreError("B站暂时无法获取播放清晰度，请稍后重试");
    }
    return qualities;
  }

  Map _readBilibiliPlayUrl(dynamic result, String roomId) {
    try {
      final data = result is Map ? result["data"] : null;
      final playUrlInfo = data is Map ? data["playurl_info"] : null;
      final playUrl = playUrlInfo is Map ? playUrlInfo["playurl"] : null;
      if (playUrl is Map) {
        return playUrl;
      }
    } catch (_) {
      // The structured error below is more useful than a type-cast exception.
    }
    CoreLog.w(
      "B站播放信息响应结构异常：roomId=$roomId "
      "responseType=${result.runtimeType}",
    );
    throw CoreError("B站播放信息响应异常，请稍后重试");
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    List<String> urls = [];
    var result = await _getRoomPlayInfo(
      queryParameters: {
        "room_id": detail.roomId,
        "protocol": "0,1",
        "format": "0,2",
        "codec": "0",
        "platform": "web",
        "qn": quality.data,
      },
    );
    var streamList = result["data"]["playurl_info"]["playurl"]["stream"];
    for (var streamItem in streamList) {
      var formatList = streamItem["format"];
      for (var formatItem in formatList) {
        var codecList = formatItem["codec"];
        for (var codecItem in codecList) {
          var urlList = codecItem["url_info"];
          var baseUrl = codecItem["base_url"].toString();
          for (var urlItem in urlList) {
            urls.add("${urlItem["host"]}$baseUrl${urlItem["extra"]}");
          }
        }
      }
    }
    // 对链接进行排序，包含mcdn的在后
    urls.sort((a, b) {
      if (a.contains("mcdn")) {
        return 1;
      } else {
        return -1;
      }
    });
    return LivePlayUrl(
      urls: urls,
      headers: {
        "referer": "https://live.bilibili.com",
        "user-agent":
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36 Edg/115.0.1901.188",
      },
    );
  }

  /// 纯音频流走移动端接口：带 only_audio=1 会返回一条**不含视频轨**的 FLV 流。
  /// 实测 12 个直播间全部成功，码率约 192~448 kbps，比"降到最低清晰度"再省 60~70%，
  /// 且流里没有视频、播放器无需解码视频。
  static const String kAndroidUserAgent =
      "Mozilla/5.0 (Linux; Android 12; VTR-AL00 Build/HUAWEIVTR-AL00) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

  @override
  bool get supportsAudioOnlyStream => true;

  @override
  Future<LivePlayUrl?> getAudioOnlyPlayUrls({
    required LiveRoomDetail detail,
  }) async {
    try {
      final result = await _getAudioOnlyPlayInfo(roomId: detail.roomId);
      final data = result["data"] as Map?;
      if (data == null || data["live_status"] != 1) {
        return null;
      }
      final urls = <String>[];
      final streamList =
          (data["playurl_info"]?["playurl"]?["stream"] as List?) ?? const [];
      for (var streamItem in streamList) {
        final formatList = (streamItem["format"] as List?) ?? const [];
        for (var formatItem in formatList) {
          // 只要 flv：fmp4/hls 线路在纯音频下没必要，且部分节点不稳。
          if (formatItem["format_name"] != "flv") {
            continue;
          }
          final codecList = (formatItem["codec"] as List?) ?? const [];
          for (var codecItem in codecList) {
            final baseUrl = codecItem["base_url"].toString();
            final urlList = (codecItem["url_info"] as List?) ?? const [];
            for (var urlItem in urlList) {
              urls.add("${urlItem["host"]}$baseUrl${urlItem["extra"]}");
            }
          }
        }
      }
      if (urls.isEmpty) {
        CoreLog.w("B站纯音频流为空：roomId=${detail.roomId}");
        return null;
      }
      return LivePlayUrl(
        urls: urls,
        headers: {"user-agent": kAndroidUserAgent},
      );
    } catch (e) {
      CoreLog.w("B站纯音频流获取失败，调用方将回退到降清晰度：roomId="
          "${detail.roomId} error=$e");
      return null;
    }
  }

  /// 移动端播放信息接口。注意两点与 web 接口不同：
  /// - 不能带 web 的 Referer（带上反而异常）；
  /// - 返回的流地址是 http，https 实测拉不动（app 已开 usesCleartextTraffic）。
  Future<dynamic> _getAudioOnlyPlayInfo({required String roomId}) {
    return HttpClient.instance.getJson(
      "https://api.live.bilibili.com/xlive/app-room/v2/index/getRoomPlayInfo",
      queryParameters: {
        "appkey": "iVGUTjsxvpLeuDCf",
        "build": "6215200",
        "c_locale": "zh_CN",
        "s_locale": "zh_CN",
        "channel": "bili",
        "mobi_app": "android",
        "device": "android",
        "device_name": "VTR-AL00",
        "platform": "android",
        "codec": "0",
        "dolby": "1",
        "format": "0,2",
        "free_type": "0",
        "http": "1",
        "mask": "0",
        "network": "wifi",
        "no_playurl": "0",
        "only_audio": "1",
        "only_video": "0",
        "play_type": "0",
        "protocol": "0,1",
        "qn": "10000",
        "room_id": roomId,
        "ts": DateTime.now().millisecondsSinceEpoch ~/ 1000,
        "statistics":
            '{"appId":1,"platform":3,"version":"6.21.5","abtest":""}',
      },
      header: {
        "user-agent": kAndroidUserAgent,
      },
    );
  }

  Future<dynamic> _getRoomPlayInfo({
    required Map<String, dynamic> queryParameters,
  }) async {
    const retryDelays = [
      Duration(milliseconds: 800),
      Duration(milliseconds: 1600),
    ];
    for (var attempt = 0; attempt <= retryDelays.length; attempt++) {
      try {
        return await _throttlePlayInfoRequest(
          () async => HttpClient.instance.getJson(
            "https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo",
            queryParameters: queryParameters,
            header: await getHeader(),
          ),
        );
      } catch (e) {
        if (e is CoreError &&
            e.statusCode == 429 &&
            attempt < retryDelays.length) {
          final delay = retryDelays[attempt];
          CoreLog.w(
            "B站播放信息接口触发 429，${delay.inMilliseconds}ms 后重试："
            "roomId=${queryParameters["room_id"]} attempt=${attempt + 1}",
          );
          await Future.delayed(delay);
          continue;
        }
        CoreLog.w(
          "B站播放信息获取失败：roomId=${queryParameters["room_id"]} "
          "attempt=${attempt + 1}/${retryDelays.length + 1} error=$e",
        );
        rethrow;
      }
    }
    throw CoreError("B站播放信息接口重试失败");
  }

  Future<T> _throttlePlayInfoRequest<T>(Future<T> Function() action) {
    final task = _playInfoRequestQueue.catchError((_) {}).then((_) async {
      const minInterval = Duration(milliseconds: 450);
      final elapsed = DateTime.now().difference(_lastPlayInfoRequestAt);
      if (elapsed < minInterval) {
        await Future.delayed(minInterval - elapsed);
      }
      _lastPlayInfoRequestAt = DateTime.now();
      return action();
    });
    _playInfoRequestQueue = task.then((_) {}, onError: (_) {});
    return task;
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    const baseUrl =
        "https://api.live.bilibili.com/xlive/web-interface/v1/second/getListByArea";
    var url = "$baseUrl?platform=web&sort=online&page_size=30&page=$page";

    var result = await getWbiJson(
      url,
      headers: getHeader,
    );
    final data = result is Map ? result["data"] : null;
    if (data is! Map) {
      return LiveCategoryResult(hasMore: false, items: []);
    }

    var hasMore = ((data["list"] as List?) ?? []).isNotEmpty;
    var items = <LiveRoomItem>[];
    for (var item in (data["list"] as List?) ?? []) {
      var roomItem = LiveRoomItem(
        roomId: item["roomid"].toString(),
        title: item["title"].toString(),
        cover: "${item["cover"]}@400w.jpg",
        userName: item["uname"].toString(),
        online: int.tryParse(item["online"].toString()) ?? 0,
      );
      items.add(roomItem);
    }
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    var roomInfo = await getRoomInfo(roomId: roomId);
    var realRoomId = roomInfo["room_info"]["room_id"].toString();

    const danmuInfoBaseUrl =
        "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo";
    var danmuInfoUrl = "$danmuInfoBaseUrl?id=$realRoomId&type=0&web_location=444.8";
    Map? danmuData;
    List<String> serverHosts = [];
    // ⚠️ 这里**刻意不做缓存**：弹幕 token 是短命凭据，只在建连/重连那一刻有效；
    //    缓存它会让重连拿到过期 token → "凭证无效"。
    //    降低请求量的正确做法是"别让定期刷新来碰这个接口"
    //    （见 live_room_controller 的在线刷新改走轻接口 + 降频），
    //    而不是把凭据存起来复用。
    try {
      var roomDanmakuResult = await getWbiJson(
        danmuInfoUrl,
        headers: getHeader,
        // 风控时不换 buvid:设备指纹(buvid3/4)必须稳定,高频更换会被 B 站
        // 判定为可疑设备,把接口级风控升级成真人验证(网页验证)。key 过期
        // 已由 getWbiJson 内 forceRefresh 重试覆盖;仍失败则放弃本轮,
        // 提示稍后再试/待网页验证解除。
      );

      // B站可能只拦截弹幕信息接口。此接口失败不应阻止进入直播间。
      final data = roomDanmakuResult is Map
          ? roomDanmakuResult["data"]
          : null;
      if (data is Map) {
        danmuData = data;
        final hostListRaw = data["host_list"];
        if (hostListRaw is List) {
          serverHosts = hostListRaw
              .map<String>((e) => e["host"].toString())
              .where((e) => e.isNotEmpty)
              .toList();
        }
      } else {
        CoreLog.w(
          "B站弹幕信息为空：roomId=$realRoomId code=${roomDanmakuResult is Map ? roomDanmakuResult["code"] : "?"} "
          "message=${roomDanmakuResult is Map ? roomDanmakuResult["message"] : "?"}",
        );
      }
    } catch (e) {
      CoreLog.w("B站弹幕信息获取失败：roomId=$realRoomId error=$e");
    }

    //var buvid = await getBuvid();
    String? liveStartTime = roomInfo["room_info"]?["live_start_time"]
        ?.toString();

    // 直播封面:开播且接口带 keyframe(实时关键帧)时优先使用,与虎牙
    // sScreenshot 同一性质;未开播/无 keyframe 回落主播静态封面。
    final roomInfoMap = roomInfo["room_info"] is Map
        ? (roomInfo["room_info"] as Map)
        : <dynamic, dynamic>{};
    final isLiveRoom = (asT<int?>(roomInfoMap["live_status"]) ?? 0) == 1;
    final keyframe = roomInfoMap["keyframe"]?.toString() ?? "";
    final staticCover = roomInfoMap["cover"]?.toString() ?? "";

    return LiveRoomDetail(
      roomId: realRoomId,
      title: roomInfo["room_info"]["title"].toString(),
      cover: isLiveRoom && keyframe.isNotEmpty ? keyframe : staticCover,
      userName: roomInfo["anchor_info"]["base_info"]["uname"].toString(),
      userAvatar: "${roomInfo["anchor_info"]["base_info"]["face"]}@100w.jpg",
      online: asT<int?>(roomInfo["room_info"]["online"]) ?? 0,
      status: (asT<int?>(roomInfo["room_info"]["live_status"]) ?? 0) == 1,
      url: "https://live.bilibili.com/$roomId",
      introduction: roomInfo["room_info"]["description"].toString(),
      notice: "",
      danmakuData: BiliBiliDanmakuArgs(
        roomId: int.tryParse(realRoomId) ?? 0,
        uid: userId,
        token: danmuData?["token"]?.toString() ?? "",
        serverHost: serverHosts.isNotEmpty
            ? serverHosts.first
            : "broadcastlv.chat.bilibili.com",
        buvid: buvid3,
        cookie: cookie,
      ),
      showTime: liveStartTime, // 将 liveStartTime 赋值给 showTime 字段
      categoryId: roomInfo["room_info"]["area_id"]?.toString(),
      categoryName: roomInfo["room_info"]["area_name"]?.toString(),
      categoryParentId: roomInfo["room_info"]["parent_area_id"]?.toString(),
      categoryParentName: roomInfo["room_info"]["parent_area_name"]?.toString(),
    );
  }

  Future<Map<String, dynamic>> getRoomInfo({required String roomId}) async {
    var url =
        "https://api.live.bilibili.com/xlive/web-room/v1/index/getInfoByRoom?room_id=$roomId";
    var result = await getWbiJson(
      url,
      headers: getHeader,
    );
    final data = result is Map ? result["data"] : null;
    if (data is Map) {
      return data as Map<String, dynamic>;
    }
    throw CoreError(
      "B站房间信息响应异常：${result is Map ? result["message"] : "非JSON响应"}",
      statusCode: result is Map && result["code"] is int
          ? result["code"] as int
          : 0,
    );
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    var result = await HttpClient.instance.getJson(
      "https://api.bilibili.com/x/web-interface/search/type?context=&search_type=live&cover_type=user_cover",
      queryParameters: {
        "order": "",
        "keyword": keyword,
        "category_id": "",
        "__refresh__": "",
        "_extra": "",
        "highlight": 0,
        "single_column": 0,
        "page": page,
      },
      header: await getHeader(),
    );

    var items = <LiveRoomItem>[];
    for (var item in result["data"]["result"]["live_room"] ?? []) {
      var title = item["title"].toString();
      //移除title中的<em></em>标签
      title = title.replaceAll(RegExp(r"<.*?em.*?>"), "");
      var roomItem = LiveRoomItem(
        roomId: item["roomid"].toString(),
        title: title,
        cover: "https:${item["cover"]}@400w.jpg",
        userName: item["uname"].toString(),
        online: int.tryParse(item["online"].toString()) ?? 0,
      );
      items.add(roomItem);
    }
    return LiveSearchRoomResult(hasMore: items.length >= 40, items: items);
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    var result = await HttpClient.instance.getJson(
      "https://api.bilibili.com/x/web-interface/search/type?context=&search_type=live_user&cover_type=user_cover",
      queryParameters: {
        "order": "",
        "keyword": keyword,
        "category_id": "",
        "__refresh__": "",
        "_extra": "",
        "highlight": 0,
        "single_column": 0,
        "page": page,
      },
      header: await getHeader(),
    );

    var items = <LiveAnchorItem>[];
    for (var item in result["data"]["result"] ?? []) {
      var uname = item["uname"].toString();
      //移除title中的<em></em>标签
      uname = uname.replaceAll(RegExp(r"<.*?em.*?>"), "");
      var anchorItem = LiveAnchorItem(
        roomId: item["roomid"].toString(),
        avatar: "https:${item["uface"]}@400w.jpg",
        userName: uname,
        liveStatus: item["is_live"],
      );
      items.add(anchorItem);
    }
    return LiveSearchAnchorResult(hasMore: items.length >= 40, items: items);
  }

  /// roomId → 主播 uid 缓存：由 [getLiveStatus] 的 get_info 响应**顺带学到**
  /// （该响应本就带 uid，零额外请求）。有 uid 就能走免 Cookie 的批量状态接口
  /// [getLiveStatusByUids]，把"每个关注一个请求"降为"整批一个请求"。
  final Map<String, String> _roomUidCache = <String, String>{};

  /// 当前已知的 roomId → uid 映射（供上层持久化到本地存储）。
  Map<String, String> get knownRoomUids =>
      Map<String, String>.from(_roomUidCache);

  /// 恢复上层持久化的 roomId → uid 映射（上层启动时调用）。
  void restoreRoomUids(Map<String, String> map) {
    if (map.isEmpty) {
      return;
    }
    _roomUidCache.addAll(map);
  }

  /// 单个 roomId 已学到的 uid（未知返回 null）。
  String? uidOfRoom(String roomId) => _roomUidCache[roomId];

  /// 按 uid **批量**查询直播状态（B站官方免 Cookie 接口，风控最轻）。
  ///
  /// 返回 uid → 是否直播中；按官方建议分片 ≤50 个/请求。
  /// 这是 B站 专属的"治本"优化：30 个关注从 30 个请求降为 1 个请求。
  Future<Map<String, bool>> getLiveStatusByUids(List<String> uids) async {
    final result = <String, bool>{};
    final list = <String>[];
    for (final u in uids) {
      final t = u.trim();
      if (t.isNotEmpty && !list.contains(t)) {
        list.add(t);
      }
    }
    for (var i = 0; i < list.length; i += 50) {
      final end = (i + 50 < list.length) ? i + 50 : list.length;
      final chunk = list.sublist(i, end);
      // 手动拼 query：dio 对 List 参数的编码不保证是重复键形式，
      // 这里明确用官方约定的 `uids%5B%5D=a&uids%5B%5D=b`（实测有效）。
      final query = chunk
          .map((e) => "uids%5B%5D=${Uri.encodeQueryComponent(e)}")
          .join("&");
      final response = await HttpClient.instance.getJson(
        "https://api.live.bilibili.com/room/v1/Room/get_status_info_by_uids?$query",
        header: await getHeader(),
      );
      final data = response is Map ? response["data"] : null;
      if (data is Map) {
        data.forEach((key, value) {
          if (value is! Map) {
            return;
          }
          final uid = value["uid"]?.toString() ?? key.toString();
          result[uid] = (asT<int?>(value["live_status"]) ?? 0) == 1;
        });
      }
    }
    return result;
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    var result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/room/v1/Room/get_info",
      queryParameters: {"room_id": roomId},
      header: await getHeader(),
    );
    final data = result is Map ? result["data"] : null;
    if (data is Map) {
      // 顺带记录主播 uid：下一轮即可用批量接口一次查完所有 B站 关注，
      // 不再"一个关注一个请求"（IP 维度风控压力随之下降）。
      final uid = data["uid"]?.toString() ?? "";
      if (uid.isNotEmpty) {
        _roomUidCache[roomId] = uid;
      }
    }
    final liveStatus = data is Map ? data["live_status"] : null;
    return (asT<int?>(liveStatus) ?? 0) == 1;
  }

  /// 轻量在线信息（在线人数 + 在播状态）：用 `room/v1/Room/get_info`，
  /// **不走 WBI 签名**，所以不会给 B站 的 WBI 风控加码。
  ///
  /// 直播间的 10 秒在线刷新走这里（原来调 [getRoomDetail]，会连带
  /// `getInfoByRoom` + `getDanmuInfo` 两次 WBI 请求 → 多端叠加触发真人验证）。
  @override
  Future<LiveRoomOnlineInfo?> getRoomOnlineInfo({required String roomId}) async {
    final result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/room/v1/Room/get_info",
      queryParameters: {"room_id": roomId},
      header: await getHeader(),
    );
    final data = result is Map ? result["data"] : null;
    if (data is! Map) {
      return null;
    }
    // 顺带记录主播 uid（供关注状态批量接口用），零额外请求。
    final uid = data["uid"]?.toString() ?? "";
    if (uid.isNotEmpty) {
      _roomUidCache[roomId] = uid;
    }
    return LiveRoomOnlineInfo(
      online: asT<int?>(data["online"]) ?? 0,
      live: (asT<int?>(data["live_status"]) ?? 0) == 1,
    );
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
    LiveRoomDetail? detail,
  }) async {
    var result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/av/v1/SuperChat/getMessageList",
      queryParameters: {"room_id": roomId},
      header: await getHeader(),
    );
    List<LiveSuperChatMessage> ls = [];
    for (var item in result["data"]?["list"] ?? []) {
      var message = LiveSuperChatMessage(
        backgroundBottomColor: item["background_bottom_color"].toString(),
        backgroundColor: item["background_color"].toString(),
        endTime: DateTime.fromMillisecondsSinceEpoch(item["end_time"] * 1000),
        face: "${item["user_info"]["face"]}@200w.jpg",
        message: item["message"].toString(),
        price: item["price"],
        startTime: DateTime.fromMillisecondsSinceEpoch(
          item["start_time"] * 1000,
        ),
        userName: item["user_info"]["uname"].toString(),
      );
      ls.add(message);
    }
    return ls;
  }

  @override
  Future<List<LiveContributionRankItem>> getContributionRank({
    required String roomId,
    LiveRoomDetail? detail,
  }) async {
    final roomInfo = await getRoomInfo(roomId: roomId);
    final roomRankItems =
        (roomInfo["room_rank_info"]?["user_rank_entry"]?["user_contribution_rank_entry"]?["item"]
            as List?) ??
        const [];
    if (roomRankItems.isNotEmpty) {
      return roomRankItems.map(_mapContributionRankItem).toList();
    }

    var roomData = roomInfo["room_info"] ?? {};
    var uid = roomData["uid"]?.toString() ?? "";
    var realRoomId = roomData["room_id"]?.toString() ?? roomId;
    if (uid.isEmpty) {
      return [];
    }

    var result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/xlive/general-interface/v1/rank/queryContributionRank",
      queryParameters: {
        "ruid": uid,
        "room_id": realRoomId,
        "page": 1,
        "page_size": 50,
      },
      header: await getHeader(),
    );
    final items = (result["data"]?["item"] as List?) ?? const [];
    return items.map(_mapContributionRankItem).toList();
  }

  LiveContributionRankItem _mapContributionRankItem(dynamic item) {
    final medalInfo = item["medal_info"] ?? item["uinfo"]?["medal"];
    final wealthLevelRaw =
        item["wealth_level"] ?? item["uinfo"]?["wealth"]?["level"];
    final wealthLevel = int.tryParse(wealthLevelRaw?.toString() ?? "");
    final guardLevel = int.tryParse(item["guard_level"].toString()) ?? 0;

    return LiveContributionRankItem(
      rank: int.tryParse(item["rank"].toString()) ?? 0,
      userName:
          item["name"]?.toString() ??
          item["uinfo"]?["base"]?["name"]?.toString() ??
          "",
      avatar:
          item["face"]?.toString() ??
          item["uinfo"]?["base"]?["face"]?.toString() ??
          "",
      scoreText: item["score"]?.toString() ?? "0",
      userLevel: wealthLevel,
      userLevelText: wealthLevel == null || wealthLevel <= 0
          ? null
          : "财富 $wealthLevel",
      fansLevel: int.tryParse(
        (medalInfo?["level"] ?? medalInfo?["medal_level"]).toString(),
      ),
      fansName:
          medalInfo?["name"]?.toString() ??
          medalInfo?["medal_name"]?.toString(),
      scoreDetail: guardLevel > 0 ? "舰队 $guardLevel" : null,
    );
  }

  /// 获取 buvid3 和 buvid4
  /// 返回buvid3和buvid4
  /// ``` json
  /// {
  ///   "b_3": "buvid3",
  ///   "b_4": "buvid4",
  /// }
  /// ```
  Future<Map> getBuvid({bool forceRefresh = false}) async {
    try {
      if (!forceRefresh && cookie.contains("buvid3")) {
        return {
          "b_3": RegExp(r"buvid3=(.*?);").firstMatch(cookie)?.group(1) ?? "",
          "b_4": RegExp(r"buvid4=(.*?);").firstMatch(cookie)?.group(1) ?? "",
        };
      }

      var result = await HttpClient.instance.getJson(
        "https://api.bilibili.com/x/frontend/finger/spi",
        queryParameters: {},
        header: {
          "user-agent": kDefaultUserAgent,
          "referer": kDefaultReferer,
          "cookie": cookie,
        },
      );
      final data = result is Map ? result["data"] : null;
      return {
        "b_3": data is Map ? data["b_3"]?.toString() ?? "" : "",
        "b_4": data is Map ? data["b_4"]?.toString() ?? "" : "",
      };
    } catch (e) {
      return {"b_3": "", "b_4": ""};
    }
  }

  static String kImgKey = '';
  static String kSubKey = '';
  /// WBI 口令(img_key/sub_key)的获取时刻。
  ///
  /// 官方 bilibili-API-collect 说明这两个口令**每日更替**，最佳实践明确要求：
  /// "Rotate WBI keys - Cache for 1-24 hours with automatic refresh"。
  /// 以前这里只判 isNotEmpty，取到一次就用到进程结束 —— TV/桌面端长期不重启
  /// 时口令早已过期，之后所有 WBI 请求都会因签名错误被拒（表现为某天起
  /// B站弹幕/播放信息取不到，重启 App 又好）。
  static DateTime _wbiKeysFetchedAt = DateTime.fromMillisecondsSinceEpoch(0);
  /// 取官方建议区间中段：12 小时刷新一次。
  static const Duration _wbiKeysTtl = Duration(hours: 12);
  /// 最近一次「签名类」强刷密钥的时刻 + 最小间隔。
  /// 密钥可能真的过期（需自愈），但风控误判同样会返回 -352 → 限频强刷，
  /// 避免"key 没坏却反复打 nav"。
  static DateTime _lastWbiSignRefreshAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _wbiSignRefreshCooldown = Duration(minutes: 10);
  /// 最近一次「限频/风控码」时刻（仅用于日志与观察）。
  static DateTime _lastWbiThrottleAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const List<int> mixinKeyEncTab = [
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
    37,
    48,
    7,
    16,
    24,
    55,
    40,
    61,
    26,
    17,
    0,
    1,
    60,
    51,
    30,
    4,
    22,
    25,
    54,
    21,
    56,
    59,
    6,
    63,
    57,
    62,
    11,
    36,
    20,
    34,
    44,
    52,
  ];
  /// 获取 WBI 口令，带 12 小时 TTL。
  ///
  /// [forceRefresh] 用于"签名疑似失效"时强制重取一次再重试请求
  /// （比如接口返回 -352 风控校验失败，可能就是口令过期导致签名不对）。
  ///
  /// 容错（2026-09-05 用户反馈"去网页验证后弹幕才恢复"的根因之一）：
  /// nav 接口被风控/限频时 data.wbi_img 可能缺失或结构异常，此时若把坏 key
  /// 写进缓存，之后 12 小时内所有 wbi 签名全错、永久 -352。
  /// 因此：取 key 失败时**保留旧 key**、不推进计时，并抛可重试异常；
  /// 仅当结构校验通过才更新缓存。
  Future<(String, String)> getWbiKeys({bool forceRefresh = false}) async {
    final withinTtl =
        DateTime.now().difference(_wbiKeysFetchedAt) < _wbiKeysTtl;
    if (!forceRefresh &&
        withinTtl &&
        kImgKey.isNotEmpty &&
        kSubKey.isNotEmpty) {
      return (kImgKey, kSubKey);
    }
    // 获取最新的 img_key 和 sub_key
    var resp = await HttpClient.instance.getJson(
      'https://api.bilibili.com/x/web-interface/nav',
      header: await getHeader(),
    );
    final data = resp is Map ? resp["data"] : null;
    final wbiImg =
        data is Map && data["wbi_img"] is Map ? data["wbi_img"] : null;
    final imgUrl = wbiImg is Map ? wbiImg["img_url"]?.toString() : null;
    final subUrl = wbiImg is Map ? wbiImg["sub_url"]?.toString() : null;
    if (imgUrl == null ||
        subUrl == null ||
        !imgUrl.contains('/') ||
        !subUrl.contains('/')) {
      // 旧 key 仍可用则保留并抛出（调用方决定是否降级重试）；无旧 key 直接抛。
      if (kImgKey.isNotEmpty && kSubKey.isNotEmpty) {
        CoreLog.w("B站WBI密钥获取异常，保留旧 key 等待重试");
        throw CoreError("B站WBI密钥获取异常", statusCode: -352);
      }
      throw CoreError("B站WBI密钥获取失败：nav 响应结构异常");
    }
    var imgKey = imgUrl.substring(imgUrl.lastIndexOf('/') + 1).split('.').first;
    var subKey = subUrl.substring(subUrl.lastIndexOf('/') + 1).split('.').first;
    if (imgKey.isEmpty || subKey.isEmpty) {
      if (kImgKey.isNotEmpty && kSubKey.isNotEmpty) {
        CoreLog.w("B站WBI密钥为空，保留旧 key 等待重试");
        throw CoreError("B站WBI密钥为空", statusCode: -352);
      }
      throw CoreError("B站WBI密钥为空");
    }

    kImgKey = imgKey;
    kSubKey = subKey;
    _wbiKeysFetchedAt = DateTime.now();

    return (imgKey, subKey);
  }

  String getMixinKey(String origin) {
    // 对 imgKey 和 subKey 进行字符顺序打乱编码
    return mixinKeyEncTab.fold("", (s, i) => s + origin[i]).substring(0, 32);
  }

  Future<Map<String, String>> getWbiSign(String url) async {
    var (imgKey, subKey) = await getWbiKeys();

    // 为请求参数进行 wbi 签名
    var mixinKey = getMixinKey(imgKey + subKey);
    var currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    var queryParams = Map<String, String>.from(Uri.parse(url).queryParameters);

    queryParams["wts"] = currentTime.toString(); // 添加 wts 字段

    //按照 key 重排参数
    Map<String, String> map = {};
    var sortedKeys = queryParams.keys.toList()..sort();
    for (var key in sortedKeys) {
      var value = queryParams[key]!;
      // 过滤 value 中的 "!'()*" 字符
      map[key] = value
          .toString()
          .split('')
          .where((c) => "!'()*".contains(c) == false)
          .join('');
    }

    var query = map.keys
        .map((key) => "$key=${Uri.encodeQueryComponent(map[key]!)}")
        .join("&");
    var wbiSign = md5.convert(utf8.encode("$query$mixinKey")).toString();
    queryParams["w_rid"] = wbiSign;
    return queryParams;
  }

  /// 🔴 限频/风控码：请求被拦，**刷新密钥不仅无用而且有害**。
  /// -412 请求被拦截 / -509 超出限制 / -799 请求过于频繁 —— 都是"频率/行为"
  /// 触发的，密钥本身没坏；此时再打一次 nav 取密钥 + 重试同一接口，
  /// 会让 1 个风控请求变成 3 个（原请求 + nav + 重试），把"接口级风控"
  /// 推向"真人验证（去网站验证）"。
  /// 用户实测（2026-09-05 起）：家里四端在同一局域网 = 同一公网 IP，
  /// 请求量在 IP 维度叠加，这类"自愈"会让网页验证更频繁。
  static bool isBiliThrottleCode(int? code) =>
      code == -412 || code == -509 || code == -799;

  /// 签名/密钥类错误码：密钥真的过期或签名错，刷新密钥后重试才**有效**。
  static bool isBiliSignCode(int? code) => code == -352;

  /// 风控/限频类错误码（请求被拦 ≠ 登录失效）。
  static bool isBiliRiskCode(int? code) =>
      isBiliThrottleCode(code) || isBiliSignCode(code);

  /// 带 WBI 签名的 GET 请求 + 分级自愈。
  ///
  /// 2026-09-05 曾把"遇风控就强制刷新密钥并重试"当成万能自愈，但用户实测
  /// **加了它之后网页验证反而更频繁**：因为 -412/-509/-799 是限频类错误，
  /// 密钥没坏，刷新+重试等于把风控请求翻 3 倍（还多打一次账号级 nav 接口）。
  ///
  /// 2026-09-10 改成分级处理：
  /// - 限频/风控类（[isBiliThrottleCode]）：**不刷新、不重试**，原样返回，
  ///   由调用方降级（弹幕/详情为空）；
  /// - 签名类（[isBiliSignCode]，-352）：刷新密钥 + 重试一次才有效，但
  ///   10 分钟内最多强刷一次（风控误判也会返回 -352，防止反复打 nav）。
  ///
  /// [onRisk] 供调用方决定"风控后是否继续"（如弹幕接口失败仅告警不抛错）。
  Future<dynamic> getWbiJson(
    String url, {
    required Future<Map<String, String>> Function() headers,
    bool Function(dynamic result)? isRisk,
    Future<void> Function()? onRisk,
  }) async {
    var queryParams = await getWbiSign(url);
    var result = await HttpClient.instance.getJson(
      url.split('?').first,
      queryParameters: queryParams,
      header: await headers(),
    );

    final int? code = result is Map
        ? (result["code"] is int
            ? result["code"] as int
            : int.tryParse("${result["code"]}"))
        : null;
    final risk = isRisk?.call(result) ?? (result is Map && isBiliRiskCode(code));
    if (risk) {
      final now = DateTime.now();
      // ① 限频/风控类：不刷新密钥、不重试（刷了只会把风控推高）。
      if (isBiliThrottleCode(code)) {
        final sinceLastThrottle = _lastWbiThrottleAt.millisecondsSinceEpoch == 0
            ? null
            : now.difference(_lastWbiThrottleAt).inSeconds;
        _lastWbiThrottleAt = now;
        CoreLog.w(
          "B站限频/风控码 $code：不刷新密钥不重试（避免把接口风控推成真人验证）"
          "${sinceLastThrottle == null ? "" : "，距上次同类 ${sinceLastThrottle}s"}"
          "：${url.split('?').first}",
        );
        if (onRisk != null) {
          await onRisk();
        }
        return result;
      }
      // ② 签名/密钥类：刷新密钥 + 重试一次，但 10 分钟内最多一次。
      if (now.difference(_lastWbiSignRefreshAt) < _wbiSignRefreshCooldown) {
        CoreLog.w(
          "B站签名类错误码 $code，${_wbiSignRefreshCooldown.inMinutes} 分钟内已强刷过密钥，本次不重刷：${url.split('?').first}",
        );
        if (onRisk != null) {
          await onRisk();
        }
        return result;
      }
      _lastWbiSignRefreshAt = now;
      CoreLog.w(
        "B站WBI请求遇签名类错误码 $code，强制刷新密钥重试一次：${url.split('?').first}",
      );
      try {
        // 强制重取密钥（绕过 12h TTL）
        await getWbiKeys(forceRefresh: true);
      } catch (e) {
        CoreLog.w("B站WBI密钥强制刷新失败：$e");
      }
      final retryParams = await getWbiSign(url);
      var retryResult = await HttpClient.instance.getJson(
        url.split('?').first,
        queryParameters: retryParams,
        header: await headers(),
      );
      if (onRisk != null) {
        await onRisk();
      }
      return retryResult;
    }
    return result;
  }

  Future<String> getAccessId() async {
    if (accessId.isNotEmpty) {
      return accessId;
    }

    // 获取 access_id
    var resp = await HttpClient.instance.getText(
      "https://live.bilibili.com/lol",
      queryParameters: {},
      header: await getHeader(),
    );
    var id = RegExp(
      r'"access_id":"(.*?)"',
    ).firstMatch(resp)?.group(1)?.replaceAll("\\", "");
    accessId = id ?? "";
    return accessId;
  }
}
