import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/services/bilibili_account_service.dart';
import 'package:simple_live_tv_app/services/bulk_data_import_service.dart';
import 'package:simple_live_tv_app/services/douyin_account_service.dart';
import 'package:simple_live_tv_app/services/kuaishou_account_service.dart';
import 'package:simple_live_tv_app/services/local_storage_service.dart';
import 'package:simple_live_tv_app/services/profile_backup_service.dart';
import 'package:simple_live_tv_app/widgets/sync_progress_dialog.dart';
import 'package:udp/udp.dart';
import 'package:uuid/uuid.dart';

class SyncService extends GetxService {
  static SyncService get instance => Get.find<SyncService>();

  static const int udpPort = 23235;
  static const int httpPort = 23234;

  UDP? udp;
  final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
  final NetworkInfo networkInfo = NetworkInfo();
  HttpServer? server;

  final ipAddress = "".obs;
  final httpRunning = false.obs;
  final httpErrorMsg = "".obs;
  final udpRunning = false.obs;
  final udpErrorMsg = "".obs;

  var deviceId = "";

  // ===== B站状态快照共享（局域网多端同公网 IP → 合并请求防风控）=====
  //
  // 背景：家里四端（手机/iPad/WIN/TV）在同一局域网 = 同一公网 IP，而 B站
  // 风控按 IP 维度计；每端各自轮询关注状态会叠加请求量，把接口级风控推成
  // 真人验证（连累弹幕 token）。这里让"谁先到期谁拉一次"，其余端 60s 内
  // 白拿同一份快照 → 公网请求从 N 份降为约 1 份。
  //
  // 只在既有轮询节奏上多做一次局域网小查询（明文、几百字节），不新增常驻
  // 唤醒、不新增端口；关闭「自动刷新关注」的端完全不参与（也不白拿）。

  /// 已发现的对端地址（UDP 收到任何数据报时按源地址记录）
  final Set<String> _peerAddresses = <String>{};

  /// 本机拉到的 B站状态快照：roomKey("bilibili_123") → 1 未播 / 2 直播中
  final Map<String, int> _biliStatus = <String, int>{};
  DateTime _biliStatusAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 从其它端取到的快照（每 [biliShareQueryInterval] 刷新一次）
  final Map<String, int> _peerBiliStatus = <String, int>{};
  DateTime _peerBiliStatusAt = DateTime.fromMillisecondsSinceEpoch(0);

  Timer? _biliShareTimer;
  bool _biliShareQuerying = false;

  /// UDP 广播发现失败时的纯 TCP 兜底扫描（见 [_discoverPeersByHttp]）。
  bool _httpPeerScanning = false;
  DateTime _lastHttpPeerScanAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _httpPeerScanCooldown = Duration(minutes: 10);
  /// 手上有对端地址却"一个都不通"时允许的较快重扫间隔（见 [_discoverPeersByHttp]）。
  static const Duration _httpPeerScanCooldownStale = Duration(seconds: 30);

  /// 上次发现过的对端地址（持久化）：下次启动**直接先问它们** → 局域网快照
  /// 打开就能"秒显示"，不必每次重新广播/扫网段；地址失效时自然回退重新发现。
  static const String _kLanPeerCacheKey = "LanPeerAddresses";
  String _peerCacheSignature = "";

  /// 对端地址最近一次**成功响应**的时间（`/info` 或 `/bili-status` 返回 200）。
  /// 用于识别"缓存地址已失效"（对端 DHCP 换 IP / 下线），避免永久卡在死地址上。
  final Map<String, DateTime> _peerSeenAt = <String, DateTime>{};

  /// 本轮 TCP 扫描中是否已发现对端（只用于提前结束扫描）。
  /// ⚠️ 不能用 `_hasKnownPeer`：缓存地址失效但还留在列表里时它仍为真，
  /// 会让整个扫描变成空操作（永远发现不到换 IP 后的对端）。
  bool _peerFoundInScan = false;

  /// 拿到其它端的新快照时回调（关注服务注册它 → 立即回写关注列表状态）。
  void Function(Map<String, int> items)? onPeerLiveStatus;

  /// 快照内容是否与上一次相同（避免重复触发回调）。
  Map<String, int> _lastDeliveredPeerStatus = <String, int>{};

  /// 局域网快照查询间隔：60s（明文小包、成本≈0；状态最多 1 分钟在端间同步）。
  static const Duration biliShareQueryInterval = Duration(seconds: 60);
  static const Duration biliShareQueryTimeout = Duration(milliseconds: 800);

