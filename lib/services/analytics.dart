import 'dart:math' as math;

import '../models/category.dart';
import '../models/models.dart';
import 'categorizer.dart';

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

/// The merchant rate of [card] that applies to [merchant], if any. A keyword
/// matches when it starts a word of the normalized merchant name, so
/// "amazon" covers "Amazon Pay" and "AMAZONPAYINDIA".
MerchantRate? merchantRateFor(CardProfile card, String merchant) {
  if (card.merchantRates.isEmpty) return null;
  final key = ' ${Categorizer.merchantKey(merchant)}';
  for (final m in card.merchantRates) {
    final kw = Categorizer.merchantKey(m.keyword);
    if (kw.isNotEmpty && key.contains(' $kw')) return m;
  }
  return null;
}

/// Rate in basis points for a purchase: a merchant rate first, then the
/// category rate, then the base rate.
int rateBpsFor(CardProfile card, String merchant, SpendCategory category) =>
    merchantRateFor(card, merchant)?.bps ?? card.rateFor(category);

/// Cap bucket a purchase counts against: its merchant rule, else its category.
String capBucket(MerchantRate? rule, SpendCategory category) =>
    rule != null ? 'm:${rule.keyword}' : 'c:${category.name}';

/// Computes cashback for a single transaction before caps (integer
/// arithmetic, rounds half up). Always positive, also for refunds.
int rawCashbackMinor(CardProfile card, TxnRecord t) {
  final bps = rateBpsFor(card, t.merchant, t.category);
  return (t.amountMinor * bps + 5000) ~/ 10000;
}

/// Whether [t] matches a search [query]: merchant, category or card name
/// text, or an amount starting with the typed digits ("1250" finds 1,250.50).
bool matchesSearch(TxnRecord t, String query, {CardProfile? card}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  if (t.merchant.toLowerCase().contains(q)) return true;
  if (t.category.label.toLowerCase().contains(q)) return true;
  if (card != null && card.name.toLowerCase().contains(q)) return true;
  if (t.isRefund && 'refund'.startsWith(q)) return true;
  final digits = q.replaceAll(',', '');
  if (RegExp(r'^\d+(\.\d{0,2})?$').hasMatch(digits)) {
    final major = (t.amountMinor / 100).toStringAsFixed(2);
    if (major.startsWith(digits)) return true;
  }
  return false;
}

