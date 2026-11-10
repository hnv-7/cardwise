import 'package:crypto/crypto.dart';

import 'dart:convert';

import '../models/category.dart';
import '../util/money.dart';
import 'categorizer.dart';

enum ParsedKind { spend, cashbackCredit }

/// The structured result of parsing one message.
class ParsedMessage {
  const ParsedMessage({
    required this.kind,
    required this.amountMinor,
    required this.currency,
    required this.last4,
    required this.merchant,
    required this.category,
    required this.timestamp,
    required this.dedupeKey,
  });

  final ParsedKind kind;
  final int amountMinor;
  final String currency;
  final String? last4;
  final String merchant;
  final SpendCategory category;
  final DateTime timestamp;
  final String dedupeKey;
}

/// Parses credit card transaction alerts. Pure Dart, no I/O, so it is fully
/// unit-testable. Anything that is not clearly a credit card spend or a
/// cashback credit (OTPs, refunds, statements, promotions, debit card or bank
/// account alerts) is rejected by returning null.
class SmsParser {
  SmsParser._();

  static const int maxBodyLength = 1000;

  // ---- classification -----------------------------------------------------

  static final RegExp _cardWord = RegExp(
    r'\b(credit\s*card|card|cc)\b',
    caseSensitive: false,
  );
  static final RegExp _debitCardOnly = RegExp(
    r'\bdebit\s*card\b',
    caseSensitive: false,
  );
  static final RegExp _creditWord = RegExp(
    r'\b(credit\s*card|cc)\b',
    caseSensitive: false,
  );

  static final RegExp _reject = RegExp(
    r'\botp\b|one[\s-]?time\s+password|\bverification code\b|\brefund(ed)?\b|'
    r'\breversed\b|\breversal\b|\bdeclined\b|\bfailed\b|\bunsuccessful\b|'
    r'\bstatement\b|\bbill\s+(is\s+)?generated\b|\bdue\s+(date|on|by)\b|'
    r'\bminimum\s+(amount\s+)?due\b|\bpayment\s+(of\s+.{0,25})?'
    r'(received|credited|successful)|\bthank\s+you\s+for\s+(your\s+)?payment|'
    r'\bpre[\s-]?approved\b|\bapply\s+now\b|\boffer\b.*\bvalid\b|'
    r'\bwill\s+be\s+(debited|charged)\b|\bemi\s+conversion\b',
    caseSensitive: false,
  );

  static final RegExp _spendVerb = RegExp(
    r'\b(spent|purchase|purchased|debited|charge|charged|used|txn|transaction|'
    r'payment|paid|swiped)\b',
    caseSensitive: false,
  );

  static final RegExp _cashbackWord = RegExp(
    r'\bcash\s*back\b',
    caseSensitive: false,
  );
  static final RegExp _cashbackCredited = RegExp(
    r'\b(credited|received|posted|added|earned|reversed to)\b',
    caseSensitive: false,
  );
  static final RegExp _cashbackPromo = RegExp(
    r'\b(will\s+be|to\s+be|get|earn|upto|up\s+to|win|eligible|chance)\b'
    r'[^.]{0,25}cash\s*back',
    caseSensitive: false,
  );

  // ---- amount -------------------------------------------------------------

  static final RegExp _amount = RegExp(
    r'(?<![a-z])(rs\.?|inr|\u20B9|usd|us\$|\$|eur|\u20AC|gbp|\u00A3|aed|sgd|'
    r'aud|cad)\s*(\d[\d,]*(?:\.\d{1,2})?)',
    caseSensitive: false,
  );
  static final RegExp _balanceContext = RegExp(
    r'(avl|avail|available|limit|lmt|bal|balance|outstanding|total\s+due)'
    r'[^0-9]{0,18}$',
    caseSensitive: false,
  );

  static String _currencyCode(String token) {
    switch (token.toLowerCase()) {
      case 'rs':
      case 'rs.':
      case 'inr':
      case '\u20B9':
        return 'INR';
      case 'usd':
      case 'us\$':
      case '\$':
        return 'USD';
      case 'eur':
      case '\u20AC':
        return 'EUR';
      case 'gbp':
      case '\u00A3':
        return 'GBP';
      default:
        return token.toUpperCase();
    }
  }

  // ---- card digits --------------------------------------------------------

  static final RegExp _last4 = RegExp(
    r'(?:[xX*\u2022]{2,}|ending(?:\s+(?:in|with))?|ends\s+with|'
    r'\bno\.?|last\s*4\s*digits?(?:\s*of)?)\s*[xX*\u2022\s]*(\d{4,6})(?!\d)',
    caseSensitive: false,
  );