  @override
  void onInit() {
    Log.d('SyncService init');
    deviceId = (const Uuid().v4()).split('-').first;
    listenUDP();
    initServer();
    _restorePeerCache();
    _scheduleLiveShareQuery();
    super.onInit();
  }

  /// 快照有效期：**自动/定时轮 3 分钟，手动轮 1 分钟**（2026-09-11 定案，
  /// 与手机/WIN 端保持完全一致）。
  static const Duration biliShareTtl = Duration(minutes: 3);
  static const Duration biliShareTtlManual = Duration(minutes: 1);

  Duration get _biliShareTtl => biliShareTtl;

  /// 本机拉到某房间状态后发布（其它端 60s 内可取用；主动拉取端才发布）。
  void publishLiveStatusItem(String roomKey, int status) {
    _biliStatus[roomKey] = status;
    _biliStatusAt = DateTime.now();
  }

  /// 取"可用"的快照：优先其它端的新鲜快照，其次本机新鲜快照；都没有
  /// 返回 null（调用方自己拉）。只接受新鲜快照，保证状态不会用旧值覆盖。
  ///
  /// [ttl] 可覆盖有效期：手动刷新传 [biliShareTtlManual]（1 分钟，要求够新），
  /// 自动/定时轮不传（默认 [biliShareTtl] = 3 分钟）。
  int? sharedLiveStatus(String roomKey, {Duration? ttl}) {
    final now = DateTime.now();
    final effectiveTtl = ttl ?? _biliShareTtl;
    if (_peerBiliStatusAt.millisecondsSinceEpoch != 0 &&
        now.difference(_peerBiliStatusAt) < effectiveTtl &&
        _peerBiliStatus.containsKey(roomKey)) {
      return _peerBiliStatus[roomKey];
    }
    if (_biliStatusAt.millisecondsSinceEpoch != 0 &&
        now.difference(_biliStatusAt) < effectiveTtl &&
        _biliStatus.containsKey(roomKey)) {
      return _biliStatus[roomKey];
    }
    return null;
  }

  /// 启动局域网快照查询定时器。
  ///
  /// 启动后 **1–3 秒立即查一次**：让"刚打开 APP 就能拿到别的端已拉到的状态"
  /// （否则要等 60s 甚至 10 分钟）。之后每 60s 一次。
  /// 启动局域网快照查询定时器。
  ///
  /// 启动后 **1–3 秒立即查一次**：让"刚打开就有别的端已拉到的状态"（否则要
  /// 等 60s 甚至 10 分钟）。之后每 60s 一次。TV 的 UDP 绑定发生在 [onInit]，
  /// 但仍补 5s / 12s 两次重试，避免首次广播失败要等满 60s。
  void _scheduleLiveShareQuery() {
    _biliShareTimer?.cancel();
    _biliShareTimer = Timer.periodic(biliShareQueryInterval, (_) {
      if (isClosed) {
        return;
      }
      queryPeersLiveStatus();
    });
    final delays = <Duration>[
      const Duration(milliseconds: 300),
      const Duration(seconds: 2),
      const Duration(seconds: 5),
      const Duration(seconds: 12),
    ];
    for (final d in delays) {
      Timer(d, () {
        if (!isClosed) {
          queryPeersLiveStatus();
        }
      });
    }
  }

  /// 问其它端要 B站状态快照（60s 一次，纯局域网明文小包）。
  ///
  /// 关闭「自动刷新关注」的端直接返回：不查询、不白拿（严格尊重开关语义）。
  Future<void> queryPeersLiveStatus() async {
    if (_biliShareQuerying) {
      return;
    }
    if (!AppSettingsController.instance.autoUpdateFollowEnable.value) {
      return;
    }
    _biliShareQuerying = true;
    try {
      // ① 先直接问**已知对端**（含上次启动缓存的地址）→ 命中即秒回填；
      // ② 一个都没回应（首次启动 / 对端换 IP / 对端下线）→ 主动发现后再问一次；
      // ③ 仍无回应 → 清理失效地址（否则 `_hasKnownPeer` 恒真 → 再也不重新发现）。
      var got = await _queryKnownPeers();
      if (!got) {
        await _ensurePeersDiscovered(force: true);
        got = await _queryKnownPeers();
      }
      if (!got) {
        _purgeDeadPeers();
      }
    } catch (e) {
      Log.w("查询局域网直播状态快照失败：$e");
    } finally {
      _biliShareQuerying = false;
      unawaited(_persistPeerCache());
    }
  }

