import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/mock_data.dart';
import '../models/activity.dart';
import '../models/device.dart';
import '../theme/app_theme.dart';
import '../widgets/activity_timeline.dart';
import '../widgets/device_health_card.dart';
import '../widgets/distance_card.dart';
import '../widgets/time_range_toggle.dart';
import 'device_screen.dart';

/// Single-page V1 dashboard. The "today" tile is always locked to today's
/// data. Three trend charts below share a single time range toggle.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final MockDataSource _data = MockDataSource();
  late DeviceHealth _device;
  late DailyActivity _today;
  late List<DailyActivity> _last7;
  late List<DailyActivity> _last30;
  late List<WeeklyActivity> _last6M;

  TimeRange _selectedRange = TimeRange.day;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    _device = _data.currentDevice();
    _today = _data.today();
    _last7 = _data.last7Days();
    _last30 = _data.last30Days();
    _last6M = _data.last6Months();
  }

  void _openDeviceScreen() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DeviceScreen(device: _device),
      ),
    );
  }

  List<DailyActivity> get _activeDailyData =>
      _selectedRange == TimeRange.week ? _last7 : _last30;

  Widget _chartCard(ChartMetric metric) => TrendChartCard(
        metric: metric,
        timeRange: _selectedRange,
        todayHours: _today.hours,
        dailyData: _activeDailyData,
        weeklyData: _last6M,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 900;
            return SingleChildScrollView(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: isWide ? 48 : 20,
                      vertical: isWide ? 44 : 24,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Header(
                          device: _device,
                          onRefresh: () => setState(_refresh),
                        ),
                        const SizedBox(height: 10),
                        Padding(
                          padding: const EdgeInsets.only(left: 2),
                          child: DeviceStatusBar(
                            device: _device,
                            onTap: _openDeviceScreen,
                          ),
                        ),
                        const SizedBox(height: 28),
                        TodayCard(today: _today),
                        const SizedBox(height: 36),
                        // Trend section: toggle + charts
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              'Activity Trends',
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineMedium
                                  ?.copyWith(fontSize: 22),
                            ),
                            const Spacer(),
                            SizedBox(
                              width: 240,
                              child: TimeRangeToggle(
                                selected: _selectedRange,
                                onChanged: (r) =>
                                    setState(() => _selectedRange = r),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        _chartCard(ChartMetric.timeInMotion),
                        const SizedBox(height: 20),
                        if (isWide)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                  child: _chartCard(ChartMetric.distance)),
                              const SizedBox(width: 20),
                              Expanded(
                                  child: _chartCard(ChartMetric.steps)),
                            ],
                          )
                        else ...[
                          _chartCard(ChartMetric.distance),
                          const SizedBox(height: 20),
                          _chartCard(ChartMetric.steps),
                        ],
                        const SizedBox(height: 48),
                        const _Footer(),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.device, required this.onRefresh});

  final DeviceHealth device;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final dateLabel = DateFormat('EEEE, MMMM d').format(DateTime.now());

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppTheme.sage,
              borderRadius: BorderRadius.circular(13),
            ),
            child: const Icon(
              Icons.accessibility_new_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'GoSteady',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontSize: 26,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  dateLabel,
                  style: const TextStyle(
                    color: AppTheme.textSoft,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: OutlinedButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Refresh'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.sage,
                side: BorderSide(color: AppTheme.border.withOpacity(0.6)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(100),
                ),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          'GoSteady Portal  ·  V1 preview  ·  mock data',
          style: TextStyle(
            color: AppTheme.textSoft.withOpacity(0.6),
            fontSize: 12,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}
