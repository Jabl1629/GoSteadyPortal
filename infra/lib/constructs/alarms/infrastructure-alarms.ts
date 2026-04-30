import * as cdk from 'aws-cdk-lib/core';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cloudwatchActions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as ce from 'aws-cdk-lib/aws-ce';
import * as sns from 'aws-cdk-lib/aws-sns';
import { Construct } from 'constructs';

/**
 * Infrastructure-Alarms — Phase 1.6.
 *
 * Standard CloudWatch metric alarms that don't depend on Lambda
 * application logs:
 *   - SQS DLQ depth on the IoT DLQ
 *   - Per-IoT-Rule failure metric
 *   - DDB UserErrors / SystemErrors per identity-bearing table
 *   - AWS Cost Anomaly Detection monitor + subscription
 *
 * All alarms / cost subscription target the shared ops topic.
 */
export interface InfrastructureAlarmsProps {
  readonly env: string;
  readonly opsTopic: sns.ITopic;
  readonly opsTopicArn: string;
  readonly dlqQueueName: string;
  readonly iotRuleNames: string[];
  readonly ddbTableNames: string[];
  /**
   * Whether to deploy the Cost Anomaly Monitor + Subscription. Requires
   * Cost Explorer enabled at the account level first. See
   * GoSteadyEnvConfig.costAnomalyEnabled.
   */
  readonly costAnomalyEnabled: boolean;
}

