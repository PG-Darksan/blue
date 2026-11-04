import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../controllers/checker_controller.dart';
import '../services/bluesky_api_service.dart';

/// Bluesky ログインアカウントの追加・複数アカウント切り替えシートを開く。
Future<void> showLoginAccountsSheet(BuildContext context, CheckerController controller) async {
  await controller.ensureLoaded();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _LoginAccountsSheet(controller: controller),
  );
}

class _LoginAccountsSheet extends StatefulWidget {
  const _LoginAccountsSheet({required this.controller});

  final CheckerController controller;

  @override
  State<_LoginAccountsSheet> createState() => _LoginAccountsSheetState();
}

class _LoginAccountsSheetState extends State<_LoginAccountsSheet> {
  final _handleController = TextEditingController();
  final _passwordController = TextEditingController();
  final _pdsController = TextEditingController();
  bool _obscure = true;
  bool _showAdvancedPds = false;
  bool _checkImmediately = true;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _handleController.dispose();
    _passwordController.dispose();
    _pdsController.dispose();
    super.dispose();
  }

  Future<void> _submitLogin() async {
    final id = _handleController.text.trim();
    final pw = _passwordController.text.trim();
    if (id.isEmpty || pw.isEmpty) {
      setState(() => _error = 'ハンドル（例: alice.bsky.social）とアプリパスワードを入力してください');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final session = await widget.controller.login(
        identifier: id,
        password: pw,
        customPdsUrl: _showAdvancedPds ? _pdsController.text : null,
      );
      if (!mounted) return;
      final shouldCheck = _checkImmediately;
      Navigator.pop(context);
      if (shouldCheck) {
        await widget.controller.checkActor(session.handle);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e is BlueskyApiException ? e.message : 'ログイン失敗: $e';
      });
    }
  }

  Future<void> _openAppPasswordsPage() async {
    final uri = Uri.parse('https://bsky.app/settings/app-passwords');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final c = widget.controller;

    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final sessions = c.sessions;
        final active = c.activeSession;

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.86),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.switch_account, color: scheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Bluesky アカウント管理・ログイン',
                            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '閲覧・相互フォローチェック・Jev 女性抽出だけならログイン不要で使えます。\n'
                      'フォロー解除・ミュート・ブロックなどの操作や自動化を行う場合は、アプリパスワードでログインしてください。',
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    if (sessions.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text(
                        '保存済みのアカウント（タップで切替）',
                        style: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      for (final s in sessions)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Material(
                            color: active?.did == s.did
                                ? scheme.primaryContainer.withValues(alpha: 0.65)
                                : scheme.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(10),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () async {
                                await c.switchSession(s.did);
                                if (context.mounted) Navigator.pop(context);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                child: Row(
                                  children: [
                                    Icon(
                                      active?.did == s.did
                                          ? Icons.radio_button_checked
                                          : Icons.radio_button_unchecked,
                                      size: 20,
                                      color: active?.did == s.did ? scheme.primary : scheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            s.displayLabel,
                                            style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                                          ),
                                          Text(
                                            active?.did == s.did ? '現在使用中' : 'タップしてこのアカウントに切り替え',
                                            style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                                          ),
                                        ],
                                      ),
                                    ),
                                    TextButton(
                                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                                      onPressed: () async {
                                        await c.switchSession(s.did);
                                        if (context.mounted) Navigator.pop(context);
                                        await c.checkActor(s.handle);
                                      },
                                      child: const Text('解析'),
                                    ),
                                    IconButton(
                                      tooltip: 'ログアウト（削除）',
                                      visualDensity: VisualDensity.compact,
                                      icon: Icon(Icons.logout, size: 18, color: scheme.error),
                                      onPressed: () => c.removeSession(s.did),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (active != null)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                            onPressed: () async {
                              await c.switchSession(null);
                              if (context.mounted) Navigator.pop(context);
                            },
                            icon: const Icon(Icons.visibility_outlined, size: 16),
                            label: const Text('未ログイン（公開閲覧モード）に切り替える'),
                          ),
                        ),
                      const Divider(height: 20),
                    ] else
                      const SizedBox(height: 14),

                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'アプリパスワードで新しくログイン',
                            style: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                          onPressed: _openAppPasswordsPage,
                          icon: const Icon(Icons.open_in_new, size: 15),
                          label: const Text('アプリパスワード発行画面'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _handleController,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'ハンドル名 または メールアドレス',
                        hintText: '例: alice.bsky.social',
                        prefixIcon: Icon(Icons.alternate_email, size: 18),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _passwordController,
                      obscureText: _obscure,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submitLogin(),
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: 'アプリパスワード（xxxx-xxxx-xxxx-xxxx）',
                        helperText: 'パスワード本体は端末に保存せず、セッショントークンのみアプリ領域に保持します',
                        helperMaxLines: 2,
                        prefixIcon: const Icon(Icons.key_outlined, size: 18),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: _obscure ? '表示' : '隠す',
                          icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: const Text('ログイン後にすぐ自分の相互フォローを解析する'),
                            value: _checkImmediately,
                            onChanged: (v) => setState(() => _checkImmediately = v ?? true),
                          ),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                          onPressed: () => setState(() => _showAdvancedPds = !_showAdvancedPds),
                          child: Text(_showAdvancedPds ? 'PDS設定を閉じる' : '独自PDS指定'),
                        ),
                      ],
                    ),
                    if (_showAdvancedPds) ...[
                      const SizedBox(height: 4),
                      TextField(
                        controller: _pdsController,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'PDS サーバー URL（通常は空欄で自動判別）',
                          hintText: 'https://bsky.social',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _error!,
                          style: text.bodySmall?.copyWith(color: scheme.onErrorContainer),
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _submitting ? null : _submitLogin,
                        icon: _submitting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.login),
                        label: Text(_submitting ? 'ログイン中…' : 'ログインする'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
