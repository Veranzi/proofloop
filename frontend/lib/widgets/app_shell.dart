import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app/theme.dart';
import '../core/auth_service.dart';
import 'brand_logo.dart';
import 'notification_bell.dart';
import 'user_avatar.dart';

class _NavItem {
  const _NavItem(this.label, this.icon, this.path, {this.adminOnly = false});
  final String label;
  final IconData icon;
  final String path;
  final bool adminOnly;
}

const _sidebarItems = [
  _NavItem('Dashboard', Icons.dashboard_outlined, '/dashboard'),
  _NavItem('Cases', Icons.folder_outlined, '/cases'),
  _NavItem('Evidence', Icons.upload_file_outlined, '/evidence'),
  _NavItem('Review', Icons.fact_check_outlined, '/review'),
  _NavItem('Reports', Icons.description_outlined, '/reports'),
  _NavItem('Profile', Icons.person_outline, '/profile'),
  _NavItem('Admin', Icons.admin_panel_settings_outlined, '/admin',
      adminOnly: true),
  _NavItem('Integrations', Icons.hub_outlined, '/integrations',
      adminOnly: true),
];

// Phones get the five tabs shown in the mobile mockups.
const _bottomItems = [
  _NavItem('Home', Icons.home_outlined, '/dashboard'),
  _NavItem('Cases', Icons.folder_outlined, '/cases'),
  _NavItem('Upload', Icons.cloud_upload_outlined, '/evidence'),
  _NavItem('Reports', Icons.description_outlined, '/reports'),
  _NavItem('Profile', Icons.person_outline, '/profile'),
];

/// Layout for every signed-in page: navy sidebar + top bar on wide screens,
/// bottom navigation on phones.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  static const wideBreakpoint = 900.0;

  int _indexFor(List<_NavItem> items) {
    final i = items.indexWhere((n) => location.startsWith(n.path));
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
    final auth = AuthService.instance;

    if (!wide) {
      final index = _indexFor(_bottomItems);
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              const _PhoneTopBar(),
              const Divider(height: 1),
              Expanded(child: child),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          height: 64,
          backgroundColor: Colors.white,
          indicatorColor: AppColors.primarySoft,
          selectedIndex: index,
          onDestinationSelected: (i) => context.go(_bottomItems[i].path),
          destinations: [
            for (final item in _bottomItems)
              NavigationDestination(icon: Icon(item.icon), label: item.label),
          ],
        ),
      );
    }

    final items =
        _sidebarItems.where((n) => !n.adminOnly || auth.isAdmin).toList();
    final index = _indexFor(items);

    return Scaffold(
      body: Row(
        children: [
          _Sidebar(
            items: items,
            selected: index,
            onSelect: (i) => context.go(items[i].path),
          ),
          Expanded(
            child: Column(
              children: [
                const _TopBar(),
                const Divider(height: 1),
                Expanded(child: child),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.items,
    required this.selected,
    required this.onSelect,
  });

  final List<_NavItem> items;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      color: AppColors.navy,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 8, bottom: 28),
            child: BrandLogo(size: 18, light: true),
          ),
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Material(
                color: i == selected ? AppColors.navyLight : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => onSelect(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 11),
                    child: Row(
                      children: [
                        Icon(items[i].icon,
                            size: 19,
                            color: i == selected
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.7)),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            items[i].label,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: i == selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: i == selected
                                  ? Colors.white
                                  : Colors.white.withValues(alpha: 0.75),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthService.instance,
      builder: (context, _) {
        final user = AuthService.instance.user;
        return Container(
          height: 64,
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              const Spacer(),
              SizedBox(
                width: 280,
                child: TextField(
                  textInputAction: TextInputAction.search,
                  // Searches case titles and references (GET /v1/cases?q=).
                  onSubmitted: (q) => context.go(
                      Uri(path: '/cases', queryParameters: {
                        if (q.trim().isNotEmpty) 'q': q.trim(),
                      }).toString()),
                  decoration: const InputDecoration(
                    hintText: 'Search cases...',
                    prefixIcon: Icon(Icons.search, size: 18),
                    contentPadding: EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const NotificationBell(),
              const SizedBox(width: 8),
              _AccountMenu(
                child: Row(
                  children: [
                    UserAvatar(
                        initials: user?.initials ?? '', url: user?.avatarUrl),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 200),
                      child: Text(user?.displayName ?? '',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w500)),
                    ),
                    const Icon(Icons.keyboard_arrow_down, size: 18),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Phones: logo, the bell and the account menu above the page.
class _PhoneTopBar extends StatelessWidget {
  const _PhoneTopBar();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthService.instance,
      builder: (context, _) {
        final user = AuthService.instance.user;
        return Container(
          height: 52,
          color: Colors.white,
          padding: const EdgeInsets.only(left: 16, right: 8),
          child: Row(
            children: [
              const BrandLogo(size: 16),
              const Spacer(),
              const NotificationBell(),
              _AccountMenu(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: UserAvatar(
                      initials: user?.initials ?? '', url: user?.avatarUrl),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AccountMenu extends StatelessWidget {
  const _AccountMenu({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Account',
      onSelected: (v) async {
        if (v == 'profile') context.go('/profile');
        if (v == 'signout') {
          await AuthService.instance.signOut();
          if (context.mounted) context.go('/login');
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'profile', child: Text('Profile')),
        PopupMenuItem(value: 'signout', child: Text('Sign out')),
      ],
      child: child,
    );
  }
}
