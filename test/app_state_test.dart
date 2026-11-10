import 'package:cc_app/models/category.dart';
import 'package:cc_app/models/models.dart';
import 'package:cc_app/services/analytics.dart';
import 'package:cc_app/services/categorizer.dart';
import 'package:cc_app/services/sms_source.dart';
import 'package:cc_app/services/vault.dart';
import 'package:cc_app/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryVault implements VaultStore {
  VaultData stored = const VaultData();
  bool failSave = false;
  @override
  Future<VaultData> load() async => stored;
  @override
  Future<void> save(VaultData data) async {
    if (failSave) throw VaultException('disk full');
    stored = data;
  }

  @override
  Future<void> wipe() async => stored = const VaultData();
}

class FakeSms implements SmsSource {
  FakeSms(this.messages, {this.supported = true});
  List<RawSms> messages;
  bool supported;
  DateTime? lastSince;
  @override
  bool get isSupported => supported;
  @override
  Future<SmsAccess> status() async => SmsAccess.granted;
  @override
  Future<SmsAccess> request() async => SmsAccess.granted;
  @override
  Future<void> openSettings() async {}
  @override
  Future<List<RawSms>> readInbox({
    required DateTime since,
    int limit = 0,
  }) async {
    lastSince = since;
    return messages;
  }
}

