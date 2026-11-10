import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/category.dart';
import '../models/models.dart';
import '../services/analytics.dart';
import '../services/sms_parser.dart';
import '../services/sms_source.dart';
import '../services/categorizer.dart';
import '../services/vault.dart';
import '../util/money.dart';

class ScanResult {
  const ScanResult({
    required this.scanned,
    required this.added,
    required this.duplicates,
    required this.cashbackCredits,
    required this.unlinked,
  });

  final int scanned;
  final int added;
  final int duplicates;
  final int cashbackCredits;

  /// Added transactions that match none of the user's cards.
  final int unlinked;
}

class AppState extends ChangeNotifier {
  AppState({required this._vault, required this._sms});

  final VaultStore _vault;
  final SmsSource _sms;

  VaultData _data = const VaultData();
  VaultData get data => _data;
  Analytics get analytics => Analytics(_data);

  bool _loaded = false;
  bool get loaded => _loaded;

  /// Set when the vault could not be read; the UI offers a reset.
  String? loadError;

  bool _scanning = false;
  bool get scanning => _scanning;

  SmsSource get sms => _sms;

  static const int firstScanDays = 90;
  static const int maxCards = 30;
  static const int maxTransactions = 20000;
  static const int maxMerchantLength = 60;

  final _rng = Random.secure();
  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${_rng.nextInt(1 << 32).toRadixString(36)}';

  // ---- lifecycle ----------------------------------------------------------

  Future<void> load() async {
    try {
      _data = await _vault.load();
      loadError = null;
    } on VaultException catch (e) {
      loadError = e.message;
    } catch (_) {
      loadError = 'Stored data could not be read.';
    }
    _loaded = true;
    notifyListeners();
  }

  /// Deletes all data and the encryption key.
  Future<void> resetAll() async {
    await _vault.wipe();
    _data = const VaultData();
    loadError = null;
    notifyListeners();
  }

  Future<void> _commit(VaultData next) async {
    final previous = _data;
    _data = next;
    notifyListeners();
    try {
      await _vault.save(next);
    } catch (_) {
      _data = previous;
      notifyListeners();
      throw VaultException('Could not save your data. Please try again.');
    }
  }

  // ---- settings -----------------------------------------------------------

  Future<void> setPrimaryCurrency(String code) => _commit(
    VaultData(
      cards: _data.cards,
      transactions: _data.transactions,
      credits: _data.credits,
      primaryCurrency: currencyFor(code).code,
      lastScanMillis: _data.lastScanMillis,
      merchantCategories: _data.merchantCategories,
    ),
  );

  VaultData _with({
    List<CardProfile>? cards,
    List<TxnRecord>? transactions,
    List<CashbackCredit>? credits,
    int? lastScanMillis,
    Map<String, SpendCategory>? merchantCategories,
  }) => VaultData(
    cards: cards ?? _data.cards,
    transactions: transactions ?? _data.transactions,
    credits: credits ?? _data.credits,
    primaryCurrency: _data.primaryCurrency,
    lastScanMillis: lastScanMillis ?? _data.lastScanMillis,
    merchantCategories: merchantCategories ?? _data.merchantCategories,
  );

  // ---- cards --------------------------------------------------------------

  static final RegExp _last4Re = RegExp(r'^\d{4}$');

  /// Validates card input; returns an error message or null.
  String? validateCard({
    required String name,
    required String last4,
    required int defaultRateBps,
    required Map<SpendCategory, int> categoryRatesBps,
    int? cycleCapMinor,
    int billingDay = 1,
    String? editingId,
  }) {
    if (name.trim().isEmpty) return 'Enter a card name.';
    if (name.trim().length > 40) return 'Card name is too long.';
    if (!_last4Re.hasMatch(last4)) {
      return 'Enter the last 4 digits of the card.';
    }
    final dup = _data.cards.any((c) => c.last4 == last4 && c.id != editingId);
    if (dup) return 'A card ending in $last4 already exists.';
    bool badRate(int r) => r < 0 || r > 10000;
    if (badRate(defaultRateBps) || categoryRatesBps.values.any(badRate)) {
      return 'Cashback rates must be between 0% and 100%.';
    }
    if (billingDay < 1 || billingDay > 28) {
      return 'Billing cycle start day must be between 1 and 28.';
    }
    if (cycleCapMinor != null && cycleCapMinor <= 0) {
      return 'Cashback cap must be greater than zero.';
    }
    if (editingId == null && _data.cards.length >= maxCards) {
      return 'You can track up to $maxCards cards.';
    }
    return null;
  }

