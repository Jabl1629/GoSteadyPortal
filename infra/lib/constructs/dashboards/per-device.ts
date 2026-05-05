import * as cdk from 'aws-cdk-lib/core';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import { Construct } from 'constructs';

/**
 * Per-Device Detail Dashboard — Phase 1.6.
 *
 * Audience: firmware team during M14.5 site-survey shakedown — needs a
 * shareable URL to watch a single device's behavior over the 7-day soak.
 *
 * Single dashboard variable `serial` (free-text input, default GS9999999999)
 * substitutes into every widget on the dashboard via PATTERN-mode regex
 * find-and-replace on the rendered dashboard JSON. To switch units:
 *
 *   1. Open the dashboard in the AWS console
 *   2. Click the variable selector at the top
 *   3. Type the new serial (e.g. `GS0000000001`)
 *
 * Every metric dimension and Logs Insights query containing `GS9999999999`
 * gets transparently swapped to the new value. No widget reload needed.
 *
 * v1 caveats (deferred to Phase 2A's Lambda-backed custom widgets):
 *   - No live Shadow read widget (CloudWatch dashboards can't query Shadow
 *     natively in v1). The "Live state" widget is a markdown block with a
 *     hand-runnable AWS CLI snippet.
 *   - The recent-activity / recent-snippet widgets surface the cloud-side
 *     log entries, not the canonical DDB rows / S3 objects directly.
 *     Phase 2A custom widgets will swap to direct queries.
 */
export interface PerDeviceDashboardProps {
  readonly env: string;
  /** Serial used as the dashboard's default variable value. */
  readonly defaultSerial: string;
}

export class PerDeviceDashboard extends Construct {
  public readonly dashboard: cloudwatch.Dashboard;

