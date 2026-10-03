import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../providers/connection_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/constants.dart';
import 'common/hub_pressable.dart';
import 'editorial/editorial.dart';

/// Why the torrent engine cannot be used, as far as the advice goes.
enum EngineTrouble {
  /// Nothing answered: not started, crashed, wrong host or port.
  notRunning,

  /// The engine program itself could not be found to start it.
  notFound,

  /// qBittorrent answered and turned the credentials down.
  rejectedLogin,

  /// It answered too slowly, or not at all within the timeout.
  slow,

  /// qBittorrent wants HTTPS; the app speaks plain HTTP.
  insecure,

  /// It was connected, then stopped answering the periodic check.
  lost,

  /// Anything else.
  unknown,
}

final RegExp _authStatus = RegExp(r'\b40[13]\b');

bool _mentions(String text, List<String> needles) => needles.any(text.contains);

/// Classify a connection error message, once, for both the one-line hint
/// and the troubleshooting tips — they used to classify it separately and
/// could disagree.
///
/// The built-in engine has no login, no HTTPS and nothing remote, so the
/// login and certificate branches cannot apply to it: a "failed to
/// authenticate" from it only ever meant that nothing answered.
EngineTrouble classifyEngineTrouble(String? message, TorrentEngineKind engine) {
  final text = (message ?? '').toLowerCase();
  final builtin = engine == TorrentEngineKind.builtin;

  if (text.contains('connection lost')) return EngineTrouble.lost;
  if (_authStatus.hasMatch(text) ||
      _mentions(text, [
        'unauthori',
        'authenticat',
        'credential',
        'username',
        'password',
        'forbidden',
      ])) {
    return builtin ? EngineTrouble.notRunning : EngineTrouble.rejectedLogin;
  }
  if (_mentions(text, ['timeout', 'timed out', 'not responding'])) {
    return EngineTrouble.slow;
  }
  if (!builtin &&
      _mentions(text, ['certificate', 'ssl', 'tls', 'handshake', 'https'])) {
    return EngineTrouble.insecure;
  }
  if (_mentions(text, [
    'connection refused',
    'no route',
    'cannot connect',
    "can't connect",
    'cannot reach',
    "can't reach",
    'failed to start',
    'not running',
    "isn't running",
    'socketexception',
    'connection error',
    'failed host lookup',
    'unreachable',
  ])) {
    return EngineTrouble.notRunning;
  }
  return EngineTrouble.unknown;
}

/// The trouble behind [connection]: the reason the connection provider
/// recorded when it has one, otherwise read from the message.
EngineTrouble engineTroubleFor(
  ConnectionState connection,
  TorrentEngineKind engine,
) {
  final builtin = engine == TorrentEngineKind.builtin;
  return switch (connection.failure) {
    ConnectionFailure.engineNotRunning ||
    ConnectionFailure.unreachable => EngineTrouble.notRunning,
    ConnectionFailure.engineNotFound => EngineTrouble.notFound,
    ConnectionFailure.loginRejected =>
      builtin ? EngineTrouble.notRunning : EngineTrouble.rejectedLogin,
    ConnectionFailure.timedOut => EngineTrouble.slow,
    ConnectionFailure.unknown ||
    null => classifyEngineTrouble(connection.errorMessage, engine),
  };
}

/// What to tell someone whose engine is down: a headline, one sentence of
/// why, and a few things to try — all for the engine they actually use.
///
/// Built-in-engine users are never sent to qBittorrent's settings: the
/// built-in engine has no Web UI to enable, no credentials to check and no
/// host to get wrong, and naming qBittorrent sends them looking for a
/// program they never installed.
class EngineIssue {
  const EngineIssue({
    required this.trouble,
    required this.title,
    required this.hint,
    required this.tips,
  });

  /// The issue for [connection], on [engine].
  factory EngineIssue.of(
    ConnectionState connection,
    TorrentEngineKind engine,
  ) => EngineIssue.forTrouble(engineTroubleFor(connection, engine), engine);

  /// The issue a bare error [message] describes, on [engine].
  factory EngineIssue.describe(String? message, TorrentEngineKind engine) =>
      EngineIssue.forTrouble(classifyEngineTrouble(message, engine), engine);

