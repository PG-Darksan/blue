import 'package:flutter/material.dart';

import '../controllers/checker_controller.dart';
import '../services/jev_service.dart';

const Color kJevPink = Color(0xFFE91E63);

/// AppBar に配置する「♀ 女性のみ」ワンタップ切り替えボタン（長押しで Jev 設定・費用ダイアログを開く）。
class FemaleFilterToggleButton extends StatelessWidget {
  const FemaleFilterToggleButton({
    super.key,
    required this.controller,
    required this.onOpenSettings,
  });

  final CheckerController controller;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final jev = controller.jev;
    final active = jev.isActive;
    final stats = controller.currentTabJevStats;
    final label = (active && controller.snapshot != null) ? '女性 ${stats.femaleCount}件' : '女性のみ';

    return Tooltip(
      message: jev.hasApiKey
          ? 'フォロー・フォロワー一覧で女性個人アカウントのみ表示（タップで切替 / 長押しで Jev 設定・費用確認）'
          : 'Jev API キーを設定して女性アカウントのみ表示する',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () {
            if (!jev.hasApiKey) {
              onOpenSettings();
            } else {
              controller.setOnlyFemaleAccounts(!jev.onlyFemaleAccounts);
            }
          },
          onLongPress: onOpenSettings,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: active ? kJevPink.withValues(alpha: 0.14) : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: active ? kJevPink : scheme.outlineVariant,
                width: active ? 1.3 : 1.0,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (controller.isJudgingJev)
                  const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kJevPink),
                  )
                else
                  Icon(
                    Icons.female,
                    size: 16,
                    color: active ? kJevPink : scheme.onSurfaceVariant,
                  ),
                const SizedBox(width: 3),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: active ? kJevPink : scheme.onSurfaceVariant,
                        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 画面上部に常時表示する Jev 稼働状況・掛かった費用バー（`nearby_insta` と共通デザイン）。
class JevUsageBar extends StatelessWidget {
  const JevUsageBar({
    super.key,
    required this.controller,
    required this.onOpenSettings,
  });

  final CheckerController controller;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final jev = controller.jev;
    final costLabel = JevService.formatCostCompact(jev.totalCostUsd);
    final stats = controller.currentTabJevStats;
    final hasSnap = controller.snapshot != null;

    final String statusText;
    if (hasSnap && jev.isActive) {
      final judgingNote = controller.isJudgingJev
          ? '（判定中…）'
          : (stats.unjudgedCount > 0 ? '（未判定 ${stats.unjudgedCount}件）' : '');
      statusText =
          '女性表示 ${stats.femaleCount}件 / 非表示 ${stats.nonFemaleCount}件$judgingNote · Jev費用 $costLabel';
    } else {
      statusText =
          'Jev ${jev.isActive ? '女性のみ表示ON（アイコン＋名前＋自己紹介判定）' : 'OFF'} · 費用 $costLabel';
    }

