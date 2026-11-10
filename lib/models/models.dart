import 'category.dart';

enum TxnSource { sms, pasted, manual }

/// A credit card profile with its cashback configuration.
class CardProfile {
  const CardProfile({
    required this.id,
    required this.name,
    required this.issuer,
    required this.last4,
    required this.colorValue,
    required this.defaultRateBps,
    required this.categoryRatesBps,
    required this.cycleCapMinor,
    required this.billingDay,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String issuer;
  final String last4;
  final int colorValue;

  /// Default cashback rate in basis points (100 bps = 1%).
  final int defaultRateBps;

  /// Per-category overrides in basis points.
  final Map<SpendCategory, int> categoryRatesBps;

  /// Max cashback per billing cycle in minor units; null = uncapped.
  final int? cycleCapMinor;

  /// Day of the month (1-28) on which each billing cycle starts, i.e. the day
  /// after the statement date. 1 means the cycle follows the calendar month.
  final int billingDay;
  final DateTime createdAt;

  int rateFor(SpendCategory c) => categoryRatesBps[c] ?? defaultRateBps;

  String get displayName => '$name \u2022\u2022$last4';

  CardProfile copyWith({
    String? name,
    String? issuer,
    String? last4,
    int? colorValue,
    int? defaultRateBps,
    Map<SpendCategory, int>? categoryRatesBps,
    int? cycleCapMinor,
    int? billingDay,
    bool clearCap = false,
  }) => CardProfile(
    id: id,
    name: name ?? this.name,
    issuer: issuer ?? this.issuer,
    last4: last4 ?? this.last4,
    colorValue: colorValue ?? this.colorValue,
    defaultRateBps: defaultRateBps ?? this.defaultRateBps,
    categoryRatesBps: categoryRatesBps ?? this.categoryRatesBps,
    cycleCapMinor: clearCap ? null : (cycleCapMinor ?? this.cycleCapMinor),
    billingDay: billingDay ?? this.billingDay,
    createdAt: createdAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'issuer': issuer,
    'last4': last4,
    'color': colorValue,
    'defaultRateBps': defaultRateBps,
    'categoryRatesBps': categoryRatesBps.map((k, v) => MapEntry(k.name, v)),
    'cycleCapMinor': cycleCapMinor,
    'billingDay': billingDay,
    'createdAt': createdAt.millisecondsSinceEpoch,
  };

  factory CardProfile.fromJson(Map<String, Object?> j) {
    final rates = <SpendCategory, int>{};
    final raw = j['categoryRatesBps'];
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is int) rates[SpendCategory.fromName(k as String?)] = v;
      });
    }
    return CardProfile(
      id: j['id']! as String,
      name: j['name']! as String,
      issuer: (j['issuer'] as String?) ?? '',
      last4: j['last4']! as String,
      colorValue: j['color']! as int,
      defaultRateBps: (j['defaultRateBps'] as int?) ?? 0,
      categoryRatesBps: rates,
      // 'monthlyCapMinor' is the key used before billing cycles existed.
      cycleCapMinor: (j['cycleCapMinor'] ?? j['monthlyCapMinor']) as int?,
      billingDay: (() {
        final d = j['billingDay'];
        return d is int && d >= 1 && d <= 28 ? d : 1;
      })(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(j['createdAt']! as int),
    );
  }
}

/// A single card transaction.
class TxnRecord {
  const TxnRecord({
    required this.id,
    required this.cardId,
    required this.cardLast4Hint,
    required this.amountMinor,
    required this.currency,
    required this.merchant,
    required this.category,
    required this.timestamp,
    required this.source,
    required this.dedupeKey,
  });

  final String id;

  /// Null while the transaction is not linked to a card profile.
  final String? cardId;

  /// Last four digits extracted from the message; used to link the
  /// transaction once a matching card is added.
  final String? cardLast4Hint;
  final int amountMinor;
  final String currency;
  final String merchant;
  final SpendCategory category;
  final DateTime timestamp;
  final TxnSource source;

  /// SHA-256 of the originating message; the message itself is never stored.
  final String? dedupeKey;

  TxnRecord copyWith({
    String? cardId,
    bool clearCard = false,
    int? amountMinor,
    String? currency,
    String? merchant,
    SpendCategory? category,
    DateTime? timestamp,
  }) => TxnRecord(
    id: id,
    cardId: clearCard ? null : (cardId ?? this.cardId),
    cardLast4Hint: cardLast4Hint,
    amountMinor: amountMinor ?? this.amountMinor,
    currency: currency ?? this.currency,
    merchant: merchant ?? this.merchant,
    category: category ?? this.category,
    timestamp: timestamp ?? this.timestamp,
    source: source,
    dedupeKey: dedupeKey,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'cardId': cardId,
    'cardLast4Hint': cardLast4Hint,
    'amountMinor': amountMinor,
    'currency': currency,
    'merchant': merchant,
    'category': category.name,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'source': source.name,
    'dedupeKey': dedupeKey,
  };

