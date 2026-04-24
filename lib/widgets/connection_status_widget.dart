import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_tokens.dart';
import '../design/app_theme.dart';
import '../providers/connection_provider.dart';

/// Widget to display connection status to qBittorrent
class ConnectionStatusWidget extends ConsumerWidget {
  final bool showLabel;
  final bool dense;

  const ConnectionStatusWidget({
    super.key,
    this.showLabel = true,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(connectionProvider);
    final theme = Theme.of(context);
    final appColors = context.appColors;

    Color statusColor;
    Color statusBgColor;
    IconData statusIcon;
    String statusText;

    switch (connectionState.status) {
      case ConnectionStatus.connected:
        statusColor = appColors.success;
        statusBgColor = appColors.successBackground;
        statusIcon = Icons.cloud_done_rounded;
        statusText = 'Connected';
        break;
      case ConnectionStatus.connecting:
        statusColor = appColors.warning;
        statusBgColor = appColors.warningBackground;
        statusIcon = Icons.cloud_sync_rounded;
        statusText = 'Connecting...';
        break;
      case ConnectionStatus.error:
        statusColor = appColors.errorState;
        statusBgColor = appColors.errorStateBackground;
        statusIcon = Icons.cloud_off_rounded;
        statusText = 'Error';
        break;
      case ConnectionStatus.disconnected:
        statusColor = appColors.paused;
        statusBgColor = appColors.pausedBackground;
        statusIcon = Icons.cloud_off_rounded;
        statusText = 'Disconnected';
        break;
    }

    if (dense) {
      return Tooltip(
        message: connectionState.errorMessage ?? statusText,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: statusBgColor,
            shape: BoxShape.circle,
          ),
          child: Icon(statusIcon, color: statusColor, size: AppIconSize.sm),
        ),
      );
    }

