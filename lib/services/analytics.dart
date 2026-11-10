import '../models/category.dart';
import '../models/models.dart';

class MonthKey implements Comparable<MonthKey> {
  const MonthKey(this.year, this.month);
  factory MonthKey.of(DateTime d) => MonthKey(d.year, d.month);

  final int year;
  final int month;

  DateTime get start => DateTime(year, month);
  MonthKey plus(int months) {
    final idx = year * 12 + (month - 1) + months;
    return MonthKey(idx ~/ 12, idx % 12 + 1);
  }

  @override
  int compareTo(MonthKey other) =>
      (year * 12 + month).compareTo(other.year * 12 + other.month);
  @override
  bool operator ==(Object other) =>
      other is MonthKey && other.year == year && other.month == month;
  @override
  int get hashCode => Object.hash(year, month);
}

/// One billing cycle of a card: [start] inclusive to [end] exclusive.
/// A cycle starts on [billingDay] (1-28) and is identified by the month in
/// which it starts, so with billingDay 15 the cycle "Oct" runs 15 Oct - 14 Nov.
class BillingCycle {
  const BillingCycle._(this.start, this.end, this.billingDay);

  factory BillingCycle.containing(DateTime d, int billingDay) {
    var key = MonthKey.of(d);
    if (d.day < billingDay) key = key.plus(-1);
    return BillingCycle.forKey(key, billingDay);
  }

  factory BillingCycle.forKey(MonthKey key, int billingDay) {
    final next = key.plus(1);
    return BillingCycle._(
      DateTime(key.year, key.month, billingDay),
      DateTime(next.year, next.month, billingDay),
      billingDay,
    );
  }

  final DateTime start;
  final DateTime end;
  final int billingDay;

  MonthKey get key => MonthKey.of(start);

  /// The cycle [n] cycles after this one (negative = earlier).
  BillingCycle plus(int n) => BillingCycle.forKey(key.plus(n), billingDay);

  /// Last day included in the cycle (the statement date).
  DateTime get lastDay => end.subtract(const Duration(days: 1));
}

/// Computes cashback for a single transaction (integer arithmetic, rounds
/// half up).
int rawCashbackMinor(CardProfile card, TxnRecord t) {
  final bps = card.rateFor(t.category);
  return (t.amountMinor * bps + 5000) ~/ 10000;
}

class CashbackSummary {
  const CashbackSummary({
    required this.estimatedMinor,
    required this.creditedMinor,
    required this.perTxn,
    required this.perCategory,
    required this.perCycle,
    required this.cappedCycles,
  });

  /// Estimated cashback after applying the monthly cap.
  final int estimatedMinor;

  /// Cashback actually credited (logged by the user or detected from SMS).
  final int creditedMinor;
  final Map<String, int> perTxn;
  final Map<SpendCategory, int> perCategory;

  /// Cashback per billing cycle, keyed by the month the cycle starts in.
  final Map<MonthKey, int> perCycle;
  final Set<MonthKey> cappedCycles;

  int get pendingMinor =>
      (estimatedMinor - creditedMinor).clamp(0, 1 << 62).toInt();
}

class Analytics {
  Analytics(this.data);

  final VaultData data;

  String get currency => data.primaryCurrency;

  List<TxnRecord> get _inCurrency =>
      data.transactions.where((t) => t.currency == currency).toList();

  /// Transactions not counted in totals because they use another currency.
  int get excludedForeignCount => data.transactions.length - _inCurrency.length;

  List<TxnRecord> transactions({
    String? cardId,
    DateTime? from,
    DateTime? to,
    SpendCategory? category,
    bool onlyPrimaryCurrency = true,
  }) {
    final src = onlyPrimaryCurrency ? _inCurrency : data.transactions;
    final out = src.where((t) {
      if (cardId != null && t.cardId != cardId) return false;
      if (category != null && t.category != category) return false;
      if (from != null && t.timestamp.isBefore(from)) return false;
      if (to != null && !t.timestamp.isBefore(to)) return false;
      return true;
    }).toList()..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }

  int total(List<TxnRecord> txns) =>
      txns.fold(0, (sum, t) => sum + t.amountMinor);

  Map<SpendCategory, int> byCategory(List<TxnRecord> txns) {
    final m = <SpendCategory, int>{};
    for (final t in txns) {
      m[t.category] = (m[t.category] ?? 0) + t.amountMinor;
    }
    return m;
  }

  Map<String?, int> byCard(List<TxnRecord> txns) {
    final m = <String?, int>{};
    for (final t in txns) {
      m[t.cardId] = (m[t.cardId] ?? 0) + t.amountMinor;
    }
    return m;
  }

  int _billingDayOf(String? cardId) {
    for (final c in data.cards) {
      if (c.id == cardId) return c.billingDay;
    }
    return 1; // unassigned transactions follow the calendar month
  }

