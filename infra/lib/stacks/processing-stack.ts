import * as cdk from 'aws-cdk-lib/core';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as path from 'path';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';
import { DataStack } from './data-stack.js';
// Note: @aws-cdk/aws-lambda:useCdkManagedLogGroup is true in cdk.json
// so CDK auto-creates log groups — we use logRetention instead of explicit LogGroup

export interface ProcessingStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
  /**
   * DataStack is kept as a CDK-level dep (so CFN deploy ordering still
   * waits for Data tables before Processing handlers run), but actual
   * table refs go through `Table.fromTableName` so we don't generate
   * CFN cross-stack ImportValues. This avoids the "cannot delete
   * export in use" deadlock when DataStack does PK migrations.
   * Phase 0B revision §Implementation note.
   */
  readonly dataStack: DataStack;
}

/**
 * Processing — Lambda functions that validate, transform, and react
 * to incoming device data.
 *
 * Deployed before Ingestion so IoT Rules can reference these Lambdas.
 *
 * Phase 0B revision (2026-04-27): table references switched from
 * `dataStack.<table>` (cross-stack imports) to `Table.fromTableName`
 * (synthesized ARNs from env-prefix conventions). This decouples
 * Processing from DataStack at the CFN level — Data can recreate
 * tables without orphaning Processing's imports.
 */
export class ProcessingStack extends cdk.Stack {
  public readonly activityProcessor: lambda.Function;
  public readonly heartbeatProcessor: lambda.Function;
  public readonly alertHandler: lambda.Function;

  constructor(scope: Construct, id: string, props: ProcessingStackProps) {
    super(scope, id, props);

    const { config } = props;
    const p = config.prefix;

    const lambdaDir = path.join(__dirname, '..', '..', 'lambda');

    // ── Table references via fromTableName ────────────────────────
    // Decouples Processing from DataStack at the CFN level. Table names
    // follow the env-prefix convention `gosteady-${p}-<suffix>`.
    const deviceTable = dynamodb.Table.fromTableName(this, 'DeviceTableRef', `gosteady-${p}-devices`);
    const activityTable = dynamodb.Table.fromTableName(this, 'ActivityTableRef', `gosteady-${p}-activity`);
    const alertTable = dynamodb.Table.fromTableName(this, 'AlertTableRef', `gosteady-${p}-alerts`);

    // ── Shared Lambda config ─────────────────────────────────────
    // Phase 0B revision (2026-04-27): user-profiles table dropped.
    // The legacy USER_PROFILE_TABLE env var is removed. Old handlers
    // that read USER_PROFILE_TABLE will fail at runtime — this is
    // expected and intentional per the spec dependency note: handlers
    // are retargeted at the new tables (Patients, DeviceAssignments,
    // Organizations) in Phase 1B revision. New env vars below are
    // forward-looking for the 1B revision retargeting.
    const commonEnv: Record<string, string> = {
      DEVICE_TABLE: deviceTable.tableName,
      ACTIVITY_TABLE: activityTable.tableName,
      ALERT_TABLE: alertTable.tableName,
      // Forward-looking for Phase 1B revision (post-0B):
      PATIENTS_TABLE: `gosteady-${p}-patients`,
      USERS_TABLE: `gosteady-${p}-users`,
      ORGANIZATIONS_TABLE: `gosteady-${p}-organizations`,
      DEVICE_ASSIGNMENTS_TABLE: `gosteady-${p}-device-assignments`,
      ENVIRONMENT: p,
    };

    // ── Activity Processor Lambda ────────────────────────────────
    this.activityProcessor = new lambda.Function(this, 'ActivityProcessor', {
      functionName: `gosteady-${p}-activity-processor`,
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'handler.handler',
      code: lambda.Code.fromAsset(path.join(lambdaDir, 'activity-processor')),
      timeout: cdk.Duration.seconds(30),
      memorySize: 256,
      environment: commonEnv,
      description: 'Processes activity session payloads from IoT Core',
      logRetention: logs.RetentionDays.ONE_MONTH,
    });

    // Grant DynamoDB access (Phase 0B revision adjustments):
    // - activity table: write sessions
    // - device table: look up serial → assignment chain
    // - user-profile table: REMOVED (table no longer exists post-0B revision)
    // Phase 1B revision will add: kms:Decrypt on IdentityKey + read on
    // Patients + Query on DeviceAssignments for the patient-resolution path.
    activityTable.grantReadWriteData(this.activityProcessor);
    deviceTable.grantReadData(this.activityProcessor);

    // ── Heartbeat Processor Lambda ───────────────────────────────
    this.heartbeatProcessor = new lambda.Function(this, 'HeartbeatProcessor', {
      functionName: `gosteady-${p}-heartbeat-processor`,
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'handler.handler',
      code: lambda.Code.fromAsset(path.join(lambdaDir, 'heartbeat-processor')),
      timeout: cdk.Duration.seconds(15),
      memorySize: 128,
      environment: commonEnv,
      description: 'Processes device heartbeat payloads from IoT Core',
      logRetention: logs.RetentionDays.ONE_MONTH,
    });

    // - device table: update battery/signal/last_seen
    // - alert table: write synthetic alerts (battery/signal thresholds)
    deviceTable.grantReadWriteData(this.heartbeatProcessor);
    alertTable.grantWriteData(this.heartbeatProcessor);

    // ── Alert Handler Lambda ─────────────────────────────────────
    this.alertHandler = new lambda.Function(this, 'AlertHandler', {
      functionName: `gosteady-${p}-alert-handler`,
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'handler.handler',
      code: lambda.Code.fromAsset(path.join(lambdaDir, 'alert-handler')),
      timeout: cdk.Duration.seconds(15),
      memorySize: 128,
      environment: commonEnv,
      description: 'Processes alert events (tip-over, fall) from IoT Core',
      logRetention: logs.RetentionDays.ONE_MONTH,
    });

    alertTable.grantReadWriteData(this.alertHandler);
    deviceTable.grantReadData(this.alertHandler);

    // ── Outputs ──────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'ActivityProcessorArn', {
      value: this.activityProcessor.functionArn,
      exportName: `${p}-ActivityProcessorArn`,
    });
    new cdk.CfnOutput(this, 'HeartbeatProcessorArn', {
      value: this.heartbeatProcessor.functionArn,
      exportName: `${p}-HeartbeatProcessorArn`,
    });
    new cdk.CfnOutput(this, 'AlertHandlerArn', {
      value: this.alertHandler.functionArn,
      exportName: `${p}-AlertHandlerArn`,
    });
  }
}
