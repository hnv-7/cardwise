import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/category.dart';
import '../models/models.dart';
import '../services/analytics.dart';
import '../state/app_state.dart';
import '../util/money.dart';
import 'transactions_screen.dart';
import 'widgets.dart';

String formatRate(int bps) {
  final pct = bps / 100;
  return pct == pct.roundToDouble()
      ? '${pct.toStringAsFixed(0)}%'
      : '${pct.toStringAsFixed(2)}%';
}

/// Parses a percentage like "1.5" into basis points; null when invalid.
int? parseRateBps(String s) {
  final t = s.trim();
  if (t.isEmpty) return null;
  final m = RegExp(r'^(\d{1,3})(?:\.(\d{1,2}))?$').firstMatch(t);
  if (m == null) return null;
  final fraction = (m.group(2) ?? '').padRight(2, '0');
  final bps =
      int.parse(m.group(1)!) * 100 +
      (fraction.isEmpty ? 0 : int.parse(fraction));
  return bps > 10000 ? null : bps;
}

/// "15 Oct - 14 Nov"
String cycleLabel(BillingCycle c) {
  final f = DateFormat('d MMM');
  return '${f.format(c.start)} - ${f.format(c.lastDay)}';
}

String ordinal(int n) {
  if (n >= 11 && n <= 13) return '${n}th';
  return switch (n % 10) {
    1 => '${n}st',
    2 => '${n}nd',
    3 => '${n}rd',
    _ => '${n}th',
  };
}

class CardsScreen extends StatelessWidget {
  const CardsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final a = app.analytics;
    final cards = app.data.cards;

    if (cards.isEmpty) {
      return EmptyState(
        icon: Icons.credit_card_outlined,
        title: 'No cards yet',
        body:
            'Add your credit cards with their cashback rates. Transactions '
            'are matched to cards by their last 4 digits.',
        action: FilledButton.icon(
          onPressed: () => showCardEditor(context),
          icon: const Icon(Icons.add),
          label: const Text('Add a card'),
        ),
      );
    }

    final now = DateTime.now();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        for (final c in cards)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _CardTile(
              card: c,
              cycle: BillingCycle.containing(now, c.billingDay),
              cycleSpend: a.total(
                a.transactions(
                  cardId: c.id,
                  from: BillingCycle.containing(now, c.billingDay).start,
                ),
              ),
              currency: a.currency,
              estimated:
                  a.cashbackFor(c).perCycle[BillingCycle.containing(
                    now,
                    c.billingDay,
                  ).key] ??
                  0,
            ),
          ),
        OutlinedButton.icon(
          onPressed: () => showCardEditor(context),
          icon: const Icon(Icons.add),
          label: const Text('Add card'),
        ),
        if (app.data.transactions.any((t) => t.cardId == null))
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              '${app.data.transactions.where((t) => t.cardId == null).length} '
              'transaction(s) are not linked to a card.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _CardTile extends StatelessWidget {
  const _CardTile({
    required this.card,
    required this.cycle,
    required this.cycleSpend,
    required this.currency,
    required this.estimated,
  });
  final CardProfile card;
  final BillingCycle cycle;
  final int cycleSpend;
  final String currency;
  final int estimated;

  @override
  Widget build(BuildContext context) {
    final base = Color(card.colorValue);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => CardDetailScreen(cardId: card.id),
        ),
      ),
      child: Ink(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: base,
        ),
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: Colors.white),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      card.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (card.issuer.isNotEmpty) Text(card.issuer),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                '\u2022\u2022\u2022\u2022  \u2022\u2022\u2022\u2022  \u2022\u2022\u2022\u2022  ${card.last4}',
                style: const TextStyle(fontSize: 16, letterSpacing: 1.5),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _kv('This cycle', formatMinor(cycleSpend, currency)),
                  ),
                  Expanded(
                    child: _kv(
                      'Est. cashback',
                      formatMinor(estimated, currency),
                    ),
                  ),
                  _kv('Base rate', formatRate(card.defaultRateBps)),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Cycle ${cycleLabel(cycle)}',
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(k, style: const TextStyle(fontSize: 11, color: Colors.white70)),
      const SizedBox(height: 2),
      Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
    ],
  );
}

class CardDetailScreen extends StatelessWidget {
  const CardDetailScreen({super.key, required this.cardId});
  final String cardId;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final card = app.cardById(cardId);
    if (card == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.credit_card_off_outlined,
          title: 'Card removed',
          body: 'This card no longer exists.',
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(card.displayName),
        actions: [
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => showCardEditor(context, existing: card),
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final ok = await confirm(
                context,
                title: 'Delete ${card.name}?',
                body:
                    'Its transactions are kept but will no longer be '
                    'linked to a card.',
              );
              if (!ok || !context.mounted) return;
              final done = await guarded(
                context,
                () => app.deleteCard(card.id),
              );
              if (done && context.mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      body: TransactionsScreen(cardId: card.id),
    );
  }
}

Future<void> showCardEditor(BuildContext context, {CardProfile? existing}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CardEditor(existing: existing),
    );

class _CardEditor extends StatefulWidget {
  const _CardEditor({this.existing});
  final CardProfile? existing;

