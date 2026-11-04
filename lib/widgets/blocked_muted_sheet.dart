import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../controllers/checker_controller.dart';
import '../models/bluesky_models.dart';
import 'account_card.dart';

/// ログイン中アカウントの「ミュート中一覧」「ブロック中一覧」を確認・解除するボトムシート。
Future<void> showBlockedMutedSheet(BuildContext context, CheckerController controller) async {
  if (!controller.isLoggedIn) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _BlockedMutedSheet(controller: controller),
  );
}

class _BlockedMutedSheet extends StatefulWidget {
  const _BlockedMutedSheet({required this.controller});

  final CheckerController controller;

  @override
  State<_BlockedMutedSheet> createState() => _BlockedMutedSheetState();
}

class _BlockedMutedSheetState extends State<_BlockedMutedSheet> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  List<BlueskyAccount>? _mutes;
  List<BlueskyAccount>? _blocks;
  bool _loading = true;
  String? _error;
  final Set<String> _busyDids = {};

  @override
  void initState() {
    super.initState();
    _fetchAll();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _fetchAll() async {
    final session = widget.controller.activeSession;
    if (session == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.controller.api.fetchMutedAccounts(session),
        widget.controller.api.fetchBlockedAccounts(session),
      ]);
      if (!mounted) return;
      setState(() {
        _mutes = results[0];
        _blocks = results[1];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _unmute(BlueskyAccount acc) async {
    final session = widget.controller.activeSession;
    if (session == null || _busyDids.contains(acc.did)) return;
    setState(() => _busyDids.add(acc.did));
    try {
      await widget.controller.api.unmute(session, acc.did);
      if (!mounted) return;
      setState(() {
        _mutes?.removeWhere((x) => x.did == acc.did);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ミュート解除に失敗: $e')));
      }
    } finally {
      if (mounted) setState(() => _busyDids.remove(acc.did));
    }
  }

  Future<void> _unblock(BlueskyAccount acc) async {
    final session = widget.controller.activeSession;
    if (session == null || _busyDids.contains(acc.did)) return;
    setState(() => _busyDids.add(acc.did));
    try {
      await widget.controller.api.unblock(
        session,
        targetDid: acc.did,
        blockingUri: acc.viewerBlockingUri,
      );
      if (!mounted) return;
      setState(() {
        _blocks?.removeWhere((x) => x.did == acc.did);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ブロック解除に失敗: $e')));
      }
    } finally {
      if (mounted) setState(() => _busyDids.remove(acc.did));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muteCount = _mutes?.length ?? 0;
    final blockCount = _blocks?.length ?? 0;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.84),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 12, 4),
              child: Row(
                children: [
                  Icon(Icons.shield_outlined, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'ミュート・ブロック管理',
                      style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    tooltip: '再読込',
                    onPressed: _loading ? null : _fetchAll,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            TabBar(
              controller: _tabs,
              tabs: [
                Tab(text: 'ミュート中 ($muteCount)'),
                Tab(text: 'ブロック中 ($blockCount)'),
              ],
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text('取得エラー: $_error', textAlign: TextAlign.center),
                          ),
                        )
                      : TabBarView(
                          controller: _tabs,
                          children: [
                            _buildList(
                              items: _mutes ?? const [],
                              emptyLabel: 'ミュート中のアカウントはありません',
                              hintText: 'ミュートは非公開データです。相手に知られることなく投稿や通知を非表示にできます。',
                              actionLabel: 'ミュート解除',
                              onAction: _unmute,
                            ),
                            _buildList(
                              items: _blocks ?? const [],
                              emptyLabel: 'ブロック中のアカウントはありません',
                              hintText: 'Bluesky のブロックは AT Protocol 上の公開レコードであり、ブロック解除すると元のフォロワー状態が復活します。',
                              actionLabel: 'ブロック解除',
                              onAction: _unblock,
                            ),
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList({
    required List<BlueskyAccount> items,
    required String emptyLabel,
    required String hintText,
    required String actionLabel,
    required Future<void> Function(BlueskyAccount acc) onAction,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          color: scheme.surfaceContainerLow,
          child: Text(
            hintText,
            style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? Center(child: Text(emptyLabel, style: text.bodyMedium))
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final acc = items[i];
                    final busy = _busyDids.contains(acc.did);
                    return ListTile(
                      leading: BlueskyAvatar(url: acc.avatarUrl, radius: 20),
                      title: Text(acc.effectiveName, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(acc.atHandle, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => launchUrl(
                        Uri.parse(acc.profileWebUrl),
                        mode: LaunchMode.externalApplication,
                      ),
                      trailing: OutlinedButton(
                        style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                        onPressed: busy ? null : () => onAction(acc),
                        child: busy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(actionLabel),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
