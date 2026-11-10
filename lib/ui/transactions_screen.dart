import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/category.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../util/money.dart';
import 'widgets.dart';

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key, this.cardId});

  /// When set, the list is fixed to a single card.
  final String? cardId;

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  String? _cardFilter;
  SpendCategory? _catFilter;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final a = app.analytics;
    final cardId = widget.cardId ?? _cardFilter;
    final list = a.transactions(
      cardId: cardId,
      category: _catFilter,
      onlyPrimaryCurrency: false,
    );

    return Column(
      children: [
        if (widget.cardId == null)
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                PopupMenuButton<String?>(
                  tooltip: 'Filter by card',
                  onSelected: (v) => setState(() => _cardFilter = v),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: null, child: Text('All cards')),
                    for (final c in app.data.cards)
                      PopupMenuItem(value: c.id, child: Text(c.displayName)),
                  ],
                  child: Chip(
                    avatar: const Icon(Icons.credit_card, size: 18),
                    label: Text(
                      app.cardById(_cardFilter)?.displayName ?? 'All cards',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<SpendCategory?>(
                  tooltip: 'Filter by category',
                  onSelected: (v) => setState(() => _catFilter = v),
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: null,
                      child: Text('All categories'),
                    ),
                    for (final c in SpendCategory.values)
                      PopupMenuItem(value: c, child: Text(c.label)),
                  ],
                  child: Chip(
                    avatar: const Icon(Icons.category_outlined, size: 18),
                    label: Text(_catFilter?.label ?? 'All categories'),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: list.isEmpty
              ? EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: 'No transactions',
                  body: app.data.transactions.isEmpty
                      ? 'Scan your messages or add a transaction manually.'
                      : 'Nothing matches the current filters.',
                  action: FilledButton.tonalIcon(
                    onPressed: () =>
                        showTransactionEditor(context, cardId: widget.cardId),
                    icon: const Icon(Icons.add),
                    label: const Text('Add transaction'),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: list.length + 1,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () => showTransactionEditor(
                            context,
                            cardId: widget.cardId,
                          ),
                          icon: const Icon(Icons.add),
                          label: const Text('Add manually'),
                        ),
                      );
                    }
                    return _TxnTile(txn: list[i - 1]);
                  },
                ),
        ),
      ],
    );
  }
}

class _TxnTile extends StatelessWidget {
  const _TxnTile({required this.txn});
  final TxnRecord txn;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final card = app.cardById(txn.cardId);
    final fmt = DateFormat('d MMM yyyy, h:mm a');
    return Dismissible(
      key: ValueKey(txn.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Theme.of(context).colorScheme.error,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      confirmDismiss: (_) => confirm(
        context,
        title: 'Delete transaction?',
        body: '${txn.merchant} - ${formatMinor(txn.amountMinor, txn.currency)}',
      ),
      onDismissed: (_) => guarded(context, () => app.deleteTransaction(txn.id)),
      child: ListTile(
        leading: CategoryAvatar(txn.category),
        title: Text(txn.merchant, overflow: TextOverflow.ellipsis),
        subtitle: Row(
          children: [
            CardDot(card),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${card?.displayName ?? (txn.cardLast4Hint != null ? 'Card ••${txn.cardLast4Hint} (not added)' : 'No card')}'
                ' \u00B7 ${fmt.format(txn.timestamp)}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        trailing: Text(
          formatMinor(txn.amountMinor, txn.currency),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        onTap: () => showTransactionEditor(context, existing: txn),
      ),
    );
  }
}

Future<void> showTransactionEditor(
  BuildContext context, {
  TxnRecord? existing,
  String? cardId,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _TxnEditor(existing: existing, cardId: cardId),
  );
}

class _TxnEditor extends StatefulWidget {
  const _TxnEditor({this.existing, this.cardId});
  final TxnRecord? existing;
  final String? cardId;

  @override
  State<_TxnEditor> createState() => _TxnEditorState();
}

class _TxnEditorState extends State<_TxnEditor> {
  late final TextEditingController _amount;
  late final TextEditingController _merchant;
  late SpendCategory _category;
  late DateTime _when;
  late String _currency;
  String? _cardId;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    final app = context.read<AppState>();
    _amount = TextEditingController(
      text: e == null ? '' : formatMinorPlain(e.amountMinor),
    );
    _merchant = TextEditingController(text: e?.merchant ?? '');
    _category = e?.category ?? SpendCategory.other;
    _when = e?.timestamp ?? DateTime.now();
    _currency = e?.currency ?? app.data.primaryCurrency;
    _cardId = e?.cardId ?? widget.cardId;
  }

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _when.isAfter(now) ? now : _when,
      firstDate: DateTime(2000),
      lastDate: now,
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_when),
    );
    if (!mounted) return;
    setState(
      () => _when = DateTime(
        d.year,
        d.month,
        d.day,
        t?.hour ?? _when.hour,
        t?.minute ?? _when.minute,
      ),
    );
  }

  Future<void> _save() async {
    final app = context.read<AppState>();
    final amount = parseAmountMinor(_amount.text);
    final err = app.validateTransaction(
      amountMinor: amount,
      merchant: _merchant.text,
      timestamp: _when,
    );
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _error = null;
      _busy = true;
    });
    final ok = await guarded(
      context,
      () => app.saveTransaction(
        id: widget.existing?.id,
        cardId: _cardId,
        amountMinor: amount,
        currency: _currency,
        merchant: _merchant.text,
        category: _category,
        timestamp: _when,
      ),
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.existing == null ? 'Add transaction' : 'Edit transaction',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              SizedBox(
                width: 110,
                child: DropdownButtonFormField<String>(
                  initialValue: _currency,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Currency',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final c in supportedCurrencies)
                      DropdownMenuItem(value: c.code, child: Text(c.code)),
                  ],
                  onChanged: (v) => setState(() => _currency = v ?? _currency),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    LengthLimitingTextInputFormatter(16),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Amount',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _merchant,
            maxLength: AppState.maxMerchantLength,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Merchant',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 4),
          DropdownButtonFormField<SpendCategory>(
            initialValue: _category,
            decoration: const InputDecoration(
              labelText: 'Category',
              helperText: 'Changes apply to this merchant from now on',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final c in SpendCategory.values)
                DropdownMenuItem(
                  value: c,
                  child: Row(
                    children: [
                      Icon(c.icon, size: 18, color: c.color),
                      const SizedBox(width: 10),
                      Text(c.label),
                    ],
                  ),
                ),
            ],
            onChanged: (v) => setState(() => _category = v ?? _category),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            initialValue: app.cardById(_cardId)?.id,
            decoration: const InputDecoration(
              labelText: 'Card',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem(value: null, child: Text('No card')),
              for (final c in app.data.cards)
                DropdownMenuItem(value: c.id, child: Text(c.displayName)),
            ],
            onChanged: (v) => setState(() => _cardId = v),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _pickDate,
            icon: const Icon(Icons.event),
            label: Text(DateFormat('d MMM yyyy, h:mm a').format(_when)),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
