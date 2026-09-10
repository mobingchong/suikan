import 'dart:convert';
import 'dart:math';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/convert_helper.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/scripts/douyin_sign.dart';

class DouyinSite implements LiveSite {
  @override
  String id = "douyin";

  @override
  String name = "抖音直播";

  @override
  LiveDanmaku getDanmaku() => DouyinDanmaku();

  /// 使用 QQBrowser User-Agent（参考 DouyinLiveRecorder）
  static const String kDefaultUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.5845.97 Safari/537.36 Core/1.116.567.400 QQBrowser/19.7.6764.400";

  static const String kDefaultReferer = "https://live.douyin.com";

  static const String kDefaultAuthority = "live.douyin.com";
  static const Duration _webCookieCacheTtl = Duration(minutes: 5);
  static final Map<String, String> _webCookieCache = <String, String>{};
  static final Map<String, DateTime> _webCookieCacheAt = <String, DateTime>{};

  /// 默认 Cookie - 只需要 ttwid 字段即可获取所有画质（包括蓝光）
  /// 经过测试验证，LOGIN_STATUS=1 等其他字段都是可选的
  static const String kDefaultCookie =
      "ttwid=1%7CB1qls3GdnZhUov9o2NxOMxxYS2ff6OSvEWbv0ytbES4%7C1680522049%7C280d802d6d478e3e78d0c807f7c487e7ffec0ae4e5fdd6a0fe74c3c6af149511";

  /// 用户设置的 cookie
  String cookie = "";

  void _logDebug(String msg) {
    // 同时使用 print 和 CoreLog 确保日志输出
    print("[Douyin] $msg");
    CoreLog.d("[Douyin] $msg");
  }

  void _logElapsed(String label, Stopwatch stopwatch) {
    stopwatch.stop();
    _logDebug("$label 耗时 ${stopwatch.elapsedMilliseconds}ms");
  }

  Map<String, dynamic> _newRequestHeaders({
    String? cookieValue,
    String authority = kDefaultAuthority,
    String referer = kDefaultReferer,
  }) {
    final requestHeaders = <String, dynamic>{
      "Authority": authority,
      "Referer": referer,
      "User-Agent": kDefaultUserAgent,
    };
    final normalizedCookie = cookieValue?.trim() ?? "";
    if (normalizedCookie.isNotEmpty) {
      requestHeaders["cookie"] = normalizedCookie;
    }
    return requestHeaders;
  }

  String _defaultPlaybackCookie() {
    return DouyinCookieHelper.extractTtwid(kDefaultCookie) ?? kDefaultCookie;
  }

  String _customPlaybackCookie() {
    return DouyinCookieHelper.extractTtwid(cookie) ?? "";
  }

  String _playbackCookie() {
    final customTtwid = _customPlaybackCookie();
    return customTtwid.isNotEmpty ? customTtwid : _defaultPlaybackCookie();
  }

  String _searchCookie() {
    final savedCookie = cookie.trim();
    return savedCookie.isNotEmpty ? savedCookie : _defaultPlaybackCookie();
  }

  Future<Map<String, dynamic>> getRequestHeaders({
    bool includeFullCookie = false,
  }) {
    return Future.value(
      _newRequestHeaders(
        cookieValue: includeFullCookie ? _searchCookie() : _playbackCookie(),
      ),
    );
  }

  Future<String> _getDanmakuCookie(String webRid) async {
    final stopwatch = Stopwatch()..start();
    final requestHeaders = await getRequestHeaders();
    final baseCookie = requestHeaders["cookie"]?.toString() ?? "";
    try {
      final webCookie = await _getWebCookie(
        webRid,
      ).timeout(const Duration(seconds: 5));
      final merged = _mergeCookieValues(
        baseCookie,
        webCookie,
        preferBase: cookie.isNotEmpty,
      );
      _logElapsed("_getDanmakuCookie($webRid)", stopwatch);
      return merged;
    } catch (e) {
      CoreLog.error(e);
      _logElapsed("_getDanmakuCookie($webRid) fallback", stopwatch);
      return baseCookie;
    }
  }

  String _mergeCookieValues(
    String baseCookie,
    String extraCookie, {
    bool preferBase = false,
  }) {
    final base = _parseCookieValue(baseCookie);
    final extra = _parseCookieValue(extraCookie);
    final merged = preferBase ? {...extra, ...base} : {...base, ...extra};
    return merged.entries
        .map((entry) => "${entry.key}=${entry.value}")
        .join("; ");
  }

  Map<String, String> _parseCookieValue(String cookieValue) {
    final cookieMap = <String, String>{};
    for (final part in cookieValue.split(";")) {
      final item = part.trim();
      if (item.isEmpty) {
        continue;
      }
      final separatorIndex = item.indexOf("=");
      if (separatorIndex <= 0) {
        continue;
      }
      final key = item.substring(0, separatorIndex).trim();
      final value = item.substring(separatorIndex + 1).trim();
      if (key.isNotEmpty) {
        cookieMap[key] = value;
      }
    }
    return cookieMap;
  }

