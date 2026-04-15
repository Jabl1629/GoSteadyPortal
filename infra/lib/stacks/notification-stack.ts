import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';

export interface NotificationStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
}

/**
 * Notifications & Events — EventBridge central bus, SNS, SES, SQS.
 *
 * Phase 2C will implement:
 *   - EventBridge custom event bus ("gosteady-events")
 *       All system events flow here first. Rules route to targets:
 *       alert.*    → SNS (push notifications)
 *       alert.*    → SQS (integration queue, for outbound HL7/FHIR)
 *       device.*   → Lambda (offline detection follow-up)
 *       activity.* → SQS (integration queue, for EMR sync)
 *
 *   - SNS Topics
 *       gosteady-{env}-tipover   → critical, immediate push
 *       gosteady-{env}-warning   → battery low, signal weak, no-activity
 *       Fan-out to FCM (Android), APNs (iOS), SMS fallback
 *
 *   - SES Email
 *       Weekly caregiver digest
 *       Device offline / battery warnings
 *       Templated with GoSteady branding
 *
 *   - SQS Integration Queue
 *       Buffers events for outbound integration Lambda
 *       Separate queues per integration partner (future)
 *       Dead-letter queue for persistent failures
 */
export class NotificationStack extends cdk.Stack {
  // Public properties will be added:
  // public readonly eventBus: events.EventBus;
  // public readonly tipoverTopic: sns.Topic;
  // public readonly warningTopic: sns.Topic;
  // public readonly integrationQueue: sqs.Queue;

  constructor(scope: Construct, id: string, props: NotificationStackProps) {
    super(scope, id, props);

    const { config } = props;
    const p = config.prefix;

    // ── Phase 2C: EventBridge + SNS + SES + SQS ─────────────────
    // TODO: Custom EventBridge bus
    // TODO: EventBridge rules (alert.* → SNS, alert.* → SQS)
    // TODO: SNS topics (tipover, warning)
    // TODO: SQS integration queue + DLQ
    // TODO: SES email identity + templates

    new cdk.CfnOutput(this, 'Status', {
      value: 'SCAFFOLD — Phase 2C pending',
    });
  }
}