  // ---- merchant -----------------------------------------------------------

  static const String _stop =
      r'(?=\s+(?:on|using|via|with|for|ref|txn|avl|avail|available|limit|lmt|'
      r'if|not|call|dated|at|upi|info|is|has|was|thank|to\s+dispute|'
      r'block|bal|balance)\b|[.,;(\n]|\s*$)';
  static const String _name = r"([A-Za-z0-9][A-Za-z0-9 &'*_/\-]{1,40}?)";

  static final List<RegExp> _merchantPatterns = [
    // "... on 10-Nov-24 on SWIGGY"
    RegExp(
      r'\bon\s+[\w\-/:]+(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?\s+on\s+' +
          _name +
          _stop,
    ),
    RegExp(r'\bat\s+' + _name + _stop, caseSensitive: false),
    RegExp(r'\btowards\s+' + _name + _stop, caseSensitive: false),
    RegExp(r'\binfo\s*[:\-]\s*' + _name + _stop, caseSensitive: false),
    RegExp(r'@\s*' + _name + _stop),
    RegExp(r'\bmerchant\s*[:\-]?\s*' + _name + _stop, caseSensitive: false),
    RegExp(r'\b(?:paid\s+)?to\s+' + _name + _stop, caseSensitive: false),
  ];

  static final RegExp _timeFragment = RegExp(r'^\d{1,2}:\d{2}');

  static String? _extractMerchant(String body) {
    for (final p in _merchantPatterns) {
      for (final m in p.allMatches(body)) {
        final cleaned = _cleanMerchant(m.group(1)!);
        if (cleaned == null) continue;
        // "at 02:30 PM" is a time, not a merchant.
        if (_timeFragment.hasMatch(cleaned)) continue;
        // A date like "10 November 2024" is not a merchant either.
        if (RegExp(r'^\d{1,2}[\s\-/](?:[A-Za-z]{3,9}|\d{1,2})[\s\-/]\d{2,4}')
            .hasMatch(cleaned)) {
          continue;
        }
        return cleaned;
      }
    }
    return null;
  }

  static String? _cleanMerchant(String raw) {
    var s = raw
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[\s\-*_/&]+$'), '')
        .replaceAll(RegExp(r'^[\s\-*_/]+'), '')
        .trim();
    s = s.replaceAll(
      RegExp(
        r'\b(pvt|private|ltd|limited|llp|inc|india)\.?$',
        caseSensitive: false,
      ),
      '',
    );
    s = s.trim();
    if (s.length < 2) return null;
    if (RegExp(r'^\d+$').hasMatch(s)) return null;
    if (RegExp(
      r'^(your|the|a|an|credit card|card)\b',
      caseSensitive: false,
    ).hasMatch(s)) {
      return null;
    }
    if (s.length > 40) s = s.substring(0, 40).trim();
    // Title-case shouting merchants: "AMAZON PAY" -> "Amazon Pay".
    if (s == s.toUpperCase()) {
      s = s
          .split(' ')
          .map((w) => w.isEmpty ? w : w[0] + w.substring(1).toLowerCase())
          .join(' ');
    }
    return s;
  }

  // ---- date ---------------------------------------------------------------

  static const Map<String, int> _months = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  static const String _timePart =
      r'(?:[\sT:,]+(?:at\s+)?(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([ap]m)?)?';

  static final RegExp _dateIso = RegExp(
    r'\b(20\d{2})-(\d{1,2})-(\d{1,2})' + _timePart,
    caseSensitive: false,
  );
  static final RegExp _dateNamed = RegExp(
    r'\b(\d{1,2})[\s\-/]([A-Za-z]{3,9})[\s\-/,]*(\d{2,4})' + _timePart,
    caseSensitive: false,
  );
  static final RegExp _dateNumeric = RegExp(
    r'\b(\d{1,2})[\-/](\d{1,2})[\-/](\d{2,4})' + _timePart,
    caseSensitive: false,
  );

