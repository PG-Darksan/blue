import 'package:flutter/material.dart';

import '../controllers/checker_controller.dart';
import '../models/bluesky_models.dart';
import '../widgets/account_card.dart';
import '../widgets/blocked_muted_sheet.dart';
import '../widgets/jev_settings_dialog.dart';
import '../widgets/login_accounts_sheet.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.controller,
  });

  final CheckerController? controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final CheckerController _controller = widget.controller ?? CheckerController();
  late final bool _ownsController = widget.controller == null;

  final _actorInput = TextEditingController();
  final _filterInput = TextEditingController();
  bool _syncedInitialActor = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _actorInput.dispose();
    _filterInput.dispose();
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  void _onControllerChanged() {
    if (!_syncedInitialActor && _actorInput.text.isEmpty) {
      final candidate = _controller.lastCheckedActor.isNotEmpty
          ? _controller.lastCheckedActor
          : (_controller.activeSession?.handle ?? '');
      if (candidate.isNotEmpty) {
        _syncedInitialActor = true;
        _actorInput.text = candidate;
      }
    }
  }

  void _inspectActor(String handleOrDid) {
    _actorInput.text = handleOrDid;
    FocusScope.of(context).unfocus();
    _controller.checkActor(handleOrDid);
  }

  Future<void> _executeBatch(BatchActionKind kind) async {
    final count = _controller.selectedCount;
    if (count == 0) return;

    if (!_controller.isLoggedIn) {
      await showLoginAccountsSheet(context, _controller);
      return;
    }

    if (kind == BatchActionKind.block) {
      final ok = await confirmBlueskyBlock(
        context,
        targetTitle: '選択したアカウント',
        count: count,
      );
      if (!ok || !mounted) return;
    } else {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('${kind.label}（$count件）'),
          content: Text(
            switch (kind) {
              BatchActionKind.unfollow => '選択中の $count 件のフォローを順番に自動解除しますか？',
              BatchActionKind.follow => '選択中の $count 件を順番に自動フォローしますか？',
              BatchActionKind.mute =>
                '選択中の $count 件を順番にミュートしますか？\n（ミュートは非公開のため相手に通知や公開記録は残りません）',
              BatchActionKind.unmute => '選択中の $count 件のミュートを解除しますか？',
              BatchActionKind.block => '',
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('実行する'),
            ),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
    }

    final result = await _controller.runBatchAction(kind);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.failed == 0
              ? '${kind.label}が完了しました（${result.succeeded}件成功）'
              : '${kind.label}: 成功 ${result.succeeded}件 / 失敗 ${result.failed}件',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final session = c.activeSession;

        return Scaffold(
          appBar: AppBar(
            titleSpacing: 12,
            title: Row(
              children: [
                Icon(Icons.cloud, color: scheme.primary, size: 22),
                const SizedBox(width: 6),
                const Flexible(
                  child: Text(
                    '相互チェッカー',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            actions: [
              // ログインアカウント切替チップ
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => showLoginAccountsSheet(context, c),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 132),
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                    decoration: BoxDecoration(
                      color: session != null ? scheme.primaryContainer.withValues(alpha: 0.7) : Colors.transparent,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: session != null ? scheme.primary : scheme.outlineVariant,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          session != null ? Icons.verified_user_outlined : Icons.login,
                          size: 15,
                          color: session != null ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            session != null ? session.atHandle : 'ログイン',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: session != null ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                                  fontWeight: session != null ? FontWeight.w600 : FontWeight.w500,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              FemaleFilterToggleButton(
                controller: c,
                onOpenSettings: () => showJevSettingsDialog(context, c),
              ),
              if (c.isLoggedIn)
                IconButton(
                  tooltip: 'ミュート・ブロック管理',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => showBlockedMutedSheet(context, c),
                  icon: const Icon(Icons.shield_outlined, size: 21),
                ),
              const SizedBox(width: 4),
            ],
          ),
          body: Column(
            children: [
              JevUsageBar(
                controller: c,
                onOpenSettings: () => showJevSettingsDialog(context, c),
              ),
              if (c.jev.lastError != null && c.jev.isActive)
                JevErrorBanner(
                  error: c.jev.lastError!,
                  onOpenSettings: () => showJevSettingsDialog(context, c),
                  onDismiss: () => c.setOnlyFemaleAccounts(false),
                ),
              if (c.batchProgress case final prog?)
                _BatchProgressBanner(
                  progress: prog,
                  onCancel: c.cancelBatch,
                ),
              const Divider(height: 1),
              _buildActorSearchHeader(context),
              if (c.checkError != null) _buildErrorBox(context, c.checkError!),
              Expanded(
                child: c.snapshot == null
                    ? _buildWelcomeState(context)
                    : _buildSnapshotContent(context, c.snapshot!),
              ),
            ],
          ),
          bottomNavigationBar: c.hasSelection ? _buildBatchBottomBar(context) : null,
        );
      },
    );
  }

  Widget _buildActorSearchHeader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final c = _controller;
    final session = c.activeSession;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: TextField(
                    controller: _actorInput,
                    autocorrect: false,
                    textInputAction: TextInputAction.search,
                    onSubmitted: _inspectActor,
                    style: text.bodyMedium,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      hintText: 'チェックする @ハンドル名（例: alice.bsky.social）',
                      prefixIcon: const Icon(Icons.alternate_email, size: 18),
                      suffixIcon: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _actorInput,
                        builder: (_, val, _) => val.text.isEmpty
                            ? const SizedBox.shrink()
                            : IconButton(
                                iconSize: 16,
                                padding: EdgeInsets.zero,
                                onPressed: _actorInput.clear,
                                icon: const Icon(Icons.clear),
                              ),
                      ),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              if (c.isCheckingGraph)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: scheme.error,
                  ),
                  onPressed: c.cancelCheck,
                  icon: const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  label: const Text('中断'),
                )
              else ...[
                FilledButton(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    minimumSize: const Size(0, 38),
                  ),
                  onPressed: () => _inspectActor(_actorInput.text),
                  child: const Text('解析'),
                ),
                if (session != null &&
                    (c.snapshot == null || c.snapshot!.targetProfile.did != session.did)) ...[
                  const SizedBox(width: 4),
                  FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 38),
                    ),
                    onPressed: () => _inspectActor(session.handle),
                    child: const Text('自分の垢'),
                  ),
                ],
              ],
            ],
          ),
          if (c.isCheckingGraph) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'フォロー ${c.followsLoaded}${c.followsTotal != null ? '/${c.followsTotal}' : ''}件 · '
                    'フォロワー ${c.followersLoaded}${c.followersTotal != null ? '/${c.followersTotal}' : ''}件 を取得中…',
                    style: text.labelSmall?.copyWith(color: scheme.primary),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorBox(BuildContext context, String message) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
      ),
    );
  }

  Widget _buildWelcomeState(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final c = _controller;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.people_alt_rounded, size: 36, color: scheme.primary),
                    const SizedBox(width: 12),
                    const Icon(Icons.female_rounded, size: 36, color: kJevPink),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Bluesky 相互フォローチェッカー & Jev 女性抽出',
                  textAlign: TextAlign.center,
                  style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  '・任意の @ハンドルを入力するだけで「片思い」「片思われ」「相互フォロー」を即座に分類します（ログイン不要）。\n'
                  '・右上の「♀ 女性のみ」をONにすると、Jev（TypeSafe AI）がアイコン画像＋名前＋自己紹介から女性個人アカウントのみを抽出します。\n'
                  '・アプリパスワードでログインすると、個別・一括でのフォロー解除・ミュート・ブロック自動化も使えます。',
                  style: text.bodySmall?.copyWith(height: 1.5, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (!c.isLoggedIn)
                      FilledButton.tonalIcon(
                        onPressed: () => showLoginAccountsSheet(context, c),
                        icon: const Icon(Icons.login, size: 18),
                        label: const Text('アプリパスワードでログイン'),
                      )
                    else
                      FilledButton.icon(
                        onPressed: c.checkMyAccount,
                        icon: const Icon(Icons.person_search, size: 18),
                        label: Text('${c.activeSession!.atHandle} を解析する'),
                      ),
                    OutlinedButton.icon(
                      onPressed: () => showJevSettingsDialog(context, c),
                      icon: const Icon(Icons.female, size: 18, color: kJevPink),
                      label: Text(c.jev.hasApiKey ? 'Jev 設定・費用を確認' : 'Jev API キーを設定'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (c.recentHandles.isNotEmpty) ...[
            const SizedBox(height: 18),
            Row(
              children: [
                Text('最近チェックしたアカウント', style: text.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
                const Spacer(),
                TextButton(
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: c.clearRecentHandles,
                  child: const Text('履歴を消去'),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final h in c.recentHandles)
                  ActionChip(
                    avatar: const Icon(Icons.history, size: 15),
                    label: Text('@$h'),
                    onPressed: () => _inspectActor(h),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSnapshotContent(BuildContext context, GraphCheckSnapshot snap) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final c = _controller;
    final target = snap.targetProfile;
    final accounts = c.visibleAccounts;
    final stats = c.currentTabJevStats;

    return Column(
      children: [
        // 1. 解析対象アカウントの概要バー
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: scheme.surfaceContainerLow,
          child: Row(
            children: [
              BlueskyAvatar(url: target.avatarUrl, radius: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${target.effectiveName} (${target.atHandle})',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      'フォロー ${snap.followsFetchedCount} · フォロワー ${snap.followersFetchedCount} · '
                      '相互 ${snap.mutualCount}',
                      style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '最新状態に再取得',
                visualDensity: VisualDensity.compact,
                iconSize: 19,
                onPressed: c.isCheckingGraph ? null : () => _inspectActor(target.handle),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        // 2. 分類タブ（片思い / 片思われ / 相互 / すべて）
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            children: [
              for (final tab in RelationTab.values)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    visualDensity: VisualDensity.compact,
                    showCheckmark: false,
                    selected: c.activeTab == tab,
                    label: Text('${tab.label} (${c.countForTab(tab)})'),
                    onSelected: (_) => c.setActiveTab(tab),
                  ),
                ),
            ],
          ),
        ),
        // 3. キーワード絞り込み＋ソート＋一括選択バー
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 8, 6),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: TextField(
                    controller: _filterInput,
                    onChanged: c.setSearchQuery,
                    style: text.bodySmall,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      hintText: '名前・@ID・自己紹介で絞り込み',
                      prefixIcon: const Icon(Icons.search, size: 16),
                      suffixIcon: c.searchQuery.isEmpty
                          ? null
                          : IconButton(
                              iconSize: 15,
                              padding: EdgeInsets.zero,
                              onPressed: () {
                                _filterInput.clear();
                                c.setSearchQuery('');
                              },
                              icon: const Icon(Icons.clear),
                            ),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              PopupMenuButton<AccountSortOrder>(
                tooltip: '並び替え',
                initialValue: c.sortOrder,
                onSelected: c.setSortOrder,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.sort, size: 17),
                      const SizedBox(width: 3),
                      Text(c.sortOrder.label, style: text.labelSmall),
                    ],
                  ),
                ),
                itemBuilder: (_) => [
                  for (final order in AccountSortOrder.values)
                    PopupMenuItem(
                      value: order,
                      child: Text(order.label),
                    ),
                ],
              ),
              if (accounts.isNotEmpty)
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: c.hasSelection ? c.clearSelection : c.selectAllVisible,
                  child: Text(c.hasSelection ? '選択解除' : '全選択', style: const TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        // 4. アカウント一覧
        Expanded(
          child: accounts.isEmpty
              ? _buildEmptyTabState(context, stats)
              : NotificationListener<ScrollNotification>(
                  onNotification: (notif) {
                    if (c.jev.isActive &&
                        !c.isJudgingJev &&
                        !c.jevPausedForCurrentList &&
                        stats.unjudgedCount > 0 &&
                        notif.metrics.extentAfter < 420) {
                      c.ensureJevJudgedForCurrentTab(loadMore: true);
                    }
                    return false;
                  },
                  child: ListView.separated(
                    itemCount: accounts.length + (c.jev.isActive && stats.unjudgedCount > 0 ? 1 : 0),
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      if (index >= accounts.length) {
                        return _buildLoadMoreJevFooter(context, stats);
                      }
                      return AccountCard(
                        account: accounts[index],
                        controller: c,
                        onInspectActor: _inspectActor,
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildEmptyTabState(BuildContext context, JevTabStats stats) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final c = _controller;

    if (c.jev.isActive && c.isJudgingJev) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: kJevPink),
              const SizedBox(height: 14),
              Text(
                'Jev で女性個人アカウントを判定しています…\n（未判定 残り ${stats.unjudgedCount}件）',
                textAlign: TextAlign.center,
                style: text.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }

    if (c.jev.isActive && stats.unjudgedCount > 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.female, size: 40, color: kJevPink),
              const SizedBox(height: 8),
              Text(
                'ここまで判定した ${stats.nonFemaleCount}件 には女性個人アカウントがありませんでした（未判定 ${stats.unjudgedCount}件）',
                textAlign: TextAlign.center,
                style: text.bodyMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: kJevPink, foregroundColor: Colors.white),
                    onPressed: () => c.ensureJevJudgedForCurrentTab(loadMore: true),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('次の48件を判定する'),
                  ),
                  OutlinedButton(
                    onPressed: () => c.ensureJevJudgedForCurrentTab(judgeAll: true),
                    child: const Text('残り全件を判定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined, size: 38, color: scheme.onSurfaceVariant),
            const SizedBox(height: 8),
            Text(
              c.jev.isActive
                  ? 'このタブに該当する女性個人アカウントはありません（非表示 ${stats.nonFemaleCount}件）'
                  : '該当するアカウントはありません',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadMoreJevFooter(BuildContext context, JevTabStats stats) {
    final c = _controller;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Center(
        child: c.isJudgingJev
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kJevPink),
                  ),
                  const SizedBox(width: 8),
                  Text('次ページのアカウントを Jev 判定中…（残り ${stats.unjudgedCount}件）'),
                ],
              )
            : Wrap(
                spacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () => c.ensureJevJudgedForCurrentTab(loadMore: true),
                    icon: const Icon(Icons.female, size: 18, color: kJevPink),
                    label: Text('さらに判定する（未判定 ${stats.unjudgedCount}件）'),
                  ),
                  TextButton(
                    onPressed: () => c.ensureJevJudgedForCurrentTab(judgeAll: true),
                    child: const Text('残り全件判定'),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildBatchBottomBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = _controller;

    return SafeArea(
      child: Material(
        elevation: 8,
        color: scheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: !c.isLoggedIn
              ? Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${c.selectedCount}件選択中（一括操作にはログインが必要です）',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    TextButton(onPressed: c.clearSelection, child: const Text('解除')),
                    FilledButton(
                      onPressed: () => showLoginAccountsSheet(context, c),
                      child: const Text('ログイン'),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          '${c.selectedCount}件を選択中',
                          style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const Spacer(),
                        TextButton(
                          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                          onPressed: c.selectAllVisible,
                          child: const Text('表示中を全選択'),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                          onPressed: c.clearSelection,
                          child: const Text('クリア'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          FilledButton.tonalIcon(
                            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                            onPressed: c.isRunningBatch ? null : () => _executeBatch(BatchActionKind.unfollow),
                            icon: const Icon(Icons.person_remove_outlined, size: 17),
                            label: const Text('一括リムーブ'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                            onPressed: c.isRunningBatch ? null : () => _executeBatch(BatchActionKind.follow),
                            icon: const Icon(Icons.person_add_outlined, size: 17),
                            label: const Text('一括フォロー'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                            onPressed: c.isRunningBatch ? null : () => _executeBatch(BatchActionKind.mute),
                            icon: const Icon(Icons.volume_off_outlined, size: 17),
                            label: const Text('一括ミュート'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              foregroundColor: scheme.error,
                            ),
                            onPressed: c.isRunningBatch ? null : () => _executeBatch(BatchActionKind.block),
                            icon: const Icon(Icons.block, size: 17),
                            label: const Text('一括ブロック'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _BatchProgressBanner extends StatelessWidget {
  const _BatchProgressBanner({
    required this.progress,
    required this.onCancel,
  });

  final BatchProgress progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${progress.kind.label}を実行中: ${progress.completed}/${progress.total}件 '
                    '${progress.currentHandle != null ? '(@${progress.currentHandle})' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: scheme.onSecondaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: scheme.error,
                  ),
                  onPressed: onCancel,
                  child: const Text('中断'),
                ),
              ],
            ),
            LinearProgressIndicator(value: progress.fraction),
          ],
        ),
      ),
    );
  }
}
