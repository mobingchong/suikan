class FollowRefreshScope {
  final String scopeKey;
  final bool includeAllNormals;
  final bool automatic;
  final bool allowBackgroundSpecials;
  final String stage;
  final String backgroundStage;

  const FollowRefreshScope({
    required this.scopeKey,
    required this.includeAllNormals,
    required this.automatic,
    required this.allowBackgroundSpecials,
    required this.stage,
    required this.backgroundStage,
  });

  const FollowRefreshScope.all({bool automatic = false})
    : this(
        scopeKey: "all",
        includeAllNormals: true,
        automatic: automatic,
        allowBackgroundSpecials: false,
        stage: "正在刷新关注状态",
        backgroundStage: "",
      );

  /// 带身份后缀的全量轮：语义与 [FollowRefreshScope.all] 相同（都是全量目标、
  /// 都不含背景特别关注），只是 scopeKey 不同。
  ///
  /// 为什么需要：`_refreshStatusTargets` 里有一条「同一 scopeKey 的刷新任务
  /// 仍在进行 → 直接复用旧进度并 return」的合并逻辑，本意是挡住连着点两次
  /// 刷新。但直播间会在自动轮询时把范围临时缩小到侧栏可见项，如果它沿用了
  /// "all" 这个 key，就会和关注页那次仍在跑的全量任务撞车 —— 关注页读到
  /// 一个不会推进的旧进度后直接 return，表现为**页面十几分钟不刷新**。
  const FollowRefreshScope.allScoped({required String keySuffix})
    : this(
        scopeKey: "all#$keySuffix",
        includeAllNormals: true,
        automatic: true,
        allowBackgroundSpecials: false,
        stage: "正在刷新关注状态",
        backgroundStage: "",
      );

  const FollowRefreshScope.page({
    required String scopeKey,
    bool automatic = false,
  }) : this(
         scopeKey: scopeKey,
         includeAllNormals: false,
         automatic: automatic,
         allowBackgroundSpecials: true,
         stage: "正在刷新关注状态",
         backgroundStage: "当前页已完成，后台补充特别关注",
       );
}
