import 'dart:ui' show Size;

import 'package:cc_app/main.dart';
import 'package:cc_app/models/category.dart';
import 'package:cc_app/services/sms_source.dart';
import 'package:cc_app/state/app_state.dart';
import 'package:flutter/material.dart' show ChoiceChip;
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
}