  Future<void> saveCard({
    String? id,
    required String name,
    required String issuer,
    required String last4,
    required int colorValue,
    required int defaultRateBps,
    required Map<SpendCategory, int> categoryRatesBps,
    int? cycleCapMinor,
    int billingDay = 1,
  }) async {
    final error = validateCard(
      name: name,
      last4: last4,
      defaultRateBps: defaultRateBps,
      categoryRatesBps: categoryRatesBps,
      cycleCapMinor: cycleCapMinor,
      billingDay: billingDay,
      editingId: id,
    );
    if (error != null) throw VaultException(error);

    final card = CardProfile(
      id: id ?? _newId(),
      name: name.trim(),
      issuer: issuer.trim(),
      last4: last4,
      colorValue: colorValue,
      defaultRateBps: defaultRateBps,
      categoryRatesBps: Map.of(categoryRatesBps),
      cycleCapMinor: cycleCapMinor,
      billingDay: billingDay,
      createdAt: id == null
          ? DateTime.now()
          : _data.cards.firstWhere((c) => c.id == id).createdAt,
    );
    final cards = id == null
        ? [..._data.cards, card]
        : [for (final c in _data.cards) c.id == id ? card : c];

    // Link previously unassigned transactions whose digits match this card.
    final txns = [
      for (final t in _data.transactions)
        t.cardId == null && t.cardLast4Hint == last4
            ? t.copyWith(cardId: card.id)
            : t,
    ];
    final credits = [
      for (final c in _data.credits)
        c.cardId == null && c.cardLast4Hint == last4 ? c.withCard(card.id) : c,
    ];
    await _commit(_with(cards: cards, transactions: txns, credits: credits));
  }

  /// Removes a card. Its transactions are kept but become unassigned.
  Future<void> deleteCard(String id) => _commit(
    _with(
      cards: _data.cards.where((c) => c.id != id).toList(),
      transactions: [
        for (final t in _data.transactions)
          t.cardId == id ? t.copyWith(clearCard: true) : t,
      ],
      credits: [
        for (final c in _data.credits) c.cardId == id ? c.withCard(null) : c,
      ],
    ),
  );

  CardProfile? cardById(String? id) {
    if (id == null) return null;
    for (final c in _data.cards) {
      if (c.id == id) return c;
    }
    return null;
  }

  String? _cardIdForLast4(String? last4) {
    if (last4 == null) return null;
    for (final c in _data.cards) {
      if (c.last4 == last4) return c.id;
    }
    return null;
  }

  // ---- transactions -------------------------------------------------------

  String? validateTransaction({
    required int? amountMinor,
    required String merchant,
    required DateTime timestamp,
  }) {
    if (amountMinor == null) return 'Enter a valid amount (e.g. 1250.50).';
    if (merchant.trim().isEmpty) return 'Enter a merchant name.';
    if (merchant.trim().length > maxMerchantLength) {
      return 'Merchant name is too long.';
    }
    if (timestamp.isAfter(DateTime.now().add(const Duration(minutes: 5)))) {
      return 'Date cannot be in the future.';
    }
    if (timestamp.year < 2000) return 'Date is too far in the past.';
    return null;
  }

