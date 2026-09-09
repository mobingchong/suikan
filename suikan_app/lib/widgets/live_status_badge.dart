import 'package:flutter/material.dart';

/// 直播状态胶囊徽章（与 TV 端 AnchorCard 状态徽章同一视觉语言）：
/// - 直播中：绿色实底 + 白字（TV 端 Colors.green 系，醒目直观）
/// - 未开播/未确认：灰色半透明底 + 主题自适应文字
/// 全圆角胶囊，所有端/关注列表/观看记录统一使用。
class LiveStatusBadge extends StatelessWidget {
  /// 0=未确认 1=未开播 2=直播中（与各平台 liveStatus 约定一致）
  final int status;
  final bool showUnknown; // true 时 0(未确认) 也显示，否则非直播中不渲染

  const LiveStatusBadge({
    super.key,
    required this.status,
    this.showUnknown = false,
  });

  bool get _active => status == 2;

  String get _label {
    if (status == 2) return "直播中";
    if (status == 0) return "未确认";
    return "未开播";
  }

  @override
  Widget build(BuildContext context) {
    if (!_active && !showUnknown) {
      return const SizedBox.shrink();
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: _active
            ? Colors.green
            : (dark ? Colors.white.withAlpha(26) : Colors.black.withAlpha(22)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _label,
        style: TextStyle(
          fontSize: 10.5,
          height: 1.3,
          fontWeight: FontWeight.w600,
          color: _active
              ? Colors.white
              : (dark ? Colors.white70 : Colors.black54),
        ),
      ),
    );
  }
}