    return Material(
      color: scheme.surfaceContainerLow,
      child: InkWell(
        onTap: onOpenSettings,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              const Icon(Icons.female, size: 15, color: kJevPink),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              if (hasSnap && jev.isActive && controller.isJudgingJev) ...[
                const SizedBox(width: 6),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: controller.pauseJevJudging,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Text(
                      '停止',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.error,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                ),
              ] else if (hasSnap && jev.isActive && stats.unjudgedCount > 0) ...[
                const SizedBox(width: 6),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => controller.ensureJevJudgedForCurrentTab(judgeAll: true),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Text(
                      '残り全件判定',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: kJevPink,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 6),
              Text(
                '設定',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Jev の通信エラーバナー。
class JevErrorBanner extends StatelessWidget {
  const JevErrorBanner({
    super.key,
    required this.error,
    required this.onOpenSettings,
    required this.onDismiss,
  });

  final String error;
  final VoidCallback onOpenSettings;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                error,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
              ),
            ),
            TextButton(onPressed: onOpenSettings, child: const Text('設定')),
            IconButton(
              tooltip: 'オフにする',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: onDismiss,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}

/// Jev（TypeSafe AI System One）の女性アカウントのみ表示設定と掛かった費用の確認ダイアログ。
Future<void> showJevSettingsDialog(BuildContext context, CheckerController controller) async {
  await controller.jev.ensureLoaded();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _JevSettingsDialog(controller: controller),
  );
}

class _JevSettingsDialog extends StatefulWidget {
  const _JevSettingsDialog({required this.controller});

  final CheckerController controller;

  @override
  State<_JevSettingsDialog> createState() => _JevSettingsDialogState();
}

class _JevSettingsDialogState extends State<_JevSettingsDialog> {
  late final TextEditingController _keyInput = TextEditingController(text: widget.controller.jev.apiKey);
  late bool _femaleOnlyEnabled =
      widget.controller.jev.hasApiKey ? widget.controller.jev.onlyFemaleAccounts : true;
  late double _threshold = widget.controller.jev.threshold;
  bool _obscure = true;
  bool _testing = false;
  ({bool ok, String message})? _testResult;

  @override
  void dispose() {
    _keyInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final jev = widget.controller.jev;
    return ListenableBuilder(
      listenable: jev,
      builder: (context, _) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.female, color: kJevPink),
            SizedBox(width: 6),
            Flexible(child: Text('Jev 女性アカウントのみ表示')),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Bluesky のフォロー・フォロワー一覧で、プロフィールアイコン画像と @ハンドル名・表示名・自己紹介文を '
                  'Jev（TypeSafe AI System One: jev-latest）に渡して判定し、'
                  '女性個人のアカウントのみを表示します（男性・店舗・企業・Bot・性別不明アカウントを非表示）。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.payments_outlined, size: 16, color: scheme.primary),
                          const SizedBox(width: 6),
                          Text('Jev に掛かった費用', style: Theme.of(context).textTheme.labelLarge),
                          const Spacer(),
                          if (jev.totalApiCalls > 0)
                            TextButton(
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                minimumSize: const Size(0, 26),
                              ),
                              onPressed: () async {
                                await jev.resetUsageStats();
                              },
                              child: const Text('費用をリセット'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '累計: ${JevService.formatCostCompact(jev.totalCostUsd)}',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '今回の起動中: ${JevService.formatCostCompact(jev.sessionCostUsd)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '通信 ${jev.totalApiCalls}回 · 判定 ${jev.totalJudgedAccounts}件 · '
                        '入力 ${jev.totalInputTokens} tok（単価 \$0.042 / 100万tok・出力無料・判定済みキャッシュは \$0）',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('女性アカウントのみを表示する'),
                  subtitle: const Text('Bluesky のアイコン画像＋名前＋自己紹介から女性個人アカウントを抽出'),
                  value: _femaleOnlyEnabled,
                  onChanged: (v) => setState(() => _femaleOnlyEnabled = v),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _keyInput,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'TypeSafe API キー',
                    hintText: 'Bearer トークンを入力',
                    helperText: 'この端末内にのみ保存され、外部や第三者には公開されません',
                    helperMaxLines: 2,
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: _obscure ? '表示' : '隠す',
                      icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      '女性判定のしきい値: ${(_threshold * 100).round()}%',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const Spacer(),
                    Text(
                      _threshold <= 0.48 ? '広めに表示' : (_threshold >= 0.70 ? '確実な女性のみ' : '標準'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
                Slider(
                  value: _threshold.clamp(0.40, 0.85),
                  min: 0.40,
                  max: 0.85,
                  divisions: 9,
                  label: '${(_threshold * 100).round()}%',
                  onChanged: (v) => setState(() => _threshold = v),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _testing
                          ? null
                          : () async {
                              setState(() {
                                _testing = true;
                                _testResult = null;
                              });
                              final res = await jev.testConnection(_keyInput.text);
                              if (mounted) {
                                setState(() {
                                  _testing = false;
                                  _testResult = res;
                                });
                              }
                            },
                      icon: _testing
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.check_circle_outline, size: 18),
                      label: const Text('接続テスト'),
                    ),
                    TextButton(
                      onPressed: () async {
                        await jev.clearCache();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('判定キャッシュを消去しました')),
                          );
                        }
                      },
                      child: const Text('判定履歴を消去'),
                    ),
                  ],
                ),
                if (_testResult case final r?) ...[
                  const SizedBox(height: 8),
                  Text(
                    r.message,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: r.ok ? scheme.primary : scheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          FilledButton(
            onPressed: () async {
              final trimmed = _keyInput.text.trim();
              await jev.updateSettings(
                apiKey: trimmed,
                onlyFemaleAccounts: _femaleOnlyEnabled && trimmed.isNotEmpty,
                threshold: _threshold,
              );
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
