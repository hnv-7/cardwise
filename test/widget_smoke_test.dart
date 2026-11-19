import 'dart:ui' show Size;

import 'package:cc_app/main.dart';
import 'package:cc_app/models/category.dart';
import 'package:cc_app/models/models.dart';
import 'package:cc_app/services/analytics.dart' show BillingCycle;
import 'package:cc_app/services/sms_source.dart';
import 'package:cc_app/state/app_state.dart';
import 'package:flutter/material.dart' show ChoiceChip, SearchBar, TextField;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'app_state_test.dart' show FakeSms, MemoryVault;

void main() {
  testWidgets('empty state, add card, scan and see dashboard', (tester) async {
    final received = DateTime.now().subtract(const Duration(hours: 2));
    final app = AppState(
      vault: MemoryVault(),
      sms: FakeSms([
        RawSms(
          'Rs.1,250.50 spent on HDFC Bank Credit Card XX4321 at SWIGGY. '
          'Avl Lmt: Rs.85,000.00',
          received,
        ),
      ]),
    );
    await app.load();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: app, child: const CardwiseApp()),
    );
    await tester.pumpAndSettle();

    expect(find.text('No spending yet'), findsOneWidget);
    expect(find.text('Scan messages'), findsOneWidget);

    await tester.tap(find.text('Scan messages'));
    await tester.pumpAndSettle();

    expect(app.data.transactions.length, 1);
    expect(find.text('Total spend'), findsOneWidget);
    expect(find.textContaining('1,250.50'), findsWidgets);

    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(find.text('Swiggy'), findsOneWidget);

    await tester.tap(find.text('Cards'));
    await tester.pumpAndSettle();
    expect(find.text('Add a card'), findsOneWidget);
  });

  testWidgets('tapping a category on Overview lists and edits its spends', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final app = AppState(vault: MemoryVault(), sms: FakeSms([]));
    await app.load();
    await app.saveTransaction(
      cardId: null,
      amountMinor: 45000,
      currency: 'INR',
      merchant: 'Corner Cafe',
      category: SpendCategory.dining,
      timestamp: DateTime.now().subtract(const Duration(hours: 1)),
    );
    await app.saveTransaction(
      cardId: null,
      amountMinor: 99900,
      currency: 'INR',
      merchant: 'Big Mart',
      category: SpendCategory.shopping,
      timestamp: DateTime.now().subtract(const Duration(hours: 1)),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: app, child: const CardwiseApp()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dining'));
    await tester.pumpAndSettle();

    // Category detail shows only dining spends, with a total.
    expect(find.text('Corner Cafe'), findsOneWidget);
    expect(find.text('Big Mart'), findsNothing);
    expect(find.textContaining('1 transaction'), findsOneWidget);

    // Tapping a spend opens the editor.
    await tester.tap(find.text('Corner Cafe'));
    await tester.pumpAndSettle();
    expect(find.text('Edit transaction'), findsOneWidget);
  });

  testWidgets('period chips filter Overview and the donut is interactive', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final app = AppState(vault: MemoryVault(), sms: FakeSms([]));
    await app.load();
    final recent = DateTime.now().subtract(const Duration(hours: 1));
    // Far enough back to be outside any "this cycle" window.
    final old = DateTime.now().subtract(const Duration(days: 75));
    Future<void> add(String m, SpendCategory c, DateTime t) =>
        app.saveTransaction(
          cardId: null,
          amountMinor: 10000,
          currency: 'INR',
          merchant: m,
          category: c,
          timestamp: t,
        );
    await add('Corner Cafe', SpendCategory.dining, recent);
    await add('Old Bistro', SpendCategory.dining, old);
    await add('Air Trip', SpendCategory.travel, old);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: app, child: const CardwiseApp()),
    );
    await tester.pumpAndSettle();

    // All five period options are offered.
    for (final label in [
      'This cycle',
      'Last cycle',
      '3 cycles',
      '6 cycles',
      'All time',
    ]) {
      expect(find.text(label), findsWidgets);
    }

    // This cycle: only the recent dining spend; Travel is not present.
    expect(find.text('Travel'), findsNothing);
    expect(find.text('Tap a slice or a category below'), findsOneWidget);

    // All time brings Travel back.
    await tester.tap(find.widgetWithText(ChoiceChip, 'All time'));
    await tester.pumpAndSettle();
    expect(find.text('Travel'), findsOneWidget);
    expect(find.textContaining('3 transactions'), findsOneWidget);
  });

  testWidgets('card detail switches between this cycle and all time', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final app = AppState(vault: MemoryVault(), sms: FakeSms([]));
    await app.load();
    await app.saveCard(
      name: 'Everyday',
      issuer: '',
      last4: '1111',
      colorValue: 0xFF3B5BDB,
      defaultRateBps: 100,
      categoryRatesBps: const {},
    );
    final cardId = app.data.cards.single.id;
    Future<void> add(String m, DateTime t) => app.saveTransaction(
      cardId: cardId,
      amountMinor: 10000,
      currency: 'INR',
      merchant: m,
      category: SpendCategory.shopping,
      timestamp: t,
    );
    await add('Fresh Mart', DateTime.now());
    // Calendar-month cycle: 75 days ago is always in an earlier cycle.
    await add('Old Mart', DateTime.now().subtract(const Duration(days: 75)));

    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: app, child: const CardwiseApp()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cards'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Everyday'));
    await tester.pumpAndSettle();

    // Defaults to the current cycle.
    expect(find.text('Spent this cycle'), findsOneWidget);
    expect(find.text('Fresh Mart'), findsOneWidget);
    expect(find.text('Old Mart'), findsNothing);
    expect(find.text('1 transaction'), findsOneWidget);

    await tester.tap(find.text('All time'));
    await tester.pumpAndSettle();
    expect(find.text('Total spent'), findsOneWidget);
    expect(find.text('Fresh Mart'), findsOneWidget);
    expect(find.text('Old Mart'), findsOneWidget);
    expect(find.text('2 transactions'), findsOneWidget);
  });

  Future<AppState> appWithCard({int? dueDays}) async {
    final app = AppState(vault: MemoryVault(), sms: FakeSms([]));
    await app.load();
    await app.saveCard(
      name: 'Everyday',
      issuer: '',
      last4: '1111',
      colorValue: 0xFF3B5BDB,
      defaultRateBps: 100,
      categoryRatesBps: const {SpendCategory.dining: 500},
      paymentDueDays: dueDays,
    );
    return app;
  }

  Future<void> add(
    AppState app,
    String merchant,
    DateTime when, {
    SpendCategory category = SpendCategory.shopping,
  }) => app.saveTransaction(
    cardId: app.data.cards.single.id,
    amountMinor: 10000,
    currency: 'INR',
    merchant: merchant,
    category: category,
    timestamp: when,
  );

  void tallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('Activity search filters by merchant and amount', (tester) async {
    tallScreen(tester);
    final app = await appWithCard();
    await add(
      app,
      'Corner Cafe',
      DateTime.now(),
      category: SpendCategory.dining,
    );
    await add(app, 'Big Mart', DateTime.now());
    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: app, child: const CardwiseApp()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();

    expect(find.byType(SearchBar), findsOneWidget);
    await tester.enterText(find.byType(SearchBar), 'corner');
    await tester.pumpAndSettle();
    expect(find.text('Corner Cafe'), findsOneWidget);
    expect(find.text('Big Mart'), findsNothing);
    expect(find.textContaining('1 result'), findsOneWidget);

    await tester.enterText(find.byType(SearchBar), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches "zzz".'), findsOneWidget);
  });

  testWidgets('card page shows the last statement and hides the card name '
      'on rows', (tester) async {
    tallScreen(tester);
    final app = await appWithCard(dueDays: 30);
    final last = BillingCycle.containing(DateTime.now(), 1).plus(-1);
    await add(app, 'Last Month Shop', last.start.add(const Duration(days: 2)));
    await add(app, 'Fresh Mart', DateTime.now());
    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: app, child: const CardwiseApp()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cards'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Everyday'));
    await tester.pumpAndSettle();

    expect(find.text('Fresh Mart'), findsOneWidget);
    expect(find.text('Last Month Shop'), findsNothing);
    // Rows show only the date, not "Everyday ••1111 · ...".
    expect(find.textContaining('Everyday ••1111 ·'), findsNothing);

    await tester.tap(find.text('Last cycle'));
    await tester.pumpAndSettle();
    expect(find.text('Statement spend'), findsOneWidget);
    expect(find.text('Last Month Shop'), findsOneWidget);
    expect(find.text('Fresh Mart'), findsNothing);
    expect(find.textContaining(' · due '), findsOneWidget);

    await tester.tap(find.text('Mark paid'));
    await tester.pumpAndSettle();
    expect(find.text('Paid'), findsOneWidget);
    expect(app.data.paidStatements.length, 1);
  });

  testWidgets('Overview lists a payment due until it is marked paid', (
    tester,
  ) async {
    tallScreen(tester);
    final app = await appWithCard(dueDays: 30);
    final last = BillingCycle.containing(DateTime.now(), 1).plus(-1);
    await add(app, 'Last Month Shop', last.start.add(const Duration(days: 2)));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: app, child: const CardwiseApp()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Payments due'), findsOneWidget);
    await tester.tap(find.text('Mark paid'));
    await tester.pumpAndSettle();
    expect(find.text('Payments due'), findsNothing);
  });

  testWidgets('which-card screen ranks cards for a purchase', (tester) async {
    tallScreen(tester);
    final app = AppState(vault: MemoryVault(), sms: FakeSms([]));
    await app.load();
    await app.saveCard(
      name: 'Diner',
      issuer: '',
      last4: '1111',
      colorValue: 0xFF3B5BDB,
      defaultRateBps: 100,
      categoryRatesBps: const {SpendCategory.dining: 500},
    );
    await app.saveCard(
      name: 'Shopper',
      issuer: '',
      last4: '2222',
      colorValue: 0xFF0CA678,
      defaultRateBps: 150,
      categoryRatesBps: const {},
      merchantRates: const [MerchantRate(keyword: 'Amazon', bps: 1000)],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: app, child: const CardwiseApp()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cards'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Which card should I use?'));
    await tester.pumpAndSettle();

    double top(String name) =>
        tester.getTopLeft(find.textContaining('$name ••')).dy;

    // Shopping by default: Shopper's 1.5% base beats Diner's 1%.
    expect(top('Shopper'), lessThan(top('Diner')));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Dining'));
    await tester.pumpAndSettle();
    expect(top('Diner'), lessThan(top('Shopper')));
    expect(find.text('₹50.00'), findsOneWidget); // 5% of 1,000

    await tester.enterText(find.byType(TextField).at(1), 'Amazon');
    await tester.pumpAndSettle();
    expect(top('Shopper'), lessThan(top('Diner')));
    expect(find.textContaining('at Amazon'), findsOneWidget);
    expect(find.text('\u20B9100.00'), findsOneWidget); // 10% of 1,000
  });
}
