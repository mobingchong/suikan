import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:logger/logger.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/scroll_behavior.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/desktop_startup_args.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/app/utils/listen_fourth_button.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/other/debug_log_page.dart';
import 'package:simple_live_app/routes/app_pages.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/current_room_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/kuaishou_account_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/profile_backup_service.dart';
import 'package:simple_live_app/services/sync_service.dart';
import 'package:simple_live_app/app/custom_source/custom_source_service.dart';
import 'package:simple_live_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/status/app_loadding_widget.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:window_manager/window_manager.dart';

import 'package:path/path.dart' as p;
import 'package:dynamic_color/dynamic_color.dart';

/// 强制崩溃日志(2026-09-04)：不依赖「写日志文件」设置(默认关)，
/// 任何 Dart 层异常都落一份现场，便于定位偶发闪退。
/// 安卓优先写 /sdcard/Download(免权限且 adb 可读)，桌面写应用数据目录。
Future<void> _writeCrashLog(String tag, Object error, StackTrace? stack) async {
  try {
    final lines = StringBuffer()
      ..writeln('[$tag] ${DateTime.now()}')
      ..writeln('$error');
    if (stack != null) {
      lines.writeln('$stack');
    }
    if (Platform.isAndroid) {
      final f = File('/sdcard/Download/suikan_crash.log');
      if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
      f.writeAsStringSync(lines.toString(), mode: FileMode.append);
    } else {
      try {
        final dir = await getApplicationSupportDirectory();
        final f = File('${dir.path}/suikan_crash.log');
        if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
        f.writeAsStringSync(lines.toString(), mode: FileMode.append);
      } catch (_) {}
    }
  } catch (_) {
    // 崩溃日志写不写得出都不影响主流程
  }
}

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // 图片缓存上限必须在 runApp 之前设好，否则第一屏已经用默认值解码过了
  NetImage.configureImageCaches();
  DesktopStartupArgs.initialize(args);
  // 单实例锁：双开进程会交错写坏同一 Hive 数据文件（2026-08-28 实测事故根因），
  // 检测到已有实例运行直接提示退出。secondary 实例使用独立数据目录，放行。
  if (!isSecondaryDesktopInstance(args) &&
      !await tryAcquireSingleInstanceLock()) {
    showAlreadyRunningMessage();
    exit(0);
  }
  // migrateData（仅桌面、首次）与 initWindow（仅桌面）没有数据依赖，可并行；
  // 手机端两者都是空操作（内部直接 return），并行无副作用。桌面首次启动能
  // 少等一段串行时间。
  //
  // 注意 MediaKit.ensureInitialized() 刻意保持在原位：它是同步的 libmpv 加载，
  // 就算挪到 runApp 之后也依然阻塞在首帧渲染前（runApp 只调度帧、不渲染），
  // 挪动没有收益，反而要承担「首屏就创建 Player」的时序风险。已查证
  // initServices 不碰 media_kit，此处时序安全。
  await Future.wait([migrateData(), initWindow()]);
  MediaKit.ensureInitialized();
  final hivePath = await resolveHivePath(args);
  await Hive.initFlutter(hivePath);
  //初始化服务（任一服务异常都只记录，不阻断启动，避免“只有空白页面”）
  try {
    await initServices(hivePath);
  } catch (e, stack) {
    Log.e('初始化服务失败（已尽量继续启动）: $e', stack);
  }
  // 全局异常兜底：release 模式下未捕获的 widget 异常默认渲染为空白页，
  // 这里改为显示可读错误，避免“只有空白页面”且无从排查。
  FlutterError.onError = (details) {
    _writeCrashLog('FlutterError', details.exception, details.stack);
    Log.e('FlutterError: ${details.exception}', details.stack ?? StackTrace.current);
  };
  ErrorWidget.builder = (details) {
    final msg = details.exception.toString();
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(
            '随看启动出现问题：\n$msg\n\n${details.stack}',
            style: const TextStyle(fontSize: 12, color: Colors.black87),
          ),
        ),
      ),
    );
  };
  // 🔴 引擎级/异步未捕获异常兜底（2026-09-04）：
  // release 下任何 zone 外的 async 错误（网络回调 / Timer / Stream / FFI 回调）
  // 默认都会让 Dart isolate 崩溃 → app 直接闪退退出（“偶发闪退、重开就好”的
  // 典型成因）。这里返回 true 吞掉并记录，把“闪退”降级为“只掉一次日志”。
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    _writeCrashLog('uncaught', error, stack);
    Log.e('[uncaught] $error', stack);
    return true;
  };
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  //设置状态栏为透明
  SystemUiOverlayStyle systemUiOverlayStyle = const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
  );
  SystemChrome.setSystemUIOverlayStyle(systemUiOverlayStyle);
  runZonedGuarded<Future<void>>(() async {
    runApp(const MyApp());
    unawaited(setupDesktopWindowLifecycle());
  }, (Object error, StackTrace stack) {
    // zone 内任何未捕获异步错误(网络回调/Timer/Stream/GetX)都到这里，
    // 记录现场并吞掉，避免 isolate 崩溃导致 app 闪退退出。
    _writeCrashLog('zone', error, stack);
    Log.e('[zone error] $error', stack);
  });
}

