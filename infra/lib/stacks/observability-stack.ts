import * as cdk from 'aws-cdk-lib/core';
import * as sns from 'aws-cdk-lib/aws-sns';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';
import { PlatformHealthDashboard } from '../constructs/dashboards/platform-health.js';
import { PerDeviceDashboard } from '../constructs/dashboards/per-device.js';
import { HandlerAlarms } from '../constructs/alarms/handler-alarms.js';
import { InfrastructureAlarms } from '../constructs/alarms/infrastructure-alarms.js';
import { DeviceAlarms } from '../constructs/alarms/device-alarms.js';

export interface ObservabilityStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
}

/**
 * Observability — Phase 1.6.
 *
 * Lifts existing-stack health and per-device drill-down into two
 * CloudWatch dashboards plus the alarm catalog (Stage 4 — added in a
 * follow-up commit). Uses CloudWatch primitives that already exist
 * (Lambda metrics, IoT Rule metrics, AWS/Billing) plus the per-device
 * EMF metrics emitted from heartbeat-processor in Stage 2.
 *
 * No CDK-level dependency on any other stack — all references are by
 * name (Lambda function names, IoT Rule names, DDB table names),
 * mirroring Phase 1B-revision's `Table.fromTableName` decoupling.
 *
 * Deploy independently of stack-state changes elsewhere; dashboards
 * have no inbound dependencies and re-deploying them is non-destructive.
 */
export class ObservabilityStack extends cdk.Stack {
  public readonly platformHealth: PlatformHealthDashboard;
  public readonly perDevice: PerDeviceDashboard;

  constructor(scope: Construct, id: string, props: ObservabilityStackProps) {
    super(scope, id, props);

    const { config } = props;
    const env = config.prefix;

    const handlerLambdaNames = [
      `gosteady-${env}-activity-processor`,
      `gosteady-${env}-heartbeat-processor`,
      `gosteady-${env}-threshold-detector`,
      `gosteady-${env}-alert-handler`,
    ];
    const allLambdaNames = [
      ...handlerLambdaNames,
      `gosteady-${env}-snippet-parser`,
      `gosteady-${env}-cognito-pre-token`,
    ];

    const iotRuleNames = [
      `gosteady_${env}_activity`,
      `gosteady_${env}_heartbeat`,
      `gosteady_${env}_alert`,
      `gosteady_${env}_snippet`,
      `gosteady_${env}_shadow_update`,
    ];

    const identityTables = [
      `gosteady-${env}-organizations`,
      `gosteady-${env}-patients`,
      `gosteady-${env}-users`,
      `gosteady-${env}-device-assignments`,
    ];

    // ── Platform-Health dashboard ───────────────────────────────
    this.platformHealth = new PlatformHealthDashboard(this, 'PlatformHealth', {
      env,
      iotRuleNames,
      lambdaFunctionNames: allLambdaNames,
      ddbTableNames: identityTables,
      dlqQueueName: `gosteady-${env}-iot-dlq`,
    });

    // ── Per-Device Detail dashboard ─────────────────────────────
    this.perDevice = new PerDeviceDashboard(this, 'PerDevice', {
      env,
      // Default serial = bench unit; M14.5 will switch to a shipping unit
      // by toggling the dashboard variable in the console (no redeploy).
      defaultSerial: 'GS9999999999',
    });

    // ── Alarm catalog (Stage 4) ─────────────────────────────────
    // Reuse Phase 1.5's existing SNS topic (deployed by Security stack;
    // exported as `{env}-CostAlarmTopic`) — preserves the email
    // subscription that's already configured. Spec L6.
    const opsTopicArn = cdk.Fn.importValue(`${env}-CostAlarmTopic`);
    const opsTopic = sns.Topic.fromTopicArn(this, 'OpsTopicRef', opsTopicArn);

    new HandlerAlarms(this, 'HandlerAlarms', {
      env,
      opsTopic,
      lambdaNames: allLambdaNames,
    });

    new InfrastructureAlarms(this, 'InfraAlarms', {
      env,
      opsTopic,
      opsTopicArn,
      dlqQueueName: `gosteady-${env}-iot-dlq`,
      iotRuleNames,
      ddbTableNames: identityTables,
      costAnomalyEnabled: config.costAnomalyEnabled,
    });

    new DeviceAlarms(this, 'DeviceAlarms', {
      env,
      opsTopic,
    });

    // ── Outputs ──────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'PlatformHealthDashboardUrl', {
      value:
        `https://console.aws.amazon.com/cloudwatch/home?region=${this.region}` +
        `#dashboards:name=gosteady-${env}-platform-health`,
      exportName: `${env}-PlatformHealthDashboardUrl`,
    });
    new cdk.CfnOutput(this, 'PerDeviceDashboardUrl', {
      value:
        `https://console.aws.amazon.com/cloudwatch/home?region=${this.region}` +
        `#dashboards:name=gosteady-${env}-per-device`,
      exportName: `${env}-PerDeviceDashboardUrl`,
    });
  }
}
