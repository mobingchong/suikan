import 'package:flutter_screenutil/flutter_screenutil.dart';

/// TV 列表网格列数统一算法 —— 关注列表与观看记录共用，保证两页同屏同列数。
///
/// ⚠️ 尺寸口径：Android TV 盒子 density=320 → 物理 1920x1080 在 Flutter 里
/// 只有 960 逻辑宽（宽 / devicePixelRatio=2）。screenutil 的 .w 以 1920 为
/// 设计基准，在 960 逻辑屏上会自动折半。此处传「整屏逻辑宽」，
/// 内部按 400.w(=该屏 200 逻辑) 为一列下限：
///   960 逻辑(扣 96.w 留白后≈912) → 4 列；
///   更窄的屏自动减列，更宽的屏(4K) 最多 8 列。
int tvListColumnCount(
  double screenLogicalWidth, {
  int minCols = 2,
  int maxCols = 8,
}) {
  final available = screenLogicalWidth - 96.w;
  final perColumn = 400.w;
  return (available / perColumn).floor().clamp(minCols, maxCols);
}
