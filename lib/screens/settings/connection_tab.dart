import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/app_theme.dart';
import '../../design/app_tokens.dart';
import '../../providers/connection_provider.dart';
import '../../providers/settings_provider.dart';
import '../../utils/feedback_utils.dart';
import '../../widgets/common/section_header.dart';
import '../../widgets/tmdb_account_section.dart';
import 'settings_tiles.dart';

class SettingsConnectionTab extends ConsumerWidget {
  const SettingsConnectionTab({
    super.key,
    required this.hostController,
    required this.portController,
    required this.usernameController,
    required this.passwordController,
    required this.qbPathController,
    required this.tmdbKeyController,
    required this.showPassword,
    required this.showTmdbKey,
    required this.onTogglePassword,
    required this.onToggleTmdbKey,
  });

  final TextEditingController hostController;
  final TextEditingController portController;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final TextEditingController qbPathController;
  final TextEditingController tmdbKeyController;
  final bool showPassword;
  final bool showTmdbKey;
  final VoidCallback onTogglePassword;
  final VoidCallback onToggleTmdbKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
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
                        controller: hostController,
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
                        controller: portController,
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
                  controller: usernameController,
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
                  controller: passwordController,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: Icon(
                      Icons.lock_rounded,
                      color: appColors.mutedText,
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        showPassword
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        color: appColors.mutedText,
                      ),
                      onPressed: () => onTogglePassword(),
                      tooltip: showPassword ? 'Hide password' : 'Show password',
                    ),
                  ),
                  obscureText: !showPassword,
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
                        controller: qbPathController,
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
                            qbPathController.text = path;
                            await ref
                                .read(settingsProvider.notifier)
                                .setQBittorrentPath(path);
                          }
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                SettingsSwitchTile(
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
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // TMDB Read Access Token
        const SettingsSectionHeader(
          title: 'TMDB Read Access Token',
          icon: Icons.movie_filter_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (ref.watch(isUsingBundledTmdbKeyProvider))
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.md),
                    child: Row(
                      children: [
                        Icon(
                          Icons.check_circle_outline_rounded,
                          size: 18,
                          color: appColors.success,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Expanded(
                          child: Text(
                            'Using the bundled TMDB Read Access Token. '
                            'Enter your own below to use a personal quota.',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: appColors.mutedText),
                          ),
                        ),
                      ],
                    ),
                  ),
                TextField(
                  controller: tmdbKeyController,
                  obscureText: !showTmdbKey,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Read Access Token (v4) — override',
                    hintText: 'e.g. 0123456789abcdef…',
                    prefixIcon: Icon(
                      Icons.key_rounded,
                      color: appColors.mutedText,
                    ),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (ref.watch(settingsProvider).tmdbApiKey.isNotEmpty)
                          IconButton(
                            icon: Icon(
                              Icons.restart_alt_rounded,
                              color: appColors.mutedText,
                            ),
                            onPressed: () {
                              tmdbKeyController.clear();
                              ref
                                  .read(settingsProvider.notifier)
                                  .setTmdbApiKey('');
                            },
                            tooltip: 'Reset to bundled default',
                          ),
                        IconButton(
                          icon: Icon(
                            showTmdbKey
                                ? Icons.visibility_off_rounded
                                : Icons.visibility_rounded,
                            color: appColors.mutedText,
                          ),
                          onPressed: () => onToggleTmdbKey(),
                          tooltip: showTmdbKey ? 'Hide key' : 'Show key',
                        ),
                      ],
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
                    label: const Text('Get a free token at themoviedb.org'),
                    onPressed: () async {
                      final url = Uri.parse(
                        'https://www.themoviedb.org/settings/api',
                      );
                      final messenger = ScaffoldMessenger.of(context);
                      if (!await launchUrl(
                        url,
                        mode: LaunchMode.externalApplication,
                      )) {
                        AppSnackBar.showOn(
                          messenger,
                          message: 'Could not open $url',
                          kind: AppSnackBarKind.error,
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // TMDB Account — sign in to sync favorites & watchlist with TMDB
        const SettingsSectionHeader(
          title: 'TMDB Account',
          icon: Icons.account_circle_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: TmdbAccountSection(),
          ),
        ),
      ],
    );
  }
}
