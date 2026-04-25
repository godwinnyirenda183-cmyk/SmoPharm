import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/domain/entities/user.dart';
import 'package:pharmacy_pos/domain/services/sync_service.dart';
import 'package:pharmacy_pos/providers/batch_provider.dart';
import 'package:pharmacy_pos/providers/low_stock_provider.dart';
import 'package:pharmacy_pos/providers/session_timeout_provider.dart';
import 'package:pharmacy_pos/providers/settings_provider.dart';
import 'package:pharmacy_pos/providers/sync_status_provider.dart';

// ---------------------------------------------------------------------------
// Near-expiry count provider
// ---------------------------------------------------------------------------

/// Emits the count of near-expiry batches, refreshing every 30 seconds.
final _nearExpiryCountProvider = StreamProvider<int>((ref) async* {
  final batchRepo = ref.watch(batchRepositoryProvider);
  final settingsRepo = ref.watch(settingsRepositoryProvider);

  Future<int> fetch() async {
    final windowDays = await settingsRepo.getNearExpiryWindowDays();
    final batches = await batchRepo.nearExpiry(windowDays);
    return batches.length;
  }

  yield await fetch();

  final ticker = Stream<void>.periodic(const Duration(seconds: 30));
  await for (final _ in ticker) {
    yield await fetch();
  }
});

// ---------------------------------------------------------------------------
// DashboardScreen
// ---------------------------------------------------------------------------

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lowStockAsync = ref.watch(lowStockProvider);
    final syncStatusAsync = ref.watch(syncStatusProvider);
    final nearExpiryAsync = ref.watch(_nearExpiryCountProvider);

    final lowStockCount = lowStockAsync.maybeWhen(
      data: (list) => list.length,
      orElse: () => 0,
    );

    final nearExpiryCount = nearExpiryAsync.maybeWhen(
      data: (n) => n,
      orElse: () => 0,
    );

    final syncStatus = syncStatusAsync.maybeWhen(
      data: (s) => s,
      orElse: () => SyncStatus.offline,
    );

    final user = ref.read(authServiceProvider).currentUser;
    final isAdmin = user?.role == UserRole.admin;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pharmacy POS'),
        actions: [
          _SyncStatusChip(status: syncStatus),
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: 'Account',
            onSelected: (value) async {
              switch (value) {
                case 'change_password':
                  Navigator.of(context).pushNamed('/change-password');
                  break;
                case 'users':
                  Navigator.of(context).pushNamed('/users');
                  break;
                case 'logout':
                  final authService = ref.read(authServiceProvider);
                  await authService.logout();
                  if (context.mounted) {
                    Navigator.of(context)
                        .pushNamedAndRemoveUntil('/', (r) => false);
                  }
                  break;
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'change_password',
                child: Row(children: [
                  const Icon(Icons.lock_reset, size: 18),
                  const SizedBox(width: 8),
                  Text('Change Password'
                      '${user?.username != null ? ' (${user!.username})' : ''}'),
                ]),
              ),
              if (isAdmin)
                const PopupMenuItem(
                  value: 'users',
                  child: Row(children: [
                    Icon(Icons.manage_accounts, size: 18),
                    SizedBox(width: 8),
                    Text('Manage Users'),
                  ]),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'logout',
                child: Row(children: [
                  Icon(Icons.logout, size: 18),
                  SizedBox(width: 8),
                  Text('Logout'),
                ]),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Alert banners
            if (lowStockCount > 0) ...[
              _AlertBanner(
                icon: Icons.warning_amber_rounded,
                count: lowStockCount,
                label:
                    '$lowStockCount product${lowStockCount == 1 ? '' : 's'} below low-stock threshold',
                color: Theme.of(context).colorScheme.errorContainer,
                onColor: Theme.of(context).colorScheme.onErrorContainer,
                onTap: () => Navigator.of(context).pushNamed('/reports'),
              ),
              const SizedBox(height: 8),
            ],
            if (nearExpiryCount > 0) ...[
              _AlertBanner(
                icon: Icons.hourglass_bottom_rounded,
                count: nearExpiryCount,
                label:
                    '$nearExpiryCount batch${nearExpiryCount == 1 ? '' : 'es'} near expiry',
                color: Colors.orange.shade100,
                onColor: Colors.orange.shade900,
                onTap: () => Navigator.of(context).pushNamed('/reports'),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: _NavigationGrid(isAdmin: isAdmin),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Alert banner
// ---------------------------------------------------------------------------

class _AlertBanner extends StatelessWidget {
  const _AlertBanner({
    required this.icon,
    required this.count,
    required this.label,
    required this.color,
    required this.onColor,
    required this.onTap,
  });

  final IconData icon;
  final int count;
  final String label;
  final Color color;
  final Color onColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Badge(
                label: Text('$count'),
                child: Icon(icon, color: onColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: onColor),
                ),
              ),
              Icon(Icons.chevron_right, color: onColor),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sync status chip
// ---------------------------------------------------------------------------

class _SyncStatusChip extends StatelessWidget {
  const _SyncStatusChip({required this.status});

  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, icon, color) = switch (status) {
      SyncStatus.offline => ('Offline', Icons.cloud_off, Colors.orange),
      SyncStatus.syncing => ('Syncing…', Icons.sync, Colors.blue),
      SyncStatus.syncComplete => ('Synced', Icons.cloud_done, Colors.green),
      SyncStatus.syncError => ('Sync error', Icons.cloud_off, Colors.red),
      SyncStatus.idle => ('Online', Icons.cloud_queue, Colors.green),
    };

    return Chip(
      avatar: Icon(icon, size: 16, color: color),
      label: Text(label, style: TextStyle(fontSize: 12, color: color)),
      backgroundColor: color.withValues(alpha: 0.1),
      side: BorderSide(color: color.withValues(alpha: 0.3)),
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }
}

// ---------------------------------------------------------------------------
// Navigation grid
// ---------------------------------------------------------------------------

class _NavigationGrid extends StatelessWidget {
  const _NavigationGrid({required this.isAdmin});

  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    final items = [
      const _NavItem(
        icon: Icons.point_of_sale,
        label: 'POS / Sale',
        route: '/pos',
      ),
      const _NavItem(
        icon: Icons.inventory_2,
        label: 'Products',
        route: '/products',
      ),
      const _NavItem(
        icon: Icons.add_box,
        label: 'Stock-In',
        route: '/stock-in',
      ),
      const _NavItem(
        icon: Icons.tune,
        label: 'Stock Adjustment',
        route: '/stock-adjustment',
      ),
      const _NavItem(
        icon: Icons.bar_chart,
        label: 'Reports',
        route: '/reports',
      ),
      const _NavItem(
        icon: Icons.history,
        label: 'Sales History',
        route: '/sales-history',
      ),
      const _NavItem(
        icon: Icons.view_list,
        label: 'Batches',
        route: '/batches',
      ),
      const _NavItem(
        icon: Icons.settings,
        label: 'Settings',
        route: '/settings',
      ),
      if (isAdmin)
        const _NavItem(
          icon: Icons.manage_accounts,
          label: 'Users',
          route: '/users',
        ),
    ];

    return GridView.count(
      crossAxisCount: 3,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.1,
      children: items.map((item) => _NavCard(item: item)).toList(),
    );
  }
}

class _NavItem {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.route,
  });

  final IconData icon;
  final String label;
  final String route;
}

class _NavCard extends StatelessWidget {
  const _NavCard({required this.item});

  final _NavItem item;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).pushNamed(item.route),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(item.icon,
                size: 36,
                color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 8),
            Text(
              item.label,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ],
        ),
      ),
    );
  }
}
