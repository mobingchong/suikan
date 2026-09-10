/// 轻量房间在线信息：只含「在线人数 + 是否在播」。
///
/// 专供直播间 10 秒在线刷新使用 —— **不取弹幕 token、不取标题/封面**。
///
/// 存在的理由（2026-09-10 B站 弹幕事故）：
/// B站 的 `getInfoByRoom`（房间信息）与 `getDanmuInfo`（弹幕 token）**都属于
/// WBI 接口族**，而直播间每 10 秒的在线刷新原本调的是 `getRoomDetail` ——
/// 等于每 10 秒打 2 次 WBI。手机/WIN/iPad/TV 四端同时看直播时，IP 维度上
/// 可达每分钟几十次 WBI 请求，直接把「接口级风控」推成**真人验证（去网站
/// 验证）**；更糟的是验证之后也恢复不了 —— 因为请求还在按 10 秒的节奏打，
/// 风控立刻复发，连带弹幕 token 一直拿不到（表现：刷新直播间后没有弹幕）。
///
/// 改用**非 WBI 的轻接口**（B站 用 `room/v1/Room/get_info`）后，WBI 请求量
/// 下降几十倍，弹幕 token 只在真正需要时（首次进房/重连）取一次。
class LiveRoomOnlineInfo {
  const LiveRoomOnlineInfo({required this.online, required this.live});

  /// 在线人数（热度）
  final int online;

  /// 是否在播
  final bool live;
}
