import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharmacy_pos/domain/services/auth_service.dart';
import 'package:pharmacy_pos/providers/session_timeout_provider.dart';
import 'package:pharmacy_pos/ui/screens/batch_management_screen.dart';
import 'package:pharmacy_pos/ui/screens/change_password_screen.dart';
import 'package:pharmacy_pos/ui/screens/dashboard_screen.dart';
import 'package:pharmacy_pos/ui/screens/lock_screen.dart';
import 'package:pharmacy_pos/ui/screens/login_screen.dart';
import 'package:pharmacy_pos/ui/screens/pos_screen.dart';
import 'package:pharmacy_pos/ui/screens/products_screen.dart';
import 'package:pharmacy_pos/ui/screens/reports_screen.dart';
import 'package:pharmacy_pos/ui/screens/sale_void_screen.dart';
import 'package:pharmacy_pos/ui/screens/sales_history_screen.dart';
import 'package:pharmacy_pos/ui/screens/settings_screen.dart';
import 'package:pharmacy_pos/ui/screens/stock_adjustment_screen.dart';
import 'package:pharmacy_pos/ui/screens/stock_in_screen.dart';
import 'package:pharmacy_pos/ui/screens/user_management_screen.dart';

const _supabaseUrl = 'https://mhfdzqzryzdqhtlwtwmn.supabase.co';
const _supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1oZmR6cXpyeXpkcWh0bHd0d21uIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzUzMTM5MzgsImV4cCI6MjA5MDg4OTkzOH0.ymzMccmJPICgEYkzokOhQLq7L2LDQi0tcrQkgQLGPlk';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Global Flutter error handler — logs to console in debug, could be wired
  // to a crash reporting service in production.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exceptionAsString()}');
    debugPrint(details.stack.toString());
  };

  await Supabase.initialize(
    url: _supabaseUrl,
    anonKey: _supabaseAnonKey,
  );

  runApp(
    const ProviderScope(
      child: PharmacyPosApp(),
    ),
  );
}

class PharmacyPosApp extends ConsumerWidget {
  const PharmacyPosApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'Pharmacy POS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const _AppRoot(),
      routes: {
        '/dashboard': (_) => const _AppRoot(child: DashboardScreen()),
        '/pos': (_) => const _AppRoot(child: PosScreen()),
        '/products': (_) => const _AppRoot(child: ProductsScreen()),
        '/stock-in': (_) => const _AppRoot(child: StockInScreen()),
        '/stock-adjustment': (_) =>
            const _AppRoot(child: StockAdjustmentScreen()),
        '/void-sale': (_) => const _AppRoot(child: SaleVoidScreen()),
        '/reports': (_) => const _AppRoot(child: ReportsScreen()),
        '/reports/low-stock': (_) => const _AppRoot(child: ReportsScreen()),
        '/settings': (_) => const _AppRoot(child: SettingsScreen()),
        '/change-password': (_) =>
            const _AppRoot(child: ChangePasswordScreen()),
        '/users': (_) => const _AppRoot(child: UserManagementScreen()),
        '/sales-history': (_) =>
            const _AppRoot(child: SalesHistoryScreen()),
        '/batches': (_) =>
            const _AppRoot(child: BatchManagementScreen()),
      },
    );
  }
}

/// Root widget that:
/// 1. Wraps every screen in a [Listener] so any pointer event resets the
///    inactivity timer — no individual screen needs to call resetTimer on tap.
/// 2. Watches [sessionTimeoutProvider] and pushes [LockScreen] when the
///    session locks.
class _AppRoot extends ConsumerStatefulWidget {
  const _AppRoot({this.child});

  /// The screen to display. When null, shows [LoginScreen].
  final Widget? child;

  @override
  ConsumerState<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<_AppRoot> {
  bool _lockScreenShown = false;

  @override
  Widget build(BuildContext context) {
    // Watch session state and push lock screen on lock.
    ref.listen<SessionState>(sessionTimeoutProvider, (previous, next) {
      if (next == SessionState.locked && !_lockScreenShown) {
        _lockScreenShown = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            Navigator.of(context)
                .push(
              MaterialPageRoute(
                builder: (_) => const LockScreen(),
                fullscreenDialog: true,
              ),
            )
                .then((_) {
              _lockScreenShown = false;
            });
          }
        });
      }
    });

    return Listener(
      // Reset inactivity timer on any pointer event (tap, scroll, drag).
      onPointerDown: (_) {
        final session = ref.read(sessionTimeoutProvider);
        if (session == SessionState.authenticated) {
          ref.read(sessionTimeoutProvider.notifier).resetTimer();
        }
      },
      child: widget.child ?? const LoginScreen(),
    );
  }
}
