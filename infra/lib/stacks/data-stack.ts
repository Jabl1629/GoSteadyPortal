import * as cdk from 'aws-cdk-lib/core';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import { Construct } from 'constructs';
import { GoSteadyEnvConfig } from '../config.js';

export interface DataStackProps extends cdk.StackProps {
  readonly config: GoSteadyEnvConfig;
}

/**
 * Data Layer — all DynamoDB tables.
 *
 * Tables:
 *   - Device Registry   (PK: serialNumber)
 *   - Activity Series    (PK: serialNumber, SK: timestamp)
 *   - Alert History      (PK: serialNumber, SK: timestamp)
 *   - User Profiles      (PK: userId)
 *
 * Note: Relationships table lives in AuthStack since it's
 * tightly coupled to Cognito user IDs.
 */
export class DataStack extends cdk.Stack {
  public readonly deviceTable: dynamodb.Table;
  public readonly activityTable: dynamodb.Table;
  public readonly alertTable: dynamodb.Table;
  public readonly userProfileTable: dynamodb.Table;

  constructor(scope: Construct, id: string, props: DataStackProps) {
    super(scope, id, props);

    const { config } = props;
    const p = config.prefix;
    const billing =
      config.dynamoBillingMode === 'PAY_PER_REQUEST'
        ? dynamodb.BillingMode.PAY_PER_REQUEST
        : dynamodb.BillingMode.PROVISIONED;
    const removal =
      p === 'prod' ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY;

    // ── Device Registry ──────────────────────────────────────────
    // One row per physical walker cap device.
    // Updated on every heartbeat (battery, signal, last_seen).
    this.deviceTable = new dynamodb.Table(this, 'DeviceRegistry', {
      tableName: `gosteady-${p}-devices`,
      partitionKey: {
        name: 'serialNumber',
        type: dynamodb.AttributeType.STRING,
      },
      billingMode: billing,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: config.pitrEnabled },
      removalPolicy: removal,
    });

    // GSI: look up device by linked walker user ID
    this.deviceTable.addGlobalSecondaryIndex({
      indexName: 'by-walker',
      partitionKey: {
        name: 'walkerUserId',
        type: dynamodb.AttributeType.STRING,
      },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    // ── Activity Time-Series ─────────────────────────────────────
    // One row per device per hour. Core data for charts.
    // PK=serial, SK=ISO timestamp (2026-04-15T14:00:00Z)
    // Attributes: steps, distanceFt, activeMinutes, assistScore
    this.activityTable = new dynamodb.Table(this, 'ActivitySeries', {
      tableName: `gosteady-${p}-activity`,
      partitionKey: {
        name: 'serialNumber',
        type: dynamodb.AttributeType.STRING,
      },
      sortKey: {
        name: 'timestamp',
        type: dynamodb.AttributeType.STRING,
      },
      billingMode: billing,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: config.pitrEnabled },
      removalPolicy: removal,
    });

    // GSI: query by date for daily roll-ups and range queries
    this.activityTable.addGlobalSecondaryIndex({
      indexName: 'by-date',
      partitionKey: {
        name: 'serialNumber',
        type: dynamodb.AttributeType.STRING,
      },
      sortKey: {
        name: 'date',
        type: dynamodb.AttributeType.STRING, // YYYY-MM-DD
      },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    // ── Alert History ────────────────────────────────────────────
    // One row per alert event (tip-over, no-activity, battery-low).
    // PK=serial, SK=ISO timestamp
    // Attributes: alertType, severity, deliveryStatus{}, acknowledged
    this.alertTable = new dynamodb.Table(this, 'AlertHistory', {
      tableName: `gosteady-${p}-alerts`,
      partitionKey: {
        name: 'serialNumber',
        type: dynamodb.AttributeType.STRING,
      },
      sortKey: {
        name: 'timestamp',
        type: dynamodb.AttributeType.STRING,
      },
      billingMode: billing,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: config.pitrEnabled },
      removalPolicy: removal,
    });

    // GSI: query alerts by walker user ID (for caregiver dashboard)
    this.alertTable.addGlobalSecondaryIndex({
      indexName: 'by-walker',
      partitionKey: {
        name: 'walkerUserId',
        type: dynamodb.AttributeType.STRING,
      },
      sortKey: {
        name: 'timestamp',
        type: dynamodb.AttributeType.STRING,
      },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    // ── User Profiles ────────────────────────────────────────────
    // Extended user data beyond what Cognito stores.
    // Notification prefs, alert thresholds, timezone, etc.
    this.userProfileTable = new dynamodb.Table(this, 'UserProfiles', {
      tableName: `gosteady-${p}-user-profiles`,
      partitionKey: {
        name: 'userId',
        type: dynamodb.AttributeType.STRING,
      },
      billingMode: billing,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: config.pitrEnabled },
      removalPolicy: removal,
    });

    // ── Outputs ──────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'DeviceTableName', {
      value: this.deviceTable.tableName,
      exportName: `${p}-DeviceTable`,
    });
    new cdk.CfnOutput(this, 'ActivityTableName', {
      value: this.activityTable.tableName,
      exportName: `${p}-ActivityTable`,
    });
    new cdk.CfnOutput(this, 'AlertTableName', {
      value: this.alertTable.tableName,
      exportName: `${p}-AlertTable`,
    });
    new cdk.CfnOutput(this, 'UserProfileTableName', {
      value: this.userProfileTable.tableName,
      exportName: `${p}-UserProfileTable`,
    });
  }
}
