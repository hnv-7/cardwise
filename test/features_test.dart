import 'dart:typed_data';

import 'package:cc_app/models/category.dart';
import 'package:cc_app/models/models.dart';
import 'package:cc_app/services/analytics.dart';
import 'package:cc_app/services/backup.dart';
import 'package:cc_app/services/sms_source.dart';
import 'package:cc_app/services/vault.dart';
import 'package:cc_app/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_state_test.dart' show FakeSms, MemoryVault;

TxnRecord txn(
  String id,
  int amt,
  DateTime d, {
  String cardId = 'c1',
  String merchant = 'm',
  SpendCategory c = SpendCategory.dining,
  TxnKind kind = TxnKind.spend,
  int? avail,
}) => TxnRecord(
  id: id,
  cardId: cardId,
  cardLast4Hint: null,
  amountMinor: amt,
  currency: 'INR',
  merchant: merchant,
  category: c,
  timestamp: d,
  source: TxnSource.manual,
  dedupeKey: null,
  kind: kind,
  availableLimitMinor: avail,
);

CardProfile card({
  String id = 'c1',
  String name = 'C',
  int? cap,
  int day = 1,
  Map<SpendCategory, int> rates = const {SpendCategory.dining: 500},
  Map<SpendCategory, int> catCaps = const {},
  List<MerchantRate> merchants = const [],
  int? limit,
  int? dueDays,
}) => CardProfile(
  id: id,
  name: name,
  issuer: '',
  last4: id == 'c1' ? '1111' : '2222',
  colorValue: 0,
  defaultRateBps: 100,
  categoryRatesBps: rates,
  cycleCapMinor: cap,
  billingDay: day,
  createdAt: DateTime(2024),
  merchantRates: merchants,
  categoryCapsMinor: catCaps,
  creditLimitMinor: limit,
  paymentDueDays: dueDays,
);

