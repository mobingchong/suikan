import 'package:flutter/material.dart';

/// 全局滚动行为：**关闭 iOS 橡皮筋回弹**。
///
/// iOS 默认是 BouncingScrollPhysics（拖到顶/底会弹性回弹）。直播聊天这类
/// 「新消息进来自动贴底」的列表在内容增长时会先触发一次过滚再弹回，观感
/// 就是"新弹幕出来时整体跳一下"。全局改为 Clamping（拖到边界硬停，
/// 与安卓一致），所有列表/聊天都不再回弹。
class NoBounceScrollBehavior extends MaterialScrollBehavior {
  const NoBounceScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const ClampingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      );
}
