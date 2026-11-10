// Entry point used only to produce README screenshots:
//   flutter run --release -t tool/screenshots_main.dart
// It runs the real UI against made-up, in-memory data. Nothing is read from or
// written to the encrypted vault, and no SMS are accessed.
import 'package:cc_app/main.dart';
import 'package:cc_app/models/category.dart';
import 'package:cc_app/models/models.dart';
import 'package:cc_app/services/sms_source.dart';
import 'package:cc_app/services/vault.dart';
import 'package:cc_app/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class _DemoVault implements VaultStore {
  _DemoVault(this.data);
  VaultData data;
  @override
  Future<VaultData> load() async => data;
  @override
  Future<void> save(VaultData next) async => data = next;
  @override
  Future<void> wipe() async => data = const VaultData();
}

class _NoSms implements SmsSource {
  @override
  bool get isSupported => true;
  @override
  Future<SmsAccess> status() async => SmsAccess.granted;
  @override
  Future<SmsAccess> request() async => SmsAccess.granted;
  @override
  Future<List<RawSms>> readInbox({
    required DateTime since,
    int limit = 0,
  }) async => const [];
  @override
  Future<void> openSettings() async {}
}

VaultData _sample() {
  final now = DateTime.now();
  final cards = [
    CardProfile(
      id: 'c1',
      name: 'Everyday Card',
      issuer: 'Sample Bank',
      last4: '1111',
      colorValue: 0xFF3B5BDB,
      defaultRateBps: 100,
      categoryRatesBps: const {
        SpendCategory.dining: 500,
        SpendCategory.groceries: 300,
      },
      cycleCapMinor: 100000,
      billingDay: 5,
      createdAt: now.subtract(const Duration(days: 200)),
    ),
    CardProfile(
      id: 'c2',
      name: 'Travel Card',
      issuer: 'Demo Bank',
      last4: '2222',
      colorValue: 0xFF0CA678,
      defaultRateBps: 150,
      categoryRatesBps: const {
        SpendCategory.travel: 500,
        SpendCategory.fuel: 400,
      },
      cycleCapMinor: null,
      billingDay: 15,
      createdAt: now.subtract(const Duration(days: 200)),
    ),
  ];

  // (merchant, category, rupees, card index)
  const rows = <(String, SpendCategory, int, int)>[
    ('Fresh Basket', SpendCategory.groceries, 2450, 0),
    ('Spice Garden', SpendCategory.dining, 1380, 0),
    ('Metro Cabs', SpendCategory.travel, 640, 1),
    ('City Power Board', SpendCategory.utilities, 2100, 0),
    ('Petro Plus', SpendCategory.fuel, 3000, 1),
    ('Style Street', SpendCategory.shopping, 4200, 0),
    ('Cine Max', SpendCategory.entertainment, 900, 0),
    ('Care Clinic', SpendCategory.health, 1500, 1),
    ('Coffee Corner', SpendCategory.dining, 420, 0),
    ('SkyWays Air', SpendCategory.travel, 8800, 1),
    ('Daily Mart', SpendCategory.groceries, 1860, 0),
    ('Pizza Point', SpendCategory.dining, 760, 0),
    ('Gadget Hub', SpendCategory.shopping, 6400, 1),
    ('Stream Plus', SpendCategory.entertainment, 499, 0),
  ];

  final txns = <TxnRecord>[];
  var n = 0;
  for (var month = 0; month < 6; month++) {
    for (var i = 0; i < rows.length; i++) {
      final r = rows[(i + month * 3) % rows.length];
      // Spread evenly over the last ~180 days, newest first.
      final daysAgo = month * 30 + (i * 2) + 1;
      final ts = now.subtract(Duration(days: daysAgo, hours: i));
      final scale = 90 + ((n * 37) % 40); // 90..129 % so months differ.
      txns.add(
        TxnRecord(
          id: 't${n++}',
          cardId: cards[r.$4].id,
          cardLast4Hint: cards[r.$4].last4,
          amountMinor: r.$3 * scale,
          currency: 'INR',
          merchant: r.$1,
          category: r.$2,
          timestamp: ts,
          source: TxnSource.manual,
          dedupeKey: null,
        ),
      );
    }
  }
  txns.sort((a, b) => b.timestamp.compareTo(a.timestamp));

  final credits = [
    for (var m = 1; m <= 3; m++)
      CashbackCredit(
        id: 'cr$m',
        cardId: cards[0].id,
        cardLast4Hint: cards[0].last4,
        amountMinor: 45000 + m * 3000,
        currency: 'INR',
        date: now.subtract(Duration(days: m * 30 - 3)),
        dedupeKey: null,
      ),
  ];

  return VaultData(cards: cards, transactions: txns, credits: credits);
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) =>
          AppState(vault: _DemoVault(_sample()), sms: _NoSms())..load(),
      child: const CardwiseApp(),
    ),
  );
}
