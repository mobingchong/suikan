import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/widgets/tv_focus_style.dart';

typedef FocusOnKeyDownCallback = KeyEventResult Function();

/// 高亮组件
class HighlightWidget extends StatelessWidget {
  final AppFocusNode focusNode;
  final Widget child;
  /// 需要把焦点状态传给 child 时用它，替代在父层再套一层 Obx。
  ///
  /// 之前 AnchorCard 在 HighlightWidget 外面又包了一层 Obx 来拿
  /// `focusNode.isFoucsed` 传给卡片内部改文字颜色，导致同一个焦点变化被两层
  /// Obx 各重建一次。改成这里统一在一个 Obx 里驱动，scale/背景/文字颜色同步，
  /// 只重建一次。传了 [childBuilder] 就忽略 [child]。
  final Widget Function(BuildContext context, bool focused)? childBuilder;
  final FocusOnKeyDownCallback? onUpKey;
  final FocusOnKeyDownCallback? onDownKey;
  final FocusOnKeyDownCallback? onLeftKey;
  final FocusOnKeyDownCallback? onRightKey;
  final Function(bool)? onFocusChange;
  final Function()? onTap;
  final Color foucsedColor;
  final Color color;
  final bool autofocus;
  final BorderRadius? borderRadius;
  final double order;
  final bool selected;
  const HighlightWidget({
    required this.focusNode,
    required this.child,
    this.childBuilder,
    this.onUpKey,
    this.onDownKey,
    this.onLeftKey,
    this.onRightKey,
    this.onFocusChange,
    this.onTap,
    this.autofocus = false,
    this.selected = false,
    this.borderRadius,
    this.order = 0.0,
    this.color = Colors.transparent,
    this.foucsedColor = Colors.white,
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return FocusTraversalOrder(
      order: NumericFocusOrder(order),
      child: Focus(
        focusNode: focusNode,
        autofocus: autofocus,
        onFocusChange: onFocusChange,
        onKeyEvent: (node, e) {
          if (e is KeyDownEvent) {
            if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
              return onRightKey?.call() ?? KeyEventResult.ignored;
            }
            if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
              return onLeftKey?.call() ?? KeyEventResult.ignored;
            }
            if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
              return onUpKey?.call() ?? KeyEventResult.ignored;
            }
            if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
              return onDownKey?.call() ?? KeyEventResult.ignored;
            }
            if (e.logicalKey == LogicalKeyboardKey.enter ||
                e.logicalKey == LogicalKeyboardKey.select ||
                e.logicalKey == LogicalKeyboardKey.space) {
              if (onTap == null) {
                return KeyEventResult.ignored;
              }
              onTap!.call();
              return KeyEventResult.handled;
            }
          }

          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: onTap,
          child: Obx(
            () => AnimatedScale(
              scale: focusNode.isFoucsed.value ? 1.1 : 1,
              duration: const Duration(milliseconds: 200),
              child: GestureDetector(
                onTap: onTap,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: borderRadius,
                    boxShadow: focusNode.isFoucsed.value
                        ? [
                            ...AppStyle.highlightShadow,
                            ...TvFocusStyle.glow(
                              Theme.of(context).colorScheme.primary,
                            ),
                          ]
                        : null,
                    // 统一焦点语言：聚焦加主题色描边（与 FocusCard 一致的
                    // 观感，形状圆角跟随各自 borderRadius）。
                    border: focusNode.isFoucsed.value
                        ? Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            width: TvFocusStyle.borderWidth,
                          )
                        : null,
                    color: (focusNode.isFoucsed.value || selected)
                        ? foucsedColor
                        : color,
                  ),
                  // 焦点状态需要传给 child 时，用 childBuilder 在同一层 Obx
                  // 里取，避免父层再套一层 Obx 造成重复重建。
                  child: childBuilder != null
                      ? childBuilder!(context, focusNode.isFoucsed.value)
                      : child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
