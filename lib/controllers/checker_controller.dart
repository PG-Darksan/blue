import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/bluesky_models.dart';
import '../services/bluesky_api_service.dart';
import '../services/jev_service.dart';

/// 相互フォローチェッカーの分類タブ。
enum RelationTab {
  followingOnly,
  followerOnly,
  mutual,
  all,
}

extension RelationTabX on RelationTab {
  String get label => switch (this) {
        RelationTab.followingOnly => '片思い',
        RelationTab.followerOnly => '片思われ',
        RelationTab.mutual => '相互',
        RelationTab.all => 'すべて',
      };

  String get description => switch (this) {
        RelationTab.followingOnly => 'フォローしているが相手からフォローされていないアカウント',
        RelationTab.followerOnly => '相手からフォローされているが自分は未フォローのアカウント',
        RelationTab.mutual => 'お互いにフォローし合っているアカウント',
        RelationTab.all => 'フォロー・フォロワーすべてのアカウント',
      };
}

/// 一覧の並び替え順。
enum AccountSortOrder {
  newest,
  oldest,
  handleAsc,
}

extension AccountSortOrderX on AccountSortOrder {
  String get label => switch (this) {
        AccountSortOrder.newest => '新しい順',
        AccountSortOrder.oldest => '古い順',
        AccountSortOrder.handleAsc => '@ハンドル順',
      };
}

/// 一括自動操作の種類。
enum BatchActionKind {
  unfollow,
  follow,
  mute,
  unmute,
  block,
}

extension BatchActionKindX on BatchActionKind {
  String get label => switch (this) {
        BatchActionKind.unfollow => '一括フォロー解除',
        BatchActionKind.follow => '一括フォロー',
        BatchActionKind.mute => '一括ミュート',
        BatchActionKind.unmute => '一括ミュート解除',
        BatchActionKind.block => '一括ブロック',
      };
}

/// 一括自動操作の進捗情報。
class BatchProgress {
  const BatchProgress({
    required this.kind,
    required this.completed,
    required this.total,
    required this.succeeded,
    required this.failed,
    this.currentHandle,
    this.lastError,
  });

  final BatchActionKind kind;
  final int completed;
  final int total;
  final int succeeded;
  final int failed;
  final String? currentHandle;
  final String? lastError;

  double get fraction => total <= 0 ? 0 : (completed / total).clamp(0.0, 1.0);
}

/// 現在のタブにおける Jev 女性判定集計。
typedef JevTabStats = ({
  int totalInTab,
  int femaleCount,
  int nonFemaleCount,
  int unjudgedCount,
});

/// Bluesky 相互フォローチェッカー & Jev 女性抽出アプリのメイン状態管理コントローラ。
class CheckerController extends ChangeNotifier {
  CheckerController({
    BlueskyApiService? api,
    JevService? jev,
    File? storageFile,
    bool inMemoryOnly = false,
    this.batchDelay = const Duration(milliseconds: 320),
  })  : _ownsJev = jev == null,
        jev = jev ?? JevService(inMemoryOnly: inMemoryOnly),
        _storageFile = storageFile,
        _inMemoryOnly = inMemoryOnly,
        _loaded = inMemoryOnly {
    this.api = api ?? BlueskyApiService(onSessionUpdated: _onSessionTokenRefreshed);
    this.jev.addListener(_onJevChanged);
    unawaited(ensureLoaded());
  }

  static const int jevChunkSize = 48;
  static const int maxRecentHandles = 15;

  late final BlueskyApiService api;
  final JevService jev;
  final bool _ownsJev;
  File? _storageFile;
  final bool _inMemoryOnly;
  final Duration batchDelay;

  bool _loaded;
  Future<void>? _loading;

  // 保存済みログインセッション（複数アカウント切替対応）
  final List<BlueskySession> _sessions = [];
  String? _activeSessionDid;
  final List<String> _recentHandles = [];

  // 相互フォロー解析の状態
  String _lastCheckedActor = '';
  GraphCheckSnapshot? _snapshot;
  bool _isCheckingGraph = false;
  String? _checkError;
  int _followsLoaded = 0;
  int? _followsTotal;
  int _followersLoaded = 0;
  int? _followersTotal;
  int _checkRunId = 0;

