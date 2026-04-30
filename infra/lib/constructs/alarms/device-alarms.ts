import * as cdk from 'aws-cdk-lib/core';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cloudwatchActions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as sns from 'aws-cdk-lib/aws-sns';
import { Construct } from 'constructs';

/**
 * Device-Alarms — Phase 1.6.
 *
 * Per-device synthetic alerts that don't fit the standard Threshold
 * Detector path (battery / signal — those go through the
 * Shadow-delta-driven Lambda from 1B-rev). These are device-fleet-wide
 * alarms on the per-device EMF metrics emitted by heartbeat-processor
 * (Stage 2).
 *
 * Currently single alarm: `watchdog_hits` ≥3 within 24 h per serial.
 * Suggested by firmware coord §F5.2 as a "device unstable" signal once
 * the M10.7.3 stress-test path showed the metric is now actionable.
 *
 * Implementation note — the alarm uses metric math to compare current
 * `watchdog_hits` against the value 24 h prior, alerting if the delta
 * is ≥3. CloudWatch alarms support `metricRollingDelta` via metric math
 * expressions.
 *
 * v1 caveat — without a dimensioned `serial` filter on the alarm, this
 * fires when ANY single device crosses the threshold, but the alarm
 * notification doesn't say which serial. Operator inspects the
 * Per-Device dashboard to diagnose. Phase 2A custom widgets will swap
 * to per-serial alarms (one alarm per known serial) once the device
 * fleet is small + enumerable from Device Registry.
 */
export interface DeviceAlarmsProps {
  readonly env: string;
  readonly opsTopic: sns.ITopic;
}

export class DeviceAlarms extends Construct {
  constructor(scope: Construct, id: string, props: DeviceAlarmsProps) {
    super(scope, id);

    const { env, opsTopic } = props;
    const snsAction = new cloudwatchActions.SnsAction(opsTopic);

    // ── Watchdog hits ≥3/24h (firmware coord §F5.2) ─────────────
    // The metric's Maximum aggregation across the fleet captures the
    // largest watchdog_hits value any device reported in the period.
    // Alarm fires if max increases by ≥3 over a 24h window — a delta
    // signal, not an absolute one (since watchdog_hits is monotonically
    // increasing across boots; absolute threshold would fire forever
    // once breached).
    const m1 = new cloudwatch.Metric({
      namespace: `GoSteady/Devices/${env}`,
      metricName: 'WatchdogHits',
      statistic: 'Maximum',
      period: cdk.Duration.hours(1),
      label: 'watchdog_hits (max across fleet)',
    });

    const expression = new cloudwatch.MathExpression({
      // Diff of last 1 h max vs the 24-h offset value. Crossing +3 means
      // any single device fired ≥3 watchdogs in that window.
      expression: 'MAX([m1]) - MAX([m1_24h_ago])',
      usingMetrics: {
        m1,
        m1_24h_ago: m1.with({
          period: cdk.Duration.hours(1),
        }),
      },
      label: 'watchdog hits Δ over 24 h',
      period: cdk.Duration.hours(24),
    });

    const alarm = new cloudwatch.Alarm(this, 'WatchdogHitsRate', {
      alarmName: `gosteady-${env}-device-watchdog-hits-rate`,
      alarmDescription:
        'A device fleet member fired ≥3 watchdog resets within 24 h. ' +
        'Firmware coord §F5.2 suggested threshold for "device unstable" ' +
        'caregiver-side notice once Phase 2A lands. v1 routes to ops topic. ' +
        'Inspect the Per-Device dashboard with each known serial to find ' +
        'the offender; the firmware crash forensics path persists ' +
        'reset_reason / fault_counters across reset.',
      metric: expression,
      threshold: 3,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    alarm.addAlarmAction(snsAction);
  }
}