Future<String?> resolveHivePath(List<String> args) async {
  if (Platform.isAndroid || Platform.isIOS) {
    return null;
  }
  final appSupportDir = await getApplicationSupportDirectory();
  if (!isSecondaryDesktopInstance(args)) {
    return appSupportDir.path;
  }
  final instanceDir = await prepareSecondaryHiveDirectory(appSupportDir);
  return instanceDir.path;
}

/// 单实例锁句柄：进程存活期间持有（仅持有不读取），退出时由 OS 自动释放。
// ignore: unused_element
RandomAccessFile? _singleInstanceLockRaf;

/// 单实例锁（防止双开进程同时写同一 Hive 数据文件导致交错损坏）。
/// 返回 false 表示已有实例在运行，本实例应退出。
/// 仅 Windows 启用；锁文件放系统临时目录（所有版本共享同一把锁）。
Future<bool> tryAcquireSingleInstanceLock() async {
  if (!Platform.isWindows) return true;
  try {
    final lockPath = p.join(
      Directory.systemTemp.path,
      'suikan_single_instance.lock',
    );
    final raf = await File(lockPath).open(mode: FileMode.write);
    // advisory 排他锁（OS 级）：已有实例持有时，这里会阻塞直到超时。
    await raf
        .lock(FileLock.exclusive)
        .timeout(const Duration(milliseconds: 800));
    _singleInstanceLockRaf = raf;
    return true;
  } catch (_) {
    return false;
  }
}

/// Windows 弹提示框（FFI）：告知用户程序已在运行。
void showAlreadyRunningMessage() {
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final messageBoxW = user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint16>, Pointer<Uint16>, Uint32),
        int Function(int, Pointer<Uint16>, Pointer<Uint16>, int)>('MessageBoxW');
    final text = _toUtf16Ptr('随看已经在运行，请勿重复打开。\n\n（同时打开两个窗口会损坏本地数据）');
    final title = _toUtf16Ptr('随看');
    messageBoxW(0, text, title, 0x40); // MB_ICONINFORMATION
    malloc.free(text);
    malloc.free(title);
  } catch (_) {
    // 弹窗失败不阻塞退出。
  }
}

/// 字符串转 UTF-16 指针（以 NUL 结尾），供 Win32 API 使用。
Pointer<Uint16> _toUtf16Ptr(String s) {
  final units = s.codeUnits;
  final raw = malloc.allocate<Uint16>(units.length + 1);
  final list = raw.cast<Uint16>().asTypedList(units.length + 1);
  for (var i = 0; i < units.length; i++) {
    list[i] = units[i];
  }
  list[units.length] = 0;
  return raw;
}

bool isSecondaryDesktopInstance(List<String> args) {
  return DesktopStartupArgs.isSecondaryDesktopInstance;
}

Future<Directory> prepareSecondaryHiveDirectory(Directory sourceDir) async {
  final instancesRoot = Directory(p.join(sourceDir.path, "instances"));
  await instancesRoot.create(recursive: true);
  final instanceDir = Directory(
    p.join(
      instancesRoot.path,
      "${DateTime.now().millisecondsSinceEpoch}_$pid",
    ),
  );
  await instanceDir.create(recursive: true);
  await copyHiveSnapshot(sourceDir, instanceDir);
  await cleanupOldSecondaryHiveDirectories(instancesRoot, instanceDir);
  return instanceDir;
}

