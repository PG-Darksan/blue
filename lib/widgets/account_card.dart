import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../controllers/checker_controller.dart';
import '../models/bluesky_models.dart';
import 'jev_settings_dialog.dart';

/// Bluesky のブロック仕様（公開レコード・ブロ解不可）を案内した上で実行確認するダイアログ。
Future<bool> confirmBlueskyBlock(
  BuildContext context, {
  required String targetTitle,
  int count = 1,
}) async {
  final res = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(count > 1 ? '$count件のアカウントをブロックしますか？' : '$targetTitle をブロックしますか？'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: const Text(
          '【Bluesky のブロック仕様のご確認】\n'
          '・リプライや引用を含め相手との関わりを強力に遮断します。\n'
          '・AT Protocol の仕様上、ブロック情報は公開レコードとして記録されます（相手に気づかれたくない場合は「ミュート」がおすすめです）。\n'
          '・ブロックしても相手側のフォローデータは消えないため、解除するとフォロワー状態が戻ります（自分がフォロー中の場合は同時にフォロー解除も行います）。',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(dialogContext).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('ブロックする'),
        ),
      ],
    ),
  );
  return res == true;
}

/// プロフィールアイコン丸表示ウィジェット。
class BlueskyAvatar extends StatelessWidget {
  const BlueskyAvatar({
    super.key,
    required this.url,
    this.radius = 22,
  });

  final String url;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: scheme.primaryContainer,
        child: Icon(Icons.person_outline, size: radius, color: scheme.onPrimaryContainer),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.surfaceContainerHighest,
      child: ClipOval(
        child: Image.network(
          trimmed,
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Icon(
            Icons.person_outline,
            size: radius,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 一覧内の 1 アカウント行カード。
class AccountCard extends StatelessWidget {
  const AccountCard({
    super.key,
    required this.account,
    required this.controller,
    required this.onInspectActor,
  });

  final BlueskyAccount account;
  final CheckerController controller;
  final ValueChanged<String> onInspectActor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final selected = controller.isSelected(account.did);
    final busy = controller.isBusy(account.did);
    final selectionMode = controller.hasSelection;
    final jevProb = controller.jev.cachedProbability(account.toJevCandidate());

    return Material(
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.32) : Colors.transparent,
      child: InkWell(
        onTap: () {
          if (selectionMode) {
            controller.toggleSelect(account.did);
          } else {
            showAccountDetailSheet(
              context,
              account: account,
              controller: controller,
              onInspectActor: onInspectActor,
            );
          }
        },
        onLongPress: () => controller.toggleSelect(account.did),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selectionMode || controller.isLoggedIn)
                Padding(
                  padding: const EdgeInsets.only(right: 6, top: 4),
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      visualDensity: VisualDensity.compact,
                      value: selected,
                      onChanged: (_) => controller.toggleSelect(account.did),
                    ),
                  ),
                ),
              BlueskyAvatar(url: account.avatarUrl, radius: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            account.effectiveName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                    Text(
                      account.atHandle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 5,
                      runSpacing: 4,
                      children: [
                        _RelationBadge(relation: account.relation),
                        if (jevProb != null)
                          _SmallBadge(
                            label: '♀ ${(jevProb * 100).round()}%',
                            color: jevProb >= controller.jev.threshold ? kJevPink : scheme.outline,
                          ),
                        if (account.viewerMuted)
                          _SmallBadge(label: 'ミュート中', color: Colors.blueGrey.shade600),
                        if (account.isViewerBlocking)
                          _SmallBadge(label: 'ブロック中', color: scheme.error),
                        if (account.viewerBlockedBy)
                          _SmallBadge(label: '被ブロック', color: scheme.error),
                      ],
                    ),
                    if (account.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        account.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(height: 1.3),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              _buildTrailingActions(context, busy),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTrailingActions(BuildContext context, bool busy) {
    final scheme = Theme.of(context).colorScheme;
    if (busy) {
      return const Padding(
        padding: EdgeInsets.all(10),
        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (controller.isLoggedIn && !account.isViewerBlocking)
          account.isViewerFollowing
              ? OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 32),
                  ),
                  onPressed: () async {
                    try {
                      await controller.toggleFollowAccount(account);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('操作失敗: $e')));
                      }
                    }
                  },
                  child: const Text('解除', style: TextStyle(fontSize: 12)),
                )
              : FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 32),
                  ),
                  onPressed: () async {
                    try {
                      await controller.toggleFollowAccount(account);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('操作失敗: $e')));
                      }
                    }
                  },
                  child: Text(
                    account.isViewerFollowedBy || account.relation == FollowRelationKind.followerOnly
                        ? 'フォロバ'
                        : 'フォロー',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
        PopupMenuButton<String>(
          tooltip: 'メニュー',
          padding: EdgeInsets.zero,
          icon: Icon(Icons.more_vert, size: 20, color: scheme.onSurfaceVariant),
          onSelected: (action) async {
            switch (action) {
              case 'inspect':
                onInspectActor(account.handle);
              case 'open':
                await launchUrl(Uri.parse(account.profileWebUrl), mode: LaunchMode.externalApplication);
              case 'mute':
                try {
                  await controller.toggleMuteAccount(account);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ミュート操作失敗: $e')));
                  }
                }
              case 'block':
                if (!account.isViewerBlocking) {
                  final ok = await confirmBlueskyBlock(context, targetTitle: account.atHandle);
                  if (!ok) return;
                }
                try {
                  await controller.toggleBlockAccount(account);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ブロック操作失敗: $e')));
                  }
                }
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'inspect',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.people_outline),
                title: Text('この人の相互・フォロワーを解析'),
              ),
            ),
            const PopupMenuItem(
              value: 'open',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.open_in_new),
                title: Text('Bluesky でプロフィールを開く'),
              ),
            ),
            if (controller.isLoggedIn) ...[
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'mute',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(account.viewerMuted ? Icons.volume_up_outlined : Icons.volume_off_outlined),
                  title: Text(account.viewerMuted ? 'ミュートを解除' : 'ミュートする（非公開）'),
                ),
              ),
              PopupMenuItem(
                value: 'block',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    account.isViewerBlocking ? Icons.lock_open_outlined : Icons.block,
                    color: account.isViewerBlocking ? null : scheme.error,
                  ),
                  title: Text(
                    account.isViewerBlocking ? 'ブロックを解除' : 'ブロックする',
                    style: TextStyle(color: account.isViewerBlocking ? null : scheme.error),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _RelationBadge extends StatelessWidget {
  const _RelationBadge({required this.relation});

  final FollowRelationKind relation;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (relation) {
      FollowRelationKind.mutual => ('相互', const Color(0xFF00897B)),
      FollowRelationKind.followingOnly => ('片思い', const Color(0xFFE65100)),
      FollowRelationKind.followerOnly => ('片思われ', const Color(0xFF5E35B1)),
      FollowRelationKind.none => ('解除済', Colors.grey),
    };
    return _SmallBadge(label: label, color: color);
  }
}

