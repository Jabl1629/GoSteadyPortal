import * as cdk from 'aws-cdk-lib/core';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as path from 'path';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';
import { DataStack } from './data-stack.js';
import { SecurityStack } from './security-stack.js';
import { ProcessingLambda } from '../constructs/processing-lambda.js';

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
  /**
   * SecurityStack provides the IdentityKey CMK ARN (via cross-stack output)
   * so handlers that read CMK-encrypted Patients / DeviceAssignments can
   * be granted `kms:Decrypt` + `kms:GenerateDataKey`. Phase 1B revision L15
   * narrowed to actual readers (heartbeat-processor doesn't read those tables).
   */
  readonly securityStack: SecurityStack;
}

/**
 * Processing — Lambda functions that validate, transform, and react
 * to incoming device data.
 *
 * Phase 1B revision (2026-04-27): patient-centric refactor.
 *   - activity-processor: ARM64 + Powertools + patient resolution + hierarchy snapshot
 *   - heartbeat-processor: slimmed to Shadow update + activation-ack only
 *   - threshold-detector: NEW Lambda triggered by Shadow update/accepted IoT Rule
 *     (replaces heartbeat-processor's threshold-checking role)
 *   - alert-handler: ARM64 + Powertools + patient resolution + hierarchy snapshot
 *
 * Deployed before Ingestion so IoT Rules can reference these Lambdas.
 */
export class ProcessingStack extends cdk.Stack {
  public readonly activityProcessor: lambda.Function;
  public readonly heartbeatProcessor: lambda.Function;
  public readonly thresholdDetector: lambda.Function;
  public readonly alertHandler: lambda.Function;

