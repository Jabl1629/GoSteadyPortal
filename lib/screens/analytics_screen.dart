import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../api/api_models.dart';
import '../data/analytics_repository.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// Internal user & population analytics (docs/specs/user-analytics.md).
///
/// internal_admin + internal_support may view (read-only, cross-tenant). Route
/// is gated to internal roles (app_router.dart); the analytics-api enforces
/// server-side too. Five metrics: session offloads, logins, SMS-OTP
/// abandonment, active-time (coarse proxy), and Steady Coach interactions.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

typedef _Bundle = ({AnalyticsOverview overview, AnalyticsUsersResponse users});

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  AnalyticsRepository? _repo;
  Future<_Bundle>? _future;
  String _range = '7d';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_repo == null) {
      final ApiClient? api = AppState.of(context).apiClient;
      _repo = api != null ? LiveAnalyticsRepository(api) : MockAnalyticsRepository();
      _future = _load();
    }
  }

  Future<_Bundle> _load() async {
    final results = await Future.wait([
      _repo!.overview(_range),
      _repo!.users(_range),
    ]);
    return (
      overview: results[0] as AnalyticsOverview,
      users: results[1] as AnalyticsUsersResponse,
    );
  }

  void _refresh() => setState(() => _future = _load());

  void _setRange(String r) {
    if (r == _range) return;
    setState(() {
      _range = r;
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = AppState.of(context).auth;
    return Scaffold(
      backgroundColor: AppTheme.cream,
      appBar: AppBar(
        title: const Text('Analytics — internal'),
        actions: [
          TextButton.icon(
            onPressed: () => context.go('/residents'),
            icon: const Icon(Icons.groups_outlined, size: 18),
            label: const Text('Residents'),
            style: TextButton.styleFrom(foregroundColor: AppTheme.textSoft),
          ),
          TextButton.icon(
            onPressed: () => context.go('/fleet'),
            icon: const Icon(Icons.dns_outlined, size: 18),
            label: const Text('Fleet'),
            style: TextButton.styleFrom(foregroundColor: AppTheme.textSoft),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => auth.signOut(),
          ),
        ],
      ),
      body: FutureBuilder<_Bundle>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
                child: CircularProgressIndicator(color: AppTheme.sage));
          }
          if (snap.hasError) {
            return _ErrorPanel(error: snap.error, onRetry: _refresh);
          }
          final data = snap.data!;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: ConstrainedBox(
                // Wide enough for the full 11-col per-user table; the table also
                // scrolls (visible scrollbar) on narrower viewports.
                constraints: const BoxConstraints(maxWidth: 1240),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _RangeToggle(range: _range, onChanged: _setRange),
                    const SizedBox(height: 8),
                    _RetentionNote(overview: data.overview),
                    const SizedBox(height: 16),
                    _KpiGrid(overview: data.overview),
                    const SizedBox(height: 20),
                    _OffloadChartCard(offloads: data.overview.offloads),
                    const SizedBox(height: 20),
                    _UsersTable(response: data.users),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── Range toggle ────────────────────────────────────────────────────────

class _RangeToggle extends StatelessWidget {
  final String range;
  final ValueChanged<String> onChanged;
  const _RangeToggle({required this.range, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const opts = ['24h', '7d', '30d'];
    return Wrap(spacing: 8, children: [
      for (final o in opts)
        ChoiceChip(
          label: Text(o),
          selected: range == o,
          onSelected: (_) => onChanged(o),
          selectedColor: AppTheme.sage.withOpacity(0.18),
          labelStyle: TextStyle(
            color: range == o ? AppTheme.sage : AppTheme.textSoft,
            fontWeight: FontWeight.w600,
          ),
          backgroundColor: AppTheme.warmWhite,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(100),
            side: BorderSide(color: AppTheme.border),
          ),
        ),
    ]);
  }
}

class _RetentionNote extends StatelessWidget {
  final AnalyticsOverview overview;
  const _RetentionNote({required this.overview});

  @override
  Widget build(BuildContext context) {
    final partial = overview.insightsStatus != 'Complete' &&
        overview.insightsStatus.isNotEmpty;
    return Row(children: [
      Icon(Icons.info_outline, size: 14, color: AppTheme.textSoft),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          'Login / OTP / active-time populate from the deploy date forward '
          '(no backfill).${partial ? '  ⚠ Audit query ${overview.insightsStatus} — numbers may be partial.' : ''}',
          style: TextStyle(color: AppTheme.textSoft, fontSize: 12),
        ),
      ),
    ]);
  }
}

// ── KPI cards ───────────────────────────────────────────────────────────

class _KpiGrid extends StatelessWidget {
  final AnalyticsOverview o;
  const _KpiGrid({required AnalyticsOverview overview}) : o = overview;

  @override
  Widget build(BuildContext context) {
    final byMethod = o.loginsByMethod;
    String methodSub() {
      if (byMethod.isEmpty) return 'no logins yet';
      final parts = <String>[];
      byMethod.forEach((k, v) => parts.add('${_methodShort(k)} $v'));
      return parts.join(' · ');
    }

    final rate = o.otp.abandonmentRate;
    return Wrap(
      spacing: 14,
      runSpacing: 14,
      children: [
        _KpiCard(
          label: 'Logins',
          value: '${o.loginsTotal}',
          sub: methodSub(),
          color: AppTheme.sage,
        ),
        _KpiCard(
          label: 'OTP abandoned',
          value: rate == null ? '—' : '${(rate * 100).toStringAsFixed(0)}%',
          sub: '${o.otp.abandoned} of ${o.otp.requested} requests'
              '${o.otp.verifyFailed > 0 ? ' · ${o.otp.verifyFailed} bad codes' : ''}',
          color: rate != null && rate >= 0.3
              ? AppTheme.statusAlert
              : AppTheme.statusWarn,
        ),
        _KpiCard(
          label: 'Active users',
          value: '${o.activeUsers}',
          sub: 'avg ${o.avgSessionMinutes.toStringAsFixed(1)}m / session',
          color: AppTheme.statusOk,
        ),
        _KpiCard(
          label: 'Session offloads',
          value: '${o.offloads.total}',
          sub: 'over ${o.range}${o.offloadTruncated ? ' · truncated' : ''}',
          color: const Color(0xFF5A8E6A),
        ),
        _KpiCard(
          label: 'Coach turns',
          value: '${o.coachTurns}',
          sub: '${o.coachActiveUsers} users',
          color: const Color(0xFF4A7C8E),
        ),
      ],
    );
  }
}

class _KpiCard extends StatelessWidget {
  final String label, value, sub;
  final Color color;
  const _KpiCard({
    required this.label,
    required this.value,
    required this.sub,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.warmWhite,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        border: Border.all(color: AppTheme.border),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6)),
          const SizedBox(height: 8),
          Text(value,
              style: TextStyle(
                  color: color, fontSize: 30, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(sub,
              style: TextStyle(color: AppTheme.textSoft, fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

String _methodShort(String m) {
  switch (m) {
    case 'sms_otp':
      return 'sms';
    case 'qr_relogin':
      return 'qr';
    case 'password':
      return 'pw';
    default:
      return m;
  }
}

// ── Offload chart (per-day / per-hour) ──────────────────────────────────

class _OffloadChartCard extends StatefulWidget {
  final OffloadBuckets offloads;
  const _OffloadChartCard({required this.offloads});

  @override
  State<_OffloadChartCard> createState() => _OffloadChartCardState();
}

class _OffloadChartCardState extends State<_OffloadChartCard> {
  bool _byHour = false;

  @override
  Widget build(BuildContext context) {
    final buckets = _byHour ? widget.offloads.perHour : widget.offloads.perDay;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      decoration: BoxDecoration(
        color: AppTheme.warmWhite,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        border: Border.all(color: AppTheme.border),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text('Session offloads',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Day')),
                ButtonSegment(value: true, label: Text('Hour')),
              ],
              selected: {_byHour},
              onSelectionChanged: (s) => setState(() => _byHour = s.first),
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text(_byHour ? 'By hour of day (UTC)' : 'By day',
              style: TextStyle(color: AppTheme.textSoft, fontSize: 12)),
          const SizedBox(height: 18),
          SizedBox(
            height: 200,
            child: buckets.isEmpty
                ? Center(
                    child: Text('No offloads in this range',
                        style: TextStyle(color: AppTheme.textSoft)))
                : _BarChart(buckets: buckets, byHour: _byHour),
          ),
        ],
      ),
    );
  }
}

class _BarChart extends StatelessWidget {
  final List<AnalyticsBucket> buckets;
  final bool byHour;
  const _BarChart({required this.buckets, required this.byHour});

  @override
  Widget build(BuildContext context) {
    final maxVal = buckets
        .map((b) => b.count)
        .fold<int>(0, (m, v) => v > m ? v : m)
        .toDouble();
    final yMax = _niceMax(maxVal);
    final interval = byHour ? 3 : 1;
    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceBetween,
        maxY: yMax,
        minY: 0,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: yMax / 4,
          getDrawingHorizontalLine: (v) => FlLine(
              color: AppTheme.border.withOpacity(0.45),
              strokeWidth: 1,
              dashArray: const [6, 4]),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 34,
              interval: yMax / 4,
              getTitlesWidget: (value, _) {
                if (value == 0) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(value.round().toString(),
                      style: _axisStyle),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 26,
              interval: 1,
              getTitlesWidget: (value, _) {
                final i = value.toInt();
                if (i < 0 || i >= buckets.length) {
                  return const SizedBox.shrink();
                }
                if (i % interval != 0) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_label(buckets[i].label), style: _axisStyle),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => AppTheme.textDark,
            tooltipRoundedRadius: 10,
            getTooltipItem: (group, _, rod, __) {
              final i = group.x;
              if (i < 0 || i >= buckets.length) return null;
              final b = buckets[i];
              return BarTooltipItem(
                '${_fullLabel(b.label)}\n${b.count} offload${b.count == 1 ? '' : 's'}',
                const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    height: 1.4),
              );
            },
          ),
        ),
        barGroups: List.generate(buckets.length, (i) {
          final y = buckets[i].count.toDouble();
          return BarChartGroupData(x: i, barRods: [
            BarChartRodData(
              toY: y,
              width: byHour ? 8 : 22,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(4),
              ),
              gradient: y > 0
                  ? const LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Color(0xFF5A8E6A), Color(0xFF72A883)],
                    )
                  : null,
              color: y > 0 ? null : AppTheme.border.withOpacity(0.3),
            ),
          ]);
        }),
      ),
    );
  }

  String _label(String raw) {
    if (byHour) {
      final h = int.tryParse(raw) ?? 0;
      if (h == 0) return '12a';
      if (h < 12) return '${h}a';
      if (h == 12) return '12p';
      return '${h - 12}p';
    }
    // date "2026-07-21" → "7/21"
    final parts = raw.split('-');
    if (parts.length == 3) {
      return '${int.tryParse(parts[1]) ?? parts[1]}/${int.tryParse(parts[2]) ?? parts[2]}';
    }
    return raw;
  }

  String _fullLabel(String raw) => byHour ? '${_label(raw)} (UTC)' : raw;
}

