import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharmacy_pos/ui/screens/dashboard_screen.dart';
import 'package:pharmacy_pos/ui/screens/login_screen.dart';
import 'package:pharmacy_pos/ui/screens/pos_screen.dart';
import 'package:pharmacy_pos/ui/screens/products_screen.dart';
import 'package:pharmacy_pos/ui/screens/reports_screen.dart';
import 'package:pharmacy_pos/ui/screens/sale_void_screen.dart';
import 'package:pharmacy_pos/ui/screens/stock_adjustment_screen.dart';
import 'package:pharmacy_pos/ui/screens/settings_screen.dart';
import 'package:pharmacy_pos/ui/screens/stock_in_screen.dart';

/// Supabase project credentials.
///
/// Replace these placeholder values with your actual Supabase project URL and
/// anon key before deploying. You can find them in the Supabase dashboard under
/// Project Settings → API.
///
/// For production, consider loading these from environment variables or a
/// secrets manager rather than hard-coding them here.
const _supabaseUrl = 'https://your-project-ref.supabase.co';
const _supabaseAnonKey = 'your-anon-key-here';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
      home: const LoginScreen(),
      routes: {
        '/dashboard': (_) => const DashboardScreen(),
        '/pos': (_) => const PosScreen(),
        '/products': (_) => const ProductsScreen(),
        '/stock-in': (_) => const StockInScreen(),
        '/stock-adjustment': (_) => const StockAdjustmentScreen(),
        '/void-sale': (_) => const SaleVoidScreen(),
        '/reports': (_) => const ReportsScreen(),
        '/reports/low-stock': (_) => const ReportsScreen(),
        '/settings': (_) => const SettingsScreen(),
      },
    );
  }

}
