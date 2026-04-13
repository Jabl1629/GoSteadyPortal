import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/mock_data.dart';
import '../models/activity.dart';
import '../models/device.dart';
import '../theme/app_theme.dart';
import '../widgets/activity_timeline.dart';
import '../widgets/daily_history.dart';
import '../widgets/device_health_card.dart';
import '../widgets/distance_card.dart';

/// Single-page V1 dashboard. Responsive: desktop lays out side-by-side,
/// mobile stacks. No routing or tabs in V1 — caregivers land here and
/// see everything at once.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final MockDataSource _data = MockDataSource();
  late DeviceHealth _device;
  late DailyActivity _today;
  late List<DailyActivity> _history;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    _device = _data.currentDevice();
    _today = _data.today();
    _history = _data.last7Days();
  }

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
                  constraints: const BoxConstraints(maxWidth: 1180),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: isWide ? 40 : 20,
                      vertical: isWide ? 40 : 24,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Header(device: _device, onRefresh: () {
                          setState(_refresh);
                        }),
                        const SizedBox(height: 32),
                        if (isWide)
                          _WideLayout(
                            device: _device,
                            today: _today,
                            history: _history,
                          )
                        else
                          _NarrowLayout(
                            device: _device,
                            today: _today,
                            history: _history,
                          ),
                        const SizedBox(height: 40),
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

    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppTheme.sage,
            borderRadius: BorderRadius.circular(12),
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
        OutlinedButton.icon(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Refresh'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.sage,
            side: const BorderSide(color: AppTheme.border),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(100),
            ),
          ),
        ),
      ],
    );
  }
}

class _WideLayout extends StatelessWidget {
  const _WideLayout({
    required this.device,
    required this.today,
    required this.history,
  });

  final DeviceHealth device;
  final DailyActivity today;
  final List<DailyActivity> history;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: DistanceCard(today: today),
            ),
            const SizedBox(width: 24),
            Expanded(
              flex: 6,
              child: DeviceHealthCard(device: device),
            ),
          ],
        ),
        const SizedBox(height: 24),
        ActivityTimeline(today: today),
        const SizedBox(height: 24),
        DailyHistory(days: history),
      ],
    );
  }
}

class _NarrowLayout extends StatelessWidget {
  const _NarrowLayout({
    required this.device,
    required this.today,
    required this.history,
  });

  final DeviceHealth device;
  final DailyActivity today;
  final List<DailyActivity> history;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        DistanceCard(today: today),
        const SizedBox(height: 20),
        DeviceHealthCard(device: device),
        const SizedBox(height: 20),
        ActivityTimeline(today: today),
        const SizedBox(height: 20),
        DailyHistory(days: history),
      ],
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'GoSteady Portal · V1 preview · mock data',
        style: TextStyle(
          color: AppTheme.textSoft.withOpacity(0.8),
          fontSize: 12,
        ),
      ),
    );
  }
}
