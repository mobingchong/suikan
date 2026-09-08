import 'package:flutter/material.dart';

/// 频道卡标题：优先单行完整显示；一行放不下时**两行尽量等长**分行
/// （避免第一行打满、第二行只剩一两个字的观感）；仍放不下才两行省略。
///
/// 频道名常见「CCTV-1 综合高清 1080P 0001」这类长串，等长分行后每行
/// 观感均衡、更像是对称排布而不是被截断。
class ChannelTitle extends StatelessWidget {
  final String text;
  final TextStyle style;
  const ChannelTitle({Key? key, required this.text, required this.style})
      : super(key: key);

  /// 按 [availableWidth] 测量并返回可换行的文本内容：
  /// - 单行放得下 → 原文本；
  /// - 单行放不下但两行等长能放下 → "上半\n下半"（每行尽量等长）；
  /// - 两行也放不下 → 交给 Text 两行省略。
  static String _wrapToTwoLines(
    TextPainter probe,
    String text,
    double availableWidth,
  ) {
    // 求单行最多能容纳的可见字符数 C。
    final runes = text.runes.toList();
    var c = 0;
    for (var i = 1; i <= runes.length; i++) {
      probe.text = TextSpan(
        text: String.fromCharCodes(runes.take(i).toList()),
        style: probe.text?.style,
      );
      probe.layout(maxWidth: availableWidth);
      if (probe.didExceedMaxLines) {
        break;
      }
      c = i;
    }
    if (c >= runes.length) return text; // 单行其实放得下
    if (runes.length <= c * 2) {
      // 两行等长分配：前半 ceil(T/2)，后半剩余，保证第二行不为空。
      final half = (runes.length + 1) ~/ 2;
      final first = String.fromCharCodes(runes.take(half).toList()).trimRight();
      final second = String.fromCharCodes(runes.skip(half).toList()).trimLeft();
      if (second.isEmpty) {
        // 极端情况：剩余全是空白，退化为单行省略
        return text;
      }
      return '$first\n$second';
    }
    return text; // 两行放不下，交给 maxLines:2 + ellipsis
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth =
            constraints.hasBoundedWidth ? constraints.maxWidth : double.infinity;
        if (!availableWidth.isFinite || availableWidth <= 0) {
          return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);
        }
        final probe = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: availableWidth);
        final String content;
        if (probe.didExceedMaxLines) {
          content = _wrapToTwoLines(probe, text, availableWidth);
        } else {
          content = text;
        }
        return Text(
          content,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
      },
    );
  }
}
