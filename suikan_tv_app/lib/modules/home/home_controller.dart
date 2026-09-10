import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/services/db_service.dart';

import 'package:simple_live_tv_app/routes/route_path.dart';

class HomeController extends BaseController {
  var datetime = "00:00".obs;

  /// 兼容字段：退出确认弹窗已移除（2026-09-10 改为双击直接退出），
  /// main.dart 仍引用它做返回键分流，恒为 false。
  static bool exitDialogShowing = false;

  bool doubleClickExit = false;
  Timer? doubleClickTimer;

  @override
  void onInit() {
    initTimer();
    super.onInit();
  }

  @override
  void onClose() {
    doubleClickTimer?.cancel();
    super.onClose();
  }

  /// 主界面返回键处理: 第一次按提示, 2 秒内再按**直接退出**。
  /// （2026-09-10 用户要求：保留双击退出，去掉多余的确认弹窗）
  void handleBack() {
    if (doubleClickExit) {
      doubleClickTimer?.cancel();
      doubleClickExit = false;
      _exitApp();
      return;
    }
    doubleClickExit = true;
    SmartDialog.showToast("再按一次返回键退出应用");
    doubleClickTimer = Timer(const Duration(seconds: 2), () {
      doubleClickExit = false;
      doubleClickTimer?.cancel();
    });
  }

  /// 双击确认后直接退出程序（无弹窗）。
  Future<void> _exitApp() async {
    doubleClickExit = false;
    doubleClickTimer?.cancel();
    // 退出前先排空写队列再关 Hive：Hive.close() 不等挂起写入，若退出时
    // 有关注刷新/源刷新/异步 compact 在写，close 会关掉正在写的箱 →
    // 帧交错损坏 → 二次打开 HiveError/白屏（2.1.21/2.1.22 用户实测）。
    try {
      await DBService.instance.flush();
    } catch (_) {}
    try {
      await Hive.close();
    } catch (_) {}
    SystemNavigator.pop();
  }

  void initTimer() {
    Timer.periodic(const Duration(seconds: 1), (timer) {
      var now = DateTime.now();
      datetime.value =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    });
  }

  void toSync() {
    Get.toNamed(RoutePath.kSync);
  }

  void toFollow() {
    Get.toNamed(RoutePath.kFollow);
  }

  void toSettings() {
    Get.toNamed(RoutePath.kSettings);
  }

  void toHistory() {
    Get.toNamed(RoutePath.kHistory);
  }

  void toHotLive() {
    Get.toNamed(RoutePath.kHotLive);
  }

  void toSearchRoom(String keyword) {
    Get.toNamed(RoutePath.kSearchRoom, arguments: keyword);
  }

  void toSearchAnchor(String keyword) {
    Get.toNamed(RoutePath.kSearchAnchor, arguments: keyword);
  }

  void toCategory() {
    Get.toNamed(RoutePath.kCategory);
  }

  void toLiveChannels() {
    Get.toNamed(RoutePath.kLiveChannels);
  }

  void toVideoLibraries() {
    Get.toNamed(RoutePath.kVideoLibraries);
  }
}
