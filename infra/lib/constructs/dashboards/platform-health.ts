import * as cdk from 'aws-cdk-lib/core';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import { Construct } from 'constructs';

/**
 * Platform Health Dashboard — Phase 1.6.
 *
 * Operational/system-health view for the cloud platform. Audience: cloud
 * + firmware team during M14.5 site-survey shakedown and M15 clinic deploy.
 *
 * No per-device variable — this is the global view of cloud-side health:
 * IoT Rule throughput / failure, Lambda invocations / errors / duration,
 * DLQ depth, DDB throttles, monthly estimated cost.
 *
 * Per-device drill-down lives on the Per-Device Detail dashboard.
 */
export interface PlatformHealthDashboardProps {
  readonly env: string;
  /** IoT Topic Rule names (no env prefix). */
  readonly iotRuleNames: string[];
  /** Lambda function names that should appear in error / duration widgets. */
  readonly lambdaFunctionNames: string[];
  /** Identity-bearing DDB table names to monitor for throttles. */
  readonly ddbTableNames: string[];
  /** SQS DLQ name (gosteady-{env}-iot-dlq). */
  readonly dlqQueueName: string;
}

export class PlatformHealthDashboard extends Construct {
  public readonly dashboard: cloudwatch.Dashboard;

  constructor(scope: Construct, id: string, props: PlatformHealthDashboardProps) {
    super(scope, id);

    const { env, iotRuleNames, lambdaFunctionNames, ddbTableNames, dlqQueueName } = props;

    this.dashboard = new cloudwatch.Dashboard(this, 'Dashboard', {
      dashboardName: `gosteady-${env}-platform-health`,
      defaultInterval: cdk.Duration.hours(3),
    });

    // ── Header ──────────────────────────────────────────────────
    this.dashboard.addWidgets(
      new cloudwatch.TextWidget({
        markdown:
          `# GoSteady Platform Health — ${env}\n` +
          'Operational view of the cloud ingestion + processing pipeline.\n' +
          'For per-device drill-down see **gosteady-' + env + '-per-device** dashboard.\n\n' +
          'Spec: [`docs/specs/phase-1.6-observability.md`](../../docs/specs/phase-1.6-observability.md).',
        width: 24,
        height: 3,
      }),
    );

    // ── Ingestion: IoT Rule throughput ──────────────────────────
    const iotSuccessMetrics = iotRuleNames.map(
      (ruleName) =>
        new cloudwatch.Metric({
          namespace: 'AWS/IoT',
          metricName: 'Success',
          dimensionsMap: { RuleName: ruleName },
          statistic: 'Sum',
          period: cdk.Duration.minutes(5),
          label: ruleName,
        }),
    );
    const iotFailureMetrics = iotRuleNames.map(
      (ruleName) =>
        new cloudwatch.Metric({
          namespace: 'AWS/IoT',
          metricName: 'Failure',
          dimensionsMap: { RuleName: ruleName },
          statistic: 'Sum',
          period: cdk.Duration.minutes(5),
          label: ruleName,
        }),
    );

    this.dashboard.addWidgets(
      new cloudwatch.GraphWidget({
        title: 'IoT Rule Success (msgs / 5 min)',
        width: 12,
        height: 6,
        left: iotSuccessMetrics,
      }),
      new cloudwatch.GraphWidget({
        title: 'IoT Rule Failure (msgs / 5 min)',
        width: 12,
        height: 6,
        left: iotFailureMetrics,
        leftAnnotations: [
          {
            value: 0,
            color: cloudwatch.Color.GREEN,
            label: 'healthy: zero failures',
          },
        ],
      }),
    );

    // ── Lambda: invocations + errors ────────────────────────────
    const lambdaInvocations = lambdaFunctionNames.map(
      (fn) =>
        new cloudwatch.Metric({
          namespace: 'AWS/Lambda',
          metricName: 'Invocations',
          dimensionsMap: { FunctionName: fn },
          statistic: 'Sum',
          period: cdk.Duration.minutes(5),
          label: fn.replace(`gosteady-${env}-`, ''),
        }),
    );
    const lambdaErrors = lambdaFunctionNames.map(
      (fn) =>
        new cloudwatch.Metric({
          namespace: 'AWS/Lambda',
          metricName: 'Errors',
          dimensionsMap: { FunctionName: fn },
          statistic: 'Sum',
          period: cdk.Duration.minutes(5),
          label: fn.replace(`gosteady-${env}-`, ''),
        }),
    );

    this.dashboard.addWidgets(
      new cloudwatch.GraphWidget({
        title: 'Lambda Invocations (sum / 5 min)',
        width: 12,
        height: 6,
        left: lambdaInvocations,
      }),
      new cloudwatch.GraphWidget({
        title: 'Lambda Errors (sum / 5 min)',
        width: 12,
        height: 6,
        left: lambdaErrors,
        leftAnnotations: [
          {
            value: 0,
            color: cloudwatch.Color.GREEN,
            label: 'healthy: zero errors',
          },
        ],
      }),
    );

    // ── Lambda: duration p50 / p95 / p99 ────────────────────────
    // One graph per handler so the percentile lines are interpretable.
    // Stacking 4 handlers' p99 lines on one graph is unreadable.
    const durationWidgets = lambdaFunctionNames.map((fn) => {
      const baseDims = { FunctionName: fn };
      return new cloudwatch.GraphWidget({
        title: `${fn.replace(`gosteady-${env}-`, '')} duration (ms)`,
        width: 12,
        height: 5,
        left: [
          new cloudwatch.Metric({
            namespace: 'AWS/Lambda',
            metricName: 'Duration',
            dimensionsMap: baseDims,
            statistic: 'p50',
            period: cdk.Duration.minutes(5),
            label: 'p50',
          }),
          new cloudwatch.Metric({
            namespace: 'AWS/Lambda',
            metricName: 'Duration',
            dimensionsMap: baseDims,
            statistic: 'p95',
            period: cdk.Duration.minutes(5),
            label: 'p95',
          }),
          new cloudwatch.Metric({
            namespace: 'AWS/Lambda',
            metricName: 'Duration',
            dimensionsMap: baseDims,
            statistic: 'p99',
            period: cdk.Duration.minutes(5),
            label: 'p99',
          }),
        ],
      });
    });
    // Pair them up: 2 widgets per row (both 12-wide → fills 24-wide grid)
    for (let i = 0; i < durationWidgets.length; i += 2) {
      const row = durationWidgets.slice(i, i + 2);
      this.dashboard.addWidgets(...row);
    }

    // ── DLQ depth + DDB throttles ───────────────────────────────
    const dlqDepth = new cloudwatch.GraphWidget({
      title: `IoT DLQ depth (${dlqQueueName})`,
      width: 12,
      height: 6,
      left: [
        new cloudwatch.Metric({
          namespace: 'AWS/SQS',
          metricName: 'ApproximateNumberOfMessagesVisible',
          dimensionsMap: { QueueName: dlqQueueName },
          statistic: 'Maximum',
          period: cdk.Duration.minutes(5),
          label: 'visible messages',
        }),
      ],
      leftAnnotations: [
        {
          value: 0,
          color: cloudwatch.Color.GREEN,
          label: 'healthy: empty DLQ',
        },
      ],
    });

    const ddbThrottles = new cloudwatch.GraphWidget({
      title: 'DDB throttle / system errors (sum / 5 min)',
      width: 12,
      height: 6,
      left: ddbTableNames.flatMap((tbl) => [
        new cloudwatch.Metric({
          namespace: 'AWS/DynamoDB',
          metricName: 'UserErrors',
          dimensionsMap: { TableName: tbl },
          statistic: 'Sum',
          period: cdk.Duration.minutes(5),
          label: `${tbl} UserErrors`,
        }),
        new cloudwatch.Metric({
          namespace: 'AWS/DynamoDB',
          metricName: 'SystemErrors',
          dimensionsMap: { TableName: tbl },
          statistic: 'Sum',
          period: cdk.Duration.minutes(5),
          label: `${tbl} SystemErrors`,
        }),
      ]),
    });

    this.dashboard.addWidgets(dlqDepth, ddbThrottles);

    // ── Cost: monthly estimated charges ─────────────────────────
    // AWS/Billing metrics are us-east-1 only and updated ~6h cadence.
    // Dimensions: Currency=USD for the total bill across all services.
    this.dashboard.addWidgets(
      new cloudwatch.GraphWidget({
        title: 'AWS Monthly Estimated Charges (USD, total account)',
        width: 24,
        height: 5,
        left: [
          new cloudwatch.Metric({
            namespace: 'AWS/Billing',
            metricName: 'EstimatedCharges',
            dimensionsMap: { Currency: 'USD' },
            statistic: 'Maximum',
            period: cdk.Duration.hours(6),
            label: 'Total USD',
          }),
        ],
        leftAnnotations: [
          {
            value: 100,
            color: cloudwatch.Color.ORANGE,
            label: 'dev billing alarm threshold ($100)',
          },
        ],
      }),
    );
  }
}
