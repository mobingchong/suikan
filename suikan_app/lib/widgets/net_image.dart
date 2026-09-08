import 'dart:async';
import 'dart:io';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class NetImage extends StatelessWidget {
  static const liveCoverCacheName = 'simple_live_live_covers';

  /// 图片缓存上限，启动早期调一次。
  ///
  /// 框架默认 1000 张 / 100MB。一张 1920x1080 的直播封面解码后约 8MB，
  /// 网格页翻两屏就把 100MB 吃满 → 不停淘汰 + 重解码，滑回去要重新等图。
  /// 收到 64MB 后配合「按显示尺寸解码」，单张降到 ~0.5MB，
  /// 64MB 能装上百张，观感无差别而常驻内存明显下降。
  ///
  /// 注意：extended_image 的命名缓存是**独立的 ImageCache 实例**，
  /// 不吃 PaintingBinding 的全局上限，必须单独配。
  static void configureImageCaches() {
    const int maxImages = 400;
    const int maxBytes = 64 << 20;

    final ImageCache globalCache = PaintingBinding.instance.imageCache;
    globalCache.maximumSize = maxImages;
    globalCache.maximumSizeBytes = maxBytes;

    imageCaches
        .putIfAbsent(liveCoverCacheName, () => ImageCache())
      ..maximumSize = 120
      ..maximumSizeBytes = 32 << 20;

    // 磁盘缓存只增不减（见 _pruneDiskImageCache），启动早期异步清理一次，
    // 不阻塞启动。
    unawaited(_pruneDiskImageCache());
  }

  /// 清理 extended_image 的磁盘图片缓存。
  ///
  /// 查证 extended_image_library 5.0.1 源码：磁盘缓存目录是
  /// `getTemporaryDirectory()/cacheimage`（常量名 `cacheImageFolderName`），
  /// 文件名 = `keyToMd5(url)`，读取时只按文件名匹配、**不看时间戳**，也没有
  /// 任何总大小上限或自动清理 —— 直播封面天天更新，旧图会无限堆积。
  ///
  /// 库自带的 `clearDiskCachedImages` 是内部 API（`_extended_network_image_utils_io.dart`
  /// 未从公开入口导出），所以这里按同一目录规则自己清理，不依赖私有 API：
  /// ① 删除超过 [maxAge] 的缓存文件；② 总大小仍超 [maxBytes] 时按最旧优先删。
  /// 全程 catch，清理失败绝不影响启动。
  static Future<void> _pruneDiskImageCache({
    Duration maxAge = const Duration(days: 7),
    int maxBytes = 200 << 20,
  }) async {
    try {
      final dir = Directory(
        p.join((await getTemporaryDirectory()).path, 'cacheimage'),
      );
      if (!dir.existsSync()) {
        return;
      }
      final now = DateTime.now();
      final files = <File>[];
      await for (final entity in dir.list()) {
        if (entity is File) {
          files.add(entity);
        }
      }

      // ① 删除过期文件。
      for (final f in files) {
        try {
          if (now.difference(await f.lastModified()) > maxAge) {
            await f.delete();
          }
        } catch (_) {/* 单个文件失败继续 */}
      }

      // ② 总大小超限时按最旧优先删。
      final remaining = <(File, DateTime)>[];
      var total = 0;
      for (final f in files) {
        try {
          if (!await f.exists()) continue;
          total += await f.length();
          remaining.add((f, await f.lastModified()));
        } catch (_) {/* 单个文件失败继续 */}
      }
      if (total <= maxBytes) {
        return;
      }
      remaining.sort((a, b) => a.$2.compareTo(b.$2));
      for (final (f, _) in remaining) {
        if (total <= maxBytes) break;
        try {
          final size = await f.length();
          await f.delete();
          total -= size;
        } catch (_) {/* 单个文件失败继续 */}
      }
    } catch (_) {/* 清理失败不影响启动 */}
  }

  /// 网格封面：按父布局给到的真实宽度解码，而不是按原图分辨率。
  ///
  /// 封面/海报原图动辄 1920x1080，解码后约 8MB/张，一屏十几张就把图片缓存
  /// 吃满，表现为滑动回去要重新等图 + 常驻内存居高不下。
  ///
  /// 两点保证不会改坏画面：
  /// 1. 只传 [cacheWidth] 一维。ExtendedResizeImage 默认策略是
  ///    ResizeImagePolicy.exact，宽高都传会按 BoxFit.fill 拉伸变形；
  ///    只传一维则保持原图宽高比。
  /// 2. 默认 allowUpscaling=false，原图比显示尺寸小时不会被放大，
  ///    最差情况就是按原图解码，与改动前完全一致。
  ///
  /// 解码宽度量化到 64px 台阶：缩放窗口时不至于每变 1px 就产生新缓存 key
  /// 而反复重解码。向上取整，保证不会解码得比需要的更小。
  static Widget cover({
    required String url,
    double? width,
    double? height,
    BoxFit? fit,
    double borderRadius = 0,
    Map<String, String>? httpHeaders,
    VoidCallback? onLoadFailed,
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
          onLoadFailed: onLoadFailed,
        );
      },
    );
  }

  final String picUrl;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final double borderRadius;
  final int? cacheWidth;
  final int? cacheHeight;
  final bool clearMemoryCacheWhenDispose;
  final String? imageCacheName;
  final Duration? cacheMaxAge;
  final bool cache;
  final Map<String, String>? httpHeaders;
  final VoidCallback? onLoadFailed;
  const NetImage(this.picUrl,
      {this.width,
      this.height,
      this.fit = BoxFit.cover,
      this.borderRadius = 0,
      this.cacheWidth,
      this.cacheHeight,
      this.clearMemoryCacheWhenDispose = false,
      this.imageCacheName,
      this.cacheMaxAge,
      this.cache = true,
      this.httpHeaders,
      this.onLoadFailed,
      Key? key})
      : super(key: key);

  /// 通用浏览器 UA。
  ///
  /// 不传 UA 时 extended_image 会用 Dart 默认 UA（含 "Dart/" 字样），在部分
  /// 图源的风控里属于“异常客户端”特征；用常规浏览器 UA 与 App 内其它
  /// 网络请求保持一致。
  static const String kDefaultImageUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

  /// 按图片域名推断来源站点 → 补对应 Referer。
  ///
  /// 直播封面（B站 keyframe / 虎牙 sScreenshot / 抖音·快手截帧等）都落在各
  /// 平台自己的图片 CDN 上，部分 CDN 做防盗链（校验 Referer），缺 Referer
  /// 会 403 拿不到图；带正确 Referer 同时也更像正常浏览器访问，降低被判定
  /// 为异常抓取的概率。
  ///
  /// 只在调用方**没有显式传** httpHeaders 时补，避免覆盖业务自定义的头
  /// （如播放地址头、fnOS 鉴权头）。
  static Map<String, String>? headersForUrl(String url) {
    if (url.isEmpty) return null;
    final lower = url.toLowerCase();
    String? referer;
    if (lower.contains('hdslb.com') || lower.contains('bilivideo.com')) {
      referer = 'https://live.bilibili.com/';
    } else if (lower.contains('douyin') || lower.contains('byteimg') ||
        lower.contains('amemv.com')) {
      referer = 'https://live.douyin.com/';
    } else if (lower.contains('huya.com')) {
      referer = 'https://www.huya.com/';
    } else if (lower.contains('douyu') || lower.contains('douyucdn')) {
      referer = 'https://www.douyu.com/';
    } else if (lower.contains('kuaishou') || lower.contains('ksyun') ||
        lower.contains('gifshow')) {
      referer = 'https://live.kuaishou.com/';
    }
    if (referer == null) return null;
    return {
      'Referer': referer,
      'User-Agent': kDefaultImageUserAgent,
    };
  }

  @override
  Widget build(BuildContext context) {
    if (picUrl.isEmpty) {
      return Image.asset(
        'assets/images/logo.png',
        width: width,
        height: height,
      );
    }
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
        shape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(borderRadius),
        cache: cache,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        clearMemoryCacheWhenDispose: clearMemoryCacheWhenDispose,
        imageCacheName: imageCacheName,
        cacheMaxAge: cacheMaxAge,
        headers: httpHeaders ?? headersForUrl(pic),
        loadStateChanged: (e) {
          if (e.extendedImageLoadState == LoadState.loading) {
            // 撑满容器尺寸的浅灰占位，而不是一个居中的 24px 灰点。图片区域
            // 在加载完成前有完整的轮廓，观感更好，也避免图片「啪」地弹出。
            // 尺寸直接复用图片的 width/height，保证与最终画面完全一致。
            return Container(
              width: width,
              height: height,
              color: Colors.black12,
              alignment: Alignment.center,
              child: const Icon(Icons.image, color: Colors.grey, size: 24),
            );
          }
          if (e.extendedImageLoadState == LoadState.failed) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              onLoadFailed?.call();
            });
            return Container(
              width: width,
              height: height,
              color: Colors.black12,
              alignment: Alignment.center,
              child: const Icon(
                Icons.broken_image,
                color: Colors.grey,
                size: 24,
              ),
            );
          }
          return null;
        },
      ),
    );
  }
}

/// 解码宽度量化到 64 的整数倍（向上取整）。
int _quantizeDecodeWidth(double devicePixels, [int step = 64]) {
  if (!devicePixels.isFinite || devicePixels <= 0) {
    return step;
  }
  return (devicePixels / step).ceil() * step;
}
