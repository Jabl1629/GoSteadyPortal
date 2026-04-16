import * as cdk from 'aws-cdk-lib/core';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as path from 'path';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';
import { DataStack } from './data-stack.js';
// Note: @aws-cdk/aws-lambda:useCdkManagedLogGroup is true in cdk.json
// so CDK auto-creates log groups — we use logRetention instead of explicit LogGroup

export interface ProcessingStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
  readonly dataStack: DataStack;
}

/**
 * Processing — Lambda functions that validate, transform, and react
 * to incoming device data.
 *
 * Deployed before Ingestion so IoT Rules can reference these Lambdas.
 */
export class ProcessingStack extends cdk.Stack {
  public readonly activityProcessor: lambda.Function;
  public readonly heartbeatProcessor: lambda.Function;
  public readonly alertHandler: lambda.Function;

  constructor(scope: Construct, id: string, props: ProcessingStackProps) {
    super(scope, id, props);

    const { config, dataStack } = props;
    const p = config.prefix;

    const lambdaDir = path.join(__dirname, '..', '..', 'lambda');

    // ── Shared Lambda config ─────────────────────────────────────
    const commonEnv: Record<string, string> = {
      DEVICE_TABLE: dataStack.deviceTable.tableName,
      ACTIVITY_TABLE: dataStack.activityTable.tableName,
      ALERT_TABLE: dataStack.alertTable.tableName,
      USER_PROFILE_TABLE: dataStack.userProfileTable.tableName,
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

    // Grant DynamoDB access
    dataStack.activityTable.grantReadWriteData(this.activityProcessor);
    dataStack.deviceTable.grantReadData(this.activityProcessor);

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

    dataStack.deviceTable.grantReadWriteData(this.heartbeatProcessor);

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

    dataStack.alertTable.grantReadWriteData(this.alertHandler);
    dataStack.deviceTable.grantReadData(this.alertHandler);

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