  // 表示・絞り込み状態
  RelationTab _activeTab = RelationTab.followingOnly;
  AccountSortOrder _sortOrder = AccountSortOrder.newest;
  String _searchQuery = '';

  // 複数選択＆自動化状態
  final Set<String> _selectedDids = {};
  final Set<String> _busyDids = {};
  BatchProgress? _batchProgress;
  bool _cancelBatchRequested = false;

  // Jev バックグラウンド判定状態
  bool _isJudgingJev = false;
  bool _jevPausedForCurrentList = false;
  int _jevRunId = 0;
  double _lastThreshold = JevService.defaultThreshold;

  List<BlueskySession> get sessions => List.unmodifiable(_sessions);
  List<String> get recentHandles => List.unmodifiable(_recentHandles);

  BlueskySession? get activeSession {
    if (_activeSessionDid == null) return null;
    for (final s in _sessions) {
      if (s.did == _activeSessionDid) return s;
    }
    return _sessions.isNotEmpty ? _sessions.first : null;
  }

  bool get isLoggedIn => activeSession != null;

  bool get isInspectingSelf =>
      activeSession != null && _snapshot != null && activeSession!.did == _snapshot!.targetProfile.did;

  String get lastCheckedActor => _lastCheckedActor;
  GraphCheckSnapshot? get snapshot => _snapshot;
  bool get isCheckingGraph => _isCheckingGraph;
  String? get checkError => _checkError;
  int get followsLoaded => _followsLoaded;
  int? get followsTotal => _followsTotal;
  int get followersLoaded => _followersLoaded;
  int? get followersTotal => _followersTotal;

  RelationTab get activeTab => _activeTab;
  AccountSortOrder get sortOrder => _sortOrder;
  String get searchQuery => _searchQuery;

  Set<String> get selectedDids => Set.unmodifiable(_selectedDids);
  int get selectedCount => _selectedDids.length;
  bool get hasSelection => _selectedDids.isNotEmpty;
  bool isSelected(String did) => _selectedDids.contains(did);
  bool isBusy(String did) => _busyDids.contains(did);

  BatchProgress? get batchProgress => _batchProgress;
  bool get isRunningBatch => _batchProgress != null;

  bool get isJudgingJev => _isJudgingJev;
  bool get jevPausedForCurrentList => _jevPausedForCurrentList;

