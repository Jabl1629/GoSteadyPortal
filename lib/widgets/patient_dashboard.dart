import 'package:flutter/material.dart';

import '../models/activity.dart';
import '../models/device.dart';
import 'activity_timeline.dart';
import 'device_health_card.dart';
import 'distance_card.dart';
import 'time_range_toggle.dart';

/// Patient-data column: device status strip, today's headline tile, and
/// three trend charts driven by a single time-range toggle. This is the
/// reusable body of the dashboard — wrappers (the legacy single-walker
/// `DashboardScreen` and the facility demo's `PatientDetailView`) provide
/// their own surrounding chrome (header, layout container, scrolling).
class PatientDashboard extends StatefulWidget {
  const PatientDashboard({
    super.key,
    required this.device,
    required this.today,
    required this.last7,
    required this.last30,
    required this.last6Months,
    this.onDeviceTap,
  });

  final DeviceHealth device;
  final DailyActivity today;
  final List<DailyActivity> last7;
  final List<DailyActivity> last30;
  final List<WeeklyActivity> last6Months;
  final VoidCallback? onDeviceTap;

  @override
  State<PatientDashboard> createState() => _PatientDashboardState();
}

class _PatientDashboardState extends State<PatientDashboard> {
  TimeRange _selectedRange = TimeRange.day;

  List<DailyActivity> get _activeDailyData =>
      _selectedRange == TimeRange.week ? widget.last7 : widget.last30;

  Widget _chartCard(ChartMetric metric) => TrendChartCard(
        metric: metric,
        timeRange: _selectedRange,
        todayHours: widget.today.hours,
        dailyData: _activeDailyData,
        weeklyData: widget.last6Months,
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stackedHeader = constraints.maxWidth < 500;
        final trendsHeader = Text(
          'Activity Trends',
          style: Theme.of(context)
              .textTheme
              .headlineMedium
              ?.copyWith(fontSize: 22),
        );
        final toggle = TimeRangeToggle(
          selected: _selectedRange,
          onChanged: (r) => setState(() => _selectedRange = r),
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DeviceStatusBar(
              device: widget.device,
              onTap: widget.onDeviceTap ?? () {},
            ),
            const SizedBox(height: 24),
            TodayCard(today: widget.today),
            const SizedBox(height: 32),
            if (stackedHeader) ...[
              trendsHeader,
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: toggle,
              ),
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  trendsHeader,
                  const Spacer(),
                  SizedBox(width: 240, child: toggle),
                ],
              ),
            const SizedBox(height: 20),
            _chartCard(ChartMetric.timeInMotion),
            const SizedBox(height: 20),
            _chartCard(ChartMetric.distance),
            const SizedBox(height: 20),
            _chartCard(ChartMetric.steps),
            const SizedBox(height: 20),
            _chartCard(ChartMetric.gaitSpeed),
          ],
        );
      },
    );
  }
}
