import 'package:cc_app/main.dart';
import 'package:cc_app/services/sms_source.dart';
import 'package:cc_app/state/app_state.dart';
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
}
