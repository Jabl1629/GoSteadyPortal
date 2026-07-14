import * as cdk from 'aws-cdk-lib/core';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import { Construct } from 'constructs';

/**
 * Fleet-Health Dashboard — device fleet ops tooling (2026-07-12).
 *
 * Passive "is my whole fleet healthy" view for the pilot operator — sibling to
 * the Per-Device Detail dashboard (single serial) and Platform Health (cloud
 * pipeline). Every device panel is a SEARCH expression over the per-device EMF
 * metrics (`GoSteady/Devices/{env}`, dimensioned by serial), so NEW units
 * appear automatically with no per-serial redeploy. Complements `tools/fleet.py`:
 *   - Dashboard = passive glance (battery / signal / who's-reporting / stuck).
 *   - CLI       = active status board + commands + readiness gates.
 *
 * Lifecycle-STATE counts (ready_to_provision / provisioned / active_monitoring
 * / discontinued) are intentionally NOT here: they live in the Device Registry
 * (DynamoDB), which a CloudWatch dashboard can't query. Run `fleet ls` for the
 * state board. This dashboard shows the telemetry- and audit-derived health
 * that IS in CloudWatch. Spec: docs/specs/device-fleet-ops-tooling.md.
 */
export interface FleetHealthDashboardProps {
  readonly env: string;
}

export class FleetHealthDashboard extends Construct {
  public readonly dashboard: cloudwatch.Dashboard;

