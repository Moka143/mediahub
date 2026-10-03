import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../providers/settings_provider.dart';
import '../utils/feedback_utils.dart';
import '../widgets/common/back_shortcuts.dart';
import '../widgets/common/mediahub_confirm_dialog.dart';
import '../widgets/common/mediahub_topbar.dart';
import 'settings/about_tab.dart';
import 'settings/connection_tab.dart';
import 'settings/downloads_tab.dart';
import 'settings/general_tab.dart';

/// Settings, as a pushed page with four tabs.
///
/// Each tab's fields save themselves when the user is done with them (see
/// `SettingsTextField`), so this screen no longer holds a controller per
/// setting or copies values back into them after a reset — the fields
/// follow the saved values on their own.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 4,
    vsync: this,
  );

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();

    // Esc, ⌘[ and Alt+← close Settings like the Back button does.
    return BackShortcuts(
      child: Scaffold(
        appBar: MediaHubTopBar(
          title: 'Settings',
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
                  Tab(icon: Icon(Icons.tune_rounded), text: 'General'),
                  Tab(icon: Icon(Icons.info_outline_rounded), text: 'About'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  const SettingsConnectionTab(),
                  const SettingsDownloadsTab(),
                  const SettingsGeneralTab(),
                  SettingsAboutTab(onReset: _confirmReset),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmReset() async {
    final notifier = ref.read(settingsProvider.notifier);
    final confirmed = await MediaHubConfirmDialog.show(
      context: context,
      title: 'Reset settings?',
      // Exactly what resetToDefaults does: fresh-install defaults (the
      // built-in engine), and the two stored credentials cleared. The TMDB
      // account session is not a setting and stays.
      message:
          'Settings go back to their defaults, the built-in engine is '
          'selected, and the saved qBittorrent password and TMDB token are '
          'cleared. Your library, favorites, watch history and TMDB sign-in '
          'are kept. This can\'t be undone.',
      confirmLabel: 'Reset',
      destructive: true,
      icon: Icons.warning_rounded,
    );
    if (confirmed != true) return;

    await notifier.resetToDefaults();
    if (!mounted) return;
    AppSnackBar.showSuccess(context, message: 'Settings reset to defaults');
  }
}
