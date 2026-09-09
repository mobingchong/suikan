/// 宽屏多列列表统一列数算法（关注列表 / 观看记录等头像行卡共用），
/// 保证同屏同列数。每列下限 260 逻辑像素（紧凑头像行卡的实际下限：
/// 头像 48 + 间距 + 两行文字区，再窄文字会过度截断）。
///
/// 口径：传「整屏逻辑宽」（含页面左右 padding，函数内统一扣 16）。
/// 手机竖屏(<520)固定 1 列；越宽列越多，最多 [maxCols] 列。
/// 例：iPad Pro 横屏 1366 → 5 列；2K WIN ≈1872 → 6 列。
int gridColumnCount(
  double screenLogicalWidth, {
  int minCols = 1,
  int maxCols = 8,
}) {
  if (screenLogicalWidth < 520) return 1; // 手机竖屏单列
  const spacing = 12.0;
  const perColumn = 260.0;
  const horizontalPadding = 16.0;
  final usable = screenLogicalWidth - horizontalPadding;
  if (usable <= perColumn) return 1;
  final cols = (usable + spacing) / (perColumn + spacing);
  return cols.floor().clamp(minCols, maxCols);
}

/// [gridColumnCount] 的容错包装：异常输入(非有限值)回退 1 列。
int safeGridColumnCount(double? screenLogicalWidth) {
  final w = screenLogicalWidth;
  if (w == null || !w.isFinite || w <= 0) return 1;
  return gridColumnCount(w);
}