    return InkWell(
      onTap:
          connectionState.hasError ||
              connectionState.status == ConnectionStatus.disconnected
          ? () => ref.read(connectionProvider.notifier).retry()
          : null,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: statusBgColor,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(color: statusColor.withAlpha(AppOpacity.light)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (connectionState.isConnecting)
              SizedBox(
                width: AppIconSize.sm,
                height: AppIconSize.sm,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: statusColor,
                ),
              )
            else
              Icon(statusIcon, size: AppIconSize.sm, color: statusColor),
            if (showLabel) ...[
              const SizedBox(width: AppSpacing.sm),
              Text(
                statusText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: statusColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            if (connectionState.qbVersion != null && showLabel) ...[
              const SizedBox(width: AppSpacing.sm),
              Text(
                'v${connectionState.qbVersion}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: appColors.mutedText,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Banner widget to show when disconnected
class ConnectionBanner extends ConsumerStatefulWidget {
  final VoidCallback? onOpenSettings;

  const ConnectionBanner({super.key, this.onOpenSettings});

  @override
  ConsumerState<ConnectionBanner> createState() => _ConnectionBannerState();
}

class _ConnectionBannerState extends ConsumerState<ConnectionBanner> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final connectionState = ref.watch(connectionProvider);
    final theme = Theme.of(context);
    final appColors = context.appColors;

    if (connectionState.isConnected) {
      return const SizedBox.shrink();
    }

    Color backgroundColor;
    Color textColor;
    String message;
    String? hintMessage;
    IconData icon;

    if (connectionState.isConnecting) {
      backgroundColor = appColors.warningBackground;
      textColor = appColors.warning;
      message = 'Connecting to qBittorrent...';
      icon = Icons.cloud_sync_rounded;
    } else if (connectionState.hasError) {
      backgroundColor = appColors.errorStateBackground;
      textColor = appColors.errorState;
      message = 'Connection failed';
      hintMessage = _getErrorHint(connectionState.errorMessage);
      icon = Icons.error_outline_rounded;
    } else {
      backgroundColor = appColors.pausedBackground;
      textColor = appColors.paused;
      message = 'Not connected to qBittorrent';
      hintMessage = 'Configure connection settings to get started';
      icon = Icons.cloud_off_rounded;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 520;
        final retryAction = isCompact
            ? IconButton(
                tooltip: 'Retry connection',
                onPressed: () => ref.read(connectionProvider.notifier).retry(),
                icon: const Icon(Icons.refresh_rounded),
                color: textColor,
              )
            : FilledButton.tonalIcon(
                onPressed: () => ref.read(connectionProvider.notifier).retry(),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
                style: FilledButton.styleFrom(
                  backgroundColor: textColor.withAlpha(AppOpacity.light),
                  foregroundColor: textColor,
                ),
              );
        final settingsAction = widget.onOpenSettings == null
            ? null
            : isCompact
            ? IconButton(
                tooltip: 'Open Settings',
                onPressed: widget.onOpenSettings,
                icon: const Icon(Icons.settings_outlined),
                color: textColor,
              )
            : OutlinedButton.icon(
                onPressed: widget.onOpenSettings,
                icon: const Icon(Icons.settings_outlined),
                label: const Text('Settings'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: textColor,
                  side: BorderSide(
                    color: textColor.withAlpha(AppOpacity.light),
                  ),
                ),
              );

        return AnimatedSize(
          duration: AppDuration.normal,
          curve: Curves.easeOutCubic,
          child: Material(
            color: backgroundColor,
            child: InkWell(
              onTap: connectionState.hasError && connectionState.errorMessage != null
                  ? () => setState(() => _isExpanded = !_isExpanded)
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(AppSpacing.sm),
                          decoration: BoxDecoration(
                            color: textColor.withAlpha(AppOpacity.light),
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          child: Icon(icon, color: textColor, size: AppIconSize.sm),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                message,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: textColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (hintMessage != null && !_isExpanded) ...[
                                const SizedBox(height: 2),
                                Text(
                                  hintMessage,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: textColor.withAlpha(AppOpacity.heavy),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (connectionState.hasError && connectionState.errorMessage != null) ...[
                          IconButton(
                            onPressed: () => setState(() => _isExpanded = !_isExpanded),
                            icon: AnimatedRotation(
                              turns: _isExpanded ? 0.5 : 0,
                              duration: AppDuration.fast,
                              child: Icon(Icons.keyboard_arrow_down_rounded, color: textColor),
                            ),
                            tooltip: _isExpanded ? 'Hide details' : 'Show details',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                        ],
                        if (!connectionState.isConnecting) ...[
                          retryAction,
                          if (settingsAction != null) ...[
                            const SizedBox(width: AppSpacing.sm),
                            settingsAction,
                          ],
                        ],
                        if (connectionState.isConnecting)
                          SizedBox(
                            width: AppIconSize.md,
                            height: AppIconSize.md,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: textColor,
                            ),
                          ),
                      ],
                    ),
                    // Expanded error details
                    if (_isExpanded && connectionState.errorMessage != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Container(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        decoration: BoxDecoration(
                          color: textColor.withAlpha(AppOpacity.subtle),
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Error Details',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: textColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              connectionState.errorMessage!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: textColor.withAlpha(AppOpacity.almostOpaque),
                                fontFamily: 'monospace',
                              ),
                            ),
                            const SizedBox(height: AppSpacing.md),
                            Text(
                              'Troubleshooting Tips:',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: textColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            ..._getTroubleshootingTips(connectionState.errorMessage!).map(
                              (tip) => Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('• ', style: TextStyle(color: textColor)),
                                    Expanded(
                                      child: Text(
                                        tip,
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: textColor.withAlpha(AppOpacity.almostOpaque),
                                        ),
                                      ),
                                    ),
                                  ],
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
            ),
          ),
        );
      },
    );
  }

  String _getErrorHint(String? errorMessage) {
    if (errorMessage == null) return 'Check your connection settings';
    final lower = errorMessage.toLowerCase();
    if (lower.contains('connection refused') || lower.contains('no route')) {
      return 'qBittorrent may not be running';
    }
    if (lower.contains('401') || lower.contains('unauthorized')) {
      return 'Check your username and password';
    }
    if (lower.contains('timeout')) {
      return 'Server is taking too long to respond';
    }
    if (lower.contains('certificate') || lower.contains('ssl')) {
      return 'SSL/Certificate issue detected';
    }
    return 'Tap for troubleshooting tips';
  }

  List<String> _getTroubleshootingTips(String errorMessage) {
    final lower = errorMessage.toLowerCase();
    final tips = <String>[];
    
    if (lower.contains('connection refused') || lower.contains('no route')) {
      tips.add('Make sure qBittorrent is running');
      tips.add('Check if the Web UI is enabled in qBittorrent settings');
      tips.add('Verify the host and port are correct');
    } else if (lower.contains('401') || lower.contains('unauthorized')) {
      tips.add('Verify your username and password');
      tips.add('Check if authentication is required in qBittorrent');
    } else if (lower.contains('timeout')) {
      tips.add('Check if qBittorrent is responding');
      tips.add('Try increasing the connection timeout');
      tips.add('Check your network connection');
    } else if (lower.contains('certificate') || lower.contains('ssl')) {
      tips.add('Try disabling HTTPS if not required');
      tips.add('Check if the SSL certificate is valid');
    } else {
      tips.add('Verify qBittorrent is running and accessible');
      tips.add('Check your network connection');
      tips.add('Review the connection settings');
    }
    
    return tips;
  }
}