  static const List<Map<String, dynamic>> _douyinCategoryData =
  [
    {
      'id': '1_1',
      'name': '射击游戏',
      'subs': [
        {'name': '和平精英', 'id': '1010032,1'},
        {'name': 'CSGO', 'id': '1010003,1'},
        {'name': '守望先锋', 'id': '1010339,1'},
        {'name': '穿越火线', 'id': '1010037,1'},
        {'name': '暗区突围：无限', 'id': '1011124,1'},
        {'name': '三角洲行动', 'id': '1011032,1'},
        {'name': '无畏契约', 'id': '1010017,1'},
        {'name': '绝地求生', 'id': '1010026,1'},
        {'name': '暗区突围', 'id': '1010018,1'},
        {'name': '穿越火线：枪战王者', 'id': '1010015,1'},
        {'name': 'Apex英雄', 'id': '1010002,1'},
        {'name': '逆战', 'id': '1010132,1'},
        {'name': '使命召唤手游', 'id': '1010080,1'},
        {'name': '萤火突击', 'id': '1010214,1'},
        {'name': '荒野行动', 'id': '1010064,1'},
        {'name': '反恐精英OL', 'id': '1010336,1'},
        {'name': '使命召唤', 'id': '1010329,1'},
        {'name': '逃离塔科夫', 'id': '1010104,1'},
        {'name': '漫威争锋', 'id': '1011240,1'},
        {'name': '界外狂潮', 'id': '1011310,1'},
        {'name': '生死狙击2', 'id': '1010068,1'},
        {'name': '彩虹六号：围攻', 'id': '1010402,1'},
        {'name': '生死狙击', 'id': '1010409,1'},
        {'name': '高能英雄', 'id': '1010198,1'},
        {'name': '战术小队', 'id': '1010445,1'},
        {'name': 'The Finals', 'id': '1010593,1'},
        {'name': '堡垒之夜', 'id': '1010383,1'},
        {'name': '战地5', 'id': '1010177,1'},
        {'name': '战地1', 'id': '1010367,1'},
        {'name': '远光84', 'id': '1010187,1'},
        {'name': '超凡先锋', 'id': '1010144,1'},
        {'name': '香肠派对', 'id': '1010050,1'},
        {'name': '卡拉彼丘', 'id': '1010168,1'},
        {'name': '迷你枪战精英', 'id': '1010460,1'},
        {'name': '不羁联盟', 'id': '1010592,1'},
        {'name': '全民枪神：边境王者', 'id': '1010645,1'}
      ],
    },
    {
      'id': '1_2',
      'name': '竞技游戏',
      'subs': [
        {'name': '英雄联盟手游', 'id': '1010023,1'},
        {'name': '永劫无间', 'id': '1010016,1'},
        {'name': '魔兽争霸3', 'id': '1010350,1'},
        {'name': '第五人格', 'id': '1010041,1'},
        {'name': '金铲铲之战', 'id': '1010055,1'},
        {'name': '云顶之弈', 'id': '1010005,1'},
        {'name': '英雄联盟', 'id': '1010014,1'},
        {'name': '王者荣耀', 'id': '1010045,1'},
        {'name': 'QQ飞车端游', 'id': '1010146,1'},
        {'name': '巅峰极速', 'id': '1010007,1'},
        {'name': 'DOTA1', 'id': '1010341,1'},
        {'name': 'QQ飞车手游', 'id': '1010033,1'},
        {'name': 'DOTA2', 'id': '1010093,1'},
        {'name': '炉石传说', 'id': '1010397,1'},
        {'name': '永劫无间手游', 'id': '1010278,1'},
        {'name': '坦克世界', 'id': '1010340,1'},
        {'name': '红色警戒2', 'id': '1010102,1'},
        {'name': '决胜巅峰', 'id': '1010292,1'},
        {'name': '三国杀', 'id': '1010061,1'},
        {'name': '跑跑卡丁车', 'id': '1010331,1'},
        {'name': '跑跑卡丁车官方竞速版', 'id': '1010131,1'},
        {'name': '战争雷霆', 'id': '1010170,1'},
        {'name': '极品飞车：集结', 'id': '1010686,1'},
        {'name': '星际争霸', 'id': '1010483,1'},
        {'name': '至暗时刻', 'id': '1010435,1'},
        {'name': '实况足球', 'id': '1010030,1'},
        {'name': '极限竞速：地平线5', 'id': '1010429,1'},
        {'name': '战舰世界', 'id': '1010418,1'},
        {'name': '恐惧饥荒', 'id': '1010430,1'},
        {'name': '全明星街球派对', 'id': '1010180,1'},
        {'name': '鹅鸭杀', 'id': '1010167,1'},
        {'name': '宝可梦大集结', 'id': '1010027,1'},
        {'name': '狼人杀', 'id': '1010313,1'},
        {'name': '决战！平安京', 'id': '1010057,1'},
        {'name': '哈利波特：魔法觉醒', 'id': '1010054,1'},
        {'name': '极限竞速：地平线4', 'id': '1010353,1'},
        {'name': '皇室战争', 'id': '1010230,1'},
        {'name': '极品飞车', 'id': '1010264,1'},
        {'name': '猫和老鼠', 'id': '1010327,1'},
        {'name': '逃跑吧！少年', 'id': '1010058,1'},
        {'name': '荒野乱斗', 'id': '1010138,1'},
        {'name': '星际争霸2', 'id': '1010509,1'},
        {'name': '最强NBA', 'id': '1010107,1'},
        {'name': '王牌竞速', 'id': '1010524,1'},
        {'name': '曙光英雄', 'id': '1010381,1'},
        {'name': '狂野飙车9：竞速传奇', 'id': '1010532,1'},
        {'name': '梦三国', 'id': '1010597,1'},
        {'name': '坦克世界：闪电战', 'id': '1010395,1'},
        {'name': '红色警戒3', 'id': '1010510,1'},
        {'name': '太空杀', 'id': '1010208,1'},
        {'name': '游戏王：决斗链接', 'id': '1010378,1'}
      ],
    },
    {
      'id': '1_3',
      'name': '单机游戏',
      'subs': [
        {'name': '植物大战僵尸', 'id': '1010324,1'},
        {'name': '黑神话：悟空', 'id': '1010358,1'},
        {'name': '俄罗斯钓鱼4', 'id': '1011048,1'},
        {'name': '星露谷物语', 'id': '1010791,1'},
        {'name': '方舟', 'id': '1010100,1'},
        {'name': '饥荒', 'id': '1010335,1'},
        {'name': '艾尔登法环', 'id': '1010087,1'},
        {'name': '人渣', 'id': '1010326,1'},
        {'name':  '拳皇97', 'id': '1010334,1'},
        {'name': '荒野大镖客2', 'id': '1010363,1'},
        {'name': '泰拉瑞亚', 'id': '1010396,1'},
        {'name': '实况足球', 'id': '1010030,1'},
        {'name': '极限竞速：地平线5', 'id': '1010429,1'},
        {'name': '只狼：影逝二度', 'id': '1010149,1'},
        {'name': '猛兽派对', 'id': '1010038,1'},
        {'name': '幻兽帕鲁', 'id': '1010981,1'},
        {'name': '双影奇境', 'id': '1010436,1'},
        {'name': '绝地潜兵2', 'id': '1011000,1'},
        {'name': '骑马与砍杀2：霸主', 'id': '1010401,1'},
        {'name': '都市：天际线', 'id': '1010142,1'},
        {'name': '木筏求生', 'id': '1010408,1'},
        {'name': '塞尔达传说：旷野之息', 'id': '1010081,1'},
        {'name': '拳皇98', 'id': '1010407,1'},
        {'name': 'The Finals', 'id': '1010593,1'},
        {'name': '战地5', 'id': '1010177,1'},
        {'name': '战神', 'id': '1010788,1'},
        {'name': '英雄无敌3', 'id': '1011119,1'},
        {'name': '宝可梦朱紫', 'id': '1010847,1'},
        {'name': '街头霸王2', 'id': '1010352,1'},
        {'name': '街头霸王6', 'id': '1010361,1'},
        {'name': '极限竞速：地平线4', 'id': '1010353,1'},
        {'name': '命运2', 'id': '1010422,1'},
        {'name': '战地1', 'id': '1010367,1'},
        {'name': '星际战甲', 'id': '1010250,1'},
        {'name': '森林之子', 'id': '1010783,1'},
        {'name': '链在一起', 'id': '1011170,1'},
        {'name': '缉私警察', 'id': '1010769,1'},
        {'name': '不祥之夜：回魂', 'id': '1011089,1'},
        {'name': '赛博朋克2077', 'id': '1010128,1'},
        {'name': '怪物猎人：崛起', 'id': '1010420,1'},
        {'name': '全面战争：三国', 'id': '1010779,1'},
        {'name': '潜水员戴夫', 'id': '1010626,1'},
        {'name': '塞尔达传说：王国之泪', 'id': '1010082,1'},
        {'name': '仁王', 'id': '1010774,1'},
        {'name': '三国志14', 'id': '1010514,1'},
        {'name': '死亡搁浅', 'id': '1010777,1'},
        {'name': '不羁联盟', 'id': '1010592,1'},
        {'name': '禁闭求生', 'id': '1010247,1'},
        {'name': '天国拯救2', 'id': '1011399,1'},
        {'name': '人类：一败涂地', 'id': '1010130,1'},
        {'name': '第一后裔', 'id': '1011175,1'},
        {'name': 'NBA 2K22', 'id': '1010417,1'},
        {'name': '鬼谷八荒', 'id': '1010224,1'},
        {'name': '无主之地3', 'id': '1010512,1'},
        {'name': '暖雪', 'id': '1010472,1'},
        {'name': '冰与火之舞', 'id': '1011146,1'},
        {'name': '消逝的光芒2：人与仁之战', 'id': '1010433,1'},
        {'name': '鬼泣5', 'id': '1010246,1'},
        {'name': '猎人：荒野的召唤', 'id': '1010441,1'},
        {'name': '匹诺曹的谎言', 'id': '1010320,1'},
        {'name': '从军', 'id': '1011394,1'},
        {'name': '泰坦陨落', 'id': '1010784,1'},
        {'name': '超级马里奥制造', 'id': '1010442,1'},
        {'name': '博德之门3', 'id': '1010640,1'},
        {'name': '女神异闻录5', 'id': '1010171,1'},
        {'name': '刺客信条：奥德赛', 'id': '1010485,1'},
        {'name': '最终幻想 16', 'id': '1010316,1'},
        {'name': 'i wanna', 'id': '1010776,1'},
        {'name': '看门狗2', 'id': '1010790,1'},
        {'name': '掘地求升', 'id': '1011136,1'},
        {'name': 'Shooterspool', 'id': '1011108,1'},
        {'name': '极限国度', 'id': '1010434,1'},
        {'name': '流放之路', 'id': '1010411,1'},
        {'name': '致命公司', 'id': '1010846,1'},
        {'name': '三国志11', 'id': '1010515,1'}
      ],
    },
    {
      'id': '1_4',
      'name': '棋牌游戏',
      'subs': [
        {'name': 'JJ象棋', 'id': '1010063,1'},
        {'name': 'JJ斗地主', 'id': '1010004,1'},
        {'name': '途游斗地主', 'id': '1010012,1'},
        {'name': 'JJ麻将', 'id': '1010094,1'},
        {'name': '指尖四川麻将', 'id': '1010040,1'},
        {'name': '天天象棋', 'id': '1010060,1'},
        {'name': '欢乐斗地主', 'id': '1010062,1'},
        {'name': '微乐斗地主', 'id': '1010714,1'},
        {'name': '开运麻将', 'id': '1010711,1'},
        {'name': '微乐四川麻将', 'id': '1010710,1'},
        {'name': '芒果斗地主', 'id': '1010028,1'},
        {'name': '多乐升级', 'id': '1010721, 1'},
        {'name': '腾讯欢乐麻将', 'id': '1010059,1'},
        {'name': '多乐够级', 'id': '1010720,1'},
        {'name': '禅游斗地主', 'id': '1010098,1'},
        {'name': '富豪麻将', 'id': '1010101,1'},
        {'name': '途游象棋', 'id': '1010553,1'}
      ],
    },
    {
      'id': '1_5',
      'name': '休闲益智',
      'subs': [
        {'name': '蛋仔派对', 'id': '1010011,1'},
        {'name': '我的世界', 'id': '1010022,1'},
        {'name': '元梦之星', 'id': '1010263,1'},
        {'name': '球球大作战', 'id': '1010010,1'},
        {'name': '沙盒与副本：英勇之地', 'id': '1010699,1'},
        {'name': '开心消消乐', 'id': '1010520,1'},
        {'name': '迷你世界', 'id': '1010046,1'},
        {'name': '忍者必须死3', 'id': '1010129,1'},
        {'name': '贪吃蛇大作战', 'id': '1010056,1'},
        {'name': '天天台球', 'id': '1010806,1'},
        {'name': '罗布乐思', 'id': '1010523,1'},
        {'name': '地铁跑酷', 'id': '1010099,1'},
        {'name': '台球帝国', 'id': '1010921,1'},
        {'name': '天天酷跑', 'id': '1010410,1'},
        {'name': '创世战车', 'id': '1010639,1'},
        {'name': '腾讯桌球', 'id': '1010121,1'},
        {'name': '创造与魔法', 'id': '1010399,1'},
        {'name': '群雄逐鹿', 'id': '1010895,1'},
        {'name': '阿瑞斯病毒2', 'id': '1010272,1'}
      ],
    },
    {
      'id': '1_6',
      'name': '角色扮演',
      'subs': [
        {'name': '燕云十六声', 'id': '1010271,1'},
        {'name': '火影忍者手游', 'id': '1010042,1'},
        {'name': '魔兽世界', 'id': '1010150,1'},
        {'name': '原神', 'id': '1010039,1'},
        {'name': '地下城与勇士', 'id': '1010092,1'},
        {'name': '大话西游2', 'id': '1010205,1'},
        {'name': '梦幻西游手游', 'id': '1010051,1'},
        {'name': '逆水寒手游', 'id': '1010083,1'},
        {'name': '地下城与勇士：起源', 'id': '1010234,1'},
        {'name': '鸣潮', 'id': '1010159,1'},
        {'name': '梦幻西游', 'id': '1010053,1'},
        {'name': '光遇', 'id': '1010035,1'},
        {'name': '剑网3', 'id': '1010249,1'},
        {'name': '七日世界', 'id': '1010558,1'},
        {'name': '命运方舟', 'id': '1010233,1'},
        {'name': '诛仙世界', 'id': '1010151,1'},
        {'name': '明日之后', 'id': '1010006,1'},
        {'name': '火炬之光：无限', 'id': '1010241,1'},
        {'name': '绝区零', 'id': '1010155,1'},
        {'name': '无限暖暖', 'id': '1010253,1'},
        {'name': '问道', 'id': '1010116,1'},
        {'name': '逆水寒', 'id': '1010364,1'},
        {'name': '龙之谷世界', 'id': '1010181,1'},
        {'name': '洛克王国', 'id': '1010203,1'},
        {'name': '航海王：壮志雄心', 'id': '1011139,1'},
        {'name': '大话西游', 'id': '1010143,1'},
        {'name': '神武4', 'id': '1010125,1'},
        {'name': '只狼：影逝二度', 'id': '1010149,1'},
        {'name': '暗黑破坏神：不朽', 'id': '1010096,1'},
        {'name': '梦幻新诛仙', 'id': '1010315,1'},
        {'name': '星球：重启', 'id': '1010193,1'},
        {'name': '冒险岛：枫之传说', 'id': '1010311,1'},
        {'name': '晶核', 'id': '1010044,1'},
        {'name': '一梦江湖', 'id': '1010412,1'},
        {'name': '射雕', 'id': '1010245,1'},
        {'name': '石器时代：觉醒', 'id': '1010487,1'},
        {'name': '新完美世界', 'id': '1010257,1'},
        {'name': '妄想山海', 'id': '1010533,1'},
        {'name': '航海王热血航线', 'id': '1010231,1'},
        {'name': '命运2', 'id': '1010422,1'},
        {'name': '仙剑世界', 'id': '1010212,1'},
        {'name': '黎明觉醒：生机', 'id': '1010029,1'},
        {'name': '新大话西游3', 'id': '1010568,1'},
        {'name': '星际战甲', 'id': '1010250,1'},
        {'name': '崩坏3', 'id': '1010020,1'},
        {'name': '长安幻想', 'id': '1010097,1'},
        {'name': '塔瑞斯世界', 'id': '1010270,1'},
        {'name': '新天龙八部', 'id': '1010266,1'},
        {'name': '月圆之夜', 'id': '1010024,1'},
        {'name': '元气骑士', 'id': '1010343,1'},
        {'name': '归龙潮', 'id': '1010153,1'},
        {'name': '尘白禁区', 'id': '1010086,1'},
        {'name': '战双帕弥什', 'id': '1010089,1'},
        {'name': '失落城堡', 'id': '1010223,1'},
        {'name': '元气骑士前传', 'id': '1010182,1'},
        {'name': '激战2', 'id': '1010405,1'},
        {'name': '暖雪', 'id': '1010472,1'},
        {'name': '苍翼：混沌效应', 'id': '1010604,1'},
        {'name': '战斗法则', 'id': '1010646,1'},
        {'name': '仙境传说：爱如初见', 'id': '1010679,1'},
        {'name': '无主之地3', 'id': '1010512,1'},
        {'name': '行侠仗义五千年', 'id': '1010248,1'},
        {'name': '博德之门3', 'id': '1010640,1'},
        {'name': '天涯明月刀', 'id': '1010119,1'},
        {'name': '匹诺曹的谎言', 'id': '1010320,1'},
        {'name': '女神异闻录5', 'id': '1010171,1'},
        {'name': '一念逍遥', 'id': '1010112,1'},
        {'name': '天龙八部2：飞龙战天', 'id': '1010120,1'},
        {'name': '斗罗大陆：史莱克学院', 'id': '1010259,1'},
        {'name': '全境封锁2', 'id': '1010199,1'},
        {'name': '流放之路', 'id': '1010411,1'}
      ],
    },
    {
      'id': '1_7',
      'name': '策略卡牌',
      'subs': [
        {'name': '崩坏：星穹铁道', 'id': '1010043,1'},
        {'name': '植物大战僵尸', 'id': '1010324,1'},
        {'name': '三国志·战略版', 'id': '1010009,1'},
        {'name': '阴阳师', 'id': '1010025,1'},
        {'name': '明日方舟', 'id': '1010013,1'},
        {'name': '漫威终极逆转', 'id': '1011150,1'},
        {'name': '率土之滨', 'id': '1010021,1'},
        {'name': '万国觉醒', 'id': '1010105,1'},
        {'name': '恋与深空', 'id': '1010084,1'},
        {'name': '海岛奇兵', 'id': '1010385,1'},
        {'name': '部落冲突', 'id': '1010145,1'},
        {'name': '斗罗大陆：魂师对决', 'id': '1010365,1'},
        {'name': '植物大战僵尸2', 'id': '1010067,1'},
        {'name': '赛尔号', 'id': '1010521,1'},
        {'name': '奥奇传说', 'id': '1010419,1'},
        {'name': '如鸢', 'id': '1010192,1'},
        {'name': '蔚蓝档案', 'id': '1010289,1'},
        {'name': '无尽的拉格朗日', 'id': '1010008,1'},
        {'name': '重返未来1999', 'id': '1010196,1'},
        {'name': '战火勋章', 'id': '1010108,1'},
        {'name': '文明', 'id': '1010265,1'},
        {'name': '梦幻模拟战', 'id': '1010394,1'},
        {'name': '航海王：燃烧意志', 'id': '1010574,1'},
        {'name': '三国志·战棋版', 'id': '1010127,1'},
        {'name': '闪耀！优俊少女', 'id': '1010291,1'},
        {'name': '三国志11', 'id': '1010515,1'},
        {'name': '小冰冰传奇', 'id': '1010673,1'}
      ],
    },
    {
      'id': '3_10000',
      'name': '娱乐天地',
      'subs': [
        {'name': '时尚', 'id': '2823,2'},
        {'name': '美食', 'id': '2786,2'},
        {'name': '旅行', 'id': '2751,2'},
        {'name': '舞蹈', 'id': '2726,2'},
        {'name': '户外', 'id': '2742,2'},
        {'name': '运动', 'id': '2791,2'},
        {'name': '音乐', 'id': '2707,2'},
        {'name': '语音互动', 'id': '2842,2'}
      ],
    },
    {
      'id': '3_10001',
      'name': '科技文化',
      'subs': [
        {'name': '人文艺术', 'id': '2756,2'},
        {'name': '教育', 'id': '2800,2'}
      ],
    }
  ];