  factory TxnRecord.fromJson(Map<String, Object?> j) => TxnRecord(
    id: j['id']! as String,
    cardId: j['cardId'] as String?,
    cardLast4Hint: j['cardLast4Hint'] as String?,
    amountMinor: j['amountMinor']! as int,
    currency: (j['currency'] as String?) ?? 'INR',
    merchant: (j['merchant'] as String?) ?? 'Unknown merchant',
    category: SpendCategory.fromName(j['category'] as String?),
    timestamp: DateTime.fromMillisecondsSinceEpoch(j['timestamp']! as int),
    source: TxnSource.values.firstWhere(
      (s) => s.name == j['source'],
      orElse: () => TxnSource.manual,
    ),
    dedupeKey: j['dedupeKey'] as String?,
  );
}

/// Cashback actually credited by the issuer (logged manually or detected
/// from a "cashback credited" message).
class CashbackCredit {
  const CashbackCredit({
    required this.id,
    required this.cardId,
    required this.cardLast4Hint,
    required this.amountMinor,
    required this.currency,
    required this.date,
    required this.dedupeKey,
  });

  final String id;
  final String? cardId;
  final String? cardLast4Hint;
  final int amountMinor;
  final String currency;
  final DateTime date;
  final String? dedupeKey;

  CashbackCredit withCard(String? newCardId) => CashbackCredit(
    id: id,
    cardId: newCardId,
    cardLast4Hint: cardLast4Hint,
    amountMinor: amountMinor,
    currency: currency,
    date: date,
    dedupeKey: dedupeKey,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'cardId': cardId,
    'cardLast4Hint': cardLast4Hint,
    'amountMinor': amountMinor,
    'currency': currency,
    'date': date.millisecondsSinceEpoch,
    'dedupeKey': dedupeKey,
  };

  factory CashbackCredit.fromJson(Map<String, Object?> j) => CashbackCredit(
    id: j['id']! as String,
    cardId: j['cardId'] as String?,
    cardLast4Hint: j['cardLast4Hint'] as String?,
    amountMinor: j['amountMinor']! as int,
    currency: (j['currency'] as String?) ?? 'INR',
    date: DateTime.fromMillisecondsSinceEpoch(j['date']! as int),
    dedupeKey: j['dedupeKey'] as String?,
  );
}

/// Everything persisted by the app.
class VaultData {
  const VaultData({
    this.cards = const [],
    this.transactions = const [],
    this.credits = const [],
    this.primaryCurrency = 'INR',
    this.lastScanMillis,
    this.merchantCategories = const {},
  });

  final List<CardProfile> cards;
  final List<TxnRecord> transactions;
  final List<CashbackCredit> credits;
  final String primaryCurrency;
  final int? lastScanMillis;

  /// Categories the user chose by hand, keyed by normalized merchant name
  /// (see `Categorizer.merchantKey`). Takes priority over keyword rules.
  final Map<String, SpendCategory> merchantCategories;

  Map<String, Object?> toJson() => {
    'version': 1,
    'cards': cards.map((c) => c.toJson()).toList(),
    'transactions': transactions.map((t) => t.toJson()).toList(),
    'credits': credits.map((c) => c.toJson()).toList(),
    'primaryCurrency': primaryCurrency,
    'lastScanMillis': lastScanMillis,
    'merchantCategories': merchantCategories.map((k, v) => MapEntry(k, v.name)),
  };

  factory VaultData.fromJson(Map<String, Object?> j) {
    List<T> list<T>(String key, T Function(Map<String, Object?>) f) =>
        ((j[key] as List?) ?? const [])
            .map((e) => f(Map<String, Object?>.from(e as Map)))
            .toList();
    final learned = <String, SpendCategory>{};
    final rawLearned = j['merchantCategories'];
    if (rawLearned is Map) {
      rawLearned.forEach((k, v) {
        if (k is String && v is String) {
          learned[k] = SpendCategory.fromName(v);
        }
      });
    }
    return VaultData(
      cards: list('cards', CardProfile.fromJson),
      transactions: list('transactions', TxnRecord.fromJson),
      credits: list('credits', CashbackCredit.fromJson),
      primaryCurrency: (j['primaryCurrency'] as String?) ?? 'INR',
      lastScanMillis: j['lastScanMillis'] as int?,
      merchantCategories: learned,
    );
  }
}
