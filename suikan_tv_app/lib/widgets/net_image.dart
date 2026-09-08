import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class NetImage extends StatelessWidget {
  /// 图片缓存上限，启动早期调一次。
  ///
  /// 框架默认 1000 张 / 100MB。一张 1920x1080 的封面解码后约 8MB，
  /// 首页/分类页翻几屏就把 100MB 吃满 → 不停淘汰 + 重解码，
  /// 在盒子这类弱 CPU 上表现为焦点移动时封面反复闪烁。
  /// 网格封面已按 400px 宽解码（单张 ~0.36MB），48MB 可容纳上百张，
  /// 观感无差别而常驻内存降到一半以下。
  static void configureImageCaches() {
    const int maxImages = 300;
    const int maxBytes = 48 << 20;

    final ImageCache globalCache = PaintingBinding.instance.imageCache;
    globalCache.maximumSize = maxImages;
    globalCache.maximumSizeBytes = maxBytes;
  }

  /// 网格封面：按父布局给到的真实宽度解码，而不是按原图分辨率。
  ///
  /// 影视库海报/直播封面原图动辄 1920x1080 甚至更高，解码后约 8MB/张，
  /// TV 网格一屏几十张会把图片缓存吃满 → 不停淘汰 + 重解码 → 焦点移动
  /// 时封面反复闪烁、滑回来要重新等图。按显示宽度解码后单张约 0.2~0.5MB，
  /// 同样内存能多驻留几十张，重进页面也能直接命中缓存。
  ///
  /// 只传 [cacheWidth] 一维（保持原图宽高比，不变形）；原图比显示尺寸小
  /// 时不放大，与不传时效果一致。解码宽度量化到 64px 台阶，避免窗口
  /// 缩放时每变 1px 就换缓存 key 反复重解码。
  static Widget cover({
    required String url,
    double? width,
    double? height,
    BoxFit? fit,
    double borderRadius = 0,
    Map<String, String>? httpHeaders,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double boxWidth = constraints.maxWidth;
        final int? decodeWidth = boxWidth.isFinite && boxWidth > 0
            ? _quantizeDecodeWidth(
                boxWidth * MediaQuery.devicePixelRatioOf(context))
            : null;
        return NetImage(
          url,
          width: width ?? double.infinity,
          height: height,
          fit: fit ?? BoxFit.cover,
          borderRadius: borderRadius,
          cacheWidth: decodeWidth,
          httpHeaders: httpHeaders,
        );
      },
    );
  }

  /// 解码宽度量化到 64px 台阶（向上取整），减少缩放导致的缓存 key 抖动。
  static int _quantizeDecodeWidth(double px) {
    const int step = 64;
    final int rounded = (px / step).ceil() * step;
    return rounded.clamp(step, 2560);
  }

  final String picUrl;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final double borderRadius;
  final int? cacheWidth;
  final Map<String, String>? httpHeaders;
  const NetImage(this.picUrl,
      {this.width,
      this.height,
      this.fit = BoxFit.cover,
      this.borderRadius = 0,
      this.cacheWidth,
      this.httpHeaders,
      Key? key})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    var pic = picUrl;
    if (pic.startsWith("//")) {
      pic = 'https:$pic';
    }
    if (pic.startsWith("asset://")) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Image.asset(
          pic.substring("asset://".length),
          fit: fit,
          height: height,
          width: width,
          cacheWidth: cacheWidth,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: ExtendedImage.network(
        pic,
        fit: fit,
        height: height,
        width: width,
        cacheWidth: cacheWidth,
        headers: httpHeaders,
        shape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(borderRadius),
        loadStateChanged: (e) {
          if (e.extendedImageLoadState == LoadState.loading) {
            return const SizedBox();
          }
          if (e.extendedImageLoadState == LoadState.failed) {
            return Icon(
              Icons.broken_image,
              color: Colors.grey,
              size: 24.w,
            );
          }
          return null;
        },
      ),
    );
  }
}