  constructor(scope: Construct, id: string, props: ProcessingStackProps) {
    super(scope, id, props);

    const { config, securityStack } = props;
    const p = config.prefix;
    const account = cdk.Stack.of(this).account;
    const region = cdk.Stack.of(this).region;

    const lambdaDir = path.join(__dirname, '..', '..', 'lambda');

    // ── Table references via fromTableName ────────────────────────
    // Phase 0B revision: refs decoupled from DataStack at the CFN level.
    const deviceTable = dynamodb.Table.fromTableName(this, 'DeviceTableRef', `gosteady-${p}-devices`);
    const activityTable = dynamodb.Table.fromTableName(this, 'ActivityTableRef', `gosteady-${p}-activity`);
    const alertTable = dynamodb.Table.fromTableName(this, 'AlertTableRef', `gosteady-${p}-alerts`);
    const patientsTable = dynamodb.Table.fromTableName(this, 'PatientsTableRef', `gosteady-${p}-patients`);
    const deviceAssignmentsTable = dynamodb.Table.fromTableName(
      this,
      'DeviceAssignmentsTableRef',
      `gosteady-${p}-device-assignments`,
    );

    // ── IdentityKey CMK reference ─────────────────────────────────
    // Imported by ARN so handlers that read CMK-encrypted Patients /
    // DeviceAssignments tables can be granted Decrypt + GenerateDataKey.
    const identityKey = kms.Key.fromKeyArn(
      this,
      'IdentityKeyRef',
      securityStack.identityKey.keyArn,
    );

    // ── Shared Lambda environment ─────────────────────────────────
    const commonEnv = {
      DEVICE_TABLE: deviceTable.tableName,
      ACTIVITY_TABLE: activityTable.tableName,
      ALERT_TABLE: alertTable.tableName,
      PATIENTS_TABLE: patientsTable.tableName,
      DEVICE_ASSIGNMENTS_TABLE: deviceAssignmentsTable.tableName,
      ENVIRONMENT: p,
    };

    // ── Powertools Lambda layer (Phase 1.6) ──────────────────────
    // AWS-managed layer; pinned ARN per env in config.ts.
    const powertoolsLayer = lambda.LayerVersion.fromLayerVersionArn(
      this,
      'PowertoolsLayer',
      config.powertoolsLayerArn,
    );

    // ── Activity Processor (refactored) ──────────────────────────
    const activityProc = new ProcessingLambda(this, 'ActivityProcessor', {
      config,
      functionName: `gosteady-${p}-activity-processor`,
      handlerDir: path.join(lambdaDir, 'activity-processor'),
      description: 'Phase 1B revision: patient-centric activity ingest with hierarchy snapshot',
      memoryMb: config.processingLambdaMemoryMb,
      timeoutSeconds: config.processingLambdaTimeoutSeconds,
      environment: commonEnv,
      powertoolsLayer,
    });
    this.activityProcessor = activityProc.function;
    // Preserve pre-1B-revision CFN logical ID so CFN does an in-place
    // UPDATE rather than CREATE+DELETE (Lambda names are region-unique
    // and the CREATE-new-before-DELETE-old order would otherwise collide).
    (this.activityProcessor.node.defaultChild as cdk.CfnResource).overrideLogicalId(
      'ActivityProcessor38C14121',
    );

    activityTable.grantWriteData(this.activityProcessor);
    deviceAssignmentsTable.grantReadData(this.activityProcessor);
    patientsTable.grantReadData(this.activityProcessor);
    identityKey.grantDecrypt(this.activityProcessor);
    identityKey.grant(this.activityProcessor, 'kms:GenerateDataKey');

    // ── Heartbeat Processor (slimmed) ────────────────────────────
    const heartbeatProc = new ProcessingLambda(this, 'HeartbeatProcessor', {
      config,
      functionName: `gosteady-${p}-heartbeat-processor`,
      handlerDir: path.join(lambdaDir, 'heartbeat-processor'),
      description: 'Phase 1B revision: Shadow update + activation-ack only (slim)',
      memoryMb: config.processingHeartbeatMemoryMb,
      timeoutSeconds: config.processingLambdaTimeoutSeconds,
      environment: {
        ...commonEnv,
        ACTIVATION_ACK_WINDOW_HOURS: String(config.activationAckWindowHours),
      },
      powertoolsLayer,
    });
    this.heartbeatProcessor = heartbeatProc.function;

    (this.heartbeatProcessor.node.defaultChild as cdk.CfnResource).overrideLogicalId(
      'HeartbeatProcessorCDD753A4',
    );

    deviceTable.grantReadWriteData(this.heartbeatProcessor);
    // Shadow update for Shadow.reported writes; targets the device's own thing
    this.heartbeatProcessor.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'ShadowUpdateOnAnyThing',
        actions: ['iot:UpdateThingShadow'],
        resources: [`arn:aws:iot:${region}:${account}:thing/*`],
      }),
    );

    // ── Threshold Detector (NEW) ─────────────────────────────────
    const thresholdDet = new ProcessingLambda(this, 'ThresholdDetector', {
      config,
      functionName: `gosteady-${p}-threshold-detector`,
      handlerDir: path.join(lambdaDir, 'threshold-detector'),
      description: 'Phase 1B revision: synthetic alerts from Shadow update/accepted',
      memoryMb: config.processingLambdaMemoryMb,
      timeoutSeconds: config.processingLambdaTimeoutSeconds,
      environment: {
        ...commonEnv,
        PRE_ACTIVATION_AUDIT_SAMPLE_HOURS: String(config.preActivationAuditSampleHours),
      },
      powertoolsLayer,
    });
    this.thresholdDetector = thresholdDet.function;

    deviceTable.grantReadData(this.thresholdDetector);
    alertTable.grantWriteData(this.thresholdDetector);
    deviceAssignmentsTable.grantReadData(this.thresholdDetector);
    patientsTable.grantReadData(this.thresholdDetector);
    identityKey.grantDecrypt(this.thresholdDetector);
    identityKey.grant(this.thresholdDetector, 'kms:GenerateDataKey');
    this.thresholdDetector.addToRolePolicy(
      new iam.PolicyStatement({
        sid: 'ShadowGetAndUpdateOnAnyThing',
        actions: ['iot:GetThingShadow', 'iot:UpdateThingShadow'],
        resources: [`arn:aws:iot:${region}:${account}:thing/*`],
      }),
    );

    // ── Alert Handler (refactored) ───────────────────────────────
    const alertHand = new ProcessingLambda(this, 'AlertHandler', {
      config,
      functionName: `gosteady-${p}-alert-handler`,
      handlerDir: path.join(lambdaDir, 'alert-handler'),
      description: 'Phase 1B revision: patient-centric device alert ingest with hierarchy snapshot',
      memoryMb: config.processingLambdaMemoryMb,
      timeoutSeconds: config.processingLambdaTimeoutSeconds,
      environment: commonEnv,
      powertoolsLayer,
    });
    this.alertHandler = alertHand.function;
    (this.alertHandler.node.defaultChild as cdk.CfnResource).overrideLogicalId(
      'AlertHandler13C27ADA',
    );

    alertTable.grantWriteData(this.alertHandler);
    deviceAssignmentsTable.grantReadData(this.alertHandler);
    patientsTable.grantReadData(this.alertHandler);
    identityKey.grantDecrypt(this.alertHandler);
    identityKey.grant(this.alertHandler, 'kms:GenerateDataKey');

    // ── Outputs ──────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'ActivityProcessorArn', {
      value: this.activityProcessor.functionArn,
      exportName: `${p}-ActivityProcessorArn`,
    });
    new cdk.CfnOutput(this, 'HeartbeatProcessorArn', {
      value: this.heartbeatProcessor.functionArn,
      exportName: `${p}-HeartbeatProcessorArn`,
    });
    new cdk.CfnOutput(this, 'ThresholdDetectorArn', {
      value: this.thresholdDetector.functionArn,
      exportName: `${p}-ThresholdDetectorArn`,
    });
    new cdk.CfnOutput(this, 'AlertHandlerArn', {
      value: this.alertHandler.functionArn,
      exportName: `${p}-AlertHandlerArn`,
    });
  }
}