  @override
  State<_CardEditor> createState() => _CardEditorState();
}

class _CardEditorState extends State<_CardEditor> {
  late final TextEditingController _name;
  late final TextEditingController _issuer;
  late final TextEditingController _last4;
  late final TextEditingController _baseRate;
  late final TextEditingController _cap;
  final Map<SpendCategory, TextEditingController> _catRates = {};
  late int _color;
  late int _billingDay;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _issuer = TextEditingController(text: e?.issuer ?? '');
    _last4 = TextEditingController(text: e?.last4 ?? '');
    _baseRate = TextEditingController(
      text: e == null ? '1' : (e.defaultRateBps / 100).toString(),
    );
    _cap = TextEditingController(
      text: e?.cycleCapMinor == null ? '' : formatMinorPlain(e!.cycleCapMinor!),
    );
    _billingDay = e?.billingDay ?? 1;
    _color = e?.colorValue ?? cardColorChoices.first;
    for (final c in SpendCategory.values) {
      final bps = e?.categoryRatesBps[c];
      _catRates[c] = TextEditingController(
        text: bps == null ? '' : (bps / 100).toString(),
      );
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _issuer,
      _last4,
      _baseRate,
      _cap,
      ..._catRates.values,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final app = context.read<AppState>();
    final base = parseRateBps(_baseRate.text);
    if (base == null) {
      setState(() => _error = 'Enter a base cashback rate between 0 and 100.');
      return;
    }
    final rates = <SpendCategory, int>{};
    for (final entry in _catRates.entries) {
      if (entry.value.text.trim().isEmpty) continue;
      final r = parseRateBps(entry.value.text);
      if (r == null) {
        setState(
          () => _error =
              'Invalid rate for ${entry.key.label}. Use a number from 0 to 100.',
        );
        return;
      }
      rates[entry.key] = r;
    }
    int? cap;
    if (_cap.text.trim().isNotEmpty) {
      cap = parseAmountMinor(_cap.text);
      if (cap == null) {
        setState(
          () => _error = 'Enter a valid cashback cap or leave it empty.',
        );
        return;
      }
    }
    final err = app.validateCard(
      name: _name.text,
      last4: _last4.text,
      defaultRateBps: base,
      categoryRatesBps: rates,
      cycleCapMinor: cap,
      billingDay: _billingDay,
      editingId: widget.existing?.id,
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
      () => app.saveCard(
        id: widget.existing?.id,
        name: _name.text,
        issuer: _issuer.text,
        last4: _last4.text,
        colorValue: _color,
        defaultRateBps: base,
        categoryRatesBps: rates,
        cycleCapMinor: cap,
        billingDay: _billingDay,
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
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final cur = currencyFor(context.read<AppState>().data.primaryCurrency);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.existing == null ? 'Add card' : 'Edit card',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Card name',
              hintText: 'e.g. Millennia',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _issuer,
                  maxLength: 30,
                  decoration: const InputDecoration(
                    labelText: 'Bank (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 120,
                child: TextField(
                  controller: _last4,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(4),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Last 4',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            children: [
              for (final c in cardColorChoices)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: Semantics(
                    label: 'Card colour',
                    selected: _color == c,
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: Color(c),
                      child: _color == c
                          ? const Icon(
                              Icons.check,
                              size: 18,
                              color: Colors.white,
                            )
                          : null,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text('Billing cycle', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _billingDay,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Cycle starts on',
              helperText:
                  'The day after your statement date. Spend and '
                  'cashback caps reset on this day each month.',
              helperMaxLines: 3,
              border: OutlineInputBorder(),
            ),
            items: [
              for (var d = 1; d <= 28; d++)
                DropdownMenuItem(
                  value: d,
                  child: Text(
                    d == 1
                        ? '1st (calendar month)'
                        : '${ordinal(d)} (statement on ${ordinal(d - 1)})',
                  ),
                ),
            ],
            onChanged: (v) => setState(() => _billingDay = v ?? _billingDay),
          ),
          const SizedBox(height: 20),
          Text('Cashback', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _baseRate,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    LengthLimitingTextInputFormatter(6),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Base rate',
                    suffixText: '%',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _cap,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    LengthLimitingTextInputFormatter(14),
                  ],
                  decoration: InputDecoration(
                    labelText: 'Cap per cycle',
                    prefixText: cur.symbol,
                    helperText: 'Optional',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Category rates (leave empty to use base rate)',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          for (final c in SpendCategory.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  CategoryAvatar(c, size: 32),
                  const SizedBox(width: 12),
                  Expanded(child: Text(c.label)),
                  SizedBox(
                    width: 100,
                    child: TextField(
                      controller: _catRates[c],
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        LengthLimitingTextInputFormatter(6),
                      ],
                      decoration: const InputDecoration(
                        isDense: true,
                        suffixText: '%',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: const Text('Save card'),
          ),
        ],
      ),
    );
  }
}
