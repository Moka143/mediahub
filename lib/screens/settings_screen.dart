import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../widgets/common/mediahub_confirm_dialog.dart';
import '../widgets/common/mediahub_topbar.dart';
import '../providers/connection_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/debouncer.dart';
import '../utils/feedback_utils.dart';
import 'settings/about_tab.dart';
import 'settings/appearance_tab.dart';
import 'settings/connection_tab.dart';
import 'settings/downloads_tab.dart';

/// Settings screen with tabbed layout for better organization
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late TextEditingController _hostController;
  late TextEditingController _portController;
  late TextEditingController _usernameController;
  late TextEditingController _passwordController;
  late TextEditingController _qbPathController;
  late TextEditingController _downloadLimitController;
  late TextEditingController _uploadLimitController;
  late TextEditingController _tmdbKeyController;
  final Debouncer _downloadLimitDebouncer = Debouncer(
    delay: const Duration(milliseconds: 600),
  );
  final Debouncer _uploadLimitDebouncer = Debouncer(
    delay: const Duration(milliseconds: 600),
  );

  bool _showPassword = false;
  bool _showTmdbKey = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    final settings = ref.read(settingsProvider);
    _hostController = TextEditingController(text: settings.host);
    _portController = TextEditingController(text: settings.port.toString());
    _usernameController = TextEditingController(text: settings.username);
    _passwordController = TextEditingController(text: settings.password);
    _qbPathController = TextEditingController(text: settings.qbittorrentPath);
    _downloadLimitController = TextEditingController(
      text: settings.downloadSpeedLimit > 0
          ? (settings.downloadSpeedLimit ~/ 1024).toString()
          : '',
    );
    _uploadLimitController = TextEditingController(
      text: settings.uploadSpeedLimit > 0
          ? (settings.uploadSpeedLimit ~/ 1024).toString()
          : '',
    );
    _tmdbKeyController = TextEditingController(text: settings.tmdbApiKey);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _qbPathController.dispose();
    _downloadLimitController.dispose();
    _uploadLimitController.dispose();
    _tmdbKeyController.dispose();
    _downloadLimitDebouncer.dispose();
    _uploadLimitDebouncer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();

    return Scaffold(
      appBar: MediaHubTopBar(
        title: 'Settings',
        showSearch: false,
        leading: canPop
            ? MediaHubIconButton(
                icon: Icons.arrow_back_rounded,
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).pop(),
              )
            : null,
      ),
      body: Column(
        children: [
          Container(
            decoration: const BoxDecoration(
              color: AppColors.bgPage,
              border: Border(
                bottom: BorderSide(color: AppColors.line, width: 1),
              ),
            ),
            child: TabBar(
              controller: _tabController,
              isScrollable: false,
              tabs: const [
                Tab(icon: Icon(Icons.link_rounded), text: 'Connection'),
                Tab(icon: Icon(Icons.download_rounded), text: 'Downloads'),
                Tab(icon: Icon(Icons.palette_rounded), text: 'Appearance'),
                Tab(icon: Icon(Icons.info_rounded), text: 'About'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                SettingsConnectionTab(
                  hostController: _hostController,
                  portController: _portController,
                  usernameController: _usernameController,
                  passwordController: _passwordController,
                  qbPathController: _qbPathController,
                  tmdbKeyController: _tmdbKeyController,
                  showPassword: _showPassword,
                  showTmdbKey: _showTmdbKey,
                  onTogglePassword: () =>
                      setState(() => _showPassword = !_showPassword),
                  onToggleTmdbKey: () =>
                      setState(() => _showTmdbKey = !_showTmdbKey),
                ),
                SettingsDownloadsTab(
                  downloadLimitController: _downloadLimitController,
                  uploadLimitController: _uploadLimitController,
                  onApplyDownloadLimit: _applyDownloadLimit,
                  onApplyUploadLimit: _applyUploadLimit,
                ),
                const SettingsAppearanceTab(),
                SettingsAboutTab(onReset: () => _showResetDialog(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _applyDownloadLimit(int limitBytes) {
    _downloadLimitDebouncer.run(() {
      unawaited(_setDownloadLimit(limitBytes));
    });
  }

  void _applyUploadLimit(int limitBytes) {
    _uploadLimitDebouncer.run(() {
      unawaited(_setUploadLimit(limitBytes));
    });
  }

  Future<void> _setDownloadLimit(int limitBytes) async {
    final connectionState = ref.read(connectionProvider);
    if (!connectionState.isConnected) return;

    final apiService = ref.read(qbApiServiceProvider);
    final success = await apiService.setDownloadLimit(limitBytes);
    if (!success && mounted) {
      AppSnackBar.showError(
        context,
        message: 'Failed to apply download limit. Check your connection.',
        actionLabel: 'Retry',
        onAction: () => _applyDownloadLimit(limitBytes),
      );
    }
  }

  Future<void> _setUploadLimit(int limitBytes) async {
    final connectionState = ref.read(connectionProvider);
    if (!connectionState.isConnected) return;

    final apiService = ref.read(qbApiServiceProvider);
    final success = await apiService.setUploadLimit(limitBytes);
    if (!success && mounted) {
      AppSnackBar.showError(
        context,
        message: 'Failed to apply upload limit. Check your connection.',
        actionLabel: 'Retry',
        onAction: () => _applyUploadLimit(limitBytes),
      );
    }
  }

  Future<void> _showResetDialog(BuildContext context) async {
    final confirmed = await MediaHubConfirmDialog.show(
      context: context,
      title: 'Reset Settings',
      message:
          'Are you sure you want to reset all settings to default values? '
          'This action cannot be undone.',
      confirmLabel: 'Reset',
      destructive: true,
      icon: Icons.warning_rounded,
    );

    if (confirmed == true) {
      await ref.read(settingsProvider.notifier).resetToDefaults();

      final settings = ref.read(settingsProvider);
      _hostController.text = settings.host;
      _portController.text = settings.port.toString();
      _usernameController.text = settings.username;
      _passwordController.text = settings.password;
      _qbPathController.text = settings.qbittorrentPath;
      _tmdbKeyController.text = settings.tmdbApiKey;
      _downloadLimitController.text = '';
      _uploadLimitController.text = '';

      if (context.mounted) {
        AppSnackBar.showSuccess(context, message: 'Settings reset to defaults');
      }
    }
  }
}