  @override
  Future<List<LiveCategory>> getCategores() async {
    List<LiveCategory> categories = [];
    for (var item in _douyinCategoryData) {
      var id = item["id"] as String;
      var name = item["name"] as String;
      List<LiveSubCategory> subs = [];
      for (var subItem in item["subs"] as List) {
        subs.add(
          LiveSubCategory(
            id: subItem['id'] as String,
            name: subItem['name'] as String,
            parentId: id,
            pic: "",
          ),
        );
      }
      var category = LiveCategory(
        children: subs,
        id: id,
        name: name,
      );
      subs.insert(
        0,
        LiveSubCategory(
          id: "720,1",
          name: category.name,
          parentId: category.id,
          pic: "",
        ),
      );
      categories.add(category);
    }
    return categories;
  }

  String? _pickPartitionImageUrl(dynamic data) {
    if (data == null) {
      return null;
    }
    if (data is String) {
      final value = data.trim();
      return value.isEmpty ? null : value;
    }
    if (data is List) {
      for (final item in data) {
        final value = _pickPartitionImageUrl(item);
        if (value != null && value.isNotEmpty) {
          return value;
        }
      }
      return null;
    }
    if (data is! Map) {
      return null;
    }

    for (final key in const [
      "icon",
      "icons",
      "cover",
      "background",
      "avatar_thumb",
      "image",
      "image_url",
      "url",
      "url_list",
      "static_icon",
    ]) {
      final value = _pickPartitionImageUrl(data[key]);
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }

    for (final value in data.values) {
      final resolved = _pickPartitionImageUrl(value);
      if (resolved != null && resolved.isNotEmpty) {
        return resolved;
      }
    }
    return null;
  }