const _axisStyle = TextStyle(
  color: AppTheme.textSoft,
  fontSize: 11,
  fontWeight: FontWeight.w400,
);

double _niceMax(double raw) {
  if (raw <= 0) return 4;
  final padded = raw * 1.15;
  final steps = [4, 5, 10, 20, 50, 100, 200, 500, 1000];
  final m = steps.firstWhere((s) => padded <= s, orElse: () => 1000);
  return m.toDouble();
}

// ── Per-user table ──────────────────────────────────────────────────────

class _UsersTable extends StatefulWidget {
  final AnalyticsUsersResponse response;
  const _UsersTable({required this.response});

  @override
  State<_UsersTable> createState() => _UsersTableState();
}

class _UsersTableState extends State<_UsersTable> {
  final ScrollController _hCtrl = ScrollController();
  _UserSegment _segment = _UserSegment.all;

  @override
  void dispose() {
    _hCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.response.users;
    // Walker user vs non-walker Care Circle member (the authoritative
    // isWalkerUser flag). The metrics below re-total for the chosen segment.
    final rows = switch (_segment) {
      _UserSegment.all => all,
      _UserSegment.walker => all.where((u) => u.isWalkerUser).toList(),
      _UserSegment.care => all.where((u) => !u.isWalkerUser).toList(),
    };
    int total(int Function(AnalyticsUserRow) f) =>
        rows.fold(0, (s, r) => s + f(r));
    final label = switch (_segment) {
      _UserSegment.all => rows.length == 1 ? 'user' : 'users',
      _UserSegment.walker => rows.length == 1 ? 'walker' : 'walkers',
      _UserSegment.care => 'in care circle',
    };

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.warmWhite,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        border: Border.all(color: AppTheme.border),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
            child: Row(children: [
              Text('Per-user',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(width: 10),
              Text('${rows.length} $label',
                  style: TextStyle(color: AppTheme.textSoft, fontSize: 13)),
              const Spacer(),
              SegmentedButton<_UserSegment>(
                segments: const [
                  ButtonSegment(value: _UserSegment.all, label: Text('All')),
                  ButtonSegment(
                      value: _UserSegment.walker, label: Text('Walkers')),
                  ButtonSegment(
                      value: _UserSegment.care, label: Text('Care circle')),
                ],
                selected: {_segment},
                onSelectionChanged: (s) => setState(() => _segment = s.first),
                showSelectedIcon: false,
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStatePropertyAll(const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ),
            ]),
          ),
          // Segment totals — the walker-vs-care-circle aggregate at a glance.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 10),
            child: Wrap(spacing: 18, runSpacing: 4, children: [
              _SegStat(label: 'logins', value: total((r) => r.logins)),
              _SegStat(
                  label: 'OTP abandoned', value: total((r) => r.otpAbandoned)),
              _SegStat(label: 'active min', value: total((r) => r.activeMinutes)),
              _SegStat(label: 'coach', value: total((r) => r.coachTurns)),
              _SegStat(
                  label: 'app-active',
                  value: rows.where((r) => r.lastActive != null).length),
              if (_segment == _UserSegment.all &&
                  widget.response.unattributedOffloads > 0)
                _SegStat(
                    label: 'unattributed offloads',
                    value: widget.response.unattributedOffloads),
            ]),
          ),
          // Explicit controller + always-visible thumb so any overflow on a
          // narrow viewport reads as "scrollable", never a silent clip.
          Scrollbar(
            controller: _hCtrl,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _hCtrl,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                children: [
                  const _UserHeaderRow(),
                  if (rows.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text('No users in this segment',
                          style: TextStyle(color: AppTheme.textSoft)),
                    ),
                  for (final r in rows) _UserRow(row: r),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Walker-vs-care-circle segment for the per-user table.
enum _UserSegment { all, walker, care }

/// One "N label" chip in the segment-totals row.
class _SegStat extends StatelessWidget {
  const _SegStat({required this.label, required this.value});
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Text.rich(TextSpan(children: [
      TextSpan(
          text: '$value ',
          style: TextStyle(
              color: AppTheme.textDark,
              fontSize: 12.5,
              fontWeight: FontWeight.w700)),
      TextSpan(
          text: label,
          style: TextStyle(color: AppTheme.textSoft, fontSize: 12.5)),
    ]));
  }
}

// Widths tuned so the full 11-col row + gaps + 40px padding (~1166px) fits
// inside the 1240px page card; narrower viewports scroll (visible scrollbar).
const _colGap = 14.0;
const _wUser = 150.0;
const _wClient = 116.0;
const _wRole = 110.0;
const _wDevice = 118.0;
const _wDevSeen = 86.0;
const _wNum = 64.0;
const _wSeen = 86.0; // "APP ACTIVE" (user in-app activity)

class _UserHeaderRow extends StatelessWidget {
  const _UserHeaderRow();

  @override
  Widget build(BuildContext context) {
    Widget h(String s, double w, {TextAlign align = TextAlign.left}) => SizedBox(
          width: w,
          child: Text(s,
              textAlign: align,
              style: TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3)),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
            top: BorderSide(color: AppTheme.border),
            bottom: BorderSide(color: AppTheme.border)),
      ),
      child: Row(spacing: _colGap, children: [
        h('USER', _wUser),
        h('CLIENT', _wClient),
        h('ROLE', _wRole),
        h('DEVICE', _wDevice),
        h('DEVICE SEEN', _wDevSeen, align: TextAlign.right),
        h('LOGINS', _wNum, align: TextAlign.right),
        h('OTP ABND', _wNum, align: TextAlign.right),
        h('ACTIVE m', _wNum, align: TextAlign.right),
        h('OFFLOADS', _wNum, align: TextAlign.right),
        h('COACH', _wNum, align: TextAlign.right),
        h('APP ACTIVE', _wSeen, align: TextAlign.right),
      ]),
    );
  }
}