Future<void> copyHiveSnapshot(Directory sourceDir, Directory targetDir) async {
  if (!await sourceDir.exists()) {
    return;
  }
  await for (final entity in sourceDir.list(followLinks: false)) {
    if (entity is! File) {
      continue;
    }
    final fileName = p.basename(entity.path);
    final lowerFileName = fileName.toLowerCase();
    if (!lowerFileName.endsWith(".hive") && !lowerFileName.endsWith(".hivec")) {
      continue;
    }
    try {
      await entity.copy(p.join(targetDir.path, fileName));
    } catch (e) {
      Log.logPrint(e);
    }
  }
}

Future<void> cleanupOldSecondaryHiveDirectories(
  Directory instancesRoot,
  Directory currentDir,
) async {
  if (!await instancesRoot.exists()) {
    return;
  }
  final now = DateTime.now();
  await for (final entity in instancesRoot.list(followLinks: false)) {
    if (entity is! Directory || entity.path == currentDir.path) {
      continue;
    }
    try {
      final stat = await entity.stat();
      if (now.difference(stat.modified) > const Duration(days: 2)) {
        await entity.delete(recursive: true);
      }
    } catch (e) {
      Log.logPrint(e);
    }
  }
}

/// 将Hive数据迁移到Application Support
Future migrateData() async {
  if (Platform.isAndroid || Platform.isIOS) {
    return;
  }
  var hiveFileList = [
    "followuser",
    //旧版本写错成hostiry了
    "hostiry",
    "followusertag",
    "localstorage",
    "danmushield",
    "danmushieldpreset",
  ];
  try {
    var newDir = await getApplicationSupportDirectory();
    var hiveFile = File(p.join(newDir.path, "followuser.hive"));
    if (await hiveFile.exists()) {
      return;
    }

    var oldDir = await getApplicationDocumentsDirectory();
    for (var element in hiveFileList) {
      var oldFile = File(p.join(oldDir.path, "$element.hive"));
      if (await oldFile.exists()) {
        var fileName = "$element.hive";
        if (element == "hostiry") {
          fileName = "history.hive";
        }
        await oldFile.copy(p.join(newDir.path, fileName));
        await oldFile.delete();
      }
      var lockFile = File(p.join(oldDir.path, "$element.lock"));
      if (await lockFile.exists()) {
        await lockFile.delete();
      }
    }
  } catch (e) {
    Log.logPrint(e);
  }
}

Future initWindow() async {
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    return;
  }
  await windowManager.ensureInitialized();
  Log.i("桌面窗口初始化");
  WindowOptions windowOptions = const WindowOptions(
    minimumSize: Size(280, 280),
    title: "随看",
  );
  await windowManager.waitUntilReadyToShow(windowOptions);
}

final _desktopWindowLifecycle = _DesktopWindowLifecycle();

Future<void> setupDesktopWindowLifecycle() async {
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    return;
  }
  windowManager.addListener(_desktopWindowLifecycle);
  if (Platform.isWindows) {
    await windowManager.setPreventClose(true);
  }
  await WidgetsBinding.instance.endOfFrame;
  Log.i("准备显示桌面窗口");
  await _desktopWindowLifecycle.restoreWindowPlacement();
  await windowManager.show();
  await windowManager.focus();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await windowManager.show();
  await windowManager.focus();
  Log.i("桌面窗口已请求显示");
}

class _DesktopWindowLifecycle with WindowListener {
  bool _closing = false;
  bool _restoring = false;
  Timer? _saveTimer;

  Future<void> restoreWindowPlacement() async {
    _restoring = true;
    try {
      final startupBounds = DesktopStartupArgs.startupWindowBounds;
      if (startupBounds != null) {
        if (DesktopStartupArgs.startupFramelessTile) {
          await _applyFramelessTileChrome();
        }
        await windowManager.setBounds(startupBounds);
        return;
      }
      final settings = AppSettingsController.instance;
      if (settings.rememberWindowPlacement.value) {
        final bounds = await _validSavedBounds();
        if (bounds != null) {
          await windowManager.setBounds(bounds);
        } else {
          await windowManager.center();
        }
        if (settings.desktopWindowMaximized) {
          await windowManager.maximize();
        }
      } else {
        await windowManager.center();
      }
    } catch (e) {
      Log.logPrint(e);
      await windowManager.center();
    } finally {
      _restoring = false;
    }
  }

