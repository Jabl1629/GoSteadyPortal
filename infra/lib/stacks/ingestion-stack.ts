import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';

export interface IngestionStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
}

/**
 * Device Ingestion — IoT Core setup.
 *
 * Phase 1A will implement:
 *   - IoT Core MQTT broker (devices connect via LTE-M)
 *   - Thing Type "GoSteadyWalkerCap"
 *   - IoT Policy restricting each device to gs/{serial}/* topics
 *   - IoT Rules:
 *       gs/{serial}/activity  → Activity Processor Lambda
 *       gs/{serial}/heartbeat → Heartbeat Processor Lambda
 *       gs/{serial}/alert     → Alert Handler Lambda + SNS
 *   - Dead-letter SQS queue for failed rule actions
 *   - Fleet Provisioning template (claim cert → unique cert exchange)
 *   - S3 bucket for firmware OTA binaries
 */
export class IngestionStack extends cdk.Stack {
  // Public properties will be added as resources are created:
  // public readonly activityRule: iot.CfnTopicRule;
  // public readonly heartbeatRule: iot.CfnTopicRule;
  // public readonly alertRule: iot.CfnTopicRule;

  constructor(scope: Construct, id: string, props: IngestionStackProps) {
    super(scope, id, props);

    const { config } = props;
    const p = config.prefix;

    // ── Phase 1A: IoT Core ───────────────────────────────────────
    // TODO: IoT Thing Type
    // TODO: IoT Policy (per-device topic restriction)
    // TODO: IoT Rules (activity → Lambda, heartbeat → Lambda, alert → Lambda + SNS)
    // TODO: DLQ for failed rule actions
    // TODO: Fleet Provisioning template
    // TODO: S3 bucket for firmware OTA

    new cdk.CfnOutput(this, 'Status', {
      value: 'SCAFFOLD — Phase 1A pending',
    });
  }
}