void main() {
  final d1 = DateTime(2024, 10, 5);
  final d2 = DateTime(2024, 10, 6);
  final d3 = DateTime(2024, 10, 7);

  group('refunds', () {
    test('lower totals and take back cashback', () {
      final c = card();
      final a = Analytics(
        VaultData(
          cards: [c],
          transactions: [
            txn('1', 100000, d1), // 5% -> 5000
            txn('2', 40000, d2, kind: TxnKind.refund), // -2000
          ],
        ),
      );
      expect(a.total(a.transactions()), 60000);
      expect(a.byCategory(a.transactions())[SpendCategory.dining], 60000);
      final s = a.cashbackFor(c);
      expect(s.perTxn['2'], -2000);
      expect(s.estimatedMinor, 3000);
    });

    test('never take a cycle below zero', () {
      final c = card();
      final a = Analytics(
        VaultData(
          cards: [c],
          transactions: [
            txn('1', 100000, DateTime(2024, 9, 20)),
            txn('2', 100000, d1, kind: TxnKind.refund),
          ],
        ),
      );
      final s = a.cashbackFor(c);
      expect(s.perTxn['2'], 0);
      expect(s.perCycle[const MonthKey(2024, 10)], 0);
      expect(s.estimatedMinor, 5000);
    });

    test('scan imports refunds linked to the card', () async {
      final app = AppState(
        vault: MemoryVault(),
        sms: FakeSms([
          RawSms(
            'Rs 499.00 refund credited to your HDFC Bank Credit Card XX4321 '
            'from AMAZON on 10-11-24. Avl Lmt: Rs 50,000.00',
            DateTime(2024, 11, 10, 9),
          ),
        ]),
      );
      await app.load();
      await app.saveCard(
        name: 'T',
        issuer: '',
        last4: '4321',
        colorValue: 0,
        defaultRateBps: 100,
        categoryRatesBps: const {},
      );
      final r = await app.scanInbox(now: DateTime(2024, 11, 15));
      expect(r.added, 1);
      expect(r.refunds, 1);
      final t = app.data.transactions.single;
      expect(t.isRefund, isTrue);
      expect(t.signedMinor, -49900);
      expect(t.cardId, app.data.cards.single.id);
      expect(t.availableLimitMinor, 5000000);
    });
  });

  group('merchant rates and caps', () {
    test('merchant rate beats the category rate', () {
      final c = card(
        merchants: const [MerchantRate(keyword: 'Swiggy', bps: 1000)],
      );
      expect(
        rawCashbackMinor(c, txn('a', 100000, d1, merchant: 'Swiggy Blr')),
        10000,
      );
      expect(
        rawCashbackMinor(c, txn('a', 100000, d1, merchant: 'SWIGGYONE')),
        10000,
      );
      expect(
        rawCashbackMinor(c, txn('a', 100000, d1, merchant: 'Zomato')),
        5000,
      );
      expect(
        rawCashbackMinor(
          c,
          txn('a', 100000, d1, merchant: 'Big Swiggy', c: SpendCategory.travel),
        ),
        10000,
      );
    });

    test('merchant cap applies per cycle', () {
      final c = card(
        merchants: const [
          MerchantRate(keyword: 'amazon', bps: 500, capMinor: 10000),
        ],
      );
      final s = Analytics(
        VaultData(
          cards: [c],
          transactions: [
            txn('1', 150000, d1, merchant: 'Amazon Pay'), // 7500
            txn('2', 150000, d2, merchant: 'Amazon.in'), // 7500 -> 2500
            txn('3', 150000, DateTime(2024, 11, 2), merchant: 'Amazon'),
          ],
        ),
      ).cashbackFor(c);
      expect(s.perTxn['1'], 7500);
      expect(s.perTxn['2'], 2500);
      expect(s.perTxn['3'], 7500);
      expect(s.cappedBuckets[const MonthKey(2024, 10)], {'m:amazon'});
    });

    test('category cap, then the card cap', () {
      final c = card(cap: 8000, catCaps: const {SpendCategory.dining: 6000});
      final s = Analytics(
        VaultData(
          cards: [c],
          transactions: [
            txn('1', 100000, d1), // 5000
            txn('2', 100000, d2), // 5000 -> 1000 (dining cap)
            txn('3', 300000, d3, c: SpendCategory.travel), // 3000 -> 2000
          ],
        ),
      ).cashbackFor(c);
      expect(s.perTxn['1'], 5000);
      expect(s.perTxn['2'], 1000);
      expect(s.perTxn['3'], 2000);
      expect(s.cappedCycles, {const MonthKey(2024, 10)});
    });
  });

  group('best card', () {
    final now = DateTime(2024, 10, 20);
    final capped = card(
      name: 'Capped',
      catCaps: const {SpendCategory.dining: 6000},
      merchants: const [MerchantRate(keyword: 'swiggy', bps: 1000)],
    );
    final plain = card(
      id: 'c2',
      name: 'Plain',
      rates: const {SpendCategory.dining: 200},
    );
    final a = Analytics(
      VaultData(
        cards: [capped, plain],
        transactions: [txn('1', 100000, d1)], // Capped: 5000 of 6000 dining
      ),
    );

    test('accounts for what is left of a cap', () {
      final picks = a.bestCards(
        category: SpendCategory.dining,
        amountMinor: 100000,
        now: now,
      );
      expect(picks.first.card.name, 'Plain');
      expect(picks.first.expectedMinor, 2000);
      expect(picks.last.expectedMinor, 1000);
      expect(picks.last.roomMinor, 1000);
    });

    test('uses a matching merchant rate', () {
      final picks = a.bestCards(
        category: SpendCategory.dining,
        merchant: 'Swiggy',
        amountMinor: 100000,
        now: now,
      );
      expect(picks.first.card.name, 'Capped');
      expect(picks.first.expectedMinor, 10000);
      expect(picks.first.rule?.keyword, 'swiggy');
      expect(picks.first.roomMinor, isNull);
    });
  });

  group('payments due', () {
    final c = card(day: 5, dueDays: 18);
    final data = VaultData(
      cards: [c],
      transactions: [
        txn('1', 100000, DateTime(2024, 10, 20)),
        txn('2', 30000, DateTime(2024, 10, 25), kind: TxnKind.refund),
        txn('3', 99900, DateTime(2024, 11, 6)), // current cycle, not billed
      ],
    );

    test('lists the last statement until its due date', () {
      final dues = Analytics(data)
          .upcomingPayments(now: DateTime(2024, 11, 15));
      expect(dues.length, 1);
      expect(dues.single.dueDate, DateTime(2024, 11, 22));
      expect(dues.single.amountMinor, 70000);
      expect(dues.single.daysLeft(DateTime(2024, 11, 15, 23)), 7);
      expect(
        Analytics(data).upcomingPayments(now: DateTime(2024, 11, 23)),
        isEmpty,
      );
    });

    test(
      'marking paid hides it; cards without a due day are skipped',
      () async {
        final vault = MemoryVault()..stored = data;
        final app = AppState(vault: vault, sms: FakeSms([]));
        await app.load();
        final when = DateTime(2024, 11, 15);
        final due = app.analytics.upcomingPayments(now: when);
        await app.setStatementPaid(due.single.key, true);
        expect(app.analytics.upcomingPayments(now: when), isEmpty);
        expect(vault.stored.paidStatements, {due.single.key});
        await app.setStatementPaid(due.single.key, false);
        expect(app.analytics.upcomingPayments(now: when).length, 1);

        final noDue = VaultData(
          cards: [card(day: 5)],
          transactions: data.transactions,
        );
        expect(Analytics(noDue).upcomingPayments(now: when), isEmpty);
      },
    );
  });

  test('credit usage uses the newest reported available limit', () {
    final c = card(limit: 10000000);
    final a = Analytics(
      VaultData(
        cards: [c],
        transactions: [
          txn('1', 100, d2, avail: 7000000),
          txn('2', 100, d1, avail: 9000000),
          txn('3', 100, d3),
        ],
      ),
    );
    final u = a.creditUsage(c)!;
    expect(u.availableMinor, 7000000);
    expect(u.usedMinor, 3000000);
    expect(u.ratio, closeTo(0.3, 1e-9));
    expect(a.creditUsage(card(id: 'c2')), isNull);
  });

  test('search matches merchant, category, card and amount', () {
    final t = txn('1', 125050, d1, merchant: 'Corner Cafe');
    expect(matchesSearch(t, ''), isTrue);
    expect(matchesSearch(t, 'corner'), isTrue);
    expect(matchesSearch(t, 'DINING'), isTrue);
    expect(matchesSearch(t, '1250'), isTrue);
    expect(matchesSearch(t, '1,250.5'), isTrue);
    expect(matchesSearch(t, '250'), isFalse);
    expect(matchesSearch(t, 'gold', card: card(name: 'Gold')), isTrue);
    expect(matchesSearch(t, 'zomato'), isFalse);
  });

  test('analytics is reused until the data changes', () async {
    final app = AppState(vault: MemoryVault(), sms: FakeSms([]));
    await app.load();
    final first = app.analytics;
    expect(identical(first, app.analytics), isTrue);
    await app.setPrimaryCurrency('USD');
    expect(identical(first, app.analytics), isFalse);
  });

  group('persistence', () {
    test('new fields round trip', () {
      final data = VaultData(
        cards: [
          card(
            catCaps: const {SpendCategory.fuel: 25000},
            merchants: const [
              MerchantRate(keyword: 'Amazon', bps: 500, capMinor: 150000),
              MerchantRate(keyword: 'Flipkart', bps: 500),
            ],
            limit: 20000000,
            dueDays: 18,
          ),
        ],
        transactions: [
          txn('1', 100, d1, kind: TxnKind.refund, avail: 123400),
          txn('2', 100, d1),
        ],
        paidStatements: const {'c1:2024-10'},
      );
      final back = VaultData.fromJson(data.toJson());
      final c = back.cards.single;
      expect(c.categoryCapsMinor, {SpendCategory.fuel: 25000});
      expect(c.merchantRates.length, 2);
      expect(c.merchantRates.first.keyword, 'Amazon');
      expect(c.merchantRates.first.capMinor, 150000);
      expect(c.merchantRates.last.capMinor, isNull);
      expect(c.creditLimitMinor, 20000000);
      expect(c.paymentDueDays, 18);
      expect(back.transactions.first.isRefund, isTrue);
      expect(back.transactions.first.availableLimitMinor, 123400);
      expect(back.transactions.last.isRefund, isFalse);
      expect(back.paidStatements, {'c1:2024-10'});
    });

    test('older data without the new fields loads with defaults', () {
      final old = VaultData(
        cards: [card()],
        transactions: [txn('1', 100, d1)],
      ).toJson();
      final c = (old['cards']! as List).first as Map<String, Object?>;
      for (final k in [
        'merchantRates',
        'categoryCapsMinor',
        'creditLimitMinor',
        'paymentDueDays',
      ]) {
        c.remove(k);
      }
      old.remove('paidStatements');
      final back = VaultData.fromJson(old);
      expect(back.cards.single.merchantRates, isEmpty);
      expect(back.cards.single.categoryCapsMinor, isEmpty);
      expect(back.cards.single.paymentDueDays, isNull);
      expect(back.transactions.single.kind, TxnKind.spend);
      expect(back.paidStatements, isEmpty);
    });

    test('card validation covers the new fields', () async {
      final app = AppState(vault: MemoryVault(), sms: FakeSms([]));
      await app.load();
      String? check({
        List<MerchantRate> merchants = const [],
        Map<SpendCategory, int> caps = const {},
        int? limit,
        int? due,
      }) => app.validateCard(
        name: 'X',
        last4: '1234',
        defaultRateBps: 100,
        categoryRatesBps: const {},
        merchantRates: merchants,
        categoryCapsMinor: caps,
        creditLimitMinor: limit,
        paymentDueDays: due,
      );
      expect(check(), isNull);
      expect(check(caps: const {SpendCategory.fuel: 0}), isNotNull);
      expect(
        check(merchants: const [MerchantRate(keyword: ' ', bps: 100)]),
        isNotNull,
      );
      expect(
        check(
          merchants: const [
            MerchantRate(keyword: 'Amazon', bps: 100),
            MerchantRate(keyword: 'amazon', bps: 200),
          ],
        ),
        isNotNull,
      );
      expect(
        check(merchants: const [MerchantRate(keyword: 'A', bps: 20000)]),
        isNotNull,
      );
      expect(check(limit: 0), isNotNull);
      expect(check(due: 31), isNotNull);
      expect(check(due: 18, limit: 100000), isNull);
    });
  });

  group('backup', () {
    final data = VaultData(
      cards: [card(dueDays: 18)],
      transactions: [txn('1', 12345, d1, kind: TxnKind.refund)],
      primaryCurrency: 'USD',
    );

    test('round trips with the right password', () async {
      final bytes = await Backup.encrypt(
        data,
        'correct horse',
        iterations: 10000,
      );
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'CWB1');
      final back = await Backup.decrypt(bytes, 'correct horse');
      expect(back.toJson(), data.toJson());
    });

    test('rejects a wrong password, tampering and other files', () async {
      final bytes = await Backup.encrypt(
        data,
        'correct horse',
        iterations: 10000,
      );
      await expectLater(
        Backup.decrypt(bytes, 'wrong horse'),
        throwsA(isA<VaultException>()),
      );
      final tampered = Uint8List.fromList(bytes)..[bytes.length - 20] ^= 1;
      await expectLater(
        Backup.decrypt(tampered, 'correct horse'),
        throwsA(isA<VaultException>()),
      );
      await expectLater(
        Backup.decrypt(Uint8List.fromList(List.filled(80, 7)), 'x'),
        throwsA(isA<VaultException>()),
      );
      await expectLater(
        Backup.encrypt(data, 'short'),
        throwsA(isA<VaultException>()),
      );
    });

    test('restore replaces all data on the device', () async {
      final vault = MemoryVault();
      final app = AppState(vault: vault, sms: FakeSms([]));
      await app.load();
      await app.saveCard(
        name: 'Old',
        issuer: '',
        last4: '9999',
        colorValue: 0,
        defaultRateBps: 100,
        categoryRatesBps: const {},
      );
      final bytes = await Backup.encrypt(
        data,
        'correct horse',
        iterations: 10000,
      );
      await app.restoreBackup(bytes, 'correct horse');
      expect(app.data.cards.single.id, 'c1');
      expect(app.data.primaryCurrency, 'USD');
      expect(vault.stored.toJson(), data.toJson());
    });

    test('default-strength export finishes in reasonable time', () async {
      final app = AppState(
        vault: MemoryVault()..stored = data,
        sms: FakeSms([]),
      );
      await app.load();
      final sw = Stopwatch()..start();
      final bytes = await app.exportBackup('correct horse');
      final back = await Backup.decrypt(bytes, 'correct horse');
      sw.stop();
      // ignore: avoid_print
      print(
        'export + restore at default iterations: ${sw.elapsedMilliseconds} ms',
      );
      expect(back.cards.single.paymentDueDays, 18);
    });
  });
}
