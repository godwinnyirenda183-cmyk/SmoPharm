import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pharmacy_pos/domain/services/sync_service.dart';
import 'package:pharmacy_pos/providers/low_stock_provider.dart';
import 'package:pharmacy_pos/providers/session_timeout_provider.dart';
import 'package:pharmacy_pos/providers/sync_status_provider.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lowStockAsync = ref.watch(lowStockProvider);
    final syncStatusAsync = ref.watch(syncStatusProvider);

    final lowStockCount = lowStockAsync.maybeWhen(
      data: (list) => list.length,
      orElse: () => 0,
    );

    final syncStatus = syncStatusAsync.maybeWhen(
      data: (s) => s,
      orElse: () => SyncStatus.offline,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pharmacy POS'),
        actions: [
          _SyncStatusChip(status: syncStatus),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: () async {
              final authService = ref.read(authServiceProvider);
              await authService.logout();
              if (context.mounted) {
                Navigator.of(context).pushReplacementNamed('/');
              }
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (lowStockCount > 0)
              _LowStockBanner(count: lowStockCount),
            const SizedBox(height: 16),
            Expanded(
              child: _NavigationGrid(),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Low-stock banner
// ---------------------------------------------------------------------------

class _LowStockBanner extends StatelessWidget {
  const _LowStockBanner({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.of(context).pushNamed('/reports/low-stock'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Badge(
                label: Text('$count'),
                child: const Icon(Icons.warning_amber_rounded),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '$count product${count == 1 ? '' : 's'} below low-stock threshold',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
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
  @override
  Widget build(BuildContext context) {
    const items = [
      _NavItem(
        icon: Icons.point_of_sale,
        label: 'POS / Sale',
        route: '/pos',
      ),
      _NavItem(
        icon: Icons.inventory_2,
        label: 'Products',
        route: '/products',
      ),
      _NavItem(
        icon: Icons.add_box,
        label: 'Stock-In',
        route: '/stock-in',
      ),
      _NavItem(
        icon: Icons.tune,
        label: 'Stock Adjustment',
        route: '/stock-adjustment',
      ),
      _NavItem(
        icon: Icons.bar_chart,
        label: 'Reports',
        route: '/reports',
      ),
      _NavItem(
        icon: Icons.settings,
        label: 'Settings',
        route: '/settings',
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
            Icon(item.icon, size: 36, color: Theme.of(context).colorScheme.primary),
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
