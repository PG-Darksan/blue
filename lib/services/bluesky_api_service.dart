import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/bluesky_models.dart';

/// Bluesky API 通信エラー。
class BlueskyApiException implements Exception {
  const BlueskyApiException(
    this.message, {
    this.statusCode,
    this.errorCode,
  });

  final String message;
  final int? statusCode;
  final String? errorCode;

  @override
  String toString() => message;
}

typedef GraphProgressCallback = void Function({
  required int followsLoaded,
  required int? followsTotal,
  required int followersLoaded,
  required int? followersTotal,
});

/// Bluesky (AT Protocol) 公式 XRPC API クライアント。
///
/// - ログイン不要の公開 API (`https://public.api.bsky.app`) での相互フォロー解析
/// - アプリパスワードによるログイン (`com.atproto.server.createSession`) と自動トークン更新 (`refreshSession`)
/// - フォロー / フォロー解除 / ミュート / ミュート解除 / ブロック / ブロック解除 の実行
class BlueskyApiService {
  BlueskyApiService({
    http.Client? client,
    this.onSessionUpdated,
  }) : _client = client ?? http.Client();

  static const publicAppViewUrl = 'https://public.api.bsky.app';
  static const defaultEntrywayUrl = 'https://bsky.social';
  static const plcDirectoryUrl = 'https://plc.directory';

  final http.Client _client;
  final FutureOr<void> Function(BlueskySession session)? onSessionUpdated;

  /// DID ごとの同時 `refreshSession` 競合を防ぐミューテックス。
  final Map<String, Future<bool>> _refreshLocks = {};

  /// ユーザー入力（`@alice.bsky.social`、`alice`、`https://bsky.app/profile/...`、`did:plc:...`）を API 用の actor 文字列へ正規化する。
  static String normalizeActorInput(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';

    // URL 形式 (https://bsky.app/profile/alice.bsky.social/...)
    final uri = Uri.tryParse(s);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      final segs = uri.pathSegments.where((p) => p.isNotEmpty).toList();
      final profIdx = segs.indexOf('profile');
      if (profIdx >= 0 && profIdx + 1 < segs.length) {
        s = Uri.decodeComponent(segs[profIdx + 1]);
      }
    }