  Future<void> saveTransaction({
    String? id,
    required String? cardId,
    required int? amountMinor,
    required String currency,
    required String merchant,
    required SpendCategory category,
    required DateTime timestamp,
  }) async {
    final error = validateTransaction(
      amountMinor: amountMinor,
      merchant: merchant,
      timestamp: timestamp,
    );
    if (error != null) throw VaultException(error);
    if (cardId != null && cardById(cardId) == null) {
      throw VaultException('Selected card no longer exists.');
    }
    if (id == null && _data.transactions.length >= maxTransactions) {
      throw VaultException('Transaction limit reached.');
    }
    if (id == null) {
      final t = TxnRecord(
        id: _newId(),
        cardId: cardId,
        cardLast4Hint: null,
        amountMinor: amountMinor!,
        currency: currency,
        merchant: merchant.trim(),
        category: category,
        timestamp: timestamp,
        source: TxnSource.manual,
        dedupeKey: null,
      );
      // A manually added transaction whose category differs from the automatic
      // guess is treated as a correction and remembered.
      final key = Categorizer.merchantKey(merchant);
      final auto =
          Categorizer.learnedCategory(_data.merchantCategories, merchant) ??
          Categorizer.categorize(merchant);
      await _commit(
        _with(
          transactions: [..._data.transactions, t],
          merchantCategories: key.isNotEmpty && auto != category
              ? {..._data.merchantCategories, key: category}
              : null,
        ),
      );
    } else {
      final old = _data.transactions.where((t) => t.id == id).firstOrNull;
      // Remember a manual category change so future transactions from the
      // same merchant (and earlier ones) follow it.
      final key = Categorizer.merchantKey(merchant);
      final learn = old != null && old.category != category && key.isNotEmpty;
      final learned = learn
          ? {..._data.merchantCategories, key: category}
          : null;
      await _commit(
        _with(
          transactions: [
            for (final t in _data.transactions)
              t.id == id
                  ? t.copyWith(
                      cardId: cardId,
                      clearCard: cardId == null,
                      amountMinor: amountMinor,
                      currency: currency,
                      merchant: merchant.trim(),
                      category: category,
                      timestamp: timestamp,
                    )
                  : (learn && Categorizer.merchantKey(t.merchant) == key)
                  ? t.copyWith(category: category)
                  : t,
          ],
          merchantCategories: learned,
        ),
      );
    }
  }

  Future<void> deleteTransaction(String id) => _commit(
    _with(transactions: _data.transactions.where((t) => t.id != id).toList()),
  );

  /// Links many transactions to [cardId] in a single save.
  Future<void> assignCardToMany(Iterable<String> txnIds, String cardId) {
    if (cardById(cardId) == null) {
      throw VaultException('Selected card no longer exists.');
    }
    final ids = txnIds.toSet();
    return _commit(
      _with(
        transactions: [
          for (final t in _data.transactions)
            ids.contains(t.id) ? t.copyWith(cardId: cardId) : t,
        ],
      ),
    );
  }

  Future<void> assignCard(String txnId, String? cardId) => _commit(
    _with(
      transactions: [
        for (final t in _data.transactions)
          t.id == txnId
              ? t.copyWith(cardId: cardId, clearCard: cardId == null)
              : t,
      ],
    ),
  );

  // ---- cashback credits ---------------------------------------------------

  Future<void> addCashbackCredit({
    required String cardId,
    required int? amountMinor,
    required DateTime date,
  }) async {
    if (amountMinor == null) {
      throw VaultException('Enter a valid cashback amount.');
    }
    if (cardById(cardId) == null) {
      throw VaultException('Selected card no longer exists.');
    }
    if (date.isAfter(DateTime.now().add(const Duration(minutes: 5)))) {
      throw VaultException('Date cannot be in the future.');
    }
    final credit = CashbackCredit(
      id: _newId(),
      cardId: cardId,
      cardLast4Hint: null,
      amountMinor: amountMinor,
      currency: _data.primaryCurrency,
      date: date,
      dedupeKey: null,
    );
    await _commit(_with(credits: [..._data.credits, credit]));
  }

