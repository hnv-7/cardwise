import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/category.dart';
import '../services/analytics.dart';
import '../state/app_state.dart';
import '../util/money.dart';
import 'widgets.dart';

enum Period { thisCycle, last3, last6, all }

extension on Period {
  String get label => switch (this) {
    Period.thisCycle => 'This cycle',
    Period.last3 => '3 cycles',
    Period.last6 => '6 cycles',
    Period.all => 'All time',
  };

  /// Number of billing cycles to include (current one counts as 1).
  int? get cycles => switch (this) {
    Period.thisCycle => 1,
    Period.last3 => 3,
    Period.last6 => 6,
    Period.all => null,
  };
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

    final txns = a.transactionsInCycles(_period.cycles, now: now);
    final total = a.total(txns);
    final byCat = a.byCategory(txns).entries.toList()
      ..sort((x, y) => y.value.compareTo(x.value));
    final byCard = a.byCard(txns).entries.toList()
      ..sort((x, y) => y.value.compareTo(x.value));
    final trend = a.cycleTrend(a.transactions(), cycles: 6, now: now);
    final cashback = app.data.cards.fold<int>(
      0,
      (s, c) => s + a.cashbackFor(c).estimatedMinor,
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        SegmentedButton<Period>(
          showSelectedIcon: false,
          segments: [
            for (final p in Period.values)
              ButtonSegment(value: p, label: Text(p.label, maxLines: 1)),
          ],
          selected: {_period},
          onSelectionChanged: (s) => setState(() => _period = s.first),
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            padding: WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 4),
            ),
          ),
        ),
        const SizedBox(height: 12),
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
                label: 'Est. cashback (all time)',
                value: formatMinor(cashback, cur),
                hint: app.data.cards.isEmpty ? 'Add a card' : null,
              ),
            ),
          ],
        ),
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
          _CategoryChart(entries: byCat, total: total, currency: cur),
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

class _CategoryChart extends StatelessWidget {
  const _CategoryChart({
    required this.entries,
    required this.total,
    required this.currency,
  });
  final List<MapEntry<SpendCategory, int>> entries;
  final int total;
  final String currency;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            SizedBox(
              height: 180,
              child: PieChart(
                PieChartData(
                  sectionsSpace: 2,
                  centerSpaceRadius: 46,
                  sections: [
                    for (final e in entries)
                      PieChartSectionData(
                        value: e.value.toDouble(),
                        color: e.key.color,
                        radius: 36,
                        showTitle: false,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            for (final e in entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    CategoryAvatar(e.key, size: 30),
                    const SizedBox(width: 12),
                    Expanded(child: Text(e.key.label)),
                    Text(
                      formatMinor(e.value, currency),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    SizedBox(
                      width: 52,
                      child: Text(
                        '${(e.value * 100 / total).toStringAsFixed(0)}%',
                        textAlign: TextAlign.right,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
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