  factory EngineIssue.forTrouble(
    EngineTrouble trouble,
    TorrentEngineKind engine,
  ) => switch (engine) {
    TorrentEngineKind.builtin => _builtin(trouble),
    TorrentEngineKind.qbittorrent => _qbittorrent(trouble),
  };

  final EngineTrouble trouble;
  final String title;
  final String hint;
  final List<String> tips;

  static EngineIssue _builtin(EngineTrouble trouble) => switch (trouble) {
    EngineTrouble.notRunning => EngineIssue(
      trouble: trouble,
      title: "The built-in engine isn't running",
      hint:
          'It may have failed to start, or another program is using its port.',
      tips: const [
        'The engine may not have started — the app log has the details',
        'Another program may be using the engine port',
        'Try a different engine port in Settings',
      ],
    ),
    EngineTrouble.notFound => EngineIssue(
      trouble: trouble,
      title: 'The built-in engine is missing',
      hint:
          "MediaHub couldn't find its torrent engine. Reinstalling MediaHub "
          'puts it back.',
      tips: const [
        'Reinstall MediaHub to restore the built-in engine',
        'Or choose a different engine in Settings',
      ],
    ),
    EngineTrouble.slow => EngineIssue(
      trouble: trouble,
      title: "The built-in engine isn't responding",
      hint: "It's taking too long to answer. Try again in a moment.",
      tips: const [
        'It may still be starting up — try again in a moment',
        'If it keeps happening, restart MediaHub',
        'Try a different engine port in Settings',
      ],
    ),
    EngineTrouble.lost => EngineIssue(
      trouble: trouble,
      title: 'Lost the connection to the built-in engine',
      hint: 'It stopped answering. Try again to reconnect.',
      tips: const [
        'Try again to reconnect',
        'If it keeps dropping, restart MediaHub',
        'The app log has the details',
      ],
    ),
    EngineTrouble.rejectedLogin ||
    EngineTrouble.insecure ||
    EngineTrouble.unknown => EngineIssue(
      trouble: EngineTrouble.unknown,
      title: "The built-in engine isn't available",
      hint: 'Try again, or check the engine port in Settings.',
      tips: const [
        'Try again in a moment',
        'Check the engine port in Settings',
        'The app log has the details',
      ],
    ),
  };

  static EngineIssue _qbittorrent(EngineTrouble trouble) => switch (trouble) {
    EngineTrouble.notRunning => EngineIssue(
      trouble: trouble,
      title: "Can't reach qBittorrent",
      hint: 'Make sure qBittorrent is running with its Web UI turned on.',
      tips: const [
        'Make sure qBittorrent is running',
        "Check that the Web UI is enabled in qBittorrent's settings",
        'Verify the host and port in Settings',
      ],
    ),
    EngineTrouble.notFound => EngineIssue(
      trouble: trouble,
      title: "qBittorrent couldn't be found",
      hint: 'Install qBittorrent, or set where it is in Settings.',
      tips: const [
        'Install qBittorrent',
        'Set the path to qBittorrent in Settings',
        'Or start qBittorrent yourself and try again',
      ],
    ),
    EngineTrouble.rejectedLogin => EngineIssue(
      trouble: trouble,
      title: "qBittorrent didn't accept the login",
      hint: 'Check the username and password in Settings.',
      tips: const [
        'Verify the username and password in Settings',
        'Check whether qBittorrent requires a login for this address',
      ],
    ),
    EngineTrouble.slow => EngineIssue(
      trouble: trouble,
      title: "qBittorrent isn't responding",
      hint: "It's taking too long to answer. Check that it's running.",
      tips: const [
        'Check that qBittorrent is responding',
        'Check your network connection',
        'Verify the host and port in Settings',
      ],
    ),
    EngineTrouble.insecure => EngineIssue(
      trouble: trouble,
      title: 'qBittorrent wants a secure connection',
      hint:
          "MediaHub connects over plain HTTP. Turn off HTTPS in qBittorrent's "
          'Web UI settings.',
      tips: const [
        "Turn off HTTPS in qBittorrent's Web UI settings",
        'Verify the host and port in Settings',
      ],
    ),
    EngineTrouble.lost => EngineIssue(
      trouble: trouble,
      title: 'Lost the connection to qBittorrent',
      hint: "It stopped answering. Check that it's still running.",
      tips: const [
        'Make sure qBittorrent is still running',
        'Check your network connection',
        'Try again to reconnect',
      ],
    ),
    EngineTrouble.unknown => EngineIssue(
      trouble: trouble,
      title: "Can't connect to qBittorrent",
      hint:
          'Check that qBittorrent is running and the connection settings '
          'are right.',
      tips: const [
        'Verify qBittorrent is running and accessible',
        'Check your network connection',
        'Review the connection settings',
      ],
    ),
  };
}

