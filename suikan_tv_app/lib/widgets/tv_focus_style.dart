import 'package:flutter/material.dart';

/// TV 遥控焦点视觉统一常量。
///
/// 全端（FocusCard 卡片网格 / HighlightWidget 大按钮与列表项 / 各种胶囊与
/// 圆形小按钮）共用同一套「焦点语言」：**聚焦时放大 + 主题色描边 + 主题色
/// 柔和光晕**，保证电视上所有可聚焦元素风格一致、与各自背景形状协调：
///
/// - 大卡片/网格项 → [scaleCard]（放大最少，靠描边+光晕显形）；
/// - 胶囊/季·类型等小条 → [scaleChip]（中等放大）；
/// - 圆形 icon 小按钮（刷新等）→ [scaleIcon]（放大最多，小控件更需显形）。
class TvFocusStyle {
  TvFocusStyle._();

  // ── 放大档位 ──────────────────────────────────────────────
  /// 大卡片/网格项（影视海报卡、直播频道卡、首页大按钮等）。
  static const double scaleCard = 1.06;
  /// 胶囊/小条（季、类型切换等可点文字条）。
  static const double scaleChip = 1.1;
  /// 圆形小按钮（AppBar 的 icon 按钮等）。
  static const double scaleIcon = 1.2;

  // ── 描边 ──────────────────────────────────────────────────
  /// 卡片/按钮聚焦描边宽度。
  static const double borderWidth = 3;
  /// 小控件（icon 按钮）聚焦描边宽度。
  static const double borderWidthSmall = 2.5;

  // ── 光晕 ──────────────────────────────────────────────────
  /// 聚焦光晕模糊半径。
  static const double glowBlur = 16;
  /// 聚焦光晕透明度（0-255）。
  static const int glowAlpha = 90;

  /// 聚焦光晕阴影（主题色）。
  static List<BoxShadow> glow(Color primary) => [
        BoxShadow(
          blurRadius: glowBlur,
          color: primary.withAlpha(glowAlpha),
        ),
      ];
}
