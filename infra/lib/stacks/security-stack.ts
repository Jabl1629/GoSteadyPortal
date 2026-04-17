import * as cdk from 'aws-cdk-lib/core';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as cloudtrail from 'aws-cdk-lib/aws-cloudtrail';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as snsSubscriptions from 'aws-cdk-lib/aws-sns-subscriptions';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cloudwatchActions from 'aws-cdk-lib/aws-cloudwatch-actions';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';

export interface SecurityStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
}

/**
 * Security Foundation (Phase 1.5)
 *
 * Cross-cutting security primitives consumed by every other stack:
 *
 *   - IdentityKey CMK  — encrypts identity-bearing DDB tables
 *                         (Users, Patients, Organizations, RoleAssignments,
 *                          DeviceAssignments)
 *   - FirmwareKey  CMK  — encrypts S3 OTA bucket + future OTA artifact integrity
 *   - AuditKey     CMK  — encrypts CloudTrail logs + audit-log S3 (Phase 1.7)
 *
 *   - CloudTrail multi-region trail with S3 destination + CloudWatch logs
 *   - Cost alarm SNS topic + monthly billing threshold alarm
 *
 * Deploy this stack FIRST — downstream stacks (Auth, Data, Ingestion) reference
 * the CMK ARNs via cross-stack outputs.
 */
export class SecurityStack extends cdk.Stack {
  public readonly identityKey: kms.Key;
  public readonly firmwareKey: kms.Key;
  public readonly auditKey: kms.Key;
  public readonly cloudTrailBucket?: s3.Bucket;
  public readonly cloudTrailLogGroup?: logs.LogGroup;
  public readonly costAlarmTopic: sns.Topic;