  Future<Rect?> _validSavedBounds() async {
    final bounds = AppSettingsController.instance.getDesktopWindowBounds();
    if (bounds == null) {
      return null;
    }
    final displays = await screenRetriever.getAllDisplays();
    for (final display in displays) {
      final displayRect = Rect.fromLTWH(
        display.visiblePosition?.dx ?? 0,
        display.visiblePosition?.dy ?? 0,
        display.visibleSize?.width ?? display.size.width,
        display.visibleSize?.height ?? display.size.height,
      );
      if (!displayRect.contains(bounds.center)) {
        continue;
      }
      final width = bounds.width.clamp(280.0, displayRect.width).toDouble();
      final height = bounds.height.clamp(280.0, displayRect.height).toDouble();

      // Windows DWM may report edge-snapped frames a few pixels outside the
      // visible work area (commonly around -7/-8). Keep that relative overhang
      // so restoring an edge-snapped window does not leave an 8px gap.
      const maxDwmOverhang = 16.0;
      final minLeft =
          displayRect.left - (Platform.isWindows ? maxDwmOverhang : 0.0);
      final maxLeft = displayRect.right -
          width +
          (Platform.isWindows ? maxDwmOverhang : 0.0);
      final minTop =
          displayRect.top - (Platform.isWindows ? maxDwmOverhang : 0.0);
      final maxTop = displayRect.bottom -
          height +
          (Platform.isWindows ? maxDwmOverhang : 0.0);

      final left = bounds.left.clamp(minLeft, maxLeft).toDouble();
      final top = bounds.top.clamp(minTop, maxTop).toDouble();
      return Rect.fromLTWH(left, top, width, height);
    }
    return null;
  }

  Future<void> _applyFramelessTileChrome() async {
    if (!Platform.isWindows) {
      return;
    }
    try {
      await windowManager.setAsFrameless();
      await windowManager.setHasShadow(false);
      await windowManager.setResizable(false);
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    } catch (e) {
      Log.logPrint(e);
    }
  }

  void _scheduleSave() {
    if (_restoring || _closing) {
      return;
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 150), () {
      unawaited(saveWindowPlacement());
    });
  }

  Future<void> saveWindowPlacement() async {
    if (!AppSettingsController.instance.rememberWindowPlacement.value) {
      return;
    }
    try {
      final liveRoom = Get.isRegistered<LiveRoomController>()
          ? Get.find<LiveRoomController>()
          : null;
      if (liveRoom?.smallWindowState.value == true ||
          await windowManager.isFullScreen()) {
        return;
      }
      final maximized = await windowManager.isMaximized();
      final previousBounds =
          AppSettingsController.instance.getDesktopWindowBounds();
      final bounds = maximized
          ? previousBounds ?? await windowManager.getBounds()
          : await windowManager.getBounds();
      await AppSettingsController.instance.setDesktopWindowPlacement(
        bounds: bounds,
        maximized: maximized,
      );
    } catch (e) {
      Log.logPrint(e);
    }
  }

  @override
  void onWindowMoved() {
    _scheduleSave();
  }

  @override
  void onWindowResized() {
    _scheduleSave();
  }

  @override
  void onWindowMaximize() {
    _scheduleSave();
  }

  @override
  void onWindowUnmaximize() {
    _scheduleSave();
  }

  @override
  void onWindowClose() {
    if (_closing) {
      return;
    }
    _closing = true;
    unawaited(_closeAppGracefully());
  }

  Future<void> _closeAppGracefully() async {
    await Utils.closeAppGracefully();
  }

}