class CashbackSummary {
  const CashbackSummary({
    required this.estimatedMinor,
    required this.creditedMinor,
    required this.perTxn,
    required this.perCategory,
    required this.perCycle,
    required this.cappedCycles,
    this.bucketUse = const {},
    this.cappedBuckets = const {},
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

  /// Cashback earned per cap bucket (see [capBucket]) in each cycle.
  final Map<MonthKey, Map<String, int>> bucketUse;

  /// Buckets whose own cap was reached in each cycle.
  final Map<MonthKey, Set<String>> cappedBuckets;

  int usedIn(MonthKey cycle, String bucket) => bucketUse[cycle]?[bucket] ?? 0;

  int get pendingMinor =>
      (estimatedMinor - creditedMinor).clamp(0, 1 << 62).toInt();
}

/// One card's spend and estimated cashback over a window of billing cycles.
class CycleSummary {
  const CycleSummary({
    required this.card,
    required this.from,
    required this.lastDay,
    required this.spendMinor,
    required this.cashbackMinor,
  });

  final CardProfile card;

  /// First day of the window; null for all time.
  final DateTime? from;

  /// Last day (statement date) of the newest cycle in the window.
  final DateTime lastDay;
  final int spendMinor;
  final int cashbackMinor;
}

/// A ranked suggestion of which card to use for a purchase.
class CardPick {
  const CardPick({
    required this.card,
    required this.bps,
    required this.rule,
    required this.expectedMinor,
    required this.roomMinor,
  });

  final CardProfile card;
  final int bps;

  /// The merchant rate that applied, if any.
  final MerchantRate? rule;

  /// Cashback the purchase would earn now, after this cycle's caps.
  final int expectedMinor;

  /// Smallest remaining cap room this cycle; null when uncapped.
  final int? roomMinor;

  bool get capReached => roomMinor == 0;
}

/// A statement whose payment is still coming up.
class PaymentDue {
  const PaymentDue({
    required this.card,
    required this.statement,
    required this.dueDate,
    required this.amountMinor,
  });

  final CardProfile card;

  /// The completed billing cycle the statement covers.
  final BillingCycle statement;
  final DateTime dueDate;

  /// Net spend in the statement cycle (an estimate of the bill).
  final int amountMinor;

  String get key =>
      VaultData.statementKey(card.id, statement.key.year, statement.key.month);

  /// Whole days from [now] to the due date (0 = due today).
  int daysLeft(DateTime now) => DateTime.utc(
    dueDate.year,
    dueDate.month,
    dueDate.day,
  ).difference(DateTime.utc(now.year, now.month, now.day)).inDays;
}

/// Latest known credit limit position of a card.
class CreditUsage {
  const CreditUsage({
    required this.limitMinor,
    required this.availableMinor,
    required this.asOf,
  });

  final int? limitMinor;
  final int availableMinor;
  final DateTime asOf;

  int? get usedMinor => limitMinor == null
      ? null
      : (limitMinor! - availableMinor).clamp(0, limitMinor!).toInt();

  /// Share of the limit in use (0-1); null without a limit.
  double? get ratio =>
      limitMinor == null || limitMinor == 0 ? null : usedMinor! / limitMinor!;
}

/// Read-only calculations over one [VaultData] snapshot. Results that are
/// costly to compute are cached, so keep one instance per snapshot.
class Analytics {
  Analytics(this.data);

  final VaultData data;

  String get currency => data.primaryCurrency;

  late final List<TxnRecord> _inCurrency = data.transactions
      .where((t) => t.currency == currency)
      .toList();

  late final Map<String, int> _billingDays = {
    for (final c in data.cards) c.id: c.billingDay,
  };

  final Map<String, CashbackSummary> _cashback = {};

  /// Transactions not counted in totals because they use another currency.
  int get excludedForeignCount => data.transactions.length - _inCurrency.length;

  List<TxnRecord> transactions({
    String? cardId,
    bool unlinkedOnly = false,
    DateTime? from,
    DateTime? to,
    SpendCategory? category,
    bool onlyPrimaryCurrency = true,
  }) {
    final src = onlyPrimaryCurrency ? _inCurrency : data.transactions;
    final out = src.where((t) {
      if (cardId != null && t.cardId != cardId) return false;
      if (unlinkedOnly && t.cardId != null) return false;
      if (category != null && t.category != category) return false;
      if (from != null && t.timestamp.isBefore(from)) return false;
      if (to != null && !t.timestamp.isBefore(to)) return false;
      return true;
    }).toList()..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }

  /// Net total: refunds are subtracted.
  int total(List<TxnRecord> txns) =>
      txns.fold(0, (sum, t) => sum + t.signedMinor);

  Map<SpendCategory, int> byCategory(List<TxnRecord> txns) {
    final m = <SpendCategory, int>{};
    for (final t in txns) {
      m[t.category] = (m[t.category] ?? 0) + t.signedMinor;
    }
    return m;
  }

  Map<String?, int> byCard(List<TxnRecord> txns) {
    final m = <String?, int>{};
    for (final t in txns) {
      m[t.cardId] = (m[t.cardId] ?? 0) + t.signedMinor;
    }
    return m;
  }

  // Unassigned transactions follow the calendar month.
  int _billingDayOf(String? cardId) => _billingDays[cardId] ?? 1;

  BillingCycle _cycleOf(TxnRecord t) =>
      BillingCycle.containing(t.timestamp, _billingDayOf(t.cardId));

  /// Transactions from [cycles] billing cycles of each transaction's own
  /// card, ending [endAgo] cycles before the current one (0 = the window ends
  /// with the current cycle, 1 = it ends with the last completed cycle).
  /// [cycles] null means all time.
  List<TxnRecord> transactionsInCycles(
    int? cycles, {
    DateTime? now,
    int endAgo = 0,
  }) {
    final clock = now ?? DateTime.now();
    return transactions().where((t) {
      if (cycles == null) return true;
      final current = BillingCycle.containing(clock, _billingDayOf(t.cardId));
      if (t.timestamp.isBefore(current.plus(1 - cycles - endAgo).start)) {
        return false;
      }
      return endAgo == 0 ||
          t.timestamp.isBefore(current.plus(1 - endAgo).start);
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
      if (sums.containsKey(k)) sums[k] = sums[k]! + t.signedMinor;
    }
    return [for (final k in keys) (k, math.max(0, sums[k]!))];
  }

  /// Cashback for one card, cached per snapshot. Applies merchant, category
  /// and base rates, then the merchant or category cap and the card's cycle
  /// cap, chronologically, so caps are consumed by the earliest purchases.
  /// A refund takes back the cashback its amount would earn, from the cycle
  /// it lands in, without taking that cycle below zero.
  CashbackSummary cashbackFor(CardProfile card) =>
      _cashback[card.id] ??= _computeCashback(card);

  CashbackSummary _computeCashback(CardProfile card) {
    final txns = _inCurrency.where((t) => t.cardId == card.id).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final perTxn = <String, int>{};
    final perCat = <SpendCategory, int>{};
    final perCycle = <MonthKey, int>{};
    final capped = <MonthKey>{};
    final buckets = <MonthKey, Map<String, int>>{};
    final cappedBuckets = <MonthKey, Set<String>>{};
    var total = 0;
    for (final t in txns) {
      final k = BillingCycle.containing(t.timestamp, card.billingDay).key;
      final rule = merchantRateFor(card, t.merchant);
      final bucket = capBucket(rule, t.category);
      final use = buckets.putIfAbsent(k, () => {});
      final used = use[bucket] ?? 0;
      final raw = rawCashbackMinor(card, t);
      int cb;
      if (t.isRefund) {
        final back = math.min(raw, math.max(0, perCycle[k] ?? 0));
        cb = -back;
        use[bucket] = math.max(0, used - back);
      } else {
        cb = raw;
        final bucketCap = rule != null
            ? rule.capMinor
            : card.categoryCapsMinor[t.category];
        if (bucketCap != null && cb > bucketCap - used) {
          cb = math.max(0, bucketCap - used);
          cappedBuckets.putIfAbsent(k, () => {}).add(bucket);
        }
        final cap = card.cycleCapMinor;
        if (cap != null) {
          final room = cap - (perCycle[k] ?? 0);
          if (cb > room) {
            cb = room < 0 ? 0 : room;
            capped.add(k);
          }
        }
        use[bucket] = used + cb;
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
      bucketUse: buckets,
      cappedBuckets: cappedBuckets,
    );
  }

  /// Cards ranked by the cashback a purchase of [amountMinor] in [category]
  /// (at [merchant], when given) would earn right now, after what is left of
  /// this cycle's caps. Ties go to the higher rate.
  List<CardPick> bestCards({
    required SpendCategory category,
    String merchant = '',
    required int amountMinor,
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    final picks = <CardPick>[];
    for (final card in data.cards) {
      final rule = merchant.trim().isEmpty
          ? null
          : merchantRateFor(card, merchant);
      final bps = rule?.bps ?? card.rateFor(category);
      final raw = (amountMinor * bps + 5000) ~/ 10000;
      final k = BillingCycle.containing(clock, card.billingDay).key;
      final s = cashbackFor(card);
      final rooms = <int>[];
      final bucketCap = rule != null
          ? rule.capMinor
          : card.categoryCapsMinor[category];
      if (bucketCap != null) {
        rooms.add(bucketCap - s.usedIn(k, capBucket(rule, category)));
      }
      final cap = card.cycleCapMinor;
      if (cap != null) rooms.add(cap - (s.perCycle[k] ?? 0));
      final room = rooms.isEmpty ? null : math.max(0, rooms.reduce(math.min));
      picks.add(
        CardPick(
          card: card,
          bps: bps,
          rule: rule,
          expectedMinor: room == null ? raw : math.min(raw, room),
          roomMinor: room,
        ),
      );
    }
    picks.sort((a, b) {
      final byCash = b.expectedMinor.compareTo(a.expectedMinor);
      if (byCash != 0) return byCash;
      final byRate = b.bps.compareTo(a.bps);
      return byRate != 0 ? byRate : a.card.name.compareTo(b.card.name);
    });
    return picks;
  }

  /// Unpaid statements whose due date is today or later, soonest first.
  /// Only cards with a payment due day set are included.
  List<PaymentDue> upcomingPayments({DateTime? now}) {
    final clock = now ?? DateTime.now();
    final today = DateTime(clock.year, clock.month, clock.day);
    final out = <PaymentDue>[];
    for (final card in data.cards) {
      final days = card.paymentDueDays;
      if (days == null) continue;
      final stmt = BillingCycle.containing(clock, card.billingDay).plus(-1);
      final last = stmt.lastDay;
      final due = DateTime(last.year, last.month, last.day + days);
      if (due.isBefore(today)) continue;
      final amount = total(
        transactions(cardId: card.id, from: stmt.start, to: stmt.end),
      );
      if (amount <= 0) continue;
      final p = PaymentDue(
        card: card,
        statement: stmt,
        dueDate: due,
        amountMinor: amount,
      );
      if (data.paidStatements.contains(p.key)) continue;
      out.add(p);
    }
    out.sort((a, b) => a.dueDate.compareTo(b.dueDate));
    return out;
  }

  /// Available limit from the newest alert that reported one, with the
  /// card's credit limit when set; null when no alert carried a figure.
  CreditUsage? creditUsage(CardProfile card) {
    TxnRecord? latest;
    for (final t in data.transactions) {
      if (t.cardId != card.id || t.availableLimitMinor == null) continue;
      if (latest == null || t.timestamp.isAfter(latest.timestamp)) latest = t;
    }
    if (latest == null) return null;
    return CreditUsage(
      limitMinor: card.creditLimitMinor,
      availableMinor: latest.availableLimitMinor!,
      asOf: latest.timestamp,
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

  /// Spend and estimated cashback of each card over [cycles] of its own
  /// billing cycles ending [endAgo] cycles before the current one.
  /// [cycles] null means all time.
  List<CycleSummary> periodSummaries(
    int? cycles, {
    DateTime? now,
    int endAgo = 0,
  }) {
    final clock = now ?? DateTime.now();
    return [
      for (final card in data.cards)
        () {
          final current = BillingCycle.containing(clock, card.billingDay);
          final newest = current.plus(-endAgo);
          final oldest = cycles == null
              ? null
              : current.plus(1 - cycles - endAgo);
          final summary = cashbackFor(card);
          final spend = _inCurrency
              .where(
                (t) =>
                    t.cardId == card.id &&
                    (oldest == null || !t.timestamp.isBefore(oldest.start)) &&
                    (endAgo == 0 || t.timestamp.isBefore(newest.end)),
              )
              .fold<int>(0, (s, t) => s + t.signedMinor);
          var cashback = 0;
          summary.perCycle.forEach((k, v) {
            final inWindow =
                (oldest == null || k.compareTo(oldest.key) >= 0) &&
                (endAgo == 0 || k.compareTo(newest.key) <= 0);
            if (inWindow) cashback += v;
          });
          return CycleSummary(
            card: card,
            from: oldest?.start,
            lastDay: newest.lastDay,
            spendMinor: spend,
            cashbackMinor: cashback,
          );
        }(),
    ];
  }

  int totalEstimatedCashback() =>
      data.cards.fold(0, (s, c) => s + cashbackFor(c).estimatedMinor);

  int totalCreditedCashback() =>
      data.cards.fold(0, (s, c) => s + cashbackFor(c).creditedMinor);
}
