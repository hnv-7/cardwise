import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/analytics.dart';
import '../state/app_state.dart';
import '../util/money.dart';
import 'cards_screen.dart';
import 'widgets.dart';

class CashbackScreen extends StatelessWidget {
  const CashbackScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final a = app.analytics;
    final cur = a.currency;

    if (app.data.cards.isEmpty) {
      return EmptyState(
        icon: Icons.savings_outlined,
        title: 'Add a card to track cashback',
        body:
            'Set each card\'s cashback rates and the app estimates what '
            'you have earned from your transactions.',
        action: FilledButton.icon(
          onPressed: () => showCardEditor(context),
          icon: const Icon(Icons.add),
          label: const Text('Add a card'),
        ),
      );
    }

    final summaries = {for (final c in app.data.cards) c.id: a.cashbackFor(c)};
    final est = summaries.values.fold<int>(0, (s, e) => s + e.estimatedMinor);
    final credited = summaries.values.fold<int>(
      0,
      (s, e) => s + e.creditedMinor,
    );
    final accumulation = a.cashbackAccumulation();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Estimated earned',
                value: formatMinor(est, cur),
                hint: 'From rates x spend',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                label: 'Credited',
                value: formatMinor(credited, cur),
                hint: 'Confirmed by issuer',
              ),
            ),
          ],
        ),
        const SectionTitle('Accumulation (6 billing cycles)'),
        _AccumulationChart(points: accumulation, currency: cur),
        const SectionTitle('By card'),
        for (final c in app.data.cards)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _CardCashback(
              card: c,
              summary: summaries[c.id]!,
              currency: cur,
            ),
          ),
        if (app.data.credits.isNotEmpty) ...[
          const SectionTitle('Credited cashback'),
          Card(
            child: Column(
              children: [
                for (final cr
                    in (app.data.credits.toList()
                      ..sort((x, y) => y.date.compareTo(x.date))))
                  ListTile(
                    leading: const Icon(Icons.check_circle_outline),
                    title: Text(formatMinor(cr.amountMinor, cr.currency)),
                    subtitle: Text(
                      '${app.cardById(cr.cardId)?.displayName ?? (cr.cardLast4Hint != null ? 'Card ••${cr.cardLast4Hint}' : 'No card')}'
                      ' \u00B7 ${DateFormat('d MMM yyyy').format(cr.date)}',
                    ),
                    trailing: IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        if (await confirm(
                              context,
                              title: 'Delete credit?',
                              body: 'Remove this cashback record?',
                            ) &&
                            context.mounted) {
                          await guarded(
                            context,
                            () => app.deleteCashbackCredit(cr.id),
                          );
                        }
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _AccumulationChart extends StatelessWidget {
  const _AccumulationChart({required this.points, required this.currency});
  final List<(MonthKey, int)> points;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxV = points.fold<int>(0, (m, e) => e.$2 > m ? e.$2 : m);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 20, 20, 12),
        child: SizedBox(
          height: 190,
          child: maxV == 0
              ? const Center(child: Text('No cashback earned yet.'))
              : LineChart(
                  LineChartData(
                    minY: 0,
                    maxY: maxV * 1.15,
                    borderData: FlBorderData(show: false),
                    gridData: FlGridData(
                      drawVerticalLine: false,
                      getDrawingHorizontalLine: (_) => FlLine(
                        color: scheme.outlineVariant.withValues(alpha: 0.5),
                        strokeWidth: 1,
                      ),
                    ),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(),
                      rightTitles: const AxisTitles(),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 52,
                          maxIncluded: false,
                          getTitlesWidget: (v, meta) => Text(
                            formatMinorCompact(v.round(), currency),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          interval: 1,
                          getTitlesWidget: (v, meta) {
                            final i = v.toInt();
                            if (i < 0 || i >= points.length) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                DateFormat.MMM().format(points[i].$1.start),
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    lineTouchData: LineTouchData(
                      touchTooltipData: LineTouchTooltipData(
                        getTooltipItems: (spots) => [
                          for (final s in spots)
                            LineTooltipItem(
                              formatMinor(s.y.round(), currency),
                              TextStyle(
                                color: scheme.onInverseSurface,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                    ),
                    lineBarsData: [
                      LineChartBarData(
                        spots: [
                          for (var i = 0; i < points.length; i++)
                            FlSpot(i.toDouble(), points[i].$2.toDouble()),
                        ],
                        isCurved: true,
                        preventCurveOverShooting: true,
                        color: scheme.primary,
                        barWidth: 3,
                        dotData: const FlDotData(show: true),
                        belowBarData: BarAreaData(
                          show: true,
                          color: scheme.primary.withValues(alpha: 0.12),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

class _CardCashback extends StatelessWidget {
  const _CardCashback({
    required this.card,
    required this.summary,
    required this.currency,
  });
  final CardProfile card;
  final CashbackSummary summary;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final app = context.read<AppState>();
    final cycle = BillingCycle.containing(DateTime.now(), card.billingDay);
    final now = cycle.key;
    final thisCycle = summary.perCycle[now] ?? 0;
    final cap = card.cycleCapMinor;
    final rates = card.categoryRatesBps.entries.toList()
      ..sort((x, y) => y.value.compareTo(x.value));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CardDot(card),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(card.displayName, style: t.textTheme.titleSmall),
                ),
                TextButton.icon(
                  onPressed: () => _addCredit(context, app),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Log credit'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _Figure(
                    'Estimated',
                    formatMinor(summary.estimatedMinor, currency),
                  ),
                ),
                Expanded(
                  child: _Figure(
                    'Credited',
                    formatMinor(summary.creditedMinor, currency),
                  ),
                ),
                Expanded(
                  child: _Figure(
                    'Pending',
                    formatMinor(summary.pendingMinor, currency),
                  ),
                ),
              ],
            ),
            if (cap != null) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Text(
                    'This cycle (${cycleLabel(cycle)})',
                    style: t.textTheme.bodySmall,
                  ),
                  const Spacer(),
                  Text(
                    '${formatMinor(thisCycle, currency)} of ${formatMinor(cap, currency)}',
                    style: t.textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: cap == 0
                      ? 0
                      : (thisCycle / cap).clamp(0, 1).toDouble(),
                  minHeight: 8,
                ),
              ),
              if (summary.cappedCycles.contains(now))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Cashback cap for this cycle reached.',
                    style: t.textTheme.bodySmall?.copyWith(
                      color: t.colorScheme.error,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text('Base ${formatRate(card.defaultRateBps)}'),
                ),
                for (final r in rates)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(r.key.icon, size: 16, color: r.key.color),
                    label: Text('${r.key.label} ${formatRate(r.value)}'),
                  ),
              ],
            ),
            if (summary.perCategory.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('Earned by category', style: t.textTheme.labelMedium),
              const SizedBox(height: 4),
              for (final e
                  in (summary.perCategory.entries
                      .where((e) => e.value > 0)
                      .toList()
                    ..sort((x, y) => y.value.compareTo(x.value))))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Icon(e.key.icon, size: 16, color: e.key.color),
                      const SizedBox(width: 8),
                      Expanded(child: Text(e.key.label)),
                      Text(formatMinor(e.value, currency)),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _addCredit(BuildContext context, AppState app) async {
    final ctrl = TextEditingController();
    final amount = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cashback credited to ${card.name}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            LengthLimitingTextInputFormatter(14),
          ],
          decoration: const InputDecoration(labelText: 'Amount'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (amount == null || !context.mounted) return;
    await guarded(
      context,
      () => app.addCashbackCredit(
        cardId: card.id,
        amountMinor: parseAmountMinor(amount),
        date: DateTime.now(),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: t.textTheme.labelSmall?.copyWith(
            color: t.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(value, style: t.textTheme.titleSmall),
        ),
      ],
    );
  }
}