  /// 问一遍当前已知对端，合并它们的快照并回写关注列表。
  /// 返回"是否有任一对端回应"（回应 = HTTP 200，哪怕它自己还没有数据）。
  Future<bool> _queryKnownPeers() async {
    final peers = _peerAddresses.where((ip) => ip.isNotEmpty).toList();
    if (peers.isEmpty) {
      return false;
    }
    final results = await Future.wait(peers.map(_fetchPeerBiliStatus));
    var anyResponse = false;
    for (final r in results) {
      if (r != null) {
        anyResponse = true;
        break;
      }
    }
    // 多端快照 **并集合并**：每个端可能只覆盖自己关注的房间（实测电视 56 条、
    // iPad 17 条），只取"最新那一份"会丢掉其它端覆盖的房间。按快照时间由新到旧
    // 合并，同一房间以更新鲜那端的值优先。
    final now = DateTime.now();
    final ttl = _biliShareTtl;
    final fresh = <_PeerBiliStatus>[
      for (final r in results)
        if (r != null && now.difference(r.at) < ttl) r,
    ];
    if (fresh.isNotEmpty) {
      fresh.sort((a, b) => b.at.compareTo(a.at));
      final merged = <String, int>{};
      for (final snap in fresh) {
        snap.items.forEach((key, value) {
          merged.putIfAbsent(key, () => value);
        });
      }
      final changed = !_sameIntMap(_lastDeliveredPeerStatus, merged);
      _peerBiliStatus
        ..clear()
        ..addAll(merged);
      _peerBiliStatusAt = now;
      if (changed) {
        _lastDeliveredPeerStatus = Map<String, int>.from(merged);
        // 立即回写关注列表（不等本端下一次轮询）
        onPeerLiveStatus?.call(Map<String, int>.from(merged));
      }
    }
    return anyResponse;
  }

  /// 清理"最近从未成功响应"的对端地址（DHCP 换 IP / 设备下线 / 上次会话残留）。
  ///
  /// 不清的话 `_hasKnownPeer` 恒为真 → `_ensurePeersDiscovered` 永远提前返回 →
  /// 局域网里其它端再多也发现不了（旧实现的硬伤：缓存地址失效后永久卡死）。
  void _purgeDeadPeers() {
    final now = DateTime.now();
    final before = _peerAddresses.length;
    _peerAddresses.removeWhere((ip) {
      final seen = _peerSeenAt[ip];
      return seen == null || now.difference(seen) > const Duration(minutes: 5);
    });
    if (_peerAddresses.length != before) {
      _peerCacheSignature = ""; // 内容变了 → 允许重新持久化
      Log.logPrint("清理失效对端地址：$before → ${_peerAddresses.length}");
    }
  }

