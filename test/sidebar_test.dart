import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/design/app_theme.dart';
import 'package:mediahub/utils/constants.dart';
import 'package:mediahub/widgets/common/mediahub_sidebar.dart';
import 'package:mediahub/widgets/common/nav_badge.dart';

const _items = [
  SidebarItem(
    icon: Icons.home_outlined,
    selectedIcon: Icons.home_rounded,
    label: 'Home',
  ),
  SidebarItem(
    icon: Icons.warning_amber_rounded,
    selectedIcon: Icons.warning_amber_rounded,
    label: 'Transfers',
    badge: 2,
    errorBadge: true,
    status: '2 need attention',
  ),
  SidebarItem(
    icon: Icons.calendar_month_outlined,
    selectedIcon: Icons.calendar_month_rounded,
    label: 'Calendar',
    dot: true,
    dotPulse: true,
    status: '1 airing today',
  ),
];

Widget _host({
  bool collapsed = false,
  bool connected = true,
  ValueChanged<int>? onSelect,
  VoidCallback? onToggle,
}) => MaterialApp(
  theme: buildDarkTheme(),
  home: Scaffold(
    body: Row(
      children: [
        MediaHubSidebar(
          items: _items,
          currentIndex: 0,
          onDestinationSelected: onSelect ?? (_) {},
          onAddTorrent: () {},
          collapsed: collapsed,
          onToggleCollapse: onToggle ?? () {},
          connected: connected,
          engineName: 'Built-in engine',
        ),
        const Expanded(child: SizedBox()),
      ],
    ),
  ),
);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('shows the real version, not "v 2.4"', (tester) async {
    await tester.pumpWidget(_host());
    expect(find.text('v${AppConstants.appVersion}'), findsOneWidget);
    expect(find.textContaining('2.4'), findsNothing);
  });

  testWidgets('connection status comes from the bool, on two lines', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    expect(find.text('BUILT-IN ENGINE'), findsOneWidget);
    expect(find.text('CONNECTED'), findsOneWidget);

    await tester.pumpWidget(_host(connected: false));
    expect(find.text('OFFLINE'), findsOneWidget);
    expect(find.text('CONNECTED'), findsNothing);
  });

  testWidgets('nav rows are keyboard buttons', (tester) async {
    final handle = tester.ensureSemantics();
    int? selected;
    await tester.pumpWidget(_host(onSelect: (i) => selected = i));

    // Tab from the top lands on the rows in order; Enter activates.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(selected, isNotNull);

    expect(
      tester.getSemantics(find.bySemanticsLabel('Transfers, 2 need attention')),
      isSemantics(isButton: true, isFocusable: true, hasTapAction: true),
    );
    handle.dispose();
  });

  testWidgets('collapsed: tooltips, and the badge and dot stay on the icons', (
    tester,
  ) async {
    await tester.pumpWidget(_host(collapsed: true));

    // Labels are gone…
    expect(find.text('Transfers'), findsNothing);
    // …but every icon says what it is.
    for (final message in [
      'Home',
      'Transfers · 2 need attention',
      'Calendar · 1 airing today',
    ]) {
      expect(find.byTooltip(message), findsOneWidget, reason: message);
    }
    // The error count and the airing dot used to disappear with the labels.
    expect(find.byType(NavBadge), findsWidgets);
    final tag = tester.widget<NavCountTag>(find.byType(NavCountTag));
    expect(tag.count, 2);
    expect(tag.isError, isTrue);
    expect(find.byType(NavStatusDot), findsOneWidget);
    expect(find.byTooltip('Add torrent'), findsOneWidget);
  });

  testWidgets('the collapse toggle is 24px, labelled, and animates cleanly', (
    tester,
  ) async {
    var collapsed = false;
    late StateSetter setOuter;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          setOuter = setState;
          return _host(
            collapsed: collapsed,
            onToggle: () => setState(() => collapsed = !collapsed),
          );
        },
      ),
    );

    final toggle = find.byTooltip('Collapse sidebar');
    expect(toggle, findsOneWidget);
    expect(tester.getSize(toggle).width, greaterThanOrEqualTo(24));

    double railWidth() =>
        tester.getSize(find.byType(MediaHubSidebar)).width -
        MediaHubSidebar.toggleGutter;
    expect(railWidth(), MediaHubSidebar.expandedWidth);

    await tester.tap(toggle);
    // Mid-animation the outer box moves with the rail — it used to jump to
    // the end width at once — and nothing overflows on any frame.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final mid = railWidth();
    expect(mid, lessThan(MediaHubSidebar.expandedWidth));
    expect(mid, greaterThan(MediaHubSidebar.collapsedWidth));
    // Not pumpAndSettle: the calendar dot pulses for as long as it shows.
    await tester.pump(const Duration(milliseconds: 300));
    expect(railWidth(), MediaHubSidebar.collapsedWidth);
    expect(find.byTooltip('Expand sidebar'), findsOneWidget);

    // And back out, frame by frame, without a RenderFlex overflow.
    setOuter(() => collapsed = false);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.takeException(), isNull);
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(railWidth(), MediaHubSidebar.expandedWidth);
  });
}
