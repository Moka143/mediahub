import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../providers/connection_provider.dart';
import '../../providers/settings_provider.dart';
import '../../utils/constants.dart';
import '../../utils/feedback_utils.dart';
import '../../widgets/common/mediahub_confirm_dialog.dart';
import '../../widgets/tmdb_account_section.dart';
import 'settings_text_field.dart';
import 'settings_tiles.dart';
import 'settings_validation.dart';
import 'tmdb_token_check.dart';

/// Settings → Connection: the torrent engine, qBittorrent's connection
/// details, the TMDB token and the TMDB account.
class SettingsConnectionTab extends ConsumerWidget {
  const SettingsConnectionTab({super.key});

  /// Lines the Browse button up with the field's input box; the row is
  /// top-aligned so the field's helper text can hang below it.
  static const double _browseButtonTopInset = 6;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final isQb = settings.engineKind == TorrentEngineKind.qbittorrent;

    return SettingsPage(
      children: [
        const _ConnectionStatusCard(),
        SettingsSection(
          title: 'Torrent engine',
          icon: Icons.bolt_rounded,
          children: [
            RadioGroup<TorrentEngineKind>(
              groupValue: settings.engineKind,
              onChanged: (kind) {
                if (kind == null || kind == settings.engineKind) return;
                unawaited(_confirmEngineSwitch(context, notifier, kind));
              },
              child: Column(
                children: [
                  for (final kind in TorrentEngineKind.values)
                    RadioListTile<TorrentEngineKind>(
                      contentPadding: EdgeInsets.zero,
                      value: kind,
                      title: Text(kind.label, style: AppType.bodyStrong()),
                      subtitle: Text(switch (kind) {
                        TorrentEngineKind.builtin =>
                          'Runs inside MediaHub. No window, no tray icon, no '
                              'notifications, nothing to install.',
                        TorrentEngineKind.qbittorrent =>
                          'Use a qBittorrent you installed — including one '
                              'on another machine.',
                      }, style: AppType.caption()),
                    ),
                ],
              ),
            ),
            if (!isQb) ...[
              const SizedBox(height: AppSpacing.md),
              SettingsTextField(
                label: 'Engine port',
                value: '${settings.rqbitPort}',
                hint: '${AppConstants.defaultRqbitPort}',
                prefixIcon: Icons.lan_rounded,
                helperText:
                    'Loopback only. Change it if something else already uses '
                    'this port — the engine restarts on the new one.',
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: validatePort,
                onSave: (v) async {
                  await notifier.setRqbitPort(int.parse(v));
                  return null;
                },
              ),
            ],
          ],
        ),

        // Everything below is qBittorrent's own configuration — a host to
        // reach, credentials to present, an executable to launch. The
        // built-in engine has none of those: it listens on loopback with no
        // auth and ships with the app.
        if (isQb) ...[
          SettingsSection(
            title: 'qBittorrent server',
            icon: Icons.dns_rounded,
            footer:
                'Changes apply when you press Enter or leave the field. '
                'MediaHub reconnects with the new details.',
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: SettingsTextField(
                      label: 'Host',
                      value: settings.host,
                      hint: 'localhost',
                      prefixIcon: Icons.dns_rounded,
                      helperText: 'A name or IP address, without http://',
                      validator: validateHost,
                      onSave: (v) async {
                        await notifier.setHost(v);
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    flex: 2,
                    child: SettingsTextField(
                      label: 'Port',
                      value: '${settings.port}',
                      hint: '${AppConstants.defaultPort}',
                      prefixIcon: Icons.tag_rounded,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      validator: validatePort,
                      onSave: (v) async {
                        await notifier.setPort(int.parse(v));
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              SettingsTextField(
                label: 'Username',
                value: settings.username,
                prefixIcon: Icons.person_rounded,
                onSave: (v) async {
                  await notifier.setUsername(v);
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.md),
              SettingsTextField(
                label: 'Password',
                value: settings.password,
                prefixIcon: Icons.lock_rounded,
                obscure: true,
                revealLabel: 'password',
                onSave: (v) async {
                  await notifier.setPassword(v);
                  return null;
                },
              ),
            ],
          ),
          SettingsSection(
            title: 'qBittorrent application',
            icon: Icons.settings_applications_rounded,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SettingsTextField(
                      label: 'qBittorrent program',
                      value: settings.qbittorrentPath,
                      hint: Platform.isWindows
                          ? QBittorrentPaths.windows
                          : Platform.isMacOS
                          ? QBittorrentPaths.macos
                          : QBittorrentPaths.linux,
                      prefixIcon: Icons.terminal_rounded,
                      helperText: 'Used to start qBittorrent on this computer',
                      validator: _validateProgramPath,
                      onSave: (v) async {
                        await notifier.setQBittorrentPath(v);
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Padding(
                    padding: const EdgeInsets.only(top: _browseButtonTopInset),
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.folder_open_rounded, size: 18),
                      label: const Text('Browse…'),
                      onPressed: () async {
                        final result = await FilePicker.platform.pickFiles();
                        final path = result?.files.firstOrNull?.path;
                        if (path != null) {
                          await notifier.setQBittorrentPath(path);
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              SettingsSwitchTile(
                icon: Icons.play_circle_outline_rounded,
                title: 'Start qBittorrent with MediaHub',
                subtitle:
                    'Launch it when MediaHub opens, if it is not already '
                    'running on this computer',
                value: settings.autoStartQBittorrent,
                onChanged: (value) =>
                    unawaited(notifier.setAutoStartQBittorrent(value)),
              ),
            ],
          ),
        ],

        const _TmdbTokenSection(),
        const SettingsSection(
          title: 'TMDB account',
          icon: Icons.account_circle_rounded,
          children: [TmdbAccountSection()],
        ),
      ],
    );
  }

  static String? _validateProgramPath(String path) {
    if (path.isEmpty) return 'Enter where qBittorrent is installed.';
    // A file, or on macOS the .app bundle (a directory) — the process
    // service launches either.
    if (!File(path).existsSync() && !Directory(path).existsSync()) {
      return 'There is nothing at this path.';
    }
    return null;
  }

  /// Switching engines is not a toggle to flip by accident: it ends any
  /// stream in progress, and the other engine's torrents disappear from
  /// Transfers until the user switches back. Say so, then switch.
  static Future<void> _confirmEngineSwitch(
    BuildContext context,
    SettingsNotifier notifier,
    TorrentEngineKind to,
  ) async {
    final toBuiltin = to == TorrentEngineKind.builtin;
    final confirmed = await MediaHubConfirmDialog.show(
      context: context,
      title: toBuiltin ? 'Use the built-in engine?' : 'Use qBittorrent?',
      message: toBuiltin
          ? 'MediaHub will run its own engine instead of talking to your '
                'qBittorrent. Anything streaming now stops, and torrents in '
                'qBittorrent won\'t show in Transfers until you switch back. '
                'Your qBittorrent settings are kept.'
          : 'MediaHub will connect to your qBittorrent instead of running its '
                'own engine. Anything streaming now stops, and the built-in '
                'engine\'s torrents won\'t show in Transfers until you switch '
                'back. Nothing is deleted.',
      confirmLabel: 'Switch',
      icon: Icons.swap_horiz_rounded,
    );
    if (confirmed == true) await notifier.setEngineKind(to);
  }
}

class _ConnectionStatusCard extends ConsumerWidget {
  const _ConnectionStatusCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionProvider);
    final settings = ref.watch(settingsProvider);

    final (tone, icon, title) = connection.isConnected
        ? (AppColors.ok, Icons.check_circle_rounded, 'Connected')
        : connection.hasError
        ? (AppColors.err, Icons.error_rounded, 'Connection failed')
        : connection.isConnecting
        ? (AppColors.fg2, Icons.sync_rounded, 'Connecting…')
        : (AppColors.fg2, Icons.cloud_off_rounded, 'Not connected');
    final detail = connection.isConnected
        ? switch (settings.engineKind) {
            TorrentEngineKind.builtin =>
              'Built-in engine on port ${settings.rqbitPort}',
            TorrentEngineKind.qbittorrent =>
              'qBittorrent ${connection.qbVersion ?? ''}'.trim(),
          }
        : connection.errorMessage ??
              'Choose and set up an engine below, then connect.';

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg),
      child: Card(
        color: connection.isConnected || connection.hasError
            ? Color.alphaBlend(
                tone.withAlpha(AppOpacity.subtle),
                AppColors.bgSurface,
              )
            : null,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.cardPadding),
          child: Semantics(
            container: true,
            liveRegion: true,
            child: Row(
              children: [
                Icon(icon, color: tone, size: AppIconSize.lg),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: AppType.bodyStrong(
                          color: connection.isConnected || connection.hasError
                              ? tone
                              : AppColors.fg,
                        ),
                      ),
                      Text(detail, style: AppType.caption()),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                FilledButton.icon(
                  onPressed: connection.isConnecting
                      ? null
                      : () => unawaited(
                          ref.read(connectionProvider.notifier).retry(),
                        ),
                  icon: connection.isConnecting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          connection.isConnected
                              ? Icons.refresh_rounded
                              : Icons.power_rounded,
                        ),
                  label: Text(
                    connection.isConnecting
                        ? 'Connecting…'
                        : connection.isConnected
                        ? 'Reconnect'
                        : 'Connect',
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

class _TmdbTokenSection extends ConsumerWidget {
  const _TmdbTokenSection();

  static final Uri _apiSettings = Uri.parse(
    'https://www.themoviedb.org/settings/api',
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(settingsProvider.select((s) => s.tmdbApiKey));
    final usingBundled = ref.watch(isUsingBundledTmdbKeyProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final checker = ref.read(tmdbTokenCheckServiceProvider);
    final messenger = ScaffoldMessenger.of(context);

    return SettingsSection(
      title: 'TMDB token',
      icon: Icons.movie_filter_rounded,
      children: [
        if (usingBundled)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: Row(
              children: [
                const Icon(
                  Icons.check_circle_outline_rounded,
                  size: 18,
                  color: AppColors.ok,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Using the TMDB token that comes with MediaHub. Paste '
                    'your own below to use your personal quota.',
                    style: AppType.caption(),
                  ),
                ),
              ],
            ),
          ),
        SettingsTextField(
          label: 'TMDB token',
          value: saved,
          hint: 'Starts with eyJ…',
          prefixIcon: Icons.key_rounded,
          helperText:
              'Your "API Read Access Token" from themoviedb.org. MediaHub '
              'checks it with TMDB before saving.',
          obscure: true,
          revealLabel: 'token',
          // Empty means "use the bundled token" — allowed only when there
          // is one; without it, an empty token leaves the catalog blank.
          validator: (v) => v.isEmpty
              ? (bundledTmdbReadAccessToken.isNotEmpty
                    ? null
                    : 'MediaHub needs a TMDB token to load shows and movies.')
              : tmdbTokenFormatError(v),
          onSave: (v) async {
            if (v.isEmpty) {
              await notifier.setTmdbApiKey('');
              return null;
            }
            final check = await checkTmdbToken(checker, v);
            switch (check.verdict) {
              case TmdbTokenVerdict.rejected:
                return check.message;
              case TmdbTokenVerdict.unchecked:
                // Offline is not the token's fault: save it, and say that
                // it could not be checked rather than pretend it was.
                await notifier.setTmdbApiKey(v);
                AppSnackBar.showOn(
                  messenger,
                  message: 'Token saved. ${check.message}',
                  kind: AppSnackBarKind.warning,
                );
                return null;
              case TmdbTokenVerdict.accepted:
                await notifier.setTmdbApiKey(v);
                return null;
            }
          },
          extraSuffix: saved.isNotEmpty && bundledTmdbReadAccessToken.isNotEmpty
              ? IconButton(
                  icon: const Icon(
                    Icons.restart_alt_rounded,
                    color: AppColors.fg2,
                  ),
                  tooltip: 'Use the token that comes with MediaHub',
                  onPressed: () => unawaited(notifier.setTmdbApiKey('')),
                )
              : null,
        ),
        const SizedBox(height: AppSpacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: const Text('Get a free token at themoviedb.org'),
            onPressed: () async {
              final opened = await launchUrl(
                _apiSettings,
                mode: LaunchMode.externalApplication,
              );
              if (!opened) {
                AppSnackBar.showOn(
                  messenger,
                  message:
                      'Couldn\'t open your browser. The page is '
                      '$_apiSettings',
                  kind: AppSnackBarKind.error,
                );
              }
            },
          ),
        ),
      ],
    );
  }
}