export class InfrastructureAlarms extends Construct {
  constructor(scope: Construct, id: string, props: InfrastructureAlarmsProps) {
    super(scope, id);

    const { env, opsTopic, opsTopicArn, dlqQueueName, iotRuleNames, ddbTableNames, costAnomalyEnabled } = props;
    const snsAction = new cloudwatchActions.SnsAction(opsTopic);

    // ── DLQ depth ───────────────────────────────────────────────
    const dlqAlarm = new cloudwatch.Alarm(this, 'IotDlqDepth', {
      alarmName: `gosteady-${env}-iot-dlq-not-empty`,
      alarmDescription:
        `${dlqQueueName} has visible messages — IoT-side rule failure (auth, ` +
        `throttling, malformed SQL, missing Lambda invoke perm). Lambda-internal ` +
        `errors do NOT land here (async invoke); see handler-errors alarms instead.`,
      metric: new cloudwatch.Metric({
        namespace: 'AWS/SQS',
        metricName: 'ApproximateNumberOfMessagesVisible',
        dimensionsMap: { QueueName: dlqQueueName },
        statistic: 'Maximum',
        period: cdk.Duration.minutes(5),
      }),
      threshold: 0,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    dlqAlarm.addAlarmAction(snsAction);

    // ── Per-IoT-Rule failure ────────────────────────────────────
    for (const rule of iotRuleNames) {
      const ruleSuffix = rule.replace(`gosteady_${env}_`, '');
      const alarm = new cloudwatch.Alarm(this, `IotRule${pascalCase(ruleSuffix)}Failure`, {
        alarmName: `gosteady-${env}-iot-rule-${ruleSuffix.replace(/_/g, '-')}-failure`,
        alarmDescription:
          `IoT Topic Rule ${rule} reported a Failure metric > 0. Causes: SQL ` +
          `parse error, missing IAM grant, target unavailable. Investigate via ` +
          `the rule's monitoring tab in the IoT Core console.`,
        metric: new cloudwatch.Metric({
          namespace: 'AWS/IoT',
          metricName: 'Failure',
          dimensionsMap: { RuleName: rule },
          statistic: 'Sum',
          period: cdk.Duration.minutes(5),
        }),
        threshold: 0,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
        evaluationPeriods: 1,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      });
      alarm.addAlarmAction(snsAction);
    }

    // ── Per-DDB-table throttle / system error ───────────────────
    for (const tbl of ddbTableNames) {
      const userErrors = new cloudwatch.Alarm(this, `Ddb${pascalCase(tbl)}UserErrors`, {
        alarmName: `gosteady-${env}-ddb-${tbl.replace(`gosteady-${env}-`, '')}-user-errors`,
        alarmDescription:
          `DDB UserErrors > 0 on ${tbl} — typically conditional-write rejects, ` +
          `missing-table refs, or IAM denies. Idempotent conditional writes (P4) ` +
          `count here; non-zero is OK for replay scenarios but worth a glance.`,
        metric: new cloudwatch.Metric({
          namespace: 'AWS/DynamoDB',
          metricName: 'UserErrors',
          dimensionsMap: { TableName: tbl },
          statistic: 'Sum',
          period: cdk.Duration.minutes(5),
        }),
        // Conditional PutItem failures (idempotency replays) count as
        // UserErrors, so non-zero is normal during replay tests. Set
        // threshold higher to reduce noise; raw "is anything failing"
        // signal is captured by the ERROR-pattern alarms.
        threshold: 5,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
        evaluationPeriods: 1,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      });
      userErrors.addAlarmAction(snsAction);

      const systemErrors = new cloudwatch.Alarm(this, `Ddb${pascalCase(tbl)}SystemErrors`, {
        alarmName: `gosteady-${env}-ddb-${tbl.replace(`gosteady-${env}-`, '')}-system-errors`,
        alarmDescription:
          `DDB SystemErrors > 0 on ${tbl} — DDB-side internal failures. AWS ` +
          `responsibility, but worth surfacing so we don't quietly retry forever.`,
        metric: new cloudwatch.Metric({
          namespace: 'AWS/DynamoDB',
          metricName: 'SystemErrors',
          dimensionsMap: { TableName: tbl },
          statistic: 'Sum',
          period: cdk.Duration.minutes(5),
        }),
        threshold: 0,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
        evaluationPeriods: 1,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      });
      systemErrors.addAlarmAction(snsAction);
    }

    // ── AWS Cost Anomaly Detection (Q6: turn on now, accept early noise) ──
    // Service-level monitor — sufficient at MVP scale per spec D10.
    // The first 30 days are a learning period; AWS docs say expect false
    // positives during that window. v1 accepts the noise; the existing
    // $100 billing alarm catches anything obvious.
    //
    // GATED on costAnomalyEnabled — requires Cost Explorer enabled at the
    // account level FIRST (one-time console opt-in). Without it the
    // CfnAnomalyMonitor resource fails CREATE with `User not enabled for
    // cost explorer access` and rolls back the stack. After enabling Cost
    // Explorer in console, flip costAnomalyEnabled=true and redeploy.
    if (costAnomalyEnabled) {
      const monitor = new ce.CfnAnomalyMonitor(this, 'CostAnomalyMonitor', {
        monitorName: `gosteady-${env}-cost-anomaly`,
        monitorType: 'DIMENSIONAL',
        monitorDimension: 'SERVICE',
      });

      new ce.CfnAnomalySubscription(this, 'CostAnomalySubscription', {
        subscriptionName: `gosteady-${env}-cost-anomaly-sub`,
        frequency: 'DAILY',
        monitorArnList: [monitor.attrMonitorArn],
        subscribers: [
          {
            type: 'SNS',
            address: opsTopicArn,
          },
        ],
        // Threshold expression: anomaly delta ≥ $20 (a meaningful jump at
        // our ~$10-30/mo dev spend). Cost Explorer requires the
        // `thresholdExpression` form rather than the deprecated `Threshold`
        // property as of 2026.
        thresholdExpression: JSON.stringify({
          Dimensions: {
            Key: 'ANOMALY_TOTAL_IMPACT_ABSOLUTE',
            MatchOptions: ['GREATER_THAN_OR_EQUAL'],
            Values: ['20'],
          },
        }),
      });
    }
  }
}

function pascalCase(s: string): string {
  return s.split(/[-_]/).map((p) => p.charAt(0).toUpperCase() + p.slice(1)).join('');
}
