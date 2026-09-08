import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/fnos/fn_os_models.dart';
import 'package:simple_live_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_app/widgets/status/app_empty_widget.dart';

import 'fn_os_add_page.dart';
import 'fn_os_browse_page.dart';

/// 「我的 - NAS影视库」列表页：管理多个飞牛影视服务器（地址+用户名+密码）。
class FnOsListPage extends StatelessWidget {
  const FnOsListPage({Key? key}) : super(key: key);

  Future<void> _remove(FnOsServer server) async {
    final ok = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('删除服务器'),
        content: Text('确定删除「${server.name}」？'),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await FnOsService.instance.removeServer(server.id);
      SmartDialog.showToast('已删除');
    }
  }

  Future<void> _edit(FnOsServer server) async {
    await Get.to(() => FnOsAddPage(editServer: server));
  }

  Future<void> _refresh(FnOsServer server) async {
    SmartDialog.showLoading(msg: '正在刷新影视库…');
    try {
      await FnOsService.instance.refreshServerLibraries(server);
      SmartDialog.dismiss();
      SmartDialog.showToast('已刷新');
    } catch (e) {
      SmartDialog.dismiss();
      SmartDialog.showToast('刷新失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('NAS影视库')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Get.to(() => const FnOsAddPage()),
        tooltip: '添加飞牛影视',
        child: const Icon(Icons.add),
      ),
      body: Obx(
        () {
          final list = FnOsService.instance.servers;
          if (list.isEmpty) {
            return const AppEmptyWidget(
              message: '还没有添加飞牛影视\n点击右下角添加服务器',
              onRefresh: null,
            );
          }
          // 多个影视库时提供聚合入口（与 TV 端「电影电视」一致）：
          // 一次浏览所有服务器的内容，不用逐个切换。
          final withAggregate = list.length > 1;
          final itemCount = list.length + (withAggregate ? 1 : 0);
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: itemCount,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              if (withAggregate && i == 0) {
                return ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  leading: const Icon(Icons.auto_awesome_mosaic_outlined),
                  title: const Text('全部影视'),
                  subtitle: Text('聚合 ${list.length} 个影视库'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Get.to(() => const FnOsBrowsePage(server: null)),
                );
              }
              final server = list[withAggregate ? i - 1 : i];
              return ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                leading: const Icon(Icons.movie_outlined),
                title: Text(server.name.isEmpty ? server.address : server.name),
                subtitle: Text(server.address),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: '编辑',
                      onPressed: () => _edit(server),
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: '刷新',
                      onPressed: () => _refresh(server),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '删除',
                      onPressed: () => _remove(server),
                    ),
                  ],
                ),
                onTap: () => Get.to(() => FnOsBrowsePage(server: server)),
              );
            },
          );
        },
      ),
    );
  }
}