  Future<void> deleteCashbackCredit(String id) =>
      _commit(_with(credits: _data.credits.where((c) => c.id != id).toList()));

  // ---- scanning -----------------------------------------------------------

  /// Reads the inbox (Android) and imports new card alerts.
  Future<ScanResult> scanInbox({DateTime? now}) async {
    if (_scanning) throw VaultException('A scan is already running.');
    _scanning = true;
    notifyListeners();
    try {
      final clock = now ?? DateTime.now();
      final last = _data.lastScanMillis;
      // Overlap by a day on incremental scans; dedupe prevents double counting.
      final since = last == null
          ? clock.subtract(const Duration(days: firstScanDays))
          : DateTime.fromMillisecondsSinceEpoch(last)
                .subtract(const Duration(days: 1));
      final messages = await _sms.readInbox(since: since, limit: 5000);
      final result = await _import(messages, TxnSource.sms, clock);
      await _commit(_with(lastScanMillis: clock.millisecondsSinceEpoch));
      return result;
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }

  /// Imports text the user pasted (iOS cannot read SMS).
  /// Messages are separated by blank lines.
  Future<ScanResult> importPasted(String text, {DateTime? now}) {
    final clock = now ?? DateTime.now();
    final chunks = text
        .split(RegExp(r'\n\s*\n'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .take(500)
        .toList();
    return _import(
      [for (final c in chunks) RawSms(c, clock)],
      TxnSource.pasted,
      clock,
    );
  }

  Future<ScanResult> _import(
    List<RawSms> messages,
    TxnSource source,
    DateTime clock,
  ) async {
    final seen = <String>{
      for (final t in _data.transactions)
        if (t.dedupeKey != null) t.dedupeKey!,
      for (final c in _data.credits)
        if (c.dedupeKey != null) c.dedupeKey!,
    };
    // Pasted text has no real receive time, so key on the parsed content
    // instead of the paste moment to make re-pasting idempotent.
    final newTxns = <TxnRecord>[];
    final newCredits = <CashbackCredit>[];
    var dupes = 0;
    var unlinked = 0;
    final budget = maxTransactions - _data.transactions.length;

    for (final m in messages) {
      final p = SmsParser.parse(m.body, m.received, now: clock);
      if (p == null) continue;
      final key = source == TxnSource.pasted
          ? SmsParser.messageKey(m.body, DateTime.fromMillisecondsSinceEpoch(0))
          : p.dedupeKey;
      if (!seen.add(key)) {
        dupes++;
        continue;
      }
      final cardId = _cardIdForLast4(p.last4);
      if (p.kind == ParsedKind.cashbackCredit) {
        newCredits.add(
          CashbackCredit(
            id: _newId(),
            cardId: cardId,
            cardLast4Hint: p.last4,
            amountMinor: p.amountMinor,
            currency: p.currency,
            date: p.timestamp,
            dedupeKey: key,
          ),
        );
      } else {
        if (newTxns.length >= budget) break;
        if (cardId == null) unlinked++;
        newTxns.add(
          TxnRecord(
            id: _newId(),
            cardId: cardId,
            cardLast4Hint: p.last4,
            amountMinor: p.amountMinor,
            currency: p.currency,
            merchant: p.merchant,
            category:
                Categorizer.learnedCategory(
                  _data.merchantCategories,
                  p.merchant,
                ) ??
                p.category,
            timestamp: p.timestamp,
            source: source,
            dedupeKey: key,
          ),
        );
      }
    }

    if (newTxns.isNotEmpty || newCredits.isNotEmpty) {
      await _commit(
        _with(
          transactions: [..._data.transactions, ...newTxns],
          credits: [..._data.credits, ...newCredits],
        ),
      );
    }
    return ScanResult(
      scanned: messages.length,
      added: newTxns.length,
      duplicates: dupes,
      cashbackCredits: newCredits.length,
      unlinked: unlinked,
    );
  }
}