  constructor(scope: Construct, id: string, props: FleetHealthDashboardProps) {
    super(scope, id);

    const { env } = props;
    const devNs = `GoSteady/Devices/${env}`;
    const auditNs = `GoSteady/Audit/${env}`;

    this.dashboard = new cloudwatch.Dashboard(this, 'Dashboard', {
      dashboardName: `gosteady-${env}-fleet-health`,
      defaultInterval: cdk.Duration.hours(24),
    });

    // ── Header ──────────────────────────────────────────────────
    this.dashboard.addWidgets(
      new cloudwatch.TextWidget({
        markdown:
          `# GoSteady Fleet Health — ${env}\n` +
          'Passive telemetry view across **all** devices (per-serial lines via ' +
          'CloudWatch SEARCH — new units appear automatically).\n\n' +
          'Lifecycle **state** (ready / provisioned / active / discontinued) is not ' +
          'here — CloudWatch cannot read the Device Registry. Run **`tools/fleet.py ls`** ' +
          'for the state board + the `status` / `check` / `ready` gates.\n\n' +
          'Single-device drill-down: **gosteady-' + env + '-per-device**. ' +
          'Spec: [`docs/specs/device-fleet-ops-tooling.md`](../../docs/specs/device-fleet-ops-tooling.md).',
        width: 24,
        height: 4,
      }),
    );

    // ── Battery + heartbeat recency ─────────────────────────────
    // SEARCH auto-labels one line per serial; a device that stops heartbeating
    // flat-lines (battery) / drops to zero samples (recency) — the operator's
    // "who's alive / whose batteries need swapping" glance.
    this.dashboard.addWidgets(
      new cloudwatch.GraphWidget({
        title: 'Battery % — all devices',
        width: 12,
        height: 6,
        left: [
          new cloudwatch.MathExpression({
            expression: `SEARCH('{${devNs},serial,service} MetricName="BatteryPct"', 'Average', 300)`,
            usingMetrics: {},
            period: cdk.Duration.minutes(5),
          }),
        ],
        leftYAxis: { min: 0, max: 1 },
        leftAnnotations: [
          { value: 0.1, color: cloudwatch.Color.ORANGE, label: 'battery_low (P1)' },
          { value: 0.05, color: cloudwatch.Color.RED, label: 'battery_critical (P1)' },
        ],
      }),
      new cloudwatch.GraphWidget({
        title: 'Heartbeats / 5 min — all devices (flat-to-zero = silent)',
        width: 12,
        height: 6,
        left: [
          new cloudwatch.MathExpression({
            expression: `SEARCH('{${devNs},serial,service} MetricName="BatteryPct"', 'SampleCount', 300)`,
            usingMetrics: {},
            period: cdk.Duration.minutes(5),
          }),
        ],
        leftAnnotations: [
          { value: 1, color: cloudwatch.Color.GREEN, label: 'reporting' },
        ],
      }),
    );

    // ── Signal + stability ──────────────────────────────────────
    this.dashboard.addWidgets(
      new cloudwatch.GraphWidget({
        title: 'Signal RSRP (dBm) — all devices',
        width: 12,
        height: 6,
        left: [
          new cloudwatch.MathExpression({
            expression: `SEARCH('{${devNs},serial,service} MetricName="RsrpDbm"', 'Average', 300)`,
            usingMetrics: {},
            period: cdk.Duration.minutes(5),
          }),
        ],
        leftAnnotations: [
          { value: -110, color: cloudwatch.Color.ORANGE, label: 'signal_weak (P2)' },
          { value: -120, color: cloudwatch.Color.RED, label: 'signal_lost (P2)' },
        ],
      }),
      new cloudwatch.GraphWidget({
        title: 'Watchdog hits — all devices (max)',
        width: 12,
        height: 6,
        left: [
          new cloudwatch.MathExpression({
            expression: `SEARCH('{${devNs},serial,service} MetricName="WatchdogHits"', 'Maximum', 3600)`,
            usingMetrics: {},
            period: cdk.Duration.hours(1),
          }),
        ],
        leftAnnotations: [
          { value: 3, color: cloudwatch.Color.ORANGE, label: 'unstable ≥3/24h (firmware §F5.2)' },
        ],
      }),
    );

    // ── Stuck signals (lifecycle-ack health) ────────────────────
    // Audit-derived fleet counts (GoSteady/Audit/{env}, emitted by the
    // metric filters in the Api stack). These are the two ways a device
    // silently stalls mid-lifecycle in a pilot:
    //   sent - acked      > 0 → provisioned but never activated (stuck).
    //   requested - done  > 0 → end-assignment wiped but never acked
    //                            (stuck in discontinued → needs force-reset).
    const sent = new cloudwatch.Metric({
      namespace: auditNs, metricName: 'DeviceActivationSent',
      statistic: 'Sum', period: cdk.Duration.hours(24),
    });
    const acked = new cloudwatch.Metric({
      namespace: auditNs, metricName: 'DeviceActivated',
      statistic: 'Sum', period: cdk.Duration.hours(24),
    });
    const wipeRequested = new cloudwatch.Metric({
      namespace: auditNs, metricName: 'DeviceWipeRequested',
      statistic: 'Sum', period: cdk.Duration.hours(24),
    });
    const wipeComplete = new cloudwatch.Metric({
      namespace: auditNs, metricName: 'DeviceWipeComplete',
      statistic: 'Sum', period: cdk.Duration.hours(24),
    });

    this.dashboard.addWidgets(
      new cloudwatch.GraphWidget({
        title: 'Unacked activations (24h) — stuck in provisioned',
        width: 12,
        height: 6,
        left: [
          new cloudwatch.MathExpression({
            expression: 'sent - acked',
            usingMetrics: { sent, acked },
            label: 'unacked_activations_24h',
            period: cdk.Duration.hours(24),
          }),
        ],
        leftAnnotations: [
          { value: 0, color: cloudwatch.Color.GREEN, label: 'healthy: all acked' },
        ],
      }),
      new cloudwatch.GraphWidget({
        title: 'Unacked wipes (24h) — stuck in discontinued (force-reset to clear)',
        width: 12,
        height: 6,
        left: [
          new cloudwatch.MathExpression({
            expression: 'requested - complete',
            usingMetrics: { requested: wipeRequested, complete: wipeComplete },
            label: 'unacked_wipes_24h',
            period: cdk.Duration.hours(24),
          }),
        ],
        leftAnnotations: [
          { value: 0, color: cloudwatch.Color.GREEN, label: 'healthy: all wiped' },
        ],
      }),
    );
  }
}