/// The engine version for the status pill — "v4.6.2", or nothing.
///
/// qBittorrent answers "v4.6.2" (which the pill used to print as
/// "vv4.6.2"); the built-in engine answers its name, "rqbit", which is not a
/// version at all and came out as "vrqbit".
String? engineVersionLabel(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  final bare = trimmed.startsWith('v') || trimmed.startsWith('V')
      ? trimmed.substring(1)
      : trimmed;
  if (!RegExp(r'^\d').hasMatch(bare)) return null;
  return 'v$bare';
}

/// The engine status pill in the Transfers top bar. Clicking it while the
/// engine is offline tries to reconnect.
class ConnectionStatusWidget extends ConsumerWidget {
  const ConnectionStatusWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionProvider);
    final engine = ref.watch(settingsProvider.select((s) => s.engineKind));
    final look = _PillLook.of(connection.status);

    final pill = _StatusPill(
      look: look,
      busy: connection.isConnecting,
      version: connection.isConnected
          ? engineVersionLabel(connection.qbVersion)
          : null,
    );

    switch (connection.status) {
      case ConnectionStatus.connected:
      case ConnectionStatus.connecting:
        final what = connection.isConnected
            ? '${engine.label} · connected'
            : 'Connecting to ${engine.sentenceName}…';
        return Tooltip(
          message: what,
          child: Semantics(
            label: what,
            child: ExcludeSemantics(child: pill),
          ),
        );
      case ConnectionStatus.error:
      case ConnectionStatus.disconnected:
        final issue = EngineIssue.of(connection, engine);
        return HubPressable(
          onTap: () => unawaited(ref.read(connectionProvider.notifier).retry()),
          tooltip: '${issue.title}. Click to try again.',
          borderRadius: BorderRadius.circular(AppRadius.full),
          excludeChildSemantics: true,
          child: pill,
        );
    }
  }
}

class _PillLook {
  const _PillLook(this.label, this.icon, this.tone, this.background);

  factory _PillLook.of(ConnectionStatus status) => switch (status) {
    ConnectionStatus.connected => _PillLook(
      'Connected',
      Icons.cloud_done_rounded,
      AppColors.ok,
      AppColors.okSoft,
    ),
    ConnectionStatus.connecting => _PillLook(
      'Connecting…',
      Icons.cloud_sync_rounded,
      AppColors.warn,
      AppColors.warn.withAlpha(AppOpacity.light),
    ),
    ConnectionStatus.error => _PillLook(
      'Offline',
      Icons.cloud_off_rounded,
      AppColors.err,
      AppColors.err.withAlpha(AppOpacity.light),
    ),
    ConnectionStatus.disconnected => const _PillLook(
      'Not connected',
      Icons.cloud_off_rounded,
      AppColors.fg2,
      AppColors.bgSurface,
    ),
  };

