import 'package:intl/intl.dart';

/// A currency the app can track. Amounts are always stored as integer minor
/// units (e.g. paise / cents) to avoid floating point rounding errors.
class Currency {
  const Currency(this.code, this.symbol, this.name);

  final String code;
  final String symbol;
  final String name;
}

const List<Currency> supportedCurrencies = [
  Currency('INR', '\u20B9', 'Indian Rupee'),
  Currency('USD', '\$', 'US Dollar'),
  Currency('EUR', '\u20AC', 'Euro'),
  Currency('GBP', '\u00A3', 'Pound Sterling'),
  Currency('AED', 'AED ', 'UAE Dirham'),
  Currency('SGD', 'S\$', 'Singapore Dollar'),
  Currency('AUD', 'A\$', 'Australian Dollar'),
  Currency('CAD', 'C\$', 'Canadian Dollar'),
];

const String defaultCurrencyCode = 'INR';

Currency currencyFor(String code) => supportedCurrencies.firstWhere(
  (c) => c.code == code,
  orElse: () => supportedCurrencies.first,
);

/// Largest amount accepted (in minor units); guards against overflow and
/// obviously corrupt input.
const int maxAmountMinor = 100000000000; // 1 billion major units

/// Parses a decimal string such as `1,234.50` into minor units (123450).
/// Returns null when the text is not a valid positive amount.
int? parseAmountMinor(String input) {
  final cleaned = input.trim().replaceAll(',', '');
  final match = RegExp(r'^(\d{1,12})(?:\.(\d{1,2}))?$').firstMatch(cleaned);
  if (match == null) return null;
  final whole = int.parse(match.group(1)!);
  final fraction = (match.group(2) ?? '').padRight(2, '0');
  final minor = whole * 100 + int.parse(fraction.isEmpty ? '0' : fraction);
  if (minor <= 0 || minor > maxAmountMinor) return null;
  return minor;
}

String _localeFor(String code) => code == 'INR' ? 'en_IN' : 'en_US';

String formatMinor(int minor, String currencyCode) {
  final c = currencyFor(currencyCode);
  return NumberFormat.currency(
    locale: _localeFor(c.code),
    symbol: c.symbol,
    decimalDigits: 2,
  ).format(minor / 100);
}

/// Short form for chart axes, e.g. 12.5K.
String formatMinorCompact(int minor, String currencyCode) {
  final c = currencyFor(currencyCode);
  return NumberFormat.compactCurrency(
    locale: _localeFor(c.code),
    symbol: c.symbol.trim(),
    decimalDigits: 1,
  ).format(minor / 100);
}

String formatMinorPlain(int minor) => (minor / 100).toStringAsFixed(2);
