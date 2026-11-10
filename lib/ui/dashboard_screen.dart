import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/category.dart';
import '../services/analytics.dart';
import '../state/app_state.dart';
import '../util/money.dart';
import 'transactions_screen.dart' show CategoryTransactionsScreen;
import 'widgets.dart';

enum Period { thisCycle, lastCycle, last3, last6, all }

extension on Period {
  String get label => switch (this) {
    Period.thisCycle => 'This cycle',
    Period.lastCycle => 'Last cycle',
    Period.last3 => '3 cycles',
    Period.last6 => '6 cycles',
    Period.all => 'All time',
  };

  /// Number of billing cycles to include.
  int? get cycles => switch (this) {
    Period.thisCycle => 1,
    Period.lastCycle => 1,
    Period.last3 => 3,
    Period.last6 => 6,
    Period.all => null,
  };

  /// How many cycles before the current one the window ends
  /// (0 = ends with the current cycle, 1 = ends with the last completed one).
  int get endAgo => this == Period.lastCycle ? 1 : 0;
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Period _period = Period.thisCycle;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final a = app.analytics;
    final cur = a.currency;
    final now = DateTime.now();

    if (app.data.transactions.isEmpty) {
      return EmptyState(
        icon: Icons.insights_outlined,
        title: 'No spending yet',
        body: app.sms.isSupported
            ? 'Tap "Scan messages" to find credit card alerts in your inbox, '
                  'or add a card first so transactions are matched to it.'
            : 'Copy your card alert messages and use the paste icon above to '
                  'import them.',
      );
    }

    final txns = a.transactionsInCycles(
      _period.cycles,
      now: now,
      endAgo: _period.endAgo,
    );
    final total = a.total(txns);
    final byCat = a.byCategory(txns).entries.toList()
      ..sort((x, y) => y.value.compareTo(x.value));
    final byCard = a.byCard(txns).entries.toList()
      ..sort((x, y) => y.value.compareTo(x.value));
    final trend = a.cycleTrend(a.transactions(), cycles: 6, now: now);
    final summaries = a.periodSummaries(
      _period.cycles,
      now: now,
      endAgo: _period.endAgo,
    );
    final cashback = summaries.fold<int>(0, (s, e) => s + e.cashbackMinor);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final p in Period.values)
              ChoiceChip(
                label: Text(p.label),
                selected: _period == p,
                onSelected: (_) => setState(() => _period = p),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Total spend',
                value: formatMinor(total, cur),
                hint: '${txns.length} transactions',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                label: 'Est. cashback',
                value: formatMinor(cashback, cur),
                hint: app.data.cards.isEmpty ? 'Add a card' : _period.label,
              ),
            ),
          ],
        ),
        if (app.data.cards.isNotEmpty) ...[
          SectionTitle('Spend & cashback by card \u00B7 ${_period.label}'),
          _CardSummaries(summaries: summaries, currency: cur),
        ],
        if (a.excludedForeignCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${a.excludedForeignCount} transaction(s) in other currencies '
              'are not included in totals.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const SectionTitle('By category'),
        if (byCat.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No spending in this period.'),
          )
        else
          _CategoryChart(
            entries: byCat,
            total: total,
            currency: cur,
            period: _period,
          ),
        const SectionTitle('Spend per billing cycle'),
        _TrendChart(trend: trend, currency: cur),
        const SectionTitle('By card'),
        if (byCard.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No spending in this period.'),
          )
        else
          _CardBreakdown(entries: byCard, total: total, currency: cur),
      ],
    );
  }
}

/// Spend and estimated cashback of each card for the selected period, over
/// that card's own billing cycles.
class _CardSummaries extends StatelessWidget {
  const _CardSummaries({required this.summaries, required this.currency});
  final List<CycleSummary> summaries;
  final String currency;