    s = s.replaceFirst(RegExp(r'^@+'), '').trim();
    if (s.isEmpty) return '';
    if (s.startsWith('did:')) return s;
    if (s.contains('@')) return s; // メールアドレス（ログイン用）
    if (!s.contains('.')) {
      return '$s.bsky.social';
    }
    return s.toLowerCase();
  }

  /// AT-URI (`at://did:plc:xxx/app.bsky.graph.follow/3k...`) から末尾の `rkey` を取り出す。
  static String? extractRkey(String? atUri) {
    if (atUri == null) return null;
    final trimmed = atUri.trim();
    if (!trimmed.startsWith('at://')) return null;
    final parts = trimmed.substring(5).split('/');
    if (parts.length < 3 || parts.last.isEmpty) return null;
    if (parts.last == 'unknown' || parts.last == 'created') return null;
    return parts.last;
  }

  static String _cleanBaseUrl(String raw) => raw.trim().replaceFirst(RegExp(r'/+$'), '');

  /// DID ドキュメント内の `#atproto_pds` サービスエンドポイントを取り出す。
  static String? extractPdsEndpointFromDidDoc(Object? didDoc) {
    if (didDoc is! Map) return null;
    final services = didDoc['service'];
    if (services is! List) return null;
    for (final svc in services) {
      if (svc is Map) {
        final id = (svc['id'] as String?) ?? '';
        final type = (svc['type'] as String?) ?? '';
        final endpoint = (svc['serviceEndpoint'] as String?)?.trim() ?? '';
        if (endpoint.startsWith('http') &&
            (id.endsWith('#atproto_pds') || type == 'AtprotoPersonalDataServer')) {
          return _cleanBaseUrl(endpoint);
        }
      }
    }
    return null;
  }

  /// ハンドルまたは DID から所属 PDS エンドポイントを自動解決する（解決できない場合は `https://bsky.social` を返す）。
  Future<String> resolvePdsUrl(String identifier) async {
    final actor = normalizeActorInput(identifier);
    if (actor.isEmpty || actor.contains('@')) return defaultEntrywayUrl;
    try {
      var did = actor;
      if (!did.startsWith('did:')) {
        final resolveUri = Uri.parse('$publicAppViewUrl/xrpc/com.atproto.identity.resolveHandle')
            .replace(queryParameters: {'handle': actor});
        final res = await _client.get(resolveUri).timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
          did = (json['did'] as String?)?.trim() ?? '';
        }
      }
      if (did.startsWith('did:plc:')) {
        final plcRes = await _client.get(Uri.parse('$plcDirectoryUrl/$did')).timeout(const Duration(seconds: 8));
        if (plcRes.statusCode == 200) {
          final doc = jsonDecode(utf8.decode(plcRes.bodyBytes));
          final pds = extractPdsEndpointFromDidDoc(doc);
          if (pds != null) return pds;
        }
      } else if (did.startsWith('did:web:')) {
        final host = Uri.decodeComponent(did.substring('did:web:'.length).split(':').first);
        final webRes =
            await _client.get(Uri.parse('https://$host/.well-known/did.json')).timeout(const Duration(seconds: 8));
        if (webRes.statusCode == 200) {
          final doc = jsonDecode(utf8.decode(webRes.bodyBytes));
          final pds = extractPdsEndpointFromDidDoc(doc);
          if (pds != null) return pds;
        }
      }
    } catch (_) {
      // ネットワークエラー時は標準エントリーウェイにフォールバック
    }
    return defaultEntrywayUrl;
  }

  /// ハンドル（またはメール）とアプリパスワードで Bluesky にログインする。
  Future<BlueskySession> createSession({
    required String identifier,
    required String password,
    String? customPdsUrl,
  }) async {
    final cleanId = normalizeActorInput(identifier);
    final cleanPw = password.trim();
    if (cleanId.isEmpty || cleanPw.isEmpty) {
      throw const BlueskyApiException('ハンドル（またはメールアドレス）とアプリパスワードを入力してください');
    }

    final initialPds = (customPdsUrl != null && customPdsUrl.trim().isNotEmpty)
        ? _cleanBaseUrl(customPdsUrl)
        : await resolvePdsUrl(cleanId);

    final uri = Uri.parse('$initialPds/xrpc/com.atproto.server.createSession');
    final res = await _client
        .post(
          uri,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'identifier': cleanId,
            'password': cleanPw,
          }),
        )
        .timeout(const Duration(seconds: 15));

    if (res.statusCode != 200) {
      throw _buildError(res, defaultPrefix: 'ログインに失敗しました');
    }

    final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final did = (json['did'] as String?)?.trim() ?? '';
    final handle = (json['handle'] as String?)?.trim() ?? cleanId;
    final accessJwt = (json['accessJwt'] as String?)?.trim() ?? '';
    final refreshJwt = (json['refreshJwt'] as String?)?.trim() ?? '';
    if (did.isEmpty || accessJwt.isEmpty || refreshJwt.isEmpty) {
      throw const BlueskyApiException('サーバーから有効なセッショントークンを取得できませんでした');
    }

    final resolvedPds = extractPdsEndpointFromDidDoc(json['didDoc']) ?? initialPds;

    final session = BlueskySession(
      did: did,
      handle: handle,
      pdsUrl: resolvedPds,
      accessJwt: accessJwt,
      refreshJwt: refreshJwt,
    );

    // プロフィール情報（表示名・アイコン）も取得してセッションに添える
    try {
      final profile = await getProfile(did, session: session);
      session.handle = profile.handle.isNotEmpty ? profile.handle : session.handle;
      session.displayName = profile.displayName;
      session.avatarUrl = profile.avatarUrl;
    } catch (_) {}

    return session;
  }

  /// セッショントークン（`accessJwt` / `refreshJwt`）を単一フライトで更新する。
  Future<bool> refreshSession(BlueskySession session) {
    final existing = _refreshLocks[session.did];
    if (existing != null) return existing;

    final future = _doRefreshSession(session).whenComplete(() {
      _refreshLocks.remove(session.did);
    });
    _refreshLocks[session.did] = future;
    return future;
  }

  Future<bool> _doRefreshSession(BlueskySession session) async {
    try {
      final uri = Uri.parse('${_cleanBaseUrl(session.pdsUrl)}/xrpc/com.atproto.server.refreshSession');
      final res = await _client.post(
        uri,
        headers: {
          'Authorization': 'Bearer ${session.refreshJwt}',
        },
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return false;
      final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final nextAccess = (json['accessJwt'] as String?)?.trim() ?? '';
      final nextRefresh = (json['refreshJwt'] as String?)?.trim() ?? '';
      if (nextAccess.isEmpty || nextRefresh.isEmpty) return false;
      session.accessJwt = nextAccess;
      session.refreshJwt = nextRefresh;
      final nextHandle = (json['handle'] as String?)?.trim() ?? '';
      if (nextHandle.isNotEmpty) session.handle = nextHandle;
      final pds = extractPdsEndpointFromDidDoc(json['didDoc']);
      if (pds != null) session.pdsUrl = pds;
      session.updatedAt = DateTime.now();
      await onSessionUpdated?.call(session);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// XRPC GET を実行する（トークン期限切れ時の自動リフレッシュ＆レート制限 429 時のリトライ付き）。
  Future<Map<String, dynamic>> _xrpcGet(
    String nsid, {
    Map<String, dynamic>? query,
    BlueskySession? session,
  }) async {
    final res = await _sendWithRetryAndRefresh(
      session: session,
      send: (activeSession) {
        final base = activeSession != null ? _cleanBaseUrl(activeSession.pdsUrl) : publicAppViewUrl;
        final uri = _buildUri('$base/xrpc/$nsid', query);
        return _client.get(
          uri,
          headers: {
            'Accept': 'application/json',
            if (activeSession != null) 'Authorization': 'Bearer ${activeSession.accessJwt}',
          },
        ).timeout(const Duration(seconds: 20));
      },
    );

    if (res.statusCode != 200) {
      throw _buildError(res);
    }
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  /// XRPC POST を実行する（認証必須操作用）。
  Future<Map<String, dynamic>> _xrpcPost(
    String nsid, {
    required BlueskySession session,
    Map<String, dynamic>? body,
  }) async {
    final res = await _sendWithRetryAndRefresh(
      session: session,
      send: (activeSession) {
        final base = _cleanBaseUrl(activeSession!.pdsUrl);
        final uri = Uri.parse('$base/xrpc/$nsid');
        return _client
            .post(
              uri,
              headers: {
                'Accept': 'application/json',
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${activeSession.accessJwt}',
              },
              body: body != null ? jsonEncode(body) : null,
            )
            .timeout(const Duration(seconds: 20));
      },
    );

    if (res.statusCode != 200) {
      throw _buildError(res);
    }
    if (res.bodyBytes.isEmpty) return const {};
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  Future<http.Response> _sendWithRetryAndRefresh({
    required BlueskySession? session,
    required Future<http.Response> Function(BlueskySession? session) send,
  }) async {
    var res = await send(session);

    // ATProto の期限切れトークン (401 または 400 ExpiredToken) は自動更新して 1 回再試行
    if (session != null && _isExpiredTokenResponse(res)) {
      final refreshed = await refreshSession(session);
      if (refreshed) {
        res = await send(session);
      }
    }

    // レート制限 (HTTP 429) は Retry-After 秒数（最大 5 秒）待機して 1 回再試行
    if (res.statusCode == 429) {
      final retryHeader = int.tryParse(res.headers['retry-after'] ?? '');
      final waitSec = (retryHeader != null && retryHeader > 0) ? retryHeader.clamp(1, 5) : 2;
      await Future<void>.delayed(Duration(seconds: waitSec));
      res = await send(session);
    }

    return res;
  }

  static bool _isExpiredTokenResponse(http.Response res) {
    if (res.statusCode == 401) return true;
    if (res.statusCode == 400 && res.bodyBytes.isNotEmpty) {
      try {
        final json = jsonDecode(utf8.decode(res.bodyBytes));
        if (json is Map && json['error'] == 'ExpiredToken') return true;
      } catch (_) {}
    }
    return false;
  }

  static Uri _buildUri(String basePath, Map<String, dynamic>? query) {
    final base = Uri.parse(basePath);
    if (query == null || query.isEmpty) return base;
    final parts = <String>[];
    for (final MapEntry(:key, :value) in query.entries) {
      if (value == null) continue;
      if (value is Iterable) {
        for (final item in value) {
          if (item != null) {
            parts.add('${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent('$item')}');
          }
        }
      } else {
        parts.add('${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent('$value')}');
      }
    }
    return base.replace(query: parts.join('&'));
  }

  static BlueskyApiException _buildError(http.Response res, {String? defaultPrefix}) {
    String? errCode;
    String? errMsg;
    if (res.bodyBytes.isNotEmpty) {
      try {
        final decoded = jsonDecode(utf8.decode(res.bodyBytes));
        if (decoded is Map) {
          errCode = decoded['error'] as String?;
          errMsg = decoded['message'] as String?;
        }
      } catch (_) {}
    }
    final readable = switch ((res.statusCode, errCode)) {
      (_, 'AccountTakedown') => 'このアカウントは凍結または停止されています',
      (400, 'InvalidRequest') when (errMsg ?? '').toLowerCase().contains('actor') =>
        '指定された Bluesky アカウントが見つかりませんでした',
      (401, _) => '認証エラーまたはアプリパスワードが正しくありません（設定画面から発行したアプリパスワードをご確認ください）',
      (429, _) => 'API のレート制限に達しました。少し時間をおいて再試行してください',
      _ => [
          ?defaultPrefix,
          if (errMsg != null && errMsg.isNotEmpty) errMsg else 'HTTP ${res.statusCode}',
        ].join(': '),
    };
    return BlueskyApiException(
      readable,
      statusCode: res.statusCode,
      errorCode: errCode,
    );
  }

  /// 指定アカウントのプロフィールを取得する。
  Future<BlueskyAccount> getProfile(String actorInput, {BlueskySession? session}) async {
    final actor = normalizeActorInput(actorInput);
    if (actor.isEmpty) {
      throw const BlueskyApiException('チェックする @ハンドル名を入力してください');
    }
    final json = await _xrpcGet(
      'app.bsky.actor.getProfile',
      query: {'actor': actor},
      session: session,
    );
    return BlueskyAccount.fromProfileJson(json);
  }

  /// 指定アカウントのフォロー一覧を全ページ取得する。
  Future<List<BlueskyAccount>> fetchAllFollows(
    String actorDidOrHandle, {
    BlueskySession? session,
    void Function(int count)? onPageProgress,
    bool Function()? isCancelled,
  }) async {
    final out = <BlueskyAccount>[];
    final seenDids = <String>{};
    String? cursor;
    var order = 0;

    while (true) {
      if (isCancelled != null && isCancelled()) break;
      final json = await _xrpcGet(
        'app.bsky.graph.getFollows',
        query: {
          'actor': actorDidOrHandle,
          'limit': 100,
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
        },
        session: session,
      );
      final list = json['follows'];
      if (list is List) {
        for (final raw in list) {
          if (raw is Map<String, dynamic>) {
            final acc = BlueskyAccount.fromProfileJson(raw, orderIndex: order++);
            if (acc.did.isNotEmpty && seenDids.add(acc.did)) {
              out.add(acc);
            }
          }
        }
      }
      onPageProgress?.call(out.length);
      final nextCursor = (json['cursor'] as String?)?.trim();
      if (nextCursor == null || nextCursor.isEmpty || (list is List && list.isEmpty)) {
        break;
      }
      cursor = nextCursor;
    }
    return out;
  }

  /// 指定アカウントのフォロワー一覧を全ページ取得する。
  Future<List<BlueskyAccount>> fetchAllFollowers(
    String actorDidOrHandle, {
    BlueskySession? session,
    void Function(int count)? onPageProgress,
    bool Function()? isCancelled,
  }) async {
    final out = <BlueskyAccount>[];
    final seenDids = <String>{};
    String? cursor;
    var order = 0;

    while (true) {
      if (isCancelled != null && isCancelled()) break;
      final json = await _xrpcGet(
        'app.bsky.graph.getFollowers',
        query: {
          'actor': actorDidOrHandle,
          'limit': 100,
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
        },
        session: session,
      );
      final list = json['followers'];
      if (list is List) {
        for (final raw in list) {
          if (raw is Map<String, dynamic>) {
            final acc = BlueskyAccount.fromProfileJson(raw, orderIndex: order++);
            if (acc.did.isNotEmpty && seenDids.add(acc.did)) {
              out.add(acc);
            }
          }
        }
      }
      onPageProgress?.call(out.length);
      final nextCursor = (json['cursor'] as String?)?.trim();
      if (nextCursor == null || nextCursor.isEmpty || (list is List && list.isEmpty)) {
        break;
      }
      cursor = nextCursor;
    }
    return out;
  }

  /// 指定アカウントのフォロー・フォロワーを全件取得し、「相互フォロー」「片思い」「片思われ」に分類する。
  Future<GraphCheckSnapshot> checkMutualGraph(
    String actorInput, {
    BlueskySession? session,
    GraphProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    final targetProfile = await getProfile(actorInput, session: session);
    var followsLoaded = 0;
    var followersLoaded = 0;

    void report() {
      onProgress?.call(
        followsLoaded: followsLoaded,
        followsTotal: targetProfile.followsCount,
        followersLoaded: followersLoaded,
        followersTotal: targetProfile.followersCount,
      );
    }

    report();

    final results = await Future.wait([
      fetchAllFollows(
        targetProfile.did,
        session: session,
        isCancelled: isCancelled,
        onPageProgress: (c) {
          followsLoaded = c;
          report();
        },
      ),
      fetchAllFollowers(
        targetProfile.did,
        session: session,
        isCancelled: isCancelled,
        onPageProgress: (c) {
          followersLoaded = c;
          report();
        },
      ),
    ]);

    final follows = results[0];
    final followers = results[1];

    final followerByDid = <String, BlueskyAccount>{
      for (final f in followers) f.did: f,
    };
    final followDids = <String>{
      for (final f in follows) f.did,
    };

    final isInspectingSelf = session != null && session.did == targetProfile.did;
    final merged = <BlueskyAccount>[];
    var order = 0;

    // 1. フォロー中アカウント（相互 or 片思い）
    for (final f in follows) {
      final matchedFollower = followerByDid[f.did];
      final isMutual = matchedFollower != null || (isInspectingSelf && f.isViewerFollowedBy);
      merged.add(
        f.copyWith(
          relation: isMutual ? FollowRelationKind.mutual : FollowRelationKind.followingOnly,
          orderIndex: order++,
          viewerFollowedByUri: f.viewerFollowedByUri ?? matchedFollower?.viewerFollowedByUri,
        ),
      );
    }

    // 2. まだフォローしていないフォロワー（片思われ）
    for (final fr in followers) {
      if (followDids.contains(fr.did)) continue;
      final isMutual = isInspectingSelf && fr.isViewerFollowing;
      merged.add(
        fr.copyWith(
          relation: isMutual ? FollowRelationKind.mutual : FollowRelationKind.followerOnly,
          orderIndex: order++,
        ),
      );
    }

    return GraphCheckSnapshot(
      targetProfile: targetProfile,
      accounts: merged,
      followsFetchedCount: follows.length,
      followersFetchedCount: followers.length,
      fetchedAt: DateTime.now(),
    );
  }

  /// 対象 DID をフォローし、作成されたレコードの AT-URI を返す。
  Future<String> follow(BlueskySession session, String targetDid) async {
    final json = await _xrpcPost(
      'com.atproto.repo.createRecord',
      session: session,
      body: {
        'repo': session.did,
        'collection': 'app.bsky.graph.follow',
        'record': {
          r'$type': 'app.bsky.graph.follow',
          'subject': targetDid,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        },
      },
    );
    return (json['uri'] as String?)?.trim() ?? 'at://${session.did}/app.bsky.graph.follow/created';
  }

  /// 対象 DID のフォローを解除する。
  Future<void> unfollow(
    BlueskySession session, {
    required String targetDid,
    String? followingUri,
  }) async {
    var rkey = extractRkey(followingUri);
    rkey ??= await _findRecordRkeyBySubject(
      session,
      collection: 'app.bsky.graph.follow',
      targetDid: targetDid,
    );
    if (rkey == null) return;

    await _xrpcPost(
      'com.atproto.repo.deleteRecord',
      session: session,
      body: {
        'repo': session.did,
        'collection': 'app.bsky.graph.follow',
        'rkey': rkey,
      },
    );
  }

  /// 対象 DID をミュートする（非公開・相手に通知や公開レコードとして残らない）。
  Future<void> mute(BlueskySession session, String targetDid) async {
    await _xrpcPost(
      'app.bsky.graph.muteActor',
      session: session,
      body: {'actor': targetDid},
    );
  }

  /// 対象 DID のミュートを解除する。
  Future<void> unmute(BlueskySession session, String targetDid) async {
    await _xrpcPost(
      'app.bsky.graph.unmuteActor',
      session: session,
      body: {'actor': targetDid},
    );
  }

  /// 対象 DID をブロックし、作成されたブロックレコードの AT-URI を返す。
  Future<String> block(BlueskySession session, String targetDid) async {
    final json = await _xrpcPost(
      'com.atproto.repo.createRecord',
      session: session,
      body: {
        'repo': session.did,
        'collection': 'app.bsky.graph.block',
        'record': {
          r'$type': 'app.bsky.graph.block',
          'subject': targetDid,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        },
      },
    );
    return (json['uri'] as String?)?.trim() ?? 'at://${session.did}/app.bsky.graph.block/created';
  }

  /// 対象 DID のブロックを解除する。
  Future<void> unblock(
    BlueskySession session, {
    required String targetDid,
    String? blockingUri,
  }) async {
    var rkey = extractRkey(blockingUri);
    rkey ??= await _findRecordRkeyBySubject(
      session,
      collection: 'app.bsky.graph.block',
      targetDid: targetDid,
    );
    if (rkey == null) return;

    await _xrpcPost(
      'com.atproto.repo.deleteRecord',
      session: session,
      body: {
        'repo': session.did,
        'collection': 'app.bsky.graph.block',
        'rkey': rkey,
      },
    );
  }

  /// `followingUri` / `blockingUri` が未取得だった場合のフォールバックとして、リポジトリ内から対象 DID の `rkey` を検索する。
  Future<String?> _findRecordRkeyBySubject(
    BlueskySession session, {
    required String collection,
    required String targetDid,
  }) async {
    // まずフォローの場合は高速な getRelationships を試す
    if (collection == 'app.bsky.graph.follow') {
      try {
        final relJson = await _xrpcGet(
          'app.bsky.graph.getRelationships',
          query: {
            'actor': session.did,
            'others': [targetDid],
          },
          session: session,
        );
        final rels = relJson['relationships'];
        if (rels is List && rels.isNotEmpty && rels.first is Map) {
          final uri = (rels.first as Map)['following'] as String?;
          final rkey = extractRkey(uri);
          if (rkey != null) return rkey;
        }
      } catch (_) {}
    }

    String? cursor;
    for (var page = 0; page < 50; page++) {
      final json = await _xrpcGet(
        'com.atproto.repo.listRecords',
        query: {
          'repo': session.did,
          'collection': collection,
          'limit': 100,
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
        },
        session: session,
      );
      final records = json['records'];
      if (records is List) {
        for (final r in records) {
          if (r is Map) {
            final val = r['value'];
            if (val is Map && val['subject'] == targetDid) {
              return extractRkey(r['uri'] as String?);
            }
          }
        }
      }
      final next = (json['cursor'] as String?)?.trim();
      if (next == null || next.isEmpty) break;
      cursor = next;
    }
    return null;
  }

  /// ログイン中アカウントのミュート一覧を取得する。
  Future<List<BlueskyAccount>> fetchMutedAccounts(BlueskySession session) async {
    final out = <BlueskyAccount>[];
    String? cursor;
    var order = 0;
    while (true) {
      final json = await _xrpcGet(
        'app.bsky.graph.getMutes',
        query: {
          'limit': 100,
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
        },
        session: session,
      );
      final list = json['mutes'];
      if (list is List) {
        for (final raw in list) {
          if (raw is Map<String, dynamic>) {
            out.add(BlueskyAccount.fromProfileJson(raw, orderIndex: order++).copyWith(viewerMuted: true));
          }
        }
      }
      final next = (json['cursor'] as String?)?.trim();
      if (next == null || next.isEmpty || (list is List && list.isEmpty)) break;
      cursor = next;
    }
    return out;
  }

  /// ログイン中アカウントのブロック一覧を取得する。
  Future<List<BlueskyAccount>> fetchBlockedAccounts(BlueskySession session) async {
    final out = <BlueskyAccount>[];
    String? cursor;
    var order = 0;
    while (true) {
      final json = await _xrpcGet(
        'app.bsky.graph.getBlocks',
        query: {
          'limit': 100,
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
        },
        session: session,
      );
      final list = json['blocks'];
      if (list is List) {
        for (final raw in list) {
          if (raw is Map<String, dynamic>) {
            final acc = BlueskyAccount.fromProfileJson(raw, orderIndex: order++);
            out.add(
              acc.isViewerBlocking
                  ? acc
                  : acc.copyWith(viewerBlockingUri: 'at://${session.did}/app.bsky.graph.block/unknown'),
            );
          }
        }
      }
      final next = (json['cursor'] as String?)?.trim();
      if (next == null || next.isEmpty || (list is List && list.isEmpty)) break;
      cursor = next;
    }
    return out;
  }
}
