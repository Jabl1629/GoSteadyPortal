// Locks the DT-4 WS1 per-device-type rendering contract so neither form factor
// regresses: the walker (Glide, walker_cap) stays steps-led, the rollator
// (rollator_platform) leads on active-minutes and NEVER renders steps (a
// frame-mount IMU produces none — coord §C52), and an absent/unknown
// deviceType falls back to walker_cap (DT-0 D9). Coord §C54/§C55.
import 'package:flutter_test/flutter_test.dart';
import 'package:gosteady_portal/d2c/rendering/metric_registry.dart';

void main() {
  group('deviceTypeView — walker_cap (Glide)', () {
    final v = deviceTypeView('walker_cap');
    test('leads on steps', () {
      expect(v.hero, ActivityMetric.steps);
    });
    test('stat row is steps-first', () {
      expect(v.statRow.first, ActivityMetric.steps);
      expect(v.statRow, contains(ActivityMetric.steps));
    });
  });

  group('deviceTypeView — rollator_platform', () {
    final v = deviceTypeView('rollator_platform');
    test('leads on active-minutes', () {
      expect(v.hero, ActivityMetric.activeMinutes);
    });
    test('NEVER renders steps', () {
      expect(v.statRow, isNot(contains(ActivityMetric.steps)));
    });
    test('shows active-minutes + distance + gait', () {
      expect(
        v.statRow,
        containsAll(<ActivityMetric>[
          ActivityMetric.activeMinutes,
          ActivityMetric.distanceFt,
          ActivityMetric.gaitSpeedFts,
        ]),
      );
    });
  });

  group('deviceTypeView — fallback reads as walker_cap (DT-0 D9)', () {
    for (final t in <String?>[null, '', 'some_future_type']) {
      test('deviceType=$t → walker_cap, steps-led', () {
        final v = deviceTypeView(t);
        expect(v.deviceType, 'walker_cap');
        expect(v.hero, ActivityMetric.steps);
      });
    }
  });
}
