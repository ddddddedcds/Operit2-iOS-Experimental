// ignore_for_file: file_names

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_all/webview_all.dart';

import '../../../../core/logging/ClientLogger.dart';
import '../../../../core/proxy/generated/CoreProxyClients.g.dart';
import '../../../../core/proxy/generated/CoreProxyModels.g.dart';
import '../market/ArtifactMarketSupport.dart';

class GitHubOAuthLoginDialog extends StatefulWidget {
  const GitHubOAuthLoginDialog({
    super.key,
    required this.clients,
    required this.onLoginCompleted,
  });

  final GeneratedCoreProxyClients clients;
  final Future<void> Function() onLoginCompleted;

  @override
  State<GitHubOAuthLoginDialog> createState() => _GitHubOAuthLoginDialogState();
}

class _GitHubOAuthLoginDialogState extends State<GitHubOAuthLoginDialog> {
  static const double _dialogWidth = 880;
  static const double _dialogHeight = 720;

  late final WebViewController _browserController;
  final TextEditingController _patController = TextEditingController();
  GitHubOAuthBrokerLoginStart? _loginStart;
  bool _isPageLoading = true;
  bool _isCompleting = false;
  bool _isSubmittingPat = false;
  String? _browserError;

  @override
  /// Initializes the visible OAuth browser before requesting an authorization URL.
  void initState() {
    super.initState();
    _browserController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _handleNavigationRequest,
          onPageStarted: (_) {
            if (!mounted) {
              return;
            }
            setState(() {
              _isPageLoading = true;
              _browserError = null;
            });
          },
          onPageFinished: _handlePageFinished,
          onUrlChange: _handleUrlChange,
          onWebResourceError: _handleWebResourceError,
        ),
      );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_startLogin());
    });
  }

  /// Starts the Core broker transaction and loads its GitHub authorization page in this dialog.
  Future<void> _startLogin() async {
    try {
      final start = await startCoreMarketAuthLogin(clients: widget.clients);
      if (!mounted) {
        return;
      }
      setState(() {
        _loginStart = start;
        _isPageLoading = true;
      });
      await _browserController.loadRequest(Uri.parse(start.authorizationUrl));
    } catch (error, stackTrace) {
      ClientLogger.e(
        'GitHub OAuth startLogin failed',
        tag: 'GitHubOAuth',
        error: error,
        stackTrace: stackTrace,
      );
      _closeWithError(error, stackTrace);
    }
  }

  /// Submits a manually-pasted Personal Access Token and skips the in-dialog
  /// WebView OAuth flow entirely. Used when the embedded WebView cannot
  /// reach GitHub (network / ATS / no-sandbox) and the user wants to
  /// authenticate via a token from another device.
  Future<void> _submitPat() async {
    final raw = _patController.text.trim();
    if (raw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先粘贴 GitHub Personal Access Token'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (_isSubmittingPat || _isCompleting) {
      return;
    }
    setState(() {
      _isSubmittingPat = true;
    });
    try {
      await widget.clients.preferencesGitHubAuthPreferences.updateAccessToken(
        accessToken: raw,
        tokenType: 'bearer',
        grantedScope: null,
      );
      final usable = await widget.clients.preferencesGitHubAuthPreferences
          .isLoggedIn();
      if (!usable) {
        throw StateError('Token rejected by GitHub (isLoggedIn=false)');
      }
      ClientLogger.i(
        'GitHub OAuth PAT login succeeded',
        tag: 'GitHubOAuth',
      );
      await widget.onLoginCompleted();
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop();
    } catch (error, stackTrace) {
      ClientLogger.e(
        'GitHub OAuth PAT login failed',
        tag: 'GitHubOAuth',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('PAT 登录失败：$error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSubmittingPat = false;
        });
      }
    }
  }

  /// Claims the one-time broker result when the browser reaches the registered completion destination.
  Future<void> _completeLogin(Uri completionUrl) async {
    final start = _loginStart;
    if (start == null || _isCompleting) {
      return;
    }
    _isCompleting = true;
    if (mounted) {
      setState(() {
        _isPageLoading = true;
      });
    }
    try {
      await completeCoreMarketAuthLogin(
        clients: widget.clients,
        start: start,
        completionUrl: completionUrl,
      );
      await widget.onLoginCompleted();
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop();
    } catch (error, stackTrace) {
      ClientLogger.e(
        'GitHub OAuth completeLogin failed',
        tag: 'GitHubOAuth',
        error: error,
        stackTrace: stackTrace,
      );
      _closeWithError(error, stackTrace);
    }
  }

  /// Stops loading the completion page and transfers the exact callback URL to Core.
  Future<NavigationDecision> _handleNavigationRequest(
    NavigationRequest request,
  ) async {
    final uri = Uri.tryParse(request.url);
    if (uri != null && isCoreMarketAuthCompletionUri(uri)) {
      unawaited(_completeLogin(uri));
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  /// Updates loading state and captures completion on browser engines that report page finishes directly.
  void _handlePageFinished(String url) {
    _handlePossibleCompletionUrl(url);
    if (!mounted) {
      return;
    }
    setState(() {
      _isPageLoading = false;
    });
  }

  /// Captures the browser redirect as soon as its URL changes.
  void _handleUrlChange(UrlChange change) {
    final url = change.url;
    if (url == null) {
      return;
    }
    _handlePossibleCompletionUrl(url);
  }

  /// Captures a completion URL reported by any browser navigation lifecycle event.
  void _handlePossibleCompletionUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null && isCoreMarketAuthCompletionUri(uri)) {
      unawaited(_completeLogin(uri));
    }
  }

  /// Shows a main-frame browser failure above the visible OAuth browser.
  void _handleWebResourceError(WebResourceError error) {
    if (error.isForMainFrame == false || !mounted || _isCompleting) {
      return;
    }
    ClientLogger.e(
      'GitHub OAuth WebView main-frame error: ${error.errorCode} '
      '${error.description}',
      tag: 'GitHubOAuth',
    );
    setState(() {
      _isPageLoading = false;
      _browserError = error.description;
    });
  }

  /// Logs the failure, closes this dialog, and presents the error in the market screen.
  void _closeWithError(Object error, StackTrace stackTrace) {
    ClientLogger.e(
      'GitHub OAuth dialog closing with error',
      tag: 'GitHubOAuth',
      error: error,
      stackTrace: stackTrace,
    );
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(error.toString()),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Closes the app-owned browser flow without attempting to claim a result.
  void _cancelLogin() {
    if (_isCompleting) {
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _patController.dispose();
    super.dispose();
  }

  @override
  /// Renders the GitHub authorization page directly inside the active market login dialog.
  Widget build(BuildContext context) {
    final loginStart = _loginStart;
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: _dialogWidth,
        height: _dialogHeight,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 16, 14),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.account_circle_outlined),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'GitHub 登录',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (_isCompleting)
                    const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    IconButton(
                      tooltip: '取消登录',
                      onPressed: _cancelLogin,
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            _PatLoginBar(
              controller: _patController,
              submitting: _isSubmittingPat,
              onSubmit: _submitPat,
            ),
            Expanded(
              child: Stack(
                children: <Widget>[
                  if (loginStart != null)
                    Positioned.fill(
                      child: WebViewWidget(controller: _browserController),
                    )
                  else
                    const Center(child: CircularProgressIndicator()),
                  if (_isPageLoading && loginStart != null)
                    const Align(
                      alignment: Alignment.topCenter,
                      child: LinearProgressIndicator(),
                    ),
                  if (_browserError != null)
                    Positioned(
                      top: 12,
                      left: 12,
                      right: 12,
                      child: Material(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            _browserError!,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact fallback bar that lets the user authenticate with a GitHub
/// Personal Access Token when the in-dialog WebView cannot reach GitHub.
/// The token is written via [preferencesGitHubAuthPreferences.updateAccessToken]
/// and validated through [preferencesGitHubAuthPreferences.isLoggedIn].
class _PatLoginBar extends StatelessWidget {
  const _PatLoginBar({
    required this.controller,
    required this.submitting,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool submitting;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      color: colors.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Row(
        children: <Widget>[
          Icon(Icons.key_outlined, size: 18, color: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          const Text(
            '或粘贴 Personal Access Token 登录',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: controller,
              enabled: !submitting,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'ghp_... 或 github_pat_...',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
              ),
              style: const TextStyle(fontSize: 13),
              onSubmitted: (_) => onSubmit(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: submitting ? null : onSubmit,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            child: submitting
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('用 Token 登录'),
          ),
        ],
      ),
    );
  }
}
