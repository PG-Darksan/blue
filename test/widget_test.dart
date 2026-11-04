import 'dart:convert';

import 'package:blue/controllers/checker_controller.dart';
import 'package:blue/main.dart';
import 'package:blue/screens/home_screen.dart';
import 'package:blue/services/bluesky_api_service.dart';
import 'package:blue/services/jev_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _jsonResponse(Object body, {int statusCode = 200}) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  group('BlueskyApiService', () {
    test('normalizeActorInput handles handles, bare names, URLs, and DIDs', () {
      expect(BlueskyApiService.normalizeActorInput('@Alice.bsky.social'), 'alice.bsky.social');
      expect(BlueskyApiService.normalizeActorInput('hanako'), 'hanako.bsky.social');
      expect(
        BlueskyApiService.normalizeActorInput('https://bsky.app/profile/yui.bsky.social/post/3k'),
        'yui.bsky.social',
      );
      expect(BlueskyApiService.normalizeActorInput('did:plc:abc123'), 'did:plc:abc123');
    });

    test('checkMutualGraph paginates and classifies mutual, followingOnly, and followerOnly', () async {
      final client = MockClient((req) async {
        final path = req.url.path;
        if (path.endsWith('/app.bsky.actor.getProfile')) {
          return _jsonResponse({
            'did': 'did:plc:me',
            'handle': 'me.bsky.social',
            'displayName': '自分',
            'followsCount': 2,
            'followersCount': 2,
          });
        }
        if (path.endsWith('/app.bsky.graph.getFollows')) {
          final cursor = req.url.queryParameters['cursor'];
          if (cursor == null) {
            return _jsonResponse({
              'cursor': 'page2',
              'follows': [
                {
                  'did': 'did:plc:mutual1',
                  'handle': 'hanako.bsky.social',
                  'displayName': '花子',
                },
              ],
            });
          }
          return _jsonResponse({
            'follows': [
              {
                'did': 'did:plc:oneway1',
                'handle': 'taro.bsky.social',
                'displayName': '太郎',
              },
            ],
          });
        }
        if (path.endsWith('/app.bsky.graph.getFollowers')) {
          return _jsonResponse({
            'followers': [
              {
                'did': 'did:plc:mutual1',
                'handle': 'hanako.bsky.social',
                'displayName': '花子',
              },
              {
                'did': 'did:plc:fan1',
                'handle': 'yui.bsky.social',
                'displayName': '結衣',
              },
            ],
          });
        }
        return _jsonResponse({'error': 'NotFound'}, statusCode: 404);
      });

      final api = BlueskyApiService(client: client);
      final snap = await api.checkMutualGraph('@me');

      expect(snap.mutualCount, 1);
      expect(snap.followingOnlyCount, 1);
      expect(snap.followerOnlyCount, 1);
      expect(
        snap.accounts.firstWhere((a) => a.did == 'did:plc:mutual1').handle,
        'hanako.bsky.social',
      );
    });

    test('auto-refreshes expired token on HTTP 400 ExpiredToken and completes block/unfollow', () async {
      var refreshed = false;
      final deletedCollections = <String>[];
      final createdCollections = <String>[];

      final client = MockClient((req) async {
        final path = req.url.path;
        if (path.endsWith('/com.atproto.server.createSession')) {
          return _jsonResponse({
            'did': 'did:plc:me',
            'handle': 'me.bsky.social',
            'accessJwt': 'expired_jwt',
            'refreshJwt': 'refresh_1',
            'didDoc': {
              'service': [
                {
                  'id': '#atproto_pds',
                  'type': 'AtprotoPersonalDataServer',
                  'serviceEndpoint': 'https://pds.example.com',
                },
              ],
            },
          });
        }
        if (path.endsWith('/app.bsky.actor.getProfile')) {
          return _jsonResponse({
            'did': 'did:plc:me',
            'handle': 'me.bsky.social',
            'displayName': 'Me',
          });
        }
        if (path.endsWith('/com.atproto.server.refreshSession')) {
          refreshed = true;
          return _jsonResponse({
            'did': 'did:plc:me',
            'handle': 'me.bsky.social',
            'accessJwt': 'fresh_jwt',
            'refreshJwt': 'refresh_2',
          });
        }
        if (req.headers['Authorization'] == 'Bearer expired_jwt') {
          return _jsonResponse(
            {'error': 'ExpiredToken', 'message': 'Token has expired'},
            statusCode: 400,
          );
        }
        if (path.endsWith('/com.atproto.repo.createRecord')) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final col = body['collection'] as String;
          createdCollections.add(col);
          return _jsonResponse({'uri': 'at://did:plc:me/$col/rkey99'});
        }
        if (path.endsWith('/com.atproto.repo.deleteRecord')) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          deletedCollections.add('${body['collection']}:${body['rkey']}');
          return _jsonResponse({});
        }
        return _jsonResponse({});
      });

      final api = BlueskyApiService(client: client);
      final session = await api.createSession(
        identifier: 'me.bsky.social',
        password: 'xxxx-xxxx-xxxx-xxxx',
        customPdsUrl: 'https://bsky.social',
      );
      expect(session.pdsUrl, 'https://pds.example.com');

      final blockUri = await api.block(session, 'did:plc:spam');
      expect(refreshed, isTrue);
      expect(session.accessJwt, 'fresh_jwt');
      expect(blockUri, 'at://did:plc:me/app.bsky.graph.block/rkey99');
      expect(createdCollections, ['app.bsky.graph.block']);

      await api.unblock(session, targetDid: 'did:plc:spam', blockingUri: blockUri);
      expect(deletedCollections, ['app.bsky.graph.block:rkey99']);
    });
  });

  group('JevService & HomeScreen integration', () {
    testWidgets('filters accounts to female-only using Jev and updates cost bar', (tester) async {
      final bskyClient = MockClient((req) async {
        final path = req.url.path;
        if (path.endsWith('/app.bsky.actor.getProfile')) {
          return _jsonResponse({
            'did': 'did:plc:target',
            'handle': 'target.bsky.social',
            'displayName': 'ターゲット',
            'followsCount': 2,
            'followersCount': 0,
          });
        }
        if (path.endsWith('/app.bsky.graph.getFollows')) {
          return _jsonResponse({
            'follows': [
              {
                'did': 'did:plc:f1',
                'handle': 'misaki.bsky.social',
                'displayName': '美咲',
                'description': 'カフェ好き女子大生♀',
              },
              {
                'did': 'did:plc:m1',
                'handle': 'kenji.bsky.social',
                'displayName': '健二',
                'description': 'ラーメン好き会社員',
              },
            ],
          });
        }
        if (path.endsWith('/app.bsky.graph.getFollowers')) {
          return _jsonResponse({'followers': []});
        }
        return _jsonResponse({}, statusCode: 404);
      });

      final jevClient = MockClient((req) async {
        expect(req.url.toString(), JevService.endpoint);
        expect(req.headers['Authorization'], 'Bearer test-key-123');
        return _jsonResponse({
          'answers': {
            'q_0': {'noul': 0.93},
            'q_1': {'noul': 0.04},
          },
          'usage': {
            'input_tokens': 1200,
          },
        });
      });

      final jev = JevService(
        client: jevClient,
        inMemoryOnly: true,
        avatarPreparer: (_, _) async => null,
      );
      await jev.updateSettings(
        apiKey: 'test-key-123',
        onlyFemaleAccounts: false,
        threshold: 0.55,
      );

      final controller = CheckerController(
        api: BlueskyApiService(client: bskyClient),
        jev: jev,
        inMemoryOnly: true,
        batchDelay: Duration.zero,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // ハンドルを入力して解析
      await tester.enterText(find.byType(TextField).first, 'target.bsky.social');
      await tester.tap(find.text('解析'));
      await tester.pumpAndSettle();

      // Jev OFF 時は美咲・健二の両方が表示される
      expect(find.text('美咲'), findsOneWidget);
      expect(find.text('健二'), findsOneWidget);

      // 右上の「女性のみ」ボタンをワンタップして ON にする
      await tester.tap(find.text('女性のみ'));
      await tester.pumpAndSettle();

      // Jev により女性個人アカウント（美咲 93%）のみ表示され、男性（健二 4%）は非表示になる
      expect(find.text('美咲'), findsOneWidget);
      expect(find.text('♀ 93%'), findsOneWidget);
      expect(find.text('健二'), findsNothing);
      expect(jev.totalJudgedAccounts, 2);
      expect(jev.totalInputTokens, 1200);
    });

    testWidgets('BlueskyMutualApp launches cleanly', (tester) async {
      await tester.pumpWidget(const BlueskyMutualApp());
      await tester.pump();
      expect(find.text('相互チェッカー'), findsOneWidget);
    });
  });
}
