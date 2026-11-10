import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/sms_source.dart';
import '../state/app_state.dart';
import '../util/money.dart';
import 'widgets.dart';

String _summary(ScanResult r) {
  if (r.added == 0 && r.cashbackCredits == 0) {
    return r.duplicates > 0
        ? 'No new transactions. ${r.duplicates} already imported.'
        : 'No credit card transactions found in ${r.scanned} messages.';
  }
  final parts = <String>[
    '${r.added} new transaction${r.added == 1 ? '' : 's'}',
    if (r.cashbackCredits > 0)
      '${r.cashbackCredits} cashback credit${r.cashbackCredits == 1 ? '' : 's'}',
  ];
  var s = 'Imported ${parts.join(' and ')}.';
  if (r.unlinked > 0) {
    s +=
        ' ${r.unlinked} not matched to a card: add the card and they will '
        'link automatically.';
  }
  return s;
}

/// Primary action: scan device messages (Android) or open paste import (iOS).
Future<void> scanFlow(BuildContext context) async {
  final app = context.read<AppState>();

  if (!app.sms.isSupported) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Messages cannot be scanned on iOS'),
        content: const Text(
          'Apple does not let apps read your SMS inbox. Copy your card '
          'alert messages and paste them into the app instead.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              pasteMessagesFlow(context);
            },
            child: const Text('Paste messages'),
          ),
        ],
      ),
    );
    return;
  }

  var access = await app.sms.status();
  if (access != SmsAccess.granted) {
    if (!context.mounted) return;
    // Prominent disclosure before the system dialog.
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.sms_outlined),
        title: const Text('Allow access to messages?'),
        content: const Text(
          'Cardwise reads your SMS inbox on this device to find credit '
          'card payment alerts. Only amount, merchant, date and last 4 '
          'digits are kept, encrypted on your phone. Message text is never '
          'stored and nothing is sent over the network.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (proceed != true) return;

    if (access == SmsAccess.permanentlyDenied) {
      if (!context.mounted) return;
      final open = await confirm(
        context,
        title: 'Permission needed',
        body: 'SMS access was turned off. Open Settings to allow it.',
        action: 'Open Settings',
      );
      if (open) await app.sms.openSettings();
      return;
    }
    access = await app.sms.request();
    if (access != SmsAccess.granted) {
      if (context.mounted) {
        showMessage(
          context,
          access == SmsAccess.permanentlyDenied
              ? 'SMS access is turned off. Enable it in Settings to scan.'
              : 'Without SMS access you can still paste messages.',
          error: true,
        );
      }
      return;
    }
  }

  if (!context.mounted) return;
  try {
    final r = await app.scanInbox();
    if (context.mounted) showMessage(context, _summary(r));
  } catch (e) {
    if (context.mounted) {
      showMessage(context, 'Scan failed. Please try again.', error: true);
    }
  }
}

Future<void> pasteMessagesFlow(BuildContext context) async {
  final app = context.read<AppState>();
  final text = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _PasteSheet(),
  );
  if (text == null || text.trim().isEmpty) return;
  try {
    final r = await app.importPasted(text);
    if (context.mounted) showMessage(context, _summary(r));
  } catch (_) {
    if (context.mounted) {
      showMessage(context, 'Import failed. Please try again.', error: true);
    }
  }
}

class _PasteSheet extends StatefulWidget {
  const _PasteSheet();

  @override
  State<_PasteSheet> createState() => _PasteSheetState();
}

class _PasteSheetState extends State<_PasteSheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text != null) {
      setState(
        () => _ctrl.text = d!.text!.length > 100000
            ? d.text!.substring(0, 100000)
            : d.text!,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Paste card alerts',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            'Separate multiple messages with a blank line.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            minLines: 5,
            maxLines: 10,
            maxLength: 100000,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText:
                  'Rs 1,250.00 spent on HDFC Bank Credit Card XX4321 at ...',
            ),
          ),
          Row(
            children: [
              TextButton.icon(
                onPressed: _paste,
                icon: const Icon(Icons.content_paste),
                label: const Text('Paste'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => Navigator.pop(context, _ctrl.text),
                child: const Text('Import'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> showSettingsSheet(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => const _SettingsSheet(),
  );
}

class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Settings', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: app.data.primaryCurrency,
              decoration: const InputDecoration(
                labelText: 'Primary currency',
                helperText:
                    'Totals only include transactions in this currency.',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final c in supportedCurrencies)
                  DropdownMenuItem(
                    value: c.code,
                    child: Text('${c.code} - ${c.name}'),
                  ),
              ],
              onChanged: (v) {
                if (v != null) {
                  guarded(context, () => app.setPrimaryCurrency(v));
                }
              },
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.delete_forever_outlined),
              title: const Text('Erase all data'),
              subtitle: const Text('Deletes cards, transactions and the key'),
              onTap: () async {
                final ok = await confirm(
                  context,
                  title: 'Erase all data?',
                  body:
                      'This permanently deletes everything stored by '
                      'Cardwise on this device.',
                  action: 'Erase',
                );
                if (ok) {
                  await app.resetAll();
                  if (context.mounted) Navigator.pop(context);
                }
              },
            ),
            const Divider(),
            Text(
              'Privacy: data is encrypted with AES-256-GCM using a key held in '
              'the device keystore, excluded from cloud backup, and never '
              'leaves your phone.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
