import '../services/jev_service.dart';

/// 検査対象アカウントから見たフォロー関係の分類。
enum FollowRelationKind {
  /// お互いにフォローしている（相互フォロー）
  mutual,

  /// 検査対象アカウントが一方的にフォローしている（片思い / 未フォロバ）
  followingOnly,

  /// 相手から一方的にフォローされている（片思われ / ファン）
  followerOnly,

  /// どちらでもない（単独プロフィール参照やブロック一覧など）
  none,
}

extension FollowRelationKindX on FollowRelationKind {
  String get label => switch (this) {
        FollowRelationKind.mutual => '相互フォロー',
        FollowRelationKind.followingOnly => '片思い',
        FollowRelationKind.followerOnly => '片思われ',
        FollowRelationKind.none => '関係なし',
      };

  String get shortLabel => switch (this) {
        FollowRelationKind.mutual => '相互',
        FollowRelationKind.followingOnly => '片思い',
        FollowRelationKind.followerOnly => '片思われ',
        FollowRelationKind.none => '-',
      };
}

/// Bluesky (AT Protocol) の 1 アカウント分のプロフィール・関係状態。
class BlueskyAccount {
  const BlueskyAccount({
    required this.did,
    required this.handle,
    this.displayName = '',
    this.avatarUrl = '',
    this.description = '',
    this.followsCount,
    this.followersCount,
    this.postsCount,
    this.relation = FollowRelationKind.none,
    this.orderIndex = 0,
    this.viewerFollowingUri,
    this.viewerFollowedByUri,
    this.viewerBlockingUri,
    this.viewerBlockedBy = false,
    this.viewerMuted = false,
  });

  final String did;
  final String handle;
  final String displayName;
  final String avatarUrl;
  final String description;
  final int? followsCount;
  final int? followersCount;
  final int? postsCount;

  /// 検査対象アカウント基準での相互・片思い・片思われ区分。
  final FollowRelationKind relation;

  /// API 取得順（新しい順ソート用）。
  final int orderIndex;

  /// ログイン中アカウントがこのユーザーをフォローしている場合の AT-URI (`at://.../app.bsky.graph.follow/...`)。
  final String? viewerFollowingUri;

  /// このユーザーがログイン中アカウントをフォローしている場合の AT-URI。
  final String? viewerFollowedByUri;

  /// ログイン中アカウントがこのユーザーをブロックしている場合の AT-URI (`at://.../app.bsky.graph.block/...`)。
  final String? viewerBlockingUri;

  /// このユーザーからブロックされているか。
  final bool viewerBlockedBy;

  /// ログイン中アカウントがこのユーザーをミュートしているか。
  final bool viewerMuted;

  bool get isViewerFollowing => viewerFollowingUri != null && viewerFollowingUri!.isNotEmpty;
  bool get isViewerFollowedBy => viewerFollowedByUri != null && viewerFollowedByUri!.isNotEmpty;
  bool get isViewerBlocking => viewerBlockingUri != null && viewerBlockingUri!.isNotEmpty;

  String get effectiveName => displayName.trim().isNotEmpty ? displayName.trim() : handle;

  String get atHandle => handle.startsWith('@') ? handle : '@$handle';

  String get profileWebUrl => 'https://bsky.app/profile/${Uri.encodeComponent(handle)}';

  /// Jev（女性個人アカウント判定）へ渡す候補オブジェクトへ変換する。
  AccountCandidate toJevCandidate() => AccountCandidate(
        username: handle,
        displayName: displayName,
        avatarUrl: avatarUrl,
        bio: description,
      );

  BlueskyAccount copyWith({
    String? did,
    String? handle,
    String? displayName,
    String? avatarUrl,
    String? description,
    int? followsCount,
    int? followersCount,
    int? postsCount,
    FollowRelationKind? relation,
    int? orderIndex,
    Object? viewerFollowingUri = _sentinel,
    Object? viewerFollowedByUri = _sentinel,
    Object? viewerBlockingUri = _sentinel,
    bool? viewerBlockedBy,
    bool? viewerMuted,
  }) {
    return BlueskyAccount(
      did: did ?? this.did,
      handle: handle ?? this.handle,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      description: description ?? this.description,
      followsCount: followsCount ?? this.followsCount,
      followersCount: followersCount ?? this.followersCount,
      postsCount: postsCount ?? this.postsCount,
      relation: relation ?? this.relation,
      orderIndex: orderIndex ?? this.orderIndex,
      viewerFollowingUri:
          identical(viewerFollowingUri, _sentinel) ? this.viewerFollowingUri : viewerFollowingUri as String?,
      viewerFollowedByUri:
          identical(viewerFollowedByUri, _sentinel) ? this.viewerFollowedByUri : viewerFollowedByUri as String?,
      viewerBlockingUri:
          identical(viewerBlockingUri, _sentinel) ? this.viewerBlockingUri : viewerBlockingUri as String?,
      viewerBlockedBy: viewerBlockedBy ?? this.viewerBlockedBy,
      viewerMuted: viewerMuted ?? this.viewerMuted,
    );
  }

  static const Object _sentinel = Object();

