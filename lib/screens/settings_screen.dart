import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/app_theme.dart';
import '../design/app_tokens.dart';
import '../providers/auto_download_provider.dart';
import '../providers/connection_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/debouncer.dart';
import '../utils/constants.dart';
import '../widgets/common/section_header.dart';

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

  Widget _buildModernSwitchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    required ThemeData theme,
    required AppColorsExtension appColors,
  }) {
    return Semantics(
      toggled: value,
      label: '$title. $subtitle',
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: value
                  ? theme.colorScheme.primary.withAlpha(AppOpacity.light)
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(
              icon,
              color: value ? theme.colorScheme.primary : appColors.mutedText,
              size: 20,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: appColors.mutedText,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _buildAutoDownloadCard(ThemeData theme, AppColorsExtension appColors) {
    final autoDownloadState = ref.watch(autoDownloadProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildModernSwitchTile(
              icon: Icons.smart_display_rounded,
              title: 'Auto-Download Next Episode',
              subtitle:
                  'Automatically queue next episode based on watch progress',
              value: autoDownloadState.enabled,
              onChanged: (value) {
                ref.read(autoDownloadProvider.notifier).setEnabled(value);
              },
              theme: theme,
              appColors: appColors,
            ),
            if (autoDownloadState.enabled) ...[
              const Divider(height: AppSpacing.lg),

              // Quality preference
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Icon(
                      Icons.high_quality_rounded,
                      color: theme.colorScheme.onSecondaryContainer,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Default Quality',
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          'Preferred quality for auto-downloads',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: appColors.mutedText,
                          ),
                        ),
                      ],
                    ),
                  ),
                  DropdownButton<String>(
                    value: autoDownloadState.defaultQuality,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    items: ['4K', '1080p', '720p', '480p'].map((quality) {
                      return DropdownMenuItem(
                        value: quality,
                        child: Text(quality),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        ref
                            .read(autoDownloadProvider.notifier)
                            .setDefaultQuality(value);
                      }
                    },
                  ),
                ],
              ),

              const SizedBox(height: AppSpacing.md),

              // Download on progress
              _buildModernSwitchTile(
                icon: Icons.play_arrow_rounded,
                title: 'Download While Watching',
                subtitle:
                    'Start download when current episode reaches threshold',
                value: autoDownloadState.downloadOnProgress,
                onChanged: (value) {
                  ref
                      .read(autoDownloadProvider.notifier)
                      .setDownloadOnProgress(value);
                },
                theme: theme,
                appColors: appColors,
              ),

              if (autoDownloadState.downloadOnProgress) ...[
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.tertiaryContainer,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Icon(
                        Icons.percent_rounded,
                        color: theme.colorScheme.onTertiaryContainer,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Progress Threshold',
                            style: theme.textTheme.titleMedium,
                          ),
                          Text(
                            'Download next when ${(autoDownloadState.progressThreshold * 100).toInt()}% watched',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: appColors.mutedText,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 120,
                      child: Slider(
                        value: autoDownloadState.progressThreshold,
                        min: 0.5,
                        max: 0.95,
                        divisions: 9,
                        label:
                            '${(autoDownloadState.progressThreshold * 100).toInt()}%',
                        onChanged: (value) {
                          ref
                              .read(autoDownloadProvider.notifier)
                              .setProgressThreshold(value);
                        },
                      ),
                    ),
                  ],
                ),
              ],

              const Divider(height: AppSpacing.lg),

              // Info about smart matching
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withAlpha(
                    AppOpacity.light,
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.auto_awesome_rounded,
                      color: theme.colorScheme.primary,
                      size: 18,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        'Quality automatically matches your current episode. Handles season transitions and checks episode availability.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appColors = context.appColors;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        centerTitle: false,
        bottom: TabBar(
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
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildConnectionTab(theme, appColors),
          _buildDownloadsTab(theme, appColors),
          _buildAppearanceTab(theme, appColors),
          _buildAboutTab(theme, appColors),
        ],
      ),
    );
  }

  Widget _buildConnectionTab(ThemeData theme, AppColorsExtension appColors) {
    final settings = ref.watch(settingsProvider);
    final connectionState = ref.watch(connectionProvider);

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      children: [
        // Connection Status Card
        Card(
          color: connectionState.isConnected
              ? appColors.success.withAlpha(AppOpacity.subtle)
              : connectionState.hasError
              ? appColors.errorState.withAlpha(AppOpacity.subtle)
              : null,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: connectionState.isConnected
                        ? appColors.success.withAlpha(AppOpacity.light)
                        : connectionState.hasError
                        ? appColors.errorState.withAlpha(AppOpacity.light)
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Icon(
                    connectionState.isConnected
                        ? Icons.check_circle_rounded
                        : connectionState.hasError
                        ? Icons.error_rounded
                        : Icons.cloud_off_rounded,
                    color: connectionState.isConnected
                        ? appColors.success
                        : connectionState.hasError
                        ? appColors.errorState
                        : appColors.mutedText,
                    size: 24,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        connectionState.isConnected
                            ? 'Connected'
                            : connectionState.hasError
                            ? 'Connection Failed'
                            : 'Not Connected',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: connectionState.isConnected
                              ? appColors.success
                              : connectionState.hasError
                              ? appColors.errorState
                              : null,
                        ),
                      ),
                      Text(
                        connectionState.isConnected
                            ? 'qBittorrent ${connectionState.qbVersion ?? ''}'
                            : connectionState.errorMessage ??
                                  'Configure connection below',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: appColors.mutedText,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: connectionState.isConnecting
                      ? null
                      : () => ref.read(connectionProvider.notifier).retry(),
                  icon: connectionState.isConnecting
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.onPrimary,
                          ),
                        )
                      : Icon(
                          connectionState.isConnected
                              ? Icons.refresh_rounded
                              : Icons.power_rounded,
                        ),
                  label: Text(
                    connectionState.isConnecting
                        ? 'Connecting...'
                        : connectionState.isConnected
                        ? 'Reconnect'
                        : 'Connect',
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // Server Settings
        const SettingsSectionHeader(
          title: 'Server Settings',
          icon: Icons.dns_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _hostController,
                        decoration: InputDecoration(
                          labelText: 'Host',
                          hintText: 'localhost',
                          prefixIcon: Icon(
                            Icons.dns_rounded,
                            color: appColors.mutedText,
                          ),
                          helperText: 'IP address or hostname',
                        ),
                        onChanged: (value) {
                          ref.read(settingsProvider.notifier).setHost(value);
                        },
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      flex: 1,
                      child: TextField(
                        controller: _portController,
                        decoration: InputDecoration(
                          labelText: 'Port',
                          hintText: '8080',
                          prefixIcon: Icon(
                            Icons.tag_rounded,
                            color: appColors.mutedText,
                          ),
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (value) {
                          final port = int.tryParse(value);
                          if (port != null) {
                            ref.read(settingsProvider.notifier).setPort(port);
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _usernameController,
                  decoration: InputDecoration(
                    labelText: 'Username',
                    prefixIcon: Icon(
                      Icons.person_rounded,
                      color: appColors.mutedText,
                    ),
                  ),
                  onChanged: (value) {
                    ref.read(settingsProvider.notifier).setUsername(value);
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _passwordController,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: Icon(
                      Icons.lock_rounded,
                      color: appColors.mutedText,
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _showPassword
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        color: appColors.mutedText,
                      ),
                      onPressed: () =>
                          setState(() => _showPassword = !_showPassword),
                      tooltip: _showPassword
                          ? 'Hide password'
                          : 'Show password',
                    ),
                  ),
                  obscureText: !_showPassword,
                  onChanged: (value) {
                    ref.read(settingsProvider.notifier).setPassword(value);
                  },
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // qBittorrent Path
        const SettingsSectionHeader(
          title: 'qBittorrent Application',
          icon: Icons.settings_applications_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _qbPathController,
                        decoration: InputDecoration(
                          labelText: 'qBittorrent Path',
                          hintText: '/Applications/qBittorrent.app/...',
                          prefixIcon: Icon(
                            Icons.terminal_rounded,
                            color: appColors.mutedText,
                          ),
                          helperText: 'Path to qBittorrent executable',
                        ),
                        onChanged: (value) {
                          ref
                              .read(settingsProvider.notifier)
                              .setQBittorrentPath(value);
                        },
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.folder_open_rounded),
                      label: const Text('Browse'),
                      onPressed: () async {
                        final result = await FilePicker.platform.pickFiles();
                        if (result != null && result.files.isNotEmpty) {
                          final path = result.files.first.path;
                          if (path != null) {
                            _qbPathController.text = path;
                            ref
                                .read(settingsProvider.notifier)
                                .setQBittorrentPath(path);
                          }
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                _buildModernSwitchTile(
                  icon: Icons.play_circle_outline_rounded,
                  title: 'Auto-start qBittorrent',
                  subtitle:
                      'Automatically start qBittorrent when the app launches',
                  value: settings.autoStartQBittorrent,
                  onChanged: (value) {
                    ref
                        .read(settingsProvider.notifier)
                        .setAutoStartQBittorrent(value);
                  },
                  theme: theme,
                  appColors: appColors,
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // TMDB API Key
        const SettingsSectionHeader(
          title: 'TMDB API Key',
          icon: Icons.movie_filter_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _tmdbKeyController,
                  obscureText: !_showTmdbKey,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'API Key (v3 auth)',
                    hintText: 'e.g. 0123456789abcdef…',
                    prefixIcon: Icon(
                      Icons.key_rounded,
                      color: appColors.mutedText,
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _showTmdbKey
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        color: appColors.mutedText,
                      ),
                      onPressed: () =>
                          setState(() => _showTmdbKey = !_showTmdbKey),
                      tooltip: _showTmdbKey ? 'Hide key' : 'Show key',
                    ),
                    helperText: 'Used to fetch show & movie metadata from TMDB',
                  ),
                  onChanged: (value) {
                    ref.read(settingsProvider.notifier).setTmdbApiKey(value);
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('Get a free key at themoviedb.org'),
                    onPressed: () async {
                      final url = Uri.parse(
                        'https://www.themoviedb.org/settings/api',
                      );
                      if (!await launchUrl(
                        url,
                        mode: LaunchMode.externalApplication,
                      )) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Could not open $url')),
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDownloadsTab(ThemeData theme, AppColorsExtension appColors) {
    final settings = ref.watch(settingsProvider);

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      children: [
        // Save Location
        const SettingsSectionHeader(
          title: 'Save Location',
          icon: Icons.folder_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.sm,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      border: Border.all(
                        color: theme.colorScheme.outline.withAlpha(
                          AppOpacity.light,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.folder_rounded, color: appColors.mutedText),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Default Save Path',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: appColors.mutedText,
                                ),
                              ),
                              Text(
                                settings.defaultSavePath,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.folder_open_rounded),
                  label: const Text('Browse'),
                  onPressed: () async {
                    final result = await FilePicker.platform.getDirectoryPath();
                    if (result != null) {
                      ref
                          .read(settingsProvider.notifier)
                          .setDefaultSavePath(result);
                    }
                  },
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // Speed Limits
        const SettingsSectionHeader(
          title: 'Speed Limits',
          icon: Icons.speed_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _downloadLimitController,
                        decoration: InputDecoration(
                          labelText: 'Download Limit (KB/s)',
                          hintText: '0 = unlimited',
                          prefixIcon: Icon(
                            Icons.arrow_downward_rounded,
                            color: appColors.success,
                          ),
                          helperText: 'Leave empty for unlimited',
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (value) {
                          final limit = int.tryParse(value) ?? 0;
                          final limitBytes = limit * 1024;
                          ref
                              .read(settingsProvider.notifier)
                              .setDownloadSpeedLimit(limitBytes);
                          _applyDownloadLimit(limitBytes);
                        },
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: TextField(
                        controller: _uploadLimitController,
                        decoration: InputDecoration(
                          labelText: 'Upload Limit (KB/s)',
                          hintText: '0 = unlimited',
                          prefixIcon: Icon(
                            Icons.arrow_upward_rounded,
                            color: theme.colorScheme.tertiary,
                          ),
                          helperText: 'Leave empty for unlimited',
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (value) {
                          final limit = int.tryParse(value) ?? 0;
                          final limitBytes = limit * 1024;
                          ref
                              .read(settingsProvider.notifier)
                              .setUploadSpeedLimit(limitBytes);
                          _applyUploadLimit(limitBytes);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // Behavior
        const SettingsSectionHeader(
          title: 'Behavior',
          icon: Icons.tune_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: _buildModernSwitchTile(
              icon: Icons.stop_circle_outlined,
              title: 'Stop seeding on complete',
              subtitle: 'Automatically pause torrents when download finishes',
              value: settings.stopSeedingOnComplete,
              onChanged: (value) {
                ref
                    .read(settingsProvider.notifier)
                    .setStopSeedingOnComplete(value);
              },
              theme: theme,
              appColors: appColors,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAppearanceTab(ThemeData theme, AppColorsExtension appColors) {
    final settings = ref.watch(settingsProvider);

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      children: [
        // Theme
        const SettingsSectionHeader(
          title: 'Theme',
          icon: Icons.dark_mode_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Choose your preferred theme',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: appColors.mutedText,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      icon: Icon(Icons.brightness_auto_rounded),
                      label: Text('System'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      icon: Icon(Icons.light_mode_rounded),
                      label: Text('Light'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      icon: Icon(Icons.dark_mode_rounded),
                      label: Text('Dark'),
                    ),
                  ],
                  selected: {settings.themeMode},
                  onSelectionChanged: (modes) {
                    ref
                        .read(settingsProvider.notifier)
                        .setThemeMode(modes.first);
                  },
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // Update Interval
        const SettingsSectionHeader(
          title: 'Refresh Rate',
          icon: Icons.timer_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(
                    Icons.update_rounded,
                    color: theme.colorScheme.onSecondaryContainer,
                    size: 20,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Update Interval',
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        'How often to refresh torrent data',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: appColors.mutedText,
                        ),
                      ),
                    ],
                  ),
                ),
                DropdownButton<int>(
                  value: settings.updateIntervalSeconds,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  items: [1, 2, 3, 5, 10].map((seconds) {
                    return DropdownMenuItem(
                      value: seconds,
                      child: Text('$seconds sec'),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      ref
                          .read(settingsProvider.notifier)
                          .setUpdateInterval(value);
                    }
                  },
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // Playback Settings (Stremio-inspired)
        const SettingsSectionHeader(
          title: 'Playback',
          icon: Icons.play_circle_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Column(
              children: [
                _buildModernSwitchTile(
                  icon: Icons.queue_play_next_rounded,
                  title: 'Binge Watching',
                  subtitle: 'Auto-play next episode when current ends',
                  value: settings.bingeWatchingEnabled,
                  onChanged: (value) {
                    ref
                        .read(settingsProvider.notifier)
                        .setBingeWatchingEnabled(value);
                  },
                  theme: theme,
                  appColors: appColors,
                ),
                if (settings.bingeWatchingEnabled) ...[
                  const Divider(height: AppSpacing.lg),
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Icon(
                          Icons.timer_rounded,
                          color: theme.colorScheme.onSecondaryContainer,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Countdown Duration',
                              style: theme.textTheme.titleMedium,
                            ),
                            Text(
                              'Seconds before episode ends to show popup',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: appColors.mutedText,
                              ),
                            ),
                          ],
                        ),
                      ),
                      DropdownButton<int>(
                        value: settings.nextEpisodeCountdownSeconds,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        items: [15, 20, 30, 45, 60].map((seconds) {
                          return DropdownMenuItem(
                            value: seconds,
                            child: Text('$seconds sec'),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            ref
                                .read(settingsProvider.notifier)
                                .setNextEpisodeCountdownSeconds(value);
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // Auto-Download Settings (Smart Queue)
        const SettingsSectionHeader(
          title: 'Smart Auto-Download',
          icon: Icons.download_for_offline_rounded,
        ),
        _buildAutoDownloadCard(theme, appColors),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // Advanced Polling Settings
        const SettingsSectionHeader(
          title: 'Advanced',
          icon: Icons.tune_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Column(
              children: [
                _buildModernSwitchTile(
                  icon: Icons.auto_mode_rounded,
                  title: 'Adaptive Polling',
                  subtitle: 'Reduce refresh rate when no downloads are active',
                  value: settings.useAdaptivePolling,
                  onChanged: (value) {
                    ref
                        .read(settingsProvider.notifier)
                        .setUseAdaptivePolling(value);
                  },
                  theme: theme,
                  appColors: appColors,
                ),
                if (settings.useAdaptivePolling) ...[
                  const Divider(height: AppSpacing.lg),
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Icon(
                          Icons.hourglass_empty_rounded,
                          color: theme.colorScheme.onSecondaryContainer,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Idle Refresh Interval',
                              style: theme.textTheme.titleMedium,
                            ),
                            Text(
                              'Refresh rate when no active downloads',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: appColors.mutedText,
                              ),
                            ),
                          ],
                        ),
                      ),
                      DropdownButton<int>(
                        value: settings.idlePollingIntervalSeconds,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        items: [5, 10, 15, 30, 60].map((seconds) {
                          return DropdownMenuItem(
                            value: seconds,
                            child: Text('$seconds sec'),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            ref
                                .read(settingsProvider.notifier)
                                .setIdlePollingInterval(value);
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAboutTab(ThemeData theme, AppColorsExtension appColors) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      children: [
        // App Info
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        theme.colorScheme.primary,
                        theme.colorScheme.tertiary,
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.primary.withAlpha(
                          AppOpacity.medium,
                        ),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.bolt_rounded,
                    color: Colors.white,
                    size: 44,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'MediaHub',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                  child: Text(
                    'Version ${AppConstants.appVersion}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'A modern torrent client for watching TV shows',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: appColors.mutedText,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // Keyboard Shortcuts
        const SettingsSectionHeader(
          title: 'Keyboard Shortcuts',
          icon: Icons.keyboard_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Column(
              children: [
                _buildShortcutRow('Play/Pause', 'Space', theme, appColors),
                const Divider(height: AppSpacing.lg),
                _buildShortcutRow('Seek Forward 10s', '→', theme, appColors),
                const Divider(height: AppSpacing.lg),
                _buildShortcutRow('Seek Backward 10s', '←', theme, appColors),
                const Divider(height: AppSpacing.lg),
                _buildShortcutRow('Volume Up', '↑', theme, appColors),
                const Divider(height: AppSpacing.lg),
                _buildShortcutRow('Volume Down', '↓', theme, appColors),
                const Divider(height: AppSpacing.lg),
                _buildShortcutRow('Toggle Fullscreen', 'F', theme, appColors),
                const Divider(height: AppSpacing.lg),
                _buildShortcutRow('Mute/Unmute', 'M', theme, appColors),
                const Divider(height: AppSpacing.lg),
                _buildShortcutRow('Exit Player', 'Esc', theme, appColors),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // Reset
        const SettingsSectionHeader(
          title: 'Reset',
          icon: Icons.restart_alt_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: appColors.errorState.withAlpha(AppOpacity.light),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(
                    Icons.restart_alt_rounded,
                    color: appColors.errorState,
                    size: 20,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Reset to Defaults',
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        'Reset all settings to default values',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: appColors.mutedText,
                        ),
                      ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Reset'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: appColors.errorState,
                  ),
                  onPressed: () => _showResetDialog(context),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.xxl),
      ],
    );
  }

  Widget _buildShortcutRow(
    String action,
    String shortcut,
    ThemeData theme,
    AppColorsExtension appColors,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(action, style: theme.textTheme.bodyMedium),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(
              color: theme.colorScheme.outline.withAlpha(AppOpacity.light),
            ),
          ),
          child: Text(
            shortcut,
            style: theme.textTheme.labelLarge?.copyWith(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Row(
            children: [
              const Icon(Icons.error_rounded, color: Colors.white),
              const SizedBox(width: AppSpacing.sm),
              const Text(
                'Failed to apply download limit. Check your connection.',
              ),
            ],
          ),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () => _applyDownloadLimit(limitBytes),
          ),
        ),
      );
    }
  }

  Future<void> _setUploadLimit(int limitBytes) async {
    final connectionState = ref.read(connectionProvider);
    if (!connectionState.isConnected) return;

    final apiService = ref.read(qbApiServiceProvider);
    final success = await apiService.setUploadLimit(limitBytes);
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Row(
            children: [
              const Icon(Icons.error_rounded, color: Colors.white),
              const SizedBox(width: AppSpacing.sm),
              const Text(
                'Failed to apply upload limit. Check your connection.',
              ),
            ],
          ),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () => _applyUploadLimit(limitBytes),
          ),
        ),
      );
    }
  }

  Future<void> _showResetDialog(BuildContext context) async {
    final appColors = context.appColors;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: appColors.errorState.withAlpha(AppOpacity.light),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.warning_rounded,
            color: appColors.errorState,
            size: 28,
          ),
        ),
        title: const Text('Reset Settings'),
        content: const Text(
          'Are you sure you want to reset all settings to default values? This action cannot be undone.',
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: appColors.errorState,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(settingsProvider.notifier).resetToDefaults();

      // Update controllers
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(AppSpacing.md),
            content: Row(
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  color: appColors.success,
                  size: 20,
                ),
                const SizedBox(width: AppSpacing.sm),
                const Text('Settings reset to defaults'),
              ],
            ),
          ),
        );
      }
    }
  }
}