  final String label;
  final IconData icon;
  final Color tone;
  final Color background;
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.look, required this.busy, this.version});

  final _PillLook look;
  final bool busy;
  final String? version;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: look.background,
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: look.tone.withAlpha(AppOpacity.medium)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox(
              width: AppIconSize.xs,
              height: AppIconSize.xs,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: look.tone,
              ),
            )
          else
            Icon(look.icon, size: AppIconSize.xs, color: look.tone),
          const SizedBox(width: AppSpacing.sm),
          Text(
            look.label,
            style: AppType.ui(
              size: AppType.sizeCaption,
              color: look.tone,
              weight: FontWeight.w500,
              height: 1.2,
            ),
          ),
          if (version != null) ...[
            const SizedBox(width: AppSpacing.sm),
            Text(
              version!,
              style: AppType.mono(
                size: AppType.sizeSmall,
                color: AppColors.fg2,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// What the Transfers screen shows while the engine is not connected,
/// instead of a "No transfers yet" list that reads as data loss.
///
/// Says why, for the engine in use, with the two ways out — try again, or
/// Settings — and the troubleshooting tips one click away. While the engine
/// is still starting it says so rather than showing an error.
class EngineOfflineState extends ConsumerStatefulWidget {
  const EngineOfflineState({super.key, this.onOpenSettings});

  final VoidCallback? onOpenSettings;

  @override
  ConsumerState<EngineOfflineState> createState() => _EngineOfflineStateState();
}

class _EngineOfflineStateState extends ConsumerState<EngineOfflineState> {
  bool _showTips = false;

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(connectionProvider);
    final engine = ref.watch(settingsProvider.select((s) => s.engineKind));
    if (connection.isConnected) return const SizedBox.shrink();

    // Before the first attempt the state is "disconnected" with no message;
    // that is the app starting up, not a failure.
    final starting =
        connection.isConnecting ||
        (connection.status == ConnectionStatus.disconnected &&
            connection.errorMessage == null);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xxxl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: starting
              ? _EngineStarting(engine: engine)
              : _EngineDown(
                  issue: EngineIssue.of(connection, engine),
                  showTips: _showTips,
                  onToggleTips: () => setState(() => _showTips = !_showTips),
                  onRetry: () =>
                      unawaited(ref.read(connectionProvider.notifier).retry()),
                  onOpenSettings: widget.onOpenSettings,
                ),
        ),
      ),
    );
  }
}

class _EngineStarting extends StatelessWidget {
  const _EngineStarting({required this.engine});

  final TorrentEngineKind engine;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: AppIconSize.xl,
          height: AppIconSize.xl,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.accent,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'Connecting to ${engine.sentenceName}…',
          textAlign: TextAlign.center,
          style: AppType.ui(size: AppType.sizeLead, color: AppColors.fg1),
        ),
      ],
    );
  }
}

class _EngineDown extends StatelessWidget {
  const _EngineDown({
    required this.issue,
    required this.showTips,
    required this.onToggleTips,
    required this.onRetry,
    this.onOpenSettings,
  });

  final EngineIssue issue;
  final bool showTips;
  final VoidCallback onToggleTips;
  final VoidCallback onRetry;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.cloud_off_rounded,
          size: AppIconSize.xxl,
          color: AppColors.err,
        ),
        const SizedBox(height: AppSpacing.lg),
        SerifTitle(
          issue.title,
          size: AppType.sizeTitle,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          issue.hint,
          textAlign: TextAlign.center,
          style: AppType.ui(
            size: AppType.sizeLead,
            color: AppColors.fg1,
            height: 1.5,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            EditorialButton(
              label: 'Try again',
              icon: Icons.refresh_rounded,
              kind: EditorialButtonKind.accent,
              onPressed: onRetry,
            ),
            if (onOpenSettings != null)
              EditorialButton(
                label: 'Open Settings',
                icon: Icons.settings_outlined,
                kind: EditorialButtonKind.subtle,
                onPressed: onOpenSettings,
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        HubPressable(
          onTap: onToggleTips,
          selected: showTips,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  showTips
                      ? 'Hide troubleshooting tips'
                      : 'Show troubleshooting tips',
                  style: AppType.ui(
                    size: AppType.sizeBody,
                    color: AppColors.fg2,
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                AnimatedRotation(
                  turns: showTips ? 0.5 : 0,
                  duration: AppDuration.fast,
                  child: const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: AppIconSize.sm,
                    color: AppColors.fg2,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (showTips) ...[
          const SizedBox(height: AppSpacing.sm),
          _TipList(tips: issue.tips),
        ],
      ],
    );
  }
}

class _TipList extends StatelessWidget {
  const _TipList({required this.tips});

  final List<String> tips;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final tip in tips)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('•  ', style: AppType.ui(color: AppColors.fg2)),
                  Expanded(
                    child: Text(
                      tip,
                      style: AppType.ui(
                        size: AppType.sizeBody,
                        color: AppColors.fg1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
