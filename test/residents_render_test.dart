import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gosteady_portal/facility_demo/data/facility_mock_data.dart'
    show PatientRowStats, Trend;
import 'package:gosteady_portal/facility_demo/models/patient.dart';
import 'package:gosteady_portal/facility_demo/widgets/patient_list_view.dart';
import 'package:gosteady_portal/theme/app_theme.dart';

/// The internal Residents page reuses the Census [PatientListView] verbatim,
/// feeding it rows built from lightweight D2C patients (no room) and passing
/// `showSteps: false` (rollators report no steps) + `colorMetrics: false`
/// (active-minute bands not yet calibrated). These tests pin the reuse:
/// empty-room Location, dropped Steps columns, and plain-black active minutes —
/// plus the Census defaults (steps shown, colored, "· Rm N") as a regression.
PatientListRow _row({
  required String name,
  required String location,
  required String room,
  String? deviceSerial,
  int activeMinutesToday = 5, // "very low" band → colored red unless black
}) {
  return PatientListRow(
    patient: Patient(
      id: 'pat_$name',
      displayName: name,
      facilityId: '',
      unitId: '',
      room: room,
      deviceSerial: deviceSerial,
    ),
    unitDisplay: location,
    stats: PatientRowStats(
      alertsThisWeek: 0,
      activeMinutesToday: activeMinutesToday,
      activeMinutes7dAvg: 20,
      activeMinutesPrior7dAvg: 18,
      activeMinutesTrend7d: Trend.flat,
      activeMinutes30dAvg: 19,
      stepsToday: 1500,
      stepsTrend7d: Trend.up,
      stepsRecentAvg: 1400,
      stepsPriorAvg: 1200,
      gaitSpeed3dAvg: 2.1,
      gaitSpeedTrend: Trend.flat,
      gaitSpeedPriorAvg: 2.0,
    ),
    activeNotifications: const [],
  );
}

Future<void> _pump(
  WidgetTester tester,
  PatientListRow row, {
  bool showSteps = true,
  bool colorMetrics = true,
}) async {
  // Desktop width — the real use case (wide → flex columns absorb slack).
  await tester.binding.setSurfaceSize(const Size(1400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: PatientListView(
        rows: [row],
        selectedPatientId: null,
        onSelect: (_) {},
        showSteps: showSteps,
        colorMetrics: colorMetrics,
      ),
    ),
  ));
}

void main() {
  testWidgets(
      'internal: empty room → cap serial (no "· Rm"); no Steps cols; black active-min',
      (tester) async {
    await _pump(
      tester,
      _row(
          name: 'Dorothy Iupert',
          location: 'GS0002000002',
          room: '',
          deviceSerial: 'GS0002000002'),
      showSteps: false,
      colorMetrics: false,
    );
    // Location = cap serial, no dangling room.
    expect(find.text('Dorothy Iupert'), findsOneWidget);
    expect(find.text('GS0002000002'), findsOneWidget);
    expect(find.textContaining('Rm'), findsNothing);
    // Steps columns dropped (header + value).
    expect(find.text('Steps today'), findsNothing);
    expect(find.text('Step trend'), findsNothing);
    expect(find.text('1,500'), findsNothing);
    // Active-min still shown, but in plain black (not the "very low" red).
    final amText = tester.widget<Text>(find.text('5'));
    expect(amText.style?.color, AppTheme.textDark);
  });

  testWidgets('census defaults: Steps shown, "· Rm N" kept, active-min colored',
      (tester) async {
    await _pump(
      tester,
      _row(name: 'James Martinez', location: 'Memory Care', room: '17A'),
    );
    expect(find.text('James Martinez'), findsOneWidget);
    expect(find.textContaining('Rm 17A'), findsOneWidget);
    expect(find.text('Steps today'), findsOneWidget);
    // colorMetrics default → the "very low" active-min value is tinted red.
    final amText = tester.widget<Text>(find.text('5'));
    expect(amText.style?.color, AppTheme.statusAlert);
  });
}