void main() {
  final now = DateTime(2024, 11, 15, 12);
  final t1 = DateTime(2024, 11, 10, 9);

  RawSms sms(String body, [DateTime? at]) => RawSms(body, at ?? t1);

  late MemoryVault vault;
  late FakeSms source;
  late AppState app;

  Future<void> addCard({
    String last4 = '4321',
    int base = 100,
    int? cap,
    int day = 1,
  }) => app.saveCard(
    name: 'Test',
    issuer: 'Bank',
    last4: last4,
    colorValue: 0xFF000000,
    defaultRateBps: base,
    categoryRatesBps: {SpendCategory.dining: 500},
    cycleCapMinor: cap,
    billingDay: day,
  );

  setUp(() async {
    vault = MemoryVault();
    source = FakeSms([
      sms(
        'Rs.1,000.00 spent on HDFC Bank Credit Card XX4321 at SWIGGY on '
        '09-11-2024:19:45:10. Avl Lmt: Rs.85,000.00',
      ),
      sms(
        'Rs 2,000.00 spent on your SBI Credit Card ending 9999 at '
        'BIG BASKET on 08/11/24.',
        DateTime(2024, 11, 8),
      ),
      sms('Your OTP is 123456'),
    ]);
    app = AppState(vault: vault, sms: source);
    await app.load();
  });

  group('scan', () {
    test('imports card alerts and links by last four', () async {
      await addCard();
      final r = await app.scanInbox(now: now);
      expect(r.scanned, 3);
      expect(r.added, 2);
      expect(r.unlinked, 1);
      final linked = app.data.transactions.where((t) => t.cardId != null);
      expect(linked.length, 1);
      expect(linked.first.amountMinor, 100000);
      expect(linked.first.category, SpendCategory.dining);
    });

    test('is idempotent', () async {
      await app.scanInbox(now: now);
      final r = await app.scanInbox(now: now);
      expect(r.added, 0);
      expect(r.duplicates, 2);
      expect(app.data.transactions.length, 2);
    });

    test('first scan looks back 90 days, later scans from last scan', () async {
      await app.scanInbox(now: now);
      expect(source.lastSince, now.subtract(const Duration(days: 90)));
      await app.scanInbox(now: now.add(const Duration(days: 3)));
      expect(source.lastSince, now.subtract(const Duration(days: 1)));
    });

    test('adding a card later links earlier unassigned transactions', () async {
      await app.scanInbox(now: now);
      expect(app.data.transactions.every((t) => t.cardId == null), isTrue);
      await addCard(last4: '9999');
      final linked = app.data.transactions.where((t) => t.cardId != null);
      expect(linked.length, 1);
      expect(linked.first.amountMinor, 200000);
    });

    test('persists to the vault', () async {
      await app.scanInbox(now: now);
      expect(vault.stored.transactions.length, 2);
      expect(vault.stored.transactions.first.dedupeKey, isNotNull);
    });

    test('pasted import is idempotent and splits on blank lines', () async {
      const text =
          'Rs 100 spent on Credit Card XX1111 at CAFE COFFEE DAY on '
          '10-11-2024.\n\nRs 200 spent on Credit Card XX1111 at UBER on '
          '10-11-2024.';
      final r1 = await app.importPasted(text, now: now);
      expect(r1.added, 2);
      final r2 = await app.importPasted(text, now: now);
      expect(r2.added, 0);
      expect(r2.duplicates, 2);
    });

    test('failed save rolls back state', () async {
      vault.failSave = true;
      await expectLater(
        app.scanInbox(now: now),
        throwsA(isA<VaultException>()),
      );
      expect(app.data.transactions, isEmpty);
      expect(app.scanning, isFalse);
    });
  });

  group('validation', () {
    test('rejects bad cards', () async {
      await expectLater(
        app.saveCard(
          name: '',
          issuer: '',
          last4: '1234',
          colorValue: 0,
          defaultRateBps: 100,
          categoryRatesBps: {},
        ),
        throwsA(isA<VaultException>()),
      );
      await expectLater(
        app.saveCard(
          name: 'X',
          issuer: '',
          last4: '12',
          colorValue: 0,
          defaultRateBps: 100,
          categoryRatesBps: {},
        ),
        throwsA(isA<VaultException>()),
      );
      await expectLater(
        app.saveCard(
          name: 'X',
          issuer: '',
          last4: '1234',
          colorValue: 0,
          defaultRateBps: 20000,
          categoryRatesBps: {},
        ),
        throwsA(isA<VaultException>()),
      );
    });

    test('rejects duplicate last4', () async {
      await addCard();
      await expectLater(addCard(), throwsA(isA<VaultException>()));
    });

    test('rejects bad transactions', () async {
      Future<void> save(int? amt, String merchant, DateTime when) =>
          app.saveTransaction(
            cardId: null,
            amountMinor: amt,
            currency: 'INR',
            merchant: merchant,
            category: SpendCategory.other,
            timestamp: when,
          );
      await expectLater(
        save(null, 'A', DateTime(2020)),
        throwsA(isA<VaultException>()),
      );
      await expectLater(
        save(100, ' ', DateTime(2020)),
        throwsA(isA<VaultException>()),
      );
      await expectLater(
        save(100, 'A', DateTime.now().add(const Duration(days: 2))),
        throwsA(isA<VaultException>()),
      );
      await save(100, 'A', DateTime(2020));
      expect(app.data.transactions.length, 1);
    });

    test('deleting a card keeps transactions unassigned', () async {
      await addCard();
      await app.scanInbox(now: now);
      await app.deleteCard(app.data.cards.first.id);
      expect(app.data.cards, isEmpty);
      expect(app.data.transactions.length, 2);
      expect(app.data.transactions.every((t) => t.cardId == null), isTrue);
    });
  });

  group('analytics', () {
    TxnRecord txn(
      String id,
      String cardId,
      int amt,
      SpendCategory c,
      DateTime d, {
      String currency = 'INR',
    }) => TxnRecord(
      id: id,
      cardId: cardId,
      cardLast4Hint: null,
      amountMinor: amt,
      currency: currency,
      merchant: 'm',
      category: c,
      timestamp: d,
      source: TxnSource.manual,
      dedupeKey: null,
    );

    CardProfile card({int? cap, int day = 1}) => CardProfile(
      id: 'c1',
      name: 'C',
      issuer: '',
      last4: '1111',
      colorValue: 0,
      defaultRateBps: 100, // 1%
      categoryRatesBps: {SpendCategory.dining: 500}, // 5%
      cycleCapMinor: cap,
      billingDay: day,

      createdAt: DateTime(2024),
    );

    test('category rate overrides base rate and rounds half up', () {
      final c = card();
      expect(
        rawCashbackMinor(c, txn('a', 'c1', 100000, SpendCategory.dining, t1)),
        5000,
      );
      expect(
        rawCashbackMinor(c, txn('a', 'c1', 100000, SpendCategory.travel, t1)),
        1000,
      );
      expect(
        rawCashbackMinor(c, txn('a', 'c1', 50, SpendCategory.travel, t1)),
        1,
      );
      expect(
        rawCashbackMinor(c, txn('a', 'c1', 49, SpendCategory.travel, t1)),
        0,
      );
    });

    test('cap applies chronologically per calendar-month cycle', () {
      final c = card(cap: 6000);
      final data = VaultData(
        cards: [c],
        transactions: [
          txn(
            '1',
            'c1',
            100000,
            SpendCategory.dining,
            DateTime(2024, 10, 1),
          ), // 5000
          txn(
            '2',
            'c1',
            100000,
            SpendCategory.dining,
            DateTime(2024, 10, 2),
          ), // 5000 -> 1000
          txn(
            '3',
            'c1',
            100000,
            SpendCategory.dining,
            DateTime(2024, 11, 1),
          ), // 5000
        ],
      );
      final s = Analytics(data).cashbackFor(c);
      expect(s.perTxn['1'], 5000);
      expect(s.perTxn['2'], 1000);
      expect(s.perTxn['3'], 5000);
      expect(s.estimatedMinor, 11000);
      expect(s.cappedCycles, {const MonthKey(2024, 10)});
    });

    test('credited and pending', () {
      final c = card();
      final data = VaultData(
        cards: [c],
        transactions: [txn('1', 'c1', 100000, SpendCategory.dining, t1)],
        credits: [
          CashbackCredit(
            id: 'x',
            cardId: 'c1',
            cardLast4Hint: null,
            amountMinor: 2000,
            currency: 'INR',
            date: t1,
            dedupeKey: null,
          ),
        ],
      );
      final s = Analytics(data).cashbackFor(c);
      expect(s.creditedMinor, 2000);
      expect(s.pendingMinor, 3000);
    });

    test('other-currency transactions are excluded from totals', () {
      final c = card();
      final data = VaultData(
        cards: [c],
        transactions: [
          txn('1', 'c1', 100000, SpendCategory.dining, t1),
          txn('2', 'c1', 999900, SpendCategory.dining, t1, currency: 'USD'),
        ],
      );
      final a = Analytics(data);
      expect(a.total(a.transactions()), 100000);
      expect(a.excludedForeignCount, 1);
      expect(a.cashbackFor(c).estimatedMinor, 5000);
    });

    test('cycle trend includes empty months, oldest first', () {
      final data = VaultData(
        transactions: [
          txn('1', 'c1', 100, SpendCategory.other, DateTime(2024, 11, 3)),
          txn('2', 'c1', 300, SpendCategory.other, DateTime(2024, 9, 3)),
        ],
      );
      final a = Analytics(data);
      final trend = a.cycleTrend(a.transactions(), cycles: 4, now: now);
      expect(trend.map((e) => e.$1), [
        const MonthKey(2024, 8),
        const MonthKey(2024, 9),
        const MonthKey(2024, 10),
        const MonthKey(2024, 11),
      ]);
      expect(trend.map((e) => e.$2), [0, 300, 0, 100]);
    });

    test('cycle trend crosses year boundary', () {
      final trend = Analytics(const VaultData())
          .cycleTrend([], cycles: 3, now: DateTime(2025, 1, 10));
      expect(trend.map((e) => e.$1), [
        const MonthKey(2024, 11),
        const MonthKey(2024, 12),
        const MonthKey(2025, 1),
      ]);
    });

    test('cashback accumulation is a running total', () {
      final c = card();
      final data = VaultData(
        cards: [c],
        transactions: [
          txn(
            '0',
            'c1',
            100000,
            SpendCategory.travel,
            DateTime(2024, 5, 1),
          ), // 1000 before window
          txn(
            '1',
            'c1',
            100000,
            SpendCategory.travel,
            DateTime(2024, 10, 1),
          ), // 1000
          txn(
            '2',
            'c1',
            100000,
            SpendCategory.dining,
            DateTime(2024, 11, 1),
          ), // 5000
        ],
      );
      final acc = Analytics(data).cashbackAccumulation(cycles: 3, now: now);
      expect(acc.map((e) => e.$2), [1000, 2000, 7000]);
    });
  });

  group('billing cycles', () {
    TxnRecord txn(String id, int amt, DateTime d, {String? cardId = 'c1'}) =>
        TxnRecord(
          id: id,
          cardId: cardId,
          cardLast4Hint: null,
          amountMinor: amt,
          currency: 'INR',
          merchant: 'm',
          category: SpendCategory.dining, // 5%
          timestamp: d,
          source: TxnSource.manual,
          dedupeKey: null,
        );

    CardProfile card(int day, {int? cap}) => CardProfile(
      id: 'c1',
      name: 'C',
      issuer: '',
      last4: '1111',
      colorValue: 0,
      defaultRateBps: 100,
      categoryRatesBps: {SpendCategory.dining: 500},
      cycleCapMinor: cap,
      billingDay: day,
      createdAt: DateTime(2024),
    );

    test('cycle bounds', () {
      final c = BillingCycle.containing(DateTime(2024, 11, 10), 15);
      expect(c.start, DateTime(2024, 10, 15));
      expect(c.end, DateTime(2024, 11, 15));
      expect(c.lastDay, DateTime(2024, 11, 14));
      final d = BillingCycle.containing(DateTime(2024, 11, 15), 15);
      expect(d.start, DateTime(2024, 11, 15));
      expect(d.plus(-1).start, DateTime(2024, 10, 15));
      expect(d.plus(1).start, DateTime(2024, 12, 15));
    });

    test('cycle crosses year boundary', () {
      final c = BillingCycle.containing(DateTime(2025, 1, 3), 20);
      expect(c.start, DateTime(2024, 12, 20));
      expect(c.end, DateTime(2025, 1, 20));
    });

    test('day 1 equals calendar month', () {
      final c = BillingCycle.containing(DateTime(2024, 2, 29, 23, 59), 1);
      expect(c.start, DateTime(2024, 2, 1));
      expect(c.end, DateTime(2024, 3, 1));
    });

    group('period summaries', () {
      // Billing day 15, now 20 Nov -> current cycle 15 Nov-14 Dec,
      // last cycle 15 Oct-14 Nov, cycle before that 15 Sep-14 Oct.
      // Dining earns 5% with a 6000 cap per cycle.
      final now = DateTime(2024, 11, 20);
      final data = VaultData(
        cards: [card(15, cap: 6000)],
        transactions: [
          txn('s', 100000, DateTime(2024, 9, 20)), // Sep cycle: 5000 cb
          txn('a', 100000, DateTime(2024, 10, 14)), // Sep cycle: 1000 cb (cap)
          txn('b', 100000, DateTime(2024, 10, 15)), // Oct cycle: 5000 cb
          txn('c', 100000, DateTime(2024, 11, 14, 23)), // Oct cycle: 1000 cb
          txn('d', 100000, DateTime(2024, 11, 15)), // Nov (current): 5000 cb
          txn('e', 100000, DateTime(2024, 11, 1), cardId: null), // unassigned
        ],
      );
      CycleSummary one(int? cycles, {int endAgo = 0}) =>
          Analytics(data)
              .periodSummaries(cycles, now: now, endAgo: endAgo)
              .single;

      test('this cycle', () {
        final s = one(1);
        expect(s.from, DateTime(2024, 11, 15));
        expect(s.lastDay, DateTime(2024, 12, 14));
        expect(s.spendMinor, 100000);
        expect(s.cashbackMinor, 5000);
      });

      test('last cycle is the previous completed cycle only', () {
        final s = one(1, endAgo: 1);
        expect(s.from, DateTime(2024, 10, 15));
        expect(s.lastDay, DateTime(2024, 11, 14));
        expect(s.spendMinor, 200000);
        expect(s.cashbackMinor, 6000); // 5000 + 1000, cap reached
      });

      test('3 cycles includes the current one', () {
        final s = one(3);
        expect(s.from, DateTime(2024, 9, 15));
        expect(s.spendMinor, 500000);
        expect(s.cashbackMinor, 17000); // 6000 + 6000 + 5000
      });

      test('all time', () {
        final s = one(null);
        expect(s.from, isNull);
        expect(s.spendMinor, 500000);
        expect(s.cashbackMinor, 17000);
      });
    });

    test('transactionsInCycles last cycle excludes the current cycle', () {
      final data = VaultData(
        cards: [card(15)],
        transactions: [
          txn('old', 100, DateTime(2024, 10, 14)),
          txn('last', 100, DateTime(2024, 10, 20)),
          txn('cur', 100, DateTime(2024, 11, 16)),
        ],
      );
      final ids = Analytics(data)
          .transactionsInCycles(1, now: DateTime(2024, 11, 20), endAgo: 1)
          .map((t) => t.id);
      expect(ids, ['last']);
    });

    test('cap resets on the billing day, not the 1st', () {
      // Cycle starts on the 15th, cap 6000 (= 60.00).
      final c = card(15, cap: 6000);
      final data = VaultData(
        cards: [c],
        transactions: [
          txn('a', 100000, DateTime(2024, 10, 20)), // cycle Oct: 5000
          txn(
            'b',
            100000,
            DateTime(2024, 11, 10),
          ), // still Oct cycle: capped to 1000
          txn('c', 100000, DateTime(2024, 11, 16)), // new cycle Nov: 5000
        ],
      );
      final s = Analytics(data).cashbackFor(c);
      expect(s.perTxn['a'], 5000);
      expect(s.perTxn['b'], 1000);
      expect(s.perTxn['c'], 5000);
      expect(s.perCycle[const MonthKey(2024, 10)], 6000);
      expect(s.perCycle[const MonthKey(2024, 11)], 5000);
      expect(s.cappedCycles, {const MonthKey(2024, 10)});
    });

    test(
      'same transactions with calendar months would not be capped the same',
      () {
        final data = VaultData(
          cards: [card(1, cap: 6000)],
          transactions: [
            txn('a', 100000, DateTime(2024, 10, 20)),
            txn('b', 100000, DateTime(2024, 11, 10)),
          ],
        );
        final s = Analytics(data).cashbackFor(data.cards.first);
        expect(s.estimatedMinor, 10000); // one per month, nothing capped
      },
    );

    test('transactionsInCycles uses each card\'s own cycle', () {
      final cardA = card(15);
      final cardB = CardProfile(
        id: 'c2',
        name: 'B',
        issuer: '',
        last4: '2222',
        colorValue: 0,
        defaultRateBps: 100,
        categoryRatesBps: const {},
        cycleCapMinor: null,
        billingDay: 1,
        createdAt: DateTime(2024),
      );
      final data = VaultData(
        cards: [cardA, cardB],
        transactions: [
          txn(
            'a1',
            100,
            DateTime(2024, 11, 10),
          ), // A: in current cycle (from 15 Oct)
          txn('a2', 100, DateTime(2024, 10, 14)), // A: previous cycle
          txn('b1', 100, DateTime(2024, 11, 2), cardId: 'c2'), // B: current
          txn('b2', 100, DateTime(2024, 10, 31), cardId: 'c2'), // B: previous
        ],
      );
      final ids = Analytics(data)
          .transactionsInCycles(1, now: DateTime(2024, 11, 12))
          .map((t) => t.id)
          .toSet();
      expect(ids, {'a1', 'b1'});
      final two = Analytics(data)
          .transactionsInCycles(2, now: DateTime(2024, 11, 12))
          .map((t) => t.id)
          .toSet();
      expect(two, {'a1', 'a2', 'b1', 'b2'});
    });

    test('legacy JSON without billingDay loads as calendar month', () {
      final card = CardProfile.fromJson({
        'id': 'x',
        'name': 'Old',
        'last4': '1234',
        'color': 1,
        'defaultRateBps': 100,
        'categoryRatesBps': <String, Object?>{},
        'monthlyCapMinor': 7000,
        'createdAt': 0,
      });
      expect(card.billingDay, 1);
      expect(card.cycleCapMinor, 7000);
    });

    test('invalid stored billing day falls back to 1', () {
      final card = CardProfile.fromJson({
        'id': 'x',
        'name': 'Bad',
        'last4': '1234',
        'color': 1,
        'billingDay': 99,
        'createdAt': 0,
      });
      expect(card.billingDay, 1);
    });

    test('billing day validation', () async {
      await expectLater(addCard(day: 0), throwsA(isA<VaultException>()));
      await expectLater(addCard(day: 29), throwsA(isA<VaultException>()));
      await addCard(day: 28);
      expect(app.data.cards.single.billingDay, 28);
    });
  });

  group('persistence model', () {
    test('json round trip', () {
      final data = VaultData(
        cards: [
          CardProfile(
            id: 'c',
            name: 'N',
            issuer: 'I',
            last4: '1234',
            colorValue: 5,
            defaultRateBps: 150,
            categoryRatesBps: {SpendCategory.fuel: 300},
            cycleCapMinor: 50000,
            billingDay: 17,
            createdAt: DateTime(2024, 1, 1),
          ),
        ],
        transactions: [
          TxnRecord(
            id: 't',
            cardId: 'c',
            cardLast4Hint: '1234',
            amountMinor: 123,
            currency: 'USD',
            merchant: 'M',
            category: SpendCategory.travel,
            timestamp: DateTime(2024, 2, 2, 3, 4),
            source: TxnSource.sms,
            dedupeKey: 'k',
          ),
        ],
        primaryCurrency: 'USD',
        lastScanMillis: 42,
      );
      final back = VaultData.fromJson(data.toJson());
      expect(back.cards.single.categoryRatesBps[SpendCategory.fuel], 300);
      expect(back.cards.single.cycleCapMinor, 50000);
      expect(back.cards.single.billingDay, 17);
      expect(back.transactions.single.timestamp, DateTime(2024, 2, 2, 3, 4));
      expect(back.transactions.single.source, TxnSource.sms);
      expect(back.primaryCurrency, 'USD');
      expect(back.lastScanMillis, 42);
    });

    test('merchant categories round trip and default to empty', () {
      final data = VaultData(
        merchantCategories: {'xyz stores': SpendCategory.dining},
      );
      final back = VaultData.fromJson(data.toJson());
      expect(back.merchantCategories['xyz stores'], SpendCategory.dining);
      expect(VaultData.fromJson({}).merchantCategories, isEmpty);
    });
  });

  group('merchant category memory', () {
    test('merchantKey normalizes case, punctuation and store numbers', () {
      expect(Categorizer.merchantKey('XYZ Stores #123'), 'xyz stores');
      expect(Categorizer.merchantKey('  xyz-stores  0042'), 'xyz stores');
    });

    test(
      'editing a category applies to later scans of the same merchant',
      () async {
        await addCard();
        await app.scanInbox(now: now);
        bool isSwiggy(TxnRecord t) => t.merchant.toLowerCase() == 'swiggy';
        final swiggy = app.data.transactions.firstWhere(isSwiggy);
        expect(swiggy.category, SpendCategory.dining);

        await app.saveTransaction(
          id: swiggy.id,
          cardId: swiggy.cardId,
          amountMinor: swiggy.amountMinor,
          currency: swiggy.currency,
          merchant: swiggy.merchant,
          category: SpendCategory.groceries,
          timestamp: swiggy.timestamp,
        );
        expect(app.data.merchantCategories['swiggy'], SpendCategory.groceries);
        expect(
          vault.stored.merchantCategories['swiggy'],
          SpendCategory.groceries,
        );

        source.messages = [
          sms(
            'Rs.250.00 spent on HDFC Bank Credit Card XX4321 at SWIGGY on '
            '12-11-2024:10:00:00.',
          ),
        ];
        await app.scanInbox(now: now);
        final latest = app.data.transactions.where(isSwiggy).toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        expect(latest.length, 2);
        expect(latest.last.category, SpendCategory.groceries);
      },
    );

    test(
      'editing also re-categorizes existing transactions of that merchant',
      () async {
        Future<void> add(String m, SpendCategory c) => app.saveTransaction(
          cardId: null,
          amountMinor: 100,
          currency: 'INR',
          merchant: m,
          category: c,
          timestamp: t1,
        );
        await add('Corner Cafe', SpendCategory.dining);
        await add('Corner Cafe 22', SpendCategory.dining);
        final first = app.data.transactions.first;
        await app.saveTransaction(
          id: first.id,
          cardId: null,
          amountMinor: 100,
          currency: 'INR',
          merchant: 'Corner Cafe',
          category: SpendCategory.shopping,
          timestamp: t1,
        );
        expect(
          app.data.transactions.map((t) => t.category),
          everyElement(SpendCategory.shopping),
        );
      },
    );

    test('unchanged category does not create an override', () async {
      await app.saveTransaction(
        cardId: null,
        amountMinor: 100,
        currency: 'INR',
        merchant: 'Swiggy',
        category: SpendCategory.dining,
        timestamp: t1,
      );
      expect(app.data.merchantCategories, isEmpty);
    });

    test('learnedCategory matches whole-word prefixes only', () {
      final learned = {'xyz': SpendCategory.health};
      expect(
        Categorizer.learnedCategory(learned, 'XYZ Bangalore'),
        SpendCategory.health,
      );
      expect(Categorizer.learnedCategory(learned, 'XYZA Stores'), isNull);
    });
  });

  group('unlinked transactions', () {
    test('filter lists only unlinked and bulk assign links them', () async {
      await addCard();
      await app.scanInbox(now: now);
      final unlinked = app.analytics.transactions(
        unlinkedOnly: true,
        onlyPrimaryCurrency: false,
      );
      expect(unlinked.length, 1);
      expect(unlinked.single.cardId, isNull);

      final other = app.data.cards.single;
      await app.assignCardToMany(unlinked.map((t) => t.id), other.id);
      expect(
        app.analytics.transactions(
          unlinkedOnly: true,
          onlyPrimaryCurrency: false,
        ),
        isEmpty,
      );
      expect(app.data.transactions.every((t) => t.cardId == other.id), isTrue);
    });

    test('bulk assign rejects an unknown card', () async {
      await app.scanInbox(now: now);
      expect(
        () => app.assignCardToMany(
          app.data.transactions.map((t) => t.id),
          'missing',
        ),
        throwsA(isA<VaultException>()),
      );
    });
  });
}