class _UserRow extends StatelessWidget {
  final AnalyticsUserRow row;
  const _UserRow({required this.row});

  @override
  Widget build(BuildContext context) {
    Widget num(int v, double w, {Color? color}) => SizedBox(
          width: w,
          child: Text('$v',
              textAlign: TextAlign.right,
              style: TextStyle(
                  color: color ?? AppTheme.textDark,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        border:
            Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.6))),
      ),
      child: Row(spacing: _colGap, children: [
        SizedBox(
          width: _wUser,
          child: Text(row.userId,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: AppTheme.textDark)),
        ),
        SizedBox(
          width: _wClient,
          child: Text(row.clientId.isEmpty ? '—' : row.clientId,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: AppTheme.textSoft)),
        ),
        SizedBox(
          width: _wRole,
          child: Text(row.role.isEmpty ? '—' : row.role.replaceAll('_', ' '),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppTheme.textSoft, fontSize: 12)),
        ),
        SizedBox(
          width: _wDevice,
          child: Text(row.deviceSerial.isEmpty ? '—' : row.deviceSerial,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontFamily: row.deviceSerial.isEmpty ? null : 'monospace',
                  fontSize: 12,
                  color: row.deviceSerial.isEmpty
                      ? AppTheme.textSoft
                      : AppTheme.textDark)),
        ),
        // DEVICE SEEN — the device's real last heartbeat (registry lastSeen),
        // stale >24h → offline color. '—' when the user has no device.
        SizedBox(
          width: _wDevSeen,
          child: Text(
            row.deviceSerial.isEmpty ? '—' : _ageLabel(row.deviceLastSeen),
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: row.deviceSerial.isEmpty
                  ? AppTheme.textSoft
                  : (_isStale(row.deviceLastSeen)
                      ? AppTheme.statusOffline
                      : AppTheme.statusOk),
            ),
          ),
        ),
        num(row.logins, _wNum),
        num(row.otpAbandoned, _wNum,
            color: row.otpAbandoned > 0 ? AppTheme.statusWarn : null),
        num(row.activeMinutes, _wNum),
        num(row.offloads, _wNum),
        num(row.coachTurns, _wNum),
        SizedBox(
          width: _wSeen,
          child: Text(_ageLabel(row.lastActive),
              textAlign: TextAlign.right,
              style: TextStyle(color: AppTheme.textSoft, fontSize: 12)),
        ),
      ]),
    );
  }
}

// ── Error panel + helpers ───────────────────────────────────────────────

class _ErrorPanel extends StatelessWidget {
  final Object? error;
  final VoidCallback onRetry;
  const _ErrorPanel({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final e = error;
    final msg =
        e is ApiException ? '${e.code} (${e.httpStatus}): ${e.message}' : '$e';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: AppTheme.statusAlert, size: 40),
          const SizedBox(height: 12),
          Text('Could not load analytics',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(msg,
              style: TextStyle(
                  color: AppTheme.textSoft, fontFamily: 'monospace')),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

String _ageLabel(DateTime? t) {
  if (t == null) return 'never';
  final s = DateTime.now().difference(t).inSeconds;
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m';
  if (s < 86400) return '${s ~/ 3600}h';
  return '${s ~/ 86400}d';
}

// A device not heard from in >24h is stale/offline (mirrors the fleet board).
bool _isStale(DateTime? t) =>
    t == null || DateTime.now().difference(t) > const Duration(hours: 24);