  String? _resolveCategoryValue(
    dynamic source,
    List<String> keys, {
    int depth = 0,
  }) {
    if (depth > 6) {
      return null;
    }
    if (source is List) {
      for (final item in source) {
        final value = _resolveCategoryValue(item, keys, depth: depth + 1);
        if (value != null && value.isNotEmpty) {
          return value;
        }
      }
      return null;
    }
    if (source is! Map) {
      return null;
    }
    for (final key in keys) {
      final value = source[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    for (final value in source.values) {
      final resolved = _resolveCategoryValue(value, keys, depth: depth + 1);
      if (resolved != null && resolved.isNotEmpty) {
        return resolved;
      }
    }
    return null;
  }

  Map<String, String?> _resolveDouyinCategoryInfo(dynamic roomData) {
    final room = roomData is Map ? roomData : <String, dynamic>{};
    final partitionRoadMap =
        room["partition_road_map"] ?? room["partitionRoadMap"];
    final partition =
        room["partition"] ??
        room["room_partition"] ??
        room["partitionInfo"] ??
        (partitionRoadMap is List && partitionRoadMap.isNotEmpty
            ? partitionRoadMap.last
            : null);
    final parentPartition =
        room["parent_partition"] ??
        room["partition_parent"] ??
        (partition is Map
            ? partition["parent_partition"] ??
                  partition["partition_parent"] ??
                  partition["parent"]
            : null) ??
        (partitionRoadMap is List && partitionRoadMap.length > 1
            ? partitionRoadMap.first
            : null) ??
        room["partitionInfo"];

    return {
      "categoryId": _resolveCategoryValue(partition, const [
        "id_str",
        "id",
        "partition_id",
        "partition",
      ]),
      "categoryName": _resolveCategoryValue(partition, const [
        "title",
        "name",
        "partition_title",
      ]),
      "categoryParentId": _resolveCategoryValue(parentPartition, const [
        "id_str",
        "id",
        "partition_id",
        "partition",
      ]),
      "categoryParentName": _resolveCategoryValue(parentPartition, const [
        "title",
        "name",
        "partition_title",
      ]),
      "categoryPic":
          _pickPartitionImageUrl(partition) ??
          _pickPartitionImageUrl(parentPartition),
    };
  }

  Map<String, dynamic> _extractCategoryRenderData(String html) {
    const marker = r'\"categoryData\":';
    final markerIndex = html.indexOf(marker);
    if (markerIndex < 0) {
      throw CoreError("抖音分类数据解析失败");
    }
    final arrayStart = html.indexOf("[", markerIndex);
    if (arrayStart < 0) {
      throw CoreError("抖音分类数据解析失败");
    }
    final escapedArray = _extractEscapedJsonArray(html, arrayStart);
    final normalizedJson = '{"categoryData":$escapedArray}'
        .replaceAll(r'\"', '"')
        .replaceAll(r"\/", "/")
        .replaceAll(r"\\", "\\");
    return json.decode(normalizedJson) as Map<String, dynamic>;
  }

  String _extractEscapedJsonArray(String source, int startIndex) {
    final buffer = StringBuffer();
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = startIndex; i < source.length; i++) {
      final char = source[i];
      buffer.write(char);

      if (escaped) {
        escaped = false;
        continue;
      }
      if (char == "\\") {
        escaped = true;
        continue;
      }
      if (char == '"') {
        inString = !inString;
        continue;
      }
      if (inString) {
        continue;
      }
      if (char == "[") {
        depth += 1;
      } else if (char == "]") {
        depth -= 1;
        if (depth == 0) {
          return buffer.toString();
        }
      }
    }
    throw CoreError("抖音分类数据解析失败");
  }

  List _resolveCategoryRoomData(dynamic result) {
    if (result is Map && result["status_code"] == 444) {
      throw CoreError("", statusCode: 444);
    }
    if (result is! Map) {
      throw CoreError("抖音分类接口返回异常");
    }
    final data = result["data"];
    if (data is! Map) {
      throw CoreError("抖音分类接口返回异常，可能已触发访问限制");
    }
    final rooms = data["data"];
    if (rooms is! List) {
      throw CoreError("抖音分类接口返回异常，可能已触发访问限制");
    }
    return rooms;
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) async {
    var ids = category.id.split(',');
    var partitionId = ids[0];
    var partitionType = ids[1];

    String serverUrl =
        "https://live.douyin.com/webcast/web/partition/detail/room/v2/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "aid": '6383',
        "app_name": "douyin_web",
        "live_id": '1',
        "device_platform": "web",
        "language": "zh-CN",
        "enter_from": "link_share",
        "cookie_enabled": "true",
        "screen_width": "1980",
        "screen_height": "1080",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Edge",
        "browser_version": "125.0.0.0",
        "browser_online": "true",
        "count": '15',
        "offset": ((page - 1) * 15).toString(),
        "partition": partitionId,
        "partition_type": partitionType,
        "req_from": '2',
      },
    );
    var requestUrl = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent);

    var result = await HttpClient.instance.getJson(
      requestUrl,
      header: await getRequestHeaders(),
    );

    final roomData = _resolveCategoryRoomData(result);
    var hasMore = roomData.length >= 15;
    var items = <LiveRoomItem>[];
    for (var item in roomData) {
      var roomItem = LiveRoomItem(
        roomId: item["web_rid"],
        title: item["room"]["title"].toString(),
        cover: item["room"]["cover"]["url_list"][0].toString(),
        userName: item["room"]["owner"]["nickname"].toString(),
        online:
            int.tryParse(
              item["room"]["room_view_stats"]["display_value"].toString(),
            ) ??
            0,
      );
      items.add(roomItem);
    }
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    String serverUrl =
        "https://live.douyin.com/webcast/web/partition/detail/room/v2/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "aid": '6383',
        "app_name": "douyin_web",
        "live_id": '1',
        "device_platform": "web",
        "language": "zh-CN",
        "enter_from": "link_share",
        "cookie_enabled": "true",
        "screen_width": "1980",
        "screen_height": "1080",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Edge",
        "browser_version": "125.0.0.0",
        "browser_online": "true",
        "count": '15',
        "offset": ((page - 1) * 15).toString(),
        "partition": '720',
        "partition_type": '1',
        "req_from": '2',
      },
    );
    var requestUrl = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent);

    var result = await HttpClient.instance.getJson(
      requestUrl,
      header: await getRequestHeaders(),
    );

    final roomData = _resolveCategoryRoomData(result);
    var hasMore = roomData.length >= 15;
    var items = <LiveRoomItem>[];
    for (var item in roomData) {
      var roomItem = LiveRoomItem(
        roomId: item["web_rid"],
        title: item["room"]["title"].toString(),
        cover: item["room"]["cover"]["url_list"][0].toString(),
        userName: item["room"]["owner"]["nickname"].toString(),
        online:
            int.tryParse(
              item["room"]["room_view_stats"]["display_value"].toString(),
            ) ??
            0,
      );
      items.add(roomItem);
    }
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  /// 未实现轻量在线接口 → 返回 null，调用方回退 [getRoomDetail]。
  @override
  Future<LiveRoomOnlineInfo?> getRoomOnlineInfo({required String roomId}) async {
    return null;
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    final stopwatch = Stopwatch()..start();
    try {
      // 有两种roomId，一种是webRid，一种是roomId
      // roomId是一次性的，用户每次重新开播都会生成一个新的roomId
      // roomId一般长度为19位，例如：7376429659866598196
      // webRid是固定的，用户每次开播都是同一个webRid
      // webRid一般长度为11-12位，例如：416144012050
      // 这里简单进行判断，如果roomId长度小于15，则认为是webRid
      if (roomId.length <= 16) {
        var webRid = roomId;
        return await getRoomDetailByWebRid(webRid);
      }

      return await getRoomDetailByRoomId(roomId);
    } finally {
      _logElapsed("getRoomDetail($roomId)", stopwatch);
    }
  }

  /// 通过roomId获取直播间信息
  /// - [roomId] 直播间ID
  /// - 返回直播间信息
  Future<LiveRoomDetail> getRoomDetailByRoomId(String roomId) async {
    final stopwatch = Stopwatch()..start();
    // 读取房间信息
    var roomData = await _getRoomDataByRoomId(roomId);
    final room = roomData["data"]?["room"];
    if (room is! Map) {
      throw CoreError("抖音直播间数据为空，可能是房间不存在、未开播或被风控限制");
    }

    // 通过房间信息获取WebRid
    var webRid = room["owner"]["web_rid"].toString();

    // 读取用户唯一ID，用于弹幕连接
    // 似乎这个参数不是必须的，先随机生成一个
    //var userUniqueId = await _getUserUniqueId(webRid);
    var userUniqueId = generateRandomNumber(12).toString();

    var owner = room["owner"];
    final categoryInfo = _resolveDouyinCategoryInfo(room);

    var status = asT<int?>(room["status"]) ?? 0;

    // roomId是一次性的，用户每次重新开播都会生成一个新的roomId
    // 所以如果roomId对应的直播间状态不是直播中，就通过webRid获取直播间信息
    if (status == 4) {
      var result = await getRoomDetailByWebRid(webRid);
      _logElapsed("getRoomDetailByRoomId($roomId) redirect", stopwatch);
      return result;
    }

    var roomStatus = status == 2;
    // 主要是为了获取cookie,用于弹幕websocket连接
    var danmakuCookie = await _getDanmakuCookie(webRid);

    final detail = LiveRoomDetail(
      roomId: webRid,
      title: room["title"].toString(),
      cover: roomStatus ? room["cover"]["url_list"][0].toString() : "",
      userName: owner["nickname"].toString(),
      userAvatar: owner["avatar_thumb"]["url_list"][0].toString(),
      online: roomStatus
          ? asT<int?>(room["room_view_stats"]["display_value"]) ?? 0
          : 0,
      status: roomStatus,
      url: "https://live.douyin.com/$webRid",
      introduction: owner["signature"].toString(),
      notice: "",
      categoryId: categoryInfo["categoryId"],
      categoryName: categoryInfo["categoryName"],
      categoryParentId: categoryInfo["categoryParentId"],
      categoryParentName: categoryInfo["categoryParentName"],
      categoryPic: categoryInfo["categoryPic"],
      danmakuData: DouyinDanmakuArgs(
        webRid: webRid,
        roomId: roomId,
        userId: userUniqueId,
        cookie: danmakuCookie,
      ),
      data: room["stream_url"],
    );
    _logElapsed("getRoomDetailByRoomId($roomId)", stopwatch);
    return detail;
  }

  /// 通过WebRid获取直播间信息
  /// - [webRid] 直播间RID
  /// - 返回直播间信息
  Future<LiveRoomDetail> getRoomDetailByWebRid(String webRid) async {
    final stopwatch = Stopwatch()..start();
    try {
      var result = await _getRoomDetailByWebRidApi(webRid);
      _logElapsed("getRoomDetailByWebRid($webRid) api", stopwatch);
      return result;
    } catch (e) {
      CoreLog.error(e);
      if (e is CoreError && e.statusCode == 444) {
        rethrow;
      }
    }
    final result = await _getRoomDetailByWebRidHtml(webRid);
    _logElapsed("getRoomDetailByWebRid($webRid) html", stopwatch);
    return result;
  }

  /// 通过WebRid访问直播间API，从API中获取直播间信息
  /// - [webRid] 直播间RID
  /// - 返回直播间信息
  Future<LiveRoomDetail> _getRoomDetailByWebRidApi(String webRid) async {
    final stopwatch = Stopwatch()..start();
    // 读取房间信息
    var data = await _getRoomDataByApi(webRid);

    var roomData = data["data"][0];
    var userData = data["user"];
    var roomId = roomData["id_str"].toString();
    final categoryInfo = _resolveDouyinCategoryInfo(roomData);

    // 读取用户唯一ID，用于弹幕连接
    // 似乎这个参数不是必须的，先随机生成一个
    //var userUniqueId = await _getUserUniqueId(webRid);
    var userUniqueId = generateRandomNumber(12).toString();

    var owner = roomData["owner"];

    var roomStatus = (asT<int?>(roomData["status"]) ?? 0) == 2;

    // 主要是为了获取cookie,用于弹幕websocket连接
    var danmakuCookie = await _getDanmakuCookie(webRid);
    final detail = LiveRoomDetail(
      roomId: webRid,
      title: roomData["title"].toString(),
      cover: roomStatus ? roomData["cover"]["url_list"][0].toString() : "",
      userName: roomStatus
          ? owner["nickname"].toString()
          : userData["nickname"].toString(),
      userAvatar: roomStatus
          ? owner["avatar_thumb"]["url_list"][0].toString()
          : userData["avatar_thumb"]["url_list"][0].toString(),
      online: roomStatus
          ? asT<int?>(roomData["room_view_stats"]["display_value"]) ?? 0
          : 0,
      status: roomStatus,
      url: "https://live.douyin.com/$webRid",
      introduction: owner?["signature"]?.toString() ?? "",
      notice: "",
      categoryId: categoryInfo["categoryId"],
      categoryName: categoryInfo["categoryName"],
      categoryParentId: categoryInfo["categoryParentId"],
      categoryParentName: categoryInfo["categoryParentName"],
      categoryPic: categoryInfo["categoryPic"],
      danmakuData: DouyinDanmakuArgs(
        webRid: webRid,
        roomId: roomId,
        userId: userUniqueId,
        cookie: danmakuCookie,
      ),
      data: roomStatus ? roomData["stream_url"] : {},
    );
    _logElapsed("_getRoomDetailByWebRidApi($webRid)", stopwatch);
    return detail;
  }

  /// 通过WebRid访问直播间网页，从网页HTML中获取直播间信息
  /// - [webRid] 直播间RID
  /// - 返回直播间信息
  Future<LiveRoomDetail> _getRoomDetailByWebRidHtml(String webRid) async {
    final stopwatch = Stopwatch()..start();
    var roomData = await _getRoomDataByHtml(webRid);
    var roomId = roomData["roomStore"]["roomInfo"]["room"]["id_str"].toString();
    var userUniqueId = resolveUserUniqueIdFromRoomData(roomData);

    var room = roomData["roomStore"]["roomInfo"]["room"];
    var owner = room["owner"];
    var anchor = roomData["roomStore"]["roomInfo"]["anchor"];
    final categoryInfo = _resolveDouyinCategoryInfo(room);
    var roomStatus = (asT<int?>(room["status"]) ?? 0) == 2;

    // 主要是为了获取cookie,用于弹幕websocket连接
    var danmakuCookie = await _getDanmakuCookie(webRid);

    final detail = LiveRoomDetail(
      roomId: webRid,
      title: room["title"].toString(),
      cover: roomStatus ? room["cover"]["url_list"][0].toString() : "",
      userName: roomStatus
          ? owner["nickname"].toString()
          : anchor["nickname"].toString(),
      userAvatar: roomStatus
          ? owner["avatar_thumb"]["url_list"][0].toString()
          : anchor["avatar_thumb"]["url_list"][0].toString(),
      online: roomStatus
          ? asT<int?>(room["room_view_stats"]["display_value"]) ?? 0
          : 0,
      status: roomStatus,
      url: "https://live.douyin.com/$webRid",
      introduction: owner?["signature"]?.toString() ?? "",
      notice: "",
      categoryId: categoryInfo["categoryId"],
      categoryName: categoryInfo["categoryName"],
      categoryParentId: categoryInfo["categoryParentId"],
      categoryParentName: categoryInfo["categoryParentName"],
      categoryPic: categoryInfo["categoryPic"],
      danmakuData: DouyinDanmakuArgs(
        webRid: webRid,
        roomId: roomId,
        userId: userUniqueId,
        cookie: danmakuCookie,
      ),
      data: roomStatus ? room["stream_url"] : {},
    );
    _logElapsed("_getRoomDetailByWebRidHtml($webRid)", stopwatch);
    return detail;
  }

  String resolveUserUniqueIdFromRoomData(dynamic roomData) {
    final resolved = _resolveNestedString(roomData, const [
      "userStore",
      "odin",
      "user_unique_id",
    ]);
    if (resolved != null && resolved.isNotEmpty) {
      return resolved;
    }

    final fallback = _resolveNestedString(roomData, const [
      "userStore",
      "user",
      "user_unique_id",
    ]);
    if (fallback != null && fallback.isNotEmpty) {
      return fallback;
    }

    return generateRandomNumber(12).toString();
  }

  String? _resolveNestedString(dynamic source, List<String> path) {
    dynamic current = source;
    for (final key in path) {
      if (current is! Map) {
        return null;
      }
      current = current[key];
      if (current == null) {
        return null;
      }
    }
    final value = current.toString().trim();
    return value.isEmpty ? null : value;
  }

  /// 读取用户的唯一ID
  /// - [webRid] 直播间RID
  // ignore: unused_element
  Future<String> _getUserUniqueId(String webRid) async {
    try {
      var webInfo = await _getRoomDataByHtml(webRid);
      return resolveUserUniqueIdFromRoomData(webInfo);
    } catch (e) {
      return generateRandomNumber(12).toString();
    }
  }

  /// 进入直播间前需要先获取cookie
  /// - [webRid] 直播间RID
  Future<String> _getWebCookie(String webRid) async {
    final requestHeaders = Map<String, dynamic>.from(await getRequestHeaders());
    final baseCookie = _getCookieHeaderValue(requestHeaders);
    final cacheKey = "$webRid|${baseCookie.hashCode}";
    final cachedAt = _webCookieCacheAt[cacheKey];
    final cachedValue = _webCookieCache[cacheKey];
    if (cachedAt != null &&
        cachedValue != null &&
        DateTime.now().difference(cachedAt) < _webCookieCacheTtl) {
      _logDebug("_getWebCookie($webRid) 使用缓存");
      return cachedValue;
    }
    final stopwatch = Stopwatch()..start();
    requestHeaders["Referer"] = "https://live.douyin.com/$webRid";
    dynamic headResp;
    try {
      headResp = await HttpClient.instance.head(
        "https://live.douyin.com/$webRid",
        header: requestHeaders,
      );
    } catch (e) {
      if (baseCookie.isNotEmpty) {
        _logDebug("获取直播间 Web Cookie 的 HEAD 请求失败，使用已保存 Cookie 继续：$e");
        _webCookieCache[cacheKey] = baseCookie;
        _webCookieCacheAt[cacheKey] = DateTime.now();
        _logElapsed("_getWebCookie($webRid) fallback", stopwatch);
        return baseCookie;
      }
      rethrow;
    }
    if (headResp.statusCode == 444) {
      throw CoreError("", statusCode: 444);
    }
    var dyCookie = "";
    if (baseCookie.isNotEmpty) {
      dyCookie = _ensureCookieEndsWithSemicolon(baseCookie);
    }
    headResp.headers["set-cookie"]?.forEach((element) {
      var cookie = element.split(";")[0];
      if (cookie.contains("ttwid")) {
        dyCookie += "$cookie;";
      }
      if (cookie.contains("__ac_nonce")) {
        dyCookie += "$cookie;";
      }
      if (cookie.contains("msToken")) {
        dyCookie += "$cookie;";
      }
    });
    _webCookieCache[cacheKey] = dyCookie;
    _webCookieCacheAt[cacheKey] = DateTime.now();
    _logElapsed("_getWebCookie($webRid)", stopwatch);
    return dyCookie;
  }

  /// 通过webRid获取直播间Web信息
  /// - [webRid] 直播间RID
  Future<Map> _getRoomDataByHtml(String webRid) async {
    final stopwatch = Stopwatch()..start();
    var dyCookie = await _getWebCookie(webRid);
    final requestStopwatch = Stopwatch()..start();
    var result = await HttpClient.instance.getText(
      "https://live.douyin.com/$webRid",
      queryParameters: {},
      header: {
        "Authority": kDefaultAuthority,
        "Referer": kDefaultReferer,
        "Cookie": dyCookie,
        "User-Agent": kDefaultUserAgent,
      },
    );
    _logElapsed("_getRoomDataByHtml($webRid) request", requestStopwatch);
    final parseStopwatch = Stopwatch()..start();
    if (result.trim().isEmpty) {
      throw CoreError("抖音直播间页面返回为空，请稍后再试");
    }
    if (!result.contains(r'\"state\"')) {
      throw CoreError("抖音直播间页面数据不可用，可能是访问受限或页面结构已变化");
    }

    var renderData =
        RegExp(
          r'\{\\"state\\":\{\\"appStore.*?\]\\n',
        ).firstMatch(result)?.group(0) ??
        "";
    if (renderData.isEmpty) {
      throw CoreError("抖音直播间页面数据解析失败，请稍后再试");
    }
    var str = renderData
        .trim()
        .replaceAll('\\"', '"')
        .replaceAll(r"\\", r"\")
        .replaceAll(']\\n', "");
    final renderDataJson = json.decode(str);
    final state = renderDataJson["state"];
    if (state is! Map) {
      throw CoreError("抖音直播间页面状态数据异常");
    }
    _logElapsed("_getRoomDataByHtml($webRid) parse", parseStopwatch);
    _logElapsed("_getRoomDataByHtml($webRid)", stopwatch);
    return state;
  }

  /// 通过webRid获取直播间Web信息
  /// - [webRid] 直播间RID
  Future<Map> _getRoomDataByApi(String webRid) async {
    final stopwatch = Stopwatch()..start();
    final result = await _requestWithCustomCookieFallback(
      label: "抖音房间接口",
      request: (cookieValue) =>
          _requestRoomDataByApi(webRid, cookieValue: cookieValue),
      hasData: _hasWebRoomData,
    );

    if (result is! Map) {
      throw Exception("抖音接口返回格式异常");
    }

    final data = result["data"];
    if (data is! Map) {
      throw CoreError("抖音直播间数据为空，请稍后再试");
    }
    final rooms = data["data"];
    if (rooms is! List || rooms.isEmpty) {
      throw CoreError("抖音直播间数据为空，可能是房间不存在、未开播或被风控限制");
    }

    _logElapsed("_getRoomDataByApi($webRid)", stopwatch);
    return data;
  }

  Future<dynamic> _requestRoomDataByApi(
    String webRid, {
    required String cookieValue,
  }) async {
    String serverUrl = "https://live.douyin.com/webcast/room/web/enter/";
    final requestHeader = _newRequestHeaders(
      cookieValue: cookieValue,
      referer: "https://live.douyin.com/$webRid",
    );

    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "aid": '6383',
        "app_name": "douyin_web",
        "live_id": '1',
        "device_platform": "web",
        "language": "zh-CN",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Chrome",
        "browser_version": "125.0.0.0",
        "web_rid": webRid,
        "msToken": "",
      },
    );
    final signStopwatch = Stopwatch()..start();
    var requestUrl = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent);
    _logElapsed("_getRoomDataByApi($webRid) a_bogus", signStopwatch);

    final requestStopwatch = Stopwatch()..start();
    var result = await HttpClient.instance.getJson(
      requestUrl,
      header: requestHeader,
    );
    _logElapsed("_getRoomDataByApi($webRid) request", requestStopwatch);
    return result;
  }

  /// 通过roomId获取直播间信息
  /// - [roomId] 直播间ID
  Future<Map> _getRoomDataByRoomId(String roomId) async {
    final result = await _requestWithCustomCookieFallback(
      label: "抖音 reflow 接口",
      request: (cookieValue) =>
          _requestRoomDataByRoomId(roomId, cookieValue: cookieValue),
      hasData: _hasReflowRoomData,
    );
    return result;
  }

  Future<dynamic> _requestWithCustomCookieFallback({
    required String label,
    required Future<dynamic> Function(String cookieValue) request,
    required bool Function(dynamic result) hasData,
  }) async {
    final customPlaybackCookie = _customPlaybackCookie();
    dynamic result;
    try {
      result = await request(_playbackCookie());
    } catch (error) {
      if (customPlaybackCookie.isEmpty) {
        rethrow;
      }
      _logDebug("$label 使用自定义 Cookie 请求失败，使用匿名 ttwid 重试：$error");
      return request(_defaultPlaybackCookie());
    }
    if (customPlaybackCookie.isEmpty || hasData(result)) {
      return result;
    }
    _logDebug("$label 返回空数据，使用匿名 ttwid 重试一次");
    return request(_defaultPlaybackCookie());
  }

  Future<dynamic> _requestRoomDataByRoomId(
    String roomId, {
    required String cookieValue,
  }) {
    return HttpClient.instance.getJson(
      'https://webcast.amemv.com/webcast/room/reflow/info/',
      queryParameters: {
        "type_id": 0,
        "live_id": 1,
        "room_id": roomId,
        "sec_user_id": "",
        "version_code": "99.99.99",
        "app_id": 6383,
      },
      header: _newRequestHeaders(cookieValue: cookieValue),
    );
  }

  bool _hasWebRoomData(dynamic result) {
    if (result is! Map) {
      return false;
    }
    final data = result["data"];
    if (data is! Map) {
      return false;
    }
    final rooms = data["data"];
    return rooms is List && rooms.any((room) => room is Map && room.isNotEmpty);
  }

  bool _hasReflowRoomData(dynamic result) {
    if (result is! Map) {
      return false;
    }
    final data = result["data"];
    if (data is! Map) {
      return false;
    }
    final room = data["room"];
    return room is Map && room.isNotEmpty;
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    final stopwatch = Stopwatch()..start();
    List<LivePlayQuality> qualities = [];

    try {
      var liveCoreData = detail.data["live_core_sdk_data"];

      if (liveCoreData == null) {
        return qualities;
      }

      var pullData = liveCoreData["pull_data"];

      if (pullData == null) {
        return qualities;
      }

      var options = pullData["options"];

      var qulityList = options?["qualities"];

      var streamData = pullData["stream_data"]?.toString() ?? "";

      if (!streamData.startsWith('{')) {
        var flvList = (detail.data["flv_pull_url"] as Map).values
            .cast<String>()
            .toList();
        var hlsList = (detail.data["hls_pull_url_map"] as Map).values
            .cast<String>()
            .toList();
        for (var quality in qulityList) {
          int level = quality["level"];
          List<String> urls = [];
          var flvIndex = flvList.length - level;
          if (flvIndex >= 0 && flvIndex < flvList.length) {
            urls.add(flvList[flvIndex]);
          }
          var hlsIndex = hlsList.length - level;
          if (hlsIndex >= 0 && hlsIndex < hlsList.length) {
            urls.add(hlsList[hlsIndex]);
          }
          var qualityItem = LivePlayQuality(
            quality: quality["name"],
            sort: level,
            data: urls,
          );
          if (urls.isNotEmpty) {
            qualities.add(qualityItem);
          }
        }
      } else {
        var qualityData = json.decode(streamData)["data"] as Map;

        for (var quality in qulityList) {
          List<String> urls = [];

          var flvUrl = qualityData[quality["sdk_key"]]?["main"]?["flv"]
              ?.toString();

          if (flvUrl != null && flvUrl.isNotEmpty) {
            urls.add(flvUrl);
          }
          var hlsUrl = qualityData[quality["sdk_key"]]?["main"]?["hls"]
              ?.toString();

          if (hlsUrl != null && hlsUrl.isNotEmpty) {
            urls.add(hlsUrl);
          }

          var qualityItem = LivePlayQuality(
            quality: quality["name"],
            sort: quality["level"],
            data: urls,
          );
          if (urls.isNotEmpty) {
            qualities.add(qualityItem);
          }
        }
      }
    } catch (e, stackTrace) {
      CoreLog.error(e);
      CoreLog.error(stackTrace);
    }
    // var qualityData = json.decode(
    //     detail.data["live_core_sdk_data"]["pull_data"]["stream_data"])["data"];

    qualities.sort((a, b) => b.sort.compareTo(a.sort));
    _logDebug("获取到的画质列表: ${qualities.map((q) => q.quality).toList()}");
    _logElapsed("getPlayQualites(${detail.roomId})", stopwatch);
    return qualities;
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    final stopwatch = Stopwatch()..start();
    // 返回列表的副本，防止外部 clear() 影响原始数据
    final result = LivePlayUrl(urls: List<String>.from(quality.data));
    _logElapsed("getPlayUrls(${detail.roomId}, ${quality.quality})", stopwatch);
    return result;
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    String serverUrl = "https://www.douyin.com/aweme/v1/web/live/search/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "device_platform": "webapp",
        "aid": "6383",
        "channel": "channel_pc_web",
        "search_channel": "aweme_live",
        "keyword": keyword,
        "search_source": "switch_tab",
        "query_correct_type": "1",
        "is_filter_search": "0",
        "from_group_id": "",
        "offset": ((page - 1) * 10).toString(),
        "count": "10",
        "pc_client_type": "1",
        "version_code": "170400",
        "version_name": "17.4.0",
        "cookie_enabled": "true",
        "screen_width": "1980",
        "screen_height": "1080",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Edge",
        "browser_version": "125.0.0.0",
        "browser_online": "true",
        "engine_name": "Blink",
        "engine_version": "125.0.0.0",
        "os_name": "Windows",
        "os_version": "10",
        "cpu_core_num": "12",
        "device_memory": "8",
        "platform": "PC",
        "downlink": "10",
        "effective_type": "4g",
        "round_trip_time": "100",
        "webid": "7382872326016435738",
      },
    );
    //var requlestUrl = await getAbogusUrl(uri.toString());
    var requlestUrl = uri.toString();
    final requestHeaders = await getRequestHeaders(includeFullCookie: true);
    var dyCookie = "";
    final savedCookie = _getCookieHeaderValue(requestHeaders);
    if (savedCookie.isNotEmpty) {
      dyCookie = _ensureCookieEndsWithSemicolon(savedCookie);
    }
    dynamic headResp;
    try {
      headResp = await HttpClient.instance.head(
        'https://live.douyin.com',
        header: requestHeaders,
      );
    } catch (e) {
      if (dyCookie.isEmpty) {
        rethrow;
      }
      _logDebug("抖音搜索预取 Cookie 的 HEAD 请求失败，使用已保存 Cookie 继续：$e");
    }
    if (headResp != null) {
      headResp.headers["set-cookie"]?.forEach((element) {
        var cookie = element.split(";")[0];
        if (cookie.contains("ttwid")) {
          dyCookie += "$cookie;";
        }
        if (cookie.contains("__ac_nonce")) {
          dyCookie += "$cookie;";
        }
      });
    }

    var result = await HttpClient.instance.getJson(
      requlestUrl,
      queryParameters: {},
      header: {
        "Authority": 'www.douyin.com',
        'accept': 'application/json, text/plain, */*',
        'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'cookie': dyCookie,
        'priority': 'u=1, i',
        'referer':
            'https://www.douyin.com/search/${Uri.encodeComponent(keyword)}?type=live',
        'sec-ch-ua':
            '"Microsoft Edge";v="125", "Chromium";v="125", "Not.A/Brand";v="24"',
        'sec-ch-ua-mobile': '?0',
        'sec-ch-ua-platform': '"Windows"',
        'sec-fetch-dest': 'empty',
        'sec-fetch-mode': 'cors',
        'sec-fetch-site': 'same-origin',
        'user-agent': kDefaultUserAgent,
      },
    );
    if (result == "" || result == 'blocked') {
      throw Exception("抖音直播搜索被限制，请稍后再试");
    }
    if (result is Map && result["status_code"] == 2483) {
      throw Exception("抖音搜索需要登录，请在账号管理中通过网页登录或手动配置完整抖音 Cookie");
    }
    var items = <LiveRoomItem>[];
    for (var item in result["data"] ?? []) {
      var itemData = json.decode(item["lives"]["rawdata"].toString());
      var roomItem = LiveRoomItem(
        roomId: itemData["owner"]["web_rid"].toString(),
        title: itemData["title"].toString(),
        cover: itemData["cover"]["url_list"][0].toString(),
        userName: itemData["owner"]["nickname"].toString(),
        online: int.tryParse(itemData["stats"]["total_user"].toString()) ?? 0,
      );
      items.add(roomItem);
    }
    return LiveSearchRoomResult(hasMore: items.length >= 10, items: items);
  }

  String _getCookieHeaderValue(Map<String, dynamic> requestHeaders) {
    return (requestHeaders["Cookie"] ?? requestHeaders["cookie"] ?? "")
        .toString()
        .trim();
  }

  String _ensureCookieEndsWithSemicolon(String value) {
    final cookie = value.trim();
    if (cookie.isEmpty || cookie.endsWith(";")) {
      return cookie;
    }
    return "$cookie;";
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    final result = await searchRooms(keyword, page: page);
    final lowerKeyword = keyword.trim().toLowerCase();
    final rooms = result.items.toList()
      ..sort((a, b) {
        final aMatched = a.userName.toLowerCase().contains(lowerKeyword);
        final bMatched = b.userName.toLowerCase().contains(lowerKeyword);
        if (aMatched != bMatched) {
          return aMatched ? -1 : 1;
        }
        return b.online.compareTo(a.online);
      });
    return LiveSearchAnchorResult(
      hasMore: result.hasMore,
      items: rooms
          .map(
            (room) => LiveAnchorItem(
              roomId: room.roomId,
              userName: room.userName,
              avatar: room.cover,
              liveStatus: true,
            ),
          )
          .toList(),
    );
  }

  /// 抖音直播为单路交织流，服务端不提供纯音频流
  /// （官方"听抖音"只支持点播中长视频，直播不适用）。
  @override
  bool get supportsAudioOnlyStream => false;

  @override
  Future<LivePlayUrl?> getAudioOnlyPlayUrls({
    required LiveRoomDetail detail,
  }) {
    return Future.value(null);
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    final targetId = roomId.trim();
    if (targetId.isEmpty) {
      return false;
    }
    LiveRoomDetail? resolvedDetail;
    try {
      final status = await _tryGetLiveStatus(targetId);
      if (status == true) {
        return true;
      }
      resolvedDetail = await getRoomDetail(roomId: targetId);
      if (resolvedDetail.status) {
        return true;
      }
      if (status != null) {
        return status;
      }
      return resolvedDetail.status;
    } catch (e) {
      if (e is CoreError && e.statusCode == 444) {
        rethrow;
      }
      if (resolvedDetail != null) {
        return resolvedDetail.status;
      }
      CoreLog.error(e);
      return false;
    }
  }

  Future<bool?> _tryGetLiveStatus(String targetId) async {
    final attempts = <Future<bool?> Function()>[];
    if (targetId.length <= 16) {
      attempts.add(() => _getLiveStatusByWebRid(targetId));
      attempts.add(() => _getLiveStatusByRoomId(targetId));
    } else {
      attempts.add(() => _getLiveStatusByRoomId(targetId));
      attempts.add(() => _getLiveStatusByWebRid(targetId));
    }

    Object? lastError;
    for (var i = 0; i < attempts.length; i++) {
      try {
        return await attempts[i]();
      } catch (e) {
        if (e is CoreError && e.statusCode == 444) {
          rethrow;
        }
        lastError = e;
        if (i == 0) {
          _logDebug("getLiveStatus($targetId) 第1路失败，尝试第2路：$e");
        }
      }
    }

    if (lastError != null) {
      CoreLog.error(lastError);
    }
    return null;
  }

  Future<bool> _getLiveStatusByWebRid(String webRid) async {
    final data = await _getRoomDataByApi(webRid);
    final roomList = data["data"];
    if (roomList is List && roomList.isNotEmpty) {
      final roomData = roomList.first;
      return _isDouyinLiveStatus(roomData);
    }
    throw CoreError("抖音直播状态数据为空");
  }

  Future<bool?> _getLiveStatusByRoomId(String roomId) async {
    final roomData = await _getRoomDataByRoomId(roomId);
    final room = roomData["data"]?["room"];
    if (room is! Map) {
      return null;
    }
    final status = _parseDouyinStatus(
      room["status"] ?? room["live_status"] ?? room["room_status"],
    );
    if (status == null) {
      return null;
    }
    if (status == 4) {
      final webRid = room["owner"]?["web_rid"]?.toString().trim() ?? "";
      if (webRid.isNotEmpty) {
        return _getLiveStatusByWebRid(webRid);
      }
    }
    return status == 2;
  }

  bool _isDouyinLiveStatus(dynamic data) {
    if (data is! Map) {
      return false;
    }
    final candidates = <dynamic>[
      data["status"],
      data["live_status"],
      data["room_status"],
      data["status_str"],
    ];
    for (final candidate in candidates) {
      final parsed = _parseDouyinStatus(candidate);
      if (parsed != null) {
        return parsed == 2;
      }
    }
    return false;
  }

  int? _parseDouyinStatus(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim());
    }
    if (value is Map) {
      for (final key in const ["status", "live_status", "room_status"]) {
        final parsed = _parseDouyinStatus(value[key]);
        if (parsed != null) {
          return parsed;
        }
      }
    }
    return null;
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
    LiveRoomDetail? detail,
  }) {
    return Future.value(<LiveSuperChatMessage>[]);
  }

  @override
  Future<List<LiveContributionRankItem>> getContributionRank({
    required String roomId,
    LiveRoomDetail? detail,
  }) async {
    final roomDetail = detail ?? await getRoomDetail(roomId: roomId);
    final webRid = roomDetail.roomId.isNotEmpty ? roomDetail.roomId : roomId;
    final danmakuArgs = roomDetail.danmakuData is DouyinDanmakuArgs
        ? roomDetail.danmakuData as DouyinDanmakuArgs
        : null;

    final roomInfo = await _getRoomDataByApi(webRid);
    final roomList = (roomInfo["data"] as List?) ?? const [];
    if (roomList.isEmpty) {
      return [];
    }
    final roomData = roomList.first;
    final owner = roomData["owner"] ?? roomInfo["user"] ?? {};
    final anchorId =
        owner["id_str"]?.toString() ?? owner["id"]?.toString() ?? "";
    final secAnchorId = owner["sec_uid"]?.toString() ?? "";
    final realRoomId =
        danmakuArgs?.roomId ?? roomData["id_str"]?.toString() ?? "";
    if (anchorId.isEmpty || secAnchorId.isEmpty || realRoomId.isEmpty) {
      return [];
    }

    final requestHeader = await getRequestHeaders();
    requestHeader["Referer"] = "https://live.douyin.com/$webRid";

    final uri = Uri.parse("https://live.douyin.com/webcast/ranklist/audience/")
        .replace(
          queryParameters: {
            "aid": "6383",
            "app_name": "douyin_web",
            "live_id": "1",
            "device_platform": "web",
            "language": "zh-CN",
            "enter_from": "link_share",
            "cookie_enabled": "true",
            "screen_width": "1920",
            "screen_height": "1080",
            "browser_language": "zh-CN",
            "browser_platform": "Win32",
            "browser_name": "Chrome",
            "browser_version": "125.0.0.0",
            "os_name": "Windows",
            "os_version": "10",
            "webcast_sdk_version": "2450",
            "room_id": realRoomId,
            "anchor_id": anchorId,
            "sec_anchor_id": secAnchorId,
            "ignoreToast": "true",
            "rank_type": "30",
            "msToken": "",
          },
        );
    final requestUrl = DouyinSign.getAbogusUrl(
      uri.toString(),
      kDefaultUserAgent,
    );
    final result = await HttpClient.instance.getJson(
      requestUrl,
      header: requestHeader,
    );
    final items = (result["data"]?["ranks"] as List?) ?? const [];
    return items
        .asMap()
        .entries
        .map((entry) {
          final item = entry.value;
          final user = item["user"] ?? {};
          final payGrade = user["pay_grade"] ?? {};
          final fansData = user["fans_club"]?["data"] ?? {};
          final userLevel = int.tryParse(payGrade["level"].toString());
          final fansLevel = int.tryParse(fansData["level"].toString());
          final scoreText = _resolveDouyinRankScore(item);
          final scoreDescription =
              item["score_description"]?.toString().trim() ?? "";
          final exactlyScore = item["exactly_score"]?.toString().trim() ?? "";
          String? scoreDetail;
          if (scoreDescription.isNotEmpty && scoreDescription != scoreText) {
            scoreDetail = scoreDescription;
          } else if (exactlyScore.isNotEmpty && exactlyScore != scoreText) {
            scoreDetail = exactlyScore;
          } else {
            final gapDescription =
                item["gap_description"]?.toString().trim() ?? "";
            scoreDetail = gapDescription.isEmpty ? null : gapDescription;
          }

          return LiveContributionRankItem(
            rank: _resolveDouyinRank(item, entry.key),
            userName: user["nickname"]?.toString() ?? "",
            avatar: _firstImageUrl(user["avatar_thumb"]),
            scoreText: scoreText,
            scoreDetail: scoreDetail,
            userLevel: userLevel,
            userLevelText: userLevel == null || userLevel <= 0
                ? null
                : "财富 $userLevel",
            userLevelIcon: _firstImageUrl(payGrade["new_im_icon_with_level"]),
            fansLevel: fansLevel,
            fansName: fansData["club_name"]?.toString(),
            fansIcon: _pickDouyinBadgeIcon(fansData["badge"]?["icons"]),
          );
        })
        .where((item) => item.userName.trim().isNotEmpty)
        .toList();
  }

  int _resolveDouyinRank(Map item, int index) {
    final parsed = int.tryParse(item["rank"]?.toString() ?? "");
    if (parsed == null || parsed <= 0) {
      return index + 1;
    }
    if (parsed == 1 && index > 0) {
      return index + 1;
    }
    return parsed;
  }

  String _firstImageUrl(dynamic data) {
    if (data is! Map) {
      return "";
    }
    final urls = data["url_list"];
    if (urls is List && urls.isNotEmpty) {
      return urls.first.toString();
    }
    return "";
  }

  String? _pickDouyinBadgeIcon(dynamic icons) {
    if (icons is! Map) {
      return null;
    }
    for (final key in const ["4", "3", "2", "1", "0"]) {
      final url = _firstImageUrl(icons[key]);
      if (url.isNotEmpty) {
        return url;
      }
    }
    for (final value in icons.values) {
      final url = _firstImageUrl(value);
      if (url.isNotEmpty) {
        return url;
      }
    }
    return null;
  }

  String _resolveDouyinRankScore(Map item) {
    final exactlyScore = item["exactly_score"]?.toString().trim() ?? "";
    if (exactlyScore.isNotEmpty) {
      return exactlyScore;
    }
    final scoreDescription = item["score_description"]?.toString().trim() ?? "";
    if (scoreDescription.isNotEmpty) {
      return scoreDescription;
    }
    final score = item["score"]?.toString().trim() ?? "";
    if (score.isNotEmpty) {
      return score;
    }
    final delta = item["delta"]?.toString().trim() ?? "";
    if (delta.isNotEmpty) {
      return delta;
    }
    return "0";
  }

  //生成指定长度的16进制随机字符串
  String generateRandomString(int length) {
    var random = Random.secure();
    var values = List<int>.generate(length, (i) => random.nextInt(16));
    StringBuffer stringBuffer = StringBuffer();
    for (var item in values) {
      stringBuffer.write(item.toRadixString(16));
    }
    return stringBuffer.toString();
  }

  // 生成随机的数字
  int generateRandomNumber(int length) {
    var random = Random.secure();
    var values = List<int>.generate(length, (i) => random.nextInt(10));
    StringBuffer stringBuffer = StringBuffer();
    for (var item in values) {
      stringBuffer.write(item);
    }
    return int.tryParse(stringBuffer.toString()) ??
        Random().nextInt(1000000000);
  }
}