  static DateTime? _extractDate(String body, DateTime now) {
    DateTime? build(
      int y,
      int mo,
      int d,
      String? hh,
      String? mm,
      String? ss,
      String? ampm,
    ) {
      if (y < 100) y += 2000;
      if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
      var h = int.tryParse(hh ?? '') ?? 0;
      final mi = int.tryParse(mm ?? '') ?? 0;
      final s = int.tryParse(ss ?? '') ?? 0;
      if (ampm != null) {
        final pm = ampm.toLowerCase() == 'pm';
        if (h == 12) h = 0;
        if (pm) h += 12;
      }
      if (h > 23 || mi > 59 || s > 59) return null;
      final dt = DateTime(y, mo, d, h, mi, s);
      // Reject impossible dates that DateTime silently rolls over.
      if (dt.month != mo || dt.day != d) return null;
      // Reject implausible dates (far future / very old).
      if (dt.isAfter(now.add(const Duration(days: 1)))) return null;
      if (dt.isBefore(now.subtract(const Duration(days: 365 * 5)))) {
        return null;
      }
      return dt;
    }

    var m = _dateIso.firstMatch(body);
    if (m != null) {
      final dt = build(
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
        m.group(4),
        m.group(5),
        m.group(6),
        m.group(7),
      );
      if (dt != null) return dt;
    }
    for (final mm in _dateNamed.allMatches(body)) {
      final mo = _months[mm.group(2)!.substring(0, 3).toLowerCase()];
      if (mo == null) continue;
      final dt = build(
        int.parse(mm.group(3)!),
        mo,
        int.parse(mm.group(1)!),
        mm.group(4),
        mm.group(5),
        mm.group(6),
        mm.group(7),
      );
      if (dt != null) return dt;
    }
    m = _dateNumeric.firstMatch(body);
    if (m != null) {
      // Day-first (dd/MM/yy) as used by Indian and most non-US issuers.
      final dt = build(
        int.parse(m.group(3)!),
        int.parse(m.group(2)!),
        int.parse(m.group(1)!),
        m.group(4),
        m.group(5),
        m.group(6),
        m.group(7),
      );
      if (dt != null) return dt;
    }
    return null;
  }

  // ---- public API ---------------------------------------------------------

  /// Stable de-duplication key; the message text itself is never persisted.
  static String messageKey(String body, DateTime received) {
    final normalised = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    final digest = sha256.convert(
      utf8.encode('$normalised|${received.millisecondsSinceEpoch}'),
    );
    return digest.toString();
  }

  /// Returns null when [body] is not a recognised credit card alert.
  /// [received] is the time the message arrived and is used when the body
  /// carries no usable date.
  static ParsedMessage? parse(String body, DateTime received, {DateTime? now}) {
    if (body.trim().isEmpty || body.length > maxBodyLength) return null;
    final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    final clock = now ?? DateTime.now();

    final isCashback =
        _cashbackWord.hasMatch(text) && _cashbackCredited.hasMatch(text);
    if (isCashback && !_cashbackPromo.hasMatch(text)) {
      final cb = _parseCashback(text, received, clock);
      if (cb != null) return cb;
    }

    if (!_cardWord.hasMatch(text)) return null;
    if (_debitCardOnly.hasMatch(text) && !_creditWord.hasMatch(text)) {
      return null;
    }
    if (_reject.hasMatch(text)) return null;
    if (!_spendVerb.hasMatch(text)) return null;

    final amount = _firstSpendAmount(text);
    if (amount == null) return null;

    final merchant = _extractMerchant(text) ?? 'Unknown merchant';
    final when = _extractDate(text, clock) ?? received;
    return ParsedMessage(
      kind: ParsedKind.spend,
      amountMinor: amount.$1,
      currency: amount.$2,
      last4: _extractLast4(text),
      merchant: merchant,
      category: Categorizer.categorize(merchant, text),
      timestamp: when,
      dedupeKey: messageKey(body, received),
    );
  }

  static ParsedMessage? _parseCashback(
    String text,
    DateTime received,
    DateTime clock,
  ) {
    final amount = _firstSpendAmount(text);
    if (amount == null) return null;
    return ParsedMessage(
      kind: ParsedKind.cashbackCredit,
      amountMinor: amount.$1,
      currency: amount.$2,
      last4: _extractLast4(text),
      merchant: 'Cashback',
      category: SpendCategory.other,
      timestamp: _extractDate(text, clock) ?? received,
      dedupeKey: messageKey(text, received),
    );
  }

  static String? _extractLast4(String text) {
    final m = _last4.firstMatch(text);
    if (m == null) return null;
    final digits = m.group(1)!;
    return digits.substring(digits.length - 4);
  }

  /// First monetary amount that is not an available-limit / balance figure.
  static (int, String)? _firstSpendAmount(String text) {
    for (final m in _amount.allMatches(text)) {
      final before = text.substring(m.start > 30 ? m.start - 30 : 0, m.start);
      if (_balanceContext.hasMatch(before)) continue;
      final minor = parseAmountMinor(m.group(2)!);
      if (minor == null) continue;
      return (minor, _currencyCode(m.group(1)!));
    }
    return null;
  }
}