  BillingCycle _cycleOf(TxnRecord t) =>
      BillingCycle.containing(t.timestamp, _billingDayOf(t.cardId));

  /// Transactions from the current billing cycle (or the last [cycles]
  /// cycles including the current one) of each transaction's own card.
  /// [cycles] null means all time.
  List<TxnRecord> transactionsInCycles(int? cycles, {DateTime? now}) {
    final clock = now ?? DateTime.now();
    return transactions().where((t) {
      if (cycles == null) return true;
      final current = BillingCycle.containing(clock, _billingDayOf(t.cardId));
      return !t.timestamp.isBefore(current.plus(1 - cycles).start);
    }).toList();
  }

  /// Latest cycle key that is current for any card.
  MonthKey _latestCurrentKey(DateTime clock) {
    var latest = MonthKey.of(clock).plus(-1);
    final days = {1, ...data.cards.map((c) => c.billingDay)};
    for (final d in days) {
      final k = BillingCycle.containing(clock, d).key;
      if (k.compareTo(latest) > 0) latest = k;
    }
    return latest;
  }

  /// Spend per billing cycle for the last [cycles] cycles, oldest first,
  /// including empty cycles. Each transaction is bucketed by its own card's
  /// cycle; buckets are labelled by the month the cycle starts in.
  List<(MonthKey, int)> cycleTrend(
    List<TxnRecord> txns, {
    int cycles = 6,
    DateTime? now,
  }) {
    final end = _latestCurrentKey(now ?? DateTime.now());
    final keys = [for (var i = cycles - 1; i >= 0; i--) end.plus(-i)];
    final sums = {for (final k in keys) k: 0};
    for (final t in txns) {
      final k = _cycleOf(t).key;
      if (sums.containsKey(k)) sums[k] = sums[k]! + t.amountMinor;
    }
    return [for (final k in keys) (k, sums[k]!)];
  }

  /// Cashback for one card. Applies per-category rates and the per-cycle cap
  /// chronologically, so the cap is consumed by the earliest purchases.
  CashbackSummary cashbackFor(CardProfile card) {
    final txns = _inCurrency.where((t) => t.cardId == card.id).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final perTxn = <String, int>{};
    final perCat = <SpendCategory, int>{};
    final perCycle = <MonthKey, int>{};
    final capped = <MonthKey>{};
    var total = 0;
    for (final t in txns) {
      final k = BillingCycle.containing(t.timestamp, card.billingDay).key;
      var cb = rawCashbackMinor(card, t);
      final cap = card.cycleCapMinor;
      if (cap != null) {
        final room = cap - (perCycle[k] ?? 0);
        if (cb > room) {
          cb = room < 0 ? 0 : room;
          capped.add(k);
        }
      }
      perTxn[t.id] = cb;
      perCat[t.category] = (perCat[t.category] ?? 0) + cb;
      perCycle[k] = (perCycle[k] ?? 0) + cb;
      total += cb;
    }
    final credited = data.credits
        .where((c) => c.cardId == card.id && c.currency == currency)
        .fold<int>(0, (s, c) => s + c.amountMinor);
    return CashbackSummary(
      estimatedMinor: total,
      creditedMinor: credited,
      perTxn: perTxn,
      perCategory: perCat,
      perCycle: perCycle,
      cappedCycles: capped,
    );
  }

  /// Cumulative estimated cashback by billing cycle for the last [cycles]
  /// cycles, across the given cards (all cards when null).
  List<(MonthKey, int)> cashbackAccumulation({
    Iterable<CardProfile>? cards,
    int cycles = 6,
    DateTime? now,
  }) {
    final selected = (cards ?? data.cards).toList();
    final end = _latestCurrentKey(now ?? DateTime.now());
    final keys = [for (var i = cycles - 1; i >= 0; i--) end.plus(-i)];
    final perCycle = <MonthKey, int>{};
    for (final c in selected) {
      cashbackFor(c).perCycle.forEach((k, v) {
        perCycle[k] = (perCycle[k] ?? 0) + v;
      });
    }
    // Start from everything earned before the window so the line is a true
    // running total.
    var running = 0;
    perCycle.forEach((k, v) {
      if (k.compareTo(keys.first) < 0) running += v;
    });
    final out = <(MonthKey, int)>[];
    for (final k in keys) {
      running += perCycle[k] ?? 0;
      out.add((k, running));
    }
    return out;
  }

  int totalEstimatedCashback() =>
      data.cards.fold(0, (s, c) => s + cashbackFor(c).estimatedMinor);

  int totalCreditedCashback() =>
      data.cards.fold(0, (s, c) => s + cashbackFor(c).creditedMinor);
}