  static String _range(CycleSummary s) {
    final f = DateFormat('d MMM');
    return s.from == null
        ? 'Up to ${f.format(s.lastDay)}'
        : '${f.format(s.from!)} - ${f.format(s.lastDay)}';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final s in summaries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    CardDot(s.card),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.card.displayName,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(_range(s), style: text.bodySmall),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(formatMinor(s.spendMinor, currency)),
                        Text(
                          '+ ${formatMinor(s.cashbackMinor, currency)}',
                          style: text.bodySmall,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CategoryChart extends StatefulWidget {
  const _CategoryChart({
    required this.entries,
    required this.total,
    required this.currency,
    required this.period,
  });
  final List<MapEntry<SpendCategory, int>> entries;
  final int total;
  final String currency;
  final Period period;

  @override
  State<_CategoryChart> createState() => _CategoryChartState();
}

class _CategoryChartState extends State<_CategoryChart> {
  SpendCategory? _selected;

  void _open(SpendCategory c) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => CategoryTransactionsScreen(
        category: c,
        cycles: widget.period.cycles,
        endAgo: widget.period.endAgo,
        periodLabel: widget.period.label,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final entries = widget.entries;
    final total = widget.total;
    // Selection is dropped when its category disappears from the period.
    final selected = entries.any((e) => e.key == _selected) ? _selected : null;
    final selectedEntry = selected == null
        ? null
        : entries.firstWhere((e) => e.key == selected);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            SizedBox(
              height: 200,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  PieChart(
                    PieChartData(
                      sectionsSpace: 2,
                      centerSpaceRadius: 56,
                      pieTouchData: PieTouchData(
                        touchCallback: (event, response) {
                          if (event is! FlTapUpEvent) return;
                          final i =
                              response?.touchedSection?.touchedSectionIndex ??
                              -1;
                          setState(() {
                            if (i < 0 || i >= entries.length) {
                              _selected = null;
                            } else {
                              final c = entries[i].key;
                              _selected = c == selected ? null : c;
                            }
                          });
                        },
                      ),
                      sections: [
                        for (final e in entries)
                          PieChartSectionData(
                            value: e.value.toDouble(),
                            color: e.key.color,
                            radius: e.key == selected ? 48 : 36,
                            showTitle: false,
                          ),
                      ],
                    ),
                  ),
                  IgnorePointer(
                    child: SizedBox(
                      width: 96,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (selectedEntry != null)
                            Icon(
                              selectedEntry.key.icon,
                              size: 20,
                              color: selectedEntry.key.color,
                            ),
                          Text(
                            selectedEntry?.key.label ?? 'Total',
                            style: text.labelMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            formatMinorCompact(
                              selectedEntry?.value ?? total,
                              widget.currency,
                            ),
                            style: text.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (selectedEntry != null)
                            Text(
                              '${(selectedEntry.value * 100 / total).toStringAsFixed(0)}%',
                              style: text.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (selected != null)
              TextButton.icon(
                onPressed: () => _open(selected),
                icon: const Icon(Icons.list_alt_outlined),
                label: Text('View ${selected.label} spends'),
              )
            else
              Text('Tap a slice or a category below', style: text.bodySmall),
            const SizedBox(height: 4),
            for (final e in entries)
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _open(e.key),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: e.key == selected
                        ? e.key.color.withValues(alpha: 0.12)
                        : null,
                  ),
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 4,
                  ),
                  child: Row(
                    children: [
                      CategoryAvatar(e.key, size: 30),
                      const SizedBox(width: 12),
                      Expanded(child: Text(e.key.label)),
                      Text(
                        formatMinor(e.value, widget.currency),
                        style: text.bodyMedium,
                      ),
                      SizedBox(
                        width: 52,
                        child: Text(
                          '${(e.value * 100 / total).toStringAsFixed(0)}%',
                          textAlign: TextAlign.right,
                          style: text.bodySmall,
                        ),
                      ),
                      const Icon(Icons.chevron_right, size: 18),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TrendChart extends StatelessWidget {
  const _TrendChart({required this.trend, required this.currency});
  final List<(MonthKey, int)> trend;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxV = trend.fold<int>(0, (m, e) => e.$2 > m ? e.$2 : m);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 20, 16, 12),
        child: SizedBox(
          height: 200,
          child: maxV == 0
              ? const Center(
                  child: Text('No spending in the last 6 billing cycles.'),
                )
              : BarChart(
                  BarChartData(
                    maxY: maxV * 1.15,
                    gridData: FlGridData(
                      drawVerticalLine: false,
                      getDrawingHorizontalLine: (_) => FlLine(
                        color: scheme.outlineVariant.withValues(alpha: 0.5),
                        strokeWidth: 1,
                      ),
                    ),
                    borderData: FlBorderData(show: false),
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
                          getTitlesWidget: (v, meta) {
                            final i = v.toInt();
                            if (i < 0 || i >= trend.length) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                DateFormat.MMM().format(trend[i].$1.start),
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    barTouchData: BarTouchData(
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipItem: (group, gi, rod, ri) => BarTooltipItem(
                          formatMinor(rod.toY.round(), currency),
                          TextStyle(
                            color: scheme.onInverseSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    barGroups: [
                      for (var i = 0; i < trend.length; i++)
                        BarChartGroupData(
                          x: i,
                          barRods: [
                            BarChartRodData(
                              toY: trend[i].$2.toDouble(),
                              color: scheme.primary,
                              width: 22,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(6),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

class _CardBreakdown extends StatelessWidget {
  const _CardBreakdown({
    required this.entries,
    required this.total,
    required this.currency,
  });
  final List<MapEntry<String?, int>> entries;
  final int total;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            for (final e in entries)
              Builder(
                builder: (context) {
                  final card = app.cardById(e.key);
                  final color = card == null
                      ? Theme.of(context).colorScheme.outline
                      : Color(card.colorValue);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CardDot(card),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                card?.displayName ?? 'Unassigned',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(formatMinor(e.value, currency)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: total == 0 ? 0 : e.value / total,
                            minHeight: 8,
                            color: color,
                            backgroundColor: color.withValues(alpha: 0.15),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
