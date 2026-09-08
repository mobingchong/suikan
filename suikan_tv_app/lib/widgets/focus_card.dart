import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/widgets/tv_focus_style.dart';

/// TV 遥控焦点卡片：包裹任意可聚焦卡片，获得焦点时显示高亮边框 + 阴影。
/// 解决自定义源/影视库浏览页（从手机端移植）遥控选中看不到位置的问题。
/// 同时处理遥控确认键（Enter/Select）：按下时触发 [onActivate]，
/// 否则只靠卡片内部的 GestureDetector 无法响应遥控确认键。
class FocusCard extends StatefulWidget {
  final Widget child;
  final double radius;

  /// 遥控确认键（Enter/Select/A）触发；不传则只聚焦、不响应确认键。
  final VoidCallback? onActivate;

  /// 是否自动获取初始焦点（列表首项传 true，遥控器进页面即可操作，
  /// 不必先按一次方向键）。
  final bool autofocus;

  /// 获得焦点时的放大倍数（TV 上焦点态更醒目；传 1 关闭）。
  final double focusScale;

  const FocusCard({
    super.key,
    required this.child,
    this.radius = 10,
    this.onActivate,
    this.autofocus = false,
    this.focusScale = TvFocusStyle.scaleCard,
  });

  @override
  State<FocusCard> createState() => _FocusCardState();
}

class _FocusCardState extends State<FocusCard> {
  final AppFocusNode _focusNode = AppFocusNode();

  /// 遥控/键盘确认键集合。
  static final Set<LogicalKeyboardKey> _activateKeys = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  };

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        _activateKeys.contains(event.logicalKey) &&
        widget.onActivate != null) {
      widget.onActivate!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _onKeyEvent,
      onFocusChange: (focused) {
        if (!focused) return;
        // 焦点项滚动到可见区域：网格跨行翻页时，遥控选中的卡片不会停留在
        // 视口外（此前只能靠猜，遥控器往下按会“选中看不见的卡片”）。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
          );
        });
      },
      child: Obx(() {
        final focused = _focusNode.isFoucsed.value;
        return AnimatedScale(
          scale: focused ? widget.focusScale : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              border: Border.all(
                color: focused
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
                width: focused ? TvFocusStyle.borderWidth : 0,
              ),
              boxShadow: focused
                  ? TvFocusStyle.glow(
                      Theme.of(context).colorScheme.primary,
                    )
                  : null,
            ),
            child: widget.child,
          ),
        );
      }),
    );
  }
}
