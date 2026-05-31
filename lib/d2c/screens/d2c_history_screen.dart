import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../theme/app_theme.dart';
import '../d2c_routes.dart';
import '../data/d2c_mock_data.dart';
import '../widgets/d2c_bottom_nav.dart';

/// Activity History — the 30 / 90-day view behind the dashboard trend's
/// "See more". Drill-down from the Activity tab, so it keeps the bottom
/// nav with Activity active + a back arrow to the dashboard.
///
/// 30-day view shows daily bars; 90-day view aggregates into weekly bars
/// (13 weeks) so the chart stays readable. Summary stats adapt to the
/// selected range. Copy is person-centric ("Susan" / "you").
class D2CHistoryScreen extends StatefulWidget {
  const D2CHistoryScreen({super.key, this.isWalkerUser = false});

  final bool isWalkerUser;

  @override
  State<D2CHistoryScreen> createState() => _D2CHistoryScreenState();
}

class _D2CHistoryScreenState extends State<D2CHistoryScreen> {
  int _days = 30; // 30 or 90

  String get _who => widget.isWalkerUser ? 'You' : 'Susan';
  String get _whoLower => widget.isWalkerUser ? 'you' : 'Susan';

  @override
  Widget build(BuildContext context) {
    final all = D2CMockData.history(days: 90);
    final data = all.sublist(all.length - _days);
    final total = data.fold<int>(0, (a, d) => a + d.steps);
    final avg = (total / data.length).round();
    final best = data.reduce((a, b) => a.steps >= b.steps ? a : b);
    final activeDays = data.where((d) => d.steps > 100).length;

    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      appBar: AppBar(
        backgroundColor: AppTheme.warmWhite,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.textDark),
          onPressed: () => context.go(D2CRoutes.dashboard),
        ),
        title: Text(
          'History',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AppTheme.textDark,
              ),
        ),
      ),
      bottomNavigationBar: const D2CBottomNav(active: D2CTab.activity),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
            children: [
              _RangeToggle(
                days: _days,
                onChanged: (d) => setState(() => _days = d),
              ),
              const SizedBox(height: 22),
              _SummaryGrid(
                avg: avg,
                best: best,
                activeDays: activeDays,
                totalDays: data.length,
              ),
              const SizedBox(height: 12),
              _TrendNote(
                text: widget.isWalkerUser
                    ? "You're averaging ${NumberFormat('#,##0').format(avg)} "
                        'steps a day — trending up over the last $_days days.'
                    : '$_who is averaging ${NumberFormat('#,##0').format(avg)} '
                        'steps a day — trending up over the last $_days days.',
              ),
              const SizedBox(height: 24),
              _HistoryChartCard(data: data, days: _days),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Range toggle (30 / 90 days)
// ─────────────────────────────────────────────────────────────────────

class _RangeToggle extends StatelessWidget {
  const _RangeToggle({required this.days, required this.onChanged});
  final int days;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppTheme.cream,
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        children: [
          _seg('30 days', 30),
          _seg('90 days', 90),
        ],
      ),
    );
  }

  Widget _seg(String label, int value) {
    final active = days == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => onChanged(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: active ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(100),
            boxShadow: active ? AppTheme.cardShadow : null,
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: active ? AppTheme.sage : AppTheme.textSoft,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Summary grid
// ─────────────────────────────────────────────────────────────────────

class _SummaryGrid extends StatelessWidget {
  const _SummaryGrid({
    required this.avg,
    required this.best,
    required this.activeDays,
    required this.totalDays,
  });

  final int avg;
  final HistoryDay best;
  final int activeDays;
  final int totalDays;

  @override
  Widget build(BuildContext context) {
    final f = NumberFormat('#,##0');
    return Row(
      children: [
        Expanded(
          child: _cell('Daily average', '${f.format(avg)}', 'steps'),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _cell('Best day', f.format(best.steps),
              DateFormat('MMM d').format(best.date)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _cell('Active days', '$activeDays', 'of $totalDays'),
        ),
      ],
    );
  }

  Widget _cell(String label, String value, String sub) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(value,
              style: const TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3)),
          const SizedBox(height: 2),
          Text(sub,
              style: const TextStyle(
                  color: AppTheme.textSoft, fontSize: 11.5)),
        ],
      ),
    );
  }
}

class _TrendNote extends StatelessWidget {
  const _TrendNote({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          const Icon(Icons.trending_up_rounded, size: 15, color: AppTheme.sage),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AppTheme.sage,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// History chart — daily bars (30d) or weekly bars (90d)
// ─────────────────────────────────────────────────────────────────────

class _HistoryChartCard extends StatelessWidget {
  const _HistoryChartCard({required this.data, required this.days});
  final List<HistoryDay> data;
  final int days;

  /// For the 90-day view, collapse into weekly averages so the chart
  /// stays legible (~13 bars instead of 90).
  List<_Bar> _bars() {
    if (days <= 30) {
      return [
        for (final d in data)
          _Bar(value: d.steps, label: DateFormat('d').format(d.date)),
      ];
    }
    final weeks = <_Bar>[];
    for (var i = 0; i < data.length; i += 7) {
      final chunk = data.sublist(i, (i + 7).clamp(0, data.length));
      final avg =
          (chunk.fold<int>(0, (a, d) => a + d.steps) / chunk.length).round();
      weeks.add(_Bar(value: avg, label: DateFormat('M/d').format(chunk.first.date)));
    }
    return weeks;
  }

  @override
  Widget build(BuildContext context) {
    final bars = _bars();
    final maxVal = bars.map((b) => b.value).fold<int>(1, (a, b) => a > b ? a : b);
    final showEveryLabel = bars.length <= 16;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            days <= 30 ? 'Daily steps' : 'Weekly average steps',
            style: const TextStyle(
                color: AppTheme.textDark,
                fontSize: 14,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 130,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < bars.length; i++)
                  Expanded(
                    child: _ChartBar(
                      bar: bars[i],
                      maxVal: maxVal,
                      // Thin out labels on the dense daily view.
                      showLabel: showEveryLabel || i % 5 == 0,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Bar {
  const _Bar({required this.value, required this.label});
  final int value;
  final String label;
}

class _ChartBar extends StatelessWidget {
  const _ChartBar({
    required this.bar,
    required this.maxVal,
    required this.showLabel,
  });
  final _Bar bar;
  final int maxVal;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final h = (bar.value / maxVal) * 100.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1.5),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Container(
            height: h.clamp(2, 100),
            decoration: BoxDecoration(
              color: AppTheme.sage.withOpacity(0.55),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 14,
            child: showLabel
                ? FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      bar.label,
                      style: const TextStyle(
                          color: AppTheme.textSoft, fontSize: 9.5),
                    ),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}