  static bool _sameIntMap(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) {
      return false;
    }
    for (final e in a.entries) {
      if (b[e.key] != e.value) {
        return false;
      }
    }
    return true;
  }

  Future<_PeerBiliStatus?> _fetchPeerBiliStatus(String address) async {
    final http = HttpClient()..connectionTimeout = biliShareQueryTimeout;
    try {
      final uri = Uri.parse("http://$address:$httpPort/bili-status");
      final req = await http.getUrl(uri).timeout(biliShareQueryTimeout);
      final resp = await req.close().timeout(biliShareQueryTimeout);
      if (resp.statusCode != 200) {
        return null;
      }
      _peerSeenAt[address] = DateTime.now(); // 对端活着（用于失效地址清理）
      final body = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(biliShareQueryTimeout);
      final data = json.decode(body);
      if (data is! Map) {
        return null;
      }
      final atMs = data['at'];
      final items = data['items'];
      if (atMs is! num || items is! Map) {
        return null;
      }
      return _PeerBiliStatus(
        at: DateTime.fromMillisecondsSinceEpoch(atMs.toInt()),
        items: {
          for (final e in items.entries)
            if (e.value is num) "${e.key}": (e.value as num).toInt(),
        },
      );
    } catch (_) {
      // 对端不可达/版本过旧（没有该路由）：视作没有快照，自己拉即可。
      return null;
    } finally {
      http.close(force: true);
    }
  }

  shelf.Response _liveStatusRequest(shelf.Request request) {
    return toJsonResponse({
      'id': deviceId,
      'at': _biliStatusAt.millisecondsSinceEpoch,
      'items': _biliStatus,
    });
  }

  void _finishSyncImport({
    required String successMessage,
    String? eventName,
  }) {
    if (eventName != null) {
      EventBus.instance.emit(eventName, 0);
    }
    SyncProgressDialog.dismiss();
    SmartDialog.showToast(successMessage);
  }

  void listenUDP() async {
    try {
      udp = await UDP.bind(Endpoint.any(port: const Port(udpPort)));
      udpRunning.value = true;
      udpErrorMsg.value = "";
      udp!.asStream().listen(
        (datagram) {
          final str = String.fromCharCodes(datagram!.data);
          Log.i("Received: $str from ${datagram.address}:${datagram.port}");
          final srcIp = datagram.address.address;
          final hasSrc = srcIp.isNotEmpty && srcIp != '0.0.0.0';
          if (str.startsWith('{') && str.endsWith('}')) {
            final data = json.decode(str);
            // 🔴 自己发的广播会被本机 socket 收到：必须按 deviceId 过滤，
            // 否则会把自己记进 _peerAddresses → `_hasKnownPeer` 恒真 →
            // 启动时跳过 TCP 兜底发现（明明局域网里有别的端却不去找）。
            if (data['id'] == deviceId) {
              return;
            }
            // 记录对端地址（用于 60s 一次的直播状态快照查询）
            if (hasSrc) {
              _peerAddresses.add(srcIp);
            }
            if (data["type"] == "hello") {
              if (httpRunning.value) {
                sendInfo();
              }
              return;
            }
          } else if (str == 'Who is Suikan?') {
            if (hasSrc) {
              _peerAddresses.add(srcIp);
            }
            if (httpRunning.value) {
              sendInfo();
            }
          }
        },
        onError: (Object e, StackTrace stackTrace) {
          udpRunning.value = false;
          udpErrorMsg.value = _formatPortError(e, udpPort, "UDP发现服务");
          Log.e("UDP discovery stream failed: $e", stackTrace);
        },
      );
    } catch (e) {
      udpRunning.value = false;
      udpErrorMsg.value = _formatPortError(e, udpPort, "UDP发现服务");
      Log.e("UDP discovery bind failed: $e", StackTrace.current);
    }
  }

  /// UDP 广播 hello：让局域网内其它端发现本端（对端收到后回一条 info 广播）。
  ///
  /// 本端只在"收到 UDP 数据报"时记录对端地址（见 [listenUDP]），所以**必须**
  /// 主动广播一次，否则对端列表恒为空 → 状态快照共享不会发生。
  /// 用 JSON hello（而非 'Who is Suikan?'）是为了同时兼容 APP 端的处理分支。
  void sendHello() async {
    if (udp == null || !udpRunning.value) {
      Log.w("Skip UDP hello broadcast: ${udpErrorMsg.value}");
      return;
    }
    await udp!.send(
      json.encode({"id": deviceId, "type": "hello"}).codeUnits,
      Endpoint.broadcast(port: const Port(udpPort)),
    );
    Log.i("send udp: hello");
  }

  /// 恢复上次发现的对端地址（启动即用 → 快照"秒显示"）。
  void _restorePeerCache() {
    try {
      final raw =
          LocalStorageService.instance.getValue<String>(_kLanPeerCacheKey, "");
      if (raw.isEmpty) {
        return;
      }
      final list = jsonDecode(raw);
      if (list is! List) {
        return;
      }
      for (final e in list) {
        final ip = (e is Map ? e['address'] : e)?.toString() ?? "";
        if (ip.isNotEmpty) {
          _peerAddresses.add(ip);
        }
      }
      Log.logPrint("恢复局域网对端缓存：${_peerAddresses.length} 个");
    } catch (e) {
      Log.d("恢复局域网对端缓存失败：$e");
    }
  }

  /// 持久化当前已知对端（内容不变则不写盘）。
  Future<void> _persistPeerCache() async {
    try {
      final list = _peerAddresses.where((ip) => ip.isNotEmpty).toList()..sort();
      if (list.isEmpty) {
        return;
      }
      final sig = list.join(",");
      if (sig == _peerCacheSignature) {
        return;
      }
      _peerCacheSignature = sig;
      await LocalStorageService.instance.setValue(
        _kLanPeerCacheKey,
        jsonEncode([for (final ip in list) {"address": ip}]),
      );
    } catch (e) {
      Log.d("持久化局域网对端缓存失败：$e");
    }
  }

  /// 查询快照前确保已发现对端（详见 [sendHello]）；拿不到就退化为"自己拉"。
  ///
  /// 先 UDP 广播 hello，**再兜底一次纯 TCP 扫描**——UDP 广播在部分设备/系统
  /// 会被过滤（安卓省电、路由 AP 隔离），TCP 扫描各端行为一致，保证电视能与
  /// 电脑 / 安卓手机 / 安卓平板 / iPhone / iPad 相互发现。
  /// [force] = true 时忽略"已知对端"直接重新发现（用于对端地址已失效的场景）。
  /// **UDP hello 与 TCP /24 扫描并行**：UDP 广播在部分网络/设备会被过滤（安卓
  /// 省电、路由 AP 隔离），TCP 扫描各端行为一致 → 并行可避免"先白等 UDP 再扫"。
  Future<void> _ensurePeersDiscovered({bool force = false}) async {
    if (!force && _hasKnownPeer) {
      return;
    }
    sendHello();
    await Future.wait([
      Future<void>.delayed(const Duration(milliseconds: 250)),
      _discoverPeersByHttp(),
    ]);
  }

  bool get _hasKnownPeer => _peerAddresses.any((ip) => ip.isNotEmpty);

  /// 纯 TCP 兜底发现：对同网段 /24 并发探一次 `GET /info`。
  ///
  /// 冷却分级：**手上有对端地址却都不通**（典型：对端 DHCP 换 IP）→ 30s 后即可
  /// 重扫；**完全没有对端**（家里只有本机）→ 10 分钟冷却，不必每分钟扫全网段。
  Future<void> _discoverPeersByHttp() async {
    if (_httpPeerScanning) {
      return;
    }
    final cooldown =
        _hasKnownPeer ? _httpPeerScanCooldownStale : _httpPeerScanCooldown;
    if (DateTime.now().difference(_lastHttpPeerScanAt) < cooldown) {
      return;
    }
    _httpPeerScanning = true;
    _peerFoundInScan = false;
    _lastHttpPeerScanAt = DateTime.now();
    try {
      final prefix = _subnetPrefix(await getLocalIP());
      if (prefix == null) {
        return;
      }
      for (var start = 1; start <= 254; start += 64) {
        final end = (start + 64 > 255) ? 255 : start + 64;
        await Future.wait([
          for (var i = start; i < end; i++) _probePeerInfo("$prefix.$i"),
        ]);
        if (_peerFoundInScan) {
          break;
        }
      }
    } catch (e) {
      Log.d("HTTP 兜底发现对端失败：$e");
    } finally {
      _httpPeerScanning = false;
    }
  }

  /// 从本机 IP（可能是 `a;b;c` 多网卡形式）取 /24 前缀。
  String? _subnetPrefix(String raw) {
    for (final part in raw.split(';')) {
      final ip = part.trim();
      if (ip.isEmpty || ip.startsWith('127.')) {
        continue;
      }
      final seg = ip.split('.');
      if (seg.length == 4) {
        return "${seg[0]}.${seg[1]}.${seg[2]}";
      }
    }
    return null;
  }

  /// 探测单个 IP 是否是随看端（`GET /info` 返回 200 且带别人的 deviceId）。
  Future<void> _probePeerInfo(String ip) async {
    if (_peerFoundInScan) {
      return;
    }
    final http = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 300);
    try {
      final req = await http
          .getUrl(Uri.parse("http://$ip:$httpPort/info"))
          .timeout(const Duration(milliseconds: 300));
      final resp = await req.close().timeout(const Duration(milliseconds: 300));
      if (resp.statusCode != 200) {
        return;
      }
      final body = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(milliseconds: 300));
      final data = json.decode(body);
      if (data is! Map) {
        return;
      }
      final id = data['id']?.toString() ?? "";
      if (id.isEmpty || id == deviceId) {
        return;
      }
      _peerSeenAt[ip] = DateTime.now(); // 对端活着（用于失效地址清理）
      _peerFoundInScan = true;
      if (_peerAddresses.add(ip)) {
        Log.logPrint("HTTP 兜底发现对端：$ip ($id)");
      }
    } catch (_) {
      // 端口未开 / 不是随看端 / 超时：静默忽略
    } finally {
      http.close(force: true);
    }
  }

  void sendInfo() async {
    if (udp == null || !udpRunning.value) {
      Log.w("Skip UDP info broadcast: ${udpErrorMsg.value}");
      return;
    }
    final name = await getDeviceName();
    final data = {
      "id": deviceId,
      "type": "tv",
      "name": name,
    };

    await udp!.send(
      json.encode(data).codeUnits,
      Endpoint.broadcast(port: const Port(udpPort)),
    );
    Log.i("send udp info: $data");
  }

  Future<String> getLocalIP() async {
    var ip = await networkInfo.getWifiIP();
    if (ip == null || ip.isEmpty) {
      final interfaces = await NetworkInterface.list();
      final ipList = <String>[];
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.type.name == 'IPv4' &&
              !addr.address.startsWith('127') &&
              !addr.isMulticast &&
              !addr.isLoopback) {
            ipList.add(addr.address);
            break;
          }
        }
      }
      ip = ipList.join(';');
    }
    return ip;
  }

  Future<String> getDeviceName() async {
    var name = "Suikan-TV";
    if (Platform.isAndroid) {
      final info = await deviceInfo.androidInfo;
      name = info.model;
    } else if (Platform.isIOS) {
      final info = await deviceInfo.iosInfo;
      name = info.name;
    } else if (Platform.isMacOS) {
      final info = await deviceInfo.macOsInfo;
      name = info.computerName;
    } else if (Platform.isLinux) {
      final info = await deviceInfo.linuxInfo;
      name = info.name;
    } else if (Platform.isWindows) {
      final info = await deviceInfo.windowsInfo;
      name = info.userName;
    }
    return name;
  }

  void initServer() async {
    try {
      final serverRouter = Router()
        ..get('/', _helloRequest)
        ..get('/info', _infoRequest)
        // B站状态快照（只读）：供同局域网的其它端白拿，合并 B站 公网请求。
        ..get('/bili-status', _liveStatusRequest)
        ..get('/live-status', _liveStatusRequest)
        ..post('/sync/follow', _syncFollowUserRequest)
        ..post('/sync/tag', _syncFollowUserTagRequest)
        ..post('/sync/history', _syncHistoryRequest)
        ..post('/sync/blocked_word', _syncBlockedWordRequest)
        ..post('/sync/account/bilibili', _syncBiliAccountRequest)
        ..post('/sync/account/douyin', _syncDouyinAccountRequest)
        ..post('/sync/account/kuaishou', _syncKuaishouAccountRequest)
        ..post('/sync/profile', _syncProfileRequest);

      server = await shelf_io.serve(
        serverRouter,
        InternetAddress.anyIPv4,
        httpPort,
      );
      server!.autoCompress = true;

      httpRunning.value = true;
      ipAddress.value = await getLocalIP();

      Log.d('Serving at http://${ipAddress.value}:${server!.port}');
    } catch (e) {
      httpRunning.value = false;
      httpErrorMsg.value = _formatPortError(e, httpPort, "HTTP同步服务");
      Log.e("HTTP sync server bind failed: $e", StackTrace.current);
    }
  }

  String get lanErrorMsg {
    final messages = <String>[
      if (httpErrorMsg.value.trim().isNotEmpty) httpErrorMsg.value,
      if (udpErrorMsg.value.trim().isNotEmpty) udpErrorMsg.value,
    ];
    return messages.join("；");
  }

  String _formatPortError(Object error, int port, String serviceName) {
    final text = error.toString();
    final lower = text.toLowerCase();
    if (text.contains("10048") ||
        lower.contains("address already in use") ||
        lower.contains("failed to create server socket") ||
        lower.contains("only one usage of each socket address")) {
      return "$port 端口已被占用，请关闭其他随看窗口后重试";
    }
    return "$serviceName启动失败：$text";
  }

  shelf.Response _helloRequest(shelf.Request request) {
    return toJsonResponse({
      'status': true,
      'message': 'http server is running...',
      "version": '随看 v${Utils.packageInfo.version}',
      "app": "Suikan",
      "type": "tv",
      "platform": Platform.operatingSystem,
    });
  }

  Future<shelf.Response> _infoRequest(shelf.Request request) async {
    final name = await getDeviceName();
    return toJsonResponse({
      "id": deviceId,
      'type': 'tv',
      'name': name,
      'version': Utils.packageInfo.version,
      'address': ipAddress.value,
      'port': httpPort,
    });
  }

  Future<shelf.Response> _syncFollowUserRequest(shelf.Request request) async {
    try {
      final overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');
      final chunk = _readSyncChunk(request);
      final body = await request.readAsString();

      SyncProgressDialog.show(_stageProgress("接收关注", chunk));
      final stopwatch = Stopwatch()..start();
      Log.d('_syncFollowUserRequest: ${body.length} bytes');

      final jsonBody = json.decode(body);
      if (jsonBody is! List) {
        throw const FormatException("关注列表格式不是数组");
      }

      final result = await BulkDataImportService.importFollowUsers(
        jsonBody,
        overwrite: overlay == 1,
        onProgress: _wrapChunkProgress(chunk),
      );

      stopwatch.stop();
      Log.i(
        "局域网同步关注完成：${result.logSummary} bytes=${body.length} elapsed=${stopwatch.elapsedMilliseconds}ms",
      );

      if (chunk.isLastChunk) {
        _finishSyncImport(
          successMessage: result.overwriteGuarded
              ? '对端关注数据明显少于本地，已按合并处理（本地数据已保留）'
              : '已同步关注用户列表（${chunk.itemTotal > 0 ? chunk.itemTotal : result.imported} 条）',
          eventName: Constant.kUpdateFollow,
        );
      }

      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      SyncProgressDialog.dismiss();
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  Future<shelf.Response> _syncFollowUserTagRequest(
    shelf.Request request,
  ) async {
    try {
      final chunk = _readSyncChunk(request);
      final body = await request.readAsString();
      SyncProgressDialog.show(_stageProgress("接收标签", chunk));
      Log.d('_syncFollowUserTagRequest: ${body.length} bytes');

      final jsonBody = json.decode(body);
      if (jsonBody is! List) {
        throw const FormatException("标签列表格式不是数组");
      }

      SyncProgressDialog.update(
        SyncProgress(
          stage: "接收标签",
          current: chunk.itemEnd,
          total: chunk.itemTotal,
          message: "TV 端暂不支持关注标签，已跳过该部分",
        ),
      );

      if (chunk.isLastChunk) {
        SyncProgressDialog.dismiss();
      }

      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      SyncProgressDialog.dismiss();
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  Future<shelf.Response> _syncHistoryRequest(shelf.Request request) async {
    try {
      final overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');
      final chunk = _readSyncChunk(request);
      final body = await request.readAsString();

      SyncProgressDialog.show(_stageProgress("接收历史", chunk));
      final stopwatch = Stopwatch()..start();
      Log.d('_syncHistoryRequest: ${body.length} bytes');

      final jsonBody = json.decode(body);
      if (jsonBody is! List) {
        throw const FormatException("历史记录格式不是数组");
      }

      final result = await BulkDataImportService.importHistories(
        jsonBody,
        overwrite: overlay == 1,
        onProgress: _wrapChunkProgress(chunk),
      );

      stopwatch.stop();
      Log.i(
        "局域网同步历史完成：${result.logSummary} bytes=${body.length} elapsed=${stopwatch.elapsedMilliseconds}ms",
      );

      if (chunk.isLastChunk) {
        _finishSyncImport(
          successMessage:
              '已同步观看记录（${chunk.itemTotal > 0 ? chunk.itemTotal : result.imported} 条）',
          eventName: Constant.kUpdateHistory,
        );
      }

      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      SyncProgressDialog.dismiss();
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  Future<shelf.Response> _syncBlockedWordRequest(shelf.Request request) async {
    try {
      final overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');
      final chunk = _readSyncChunk(request);
      final body = await request.readAsString();

      SyncProgressDialog.show(_stageProgress("接收屏蔽词", chunk));
      final stopwatch = Stopwatch()..start();
      Log.d('_syncBlockedWordRequest: ${body.length} bytes');

      final jsonBody = json.decode(body);
      if (jsonBody is! List) {
        throw const FormatException("屏蔽词格式不是数组");
      }

      final result = await BulkDataImportService.importShieldValues(
        jsonBody,
        overwrite: overlay == 1,
        onProgress: _wrapChunkProgress(chunk),
      );

      stopwatch.stop();
      Log.i(
        "局域网同步屏蔽词完成：${result.logSummary} bytes=${body.length} elapsed=${stopwatch.elapsedMilliseconds}ms",
      );

      if (chunk.isLastChunk) {
        _finishSyncImport(
          successMessage:
              '已同步弹幕屏蔽词（${chunk.itemTotal > 0 ? chunk.itemTotal : result.imported} 条）',
        );
      }

      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      SyncProgressDialog.dismiss();
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  Future<shelf.Response> _syncBiliAccountRequest(shelf.Request request) async {
    try {
      final body = await request.readAsString();
      Log.d('_syncBiliAccountRequest: $body');
      final jsonBody = json.decode(body);
      if (jsonBody is! Map) {
        throw const FormatException("账号数据格式不是对象");
      }

      final cookie = jsonBody['cookie']?.toString() ?? "";
      if (cookie.isEmpty) {
        throw const FormatException("账号 Cookie 为空");
      }

      BiliBiliAccountService.instance.setCookie(cookie);
      BiliBiliAccountService.instance.loadUserInfo();
      SmartDialog.showToast('已同步哔哩哔哩账号');
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  Future<shelf.Response> _syncDouyinAccountRequest(
    shelf.Request request,
  ) async {
    try {
      final body = await request.readAsString();
      Log.d('_syncDouyinAccountRequest');
      final jsonBody = json.decode(body);
      if (jsonBody is! Map) {
        throw const FormatException("账号数据格式不是对象");
      }

      final cookie = jsonBody['cookie']?.toString() ?? "";
      if (cookie.isEmpty) {
        throw const FormatException("账号 Cookie 为空");
      }

      DouyinAccountService.instance.setCookie(cookie);
      SmartDialog.showToast('已同步抖音账号');
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  Future<shelf.Response> _syncKuaishouAccountRequest(
    shelf.Request request,
  ) async {
    try {
      final body = await request.readAsString();
      final jsonBody = json.decode(body);
      if (jsonBody is! Map) {
        throw const FormatException("账号数据格式不是对象");
      }
      final cookie = jsonBody['cookie']?.toString() ?? '';
      if (cookie.isEmpty) {
        throw const FormatException("账号 Cookie 为空");
      }
      final kww = jsonBody['kww']?.toString() ?? '';
      final expiresAtMs = (jsonBody['cookieExpiresAt'] as num?)?.toInt() ?? 0;
      KuaishouAccountService.instance.setCookie(
        cookie,
        kww: kww.isEmpty ? null : kww,
        expiresAt: expiresAtMs > 0
            ? DateTime.fromMillisecondsSinceEpoch(expiresAtMs)
            : null,
      );
      SmartDialog.showToast('已同步快手账号');
      return toJsonResponse({'status': true, 'message': 'success'});
    } catch (e) {
      return toJsonResponse({'status': false, 'message': e.toString()});
    }
  }

  /// 接收完整配置包（设置/关注/历史/屏蔽词/自定义源/影视库/账号）。
  Future<shelf.Response> _syncProfileRequest(shelf.Request request) async {
    try {
      final overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');
      final body = await request.readAsString();
      SyncProgressDialog.show(const SyncProgress(stage: "接收配置包"));
      final summary = await ProfileBackupService.instance.importProfileJson(
        body,
        overwrite: overlay == 1,
        onProgress: SyncProgressDialog.update,
      );
      SmartDialog.showToast('已同步配置包');
      SyncProgressDialog.dismiss();
      return toJsonResponse({
        'status': true,
        'message': summary.message,
      });
    } catch (e) {
      SyncProgressDialog.dismiss();
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  shelf.Response toJsonResponse(Map<String, dynamic> data) {
    return shelf.Response.ok(
      json.encode(data),
      headers: {
        'Content-Type': 'application/json',
      },
      encoding: Encoding.getByName('utf-8'),
    );
  }

  _SyncChunk _readSyncChunk(shelf.Request request) {
    final params = request.requestedUri.queryParameters;
    return _SyncChunk(
      chunkIndex: int.tryParse(params["chunkIndex"] ?? "") ?? 1,
      chunkTotal: int.tryParse(params["chunkTotal"] ?? "") ?? 1,
      itemStart: int.tryParse(params["itemStart"] ?? "") ?? 0,
      itemEnd: int.tryParse(params["itemEnd"] ?? "") ?? 0,
      itemTotal: int.tryParse(params["itemTotal"] ?? "") ?? 0,
    );
  }

  SyncProgress _stageProgress(String stage, _SyncChunk chunk) {
    final total = chunk.itemTotal > 0 ? chunk.itemTotal : chunk.chunkTotal;
    final current = chunk.itemTotal > 0 ? chunk.itemEnd : chunk.chunkIndex;
    return SyncProgress(
      stage: stage,
      current: current,
      total: total,
      message: chunk.chunkTotal > 1
          ? "接收第 ${chunk.chunkIndex}/${chunk.chunkTotal} 段"
          : stage,
    );
  }

  SyncProgressCallback _wrapChunkProgress(_SyncChunk chunk) {
    return (progress) {
      if (chunk.itemTotal <= 0) {
        SyncProgressDialog.update(progress);
        return;
      }
      final current = (chunk.itemStart + progress.current)
          .clamp(0, chunk.itemTotal)
          .toInt();
      SyncProgressDialog.update(
        SyncProgress(
          stage: progress.stage,
          current: current,
          total: chunk.itemTotal,
          message: "${progress.stage} $current/${chunk.itemTotal}",
        ),
      );
    };
  }

  @override
  void onClose() {
    Log.d('SyncService close');
    udp?.close();
    udpRunning.value = false;
    server?.close(force: true);
    httpRunning.value = false;
    super.onClose();
  }
}

class _SyncChunk {
  final int chunkIndex;
  final int chunkTotal;
  final int itemStart;
  final int itemEnd;
  final int itemTotal;

  const _SyncChunk({
    required this.chunkIndex,
    required this.chunkTotal,
    required this.itemStart,
    required this.itemEnd,
    required this.itemTotal,
  });

  bool get isLastChunk => chunkIndex >= chunkTotal;
}

/// 局域网内其它端发布的 B站状态快照。
class _PeerBiliStatus {
  final DateTime at;
  final Map<String, int> items;
  _PeerBiliStatus({required this.at, required this.items});
}
