import 'package:cc_app/models/category.dart';
import 'package:cc_app/services/categorizer.dart';
import 'package:cc_app/services/sms_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final received = DateTime(2024, 11, 10, 9, 0);
  final now = DateTime(2024, 11, 11);

  ParsedMessage? parse(String s) => SmsParser.parse(s, received, now: now);

  group('spend alerts', () {
    test('HDFC style', () {
      final p = parse(
        'Rs.1,250.50 spent on HDFC Bank Credit Card XX4321 at SWIGGY on '
        '09-11-2024:19:45:10. Avl Lmt: Rs.85,000.00. Not you? Call 1800',
      );
      expect(p, isNotNull);
      expect(p!.kind, ParsedKind.spend);
      expect(p.amountMinor, 125050);
      expect(p.currency, 'INR');
      expect(p.last4, '4321');
      expect(p.merchant, 'Swiggy');
      expect(p.category, SpendCategory.dining);
      expect(p.timestamp.day, 9);
      expect(p.timestamp.month, 11);
    });

    test('ICICI style', () {
      final p = parse(
        'INR 3,499.00 spent using ICICI Bank Card XX9876 on 08-Nov-24 on '
        'AMAZON PAY. Avl Limit: INR 1,20,000.00.',
      );
      expect(p, isNotNull);
      expect(p!.amountMinor, 349900);
      expect(p.last4, '9876');
      expect(p.merchant, 'Amazon Pay');
      expect(p.category, SpendCategory.shopping);
      expect(p.timestamp, DateTime(2024, 11, 8));
    });

    test('SBI style with Rs and ending', () {
      final p = parse(
        'Rs 540.00 spent on your SBI Credit Card ending 1122 at BIG BASKET '
        'on 07/11/24. Trxn. not done by you? Report immediately.',
      );
      expect(p, isNotNull);
      expect(p!.amountMinor, 54000);
      expect(p.last4, '1122');
      expect(p.category, SpendCategory.groceries);
      expect(p.timestamp, DateTime(2024, 11, 7));
    });

    test('US dollar alert', () {
      final p = parse(
        'Chase: A charge of \$45.20 at Starbucks was made on your credit '
        'card ending in 7788 on 2024-11-09 08:15.',
      );
      expect(p, isNotNull);
      expect(p!.currency, 'USD');
      expect(p.amountMinor, 4520);
      expect(p.last4, '7788');
      expect(p.merchant, 'Starbucks');
      expect(p.category, SpendCategory.dining);
    });

    test('does not mistake available limit for the amount', () {
      final p = parse(
        'Your Credit Card XX1234 Avl Limit Rs 50,000. Spent Rs 800 at '
        'INDIAN OIL on 10-11-2024.',
      );
      expect(p, isNotNull);
      expect(p!.amountMinor, 80000);
      expect(p.category, SpendCategory.fuel);
    });

    test('falls back to received time when no date present', () {
      final p = parse('Rs 100 spent on Credit Card XX0001 at LOCAL STORE.');
      expect(p, isNotNull);
      expect(p!.timestamp, received);
    });

    test('12 hour time parsing', () {
      final p = parse(
        'Rs 100 spent on Credit Card XX0001 at CAFE COFFEE DAY on '
        '10-Nov-2024 02:30 PM.',
      );
      expect(p, isNotNull);
      expect(p!.timestamp, DateTime(2024, 11, 10, 14, 30));
    });
  });

  group('rejects', () {
    final cases = <String, String>{
      'otp':
          'OTP 123456 for Rs 500 txn on your Credit Card XX1234. Do not '
          'share.',
      'debit': 'Rs 500 spent on your Debit Card XX1234 at AMAZON.',
      'bank account': 'Rs 500 debited from A/c XX1234 on 10-11-24 UPI.',
      'refund': 'Refund of Rs 500 processed to your Credit Card XX1234.',
      'payment received':
          'Payment of Rs 5,000 received on your Credit Card XX1234. Thank you.',
      'statement':
          'Your Credit Card XX1234 statement is generated. Total due '
          'Rs 5,000, due date 20-11-2024.',
      'promo': 'Get 5% cashback on your credit card spends! Apply now.',
      'declined': 'Transaction of Rs 500 declined on Credit Card XX1234.',
      'empty': '   ',
      'random': 'Hey are we meeting at 5pm? I owe you Rs 500.',
    };
    cases.forEach((name, body) {
      test(name, () => expect(parse(body), isNull));
    });

    test('over-long body', () {
      expect(parse('Rs 100 spent on credit card ${'x' * 2000}'), isNull);
    });

    test('rejects far-future dates by using received time', () {
      final p = parse(
        'Rs 100 spent on Credit Card XX0001 at LOCAL STORE on 01-01-2035.',
      );
      expect(p, isNotNull);
      expect(p!.timestamp, received);
    });
  });

  group('cashback credit', () {
    test('detects credited cashback', () {
      final p = parse(
        'Cashback of Rs 75.00 has been credited to your Credit Card '
        'XX4321 on 05-11-2024.',
      );
      expect(p, isNotNull);
      expect(p!.kind, ParsedKind.cashbackCredit);
      expect(p.amountMinor, 7500);
      expect(p.last4, '4321');
    });

    test('ignores cashback promotions', () {
      expect(
        parse('Get Rs 500 cashback on your credit card if you spend 5000'),
        isNull,
      );
    });
  });

  group('dedupe key', () {
    test('is stable and whitespace insensitive', () {
      expect(
        SmsParser.messageKey('a  b', received),
        SmsParser.messageKey('a b', received),
      );
      expect(
        SmsParser.messageKey('a b', received),
        isNot(
          SmsParser.messageKey('a b', received.add(const Duration(seconds: 1))),
        ),
      );
    });
  });

  group('categorizer', () {
    test('keyword precedence', () {
      expect(
        Categorizer.categorize('Swiggy Instamart'),
        SpendCategory.groceries,
      );
      expect(Categorizer.categorize('Uber'), SpendCategory.travel);
      expect(Categorizer.categorize('BESCOM'), SpendCategory.utilities);
      expect(Categorizer.categorize('Random Co'), SpendCategory.other);
    });

    test('word boundaries avoid false positives', () {
      expect(Categorizer.categorize('Barbados Holdings'), SpendCategory.other);
    });
  });
}
