import 'package:cc_app/util/money.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseAmountMinor', () {
    test('valid inputs', () {
      expect(parseAmountMinor('1,234.5'), 123450);
      expect(parseAmountMinor('10'), 1000);
      expect(parseAmountMinor('0.99'), 99);
      expect(parseAmountMinor(' 42.05 '), 4205);
    });
    test('invalid inputs', () {
      for (final s in ['', 'abc', '-5', '0', '0.00', '1.234', '1e5', '1..2']) {
        expect(parseAmountMinor(s), isNull, reason: s);
      }
    });
    test('upper bound', () {
      expect(parseAmountMinor('999999999999'), isNull);
    });
  });
}