  constructor(scope: Construct, id: string, props: PerDeviceDashboardProps) {
    super(scope, id);

    const { env, defaultSerial } = props;

    this.dashboard = new cloudwatch.Dashboard(this, 'Dashboard', {
      dashboardName: `gosteady-${env}-per-device`,
      defaultInterval: cdk.Duration.hours(24),
    });

    // ── Dashboard variable: serial ──────────────────────────────
    // PATTERN type: regex find-and-replace on dashboard JSON. Default
    // value is the bench unit's serial; literal "GS9999999999" is the
    // string that gets substituted everywhere.
    this.dashboard.addVariable(
      new cloudwatch.DashboardVariable({
        type: cloudwatch.VariableType.PATTERN,
        inputType: cloudwatch.VariableInputType.INPUT,
        id: 'serial',
        label: 'Device serial',
        value: defaultSerial,
        defaultValue: cloudwatch.DefaultValue.value(defaultSerial),
        visible: true,
      }),
    );

    // ── Header + live state CLI snippet ─────────────────────────
    this.dashboard.addWidgets(
      new cloudwatch.TextWidget({
        markdown:
          `# GoSteady Per-Device Detail — ${env}\n` +
          'Single-device drill-down. Switch device via the **Device serial** ' +
          'variable above (currently `' + defaultSerial + '`).\n\n' +
          '**Live state (run from terminal):**\n' +
          '```bash\n' +
          'aws iot-data get-thing-shadow --region us-east-1 \\\n' +
          `  --thing-name ${defaultSerial} /tmp/shadow.json && \\\n` +
          '  jq .state.reported /tmp/shadow.json\n' +
          '```\n\n' +
          'Phase 2A custom widget will replace this with a live Shadow read panel.',
        width: 24,
        height: 6,
      }),
    );

    // ── Battery curve ──────────────────────────────────────────
    this.dashboard.addWidgets(
      new cloudwatch.GraphWidget({
        title: `Battery % (${defaultSerial})`,
        width: 12,
        height: 6,
        left: [
          new cloudwatch.Metric({
            namespace: `GoSteady/Devices/${env}`,
            metricName: 'BatteryPct',
            dimensionsMap: {
              serial: defaultSerial,
              service: `gosteady-${env}-heartbeat-processor`,
            },
            statistic: 'Average',
            period: cdk.Duration.minutes(60),
            label: 'battery_pct',
          }),
        ],
        leftYAxis: { min: 0, max: 1 },
        leftAnnotations: [
          {
            value: 0.10,
            color: cloudwatch.Color.ORANGE,
            label: 'battery_low (P1)',
          },
          {
            value: 0.05,
            color: cloudwatch.Color.RED,
            label: 'battery_critical (P1)',
          },
        ],
      }),
      new cloudwatch.GraphWidget({
        title: `Signal — RSRP & SNR (${defaultSerial})`,
        width: 12,
        height: 6,
        left: [
          new cloudwatch.Metric({
            namespace: `GoSteady/Devices/${env}`,
            metricName: 'RsrpDbm',
            dimensionsMap: {
              serial: defaultSerial,
              service: `gosteady-${env}-heartbeat-processor`,
            },
            statistic: 'Average',
            period: cdk.Duration.minutes(60),
            label: 'rsrp_dbm',
          }),
        ],
        right: [
          new cloudwatch.Metric({
            namespace: `GoSteady/Devices/${env}`,
            metricName: 'SnrDb',
            dimensionsMap: {
              serial: defaultSerial,
              service: `gosteady-${env}-heartbeat-processor`,
            },
            statistic: 'Average',
            period: cdk.Duration.minutes(60),
            label: 'snr_db',
          }),
        ],
        leftAnnotations: [
          { value: -110, color: cloudwatch.Color.ORANGE, label: 'signal_weak (P2)' },
          { value: -120, color: cloudwatch.Color.RED, label: 'signal_lost (P2)' },
        ],
      }),
    );

    // ── Reset / fault counters ─────────────────────────────────
    this.dashboard.addWidgets(
      new cloudwatch.GraphWidget({
        title: `Watchdog hits & fault counters (${defaultSerial})`,
        width: 24,
        height: 5,
        left: [
          new cloudwatch.Metric({
            namespace: `GoSteady/Devices/${env}`,
            metricName: 'WatchdogHits',
            dimensionsMap: {
              serial: defaultSerial,
              service: `gosteady-${env}-heartbeat-processor`,
            },
            statistic: 'Maximum',
            period: cdk.Duration.minutes(60),
            label: 'watchdog_hits',
          }),
          new cloudwatch.Metric({
            namespace: `GoSteady/Devices/${env}`,
            metricName: 'FaultCountersFatal',
            dimensionsMap: {
              serial: defaultSerial,
              service: `gosteady-${env}-heartbeat-processor`,
            },
            statistic: 'Maximum',
            period: cdk.Duration.minutes(60),
            label: 'fault_counters.fatal',
          }),
          new cloudwatch.Metric({
            namespace: `GoSteady/Devices/${env}`,
            metricName: 'FaultCountersWatchdog',
            dimensionsMap: {
              serial: defaultSerial,
              service: `gosteady-${env}-heartbeat-processor`,
            },
            statistic: 'Maximum',
            period: cdk.Duration.minutes(60),
            label: 'fault_counters.watchdog',
          }),
        ],
        leftAnnotations: [
          {
            value: 3,
            color: cloudwatch.Color.ORANGE,
            label: 'watchdog ≥3/24h alarm threshold (firmware §F5.2)',
          },
        ],
      }),
    );

    // ── Recent activity (Logs Insights) ─────────────────────────
    this.dashboard.addWidgets(
      new cloudwatch.LogQueryWidget({
        title: `Recent activity sessions (${defaultSerial})`,
        logGroupNames: [`/aws/lambda/gosteady-${env}-activity-processor`],
        view: cloudwatch.LogQueryVisualizationType.TABLE,
        width: 24,
        height: 8,
        queryLines: [
          // Phase 1.6 follow-up 2026-05-05: align field names with what
          // activity-processor actually emits in its audit `after` block —
          // it uses camelCase (distanceFt / activeMinutes / roughnessR /
          // surfaceClass / firmwareVersion), not the snake_case firmware
          // contract names. Originally the query was reading from snake_case
          // fields that don't exist in the log shape, so only `steps`
          // populated.
          'fields @timestamp, subject.deviceSerial as serial, after.sessionEnd as session_end, ' +
            'after.steps as steps, after.distanceFt as distance_ft, ' +
            'after.activeMinutes as active_min, after.roughnessR as R, ' +
            'after.surfaceClass as surface, after.firmwareVersion as firmware',
          'filter event = "patient.activity.create"',
          `filter subject.deviceSerial = "${defaultSerial}"`,
          'sort @timestamp desc',
          'limit 20',
        ],
      }),
    );

    // ── Recent snippet uploads (Logs Insights) ──────────────────
    // snippet-parser logs include serial, snippet_id, window_start_ts,
    // payload_size, s3_key per the Phase 1A revision impl. The query
    // pulls the last 20 snippet upload events for the selected serial.
    this.dashboard.addWidgets(
      new cloudwatch.LogQueryWidget({
        title: `Recent snippet uploads (${defaultSerial})`,
        logGroupNames: [`/aws/lambda/gosteady-${env}-snippet-parser`],
        view: cloudwatch.LogQueryVisualizationType.TABLE,
        width: 24,
        height: 8,
        queryLines: [
          // snippet-parser logs `size_bytes` (not `payload_size` — verified
          // against handler.py 2026-04-30 — keep names aligned).
          'fields @timestamp, serial, snippet_id, window_start_ts, size_bytes, anomaly_trigger, s3_key',
          'filter event = "device.snippet_uploaded"',
          `filter serial = "${defaultSerial}"`,
          'sort @timestamp desc',
          'limit 20',
        ],
      }),
    );

    // ── Recent synthetic alerts (Logs Insights) ─────────────────
    this.dashboard.addWidgets(
      new cloudwatch.LogQueryWidget({
        title: `Recent synthetic alerts (Threshold Detector — ${defaultSerial})`,
        logGroupNames: [`/aws/lambda/gosteady-${env}-threshold-detector`],
        view: cloudwatch.LogQueryVisualizationType.TABLE,
        width: 12,
        height: 8,
        queryLines: [
          'fields @timestamp, after.alertType as alertType, after.severity as severity, ' +
            'after.eventTimestamp as eventTimestamp, subject.patientId as patientId',
          'filter event = "alert.synthetic.create"',
          `filter subject.deviceSerial = "${defaultSerial}"`,
          'sort @timestamp desc',
          'limit 10',
        ],
      }),
      new cloudwatch.LogQueryWidget({
        title: `Recent device alerts (Alert Handler — ${defaultSerial})`,
        logGroupNames: [`/aws/lambda/gosteady-${env}-alert-handler`],
        view: cloudwatch.LogQueryVisualizationType.TABLE,
        width: 12,
        height: 8,
        queryLines: [
          'fields @timestamp, after.alertType as alertType, after.severity as severity, ' +
            'after.eventTimestamp as eventTimestamp, subject.patientId as patientId',
          'filter event = "alert.device.create"',
          `filter subject.deviceSerial = "${defaultSerial}"`,
          'sort @timestamp desc',
          'limit 10',
        ],
      }),
    );
  }
}