Future initServices([String? hivePath]) async {
  Hive.registerAdapter(FollowUserAdapter());
  Hive.registerAdapter(HistoryAdapter());
  Hive.registerAdapter(FollowUserTagAdapter());

  // 包信息（走平台通道，有 IO 开销）与本地存储、数据库三者互相独立，一起并行。
  // Utils.packageInfo 只在日志 / 我的页 / 同步服务里读，db_service 与
  // local_storage_service 都不依赖它，并发安全。
  Log.d("Init PackageInfo + LocalStorage + DBService (并行)");
  final fPackageInfo = PackageInfo.fromPlatform();
  final fLocalStorage = Get.put(LocalStorageService()).init();
  final fDB = Get.put(DBService()).init(hivePath: hivePath);
  Utils.packageInfo = await fPackageInfo;
  await Future.wait([fLocalStorage, fDB]);
  // 自定义源 / 飞牛影视库必须在 runApp 之前完成注册：
  // 否则首页/分类按 Sites.browseSites 构建标签时站点尚未就绪，
  // 且 IndexedController 启动自动恢复“上次直播间”会找不到 custom_/fnos_ 站点。
  // 两者仅依赖 DBService（已就绪）且互相独立，并行初始化。
  Log.d("Init CustomSource + FnOs (并行)");
  await Future.wait([
    Get.put(CustomSourceService()).init(),
    Get.put(FnOsService()).init(),
  ]);
  Get.put(CurrentRoomService());
  //初始化设置控制器
  Get.put(AppSettingsController());

  Get.put(BiliBiliAccountService());

  Get.put(DouyinAccountService());

  Get.put(KuaishouAccountService());

  Get.put(FollowService());
  Get.put(ProfileBackupService());

  if (DesktopStartupArgs.isSecondaryDesktopInstance) {
    Log.i("Skip SyncService for desktop secondary player instance");
  } else {
    Get.put(SyncService());
  }

  initCoreLog();
}

void initCoreLog() {
  //日志信息
  CoreLog.enableLog =
      !kReleaseMode || AppSettingsController.instance.logEnable.value;
  CoreLog.requestLogType = RequestLogType.short;
  CoreLog.onPrintLog = (level, msg) {
    switch (level) {
      case Level.debug:
        Log.d(msg);
        break;
      case Level.error:
        Log.e(msg, StackTrace.current);
        break;
      case Level.info:
        Log.i(msg);
        break;
      case Level.warning:
        Log.w(msg);
        break;
      default:
        Log.logPrint(msg);
    }
  };
}

class MyApp extends StatelessWidget {
  static const MethodChannel _desktopShortcutChannel =
      MethodChannel("simple_live/desktop_shortcuts");
  static bool _desktopShortcutHandlerBound = false;
  static bool? _desktopShortcutCaptureEnabled;

