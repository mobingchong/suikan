import 'package:flutter/material.dart';
import 'package:simple_live_tv_app/app/custom_source/custom_source_service.dart';
import 'package:simple_live_tv_app/app/custom_source/m3u_models.dart';
import 'package:simple_live_tv_app/modules/category/category_controller.dart';
import 'package:simple_live_tv_app/routes/app_navigation.dart';

class CustomSourceGroupPage extends StatelessWidget {
  final M3uSource source;
  const CustomSourceGroupPage({Key? key, required this.source})
      : super(key: key);

  List<MapEntry<String, List<M3uChannel>>> _buildGroups() {
    final map = <String, List<M3uChannel>>{};
    for (final c in source.channels) {
      final g = (c.group ?? '未分组').trim().isEmpty
          ? '未分组'
          : (c.group!).trim();
      map.putIfAbsent(g, () => []).add(c);
    }
    final entries = map.entries.toList();
    entries.sort((a, b) => a.key.compareTo(b.key));
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final groups = _buildGroups();
    return Scaffold(
      appBar: AppBar(title: Text(source.name.isEmpty ? source.url : source.name)),
      body: groups.isEmpty
          ? const Center(child: Text('该直播源暂无频道'))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: groups.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final entry = groups[i];
                return ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(entry.key),
                  subtitle: Text('${entry.value.length} 个频道'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    final site =
                        CustomSourceService.instance.siteForSource(source.id);
                    if (site == null) return;
                    AppNavigator.toCategoryDetail(
                      site: site,
                      category: LiveSubCategoryExt(
                        id: entry.key,
                        name: entry.key,
                        parentId: 'custom',
                        site: site,
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}
