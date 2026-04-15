import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';
import { DataStack } from './data-stack.js';

export interface ProcessingStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
  readonly dataStack: DataStack;
}

/**
 * Processing — Lambda functions that validate, transform, and react
 * to incoming device data.
 *
 * Phase 1B will implement:
 *   - Activity Processor Lambda
 *       Validates hourly payload schema, deduplicates by device+timestamp,
 *       writes to activity time-series table, computes daily roll-ups.
 *       Triggered by IoT Rule on gs/{serial}/activity.
 *
 *   - Heartbeat Processor Lambda
 *       Updates device registry (battery, signal, last_seen),
 *       checks thresholds (low battery, weak signal),
 *       publishes warning events to EventBridge.
 *       Triggered by IoT Rule on gs/{serial}/heartbeat.
 *
 *   - Alert Handler Lambda
 *       Receives tip-over / fall events from IoT Rules,
 *       logs to alert history table,
 *       resolves linked caregivers from relationships table,
 *       publishes to EventBridge for fan-out (SNS + integration targets).
 *       Triggered by IoT Rule on gs/{serial}/alert.
 *
 *   - Scheduled Jobs (EventBridge cron → Lambda)
 *       No-activity check: every 30 min
 *       Weekly trend computation: 7d rolling averages
 *       Offline detector: flags devices with no heartbeat > 8h
 *
 * Each Lambda gets:
 *   - Read/write to the relevant DynamoDB tables (least-privilege)
 *   - CloudWatch log group with 30d retention
 *   - X-Ray tracing enabled
 */
export class ProcessingStack extends cdk.Stack {
  // Public properties will be added:
  // public readonly activityProcessor: lambda.Function;
  // public readonly heartbeatProcessor: lambda.Function;
  // public readonly alertHandler: lambda.Function;

  constructor(scope: Construct, id: string, props: ProcessingStackProps) {
    super(scope, id, props);

    const { config, dataStack } = props;
    const p = config.prefix;

    // ── Phase 1B: Processing Lambdas ─────────────────────────────
    // TODO: Activity Processor Lambda (Python, lambda/activity-processor/)
    //       - dataStack.activityTable read/write
    //       - dataStack.deviceTable read (to resolve walker user)
    //
    // TODO: Heartbeat Processor Lambda (Python, lambda/heartbeat-processor/)
    //       - dataStack.deviceTable read/write
    //
    // TODO: Alert Handler Lambda (Python, lambda/alert-handler/)
    //       - dataStack.alertTable write
    //       - authStack.relationshipsTable read
    //       - EventBridge putEvents
    //
    // TODO: Scheduled Jobs Lambda (Python, lambda/scheduled-jobs/)
    //       - EventBridge cron rules
    //       - dataStack.activityTable read
    //       - dataStack.deviceTable read

    new cdk.CfnOutput(this, 'Status', {
      value: 'SCAFFOLD — Phase 1B pending',
    });
  }
}