  constructor(scope: Construct, id: string, props: SecurityStackProps) {
    super(scope, id, props);

    const { config } = props;
    const p = config.prefix;
    const isProd = p === 'prod';
    const removal = isProd ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY;

    // ── KMS Customer-Managed Keys ────────────────────────────────────
    // One CMK per data-domain: identity / firmware / audit.
    // Per-resource keys would explode operational surface without
    // proportional security benefit. See phase-1.5-security.md decision D2.

    this.identityKey = new kms.Key(this, 'IdentityKey', {
      alias: `gosteady/${p}/identity`,
      description:
        'GoSteady identity-bearing data (Users, Patients, Organizations, ' +
        'RoleAssignments, DeviceAssignments)',
      enableKeyRotation: true,
      removalPolicy: removal,
      pendingWindow: cdk.Duration.days(7),
    });

    this.firmwareKey = new kms.Key(this, 'FirmwareKey', {
      alias: `gosteady/${p}/firmware`,
      description: 'GoSteady firmware OTA artifacts (S3 bucket + IoT Jobs)',
      enableKeyRotation: true,
      removalPolicy: removal,
      pendingWindow: cdk.Duration.days(7),
    });

    this.auditKey = new kms.Key(this, 'AuditKey', {
      alias: `gosteady/${p}/audit`,
      description:
        'GoSteady audit artifacts (CloudTrail logs + Phase 1.7 application audit)',
      enableKeyRotation: true,
      removalPolicy: removal,
      pendingWindow: cdk.Duration.days(7),
    });

    // ── CloudTrail ───────────────────────────────────────────────────
    // Multi-region management-events trail. Destination:
    //   1. S3 bucket (long-term, optionally Object-Locked in prod)
    //   2. CloudWatch Logs group (90-day hot retention)

    if (config.cloudTrailEnabled) {
      // Grant CloudTrail service principal to use the AuditKey for encryption.
      // CDK's Trail construct does NOT auto-wire this; must be explicit.
      this.auditKey.addToResourcePolicy(
        new iam.PolicyStatement({
          sid: 'AllowCloudTrailEncryption',
          effect: iam.Effect.ALLOW,
          principals: [new iam.ServicePrincipal('cloudtrail.amazonaws.com')],
          actions: ['kms:GenerateDataKey*', 'kms:DescribeKey'],
          resources: ['*'],
          conditions: {
            StringEquals: {
              'aws:SourceAccount': this.account,
            },
            StringLike: {
              'aws:SourceArn': `arn:aws:cloudtrail:${this.region}:${this.account}:trail/*`,
            },
          },
        }),
      );

      this.cloudTrailBucket = new s3.Bucket(this, 'CloudTrailBucket', {
        bucketName: `gosteady-${p}-cloudtrail-logs-${this.account}`,
        encryption: config.kmsCmkEnabled
          ? s3.BucketEncryption.KMS
          : s3.BucketEncryption.S3_MANAGED,
        encryptionKey: config.kmsCmkEnabled ? this.auditKey : undefined,
        blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
        versioned: true,
        enforceSSL: true,
        // Object Lock is prod-only — compliance mode makes the bucket
        // non-destroyable, which blocks dev teardown.
        objectLockEnabled: config.cloudTrailObjectLockEnabled,
        objectLockDefaultRetention: config.cloudTrailObjectLockEnabled
          ? s3.ObjectLockRetention.compliance(cdk.Duration.days(365 * 6))
          : undefined,
        removalPolicy: removal,
        autoDeleteObjects: !isProd && !config.cloudTrailObjectLockEnabled,
        lifecycleRules: [
          {
            id: 'TransitionToGlacierAfter90Days',
            enabled: true,
            transitions: [
              {
                storageClass: s3.StorageClass.GLACIER,
                transitionAfter: cdk.Duration.days(90),
              },
            ],
          },
        ],
      });

      this.cloudTrailLogGroup = new logs.LogGroup(this, 'CloudTrailLogGroup', {
        logGroupName: `/aws/cloudtrail/gosteady-${p}`,
        retention: logs.RetentionDays.THREE_MONTHS,
        removalPolicy: removal,
      });

      new cloudtrail.Trail(this, 'CloudTrail', {
        trailName: `gosteady-${p}-cloudtrail`,
        bucket: this.cloudTrailBucket,
        cloudWatchLogGroup: this.cloudTrailLogGroup,
        sendToCloudWatchLogs: true,
        includeGlobalServiceEvents: true,
        isMultiRegionTrail: true,
        enableFileValidation: true,
        // Management events only in Phase 1.5. S3 + DynamoDB data events
        // are deferred to Phase 1.7 alongside application-level audit.
      });
    }

    // ── Cost Alarm SNS Topic + Billing Alarm ────────────────────────
    // Billing metric is published only in us-east-1 (AWS limitation).
    // Stack already deploys there, so no cross-region dance needed.
    // NOTE: Requires "Receive Billing Alerts" enabled account-wide in the
    // AWS Billing & Cost Management console (one-time manual step).

    this.costAlarmTopic = new sns.Topic(this, 'CostAlarmTopic', {
      topicName: `gosteady-${p}-cost-alarms`,
      displayName: 'GoSteady Cost Alarms',
    });

    if (config.costAlarmEmail) {
      this.costAlarmTopic.addSubscription(
        new snsSubscriptions.EmailSubscription(config.costAlarmEmail),
      );
    }

    const billingMetric = new cloudwatch.Metric({
      namespace: 'AWS/Billing',
      metricName: 'EstimatedCharges',
      dimensionsMap: { Currency: 'USD' },
      statistic: 'Maximum',
      period: cdk.Duration.hours(6),
    });

    const billingAlarm = new cloudwatch.Alarm(this, 'BillingAlarm', {
      alarmName: `gosteady-${p}-billing-over-${config.costAlarmThresholdUsd}`,
      alarmDescription: `GoSteady monthly estimated charges exceed $${config.costAlarmThresholdUsd}`,
      metric: billingMetric,
      threshold: config.costAlarmThresholdUsd,
      evaluationPeriods: 1,
      comparisonOperator:
        cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    billingAlarm.addAlarmAction(
      new cloudwatchActions.SnsAction(this.costAlarmTopic),
    );

    // ── Outputs ──────────────────────────────────────────────────────

    new cdk.CfnOutput(this, 'IdentityKeyArn', {
      value: this.identityKey.keyArn,
      exportName: `${p}-IdentityKeyArn`,
      description: 'CMK for identity-bearing DDB tables',
    });

    new cdk.CfnOutput(this, 'FirmwareKeyArn', {
      value: this.firmwareKey.keyArn,
      exportName: `${p}-FirmwareKeyArn`,
      description: 'CMK for firmware OTA artifacts',
    });

    new cdk.CfnOutput(this, 'AuditKeyArn', {
      value: this.auditKey.keyArn,
      exportName: `${p}-AuditKeyArn`,
      description: 'CMK for audit logs (CloudTrail + Phase 1.7 app audit)',
    });

    if (this.cloudTrailBucket) {
      new cdk.CfnOutput(this, 'CloudTrailBucketName', {
        value: this.cloudTrailBucket.bucketName,
        exportName: `${p}-CloudTrailBucket`,
      });
    }

    new cdk.CfnOutput(this, 'CostAlarmTopicArn', {
      value: this.costAlarmTopic.topicArn,
      exportName: `${p}-CostAlarmTopic`,
      description: 'SNS topic for cost/billing alarms',
    });
  }
}
