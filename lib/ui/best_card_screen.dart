import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/category.dart';
import '../services/analytics.dart';
import '../services/categorizer.dart';
import '../state/app_state.dart';
import '../util/money.dart';
import 'cards_screen.dart' show formatRate;
import 'widgets.dart';

/// Ranks the user's cards for a purchase by the cashback it would earn now,
/// taking merchant and category rates and what is left of this cycle's caps
/// into account.
class BestCardScreen extends StatefulWidget {
  const BestCardScreen({super.key});

  @override
  State<BestCardScreen> createState() => _BestCardScreenState();
}

class _BestCardScreenState extends State<BestCardScreen> {
  final _amount = TextEditingController(text: '1000');
  final _merchant = TextEditingController();
  SpendCategory _category = SpendCategory.shopping;

  /// Once the user picks a category, typing a merchant no longer changes it.
  bool _categoryPicked = false;

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    super.dispose();
  }

  void _onMerchant(String text, AppState app) {
    setState(() {
      if (_categoryPicked || text.trim().isEmpty) return;
      _category =
          Categorizer.learnedCategory(app.data.merchantCategories, text) ??
          Categorizer.categorize(text);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final a = app.analytics;
    final cur = currencyFor(a.currency);
    final amount = parseAmountMinor(_amount.text);
    final picks = amount == null
        ? const <CardPick>[]
        : a.bestCards(
            category: _category,
            merchant: _merchant.text,
            amountMinor: amount,
          );
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Which card to use?')),
      body: SafeArea(
        child: app.data.cards.isEmpty
            ? const EmptyState(
                icon: Icons.credit_card_outlined,
                title: 'No cards yet',
                body: 'Add your cards with their cashback rates first.',
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 140,
                        child: TextField(
                          controller: _amount,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9.,]'),
                            ),
                            LengthLimitingTextInputFormatter(14),
                          ],
                          decoration: InputDecoration(
                            labelText: 'Amount',
                            prefixText: cur.symbol,
                            border: const OutlineInputBorder(),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _merchant,
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(
                            labelText: 'Merchant (optional)',
                            hintText: 'e.g. Amazon',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (v) => _onMerchant(v, app),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final c in SpendCategory.values)
                        ChoiceChip(
                          avatar: Icon(c.icon, size: 18, color: c.color),
                          label: Text(c.label),
                          selected: _category == c,
                          onSelected: (_) => setState(() {
                            _category = c;
                            _categoryPicked = true;
                          }),
                        ),
                    ],
                  ),
                  SectionTitle(
                    amount == null
                        ? 'Enter an amount'
                        : 'Best for ${formatMinor(amount, cur.code)} '
                              'on ${_category.label}',
                  ),
                  for (var i = 0; i < picks.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _PickTile(
                        pick: picks[i],
                        best: i == 0 && picks[i].expectedMinor > 0,
                        category: _category,
                        currency: cur.code,
                        usage: a.creditUsage(picks[i].card),
                      ),
                    ),
                  if (picks.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Estimates use your rates and what is left of each '
                        "card's caps this billing cycle.",
                        style: text.bodySmall,
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _PickTile extends StatelessWidget {
  const _PickTile({
    required this.pick,
    required this.best,
    required this.category,
    required this.currency,
    required this.usage,
  });

  final CardPick pick;
  final bool best;
  final SpendCategory category;
  final String currency;
  final CreditUsage? usage;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final card = pick.card;
    final rateText = pick.rule != null
        ? '${formatRate(pick.bps)} at ${pick.rule!.keyword}'
        : card.categoryRatesBps.containsKey(category)
        ? '${formatRate(pick.bps)} on ${category.label}'
        : '${formatRate(pick.bps)} base rate';
    final notes = <String>[
      rateText,
      if (pick.capReached)
        'cap reached this cycle'
      else if (pick.roomMinor != null)
        '${formatMinor(pick.roomMinor!, currency)} cap left',
      if (usage != null)
        '${formatMinor(usage!.availableMinor, currency)} available',
    ];
    return Card(
      elevation: 0,
      color: best
          ? t.colorScheme.primaryContainer
          : t.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            CardDot(card),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          card.displayName,
                          style: t.textTheme.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (best) ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.star_rounded,
                          size: 18,
                          color: t.colorScheme.primary,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    notes.join(' · '),
                    style: t.textTheme.bodySmall?.copyWith(
                      color: pick.capReached ? t.colorScheme.error : null,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatMinor(pick.expectedMinor, currency),
              style: t.textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}