  factory BlueskyAccount.fromProfileJson(
    Map<String, dynamic> json, {
    FollowRelationKind relation = FollowRelationKind.none,
    int orderIndex = 0,
  }) {
    final viewer = json['viewer'];
    String? viewerFollowing;
    String? viewerFollowedBy;
    String? viewerBlocking;
    var blockedBy = false;
    var muted = false;
    if (viewer is Map) {
      viewerFollowing = _nonEmptyStr(viewer['following']);
      viewerFollowedBy = _nonEmptyStr(viewer['followedBy']);
      viewerBlocking = _nonEmptyStr(viewer['blocking']);
      blockedBy = viewer['blockedBy'] == true;
      muted = viewer['muted'] == true;
    }
    return BlueskyAccount(
      did: (json['did'] as String?)?.trim() ?? '',
      handle: (json['handle'] as String?)?.trim() ?? '',
      displayName: (json['displayName'] as String?)?.trim() ?? '',
      avatarUrl: (json['avatar'] as String?)?.trim() ?? '',
      description: (json['description'] as String?)?.trim() ?? '',
      followsCount: (json['followsCount'] as num?)?.toInt(),
      followersCount: (json['followersCount'] as num?)?.toInt(),
      postsCount: (json['postsCount'] as num?)?.toInt(),
      relation: relation,
      orderIndex: orderIndex,
      viewerFollowingUri: viewerFollowing,
      viewerFollowedByUri: viewerFollowedBy,
      viewerBlockingUri: viewerBlocking,
      viewerBlockedBy: blockedBy,
      viewerMuted: muted,
    );
  }

  static String? _nonEmptyStr(Object? v) {
    if (v is! String) return null;
    final trimmed = v.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// 端末内に保存する Bluesky のログインセッション（パスワード本体は保存しない）。
class BlueskySession {
  BlueskySession({
    required this.did,
    required this.handle,
    this.displayName = '',
    this.avatarUrl = '',
    required this.pdsUrl,
    required this.accessJwt,
    required this.refreshJwt,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String did;
  String handle;
  String displayName;
  String avatarUrl;
  String pdsUrl;
  String accessJwt;
  String refreshJwt;
  DateTime updatedAt;

  String get atHandle => handle.startsWith('@') ? handle : '@$handle';

  String get displayLabel =>
      displayName.trim().isNotEmpty ? '${displayName.trim()} ($atHandle)' : atHandle;

  Map<String, dynamic> toJson() => {
        'did': did,
        'handle': handle,
        if (displayName.isNotEmpty) 'displayName': displayName,
        if (avatarUrl.isNotEmpty) 'avatarUrl': avatarUrl,
        'pdsUrl': pdsUrl,
        'accessJwt': accessJwt,
        'refreshJwt': refreshJwt,
        'updatedAt': updatedAt.toIso8601String(),
      };

  static BlueskySession? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final did = (raw['did'] as String?)?.trim() ?? '';
    final handle = (raw['handle'] as String?)?.trim() ?? '';
    final pdsUrl = (raw['pdsUrl'] as String?)?.trim() ?? '';
    final accessJwt = (raw['accessJwt'] as String?)?.trim() ?? '';
    final refreshJwt = (raw['refreshJwt'] as String?)?.trim() ?? '';
    if (did.isEmpty || handle.isEmpty || pdsUrl.isEmpty || accessJwt.isEmpty || refreshJwt.isEmpty) {
      return null;
    }
    return BlueskySession(
      did: did,
      handle: handle,
      displayName: (raw['displayName'] as String?)?.trim() ?? '',
      avatarUrl: (raw['avatarUrl'] as String?)?.trim() ?? '',
      pdsUrl: pdsUrl,
      accessJwt: accessJwt,
      refreshJwt: refreshJwt,
      updatedAt: DateTime.tryParse((raw['updatedAt'] as String?) ?? '') ?? DateTime.now(),
    );
  }
}

/// 1 回の相互フォローチェック結果スナップショット。
class GraphCheckSnapshot {
  const GraphCheckSnapshot({
    required this.targetProfile,
    required this.accounts,
    required this.followsFetchedCount,
    required this.followersFetchedCount,
    required this.fetchedAt,
  });

  final BlueskyAccount targetProfile;
  final List<BlueskyAccount> accounts;
  final int followsFetchedCount;
  final int followersFetchedCount;
  final DateTime fetchedAt;

  int get mutualCount => accounts.where((a) => a.relation == FollowRelationKind.mutual).length;
  int get followingOnlyCount => accounts.where((a) => a.relation == FollowRelationKind.followingOnly).length;
  int get followerOnlyCount => accounts.where((a) => a.relation == FollowRelationKind.followerOnly).length;

  GraphCheckSnapshot copyWith({
    BlueskyAccount? targetProfile,
    List<BlueskyAccount>? accounts,
  }) {
    return GraphCheckSnapshot(
      targetProfile: targetProfile ?? this.targetProfile,
      accounts: accounts ?? this.accounts,
      followsFetchedCount: followsFetchedCount,
      followersFetchedCount: followersFetchedCount,
      fetchedAt: fetchedAt,
    );
  }
}
