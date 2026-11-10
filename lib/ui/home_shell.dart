import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'cards_screen.dart';
import 'cashback_screen.dart';
import 'dashboard_screen.dart';
import 'scan_flow.dart';
import 'transactions_screen.dart';
import 'widgets.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _titles = ['Overview', 'Transactions', 'Cards', 'Cashback'];

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    if (!app.loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (app.loadError != null) return _RecoveryScreen(message: app.loadError!);

    const pages = [
      DashboardScreen(),
      TransactionsScreen(),
      CardsScreen(),
      CashbackScreen(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
        actions: [
          IconButton(
            tooltip: 'Paste messages',
            icon: const Icon(Icons.content_paste_go_outlined),
            onPressed: () => pasteMessagesFlow(context),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => showSettingsSheet(context),
          ),
        ],
      ),
      body: SafeArea(child: pages[_index]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: app.scanning ? null : () => scanFlow(context),
        icon: app.scanning
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.sms_outlined),
        label: Text(app.scanning ? 'Scanning...' : 'Scan messages'),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights),
            label: 'Overview',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'Activity',
          ),
          NavigationDestination(
            icon: Icon(Icons.credit_card_outlined),
            selectedIcon: Icon(Icons.credit_card),
            label: 'Cards',
          ),
          NavigationDestination(
            icon: Icon(Icons.savings_outlined),
            selectedIcon: Icon(Icons.savings),
            label: 'Cashback',
          ),
        ],
      ),
    );
  }
}

class _RecoveryScreen extends StatelessWidget {
  const _RecoveryScreen({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Scaffold(
      body: SafeArea(
        child: EmptyState(
          icon: Icons.lock_reset,
          title: 'Your data could not be opened',
          body:
              '$message\n\nThis can happen after a device restore, because '
              'the encryption key never leaves the device. You can retry, or '
              'erase the stored data and start fresh.',
          action: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(onPressed: app.load, child: const Text('Retry')),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () async {
                  final ok = await confirm(
                    context,
                    title: 'Erase all data?',
                    body:
                        'This permanently deletes all stored cards and '
                        'transactions on this device.',
                    action: 'Erase',
                  );
                  if (ok) await app.resetAll();
                },
                child: const Text('Erase and start fresh'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
