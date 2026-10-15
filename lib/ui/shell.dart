import 'package:flutter/material.dart';

import '../data/library.dart';
import 'home/home_screen.dart';
import 'my_list/my_list_screen.dart';
import 'search/search_screen.dart';
import 'theme.dart';

/// Root scaffold with the Home / Search / My List bottom navigation.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _index = 0;
  final _searchFocus = FocusNode();
  late final List<Widget> _tabs = [
    const HomeScreen(),
    SearchScreen(focusNode: _searchFocus),
    const MyListScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Persist debounced watch progress before the process may be killed.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      Library.instance.flush();
    }
  }

  void _select(int i) {
    if (i == _index) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _index = i);
    if (i == 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _index == 1) _searchFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _select(0);
      },
      child: Scaffold(
        body: IndexedStack(
          index: _index,
          children: [
            for (var i = 0; i < _tabs.length; i++)
              TickerMode(enabled: i == _index, child: _tabs[i]),
          ],
        ),
        bottomNavigationBar: DecoratedBox(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.outline, width: 0.5)),
          ),
          child: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: _select,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.search_rounded),
                selectedIcon: Icon(Icons.search_rounded),
                label: 'Search',
              ),
              NavigationDestination(
                icon: Icon(Icons.bookmark_border_rounded),
                selectedIcon: Icon(Icons.bookmark_rounded),
                label: 'My List',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