  @override
  void dispose() {
    _checkRunId++;
    _jevRunId++;
    jev.removeListener(_onJevChanged);
    if (_ownsJev) jev.dispose();
    super.dispose();
  }

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    await jev.ensureLoaded();
    try {
      if (_storageFile == null) {
        final dir = await getApplicationSupportDirectory();
        _storageFile = File('${dir.path}${Platform.pathSeparator}bsky_checker_state_v1.json');
      }
      if (await _storageFile!.exists()) {
        final raw = jsonDecode(await _storageFile!.readAsString());
        if (raw is Map<String, dynamic>) {
          final rawSessions = raw['sessions'];
          if (rawSessions is List) {
            _sessions
              ..clear()
              ..addAll([for (final item in rawSessions) ?BlueskySession.fromJson(item)]);
          }
          final activeDid = raw['activeSessionDid'] as String?;
          if (activeDid != null && _sessions.any((s) => s.did == activeDid)) {
            _activeSessionDid = activeDid;
          } else if (_sessions.isNotEmpty) {
            _activeSessionDid = _sessions.first.did;
          }
          final recents = raw['recentHandles'];
          if (recents is List) {
            _recentHandles
              ..clear()
              ..addAll([
                for (final h in recents)
                  if (h is String && h.trim().isNotEmpty) h.trim(),
              ]);
          }
          _lastCheckedActor = (raw['lastCheckedActor'] as String?)?.trim() ?? '';
        }
      }
    } on MissingPluginException {
      // テスト環境ではメモリ内のみ
    } catch (e) {
      debugPrint('状態の読み込みに失敗: $e');
    } finally {
      _lastThreshold = jev.threshold;
      _loaded = true;
      notifyListeners();
    }
  }

  Future<void> _saveState() async {
    if (_inMemoryOnly) return;
    final file = _storageFile;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'sessions': [for (final s in _sessions) s.toJson()],
        if (_activeSessionDid != null) 'activeSessionDid': _activeSessionDid,
        'recentHandles': _recentHandles,
        'lastCheckedActor': _lastCheckedActor,
      }));
    } catch (e) {
      debugPrint('状態の保存に失敗: $e');
    }
  }

  Future<void> _onSessionTokenRefreshed(BlueskySession updated) async {
    final idx = _sessions.indexWhere((s) => s.did == updated.did);
    if (idx >= 0) {
      _sessions[idx] = updated;
      await _saveState();
      notifyListeners();
    }
  }

  void _onJevChanged() {
    final thresholdChanged = (_lastThreshold - jev.threshold).abs() > 0.0001;
    _lastThreshold = jev.threshold;
    if (jev.isActive && !_jevPausedForCurrentList) {
      unawaited(ensureJevJudgedForCurrentTab());
    } else if (!jev.isActive) {
      _jevRunId++;
      _isJudgingJev = false;
      _jevPausedForCurrentList = false;
    } else if (thresholdChanged) {
      notifyListeners();
    }
    notifyListeners();
  }

  /// 「女性のみ表示」をワンタップで ON/OFF する。
  Future<void> setOnlyFemaleAccounts(bool enabled) async {
    _jevPausedForCurrentList = false;
    await jev.updateSettings(onlyFemaleAccounts: enabled);
  }

  /// アプリパスワードで Bluesky アカウントにログインして保存する。
  Future<BlueskySession> login({
    required String identifier,
    required String password,
    String? customPdsUrl,
  }) async {
    await ensureLoaded();
    final session = await api.createSession(
      identifier: identifier,
      password: password,
      customPdsUrl: customPdsUrl,
    );
    final existingIdx = _sessions.indexWhere((s) => s.did == session.did);
    if (existingIdx >= 0) {
      _sessions[existingIdx] = session;
    } else {
      _sessions.add(session);
    }
    _activeSessionDid = session.did;
    _recordRecentHandle(session.handle);
    notifyListeners();
    await _saveState();
    return session;
  }

  /// アクティブなログインアカウントを切り替える（`null` を渡すと未ログイン閲覧モード）。
  Future<void> switchSession(String? did) async {
    await ensureLoaded();
    if (did == null) {
      _activeSessionDid = null;
    } else if (_sessions.any((s) => s.did == did)) {
      _activeSessionDid = did;
    }
    notifyListeners();
    await _saveState();
  }

  /// 保存済みログインアカウントを削除（ログアウト）する。
  Future<void> removeSession(String did) async {
    await ensureLoaded();
    _sessions.removeWhere((s) => s.did == did);
    if (_activeSessionDid == did) {
      _activeSessionDid = _sessions.isNotEmpty ? _sessions.first.did : null;
    }
    notifyListeners();
    await _saveState();
  }

  Future<void> clearRecentHandles() async {
    _recentHandles.clear();
    notifyListeners();
    await _saveState();
  }

  void _recordRecentHandle(String handle) {
    final clean = handle.trim().replaceFirst(RegExp(r'^@+'), '');
    if (clean.isEmpty) return;
    _recentHandles.removeWhere((h) => h.toLowerCase() == clean.toLowerCase());
    _recentHandles.insert(0, clean);
    if (_recentHandles.length > maxRecentHandles) {
      _recentHandles.removeRange(maxRecentHandles, _recentHandles.length);
    }
  }

  /// 現在実行中の相互フォロー取得を中断する。
  void cancelCheck() {
    if (!_isCheckingGraph) return;
    _checkRunId++;
    _isCheckingGraph = false;
    notifyListeners();
  }

  /// ログイン中の自分のアカウントを相互フォロー解析する。
  Future<void> checkMyAccount() async {
    final session = activeSession;
    if (session == null) return;
    await checkActor(session.handle);
  }

  /// 指定した `@handle` または `DID` のフォロー・フォロワーを全件取得して相互関係を解析する。
  Future<void> checkActor(String rawActor) async {
    await ensureLoaded();
    final normalized = BlueskyApiService.normalizeActorInput(rawActor);
    if (normalized.isEmpty) {
      _checkError = 'チェックする Bluesky の @ハンドル名を入力してください';
      notifyListeners();
      return;
    }

    final runId = ++_checkRunId;
    _jevRunId++;
    _isJudgingJev = false;
    _jevPausedForCurrentList = false;
    _isCheckingGraph = true;
    _checkError = null;
    _followsLoaded = 0;
    _followsTotal = null;
    _followersLoaded = 0;
    _followersTotal = null;
    _selectedDids.clear();
    notifyListeners();

    try {
      final snap = await api.checkMutualGraph(
        normalized,
        session: activeSession,
        isCancelled: () => runId != _checkRunId,
        onProgress: ({
          required followsLoaded,
          required followsTotal,
          required followersLoaded,
          required followersTotal,
        }) {
          if (runId != _checkRunId) return;
          _followsLoaded = followsLoaded;
          _followsTotal = followsTotal;
          _followersLoaded = followersLoaded;
          _followersTotal = followersTotal;
          notifyListeners();
        },
      );
      if (runId != _checkRunId) return;

      _snapshot = snap;
      _lastCheckedActor = snap.targetProfile.handle;
      _recordRecentHandle(snap.targetProfile.handle);
      _isCheckingGraph = false;

      // 片思いが 0 件で片思われや相互がある場合は見やすいタブへ自動調整
      if (_activeTab == RelationTab.followingOnly &&
          snap.followingOnlyCount == 0 &&
          snap.followerOnlyCount > 0) {
        _activeTab = RelationTab.followerOnly;
      }

      notifyListeners();
      unawaited(_saveState());

      if (jev.isActive) {
        unawaited(ensureJevJudgedForCurrentTab());
      }
    } catch (e) {
      if (runId != _checkRunId) return;
      _isCheckingGraph = false;
      _checkError = e is BlueskyApiException ? e.message : '取得に失敗しました: $e';
      notifyListeners();
    }
  }

  void setActiveTab(RelationTab tab) {
    if (_activeTab == tab) return;
    _activeTab = tab;
    _selectedDids.clear();
    _jevPausedForCurrentList = false;
    notifyListeners();
    if (jev.isActive) {
      unawaited(ensureJevJudgedForCurrentTab());
    }
  }

  void setSortOrder(AccountSortOrder order) {
    if (_sortOrder == order) return;
    _sortOrder = order;
    notifyListeners();
  }

  void setSearchQuery(String query) {
    if (_searchQuery == query) return;
    _searchQuery = query;
    notifyListeners();
    if (jev.isActive && !_jevPausedForCurrentList) {
      unawaited(ensureJevJudgedForCurrentTab());
    }
  }

  /// タブ＋検索ワード＋並び順まで適用した一覧（Jev 女性フィルタ適用前）。
  List<BlueskyAccount> get baseFilteredAccounts {
    final snap = _snapshot;
    if (snap == null) return const [];

    final q = _searchQuery.trim().toLowerCase();
    final filtered = <BlueskyAccount>[
      for (final a in snap.accounts)
        if (_matchesTab(a, _activeTab) && _matchesQuery(a, q)) a,
    ];

    switch (_sortOrder) {
      case AccountSortOrder.newest:
        filtered.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
      case AccountSortOrder.oldest:
        filtered.sort((a, b) => b.orderIndex.compareTo(a.orderIndex));
      case AccountSortOrder.handleAsc:
        filtered.sort((a, b) => a.handle.toLowerCase().compareTo(b.handle.toLowerCase()));
    }
    return filtered;
  }

  /// 画面に最終表示するアカウント一覧（`jev.isActive` が ON なら Jev で女性と判定された個人アカウントのみ）。
  List<BlueskyAccount> get visibleAccounts {
    final base = baseFilteredAccounts;
    if (!jev.isActive) return base;
    return [
      for (final a in base)
        if (jev.cachedIsFemale(a.toJevCandidate()) == true) a,
    ];
  }

  /// 現在開いているタブの Jev 女性判定件数サマリ。
  JevTabStats get currentTabJevStats {
    final base = baseFilteredAccounts;
    var female = 0;
    var nonFemale = 0;
    var unjudged = 0;
    for (final a in base) {
      final res = jev.cachedIsFemale(a.toJevCandidate());
      if (res == true) {
        female++;
      } else if (res == false) {
        nonFemale++;
      } else {
        unjudged++;
      }
    }
    return (
      totalInTab: base.length,
      femaleCount: female,
      nonFemaleCount: nonFemale,
      unjudgedCount: unjudged,
    );
  }

  int countForTab(RelationTab tab) {
    final snap = _snapshot;
    if (snap == null) return 0;
    return switch (tab) {
      RelationTab.followingOnly => snap.followingOnlyCount,
      RelationTab.followerOnly => snap.followerOnlyCount,
      RelationTab.mutual => snap.mutualCount,
      RelationTab.all => snap.accounts.where((a) => a.relation != FollowRelationKind.none).length,
    };
  }

  static bool _matchesTab(BlueskyAccount a, RelationTab tab) => switch (tab) {
        RelationTab.followingOnly => a.relation == FollowRelationKind.followingOnly,
        RelationTab.followerOnly => a.relation == FollowRelationKind.followerOnly,
        RelationTab.mutual => a.relation == FollowRelationKind.mutual,
        RelationTab.all => a.relation != FollowRelationKind.none,
      };

  static bool _matchesQuery(BlueskyAccount a, String lowerQuery) {
    if (lowerQuery.isEmpty) return true;
    return a.handle.toLowerCase().contains(lowerQuery) ||
        a.displayName.toLowerCase().contains(lowerQuery) ||
        a.description.toLowerCase().contains(lowerQuery);
  }

  /// Jev バックグラウンド判定を一時停止する（API 消費を止めたいとき用）。
  void pauseJevJudging() {
    _jevPausedForCurrentList = true;
    _jevRunId++;
    _isJudgingJev = false;
    notifyListeners();
  }

  /// 現在のタブにある未判定アカウントを Jev で判定する。
  /// - 通常時は 1 チャンク（[jevChunkSize] = 48 件）ずつ順次判定し、女性表示が少なければ自動で次チャンクも補う。
  /// - [judgeAll] が `true` の場合はタブ内の残り未判定をすべて判定する。
  Future<void> ensureJevJudgedForCurrentTab({
    bool loadMore = false,
    bool judgeAll = false,
  }) async {
    if (!jev.isActive || _snapshot == null) return;
    if (_isJudgingJev && !judgeAll) return;

    if (loadMore || judgeAll) {
      _jevPausedForCurrentList = false;
    }
    if (_jevPausedForCurrentList) return;

    final runId = ++_jevRunId;
    _isJudgingJev = true;
    notifyListeners();

    try {
      var rounds = 0;
      while (runId == _jevRunId && jev.isActive && !_jevPausedForCurrentList) {
        final base = baseFilteredAccounts;
        final unjudged = <AccountCandidate>[
          for (final a in base)
            if (jev.cachedIsFemale(a.toJevCandidate()) == null) a.toJevCandidate(),
        ];
        if (unjudged.isEmpty) break;

        final targetSlice = judgeAll
            ? unjudged
            : unjudged.take(jevChunkSize).toList();

        await jev.judgeFemaleAccounts(
          targetSlice,
          isCancelled: () => runId != _jevRunId || !jev.isActive || _jevPausedForCurrentList,
        );

        rounds++;
        if (judgeAll) break;

        // 初回またはスクロール追従時、画面上の女性アカウントがまだ 10 件未満なら最大 2 ラウンドまで自動補充する
        final stats = currentTabJevStats;
        if (stats.femaleCount >= 10 || stats.unjudgedCount == 0 || rounds >= 2) {
          break;
        }
      }
    } finally {
      if (runId == _jevRunId) {
        _isJudgingJev = false;
        notifyListeners();
      }
    }
  }

  // ---- 選択状態の操作 ----

  void toggleSelect(String did) {
    if (!_selectedDids.remove(did)) {
      _selectedDids.add(did);
    }
    notifyListeners();
  }

  void selectAllVisible() {
    for (final a in visibleAccounts) {
      _selectedDids.add(a.did);
    }
    notifyListeners();
  }

  void clearSelection() {
    if (_selectedDids.isEmpty) return;
    _selectedDids.clear();
    notifyListeners();
  }

  // ---- 単体アカウント操作（フォロー / 解除 / ミュート / ブロック） ----

  void _updateAccountInSnapshot(String did, BlueskyAccount Function(BlueskyAccount cur) updater) {
    final snap = _snapshot;
    if (snap == null) return;
    final nextList = [
      for (final a in snap.accounts) a.did == did ? updater(a) : a,
    ];
    _snapshot = snap.copyWith(accounts: nextList);
  }

  Future<void> toggleFollowAccount(BlueskyAccount account) async {
    final session = activeSession;
    if (session == null || _busyDids.contains(account.did)) return;

    _busyDids.add(account.did);
    notifyListeners();
    try {
      if (account.isViewerFollowing) {
        await api.unfollow(
          session,
          targetDid: account.did,
          followingUri: account.viewerFollowingUri,
        );
        _updateAccountInSnapshot(account.did, (cur) {
          final nextRel = isInspectingSelf
              ? (cur.relation == FollowRelationKind.mutual
                  ? FollowRelationKind.followerOnly
                  : FollowRelationKind.none)
              : cur.relation;
          return cur.copyWith(viewerFollowingUri: null, relation: nextRel);
        });
        _selectedDids.remove(account.did);
      } else {
        final uri = await api.follow(session, account.did);
        _updateAccountInSnapshot(account.did, (cur) {
          final nextRel = isInspectingSelf
              ? (cur.relation == FollowRelationKind.followerOnly || cur.isViewerFollowedBy
                  ? FollowRelationKind.mutual
                  : FollowRelationKind.followingOnly)
              : cur.relation;
          return cur.copyWith(viewerFollowingUri: uri, relation: nextRel);
        });
      }
    } finally {
      _busyDids.remove(account.did);
      notifyListeners();
    }
  }

  Future<void> toggleMuteAccount(BlueskyAccount account) async {
    final session = activeSession;
    if (session == null || _busyDids.contains(account.did)) return;

    _busyDids.add(account.did);
    notifyListeners();
    try {
      if (account.viewerMuted) {
        await api.unmute(session, account.did);
        _updateAccountInSnapshot(account.did, (cur) => cur.copyWith(viewerMuted: false));
      } else {
        await api.mute(session, account.did);
        _updateAccountInSnapshot(account.did, (cur) => cur.copyWith(viewerMuted: true));
      }
    } finally {
      _busyDids.remove(account.did);
      notifyListeners();
    }
  }

  Future<void> toggleBlockAccount(BlueskyAccount account, {bool alsoUnfollow = true}) async {
    final session = activeSession;
    if (session == null || _busyDids.contains(account.did)) return;

    _busyDids.add(account.did);
    notifyListeners();
    try {
      if (account.isViewerBlocking) {
        await api.unblock(
          session,
          targetDid: account.did,
          blockingUri: account.viewerBlockingUri,
        );
        _updateAccountInSnapshot(account.did, (cur) => cur.copyWith(viewerBlockingUri: null));
      } else {
        // フォロー中だった場合は先にフォローレコードも削除しておく（ブロック解除時にフォローが復活しないように）
        if (alsoUnfollow && account.isViewerFollowing) {
          try {
            await api.unfollow(
              session,
              targetDid: account.did,
              followingUri: account.viewerFollowingUri,
            );
          } catch (_) {}
        }
        final blockUri = await api.block(session, account.did);
        _updateAccountInSnapshot(account.did, (cur) {
          final nextRel = (alsoUnfollow && isInspectingSelf && cur.relation == FollowRelationKind.followingOnly)
              ? FollowRelationKind.none
              : (alsoUnfollow && isInspectingSelf && cur.relation == FollowRelationKind.mutual
                  ? FollowRelationKind.followerOnly
                  : cur.relation);
          return cur.copyWith(
            viewerBlockingUri: blockUri,
            viewerFollowingUri: alsoUnfollow ? null : cur.viewerFollowingUri,
            relation: nextRel,
          );
        });
        _selectedDids.remove(account.did);
      }
    } finally {
      _busyDids.remove(account.did);
      notifyListeners();
    }
  }

  // ---- 一括自動操作（レート制限配慮ウェイト＆キャンセル対応） ----

  void cancelBatch() {
    if (_batchProgress != null) {
      _cancelBatchRequested = true;
      notifyListeners();
    }
  }

  /// 選択中のアカウントに対して一括操作（フォロー解除 / フォロー / ミュート / ブロック等）を自動実行する。
  Future<({int succeeded, int failed})> runBatchAction(
    BatchActionKind kind, {
    List<BlueskyAccount>? explicitTargets,
  }) async {
    final session = activeSession;
    final snap = _snapshot;
    if (session == null || _batchProgress != null) {
      return (succeeded: 0, failed: 0);
    }

    final targets = explicitTargets ??
        [
          if (snap != null)
            for (final a in snap.accounts)
              if (_selectedDids.contains(a.did)) a,
        ];
    if (targets.isEmpty) return (succeeded: 0, failed: 0);

    _cancelBatchRequested = false;
    var succeeded = 0;
    var failed = 0;
    String? lastErr;

    _batchProgress = BatchProgress(
      kind: kind,
      completed: 0,
      total: targets.length,
      succeeded: 0,
      failed: 0,
      currentHandle: targets.first.handle,
    );
    notifyListeners();

    try {
      for (var i = 0; i < targets.length; i++) {
        if (_cancelBatchRequested) break;
        final target = targets[i];
        _batchProgress = BatchProgress(
          kind: kind,
          completed: i,
          total: targets.length,
          succeeded: succeeded,
          failed: failed,
          currentHandle: target.handle,
          lastError: lastErr,
        );
        notifyListeners();

        try {
          switch (kind) {
            case BatchActionKind.unfollow:
              if (target.isViewerFollowing || (isInspectingSelf && _isTargetFollowed(target))) {
                await api.unfollow(
                  session,
                  targetDid: target.did,
                  followingUri: target.viewerFollowingUri,
                );
                _updateAccountInSnapshot(target.did, (cur) {
                  final nextRel = isInspectingSelf
                      ? (cur.relation == FollowRelationKind.mutual
                          ? FollowRelationKind.followerOnly
                          : FollowRelationKind.none)
                      : cur.relation;
                  return cur.copyWith(viewerFollowingUri: null, relation: nextRel);
                });
              }
            case BatchActionKind.follow:
              if (!target.isViewerFollowing) {
                final uri = await api.follow(session, target.did);
                _updateAccountInSnapshot(target.did, (cur) {
                  final nextRel = isInspectingSelf
                      ? (cur.relation == FollowRelationKind.followerOnly || cur.isViewerFollowedBy
                          ? FollowRelationKind.mutual
                          : FollowRelationKind.followingOnly)
                      : cur.relation;
                  return cur.copyWith(viewerFollowingUri: uri, relation: nextRel);
                });
              }
            case BatchActionKind.mute:
              if (!target.viewerMuted) {
                await api.mute(session, target.did);
                _updateAccountInSnapshot(target.did, (cur) => cur.copyWith(viewerMuted: true));
              }
            case BatchActionKind.unmute:
              if (target.viewerMuted) {
                await api.unmute(session, target.did);
                _updateAccountInSnapshot(target.did, (cur) => cur.copyWith(viewerMuted: false));
              }
            case BatchActionKind.block:
              if (!target.isViewerBlocking) {
                if (target.isViewerFollowing) {
                  try {
                    await api.unfollow(
                      session,
                      targetDid: target.did,
                      followingUri: target.viewerFollowingUri,
                    );
                  } catch (_) {}
                }
                final blockUri = await api.block(session, target.did);
                _updateAccountInSnapshot(target.did, (cur) {
                  final nextRel = isInspectingSelf && cur.relation == FollowRelationKind.followingOnly
                      ? FollowRelationKind.none
                      : (isInspectingSelf && cur.relation == FollowRelationKind.mutual
                          ? FollowRelationKind.followerOnly
                          : cur.relation);
                  return cur.copyWith(
                    viewerBlockingUri: blockUri,
                    viewerFollowingUri: null,
                    relation: nextRel,
                  );
                });
              }
          }
          succeeded++;
          _selectedDids.remove(target.did);
        } catch (e) {
          failed++;
          lastErr = e is BlueskyApiException ? e.message : '$e';
        }

        _batchProgress = BatchProgress(
          kind: kind,
          completed: i + 1,
          total: targets.length,
          succeeded: succeeded,
          failed: failed,
          currentHandle: target.handle,
          lastError: lastErr,
        );
        notifyListeners();

        if (i + 1 < targets.length && !_cancelBatchRequested && batchDelay > Duration.zero) {
          await Future<void>.delayed(batchDelay);
        }
      }
    } finally {
      _batchProgress = null;
      _cancelBatchRequested = false;
      notifyListeners();
    }

    return (succeeded: succeeded, failed: failed);
  }

  static bool _isTargetFollowed(BlueskyAccount a) =>
      a.relation == FollowRelationKind.mutual || a.relation == FollowRelationKind.followingOnly;
}