  /// 全局快捷键监听用的 FocusNode。
  ///
  /// 原先是在下面的 builder 里 `FocusNode()` 就地新建，而 builder 在每次路由
  /// 变化时都会重跑 —— 于是每导航一次就新建一个 FocusNode，旧的那批从来不会
  /// 被释放（StatelessWidget 也没有 dispose 可挂），随使用时间持续累积。
  ///
  /// 全局快捷键本就需要贯穿整个应用生命周期，提为静态单例正合适：只创建
  /// 一次，也就不存在需要释放的问题。
  static final FocusNode _globalShortcutFocusNode = FocusNode();

  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    if (!_desktopShortcutHandlerBound) {
      _desktopShortcutChannel.setMethodCallHandler(
        _handleDesktopShortcutMethod,
      );
      FocusManager.instance.addListener(_syncDesktopShortcutCaptureState);
      _desktopShortcutHandlerBound = true;
    }
    unawaited(_syncDesktopShortcutCaptureState());
    // 主题三件套(isDynamic/styleColor/themeMode)必须放进 Obx：
    // 顶层此前无任何响应式依赖，设置页改完值不会触发 MyApp 重建，
    // 导致“外观设置→显示主题/动态取色/主题色”改了不生效（2026-09-05 用户反馈）。
    return Obx(() {
      bool isDynamicColor = AppSettingsController.instance.isDynamic.value;
      Color styleColor =
          Color(AppSettingsController.instance.styleColor.value);
      final themeMode =
          ThemeMode.values[AppSettingsController.instance.themeMode.value];
      return DynamicColorBuilder(
          builder: ((ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        ColorScheme? lightColorScheme;
        ColorScheme? darkColorScheme;
        if (lightDynamic != null && darkDynamic != null && isDynamicColor) {
          lightColorScheme = lightDynamic;
          darkColorScheme = darkDynamic;
        } else {
          lightColorScheme = ColorScheme.fromSeed(
            seedColor: styleColor,
            brightness: Brightness.light,
          );
          darkColorScheme = ColorScheme.fromSeed(
              seedColor: styleColor, brightness: Brightness.dark);
        }
        return GetMaterialApp(
          title: "随看",
          scrollBehavior: const NoBounceScrollBehavior(),
          theme: AppStyle.lightTheme.copyWith(colorScheme: lightColorScheme),
          darkTheme: AppStyle.darkTheme.copyWith(colorScheme: darkColorScheme),
          themeMode: themeMode,
        initialRoute: RoutePath.kIndex,
        getPages: AppPages.routes,
        routingCallback: (_) {
          unawaited(_syncDesktopShortcutCaptureState());
        },
        //国际化
        locale: const Locale("zh", "CN"),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale("zh", "CN")],
        logWriterCallback: (text, {bool? isError}) {
          Log.addDebugLog(text, (isError ?? false) ? Colors.red : Colors.grey);
          Log.writeLog(text, (isError ?? false) ? Level.error : Level.info);
        },
        // 升级后Android页面过渡动画似乎有BUG
        defaultTransition: Platform.isAndroid ? Transition.cupertino : null,
        //debugShowCheckedModeBanner: false,
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(
          loadingBuilder: ((msg) => const AppLoaddingWidget()),
          //字体大小不跟随系统变化
          builder: (context, child) {
            // Fix for HyperOS windowed-mode Flutter bug:
            // - Values > 50 indicate the bug (windowed mode on HyperOS)
            // - Values == 0 are valid for fullscreen/immersive mode and must NOT be treated as abnormal
            const fallbackPadding = EdgeInsets.only(top: 25, bottom: 35);
            const maxNormalPadding = 50.0;

            final mediaQueryData = MediaQuery.of(context);
            final hasAbnormalPadding = Platform.isAndroid &&
                mediaQueryData.viewPadding.top > maxNormalPadding;

            final fixedMediaQueryData = hasAbnormalPadding
                ? mediaQueryData.copyWith(
                    viewPadding: fallbackPadding,
                    padding: fallbackPadding,
                    textScaler: const TextScaler.linear(1.0),
                  )
                : mediaQueryData.copyWith(
                    textScaler: const TextScaler.linear(1.0));

            return MediaQuery(
              data: fixedMediaQueryData,
              child: Stack(
                children: [
                  //侧键返回
                  RawGestureDetector(
                    excludeFromSemantics: true,
                    gestures: <Type, GestureRecognizerFactory>{
                      FourthButtonTapGestureRecognizer:
                          GestureRecognizerFactoryWithHandlers<
                              FourthButtonTapGestureRecognizer>(
                        () => FourthButtonTapGestureRecognizer(),
                        (FourthButtonTapGestureRecognizer instance) {
                          instance.onTapDown = (TapDownDetails details) async {
                            //如果处于全屏状态，退出全屏
                            if (!Platform.isAndroid && !Platform.isIOS) {
                              if (await windowManager.isFullScreen()) {
                                await windowManager.setFullScreen(false);
                                return;
                              }
                            }
                            Get.back();
                          };
                        },
                      ),
                    },
                    child: KeyboardListener(
                      focusNode: _globalShortcutFocusNode,
                      autofocus: true,
                      onKeyEvent: (KeyEvent event) async {
                        if (event is KeyDownEvent) {
                          await _handleGlobalShortcut(event);
                        }
                      },
                      child: child!,
                    ),
                  ),

                  //查看DEBUG日志按钮
                  //只在Debug、Profile模式显示
                  Visibility(
                    visible: !kReleaseMode,
                    child: Positioned(
                      right: 12,
                      bottom: 100 + context.mediaQueryViewPadding.bottom,
                      child: Opacity(
                        opacity: 0.4,
                        child: ElevatedButton(
                          child: const Text("DEBUG LOG"),
                          onPressed: () {
                            Get.bottomSheet(
                              const DebugLogPage(),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    }));
    });
  }

  static bool get _isDesktopPlatform =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static bool get _hasEditableTextFocus {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    return focusContext != null &&
        focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  static Future<void> _syncDesktopShortcutCaptureState() async {
    if (!_isDesktopPlatform) {
      return;
    }
    final enabled =
        Get.isRegistered<LiveRoomController>() && !_hasEditableTextFocus;
    if (_desktopShortcutCaptureEnabled == enabled) {
      return;
    }
    _desktopShortcutCaptureEnabled = enabled;
    try {
      await _desktopShortcutChannel.invokeMethod(
        "setShortcutCaptureEnabled",
        {"enabled": enabled},
      );
    } catch (e) {
      Log.d("桌面快捷键捕获状态同步失败: $e");
    }
  }

  Future<void> _handleGlobalShortcut(KeyDownEvent event) async {
    unawaited(_syncDesktopShortcutCaptureState());
    if (_hasEditableTextFocus) {
      return;
    }

    LiveRoomController? liveRoomController;
    if (Get.isRegistered<LiveRoomController>()) {
      liveRoomController = Get.find<LiveRoomController>();
    }

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (liveRoomController != null &&
          (liveRoomController.fullScreenState.value ||
              liveRoomController.smallWindowState.value)) {
        await liveRoomController.exitPlayerWindowMode();
        return;
      }
      if (!Platform.isAndroid &&
          !Platform.isIOS &&
          await windowManager.isFullScreen()) {
        await windowManager.setFullScreen(false);
      }
      return;
    }

    if (liveRoomController == null) {
      return;
    }
    final settings = AppSettingsController.instance;
    final logicalKeyId = event.logicalKey.keyId;
    final physicalKey = event.physicalKey;

    bool matches(int shortcut) {
      if (shortcut == AppSettingsController.kShortcutDisabled) {
        return false;
      }
      if (shortcut == logicalKeyId) {
        return true;
      }
      // Prefer physical letter keys as a fallback so desktop shortcuts still
      // work when an IME changes the logical key mapping.
      if (shortcut == LogicalKeyboardKey.keyF.keyId) {
        return physicalKey == PhysicalKeyboardKey.keyF;
      }
      if (shortcut == LogicalKeyboardKey.keyD.keyId) {
        return physicalKey == PhysicalKeyboardKey.keyD;
      }
      if (shortcut == LogicalKeyboardKey.keyM.keyId) {
        return physicalKey == PhysicalKeyboardKey.keyM;
      }
      if (shortcut == LogicalKeyboardKey.keyR.keyId) {
        return physicalKey == PhysicalKeyboardKey.keyR;
      }
      if (shortcut == LogicalKeyboardKey.keyC.keyId) {
        return physicalKey == PhysicalKeyboardKey.keyC;
      }
      if (shortcut == LogicalKeyboardKey.keyQ.keyId) {
        return physicalKey == PhysicalKeyboardKey.keyQ;
      }
      if (shortcut == LogicalKeyboardKey.keyE.keyId) {
        return physicalKey == PhysicalKeyboardKey.keyE;
      }
      if (shortcut == LogicalKeyboardKey.keyT.keyId) {
        return physicalKey == PhysicalKeyboardKey.keyT;
      }
      if (shortcut == LogicalKeyboardKey.keyG.keyId) {
        return physicalKey == PhysicalKeyboardKey.keyG;
      }
      if (shortcut == LogicalKeyboardKey.keyB.keyId) {
        return physicalKey == PhysicalKeyboardKey.keyB;
      }
      if (shortcut == LogicalKeyboardKey.keyN.keyId) {
        return physicalKey == PhysicalKeyboardKey.keyN;
      }
      if (shortcut == LogicalKeyboardKey.arrowUp.keyId) {
        return physicalKey == PhysicalKeyboardKey.arrowUp;
      }
      if (shortcut == LogicalKeyboardKey.arrowDown.keyId) {
        return physicalKey == PhysicalKeyboardKey.arrowDown;
      }
      return false;
    }

    if (matches(settings.liveRoomShortcutFullScreen.value)) {
      await liveRoomController.toggleFullScreen();
      return;
    }
    if (matches(settings.liveRoomShortcutDanmaku.value)) {
      liveRoomController.toggleDanmakuByShortcut();
      return;
    }
    if (matches(settings.liveRoomShortcutMute.value)) {
      await liveRoomController.toggleMute();
      return;
    }
    if (_isDesktopPlatform &&
        matches(settings.liveRoomShortcutVolumeUp.value)) {
      await liveRoomController.adjustDesktopPlayerVolume(5);
      return;
    }
    if (_isDesktopPlatform &&
        matches(settings.liveRoomShortcutVolumeDown.value)) {
      await liveRoomController.adjustDesktopPlayerVolume(-5);
      return;
    }
    if (matches(settings.liveRoomShortcutRefresh.value)) {
      liveRoomController.refreshRoom();
      return;
    }
    if (matches(settings.liveRoomShortcutToggleChat.value) &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      liveRoomController.toggleDesktopSidePanel();
    }
  }

  Future<dynamic> _handleDesktopShortcutMethod(MethodCall call) async {
    if (call.method == "shortcutCaptureStateRequested") {
      await _syncDesktopShortcutCaptureState();
      return null;
    }
    if (call.method != "shortcutKeyDown") {
      return null;
    }
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return null;
    }
    final args = call.arguments;
    if (args is! Map) {
      return null;
    }
    final key = args["key"]?.toString().trim() ?? "";
    if (key.isEmpty) {
      return null;
    }
    await _handleDesktopShortcutByPhysicalKey(key);
    return null;
  }

  Future<void> _handleDesktopShortcutByPhysicalKey(
      String physicalKeyName) async {
    if (_hasEditableTextFocus) {
      return;
    }

    if (!Get.isRegistered<LiveRoomController>()) {
      return;
    }
    final liveRoomController = Get.find<LiveRoomController>();
    final settings = AppSettingsController.instance;

    bool matchesDesktopShortcut(int shortcut) {
      if (shortcut == AppSettingsController.kShortcutDisabled) {
        return false;
      }
      switch (physicalKeyName) {
        case "keyF":
          return shortcut == LogicalKeyboardKey.keyF.keyId;
        case "keyD":
          return shortcut == LogicalKeyboardKey.keyD.keyId;
        case "keyM":
          return shortcut == LogicalKeyboardKey.keyM.keyId;
        case "keyR":
          return shortcut == LogicalKeyboardKey.keyR.keyId;
        case "keyC":
          return shortcut == LogicalKeyboardKey.keyC.keyId;
        case "keyQ":
          return shortcut == LogicalKeyboardKey.keyQ.keyId;
        case "keyE":
          return shortcut == LogicalKeyboardKey.keyE.keyId;
        case "keyT":
          return shortcut == LogicalKeyboardKey.keyT.keyId;
        case "keyG":
          return shortcut == LogicalKeyboardKey.keyG.keyId;
        case "keyB":
          return shortcut == LogicalKeyboardKey.keyB.keyId;
        case "keyN":
          return shortcut == LogicalKeyboardKey.keyN.keyId;
        case "arrowUp":
          return shortcut == LogicalKeyboardKey.arrowUp.keyId;
        case "arrowDown":
          return shortcut == LogicalKeyboardKey.arrowDown.keyId;
        default:
          return false;
      }
    }

    if (matchesDesktopShortcut(settings.liveRoomShortcutFullScreen.value)) {
      await liveRoomController.toggleFullScreen();
      return;
    }
    if (matchesDesktopShortcut(settings.liveRoomShortcutDanmaku.value)) {
      liveRoomController.toggleDanmakuByShortcut();
      return;
    }
    if (matchesDesktopShortcut(settings.liveRoomShortcutMute.value)) {
      await liveRoomController.toggleMute();
      return;
    }
    if (matchesDesktopShortcut(settings.liveRoomShortcutVolumeUp.value)) {
      await liveRoomController.adjustDesktopPlayerVolume(5);
      return;
    }
    if (matchesDesktopShortcut(settings.liveRoomShortcutVolumeDown.value)) {
      await liveRoomController.adjustDesktopPlayerVolume(-5);
      return;
    }
    if (matchesDesktopShortcut(settings.liveRoomShortcutRefresh.value)) {
      liveRoomController.refreshRoom();
      return;
    }
    if (matchesDesktopShortcut(settings.liveRoomShortcutToggleChat.value)) {
      liveRoomController.toggleDesktopSidePanel();
    }
  }
}
