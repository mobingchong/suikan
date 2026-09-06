import 'package:simple_live_tv_app/app/controller/base_controller.dart';

/// 数据同步页控制器（局域网同步）。
/// 服务启停由 [SyncService] 负责，本控制器仅承载页面状态，
/// 页面主要直接监听 SyncService 的 Rx 状态。
class SyncController extends BaseController {
  @override
  void onInit() {
    super.onInit();
  }
}