class _SmallBadge extends StatelessWidget {
  const _SmallBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.8),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}

/// アカウントの詳細プロフィール＆操作ボトムシート。
Future<void> showAccountDetailSheet(
  BuildContext context, {
  required BlueskyAccount account,
  required CheckerController controller,
  required ValueChanged<String> onInspectActor,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      return ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final latest = controller.snapshot?.accounts.firstWhere(
                (a) => a.did == account.did,
                orElse: () => account,
              ) ??
              account;
          final scheme = Theme.of(context).colorScheme;
          final text = Theme.of(context).textTheme;
          final prob = controller.jev.cachedProbability(latest.toJevCandidate());

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      BlueskyAvatar(url: latest.avatarUrl, radius: 30),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              latest.effectiveName,
                              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            Text(
                              latest.atHandle,
                              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                _RelationBadge(relation: latest.relation),
                                if (prob != null)
                                  _SmallBadge(
                                    label: 'Jev 女性確率 ${(prob * 100).round()}%',
                                    color: prob >= controller.jev.threshold ? kJevPink : scheme.outline,
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (latest.description.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: SelectableText(
                        latest.description,
                        style: text.bodySmall?.copyWith(height: 1.4),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          onInspectActor(latest.handle);
                        },
                        icon: const Icon(Icons.people_alt_outlined, size: 18),
                        label: const Text('この人の相互・フォロワーを解析'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => launchUrl(
                          Uri.parse(latest.profileWebUrl),
                          mode: LaunchMode.externalApplication,
                        ),
                        icon: const Icon(Icons.open_in_new, size: 17),
                        label: const Text('Bluesky で開く'),
                      ),
                    ],
                  ),
                  if (controller.isLoggedIn) ...[
                    const Divider(height: 24),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (!latest.isViewerBlocking)
                          FilledButton.tonalIcon(
                            onPressed: controller.isBusy(latest.did)
                                ? null
                                : () => controller.toggleFollowAccount(latest),
                            icon: Icon(
                              latest.isViewerFollowing ? Icons.person_remove_outlined : Icons.person_add_outlined,
                              size: 18,
                            ),
                            label: Text(latest.isViewerFollowing ? 'フォロー解除' : 'フォローする'),
                          ),
                        OutlinedButton.icon(
                          onPressed: controller.isBusy(latest.did)
                              ? null
                              : () => controller.toggleMuteAccount(latest),
                          icon: Icon(
                            latest.viewerMuted ? Icons.volume_up_outlined : Icons.volume_off_outlined,
                            size: 18,
                          ),
                          label: Text(latest.viewerMuted ? 'ミュート解除' : 'ミュート'),
                        ),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: latest.isViewerBlocking ? null : scheme.error,
                          ),
                          onPressed: controller.isBusy(latest.did)
                              ? null
                              : () async {
                                  if (!latest.isViewerBlocking) {
                                    final ok = await confirmBlueskyBlock(
                                      context,
                                      targetTitle: latest.atHandle,
                                    );
                                    if (!ok) return;
                                  }
                                  await controller.toggleBlockAccount(latest);
                                },
                          icon: Icon(
                            latest.isViewerBlocking ? Icons.lock_open_outlined : Icons.block,
                            size: 18,
                          ),
                          label: Text(latest.isViewerBlocking ? 'ブロック解除' : 'ブロック'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
